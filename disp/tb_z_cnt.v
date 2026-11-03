//=============================================================================
// disp/tb_z_cnt.v  —  P1 "Z计数" 的 5 ms 抑制窗（v85）单元测试
//
// 背景（上板证据）：v84 屏上 P1 的 "Z计数" 打到 99999 饱和，而 "累计转数" 只有
// 4001 REV；rtl 的绝对 Z 计数 0x054A 折算 7.62 Hz ↔ 457 rpm / 8.32 Hz ↔ 499 rpm，
// 严格 1 个/转 ⇒ **硬件每转只出 1 个 Z**，是屏上这个计数器把停位喘振数爆了
// （转子停在索引位附近，电角度在 0° 抖动，每跨一次零就出一个 Z ≈ 3 kHz）。
//
// 修法：disp/z_cnt_lab.v 里加 5 ms 可重触发抑制窗（50 MHz ⇒ 250,000 拍）。
//   只有距**上一个 Z 上升沿**超过 5 ms 的上升沿才计数。
//
// 本测试台喂三种波形（全部是真实时间量级，clk = 50 MHz / 20 ns）：
//   §1  20 个 Z，间隔 1 ms         ⇒ 只应计 1 个（喘振被整串压掉）
//   §2  再 3 个 Z，间隔 100 ms     ⇒ 每个都该计（累计 4）
//   §3  停位喘振：500 个 Z、间隔 1 ms，随后 3 个正常 100 ms ⇒ 累计 8
//      （喘振串里"第 1 个"无法与正常的 1 个/转区分，所以是 +1 而不是 0：
//        与 4001 转的真值相比差 1，而不是差 1200 万）
//
// 跑法（run_sim.ps1 只扫 sim\tb_*.v，本文件在 disp\ 下，要手工起 xsim）：
//   cd %TEMP%\fpga_sim_work\zcnt
//   xvlog  C:\Users\zhaoy\Desktop\FPGA\disp\z_cnt_lab.v C:\Users\zhaoy\Desktop\FPGA\disp\tb_z_cnt.v
//   xelab -debug typical tb_z_cnt -s tb_z_cnt
//   xsim tb_z_cnt -R
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_z_cnt;

    // 50 MHz
    reg clk = 1'b0;
    always #10 clk = ~clk;

    localparam integer C_1MS   = 50_000;      // 1 ms @ 50 MHz
    localparam integer C_100MS = 5_000_000;   // 100 ms @ 50 MHz

    reg         rst_n;
    reg         start;
    reg         z;
    reg         hold;

    wire        we;
    wire [11:0] waddr;
    wire [7:0]  wdata;
    wire        busy, done;

    z_cnt_lab u_cnt (
        .clk(clk), .rst_n(rst_n), .start(start),
        .z(z), .hold(hold),
        .we(we), .waddr(waddr), .wdata(wdata),
        .busy(busy), .done(done)
    );

    // 标签层影子 RAM（只为了回读，不参与逻辑）
    reg [7:0] lab [0:4095];
    always @(posedge clk) begin
        if (we) lab[waddr[11:0]] <= wdata;
    end

    integer errors = 0;

    // 当前 5 位十进制计数值
    function integer cnt;
        input dummy;
        begin
            cnt = u_cnt.d4 * 10000 + u_cnt.d3 * 1000 + u_cnt.d2 * 100 +
                  u_cnt.d1 * 10 + u_cnt.d0;
        end
    endfunction

    task chki;
        input [8*64-1:0] label;
        input integer    got;
        input integer    want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : got %0d want %0d", label, got, want);
            end else begin
                $display("[ OK ] %0s : %0d", label, got);
            end
        end
    endtask

    // 一个 Z 脉冲：高 20 拍（400 ns）+ 低 20 拍，上升沿只有一个
    task pulse_z;
        begin
            // ★ 必须在 negedge 上改电平：若和 posedge 同一时刻跳变，
            //   被测件的 z_q 会在同一拍采到新值，上升沿被吞掉（本 TB 首版
            //   就是因此 20 个脉冲记 0 个）。
            @(negedge clk); z = 1'b1;
            repeat (20) @(posedge clk);
            @(negedge clk); z = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    // z 保持低电平，空跑 n 拍
    task idle_n;
        input integer n;
        begin
            @(negedge clk); z = 1'b0;
            repeat (n) @(posedge clk);
        end
    endtask

    // 打一拍 start，让写状态机把 5 位十进制搬到标签层
    task lab_update;
        begin
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            repeat (40) @(posedge clk);
        end
    endtask

    integer k;

    initial begin
        rst_n = 1'b0; start = 1'b0; z = 1'b0; hold = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        //---------------------------------------------------------------
        $display("--- 0. 复位后计数为 0 ---");
        //---------------------------------------------------------------
        chki("复位计数", cnt(1'b0), 0);

        //---------------------------------------------------------------
        $display("--- 1. 20 个 Z，间隔 1 ms（停位喘振）⇒ 只计 1 个 ---");
        //---------------------------------------------------------------
        for (k = 0; k < 20; k = k + 1) begin
            pulse_z;
            idle_n(C_1MS);
        end
        chki("1 ms x 20 之后", cnt(1'b0), 1);

        //---------------------------------------------------------------
        $display("--- 2. 再 3 个 Z，间隔 100 ms ⇒ 每个都计（累计 4） ---");
        //---------------------------------------------------------------
        idle_n(C_100MS);
        pulse_z;
        idle_n(C_100MS);
        pulse_z;
        idle_n(C_100MS);
        pulse_z;
        idle_n(C_100MS);
        chki("100 ms x 3 之后", cnt(1'b0), 4);

        //---------------------------------------------------------------
        $display("--- 3. 停位喘振 500 次（1 ms）+ 随后 3 个正常（100 ms）⇒ 8 ---");
        //---------------------------------------------------------------
        //   ★ 喘振串的第一个上升沿仍然是"距上一个 Z 已经很久"的那个，
        //     抑制窗无法把它和正常的 1 个/转区分开，所以这一串记 +1。
        for (k = 0; k < 500; k = k + 1) begin
            pulse_z;
            idle_n(C_1MS);
        end
        chki("喘振 500 次之后", cnt(1'b0), 5);
        idle_n(C_100MS);
        pulse_z;
        idle_n(C_100MS);
        pulse_z;
        idle_n(C_100MS);
        pulse_z;
        idle_n(C_100MS);
        chki("之后 3 个正常脉冲", cnt(1'b0), 8);

        //---------------------------------------------------------------
        $display("--- 4. 标签层：5 格十进制（高位前导零写空格） ---");
        //---------------------------------------------------------------
        //   计数 = 8 ⇒ 格行 36、格列 12..16 = "    8"（个位永远显示）
        lab_update;
        for (k = 0; k < 5; k = k + 1) begin
            $display("        lab(36,%0d) = %0d", 12 + k, lab[{6'd36, 6'd0} + 12 + k]);
        end
        if (lab[{6'd36, 6'd0} + 12] !== 8'd0)  begin errors = errors + 1; $display("[FAIL] 万位应是空格"); end
        if (lab[{6'd36, 6'd0} + 16] !== 8'd16) begin errors = errors + 1; $display("[FAIL] 个位应是 '8' (码 16)"); end

        //---------------------------------------------------------------
        $display("--- 5. 计数 ---");
        //---------------------------------------------------------------
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
