// =============================================================================
//  disp/freq_meter.v  --  输入频率 / 方向 / 累计位置 解算器（屏幕本机 UI 专用）
//
//  为什么这样算（2026-10-15 定案，见 docs/13_display_ui_requirements.md §7）：
//
//    1) 只拿 16 bit `angle` 求导在 f_in > 5 kHz 就混叠（host/encoder.py:10-12）。
//       必须用 pos_full 的 64 电周期解回绕。
//    2) 本模块在 50 MHz 上**逐拍**累加 pos_full 的有符号 22 bit 增量，
//       所以解回绕下限是「单拍位移 < 64 电周期」，即 f_in < 64 x 50 MHz = 3.2 GHz。
//       工程上不可能违反 —— 这就是「最精准」的来源：不存在量程上限的赌注。
//    3) 闸门取 1/64 s = 781,250 拍，频率解算因此**退化成精确的移位**：
//             f_in = Δ/65536 / (1/64) = Δ/1024
//       即闸门末的 32 bit 累加值 Δ 本身就是 f_in 的 1/1024 Hz 定点数（f_q10）。
//       **测量通路上没有乘法器、没有除法器、没有任何截断误差。**
//    4) 每 15.625 ms 出新值（64 次/s）。Δ 的 1 LSB = 1/1024 Hz ≈ 0.98 mHz
//       **绝对**分辨率，与 f_in 高低无关 —— 这就是「最快速」的来源：
//       闸门再短就会牺牲分辨率，再长就牺牲刷新率，1/64 s 是两者的最优折中。
//
//  ★ 时序纪律（docs/13_display_ui_requirements.md §7.2，Q7′ 三条硬规则）：
//      22 bit 减法与 32 bit 加法被**拆成两级流水**（d22_r / acc），
//      避免「减法串加法」形成新的关键路径；
//      48 bit 的 pos_acc 加法独占一拍（操作数是寄存器），
//      闸门边界只做一次搬移，其余时间全流水、无停顿、无分支失败。
//
//  ★ 交付纪律：本模块放在 disp/ 而不是 rtl/，因为它**不进入**编码器生产构建。
//      rtl/ 一行不动是本次屏幕项目的硬约束。
// =============================================================================
`timescale 1ns / 1ps

module freq_meter #(
    parameter integer CLK_HZ   = 50_000_000,   // 像素时钟 = 板载晶振，也是唯一的系统时钟
    parameter integer GATE_DIV = 64            // 闸门 = 1/GATE_DIV 秒（=64 时闸门 15.625 ms）
)(
    input  wire               clk,
    input  wire               rst_n,
    // 只读抽头：pos_full 的低 22 位 = {cycle_cnt[5:0], angle[15:0]}
    input  wire signed [21:0] pos_full,
    // f_in 的 1/1024 Hz 定点数（有符号）：f_in[Hz] = f_q10 / 1024
    output reg  signed [31:0] f_q10,
    // 上电以来的累计位置，单位 1/65536 电周期（48 bit 有符号，供累计转数使用）
    output reg  signed [47:0] pos_acc,
    // 2'b01 = 正向（CW），2'b10 = 反向（CCW），2'b00 = 静止
    output reg  signed [1:0]  dir,
    // 闸门结束脉冲（一拍的 valid），与 f_q10 / pos_acc / dir 同拍对齐
    output reg                valid
);

    // ---------------------------------------------------------------------
    // 闸门常数：50 MHz / 64 = 781,250 拍，需要 20 bit（2^20 = 1,048,576 > 781,250）
    // ---------------------------------------------------------------------
    localparam integer GATE_CLKS = CLK_HZ / GATE_DIV;
    localparam integer GCW       = 20;

    reg  signed [21:0] pos_prev;
    reg  signed [21:0] d22_r;      // 第 1 级流水：本拍位移
    reg  signed [31:0] acc;        // 第 2 级流水：闸门内累加
    reg  [GCW-1:0]     gate_cnt;
    reg                gate_d;     // 闸门结束，延后一拍（给方向/累计用）

    wire signed [21:0] d22    = pos_full - pos_prev;          // 22 bit 有符号，自然回绕
    wire signed [31:0] d22_x  = {{10{d22_r[21]}}, d22_r};     // 符号扩展到 32 bit
    wire               gate_e = (gate_cnt == GATE_CLKS - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos_prev <= 22'sd0;
            d22_r    <= 22'sd0;
            acc      <= 32'sd0;
            gate_cnt <= {GCW{1'b0}};
            gate_d   <= 1'b0;
            f_q10    <= 32'sd0;
            pos_acc  <= 48'sd0;
            dir      <= 2'sd0;
            valid    <= 1'b0;
        end else begin
            // ---- 第 1 级流水：22 bit 有符号增量（解 64 电周期回绕）----
            pos_prev <= pos_full;
            d22_r    <= d22;

            // ---- 闸门计数器 ----
            gate_cnt <= gate_e ? {GCW{1'b0}} : (gate_cnt + 1'b1);
            gate_d   <= gate_e;

            // ---- 第 2 级流水：32 bit 累加（与减法不同拍）----
            // 闸门末尾把「acc + 本拍增量」整体搬进 f_q10，累加器归零。
            // 每个闸门恰好累加 GATE_CLKS 个已寄存的增量，
            // 所以 f_q10 = Δ = GATE_CLKS 个增量的和，无重复、无丢失。
            if (gate_e) begin
                f_q10 <= acc + d22_x;
                acc   <= 32'sd0;
            end else begin
                acc   <= acc + d22_x;
            end

            // ---- 闸门后一拍：方向 + 累计位置 ----
            // 48 bit 加法独占一拍，操作数全是寄存器，不与其他逻辑串联。
            if (gate_d) begin
                if (f_q10[31])       dir <= 2'b10;   // 反向
                else if (f_q10 != 0) dir <= 2'b01;   // 正向
                else                 dir <= 2'b00;   // 静止（保持不了就明确报静止）
                pos_acc <= pos_acc + {{16{f_q10[31]}}, f_q10};
                valid   <= 1'b1;
            end else begin
                valid <= 1'b0;
            end
        end
    end

endmodule
