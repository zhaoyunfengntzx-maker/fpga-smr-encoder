// -----------------------------------------------------------------------------
//  lcd_test/rtl/lcd_rgb_test_top.v
//  7 寸 RGB-LCD 屏 + 电容触摸基本性能测试 —— 顶层
//
//  硬件前提（已核对，见 docs/RGB_LCD_wiring_check.md）：
//    板子     正点原子达芬奇-lite（xc7a35tfgg484-2），RGB 屏接口 = 板上 J7
//    屏       正点原子 ATK-7016 系列，7 寸 1024x600 IPS 电容屏，40P 0.5mm FPC
//    像素时钟 50MHz（= 板载 sys_clk，不需要 MMCM，像素使能恒 1 即可）
//    背光     lcd_bl 高电平点亮
//
//  这个小工程做什么（与既有编码器工程完全隔离，只借用它的引脚号）：
//    1) 上电先让 24 根 RGB 数据线呈高阻，读回屏 ID（R7/G7/B7 被模块的 ID 电阻
//       分压成高低），据此选时序 —— FPGA 没有别的办法"问"出屏幕型号
//    2) 之后 lcd_timing_gen 产生 DE 模式时序，lcd_test_pattern 产生 10 幅测试画面
//    3) IIC 主机（在 touch_i2c_ctrl 内部）探测并轮询电容触摸 IC：
//       GT911（0x5D，状态 0x814E）或 FT5x06（0x38，状态 0x02）
//    4) 每秒把画面号/触摸 IC/点数/第 1 点坐标/IIC 传输与错误次数经 UART 115200
//       发一帧 16 字节遥测，便于用电脑量化，而不是只靠肉眼看
//
//  按键：板载 KEY（W9）短按切画面；按住约 0.6s 会复位 LCD 与触摸 IC（硬复位）。
//
//  ★ 数据线方向：lcd_rgb 是 24 根双向线（因为同时挂着 ID 电阻）。
//    读 ID 期间 data_oe=0 => 全部高阻；之后 data_oe=1 => 驱动像素数据。
//    数据输出用 always @(*) + 先赋 0 再按位赋 1 的写法，等价于 24 个三态门。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module lcd_rgb_test_top (
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
    inout  wire        touch_int      // T5（复位期间由 FPGA 拉低，之后释放并靠内部上拉）
);

    // =========================================================== 复位 / 按键
    //  rst_n     只受上电延迟控制（测试程序自己的复位）
    //  lcd_rst_n 还叠加板载按键，用来硬复位 LCD 面板与触摸 IC
    wire rst_n;          // 测试逻辑复位：只受上电延迟控制
    wire key_rst_n;      // 板载按键复位链的输出
    wire id_rst_n;       // 读 ID 模块自己产生的面板复位（读 ID 期间保持复位）
    wire lcd_rst_n;      // ★ 最终送给面板/触摸 IC 的复位 = 两者相与（任一拉低即复位）
                         //   （原来 u_por_lcd 与 u_id 同时驱动这一根线，仿真里会变成 X）

    lcd_rst_sync #(.POR_CYCLES(19'd524287)) u_por (
        .clk   (sys_clk),
        .key_n (1'b1),
        .rst_n (rst_n)
    );

    lcd_rst_sync #(.POR_CYCLES(19'd524287)) u_por_lcd (
        .clk   (sys_clk),
        .key_n (key_n),
        .rst_n (key_rst_n)
    );

    wire key_state, key_press, key_release, key_long;
    key_debounce u_key (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .key_n      (key_n),
        .key_state  (key_state),
        .press      (key_press),
        .release_evt(key_release),
        .long_press (key_long)
    );

    reg pat_adv;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) pat_adv <= 1'b0;
        else        pat_adv <= key_press;      // 短按切下一幅画面
    end

    // =========================================================== 屏 ID 读取
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

    assign lcd_rst_n = id_rst_n & key_rst_n;

    // ============================================================ 时序参数
    // ATK-7016 / 7084 / 4384 的时序取自《达芬奇-lite 之 FPGA 开发指南》13.1 节；
    // 4342 / 1018 用标准 VESA 时序兜底（本工程的目标屏是 7016，其余只为"插错屏
    // 也能点亮"而准备，不追求精确刷新率）。
    reg [11:0] p_h_sync, p_h_back, p_h_disp, p_h_front;
    reg [11:0] p_v_sync, p_v_back, p_v_disp, p_v_front;
    reg [3:0]  p_ce_div;

    always @(*) begin
        case (panel_id)
        // 000 -> ATK-4342 4.3" 480x272，PCLK 12.5MHz
        3'b000: begin
            p_h_sync = 12'd41;  p_h_back = 12'd43;  p_h_disp = 12'd480;
            p_h_front= 12'd8;
            p_v_sync = 12'd10;  p_v_back = 12'd12;  p_v_disp = 12'd272;
            p_v_front= 12'd8;
            p_ce_div = 4'd4;
        end
        // 001 -> ATK-7084 7" 800x480，PCLK 25MHz
        3'b001: begin
            p_h_sync = 12'd128; p_h_back = 12'd88;  p_h_disp = 12'd800;
            p_h_front= 12'd40;
            p_v_sync = 12'd2;   p_v_back = 12'd33;  p_v_disp = 12'd480;
            p_v_front= 12'd10;
            p_ce_div = 4'd2;
        end
        // 100 -> ATK-4384 4.3" 800x480，PCLK 25MHz
        3'b100: begin
            p_h_sync = 12'd128; p_h_back = 12'd88;  p_h_disp = 12'd800;
            p_h_front= 12'd40;
            p_v_sync = 12'd2;   p_v_back = 12'd33;  p_v_disp = 12'd480;
            p_v_front= 12'd10;
            p_ce_div = 4'd2;
        end
        // 101 -> ATK-1018 10.1" 1280x800，PCLK 50MHz
        3'b101: begin
            p_h_sync = 12'd10;  p_h_back = 12'd80;  p_h_disp = 12'd1280;
            p_h_front= 12'd70;
            p_v_sync = 12'd3;   p_v_back = 12'd10;  p_v_disp = 12'd800;
            p_v_front= 12'd10;
            p_ce_div = 4'd1;
        end
        // 010（ATK-7016 7" 1024x600，本工程目标屏）与未识别值
        default: begin
            p_h_sync = 12'd20;  p_h_back = 12'd140; p_h_disp = 12'd1024;
            p_h_front= 12'd160;
            p_v_sync = 12'd3;   p_v_back = 12'd20;  p_v_disp = 12'd600;
            p_v_front= 12'd12;
            p_ce_div = 4'd1;
        end
        endcase
    end

    // 像素使能：50MHz / p_ce_div。用使能而不是分频时钟，全部逻辑留在 50MHz 单域
    // （分频时钟是非全局衍生时钟，要额外 BUFG 且要做 CDC）。
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
        .h_sync   (p_h_sync),
        .h_back   (p_h_back),
        .h_disp   (p_h_disp),
        .h_front  (p_h_front),
        .v_sync   (p_v_sync),
        .v_back   (p_v_back),
        .v_disp   (p_v_disp),
        .v_front  (p_v_front),
        .lcd_hs   (lcd_hs_i),
        .lcd_vs   (lcd_vs_i),
        .lcd_de   (lcd_de_i),
        .pix_x    (pix_x),
        .pix_y    (pix_y),
        .frame_st (frame_st),
        .line_st  (line_st)
    );

    // ======================================================== 触摸 INT 上电时序
    // GT911 的 INT 是**开漏输出**，官方上电时序（Linux goodix.c 的 goodix_reset +
    // goodix_int_sync 就是这三步）：
    //   ① RST 拉低期间 INT 保持低电平 —— 器件地址在 RST 上升沿按 INT 电平锁存
    //      （低 = 0x5D，高 = 0x14；本板识别到的是 0x5D）
    //   ② RST 释放后 INT 再保持低约 50ms，让芯片把固件/配置装载完
    //   ③ 之后 INT 必须能回到高电平，芯片才用低脉冲表示"有数据就绪"
    // 第 ③ 步最容易漏：模块的 INT 在 FPC 上不一定有上拉电阻。本工程在
    // lcd_test.xdc 里给 touch_int 开了内部弱上拉（PULLTYPE PULLUP）。缺了它，
    // 开漏的 INT 会一直贴在低电平 —— 上板实测"产品 ID 能读、点数恒为 0"与此一致。
    reg [21:0] int_hold_cnt;                  // 50ms @50MHz = 2_500_000
    wire       int_hold = (lcd_rst_n == 1'b0) || (int_hold_cnt < 22'd2_500_000);
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)                            int_hold_cnt <= 22'd0;
        else if (lcd_rst_n == 1'b0)            int_hold_cnt <= 22'd0;
        else if (int_hold_cnt < 22'd2_500_000) int_hold_cnt <= int_hold_cnt + 22'd1;
    end
    assign touch_int = int_hold ? 1'b0 : 1'bz;
    wire   int_pin   = touch_int;             // 释放后读回真实电平（遥测上报）

    // ============================================================= IIC 触摸
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
    wire [15:0] gt_xmax, gt_ymax;

    touch_i2c_ctrl u_touch (
        .clk         (sys_clk),
        .rst_n       (lcd_rst_n),
        .scl_i       (scl_line),
        .scl_oe      (scl_oe),
        .sda_i       (sda_line),
        .sda_oe      (sda_oe),
        .int_n_i     (int_pin),
        .tch_valid   (tch_valid),
        .tch_toggle  (tch_toggle),
        .tch_type    (tch_type),
        .tch_num     (tch_num),
        .tch_x0      (tch_x0), .tch_y0 (tch_y0),
        .tch_x1      (tch_x1), .tch_y1 (tch_y1),
        .tch_x2      (tch_x2), .tch_y2 (tch_y2),
        .tch_x3      (tch_x3), .tch_y3 (tch_y3),
        .tch_x4      (tch_x4), .tch_y4 (tch_y4),
        .stat_reads  (stat_reads),
        .stat_nack   (stat_nack),
        .stat_timeout(stat_timeout),
        .stat_touch  (stat_touch),
        .rst_cnt     (rst_cnt),
        .probe_gt    (probe_gt),
        .probe_ft    (probe_ft),
        .prod_id     (prod_id),
        .gt_status_raw (gt_status_raw),
        .gt_xmax     (gt_xmax),
        .gt_ymax     (gt_ymax),
        .int_low_cnt (int_low_cnt)
    );

    assign touch_rst_n = lcd_rst_n;

    // ============================================================ 画面生成
    wire [23:0] pixel_data;
    wire [3:0]  pattern;

    // 每秒统计快照（在这里声明，因为画面模块实例要用到）
    reg [7:0]  sec_cnt;
    reg        sec_pulse;
    reg [15:0] reads_ps, err_ps, touch_ps;
    // 上一秒的累计值。stat_* 在触摸模块里只增不减，所以每秒上报的是"差值"
    // （否则读数是个一路涨到 65535 再回绕的累计量，不是每秒速率）。
    reg [15:0] reads_prev, err_prev, touch_prev;

    // 给画面模块的"探测中"指示：0=不在探测 1=正在试 GT911 2=正在试 FT5x05
    wire [7:0] probe_code = (tch_type == 2'd0) ? 8'd2 : 8'd0;

    lcd_test_pattern u_pat (
        .clk_pix    (sys_clk),
        .rst_n      (rst_n),
        .pix_x      (pix_x),
        .pix_y      (pix_y),
        .frame_st   (frame_st),
        .de         (lcd_de_i),
        .pat_adv    (pat_adv),
        .tch_type   (tch_type),
        .tch_valid  (tch_valid),
        .tch_num    (tch_num),
        .tch_x0     (tch_x0), .tch_y0 (tch_y0),
        .tch_x1     (tch_x1), .tch_y1 (tch_y1),
        .tch_x2     (tch_x2), .tch_y2 (tch_y2),
        .tch_x3     (tch_x3), .tch_y3 (tch_y3),
        .tch_x4     (tch_x4), .tch_y4 (tch_y4),
        .reads_ps   (reads_ps),
        .err_ps     (err_ps),
        .touch_ps   (touch_ps),
        .probe_code (probe_code),
        .frame_tick (frame_tick),
        .pattern    (pattern),
        .pixel_data (pixel_data)
    );

    // ============================================================ 输出引脚
    assign lcd_pclk = sys_clk;
    assign lcd_hs   = lcd_hs_i;
    assign lcd_vs   = lcd_vs_i;
    assign lcd_de   = lcd_de_i;
    assign lcd_bl   = 1'b1;              // 背光常亮（高电平点亮）
    assign lcd_rst  = lcd_rst_n;

    // 24 根双向数据线：用连续赋值写三态，综合成 24 个 IOBUF。
    // 写 ID 期间 data_oe = 0，全部高阻，由 LCD 模块上的 ID 电阻把 R7/G7/B7 拉成
    // 高/低/悬空可辨的电平。
    genvar gi;
    generate
        for (gi = 0; gi < 24; gi = gi + 1) begin : g_rgb
            assign lcd_rgb[gi] = data_oe ? pixel_data[gi] : 1'bz;
        end
    endgenerate

    // ============================================================ 每秒门控
    // frame_tick 每帧 1 个脉冲，58.6 帧/秒 => 计到 58 约 1.007 秒
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_cnt   <= 8'd0;
            sec_pulse <= 1'b0;
            reads_ps  <= 16'd0;
            err_ps    <= 16'd0;
            touch_ps  <= 16'd0;
            reads_prev <= 16'd0;
            err_prev   <= 16'd0;
            touch_prev <= 16'd0;
        end
        else begin
            sec_pulse <= 1'b0;
            if (frame_tick) begin
                if (sec_cnt == 8'd58) begin
                    sec_cnt   <= 8'd0;
                    sec_pulse <= 1'b1;
                    reads_ps  <= stat_reads[15:0] - reads_prev;
                    err_ps    <= (stat_nack[15:0] + stat_timeout[15:0]) - err_prev;
                    touch_ps  <= stat_touch[15:0] - touch_prev;
                    reads_prev <= stat_reads[15:0];
                    err_prev   <= stat_nack[15:0] + stat_timeout[15:0];
                    touch_prev <= stat_touch[15:0];
                end
                else sec_cnt <= sec_cnt + 8'd1;
            end
        end
    end

    // ============================================================ UART 遥测
    // ★ 这里必须是 8 位：曾经写成 {id_valid, 3'b000, 5 个型号命中位} = 9 位，
    //   赋给 8 位 wire 时最高位（id_valid）被静默丢掉，PC 侧永远看到
    //   "panel id valid = 0"（虽然型号位是对的）。改成 1+2+5 = 8 位。
    wire [7:0] id_bits = {id_valid, 2'b00,
                          (panel_id == 3'b101), (panel_id == 3'b001),
                          (panel_id == 3'b010), (panel_id == 3'b100),
                          (panel_id == 3'b000)};

    uart_frame_sender u_uart (
        .clk  (sys_clk),
        .rst_n(rst_n),
        .send (sec_pulse),
        .b0   (8'hA5),
        .b1   (8'h4C),                       // 'L' = LCD 测试程序
        .b2   (8'h02),                       // 协议版本 2（字段见 docs/LCD_touch_test_readme.md §7）
        .b3   (id_bits),
        // b4：bit6 = 触摸 INT 线电平、bit5 = IIC SDA 空闲电平、bit4 = IIC SCL 空闲电平、
        //     bit[3:0] = 当前画面号。空闲时 SDA/SCL 都应是 1；INT 释放后也应是 1
        //     （若恒为 0，说明模块没有 INT 上拉、或芯片一直把 INT 压住）。
        .b4   ({1'b0, int_pin, sda_line, scl_line, pattern}),
        .b5   ({tch_valid, 5'd0, tch_type}),
        .b6   (gt_status_raw),               // 0x814E 原始状态字：bit7=就绪 [3:0]=点数
        .b7   (prod_id),                     // GT911 产品 ID 首字节（0x39='9'）
        .b8   (tch_x0[15:8]),
        .b9   (tch_x0[7:0]),
        .b10  (tch_y0[15:8]),
        .b11  (tch_y0[7:0]),
        .b12  (gt_xmax[15:8]),               // 芯片内配置的 X 分辨率（7 寸屏应为 1024）
        .b13  (gt_xmax[7:0]),
        .b14  (gt_ymax[15:8]),               // 芯片内配置的 Y 分辨率（应为 600）
        .b15  (gt_ymax[7:0]),
        .tx   (uart_tx),
        .busy ()
    );

endmodule
