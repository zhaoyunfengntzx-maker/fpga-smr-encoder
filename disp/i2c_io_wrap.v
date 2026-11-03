// -----------------------------------------------------------------------------
//  disp/i2c_io_wrap.v
//  IIC 开漏双向引脚（自 lcd_test2/rtl/lcd_test_support.v 原样搬入，逻辑未改）
//
//  板级 T_SCL/T_SDA 上各有上拉（接 LCD 模块侧），FPGA 只负责"拉低"或"释放"。
//  这里用 IOBUF 实现：oe=1 时把 O（恒 0）推到线上 = 拉低；oe=0 时高阻 = 释放，
//  由外部上拉拉高。I 是回读值，经两级同步后再给 IIC 逻辑用。
//
//  ★ 搬入时唯一必须连注释一起保留的教训：IOBUF 的 T 是"三态使能、高有效"
//    （T=1 => 高阻），与本模块 oe 的语义相反，所以必须接 ~oe。曾经直接接 oe，
//    仿真桩恰好也写反（互相抵消、全绿），上板后"释放"变成"拉低"：
//    SDA 恒低 => 所有地址都像被 ACK、读回全 0。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module i2c_io_wrap (
    input  wire clk,
    input  wire rst_n,
    input  wire scl_oe,       // 1 = 拉低 SCL
    input  wire sda_oe,       // 1 = 拉低 SDA
    output wire scl_o,        // 同步后的线上电平
    output wire sda_o,
    inout  wire scl_io,
    inout  wire sda_io
);
    wire scl_i, sda_i;
    wire scl_sync, sda_sync;

    // 高阻时靠外部上拉（LCD 模块侧有上拉电阻）。
    IOBUF #(.DRIVE(8), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW")) u_scl (
        .O  (scl_i),
        .IO (scl_io),
        .I  (1'b0),
        .T  (~scl_oe)
    );
    IOBUF #(.DRIVE(8), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW")) u_sda (
        .O  (sda_i),
        .IO (sda_io),
        .I  (1'b0),
        .T  (~sda_oe)
    );

    reg [1:0] scl_s, sda_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_s <= 2'b11;
            sda_s <= 2'b11;
        end
        else begin
            scl_s <= {scl_s[0], scl_i};
            sda_s <= {sda_s[0], sda_i};
        end
    end

    assign scl_o = scl_s[1];
    assign sda_o = sda_s[1];
endmodule
