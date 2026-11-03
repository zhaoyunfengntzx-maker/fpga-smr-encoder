//=============================================================================
// pole_counter.v —— 多周期（极）计数与辨向（SPEC_interface_contract.md §1.7）
//-----------------------------------------------------------------------------
// 功能
//   用"跨零方向"而不是简单差分来判方向并计数，输出多周期计数 cycle_cnt、
//   融合位置 pos_full = {cycle_cnt, angle}、方向 dir 与正/负跨零脉冲。
//
// Latency（in_valid -> out_valid）= 2 clk
//   系统时钟 50 MHz（单时钟域，无 MMCM）-> 40 ns。
//
// 为什么必须用"跨零方向"而不是角度差分
//   角度是模 2^AW 的量：真正的差分在 0/2^AW 处会跳变 ±2^AW，必须额外判方向才
//   能区分"正跨零"和"负跨零"；而在跨零点附近角度抖动（噪声、量化）会让朴素
//   差分的符号反复翻转，直接累加就会**误计数**。本模块只在满足
//       上一拍 angle ∈ [2^AW - 2^(AW-3), 2^AW)  且  本拍 angle ∈ [0, 2^(AW-3))
//   时判为一次正跨零（+1 计数），反之为负跨零（-1 计数）；门限 2^(AW-3) = 45°，
//   与 专用细分 ASIC 的半周期扇区（mcs 同步位）思想一致。
//   一次真实跨零必须"从 >315° 走到 <45°"，中间抖动只要不满足这个"两端条件"
//   就不会计数，因此比朴素差分稳得多。
//   45° 窗口同时给出可测转速上限：50 MHz 采样下 45°/样点 = 360°/(8*20ns)
//   = 6.25 MHz 输入频率，远高于 同类专用方案规格的 700 kHz sin/cos 输入上限。
//
// glitch_guard（本模块相对 SPEC 端口表的**新增输入**，见文件尾"端口扩展说明"）
//   跨零被接受后，在其后的 glitch_guard 个 clk 内屏蔽后续跨零事件（既不计数、
//   也不输出脉冲，保持 cycle_cnt 与 wrap_pos/wrap_neg 严格一致），即对跨零脉冲
//   做"时间去抖"。
//   理由：跨零点两侧的噪声/量化抖动可能在一个很短的时间内制造出多次
//   "正跨零 + 负跨零"事件对；这些事件在计数上会成对抵消、但在脉冲输出上会
//   变成一串毛刺，干扰下游测速/中断逻辑。真实跨零之间的最小间隔由输入频率
//   决定：700 kHz 输入在 50 MHz 采样下一个完整周期 ≥71 个采样点，两次跨零
//   至少隔 71 拍，所以屏蔽 2~8 拍对真实运动没有任何影响。
//   代价（必须知道）：若在保护窗内真的发生了反向跨零（等价于输入频率
//   > 1/(guard*20ns) 的反转，已达 MHz 量级，远超 专用细分 ASIC 的 700 kHz 输入规格），
//   这一次计数会被丢弃。因此建议 glitch_guard = 0（关闭）或 2~8。
//   glitch_guard = 0 时行为与 SPEC 端口表完全一致（无屏蔽）。
//
// 其它约定
//   * 跨零判据只在**有效样本**之间做（不假设每拍都有新样本）：上一拍角度取
//     "上一个 in_valid 样点的角度"，因此抽取后的稀疏 valid 也能正确工作。
//   * clr_on_z：z_window 的上升沿且 clr_on_z=1 时清零 cycle_cnt。
//   * preset_en：预置 cycle_cnt = preset（预置优先级最高）。
//   * 优先级：preset_en > z 上升沿清零 > 跨零计数。
//   * dir：正跨零置 1，负跨零置 0，其余保持；复位后为 1（默认正转）。
//   * pos_full 与 cycle_cnt 同拍更新：pos_full = {cycle_cnt, angle}。
//
// 资源估计：~80 LUT / ~90 FF / 0 DSP
// 复位：同步、低有效。无 initial / #delay / inout / SystemVerilog 语法。
//=============================================================================
module pole_counter #(
    parameter integer AW     = 16,   // 角度位宽
    parameter integer CW     = 16,   // 多周期计数器位宽（传统方案 = 14，这里 16）
    parameter integer GUARDW = 4     // glitch_guard 端口位宽（0..2^GUARDW-1 拍）
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire        [AW-1:0] angle,      // 已滤波的周期内角度
    input  wire                in_valid,
    input  wire                z_window,    // Z 门控窗口有效（来自顶层）
    input  wire                clr_on_z,    // 1=Z 上升沿清零多周期计数
    input  wire signed [CW-1:0] preset,     // 多周期计数预置值
    input  wire                preset_en,
    input  wire        [GUARDW-1:0] glitch_guard, // 【扩展端口】跨零后屏蔽计数的 clk 数
    output reg  signed [CW-1:0] cycle_cnt,  // 多周期（极）计数
    output reg  signed [CW+AW-1:0] pos_full,// {cycle_cnt, angle}
    output reg                  dir,        // 1=正转
    output reg                  wrap_pos,   // 正跨零脉冲（1 拍）
    output reg                  wrap_neg,   // 负跨零脉冲（1 拍）
    output reg                  out_valid
);

    //-------------------------------------------------------------------------
    // 常量：45° 门限
    //   TOP_TH = 2^AW - 2^(AW-3)   （315°）
    //   LOW_TH = 2^(AW-3) - 1      （< 45° 的上界，即 [0, 2^(AW-3)) ）
    //-------------------------------------------------------------------------
    localparam integer QW = AW - 3;
    localparam [AW-1:0] TOP_TH = (1 << AW) - (1 << QW);
    localparam [AW-1:0] LOW_TH = (1 << QW) - 1;

    //-------------------------------------------------------------------------
    // 第 1 级：打一拍（同时保留"上一个有效样本的角度"）
    //-------------------------------------------------------------------------
    // ★ 判据必须比较**紧邻的两个有效样点**（ang_s1 → ang_s0），比较结果在本拍
    //   组合有效，跨零脉冲/计数同为该拍寄存输出，总 Latency 仍为 2 级。
    reg [AW-1:0] ang_s0;      // 第 0 级：本拍输入角度（当前样点）
    reg [AW-1:0] ang_s1;      // 第 1 级：上一个样点角度（前一样点）
    reg          vld_d1;      // 与 ang_s1 同拍的上一样点有效标志
    reg          have_prev;   // ang_s1 是否已经存在（复位后第一个样点不算跨零）
    reg [GUARDW-1:0] guard_cnt;
    reg          z_d1;
    reg          z_clr_pend;  // Z 清零请求挂起（等下一个有效样点执行）

    wire guard_act = (guard_cnt != {GUARDW{1'b0}});
    wire z_rise    = z_window & (~z_d1);

    // 样点间的一步跨角（模 2^AW），以及"窗口内"的差分对两个窗口都对称：
    //   正跨零：prev∈[315,360) → cur∈[0,45)   ⇒ step_prev = 315°, step_cur = 45°
    //   负跨零：prev∈[0,45)   → cur∈[315,360) ⇒ step_prev = 315°, step_cur = 45°
    // 即两个方向都只需"两端各自落在自己的窗口里"，判据完全对称。
    //
    // ★ 为什么原来的 (prev>=TOP & cur<=LOW) / (cur>=TOP & prev<=LOW) 不对称：
    //   以负跨零 0° → 350° 为例，(cur>=315°)=真 但 (prev<=45°) 只在 prev 恰好在
    //   窗口内时成立；一旦样点已经把 prev 推到 45° 以上（如 prev=45.0°、prev=90°），
    //   第二个条件失效，真实跨零被漏掉。旧实现把 prev_ang 的更新与 ang_d1 放在
    //   同一拍，prev_ang 实际比 ang_d1 早了一整拍，使漏检更严重：反转扫描一圈
    //   都检测不到。现改为对称判据后，任何"从 >315° 走到 <45°"（或反向）都成立。
    wire [AW-1:0]     step_fwd = ang_s1 - ang_s0;        // +方向步长（模 2^AW）
    wire [AW-1:0]     step_bwd = ang_s0 - ang_s1;        // −方向步长（模 2^AW）
    localparam [31:0] STEP_MIN = (32'd1 << AW) - (32'd1 << (AW - 2));      // 270°
    // ★ 这里**故意不定义** step_small_f / step_small_b（≤90° 的"小跳变"）：
    //   它们在本模块里没有任何合法用途，只作反面教材存在于注释中 ——
    //   因为 step_bwd = 2^AW − step_fwd 恒成立，若把负跨零判据写成 step_small_b，
    //   它会与正跨零条件恒等，一次正跨零会同时报出两个方向、cycle_cnt 原地抵消。
    //   （历史上确实这么写错过，故留此说明；见 sim/tb_pole_counter.v 的反转扫描用例。）
    wire step_big_f   = (step_fwd >= STEP_MIN);          // 大正跳变（≥270°）
    wire step_big_b   = (step_bwd >= STEP_MIN);          // 大负跳变（≥270°）

    wire pair_valid = have_prev & vld_d1;                // 相邻两样点均已存在且有效
    wire in_top     = (ang_s0 >= TOP_TH) | (ang_s1 >= TOP_TH);
    wire in_low     = (ang_s0 <= LOW_TH) | (ang_s1 <= LOW_TH);
    wire spans_zero = in_top & in_low;                   // 两端分处零度两侧

    // 跨零原始判据（组合逻辑）。spans_zero 已保证两端分处零度两侧，此时
    // step_big_f 等价于"上一拍 ∈ [315,360) 且本拍 ∈ [0,45)"（正跨零），
    // step_big_b 等价于"上一拍 ∈ [0,45) 且本拍 ∈ [315,360)"（负跨零），
    // 与文件头第 15-16 行的判据一一对应，两个方向互斥。
    // 注意：负跨零必须用大负跳变 step_big_b —— 若误写成小负跳变 step_small_b，
    // 因 step_bwd = 2^AW - step_fwd 会与正跨零条件恒等，一次正跨零会同时报两个方向。
    //=========================================================================
    // v70 修复：增量展开计数（取代"单步 ≥270°"的跨零判据）
    //   原判据要求相邻有效样点角度跳变 ≥270°（step_big_f/b + spans_zero），
    //   只在**欠采样/混叠**输入下成立。本板 loop_filter 以 12.5 MHz 更新
    //   （rtl/enc_top.v 的 cordic_valid），而转台电信号 25.27 kHz
    //   ⇒ 每电周期约 495 个样点、相邻样点步进仅 ~0.73°，跨零永不触发，
    //   cycle_cnt 恒 0 ⇒ mech_angle/Z/UVW/RPM/多圈计数全部失效。
    //   现改为把相邻样点差分累加（有符号），累加量跨过 ±2^AW 即计一圈，
    //   任何过采样比都能正确计数；反转时累加量反向，两方向互斥。
    //   ★ step_s 必须先做**模 2^AW 无符号差**，再把差值当有符号数：
    //     angle 是 0..2^AW-1 的无符号相位，若先把 ang_s0/ang_s1 各自符号扩展再相减，
    //     相位越过 2^(AW-1)（本机 32768）时会被误判成负跳变（实测 step=-65403），
    //     累加器每半周被扣掉 2^AW，净累加恒 0 ⇒ cycle_cnt 仍然恒 0。
    //   差值的符号扩展只对**差值本身**做（过采样时它就是真实小步长）；
    //   若未来又接欠采样源（单步 >180°），会被解释成反向小步，需再议。
    //=========================================================================
    localparam signed [AW+1:0] TWO_PI = (1 << AW);       // 2^AW（一整周）
    reg  signed [AW+1:0] phase_acc;                      // 展开累加器（±2^AW 内）
    wire [AW-1:0]        diff_u   = ang_s0 - ang_s1;    // 模 2^AW 无符号差
    wire signed [AW+1:0] step_s   = {{2{diff_u[AW-1]}}, diff_u};
    wire signed [AW+1:0] acc_nxt  = phase_acc + step_s;
    wire                 acc_pos  = pair_valid & (acc_nxt >=  TWO_PI);
    wire                 acc_neg  = pair_valid & (acc_nxt <= -TWO_PI);
    wire signed [AW+1:0] acc_wrap = acc_pos ? (acc_nxt - TWO_PI) :
                                    acc_neg ? (acc_nxt + TWO_PI) : acc_nxt;

    wire wrap_p_raw = acc_pos;
    wire wrap_n_raw = acc_neg;
    // 保护窗内屏蔽
    wire wrap_p_ev  = vld_d1 & wrap_p_raw & (~guard_act);
    wire wrap_n_ev  = vld_d1 & wrap_n_raw & (~guard_act);
    wire wrap_any   = wrap_p_ev | wrap_n_ev;

    //-------------------------------------------------------------------------
    // 第 2 级：计数 / 预置 / 清零，输出全部在本拍寄存（总 Latency = 2）
    //   优先级：preset_en > Z 上升沿清零 > 跨零计数
    //   Z 清零事件若落在非有效样点上，先挂起（z_clr_pend），在下一个有效样点
    //   执行，保证 cycle_cnt 与 pos_full 始终是同一拍的一对。
    //-------------------------------------------------------------------------
    wire signed [CW-1:0] cnt_inc = cycle_cnt + {{(CW-1){1'b0}}, 1'b1};
    wire signed [CW-1:0] cnt_dec = cycle_cnt - {{(CW-1){1'b0}}, 1'b1};
    wire signed [CW-1:0] cnt_wrap = wrap_p_ev ? cnt_inc :
                                    (wrap_n_ev ? cnt_dec : cycle_cnt);

    wire z_clr_req   = z_rise & clr_on_z;
    wire z_clr_apply = vld_d1 & (z_clr_pend | z_clr_req);
    wire do_upd      = vld_d1 | preset_en;

    wire signed [CW-1:0] cnt_nxt = preset_en     ? preset :
                                   z_clr_apply    ? {CW{1'b0}} : cnt_wrap;
    // ★ 用第 0 级角度 ang_s0：本拍组合判出的跨零由 ang_s0（= 本拍 angle）触发，
    //   cnt_nxt 与 pos_nxt 同拍寄存；若配 ang_s1，则位置低位比计数慢一个样点，
    //   与文件头第 8 行（Latency = 2 clk）和第 44 行（pos_full = {cycle_cnt, angle}）不符。
    wire [CW+AW-1:0]     pos_nxt = {cnt_nxt, ang_s0};

    always @(posedge clk) begin
        if (!rst_n) begin
            ang_s0     <= {AW{1'b0}};
            ang_s1     <= {AW{1'b0}};
            vld_d1     <= 1'b0;
            have_prev  <= 1'b0;
            guard_cnt  <= {GUARDW{1'b0}};
            z_d1       <= 1'b0;
            z_clr_pend <= 1'b0;
            cycle_cnt  <= {CW{1'b0}};
            pos_full   <= {(CW+AW){1'b0}};
            phase_acc  <= {(AW+2){1'b0}};
            dir        <= 1'b1;
            wrap_pos   <= 1'b0;
            wrap_neg   <= 1'b0;
            out_valid  <= 1'b0;
        end else begin
            // ★ 判据用 ang_s1/ang_s0 比较**相邻两个有效样点**，比较结果在本拍
            //   组合有效；跨零脉冲与 cycle_cnt 都在本拍寄存，Latency 仍为 2 级。
            //   旧实现把 (prev_ang, ang_d1) 同拍推进，prev_ang 实际比 ang_d1 早了
            //   一整拍且判据本身不对称，导致反转扫描一个跨零都检测不到。
            ang_s0 <= angle;
            vld_d1 <= in_valid;      // 与 ang_s0 同拍：ang_s0 是第 1 级有效样点
            z_d1   <= z_window;

            // 跨零脉冲与计数同拍输出
            wrap_pos <= wrap_p_ev;
            wrap_neg <= wrap_n_ev;

            // 每个有效样点都刷新"上一个有效样点"基准（保护窗内也刷新，
            // 角度跟踪不断）。ang_s1 的更新与 ang_s0 级联同一拍推进，
            // 因此某一拍上 (ang_s1, ang_s0) 恰好是相邻的两个有效样点。
            if (vld_d1) begin
                ang_s1    <= ang_s0;
                have_prev <= 1'b1;
            end

            if (do_upd) begin
                cycle_cnt <= cnt_nxt;
                pos_full  <= pos_nxt;
            end

            // v70：展开累加器随有效样点推进；Z 清零时一并归零
            if (z_clr_apply)      phase_acc <= {(AW+2){1'b0}};
            else if (pair_valid)  phase_acc <= acc_wrap;

            if (wrap_p_ev)      dir <= 1'b1;
            else if (wrap_n_ev) dir <= 1'b0;

            // Z 清零请求的挂起/撤销
            if (z_clr_apply)            z_clr_pend <= 1'b0;
            else if (z_clr_req)         z_clr_pend <= 1'b1;

            // 跨零后装载保护窗；否则按 clk 递减
            if (wrap_any)               guard_cnt <= glitch_guard;
            else if (guard_act)         guard_cnt <= guard_cnt -
                                                    {{(GUARDW-1){1'b0}}, 1'b1};

            out_valid <= vld_d1;
        end
    end

endmodule

//=============================================================================
// 端口扩展说明（相对 SPEC §1.7 的端口表）
//   新增：input wire [GUARDW-1:0] glitch_guard     （默认参数 GUARDW=4）
//   位置：放在受约束的输入端口之后、输出端口之前；其余端口名/位宽/顺序与
//         SPEC §1.7 完全一致。顶层例化时把该输入接 4'd0 即得到与 SPEC 端口
//         表完全相同（无屏蔽）的行为。
//=============================================================================
