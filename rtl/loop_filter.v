//=============================================================================
// loop_filter.v —— PI 伺服滤波（抖动抑制 / 滞后控制，SPEC_interface_contract.md §1.6）
//-----------------------------------------------------------------------------
// 功能
//   对 CORDIC 输出的周期内角度做 PI 环路滤波，输出扩展位置 pos_out（每圈
//   = REV = 2^(AW+FRAC)），并给出"超前/滞后 > 45°"的 lag_limit 标志
//   （对应 TW28 STAT_VAL.laglim）。
//
// Latency（in_valid -> out_valid）= 3 clk （内部环路状态 1 拍 + 输出流水 2 拍）
//   系统时钟 50 MHz（单时钟域，无 MMCM）-> 60 ns。
//
//------------------------------------------------------------------------------
// 定点与数学（内部位置 pos 为 AW+FRAC 位有符号，按 REV = 2^(AW+FRAC) 回绕）
//------------------------------------------------------------------------------
//   REV    = 1 << (AW+FRAC)          // 一圈 = 2^24（AW=16, FRAC=8）
//   ang_ext= (ang_in << FRAC)        // 输入角度扩展成 AW+FRAC 位定点
//   err    = wrap_signed(ang_ext - pos)   // 模 REV 的有符号差，自动折到 ±REV/2
//   I[n+1] = clamp(I[n] + (err >>> KI_SHIFT[ki]), ±REV/4)      // 积分（抗饱和限幅）
//   pos[n+1] = pos[n] + (err >>> KP_SHIFT[kp]) + I[n+1]        // P + I
//   lag_limit = (|err| > REV/8)      // 45°，与 TW28 STAT_VAL.laglim 同义
//
//   KP_SHIFT = {2,3,4,5,6,7,8,9}（kp=0..7，kp 越大 P 增益越小、滤波越重）
//   KI_SHIFT = {7,6,5,4}        （ki=0..3，与 SPEC §1.6 一致）
//   ★ SPEC §1.6 把 I 项写成 "pos = pos + P + I[n]"（用**上一拍**的积分值），
//     本模块用 I[n+1]（本拍更新后的积分值）。二者只差 Kp/Ki 的一个采样周期
//     相位，但稳定性完全不同，推导见下：
//       E/A = (z-1)^2 / ( z^2 + (Kp+Ki-2) z + (1-Kp) )
//     Jury 判据（二阶多项式 z^2+a1 z+a0）：
//       |a0| < 1        ->  0 < Kp < 2            （Kp = 2^-2 .. 2^-9，恒满足）
//       1+a1+a0 > 0     ->  Ki > 0                （ki>=1 时恒满足）
//       1-a1+a0 > 0     ->  Ki < 4-2Kp            （Ki<=2^-4, 4-2Kp>=3.5，恒满足）
//     => kp=0..7、ki=1..3 全部稳定。若按 SPEC 原文用 I[n]，判据变成
//        Ki < Kp 才稳定，于是 kp=6/ki=3（datasheet 推荐的 heavy 档）会发散——
//        这正是"把 PI 环路做成数学上自洽"必须改的地方。model/loop_filter_model.py
//        对全部 kp=0..6 × ki=1..3 组合做了阶跃响应实测，无发散。
//
//   DC 增益 P/A(1) = 1  => 阶跃输入稳态误差 0
//   E/A 在 z=1 处是**二阶零点** => 恒速输入的稳态滞后为 0（I 项的意义，
//     与 TW28 数据手册 "non-zero ki gives zero lag at constant velocity" 一致）
//
//   闭环带宽（把 z-1 近似成 sT，T = 1/fs）：
//       特征方程 -> s^2 + ((Kp+Ki)/T) s + Ki/T^2 = 0
//       ωn = sqrt(Ki)/T = sqrt(Ki) * fs   [rad/s]
//       ζ  = (Kp+Ki) / (2 sqrt(Ki))
//       f_3dB = ωn/(2π) * sqrt(1-2ζ² + sqrt((1-2ζ²)²+1))     (ζ<0.707 时)
//     fs = 50 MHz 时的几组值（对应 SPEC 的推荐档）：
//       kp=0 ki=3 : Kp=1/4,   Ki=1/16 , ζ=0.63, ωn=12.5 Mrad/s, f_3dB≈2.2 MHz
//       kp=2 ki=3 : Kp=1/16,  Ki=1/16 , ζ=0.25, ωn=12.5 Mrad/s, f_3dB≈2.6 MHz
//       kp=4 ki=3 : Kp=1/64,  Ki=1/16 , ζ=0.16, ωn=12.5 Mrad/s, f_3dB≈2.9 MHz
//       kp=6 ki=3 : Kp=1/256, Ki=1/16 , ζ=0.13, ωn=12.5 Mrad/s, f_3dB≈3.0 MHz
//       kp=0 ki=1 : Kp=1/4,   Ki=1/128, ζ=3.5 , ωn= 4.4 Mrad/s, f_3dB≈0.68 MHz
//     ★ ωn 只由 ki 决定、kp 只改阻尼：kp 越大阻尼越小（SPEC 也把 kp 描述成
//       "越大滤波越强"——它抑制的是单拍抖动，即高频噪声，代价是相位滞后）。
//       输入信号带宽（TW28 规格 ≤700 kHz 的 sin/cos 输入，50 MHz 采样下
//       一个输入周期至少 71 个采样点，即 ≤0.088 rad/sample）远低于上述 ωn，
//       环路对信号本身几乎不衰减，只对抖动起作用。
//
//   ki=0：关掉 I 通路（I 恒为 0），退化成纯 P 环路（与 TW28 "ki=0 时 kp 必须
//         也为 0" 的约束一致）；kp=0 且 ki=0：整个滤波器直通（pos = ang_ext），
//         用于标定/旁路。
//
// Latency = 3；freeze=1 时 pos_out 保持、积分器不清零（只冻结）。
//
// 资源估计：2 个 24bit 加减器 + 限幅比较器 + 3 级 24bit 流水
//           ~= 150 LUT / 150 FF / 0 DSP
// 复位：同步、低有效。无 initial / #delay / inout / SystemVerilog 语法。
//=============================================================================
module loop_filter #(
    parameter integer AW   = 16,    // 输入角度位宽（每周期 = 2^AW）
    parameter integer FRAC = 8,     // 扩展小数位
    // GATE_STATE（见 docs/DEV_STATUS.md §1.39/§1.40、§1.42 第 9/10 条）：
    //   0 = 环路状态 pos/integ 每个 clk 都更新。输入 in_valid 是 1/4 分频
    //       （cordic_valid = 12.5 MHz，见 rtl/decim_avg.v），所以"每样本"增益
    //       实际被放大 4 倍，I 项每样本 = err/4（ki=3, ki_shift=4），环路欠阻尼、
    //       在节拍上把 CORDIC 噪声放大 ~5 倍（ILA 实测）。★ 本默认值**保持不变**，
    //       因为 tb_loop_filter 与 model/loop_filter_model.py 都按"每 clk 更新"逐位对齐。
    //   1 = 只在 in_valid 拍更新环路状态（增益恢复"每样本"语义）。
    //   ★ 生产配置（rtl/enc_top.v 的 u_filter 例化）自 v8 起显式传 1；配套的 kp/ki
    //     复位值已重调为 kp=2/ki=3（rtl/reg_file.v 的 r_filt_k）。改动依据 = 全链路
    //     A/B 回放 sim/tb_loop_abz_chain.v。
    parameter integer GATE_STATE = 0
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire        [AW-1:0] ang_in,     // 输入角度（每周期 2^AW）
    input  wire                in_valid,
    input  wire        [3:0]    kp,         // 0…7（越大滤波越强，与 TW28 FILT_K.kp 同义）
    input  wire        [1:0]    ki,         // 0…3
    input  wire                freeze,      // 1=保持当前输出（用于标定/停机抱死）
    output reg  signed [AW+FRAC-1:0] pos_out, // 扩展位置，每周期 = 2^(AW+FRAC)
    output reg                  lag_limit,  // 超前/滞后超过 45°（对应 TW28 STAT_VAL.laglim）
    output reg                  out_valid,
    // ★ v9（S2）：速度观测输出 = 积分器状态（每抽样点的位置增量，单位 2^(AW+FRAC)/圈），
    //   与 pos_out 同拍对齐（同样延迟 3 拍）。锁定后它收敛到 ω·T_sample，是延迟前馈
    //   （rtl/lag_ff.v）和速度遥测的唯一数据源，不需要额外的微分器。
    //   注：ki=0（纯 P）或 bypass 时积分器恒 0，此时 speed_out 也是 0 —— 语义正确，
    //   因为没有积分器的环路对恒速输入有稳态误差，本来就不该拿来算 ω。
    output reg  signed [AW+FRAC-1:0] speed_out
);

    //-------------------------------------------------------------------------
    // 常量
    //-------------------------------------------------------------------------
    localparam integer PW = AW + FRAC;                      // 24，位置位宽

    localparam signed [PW-1:0] INTEG_POS = (1 << (PW - 2)) - 1; // +REV/4 - 1
    localparam signed [PW-1:0] INTEG_NEG = -(1 << (PW - 2));    // -REV/4
    localparam signed [PW-1:0] LAG_POS   =  (1 << (PW - 3));    // +REV/8 = 45°
    localparam signed [PW-1:0] LAG_NEG   = -(1 << (PW - 3));    // -REV/8

    //-------------------------------------------------------------------------
    // 移位表（用 function 写死，综合时按 kp/ki 折叠成小 mux）
    //-------------------------------------------------------------------------
    function integer kp_shift;
        input [3:0] k;
        begin
            case (k)
            4'd0: kp_shift = 2;
            4'd1: kp_shift = 3;
            4'd2: kp_shift = 4;
            4'd3: kp_shift = 5;
            4'd4: kp_shift = 6;
            4'd5: kp_shift = 7;
            4'd6: kp_shift = 8;
            default: kp_shift = 9;
            endcase
        end
    endfunction

    function integer ki_shift;
        input [1:0] k;
        begin
            case (k)
            2'd0: ki_shift = 7;
            2'd1: ki_shift = 6;
            2'd2: ki_shift = 5;
            default: ki_shift = 4;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // 输入扩展：ang_in(16bit unsigned) -> ang_ext(24bit signed) = ang_in << FRAC
    //-------------------------------------------------------------------------
    wire signed [PW-1:0] ang_ext = $signed({{(PW-AW){1'b0}}, ang_in}) <<< FRAC;

    //-------------------------------------------------------------------------
    // 环路状态
    //-------------------------------------------------------------------------
    reg signed [PW-1:0] pos;      // 已滤波位置（每圈 REV）
    reg signed [PW-1:0] integ;    // 积分器（速度项）

    // 模 REV 的有符号差：24bit 减法自然回绕，按有符号解释就是折到 ±REV/2
    wire signed [PW-1:0] err = ang_ext - pos;

    wire signed [PW-1:0] p_term    = err >>> kp_shift(kp);   // P 项
    wire signed [PW-1:0] i_inc     = err >>> ki_shift(ki);   // I 项增量
    wire signed [PW-1:0] integ_sum = integ + i_inc;
    wire signed [PW-1:0] integ_lim = (integ_sum > INTEG_POS) ? INTEG_POS :
                                     (integ_sum < INTEG_NEG) ? INTEG_NEG : integ_sum;

    wire i_en   = (ki != 2'd0);                       // ki=0 关闭 I 通路
    wire bypass = (kp == 4'd0) && (ki == 2'd0);       // 全 0 时直通

    wire signed [PW-1:0] integ_use = i_en ? integ_lim : {PW{1'b0}};
    wire signed [PW-1:0] pos_sum   = pos + p_term + integ_use;

    wire signed [PW-1:0] pos_nxt   = freeze ? pos :
                                     (bypass ? ang_ext : pos_sum);
    wire signed [PW-1:0] integ_nxt = freeze ? integ :
                                     (bypass ? {PW{1'b0}} : integ_use);

    wire lag_raw = (err > LAG_POS) || (err < LAG_NEG);   // 滞后 > 45°

    wire state_en = GATE_STATE ? in_valid : 1'b1;   // GATE_STATE=0 时恒 1（与旧版等效）

    always @(posedge clk) begin
        if (!rst_n) begin
            pos   <= {PW{1'b0}};
            integ <= {PW{1'b0}};
        end else if (state_en) begin
            pos   <= pos_nxt;
            integ <= integ_nxt;
        end
    end

    //-------------------------------------------------------------------------
    // 输出流水 2 拍：pos_out = 环路状态再延迟 2 拍，总 Latency = 3
    //-------------------------------------------------------------------------
    reg signed [PW-1:0] pos_p1;
    reg signed [PW-1:0] spd_p1;   // 速度观测的第 2 拍（与 pos_p1 同步）
    reg        [1:0]    vld_sr;   // [0]=延迟1拍, [1]=延迟2拍
    reg        [1:0]    lag_sr;

    // pos 状态本身即第 1 拍；pos_p1 第 2 拍；pos_out 第 3 拍。
    // vld_sr[1] 是"延迟 2 拍"，再打一拍给 out_valid 正好是第 3 拍，与 pos_out 对齐；
    // lag_raw 走同样深度，lag_limit 与 out_valid 同拍。
    always @(posedge clk) begin
        if (!rst_n) begin
            pos_p1    <= {PW{1'b0}};
            pos_out   <= {PW{1'b0}};
            spd_p1    <= {PW{1'b0}};
            speed_out <= {PW{1'b0}};
            vld_sr    <= 2'd0;
            lag_sr    <= 2'd0;
            out_valid <= 1'b0;
            lag_limit <= 1'b0;
        end else begin
            pos_p1    <= pos;
            pos_out   <= pos_p1;
            // 速度观测走同样深度的流水：integ 是第 1 拍，spd_p1 第 2 拍，speed_out 第 3 拍
            spd_p1    <= integ;
            speed_out <= spd_p1;
            vld_sr    <= {vld_sr[0], in_valid};
            lag_sr    <= {lag_sr[0], lag_raw};
            out_valid <= vld_sr[1];
            lag_limit <= lag_sr[1];
        end
    end

endmodule
