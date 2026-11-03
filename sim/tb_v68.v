//=============================================================================
// sim/tb_v68.v —— v68（400 mVpp 单端正交，前端 4.16×，带显示屏）验收测试台
//-----------------------------------------------------------------------------
// 对应位流（生产）：_impl_v68/enc_top_v68.bit
// 对应位流（显示）：_impl_disp_v68/enc_top_disp_v68.bit
// 对应 RTL：_synth_work_v68/rtl_v68/（tools/make_v68_rtl.py 生成）
//          与 v66 的差异：POLE_BITS=6、RTL_BUILD_ID=0x0010、INTER0=32；
//          GAIN_S/GAIN_C 保持 32768（1.0），因为 400 mVpp 已经到 0.832 FS。
//
// 物理换算
//   AD9238 差分满量程 2 Vpp = 4096 码；SMA 端 1 LSB = 488 µV/4.16 ≈ 117 µV。
//   400 mVpp → 3408 码峰峰 → 峰值 1704 码 → 0.832 FS
//   350 mVpp → 2982 码峰峰 → 峰值 1491 码 → 0.728 FS
//   450 mVpp → 3834 码峰峰 → 峰值 1917 码 → 0.936 FS
//   不削顶最大输入 481 mVpp（1.0 FS）。
//
// 覆盖
//   T1  400 mVpp + 默认 1.0：amp_ok、TRACK、无饱和、amp_sq≈0.69·2^30
//   T2  450 mVpp：仍 TRACK、不饱和（0.936 FS）
//   T3  350 mVpp：中间点（0.728 FS）
//   T4  400 mVpp 一键标定：done、GAIN≈0.96、SHIFT=0、校正后 amp_sq≈0.64·2^30
//   T5  A/B：把增益强拉回 v67 的 1.5 ⇒ 1.248 FS，amp_high/cor_sat=1、丢 TRACK；
//       恢复 1.0 ⇒ 重新 TRACK（证明 400 mVpp 不能沿用 v67 的默认 1.5）
//
// 说明
//   * 本台只做功能验收；角度精度/ABZ 边沿率仍由 tb_enc_top / tb_abz_gen 覆盖。
//   * 相位步进 32/65536 ⇒ 2048 clk/电周期（40.96 µs，24.4 kHz 电频率），
//     64 电周期/机械圈。选这个速度是为了让 64 周期标定窗口在 ~13 万拍内跑完，
//     同时仍处于“低速手转”量级（lag_ff 的 9 抽样点延迟补偿有效）。
//   * 按键去抖 1.3 ms（65536 clk），所以 T4 把 key_n 拉低 70000 拍再释放。
//=============================================================================
`timescale 1ns/1ps

module tb_v68;

    localparam integer CLK_HALF  = 10;          // 50 MHz
    localparam integer PH_STEP   = 32;          // 2048 clk / 电周期
    localparam integer CLK_CYC   = 65536 / PH_STEP;
    localparam integer AMP400    = 1704;
    localparam integer AMP350    = 1491;
    localparam integer AMP450    = 1917;

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
    reg  [1:0]  amp_sel;              // 0=400, 1=350, 2=450 mVpp
    integer     pass_cnt, fail_cnt;
    integer     timeout;
    integer     k;
    reg         saw_high;                 // T5：一个电周期内是否见过 amp_high
    integer     cal_gain_s, cal_gain_c;   // T4 标定后的 GAIN，T5 用来回写

    // ---- 64k 点正弦表（峰值 1917 码 = 450 mVpp），余弦由 +90° 索引得到 ----
    reg signed [11:0] sin_lut [0:65535];
    reg signed [11:0] cos_lut [0:65535];
    integer li;
    initial begin
        for (li = 0; li < 65536; li = li + 1) begin
            sin_lut[li] = $rtoi(1917.0 * $sin(2.0 * 3.141592653589793 * li / 65536.0));
        end
        for (li = 0; li < 65536; li = li + 1) begin
            cos_lut[li] = sin_lut[(li + 16384) & 16'hFFFF];
        end
    end

    wire signed [11:0] s_full = sin_lut[ph];
    wire signed [11:0] c_full = cos_lut[ph];

    // 峰值缩放：450→1917，400→1917*8/9=1704，350→1917*7/9=1491
    wire signed [11:0] s_amp = (amp_sel == 2'd0) ? (s_full * 8) / 9 :
                               (amp_sel == 2'd1) ? (s_full * 7) / 9 : s_full;
    wire signed [11:0] c_amp = (amp_sel == 2'd0) ? (c_full * 8) / 9 :
                               (amp_sel == 2'd1) ? (c_full * 7) / 9 : c_full;

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
        $display("\n[TEST T1] 400 mVpp (3408 codes pp), default gain 1.0, bipolar 0 V");
        amp_sel = 2'd0;
        wait_clk(30 * CLK_CYC);            // 30 电周期 ≈ 1.23 ms > 1 ms 锁定窗口

        chk(dut.u_regs.r_gain_s === 16'd32768, "T1-default-GAIN_S-1.0");
        chk(dut.u_regs.r_gain_c === 16'd32768, "T1-default-GAIN_C-1.0");
        chk(dut.u_regs.r_inter0 === 8'd32,      "T1-default-INTER0-32");
        chk(dut.cfg_inter === 10'd32,           "T1-default-cfg_inter-32");
        chk(dut.amp_low   === 1'b0,               "T1-400mV-amp-not-low");
        chk(dut.amp_high  === 1'b0,               "T1-400mV-amp-not-high");
        chk(dut.amp_ok    === 1'b1,               "T1-400mV-amp-ok");
        chk(dut.cor_sat   === 1'b0,               "T1-400mV-no-corr-sat");
        chk(dut.lock_state === 2'd1,              "T1-400mV-TRACK");
        chk(dut.amp_sq > 32'd680000000 && dut.amp_sq < 32'd810000000,
            "T1-400mV-amp_sq-0.69FS");

        //-----------------------------------------------------------------
        $display("\n[TEST T2] 450 mVpp (3834 codes pp), default gain 1.0");
        amp_sel = 2'd2;
        wait_clk(12 * CLK_CYC);

        chk(dut.amp_low   === 1'b0, "T2-450mV-amp-not-low");
        chk(dut.amp_high  === 1'b0, "T2-450mV-amp-not-high");
        chk(dut.amp_ok    === 1'b1, "T2-450mV-amp-ok");
        chk(dut.cor_sat   === 1'b0, "T2-450mV-no-corr-sat");
        chk(dut.lock_state === 2'd1, "T2-450mV-TRACK");
        chk(dut.amp_sq > 32'd850000000 && dut.amp_sq < 32'd1020000000,
            "T2-450mV-amp_sq-0.88FS");

        //-----------------------------------------------------------------
        $display("\n[TEST T3] 350 mVpp (2982 codes pp), default gain 1.0");
        amp_sel = 2'd1;
        wait_clk(6 * CLK_CYC);

        chk(dut.amp_ok    === 1'b1, "T3-350mV-amp-ok");
        chk(dut.amp_low   === 1'b0, "T3-350mV-amp-not-low");
        chk(dut.lock_state === 2'd1, "T3-350mV-TRACK");
        chk(dut.amp_sq > 32'd490000000 && dut.amp_sq < 32'd620000000,
            "T3-350mV-amp_sq-0.53FS");

        //-----------------------------------------------------------------
        $display("\n[TEST T4] one-key calibration at 400 mVpp (64 cycles window)");
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
        chk($unsigned(dut.res_gain_s) > 30000 && $unsigned(dut.res_gain_s) < 33000,
            "T4-res-GAIN_S-0.96");
        chk($unsigned(dut.res_gain_c) > 30000 && $unsigned(dut.res_gain_c) < 33000,
            "T4-res-GAIN_C-0.96");
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
        $display("\n[TEST T5] A/B: force gain 1.5 (v67 default) at 400 mVpp");
        cal_gain_s = dut.u_regs.r_gain_s;
        cal_gain_c = dut.u_regs.r_gain_c;
        $display("  [dbg] T5 before force: gain_reg=%0d amp_sq=%0d amp_high=%b",
                 dut.u_regs.r_gain_s, dut.amp_sq, dut.amp_high);
        force dut.u_regs.r_gain_s = 16'd49152;
        force dut.u_regs.r_gain_c = 16'd49152;

        // amp_high 是逐拍组合比较：削顶后 s²+c² 随相位在 1.0~2.0 FS² 摆动，
        // 单点采样可能恰好落在阈值以下。这里扫一个完整电周期，只要出现过
        // 一次 amp_high 就算触发（等价于示波器/上位机看到的高幅告警）。
        saw_high = 1'b0;
        for (k = 0; k < 20 * CLK_CYC; k = k + 1) begin
            @(posedge sys_clk);
            if (dut.amp_high) saw_high = 1'b1;
        end

        $display("  [dbg] T5 forced: gain_reg=%0d amp_sq=%0d amp_high=%b cor_sat=%b",
                 dut.u_regs.r_gain_s, dut.amp_sq, dut.amp_high, dut.cor_sat);
        chk(saw_high === 1'b1,           "T5-gain1.5-amp-high");
        chk(dut.cor_sat  === 1'b1,       "T5-gain1.5-corr-sat");
        chk(dut.lock_state !== 2'd1,     "T5-gain1.5-not-TRACK");

        release dut.u_regs.r_gain_s;
        release dut.u_regs.r_gain_c;
        // xsim 的 release 对“只由时序 always 偶尔赋值”的 reg 不会自动回填旧值，
        // 会停在被 force 的 49152；这里显式写回 T4 的标定增益，等价于上位机
        // 重新下发系数。RTL 行为不受影响，T5 验的是“增益恢复后环路能重新锁定”。
        force dut.u_regs.r_gain_s = cal_gain_s;
        force dut.u_regs.r_gain_c = cal_gain_c;
        wait_clk(30 * CLK_CYC);           // > 1 ms 恢复窗口（12500 抽样）

        $display("  [dbg] T5 released: gain_reg=%0d amp_sq=%0d amp_high=%b lock=%0d",
                 dut.u_regs.r_gain_s, dut.amp_sq, dut.amp_high, dut.lock_state);
        chk(dut.amp_high === 1'b0,       "T5-release-amp-not-high");
        chk(dut.amp_ok   === 1'b1,       "T5-release-amp-ok");
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
