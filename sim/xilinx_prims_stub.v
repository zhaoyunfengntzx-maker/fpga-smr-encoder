// ============================================================================
//  xilinx_prims_stub.v  ——  仿真专用 Xilinx 原语桩模型（不是 RTL 的一部分）
// ----------------------------------------------------------------------------
//  为什么需要
//    rtl/enc_top.v 例化了两个 Xilinx 原语：BUFG（rtl/enc_top.v:94）与 ODDR
//    （rtl/enc_top.v:113-125）。原语定义在 Vivado 的 unisims_ver 库里，而本机
//    没有预编译的 xsim 库（D:\Vivado\2026.1\Vivado\data\xsim 下无 compile_simlib.tcl）。
//    本文件给出行为等价的桩，仅供仿真；综合时 Vivado 解析到 unisims_ver 的真实
//    原语，两者不冲突（本文件只被 tb_enc_top 的 xvlog 调用，不进综合源集）。
//
//  桩的保真度
//    · BUFG：纯缓冲。仿真中无时钟树延迟，I -> O 组合直通，与 unisims 行为一致。
//    · ODDR：DDR_CLK_EDGE="SAME_EDGE" 的标准行为 —— 上升沿输出 D1、下降沿输出 D2，
//      初值 INIT，R/S 异步置位复位。rtl/enc_top.v 用 D1=0/D2=1，于是 Q 在 clk
//      上升沿变低、下降沿变高，得到 ad_clk 相对 clk_i 反相 180° —— 这正是
//      rtl/enc_top.v:109-111 注释声明的意图（ad_clk 上升沿比 clk 上升沿晚 10 ns）。
// ============================================================================

`timescale 1ns / 1ps

module BUFG (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule

module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter INIT         = 1'b0,
    parameter SRTYPE       = "SYNC"
) (
    output wire Q,
    input  wire C,
    input  wire CE,
    input  wire D1,
    input  wire D2,
    input  wire R,
    input  wire S
);
    reg q_r;

    initial q_r = INIT;

    // SAME_EDGE：D1 在上升沿、D2 在下降沿输出（同一个时钟沿寄存器实现）
    always @(posedge C) if (CE) q_r <= D1;
    always @(negedge C) if (CE) q_r <= D2;

    // R/S：SRTYPE="ASYNC" 时异步生效，否则随 C 同步生效
    generate
        if (SRTYPE == "ASYNC") begin : g_async
            always @(posedge R or posedge S) begin
                if (R) q_r <= 1'b0;
                else if (S) q_r <= 1'b1;
            end
        end else begin : g_sync
            always @(posedge C) begin
                if (R) q_r <= 1'b0;
                else if (S) q_r <= 1'b1;
            end
        end
    endgenerate

    assign Q = q_r;
endmodule

// ----------------------------------------------------------------------------
//  IDDR：RGMII RX 用。SAME_EDGE_PIPELINED —— Q1=上升沿样本、Q2=下降沿样本
//  但两者在同一个时钟沿更新（流水化），等价于把 D 在 C 的上升/下降沿各打一拍，
//  Q1 比 Q2 早半拍；仿真里用"上升沿采 D 到 q1，下降沿采 D 到 q2"即可。
// ----------------------------------------------------------------------------
module IDDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter INIT_Q1      = 1'b0,
    parameter INIT_Q2      = 1'b0,
    parameter SRTYPE       = "SYNC"
) (
    output wire Q1,
    output wire Q2,
    input  wire C,
    input  wire CE,
    input  wire D,
    input  wire R,
    input  wire S
);
    reg q1_r, q2_r;

    initial begin
        q1_r = INIT_Q1;
        q2_r = INIT_Q2;
    end

    always @(posedge C) if (CE) q1_r <= D;
    always @(negedge C) if (CE) q2_r <= D;

    generate
        if (SRTYPE == "ASYNC") begin : g_async_i
            always @(posedge R or posedge S) begin
                if (R) begin q1_r <= 1'b0; q2_r <= 1'b0; end
                else if (S) begin q1_r <= 1'b1; q2_r <= 1'b1; end
            end
        end
    endgenerate

    assign Q1 = q1_r;
    assign Q2 = q2_r;
endmodule

// ----------------------------------------------------------------------------
//  MMCME2_BASE：仿真里只做"按 CLKOUTn_DIVIDE 分频 + LOCKED 延迟拉高"。
//  真实 MMCM 的相位/抖动不在仿真范围内，时序由 Vivado 的 timing 报告保证。
// ----------------------------------------------------------------------------
module MMCME2_BASE #(
    parameter BANDWIDTH          = "OPTIMIZED",
    parameter CLKIN1_PERIOD      = 10.0,
    parameter DIVCLK_DIVIDE      = 1,
    parameter CLKFBOUT_MULT_F    = 5.0,
    parameter CLKFBOUT_PHASE     = 0.0,
    parameter CLKOUT0_DIVIDE_F   = 1.0,
    parameter CLKOUT0_DUTY_CYCLE = 0.5,
    parameter CLKOUT1_DIVIDE     = 1,
    parameter REF_JITTER1        = 0.010,
    parameter STARTUP_WAIT       = "FALSE"
) (
    input  wire CLKIN1,
    input  wire CLKFBIN,
    output wire CLKFBOUT,
    output wire CLKOUT0,
    output wire CLKOUT1,
    output wire CLKOUT2,
    output wire CLKOUT3,
    output wire CLKOUT4,
    output wire CLKOUT5,
    output wire LOCKED,
    input  wire PWRDWN,
    input  wire RST
);
    // VCO = CLKIN1 * MULT / DIVCLK，输出 = VCO / DIVIDE
    localparam real T_IN   = CLKIN1_PERIOD;
    localparam real T_VCO  = T_IN * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
    localparam real T_OUT0 = T_VCO * CLKOUT0_DIVIDE_F;
    localparam real T_OUT1 = T_VCO * CLKOUT1_DIVIDE;

    assign CLKFBOUT = CLKIN1;

    reg clk0_r = 1'b0;
    reg clk1_r = 1'b0;

    always #(T_OUT0 / 2.0) clk0_r = ~clk0_r;
    always #(T_OUT1 / 2.0) clk1_r = ~clk1_r;

    assign CLKOUT0 = clk0_r;
    assign CLKOUT1 = clk1_r;
    assign CLKOUT2 = 1'b0;
    assign CLKOUT3 = 1'b0;
    assign CLKOUT4 = 1'b0;
    assign CLKOUT5 = 1'b0;

    reg locked_r = 1'b0;
    initial #(T_IN * 100.0) locked_r = 1'b1;
    assign LOCKED = locked_r;
endmodule

// ----------------------------------------------------------------------------
//  IDELAYE2：默认 USE_IDELAY=0 时不会被例化，留个空桩免得改参数时编译失败。
// ----------------------------------------------------------------------------
module IDELAYE2 #(
    parameter IDELAY_TYPE           = "FIXED",
    parameter IDELAY_VALUE          = 0,
    parameter DELAY_SRC             = "IDATAIN",
    parameter SIGNAL_PATTERN        = "DATA",
    parameter REFCLK_FREQUENCY      = 200.0,
    parameter HIGH_PERFORMANCE_MODE = "TRUE",
    parameter CINVCTRL_SEL          = "FALSE",
    parameter PIPE_SEL              = "FALSE"
) (
    input  wire       C,
    input  wire       CE,
    input  wire       INC,
    input  wire       LD,
    input  wire       LDPIPEEN,
    input  wire       REGRST,
    input  wire [4:0] CNTVALUEIN,
    input  wire       IDATAIN,
    input  wire       DATAIN,
    output wire [4:0] CNTVALUEOUT,
    output wire       DATAOUT
);
    assign DATAOUT     = IDATAIN;
    assign CNTVALUEOUT = CNTVALUEIN;
endmodule


// ----------------------------------------------------------------------------
//  BUFIO：RX 采样时钟走 IO 时钟网；行为级就是一根线（tb 里 rgmii_rxc 由 TB 驱动）。
// ----------------------------------------------------------------------------
module BUFIO (input wire I, output wire O);
    assign O = I;
endmodule

// ----------------------------------------------------------------------------
//  IDELAYCTRL：校准 IDELAYE2 的 tap 基准；行为级 RDY 跟随复位。
// ----------------------------------------------------------------------------
module IDELAYCTRL (
    output wire RDY,
    input  wire REFCLK,
    input  wire RST
);
    assign RDY = ~RST;
endmodule

// ----------------------------------------------------------------------------
//  IOBUF：双向 IO。T=1 时输出高阻（读），T=0 时驱动 I（写）；O 始终跟随 IO。
//  disp/i2c_io_wrap.v 用它做 touch_scl/touch_sda 的开漏双向口；xsim 没有 unisims 预编译库，
//  所以这里给行为等价模型（2026-11-02 补，B2 显示覆盖时缺 IOBUF 导致 xelab 失败）。
// ----------------------------------------------------------------------------
module IOBUF #(
    parameter integer DRIVE = 12,
    parameter IOSTANDARD = "DEFAULT",
    parameter SLEW = "SLOW"
) (
    input  wire I,
    input  wire T,
    output wire O,
    inout  wire IO
);
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule
 
// IBUF/OBUF/OBUFT：同族单端口缓冲，行为级为直连。
module IBUF (input wire I, output wire O);
    assign O = I;
endmodule

module OBUF (input wire I, output wire O);
    assign O = I;
endmodule

module OBUFT (input wire I, input wire T, output wire O);
    assign O = T ? 1'bz : I;
endmodule
