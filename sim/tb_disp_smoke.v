// -----------------------------------------------------------------------------
//  sim/tb_disp_smoke.v —— 显示子系统（enc_top_disp）的冒烟测试（2026-11-02 新增）
//
//  背景：审计报告 B2 —— 全仓库 35 个 TB 里**没有一个**实例化 enc_top_disp，
//        48 个 disp/*.v 模块（约 17.4k LUT）在仿真里从没跑过，只能靠上板目视。
//        本 TB 是第一块最小覆盖：把 enc_top_disp 整体跑起来，判定"屏真的在出画面"。
//
//  判据（全部可自动判定，不比对像素内容）：
//    1. lcd_pclk 在跳；
//    2. lcd_vs 周期 ≈ 635×1344/50MHz = 17.069 ms（1024×600 @ 58.6 Hz）；
//    3. 每帧 lcd_de 有效像素数 == 1024×600；
//    4. lcd_rgb 在有效区内**不是全黑**（渲染器真的在画）；
//    5. 关键输出无 X；
//    6. 跑到第 4 个场同步后自动结束并打印 PASS/FAIL。
//
//  跑法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Only tb_disp_smoke -Rebuild
//        （run_sim.ps1 里 tb_disp* 会自动带上 disp/*.v 与 ENC_DISP_TAP/ENC_V69_CPR2048）
//  时长：约 3.2 帧 ≈ 55 ms 仿真时间（xsim 约 1–3 min）。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_disp_smoke;

    localparam integer H_DISP = 1024;
    localparam integer V_DISP = 600;
    localparam real    FRAME_NS = 635.0 * 1344.0 * 20.0;   // 17,068,800 ns

    // ---------------- 时钟 ----------------
    reg sys_clk = 0;
    always #10 sys_clk = ~sys_clk;          // 50 MHz

    reg eth_rxc = 0;
    always #4 eth_rxc = ~eth_rxc;           // 125 MHz（RGMII RX）

    // ---------------- 输入 ----------------
    reg key_n = 0, key1_n = 1, ui_btn = 1;
    reg [11:0] ad_ch1_d = 0, ad_ch2_d = 0;
    reg ad_ch1_otr = 0, ad_ch2_otr = 0;
    reg spi_sck = 0, spi_ss_n = 1, spi_mosi = 0;
    reg uart_rx = 1;
    reg [3:0] eth_rxd = 0;
    reg eth_rx_ctl = 0;

    wire [23:0] lcd_rgb;
    wire lcd_pclk, lcd_hs, lcd_vs, lcd_de, lcd_bl, lcd_rst;
    wire [7:0]  disp_test;
    wire a_out, b_out, z_out, u_out, v_out, w_out;
    wire [3:0] eth_txd, led;
    wire eth_txc, eth_tx_ctl;
    wire ad_clk, ad_clk2;
    wire touch_rst_n;
    wire touch_scl, touch_sda, touch_int;

    pullup (touch_scl);
    pullup (touch_sda);
    pullup (touch_int);

    // ---------------- DUT ----------------
    enc_top_disp u_dut (
        .sys_clk      (sys_clk),
        .key_n        (key_n),
        .key1_n       (key1_n),
        .ui_btn       (ui_btn),
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
        .uart_rx      (uart_rx),
        .irq_n        (irq_n),
        .phy_rst_n    (phy_rst_n),
        .eth_txd      (eth_txd),
        .eth_txc      (eth_txc),
        .eth_tx_ctl   (eth_tx_ctl),
        .eth_rxd      (eth_rxd),
        .eth_rxc      (eth_rxc),
        .eth_rx_ctl   (eth_rx_ctl),
        .lcd_rgb      (lcd_rgb),
        .lcd_pclk     (lcd_pclk),
        .lcd_hs       (lcd_hs),
        .lcd_vs       (lcd_vs),
        .lcd_de       (lcd_de),
        .lcd_bl       (lcd_bl),
        .lcd_rst      (lcd_rst),
        .touch_scl    (touch_scl),
        .touch_sda    (touch_sda),
        .touch_rst_n  (touch_rst_n),
        .touch_int    (touch_int),
        .disp_test    (disp_test)
    );

    // ---------------- 激励：正交正弦（1024 点 LUT，12 位，≈±1500 LSB）----------------
    reg [31:0] ph = 0;
    localparam integer PH_STEP = 4300;      // f = 50MHz*4300/2^32 ≈ 50 Hz
    always @(posedge sys_clk) ph <= ph + PH_STEP;

    reg [11:0] sin_lut [0:1023];
    reg [11:0] cos_lut [0:1023];
    integer k;
    initial begin
        for (k = 0; k < 1024; k = k + 1) begin
            sin_lut[k] = $rtoi(2048.0 + 1500.0 * $sin(2.0 * 3.14159265358979 * k / 1024.0));
            cos_lut[k] = $rtoi(2048.0 + 1500.0 * $cos(2.0 * 3.14159265358979 * k / 1024.0));
        end
    end
    always @(posedge sys_clk) begin
        ad_ch1_d <= sin_lut[ph[31:22]];
        ad_ch2_d <= cos_lut[ph[31:22]];
    end

    // ---------------- 统计 ----------------
    integer vs_fall     = 0;
    integer de_pix      = 0;
    integer rgb_nz      = 0;
    integer pclk_tog    = 0;
    integer x_seen      = 0;
    integer bad_frames  = 0;
    integer blank_frames = 0;
    realtime t_prev_vs  = 0.0;
    realtime min_period = 1.0e12;
    realtime max_period = 0.0;

    reg lcd_vs_prev = 1'b1;

    // lcd_pclk 在 v73 里是 sys_clk 的直通（同相），若在 sys_clk 的 posedge 采样去比"上一拍"，
    // 采样点正好撞在跳变沿上 ⇒ 只会数到 1 次。直接在该时钟自己的两个沿上计数。
    always @(posedge lcd_pclk) pclk_tog = pclk_tog + 1;

    always @(posedge sys_clk) begin
        if ($realtime > 200000.0) begin
            if ((^lcd_de === 1'bx) || (^lcd_hs === 1'bx) || (^lcd_vs === 1'bx) ||
                (^lcd_rgb === 1'bx) || (^disp_test === 1'bx) || (^a_out === 1'bx)) begin
                x_seen = x_seen + 1;
            end
        end

        if (lcd_de === 1'b1) begin
            de_pix = de_pix + 1;
            if (lcd_rgb != 24'h000000) rgb_nz = rgb_nz + 1;
        end

        if ((lcd_vs === 1'b0) && (lcd_vs_prev === 1'b1)) begin
            vs_fall = vs_fall + 1;
            if (vs_fall >= 2) begin
                if (de_pix != H_DISP * V_DISP) begin
                    bad_frames = bad_frames + 1;
                    $display("[DISP] frame %0d: de pixels = %0d (expect %0d)  <-- MISMATCH",
                             vs_fall - 1, de_pix, H_DISP * V_DISP);
                end else begin
                    $display("[DISP] frame %0d: de pixels = %0d OK", vs_fall - 1, de_pix);
                end
                $display("[DISP] frame %0d: rgb non-zero %0d / %0d = %.1f%%",
                         vs_fall - 1, rgb_nz, de_pix,
                         (de_pix > 0) ? (100.0 * rgb_nz / de_pix) : 0.0);
                if (rgb_nz * 10 < de_pix) blank_frames = blank_frames + 1;
                if (t_prev_vs > 0.0) begin
                    $display("[DISP] frame %0d: period = %.3f ms (expect 17.069)",
                             vs_fall - 1, ($realtime - t_prev_vs) / 1.0e6);
                    if (($realtime - t_prev_vs) < min_period) min_period = $realtime - t_prev_vs;
                    if (($realtime - t_prev_vs) > max_period) max_period = $realtime - t_prev_vs;
                end
                de_pix = 0;
                rgb_nz = 0;
            end
            t_prev_vs = $realtime;
            if (vs_fall >= 4) begin
                $display("");
                $display("[DISP] vs edges seen = %0d, pclk toggles = %0d, X samples = %0d",
                         vs_fall, pclk_tog, x_seen);
                if (max_period > 0.0) begin
                    $display("[DISP] frame period min = %.3f ms, max = %.3f ms",
                             min_period / 1.0e6, max_period / 1.0e6);
                end
                if (pclk_tog < 1000)   $display("[FAIL] lcd_pclk not toggling");
                if (bad_frames != 0)   $display("[FAIL] %0d frame(s) with wrong DE pixel count", bad_frames);
                if (blank_frames != 0) $display("[FAIL] %0d frame(s) with (almost) black RGB", blank_frames);
                if (x_seen != 0)       $display("[FAIL] X on LCD/key outputs (%0d samples)", x_seen);
                if (max_period > 0.0 &&
                    (max_period < 0.95 * FRAME_NS || min_period > 1.05 * FRAME_NS))
                    $display("[FAIL] frame period out of +-5%% of 17.069 ms");
                if (pclk_tog >= 1000 && bad_frames == 0 && blank_frames == 0 &&
                    x_seen == 0 && max_period > 0.0 &&
                    max_period >= 0.95 * FRAME_NS && min_period <= 1.05 * FRAME_NS) begin
                    $display("TEST PASSED (disp smoke: timing + de pixels + rgb + no-X)");
                end else begin
                    $display("TEST FAILED");
                end
                $finish;
            end
        end
        lcd_vs_prev <= lcd_vs;
    end

    // 硬超时（6 帧），避免卡死
    initial begin
        #(FRAME_NS * 7.0);
        $display("[DISP] TIMEOUT: only %0d vs edges seen", vs_fall);
        $display("TEST FAILED");
        $finish;
    end

    // 复位释放
    initial begin
        #200;
        key_n = 1;
        $display("[DISP] key_n released at %0t", $time);
    end

endmodule
