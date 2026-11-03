//=============================================================================
// disp/tb_p3_page.v —— P3 李萨如 XY 页的端到端验证（v16）
//-----------------------------------------------------------------------------
//   一个顶层里放两组被测件：
//     ① disp_engine（page=2）—— 验**屏上的像素**：点阵落点与列对齐、方框、
//        中心十字、绘图区底色，以及"P3 上不该出现的两样东西"（P1 的卡片白底、
//        P1 的文字）；
//     ② xy_plot + xy_ram —— 验**几何的产出**：整面清零的拍数、坐标映射与钳位、
//        y 轴取反、双缓冲换面。
//
//   ★ 本测试台的第 1 节是「列对齐」：预置**位图第 50 列**（覆盖屏上
//     x = 320 + 2*50 = 420..421），再去 x 轴上找它到底从哪一列开始。
//     位图格是 2x2 屏上像素，所以"偏 1 px"改的是**起始列**而不是中心。
//
//   ★ 但要说清楚它测**不到**什么：smp()/find_col() 都是把 pix_x 停在一点上再读，
//     数据通路无论几级寄存都会收敛到同一个值 ⇒ **管线级数测不出来**。级数只能用
//     **移动光栅**测，见 disp/tb_pipe_align.v（U-16 那轮就是靠它才发现 v15 的
//     点阵多补了一级、整张图右移 1 px，而本测试台一直是绿的）。
//
//   ★ 预置数据写在**显示面**（face=1）并把描点器的 disp_buf / wr_buf 都 force 住
//     （disp_buf=1、wr_buf=0），于是描点器只擦/画 face=0，读只读 face=1，读写
//     完全不碰面。这是双缓冲的直接好处：测试不需要和描点器抢内存，也就不需要为了
//     "让测试稳定"去关掉描点器 —— 那种"关掉被测逻辑再测"的做法会让测试台自己
//     变成最大的未测部分。
//     这里用 force 而不是 tb_p2_page.v 里的普通赋值：描点器每个 frame_st 都会
//     非阻塞地改写这两个 reg，普通赋值会被它覆盖回去。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_p3_page;

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

    // ------------------------------------------------------------- 时钟复位 --
    reg clk = 1'b0;
    always #10 clk = ~clk;          // 50 MHz

    reg rst_n = 1'b0;

    // ======================================================= 被测件 ① disp_engine
    reg  [2:0]  page = 3'd2;        // P3 李萨如 XY
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
        // v22 面板端口：本页台子不测面板，全部绑不激活值
        .pnl_on(1'b0), .pnl_inter(10'd64), .pnl_prog(6'd0), .pnl_press(4'd0),
        .pnl_fld(1'b0), .pnl_didx(3'd0),
        .pnl_pend(1'b0), .pnl_idx(3'd0), .pnl_undo_avail(1'b0), .pnl_undo_inter(10'd64),
        .pnl_undo_div(3'd0),
        .lcd_rgb(lcd_rgb), .de_o(de_o), .dbg_x(dbg_x), .dbg_y(dbg_y)
    );

    // ================================================ 被测件 ② xy_plot / xy_ram
    //   SAMPLE_DIV 调小到 4，好让一个测试用例里能打上很多个点。
    reg               pl_frame = 1'b0;
    reg signed [15:0] pl_s = 16'sd0, pl_c = 16'sd0;

    wire        pl_we;
    wire [16:0] pl_waddr;
    wire        pl_wdata;
    wire        pl_wr_buf, pl_disp_buf;
    wire        pl_rdata;

    xy_plot #(.SAMPLE_DIV(8'd4)) u_pl (
        .clk(clk), .rst_n(rst_n), .frame_st(pl_frame),
        .s_n(pl_s), .c_n(pl_c),
        .we(pl_we), .waddr(pl_waddr), .wdata(pl_wdata),
        .wr_buf(pl_wr_buf), .disp_buf(pl_disp_buf)
    );
    xy_ram u_pl_ram (
        .clk(clk), .we(pl_we), .waddr(pl_waddr), .wdata(pl_wdata),
        .raddr(17'd0), .rdata(pl_rdata)
    );

    // 抓每一次写：we 只持续一拍，必须在当拍记下来。
    //   清零写 wdata=0、打点写 wdata=1 —— 用 wdata 区分两种写，不需要另加端口。
    integer    n_clr = 0, n_dot = 0;
    reg [16:0] first_clr_addr;
    reg [7:0]  first_bx, first_by;
    reg [7:0]  last_bx,  last_by;
    reg        last_f;
    always @(posedge clk) if (pl_we) begin
        if (pl_wdata) begin
            if (n_dot == 0) begin
                first_bx <= pl_waddr[7:0];
                first_by <= pl_waddr[15:8];
            end
            last_bx <= pl_waddr[7:0];
            last_by <= pl_waddr[15:8];
            last_f  <= pl_waddr[16];
            n_dot   <= n_dot + 1;
        end else begin
            if (n_clr == 0) first_clr_addr <= pl_waddr;
            n_clr <= n_clr + 1;
        end
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

    integer xi, yy;
    reg [23:0] pc;
    integer n_card, n_text;

    // 预置**显示面**（face=1）：位图 192x192，格 (bx,by) 覆盖屏上
    //   x = 320 + 2*bx .. +1，y = 178 + 2*by .. +1
    //   放三格：中心偏一点的一格用来验列对齐，另外两格验位图四角。
    task force_disp_face_and_preload;
    begin
        force u_dut.u_xy_plot.disp_buf = 1'b1;
        force u_dut.u_xy_plot.wr_buf   = 1'b0;
        u_dut.u_xy_ram.mem[{1'b1, 8'd70,  8'd50 }] = 1'b1;   // 屏上 x 420..421, y 318..319
        u_dut.u_xy_ram.mem[{1'b1, 8'd0,   8'd0  }] = 1'b1;   // 屏上 (320,178)
        u_dut.u_xy_ram.mem[{1'b1, 8'd191, 8'd191}] = 1'b1;   // 屏上 (702,560)
    end
    endtask

    // 一行上找某个颜色第一次出现的 x
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

    // 换一组样本，等够若干拍让描点器打上至少一个点
    task set_sample; input signed [15:0] s, c;
    begin
        @(negedge clk);
        pl_s = s; pl_c = c;
        repeat (8) @(posedge clk);
    end
    endtask

    initial begin
        // ------------------------------------------------------------- 复位 --
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4)  @(posedge clk);
        #1;

        // ===================================================== 第 1 节：列对齐
        //   位图第 50 列 -> 屏上 x = 320 + 2*50 = 420（占 420..421）。
        //   级数不对会变成 419（早一拍）或 421（晚一拍）。
        force_disp_face_and_preload;

        find_col(12'd318, C_ACC, 12'd410, 12'd430);      // y = 178 + 2*70
        chki("点阵第 50 列起点落在 x=420", found_x, 420);

        smp(12'd421, 12'd319, pc);
        chk24("格 (50,70) 的右下角也是轨迹色", pc, C_ACC);
        smp(12'd419, 12'd318, pc);
        chk24("格 (50,70) 左侧一格是绘图区底", pc, C_PLOT);
        smp(12'd422, 12'd318, pc);
        chk24("格 (50,70) 右侧一格是绘图区底", pc, C_PLOT);

        // ================================================= 第 2 节：方框 / 十字
        smp(12'd232, 12'd300, pc);
        chk24("方框左沿 x=232 是网格色", pc, C_GRID);
        smp(12'd791, 12'd300, pc);
        chk24("方框右沿 x=791 是网格色", pc, C_GRID);
        smp(12'd400, 12'd140, pc);
        chk24("方框上沿 y=140 是网格色", pc, C_GRID);
        smp(12'd400, 12'd599, pc);
        chk24("方框下沿 y=599 是网格色", pc, C_GRID);

        smp(12'd512, 12'd300, pc);
        chk24("中心竖线 x=512 是网格色", pc, C_GRID);
        smp(12'd400, 12'd370, pc);
        chk24("中心横线 y=370 是网格色", pc, C_GRID);

        // ========================================= 第 3 节：框内 / 点阵区底 / 越界
        smp(12'd240, 12'd300, pc);
        chk24("框内、点阵区外是绘图区底", pc, C_PLOT);
        smp(12'd400, 12'd300, pc);
        chk24("点阵区内、没打点的格子是绘图区底", pc, C_PLOT);
        smp(12'd319, 12'd300, pc);
        chk24("点阵区左界外一像素是绘图区底", pc, C_PLOT);
        smp(12'd704, 12'd300, pc);
        chk24("点阵区右界外一像素是绘图区底", pc, C_PLOT);
        smp(12'd400, 12'd177, pc);
        chk24("点阵区上界外一像素是绘图区底", pc, C_PLOT);
        smp(12'd400, 12'd562, pc);
        chk24("点阵区下界外一像素是绘图区底", pc, C_PLOT);

        smp(12'd320, 12'd178, pc);
        chk24("位图 (0,0) 格左上角是轨迹色", pc, C_ACC);
        smp(12'd702, 12'd560, pc);
        chk24("位图 (191,191) 格左上角是轨迹色", pc, C_ACC);

        smp(12'd200, 12'd300, pc);
        chk24("方框外仍是页面底色", pc, C_BG);

        // ============================ 第 4 节：P3 上不该有 P1 的卡片与文字
        n_card = 0; n_text = 0;
        for (yy = 0; yy < 8; yy = yy + 1) begin
            for (xi = 80; xi <= 1023; xi = xi + 1) begin
                smp(xi[11:0], ((64 + 76*yy) > 599) ? 12'd599 : (64 + 76*yy), pc);
                if (pc === C_CARD) n_card = n_card + 1;
                if (pc === C_TEXT) n_text = n_text + 1;
            end
        end
        chki("P3 上没有任何 P1 卡片白底像素", n_card, 0);
        chki("P3 上没有任何 P1 文字像素", n_text, 0);

        //   ★ v17：P3 自己也有文字了（页标题 + 轴标 "Y"/"X"）。上面那次全行扫
        //     恰好扫不到 P3 自己的字（它的字在 lab 行 10 与 36，扫的是 64+76k），
        //     所以这里补一条**正面**断言：点阵里必须有字。
        //     栅格换算：lab 行 10 列 17 -> x 272..287、y 160..175。
        n_text = 0;
        for (yy = 160; yy <= 175; yy = yy + 1)
            for (xi = 272; xi <= 287; xi = xi + 1) begin
                smp(xi[11:0], yy[11:0], pc);
                if (pc === C_TEXT) n_text = n_text + 1;
            end
        chki("P3 的 Y 轴标画出来了（墨点数不为 0）", (n_text > 0), 1);

        // ==================================================== 第 5 节：导航高亮
        smp(12'd8, 12'd236, pc);
        chk24("P3 上导航第 2 项「XY」高亮", pc, C_SEC);
        smp(12'd8, 12'd100, pc);
        chk24("P3 上导航第 0 项未高亮", pc, C_NAV);
        smp(12'd8, 12'd580, pc);
        chk24("P3 上导航第 5 项未高亮", pc, C_NAV);

        // ============================================ 第 6 节：描点器的产出
        //   换面：复位后 wr_buf=0 / disp_buf=0；打一次 frame_st 之后
        //   disp_buf 取上一轮的 wr_buf（=0），wr_buf 翻成 1。
        chki("复位后 wr_buf = 0", pl_wr_buf, 0);
        chki("复位后不进清零相（没有任何一次写）", n_clr + n_dot, 0);
        @(negedge clk); pl_frame = 1'b1;
        @(negedge clk); pl_frame = 1'b0;
        @(posedge clk); #1;
        chki("帧首后 wr_buf 翻成 1", pl_wr_buf, 1);
        chki("帧首后 disp_buf 取到上一轮的 wr_buf", pl_disp_buf, 0);

        //   整面清零：一次 65536 个地址，一拍一个，且必须全落在**新写面**（face=1）。
        repeat (70000) @(posedge clk);
        chki("一次 frame_st 触发 65536 次清零写", n_clr, 65536);
        chki("第一次清零写落在新写面 (face=1)", first_clr_addr[16], 1);
        chki("清零写从地址 0 开始", first_clr_addr[15:0], 0);
        if (n_dot < 1) begin
            errors = errors + 1;
            $display("[FAIL] 清面之后一个点都没打（n_dot=%0d）", n_dot);
        end else
            $display("[ OK ] 清面之后开始打点，n_dot=%0d", n_dot);
        chki("第一个点落在位图中心 (96,96)", {first_by, first_bx}, 16'h6060);
        chki("打点落在新写面 (face=1)", last_f, 1);

        //   坐标映射与钳位（SAMPLE_DIV=4，稳 8 拍足够覆盖一整轮采样）
        set_sample(16'sd0, 16'sd0);
        chki("s=0,c=0 -> bx=96", last_bx, 96);
        chki("s=0,c=0 -> by=96", last_by, 96);

        set_sample(16'sd32767, 16'sd32767);
        chki("s 正满量程钳到 bx=191", last_bx, 191);
        chki("c 正满量程钳到 by=0（y 轴取反）", last_by, 0);

        set_sample(-16'sd32768, -16'sd32768);
        chki("s 负满量程钳到 bx=0", last_bx, 0);
        chki("c 负满量程钳到 by=191（y 轴取反）", last_by, 191);

        //   非对称的一对，好让 bx / by 取到**不同**的值：
        //   s = 2560  -> rx = 96 + (2560>>>8 = 10)  = 106
        //   c = -5120 -> ry = 96 - (-5120>>>8 = -20) = 116
        set_sample(16'sd2560, -16'sd5120);
        chki("s=2560 -> bx=106（>>>8 加中心）", last_bx, 106);
        chki("c=-5120 -> by=116（>>>8 后取反再加中心）", last_by, 116);

        //   第二次 frame_st：再翻一次面
        @(negedge clk); pl_frame = 1'b1;
        @(negedge clk); pl_frame = 1'b0;
        @(posedge clk); #1;
        chki("第二次帧首后 wr_buf 翻回 0", pl_wr_buf, 0);
        chki("第二次帧首后 disp_buf 取到 1", pl_disp_buf, 1);

        // ------------------------------------------------------------- 结算 --
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #40_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule

`default_nettype wire
