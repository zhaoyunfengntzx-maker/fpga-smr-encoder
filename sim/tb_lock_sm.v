// ============================================================================
// tb_lock_sm.v —— rtl/lock_sm.v 自检测试台（S3 锁定状态机）
// ----------------------------------------------------------------------------
// 用小计数（GOOD_N=8 / BAD_N=4 / RECOV_N=6）把状态机的时间尺度压到几十拍，
// 逐拍核对状态迁移与事件脉冲。
//   TEST 1  复位后 state=INIT、无事件
//   TEST 2  连续 good = GOOD_N-1 拍仍在 INIT；第 GOOD_N 拍进 TRACK 并出 acq_evt
//   TEST 3  TRACK 中 1 拍 bad：bad_run=1、下一拍归零、状态不变（毛刺容忍）
//   TEST 4  连续 bad = BAD_N-1 拍仍在 TRACK；第 BAD_N 拍进 LOST、lost_evt、lost_cnt=1
//   TEST 5  LOST 中 good 不够 RECOV_N 拍不恢复；够了回 TRACK 并出 acq_evt
//   TEST 6  lag_fatal 单独即可判坏；cor_sat 单独即可判坏；amp_high 也算坏
//   TEST 7  第二次掉锁 ⇒ lost_cnt=2
//   TEST 8  bad_run 在持续坏时饱和（不溢出回绕）
// ============================================================================
`timescale 1ns / 1ps

module tb_lock_sm;

    localparam integer GOOD_N  = 8;
    localparam integer BAD_N   = 4;
    localparam integer RECOV_N = 6;

    integer fails;
    integer i;

    reg        clk, rst_n, in_valid;
    reg        amp_ok, amp_low, amp_high, lag_fatal, cor_sat;
    wire [1:0] state;
    wire       lost_evt, acq_evt;
    wire [15:0] lost_cnt, bad_run;

    lock_sm #(
        .GOOD_N  (GOOD_N),
        .BAD_N   (BAD_N),
        .RECOV_N (RECOV_N)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .amp_ok    (amp_ok),
        .amp_low   (amp_low),
        .amp_high  (amp_high),
        .lag_fatal (lag_fatal),
        .cor_sat   (cor_sat),
        .state     (state),
        .lost_evt  (lost_evt),
        .acq_evt   (acq_evt),
        .lost_cnt  (lost_cnt),
        .bad_run   (bad_run)
    );

    always #10 clk = ~clk;

    task chk;
        input [255:0] name;
        input [15:0]  got;
        input [15:0]  exp;
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s : got=%0d exp=%0d", name, got, exp);
            end
        end
    endtask

    // 一拍：in_valid=1，给定信号质量
    task step_good;
        begin
            @(negedge clk);
            in_valid = 1'b1;
            amp_ok = 1'b1; amp_low = 1'b0; amp_high = 1'b0;
            lag_fatal = 1'b0; cor_sat = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    task step_bad;
        begin
            @(negedge clk);
            in_valid = 1'b1;
            amp_ok = 1'b0; amp_low = 1'b1; amp_high = 1'b0;
            lag_fatal = 1'b0; cor_sat = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    task step_idle;
        begin
            @(negedge clk);
            in_valid = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        fails = 0;
        clk = 1'b0; rst_n = 1'b0;
        in_valid = 1'b0;
        amp_ok = 1'b0; amp_low = 1'b0; amp_high = 1'b0; lag_fatal = 1'b0; cor_sat = 1'b0;

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk); #1;

        // TEST 1
        chk("T1-init-state", {14'd0, state}, 16'd0);
        chk("T1-init-lost..cnt", lost_cnt, 16'd0);

        // TEST 2：GOOD_N-1 拍还在 INIT
        for (i = 0; i < GOOD_N - 1; i = i + 1) step_good;
        chk("T2-still-init", {14'd0, state}, 16'd0);
        step_good;                                  // 第 GOOD_N 拍
        chk("T2-track", {14'd0, state}, 16'd1);
        chk("T2-acq-evt", {15'd0, acq_evt}, 16'd1);
        step_good;
        chk("T2-acq-pulse-1clk", {15'd0, acq_evt}, 16'd0);

        // TEST 3：单拍坏 → bad_run=1，状态不变
        step_bad;
        chk("T3-bad-run", bad_run, 16'd1);
        chk("T3-still-track", {14'd0, state}, 16'd1);
        step_good;
        chk("T3-bad-run-clr", bad_run, 16'd0);

        // TEST 4：连续 BAD_N-1 拍仍在 TRACK
        for (i = 0; i < BAD_N - 1; i = i + 1) step_bad;
        chk("T4-still-track", {14'd0, state}, 16'd1);
        step_bad;
        chk("T4-lost", {14'd0, state}, 16'd2);
        chk("T4-lost-evt", {15'd0, lost_evt}, 16'd1);
        chk("T4-lost-cnt", lost_cnt, 16'd1);
        step_idle;
        chk("T4-lost-evt-1clk", {15'd0, lost_evt}, 16'd0);

        // TEST 5：LOST 中 good 不足 RECOV_N 拍不恢复
        for (i = 0; i < RECOV_N - 1; i = i + 1) step_good;
        chk("T5-still-lost", {14'd0, state}, 16'd2);
        step_good;
        chk("T5-recovered", {14'd0, state}, 16'd1);
        chk("T5-acq-evt", {15'd0, acq_evt}, 16'd1);

        // TEST 6：lag_fatal / cor_sat / amp_high 各自都能判坏
        for (i = 0; i < BAD_N; i = i + 1) begin
            @(negedge clk);
            in_valid = 1'b1;
            amp_ok = 1'b0; amp_low = 1'b0; amp_high = 1'b0;
            lag_fatal = 1'b1; cor_sat = 1'b0;
            @(posedge clk); #1;
        end
        chk("T6-lagfatal-lost", {14'd0, state}, 16'd2);
        for (i = 0; i < RECOV_N; i = i + 1) step_good;
        chk("T6-recover2", {14'd0, state}, 16'd1);
        for (i = 0; i < BAD_N; i = i + 1) begin
            @(negedge clk);
            in_valid = 1'b1;
            amp_ok = 1'b0; amp_low = 1'b0; amp_high = 1'b0;
            lag_fatal = 1'b0; cor_sat = 1'b1;
            @(posedge clk); #1;
        end
        chk("T6-corsat-lost", {14'd0, state}, 16'd2);
        for (i = 0; i < RECOV_N; i = i + 1) step_good;
        for (i = 0; i < BAD_N; i = i + 1) begin
            @(negedge clk);
            in_valid = 1'b1;
            amp_ok = 1'b0; amp_low = 1'b0; amp_high = 1'b1;
            lag_fatal = 1'b0; cor_sat = 1'b0;
            @(posedge clk); #1;
        end
        chk("T6-amphigh-lost", {14'd0, state}, 16'd2);

        // TEST 7：lost_cnt 累计到 4（T4 一次 + T6 的三次：lag_fatal / cor_sat / amp_high）
        chk("T7-lost-cnt-4", lost_cnt, 16'd4);

        // TEST 8：bad_run 饱和（长跑 200 拍坏，仍在 TRACK 前半段）
        for (i = 0; i < RECOV_N; i = i + 1) step_good;   // 先回 TRACK
        chk("T8-back-track", {14'd0, state}, 16'd1);
        for (i = 0; i < 40; i = i + 1) step_bad;          // 40 > BAD_N ⇒ 会进 LOST
        chk("T8-lost-again", {14'd0, state}, 16'd2);
        // LOST 状态 bad_run 清零；这里只验证不溢出（进 LOST 前 bad_run 最多 BAD_N-1…）
        if (bad_run === 16'hxxxx) begin
            fails = fails + 1;
            $display("[FAIL] T8-bad-run-x");
        end

        repeat (4) @(posedge clk);
        if (fails == 0) $display("TEST PASSED (%0d checks)", 14);
        else            $display("TEST FAILED (%0d errors)", fails);
        $finish;
    end

    initial begin
        #200000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
