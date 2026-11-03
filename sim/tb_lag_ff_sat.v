//=============================================================================
// tb_lag_ff_sat.v —— lag_ff 饱和边界自检（2026-11-02 审计新增）
//
// 背景：原实现先 `prod_q8 >>> 8` 截成 24 位、再判饱和，真值落在 (2^23, 2^24)
//       时截断后变负数，本该饱和到 +REV/4，实际饱和到 −REV/4（符号反转、
//       位置朝反方向跳四分之一圈）。本 TB 专门打这个窗口。
//
// 用例（AW=16/FRAC=8 ⇒ PW=24，REV=2^24，±REV/4 = ±4194304）：
//   C1 speed=+1000  tau=256  ⇒ corr=+1000        （小信号不变，回归旧行为）
//   C2 speed=-1000  tau=256  ⇒ corr=-1000
//   C3 speed=+2^22  tau=512  ⇒ prod=2^31 ⇒ 真值 +2^23 ⇒ 期望 clamped to +4194303
//                              （旧实现给 -4194304，本 TB 会 FAIL）
//   C4 speed=+8388607 tau=65535 ⇒ 巨额正 ⇒ 期望 +4194303
//   C5 speed=-8388608 tau=65535 ⇒ 巨额负 ⇒ 期望 -4194304
//   C6 en=0                  ⇒ corr=0
//
// 判定：每个用例在 3 拍延迟后采样 corr_out，全部命中才打印 TEST PASSED。
//=============================================================================
`timescale 1ns / 1ps

module tb_lag_ff_sat;

    localparam integer AW = 16;
    localparam integer FRAC = 8;
    localparam integer PW = AW + FRAC;

    localparam signed [PW-1:0] CORR_MAX =  (1 << (PW-2)) - 1;   // +4194303
    localparam signed [PW-1:0] CORR_MIN = -(1 << (PW-2));       // -4194304

    reg                     clk = 1'b0;
    reg                     rst_n = 1'b0;
    reg  signed [PW-1:0]    speed_pos = {PW{1'b0}};
    reg  [15:0]             tau_q8 = 16'd0;
    reg                     en = 1'b0;
    wire signed [PW-1:0]    corr_out;
    wire                    corr_valid;

    integer errors = 0;

    always #10 clk = ~clk;      // 50 MHz

    lag_ff #(.AW(AW), .FRAC(FRAC)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .speed_pos  (speed_pos),
        .tau_q8     (tau_q8),
        .en         (en),
        .corr_out   (corr_out),
        .corr_valid (corr_valid)
    );

    task chk_c(input signed [PW-1:0] spd,
               input [15:0]          tau,
               input                 ena,
               input signed [PW-1:0] exp_v,
               input [8*24-1:0]      name);
        integer k;
        begin
            @(negedge clk);
            speed_pos = spd;
            tau_q8    = tau;
            en        = ena;
            for (k = 0; k < 5; k = k + 1) @(negedge clk);   // 等 5 拍稳定（延迟 3 拍）
            if (corr_out !== exp_v) begin
                errors = errors + 1;
                $display("[FAIL] %0s speed=%0d tau=%0d en=%0d -> corr=%0d, want=%0d",
                         name, $signed(spd), tau, ena, $signed(corr_out), $signed(exp_v));
            end else begin
                $display("[ ok ] %0s speed=%0d tau=%0d en=%0d -> corr=%0d",
                         name, $signed(spd), tau, ena, $signed(corr_out));
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // C1/C2：小信号线性区（旧行为必须保持）
        chk_c(24'sd1000,  16'd256, 1'b1,  24'sd1000,  "C1 small +");
        chk_c(-24'sd1000, 16'd256, 1'b1, -24'sd1000,  "C2 small -");

        // C3：老 bug 的窗口 —— 真值 +2^23，必须饱和到 +REV/4
        chk_c(24'sd4194304, 16'd512, 1'b1, CORR_MAX, "C3 sat + (old bug)");

        // C4/C5：远超上限，正负两个方向都要饱和到正确符号
        chk_c(24'sd8388607,  16'd65535, 1'b1, CORR_MAX, "C4 huge +");
        chk_c(-24'sd8388608, 16'd65535, 1'b1, CORR_MIN, "C5 huge -");

        // C6：en=0 时输出恒 0
        chk_c(24'sd4194304, 16'd512, 1'b0, {PW{1'b0}}, "C6 disabled");

        if (errors == 0) begin
            $display("TEST PASSED (lag_ff saturation, 6 cases)");
        end else begin
            $display("TEST FAILED: %0d case(s) wrong", errors);
        end
        $finish;
    end

    // 看门狗
    initial begin
        #20000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
