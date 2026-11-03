// ---------------------------------------------------------------------------
// dut_sample.v —— 示例 DUT（供 tb_wiring.py 示例使用，不是本工程的 RTL）
// 8 bit 数据打一拍，en 有效时输出 valid
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module dut_sample (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  din,
    input  wire        en,
    output reg  [7:0]  dout,
    output reg         valid
);

    always @(posedge clk) begin
        if (!rst_n) begin
            dout  <= 8'd0;
            valid <= 1'b0;
        end else if (en) begin
            dout  <= din;
            valid <= 1'b1;
        end else begin
            valid <= 1'b0;
        end
    end

endmodule
