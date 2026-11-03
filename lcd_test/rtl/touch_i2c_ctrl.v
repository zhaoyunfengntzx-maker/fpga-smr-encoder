// -----------------------------------------------------------------------------
//  lcd_test/rtl/touch_i2c_ctrl.v
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
    output reg  [7:0]   int_low_cnt        // INT 为低的采样计数（24 位会被截断，仅看趋势）
);

    // ------------------------------------------------------------- 常量
    localparam [6:0] ADDR_GT = 7'h5D;
    localparam [6:0] ADDR_FT = 7'h38;

    localparam [2:0] STEP_GT_PB  = 3'd0,   // 探测 GT911：读 0x814E
                     STEP_FT_PB  = 3'd1,   // 探测 FT5206：读 0x02
                     STEP_FT_PB2 = 3'd2,   // 探测 FT5206：读 0x03（确认坐标区）
                     STEP_LOOP   = 3'd3,   // 正式轮询 GT911：0x814E 起读 6 字
                     STEP_FT_RD  = 3'd4,   // 正式轮询 FT5206：0x03 起读 4 字
                     STEP_CLR    = 3'd5,   // GT911 清中断：写 0x814E = 0
                     STEP_GT_ID  = 3'd6,   // 读 GT911 产品 ID（0x8140 起 4 字节）
                     STEP_GT_INFO= 3'd7;   // 读 GT911 固件版本 + X/Y 分辨率（0x8144 起 6 字节）

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
        .sda_oe    (sda_oe)
    );

    // ------------------------------------------------------------- 状态
    reg [2:0]  state;
    reg [2:0]  step;
    reg [1:0]  mode;
    reg [24:0] slow_cnt;      // SLOW 模式重探
    reg [19:0] rdy_to;        // 探测/轮询之间的稳定期
    reg [7:0]  gt_status, ft_status;
    reg        int_low;

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
            // GT911：从 0x814E 起读 26 字节 = 状态字 b0 + 5 个点，每点 **5 字节**
            //        {track id, X 低, X 高(仅低 4 位有效), Y 低, Y 高(仅低 4 位有效)}
            // 主机把**先收到的字节放低位**：d_k = {b(2k+1), b(2k)}。于是字节下标
            //   b0=status, b1=tid0, b2=X0L, b3=X0H, b4=Y0L, b5=Y0H, b6=tid1, ...
            // 偶数点落在字内（X=字的高/低字节），奇数点**跨字**（X 低字节是上一个字的高字节）。
            // ★ 曾经的错误：按 d1..d5 逐字取 [13:8]/[7:0]，等于假设每点 4 字节且字对齐 ——
            //   点 1 及以后全部错位（实测 x1 = 0x0402 而非 0x384）。
            nnum = (gt_num > 4'd5) ? 3'd5 : gt_num[2:0];
            // 点 0：X = {X0H[3:0], X0L}，X0L = b2 = d1[7:0]，X0H = b3 = d1[15:8]
            nx0 = {4'd0, d1[11:8], d1[7:0]};
            ny0 = {4'd0, d2[11:8], d2[7:0]};
            // 点 1：X1L = b7 = d3[15:8]，X1H = b8 = d4[7:0]；Y1L = b9 = d4[15:8]，Y1H = b10 = d5[7:0]
            nx1 = {4'd0, d4[3:0], d3[15:8]};
            ny1 = {4'd0, d5[3:0], d4[15:8]};
            // 点 2：X2L = b12 = d6[7:0]，X2H = b13 = d6[15:8]
            nx2 = {4'd0, d6[11:8], d6[7:0]};
            ny2 = {4'd0, d7[11:8], d7[7:0]};
            // 点 3：X3L = b17 = d8[15:8]，X3H = b18 = d9[7:0]
            nx3 = {4'd0, d9[3:0], d8[15:8]};
            ny3 = {4'd0, d10[3:0], d9[15:8]};
            // 点 4：X4L = b22 = d11[7:0]，X4H = b23 = d11[15:8]
            nx4 = {4'd0, d11[11:8], d11[7:0]};
            ny4 = {4'd0, d12[11:8], d12[7:0]};
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
                       step == STEP_GT_INFO ||
                       step == STEP_GT_ID)                     ? 2'd2 :
                      (step == STEP_CLR)                       ? 2'd3 : 2'd1;
    assign m_addr   = (step == STEP_FT_PB || step == STEP_FT_PB2 || step == STEP_FT_RD)
                      ? ADDR_FT : ADDR_GT;
    assign m_tx1    = (step == STEP_FT_PB || step == STEP_FT_PB2) ? 8'h02 :
                      (step == STEP_FT_RD)                        ? 8'h03 : 8'h81;
    assign m_tx2    = (step == STEP_GT_ID)   ? 8'h40 :
                      (step == STEP_GT_INFO) ? 8'h44 : 8'h4E;
    assign m_tx3    = 8'h00;
    // ★ LOOP = 13 个 16bit 字 = 26 字节 = 0x814E 状态字 + 5 个点 × 5 字节
    //   （主机读缓冲已扩到 32 字节，见 i2c_master_seq.v 的 rd_buf/rd_data8..15）
    assign m_rdw    = (step == STEP_GT_PB)  ? 4'd1 :
                      (step == STEP_FT_PB)  ? 4'd1 :
                      (step == STEP_FT_PB2) ? 4'd2 :
                      (step == STEP_LOOP)   ? 4'd13 :
                      (step == STEP_GT_ID)  ? 4'd2 :
                      (step == STEP_GT_INFO)? 4'd3 :
                      (step == STEP_FT_RD)  ? 4'd4 : 4'd1;

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
        end
        else begin
            // ------------------------------------------------ INT 采样（仅统计）
            int_low <= ~int_n_i;
            if (~int_n_i) int_low_cnt <= int_low_cnt + 8'd1;

            case (state)
            // ------------------------------------------------------ 发请求
            ST_IDLE: begin
                if (rdy_to != 20'd0) begin
                    rdy_to <= rdy_to - 20'd1;
                end
                else if (mode != 2'd0) begin
                    m_req <= 1'b1;
                    state <= ST_REQ;
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
                        if (step == STEP_LOOP) gt_status_raw <= d0[7:0];
                        // 0x8144 起 6 字节 = 固件版本(2B) + X 输出上限(2B) + Y 输出上限(2B)。
                        // 字节序：先收到的字节落在低位，所以 d1 = {0x8147(高), 0x8146(低)}，
                        // 它本身就已经是 Little-Endian 的分辨率（1024=0x0400 / 600=0x0258），
                        // 直接用即可。★ 曾经在这里多写一次字节交换，真的 1024 被解成 4。
                        if (step == STEP_GT_INFO) begin
                            gt_xmax <= d1;
                            gt_ymax <= d2;
                        end
                        if (step == STEP_LOOP || step == STEP_FT_RD) begin
                            tch_num    <= nnum;
                            tch_x0 <= nx0; tch_y0 <= ny0;
                            tch_x1 <= nx1; tch_y1 <= ny1;
                            tch_x2 <= nx2; tch_y2 <= ny2;
                            tch_x3 <= nx3; tch_y3 <= ny3;
                            tch_x4 <= nx4; tch_y4 <= ny4;
                            tch_valid  <= (nnum != 3'd0);
                            tch_toggle <= ~tch_toggle;
                            if (nnum != 3'd0) stat_touch <= stat_touch + 24'd1;
                        end
                    end
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
                    step   <= STEP_CLR;              // GT911 必须清状态标记
                    rdy_to <= 20'd0;
                end
                // GT911 产品 ID：0x8140 起 4 字节 = '9' '1' '1' + 版本。
                // 读到 0x39 说明"确实是 GT911 在应答、而且读回的是真数据"；
                // 读到 0x00/0xFF 说明总线被拉死或器件没在上电工作状态。
                STEP_GT_ID: begin
                    prod_id <= d0[7:0];
                    step    <= STEP_GT_INFO;         // 顺手把分辨率读回来（诊断）
                    rdy_to  <= 20'd100_000;          // 2ms
                end
                // 固件版本 + X/Y 分辨率：只读一次，用来判断芯片的配置是否真的加载了
                STEP_GT_INFO: begin
                    step    <= STEP_LOOP;
                    rdy_to  <= 20'd100_000;          // 2ms
                end
                STEP_CLR: begin
                    step   <= STEP_LOOP;
                    rdy_to <= 20'd250_000;           // 5ms
                end
                STEP_FT_RD: begin
                    step   <= STEP_FT_RD;
                    rdy_to <= 20'd250_000;           // 5ms（FT 不用清标记）
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
