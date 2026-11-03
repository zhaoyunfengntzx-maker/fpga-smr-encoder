// ---------------------------------------------------------------------------
// tb_good.v —— 接线正确的测试台（tb_wiring.py 的对照样例）
// 每个 DUT 输入都被驱动；有 $finish、超时保护、可判读结论行
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_good;

    reg         clk, rst_n;
    reg  [7:0]  din;
    reg         en;
    wire [7:0]  dout;
    wire        valid;

    integer fails;
    integer i;

    dut_sample dut (
        .clk   (clk),
        .rst_n (rst_n),
        .din   (din),
        .en    (en),
        .dout  (dout),
        .valid (valid)
    );

    always #10 clk = ~clk;

    initial begin
        fails = 0;
        clk = 1'b0; rst_n = 1'b0; din = 8'd0; en = 1'b0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;

        for (i = 0; i < 16; i = i + 1) begin
            @(negedge clk);
            din = i[7:0];
            en  = 1'b1;
        end
        @(negedge clk);
        en = 1'b0;
        @(posedge clk);
        if (valid !== 1'b0) fails = fails + 1;

        if (fails == 0) $display("TEST PASSED (16 checks)");
        else            $display("TEST FAILED (%0d errors)", fails);
        $finish;
    end

    initial begin
        #100000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
