// -----------------------------------------------------------------------------
//  lcd_test2/rtl/lcd_test2_top.v
//  LCD 屏幕测试程序（第二版）—— 顶层
//
//  硬件（与第一版 lcd_test/ 完全相同，引脚账来自《达芬奇-lite 之 FPGA 开发指南》表 2.1.1）：
//    板子     正点原子达芬奇-lite（xc7a35tfgg484-2），RGB 屏接口 = 板上 J7
//    屏       正点原子 ATK-7016 系列，7 寸 1024x600 IPS 电容屏（触摸 IC GT911）
//    像素时钟 50MHz（= 板载 sys_clk，不需要 MMCM）
//
//  功能（需求书见 docs/LCD_test_program_requirements.md）：
//    F1 标准色轮播  8 色满屏，约 1.0 s/色，四角小字给出色名/RGB/帧计数
//    F2 触摸点位    1024×600 的 64px 网格 + 每 128px 坐标数字 + 信息面板
//    F3 实时反馈    触点处彩色准星（十字+方框）跟随，抬手后保留约 0.5 s
//    F4 模式切换    板载 KEY（W9）短按切 F1 ↔ F2/F3；长按（≥1 s）暂停
//    F5 串口遥测    115200 8N1，每秒一帧 26 字节（协议 v3）
//    F6 触摸按需读  只读状态字 0x814E；bit7=0 时不读点位数据（见 touch_i2c_ctrl.v）
//
//  ★ 与第一版一样，lcd_rgb 是 24 根双向线：读屏 ID 期间 data_oe=0（全高阻），
//    之后 data_oe=1 驱动像素数据 —— 综合成 24 个 IOBUF。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module lcd_test2_top (
    input  wire        sys_clk,       // 50MHz，引脚 V4（Bank 34）
    input  wire        key_n,         // 板载按键，按下为 0（W9）

    output wire        uart_tx,       // W21

    // ---------------- 到 J7 的 LCD 接口 ----------------
    inout  wire [23:0] lcd_rgb,       // 高位 R、中位 G、低位 B（RGB888）
    output wire        lcd_pclk,      // U1
    output wire        lcd_hs,        // AB2
    output wire        lcd_vs,        // T1
    output wire        lcd_de,        // W2
    output wire        lcd_bl,        // Y2，高电平点亮
    output wire        lcd_rst,       // R2，低电平复位

    // ---------------- 到触摸 IC 的 IIC ----------------
    inout  wire        touch_scl,     // T4
    inout  wire        touch_sda,     // U5
    output wire        touch_rst_n,   // W4
    inout  wire        touch_int      // T5（复位期间拉低，之后释放并靠内部上拉）
);

    // ================================================================ 复位
    wire rst_n;          // 测试逻辑复位：只受上电延迟控制（约 10.5 ms）
    wire id_rst_n;       // 读 ID 模块产生的面板复位（读 ID 期间保持复位）
    wire lcd_rst_n;      // 送给面板/触摸 IC 的复位

    lcd_rst_sync #(.POR_CYCLES(19'd524287)) u_por (
        .clk   (sys_clk),
        .key_n (1'b1),
        .rst_n (rst_n)
    );

    // ============================================================ 按键（F4）
    wire key_state, key_press, key_long;
    wire mode, paused;

    key_ctrl #(
        .DB_CYCLES   (20'd500_000),        // 消抖 10 ms
        .LONG_CYCLES (27'd50_000_000)      // 长按阈值 1 s
    ) u_key (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .key_n      (key_n),
        .mode       (mode),
        .paused     (paused),
        .press      (key_press),
        .long_press (key_long),
        .key_state  (key_state)
    );

    // ============================================================ 屏 ID 读取
    wire       data_oe;
    wire [2:0] panel_id;
    wire       id_valid;

    lcd_panel_id_read #(.RD_CYCLES(23'd2_097_151)) u_id (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .lcd_r7   (lcd_rgb[7]),
        .lcd_g7   (lcd_rgb[15]),
        .lcd_b7   (lcd_rgb[23]),
        .data_oe  (data_oe),
        .lcd_rst_n(id_rst_n),
        .panel_id (panel_id),
        .id_valid (id_valid)
    );

    assign lcd_rst_n = id_rst_n;

    // ============================================================ 时序参数
    // ATK-7016 / 7084 / 4384 取自《达芬奇-lite 之 FPGA 开发指南》13.1 节；
    // 4342 / 1018 用标准 VESA 时序兜底（本程序目标屏是 7016）。
    reg [11:0] p_h_sync, p_h_back, p_h_disp, p_h_front;
    reg [11:0] p_v_sync, p_v_back, p_v_disp, p_v_front;
    reg [3:0]  p_ce_div;

    always @(*) begin
        case (panel_id)
        3'b000: begin   // ATK-4342 4.3" 480x272，PCLK 12.5MHz
            p_h_sync = 12'd41;  p_h_back = 12'd43;  p_h_disp = 12'd480;  p_h_front = 12'd8;
            p_v_sync = 12'd10;  p_v_back = 12'd12;  p_v_disp = 12'd272;  p_v_front = 12'd8;
            p_ce_div = 4'd4;
        end
        3'b001: begin   // ATK-7084 7" 800x480，PCLK 25MHz
            p_h_sync = 12'd128; p_h_back = 12'd88;  p_h_disp = 12'd800;  p_h_front = 12'd40;
            p_v_sync = 12'd2;   p_v_back = 12'd33;  p_v_disp = 12'd480;  p_v_front = 12'd10;
            p_ce_div = 4'd2;
        end
        3'b100: begin   // ATK-4384 4.3" 800x480，PCLK 25MHz
            p_h_sync = 12'd128; p_h_back = 12'd88;  p_h_disp = 12'd800;  p_h_front = 12'd40;
            p_v_sync = 12'd2;   p_v_back = 12'd33;  p_v_disp = 12'd480;  p_v_front = 12'd10;
            p_ce_div = 4'd2;
        end
        3'b101: begin   // ATK-1018 10.1" 1280x800，PCLK 50MHz
            p_h_sync = 12'd10;  p_h_back = 12'd80;  p_h_disp = 12'd1280; p_h_front = 12'd70;
            p_v_sync = 12'd3;   p_v_back = 12'd10;  p_v_disp = 12'd800;  p_v_front = 12'd10;
            p_ce_div = 4'd1;
        end
        default: begin  // 010 = ATK-7016 7" 1024x600（目标屏）
            p_h_sync = 12'd20;  p_h_back = 12'd140; p_h_disp = 12'd1024; p_h_front = 12'd160;
            p_v_sync = 12'd3;   p_v_back = 12'd20;  p_v_disp = 12'd600;  p_v_front = 12'd12;
            p_ce_div = 4'd1;
        end
        endcase
    end

    // 像素使能：50MHz / p_ce_div（用使能而不是分频时钟，全部逻辑留在单一时钟域）
    reg [3:0] ce_cnt;
    wire      pixel_en;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) ce_cnt <= 4'd0;
        else if (ce_cnt == p_ce_div - 4'd1) ce_cnt <= 4'd0;
        else ce_cnt <= ce_cnt + 4'd1;
    end
    assign pixel_en = (p_ce_div <= 4'd1) ? 1'b1 : (ce_cnt == p_ce_div - 4'd1);

    // ============================================================ 时序发生器
    wire [11:0] pix_x, pix_y;
    wire        lcd_de_i, frame_st, line_st;
    wire        lcd_hs_i, lcd_vs_i;

    lcd_timing_gen u_tmg (
        .clk_pix  (sys_clk),
        .rst_n    (rst_n),
        .pixel_en (pixel_en),
        .h_sync   (p_h_sync),  .h_back (p_h_back),
        .h_disp   (p_h_disp),  .h_front(p_h_front),
        .v_sync   (p_v_sync),  .v_back (p_v_back),
        .v_disp   (p_v_disp),  .v_front(p_v_front),
        .lcd_hs   (lcd_hs_i),
        .lcd_vs   (lcd_vs_i),
        .lcd_de   (lcd_de_i),
        .pix_x    (pix_x),
        .pix_y    (pix_y),
        .frame_st (frame_st),
        .line_st  (line_st)
    );

    wire frame_tick = frame_st;     // 每帧一个脉冲，用来做 1 秒门控

    // ======================================================== 触摸 INT 上电时序
    // GT911 的 INT 是开漏输出：① RST 低期间 INT 保持低（器件地址在 RST 上升沿
    // 按 INT 电平锁存，低 = 0x5D）；② RST 释放后 INT 再保持低约 50ms；
    // ③ 之后必须能回到高电平。模块 FPC 上不一定有 INT 上拉，本工程在 XDC 里给
    // touch_int 开了内部弱上拉（PULLTYPE PULLUP）。
    reg [21:0] int_hold_cnt;                  // 50ms @50MHz = 2_500_000
    wire       int_hold = (lcd_rst_n == 1'b0) || (int_hold_cnt < 22'd2_500_000);
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)                            int_hold_cnt <= 22'd0;
        else if (lcd_rst_n == 1'b0)            int_hold_cnt <= 22'd0;
        else if (int_hold_cnt < 22'd2_500_000) int_hold_cnt <= int_hold_cnt + 22'd1;
    end
    assign touch_int = int_hold ? 1'b0 : 1'bz;
    wire   int_pin   = touch_int;             // 释放后读回真实电平（遥测上报）

    // ============================================================== IIC 触摸
    wire scl_oe, sda_oe, scl_line, sda_line;

    i2c_io_wrap u_io (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .scl_oe (scl_oe),
        .sda_oe (sda_oe),
        .scl_o  (scl_line),
        .sda_o  (sda_line),
        .scl_io (touch_scl),
        .sda_io (touch_sda)
    );

    wire        tch_valid, tch_toggle;
    wire [1:0]  tch_type;
    wire [2:0]  tch_num;
    wire [15:0] tch_x0, tch_y0, tch_x1, tch_y1, tch_x2, tch_y2,
                tch_x3, tch_y3, tch_x4, tch_y4;
    wire [23:0] stat_reads, stat_nack, stat_timeout, stat_touch;
    wire [7:0]  rst_cnt, probe_gt, probe_ft, int_low_cnt, prod_id;
    wire [7:0]  gt_status_raw;
    wire [15:0] touch_dbg;                 // {4'd0, step, IIC主机state, IIC主机busy, 触摸state}
    wire [15:0] gt_xmax, gt_ymax;

    touch_i2c_ctrl u_touch (
        .clk           (sys_clk),
        .rst_n         (lcd_rst_n),
        .scl_i         (scl_line),
        .scl_oe        (scl_oe),
        .sda_i         (sda_line),
        .sda_oe        (sda_oe),
        .int_n_i       (int_pin),
        .tch_valid     (tch_valid),
        .tch_toggle    (tch_toggle),
        .tch_type      (tch_type),
        .tch_num       (tch_num),
        .tch_x0        (tch_x0), .tch_y0 (tch_y0),
        .tch_x1        (tch_x1), .tch_y1 (tch_y1),
        .tch_x2        (tch_x2), .tch_y2 (tch_y2),
        .tch_x3        (tch_x3), .tch_y3 (tch_y3),
        .tch_x4        (tch_x4), .tch_y4 (tch_y4),
        .stat_reads    (stat_reads),
        .stat_nack     (stat_nack),
        .stat_timeout  (stat_timeout),
        .stat_touch    (stat_touch),
        .rst_cnt       (rst_cnt),
        .probe_gt      (probe_gt),
        .probe_ft      (probe_ft),
        .prod_id       (prod_id),
        .gt_status_raw (gt_status_raw),
        .gt_xmax       (gt_xmax),
        .gt_ymax       (gt_ymax),
        .int_low_cnt   (int_low_cnt),
        .dbg           (touch_dbg)
    );

    assign touch_rst_n = lcd_rst_n;

    // ============================================================ 画面生成
    wire [23:0] pixel_data;
    wire [2:0]  color_idx;
    wire [2:0]  disp_num;
    wire [23:0] frame_cnt;

    screen_pattern u_pat (
        .clk           (sys_clk),
        .rst_n         (rst_n),
        .de            (lcd_de_i),
        .pix_x         (pix_x),
        .pix_y         (pix_y),
        .frame_st      (frame_tick),
        .mode          (mode),
        .paused        (paused),
        .tch_valid     (tch_valid),
        .tch_type      (tch_type),
        .tch_num       (tch_num),
        .tch_x0        (tch_x0), .tch_y0 (tch_y0),
        .tch_x1        (tch_x1), .tch_y1 (tch_y1),
        .tch_x2        (tch_x2), .tch_y2 (tch_y2),
        .tch_x3        (tch_x3), .tch_y3 (tch_y3),
        .tch_x4        (tch_x4), .tch_y4 (tch_y4),
        .gt_status_raw (gt_status_raw),
        .int_n         (int_pin),
        .pixel_data    (pixel_data),
        .color_idx     (color_idx),
        .disp_num      (disp_num),
        .frame_cnt     (frame_cnt)
    );

    // ============================================================ 输出引脚
    assign lcd_pclk = sys_clk;
    assign lcd_hs   = lcd_hs_i;
    assign lcd_vs   = lcd_vs_i;
    assign lcd_de   = lcd_de_i;
    assign lcd_bl   = 1'b1;              // 背光常亮（高电平点亮）
    assign lcd_rst  = lcd_rst_n;

    // 24 根双向数据线：读 ID 期间全高阻，之后驱动像素数据（综合成 24 个 IOBUF）
    genvar gi;
    generate
        for (gi = 0; gi < 24; gi = gi + 1) begin : g_rgb
            assign lcd_rgb[gi] = data_oe ? pixel_data[gi] : 1'bz;
        end
    endgenerate

    // ============================================================ 每秒门控
    reg [7:0]  sec_cnt;
    reg        sec_pulse;
    reg [15:0] reads_ps, err_ps;
    reg [15:0] reads_prev, err_prev;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_cnt    <= 8'd0;
            sec_pulse  <= 1'b0;
            reads_ps   <= 16'd0;
            err_ps     <= 16'd0;
            reads_prev <= 16'd0;
            err_prev   <= 16'd0;
        end else begin
            sec_pulse <= 1'b0;
            if (frame_tick) begin
                if (sec_cnt == 8'd58) begin        // 58.6 帧 ≈ 1.007 s
                    sec_cnt    <= 8'd0;
                    sec_pulse  <= 1'b1;
                    reads_ps   <= stat_reads[15:0] - reads_prev;
                    err_ps     <= (stat_nack[15:0] + stat_timeout[15:0]) - err_prev;
                    reads_prev <= stat_reads[15:0];
                    err_prev   <= stat_nack[15:0] + stat_timeout[15:0];
                end else begin
                    sec_cnt <= sec_cnt + 8'd1;
                end
            end
        end
    end

    // ============================================================ UART 遥测 v3
    // 26 字节定长帧，字段表见 docs/LCD_test_program_readme.md
    wire [7:0] id_bits = {id_valid, 2'b00,
                          (panel_id == 3'b101), (panel_id == 3'b001),
                          (panel_id == 3'b010), (panel_id == 3'b100),
                          (panel_id == 3'b000)};

    uart_frame_sender26 u_uart (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .send  (sec_pulse),
        // 0..3：帧头 + 版本 + 屏 ID
        .w0    ({8'hA5, 8'h4C, 8'h03, id_bits}),
        // 4..7：模式 / 暂停 / 触摸型号 / 触摸是否锁定
        //   ★ 2026-10-15：byte4/5/6 原来全是空位（mode 只占 1bit、paused 1bit、
        //     tch_type 2bit），把触摸模块状态机的 state/step 和 IIC 主机 state/busy
        //     塞进空位里上报。这样"触摸卡死"这类问题不用再猜——直接看遥测就知道
        //     卡在哪个状态。字段位定义见 docs/LCD_test_program_readme.md §5。
        //     byte4 = {state[2:0], step[3:0], mode}        ← dbg[2:0] / dbg[11:8] / mode
        //     byte5 = {6'd0, m_busy, paused}
        //     byte6 = {2'd0, m_state[3:0], tch_type[1:0]}  ← dbg[7:4]
        .w1    ({touch_dbg[2:0], touch_dbg[11:8], mode,
                 6'd0, touch_dbg[3], paused,
                 2'd0, touch_dbg[7:4], tch_type,
                 7'd0, tch_valid}),
        // 8..11：点数 / 状态字 / 标准色序号 / 帧计数高字节
        .w2    ({5'd0, tch_num, gt_status_raw, 5'd0, color_idx, frame_cnt[23:16]}),
        // 12..15：帧计数低两字节 + 第 1 点 X
        .w3    ({frame_cnt[15:8], frame_cnt[7:0], tch_x0[15:8], tch_x0[7:0]}),
        // 16..19：第 1 点 Y + 第 2 点 X
        .w4    ({tch_y0[15:8], tch_y0[7:0], tch_x1[15:8], tch_x1[7:0]}),
        // 20..23：第 2 点 Y + 每秒 IIC 轮询次数
        .w5    ({tch_y1[15:8], tch_y1[7:0], reads_ps[15:8], reads_ps[7:0]}),
        // 24..25：每秒 IIC 错误次数（26/27 字节不发送，留作尾标记）
        .w6    ({err_ps[15:8], err_ps[7:0], 8'h5A, 8'h00}),
        .tx    (uart_tx),
        .busy  ()
    );

endmodule
