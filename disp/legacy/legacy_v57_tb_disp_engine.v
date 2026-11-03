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

module tb_disp_engine;

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
    // v45（㊷）空态：BiSS 帧 CRC 错（抽头真信号，rtl 里是 crc_err_seen 的 sticky 标志）。
    //   默认 0 = "链路正常"，各段按需拉起来验空态；段末一律复原 0。
    reg         t_crc      = 1'b0;
    // v54（C3，契约 v1.1）：**链路静默**（BiSS 主机 `ma` 无边沿 > 2 ms @50 MHz）。
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
        .tap_calib_busy (1'b0),
        .tap_biss_crc_err(t_crc),  // v45（㊷）：空态判据的第三个来源
        .tap_biss_link_lost(t_link_lost),  // v54（C3）：第四个来源，非粘滞
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

    // ---- 断言状态 ----
    //   ★ 行/帧边界**不用** line_st / frame_st 做判据：那两个脉冲可能与
    //     "本行最后一个像素"落在同一拍，结算（清零）与计数（+1）会在同一拍
    //     争抢同一个变量 —— 2026-10-15 实测就因此稳定少算 1 个像素、1 行
    //     （1023/1024、599/600）。改用自洽判据：de 下降沿 = 本行结束；
    //     本帧 de 有效像素攒满 H_DISP*V_DISP = 614400 个 = 本帧结束。
    localparam integer FRAME_DE = H_DISP * V_DISP;   // 614400
    reg de_d = 1'b0;
    reg pending_frame_end = 1'b0;
    integer errors = 0;
    integer n_de_row = 0;        // 本行 de 计数
    integer n_de_frame = 0;      // 本帧 de 像素累计（判帧边界用）
    integer n_row = 0;           // 本帧已结束的行数
    integer n_blank_rgb = 0;     // 消隐期出现非 0 颜色的次数
    integer n_frame = 0;         // 完整帧数
    integer max_de_row = 0;
    integer min_de_row = 999999;
    reg [23:0] alive_a, alive_b;

    // ---- [5] 文字层对齐守卫（2026-10-15 补）----
    //   为什么要加：disp_engine 曾把字形数据**多寄存一拍**，于是每个格显示的是
    //   前一个格的字符 —— 整页文字右移整整一格（lab 层 16 px、val 层 32 px）。
    //   当时这个测试台只查几何（de/行/帧计数）与消隐，**完全看不到**这个错误；
    //   是靠 disp/sim/smoke_p1.v 的人眼缩略图才发现的。这条守卫把它变成可自动判定的。
    //   选点：取标签**第一个字**，判据是"最左文字像素落在该格的第 0..3 px 内"。
    //   为什么给 4 px 容差：ASCII 字形（10x14）总是从行位最高位起画，无法偏；
    //   但汉字是 16x16 点阵，像"总""输"这类字本身的第 0 列就是空白（左边留白），
    //   最左墨点自然落在 +1。原先写死 "== 16 / == 64" 的判据在换成汉字后会误报。
    //   容差仍远小于一格（lab 格宽 16 px），所以"整页文字右移一格"的缺陷照样抓得住。
    //     lab 层导航标签 "总览" 在格行 4、格列 1 ⇒ y=65..78，最左文字像素应在 x=16..19
    //     lab 层卡片标签 "输入频率" 在格行 5、格列 6 ⇒ y=81..94，最左文字像素应在 x=96..99
    localparam [23:0] C_TEXT = 24'h1F2D3D;
    integer min_x_nav = 999999;
    integer min_x_lab = 999999;

    // ---- [6] 导航高亮跟随页号（2026-10-15 补）----
    //   选点：x=8 —— 它在导航列内、又避让了左端 4 px 的告警条；
    //         导航文字从 lab 格列 1 = x16 起，所以 x=8 一定没有任何字形。
    //   y=100 落在导航项 0（24..119；文字在 64..79 的**下方**），
    //   y=580 落在导航项 5（504..599；文字在 544..559 的下方）—— 两处都是纯底色，
    //   所以读到的就是 bg_sel 本身，不含任何字形叠加。
    localparam [23:0] C_SEC = 24'h8FC4EC;
    localparam [23:0] C_NAV = 24'hDCE9F5;

    // ---- [7] v19 绘制层采样（危险区 / 模态对话框 / 状态条三入口）----
    //   色板镜像（与 disp/disp_engine.v 的 localparam 一一对应）。
    localparam [23:0] C_BG    = 24'hEAF3FB;
    localparam [23:0] C_CARD  = 24'hFFFFFF;
    localparam [23:0] C_GRID  = 24'hD6E3F0;
    localparam [23:0] C_FAULT = 24'hD9453D;
    //   ★ v42（㊴）：第 2 颗按钮的描边兼作"恢复序列回读结果"的指示灯，
    //     全一致时用 C_OK（与 disp_engine.v:239 同值）。
    localparam [23:0] C_OK    = 24'h3FA45B;
    localparam [23:0] C_WARN  = 24'hE08B2D;   // v31（㉘）：与 disp_engine.v / spec 5.2 同值
    localparam [23:0] C_DIM   = 24'h5A6B7A;
    localparam [23:0] C_ACC   = 24'h2E7DD1;   // v20：标题带按钮/Tab 选中描边（disp_engine.v:162）
    localparam [23:0] C_TRACK = 24'hDCE9F5;   // v22：滑条轨道（与 C_NAV 同色，见 disp_engine.v）
    //   采样坐标一律用 dbg_x/dbg_y —— 它们与 lcd_rgb 同拍对齐（都出自 px2/py2 那一级再寄存），
    //   而 pix_x/pix_y 比它们早 3 拍。v19 之前 [4] 段用 pix_x 反推采样点，偏 3 px 看不出来
    //   （活性灯有 119 px 宽）；灯收窄到 64 px 之后 959 落到状态条底色上，才把量具的
    //   这个偏差照出来。**量具自己也要有量具：采样点必须与读数同源。**
    reg [23:0] samp;
    // ---- [7] 文字扫描：自由运行 always 每拍累加，门控信号是 dlg_tb 的**状态** ----
    //   为什么不划"帧相位"：实测 `wait (frame_done)` 两次之间只隔 1 个时钟，
    //   相位窗口根本落不到整帧上（三轮假 FAIL 都出在这里）。改成用 tb 自己控制的
    //   dlg_tb 当门控，配合"n_frame 变化 = 帧边界"的清零/读数，结果完全确定。
    integer    f0;                 // [7] 帧边界等待用的帧号快照
    integer    sc_dz_lbl;          // 危险区按钮标签（关闭态，格行 34）
    integer    sc_dz_lbl1;         // v34（㊲）：询问态下同一标签的像素（遮罩不许吃掉它）
    integer    sc_dlg_t0;          // 关闭态：对话框那三行的文字像素（含页面自己的字）
    integer    sc_dlg_t1;          // 询问态：对话框标题（格行 15）
    integer    sc_dlg_r1;          // 询问态：寄存器号（格行 17）
    integer    sc_dlg_t2;          // 忙碌态：对话框标题仍在
    integer    sc_p6r3;            // 对照：P6 第 1 项标题（**行带内** y 65..78，"倍频"）
    integer    sc_p6r4;            // 对照：P6 导航列（格行 4，"总览"）
    integer    sc_p6r5l;           // ★ v41（㊳）：第 5 项（88 px 行带 4）的**标题**墨迹
    integer    sc_p6r5v;           // ★ v41（㊳）：第 5 项（88 px 行带 4）的**数值**墨迹
    integer    sc_p6r3x;           // ★ v41（㊳）：旧自然格行 3（y 48..63）的**残留**墨迹，必须为 0
    // ---- [7] v42（㊴）：两颗对称按钮 + 恢复默认对话框 ----
    //   第 1 颗按钮的标签从格列 23 挪到格列 21（两颗按钮各 412 px 居中），所以
    //   `sc_dz_lbl`/`sc_dz_lbl1` 的窗口跟着从 x 368..495 改成 x 336..431；
    //   第 2 颗按钮的标签是新加的（格行 34 格列 49 = x 784..847）。
    //   两套对话框共用同一张版面：清除锁存故障用**格行 13/18**、恢复默认用
    //   **格行 14/19**（`dlg_title_row`/`dlg_body_row` 由 ui_dlg_kind 选）。
    //   所以判据是"同一次询问里，另一套的行必须一个字都没有"——
    //   这就是"两套对话框真的分开了"的证伪点，单看"有字"是骗得过去的。
    integer    sc_dz_lbl2;         // ★ v42（㊴）：第 2 颗按钮的标签（x 784..847）
    integer    sc_dlg_k1t;         // ★ v42（㊴）：恢复默认对话框的标题行（格行 14 = y 224..239）
    integer    sc_dlg_k1b;         // ★ v42（㊴）：恢复默认对话框的正文行（格行 19 = y 304..319）
    integer    sc_dlg_k1x;         // ★ v42（㊴）：正文右侧空白段（x 624..703）—— 证伪"没挪位"
    // ---- [8] v20：标题带按钮文字（P1 标定 / P4 展开，按 t_page 门控）----
    //   ★ v43（㊵）：P4 的按钮从 ASCII `EXPAND` 改成 spec 4.6 的字面「展开」，
    //     Tab 1 从 `SIM` 改成 spec 4.4 的字面「模拟」（字库补了 模/拟/展/开 四个字）。
    integer    sc_btn_p1;          // P1 标题带按钮区内的文字像素（"标定"）
    integer    sc_btn_p4;          // P4 标题带按钮区内的文字像素（v43 起是"展开"）
    integer    sc_tab_p2;          // P2/P3 Tab 栏区内的文字像素（v43 起是"模拟"/"XY"）
    // ---- [9] v22：编辑面板文字（格行 21 标题 / 格行 34 三个按钮标签）----
    integer    sc_pnl_t;           // 面板文字像素（门控 = pnl_on_tb）
    // ---- [19] v51（㊽）：面板右上"等效倍率 / AB 边沿率"两格行（y 368..415、x 576..752）----
    //   ★ 无条件统计（不用 pnl_on_tb 门控）：正反两条断言分别判 >0 与 ==0，
    //     否则"面板收起后归零"就是同义反复（同 §[9] 的教训）。
    integer    sc_b4_t;            // 右上两行的文字像素
    // ---- [20] v52（㊾）：卡 6 次级行 `U● V● W○` 的逐格对码结果 ----
    reg        uv_ok;              // 8 格字符码全对 = 1
    // ---- [10] v24：BACK 按钮的「↩ 回到 ×N ÷M」标签带（格行 34，列 46..54）----
    //   v44（㊶）：标签从 7 格扩到 9 格（多出 '÷' 与分频个位），循环变量与期望数组同步。
    integer    sc_back_t;          // BACK 按钮区（x 736..879）内的文字像素
    integer    ink_8;              // [10] 三个用例的墨量（大小关系本身是判据）
    integer    ink_256;
    integer    ink_0;
    integer    ink_div;            // v44（㊶）：一个"分频个位"用例的墨量（与 ink_8 比）
    // ---- [9b] v44（㊶）：面板数值窗（同一组大字段显示待应用倍频 / 待应用分频）----
    //   ★ 区间必须从 y = 352 起：格行 21 的「倍频分频」标题在 y 336..351，从 336 起
    //     会把标题文字算进"值窗墨量"，三位数与一位数的比较就废了。
    integer    sc_win_t;           // 数值窗区（x 330..571, y 352..441）内的 C_TEXT 像素
    integer    ink_v3;             // ×256 的窗内墨量（三位数）
    integer    ink_v2;             // ×64 的窗内墨量（两位数）
    integer    ink_v1;             // ÷7 的窗内墨量（一位数）
    //   ★ 三个大字段**各自**的墨量：面板通路（拆位）与键盘通路（直接给数字）
    //     喂同一组数字时，逐格墨量必须相等 —— 这是拆位算法的功能判据。
    //     大字段 48×80，x 从 340 / 412 / 484 起（KPV_X = 340、KPV_DX = 72），
    //     y 352..431（窗框 KPV_Y0/Y1 = 342/442）。
    integer    sc_d2_t, sc_d1_t, sc_d0_t;
    integer    ink_p2, ink_p1, ink_p0;   // 面板通路三格
    integer    ink_k2, ink_k1, ink_k0;   // 键盘通路三格
    reg [7:0]  exp_lab [0:8];      // 本用例 9 个格的期望字符码
    integer    lk;                 // 标签带比较用的循环变量
    // ---- [11b] v45（㊷）：空态 ----
    //   基线快照：两个**非测量**字段（字段 1 倍频分频 = 配置回读、字段 5 ABZ/UVW
    //   = 逻辑电平）在信号可信时的字符码。空态轮必须与基线**逐格相同** ——
    //   不硬编码 "* 64 d1" 这类模式，免得随配置/字模漂移假报错。
    reg [7:0]  base_ratio [0:6];   // 值层 (2, 13..19)
    reg [7:0]  base_abz   [0:7];   // 值层 (7, 23..30)
    integer    bq;                 // 空态轮的循环变量
    integer    ndig_t;             // 输入频率字段里的数字字符个数（基线/复原两处用）
    integer    ndash_t;            // 同一个字段里的 '-' 个数（空态的唯一硬标志）
    // ---- [17] v48（㊺）A2：卡 4 次级 pos_full 的十六进制期望/实测 ----
    reg [7:0]  hex_exp [0:7];      // 8 位十六进制字符码（"003A1B2C"）
    reg [7:0]  lab_got;            // 读回来的标签层字符码
    // ---- [11] v30：卡片迷你状态条（●正常 / ▲警示 / ✖故障）----
    //   注意：驱动遥测的四个寄存器必须声明在 u_dut 例化**之前** —— 例化端口表里
    //   用到未声明标识符时，Verilog 会先给它隐式声明成 1 bit 的 wire，后面再补
    //   `reg` 声明就撞车（xvlog 报 "'t_io_flags' is already implicitly declared"）。
    //   这四个原本是例化里的常数（8'h00 / 1'b1 / 1'b0），状态条一上来就提成 tb 变量，
    //   否则"卡 6 两路都没使能 ⇒ 故障"那条分支永远够不着。
    integer    sc_chip_t;          // 卡片状态条 4 格内的 C_TEXT 像素（按页号门控）
    // ---- [11] v31（㉘）：第三重冗余「反转视频（白字反色块）」----
    //   spec 5.2 的四重冗余 = 字形 + 中文文字 + 反转视频（白字反色块）+ 可关的 2 Hz 闪烁。
    //   判据分两半，缺一半就会被"只是换了字"骗过去：
    //     ① `sc_chip_t`（C_TEXT 墨量）：正常轮 > 0（黑字在屏上）；警示轮 == 0
    //        （字变成白的了 —— 这就是"反色块"存在的证据）；
    //     ② `sc_chip_bg`（C_WARN/C_FAULT 块色像素）：正常轮 == 0（不反转）；
    //        警示/故障轮 > 0（整块 64x16 变成状态色）。
    //   颜色本身另用 expect_px 钉在**空格那一格**的坐标上（那格没有字形，
    //   像素只可能是块色或卡片白底，不受字模改动影响）。
    integer    sc_chip_bg;
    integer    ink_chip_ok;        // 轮 A（卡 1 正常）的 C_TEXT 墨量
    integer    ink_chip_warn;      // 轮 B（卡 1 警示）的 C_TEXT 墨量（期望 0）
    integer    ink_chip_block;     // 轮 B（卡 1 警示）的块色像素（期望 > 0）
    // ---- [12] v32（㉙）：第四重冗余「可关闭的 2 Hz 闪烁」----
    //   闪烁只改"反色块显不显示"，所以判据是"同一条状态条在两个相位下的两种长相"：
    //     相位 1（亮）：块色 > 0、黑字 == 0；相位 0（灭）：块色 == 0、黑字 > 0。
    //   关掉闪烁（ui_blink_en = 0）时相位 0 也必须常亮 ⇒ ㉘ 的行为一字不变。
    integer    f1;                 // [12] 自己的帧号快照（不蹭 wait_frames 的 f0）
    integer    blink_on_bg;        // 相位 1 的块色墨量
    integer    blink_on_tx;        // 相位 1 的黑字墨量（期望 0）
    integer    blink_off_bg;       // 相位 0 的块色墨量（期望 0）
    integer    blink_off_tx;       // 相位 0 的黑字墨量
    integer    blink_dis_bg;       // 闪烁关闭 + 相位 0 的块色墨量（期望 > 0）
    reg        hold_page = 1'b0;   // [7] 期间钉住页号（帧末的自动翻页要停）
    // ---- [14] v36（㉜）：P8「自检结果」的结论（规范 §4.4 的第 ⑤ 项）----
    //   结论文本由 disp/selftest_lab.v 每帧写进 p8_lab_ram 的 {36,36}/{36,37}，
    //   它吃的三个 IIC 计数来自 tch_diag 的位域（与 touch_view 同一根总线）：
    //     读次数 [99:76] / 无应答 [123:100] / 超时 [147:124]
    //   判据两层：① 直接读 RAM 格子（内容精确）② 那一带的 C_TEXT 墨量 > 0
    //   （证明文字层真的画出来了，而不只是 RAM 里对）。
    //   （t_diag 的声明在例化之前，这个块里只放累加器与判据用的中间量。）
    integer    p8v_px;             // P8 结论两格的 C_TEXT 墨量（按页号门控）
    reg        p8v_on = 1'b0;      // 该累加器的使能
    // ---- [15] v38（㉞）：P4 等效采样注记（spec §7 :305 的"在图上注明"）----
    //   注记是**静态版面**（tools/gen_text_ram.py 的 P4_LAB `(27, 6, …)` 起 14 格），
    //   所以判据分两层，缺一层就会被骗过去：
    //     ① 直接读 u_p4_lab_ram 的 14 格字符码 —— 精确到"屏上是哪个字"
    //        （只看像素时，"128点等效采样"和"按电角度重建128箱等效采样"都是黑字）；
    //     ② 那一条带里的 C_TEXT 墨量 > 0 —— 证明文字层真的画出来了
    //        （只读 RAM 时，"写对了但没渲染"照样绿）。
    integer    p4n_px;             // P4 注记那一条带的 C_TEXT 墨量（按页号门控）
    reg        p4n_on = 1'b0;      // 该累加器的使能
    reg [7:0]  exp_note [0:13];    // 14 格的期望字符码（码值口径见 check_p4note）
    // ---- [16] v39（㉟）：P1 两处口径注记（spec §7 数据来源表 :300 / :302）----
    //   规范对这两条的原话：
    //     · :300 机械转速 RPM = 60×f_in/极对数 ⇒ **标「估算值」**；
    //     · :302 累计转数从「本次上电」起算、**不是掉电保存的绝对值，屏上要写明**。
    //   两条都是**静态版面**（tools/gen_text_ram.py 的 P1_LAB），判据与 [15] 同构：
    //     ① 直接读 u_p1_lab_ram 的格子字符码 —— 精确到"屏上是哪个字"
    //        （只看像素时，"估算值"这三个字画没画出来根本分不清是什么）；
    //     ② 两条带里的 C_TEXT 墨量 > 0 —— 证明文字层真的画出来了
    //        （只读 RAM 时，"写对了但没渲染"照样绿）。
    //   码值口径 = 51（ASCII_CHARS 的字数）+ tools/cn_glyphs.py 的 CHARS 下标；
    //   期望值由 _disp_work/_probe39.py 从生成器现算，verify_u39.py 逐项复核。
    integer    p1n_px;             // 「估算值」那一条带的 C_TEXT 墨量（按页号门控）
    integer    p1q_px;             // 「本次上电起算」那一条带的 C_TEXT 墨量
    reg        p1n_on = 1'b0;      // 上面两个累加器的共同使能
    reg [7:0]  exp_est     [0:2];  // 转速卡「估算值」3 格的期望字符码
    reg [7:0]  exp_revnote [0:5];  // 累计转数卡「本次上电起算」6 格的期望字符码
    reg [23:0] navbg0, navbg1, navbg2, navbg3, navbg4, navbg5;
    reg [2:0]  exp_sel;          // 本帧期望被高亮的导航项号（3'd7 = 一个都不高亮）
    reg        nav_err;
    integer dbg_sc0 = 0, dbg_sc5 = 0;

    // ---- [17] v58：R8 卡 6 电平条按页门控 / R9 导航「设置」不再被整行排除 ----
    //   R8：卡 6 的六行电平条只属于 P1 卡片 6（x 752..1007、y 512..559），判据里必须
    //       带 (page == 0)。以前漏了门控 ⇒ 每页右下角都浮出几条蓝线。这里直接引
    //       被测件的组合信号 c6_draw（与像素同拍），非 P1 页上一个像素都不许为真。
    //   R9：导航「设置」在 lab 格（行 34、列 1）= x 16..31、y 544..559。以前
    //       glyph_page 在 P1 上整行排除 21/34 ⇒ 这一项被一起抹掉。这里数 C_TEXT 墨量。
    integer c6_non_p1_px = 0;      // 非 P1 页上 c6_draw 为真的像素数（必须 0）
    integer set_nav_px   = 0;      // P1 导航「设置」那 16x16 格的 C_TEXT 墨量（必须 > 0）

    // ---- [7] 采样与扫描任务 ----
    task sample_at;                    // 等 (sx,sy) 这个像素过去，取它的合成色
        input [11:0] sx, sy;
        begin
            wait (de_o && (dbg_x == sx) && (dbg_y == sy));
            samp = lcd_rgb;
        end
    endtask

    task expect_px;                    // 采样 + 比对
        input [11:0] sx, sy;
        input [23:0] want;
        input [8*24-1:0] tag;
        begin
            sample_at(sx, sy);
            if (samp === want) begin
                $display("[ OK ] %0s @ (%0d,%0d) = %h", tag, sx, sy, samp);
            end else begin
                errors = errors + 1;
                $display("[FAIL] %0s @ (%0d,%0d) = %h, want %h", tag, sx, sy, samp, want);
            end
        end
    endtask

    //   ★ 已删除 count_text（task + wait/while 数矩形的写法）：实测它会在行内提前
    //     退出，连"一定存在"的 P1 导航文字都数到 0，用它得到的判据全是假的。
    //     文字判据现在一律走上面的每帧累加器（sc_*），门控信号是 dlg_tb 状态。

    // ---- [10] v24：等 n 个帧边界（"n_frame 变化 = 帧边界"是 [7] 起就用的量具）----
    task wait_frames;
        input integer n;
        integer q;
        begin
            for (q = 0; q < n; q = q + 1) begin
                f0 = n_frame; while (n_frame == f0) @(posedge clk);
            end
        end
    endtask

    // ---- [10] 读层次里 p1_lab_ram 的写结果，比对 7 个格的字符码 ----
    //   为什么不看像素：像素能证明"画出来了"，却看不清"值是不是这个数"；
    //   两条判据分工，缺一条就会漏掉一半（㉓ 记录的教训）。
    task check_lab;
        input [8*16-1:0] tag;
        begin
            for (lk = 0; lk < 9; lk = lk + 1) begin
                if (u_dut.u_p1_lab_ram.mem[{6'd34, 6'd46 + lk[5:0]}] !== exp_lab[lk]) begin
                    errors = errors + 1;
                    $display("[FAIL] 标签带 %0s 第 %0d 格（列 %0d）= %0d，期望 %0d",
                             tag, lk, 46 + lk,
                             u_dut.u_p1_lab_ram.mem[{6'd34, 6'd46 + lk[5:0]}], exp_lab[lk]);
                end
            end
            $display("[ OK ] 标签带 %0s：9 格字符码全对", tag);
        end
    endtask

    // ---- [14] v36（㉜）：读 P8 的 lab 格（底栏结论区）----
    //   与 check_lab / check_card 同一条经验：像素证明"画出来了"，看不清"写的是
    //   哪个字"；所以内容一律直接读 RAM，像素只作活性判据（p8v_px）。
    task check_p8cell;
        input [8*20-1:0] tag;
        input [5:0]      cc;
        input [7:0]      want;
        begin
            if (u_dut.u_p8_lab_ram.mem[{6'd36, cc}] !== want) begin
                errors = errors + 1;
                $display("[FAIL] P8 %0s 格 (%0d,%0d) = %0d，期望 %0d",
                         tag, 36, cc, u_dut.u_p8_lab_ram.mem[{6'd36, cc}], want);
            end else begin
                $display("[ OK ] P8 %0s 格 (%0d,%0d) = %0d", tag, 36, cc, want);
            end
        end
    endtask

    // ---- [15] v38（㉞）：读 P4 的 lab 格（等效采样注记那 14 格）----
    //   与 check_lab / check_p8cell 同一条经验：像素证明"画出来了"，看不清"写的是
    //   哪个字"；所以内容一律直接读 RAM，像素只作活性判据（p4n_px）。
    //   码值口径 = 51（ASCII_CHARS 的字数）+ tools/cn_glyphs.py 的 CHARS 下标；
    //   这张表与生成器的一致性由 _disp_work/verify_u38.py 逐项复核（两处共同契约）。
    task check_p4note;
        input [8*16-1:0] tag;
        integer q;
        begin
            for (q = 0; q < 14; q = q + 1) begin
                if (u_dut.u_p4_lab_ram.mem[{6'd27, 6'd6 + q[5:0]}] !== exp_note[q]) begin
                    errors = errors + 1;
                    $display("[FAIL] P4 注记 %0s 第 %0d 格（行 27 列 %0d）= %0d，期望 %0d",
                             tag, q, 6 + q,
                             u_dut.u_p4_lab_ram.mem[{6'd27, 6'd6 + q[5:0]}], exp_note[q]);
                end
            end
            $display("[ OK ] P4 注记 %0s：14 格字符码全对", tag);
        end
    endtask

    // ---- [16] v39（㉟）：读 P1 两处口径注记的格子（转速卡 3 格 + 累计转数卡 6 格）----
    //   与 check_lab / check_p4note 同一条经验：像素证明"画出来了"，看不清"写的是
    //   哪个字"；所以内容一律直接读 RAM，像素只作活性判据（p1n_px / p1q_px）。
    //   这两条注记都是**页面层静态文字**，没有任何运行期写者（P1 上只有格行 15/36
    //   的迷你状态条与格行 34 的撤销值由 disp/stat_chip.v、disp/undo_lab.v 覆写），
    //   所以格子读数就是版面契约本身。
    task check_p1notes;
        input [8*16-1:0] tag;
        integer q;
        begin
            for (q = 0; q < 3; q = q + 1) begin
                if (u_dut.u_p1_lab_ram.mem[{6'd14, 6'd46 + q[5:0]}] !== exp_est[q]) begin
                    errors = errors + 1;
                    $display("[FAIL] %0s「估算值」第 %0d 格（行 14 列 %0d）= %0d，期望 %0d",
                             tag, q, 46 + q,
                             u_dut.u_p1_lab_ram.mem[{6'd14, 6'd46 + q[5:0]}], exp_est[q]);
                end
            end
            for (q = 0; q < 6; q = q + 1) begin
                if (u_dut.u_p1_lab_ram.mem[{6'd23, 6'd26 + q[5:0]}] !== exp_revnote[q]) begin
                    errors = errors + 1;
                    $display("[FAIL] %0s「本次上电起算」第 %0d 格（行 23 列 %0d）= %0d，期望 %0d",
                             tag, q, 26 + q,
                             u_dut.u_p1_lab_ram.mem[{6'd23, 6'd26 + q[5:0]}], exp_revnote[q]);
                end
            end
            $display("[ OK ] P1 口径注记 %0s：3 + 6 格字符码全对", tag);
        end
    endtask

    // ---- [11] v30：读六张卡状态条那 4 格的字符码 ----
    //   顺序固定为「字形 / 空格 / 词首字 / 词末字」，格行格列由卡号推出来
    //   （与 disp/stat_chip.v 的 ROW_TOP/ROW_BOT、COL_0/1/2 同源）。
    //   为什么不省掉"空格"那一格：那格是**刻意的空格**（字形与词之间留一格），
    //   静态版面里它是空的，如果哪天词挪了一格，这条断言会立刻红 —— 位置契约。
    task check_card;
        input [8*16-1:0] tag;
        input [2:0]      ci;
        input [7:0]      g, wa, wb;
        reg [5:0]        rc, cc;
        begin
            rc = (ci < 3'd3) ? 6'd15 : 6'd36;
            cc = ((ci == 3'd0) || (ci == 3'd3)) ? 6'd6  :
                 ((ci == 3'd1) || (ci == 3'd4)) ? 6'd26 : 6'd46;
            if (u_dut.u_p1_lab_ram.mem[{rc, cc}] !== g) begin
                errors = errors + 1;
                $display("[FAIL] %0s 卡 %0d 字形格 (%0d,%0d) = %0d，期望 %0d",
                         tag, ci + 1, rc, cc, u_dut.u_p1_lab_ram.mem[{rc, cc}], g);
            end
            if (u_dut.u_p1_lab_ram.mem[{rc, cc + 6'd1}] !== 8'd0) begin
                errors = errors + 1;
                $display("[FAIL] %0s 卡 %0d 分隔格 (%0d,%0d) = %0d，期望空格",
                         tag, ci + 1, rc, cc + 1, u_dut.u_p1_lab_ram.mem[{rc, cc + 6'd1}]);
            end
            if (u_dut.u_p1_lab_ram.mem[{rc, cc + 6'd2}] !== wa) begin
                errors = errors + 1;
                $display("[FAIL] %0s 卡 %0d 词首字 (%0d,%0d) = %0d，期望 %0d",
                         tag, ci + 1, rc, cc + 2, u_dut.u_p1_lab_ram.mem[{rc, cc + 6'd2}], wa);
            end
            if (u_dut.u_p1_lab_ram.mem[{rc, cc + 6'd3}] !== wb) begin
                errors = errors + 1;
                $display("[FAIL] %0s 卡 %0d 词末字 (%0d,%0d) = %0d，期望 %0d",
                         tag, ci + 1, rc, cc + 3, u_dut.u_p1_lab_ram.mem[{rc, cc + 6'd3}], wb);
            end
        end
    endtask

    // ---- [11] v30：六卡状态探针（{卡6,卡5,卡4,卡3,卡2,卡1} 各 2 bit）----
    task check_chip_st;
        input [8*16-1:0] tag;
        input [11:0]     want;
        begin
            if (u_dut.u_stat_chip.chip_st !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s 六卡状态探针 chip_st = %h，期望 %h",
                         tag, u_dut.u_stat_chip.chip_st, want);
            end else $display("[ OK ] %0s 六卡状态探针 chip_st = %h", tag, want);
        end
    endtask

    //   [9] 用的反向判据："这个坐标上**不许**出现某个颜色"。面板关着时，
    //   面板的签名色（描边强调色 / 轨道色 / 待应用黄 / 压暗灰）都不许出现；
    //   至于那里到底是什么底色，由页面自己决定（P1 下半屏是白卡还是页底
    //   不属于本段的契约，钉住它反而会随页面改版而假报错）。
    //   ★ 但"签名色"里**不包含 `C_TEXT`** —— 它是页面文字（字库层）与面板符号
    //     共用的色。曾经这里有一条 `expect_not_px(192,496,C_TEXT)` 想证"面板关着
    //     时没有 [−] 符号"，它是**抛硬币**：P1 的数值层（`disp/text_ram.v` 的
    //     `p1_val_ram`，带 we/waddr/wdata）运行期每帧被 `val_format` 重写，而本台
    //     :75 的 `t_angle` 每帧 +8192 ⇒ 同一像素逐帧翻墨。㊲ 在 [7] 段插两条采样
    //     （`sample_at` 是 wait，会把相位整体挪一格）就把它挪红了，**RTL 一字未改**
    //     （`f1c8f1f` 全量回归时它是绿的 = 运气）。⇒ 改用下面的分层信号判据。
    task expect_not_px;
        input [11:0] sx, sy;
        input [23:0] bad;
        input [8*24-1:0] tag;
        begin
            sample_at(sx, sy);
            if (samp === bad) begin
                errors = errors + 1;
                $display("[FAIL] %0s @ (%0d,%0d) = %h（这个坐标不该出现该色）", tag, sx, sy, samp);
            end else begin
                $display("[ OK ] %0s @ (%0d,%0d) = %h", tag, sx, sy, samp);
            end
        end
    endtask

    //   v34（㊲）：**分层信号判据** —— "面板**层**在这一点使能了吗"，取代"合成出来的
    //   颜色对不对"。合成结果分不清那一笔是页面画的还是面板画的（见上面那段注释），
    //   而层信号 `pnl_any` 本身就带 `pnl_on` 门控（`disp/disp_engine.v:1706`：
    //   `wire pnl_any = pnl_on && (cx >= PNL_X0) && ...`）⇒ 关着时必为 0、开着时
    //   在该按钮内必为 1，**与页面内容完全无关**，因而不随页面改版假报错。
    //   ★ 坐标必须取**与合成同拍**的内部坐标 `px2/py2`（`wire [11:0] cx = px2;`
    //     `disp/disp_engine.v:1183`），不能用输出栅格的 `dbg_x/dbg_y`：`dbg_x <= px2`
    //     比 px2 **又晚一拍**（`disp/disp_engine.v:2042`），在那时读 `pnl_any` 会
    //     差一个像素（`sample_at` 等的就是 dbg_x/dbg_y）。
    task expect_pnl_layer;
        input [11:0] sx, sy;
        input        want;
        input [8*40-1:0] tag;
        begin
            wait (u_dut.de2 && (u_dut.px2 == sx) && (u_dut.py2 == sy));
            if (u_dut.pnl_any !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : 面板层 pnl_any @ (%0d,%0d) = %b, want %b",
                         tag, sx, sy, u_dut.pnl_any, want);
            end else begin
                $display("[ OK ] %0s : 面板层 pnl_any @ (%0d,%0d) = %b",
                         tag, sx, sy, u_dut.pnl_any);
            end
        end
    endtask



    // ---- [11b] v45（㊷）空态：P1 数值层单格字符码 ----
    //   判据为什么落在**字符码**上：像素颜色分不清"这一笔是数字还是短横"，
    //   而 `p1_val_ram` 的字符码就是"屏上是哪个字"的唯一硬证据（与 [10]/[11]
    //   读 `p1_lab_ram` 同一手法）。空态的 '-' 正是字符码 2（CH_MINUS）。
    task chk_val_cell;
        input [8*24-1:0] tag;
        input [5:0]      vrow, vcol;
        input [7:0]      want;
        reg   [7:0]      got;
        begin
            //   值层的格地址 = {行[3:0], 列[4:0]}（行 0..9、列 0..31）—— 与
            //   `disp/disp_engine.v:930-932` 的 `{val_cy, val_cx}` 同式。
            //   ★ 不能照抄 lab 层的 {行[5:0], 列[5:0]}：lab RAM 是 mem[0:2431]
            //   （列距 64），值层是 mem[0:319]（列距 32），照抄会读到别的格甚至越界 X。
            got = u_dut.u_p1_val_ram.mem[{vrow[3:0], vcol[4:0]}];
            if (got !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s 值层 (%0d,%0d) got %0d want %0d",
                         tag, vrow, vcol, got, want);
            end
        end
    endtask

    //   整格期望：wid 格，从右数第 frac 格是小数点、其余全是 '-'（frac=0 时全 '-'）
    task chk_val_dashes;
        input [8*24-1:0] tag;
        input [5:0]      vrow, vcol;
        input [4:0]      wid, frac;
        integer          k;
        begin
            for (k = 0; k < wid; k = k + 1) begin
                if ((frac != 5'd0) && (k == (wid - 5'd1 - frac)))
                    chk_val_cell(tag, vrow, vcol + k[5:0], 8'd1);   // CH_DOT
                else
                    chk_val_cell(tag, vrow, vcol + k[5:0], 8'd2);   // CH_MINUS
            end
        end
    endtask

    // 本帧第 614400 个有效像素出现的这一拍 = 本帧结束
    wire frame_done = de && ((n_de_frame + 1) == FRAME_DE);

    // ---- 实测帧周期（不许拿常数冒充测量值）----
    integer cyc = 0;
    integer measured_period = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (frame_done) begin
                //   cyc 统计的是"两次 frame_done 之间、除帧边界那一拍以外"的拍数，
                //   所以真实周期 = cyc + 1。这是测量仪器的 off-by-one，不是 DUT 的。
                if (n_frame > 0) measured_period <= cyc + 1;
                cyc <= 0;
            end else begin
                cyc <= cyc + 1;
            end
        end
    end

    // ---- 每拍：行内 de 计数 + 消隐期颜色检查 + 行/帧边界结算 ----
    //   ★ 全部放在**同一个 always 块、统一非阻塞赋值**。2026-10-15 的原始版本
    //     把计数放一个块（NBA）、清零放另一个块（阻塞赋值），同一拍对 n_de_row
    //     有两个写者 —— 清零被 NBA 覆盖，每行计数变成累计值 2048/3072/4096…，
    //     测试台自己制造了约 1800 个假错误。
    always @(posedge clk) begin
        if (rst_n) begin
            de_d <= de;

            if (de) begin
                n_de_row   <= n_de_row + 1;
                n_de_frame <= n_de_frame + 1;
            end

            // 消隐期必须输出黑。判据用 de_o（与 lcd_rgb 同拍），不能用 de：
            // 用 de 会比数据早 3 拍，每行的 DE 下降沿都会多报一个假违例。
            if (!de_o && (lcd_rgb !== 24'h000000)) n_blank_rgb <= n_blank_rgb + 1;

            // ---- [5] 文字层对齐采样（判据见声明处）----
            if (de_o && lcd_rgb === C_TEXT) begin
                if (dbg_y >= 65 && dbg_y <= 78  && dbg_x < min_x_nav) min_x_nav <= dbg_x;
                if (dbg_y >= 81 && dbg_y <= 94  && dbg_x < min_x_lab) min_x_lab <= dbg_x;
            end

            // ---- [7] 文字扫描（按 dlg_tb 的**状态**门控，不靠帧相位）----
            //   为什么不用 scan_ph + wait(frame_done) 划相位：实测那套划不出相位来
            //   （两个 wait 之间只隔了 1 个时钟），代价是三轮假 FAIL。用 tb 自己控制的
            //   dlg_tb 当门控信号则完全确定：dlg=0 的帧看危险区标签、dlg=1 的帧看对话框。
            //   计数由 [7] 段在帧边界前后清零/读数（帧边界用 n_frame 变化判，见 [7] 段）。
            if (de_o) begin
                if (dlg_tb == 2'd0) begin
                    // [dbg] 分组对照：P6 第 1 项标题带(标题 RAM 行 4 的**行带内**墨迹) /
                    //   P6 导航列(4) / 危险区标签(34)
                    //   ★ v41（㊳）：P6 改成 88 px 行带后，第 1 项的标题墨迹落在
                    //     带内 v 1..14 ⇒ y 65..78（不再是旧的 y 48..63）。
                    if ((dbg_y >= 12'd65) && (dbg_y <= 12'd78) &&
                        (dbg_x >= 12'd96) && (dbg_x <= 12'd143) && (lcd_rgb === C_TEXT))
                        sc_p6r3 <= sc_p6r3 + 1;
                    if ((dbg_y >= 12'd64) && (dbg_y <= 12'd79) &&
                        (dbg_x >= 12'd16) && (dbg_x <= 12'd31) && (lcd_rgb === C_TEXT))
                        sc_p6r4 <= sc_p6r4 + 1;
                    if ((dbg_y >= 12'd544) && (dbg_y <= 12'd559) &&
                        (dbg_x >= 12'd336) && (dbg_x <= 12'd431) && (lcd_rgb === C_TEXT))
                        sc_dz_lbl <= sc_dz_lbl + 1;
                    //   ★ v42（㊴）：第 2 颗按钮的标签（同一行的格列 49..52）。
                    if ((dbg_y >= 12'd544) && (dbg_y <= 12'd559) &&
                        (dbg_x >= 12'd784) && (dbg_x <= 12'd847) && (lcd_rgb === C_TEXT))
                        sc_dz_lbl2 <= sc_dz_lbl2 + 1;
                    //   ★ v41（㊳）：第 5 项（行带 4 = y 416..503）的两层墨迹。
                    //     标题：带内 v 1..14 ⇒ y 417..430，第 1 列标题 x 96..191。
                    //     数值：带内 v 24..65 ⇒ y 440..481，第 1 列数值 x 96..191。
                    if ((dbg_y >= 12'd417) && (dbg_y <= 12'd430) &&
                        (dbg_x >= 12'd96) && (dbg_x <= 12'd191) && (lcd_rgb === C_TEXT))
                        sc_p6r5l <= sc_p6r5l + 1;
                    if ((dbg_y >= 12'd440) && (dbg_y <= 12'd481) &&
                        (dbg_x >= 12'd96) && (dbg_x <= 12'd191) && (lcd_rgb === C_TEXT))
                        sc_p6r5v <= sc_p6r5v + 1;
                    //   ★ v41（㊳）：标题 RAM 行必须从 4 起。若还写在行 3，它的**自然**
                    //     位置 y 48..63 落在 p6_area（y >= 64）之外 ⇒ 自然映射会把这 5 个
                    //     标题多画一行到第一行带上方当残留文字。这里逐帧数残墨，判据要求 0。
                    //     ★ 窗口从 y 52 起、不从 49 起：标题带那个「闪烁」复选框
                    //     （CHK_X0/Y0 = 668/36，16x16，实心时是 C_TEXT）占 y 36..51，
                    //     照 49 起会把它的下沿数进来 —— 那 22 px 是假红（已实测）。
                    if ((dbg_y >= 12'd52) && (dbg_y <= 12'd62) &&
                        (dbg_x >= 12'd96) && (dbg_x <= 12'd831) && (lcd_rgb === C_TEXT))
                        sc_p6r3x <= sc_p6r3x + 1;
                    if ((dbg_y >= 12'd208) && (dbg_y <= 12'd223) &&
                        (dbg_x >= 12'd232) && (dbg_x <= 12'd792) && (lcd_rgb === C_TEXT))
                        sc_dlg_t0 <= sc_dlg_t0 + 1;
                end else if (dlg_tb == 2'd1) begin
                    //   ★ v34（㊲）：询问态下危险区按钮**不再被压暗**（它就是这次
                    //     二次确认的主体）。同一个窗口、同一个颜色再数一遍：遮罩
                    //     真把它吃掉时这里是 0（这就是旧版的行为）。
                    if ((dbg_y >= 12'd544) && (dbg_y <= 12'd559) &&
                        (dbg_x >= 12'd336) && (dbg_x <= 12'd431) && (lcd_rgb === C_TEXT))
                        sc_dz_lbl1 <= sc_dz_lbl1 + 1;
                    //   ★ v42（㊴）：两套对话框各占两行 —— 无条件数这四行，
                    //     由正反两条断言分别判 >0 与 ==0（kind 由 dlg_kind_tb 钉住）。
                    //     格行 14 = 恢复默认的标题（格列 30..33 = x 480..543）。
                    if ((dbg_y >= 12'd224) && (dbg_y <= 12'd239) &&
                        (dbg_x >= 12'd480) && (dbg_x <= 12'd543) && (lcd_rgb === C_TEXT))
                        sc_dlg_k1t <= sc_dlg_k1t + 1;
                    //     格行 19 = 恢复默认的正文（"REG 0X0100-051A"，格列 24..38
                    //       ⇒ x 384..623；★ ㊴ 把起始格列从 29 挪到 24 让它居中，
                    //       见 tools/gen_text_ram.py 的 v42 注释）。
                    if ((dbg_y >= 12'd304) && (dbg_y <= 12'd319) &&
                        (dbg_x >= 12'd384) && (dbg_x <= 12'd623) && (lcd_rgb === C_TEXT))
                        sc_dlg_k1b <= sc_dlg_k1b + 1;
                    if ((dbg_y >= 12'd304) && (dbg_y <= 12'd319) &&
                        (dbg_x >= 12'd624) && (dbg_x <= 12'd703) && (lcd_rgb === C_TEXT))
                        sc_dlg_k1x <= sc_dlg_k1x + 1;   // 证伪：右半段不该有墨
                    if ((dbg_y >= 12'd208) && (dbg_y <= 12'd223) &&
                        (dbg_x >= 12'd232) && (dbg_x <= 12'd792) && (lcd_rgb === C_TEXT))
                        sc_dlg_t1 <= sc_dlg_t1 + 1;
                    if ((dbg_y >= 12'd288) && (dbg_y <= 12'd303) &&
                        (dbg_x >= 12'd232) && (dbg_x <= 12'd792) && (lcd_rgb === C_TEXT))
                        sc_dlg_r1 <= sc_dlg_r1 + 1;
                end else begin
                    if ((dbg_y >= 12'd208) && (dbg_y <= 12'd223) &&
                        (dbg_x >= 12'd232) && (dbg_x <= 12'd792) && (lcd_rgb === C_TEXT))
                        sc_dlg_t2 <= sc_dlg_t2 + 1;
                end
            end

            // ---- [8] v20 标题带按钮 / Tab 栏文字（按 t_page 门控）----
            //   与 [7] 同一个纪律：门控信号是 tb 自己钉住的页号（t_page），不划帧相位。
            if (de_o) begin
                if ((t_page == 3'd0) || (t_page == 3'd3)) begin
                    if ((dbg_x >= 12'd660) && (dbg_x < 12'd820) &&
                        (dbg_y >= 12'd28)  && (dbg_y < 12'd60)  && (lcd_rgb === C_TEXT)) begin
                        if (t_page == 3'd0) sc_btn_p1 <= sc_btn_p1 + 1;
                        else                sc_btn_p4 <= sc_btn_p4 + 1;
                    end
                end
                if ((t_page == 3'd1) || (t_page == 3'd2)) begin
                    if ((dbg_x >= 12'd96) && (dbg_x < 12'd500) &&
                        (dbg_y >= 12'd96) && (dbg_y < 12'd136) && (lcd_rgb === C_TEXT))
                        sc_tab_p2 <= sc_tab_p2 + 1;
                end
            end

            // ---- [9] v22 编辑面板的文字（格行 21 = "倍频分频"/"PRESET"，
            //      格行 34 = "CANCEL"/"APPLY"/"回到"）----
            //   ★ v23：这里**不能**用 pnl_on_tb 门控 —— 上一版就是这么写的，结果
            //     "面板收起后文字消失"那条断言成了同义反复（门都关了当然数不到），
            //     真缺陷（面板关着时页面层照样画这两行）就藏过去了。现在无条件
            //     统计这两行的 C_TEXT 像素，由正反两条断言分别判 >0 与 ==0。
            if (de_o) begin
                if ((dbg_x >= 12'd96) && (dbg_x < 12'd928) &&
                    (((dbg_y >= 12'd336) && (dbg_y < 12'd352)) ||
                     ((dbg_y >= 12'd544) && (dbg_y < 12'd560))) && (lcd_rgb === C_TEXT))
                    sc_pnl_t <= sc_pnl_t + 1;
            end

            // ---- [19] v51（㊽）：面板右上"等效倍率 / AB 边沿率"两格行 ----
            //   格行 23 = y 368..383、格行 25 = y 400..415；列 36..46 = x 576..751。
            //   为什么不与 sc_pnl_t 合并：那两块（行 21/34）是面板的标题与命令按钮，
            //   这两行是 pnl_calc 每帧写进去的**动态值**，门控/清零节奏不同。
            if (de_o &&
                (dbg_x >= 12'd576) && (dbg_x < 12'd752) &&
                (((dbg_y >= 12'd368) && (dbg_y < 12'd384)) ||
                 ((dbg_y >= 12'd400) && (dbg_y < 12'd416))) && (lcd_rgb === C_TEXT))
                sc_b4_t <= sc_b4_t + 1;

            // ---- [10] v24：BACK 按钮的标签带（格行 34 = y 544..559，列 46..53）----
            //   判据只看这一小片里的 C_TEXT 像素，用来证明"标签真的画到屏上"：
            //   「↩ 回到 ×256」比「↩ 回到 ×8」墨多，avail=0 的「回到」最少 ——
            //   三者的计数大小关系就是这一段的活性判据。
            if (de_o && (t_page == 3'd0) &&
                (dbg_x >= 12'd736) && (dbg_x < 12'd880) &&
                (dbg_y >= 12'd544) && (dbg_y < 12'd560) && (lcd_rgb === C_TEXT))
                sc_back_t <= sc_back_t + 1;

            // ---- [9b] v44（㊶）：面板数值窗（x 330..571 = 三个 48×80 大字段，
            //      y 352..441）----
            //   门控只按 de_o：面板层在时（pnl_on_tb=1）面板矩形内的页面字形全被
            //   抑制（disp_engine 的 glyph_pnl_sup），这块区域只剩面板自己的层 ——
            //   白底 + C_TEXT 的数字。三档互比即"窗口跟着字段换内容"的活性判据。
            if (de_o &&
                (dbg_x >= 12'd330) && (dbg_x < 12'd572) &&
                (dbg_y >= 12'd352) && (dbg_y < 12'd442) && (lcd_rgb === C_TEXT))
                sc_win_t <= sc_win_t + 1;

            //   三个大字段各自的墨量（同一段区域，按 48 px 宽切成三格）：
            //   面板通路（拆位得到的数字）与键盘通路（数字寄存器）逐格比。
            if (de_o && (dbg_y >= 12'd352) && (dbg_y < 12'd432) && (lcd_rgb === C_TEXT)) begin
                if ((dbg_x >= 12'd340) && (dbg_x < 12'd388)) sc_d2_t <= sc_d2_t + 1;
                if ((dbg_x >= 12'd412) && (dbg_x < 12'd460)) sc_d1_t <= sc_d1_t + 1;
                if ((dbg_x >= 12'd484) && (dbg_x < 12'd532)) sc_d0_t <= sc_d0_t + 1;
            end

            // ---- [11] v30：卡片 1 的状态条那 4 格（格行 15 = y 240..255，
            //      格列 6..9 = x 96..159）----
            //   与 [10] 同一个纪律：按 tb 自己钉住的页号门控，不划帧相位。
            //   两个计数合起来是"反转视频"（v31/㉘）的判据：
            //     C_TEXT 墨量：正常轮 > 0（黑字在卡白底上）；警示/故障轮 == 0
            //       （字已经变成白的，屏上再没有 C_TEXT）；
            //     块色墨量：正常轮 == 0（不反转）；警示/故障轮 > 0（整块变状态色）。
            if (de_o && (t_page == 3'd0) &&
                (dbg_x >= 12'd96) && (dbg_x < 12'd160) &&
                (dbg_y >= 12'd240) && (dbg_y < 12'd256)) begin
                if (lcd_rgb === C_TEXT)
                    sc_chip_t <= sc_chip_t + 1;
                if ((lcd_rgb === C_WARN) || (lcd_rgb === C_FAULT))
                    sc_chip_bg <= sc_chip_bg + 1;
            end

            // ---- [14] v36（㉜）：P8 结论那两格（格行 36 = y 576..591，
            //      格列 36/37 = x 576..607）----
            //   与 [10]/[11] 同一个纪律：按 tb 自己钉住的页号（P8 = 3'd7）门控。
            //   这条只证明"结论真的画到屏上了"；结论**是不是那两个字**由上面对
            //   p8_lab_ram 的格子读数负责 —— 两条判据分工，缺一条会漏一半。
            if (p8v_on && de_o && (t_page == 3'd7) &&
                (dbg_x >= 12'd576) && (dbg_x < 12'd608) &&
                (dbg_y >= 12'd576) && (dbg_y < 12'd592) && (lcd_rgb === C_TEXT))
                p8v_px <= p8v_px + 1;

            // ---- [15] v38（㉞）：P4 等效采样注记那一条带（格行 27 = y 432..447，
            //      格列 6..19 = x 96..319）----
            //   与 [10]/[11]/[14] 同一个纪律：按 tb 自己钉住的页号（P4 = 3'd3）门控，
            //   不划帧相位。这条只证明"注记真的画到屏上了"；注记**是哪 14 个字**
            //   由 check_p4note 的格子读数负责 —— 两条判据分工，缺一条会漏一半。
            if (p4n_on && de_o && (t_page == 3'd3) &&
                (dbg_x >= 12'd96) && (dbg_x < 12'd320) &&
                (dbg_y >= 12'd432) && (dbg_y < 12'd448) && (lcd_rgb === C_TEXT))
                p4n_px <= p4n_px + 1;

            // ---- [16] v39（㉟）：P1 两处口径注记的带（估/算/值 在格行 14 =
            //      y 224..239、格列 46..48 = x 736..783；本次上电起算 在格行 23 =
            //      y 368..383、格列 26..31 = x 416..511）----
            //   与 [10]/[11]/[14]/[15] 同一个纪律：按 tb 自己钉住的页号（P1 = 3'd0）
            //   门控。这一对只证明"两条注记真的画到屏上了"；**是哪几个字**由
            //   check_p1notes 的格子读数负责 —— 两条判据分工，缺一条会漏一半。
            if (p1n_on && de_o && (t_page == 3'd0) &&
                (dbg_x >= 12'd736) && (dbg_x < 12'd784) &&
                (dbg_y >= 12'd224) && (dbg_y < 12'd240) && (lcd_rgb === C_TEXT))
                p1n_px <= p1n_px + 1;
            if (p1n_on && de_o && (t_page == 3'd0) &&
                (dbg_x >= 12'd416) && (dbg_x < 12'd512) &&
                (dbg_y >= 12'd368) && (dbg_y < 12'd384) && (lcd_rgb === C_TEXT))
                p1q_px <= p1q_px + 1;

            // ---- [6] 导航底色采样（判据见声明处）----
            if (de_o && (dbg_x == 12'd8)) begin
                if (dbg_y == 12'd100) navbg0 <= lcd_rgb;
                if (dbg_y == 12'd140) navbg1 <= lcd_rgb;
                if (dbg_y == 12'd236) navbg2 <= lcd_rgb;
                if (dbg_y == 12'd332) navbg3 <= lcd_rgb;
                if (dbg_y == 12'd428) navbg4 <= lcd_rgb;
                if (dbg_y == 12'd580) navbg5 <= lcd_rgb;
            end
            if (dbg_sc0 < 3 && dbg_x == 12'd8 && dbg_y == 12'd100) begin
                dbg_sc0 <= dbg_sc0 + 1;
                $display("[dbg] t=%0t x=%0d y=%0d de_o=%b lcd=%h", $time, dbg_x, dbg_y, de_o, lcd_rgb);
            end
            if (dbg_sc5 < 3 && dbg_x == 12'd8 && dbg_y == 12'd580) begin
                dbg_sc5 <= dbg_sc5 + 1;
                $display("[dbg5] t=%0t x=%0d y=%0d de_o=%b lcd=%h", $time, dbg_x, dbg_y, de_o, lcd_rgb);
            end

            // ---- [17] v58：R8 / R9 两条版面回归（判据见声明处）----
            if (de_o && (t_page != 3'd0) && u_dut.c6_draw)
                c6_non_p1_px <= c6_non_p1_px + 1;
            if (de_o && (t_page == 3'd0) &&
                (dbg_x >= 12'd16) && (dbg_x < 12'd32) &&
                (dbg_y >= 12'd544) && (dbg_y < 12'd560) && (lcd_rgb === C_TEXT))
                set_nav_px <= set_nav_px + 1;

            // ---- de 下降沿 = 本行结束 ----
            if (de_d && !de) begin
                if (n_frame > 0 && n_de_row !== H_DISP) begin
                    errors <= errors + 1;
                    if (errors < 8)
                        $display("[FAIL] row %0d: de count = %0d, expected %0d",
                                 n_row, n_de_row, H_DISP);
                end
                if (n_de_row > max_de_row) max_de_row <= n_de_row;
                if (n_de_row < min_de_row) min_de_row <= n_de_row;
                n_de_row <= 0;

                if (pending_frame_end) begin
                    // 这一行就是本帧的第 600 行
                    if (n_frame > 0 && (n_row + 1) !== V_DISP) begin
                        errors <= errors + 1;
                        $display("[FAIL] frame %0d: rows = %0d, expected %0d",
                                 n_frame, n_row + 1, V_DISP);
                    end
                    // [5] 第一帧结束后判文字层对齐。文字出现在 y<=94，远早于帧尾
                    //     （y=599、x=1023），所以此刻读到的 min_x_* 已经是最终值。
                    if (n_frame == 0) begin
                        if (min_x_nav < 16 || min_x_nav > 19) begin
                            errors <= errors + 1;
                            $display("[FAIL] text align: nav '总览' leftmost text px = %0d, expected 16..19 (lab cell col 1)",
                                     min_x_nav);
                        end
                        if (min_x_lab < 96 || min_x_lab > 99) begin
                            errors <= errors + 1;
                            $display("[FAIL] text align: card label '输入频率' leftmost text px = %0d, expected 96..99 (lab cell col 6)",
                                     min_x_lab);
                        end
                    end

                    // ---- [6] 导航高亮：按**当前**页号判一次，再推进页号（0->5->7->0）----
                    //   为什么可以在这里判：采样点 y=100/140/236/580 都出现在帧末之前，
                    //   而页号只在帧末改 —— 所以这一帧采到的几个值必然同属一个页号。
                    //   连跑 5 帧覆盖 P1/P2/P3/P6/P8（帧 1->页1、2->页2、3->页5、4->页7、5->页0）。
                    //   ★ v15 起页号按 spec 页序：0=P1、1=P2、2=P3、5=P6、7=P8。
                    //     导航第 k 项 = 第 k 页，所以 y=100（第 0 项）在 P1 高亮、
                    //     y=140（第 1 项）在 P2 高亮、y=236（第 2 项）在 P3 高亮、
                    //     y=580（第 5 项）在 P6 高亮，而 P8 四项都不高亮（nav_idx 只到 5）。
                    //   ★ 采样 y 都落在导航项的文字**之外**（文字在 64..79 /
                    //     160..175 / 256..271 / 352..367 / 448..463），
                    //     读数不含字形叠加。
                    if (n_frame > 0 && !hold_page) begin
                        // 期望被选中的项号：P1->0、P2->1、P3->2、P4->3、P5->4、
                        // P6->5；P7/P8 一个都不高亮 —— 导航只有 6 项，
                        // 而 nav_sel 现在是 (nav_idx == page)，所以这是比较的必然结果。
                        case (t_page)
                            3'd0:    exp_sel = 3'd0;
                            3'd1:    exp_sel = 3'd1;
                            3'd2:    exp_sel = 3'd2;
                            3'd3:    exp_sel = 3'd3;
                            3'd4:    exp_sel = 3'd4;
                            3'd5:    exp_sel = 3'd5;
                            default: exp_sel = 3'd7;      // 3'd7 永不匹配
                        endcase

                        nav_err = 1'b0;
                        if ((navbg0 !== ((exp_sel == 3'd0) ? C_SEC : C_NAV)) ||
                            (navbg1 !== ((exp_sel == 3'd1) ? C_SEC : C_NAV)) ||
                            (navbg2 !== ((exp_sel == 3'd2) ? C_SEC : C_NAV)) ||
                            (navbg3 !== ((exp_sel == 3'd3) ? C_SEC : C_NAV)) ||
                            (navbg4 !== ((exp_sel == 3'd4) ? C_SEC : C_NAV)) ||
                            (navbg5 !== ((exp_sel == 3'd5) ? C_SEC : C_NAV)))
                            nav_err = 1'b1;

                        if (nav_err) begin
                            errors <= errors + 1;
                            $display("[FAIL] nav highlight on P%0d: item0..5 = %h %h %h %h %h %h, expect selected=%0d",
                                     t_page, navbg0, navbg1, navbg2, navbg3, navbg4, navbg5, exp_sel);
                        end else if (exp_sel == 3'd7) begin
                            $display("[ OK ] nav highlight on P%0d: no nav entry highlighted (all %h)",
                                     t_page, C_NAV);
                        end else begin
                            $display("[ OK ] nav highlight on P%0d follows page: item%0d=%h (selected), others %h",
                                     t_page, exp_sel, C_SEC, C_NAV);
                        end

                        t_page <= (t_page == 3'd0) ? 3'd1 :
                                  (t_page == 3'd1) ? 3'd2 :
                                  (t_page == 3'd2) ? 3'd3 :
                                  (t_page == 3'd3) ? 3'd4 :
                                  (t_page == 3'd4) ? 3'd5 :
                                  (t_page == 3'd5) ? 3'd6 :
                                  (t_page == 3'd6) ? 3'd7 : 3'd0;
                    end
                    n_frame           <= n_frame + 1;
                    n_row             <= 0;
                    pending_frame_end <= 1'b0;
                end else begin
                    n_row <= n_row + 1;
                end
            end

            // ---- 本帧攒满 614400 个有效像素 = 本帧结束 ----
            if (frame_done) begin
                pending_frame_end <= 1'b1;
                n_de_frame        <= 0;
            end
        end
    end

    initial begin
        $display("================================================================");
        $display(" tb_disp_engine : LCD timing + disp_engine skeleton checks");
        $display(" H_TOTAL=%0d  V_TOTAL=%0d  frame=%0d clocks  => %.3f Hz",
                 H_TOTAL, V_TOTAL, FRAME, 1.0e9 / (20.0 * FRAME));
        $display("================================================================");

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // 跑 7 整帧多一点（7 × 853,440 × 20 ns ≈ 120 ms）
        //   ★ 从 2 帧加到 4 帧是为了 [6]：导航高亮要按页各判一次，
        //     而页号只在帧末推进，所以最少要跑满 7 帧才能覆盖 P1/P2/P3/P4/P5/P6/P8。
        repeat (9 * FRAME + 200) @(posedge clk);

        // [1][2] 行/帧结构（用**实测**的 min/max，不再拿常数冒充测量值）
        if (n_frame < 8) begin
            errors = errors + 1;
            $display("[FAIL] only %0d frames completed, expected >= 8", n_frame);
        end else if (min_de_row !== H_DISP || max_de_row !== H_DISP) begin
            errors = errors + 1;
            $display("[FAIL] de/row min = %0d, max = %0d, expected both %0d",
                     min_de_row, max_de_row, H_DISP);
        end else begin
            $display("[ OK ] frames = %0d ; rows/frame = %0d ; de/row = %0d (min %0d, max %0d)",
                     n_frame, V_DISP, H_DISP, min_de_row, max_de_row);
            $display("       line and frame geometry match the ATK-7016 spec exactly");
        end

        // [5] 实测帧周期必须恰好等于 H_TOTAL*V_TOTAL 个像素时钟
        if (measured_period !== FRAME) begin
            errors = errors + 1;
            $display("[FAIL] measured frame period = %0d clocks, expected %0d (%.3f Hz vs %.3f Hz)",
                     measured_period, FRAME,
                     1.0e9 / (20.0 * measured_period), 1.0e9 / (20.0 * FRAME));
        end else begin
            $display("[ OK ] measured frame period = %0d clocks = %.3f Hz (exact)",
                     measured_period, 1.0e9 / (20.0 * FRAME));
        end

        // [3] 消隐期必须黑
        if (n_blank_rgb !== 0) begin
            errors = errors + 1;
            $display("[FAIL] %0d pixels drove a non-zero colour while de=0", n_blank_rgb);
        end else begin
            $display("[ OK ] blanking interval is strictly black (%0d violations)", n_blank_rgb);
        end

        // [17] v58：R8 卡 6 电平条不许漏到别的页
        if (c6_non_p1_px !== 0) begin
            errors = errors + 1;
            $display("[FAIL] 卡 6 电平条漏到非 P1 页：%0d px（c6_band 缺 page==0 门控）",
                     c6_non_p1_px);
        end else begin
            $display("[ OK ] 卡 6 电平条只在 P1 画（非 P1 页 0 px 越界）");
        end

        // [17] v58：R9 P1 导航「设置」必须画出来
        if (set_nav_px == 0) begin
            errors = errors + 1;
            $display("[FAIL] P1 导航「设置」一个像素都没画（行 21/34 的整行排除吃掉了列 1）");
        end else begin
            $display("[ OK ] P1 导航「设置」有墨 %0d px（行 34 列 1 未被整行排除）", set_nav_px);
        end

        // [4] 抽头活性：翻转 tap_angle 必须改变活性块颜色
        //   ★ 先冻结生成器，并多等一整帧，让 de 快照（q_* <= tap_*）跟上显式赋值。
        //   不冻结的话生成器每帧把 t_angle += 8192，会和这里的赋值抢同一个 reg，
        //   tap_xor 会一次翻掉好几个位，tap_alive（= bit7 ^ bit3）反而不变。
        tap_freeze = 1'b1;
        t_angle = 16'h0000;
        //   ⚠ `wait (cond)` 在条件**当前就成立**时会立刻返回 —— 所以每个赋值之后
        //   必须先过一拍再等，否则两次采样会落在同一拍上（还会读到端口尚未传播的旧值）。
        //   ★ v19 修正：采样点改用 dbg_x/dbg_y（与 lcd_rgb **同拍对齐**的坐标），
        //   不再用 pix_x/pix_y 反推。lcd_rgb 是两级寄存之后再寄存一拍的输出
        //   （px1←pix_x、px2←px1、compose 用 px2、lcd_rgb←compose），所以
        //   "看到 pix_x==960"这一拍，lcd_rgb 里装的是 x=958/959 那个像素。
        //   v19 之前活性灯占了 x>904 的 119 px，偏 3 px 照样落在灯里，这个量具偏差
        //   一直没暴露；v19 把灯收窄到 x>=960 之后，959 落到状态条底色（C_ACC）上，
        //   才把它照出来。**量具自己也有偏差：采样点必须与读数同源。**
        @(posedge clk);
        wait (de_o && (dbg_x == 12'd960) && (dbg_y == 12'd6));
        @(posedge clk);
        wait (de_o && (dbg_x == 12'd960) && (dbg_y == 12'd6));   // 再跨一帧让快照稳定
        alive_a = lcd_rgb;
        $display("[dbgTap] A: t_angle=%h tap_angle=%h q_angle=%h tap_xor=%h tap_alive=%b dbg=%0d,%0d de_o=%b lcd=%h",
                 t_angle, u_dut.tap_angle, u_dut.q_angle, u_dut.tap_xor, u_dut.tap_alive, dbg_x, dbg_y, de_o, lcd_rgb);
        //   ★ 只翻 bit7。tap_alive = tap_xor[7] ^ tap_xor[3]，
        //   原来写 16'h0088（同时翻 bit7 和 bit3）会让这个 XOR 保持不变 ——
        //   这是个奇偶性错误，测试永远不可能通过。2026-10-15 修正。
        t_angle = 16'h0080;
        @(posedge clk);
        wait (de_o && (dbg_x == 12'd960) && (dbg_y == 12'd6));   // 下一帧同一位置
        alive_b = lcd_rgb;
        $display("[dbgTap] B: t_angle=%h tap_angle=%h q_angle=%h tap_xor=%h tap_alive=%b dbg=%0d,%0d de_o=%b lcd=%h",
                 t_angle, u_dut.tap_angle, u_dut.q_angle, u_dut.tap_xor, u_dut.tap_alive, dbg_x, dbg_y, de_o, lcd_rgb);
        tap_freeze = 1'b0;
        if (alive_a === alive_b) begin
            errors = errors + 1;
            $display("[FAIL] tap-alive block ignored the tap change (%h -> %h)", alive_a, alive_b);
        end else begin
            $display("[ OK ] tap-alive block tracks the encoder tap (%h -> %h)", alive_a, alive_b);
        end

        // =====================================================================
        // [7] v19 绘制层：状态条三入口 / P6 危险区 / 模态二次确认对话框
        //   坐标全部抄自 disp/disp_engine.v 的 localparam（两处共同契约，改版面要改两处）。
        //   判据是**合成输出上的像素**，不是内部信号 —— 图层优先级、遮罩、字形门控
        //   这些问题只有看合成结果才能发现。
        // =====================================================================
        hold_page = 1'b1;              // 停掉帧末自动翻页，页号由本段自己钉住
        t_page    = 3'd5;              // P6
        dlg_tb    = 2'd0;
        repeat (2) @(posedge clk);

        $display("---- [7] 状态条右端三入口（任何页都在）----");
        $display("[dbg] p6 lab(4,6)=%h (13,29)=%h (18,29)=%h (22,21)=%h (22,39)=%h (34,21)=%h (34,49)=%h (14,30)=%h (19,29)=%h",
                 u_dut.u_p6_lab_ram.mem[{6'd4, 6'd6}],  u_dut.u_p6_lab_ram.mem[{6'd13, 6'd29}],
                 u_dut.u_p6_lab_ram.mem[{6'd18, 6'd29}], u_dut.u_p6_lab_ram.mem[{6'd22, 6'd21}],
                 u_dut.u_p6_lab_ram.mem[{6'd22, 6'd39}], u_dut.u_p6_lab_ram.mem[{6'd34, 6'd21}],
                 u_dut.u_p6_lab_ram.mem[{6'd34, 6'd49}], u_dut.u_p6_lab_ram.mem[{6'd14, 6'd30}],
                 u_dut.u_p6_lab_ram.mem[{6'd19, 6'd29}]);
        //   ● 圆点 = 触摸链路六态色；▲ = 告警色；⚙ 齿环+十字 + 1 px 方框 = C_CARD。
        //   判据直接引被测件内部的同名列（组合信号，与像素同拍），避免测试台再抄一份色号。
        expect_px(12'd768, 12'd12, u_dut.sig_col,   "sbar S");
        expect_px(12'd832, 12'd12, u_dut.alert_col, "sbar ALM");
        expect_px(12'd864, 12'd12, C_CARD,          "sbar SYS box edge");
        expect_px(12'd896, 12'd12, C_CARD,          "sbar SYS gear");
        //   活性灯搬家后：x=960 上是心跳块（上半），不再是状态条底色
        expect_px(12'd960, 12'd12, u_dut.tch_lamp_col, "tch lamp band");

        $display("---- [7] P6 危险区（对话框关闭）----");
        //   关闭态用**像素**判"对话框没露头"：遮罩色与红边框都不该在。
        //   （不能用"格行 13 没有文字像素"判 —— 对话框的标题/寄存器号用的正是 P6
        //    自己放标签与数值的那三行 13/18/22，关闭态那里是页面自己的字与数值。）
        expect_px(12'd100, 12'd300, C_BG,    "no dialog mask when closed");
        expect_px(12'd232, 12'd300, C_BG,    "no dialog border when closed");
        //   ★ v42（㊴）：危险区里现在是**两颗**对称按钮（x 180..591 与 x 608..1019，
        //     各 412 px，间隔 16 px）。"区底色"取样点不能再落在按钮上 —— 旧的
        //     (700,530) 现在正是第 2 颗按钮的脸，挪到两颗之间的缝 x 592..607。
        expect_px(12'd600, 12'd552, C_CARD,  "dz zone fill（两颗按钮之间的缝）");
        expect_px(12'd140, 12'd550, C_FAULT, "dz tri");
        expect_px(12'd180, 12'd560, C_FAULT, "dz btn1 L edge");
        expect_px(12'd400, 12'd560, C_BG,    "dz btn1 face");
        expect_px(12'd591, 12'd560, C_FAULT, "dz btn1 R edge");
        expect_px(12'd608, 12'd560, C_FAULT, "dz btn2 L edge");
        expect_px(12'd800, 12'd560, C_BG,    "dz btn2 face");
        expect_px(12'd1019, 12'd560, C_FAULT, "dz btn2 R edge");
        expect_px(12'd80,  12'd599, C_FAULT, "dz zone bottom");
        //   ★ v33（㉝）：危险区 80 → 96 px（spec 4.4 的字面值）。上面那组判据
        //     在旧几何下**全都通过**，所以必须补下面这些"只有新几何才对"的点，
        //     否则这条改动没有任何回归能力：
        expect_px    (12'd700, 12'd504, C_FAULT, "dz zone 上沿 @504（新）");
        expect_not_px(12'd700, 12'd503, C_FAULT, "dz zone 上一行 503 不是故障色");
        //   ★ v41（㊳）：5 x 88 = 440 ⇒ 第 5 项数值墨迹落 440..481，504 之上 23 px
        //     全是空白（旧版面第 4 项数值格是 y 448..511，字形到 500，504..511 是空档）。
        //     这一条同时钉住"重叠带里没有墨迹被吃掉"。
        expect_px    (12'd700, 12'd508, C_CARD,  "dz 与数值带之间（508）是危险区底色");
        expect_not_px(12'd700, 12'd508, C_TEXT,  "危险区上沿附近没有文字被盖住");
        expect_not_px(12'd700, 12'd490, C_TEXT,  "第 5 项数值墨迹止于 481，不会伸进危险区");
        //   按钮框 y 520..583（64 px，中心 552 = 危险区中心）：上下留 16 px。
        expect_px    (12'd192, 12'd520, C_FAULT, "dz btn 上沿 @520（新）");
        expect_px    (12'd192, 12'd583, C_FAULT, "dz btn 下沿 @583（新）");
        expect_px    (12'd192, 12'd519, C_CARD,  "dz btn 上一行 519 是区底色");
        expect_px    (12'd192, 12'd584, C_CARD,  "dz btn 下一行 584 是区底色");
        //   警示三角 y 532..572（中心 552）：573 起回到区底色。
        expect_px    (12'd140, 12'd532, C_FAULT, "dz tri 尖顶 @532（新）");
        expect_px    (12'd140, 12'd572, C_FAULT, "dz tri 底边 @572（新）");
        expect_px    (12'd140, 12'd573, C_CARD,  "dz tri 下方 573 是区底色");
        expect_px    (12'd140, 12'd531, C_CARD,  "dz tri 上方 531 是区底色");
        $display("[scan] 帧边界等待（用 n_frame 变化判，不信 frame_done 的相位）");
        //   文字扫描改用 [5] 那种"整帧累加"的量具：等到帧边界 → 清零 → 开扫描相位
        //   → 再等一个帧边界 → 关相位读数。task + wait/while 的写法实测会在行内
        //   提前退出（连"一定存在"的 P1 导航文字都数到 0），不可用。
        $display("[scan] before wait1 t=%0t n_frame=%0d", $time, n_frame);
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        $display("[scan] after wait1  t=%0t n_frame=%0d", $time, n_frame);
        sc_dz_lbl = 0; sc_dlg_t0 = 0; sc_p6r3 = 0; sc_p6r4 = 0;
        sc_p6r5l = 0; sc_p6r5v = 0; sc_p6r3x = 0; sc_dz_lbl2 = 0;
        $display("[scan] closed scan start t=%0t n_frame=%0d", $time, n_frame);
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        $display("[scan] after wait2 t=%0t n_frame=%0d", $time, n_frame);
        $display("[dbg] 文字扫描：P6 第1项标题带=%0d 导航行4=%0d 危险区行34=%0d",
                 sc_p6r3, sc_p6r4, sc_dz_lbl);
        $display("[dbg] P6 第 5 项（行带 4）：标题墨迹=%0d px 数值墨迹=%0d px",
                 sc_p6r5l, sc_p6r5v);
        //   ★ v41（㊳）：版面改动的**证伪判据** —— 旧自然格行 3 的下半（y 52..62）
        //     必须一滴墨都没有。这一条在"标题还写在 lab 行 3"的版本里必然红（虚拟映射
        //     只覆盖 y >= 64，行 3 的自然位置会漏在第一行带上方）。窗口下沿取 52 的理由
        //     见扫描处（标题带复选框 y 36..51 是 C_TEXT）。
        if (sc_p6r3x == 0) $display("[ OK ] P6 首行标题上方（旧自然格行 3，y 52..62）无残留墨迹");
        else begin errors = errors + 1;
              $display("[FAIL] P6 首行标题上方有残留墨迹 %0d px（标题 RAM 行应从 4 起）", sc_p6r3x); end
        if (sc_dz_lbl > 0) $display("[ OK ] dz 按钮 1 文字在屏上（%0d px）", sc_dz_lbl);
        else begin errors = errors + 1; $display("[FAIL] dz 按钮 1 文字没画出来（格行 34 列 21..26）"); end
        //   ★ v42（㊴）：第 2 颗按钮的标签（"恢复默认"）。它与第 1 颗同排、同色，
        //     但住在另一个窗口里 —— 这一条证明"两颗按钮的标签都真的上了屏"。
        if (sc_dz_lbl2 > 0) $display("[ OK ] dz 按钮 2 文字在屏上（%0d px）", sc_dz_lbl2);
        else begin errors = errors + 1; $display("[FAIL] dz 按钮 2 文字没画出来（格行 34 列 49..52）"); end
        //   ★ v41（㊳）：这一条是本轮**版面改动**的直接判据 —— 88 px 行带 4
        //     （y 416..503）里必须同时有标题墨迹（带内 v 1..14）与数值墨迹
        //     （带内 v 24..65）。照旧版面（4 x 128）这两个窗口里只有空白。
        if (sc_p6r5l > 0) $display("[ OK ] P6 第 5 项标题「增益S」在屏上（%0d px，行带 4 的 y 417..430）", sc_p6r5l);
        else begin errors = errors + 1;
              $display("[FAIL] P6 第 5 项标题没画出来（行带 4 的 y 417..430，0 px）"); end
        if (sc_p6r5v > 0) $display("[ OK ] P6 第 5 项数值在屏上（%0d px，行带 4 的 y 440..481）", sc_p6r5v);
        else begin errors = errors + 1;
              $display("[FAIL] P6 第 5 项数值没画出来（行带 4 的 y 440..481，0 px）"); end
        //   对话框文字住在 P6 lab 的格行 13/18/22（v41 从 15/17/21 迁来）——
        //   与 P6 自己的标签/数值同行，所以关闭态这里必然有字（那是页面自己的），
        //   只能打信息不能当判据。
        $display("[info] 关闭态格行 13 文字像素 = %0d（P6 自己的标签/数值）", sc_dlg_t0);

        $display("---- [7] 模态二次确认（询问中）----");
        dlg_tb = 2'd1;
        repeat (2) @(posedge clk);
        expect_px(12'd100, 12'd12,  C_DIM,   "mask over sbar");
        expect_px(12'd100, 12'd104, C_DIM,   "mask over page text");
        expect_px(12'd100, 12'd300, C_DIM,   "mask outside box");
        expect_px(12'd232, 12'd300, C_FAULT, "dlg border");
        expect_px(12'd500, 12'd300, C_CARD,  "dlg face");
        expect_px(12'd272, 12'd352, C_GRID,  "dlg NO edge");
        expect_px(12'd380, 12'd352, C_BG,    "dlg NO face");
        expect_px(12'd600, 12'd352, C_BG,    "dlg YES face");
        //   ★ v34（㊲）：询问态下危险区按钮**仍然可见** —— 它是这次二次确认的主体。
        //     旧版本这里读到 C_DIM：遮罩把 y 520..583 整片压暗，于是 dz_col 里
        //     "ui_dlg != 0 → 浅红 FBD9D6" 那条分支**从来没有上过屏**（U-40.8 第 3 条
        //     写的那句"进询问态后按钮底色变浅"是死像素）。下面两条是同一次采样的
        //     正反两面：按钮上看见它自己的脸，按钮外那片危险区照旧被压暗。
        expect_px(12'd300, 12'd552, 24'hFBD9D6, "dz btn visible under mask");
        expect_px(12'd100, 12'd552, C_DIM,      "dz zone outside btn still masked");
        $display("[scan] 模态帧边界等待");
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        sc_dlg_t1 = 0; sc_dlg_r1 = 0; sc_dz_lbl1 = 0; sc_dlg_k1t = 0; sc_dlg_k1b = 0;
        sc_dlg_k1x = 0;
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        if (sc_dlg_t1 > 0) $display("[ OK ] 对话框标题在屏上（%0d px）", sc_dlg_t1);
        else begin errors = errors + 1; $display("[FAIL] 对话框标题没画出来（格行 13）"); end
        if (sc_dlg_r1 > 0) $display("[ OK ] 对话框寄存器号一行在屏上（%0d px）", sc_dlg_r1);
        else begin errors = errors + 1; $display("[FAIL] 对话框寄存器号没画出来（格行 18）"); end
        //   ★ v34（㊲）：同一个标签窗口、询问态下再数一次。按钮被压暗时这里必然是 0。
        if (sc_dz_lbl1 > 0) $display("[ OK ] 询问态下按钮标签仍在屏上（%0d px）", sc_dz_lbl1);
        else begin errors = errors + 1;
              $display("[FAIL] 询问态下按钮标签被遮罩吃掉（格行 34 列 21..26，0 px）"); end
        //   ★ v42（㊴）：同一次询问里，**恢复默认**那套的行（14/19）必须一个字都没有 ——
        //     两套对话框共用同一张版面，只有 dlg_title_row/dlg_body_row 由 ui_dlg_kind
        //     选行。这条证伪点抓的就是"选行没生效（两套字叠在一起）"。
        if ((sc_dlg_k1t == 0) && (sc_dlg_k1b == 0) && (sc_dlg_k1x == 0))
            $display("[ OK ] 询问态（故障）下恢复默认的行 14/19 无墨（0/0/0 px）");
        else begin errors = errors + 1;
              $display("[FAIL] 询问态（故障）下恢复默认的行 14/19 有墨（%0d/%0d/%0d px）",
                       sc_dlg_k1t, sc_dlg_k1b, sc_dlg_k1x); end

        $display("---- [7] 模态二次确认（确认写入中）----");
        dlg_tb = 2'd2;
        repeat (2) @(posedge clk);
        expect_px(12'd380, 12'd352, C_BG,       "dlg NO face unchanged");
        expect_px(12'd600, 12'd352, 24'hFBD9D6, "dlg YES face busy");
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        sc_dlg_t2 = 0;
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        if (sc_dlg_t2 > 0) $display("[ OK ] 忙碌态对话框标题仍在（%0d px）", sc_dlg_t2);
        else begin errors = errors + 1; $display("[FAIL] 忙碌态对话框标题没了（格行 13）"); end

        dlg_tb = 2'd0;
        hold_page = 1'b0;
        t_page   = 3'd0;

        // =====================================================================
        // [8] v20 绘制层：标题带主操作按钮（P1「标定」/ P4「EXPAND」）+ P2/P3 页内 Tab
        //   坐标抄自 disp/disp_engine.v 的 TBTN_* / TAB_*（两处共同契约）。
        //   ★ 同一个按钮矩形在 P1 是「标定」、在 P4 是「EXPAND」：文字来自各页 lab 平面，
        //     白底+强调色描边与命中编号（hit_test 15 号）跨页共用，策略层按 page 分派。
        //   ★ Tab 栏**不在 hit_test 表里**（矩形压在 P1 卡片 8/9 上、而它不认识页号），
        //     所以这里只验"画出来了 + 选中态配色"，命中判定由 tb_hit_test 的 4c 段负责。
        //   ★ 反向判据同样重要：P2 上不该有标题带按钮、P4 上不该有 Tab 栏
        //     （两者都由 page 门控，写错页就会在别的页面上漏出来）。
        // =====================================================================
        $display("---- [8] 标题带主操作按钮（P1 标定）----");
        hold_page = 1'b1;              // 页号由本段钉住（帧末自动翻页停）
        t_page    = 3'd0;              // P1
        repeat (2) @(posedge clk);
        expect_px(12'd660, 12'd44, C_ACC,  "P1 btn L edge");
        expect_px(12'd819, 12'd28, C_ACC,  "P1 btn top-R edge");
        expect_px(12'd700, 12'd44, C_CARD, "P1 btn face");
        expect_px(12'd820, 12'd44, C_BG,   "P1 btn right outside");
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        sc_btn_p1 = 0;
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        if (sc_btn_p1 > 0) $display("[ OK ] P1 标题带按钮文字在屏上（%0d px）", sc_btn_p1);
        else begin errors = errors + 1; $display("[FAIL] P1 标题带按钮的文字没画出来"); end

        $display("---- [8] 标题带主操作按钮（P4 展开）----");
        t_page = 3'd3;                 // P4
        repeat (2) @(posedge clk);
        expect_px(12'd660, 12'd44, C_ACC,  "P4 btn L edge");
        expect_px(12'd700, 12'd44, C_CARD, "P4 btn face");
        expect_px(12'd96,  12'd116, C_BG,  "P4 has no tab bar");
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        sc_btn_p4 = 0;
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        if (sc_btn_p4 > 0) $display("[ OK ] P4 展开 的文字在屏上（%0d px）", sc_btn_p4);
        else begin errors = errors + 1; $display("[FAIL] P4 展开 的文字没画出来"); end
        //   ★ v43（㊵）：不只判"有墨"，把**字的身份**钉住 —— 「展开」= lab 码 181/182
        //     （51 ASCII + 序号 130/131；见 tools/cn_glyphs.py 的 CN_ORDER 末尾）。
        //     只判有墨的话，退回 ASCII `EXPAND` 也照样绿（那正是 v20..v42 的状态）。
        if ((u_dut.u_p4_lab_ram.mem[{6'd2, 6'd45}] === 8'd181) &&
            (u_dut.u_p4_lab_ram.mem[{6'd2, 6'd46}] === 8'd182))
            $display("[ OK ] P4 标题带按钮写的是「展开」（码 181/182，spec 4.6 字面）");
        else begin errors = errors + 1;
              $display("[FAIL] P4 标题带按钮的字符码 = %0d/%0d（want 181/182）",
                       u_dut.u_p4_lab_ram.mem[{6'd2, 6'd45}],
                       u_dut.u_p4_lab_ram.mem[{6'd2, 6'd46}]); end

        $display("---- [8] P2/P3 页内 Tab 栏 ----");
        t_page = 3'd1;                 // P2：左边「模拟」选中
        repeat (2) @(posedge clk);
        expect_px(12'd96,  12'd116, C_ACC,  "P2 tab0 L edge (selected)");
        expect_px(12'd150, 12'd116, C_CARD, "P2 tab0 face (selected)");
        expect_px(12'd295, 12'd116, C_ACC,  "P2 tab0 R edge (selected)");
        expect_px(12'd300, 12'd116, C_GRID, "P2 tab1 L edge (idle)");
        expect_px(12'd350, 12'd116, C_NAV,  "P2 tab1 face (idle)");
        expect_px(12'd297, 12'd116, C_BG,   "P2 tab gap");
        expect_px(12'd700, 12'd44,  C_BG,   "P2 has no title button");
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        sc_tab_p2 = 0;
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        if (sc_tab_p2 > 0) $display("[ OK ] P2 Tab 栏文字在屏上（%0d px）", sc_tab_p2);
        else begin errors = errors + 1; $display("[FAIL] P2 Tab 栏的 模拟/XY 文字没画出来"); end
        //   ★ v43（㊵）：Tab 1 的标签是「模拟」= lab 码 179/180（序号 128/129）。
        //     P2 与 P3 各有一份 lab 平面，两页都要判（同一条版面在生成器里写了两遍）。
        if ((u_dut.u_p2_lab_ram.mem[{6'd7, 6'd11}] === 8'd179) &&
            (u_dut.u_p2_lab_ram.mem[{6'd7, 6'd12}] === 8'd180) &&
            (u_dut.u_p3_lab_ram.mem[{6'd7, 6'd11}] === 8'd179) &&
            (u_dut.u_p3_lab_ram.mem[{6'd7, 6'd12}] === 8'd180))
            $display("[ OK ] P2/P3 的 Tab 1 写的是「模拟」（码 179/180，spec 4.4 字面）");
        else begin errors = errors + 1;
              $display("[FAIL] Tab 1 字符码 P2=%0d/%0d P3=%0d/%0d（want 179/180）",
                       u_dut.u_p2_lab_ram.mem[{6'd7, 6'd11}], u_dut.u_p2_lab_ram.mem[{6'd7, 6'd12}],
                       u_dut.u_p3_lab_ram.mem[{6'd7, 6'd11}], u_dut.u_p3_lab_ram.mem[{6'd7, 6'd12}]); end

        t_page = 3'd2;                 // P3：右边 XY 选中
        repeat (2) @(posedge clk);
        expect_px(12'd96,  12'd116, C_GRID, "P3 tab0 L edge (idle)");
        expect_px(12'd150, 12'd116, C_NAV,  "P3 tab0 face (idle)");
        expect_px(12'd295, 12'd116, C_GRID, "P3 tab0 R edge (idle)");
        expect_px(12'd300, 12'd116, C_ACC,  "P3 tab1 L edge (selected)");
        expect_px(12'd350, 12'd116, C_CARD, "P3 tab1 face (selected)");

        hold_page = 1'b0;
        t_page    = 3'd0;

        // =====================================================================
        // [9] v22 绘制层：倍频编辑面板（spec 4.5 / 6.2 / 6.3 / 6.5）
        //   坐标抄自 disp/disp_engine.v 的 PNL_*/MNS_*/PLS_*/SLD_*/CCL_*/APL_*/BCK_*
        //   （与 disp/ui_panel.v 是两处共同契约）。这里只验"这一笔画出来没有、
        //   颜色对不对"；手势语义（点按/长按/拖拽/取消/应用/撤销）由
        //   disp/tb_ui_panel.v 负责，写寄存器链路由 disp/tb_ui_edit.v 负责。
        //   ★ 页号在整段里钉死在 P1（面板只属于 P1）：不钉的话，DUT 的自由翻页
        //     会让"面板文字"扫描扫到别的页 ⇒ 假报 0 px（和 [8] 同一个理由）。
        //   ★ 反向判据同样重要：面板关着时这几块图形一格都不许出现。
        // =====================================================================
        hold_page = 1'b1;
        t_page    = 3'd0;                    // P1
        pnl_idx_tb = 3'd3;                   // 档 3 = ×16（选中区间 x = 432..495）

        $display("---- [9] 编辑面板：关着时什么都不画 ----");
        pnl_on_tb    = 1'b0;
        pnl_prog_tb  = 6'd0;
        pnl_press_tb = 4'd0;
        pnl_pend_tb  = 1'b0;
        pnl_undo_tb  = 1'b0;
        repeat (2) @(posedge clk);
        expect_not_px(12'd96,  12'd400, C_ACC,      "panel off: 无面板左边框");
        expect_not_px(12'd500, 12'd320, C_ACC,      "panel off: 无面板上边框");
        expect_not_px(12'd190, 12'd496, 24'hDCE9F5, "panel off: 没有 [−] 按钮按下态");
        //   v34（㊲）：这条从 `expect_not_px(...,C_TEXT,...)` 换成**分层信号判据** ——
        //   `C_TEXT` 是页面文字与面板符号共用的色，"合成像素不是 C_TEXT"证明不了
        //   面板不在（P1 数值层每帧被 val_format 重写 ⇒ 那一点逐帧翻墨）。
        //   详见 `expect_pnl_layer` 上面的注释。
        expect_pnl_layer(12'd192, 12'd496, 1'b0, "panel off: [−] 符号处面板层不使能");
        expect_not_px(12'd440, 12'd480, C_SEC,      "panel off: 滑条选中档不出现");
        expect_not_px(12'd600, 12'd480, C_TRACK,    "panel off: 滑条轨道不出现");
        expect_not_px(12'd528, 12'd535, 24'hFFF3CD, "panel off: 没有待应用黄");
        expect_not_px(12'd800, 12'd535, 24'hEDF1F6, "panel off: 没有 BACK 压暗底");

        $display("---- [9] 编辑面板：开面板（底 + 描边 + 两个步进按钮）----");
        pnl_on_tb = 1'b1;
        repeat (2) @(posedge clk);
        expect_px(12'd96,  12'd400, C_ACC,  "面板左边框");
        expect_px(12'd927, 12'd400, C_ACC,  "面板右边框");
        expect_px(12'd500, 12'd320, C_ACC,  "面板上边框");
        expect_px(12'd500, 12'd591, C_ACC,  "面板下边框");
        //   v44（㊶）起面板里多了"待应用值"数值窗（x 330..572, y 342..442）与字段切换
        //   按钮（x 240..304, y 344..408）⇒ "面板底色"要挑一处真正空着的地方取；
        //   (500,400) 现在落在数值窗的大字段数字上（白墨），改判在 (150,400)。
        expect_px(12'd150, 12'd400, C_BG,   "面板底色");
        expect_px(12'd95,  12'd400, C_BG,   "面板外（左）");
        expect_px(12'd190, 12'd470, C_CARD, "[−] 按钮白底");
        expect_px(12'd160, 12'd496, C_GRID, "[−] 按钮描边");
        expect_px(12'd830, 12'd470, C_CARD, "[+] 按钮白底");
        expect_px(12'd863, 12'd496, C_GRID, "[+] 按钮描边（右边框在 863）");
        //   符号是图形画出来的（16 px 字格放不正），中心必须正好在按钮中心
        expect_px(12'd192, 12'd496, C_TEXT, "[−] 横杠中心");
        //   证伪点（v34/㊲）：同一个探针在面板开着时**必须**读到 1，否则上面那条
        //   "关着读到 0"什么也证明不了（探针接错线也永远是 0）。
        expect_pnl_layer(12'd192, 12'd496, 1'b1, "panel on: [−] 符号处面板层使能（证伪点）");
        expect_px(12'd170, 12'd496, C_CARD, "[−] 横杠左侧留白（符号不是整块）");
        expect_px(12'd832, 12'd496, C_TEXT, "[+] 十字中心");
        expect_px(12'd832, 12'd485, C_TEXT, "[+] 竖杠");
        expect_px(12'd855, 12'd496, C_CARD, "[+] 十字右侧留白");
        //   spec 4.5：面板只占下半屏，上半屏波形继续刷新 ⇒ 面板外不许压暗
        expect_px(12'd500, 12'd200, C_CARD, "面板外上半屏不压暗");

        $display("---- [9] 编辑面板：滑条（8 档 + 轨道 + 选中档 + 游标）----");
        expect_px(12'd600, 12'd480, C_TRACK, "滑条轨道（未选中段）");
        expect_px(12'd440, 12'd480, C_SEC,   "选中档 3 的区间");
        expect_px(12'd464, 12'd480, C_ACC,   "当前档游标");
        expect_px(12'd528, 12'd480, C_GRID,  "档位刻度（选中段外）");

        $display("---- [9] 编辑面板：CANCEL / APPLY / BACK ----");
        //   描边取 y=552（x 在文字左边）；底色必须取 y=535 —— 三个按钮的标签
        //   占 lab 格行 34（y 544..559），y=552 会正好读到字（1f2d3d = C_TEXT）。
        expect_px(12'd176, 12'd552, C_GRID,  "CANCEL 描边");
        expect_px(12'd250, 12'd535, C_CARD,  "CANCEL 白底");
        expect_px(12'd448, 12'd552, C_GRID,  "APPLY 描边（无待应用值）");
        expect_px(12'd528, 12'd535, C_CARD,  "APPLY 白底（无待应用值）");
        expect_px(12'd720, 12'd552, 24'hC8D2DE, "BACK 描边（无上一次值：压暗）");
        expect_px(12'd800, 12'd535, 24'hEDF1F6, "BACK 白底（无上一次值：压暗）");

        //   "待应用"（黄底 + 强调色描边）与"有上一次值"（恢复正常配色）
        pnl_pend_tb = 1'b1;
        pnl_undo_tb = 1'b1;
        repeat (2) @(posedge clk);
        expect_px(12'd448, 12'd552, C_ACC,      "APPLY 描边转强调色（待应用）");
        expect_px(12'd528, 12'd535, 24'hFFF3CD, "APPLY 变浅黄（待应用）");
        expect_px(12'd720, 12'd552, C_GRID,     "BACK 描边（有上一次值）");
        expect_px(12'd800, 12'd535, C_CARD,     "BACK 白底（有上一次值）");
        pnl_pend_tb = 1'b0;
        pnl_undo_tb = 1'b0;

        $display("---- [9] 编辑面板：按下态 + 长按进度真圆环 ----");
        pnl_press_tb = 4'd1;                 // 按住 [−]（P_MNS）
        pnl_prog_tb  = 6'd0;
        repeat (2) @(posedge clk);
        expect_px(12'd160, 12'd496, C_ACC,      "[−] 按下：描边转强调色");
        expect_px(12'd190, 12'd470, 24'hDCE9F5, "[−] 按下：整块变浅蓝");
        // 真圆环（v29/㉕）：环带 26..30 px、圆心 (192,496)。四个方向的采样点都落在
        //   带内（距离 27.5~28.5）：12 点 (192,468) 扇区 0、3 点 (220,496) 扇区 15、
        //   6 点 (192,524) 扇区 31、9 点 (164,496) 扇区 47。
        expect_px(12'd192, 12'd468, 24'hDCE9F5, "进度未开始：12 点方向环带留白");
        expect_px(12'd220, 12'd496, 24'hDCE9F5, "进度未开始：3 点方向环带留白");
        expect_not_px(12'd192, 12'd468, C_ACC,  "进度未开始：环带不是强调色");
        pnl_prog_tb = 6'd1;                  // 只画第 1 格（扇区 0 = 12 点方向）
        repeat (2) @(posedge clk);
        expect_px(12'd192, 12'd468, C_ACC,      "进度 1/63：12 点方向亮");
        expect_px(12'd220, 12'd496, 24'hDCE9F5, "进度 1/63：3 点方向未亮");
        pnl_prog_tb = 6'd17;                 // 扇区 0..16 亮 ⇒ 刚过 3 点方向
        repeat (2) @(posedge clk);
        expect_px(12'd220, 12'd496, C_ACC,      "进度 17/63：3 点方向亮");
        expect_px(12'd192, 12'd524, 24'hDCE9F5, "进度 17/63：6 点方向未亮");
        pnl_prog_tb = 6'd63;                 // 满格：最后一级补齐整圈
        repeat (2) @(posedge clk);
        expect_px(12'd192, 12'd524, C_ACC,      "进度满格：6 点方向亮");
        expect_px(12'd164, 12'd496, C_ACC,      "进度满格：9 点方向亮");
        expect_px(12'd200, 12'd480, 24'hDCE9F5, "环内（距离 17.7）不是环：留白");
        pnl_prog_tb  = 6'd0;
        pnl_press_tb = 4'd0;
        repeat (2) @(posedge clk);

        //   面板自己的文字（格行 21 标题 + 格行 34 三个按钮标签）
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        sc_pnl_t = 0;
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        if (sc_pnl_t > 0) $display("[ OK ] 面板标题与按钮文字在屏上（%0d px）", sc_pnl_t);
        else begin errors = errors + 1; $display("[FAIL] 面板文字没画出来"); end

        //   反向：面板收起后，同一块区域的文字必须消失（防止"关不掉"）
        pnl_on_tb = 1'b0;
        repeat (2) @(posedge clk);
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        sc_pnl_t = 0;
        f0 = n_frame; while (n_frame == f0) @(posedge clk);
        if (sc_pnl_t == 0) $display("[ OK ] 面板收起后文字消失");
        else begin errors = errors + 1;
                   $display("[FAIL] 面板收起后仍有 %0d px 文字", sc_pnl_t); end

        // =====================================================================
        // [9b] v44（㊶）：字段切换按钮（×倍频 ⇄ ÷分频）+ 面板数值窗
        //   ㊶ 之前面板只改倍频（文件头自己写着"分频不动"）；现在同一套控件
        //   （[−]/[+]、滑条、长按、键盘）作用于 FLD 按钮选中的那个字段。
        //   这一段钉两件事：
        //     ① 图标本身：× 是两条 31×31 对角线、÷ 是 25×3 横杠 + 上下两点 ——
        //        两者都**不是实心块**（正上方必须留白），且面板关着时面板层不使能；
        //     ② 数值窗：同一组 3 个 48×80 大字段既显示待应用倍频也显示待应用分频，
        //        判据用**位数变了墨量就变**（×256 > ×64 > ÷7），不写死像素数。
        // =====================================================================
        $display("---- [9b] v44（㊶）：字段切换按钮 FLD + 数值窗 ----");
        pnl_on_tb    = 1'b0;
        pnl_fld_tb   = 1'b0;
        pnl_inter_tb = 10'd64;
        pnl_didx_tb  = 3'd0;
        repeat (2) @(posedge clk);
        expect_pnl_layer(12'd272, 12'd376, 1'b0, "panel off: FLD 处面板层不使能");

        pnl_on_tb = 1'b1;
        repeat (2) @(posedge clk);
        expect_px(12'd240, 12'd376, C_GRID, "FLD 描边（未按下）");
        expect_px(12'd250, 12'd380, C_CARD, "FLD 白底");
        expect_px(12'd272, 12'd376, C_TEXT, "× 图标：中心（两条对角线交点）");
        expect_px(12'd280, 12'd384, C_TEXT, "× 图标：右下斜线");
        expect_px(12'd280, 12'd368, C_TEXT, "× 图标：右上斜线");
        expect_px(12'd272, 12'd360, C_CARD, "× 图标：正上方留白（不是实心块）");
        expect_pnl_layer(12'd272, 12'd376, 1'b1, "panel on: FLD 处面板层使能（证伪点）");

        //   切到 ÷ 字段 —— 这一条就是"字段切换按钮"的全部意义：
        pnl_fld_tb = 1'b1;
        repeat (2) @(posedge clk);
        expect_px(12'd272, 12'd376, C_TEXT, "÷ 图标：横杠中心");
        expect_px(12'd272, 12'd367, C_TEXT, "÷ 图标：上点");
        expect_px(12'd272, 12'd384, C_TEXT, "÷ 图标：下点");
        expect_px(12'd290, 12'd376, C_CARD, "÷ 图标：横杠右侧留白（杠不过半）");
        expect_px(12'd272, 12'd360, C_CARD, "÷ 图标：正上方留白");
        expect_px(12'd280, 12'd384, C_CARD, "÷ 图标：旧 × 的右下斜线已消失");

        //   按下态：与 [−]/[+] 同一套观感（描边/图形转强调色、底变浅蓝）
        pnl_press_tb = 4'd8;
        repeat (2) @(posedge clk);
        expect_px(12'd240, 12'd376, C_ACC,      "FLD 按下：描边转强调色");
        expect_px(12'd250, 12'd380, 24'hDCE9F5, "FLD 按下：整块变浅蓝");
        expect_px(12'd272, 12'd376, C_ACC,      "FLD 按下：图标转强调色");
        pnl_press_tb = 4'd0;
        repeat (2) @(posedge clk);

        // ---- 数值窗：位数换了，窗口不换（同一组大字段）----
        pnl_fld_tb   = 1'b0;
        pnl_inter_tb = 10'd256;                  // 三位数
        pnl_didx_tb  = 3'd0;
        wait_frames(1); sc_win_t = 0; wait_frames(1); ink_v3 = sc_win_t;
        pnl_inter_tb = 10'd64;                   // 两位数
        wait_frames(1); sc_win_t = 0; wait_frames(1); ink_v2 = sc_win_t;
        pnl_fld_tb   = 1'b1;                     // ÷ 字段、一位数
        pnl_didx_tb  = 3'd6;                     // 码 6 = ÷7
        wait_frames(1); sc_win_t = 0; wait_frames(1); ink_v1 = sc_win_t;
        $display("[scan] 数值窗墨量：×256 = %0d，×64 = %0d，÷7 = %0d",
                 ink_v3, ink_v2, ink_v1);
        if ((ink_v3 > ink_v2) && (ink_v2 > ink_v1))
            $display("[ OK ] 数值窗跟着字段换内容（%0d > %0d > %0d）", ink_v3, ink_v2, ink_v1);
        else begin errors = errors + 1;
                   $display("[FAIL] 数值窗墨量不满足 ×256 > ×64 > ÷7：%0d / %0d / %0d",
                            ink_v3, ink_v2, ink_v1); end
        if (ink_v1 > 0) $display("[ OK ] ÷ 字段的数字画在同一个窗口里（%0d px）", ink_v1);
        else begin errors = errors + 1;
                   $display("[FAIL] ÷ 字段的数值窗一个像素都没有"); end

        // ---- 拆位对不对：面板通路与键盘通路喂**同一组数字**，逐格比墨量 ---------
        //   键盘通路（t_kp_d2/d1/d0）本来就是寄存器；下面把面板待应用值设成 256
        //   （拆位应得 2/5/6）、键盘三个数字寄存器也设成 2/5/6，两边的三格墨量
        //   必须**逐格相等** —— 只比"三位 > 两位 > 一位"是判不出拆错的。
        pnl_on_tb    = 1'b1;
        t_kp_on      = 1'b0;      // 先把面板通路的结果量出来
        pnl_fld_tb   = 1'b0;
        pnl_inter_tb = 10'd0;     // 编码 0 = ×256 ⇒ 数字 2/5/6
        pnl_didx_tb  = 3'd0;
        wait_frames(1); sc_d2_t = 0; sc_d1_t = 0; sc_d0_t = 0;
        wait_frames(1); ink_p2 = sc_d2_t; ink_p1 = sc_d1_t; ink_p0 = sc_d0_t;

        t_kp_on      = 1'b1;      // 再喂同样三个数字给键盘通路
        t_kp_d2      = 4'd2;
        t_kp_d1      = 4'd5;
        t_kp_d0      = 4'd6;
        t_kp_dig     = 2'd3;      // 三位都输过 ⇒ 前导格不空白
        wait_frames(1); sc_d2_t = 0; sc_d1_t = 0; sc_d0_t = 0;
        wait_frames(1); ink_k2 = sc_d2_t; ink_k1 = sc_d1_t; ink_k0 = sc_d0_t;
        $display("[scan] 拆位 2/5/6：面板 %0d/%0d/%0d vs 键盘 %0d/%0d/%0d",
                 ink_p2, ink_p1, ink_p0, ink_k2, ink_k1, ink_k0);
        if ((ink_p2 == ink_k2) && (ink_p1 == ink_k1) && (ink_p0 == ink_k0) &&
            (ink_p2 > 0) && (ink_p1 > 0) && (ink_p0 > 0))
            $display("[ OK ] 面板拆位 = 键盘数字（256 → 2/5/6，逐格墨量相等）");
        else begin errors = errors + 1;
                   $display("[FAIL] 面板拆位与键盘数字不一致：%0d/%0d/%0d vs %0d/%0d/%0d",
                            ink_p2, ink_p1, ink_p0, ink_k2, ink_k1, ink_k0); end

        //   一位数再来一次：面板 ÷7（拆位应得 0/0/7）对键盘 0/0/7 ——
        //   顺带验"前导格被抹掉"这条在两通路上等价。
        t_kp_on      = 1'b0;
        pnl_fld_tb   = 1'b1;
        pnl_didx_tb  = 3'd6;      // 码 6 = ÷7
        wait_frames(1); sc_d2_t = 0; sc_d1_t = 0; sc_d0_t = 0;
        wait_frames(1); ink_p2 = sc_d2_t; ink_p1 = sc_d1_t; ink_p0 = sc_d0_t;

        t_kp_on      = 1'b1;
        t_kp_d2      = 4'd0;
        t_kp_d1      = 4'd0;
        t_kp_d0      = 4'd7;
        t_kp_dig     = 2'd1;      // 只输了一位 ⇒ 前两格空白
        wait_frames(1); sc_d2_t = 0; sc_d1_t = 0; sc_d0_t = 0;
        wait_frames(1); ink_k2 = sc_d2_t; ink_k1 = sc_d1_t; ink_k0 = sc_d0_t;
        $display("[scan] 拆位 ÷7：面板 %0d/%0d/%0d vs 键盘 %0d/%0d/%0d",
                 ink_p2, ink_p1, ink_p0, ink_k2, ink_k1, ink_k0);
        if ((ink_p2 == ink_k2) && (ink_p1 == ink_k1) && (ink_p0 == ink_k0) &&
            (ink_p0 > 0) && (ink_p2 == 0) && (ink_p1 == 0))
            $display("[ OK ] 面板拆位 = 键盘数字（÷7 → 0/0/7，前导格同样空白）");
        else begin errors = errors + 1;
                   $display("[FAIL] ÷7 拆位/前导空白与键盘不一致：%0d/%0d/%0d vs %0d/%0d/%0d",
                            ink_p2, ink_p1, ink_p0, ink_k2, ink_k1, ink_k0); end
        t_kp_on      = 1'b0;

        pnl_fld_tb   = 1'b0;
        pnl_didx_tb  = 3'd0;
        pnl_inter_tb = 10'd64;
        repeat (2) @(posedge clk);

        // =====================================================================
        // [10] v24：「↩ 回到 ×N ÷M」—— BACK 按钮的标签带（P1 lab 第 34 格行 46..54）
        //   undo_lab 每帧把这 9 格重写一遍（规范 §6.5：面板要显示"上一次值"）。
        //   ★ v44（㊶）：标签从 7 格扩到 9 格（末尾多 '÷' 与分频个位）—— 面板能改
        //     分频之后，"回到上一次值"必须把分频一起带回去，否则只回到一半。
        //   两条判据分工：
        //     ① 读 u_p1_lab_ram.mem 的字符码 —— 钉住"值算对了"（double dabble、
        //        前导零抑制、编码 0 = ×256、div 码 0 = ÷1）；
        //     ② 数 BACK 按钮区（x 736..879, y 544..559）的 C_TEXT 像素 —— 钉住
        //        "字真的到了屏上"（P1 的 lab 层只在 page=0 且面板开着时才合成）。
        //   ★ 四者墨量的**大小关系**（×256 > ×8 > 只有"回到"；×64 ÷8 > 只有"回到"）
        //     也是判据：单看"有字"会漏掉"标签带被静态版面盖住"这种缺陷。
        // =====================================================================
        $display("---- [10] BACK 标签带：↩ 回到 ×N ÷M ----");
        hold_page         = 1'b1;
        t_page            = 3'd0;
        pnl_on_tb         = 1'b1;
        pnl_undo_tb       = 1'b1;
        pnl_pend_tb       = 1'b0;
        pnl_press_tb      = 4'd0;
        pnl_undo_div_tb   = 3'd0;                // ÷1
        pnl_undo_inter_tb = 10'd8;               // 一位数
        repeat (2) @(posedge clk);
        wait_frames(2);                          // 帧首的 undo_lab 写完 + 稳定一帧
        exp_lab[0] = 8'd47;                      // '↩'
        exp_lab[1] = 8'd135;                     // '回'
        exp_lab[2] = 8'd136;                     // '到'
        exp_lab[3] = 8'd45;                      // '×'
        exp_lab[4] = 8'd16;                      // '8'
        exp_lab[5] = 8'd0;
        exp_lab[6] = 8'd0;
        exp_lab[7] = 8'd46;                      // '÷'（v44/㊶）
        exp_lab[8] = 8'd9;                       // '1'（div 码 0 = ÷1）
        check_lab("×8");
        sc_back_t = 0;
        wait_frames(1);
        ink_8 = sc_back_t;
        $display("[scan] BACK 标签带 ×8 的墨量 = %0d px", ink_8);
        if (ink_8 <= 0) begin
            errors = errors + 1;
            $display("[FAIL] ×8 标签带在屏上一个文字像素都没有");
        end else $display("[ OK ] ×8 标签带在屏上（%0d px）", ink_8);

        pnl_undo_inter_tb = 10'd256;             // 编码 0 = ×256，这里直接用 256
        repeat (2) @(posedge clk);
        wait_frames(2);
        exp_lab[4] = 8'd10;                      // '2'
        exp_lab[5] = 8'd13;                      // '5'
        exp_lab[6] = 8'd14;                      // '6'
        check_lab("×256");
        sc_back_t = 0;
        wait_frames(1);
        ink_256 = sc_back_t;
        $display("[scan] BACK 标签带 ×256 的墨量 = %0d px", ink_256);
        if (ink_256 <= ink_8) begin
            errors = errors + 1;
            $display("[FAIL] ×256 的墨量 %0d 不大于 ×8 的 %0d（三位数字没画出来）",
                     ink_256, ink_8);
        end else $display("[ OK ] ×256 比 ×8 墨多（%0d > %0d）：三位数字画出来了",
                          ink_256, ink_8);

        //   v44（㊶）新增：分频个位也要画出来 ——「↩ 回到 ×64 ÷8」
        //   这一条补的正是 ㊶ 本体：面板能改分频之后，撤销标签必须把 ÷M 一起写回去，
        //   否则"回到上一次值"只回到一半（倍频回了、分频没回），而屏上看不出来。
        pnl_undo_inter_tb = 10'd64;
        pnl_undo_div_tb   = 3'd7;                // ÷8（码 7）
        repeat (2) @(posedge clk);
        wait_frames(2);
        exp_lab[4] = 8'd14;                      // '6'
        exp_lab[5] = 8'd12;                      // '4'
        exp_lab[6] = 8'd0;
        exp_lab[7] = 8'd46;                      // '÷'
        exp_lab[8] = 8'd16;                      // '8'
        check_lab("×64 ÷8");
        sc_back_t = 0;
        wait_frames(1);
        ink_div = sc_back_t;
        $display("[scan] BACK 标签带 ×64 ÷8 的墨量 = %0d px", ink_div);
        if (ink_div <= 0) begin
            errors = errors + 1;
            $display("[FAIL] ÷8 的「8」在屏上一个像素都没有");
        end else if (ink_div <= ink_0) begin
            errors = errors + 1;
            $display("[FAIL] ×64 ÷8 的墨量 %0d 不大于「只有回到」的 %0d",
                     ink_div, ink_0);
        end else $display("[ OK ] 分频个位画出来了（×64 ÷8 = %0d px > %0d）",
                          ink_div, ink_0);

        //   avail=0（还没有"上一次值"）：只写「回到」，位置与静态版面一致（46/47）
        pnl_undo_tb = 1'b0;
        pnl_undo_inter_tb = 10'd0;
        repeat (2) @(posedge clk);
        wait_frames(2);
        exp_lab[0] = 8'd135;                     // '回'
        exp_lab[1] = 8'd136;                     // '到'
        exp_lab[2] = 8'd0;
        exp_lab[3] = 8'd0;
        exp_lab[4] = 8'd0;
        exp_lab[5] = 8'd0;
        exp_lab[6] = 8'd0;
        exp_lab[7] = 8'd0;                       // v44（㊶）：'÷' 也要消失
        exp_lab[8] = 8'd0;
        check_lab("无上一次值");
        sc_back_t = 0;
        wait_frames(1);
        ink_0 = sc_back_t;
        $display("[scan] BACK 标签带（无上一次值）的墨量 = %0d px", ink_0);
        if (ink_0 <= 0) begin
            errors = errors + 1;
            $display("[FAIL] 无上一次值时的「回到」没画出来");
        end else if (ink_0 >= ink_8) begin
            errors = errors + 1;
            $display("[FAIL] 「回到」的墨量 %0d 不小于 ×8 的 %0d（箭头没被去掉？）",
                     ink_0, ink_8);
        end else $display("[ OK ] 无上一次值：只剩「回到」（%0d < %0d）", ink_0, ink_8);

        pnl_on_tb = 1'b0;
        pnl_undo_inter_tb = 10'd64;
        pnl_undo_div_tb   = 3'd0;
        repeat (2) @(posedge clk);

        hold_page = 1'b0;
        t_page    = 3'd0;

        // =====================================================================
        // [11] v30：卡片迷你状态条（规范 4.3 的"迷你状态条" / 5.2 的"状态字模"）
        //   U-30 把 正常/警示/故障 三个词与 ●/▲/✖ 三个字形做成了字模（v30 版本），
        //   disp/stat_chip.v 每帧按判据表把六张卡的状态写进 P1 的 lab 平面。
        //   这一段的判据分三层，缺哪层都能藏缺陷：
        //     ① 探针 u_stat_chip.chip_st —— 判据表本身算得对不对（单元测试
        //        tb_stat_chip.v 已经把 14 种输入组合穷举过，这里只钉端到端接线）；
        //     ② 读 u_p1_lab_ram.mem 的字符码 —— "卡号 → 格行/格列"的映射对不对
        //        （⊕ 这条正是单元测试抓不到、只能在引擎里看到的：六卡分两排三列，
        //         列序不能用 chip[1:0] 直接取，见 stat_chip.v 的注释）；
        //     ③ 数状态条 4 格的 C_TEXT 墨量 —— "字真的到了屏上"，且**随遥测改字**
        //        （正常轮与警示轮的墨量必须不等：漂移/门控/被别的图层盖住都会
        //         让两轮相等或为零）。
        //   轮 C 再把面板打开，让 undo_lab 与本模块抢同一个写口 —— 仲裁（面板优先、
        //   本模块停拍）不能让任何一边丢写：面板标签 7 格与卡片状态条 4 格都得对。
        // =====================================================================
        $display("---- [11] 卡片迷你状态条：●正常 / ▲警示 / ✖故障 ----");
        hold_page   = 1'b1;
        t_page      = 3'd0;
        pnl_on_tb   = 1'b0;      // 轮 A/B：面板关着，P1 的 lab 写口只归状态条
        pnl_undo_tb = 1'b0;
        pnl_pend_tb = 1'b0;
        pnl_press_tb = 4'd0;

        // ---- 轮 A：卡 1..5 全正常（●正常），卡 6 警示（uvw_warn=1 且 uwven 未使能）----
        t_io_flags = 8'h18;      // bit4 abzen=1、bit3 uvw_warn=1，其余 0
        t_stat     = 8'h00;
        t_abzen    = 1'b1;
        t_uwven    = 1'b0;
        repeat (2) @(posedge clk);
        wait_frames(2);          // 遥测打一拍 → 帧首写口 → 再稳一帧
        check_chip_st("轮 A", 12'h400);          // 只有卡 6 = 警示(1) ⇒ bit[11:10]
        check_card("轮 A", 3'd0, 8'd48, 8'd134, 8'd135);   // ●正常
        check_card("轮 A", 3'd1, 8'd48, 8'd134, 8'd135);
        check_card("轮 A", 3'd2, 8'd48, 8'd134, 8'd135);
        check_card("轮 A", 3'd3, 8'd48, 8'd134, 8'd135);
        check_card("轮 A", 3'd4, 8'd48, 8'd134, 8'd135);
        check_card("轮 A", 3'd5, 8'd49, 8'd136, 8'd137);   // ▲警示
        sc_chip_t = 0;
        wait_frames(1);
        ink_chip_ok = sc_chip_t;
        $display("[scan] 卡 1 状态条（●正常）墨量 = %0d px", ink_chip_ok);
        if (ink_chip_ok <= 0) begin
            errors = errors + 1;
            $display("[FAIL] 卡 1 状态条在屏上一个文字像素都没有");
        end else $display("[ OK ] 卡 1 状态条在屏上（%0d px）", ink_chip_ok);

        // ---- [11] v31（㉘）：第三重冗余「反转视频」——正常卡不反转 ----
        //   块色像素数必须为 0：正常状态条是"卡片白底 + 黑字"，一点状态色都不该有。
        ink_chip_block = sc_chip_bg;
        if (ink_chip_block != 0) begin
            errors = errors + 1;
            $display("[FAIL] 轮 A 卡 1 是正常，状态条里却有 %0d px 状态色（不该反色）",
                     ink_chip_block);
        end else $display("[ OK ] 轮 A 卡 1 正常：状态条无反色块（块色 0 px）");
        //   颜色钉在**空格那一格**（第 2 格）的像素上：那格没有字形，像素只可能是
        //   块色或卡片白底 —— 字模以后再改也不影响这几条。取样点 = 格列*16+8,
        //   格行*16+8：卡 1 (120,248) / 卡 2 (440,248) / 卡 3 (760,248)（行 15）、
        //   卡 4 (120,584) / 卡 5 (440,584) / 卡 6 (760,584)（行 36）。
        expect_not_px(12'd120, 12'd248, C_WARN,  "轮 A 卡 1（正常）状态条没有反色块");
        expect_not_px(12'd440, 12'd248, C_WARN,  "轮 A 卡 2（正常）状态条没有反色块");
        expect_not_px(12'd760, 12'd248, C_WARN,  "轮 A 卡 3（正常）状态条没有反色块");
        expect_px    (12'd760, 12'd584, C_WARN,  "轮 A 卡 6（警示）状态条反色块");

        // ---- 轮 B：三种状态同屏 ----
        //   卡 1 警示(lag_warn) / 卡 2 警示(stat.inclim) / 卡 3 故障(amp_bad)
        //   卡 4 故障(cor_sat) / 卡 5 警示(stat.laglim) / 卡 6 故障(两路都没使能)
        t_io_flags = 8'hC1;      // bit7 amp_bad、bit6 cor_sat、bit0 lag_warn
        t_stat     = 8'h2C;      // bit5 scamp、bit3 inclim、bit2 laglim
        t_abzen    = 1'b0;
        t_uwven    = 1'b0;
        repeat (2) @(posedge clk);
        wait_frames(2);
        check_chip_st("轮 B", 12'h9A5);          // {2,1,2,2,1,1}
        check_card("轮 B", 3'd0, 8'd49, 8'd136, 8'd137);   // ▲警示
        check_card("轮 B", 3'd1, 8'd49, 8'd136, 8'd137);
        check_card("轮 B", 3'd2, 8'd50, 8'd97,  8'd98);    // ✖故障
        check_card("轮 B", 3'd3, 8'd50, 8'd97,  8'd98);
        check_card("轮 B", 3'd4, 8'd49, 8'd136, 8'd137);
        check_card("轮 B", 3'd5, 8'd50, 8'd97,  8'd98);
        sc_chip_t = 0;
        sc_chip_bg = 0;
        wait_frames(1);
        ink_chip_warn  = sc_chip_t;
        ink_chip_block = sc_chip_bg;
        $display("[scan] 卡 1 状态条（▲警示）C_TEXT 墨量 = %0d px、块色 = %0d px",
                 ink_chip_warn, ink_chip_block);
        //  ① 反转的证据：警示卡上不该再有黑字（C_TEXT == 0），而正常轮必须 > 0 ——
        //     否则"反转"根本没发生，只是字没画出来（两条互为对照，缺一条会假绿）。
        if (ink_chip_warn != 0) begin
            errors = errors + 1;
            $display("[FAIL] 轮 B 卡 1 已警示，状态条上还有 %0d px 黑字（没有反色）",
                     ink_chip_warn);
        end else if (ink_chip_ok <= 0) begin
            errors = errors + 1;
            $display("[FAIL] 轮 A 卡 1 正常时也没有黑字（%0d px）—— 状态条没画到像素上",
                     ink_chip_ok);
        end else $display("[ OK ] 正常轮黑字 %0d px、警示轮黑字归零 ⇒ 字变白了",
                          ink_chip_ok);
        //  ② 反色块本身：警示轮的状态条必须出现状态色（C_WARN 或 C_FAULT）
        if (ink_chip_block <= 0) begin
            errors = errors + 1;
            $display("[FAIL] 轮 B 卡 1 已警示，状态条里一个状态色像素都没有（没有反色块）");
        end else $display("[ OK ] 轮 B 卡 1 警示：状态条反色块 %0d px", ink_chip_block);
        //  ③ 六张卡逐个钉住块色：警示 = C_WARN、故障 = C_FAULT（空格那一格取样）
        expect_px(12'd120, 12'd248, C_WARN,  "轮 B 卡 1（警示）状态条反色块");
        expect_px(12'd440, 12'd248, C_WARN,  "轮 B 卡 2（警示）状态条反色块");
        expect_px(12'd760, 12'd248, C_FAULT, "轮 B 卡 3（故障）状态条反色块");
        expect_px(12'd120, 12'd584, C_FAULT, "轮 B 卡 4（故障）状态条反色块");
        expect_px(12'd440, 12'd584, C_WARN,  "轮 B 卡 5（警示）状态条反色块");
        expect_px(12'd760, 12'd584, C_FAULT, "轮 B 卡 6（故障）状态条反色块");

        // ---- 轮 C：写口仲裁 —— 面板标签与状态条同帧都得落地 ----
        //   undo_lab 每帧写行 34 的 7 格，stat_chip 每帧写行 15/36 的 24 格；两个写者
        //   共用一个 RAM 写口，由 disp_engine 做优先权（面板优先、状态条停拍）。
        //   这里同时要求两边都对：只要仲裁丢写，就会有一边停在旧值上。
        t_io_flags = 8'hC3;      // 再加 bit1 lag_fatal ⇒ 卡 1 变故障
        t_stat     = 8'h2C;
        t_abzen    = 1'b0;
        t_uwven    = 1'b0;
        pnl_on_tb         = 1'b1;
        pnl_undo_tb       = 1'b1;
        pnl_undo_inter_tb = 10'd16;               // 「↩ 回到 ×16」
        repeat (2) @(posedge clk);
        wait_frames(2);
        exp_lab[0] = 8'd47;                      // '↩'
        exp_lab[1] = 8'd135;                     // '回'
        exp_lab[2] = 8'd136;                     // '到'
        exp_lab[3] = 8'd45;                      // '×'
        exp_lab[4] = 8'd9;                       // '1'
        exp_lab[5] = 8'd14;                      // '6'
        exp_lab[6] = 8'd0;
        exp_lab[7] = 8'd46;                      // '÷'（v44/㊶，div 码此时是 0 = ÷1）
        exp_lab[8] = 8'd9;                       // '1'
        check_lab("×16（与状态条同帧）");
        check_chip_st("轮 C", 12'h9A6);          // 卡 1 变故障 ⇒ {2,1,2,2,1,2}
        check_card("轮 C", 3'd0, 8'd50, 8'd97, 8'd98);     // 卡 1 ✖故障（仲裁不丢写）
        check_card("轮 C", 3'd5, 8'd50, 8'd97, 8'd98);     // 第二排也照旧
        //  面板开着时反色块照旧：这两条同时证明"状态条的像素路径与面板无争"。
        //  ★ 只能查**第一排**：面板矩形是 PNL_X0..X1 = 96..927、PNL_Y0..Y1 = 320..591
        //    （disp/disp_engine.v:255-258），整排第二张卡的状态条都在面板下面
        //    （实测 (760,584) 取到的是面板底色 C_BG，不是块色 —— 这不是缺陷，
        //    是这一段的取样点选错了；第二排的块色判据在轮 A/轮 B 里查过）。
        expect_px(12'd120, 12'd248, C_FAULT, "轮 C 卡 1（故障）状态条反色块");
        expect_px(12'd760, 12'd248, C_FAULT, "轮 C 卡 3（故障）状态条反色块");

        // 还原（免得影响将来在 [11] 之后追加的段）
        pnl_on_tb         = 1'b0;
        pnl_undo_tb       = 1'b0;
        pnl_undo_inter_tb = 10'd64;
        t_io_flags        = 8'h00;
        t_stat            = 8'h00;
        t_abzen           = 1'b1;
        t_uwven           = 1'b0;
        hold_page         = 1'b0;
        t_page            = 3'd0;
        repeat (2) @(posedge clk);

        // =====================================================================
        // ---- [12] v32（㉙）：第四重冗余「可关闭的 2 Hz 闪烁」----
        //   spec §5.2 的四重是「字形 + 中文文字 + 反转视频（白字反色块）
        //   + 可关闭的 2 Hz 闪烁」。㉗ 落了前两重、㉘ 落了第三重，本段验第四重。
        //   判据分三块，都不靠"数时间"：
        //     ① 相位 → 像素：把 u_dut.blk_ph 强推成 1/0，各跑一整帧，看卡 1 状态条
        //        的块色与黑字墨量（相位 1 ⇒ 有块色、无黑字；相位 0 ⇒ 无块色、有黑字）。
        //        强推的时机是**帧首之后一拍**，这样整帧都不会被引擎的 always 覆盖。
        //     ② 关掉闪烁（t_blink = 0）⇒ 相位 0 也必须常亮（㉘ 的行为一字不变）。
        //     ③ 相位发生器的算术：直接探 blk_div/blk_ph（blk_div==14 才翻、翻了归 0），
        //        等价于"半周期 15 帧 = 256.03 ms ⇒ 1.953 Hz"，但不与 NBA 的更新次序赛跑。
        //     ④ P6 的入口：标题带那颗按钮里的 16x16 复选框（实心 = 开 / 空心 = 关）
        //        与文字层的「闪烁」两格。复选框的"填/空"是几何信息，不看颜色也能读。
        // =====================================================================
        t_io_flags = 8'hC1;      // 卡 1 = 警示（bit0 lag_warn）
        t_stat     = 8'h2C;
        t_abzen    = 1'b0;
        t_uwven    = 1'b0;
        //   ★ 必须钉住页号：tb 的自动翻页是 `if (n_frame > 0 && !hold_page) t_page <= …`
        //     每帧一页。@(scan) 的累加器按 `t_page == 3'd0` 门控 —— 忘了 hold_page
        //     就会在 wait_frames 里翻到 P2/P3，块色墨量恒为 0（第一次跑就是这么红的 3 条）。
        hold_page  = 1'b1;
        t_page     = 3'd0;
        t_blink    = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);

        // ---- ① 相位 1：反色块亮 ----
        f1 = n_frame; while (n_frame === f1) @(posedge clk);
        @(posedge clk);                       // 离开帧首，避免与引擎的 always 抢
        u_dut.blk_div = 4'd0;
        u_dut.blk_ph  = 1'b1;
        sc_chip_t  = 0;
        sc_chip_bg = 0;
        wait_frames(1);
        blink_on_bg = sc_chip_bg;
        blink_on_tx = sc_chip_t;
        if (blink_on_bg <= 0) begin
            $display("[FAIL] 闪烁相位 1（亮）：卡 1 状态条没有反色块（块色 %0d px）", blink_on_bg);
            errors = errors + 1;
        end else if (blink_on_tx !== 0) begin
            $display("[FAIL] 闪烁相位 1（亮）：状态条上还有 %0d px 黑字（该是白字）", blink_on_tx);
            errors = errors + 1;
        end else begin
            $display("[ OK ] 闪烁相位 1（亮）：反色块 %0d px、黑字 0 px", blink_on_bg);
        end

        // ---- ② 相位 0：反色块灭（回到黑字白底）----
        f1 = n_frame; while (n_frame === f1) @(posedge clk);
        @(posedge clk);
        u_dut.blk_div = 4'd0;
        u_dut.blk_ph  = 1'b0;
        sc_chip_t  = 0;
        sc_chip_bg = 0;
        wait_frames(1);
        blink_off_bg = sc_chip_bg;
        blink_off_tx = sc_chip_t;
        if (blink_off_bg !== 0) begin
            $display("[FAIL] 闪烁相位 0（灭）：状态条还有 %0d px 块色（该灭）", blink_off_bg);
            errors = errors + 1;
        end else if (blink_off_tx <= 0) begin
            $display("[FAIL] 闪烁相位 0（灭）：状态条没有黑字（该回到 ●/▲ 字形 + 中文）");
            errors = errors + 1;
        end else begin
            $display("[ OK ] 闪烁相位 0（灭）：黑字 %0d px、块色 0 px", blink_off_tx);
        end

        // ---- ③ 关掉闪烁 ⇒ 相位 0 也常亮（㉘ 的行为）----
        t_blink = 1'b0;
        f1 = n_frame; while (n_frame === f1) @(posedge clk);
        @(posedge clk);
        u_dut.blk_div = 4'd0;
        u_dut.blk_ph  = 1'b0;
        sc_chip_t  = 0;
        sc_chip_bg = 0;
        wait_frames(1);
        blink_dis_bg = sc_chip_bg;
        if (blink_dis_bg <= 0) begin
            $display("[FAIL] 闪烁关闭 + 相位 0：反色块没常亮（块色 %0d px）", blink_dis_bg);
            errors = errors + 1;
        end else begin
            $display("[ OK ] 闪烁关闭：相位 0 也常亮（块色 %0d px，㉘ 的行为不变）", blink_dis_bg);
        end

        // ---- ④ 相位发生器的算术：blk_div==14 那一拍才翻 ----
        t_blink = 1'b1;
        f1 = n_frame; while (n_frame === f1) @(posedge clk);
        @(posedge clk);
        u_dut.blk_div = 4'd13;
        u_dut.blk_ph  = 1'b1;
        wait_frames(1);
        @(posedge clk);
        if ((u_dut.blk_ph !== 1'b1) || (u_dut.blk_div !== 4'd14)) begin
            $display("[FAIL] 闪烁分频 13 → 期望 (ph=1, div=14)，实测 (ph=%b, div=%0d)",
                     u_dut.blk_ph, u_dut.blk_div);
            errors = errors + 1;
        end else begin
            $display("[ OK ] 闪烁分频 13 → (ph=1, div=14)（第 14 拍还不翻）");
        end
        f1 = n_frame; while (n_frame === f1) @(posedge clk);
        @(posedge clk);
        u_dut.blk_div = 4'd14;
        u_dut.blk_ph  = 1'b1;
        wait_frames(1);
        @(posedge clk);
        if ((u_dut.blk_ph !== 1'b0) || (u_dut.blk_div !== 4'd0)) begin
            $display("[FAIL] 闪烁分频 14 → 期望 (ph=0, div=0)，实测 (ph=%b, div=%0d)",
                     u_dut.blk_ph, u_dut.blk_div);
            errors = errors + 1;
        end else begin
            $display("[ OK ] 闪烁分频 14 → (ph=0, div=0)：半周期 15 帧 = 256.03 ms ⇒ 1.953 Hz");
        end

        // ---- ⑤ P6 的入口：标题带按钮里的复选框 + 文字层的「闪烁」----
        hold_page = 1'b1;                     // 停掉自动翻页
        repeat (2) @(posedge clk);
        t_page = 3'd5;
        repeat (2) @(posedge clk);
        wait_frames(2);
        // (a) 闪烁开 ⇒ 实心：整块都是 C_TEXT
        t_blink = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(1);
        expect_px(12'd668, 12'd36, C_TEXT, "P6 复选框（开）左上角");
        expect_px(12'd675, 12'd43, C_TEXT, "P6 复选框（开）内部实心");
        // (b) 闪烁关 ⇒ 空心：内部是卡片白底、四边 1 px C_TEXT
        t_blink = 1'b0;
        repeat (2) @(posedge clk);
        wait_frames(1);
        expect_px(12'd675, 12'd43, C_CARD, "P6 复选框（关）内部空心");
        expect_px(12'd683, 12'd43, C_TEXT, "P6 复选框（关）右描边");
        // (c) 文字层：p6_lab_ram 的 (2,44)/(2,45) = 「闪」「烁」
        begin : p6_blink_label
            reg [7:0] c0, c1;
            c0 = u_dut.u_p6_lab_ram.mem[{6'd2, 6'd44}];
            c1 = u_dut.u_p6_lab_ram.mem[{6'd2, 6'd45}];
            if (c0 !== 8'd140 || c1 !== 8'd141) begin
                $display("[FAIL] P6 标题带按钮标签 = (%0d,%0d)，期望 (140,141) = 「闪烁」", c0, c1);
                errors = errors + 1;
            end else begin
                $display("[ OK ] P6 标题带按钮标签 = (140,141) = 「闪烁」");
            end
        end

        // ---- ⑥ v34（㊲）：危险区按钮的按下反馈（同一点两态）----
        //   为什么用"同一点两态"而不是"某个态里某个色"：只测按住态的话，把按钮
        //   底色直接刷成 C_FAULT 也能过；只有**不按时的同一点必须是脸**才证伪
        //   "这圈是按下才画上去的"。这也是把"按下反馈"从"一个颜色"钉成
        //   "一个形状"的判据（spec §5.2：颜色绝不作为唯一编码）。
        //   ★ v42（㊴）：危险区改成两颗 412 px 对称按钮后，第 1 颗的几何从
        //     x 192..639 变成 **x 180..591**（y 仍是 520..583），内嵌框（各边 2 px、
        //     里侧 10 px）跟着变成 **左 x 190..191 / 右 x 580..581**，
        //     上下仍是 y 530..531 / 572..573。
        //   ★ 8 个点都避开格行 34 的标签字形（第 1 颗 x 336..431 / y 544..559）、
        //     避开警示三角（中心 x=140）与按钮自己的红描边。
        begin : dz_press_ring
            // (a) 未按下：内嵌框的位置就是按钮的脸
            dz_prs_tb = 1'b0;
            repeat (2) @(posedge clk);
            wait_frames(1);
            expect_px(12'd190, 12'd552, C_BG, "P6 未按下：内框左外沿是脸");
            expect_px(12'd191, 12'd552, C_BG, "P6 未按下：内框左内沿是脸");
            expect_px(12'd580, 12'd552, C_BG, "P6 未按下：内框右内沿是脸");
            expect_px(12'd581, 12'd552, C_BG, "P6 未按下：内框右外沿是脸");
            expect_px(12'd400, 12'd530, C_BG, "P6 未按下：内框上外沿是脸");
            expect_px(12'd400, 12'd531, C_BG, "P6 未按下：内框上内沿是脸");
            expect_px(12'd400, 12'd572, C_BG, "P6 未按下：内框下内沿是脸");
            expect_px(12'd400, 12'd573, C_BG, "P6 未按下：内框下外沿是脸");
            // (b) 按住：同一圈逐点亮起来
            dz_prs_tb = 1'b1;
            repeat (2) @(posedge clk);
            wait_frames(1);
            expect_px(12'd190, 12'd552, C_FAULT, "P6 按住：内框左外沿亮");
            expect_px(12'd191, 12'd552, C_FAULT, "P6 按住：内框左内沿亮");
            expect_px(12'd580, 12'd552, C_FAULT, "P6 按住：内框右内沿亮");
            expect_px(12'd581, 12'd552, C_FAULT, "P6 按住：内框右外沿亮");
            expect_px(12'd400, 12'd530, C_FAULT, "P6 按住：内框上外沿亮");
            expect_px(12'd400, 12'd531, C_FAULT, "P6 按住：内框上内沿亮");
            expect_px(12'd400, 12'd572, C_FAULT, "P6 按住：内框下内沿亮");
            expect_px(12'd400, 12'd573, C_FAULT, "P6 按住：内框下外沿亮");
            // (c) 按住**不是**把整块按钮染色，也没越出按钮
            expect_px(12'd300, 12'd552, C_BG,    "P6 按住：按钮内部仍是脸（不是整块染色）");
            expect_px(12'd100, 12'd552, C_CARD,  "P6 按住：按钮之外仍是危险区底");
            // 还原：松手后这一圈必须熄掉（否则"按下反馈"变成了常亮装饰）
            dz_prs_tb = 1'b0;
            repeat (2) @(posedge clk);
            wait_frames(1);
            expect_px(12'd190, 12'd552, C_BG, "P6 松开：内框熄灭");
        end

        // ---- ⑦ v42（㊴）：第 2 颗按钮（恢复默认）+ 回读结果的两重表示 + 两套对话框 ----
        //   三段判据，每段都带自己的证伪面：
        //     ① 内嵌框同一点两态（未按 = 脸、按住 = 亮）—— 证明第 2 颗有**自己的**
        //        按下电平（而不是跟着第 1 颗的 ui_dz_press 一起亮）；
        //     ② 描边色兼作"恢复序列结果"指示灯：ui_rst_state = 1 全绿，其余（0/2/3）红。
        //        三个态各采一次 ⇒ "无条件画成绿的"或"无条件画成红的"都过不去；
        //     ③ ✖ 标记：ui_rst_bad 的第 (k, n) 位 ⇒ 第 k 行带第 n 列标题右侧一个红 ✖。
        //        用 bit 4（= 行带 1 列 1 = 限幅）⇒ 必须在 y 153..166 出现，
        //        而 y 65..78（行带 0 列 1）**必须仍然没有**。这一条正是"选行带要用
        //        行带号 p6_k、不能用自然格行 lab_cy"的证伪点：按 lab_cy 选带的第一版
        //        会把 ✖ 画到行带 0 去，这两条断言会同时红（那是我自己写出的真缺陷）。
        begin : dz_btn2_and_bad
            // (a) 第 2 颗的内嵌框：x 618..619 / 1008..1009，y 530..531 / 572..573
            dz_prs2_tb = 1'b0;
            repeat (2) @(posedge clk);
            wait_frames(1);
            expect_px(12'd618, 12'd552,  C_BG, "P6 第2颗未按下：内框左外沿是脸");
            expect_px(12'd619, 12'd552,  C_BG, "P6 第2颗未按下：内框左内沿是脸");
            expect_px(12'd1008, 12'd552, C_BG, "P6 第2颗未按下：内框右内沿是脸");
            expect_px(12'd1009, 12'd552, C_BG, "P6 第2颗未按下：内框右外沿是脸");
            expect_px(12'd800, 12'd530,  C_BG, "P6 第2颗未按下：内框上外沿是脸");
            expect_px(12'd800, 12'd531,  C_BG, "P6 第2颗未按下：内框上内沿是脸");
            expect_px(12'd800, 12'd572,  C_BG, "P6 第2颗未按下：内框下内沿是脸");
            expect_px(12'd800, 12'd573,  C_BG, "P6 第2颗未按下：内框下外沿是脸");
            //   ★ 同一次采样里第 1 颗的内框必须仍是脸：两颗各有各的按下电平。
            expect_px(12'd190, 12'd552,  C_BG, "P6 第2颗按下电平不影响第1颗");
            dz_prs2_tb = 1'b1;
            repeat (2) @(posedge clk);
            wait_frames(1);
            expect_px(12'd618, 12'd552,  C_FAULT, "P6 第2颗按住：内框左外沿亮");
            expect_px(12'd619, 12'd552,  C_FAULT, "P6 第2颗按住：内框左内沿亮");
            expect_px(12'd1008, 12'd552, C_FAULT, "P6 第2颗按住：内框右内沿亮");
            expect_px(12'd1009, 12'd552, C_FAULT, "P6 第2颗按住：内框右外沿亮");
            expect_px(12'd800, 12'd530,  C_FAULT, "P6 第2颗按住：内框上外沿亮");
            expect_px(12'd800, 12'd531,  C_FAULT, "P6 第2颗按住：内框上内沿亮");
            expect_px(12'd800, 12'd572,  C_FAULT, "P6 第2颗按住：内框下内沿亮");
            expect_px(12'd800, 12'd573,  C_FAULT, "P6 第2颗按住：内框下外沿亮");
            expect_px(12'd800, 12'd552,  C_BG,    "P6 第2颗按住：按钮内部仍是脸");
            expect_px(12'd600, 12'd552,  C_CARD,  "P6 第2颗按住：两颗之间的缝仍是区底色");
            dz_prs2_tb = 1'b0;
            repeat (2) @(posedge clk);
            wait_frames(1);
            expect_px(12'd618, 12'd552, C_BG, "P6 第2颗松开：内框熄灭");

            // (b) 描边色 = 回读结果指示灯（三态各一次）
            rst_bad_tb = 15'd0;
            rst_state_tb = 2'd0;
            repeat (2) @(posedge clk); wait_frames(1);
            expect_px(12'd608, 12'd552, C_FAULT, "rst_state=0（空闲）：第2颗描边红");
            rst_state_tb = 2'd1;
            repeat (2) @(posedge clk); wait_frames(1);
            expect_px(12'd608, 12'd552, C_OK, "rst_state=1（17 项全一致）：第2颗描边绿");
            rst_state_tb = 2'd2;
            repeat (2) @(posedge clk); wait_frames(1);
            expect_px(12'd608, 12'd552, C_FAULT, "rst_state=2（有不一致）：第2颗描边红");

            // (c) ✖ 标记：bit 4 = 行带 1 列 1 = 限幅。
            //     ✖ 的墨迹几何（tools/gen_font_rom.py:557-565 的 5x7 点阵、s=2、
            //     y_off=1、左对齐）：格内 x 0..9、y 1..14；中心墨迹在 (x 4..5, y 7..8)。
            //     第 1 列格位 = BAD_COL1 = 32 ⇒ x 512..527。
            rst_state_tb = 2'd2;
            rst_bad_tb   = 15'h0010;
            repeat (2) @(posedge clk); wait_frames(1);
            expect_px(12'd516, 12'd159, C_FAULT, "✖ 限幅（行带1列1）中心墨迹");
            expect_px(12'd512, 12'd153, C_FAULT, "✖ 限幅（行带1列1）左上角墨迹");
            expect_px(12'd516, 12'd71,  C_BG, "行带0列1 没有 ✖（选带用 p6_k，不是 lab_cy）");
            expect_px(12'd196, 12'd159, C_BG, "行带1列0 没有 ✖（bit3 = 0，不许误报）");
            expect_px(12'd836, 12'd159, C_BG, "行带1列2 没有 ✖（bit5 = 0，不许误报）");
            //   证伪面：把失败位清掉，同一格必须立刻回到页面底色。
            rst_bad_tb = 15'd0;
            repeat (2) @(posedge clk); wait_frames(1);
            expect_px(12'd516, 12'd159, C_BG, "rst_bad=0：同一格没有 ✖（不是常亮装饰）");
            //   证伪面：行带 1 的**另一列**失败时，✖ 必须跟着换列（bit 5 = 列 2）。
            rst_bad_tb = 15'h0020;
            repeat (2) @(posedge clk); wait_frames(1);
            expect_px(12'd836, 12'd159, C_FAULT, "bit5 ⇒ 行带1列2 的 ✖ 亮（列也按位选）");
            expect_px(12'd516, 12'd159, C_BG,    "bit5 ⇒ 行带1列1 的 ✖ 不亮");
            rst_bad_tb = 15'd0;
            rst_state_tb = 2'd0;
            repeat (2) @(posedge clk); wait_frames(1);

            // (d) 两套对话框的文字行（kind 由 dlg_kind_tb 钉住；窗口见 [7] 的扫描段）
            //     清除锁存故障 = 格行 13/18，恢复默认 = 格行 14/19。
            dlg_tb = 2'd1; dlg_kind_tb = 1'b1;
            repeat (2) @(posedge clk);
            wait_frames(1);
            //   kind=1 时两套按钮都不该被吃掉（它与第 1 颗共用同一条 dz_keep 放行规则）
            expect_px(12'd300, 12'd552, 24'hFBD9D6, "询问态（恢复默认）第1颗仍可见");
            expect_px(12'd800, 12'd552, 24'hFBD9D6, "询问态（恢复默认）第2颗仍可见");
            f0 = n_frame; while (n_frame == f0) @(posedge clk);
            sc_dlg_t1 = 0; sc_dlg_r1 = 0; sc_dlg_k1t = 0; sc_dlg_k1b = 0;
            sc_dlg_k1x = 0;
            f0 = n_frame; while (n_frame == f0) @(posedge clk);
            //   ★ 正文行现在从格列 24 起（x 384..623）⇒ 右侧 x 624..703 必须空，
            //     这条与 sc_dlg_k1b > 0 一起才算"挪到位"（只判有墨是骗得过去的）。
            if ((sc_dlg_k1t > 0) && (sc_dlg_k1b > 0) && (sc_dlg_k1x == 0))
                $display("[ OK ] 询问态（恢复默认）行 14/19 有墨且正文居中（%0d/%0d/0 px）",
                         sc_dlg_k1t, sc_dlg_k1b);
            else begin errors = errors + 1;
                  $display("[FAIL] 询问态（恢复默认）行 14/19 没墨或正文没居中（%0d/%0d/%0d px）",
                           sc_dlg_k1t, sc_dlg_k1b, sc_dlg_k1x); end
            if ((sc_dlg_t1 == 0) && (sc_dlg_r1 == 0))
                $display("[ OK ] 询问态（恢复默认）下故障对话框的行 13/18 无墨（0/0 px）");
            else begin errors = errors + 1;
                  $display("[FAIL] 询问态（恢复默认）下故障对话框的行 13/18 有墨（%0d/%0d px）",
                           sc_dlg_t1, sc_dlg_r1); end
            dlg_tb = 2'd0; dlg_kind_tb = 1'b0;
            repeat (2) @(posedge clk);
            wait_frames(1);
        end

        // 还原
        t_blink    = 1'b0;
        hold_page  = 1'b0;
        t_page     = 3'd0;
        t_io_flags = 8'h00;
        t_stat     = 8'h00;
        t_abzen    = 1'b1;
        t_uwven    = 1'b0;
        repeat (2) @(posedge clk);

        // ---- [11b] v45（㊷）/ v46（㊸）：空态（docs/13:351 反模式 8 / :364 的 S7 打磨项）----
        //   信号不可信时，屏上**不许再出现"看起来像测量值"的数字**。
        //   `sig_bad` 有两个来源（都在 `disp/disp_engine.v` 里，抽头直出、没改 rtl/）：
        //     ① `tap_biss_crc_err` = **链路 CRC 错**（帧来了但没过校验）；
        //     ② v46（㊸）新增 **无载波** = `tap_amp_sq < tap_amp_low_sq`
        //        （幅值低于下限门限 ⇒ 编码器侧根本没信号；"编码器停摆"在显示侧
        //         唯一可观测的形态。抽头里没有 BiSS 链路心跳位，纯链路静默判不出来）。
        //   ★ 为什么**不**把 cor_sat / amp_bad 这两个**标志位**并进来（这是首跑 44 条红
        //     换来的口径）：那两个位在 §[11] 轮 B 里已经**各自**钉在卡 3（转速，amp_bad
        //     直接影响幅值）与卡 4（角度，cor_sat 影响正交通道）的判据上。把它们并进
        //     `sig_bad` 会把"每张卡各自的口径"抹平成"四张测量卡全废"，反而丢信息；
        //     而 CRC 错说明**整帧**数据都没过校验，与"是哪张卡的问题"无关 ⇒ 只有它
        //     才该让四个测量字段一起进空态。轮 B2 专门钉这条区分。
        //     （② 是**值/门限**比较，不是标志位：幅值偏高仍属"质量"问题，不许空态。）
        //   三条判据（缺一条都能藏缺陷）：
        //     ① 四个**测量**字段（输入频率 / 转速 / 角度 / 累计转数）整格 '-'，
        //        小数点保留 ⇒ 读数变成"------.--"，一眼看得出"这不是零、是没读数"；
        //        （空态用 '-' 而不是空白：空白会被当成"这里本来没画东西"）
        //     ② 四个测量卡的迷你状态条 ✖ 故障，并且因为不是"正常"而反色
        //        ⇒ 块色必须是 **C_FAULT**（能区分故障与警示，别被 C_WARN 蒙过去）；
        //     ③ 字段 1（配置回读）与字段 5（ABZ/UVW 逻辑电平）、卡 2、卡 6
        //        **一字不动** —— 它们与输入信号可不可信无关，屏上必须继续说得出
        //        "现在配的是多少、线是什么"。
        //   各轮（A 基线 / B 链路 CRC / B2 质量标志 / D 无载波 / D2 门限边界 /
        //   E 静止 / C 撤销）缺一条都有藏缺陷的缝：D 钉"没信号要空态"，E 钉
        //   "**静止 ≠ 停摆**"（静止时载波还在、频率合法地是 0 ⇒ 必须照常显示
        //   0.00，不许误空态），D2 钉判据是严格小于。
        //   ★ 值层判据落在 `u_p1_val_ram.mem` 的**字符码**上（"屏上是哪个字"的
        //     唯一硬证据；像素颜色分不清数字与短横），与 [10]/[11] 读 lab 层同一手法。
        //   ★ 但值层与 lab 层的**格地址布局不同**：值层是 `mem[0:319]`、地址 = 行*32+列
        //     （`disp/disp_engine.v:930-932` 的 `{val_cy, val_cx}`，行 4 bit、列 5 bit），
        //     lab 层是 `mem[0:2431]`、地址 = 行*64+列。照抄 lab 的写法会读到别的格甚至
        //     越界 X —— 这正是首跑 [11b] 那 32 条 `got 0 / got X` 的原因。
        // =====================================================================
        $display("---- [11b] v45（㊷）空态：不可信信号不给'看起来像测量值'的数字 ----");
        hold_page  = 1'b1;
        t_page     = 3'd0;
        pnl_on_tb  = 1'b0;          // 面板关着：数值层只归 val_format
        t_blink    = 1'b0;          // 反色块常亮，免得闪烁相位把块色判据弄飘
        t_crc      = 1'b0;          // 链路正常
        t_io_flags = 8'h30;         // ABZ/UVW 都使能 ⇒ 卡 6 正常
        t_stat     = 8'h00;
        t_abzen    = 1'b1;
        t_uwven    = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);

        // ---- 轮 A：基线（链路正常）----
        //   先把两个非测量字段的字符码存下来，再确认"输入频率字段真的是一串数字"
        //   —— 否则 val_format 若恒输出 '-'，轮 B 的空态判据会**照样全绿**。
        for (bq = 0; bq < 7; bq = bq + 1)
            base_ratio[bq] = u_dut.u_p1_val_ram.mem[{4'd2, 5'd13 + bq[4:0]}];
        for (bq = 0; bq < 8; bq = bq + 1)
            base_abz[bq]   = u_dut.u_p1_val_ram.mem[{4'd7, 5'd23 + bq[4:0]}];
        ndig_t  = 0;
        ndash_t = 0;
        for (bq = 0; bq < 9; bq = bq + 1) begin
            $display("      轮 A 值层 (2,%0d) = %0d", 3 + bq,
                     u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}]);
            if ((u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] >= 8'd8) &&
                (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] <= 8'd17))
                ndig_t = ndig_t + 1;
            if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] === 8'd2)
                ndash_t = ndash_t + 1;
        end
        //   ★ 门槛别定太高：tb 默认的频率遥测是 0，字段显示 `0.00`
        //     （**3** 个数字 + 1 个点）。定成"≥4 个数字"会在默认遥测下自己红
        //     （第一次跑就是这么红的）。真正要钉的是"**没有一个 '-'**"（空态标志）
        //     加上"至少 3 个数字"（像读数）。
        if ((ndash_t != 0) || (ndig_t < 3)) begin
            errors = errors + 1;
            $display("[FAIL] 轮 A 输入频率字段 = %0d 个数字 / %0d 个 '-'（基线本身就不像读数）",
                     ndig_t, ndash_t);
        end else $display("[ OK ] 轮 A 输入频率字段有 %0d 个数字、0 个 '-'（基线成立）", ndig_t);

        // ---- 轮 B：链路 CRC 错 ⇒ 空态 ----
        t_crc = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);             // 遥测 → sig_bad → val_format 重写一帧 → 再稳一帧

        // ① 四个测量字段整格 '-'，小数点保留
        chk_val_dashes("空态 输入频率", 6'd2, 6'd3,  5'd9, 5'd2);
        chk_val_dashes("空态 转速",     6'd2, 6'd23, 5'd8, 5'd1);
        chk_val_dashes("空态 角度",     6'd7, 6'd3,  5'd7, 5'd1);
        chk_val_dashes("空态 累计转数", 6'd7, 6'd13, 5'd8, 5'd0);
        $display("[ OK ] 空态 四个测量字段整格 '-'（小数点保留）");

        // ② 两个非测量字段与基线逐格相同
        for (bq = 0; bq < 7; bq = bq + 1) begin
            if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd13 + bq[4:0]}] !== base_ratio[bq]) begin
                errors = errors + 1;
                $display("[FAIL] 空态动了字段 1（倍频分频）第 %0d 格：got %0d want %0d",
                         bq, u_dut.u_p1_val_ram.mem[{4'd2, 5'd13 + bq[4:0]}], base_ratio[bq]);
            end
        end
        for (bq = 0; bq < 8; bq = bq + 1) begin
            //   ★ 字段 5（ABZ/UVW 逻辑电平）是**活数据**：A/B/Z 三个电平位跟着编码器
            //     模型的边沿走，所以"与基线逐格相同"这条太严 —— 电平位从 0 翻到 1
            //     本来就是对的。分两类判：
            //       字母格（A/B/Z，码 18/19/43）与空格格（码 0）⇒ 必须**一字不动**；
            //       电平格 ⇒ 必须是 ●（48）或 ○（51）之一 —— v52（㊾）起电平位用
            //         实心/空心圈表示（规范 §4.5 原文 `A● B● Z○`），不再是数字 1/0。
            //   ★ 这里别再按"8..17 = 数字"判：那是 v52 之前的写法，现在电平位
            //     一个都不落在数字区间，照旧判会把每一次电平翻转都报成 FAIL。
            if ((base_abz[bq] === 8'd18) || (base_abz[bq] === 8'd19) ||
                (base_abz[bq] === 8'd43) || (base_abz[bq] === 8'd0)) begin
                if (u_dut.u_p1_val_ram.mem[{4'd7, 5'd23 + bq[4:0]}] !== base_abz[bq]) begin
                    errors = errors + 1;
                    $display("[FAIL] 空态动了字段 5（ABZ/UVW）第 %0d 格：got %0d want %0d",
                             bq, u_dut.u_p1_val_ram.mem[{4'd7, 5'd23 + bq[4:0]}], base_abz[bq]);
                end
            end else if ((u_dut.u_p1_val_ram.mem[{4'd7, 5'd23 + bq[4:0]}] !== 8'd48) &&
                         (u_dut.u_p1_val_ram.mem[{4'd7, 5'd23 + bq[4:0]}] !== 8'd51)) begin
                errors = errors + 1;
                $display("[FAIL] 空态把字段 5（ABZ/UVW）第 %0d 格的电平位换掉了：got %0d want ●(48)/○(51)（基线 %0d）",
                         bq, u_dut.u_p1_val_ram.mem[{4'd7, 5'd23 + bq[4:0]}], base_abz[bq]);
            end
        end
        $display("[ OK ] 空态 字段 1/字段 5 与基线逐格相同（配置与逻辑电平不受影响）");

        // ③ 状态条：卡 1/3/4/5 ✖故障，卡 2/卡 6 ●正常（探针 + 字符码两层）
        check_chip_st("空态", 12'h2A2);                  // {卡6,卡5,卡4,卡3,卡2,卡1}
        check_card("空态", 3'd0, 8'd50, 8'd97, 8'd98);   // ✖ 故障
        check_card("空态", 3'd1, 8'd48, 8'd134, 8'd135); // ● 正常（配置回读）
        check_card("空态", 3'd2, 8'd50, 8'd97, 8'd98);
        check_card("空态", 3'd3, 8'd50, 8'd97, 8'd98);
        check_card("空态", 3'd4, 8'd50, 8'd97, 8'd98);
        check_card("空态", 3'd5, 8'd48, 8'd134, 8'd135); // ● 正常（使能状态）
        $display("[ OK ] 空态 六卡状态条：1/3/4/5 ✖故障，2/6 ●正常");

        // ---- ④ v50（㊼）B3：**P5 六状态表与 P2 俯标的空态** ----
        //   同一个 sig_bad 也喂进了 p5_view / p2_badge：空态时它们的数值格必须写 '-'
        //   （码 2），而不是 0 或饱和值 —— `99999` 是 16 bit BCD 的饱和点，不是哨兵。
        //   这里读**标签层**的字符码（P5/P2 的动态数字都写在 lab 平面里）。
        //   P5：六个状态行 = lab 行 9..14；次数列从列 28 起 5 格、占比列从列 33 起 5 格。
        for (bq = 0; bq < 5; bq = bq + 1) begin
            lab_got = u_dut.u_p5_lab_ram.mem[{6'd9, 6'd28 + bq[5:0]}];
            if (lab_got !== 8'd2) begin
                errors = errors + 1;
                $display("[FAIL] B3 空态 P5 第 1 行次数第 %0d 格 = %0d，期望 2（'-'）", bq, lab_got);
            end
            lab_got = u_dut.u_p5_lab_ram.mem[{6'd9, 6'd33 + bq[5:0]}];
            if (lab_got !== 8'd2) begin
                errors = errors + 1;
                $display("[FAIL] B3 空态 P5 第 1 行占比第 %0d 格 = %0d，期望 2（'-'）", bq, lab_got);
            end
        end
        $display("[ OK ] B3 空态 P5 次数/占比逐格 '-'（第 1 行 10 格）");

        //   P2：四枚徽标 = lab 行 36、起始列 28/38/48/58、每枚 6 格（见 disp/p2_badge.v
        //   的 `f_col` 表）。这里逐格验第 1 枚（28）与第 4 枚（58），中间两枚同一套生成器。
        for (bq = 0; bq < 6; bq = bq + 1) begin
            lab_got = u_dut.u_p2_lab_ram.mem[{6'd36, 6'd28 + bq[5:0]}];
            if (lab_got !== 8'd2) begin
                errors = errors + 1;
                $display("[FAIL] B3 空态 P2 第 1 枚徽标第 %0d 格 = %0d，期望 2（'-'）", bq, lab_got);
            end
            lab_got = u_dut.u_p2_lab_ram.mem[{6'd36, 6'd58 + bq[5:0]}];
            if (lab_got !== 8'd2) begin
                errors = errors + 1;
                $display("[FAIL] B3 空态 P2 第 4 枚徽标第 %0d 格 = %0d，期望 2（'-'）", bq, lab_got);
            end
        end
        $display("[ OK ] B3 空态 P2 俯标第 1/4 枚逐格 '-'（12 格）");

        // ④ 像素级：卡 1 的反色块是**故障色**（不是警示色），卡 2/卡 6 不反色
        expect_px    (12'd120, 12'd248, C_FAULT, "空态 卡 1 状态条反色块 = 故障色");
        expect_not_px(12'd440, 12'd248, C_FAULT, "空态 卡 2（配置回读）不反色");
        expect_not_px(12'd760, 12'd584, C_FAULT, "空态 卡 6（使能状态）不反色");

        // ---- 轮 B2：**链路 CRC ≠ 信号质量**（口径区分，不许把两者混为一谈）----
        //   只把 amp_bad + cor_sat 拉起来（链路本身是好的，t_crc 保持 0）：
        //   卡 3/卡 4 该按各自的判据报 ✖（转速受幅度影响、角度受相关器饱和影响），
        //   但**测量读数不许进空态** —— 帧数据本身是可信的，把它抹成 '-' 反而丢信息。
        //   这条判据把"sig_bad 只认链路 CRC"这个口径钉死：以后谁把 io_flags 的
        //   信号质量位并进 sig_bad，这里立刻红。
        t_crc      = 1'b0;
        t_io_flags = 8'hF0;         // bit7 amp_bad、bit6 cor_sat、bit5 uwven、bit4 abzen
        t_stat     = 8'h00;
        repeat (2) @(posedge clk);
        wait_frames(2);
        ndig_t  = 0;
        ndash_t = 0;
        for (bq = 0; bq < 9; bq = bq + 1) begin
            if ((u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] >= 8'd8) &&
                (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] <= 8'd17))
                ndig_t = ndig_t + 1;
            if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] === 8'd2)
                ndash_t = ndash_t + 1;
        end
        if ((ndash_t != 0) || (ndig_t < 3)) begin
            errors = errors + 1;
            $display("[FAIL] 只有 amp_bad/cor_sat（链路好）时输入频率 = %0d 个数字 / %0d 个 '-' —— 空态口径被扩大了",
                     ndig_t, ndash_t);
        end else $display("[ OK ] 只有 amp_bad/cor_sat（链路好）：读数照常显示（%0d 个数字、0 个 '-'）", ndig_t);
        check_chip_st("链路好但信号差", 12'h0A0);   // {卡6,卡5,卡4,卡3,卡2,卡1} = 只有卡 3/4 故障
        check_card("链路好但信号差", 3'd0, 8'd48, 8'd134, 8'd135);   // 卡 1 ●正常
        check_card("链路好但信号差", 3'd2, 8'd50, 8'd97,  8'd98);    // 卡 3 ✖故障（amp_bad）
        $display("[ OK ] 只有 amp_bad/cor_sat：卡 3/卡 4 ✖故障，其余 ●正常，读数不空态");

        // ---- 轮 D：**无载波**（编码器停摆/断线）⇒ 空态 ----
        //   这是 v46（㊸）补的那一半：㊷ 只认"帧来了但没过校验"，认不出"根本没了信号"。
        //   刺激用的是**幅值值**（`t_amp_sq` 掉到下限门限以下），不是 io_flags 的
        //   amp_bad 标志位 —— 判据在 disp_engine 里是值比较（与 rtl/amp_monitor.v:95
        //   的 `w_low = (amp32 < amp_low_sq)` 同口径）。io_flags 这里按**真实器件**
        //   会有的样子一起置起来（amp_bad 必然同时亮），免得造出硬件上不存在的组合。
        //   下限门限常量：`tap_amp_low_sq = 32'h170A_3D71`（0.6² = 0.36 Q2.30）。
        t_crc      = 1'b0;              // 链路本身是好的：空态必须由"没载波"单独触发
        t_amp_sq   = 32'h1000_0000;     // 0.25 Q2.30 < 0.36 ⇒ 无载波
        t_io_flags = 8'hB0;             // bit7 amp_bad（器件会亮）+ bit5 uwven + bit4 abzen
        t_stat     = 8'h00;
        repeat (2) @(posedge clk);
        wait_frames(2);
        chk_val_dashes("无载波 输入频率", 6'd2, 6'd3,  5'd9, 5'd2);
        chk_val_dashes("无载波 转速",     6'd2, 6'd23, 5'd8, 5'd1);
        chk_val_dashes("无载波 角度",     6'd7, 6'd3,  5'd7, 5'd1);
        chk_val_dashes("无载波 累计转数", 6'd7, 6'd13, 5'd8, 5'd0);
        $display("[ OK ] 无载波（帧本身是好的）：四个测量字段整格 '-'，不许显示 0.00");
        check_chip_st("无载波空态", 12'h2A2);           // 卡 1/3/4/5 ✖故障，卡 2/卡 6 ●正常
        check_card("无载波空态", 3'd0, 8'd50, 8'd97, 8'd98);
        check_card("无载波空态", 3'd5, 8'd48, 8'd134, 8'd135);
        expect_px    (12'd120, 12'd248, C_FAULT, "无载波 卡 1 状态条反色块 = 故障色");

        // ---- 轮 D2：门限**边界**（`amp_sq == amp_low_sq`）⇒ 不算无载波 ----
        //   判据是**严格**小于（与 rtl/amp_monitor.v:95 一字不差）。改成"小于等于"
        //   会把"刚好压在下限上"也判成没信号 —— 这一条就是钉这个的。
        t_amp_sq   = 32'h170A_3D71;     // == 下限门限，一个 LSB 都不低
        t_io_flags = 8'h30;             // 器件侧此时 amp_bad 不该亮（严格小于才亮）
        repeat (2) @(posedge clk);
        wait_frames(2);
        ndig_t  = 0;
        ndash_t = 0;
        for (bq = 0; bq < 9; bq = bq + 1) begin
            if ((u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] >= 8'd8) &&
                (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] <= 8'd17))
                ndig_t = ndig_t + 1;
            if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] === 8'd2)
                ndash_t = ndash_t + 1;
        end
        if ((ndash_t != 0) || (ndig_t < 3)) begin
            errors = errors + 1;
            $display("[FAIL] 幅值**等于**下限门限时输入频率 = %0d 个数字 / %0d 个 '-'：判据被放宽成含等于了",
                     ndig_t, ndash_t);
        end else $display("[ OK ] 幅值 == 下限门限（严格小于才空态）：读数照常显示（%0d 个数字）", ndig_t);
        check_chip_st("门限边界", 12'h000);

        // ---- 轮 E：**编码器静止 ≠ 停摆**（载波在、频率合法地是 0）⇒ 照常显示 ----
        //   这是本判据最容易被误用的地方：不能拿"位置/频率不变"当停摆证据
        //   （静止的编码器本来就不变），只有**载波**才能区分两者。
        t_amp_sq   = 32'h2000_0000;     // 0.5 Q2.30，落在 [0.36, 1.44] 窗口内
        t_io_flags = 8'h30;
        t_stat     = 8'h00;
        repeat (2) @(posedge clk);
        wait_frames(2);
        ndig_t  = 0;
        ndash_t = 0;
        for (bq = 0; bq < 9; bq = bq + 1) begin
            $display("      轮 E 值层 (2,%0d) = %0d", 3 + bq,
                     u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}]);
            if ((u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] >= 8'd8) &&
                (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] <= 8'd17))
                ndig_t = ndig_t + 1;
            if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] === 8'd2)
                ndash_t = ndash_t + 1;
        end
        if ((ndash_t != 0) || (ndig_t < 3)) begin
            errors = errors + 1;
            $display("[FAIL] 载波在、转速 0（静止）时输入频率 = %0d 个数字 / %0d 个 '-' —— 把静止误判成停摆了",
                     ndig_t, ndash_t);
        end else $display("[ OK ] 载波在 + 转速 0（静止）：照常显示 0.00，不空态（%0d 个数字）", ndig_t);
        check_chip_st("静止", 12'h000);

        // ---- 轮 C：撤销空态 ⇒ 读数必须回来（空态不能是"一旦进去就出不来"）----
        t_crc      = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);
        //   先确认空态这次真的生效（否则轮 C 的"回来"是空判据）
        chk_val_dashes("轮C前空态", 6'd2, 6'd3, 5'd9, 5'd2);
        t_crc = 1'b0;
        repeat (2) @(posedge clk);
        wait_frames(2);
        ndig_t  = 0;
        ndash_t = 0;
        for (bq = 0; bq < 9; bq = bq + 1) begin
            if ((u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] >= 8'd8) &&
                (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] <= 8'd17))
                ndig_t = ndig_t + 1;
            if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3 + bq[4:0]}] === 8'd2)
                ndash_t = ndash_t + 1;
        end
        if ((ndash_t != 0) || (ndig_t < 3)) begin
            errors = errors + 1;
            $display("[FAIL] 撤销空态后输入频率 = %0d 个数字 / %0d 个 '-'（空态卡住了）", ndig_t, ndash_t);
        end else $display("[ OK ] 撤销空态后输入频率回到 %0d 个数字、0 个 '-'", ndig_t);

        // ---- B3 反向判据：撤销空态后 P5/P2 必须**回到数字**（防"恒空"骗绿）----
        //   取每枚字段的**最右一格**：前导零抑制只影响左边几格，最右格永远是数字。
        //   P5 第 1 行次数列 = 行 9、列 28..32 ⇒ 最右格列 32；
        //   P2 第 1 枚徽标 = 行 36、列 28..33 ⇒ 最右格列 33。
        lab_got = u_dut.u_p5_lab_ram.mem[{6'd9, 6'd32}];
        if ((lab_got < 8'd8) || (lab_got > 8'd17)) begin
            errors = errors + 1;
            $display("[FAIL] B3 撤销空态后 P5 次数最右格 = %0d，期望数字(8..17)", lab_got);
        end
        lab_got = u_dut.u_p2_lab_ram.mem[{6'd36, 6'd33}];
        if ((lab_got < 8'd8) || (lab_got > 8'd17)) begin
            errors = errors + 1;
            $display("[FAIL] B3 撤销空态后 P2 徽标最右格 = %0d，期望数字(8..17)", lab_got);
        end else begin
            $display("[ OK ] B3 撤销空态后 P5/P2 回到数字（最右格都是数字码）");
        end

        // 还原：遥测回默认（后面的段落依赖这些初值）
        t_io_flags = 8'h00;
        t_stat     = 8'h00;
        t_abzen    = 1'b1;
        t_uwven    = 1'b0;
        t_crc      = 1'b0;
        t_amp_sq   = 32'h2000_0000;     // v46（㊸）：幅值回默认（载波在）
        hold_page  = 1'b0;
        t_page     = 3'd0;
        repeat (2) @(posedge clk);

        // ---- [13] v33（㉚）：数字键盘（spec 6.3 的兜底入口）----
        //   三层判据：
        //     ① 键盘关着时：面板右上角多一颗「键盘」入口按钮（12 点阵图标），
        //        且键位区什么也不画（键只在键盘模式下存在）；
        //     ② 键盘模式：键位的描边/底/数字/← ↵ 箭头；
        //     ③ 输入窗：三位 BIG 字段 + 前导零不画 + 面板标题（lab 行 21）被抑制。
        //   ★ 几何与 disp/ui_panel.v 的 KPB_* / KP_* 是两处共同契约：
        //     描边取样点就是 ui_panel 命中矩形的四个角，改一边这里立刻红。
        hold_page         = 1'b1;
        t_page            = 3'd0;
        pnl_on_tb         = 1'b1;
        pnl_inter_tb      = 10'd64;
        pnl_undo_tb       = 1'b1;
        pnl_undo_inter_tb = 10'd64;
        t_kp_on           = 1'b0;
        repeat (2) @(posedge clk);
        wait_frames(1);

        // ① 入口按钮 64x64 @ (856,392)
        expect_px(12'd856, 12'd392, C_GRID, "键盘入口按钮左上角描边");
        expect_px(12'd868, 12'd400, C_TEXT, "键盘入口按钮图标（第 1 个点）");
        expect_px(12'd875, 12'd405, C_CARD, "键盘入口按钮底（点与点之间的缝）");
        //   键盘关着：键位区的那个像素是**面板底色**（键只在键盘模式下画）
        expect_px(12'd134, 12'd335, C_BG,   "键盘关：键位区不画（面板底色）");
        //   同一像素上的正向对照：非键盘模式下标题（lab 行 21）是**允许**画的
        //   ★ 判据直接读 DUT 的门信号（`glyph_pnl = lab_bit & pnl_lab_cell & pnl_on`
        //     是它下游），在**那一个像素时刻**读一次就够 —— 不需要跨帧累加器，
        //     累加器在这里反而不可靠（v33 第一次跑时键盘侧累加器读到 0 而直接
        //     读数是对的，见下面两条 [dbg]）。
        wait (de_o && (dbg_x == 12'd136) && (dbg_y === 12'd336));
        $display("[dbg] 非键盘模式 pnl_lab_cell=%b", u_dut.pnl_lab_cell);
        if (u_dut.pnl_lab_cell !== 1'b1) begin
            $display("[FAIL] 非键盘模式：标题行 pnl_lab_cell = %b，期望 1（面板标题照画）",
                     u_dut.pnl_lab_cell);
            errors = errors + 1;
        end else begin
            $display("[ OK ] 非键盘模式：标题行 pnl_lab_cell = 1");
        end

        // ② 键盘模式：三位数字 1/2/3
        t_kp_on  = 1'b1;
        t_kp_d2  = 4'd1;
        t_kp_d1  = 4'd2;
        t_kp_d0  = 4'd3;
        t_kp_dig = 2'd3;
        repeat (2) @(posedge clk);
        wait_frames(1);
        expect_px(12'd112, 12'd328, C_GRID, "键 1 左上角描边");
        expect_px(12'd140, 12'd342, C_TEXT, "键 1 的数字（b 段）");
        expect_px(12'd134, 12'd335, C_CARD, "键 1 的底（数字 1 不点亮 a 段）");
        expect_px(12'd121, 12'd499, C_TEXT, "← 键的箭头头部");
        expect_px(12'd233, 12'd496, C_TEXT, "↵ 键的竖笔");
        //   ★ 键盘模式下的"还原"：入口按钮不再画（那格回到面板底色）
        expect_px(12'd875, 12'd405, C_BG,   "键盘模式：入口按钮不画");
        // ③ 输入窗：三位 48x80 大字段（字段左上角 340/412/484，y = 352）
        expect_px(12'd330, 12'd342, C_GRID, "输入窗左上角");
        expect_px(12'd384, 12'd372, C_TEXT, "输入窗百位「1」的 b 段");
        expect_px(12'd364, 12'd392, C_CARD, "输入窗百位「1」的 g 段（1 不点亮 g）");
        expect_px(12'd508, 12'd355, C_TEXT, "输入窗个位「3」的 a 段");
        expect_px(12'd528, 12'd408, C_TEXT, "输入窗个位「3」的 c 段");
        //   面板标题（lab 行 21）在键盘模式下必须被抑制：直接读门信号
        wait (de_o && (dbg_x == 12'd136) && (dbg_y === 12'd336));
        $display("[dbg] 键盘模式 pnl_lab_cell=%b t_kp_on=%b",
                 u_dut.pnl_lab_cell, t_kp_on);
        if (u_dut.pnl_lab_cell !== 1'b0) begin
            $display("[FAIL] 键盘模式：标题行 pnl_lab_cell = %b，期望 0（被键盘抑制）",
                     u_dut.pnl_lab_cell);
            errors = errors + 1;
        end else begin
            $display("[ OK ] 键盘模式：标题行 pnl_lab_cell = 0（键盘压住标题）");
        end
        //   前导零不画：位数降到 1 ⇒ 百位与十位字段全灭，个位照画
        t_kp_d2  = 4'd0;
        t_kp_d1  = 4'd3;
        t_kp_dig = 2'd1;
        repeat (2) @(posedge clk);
        wait_frames(1);
        expect_px(12'd384, 12'd372, C_CARD, "位数 1：百位字段不画");
        expect_px(12'd436, 12'd355, C_CARD, "位数 1：十位字段不画");
        expect_px(12'd508, 12'd355, C_TEXT, "位数 1：个位照画（3 的 a 段）");

        // 还原
        t_kp_on    = 1'b0;
        t_kp_d2    = 4'd0;
        t_kp_d1    = 4'd0;
        t_kp_d0    = 4'd0;
        t_kp_dig   = 2'd0;
        t_kp_sel   = 4'hF;
        pnl_on_tb  = 1'b0;
        pnl_undo_tb = 1'b0;
        pnl_inter_tb = 10'd64;
        hold_page  = 1'b0;
        t_page     = 3'd0;
        repeat (2) @(posedge clk);

        // ---- [14] v36（㉜）：P8「自检结果」的结论（规范 §4.4 第 ⑤ 项）----
        //   三项判据都来自显示侧到触摸 IC 那条 IIC 链路的计数，而这三个计数
        //   **就显示在同一页的第 15 格行上**（IIC 读 / 无应答 / 超时）⇒ 结论可以
        //   被同屏明细交叉验证（规范 §5.2 的纪律）。
        //   几何与 disp/selftest_lab.v 的 LAB_ROW/LAB_C0 是两处共同契约：
        //   标签「自检结果」在 31..34（静态版面），结论两个字在 36/37（每帧覆写）。
        //   ★ 每换一次 t_diag 要等 **2 帧**（不是 1 帧）：q_tch_* 是在可见像素期
        //     （de）里抓的，结论在**下一次** vf_start 才写进 RAM —— 也就是
        //     "先抓计数、下一帧开头写结论"的一级流水。页面上第 15 格行的三个计数
        //     由 touch_view 在同一个 vf_start 写，所以结论与明细永远出自同一份快照。
        //     第一次跑就是漏了这一级：5 条判据读到的是**上一个状态**（见记录 58）。
        hold_page = 1'b1;
        t_page    = 3'd7;                        // P8 系统信息
        // ① 链路正常（读 != 0、无应答 0、超时 0）⇒ 通过
        t_diag[99:76]   = 24'd1234;              // IIC 读次数
        t_diag[123:100] = 24'd0;                 // 无应答
        t_diag[147:124] = 24'd0;                 // 超时
        p8v_px = 0; p8v_on = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);
        p8v_on = 1'b0;
        check_p8cell("结论「通过」第 0 格（通）", 6'd36, 8'd159);
        check_p8cell("结论「通过」第 1 格（过）", 6'd37, 8'd160);
        //   静态标签必须原样不动：写者只碰自己那两格（与 band_view 的 11/27 列
        //   同一条纪律）—— 这条同时证明 selftest_lab 的写入没有越界。
        check_p8cell("静态标签第 31 格（自）", 6'd31, 8'd155);
        check_p8cell("静态标签第 32 格（检）", 6'd32, 8'd156);
        check_p8cell("静态标签第 33 格（结）", 6'd33, 8'd157);
        check_p8cell("静态标签第 34 格（果）", 6'd34, 8'd158);
        if (p8v_px <= 0) begin
            errors = errors + 1;
            $display("[FAIL] P8 结论（通过）那一带一个 C_TEXT 像素都没有（没画出来）");
        end else begin
            $display("[ OK ] P8 结论（通过）墨量 = %0d px", p8v_px);
        end

        // ② IIC 停摆（读次数 0）⇒ 失败
        t_diag[99:76] = 24'd0;
        repeat (2) @(posedge clk);
        wait_frames(2);
        check_p8cell("结论「失败」第 0 格（失）", 6'd36, 8'd161);
        check_p8cell("结论「失败」第 1 格（败）", 6'd37, 8'd162);

        // ③ 有不应答 ⇒ 失败（三个判据各有一条反例：这是第二条）
        t_diag[99:76]   = 24'd100;
        t_diag[123:100] = 24'd3;
        repeat (2) @(posedge clk);
        wait_frames(2);
        check_p8cell("NAK!=0 结论第 0 格", 6'd36, 8'd161);
        check_p8cell("NAK!=0 结论第 1 格", 6'd37, 8'd162);

        // ④ 有超时 ⇒ 失败（第三条反例），并顺便验证结论能变回「通过」
        t_diag[123:100] = 24'd0;
        t_diag[147:124] = 24'd1;
        repeat (2) @(posedge clk);
        wait_frames(2);
        check_p8cell("TO!=0 结论第 0 格", 6'd36, 8'd161);
        t_diag[147:124] = 24'd0;
        repeat (2) @(posedge clk);
        wait_frames(2);
        check_p8cell("TO 清零后回到「通过」", 6'd36, 8'd159);
        check_p8cell("TO 清零后结论第 1 格（过）", 6'd37, 8'd160);

        // 还原
        t_diag    = 160'h0;
        hold_page = 1'b0;
        t_page    = 3'd0;
        repeat (2) @(posedge clk);

        // ---- [15] v38（㉞）：P4 等效采样注记（spec §7 数据来源表 :305）----
        //   规范对 ABZ/UVW 的原话：时间轴画 A/B 会混叠，**必须按电角度 64/128 箱
        //   等效采样，并在图上注明**。旧注记是「128点等效采样」—— 缺的正是
        //   "按 / 重 / 建 / 箱" 四个字（那一轮字库 7 bit 已满，只能用"点"顶"箱"）。
        //   这一版把四个字栅格化后按字面写全：14 格，行 27（y 432..447）、
        //   列 6..19（x 96..319）—— 行 27 是 P4 框内唯一不压波形/轴标/刻度的空行。
        //   判据两层（见 check_p4note 与 p4n_px 的注释）：格子读数管"是哪个字"，
        //   墨量管"真的画出来了"；这一段的期望码与 tools/cn_glyphs.py 同源，
        //   由 _disp_work/verify_u38.py 逐项复核（两处共同契约）。
        hold_page = 1'b1;
        t_page    = 3'd3;                        // P4 ABZ/UVW 时序
        exp_note[0]  = 8'd163;                   // 按（v38 新增）
        exp_note[1]  = 8'd71;                    // 电
        exp_note[2]  = 8'd75;                    // 角
        exp_note[3]  = 8'd76;                    // 度
        exp_note[4]  = 8'd164;                   // 重（v38 新增）
        exp_note[5]  = 8'd165;                   // 建（v38 新增）
        exp_note[6]  = 8'd9;                     // '1'
        exp_note[7]  = 8'd10;                    // '2'
        exp_note[8]  = 8'd16;                    // '8'
        exp_note[9]  = 8'd166;                   // 箱（v38 新增）
        exp_note[10] = 8'd69;                    // 等
        exp_note[11] = 8'd70;                    // 效
        exp_note[12] = 8'd127;                   // 采
        exp_note[13] = 8'd128;                   // 样
        p4n_px = 0; p4n_on = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);
        p4n_on = 1'b0;
        check_p4note("「按电角度重建128箱等效采样」");
        if (p4n_px <= 0) begin
            errors = errors + 1;
            $display("[FAIL] P4 注记那一条带一个 C_TEXT 像素都没有（没画出来）");
        end else begin
            $display("[ OK ] P4 注记墨量 = %0d px", p4n_px);
        end
        hold_page = 1'b0;
        t_page    = 3'd0;
        repeat (2) @(posedge clk);

        // ---- [16] v39（㉟）：P1 两处口径注记（spec §7 数据来源表 :300 / :302）----
        //   :300 `RPM = 60 × f_in / 极对数`（f_in 是 64 周期解回绕或 RTL 计数器算出来
        //   的）⇒ 规范要求**标「估算值」**；:302 累计转数从「本次上电」起算、
        //   **不是掉电保存的绝对值，屏上要写明**。
        //   两条都写在 P1 的 lab 面空行上（转速卡的 RPM 单位下方格行 14；累计转数卡
        //   标题下方格行 23），页面上没有任何运行期写者碰这两格。
        //   判据两层（见 check_p1notes 与 p1n_px 的注释）：格子读数管"是哪个字"，
        //   墨量管"真的画出来了"；这一段的期望码与 tools/cn_glyphs.py 同源，
        //   由 _disp_work/verify_u39.py 逐项复核（两处共同契约）。
        hold_page = 1'b1;
        t_page    = 3'd0;                        // P1 总览
        exp_est[0]     = 8'd167;                 // 估（v39 新增）
        exp_est[1]     = 8'd168;                 // 算（v39 新增）
        exp_est[2]     = 8'd126;                 // 值
        exp_revnote[0] = 8'd150;                 // 本
        exp_revnote[1] = 8'd104;                 // 次
        exp_revnote[2] = 8'd169;                 // 上（v39 新增）
        exp_revnote[3] = 8'd71;                  // 电
        exp_revnote[4] = 8'd170;                 // 起（v39 新增）
        exp_revnote[5] = 8'd168;                 // 算（与「估算值」共用同一个字模）
        p1n_px = 0; p1q_px = 0; p1n_on = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);
        p1n_on = 1'b0;
        check_p1notes("「估算值」+「本次上电起算」");
        if (p1n_px <= 0) begin
            errors = errors + 1;
            $display("[FAIL] 「估算值」那一条带一个 C_TEXT 像素都没有（没画出来）");
        end else begin
            $display("[ OK ] 「估算值」墨量 = %0d px", p1n_px);
        end
        if (p1q_px <= 0) begin
            errors = errors + 1;
            $display("[FAIL] 「本次上电起算」那一条带一个 C_TEXT 像素都没有（没画出来）");
        end else begin
            $display("[ OK ] 「本次上电起算」墨量 = %0d px", p1q_px);
        end
        hold_page = 1'b0;
        t_page    = 3'd0;
        repeat (2) @(posedge clk);

        // =====================================================================
        // ---- [17] v48（㊺）A1 + A2：卡内 1 px 分隔线 + 卡 4 次级 pos_full 十六进制 ----
        //   A1（spec §4.3，docs/13:162）：卡内 `y+110` 一条 1 px 的 #D6E3F0 分隔线，
        //     左右各内缩 16 px。本工程卡片 288x256 @ x 96/416/736、y 64/336 ⇒
        //       第 1 排：y = 174，x ∈ [112, 367]（96+16 .. 96+288-16-1）
        //       第 2 排：y = 446，同理
        //     判据四层：线两端有、两端外 1 px 没有（不能越界）、上下相邻行没有
        //     （严格 1 px）、第二排也有。
        //   A2（spec §4.5，docs/13:188）：卡 4 次级信息 = `pos_full 0x……`。
        //     静态标签 `POS 0X` 在 lab (35,6..11)，运行期由 disp/pos_hex.v 把 8 位
        //     十六进制写到 (35,12..19)。本段把 pos_full **冻成 0x003A1B2C** 再逐格读
        //     标签层字符码 —— 判据落在"哪个字"上，不是像素颜色。
        //   ★ 为什么冻结：tb 的 t_pos_full 是自由计数器，不冻住时读回来的值与
        //     写进 RAM 的值不是同一拍，判据会自己红（与 §[11b] 值层同一条纪律）。
        // =====================================================================
        $display("---- [17] v48（㊺）卡内分隔线 + 卡 4 pos_full 十六进制 ----");
        hold_page = 1'b1;
        t_page    = 3'd0;
        repeat (2) @(posedge clk);
        wait_frames(2);

        expect_px    (12'd112, 12'd174, C_GRID, "A1 卡 1 分隔线左端");
        expect_px    (12'd367, 12'd174, C_GRID, "A1 卡 1 分隔线右端");
        expect_not_px(12'd111, 12'd174, C_GRID, "A1 分隔线左端不越界");
        expect_not_px(12'd368, 12'd174, C_GRID, "A1 分隔线右端不越界");
        expect_not_px(12'd112, 12'd173, C_GRID, "A1 分隔线严格 1 px（上一行无线）");
        expect_not_px(12'd112, 12'd175, C_GRID, "A1 分隔线严格 1 px（下一行无线）");
        expect_px    (12'd112, 12'd446, C_GRID, "A1 卡 4 分隔线左端");
        expect_px    (12'd367, 12'd446, C_GRID, "A1 卡 4 分隔线右端");
        $display("[ OK ] A1 两排卡片的分隔线都在 y+110、内缩 16 px、严格 1 px");

        force t_pos_full = 32'h003A1B2C;
        repeat (2) @(posedge clk);
        wait_frames(2);
        hex_exp[0] = 8'd8;    // '0'
        hex_exp[1] = 8'd8;    // '0'
        hex_exp[2] = 8'd11;   // '3'
        hex_exp[3] = 8'd18;   // 'A'
        hex_exp[4] = 8'd9;    // '1'
        hex_exp[5] = 8'd19;   // 'B'
        hex_exp[6] = 8'd10;   // '2'
        hex_exp[7] = 8'd20;   // 'C'
        for (bq = 0; bq < 8; bq = bq + 1) begin
            lab_got = u_dut.u_p1_lab_ram.mem[{6'd35, 6'd12 + bq[5:0]}];
            if (lab_got !== hex_exp[bq]) begin
                errors = errors + 1;
                $display("[FAIL] A2 卡 4 pos_full 第 %0d 位 = %0d，期望 %0d",
                         bq, lab_got, hex_exp[bq]);
            end
        end
        // 静态标签 `POS 0X` 也一起判（生成器没重生成时这里会红）
        if (u_dut.u_p1_lab_ram.mem[{6'd35, 6'd6}]  !== 8'd33 ||   // 'P'
            u_dut.u_p1_lab_ram.mem[{6'd35, 6'd7}]  !== 8'd32 ||   // 'O'
            u_dut.u_p1_lab_ram.mem[{6'd35, 6'd8}]  !== 8'd36 ||   // 'S'
            u_dut.u_p1_lab_ram.mem[{6'd35, 6'd9}]  !== 8'd0  ||   // ' '
            u_dut.u_p1_lab_ram.mem[{6'd35, 6'd10}] !== 8'd8  ||   // '0'
            u_dut.u_p1_lab_ram.mem[{6'd35, 6'd11}] !== 8'd41) begin // 'X'
            errors = errors + 1;
            $display("[FAIL] A2 卡 4 静态标签不是 `POS 0X`（lab 35,6..11 = %0d %0d %0d %0d %0d %0d）",
                     u_dut.u_p1_lab_ram.mem[{6'd35, 6'd6}],  u_dut.u_p1_lab_ram.mem[{6'd35, 6'd7}],
                     u_dut.u_p1_lab_ram.mem[{6'd35, 6'd8}],  u_dut.u_p1_lab_ram.mem[{6'd35, 6'd9}],
                     u_dut.u_p1_lab_ram.mem[{6'd35, 6'd10}], u_dut.u_p1_lab_ram.mem[{6'd35, 6'd11}]);
        end else $display("[ OK ] A2 卡 4 标签 `POS 0X` + 8 位十六进制 = 003A1B2C");
        release t_pos_full;
        //   「方向 CCW」挪到卡 3 的次级行（lab 17/46..，spec §4.5 把它归在转速卡）
        if (u_dut.u_p1_lab_ram.mem[{6'd17, 6'd46}] !== 8'd73 ||  // 方
            u_dut.u_p1_lab_ram.mem[{6'd17, 6'd47}] !== 8'd74) begin // 向
            errors = errors + 1;
            $display("[FAIL] A2 卡 3 次级行没有「方向」二字（lab 17,46..47 = %0d %0d）",
                     u_dut.u_p1_lab_ram.mem[{6'd17, 6'd46}], u_dut.u_p1_lab_ram.mem[{6'd17, 6'd47}]);
        end else $display("[ OK ] A2 卡 3 次级行「方向 CCW」已就位");
        hold_page = 1'b0;
        t_page    = 3'd0;
        repeat (2) @(posedge clk);

        // =====================================================================
        // ---- [18] v49（㊻）A3：卡 6 底部迷你 6 通道逻辑条（spec §4.5 :190）----
        //   六条通道 = io_state 的 a/b/z/u/v/w（位 0..5），每条 8 px 高、共 48 px，
        //   带内 x 752..1007（卡 6 = x 736..1023，左右各内缩 16 px）。
        //   每条只画"电平线"：高电平整条填 C_ACC，低电平只留左端 16 px 短桩 C_GRID。
        //   判据：三道高（第 1/2/6 道）+ 带外不画 + 全低时只剩短桩、右侧回卡片白底。
        // =====================================================================
        $display("---- [18] v49（㊻）卡 6 六通道逻辑条 ----");
        hold_page = 1'b1;
        t_page    = 3'd0;
        t_iostate = 8'h3F;                     // a/b/z/u/v/w 全高（bit0..5）
        repeat (2) @(posedge clk);
        wait_frames(1);
        expect_px    (12'd900, 12'd516, C_ACC,  "A3 第 1 道（a）高电平整条");
        expect_px    (12'd900, 12'd524, C_ACC,  "A3 第 2 道（b）高电平整条");
        expect_px    (12'd900, 12'd556, C_ACC,  "A3 第 6 道（w）高电平整条");
        expect_not_px(12'd900, 12'd564, C_ACC,  "A3 带外（y>=560）不画");
        t_iostate = 8'h00;                     // 全低：只剩 16 px 短桩
        repeat (2) @(posedge clk);
        wait_frames(1);
        expect_px    (12'd760, 12'd516, C_GRID, "A3 低电平只剩左端短桩");
        expect_px    (12'd900, 12'd516, C_CARD, "A3 低电平右侧不画（卡片白底）");
        $display("[ OK ] A3 六通道逻辑条：高电平整条 / 低电平短桩 / 带外不画");
        hold_page = 1'b0;
        t_page    = 3'd0;
        t_iostate = 8'h00;
        repeat (2) @(posedge clk);

        // =====================================================================
        // ---- [19] v51（㊽）B4：面板上"算出来的两个数"（spec §6.3 :284）----
        //   等效倍率 = inter/div（一位小数，行 23 列 41..45）、
        //   预测 AB 边沿率 = 4 × 等效倍率 × f_in（0.1 kHz 为单位，行 25 列 42..46）。
        //   ★ 为什么在这两格行（y 368..415）/ 列 36 起（x 576..751）：面板里
        //     KPV 数值窗占 x 330..572 / y 342..442，滑条 y 448..、± x 800..864、
        //     键盘钮 x 856..920 —— 唯一空带就是面板右上；首版放到列 22..31
        //     正好压进数值窗，§[9b] 的"前导格空白"当场判红（213/12 vs 0/0）。
        //   ★ f_in 用 `force u_dut.fm_f_q10` 给（1/1024 Hz 定点：68 Hz ⇒ 69,632）：
        //     freq_meter 要攒 64 个电周期才结算，这台子等不到那个时间。
        //   ★ 五条判据：① ×100÷3 ⇒ `33.3` / `  9.1`；② 空态 sig_bad ⇒ 边沿率整行 `-`
        //     而等效倍率照旧（后者只依赖设置值，永远有效）；③ 改 ÷1 ⇒ `64.0` / `17.4`
        //     （反向判据：防"算一次就不更新"）；④ 这两个格行在屏上有墨、面板一关
        //     立刻归零（写入列窗与页面层排除窗必须一致）；⑤ 放开 force 后回正常。
        // =====================================================================
        $display("---- [19] v51（㊽）面板：等效倍率 / AB 边沿率 ----");
        hold_page    = 1'b1;
        t_page       = 3'd0;
        pnl_on_tb    = 1'b1;
        pnl_fld_tb   = 1'b0;
        t_kp_on      = 1'b0;
        pnl_inter_tb = 10'd100;                 // ×100
        pnl_didx_tb  = 3'd2;                    // ÷3
        force u_dut.fm_f_q10 = 32'sd69632;      // 68 Hz
        repeat (2) @(posedge clk);
        wait_frames(3);
        // 100/3 = 33.33 ⇒ " 33.3"；4×100×68/3 = 9,066.7 边沿/s = 9.07 kHz ⇒ "  9.1"
        if (u_dut.u_p1_lab_ram.mem[{6'd23, 6'd41}] !== 8'd0  ||   // ' '
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd42}] !== 8'd11 ||   // '3'
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd43}] !== 8'd11 ||   // '3'
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd44}] !== 8'd1  ||   // '.'
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd45}] !== 8'd11) begin // '3'
            errors = errors + 1;
            $display("[FAIL] B4 等效倍率 ×100÷3 应为 ` 33.3`，实得 %0d %0d %0d %0d %0d",
                     u_dut.u_p1_lab_ram.mem[{6'd23, 6'd41}], u_dut.u_p1_lab_ram.mem[{6'd23, 6'd42}],
                     u_dut.u_p1_lab_ram.mem[{6'd23, 6'd43}], u_dut.u_p1_lab_ram.mem[{6'd23, 6'd44}],
                     u_dut.u_p1_lab_ram.mem[{6'd23, 6'd45}]);
        end else $display("[ OK ] B4 等效倍率 ×100÷3 = ` 33.3`");
        if (u_dut.u_p1_lab_ram.mem[{6'd25, 6'd42}] !== 8'd0  ||   // ' '
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd43}] !== 8'd0  ||   // ' '
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd44}] !== 8'd17 ||   // '9'
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd45}] !== 8'd1  ||   // '.'
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd46}] !== 8'd9) begin // '1'
            errors = errors + 1;
            $display("[FAIL] B4 AB 边沿率 ×100÷3@68Hz 应为 `  9.1`，实得 %0d %0d %0d %0d %0d",
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd42}], u_dut.u_p1_lab_ram.mem[{6'd25, 6'd43}],
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd44}], u_dut.u_p1_lab_ram.mem[{6'd25, 6'd45}],
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd46}]);
        end else $display("[ OK ] B4 AB 边沿率 ×100÷3@68Hz = `  9.1`");

        // ---- 空态：边沿率整行 '-'（它依赖测出来的 f_in），等效倍率照旧 -----------
        force u_dut.sig_bad = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(2);
        if (u_dut.u_p1_lab_ram.mem[{6'd25, 6'd42}] !== 8'd0 ||
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd43}] !== 8'd0 ||
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd44}] !== 8'd0 ||
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd45}] !== 8'd0 ||
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd46}] !== 8'd2) begin // '-'
            errors = errors + 1;
            $display("[FAIL] B4 空态 AB 边沿率应为 `    -`，实得 %0d %0d %0d %0d %0d",
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd42}], u_dut.u_p1_lab_ram.mem[{6'd25, 6'd43}],
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd44}], u_dut.u_p1_lab_ram.mem[{6'd25, 6'd45}],
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd46}]);
        end else $display("[ OK ] B4 空态 AB 边沿率 = `    -`");
        if (u_dut.u_p1_lab_ram.mem[{6'd23, 6'd45}] !== 8'd11) begin
            errors = errors + 1;
            $display("[FAIL] B4 空态不该动等效倍率（行 23 列 45 = %0d，应为 11）",
                     u_dut.u_p1_lab_ram.mem[{6'd23, 6'd45}]);
        end else $display("[ OK ] B4 空态下等效倍率仍是 ` 33.3`（只依赖设置值）");
        release u_dut.sig_bad;

        // ---- 反向判据：改 ÷1 ⇒ 两个数都要跟着变 -------------------------------
        pnl_inter_tb = 10'd64;
        pnl_didx_tb  = 3'd0;                    // ÷1
        repeat (2) @(posedge clk);
        wait_frames(3);
        // 64/1 = 64.0 ⇒ " 64.0"；4×64×68 = 17,408 边沿/s = 17.4 kHz ⇒ " 17.4"
        if (u_dut.u_p1_lab_ram.mem[{6'd23, 6'd41}] !== 8'd0  ||
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd42}] !== 8'd14 ||   // '6'
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd43}] !== 8'd12 ||   // '4'
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd44}] !== 8'd1  ||
            u_dut.u_p1_lab_ram.mem[{6'd23, 6'd45}] !== 8'd8) begin // '0'
            errors = errors + 1;
            $display("[FAIL] B4 等效倍率 ×64÷1 应为 ` 64.0`，实得 %0d %0d %0d %0d %0d",
                     u_dut.u_p1_lab_ram.mem[{6'd23, 6'd41}], u_dut.u_p1_lab_ram.mem[{6'd23, 6'd42}],
                     u_dut.u_p1_lab_ram.mem[{6'd23, 6'd43}], u_dut.u_p1_lab_ram.mem[{6'd23, 6'd44}],
                     u_dut.u_p1_lab_ram.mem[{6'd23, 6'd45}]);
        end else $display("[ OK ] B4 等效倍率 ×64÷1 = ` 64.0`（跟着改）");
        if (u_dut.u_p1_lab_ram.mem[{6'd25, 6'd42}] !== 8'd0  ||
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd43}] !== 8'd9  ||   // '1'
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd44}] !== 8'd15 ||   // '7'
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd45}] !== 8'd1  ||
            u_dut.u_p1_lab_ram.mem[{6'd25, 6'd46}] !== 8'd12) begin // '4'
            errors = errors + 1;
            $display("[FAIL] B4 AB 边沿率 ×64÷1@68Hz 应为 ` 17.4`，实得 %0d %0d %0d %0d %0d",
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd42}], u_dut.u_p1_lab_ram.mem[{6'd25, 6'd43}],
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd44}], u_dut.u_p1_lab_ram.mem[{6'd25, 6'd45}],
                     u_dut.u_p1_lab_ram.mem[{6'd25, 6'd46}]);
        end else $display("[ OK ] B4 AB 边沿率 ×64÷1@68Hz = ` 17.4`（跟着改）");

        // ---- 层门控：这两格行（y 368..415、x 576..752）面板开有墨、关无墨 --------
        //   为什么必须单独判：写入列窗（pnl_calc 写的）与页面层排除窗（glyph_page）
        //   是两处代码，差一格就是"面板上少一位"或"关面板后浮着一串旧数字"。
        //   计数器无条件统计（同 §[9] 的教训：用 pnl_on_tb 门控会让断言变成同义反复）。
        sc_b4_t = 0;
        wait_frames(1);
        if (sc_b4_t > 0) $display("[ OK ] B4 面板开着时右上两行有字（%0d px）", sc_b4_t);
        else begin errors = errors + 1;
                   $display("[FAIL] B4 面板开着时右上两行一个像素都没有"); end;
        release u_dut.fm_f_q10;
        pnl_on_tb = 1'b0;
        repeat (2) @(posedge clk);
        sc_b4_t = 0;
        wait_frames(1);
        if (sc_b4_t == 0) $display("[ OK ] B4 面板收起后右上两行归零（排除窗对齐）");
        else begin errors = errors + 1;
                   $display("[FAIL] B4 面板收起后仍有 %0d px 旧数字", sc_b4_t); end;
        hold_page = 1'b0;
        t_page    = 3'd0;
        repeat (2) @(posedge clk);

        // =====================================================================
        // ---- [20] v52（㊾）A3：卡 6 的次级行 `U● V● W○`（spec §4.5 :190）----
        //   8 格落在**标签层**行 26 列 46..53（y 416..431、x 736..863）：
        //   标题 `ABZ/UVW` 在行 22、大数字在行 7，中间这条是空行。
        //   判据只读 `u_p1_lab_ram.mem` 的字符码 —— 屏上是哪个字，这是唯一硬证据
        //   （同 §[17]/§[19] 的手法；像素颜色分不出 ● 和 ○）。
        //   ★ 两个电平字：● = 48（高）、○ = **183**（低）。○ 在 lab 平面是 183、
        //     在 val 平面是 51 —— 两个平面各有自己的字符表，见
        //     tools/gen_text_ram.py 的 LAB_EXTRA / VAL_EXTRA。
        //   ★ 三组用例：① w/v/u 全高；② u/w 低、v 高（判据必须跟着翻）；
        //     ③ 主值行的 `A● B● Z○` 也是同一轮改的（val 平面，码 48/51）。
        // =====================================================================
        $display("---- [20] v52（㊾）卡 6 次级行 U● V● W○ ----");
        hold_page = 1'b1;
        t_page    = 3'd0;
        pnl_on_tb = 1'b0;
        //   ★ 必须先把编码器模型冻住：`t_iostate` 在 `frame_st && !tap_freeze` 下
        //     每帧被 `t_iostate <= {t_iostate[6:0], t_iostate[7] ^ t_iostate[5]}`
        //     旋一位（disp/tb_disp_engine.v:95-103，模拟 ABZ 边沿）。不冻住的话
        //     这里赋的值下一帧就被移走，三组电平判据全部读歪 —— 复跑时 5 条 FAIL
        //     里有 3 条是这么来的（赋 8'h38 却读到 U○ V● W●，赋 8'h10 读到
        //     U○ V○ W●）。冻住后 `frame_st` 计数与 `wait_frames()` 照常走。
        tap_freeze = 1'b1;
        t_iostate = 8'h38;                      // bit5..3 = {w,v,u} = 1,1,1
        repeat (2) @(posedge clk);
        wait_frames(3);
        uv_ok = 1'b1;
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd46}] !== 8'd38) uv_ok = 1'b0;  // U
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd47}] !== 8'd48) uv_ok = 1'b0;  // ●
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd48}] !== 8'd0)  uv_ok = 1'b0;  // ' '
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd49}] !== 8'd39) uv_ok = 1'b0;  // V
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd50}] !== 8'd48) uv_ok = 1'b0;  // ●
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd51}] !== 8'd0)  uv_ok = 1'b0;  // ' '
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd52}] !== 8'd40) uv_ok = 1'b0;  // W
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd53}] !== 8'd48) uv_ok = 1'b0;  // ●
        if (!uv_ok) begin
            errors = errors + 1;
            $display("[FAIL] A3 卡 6 次级行全高应读 `U● V● W●`：got %0d %0d %0d %0d %0d %0d %0d %0d",
                     u_dut.u_p1_lab_ram.mem[{6'd26, 6'd46}], u_dut.u_p1_lab_ram.mem[{6'd26, 6'd47}],
                     u_dut.u_p1_lab_ram.mem[{6'd26, 6'd48}], u_dut.u_p1_lab_ram.mem[{6'd26, 6'd49}],
                     u_dut.u_p1_lab_ram.mem[{6'd26, 6'd50}], u_dut.u_p1_lab_ram.mem[{6'd26, 6'd51}],
                     u_dut.u_p1_lab_ram.mem[{6'd26, 6'd52}], u_dut.u_p1_lab_ram.mem[{6'd26, 6'd53}]);
        end else $display("[ OK ] A3 卡 6 次级行全高 = `U● V● W●`（8 格逐格对码）");

        // ② u=0、v=1、w=0 ⇒ `U○ V● W○`（○ = 183）
        t_iostate = 8'h10;                      // bit5..3 = {w,v,u} = 0,1,0
        repeat (2) @(posedge clk);
        wait_frames(3);
        uv_ok = 1'b1;
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd47}] !== 8'd183) uv_ok = 1'b0;  // ○（U 低）
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd50}] !== 8'd48)  uv_ok = 1'b0;  // ●（V 高）
        if (u_dut.u_p1_lab_ram.mem[{6'd26, 6'd53}] !== 8'd183) uv_ok = 1'b0;  // ○（W 低）
        if (!uv_ok) begin
            errors = errors + 1;
            $display("[FAIL] A3 卡 6 次级行 U/W 低应读 ○(183)：U 位 %0d / V 位 %0d / W 位 %0d",
                     u_dut.u_p1_lab_ram.mem[{6'd26, 6'd47}],
                     u_dut.u_p1_lab_ram.mem[{6'd26, 6'd50}],
                     u_dut.u_p1_lab_ram.mem[{6'd26, 6'd53}]);
        end else $display("[ OK ] A3 卡 6 次级行 U/W 低 = `U○ V● W○`（○ 是 lab 码 183）");

        // ③ 主值行 `A● B● Z○`：val 平面，电平字是 ● 48 / ○ 51
        //   ★ 这里**不能** force DUT 内部的 `q_io_state[2:0]`：xsim 明确拒绝
        //     `ERROR: [VRFC 10-3149] bit-select or part-select is not allowed in a
        //     force statement for non-net 'q_io_state'`（踩过一次）。
        //     改从端口这一侧给：`t_iostate` 就是 `.tap_io_state()` 的驱动源，
        //     q_io_state 只是它打一拍，等下两帧自然就到了。
        t_iostate = 8'h05;                      // a=1 b=0 z=1（bit0=a, bit1=b, bit2=z）
        repeat (2) @(posedge clk);
        wait_frames(3);
        //   ★ 列号：字段 5 是 8 格，落在 val 平面**行 7 列 23..30**
        //     （`disp/val_format.v` 的 `f_row = 7 / f_col = 23 / f_wid = 8`），
        //     即 `A ● ' ' B ○ ' ' Z ●` —— Z 在列 **29**、最后一个圈在列 **30**。
        //     首版把 Z 写成列 30、圈写成列 31（差一格），复跑时报
        //     `got 18 48 0 19 51 0 48 0`：列 30 读到的是 ●，列 31 还没写到。
        if ((u_dut.u_p1_val_ram.mem[{4'd7, 5'd23}] !== 8'd18) ||   // 'A'
            (u_dut.u_p1_val_ram.mem[{4'd7, 5'd24}] !== 8'd48) ||   // ●
            (u_dut.u_p1_val_ram.mem[{4'd7, 5'd25}] !== 8'd0)  ||   // ' '
            (u_dut.u_p1_val_ram.mem[{4'd7, 5'd26}] !== 8'd19) ||   // 'B'
            (u_dut.u_p1_val_ram.mem[{4'd7, 5'd27}] !== 8'd51) ||   // ○
            (u_dut.u_p1_val_ram.mem[{4'd7, 5'd29}] !== 8'd43) ||   // 'Z'
            (u_dut.u_p1_val_ram.mem[{4'd7, 5'd30}] !== 8'd48)) begin // ●
            errors = errors + 1;
            $display("[FAIL] A3 主值行应读 `A● B○ Z●`（A=1 B=0 Z=1）：%0d %0d %0d %0d %0d %0d %0d %0d",
                     u_dut.u_p1_val_ram.mem[{4'd7, 5'd23}], u_dut.u_p1_val_ram.mem[{4'd7, 5'd24}],
                     u_dut.u_p1_val_ram.mem[{4'd7, 5'd25}], u_dut.u_p1_val_ram.mem[{4'd7, 5'd26}],
                     u_dut.u_p1_val_ram.mem[{4'd7, 5'd27}], u_dut.u_p1_val_ram.mem[{4'd7, 5'd28}],
                     u_dut.u_p1_val_ram.mem[{4'd7, 5'd29}], u_dut.u_p1_val_ram.mem[{4'd7, 5'd30}]);
        end else $display("[ OK ] A3 主值行 = `A● B○ Z●`（val 平面 ● 48 / ○ 51）");
        t_iostate  = 8'h00;
        tap_freeze = 1'b0;                      // 解冻，交还给后面的收尾
        hold_page = 1'b0;
        t_page    = 3'd0;
        repeat (2) @(posedge clk);

        // =====================================================================
        // ---- [21] v54（C3）：链路静默（tap_biss_link_lost）单独就能触发空态 ----
        //   空态来源从三个变四个：BiSS CRC 错 / 无载波 / **链路静默**
        //   （契约 v1.1 新增的 `disp_tap[375]`，rtl 侧 "ma 无边沿 > 2 ms @50 MHz"）。
        //   ★ 这条与 `t_crc` 的**唯一行为差别**是粘滞性：`crc_err_seen` 错一次就
        //     再也不退（只能靠 0x0405 W1C 清），`link_lost` 主机一恢复边沿就自己
        //     落回 0。所以这里必须验"能落回"，否则把非粘滞画成粘滞也照样绿。
        //   ★ 空态的判据用**字符码**：字段 0（f_in）空态整格 '-'（码 2），小数点
        //     保留（列 9 仍是 '.' = 码 1）—— 见 disp/val_format.v 的 nodata 支。
        //     正常态同一格必须**不是** '-'，末位（列 11）必须是数字（码 8..17，
        //     个位永远显示、不受前导零抑制影响）。
        // =====================================================================
        $display("---- [21] v54 C3 链路静默空态 ----");
        hold_page   = 1'b1;
        t_page      = 3'd0;
        pnl_on_tb   = 1'b0;
        t_crc       = 1'b0;
        t_link_lost = 1'b0;
        t_amp_sq    = 32'h2000_0000;            // 载波在：空态只可能来自 link_lost
        repeat (2) @(posedge clk);
        wait_frames(3);

        // ① 基线：link_lost=0 时不能因为"多了第四个来源"就把正常画面压成空态
        uv_ok = 1'b1;
        if (u_dut.sig_bad !== 1'b0) uv_ok = 1'b0;
        if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3}]  === 8'd2)  uv_ok = 1'b0;  // 不能是 '-'
        if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd11}] < 8'd8)   uv_ok = 1'b0;  // 末位是数字
        if (!uv_ok) begin
            errors = errors + 1;
            $display("[FAIL] C3 基线（link_lost=0）不应当是空态：sig_bad=%b 列3=%0d 列11=%0d",
                     u_dut.sig_bad, u_dut.u_p1_val_ram.mem[{4'd2, 5'd3}],
                     u_dut.u_p1_val_ram.mem[{4'd2, 5'd11}]);
        end else $display("[ OK ] C3 基线（link_lost=0）数值照常，sig_bad = 0");

        // ② 只拉 link_lost（t_crc=0、幅值正常）⇒ 必须进空态
        t_link_lost = 1'b1;
        repeat (2) @(posedge clk);
        wait_frames(3);
        uv_ok = 1'b1;
        if (u_dut.sig_bad !== 1'b1) uv_ok = 1'b0;
        if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3}]  !== 8'd2) uv_ok = 1'b0;   // '-'
        if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd9}]  !== 8'd1) uv_ok = 1'b0;   // '.' 保留
        if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd11}] !== 8'd2) uv_ok = 1'b0;   // '-'
        if (!uv_ok) begin
            errors = errors + 1;
            $display("[FAIL] C3 链路静默应进空态：sig_bad=%b 列3=%0d 列9=%0d 列11=%0d",
                     u_dut.sig_bad, u_dut.u_p1_val_ram.mem[{4'd2, 5'd3}],
                     u_dut.u_p1_val_ram.mem[{4'd2, 5'd9}],
                     u_dut.u_p1_val_ram.mem[{4'd2, 5'd11}]);
        end else $display("[ OK ] C3 链路静默（只拉 link_lost）⇒ sig_bad=1、f_in 整格 '-'");

        // ③ 落回：link_lost=0 ⇒ sig_bad 回 0、数值行恢复（非粘滞，与 crc_err_seen 相反）
        t_link_lost = 1'b0;
        repeat (2) @(posedge clk);
        wait_frames(3);
        uv_ok = 1'b1;
        if (u_dut.sig_bad !== 1'b0) uv_ok = 1'b0;
        if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd3}]  === 8'd2) uv_ok = 1'b0;
        if (u_dut.u_p1_val_ram.mem[{4'd2, 5'd11}] < 8'd8)  uv_ok = 1'b0;
        if (!uv_ok) begin
            errors = errors + 1;
            $display("[FAIL] C3 link_lost 落回后应恢复：sig_bad=%b 列3=%0d 列11=%0d",
                     u_dut.sig_bad, u_dut.u_p1_val_ram.mem[{4'd2, 5'd3}],
                     u_dut.u_p1_val_ram.mem[{4'd2, 5'd11}]);
        end else $display("[ OK ] C3 link_lost 落回 ⇒ sig_bad=0、数值行恢复（非粘滞）");

        t_link_lost = 1'b0;
        t_crc       = 1'b0;
        hold_page   = 1'b0;
        t_page      = 3'd0;
        repeat (2) @(posedge clk);

        if (errors === 0) $display("\nTEST PASSED: 0 errors");
        else              $display("\nTEST FAILED: %0d errors", errors);
        $finish;
    end

    // 超时保护：8 帧时间还没跑完就是死锁（[6] 把总时长抬到了约 6 帧）
    // 超时保护：v19 加了 [7] 段（20 个采样点 + 5 次文字扫描，每次可能跨一帧），
    //   所以上限从 180 ms（约 10 帧）抬到 1.2 s（约 70 帧）。
    // v20 再加 [8] 段（5 个页面 × 采样 + 3 次文字扫描 + 10 次帧边界等待）⇒ 抬到 1.9 s（约 111 帧）。
    //   ★ 注意 32 位字面量上限：`#2_400_000_000;` 会溢出成负数，xsim 报
    //     `[XSIM 43-3368] Negative delay … treated as 0` 然后立刻超时（踩过一次）。
    //     所以这里用 1_900_000_000（< 2^31-1）而不是 2.4e9。
    // v22 再加 [9] 段（约 30 次像素采样 + 3 次帧边界等待）⇒ 抬到 2_000_000_000
    //   （**还是不能**写成 2.4e9：那已经越过 2^31-1 = 2_147_483_647 了）。
    // ★ v30 改成**按帧数**兜底，不再堆绝对延时：加 [11] 段后所需的绝对时间
    //   （约 126 帧 ⇒ 2.16e9 ns）已经越过 2^31-1，那个上限就在眼前了。
    //   帧数上限与时钟频率、段数都无关，改段不用再动这个数。150 帧 = 当前用例
    //   （约 110 帧）再留 36% 余量；真死锁时最多多跑 40 帧就收工。
    // ★ v36 加了 [14] 段（约 9 帧：5 个状态切换 × 帧边界等待）⇒ 抬到 180 帧
    //   （180 × 17.0688 µs ≈ 3.07 ms，仍在 32 位延时上限之内，与它无关）。
    // ★ v38（㉞）再加 [15] 段（约 2 帧：一次页面切换 + 帧边界等待）⇒ 抬到 195 帧。
    // ★ v39（㉟）再加 [16] 段（约 2 帧：P1 一次页面切换 + 帧边界等待）⇒ 抬到 210 帧。
    //   ★ 这里用**自己的**帧号快照 fto_prev，不能蹭 wait_frames 的 f0：
    //     两个块都写同一个变量时，f0=n_frame 与 while 之间会插进另一个块的赋值，
    //     帧边界就等歪了（同一拍两个写者的老坑，见 tb 顶部那个 NBA 注释）。
    // ★ v51（㊽）再加 [19] 段（约 11 帧：3 + 2 + 3 次帧边界等待 + 收尾）⇒ 抬到 235 帧。
    // ★ v52（㊾）再加 [20] 段（约 8 帧：三组用例 × 2 次帧边界等待 + 收尾）⇒ 抬到 245 帧。
    // ★ v54（C3）再加 [21] 段（约 10 帧：三次帧边界等待 + 收尾）⇒ 抬到 260 帧。
    integer fto = 0;
    integer fto_prev = 0;
    initial begin
        forever begin
            fto_prev = n_frame;
            while (n_frame == fto_prev) @(posedge clk);
            fto = fto + 1;
            if (fto > 260) begin
                $display("\n[FAIL] TIMEOUT (260 frames exceeded)");
                $display("TEST FAILED: timeout");
                $finish;
            end
        end
    end

endmodule
