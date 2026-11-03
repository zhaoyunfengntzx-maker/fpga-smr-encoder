// -----------------------------------------------------------------------------
//  disp/tb_disp_v58.v —— v58 页集契约测试（新增，取代 8 页版回归）
//
//  为什么重写而不是改旧台：旧 tb_disp_engine.v 有 3316 行、逐页断言
//  P1..P8 的像素（P5 表格、P8 诊断字段、P3、P2 双 Tab…）。v58 删掉
//  P3/P5/P8 三页后，那些断言描述的东西已经不存在 —— 继续把它们留在 CI 里
//  只会把"删页"误报成"回归失败"。旧台归档为
//  disp/legacy_v57_tb_disp_engine.v（不再被 tools/run_sim_disp.ps1 的 tb_* 通配到）。
//
//  本台只盯 v58 新形态下"错了就上板花屏/白屏"的五件事：
//    [1] 导航 4 项（每项 144 px）：页 0/1/3/5 上对应档位底色 = C_SEC，其余 = C_NAV。
//    [2] 已删的页（2/4/7）上不得出现卡片白底 —— 防"删页只删入口、残留从别页漏过来"。
//    [3] 卡片 6 的六通道电平条（c6_draw）只在 P1 上为真 —— 这就是用户报的"右下角蓝线"。
//    [4] P1 左侧导航「设置」有墨。
//    [5] 每个存活页的标题带都有表头文字（字模接错会让整页变空）。
//
//  不再检查：具体字形好不好看（需人眼，且字模会随设计变）、
//  P2/P4 曲线形状（它们由采样模块决定，已有各自的单元台）。
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
//  sim/tb_disp_engine.v —— 显示引擎骨架的仿真检查（v13 新增）
//
//  这一版**不检查"界面好不好看"**（骨架版的字形是程序化方框字，本来就不好看），
//  只检查四件"错了就一定上板黑屏/花屏"的事：
//
//    [1] lcd_de 每行恰好 1024 拍有效、每帧恰好 600 行 —— 时序参数没写错。
//    [2] 帧周期 = 635 × 1344 = 853,440 拍 —— 场频 58.6 Hz（不是别的数）。
//    [3] 消隐期（de=0）lcd_rgb 必须恒为 0 —— 消隐期出彩色会在屏上留下
//        "边缘拖尾/回扫亮线"，是最难查的一类毛病。
//    [4] 抽头真的进了渲染器：tap_angle 一翻转，状态条右端的"活性块"颜色就跟着变。
//        这是 disp_engine 里那段"活性证明"逻辑的单元级证据；上板时它表现为
//        "状态条右端在闪"，抽头断线则不闪。
//
//  ---------------------------------------------------------------------------
//  ★ 为什么抽头用**内置激励**而不是例化真的 enc_top：
//    本测试台的目的是验证**屏侧渲染管线**，不是编码器。把 enc_top 拉进来会让
//    一次仿真的成本上升几个数量级（CORDIC 18 拍流水、除法器、5 级环路滤波），
//    而它对"时序发生器 + 渲染器"的正确性没有任何额外证明力。
//    enc_top 自己的回归由 sim/tb_enc_top.v 全套负责，见 docs/DEV_STATUS.md §2。
//    唯一需要在合并层验证的"接线是否正确"由 synthesis 的 drc/逻辑优化报告兜底
//    （未连接/常量化的探针会在 place 阶段暴露成 UCIO 或优化日志）。
//
//  ---------------------------------------------------------------------------
//  ★ 还有一个**故意不检查**的东西：具体像素颜色。字形是占位方框，颜色会随版式
//    改动而变；把它写进断言只会让测试变成"一改版就红"的噪声源。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_disp_v58;

    localparam integer H_SYNC  = 20;
    localparam integer H_BACK  = 140;
    localparam integer H_DISP  = 1024;
    localparam integer H_FRONT = 160;
    localparam integer V_SYNC  = 3;
    localparam integer V_BACK  = 20;
    localparam integer V_DISP  = 600;
    localparam integer V_FRONT = 12;

    localparam integer H_TOTAL = H_SYNC + H_BACK + H_DISP + H_FRONT;   // 1344
    localparam integer V_TOTAL = V_SYNC + V_BACK + V_DISP + V_FRONT;   // 635
    localparam integer FRAME   = H_TOTAL * V_TOTAL;                    // 853440

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;      // 50 MHz

    // ---- 时序发生器 ----
    wire [11:0] pix_x, pix_y;
    wire        de, hs, vs, frame_st, line_st;

    lcd_timing_gen u_tg (
        .clk_pix  (clk),
        .rst_n    (rst_n),
        .pixel_en (1'b1),
        .h_sync   (H_SYNC[11:0]),
        .h_back   (H_BACK[11:0]),
        .h_disp   (H_DISP[11:0]),
        .h_front  (H_FRONT[11:0]),
        .v_sync   (V_SYNC[11:0]),
        .v_back   (V_BACK[11:0]),
        .v_disp   (V_DISP[11:0]),
        .v_front  (V_FRONT[11:0]),
        .lcd_hs   (hs),
        .lcd_vs   (vs),
        .lcd_de   (de),
        .pix_x    (pix_x),
        .pix_y    (pix_y),
        .frame_st (frame_st),
        .line_st  (line_st)
    );

    // ---- 编码器抽头：内置"像编码器"的激励 ----
    reg [15:0] t_angle    = 16'h0000;
    reg [31:0] t_pos_full = 32'h0000_0000;
    reg [15:0] t_sin      = 16'h0000;
    reg [15:0] t_cos      = 16'h4000;   // Q1.15，0.5 满幅
    reg [7:0]  t_iostate  = 8'h09;      // dir=0, a=1, z=0, u=1, v=0, w=0
    // ---- [6] 导航高亮跟随页号的测试驱动（2026-10-15 补）----
    //   为什么要驱动页号：nav_sel 曾写死成"第 0 项"，翻到 P6/P8 时左侧仍高亮"总览"。
    //   这不是几何错误，原测试台跑满帧也不会报。要抓到它，必须把页号推进一遍、
    //   每页稳定跑满一整帧，再回读导航列的底色。
    reg [2:0]  t_page = 3'd0;

    // 每帧推进 1/8 圈（8192 LSB），并让 sin 跟随 phase 的象限走三角波近似。
    // 目的只是"看起来像编码器数据在动"，不是模拟真实正余弦精度。
    integer frame_n = 0;
    //   ★ 第 [4] 项（抽头活性）需要在两次采样之间让 tap_* 静止。
    //   这个生成器每帧都推进 t_angle，会和那个检查里的显式赋值抢同一个 reg
    //   （非阻塞 vs 阻塞，谁赢取决于帧相位）—— 于是那条判据一度只是"碰巧"通过。
    //   tap_freeze 让检查期间完全不推进，判据才确定。
    reg tap_freeze = 1'b0;
    always @(posedge clk) begin
        if (frame_st && !tap_freeze) begin
            frame_n   <= frame_n + 1;
            t_angle   <= t_angle + 16'd8192;
            t_pos_full<= t_pos_full + 32'd8192;
            // 三角波：取 angle 的高位做分段，幅值 ±0.5 FS
            t_sin     <= {~t_angle[15], t_angle[14:0]};   // 粗糙但单调可动
            t_cos     <= { t_angle[15], ~t_angle[14:0]};
            t_iostate <= {t_iostate[6:0], t_iostate[7] ^ t_iostate[5]};
        end
    end

    // ---- 显示引擎 ----
    wire [23:0] lcd_rgb;
    wire        de_o;                    // disp_engine 输出的、与 lcd_rgb 同拍对齐的 de
    wire [11:0] dbg_x, dbg_y;
    reg  [1:0]  dlg_tb = 2'd0;           // v19：模态对话框状态（0=不显示 1=询问 2=写入中）
    // v34（㊲）：危险区按钮的按住电平（绘制层据此画内嵌框；[9] 段两态复检用）
    reg         dz_prs_tb = 1'b0;
    // v42（㊴）：第二颗按钮的按住电平 / 对话框种类（0 = 清除锁存故障、1 = 恢复默认）
    //            / 恢复序列结果（0 = 空闲、1 = 全一致、2 = 有不一致）/ 15 位失败标志
    reg         dz_prs2_tb  = 1'b0;
    reg         dlg_kind_tb = 1'b0;
    reg  [1:0]  rst_state_tb = 2'd0;
    reg  [14:0] rst_bad_tb   = 15'd0;
    // v22：编辑面板（[9] 段逐项拉起来做像素级复检）
    reg         pnl_on_tb   = 1'b0;
    reg  [9:0]  pnl_inter_tb = 10'd64;
    reg         pnl_fld_tb   = 1'b0;      // v44（㊶）：活动字段 0 = ×倍频、1 = ÷分频
    reg  [2:0]  pnl_didx_tb  = 3'd0;      // v44（㊶）：待应用分频码 0..7（div = 码 + 1）
    reg  [5:0]  pnl_prog_tb = 6'd0;
    reg  [3:0]  pnl_press_tb = 4'd0;      // v44（㊶）：4 bit（多一个 P_FLD = 8）
    reg         pnl_pend_tb = 1'b0;
    reg  [2:0]  pnl_idx_tb  = 3'd3;      // 档 3 = ×16
    reg         pnl_undo_tb = 1'b0;
    reg  [9:0]  pnl_undo_inter_tb = 10'd64;   // v24：「上一次值」的倍频码（0 = 256）
    reg  [2:0]  pnl_undo_div_tb   = 3'd0;     // v44（㊶）：「上一次值」的分频码（0 = ÷1）
    // v30：[11] 段驱动的遥测与使能（必须在例化前面声明，理由见 [11] 的注释）
    reg  [7:0]  t_io_flags = 8'h00;  // telemetry {amp_bad,cor_sat,uwven,abzen,uvw_warn,z_win,lag_fat,lag_warn}
    reg  [7:0]  t_stat     = 8'h00;  // 状态字 {res,adapt,scamp,lagfatl,inclim,laglim,falarm,oflow}
    reg         t_abzen    = 1'b1;
    reg         t_uwven    = 1'b0;
    // v45（㊷）空态：抽头 [126]（原链路帧 CRC 错，sticky）。v74 起该源恒 0。
    //   默认 0 = "链路正常"，各段按需拉起来验空态；段末一律复原 0。
    reg         t_crc      = 1'b0;
    // v54（C3）：抽头 [375]（原链路静默，非粘滞）。v74 起该源恒 0。
    //   与 t_crc 的区别：crc_err_seen 是粘滞的（错一次就不退），link_lost 是**非粘滞**的
    //   （主机一恢复边沿，2 ms 内自己落回 0 —— 门限 100,000 拍 × 20 ns）—— 所以段落里必须验"能落回"。
    //   默认 0 = 链路有活动；[21] 段单独拉起来验空态与落回。
    reg         t_link_lost = 1'b0;
    // v46（㊸）空态的另一半：**无载波**判据要看幅值**值**（`tap_amp_sq < tap_amp_low_sq`），
    //   所以这里必须能在段落里改它 —— 原来是例化处的常量 32'h2000_0000（= 0.5 Q2.30）。
    //   默认值就是那个常量：比下限门限 32'h170A_3D71（0.6² = 0.36 Q2.30）大 ⇒ 载波在。
    reg  [31:0] t_amp_sq   = 32'h2000_0000;
    // v32（㉙）：闪烁使能。**默认 0** —— [11] 段的 ㉗/㉘ 判据要求反色块全程可见，
    //   开着闪烁会让那些像素断言随相位飘。[12] 段再单独把它打开测闪烁本身。
    reg         t_blink    = 1'b0;
    // v36（㉜）：触摸诊断位域（P8「自检结果」的三个 IIC 计数就从这里来）。
    //   **默认全 0** —— 0 表示"读次数 0（IIC 停摆）"，即 P8 结论默认是「失败」，
    //   与静态版面的占位一致；[14] 段再单独驱动它测结论的四种组合。
    //   ★ 同样必须在例化之前声明（同一坑：VRFC 10-2938）。
    reg  [159:0] t_diag   = 160'h0;
    // v33（㉚）：数字键盘的绘制输入。**默认全 0** —— [11]/[12] 段的判据都基于
    //   "面板上没有键盘"这一画面；[13] 段再单独把键盘打开测键盘本身。
    //   ★ 必须在这里（例化之前）声明，否则 xvlog 报
    //     `VRFC 10-2938 't_kp_on' is already implicitly declared`。
    reg         t_kp_on    = 1'b0;
    reg  [3:0]  t_kp_d2    = 4'd0;
    reg  [3:0]  t_kp_d1    = 4'd0;
    reg  [3:0]  t_kp_d0    = 4'd0;
    reg  [1:0]  t_kp_dig   = 2'd0;
    reg  [3:0]  t_kp_sel   = 4'hF;

    disp_engine u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .page           (t_page),        // [6] 逐页推进，验导航高亮跟随页号
        // ★ v89：这两个输入从来没接过（v60 的 demo_on、v87 的 p2_mode），
        //   悬空 = 1'bz，X 会从 P2 档位/P6 演示通路渗进像素层。显式钉死。
        .p2_mode        (2'd0),          // 0 = AUTO（P2 时基自动档）
        .demo_on        (1'b0),          // P6 演示开关关
        .pix_x          (pix_x),
        .pix_y          (pix_y),
        .de             (de),
        .tap_angle      (t_angle),
        .tap_s_n        (t_sin),
        .tap_c_n        (t_cos),
        .tap_pos_full   (t_pos_full),
        .tap_io_state   (t_iostate),
        .tap_io_flags   (t_io_flags),
        .tap_stat       (t_stat),
        .tap_cfg_inter  (10'd256),
        .tap_cfg_div    (3'd1),
        .tap_cfg_pairs  (5'd4),
        // v14：P6 回读字段。本测试台只验版面与导航高亮，给一组固定值即可；
        // 若留空（z）会在 P6 页把 X 写进 p6_val_ram，污染后续像素判据。
        .tap_cfg_hyst_ab(5'd2),
        .tap_cfg_ablimit(8'd255),
        .tap_cfg_zwidth (4'd5),
        .tap_cfg_zphase (12'd0),
        .tap_cfg_uvwph  (16'd0),
        .tap_cfg_pol    (4'b0000),
        // P7 的七个抽头（v15）。本测试台巡的是六页的导航高亮，P7 也在巡的页里
        // （它不高亮任何导航项）—— 曲线与参数值给固定值即可。
        .tap_ofs_s      (16'sd0),
        .tap_ofs_c      (16'sd0),
        .tap_gain_s     (16'd32768),
        .tap_gain_c     (16'd32768),
        .tap_phase_k    (16'sd0),
        .tap_shift      (4'd0),
        .tap_amp_sq     (t_amp_sq),
        // v21：P7 幅值百分比的两个门限（真实寄存器默认值）。
        //   ★ 这两个端口是 v21 新加的：漏接的话 P7 通路会拿到 z，百分比整片变 X
        //     （与 U-17 记录 28 那次"漏接一个输入整页变 X"同一类）。
        .tap_amp_low_sq (32'h170A_3D71),
        .tap_amp_high_sq(32'h5C28_F5C3),
        .tap_abzen      (t_abzen),
        .tap_uwven      (t_uwven),
        // ★ v89：tap_calib_busy / tap_calib_done 两个输入随 P1「标定」按钮一起删了
        //   （标定中 / 标定通过回显没了），这里不再需要钉 0。
        .tap_link_crc_err(t_crc),  // v45（㊷）：原链路 CRC 判据源（v74 起恒 0）
        .tap_link_lost(t_link_lost),  // v54（C3）：原链路静默判据源（v74 起恒 0）
        .tch_diag       (t_diag),  // 触摸诊断：P8 结论的 [14] 段要驱动它（其余段恒 0）
        .ui_state       (2'd0),    // 改值事务：空闲（③ 的反馈层已接，这里只验证不破坏底色）
        .ui_err         (4'd0),
        .ui_dlg         (dlg_tb),  // v19 模态：本测试台在 [7] 段里把它拉起来做像素级复检
        // v34（㊲）：按住电平。本台用它做"同一点两态"复检（按住 = 内嵌框，不按 = 脸）
        .ui_dz_press    (dz_prs_tb),
        // v42（㊴）：第二颗按钮 / 对话框种类 / 恢复结果。本台在新增的第 ⑦ 段里
        // 逐项拉起来做像素级复检（第 2 颗的内嵌框、✖、描边绿/红、两套对话框文字）。
        .ui_dz_press2   (dz_prs2_tb),
        .ui_dlg_kind    (dlg_kind_tb),
        .ui_rst_state   (rst_state_tb),
        .ui_rst_bad     (rst_bad_tb),
        .ui_blink_en    (t_blink), // v32（㉙）闪烁使能：[11] 恒 0，[12] 单独拉高
        // v22 编辑面板：本测试台在 [9] 段里逐项拉起来做像素级复检
        .pnl_on         (pnl_on_tb),
        .pnl_inter      (pnl_inter_tb),
        .pnl_fld        (pnl_fld_tb),
        .pnl_didx       (pnl_didx_tb),
        .pnl_prog       (pnl_prog_tb),
        .pnl_press      (pnl_press_tb),
        .pnl_pend       (pnl_pend_tb),
        .pnl_idx        (pnl_idx_tb),
        .pnl_undo_avail (pnl_undo_tb),
        .pnl_undo_inter (pnl_undo_inter_tb),
        .pnl_undo_div   (pnl_undo_div_tb),
        // v33（㉚）数字键盘：[11]/[12] 段恒关（画面 = 面板原样），[13] 段单独开
        .pnl_kp_on      (t_kp_on),
        .pnl_kp_d2      (t_kp_d2),
        .pnl_kp_d1      (t_kp_d1),
        .pnl_kp_d0      (t_kp_d0),
        .pnl_kp_dig     (t_kp_dig),
        .pnl_kp_sel     (t_kp_sel),
        .lcd_rgb        (lcd_rgb),
        .de_o           (de_o),
        .dbg_x          (dbg_x),
        .dbg_y          (dbg_y)
    );
    // =====================================================================
    // =====================================================================
    //  v58 契约测试体（v2：全部内联在 initial 里，不用嵌套 task/数组）
    //    验收点：
    //      [1] 四个导航档位：选中档 = C_SEC，其余 = C_NAV
    //      [2] 删掉的页（2/4/7）内容区不许出现卡片白底
    //      [3] 非 P1 页 c6_draw 必须恒 0（R8 蓝线回归）
    //      [4] P1 导航「设置」格（行 34 / 列 1）必须有墨（R9 回归）
    //      [5] 每个存活页的标题带墨量 > 0（字模与页面接通）
    // =====================================================================
    localparam [23:0] L_SEC  = 24'h8FC4EC;
    localparam [23:0] L_NAV  = 24'hDCE9F5;
    localparam [23:0] L_CARD = 24'hFFFFFF;
    localparam [23:0] L_TEXT = 24'h1F2D3D;

    reg [23:0] nb0, nb1, nb2, nb3;
    integer set_ink, c6_bleed, card_leak, tink, errs, pgx, k;
    integer navw_ink;
    reg [23:0] L_ACC = 24'h2E7DD1;
    reg [23:0] e0, e1, e2, e3;

    // 每像素采样：四档底色 + c6 泄漏 + 设置导航墨 + 已删页卡片白底 + 标题带墨
    always @(posedge clk) if (de_o) begin
        if (dbg_x == 12'd8) begin
            if (dbg_y == 12'd100) nb0 <= lcd_rgb;
            if (dbg_y == 12'd200) nb1 <= lcd_rgb;
            if (dbg_y == 12'd350) nb2 <= lcd_rgb;
            if (dbg_y == 12'd520) nb3 <= lcd_rgb;
        end
        // v60（T1）：卡 6 的电平条已整块删除，改成"右下角不许出现 C_ACC 横线"。
        if ((dbg_y >= 12'd500) && (dbg_y <= 12'd560) &&
            (dbg_x >= 12'd700) && (dbg_x <= 12'd1023) && (lcd_rgb == L_ACC))
            c6_bleed <= c6_bleed + 1;
        if ((t_page == 3'd0) && (dbg_y >= 12'd512) && (dbg_y <= 12'd527) &&
            (dbg_x >= 12'd16) && (dbg_x <= 12'd31) && (lcd_rgb == L_TEXT))
            set_ink <= set_ink + 1;
        if ((t_page == 3'd5) && (dbg_y >= 12'd224) && (dbg_y <= 12'd239) &&
            (dbg_x >= 12'd16) && (dbg_x <= 12'd31) && (lcd_rgb == L_TEXT))
            navw_ink <= navw_ink + 1;
        if (((t_page == 3'd2) || (t_page == 3'd4) || (t_page == 3'd7)) &&
            (dbg_x >= 12'd96) && (dbg_y >= 12'd64) && (lcd_rgb == L_CARD))
            card_leak <= card_leak + 1;
        // 标题带 = 顶部蓝色状态栏（y<24），页标题用白字压在蓝底上
        if ((dbg_y >= 12'd3) && (dbg_y <= 12'd20) &&
            (dbg_x >= 12'd40) && (dbg_x <= 12'd600) &&
            (lcd_rgb != 24'h2E7DD1) && (lcd_rgb != 24'hEAF3FB))
            tink <= tink + 1;
    end

    initial begin
        errs = 0;
        set_ink = 0; c6_bleed = 0; card_leak = 0; tink = 0; navw_ink = 0;
        #200 rst_n = 1'b1;
        repeat (3) @(posedge frame_st);

        $display("================================================================");
        $display(" tb_disp_v58 : 5-page contract checks");
        $display("================================================================");

        for (pgx = 0; pgx < 8; pgx = pgx + 1) begin
            t_page = pgx[2:0];
            tink = 0; set_ink = 0; c6_bleed = 0; card_leak = 0; navw_ink = 0;
            repeat (2) @(posedge frame_st);

            // 哪一档导航亮：0->0, 1->1, 3->2, 5->3，其余不亮
            e0 = L_NAV; e1 = L_NAV; e2 = L_NAV; e3 = L_NAV;
            if (pgx == 0) e0 = L_SEC;
            if (pgx == 1) e1 = L_SEC;
            if (pgx == 3) e2 = L_SEC;
            if (pgx == 5) e3 = L_SEC;

            if ((nb0 !== e0) || (nb1 !== e1) || (nb2 !== e2) || (nb3 !== e3)) begin
                $display("[FAIL] P%0d nav bands = %h/%h/%h/%h expect %h/%h/%h/%h",
                         pgx, nb0, nb1, nb2, nb3, e0, e1, e2, e3);
                errs = errs + 1;
            end else begin
                $display("[ OK ] P%0d nav bands ok", pgx);
            end

            if (c6_bleed !== 0) begin
                $display("[FAIL] P%0d stray C_ACC line bottom-right: %0d px (R8/T1)", pgx, c6_bleed);
                errs = errs + 1;
            end

            // v60（T2）：设置页导航第二项「波形」（格行 14、格列 1）必须有墨
            if ((pgx == 5) && (navw_ink < 40)) begin
                $display("[FAIL] P5 nav label row14 has only %0d px (T2)", navw_ink);
                errs = errs + 1;
            end

            if ((pgx == 2 || pgx == 4 || pgx == 7) && (card_leak !== 0)) begin
                $display("[FAIL] deleted page P%0d paints %0d card px", pgx, card_leak);
                errs = errs + 1;
            end

            //   ★ v89：P1「标定」按钮删掉后，P1 的标题带**不再有按钮文字**，
            //     但状态栏左上角仍有「P1 总览」⇒ 墨迹照旧要求 >0。
            //   ★ v88：P7(6) 标定页已删（txt_page 不再含 page 6），这一档再也
            //     不是"活页"，所以不再要求它有墨迹（原来 v87 及以前有）。
            if ((pgx == 0 || pgx == 1 || pgx == 3 || pgx == 5) &&
                (tink <= 0)) begin
                $display("[FAIL] P%0d title band has no ink", pgx);
                errs = errs + 1;
            end else begin
                $display("[ OK ] P%0d title ink = %0d px", pgx, tink);
            end
        end

        // R9：P1 的导航「设置」
        t_page = 3'd0;
        set_ink = 0;
        repeat (2) @(posedge frame_st);
        if (set_ink <= 0) begin
            $display("[FAIL] P1 nav \"设置\" cell is empty (R9)");
            errs = errs + 1;
        end else begin
            $display("[ OK ] P1 nav setting cell ink = %0d px", set_ink);
        end

        $display("================================================================");
        if (errs == 0) $display("[PASS] tb_disp_v58: all checks passed");
        else           $display("[FAIL] tb_disp_v58: %0d check(s) failed", errs);
        $display("================================================================");
        $finish;
    end
endmodule
