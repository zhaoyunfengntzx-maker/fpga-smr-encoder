// -----------------------------------------------------------------------------
//  lcd_test/rtl/i2c_master_seq.v
//  IIC(Inter-Integrated Circuit) 主机「字节级」引擎 —— 供电容触摸屏使用
//
//  为什么单独抽一个字节级引擎：
//    rtl/spi_slave.v / rtl/uart_spi_bridge.v 都是「固定长度、单次传输」的写法，
//    表达不了触摸屏需要的两种序列：
//      GT911  : 写寄存器地址 -> 重复START -> 从机地址(R) -> 连续读 N 字节
//      FT5x06 : 写寄存器地址 -> STOP      -> START -> 从机地址(R) -> 读 N 字节
//    所以这里把 IIC 做成可复用原语：上层填从机地址 + 最多 2 个写字节 +
//    要读几个 16bit 字，剩下的交给状态机。
//
//  时序与采样约定（本模块的"时间轴"）：
//    一个 SCL 位周期 = 4 个相位 ph=0..3，每个相位 QUARTER = CLK_DIV 个 clk。
//      ph=0 : 拉低 SCL，主机把数据放到 SDA（发）/ 释放 SDA（收）
//      ph=1 : 释放 SCL -> 高；**采样点就在 ph==1 的最后一个 clk**（SCL 高电平中点）
//      ph=2 : 保持 SCL 高
//      ph=3 : 拉低 SCL，进入下一位
//    => SCL 频率 = clk/(4*CLK_DIV) = 50MHz/(4*62) = 201.6kHz（GT911/FT5x06 均支持）
//       START/STOP 各花 1 个位周期。
//
//  关键设计点（每条都是踩过坑才写下来的）：
//    1) 数据在 SCL 低电平期间翻转、在 SCL 高电平中点采样，天然满足 setup/hold。
//    2) ★ 总线超时看门狗。触摸屏没接好时 SCL/SDA 被外部上拉成常高，状态机永远
//       等不到边沿 -> 卡死 -> 屏幕也黑，现象会被误判成"屏时序参数写错"。
//       判据：全局相位计数 stop_cnt 连续 LIMIT 个周期不推进（总线上没有任何
//       活动）就放弃本次传输、置 timeout 回 IDLE。从机时钟拉伸也计入此上限。
//    3) SDA/SCL 都是开漏 + 外部上拉：输出 0 靠拉低、输出 1 靠释放。故 *_oe
//       语义是"拉低"，不是"输出使能"。
//    4) 不采用"发完 NACK 再 STOP，然后重新 START"来拼 GT911 的寄存器读 —— 那会
//       多发一个 STOP，部分触摸IC会因此复位地址指针。读用**重复START**拼接。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module i2c_master_seq #(
    parameter CLK_DIV    = 62,           // 每相位 clk 数
    parameter BUSY_LIMIT = 25'd4_000_000 // 空转上限 80ms @50MHz
)(
    input               clk,
    input               rst_n,

    // ---- 控制侧 ----
    input               req,         // 单周期脉冲：发起一次传输
    input               wr,          // 1 = 写(tx 字节)，0 = 读(rd_words 个 16bit 字)
    input               rep,         // 读时：1 = 重复START拼接，0 = STOP断开再接续
    input       [7:0]   slv_addr,    // 7bit 从机地址（不含 R/W 位）
    input       [7:0]   tx_byte,     // 写：第 1 个字节（GT911 是地址高字节 0x81）
    input       [7:0]   tx_byte2,    // 写：第 2 个字节（GT911 是地址低字节 0x4E）
    input       [7:0]   tx_byte3,    // 写：第 3 个字节（清标记时的数据字节 0x00）
    input       [1:0]   tx_cnt,      // ★ 先发的写字节总数 0..3
                                     //   写传输：数据字节数；读传输：寄存器指针字节数
    input       [3:0]   rd_words,    // 读：读回几个 16bit 字（1..15，最多 30 字节）
    output reg          busy,
    output reg          done,        // 单周期脉冲
    output reg          nack,        // done 时有效：从机不应答
    output reg          timeout,     // done 时有效：总线超时

    // ---- 读回数据（小端拼字：先收到的字节是低 8 位） ----
    output wire [15:0]  rd_data0, rd_data1, rd_data2, rd_data3,
                        rd_data4, rd_data5, rd_data6, rd_data7,
                        rd_data8, rd_data9, rd_data10, rd_data11,
                        rd_data12, rd_data13, rd_data14, rd_data15,

    // ---- IIC 引脚（开漏语义，顶层接 IOBUF） ----
    input               scl_i,
    output reg          scl_oe,      // 1 = 拉低 SCL
    input               sda_i,
    output reg          sda_oe,      // 1 = 拉低 SDA

    // ---- 调试观测（遥测上报，不影响逻辑） ----
    output wire [3:0]   dbg_state,
    output wire         dbg_busy
);

    // ------------------------------------------------------------ 参数展开
    localparam [15:0] QUARTER = CLK_DIV;

    // ------------------------------------------------------------ 状态编码
    localparam [3:0] S_IDLE      = 4'd0,
                     S_START     = 4'd1,
                     S_SEND_ADDR = 4'd2,
                     S_ACK_ADDR  = 4'd3,
                     S_SEND_TX   = 4'd4,
                     S_ACK_TX    = 4'd5,
                     S_RX        = 4'd6,
                     S_ACK_RX    = 4'd7,
                     S_STOP      = 4'd8,
                     S_END       = 4'd9,
                     S_RECOVER   = 4'd10;   // 看门狗触发后的总线恢复（打 SCL 时钟）

    reg [3:0]  state;
    reg [1:0]  ph;              // 位内相位 0..3
    reg [15:0] phc;             // 相位内 clk 计数
    reg [2:0]  bitcnt;          // 位计数 7..0
    reg [7:0]  shreg;           // 移位寄存器
    reg [7:0]  tx1, tx2;
    reg [1:0]  tsent;           // 已发出的写字节数（1..tw）
    reg        rd_mode;         // 本次传输是否为"读"
    reg        rep_mode;        // 读时是否用重复START
    reg        after_stop_read; // FT 式：STOP 之后还要再读一次
    reg [3:0]  tw;              // 待发送的数据字节数（0 或 1）
    reg [4:0]  wcnt;            // 待接收字节数 = 2*rd_words（最多 30）
    reg [4:0]  rcnt;            // 已接收字节数
    reg [255:0] rd_buf;         // 收到的字节流（每字节占 8 位，低位在前，最多 32 字节）
    reg [24:0] stop_cnt;        // 看门狗：**当前状态**已连续停留的周期数
                                //   （★ 两处修复：1) 原来用 16bit 并把
                                //   BUSY_LIMIT[15:0] 截断比较，阈值实际只有
                                //   34048 拍 = 0.68ms；2) 原来在"等相位结束"
                                //   分支里每拍清零，而相位又只有 QUARTER 拍，
                                //   于是永远到不了阈值 —— 看门狗是死代码。）
    reg [3:0]  state_q;         // 上一拍的状态，用来实现"状态一变就清零"
    reg [3:0]  rec_cnt;         // 恢复阶段剩余的 SCL 时钟组数
    reg        nack_r, to_r;

    assign rd_data0 = rd_buf[15:0];
    assign rd_data1 = rd_buf[31:16];
    assign rd_data2 = rd_buf[47:32];
    assign rd_data3 = rd_buf[63:48];
    assign rd_data4 = rd_buf[79:64];
    assign rd_data5 = rd_buf[95:80];
    assign rd_data6 = rd_buf[111:96];
    assign rd_data7 = rd_buf[127:112];
    assign rd_data8  = rd_buf[143:128];
    assign rd_data9  = rd_buf[159:144];
    assign rd_data10 = rd_buf[175:160];
    assign rd_data11 = rd_buf[191:176];
    assign rd_data12 = rd_buf[207:192];
    assign rd_data13 = rd_buf[223:208];
    assign rd_data14 = rd_buf[239:224];
    assign rd_data15 = rd_buf[255:240];

    wire        ph_end   = (phc == QUARTER - 16'd1);
    wire        sample   = (ph == 2'd1) && ph_end;   // SCL 高电平中点采样
    wire        sda_bit  = shreg[7];
    wire        sda_low  = ~sda_bit;

    assign dbg_state = state;
    assign dbg_busy  = busy;

    // 本次传输"先发的写字节数"（读传输也要先写寄存器指针）——直接由 tx_cnt 给出：
    //   写（wr=1）：tx_cnt = 数据字节数
    //   读（wr=0）：tx_cnt = 寄存器指针字节数（GT911=2、FT5206=1）；0 = 直接读
    wire [1:0]  n_tx = tx_cnt;

    // ------------------------------------------------------------ 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; ph <= 2'd0; phc <= 16'd0; bitcnt <= 3'd0;
            shreg <= 8'd0; tx1 <= 8'd0; tx2 <= 8'd0;
            rd_mode <= 1'b0; rep_mode <= 1'b0; after_stop_read <= 1'b0;
            tw <= 4'd0; wcnt <= 5'd2; rcnt <= 5'd0; tsent <= 2'd0;
            rd_buf <= 256'd0;
            busy <= 1'b0; done <= 1'b0; nack <= 1'b0; timeout <= 1'b0;
            stop_cnt <= 25'd0; rec_cnt <= 4'd0; state_q <= S_IDLE;
            nack_r <= 1'b0; to_r <= 1'b0;
            scl_oe <= 1'b0; sda_oe <= 1'b0;
        end
        else begin
            done <= 1'b0;
            // ------------------------------------------- 看门狗计时
            // ★ 计的是"当前状态停留了多少拍"：状态一变就清零。
            //   只有这样才能既"不误报"又"能触发"：
            //     · 正常状态驻留最长的是一次字节接收 S_RX = 8bit × 4相 × QUARTER
            //       ≈ 2000 拍（CLK_DIV=62），远小于 BUSY_LIMIT=2_000_000 拍(40ms)；
            //     · 真的被拖住时状态不变，计数一直涨 → 必然触发。
            //   早期版本把计数放在"相位边界推进"里清零（相位只有 QUARTER 拍），
            //   阈值根本够不着 ⇒ 看门狗永远不触发（上板触摸停摆就是这个缺口）。
            if (state != state_q) begin
                state_q  <= state;
                stop_cnt <= 25'd0;
            end
            else if (stop_cnt != 25'h1FFFFFF) begin
                stop_cnt <= stop_cnt + 25'd1;
            end

            // ------------------------------------------- 看门狗（最高优先级）
            // ★ 两级修复（原版这里是"死代码"）：
            //   1) 原来比较的是 BUSY_LIMIT[15:0]，25 位参数被截断成 34048 拍
            //      （0.68ms @50MHz）而不是 2_000_000 拍（40ms）；而且 stop_cnt
            //      在"等相位结束"的分支里每拍都被清零 → 永远到不了阈值 → 看门狗
            //      从未触发过。上板现象：GT911 在长读（30 字节报点）时拉长 SCL，
            //      主机相位若被拖住就永久停在那个相位，上层等 done 等到永远
            //      （遥测表现为 reads_ps=0、err_ps=0、触摸字段全部冻结）。
            //   2) 触发后不再去走 S_STOP（S_STOP 也可能被从机拉低的 SCL 拖住），
            //      而是进 S_RECOVER：不看总线电平、纯打 9 组 SCL 时钟 + STOP，
            //      **保证**能走到 S_END 产生 done。
            if (busy && state != S_IDLE && state != S_END &&
                state != S_RECOVER &&
                state == state_q &&          // ★ 刚换状态那一拍不算：此刻 stop_cnt
                                             //   还是上一个状态的旧值，会立刻误触发
                stop_cnt >= BUSY_LIMIT) begin
                to_r   <= 1'b1;
                scl_oe <= 1'b0;
                sda_oe <= 1'b0;          // SDA 释放，恢复时钟不会像数据
                ph     <= 2'd0; phc <= 16'd0;
                rec_cnt <= 4'd5;         // 5 次 × 2 个 SCL 脉冲 = 10 个时钟
                state  <= S_RECOVER;
                // ★★ 必须清零：否则下一拍 stop_cnt 仍然 ≥ BUSY_LIMIT，
                //    看门狗会**每拍重新触发**，ph 被反复压回 0，
                //    S_RECOVER 永远走不完 —— 等于把"卡死"换了个地方继续卡死。
                //    （这条是 tb_i2c_watchdog.v 抓出来的：没有它，仿真里
                //      state 永远停在 10、done 永不来。）
                stop_cnt <= 25'd0;
            end
            // ------------------------------------------- 空闲：等 req，立即启动
            // ★ 必须放在"相位边界"判断之前，且不能放在 case 的 S_IDLE 分支里：
            //   状态机只在 phc == QUARTER-1 时推进（每 CLK_DIV 个 clk 一次），
            //   而 req 是**单周期脉冲**。若在相位边界才采样 req，则只有在脉冲
            //   恰好落在边界那一拍时才会启动 —— 真实 CLK_DIV=62 时命中率 1/62，
            //   表现为"上电后经常连一次传输都发不出去"（仿真里 scl_edges = 0）。
            else if (state == S_IDLE) begin
                ph      <= 2'd0;
                phc     <= 16'd0;
                scl_oe  <= 1'b0;
                sda_oe  <= 1'b0;
                busy    <= 1'b0;
                timeout <= 1'b0;
                if (req) begin
                    busy      <= 1'b1;
                    nack_r    <= 1'b0;
                    to_r      <= 1'b0;
                    stop_cnt  <= 25'd0;
                    rcnt      <= 5'd0;
                    rd_buf    <= 256'd0;
                    tw        <= n_tx;                  // 本次要发的写字节总数
                    tsent     <= (n_tx != 2'd0) ? 2'd1 : 2'd0;   // 第 1 个写字节即将发出
                    wcnt      <= {rd_words, 1'b0};      // = 2 * rd_words（最多 30）
                    tx1       <= tx_byte;
                    tx2       <= tx_byte2;
                    rd_mode   <= ~wr;
                    rep_mode  <= rep;
                    after_stop_read <= (wr == 1'b0) && (rep == 1'b0);
                    // ★ 第 1 个地址字节的 R/W：只有"直接读"（无指针字节）才是 1；
                    //   要先写指针的读（GT911/FT）第一个地址必须是写（0），
                    //   写完指针后再重复START用 R=1 的地址。
                    shreg     <= {slv_addr, (n_tx == 2'd0) ? ~wr : 1'b0};
                    bitcnt    <= 3'd7;
                    ph        <= 2'd0;
                    state     <= S_START;
                end
            end
            else if (phc < QUARTER - 16'd1) begin
                phc <= phc + 16'd1;
                // ★ 这里**不能**清 stop_cnt：清了看门狗就永远看不到"相位被拖住"。
                //   stop_cnt 只在相位真正推进时清零（下面的 else 分支）。
            end
            else begin
                // --------------------------------------- 一个相位结束，推进
                // ★ 这里**不能**清 stop_cnt：它计的是"当前状态停留时间"，
                //   清在这里就等于只看一个相位（QUARTER 拍），阈值又够不着了。
                phc <= 16'd0;
                case (state)

                // ------------------------------------------------------ IDLE
                // 注：S_IDLE 已在 case 之前单独处理（等 req、立即启动），
                //     此处不再出现 S_IDLE 分支，避免"单周期脉冲被相位边界漏采"。

                // ----------------------------------------------------- START
                // ph0:SCL 高、SDA 高   ph1:SDA 拉低(SCL高) = START
                // ph2:SCL 拉低         ph3:保持
                S_START: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end
                    2'd1: begin scl_oe <= 1'b0; sda_oe <= 1'b1; end
                    2'd2: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end
                    2'd3: begin                                   // 准备发第一位
                        scl_oe <= 1'b1;
                        sda_oe <= sda_low;
                        bitcnt <= 3'd7;
                    end
                    default: ;
                    endcase
                    ph    <= ph + 2'd1;
                    if (ph == 2'd3) state <= S_SEND_ADDR;
                end

                // ------------------------------------------------- 发送 8bit
                // ph0:SCL 低、放数据    ph1:SCL 高(从机采样)
                // ph2:SCL 高保持        ph3:SCL 拉低 + 放下一位数据
                S_SEND_ADDR, S_SEND_TX: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= sda_low; end
                    2'd1: begin scl_oe <= 1'b0; sda_oe <= sda_low; end
                    2'd2: begin scl_oe <= 1'b0; sda_oe <= sda_low; end
                    2'd3: begin
                        scl_oe <= 1'b1;
                        shreg  <= {shreg[6:0], 1'b0};
                        sda_oe <= sda_low;      // 注意：用的是移位前的 bit
                    end
                    default: ;
                    endcase
                    if (ph == 2'd3) begin
                        if (bitcnt == 3'd0)
                            state <= (state == S_SEND_ADDR) ? S_ACK_ADDR : S_ACK_TX;
                        else
                            bitcnt <= bitcnt - 3'd1;
                    end
                    ph <= ph + 2'd1;
                end

                // --------------------------------------------------- 收地址 ACK
                S_ACK_ADDR: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    2'd1: begin scl_oe <= 1'b0; if (ph_end && sda_i) nack_r <= 1'b1; end
                    2'd2: begin scl_oe <= 1'b0; end
                    2'd3: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    default: ;
                    endcase
                    if (ph == 2'd3) begin
                        if (nack_r || sda_i) begin
                            state <= S_STOP;              // 地址无应答，后续不做
                            tw    <= 4'd0;
                            tsent <= 2'd0;
                        end
                        else if (tsent != 2'd0) begin
                            // 先发写字节（纯写的数据字节，或读传输的寄存器指针）
                            shreg  <= tx1;
                            bitcnt <= 3'd7;
                            state  <= S_SEND_TX;
                        end
                        else if (rd_mode) begin
                            bitcnt <= 3'd7;
                            state  <= S_RX;               // 已发完指针：直接开始收
                        end
                        else state <= S_STOP;             // 纯写且无字节：收工
                    end
                    ph <= ph + 2'd1;
                end

                // --------------------------------------------------- 收数据 ACK
                S_ACK_TX: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    2'd1: begin scl_oe <= 1'b0; if (ph_end && sda_i) nack_r <= 1'b1; end
                    2'd2: begin scl_oe <= 1'b0; end
                    2'd3: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    default: ;
                    endcase
                    if (ph == 2'd3) begin
                        if (nack_r || sda_i) begin
                            state <= S_STOP;
                            tsent <= 2'd0;
                        end
                        else if (tsent < tw) begin        // 还有写字节没发完
                            tsent <= tsent + 2'd1;
                            shreg <= (tsent == 2'd1) ? tx2 : tx_byte3;
                            bitcnt<= 3'd7;
                            state <= S_SEND_TX;
                        end
                        else begin
                            tsent <= 2'd0;                // 写字节发完，复位计数
                            if (rd_mode) begin            // 写指针结束 -> 进入读阶段
                                shreg  <= {slv_addr, 1'b1};
                                bitcnt <= 3'd7;
                                if (rep_mode) state <= S_START;  // GT911：重复START
                                else begin                        // FT：STOP 后再起
                                    state           <= S_STOP;
                                    after_stop_read <= 1'b1;
                                end
                            end
                            else state <= S_STOP;         // 纯写：收工
                        end
                    end
                    ph <= ph + 2'd1;
                end

                // ------------------------------------------------------ 收 8bit
                S_RX: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    2'd1: begin scl_oe <= 1'b0; if (ph_end) shreg <= {shreg[6:0], sda_i}; end
                    2'd2: begin scl_oe <= 1'b0; end
                    2'd3: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    default: ;
                    endcase
                    if (ph == 2'd3) begin
                        if (bitcnt == 3'd0) state <= S_ACK_RX;
                        else begin
                            bitcnt <= bitcnt - 3'd1;
                            state  <= S_RX;
                        end
                    end
                    ph <= ph + 2'd1;
                end

                // ------------------------------------------- 发 ACK/NACK + 存字节
                // ★ 应答位必须在整个相位里**保持不变**：
                //   原来 ph2 就在 SCL 还是高电平时把 SDA 释放（拉高），这在 IIC 总线上
                //   正好构成一个 STOP 条件，从机读到第 1 个字节后就复位了，后面的字节
                //   全部被读成 0xFF（实测 x0 解码成 0x3FFF = 全 1）。
                //   正确的释放时机是"下一个状态里 SCL 已经拉低之后"（S_RX ph0 / S_STOP ph0）。
                S_ACK_RX: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= (rcnt == wcnt - 5'd1) ? 1'b0 : 1'b1; end
                    2'd1: begin scl_oe <= 1'b0; sda_oe <= (rcnt == wcnt - 5'd1) ? 1'b0 : 1'b1; end
                    2'd2: begin scl_oe <= 1'b0; sda_oe <= (rcnt == wcnt - 5'd1) ? 1'b0 : 1'b1; end
                    2'd3: begin scl_oe <= 1'b1; sda_oe <= (rcnt == wcnt - 5'd1) ? 1'b0 : 1'b1; end
                    default: ;
                    endcase
                    if (ph == 2'd3) begin
                        // 把刚收到的字节塞进 rd_buf（低位在前，小端）
                        rd_buf[8*rcnt +: 8] <= shreg;
                        if (rcnt == wcnt - 5'd1) begin
                            rcnt  <= 5'd0;
                            state <= S_STOP;
                        end
                        else begin
                            rcnt   <= rcnt + 5'd1;
                            bitcnt <= 3'd7;
                            state  <= S_RX;
                        end
                    end
                    ph <= ph + 2'd1;
                end

                // ------------------------------------------------------- STOP
                // ph0:SCL 低、SDA 低   ph1:SCL 高、SDA 低
                // ph2:SCL 高、SDA 释放 -> STOP   ph3:准备下一次 START
                S_STOP: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end
                    2'd1: begin scl_oe <= 1'b0; sda_oe <= 1'b1; end
                    2'd2: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end
                    2'd3: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end
                    default: ;
                    endcase
                    if (ph == 2'd3) begin
                        if (after_stop_read && !nack_r && !to_r) begin
                            // FT 式分段读：STOP 之后重新 START 读数据
                            after_stop_read <= 1'b0;
                            rd_mode <= 1'b1;
                            shreg   <= {slv_addr, 1'b1};
                            bitcnt  <= 3'd7;
                            rcnt    <= 5'd0;
                            state   <= S_START;
                        end
                        else state <= S_END;
                    end
                    ph <= ph + 2'd1;
                end

                // ------------------------------------------- 总线恢复
                // ★ 看门狗触发后走这里。不看 scl_i/sda_i（可能被从机拉死），
                //   纯靠 phc 计时打 SCL 时钟：把从机从"半途等时钟"的状态里敲出来，
                //   再把线全部释放，然后照常 S_STOP -> S_END。因为不依赖总线电平，
                //   这一步**保证**能走完 —— 于是 done 一定能产生。
                S_RECOVER: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end   // SCL 低
                    2'd1: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end   // SCL 高
                    2'd2: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end   // SCL 低
                    2'd3: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end   // SCL 高
                    default: ;
                    endcase
                    if (ph == 2'd3) begin
                        if (rec_cnt == 4'd0) state <= S_STOP;
                        else                 rec_cnt <= rec_cnt - 4'd1;
                    end
                    ph <= ph + 2'd1;
                end

                // -------------------------------------------------------- END
                S_END: begin
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b0;
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    nack   <= nack_r;
                    timeout<= to_r;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
