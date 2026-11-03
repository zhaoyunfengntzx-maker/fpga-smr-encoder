// ============================================================================
//  lcd_test/sim/iobuf_stub.v  ——  仿真专用 IOBUF 桩模型（不进综合源集）
// ----------------------------------------------------------------------------
//  为什么需要
//    lcd_test/rtl/lcd_test_support.v 里的 i2c_io_wrap 例化了两个 IOBUF（开漏 IIC
//    的引脚原语）。真实定义在 unisims_ver 里，本机没有预编译 xsim 库，所以仿真时
//    用本桩代替。综合时 Vivado 解析到真实 IOBUF，两者不冲突（本文件只被测试台调用）。
//
//  桩的保真度（★ 必须与真实 IOBUF 的 T 极性一致：T=1 => 高阻，T=0 => 驱动）
//    · IO        ：T=0 时由 I 驱动引脚（I 恒 0 => 拉低）；T=1 时引脚呈高阻（z），
//                  由外部上拉/从机驱动
//    · O         ：回读引脚实际电平（含外部驱动的影响）——这正是"开漏读回"的关键，
//                  如果这里写成 I 就会丢掉从机拉低的效果。
//  ★ 曾经写反过：`IO = T ? I : 1'bz`（T=1 驱动）与真实原语相反，导致仿真全绿、上板
//    却把"释放"变成"拉低"（SDA 恒低 => 所有地址都像被 ACK、读回全 0），见
//    docs/LCD_touch_test_readme.md §12 的"上板实测记录"。
// ============================================================================

`timescale 1ns / 1ps

module IOBUF #(
    parameter DRIVE      = 12,
    parameter IOSTANDARD = "DEFAULT",
    parameter SLEW       = "SLOW"
) (
    input  wire I,
    output wire O,
    inout  wire IO,
    input  wire T
);
    assign O  = IO;
    assign IO = T ? 1'bz : I;      // 真实 IOBUF 语义：T=1 高阻，T=0 驱动
endmodule
