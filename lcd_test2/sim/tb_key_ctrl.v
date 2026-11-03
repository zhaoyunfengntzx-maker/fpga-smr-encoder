//==========================================================================
// tb_key_ctrl.v —— F4 按键消抖 / 短按切模式 / 长按暂停 自检
//   参数按仿真缩放：DB_CYCLES=100、LONG_CYCLES=1000
//==========================================================================
`timescale 1ns / 1ps

module tb_key_ctrl;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  key_n = 1'b1;

    wire mode, paused, press, long_press, key_state;
    integer errors = 0;

    always #10 clk = ~clk;      // 50MHz

    key_ctrl #(
        .DB_CYCLES   (20'd100),
        .LONG_CYCLES (27'd1000)
    ) u_key (
        .clk        (clk),
        .rst_n      (rst_n),
        .key_n      (key_n),
        .mode       (mode),
        .paused     (paused),
        .press      (press),
        .long_press (long_press),
        .key_state  (key_state)
    );

    task check;
        input [8*32:1] name;
        input          got;
        input          exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %0s: got %b expected %b", name, got, exp);
            end else begin
                $display("[ OK ] %0s: %b", name, got);
            end
        end
    endtask

    integer press_cnt, long_cnt;

    initial begin
        $display("== tb_key_ctrl: F4 按键 ==");
        press_cnt = 0;
        long_cnt  = 0;

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        check("复位后 mode=0", mode, 1'b0);
        check("复位后 paused=0", paused, 1'b0);

        // ---------------- 测试 1：短按（按住 400 拍 < 1000）换模式 ----------------
        key_n = 1'b0;
        repeat (400) @(posedge clk);
        key_n = 1'b1;
        repeat (400) @(posedge clk);
        check("短按后 mode=1", mode, 1'b1);
        check("短按后 paused 不变", paused, 1'b0);

        // ---------------- 测试 2：抖动（< DB_CYCLES）不应触发 ----------------
        key_n = 1'b0; repeat (30) @(posedge clk);
        key_n = 1'b1; repeat (30) @(posedge clk);
        key_n = 1'b0; repeat (30) @(posedge clk);
        key_n = 1'b1; repeat (400) @(posedge clk);
        check("抖动后 mode 不变", mode, 1'b1);

        // ---------------- 测试 3：长按（按住 1500 拍 > 1000）暂停 ----------------
        key_n = 1'b0;
        repeat (1500) @(posedge clk);
        key_n = 1'b1;
        repeat (400) @(posedge clk);
        check("长按后 paused=1", paused, 1'b1);
        check("长按后 mode 不变", mode, 1'b1);

        // ---------------- 测试 4：再短按一次切回 F1 ----------------
        key_n = 1'b0;
        repeat (400) @(posedge clk);
        key_n = 1'b1;
        repeat (400) @(posedge clk);
        check("再次短按后 mode=0", mode, 1'b0);

        // ---------------- 统计脉冲个数 ----------------
        // 短按共 2 次（测试 1、测试 4）；测试 2 是抖动不应产生脉冲；
        // 测试 3 是长按，只出 long_press，不出 press。
        repeat (200) @(posedge clk);
        $display("press pulses  = %0d (期望 2)", press_cnt);
        $display("long  pulses  = %0d (期望 1)", long_cnt);
        if (press_cnt !== 2) begin errors = errors + 1; $display("[FAIL] 短按脉冲个数"); end
        if (long_cnt  !== 1) begin errors = errors + 1; $display("[FAIL] 长按脉冲个数"); end

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    always @(posedge clk) begin
        if (press)      press_cnt = press_cnt + 1;
        if (long_press) long_cnt  = long_cnt + 1;
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
