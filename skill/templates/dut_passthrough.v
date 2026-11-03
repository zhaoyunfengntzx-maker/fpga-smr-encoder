// ===========================================================================
// dut_passthrough.v —— 模板自带的"最小 DUT"，只为让 tb_skeleton.v 能立刻跑通
//   换题目时删掉它，把 tb_skeleton.v 里的实例化改成你自己的 DUT。
//   它的存在有实际用途：模板第一次使用就应该是"能跑出 PASSED"的状态，
//   否则你分不清"测试台写错了"还是"DUT 还没准备好"。
// ===========================================================================
`timescale 1ns / 1ps

module dut_passthrough #(
    parameter integer W = 16          // 数据位宽
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [W-1:0]     din,
    input  wire             din_valid,
    output reg  [W-1:0]     dout,
    output reg              dout_valid
);

    // 打一拍：延迟 1 clk，供测试台做"延迟对齐"的示范
    always @(posedge clk) begin
        if (!rst_n) begin
            dout       <= {W{1'b0}};
            dout_valid <= 1'b0;
        end else begin
            dout       <= din;
            dout_valid <= din_valid;
        end
    end

endmodule
