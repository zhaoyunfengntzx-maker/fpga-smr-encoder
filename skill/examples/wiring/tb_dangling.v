// ---------------------------------------------------------------------------
// tb_dangling.v —— 反面样例：仿真"能跑完并打印 PASSED"，但激励根本没接上
//   * din 声明了却从未赋值        → W1（--strict 下为 E）
//   * en 连成常量 1'b1            → E2
//   * rst_n 端口缺连接             → E1
// 这正是 docs/ai-collaboration-log.md 记录 1 的那种测试台。
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_dangling;

    reg         clk;
    reg  [7:0]  din;
    wire [7:0]  dout;
    wire        valid;

    dut_sample dut (
        .clk   (clk),
        .din   (din),
        .en    (1'b1),
        .dout  (dout),
        .valid (valid)
    );

    always #10 clk = ~clk;

    initial begin
        clk = 1'b0;
        #1000;
        $display("TEST PASSED");
        $finish;
    end

endmodule
