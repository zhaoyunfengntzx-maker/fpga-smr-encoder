src = r"""`timescale 1ns / 1ps
module tb_uvw;
    localparam AW = 16;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;         // 50 MHz
    reg  [AW-1:0] angle = 0;
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
    // mech angle ramp: 32 LSB per electrical step, hold ~508 clk so that
    // eang rate = 65536*4/ (508*2048) ... just make it slow enough
    initial begin
        repeat (10) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        for (i = 0; i < 2048 * 2; i = i + 1) begin   // 2 mech revs
            @(negedge clk); in_valid = 1; angle = angle + 32;
            @(negedge clk); in_valid = 0;
            repeat (7) @(negedge clk);
        end
        $display("states: 000=%0d 001=%0d 010=%0d 011=%0d 100=%0d 101=%0d 110=%0d 111=%0d",
                 n_st[0],n_st[1],n_st[2],n_st[3],n_st[4],n_st[5],n_st[6],n_st[7]);
        $display("transitions=%0d  ppe=%0d  warn=%b  (2 revs, 4 pairs => expect 48 transitions)", ntr, ppe, warn);
        $finish;
    end
endmodule
"""
open("tb_uvw.v", "w", encoding="utf-8", newline="\n").write(src)
