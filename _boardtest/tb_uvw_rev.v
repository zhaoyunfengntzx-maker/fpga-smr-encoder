`timescale 1ns / 1ps
module tb_uvw_rev;
    localparam AW = 16;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;
    reg  [AW-1:0] angle = 16'd30000;
    reg           in_valid = 0;
    wire u, v, w, ov, warn;
    wire [5:0] ppe;
    uvw_gen dut (
        .clk(clk), .rst_n(rst_n), .angle(angle), .in_valid(in_valid),
        .pairs(5'd4), .uvwpol(1'b0), .uvwdir(1'b0), .uwven(1'b1),
        .uvwph(16'sd0), .uvw_hyst(5'd0),
        .u_out(u), .v_out(v), .w_out(w), .out_valid(ov),
        .uvw_freq_warn(warn), .pole_pairs_eff(ppe));
    integer n_st[0:7];
    integer i, k, ntr = 0; reg [2:0] prev = 3'bxxx;
    initial for (k = 0; k < 8; k = k + 1) n_st[k] = 0;
    always @(posedge clk) if (rst_n) begin
        if ({u,v,w} !== prev) begin ntr = ntr + 1; prev = {u,v,w}; end
        n_st[{u,v,w}] = n_st[{u,v,w}] + 1;
    end
    initial begin
        repeat (10) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        for (i = 0; i < 2048 * 2; i = i + 1) begin
            @(negedge clk); in_valid = 1; angle = angle - 32;
            @(negedge clk); in_valid = 0;
            repeat (7) @(negedge clk);
        end
        $display("REV states: 001=%0d 010=%0d 011=%0d 100=%0d 101=%0d 110=%0d",
                 n_st[1],n_st[2],n_st[3],n_st[4],n_st[5],n_st[6]);
        $display("REV transitions=%0d (2 revs, 4 pairs => 48)", ntr);
        $finish;
    end
endmodule
