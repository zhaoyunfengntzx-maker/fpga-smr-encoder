//=============================================================================
//  led_blink.v —— 最小心跳位流（不实例化 MIG，只验证"位流在跑 + LED 引脚对"）
//
//  用途：DDR3 自检版两个灯都不亮时，先烧这个。
//    · 这个能闪 ⇒ 板子、引脚、时钟都没问题，问题在 DDR3 顶层里
//    · 这个也不闪 ⇒ 位流没跑起来（配置/时钟/引脚），与 DDR3 无关
//
//  现象：led[0] 与 led[1] 反相，各 1 Hz（周期 1 s，肉眼一眼能看出来）。
//        哪个灯常亮不闪，就说明那个灯的引脚或焊接有问题。
//=============================================================================
`timescale 1ns / 1ps

module led_blink (
    input  wire       sys_clk,   // V4, 50 MHz
    output wire [1:0] led        // AB21 / AB22
);

    // 50 MHz / 2^25 ≈ 0.67 s 翻转一次；再分频成 1 Hz 方波
    reg [24:0] cnt;
    always @(posedge sys_clk) cnt <= cnt + 25'd1;

    reg hb;
    always @(posedge sys_clk) begin
        if (cnt == 25'd0) hb <= ~hb;
    end

    // 反相输出：一个亮一个灭，交替
    assign led[0] =  hb;
    assign led[1] = ~hb;

endmodule
