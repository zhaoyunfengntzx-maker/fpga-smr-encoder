`timescale 1ns / 1ps
module tb_dbg2;
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
    integer i, np = 0; reg signed [31:0] aa = 0;
    always @(posedge clk) if (dut.acc_pos) np = np + 1;
    initial begin
        $display("TWO_PI=%0d step_s=%0d", dut.TWO_PI, dut.step_s);
        repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        for (i = 0; i < 600; i = i + 1) begin
            @(negedge clk); in_valid = 1; aa = aa + 133; angle = aa[AW-1:0];
            @(negedge clk); in_valid = 0; repeat (2) @(negedge clk);
            #1 if (i > 485) $display("i=%0d ang=%0d acc=%0d pv=%b ap=%b cnt=%0d np=%0d",
                        i, angle, dut.phase_acc, dut.pair_valid, dut.acc_pos, cycle_cnt, np);
        end
        $display("END cnt=%0d np=%0d", cycle_cnt, np);
        $finish;
    end
endmodule
