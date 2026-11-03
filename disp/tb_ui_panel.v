//=============================================================================
//  disp/tb_ui_panel.v  --  倍频编辑面板（disp/ui_panel.v）的交互自检
//
//  这个台子测的是**手势语义**，不是像素：几何与绘制由 disp/tb_disp_engine.v
//  的第 [9] 段把关，写入链路（两阶段提交 + 回读 + 回滚）由 disp/tb_ui_edit.v
//  把关。这里只验三件事：
//    ① 六种手势各自的效果：[−]/[+] 点按、滑条吸附、拖拽、长按加速、
//       CANCEL 不写 / APPLY 写 / BACK 主动撤销；
//    ② 状态机的不变量：面板不跨页、不跨模态；没有改动时 APPLY 不写寄存器；
//       写成功才产生"上一次值"，且 BACK 之后新旧"上一次值"互换；
//    ③ 长按绝不会是唯一入口（点按在任何时候都能走一档）。
//    ④ v44（㊶）起面板有两个字段（×倍频 / ÷分频）：字段切换按钮、同一套控件
//       作用于活动字段、÷字段的键盘只收一位 1..8、APPLY 只改分频时倍频原样带出
//       （见第 10 节）。
//
//  ★ 小参数：HOLD_CYC/REP_CYC 换成 20 拍 / 10 拍，让"0.6 s 后每 0.2 s 一档"
//    在几十拍内发生（真实值是 30_000_000 / 10_000_000 @50 MHz）。
//  ★ 与 disp/tb_hit_test.v 分工：那边验"触摸生命周期事件对不对"
//    （held/rel_stb/cur_x），这边直接把这些事件喂给面板。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_ui_panel;

    reg clk = 1'b0;
    always #10 clk = ~clk;            // 50 MHz 系统时钟

    reg rst_n = 1'b0;

    // ---- 策略层输入（disp/enc_top_disp.v 提供）----
    reg        page     = 1'b1;       // page == 3'd0（P1）
    reg  [1:0] dlg      = 2'd0;
    reg        open_req = 1'b0;
    reg        press_stb = 1'b0;
    reg [11:0] press_x  = 12'd0, press_y = 12'd0;
    reg        held     = 1'b0;
    reg [11:0] cur_x    = 12'd0, cur_y = 12'd0;
    reg        rel_stb  = 1'b0;
    reg  [1:0] ui_state = 2'd0;       // ST_IDLE
    reg  [9:0] tap_inter = 10'd64;    // 回读确认值
    reg  [2:0] tap_div   = 3'd0;      // 分频寄存器值（= div-1）

    // ---- 被测件输出 ----
    wire        pnl_on;
    wire [2:0]  pnl_idx;
    wire [9:0]  pnl_inter;
    wire        pnl_fld;              // v44（㊶）：活动字段 0 = ×倍频、1 = ÷分频
    wire [2:0]  pnl_didx;             // v44（㊶）：待应用分频码 0..7（div = 码 + 1）
    wire [5:0]  pnl_prog;
    wire [3:0]  pnl_press;            // v44（㊶）：4 bit（多一个 P_FLD = 8）
    wire        pnl_pend;
    wire        pnl_undo_avail;
    wire [9:0]  pnl_undo_inter;
    wire [2:0]  pnl_undo_div;
    wire        req;
    wire [9:0]  req_inter;
    wire [2:0]  req_div_code;
    // v33（㉚）：数字键盘的输出（spec 6.3 的兜底入口）
    wire        kp_on;
    wire [3:0]  kp_d2, kp_d1, kp_d0;
    wire [1:0]  kp_dig;
    wire [3:0]  kp_sel;

    ui_panel #(
        .HOLD_CYC (25'd20),
        .REP_CYC  (25'd10)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .page           (page),
        .dlg            (dlg),
        .open_req       (open_req),
        .press_stb      (press_stb),
        .press_x        (press_x),
        .press_y        (press_y),
        .held           (held),
        .cur_x          (cur_x),
        .cur_y          (cur_y),
        .rel_stb        (rel_stb),
        .ui_state       (ui_state),
        .tap_inter      (tap_inter),
        .tap_div        (tap_div),
        .pnl_on         (pnl_on),
        .pnl_idx        (pnl_idx),
        .pnl_inter      (pnl_inter),
        .pnl_fld        (pnl_fld),
        .pnl_didx       (pnl_didx),
        .pnl_prog       (pnl_prog),
        .pnl_press      (pnl_press),
        .pnl_pend       (pnl_pend),
        .pnl_undo_avail (pnl_undo_avail),
        .pnl_undo_inter (pnl_undo_inter),
        .pnl_undo_div   (pnl_undo_div),
        .kp_on          (kp_on),
        .kp_d2          (kp_d2),
        .kp_d1          (kp_d1),
        .kp_d0          (kp_d0),
        .kp_dig         (kp_dig),
        .kp_sel         (kp_sel),
        .req            (req),
        .req_inter      (req_inter),
        .req_div_code   (req_div_code)
    );

    // ---- 断言状态 ----
    integer errors  = 0;
    integer req_cnt = 0;              // 写请求脉冲计数（验"不该写的时候一个都不发"）
    always @(posedge clk) if (req) req_cnt = req_cnt + 1;

    // ---- 控件中心坐标（与 disp/ui_panel.v 的参数同源）----
    localparam [11:0] MINUS_X = 12'd190, STEP_Y = 12'd496;   // [−]
    localparam [11:0] PLUS_X  = 12'd830;                     // [+]
    localparam [11:0] SLD_Y   = 12'd480;                     // 滑条
    localparam [11:0] CCL_X   = 12'd250, CMD_Y = 12'd552;    // CANCEL
    localparam [11:0] APL_X   = 12'd528;                     // APPLY
    localparam [11:0] BCK_X   = 12'd800;                     // BACK
    // v33（㉚）：数字键盘。入口按钮 64x64 @ (856..920, 392..456)；
    //   键位栅格 44x44、步距 52：键心 = (112 + 52*列 + 22, 328 + 52*行 + 22)。
    localparam [11:0] KPB_X   = 12'd888, KPB_Y = 12'd424;    // 「键盘」入口按钮中心
    // v44（㊶）：字段切换按钮中心（64x64 @ 240..304, 344..408 ⇒ 中心 272/376）
    localparam [11:0] FLD_X   = 12'd272, FLD_Y = 12'd376;
    localparam [11:0] KP_Y0   = 12'd350, KP_Y1 = 12'd402;    // 第 1/2 行键心
    localparam [11:0] KP_Y2   = 12'd454, KP_Y3 = 12'd506;    // 第 3/4 行键心
    localparam [11:0] KP_C0   = 12'd134, KP_C1 = 12'd186, KP_C2 = 12'd238;

    // =====================================================================
    // 通用任务
    // =====================================================================
    task chki;
        input [8*72-1:0] label;
        input integer    got, want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : got %0d want %0d", label, got, want);
            end else begin
                $display("[ OK ] %0s : %0d", label, got);
            end
        end
    endtask

    task chk_true;
        input [8*72-1:0] label;
        input            cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("[FAIL] %0s", label);
            end else begin
                $display("[ OK ] %0s", label);
            end
        end
    endtask

    task tick;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
            #1;
        end
    endtask

    // 开面板：点 P1 卡片 2 的单拍请求
    task open_panel;
        begin
            open_req = 1'b1; tick(1);
            open_req = 1'b0; tick(1);
        end
    endtask

    // 一次"按下"（按住不放，等调用者决定什么时候抬）
    task touch_down;
        input [11:0] x, y;
        begin
            press_x = x; press_y = y; cur_x = x; cur_y = y;
            press_stb = 1'b1; held = 1'b1;
            tick(1);
            press_stb = 1'b0;
        end
    endtask

    task touch_move;
        input [11:0] x, y;
        begin
            cur_x = x; cur_y = y;
            tick(1);
        end
    endtask

    task touch_up;
        begin
            held = 1'b0; rel_stb = 1'b1;
            tick(1);
            rel_stb = 1'b0;
            tick(1);
        end
    endtask

    // 点一下（按下 + 抬起）
    task tap_at;
        input [11:0] x, y;
        begin
            touch_down(x, y);
            touch_up;
        end
    endtask

    // 模拟 ui_edit 的一笔成功事务：进 BUSY（几百 µs）→ ST_OK（回读一致）
    task txn_ok;
        begin
            ui_state = 2'd1; tick(4);      // ST_BUSY
            ui_state = 2'd2; tick(4);      // ST_OK：回读确认
            ui_state = 2'd0; tick(2);      // 回 IDLE
        end
    endtask

    integer i;
    initial begin
        // -----------------------------------------------------------------
        // 第 0 节：复位态
        // -----------------------------------------------------------------
        tick(5);
        rst_n = 1'b1;
        tick(3);
        chki("复位后面板是关的",        pnl_on,    0);
        chki("复位后请求线是低的",      req,       0);
        chki("复位后撤销记忆不可用",    pnl_undo_avail, 0);

        // -----------------------------------------------------------------
        // 第 1 节：开面板 = 吸附到"不大于回读值的最大档"
        //   回读值 64 → 档 5（2/4/8/16/32/64）；此时"待应用"必须为 0
        // -----------------------------------------------------------------
        open_panel;
        chki("开面板：面板打开",        pnl_on,        1);
        chki("开面板：吸附到档 5（×64）", pnl_idx,      5);
        chki("开面板：待应用值 = 回读值", pnl_inter,    64);
        chki("开面板：没有待应用（不标黄）", pnl_pend,   0);
        chki("开面板：不写寄存器",      req_cnt,       0);

        // -----------------------------------------------------------------
        // 第 2 节：点按 [−] / [+]（点按永远是入口，长按只是加速）
        // -----------------------------------------------------------------
        tap_at(PLUS_X, STEP_Y);
        chki("[+] 点按走一档（×128）",  pnl_idx,      6);
        chki("[+] 点按后待应用值",      pnl_inter,    128);
        chki("[+] 点按后进入待应用态",  pnl_pend,     1);
        chki("[+/−] 点按不写寄存器",    req_cnt,      0);

        tap_at(MINUS_X, STEP_Y);
        chki("[−] 点按回一档（×64）",   pnl_idx,      5);
        chki("[−] 点按后待应用态消失",  pnl_pend,     0);

        // 边界：档 0 的 [−]、档 7 的 [+] 都不动（面板两端夹住，不绕回）
        tap_at(PLUS_X, STEP_Y);            // 6
        tap_at(PLUS_X, STEP_Y);            // 7（×256）
        chki("四次点按后到档 7",        pnl_idx,      7);
        tap_at(PLUS_X, STEP_Y);
        chki("档 7 再 [+] 不动（不绕回）", pnl_idx,    7);
        tap_at(MINUS_X, STEP_Y);           // 6
        tap_at(MINUS_X, STEP_Y);           // 5
        tap_at(MINUS_X, STEP_Y);           // 4
        tap_at(MINUS_X, STEP_Y);           // 3
        tap_at(MINUS_X, STEP_Y);           // 2
        tap_at(MINUS_X, STEP_Y);           // 1
        tap_at(MINUS_X, STEP_Y);           // 0
        chki("八次 [−] 后到档 0",       pnl_idx,      0);
        tap_at(MINUS_X, STEP_Y);
        chki("档 0 再 [−] 不动（不绕回）", pnl_idx,    0);
        chki("档 0 的待应用值 = ×2",    pnl_inter,    2);

        // -----------------------------------------------------------------
        // 第 3 节：滑条点按吸附 + 拖拽吸附（spec 6.3 的"离散滑条/档位吸附"）
        //   滑条 x 240..752，64 px 一档：700 → 档 7、300 → 档 0、430 → 档 2
        // -----------------------------------------------------------------
        touch_down(12'd700, SLD_Y);
        chki("滑条点按吸附到档 7",      pnl_idx,      7);
        chki("滑条点按后待应用值 ×256", pnl_inter,    0);      // 编码 0 = 256
        touch_move(12'd300, SLD_Y);
        chki("拖到最左 = 档 0",         pnl_idx,      0);
        touch_move(12'd430, SLD_Y);
        chki("拖到 x=430 = 档 2（×8）", pnl_idx,      2);
        chki("拖拽全程不写寄存器",      req_cnt,      0);
        touch_up;
        chki("抬起后按住的控件清空",    pnl_press,    0);

        // -----------------------------------------------------------------
        // 第 4 节：长按加速（进度 + 每 0.2 s 走一档）
        //   HOLD_CYC=20 / REP_CYC=10 是本台子的小参数
        // -----------------------------------------------------------------
        touch_down(PLUS_X, STEP_Y);
        chki("长按起手先走一档（点按即入口）", pnl_idx, 3);
        tick(25);                                   // 超过 HOLD_CYC
        chki("长按到点再走一档（档 4）", pnl_idx,      4);
        chk_true("长按进度给到满格（矩形环画满）", (pnl_prog == 6'd63));
        tick(12);                                   // 超过 REP_CYC
        chki("加速后每 0.2 s 一档（档 5）", pnl_idx,   5);
        touch_up;
        chki("抬起后进度归零",          pnl_prog,     0);
        chki("长按全程不写寄存器（只有 APPLY 写）", req_cnt, 0);

        // -----------------------------------------------------------------
        // 第 5 节：CANCEL = 一个字节都不发
        // -----------------------------------------------------------------
        tap_at(PLUS_X, STEP_Y);                     // 档 6：有了待应用值
        chki("CANCEL 前有待应用值",     pnl_pend,     1);
        tap_at(CCL_X, CMD_Y);
        chki("CANCEL 收起面板",         pnl_on,       0);
        chki("CANCEL 一个字节都没发",   req_cnt,      0);
        open_panel;                                 // 重新打开：吸附回回读值
        chki("重开后待应用值回到回读值", pnl_pend,    0);
        chki("重开后吸附到档 5",        pnl_idx,      5);

        // -----------------------------------------------------------------
        // 第 6 节：APPLY —— 两阶段提交（写之前记下"上一次值"）
        // -----------------------------------------------------------------
        tap_at(PLUS_X, STEP_Y);                     // 档 6 = ×128
        chki("APPLY 前待应用 ×128",     pnl_inter,    128);
        tap_at(APL_X, CMD_Y);
        chki("APPLY 发出一个写请求",    req_cnt,      1);
        chki("请求写的是待应用值",      req_inter,    128);
        chki("请求带的分频 = 回读值",   req_div_code, 0);
        chk_true("事务期间不收起面板",  (pnl_on == 1'b1));
        txn_ok;
        chki("事务成功后收起面板",      pnl_on,       0);
        chki("事务成功后记住上一次值",  pnl_undo_avail, 1);
        chki("上一次值 = 写之前的 ×64", pnl_undo_inter, 64);

        // -----------------------------------------------------------------
        // 第 7 节：BACK —— 主动「回到上一次值」（spec 6.5）
        //   先让回读值跟上（真实的 tap_inter 就是寄存器回读），再开面板按 BACK
        // -----------------------------------------------------------------
        tap_inter = 10'd128;                        // 回读确认：×128
        open_panel;
        chki("重开后吸附到档 6（×128）", pnl_idx,     6);
        chki("BACK 前没有待应用值",     pnl_pend,     0);
        tap_at(BCK_X, CMD_Y);
        chki("BACK 发出写请求",         req_cnt,      2);
        chki("BACK 写的是上一次值 ×64", req_inter,    64);
        txn_ok;
        chki("BACK 后收起面板",         pnl_on,       0);
        chki("BACK 后上一次值互换为 ×128", pnl_undo_inter, 128);
        chki("互换后撤销仍然可用",      pnl_undo_avail, 1);

        // 没有"上一次值"时按 BACK 不起作用（复位后第一次开面板的那种状态）
        //   这里用一次失败事务来构造：失败不回滚记忆，但应保持旧记忆
        tap_inter = 10'd64;
        open_panel;
        tap_at(APL_X, CMD_Y);                       // 没有改动：直接收起，不写
        chki("没有改动时 APPLY 不写寄存器", req_cnt,  2);
        chki("没有改动时 APPLY 直接收起",   pnl_on,   0);

        // -----------------------------------------------------------------
        // 第 8 节：面板不跨页、不跨模态
        // -----------------------------------------------------------------
        open_panel;
        chki("开面板成功",              pnl_on,       1);
        page = 1'b0;                                // 翻到别的页
        tick(2);
        chki("离开 P1 自动收起",        pnl_on,       0);
        page = 1'b1;
        open_panel;
        chki("回到 P1 重开成功",        pnl_on,       1);
        dlg = 2'd1;                                 // 二次确认模态弹出来
        tick(2);
        chki("模态弹出时自动收起",      pnl_on,       0);
        dlg = 2'd0;
        tick(2);

        // 按下不在任何控件上：什么都不该发生
        tap_at(12'd500, 12'd400);
        chki("空白处按下不写寄存器",    req_cnt,      2);

        // -----------------------------------------------------------------
        // 第 9 节：数字键盘兜底（spec 6.3）—— 入口 / 种子 / 输入 / 上限拒绝 /
        //          退格 / 首位 0 / 「退一层」/ 按住高亮
        //   键盘是"连续滑条在 256 档上不可用"的兜底入口：键盘模式下 [−]/[+] 与
        //   滑条都失效，值只能一个字一个字敲；APPLY 的写入路径与步进器**同一个**
        //   （所以两阶段提交的字面纪律没变，见第 6 节）。
        // -----------------------------------------------------------------
        tap_inter = 10'd64;
        open_panel;
        chki("键盘入口前：键盘是关的",   kp_on,        0);
        tap_at(KPB_X, KPB_Y);
        chki("点入口按钮进键盘模式",     kp_on,        1);
        chki("键盘种子：位数 = 2",        kp_dig,      2);
        chki("键盘种子：百位 = 0",        kp_d2,       0);
        chki("键盘种子：十位 = 6",        kp_d1,       6);
        chki("键盘种子：个位 = 4",        kp_d0,       4);
        chki("进键盘不写寄存器",          req_cnt,     2);
        tap_at(PLUS_X, STEP_Y);
        chki("键盘模式下 [+] 不动档位",   pnl_idx,     5);
        //   两次退格把种子清空（dig = 0）
        tap_at(KP_C0, KP_Y3);                       // ←
        tap_at(KP_C0, KP_Y3);                       // ←
        chki("两次退格后位数为 0",        kp_dig,      0);
        //   首位 0 不接受（否则"05"这种输入会污染值）
        tap_at(KP_C1, KP_Y3);                       // 0
        chki("首位 0 不接受（位数仍 0）", kp_dig,      0);
        //   注意：两次退格已经把"待应用值"写成了 0（退格是改值的动作），所以这里
        //   要看的是"被拒绝的 0 键没有把值再改一遍"，而不是"有没有待应用"。
        chki("首位 0 不接受（待应用值仍 0）", pnl_inter, 0);
        //   输入 256（寄存器合同上限）⇒ 编码 0
        tap_at(KP_C1, KP_Y0);                       // 2
        tap_at(KP_C1, KP_Y1);                       // 5
        tap_at(KP_C2, KP_Y1);                       // 6
        chki("输入 256：位数 3",          kp_dig,      3);
        chki("输入 256：待应用值编码 0",  pnl_inter,   0);
        chki("输入 256：进入待应用态",    pnl_pend,    1);
        //   再敲一位 ⇒ 2566 > 256：拒绝该键（不悄悄截成 256）
        tap_at(KP_C2, KP_Y1);                       // 6
        chki("超过 256 不接受该键（位数仍 3）", kp_dig, 3);
        chki("超过 256 不接受该键（值不变）", pnl_inter, 0);
        tap_at(APL_X, CMD_Y);
        chki("APPLY 写出输入值",          req_cnt,     3);
        chki("APPLY 写的是 256（编码 0）", req_inter,   0);
        txn_ok;
        chki("事务成功后收起面板",        pnl_on,      0);
        //   重开：回读 256（编码 0）⇒ 种子三位 (2,5,6)
        tap_inter = 10'd0;
        open_panel;
        chki("重开后吸附到档 7",          pnl_idx,     7);
        tap_at(KPB_X, KPB_Y);
        chki("种子 = 回读 256：位数 3",   kp_dig,      3);
        chki("种子 = 回读 256：百位 2",   kp_d2,       2);
        chki("种子 = 回读 256：十位 5",   kp_d1,       5);
        //   CANCEL「退一层」：键盘里先只退键盘，再按一次才收面板
        tap_at(CCL_X, CMD_Y);
        chki("键盘里 CANCEL 只退一层（面板还在）", pnl_on, 1);
        chki("键盘里 CANCEL 退掉键盘",    kp_on,       0);
        tap_at(CCL_X, CMD_Y);
        chki("再 CANCEL 才收面板",        pnl_on,       0);
        //   键盘模式下入口按钮不再响应（免得把自己关掉）
        open_panel;
        tap_at(KPB_X, KPB_Y);
        chki("再次进键盘",                kp_on,       1);
        tap_at(KPB_X, KPB_Y);
        chki("键盘模式下再点入口不变",    kp_on,       1);
        //   按住键只做高亮（点按一次输入一位，按住不连击）
        touch_down(KP_C1, KP_Y1);                   // 按住 5
        chki("按住键 5：高亮跟着走",      kp_sel,      5);
        touch_up;
        chki("抬起后高亮清空",            kp_sel,     15);
        chki("键盘全程一个字节都没写",    req_cnt,     3);
        page = 1'b0;                                // 跨页必须把键盘一起收掉
        tick(2);
        chki("离开 P1 自动收起键盘",      kp_on,       0);
        page = 1'b1;
        open_panel;
        chki("键盘下回读值没被改坏",      pnl_inter,   0);

        // -----------------------------------------------------------------
        // 第 10 节：v44（㊶）÷分频八档步进 —— 字段切换 / 步进边界 / 滑条 /
        //           长按加速 / 数字键盘（只收 1..8）/ APPLY 带出分频码 /
        //           BACK 把倍频与分频一起带回
        //   ★ 编码口径：`pnl_didx` **就是寄存器值**（div = 码 + 1）⇒ ÷1 = 码 0。
        //   ★ 打开面板时 `pnl_inter` = 回读**真值**（不再吸附成档位）：写命令
        //     `pack_cmd` 同时写 0x0101/0x0102，只改分频时不许把回读的 100 顺手
        //     改成 64（下面专门有一条判据钉住这件事）。
        // -----------------------------------------------------------------
        tap_at(CCL_X, CMD_Y);                       // 先收掉面板（键盘已关 ⇒ 一层）
        chki("第 10 节：先收起面板",     pnl_on,       0);
        tap_inter = 10'd100;                        // 回读值故意不是档位（×64 与 ×128 之间）
        tap_div   = 3'd2;                           // 回读分频码 2 = ÷3
        open_panel;
        chki("÷字段：默认活动字段 = ×倍频", pnl_fld,   0);
        chki("÷字段：待应用倍频 = 回读真值 100", pnl_inter, 100);
        chki("÷字段：待应用分频码 = 回读 2", pnl_didx, 2);
        chki("÷字段：刚打开没有待应用",  pnl_pend,    0);
        chki("÷字段：滑条游标吸附到档 5（×64）", pnl_idx, 5);

        // 切换字段本身不是"改动"
        tap_at(FLD_X, FLD_Y);
        chki("切到 ÷ 字段",              pnl_fld,     1);
        chki("切字段不改倍频",           pnl_inter,   100);
        chki("切字段不改分频",           pnl_didx,    2);
        chki("切字段不产生待应用",       pnl_pend,    0);
        chki("切字段不写寄存器",         req_cnt,     3);

        // [−]/[+] 步进：÷3 → ÷2 → ÷1，两端夹住不绕回
        tap_at(MINUS_X, STEP_Y);
        chki("[−] 走一档：码 1（÷2）",   pnl_didx,    1);
        chki("[−] 走一档后进入待应用态", pnl_pend,    1);
        tap_at(MINUS_X, STEP_Y);
        chki("[−] 再走一档：码 0（÷1）", pnl_didx,    0);
        tap_at(MINUS_X, STEP_Y);
        chki("÷1 再 [−] 不动（不绕回）", pnl_didx,    0);
        for (i = 0; i < 10; i = i + 1) tap_at(PLUS_X, STEP_Y);
        chki("十次 [+] 后停在 ÷8（码 7）", pnl_didx,  7);
        tap_at(PLUS_X, STEP_Y);
        chki("÷8 再 [+] 不动（不绕回）", pnl_didx,    7);
        chki("÷字段步进全程不动倍频",    pnl_inter,   100);
        chki("÷字段步进不写寄存器",      req_cnt,     3);

        // 滑条：第 k 格 = 分频码 k（几何与 ×倍频 共用，一字未改）
        touch_down(12'd700, SLD_Y);
        chki("滑条点按：码 7（÷8）",     pnl_didx,    7);
        touch_move(12'd300, SLD_Y);
        chki("拖到最左：码 0（÷1）",     pnl_didx,    0);
        touch_move(12'd430, SLD_Y);
        chki("拖到 x=430：码 2（÷3）",   pnl_didx,    2);
        touch_up;
        chki("拖拽全程不写寄存器",       req_cnt,     3);

        // 长按加速：÷字段一样 0.6 s 后每 0.2 s 一档
        touch_down(PLUS_X, STEP_Y);
        chki("÷字段长按起手先走一档（码 3）", pnl_didx, 3);
        tick(25);
        chki("÷字段长按到点再走一档（码 4）", pnl_didx, 4);
        tick(12);
        chki("÷字段加速后每 0.2 s 一档（码 5）", pnl_didx, 5);
        touch_up;
        chki("÷字段长按全程不写寄存器",  req_cnt,     3);

        // 数字键盘：÷字段只收一位 1..8（0/9 不接受该键），← 只做高亮
        tap_at(KPB_X, KPB_Y);
        chki("÷字段进键盘",              kp_on,       1);
        chki("÷字段键盘种子：位数 = 1",  kp_dig,      1);
        chki("÷字段键盘种子 = 码 + 1 = 6", kp_d0,     6);
        tap_at(KP_C1, KP_Y3);                       // 0：不接受
        chki("÷字段不接受 0（位数仍 1）", kp_dig,     1);
        chki("÷字段不接受 0（码不变）",  pnl_didx,    5);
        tap_at(KP_C2, KP_Y2);                       // 9：不接受
        chki("÷字段不接受 9（位数仍 1）", kp_dig,     1);
        chki("÷字段不接受 9（码不变）",  pnl_didx,    5);
        tap_at(KP_C0, KP_Y3);                       // ←：只有高亮反馈
        chki("÷字段的 ← 只做高亮（码不变）", pnl_didx, 5);
        tap_at(KP_C0, KP_Y1);                       // 4 ⇒ ÷4（码 3）
        chki("÷字段敲 4 ⇒ 码 3（÷4）",   pnl_didx,    3);
        chki("÷字段敲键不改倍频",        pnl_inter,   100);
        tap_at(KP_C2, KP_Y3);                       // ↵ 收键盘（值留在待应用）
        chki("÷字段 ↵ 收键盘",           kp_on,       0);
        chki("÷字段收键盘后仍有待应用",  pnl_pend,    1);

        // APPLY：只改分频时，倍频必须原样带出（这是"不吸附"设计的核心判据）
        tap_at(APL_X, CMD_Y);
        chki("÷字段 APPLY 发出写请求",   req_cnt,     4);
        chki("÷字段 APPLY 带出码 3（÷4）", req_div_code, 3);
        chki("÷字段 APPLY 倍频原样带出 100", req_inter, 100);
        txn_ok;
        chki("÷字段 APPLY 后收起面板",   pnl_on,      0);
        chki("÷字段 APPLY 后记住上一次值", pnl_undo_avail, 1);
        chki("上一次值的倍频 = 写之前 100", pnl_undo_inter, 100);
        chki("上一次值的分频 = 写之前码 2", pnl_undo_div, 2);

        // BACK：倍频与分频**一起**回到上一次值
        tap_div   = 3'd3;                           // 回读确认：寄存器现在 ÷4
        tap_inter = 10'd100;
        open_panel;
        chki("BACK 前：待应用分频码 = 回读 3", pnl_didx, 3);
        chki("BACK 前没有待应用",        pnl_pend,    0);
        tap_at(BCK_X, CMD_Y);
        chki("BACK 发出写请求",          req_cnt,     5);
        chki("BACK 写回上一次值的倍频",  req_inter,   100);
        chki("BACK 写回上一次值的分频",  req_div_code, 2);
        txn_ok;
        chki("BACK 后收起面板",          pnl_on,      0);
        chki("BACK 后新旧上一次值互换（分频）", pnl_undo_div, 3);
        chki("BACK 后撤销仍可用",        pnl_undo_avail, 1);
        chki("÷字段整节结束：一个字节都没多发", req_cnt, 5);

        // -----------------------------------------------------------------
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #200_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule

`default_nettype wire
