// ============================================================================
// tb_lag_ff.v —— rtl/lag_ff.v 自检测试台（Vivado xsim）
// ----------------------------------------------------------------------------
// 覆盖内容（S2 延迟前馈的核心算术）：
//   TEST 1  en=0：无论速度多大，corr_out 恒 0（关闭语义）
//   TEST 2  正速度：corr = (speed × tau_q8) >>> 8，逐位核对
//   TEST 3  负速度：corr 为负且幅值相等（前馈符号必须跟方向走）
//   TEST 4  tau=0：corr 恒 0（"零延迟"边界）
//   TEST 5  饱和：异常大速度时钳到 ±REV/4（不能把位置推飞）
//   TEST 6  延迟：输入变化后正好 2 个 clk 出现新值（文档承诺 latency=2）
//   TEST 7  线性：tau 翻倍 ⇒ corr 翻倍（Q8 定点没有截断误差累积）
//
// 运行：run_sim.ps1 -Only tb_lag_ff   （或 xsim -tclbatch）
// 结束打印 TEST PASSED / TEST FAILED。
// ============================================================================
`timescale 1ns / 1ps

module tb_lag_ff;

    localparam integer AW   = 16;
    localparam integer FRAC = 8;
    localparam integer PW   = AW + FRAC;

    localparam signed [PW-1:0] CORR_MAX =  (1 << (PW-2)) - 1;   // +REV/4-1
    localparam signed [PW-1:0] CORR_MIN = -(1 << (PW-2));       // -REV/4

    integer fails;
    integer n;

    reg                  clk;
    reg                  rst_n;
    reg  signed [PW-1:0] speed_pos;
    reg  [15:0]          tau_q8;
    reg                  en;
    wire signed [PW-1:0] corr_out;
    wire                 corr_valid;

    lag_ff #(
        .AW   (AW),
        .FRAC (FRAC)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .speed_pos  (speed_pos),
        .tau_q8     (tau_q8),
        .en         (en),
        .corr_out   (corr_out),
        .corr_valid (corr_valid)
    );

    always #10 clk = ~clk;       // 50 MHz

    // 期望值（与 RTL 同一定点式）
    function signed [PW-1:0] expect_corr;
        input signed [PW-1:0] spd;
        input [15:0]          tq;
        input                 e;
        reg signed [PW+15:0]  p;
        begin
            if (!e) begin
                expect_corr = {PW{1'b0}};
            end else begin
                p = spd * $signed({1'b0, tq});
                p = p >>> 8;
                if (p > CORR_MAX)      expect_corr = CORR_MAX;
                else if (p < CORR_MIN) expect_corr = CORR_MIN;
                else                   expect_corr = p[PW-1:0];
            end
        end
    endfunction

    task chk;
        input [255:0] name;
        input signed [PW-1:0] got;
        input signed [PW-1:0] exp;
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s : got=%0d exp=%0d", name, got, exp);
            end
        end
    endtask

    task settle;                 // 等 3 拍让流水走完
        begin
            @(posedge clk); @(posedge clk); @(posedge clk);
            #1;
        end
    endtask

    initial begin
        fails = 0;
        clk = 1'b0;
        rst_n = 1'b0;
        speed_pos = {PW{1'b0}};
        tau_q8 = 16'd0;
        en = 1'b0;

        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        //------------------------------------------------------------------
        // TEST 1：en=0 ⇒ 恒 0（即使速度很大）
        //------------------------------------------------------------------
        speed_pos = 32'sd200000;
        tau_q8    = 16'd2304;
        en        = 1'b0;
        settle;
        chk("T1-en-off-zero", corr_out, {PW{1'b0}});

        //------------------------------------------------------------------
        // TEST 2：正速度 65536（= 1/256 圈/样本），tau = 9.0 样本
        //         corr = 65536*2304>>8 = 589824
        //------------------------------------------------------------------
        speed_pos = 32'sd65536;
        tau_q8    = 16'd2304;
        en        = 1'b1;
        settle;
        if (corr_out !== 32'sd589824) begin
            fails = fails + 1;
            $display("[FAIL] T2-pos : got=%0d exp=%0d", corr_out, 32'sd589824);
        end

        //------------------------------------------------------------------
        // TEST 3：负速度
        //------------------------------------------------------------------
        speed_pos = -32'sd65536;
        settle;
        if (corr_out !== -32'sd589824) begin
            fails = fails + 1;
            $display("[FAIL] T3-neg : got=%0d exp=%0d", corr_out, -32'sd589824);
        end

        //------------------------------------------------------------------
        // TEST 4：tau=0 ⇒ 0
        //------------------------------------------------------------------
        speed_pos = 32'sd65536;
        tau_q8    = 16'd0;
        settle;
        chk("T4-tau-zero", corr_out, {PW{1'b0}});

        //------------------------------------------------------------------
        // TEST 5：饱和（speed=2^22，tau=2304 → 远大于 REV/4）
        //------------------------------------------------------------------
        speed_pos = 32'sd4194304;      // 2^22
        tau_q8    = 16'd2304;
        settle;
        chk("T5-sat-pos", corr_out, CORR_MAX);
        speed_pos = -32'sd4194304;
        settle;
        chk("T5-sat-neg", corr_out, CORR_MIN);

        //------------------------------------------------------------------
        // TEST 6：延迟恰为 2 clk
        //   在 posedge 后 #1 改输入，下一拍(posedge)进入 prod，再下一拍出 corr_out
        //------------------------------------------------------------------
        speed_pos = 32'sd0;
        tau_q8    = 16'd256;           // 1.0 样本
        settle;
        @(posedge clk); #1;
        speed_pos = 32'sd65536;        // 期望 corr = 65536*256>>8 = 65536
        @(posedge clk); #1;            // 第 1 拍：prod 装入
        if (corr_out !== 32'sd0) begin
            fails = fails + 1;
            $display("[FAIL] T6-latency-early : corr 提前变化 %0d", corr_out);
        end
        @(posedge clk); #1;            // 第 2 拍：corr_out 更新
        if (corr_out !== 32'sd65536) begin
            fails = fails + 1;
            $display("[FAIL] T6-latency : got=%0d exp=%0d", corr_out, 32'sd65536);
        end

        //------------------------------------------------------------------
        // TEST 7：线性 —— tau 翻倍，corr 翻倍
        //------------------------------------------------------------------
        speed_pos = 32'sd4096;
        tau_q8    = 16'd2048;          // 8.0 样本
        settle;
        n = corr_out;                  // 4096*2048>>8 = 32768
        if (n !== 32768) begin
            fails = fails + 1;
            $display("[FAIL] T7-linear-1x : got=%0d exp=32768", n);
        end
        tau_q8 = 16'd4096;             // 16.0 样本
        settle;
        if (corr_out !== 65536) begin
            fails = fails + 1;
            $display("[FAIL] T7-linear-2x : got=%0d exp=65536", corr_out);
        end

        //------------------------------------------------------------------
        // 汇总
        //------------------------------------------------------------------
        repeat (4) @(posedge clk);
        if (fails == 0) $display("TEST PASSED (%0d checks)", 8);
        else            $display("TEST FAILED (%0d errors)", fails);
        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
