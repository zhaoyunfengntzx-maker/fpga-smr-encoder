// -----------------------------------------------------------------------------
//  disp/enc_top_disp.v —— 「编码器 + 显示屏引擎」合并实验顶层（v13 新增）
//
//  ★ 本文件存在的**唯一目的**是回答一个问题：
//      "把编码器（含 18.615 ns 的 cfg_ablimit→gap_num 组合链）和显示屏引擎
//       放进同一块 xc7a35t 之后，真实 WNS/WHS 还剩多少？"
//    这是一个**时序实验顶层**，不是最终交付形态。最终形态是把它作为
//    生成块或直接包进 enc_top（见 docs/13_display_ui_requirements.md 的 S2 阶段）。
//
//  ★ 与 enc_top 的关系：enc_top 一行逻辑都不改，只多了一个**只读**输出
//    `disp_tap[375:0]`（见 rtl/enc_top.v 端口声明处的位序契约；v21 追加了
//    幅值上下限两个门限字段，v22/C3 追加了链路心跳位 [375]，[374:0] 一位没动）。本文件
//    把 enc_top 原样例化，再挂三个新子模块：
//       u_lcd_timing : disp/lcd_timing_gen.v（lcd_test2/rtl/ 同名文件的副本，
//                      1024×600@58.6 Hz，DE 模式）
//       u_disp       : disp/disp_engine.v（像素流水线渲染器）
//       u_tap        : disp/enc_disp_tap.v（抽头总线 → 具名端口，纯连线）
//
//  ★ 目录纪律：本文件与新模块全部住在 `disp/`，不放 `rtl/`。
//    `rtl/` 是编码器本体的模块清单（rtl/SPEC_interface_contract.md 只有 20 个模块），
//    显示相关的新增代码一旦混进去，`rtl/` 的"单时钟域、零 MMCM、零 IP"
//    叙事和既有的 lint/pinout/spec 三套自查都会被稀释。
//    等架构定案（S2）再决定是"移入 rtl/"还是"做成可配 IP 风格子目录"。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module enc_top_disp (
    // ---- 与 enc_top 完全一致的板级接口 ----
    input  wire        sys_clk,          // 板载 50 MHz 晶振（V4）
    input  wire        key_n,            // 低有效用户按键 KEY0（W9）= 全局复位 + 一键标定
    input  wire        key1_n,           // 低有效用户按键 KEY1（Y9）= 页切换
    input  wire        ui_btn,           // 低有效页切换按键（J5-29 / H14，需外接跳线）

    output wire        ad_clk,           // AD9238 通道 1 时钟（J6-26 / B18）
    output wire        ad_clk2,          // AD9238 通道 2 时钟（J6-9  / F16）
    input  wire [11:0] ad_ch1_d,         // 通道 1 数据（sin）
    input  wire [11:0] ad_ch2_d,         // 通道 2 数据（cos）
    input  wire        ad_ch1_otr,
    input  wire        ad_ch2_otr,

    output wire        a_out, b_out, z_out,
    output wire        u_out, v_out, w_out,

    input  wire        spi_sck,
    input  wire        spi_ss_n,
    input  wire        spi_mosi,
    output wire        spi_miso,

    output wire [3:0]  led,

    output wire        uart_tx,
    input  wire        uart_rx,
    output wire        irq_n,

    // ---- 千兆以太网（B2，v60 起并入合并顶层）：YT8531C，RGMII ----
    //   ★ v59 之前这里没有这 7 个端口，enc_top 的 eth_* 全部悬空，
    //     板上 ping 不通是"必然"而不是"配置问题"（见 docs/21 §10.2）。
    //     v60 把端口补全、XDC 由 tools/gen_merged_xdc.py 从
    //     constr/enc_top_eth.xdc 合并（含 eth_rxc 时钟与输入输出延时）。
    output wire        phy_rst_n,        // V18
    output wire [3:0]  eth_txd,          // U17/U18/P14/R14
    output wire        eth_txc,          // AA18
    output wire        eth_tx_ctl,       // AB18
    input  wire [3:0]  eth_rxd,          // AA19/AB20/V17/W17
    input  wire        eth_rxc,          // Y18（PHY 提供的 125 MHz RX 时钟）
    input  wire        eth_rx_ctl,       // V19

    // ---- 7 寸 RGB-LCD（J7，与 lcd_test2 完全同名同序）----
    output wire [23:0] lcd_rgb,
    output wire        lcd_pclk,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_de,
    output wire        lcd_bl,
    output wire        lcd_rst,

    // ---- 电容触摸（J7 排线上的四根，与 lcd_test2 同名同序）----
    //   ★ 新增这四根端口会改变工具的"顶层端口清单"：
    //     - tools/pinout_verify.py 校验的是 **enc_top**，不是本文件，不受影响；
    //     - 但 tools/gen_merged_xdc.py 会按本文件的端口做覆盖检查，
    //       所以 XDC 里必须同时补上这四根的引脚与电气属性（见 TOUCH_PINS）。
    inout  wire        touch_scl,        // T4（开漏，模块侧有上拉）
    inout  wire        touch_sda,        // U5（开漏，模块侧有上拉）
    output wire        touch_rst_n,      // W4（低有效复位，与 lcd_rst 联动）
    inout  wire        touch_int,        // T5（开漏 + 内部弱上拉）

    // ---- 实验探针：显示引擎内部计数器（含帧计数），示波器可看 ----
    //   用板上 led[2] 与 led[3] 之外的 J5 空闲针输出，便于上板验证渲染器活着
    output wire [7:0]  disp_test
);

    // v68：64 周期/转的显示版把 RPM/累计转数按固定 64 电周期/转换算；
    // 不定义 ENC_V68_CPR64 时保持 0（沿用 cfg_pairs），v66/v62 显示不受影响。
`ifdef ENC_V68_CPR64
    localparam integer DISP_CPR = 64;
`elsif ENC_V69_CPR2048
    // v69：真实转台 2048 PPR（POLE_BITS=11），屏上 RPM/转数按 2048 电周期/转换算
    localparam integer DISP_CPR = 2048;
`else
    localparam integer DISP_CPR = 0;
`endif

    //=========================================================================
    // 1. 复位：key_n 是板上低有效按键，直接作为屏侧复位源
    //    ★ 这里**刻意不把复位恒接 1'b1**：恒接 1 会让综合器把 lcd_timing_gen /
    //      disp_engine 的复位逻辑整片常量折叠掉，量出来的 WNS 会比真实值乐观
    //      （少了复位网络、少了复位多路选择器）。本文件是用来量时序的，
    //      任何"让数字变好看"的简化都要拒绝。异步释放由同步器的第一级承担。
    //=========================================================================
    reg rst_meta = 1'b0, rst_sync = 1'b0;
    always @(posedge sys_clk or negedge key_n) begin
        if (!key_n) begin
            rst_meta <= 1'b0;
            rst_sync <= 1'b0;
        end else begin
            rst_meta <= 1'b1;
            rst_sync <= rst_meta;
        end
    end

    //=========================================================================
    // 2. 编码器（原样例化，只多接一根只读抽头）
    //=========================================================================
    wire [375:0] disp_tap;

    // ---- 层内 uart_rx 的所有权：屏要写寄存器时由 ui_edit 接管 ----
    //   ★ 一处 mux 解决"屏怎么改寄存器"，rtl/ 与两套 XDC 一行都不动。
    //     理由与命令格式见 disp/ui_edit.v 的头注释。
    //     物理引脚与 ui_edit 的发送线都"空闲为高"，所以不发送时等同直连；
    //     发送期间（ui_busy=1）把上位机的字节挡在外面，避免两个主机交错。
    wire ui_tx_line, ui_busy;
    // ---- v19：第二条写通道（W1C 清锁存）也走 mux，规则 = W1C 优先 ----
    //   两根 uart_tx 只能有一根上线。W1C 优先的理由：它的事务短（4 字节、不回读），
    //   而且是用户刚在屏上按下的动作，压后它会让"按了没反应"的窗口变长。
    //   互斥由请求侧保证：W1C 忙时主通道不接受新 req（见下面的 ui_req 门控）。
    wire w1c_tx_line, w1c_busy;
    // ---- v42（㊴）：第三条写通道（恢复默认的命令序列）也走 mux，优先级最高 ----
    //   它的 13 条命令必须**连续、不被打断**（中断会把一套默认值写了一半），
    //   而且总时长约 8.8 ms（13 x (20 µs 字节 + 500 µs 命令间隔) + 2 ms settle）；
    //   把它排在最前，代价是"用户按下恢复默认的那 8.8 ms 里上位机发不了命令"，
    //   与 docs/15 已有的说明同一类。
    wire rst_tx_line, rst_busy;
    wire enc_uart_rx = (rst_busy | ui_busy | w1c_busy)
                       ? (rst_busy ? rst_tx_line
                                   : (w1c_busy ? w1c_tx_line : ui_tx_line)) : uart_rx;

    enc_top u_enc (
        .sys_clk      (sys_clk),
        .key_n        (key_n),
        .ad_clk       (ad_clk),
        .ad_clk2      (ad_clk2),
        .ad_ch1_d     (ad_ch1_d),
        .ad_ch2_d     (ad_ch2_d),
        .ad_ch1_otr   (ad_ch1_otr),
        .ad_ch2_otr   (ad_ch2_otr),
        .a_out        (a_out),
        .b_out        (b_out),
        .z_out        (z_out),
        .u_out        (u_out),
        .v_out        (v_out),
        .w_out        (w_out),
        .spi_sck      (spi_sck),
        .spi_ss_n     (spi_ss_n),
        .spi_mosi     (spi_mosi),
        .spi_miso     (spi_miso),
        .led          (led),
        .uart_tx      (uart_tx),
        .uart_rx      (enc_uart_rx),
        .irq_n        (irq_n),
        .phy_rst_n    (phy_rst_n),
        .eth_txd      (eth_txd),
        .eth_txc      (eth_txc),
        .eth_tx_ctl   (eth_tx_ctl),
        .eth_rxd      (eth_rxd),
        .eth_rxc      (eth_rxc),
        .eth_rx_ctl   (eth_rx_ctl),
        .disp_tap     (disp_tap)
    );

    //=========================================================================
    // 3. 抽头解包
    //=========================================================================
    wire [15:0] tap_angle;
    wire [31:0] tap_pos_full;
    wire [15:0] tap_s_n, tap_c_n;
    wire [7:0]  tap_io_state, tap_io_flags, tap_stat;
    wire [9:0]  tap_inter;
    wire [2:0]  tap_div;
    wire [4:0]  tap_pairs;
    // v14：P6 设置页要显示"寄存器现在是什么"，v13 的抽头只有倍频/分频/极对数
    // 三个够用，其余六个从这里补（位序契约见 rtl/enc_top.v 的 disp_tap 注释）。
    wire [4:0]  tap_hyst_ab;
    wire [7:0]  tap_ablimit;
    wire [3:0]  tap_zwidth;
    wire [11:0] tap_zphase;
    wire [15:0] tap_uvwph;
    wire [3:0]  tap_pol;
    // v15：P7 标定页要显示"标定六参数现在是什么"与实测幅值 s²+c²。
    // 这七个量在 rtl/reg_file.v 里早就是既有端口，所以本轮没有新增寄存器、
    // 也没有改 reg_file.v —— 只是把已有的线接到抽头上（位序见 rtl/enc_top.v）。
    wire signed [15:0] tap_ofs_s, tap_ofs_c, tap_phase_k;
    wire        [15:0] tap_gain_s, tap_gain_c;
    wire        [3:0]  tap_shift;
    wire        [31:0] tap_amp_sq;
    // v21：P7 的幅值百分比要"相对编码器自己的判据门限"，所以抽头多引两个门限。
    // 同样没有新增寄存器、没有改 reg_file.v —— 两个都是既有 cfg_* 寄存器直出。
    wire        [31:0] tap_amp_low_sq, tap_amp_high_sq;
    wire        tap_abzen, tap_uwven, tap_calib_busy, tap_calib_done;
    wire        tap_link_crc_err, tap_otr_lat, tap_amp_bad, tap_lag_bad;
    wire        tap_limiter, tap_z_window, tap_uvw_freq_warn;
    wire        tap_link_lost;      // v74：恒 0 的保留位（位图不重排）

    enc_disp_tap u_tap (
        .disp_tap       (disp_tap),
        .angle          (tap_angle),
        .pos_full       (tap_pos_full),
        .s_n            (tap_s_n),
        .c_n            (tap_c_n),
        .io_state       (tap_io_state),
        .io_flags       (tap_io_flags),
        .stat           (tap_stat),
        .cfg_inter      (tap_inter),
        .cfg_div        (tap_div),
        .cfg_pairs      (tap_pairs),
        .cfg_hyst_ab    (tap_hyst_ab),
        .cfg_ablimit    (tap_ablimit),
        .cfg_zwidth     (tap_zwidth),
        .cfg_zphase     (tap_zphase),
        .cfg_uvwph      (tap_uvwph),
        .cfg_pol        (tap_pol),
        .cfg_ofs_s      (tap_ofs_s),
        .cfg_ofs_c      (tap_ofs_c),
        .cfg_gain_s     (tap_gain_s),
        .cfg_gain_c     (tap_gain_c),
        .cfg_phase_k    (tap_phase_k),
        .cfg_shift      (tap_shift),
        .stat_amp_sq    (tap_amp_sq),
        .amp_low_sq     (tap_amp_low_sq),
        .amp_high_sq    (tap_amp_high_sq),
        .cfg_abzen      (tap_abzen),
        .cfg_uwven      (tap_uwven),
        .calib_busy     (tap_calib_busy),
        .calib_done     (tap_calib_done),
        .link_crc_err   (tap_link_crc_err),
        .otr_lat        (tap_otr_lat),
        .amp_bad        (tap_amp_bad),
        .lag_bad        (tap_lag_bad),
        .limiter_active (tap_limiter),
        .z_window       (tap_z_window),
        .uvw_freq_warn  (tap_uvw_freq_warn),
        .link_lost      (tap_link_lost)
    );

    //=========================================================================
    // 4. LCD 时序发生器（1024×600，ATK-7016，DE 模式，像素时钟 = sys_clk 50 MHz）
    //    ★ 之所以不需要 MMCM：ATK-7016 要求的像素时钟正好是 50 MHz，与板载
    //      晶振同频 ⇒ 像素域与系统域**同一个时钟**，零 CDC 风险。这是本项目
    //      最重要的架构红利，改时序参数前必须先想清楚这一条会不会被破坏。
    //    ★ 接口形态：H_*/V_* 是**输入端口不是参数**（上电读屏 ID 后才知道接的是
    //      哪一款屏），而 pixel_en 让我们保持单时钟域 —— 本设计恒接 1'b1。
    //=========================================================================
    wire [11:0] pix_x, pix_y;
    wire        de, hs, vs, frame_st, line_st;
    wire        disp_de;               // disp_engine 的 de_o（与 lcd_rgb_o 同拍）

    lcd_timing_gen u_lcd_timing (
        .clk_pix  (sys_clk),
        .rst_n    (rst_sync),
        .pixel_en (1'b1),          // 50 MHz 像素时钟：每拍推进一个像素
        .h_sync   (12'd20),        // ATK-7016：HS 20 / HBP 140 / HACT 1024 / HFP 160
        .h_back   (12'd140),
        .h_disp   (12'd1024),
        .h_front  (12'd160),
        .v_sync   (12'd3),         // VS 3 / VBP 20 / VACT 600 / VFP 12
        .v_back   (12'd20),
        .v_disp   (12'd600),
        .v_front  (12'd12),
        .lcd_hs   (hs),
        .lcd_vs   (vs),
        .lcd_de   (de),
        .pix_x    (pix_x),
        .pix_y    (pix_y),
        .frame_st (frame_st),
        .line_st  (line_st)
    );

    // ---- 面板接口对齐 ----
    //   disp_engine 的像素总延迟 = 3 拍（2 级流水 + 输出寄存器，见 disp_engine.v 的
    //   "S5 对齐延迟线"小节）。所以 lcd_hs / lcd_vs / lcd_de 都必须延迟同样的拍数，
    //   否则 DE 窗口与数据错位 —— 表现为整屏右移 3 px，外加每行左端一条 3 px 竖黑条。
    //   hs/vs/de 一起延迟是标准做法：面板只关心 DE 有效窗相对 HS/VS 的位置，
    //   整体平移 3 个像素时钟对成像是透明的（只吃掉 3 px 前沿、还给 3 px 后沿）。
    localparam integer DISP_LATENCY = 3;
    reg [DISP_LATENCY-1:0] hs_dly = {DISP_LATENCY{1'b1}};
    reg [DISP_LATENCY-1:0] vs_dly = {DISP_LATENCY{1'b1}};
    always @(posedge sys_clk) begin
        hs_dly <= {hs_dly[DISP_LATENCY-2:0], hs};
        vs_dly <= {vs_dly[DISP_LATENCY-2:0], vs};
    end

    assign lcd_pclk = sys_clk;
    assign lcd_hs   = hs_dly[DISP_LATENCY-1];
    assign lcd_vs   = vs_dly[DISP_LATENCY-1];
    assign lcd_de   = disp_de;          // = disp_engine 的 de_o，与 lcd_rgb 同拍
    assign lcd_bl   = 1'b1;
    assign lcd_rst  = rst_sync;

    //=========================================================================
    // 4.5 电容触摸（GT911 / FT5x06）
    //   来源：disp/touch_ctrl.v + disp/i2c_master_seq.v + disp/i2c_io_wrap.v，
    //   三者自 lcd_test2 原样搬入（逻辑一行未改），原件已在仿真里读回 5 个触点：
    //   `tch_type=1(GT911) num=5 (600,256) (900,400) reads=11 nack=0 timeout=0
    //    prod_id=0x39 0x814E=0x05 XMAX/YMAX=1024/600`（disp/logs/tb_touch_ctrl.log）。
    //
    //   ★ INT 上电时序是 GT911 "触摸没反应" 的头号原因，三条缺一不可：
    //     ① RST 低期间 INT 必须保持低 —— 器件地址在 RST 上升沿按 INT 电平锁存，
    //        低 = 0x5D、高 = 0x14；
    //     ② RST 释放后 INT 还要保持低约 50 ms；
    //     ③ 之后必须释放 INT，由外部或内部上拉把它拉高。
    //   ATK-7016 的 FPC 上不一定有 INT 上拉 ⇒ XDC 必须给 touch_int 开
    //   PULLTYPE PULLUP（tools/gen_merged_xdc.py 的 TOUCH_PINS 已带）。
    //=========================================================================
    //   ★ v60（T9）：此信号的驱动在 touch_ctrl 实例之后（需要 tch_type）。
    wire touch_rst_n_w;
    // =====================================================================

    reg [21:0] int_hold_cnt = 22'd0;    // 50 ms @50 MHz = 2_500_000
    wire       int_hold = (touch_rst_n_w == 1'b0) || (int_hold_cnt < 22'd2_500_000);
    always @(posedge sys_clk or negedge touch_rst_n_w) begin
        if (!touch_rst_n_w)                    int_hold_cnt <= 22'd0;
        else if (int_hold_cnt < 22'd2_500_000) int_hold_cnt <= int_hold_cnt + 22'd1;
    end
    assign touch_int   = int_hold ? 1'b0 : 1'bz;
    assign touch_rst_n = touch_rst_n_w;
    wire   int_pin     = touch_int;     // 释放后回读真实电平（诊断用）

    wire scl_oe, sda_oe, scl_line, sda_line;

    i2c_io_wrap u_touch_io (
        .clk    (sys_clk),
        .rst_n  (touch_rst_n_w),
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
    wire [23:0] tch_stat_reads, tch_stat_nack, tch_stat_timeout, tch_stat_touch;
    wire [7:0]  tch_rst_cnt, tch_probe_gt, tch_probe_ft, tch_int_low;
    wire [7:0]  tch_prod_id, tch_status_raw;
    wire [15:0] tch_xmax, tch_ymax;
    wire [15:0] tch_dbg;

    touch_i2c_ctrl u_touch (
        .clk           (sys_clk),
        .rst_n         (touch_rst_n_w),
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
        .stat_reads    (tch_stat_reads),
        .stat_nack     (tch_stat_nack),
        .stat_timeout  (tch_stat_timeout),
        .stat_touch    (tch_stat_touch),
        .rst_cnt       (tch_rst_cnt),
        .probe_gt      (tch_probe_gt),
        .probe_ft      (tch_probe_ft),
        .prod_id       (tch_prod_id),
        .gt_status_raw (tch_status_raw),
        .gt_xmax       (tch_xmax),
        .gt_ymax       (tch_ymax),
        .int_low_cnt   (tch_int_low),
        .dbg           (tch_dbg)
    );

    // ★ v60（T9）触控上电与自恢复（放在实例之后，因为要用 tch_type）
    //   ① 上电后先压住 RST **200 ms** 再放；
    //   ② 释放后 INT 保持低 50 ms（沿用下面的 int_hold_cnt）；
    //   ③ 若 1 s 后 tch_type 仍为 0（从没锁上型号），自动重走一次
    //      "RST 低 20 ms + 释放后 INT 低 50 ms"。
    //   这正是原本只有按 KEY0（全局复位）才会发生的事，现在由显示侧自己触发；
    //   t9_retries 上 UART 遥测，方便上板判断"是不是靠自动重试救回来的"。
    // =====================================================================
    reg  [27:0] t9_pwr_cnt = 28'd0;     // 200 ms @50MHz = 10_000_000
    reg  [25:0] t9_bad_cnt = 26'd0;     // 1 s   @50MHz = 50_000_000
    reg  [20:0] t9_low_cnt = 21'd0;     // 20 ms @50MHz = 1_000_000
    reg  [7:0]  t9_retries = 8'd0;
    reg         t9_rst_low = 1'b0;
    wire        t9_pwr_done = (t9_pwr_cnt == 28'd10_000_000);

    always @(posedge sys_clk or negedge rst_sync) begin
        if (!rst_sync) begin
            t9_pwr_cnt <= 28'd0;
            t9_bad_cnt <= 26'd0;
            t9_low_cnt <= 21'd0;
            t9_retries <= 8'd0;
            t9_rst_low <= 1'b0;
        end else if (!t9_pwr_done) begin
            t9_pwr_cnt <= t9_pwr_cnt + 28'd1;
            t9_bad_cnt <= 26'd0;
        end else if (t9_rst_low) begin
            if (t9_low_cnt == 21'd1_000_000) begin
                t9_rst_low <= 1'b0;
                t9_low_cnt <= 21'd0;
            end else begin
                t9_low_cnt <= t9_low_cnt + 21'd1;
            end
        end else if (tch_type == 2'd0) begin
            if (t9_bad_cnt == 26'd50_000_000) begin
                t9_bad_cnt <= 26'd0;
                t9_rst_low <= 1'b1;
                t9_low_cnt <= 21'd0;
                t9_retries <= t9_retries + 8'd1;
            end else begin
                t9_bad_cnt <= t9_bad_cnt + 26'd1;
            end
        end else begin
            t9_bad_cnt <= 26'd0;
        end
    end

    assign touch_rst_n_w = rst_sync & t9_pwr_done & (~t9_rst_low);

    // ---- 触摸诊断打包（送给 disp_engine 的 P6 页显示）----
    //   打包而不是散成一堆端口：诊断字段还会增删，位宽契约集中在这一个地方，
    //   加字段时只需改这一行 + disp_engine 里对应的解包。
    //   [1:0]type [4:2]num [20:5]x0 [36:21]y0 [44:37]status [52:45]prod_id
    //   [56:53]rst_cnt[3:0] [57]valid [65:58]probe_gt [73:66]probe_ft
    //   [74]int_pin [75]tch_toggle [99:76]stat_reads[23:0]
    //   [123:100]stat_nack[23:0] [147:124]stat_timeout[23:0]
    //   [159:148]dbg[11:0] = {step[3:0], m_state[3:0], m_busy, state[2:0]}
    //     —— IIC 主机状态机与触摸控制器步进。卡死在某个相位时，这两个字段
    //        就是"卡在哪一步"的直接证据；没有它们，上板只能看到"什么都不动"。
    //   ★ 三个 24 位计数器一起进总线是有意的：上板时单看它们就能把故障分成
    //     三类 —— reads 不动 = IIC 根本没跑起来；reads 在涨但 nack 也涨 =
    //     从机不应答（地址/上拉/接线）；reads 在涨、nack=0 但点数恒 0 =
    //     通信正常而是 0x814E 不刷新（配置/INT 时序问题）。
    wire [159:0] tch_diag = {tch_dbg[11:0], tch_stat_timeout, tch_stat_nack, tch_stat_reads,
                             tch_toggle, int_pin, tch_probe_ft, tch_probe_gt,
                             tch_valid, tch_rst_cnt[3:0],
                             tch_prod_id, tch_status_raw,
                             tch_y0, tch_x0, tch_num, tch_type};

    //=========================================================================
    // 4.8 触摸命中判定：坐标 -> 控件编号（第 3 条）
    //   触摸通路本来就是通的（准星跟手、坐标可读），缺的是"哪个控件被碰了"：
    //   在此之前没有任何控件知道自己的矩形。本模块只做几何 + 边沿，**不认识
    //   page** —— "碰了卡片 9 该干什么"是策略，留在这一层。
    //   ★ 几何常量是**两处契约**：disp/disp_engine.v:109-116 定版面，这里定
    //     判定。任何一边单独改都会"看着对、点着错"，所以 disp/tb_hit_test.v
    //     用字面量把这份契约钉住（改了一边测试台立刻红）。
    //=========================================================================
    wire        hit_stb;
    wire [4:0]  hit_id;
    wire [11:0] hit_x, hit_y;
    //   v22：触摸生命周期（长按/拖拽/滑动要用）—— hit_stb 仍然是"一次按下一次"，
    //   held 是"当前有接触"、rel_stb 是"抬起"、cur_x/cur_y 是按住期间的最新坐标。
    wire        hit_held, hit_rel;
    wire [11:0] hit_cur_x, hit_cur_y;

    hit_test u_hit (
        .clk        (sys_clk),
        .rst_n      (rst_sync),
        .tch_num    (tch_num),
        .tch_x0     (tch_x0),
        .tch_y0     (tch_y0),
        .tch_toggle (tch_toggle),
        .hit_stb    (hit_stb),
        .hit_id     (hit_id),
        .hit_x      (hit_x),
        .hit_y      (hit_y),
        .held       (hit_held),
        .rel_stb    (hit_rel),
        .cur_x      (hit_cur_x),
        .cur_y      (hit_cur_y)
    );
    //   hit_x / hit_y 供本层做**按坐标 + 页号**的判定：模态对话框的两个按钮
    //   （4.9 节）与 P6 危险区按钮 —— 这三处都因为"hit_test 只认静态矩形、
    //   不认识页号与模态"而无法用编号表达。

    // v22：倍频编辑面板（disp/ui_panel.v）的信号。先声明、后例化 ——
    //   翻页 always 块与 ui_edit 的 mux 都要读 pnl_on / pnl_req。
    wire        pnl_on;
    wire [2:0]  pnl_idx;
    wire [9:0]  pnl_inter;
    wire        pnl_fld;              // v44（㊶）：活动字段 0 = ×倍频、1 = ÷分频
    wire [2:0]  pnl_didx;             // v44（㊶）：待应用分频码 0..7（div = 码 + 1）
    wire [5:0]  pnl_prog;
    wire [3:0]  pnl_press;            // v44（㊶）：4 bit（多一个 P_FLD = 8）
    wire        pnl_pend;
    wire        pnl_undo_avail;
    wire [9:0]  pnl_undo_inter;
    wire [2:0]  pnl_undo_div;
    // v33（㉚）数字键盘：ui_panel 的输出 → disp_engine 的绘制层
    wire        pnl_kp_on;
    wire [3:0]  pnl_kp_d2;
    wire [3:0]  pnl_kp_d1;
    wire [3:0]  pnl_kp_d0;
    wire [1:0]  pnl_kp_dig;
    wire [3:0]  pnl_kp_sel;
    wire        pnl_req;
    wire [9:0]  pnl_req_inter;
    wire [2:0]  pnl_req_div;
    reg         pnl_open_req = 1'b0;    // 单拍：点 P1 卡片 2 -> 请求开面板
    //   （综合会直接把它们优化掉，不影响判定。）

    localparam [4:0] HIT_NAV_TOP  = 5'd0;   // 导航第 0 项「总览」 -> P1
    localparam [4:0] HIT_NAV_WAVE = 5'd1;   // 导航第 1 项「波形」 -> P2
    localparam [4:0] HIT_NAV_LOGIC= 5'd2;   // 导航第 2 项「时序」 -> P4
    localparam [4:0] HIT_NAV_SET  = 5'd3;   // 导航第 3 项「设置」 -> P6
    localparam [4:0] HIT_CARD_MD  = 5'd9;   // P1 列1行0 = 「倍频分频」卡
    localparam [4:0] HIT_CARD_CAL = 5'd10;  // P1 列2行0 = 第 3 张卡 = 「转速」
    localparam [4:0] HIT_CARD_ABZ = 5'd13;  // P1 列2行1 = 第 6 张卡 = 「ABZ/UVW」
    //   ★ v60（T8）：P6 危险带右半侧的「演示」开关（hit_test 的 HIT_DEMO）
    localparam [4:0] HIT_DEMO    = 5'd14;
    //   ★ v20 的历史：spec §4.5 把第 3 张卡的内容钉死成「转速」（主值 1800.0 rpm、
    //     副文本 电气频率/方向 CCW），而 §4.6 的下钻图又写"点卡片 3 → P7 标定" ——
    //     两处放在一起读像是自相矛盾。v20 当时的取舍是"只留标题带按钮这一条路"。
    //   ★ v53（㊿）：改回**双入口** —— §4.6 是导航契约，写的是"从哪块屏能到哪一页"，
    //     与 §4.5 规定卡片**画什么内容**不冲突（点了就翻页，不改变卡片上的读数）。
    //     所以卡片 3 与标题带「标定」按钮都能进 P7，两条路各自独立成立；
    //     同一轮按 §4.6 补上"点卡片 6 → P4 逻辑时序"。
    // ---- v58：状态条 [系统 ⚙] 随 P8 删除，HIT_SYS / tap_sys 一并撤掉 ----
    localparam [4:0] HIT_SBAR     = 5'd6;   // 状态条本体（没细分 x 时的兜底）
    // ---- v20：标题带主操作按钮（编号由 disp/hit_test.v 定）----
    //   同一颗按钮在两页上代表两件事：P1 -> P7（标定）、P4 -> P5（六状态明细）。
    //   几何判定只看矩形，**动作由页号决定**，所以判定写成"编号 + page"。
    localparam [4:0] HIT_TITLE_BTN = 5'd15;

    wire tap_nav_top  = hit_stb && (hit_id == HIT_NAV_TOP);
    wire tap_nav_wave = hit_stb && (hit_id == HIT_NAV_WAVE);
    wire tap_nav_lg   = hit_stb && (hit_id == HIT_NAV_LOGIC);
    wire tap_nav_set  = hit_stb && (hit_id == HIT_NAV_SET);
    wire tap_card_md  = hit_stb && (hit_id == HIT_CARD_MD);
    //   ★ v53（㊿）：恢复卡片 3 的下钻（spec §4.6），并新增卡片 6 —— 两者都带
    //     `page == 3'd0` 守卫（卡片网格只描述 P1 的 6 格），守卫写在用它们的
    //     4.6 节里，与 tap_card_md 同一个理由：这一层不能在声明 page 之前引用它。
    wire tap_card_cal = hit_stb && (hit_id == HIT_CARD_CAL);
    wire tap_card_abz = hit_stb && (hit_id == HIT_CARD_ABZ);
    wire tap_title_btn = hit_stb && (hit_id == HIT_TITLE_BTN);
    wire tap_demo      = hit_stb && (hit_id == HIT_DEMO);
    //   ★ P6 危险区「清除锁存故障」**不看 hit_id，只看坐标 + 页号** ——
    //     它的解码里要引用 page，所以定义放在声明了 page 之后的 4.9 节。
    //   tap_card_md 不带 page 判断，是为了不在这一层提前引用下面的 page；
    //   "卡片网格只在 P1 有意义"这条守卫放在用它的地方。
    //   危险区的 page 守卫写在解码那一行本身（那里还带坐标），因为它是唯一
    //   需要页号才能解的矩形。
    //   ★ v34（㊲）：危险区那个信号已经从 `tap_dz_clr`（按下即弹窗）改成
    //     `dz_prs_lvl`（按住电平）+ `dz_click`（抬起才算点击），见 4.9 节。

    //=========================================================================
    // 4.9 v19：模态二次确认的状态（"清除锁存故障"）
    //   dlg = 0 关；1 = 询问中（等 CANCEL / OK）；2 = 已按 OK，正在写 0x0405。
    //   状态放在这一层（策略层），画面只负责按 ui_dlg 画遮罩与对话框 ——
    //   disp_engine 不持有任何事务状态，它连 page 都不判断（见它的端口注释）。
    //   ★ 对话框的两个按钮**不在 hit_test 的矩形表里**：模态一开，本层的
    //     所有 hit_id 都不认（那是被挡住的下层控件），只用原始坐标 hit_x/hit_y
    //     去比对对话框自己的两个按钮。这样 hit_test 保持自己"只认静态矩形、
    //     不认识 page 与模态"的单一职责，几何契约仍只存在于两处：
    //       disp/disp_engine.v 的 DLG_* 常量（画框）
    //       本节的 DLG_HIT_* 常量（判定，画框 + 8 px 外扩）
    //=========================================================================
    localparam [11:0] DLG_HIT_NO_X0  = 12'd264;   // = disp_engine 的 DLG_NO_X0 - 8
    localparam [11:0] DLG_HIT_NO_X1  = 12'd496;   // = DLG_NO_X1 + 8
    localparam [11:0] DLG_HIT_YES_X0 = 12'd528;   // = DLG_YES_X0 - 8
    localparam [11:0] DLG_HIT_YES_X1 = 12'd760;   // = DLG_YES_X1 + 8
    localparam [11:0] DLG_HIT_Y0     = 12'd316;   // = DLG_BTN_Y0 - 8
    localparam [11:0] DLG_HIT_Y1     = 12'd388;   // = DLG_BTN_Y1 + 8

    reg [1:0] dlg = 2'd0;
    reg       w1c_req = 1'b0;

    // ---- v32（㉙）：spec §5.2 第四重冗余「可关闭的 2 Hz 闪烁」的开关 ----
    //   这是**显示侧偏好**，不进寄存器、也不进 disp_tap（rtl/ 一行未改）：
    //   它只改"反色块显不显示"，不改任何状态判据。
    //   入口 = P6（page 5）标题带那颗主操作按钮 —— 与 P1「标定」→ P7、
    //   P4「展开」→ P5 是同一个矩形、同一个命中编号（HIT_TITLE_BTN = 15），
    //   动作按页号分派（见下面的 if (tap_title_btn) 链）。
    //   ★ 复位默认**开**：spec 把闪烁写成默认存在的第三/第四重冗余，
    //     "可关闭"是给现场嫌闪的人用的，不是默认关掉的装饰。
    //   ★ 状态位放在策略层而不是 disp_engine：引擎不持有任何事务/偏好状态
    //     （它连 page 都由端口进来），这条纪律从 v19 的模态起就没破过。
    reg       scr_blink = 1'b1;
    //   ★ v60（T8）：演示模式开关（P6 上点「演示」切换）。
    //     显示侧局部状态，不写寄存器、不过 SPI；上电默认关。
    reg       demo_on = 1'b0;
    //   ★ v60（T8）：演示模式（P6 开关）—— 显示侧局部状态，上电默认关

    //   危险区按钮的判定见上面（引用 page，所以不在本节的 wire 组里）
    //   —— v34（㊲）起是 `dz_prs_lvl` 与 `dz_click`。
    wire dlg_hit_no  = (hit_x >= DLG_HIT_NO_X0)  && (hit_x < DLG_HIT_NO_X1)  &&
                       (hit_y >= DLG_HIT_Y0)     && (hit_y < DLG_HIT_Y1);
    wire dlg_hit_yes = (hit_x >= DLG_HIT_YES_X0) && (hit_x < DLG_HIT_YES_X1) &&
                       (hit_y >= DLG_HIT_Y0)     && (hit_y < DLG_HIT_Y1);

    //=========================================================================
    // 5. 显示引擎
    //    （端口序严格按 disp/disp_engine.v 声明；pairs 已接入 —— 转速与
    //      累计转数都要除以它；calib_done 仍是"留着备用"的抽头）
    //=========================================================================
    // ---- 页切换：低有效按键 -> 20 ms 去抖 -> 循环 page ----
    //   后面接 S3 的编辑面板时会由触摸接管；现在先用实体按键，
    //   这样"多页"这件事在**没有触摸**的前提下也能上板验证。
    //
    //   ★ 2026-10-15 上板发现：原来只接 J5-29(H14) 一颗**外接**针，板上没有按钮，
    //     用户按的是板载 KEY0(W9) —— 那根在本设计里是**全局异步复位**（见下面
    //     always 的 negedge key_n），按一下只是把系统复位回 P1，屏上"没反应"。
    //     现在把板载 KEY1(Y9) 也并进来：KEY1 一直是空闲的（constr/enc_top.xdc:64），
    //     按下才是真的翻页。J5-29 保留，方便飞线或用外部信号驱动。
    //     两颗都是"按下才接地"的低有效输入、各自带上拉，所以直接相与。
    wire btn_raw_n = key1_n & ui_btn;
    reg [1:0]  btn_sy = 2'b11;
    reg        btn_d  = 1'b1;
    reg [19:0] btn_lock = 20'd0;
    reg [2:0]  page   = 3'd0;          // v15：按 spec 4.4 页序，见 disp/disp_engine.v 的端口注释

    // ---- v75（A）：P2 波形时基三档的入口 ----
    //   用户要求"点 P2 底部轴标区域循环切换"。这块区域只有文字、不是控件，不在
    //   hit_test 的矩形表里，所以沿用本层既有的"坐标 + 页号"范式（与对话框的两颗
    //   按钮、P6 危险区同一个套路：hit_test 保持只认静态矩形的单一职责），
    //   不新增 hit_id、也不给 hit_test 加条目（它的表被 tb_hit_test.v 钉着）。
    //   几何：底栏第 36 格行（y 576..591）、第 6..13 格（x 96..223），命中区整行
    //   外扩到 x 88..360 / y 566..600 —— 触控面积远大于字形（spec 6.1 的 72 px）。
    //   档位默认 = 1（300 µs），与 tools/gen_text_ram.py 里 P2_LAB 的静态默认档一致。
    localparam [11:0] P2W_HIT_X0 = 12'd88;
    localparam [11:0] P2W_HIT_X1 = 12'd360;
    localparam [11:0] P2W_HIT_Y0 = 12'd566;
    localparam [11:0] P2W_HIT_Y1 = 12'd600;

    wire p2w_hit = hit_stb && (page == 3'd1) &&
                   (hit_x >= P2W_HIT_X0) && (hit_x < P2W_HIT_X1) &&
                   (hit_y >= P2W_HIT_Y0) && (hit_y < P2W_HIT_Y1);

    reg [1:0] p2_gear = 2'd1;          // 0 = 2.4 ms / 1 = 300 µs / 2 = 38 µs

    always @(posedge sys_clk or negedge key_n) begin
        if (!key_n)
            p2_gear <= 2'd1;
        else if (p2w_hit)
            // 循环 1 -> 2 -> 0 -> 1：把默认档排在中间，点一下先换到更快的窗口，
            // 再点一下到最慢，避免"第一下就跳到 2.4 ms 看不出变化"。
            p2_gear <= (p2_gear == 2'd2) ? 2'd0 : (p2_gear + 2'd1);
    end

    //   ★ P6 危险区「清除锁存故障」**不看 hit_id，只看坐标 + 页号**：
    //     它的矩形（x 184..648, y 512..592）与 P1 的两张 row1 卡片
    //     （col0 x 96..384、col1 x 416..704）大面积重叠，而 hit_test 不认识
    //     页号 ⇒ 那块面积上报出来的是卡片编号（disp/tb_hit_test.v 专门钉住了
    //     这个事实）。几何判定无法区分"P1 的卡片"与"P6 的危险区按钮"，
    //     只有本层同时握着 page 与原始坐标。
    //     矩形与 disp/disp_engine.v 的 DZ_BTN_* 是共同契约。
    //   ★ v33（㉝）：这里原来写的是裸数字（192/640/528/592），现在抽成 DZ_HIT_*，
    //     并把**触控外扩**写成与对话框按钮同一个约定（画框 ±8 px）：
    //     按钮框是 64 px 高（y 520..583），命中区 512..591 = **80 px**，
    //     落在 spec 6.1「危险动作 72..96 px」里。之前那 8 px 只写在注释里
    //     （gen_text_ram.py 说"含触控外扩后 72 px"），代码里其实一点没扩。
    //   （定义写在这里而不是 4.9 节，是因为它引用 page —— 与 tap_card_* 同一个理由。）
    //   ★ v42（㊴）：危险区从"1 颗按钮（x 192..640）"改成"两颗对称按钮
    //     （x 180..591 与 x 608..1019）"，这一组命中矩形**必须跟着画框一起挪**：
    //     漏改的后果不是"边缘差 8 px"，而是第 2 颗按钮左起 40 px（x 608..647）
    //     会同时落进第 1 颗的命中区 —— 按"恢复默认"会弹出"清除锁存故障"的对话框
    //     （FSM 里 dz_click 的分支在前）。下面两颗的命中区在 x=600 处前后相接、不重叠。
    localparam [11:0] DZ_HIT_X0 = 12'd172;         // = disp_engine 的 DZ_BTN_X0 - 8
    localparam [11:0] DZ_HIT_X1 = 12'd600;         // = DZ_BTN_X1 + 8
    localparam [11:0] DZ_HIT_Y0 = 12'd512;         // = DZ_BTN_Y0 - 8
    localparam [11:0] DZ_HIT_Y1 = 12'd592;         // = DZ_BTN_Y1 + 8
    //   ★ v34（㊲）：按下与"发声"分家 —— 本轮的核心语义改动。
    //     旧行为 `wire tap_dz_clr = hit_stb && 命中`：手指一按下就弹对话框，
    //     而对话框一弹，模态遮罩立刻把危险区压暗 ⇒ 按下反馈**物理上看不见**。
    //     新行为：
    //       · 按住期间（`hit_held` 且**当前**坐标仍在命中矩形内）→ `dz_prs_lvl = 1`：
    //         绘制层只画一圈内嵌框（按下反馈，形状编码），**不进询问态**（防误触）。
    //       · 抬起那一拍（`hit_rel`）：只有**按下点**（`hit_x/hit_y`）与**抬起点**
    //         （`hit_cur_x/hit_cur_y` —— hit_test 保证"抬起那拍 cur 保持抬前最后
    //         一次合法坐标"）都在命中矩形内，才算一次点击 ⇒ 按住后滑出再松手
    //         不算，与 spec §6.5「防误触但不必弹窗」同一路。
    //     ★ 于是"进询问态"必须等到抬起；按住期间只由 ui_dz_press 画内嵌框。
    //     ★ 三个信号都带 `page == 5` 守卫（hit_test 不认识页号，见上面那段注释）。
    wire dz_now_in = (page == 3'd5) &&
                     (hit_cur_x >= DZ_HIT_X0) && (hit_cur_x < DZ_HIT_X1) &&
                     (hit_cur_y >= DZ_HIT_Y0) && (hit_cur_y < DZ_HIT_Y1);
    wire dz_prs_lvl = hit_held && dz_now_in;
    wire dz_hit_at_press = (page == 3'd5) &&
                           (hit_x >= DZ_HIT_X0) && (hit_x < DZ_HIT_X1) &&
                           (hit_y >= DZ_HIT_Y0) && (hit_y < DZ_HIT_Y1);

    reg dz_latch = 1'b0;      // 这次按下是否落在危险区按钮上（按下那拍记住）

    always @(posedge sys_clk or negedge key_n) begin
        if (!key_n)
            dz_latch <= 1'b0;
        else if (hit_stb)
            dz_latch <= dz_hit_at_press;
        else if (hit_rel)
            dz_latch <= 1'b0;
    end

    wire dz_click = hit_rel && dz_latch && dz_now_in;

    //   ★ v42（㊴）：第二颗按钮「恢复默认」—— 同一套语义，自己的矩形与自己的 latch。
    //     两颗按钮等宽对称（x 180..591 与 x 608..1019，间隔 16 px），命中区各外扩 ±8 px
    //     ⇒ x 172..599 与 x 600..1027、y 512..591。**两条命中区在 x 600 处相接但不重叠**
    //     （低半沿属于第 2 颗），所以"按下点在哪颗上"永远是确定的。
    //     矩形与 disp/disp_engine.v 的 DZ_BTN_/DZ_BTN2_* 是共同契约。
    localparam [11:0] DZ2_HIT_X0 = 12'd600;        // = DZ_BTN2_X0 - 8
    localparam [11:0] DZ2_HIT_X1 = 12'd1027;       // = DZ_BTN2_X1 + 7（钳在屏幕 1024 内）
    wire dz_now_in2 = (page == 3'd5) &&
                      (hit_cur_x >= DZ2_HIT_X0) && (hit_cur_x < DZ2_HIT_X1) &&
                      (hit_cur_y >= DZ_HIT_Y0) && (hit_cur_y < DZ_HIT_Y1);
    wire dz_prs_lvl2 = hit_held && dz_now_in2;
    wire dz_hit_at_press2 = (page == 3'd5) &&
                            (hit_x >= DZ2_HIT_X0) && (hit_x < DZ2_HIT_X1) &&
                            (hit_y >= DZ_HIT_Y0) && (hit_y < DZ_HIT_Y1);

    reg dz_latch2 = 1'b0;     // 这次按下是否落在第 2 颗按钮上

    always @(posedge sys_clk or negedge key_n) begin
        if (!key_n)
            dz_latch2 <= 1'b0;
        else if (hit_stb)
            dz_latch2 <= dz_hit_at_press2;
        else if (hit_rel)
            dz_latch2 <= 1'b0;
    end

    wire dz_click2 = hit_rel && dz_latch2 && dz_now_in2;

    //   ★ v58：P2/P3 的 Tab 栏随 P3 一起删除（用户：Tab 栏省掉、40 px 让给波形）。
    //     于是 tap_tab_* 两条入口不再存在，页内 Tab 也一并从 disp_engine 去掉。

    always @(posedge sys_clk or negedge key_n) begin
        if (!key_n) begin
            btn_sy <= 2'b11; btn_d <= 1'b1; btn_lock <= 20'd0; page <= 3'd0;
        end else begin
            btn_sy <= {btn_sy[0], btn_raw_n};
            btn_d  <= btn_sy[1];
            if (btn_lock != 20'd0)
                btn_lock <= btn_lock - 20'd1;
            if (btn_d && !btn_sy[1] && (btn_lock == 20'd0)) begin
                // 只循环**还存在的页**：P1(0) -> P2(1) -> P4(3) -> P6(5)
                //   -> P7(6) -> P1。
                // ★ v58：P3(2)/P5(4)/P8(7) 已删，页号保留空洞（不重编号），
                //   所以这条链要跳过 2/4/7 —— 以后再加页也同步这一行。
                page     <= (page == 3'd0) ? 3'd1 :
                            (page == 3'd1) ? 3'd3 :
                            (page == 3'd3) ? 3'd5 :
                            (page == 3'd5) ? 3'd6 : 3'd0;
                btn_lock <= 20'd1_000_000;     // 20 ms @ 50 MHz
            end

            // ---- 触摸翻页（第 3 条起成为主入口）-----------------------------
            //   点左侧导航项：总览 -> P1、波形 -> P2、XY -> P3、逻辑 -> P4、
            //   状态 -> P5、设置 -> P6。
            //   ★ 六个导航项现在全部有落点；P7（标定）**不在**导航栏里 ——
            //     spec §4.6 给的下钻路径是"点卡片 3 -> P7 标定与误差可视化"，
            //     但 §4.5 把卡片 3 钉成「转速」（主值 1800.0 rpm）⇒ v20 改成
            //     标题带右侧的主操作按钮（本节下面的 tap_title_btn）。
            //   ★ spec 4.4 写的入口是"P2 -> Tab「XY」-> P3"。v20 起页内 Tab 栏
            //     真的画出来了（disp/disp_engine.v 的 TAB_* + 下面的 tap_tab_*），
            //     左侧导航的「XY」项仍然在，两条路都能到 P3。
            //   ★ 写在按键分支之后：同一拍两者都成立时以触摸为准。
            //   ★ 不碰 btn_lock：两者只是各自把 page 写成一个合理的值，撞上的
            //     概率可以忽略，多一层耦合反而更难推理。
            //   ★ v19：模态（二次确认对话框）打开期间，**整层动作全部让路** ——
            //     spec §6.4 的二次确认要"挡住底下的一切"，包括翻页。dlg 由
            //     下面的对话框状态机驱动（见 4.9 节），这里只读。
            //   ★ v22：编辑面板打开期间同样整层让路（面板是模态，只占下半屏，
            //     但翻页/导航/标题带按钮在面板下面，点它们会改到看不见的页）。
            if ((dlg == 2'd0) && !pnl_on) begin
                if (tap_nav_top)
                    page <= 3'd0;
                if (tap_nav_wave)
                    page <= 3'd1;
                if (tap_nav_lg)
                    page <= 3'd3;
                if (tap_nav_set)
                    page <= 3'd5;
                //   ★ v20：P2/P3 的页内 Tab（spec §4.1「左侧导航 + 页内 Tab」、
                //     §4.4「导航「波形」→ Tab「模拟」」、§4.6「P2 ─Tab「XY」→ P3」）。
                //     矩形与页号守卫都在上面的 tap_tab_* 里（引用 page 才能定）。
                //   ★ v58：P2/P3 的页内 Tab 两条入口随 P3 一起删除。
                //   ★ v58：P4 的「展开」按钮删掉（它只通向已删的 P5）。
                //     于是标题带按钮只剩两种作用：P1 -> P7 标定、P6 -> 切换闪烁。
                if (tap_title_btn) begin
                    if (page == 3'd0)
                        page <= 3'd6;
                    //   ★ v32（㉙）：P6 上这颗按钮不是"去某一页"，而是**切换一个显示偏好**
                    //     —— spec §5.2 第四重冗余「可关闭的 2 Hz 闪烁」。
                    //     不翻页、不写字节，所以它不需要 dlg/pnl 之外的任何握手。
                    else if (page == 3'd5)
                        scr_blink <= ~scr_blink;
                end
                //   ★ v58：状态条 ⚙（→ P8 系统信息）随 P8 一起删除。
                //   ★ v53（㊿）C1+C2：spec §4.6 的两条卡片下钻。
                //     卡片 3（列2行0 = 「转速」）-> P7 标定；卡片 6（列2行1 =
                //     「ABZ/UVW」）-> P4 逻辑时序。
                //     ★ 为什么不和 tap_card_md 写在同一个 always 块：那一个写的是
                //       pnl_open_req（开面板），这里写的是 page；两块各管各的状态，
                //       同一拍点中两张卡不可能（矩形互斥），拆开更好推理。
                //     ★ 守卫 `page == 3'd0` 与 tap_card_md 相同：hit_id 8..13 只
                //       描述 P1 的卡片网格，别的页上同一坐标是别的控件。
                if (tap_card_cal && (page == 3'd0))
                    page <= 3'd6;
                if (tap_card_abz && (page == 3'd0))
                    page <= 3'd3;
                //   ★ v60（T8）：演示开关。只在 P6 上生效（与弹出面板互斥），
                //     不写寄存器、不过 SPI —— 它只是一个显示偏好，上电默认关。
                if (tap_demo && (page == 3'd5))
                    demo_on <= ~demo_on;
            end
        end
    end

    //=========================================================================
    // 4.7 屏上改值：两阶段提交 + 回读确认（写侧执行器）
    //=========================================================================
    //   本版触发有两条，走同一条执行链：
    //     ① 点 P1 的 MULT/DIV 卡片（第 3 条起，主入口）—— 见本节末尾；
    //     ② 长按板载 KEY1 >= 1 秒（上一版的主入口，现在留作**上板兜底**）。
    //   留 ② 的原因：①的触点几何只在仿真里验过，没上过板。等触摸在实机上
    //   确认命中之后，删掉 ②（约 25 行：lp_cnt / lp_armed / 那个 else-if 分支）
    //   就兑现 docs/13_display_ui_requirements.md 的 C3「不设计按键兜底」。
    //   短按 = 翻页（上一节），长按 = 改值 —— 分开是有意的：长按只做
    //   "防误触"的动作。
    //     这一步先证明**写链路 + 回读确认 + 自动回滚**在实机上成立；有了稳定的
    //     触点之后，req 由 P6 编辑面板的「应用」接管（S3 的后半段）。
    //   ★ 提交后屏上立刻能看到：P1 的 MULT/DIV 卡片是 val_format 用 cfg_inter /
    //     cfg_div 实时算出来的（disp/val_format.v:306-322），所以 X? 会变。
    //     P6 的九项仍是 text_ram 静态预置（那要按页切字段表，属 S3 后半）。
    //
    //   档位序列与 rtl/abz_gen.v:118 的编码一致：2,4,8,...,128,256(编码 0)。
    //   当前值不在档位上（例如复位后的 0 之外的值）就从 64 起步。
    function [9:0] next_preset;
        input [9:0] cur;
        begin
            case (cur)
            10'd2:   next_preset = 10'd4;
            10'd4:   next_preset = 10'd8;
            10'd8:   next_preset = 10'd16;
            10'd16:  next_preset = 10'd32;
            10'd32:  next_preset = 10'd64;
            10'd64:  next_preset = 10'd128;
            10'd128: next_preset = 10'd0;      // 256：abz_gen 把 0 当 256
            10'd0:   next_preset = 10'd2;      // 从 256 绕回 2
            default: next_preset = 10'd64;
            endcase
        end
    endfunction

    reg [26:0] lp_cnt   = 27'd0;
    reg        lp_armed = 1'b1;
    reg        ui_req   = 1'b0;
    reg [9:0]  ui_inter = 10'd64;
    reg [2:0]  ui_div   = 3'd0;

    always @(posedge sys_clk or negedge key_n) begin
        if (!key_n) begin
            lp_cnt <= 27'd0; lp_armed <= 1'b1; ui_req <= 1'b0;
            ui_inter <= 10'd64; ui_div <= 3'd0;
            pnl_open_req <= 1'b0;
        end else begin
            ui_req <= 1'b0;                        // 默认：单拍脉冲
            pnl_open_req <= 1'b0;
            if (btn_sy[1]) begin                   // 松开
                lp_cnt   <= 27'd0;
                lp_armed <= 1'b1;
            end else if (lp_armed) begin           // 按住
                //   v19：模态打开期间、或 W1C 通道正忙时，主通道不接受新事务
                //   （两根 uart_tx 只有一根能上线，见第 2 节的 mux 注释）。
                //   v22：编辑面板开着时也不受理（面板有自己的 APPLY 通道）。
                if ((lp_cnt >= 27'd50_000_000) && (dlg == 2'd0) && !w1c_busy && !pnl_on) begin // 1 s @ 50 MHz
                    ui_inter <= next_preset(tap_inter);
                    ui_div   <= tap_div;           // 物理键只走倍频预设，分频原样带回
                    ui_req   <= 1'b1;
                    lp_armed <= 1'b0;              // 一次长按只提交一次
                end else begin
                    lp_cnt <= lp_cnt + 27'd1;
                end
            end

            // ---- v22：点 P1「倍频分频」卡 = **打开编辑面板** ----------
            //   卡片编号 9 = 8 + 列1 + 3*行0（hit_test.v 的编号规则），与
            //   disp/disp_engine.v 的 `ui_card = (page == 3'd0) && col1 && row0`
            //   指的是同一张卡。
            //   ★ v21 及以前这里是"点一下 = 跳到下一个预设档并立刻提交"，那样
            //     既没有"待应用"态、也没有撤销（spec 6.2/6.5 要的两件事）。
            //     v22 改成：点卡片 -> 开面板（disp/ui_panel.v），改值在面板里，
            //     「APPLY」才走两阶段提交 + 回读确认。
            //   ★ 只在 P1 生效：hit_id 8..13 描述的是 P1 的 6 卡网格，P6 上同
            //     一坐标是别的控件 —— 少了这层守卫，点 P6 空白处也会开面板。
            if (tap_card_md && (page == 3'd0) && (dlg == 2'd0) && !w1c_busy) begin
                pnl_open_req <= 1'b1;
            end
        end
    end

    wire [1:0]  ui_state;
    wire        ui_done;
    wire [9:0]  ui_ok_inter;
    wire [2:0]  ui_ok_div;
    wire [3:0]  ui_err;
    wire [15:0] ui_txn_cnt, ui_fail_cnt;

    ui_edit #(
        .BAUD_DIV   (25),            // 2 Mbaud
        .GAP_CLK    (4000),          // 80 µs
        .SETTLE_CLK (100_000)        // 2 ms
    ) u_ui_edit (
        .clk        (sys_clk),
        .rst_n      (rst_sync),
        //   ★ v22：两个请求源在**这里**做 mux —— 编辑面板的「APPLY / BACK」
        //     与"长按 KEY1 兜底"走同一条执行链（同一条 UART 命令注入 + 回读确认
        //     + 自动回滚）。两条路同时成立的概率可以忽略（KEY1 长按在面板开着
        //     时已被 !pnl_on 挡住），所以直接以面板为准。
        .req        (pnl_req | ui_req),
        .inter_enc  (pnl_req ? pnl_req_inter : ui_inter),
        .div_code   (pnl_req ? pnl_req_div   : ui_div),
        .tap_inter  (tap_inter),
        .tap_div    (tap_div),
        .tx_line    (ui_tx_line),
        .tx_busy    (ui_busy),
        .state      (ui_state),
        .done       (ui_done),
        .ok_inter   (ui_ok_inter),
        .ok_div     (ui_ok_div),
        .err_code   (ui_err),
        .txn_cnt    (ui_txn_cnt),
        .fail_cnt   (ui_fail_cnt)
    );

    //=========================================================================
    // 4.12 v22：倍频编辑面板的交互状态机（spec 4.5 / 6.2 / 6.3 / 6.5）
    //   它不画一个像素（绘制在 disp/disp_engine.v 的 5.13 段），也不碰寄存器
    //   （写走上面 u_ui_edit 的两阶段提交）—— 只做三件事：
    //     ① 把触摸生命周期翻译成手势：[−]/[+]/滑条/CANCEL/APPLY/BACK；
    //     ② 维护"待应用值"（pnl_inter）与"上一次值"（跨事务保留）；
    //     ③ 把「APPLY / BACK」变成单拍 req。
    //   ★ open_req 只在 P1 卡片 2 上产生（上面 4.7 节），这里再守一次页号。
    //   ★ 面板不跨页：page 一离开 P1 就自动收起（由 pnl_page 保证），
    //     所以不需要额外的"页面变了"事件。
    //=========================================================================
    ui_panel u_ui_panel (
        .clk            (sys_clk),
        .rst_n          (rst_sync),
        .page           (page == 3'd0),
        .dlg            (dlg),
        .open_req       (pnl_open_req),
        .press_stb      (hit_stb),
        .press_x        (hit_x),
        .press_y        (hit_y),
        .held           (hit_held),
        .cur_x          (hit_cur_x),
        .cur_y          (hit_cur_y),
        .rel_stb        (hit_rel),
        .ui_state       (ui_state),
        .tap_inter      (tap_inter),
        .tap_div        (tap_div),
        .pnl_on         (pnl_on),
        .pnl_idx        (pnl_idx),
        .pnl_inter      (pnl_inter),
        .pnl_fld        (pnl_fld),
        .pnl_didx       (pnl_didx),
        .pnl_prog       (pnl_prog),
        .pnl_press      (pnl_press),
        .pnl_pend       (pnl_pend),
        .pnl_undo_avail (pnl_undo_avail),
        .pnl_undo_inter (pnl_undo_inter),
        .pnl_undo_div   (pnl_undo_div),
        .req            (pnl_req),
        .req_inter      (pnl_req_inter),
        .req_div_code   (pnl_req_div),
        // ---- v33（㉚）数字键盘：面板的输出直接进绘制层 ----
        //   键盘是**纯显示侧**的输入法：它只改 pnl_inter（待应用值），
        //   写寄存器仍然走 pnl_req -> ui_edit 那条两阶段提交链路。
        .kp_on          (pnl_kp_on),
        .kp_d2          (pnl_kp_d2),
        .kp_d1          (pnl_kp_d1),
        .kp_d0          (pnl_kp_d0),
        .kp_dig         (pnl_kp_dig),
        .kp_sel         (pnl_kp_sel)
    );

    wire [23:0] lcd_rgb_o;
    wire [11:0] dbg_x, dbg_y;

    //=========================================================================
    // 4.11 v19：W1C 写通道（清除锁存故障）+ 模态状态机
    //   契约来源：docs/13_display_ui_requirements.md §6.4（"清除锁存故障"必须
    //   二次确认）与 §6.2（写 -> 状态 -> 回读确认）。
    //   ★ 这里的"回读确认"与 0x0101 那条**不是同一种**：0x0405 是 W1C，而且
    //     **不在 disp_tap 的 376 位上**（rtl/SPEC_interface_contract.md），没有
    //     可读的写入回执。给用户看的确认物是**故障状态本身**：tap 的 stat[0]
    //     是锁存故障位，清掉之后状态条 [告警 ▲] 与左端告警条会自己变回正常色
    //     （disp_engine 的 alert_fault = q_stat[0] | q_io_flags[7] | ...）。
    //     所以屏上不会出现"已清除"这种**屏自己说的**话，只有硬件回读的故障位
    //     变了色 —— 字库里也没有"已/清除成功"这些字，这一点正好不用妥协。
    //   ★ 复用 ui_edit 而不是新写一个发送器：写 4 个字节的时序（GAP/WAITB/
    //     WAITD）已经被上板验证过（U-9 的 0x0101 链路），复制一份等于把那段
    //     验证作废。差别只有地址与"不做相等校验"两件事，都用参数表达。
    //=========================================================================
    //   ★ v42（㊴）：模态现在服务**两件**危险动作（spec §6.4 的两条都归它管）：
    //     dlg_kind = 0 -> 清除锁存故障（写 0x0405 bit0，W1C，一条事务）
    //     dlg_kind = 1 -> 恢复默认（13 条命令的序列 + 全序列回读，见 disp/ui_restore.v）
    //     询问态的画法两套文字由 disp_engine 按 ui_dlg_kind 选（标题/正文行不同）。
    //   ★ 恢复序列**不回滚**（用户拍板的 F1）：结果由 ui_restore.state/bad 直接
    //     送给绘制层 —— 全一致 => 第 2 颗按钮描边转绿；有不一致 => 描边红 + 那一项
    //     标题右侧红 ✖。所以"结果"不需要存在本 FSM 里，关掉对话框也还看得见。
    reg        dlg_kind = 1'b0;    // 0 = 清除锁存故障、1 = 恢复默认
    wire [1:0] w1c_state;
    wire       w1c_done;
    reg        rst_req = 1'b0;
    wire [1:0] rst_state;
    wire [14:0] rst_bad;
    wire       rst_done;

    //=========================================================================
    // 4.11a ★ v82（任务C）：锁存**自动老化** —— 每 2 s 自动清一次 0x0405
    //   用户原话："能不能不要总是锁存？锁存非常容易被触发，而且解除锁存很麻烦"。
    //   现状（rtl/reg_file.v:481-485）是 `r_stat_latch <= r_stat_latch | stat_val_now`
    //   —— 任何**一拍**的瞬时告警（otr / inclim / amp_low|amp_high / lag）都会被
    //   永久记住，屏上就一直是「▲ 警示 / ✖ 故障」，只能进 P6 点「清除锁存故障」
    //   → 二次确认 → 才消。上板时一次上电的毛刺能挂一整天。
    //
    //   本方案**不动 RTL**（显示位流读的是 _synth_work_v74/rtl_v74 的快照，
    //   见回报"显示位流的 RTL 来源目录"），只在显示侧复用已经上板验证过的
    //   W1C 通道（同一个 ui_edit 实例、同一条 4 字节写命令），把它从"人工点按钮"
    //   变成"定时自动"：
    //     · 每 LATCH_AGE_MAX 个 sys_clk（100 000 000 = 2 s @50 MHz）发一次
    //       0x0405 <- 0xFF（W1C：写 1 清对应位；rtl/reg_file.v:130-136 的位序 =
    //       bit0 otr / bit2 lag / bit3 inclim / bit5 amp_low|amp_high）。
    //       ★ 必须写整字节 0xFF，不能沿用原来那颗按钮的 0x01（只清 bit0）——
    //       按钮只管 otr，这里要清全部锁存位。
    //     · **当前条件仍在**的位下一拍就会重新锁存（reg_file.v:484 是 else 分支、
    //       每拍都锁一次），所以这条命令的效果恰好是"锁存退化成 2 s 记忆"：
    //       真故障照旧常亮，瞬态毛刺最多糊屏 2 s 后自己消失。
    //     · 发命令的时机：只在对话框空闲（dlg==0）、W1C 通道空闲、恢复默认序列
    //       空闲时发，避免和用户操作抢 UART。被别的帧挤掉也没关系，2 s 后再发。
    //   语义上等价于任务书方案 1 的"最近 2 s 内出现过才显示"：显示层看到的
    //   0x0404 里 otr_lat 项（= otr | 锁存，见 rtl/reg_file.v:283 的 stat_val_now）
    //   最多只会"晚 2 s 落地"。
    //=========================================================================
    localparam [27:0] LATCH_AGE_MAX = 28'd99_999_999;   // 2 s @ 50 MHz

    reg [27:0] latch_age;

    always @(posedge sys_clk or negedge key_n) begin
        if (!key_n) begin
            dlg      <= 2'd0;
            dlg_kind <= 1'b0;
            w1c_req  <= 1'b0;
            rst_req  <= 1'b0;
            latch_age <= 28'd0;
        end else begin
            w1c_req <= 1'b0;                      // 默认：单拍脉冲
            rst_req <= 1'b0;

            // ★ v82：锁存自动老化（2 s 一次，只在通道全空闲时发）
            if (latch_age == LATCH_AGE_MAX) begin
                latch_age <= 28'd0;
                if ((dlg == 2'd0) && !w1c_busy && !rst_busy)
                    w1c_req <= 1'b1;
            end else begin
                latch_age <= latch_age + 28'd1;
            end

            case (dlg)
            2'd0: begin
                // dz_click/dz_click2 里已经带了 page == 5 的守卫（见它们的解码处）：
                // 其它页面上这两块面积是别的东西（P1 上它是卡片 13/14 的下半）。
                // ★ v34（㊲）：这里从"按下那拍"改成"抬起那拍"（dz_click）——
                //   按下不再进询问态，免得遮罩把按下反馈盖掉。
                // ★ v42：第 2 颗按钮同时要求序列空闲（正在跑就不要再排一次）。
                if (dz_click) begin
                    dlg      <= 2'd1;
                    dlg_kind <= 1'b0;
                end
                else if (dz_click2 && !rst_busy) begin
                    dlg      <= 2'd1;
                    dlg_kind <= 1'b1;
                end
            end
            2'd1: begin
                // 模态期间**只看原始坐标**，hit_id 一概不认（被遮住的控件不许响应）
                if (hit_stb && dlg_hit_no)
                    dlg <= 2'd0;                  // 取消：一个字节都不发
                else if (hit_stb && dlg_hit_yes) begin
                    dlg <= 2'd2;
                    if (dlg_kind) rst_req <= 1'b1; // 启动 13 条命令的序列
                    else          w1c_req <= 1'b1; // 发 0x0405 <- 1
                end
            end
            default: begin                        // 2'd2：等动作结束
                if (dlg_kind ? rst_done : w1c_done)
                    dlg <= 2'd0;
            end
            endcase
        end
    end

    ui_edit #(
        .BAUD_DIV   (25),                      // 2 Mbaud
        .GAP_CLK    (4000),                    // 80 µs
        .SETTLE_CLK (100_000),                 // VERIFY=0 用不到，留默认值
        .CMD_B0     (8'h80 | 8'h08 | 8'h04),   // = 8'h8C（写命令 + 0x04 区）
        .CMD_B1     (8'h05),                   // addr[7:0] = 0x05 -> 0x0405
        .VERIFY     (0)                        // W1C 不能走相等校验（见 ui_edit 头注释）
    ) u_ui_w1c (
        .clk        (sys_clk),
        .rst_n      (rst_sync),
        .req        (w1c_req),
        .inter_enc  (10'h0FF),                 // ★ v82：b3 = 0xFF -> 清全部锁存位
                                               //   （原来是 10'd1 只清 bit0；见上方
                                               //    "锁存自动老化" 注释）
        .div_code   (3'd0),                    // b2 = 0x00 -> 0x0406 只读，写 0 无副作用
        .tap_inter  (tap_inter),
        .tap_div    (tap_div),
        .tx_line    (w1c_tx_line),
        .tx_busy    (w1c_busy),
        .state      (w1c_state),
        .done       (w1c_done)
        // ok_inter / ok_div / err_code / txn_cnt / fail_cnt 不接：VERIFY=0 的
        //   实例不产生这些语义（没有回读、没有回滚），done 就是全部结果。
    );

    //=========================================================================
    // 4.11b v42（㊴）：恢复默认的命令序列（disp/ui_restore.v）
    //   13 条 4 字节写命令 = 16 个寄存器 = P6 可见的 15 项 + 标定偏置 OFS_S/OFS_C。
    //   全部发完再等 2 ms、然后拿下面这 17 个抽头字段逐项比对复位默认值。
    //   ★ 一条新协议命令都没有，冻结契约 rtl/SPEC_interface_contract.md 一行不改。
    //   ★ GAP_CLK = 500 µs（不是 80 µs）：rtl/uart_spi_bridge.v 在"内部 SPI 帧 +
    //     等遥测空闲 + 发 6 字节应答"这段窗口里不看 rx，90 µs 左右的下一条命令会
    //     被整条丢掉 —— 详见 disp/ui_restore.v 头注释的"为什么命令之间要空 500 µs"。
    //=========================================================================
    ui_restore #(
        .BAUD_DIV   (25),                      // 2 Mbaud
        .GAP_CLK    (25_000),                  // 500 µs（桥的处理窗口 ~160 µs 的 3 倍）
        .SETTLE_CLK (100_000)                  // 2 ms（等桥释放 + 遥测帧恢复）
    ) u_ui_rst (
        .clk        (sys_clk),
        .rst_n      (rst_sync),
        .start      (rst_req),
        .tap_pairs  (tap_pairs),
        .tap_inter  (tap_inter),
        .tap_div    (tap_div),
        .tap_hyst_ab(tap_hyst_ab),
        .tap_ablimit(tap_ablimit),
        .tap_zwidth (tap_zwidth),
        .tap_zphase (tap_zphase),
        .tap_uvwph  (tap_uvwph),
        .tap_pol    (tap_pol),
        .tap_abzen  (tap_abzen),
        .tap_uwven  (tap_uwven),
        .tap_shift  (tap_shift),
        .tap_ofs_s  (tap_ofs_s),
        .tap_ofs_c  (tap_ofs_c),
        .tap_gain_s (tap_gain_s),
        .tap_gain_c (tap_gain_c),
        .tap_phase_k(tap_phase_k),
        .tx_line    (rst_tx_line),
        .busy       (rst_busy),
        .done       (rst_done),
        .state      (rst_state),
        .bad        (rst_bad)
    );

    disp_engine #(.CPR(DISP_CPR)) u_disp (
        .clk            (sys_clk),
        .rst_n          (rst_sync),
        .page           (page),
        .p2_gear        (p2_gear),
        .pix_x          (pix_x),
        .pix_y          (pix_y),
        .de             (de),
        .tap_angle      (tap_angle),
        .tap_s_n        (tap_s_n),
        .tap_c_n        (tap_c_n),
        .tap_pos_full   (tap_pos_full),
        .tap_io_state   (tap_io_state),
        .tap_io_flags   (tap_io_flags),
        .tap_stat       (tap_stat),
        .tap_cfg_inter  (tap_inter),
        .tap_cfg_div    (tap_div),
        .tap_cfg_pairs  (tap_pairs),
        .tap_cfg_hyst_ab(tap_hyst_ab),
        .tap_cfg_ablimit(tap_ablimit),
        .tap_cfg_zwidth (tap_zwidth),
        .tap_cfg_zphase (tap_zphase),
        .tap_cfg_uvwph  (tap_uvwph),
        .tap_cfg_pol    (tap_pol),
        .tap_ofs_s      (tap_ofs_s),
        .tap_ofs_c      (tap_ofs_c),
        .tap_gain_s     (tap_gain_s),
        .tap_gain_c     (tap_gain_c),
        .tap_phase_k    (tap_phase_k),
        .tap_shift      (tap_shift),
        .tap_amp_sq     (tap_amp_sq),
        .tap_amp_low_sq (tap_amp_low_sq),
        .tap_amp_high_sq(tap_amp_high_sq),
        .tap_abzen      (tap_abzen),
        .tap_uwven      (tap_uwven),
        .tap_calib_busy (tap_calib_busy),
        // v45（㊷）/v46（㊸）空态：两个原链路判据源在 v74 后恒 0，
        //   空态实际只剩"无载波"一个源（amp 抽头在 disp_engine 里比值比出来）
        .tap_link_crc_err (tap_link_crc_err),
        .tap_link_lost  (tap_link_lost),
        .tch_diag       (tch_diag),
        .ui_state       (ui_state),
        .ui_err         (ui_err),
        .ui_dlg         (dlg),
        // v34（㊲）：按住电平（只画内嵌框，不参与写寄存器判定）
        .ui_dz_press    (dz_prs_lvl),
        // v42（㊴）：第 2 颗按钮的按住电平 / 当前在问哪一件事 / 恢复序列的结果
        .ui_dz_press2   (dz_prs_lvl2),
        .ui_dlg_kind    (dlg_kind),
        .ui_rst_state   (rst_state),
        .ui_rst_bad     (rst_bad),
        .ui_blink_en    (scr_blink),
        .demo_on        (demo_on),
        .pnl_on         (pnl_on),
        .pnl_inter      (pnl_inter),
        .pnl_fld        (pnl_fld),
        .pnl_didx       (pnl_didx),
        .pnl_prog       (pnl_prog),
        .pnl_press      (pnl_press),
        .pnl_pend       (pnl_pend),
        .pnl_idx        (pnl_idx),
        .pnl_undo_avail (pnl_undo_avail),
        .pnl_undo_inter (pnl_undo_inter),
        .pnl_undo_div   (pnl_undo_div),     // v44（㊶）：撤销标签末尾的 ÷M
        // v33（㉚）数字键盘（绘制层据此把面板换成键盘）
        .pnl_kp_on      (pnl_kp_on),
        .pnl_kp_d2      (pnl_kp_d2),
        .pnl_kp_d1      (pnl_kp_d1),
        .pnl_kp_d0      (pnl_kp_d0),
        .pnl_kp_dig     (pnl_kp_dig),
        .pnl_kp_sel     (pnl_kp_sel),
        .lcd_rgb        (lcd_rgb_o),
        .de_o           (disp_de),
        .dbg_x          (dbg_x),
        .dbg_y          (dbg_y)
    );

    assign lcd_rgb = lcd_rgb_o;

    //=========================================================================
    // 6. 实验探针：帧计数（低 8 位）
    //    上板判据：disp_test[7:0] 每帧 +1（58.6 次/s）。计数不动 ⇒ 时序发生器
    //    或显示引擎已经停摆；计数在动但屏是黑/花屏 ⇒ 问题在渲染内容而非时序。
    //    ★ 用一个 8 bit 计数器而不是把内部信号引出来，是为了不改变被测量对象
    //      本身的扇出（观测不能扰动被测对象）。
    //=========================================================================
    reg vs_d = 1'b1;
    reg [7:0] frame_cnt = 8'd0;

    always @(posedge sys_clk) begin
        vs_d <= vs;
        if (vs_d && !vs) frame_cnt <= frame_cnt + 8'd1;
    end

    assign disp_test = frame_cnt;

endmodule
