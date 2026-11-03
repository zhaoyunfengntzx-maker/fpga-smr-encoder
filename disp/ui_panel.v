// -----------------------------------------------------------------------------
//  disp/ui_panel.v —— 倍频/分频编辑面板（模态）的交互状态机
//
//  为什么需要这个模块：
//    v21 之前，屏上"改倍频"只有两条路：点 P1 卡片 2（直接跳到下一个预设档并
//    立刻提交），或者长按板载 KEY1。两条路都是"一次动作 = 一次写事务"：
//    没有面板、没有待应用态、没有撤销。而 docs/13_display_ui_requirements.md
//    的 4.5 / 6.3 / 6.5 要的是：
//      * 点卡片 2 → **模态编辑面板**（只占下半屏，上半屏波形继续刷新）；
//      * 倍频 2..256 用「预设档位步进器 + 长按加速 + 离散滑条（档位吸附）」；
//      * 分频 1..8 用 8 档步进（v44/㊶ 起：同一套控件 + 一颗字段切换按钮）；
//      * 长按配**进度反馈**，而且"长按绝不作为唯一入口"（点按必须也能用）；
//      *「应用」走与上位机同一条两阶段提交 + 回读确认链路（disp/ui_edit.v），
//        失败由 ui_edit 回滚；
//      * 已写入的值提供"上一次值"记忆，能主动「撤销回上一次值」。
//    本模块就是那张面板的**手势与策略**：几何→控件、手势→档位、应用→写请求、
//    撤销→记忆。像素怎么画由 disp/disp_engine.v 负责。
//
//  ---------------------------------------------------------------------------
//  ★ 两处共同契约（改一边必须改另一边）
//  ---------------------------------------------------------------------------
//    面板矩形与 6 个控件矩形在这里以参数给出，disp/disp_engine.v 用同名常量
//    画同样的矩形。disp/tb_ui_panel.v 与 disp/tb_disp_engine.v 各自断言边界值，
//    只改一边会被测试台直接报出来 —— 与 hit_test.v / disp_engine.v 之间那条
//    "触摸矩形 vs 绘制矩形"的契约是同一套做法。
//
//  ---------------------------------------------------------------------------
//  手势（只用"按下 / 按住 / 抬起"三样；I2C 采样率就是时间分辨率）
//  ---------------------------------------------------------------------------
//    点按 [−] / [+] ：立刻走一档（**点按永远是入口**，长按只是加速）
//    长按 [−] / [+] ：0.6 s 后开始每 0.2 s 自动走一档，进度由 pnl_prog 给出
//                     （绘制层按它画"沿按钮周长的进度环"）
//    滑条上拖拽     ：手指到哪一档就吸附到哪一档（6.3 的"离散滑条 / 档位吸附"）
//    手指出按钮     ：立刻停止加速（不需要抬起事件，容错更好）
//    取消 / 应用 / BACK：按下即生效
//
//  档位表固定为 spec 6.3 的 8 档：2 / 4 / 8 / 16 / 32 / 64 / 128 / 256，
//  编码沿用 disp/ui_edit.v 的约定（**0 表示 256**）。面板打开时把待应用值
//  吸附到"不大于回读值的最大档"：寄存器里可能是上位机写的任意值（例如 100），
//  面板是离散步进器，只认档位；回读真值一直显示在 P1 卡片 2 上，两者不矛盾。
//
//  ★ v33（㉚）新增：**数字键盘兜底**（spec 6.3 的最后一条）
//    前三条路（预设档位 / 长按加速 / 离散滑条）都只能落在 spec 列的 8 个档位上，
//    而寄存器里的 `inter` 是 2…256 的**任意**整数（上位机可以写 100）。键盘就是
//    为这种情况准备的：面板上多一颗「键盘」按钮（64x64，`KPB_*`），点开后面板
//    换成 3 列 x 4 行的数字键盘（44x44、间距 8 px ⇒ spec 6.1 的"最小 40 px"与
//    "相邻 ≥8 px"都满足），排布 1 2 3 / 4 5 6 / 7 8 9 / ← 0 ↵。
//      * 数字键拼到最低位（右对齐的三位 BCD），**新值 > 256 的键直接不接受**
//        （比"悄悄改成 256"诚实：用户能看出最后一位没进去）；
//      * ← 退格；↵ 只把值放进"待应用"（**不写寄存器** —— spec 6.2 的两阶段提交
//        一个字都没动，写还是走「应用」→ ui_edit → 回读确认）；
//      * 「取消」在键盘模式里是"退一层"：先收键盘，面板还开着（值不变）；
//      * 键盘只在面板里活着：面板收起 / 跨页 / 进模态都把它一起收掉。
//    键盘上的十个数字是 `disp/seg7.v` 用**图形**画的 —— 面板内字库字形被
//    `glyph_pnl_sup` 抑制，val 平面的 48 px 数字也被抑制，只能用段图形。
//
//  ★ v44（㊶）：**分频 div（1…8）也能在面板里改**（spec 6.3 第二句）
//    面板多一颗 64x64 的字段切换按钮（`FLD_*`，绘制在 disp/disp_engine.v）：
//    当前字段是 ×倍频 时按一下切到 ÷分频，再按切回。切过去之后**同一套控件**
//    全部改作用在分频上：[−]/[+] 走一档（8 档 1..8，两端夹住不绕回）、8 档滑条的
//    第 k 格吸附到 ÷(k+1)、长按加速、数字键盘也跟着走 —— 不再另加一排"只能点、
//    不能滑、不能长按"的按钮（spec 6.3 要的是"div (1…8) 用 8 档步进"，而滑条
//    本来就是 8 档）。
//    ★ 编码口径：面板里的分频码 `pnl_didx` **就是寄存器值**（div = 码 + 1，
//      ÷1 ⇒ 0），与 disp/ui_edit.v 的 `div_code` 同式；滑条第 k 格 = 码 k。
//    ★ 数字键盘在 ÷ 字段里只收一位 1..8：0/9 直接**不接受**（与"越界键不接受"
//      同一条诚实口径）；← 在一位字段里没有可退的位，只做高亮反馈。
//    ★ 打开面板时倍频的待应用值 = **回读真值**，不再吸附成档位：上位机可能写了
//      任意值（例如 100），只改分频时不该顺手把它改成 64 —— 写命令是一条同时写
//      0x0101/0x0102 的 4 字节命令，两个寄存器必须一起给，所以"没动过的那个"
//      必须原样带上。滑条游标仍显示"不大于回读值的最大档"（`pnl_idx`）。
//    ★ 仍未做（记进归档）：面板里没有算出来的"等效倍率 = inter/div"数值与
//      "预测 AB 边沿率" —— 它们仍由 P1 卡片 2 的 "×N ÷M" 与副文本给出
//      （面板开着时那一行显示的是**待应用**的两个值，改前就能看到后果）。
//    （长按进度自 ㉕ 起画的是真圆环；本模块只给 `pnl_prog`，画法是绘制层的事。）
//
//  ---------------------------------------------------------------------------
//  资源与路径
//  ---------------------------------------------------------------------------
//    全部常数比较 + 三个小计数器，不在像素路径上。写请求 req 是单拍，
//    与"板载 KEY1 长按"那条路在策略层做 mux（disp/enc_top_disp.v）。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module ui_panel #(
    // ---- 面板矩形（与 disp/disp_engine.v 的 PNL_* 一一对应）----
    parameter [11:0] PNL_X0 = 12'd96,
    parameter [11:0] PNL_X1 = 12'd928,
    parameter [11:0] PNL_Y0 = 12'd320,
    parameter [11:0] PNL_Y1 = 12'd592,
    // ---- [−] / [+] 步进按钮（64 x 64，spec 6.1 的"主操作 56..64"）----
    parameter [11:0] MNS_X0 = 12'd160,
    parameter [11:0] MNS_X1 = 12'd224,
    parameter [11:0] MNS_Y0 = 12'd464,
    parameter [11:0] MNS_Y1 = 12'd528,
    parameter [11:0] PLS_X0 = 12'd800,
    parameter [11:0] PLS_X1 = 12'd864,
    parameter [11:0] PLS_Y0 = 12'd464,
    parameter [11:0] PLS_Y1 = 12'd528,
    // ---- 离散滑条触区：8 档铺满 512 px ⇒ 64 px 一档（64 是 2 的幂 ⇒ 用移位）----
    parameter [11:0] SLD_X0 = 12'd240,
    parameter [11:0] SLD_X1 = 12'd752,
    parameter [11:0] SLD_Y0 = 12'd448,
    parameter [11:0] SLD_Y1 = 12'd528,
    parameter [11:0] SLD_SPAN = 12'd512,      // = SLD_X1 - SLD_X0
    // ---- 取消 / 应用 / BACK（160 x 48，spec 6.1 的"标准 48"）----
    parameter [11:0] CCL_X0 = 12'd176,
    parameter [11:0] CCL_X1 = 12'd336,
    parameter [11:0] CCL_Y0 = 12'd528,
    parameter [11:0] CCL_Y1 = 12'd576,
    parameter [11:0] APL_X0 = 12'd448,
    parameter [11:0] APL_X1 = 12'd608,
    parameter [11:0] APL_Y0 = 12'd528,
    parameter [11:0] APL_Y1 = 12'd576,
    parameter [11:0] BCK_X0 = 12'd720,
    parameter [11:0] BCK_X1 = 12'd880,
    parameter [11:0] BCK_Y0 = 12'd528,
    parameter [11:0] BCK_Y1 = 12'd576,
    // ---- v33（㉚）数字键盘（与 disp/disp_engine.v 的同名常量一一对应）----
    //   「键盘」入口按钮：64x64，面板右上角空白区（[+] 的上方 8 px），
    //   x 856..920 与 PNL_X1=928 留 8 px 边距。
    parameter [11:0] KPB_X0 = 12'd856,
    parameter [11:0] KPB_X1 = 12'd920,
    parameter [11:0] KPB_Y0 = 12'd392,
    parameter [11:0] KPB_Y1 = 12'd456,
    // ---- v44（㊶）字段切换按钮（与 disp/disp_engine.v 的 FLD_* 一一对应）----
    //   64x64，放在面板上方的空白带里、标题「倍频分频」（格列 7..12 = x 112..207）
    //   右侧：x 240..304、y 344..408。这一带（x 224..840 / y 320..448）在非键盘
    //   模式下没有别的墨迹（面板内所有页面字形都被 glyph_pnl_sup 抑制），
    //   也不会压键盘（键盘栅格 x 112..260 —— 但键盘模式下这颗按钮根本不响应，
    //   见 §2 的 wid_eff）。
    parameter [11:0] FLD_X0 = 12'd240,
    parameter [11:0] FLD_X1 = 12'd304,
    parameter [11:0] FLD_Y0 = 12'd344,
    parameter [11:0] FLD_Y1 = 12'd408,
    //   键位栅格：3 列 x 4 行，44x44 px、间距 8 px（步距 52），
    //   栅格整体 148 x 200，左上角 (112, 328)，右下角 (260, 528) ——
    //   正好**不压** PNL_Y0=320 的上边框与 CMD_Y0=528 的命令行。
    parameter [11:0] KP_X0  = 12'd112,
    parameter [11:0] KP_Y0  = 12'd328,
    parameter [11:0] KP_BTN = 12'd44,
    parameter [11:0] KP_STEP= 12'd52,
    // ---- 长按加速：0.6 s 后每 0.2 s 一档（50 MHz 系统时钟）----
    parameter [24:0] HOLD_CYC = 25'd30_000_000,
    parameter [24:0] REP_CYC  = 25'd10_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 策略层：只有 P1 有这张面板；W1C 模态开着时不响应 ----
    //   ★ page 的口径是"**当前在 P1**"（策略层接的是 `page == 3'd0`），
    //     不是 3 位页号 —— 面板只服务 P1，传页号过来反而容易把极性写反。
    input  wire        page,
    input  wire [1:0]  dlg,
    input  wire        open_req,      // 单拍：点 P1 卡片 2（策略层已判页号/模态/忙闲）

    // ---- 触摸生命周期（disp/hit_test.v v22）----
    input  wire        press_stb,     // 单拍：新的一次按下
    input  wire [11:0] press_x,
    input  wire [11:0] press_y,
    input  wire        held,          // 电平：当前有接触
    input  wire [11:0] cur_x,         // 按住期间最新坐标
    input  wire [11:0] cur_y,
    input  wire        rel_stb,       // 单拍：抬起

    // ---- 提交链路（disp/ui_edit.v 的两阶段提交 + 回读）----
    input  wire [1:0]  ui_state,      // ST_IDLE / ST_BUSY / ST_OK / ST_FAILED
    input  wire [9:0]  tap_inter,     // 回读确认值（编码：0 表示 256）
    input  wire [2:0]  tap_div,       // 回读确认的分频码（= div - 1）

    // ---- 面板状态（绘制层 + val_format 用）----
    output reg         pnl_on,
    output reg  [2:0]  pnl_idx,       // 待应用档位下标 0..7（= ×倍频的档号）
    output reg  [9:0]  pnl_inter,     // 待应用编码值（0 = 256）
    output reg         pnl_fld,       // v44（㊶）：活动字段，0 = ×倍频、1 = ÷分频
    output reg  [2:0]  pnl_didx,      // v44（㊶）：待应用分频码 0..7（div = 码 + 1）
    output reg  [5:0]  pnl_prog,      // 长按进度 0..63（矩形进度环用）
    output reg  [3:0]  pnl_press,     // 当前按住/反馈的控件（0..8，见 P_*）
    output wire        pnl_pend,      // 待应用值 ≠ 回读值（"待应用"态，绘制层标黄）
    output reg         pnl_undo_avail,
    output reg  [9:0]  pnl_undo_inter,
    output reg  [2:0]  pnl_undo_div,

    // ---- v33（㉚）数字键盘状态（绘制层据此改画整张面板）----
    //   ★ kp_on 是 kp_mode 的**镜子**（wire + assign，见 §1b）：第一版漏了这条
    //     驱动，端口停在 X 上，键盘模式的整条通路跟着 X（tb 报
    //     `键盘入口前：键盘是关的 : got X want 0`）。状态只存一处、其余全是镜子，
    //     与 `disp/stat_chip.v` 的 `assign we = (st == S_WR) && !hold;` 同一条纪律。
    output wire        kp_on,         // 键盘模式（= kp_mode 的组合镜像）
    output reg  [3:0]  kp_d2,         // 三位 BCD（**右对齐**：d0 是最新输入的那位）
    output reg  [3:0]  kp_d1,
    output reg  [3:0]  kp_d0,
    output reg  [1:0]  kp_dig,        // 已输入位数 0..3
    output reg  [3:0]  kp_sel,        // 当前按住的键（4'hF = 无）

    // ---- 写请求（单拍；与 KEY1 长按那条路在策略层 mux）----
    output reg         req,
    output reg  [9:0]  req_inter,     // 要写入的倍频编码
    output reg  [2:0]  req_div_code   // 要写入的分频码（寄存器值 = div-1）
);

    localparam [1:0] ST_BUSY = 2'd1,
                     ST_OK   = 2'd2;

    // 控件编号（与 disp/disp_engine.v 的 PNLP_* 对应）
    localparam [3:0] P_NONE = 4'd0,
                     P_MNS  = 4'd1,
                     P_PLS  = 4'd2,
                     P_SLD  = 4'd3,
                     P_CCL  = 4'd4,
                     P_APL  = 4'd5,
                     P_BCK  = 4'd6,
                     P_KEY  = 4'd7,   // v33：键盘键 / 「键盘」入口按钮（同一编号）
                     P_FLD  = 4'd8;   // v44（㊶）：字段切换按钮（×倍频 ⇄ ÷分频）

    // =========================================================================
    // 1. 档位表：spec 6.3 的 8 档 2/4/8/16/32/64/128/256
    //      idx k ⇒ 2^(k+1)；268 以上不可能（k=7 ⇒ 256）
    //      编码：enc = 0 表示 256（沿用 disp/ui_edit.v 的约定）
    // =========================================================================
    function [9:0] preset_enc;
        input [2:0] k;
        begin
            preset_enc = (k == 3'd7) ? 10'd0 : (10'd1 << (k + 3'd1));
        end
    endfunction

    function [8:0] inter_dec;            // 解码成无符号 2..256
        input [9:0] enc;
        begin
            inter_dec = (enc == 10'd0) ? 9'd256 : enc[8:0];
        end
    endfunction

    function [2:0] idx_of;               // "不大于 v 的最大档"（v 已解码）
        input [8:0] v;
        begin
            if      (v >= 9'd256) idx_of = 3'd7;
            else if (v >= 9'd128) idx_of = 3'd6;
            else if (v >= 9'd64)  idx_of = 3'd5;
            else if (v >= 9'd32)  idx_of = 3'd4;
            else if (v >= 9'd16)  idx_of = 3'd3;
            else if (v >= 9'd8)   idx_of = 3'd2;
            else if (v >= 9'd4)   idx_of = 3'd1;
            else                  idx_of = 3'd0;
        end
    endfunction

    // =========================================================================
    // 1b. 数字键盘（spec 6.3 的兜底入口；几何见文件头 KPB_* / KP_*）
    // =========================================================================
    localparam [3:0] KP_BS = 4'd10,     // ← 退格
                     KP_EN = 4'd11,     // ↵ 确认（只进"待应用"）
                     KP_NO = 4'hF;      // 没按在键上

    // 键盘模式。★ 必须声明在 §2 的 `wid_eff` **之前** ——
    //   xvlog 对"先用后声明"报 `VRFC 10-3380 identifier ... is used before its
    //   declaration`（㉗ 的 `disp/stat_chip.v` 也是这样踩过一次）。
    reg kp_mode;
    assign kp_on = kp_mode;             // 镜面输出（见端口处的说明）

    function [1:0] kp_col_of;           // 52 px 一列（44 键 + 8 间距）
        input [11:0] d;
        begin kp_col_of = (d >= 12'd104) ? 2'd2 : (d >= 12'd52) ? 2'd1 : 2'd0; end
    endfunction

    function [1:0] kp_row_of;           // 52 px 一行
        input [11:0] d;
        begin
            kp_row_of = (d >= 12'd156) ? 2'd3 : (d >= 12'd104) ? 2'd2 :
                        (d >= 12'd52)  ? 2'd1 : 2'd0;
        end
    endfunction

    function [11:0] kp_base_of;         // 该列/行的起始偏移 0/52/104/156
        input [1:0] k;
        begin
            kp_base_of = (k == 2'd0) ? 12'd0 : (k == 2'd1) ? 12'd52 :
                         (k == 2'd2) ? 12'd104 : 12'd156;
        end
    endfunction

    // 键码：手机键盘排布 1 2 3 / 4 5 6 / 7 8 9 / ← 0 ↵
    function [3:0] kp_key_of;
        input [1:0] r, c;
        begin
            case ({r, c})
                4'd0:  kp_key_of = 4'd1;
                4'd1:  kp_key_of = 4'd2;
                4'd2:  kp_key_of = 4'd3;
                4'd4:  kp_key_of = 4'd4;
                4'd5:  kp_key_of = 4'd5;
                4'd6:  kp_key_of = 4'd6;
                4'd8:  kp_key_of = 4'd7;
                4'd9:  kp_key_of = 4'd8;
                4'd10: kp_key_of = 4'd9;
                4'd12: kp_key_of = KP_BS;
                4'd13: kp_key_of = 4'd0;
                default: kp_key_of = KP_EN;    // 4'd14 = 右下角
            endcase
        end
    endfunction

    // 键是不是被按住：先判在栅格内，再判落在那 44x44 方块里（8 px 的缝不算按中）
    function kp_hit_of;
        input [11:0] fx, fy;
        reg   [11:0] ex, ey;
        reg   [1:0]  cc, rr;
        begin
            ex = (fx >= KP_X0) ? (fx - KP_X0) : 12'd0;
            ey = (fy >= KP_Y0) ? (fy - KP_Y0) : 12'd0;
            cc = kp_col_of(ex);
            rr = kp_row_of(ey);
            kp_hit_of = (fx >= KP_X0) && (fx < KP_X0 + 12'd148) &&
                        (fy >= KP_Y0) && (fy < KP_Y0 + 12'd200) &&
                        ((ex - kp_base_of(cc)) < KP_BTN) &&
                        ((ey - kp_base_of(rr)) < KP_BTN);
        end
    endfunction

    wire [11:0] kp_pdx = (press_x >= KP_X0) ? (press_x - KP_X0) : 12'd0;
    wire [11:0] kp_pdy = (press_y >= KP_Y0) ? (press_y - KP_Y0) : 12'd0;
    wire [11:0] kp_cdx = (cur_x   >= KP_X0) ? (cur_x   - KP_X0) : 12'd0;
    wire [11:0] kp_cdy = (cur_y   >= KP_Y0) ? (cur_y   - KP_Y0) : 12'd0;

    wire        kp_press = kp_hit_of(press_x, press_y);
    wire        kp_cur   = kp_hit_of(cur_x,   cur_y);
    wire [3:0]  kp_pkey  = kp_key_of(kp_row_of(kp_pdy), kp_col_of(kp_pdx));
    wire [3:0]  kp_ckey  = kp_key_of(kp_row_of(kp_cdy), kp_col_of(kp_cdx));

    // 「键盘」入口按钮的按下（只在**非**键盘模式有效）
    wire        kp_btn_press = (press_x >= KPB_X0) && (press_x < KPB_X1) &&
                               (press_y >= KPB_Y0) && (press_y < KPB_Y1);

    // 三位 BCD → 值。100 = 64+32+4、10 = 8+2：**移位相加**，不用 `*`
    // （U-30 的教训：一次 `x * 16'd188` 就在资源表里多出一个 DSP48）
    function [11:0] kp_dec3;
        input [3:0] a, b, c;            // a = 百位、b = 十位、c = 个位
        begin
            kp_dec3 = (({8'b0, a} << 6) + ({8'b0, a} << 5) + ({8'b0, a} << 2)) +
                      (({8'b0, b} << 3) + ({8'b0, b} << 1)) + {8'b0, c};
        end
    endfunction

    wire [11:0] kp_val   = kp_dec3(kp_d2, kp_d1, kp_d0);   // 当前已输入的值
    wire [11:0] kp_nv    = kp_dec3(kp_d1, kp_d0, kp_pkey); // 再按一个数字键之后
    wire [11:0] kp_bv    = kp_dec3(4'd0, kp_d2, kp_d1);    // 退格之后
    wire        kp_nv_ok = (kp_nv <= 12'd256);
    wire [9:0]  kp_nv_enc = (kp_nv == 12'd256) ? 10'd0 : kp_nv[9:0];
    wire [9:0]  kp_bv_enc = (kp_bv == 12'd256) ? 10'd0 : kp_bv[9:0];

    // 打开键盘时把"待应用值"摆进三位 BCD，用户看得到起点
    wire [8:0]  kp_seed = inter_dec(pnl_inter);
    wire [3:0]  kp_sd2  = (kp_seed >= 9'd200) ? 4'd2 : (kp_seed >= 9'd100) ? 4'd1 : 4'd0;
    wire [8:0]  kp_srem = kp_seed - ((kp_sd2 == 4'd2) ? 9'd200 :
                                     (kp_sd2 == 4'd1) ? 9'd100 : 9'd0);
    wire [3:0]  kp_sd1  = (kp_srem >= 9'd90) ? 4'd9 : (kp_srem >= 9'd80) ? 4'd8 :
                          (kp_srem >= 9'd70) ? 4'd7 : (kp_srem >= 9'd60) ? 4'd6 :
                          (kp_srem >= 9'd50) ? 4'd5 : (kp_srem >= 9'd40) ? 4'd4 :
                          (kp_srem >= 9'd30) ? 4'd3 : (kp_srem >= 9'd20) ? 4'd2 :
                          (kp_srem >= 9'd10) ? 4'd1 : 4'd0;
    wire [8:0]  kp_s10  = ({5'b0, kp_sd1} << 3) + ({5'b0, kp_sd1} << 1);
    wire [3:0]  kp_sd0  = kp_srem - kp_s10;
    wire [1:0]  kp_sdig = (kp_sd2 != 4'd0) ? 2'd3 : (kp_sd1 != 4'd0) ? 2'd2 : 2'd1;
    // v44（㊶）÷字段进键盘时的种子：分频码 + 1 = 1..8，只占个位
    wire [3:0]  kp_dv_d0 = {1'b0, pnl_didx} + 4'd1;

    // =========================================================================
    // 2. 矩形命中（按下那一刻判控件；按住期间判"手指还在不在同一个按钮上"）
    // =========================================================================
    function in_rect;
        input [11:0] x, y, x0, x1, y0, y1;
        begin
            in_rect = (x >= x0) && (x < x1) && (y >= y0) && (y < y1);
        end
    endfunction

    wire [3:0] wid_at_press =
        in_rect(press_x, press_y, MNS_X0, MNS_X1, MNS_Y0, MNS_Y1) ? P_MNS :
        in_rect(press_x, press_y, PLS_X0, PLS_X1, PLS_Y0, PLS_Y1) ? P_PLS :
        in_rect(press_x, press_y, SLD_X0, SLD_X1, SLD_Y0, SLD_Y1) ? P_SLD :
        in_rect(press_x, press_y, CCL_X0, CCL_X1, CCL_Y0, CCL_Y1) ? P_CCL :
        in_rect(press_x, press_y, APL_X0, APL_X1, APL_Y0, APL_Y1) ? P_APL :
        in_rect(press_x, press_y, BCK_X0, BCK_X1, BCK_Y0, BCK_Y1) ? P_BCK :
        in_rect(press_x, press_y, FLD_X0, FLD_X1, FLD_Y0, FLD_Y1) ? P_FLD :
        P_NONE;

    wire [3:0] wid_now =
        in_rect(cur_x, cur_y, MNS_X0, MNS_X1, MNS_Y0, MNS_Y1) ? P_MNS :
        in_rect(cur_x, cur_y, PLS_X0, PLS_X1, PLS_Y0, PLS_Y1) ? P_PLS :
        P_NONE;

    // ---- v33（㉚）：键盘模式下整张面板只剩「键盘键」「CANCEL」「APPLY」----
    //   MNS/PLS/SLD 在键盘模式下不响应：绘制层此时把整张面板换成了键盘
    //   （见 disp/disp_engine.v 的 kp_on 分支），屏幕上没有那三个控件的影子。
    //   ★ v44（㊶）：字段切换按钮在键盘模式下同样不响应（它也被键盘盖住）。
    wire [3:0] wid_eff = kp_mode ?
            (kp_press ? P_KEY :
             in_rect(press_x, press_y, CCL_X0, CCL_X1, CCL_Y0, CCL_Y1) ? P_CCL :
             in_rect(press_x, press_y, APL_X0, APL_X1, APL_Y0, APL_Y1) ? P_APL :
             P_NONE) :
            (kp_btn_press ? P_KEY : wid_at_press);

    // APPLY 写寄存器前把值夹到合同范围 2…256：键盘能敲出 0/1，
    // 而 rtl 契约（rtl/SPEC_interface_contract.md）写的是 2…256。
    // 预设档位与滑条本来就只产生合法值，这条只为键盘存在。
    wire [11:0] pnl_val   = inter_dec(pnl_inter);
    wire [11:0] pnl_clamp = (pnl_val < 12'd2) ? 12'd2 : (pnl_val > 12'd256) ? 12'd256 : pnl_val;
    wire [9:0]  pnl_cenc  = (pnl_clamp == 12'd256) ? 10'd0 : pnl_clamp[9:0];

    // =========================================================================
    // 3. 滑条吸附：x 到档位的映射就是 (cur_x - SLD_X0) / 64，64 是 2 的幂
    //     所以用移位而不是除法器（与 disp/disp_engine.v 的 P4 刻度同一个理由）。
    // =========================================================================
    wire [11:0] sl_dx  = (cur_x > SLD_X0) ? (cur_x - SLD_X0) : 12'd0;
    wire [2:0]  sl_idx = (sl_dx >= SLD_SPAN) ? 3'd7 : sl_dx[8:6];

    // =========================================================================
    // 4. 面板内的档位步进（两端夹住，不绕回：256 再 + 什么也不做）
    //    与 KEY1 那条路（disp/enc_top_disp.v 的 next_preset 会绕回 2）不同 ——
    //    面板是"看得见的档位"，撞到边界不动比跳回去更好理解。
    // =========================================================================
    wire [2:0] idx_up = (pnl_idx == 3'd7) ? 3'd7 : (pnl_idx + 3'd1);
    wire [2:0] idx_dn = (pnl_idx == 3'd0) ? 3'd0 : (pnl_idx - 3'd1);

    // ---- v44（㊶）÷分频的档位步进（8 档 1..8，寄存器码 0..7，两端同样夹住）----
    //   滑条第 k 格 = 分频码 k（`sl_idx` 直接拿来用，不需要第二套映射）；
    //   面板里的分频码就是寄存器值，所以"档位下标"和"要写的码"是同一个数。
    wire [2:0] didx_up = (pnl_didx == 3'd7) ? 3'd7 : (pnl_didx + 3'd1);
    wire [2:0] didx_dn = (pnl_didx == 3'd0) ? 3'd0 : (pnl_didx - 3'd1);

    wire [2:0] open_idx = idx_of(inter_dec(tap_inter));

    // 待应用值 ≠ 回读值。★ 比较的是**解码后的值**：编码 0 与 256 必须算相等。
    //   v44（㊶）：两个字段一起比 —— 只改了分频也算"待应用"（APPLY 会同时写
    //   0x0101/0x0102 两个寄存器，所以"有一个不一样"就是有待应用的内容）。
    assign pnl_pend = (inter_dec(pnl_inter) != inter_dec(tap_inter)) ||
                      (pnl_didx != tap_div);

    // =========================================================================
    // 5. 状态与手势
    // =========================================================================
    reg [3:0]  hold_wid;      // 这次按住从哪个控件开始（P_NONE = 没开始）
    reg [24:0] hold_cnt;      // 长按计时（到 HOLD_CYC 开始加速）
    reg [24:0] rep_cnt;       // 加速后的重复计时
    reg        accel;         // 已经进入加速
    reg        busy_txn;      // 有一笔写事务在飞
    reg        seen_busy;     // 已经见过 ui_edit 进 BUSY（判收尾用）
    reg [9:0]  pre_enc;       // 这笔事务写之前的已确认倍频
    reg [2:0]  pre_div;

    // ---- v33（㉚）数字键盘状态 ----
    //   kp_on / kp_d2 / kp_d1 / kp_d0 / kp_dig / kp_sel 是 **ANSI 端口**（output reg），
    //   在这里不能重复声明；kp_mode 声明在 §1b（wid_eff 之前）。
    //   端口里的三位 BCD 是**右对齐**的：kp_d0 = 最后输入的那位。前导零不显示。

    // 面板收起/跨模态时键盘也必须收（同一条纪律：面板是模态的）
    wire kp_clear = pnl_on && (!page || (dlg != 2'd0));

    // 手指是否还压在"开始那次按下的那个步进按钮"上
    wire hold_ok = held && ((hold_wid == P_MNS) || (hold_wid == P_PLS)) &&
                   (wid_now == hold_wid);

    wire rep_fire  = hold_ok && accel && (rep_cnt >= REP_CYC);
    wire first_fire = hold_ok && !accel && (hold_cnt >= HOLD_CYC);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pnl_on         <= 1'b0;
            pnl_idx        <= 3'd5;               // ×64（寄存器复位值）
            pnl_inter      <= 10'd64;
            pnl_fld        <= 1'b0;               // v44（㊶）：默认活动字段 = ×倍频
            pnl_didx       <= 3'd0;               // v44（㊶）：分频复位 ÷1（码 0）
            pnl_prog       <= 6'd0;
            pnl_press      <= P_NONE;
            pnl_undo_avail <= 1'b0;
            pnl_undo_inter <= 10'd64;
            pnl_undo_div   <= 3'd0;
            req            <= 1'b0;
            req_inter      <= 10'd64;
            req_div_code   <= 3'd0;
            hold_wid       <= P_NONE;
            hold_cnt       <= 25'd0;
            rep_cnt        <= 25'd0;
            accel          <= 1'b0;
            busy_txn       <= 1'b0;
            seen_busy      <= 1'b0;
            pre_enc        <= 10'd64;
            pre_div        <= 3'd0;
            kp_mode        <= 1'b0;
            kp_d2          <= 4'd0;
            kp_d1          <= 4'd0;
            kp_d0          <= 4'd0;
            kp_dig         <= 2'd0;
            kp_sel         <= KP_NO;
        end else begin
            req <= 1'b0;                          // 默认：请求是单拍

            // ---- (1) 面板不跨页、不跨模态 ----
            if (kp_clear) begin
                pnl_on    <= 1'b0;
                pnl_press <= P_NONE;
                hold_wid  <= P_NONE;
                kp_mode   <= 1'b0;
                kp_sel    <= KP_NO;
            end

            // ---- (2) 开面板：点 P1 卡片 2 ----
            if (open_req && page && !pnl_on && (dlg == 2'd0) && (ui_state != ST_BUSY)) begin
                pnl_on    <= 1'b1;
                pnl_idx   <= open_idx;                // 游标：不大于回读值的最大档
                pnl_inter <= tap_inter;               // v44（㊶）：待应用值 = 回读真值
                pnl_fld   <= 1'b0;                    // 每次打开都从 ×倍频 起
                pnl_didx  <= tap_div;                 // ÷分频的待应用值 = 回读码
                pnl_press <= P_NONE;
                hold_wid  <= P_NONE;
                hold_cnt  <= 25'd0;
                rep_cnt   <= 25'd0;
                accel     <= 1'b0;
            end

            // ---- (3) 按下：先判落在哪个控件 ----
            if (pnl_on && !busy_txn && press_stb) begin
                hold_wid  <= wid_eff;
                hold_cnt  <= 25'd0;
                rep_cnt   <= 25'd0;
                accel     <= 1'b0;
                pnl_press <= wid_eff;

                if (wid_eff == P_KEY) begin
                    if (kp_mode) begin
                        // ---- 键盘模式：按的是某一个键 ----
                        kp_sel <= kp_pkey;
                        if (kp_pkey <= 4'd9) begin
                            if (pnl_fld) begin
                                // ---- v44（㊶）÷字段：只收一位 1..8 ----
                                //   0 与 9 **不接受该键**（与倍频那条"越界键不接受"
                                //   同一条诚实口径：用户能看出这一下没进去）。
                                if ((kp_pkey >= 4'd1) && (kp_pkey <= 4'd8)) begin
                                    kp_d2    <= 4'd0;
                                    kp_d1    <= 4'd0;
                                    kp_d0    <= kp_pkey;
                                    kp_dig   <= 2'd1;
                                    pnl_didx <= kp_pkey[2:0] - 3'd1;   // ÷N ⇒ 码 N-1
                                end
                            end else begin
                                // 数字键：右移一位塞进去。>256 时**不接受该键**
                                //（悄悄截成 256 会让人以为输入成功，比不接受更糟）；
                                // 首位也不接受 0（0 只能出现在十位/个位）。
                                if (kp_nv_ok && !((kp_dig == 2'd0) && (kp_pkey == 4'd0))) begin
                                    kp_d2     <= kp_d1;
                                    kp_d1     <= kp_d0;
                                    kp_d0     <= kp_pkey;
                                    kp_dig    <= (kp_dig == 2'd3) ? 2'd3 : (kp_dig + 2'd1);
                                    pnl_inter <= kp_nv_enc;
                                end
                            end
                        end else if (kp_pkey == KP_BS) begin
                            // v44（㊶）：÷字段是一位数，没有可退的位 —— ← 只做高亮反馈
                            if (!pnl_fld) begin
                                kp_d2     <= 4'd0;
                                kp_d1     <= kp_d2;
                                kp_d0     <= kp_d1;
                                kp_dig    <= (kp_dig == 2'd0) ? 2'd0 : (kp_dig - 2'd1);
                                pnl_inter <= kp_bv_enc;
                            end
                        end else begin
                            // KP_EN：确认 = 收键盘，值留在"待应用"。
                            // spec §6.2 的两阶段提交不变：真正写寄存器要按 APPLY，
                            // 屏上只显示回读确认过的值。
                            kp_mode <= 1'b0;
                            kp_sel  <= KP_NO;
                        end
                    end else begin
                        // ---- 非键盘模式：这颗按钮 = 进键盘，并把当前字段的待应用值
                        //      摆成种子（v44（㊶）：÷字段的种子是"码 + 1" = 1..8，
                        //      只占个位）----
                        kp_mode <= 1'b1;
                        if (pnl_fld) begin
                            kp_d2  <= 4'd0;
                            kp_d1  <= 4'd0;
                            kp_d0  <= kp_dv_d0;
                            kp_dig <= 2'd1;
                        end else begin
                            kp_d2   <= kp_sd2;
                            kp_d1   <= kp_sd1;
                            kp_d0   <= kp_sd0;
                            kp_dig  <= kp_sdig;
                        end
                        kp_sel  <= KP_NO;
                    end
                end else if (wid_eff == P_MNS) begin
                    if (pnl_fld) begin
                        pnl_didx <= didx_dn;                  // ÷字段：÷1..÷8 走一档
                    end else begin
                        pnl_idx   <= idx_dn;                  // 点按 = 立刻走一档
                        pnl_inter <= preset_enc(idx_dn);
                    end
                end else if (wid_eff == P_PLS) begin
                    if (pnl_fld) begin
                        pnl_didx <= didx_up;
                    end else begin
                        pnl_idx   <= idx_up;
                        pnl_inter <= preset_enc(idx_up);
                    end
                end else if (wid_eff == P_SLD) begin
                    if (pnl_fld) begin
                        pnl_didx <= sl_idx;                   // 第 k 格 = 分频码 k
                    end else begin
                        pnl_idx   <= sl_idx;                  // 点滑条 = 直接吸附
                        pnl_inter <= preset_enc(sl_idx);
                    end
                end else if (wid_eff == P_FLD) begin
                    // ---- v44（㊶）：×倍频 ⇄ ÷分频。键盘模式下 wid_eff 里没有这一项
                    //      （绘制层此时把整张面板换成了键盘），所以这里不用管键盘状态。
                    pnl_fld <= ~pnl_fld;
                end else if (wid_eff == P_CCL) begin
                    if (kp_mode) begin
                        kp_mode   <= 1'b0;      // CANCEL = "退一层"：先收键盘，面板还在
                        kp_sel    <= KP_NO;
                    end else begin
                        pnl_on    <= 1'b0;      // 取消 = 什么都不写
                        pnl_press <= P_NONE;
                        hold_wid  <= P_NONE;
                    end
                end else if (wid_eff == P_APL) begin
                    if (!pnl_pend) begin
                        pnl_on    <= 1'b0;                    // 没有改动：不写寄存器，收起
                        pnl_press <= P_NONE;
                        hold_wid  <= P_NONE;
                    end else begin
                        req          <= 1'b1;                 // 两阶段提交 + 回读（ui_edit）
                        req_inter    <= pnl_cenc;             // 夹到 2…256（键盘能敲出 0/1）
                        req_div_code <= pnl_didx;             // v44（㊶）：待应用分频码
                        pre_enc      <= tap_inter;            // 撤销目标 = 写之前的真值
                        pre_div      <= tap_div;
                        busy_txn     <= 1'b1;
                        seen_busy    <= 1'b0;
                    end
                end else if (wid_eff == P_BCK) begin
                    if (pnl_undo_avail) begin
                        req          <= 1'b1;                 // 主动撤销：也走回读确认那条路
                        req_inter    <= pnl_undo_inter;
                        req_div_code <= pnl_undo_div;
                        pre_enc      <= tap_inter;            // 换过去的那个成为新的"上一次值"
                        pre_div      <= tap_div;
                        busy_txn     <= 1'b1;
                        seen_busy    <= 1'b0;
                    end
                end
            end

            // ---- (4) 拖拽 / 滑动：手指到哪一档就吸附到哪一档 ----
            else if (pnl_on && !busy_txn && held && (hold_wid == P_SLD)) begin
                if (pnl_fld) pnl_didx <= sl_idx;              // v44：÷字段拖拽
                else begin
                    pnl_idx   <= sl_idx;
                    pnl_inter <= preset_enc(sl_idx);
                end
                pnl_press <= P_SLD;
            end

            // ---- (4b) 键盘：按住时只做高亮反馈 ----
            //   键值在 press_stb 那一拍就已经吃进去了（点按 = 一次输入），
            //   这里不重复输入 —— 键盘不是步进器，按住不放不该连击。
            else if (pnl_on && !busy_txn && kp_mode && held) begin
                kp_sel    <= kp_cur ? kp_ckey : KP_NO;
                pnl_press <= kp_cur ? P_KEY : P_NONE;
            end

            // ---- (5) 长按加速：到点就走一档 ----
            else if (pnl_on && !busy_txn && (rep_fire || first_fire)) begin
                if (pnl_fld) begin
                    // v44（㊶）：÷字段的长按加速与 ×字段共用同一套计时/进度环
                    pnl_didx <= (hold_wid == P_PLS) ? didx_up : didx_dn;
                end else if (hold_wid == P_PLS) begin
                    pnl_idx   <= idx_up;
                    pnl_inter <= preset_enc(idx_up);
                end else begin
                    pnl_idx   <= idx_dn;
                    pnl_inter <= preset_enc(idx_dn);
                end
                pnl_press <= hold_wid;
            end

            // ---- (6) 长按计时与进度（pnl_prog = 计时器高位，约 0.6 s 走到 57/63）----
            if (pnl_on && !busy_txn && hold_ok && !press_stb) begin
                if (!accel) begin
                    if (hold_cnt < HOLD_CYC) hold_cnt <= hold_cnt + 25'd1;
                    else                     accel    <= 1'b1;
                end else begin
                    if (rep_cnt < REP_CYC) rep_cnt <= rep_cnt + 25'd1;
                    else                   rep_cnt <= 25'd0;
                end
                pnl_prog <= accel ? 6'd63 : hold_cnt[24:19];
            end else begin
                hold_cnt <= 25'd0;
                rep_cnt  <= 25'd0;
                accel    <= 1'b0;
                pnl_prog <= 6'd0;
            end

            // ---- (7) 抬起：手势收尾（这一拍 held 已经是 0，上面的分支都不会动）----
            if (rel_stb) begin
                pnl_press <= P_NONE;
                hold_wid  <= P_NONE;
                hold_cnt  <= 25'd0;
                rep_cnt   <= 25'd0;
                accel     <= 1'b0;
                kp_sel    <= KP_NO;
                pnl_prog  <= 6'd0;
            end

            // ---- (8) 写事务收尾：ui_edit 从 BUSY 走到 OK / FAILED ----
            if (busy_txn) begin
                if (ui_state == ST_BUSY) begin
                    seen_busy <= 1'b1;
                end else if (seen_busy) begin
                    busy_txn  <= 1'b0;
                    seen_busy <= 1'b0;
                    pnl_on    <= 1'b0;         // 无论成败都收起：屏上只剩回读确认过的值
                    pnl_press <= P_NONE;
                    hold_wid  <= P_NONE;
                    if (ui_state == ST_OK) begin
                        pnl_undo_inter <= pre_enc;   // "上一次值" = 这笔事务写之前的真值
                        pnl_undo_div   <= pre_div;
                        pnl_undo_avail <= 1'b1;
                    end
                    // 失败时 ui_edit 已经用旧值回滚，面板不额外做什么：
                    // 卡片 2 显示的是回读真值，它自己会说明"没改成"。
                end
            end
        end
    end

endmodule
