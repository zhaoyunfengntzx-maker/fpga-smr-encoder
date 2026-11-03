// ============================================================================
// tb_bias_track.v —— rtl/bias_track.v 自检测试台（S4 偏置慢跟踪，v9.1 分块积分版）
// ----------------------------------------------------------------------------
// 窗口缩到 LOG2N=8（N=256 样本 = 8 个电周期），数学与 LOG2N=15 完全同构。
// 分块语义：一个窗口内 bias 恒定，窗口末 bias += 窗口均值。
//   TEST 1  en=0：不累加，bias 恒 0
//   TEST 2  一个窗口未满（255 样本）：bias 仍为 0、valid=0
//   TEST 3  满一个窗口：bias_s=+300、bias_c=-200（均值=直流，正弦整周期相消）
//   TEST 4  第二个窗口：残差已为 0 ⇒ bias 不再变化（无正反馈累积）
//   TEST 5  restart：清零，重新一块又回到 300
//   TEST 6  直流超限 20000 ⇒ bias_big 置位、bias 钳在 +8191
//   TEST 7  纯正弦：bias ≈ 0（AC 不外泄）
// ============================================================================
`timescale 1ns / 1ps

module tb_bias_track;

    localparam integer LOG2N = 8;
    localparam integer N     = (1 << LOG2N);
    localparam integer PER   = 32;               // 正弦周期（样本）
    localparam real    AMP   = 800.0;

    integer fails;
    integer i;
    integer phase;

    reg                clk, rst_n, in_valid, en, restart;
    reg  signed [15:0] s_in, c_in;
    wire signed [15:0] bias_s, bias_c;
    wire               bias_valid, bias_big;

    bias_track #(
        .LOG2N (LOG2N)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .s_in      (s_in),
        .c_in      (c_in),
        .en        (en),
        .restart   (restart),
        .bias_s    (bias_s),
        .bias_c    (bias_c),
        .bias_valid(bias_valid),
        .bias_big  (bias_big)
    );

    always #10 clk = ~clk;

    // 正弦查表（PER=32 点）
    function integer sin_i;
        input integer p;
        begin
            case (p % PER)
            0:  sin_i =    0;  1:  sin_i =  156;  2:  sin_i =  307;  3:  sin_i =  444;
            4:  sin_i =  566;  5:  sin_i =  664;  6:  sin_i =  742;  7:  sin_i =  795;
            8:  sin_i =  800;  9:  sin_i =  795; 10:  sin_i =  742; 11:  sin_i =  664;
            12: sin_i =  566; 13:  sin_i =  444; 14:  sin_i =  307; 15:  sin_i =  156;
            16: sin_i =    0; 17:  sin_i = -156; 18:  sin_i = -307; 19:  sin_i = -444;
            20: sin_i = -566; 21:  sin_i = -664; 22:  sin_i = -742; 23:  sin_i = -795;
            24: sin_i = -800; 25:  sin_i = -795; 26:  sin_i = -742; 27:  sin_i = -664;
            28: sin_i = -566; 29:  sin_i = -444; 30:  sin_i = -307; 31:  sin_i = -156;
            default: sin_i = 0;
            endcase
        end
    endfunction

    task chk;
        input [255:0] name;
        input signed [15:0] got;
        input signed [15:0] exp;
        input integer tol;
        begin
            if ((got > exp + tol) || (got < exp - tol)) begin
                fails = fails + 1;
                $display("[FAIL] %0s : got=%0d exp=%0d tol=%0d", name, got, exp, tol);
            end
        end
    endtask

    task run_samples;              // 跑 n 个样本（带直流偏置 dcs/dcc）
        input integer n;
        input integer dcs;
        input integer dcc;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                // ★ 闭环建模：硬件里 s_cor = 原始 − (cfg_ofs + bias)，本台用
                //   "原始直流 − bias" 还原这条通路，否则偏差不会被减掉、会一直累积。
                s_in = sin_i(phase) + dcs - bias_s;
                c_in = sin_i(phase + PER/4) + dcc - bias_c;
                phase = phase + 1;
                @(posedge clk); #1;
            end
        end
    endtask

    initial begin
        fails = 0;
        clk = 1'b0; rst_n = 1'b0;
        in_valid = 1'b0; en = 1'b0; restart = 1'b0;
        s_in = 16'sd0; c_in = 16'sd0;
        phase = 0;

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk); #1;

        // TEST 1：en=0 时不动（且喂满一个窗口也不动）
        run_samples(N, 300, -200);
        if (bias_s !== 16'sd0 || bias_c !== 16'sd0 || bias_valid !== 1'b0) begin
            fails = fails + 1;
            $display("[FAIL] T1-en-off : bias_s=%0d bias_c=%0d valid=%0d",
                     bias_s, bias_c, bias_valid);
        end

        // TEST 2：en=1 但窗口未满（N-1 个样本）⇒ 仍为 0
        en = 1'b1;
        run_samples(N - 1, 300, -200);
        if (bias_s !== 16'sd0 || bias_valid !== 1'b0) begin
            fails = fails + 1;
            $display("[FAIL] T2-half-window : bias_s=%0d valid=%0d", bias_s, bias_valid);
        end

        // TEST 3：补满一个窗口 ⇒ bias = 窗口均值 = 直流
        run_samples(1, 300, -200);
        if (!bias_valid) begin
            fails = fails + 1;
            $display("[FAIL] T3-valid : bias_valid=0");
        end
        chk("T3-bias-s", bias_s, 16'sd300,  2);
        chk("T3-bias-c", bias_c, -16'sd200, 2);

        // TEST 4：再跑一个窗口，残差已为 0 ⇒ 不允许继续累积
        run_samples(N, 300, -200);
        chk("T4-no-accum-s", bias_s, 16'sd300,  2);
        chk("T4-no-accum-c", bias_c, -16'sd200, 2);

        // TEST 5：restart 清空，重新一块又回到 300
        @(negedge clk); restart = 1'b1; @(posedge clk); #1;
        @(negedge clk); restart = 1'b0;
        if (bias_valid !== 1'b0 || bias_s !== 16'sd0) begin
            fails = fails + 1;
            $display("[FAIL] T5-restart : valid=%0d bias_s=%0d", bias_valid, bias_s);
        end
        run_samples(N, 300, -200);
        chk("T5-restart-relearn", bias_s, 16'sd300, 2);

        // TEST 6：直流超限 ⇒ big + 钳位
        run_samples(N, 20000, 20000);
        if (!bias_big) begin
            fails = fails + 1;
            $display("[FAIL] T6-big-flag : bias_big=0");
        end
        chk("T6-clamp", bias_s, 16'sd8191, 0);

        // TEST 7：重启后纯正弦，稳态 bias≈0
        @(negedge clk); restart = 1'b1; @(posedge clk); #1;
        @(negedge clk); restart = 1'b0;
        phase = 0;
        run_samples(4 * N, 0, 0);
        chk("T7-ac-leak-s", bias_s, 16'sd0, 2);
        chk("T7-ac-leak-c", bias_c, 16'sd0, 2);
        if (bias_big) begin
            fails = fails + 1;
            $display("[FAIL] T7-big-cleared : restart 后 bias_big 应清零");
        end

        repeat (4) @(posedge clk);
        if (fails == 0) $display("TEST PASSED (%0d checks)", 12);
        else            $display("TEST FAILED (%0d errors)", fails);
        $finish;
    end

    initial begin
        #2000000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
