//=============================================================================
//  blink_mmcm.v —— 二分定位用：只有 MMCM，没有 MIG
//
//  背景（2026-10-19）：纯 LED 位流能交替闪，说明板子/时钟/LED/配置都没问题；
//  但带上 MMCM + MIG 的 ddr3_top 两个灯全灭。用这个位流把 MMCM 单独摘出来：
//
//    · 本设计闪 ⇒ MMCM 200 MHz 正常，问题在 MIG 那一段
//    · 本设计不闪 ⇒ MMCM 配置有问题（VCO/分频/复位），与 MIG 无关
//
//  现象：
//    led[0] 1 Hz 闪（计数在 200 MHz 域，能闪就说明 MMCM 输出了）
//    led[1] 常亮 = MMCM locked；不亮 = 没锁上
//=============================================================================
`timescale 1ns / 1ps

module blink_mmcm (
    input  wire       sys_clk,   // V4, 50 MHz
    output wire [1:0] led
);

    wire clkfb, clk200_raw, clk200, locked;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (20.000),
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (20.000),
        .CLKOUT0_DIVIDE_F   (5.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKIN1   (sys_clk),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk200_raw),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_bufg (.I(clk200_raw), .O(clk200));

    // 200 MHz / 2^27 ≈ 0.67 s 翻转一次
    reg [26:0] cnt;
    always @(posedge clk200) cnt <= cnt + 27'd1;

    reg hb;
    always @(posedge clk200) begin
        if (cnt == 27'd0) hb <= ~hb;
    end

    assign led[0] = hb;
    assign led[1] = locked;

endmodule
