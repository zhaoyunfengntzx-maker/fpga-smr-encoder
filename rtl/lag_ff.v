//=============================================================================
// lag_ff.v —— 速度前馈延迟补偿（Delay / Lag Feed-Forward）
//-----------------------------------------------------------------------------
// 为什么需要它
//   从 ADC 采样到 pos_out 输出，中间有固定延迟 T（抽取盒式平均 + 校正 + CORDIC +
//   环路滤波，实测约 0.6~0.9 µs）。PI 环路对**恒速**输入的稳态误差为 0，但它跟踪的
//   是"延迟之后的测量值"，所以输出位置相对真实位置**恒滞后 ω·T**：
//
//       角度误差(°) = 360 × f_el × T
//
//   2048 PPR、3000 rpm（f_el = 102.4 kHz）、T = 0.83 µs 时：
//       误差 = 360 × 102.4e3 × 0.83e-6 = 30.6° 电角度 = 30.6/2048 转 ≈ 0.015° 机械
//            ≈ **54″** —— 这比 ±1″ 的目标大 50 倍，是高速段精度的第一杀手。
//
//   本模块把这个滞后算出来并加回去：corr = ω × T（ω = 每个抽样点的位置增量，
//   直接取自 loop_filter 的积分器，它天然就是"每样本速度"，且已被环路平滑）。
//
// 数学
//   speed_pos : 每个抽样点的位置增量，单位 = 位置 LSB（REV = 2^(AW+FRAC)）
//   tau_q8    : 总延迟 T，单位 = 抽样点，Q8（例如 7.4 个抽样点 -> 1894）
//   corr      = (speed_pos × tau_q8) >>> 8      （位置单位，有符号）
//   饱和到 ±(2^(AW+FRAC-1)-1)，防止异常速度把位置推飞。
//
//   ★ 为什么在"位置域"而不是"角度域"算：位置域是连续量，加回去之后整圈位置
//     {周期计数, 角度} 天然连续（32 位加法自动进位/借位），不会在过零点出现
//     "角度先跳、计数后跟"的错拍（UVW 那一课就是这么来的，见 enc_top.v:719 注释）。
//
// 用法（enc_top）
//   u_filter.speed_out -> speed_pos
//   corr 加到 pos_full 上得到"上报位置"，**只给遥测/显示用**；
//   UVW/ABZ/Z 的判据仍用未修正的 pos_full —— 那边的边沿时序对固定延迟不敏感，
//   而把修正掺进周期计数会在过零点制造 ±1 计数抖动。
//
// Latency = 3 clk（乘法 1 拍 + 饱和/有效 1 拍 + 输出 1 拍），50 MHz 下 60 ns。
// 资源：1 个 DSP48（24×16）+ 少量 LUT。en=0 时输出恒 0（等价于不补偿）。
// 复位：同步、低有效。无 initial / #delay / inout / SystemVerilog 语法。
//=============================================================================
module lag_ff #(
    parameter integer AW   = 16,
    parameter integer FRAC = 8
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire signed [AW+FRAC-1:0]  speed_pos,   // 每抽样位置增量
    input  wire        [15:0]         tau_q8,      // 延迟，Q8 抽样点
    input  wire                       en,          // 1=补偿
    output reg  signed [AW+FRAC-1:0]  corr_out,    // 修正量（位置单位）
    output reg                        corr_valid
);

    localparam integer PW  = AW + FRAC;
    localparam signed [PW-1:0] CORR_MAX =  (1 << (PW-2)) - 1;   // ±REV/4 上限
    localparam signed [PW-1:0] CORR_MIN = -(1 << (PW-2));

    //------------------------------------------------------------------
    // 乘法：24 位有符号 × 16 位无符号 -> 40 位有符号
    //------------------------------------------------------------------
    reg  signed [PW+15:0] prod_q8;      // 延迟 1 拍
    reg                   prod_vld;
    reg                   en_d;

    wire signed [PW+15:0] prod_full = speed_pos * $signed({1'b0, tau_q8});

    always @(posedge clk) begin
        if (!rst_n) begin
            prod_q8  <= {(PW+16){1'b0}};
            prod_vld <= 1'b0;
            en_d     <= 1'b0;
        end else begin
            prod_q8  <= prod_full;
            prod_vld <= 1'b1;           // 输入每拍都有效（speed 是连续状态量）
            en_d     <= en;
        end
    end

    //------------------------------------------------------------------
    // 右移 8 位 + 饱和 + 使能（第 2/3 拍）
    //------------------------------------------------------------------
    // ★ 2026-11-02 审计修复：原来先 `prod_q8 >>> 8` 截成 24 位再判饱和，
    //   真值落在 (2^23, 2^24) 时截断后变负数，本该饱和到 +REV/4，实际饱和到 −REV/4
    //   （位置会朝反方向猛跳四分之一圈）。现在在全宽（PW+16 位）上先饱和、最后再取低位。
    //   常规工况 |corr| ≤ REV/4 时行为与旧版完全一致（见 sim/tb_lag_ff_sat.v）。
    localparam signed [PW+15:0] CORR_MAX_W = CORR_MAX;
    localparam signed [PW+15:0] CORR_MIN_W = CORR_MIN;

    wire signed [PW+15:0] corr_sh = prod_q8 >>> 8;      // 40 位算术右移，不会溢出

    wire signed [PW-1:0] corr_sat = (corr_sh > CORR_MAX_W) ? CORR_MAX :
                                    (corr_sh < CORR_MIN_W) ? CORR_MIN :
                                    corr_sh[PW-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            corr_out   <= {PW{1'b0}};
            corr_valid <= 1'b0;
        end else begin
            corr_out   <= en_d ? corr_sat : {PW{1'b0}};
            corr_valid <= prod_vld;
        end
    end

endmodule
