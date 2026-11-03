src = r"""`timescale 1ns / 1ps
module tb_acc2;
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
        .z_window(cycle_cnt[10:0] == 11'd0), .clr_on_z(1'b0),
        .preset(16'sd0), .preset_en(1'b0), .glitch_guard(4'd2),
        .cycle_cnt(cycle_cnt), .pos_full(pos_full),
        .dir(dir), .wrap_pos(wrap_pos), .wrap_neg(wrap_neg), .out_valid(out_valid));
    integer i, np = 0, nn = 0; reg signed [31:0] aa = 0; reg signed [31:0] step_lsb = 133;
    always @(posedge clk) if (rst_n) begin
        if (dut.wrap_p_ev) np = np + 1;
        if (dut.wrap_n_ev) nn = nn + 1;
    end
    task fwd(input integer n);
        begin for (i = 0; i < n; i = i + 1) begin
            @(negedge clk); in_valid = 1; aa = aa + step_lsb; angle = aa[AW-1:0];
            @(negedge clk); in_valid = 0; repeat (2) @(negedge clk);
        end end
    endtask
    initial begin
        repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        fwd(3000);
        $display("FWD 3000 samples (133 LSB): cycle_cnt=%0d wraps=+%0d/-%0d expect~6 acc=%0d",
                 cycle_cnt, np, nn, dut.phase_acc);
        np = 0; nn = 0;
        fwd(3000);
        $display("FWD again: cycle_cnt=%0d wraps=+%0d/-%0d expect~12 acc=%0d",
                 cycle_cnt, np, nn, dut.phase_acc);
        $finish;
    end
endmodule
"""
open("tb_acc2.v", "w", encoding="utf-8", newline="\n").write(src)
