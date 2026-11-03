`timescale 1ns / 1ps
// v70 验证：pole_counter 在 12.5 MHz 过采样、每样点 ~0.73° 时能否正确计圈
module tb_acc;
    localparam AW = 16, CW = 16;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;              // 50 MHz

    reg  [AW-1:0] angle = 0;
    reg           in_valid = 0;
    wire [CW-1:0] cycle_cnt;
    wire [CW+AW-1:0] pos_full;
    wire dir, wrap_pos, wrap_neg, out_valid;

    reg  signed [31:0] step_lsb = 133;  // 0.73° ≈ 133 LSB
    reg  [10:0] z_en = 0;

    pole_counter #(.AW(AW), .CW(CW)) dut (
        .clk(clk), .rst_n(rst_n), .angle(angle),
        .in_valid(in_valid), .z_window(cycle_cnt[10:0] == 11'd0),
        .clr_on_z(z_en == 11'd0 ? 1'b0 : 1'b0),
        .preset(16'sd0), .preset_en(1'b0),
        .glitch_guard(4'd2),
        .cycle_cnt(cycle_cnt), .pos_full(pos_full),
        .dir(dir), .wrap_pos(wrap_pos), .wrap_neg(wrap_neg),
        .out_valid(out_valid)
    );

    integer n_valid = 0, n_wrap_p = 0, n_wrap_n = 0, i;
    reg signed [31:0] ang_acc = 0;
    always @(posedge clk) if (wrap_pos) n_wrap_p = n_wrap_p + 1;
    always @(posedge clk) if (wrap_neg) n_wrap_n = n_wrap_n + 1;

    task run_samples(input integer cnt);
        begin
            for (i = 0; i < cnt; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                ang_acc = ang_acc + step_lsb;
                angle = ang_acc[AW-1:0];
                @(negedge clk);
                in_valid = 1'b0;
                repeat (2) @(negedge clk);   // 12.5 MHz 有效：每 4 拍一次
            end
        end
    endtask

    integer exp_p;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        // ---- 正转：3000 个样点，0.73°/样 ⇒ 期望 ~6.09 圈
        step_lsb = 133;
        run_samples(3000);
        exp_p = 3000 / 494;   // 360/0.7308 ≈ 493 样/圈
        $display("FWD: samples=3000 cycle_cnt=%0d wraps=+%0d/-%0d exp~%0d",
                 cycle_cnt, n_wrap_p, n_wrap_n, exp_p);
        if (cycle_cnt < exp_p - 1 || cycle_cnt > exp_p + 1)
            $display("FWD FAIL");

        // ---- 反转：3000 个样点
        n_wrap_p = 0; n_wrap_n = 0;
        step_lsb = -133;
        run_samples(3000);
        $display("REV: samples=3000 cycle_cnt=%0d wraps=+%0d/-%0d exp~-%0d",
                 cycle_cnt, n_wrap_p, n_wrap_n, exp_p);
        if (cycle_cnt > -exp_p + 1 || cycle_cnt < -exp_p - 1)
            $display("REV FAIL");

        // ---- 慢速小幅抖动（模拟噪声，不跨零）应不计数
        n_wrap_p = 0; n_wrap_n = 0;
        for (i = 0; i < 500; i = i + 1) begin
            @(negedge clk); in_valid = 1; angle = 1000 + (i % 2);
            @(negedge clk); in_valid = 0; repeat (2) @(negedge clk);
        end
        $display("JITTER: cycle_cnt=%0d wraps=+%0d/-%0d (should be 0)", cycle_cnt, n_wrap_p, n_wrap_n);

        $display("TB_ACC_DONE");
        $finish;
    end
endmodule
