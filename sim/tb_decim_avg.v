//=============================================================================
// 测试台 : tb_decim_avg
// 文件   : sim/tb_decim_avg.v
// 被测   : rtl/decim_avg.v
//
// 【测试内容】
//   1) 平均值正确性：4 个样本一组，输出 = 组和 >>> LOG2DEC（算术右移）。
//   2) Latency = 2：本组最后一个 din_valid 之后第 2 拍 dout_valid 拉高，且只高 1 拍。
//   3) 负数/floor 语义：(-1,-2,0,1) 组和 = -2，(-2)>>>2 = -1（向 -inf 取整，不是 0）。
//   4) din_valid 可以不连续（有空洞时仍然按 4 个有效样本成组）。
//   5) 满量程边界：+4095 和 -4096 常量输入不被改写（DW=13 的极值）。
//   6) 复位行为。
//   7) 第二实例 LOG2DEC=0（NDEC=1，CW=1 的边界）：直通且 Latency 仍为 2。
//
// 【饱和说明】累加器位宽 = DW+LOG2DEC 在数学上必然装得下 2^LOG2DEC 个 DW 位有符号
//   数之和，所以**正常数据路径下饱和分支不可达**（RTL 里是防御性保护）。
//   本测试台因此验证的是"极值不被改写、不回绕"，而不是去触发饱和。
//=============================================================================
`timescale 1ns / 1ps

module tb_decim_avg;

    localparam integer DW  = 13;
    localparam integer L2  = 2;          // 抽取率 4

    // ---- DUT A：默认参数 ----
    reg                  clk;
    reg                  rst_n;
    reg  signed [DW-1:0] din;
    reg                  din_valid;
    wire signed [DW-1:0] dout;
    wire                 dout_valid;

    // ---- DUT B：LOG2DEC=0（直通边界）----
    reg  signed [DW-1:0] din_b;
    reg                  din_valid_b;
    wire signed [DW-1:0] dout_b;
    wire                 dout_valid_b;

    integer errors;

    decim_avg #(
        .DW      (DW),
        .LOG2DEC (L2)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (din),
        .din_valid  (din_valid),
        .dout       (dout),
        .dout_valid (dout_valid)
    );

    decim_avg #(
        .DW      (DW),
        .LOG2DEC (0)
    ) dut_b (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (din_b),
        .din_valid  (din_valid_b),
        .dout       (dout_b),
        .dout_valid (dout_valid_b)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;           // 100 MHz
    end

    //-------------------------------------------------------------------------
    // 送一组 4 个样本（可以带空洞），然后在最后一个样本之后第 2 拍检查
    //   s0..s3        : 4 个样本
    //   gap           : 相邻样本之间插入几个 din_valid=0 的空拍（0 表示连续）
    //-------------------------------------------------------------------------
    task feed_group;
        input signed [DW-1:0] s0, s1, s2, s3;
        input integer         gap;
        input signed [DW-1:0] exp;
        begin
            @(negedge clk); din = s0; din_valid = 1'b1;
            repeat (gap) begin @(negedge clk); din_valid = 1'b0; end
            @(negedge clk); din = s1; din_valid = 1'b1;
            repeat (gap) begin @(negedge clk); din_valid = 1'b0; end
            @(negedge clk); din = s2; din_valid = 1'b1;
            repeat (gap) begin @(negedge clk); din_valid = 1'b0; end
            @(negedge clk); din = s3; din_valid = 1'b1;
            @(negedge clk); din_valid = 1'b0;      // 本组结束
            @(negedge clk);                        // 再等 1 拍（Latency=2）后检查

            if (dout_valid !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] 组 (%0d,%0d,%0d,%0d) gap=%0d: dout_valid=%b（必须第 2 拍拉高）",
                         $signed(s0), $signed(s1), $signed(s2), $signed(s3), gap, dout_valid);
            end else if (dout !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] 组 (%0d,%0d,%0d,%0d) gap=%0d: dout=%0d，期望 %0d",
                         $signed(s0), $signed(s1), $signed(s2), $signed(s3), gap,
                         $signed(dout), $signed(exp));
            end else begin
                $display("  [ok  ] 组 (%6d,%6d,%6d,%6d) gap=%0d -> dout=%6d",
                         $signed(s0), $signed(s1), $signed(s2), $signed(s3), gap, $signed(dout));
            end

            // dout_valid 只应高 1 拍：再等 1 拍必须已经落下
            @(negedge clk);
            if (dout_valid !== 1'b0) begin
                errors = errors + 1;
                $display("  [FAIL] dout_valid 多于 1 拍（本应只高 1 拍）");
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // LOG2DEC=0 直通检查
    //-------------------------------------------------------------------------
    task check_bypass;
        input signed [DW-1:0] d;
        begin
            @(negedge clk); din_b = d; din_valid_b = 1'b1;
            @(negedge clk); din_valid_b = 1'b0;
            @(negedge clk);
            if (dout_valid_b !== 1'b1 || dout_b !== d) begin
                errors = errors + 1;
                $display("  [FAIL] LOG2DEC=0 直通: din=%0d -> dout=%0d valid=%b，期望 %0d/1",
                         $signed(d), $signed(dout_b), dout_valid_b, $signed(d));
            end else begin
                $display("  [ok  ] LOG2DEC=0 直通: %6d -> %6d", $signed(d), $signed(dout_b));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        errors      = 0;
        clk         = 1'b0;
        rst_n       = 1'b0;
        din         = {DW{1'b0}};
        din_valid   = 1'b0;
        din_b       = {DW{1'b0}};
        din_valid_b = 1'b0;

        $display("================================================================");
        $display(" tb_decim_avg : 抽取滑动平均自检测试 (DW=%0d, LOG2DEC=%0d)", DW, L2);
        $display("================================================================");

        // ---- 复位 ----
        repeat (4) @(posedge clk);
        @(negedge clk);
        if (dout !== {DW{1'b0}} || dout_valid !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] 复位值: dout=%0d dout_valid=%b（应为 0/0）",
                     $signed(dout), dout_valid);
        end else begin
            $display(" 【1】复位: dout=0 dout_valid=0  [ok]");
        end
        rst_n = 1'b1;

        // ---- 平均值 ----
        $display("");
        $display(" 【2】平均值（组和 >>> %0d）+ Latency=2", L2);
        feed_group(13'sd100,  13'sd200,  13'sd300,  13'sd400,  0, 13'sd250);   // 1000>>2 = 250
        feed_group(13'sd4095, 13'sd4095, 13'sd4095, 13'sd4095, 0, 13'sd4095);  // 16380>>2
        feed_group(-13'sd4096,-13'sd4096,-13'sd4096,-13'sd4096,0,-13'sd4096);  // 满量程负
        feed_group(13'sd1,    13'sd2,    13'sd3,    13'sd4,    0, 13'sd2);    // 10>>2 = 2
        feed_group(-13'sd1,   -13'sd2,   13'sd0,    13'sd1,    0, -13'sd1);   // -2>>2 = -1 (floor!)
        feed_group(-13'sd1,   -13'sd1,   -13'sd1,   13'sd0,    0, -13'sd1);   // -3>>2 = -1
        feed_group(13'sd0,    13'sd0,    13'sd0,    13'sd0,    0, 13'sd0);

        // ---- 空洞 ----
        $display("");
        $display(" 【3】din_valid 不连续（样本间插入空洞）");
        feed_group(13'sd400,  13'sd800,  13'sd1200, 13'sd1600, 2, 13'sd1000);  // 4000>>2
        feed_group(13'sd0,    13'sd0,    13'sd0,    13'sd4,    3, 13'sd1);     // 4>>2 = 1

        // ---- LOG2DEC=0 直通 ----
        $display("");
        $display(" 【4】LOG2DEC=0（NDEC=1, 计数器位宽=1 的边界）");
        check_bypass(13'sd1000);
        check_bypass(-13'sd2048);
        check_bypass(13'sd4095);
        check_bypass(-13'sd4096);
        check_bypass(13'sd0);

        $display("");
        $display("================================================================");
        if (errors == 0) $display(" TEST PASSED (0 errors)");
        else             $display(" TEST FAILED (%0d errors)", errors);
        $display("================================================================");
        $finish;
    end

endmodule
