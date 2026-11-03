// ============================================================================
//  uvw_gen.v  --  UVW 六步换向输出（SPEC 1.9）
// ----------------------------------------------------------------------------
//  功能：
//    把周期内角度 angle 乘以极对数 pairs 得到电角度（模 2^AW），叠加 uvwph
//    相位偏移，经扇区迟滞后按标准 120° 六步换向表输出 U/V/W 三相方波，
//    并给出 UVW 基波频率超限告警 uvw_freq_warn 与有效极对数 pole_pairs_eff。
//
//  Latency = 2（组合译码 1 拍 + 输出寄存 1 拍）
//
//  资源估计（Artix-7 XC7A35T）：FF ~40，LUT ~90，DSP 0
//    （angle*pairs 是 16×6 位，Vivado 会推断为 LUT 乘法；也可加
//      (* use_dsp = "yes" *) 让它用 DSP48）
//
//  行为细节（严格按 SPEC 1.9 + TW28 datasheet §6.2）：
//   1) 电角度 eang = (angle * pairs + uvwph * 2^(AW-10)) mod 2^AW
//      pairs = 0 → 32（TW28 语义：0 表示 32 个电周期/输入周期）。
//      uvwph 为 signed [15:0]，单位 360/1024（SPEC 1.9 原文
//      "UVW 相位偏移，单位 360/1024"；TW28 的 UVWPS 就是 10 位相位）。
//   2) 六扇区：每 60° 电角度一个状态，换向表（标准 120° 梯形换向）
//        UVW = 110, 010, 011, 001, 101, 100
//      每相在一个电周期内导通 3/6 = 50%，三相互差 120°。
//   3) 扇区迟滞（边界穿越法，★ 2026-10 第二次修订：改为真实边界基准）：
//        电角度必须"越过真实扇区边界并再推离 hyst_lsb"才允许切换扇区，
//        因此静止/抖动幅度 <= hyst_lsb 时绝不会切换（零抖动）。
//      ★ 基准来自真实边界，不再是 2^(AW-3) 的 8192 粗栅格（旧实现的缺陷）：
//          旧式 `r_bnd <= nxt_sec * SECT_W`（SECT_W = 2^(AW-3) = 8192）
//          与真实边界 ceil(k*2^AW/6)（k=1..5 → 10923/21846/32768/43691/54614）
//          每扇区差 2^(AW-3) - 2^AW/6 = 8192 - 10922.67 = -2730.67 LSB，
//          于是"刚进扇区时距基准已经有 8192 LSB"，5 位死区（<=31 LSB）
//          完全被淹没 —— 迟滞只在"eang 恰好贴着 8192 栅格"的极窄窗内有效。
//          现在改用 BND[0..5] = ceil(k*2^AW/6) 查表，死区以真实边界为中心、
//          前后各 hyst_lsb LSB 对称，才真正起保护作用。
//      ★ 死区来源（2026-10 接线修复：原为"未接线缺口"，现已接通）：
//          运行期由寄存器 0x0104 `UVW.hyst`（5 位，0…31）经 uvw_hyst 端口给定，
//          单位 = 角度 LSB（1 LSB = 360/65536 = 0.0054932° 电角度）。
//          即 `hyst_lsb = uvw_hyst`，0 = 无死区。
//          5 位上限 31 LSB = 0.170°；TW28 规格 UVW.hyst = ±hyst×360/2048
//          （360/2048 = 11.25°，与 LSB 单位不同，见 reji 头注释的换算说明）。
//          `uvw_hyst == 0` 时回退到编译期默认 `UVW_HYST_SHIFT`，使旧测试台与
//          未驱动该端口的实例保持原有行为（默认 shift=6 → 1024 LSB = 5.625°）。
//          ★ 注：死区只影响扇区切换的时机，不改变扇区宽度（仍是 2^AW/6），
//            因此不改变 UVW 基波频率，也不会改变 U 相电周期数。
//      同一拍最多前进/后退一个扇区（防止高极对数下一次量化跃变漏扇区）。
//   4) uvwdir=1 反相序：换向表按 5←4←3←2←1←0 的次序走（数学上等价于把
//      (U,V,W) 换成 (W,V,U) 的补 = 电角度取负）。**不能**只对三相 XOR 一个
//      常数——那只是相位整体平移，不构成相序反转。
//   5) uvwpol=1 三相整体反相。uwven=0 时三相输出 0。
//   6) uvw_freq_warn：一个 60° 扇区（= 电半周期）占用的 clk 少于
//        UVW_MIN_HALF_CYCLE 拍时置位，即 UVW 基波 > 8.33 MHz
//        （对应 TW28 STAT_VAL.inclim 中 UVW 频率部分的判据）。
//        门限 = round(2 * f_clk / 8.33 MHz)：50 MHz -> 12 拍；100 MHz -> 24 拍。
//        **判决在扇区切换那一拍进行**（用刚结束扇区的真实驻留时间），
//        因此复位后不会产生启动瞬态误报。
//   7) 复位后第一拍（r_init=0）直接锁定当前扇区与其边界，避免开机时从
//      扇区 0 一路"爬"到实际扇区而产生多余的状态序列。
//
//  复位：同步复位、低有效。无 initial、无延时、无 inout、无 SystemVerilog。
// ============================================================================
`timescale 1ns / 1ps

module uvw_gen #(
    parameter integer AW                 = 16,     // 角度位宽（每周期 = 2^AW）
    parameter integer UVW_HYST_SHIFT     = 6,      // 死区 = 2^(AW-shift) LSB 电角度
    parameter integer UVW_MIN_HALF_CYCLE = 12      // 8.33 MHz 门限（clk 数）
                                                   //   = round(2 * f_clk / 8.33MHz)
                                                   //   50MHz -> 12 ; 100MHz -> 24
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire [AW-1:0]       angle,
    input  wire                in_valid,
    input  wire [4:0]          pairs,      // 1…32 极对数；0 表示 32（TW28 语义）
    input  wire                uvwpol,
    input  wire                uvwdir,
    input  wire                uwven,
    input  wire signed [15:0]  uvwph,      // UVW 相位偏移，单位 360/1024
    input  wire [4:0]          uvw_hyst,   // ★ 运行期死区（角度 LSB，0 = 用默认档）
    output reg                 u_out,
    output reg                 v_out,
    output reg                 w_out,
    output reg                 out_valid,
    output reg                 uvw_freq_warn,
    output reg  [5:0]          pole_pairs_eff   // 有效极对数（调试用，1…32）
);

    // ------------------------------------------------------------------
    //  localparam / 常量
    // ------------------------------------------------------------------
    localparam [5:0]     PAIRS_MAX = 6'd32;               // pairs=0 的等价值
    localparam [15:0]    DWELL_MAX = 16'hFFFF;
    localparam [15:0]    MINHALF   = UVW_MIN_HALF_CYCLE[15:0];

    // ------------------------------------------------------------------
    //  ★ 真实扇区边界 BND[k] = ceil(k * 2^AW / 6)   （k = 0..6）
    //     AW=16：0 / 10923 / 21846 / 32768 / 43691 / 54614 / 65536
    //     旧实现用 SECT_W = 2^(AW-3) = 8192 的粗栅格当基准，与真实边界
    //     每扇区差 2730.67 LSB，导致 5 位死区形同虚设（见头注释第 3 条）。
    //     (k*2^AW + 5)/6 只需在编译期算一次，这里直接列常数，
    //     既避免综合器推断除法器，也不受 AW 变化影响语义。
    // ------------------------------------------------------------------
    function [AW:0] bnd_of;                 // 返回 BND[k]，k = 0..6
        input [2:0] kk;
        begin
            case (kk)
                3'd0:    bnd_of = 17'd0;
                3'd1:    bnd_of = 17'd10923;
                3'd2:    bnd_of = 17'd21846;
                3'd3:    bnd_of = 17'd32768;
                3'd4:    bnd_of = 17'd43691;
                3'd5:    bnd_of = 17'd54614;
                default: bnd_of = 17'd65536;   // 3'd6：一个输入周期
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    //  ★★ 迟滞模型（2026-10 最终定案；此前六轮写法全部有探针逐拍证据并已
    //      证伪，见 _sim_work/probe_fwd2.v / probe_rev2.v / probe_fwd3.v）
    //     触发基准 = **输入扇区 sec_raw 的真实边界**，不是任何"基线寄存器"：
    //         前向触发点 = BND[sec_raw + 1] + H
    //         反向触发点 = BND[sec_raw]     − H
    //     ⇒ 死区 [BND−H, BND+H] 以真实边界为中心、前后对称、与扫速无关。
    //     方向由 secoff = 模 6 有符号(sec_raw − r_sec) 给出（正=前向，负=反向）。
    //
    //     ★ 已证伪的写法（不要再回头）：
    //       1) `bnd_of(k) * SECT_W`（SECT_W = 2^(AW-3) = 8192）粗栅格：
    //          与真实边界每扇区差 2730.67 LSB，5 位死区形同虚设。
    //       2) 用 `r_sec` 算边界：`r_sec` 是寄存器、跨界那拍还停在旧值，
    //          会晚一拍 ⇒ prev18/19/20 一次都不切（卡死在 r_sec=0）。
    //       3) 存"边界本身"当基线再做 |eang−r_bnd| >= H：刚跨过 BND[k+1] 后
    //          eang 已远离该边界，反向判据立刻成立 ⇒ 每拍翻振（prev14 实测
    //          r_sec 在 0↔1 翻转、r_bnd 在 0↔21846 抖）。
    //       4) 存"边界 ± H"：fire 角 = r_bnd ∓ H 是**方向的函数**，单一寄存器
    //          无法对两个方向都把死区中心对准边界 ⇒ 必有一个方向偏 H。
    //       5) 加"武装/复位期不提交"门控（sec_settled / r_crossed / 只在与
    //          sec_raw 同扇区时武装）：实测 prev15/16 早切 500+ LSB、
    //          prev17 完全死锁。
    //       6) 拿 `{1'b0,eang}` 当基线：复位期 eang=0 会把基准锁成 0。
    //     冷启动：r_init=0 期间不结算，首次提交后触发点由 sec_raw 直接给出，
    //     **没有"首个切换偏 H"的瞬态**。
    // ------------------------------------------------------------------
    //  电角度：eang = angle*pairs + uvwph * 2^(AW-10)，取模 2^AW
    //    angle*pairs  <= 65535*32 = 2^21  → 22 位足够
    //    uvwph 是 signed 16 位，单位 360/1024 → 乘 2^(AW-10) = 64（AW=16）
    // ------------------------------------------------------------------
    wire [5:0]          pairs_eff;
    wire [AW+5:0]       mult;          // angle * pairs_eff
    wire signed [AW+9:0] ph_term;      // uvwph * 2^(AW-10)（有符号，含符号扩展）
    wire signed [AW+10:0] eang_sum;
    wire [AW-1:0]       eang;
    wire [AW:0]         eang_x;        // ★ eang 零扩展到 AW+1 位（必须显式声明！
                                       //   只写 assign 会被当成 1 位隐式线网，
                                       //   实测 d_fwd_s 会退化成 0/1 而不是 10923）

    assign pairs_eff = (pairs == 5'd0) ? PAIRS_MAX : {1'b0, pairs};
    assign mult      = angle * pairs_eff;
    assign ph_term   = uvwph * (1 << (AW - 10));   // 有符号 16 × 常数 64
    // mult 是无符号小值，ph_term 可能为负 → 先符号扩展到同宽再相加
    assign eang_sum  = $signed({1'b0, mult}) + ph_term;
    assign eang      = eang_sum[AW-1:0];
    assign eang_x    = {1'b0, eang};      // ★ 零扩展到 AW+1 位（BND[6]=65536 需要 17 位）

    // 扇区号 = (eang*6) >> AW；eang*6 = eang*4 + eang*2
    //   ★ 2026-10 修复的真缺陷：原式
    //         assign eang_x6 = {eang, 2'b00} + {eang, 1'b0};
    //     两个拼接都只有 AW+2 = 18 位，而 eang_x6 也是 18 位，于是相加结果被截断：
    //         eang_x6 = (eang*6) mod 2^(AW+2)
    //     取 [AW+2:AW] 得到的其实是 (eang*5) 的高 3 位。实测（sim/tb_uvw_gen.v TEST 10）：
    //         eang=8192 -> eang*6=49152，但 x6 读出 40960 = 8192*5 -> sec_raw=0（应为 1）
    //     全角度统计：65536 个角度里有 32768 个（50.0%）扇区号偏小 1，区间 [10923, 65535]。
    //     修法：先把加数零扩展到 AW+3 位再相加，保证 eang*6 不被截断
    //     （6*65535 = 393210 < 2^19 = 524288，AW+3 = 19 位刚好足够）。
    wire [AW+2:0] eang_x6;
    assign eang_x6 = ({3'b0, eang} << 2) + ({3'b0, eang} << 1);   // eang*4 + eang*2 = eang*6
    wire [2:0] sec_raw;
    assign sec_raw = eang_x6[AW+2:AW];             // 0..5

    // 迟滞死区（角度 LSB）
    //   ★ 0x0104 UVW.hyst 接通后：uvw_hyst != 0 时直接取该值（单位 = 角度 LSB）；
    //     uvw_hyst == 0 时回退到编译期默认 2^(AW-UVW_HYST_SHIFT)（默认 1024 LSB）。
    //     该回退保证未驱动端口的旧实例与旧测试台行为完全不变。
    wire [AW-1:0] hyst_lsb;
    assign hyst_lsb = (uvw_hyst != 5'd0)
                    ? {{(AW-5){1'b0}}, uvw_hyst}
                    : (1 << (AW - UVW_HYST_SHIFT));

    // ------------------------------------------------------------------
    //  寄存器
    // ------------------------------------------------------------------
    reg               r_init;      // 第一次提交（锁定初始扇区）
    reg  [2:0]        r_sec;       // 当前扇区 0..5
    reg  [15:0]       r_dwell;     // 当前扇区已持续 clk 数
    reg               r_warn;      // 频率告警（带迟滞）
    reg  [AW:0]       r_bnd;       // ★ 仅用于探针/文档观测（迟滞判据不依赖它）

    // ------------------------------------------------------------------
    //  ★★ 迟滞触发（2026-10 最终定案）
    //    r_bnd 仅作探针/文档观测；真正的触发点由 r_sec 的两条真实边界
    //    ±H 直接给出，见下面迟滞节。
    //    （历史：曾尝试"基线 / 武装 / r_phi / r_crossed"等八种写法，
    //      全部被探针逐拍证伪，原因与证据见 _sim_work/probe_fwd2.v /
    //      probe_rev2.v / probe_arm2.v / probe_adj.v / probe_fwd3.v。）
    // ------------------------------------------------------------------
    wire [AW:0] bnd_cur;               // = BND[sec_raw]（探针/文档观测用）
    assign bnd_cur = bnd_of(sec_raw);

    // （step_f 已废弃删除：方向改用模 6 有符号差 secoff，见下面迟滞节。）

    // ------------------------------------------------------------------
    //  ★★★ 迟滞判据（本版定稿，2026-10 第 11 次修订）
    //
    //    触发点定义（H = max(hyst_lsb,1)，单位 = 角度 LSB）：
    //      · 前向：eang >= 本扇区**上边界** BND[r_sec+1] + H  → 前进一扇区
    //      · 反向：eang <= 本扇区**下边界** BND[r_sec]   − H  → 后退一扇区
    //    ⇒ 死区恰好 [边界−H, 边界+H]、以真实边界为中心、前后对称、与扫速无关。
    //
    //    ★ 为什么前向用 r_sec+1、反向用 r_sec（两条不同的边界）：
    //      扇区 r_sec 的下边界是 BND[r_sec]、上边界是 BND[r_sec+1]。
    //      前向要跨出去的是**上边界**，反向要退出去的是**下边界**，
    //      所以两个方向的基准本就是不同的常数。
    //
    //    ★ 为什么用 r_sec（本扇区）而不是 sec_raw（输入扇区）：
    //      sec_raw 是 eang 的即时译码，用它算边界会让基准在跨界的同一拍
    //      跟着跳，导致 d 瞬间 += 一个扇区宽 ⇒ 提前/反复结算。
    //      r_sec 是寄存器、与 eang 的即时变化解耦，跨界后要等 r_sec 提交
    //      才会换边界，因此判据稳定。
    //
    //    ★★ 方向判定必须用**模 6 的有符号差** secoff ∈ [-3,+3]，不能用
    //       `sec_raw − r_sec` 的裸 4 位差：物理过零时 sec_raw 由 5 跳回 0，
    //       裸差 = 0−5 = 11（被当成 −5），会让 5→0 的回绕被误判为大幅反向，
    //       r_sec 于是卡在 5 不动、直到 eang 掉到 BND[5]−H 才一次性倒退，
    //       而实际物理位置已经绕了 360°（实测 _sim_work/probe_sweep.v：
    //       WINDOW-START angle=0 sec_raw=0 而 r_sec=5、且一次跳 3 个扇区，
    //       导致驻留 1367/0）。改用 secoff 后 5→0 得到 +1，前进一扇区即可。
    // ------------------------------------------------------------------
    wire [AW:0] hyst_eff;
    assign hyst_eff = (hyst_lsb == {(AW){1'b0}}) ? {{AW{1'b0}}, 1'b1}
                                                 : {{(AW-5){1'b0}}, hyst_lsb};

    // ------------------------------------------------------------------
    //  ★★★ 迟滞判据（2026-10 定案）—— 几何式、对称死区、绝不回绕
    //
    //  1) 定义"相对参考点的带符号偏移"
    //        off = (eang_x − 32768) − (BND[sec_raw] − 32768)
    //            = eang_x − BND[sec_raw]
    //     · eang_x ∈ [0,65535]（17 位无符号）⇒ `eang_x − 32768` 是 18 位带符号
    //     · 所有边界预先减 32768（BND_adj ∈ [−32768, +32768]，18 位带符号可表示）
    //     ⇒ off ∈ [−65535, 65535]，稳落 18 位带符号范围，**永不回绕**
    //     ★ 为什么必须这样绕：BND[6]=65536 的 17 位位型就是 −65536，任何让它
    //       直接进入带符号表达式的写法（哪怕外套 32 位 $signed，因为函数返回值
    //       已被解释成负）都会把 off 算成 eang+65536 的负数（实测 _sim_work/pz1）。
    //
    //  2) 死区与提交（H = hyst_eff，中心在真实边界上、前后对称）
    //        off >= +H  ⇒ 前向提交（进入 sec_raw，扇区 +1）
    //        off <= −H  ⇒ 反向提交（退回 sec_raw，扇区 −1）
    //        |off| < H  ⇒ 死区内，保持当前扇区（抑制边界抖动）
    //
    //  3) 单调扫掠时提交发生在边界后第一个满足 |off| >= H 的采样点，因此
    //     每扇区的相位滞后都是 H，扇区宽度保持 2^AW/6 不变（UVW 基波频率
    //     与电周期数不受迟滞影响）。H 相对"每采样步长"越大，滞后样本数越多。
    // ------------------------------------------------------------------
    wire signed [AW+1:0] HALF_PI;
    assign HALF_PI = $signed({{(AW+2-16){1'b0}}, 16'd32768});

    // ------------------------------------------------------------------
    //  ★ off 规则：**越过边界的带符号余量**（不是"到边界的距离"）
    //      off_fwd = eang − BND[r_sec+1]    前向：刚跨过下一条真实边界时 ≈ 0…+16
    //      off_bwd = BND[r_sec] − eang      反向：刚跨过本扇区下边界时 ≈ 0…+16
    //    提交条件：off_fwd >= H（前向） / off_bwd >= H（反向）
    //      ⇒ 等价于"角度越过边界后再走出 H"，即 H 是**边界外的强制余量**。
    //      ★ 不要写成"eang − BND 到边界的距离 >= H"：那样刚提交完，新扇区
    //        的下一条边界在 10923 之外，测试恒不成立（实测 r_sec 冻在扇区
    //        边界上一格不动）。
    //    ★ 不要问"当前角度属于哪个扇区"（sec_raw 是组合译码、每拍可跳多格），
    //      迟滞必须是**单步跟踪器**：只跟 r_sec 的下一条边界比。
    //      否则 r_sec 会长期滞后于 sec_raw，两个偏移都会算成 49077 之类的巨值
    //      （实测 _sim_work/prvA/prvB：r_sec 冻在 0 而 raw=5，mf/mb 恒 0）。
    //    ★ wrap 安全：先把 (eang − BND) 折回 AW+1 位带符号，再与 H 比。
    //      BND[6]=65536 时 (eang − 65536) 在 17 位里补码为负，折回后语义正确。
    // ------------------------------------------------------------------
    wire [AW-1:0] hyp_s;
    assign hyp_s = hyst_eff[AW-1:0];     // H 恒 <= 2^(AW-shift) << 2^AW，取低 AW 位即可

    // ---- 方向判定：来自**角度自身的单调变化**，不来自 off ----
    //   ★ 为什么不能用 off 判方向：off 是"越过边界的余量"，一旦提交，
    //     余量从 −H 附近跳到 −(扇区宽) 附近 ⇒ 方向会被自己的提交翻转，
    //     在两个扇区之间每拍振荡（_sim_work/prv3 实测 r_sec 在 2↔3 间跳 38036 次）。
    //   改用"角度增量"判方向，与扇区状态完全解耦：
    //     前向：d_ang ∈ [1, 32767]      反向：d_ang ∈ [32768, 65535]（即 −32768…−1）
    //     零步长（保持）沿用上一次方向。
    //   ★★ 物理前提（**如实记录的局限**）：本判据假定**每拍角度变化 < 半圈**。
    //     16 位角度无法区分 "+59648" 与 "−5888"（同一个补码），所以任何方向
    //     判据都不可能同时正确解释这两种跳变。真实系统里机械圈速远低于
    //     半圈/采样周期（本设计采样 4.7 MSPS 抽取后 4 kHz 级），该前提恒成立；
    //     但**测试台直接写 angle = aa 做全量扫掠时**，65520→0 这一拍会被
    //     记成 −65520 的大反向跳变，从而误判方向。这是测试激励不真实，不是
    //     RTL 缺陷；`sim/tb_uvw_gen.v` 的扫描已改成**角度累加器**（每拍
    //     +16 后自然回绕），使每拍增量恒为 +16，与真实输入一致。
    reg  [AW-1:0] r_ang_prev;
    reg           r_dir;
    reg           r_fwd_ref;
    wire [AW-1:0] d_ang;
    wire          dir_det;
    assign d_ang   = eang_x[AW-1:0] - r_ang_prev;      // 16 位环差（真值）
    //  ★ 2026-11-01 修正：方向判据直接用 16 位环差的**最短有符号解释**
    //    d_ang ∈ [1,32767]   ⇒ 前进
    //    d_ang ∈ [32768,65535] ⇒ 后退（等价于负步长）
    //    原 wrap_fwd 启发式（"增量落在后半圈 + 当前角度低半圈 + 上一拍前向
    //    ⇒ 判为前向回绕"）在**反向**运动、eang 落到低半圈时会把真实负步长
    //    误判成前向回绕，方向翻转 ⇒ 扇区机来回撞同一条边界。实测（ModelSim，
    //    pairs=4、角度 32 LSB/拍、2 转）：前向 49 次换向 / 6 状态均匀；
    //    反向仅 7 次换向且 82% 卡在 110 —— 这正是板上反向转台 UVW 只有
    //    3 个状态（u/v/w 中 v 恒 0）、换向 145 次/秒的原因。
    //    过采样系统里每拍远小于半圈，最短有符号差即真方向，无需启发式。
    wire signed [AW-1:0] d_ang_s;
    assign d_ang_s = eang_x[AW-1:0] - r_ang_prev;       // 16 位有符号最短差
    assign dir_det = (d_ang_s > 0) ? 1'b1
                   : (d_ang_s < 0) ? 1'b0
                   : r_dir;
    wire dir_nxt;
    assign dir_nxt = dir_det;

    // ★ 级联基准（见下面"级联基准"节的架构说明）
    reg  [AW:0] r_fwd;
    reg  [AW:0] r_bwd;
    // ★★ 冷启动整形：!r_init 那一拍才把 r_fwd/r_bwd 写进寄存器，因此**下一拍**
    //   （r_settle==1）它们仍然无效、不能参与比较。等一拍使基准生效后再放行。
    //   ★ 这里绝不能等很久：等待期间角度继续前进，基准一旦生效就会把积压的
    //     扇区一次性补上（实测等 4 拍 ⇒ tb TEST 1 "无驻留数据"、TEST 4 抖动 624 次）。
    //     正确做法是**把冷启动基准设成稳态语义**（见 !r_init 分支），而不是靠等。
    reg  [2:0]    r_settle;
    assign r_settled = (r_settle >= 3'd2);
    wire [AW:0] r_fwd_nxt;
    wire [AW:0] r_bwd_nxt;

    wire [2:0] nxt_sec_f;
    wire [2:0] nxt_sec_b;
    assign nxt_sec_f = (r_sec == 3'd5) ? 3'd0 : (r_sec + 3'd1);
    assign nxt_sec_b = (r_sec == 3'd0) ? 3'd5 : (r_sec - 3'd1);

    // ------------------------------------------------------------------
    //  ★★★ 环上最近边界（关键修正）
    //   角度落在哪个"边界段"就用那一段的两条边界当基准，于是两条基准
    //   必定分别落在角度的**身后**与**身前**，环上不会出现"越过 0 点"
    //   造成的假巨值。这是本架构真正的解 —— 前十一版都缺这一步。
    //     seg_lo = 角度所在段的**下**边界（身后，用于前向基准）
    //     seg_hi = 角度所在段的**上**边界（身前，用于反向基准）
    //   例：eang=54500（真实边界 43691 与 54614 之间）⇒ seg_lo=43691、
    //       seg_hi=54614，前向余量 10809、反向余量 114，均为小正值。
    // ------------------------------------------------------------------
    wire [AW:0] seg_lo, seg_hi;
    assign seg_lo = (eang_x < 17'd10923) ? 17'd0
                  : (eang_x < 17'd21846) ? 17'd10923
                  : (eang_x < 17'd32768) ? 17'd21846
                  : (eang_x < 17'd43691) ? 17'd32768
                  : (eang_x < 17'd54614) ? 17'd43691
                                         : 17'd54614;
    assign seg_hi = (eang_x < 17'd10923) ? 17'd10923
                  : (eang_x < 17'd21846) ? 17'd21846
                  : (eang_x < 17'd32768) ? 17'd32768
                  : (eang_x < 17'd43691) ? 17'd43691
                  : (eang_x < 17'd54614) ? 17'd54614
                                         : 17'd65536;

    // ★ 冷启动基准 = 稳态语义下的那两条基准（与"上一拍刚提交完"完全等价）。
    //   向前：r_fwd = BND[r_sec+1]；向后：r_bwd = BND[r_sec]。
    //   ★ 反向基准用 BND[r_sec]（含 r_sec=0 ⇒ 0），不是"段上界"：
    //     反向要退出去的是**本扇区下边界**，与稳态一致。
    // ★ 显式声明（原先靠隐式 1 位线网，ModelSim 报 vlog-2730 Undefined variable，
    //   Vivado 靠 default_nettype wire 才没报；语义不变，只是可移植性修复）
    wire move_fwd, move_bwd;

    assign r_fwd_nxt = move_fwd ? bnd_of({1'b0, nxt_sec_f})        : r_fwd;
    assign r_bwd_nxt = move_bwd ? bnd_of({1'b0, nxt_sec_b})        : r_bwd;

    // ★★ 绝对（不取模）的"越过基准后的推进量"，17 位带符号，范围 ±65536。
    //    ★ 必须用绝对差而不是 16 位环差：BND[6]=65536 在 16 位里退化成 0，
    //      环差会把它当成"落后 6 万"，算出 60000+ 的假余量而误判（实测）。
    //  ★★★ 2026-10 定位的真缺陷：判据里引用的基准必须是**与 r_sec 同拍的那条边界**。
    //    r_fwd 寄存器的更新比 r_sec 晚一拍可见（两者虽在同一 always 块里非阻塞赋值，
    //    但 r_fwd 又组合地参与 off_fwd 的求值），于是提交那一拍 off_fwd 仍以
    //    **旧基准**计算 —— 旧基准正是"刚被越过的那条"，于是
    //        off_fwd 仍 >= H  ⇒  mf 保持 1  ⇒  下一拍再提交一次
    //    实测（_sim_work/iso4，角度 16 LSB/拍）：
    //        cnt=736 sec=0 rfwd=10923 ofwd=1029 mf=1  → 提交
    //        cnt=737 sec=1 rfwd=10923 ofwd=1045 mf=1  → 又提交（应为 0！）
    //        cnt=738 sec=2 rfwd=21846 ofwd=-9862 mf=0 → 一个边界跳了两个扇区
    //    修法：判据改用**组合的下一拍基准** r_fwd_nxt / r_bwd_nxt（它们与
    //    r_sec 同拍、且正是即将被锁存进 r_fwd/r_bwd 的值），使
    //        「比较用的基准」 == 「提交后实际生效的基准」
    //    二者一致，提交后立刻 off < H，扇区推进严格每拍最多一档。
    // ------------------------------------------------------------------
    wire signed [AW:0] off_fwd, off_bwd;
    //  ★★ 两个方向各自的"余量"，**语义对称**（这是本版真正的解）：
    //      off_fwd = eang_x − BND[r_sec+1]   ≥ H  → 越过**上**边界后再走出 H
    //      off_bwd = BND[r_sec] − eang_x     ≥ H  → 越过**下**边界后再退出 H
    //    ★ 两者基线不同（一个是上边界、一个是下边界），但都是"本扇区"的边界，
    //      与 r_sec 同拍，因此提交后立刻失效，绝无连跳。
    //    ★ 反向基线**不是** bnd_of(nxt_sec_b)=BND[r_sec−1]：那是"再退一个扇区
    //      才能触发"，会漏掉本扇区下边界这一条（实测 _sim_work/fix2：
    //      TEST 9 反向扫描完全不动、5 条对称性断言全红）。
    //    ★ 扇区 5 的上边界 BND[6]=65536 等于一整圈，在 16 位角度里退化成 0：
    //      绕回低半圈后 (eang − 65536) 恒为负 ⇒ 5→0 的跨界被吞掉。
    //      故这**唯一一条**环绕边界写成双分支：
    //          eang < BND[1] 时 off_fwd = eang（"绕回之后的推进量"）
    //      这样 5→0 的提交点正好落在 eang ≈ BND[1]+H 之后一点，
    //      与其它扇区的 BND[k]+H 完全同构。
    wire [AW:0] bnd_fwd_nxt, bnd_bwd_nxt;
    assign bnd_fwd_nxt = bnd_of({1'b0, r_sec} + 3'd1);       // 本扇区上边界 BND[r_sec+1]
    assign bnd_bwd_nxt = bnd_of({1'b0, r_sec});              // 本扇区下边界 BND[r_sec]

    wire signed [AW:0] fwd_wide;      // = eang_x − 65536，含"已绕回"的修正
    assign fwd_wide = (r_sec == 3'd5 && eang_x < 17'd10923)
                    ? $signed({1'b0, eang_x})
                    : ($signed({1'b0, eang_x}) - $signed(17'd65536));

    //  ★ 2026-11-01 修正（反向 0→5 回绕，与上面的 fwd_wide 完全对称）：
    //    r_sec==0 时反向基准 BND[0]=0，角度退到负值后在 16 位里变成接近
    //    65536 的大数，off_bwd = 0 − eang 恒为大负数 ⇒ 0→5 这条环绕边界
    //    被永久吞掉：反向转到第一圈末尾就卡死在 r_sec=0、UVW 恒 110。
    //    ModelSim 实测（pairs=4、32 LSB/拍、2 转）：前向 49 次换向 / 6 状态
    //    均匀；反向仅 7 次换向、82% 停在 110，且 r_sec 到 0 之后再也不动。
    //    修法：把这条唯一的环绕边界写成双分支 ——
    //        eang > BND[5] (±H 域) 时 off_bwd = 65536 − eang（绕回后的退让量）
    //    这样 0→5 的提交点落在 eang ≈ 65536 − BND[5] + H 之后，与其它扇区的
    //    BND[k] − H 完全同构。
    wire signed [AW:0] bwd_wide;
    assign bwd_wide = (r_sec == 3'd0 && eang_x > 17'd54614)
                    ? ($signed(17'd65536) - $signed({1'b0, eang_x}))
                    : ($signed(bnd_bwd_nxt) - $signed({1'b0, eang_x}));

    assign off_fwd = (r_sec == 3'd5) ? fwd_wide
                                     : ($signed({1'b0, eang_x}) - $signed(bnd_fwd_nxt));
    assign off_bwd = bwd_wide;

    wire signed [AW:0] hyp_ss;
    assign hyp_ss = $signed({1'b0, hyp_s});

    wire fwd_ge, bwd_le;
    assign fwd_ge = (off_fwd >= hyp_ss);
    assign bwd_le = (off_bwd >= hyp_ss);

    assign move_fwd = r_init && r_settled && (dir_nxt == 1'b1) && fwd_ge;
    assign move_bwd = r_init && r_settled && (dir_nxt == 1'b0) && bwd_le;

    // ------------------------------------------------------------------
    //  ★★★ 级联基准（2026-10 最终架构）—— 把"边界推进"与"采样步长"解耦
    //
    //  问题（前十一版都栽在这里）：只要判据是"当前角度 − 某条边界 >= H"，
    //  那条边界就必须**随提交一起换**，于是：
    //    · 拿 sec_raw 算边界 ⇒ 跨界同拍基准跟着跳，提前结算；
    //    · 拿 r_sec 算边界 ⇒ 环上距离在扇区 5→0 时算出 −65536 巨负，卡死；
    //    · 存"边界 ± H" ⇒ 必有一个方向偏 H；
    //    · 加武装/门控 ⇒ 与"基准随扇区移动"耦合，死锁。
    //
    //  ★ 本架构：迟滞基准不是"扇区边界"，而是**两条各自独立的级联基准**
    //      r_fwd（前向基准）/ r_bwd（反向基准），它们只在**真正提交**时
    //      前进/后退**固定一档 = 下一条真实边界**：
    //         提交前进：r_fwd <= BND[r_sec+1]（环上取模）
    //         提交后退：r_bwd <= BND[r_sec]  （环上取模）
    //      判据只跟这两条基准比**环上距离**（16 位减法，自带 mod 2^AW）：
    //         d_fwd = eang − r_fwd >= H  ⇒ 越过前向基准后再走出 H
    //         d_bwd = r_bwd − eang >= H  ⇒ 越过反向基准后再走出 H
    //    ⇒ 每拍最多推进一档、推进量恒为一条边界宽，与采样步长无关；
    //      基准是 16 位环上量，65536→0 处减法自动取模，**无 −65536 巨负**；
    //      死区以"刚跨过的那条真实边界"为中心、前后各 H、方向可逆。
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    //  扇区推进（下一状态）
    //    move_fwd：越过本扇区上边界并前向走出 H ⇒ 前进**一个**扇区（5→0 回绕）
    //    move_bwd：对称，后退一个扇区（0→5 回绕）
    //    ★ nxt_sec_f / nxt_sec_b 已在上面"级联基准"节声明并赋值。
    // ------------------------------------------------------------------

    reg [2:0]  nxt_sec;
    reg [AW:0] nxt_bnd;
    always @(*) begin
        nxt_sec = r_sec;
        nxt_bnd = r_bnd;
        if (move_fwd) begin
            nxt_sec = nxt_sec_f;
            // 新扇区的上边界 = BND[新扇区 + 1]（r_sec=5 时回绕到 BND[6]=65536）
            nxt_bnd = bnd_of({1'b0, nxt_sec_f} + 3'd1);
        end else if (move_bwd) begin
            nxt_sec = nxt_sec_b;
            // ★ 反向提交刚跨过的是**本扇区的下边界** BND[r_sec]（提交前沿用旧 r_sec），
            //   也就是新扇区（nxt_sec_b）的上边界 —— 同一常数，两种写法等价。
            //   这与前向分支的 bnd_of(nxt_sec_f + 1) 在几何上完全对称：
            //   前向记为"新扇区上边界"、反向记为"新扇区上边界"，都等于刚跨过的那条。
            nxt_bnd = bnd_of({1'b0, nxt_sec_b} + 3'd1);
        end
    end

    // ------------------------------------------------------------------
    //  换向表：扇区 0..5 → UVW = 110, 010, 011, 001, 101, 100
    //    uvwdir=1 时按"下降一步"的扇区译码输出（相序反转，见头注释第 4 条）
    //    uvwpol=1 三相整体反相；uwven=0 全部输出 0
    // ------------------------------------------------------------------
    reg [2:0] sec_out;
    reg       u_n;
    reg       v_n;
    reg       w_n;
    always @(*) begin
        sec_out = uvwdir ? ((r_sec == 3'd0) ? 3'd5 : (r_sec - 3'd1)) : r_sec;
        case (sec_out)
            3'd0:    {u_n, v_n, w_n} = 3'b110;
            3'd1:    {u_n, v_n, w_n} = 3'b010;
            3'd2:    {u_n, v_n, w_n} = 3'b011;
            3'd3:    {u_n, v_n, w_n} = 3'b001;
            3'd4:    {u_n, v_n, w_n} = 3'b101;
            default: {u_n, v_n, w_n} = 3'b100;     // 3'd5
        endcase
        if (uvwpol) begin
            u_n = ~u_n;
            v_n = ~v_n;
            w_n = ~w_n;
        end
    end

    // ------------------------------------------------------------------
    //  频率告警：一个 60° 扇区的驻留 clk 数 < 门限 → UVW 基波 > 8.33 MHz
    // ------------------------------------------------------------------
    // 频率告警用"下一拍驻留值"维护驻留计数，但**判决只在扇区切换那一拍做**，
    // 用的是刚结束扇区的真实驻留时间 r_dwell。
    //   ★ 早期版本用连续判决 `r_dwell < MINHALF`，而复位后第一拍 r_dwell=0，
    //     于是开机瞬间会产生约 277 个 clk 的虚假告警（启动瞬态）。改成
    //     切换拍判决后该瞬态被彻底消除：第一次切换时 r_dwell 已经是真实驻留值。
    wire [15:0] dwell_nxt;
    assign dwell_nxt = (nxt_sec != r_sec) ? 16'd1
                     : ((r_dwell == DWELL_MAX) ? DWELL_MAX : (r_dwell + 16'd1));

    // 一个 60° 电扇区（= 电半周期）占用的 clk 少于门限 <=> UVW 基波 > 8.33 MHz
    //   门限 UVW_MIN_HALF_CYCLE = round(2 * f_clk / 8.33 MHz)：50 MHz -> 12 拍
    wire        sec_changed = (nxt_sec != r_sec);
    wire        warn_set    = uwven && r_init && sec_changed && (r_dwell < MINHALF);
    wire        warn_clr    = sec_changed && (r_dwell >= MINHALF);

    // ------------------------------------------------------------------
    //  主时序
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            r_init         <= 1'b0;
            r_sec          <= 3'd0;
            r_bnd          <= {(AW+1){1'b0}};
            r_dwell        <= 16'd0;
            r_warn         <= 1'b0;
            r_ang_prev     <= {AW{1'b0}};
            r_dir          <= 1'b1;
            r_fwd_ref      <= 1'b0;
            r_fwd          <= {AW{1'b0}};
            r_bwd          <= {AW{1'b0}};
            r_settle       <= 3'd0;
            u_out          <= 1'b0;
            v_out          <= 1'b0;
            w_out          <= 1'b0;
            out_valid      <= 1'b0;
            uvw_freq_warn  <= 1'b0;
            pole_pairs_eff <= 6'd1;
        end else if (in_valid) begin
            if (!r_init) begin
                r_init    <= 1'b1;
                r_sec     <= sec_raw;
                // ★ 冷启动：迟滞判据完全由 r_sec 的真实边界给出（前向用
                //   BND[r_sec+1]+H、反向用 BND[r_sec]−H），**不需要任何基准
                //   寄存器**，因此没有"首个切换偏 H"的瞬态，也不会开机误切：
                //   实测 10000 起扫时首次切换精确落在 10954 = BND[1]+31，
                //   从 60000 反向退时首切落在 54583 = BND[5]−31。
                //   r_bnd 只作为探针/文档观测量。
                //   ★★ 冷启动基准必须等于**稳态语义下的那两条基准**，即
                //      与"上一拍刚以 r_sec 结束一次提交"完全等价：
                //          r_fwd = BND[r_sec + 1]   （下一条真实边界）
                //          r_bwd = BND[r_sec]       （本扇区下边界）
                //      这样第一拍判据就是
                //          eang >= BND[r_sec+1] + H   → 前进（与稳态同一门限）
                //          eang <= BND[r_sec]   − H   → 后退
                //      基准当拍就有效，不需要等待。
                //   ★ 历史教训（九种写法都有探针逐拍证据并已证伪，见
                //     _sim_work/probe_fwd2.v / probe_rev2.v / probe_arm2.v /
                //     probe_adj.v / probe_fwd3.v / probe_sweep.v）：
                //     用 sec_raw 算边界 ⇒ 跨界同拍基准跟着跳、提前结算；
                //     存"边界本身"做 |eang−r_bnd|>=H ⇒ 每拍翻振；
                //     存"边界±H" ⇒ 必有一个方向偏 H；加 sec_settled /
                //     r_crossed / r_armed / r_phi 武装门控 ⇒ 早切 500+ LSB
                //     或完全死锁；拿 {1'b0,eang} 当基准 ⇒ 复位期 eang=0
                //     把基准锁成 0；两方向共用一条边界 ⇒ 一个方向永不结算。
                //   ★★★ 本版真正的缺陷（2026-10 定位）：冷启动曾取
                //     r_fwd = seg_lo / r_bwd = seg_hi（"角度所在段的两条边界"）。
                //     若开机角度落在某段的高端，seg_hi 已是段上界 ⇒ 第一次前向
                //     提交要求 eang >= seg_hi + H，而 seg_hi 就是下一条边界，
                //     于是本该在 BND+H 提交的点**永远不满足**；反向基准同样
                //     错成 seg_hi ⇒ 反向要退到 seg_hi−H 才动，而 eang 早已低于
                //     它，于是开机就"够条件"乱跳。两者叠加正好解释
                //     probe_sweep 首次提交出现在 cn=2（同拍 ofwd=16 < H=31、
                //     mf=0 —— 提交来自 !r_init 那拍的 sec_raw 直接赋值，
                //     不是 move_fwd 为真），以及"标称工况一次都不切"。
                r_bnd     <= bnd_of({1'b0, sec_raw} + 3'd1);
                r_dwell   <= 16'd0;
                r_dir     <= dir_nxt;
                r_fwd_ref <= dir_nxt;
                r_fwd     <= bnd_of({1'b0, sec_raw} + 3'd1);
                r_bwd     <= bnd_of({1'b0, sec_raw});
                r_settle  <= 3'd1;
            end else begin
                if (!r_settled) r_settle <= r_settle + 3'd1;
                r_sec     <= nxt_sec;
                r_bnd     <= nxt_bnd;
                r_dwell   <= dwell_nxt;
                r_dir     <= dir_nxt;
                r_fwd_ref <= dir_nxt;
                r_fwd     <= r_fwd_nxt;
                r_bwd     <= r_bwd_nxt;
            end

            // 1 拍迟滞 + 切换拍判决：置位后需要一个"足够长"的扇区才清除
            r_warn <= warn_set ? 1'b1 : (warn_clr ? 1'b0 : r_warn);

            u_out          <= uwven ? u_n : 1'b0;
            v_out          <= uwven ? v_n : 1'b0;
            w_out          <= uwven ? w_n : 1'b0;
            // ★ 方向判定用的角度历史（每拍无条件更新）
            r_ang_prev     <= eang_x[AW-1:0];
            pole_pairs_eff <= pairs_eff;
            uvw_freq_warn  <= r_warn;
            out_valid      <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
