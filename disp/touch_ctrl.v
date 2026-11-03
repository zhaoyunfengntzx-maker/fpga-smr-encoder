// -----------------------------------------------------------------------------
//  disp/touch_ctrl.v
//  电容触摸屏 IIC 控制序列器（GT911 / FT5206 / FT5446 兼容）
//
//  为什么要自动探测：
//    正点原子 7 寸 1024x600 模块（ATK-7016）在不同批次上分别贴 GT911 或
//    FT5206/FT5446（厂家标称"触摸IC GT911/FT5206/FT5446"）。两者虽然都是
//    IIC 电容屏，但从机地址、寄存器地址、读法都不同：
//
//      GT911   7bit 地址 0x5D，触摸状态寄存器 0x814E（2 字节寄存器地址），
//              一次性读 status(1B) + 5 个点 x 4B = 10B（小端，d0 的低字节是
//              status）。★ 每次读完必须写 0x814E = 0x00 清标记，否则 IC 不再
//              刷新数据 —— 这是"触摸没反应"最常见的原因。
//      FT5206  7bit 地址 0x38，触摸状态寄存器 0x02（1 字节），点数在
//              status[3:0]；坐标在 0x03 起的 4 字节/点。
//              ★ 必须"先读 0x02 再读 0x03"，不能一条流水线读下来（不同寄存器
//              有不同长度，连续读会错位；官方驱动就是分两次读的）。
//
//    所以这里上电后依次探测：先按 GT911 读一次 0x814E，若地址被应答且状态
//    字节落在 0..5 就锁定 GT911；否则按 FT5206 读 0x02，应答即锁定 FT。
//    都没应答则进入 SLOW 模式（每 500ms 重探一次），probe_gt/probe_ft 与
//    rst_cnt 会把探测过程暴露给 UART 遥测，而不是死循环什么都不说。
//
//  其它设计点：
//    1) SCL/SDA/INT 都经 2 级同步器再进状态机（异步引脚直接进 FSM 有亚稳态）。
//    2) 从机地址是 7bit，发出时左移 1 位补 R/W —— 由 i2c_master_seq 负责拼接。
//    3) stat_reads/nack/timeout/touch 四个 24bit 计数器 + 1 秒门控 = 真实的
//       "触摸扫描率 / 误码率"，这是触控性能测试最主要的量化指标。
//    4) 只有**锁定型号之后**的失败才计入 nack/timeout，否则探测阶段的
//       "故意用错地址"会污染统计。
//    5) 坐标更新时翻转 tch_toggle，像素域用边沿检测安全取用（跨时钟域握手）。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module touch_i2c_ctrl #(
    parameter IIC_DIV  = 62,               // SCL = 50MHz/(4*62) = 201.6kHz
    parameter SLOW_CYC = 25'd25_000_000    // SLOW 模式重探间隔 = 500ms
)(
    input               clk,               // 50MHz
    input               rst_n,

    // ---- IIC（开漏语义，顶层接 IOBUF） ----
    input               scl_i,
    output              scl_oe,
    input               sda_i,
    output              sda_oe,

    // ---- 触摸中断（低有效，仅上报） ----
    input               int_n_i,

    // ---- 结果 ----
    output reg          tch_valid,         // 1 = 本次读到的坐标有效
    output reg          tch_toggle,        // 每得到一组新坐标翻转一次（跨域握手）
    output reg  [1:0]   tch_type,          // 0=未知 1=GT911 2=FT5x06
    output reg  [2:0]   tch_num,           // 触摸点数 0..5
    output reg  [15:0]  tch_x0, tch_y0,
    output reg  [15:0]  tch_x1, tch_y1,
    output reg  [15:0]  tch_x2, tch_y2,
    output reg  [15:0]  tch_x3, tch_y3,
    output reg  [15:0]  tch_x4, tch_y4,

    // ---- 统计 ----
    output reg  [23:0]  stat_reads,        // 成功完成的传输次数
    output reg  [23:0]  stat_nack,         // 从机无应答次数（锁定型号后）
    output reg  [23:0]  stat_timeout,      // 总线超时次数（锁定型号后）
    output reg  [23:0]  stat_touch,        // 累计检测到"有点"的次数
    output reg  [7:0]   rst_cnt,           // 探测阶段序号（排查用）
    output reg  [7:0]   probe_gt,          // GT911 探测读到的状态字节
    output reg  [7:0]   probe_ft,          // FT5206 探测读到的状态字节
    output reg  [7:0]   prod_id,           // GT911 产品 ID 首字节（0x39 = '9'）
                                           //   ★ 上板诊断用：总线被拉死时这里会是 0x00
    output reg  [7:0]   gt_status_raw,     // 0x814E 原始状态字节（bit7=坐标就绪, [3:0]=点数）
    output reg  [15:0]  gt_xmax, gt_ymax,  // 0x8146/0x8148：芯片内部配置的分辨率
                                           //   ★ 上板诊断用：读到 0 说明配置没加载/固件没跑
    output reg  [7:0]   int_low_cnt,       // INT 为低的采样计数（24 位会被截断，仅看趋势）

    // ---- 调试观测（遥测 v3 的 byte4/5/6 复用空位上报，见 lcd_test2_top.v） ----
    //   dbg[2:0] = 本模块状态机 state，dbg[3] = IIC 主机 busy，
    //   dbg[7:4] = IIC 主机 state，dbg[11:8] = step
    output wire [15:0]  dbg
);

    // ------------------------------------------------------------- 编译期开关
    // ★ F6-3「配置表写入」开关（需求书：本版可不实现，但必须留开关 + 文档说明）
    //   1'b0 = 不写配置表，用 GT911 出厂默认配置 —— 本版走的路，已上板验证。
    //   1'b1 = 预留：识别成功后先去 STEP_CFG 写原厂 184 字节配置表（0x8047 起）。
    //          ★ 现在打开开关是**故意让触摸停下来**：STEP_CFG 分支还没有数据可写，
    //            所以它不发任何 IIC 请求、step 停在原地。现象一眼能认：
    //            遥测 mode/tch_type 正常但 reads_ps 掉到 0，面板点数永远是 0。
    //            补实现：在 STEP_CFG 里按原厂寄存器表把 184 字节写完，再
    //            `step <= STEP_GT_INFO` 接回原来那条链。
    //          为什么宁可用"停下"也不用"随便写一版"：GT911 配置表写错会把芯片配到
    //          错误的分辨率/中断模式，比不写更糟（这一版就是靠出厂配置跑通的）。
    parameter CFG_WRITE_EN = 1'b0;

    // ------------------------------------------------------------- 常量
    localparam [6:0] ADDR_GT = 7'h5D;
    localparam [6:0] ADDR_FT = 7'h38;

    // 等 IIC 主机 done 的兜底上限：50ms（2_500_000 × 20ns）没等到就强行跳出
    localparam [24:0] WAIT_LIMIT = 25'd2_500_000;

    localparam [3:0] STEP_GT_PB  = 4'd0,   // 探测 GT911：读 0x814E
                     STEP_FT_PB  = 4'd1,   // 探测 FT5206：读 0x02
                     STEP_FT_PB2 = 4'd2,   // 探测 FT5206：读 0x03（确认坐标区）
                     STEP_LOOP   = 4'd3,   // GT911 读点位：0x814E 起 13 字（26 字节）
                     STEP_FT_RD  = 4'd4,   // 正式轮询 FT5206：0x03 起读 4 字
                     STEP_CLR    = 4'd5,   // GT911 清中断：写 0x814E = 0
                     STEP_GT_ID  = 4'd6,   // 读 GT911 产品 ID（0x8140 起 4 字节）
                     STEP_GT_INFO= 4'd7,   // 读 GT911 固件版本 + X/Y 分辨率（0x8144 起 6 字节）
                     // ★ 第二版新增：轮询 GT911 时**只读状态字**（1 个字 = 2 字节）。
                     //   只有状态字非 0（bit7=坐标就绪 / 有点 / have key）时，才进入
                     //   STEP_LOOP 把 26 字节的点位数据读回来，读完再 STEP_CLR 清标记。
                     //   第一版是无条件每 3.3ms 读 26 字节并清标记，总线占用高得多，
                     //   也不是 GT911 常见驱动的用法。
                     STEP_POLL   = 4'd8,
                     // ★ 点 4 单读：GT911 每点 **8 字节**，从 0x814E 起 15 字（30 字节）只能
                     //   覆盖到点 3（点 3 的 Y 高字节 = 0x816B）。点 4 的 X/Y 在
                     //   0x8170..0x8173，所以 LOOP 之后再补一次"0x8170 起 2 字"的短读。
                     STEP_LOOP4  = 4'd10,
                     // ★ F6-3 预留（配合文件顶部的 CFG_WRITE_EN 开关）
                     STEP_CFG    = 4'd9;

    localparam [2:0] ST_IDLE = 3'd0, ST_REQ = 3'd1, ST_WAIT = 3'd2,
                     ST_END  = 3'd3, ST_HOLD= 3'd4;

    localparam [1:0] MODE_GT = 2'd1, MODE_FT = 2'd2;

    // ------------------------------------------------------------- IIC 引擎连线
    reg          m_req;
    wire         m_wr, m_rep;
    wire [1:0]   m_txcnt;
    wire [7:0]   m_addr, m_tx1, m_tx2, m_tx3;
    wire [3:0]   m_rdw;
    wire         m_busy, m_done, m_nack, m_to;
    wire [3:0]   m_state;                  // IIC 主机当前状态（调试观测）
    wire [15:0]  d0, d1, d2, d3, d4, d5, d6, d7;
    wire [15:0]  d8, d9, d10, d11, d12, d13, d14, d15;

    i2c_master_seq #(
        .CLK_DIV    (IIC_DIV),
        .BUSY_LIMIT (25'd2_000_000)        // 40ms 无总线活动即判超时
    ) u_iic (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (m_req),
        .wr        (m_wr),
        .rep       (m_rep),
        .slv_addr  (m_addr),
        .tx_byte   (m_tx1),
        .tx_byte2  (m_tx2),
        .tx_byte3  (m_tx3),
        .tx_cnt    (m_txcnt),
        .rd_words  (m_rdw),
        .busy      (m_busy),
        .done      (m_done),
        .nack      (m_nack),
        .timeout   (m_to),
        .rd_data0  (d0), .rd_data1 (d1), .rd_data2 (d2), .rd_data3 (d3),
        .rd_data4  (d4), .rd_data5 (d5), .rd_data6 (d6), .rd_data7 (d7),
        .rd_data8  (d8),  .rd_data9  (d9),  .rd_data10 (d10), .rd_data11 (d11),
        .rd_data12 (d12), .rd_data13 (d13), .rd_data14 (d14), .rd_data15 (d15),
        .scl_i     (scl_i),
        .scl_oe    (scl_oe),
        .sda_i     (sda_i),
        .sda_oe    (sda_oe),
        .dbg_state (m_state),
        .dbg_busy  ()
    );

    // ------------------------------------------------------------- 状态
    reg [2:0]  state;
    reg [3:0]  step;
    reg [1:0]  mode;
    reg [24:0] slow_cnt;      // SLOW 模式重探
    reg [19:0] rdy_to;        // 探测/轮询之间的稳定期
    reg [24:0] wait_cnt;      // ★ ST_WAIT 兜底超时计数（见 WAIT_LIMIT）

    assign dbg = {4'd0, step, m_state, m_busy, state};
    reg [7:0]  gt_status, ft_status;
    reg        int_low;
    // ★ 连续"读不到报点"的轮询计数（见 STEP_POLL）：用于在芯片丢失"抬手"中断、
    //   状态字恒为 0 时主动清掉残留点数，否则准星会一直挂在屏上。
    reg [5:0]  nodata_cnt;

    // ------------------------------------------------------------- 点数据解码
    wire [3:0] gt_num = d0[3:0];
    wire [3:0] ft_num = ft_status[3:0];

    reg [15:0] nx0, nx1, nx2, nx3, nx4;
    reg [15:0] ny0, ny1, ny2, ny3, ny4;
    reg [2:0]  nnum;

    always @(*) begin
        if (mode == MODE_FT) begin
            // FT5206 从 0x03 起读 8 字节，每点 4 字节：XH(只用低 4 位)、XL、YH、YL。
            // 主机把先收到的字节放低位，所以 d0 = {XL, XH}、d1 = {YL, YH}
            //   x = ((XH & 0x0F) << 8) | XL = {2'd0, d0[3:0], d0[15:8]}
            nnum = (ft_num > 4'd5) ? 3'd5 : ft_num[2:0];
            nx0 = {2'd0, d0[3:0], d0[15:8]};
            ny0 = {2'd0, d1[3:0], d1[15:8]};
            nx1 = {2'd0, d2[3:0], d2[15:8]};
            ny1 = {2'd0, d3[3:0], d3[15:8]};
            nx2 = 16'd0; ny2 = 16'd0;
            nx3 = 16'd0; ny3 = 16'd0;
            nx4 = 16'd0; ny4 = 16'd0;
        end
        else begin
            // GT911：**每个触摸点占 8 字节**（GT911 Programming Guide / Linux goodix.c 的
            //        GOODIX_CONTACT_SIZE=8 / Slint gt911 crate 的 TOUCHPOINT_ENTRY_LEN=8）。
            //        点 0 起始寄存器 0x814F，之后每点 +8：
            //          +0 = track id，+1/+2 = X（小端），+3/+4 = Y（小端），+5/+6 = 面积，+7 = 保留
            //        于是点 k 的 X = {4'd0, XH[3:0], XL}，字节地址如下（读出流从 0x814E 起）：
            //          b0   = status        b1..b8   = 点 0（X = b2/b3，Y = b4/b5）
            //          b9..b16 = 点 1（X = b10/b11，Y = b12/b13）
            //          b17..b24 = 点 2（X = b18/b19，Y = b20/b21）
            //          b25..b32 = 点 3（X = b26/b27，Y = b28/b29）
            //          b33..b40 = 点 4（X = b34/b35，Y = b36/b37，tid 在 0x816F）
            // 主机把**先收到的字节放低位**：d_k = {b(2k+1), b(2k)}。因为每点 8 字节=4 个字，
            // 点 0/1/2/3 都**字对齐**，一个点的 X 就落在同一个字的高低字节里。
            // ★ 曾按"每点 5 字节"解码（点 1 起全部错位：x1 恒 0、y1 恒 0x401=1025，正是
            //   上板遥测看到的现象），仿真模型当时也是按 5 字节摆的，等于把错误一起验证了。
            nnum = (gt_num > 4'd5) ? 3'd5 : gt_num[2:0];
            // 点 0：X = {X0H,X0L} = d1，Y = {Y0H,Y0L} = d2
            nx0 = {4'd0, d1[11:8], d1[7:0]};
            ny0 = {4'd0, d2[11:8], d2[7:0]};
            // 点 1：从 b10/b11 起，正好是 d5/d6
            nx1 = {4'd0, d5[11:8], d5[7:0]};
            ny1 = {4'd0, d6[11:8], d6[7:0]};
            // 点 2：从 b18/b19 起，正好是 d9/d10
            nx2 = {4'd0, d9[11:8], d9[7:0]};
            ny2 = {4'd0, d10[11:8], d10[7:0]};
            // 点 3：从 b26/b27 起，正好是 d13/d14（b29 = 0x816B 是本次长读的最后一个数据字节）
            nx3 = {4'd0, d13[11:8], d13[7:0]};
            ny3 = {4'd0, d14[11:8], d14[7:0]};
            // 点 4：b33..b40 超出本次长读范围（30 字节只到 b29），由 STEP_LOOP4 单独
            //       从 0x8170 读 2 个字：d0 = {X4H,X4L}、d1 = {Y4H,Y4L}。
            //       ★ 只有 STEP_LOOP4 那一刻这两个式子才有意义（那时 d0/d1 才是点 4 的数据），
            //         所以点 4 的锁存必须单独放在 STEP_LOOP4 完成时做。
            nx4 = {4'd0, d0[11:8], d0[7:0]};
            ny4 = {4'd0, d1[11:8], d1[7:0]};
        end
    end

    // --------------------------------------------------- 本次传输参数（组合）
    assign m_wr     = (step == STEP_CLR);
    assign m_rep    = (step != STEP_FT_PB) && (step != STEP_FT_PB2) &&
                      (step != STEP_FT_RD);
    // ★ GT911 的寄存器地址是**大端 16bit**：必须先发高字节 0x81，再发低字节 0x4E。
    //   早先写成 0x4E/0x81（低字节在前），从机解析出的指针是 0x4E81 —— 落在未定义区，
    //   读回全 0。而探测判据是"状态字 <= 5"，全 0 恰好**通过**，于是 mode 被错误锁定成
    //   GT911、后续轮询全是 0：表现为"认得出屏但读不到坐标"。
    // FT5206 的寄存器地址是单字节，没有第 2/3 字节。
    // ★ 每步先写的字节数（读步 = 寄存器指针字节数；写步 = 数据字节数）
    //   GT911 指针 2 字节（0x81 高、0x4E 低）；FT5206 指针 1 字节；
    //   清标记是写 0x814E <= 0x00，共 3 字节。
    assign m_txcnt  = (step == STEP_GT_PB || step == STEP_LOOP ||
                       step == STEP_GT_INFO || step == STEP_POLL ||
                       step == STEP_LOOP4 || step == STEP_GT_ID) ? 2'd2 :
                      (step == STEP_CLR)                       ? 2'd3 : 2'd1;
    assign m_addr   = (step == STEP_FT_PB || step == STEP_FT_PB2 || step == STEP_FT_RD)
                      ? ADDR_FT : ADDR_GT;
    assign m_tx1    = (step == STEP_FT_PB || step == STEP_FT_PB2) ? 8'h02 :
                      (step == STEP_FT_RD)                        ? 8'h03 : 8'h81;
    assign m_tx2    = (step == STEP_GT_ID)   ? 8'h40 :
                      (step == STEP_GT_INFO) ? 8'h44 :
                      (step == STEP_LOOP4)   ? 8'h70 : 8'h4E;
    assign m_tx3    = 8'h00;
    // ★ LOOP = 15 个 16bit 字 = 30 字节 = 0x814E 状态字 + 点 0..3 × 8 字节
    //   （点 3 的 Y 高字节 = 0x816B 是最后一个数据字节；点 4 由 STEP_LOOP4 再读 2 字）
    //   主机读缓冲 32 字节 / rd_data0..15，15 字正好是上限，见 i2c_master_seq.v。
    assign m_rdw    = (step == STEP_GT_PB)  ? 4'd1 :
                      (step == STEP_FT_PB)  ? 4'd1 :
                      (step == STEP_FT_PB2) ? 4'd2 :
                      (step == STEP_LOOP)   ? 4'd15 :
                      (step == STEP_LOOP4)  ? 4'd2 :
                      (step == STEP_GT_ID)  ? 4'd2 :
                      (step == STEP_GT_INFO)? 4'd3 :
                      (step == STEP_FT_RD)  ? 4'd4 : 4'd1;   // STEP_POLL 也是 1 个字

    // ------------------------------------------------------------- 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; step <= STEP_GT_PB; mode <= 2'd0;
            m_req <= 1'b0;
            // ★ slow_cnt 复位值必须是 SLOW_CYC（而不是 0）：ST_IDLE 在 mode==0 时
            //   要等 slow_cnt 计满 SLOW_CYC 才发探测请求。若复位成 0，上电后要等
            //   整整 500ms 才会发出第一次探测 —— 表现为"接上屏 0.5 秒才亮/才认屏"，
            //   在仿真里则表现为 4ms 窗口内 SCL 一次都不动（scl_edges = 0）。
            //   置成 SLOW_CYC 表示"重探定时器已到期"，于是第一次探测立刻发出。
            slow_cnt <= SLOW_CYC[24:0]; rdy_to <= 20'd0;
            tch_valid <= 1'b0; tch_toggle <= 1'b0; tch_type <= 2'd0; tch_num <= 3'd0;
            tch_x0 <= 16'd0; tch_y0 <= 16'd0; tch_x1 <= 16'd0; tch_y1 <= 16'd0;
            tch_x2 <= 16'd0; tch_y2 <= 16'd0; tch_x3 <= 16'd0; tch_y3 <= 16'd0;
            tch_x4 <= 16'd0; tch_y4 <= 16'd0;
            stat_reads <= 24'd0; stat_nack <= 24'd0; stat_timeout <= 24'd0;
            stat_touch <= 24'd0;
            rst_cnt <= 8'd0; probe_gt <= 8'd0; probe_ft <= 8'd0; prod_id <= 8'h00;
            gt_status_raw <= 8'h00; gt_xmax <= 16'd0; gt_ymax <= 16'd0;
            gt_status <= 8'd0; ft_status <= 8'd0;
            int_low <= 1'b0; int_low_cnt <= 8'd0;
            nodata_cnt <= 6'd0;
            wait_cnt   <= 25'd0;
        end
        else begin
            // ------------------------------------------------ INT 采样（仅统计）
            int_low <= ~int_n_i;
            if (~int_n_i) int_low_cnt <= int_low_cnt + 8'd1;

            case (state)
            // ------------------------------------------------------ 发请求
            ST_IDLE: begin
                // ★ 第二版：INT 是"有数据就绪"的低脉冲。INT 一低就**立刻**发请求，
                //   不再等 rdy_to 计满；空闲时则按 rdy_to 的慢节奏轮询（~10ms）。
                //   这样既跟得上手指，又不会像第一版那样把总线占满。
                if (rdy_to != 20'd0 && int_n_i) begin
                    rdy_to <= rdy_to - 20'd1;
                end
                // ★ CFG_WRITE_EN 打开且已进 STEP_CFG 时，故意不发任何请求：
                //   配置表写入还没实现，宁可停在原地（现象见文件顶部说明），
                //   也不能让 step=4'd9 落到 IIC 引擎的 default 分支上乱读寄存器。
                //   开关默认 0，下面两处条件都会被综合常量折叠掉，逻辑与关闭时完全一致。
                else if (mode != 2'd0 && !(CFG_WRITE_EN && step == STEP_CFG)) begin
                    rdy_to <= 20'd0;
                    m_req <= 1'b1;
                    state <= ST_REQ;
                end
                else if (CFG_WRITE_EN && step == STEP_CFG) begin
                    rdy_to <= 20'd0;                 // 停在原地：不产生总线活动
                end
                else if (slow_cnt >= SLOW_CYC[24:0]) begin
                    m_req <= 1'b1;
                    slow_cnt <= 25'd0;
                    state <= ST_REQ;
                end
                else begin
                    slow_cnt <= slow_cnt + 25'd1;
                end
            end

            ST_REQ: begin
                m_req <= 1'b0;
                wait_cnt <= 25'd0;
                state <= ST_WAIT;
            end

            // ------------------------------------------------------ 等完成
            ST_WAIT: begin
                if (m_done) begin
                    state <= ST_END;
                    if (m_to) begin
                        if (mode != 2'd0) stat_timeout <= stat_timeout + 24'd1;
                    end
                    else if (m_nack) begin
                        if (mode != 2'd0) stat_nack <= stat_nack + 24'd1;
                    end
                    else begin
                        stat_reads <= stat_reads + 24'd1;
                        if (step == STEP_GT_PB) begin
                            gt_status <= d0[7:0];
                            probe_gt  <= d0[7:0];
                        end
                        if (step == STEP_FT_PB) begin
                            ft_status <= d0[7:0];
                            probe_ft  <= d0[7:0];
                        end
                        // 0x814E 原始状态字节（bit7 = 坐标就绪）。上板时若恒为 0x00，
                        // 说明芯片根本没产生报点（配置没加载 / 传感没接 / INT 被压住）。
                        if (step == STEP_LOOP || step == STEP_POLL) gt_status_raw <= d0[7:0];
                        // 0x8144 起 6 字节 = 固件版本(2B) + X 输出上限(2B) + Y 输出上限(2B)。
                        // 字节序：先收到的字节落在低位，所以 d1 = {0x8147(高), 0x8146(低)}，
                        // 它本身就已经是 Little-Endian 的分辨率（1024=0x0400 / 600=0x0258），
                        // 直接用即可。★ 曾经在这里多写一次字节交换，真的 1024 被解成 4。
                        if (step == STEP_GT_INFO) begin
                            gt_xmax <= d1;
                            gt_ymax <= d2;
                        end
                        // ★ 点 0..3 在 LOOP 长读（30 字节 = 状态字 + 点0..3 各 8 字节）里就有；
                        //   点 4 要等 STEP_LOOP4 的短读回来（那时 d0/d1 才是点 4 的 X/Y），
                        //   所以点 4 必须分开锁存，不能在 LOOP 这里用 nx4/ny4。
                        if (step == STEP_LOOP || step == STEP_FT_RD) begin
                            tch_num    <= nnum;
                            tch_x0 <= nx0; tch_y0 <= ny0;
                            tch_x1 <= nx1; tch_y1 <= ny1;
                            tch_x2 <= nx2; tch_y2 <= ny2;
                            tch_x3 <= nx3; tch_y3 <= ny3;
                            tch_valid  <= (nnum != 3'd0);
                            tch_toggle <= ~tch_toggle;
                            nodata_cnt <= 6'd0;
                            if (nnum != 3'd0) stat_touch <= stat_touch + 24'd1;
                        end
                        // 点 4（第 5 点）：STEP_LOOP4 从 0x8170 单独读 2 字
                        if (step == STEP_LOOP4) begin
                            tch_x4 <= nx4; tch_y4 <= ny4;
                        end
                    end
                end
                // ★ 兜底：IIC 主机因任何原因没给出 done 时强行跳出，绝不让状态机
                //   永远停在"等 done"上。上板出现过的"触摸后 reads_ps 掉 0、所有
                //   触摸字段冻结、err_ps 也是 0"就是这种死等（done 永远不来，
                //   所以既不计数成功也不计数失败）。跳出后回到 POLL 轮询态。
                else begin
                    if (wait_cnt >= WAIT_LIMIT) begin
                        wait_cnt <= 25'd0;
                        state    <= ST_IDLE;
                        step     <= STEP_POLL;
                        if (mode != 2'd0) stat_timeout <= stat_timeout + 24'd1;
                    end
                    else wait_cnt <= wait_cnt + 25'd1;
                end
            end

            // ------------------------------------------------------ 决定下一步
            ST_END: begin
                state <= ST_IDLE;
                case (step)
                STEP_GT_PB: begin
                    rst_cnt <= 8'd1;
                    // ★ 探测判据必须容忍"有数据就绪"的状态字。GT911 的 0x814E：
                    //   bit7 = 坐标就绪、bit6 = large detect、bit5 = 保留(0)、bit4 = have key、
                    //   bit[3:0] = 点数。所以读到 0x82（2 点就绪）是**正常**值，而早先的
                    //   判据 `d0[7:0] <= 5` 把它判成"不是 GT911"，于是 mode 永远锁不上、
                    //   每 500ms 重探一次（集成台实测 1.5s 内只发出 2 次读、mode 恒为 0，
                    //   而 tb_touch_i2c 里假从机状态字是 0x02 所以侥幸通过）。
                    //   正确判据：地址被应答 + 不是总线空闲的 0xFF + 保留位 bit5 为 0 +
                    //             点数 <= 5。
                    if (!m_nack && !m_to && (d0[7:0] != 8'hFF) &&
                        (d0[5] == 1'b0) && (d0[3:0] <= 4'd5)) begin
                        mode     <= MODE_GT;
                        tch_type <= 2'd1;
                        step     <= STEP_GT_ID;      // 先读产品 ID（上板诊断）
                        rdy_to   <= 20'd100_000;     // 2ms
                    end
                    else begin
                        // ★ GT 探测失败 -> 立刻排下一个探测（FT）。这里必须把 slow_cnt
                        //   重新置成 SLOW_CYC：mode 还是 0，ST_IDLE 会走 `slow_cnt >= SLOW_CYC`
                        //   那条分支；不重新置位的话，FT 探测要再等 500ms 才会发出
                        //   （实测：只有 FT 芯片的板上，8ms 仿真里一根 SCL 都没有）。
                        //   注意只在这一条分支重新置位 —— 整条探测链都没找到时仍然保持
                        //   500ms 的慢重探节奏，不会变成 2ms 一次的持续打扰。
                        step     <= STEP_FT_PB;
                        rdy_to   <= 20'd100_000;
                        slow_cnt <= SLOW_CYC[24:0];
                    end
                end
                STEP_FT_PB: begin
                    rst_cnt <= 8'd2;
                    if (!m_nack && !m_to && (d0[7:0] != 8'hFF) && (d0[3:0] <= 4'd5)) begin
                        mode   <= MODE_FT;
                        step   <= STEP_FT_PB2;
                        rdy_to <= 20'd100_000;
                    end
                    else begin
                        step   <= STEP_GT_PB;        // 都没找到，回头再试
                        rdy_to <= 20'd100_000;
                    end
                end
                STEP_FT_PB2: begin
                    rst_cnt <= 8'd3;
                    if (!m_nack && !m_to) begin
                        mode     <= MODE_FT;
                        tch_type <= 2'd2;
                        step     <= STEP_FT_RD;
                        rdy_to   <= 20'd100_000;
                    end
                    else begin
                        step   <= STEP_GT_PB;
                        rdy_to <= 20'd100_000;
                    end
                end
                STEP_LOOP: begin
                    // ★ 真有 5 点时才补读点 4（省掉一次总线往返）；否则直接去清标记。
                    //   nnum 在这里仍然有效：ST_END 时 d0..d15 还是 LOOP 长读的数据。
                    if (nnum >= 3'd5) begin
                        step   <= STEP_LOOP4;
                        rdy_to <= 20'd0;
                    end
                    else begin
                        step   <= STEP_CLR;          // GT911 必须清状态标记
                        rdy_to <= 20'd0;
                    end
                end
                // 点 4 补齐：0x8170 起 2 字
                STEP_LOOP4: begin
                    step   <= STEP_CLR;
                    rdy_to <= 20'd0;
                end
                // GT911 产品 ID：0x8140 起 4 字节 = '9' '1' '1' + 版本。
                // 读到 0x39 说明"确实是 GT911 在应答、而且读回的是真数据"；
                // 读到 0x00/0xFF 说明总线被拉死或器件没在上电工作状态。
                STEP_GT_ID: begin
                    prod_id <= d0[7:0];
                    // ★ F6-3：开关打开时先去写配置表（见 STEP_CFG），默认直接读信息
                    step    <= CFG_WRITE_EN ? STEP_CFG : STEP_GT_INFO;
                    rdy_to  <= 20'd100_000;          // 2ms
                end
                // 固件版本 + X/Y 分辨率：只读一次，用来判断芯片的配置是否真的加载了
                STEP_GT_INFO: begin
                    step    <= STEP_POLL;            // ★ 进"按需读"轮询
                    rdy_to  <= 20'd100_000;          // 2ms
                end
                STEP_CLR: begin
                    step   <= STEP_POLL;             // ★ 清完标记先只读状态字
                    rdy_to <= 20'd100_000;           // 2ms（有点时快速跟手）
                end
                // ★ 按需读：状态字为 0 就继续慢轮询；非 0（坐标就绪 / 有点 / have key）
                //   才把 26 字节点位数据读回来。这样总线占用从"每 3.3ms 读 26 字节"
                //   降到"每 10ms 读 2 字节，有触摸时才多读 26 字节"。
                STEP_POLL: begin
                    if (!m_nack && !m_to && (d0[7:0] != 8'h00)) begin
                        nodata_cnt <= 6'd0;
                        step   <= STEP_LOOP;
                        rdy_to <= 20'd0;
                    end
                    else begin
                        step   <= STEP_POLL;
                        rdy_to <= 20'd500_000;       // 10ms 后再看（INT 一低就跳过这段等待）
                        // ★ 抬手兜底：GT911 有时不产生"抬手"中断，状态字会一直是 0，
                        //   点数据就永远停在最后一帧（实测抬手后 tch_num 恒为 2、准星挂在
                        //   屏上不动）。连续 48 次（≈0.5s）读不到任何报点就主动清点数/有效位。
                        if (nodata_cnt != 6'd63) nodata_cnt <= nodata_cnt + 6'd1;
                        if (nodata_cnt >= 6'd47) begin
                            tch_num   <= 3'd0;
                            tch_valid <= 1'b0;
                        end
                    end
                end
                STEP_FT_RD: begin
                    step   <= STEP_FT_RD;
                    rdy_to <= 20'd250_000;           // 5ms（FT 不用清标记）
                end
                // ★ F6-3 预留：GT911 配置表写入（184 字节，0x8047 起）
                //   本版没有可用的原厂配置表内容，所以这里刻意不碰总线、把 step 停在原地，
                //   让"开关打开了但功能没实现"表现为"触摸轮询停住"（见文件顶部说明）。
                //   补实现：按原厂寄存器表把这 184 字节发出去（必要时分批，每批后留出
                //   配置加载时间），写完再 `step <= STEP_GT_INFO` 接回原链。
                STEP_CFG: begin
                    step   <= STEP_CFG;
                    rdy_to <= 20'd0;
                end
                default: begin
                    step   <= STEP_GT_PB;
                    rdy_to <= 20'd100_000;
                end
                endcase
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
