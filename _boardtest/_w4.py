src = r"""`timescale 1ns / 1ps
module tb_dbg4;
    localparam AW = 16, CW = 16;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    reg  [AW-1:0] angle = 0;
    reg           in_valid = 0;
    wire [CW-1:0] cycle_cnt;
    wire [CW+AW-1:0] pos_full;
    wire dir, wrap_pos, wrap_neg, out_valid;
    pole_counter #(.AW(AW), .CW(CW)) dut (
        .clk(clk), .rst_n(rst_n), .angle(angle), .in_valid(in_valid),
        .z_window(1'b0), .clr_on_z(1'b0), .preset(16'sd0), .preset_en(1'b0),
        .glitch_guard(4'd0), .cycle_cnt(cycle_cnt), .pos_full(pos_full),
        .dir(dir), .wrap_pos(wrap_pos), .wrap_neg(wrap_neg), .out_valid(out_valid));
    integer i, npv = 0, nv = 0; reg signed [31:0] aa = 0;
    always @(posedge clk) begin
        if (dut.pair_valid) npv = npv + 1;
        if (dut.vld_d1) nv = nv + 1;
    end
    initial begin
        repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        for (i = 0; i < 600; i = i + 1) begin
            @(negedge clk); in_valid = 1; aa = aa + 133; angle = aa[AW-1:0];
            @(negedge clk); in_valid = 0; repeat (2) @(negedge clk);
            #1 if (i % 50 == 0)
                $display("i=%0d ang=%0d acc=%0d s0=%0d s1=%0d step=%0d pv=%b npv=%0d nv=%0d",
                         i, angle, dut.phase_acc, dut.ang_s0, dut.ang_s1, dut.step_s,
                         dut.pair_valid, npv, nv);
        end
        $display("END cnt=%0d npv=%0d nv=%0d", cycle_cnt, npv, nv);
        $finish;
    end
endmodule
"""
open("tb_dbg4.v", "w", encoding="utf-8", newline="\n").write(src)
