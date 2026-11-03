// ============================================================================
//  calib_ctrl.v  ——  六参数**闭式**自动标定状态机 (核心创新点)
// ----------------------------------------------------------------------------
//  功能
//    对 sin/cos 通道做一次闭式"椭圆 -> 圆"映射标定。信号模型：
//        s = A_s*sin(th) + O_s
//        c = A_c*cos(th + dphi) + O_c
//    在标定窗口(win_cycles 个 sin/cos 输入周期)内累加 5 个量：
//        S1=Σs   S2=Σc   S3=Σs²   S4=Σc²   S5=Σs·c      (48 位累加器)
//    N = 实际累加样本数(sample 数，不是周期数)。然后：
//        O_s = S1/N ;  O_c = S2/N
//        ms2 = S3/N - O_s²          (二阶中心矩 = mean((s-O_s)²))
//        mc2 = S4/N - O_c²
//        A_s = sqrt(2*ms2) ;  A_c = sqrt(2*mc2)      // 正弦幅度不是 RMS!
//        sd  = S5/N - O_s*O_c       (= mean(s1*c1), s1=s-O_s, c1=c-O_c)
//        sin_dp = clamp(-2*sd/(A_s*A_c), -0.5, +0.5)
//        cos_dp = sqrt(1 - sin_dp²)
//        phase_k(Q1.15) = 32768 * (2*sd)/(A_s*A_s)
//        ref = 26214 (= 0.80*32768，归一化目标幅度)
//        tg_s = ref/A_s ;  tg_c = ref/(A_c*cos_dp)
//        sh   = 满足 tg/2^sh <= 1.999 的最小 sh (0..3)   [_coarse_shift()]
//        gain_s(Q1.15) = 32768*tg_s/2^sh_s ;  gain_c 同理
//
//  与 model/golden_model.py::calibrate() / _coarse_shift() 逐式对应
//     o_s / o_c            -> S_OFFSET      （S1/N、S2/N，向零截断）
//     ms2 / mc2 / sd       -> S_AMP         （S3/N、S4/N、|S5|/N 再减乘积）
//     a_s / a_c            -> S_SQRT1/2     （共用逐位开方器）
//     sin_dp / cos_dp      -> S_PHASE
//     tg_s / tg_c          -> S_GAIN
//     phase_k              -> S_DIV
//     _coarse_shift + gain -> S_SHIFT       （gain = tg >> sh）
//     写回寄存器组          -> S_WRITE
//    RTL 使用**向零截断**的整数除法/开方，golden_model 用浮点 + round，
//    故二者可能相差 ≤1 LSB（已在此说明）。
//
//  资源 vs 延迟的取舍（明确记录）
//    9 次除法共用一个 48 位恢复余数除法器(48 拍/次)，3 次开方共用一个 32 位
//    逐位开方器(16 拍/次)：
//        9×49 + 3×17 ≈ 492 clk ≈ 4.9 µs @100 MHz，只在每次标定开始时发生一次。
//    若改为全并行/流水，9 个除法器 + 3 个开方器要多消耗约 8 个 DSP48 与上千
//    LUT，对 XC7A35T(20800 LUT / 90 DSP) 不划算 —— 因此选择"串行复用"。
//
//  标定精度（来自已验证的 model/golden_model.py，AW=16，16 位角度）
//    偏置 + 增益失衡 + 正交误差 组合工况：校正前最大角误差 20.98°，
//    校正后 0.0165°（≈1273 倍改善），已到达 16 位角度量化底噪(0.0055° 量级)。
//    残余误差主要由未补偿的 2 次谐波决定（0.5% 谐波 -> 0.357° 残余）。
//
//  未来工作（默认关闭的扩展钩子，本模块不实现谐波估计器）
//    2 次谐波校正：sc_correct 中 s -= (h2_k*s2_est)>>>15, c 同理，h2_k 来自
//    reg_file 的 0x051B/0x051C(cfg_h2_k)。估计器需额外累加 Σs·sin2θ 等项，
//    本版只预留寄存器地址，不做估计（见文件末尾 H2_HOOK 注释块）。
//
//  Latency
//    start 上升沿 -> done ≈ (窗口周期数 × 每周期样本数) + 约 520 clk。
//    纯计算段(累加结束 -> done) ≈ 520 clk ≈ 5.2 µs @100 MHz。
//
//  资源估计 / 关键假设
//    FF ≈ 480（5×48 累加器 + 除法器 48×3+32 + 开方 32+20+17 + 结果寄存器）
//    LUT ≈ 700，DSP = 3（s²、c²、s·c 三个 16×16 乘法）
//    假设 1) 单次标定最多累加 MAX_SAMPLES = 65536 个样本 => |S5| ≤ 2^46、
//            S3/S4 ≤ 2^46，48 位累加器不溢出；超限则提前结束并置 truncated。
//    2) win_cycles 以 cycle_pulse 计数（每 sin/cos 输入周期 1 个脉冲）。
//    3) 结果通过 calib_we/calib_addr/calib_wdata 以字节写方式写回 reg_file。
// ============================================================================

module calib_ctrl #(
    parameter integer REF_Q15     = 26214,   // 0.80 * 32768，归一化目标幅度
    parameter integer MAX_SAMPLES = 65536    // 累加器不溢出的样本上限
)(
    input  wire                clk,
    input  wire                rst_n,
    // ---- 控制 ----
    input  wire                start,          // 上升沿启动一次标定
    input  wire [15:0]         win_cycles,     // 标定窗口(输入周期数)，0 视为 1
    output reg                 busy,
    output reg                 done,           // 保持到下次 start
    output reg                 truncated,      // 因样本上限提前结束窗口
    output reg  [2:0]          retry_cnt,      // ★ 因"窗口非整周期"丢弃重来的次数
    output reg                 win_bad,        // ★ 重试用尽仍有非整周期窗口（结果可能有偏）
    // ---- ★ v6 诊断快照：最近一次**关门**时的窗口统计（SPI 只读，见 docs §1.32）----
    //   目的：板上"到底间隔偏了多少"过去没有任何读出口（int_min/int_max/nsamp/wcnt
    //   全是内部量），只能靠 ILA 撞 20.5 µs 窗口 ⇒ 现在一次 UART 读回即可定量。
    output reg  [17:0]         dbg_int_min,    // 窗口内最小周期间隔（样本数）
    output reg  [17:0]         dbg_int_max,    // 窗口内最大周期间隔
    output reg  [17:0]         dbg_nsamp_cls,  // 关门时的样本数
    output reg  [15:0]         dbg_wcnt_cls,   // 关门时已完成的输入周期数
    // ---- 待标定信号 (Q1.15) ----
    input  wire signed [15:0]  s_n,
    input  wire signed [15:0]  c_n,
    input  wire                in_valid,       // 每个样本 1 拍
    input  wire                cycle_pulse,    // 每个 sin/cos 输入周期 1 个脉冲
    // ---- 结果（写回寄存器组，同时直接输出便于顶层/测试台使用）----
    output reg  signed [15:0]  res_ofs_s,
    output reg  signed [15:0]  res_ofs_c,
    output reg         [15:0]  res_gain_s,
    output reg         [15:0]  res_gain_c,
    output reg  signed [15:0]  res_phase_k,
    output reg         [1:0]   res_shift_s,
    output reg         [1:0]   res_shift_c,
    // ---- 写寄存器组接口（字节宽，与 spi_slave -> reg_file 一致）----
    output reg                 calib_we,
    output reg  [15:0]         calib_addr,
    output reg  [7:0]          calib_wdata,
    // ---- 调试 ----
    output reg  [3:0]          state_dbg
);

    // ------------------------------------------------------------------
    // 结果寄存器地址（与 reg_file.v 的 0x05xx 扩展段一致）
    // ------------------------------------------------------------------
    localparam [15:0] ADDR_OFS_S   = 16'h0510;   // 0x0510 低字节 / 0x0511 高字节
    localparam [15:0] ADDR_OFS_C   = 16'h0512;
    localparam [15:0] ADDR_GAIN_S  = 16'h0514;
    localparam [15:0] ADDR_GAIN_C  = 16'h0516;
    localparam [15:0] ADDR_PHASE_K = 16'h0518;
    localparam [15:0] ADDR_SHIFT   = 16'h051A;   // [1:0]=shift_s [3:2]=shift_c

    // 增益分子（定点推导见头注释）
    //   gain_s = 32768*REF_Q15 / A_s                     (30 bit 分子)
    //   gain_c = 32768^2*REF_Q15 / (A_c*cos_dp)          (45 bit 分子)
    localparam [31:0] REF32      = REF_Q15;                     // 32 位无符号解释
    localparam [47:0] NUM_GAIN_S = 48'd32768 * {16'd0, REF32};
    localparam [47:0] NUM_GAIN_C = (48'd1 << 30) * {16'd0, REF32};

    // _coarse_shift 判据：tg/2^sh <= 1.999  <=>  32768*tg <= 1.999*32768
    localparam [31:0] TG_SH0 = 32'd65503;    // round(1.999*32768)
    localparam [31:0] TG_SH1 = 32'd131006;
    localparam [31:0] TG_SH2 = 32'd262012;

    localparam [31:0] TWO_POW_30 = 32'h40000000;
    localparam [31:0] MAX_SAMP   = MAX_SAMPLES;    // 0..2^31-1，累加器不溢出上限

    // 状态编码（state_dbg 4 位）
    localparam [3:0] S_IDLE   = 4'd0,
                     S_ACCUM  = 4'd1,
                     S_OFFSET = 4'd2,
                     S_AMP    = 4'd3,
                     S_SQRT1  = 4'd4,
                     S_SQRT2  = 4'd5,
                     S_PHASE  = 4'd6,
                     S_GAIN   = 4'd7,
                     S_DIV    = 4'd8,
                     S_SHIFT  = 4'd9,
                     S_WRITE  = 4'd10,
                     S_DONE   = 4'd11;

    // ==================================================================
    // 1) 累加器与乘法
    // ==================================================================
    reg signed [47:0] S1, S2, S3, S4, S5;
    reg        [17:0] nsamp;        // 已累加样本数 0..MAX_SAMP
    reg        [15:0] wcnt;         // 已完成的输入周期数
    reg        [31:0] n_win;        // 本次窗口实际样本数 N

    // ★ 2026-10-10 整周期收尾（修"1 kHz 一键标定失效"）：
    //   nsamp_prev = 上一个输入周期边界处的样本数，用来算出"一个输入周期有多少样本"，
    //   从而在样本上限（MAX_SAMP）到来**之前**的周期边界上关门（见 S_ACCUM）。
    reg        [17:0] nsamp_prev;
    reg        [17:0] plast_t;      // 上一个周期的样本数（组合中间量）
    reg        [31:0] nxt_est_t;    // 本边界样本数 + 2*上一周期样本数
    reg               cap_stop_t;   // 1 = 再累加一个周期就装不下 MAX_SAMP 了

    // ★ 2026-10-10 非整周期窗口检测 + 重试（根因见 docs/DEV_STATUS.md §1.28）：
    //   周期脉冲来自顶层 angle_raw 的 MSB 翻转检测；若过零点附近 MSB 抖动，脉冲
    //   相位会跳半个周期，窗口就变成**奇数个半周期**（非整数个输入周期）⇒ 一阶矩
    //   O_s 被 ±2A/(nπ) 污染（实测 0x0766/0x076A/0xF6FE/0xF6FF），而 O_c 不受影响。
    //   这里用"窗口内各周期样本数的 max/min"识别这种窗口：正常时每次间隔都等于
    //   一个输入周期的样本数（±几拍抖动）；半周期错位会让窗口里恰好多出一个半
    //   周期 ⇒ 只有一个间隔变成 3H、其余为 2H ⇒ max/min = 1.5（判据用 1.25 倍，
    //   见下面的说明，1.5 倍的严格判据会正好漏检）。识别到就本轮作废、重新标定，
    //   最多 MAX_RETRY 次。
    reg        [17:0] int_min;      // 窗口内最小周期间隔（样本数）
    reg        [17:0] int_max;      // 窗口内最大周期间隔（样本数）
    reg               int_seen;     // 已记录过至少一个周期间隔
    reg        [17:0] lim_min_t;    // 含收尾那拍的 min（组合中间量）
    reg        [17:0] lim_max_t;    // 含收尾那拍的 max（组合中间量）
    reg               win_bad_t;    // 本次窗口非整周期（组合中间量）
    localparam [2:0]  MAX_RETRY = 3'd3;

    // ★ 2026-10-10 幂等标定（docs/DEV_STATUS.md §1.18）：
    //   armed  = 已对齐到第一个输入周期边界，此前的样本一律不累加。
    //   arm_tmo= 等待周期边界的保护计时：输入不转/极慢时不会挂死（1 s @50MHz）。
    reg               armed;
    reg        [25:0] arm_tmo;
    localparam [25:0] ARM_TMO_MAX = 26'd50_000_000;   // 1 s @ 50 MHz

    wire signed [15:0] s_s = s_n;
    wire signed [15:0] c_s = c_n;
    wire signed [31:0] p_ss = s_s * s_s;      // Q2.30，|.| <= 2^30
    wire signed [31:0] p_cc = c_s * c_s;
    wire signed [31:0] p_sc = s_s * c_s;

    wire signed [47:0] s_ext   = {{32{s_s[15]}}, s_s};
    wire signed [47:0] c_ext   = {{32{c_s[15]}}, c_s};
    wire signed [47:0] pss_ext = {{16{p_ss[31]}}, p_ss};
    wire signed [47:0] pcc_ext = {{16{p_cc[31]}}, p_cc};
    wire signed [47:0] psc_ext = {{16{p_sc[31]}}, p_sc};

    wire [15:0] win_n = (win_cycles == 16'd0) ? 16'd1 : win_cycles;

    // ==================================================================
    // 2) 共用串行除法器：48 位无符号 / 32 位无符号 -> 48 位商
    //    恢复余数法，48 拍；den = 0 时商饱和为全 1。
    // ==================================================================
    reg        dv_go;
    reg [47:0] dv_num;
    reg [31:0] dv_den;
    reg [47:0] dv_quot;
    reg        dv_rdy;

    reg [47:0] dv_n, dv_q, dv_rem, dv_shift;
    reg [31:0] dv_d;
    reg [6:0]  dv_cnt;
    reg        dv_busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            dv_busy <= 1'b0;
            dv_rdy  <= 1'b0;
            dv_cnt  <= 7'd0;
            dv_n    <= 48'd0;
            dv_q    <= 48'd0;
            dv_rem  <= 48'd0;
            dv_d    <= 32'd0;
            dv_quot <= 48'd0;
        end else begin
            dv_rdy <= 1'b0;
            if (!dv_busy) begin
                if (dv_go) begin
                    if (dv_den == 32'd0) begin
                        dv_quot <= 48'hFFFFFFFFFFFF;   // 除零 -> 饱和
                        dv_rdy  <= 1'b1;
                    end else begin
                        dv_busy <= 1'b1;
                        dv_n    <= dv_num;
                        dv_d    <= dv_den;
                        dv_q    <= 48'd0;
                        dv_rem  <= 48'd0;
                        dv_cnt  <= 7'd48;
                    end
                end
            end else begin
                dv_shift = {dv_rem[46:0], dv_n[47]};
                if (dv_shift >= {16'd0, dv_d}) begin
                    dv_rem <= dv_shift - {16'd0, dv_d};
                    dv_q   <= {dv_q[46:0], 1'b1};
                end else begin
                    dv_rem <= dv_shift;
                    dv_q   <= {dv_q[46:0], 1'b0};
                end
                dv_n <= {dv_n[46:0], 1'b0};
                if (dv_cnt == 7'd1) begin
                    dv_busy <= 1'b0;
                    dv_rdy  <= 1'b1;
                    dv_quot <= {dv_q[46:0],
                                (dv_shift >= {16'd0, dv_d}) ? 1'b1 : 1'b0};
                    dv_cnt  <= 7'd0;
                end else begin
                    dv_cnt <= dv_cnt - 7'd1;
                end
            end
        end
    end

    // ==================================================================
    // 3) 共用串行开方器：32 位无符号 -> 16 位无符号 floor(sqrt(x))
    //    逐位试根法(restoring digit-by-digit)，16 拍。
    // ==================================================================
    reg        sq_go;
    reg [31:0] sq_in;
    reg [15:0] sq_out;
    reg        sq_rdy;

    reg [31:0] sq_x;
    reg [19:0] sq_rem, sq_rem_new;
    reg [16:0] sq_root, sq_trial;
    reg [3:0]  sq_i;
    reg        sq_busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            sq_busy <= 1'b0;
            sq_rdy  <= 1'b0;
            sq_x    <= 32'd0;
            sq_rem  <= 20'd0;
            sq_root <= 17'd0;
            sq_i    <= 4'd0;
            sq_out  <= 16'd0;
        end else begin
            sq_rdy <= 1'b0;
            if (!sq_busy) begin
                if (sq_go) begin
                    sq_busy <= 1'b1;
                    sq_x    <= sq_in;
                    sq_rem  <= 20'd0;
                    sq_root <= 17'd0;
                    sq_i    <= 4'd15;
                end
            end else begin
                // 逐位试根(restoring digit-by-digit)：
                //   rem' = 4*rem + 输入的下 2 位
                //   rem' >= 4*root+1 ? -> d=1, rem = rem'-(4*root+1), root = 2*root+1
                //                        d=0, rem = rem',               root = 2*root
                // 试根前 root 恒 < 2^15，故 4*root+1 用 17 位即可(丢掉恒 0 的高位)。
                // 该算法与 model/calib_rtl_model.py::isqrt_u32 逐位一致，
                // 已用 20000 组随机数 + 边界值对比 math.isqrt 全部通过。
                sq_rem_new = {sq_rem[17:0], 2'b00} | {18'd0, sq_x[(sq_i * 2) +: 2]};
                sq_trial   = {sq_root[14:0], 2'b01};            // 4*root + 1
                if (sq_rem_new >= {3'd0, sq_trial}) begin
                    sq_rem  <= sq_rem_new - {3'd0, sq_trial};
                    sq_root <= {sq_root[15:0], 1'b1};           // 2*root + 1
                    if (sq_i == 4'd0) sq_out <= {sq_root[15:0], 1'b1};
                end else begin
                    sq_rem  <= sq_rem_new;
                    sq_root <= {sq_root[15:0], 1'b0};           // 2*root
                    if (sq_i == 4'd0) sq_out <= {sq_root[15:0], 1'b0};
                end
                if (sq_i == 4'd0) begin
                    sq_busy <= 1'b0;
                    sq_rdy  <= 1'b1;
                end else begin
                    sq_i <= sq_i - 4'd1;
                end
            end
        end
    end

    // ==================================================================
    // 4) 中间量
    // ==================================================================
    reg signed [15:0] o_s, o_c;                 // 一阶矩 = 直流偏置 (Q1.15)
    reg [31:0] mean_sq_s, mean_sq_c;            // S3/N, S4/N (Q2.30)
    reg [31:0] sd_mean_mag;                     // |S5/N| (Q2.30)
    reg        sd_mean_neg;
    reg [15:0] a_s, a_c;                        // sqrt(2*ms2) (Q1.15)
    reg [15:0] sin_dp_mag, cos_dp;              // Q1.15（sin 限幅到 ±0.5）
    reg [15:0] phase_k_mag;                     // |phase_k| (Q1.15)
    reg [31:0] tg_s, tg_c;                      // 未粗调的 Q1.15 增益

    wire signed [31:0] o_s_sq  = o_s * o_s;     // Q2.30，恒 >= 0
    wire signed [31:0] o_c_sq  = o_c * o_c;
    wire signed [31:0] oc_prod = o_s * o_c;     // Q2.30，可正可负

    wire [31:0] ms2_s = (mean_sq_s >= o_s_sq[31:0]) ? (mean_sq_s - o_s_sq[31:0]) : 32'd0;
    wire [31:0] ms2_c = (mean_sq_c >= o_c_sq[31:0]) ? (mean_sq_c - o_c_sq[31:0]) : 32'd0;
    wire [31:0] dbl_ms2_s = {ms2_s[30:0], 1'b0};    // 2*ms2 (<= 2^31, 无符号)
    wire [31:0] dbl_ms2_c = {ms2_c[30:0], 1'b0};
    wire [31:0] num_2ms_s = (dbl_ms2_s < 32'd2) ? 32'd2 : dbl_ms2_s;  // 与模型 max(2.0,·) 一致
    wire [31:0] num_2ms_c = (dbl_ms2_c < 32'd2) ? 32'd2 : dbl_ms2_c;

    wire [31:0] a_s32  = {16'd0, a_s};
    wire [31:0] a_c32  = {16'd0, a_c};
    wire [31:0] a_ssq  = a_s32 * a_s32;                  // <= 2^31 (无符号 32 位)
    wire [31:0] a_sac  = a_s32 * a_c32;                  // <= 2^30
    wire [31:0] a_ccos = a_c32 * {16'd0, cos_dp};        // <= 2^30
    wire [31:0] sin_dp_sq2 = {16'd0, sin_dp_mag} * {16'd0, sin_dp_mag}; // <= 2^28
    wire [31:0] cos_dp_in  = TWO_POW_30 - sin_dp_sq2;    // 2^30 - sin² >= 2^30-2^28

    // sd = mean(s1*c1) = ±|S5/N| - O_s*O_c   （33 位有符号，防溢出）
    wire signed [32:0] sd_mag_s  = $signed({1'b0, sd_mean_mag});
    wire signed [32:0] oc_prod_s = $signed({oc_prod[31], oc_prod});
    wire signed [32:0] sd_wide   = sd_mean_neg ? ((-sd_mag_s) - oc_prod_s)
                                               : (sd_mag_s - oc_prod_s);
    // 饱和到 32 位有符号（|sd| 理论 <= 2^31，极端情况下防回绕）
    wire signed [31:0] sd_w      = (sd_wide >  33'sd2147483647) ? 32'sh7FFFFFFF :
                                   (sd_wide < -33'sd2147483648) ? 32'sh80000000 :
                                                                  sd_wide[31:0];
    wire               sd_neg    = sd_w[31];
    wire [47:0] sd_abs48   = sd_neg ? {16'd0, (~sd_w + 32'd1)} : {16'd0, sd_w};
    // sin_dp 分子 = 2*|sd|<<15 = |sd|<<16 ；phase_k 分子 = 2*32768*|sd| = |sd|<<16
    // 二者数值相同，仅分母不同（A_s*A_c vs A_s²），故共用一个 48 位分子。
    wire [47:0] sdp_num = sd_abs48 << 16;
    wire signed [15:0] phase_k_s = sd_neg ? (-$signed(phase_k_mag))
                                          : ($signed(phase_k_mag));

    // 有符号 48 位幅值（S1/S2/S5 为有符号累加器）
    reg  [47:0] s1_abs, s2_abs, s5_abs;
    reg         s1_neg, s2_neg, s5_neg;
    always @(*) begin
        s1_neg = S1[47];
        s1_abs = S1[47] ? (~S1 + 48'd1) : S1;
        s2_neg = S2[47];
        s2_abs = S2[47] ? (~S2 + 48'd1) : S2;
        s5_neg = S5[47];
        s5_abs = S5[47] ? (~S5 + 48'd1) : S5;
    end

    // 最终增益（移位后可读，也用于写回）
    wire [31:0] gain_s_sh = tg_s >> res_shift_s;
    wire [31:0] gain_c_sh = tg_c >> res_shift_c;
    wire [15:0] gain_s_fin = (gain_s_sh > 32'd65535) ? 16'hFFFF : gain_s_sh[15:0];
    wire [15:0] gain_c_fin = (gain_c_sh > 32'd65535) ? 16'hFFFF : gain_c_sh[15:0];

    // ==================================================================
    // 5) 主状态机
    // ==================================================================
    reg [3:0]  state, sub;
    reg        start_d;
    reg        finish_t;
    reg [17:0] n_after_t;

    task div_issue;
        input [47:0] num;
        input [31:0] den;
        begin
            dv_num <= num;
            dv_den <= den;
            dv_go  <= 1'b1;
        end
    endtask

    task sqrt_issue;
        input [31:0] x;
        begin
            sq_in <= x;
            sq_go <= 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; sub <= 4'd0;
            busy <= 1'b0; done <= 1'b0; truncated <= 1'b0;
            retry_cnt <= 3'd0; win_bad <= 1'b0;
            int_min <= 18'd0; int_max <= 18'd0; int_seen <= 1'b0;
            dbg_int_min <= 18'd0; dbg_int_max <= 18'd0;
            dbg_nsamp_cls <= 18'd0; dbg_wcnt_cls <= 16'd0;
            S1 <= 48'sd0; S2 <= 48'sd0; S3 <= 48'sd0; S4 <= 48'sd0; S5 <= 48'sd0;
            nsamp <= 18'd0; wcnt <= 16'd0; n_win <= 32'd0; nsamp_prev <= 18'd0;
            o_s <= 16'sd0; o_c <= 16'sd0;
            mean_sq_s <= 32'd0; mean_sq_c <= 32'd0;
            sd_mean_mag <= 32'd0; sd_mean_neg <= 1'b0;
            a_s <= 16'd1; a_c <= 16'd1;
            sin_dp_mag <= 16'd0; cos_dp <= 16'd1;
            phase_k_mag <= 16'd0; tg_s <= 32'd0; tg_c <= 32'd0;
            res_ofs_s <= 16'sd0; res_ofs_c <= 16'sd0;
            res_gain_s <= 16'd0; res_gain_c <= 16'd0;
            res_phase_k <= 16'sd0; res_shift_s <= 2'd0; res_shift_c <= 2'd0;
            calib_we <= 1'b0; calib_addr <= 16'd0; calib_wdata <= 8'd0;
            state_dbg <= S_IDLE;
            dv_go <= 1'b0; sq_go <= 1'b0;
            start_d <= 1'b0;
        end else begin
            dv_go     <= 1'b0;      // 脉冲类信号默认拉低
            sq_go     <= 1'b0;
            calib_we  <= 1'b0;
            start_d   <= start;
            state_dbg <= state;

            case (state)
            // ----------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (start & ~start_d) begin
                    busy      <= 1'b1;
                    done      <= 1'b0;
                    truncated <= 1'b0;
                    retry_cnt <= 3'd0;      // ★ 每次主机启动都从"一次成功"重新计数
                    win_bad   <= 1'b0;
                    int_min   <= 18'd0; int_max <= 18'd0; int_seen <= 1'b0;
                    dbg_int_min <= 18'd0; dbg_int_max <= 18'd0;
                    dbg_nsamp_cls <= 18'd0; dbg_wcnt_cls <= 16'd0;
                    S1 <= 48'sd0; S2 <= 48'sd0; S3 <= 48'sd0;
                    S4 <= 48'sd0; S5 <= 48'sd0;
                    nsamp <= 18'd0; wcnt <= 16'd0;
                    nsamp_prev <= 18'd0;   // ★ 整周期收尾预测的基准（复位为 0 = 尚未测过上周期）
                    armed   <= 1'b0;      // ★ 等第一个周期边界再开始累加（幂等标定）
                    arm_tmo <= 26'd0;
                    state <= S_ACCUM; sub <= 4'd0;
                end
            end
            // ----------------------------------------------------------
            S_ACCUM: begin
                finish_t  = 1'b0;
                n_after_t = nsamp;
                //  ★ 窗口边界修正（2026-10-10）：
                //   原实现为
                //       if (cycle_pulse) begin
                //           wcnt <= wcnt + 16'd1;
                //           if ((wcnt + 16'd1) >= win_n) finish_t = 1'b1;
                //       end
                //   它有两个后果：
                //   (a) 判据用的是"更新前的 wcnt + 1"，即第 (win_n-1) 个脉冲
                //       就把窗口关掉了 ⇒ win_cycles=N 实际只累加 N-1 个完整
                //       周期（实测 win_cycles=4、每周期 8 样本时 nsamp=24）；
                //       ★ 注意：2026-10-10 加入 armed 对齐之后，**同一个表达式
                //       语义变了**——arming 那一拍（第 0 个脉冲）不计数，于是
                //       `(wcnt+1) >= win_n` 正好在第 win_n 个**完整**周期结束时
                //       关门。这就是它现在又回到 `>=` 的原因（见下面 ★★ 段），
                //       不要只看这一条就把它改回 `>`。
                //   (b) 关门那一拍 `in_valid` 可能仍为高，该拍样本被
                //       finish 抢先结束，样本数再少 1 个（win_cycles=1 时
                //       win_n=1，首个脉冲即关门，nsamp=0，窗口长度为 0）。
                //   n_win=0 会让后续 O_s=S1/0 的除法进入"分母为 0 → 商饱和"
                //   分支（不挂死，但标定静默失效），属于真实缺陷。
                //   改为 if/else：关门那一拍的样本不计入。
                //   ★★ 2026-10-10 幂等标定（§1.18）再加一层：**先对齐到第一个输入周期
                //   边界再开始累加**。原实现从 start 那一拍就开始累加，窗口 =
                //   "一段起始残缺周期 + win_cycles 个整周期"，残缺段长度取决于触发时刻落在
                //   波形的哪个相位 ⇒ 同一路输入、同一套参数，两次一键标定解出的系数不同
                //   （实测 OFS_C 930→−17、PHASE_K 20→−41、GAIN_S 30324→29840），这是
                //   "标定不可重复"的第二个来源（第一个来源是累加的是**校正后**的信号，
                //   已在 enc_top.v 改成累加 s_dec/c_dec）。
                //   对齐之后窗口严格等于 win_cycles 个完整输入周期（nsamp = win_cycles*P），
                //   与触发相位无关 ⇒ 重复标定结果一致。关门判据随之回到
                //   (wcnt+1) >= win_n —— armed 之后第 win_n 个脉冲就是整周期结束。
                //   ★ 细节：**对齐那一拍的样本也计入**（它是新周期的第一个样本），
                //     但那一拍**不算**已完成的周期 —— 下面 `wcnt` 的自增都带 `armed`
                //     保护。两件事必须同时做对：只计入样本、不计数周期，窗口才是
                //     [周期边界, 第 win_n 个边界) 的 win_cycles 个整周期（nsamp = win_cycles*P）。
                //     实测踩过两次：丢掉对齐样本 ⇒ nsamp=16383；对齐拍多算一个周期
                //     ⇒ nsamp=16128（少一个整周期）。
                if (!armed) begin
                    // 等第一个周期边界
                    if (cycle_pulse) begin
                        armed   <= 1'b1;
                        wcnt    <= 16'd0;
                        arm_tmo <= 26'd0;
                    end else if (arm_tmo >= ARM_TMO_MAX) begin
                        // 输入不转/极慢：不挂死，置 truncated 并以空窗口收尾
                        finish_t  = 1'b1;
                        truncated <= 1'b1;
                    end else begin
                        arm_tmo <= arm_tmo + 26'd1;
                    end
                end
                // ---- 累加与关门（与对齐阶段分开写，好让"对齐那一拍"也能累加）----
                // ★★ 2026-10-10 整周期收尾：样本上限到达时**不再当拍关门**。
                //   原实现在 `n_after_t >= MAX_SAMP` 时立刻关门，窗口会停在半个输入
                //   周期上 ⇒ O_s/O_c 被残缺周期污染。1 kHz 时一个输入周期 = 12500 个
                //   样本，64 个周期需要 800000 个样本 ≫ MAX_SAMP(65536)，旧实现只走到
                //   5.24 个周期，实测把圆度从 0.34% 改坏到 3.09%（0x0502 bit3 置 1）。
                //   现在用"上一个周期的样本数"预测下一个周期是否还装得下（留 2 倍
                //   余量，容忍输入变慢），装不下就在**当前周期边界**关门 ⇒ 累加值
                //   始终是整数个周期的和，解无偏；只把窗口周期数减小并置 truncated
                //   让主机知道"被样本上限截短了"（结果仍然有效）。
                plast_t    = nsamp - nsamp_prev;
                nxt_est_t  = {14'd0, nsamp} + {plast_t, 1'b0};
                cap_stop_t = (nsamp_prev != 18'd0) && (nxt_est_t > MAX_SAMP);
                // ---- ★ 非整周期窗口检测：记录窗口内每个周期间隔的 min/max ----
                //   （脉冲间隔应为整数个输入周期；出现半周期时间隔只有一半）
                if (cycle_pulse && armed && !finish_t) begin
                    if (!int_seen) begin
                        int_seen <= 1'b1;
                        int_min  <= plast_t;
                        int_max  <= plast_t;
                    end else begin
                        if (plast_t < int_min) int_min <= plast_t;
                        if (plast_t > int_max) int_max <= plast_t;
                    end
                end
                if (!finish_t) begin
                if (armed && cycle_pulse && (((wcnt + 16'd1) >= win_n) || cap_stop_t)) begin
                    // 收尾这一拍的间隔也要参与判定（上面的寄存器更新要下一拍才生效）
                    lim_min_t = (!int_seen) ? plast_t
                                            : ((plast_t < int_min) ? plast_t : int_min);
                    lim_max_t = (!int_seen) ? plast_t
                                            : ((plast_t > int_max) ? plast_t : int_max);
                    //  ★ 阈值 1.25 倍（不是 1.5 倍）：抖动让"半周期错位"时，窗口里
                    //    会恰好多出一个半周期 ⇒ 只有**一个**间隔变成 3H（其余 2H），
                    //    即 max/min = 1.5；若用 `max > min*1.5` 的严格判据就正好漏检
                    //    （3H > 3H 为假）。正常窗口的间隔抖动只有 ±1~2 个样本（1 kHz
                    //    时 12500 样本/周期），1.25 倍余量绰绰有余。
                    win_bad_t = (lim_max_t > (lim_min_t + (lim_min_t >> 2)));
                    // ★ v6 诊断快照：无论本轮是"丢弃重来"还是"最终采用"，都把这一
                    //   窗口的间隔统计 / 样本数 / 周期数锁存下来（SPI 读 0x050A/0x050B/
                    //   0x050D/0x050C）⇒ 板上"间隔到底偏了多少"从"只能靠 ILA 撞"变成
                    //   一条 UART 读数。最后一次尝试的窗口即最终留下的诊断值。
                    dbg_int_min   <= lim_min_t;
                    dbg_int_max   <= lim_max_t;
                    dbg_nsamp_cls <= nsamp + 18'd1;
                    dbg_wcnt_cls  <= wcnt + 16'd1;
                    if (win_bad_t && (retry_cnt < MAX_RETRY)) begin
                        // ★★ 窗口非整周期（脉冲相位因 MSB 抖动跳了半个周期）⇒ 本轮
                        //    一阶矩必然有偏（实测 O_s 会错 ±1800…2300），直接丢弃重来。
                        retry_cnt <= retry_cnt + 3'd1;
                        S1 <= 48'sd0; S2 <= 48'sd0; S3 <= 48'sd0;
                        S4 <= 48'sd0; S5 <= 48'sd0;
                        nsamp <= 18'd0; wcnt <= 16'd0; nsamp_prev <= 18'd0;
                        int_seen <= 1'b0; int_min <= 18'd0; int_max <= 18'd0;
                        armed   <= 1'b0;   // 重新对齐到下一个周期边界
                        arm_tmo <= 26'd0;
                        n_after_t = 18'd0; // 防止下面的 MAX_SAMP 硬上限分支把本轮当成"已完成"
                    end else begin
                        finish_t = 1'b1;             // 第 win_n 个周期边界（或样本上限）关门
                        if (win_bad_t) begin
                            win_bad   <= 1'b1;       // 重试用尽仍有非整周期 ⇒ 如实上报
                            truncated <= 1'b1;
                        end
                        if (cap_stop_t && ((wcnt + 16'd1) < win_n)) truncated <= 1'b1;
                        wcnt <= wcnt + 16'd1;
                    end
                end else if (in_valid && (nsamp < MAX_SAMP)
                             && (armed || cycle_pulse)) begin
                    S1 <= S1 + s_ext;
                    S2 <= S2 + c_ext;
                    S3 <= S3 + pss_ext;
                    S4 <= S4 + pcc_ext;
                    S5 <= S5 + psc_ext;
                    nsamp     <= nsamp + 18'd1;
                    n_after_t = nsamp + 18'd1;
                    if (cycle_pulse && armed) begin
                        wcnt       <= wcnt + 16'd1;
                        nsamp_prev <= nsamp + 18'd1;  // 本拍样本已计入
                    end
                end else if (cycle_pulse && armed) begin
                    wcnt       <= wcnt + 16'd1;
                    nsamp_prev <= nsamp;              // 本拍样本未计入
                end
                end // if (!finish_t)  —— 累加与关门
                if (n_after_t >= MAX_SAMP) begin
                    finish_t  = 1'b1;
                    truncated <= 1'b1;
                end
                if (finish_t) begin
                    if (n_after_t == 18'd0) begin
                        state <= S_DONE;
                    end else begin
                        n_win <= {14'd0, n_after_t};
                        state <= S_OFFSET; sub <= 4'd0;
                    end
                end
            end
            // ----------------------------------------------------------
            // O_s = S1/N ; O_c = S2/N （向零截断 + 饱和）
            S_OFFSET: begin
                case (sub)
                4'd0: begin div_issue(s1_abs, n_win);   sub <= 4'd1; end
                4'd1: if (dv_rdy) begin
                    o_s <= (dv_quot[15:0] > 16'd32767) ? (s1_neg ? (-16'sd32767) : 16'sd32767)
                                                       : (s1_neg ? (-$signed(dv_quot[15:0]))
                                                                 :   $signed(dv_quot[15:0]));
                    sub <= 4'd2;
                end
                4'd2: begin div_issue(s2_abs, n_win);   sub <= 4'd3; end
                default: if (dv_rdy) begin
                    o_c <= (dv_quot[15:0] > 16'd32767) ? (s2_neg ? (-16'sd32767) : 16'sd32767)
                                                       : (s2_neg ? (-$signed(dv_quot[15:0]))
                                                                 :   $signed(dv_quot[15:0]));
                    state <= S_AMP; sub <= 4'd0;
                end
                endcase
            end
            // ----------------------------------------------------------
            // mean(s²)=S3/N ; mean(c²)=S4/N ; |mean(s·c)|=|S5|/N
            S_AMP: begin
                case (sub)
                4'd0: begin div_issue(S3, n_win);               sub <= 4'd1; end
                4'd1: if (dv_rdy) begin mean_sq_s <= dv_quot[31:0]; sub <= 4'd2; end
                4'd2: begin div_issue(S4, n_win);               sub <= 4'd3; end
                4'd3: if (dv_rdy) begin mean_sq_c <= dv_quot[31:0]; sub <= 4'd4; end
                4'd4: begin div_issue(s5_abs, n_win);           sub <= 4'd5; end
                default: if (dv_rdy) begin
                    sd_mean_mag <= dv_quot[31:0];
                    sd_mean_neg <= s5_neg;
                    state <= S_SQRT1; sub <= 4'd0;
                end
                endcase
            end
            // ----------------------------------------------------------
            // A_s = sqrt(2*ms2_s)   （注意 ms2 用的是本拍之前的 mean_sq/o_s）
            S_SQRT1: begin
                case (sub)
                4'd0: begin sqrt_issue(num_2ms_s);   sub <= 4'd1; end
                default: if (sq_rdy) begin
                    a_s <= (sq_out == 16'd0) ? 16'd1 : sq_out;
                    state <= S_SQRT2; sub <= 4'd0;
                end
                endcase
            end
            // ----------------------------------------------------------
            // A_c = sqrt(2*ms2_c)
            S_SQRT2: begin
                case (sub)
                4'd0: begin sqrt_issue(num_2ms_c);   sub <= 4'd1; end
                default: if (sq_rdy) begin
                    a_c <= (sq_out == 16'd0) ? 16'd1 : sq_out;
                    state <= S_PHASE; sub <= 4'd0;
                end
                endcase
            end
            // ----------------------------------------------------------
            // sin_dp = clamp((|sd|<<16)/(A_s*A_c), 0, 0.5)
            // cos_dp = sqrt(2^30 - sin_dp²)
            S_PHASE: begin
                case (sub)
                4'd0: begin div_issue(sdp_num, a_sac);   sub <= 4'd1; end
                4'd1: if (dv_rdy) begin
                    sin_dp_mag <= (dv_quot[15:0] > 16'd16384) ? 16'd16384 : dv_quot[15:0];
                    sub <= 4'd2;
                end
                4'd2: begin sqrt_issue(cos_dp_in);       sub <= 4'd3; end
                default: if (sq_rdy) begin
                    cos_dp <= (sq_out == 16'd0) ? 16'd1 : sq_out;
                    state <= S_GAIN; sub <= 4'd0;
                end
                endcase
            end
            // ----------------------------------------------------------
            // tg_s = NUM_GAIN_S/A_s ; tg_c = NUM_GAIN_C/(A_c*cos_dp)
            S_GAIN: begin
                case (sub)
                4'd0: begin div_issue(NUM_GAIN_S, a_s32);    sub <= 4'd1; end
                4'd1: if (dv_rdy) begin
                    tg_s <= (dv_quot[31:0] > 32'd1048575) ? 32'd1048575 : dv_quot[31:0];
                    sub <= 4'd2;
                end
                4'd2: begin div_issue(NUM_GAIN_C, a_ccos);   sub <= 4'd3; end
                default: if (dv_rdy) begin
                    tg_c <= (dv_quot[31:0] > 32'd1048575) ? 32'd1048575 : dv_quot[31:0];
                    state <= S_DIV; sub <= 4'd0;
                end
                endcase
            end
            // ----------------------------------------------------------
            // phase_k = 32768*2*sd/A_s² = (|sd|<<16)/A_s²
            S_DIV: begin
                case (sub)
                4'd0: begin div_issue(sdp_num, a_ssq);   sub <= 4'd1; end
                default: if (dv_rdy) begin
                    phase_k_mag <= (dv_quot[15:0] > 16'd32767) ? 16'd32767 : dv_quot[15:0];
                    state <= S_SHIFT; sub <= 4'd0;
                end
                endcase
            end
            // ----------------------------------------------------------
            // _coarse_shift(): 选 sh 使 tg/2^sh <= 1.999；gain = tg >> sh
            S_SHIFT: begin
                if (tg_s <= TG_SH0)      res_shift_s <= 2'd0;
                else if (tg_s <= TG_SH1) res_shift_s <= 2'd1;
                else if (tg_s <= TG_SH2) res_shift_s <= 2'd2;
                else                     res_shift_s <= 2'd3;

                if (tg_c <= TG_SH0)      res_shift_c <= 2'd0;
                else if (tg_c <= TG_SH1) res_shift_c <= 2'd1;
                else if (tg_c <= TG_SH2) res_shift_c <= 2'd2;
                else                     res_shift_c <= 2'd3;

                res_ofs_s   <= o_s;
                res_ofs_c   <= o_c;
                res_phase_k <= phase_k_s;
                state <= S_WRITE; sub <= 4'd0;
            end
            // ----------------------------------------------------------
            // 结果写回寄存器组（11 个字节，每拍 1 字节）
            S_WRITE: begin
                calib_we <= 1'b1;
                case (sub)
                4'd0:  begin calib_addr <= ADDR_OFS_S;
                             calib_wdata <= o_s[7:0];              end
                4'd1:  begin calib_addr <= ADDR_OFS_S + 16'd1;
                             calib_wdata <= o_s[15:8];             end
                4'd2:  begin calib_addr <= ADDR_OFS_C;
                             calib_wdata <= o_c[7:0];              end
                4'd3:  begin calib_addr <= ADDR_OFS_C + 16'd1;
                             calib_wdata <= o_c[15:8];             end
                4'd4:  begin calib_addr <= ADDR_GAIN_S;
                             calib_wdata <= gain_s_fin[7:0];       end
                4'd5:  begin calib_addr <= ADDR_GAIN_S + 16'd1;
                             calib_wdata <= gain_s_fin[15:8];      end
                4'd6:  begin calib_addr <= ADDR_GAIN_C;
                             calib_wdata <= gain_c_fin[7:0];       end
                4'd7:  begin calib_addr <= ADDR_GAIN_C + 16'd1;
                             calib_wdata <= gain_c_fin[15:8];      end
                4'd8:  begin calib_addr <= ADDR_PHASE_K;
                             calib_wdata <= phase_k_s[7:0];        end
                4'd9:  begin calib_addr <= ADDR_PHASE_K + 16'd1;
                             calib_wdata <= phase_k_s[15:8];       end
                4'd10: begin calib_addr <= ADDR_SHIFT;
                             calib_wdata <= {4'b0000, res_shift_c, res_shift_s}; end
                default: begin calib_we <= 1'b0; state <= S_DONE; sub <= 4'd0; end
                endcase
                if (sub != 4'd11) sub <= sub + 4'd1;
            end
            // ----------------------------------------------------------
            S_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                res_gain_s <= gain_s_fin;
                res_gain_c <= gain_c_fin;
                state <= S_IDLE;
            end
            // ----------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end

    // ==================================================================
    // H2_HOOK: 2 次谐波校正（未来工作，默认不实现）
    //   计划：额外累加 S6=Σ s·sin(2θ), S7=Σ c·cos(2θ)（θ 来自 CORDIC 角度），
    //   估计 h2_k = 2*(S6+S7)/N，写 cfg_h2_k(0x051B/0x051C)，
    //   由 sc_correct 执行 s -= (h2_k*s2_est)>>>15。
    //   需要 CORDIC 角度回绕脉冲做 2θ 查表，本版未实现（见头注释"未来工作"）。
    // ==================================================================

endmodule
