// ============================================================================
//  abz_gen.v  --  ABZ 增量输出发生器（SPEC 1.8，核心创新点 3）
// ----------------------------------------------------------------------------
//  功能：
//    把周期内角度 angle 细分成 4*inter 个正交边沿，经迟滞、post-AB 分频
//    (div)、AB 限频 (ablimit)、Z 门控相位后输出工业标准 ABZ 增量信号，
//    并给出边沿计数 edge_cnt、限频状态 limiter_active、lag_warn / lag_fatal。
//
//  Latency ≤ 3（in_valid 起算到 out_valid = 2 拍；加上输入寄存共 3 拍）
//
//  资源估计（Artix-7 XC7A35T，AW=16）：
//    FF  ~170（32 位 edge_cnt、12 位限频计数器、16 位 Z 相位差、12 位相位累加器）
//    LUT ~260（20 位乘法用移位加法；无 DSP 推断）
//    DSP  0
//
//  时钟假设：本工程 v1 为 **50 MHz 单时钟域**（CLK_PERIOD_NS = 20.0）；可由顶层
//    覆盖为 100 MHz（10.0）。AB/UVW 输出频率远低于时钟，直接由该时钟产生（SPEC 0.3）。
//
//  ※ A/B 格雷正交映射的两种等价写法（已在 _tools/check_ab_map.py 上逐点验证）
//
//   SPEC 1.8 原文写的映射 A = edge_idx[1]^edge_idx[0]、B = edge_idx[1]，
//   与本地采用的  映射 A = edge_idx[1]、B = edge_idx[1]^edge_idx[0]，
//   **两者都是合法的标准格雷正交序列**，差别只在"哪一相超前"：
//
//     原文映射(idx 0,1,2,3,…): A,B = 00→10→11→01→00…   A 超前 B  90°  (A 首升沿 idx=1，B 首升沿 idx=2)
//     本地映射(idx 0,1,2,3,…): A,B = 00→01→11→10→00…   B 超前 A  90°  (A 首升沿 idx=2，B 首升沿 idx=1)
//
//   两者的实测结果（64 步）：A 占空 50.00%、B 占空 50.00%，A/B 边沿数各 32 次，
//   且都满足 A ≠ B 与 A ≠ ~B。
//   ⚠ 早期版本的本注释曾断言"原文映射会退化成 A ≡ ~B、180°、2/3 占空"——
//     该断言是**错误的**：edge_idx[0] 每步翻转、edge_idx[1] 每两步翻转，二者并不同步翻转。
//     现已更正（验证脚本：_tools/check_ab_map.py）。
//
//   因此本地实现选择哪一种**只是方向约定问题**，可由 abzdir 完全补偿：
//   本模块采用 B 超前 A 的相位序；若你的接收端约定 A 超前 B，
//   把 abzdir 置 1（或在顶层交换 a_out/b_out 的引脚分配）即可。
//   本工程默认 abzdir 由寄存器 OUTPUT.abzdir 控制，实测单路反相/双路反相/
//   abzdir 的行为与 通用 ABZ 规范 §6.1 的规则一致（见文件末尾实测表）。
//
//  ※ 与契约的其它解释：
//   1) "div=2…8 时对边沿索引做 mod div 抽取（保留一个 3 位模计数器）" —— 本地
//      实现为"相位累加器 + 每 div 个原始边沿步输出 1 步"，这是 mod div 抽取
//      的等价、且不会丢步的写法（输入一拍跨多个边沿时按实际增量累加）。
//   2) AB 限频的最小间隔换算：
//         gap_clk = ceil( (20 [ns/edge] * (ablimit+1) * div) / CLK_PERIOD_NS )
//      用 CLK_PERIOD_NS/0.5/0.25 三个参数分支实现，避免在可综合代码里用浮点。
//   3) lag_warn / lag_fatal（SPEC 未定义量化方式）：用"没能及时执行的步数"
//      lag_mag 换算成输出相位判定（一个输入周期 = 4*inter 个边沿步 = 360°）：
//        45°  (lag_warn) : lag_mag * div >= inter / 2   （奇数 inter 向上取整）
//        180° (lag_fatal): lag_mag * div >= 2 * inter
//      inter 为 0 时按 256 处理。该定义与 model/abz_uvw_model.py 完全一致。
//      ★★ 2026-10-11（v8，见 DEV_STATUS §1.33 ⑦ / §3 item 18）：此前这两条的阈值
//        写成 2*inter / 4*inter，按 4*inter 步 = 360° 的几何其实是 **180° / 360°**，
//        与"45°/180°"的标称差 4×（探针 tools/lag_thr_probe.py 实测：慢速斜坡首次
//        lag_warn 时真实滞后 180.7°、首次 lag_fatal 361.4°）。后果是 lag_fatal 进
//        帧的 E 位（rtl/enc_top.v:730）后，接口上的"错位"告警要丢掉近一整圈才亮。
//        现已按标称重标定为 inter/2 与 2*inter（本行公式即当前实现）。
//      ★ 2026-10（v8 / item 16）：判据幅值 lag_mag = |slc_fwd - slc_bwd| + r_ovl，
//        两个来源：
//        ① 被 ablimit 限频器压住的点火（原有，方向性计数，只喂 limiter_active 与 lag）；
//        ② **累加器过速钳位**（新增，独立的无方向计数 r_ovl）：单拍步进超过 acc_th 时
//           余量排不出去，钳回 [0,acc_th-1]，每钳一拍记 1 步。此前这条路径完全不进
//           pending，于是"每 in_valid 拍最多点火一次"这条硬上限造成的丢沿**不被监视器
//           看见**（lag_warn/lag_fatal 全程为 0 的盲区）。
//        ★★ ② **不并入** ① 的计数器：① 的两个计数器是方向性的（正向只被正向边沿
//           衰减），纯单向运行时一次反向残留永不衰减，而 limiter_active 含
//           (pending!=0) ⇒ 会把 limiter_active **永久拉高**、破坏 SPEC_interface_contract.md:372
//           对限频状态的契约（实测 tb_enc_top TEST B：slc_b=4 残留 ⇒ limiter_hi 满圈
//           4194304 clk）。故 ② 单独计数、只喂 lag 判据，limiter_active 维持 v7 语义。
//        ★ r_ovl 计数为**下界**（单拍丢多步只记 1）⇒ 只会报得偏保守、不会漏报。
//   4) Z 宽度：★ v9（2026-10-11）起改为 **(z_width + 1) 个"边沿索引步"**，对齐通用的
//      `zwidth_edges = (zwidth + 1) / div` 约定（公开数据手册、本设计 §3.5）。v8 及以前是 `z_width` 个原始边沿步
//      （默认 4 vs 手册 5 = 短 20%，`z_width = 0` 时 v8 无 Z 而手册 1 步）——
//      差异已由仿真（tb_enc_top C5 = 2042 拍 ≈ 4×512）与板上二值实验（`0x0108 = 0x4000`
//      时 Z 完全无脉冲）双重确认，见 docs/DEV_STATUS.md §1.47。
//      Z 通道旁路 post-AB 分频（与 专用细分 ASIC 一致），所以 div>1 时 Z 的宽度按原始
//      分辨率计，折算到"输出 AB 边沿"约为 (z_width+1)/div（实测见报告表 2）。
//      并有 Z_TIMEOUT 超时保护：若 (z_width+1) 个边沿始终未走满（输入停住），
//      Z 脉冲在 Z_TIMEOUT 个 clk 后强制结束，避免卡死 —— 代价是极低频时宽度会被
//      截短（`f_in ≥ 11.92·(z_width+1) Hz`，见 docs/DEV_STATUS.md §1.49 与 §1.26 ⚠ 条）。
//   5) z_window=1 且角度穿越 z_phase 时产生 Z；z_window=0 时不产生 Z。
//
//  专用细分 ASIC 极性规则（datasheet §6.1 OUTPUT.apol/.bpol）：
//    "只翻转 apol 或 bpol 之一会反转 AB 计数方向，两个都翻转不会。"
//    本模块 apol/bpol 只做电平反相，abzdir 只控制索引行进方向；在标准格雷
//    正交映射下，反相单路恰好等价于方向反转，因此 (apol ^ bpol)=1 时计数
//    方向自动反转，用户用 abzdir=1 补偿回来。实测：
//      apol=1 或 bpol=1 -> 索引递减；apol=bpol=1 -> 索引递增；
//      abzdir=1 -> 索引递减；apol=1 & abzdir=1 -> 索引重新递增。
//
//  复位：同步复位、低有效。无 initial、无延时、无 inout、无 SystemVerilog。
// ============================================================================
`timescale 1ns / 1ps

module abz_gen #(
    parameter integer AW            = 16,      // 角度位宽（每周期 = 2^AW）
    parameter integer ZW            = 12,      // Z 相位/宽度位宽（内部）
    parameter integer LIMW          = 12,      // AB 限频保持计数器位宽
    parameter integer PENDING_W     = 13,      // 待执行步数（有符号）位宽
    parameter integer ACCW          = 13,      // 相位累加器位宽（有符号）
    parameter integer STEPW         = 12,      // 单拍索引增量位宽（有符号）。★ 12 位足够：
                                               //   d_sgn 的有效范围是 ±2*inter（<= ±512），而
                                               //   补码截断到任意 >=12 位都保号（±2047 都能正确
                                               //   表示），实测 12/13 位结果逐位相同。
                                               //   （曾经这里还有一行多余的 assign，按 d_sgn[10]
                                               //   做零扩展 —— d_sgn[10] 对负数是 1，会把 -1 变成
                                               //   -2047；那行已删除，见下方注释。）
    parameter         CLK_PERIOD_NS = 20.0,    // clk 周期 ns（50 MHz = 20.0，100 MHz = 10.0）
                                               //   本工程 v1 为 50 MHz 单时钟域，故默认 20.0
    parameter         CLK_NS_HALF   = 5.0,     // = CLK_PERIOD_NS / 2
    parameter         CLK_NS_QUART  = 2.5      // = CLK_PERIOD_NS / 4
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire [AW-1:0]       angle,
    input  wire                in_valid,
    input  wire [9:0]          inter,      // AB 输出周期数/输入周期；0 视为 256；2…256
    input  wire [2:0]          div,        // 后分频 1…8（寄存器值 = div-1）
    input  wire [4:0]          hyst,       // 迟滞 0…31，单位 360°/2048
    input  wire [7:0]          ablimit,    // 限频：最小边沿间隔 = 20ns*(ablimit+1)*div
    input  wire                apol,
    input  wire                bpol,
    input  wire                zpol,
    input  wire                abzdir,
    input  wire                abzen,
    // ---- Z 通道 ----
    input  wire                z_window,   // 来自顶层 Z 门控窗口
    input  wire [11:0]         z_phase,    // Z 相位，单位 360°/4096
    input  wire [3:0]          z_width,    // Z 宽度参数（z_width 0…15）；★ v9 起实际脉冲宽 = z_width+1 个 AB 边沿步（1…16）
    // ---- 输出 ----
    output reg                 a_out,
    output reg                 b_out,
    output reg                 z_out,
    output reg  signed [31:0]  edge_cnt,   // 内部 AB 边沿计数（有符号）
    output reg                 limiter_active,
    output reg                 out_valid,
    output reg                 lag_warn,   // 滞后 >= 45°
    output reg                 lag_fatal   // 滞后 >= 180°
);

    // ------------------------------------------------------------------
    //  localparam
    // ------------------------------------------------------------------
    localparam integer EDGE_SHIFT = AW - 2;              // (angle*inter) >>> (AW-2)
    localparam integer HYST_SHIFT = AW - 11;             // 迟滞量子 = 360/2048
    localparam integer ZPH_SHIFT  = AW - 12;             // z_phase 单位 360/4096
    localparam integer ZPH_BITS   = 12;
    localparam integer ZPH_W      = (AW > ZPH_BITS) ? AW : ZPH_BITS;
    localparam integer Z_TIMEOUT  = 4096;                // Z 脉冲最长 clk 数
    localparam integer Z_PULSE_W  = 5;                   // ★ v9：Z 宽度位数（z_width+1 ⇒ 最大 16）
    localparam integer NS_PER_CLK = (CLK_PERIOD_NS < 1.0) ? 1 : CLK_PERIOD_NS;
    localparam [15:0]  GAP_MAX    = 16'hFFFF;            // 限频间隔饱和上限
    localparam [9:0]   INTER_MAX  = 10'd256;             // inter=0 的等价值
    localparam signed [ACCW-1:0] ACC_ZERO = {ACCW{1'b0}};
    localparam signed [ACCW-1:0] ACC_ONE  = {{(ACCW-1){1'b0}}, 1'b1};   // 供余量上限 acc_th-1
    localparam signed [STEPW-1:0] STEP_ZERO = {STEPW{1'b0}};
    localparam signed [PENDING_W-1:0] PEND_ZERO = {PENDING_W{1'b0}};
    localparam signed [PENDING_W-1:0] PEND_ONE  = {{(PENDING_W-1){1'b0}}, 1'b1};
    localparam signed [PENDING_W-1:0] PEND_MAX  = {1'b0, {(PENDING_W-1){1'b1}}};
    localparam integer LAG_WARN_DIV  = 2;    // 45°  = inter/2（4*inter 步的 1/8），奇数 inter 向上取整
    localparam integer LAG_FATAL_MUL = 2;    // 180° = 2*inter（4*inter 步的 1/2）

    // ------------------------------------------------------------------
    //  内部信号
    // ------------------------------------------------------------------
    reg  [9:0]                  inter_n;        // 0 → 256
    reg  [2:0]                  div_n;          // 寄存器值 0..7（div = div_n+1）
    reg  [AW-1:0]               hyst_lsb;       // hyst * 2^(AW-11)
    reg                         dir_rev;        // 1 = 索引递减

    reg  [AW-1:0]               r_last_ang;     // 上一次"允许切换"时的原始角度
    reg  [9:0]                  r_idx;
    // ★ r_idx 的"上一拍值"（= 上一拍锁存进 r_idx 的 idx_tgt）。组合逻辑里的目标差
    //   必须只差**一拍**：时序块在同一拍执行 "r_idx <= idx_tgt"，非阻塞赋值下 RHS
    //   读到的 r_idx 仍是更新前的值，所以 (idx_tgt - r_idx) 本身就是正确的单拍差。
    //   而 r_idx_prev 若按 r_idx_prev <= r_idx 锁存，就比 r_idx 又旧一拍，差值变成
    //   跨两拍的差：同一个原始边沿步会被累计两次（相位累加器推进速度翻倍，A/B 边沿
    //   数约为 4*inter/div 的两倍）。故下面时序块锁存的是 idx_tgt，使本寄存器真正
    //   等于"上一拍的 r_idx"。参考模型 model/abz_uvw_model.py:169-175 用的就是推进
    //   前的 cur_idx（模型在函数末尾 :274 才 cur_idx = tgt），二者语义一致。
    reg  [9:0]                  r_idx_prev;
    reg  [9:0]                  r_div_idx;
    reg  signed [ACCW-1:0]      r_acc;
    reg  [LIMW-1:0]             r_hold;
    reg  signed [PENDING_W-1:0] r_slc_fwd;
    reg  signed [PENDING_W-1:0] r_slc_bwd;
    // ★★ 过速丢步积压（item 16 ②）：与上面两个"被限频器压住的步数"分开计。
    //    只进 **lag 判据**，不进 limiter_active —— 后者按 SPEC_interface_contract.md:372 的
    //    契约必须只表示"限频保持/正在补发被压住的步"这一状态（见文件头 :47-62）。
    reg  [PENDING_W-1:0]        r_ovl;

    // Z 通道
    reg                         r_z_active;     // Z 脉冲正在输出
    reg                         r_z_prev_hi;    // 上一拍相位差是否落在后半周
    reg  [3:0]                  r_pend_ttl;     // ★ v71：跨零挂起剩余寿命（有效样点数）
    reg  [Z_PULSE_W-1:0]        r_z_left;       // Z 剩余边沿步（★ v9：5 位，最大 16）
    reg  [15:0]                 r_z_to;         // Z 超时计数
    reg                         r_z_out;

    // 组合
    wire [9:0]                  r_idx_m1;        // inter_n - 1
    wire [9:0]                  half_step;       // inter_n*2
    wire [AW+9:0]               idx_prod;        // angle * inter_n
    wire [9:0]                  idx_raw;
    wire [AW-1:0]               ang_delta;
    wire                        hyst_pass;
    wire [9:0]                  idx_tgt;
    // ★★ 位宽修正（2026-10）：原来这四条是 11 位、half_per/period 是 12 位，看似
    //    够用，实际在反向路径上有截断：`d_rev_raw = r_idx_prev - idx_tgt` 可以是
    //    负数（如 -1），而 d_sgn 声明为 **11 位无符号** ⇒ -1 存进去变成 2047，
    //    随后 `d_sgn[10]=1`、`~d_sgn + 11'd1` 算出 -2047，step_val 被符号扩展成
    //    -2047 而不是 -1，步进幅度被放大 2047 倍。实测逐拍 dump
    //    （_sim_work/pt_e2.v）：abzdir=1 时出现 `d_sgn=2047 step=-1`。
    //    旧代码之所以"看起来正常"，是因为累加器被符号门控卡在饱和值上掩盖了它
    //    （见下方累加器排空修正）。统一加宽到 13 位有符号后，±4095 足以覆盖
    //    |4*inter|=1024、|2*inter|=512 与两个 raw 差的全域，不再有任何截断。
    wire signed [12:0]          d_fwd_raw;      // 精确目标差（±4*inter）
    wire signed [12:0]          d_rev_raw;
    wire signed [12:0]          d_sgn;           // 最短有符号差（补码，范围 ±2*inter）
    wire        [12:0]          d_abs;
    wire                        d_nz;            // d_sgn != 0
    wire                        trig_ok;
    wire signed [12:0]          half_per;        // 2*inter（半周期）
    wire signed [12:0]          period;          // 4*inter（一个整周期）
    wire signed [STEPW-1:0]     step_val;
    wire signed [ACCW-1:0]      acc_sum;
    // ★★ 累加器排空修正（见下方 "累加器溢出判定" 与主时序的注释）：
    //    acc_step_sum = r_acc + step_val  —— 本拍叠加后、**尚未排空**的原始累加值。
    //    它就是 acc_sum 的别名，单独起名只是为了在代码里强调"排空还没做"，
    //    因为排空的唯一位置是主时序里 r_acc 那三行（组合块只出判据，绝不扣 acc_th）。
    wire signed [ACCW-1:0]      acc_step_sum;
    reg  [15:0]                 gap16;           // 限频间隔（clk 数），组合计算
    wire signed [PENDING_W-1:0] pend;
    wire [PENDING_W-1:0]        pend_mag;
    wire [PENDING_W+11:0]       pend_scaled;
    wire [PENDING_W+11:0]       lag_warn_th;
    wire [PENDING_W+11:0]       lag_fatal_th;
    wire signed [ACCW-1:0]      acc_th;          // div 的有符号零扩展
    // ★★★ acc_th 必须是**有符号**（`wire signed`）—— 2026-10 的真根因就在这里。
    //   原声明是 `wire [ACCW-1:0] acc_th;`（无符号），而判定写成
    //       if (acc_step_sum >= acc_th) acc_fire_fwd = 1'b1;
    //   当 acc_step_sum 是负数（反向路径必然出现）时，Verilog 的混符号比较规则会把
    //   **两边都按无符号比**：-1 被读成 8191，于是 `8191 >= 1` 成立 ⇒ **反向也被
    //   判成"正向点火"**，方向信息彻底丢失，同时真正的反向排空分支
    //   （`acc_step_sum < ACC_ZERO`）永远轮不到。结果就是累加器单调滚向负饱和、
    //   边沿静默丢失，而 lag_warn/lag_fatal 全程为 0。
    //   实测逐拍 dump（_sim_work/pt_e3.v，abzdir=1 / inter=8 / div=0）：
    //     acc_sum=-2 已被判成 fire_fwd=1，r_acc 每拍 -1 单调下滚。
    //   改成 `wire signed` 后两边都是有符号，比较才会按补码语义正确进行。
    //   （acc_sum / acc_step_sum 本来就是 `wire signed`，唯一漏掉的就是这一条。）
    // ★★ 过速钳位 + 监视（2026-10，v8 / item 16 ①+②）—— 见下方"累加器过速保护"整段。
    wire signed [ACCW-1:0]      acc_rem_max;     // 余量上限 = acc_th - 1（合法余量区间 [0, acc_th-1]）
    wire signed [ACCW-1:0]      acc_rem_fwd;     // 正向排空一次后的余量 = acc_step_sum - acc_th
    wire signed [ACCW-1:0]      acc_rem_bwd;     // 反向排空一次后的余量 = acc_step_sum + acc_th
    wire                        acc_clip_fwd;    // 正向余量越上限 ⇒ 本拍至少丢掉 1 个完整输出步
    wire                        acc_clip_bwd;    // 反向余量越下限 ⇒ 同上（反向）
    // Z
    wire [ZPH_W-1:0]            z_phase_ext;
    wire [ZPH_W-1:0]            z_ang_ext;
    wire [ZPH_W-1:0]            z_ph_off;
    wire                        z_ph_hi;
    wire [Z_PULSE_W-1:0]        z_pulse_n;      // ★ v9：z_width + 1（最大 16）
    // 分频/限频控制
    reg                         acc_fire_fwd;
    reg                         acc_fire_bwd;
    wire                        hold_empty;
    wire                        fwd_go;
    wire                        bwd_go;
    wire                        idx_exec;
    // pending（r_slc_fwd/r_slc_bwd）的单点净变化信号 —— 见"限频压住的步数"整段：
    //   增 = 被限频器压住的点火（**只有这一条**，与 v7 相同 ⇒ limiter_active 语义不变）
    //   减 = 本拍真的执行了一个边沿
    //   ⚠ 增与减互斥：hold 非空时 idx_exec=0，同一拍不可能又增又减。
    wire                        slc_fwd_inc;
    wire                        slc_fwd_dec;
    wire                        slc_bwd_inc;
    wire                        slc_bwd_dec;
    wire                        ovl_tick;      // 本拍累加器被钳位（= 至少丢 1 个完整输出步）
    wire [PENDING_W:0]          lag_mag;       // lag 判据用幅值 = |净积压| + 过速积压

    // ------------------------------------------------------------------
    //  0) 参数预计算
    // ------------------------------------------------------------------
    always @(*) begin
        inter_n  = (inter == 10'd0) ? INTER_MAX : inter;
        div_n    = div;
        hyst_lsb = hyst << HYST_SHIFT;             // 32 * hyst
        dir_rev  = abzdir ^ apol ^ bpol;
    end

    assign r_idx_m1   = inter_n - 10'd1;
    assign half_step  = inter_n << 1;              // 2*inter（判最短差用）

    // ------------------------------------------------------------------
    //  1) 边沿索引插补：edge_idx = (angle * inter) >>> (AW-2)
    //     乘积 <= 256 * 65535 = 2^24，用 (AW+10) 位足够。
    // ------------------------------------------------------------------
    assign idx_prod = angle * inter_n;
    assign idx_raw  = idx_prod[AW+9:EDGE_SHIFT];

    // ------------------------------------------------------------------
    //  2) 迟滞：仅当"原始角度算出的索引 != 当前索引"且"相对上次切换角度的
    //     变化量 >= hyst*2^(AW-11)"时才允许推进（用角度比较，不比较索引模）。
    //     hyst=0 时不启用迟滞（与 SPEC 一致：仅"当前边沿索引 + 迟滞"之外才切换）。
    // ------------------------------------------------------------------
    assign ang_delta = angle - r_last_ang;
    assign hyst_pass = (hyst == 5'd0) ? 1'b1
                     : ((ang_delta >= hyst_lsb) ||
                        (ang_delta >= ({1'b1, {(AW-1){1'b0}}} - hyst_lsb + 1'b1)));

    assign idx_tgt  = hyst_pass ? idx_raw : r_idx;

    // ------------------------------------------------------------------
    //  3) 最短有符号差 + 相位累加器（等价于对边沿索引做 mod div 抽取）
    //     累加器按 idx 的**实际增量**推进，因此输入一拍跨多个边沿时不会丢步。
    // ------------------------------------------------------------------
    // 差用 11 位有符号减法得到**精确**值：idx_raw 的取值域是 [0, 4*inter-1]，差值
    // 范围 ±1023 不会回绕（原写法是 10 位无符号减，即 mod 1024：inter=64 时索引
    // 回绕处 0-255 得 769 而不是 -255，随后减 2*inter 得到 513，于是每个回绕点都
    // 往相位累加器灌进一个几百~上千的假步进）。
    assign d_fwd_raw = {1'b0, idx_tgt} - {1'b0, r_idx_prev};
    assign d_rev_raw = {1'b0, r_idx_prev} - {1'b0, idx_tgt};
    // 取"最短路径"差：idx_raw 的取值域是 [0, 4*inter-1]（一个输入周期走 4*inter 个
    // 边沿步），所以"一个整周期"= 4*inter、"半周期"= 2*inter。原写法误把半周期当作
    // 整周期（减去 2*inter），加上上面的 mod 1024 污染，导致回绕点步进严重错误。
    // 下面用"超出 ±半周期则折回一个整周期"，与模型 model/abz_uvw_model.py:168-175
    // （mod n_step 后按 n_step/2 折回得到最短有符号差）等价。
    // ★ 宽度：全部用上面已加宽的 13 位有符号（period = 4*inter 最大 1024，
    //   half_per = 2*inter 最大 512，d_xxx_raw 最大 ±4*inter = ±1024）。
    assign half_per = half_step;                      // 2*inter
    assign period   = {1'b0, inter_n, 2'b0};          // 4*inter
    assign d_sgn = dir_rev
                 ? ((d_rev_raw >  half_per) ? (d_rev_raw - period)
                 :  (d_rev_raw < -half_per) ? (d_rev_raw + period)
                 :  d_rev_raw)
                 : ((d_fwd_raw >  half_per) ? (d_fwd_raw - period)
                 :  (d_fwd_raw < -half_per) ? (d_fwd_raw + period)
                 :  d_fwd_raw);
    // ★ 取绝对值必须按**符号位**判（d_sgn[12]），不能按 d_sgn[10]。d_sgn 现在
    //   是有符号 13 位，`~d_sgn + 13'd1` 在自身宽度内取反加一，结果正确。
    assign d_abs   = d_sgn[12] ? (~d_sgn + 13'd1) : d_sgn;
    assign d_nz    = (d_sgn != 13'sd0);
    assign trig_ok = d_nz && ((hyst == 5'd0) || (d_abs >= {8'd0, hyst}));
    // ★ 符号扩展：反向时 d_sgn 是负数（如 -1 = 13'b1_1111_1111_1111），若零扩展
    //   就会把它当成大正数、方向彻底搞反 —— 这正是 TEST E 六种极性配置全给出
    //   同一个正计数的原因。当前 d_sgn 恰好 13 位 = STEPW 位，扩展量为 0，
    //   但**不能**无条件写 {{(STEPW-13){d_sgn[12]}}, d_sgn}：当 STEPW-13 为负时
    //   Vivado 报 `ERROR: [VRFC 10-10112] concatenation multiplier constant must
    //   be positive`，整个设计无法 elaborate。故按宽度分支。
    generate
        if (STEPW > 13) begin : g_sext
            assign step_val = trig_ok ? {{(STEPW-13){d_sgn[12]}}, d_sgn} : STEP_ZERO;
        end else begin : g_nosext
            assign step_val = trig_ok ? d_sgn[STEPW-1:0] : STEP_ZERO;
        end
    endgenerate

    assign acc_th  = {{(ACCW-10){1'b0}}, div_n} + {{(ACCW-10){1'b0}}, 10'd1}; // div = div_n+1
    assign acc_sum = r_acc + step_val;
    assign acc_step_sum = acc_sum;             // 别名，强调"叠加后、尚未排空"

    // ------------------------------------------------------------------
    //  ★★ 累加器过速保护（2026-10，v8 / docs/DEV_STATUS.md §3 item 16 ①+②）
    //
    //  缺陷（v7 及以前）：r_acc 只在"点火"那一支里被排空一次（一次 -acc_th），
    //  而排空的唯一机会是每个 in_valid 拍一次（主时序整块被 `if (in_valid)` 门控）。
    //  所以单拍步进一旦超过 acc_th，余量就会**越界累积**：
    //      r_acc 每拍净增 (step_val - acc_th) > 0
    //      -> 13 位有符号在约 4095/(step-acc_th) 拍后越过 +4095 **回绕成负**
    //      -> acc_step_sum < 0 -> acc_fire_bwd -> **反向点火**，A/B 短暂倒转。
    //  实测（sim/tb_abz_jitter.v PH3，inter=256/div=1/f_in=20 kHz）：净增
    //  ≈1.6384-1 = 0.6384/拍，约 6400 拍（0.51 ms）后回绕；1 ms 窗口内出现
    //  正向 10947 / **反向 1553** 次点火。更糟的是 lag_warn/lag_fatal 全程为 0：
    //  pend（r_slc_fwd/r_slc_bwd）只统计"被 ablimit 限频器压住的步"，而这条
    //  过速路径根本不进限频器，**监视器对它的失效完全瞎**。
    //
    //  修法（两条，都不改正常工况的行为）：
    //    ① **双向钳位**：累加器的合法余量区间是 [0, acc_th-1]（它只保存"不够一个
    //       输出步"的余量，正反向都落在这一段），排空后的余量一律钳回该区间：
    //          正向 rem = acc_step_sum - acc_th，> acc_th-1 就取 acc_th-1；
    //          反向 rem = acc_step_sum + acc_th，< 0        就取 0。
    //       r_acc 从此恒在 [0, acc_th-1]，**不可能回绕** ⇒ 反向点火突发消失。
    //    ② **钳位即报**：钳位条件与"本拍至少丢掉 1 个完整输出步"**等价**
    //       （正向 rem > acc_th-1 ⇔ rem >= acc_th；反向 rem < 0 ⇔ 排空后仍欠
    //         acc_th 以上），所以钳位时给**独立的**过速计数 r_ovl **+1**，
    //       再由 lag_mag = |pend| + r_ovl 喂 lag_warn/lag_fatal，"跟不上"就看得见了。
    //       计数按"每拍 +1"是**下界**（单拍丢多个步时只记 1），持续过载下 r_ovl
    //       单调累积、照样到阈值，不会漏报，只会报得偏保守。
    //       ⚠ 若图省事把这一份直接加进 r_slc_fwd/r_slc_bwd（我第一版就是这么写的），
    //         limiter_active 会被**永久**拉高：那两个计数器是方向性的，
    //         纯正向运行里一次反向残留永不衰减（tb_enc_top TEST B 实测
    //         slc_b=4 ⇒ limiter_hi 满圈 4194304 clk、B8 失败）。详见文件头 :52-65。
    //
    //  ★ 正常工况（单拍步进 <= acc_th）永远不进这两条分支：div=1 时合法余量就是
    //    {0}，div=8 时余量 < 8，而正常步进远小于 acc_th —— 见回归判据 PH1/PH2。
    // ------------------------------------------------------------------
    assign acc_rem_max  = acc_th - ACC_ONE;
    assign acc_rem_fwd  = acc_step_sum - acc_th;
    assign acc_rem_bwd  = acc_step_sum + acc_th;
    assign acc_clip_fwd = acc_fire_fwd && (acc_rem_fwd >  acc_rem_max);
    assign acc_clip_bwd = acc_fire_bwd && (acc_rem_bwd <  ACC_ZERO);

    // ------------------------------------------------------------------
    //  4) 限频间隔：gap = ceil(20*(ablimit+1)*div / CLK_PERIOD_NS) 个 clk
    //     分母 NS_PER_CLK 是编译期整型常量（100 MHz → 10），综合时是常数除法。
    // ------------------------------------------------------------------
    wire [31:0] gap_num;
    wire [31:0] div_ext;
    assign div_ext = {{(32-ACCW){1'b0}}, acc_th};
    assign gap_num = 32'd20 * ({24'd0, ablimit} + 32'd1) * div_ext;

    always @(*) begin
        gap16 = (gap_num + (NS_PER_CLK - 1)) / NS_PER_CLK;
        if (gap16 > GAP_MAX) begin
            gap16 = GAP_MAX;
        end
    end

    assign hold_empty = (r_hold == {LIMW{1'b0}});
    assign fwd_go     = acc_fire_fwd && hold_empty;
    assign bwd_go     = acc_fire_bwd && hold_empty;
    assign idx_exec   = fwd_go | bwd_go;

    // ---- 限频压住 / 过速丢掉的步数（**单点净更新**，见上方 slc_* 信号）----
    //   ★ item 16 ② 的关键取舍：**过速（钳位）不进这里**。
    //     理由（有实测证据）：这两个计数器是**方向性**的 —— r_slc_fwd 只在正向执行
    //     边沿时 -1、r_slc_bwd 只在反向执行边沿时 -1。纯正向运行里任何一次反向
    //     增量都**永远不会衰减**，而 limiter_active = (!hold_empty)||(pend_mag!=0)
    //     会把这一次残留**永久**拉高（实测：tb_enc_top TEST B 起始即 slc_b=4、
    //     整个机械圈 limiter_hi=4194304 clk，B8 判据必失败 —— 见 docs/DEV_STATUS.md
    //     §1.33 ④）。所以过速证据走下面独立的 r_ovl 计数、只喂 lag 判据。
    assign slc_fwd_inc = acc_fire_fwd && !hold_empty;
    assign slc_fwd_dec = fwd_go && (r_slc_fwd > PEND_ZERO);
    assign slc_bwd_inc = acc_fire_bwd && !hold_empty;
    assign slc_bwd_dec = bwd_go && (r_slc_bwd > PEND_ZERO);
    //   过速证据：钳位拍 = 至少丢掉 1 个完整输出步（正反向等价，故不分方向）。
    assign ovl_tick = acc_clip_fwd | acc_clip_bwd;

    // ------------------------------------------------------------------
    //  累加器溢出判定（组合）：叠加后 >= div 就正向点火；叠加后 < 0 就反向点火。
    //
    //  ★★★ 缺陷修正（2026-10）—— **真根因是有符号/无符号混比，不是"符号门控"**。
    //
    //  原先 `acc_th` 被声明为无符号：
    //        wire [ACCW-1:0] acc_th;                     // ← 无符号！
    //  而判定写成 `if (acc_step_sum >= acc_th)`。Verilog 的**混符号比较规则**是
    //  "只要有一边无符号就两边都按无符号比"，而 acc_step_sum 是 `wire signed`。
    //  于是当累加器为负（**反向路径必然出现**）时：
    //        acc_step_sum = -1  →  被读成 8191，`8191 >= 1` 成立
    //  ⇒ **反向也被判成"正向点火"**，方向信息彻底丢失，真正的反向排空分支
    //    （`acc_step_sum < ACC_ZERO`）永远轮不到。
    //  后果：累加器单调滚向 13 位有符号负饱和，此后必须再攒够 acc_th 才点火
    //  一次，大量该产生的 A/B 边沿被静默丢掉，而 lag_warn / lag_fatal 全程为 0
    //  （pend 走的是被限频压住的那条路径，根本没进过限频器）—— 这就是"静默丢边沿"。
    //
    //  ★ 逐拍 dump 证据（`_sim_work/pt_e3.v`，abzdir=1 / inter=8 / div=0，改前）：
    //        i=16  acc_sum=-2  acc_th=1  fire_f=1  fire_b=0  r_acc=-2
    //        i=17  acc_sum=-3  acc_th=1  fire_f=1  fire_b=0  r_acc=-3   … 每拍 −1 下滚
    //    改成 `wire signed` 后同一点变成 acc_sum=0 / fire_f=0 / r_acc=0，不再漂。
    //
    //  ⇒ 四处修法：
    //    ① `acc_th` 改 `wire signed [ACCW-1:0]`（**关键一行**，两边都变有符号，
    //       比较才按补码语义进行）；
    //    ② 差路径 `d_fwd_raw`/`d_rev_raw`/`d_sgn`/`d_abs`/`half_per`/`period`
    //       统一加宽到 13 位有符号（原 `wire [10:0] d_sgn` 会把反向的 −1 存成 2047）；
    //    ③ 删掉一行**遗留的重复 `assign step_val`**（按 `d_sgn[10]` 零扩展，把 −1
    //       变成 −2047，且覆盖了上面 generate 的符号扩展分支）；
    //    ④ 补 `step_val == 0` 拍的**残留进位排空**（见下方主时序）。
    //
    //  ★ 此前的两版诊断（"符号门控导致 step_val==0 的拍排不掉进位"）只是次要
    //    放大器，且那个"511/512 = 99.8%"的量化来自只用 4 个采样点/电周期的隔离
    //    测试台，属混叠读数、不足为凭。修复后的正确口径见 `sim/tb_abz_gen.v`。
    //
    //  ⇒ 修法要点：点火判据**不再看 step_val 的符号**，只看累加值本身。
    //     由 acc_fire_fwd / acc_fire_bwd 在时序块里统一做**一次**排空
    //     （排空的唯一位置就是主时序里的 r_acc 那三行，组合块只做判据、
    //      绝不自己扣 acc_th —— 一开始我在组合块里也扣了一次，导致同一拍
    //      扣两遍，A/B 直接反向、tb_abz_gen TEST E 全红）。
    //     黄金模型 model/abz_uvw_model.py 的判定已同步为同样的"单次排空 + 不看符号"。
    // ------------------------------------------------------------------
    //  ★★ 组合块只出判据，**绝不自己扣 acc_th**（排空的唯一位置是主时序里 r_acc
    //     那三行）。一开始我在这里也扣了一次，结果同一拍排空两遍，A/B 直接反向、
    //     tb_abz_gen TEST E 全红 —— 这是本轮踩过的最贵的坑，务必保持。
    //     判定本身与 step_val 的符号**无关**，只看叠加后的累加值；至于是走
    //     "正常步进路径"还是"残留排空路径"，由主时序按 step_val 是否为零区分。
    always @(*) begin
        acc_fire_fwd = 1'b0;
        acc_fire_bwd = 1'b0;
        if (acc_step_sum >= acc_th)       acc_fire_fwd = 1'b1;
        else if (acc_step_sum < ACC_ZERO) acc_fire_bwd = 1'b1;
    end

    // ------------------------------------------------------------------
    //  5) lag 监视：pending = |slc_fwd - slc_bwd|，按输出相位判 45°/180°
    //     ★ item 16 ②：幅值再叠加"过速丢步积压" r_ovl，把"跟不上"纳入同一判据。
    //       两个量纲相同（都按"被拖住/丢掉的输出步数"计，每步 = acc_th 个索引单位），
    //       故直接相加：lag_mag = |pend| + r_ovl。
    // ------------------------------------------------------------------
    assign pend = r_slc_fwd - r_slc_bwd;
    assign pend_mag = pend[PENDING_W-1] ? (~pend + PEND_ONE) : pend;
    assign lag_mag = {1'b0, pend_mag} + {1'b0, r_ovl};
    assign pend_scaled  = {5'd0, lag_mag} * acc_th;
    assign lag_warn_th  = ({4'd0, inter_n} + 14'd1) >> LAG_WARN_DIV;   // 45°：向上取整
    assign lag_fatal_th = {4'd0, inter_n} * LAG_FATAL_MUL;             // 180°

    // ------------------------------------------------------------------
    //  6) Z 通道：角度穿越 z_phase 时产生 (z_width + 1) 个边沿步宽的 Z 脉冲，
    //     z_window=0 时不产生；带超时保护。
    //     ★ v9（2026-10-11）：宽度由 z_width 改为 z_width + 1，对齐公开数据手册的
    //     `zwidth_edges = (zwidth + 1) / div` 约定（本设计 §3.5）。v8 及以前为 z_width 个原始边沿步
    //     （默认 4 vs 手册 5，短 20%；z_width=0 时 v8 无 Z、手册 1 步）。
    //     板上二值实证见 docs/DEV_STATUS.md §1.47（z_width=0 时 v8 无脉冲）。
    // ------------------------------------------------------------------
    assign z_phase_ext = {{(ZPH_W-ZPH_BITS){1'b0}}, z_phase} << ZPH_SHIFT;
    assign z_ang_ext   = {{(ZPH_W-AW){1'b0}}, angle};
    assign z_ph_off    = z_ang_ext - z_phase_ext;
    assign z_ph_hi     = z_ph_off[ZPH_W-1];               // 1 = 相位差落在后半周（>=180°）
    //  ★ v9：加 1 个原始边沿步（z_width 0…15 ⇒ 宽度 1…16 步，故用 Z_PULSE_W=5 位）。
    assign z_pulse_n   = {1'b0, z_width} + 5'd1;

    // ★ v8（2026-10-11）：装载与推进分离所需的组合条件。
    //   z_in_win = 门控窗（选择"哪一次跨零出 Z"，每 2^POLE_BITS 个输入周期一次）；
    //   z_load   = 跨零沿 + 窗内 + 当前无脉冲 ⇒ 装载一个新脉冲；
    //   z_step_fin / z_timeout = 脉冲收尾（前者按边沿步数走完 z_width+1，后者 Z_TIMEOUT 兜底）。
    wire               z_in_win   = z_window & abzen;
    // ★ v71（2026-11-02 审计修复）：跨零沿先"挂起"Z_PEND_TTL 个有效样点，等 z_window
    //   脉冲到来再装载。原因：集成路径的窗由 pole_counter 回绕事件产生，比角度真正
    //   过零晚约 2 拍；若只在"开窗当拍同时有跨零沿"时才装载，Z 永远不会出。
    //   挂起有寿命上限（Z_PEND_TTL 个样点 ≈ 640 ns），远离窗的跨零不会留下僵尸请求。
    localparam integer Z_PEND_TTL = 8;
    // ★ v71：跨零沿要分方向。正转时 z_ph_hi 由 1→0（相位差由负变正），
    //   反转时是 0→1；只认一个方向会让反向完全不产生 Z（tb_enc_top C2/C5 FAIL）。
    //   方向由相邻有效样点的原始角度差符号给出（过采样下步长 << 半周）。
    wire signed [AW-1:0] z_dang  = angle - r_last_ang;
    wire               z_rev     = z_dang[AW-1];
    wire               z_xing    = z_rev ? (z_ph_hi & (~r_z_prev_hi))
                                        : ((~z_ph_hi) & r_z_prev_hi);
    wire               z_pend_ok  = (r_pend_ttl != 4'd0);
    wire               z_load     = z_in_win & (z_xing | z_pend_ok) & (~r_z_active);
    wire               z_step_fin = r_z_active & idx_exec & (r_z_left == 5'd1);
    wire               z_timeout  = r_z_active & (r_z_to == 16'd0);

    // ------------------------------------------------------------------
    //  主时序
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            r_last_ang     <= {AW{1'b0}};
            r_idx          <= 10'd0;
            r_idx_prev     <= 10'd0;
            r_div_idx      <= 10'd0;
            r_acc          <= ACC_ZERO;
            r_hold         <= {LIMW{1'b0}};
            r_slc_fwd      <= PEND_ZERO;
            r_slc_bwd      <= PEND_ZERO;
            r_ovl          <= {PENDING_W{1'b0}};
            r_z_active     <= 1'b0;
            r_z_prev_hi    <= 1'b0;
            r_pend_ttl     <= 4'd0;
            r_z_left       <= 5'd0;
            r_z_to         <= 16'd0;
            r_z_out        <= 1'b0;
            a_out          <= 1'b0;
            b_out          <= 1'b0;
            z_out          <= 1'b0;
            edge_cnt       <= 32'sd0;
            limiter_active <= 1'b0;
            lag_warn       <= 1'b0;
            lag_fatal      <= 1'b0;
            out_valid      <= 1'b0;
        end else if (in_valid) begin
            // ---- 迟滞角度跟踪 ----
            if (hyst_pass) begin
                r_last_ang <= angle;
            end
            r_idx <= idx_tgt;
            // ★ 目标差必须相对**上一拍的 idx_tgt**（即与 r_idx 更新前同值），故这里
            //   锁存 idx_tgt 而不是 r_idx：若写成 r_idx_prev <= r_idx，则该寄存器比
            //   r_idx 又旧一拍，差值变成跨两拍的差，同一个原始边沿步会被累计两次，
            //   相位累加器推进速度翻倍 → A/B 边沿数约为 4*inter/div 的两倍。
            //   （模型 model/abz_uvw_model.py:173-174 用 (tgt - cur_idx)，其 cur_idx
            //     直到 :274 才更新，正是"只差一拍"。）
            r_idx_prev <= idx_tgt;    // 供下一拍组合逻辑做目标差

            // ---- 相位累加器 + 分频抽取（每 div 个原始步输出 1 步）----
            //  ★★ 缺陷修正（2026-10）：原文是
            //       if      (step_val > STEP_ZERO) begin r_acc <= (acc_sum>=acc_th)? acc_sum-acc_th : acc_sum; ... end
            //       else if (step_val < STEP_ZERO) begin r_acc <= (acc_sum< ACC_ZERO)? acc_sum+acc_th : acc_sum; ... end
            //     即 r_acc 的更新被 step_val 的**符号**门控，两条分支各自只排空一次。
            //     问题在于 step_val == 0 的拍（输入角度本拍没跨过索引台阶，或迟滞
            //     把这一拍挡住）**完全不参与结算**：正常步进路径留下的余量卡在
            //     r_acc 里出不去。正向时 r_acc 加满即减、始终留在 [0,acc_th-1]，
            //     所以看不出来；反向时连续多拍叠加负步却排不掉，r_acc 单调跌到
            //     13 位有符号下限并**饱和**，此后必须再攒够 acc_th 才点火一次，
            //     大量该产生的 A/B 边沿被静默丢掉，而 lag_warn/lag_fatal 全程为 0
            //     （pend 走的是被限频压住的另一条路径，根本没进过限频器）。
            //     ★ 这是一条**长程累积**效应：单电周期只丢 1/512，要跑很多周期才
            //     明显（探针 _sim_work/pb_acc.v 实测 acc 贴底 -4096、A 沿 255/512）。
            //
            //  ⇒ 修法：**保留**上面两条符号分支的原有行为（正常步进路径一拍只排空
            //     一次，与 model/abz_uvw_model.py:177-197 的判定一致），只在
            //     step_val == 0 的拍**追加**一条残留排空分支，把卡住的余量放出来。
            //     排空的唯一位置就是下面这一处，组合块只出判据、绝不自己扣 acc_th
            //     （一开始我在组合块里也扣了一次，导致同一拍排空两遍、A/B 直接反向，
            //      tb_abz_gen TEST E 六项全红）。
            if (acc_fire_fwd) begin
                // ★★ 过速保护（item 16 ①）：排空后余量越上限就钳到 acc_th-1，
                //    r_acc 恒在 [0,acc_th-1]，永不走成负数 ⇒ 不再回绕成反向点火。
                r_acc <= acc_clip_fwd ? acc_rem_max : acc_rem_fwd;
            end else if (acc_fire_bwd) begin
                r_acc <= acc_clip_bwd ? ACC_ZERO : acc_rem_bwd;
            end else if (step_val != STEP_ZERO) begin
                // 正常步进路径：本拍叠加的值直接留下，等攒够 acc_th 再点火
                r_acc <= acc_step_sum;
            end else begin
                // ---- ★ 残留排空路径（新增）：本拍没有新步进 ----
                // 走到这里时 acc_step_sum 必然已落在不变区间 [0, acc_th-1]
                // （上面的两个比较都不成立），所以直接把它写回即可 —— 保留
                // 小于 acc_th 的余量继续往下一拍累积，而不是清零。保留余量才
                // 与 model/abz_uvw_model.py:216-231 的 `while acc >= div` 语义
                // 一致（那里循环到 acc < div 为止，同样保留余量）。
                r_acc <= acc_step_sum;
            end

            if (acc_fire_fwd) begin
                if (hold_empty) begin
                    r_div_idx <= (r_div_idx >= r_idx_m1) ? 10'd0 : (r_div_idx + 10'd1);
                end
                // else：本拍被限频器压住、不执行 —— pending 计入下方**单点更新**，
                //       这里不再直接赋值 r_slc_fwd（避免同一 reg 被多处赋值后相互覆盖）。
            end else if (acc_fire_bwd) begin
                if (hold_empty) begin
                    r_div_idx <= (r_div_idx == 10'd0) ? r_idx_m1 : (r_div_idx - 10'd1);
                end
            end

            // ---- 限频保持计数器 ----
            // 契约（本文件 :45）：最小边沿间隔 = gap_clk 个时钟。执行边沿后从下一拍
            // 起才开始递减，故装入值必须取 gap16-1，hold_empty 才会恰好在"上一沿 +
            // gap16"拍成立（间隔 = gap16 拍）。原先直接装入 gap16，实际间隔变成
            // gap16+1；当 gap16 与该配置的自然边沿周期相等时（inter=256/div=8：
            // 原始索引步间隔 2 拍、累加器满 8 步 = 16 拍、gap16 = 16），每到期的步
            // 都被 hold_empty 挡住而 r_acc 仍被扣掉 acc_th，输出速率恰好减半
            // （实测 64，契约值 128）。黄金模型 model/abz_uvw_model.py:154,:200-207
            // 的间隔正是 gap 拍，用它复算 inter=256/div=8 得 128，与本修正一致。
            if (idx_exec) begin
                r_hold <= (gap16 <= 16'd1) ? {LIMW{1'b0}}
                                           : (gap16[LIMW-1:0] - {{(LIMW-1){1'b0}}, 1'b1});
            end else if (!hold_empty) begin
                r_hold <= r_hold - {{(LIMW-1){1'b0}}, 1'b1};
            end

            // ---- 限频压住的步数（**单点净更新**，与 v7 语义相同）----
            //   增：被限频器压住的点火；减：本拍真的执行了一个边沿（见上方 slc_* 注释）
            if (slc_fwd_inc) begin
                r_slc_fwd <= (r_slc_fwd >= PEND_MAX) ? PEND_MAX : (r_slc_fwd + PEND_ONE);
            end else if (slc_fwd_dec) begin
                r_slc_fwd <= r_slc_fwd - PEND_ONE;
            end
            if (slc_bwd_inc) begin
                r_slc_bwd <= (r_slc_bwd >= PEND_MAX) ? PEND_MAX : (r_slc_bwd + PEND_ONE);
            end else if (slc_bwd_dec) begin
                r_slc_bwd <= r_slc_bwd - PEND_ONE;
            end

            // ---- 过速丢步积压 r_ovl（item 16 ②，只喂 lag 判据）----
            //   增：本拍钳位（至少丢 1 个完整输出步）。**不与同拍的执行相抵** ——
            //       钳位拍往往同时也在出边沿，但那一拍已经证明"产出的边沿数不够"，
            //       相抵会让"每拍都钳位且每拍都出沿"的严重过载**平白看不见**
            //       （这正是 v7 最要命的盲区形态）。
            //   减：没钳位而确实执行了一个边沿 ⇒ 积压还掉 1 步。
            //   计数为**下界**：单拍丢多步时只记 1，故只会报得偏保守、不会漏报。
            if (ovl_tick) begin
                r_ovl <= (r_ovl >= PEND_MAX) ? PEND_MAX : (r_ovl + PEND_ONE);
            end else if (idx_exec && (r_ovl > {PENDING_W{1'b0}})) begin
                r_ovl <= r_ovl - PEND_ONE;
            end

            // ---- 边沿计数 ----
            if (fwd_go) begin
                edge_cnt <= edge_cnt + 32'sd1;
            end else if (bwd_go) begin
                edge_cnt <= edge_cnt - 32'sd1;
            end

            // ---- Z 通道 ----
            // 相位点检测（边沿检测法）：z_ph_off 落在后半周时 z_ph_hi=1；
            // z_ph_hi 由 1 变 0 即"刚刚越过 z_phase" → 若当前无脉冲则装载
            // (z_width + 1) 个边沿步的 Z 脉冲。每个输入周期恰好一次。
            // ★ v8 修复（2026-10-11）：原实现把"脉冲推进 + 超时兜底"也放在 `z_window`
            //   门控内，而集成路径（rtl/enc_top.v 的 z_window 来自 cycle_cnt）在装载后
            //   ~2 clk 窗就关闭（pole_counter 的 wrap 延迟 2 clk）⇒ Z 脉冲被截成
            //   2 clk = 40 ns，`z_width`(0x0108) 完全不起作用。证据：
            //   sim/logs/tb_enc_top.log 的 Z_width_max=2（v7、v8 两版日志都是 2），
            //   而 tb_abz_gen / tb_abz_jitter / tb_loop_abz_chain 都把 .z_window(1'b1)
            //   常开 ⇒ "Z 宽 3.84 µs" 只在窗常开下成立，集成路径从未被测到
            //   （docs/DEV_STATUS.md §1.26 的口径需订正）。
            //   现在：装载仍由窗门控（每 2^POLE_BITS 个输入周期一次），脉冲推进与
            //   Z_TIMEOUT 兜底在窗外继续，宽度为 (z_width + 1) 个边沿步（★ v9 起）。
            //   ⚠ Z_TIMEOUT = 4096 clk 的兜底意味着极低频时宽度会被截短：
            //     需要 (z_width+1)/(1024·f_in) ≤ 81.9 µs ⇒ f_in ≥ 11.92·(z_width+1) Hz
            //     （默认 5 步 ⇒ ≥ 59.6 Hz，最大 16 步 ⇒ ≥ 190.7 Hz）；低频应用要放大 Z_TIMEOUT。
            if (z_load) begin
                r_z_active <= 1'b1;
                r_z_left   <= z_pulse_n;
                r_z_to     <= Z_TIMEOUT[15:0];
                // ★ v9：z_pulse_n ∈ [1,16] ⇒ 装载即可输出（v8 之前 z_width=0 时此处为 0，
                // 即"z_width=0 ⇒ 无 Z"，与手册 `(0+1)/div = 1` 步不符，已由 §1.47 板上实验确认）。
                r_z_out    <= 1'b1;
            end else if (r_z_active == 1'b1) begin
                if ((abzen == 1'b0) || z_step_fin || z_timeout) begin
                    r_z_active <= 1'b0;
                    r_z_out    <= 1'b0;
                    r_z_left   <= 5'd0;
                    r_z_to     <= 16'd0;
                end else begin
                    if (idx_exec && (r_z_left != 5'd0)) begin
                        r_z_left <= r_z_left - 5'd1;
                    end
                    if (r_z_to != 16'd0) begin
                        r_z_to <= r_z_to - 16'd1;
                    end
                end
            end else begin
                r_z_out  <= 1'b0;
                r_z_left <= 5'd0;
                r_z_to   <= 16'd0;
            end

            // 相位过零沿检测寄存：★ v71 起始终跟随 z_ph_hi（不再窗外清零），
            //   "哪一次跨零出 Z"完全由 z_window 脉冲 + 挂起寿命决定。
            r_z_prev_hi <= (z_ph_hi == 1'b1);

            // 跨零挂起寿命：检测到跨零沿则重新装满，否则逐样点递减
            if (z_xing) begin
                r_pend_ttl <= Z_PEND_TTL[3:0];
            end else if (r_pend_ttl != 4'd0) begin
                r_pend_ttl <= r_pend_ttl - 4'd1;
            end

            // ---- 输出级：标准格雷正交译码 + 极性 ----
            if (abzen) begin
                a_out <= r_div_idx[1] ^ apol;
                b_out <= (r_div_idx[1] ^ r_div_idx[0]) ^ bpol;
            end else begin
                a_out <= 1'b0;
                b_out <= 1'b0;
            end
            z_out <= abzen ? (r_z_out ^ zpol) : 1'b0;

            // ---- 状态输出 ----
            limiter_active <= (!hold_empty) || (pend_mag != {PENDING_W{1'b0}});
            lag_warn       <= (pend_scaled >= lag_warn_th);
            lag_fatal      <= (pend_scaled >= lag_fatal_th);
            out_valid      <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule

// ============================================================================
//  z_index_gen.v  --  虚拟索引（Z）门控窗发生器
// ----------------------------------------------------------------------------
//  把"每 2^POLE_BITS 个输入周期（= 1 圈）一个 Z"的圈事件从 enc_top 里抽出来，
//  便于单独例化做抖动回归（sim/tb_z_chatter.v），不改变 enc_top 的行为。
//
//  接口：angle（周期内角度，1 圈 = 2^AW LSB）、in_valid（有效样点）
//        → z_window（门控窗脉冲，Z_WIN_CLKS 拍宽）、z_idx_evt（单拍圈事件）
//
//  ★ v75（2026-11-03）：arm 机制修复"停位抖动时 Z 连续喘振（chatter）"
//    旧实现的事件式判据是
//        z_idx_evt = (ang_wrap_f | ang_wrap_b) & (rev_cnt[POLE_BITS-1:0] == 0)
//    转轴停在索引位附近时角度在 0° 附近来回 ⇒ ang_wrap_f/b 交替、rev_cnt 在
//    0/1 之间翻 ⇒ **每翻回 0 就再出一次 Z**。实测 0x054A 的 Z 计数 12,128,530
//    而实际只转约 4001 转（z_rate.py 实测转动时严格 1 Z/转），差额全部来自这种
//    停位抖动（抖动频率约 3 kHz）。
//
//    现在：出过一次 Z 后 z_armed <= 0，只有当角度相对**上一个 Z 的位置**离开
//    ≥ 1/8 圈（Z_ARM_DIST = 2^(AW-3) = 8192 LSB，模 2π 最短弧）才重新布防。
//    ⇒ 抖动幅度只有几十 LSB 时永远不再布防 ⇒ 同一圈最多出一个 Z；
//      正常转动离开 1/8 圈后立刻布防，圈事件照旧由 rev_cnt 保证 1 圈 1 次。
//
//    ⚠⚠ 最短弧**必须**用 AW 位补码差（模 2^AW 自动回绕）：
//          wire signed [AW-1:0] z_arm_d = angle - z_arm_ang;
//        绝不能写成 17 位扩位相减：0.2° 与 359.8° 的 16 位差是 +36（短弧），
//        扩位相减会算成 −65500，被判成"已离开 90°" ⇒ 停位抖动照样喘振
//        （这个 bug 在其它工程里踩过，见任务记录）。
// ============================================================================
module z_index_gen #(
    parameter integer AW        = 16,      // 周期内角度位宽（1 圈 = 2^AW LSB）
    parameter integer POLE_BITS = 11,      // 每 2^POLE_BITS 个输入周期 = 1 圈
    parameter integer CW        = 32       // 圈计数器位宽（与 enc_top 的 CYCLE_BITS 一致）
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [AW-1:0] angle,        // 周期内角度
    input  wire          in_valid,     // 有效样点
    output wire          z_window,     // Z 门控窗（6 拍宽）
    output wire          z_idx_evt,    // 单拍圈事件（已过 arm 判据）
    output wire          z_armed_o     // 探针：当前是否已布防
);

    localparam integer Z_WIN_CLKS = 6;                        // 窗宽（clk），> 2 拍读数延迟
    localparam [AW-1:0] ZW_TOP = (1 << AW) - (1 << (AW-3));   // 7/8 圈（AW=16 → 57344）
    localparam [AW-1:0] ZW_LOW = (1 << (AW-3));               // 1/8 圈（AW=16 → 8192）
    localparam [AW-1:0] Z_ARM_DIST = (1 << (AW-3));           // 重新布防所需的角距（1/8 圈）

    // ---- 过零事件：上一有效样点还在 7/8 圈外、本拍已进入 1/8 圈内（或反向）----
    reg [AW-1:0] z_ang_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              z_ang_prev <= {AW{1'b0}};
        else if (in_valid)       z_ang_prev <= angle;
    end

    wire ang_wrap_f = in_valid & (z_ang_prev >= ZW_TOP) & (angle <= ZW_LOW);
    wire ang_wrap_b = in_valid & (z_ang_prev <= ZW_LOW) & (angle >= ZW_TOP);

    // ---- 自由运行的圈计数（不在 Z 处清零，避免自我重触发）----
    reg signed [CW-1:0] rev_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          rev_cnt <= {CW{1'b0}};
        else if (ang_wrap_f) rev_cnt <= rev_cnt + 1'b1;
        else if (ang_wrap_b) rev_cnt <= rev_cnt - 1'b1;
    end

    // ---- ★ v75 arm 机制 ----
    reg              z_armed;
    reg  [AW-1:0]    z_arm_ang;                        // 上一个 Z 所在的角度
    wire signed [AW-1:0] z_arm_d   = angle - z_arm_ang; // ★ 模 2^AW 最短弧（补码）
    wire        [AW-1:0] z_arm_abs = z_arm_d[AW-1] ? (~z_arm_d + 1'b1) : z_arm_d;
    wire                 z_arm_ok  = (z_arm_abs >= Z_ARM_DIST);

    // 圈事件对齐：rev_cnt 的低 POLE_BITS 位为 0 ⇒ 每 2^POLE_BITS 个角度回绕出一次 Z
    wire z_rev_ok;
    //   POLE_BITS=11（生产配置）⇒ 每 2048 个电周期一个 Z。
    //   POLE_BITS=0 是给仿真用的"每个回绕一个 Z"（sim/tb_z_chatter.v 用它把
    //   "1 圈"映射成 1 个角度回绕，回归里 3 圈 = 3 个 Z；生产不受影响）。
    //   注意 POLE_BITS=0 时 `rev_cnt[-1:0]` 是非法零宽切片，必须走 generate 分支。
    generate
        if (POLE_BITS <= 0) begin : g_rev_all
            assign z_rev_ok = 1'b1;      // 2^0 = 1 ⇒ 每个回绕都算一个"圈"
        end else begin : g_rev_bits
            assign z_rev_ok = (rev_cnt[POLE_BITS-1:0] == {POLE_BITS{1'b0}});
        end
    endgenerate

    assign z_idx_evt = (ang_wrap_f | ang_wrap_b) & z_armed & z_rev_ok;
    assign z_armed_o = z_armed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z_armed   <= 1'b1;                          // ★ 复位即布防：首个索引正常出 Z
            z_arm_ang <= {AW{1'b0}};
        end else if (z_idx_evt) begin
            z_armed   <= 1'b0;                          // 出过 Z ⇒ 撤防，必须离开 1/8 圈才重布
            z_arm_ang <= angle;
        end else if (in_valid && z_arm_ok) begin
            z_armed   <= 1'b1;
        end
    end

    // ---- 窗展宽 ----
    reg [3:0] z_win_left;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    z_win_left <= 4'd0;
        else if (z_idx_evt)            z_win_left <= Z_WIN_CLKS[3:0];
        else if (z_win_left != 4'd0)   z_win_left <= z_win_left - 4'd1;
    end
    assign z_window = z_idx_evt | (z_win_left != 4'd0);

endmodule
