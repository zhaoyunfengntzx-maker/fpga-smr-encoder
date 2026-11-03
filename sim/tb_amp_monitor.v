//=============================================================================
// 测试台 : tb_amp_monitor
// 文件   : sim/tb_amp_monitor.v
// 被测   : rtl/amp_monitor.v
//
// 【测试内容】
//   1) 零输入：amp_sq=0 -> amp_low=1。
//   2) 正常幅值 + 门限判断（ok / low / high 三态互斥）。
//   3) **关键边界：s=c=-32768 时 s^2+c^2 = 2^31 = 2147483648**，
//      必须正好输出 2147483648（若内部用 32 位 signed 相加会溢出成 -2^31，
//      这里就是用来抓这个 bug 的）。
//   4) 门限正好相等时的严格性：amp_sq == low_sq 时 amp_low 必须为 0；
//      amp_sq == high_sq 时 amp_high 必须为 0。
//   5) 门限写反（low_sq > high_sq）时 amp_ok 恒 0。
//   6) Latency = 2、out_valid 对齐、复位行为。
//   7) 与 TW28 的 60%/120% 门限对应关系（注释中给出换算）。
//
// 门限取值（对应 TW28 的 60% / 120%，参考幅值 A_ref = 30000）：
//     low_sq  = (0.60*30000)^2 = 18000^2 =   324000000
//     high_sq = (1.20*30000)^2 = 36000^2 =  1296000000
//=============================================================================
`timescale 1ns / 1ps

module tb_amp_monitor;

    localparam integer DW = 16;

    localparam [31:0] LOW_SQ  = 32'd324000000;      // (60% * 30000)^2
    localparam [31:0] HIGH_SQ = 32'd1296000000;     // (120% * 30000)^2

    reg                  clk;
    reg                  rst_n;
    reg  signed [DW-1:0] s_n;
    reg  signed [DW-1:0] c_n;
    reg                  in_valid;
    reg         [31:0]   amp_low_sq;
    reg         [31:0]   amp_high_sq;
    wire        [31:0]   amp_sq;
    wire                 amp_ok;
    wire                 amp_low;
    wire                 amp_high;
    wire                 out_valid;

    integer errors;

    amp_monitor #(
        .DW (DW)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_n         (s_n),
        .c_n         (c_n),
        .in_valid    (in_valid),
        .amp_low_sq  (amp_low_sq),
        .amp_high_sq (amp_high_sq),
        .amp_sq      (amp_sq),
        .amp_ok      (amp_ok),
        .amp_low     (amp_low),
        .amp_high    (amp_high),
        .out_valid   (out_valid)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;           // 100 MHz
    end

    //-------------------------------------------------------------------------
    // 送一对 s/c，等 2 拍（Latency=2）后检查全部输出
    //-------------------------------------------------------------------------
    task check_amp;
        input signed [DW-1:0] s;
        input signed [DW-1:0] c;
        input [31:0]          lo;
        input [31:0]          hi;
        input [31:0]          e_sq;
        input                 e_ok;
        input                 e_low;
        input                 e_high;
        input [8*48-1:0]      tag;
        begin
            @(negedge clk);
            s_n         = s;
            c_n         = c;
            amp_low_sq  = lo;
            amp_high_sq = hi;
            in_valid    = 1'b1;

            repeat (2) @(posedge clk);       // Latency = 2
            @(negedge clk);

            if (amp_sq !== e_sq || amp_ok !== e_ok || amp_low !== e_low ||
                amp_high !== e_high || out_valid !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s: s=%0d c=%0d -> amp_sq=%0d ok=%b low=%b high=%b valid=%b",
                         tag, $signed(s), $signed(c), amp_sq, amp_ok, amp_low, amp_high,
                         out_valid);
                $display("         期望: amp_sq=%0d ok=%b low=%b high=%b valid=1",
                         e_sq, e_ok, e_low, e_high);
            end else begin
                $display("  [ok  ] %0s: s=%6d c=%6d -> amp_sq=%10d ok=%b low=%b high=%b",
                         tag, $signed(s), $signed(c), amp_sq, amp_ok, amp_low, amp_high);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        errors      = 0;
        rst_n       = 1'b0;
        s_n         = 16'sd0;
        c_n         = 16'sd0;
        in_valid    = 1'b0;
        amp_low_sq  = LOW_SQ;
        amp_high_sq = HIGH_SQ;

        $display("================================================================");
        $display(" tb_amp_monitor : 幅值监视（平方和比较，无开方）自检测试");
        $display(" 门限: low_sq=%0d (18000^2)  high_sq=%0d (36000^2)", LOW_SQ, HIGH_SQ);
        $display("================================================================");

        // ---- 1) 复位 ----
        repeat (4) @(posedge clk);
        @(negedge clk);
        if (amp_sq !== 32'd0 || amp_ok !== 1'b0 || amp_low !== 1'b0 ||
            amp_high !== 1'b0 || out_valid !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] 复位值: amp_sq=%0d ok=%b low=%b high=%b valid=%b",
                     amp_sq, amp_ok, amp_low, amp_high, out_valid);
        end else begin
            $display(" 【1】复位: 全部输出为 0  [ok]");
        end
        rst_n = 1'b1;

        // ---- 2) 基本幅值/门限 ----
        $display("");
        $display(" 【2】幅值与门限判断（s^2+c^2 与门限比较）");
        check_amp(16'sd0,     16'sd0,     LOW_SQ, HIGH_SQ,
                  32'd0, 1'b0, 1'b1, 1'b0, "零输入 -> 弱信号");
        check_amp(16'sd30000, 16'sd0,     LOW_SQ, HIGH_SQ,
                  32'd900000000, 1'b1, 1'b0, 1'b0, "A=30000 正常");
        check_amp(16'sd0,     16'sd30000, LOW_SQ, HIGH_SQ,
                  32'd900000000, 1'b1, 1'b0, 1'b0, "余弦通道 30000 正常");
        check_amp(16'sd32767, 16'sd0,     LOW_SQ, HIGH_SQ,
                  32'd1073676289, 1'b1, 1'b0, 1'b0, "s=+32767 最大正");
        check_amp(-16'sd32768, 16'sd0,    LOW_SQ, HIGH_SQ,
                  32'd1073741824, 1'b1, 1'b0, 1'b0, "s=-32768 最大负");

        // ---- 3) 关键边界：s=c=-32768 -> 2^31，绝不能回绕 ----
        $display("");
        $display(" 【3】关键边界：s=c=-32768 -> s^2+c^2 = 2^31 = 2147483648");
        check_amp(-16'sd32768, -16'sd32768, LOW_SQ, HIGH_SQ,
                  32'd2147483648, 1'b0, 1'b0, 1'b1, "2^31 不回绕 -> high");

        // ---- 4) 门限严格性 ----
        $display("");
        $display(" 【4】门限正好相等（low/high 都用严格不等号）");
        check_amp(16'sd18000, 16'sd0, LOW_SQ, HIGH_SQ,
                  32'd324000000, 1'b1, 1'b0, 1'b0, "amp_sq == low_sq -> 不算 low");
        check_amp(16'sd27000, 16'sd27000, LOW_SQ, 32'd1458000000,
                  32'd1458000000, 1'b1, 1'b0, 1'b0, "amp_sq == high_sq -> 不算 high");
        check_amp(16'sd27001, 16'sd27000, LOW_SQ, 32'd1458000000,
                  32'd1458054001, 1'b0, 1'b0, 1'b1, "超过 high_sq 1 LSB -> high");
        check_amp(16'sd17999, 16'sd0, LOW_SQ, HIGH_SQ,
                  32'd323964001, 1'b0, 1'b1, 1'b0, "低于 low_sq 1 LSB -> low");
        check_amp(16'sd18001, 16'sd0, LOW_SQ, HIGH_SQ,
                  32'd324036001, 1'b1, 1'b0, 1'b0, "高于 low_sq 1 LSB -> ok");

        // ---- 5) 门限写反 ----
        $display("");
        $display(" 【5】门限写反（low_sq > high_sq）-> amp_ok 必须恒 0");
        // 此时 400000000 < low_sq(1296000000) 所以 low=1，但 ok 必须为 0（low 优先）
        check_amp(16'sd20000, 16'sd0, HIGH_SQ, LOW_SQ,
                  32'd400000000, 1'b0, 1'b1, 1'b0, "low>high -> ok=0, low 优先");

        $display("");
        $display("================================================================");
        if (errors == 0) $display(" TEST PASSED (0 errors)");
        else             $display(" TEST FAILED (%0d errors)", errors);
        $display("================================================================");
        $finish;
    end

endmodule
