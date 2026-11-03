`timescale 1ns / 1ps
module tb_uvw_rev2;
    localparam AW = 16;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    reg  [AW-1:0] angle = 16'd30000;
    reg           in_valid = 0;
    wire u, v, w, ov, warn; wire [5:0] ppe;
    uvw_gen dut (.clk(clk), .rst_n(rst_n), .angle(angle), .in_valid(in_valid),
        .pairs(5'd4), .uvwpol(1'b0), .uvwdir(1'b0), .uwven(1'b1),
        .uvwph(16'sd0), .uvw_hyst(5'd0),
        .u_out(u), .v_out(v), .w_out(w), .out_valid(ov),
        .uvw_freq_warn(warn), .pole_pairs_eff(ppe));
    integer i;
    initial begin
        repeat (10) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        for (i = 0; i < 2048; i = i + 1) begin
            @(negedge clk); in_valid = 1; angle = angle - 32;
            @(negedge clk); in_valid = 0;
            repeat (7) @(negedge clk);
            #1 if (i % 100 == 0)
                $display("i=%0d eang=%0d sec=%0d uvw=%b%b%b dir=%b offb=%0d bwd=%b hyp=%0d init=%b st=%0d",
                    i, dut.eang, dut.r_sec, u, v, w, dut.dir_nxt, dut.off_bwd, dut.bwd_le, dut.hyp_ss, dut.r_init, dut.r_settle);
        end
        $finish;
    end
endmodule
