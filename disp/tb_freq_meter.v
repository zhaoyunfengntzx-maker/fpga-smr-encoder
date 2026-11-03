// =============================================================================
//  disp/tb_freq_meter.v  --  freq_meter 自检
//
//  放在 disp/ 而不是 sim/：sim/tb_*.v 会被 tools/run_sim.ps1 收走，而那份脚本
//  只编译 rtl/*.v，本测试台需要 disp/freq_meter.v —— 放错地方会把
//  「编码器回归 PASS 21/21」的基线全部变成 BUILD-ERR。
//  本目录的测试台由 tools/run_sim_disp.ps1 负责。
//
//  验证 4 件事（都是「错了必然显示错数字」的）：
//    T1 正向：闸门末 f_q10 == step x GATE_CLKS，dir = 01
//    T2 反向：同上取负，dir = 10
//    T3 静止：f_q10 == 0，dir = 00
//    T4 解回绕：step = 200,000 LSB/拍（> 16 bit angle 的整个量程 65536），
//       而 f_q10 仍然精确 = step x GATE_CLKS
//       —— 这一条正是「不能只用 16 bit angle 求导」的实验证据
//          （host/encoder.py:10-12 记的那个坑）。
//    另：pos_acc 必须恰好等于历次 f_q10 之和（累计位置不许多也不许少）。
//
//  ★ 仿真时间压缩技巧：把 CLK_HZ 缩小 1000 倍（50,000 而不是 50,000,000），
//    闸门就只有 781 拍而不是 781,250 拍。
//    f_q10 的定点含义 **只取决于 GATE_DIV**，与 CLK_HZ 无关：
//        f_q10 = f_in x 65536 / GATE_DIV
//    GATE_DIV=64 时 65536/64 = 1024，正是生产配置。被测逻辑一模一样。
//
//  注意：$display 的标签一律用 ASCII。中文标签在 GBK 控制台下会变成乱码，
//        而日志的可读性比"标签好看"重要。
// =============================================================================
`timescale 1ns / 1ps

module tb_freq_meter;

    localparam integer TB_CLK_HZ = 50_000;
    localparam integer TB_DIV    = 64;
    localparam integer GATE_CLKS = TB_CLK_HZ / TB_DIV;   // 781 拍/闸门

    reg clk = 1'b0;
    always #10 clk = ~clk;                                // 20 ns 周期

    reg                rst_n = 1'b0;
    reg  signed [21:0] pos   = 22'sd0;
    wire signed [31:0] f_q10;
    wire signed [47:0] pos_acc;
    wire signed [1:0]  dir;
    wire               valid;

    integer step;
    integer gate;
    integer errs  = 0;
    integer sum_f = 0;      // 历次闸门 f_q10 之和（应与 pos_acc 相等）

    freq_meter #(.CLK_HZ(TB_CLK_HZ), .GATE_DIV(TB_DIV)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .pos_full (pos),
        .f_q10    (f_q10),
        .pos_acc  (pos_acc),
        .dir      (dir),
        .valid    (valid)
    );

    // 逐拍按 step 推进 pos（被测的输入激励）
    always @(posedge clk) if (rst_n) pos <= pos + step;

    task wait_valid;
        begin
            @(posedge clk);
            while (!valid) @(posedge clk);
        end
    endtask

    task check(input signed [31:0] exp_f, input [1:0] exp_dir, input [8*16-1:0] tag);
        begin
            if (f_q10 !== exp_f) begin
                errs = errs + 1;
                $display("[FAIL] %0s : f_q10 = %0d, 期望 %0d", tag, f_q10, exp_f);
            end else begin
                $display("[ OK ] %0s : f_q10 = %0d  ->  f_in = %0.4f Hz", tag, f_q10, f_q10 / 1024.0);
            end
            if (dir !== exp_dir) begin
                errs = errs + 1;
                $display("[FAIL] %0s : dir = %b, 期望 %b", tag, dir, exp_dir);
            end
        end
    endtask

    initial begin
        $display("==== tb_freq_meter  CLK_HZ=%0d GATE_DIV=%0d GATE_CLKS=%0d ====",
                 TB_CLK_HZ, TB_DIV, GATE_CLKS);

        step  = 0;
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;

        // ---------------- T1 正向 step = +2 ----------------
        step = 2;
        for (gate = 0; gate < 5; gate = gate + 1) begin
            wait_valid;
            sum_f = sum_f + f_q10;
            if (gate >= 2) check(32'sd1562, 2'b01, "T1 fwd +2");
        end

        // ---------------- T2 反向 step = -3 ----------------
        step = -3;
        for (gate = 0; gate < 5; gate = gate + 1) begin
            wait_valid;
            sum_f = sum_f + f_q10;
            if (gate >= 2) check(-32'sd2343, 2'b10, "T2 rev -3");
        end

        // ---------------- T3 静止 step = 0 ----------------
        step = 0;
        for (gate = 0; gate < 3; gate = gate + 1) begin
            wait_valid;
            sum_f = sum_f + f_q10;
            if (gate >= 1) check(32'sd0, 2'b00, "T3 stop 0");
        end

        // ---------------- T4 解回绕 step = +200000 ----------------
        // 16 bit angle 的全量程只有 65536，一步跨 200000 LSB 意味着
        // 「按 angle 求导」这条路会完全混叠，而本模块仍然精确。
        step = 200000;
        for (gate = 0; gate < 5; gate = gate + 1) begin
            wait_valid;
            sum_f = sum_f + f_q10;
            if (gate >= 2) check(32'sd200000 * GATE_CLKS, 2'b01, "T4 unwrap +200000");
        end

        // ---------------- T5 累计位置守恒 ----------------
        if (pos_acc !== sum_f) begin
            errs = errs + 1;
            $display("[FAIL] T5 pos_acc = %0d, 应为 18 次 f_q10 之和 %0d", pos_acc, sum_f);
        end else begin
            $display("[ OK ] T5 pos_acc = %0d == sum(f_q10)  （18 个闸门，守恒）", pos_acc);
        end

        // ------------------------------------------------
        if (errs == 0) $display("TEST PASSED: 0 errors");
        else           $display("TEST FAILED: %0d errors", errs);
        $finish;
    end

endmodule
