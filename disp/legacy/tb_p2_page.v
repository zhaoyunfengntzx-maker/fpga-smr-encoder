//=============================================================================
// disp/tb_p2_page.v —— P2 输入波形页的端到端验证（v15）
//-----------------------------------------------------------------------------
//   一个顶层里放两个被测件：
//     ① disp_engine（page=1）—— 验**屏上的像素**：轨迹落点、框、中线、以及
//        "P2 上不该出现的两样东西"（P1 的卡片白底、P1 的文字）；
//     ② wave_trace + wave_ram —— 验**几何的产出**：每列线段的上下沿、钳位、
//        双缓冲换面、扫满即停。
//
//   ★ 本测试台最重要的一条是「列对齐」：波形通路是 disp_engine 里**唯一一路
//     只有一级存储**的数据（文字是"RAM 一拍 + 字形 ROM 一拍"共两拍）。
//     少补一拍，整条波形就右移 1 px；而它不会让任何"跑满帧/查帧率"的检查变红，
//     只会让波形看着"有点歪"。所以这里预置**第 100 列**，再去 x 轴上找它到底
//     出现在哪一列 —— 只有这一条断言能抓住那类 bug。
//
//   ★ 预置数据写在**显示面**（disp_buf=1）并把 tracer 的 disp_buf 强置为 1，
//     于是 tracer 往写面（buf=0）照常采样，读写互不干扰。这是双缓冲的直接好处：
//     测试不需要和采样器抢内存，也就不需要为了"让测试稳定"去关掉采样器 ——
//     那种"关掉被测逻辑再测"的做法会让测试台自己变成最大的未测部分。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_p2_page;

    // ---------------------------------------------------------------- 色板 --
    localparam [23:0] C_BG    = 24'hEAF3FB;
    localparam [23:0] C_CARD  = 24'hFFFFFF;
    localparam [23:0] C_GRID  = 24'hD6E3F0;
    localparam [23:0] C_ACC   = 24'h2E7DD1;
    localparam [23:0] C_SEC   = 24'h8FC4EC;
    localparam [23:0] C_NAV   = 24'hDCE9F5;
    localparam [23:0] C_TEXT  = 24'h1F2D3D;
    localparam [23:0] C_BLACK = 24'h000000;
    localparam [23:0] C_PLOT  = 24'hF7FBFF;
    localparam [23:0] C_TR_A  = 24'h2E7DD1;
    localparam [23:0] C_TR_B  = 24'hC2185B;

    // ------------------------------------------------------------- 时钟复位 --
    reg clk = 1'b0;
    always #10 clk = ~clk;          // 50 MHz

    reg rst_n = 1'b0;

    // ======================================================= 被测件 ① disp_engine
    reg  [2:0]  page = 3'd1;        // P2 输入波形
    reg  [11:0] px = 12'd0, py = 12'd0;
    reg         de = 1'b0;

    wire [23:0] lcd_rgb;
    wire        de_o;
    wire [11:0] dbg_x, dbg_y;

    disp_engine u_dut (
        .clk(clk), .rst_n(rst_n), .page(page),
        .pix_x(px), .pix_y(py), .de(de),
        .tap_angle(16'h2000), .tap_s_n(16'h0A00), .tap_c_n(16'h0500),
        .tap_pos_full(32'h0000_1234),
        .tap_io_state(8'b0100_0001), .tap_io_flags(8'b0001_0001), .tap_stat(8'h00),
        .tap_cfg_inter(10'd4), .tap_cfg_div(3'd0), .tap_cfg_pairs(5'd4),
        .tap_cfg_hyst_ab(5'd2), .tap_cfg_ablimit(8'd255),
        .tap_cfg_zwidth(4'd5), .tap_cfg_zphase(12'd0), .tap_cfg_uvwph(16'd0),
        .tap_cfg_pol(4'b0000),
        // P7 的七个抽头（v15）：本测试台不测 P7，给固定值 —— 漏接的输入是 z，
        // 会让那一页的通路整片变 X（见 U-17 记录 28）。
        .tap_ofs_s(16'sd0), .tap_ofs_c(16'sd0),
        .tap_gain_s(16'd32768), .tap_gain_c(16'd32768),
        .tap_phase_k(16'sd0), .tap_shift(4'd0), .tap_amp_sq(32'h2000_0000),
        // v21：P7 幅值百分比的门限（本测试台不测 P7，但要给足值免得那条通路出 X）
        .tap_amp_low_sq(32'h170A_3D71), .tap_amp_high_sq(32'h5C28_F5C3),
        .tap_abzen(1'b1), .tap_uwven(1'b1), .tap_calib_busy(1'b0), .tap_biss_crc_err(1'b0), .tap_biss_link_lost(1'b0),
        .tch_diag(160'd0),
        .ui_state(2'd0), .ui_err(4'd0), .ui_dlg(2'd0), .ui_dz_press(1'b0),
        .ui_dz_press2(1'b0), .ui_dlg_kind(1'b0), .ui_rst_state(2'd0), .ui_rst_bad(15'd0),
        .pnl_on(1'b0), .pnl_inter(10'd64), .pnl_prog(6'd0), .pnl_press(4'd0),
        .pnl_fld(1'b0), .pnl_didx(3'd0),
        .pnl_pend(1'b0), .pnl_idx(3'd0), .pnl_undo_avail(1'b0), .pnl_undo_inter(10'd64),
        .pnl_undo_div(3'd0),
        .lcd_rgb(lcd_rgb), .de_o(de_o), .dbg_x(dbg_x), .dbg_y(dbg_y)
    );

    // ================================================ 被测件 ② wave_trace/sram
    reg                tr_frame = 1'b0;
    reg                tr_de    = 1'b1;   // ★ v17：扫描使能（这个单元 tb 里恒 1，见第 7 节末）
    reg signed [15:0]  tr_s = 16'sd0, tr_c = 16'sd0;

    wire        tr_we;
    wire [10:0] tr_waddr;
    wire [31:0] tr_wdata;
    wire [10:0] tr_wr_ptr;
    wire        tr_wr_buf, tr_disp_buf;
    wire [31:0] tr_rdata;

    wave_trace #(.SWEEP_DIV(12'd8), .SWEEP_LEN(11'd4)) u_tr (
        .clk(clk), .rst_n(rst_n), .frame_st(tr_frame), .de(tr_de),
        .s_n(tr_s), .c_n(tr_c),
        .we(tr_we), .waddr(tr_waddr), .wdata(tr_wdata),
        .wr_ptr(tr_wr_ptr), .wr_buf(tr_wr_buf), .disp_buf(tr_disp_buf)
    );
    wave_ram u_tr_ram (
        .clk(clk), .we(tr_we), .waddr(tr_waddr), .wdata(tr_wdata),
        .raddr(11'd0), .rdata(tr_rdata)
    );

    // 抓每一次写：we 只持续一拍，所以必须在当拍就记下来
    integer    n_wr = 0;
    reg [10:0] got_waddr;
    reg [31:0] got_wdata;
    reg [10:0] got_wr_ptr;
    always @(posedge clk) if (tr_we) begin
        got_waddr  <= tr_waddr;
        got_wdata  <= tr_wdata;
        got_wr_ptr <= tr_wr_ptr;
        n_wr       <= n_wr + 1;
    end

    // ------------------------------------------------------------- 计数与断言 --
    integer errors = 0;

    task chk24; input [8*72-1:0] label; input [23:0] got, want;
    begin
        if (got !== want) begin
            errors = errors + 1;
            $display("[FAIL] %0s : got %h want %h", label, got, want);
        end else
            $display("[ OK ] %0s : %h", label, got);
    end
    endtask

    task chk32; input [8*72-1:0] label; input [31:0] got, want;
    begin
        if (got !== want) begin
            errors = errors + 1;
            $display("[FAIL] %0s : got %08h want %08h", label, got, want);
        end else
            $display("[ OK ] %0s : %08h", label, got);
    end
    endtask

    task chki; input [8*72-1:0] label; input integer got, want;
    begin
        if (got !== want) begin
            errors = errors + 1;
            $display("[FAIL] %0s : got %0d want %0d", label, got, want);
        end else
            $display("[ OK ] %0s : %0d", label, got);
    end
    endtask

    // --------------------------------------------------------- 逐点采样像素 --
    //   驱动固定坐标并等够 5 拍：流水线是 2 拍（px1/px2）+ 1 拍输出寄存器，
    //   输入保持不变时 5 拍后 lcd_rgb 一定对应 (px2,py2) == (sx,sy)。
    task smp; input [11:0] sx, sy; output [23:0] col;
    begin
        px = sx; py = sy; de = 1'b1;
        repeat (5) begin @(posedge clk); #1; end
        col = lcd_rgb;
    end
    endtask

    //   ★ 不写成"采样点计数"而是逐点比对，是为了让失败信息能直接指出 x 坐标 ——
    //     列对齐那类 bug 的唯一线索就是"波形整体偏了几个像素"。
    integer xi;
    integer yy;
    reg [23:0] pc;
    integer n_card, n_text;

    // ★ v17：P2 自己也有文字了，所以"整页无墨点"这条断言必须换成
    //   "P1 的文字行上没有墨点"。下面这张表就是 P1 文字所在的 y：
    //   六条标签格行（每格 16 px，取行中）加两条大数字格区（32x64 格，取行中）。
    //   P2 自己的文字在 lab 行 0/9/23/36 与这八条 y 都不相交。
    integer r_;
    integer p1_text_y [0:7];
    initial begin
        p1_text_y[0] = 5*16  + 8;    // lab 行 5 「输入频率 / 倍频分频 / 转速」
        p1_text_y[1] = 13*16 + 8;    // lab 行 13 「HZ / 等效倍率 / RPM」
        p1_text_y[2] = 15*16 + 8;    // lab 行 15 「边沿率 4X倍频XF」
        p1_text_y[3] = 22*16 + 8;    // lab 行 22 「角度 / 累计转数 / ABZ/UVW」
        p1_text_y[4] = 33*16 + 8;    // lab 行 33 「DEG / REV」
        p1_text_y[5] = 35*16 + 8;    // lab 行 35 「方向 CCW / Z计数」
        p1_text_y[6] = 2*64  + 32;   // val 行 2 的六格大数字（y 128..191）
        p1_text_y[7] = 7*64  + 32;   // val 行 7 的六格大数字（y 448..511）
    end

    // 预置显示面（buf=1）的第 100 列与第 500 列，并把 tracer 的 disp_buf 强置为 1。
    //   {A_hi, A_lo, B_hi, B_lo}
    task force_disp_buf_and_preload;
    begin
        u_dut.u_wave_trace.disp_buf = 1'b1;
        // 第 100 列：A 只占第 50 行，B 只占第 150 行
        u_dut.u_wave_ram.mem[11'h400 | 11'd100] = {8'd50, 8'd50, 8'd150, 8'd150};
        // 第 500 列：A 只占第 0 行，B 保持第 99 行 —— 空出中线那一行
        u_dut.u_wave_ram.mem[11'h400 | 11'd500] = {8'd0, 8'd0, 8'd99, 8'd99};
    end
    endtask

    // 一列一行：在一段 x 区间里找某个颜色第一次出现的位置
    integer found_x;
    task find_col; input [11:0] y; input [23:0] want; input [11:0] xa, xb;
    begin
        found_x = -1;
        for (xi = xa; xi <= xb; xi = xi + 1) begin
            smp(xi[11:0], y, pc);
            if (pc === want && found_x < 0) found_x = xi;
        end
    end
    endtask

    initial begin
        // ------------------------------------------------------------- 复位 --
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4)  @(posedge clk);
        #1;

        // ===================================================== 第 1 节：列对齐
        //   预置第 100 列：A 通道线段只占通道内第 50 行、B 通道只占第 150 行。
        //   它们必须出现在 x = 80 + 100 = 180 上。
        //   ★ 这一节测的是**组合映射**（位图第 100 列 ↔ 屏上 x=180），**测不到管线
        //     级数**：smp() 把 pix_x 停在一点上再读，数据通路无论几级都会收敛到同一个
        //     值。级数只能用**移动光栅**测 —— 见 disp/tb_pipe_align.v（U-16 那轮
        //     就是靠它才发现 v15 的波形和点阵各多补了一级、整块右移 1 px）。
        force_disp_buf_and_preload;

        find_col(12'd190, C_TR_A, 12'd170, 12'd190);   // A: y = 140+50
        chki("A 轨迹落在第 100 列 (x=180)", found_x, 180);

        find_col(12'd510, C_TR_B, 12'd170, 12'd190);   // B: y = 360+150
        chki("B 轨迹落在第 100 列 (x=180)", found_x, 180);

        // 同一列上、线段之外的行必须是轨迹区底色（探针不能被拉宽）
        smp(12'd180, 12'd191, pc);
        chk24("A 线段下端之外是轨迹区底", pc, C_PLOT);
        smp(12'd180, 12'd190 - 12'd1, pc);
        chk24("A 线段上端之外是轨迹区底", pc, C_PLOT);

        // =============================================== 第 2 节：框 / 中线 / 区底
        smp(12'd500, 12'd200, pc);
        chk24("A 区内部底色", pc, C_PLOT);
        smp(12'd500, 12'd420, pc);
        chk24("B 区内部底色", pc, C_PLOT);
        smp(12'd80,  12'd200, pc);
        chk24("框左沿", pc, C_GRID);
        smp(12'd1023, 12'd200, pc);
        chk24("框右沿", pc, C_GRID);
        smp(12'd500, 12'd140, pc);
        chk24("A 区上沿", pc, C_GRID);
        smp(12'd500, 12'd559, pc);
        chk24("B 区下沿", pc, C_GRID);
        // 两区之间的空隙既不属于 A 也不属于 B ⇒ 页面底，不是轨迹区底
        smp(12'd500, 12'd350, pc);
        chk24("A/B 之间是页面底（不是轨迹区底）", pc, C_BG);
        // 中线：第 500 列预置成 A 通道第 0 行，于是第 99 行空出来，能看到网格色
        smp(12'd580, 12'd239, pc);                     // x=580 → 第 500 列
        chk24("中线（第 500 列 A 通道第 99 行）", pc, C_GRID);
        smp(12'd580, 12'd140, pc);
        chk24("预置第 0 行的轨迹", pc, C_TR_A);

        // ============================ 第 3/4 节：P2 上的文字（v17 改）
        //   v17 之前 P2 整页**不画文字**（disp_engine 的 txt_page 把 page 1/2/3 排除在外），
        //   这一节原本断言"一个墨点都没有"。现在 P2 有自己的 lab 平面
        //   （页标题 / A SIN / B COS / 底栏 "等效采样 100US"），改成三条：
        //     ① P1 的卡片白底仍然一个都不许有（不变）；
        //     ② P2 自己的通道标注**必须在**（在 A SIN 那一行数墨点）；
        //     ③ P1 的文字行上一个墨点都不许有 —— lab 平面漏接的指纹：
        //        平面选的若还是 P1，"输入频率 / HZ / 角度 / DEG" 就会出现在这里。
        //   P2 自己的文字行（lab 0/9/23/36）与 ③ 的八条 y 不相交，所以不会误伤。
        n_card = 0;
        for (yy = 64; yy < 600; yy = yy + 76) begin
            for (xi = 80; xi <= 1023; xi = xi + 1) begin
                smp(xi[11:0], yy[11:0], pc);
                if (pc === C_CARD) n_card = n_card + 1;
            end
        end
        chki("P2 轨迹区里没有 P1 的卡片白底 (FFFFFF)", n_card, 0);

        //   ② A SIN 标注：lab 行 9（y 144..159）、列 6 起（x 96..191）
        n_text = 0;
        for (yy = 144; yy <= 159; yy = yy + 1)
            for (xi = 96; xi <= 191; xi = xi + 1) begin
                smp(xi[11:0], yy[11:0], pc);
                if (pc === C_TEXT) n_text = n_text + 1;
            end
        chki("P2 的 A SIN 通道标注画出来了（墨点数不为 0）", (n_text > 0), 1);

        //   ③ P1 文字行的漏接指纹（在 P1 有字的列上采样，断言 P2 上没有那些墨点）
        //   ★ v18：第 35 格行只能采第一个窗口。P2 自己在这一行画了四枚徽标的
        //     标签（列 28..33 / 38..41 / 48..52 / 58..62，见 gen_text_ram.py 的
        //     P2_LAB），其中第一枚（列 28..33）压在第二窗口（列 26..29）上、
        //     第三枚（列 48..52）压在第三窗口（列 46..49）上。
        //     P1 在第 35 行只有 "方向 CCW"（列 6..13）与 "Z计数"（列 26..28），
        //     而 P2 的徽标标签是**本页自己的文字**、不是"P1 漏接"，所以第二、
        //     三窗口在那一行没有判据价值，跳过不损失什么。
        n_text = 0;
        for (r_ = 0; r_ < 8; r_ = r_ + 1) begin
            for (xi = 96;  xi <= 159; xi = xi + 2) begin
                smp(xi[11:0], p1_text_y[r_], pc);
                if (pc === C_TEXT) n_text = n_text + 1;
            end
            if (r_ != 5) begin
                for (xi = 416; xi <= 479; xi = xi + 2) begin
                    smp(xi[11:0], p1_text_y[r_], pc);
                    if (pc === C_TEXT) n_text = n_text + 1;
                end
                for (xi = 736; xi <= 799; xi = xi + 2) begin
                    smp(xi[11:0], p1_text_y[r_], pc);
                    if (pc === C_TEXT) n_text = n_text + 1;
                end
            end
        end
        chki("P1 的文字行在 P2 上一个墨点都没有（lab 平面漏接指纹）", n_text, 0);

        // ==================================================== 第 5 节：导航高亮
        smp(12'd8, 12'd100, pc);       // 第 0 项「总览」
        chk24("P2 上导航第 0 项未选中", pc, C_NAV);
        smp(12'd8, 12'd160, pc);       // 第 1 项「波形」
        chk24("P2 上导航第 1 项已选中", pc, C_SEC);

        // ========================================== 第 6 节：未预置列 = 居中直线
        //   缓冲的初值是四个字节 99 —— "还没采到样本"在屏上是**两条居中直线**，
        //   不是贴顶的直线（贴顶会被误读成信号削顶）。
        smp(12'd300, 12'd239, pc);     // 第 220 列，A 通道第 99 行
        chk24("未预置列画的是 A 通道居中直线", pc, C_TR_A);
        smp(12'd300, 12'd459, pc);     // 第 220 列，B 通道第 99 行
        chk24("未预置列画的是 B 通道居中直线", pc, C_TR_B);

        // ================================================ 第 7 节：采样器几何
        de = 1'b0;
        tr_s = 16'sd0; tr_c = 16'sd0;
        tr_frame = 1'b1; @(posedge clk); #1; tr_frame = 1'b0;   // 换面 + 归零
        chki("帧首后列指针归零", tr_wr_ptr, 0);
        chki("帧首后写面翻转", {31'd0, tr_wr_buf}, 1);

        n_wr = 0;
        repeat (8 * 5) @(posedge clk); #1;                       // 放 5 列的时间
        //   5 列里只有 SWEEP_LEN(=4) 列会真写：写满是**停手**，不是回卷。
        chki("写满 SWEEP_LEN 即停（5 列时间只写 4 列）", n_wr, 4);
        chk32("第 4 列数据 = 中线各字节 99", got_wdata, 32'h6363_6363);
        chki("最后一次写的列号 = SWEEP_LEN-1", got_waddr[9:0], 3);
        chki("最后一次写落在写面 buf=1", got_waddr[10], 1);

        // ---- 线段上下沿 + 钳位 ----
        //   SWEEP_DIV=8 ⇒ 每 10 拍正好推进一列（写发生在第 8/9 拍，监视器在第 10 拍记下）。
        tr_frame = 1'b1; @(posedge clk); #1; tr_frame = 1'b0;
        n_wr = 0;
        tr_s = 16'sd2560;                                       // >>>8 = 10 → 行 89
        repeat (10) @(posedge clk); #1;
        chk32("第 0 列：从 99 到 89 的线段", got_wdata, 32'h6359_6363);
        tr_s = 16'h7FFF;                                        // +32767 → 钳到第 0 行
        repeat (10) @(posedge clk); #1;
        chk32("第 1 列：正溢出钳到第 0 行（与第 89 行连成线段）", got_wdata, 32'h5900_6363);
        tr_s = 16'h8000;                                        // -32768 → 钳到第 199 行
        repeat (10) @(posedge clk); #1;
        chk32("第 2 列：负溢出钳到第 199 行（与第 0 行连成线段）", got_wdata, 32'hC700_6363);

        // ---- 双缓冲：换面必须发生在扫描之间，且写面数据不会被显示面看到 ----
        tr_frame = 1'b1; @(posedge clk); #1; tr_frame = 1'b0;
        chki("换面：disp_buf 取到换面前写面的值 0", {31'd0, tr_disp_buf}, 0);
        chki("换面：写面翻到 1", {31'd0, tr_wr_buf}, 1);
        chki("换面同时列指针归零", tr_wr_ptr, 0);

        // ---- v17：扫描必须门控在 de 上（消隐期一列都不许推进）----
        //   上板照片上 x 80..447 那条平线就是"消隐期也每 128 拍写一列、
        //   而样本在消隐期是冻结的"造成的。这一节把 de=0 的那段时间钉死。
        //   ⚠ 计数用的监视器在 we 的**下一拍**才记数（we 只持续一拍，监视器是
        //     寄存的），所以"写一列"要在 8 个可见拍之后再等 1 拍才数得到 ——
        //     第一版只等 8 拍，把自己写成了 off-by-one（U-21 记录）。
        tr_frame = 1'b1; @(posedge clk); #1; tr_frame = 1'b0;
        n_wr  = 0;
        tr_de = 1'b0;
        repeat (8 * 5) @(posedge clk); #1;                       // 放 5 列的时间，但 de=0
        chki("de=0 期间一列都不写", n_wr, 0);
        chki("de=0 期间列指针不动", tr_wr_ptr, 0);
        tr_de = 1'b1;
        n_wr  = 0;
        repeat (8 + 1) @(posedge clk); #1;                       // 8 个可见拍写一列，第 9 拍计数
        chki("de 回 1 后 8 个可见拍写一列", n_wr, 1);
        chki("de 回 1 后列指针走到 1", tr_wr_ptr, 1);
        chki("de 门控后写的是第 0 列", got_waddr[9:0], 0);

        // ------------------------------------------------------------- 收尾 --
        repeat (20) @(posedge clk);
        if (errors == 0)
            $display("TEST PASSED: 0 errors");
        else
            $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
