//=============================================================================
// 模块名 : cdc_sync2 / cdc_pulse
// 文件   : rtl/cdc_sync2.v
// 功能   : 跨时钟域（CDC）通用小模块，供全工程复用
//            cdc_sync2 : N 位两级同步器（电平/总线位同步）
//            cdc_pulse : 单周期脉冲跨时钟域（源域翻转 + 目标域边沿检测）
//
// Latency : cdc_sync2 : 2 个目标时钟周期（q_sync 在第 2 拍有效）
//           cdc_pulse: 源域翻转 1 拍 + 目标域 2 拍同步 + 1 拍边沿检测
//                      = 目标域 3 拍（相对源脉冲的绝对延迟还取决于两域相位）
// 资源估计: cdc_sync2 每个 bit 2 个 FF（WIDTH 位 -> 2*WIDTH FF，0 DSP，0 LUT）
//           cdc_pulse 约 6 个 FF
// 关键假设:
//   1. 复位是**同步、低有效**的，两个域共用 rst_n；顶层必须保证 rst_n 的释放
//      在两个时钟域内都已同步（例如各自用复位同步器），否则同步器第一级可能
//      出现亚稳态窗口内复位释放的问题。
//   2. cdc_sync2 只适合"多比特同时变化但可以容忍采样到中间态"的场合
//      （纯数据总线不建议直接用 2FF 同步器，应加握手或异步 FIFO）。
//      cdc_sync2 的典型用途：单比特标志、慢变化的电平（如 en/OTR/配置位）。
//   3. cdc_pulse 要求源域相邻两个脉冲的间隔 > 1 个目标时钟周期
//      （严格讲 ≥ 2 个目标周期保证被边沿检测捕获），否则翻转可能被吞掉。
//      脉冲过密时请改用异步 FIFO 或握手。
//   4. 两组 ASYNC_REG 属性必须保留，Vivado 才会把这两级 FF 放到同一个 slice
//      并做最小时延布线（等效于 MTBF 优化）。
//=============================================================================
`timescale 1ns / 1ps

//-----------------------------------------------------------------------------
// cdc_sync2 : WIDTH 位两级同步器
//-----------------------------------------------------------------------------
module cdc_sync2 #(
    parameter integer WIDTH = 1          // 同步信号位宽（≥1）
)(
    input  wire             clk,         // 目标时钟域时钟
    input  wire             rst_n,       // 同步复位，低有效（目标域）
    input  wire [WIDTH-1:0] d_async,     // 异步输入（源时钟域）
    output wire [WIDTH-1:0] q_sync       // 同步后的输出（目标域）
);

    // 两级同步寄存器：均加 ASYNC_REG，Vivado 会就近布局
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_meta;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_out;

    always @(posedge clk) begin
        if (!rst_n) begin
            sync_meta <= {WIDTH{1'b0}};
            sync_out  <= {WIDTH{1'b0}};
        end else begin
            sync_meta <= d_async;        // 第 1 级：可能亚稳态
            sync_out  <= sync_meta;      // 第 2 级：输出稳定
        end
    end

    assign q_sync = sync_out;

endmodule

//-----------------------------------------------------------------------------
// cdc_pulse : 单周期脉冲跨时钟域（toggle + 边沿检测）
//   源域：每来一个 pulse_in 就翻转一次电平 tog（电平在源域保持，不会丢）
//   目标域：两级同步 tog，再与延迟一拍的值异或 -> 目标域单周期脉冲
//-----------------------------------------------------------------------------
module cdc_pulse (
    input  wire clk_src,                 // 源时钟域
    input  wire clk_dst,                 // 目标时钟域
    input  wire rst_n,                   // 同步复位，低有效（两域共用）
    input  wire pulse_in,                // 源域单周期脉冲
    output reg  pulse_out                // 目标域单周期脉冲
);

    // ---- 源域：翻转电平 ----
    reg tog;

    always @(posedge clk_src) begin
        if (!rst_n) begin
            tog <= 1'b0;
        end else if (pulse_in) begin
            tog <= ~tog;
        end
    end

    // ---- 目标域：两级同步 + 边沿检测 ----
    (* ASYNC_REG = "TRUE" *) reg tog_meta;
    (* ASYNC_REG = "TRUE" *) reg tog_sync;
    reg tog_d;

    always @(posedge clk_dst) begin
        if (!rst_n) begin
            tog_meta  <= 1'b0;
            tog_sync  <= 1'b0;
            tog_d     <= 1'b0;
            pulse_out <= 1'b0;
        end else begin
            tog_meta  <= tog;
            tog_sync  <= tog_meta;
            tog_d     <= tog_sync;
            pulse_out <= tog_sync ^ tog_d;
        end
    end

endmodule
