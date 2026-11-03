// -----------------------------------------------------------------------------
//  disp/disp_engine.v —— 7 寸屏本机 UI 渲染引擎
//
//  当前版本 = P1 总览页（`docs/13_display_ui_requirements.md` §4.5）。
//  它同时回答那个可测量的工程问题：
//
//      在 50 MHz 单时钟域、1 拍 1 像素的约束下，
//      「双层位图文本 + 程序化面板 + 编码器数据」的合成流水线
//      能不能收敛到时序预算 WNS ≥ +0.5 ns？
//
//  为什么必须守住这条（见 `_synth_work/impl_timing.rpt:209-218`）：
//    编码器实现版 WNS = +0.959 ns，最差路径是 `cfg_ablimit[2] → r_hold[0]` 的
//    28 级组合链（18.615 ns，其中路由占 58%）。合并显示引擎后实测只剩 +0.833 ns
//    （`_disp_work/impl_timing.rpt`，增量 -0.126 ns 建立 / -0.014 ns 保持）。
//    ⇒ 显示侧任何一条超过 ~19 ns 的组合链都会把整个工程拖成时序不收敛。
//
//  ---------------------------------------------------------------------------
//  ★ 三条硬规则（本文件必须遵守，也是交给后续版本的契约）
//  ---------------------------------------------------------------------------
//   规则 1  像素路径全寄存器化：每拍推进一步，禁止任何反压/停顿/分支失败。
//           本模块没有任何 FSM 在像素路径上，也没有 RAM 的读-改-写。
//   规则 2  BRAM 读出的数据必须**寄存一个完整"格"的时长**再使用。
//           字符单元 16/32 px 宽 ⇒ 读地址在格首变化、数据寄存一个整格；
//           字形 ROM 的行在格内恒定 ⇒ 地址在格首变化、数据寄存一个整格。
//           这样 BRAM 的 ~2 ns 读延迟被完全隐藏，不会出现在像素路径上。
//           （调研报告的反模式："每像素 1 次 BRAM 访问"会让端口占用达 72%；
//             本设计是每 16/32 像素 1 次读。）
//   规则 3  绝不复用编码器的组合链做判断。tap 输入只进寄存器，不参与
//           `gap_num` / `ablimit` 任何逻辑，也不给它们加扇出。
//
//  ---------------------------------------------------------------------------
//  像素流水线（延迟固定 3 拍，每拍 1 像素）
//  ---------------------------------------------------------------------------
//   S0  pix_x/pix_y/de 到达；由坐标拼出两层字符 RAM 的读地址（格首变一次）
//   S1  px1/py1/de1 + 两层字符码就位（BRAM 同步读）
//       → 组合出字形 ROM 地址 {char_code, 格内 y}（格首变一次）
//   S2  px2/py2/de2 + 两层字形行位图就位（ROM 同步读）
//       → 移位寄存器在格首装载、其后每拍左移 1 位，MSB 即当前列的像素
//   S3  合成（面板 + 描边 + 双层文字）→ 寄存输出 lcd_rgb
//
//  为什么用"移位寄存器"而不是"位选多路器"：
//    30 选 1 的多路器在 7 系列上约 5 级 LUT，已经越过 pixel path ≤ 4 级的纪律；
//    而移位寄存器把列选择退化成一个寄存器，像素路径上没有任何选择逻辑。
//    代价只是每层一个 16/32 bit 寄存器。
//
//  为什么字模行号 = 格内 y 本身（不做偏移/钳位）：
//    `tools/gen_font_rom.py` 生成的字库里，每个字占满整个格高，字形之外的扫描行
//    全是 0。这样 ROM 地址就是 `{ch, 格内 y}` 的直接拼接，像素路径上不需要
//    任何偏移、钳位或比较。多存几行 0 换来更短的路径，划算。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module disp_engine #(
    // v68 显示版：固定每转电周期数（64）；0 = 沿用 cfg_pairs（旧版行为）。
    // 只影响 val_format 的 RPM/累计转数字段。
    parameter integer CPR = 0
) (
    input  wire        clk,           // 50 MHz，与 enc_top 同域
    input  wire        rst_n,
    // ---- 页号（v15 起按 spec 4.4 的页序重排，3 位 = 8 页）----
    //   0 = P1 总览   1 = P2 输入波形  2 = P3 李萨如 XY  3 = P4 ABZ/UVW 时序
    //   4 = P5 六状态表 5 = P6 设置    6 = P7 标定       7 = P8 系统信息/触摸诊断
    //   ★ v14 及以前的编码是「0=P1, 1=P6, 2=P8」——那是按"页面做出来的先后"编的，
    //     于是**页号与左侧导航项的序号无关**，nav_sel 只能靠一张手写映射表
    //     （`nav_page = (page==0)?0:(page==1)?5:7`）。v15 把它对齐到 spec 页序后，
    //     映射表整条消失：导航第 k 项就是第 k 页（k=0..5），P7/P8 不在导航里，
    //     自然一个都不高亮。**能用编号顺序表达的关系，不要用查表表达。**
    input  wire [2:0]  page,
    // ★ v75（A）：P2 波形时基档位（0 = 2.4 ms / 1 = 300 µs / 2 = 38 µs）。
    //   档位是**显示侧偏好**、不进寄存器、不过 SPI，所以和 pnl_on/page 一样
    //   由策略层（disp/enc_top_disp.v 的触摸判定）送进来，引擎不持有它。
    input  wire [1:0]  p2_gear,

    // ---- 时序发生器接口（复用 lcd_test2/rtl/lcd_timing_gen.v，已实测通过）----
    input  wire [11:0] pix_x,         // 0..1023
    input  wire [11:0] pix_y,         // 0..599
    input  wire        de,            // 数据使能（有效区）

    // ---- 编码器数据抽头（只读快照，本模块绝不回驱）----
    input  wire [15:0] tap_angle,     // 电角度，0..65535 = 0..360°
    input  wire [15:0] tap_s_n,       // 校正后 sin（有符号）
    input  wire [15:0] tap_c_n,       // 校正后 cos（有符号）
    input  wire [31:0] tap_pos_full,  // 全周期位置
    input  wire [7:0]  tap_io_state,  // {limiter,dir,w,v,u,z,b,a}
    input  wire [7:0]  tap_io_flags,  // {amp_bad,cor_sat,uwven,abzen,uvw_warn,z_win,lag_fat,lag_warn}
    input  wire [7:0]  tap_stat,      // 状态字节
    input  wire [9:0]  tap_cfg_inter, // 倍频 inter
    input  wire [2:0]  tap_cfg_div,   // 分频 div
    input  wire [4:0]  tap_cfg_pairs, // 极对数（算转速/累计转数用）
    // ---- v14：P6 设置页的另外 6 个回读字段（位序见 rtl/enc_top.v 的 disp_tap 契约）----
    //   v13 只把倍频/分频/极对数引出来，够 P1 卡片算转速用；
    //   P6 要显示全部 9 个设置项，所以补齐（迟滞/限幅/Z脉宽/Z相位/UVW相位/极性）。
    input  wire [4:0]  tap_cfg_hyst_ab,
    input  wire [7:0]  tap_cfg_ablimit,
    input  wire [3:0]  tap_cfg_zwidth,
    input  wire [11:0] tap_cfg_zphase,
    input  wire [15:0] tap_cfg_uvwph,
    input  wire [3:0]  tap_cfg_pol,   // {uvwpol,zpol,bpol,apol}

    //   P7 标定页要的六个参数 + 实测幅值（抽头 v15）。这些量在 rtl/reg_file.v 里
    //   **早就是既有端口**（0x0510..0x051A 是寄存器输出、0x0530 是只读监视量），
    //   所以 v15 只是把它们引到显示侧：没有新增寄存器，也没有改 reg_file。
    input  wire signed [15:0] tap_ofs_s,
    input  wire signed [15:0] tap_ofs_c,
    input  wire [15:0] tap_gain_s,
    input  wire [15:0] tap_gain_c,
    input  wire signed [15:0] tap_phase_k,
    input  wire [3:0]  tap_shift,     // {shift_c[1:0], shift_s[1:0]}，0x051A
    input  wire [31:0] tap_amp_sq,    // 0x0530 STAT_AMP_SQ（Q2.30，只读）
    // v21：P7 的幅值百分比基准 = 编码器自己的幅值判据门限（0x0520 / 0x0524）。
    // 为什么非要引这两个：不引的话屏上只能拿一个"写死的额定值"当分母，
    // 用户一改门限，屏上的百分比就和编码器的告警判据不是一个口径了。
    input  wire [31:0] tap_amp_low_sq,   // 0x0520 AMP_LOW_SQ （Q2.30，默认 (0.60)²·2³⁰）
    input  wire [31:0] tap_amp_high_sq,  // 0x0524 AMP_HIGH_SQ（Q2.30，默认 (1.20)²·2³⁰）

    input  wire        tap_abzen,
    input  wire        tap_uwven,
    input  wire        tap_calib_busy,
    // v45（㊷）：抽头 [126] —— 原为链路帧 CRC 错的粘滞位（`crc_err_seen`）。
    //   这是"链路给出的数据本身就坏了"的直接证据，v44 之前显示侧没消费它。
    //   v74 起该源恒 0（端口保留、位图不重排），空态判据只剩"无载波"。
    input  wire        tap_link_crc_err,
    // v54（C3）：抽头 [375] —— 原为链路**静默**（心跳非粘滞：主机一恢复即落回 0）。
    //   同样在 v74 起恒 0，端口保留（位图不重排），仅作历史接口占位。
    input  wire        tap_link_lost,

    // ---- 触摸诊断打包（见 disp/enc_top_disp.v 的位序契约）----
    //   [1:0]type [4:2]num [20:5]x0 [36:21]y0 [44:37]status [52:45]prod_id
    //   [56:53]rst_cnt[3:0] [57]valid [65:58]probe_gt [73:66]probe_ft
    //   [74]int_pin [75]tch_toggle [99:76]stat_reads[23:0]
    //   [123:100]stat_nack[23:0] [147:124]stat_timeout[23:0]
    //   ★ P6 的触摸诊断页从这里解包。在页面画出来之前，本信号先参与
    //     `tch_alive` 的奇偶折叠 —— 否则综合器会把整条触摸诊断路径当死逻辑删掉，
    //     上板时"触摸有没有在动"就无从观察（详见下面 tch_alive 的注释）。
    input  wire [159:0] tch_diag,

    // ---- 屏上改值（③）的事务状态 ----
    //   只引两个信号，驱动两处可见反馈（见下文 ui_card_col）：
    //     ui_state -> P1 的 MULT/DIV 卡片底色：空闲/进行中/已确认/失败 四态
    //     ui_err   -> 失败时区分"回读不一致"（可回滚）与"回滚也失败"（严重）
    input  wire [1:0]  ui_state,
    input  wire [3:0]  ui_err,

    // ---- v19：模态二次确认（状态由 disp/enc_top_disp.v 的策略层持有）----
    //   0 = 不显示；1 = 询问中（等 CANCEL / OK）；2 = 已按 OK，正在写 0x0405
    //   ★ 模态一开，整个合成链只剩"遮罩 + 对话框 + 对话框自己的文字"：
    //     连触点半字准星都被遮住（spec 6.4 的二次确认不能与底层页面抢注意力）。
    input  wire [1:0]  ui_dlg,

    // ---- v34（㊲）：P6 危险区按钮的"按住"电平（按下反馈）----
    //   1 = 手指正按在危险区按钮的命中矩形里（策略层 disp/enc_top_disp.v 的
    //   `dz_prs_lvl = hit_held && dz_now_in`）。
    //   ★ 它**只改外观**，不参与任何"写寄存器"的判定：真正发声的是抬起那一拍的
    //     `dz_click`（按下点与抬起点都在按钮内），而且仍要在对话框里按 OK。
    //   ★ 为什么需要这一位：旧行为是"按下即进询问态"，而询问态一开模态遮罩立刻
    //     把危险区整块压暗（compose 的 C_DIM 那一支）⇒ 按下反馈**物理上不可能被
    //     看见**。所以反馈分两半：按住期间由本信号画内嵌框；进询问态之后由
    //     compose 的 `dz_keep` 让按钮矩形自己不被遮罩吃掉。
    input  wire        ui_dz_press,

    // ---- v42（㊴）：第二颗危险区按钮「恢复默认」的三条外观信号 ----
    //   ui_dz_press2 : 同 ui_dz_press，只是属于第 2 颗按钮（x 608..1019）。
    //   ui_dlg_kind  : 询问态在问哪一件事。0 = 清除锁存故障（标题行 13 / 正文 18）、
    //                  1 = 恢复默认（标题行 14 / 正文 19）。只影响"画哪一套文字"，
    //                  不影响任何写寄存器判定（那是策略层的事）。
    //   ui_rst_state : 恢复序列的结果，2'd0 = 空闲/无结果、2'd1 = 全部回读一致、
    //                  2'd2 = 有不一致。它只决定第 2 颗按钮描边的颜色（绿/红）——
    //                  "失败"这件事本身由 ✖ 字形承担（ui_rst_bad）。
    //   ui_rst_bad   : 15 位，P6 的 15 项逐项"没回读上"标志，位序 = 行*3 + 列
    //                  （行 0..4 = 5 个 88 px 行带，列 0..2 = 三列）。置位的那一项
    //                  在它的标题行右侧画一个红 ✖（见 bad_mark_*）。
    input  wire        ui_dz_press2,
    input  wire        ui_dlg_kind,
    input  wire [1:0]  ui_rst_state,
    input  wire [14:0] ui_rst_bad,

    // ---- v32（㉙）：spec §5.2 第四重冗余「可关闭的 2 Hz 闪烁」的开关 ----
    //   1 = 闪烁开（警示/故障的状态条反色块按 ~2 Hz 通断）；
    //   0 = 闪烁关（反色块常亮，即 ㉘ 的行为不变）。
    //   ★ 这一位是**显示侧偏好**，由策略层持有（disp/enc_top_disp.v 的 scr_blink），
    //     入口是 P6 标题带那颗主操作按钮（与 P1「标定」/ P4「展开」同一个矩形、
    //     同一个命中编号 HIT_TITLE_BTN，动作按页号分派）。复位默认开。
    //   ★ 它只作用在"反色块显不显示"，不改变状态判据本身 —— 所以把闪烁关掉以后，
    //     ㉗/㉘ 的判据（字形、中文文字、反色块）一字不动。
    input  wire        ui_blink_en,
    //   v60（T8）：演示模式（P6 开关）—— 关时一切照旧。
    input  wire        demo_on,

    // ---- v22：倍频编辑面板（策略层在 disp/enc_top_disp.v，交互在 disp/ui_panel.v）----
    //   pnl_on     : 面板开着时整个下半屏被面板接管（照 v19 模态的写法）
    //   pnl_inter  : 待应用倍频（编码 0 = 256），val_format 用它渲染字段 1
    //   pnl_prog   : 长按加速的进度 0..63（沿 [−]/[+] 按钮周长的**真圆环**，
    //                环带 26..30 px，见 §5.13 与 disp/ring_lut.v）
    //   pnl_press  : 当前被按住的控件号（P_MNS=1/P_PLS=2/P_SLD=3/P_KEY=7/P_FLD=8）
    //   pnl_pend   : 待应用值 ≠ 回读值（"待应用"黄态，spec 6.2）
    //   pnl_idx    : 档位 0..7（= inter 2,4,…,256 的档号）
    //   pnl_fld    : v44（㊶）活动字段，0 = ×倍频、1 = ÷分频（八档步进共用一套控件）
    //   pnl_didx   : v44（㊶）待应用分频码 0..7（div = 码 + 1 = 寄存器值）
    //   pnl_undo_avail : 有"上一次值"可回（spec 6.5 的「回到上一次值」）
    //   pnl_undo_inter : "上一次值"的倍频码（0 = 256）—— v24 用它画按钮标签
    //   pnl_undo_div   : "上一次值"的分频码（0 = ÷1）—— v44（㊶）起标签末尾也写 ÷M
    input  wire        pnl_on,
    input  wire [9:0]  pnl_inter,
    input  wire        pnl_fld,
    input  wire [2:0]  pnl_didx,
    input  wire [5:0]  pnl_prog,
    input  wire [3:0]  pnl_press,
    input  wire        pnl_pend,
    input  wire [2:0]  pnl_idx,
    input  wire        pnl_undo_avail,
    input  wire [9:0]  pnl_undo_inter,
    input  wire [2:0]  pnl_undo_div,

    // ---- v33（㉚）数字键盘（spec 6.3 的最后一条：数字键盘兜底）----
    //   几何与 disp/ui_panel.v 的 KPB_* / KP_* 是**两处共同契约**：
    //   命中判定（触摸矩形）在 ui_panel，绘制在这里，改一边必须改另一边。
    //   ★ 键盘是纯显示侧的输入法：它只改 pnl_inter（待应用值），
    //     写寄存器仍走 pnl_req → ui_edit 的两阶段提交 + 回读确认。
    input  wire        pnl_kp_on,     // 键盘模式（面板换成键盘）
    input  wire [3:0]  pnl_kp_d2,     // 三位 BCD，**右对齐**：d0 = 最后输入的那位
    input  wire [3:0]  pnl_kp_d1,
    input  wire [3:0]  pnl_kp_d0,
    input  wire [1:0]  pnl_kp_dig,    // 已输入位数 0..3（前导零不画）
    input  wire [3:0]  pnl_kp_sel,    // 当前按住的键（4'hF = 无）

    // ---- 面板 ----
    output reg  [23:0] lcd_rgb,
    output wire        de_o,          // 与 lcd_rgb 对齐的 de（面板侧当 lcd_de 用）
    output reg  [11:0] dbg_x,         // 调试：与 lcd_rgb 同拍的坐标
    output reg  [11:0] dbg_y
);

    // =========================================================================
    // 1. 版面常量（全部是 16 px 字符格的整数倍，便于格对齐）
    //    导航栏 80 px 宽；状态条 y<24；标题带 24..64；内容区 x>=80
    //    卡片 3 列 x 2 行：x = 96/416/736（宽 288），y = 64/336（高 256）
    //    ★ 卡片原点 96 = 导航栏 80 px + 16 px 内边距：卡片右沿 383/703/1023，
    //      内容一律不压进导航栏（旧值 32/352/672 让卡片 0 盖住导航栏右半）。
    //    ★ 三个原点都是 32 的倍数，所以数值层格列 = (card_x+32)/32 = 3/13/23，
    //      数值层格行 = y/64 = 2/7；卡片宽 288 = 整 9 个数值格 ——
    //      disp/val_format.v 的 f_col = 3/13/23、字段 0 的 f_wid = 9 必须与此一致。
    // =========================================================================
    localparam [11:0] NAV_W    = 12'd80;
    localparam [11:0] SBAR_H   = 12'd24;
    localparam [11:0] TITLE_H  = 12'd64;
    // ★ v59：总览卡片墙 3 列 x 2 行 -> 2 列 x 3 行。
    //   内容区 928 x 536：列 96 / 576（卡宽 448、列缝 32）、
    //   行 64 / 256 / 448（卡高 152、行缝 40，正好铺到 600）。
    //   行距 192 = 4 x 48：数值格高 48 px 时三行数值都落在
    //   格行 2 / 6 / 10 上（见 disp/val_format.v 的 f_row）。
    localparam [11:0] CARD_W   = 12'd448;
    localparam [11:0] CARD_H   = 12'd152;
    localparam [11:0] CARD_X0  = 12'd96;
    localparam [11:0] CARD_X1  = 12'd576;
    localparam [11:0] CARD_Y0  = 12'd64;
    localparam [11:0] CARD_Y1  = 12'd256;
    localparam [11:0] CARD_Y2  = 12'd448;

    // ---- 色板（沿用 docs/10_host_requirements.md 已冻结的浅色板）----
    localparam [23:0] C_BG    = 24'hEAF3FB;   // 页面底
    localparam [23:0] C_CARD  = 24'hFFFFFF;   // 卡片
    localparam [23:0] C_GRID  = 24'hD6E3F0;   // 网格/描边
    localparam [23:0] C_ACC   = 24'h2E7DD1;   // 主强调
    localparam [23:0] C_SEC   = 24'h8FC4EC;   // 次级强调（导航选中）
    localparam [23:0] C_NAV   = 24'hDCE9F5;   // 导航底
    localparam [23:0] C_TEXT  = 24'h1F2D3D;   // 正文
    localparam [23:0] C_OK    = 24'h3FA45B;   // 正常
    localparam [23:0] C_WARN  = 24'hE08B2D;   // 警示
    localparam [23:0] C_FAULT = 24'hD9453D;   // 故障
    localparam [23:0] C_BLACK = 24'h000000;   // 消隐
    localparam [23:0] C_DIM   = 24'h5A6B7A;   // v19 模态遮罩（无 alpha，用实色压暗）

    // ---- v19：状态条右端指示器 + P6 危险区 + 二次确认对话框 ----
    //   ★ 这几组坐标与 disp/hit_test.v 的对应参数是**两处共同契约**（改这里必须
    //     改那里，`disp/tb_hit_test_v58.v` 钉一半）：
    //     SBAR_SIG_CX / SBAR_ALM_CX                <->  hit_test 的导航/状态条矩形
    //     DZ_* / DLG_*                             <->  hit_test 的 DZ_* / DLG_*
    localparam [11:0] SBAR_SIG_CX = 12'd768;   // [信号 ●] 中心（指示器）
    localparam [11:0] SBAR_ALM_CX = 12'd832;   // [告警 ▲] 中心（指示器）
    //   ★ v58：[系统 ⚙] 与 P8 一起删除（原 SBAR_SYS_CX=896 / SBAR_SYS_W=64）。
    localparam [11:0] LAMP_X0     = 12'd960;   // 活性灯左沿（v19 前是 904，与原 ⚙ 档位重叠）
    //   ★ v33（㉝）：危险区从 944x80（y 520..599）改成 **944x96（y 504..599）**，
    //     对齐 spec 4.4 的字面值。为什么能到 96 而不是当年那个 88：
    //     P6 的 12 项排成 4 档（档距 128 px）后，**第 4 项的数值格是 y 448..511**，
    //     而字形只占格内 y=11..52（绝对 459..500）—— 格的下沿 8 px 是纯空白。
    //     危险区就把这 8 px 收回来：504..599 = 96 px，与数值格重叠的 504..511
    //     里没有任何墨迹。三样东西（区间 / 按钮 / 三角）的中心都是 y=552，
    //     而按钮文字本来就在 lab 格行 34（y 544..559，中心 552）⇒ 版面不用动。
    localparam [11:0] DZ_X0     = 12'd80;      // P6 底部危险区（画面，944x96）
    localparam [11:0] DZ_X1     = 12'd1024;    //   宽 944（x 80..1023）
    localparam [11:0] DZ_Y0     = 12'd504;     //   高 96（y 504..599，spec 4.4）
    localparam [11:0] DZ_Y1     = 12'd600;
    localparam [11:0] DZ_BTN_X0 = 12'd180;     // 「清除锁存故障」按钮（412x64）
    localparam [11:0] DZ_BTN_X1 = 12'd592;     //   x 180..591，中心 385.5
    localparam [11:0] DZ_BTN2_X0= 12'd608;     // 「恢复默认」按钮（412x64）
    localparam [11:0] DZ_BTN2_X1= 12'd1020;    //   x 608..1019，中心 813.5
    localparam [11:0] DZ_BTN_Y0 = 12'd520;     //   中心 y = 552 = 危险区中心
    localparam [11:0] DZ_BTN_Y1 = 12'd584;
    //   ★ v42（㊴）：两颗按钮**等宽对称**（各 412 px，间隔 16 px），标签仍在格行 34：
    //     第 1 颗「清除锁存故障」格列 21（x 336..431，中心 383.5）、第 2 颗「恢复默认」
    //     格列 49（x 784..847，中心 815.5）——两处都离自己按钮的中心 ≤2 px。
    //     与 tools/gen_text_ram.py 的 P6_LAB、tools/preview_pages.py 的 DZ_* 是三处
    //     共同契约；命中矩形在 disp/enc_top_disp.v 的 DZ_HIT_*/DZ2_HIT_*（各 ±8 px）。
    localparam [11:0] DLG_X0     = 12'd232;    // 二次确认对话框外框
    localparam [11:0] DLG_X1     = 12'd792;
    localparam [11:0] DLG_Y0     = 12'd196;
    localparam [11:0] DLG_Y1     = 12'd404;
    localparam [11:0] DLG_BTN_Y0 = 12'd324;    // 两个按钮（CANCEL / OK）
    localparam [11:0] DLG_BTN_Y1 = 12'd380;
    localparam [11:0] DLG_NO_X0  = 12'd272;
    localparam [11:0] DLG_NO_X1  = 12'd488;
    localparam [11:0] DLG_YES_X0 = 12'd536;
    localparam [11:0] DLG_YES_X1 = 12'd752;
    //   v41（㊳）：对话框文字住的三个 lab 格行。v19..v40 用的是 15/17/21（当时
    //   P6 的标题行在 3/11/19/27，这三行是它们之间的空白）。P6 改成 88 px 行带后
    //   标题墨迹落到 y 65..78 / 153..166 / 241..254 / 329..342 / 417..430，旧行 15
    //   （240..255）与 21（336..351）会压住第 3/第 4 项的标题（那两条标题会被模态
    //   排除吃掉）⇒ 迁到 13/18/22：与五条标题墨迹全不重叠、都在对话框框内
    //   （y 196..404），且 22 落在两个按钮矩形（y 324..380）里。
    //   ★ 行 22 同时是导航栏第 4 个页签「时序」（NAV 的格行 22、格列 1）⇒ 页面层
    //     对这一行的排除要再按格列门控（见下面 dlg_cell0 的 lcol2 >= 16）。
    localparam [5:0]  DLG_ROW0   = 6'd13;      // 标题（"清除锁存故障"）
    localparam [5:0]  DLG_ROW1   = 6'd18;      // 动作对象（"REG 0X0405"）
    localparam [5:0]  DLG_ROW2   = 6'd22;      // 两个动作共用的按钮标签（CANCEL / OK）
    //   v42（㊴）：「恢复默认」是第二套动作，它的标题/正文分住 14/19（lab 平面是静态
    //   RAM，同一格位只能有一个字符串）。哪一套在画由 ui_dlg_kind 选（见 dlg_title_row
    //   / dlg_body_row），而**页面层对五行全部排除**（13/14/18/19/22）—— 否则切换动作
    //   时另一套的字符串会当页面正文飘在设置项中间。
    localparam [5:0]  DLG_ROW3   = 6'd14;      // 恢复默认对话框标题（"恢复默认"）
    localparam [5:0]  DLG_ROW4   = 6'd19;      // 恢复默认动作对象（"REG 0X0100-051A"）
    //   v42：恢复默认失败时，在"没回读上的那一项"标题行右侧再画一个红 ✖（格列 12/32/52
    //   三个固定格位 + 行 4+k），字形码取 ASCII 的 ✖（font_rom 的 50 号）。见后面
    //   bad_mark_* 一段 —— 这是 spec §5.2「颜色绝不作为唯一的状态编码」的落实：
    //   失败既有颜色（红）也有字形（✖）。
    localparam [5:0]  BAD_COL0   = 6'd12;      // 第 0 列项的 ✖ 格位（x 192..207）
    localparam [5:0]  BAD_COL1   = 6'd32;      // 第 1 列项的 ✖ 格位（x 512..527）
    localparam [5:0]  BAD_COL2   = 6'd52;      // 第 2 列项的 ✖ 格位（x 832..847）
    localparam [7:0]  CH_XMARK   = 8'd50;      // ASCII_CHARS 的「✖」

    // ---- v20：标题带"主操作按钮" + P2/P3 页内 Tab 栏 ----
    //   ★ 坐标与 disp/hit_test.v 的 TBTN_* 是**两处共同契约**：
    //     - 按钮绘制 160x32（x 660..820 / y 28..60），命中矩形放大到 40 px 高
    //       （y 24..64，spec 6.1 的最小触控目标）——与状态条 ⚙ 同一套做法
    //       （画 24 px 高、命中 48 px）。
    //     - Tab 栏绘制 y 96..136（40 px == 最小触控目标），两个页签各 200 px 宽：
    //       SIM = x 96..296、XY = x 300..500。命中矩形与绘制同尺寸。
    //     - 两者都**故意不放进 hit_test 的矩形表**另一说：按钮放（它有独立编号
    //       15，与卡片/导航/⚙ 都不重叠），Tab 栏不放（它的矩形压在 P1 卡片 8/9 上，
    //       而 hit_test 不认识页号）⇒ Tab 由策略层按坐标 + 页号判。
    localparam [11:0] TBTN_X0 = 12'd660;
    localparam [11:0] TBTN_X1 = 12'd820;
    localparam [11:0] TBTN_Y0 = 12'd28;
    localparam [11:0] TBTN_Y1 = 12'd60;
    //   ★ v60（T8）：P6 状态栏右侧的「演示」开关（与「闪烁」并排，两者都是显示偏好）。
    //     与 disp/hit_test.v 的 DEMO_* 是两处共同契约。
    localparam [11:0] DEMO_BTN_X0 = 12'd840;
    localparam [11:0] DEMO_BTN_X1 = 12'd1000;
    localparam [11:0] DEMO_BTN_Y0 = 12'd28;
    localparam [11:0] DEMO_BTN_Y1 = 12'd60;
    localparam [11:0] TAB_Y0  = 12'd96;
    localparam [11:0] TAB_Y1  = 12'd136;
    localparam [11:0] TAB0_X0 = 12'd96;
    localparam [11:0] TAB0_X1 = 12'd296;
    localparam [11:0] TAB1_X0 = 12'd300;
    localparam [11:0] TAB1_X1 = 12'd500;

    // ---- v22：倍频编辑面板（spec §4.5/§6.2/§6.3/§6.5）----
    //   ★ 与 disp/ui_panel.v 的 `PNL_*` / `MNS_*` / `PLS_*` / `SLD_*` / `CCL_*` /
    //     `APL_*` / `BCK_*` 参数是**两处共同契约**（改一处必须同改另一处，否则
    //     画出来的按钮与命中矩形错位 —— hit_test 的矩形表就是这么被 tb 钉住的）。
    //   全部落在 16 px 文字格网上：x 96..928 = 格列 6..58、y 320..592 = 格行 20..37。
    //   ★ 只占**下半屏**（面板顶 y=320），上半屏（卡片 1、卡片 2 的大字）
    //     继续正常刷新，符合 spec §4.5「模态，只占下半屏，上半屏波形继续刷新」。
    //   两个步进按钮 64x64 = spec §6.1 的"主操作 56..64"；三个命令按钮 160x48
    //   = spec §6.1 的"标准 48"。
    localparam [11:0] PNL_X0 = 12'd96;
    localparam [11:0] PNL_X1 = 12'd928;
    localparam [11:0] PNL_Y0 = 12'd320;
    localparam [11:0] PNL_Y1 = 12'd592;
    localparam [11:0] MNS_X0 = 12'd160;    // [−]
    localparam [11:0] MNS_X1 = 12'd224;
    localparam [11:0] PLS_X0 = 12'd800;    // [+]
    localparam [11:0] PLS_X1 = 12'd864;
    localparam [11:0] STP_Y0 = 12'd464;
    localparam [11:0] STP_Y1 = 12'd528;
    localparam [11:0] SLD_X0 = 12'd240;    // 离散滑条：8 档 x 64 px = 512 px
    localparam [11:0] SLD_X1 = 12'd752;
    localparam [11:0] SLD_Y0 = 12'd448;
    localparam [11:0] SLD_Y1 = 12'd528;
    localparam [11:0] SLD_TRK_Y0 = 12'd472;   // 轨道与刻度
    localparam [11:0] SLD_TRK_Y1 = 12'd504;
    localparam [11:0] CCL_X0 = 12'd176;    // CANCEL
    localparam [11:0] CCL_X1 = 12'd336;
    localparam [11:0] APL_X0 = 12'd448;    // APPLY
    localparam [11:0] APL_X1 = 12'd608;
    localparam [11:0] BCK_X0 = 12'd720;    // BACK（回到上一次值）
    localparam [11:0] BCK_X1 = 12'd880;
    localparam [11:0] CMD_Y0 = 12'd528;
    localparam [11:0] CMD_Y1 = 12'd576;
    //   ---- v44（㊶）字段切换按钮（×倍频 ⇄ ÷分频）----
    //   64x64，放在面板上方的空白带、标题「倍频分频」（格列 7..12 = x 112..207）
    //   右侧；右边紧接着就是下面那块数值窗（KPV_X0 = 330），两者成一组。
    //   ★ 与 disp/ui_panel.v 的 FLD_* 是同一契约（命中在那边、绘制在这里）。
    localparam [11:0] FLD_X0 = 12'd240;
    localparam [11:0] FLD_X1 = 12'd304;
    localparam [11:0] FLD_Y0 = 12'd344;
    localparam [11:0] FLD_Y1 = 12'd408;

    // ---- v33（㉚）数字键盘几何（与 disp/ui_panel.v 的 KPB_* / KP_* 一一对应）----
    //   「键盘」入口按钮 64x64，在面板右上角空白区（[+] 上方 8 px、右侧 8 px）；
    //   键盘栅格 3 列 × 4 行、44x44、间距 8 px（= spec 6.1 的"最小 40"与"相邻 ≥8"），
    //   整体 148x200，左上角 (112,328) —— 正好落在键盘模式里唯一空着的一块。
    localparam [11:0] KPB_X0 = 12'd856;
    localparam [11:0] KPB_X1 = 12'd920;
    localparam [11:0] KPB_Y0 = 12'd392;
    localparam [11:0] KPB_Y1 = 12'd456;
    localparam [11:0] KP_X0  = 12'd112;
    localparam [11:0] KP_Y0  = 12'd328;
    localparam [11:0] KP_BTN = 12'd44;
    localparam [3:0]  KP_NO  = 4'hF;       // 没有键被按住（与 ui_panel 同值）
    //   输入窗：三位 48x80 大字段（disp/seg7.v 的 BIG）+ 1 px 外框
    localparam [11:0] KPV_X0 = 12'd330;
    localparam [11:0] KPV_X1 = 12'd572;
    localparam [11:0] KPV_Y0 = 12'd342;
    localparam [11:0] KPV_Y1 = 12'd442;
    localparam [11:0] KPV_DX = 12'd72;     // 三个字段的间距（48 宽 + 24 空隙）
    localparam [11:0] KPV_X  = 12'd340;    // 第一个字段的左上角
    localparam [11:0] KPV_Y  = 12'd352;

    // ---- P2 输入波形页版面（spec 4.4：双通道 944x440 + 右下 4 个 88x32 徽标）----
    //   ★ 轨迹区左沿 = 导航栏右沿 = 80，所以 P2 是**唯一不按 16 px 格布局**的
    //     页面：波形是 1 px 精度，与 lab/val 两层格无关。例外要写出来，
    //     否则下一个人会去找"为什么这页的格坐标对不上"。
    localparam [11:0] WAVE_X0   = 12'd80;
    localparam [11:0] WAVE_X1   = 12'd1024;
    localparam [11:0] WAVE_A_Y0 = 12'd100;    // ★ v58：Tab 栏删后上提 40 px
    localparam [11:0] WAVE_A_Y1 = 12'd320;    // A 通道 220 行
    localparam [11:0] WAVE_B_Y0 = 12'd340;
    localparam [11:0] WAVE_B_Y1 = 12'd560;    // B 通道 220 行

    // ---- P2 专用色 ----
    //   两条轨迹必须能区分，但**颜色不是唯一编码**（spec 5.2）：A/B 分处上下两个
    //   各自带中线和外框的区域，即使打印成黑白也读得出来 —— 颜色只是加速识别。
    localparam [23:0] C_PLOT = 24'hF7FBFF;    // 轨迹区底（比卡片底 FFFFFF 略冷，一眼看出框）
    localparam [23:0] C_TR_A = 24'h303F9F;    // A 通道轨迹（靛蓝）
    localparam [23:0] C_TR_B = 24'hC62828;    // B 通道轨迹（红，与 C_CH_B 同色）

    // ---- P3 李萨如 XY 页版面（spec 4.4："绘图区 560x560 居中（x=232..792，y=140..600）"）----
    //   ★ **spec 那一行自相矛盾**：x 232..792 是 560 宽没错，但 y 140..600 只有 460 高。
    //     560x560 同时"居中"需要 y=20..580，而 y=20 会插进标题带（24..64）。
    //     两个数字里只能信一个，这里**信坐标**（560 宽 x 460 高，紧贴标题带下方），
    //     因为坐标是能和其它页面拼在一起的量，尺寸不是。见 DEV_STATUS 的 U-15.7。
    localparam [11:0] XY_X0   = 12'd232;
    localparam [11:0] XY_X1   = 12'd792;      // 560 宽
    localparam [11:0] XY_Y0   = 12'd140;
    localparam [11:0] XY_Y1   = 12'd600;      // 460 高
    //   点阵区：192x192 位图，每格铺 2x2 屏上像素 => 384x384，在 560x460 的框里居中。
    //   384 是 2 的幂的倍数、192 是 3*64，两者都能整除掉，所以位图坐标 = 纯移位。
    localparam [11:0] XY_BX0  = 12'd320;      // 232 + (560-384)/2
    localparam [11:0] XY_BX1  = 12'd704;
    localparam [11:0] XY_BY0  = 12'd178;      // 140 + (460-384)/2
    localparam [11:0] XY_BY1  = 12'd562;

    // ---- P4 ABZ/UVW 时序页版面 ----
    //   v18：框宽改成 spec §4.5 的 944×340（x = 80..1023），轨迹区 856 px。
    //     上一版是 600 px（居中），当时的理由是"spec 那一行的数字配不平"：
    //     88（标签栏）+ 824（轨迹区）= 912 ≠ 944，而 824 px 也除不出整数个箱。
    //     现在换个取法把两个要求都满足：**以内容区宽度为准**（944 - 88 = 856），
    //     箱数仍然是 128（写口一个 clk 只能写一箱、电角度每拍前进约 503 个计数，
    //     一个电气周期只够写 ~130 箱 ⇒ 128 已是采集侧上限，见 disp/logic_scope.v
    //     的 v18 段），箱宽由 4 px 变成 6.6875 px —— 读地址用移位相加
    //     `(dx * 153) >> 10` 摊开，仍然没有乘法器（spec §7.2）。
    //     框高仍取 340：6 行 x 48 + 上下留白 12 + 时间轴条 28。
    //   ★ v58（R4）：用户要“波形纵向再大一点，填满页面”。
    //   旧版框只到 y=480，下面空 120 px（占屏 63%）。
    //   现在框下沿 596：6 行 x 68 = 408，加上上流 12 与时间轴条 24 正好填满
    //   （占屏 71% 高度、占内容区 96%）。时间轴竖列也随之下移到 572。
    localparam [11:0] LG_X0    = 12'd80;      // 内容区左沿（944 宽）
    localparam [11:0] LG_X1    = 12'd1024;
    localparam [11:0] LG_Y0    = 12'd100;
    localparam [11:0] LG_Y1    = 12'd596;     // 496 高
    localparam [11:0] LG_TX0   = 12'd168;     // 80 + 88，轨迹区左沿（标签栏 88）
    localparam [11:0] LG_TX1   = 12'd1024;    // 856 px = 128 箱摊开（见 logic_scope v18）
    localparam [11:0] LG_TOP   = 12'd112;     // 第 0 行上沿（框内留白 12）
    localparam [11:0] LG_ROW_H = 12'd68;      // 6 行 = 408，末行下沿 520
    //   ★ v58 补记：行边界必须由 LG_ROW_H 派生。上一版只把 LG_ROW_H 改成 68，
    //     像素通路里还留着 48 的比较链与 row*48 偏移 —— 于是文字层按 68 画、
    //     波形按 48 画，六行挤在 288 px 里、下面空出 172 px（上板一眼能看出来）。
    //     这里把阈值与偏移都改成派生常量，改行高就只改一行。
    localparam [11:0] LG_R1    = LG_ROW_H;      // 68
    localparam [11:0] LG_R2    = LG_ROW_H * 2;  // 136
    localparam [11:0] LG_R3    = LG_ROW_H * 3;  // 204
    localparam [11:0] LG_R4    = LG_ROW_H * 4;  // 272
    localparam [11:0] LG_R5    = LG_ROW_H * 5;  // 340
    localparam [11:0] LG_BAND_H = LG_ROW_H * 6; // 408（六行总高）
    localparam [11:0] LG_RAIL_HI = 12'd16;    // 行内高轨
    localparam [11:0] LG_RAIL_LO = 12'd44;    // 行内低轨（行高 68 内留上下各 16 余量）
    localparam [11:0] LG_AXIS  = 12'd560;     // 时间轴条上沿（刻度 561..570，轴标文字 576..591）

    //   六条通道各自的颜色。**颜色不是唯一编码**（spec 5.2）：六个通道各占一条
    //   独立的行、各自带动色标签块，即使打印成黑白也数得出来 —— 颜色只是加速识别。
    //   A/B 沿用 P2 的蓝/红，这样"上面那条波形"和"这里这条时序"是同一种颜色。
    //   ★ v58（R16/E）：旧配色（蓝/品红/绿/橙/紫/青）里 B 的品红与 U 的橙在
    //     这块屏上偏接近，A 的蓝与 W 的青也容易被认成同一档。换成下面这组：
    //     六个色相的间距 ≥ 43°，且 U 用**高明度琥珀**、W 用**低明度深青**，
    //     靠明度再拉一次距离 —— 灰度打印也能分出 6 档深浅。
    localparam [23:0] C_CH_A = 24'h303F9F;    // A 靛蓝（与 C_TR_A 同色，色相 235）
    localparam [23:0] C_CH_B = 24'hC62828;    // B 红（与 C_TR_B 同色）
    localparam [23:0] C_CH_Z = 24'h2E7D32;    // Z 绿
    localparam [23:0] C_CH_U = 24'hF9A825;    // U 琥珀（明度高，避开 B 的红）
    localparam [23:0] C_CH_V = 24'h7B1FA2;    // V 紫
    localparam [23:0] C_CH_W = 24'h00838F;    // W 青（色相 187，与 A 的 235 拉开 48°）

    // ---- P5 六状态表：spec §4.4 的严格几何（v30 / ㉖ 重排）----
    //   6 行 x 5 列，行高 30 px、列宽 188 px，含占比条形图列。
    //   ★ 30/188 与全局 16 px 文字格网不可通约（30/16 = 1.875、188/16 = 11.75），
    //     所以表格区走下面 §3 里那套"P5 虚拟格网"，而不是直接用
    //     pix_x[9:4]/pix_y[9:4] 当行列号。
    //   表框 x = 82..1021（5 x 188 = 940）、y = 128..338（(1 + 6) x 30 = 210；
    //   表头一行 + 六个数据行），行带上沿 = 128 + 30r、列左沿 = 82 + 188c。
    //   第 5 列（c = 4，x = 834..1021）里画比例条：起点 836、满量程 184 px，
    //   所以条长阈值由 p5_view 直接给成 0..188 的像素数（perm*193/1024），
    //   像素通路里仍然没有乘法器（spec 7.2 同一条理由）。
    localparam [11:0] P5_TX0    = 12'd82;     // 表格左沿（列 0 左边界）
    localparam [11:0] P5_TY0    = 12'd128;    // 表头上沿
    localparam [11:0] P5_TX1    = 12'd1022;   // 右开区间：82 + 5*188
    localparam [11:0] P5_TY1    = 12'd338;    // 下开区间：128 + 7*30
    localparam [11:0] P5_COL_W  = 12'd188;    // 列宽（spec）
    localparam [11:0] P5_ROW_H  = 12'd30;     // 行高（spec）
    localparam [11:0] P5_INSET  = 12'd6;      // 每列左右各内缩 6 px（11 x 16 + 12 = 188）
    localparam [11:0] P5_VINSET = 12'd7;      // 行带内上下各 7 px（16 px 字高居中于 30 px）
    localparam [11:0] P5_BAR_X0 = 12'd836;    // 第 5 列里比例条的起点
    localparam [11:0] P5_BAR_X1 = 12'd1020;   // 836 + 184（满量程）
    localparam [5:0]  P5_RAM_R0 = 6'd8;       // 表头行占用的 RAM 行号（数据行 = 9..14）
    localparam [23:0] C_TRACK   = 24'hDCE9F5; // 条形图的空槽（与导航未选中同色）

    // ---- P6 设置页的 88 px 行带（v41/㊳：spec §4.4 的"项高 88"字面值）----
    //   ★ 与 P5 同一条路线：88 与两套全局网格都不可通约（lab 格 16 px、val 格 64 px），
    //     所以用比较器算出"项号 k"与"带内 y = v"，再拿它们当 RAM 行号与字形 ROM 的
    //     "格内 y"。三处共同契约：本文件、disp/p6_view.v 的 f_row()/f_col()、
    //     tools/gen_text_ram.py 的 P6_LAB/P6_VAL —— 改一处必须同改另两处。
    //     5 x 88 = 440 px 铺满内容区 y 64..503，危险区 504..599 不动。
    //     标题（lab）：RAM 行 = 4 + k、格内 y = v（墨迹 v 1..14）
    //     数值（val）：RAM 行 = 1 + k、格内 y = v - 13（墨迹 v 24..65）
    //   ★ 标题 RAM 行必须从 4 起（不能从 3 起）：行 3 的**自然**位置是 y 48..63，
    //     落在 p6_area（pix_y >= 64）之外 ⇒ 自然映射会把「倍频」多画一行到
    //     第一行带上方当残留文字。取 4..8 时自然位置 y 64..143 全部落在带区里，
    //     由虚拟映射接管，不会漏画（㊳ 的 (100,55) 判据钉住这一点）。
    //   ★ 两层的"可见性"必须各自门控：不加的话同一个字形会在 88 px 带里按 16/64 px
    //     周期重复，而且负相位会回卷出伪墨迹（这条是 ㊳ 的判据钉住的）。
    localparam [11:0] P6_X0     = 12'd96;     // 内容左侧（导航栏 80 + 16 内边距）
    localparam [11:0] P6_TY0    = 12'd64;     // 第一条行带上沿
    localparam [11:0] P6_TY1    = 12'd504;    // 行带区下沿（= 危险区上沿）
    localparam [11:0] P6_VPH    = 12'd13;     // 数值层相位：格内 y = v - 13
    localparam [5:0]  P6_LAB_R0 = 6'd4;       // 标题 RAM 行起点（4..8；从 4 起的理由见上）
    localparam [3:0]  P6_VAL_R0 = 4'd1;       // 数值 RAM 行起点（1..5）

    // ---- P7 标定与误差可视化版面（v16）----
    //   左框：标定前/后两条误差曲线；右框：六个标定参数的当前值。
    //   曲线区 512 px = 128 个电角度箱 x 4 px —— 箱宽取 4 px 是为了让箱号
    //   只有一次右移（pix_x[8:2]），像素通路里不出现除法。
    localparam [11:0] P7_BX0  = 12'd96;    // 左框（曲线框）
    localparam [11:0] P7_BX1  = 12'd640;
    localparam [11:0] P7_BY0  = 12'd112;   // lab 格行 7
    localparam [11:0] P7_BY1  = 12'd480;   // v60（T6）：304 -> 368 px，左框下延
    localparam [11:0] P7_CVX0 = 12'd112;   // 曲线区左沿（lab 格列 7）
    localparam [11:0] P7_CVX1 = 12'd624;   // 112 + 512
    localparam [11:0] P7_CVY0 = 12'd160;   // 曲线区上沿（lab 格行 10）
    localparam [11:0] P7_CVY1 = 12'd400;   // v64：160+240，与 p7_view 写入的 0..239 对齐
                                            //   （原来 464 = 304 高，下半 64 px 永远画不到，
                                            //     再叠上 p7_ry[7:0] 截断就出现框底幽灵曲线）
    localparam [11:0] P7_RX0  = 12'd656;   // 右框（参数框）
    localparam [11:0] P7_RX1  = 12'd1008;
    //   图例色块：紧挨着 lab(8,30) 的"前"与 lab(8,34) 的"后"
    localparam [11:0] P7_SW0  = 12'd462;
    localparam [11:0] P7_SW1  = 12'd526;
    localparam [23:0] C_EPRE  = 24'hC2185B; // "标定前"曲线（品红）
    localparam [23:0] C_EPOST = 24'h2E7D32; // "标定后"曲线（绿）

    // =========================================================================
    // 2. 编码器数据抽头寄存（规则 3：只进寄存器，不复用其组合逻辑）
    // =========================================================================
    reg [15:0] q_angle, q_s_n, q_c_n;
    reg [31:0] q_pos_full;
    reg [7:0]  q_io_state, q_io_flags, q_stat;
    reg [9:0]  q_inter;
    reg [2:0]  q_div;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_angle <= 16'd0; q_s_n <= 16'd0; q_c_n <= 16'd0;
            q_pos_full <= 32'd0;
            q_io_state <= 8'd0; q_io_flags <= 8'd0; q_stat <= 8'd0;
            q_inter <= 10'd0; q_div <= 3'd0;
        end else begin
            // ★ v77（P2 38 µs 档撕裂）：sin/cos 改成**每拍都采**，不再门控在 de。
            //   原来这两路只在可见像素期间更新，消隐期是冻结值 —— 而 wave_trace
            //   的时基若连续推进（v77 已改），冻结样本就会被当成"新样本"写进
            //   944 列里，38 µs 档每行末尾多出 ~91 列平线，曲线仍然会在同一位置
            //   错位。两处必须同时满足：样本连续 + 时基连续。
            //   这两路只喂 wave_trace 与自检哈希（见下方 tap_xor），不参与其它
            //   按 de 对齐的逻辑，所以提前/继续更新不会影响别的通路。
            q_s_n <= tap_s_n; q_c_n <= tap_c_n;
            if (de) begin
                q_angle <= tap_angle;
                q_pos_full <= tap_pos_full;
                q_io_state <= tap_io_state; q_io_flags <= tap_io_flags; q_stat <= tap_stat;
                q_inter <= tap_cfg_inter; q_div <= tap_cfg_div;
            end
        end
    end

    // =========================================================================
    // 2a. 触摸诊断解包（位序契约见 disp/enc_top_disp.v 的 tch_diag 注释）
    //
    // 解包也进寄存器：tch_diag 本身是触摸控制器的寄存器输出，但直接拿它做
    // 比较会往像素路径上多挂一级组合；统一寄存后像素路径只看到 q_tch_*。
    //
    // ★ 为什么这里必须先于画页面而存在：上板时"触摸到底有没有在动"需要一个
    //   屏上可见的答案。只靠 ILA 会把时序余量从 0.959 压到 0.332（见
    //   docs/DEV_STATUS.md），而这个页面用现成的抽头就能看。三个计数器
    //   读数的含义是分层的：reads 恒为 0 = IIC 根本没跑；reads 与 nack 一起
    //   涨 = 从机不应答；reads 在涨、nack 为 0、点数恒为 0 = 通信正常但
    //   0x814E 永不刷新（本板历史上就是这个现象）。
    // =========================================================================
    wire [1:0]  tch_type_w    = tch_diag[1:0];
    wire [2:0]  tch_num_w     = tch_diag[4:2];
    wire [15:0] tch_x0_w      = tch_diag[20:5];
    wire [15:0] tch_y0_w      = tch_diag[36:21];
    wire [7:0]  tch_status_w  = tch_diag[44:37];
    wire [7:0]  tch_pid_w     = tch_diag[52:45];
    wire        tch_valid_w   = tch_diag[57];
    wire [23:0] tch_reads_w   = tch_diag[99:76];
    wire [23:0] tch_nack_w    = tch_diag[123:100];
    wire [23:0] tch_timeout_w = tch_diag[147:124];
    // P8 底栏那三个小数字用的量（同样是 tch_diag 里的位，见 enc_top_disp.v 的位序注释）
    wire [3:0]  tch_rst_w     = tch_diag[56:53];
    wire        tch_intpin_w  = tch_diag[74];
    wire        tch_toggle_w  = tch_diag[75];

    reg [1:0]  q_tch_type;
    reg [2:0]  q_tch_num;
    reg [15:0] q_tch_x0, q_tch_y0;
    reg [7:0]  q_tch_status, q_tch_pid;
    reg        q_tch_valid;
    reg [23:0] q_tch_reads, q_tch_nack, q_tch_timeout;
    reg [3:0]  q_tch_rst;
    reg        q_tch_intpin, q_tch_toggle;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_tch_type <= 2'd0; q_tch_num <= 3'd0;
            q_tch_x0 <= 16'd0; q_tch_y0 <= 16'd0;
            q_tch_status <= 8'd0; q_tch_pid <= 8'd0; q_tch_valid <= 1'b0;
            q_tch_reads <= 24'd0; q_tch_nack <= 24'd0; q_tch_timeout <= 24'd0;
            q_tch_rst <= 4'd0; q_tch_intpin <= 1'b0; q_tch_toggle <= 1'b0;
        end else if (de) begin
            q_tch_type <= tch_type_w; q_tch_num <= tch_num_w;
            q_tch_x0 <= tch_x0_w; q_tch_y0 <= tch_y0_w;
            q_tch_status <= tch_status_w; q_tch_pid <= tch_pid_w;
            q_tch_valid <= tch_valid_w;
            q_tch_reads <= tch_reads_w; q_tch_nack <= tch_nack_w;
            q_tch_timeout <= tch_timeout_w;
            q_tch_rst <= tch_rst_w; q_tch_intpin <= tch_intpin_w;
            q_tch_toggle <= tch_toggle_w;
        end
    end

    // ---- 触摸状态灯与十字准星的着色见第 5 节（需要用到 cx/cy 与 tch_alive，
    //      放在那里才不会"先用后声明"）----

    // =========================================================================
    // 2b. 测量与数值格式化（都跑在消隐期，不在像素路径上）
    //
    // 数据源说明：抽头带来的 pos_full 是编码器 48 位 pos_full 的低 32 位，
    // 其中有意义的只是低 22 位（{cycle_cnt[5:0], angle[15:0]}），每 64 个
    // 电周期回绕一次 —— 正好等于解回绕所需的一整圈，所以直接把低 22 位
    // 送进 freq_meter 即可，多一个周期也不会错。
    //
    // 频率不是"数闸门内的脉冲"（那需要把 A/B 边沿引进来，会动编码器），
    // 而是逐拍累加 pos_full 的有符号增量后在 1/64 s 闸门结算：
    //     f_in = Δ / 65536 / (1/64) = Δ / 1024
    // 所以闸门末的累加值本身就是 1/1024 Hz 定点的频率，通路无乘法无除法。
    // =========================================================================
    wire signed [21:0] fm_pos = tap_pos_full[21:0];
    wire signed [31:0] fm_f_q10;
    wire signed [47:0] fm_pos_acc;
    wire signed [1:0]  fm_dir;
    wire               fm_valid;

    freq_meter #(.CLK_HZ(50_000_000), .GATE_DIV(64)) u_freq_meter (
        .clk(clk), .rst_n(rst_n), .pos_full(fm_pos),
        .f_q10(fm_f_q10), .pos_acc(fm_pos_acc), .dir(fm_dir), .valid(fm_valid)
    );

    // 一帧一次的启动脉冲：取"最后一个有效像素"后一拍。
    // 消隐期有 239040 拍，val_format 全程约三百多拍，余量三个数量级。
    wire last_px = de && (pix_y == 12'd599) && (pix_x == 12'd1023);
    reg  last_px_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) last_px_d <= 1'b0;
        else        last_px_d <= last_px;
    end
    wire vf_start = last_px_d;

    wire        vf_we;
    wire [8:0]  vf_waddr;
    wire [5:0]  vf_wdata;
    wire        vf_busy, vf_done;
    // ★ v82：val_format 报的"每个字段实际字符数"（供 unit_lab 摆单位）
    wire [3:0]  vf_len_o;
    wire [2:0]  vf_fld_o;
    wire        vf_len_stb;

    // ---- v45（㊷）/ v46（㊸）空态判据：测量数据不可信 ⇒ 测量字段显示 '-'，
    //      四个测量卡状态条报 ✖ 故障 ----
    //   现存来源只有一个：`amp_gone` —— **无载波**（幅值掉到下限门限以下，v46 ㊸ 新增）。
    //   抽头 [126]/[375] 两个原链路判据源（帧 CRC 错 / 链路静默）在 v74 随从站模块
    //   删除后恒 0；两个端口保留（位图不重排），但不再进入本判据。
    //
    //   ★ v46（㊸）为什么加 `amp_gone`：㊷ 只覆盖了"帧来了但没过校验"，
    //     覆盖不了"编码器侧根本没信号"—— 审计原话是"编码器停摆时 P1 仍显示
    //     ● 正常 + 0.00 Hz"：载波没了、后台算出来的频率是 0，屏上却把它当成
    //     一个**合法读数**显示（docs/13:351 反模式 8）。
    //   ★ `amp_gone` 直接比**值**（`tap_amp_sq < tap_amp_low_sq`），而不是用
    //     抽头的 `[128] amp_bad` 标志：那个标志口径是 `amp_low | amp_high`
    //     （`rtl/SPEC_interface_contract.md:705-744` 的位序表），会把"幅值**偏高**"
    //     （前端过驱/偏置过大）也算进"没信号"。偏高是**质量**问题（卡 3 已经按
    //     amp_bad 报 ✖），不是"没有数据"。
    //     比较口径与器件侧完全一致：`rtl/amp_monitor.v:95` 的 `w_low = (amp32 < amp_low_sq)`
    //     （严格小于；门限写 0 = 关掉这条判据 ⇒ 恒不触发，见该文件 :32-33/:92-95）。
    //     `rtl/amp_monitor.v:6` 也把 amp_low 注释成"信号太弱，例如磁环脱落/气隙过大"
    //     —— 正是"编码器停摆/断线"在显示侧唯一可观测的形态。
    //   ★ 与"编码器**静止**"的区别（这是本判据最容易被误用成误判的地方）：
    //     静止 ⇒ 载波还在、幅值在窗口内，只是位置/频率是 0 ⇒ **照常显示 0.00**；
    //     停摆/断线 ⇒ 幅值塌到下限以下 ⇒ 空态。轮 D/轮 E 把这组区分钉死。
    //   ★ 为什么**不**把 cor_sat / amp_bad 这两个**标志位**并进来（这是 tb_disp_engine
    //     首跑 44 条红换来的口径，§[11b] 轮 B2 把它钉死）：
    //       这两个位已经**各自**落在卡片状态条的判据上 —— `st_rpm` 认 amp_bad
    //       （幅值直接影响转速换算）、`st_angle` 认 cor_sat（正交通道饱和直接影响
    //       角度）。把它们并进 `sig_bad` 会把"每张卡各自的口径"抹平成"四张测量卡
    //       全废"，反而丢信息（例如幅值变差时转速仍可信、但会被一起抹掉）。
    //       （v46 ㊸ 加的 `amp_gone` 不是这两个标志位中的任何一个：它只判"幅值低于
    //        下限"这一侧、而且是显示侧自己比出来的，见上面那两条 ★。）
    //   ⇒ 顶栏 `alert_fault = q_stat[0] | q_io_flags[7] | q_io_flags[6]`（信号质量问题）
    //     与这里（数据有无/可信问题）是**两个层次**，屏上不会自相矛盾：顶栏亮▲/✖的同时，
    //     只有真正不可信的读数才进空态。
    //   ★ v46（㊸）与轮 B2（`io_flags = 8'hF0` = amp_bad+cor_sat，且**帧本身是好的**）
    //     不冲突：那一条钉的是"信号**质量标志**不许抹平读数"，用的刺激是标志位；
    //     这里判的是"信号**有没有**"，用的是幅值**值**与门限的比较。两者可以同时为真
    //     也可以各自单独为真，语义不重叠（标志位管卡 3/卡 4 的各自口径，值比较管
    //     "还有没有一个载波"）。
    wire amp_gone = (tap_amp_sq < tap_amp_low_sq);   // 无载波：幅值低于下限门限
    //  v74：原链路判据两项随模块删除（端口保留、恒 0）⇒ 只剩"没有载波"一个源。
    wire sig_bad  = amp_gone;

    // ---- v60（R1）：把故障源**按卡拆开** ----------------------------------
    //   上板反馈：只接信号发生器（没有外接从站主机）时，六张卡全挂「✕ 故障」。
    //   实际上每张卡的数据源不同，应该各自判：
    //     卡 0 输入频率 / 卡 2 转速 / 卡 3 角度  —— 只靠模拟量（amp_gone）
    //     卡 4 累计转数            —— 靠内部多圈位置
    //     卡 1 倍频分频 / 卡 5 ABZ-UVW —— 纯配置与输入引脚，永远可信
    //   角度与转速不走链路：`tap_angle` 来自 CORDIC（对 ADC 的 SIN/COS 算），
    //   只要模拟载波在就有效。
    wire amp_bad_c = amp_gone;
    wire enc_bad_c = 1'b0;      // v74：卡 4 累计转数走内部多圈位置，不再依赖外部链路
    wire [5:0] bad_mask = {1'b0,        // card5 ABZ/UVW
                           enc_bad_c,   // card4 累计转数
                           amp_bad_c,   // card3 角度
                           amp_bad_c,   // card2 转速
                           1'b0,        // card1 倍频分频
                           amp_bad_c};  // card0 输入频率

    // =====================================================================
    // v60（T8）演示模式：只探信号发生器、没有外接从站主机时，可以在 P6 上把六张卡
    //   切成一组“看得出来是否工作”的演示值（１５００.00 Hz / 转速跟着走 / 角度慢慢旋转）。
    //   关时**一切照旧** —— 这一块不改任何数据源，只是在进 val_format 之前做一次 mux。
    //   为什么不探到 ADC/链路里：演示就是演示，不能让屏上出现一个“真实但虚假”的混合态。
    // =====================================================================
    reg [31:0] dm_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         dm_cnt <= 32'd0;
        else if (vf_start)  dm_cnt <= dm_cnt + 32'd37;   // 每帧 +37（与帧率互质，看上去在走）
    end
    wire signed [31:0] dm_f_q10 = 32'sd1536000;                  // 1500.00 Hz
    wire        [47:0] dm_pos    = {16'd0, dm_cnt[31:16], 8'd0}; // 累计转数慢慢走
    wire        [15:0] dm_ang    = dm_cnt[23:8];                 // 顶部不断回绕 ⇒ 角度在转
    wire        [7:0]  dm_io     = {2'b0, dm_cnt[25:23], 3'b0};  // A/B/Z 位随计数器走

    wire signed [31:0] vfs_f_q10  = demo_on ? dm_f_q10 : fm_f_q10;
    wire        [47:0] vfs_pos    = demo_on ? dm_pos    : fm_pos_acc;
    wire        [15:0] vfs_angle  = demo_on ? dm_ang    : q_angle;
    wire        [7:0]  vfs_io     = demo_on ? dm_io     : q_io_state;
    wire        [5:0]  vfs_bad    = demo_on ? 6'd0      : bad_mask;

    val_format #(.CPR(CPR)) u_val_format (
        .clk(clk), .rst_n(rst_n), .start(vf_start),
        .f_q10(vfs_f_q10), .pos_acc(vfs_pos), .angle(vfs_angle),
        .io_state(vfs_io), .cfg_inter(q_inter), .cfg_div(q_div),
        .cfg_pairs(tap_cfg_pairs),
        // v22：面板开着时字段 1 显示"待应用值"（spec 6.2 的"待应用"态）
        // v44（㊶）：倍频与分频**都**显示待应用值（面板现在两个字段都能改）
        .pnl_on(pnl_on), .pnl_inter(pnl_inter), .pnl_div(pnl_didx),
        .nodata_mask(vfs_bad),
        .we(vf_we), .waddr(vf_waddr), .wdata(vf_wdata),
        .busy(vf_busy), .done(vf_done),
        // v82：字符数上报（单位动态摆放）
        .len_o(vf_len_o), .fld_o(vf_fld_o), .len_stb(vf_len_stb)
    );

    // ---- ★ v58：P8 系统信息页整页删除（用户 R7）----
    //   连同它的三个写者一起拿掉：touch_view（触摸诊断 9 字段）、
    //   band_view（底栏三个小数字）、selftest_lab（自检结论）。
    //   省下 2 块 text RAM + 约 400 LUT。触摸诊断的原始计数仍在本模块端口上，
    //   顶层的触摸链路照旧工作，只是不再有页面把它们画出来。

    // ---- P6 设置页那 9 个数字走的是**自己的字段表**（v14 新增）----
    //   写口从 v13 起就一直空着，当时那段注释写了理由：val_format 的 6 个字段
    //   坐标是按 P1 卡片排布定死的（格行 2/7、格列 2/12/22），而 P6 的设置项在
    //   格行 1/4/7 —— 把 vf_waddr 接过来只会把配置值写成输入频率/转速。
    //   所以缺的从来不是写口，是"按页切换字段表"的格式化器，也就是本模块。
    //   三个显示口径（倍频 0→256、分频编码 +1、极对数 0→32）在 p6_view 里做。
    wire        p6v_we;
    wire [8:0]  p6v_waddr;
    wire [5:0]  p6v_wdata;
    wire        p6v_busy, p6v_done;

    p6_view u_p6_view (
        .clk(clk), .rst_n(rst_n), .start(vf_start),
        .cfg_inter(tap_cfg_inter), .cfg_div(tap_cfg_div), .cfg_pairs(tap_cfg_pairs),
        .cfg_hyst_ab(tap_cfg_hyst_ab), .cfg_ablimit(tap_cfg_ablimit),
        .cfg_zwidth(tap_cfg_zwidth), .cfg_zphase(tap_cfg_zphase),
        .cfg_uvwph(tap_cfg_uvwph), .cfg_pol(tap_cfg_pol),
        // v19：第 4 行三项（ABZ / UVW / SHIFT）—— 三个信号早就在本模块端口上
        .cfg_abzen(tap_abzen), .cfg_uwven(tap_uwven), .cfg_shift(tap_shift),
        // v41（㊳）：第 5 行三项（增益S / 增益C / 相位修正）—— v15 起就在本模块端口上
        .cfg_gain_s(tap_gain_s), .cfg_gain_c(tap_gain_c), .cfg_phase_k(tap_phase_k),
        .we(p6v_we), .waddr(p6v_waddr), .wdata(p6v_wdata),
        .busy(p6v_busy), .done(p6v_done)
    );

    // ---- ★ v58：P5 六状态表整页删除（用户 R5）----
    //   连 p5_view（851 LUT）一起拿掉。P5 的绘制代码仍在下面（页号 4 空着），
    //   但页使能 p5_lg 已被钉成常量 0，综合会把整枝剪掉。
    wire [7:0] p5_bar_t0 = 8'd0, p5_bar_t1 = 8'd0, p5_bar_t2 = 8'd0;
    wire [7:0] p5_bar_t3 = 8'd0, p5_bar_t4 = 8'd0, p5_bar_t5 = 8'd0;

    // ---- P7 标定与误差可视化（v16 新增）----
    //   三块 128 箱小 RAM：
    //     acc_ram   每箱 32 bit = {hi[15:0], lo[15:0]}，记 amp_sq[30:15] 的 min/max
    //     bef/aft   每箱 16 bit = {hi_y[7:0], lo_y[7:0]}，已换算成**屏上行号**
    //   ★ 显示侧存行号而不是原始幅值：像素通路里只允许两次区间比较
    //     （spec §7.2 禁实时栅格化），换算在 p7_view 的消隐期做完。
    //   ★ 两块显示 RAM 用**同一个箱号**读，两拍数据在同一拍返回，所以像素通路
    //     只需要再补**一级**寄存器就与 px2 对齐（与 P2/P3 的同一条规则，见 U-16）。
    //   ★ 读地址用未延迟的 pix_x，和文字平面完全一样 —— 声明必须在这里，
    //     Verilog-2001 按文本顺序解析标识符（本项目已踩过三次 VRFC 10-3380）。
    wire [11:0] p7_dx        = pix_x - P7_CVX0;
    wire [6:0]  p7_bin       = p7_dx[8:2];   // 512 px / 4 px = 128 箱
    wire [6:0]  p7_bef_raddr = p7_bin;
    wire [6:0]  p7_aft_raddr = p7_bin;

    wire        p7v_we;
    wire [11:0] p7v_waddr;
    wire [7:0]  p7v_wdata;
    wire        p7v_busy, p7v_done;
    // ★ v85：p7_gate_lab（0%/100% 闸线标签）随"绝对幅值口径"一起删掉 ——
    //   新标尺是固定的 ±2%（零线居中），刻度标签是静态的（tools/gen_text_ram.py
    //   的 P7_LAB：+2% / 0 / -2%），不再需要每帧重写的坐标。
    //   因此 p7_view 的 hold 恒接 0，文字层只由 p7_view 一个写者驱动。
    wire        p7_acc_we, p7_bef_we, p7_aft_we;
    wire [6:0]  p7_acc_waddr, p7_bef_waddr, p7_aft_waddr;
    wire [31:0] p7_acc_wdata;
    wire [15:0] p7_bef_wdata, p7_aft_wdata;
    wire [6:0]  p7_acc_raddr;
    wire [31:0] p7_acc_rdata;
    wire [15:0] p7_bef_rdata, p7_aft_rdata;

    p7_view u_p7_view (
        .clk(clk), .rst_n(rst_n), .start(vf_start), .hold(1'b0),
        .angle(q_angle), .amp_sq(tap_amp_sq), .calib_busy(tap_calib_busy),
        .amp_low_sq(tap_amp_low_sq), .amp_high_sq(tap_amp_high_sq),
        .ofs_s(tap_ofs_s), .ofs_c(tap_ofs_c),
        .gain_s(tap_gain_s), .gain_c(tap_gain_c),
        .phase_k(tap_phase_k), .shift(tap_shift),
        .acc_we(p7_acc_we), .acc_waddr(p7_acc_waddr), .acc_wdata(p7_acc_wdata),
        .acc_raddr(p7_acc_raddr), .acc_rdata(p7_acc_rdata),
        .bef_we(p7_bef_we), .bef_waddr(p7_bef_waddr), .bef_wdata(p7_bef_wdata),
        .aft_we(p7_aft_we), .aft_waddr(p7_aft_waddr), .aft_wdata(p7_aft_wdata),
        .we(p7v_we), .waddr(p7v_waddr), .wdata(p7v_wdata),
        .busy(p7v_busy), .done(p7v_done)
    );

    // ★ v85：p7_gate_lab 实例删除（标签改成 P7_LAB 里的静态 +2% / 0 / -2%）

    p7_ram #(.DW(32), .INIT({16'd0, 16'hFFFF})) u_p7_acc_ram (
        .clk(clk), .we(p7_acc_we), .waddr(p7_acc_waddr), .wdata(p7_acc_wdata),
        .raddr(p7_acc_raddr), .rdata(p7_acc_rdata)
    );
    p7_ram #(.DW(16), .INIT({8'd120, 8'd120})) u_p7_bef_ram (
        .clk(clk), .we(p7_bef_we), .waddr(p7_bef_waddr), .wdata(p7_bef_wdata),
        .raddr(p7_bef_raddr), .rdata(p7_bef_rdata)
    );
    p7_ram #(.DW(16), .INIT({8'd120, 8'd120})) u_p7_aft_ram (
        .clk(clk), .we(p7_aft_we), .waddr(p7_aft_waddr), .wdata(p7_aft_wdata),
        .raddr(p7_aft_raddr), .rdata(p7_aft_rdata)
    );

    // =========================================================================
    // 3. 两层字符格 + 字符 RAM
    //    lab : 64 x 38 格，格 16x16，字符码 7 bit（44 ASCII + 66 汉字，font_rom_lab）
    //          ASCII 字形 10x14 左对齐占行高 10 位，汉字 16x16 满格
    //    val : 32 x 10 格，格 32x64，字形 30x42，码 6 bit（只 ASCII，font_rom_val）
    // =========================================================================
    // ---- S0：格坐标与读地址 ----
    wire [5:0] lab_cx = pix_x[9:4];                 // 0..63
    wire [5:0] lab_cy = pix_y[9:4];                 // 0..37

    // ---- v30（㉖）：P5 表格区的"虚拟格网" ----
    //   P5 的表格按 spec 是 行高 30 / 列宽 188 / 6 行 x 5 列，与全局 16 px 文字
    //   格网**不可通约**（30/16 = 1.875、188/16 = 11.75）。这里把它折算成
    //   "RAM 里的 (行, 列)" + "格内 (x, y)"，供三个流水级各取所需：
    //     · S0 用它当 lab RAM 的读地址（行 = 8 + rr，列 = c*11 + gx[7:4]）
    //     · S1 用它当字形 ROM 的格内 y（gy = 行带内 y - 7）
    //     · S2 用它当字形位图的取位相位（gx = 列内 x - 6，MSB = 最左）
    //   三处共同契约：本文件、disp/p5_view.v 的 f_row()/f_col()、
    //   tools/gen_text_ram.py 的 P5_LAB。改一处必须同改另两处。
    //   ★ 30 与 188 都不是 2 的幂，所以行带号/列号用比较器 + 减法做（各 3~4 级），
    //     不上除法器：这一段在 S0 的组合路径上（RAM 地址建立），多一个除法器
    //     就会顶掉建立余量。
    wire        p5_tab0 = (page == 3'd4) && (pix_x >= P5_TX0) && (pix_x < P5_TX1) &&
                          (pix_y >= P5_TY0) && (pix_y < P5_TY1);
    wire [11:0] p5_vdx  = pix_x - P5_TX0;                 // 0..939
    wire [11:0] p5_vdy  = pix_y - P5_TY0;                 // 0..209
    wire [2:0]  p5_rr   = (p5_vdy >= 12'd180) ? 3'd6 :
                          (p5_vdy >= 12'd150) ? 3'd5 :
                          (p5_vdy >= 12'd120) ? 3'd4 :
                          (p5_vdy >= 12'd90)  ? 3'd3 :
                          (p5_vdy >= 12'd60)  ? 3'd2 :
                          (p5_vdy >= 12'd30)  ? 3'd1 : 3'd0;
    wire [11:0] p5_rtop = (p5_rr == 3'd6) ? 12'd180 : (p5_rr == 3'd5) ? 12'd150 :
                          (p5_rr == 3'd4) ? 12'd120 : (p5_rr == 3'd3) ? 12'd90 :
                          (p5_rr == 3'd2) ? 12'd60  : (p5_rr == 3'd1) ? 12'd30 : 12'd0;
    wire [11:0] p5_sy   = p5_vdy - p5_rtop;               // 行带内 y：0..29
    wire [2:0]  p5_c    = (p5_vdx >= 12'd752) ? 3'd4 :
                          (p5_vdx >= 12'd564) ? 3'd3 :
                          (p5_vdx >= 12'd376) ? 3'd2 :
                          (p5_vdx >= 12'd188) ? 3'd1 : 3'd0;
    wire [11:0] p5_clft = (p5_c == 3'd4) ? 12'd752 : (p5_c == 3'd3) ? 12'd564 :
                          (p5_c == 3'd2) ? 12'd376 : (p5_c == 3'd1) ? 12'd188 : 12'd0;
    wire [11:0] p5_sx   = p5_vdx - p5_clft;               // 列内 x：0..187
    wire [11:0] p5_gx   = p5_sx - P5_INSET;               // 格内 x：0..175 有效
    wire [11:0] p5_gy   = p5_sy - P5_VINSET;              // 格内 y：0..15 有效
    wire        p5_vvis = p5_tab0 && (p5_sx >= P5_INSET) &&
                          (p5_sx < P5_INSET + 12'd176) &&
                          (p5_sy >= P5_VINSET) && (p5_sy < P5_VINSET + 12'd16);
    wire [5:0]  p5_cbase = {p5_c, 3'b0} + {p5_c, 1'b0} + {3'd0, p5_c};   // c*11
    wire [5:0]  p5_vrow  = P5_RAM_R0 + {3'd0, p5_rr};                    // 8..14
    wire [5:0]  p5_vcol  = p5_cbase + p5_gx[7:4];                        // 0..54

    // ---- P6 的 88 px 行带虚拟格网（v41/㊳）----
    //   常量见 §1 的 P6_*（内容区 y 64..503 = 5 x 88，危险区 504..599 不动）。
    //   与 P5 的差别：P5 的行带号直接就是 RAM 行号（8 + rr）；P6 要把"项号 k"映射到
    //   "标题 RAM 行 3 + k / 数值 RAM 行 1 + k"，而且两层各自的"格内 y"不同
    //   （标题 = v、数值 = v - 13）—— 所以除了两处地址 mux，还有两处 row_in_cell
    //   mux 与两处可见性门（后者都在像素流水线里，见 §3）。
    //   ★ 对话框文字的三个 lab 行（DLG_ROW0/1/2）**不在**虚拟映射里：那些像素走自然
    //     映射（行 = pix_y[9:4]），否则模态文字会被虚拟地址吃掉。13/18/22 三个行号
    //     分别落在 88 px 行带 1/2/3 内，所以这个排除不是可选项。
    //   ★ 数值层的地址不做这个排除（数值层没有借用行），只有可见性做窗口门控。
    wire        p6_area = (page == 3'd5) && (pix_x >= P6_X0) &&
                          (pix_y >= P6_TY0) && (pix_y < P6_TY1);
    wire [11:0] p6_vy   = pix_y - P6_TY0;                 // 0..439
    wire [2:0]  p6_k    = (p6_vy >= 12'd352) ? 3'd4 :
                          (p6_vy >= 12'd264) ? 3'd3 :
                          (p6_vy >= 12'd176) ? 3'd2 :
                          (p6_vy >= 12'd88)  ? 3'd1 : 3'd0;
    wire [11:0] p6_ktop = (p6_k == 3'd4) ? 12'd352 : (p6_k == 3'd3) ? 12'd264 :
                          (p6_k == 3'd2) ? 12'd176 : (p6_k == 3'd1) ? 12'd88 : 12'd0;
    wire [11:0] p6_v    = p6_vy - p6_ktop;                // 带内 y：0..87
    wire        p6_dlg  = (lab_cy == DLG_ROW0) || (lab_cy == DLG_ROW1) ||
                          (lab_cy == DLG_ROW2) || (lab_cy == DLG_ROW3) ||
                          (lab_cy == DLG_ROW4);
    wire        p6_map  = p6_area && !p6_dlg;
    wire [5:0]  p6_lrow = P6_LAB_R0 + {3'd0, p6_k};       // 4..8
    wire [3:0]  p6_vrow = P6_VAL_R0 + {1'b0, p6_k};       // 1..5
    wire [11:0] p6_vg   = p6_v - P6_VPH;                  // 门控后 0..52（见 p6_vvis）
    wire        p6_lvis = p6_map && (p6_v < 12'd16);      // 标题墨迹窗口（v 1..14）
    wire        p6_vvis = p6_area && (p6_v >= P6_VPH) &&
                          (p6_v < P6_VPH + 12'd53);       // 数值墨迹窗口（v 24..65）
    //   两层的"清零"信号（供 S2 用，见流水线那一段）：
    wire        p6_lbl_off = p6_map  && !p6_lvis;         // 虚拟映射里、窗口外 ⇒ 清零
    wire        p6_val_off = p6_area && !p6_vvis;         // 行带区里、窗口外   ⇒ 清零

    wire [11:0] lab_raddr = p5_tab0 ? {p5_vrow, p5_vcol} :
                            (p6_map  ? {p6_lrow, lab_cx} : {lab_cy, lab_cx});

    wire [4:0] val_cx = pix_x[9:5];                 // 0..31
    // ★ v59：P1 的数值格高从 64 px 降到 48 px（字形 30x48 正好满格），
    //   因为 2 列 x 3 行的卡片高 152 px，64 px 的格子放不下三行。
    //   48 = 3 x 16：行号 = floor(y / 48)。不用除法器 —— 在 y < 608 范围内
    //   (n * 43) >> 7 与 floor(n/3) 完全等价（n = y >> 4），只需一个常量乘法
    //   加一次右移，比 12 位除法器便宜得多。
    //   格内扫描行 = y - 48*row + 8：字库仍按 64 行格存（字形在 8..55），
    //   这样 ROM 布局、font_rom 地址拼接、其它四页全不受影响。
    wire [11:0] p1_n16   = {8'd0, pix_y[9:4]};
    wire [13:0] p1_mul   = p1_n16 * 12'd43;
    wire [3:0]  p1_vcy   = p1_mul[13:7];
    wire [11:0] p1_cy48  = ({8'd0, p1_vcy} << 5) + ({8'd0, p1_vcy} << 4);
    wire [5:0]  p1_vg    = pix_y - p1_cy48 + 12'd8;
    wire [3:0] val_cy = (page == 3'd0) ? p1_vcy : pix_y[9:6];
    wire [8:0] val_raddr = p6_area ? {p6_vrow, val_cx} : {val_cy, val_cx};

    // 每页一对 RAM，读出来的选择就是一个 3 选 1 —— 页数少时这样没有填充浪费。
    // 页数多到 LUTRAM 放不下时，再改成单块 BRAM + 页号拼进高位地址。
    //   ★ v23：lab 码宽从 7 bit 升到 8 bit（字库 136 码 > 128），所以这八条
    //     线、lab_ch_raw 以及下面四块 lab RAM 的 wdata 常量全部变宽一位。
    //     这是"两处共同契约"里 RTL 那一处，另一处是 tools/gen_font_rom.py 的
    //     PLANES[lab].idx_w 与 tools/gen_text_ram.py 的 LAB_CODE_W。
    wire [7:0] lab_ch_p1, lab_ch_p2, lab_ch_p4, lab_ch_p6, lab_ch_p7;
    wire [5:0] val_ch_p1, val_ch_p6;
    // ★ v58：P3/P5/P8 三页删除 ⇒ 它们的文字层/数值层输入直接引常量 0。
    //   页号保留空洞（0/1/3/5/6），mux 里那几档仍在，只是喂 0。
    wire [7:0] lab_ch_p3 = 8'd0;
    wire [7:0] lab_ch_p5 = 8'd0;
    wire [7:0] lab_ch_p8 = 8'd0;
    wire [5:0] val_ch_p8 = 6'd0;
    // ★ P5 是**纯文字层页**：表格用的是 16 px 小字格（lab 平面），数字由 p5_view
    //   每帧写进 lab 平面的空列 ⇒ P5 的 val 平面没有任何内容，这一档直接接常量 0。
    //   不例化"一块全 0 的空 RAM"：综合器会先证明它恒为 0 再删掉它，日志里多出
    //   "Unused sequential element ... was removed" / "RAM ... got removed" 两条警告，
    //   描述的却是同一件"本来就没用"的事。写成常量，日志和代码就说同一句话。
    //   ★ 声明**必须**在这个 mux 之前：Verilog-2001 按文本顺序解析标识符，
    //     用在前、声明在后会报 VRFC 10-3380（本项目已踩过三次）。
    //   教训（U-17 记录 28）：mux 少接一档不会报错，只会让那一页的字形通路
    //   变成 z -> X，整页像素采样全成 XXXXXX；"跑满帧/查帧率"这类检查一条都不红。
    wire [5:0] val_ch_p5 = 6'd0;
    // ★ P7 与 P5 同类：六个参数与幅值都写在 16 px 小格上，val 平面没有内容，
    //   照 P5 的写法接常量 0（不例化空 RAM，理由同上）。
    wire [5:0] val_ch_p7 = 6'd0;
    // ★ v17：P2/P3/P4 也各补了一块 lab 平面（标题 / 通道名 / 轴标）。
    //   它们的 val 平面是空的（数字不走 32 px 大格），同样接常量 0。
    //   ⚠ 这一档**必须显式写出来**：val 的 default 分支是 val_ch_p1，漏掉就会把
    //     P1 的六个大数字叠到 P2/P3/P4 上 —— 这正是当初把这三页排除在文字层之外的
    //     原因（当时的选择是"整页不画字"，代价是连标题和导航标签都没了）。
    wire [5:0] val_ch_p2 = 6'd0;
    wire [5:0] val_ch_p3 = 6'd0;
    wire [5:0] val_ch_p4 = 6'd0;
    wire [7:0] lab_ch_raw = (page == 3'd5) ? lab_ch_p6 :
                            (page == 3'd7) ? lab_ch_p8 :
                            (page == 3'd6) ? lab_ch_p7 :
                            (page == 3'd4) ? lab_ch_p5 :
                            (page == 3'd1) ? lab_ch_p2 :
                            (page == 3'd2) ? lab_ch_p3 :
                            (page == 3'd3) ? lab_ch_p4 : lab_ch_p1;
    wire [5:0] val_ch_raw = (page == 3'd5) ? val_ch_p6 :
                            (page == 3'd7) ? val_ch_p8 :
                            (page == 3'd6) ? val_ch_p7 :
                            (page == 3'd4) ? val_ch_p5 :
                            (page == 3'd1) ? val_ch_p2 :
                            (page == 3'd2) ? val_ch_p3 :
                            (page == 3'd3) ? val_ch_p4 : val_ch_p1;

    //   ★ v42（㊴）：恢复默认**失败**时，在"没回读上的那一项"标题行右侧补一个红 ✖。
    //     位置 = 三列各自的固定格列（BAD_COL0/1/2 = 12/32/52，在数值格左沿附近）
    //     × 行带自己的标题格行（4..8，与 P6_LAB 的标题行同一组）。因为 P6 的行带是
    //     虚拟的，这里用 lab_cy 直接判"是不是某条标题行的第 k 带"：
    //       lab_cy = 4 + k（k = 0..4）且 lab_cx == BAD_COLn ⇒ 第 (k, n) 项失败。
    //     `ui_rst_bad` 的位序 = k*3 + n（与 ui_restore 的输出一致）。
    //     ★ 它**只覆盖送进字形 ROM 的字符码**（见下面的 lab_ch_ovr），字形取 ASCII
    //       的 ✖（CH_XMARK = 50）；着色在 S2（bad_mark2）：只有该像素确实是这一格的
    //       字形墨迹时（lab_bit）才涂红，宁静区仍走正常底色/压暗逻辑。
    //   ★ 用行带号 p6_k（不是自然格行 lab_cy）！P6 的行带是虚拟的：第 k 带的标题墨迹
    //     落在自然 y = 64+88k .. +15，横跨 1~2 个自然格行（第 1 带 = y 152..167 ⇒
    //     lab_cy = 9/10）。第一版按 lab_cy-4 选带 ⇒ 只有第 0 带能中，其余四带的 ✖
    //     永远画不出来（= 判据会"证伪得不明不白"）。这里改成 p6_map（行带区、
    //     且不在对话框行上）+ 带内标题窗口 p6_v < 16 + 三列固定格列。
    wire [3:0]  bad_col3   = (lab_cx == BAD_COL0) ? 4'd0 :
                             (lab_cx == BAD_COL1) ? 4'd1 :
                             (lab_cx == BAD_COL2) ? 4'd2 : 4'd3;
    wire [4:0]  bad_bit_i  = {2'd0, p6_k} * 4'd3 + {2'd0, bad_col3[1:0]};
    wire        bad_mark_cell = (page == 3'd5) && (ui_rst_state == 2'd2) && p6_lvis &&
                                (bad_col3 != 4'd3) && ui_rst_bad[bad_bit_i];
    wire [7:0] lab_ch_ovr = bad_mark_cell ? CH_XMARK : lab_ch_raw;

    // 标签层写口：P1 的这一块**只**给面板的「↩ 回到 ×N」按钮标签用
    //   （disp/undo_lab.v，v24），其余页面的 lab 平面写口分别归
    //   p2_badge / p5_view / p7_view / band_view，都在下面各自的例化里。
    // 数值层写口由 val_format / touch_view / p6_view 每帧消隐期重写 —— 卡上的读数
    // 和 P6 的设置项都是**真实寄存器值的回读**，不是预置的假数字。
    // ⚠ 运行期改写只写当前页（waddr 里**不含**页号），所以每个格式化器的字段
    //   坐标对每一页都是同一套；换页后数值层会由下一帧重新写满。
    wire        ul_we;
    wire [11:0] ul_waddr;
    wire [7:0]  ul_wdata;
    wire        ul_busy;      // 写序列进行中（当前没有第二个写者要仲裁，留作探针）
    wire        ul_done;      // 写序列结束单拍

    undo_lab u_undo_lab (
        .clk(clk), .rst_n(rst_n), .start(vf_start),
        .avail(pnl_undo_avail), .inter(pnl_undo_inter), .div(pnl_undo_div),
        .we(ul_we), .waddr(ul_waddr), .wdata(ul_wdata),
        .busy(ul_busy), .done(ul_done)
    );

    // ★ v30：P1 六张卡的迷你状态条（spec 4.3 / 5.2 的状态字模）。
    //   同一个写口上的第二个写者：行号与 undo_lab 从不冲突（15/36 对 34），
    //   所以只需要一个优先权 mux —— 面板标签优先，stat_chip 在 hold 拍上停一拍
    //   （不写、不推进索引），等空闲拍再写。结果与顺序无关，只影响第几拍写完。
    wire        sc_we;
    wire [11:0] sc_waddr;
    wire [7:0]  sc_wdata;
    wire        sc_busy;      // 写序列进行中（探针）
    wire        sc_done;      // 写序列结束单拍（探针）
    wire [11:0] sc_chip_st;   // 六卡状态 {2bit x6}（探针/测试用）

    stat_chip u_stat_chip (
        .clk(clk), .rst_n(rst_n), .start(vf_start),
        .io_flags(q_io_flags), .stat(q_stat), .bad_mask(vfs_bad),
        .hold(ul_we),
        .chip_st(sc_chip_st),
        .we(sc_we), .waddr(sc_waddr), .wdata(sc_wdata),
        .busy(sc_busy), .done(sc_done)
    );

    // ★ v48（㊺）A2：P1 卡 4 次级信息的 `pos_full` 十六进制（spec §4.5 :188）。
    //   同一个写口上的第三个写者，行号 35 与 undo_lab(34) / stat_chip(15,36) 不冲突 ⇒
    //   优先权 mux：面板标签 > 状态条 > 本模块。hold 给"前两个正在写"的那一拍。
    wire        ph_we;
    wire [11:0] ph_waddr;
    wire [7:0]  ph_wdata;
    wire        ph_busy;      // 写序列进行中（探针）
    wire        ph_done;      // 写序列结束单拍（探针）

    pos_hex u_pos_hex (
        .clk(clk), .rst_n(rst_n), .start(vf_start),
        .pos_full(q_pos_full),
        .hold(ul_we | sc_we),
        .we(ph_we), .waddr(ph_waddr), .wdata(ph_wdata),
        .busy(ph_busy), .done(ph_done)
    );

    // ---- v51（㊽）B4：面板上"算出来的两个数"（spec §6.3 :284）----
    //   等效倍率 = inter/div、预测 AB 边沿率 = 4 × 等效倍率 × f_in；只在面板开着时
    //   每帧算一次（串行除法，全在垂直消隐期）。写口排在仲裁的最后一位：
    //   标签(ul) > 状态条(sc) > 十六进制(pos_hex) > 本模块。
    //   ★ hold 必须把前三个写口都算进来 —— 组合 we 的写法下"晚一拍写"就是丢一格
    //     （U-49 的 pos_hex 就是因为时序 we 每帧丢一格才发现的）。
    wire        pc_we;
    wire [11:0] pc_waddr;
    wire [7:0]  pc_wdata;
    wire        pc_busy, pc_done;

    pnl_calc u_pnl_calc (
        .clk(clk), .rst_n(rst_n),
        .pnl_on(pnl_on), .inter_enc(pnl_inter), .div_code(pnl_didx),
        .f_q10(fm_f_q10),
        .start(vf_start), .sig_bad(sig_bad),
        .hold(ul_we | sc_we | ph_we),
        .waddr(pc_waddr), .wdata(pc_wdata), .we(pc_we),
        .busy(pc_busy), .done(pc_done)
    );

    // ---- v52（㊾）A3：卡 6 次级行 `U● V● W○`（spec §4.5 :190）----
    //   8 格落在标签层 行 26 列 46..53（卡 6 标题 `ABZ/UVW` 在行 22、大数字在行 7，
    //   中间这条是空的；行 23/25 的列 36..46 已被 U-52 的面板两行占用）。
    //   写口排在仲裁的最后一位：标签(ul) > 状态条(sc) > 十六进制(pos_hex) >
    //   面板数字(pnl_calc) > 本模块。hold 同样必须把前四个写口都算进来。
    wire        uv_we;
    wire [8:0]  uv_waddr;
    wire [5:0]  uv_wdata;
    wire        uv_busy, uv_done;

    uv_state u_uv_state (
        // ★ v83（任务B）：卡 6 的两行改成**同字号**（都走数值面 30x48）⇒ 本模块
        //   从标签层搬到数值层：waddr/wdata 变成 9 bit / 6 bit，写口也从 P1 标签层
        //   换到 P1 数值层（见下面 p1_val_ram 的写口 mux）。
        //   start 改接 vf_done：本模块用的是"本帧"的 uvw 电平，必须等 val_format
        //   把本帧的字段 5 写完、让出数值层写口之后再动，否则会和它撞同一拍。
        .clk(clk), .rst_n(rst_n), .start(vf_done),
        .uvw(q_io_state[5:3]),          // {w,v,u}
        .hold(vf_we),                   // 数值层写口同一拍只能有一个写者
        .we(uv_we), .waddr(uv_waddr), .wdata(uv_wdata),
        .busy(uv_busy), .done(uv_done)
    );

    // ---- v77：卡 6 左下角「Z计数」的数值（spec 4.3 的 Z 计数）----
    //   为什么在显示侧自己数：rtl/enc_top.v 的 z_pulse_cnt 只挂在寄存器
    //   0x054A..0x054D 上，没有进 tap 端口，而本版不许动 rtl/。判据相同
    //   （Z 上升沿），数据源换成 tap 里的 Z 电平。
    //   写口排在仲裁最后一位：标签(ul) > 状态条(sc) > 十六进制(pos_hex) >
    //   面板数字(pnl_calc) > UVW 电平(uv_state) > 本模块。
    wire        zc_we;
    wire [11:0] zc_waddr;
    wire [7:0]  zc_wdata;
    wire        zc_busy, zc_done;

    z_cnt_lab u_z_cnt_lab (
        .clk(clk), .rst_n(rst_n), .start(vf_start),
        .z(q_io_state[2]),                     // {w,v,u,z,b,a} 里的 z
        // ★ v83：uv_state 已改到数值层，不再占标签层写口 ⇒ hold 里去掉 uv_we。
        .hold(ul_we | sc_we | ph_we | pc_we),
        .we(zc_we), .waddr(zc_waddr), .wdata(zc_wdata),
        .busy(zc_busy), .done(zc_done)
    );

    // ★ v82（任务B）：四个单位（kHz/RPM/DEG/REV）跟着数值长度走 —— 见
    //   disp/unit_lab.v 的头注释。这里只负责把 val_format 报上来的
    //   "本字段实际字符数"按字段号存下来；上电默认值 = 字段满宽，于是首帧
    //   之前画面与 v79 的静态版面一致（21/19/49/23 列）。
    reg  [3:0] u_len_fin, u_len_rpm, u_len_ang, u_len_rev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_len_fin <= 4'd7;     // f_wid(0)
            u_len_rpm <= 4'd6;     // f_wid(2)
            u_len_ang <= 4'd7;     // f_wid(3)（v83：6 -> 7，见 val_format.v）
            u_len_rev <= 4'd8;     // f_wid(4)
        end else if (vf_len_stb) begin
            case (vf_fld_o)
                3'd0: u_len_fin <= vf_len_o;
                3'd2: u_len_rpm <= vf_len_o;
                3'd3: u_len_ang <= vf_len_o;
                3'd4: u_len_rev <= vf_len_o;
                default: ;
            endcase
        end
    end

    wire        un_we;
    wire [11:0] un_waddr;
    wire [7:0]  un_wdata;
    wire        un_busy;

    // ★ v83：uv_state 搬到数值层 ⇒ 标签层写口的仲裁链里不再有它。
    wire [11:0] p1_waddr = ul_we ? ul_waddr : (sc_we ? sc_waddr :
                           (ph_we ? ph_waddr : (pc_we ? pc_waddr :
                           (zc_we ? zc_waddr : un_waddr))));
    wire [7:0]  p1_wdata = ul_we ? ul_wdata : (sc_we ? sc_wdata :
                           (ph_we ? ph_wdata : (pc_we ? pc_wdata :
                           (zc_we ? zc_wdata : un_wdata))));
    wire        p1_we    = ul_we | sc_we | ph_we | pc_we | zc_we | un_we;

    unit_lab u_unit_lab (
        // ★ v83（任务B）：start 从 vf_start 改接 vf_done —— 单位落点是
        //   2*字段实际字符数 + 1，若与 val_format 同时起跑，拿到的 len 是
        //   **上一帧**的（角度每帧走 ~110°，字符数经常在 5↔6 之间跳），
        //   数字一变长单位就落晚一格、被数字压住（上板 "DEG 被 -293.2 压住"）。
        //   等 val_format 把六个字段全写完再动，len 一定是本帧的。
        .clk(clk), .rst_n(rst_n), .start(vf_done),
        .hold(ul_we | sc_we | ph_we | pc_we | zc_we),
        .len_fin(u_len_fin), .len_rpm(u_len_rpm),
        .len_ang(u_len_ang), .len_rev(u_len_rev),
        .we(un_we), .waddr(un_waddr), .wdata(un_wdata), .busy(un_busy)
    );

    p1_lab_ram u_p1_lab_ram (
        .clk(clk), .we(p1_we), .waddr(p1_waddr), .wdata(p1_wdata),
        .raddr(lab_raddr), .rdata(lab_ch_p1)
    );
    // ★ v58：P2 右下角四枚徽标（VPP-PC / F-HZ / DT-US / DV-PC）删除 —— 用户 R2。
    //   它是历史信息量最低、却最贵的一块（p2_badge：585 LUT + 3 个 DSP）。

    // ★ v17：P2/P3/P4 的静态版面（页标题 + 通道名/轴标 + 底栏注）。
    //   ★ v75（A）：P2 底栏的窗宽是运行期值（三档时基可切），由 p2_win_lab
    //     每帧重写第 36 行的 9..13 格；静态版面里那 5 格是默认档 "300US"。
    //     这块 RAM 的写口自 v58 删掉 p2_badge 后一直悬空（p2b_* 原来是隐式线网，
    //     宽 1 bit、实际没驱动），这次一并补成显式线网并接上写者。
    wire        p2b_we;
    wire [11:0] p2b_waddr;
    wire [7:0]  p2b_wdata;
    wire        p2b_busy, p2b_done;

    p2_win_lab u_p2_win_lab (
        .clk(clk), .rst_n(rst_n), .start(vf_start), .gear(p2_gear),
        .we(p2b_we), .waddr(p2b_waddr), .wdata(p2b_wdata),
        .busy(p2b_busy), .done(p2b_done)
    );

    p2_lab_ram u_p2_lab_ram (
        .clk(clk), .we(p2b_we), .waddr(p2b_waddr), .wdata(p2b_wdata),
        .raddr(lab_raddr), .rdata(lab_ch_p2)
    );
    // ★ v58：P3 删页 ⇒ 这块 text RAM 不再例化（省 1 块 RAMB36）。
    //   ★ v79：本块的写口不再是悬空的 1'b0 —— 写者是 p4_dbg_lab（例化在下面
    //     u_p4_scope 之后，因为它要读 p4_scope 的 dbg_* 抽头）。
    //     ★ 但写口这四根线必须**在这里先声明**：Verilog-2001 的按名端口连接会
    //     在第一次出现时做"隐式 net 声明"（VRFC 10-2938：already implicitly
    //     declared），后面再 wire 一遍就是重复声明 ⇒ 必须提早到本行之前。
    wire        p4d_we;
    wire [11:0] p4d_waddr;
    wire [7:0]  p4d_wdata;
    wire        p4d_busy, p4d_done;
    p4_lab_ram u_p4_lab_ram (
        .clk(clk), .we(p4d_we), .waddr(p4d_waddr), .wdata(p4d_wdata),
        .raddr(lab_raddr), .rdata(lab_ch_p4)
    );
    p6_lab_ram u_p6_lab_ram (
        .clk(clk), .we(1'b0), .waddr(12'd0), .wdata(8'd0),
        .raddr(lab_raddr), .rdata(lab_ch_p6)
    );
    // ★ v58：P8 删页 ⇒ lab/val 两块 RAM 都不再例化（省 2 块 RAMB36）。
    // ★ v58：P5 删页 ⇒ 这块 text RAM 不再例化（省 1 块 RAMB36）。
    p7_lab_ram u_p7_lab_ram (
        // v16：标题/两个框标题/图例/六个参数名来自 initial 静态预置，
        // 六个参数值与幅值由 p7_view 每帧覆写（字段表见 disp/p7_view.v，
        // 列位置与 tools/gen_text_ram.py 的 P7_LAB 是两处共同契约）。
        // ★ v85：唯一写者就是 p7_view（闸线标签模块已删）。
        .clk(clk), .we(p7v_we),
        .waddr(p7v_waddr),
        .wdata(p7v_wdata),
        .raddr(lab_raddr), .rdata(lab_ch_p7)
    );
    p1_val_ram u_p1_val_ram (
        // val_format 的字段坐标是按 P1 卡片排布定死的（数值层格行 2/6/10/11、
        // 格列 3/18），所以它只在 P1 页有效：写口用页号门控。
        // ★ v83（任务B）：卡 6 的 `U● V● W○` 从标签层搬到这里（uv_state），
        //   于是这块 RAM 有两个写者。仲裁规则：uv_state 在 val_format 写的那拍
        //   被 hold 住（见 u_uv_state 的 .hold），两者永不撞拍；地址也不相交
        //   （val_format 的字段 5 已下移到格行 11，uv_state 只写格行 10 的 18..25）。
        .clk(clk), .we((vf_we | uv_we) & (page == 3'd0)),
        .waddr(vf_we ? vf_waddr : uv_waddr),
        .wdata(vf_we ? vf_wdata : uv_wdata),
        .raddr(val_raddr), .rdata(val_ch_p1)
    );
    p6_val_ram u_p6_val_ram (
        // v14 起写口交给 p6_view（字段表见 disp/p6_view.v 的头注释）。
        // 页号门控在这里而不是在 RAM 里：P1/P6 的地址空间完全重叠（都是
        // {格行,格列}），同一拍只能让一个格式化器写，否则两页互相踩。
        .clk(clk), .we(p6v_we & (page == 3'd5)), .waddr(p6v_waddr), .wdata(p6v_wdata),
        .raddr(val_raddr), .rdata(val_ch_p6)
    );
    // ★ v58：P8 删页 ⇒ 这块 val RAM 不再例化。
    // P5 没有 val 平面内容（它是纯文字层页）—— val_ch_p5 是常量 0，
    // 声明见上面 lab/val 选择器那一段。

    // ---- P2 输入波形：轨迹表（双缓冲）----
    //   采样器把两路 16 bit 样本压成"每列一条线段"，写进**不显示**的那一面；
    //   帧首换面。像素通路只做一次区间比较 —— 见 disp/wave_trace.v 的头注释。
    wire        wt_we;
    wire [10:0] wt_waddr;
    wire [31:0] wt_wdata;
    wire [10:0] wt_wr_ptr;
    wire        wt_wr_buf, wt_disp_buf;
    wire [31:0] wave_q;

    wave_trace u_wave_trace (
        .clk(clk), .rst_n(rst_n), .frame_st(vf_start),
        // ★ v17：扫描按可见像素推进（原来消隐期也推进，写进 367 列冻结样本，
        //   屏上最左 ~367 列成了一条平线 —— 上板照片 x 80..447 就是它）。
        .de(de),
        .s_n(q_s_n), .c_n(q_c_n),            // 已打过一拍的抽头寄存器（规则 3）
        // ★ v75（A）：时基三档由策略层的触摸判定给出（见 wave_trace.v 的注释）。
        .gear(p2_gear),
        .we(wt_we), .waddr(wt_waddr), .wdata(wt_wdata),
        .wr_ptr(wt_wr_ptr), .wr_buf(wt_wr_buf), .disp_buf(wt_disp_buf)
    );

    //   读地址用 pix_x（S0 组合）给出，与文字平面的读法一致。
    //   ★ 输出只补**一级**（wave_d1）而不是两级。推导：RAM 的 `rdata <= mem[raddr]`
    //     本身已经是一级，而 raddr 用的是**未延迟**的 pix_x ⇒ 第 n+1 拍 mem 给出的
    //     是 pix_x(n) 的内容，而同一拍的 px2 = pix_x(n-1)：**数据比坐标早一格**。
    //     再补一级正好对齐；补两级会让整条波形右移 1 px（不报错，只是横移）。
    //   ★ 这条只能用**移动光栅**验证（disp/tb_pipe_align.v）：把坐标停在一点上采样时
    //     数据通路无论几级都会收敛到同一个值，级数根本测不出来（v15 的两张页面
    //     测试台就是这么漏掉它的）。
    wire [9:0]  wave_col   = pix_x[9:0] - 10'd80;
    wire [10:0] wave_raddr = {wt_disp_buf, wave_col};

    wave_ram u_wave_ram (
        .clk(clk), .we(wt_we), .waddr(wt_waddr), .wdata(wt_wdata),
        .raddr(wave_raddr), .rdata(wave_q)
    );

    reg [31:0] wave_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wave_d1 <= 32'h6363_6363;
        else        wave_d1 <= wave_q;
    end

    // ---- P3 李萨如 XY：点阵存储 + 描点器 ----
    //   ★ 读地址直接从 **pix_x / pix_y**（S0 组合）给出，与文字平面、波形表同一
    //     个时基；输出只补**一级**（xy_d1），与 P2/P4 的实时数据通路级数**必须相同**。
    //     推导见上面 P2 那段（"数据比坐标早一格"）。多补一级会让整个点阵右移 1 px，
    //     不报错，只是"看起来有点歪"。
    // ★ v58：P3 李萨如页整页删除（用户：连 XY 一起删，留 5 页）。
    //   页使能钉成常量 0 ⇒ 下面整枝 P3 绘制逻辑被综合剪掉；
    //   同时撤掉 xy_plot（采样/写缓冲）与 xy_ram（128 Kbit = 4 块 RAMB36，
    //   是显示子系统里单笔最大的一块 BRAM）。
    wire p3_xy     = 1'b0;
    wire in_xy_bmp = 1'b0;
    wire [11:0] xy_dx = 12'd0;
    wire [11:0] xy_dy = 12'd0;
    wire [7:0]  xy_bx = 8'd0;
    wire [7:0]  xy_by = 8'd0;
    wire        xy_disp_buf = 1'b0;
    wire        xy_q = 1'b0;

    reg xy_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) xy_d1 <= 1'b0;
        else        xy_d1 <= xy_q;
    end

    // ---- P4 ABZ/UVW 时序：按电角度装箱的等效时间存储 ----
    //   ★ **一级**寄存，不是两级。级数不是照抄来的，是推出来的：
    //     RAM 的 `rdata <= mem[raddr]` 本身已经是一级，而 raddr 用的是 S0 的
    //     pix_x —— 所以在第 n+1 拍，mem 给出的是 **pix_x(n)** 的内容，而同一拍
    //     的 px2 = pix_x(n-1)。也就是"数据比坐标早一格"。再补**一级**正好对齐。
    //     补两级的话数据会比坐标晚一格：屏上看不出"错"，只会在框里横移 1 px。
    //     这条推导在 disp/tb_pipe_align.v 里用**移动光栅**验证过（stationary 采样
    //     的测试台测不出级数，见 U-16 的说明）。
    wire p4_lg  = (page == 3'd3);
    //   轨迹区像素偏移（10 位回绕）。框内恒在 0..855（见 lg_tband），框外回绕值
    //   只在 logic_scope 里被 in_tx 挡掉，不会产生越界索引。
    wire [9:0] lg_dx = pix_x[9:0] - LG_TX0[9:0];
    //   ★ v60（T7）：换成触发式时域捕获（disp/trace_cap.v）。
    //   原来的 logic_scope 按电角度分 128 箱重建，只有 A/B 与电角度锁相时才稳；
    //   信号源单独喂 A/B 时每一帧相位都不同，屏上就是“流动”的方波。
    //   现在：2 us/点、触发点对齐、双缓存整帧换图 ⇒ 波形稳定，仍然每 1 ms 左右刷新一次。
    //   ★ v75（B）：再改成**双窗口按角度分箱**（disp/p4_scope.v）——
    //   2 µs/点的单窗口里，A/B 每电周期跳 32*inter/100 次、U/V/W 只看得见半段
    //   斜坡、Z 每回合 1 个脉冲根本不出现（docs/38 的 P0-5）。角度分箱后
    //   上半区 64 箱 = 4 个 A 周期、下半区 128 箱 = 1 个电周期，两者同时采、
    //   不新增 BRAM（64x2 + 128x4 bit 全在 LUTRAM 里）。
    //   armed 恒 1：角度分箱天然相位确定，不需要等触发（见 p4_scope.v 头注释）。
    //   ★ v77：每箱**只存电平**；箱边界上的跳变由 p4_scope 内部用同一级流水
    //     现算成 qv/qlv（见 p4_scope.v 头注释的"根因"段：竖线若放在像素通路里
    //     比"当前箱 vs 上一箱"，会因为读口三级流水错位而整帧消失）。
    //     行 0/1 = A/B 取上半区 {b,a}；行 2..5 = Z/U/V/W 取下半区 {w,v,u,z}。
    //     行号 -> 位序仍与 lg_row 比较链、tools/gen_text_ram.py 的 P4_LAB 同契约。
    //   ★ v78：**改成单次触发示波器**（每 500 ms 采一帧、采满即冻结）。三处变化：
    //     1) 抽头从 q_angle/q_io_state（被 de 门控，消隐期冻结）换成**连续的**
    //        tap_angle/tap_io_state。采样窗口只有 256 个 clk，一旦落进消隐期，
    //        冻结样本会把整屏写成平线 —— 这与 2 节里 q_s_n/q_c_n 改连续的理由同源。
    //     2) 端口去掉 inter/qpu/qpl：时基不再靠 inter 分箱，改成现场测 A 周期与
    //        电周期（见 p4_scope.v 的 §1/§2），换速度时窗口自己跟着缩放。
    //     3) 新增 qz：Z 的窄脉冲（几个 clk 宽，256 点抽稀必然漏掉）用"边沿标记位"
    //        单独带出来，屏上画成该列的竖标。
    //        ★ 为什么不能靠采样电平碰运气：inter=32、zwidth 默认值下 Z 只有
    //        6 个 clk 宽，下区采样周期 8 clk ⇒ 命中概率约 3/4 都是"漏"，
    //        而 Z 的相位又固定在某个电角度上，漏掉就会整帧不出现。
    wire [1:0]  lg_qu, lg_qv;
    wire [3:0]  lg_ql, lg_qlv;
    wire        lg_qz;
    wire        lg_armed;
    wire [15:0] lg_frames;
    //   ★ v79：屏上自证抽头（见 disp/p4_dbg_lab.v 文件头）。上板空白时靠这三个数
    //     判断卡在"过零/触发/写指针"哪一环，不必改 rtl/ 加寄存器。
    wire [20:0] lg_dbg_eclk;
    wire [7:0]  lg_dbg_wp;
    wire [1:0]  lg_dbg_enok;
    wire        lg_dbg_cd, lg_dbg_tmo;
    // v84：窗口长度 / U 相交叉校验 / 无信号标志都上屏（见 disp/p4_dbg_lab.v 文件头）
    wire [21:0] lg_dbg_win;
    wire        lg_dbg_upok, lg_dbg_nocap;
    wire [2:0]  lg_dbg_scnt;
    wire [15:0] lg_dbg_urise;
    p4_scope u_p4_scope (
        .clk(clk), .rst_n(rst_n),
        .angle(tap_angle), .io6(tap_io_state[5:0]),
        .pairs(tap_cfg_pairs),
        .dx(lg_dx),
        .qu(lg_qu), .qv(lg_qv),
        .ql(lg_ql), .qlv(lg_qlv), .qz(lg_qz),
        .armed(lg_armed), .frames(lg_frames),
        .dbg_eclk(lg_dbg_eclk), .dbg_wp(lg_dbg_wp), .dbg_enok(lg_dbg_enok),
        .dbg_cd(lg_dbg_cd), .dbg_tmo(lg_dbg_tmo),
        .dbg_win(lg_dbg_win), .dbg_upok(lg_dbg_upok), .dbg_scnt(lg_dbg_scnt),
        .dbg_nocap(lg_dbg_nocap), .dbg_urise(lg_dbg_urise)
    );

    // ---- P4 页右上角的屏上自证读数（v79）----
    //   写 16 个十六进制数字格到 p4_lab_ram（该 RAM 的写口在 v78 之前一直悬空，
    //   所以这是零成本加写者）；有数据后顺带把静态的 "NO CAPTURE" 擦成空格。
    //   位置与 tools/gen_text_ram.py 的 P4_LAB 是两处共同契约。
    //   ★ p4d_* 的声明在文件上方 u_p4_lab_ram 之前（端口连接处会隐式声明）。
    p4_dbg_lab u_p4_dbg_lab (
        .clk(clk), .rst_n(rst_n), .start(vf_start), .hold(1'b0),
        .frames(lg_frames), .win(lg_dbg_win), .eclk(lg_dbg_eclk), .wp(lg_dbg_wp),
        .enok(lg_dbg_enok), .upok(lg_dbg_upok), .scnt(lg_dbg_scnt),
        .nocap(lg_dbg_nocap),
        .we(p4d_we), .waddr(p4d_waddr), .wdata(p4d_wdata),
        .busy(p4d_busy), .done(p4d_done)
    );

    //   电平 6 位（行 0..5）+ 样本边界跳变 6 位（同一行序，同一拍）+ Z 竖标 1 位。
    wire [5:0] lg_q6  = {lg_ql[3], lg_ql[2], lg_ql[1], lg_ql[0], lg_qu[1], lg_qu[0]};
    wire [5:0] lg_qv6 = {lg_qlv[3], lg_qlv[2], lg_qlv[1], lg_qlv[0], lg_qv[1], lg_qv[0]};

    reg [5:0] lg_w, lg_ew, lg_ew_d;
    reg       lg_wz;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lg_w <= 6'd0; lg_ew <= 6'd0; lg_ew_d <= 6'd0; lg_wz <= 1'b0; end
        else        begin
            lg_w    <= lg_q6;
            lg_ew   <= lg_qv6;
            lg_ew_d <= lg_ew;
            lg_wz   <= lg_qz;
        end
    end

    // ---- S1：坐标与 de 对齐延迟 + 字形 ROM 读 ----
    //   ★ 字形数据**不再多打一拍**。理由（disp/sim/smoke_p1.v 第一次跑就抓到了）：
    //     ROM 自己的输出已经是寄存的。"再存进 lab_glyph2"会让字形比 px2/py2 晚一拍，
    //     而装载判据用的是 px2 的格边界 ⇒ 每个格显示的是**前一个格**的字符，
    //     于是整页文字右移整整一格（lab 移 16 px、val 移 32 px）。
    //     修前实测：导航 "MAIN" 落在 x=32（应在 x=16），数值 "1500.00" 落在 x=96（应在 x=64）。
    //     对齐契约：第 k 拍 lab_bits = 格(px2(k)) 的字形，row = py2(k) 的格内 y。
    reg [11:0] px1, py1, px2, py2;
    reg        de1, de2, de3;
    wire [15:0] lab_bits;
    wire [29:0] val_bits;

    // v30：P5 虚拟格网的三处流水对齐（见下面 lab_bit 的注释）
    reg        p5_tb1, p5_tb2, p5_vis1, p5_vis2;
    reg [3:0]  p5_gy1, p5_gx1, p5_gx2;

    // v41（㊳）：P6 的 88 px 行带虚拟格网同样要对齐到 S1（字形 ROM 的"格内 y"）
    //   与 S2（两层的可见性）。用"_off"两个信号把"该点的字形要清零"直接算出来，
    //   比把 map/window 两组信号各自打两拍少一半寄存器：
    //     p6_lbl_off = 在 P6 虚拟映射里、但不在标题墨迹窗口（v >= 16）⇒ 标题层清零
    //     p6_val_off = 在 P6 行带区里、但不在数值墨迹窗口（v < 13 或 v >= 66）⇒ 数值层清零
    //   两级（S0 算出 -> S1 -> S2），与 px1/px2 同拍推进。
    reg        p6_area1, p6_map1;
    reg [3:0]  p6_vl1;
    reg [5:0]  p6_vg1;
    reg        p6_lbl_off1, p6_lbl_off2, p6_val_off1, p6_val_off2;
    //   ★ v42（㊴）：恢复默认失败时那枚 ✖ 的着色标志，跟着同一套流水走两拍
    //     （S0 选出 bad_mark_cell 覆盖字符码 → S2 着色，与 lab_bit 同拍）。
    reg        bad_mark1, bad_mark2;

    // ROM 地址 = {字符码, 格内 y}。行号就是格内 y 本身（见文件头说明）。
    //   ★ v30：P5 表格区的"格内 y"不是 py1[3:0]，而是虚拟格网的 p5_gy1
    //     （行带内 y 减 7 px 内缩）。字形 ROM 仍然是"1 拍寄存输出"，所以
    //     S1 给地址、S2 拿数据 —— 与 px2/py2 同一拍，级数一点没变。
    //   ★ v41（㊳）：P6 的 88 px 行带同理 —— 标题层的"格内 y"是带内 y（p6_vl1，
    //     自然映射时用 py1[3:0]），数值层是"带内 y - 13"（p6_vg1，自然映射时用
    //     py1[5:0]）。两个 mux 都在 S1，级数与 P5 那条并列，不加流水级。
    font_rom_lab u_lab_font (.clk(clk), .ch_idx(lab_ch_ovr),
                             .row_in_cell(p5_tb1 ? p5_gy1 :
                                          (p6_map1 ? p6_vl1 : py1[3:0])),
                             .bits(lab_bits));
    // ★ v59：上面 p1_vcy/p1_vg 是 S0（pix_y）上的值，字形要在 S1（py1）上取，
    //   所以同一套算法在这里再算一遍（两个常量乘法 = 6 个 LUT）。
    wire [11:0] p1_n16_1  = {8'd0, py1[9:4]};
    wire [13:0] p1_mul_1  = p1_n16_1 * 12'd43;
    wire [3:0]  p1_vcy1   = p1_mul_1[13:7];
    wire [11:0] p1_cy48_1 = ({8'd0, p1_vcy1} << 5) + ({8'd0, p1_vcy1} << 4);
    wire [5:0]  p1_vg1    = py1 - p1_cy48_1 + 12'd8;
    font_rom_val u_val_font (.clk(clk), .ch_idx(val_ch_raw),
                             .row_in_cell(p6_area1 ? p6_vg1 :
                                           ((page == 3'd0) ? p1_vg1 : py1[5:0])),
                             .bits(val_bits));

    // -------------------------------------------------------------------------
    // v29（㉕）真圆环进度：把"半径"和"角度"分开算 —— 半径只取决于像素到按钮
    //   中心的距离，与角度无关，于是把 64x64 的按钮坐标**镜像折叠**成 32x32 查
    //   表（`disp/ring_lut.v`，生成器 `tools/gen_ring_lut.py`）；角度只需把折叠
    //   象限里的 `k` 拼成全局扇区号（与生成器的 `assemble` 同式）。**没有乘法器、
    //   没有 CORDIC、没有除法**，只多 1 个 1Kx5 的 ROM（一个 RAMB18）。
    //   时间对齐与字体 ROM 完全一样：地址用 S1 的 px1/py1 组合、表在 S1 末采样
    //   ⇒ 数据与 px2/py2 同拍。**不要在 cx/cy 那一拍发读**，那会给整条像素链补
    //   一拍，文字/面板/波形一起错位。
    // -------------------------------------------------------------------------
    wire [11:0] rl_x1 = px1 - ((pnl_press == 4'd1) ? MNS_X0 : PLS_X0);
    wire [11:0] rl_y1 = py1 - STP_Y0;

    // 0..31 -> 31-i（^31）、32..63 -> i-32：折叠坐标越大离按钮中线越远。
    function [4:0] ring_fold(input [5:0] i);
        begin
            ring_fold = i[5] ? i[4:0] : (i[4:0] ^ 5'h1F);
        end
    endfunction

    wire [9:0] ring_addr = {ring_fold(rl_y1[5:0]), ring_fold(rl_x1[5:0])};
    wire [4:0] ring_q;
    ring_lut u_ring_lut (.clk(clk), .addr(ring_addr), .q(ring_q));

    reg rlx_hi, rly_hi;      // S2：像素在按钮的右半 / 下半（象限装配用）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px1 <= 12'd0; py1 <= 12'd0; de1 <= 1'b0;
            px2 <= 12'd0; py2 <= 12'd0; de2 <= 1'b0; de3 <= 1'b0;
            rlx_hi <= 1'b0; rly_hi <= 1'b0;
            p5_tb1 <= 1'b0; p5_tb2 <= 1'b0; p5_vis1 <= 1'b0; p5_vis2 <= 1'b0;
            p5_gy1 <= 4'd0; p5_gx1 <= 4'd0; p5_gx2 <= 4'd0;
            p6_area1 <= 1'b0; p6_map1 <= 1'b0; p6_vl1 <= 4'd0; p6_vg1 <= 6'd0;
            p6_lbl_off1 <= 1'b0; p6_lbl_off2 <= 1'b0;
            p6_val_off1 <= 1'b0; p6_val_off2 <= 1'b0;
            bad_mark1 <= 1'b0; bad_mark2 <= 1'b0;
        end else begin
            px1 <= pix_x;  py1 <= pix_y;  de1 <= de;
            px2 <= px1;    py2 <= py1;    de2 <= de1;   de3 <= de2;
            rlx_hi <= rl_x1[5];  rly_hi <= rl_y1[5];
            p5_tb1 <= p5_tab0; p5_tb2 <= p5_tb1;
            p5_vis1 <= p5_vvis; p5_vis2 <= p5_vis1;
            p5_gy1 <= p5_gy[3:0];
            p5_gx1 <= p5_gx[3:0]; p5_gx2 <= p5_gx1;
            p6_area1 <= p6_area; p6_map1 <= p6_map;
            p6_vl1 <= p6_v[3:0]; p6_vg1 <= p6_vg[5:0];
            p6_lbl_off1 <= p6_lbl_off; p6_lbl_off2 <= p6_lbl_off1;
            p6_val_off1 <= p6_val_off; p6_val_off2 <= p6_val_off1;
            bad_mark1 <= bad_mark_cell; bad_mark2 <= bad_mark1;
        end
    end
    assign de_o = de3;

    // =========================================================================
    // 4. S2：两层移位寄存器（格首装载，其后每拍左移一位，MSB 即当前列）
    //    装载时把字形左对齐到寄存器高位，右侧补 0；这样扫过字形宽度之后
    //    移进来的是 0，天然"格余留白"，不需要任何宽度判断。
    // =========================================================================
    reg [15:0] lab_sr;      // 16 bit 行位图 -> 16 px 格（汉字满格，ASCII 左对齐占高 10 位）
    reg [31:0] val_sr;      // 30 bit 行位图 -> 32 px 格

    wire lab_ld = (px2[3:0] == 4'd0);
    wire val_ld = (px2[4:0] == 5'd0);

    wire lab_bit = p5_tb2 ? (p5_vis2 ? lab_bits[15 - p5_gx2] : 1'b0)
                          : (p6_lbl_off2 ? 1'b0
                                         : (lab_ld ? lab_bits[15] : lab_sr[15]));
    //   ★ v41（㊳）：P6 行带的数值层要把"窗口外"的像素清零 —— 数值格是 64 px，
    //     88 px 行带里同一格字形会露到相邻行带；不加这个门，带与带之间会多出一截
    //     半个字形（㊳ 的首跑红就是靠这条判据逼出来的）。
    wire val_bit = p6_val_off2 ? 1'b0 : (val_ld ? val_bits[29] : val_sr[31]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lab_sr <= 16'd0;
            val_sr <= 32'd0;
        end else begin
            lab_sr <= lab_ld ? {lab_bits[14:0], 1'b0} : {lab_sr[14:0], 1'b0};
            val_sr <= val_ld ? {val_bits[28:0], 3'b0} : {val_sr[30:0], 1'b0};
        end
    end

    //   文字层只在"已经有自己文字平面的页"上显示。★ v17 起**八页全有**：
    //   P2/P3/P4 也各补了一块静态 lab 平面（标题 / 通道名 / 信号名 / 轴标），
    //   所以这个页号门控现在只是"八页都在册"的显式清单，不是功能开关。
    //   它仍然必须存在：lab_ch_raw/val_ch_raw 的默认分支是 P1 平面，任何一页
    //   漏在这张清单外，就不会画字（漏画是静默的），而它的 val 档若也漏写，
    //   会**叠着 P1 的六个大数字**。
    wire txt_page  = (page == 3'd0) || (page == 3'd1) || (page == 3'd2) ||
                     (page == 3'd3) || (page == 3'd4) || (page == 3'd5) ||
                     (page == 3'd6) || (page == 3'd7);
    wire glyph_bit = txt_page & (lab_bit | val_bit);

    // =========================================================================
    // 5. S3：合成（面板 + 描边 + 文字 + 告警条）
    //    全部用 S2 的坐标（px2/py2），绝不用"当前" pix_x/pix_y —— 那会让底图
    //    与文字整体错位，并在每个 DE 下降沿多出一个"该黑却着色"的像素
    //    （disp/tb_disp_engine.v 抓出过这个缺陷，指纹是每行恰好 1 个）。
    // =========================================================================
    wire [11:0] cx = px2;
    wire [11:0] cy = py2;

    // ---- 卡片判据 ----
    wire col0 = (cx >= CARD_X0) && (cx < CARD_X0 + CARD_W);
    wire col1 = (cx >= CARD_X1) && (cx < CARD_X1 + CARD_W);
    wire row0 = (cy >= CARD_Y0) && (cy < CARD_Y0 + CARD_H);
    wire row1 = (cy >= CARD_Y1) && (cy < CARD_Y1 + CARD_H);
    wire row2 = (cy >= CARD_Y2) && (cy < CARD_Y2 + CARD_H);
    //   ★ v15 起卡片框**只在 P1 画**：spec 4.3/4.5 把"卡片模板"定义为 P1 的版面，
    //     而 P6 用的是"3 列 x 4 项网格"（spec 4.4；v41 起 3 列 x 5 项）、P2 是轨迹区。
    //     以前不判页号，于是在 P2/P6 上也会画出与内容对不齐的卡片框（P6 的项在
    //     y 64/152/240/328/416 的 88 px 行带里，卡片框在 y=64/336，两者错开一段）。
    wire in_card = (page == 3'd0) & ((col0 | col1) & (row0 | row1 | row2));

    // 卡片内的局部坐标（用于 1 px 描边）
    wire [11:0] lx = col0 ? (cx - CARD_X0) : (cx - CARD_X1);
    wire [11:0] ly = row0 ? (cy - CARD_Y0) :
                     (row1 ? (cy - CARD_Y1) : (cy - CARD_Y2));
    wire on_border = (lx == 12'd0) || (lx == CARD_W - 12'd1) ||
                     (ly == 12'd0) || (ly == CARD_H - 12'd1);
    wire card_edge = in_card & on_border;
    // ---- v48（㊺）A1：spec §4.3 的**卡内 1 px 分隔线**（y+110，#D6E3F0）----
    //   spec 原文：`y+110 │ ── 1px 分隔线 #D6E3F0（卡内 x 16..284）`。
    //   本工程的卡片是 288 宽（不是 spec 的 300），所以按 spec 的**相对口径**
    //   "左右各内缩 16 px" 落：lx ∈ [16, CARD_W-16) ⇒ 宽 256 px。
    //   线高严格 1 px（只有 ly == 110 那一行），不占数值区、不压次级信息。
    //   ★ v59：卡高 256 -> 152 之后，12'd110 那一行正好压在状态行上，
    //     再也没有一条“卡内空白行”可用；直接取消这条 1 px 分隔线。
    //     卡框描边（card_edge）不受影响。
    wire card_div  = 1'b0;

    // ---- 导航栏 / 状态条 / 标题带 ----
    wire in_nav    = (cx < NAV_W);
    wire in_sbar   = (cy < SBAR_H);
    wire in_title  = (cy >= SBAR_H) && (cy < TITLE_H);
    // ---- 导航项命中段：144 px 一档（= 9 个 lab 格行），首项从状态条下沿起 ----
    //   ★ v58（R3）：删掉 XY / 状态两项后只剩 4 项，每项高度从 96 px 改成 144 px
    //     （内容区 24..599 = 576 px，576/4 = 144）。每项变大一半，触摸目标
    //     从 80x96 变 80x144，按 48 px 最小目标口径看也更宽松。
    //   为什么不用除法：144 不是 2 的幂，而这里只有 4 项 —— 3 个比较器比
    //   一个 12 位除法器便宜得多，而且它落在像素域的组合路径上（每像素都要算）。
    //   ★ 页号没重编：P3(2)/P5(4)/P8(7) 空着，所以第 3 项（时序）指向页 3、
    //     第 4 项（设置）指向页 5。映射写在 nav_page 里，不是 nav_idx == page。
    wire [1:0] nav_idx =
        (cy < (SBAR_H + 12'd144)) ? 2'd0 :   // 24..167   总览  -> P1(0)
        (cy < (SBAR_H + 12'd288)) ? 2'd1 :   // 168..311  波形  -> P2(1)
        (cy < (SBAR_H + 12'd432)) ? 2'd2 :   // 312..455  时序  -> P4(3)
                                    2'd3;    // 456..599  设置  -> P6(5)
    wire [2:0] nav_page = (nav_idx == 2'd0) ? 3'd0 :
                          (nav_idx == 2'd1) ? 3'd1 :
                          (nav_idx == 2'd2) ? 3'd3 : 3'd5;
    //   P7(6) 不在导航里 ⇒ "一个都不高亮"是比较结果的必然，不是哨兵值。
    wire nav_sel   = in_nav && (cy >= SBAR_H) && (nav_page == page);

    // ---- 告警层：从抽头快照解出最高优先级告警 ----
    //  ★ v60（上板反馈 #1）：上板只接信号发生器时，左边那条红带与标题带 ▲ 一直红
    //    —— 因为 `q_stat[0]`（oflow：cor_sat|otr_lat）与链路状态都被当成了 “故障”。
    //    口径改成两档：
    //     红（故障）  = 没有载波（amp_gone） —— “数据真的不能用”；
    //     橙（警示）  = CORDIC 饱和 / 幅值超窗 —— “某一路不太对，但读数还能看”。
    //    没接外接从站主机（只接发生器）就只会积到橙色一档，不再“一上电就红”。
    wire alert_fault = amp_gone;                        // v74：去掉链路 CRC 项
    wire alert_warn  = q_stat[0] |
                       q_stat[5] | q_stat[4] | q_stat[2] | q_io_flags[5] | q_io_flags[4];
    wire [23:0] alert_col = alert_fault ? C_FAULT : (alert_warn ? C_WARN : C_OK);
    wire alert_band = (cx < 12'd4) && (cy >= SBAR_H);

    // ---- 抽头"活性证明"：状态条右端 120 px 区域的亮度随编码器位置低位翻转 ----
    //   目的不是好看，而是让"抽头通路真的接上了"成为**上板可见**的事实：
    //   若抽头断线，这一块会静止不动。同时它保证 tap_* 全部进入实际逻辑，
    //   否则综合器会把整组抽头寄存器当成死逻辑删掉，测出来的时序是假的。
    //   ★ 只用寄存器后的低位，组合深度 2 级，绝不影响时序。
    wire [15:0] tap_xor = q_angle ^ q_s_n ^ q_c_n ^ q_pos_full[31:16] ^ q_pos_full[15:0]
                        ^ {8'd0, q_io_state} ^ {8'd0, q_io_flags} ^ {8'd0, q_stat}
                        ^ {6'd0, q_inter} ^ {13'd0, q_div};
    wire tap_alive = tap_xor[7] ^ tap_xor[3];

    // ---- 触摸"活性证明"：同一块区域的**下半 12 px** 改由触摸诊断驱动 ----
    //   分离成上下两条而不是叠加，是为了上板时能用肉眼看懂：
    //     上半（tap_alive）不动 ⇒ 编码器抽头断线；
    //     下半（tch_alive）不动 ⇒ 触摸控制器停摆（IIC 卡死 / 没锁定型号）。
    //   两条都动但 P6 页没反应 ⇒ 问题在渲染或坐标判定，不在数据通路。
    //   ★ 取触摸诊断里最会变的三段（点数/x0/stat_reads）做奇偶，
    //     组合深度 1 级，不影响时序。
    wire [15:0] tch_xor = tch_diag[15:0] ^ tch_diag[31:16]
                        ^ tch_diag[91:76] ^ {16{tch_diag[57]}};
    wire tch_alive = tch_xor[5] ^ tch_xor[11];
    // v19：两条活性灯从 x>904 挪到 x>=960 —— 904 与状态条 [系统 ⚙] 的 64 px 档位
    // （864..927）重叠，而灯在合成链里优先级高于文字，不挪会把新入口盖掉。
    wire heartbeat_zone = (cx >= LAMP_X0) && in_sbar;
    wire tch_zone       = (cx >= LAMP_X0) && in_sbar && (cy >= (SBAR_H - 12));

    // ---- 触摸状态灯：按"故障类别"分层着色（优先级从高到低）----
    //   红   reads==0       IIC 停摆（最严重）
    //   红   timeout!=0     总线超时（从机把 SDA 拉死）
    //   橙   nack!=0        有不应答
    //   蓝   0x814E 状态为 0 通信正常但状态寄存器不刷新 ← 本板历史现象
    //   绿   点数!=0        检测到触摸点
    //   闪   其余           通信在跑但当前无触点（用 tch_alive 心闪，不闪=断线）
    wire [23:0] tch_lamp_col =
        (q_tch_reads == 24'd0)   ? C_FAULT :
        (q_tch_timeout != 24'd0) ? C_FAULT :
        (q_tch_nack != 24'd0)    ? C_WARN  :
        (q_tch_status == 8'd0)   ? C_ACC   :
        (q_tch_num != 3'd0)      ? C_OK    :
                                   (tch_alive ? C_OK : C_SEC);

    // ---- 触点十字准星：证据比数字更直观 ----
    // 只比 11 位（坐标右移 1 位）⇒ 线宽 2 px，省掉一级比较器。
    wire tch_cross = (q_tch_num != 3'd0) &&
                     ((cx[11:1] == q_tch_x0[11:1]) || (cy[11:1] == q_tch_y0[11:1]));

    // ---- 分层着色（按优先级从低到高）----
    // ★ 状态条必须**先于**导航栏判定：状态条是通栏的（spec 4.2 y=0..24 全宽，
    //   页名 + 右端三个入口），导航栏从状态条下面开始。
    //   反过来写会让导航栏盖住页名最左 80 px，而页名文字是白字 ⇒
    //   在 C_NAV 浅蓝底上等于隐形（上板实测：P1 只剩 "VERVIEW"、P8 只剩 "OUCH DIAG"）。
    // ---- ③ 屏上改值：MULT/DIV 卡片底色的四态反馈 ----
    //   目的：让"值到底写进去没有"在屏上**一眼可见**，而不是只在 P6 的数字里。
    //   卡片 2 = 第 1 列第 0 行（P1 的 倍频/分频 卡，也就是 val_format 用
    //   cfg_inter/cfg_div 实时算出来的那一张）。
    //   ★ 底色一律用极浅色，保证 C_TEXT 深字仍然可读（对比度 >= 8:1）；
    //     深浅两档红用来区分"回读不一致（已自动回滚）"与"回滚也失败（严重）"。
    //     这也是 docs/13 反模式第 3 条"颜色不是唯一编码"的兑现：
    //     颜色只作辅助，数值本身（X? /1）与 P6 的数字才是主证据。
    wire ui_card = (page == 3'd0) && col1 && row0;
    wire [23:0] ui_card_col =
        // v22：面板开着且"待应用值 ≠ 回读值"时，卡片也进浅黄（与 ui_state 的
        //   BUSY 黄同色）—— 用户在面板里改了但还没写，卡片必须一眼看出"未生效"。
        (pnl_on && pnl_pend) ? 24'hFFF3CD :                          // v22 待应用：浅黄
        (ui_state == 2'd1) ? 24'hFFF3CD :                            // 待应用/进行中：浅黄
        (ui_state == 2'd2) ? 24'hE3F5E7 :                            // 已应用（回读确认）：浅绿
        (ui_state == 2'd3) ? ((ui_err == 4'd2) ? 24'hE8B4B0 :        // 回滚也失败：深红
                                               24'hFBD9D6) :         // 回读不一致已回滚：浅红
                             C_CARD;

    // =========================================================================
    // 5.1 P2 输入波形：轨迹区几何（全部是寄存器后信号的组合，深度 2 级比较）
    // =========================================================================
    wire in_p2     = (page == 3'd1);
    wire in_p2a    = in_p2 && (cx >= WAVE_X0) && (cx < WAVE_X1) &&
                     (cy >= WAVE_A_Y0) && (cy < WAVE_A_Y1);
    wire in_p2b    = in_p2 && (cx >= WAVE_X0) && (cx < WAVE_X1) &&
                     (cy >= WAVE_B_Y0) && (cy < WAVE_B_Y1);
    wire in_p2_box = in_p2a | in_p2b;

    //   外框：竖边只在通道的行区间内画，横边只在 x>=80 内画 ——
    //   少了这两个限制，y=140 的整行（含左侧导航栏）都会被画成网格色。
    wire p2_vert = in_p2 && ((cx == WAVE_X0) || (cx == WAVE_X1 - 12'd1)) &&
                   (((cy >= WAVE_A_Y0) && (cy < WAVE_A_Y1)) ||
                    ((cy >= WAVE_B_Y0) && (cy < WAVE_B_Y1)));
    wire p2_horiz = in_p2 && (cx >= WAVE_X0) && (cx < WAVE_X1) &&
                    ((cy == WAVE_A_Y0) || (cy == WAVE_A_Y1 - 12'd1) ||
                     (cy == WAVE_B_Y0) || (cy == WAVE_B_Y1 - 12'd1));
    wire p2_border = p2_vert | p2_horiz;

    //   v60（T5）：细栅格（每 64 px 一根竖线、每 32 px 一根横线）
    //   与左侧 32 px 刻度条。刻度条盖在轨迹区最左边上（底色同 C_PLOT），
    //   这样不用改 WAVE_X0、也不用改 wave_trace 的 dx 映射。
    wire p2_gridv = in_p2_box && (cx[5:0] == 6'd0);
    wire p2_gridh = in_p2_box && (cy[4:0] == 6'd0);
    wire p2_scale = in_p2_box && (cx < WAVE_X0 + 12'd32);
    wire [11:0] ry_a = cy - WAVE_A_Y0;
    wire [11:0] ry_b = cy - WAVE_B_Y0;
    wire p2_mid = (in_p2a && (ry_a == 12'd99)) || (in_p2b && (ry_b == 12'd99));
    //   刻度：上沿 / 中线 / 下沿，长 12 px，只在刻度条内
    wire p2_tick = p2_scale &&
                   ((in_p2a && ((ry_a == 12'd9) || (ry_a == 12'd99) || (ry_a == 12'd189))) ||
                    (in_p2b && ((ry_b == 12'd9) || (ry_b == 12'd99) || (ry_b == 12'd189))))
                   && (cx < WAVE_X0 + 12'd12);

    //   轨迹命中：**只要两次比较**。线段几何早已在 wave_trace 里算好，
    //   像素通路不做任何斜率计算、不走循环 —— 兑现 spec 7.2。
    wire [7:0] wa_lo = wave_d1[23:16], wa_hi = wave_d1[31:24];
    wire [7:0] wb_lo = wave_d1[7:0],   wb_hi = wave_d1[15:8];
    wire trace_a = in_p2a && (ry_a[7:0] >= wa_lo) && (ry_a[7:0] <= wa_hi);
    wire trace_b = in_p2b && (ry_b[7:0] >= wb_lo) && (ry_b[7:0] <= wb_hi);

    // =========================================================================
    // 5.2 P3 李萨如 XY：方框 + 中心十字 + 点阵描点
    //   像素通路在这里也**只有一次查表**：几何（点位）早在 xy_plot 里算完，
    //   这里做的是 `xy_d1` 这一位的判色，没有任何斜率/连线计算 —— 兑现 spec 7.2。
    // =========================================================================
    wire in_xy_box = p3_xy && (cx >= XY_X0) && (cx < XY_X1) &&
                     (cy >= XY_Y0) && (cy < XY_Y1);
    wire in_xy_bmp2 = p3_xy && (cx >= XY_BX0) && (cx < XY_BX1) &&
                               (cy >= XY_BY0) && (cy < XY_BY1);

    wire p3_border = in_xy_box && ((cx == XY_X0) || (cx == XY_X1 - 12'd1) ||
                                   (cy == XY_Y0) || (cy == XY_Y1 - 12'd1));

    //   中心十字：位图中心 (96,96) 对应屏上 (320+192, 178+192) = (512, 370)。
    //   没有这两条线，"圆偏了还是信号有直流"分不出来。
    wire p3_axis = in_xy_box && ((cx == XY_BX0 + 12'd192) || (cy == XY_BY0 + 12'd192));

    //   点阵命中：只有一次查表 + 一次与。位图 192x192 → 屏上 384x384（2x2 像素/格）。
    wire xy_dot = in_xy_bmp2 && xy_d1;

    // =========================================================================
    // 5.3 P4 ABZ/UVW 时序：6 条通道行 + 高/低轨 + 样本边界竖直边沿 + Z 竖标
    //   像素通路里同样只有移位与比较：样本号早在 p4_scope 的读口算好
    //   （(dx*306)>>10，255 取一的 LUTRAM 异步读），这里的"算"只有
    //   行号 = 行内偏移的比较链、电平 = 对 lg_w 的一次索引。
    //   没有斜率计算、没有连线循环 —— 兑现 spec §7.2。
    // =========================================================================
    function [23:0] lg_ch_col;
        input [2:0] k;
        begin
            lg_ch_col = (k == 3'd0) ? C_CH_A : (k == 3'd1) ? C_CH_B :
                        (k == 3'd2) ? C_CH_Z : (k == 3'd3) ? C_CH_U :
                        (k == 3'd4) ? C_CH_V : C_CH_W;
        end
    endfunction

    wire in_lg_box = p4_lg && (cx >= LG_X0) && (cx < LG_X1) &&
                              (cy >= LG_Y0) && (cy < LG_Y1);

    wire [11:0] lg_dy    = cy - LG_TOP;
    wire        lg_rband = in_lg_box && (cy >= LG_TOP) && (cy < LG_TOP + LG_BAND_H);
    //   ★ 轨迹只画在**轨迹区**里（cx >= LG_TX0）。少了这个限制，高/低轨与竖直边沿
    //     会一路画进左边的标签栏（实测：第 0 行的高轨从 x=212 就开始），因为
    //     lg_rband 只看行、不看列。标签色块走 lg_rband，所以两者要分开。
    wire        lg_tband = lg_rband && (cx >= LG_TX0);

    wire [2:0] lg_row = (lg_dy < LG_R1) ? 3'd0 :
                        (lg_dy < LG_R2) ? 3'd1 :
                        (lg_dy < LG_R3) ? 3'd2 :
                        (lg_dy < LG_R4) ? 3'd3 :
                        (lg_dy < LG_R5) ? 3'd4 : 3'd5;
    //   row*68 = row*64 + row*4 —— 两次移位一次加，避免 12 位乘法器进像素通路。
    //   ★ 这个写法只在 LG_ROW_H == 68 时成立；改行高时必须同步改这里的移位。
    wire [11:0] lg_off = {lg_row, 6'b0} + {lg_row, 2'b0};
    wire [11:0] lg_ry  = lg_dy - lg_off;                 // 行内 y，0..67

    wire        lg_lvl  = lg_w [lg_row];

    //   ★ v77（P4"零星短横线/几乎全空"）：
    //   竖线 = "这一箱的电平与上一箱不同"，由 p4_scope 在读口同一级流水里算好
    //   （qv/qlv），这里只做一次索引。老做法在像素通路里比 lg_w 与 lg_wp，
    //   而两者是读口三级流水的产物，一旦相位对不齐竖线就整帧消失（见
    //   p4_scope.v 头注释）。
    //   水平轨同时加粗到 2 px（HI..HI+1 / LO..LO+1）：1024x600 上 1 px 单色
    //   横线与背景对比太低，照片里几乎看不见 —— 这才是"几乎全空"的一半原因。
    //   竖线加粗到 2 px：把"本列有跳变"或"上一列有跳变"都点亮。
    wire        lg_e      = lg_ew[lg_row] | lg_ew_d[lg_row];
    wire        lg_hi2    = (lg_ry == LG_RAIL_HI) || (lg_ry == LG_RAIL_HI + 12'd1);
    wire        lg_lo2    = (lg_ry == LG_RAIL_LO) || (lg_ry == LG_RAIL_LO + 12'd1);
    wire        lg_rail_px = (lg_lvl ? lg_hi2 : lg_lo2);

    //   ★ v78：Z 的窄脉冲用"竖标"而不是靠电平碰运气。p4_scope 在窗口内每见到
    //   一次 Z 上升沿就把标记钉在当时那个样本上（lo_mem 第 5 位），这里把
    //   "本列或上一列有标记"的那 1~2 个样本（3.3~6.7 px）画满整个行高
    //   （HI..LO+1）—— 读作"这一个时刻发生过 Z 事件"，与电平轨不混。
    //   只落在 Z 行（lg_row == 2），因为 lo_mem 的标记位只属于 Z。
    wire        lg_zmark  = lg_wz && (lg_row == 3'd2) &&
                            (lg_ry >= LG_RAIL_HI) && (lg_ry <= LG_RAIL_LO + 12'd1);

    wire lg_trace_px = lg_tband && (lg_rail_px || lg_zmark ||
                                    (lg_e && (lg_ry >= LG_RAIL_HI) && (lg_ry <= LG_RAIL_LO + 12'd1)));

    //   标签栏的通道色块：位置就是通道编号（颜色只是加速识别，spec 5.2）。
    //   标签栏只有 88 px（x = LG_X0..LG_TX0），色块占 16..40、通道字母占格列 8（x=128）。
    wire lg_swatch = lg_rband && (cx >= LG_X0 + 12'd16) && (cx < LG_X0 + 12'd40) &&
                     (lg_ry >= LG_RAIL_HI) && (lg_ry <= LG_RAIL_LO);

    //   网格：外框 + 标签栏分隔 + 时间轴条 + 每 45° 一个刻度（v21 改）
    wire p4_border = in_lg_box && ((cx == LG_X0) || (cx == LG_X1 - 12'd1) ||
                                   (cy == LG_Y0) || (cy == LG_Y1 - 12'd1));
    wire p4_labsep = in_lg_box && (cx == LG_TX0 - 12'd1);
    wire p4_axisln = in_lg_box && (cy == LG_AXIS);
    //   v21：刻度从"每 128 px 一根（≈53.8°，标不出整度数）"改成"每 45° 一根"。
    //   轨迹区宽 LG_TX1 - LG_TX0 = 856 px 覆盖 0..360°（128 箱 × 2.8125°/箱），
    //   而 856 = 8 × 107 恰好整除 ⇒ 8 根刻度正好落在 0/45/90/135/180/225/270/315°，
    //   x = 168 + 107k（k = 0..7），最后一根 917 之后到 1024 仍是完整的一格 45°。
    //   为什么不用 lg_tx[6:0] == 0 那种位截断：107 不是 2 的幂，位截断做不出 45°；
    //   8 个常量比较比一次 12 位除法便宜。★ 这 8 根与 lab 层行 29 的 8 个刻度数字
    //   （tools/gen_text_ram.py 的 P4_LAB）是同一个契约的第二处，改一处必须同改另一处。
    wire [11:0] p4_tx = cx - LG_TX0;
    //   ★ v78：回到"每 45° 一根、107 px"，与上面 v21 的注释和 lab 层行 29 的
    //   0/45/.../360 数字对齐。v60（T7）曾经改成 100 px/根，那是"1 µs/px、
    //   窗口 856 µs"的时域口径；v78 起下区窗口是**整 1 个电周期**（360°），
    //   45° = 856/8 = 107 px —— 100 px 那排刻度会让 315°/360° 越出右边界，
    //   且与刻度文字错开 7 px/根（v75 注释里已记为遗留项，这里一并修掉）。
    wire p4_tick   = in_lg_box && (cy > LG_AXIS) && (cy < LG_AXIS + 12'd10) &&
                     (cx >= LG_TX0) &&
                     ((p4_tx == 12'd0)   || (p4_tx == 12'd107) || (p4_tx == 12'd214) ||
                      (p4_tx == 12'd321) || (p4_tx == 12'd428) || (p4_tx == 12'd535) ||
                      (p4_tx == 12'd642) || (p4_tx == 12'd749));
    // ★ v75（B）：上下两个窗口的分界 + 上半区（A/B）自己的刻度。
    //   上半区 6 行里前 2 行（A/B）是"4 个 A 周期"的快时基窗口，后 4 行
    //   （Z/U/V/W）是"1 个电周期"的慢时基窗口 —— 一根横线把两个时间轴分开，
    //   否则底轴那排刻度（45°/根）会被读成两区共用。
    //   位置：分界线本身落在 y = 256..257（B 行低轨 224 与 Z 行高轨 264 之间的
    //   空带里），上半区的 5 根刻度线在 234..239，刻度文字在格行 15（240..255）——
    //   刻度线在上、文字居中、分界线在下，三者互不重叠（文字是 16 px 格行，
    //   格行边界卡不进 3 px 的缝里，所以用"上下夹住文字"这个排法）。
    localparam [11:0] LG_DIV_Y = LG_TOP + 12'd146;   // = 258
    wire p4_div = in_lg_box && (cx >= LG_TX0) &&
                  ((cy == LG_DIV_Y - 12'd2) || (cy == LG_DIV_Y - 12'd1));
    //   上半区刻度：4 个 A 周期占满 856 px ⇒ 每 214 px 一根（x = 168/382/596/810/1024），
    //   线长 6 px，画在分界线文字的上方。214 = 856/4 是"4 个 A 周期"这个窗口宽度
    //   摊到 4 个 A 周期的结果，与 p4_scope.v 的 ubin 分箱（每 A 周期 16 箱 = 214 px）
    //   同源；lab 层 row 15 的 0/1A/2A/3A/4A 与这里是同一份契约。
    wire [11:0] p4_udx = cx - LG_TX0;
    wire p4_utick = in_lg_box && (cy >= LG_DIV_Y - 12'd24) && (cy < LG_DIV_Y - 12'd18) &&
                    ((p4_udx == 12'd0) || (p4_udx == 12'd214) || (p4_udx == 12'd428) ||
                     (p4_udx == 12'd642) || (p4_udx == 12'd856));

    wire p4_grid   = p4_border | p4_labsep | p4_axisln | p4_tick | p4_div | p4_utick;

    // ---- P5 六状态表的占比条形图列（v30 重排）----
    //   spec 4.4：表格 6 行 x 5 列、行高 30、列宽 188，第 5 列是占比条形图。
    //   表体行带 r（0..5）覆盖 y = 158 + 30r .. 187 + 30r，条形只占行带里
    //   y = 168 .. 185（18 px，与 30 px 行带垂直居中），行号从 cy 现算 ——
    //   像素这里算的是**屏幕坐标**，与 S0/S1/S2 那套虚拟格网（RAM 行 / 格内行）
    //   是同一份契约的两个视图，改一处必须同改另两处。
    //   阈值是 p5_view 的六个寄存器（perm * 188 / 1024，0..183 px），所以这里
    //   只剩"列偏移 < 阈值"一次比较。★ 阈值与百分比同源，不会出现"数字说
    //   30%、条子画成 45%"这种两处各算一次才有的偏差。
    wire        p5_lg    = 1'b0;   // v58：P5 已删，页使能钉 0
    wire [11:0] p5_bdy   = cy - 12'd158;             // 表体上沿
    wire [2:0]  p5_br    = (p5_bdy >= 12'd150) ? 3'd5 :
                           (p5_bdy >= 12'd120) ? 3'd4 :
                           (p5_bdy >= 12'd90)  ? 3'd3 :
                           (p5_bdy >= 12'd60)  ? 3'd2 :
                           (p5_bdy >= 12'd30)  ? 3'd1 : 3'd0;
    wire [11:0] p5_brtop = (p5_br == 3'd5) ? 12'd150 : (p5_br == 3'd4) ? 12'd120 :
                           (p5_br == 3'd3) ? 12'd90  : (p5_br == 3'd2) ? 12'd60 :
                           (p5_br == 3'd1) ? 12'd30  : 12'd0;
    wire [11:0] p5_bsy  = p5_bdy - p5_brtop;         // 行带内 y：0..29
    wire        p5_bzone = p5_lg && (cx >= P5_BAR_X0) && (cx < P5_BAR_X1) &&
                           (cy >= 12'd158) && (cy < 12'd338) &&
                           (p5_bsy >= 12'd10) && (p5_bsy < 12'd28);

    reg  [7:0]  p5_thr;
    always @* begin
        case (p5_br)
            3'd0:    p5_thr = p5_bar_t0;
            3'd1:    p5_thr = p5_bar_t1;
            3'd2:    p5_thr = p5_bar_t2;
            3'd3:    p5_thr = p5_bar_t3;
            3'd4:    p5_thr = p5_bar_t4;
            default: p5_thr = p5_bar_t5;
        endcase
    end

    wire [11:0] p5_bdx  = cx - P5_BAR_X0;            // 0..183
    wire        p5_fill = p5_bzone && (p5_bdx < {4'b0000, p5_thr});

    //   v30 的表格线：外框 x = 81..1023、y = 127..339（左右/上下边界各取 bbox
    //   的最外像素）；4 条列分隔线（x = 82 + 188c，c = 1..4）；6 条行分隔线
    //   （y = 128 + 30r，r = 1..6）。文字行在行带里上下各留 7 px，横线不会压字。
    wire p5_frame  = p5_lg &&
                     (cx >= P5_TX0 - 12'd1) && (cx <= P5_TX1 + 12'd1) &&
                     (cy >= P5_TY0 - 12'd1) && (cy <= P5_TY1 + 12'd1) &&
                     ((cx == P5_TX0 - 12'd1) || (cx == P5_TX1 + 12'd1) ||
                      (cy == P5_TY0 - 12'd1) || (cy == P5_TY1 + 12'd1));
    wire p5_colsep = p5_lg && (cy >= P5_TY0) && (cy < P5_TY1) &&
                     ((cx == 12'd270) || (cx == 12'd458) || (cx == 12'd646) ||
                      (cx == 12'd834));
    wire p5_rowsep = p5_lg && (cx >= P5_TX0) && (cx < P5_TX1) &&
                     ((cy == 12'd158) || (cy == 12'd188) || (cy == 12'd218) ||
                      (cy == 12'd248) || (cy == 12'd278) || (cy == 12'd308));
    wire p5_grid   = p5_frame | p5_colsep | p5_rowsep;

    //   条形图数值刻度：0 / 25 / 50 / 75 / 100% 五条。位置与条子同一套取整
    //   （x = 836 + (pct*10 permille * 188) >> 10）：0 -> 836、25 -> 881、
    //   50 -> 927、75 -> 973、100 -> 1019（框内最后一列）。
    //   格列 25 / 40 / 55 的静态数字（P5_LAB 行 21）与这五根线是同一个契约的
    //   第二处，改一处必须同改另一处。
    wire p5_btick = p5_lg && (cy >= 12'd158) && (cy < 12'd338) &&
                    ((cx == 12'd836) || (cx == 12'd881) || (cx == 12'd927) ||
                     (cx == 12'd973) || (cx == 12'd1019));

    // ---- P7 标定与误差可视化（v16）----
    //   左框两条曲线（标定前品红 / 标定后绿），右框是 p7_view 写的六个参数值。
    //   两块曲线 RAM 用同一个箱号同时读出，这里只补**一级**寄存器 —— 与文字通路
    //   的级数一致（U-16 的规则：与 px2 对齐的实时通路只能有两级存储）。
    reg [31:0] p7_pair;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) p7_pair <= 32'd0;
        else        p7_pair <= {p7_aft_rdata, p7_bef_rdata};
    end

    wire        p7_lg     = (page == 3'd6);
    wire        in_p7_cv  = p7_lg && (cx >= P7_CVX0) && (cx < P7_CVX1) &&
                            (cy >= P7_CVY0) && (cy < P7_CVY1);
    wire [11:0] p7_ry     = cy - P7_CVY0;
    // ★ 2026-10-28 修（审计）：P7 纵轴只写 0..239（p7_view 里 clamp 到 239），
    //   而原式用 p7_ry[7:0] 比较 ⇒ cy 落在 256..463 时 8 位截断回绕到 0..207，
    //   在框底复现出一条"幽灵曲线"。这里先按 8 位有效范围开窗，再比上下界。
    wire        p7_vis    = (p7_ry < 12'd256);
    wire [7:0]  p7_lo_bef = p7_pair[7:0];
    wire [7:0]  p7_hi_bef = p7_pair[15:8];
    wire [7:0]  p7_lo_aft = p7_pair[23:16];
    wire [7:0]  p7_hi_aft = p7_pair[31:24];
    wire        p7_in_bef = in_p7_cv && p7_vis && (p7_ry[7:0] >= p7_lo_bef) && (p7_ry[7:0] <= p7_hi_bef);
    wire        p7_in_aft = in_p7_cv && p7_vis && (p7_ry[7:0] >= p7_lo_aft) && (p7_ry[7:0] <= p7_hi_aft);

    wire        p7_in_lbox = p7_lg && (cx >= P7_BX0) && (cx < P7_BX1) &&
                             (cy >= P7_BY0) && (cy < P7_BY1);
    wire        p7_in_rbox = p7_lg && (cx >= P7_RX0) && (cx < P7_RX1) &&
                             (cy >= P7_BY0) && (cy < P7_BY1);
    wire        p7_box_any = p7_in_lbox || p7_in_rbox;
    wire        p7_gedge   = (cx == P7_BX0) || (cx == P7_BX1 - 12'd1) ||
                             (cx == P7_RX0) || (cx == P7_RX1 - 12'd1) ||
                             (cy == P7_BY0) || (cy == P7_BY1 - 12'd1) ||
                             (cy == P7_CVY0) || (cy == P7_CVY1 - 12'd1) ||
                             (cx == P7_CVX0) || (cx == P7_CVX1 - 12'd1);
    wire        p7_grid    = (p7_in_lbox || p7_in_rbox) && p7_gedge;
    //   图例色块：紧挨 lab(8,30)"前" 与 lab(8,34)"后" 的左侧
    wire        p7_swatch  = p7_lg && (cy >= 12'd128) && (cy < 12'd144) &&
                             (((cx >= P7_SW0) && (cx < P7_SW0 + 12'd16)) ||
                              ((cx >= P7_SW1) && (cx < P7_SW1 + 12'd16)));
    wire [23:0] p7_sw_col  = (cx >= P7_SW1) ? C_EPOST : C_EPRE;

    // ★ v75（D）：误差曲线的零线 / 参考线。
    //   原来曲线区一根坐标线都没有，读图时无法判断"这条平带是不是落在标称
    //   位置上"（也无法判断平带有没有整体漂移）。这里按**几何常量**画一条
    //   标称线 + 两条四分之一线：
    //     标称行   = 120  -> y = P7_CVY0 + 120 = 280
    //     四分线   = 60 / 180（虚线，每 4 px 取 2 px，与曲线区分开）
    //   120 这个数不是随手取的：它是 disp_engine 里 p7_ram 的 INIT
    //   {8'd120, 8'd120}（标定正确时的平带行号），p7_view 的 clamp 上限 239
    //   也以它为半幅。所以"参考线 / 初值 / 映射中点"三者同源，不会互相矛盾。
    localparam [11:0] P7_REF_Y = 12'd120;
    wire        p7_ref     = in_p7_cv && (p7_ry == P7_REF_Y);
    wire        p7_ref_q   = in_p7_cv && (p7_dx[1:0] != 2'b11) &&
                             ((p7_ry == 12'd60) || (p7_ry == 12'd180));

    //   ★ v85：两条"幅值 0%/100% 闸线"随绝对幅值口径一起删除。
    //   新纵轴是固定的 ±2% 满量程、零线居中（disp/p7_view.v 的 y = 120 - 0.6·dev），
    //   刻度行号与门限寄存器无关，所以不需要实时算行号，也不需要闸线。
    //   参考线保留：零线 p7_ref（行 120）+ ±1% 两条虚线 p7_ref_q（行 60/180）。

    // =========================================================================
    // 5.8 v19：状态条右端两个指示器（spec 4.2 的 [信号 ●][告警 ▲]）
    //   为什么画几何图形而不是文字：字库里没有 信/号/告/警 这些字，而 lab 字符码
    //   是有上限的（见 tools/gen_text_ram.py 的 P6 段注释）。
    //   两个档位各 64 px，落在状态条 y<24 里（图形只占 y 3..21）：
    //     ● 圆点：颜色 = 触摸链路六态（tch_lamp_col）—— 顺带保留"触摸在不在动"
    //             的证据；C_SEC（空闲深蓝）在蓝底状态条上看不清，改判成 C_WARN。
    //     ▲ 三角：颜色 = 最高优先级告警（alert_col，与左端告警条同一套判据）。
    //   ★ v58：第三个档位 [系统 ⚙] 随 P8 删除 —— 它当时是全条唯一可点的一项。
    //   ★ 两条活性灯从 x>904 挪到 x>960：904 与原 ⚙ 的 64 px 档位重叠，不挪就会
    //     把入口盖掉（灯在 compose 里优先级高于文字）。
    // =========================================================================
    wire [11:0] sig_adx = (cx >= SBAR_SIG_CX) ? (cx - SBAR_SIG_CX) : (SBAR_SIG_CX - cx);
    wire [11:0] alm_adx = (cx >= SBAR_ALM_CX) ? (cx - SBAR_ALM_CX) : (SBAR_ALM_CX - cx);
    wire [11:0] sig_ady = (cy >= 12'd12) ? (cy - 12'd12) : (12'd12 - cy);
    // ● 八角形近似圆：三条比较够圆了（半径 6，屏上 13 px 大小）
    wire sig_dot  = (sig_adx <= 12'd6) && (sig_ady <= 12'd6) &&
                    ((sig_adx + sig_ady) <= 12'd9);
    // ▲ 顶点在上：宽度随行号线性张开（行 3 是尖，行 21 是底边 18 px 半宽）
    wire [11:0] alm_w = (cy >= 12'd3) ? (cy - 12'd3) : 12'd0;
    wire alm_tri = (cy >= 12'd3) && (cy <= 12'd21) && (alm_adx <= alm_w);
    wire [23:0] sig_col = (tch_lamp_col == C_SEC) ? C_WARN : tch_lamp_col;

    // =========================================================================
    // 5.9 v19：P6 底部危险区（944x96，spec 4.4）+ 「清除锁存故障」按钮 + 警示三角
    //   层级：危险区在**文字之下**（按钮上的"清除锁存故障"是 lab 文字，画在上面），
    //   在页面底之上。按钮在模态态下变浅红（正在写 0x0405）。
    //   ★ v33（㉝）：区高 80 → 96，按钮与三角**跟着中心 552 一起下移/上移**，
    //     三者仍然同心；命中矩形的外扩在 disp/enc_top_disp.v 的 DZ_HIT_*（±8 px）。
    // =========================================================================
    wire in_p6  = (page == 3'd5);
    wire dz_any = in_p6 && (cx >= DZ_X0) && (cx < DZ_X1) && (cy >= DZ_Y0) && (cy < DZ_Y1);
    wire dz_zone_edge = dz_any && ((cx == DZ_X0) || (cx == DZ_X1 - 12'd1) ||
                                   (cy == DZ_Y0) || (cy == DZ_Y1 - 12'd1));
    wire dz_btn = in_p6 && (cx >= DZ_BTN_X0) && (cx < DZ_BTN_X1) &&
                  (cy >= DZ_BTN_Y0) && (cy < DZ_BTN_Y1);
    wire dz_btn_edge = dz_btn && ((cx == DZ_BTN_X0) || (cx == DZ_BTN_X1 - 12'd1) ||
                                  (cy == DZ_BTN_Y0) || (cy == DZ_BTN_Y1 - 12'd1));
    // 警示三角：中心 x=140，尖顶 y=532、底边 y=572（41 行、半宽 20；中心仍 552）
    wire [11:0] dz_tadx = (cx >= 12'd140) ? (cx - 12'd140) : (12'd140 - cx);
    wire [11:0] dz_tw   = (cy >= 12'd532) ? (cy - 12'd532) : 12'd0;
    wire dz_tri = in_p6 && (cy >= 12'd532) && (cy <= 12'd572) &&
                  (dz_tadx <= dz_tw) && (dz_tadx <= 12'd20);
    wire dz_btn2 = in_p6 && (cx >= DZ_BTN2_X0) && (cx < DZ_BTN2_X1) &&
                   (cy >= DZ_BTN_Y0) && (cy < DZ_BTN_Y1);
    wire dz_btn2_edge = dz_btn2 && ((cx == DZ_BTN2_X0) || (cx == DZ_BTN2_X1 - 12'd1) ||
                                    (cy == DZ_BTN_Y0) || (cy == DZ_BTN_Y1 - 12'd1));
    //   ★ v34（㊲）：按住期间的**形状编码**（spec §5.2：颜色绝不作为唯一的状态
    //     编码）。做法是在按钮里侧 10 px 处再画一圈 2 px 内嵌框，而不是把按钮染色 ——
    //     于是一张静止画面里"按住了"也能靠几何看出来，色弱与强光下同样成立。
    //     v42（㊴）两颗按钮各有自己的一圈：第 1 颗 x 190..191 / 580..581、
    //     第 2 颗 x 618..619 / 1008..1009，两者的 y 都是 530..531 / 572..573。
    //     它与按钮自己的 64 px 描边之间留 10 px 白底，与格行 34 的两条标签
    //     （x 336..431 与 x 784..847、y 544..559）不重叠 ⇒ 深色标签仍在浅底上。
    wire dz_btn_in = dz_btn && (cx >= DZ_BTN_X0 + 12'd10) && (cx < DZ_BTN_X1 - 12'd10) &&
                     (cy >= DZ_BTN_Y0 + 12'd10) && (cy < DZ_BTN_Y1 - 12'd10);
    wire dz_btn_in_edge = dz_btn_in && ((cx <= DZ_BTN_X0 + 12'd11) ||
                                        (cx >= DZ_BTN_X1 - 12'd12) ||
                                        (cy <= DZ_BTN_Y0 + 12'd11) ||
                                        (cy >= DZ_BTN_Y1 - 12'd12));
    wire dz_btn2_in = dz_btn2 && (cx >= DZ_BTN2_X0 + 12'd10) && (cx < DZ_BTN2_X1 - 12'd10) &&
                      (cy >= DZ_BTN_Y0 + 12'd10) && (cy < DZ_BTN_Y1 - 12'd10);
    wire dz_btn2_in_edge = dz_btn2_in && ((cx <= DZ_BTN2_X0 + 12'd11) ||
                                          (cx >= DZ_BTN2_X1 - 12'd12) ||
                                          (cy <= DZ_BTN_Y0 + 12'd11) ||
                                          (cy >= DZ_BTN_Y1 - 12'd12));
    wire dz_press  = ui_dz_press  && dz_btn_in_edge;
    wire dz_press2 = ui_dz_press2 && dz_btn2_in_edge;
    //   ★ v42：第 2 颗按钮的描边兼当"恢复序列结果"的指示灯 —— 全绿（C_OK）=
    //     17 个回读字段全一致，红（C_FAULT）= 有不一致（此时同时有 ✖ 字形，见下）。
    //     空闲（ui_rst_state = 0）时与第 1 颗一样是红框（危险动作的常规样貌）。
    wire [23:0] dz_btn2_edge_col = (ui_rst_state == 2'd1) ? C_OK : C_FAULT;
    wire [23:0] dz_col = dz_btn_edge ? C_FAULT :
                         dz_btn2_edge ? dz_btn2_edge_col :
                         dz_zone_edge ? C_FAULT :
                         dz_tri ? C_FAULT :
                         dz_press ? C_FAULT :
                         dz_press2 ? C_FAULT :
                         (dz_btn || dz_btn2) ? (ui_dlg != 2'd0 ? 24'hFBD9D6 : C_BG) :
                                  C_CARD;
    wire dz_px = dz_btn_edge || dz_btn2_edge || dz_zone_edge || dz_tri ||
                 dz_press || dz_press2 || dz_btn || dz_btn2 || dz_any;

    // =========================================================================
    // 5.10 v19：模态二次确认对话框
    //   关掉时任何像素都不参与；打开时：外框内 = 对话框，外框外 = 实色遮罩。
    //   对话框的**文字**来自 P6 lab 平面的两个专用格行（15 = 标题、21 = 按钮），
    //   页面层对这两行做排除（`glyph_page`），只有模态层画它们。
    // =========================================================================
    wire [5:0]  lrow2     = py2[9:4];
    //   对话框文字住在 P6 lab 平面的三个专用格行里；排除**必须按页门控** ——
    //   P8 的 lab 行 15 是它自己的三组标题（触点 X0 / 触点 Y0 / 0x814E）。
    //   ★ v41（㊳）：行号从 15/17/21 迁到 13/18/22（见 §1 的 DLG_ROW* 注释）。
    //     行 22 同时是导航栏第 4 个页签「时序」（NAV 格行 22、格列 1）所在行 ⇒
    //     对这一行要再按格列门控（px2[9:4] >= 16，即 x >= 256），否则页签会被吃掉。
    //   ★ 这里**不要**再声明 lcol2：下面 §状态条扫描 已有一份 `lcol2 = cx[9:4]`
    //     （cx = px2，同值），重复声明 xvlog 会报 VRFC 10-9364。
    //   ★ v42（㊴）：对话框有**两套**（kind 0 = 清除锁存故障、kind 1 = 恢复默认），
    //     标题/正文各住一行（13/18 与 14/19），由 ui_dlg_kind 选当前那一套；
    //     按钮标签行 22 两套共用。★ **页面层对五行全部排除**（13/14/18/19/22）：
    //     否则切到"清除锁存故障"时"恢复默认"那两行的字符串会当页面正文飘在设置项里。
    wire [5:0]  dlg_title_row = ui_dlg_kind ? DLG_ROW3 : DLG_ROW0;
    wire [5:0]  dlg_body_row  = ui_dlg_kind ? DLG_ROW4 : DLG_ROW1;
    wire        dlg_row_page  = (lrow2 == DLG_ROW0) || (lrow2 == DLG_ROW1) ||
                                (lrow2 == DLG_ROW3) || (lrow2 == DLG_ROW4);
    //   ★ v60（T2）：四行也要按列门控！导航标签就在格列 1，
    //     而导航「波形」的格行恰好是 14 = DLG_ROW3（“恢复默认”标题行）。
    //     原来整行排除 ⇒ 设置页导航少一项（上板照片 m03131）。
    //     对话框字体在格列 21/29/39 一带，所以列门控取 >= 6 就够。
    wire        dlg_cell0 = (dlg_row_page && (px2[9:4] >= 6'd6)) ||
                            ((lrow2 == DLG_ROW2) && (px2[9:4] >= 6'd16));
    //   当前那一套的两行（模态层只画这两行；按钮行另外判）。
    wire        dlg_cur   = (lrow2 == dlg_title_row) || (lrow2 == dlg_body_row) ||
                            (lrow2 == DLG_ROW2);
    wire        dlg_cell  = dlg_cell0 && (page == 3'd5);
    wire        dlg_on    = (ui_dlg != 2'd0);
    wire        in_dlg_box = (cx >= DLG_X0) && (cx < DLG_X1) &&
                             (cy >= DLG_Y0) && (cy < DLG_Y1);
    wire        dlg_border = in_dlg_box && ((cx <= DLG_X0 + 12'd1) ||
                                            (cx >= DLG_X1 - 12'd2) ||
                                            (cy <= DLG_Y0 + 12'd1) ||
                                            (cy >= DLG_Y1 - 12'd2));
    wire        dlg_no  = (cx >= DLG_NO_X0)  && (cx < DLG_NO_X1) &&
                          (cy >= DLG_BTN_Y0) && (cy < DLG_BTN_Y1);
    wire        dlg_yes = (cx >= DLG_YES_X0) && (cx < DLG_YES_X1) &&
                          (cy >= DLG_BTN_Y0) && (cy < DLG_BTN_Y1);
    wire        dlg_no_edge  = dlg_no  && ((cx == DLG_NO_X0)  || (cx == DLG_NO_X1 - 12'd1) ||
                                           (cy == DLG_BTN_Y0) || (cy == DLG_BTN_Y1 - 12'd1));
    wire        dlg_yes_edge = dlg_yes && ((cx == DLG_YES_X0) || (cx == DLG_YES_X1 - 12'd1) ||
                                           (cy == DLG_BTN_Y0) || (cy == DLG_BTN_Y1 - 12'd1));
    wire [23:0] dlg_col = dlg_border ? C_FAULT :
                          dlg_yes_edge ? C_GRID :
                          dlg_yes ? ((ui_dlg == 2'd2) ? 24'hFBD9D6 : C_BG) :
                          dlg_no_edge ? C_GRID :
                          dlg_no ? C_BG : C_CARD;
    // 对话框文字（格行 15 / 21）：只在模态态画，颜色同正文
    // v22：倍频编辑面板占下半屏时，**面板矩形内的一切页面字形都不画**（否则
    //   卡片 2 第 2 行、P1 数值层第 7 行会从面板上穿出来）。抑制只按 pnl_on 门控，
    //   而 pnl_on 本身只在 P1（page==0）成立 ⇒ 不会误伤别的页。
    wire        glyph_pnl_sup = pnl_on && (cx >= PNL_X0) && (cx < PNL_X1) &&
                                          (cy >= PNL_Y0) && (cy < PNL_Y1);
    // v23 修正（U-26 遗留的真缺陷）：面板那两行字（格行 21 的标题、格行 34 的三个
    //   按钮标签）在**面板关着时**也会被页面层画出来 —— 它们的字形就摆在 P1 的
    //   lab 平面里，`glyph_page` 只排除对话框（P6）的格位。屏上的现象是：面板没
    //   打开，卡片 2 底下却浮着「倍频分频 / PRESET / CANCEL / APPLY / 回到」。
    //   修法 = 让页面层在 P1 上永远不碰这两行，它们只归模态层（glyph_pnl）。
    //   P1 自己在这两行上没有别的字（P1_LAB 用的是 5/13/15/22/33/35 行），
    //   所以按 (page==0) 排除是安全的；别的页（如 P5 的刻度数字也在格行 21）
    //   一行都不动。
    //   v51（㊽）B4 追加：格行 23 / 25 的"等效倍率 / AB 边沿率"数值窗+标签窗
    //   （行 23 列 36..45、行 25 列 36..46）也归模态层 —— 面板关着时它们是空白
    //   （写者只在 pnl_on 时跑，关面板后旧值不许漏出来）。
    //   ★ 窗口必须整段盖住**标签+数值**：标签列 36..39/36..40 是静态 P1_LAB 字，
    //     数值列 41..45/42..46 是 pnl_calc 写的；只盖数值列会让标签留在页面上。
    //   ★ 列号这里必须写 cx[9:4]：lcol2 声明在下面的 §状态条扫描 里（行号靠后，
    //     在这里引用会变成 1 bit 的隐式线网 —— 见 :1906 的同一条告诫）。
    //   ★ v52（㊾）A3 的卡 6 次级行 `U● V● W○`（行 26 列 46..53）**不加进这里**：
    //     它虽然也是每帧写进 lab RAM 的动态内容，但它属于卡片本身而不是模态层 ——
    //     面板关着、键盘收着的时候也要看得见。它靠"P1 静态版面在这 8 格上没有字"
    //     来避免冲突（P1_LAB 的行 26 全空，见 tools/gen_text_ram.py），
    //     所以页面层照常读、照常画，不需要排除窗。
    wire        glyph_page = glyph_bit & (~dlg_cell | val_bit) & ~glyph_pnl_sup
                           & ~(lab_bit & (page == 3'd0) & (cx[9:4] >= 6'd6) &
                               ((lrow2 == 6'd21) || (lrow2 == 6'd34) ||
                                ((lrow2 == 6'd23) && (cx[9:4] >= 6'd36) && (cx[9:4] <= 6'd45)) ||
                                ((lrow2 == 6'd25) && (cx[9:4] >= 6'd36) && (cx[9:4] <= 6'd46))));
    wire        glyph_dlg  = lab_bit & dlg_cell & dlg_cur & dlg_on;

    // =========================================================================
    // 5.11 v20：标题带主操作按钮（P1「标定」→ P7、P4「展开」→ P5、P6「闪烁」）
    //   按钮文字不在这里画：它来自各页 lab 平面（P1 格列 45、P4 格列 45（★ v43/㊵
    //   起，与 P1 同格列；v20..v42 是 6 格的 `EXPAND` 占 43..48）、
    //   P6 格列 44，都在格行 2 = y 32..47），由文字层叠在底色上。
    //   本层只画"白底 + 强调色描边"。
    //   点它的判定在策略层（hit_test 只给 HIT_TITLE_BTN，由页号决定去 P7 / P5 / 切换闪烁）。
    //   ★ v32（㉙）：P6 上这颗按钮是 spec §5.2 第四重冗余「可关闭的 2 Hz 闪烁」的开关。
    //     它的开/关**不写字、也不靠颜色**，而是按钮左侧一个 16x16 复选框：
    //       实心（C_TEXT 填满） = 闪烁开；空心（1 px C_TEXT 描边）= 闪烁关。
    //     这条与 §5.2 的"颜色绝不作为唯一的状态编码"是同一条纪律 —— 复选框的
    //     "填/空"在任何打印/截图/色弱条件下都能读。
    //     ★ 复选框矩形与文字层的「闪烁」（格列 44/45 = x 704..735）**不许重叠**：
    //       复选框取 x 668..683（格列 41..42），文字在它右边。
    // =========================================================================
    wire        tb_page = (page == 3'd0) || (page == 3'd3) || (page == 3'd5);
    wire        tb_any  = tb_page && (cx >= TBTN_X0) && (cx < TBTN_X1) &&
                          (cy >= TBTN_Y0) && (cy < TBTN_Y1);
    wire        tb_edge = tb_any && ((cx == TBTN_X0) || (cx == TBTN_X1 - 12'd1) ||
                                     (cy == TBTN_Y0) || (cy == TBTN_Y1 - 12'd1));
    localparam [11:0] CHK_X0 = 12'd668;
    localparam [11:0] CHK_Y0 = 12'd36;
    wire        chk_zone = (page == 3'd5) &&
                           (cx >= CHK_X0) && (cx < CHK_X0 + 12'd16) &&
                           (cy >= CHK_Y0) && (cy < CHK_Y0 + 12'd16);
    wire        chk_edge = chk_zone && ((cx == CHK_X0) || (cx == CHK_X0 + 12'd15) ||
                                        (cy == CHK_Y0) || (cy == CHK_Y0 + 12'd15));
    wire        chk_mark = chk_zone && (ui_blink_en || chk_edge);
    wire [23:0] tb_col  = tb_edge ? C_ACC : chk_mark ? C_TEXT : C_CARD;

    // ★ v60（T8）：演示开关按钮（只在 P6）。视觉与「闪烁」按钮同构：
    //   1 px 描边 + 左侧 16x16 复选框（实心=开/空心=关），文字「演示」在格列 55。
    wire        db_any  = (page == 3'd5) && (cx >= DEMO_BTN_X0) && (cx < DEMO_BTN_X1) &&
                          (cy >= DEMO_BTN_Y0) && (cy < DEMO_BTN_Y1);
    wire        db_edge = db_any && ((cx == DEMO_BTN_X0) || (cx == DEMO_BTN_X1 - 12'd1) ||
                                     (cy == DEMO_BTN_Y0) || (cy == DEMO_BTN_Y1 - 12'd1));
    localparam [11:0] DCHK_X0 = 12'd848;
    localparam [11:0] DCHK_Y0 = 12'd36;
    wire        dchk_zone = (page == 3'd5) &&
                            (cx >= DCHK_X0) && (cx < DCHK_X0 + 12'd16) &&
                            (cy >= DCHK_Y0) && (cy < DCHK_Y0 + 12'd16);
    wire        dchk_edge = dchk_zone && ((cx == DCHK_X0) || (cx == DCHK_X0 + 12'd15) ||
                                          (cy == DCHK_Y0) || (cy == DCHK_Y0 + 12'd15));
    wire        dchk_mark = dchk_zone && (demo_on || dchk_edge);
    wire [23:0] db_col  = db_edge ? C_ACC : dchk_mark ? C_TEXT : C_CARD;

    // =========================================================================
    // 5.12 v20：P2/P3 页内 Tab 栏（SIM | XY，spec 4.1「左侧导航 + 页内 Tab」）
    //   两个页签各 200x40；选中页签白底 + 强调色描边、未选中导航色 + 网格色描边。
    //   P2 = page 1 选中左边那个，P3 = page 2 选中右边那个。
    //   ★ 命中不在 hit_test 里（矩形压在 P1 卡片 8/9 上，而它不认识页号）⇒
    //     策略层按坐标 + 页号判（disp/enc_top_disp.v 的 tap_tab_sim / tap_tab_xy）。
    // =========================================================================
    wire        tab_page = 1'b0;   // ★ v58：P3 删页、P2 的 Tab 也取消（用户：
                                   //   "单一 Tab 可删、让 40 px 给波形"）。
                                   //   铉成常量 0 后整个页签绘制枝被剪掉。
    wire        tab0_any = tab_page && (cx >= TAB0_X0) && (cx < TAB0_X1) &&
                           (cy >= TAB_Y0) && (cy < TAB_Y1);
    wire        tab1_any = tab_page && (cx >= TAB1_X0) && (cx < TAB1_X1) &&
                           (cy >= TAB_Y0) && (cy < TAB_Y1);
    wire        tab_sel0 = (page == 3'd1);
    wire        tab_any  = tab0_any || tab1_any;
    wire        tab_edge = tab_any && ((cy == TAB_Y0) || (cy == TAB_Y1 - 12'd1) ||
                                       (cx == TAB0_X0) || (cx == TAB0_X1 - 12'd1) ||
                                       (cx == TAB1_X0) || (cx == TAB1_X1 - 12'd1));
    wire        tab_hot  = (tab0_any && tab_sel0) || (tab1_any && !tab_sel0);
    wire [23:0] tab_col  = tab_edge ? (tab_hot ? C_ACC : C_GRID) :
                          tab_hot  ? C_CARD : C_NAV;

    // =========================================================================
    // 5.13 v22：倍频编辑面板（spec 4.5 卡 2 下钻 / 6.2 两阶段提交 / 6.3 预设+长按
    //           加速+离散滑条 / 6.5 「回到上一次值」）
    //   ★ 这一层**只画图形**，不做任何命中判定：坐标/编号的判定全在策略层
    //     disp/ui_panel.v（它的矩形表与这里的常量是两处共同契约）。
    //   五件东西：面板底 + 标题、[−]/[+] 两个步进按钮（含长按进度真圆环）、
    //   离散滑条（8 档 + 轨道 + 选中档）、CANCEL/APPLY/BACK 三个命令按钮。
    //   配色全部复用既有色板：C_BG 面板底 / C_ACC 强调 / C_GRID 网格 / C_SEC
    //   选中档 / C_TRACK 轨道 / 24'hDCE9F5 按下态（与 C_TRACK 同色不同用）。
    // =========================================================================
    wire        pnl_any  = pnl_on && (cx >= PNL_X0) && (cx < PNL_X1) &&
                           (cy >= PNL_Y0) && (cy < PNL_Y1);
    wire        pnl_edge = pnl_any && ((cx == PNL_X0) || (cx == PNL_X1 - 12'd1) ||
                                       (cy == PNL_Y0) || (cy == PNL_Y1 - 12'd1));
    //   [−] / [+]：64x64 白底方框，按下期间整块变浅蓝、描边变强调色。
    wire        mns_any  = pnl_on && !pnl_kp_on && (cx >= MNS_X0) && (cx < MNS_X1) &&
                           (cy >= STP_Y0) && (cy < STP_Y1);
    wire        pls_any  = pnl_on && !pnl_kp_on && (cx >= PLS_X0) && (cx < PLS_X1) &&
                           (cy >= STP_Y0) && (cy < STP_Y1);
    wire        mns_edge = mns_any && ((cx == MNS_X0) || (cx == MNS_X1 - 12'd1) ||
                                        (cy == STP_Y0) || (cy == STP_Y1 - 12'd1));
    wire        pls_edge = pls_any && ((cx == PLS_X0) || (cx == PLS_X1 - 12'd1) ||
                                        (cy == STP_Y0) || (cy == STP_Y1 - 12'd1));
    wire        mns_down = (pnl_press == 4'd1);
    wire        pls_down = (pnl_press == 4'd2);
    //   [−] / [+] 的符号**用图形画**，不走字库：64 px 按钮的中心在 x=192 / 832、
    //   y=496，而 16 px 字格的格心只能落在 183.5/199.5 这种位置 —— 用字符会偏
    //   8 px。横杠 32x6（y 493..498）、竖杠 6x32（x 829..834 / y 480..511）。
    wire [11:0] stp_cx = mns_any ? 12'd192 : 12'd832;
    wire        stp_hbar = pnl_on && (mns_any || pls_any) &&
                           (cy >= 12'd493) && (cy <= 12'd498) &&
                           (cx >= (stp_cx - 12'd16)) && (cx <= (stp_cx + 12'd15));
    wire        stp_vbar = pnl_on && pls_any &&
                           (cx >= (stp_cx - 12'd3)) && (cx <= (stp_cx + 12'd2)) &&
                           (cy >= 12'd480) && (cy <= 12'd511);
    wire        stp_sym  = stp_hbar | stp_vbar;
    //   长按加速的"圆环"进度（v29/㉕ 起是真圆环，画在按钮描边**里面**那一圈）：
    //   环带内径 26 px、外径 30 px，沿 64 个 5.625° 的扇区从 12 点起顺时针画。
    //   判定全来自折叠表（`ring_q[4]` = 落在环带内、`ring_q[3:0]` = 折叠象限内
    //   的扇区号），象限由 S2 的 `rlx_hi/rly_hi` 给出 —— 与生成器的 `assemble`
    //   同式，因此不需要象限比较链。★ 进度 6 bit：0 → 不画，63 → 整圈补齐
    //   （64 个扇区 / 63 级进度，最后一级收尾；与矩形环"63 级 = 252 px > 周长
    //   248 px"的行为一致）。
    wire [5:0] ring_k   = {2'b0, ring_q[3:0]};
    wire [5:0] ring_sec = rlx_hi ? (rly_hi ? (6'd31 - ring_k) : ring_k) :
                                   (rly_hi ? (6'd32 + ring_k) : (6'd63 - ring_k));
    wire       pnl_ring = pnl_on && (mns_down || pls_down) && (mns_any || pls_any) &&
                          ring_q[4] && ((pnl_prog == 6'd63) || (ring_sec < pnl_prog));
    //   ---- v44（㊶）字段切换按钮（×倍频 ⇄ ÷分频，P_FLD = 8）----
    //   64x64 白底方框，放在面板上方空白带、紧挨着下面那块数值窗（KPV_*）。
    //   图标用图形画（面板内字库被 glyph_pnl_sup 抑制）：× 是两条 45° 斜杠、
    //   ÷ 是一条横杠加上下两点。按下期间浅蓝底 + 强调色描边/图形。
    wire        fld_any  = pnl_on && !pnl_kp_on && (cx >= FLD_X0) && (cx < FLD_X1) &&
                                                  (cy >= FLD_Y0) && (cy < FLD_Y1);
    wire        fld_edge = fld_any && ((cx == FLD_X0) || (cx == FLD_X1 - 12'd1) ||
                                        (cy == FLD_Y0) || (cy == FLD_Y1 - 12'd1));
    wire        fld_down = (pnl_press == 4'd8);        // P_FLD（与 ui_panel 同编号）
    localparam [11:0] FLD_CX = FLD_X0 + 12'd32;        // 图标中心 (272, 376)
    localparam [11:0] FLD_CY = FLD_Y0 + 12'd32;
    wire [11:0] fld_ax = (cx >= FLD_CX) ? (cx - FLD_CX) : (FLD_CX - cx);
    wire [11:0] fld_ay = (cy >= FLD_CY) ? (cy - FLD_CY) : (FLD_CY - cy);
    wire [11:0] fld_ad = (fld_ax >= fld_ay) ? (fld_ax - fld_ay) : (fld_ay - fld_ax);
    wire        fld_xpx  = fld_any && (fld_ad <= 12'd1) && (fld_ax <= 12'd15);  // 31x31 的 ×
    wire        fld_dbar = fld_any && (fld_ax <= 12'd12) && (fld_ay <= 12'd1);  // 25x3 横杠
    wire        fld_ddot = fld_any && (fld_ax <= 12'd2) && (fld_ay >= 12'd8) &&
                           (fld_ay <= 12'd11);                                 // 上下各一个点
    wire        fld_sym  = pnl_fld ? (fld_dbar || fld_ddot) : fld_xpx;
    //   离散滑条：轨道 32 px 高 + 8 根刻度（档 i 中心 = SLD_X0 + 64*i + 32）；
    //   选中档的 64 px 区间用次级强调色铺底（spec 6.3 的"档位吸附"要让用户看见
    //   档在哪），当前档再压一根强调色游标。
    //   ★ v44（㊶）：滑条选中**活动字段**的档 —— ×字段 = 倍频档 0..7、÷字段 =
    //     分频码 0..7，两边都是 8 格 × 64 px，所以几何一个字不用改。
    wire [2:0]  pnl_ai   = pnl_fld ? pnl_didx : pnl_idx;
    wire        sl_any   = pnl_on && !pnl_kp_on && (cx >= SLD_X0) && (cx < SLD_X1) &&
                           (cy >= SLD_Y0) && (cy < SLD_Y1);
    wire        sl_track = sl_any && (cy >= SLD_TRK_Y0) && (cy < SLD_TRK_Y1);
    wire        sl_zone  = sl_track &&
                           (cx >= (SLD_X0 + {3'b0, pnl_ai, 6'b0})) &&
                           (cx <  (SLD_X0 + {3'b0, pnl_ai, 6'b0} + 12'd64));
    wire        sl_tick  = sl_any && (cy >= SLD_TRK_Y0 - 12'd8) &&
                           (cy < SLD_TRK_Y1 + 12'd8) &&
                           ((cx == SLD_X0 + 12'd32) || (cx == SLD_X0 + 12'd96) ||
                            (cx == SLD_X0 + 12'd160) || (cx == SLD_X0 + 12'd224) ||
                            (cx == SLD_X0 + 12'd288) || (cx == SLD_X0 + 12'd352) ||
                            (cx == SLD_X0 + 12'd416) || (cx == SLD_X0 + 12'd480));
    wire        sl_cur   = sl_zone && (cy >= SLD_TRK_Y0 - 12'd12) &&
                           (cy < SLD_TRK_Y1 + 12'd12) && (cx == SLD_X0 + 12'd32 + {3'b0, pnl_ai, 6'b0});
    //   三个命令按钮：白底 + 网格色描边；APPLY 在"待应用"时描边转强调色并变浅黄；
    //   BACK 在"没有上一次值"时压暗（告诉用户这一路暂时不可用，spec 6.5）。
    wire        ccl_any = pnl_on && (cx >= CCL_X0) && (cx < CCL_X1) &&
                          (cy >= CMD_Y0) && (cy < CMD_Y1);
    wire        apl_any = pnl_on && (cx >= APL_X0) && (cx < APL_X1) &&
                          (cy >= CMD_Y0) && (cy < CMD_Y1);
    wire        bck_any = pnl_on && (cx >= BCK_X0) && (cx < BCK_X1) &&
                          (cy >= CMD_Y0) && (cy < CMD_Y1);
    wire        ccl_edge = ccl_any && ((cx == CCL_X0) || (cx == CCL_X1 - 12'd1) ||
                                        (cy == CMD_Y0) || (cy == CMD_Y1 - 12'd1));
    wire        apl_edge = apl_any && ((cx == APL_X0) || (cx == APL_X1 - 12'd1) ||
                                        (cy == CMD_Y0) || (cy == CMD_Y1 - 12'd1));
    wire        bck_edge = bck_any && ((cx == BCK_X0) || (cx == BCK_X1 - 12'd1) ||
                                        (cy == CMD_Y0) || (cy == CMD_Y1 - 12'd1));
    // ---------------------------------------------------------------------
    //   v33（㉚）数字键盘（spec 6.3 的最后一条：数字键盘兜底）
    //     kp_on = 0：面板右上角多一颗「键盘」入口按钮（KPB_*）；
    //     kp_on = 1：整张面板换成键盘 —— 左 3x4 键位、右三位输入窗。
    //   ★ 键上的十个数字用 disp/seg7.v 画（面板内的字库字形被 glyph_pnl_sup
    //     抑制，val 平面的 48 px 数字同样被抑制），← / ↵ 用线段图形。
    //   ★ 键盘模式下**不画面板标题**（lab 行 21 = y 336..352 正压在第 1 行键上，
    //     标题字符格在 x 112..208）；三个命令按钮的标签（行 34 = y 544..560）
    //     在键盘下方照常画 —— CANCEL/APPLY 在键盘模式下仍然有效。
    // ---------------------------------------------------------------------
    wire        kp_mode_d = pnl_on && pnl_kp_on;

    //   「键盘」入口按钮：白底 + 网格色描边，按下变浅蓝；图标是 12 点阵
    //   （3 列 × 4 行 6x6 方块，x = 12/29/46、y = 8/22/36/50）
    wire        kpb_any  = pnl_on && !pnl_kp_on && (cx >= KPB_X0) && (cx < KPB_X1) &&
                           (cy >= KPB_Y0) && (cy < KPB_Y1);
    wire        kpb_edge = kpb_any && ((cx == KPB_X0) || (cx == KPB_X1 - 12'd1) ||
                                       (cy == KPB_Y0) || (cy == KPB_Y1 - 12'd1));
    wire        kpb_down = (pnl_press == 4'd7);        // P_KEY（与 ui_panel 同编号）
    wire [11:0] kpb_lx   = kpb_any ? (cx - KPB_X0) : 12'd0;
    wire [11:0] kpb_ly   = kpb_any ? (cy - KPB_Y0) : 12'd0;
    wire        kpb_dotx = ((kpb_lx >= 12'd12) && (kpb_lx < 12'd18)) ||
                           ((kpb_lx >= 12'd29) && (kpb_lx < 12'd35)) ||
                           ((kpb_lx >= 12'd46) && (kpb_lx < 12'd52));
    wire        kpb_doty = ((kpb_ly >= 12'd8)  && (kpb_ly < 12'd14)) ||
                           ((kpb_ly >= 12'd22) && (kpb_ly < 12'd28)) ||
                           ((kpb_ly >= 12'd36) && (kpb_ly < 12'd42)) ||
                           ((kpb_ly >= 12'd50) && (kpb_ly < 12'd56));
    wire        kpb_dot  = kpb_any && kpb_dotx && kpb_doty;

    //   键盘栅格：整块 148x200、每格 44x44；8 px 的缝属于"底"（按在缝里不响应，
    //   与 disp/ui_panel.v 的 kp_hit_of 同一个判据）
    wire        kp_in_grid = kp_mode_d && (cx >= KP_X0) && (cx < KP_X0 + 12'd148) &&
                                           (cy >= KP_Y0) && (cy < KP_Y0 + 12'd200);
    wire [11:0] kp_rx  = kp_in_grid ? (cx - KP_X0) : 12'd0;
    wire [11:0] kp_ry  = kp_in_grid ? (cy - KP_Y0) : 12'd0;
    wire [1:0]  kp_gc  = (kp_rx >= 12'd104) ? 2'd2 : (kp_rx >= 12'd52) ? 2'd1 : 2'd0;
    wire [1:0]  kp_gr  = (kp_ry >= 12'd156) ? 2'd3 : (kp_ry >= 12'd104) ? 2'd2 :
                         (kp_ry >= 12'd52)  ? 2'd1 : 2'd0;
    wire [11:0] kp_lx  = kp_rx - ((kp_gc == 2'd0) ? 12'd0 : (kp_gc == 2'd1) ? 12'd52 : 12'd104);
    wire [11:0] kp_ly  = kp_ry - ((kp_gr == 2'd0) ? 12'd0 : (kp_gr == 2'd1) ? 12'd52 :
                                  (kp_gr == 2'd2) ? 12'd104 : 12'd156);
    wire        kp_box = kp_in_grid && (kp_lx < KP_BTN) && (kp_ly < KP_BTN);
    wire        kp_box_edge = kp_box && ((kp_lx == 12'd0) || (kp_lx == KP_BTN - 12'd1) ||
                                          (kp_ly == 12'd0) || (kp_ly == KP_BTN - 12'd1));
    //   (行,列) → 键码：与 disp/ui_panel.v 的 kp_key_of 同式（手机键盘排布）
    function [3:0] kp_keyf;
        input [1:0] r, c;
        begin
            case ({r, c})
                4'd0:  kp_keyf = 4'd1;    4'd1:  kp_keyf = 4'd2;    4'd2:  kp_keyf = 4'd3;
                4'd4:  kp_keyf = 4'd4;    4'd5:  kp_keyf = 4'd5;    4'd6:  kp_keyf = 4'd6;
                4'd8:  kp_keyf = 4'd7;    4'd9:  kp_keyf = 4'd8;    4'd10: kp_keyf = 4'd9;
                4'd12: kp_keyf = 4'd10;   4'd13: kp_keyf = 4'd0;
                default: kp_keyf = 4'd11;
            endcase
        end
    endfunction
    wire [3:0]  kp_key  = kp_keyf(kp_gr, kp_gc);
    wire        kp_down = kp_box && (pnl_kp_sel == kp_key);
    //   格子序号 = 3*行 + 列（0..11）→ 该格画的数字；15 = 不画（← / ↵ 用线段）
    function [3:0] kp_key_digit;
        input integer i;
        begin
            kp_key_digit = (i == 10) ? 4'd0 :        // 第 4 行中间 = 0
                           (i >= 9)  ? 4'd15 :       // (3,0) = ←、(3,2) = ↵
                                       (i[3:0] + 4'd1);   // 0..8 → 1..9
        end
    endfunction
    wire [11:0] kp_dig_on;            // 12 个数字字段的输出（顺序 = 3*行 + 列）
    genvar gk;
    generate
        for (gk = 0; gk < 12; gk = gk + 1) begin : g_kp_digit
            seg7 #(.X0(12'd124 + (12'd52 * (gk % 3))),
                   .Y0(12'd334 + (12'd52 * (gk / 3))),
                   .BIG(1'b0)) u_key_digit (
                .cx(cx), .cy(cy), .d(kp_key_digit(gk)), .blank(1'b0),
                .on(kp_dig_on[gk]));
        end
    endgenerate
    wire [3:0]  kp_idx = {1'b0, kp_gr, 1'b0} + {2'b0, kp_gr} + {2'b0, kp_gc};
    wire        kp_in_dfield = kp_box && (kp_lx >= 12'd12) && (kp_lx < 12'd32) &&
                               (kp_ly >= 12'd6) && (kp_ly < 12'd38) &&
                               (kp_key != 4'd10) && (kp_key != 4'd11);
    wire        kp_digit_px  = kp_in_dfield && kp_dig_on[kp_idx];
    //   ←（格子 9）与 ↵（格子 11）：4 px 粗的线段图形
    wire        kp_l_left  = kp_box && (kp_key == 4'd10) &&
                             (((kp_lx >= 12'd8)  && (kp_lx < 12'd12) && (kp_ly >= 12'd14) && (kp_ly < 12'd30)) ||
                              ((kp_lx >= 12'd12) && (kp_lx < 12'd16) && (kp_ly >= 12'd17) && (kp_ly < 12'd27)) ||
                              ((kp_lx >= 12'd16) && (kp_lx < 12'd34) && (kp_ly >= 12'd20) && (kp_ly < 12'd24)));
    wire        kp_l_enter = kp_box && (kp_key == 4'd11) &&
                             (((kp_lx >= 12'd16) && (kp_lx < 12'd20) && (kp_ly >= 12'd10) && (kp_ly < 12'd29)) ||
                              ((kp_lx >= 12'd16) && (kp_lx < 12'd31) && (kp_ly >= 12'd25) && (kp_ly < 12'd29)) ||
                              ((kp_lx >= 12'd27) && (kp_lx < 12'd31) && (kp_ly >= 12'd18) && (kp_ly < 12'd36)) ||
                              ((kp_lx >= 12'd31) && (kp_lx < 12'd35) && (kp_ly >= 12'd22) && (kp_ly < 12'd32)));
    wire [23:0] kp_glyph_col = kp_down ? C_ACC : C_TEXT;
    //   输入窗 / 数值窗：三位 48x80 大字段 + 1 px 外框。同一块窗两种用途
    //   （v44/㊶ 起共用同一组 seg7 实例，省三个大字段）：
    //     · 键盘模式（v33）   —— 显示三位输入，前导零不画，一位都没输入时画 "0"；
    //     · 面板模式（v44）   —— 显示**活动字段的待应用值**：× 字段 = 倍频 1..3 位
    //                            （256 三位、16 两位、8 一位，前导零不画）、
    //                            ÷ 字段 = 分频 1..8 一位。三格右对齐，位数少时左侧留空。
    wire        pv_win   = pnl_on && !pnl_kp_on;
    wire [11:0] pv_iv    = (pnl_inter == 10'd0) ? 12'd256 : {2'b0, pnl_inter};
    wire [11:0] pv_div   = {9'd0, pnl_didx} + 12'd1;   // 分频码 0..7 → ÷1..÷8
    //   ★ 拆位**不用减法链，改成并行比较**（U-45 第三次实测：串行减法链本身就是
    //   关键路径 —— 源 u_disp/pv_num_reg[1]/C、终点 u_disp/pvd_r_reg[3]/D，
    //   20.472 ns / 32 级逻辑（11 个 CARRY4），其中 12.786 ns 是布线；
    //   "3 次减 100 + 10 次减 10"是一条串行链，压不进一个 20 ns 周期）。
    //   面板待应用值 ≤ 256（倍频 1..256、分频 1..8）⇒ 百位只可能是 0/1/2：
    //     百位 = v≥200 ? 2 : v≥100 ? 1 : 0，余数 m = v - 100·百位（0..99）
    //     十位 = m 与 10/20/…/90 的**并行**比较（成立的里取最大的那个）
    //     个位 = m - 10·十位（10·t = t<<3 + t<<1，没有乘法器）
    //   全程没有串行链、没有 * 与 /。位宽论证：倍频编码 0 表示 256（见 pv_iv），
    //   分频 1..8，所以 v ≤ 256 恒成立。
    reg  [11:0] pv_num;   // 待显示的数先锁一拍：跨模块走线不进组合链
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pv_num <= 12'd0;
        else        pv_num <= pnl_fld ? pv_div : pv_iv;
    end
    wire        pv_ge100 = (pv_num >= 12'd100);
    wire        pv_ge200 = (pv_num >= 12'd200);
    wire [3:0]  cd_h  = pv_ge200 ? 4'd2 : (pv_ge100 ? 4'd1 : 4'd0);
    wire [11:0] cd_m  = pv_ge200 ? (pv_num - 12'd200) :
                        (pv_ge100 ? (pv_num - 12'd100) : pv_num);
    wire [3:0]  cd_t  = (cd_m >= 12'd90) ? 4'd9 : (cd_m >= 12'd80) ? 4'd8 :
                        (cd_m >= 12'd70) ? 4'd7 : (cd_m >= 12'd60) ? 4'd6 :
                        (cd_m >= 12'd50) ? 4'd5 : (cd_m >= 12'd40) ? 4'd4 :
                        (cd_m >= 12'd30) ? 4'd3 : (cd_m >= 12'd20) ? 4'd2 :
                        (cd_m >= 12'd10) ? 4'd1 : 4'd0;
    wire [11:0] cd_t10 = {cd_t, 3'b0} + {cd_t, 1'b0};   // 10·t = t<<3 + t<<1
    wire [3:0]  cd_r  = cd_m - cd_t10;                  // 0..9
    //   ★ 拆位结果还要**打一拍**再进 seg7（U-45 首版实测 WNS -2.923 ns：19 条失败
    //   端点的源都是 u_ui_panel/pnl_inter_reg[2]/C、终点都是 u_disp/lcd_rgb_reg[*]/D）。
    //   不打拍，"拆位 → seg7 位图 → pnl_col 优先级链 → 调色板"要在同一个 20 ns
    //   里走完，走不完；两级打拍一共多两个像素时钟，显示上看不出来。
    //   ÷ 字段的 1..8 只占个位 ⇒ 百位/十位天然为 0、两个空白标志也天然成立，
    //   所以下面两个 mux 里不必再判 pnl_fld。
    reg  [3:0]  pvd_h, pvd_t, pvd_r;
    reg         pvd_b2, pvd_b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pvd_h  <= 4'd0;
            pvd_t  <= 4'd0;
            pvd_r  <= 4'd0;
            pvd_b2 <= 1'b1;
            pvd_b1 <= 1'b1;
        end else begin
            pvd_h  <= cd_h;
            pvd_t  <= cd_t;
            pvd_r  <= cd_r;
            pvd_b2 <= (cd_h == 4'd0);
            pvd_b1 <= (cd_h == 4'd0) && (cd_t == 4'd0);
        end
    end
    wire [3:0]  win_d2 = pnl_kp_on ? pnl_kp_d2 : pvd_h;
    wire [3:0]  win_d1 = pnl_kp_on ? pnl_kp_d1 : pvd_t;
    wire [3:0]  win_d0 = pnl_kp_on ? pnl_kp_d0 : pvd_r;
    wire        win_b2 = pnl_kp_on ? (pnl_kp_dig < 2'd3) : pvd_b2;
    wire        win_b1 = pnl_kp_on ? (pnl_kp_dig < 2'd2) : pvd_b1;
    wire        kpv_any  = (kp_mode_d || pv_win) && (cx >= KPV_X0) && (cx < KPV_X1) &&
                                                   (cy >= KPV_Y0) && (cy < KPV_Y1);
    wire        kpv_edge = kpv_any && ((cx == KPV_X0) || (cx == KPV_X1 - 12'd1) ||
                                       (cy == KPV_Y0) || (cy == KPV_Y1 - 12'd1));
    wire        kpv_d2_on, kpv_d1_on, kpv_d0_on;
    seg7 #(.X0(KPV_X), .Y0(KPV_Y), .BIG(1'b1)) u_kpv_d2 (
        .cx(cx), .cy(cy), .d(win_d2), .blank(win_b2), .on(kpv_d2_on));
    seg7 #(.X0(KPV_X + KPV_DX), .Y0(KPV_Y), .BIG(1'b1)) u_kpv_d1 (
        .cx(cx), .cy(cy), .d(win_d1), .blank(win_b1), .on(kpv_d1_on));
    seg7 #(.X0(KPV_X + KPV_DX + KPV_DX), .Y0(KPV_Y), .BIG(1'b1)) u_kpv_d0 (
        .cx(cx), .cy(cy), .d(win_d0), .blank(1'b0), .on(kpv_d0_on));
    wire        kpv_digit = kpv_d2_on || kpv_d1_on || kpv_d0_on;

    wire [23:0] pnl_col = pnl_edge ? C_ACC :
                          pnl_ring ? C_ACC :
                          mns_edge ? (mns_down ? C_ACC : C_GRID) :
                          pls_edge ? (pls_down ? C_ACC : C_GRID) :
                          stp_sym  ? C_TEXT :
                          fld_edge ? (fld_down ? C_ACC : C_GRID) :
                          fld_sym  ? (fld_down ? C_ACC : C_TEXT) :
                          fld_any  ? (fld_down ? 24'hDCE9F5 : C_CARD) :
                          mns_any  ? (mns_down ? 24'hDCE9F5 : C_CARD) :
                          pls_any  ? (pls_down ? 24'hDCE9F5 : C_CARD) :
                          sl_cur   ? C_ACC :
                          sl_zone  ? (sl_track ? C_SEC : C_BG) :
                          sl_tick  ? C_GRID :
                          sl_track ? C_TRACK :
                          ccl_edge ? C_GRID :
                          ccl_any  ? C_CARD :
                          apl_edge ? (pnl_pend ? C_ACC : C_GRID) :
                          apl_any  ? (pnl_pend ? 24'hFFF3CD : C_CARD) :
                          bck_edge ? (pnl_undo_avail ? C_GRID : 24'hC8D2DE) :
                          bck_any  ? (pnl_undo_avail ? C_CARD : 24'hEDF1F6) :
                          // v33（㉚）键盘入口按钮 + 键盘。层级：描边 → 图形 → 底。
                          //   ★ "图形"必须排在"底"**之前**：`kpb_any`/`kp_box`/`kpv_any`
                          //     覆盖的面积包含图形像素，底写在前面会把图标与数字整片
                          //     吞掉（第一版就是这样：面板上只会看到一片白）。
                          //     与 P5 条形图"fill > tick > track"是同一条分层纪律。
                          kpb_edge ? C_GRID :
                          kpb_dot  ? C_TEXT :
                          kpb_any  ? (kpb_down ? 24'hDCE9F5 : C_CARD) :
                          kp_box_edge ? (kp_down ? C_ACC : C_GRID) :
                          kp_digit_px ? kp_glyph_col :
                          kp_l_left   ? kp_glyph_col :
                          kp_l_enter  ? kp_glyph_col :
                          kp_box   ? (kp_down ? 24'hDCE9F5 : C_CARD) :
                          kpv_edge ? C_GRID :
                          kpv_digit ? C_TEXT :
                          kpv_any  ? C_CARD :
                                     C_BG;
    //   面板自己的文字（格行 21 = 标题、格行 34 = 三个按钮标签，见
    //   tools/gen_text_ram.py 的 P1_LAB）：只在面板开着时画，颜色同正文。
    //   ★ 键盘模式下标题（行 21）不画：它在 x 112..208、y 336..352，
    //     正压在键盘第 1 行键（y 328..372）上；命令按钮标签（行 34）照常画。
    //   ★ v51（㊽）B4 再追加两行（面板右侧空白带）：
    //     格行 23 = "等效倍率"（标签列 36..39、数值列 41..45）、
    //     格行 25 = "AB边沿率"（标签列 36..40、数值列 42..46）。
    //     标签是静态字（P1_LAB），数值由 disp/pnl_calc.v 每帧写进 lab RAM。
    //     列窗口与上面 glyph_page 的排除**必须一致**（差一格就是"面板上少一位数字"
    //     或"关面板后浮着一串旧数字"）。
    //     ★ 为什么整窗在列 36 之后：数值窗 KPV 占 x 330..572（列 20..35），
    //       窗内放下任何字都会把大数字/前导空白判据打红（tb §[9b]）。
    wire        pnl_lab_cell = ((lrow2 == 6'd21) && !pnl_kp_on) || (lrow2 == 6'd34) ||
                               ((lrow2 == 6'd23) && (cx[9:4] >= 6'd36) && (cx[9:4] <= 6'd45)) ||
                               ((lrow2 == 6'd25) && (cx[9:4] >= 6'd36) && (cx[9:4] <= 6'd46));
    wire        glyph_pnl    = lab_bit & pnl_lab_cell & pnl_on;

    // ---- v60（T1）：卡 6 的“迷你六通道电平条”整块删除 ----
    //   它是 v49 按 288x256 卡片几何写死的矩形（C6_X0=752/C6_Y0=512）。v59 卡片改 448x152
    //   后这个矩形落进右下 ABZ 卡里，就是上板照片上“右下角一直有蓝色横线”的来源。
    //   U/V/W 的状态已由 stat_chip 的圆点表达，这里不再重复一套。

    wire [23:0] bg_sel  = ui_card   ? ui_card_col :
                          tab_any   ? tab_col :
                          tb_any    ? tb_col :
                          db_any    ? db_col :
                          in_card   ? C_CARD :
                          in_sbar   ? C_ACC  :
                          in_nav    ? (nav_sel ? C_SEC : C_NAV) :
                          in_p2_box ? C_PLOT :
                          in_xy_box ? C_PLOT :
                          in_lg_box ? C_PLOT :
                          p7_in_rbox ? C_CARD :
                          p7_in_lbox ? C_PLOT :
                          p5_bzone  ? C_TRACK :
                          in_title  ? C_BG   : C_BG;
    wire [23:0] bg_c6   = bg_sel;   // v60（T1）：电平条已删，这级退化为直通
    wire [23:0] bg_grid = (p2_border || p3_border || p4_grid || p7_grid || p5_grid ||
                           card_edge || card_div)
                          ? C_GRID : bg_c6;
    //   ★ v24（㉕）起条形图槽只在"表格区"里铺：表的行带/列带由 p5_bzone 判定，
    //     v30 重排后它同时是"第 5 列的槽带"（行带内 y = 10..27）。
    //   v21：P5 条形图的 25/50/75/100% 刻度线单独用**次级强调色**。理由：网格色
    //   C_GRID(D6E3F0) 与空槽 C_TRACK(DCE9F5) 几乎同色，画在槽里等于没画；
    //   C_SEC(8FC4EC) 是这一页已有的颜色（导航选中），不新增色。
    //   填充条在下一级 with_bar 覆盖它，所以刻度只显现在没被填满的槽里。
    wire [23:0] bg_edge = p5_btick ? C_SEC : bg_grid;
    wire [23:0] bg_mid  = p2_mid ? C_GRID : bg_edge;
    //   v60（T5）：细栅格用最浅的网格色，刻度条用轨迹底色 → 遇上则提升
    wire [23:0] bg_p2grid = (p2_gridv || p2_gridh) ? C_GRID : bg_mid;
    wire [23:0] bg_p2sc   = p2_scale ? (p2_tick ? C_GRID : C_PLOT) : bg_p2grid;
    wire [23:0] bg_axis = p3_axis ? C_GRID : bg_mid;
    //   v60（T5）：刻度条盖在轨迹上（它是"坐标轴"），其余区域轨迹在栅格上面
    wire [23:0] with_wave = p2_scale ? bg_p2sc :
                            (trace_a ? C_TR_A : (trace_b ? C_TR_B : bg_p2sc));
    wire [23:0] with_dot  = xy_dot ? C_ACC : with_wave;
    wire [23:0] with_lg   = (lg_trace_px || lg_swatch) ? lg_ch_col(lg_row) : with_dot;
    wire [23:0] with_bar  = p5_fill ? C_ACC : with_lg;
    //   曲线画在文字下面：右框本来没有曲线命中，左框的标题文字压在曲线区之外。
    //   ★ v75（D）：先铺**参考线**再画曲线 —— 曲线是 min/max 包络、会盖住参考线，
    //     这与"数据优先"的读图顺序一致（参考线是背景标尺，不是数据）。
    //     参考行 = P7_CVY0 + 120：120 是 p7_ram 的 INIT 值 {8'd120,8'd120}
    //     （标定正确时的平带行号），也是 p7_view 的 clamp 中点，所以三者同源。
    wire [23:0] with_cv   = p7_in_aft ? C_EPOST : (p7_in_bef ? C_EPRE :
                            (p7_ref ? C_GRID : (p7_ref_q ? C_SEC : with_bar)));
    wire [23:0] with_sw   = p7_swatch ? p7_sw_col : with_cv;
    wire [23:0] txt_col = in_sbar   ? C_CARD : C_TEXT;
    //   ★ v42（㊴）：恢复默认失败的 ✖ —— 只有"那一格的字形墨迹"（lab_bit &
    //     bad_mark2）才涂红；同格其余像素仍走原来的底色/压暗逻辑，于是它是
    //     "一个红 ✖"而不是"一块红方块"。颜色之外还有字形（spec §5.2）。
    wire [23:0] txt_col_dyn = (lab_bit & bad_mark2) ? C_FAULT : txt_col;
    // =========================================================================
    // 5.13 v31（㉘）/ v32（㉙）：spec §5.2 的后两重冗余
    //   第三重「反转视频（白字反色块）」：某张卡的状态只要不是"正常"，就把它的迷你
    //   状态条那 4 个格（64x16 px）整块反转成"状态色底 + 白字"。
    //   第四重「可关闭的 2 Hz 闪烁」（v32）：上面那块反色块按 ~2 Hz 通断。
    //   spec 原文（docs/13_display_ui_requirements.md:242-244）：
    //     `● 正常` / `▲ 警示` / `✖ 故障` = 字形 + 中文文字 + 反转视频（白字反色块）
    //     + 可关闭的 2 Hz 闪烁。**颜色绝不作为唯一的状态编码**。
    //   ★ 反转只落在**状态条**上、不是整张卡：反转的语义是"这一行是告警"；整卡反转
    //     会把 48 px 大数字也反掉，反而看不清数值（spec 的模板里状态条本来就是独立一行）。
    //   ★ 判据用 (lrow2, lcol2) 而不是 (cx, cy)：字形位用的是 S2 的格坐标，两者同拍
    //     （cx = px2、lrow2 = py2[9:4]、lcol2 = cx[9:4]），换成像素绝对坐标会与字形错开一格。
    //   ★ 反转不动字形本身：白字压在状态色底上对比度约 7:1，"有没有反色块"本身就是
    //     第三重信息（● 正常 是透明底、无块）。六张卡的矩形与 `disp/stat_chip.v` 的
    //     ROW_TOP=15 / ROW_BOT=36 / COL_0/1/2 = 6/26/46 逐格一致，两处必须一起改。
    //   ★ 闪烁的频率是**帧量化**的：一帧 = 853,440 px / 50 MHz = 17.0688 ms，
    //     半周期取 **15 帧 = 256.03 ms** ⇒ 全周期 512.06 ms ⇒ **1.953 Hz**
    //     （与 spec 的 2 Hz 差 2.4%；58.59 Hz 帧率下 14 帧会是 2.09 Hz，更远）。
    //     取"帧"而不是"像素计数"是因为 vf_start 已经是一帧的边界，不需要把
    //     853,440 这个魔数再引进来一次。
    //   ★ 关掉闪烁（ui_blink_en = 0）⇒ 反色块常亮，即 ㉘ 的行为**一字不变** ——
    //     所以 ㉗/㉘ 的判据在默认开闪烁时需要对相位可控（测试台强推 blk_ph）。
    //   ★ 闪烁只改"反色块显不显示"，不动状态判据：关半周期里状态条长回"黑字白底"，
    //     与 ● 正常 的观感相同 —— 这正是"闪烁本身是第四重信息"的意思。
    // =========================================================================
    // 闪烁相位：每 15 个帧首翻转一次
    reg [3:0]  blk_div;
    reg        blk_ph;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk_div <= 4'd0;
            blk_ph  <= 1'b0;
        end else if (vf_start) begin
            if (blk_div == 4'd14) begin
                blk_div <= 4'd0;
                blk_ph  <= ~blk_ph;
            end else begin
                blk_div <= blk_div + 4'd1;
            end
        end
    end

    wire [5:0]  lcol2    = cx[9:4];
    //   ★ v77（P1 左下角「Z 计数」是红底且没有数值）：这六块反色底原来是
    //   **v58 三列卡片**的坐标（行 15/36，列 6/26/46），v59 把卡片改成两列三行
    //   之后 stat_chip 挪到行 7/19/31、列 30/60，这里却没跟着改。于是
    //   "角度"卡（chip 3）一进警示/故障，就会在**行 36 列 6..9** 上刷一块
    //   红底 —— 那正好是 "Z计数" 标签所在格（x 96..159、y 576..591）。
    //   现在按 chip = 2*row + col 重写，与 stat_chip.v 的 ROW_*/COL_* 同一套
    //   坐标，反色块落回 "● 正常" 那四格背后（行 36 列 6 因此腾出来给 Z 计数）。
    wire        scbar_c0 = (lrow2 == 6'd7)  && (lcol2 >= 6'd30) && (lcol2 <= 6'd33);
    wire        scbar_c1 = (lrow2 == 6'd7)  && (lcol2 >= 6'd60) && (lcol2 <= 6'd63);
    wire        scbar_c2 = (lrow2 == 6'd19) && (lcol2 >= 6'd30) && (lcol2 <= 6'd33);
    wire        scbar_c3 = (lrow2 == 6'd19) && (lcol2 >= 6'd60) && (lcol2 <= 6'd63);
    wire        scbar_c4 = (lrow2 == 6'd31) && (lcol2 >= 6'd30) && (lcol2 <= 6'd33);
    wire        scbar_c5 = (lrow2 == 6'd31) && (lcol2 >= 6'd60) && (lcol2 <= 6'd63);
    wire        scbar_any = (page == 3'd0) && (scbar_c0 || scbar_c1 || scbar_c2 ||
                                               scbar_c3 || scbar_c4 || scbar_c5);
    wire [1:0]  scbar_sel = scbar_c0 ? sc_chip_st[1:0]  :
                            scbar_c1 ? sc_chip_st[3:2]  :
                            scbar_c2 ? sc_chip_st[5:4]  :
                            scbar_c3 ? sc_chip_st[7:6]  :
                            scbar_c4 ? sc_chip_st[9:8]  : sc_chip_st[11:10];
    wire        scbar_inv = scbar_any && (scbar_sel != 2'd0);   // 只有警示/故障反转
    wire [23:0] scbar_bg  = (scbar_sel == 2'd2) ? C_FAULT : C_WARN;
    //   v32：这一拍到底显不显示反色块 —— 闪烁关 ⇒ 恒显（㉘ 的行为）
    wire        scbar_blk = scbar_inv && (ui_blink_en ? blk_ph : 1'b1);
    // v19 层级：页面底/卡片/波形 → P6 危险区 → 文字 → 状态条图形 → 活性灯/准星
    //           → 模态（遮罩 + 对话框 + 对话框文字，压过一切）
    wire [23:0] with_dz   = dz_px ? dz_col : with_sw;
    //   ★ v77（上板：P2 底栏 宽度标签 字号偏小、贴左下有压线感）：字库只有
    //   11x14 与 30x48 两档，中间那档不存在（字号由 disp/font_rom.v 定死），
    //   所以"放大一档"做不到。改成**加深色底 + 白字反色**：同一档字号下，
    //   白字压强调色底的可读性明显高过深灰字压浅蓝页底，视觉上也就不"糊"。
    //   位置同时右移到格列 55..62（x 880..1007），右沿像原来贴左沿那样内缩 16 px，
    //   色底块（格列 54..63）贴到波形框右沿 1024 —— 从"贴在左下角"变成
    //   "坐标轴右端的刻度注"。
    wire        p2w_chip = (page == 3'd1) && (lrow2 == 6'd36) &&
                           (lcol2 >= 6'd54) && (lcol2 <= 6'd63);
    wire [23:0] chip_bg  = p2w_chip ? C_ACC : scbar_bg;
    wire [23:0] with_txt  = (scbar_blk || p2w_chip)
                            ? (glyph_page ? C_CARD : chip_bg)
                            : (glyph_page ? txt_col_dyn : with_dz);
    wire [23:0] with_icon = sig_dot ? sig_col : alm_tri ? alert_col : with_txt;
    wire [23:0] no_dlg    = tch_cross      ? C_ACC   :
                            tch_zone       ? tch_lamp_col :
                            heartbeat_zone ? (tap_alive ? C_OK : C_WARN) :
                            alert_band     ? alert_col : with_icon;
    //   ★ v22 面板不压暗面板外的画面：spec 4.5 明写"上半屏波形继续刷新"，
    //     模态感由面板自身的不透明底 + 强调色描边给（P6 的二次确认才用遮罩）。
    //   ★ v75（C）：照 v22 的原始理由做**半透明**版 —— 用户指出"倍频面板直接叠在
    //     数值上，底下没有压暗"，读不出层次。这里用 50% 棋盘抖动（相邻像素一个
    //     C_DIM、一个原色）代替 v22 的"完全不压"，它等效于 alpha=0.5，既保留
    //     spec 4.5 要求的"波形继续可见"，又让面板区域与背景一眼分开。
    //     不能直接用实色 C_DIM：那会把上半屏波形涂死，等于推翻 spec 4.5。
    //     模态框（dz）仍用实色压暗，语义不同（"不可操作"），优先级也在它之上。
    wire        pnl_dim_px = pnl_on && !pnl_any && ((cx[0] ^ cy[0]) == 1'b0);
    wire [23:0] pnl_dim    = pnl_dim_px ? C_DIM : no_dlg;
    wire [23:0] with_pnl  = pnl_on ? (pnl_any ? (glyph_pnl ? C_TEXT : pnl_col) : pnl_dim)
                                   : no_dlg;
    //   ★ v34（㊲）：询问态下**危险区按钮自己不被遮罩吃掉** —— 否则用户在按住时
    //     看到的仍是"按下就跳出一块压暗"，反馈链在最后一步断掉。放行的范围**只有
    //     那个按钮矩形**（dz_btn：含 64 px 描边、内嵌框与格行 34 的标签字形），
    //     危险区其余部分照旧压暗 ⇒ "模态压过一切"这条契约只在按钮这一个矩形上让步，
    //     且对话框自己的遮罩判据（`expect_px(100,552,C_DIM)`）一字不动。
    //     v42（㊴）：放行范围扩到**两颗**按钮（dz_btn || dz_btn2）—— 恢复默认那条
    //     链路也要有同样的按下反馈与"按钮仍在屏上"的可见性。
    wire        dz_keep   = dlg_on && (dz_btn || dz_btn2);
    wire [23:0] dz_self   = glyph_page ? txt_col_dyn : dz_col;
    wire [23:0] compose   = dlg_on ? (in_dlg_box ? (glyph_dlg ? C_TEXT : dlg_col)
                                                 : (dz_keep ? dz_self : C_DIM))
                                   : with_pnl;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lcd_rgb <= C_BLACK;
            dbg_x   <= 12'd0;
            dbg_y   <= 12'd0;
        end else begin
            dbg_x   <= px2;
            dbg_y   <= py2;
            lcd_rgb <= de2 ? compose : C_BLACK;
        end
    end

endmodule
