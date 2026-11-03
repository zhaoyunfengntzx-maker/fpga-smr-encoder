//=============================================================================
// sim/tb_lowsig.v —— v67 小信号版（200–300 mVpp，前端 4.16×）验收测试台
//-----------------------------------------------------------------------------
// 对应位流：_impl_lowsig/enc_top_lowsig.bit（tools/impl_check_lowsig.tcl）
// 对应 RTL：_synth_work_lowsig/rtl_lowsig/（tools/make_lowsig_rtl.py 生成）
//          与 rtl/ 的唯一差异：POLE_BITS=6、RTL_BUILD_ID=0x000F、
//          GAIN_S/GAIN_C 复位 49152（Q1.15 ×1.5）
//
// 物理换算
//   AD9238 差分满量程 2 Vpp = 4096 码；SMA 端 1 LSB = 488 µV/4.16 ≈ 117 µV。
//   200 mVpp → 1704 码峰峰 → 峰值 852 码
//   250 mVpp → 2130 码峰峰 → 峰值 1065 码
//   300 mVpp → 2556 码峰峰 → 峰值 1278 码
//   默认数字增益 1.5 后：0.624 / 0.780 / 0.937 FS，全部落在 [0.60,1.20]。
//
// 覆盖
//   T1  200 mVpp + 默认 1.5：amp_ok、TRACK、无饱和、amp_sq≈0.39·2^30
//   T2  300 mVpp + 默认 1.5：仍 TRACK、16bit 不饱和（0.937 FS）
//   T3  250 mVpp + 默认 1.5：中间点
//   T4  200 mVpp 一键标定：done、GAIN≈1.92、SHIFT=0、校正后 amp_sq≈0.64·2^30
//   T5  A/B 对照：把增益强拉回 1.0（旧程序默认）⇒ amp_low=1、丢 TRACK；
//       释放后恢复校准增益 ⇒ 重新 TRACK（证明 v67 的默认增益是必要的）
//
// 说明
//   * 本台只做功能验收；角度精度/ABZ 边沿率仍由 tb_enc_top / tb_abz_gen 覆盖。
//   * 相位步进 32/65536 ⇒ 2048 clk/电周期（40.96 µs，24.4 kHz 电频率），
//     64 电周期/机械圈。选这个速度是为了让 64 周期标定窗口在 ~13 万拍内跑完，
//     同时仍处于"低速手转"量级（lag_ff 的 9 抽样点延迟补偿有效）。
//   * 按键去抖 1.3 ms（65536 clk），所以 T4 把 key_n 拉低 70000 拍再释放。
//=============================================================================
`timescale 1ns/1ps

module tb_lowsig;

    localparam integer CLK_HALF  = 10;          // 50 MHz
    localparam integer PH_STEP   = 32;          // 2048 clk / 电周期
    localparam integer CLK_CYC   = 65536 / PH_STEP;
    localparam integer AMP200    = 852;
    localparam integer AMP250    = 1065;
    localparam integer AMP300    = 1278;

    reg         sys_clk;
    reg         key_n;
    wire        ad_clk;
    wire [11:0] ad_ch1_d;
    wire [11:0] ad_ch2_d;
    reg         ad_ch1_otr;
    reg         ad_ch2_otr;
    wire        a_out, b_out, z_out, u_out, v_out, w_out;
    reg         spi_sck, spi_ss_n, spi_mosi;
    wire        spi_miso;
    wire [3:0]  led;
    wire        uart_tx;
    reg         uart_rx;
    wire        irq_n;

    reg  [15:0] ph;
    reg  [1:0]  amp_sel;              // 0=200, 1=250, 2=300 mVpp
    integer     pass_cnt, fail_cnt;
    integer     timeout;
    integer     cal_gain_s, cal_gain_c;   // T4 标定后的 GAIN，T5 用来回写

    // ---- 64k 点正弦表（峰值 1278 码），余弦由 +90° 索引得到 ----
    reg signed [11:0] sin_lut [0:65535];
    reg signed [11:0] cos_lut [0:65535];
    integer li;
    initial begin
        for (li = 0; li < 65536; li = li + 1) begin
            sin_lut[li] = $rtoi(1278.0 * $sin(2.0 * 3.141592653589793 * li / 65536.0));
        end
        for (li = 0; li < 65536; li = li + 1) begin
            cos_lut[li] = sin_lut[(li + 16384) & 16'hFFFF];
        end
    end

    wire signed [11:0] s_full = sin_lut[ph];
    wire signed [11:0] c_full = cos_lut[ph];

    // 峰值缩放：300→1278，250→1278*5/6=1065，200→1278*2/3=852
    wire signed [11:0] s_amp = (amp_sel == 2'd0) ? (s_full * 2) / 3 :
                               (amp_sel == 2'd1) ? (s_full * 5) / 6 : s_full;
    wire signed [11:0] c_amp = (amp_sel == 2'd0) ? (c_full * 2) / 3 :
                               (amp_sel == 2'd1) ? (c_full * 5) / 6 : c_full;

    // 二进制补码 -> ADC 偏移二进制（0x800 = 0 V）
    assign ad_ch1_d = s_amp ^ 12'h800;
    assign ad_ch2_d = c_amp ^ 12'h800;

    initial sys_clk = 1'b0;
    always #CLK_HALF sys_clk = ~sys_clk;

    always @(posedge sys_clk) ph <= ph + 16'd32;

    // ---- DUT ----
    enc_top #(
        .AW            (16),
        .FRAC          (8),
        .LOG2DEC       (2),
        .BAUD_DIV      (25),
        .SAMPLE_DIV    (5000),
        .CLK_PERIOD_NS (20),
        .POR_BITS      (4),
        .POLE_BITS     (6)
    ) dut (
        .sys_clk    (sys_clk),
        .key_n      (key_n),
        .ad_clk     (ad_clk),
        .ad_ch1_d   (ad_ch1_d),
        .ad_ch2_d   (ad_ch2_d),
        .ad_ch1_otr (ad_ch1_otr),
        .ad_ch2_otr (ad_ch2_otr),
        .a_out      (a_out),
        .b_out      (b_out),
        .z_out      (z_out),
        .u_out      (u_out),
        .v_out      (v_out),
        .w_out      (w_out),
        .spi_sck    (spi_sck),
        .spi_ss_n   (spi_ss_n),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .led        (led),
        .uart_tx    (uart_tx),
        .irq_n      (irq_n),
        .uart_rx    (uart_rx)
    );

    task wait_clk;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge sys_clk);
        end
    endtask

    task chk;
        input             cond;
        input [255:0]     id;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("  [ok  ] %0s", id);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s", id);
            end
        end
    endtask

    initial begin
        sys_clk    = 1'b0;
        key_n      = 1'b1;
        ad_ch1_otr = 1'b0;
        ad_ch2_otr = 1'b0;
        spi_sck    = 1'b0;
        spi_ss_n   = 1'b1;
        spi_mosi   = 1'b0;
        uart_rx    = 1'b1;
        ph         = 16'd0;
        amp_sel    = 2'd0;
        pass_cnt   = 0;
        fail_cnt   = 0;

        wait_clk(200);      // POR_BITS=4 + 同步/去抖余量

        //-----------------------------------------------------------------
        // v68 起 RTL 复位默认 GAIN=1.0（32768），幅值窗也改到 288–481 mVpp；
        // 本 TB 检验的是"低幅值 + 数字增益 1.5"这条通路，因此这里显式把增益
        // 写成 1.5（49152），不再依赖复位默认值（复位默认值由 tb_reg_file 覆盖）。
        dut.u_regs.r_gain_s = 16'd49152;
        dut.u_regs.r_gain_c = 16'd49152;
        wait_clk(4);

        $display("\n[TEST T1] 200 mVpp (1704 codes pp), gain forced 1.5, bipolar 0 V");
        amp_sel = 2'd0;
        wait_clk(30 * CLK_CYC);            // 30 电周期 ≈ 1.23 ms > 1 ms 锁定窗口

        chk(dut.u_regs.r_gain_s === 16'd49152, "T1-gain_S-1.5-applied");
        chk(dut.u_regs.r_gain_c === 16'd49152, "T1-gain_C-1.5-applied");
        chk(dut.u_regs.r_inter0 === 8'd32,      "T1-default-INTER0-32");
        chk(dut.cfg_inter === 10'd32,           "T1-default-cfg_inter-32");
        chk(dut.amp_low   === 1'b0,               "T1-200mV-amp-not-low");
        chk(dut.amp_high  === 1'b0,               "T1-200mV-amp-not-high");
        chk(dut.amp_ok    === 1'b1,               "T1-200mV-amp-ok");
        chk(dut.cor_sat   === 1'b0,               "T1-200mV-no-corr-sat");
        chk(dut.lock_state === 2'd1,              "T1-200mV-TRACK");
        chk(dut.amp_sq > 32'd350000000 && dut.amp_sq < 32'd480000000,
            "T1-200mV-amp_sq-0.39FS");

        //-----------------------------------------------------------------
        $display("\n[TEST T2] 300 mVpp (2556 codes pp), default gain 1.5");
        amp_sel = 2'd2;
        wait_clk(12 * CLK_CYC);

        chk(dut.amp_low   === 1'b0, "T2-300mV-amp-not-low");
        chk(dut.amp_high  === 1'b0, "T2-300mV-amp-not-high");
        chk(dut.amp_ok    === 1'b1, "T2-300mV-amp-ok");
        chk(dut.cor_sat   === 1'b0, "T2-300mV-no-corr-sat");
        chk(dut.lock_state === 2'd1, "T2-300mV-TRACK");
        chk(dut.amp_sq > 32'd850000000 && dut.amp_sq < 32'd1020000000,
            "T2-300mV-amp_sq-0.88FS");

        //-----------------------------------------------------------------
        $display("\n[TEST T3] 250 mVpp (2130 codes pp), default gain 1.5");
        amp_sel = 2'd1;
        wait_clk(6 * CLK_CYC);

        chk(dut.amp_ok    === 1'b1, "T3-250mV-amp-ok");
        chk(dut.amp_low   === 1'b0, "T3-250mV-amp-not-low");
        chk(dut.lock_state === 2'd1, "T3-250mV-TRACK");
        chk(dut.amp_sq > 32'd560000000 && dut.amp_sq < 32'd740000000,
            "T3-250mV-amp_sq-0.61FS");

        //-----------------------------------------------------------------
        $display("\n[TEST T4] one-key calibration at 200 mVpp (64 cycles window)");
        amp_sel = 2'd0;
        wait_clk(4 * CLK_CYC);

        key_n = 1'b0;
        wait_clk(70000);                    // > 65536 去抖
        key_n = 1'b1;

        timeout = 0;
        while ((dut.calib_done !== 1'b1) && (timeout < 600000)) begin
            @(posedge sys_clk);
            timeout = timeout + 1;
        end

        chk(dut.calib_done === 1'b1, "T4-calib-done");
        chk(dut.calib_busy === 1'b0, "T4-calib-not-busy");
        chk($unsigned(dut.res_gain_s) > 60000 && $unsigned(dut.res_gain_s) < 67000,
            "T4-res-GAIN_S-1.92");
        chk($unsigned(dut.res_gain_c) > 60000 && $unsigned(dut.res_gain_c) < 67000,
            "T4-res-GAIN_C-1.92");
        chk(dut.res_shift_s === 2'd0, "T4-res-SHIFT_S-0");
        chk(dut.res_shift_c === 2'd0, "T4-res-SHIFT_C-0");

        wait_clk(8 * CLK_CYC);
        chk(dut.amp_ok   === 1'b1, "T4-postcal-amp-ok");
        chk(dut.amp_low  === 1'b0, "T4-postcal-amp-not-low");
        chk(dut.amp_high === 1'b0, "T4-postcal-amp-not-high");
        chk(dut.lock_state === 2'd1, "T4-postcal-TRACK");
        chk(dut.amp_sq > 32'd630000000 && dut.amp_sq < 32'd740000000,
            "T4-postcal-amp_sq-0.64FS");
        $display("  [dbg] T4 gain_reg=%0d gain_c_reg=%0d shift_reg=%0d amp_sq=%0d",
                 dut.u_regs.r_gain_s, dut.u_regs.r_gain_c, dut.u_regs.r_shift_s, dut.amp_sq);

        //-----------------------------------------------------------------
        $display("\n[TEST T5] A/B: force gain 1.0 (old default) at 200 mVpp");
        cal_gain_s = dut.u_regs.r_gain_s;
        cal_gain_c = dut.u_regs.r_gain_c;
        $display("  [dbg] T5 before force: gain_reg=%0d amp_sq=%0d amp_low=%b",
                 dut.u_regs.r_gain_s, dut.amp_sq, dut.amp_low);
        force dut.u_regs.r_gain_s = 16'd32768;
        force dut.u_regs.r_gain_c = 16'd32768;
        wait_clk(12 * CLK_CYC);

        $display("  [dbg] T5 forced: gain_reg=%0d amp_sq=%0d amp_low=%b",
                 dut.u_regs.r_gain_s, dut.amp_sq, dut.amp_low);
        chk(dut.amp_low === 1'b1,        "T5-gain1.0-amp-low");
        chk(dut.lock_state !== 2'd1,     "T5-gain1.0-not-TRACK");

        release dut.u_regs.r_gain_s;
        release dut.u_regs.r_gain_c;
        // xsim 的 release 对"只由时序 always 偶尔赋值"的 reg 不会自动回填旧值，
        // 会停在被 force 的 32768；这里显式写回 T4 的标定增益，等价于上位机
        // 重新下发系数。RTL 行为不受影响，T5 验的是"增益恢复后环路能重新锁定"。
        force dut.u_regs.r_gain_s = cal_gain_s;
        force dut.u_regs.r_gain_c = cal_gain_c;
        wait_clk(30 * CLK_CYC);           // > 1 ms 恢复窗口（12500 抽样）

        $display("  [dbg] T5 released: gain_reg=%0d amp_sq=%0d amp_low=%b lock=%0d",
                 dut.u_regs.r_gain_s, dut.amp_sq, dut.amp_low, dut.lock_state);
        chk(dut.amp_low === 1'b0,        "T5-release-amp-not-low");
        chk(dut.lock_state === 2'd1,     "T5-release-TRACK-again");

        //-----------------------------------------------------------------
        $display("\n==== RESULT: %0d passed, %0d failed ====", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("TEST PASSED");
        else               $display("TEST FAILED");
        $finish;
    end

    // 看门狗：正常 ~1.2 M 拍（24 ms）；50 ms 仍未结束则报错退出
    initial begin
        #50_000_000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
