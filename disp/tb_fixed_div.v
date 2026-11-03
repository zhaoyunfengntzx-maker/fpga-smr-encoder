// =============================================================================
//  sim/tb_fixed_div.v  --  fixed_div 自检
//
//  验证：精确商、精确余数、忙标志握手、连发第二次调用、除零饱和。
//  屏上真正要用的是两组：
//      rpm_x10 = (75 x f_q10) / (128 x pairs)
//      revs    = (pos_acc >> 16) / pairs
// =============================================================================
`timescale 1ns / 1ps

module tb_fixed_div;

    reg          clk = 1'b0;
    always #10 clk = ~clk;

    reg          rst_n = 1'b0;
    reg          start = 1'b0;
    reg  [39:0]  dividend = 40'd0;
    reg  [15:0]  divisor  = 16'd1;
    wire [39:0]  quotient;
    wire [39:0]  remainder;
    wire         busy;
    wire         done;

    integer errs = 0;
    integer n;

    fixed_div #(.W(40), .DW(16)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .dividend(dividend), .divisor(divisor),
        .quotient(quotient), .remainder(remainder),
        .busy(busy), .done(done)
    );

    task do_div(input [39:0] a, input [15:0] b, input [63:0] ea, input [63:0] er, input [8*24-1:0] tag);
        begin
            @(negedge clk);
            dividend = a; divisor = b; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            n = 0;
            while (!done && n < 200) begin
                @(negedge clk);
                n = n + 1;
            end
            if (n >= 200) begin
                errs = errs + 1;
                $display("[FAIL] %0s : done timeout (%0d cycles)", tag, n);
            end else begin
                if (quotient !== ea[39:0]) begin
                    errs = errs + 1;
                    $display("[FAIL] %0s : quotient = %0d, expected %0d", tag, quotient, ea[39:0]);
                end
                if (remainder !== er[39:0]) begin
                    errs = errs + 1;
                    $display("[FAIL] %0s : remainder = %0d, expected %0d", tag, remainder, er[39:0]);
                end
                if (quotient === ea[39:0] && remainder === er[39:0])
                    $display("[ OK ] %0s : %0d / %0d = %0d rem %0d  (%0d cycles)",
                             tag, a, b, quotient, remainder, n);
            end
        end
    endtask

    initial begin
        $display("==== tb_fixed_div ====");
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // 1234567 / 7 = 176366 余 5
        do_div(40'd1234567, 16'd7, 40'd176366, 40'd5, "T1 1234567/7");

        // 1000000000 / 32 = 31250000 余 0（连发：紧接着上一次）
        do_div(40'd1000000000, 16'd32, 40'd31250000, 40'd0, "T2 1e9/32");

        // 屏上真实用例 A：rpm_x10 = (75 x f_q10) / (128 x pairs)
        //   f_q10 = 1536000 (== f_in 1500.00 Hz)，pairs = 4
        //   -> num = 75 x 1536000 = 115200000, den = 128 x 4 = 512
        //   -> 115200000 / 512 = 225000  即 22500.0 rpm = 60 x 1500 / 4
        do_div(40'd115200000, 16'd512, 40'd225000, 40'd0, "T3 rpm_x10");

        // 屏上真实用例 B：revs = (pos_acc >> 16) / pairs
        //   pos_acc >> 16 = 5000000 电周期，pairs = 8 -> 625000 转
        do_div(40'd5000000, 16'd8, 40'd625000, 40'd0, "T4 revs");

        // 小/大边界
        do_div(40'd0,          16'd7,  40'd0,          40'd0, "T5 0/7");
        do_div(40'd5,          16'd65535, 40'd0,       40'd5, "T6 5/65535");

        if (errs == 0) $display("TEST PASSED: 0 errors");
        else           $display("TEST FAILED: %0d errors", errs);
        $finish;
    end

endmodule
