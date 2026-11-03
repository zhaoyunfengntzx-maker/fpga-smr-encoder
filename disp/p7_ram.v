// ===========================================================================
// disp/p7_ram.v -- P7 曲线用的 128 箱小 RAM
//
// 这一块被例化三次，靠 DW / INIT 两个参数区分用途：
//   acc_ram   : DW=32，字 = {hi[15:0], lo[15:0]}，每箱的原始幅值上下界
//               INIT = {16'h0000, 16'hFFFF} —— "还没有数据"时 lo 取最大、hi 取最小，
//               于是显示侧的区间比较 (lo <= y <= hi) 恒为假，屏上是一条**空白**，
//               而不是假装有一条压在最上面的线。
//   bef_ram   : DW=16，字 = {hi_y[7:0], lo_y[7:0]}，"标定前"那条曲线，已换算成屏上行号
//   aft_ram   : DW=16，同上，"标定后"
//               INIT = {8'd120, 8'd120} —— 第一帧 dump 之前先画成一条中间横线。
//
// 为什么显示侧存的是**行号**而不是原始幅值：像素通路里不允许出现乘法/比较链
// （docs/13_display_ui_requirements.md §7.2），换算必须在消隐期做完。
//
// 为什么读口只有一个而显示要两条曲线：两条曲线各自一块 RAM，**同时**用同一个箱号
// 读，两拍数据在同一拍返回，显示侧只补一级寄存器就与 px2 对齐（U-16 的级数规则）。
// ===========================================================================
`default_nettype none

module p7_ram #(
    parameter integer  DW   = 16,
    parameter [DW-1:0] INIT = {DW{1'b0}}
)(
    input  wire          clk,
    input  wire          we,
    input  wire [6:0]    waddr,
    input  wire [DW-1:0] wdata,
    input  wire [6:0]    raddr,
    output reg  [DW-1:0] rdata
);

    reg [DW-1:0] mem [0:127];
    integer i;

    // 显式清零/铺初值：仿真里没写过的字是 X，会顺着比较链漏进整块底色断言
    // （disp/text_ram.v 在 U-11 那轮踩过同一个坑）。
    initial begin
        for (i = 0; i < 128; i = i + 1) mem[i] = INIT;
    end

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule

`default_nettype wire
