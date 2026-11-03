//=============================================================================
//  disp/tb_p5_page.v  --  P5「六状态表 + 驻留统计」自检
//
//  一个顶层放两个被测件：
//    ① disp_engine（page = 3'd4）—— 验屏上的东西：条形图列的几何与填充、
//       文字层的页门（P5 不该出现卡片框/图表底色）、导航高亮落在第 4 项；
//    ② 小参数的 p5_view #(.WIN_FRAMES(3)) + **真正的 p5_lab_ram** —— 验
//       格式化结果本身：计数窗口、8 个字段的字符、条形图阈值。
//       小参数是为了让"窗口关门"在几十拍内发生，而不是 64 帧（1.1 s）。
//
//  ★ 采样规则与其它显示测试台一致：把 pix_x/pix_y 停住 ≥5 拍再读 lcd_rgb，
//    这样读到的是**组合映射**（"哪一格该亮"），与管线级数无关。
//    级数由 disp/tb_pipe_align.v 用移动光栅单独把关。
//
//  一条容易搞错的判据：C_TRACK 与 C_NAV 都是 24'hDCE9F5、C_ACC 与 C_TR_A
//  都是 24'h2E7DD1。这不是笔误 —— 条形图的空槽刻意沿用导航未选中的底色，
//  填充刻意沿用主强调色。P5 页上不会同时出现导航底色与条形区（y 不同段），
//  所以不会互相干扰。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_p5_page;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;

    // ---- 像素接口 ----
    reg  [11:0] px = 12'd0;
    reg  [11:0] py = 12'd0;
    reg         de = 1'b0;

    wire [23:0] lcd_rgb;
    wire        de_o;
    wire [11:0] dbg_x, dbg_y;

    // ---- 色板（与 disp/disp_engine.v 的 localparam 一一对应）----
    localparam [23:0] C_BG    = 24'hEAF3FB;
    localparam [23:0] C_CARD  = 24'hFFFFFF;
    localparam [23:0] C_GRID  = 24'hD6E3F0;
    localparam [23:0] C_ACC   = 24'h2E7DD1;
    localparam [23:0] C_SEC   = 24'h8FC4EC;
    localparam [23:0] C_NAV   = 24'hDCE9F5;
    localparam [23:0] C_TEXT  = 24'h1F2D3D;
    localparam [23:0] C_BLACK = 24'h000000;
    localparam [23:0] C_PLOT  = 24'hF7FBFF;
    localparam [23:0] C_TRACK = 24'hDCE9F5;

    // ---- P5 版面（与 disp/disp_engine.v 的 localparam 同源，v30 重排）----
    //   spec 4.4：6 行 x 5 列、行高 30、列宽 188，含占比条形图列。
    localparam [11:0] TX0     = 12'd82;     // 表格左沿（列 0 左边界）
    localparam [11:0] TY0     = 12'd128;    // 表头上沿
    localparam [11:0] TX1     = 12'd1022;   // 右开区间：82 + 5*188
    localparam [11:0] TY1     = 12'd338;    // 下开区间：128 + 7*30
    localparam [11:0] ROW_H   = 12'd30;     // 行高（spec）
    localparam [11:0] BAR_X0  = 12'd836;    // 第 5 列里比例条槽的起点
    localparam [11:0] BAR_X1  = 12'd1020;   // 右开区间：836 + 184

    integer errors = 0;

    disp_engine u_dut (
        .clk(clk), .rst_n(rst_n), .page(3'd4),
        .pix_x(px), .pix_y(py), .de(de),
        .tap_angle(16'h2000), .tap_s_n(16'h0A00), .tap_c_n(16'h0500),
        .tap_pos_full(32'h0000_1234),
        .tap_io_state(8'b0000_0100), .tap_io_flags(8'h00), .tap_stat(8'h00),
        .tap_cfg_inter(10'd64), .tap_cfg_div(3'd0), .tap_cfg_pairs(5'd4),
        .tap_cfg_hyst_ab(5'd2), .tap_cfg_ablimit(8'd255), .tap_cfg_zwidth(4'd5),
        .tap_cfg_zphase(12'd0), .tap_cfg_uvwph(16'd0), .tap_cfg_pol(4'b0000),
        // P7 的七个抽头（v15）：本测试台不测 P7，给固定值 —— Verilog-2001 漏接的
        // 输入是 z，会让那一页的通路整片变 X（见 U-17 记录 28）。
        .tap_ofs_s(16'sd0), .tap_ofs_c(16'sd0),
        .tap_gain_s(16'd32768), .tap_gain_c(16'd32768),
        .tap_phase_k(16'sd0), .tap_shift(4'd0), .tap_amp_sq(32'h2000_0000),
        // v21：P7 幅值百分比的门限（本测试台不测 P7，但要给足值免得那条通路出 X）
        .tap_amp_low_sq(32'h170A_3D71), .tap_amp_high_sq(32'h5C28_F5C3),
        .tap_abzen(1'b1), .tap_uwven(1'b1), .tap_calib_busy(1'b0), .tap_biss_crc_err(1'b0), .tap_biss_link_lost(1'b0),
        .tch_diag(160'd0), .ui_state(2'd0), .ui_err(4'd0), .ui_dlg(2'd0), .ui_dz_press(1'b0),
        .ui_dz_press2(1'b0), .ui_dlg_kind(1'b0), .ui_rst_state(2'd0), .ui_rst_bad(15'd0),
        .pnl_on(1'b0), .pnl_inter(10'd64), .pnl_prog(6'd0), .pnl_press(4'd0),
        .pnl_fld(1'b0), .pnl_didx(3'd0),
        .pnl_pend(1'b0), .pnl_idx(3'd0), .pnl_undo_avail(1'b0), .pnl_undo_inter(10'd64),
        .pnl_undo_div(3'd0),
        .lcd_rgb(lcd_rgb), .de_o(de_o), .dbg_x(dbg_x), .dbg_y(dbg_y)
    );

    // =====================================================================
    // 被测件 ②：小窗口的 p5_view + 真正的 p5_lab_ram
    // =====================================================================
    reg         pv_fst = 1'b0;      // 手动的"帧首一拍"
    reg  [2:0]  pv_uvw = 3'd1;
    wire        pv_we;
    wire [11:0] pv_waddr;
    wire [7:0]  pv_wdata;
    wire        pv_busy, pv_done;
    // v30：条形图阈值量程改成 0..183 px（第 5 列里的槽长 184 px），所以是 8 bit
    wire [7:0]  pv_t0, pv_t1, pv_t2, pv_t3, pv_t4, pv_t5;
    wire [7:0]  pv_rdata;

    p5_view #(.WIN_FRAMES(6'd3)) u_pv (
        .clk(clk), .rst_n(rst_n), .start(pv_fst), .uvw(pv_uvw),
        .sig_bad(1'b0),         // v50（㊼）：单元台默认非空态（空态判据见下一轮）
        .we(pv_we), .waddr(pv_waddr), .wdata(pv_wdata),
        .busy(pv_busy), .done(pv_done),
        .bar_t0(pv_t0), .bar_t1(pv_t1), .bar_t2(pv_t2),
        .bar_t3(pv_t3), .bar_t4(pv_t4), .bar_t5(pv_t5)
    );

    p5_lab_ram u_pram (
        .clk(clk), .we(pv_we), .waddr(pv_waddr), .wdata(pv_wdata),
        .raddr(12'd0), .rdata(pv_rdata)
    );

    // =====================================================================
    // 通用任务
    // =====================================================================
    task chk24;
        input [8*72-1:0] label;
        input [23:0]     got, want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : got %h want %h", label, got, want);
            end else begin
                $display("[ OK ] %0s : %h", label, got);
            end
        end
    endtask

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

    // 把像素坐标停住 ≥5 拍再读
    task smp;
        input  [11:0] sx, sy;
        output [23:0] col;
        begin
            @(negedge clk);
            px = sx; py = sy; de = 1'b1;
            repeat (5) @(posedge clk);
            #1;
            col = lcd_rgb;
        end
    endtask

    // ---- lab 文字层的格子回读 ----
    //   ★ v24 修：这里必须返回 8 bit。旧版是 [6:0]，而 RAM 每格 8 bit，
    //     汉字码 >= 128 被截成 7 bit 之后永远对不上（表现为"汉字标签全印成空格"）。
    function [7:0] rdcell;
        input [5:0] r, c;
        begin
            rdcell = u_pram.mem[{r, 6'd0} + {6'd0, c}];
        end
    endfunction

    task chk_cell;
        input [5:0] r, c;
        input [7:0] want;
        begin
            if (rdcell(r, c) !== want) begin
                errors = errors + 1;
                $display("[FAIL] lab cell (%0d,%0d) = %0d want %0d", r, c, rdcell(r, c), want);
            end
        end
    endtask

    // 把一段格子打成可读文本（0=空格 1='.' 8..17='0'..'9' 18+='A'+）
    task show_fld;
        input [5:0] r, c0;
        input integer w;
        integer k;
        reg [7:0] ch;
        begin
            $write("        lab(%0d,%0d..%0d) = \"", r, c0, c0 + w - 1);
            for (k = 0; k < w; k = k + 1) begin
                ch = rdcell(r, c0 + k);
                if      (ch == 7'd0)                 $write(" ");
                else if (ch == 7'd1)                 $write(".");
                else if (ch >= 7'd8 && ch <= 7'd17)  $write("%c", 8'd48 + (ch - 7'd8));
                else                                 $write("%c", 8'd65 + (ch - 7'd18));
            end
            $write("\"\n");
        end
    endtask

    // ★ 等渲染空闲。一轮渲染约 450 拍（8 个字段 x（40 拍除法 + 10 拍双 dabble
    //   + 5 拍写）），而 p5_view 只在 S_IDLE 认 start ⇒ 上一轮没跑完就发下一个
    //   start，那个脉冲会被**丢掉**，而正在跑的那一轮会读到新改的 snap
    //   （已渲完的字段用旧值、未渲到的用新值）—— 实测表现就是
    //   "字段 0/1 渲成 0.0，而字段 6 渲成 90.0"。
    task pv_wait_idle;
        integer k;
        begin
            for (k = 0; (k < 4000) && pv_busy; k = k + 1) @(posedge clk);
        end
    endtask

    // 手动帧首脉冲（两个 negedge，保证被 posedge 采到一次）
    task pv_frame;
        begin
            pv_wait_idle;
            @(negedge clk); pv_fst = 1'b1;
            @(negedge clk); pv_fst = 1'b0;
        end
    endtask

    // 等渲染完成。★ 不用 wait(done)：done 只高**一拍**，而 wait 的求值时机
    // 取决于仿真器的事件调度，容易刚好错过 —— 逐拍轮询没有这个风险。
    task pv_wait_done;
        integer k;
        begin
            for (k = 0; (k < 4000) && !pv_done; k = k + 1) @(posedge clk);
            if (!pv_done) begin
                errors = errors + 1;
                $display("[FAIL] p5_view 渲染没在 4000 拍内完成");
            end
        end
    endtask

    // ---- 整行扫描计数 ----
    integer n_card, n_plot, n_text, n_track, n_acc;
    task scan_row;
        input [11:0] sy;
        input [11:0] xa, xb;
        integer x;
        reg [23:0] col;
        begin
            n_card = 0; n_plot = 0; n_text = 0; n_track = 0; n_acc = 0;
            for (x = xa; x <= xb; x = x + 1) begin
                smp(x[11:0], sy, col);
                if (col === C_CARD)  n_card  = n_card  + 1;
                if (col === C_PLOT)  n_plot  = n_plot  + 1;
                if (col === C_TEXT)  n_text  = n_text  + 1;
                if (col === C_TRACK) n_track = n_track + 1;
                if (col === C_ACC)   n_acc   = n_acc   + 1;
            end
        end
    endtask

    // ---- 一段像素区的文字墨量（y0..y0+15 行，x0..x1 列）----
    //   ★ v40（㊱）：判"状态名的汉字真的画出来了"要用**像素**，不能只回读 RAM
    //     （写对了但没渲染出来，RAM 判据永远是绿的 —— v24 的 7 bit 截断就是
    //     这么表现的：汉字标签全印成空格，而 RAM 里码值一个不差）。
    integer ink_n;
    task chk_ink_band;
        input [8*72-1:0] label;
        input [11:0] y0, x0, x1;
        input integer want;
        integer yy, xx;
        reg [23:0] col;
        begin
            ink_n = 0;
            for (yy = y0; yy < y0 + 16; yy = yy + 1) begin
                for (xx = x0; xx <= x1; xx = xx + 1) begin
                    smp(xx[11:0], yy[11:0], col);
                    if (col === C_TEXT) ink_n = ink_n + 1;
                end
            end
            if (ink_n !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : 墨量 %0d want %0d", label, ink_n, want);
            end else begin
                $display("[ OK ] %0s : 墨量 %0d", label, ink_n);
            end
        end
    endtask

    // =====================================================================
    reg [23:0] c1, c2, c3;

    initial begin
        $display("==== tb_p5_page ====");

        // -----------------------------------------------------------------
        // 第 1 节：复位
        // -----------------------------------------------------------------
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        chk_true("复位后 p5_view 不忙", (pv_busy === 1'b0));
        chki("复位后条形图阈值全 0" , pv_t0, 0);

        // -----------------------------------------------------------------
        // 第 2 节：计数窗口（WIN_FRAMES = 3，所以第 4 个帧首拍关门）
        //   窗口内 uvw = 1 走一段，再 uvw = 2 走一段：总采样数应等于两段之和，
        //   状态 0 与 7 应该是 0 —— 这条断言盯的是"命中的是 uvw 本身，
        //   不是某个恒定的状态号"。
        // -----------------------------------------------------------------
        pv_uvw = 3'd1;
        pv_frame();
        repeat (19) @(posedge clk);
        pv_uvw = 3'd2;
        pv_frame();
        repeat (19) @(posedge clk);
        pv_frame();
        repeat (19) @(posedge clk);
        pv_frame();                       // 第 4 个 → 关门、冻结快照
        repeat (4) @(posedge clk);

        $display("        window: tot=%0d cnt1=%0d cnt2=%0d cnt0=%0d cnt7=%0d",
                 u_pv.snap_tot, u_pv.snap[1], u_pv.snap[2], u_pv.snap[0], u_pv.snap[7]);

        chk_true("窗口总采样数 > 0", (u_pv.snap_tot > 0));
        chki("窗口内状态 0 一次都没出现", u_pv.snap[0], 0);
        chki("窗口内状态 7 一次都没出现", u_pv.snap[7], 0);
        chk_true("状态 1 与状态 2 的计数之和等于窗口总数",
                 ((u_pv.snap[1] + u_pv.snap[2]) === u_pv.snap_tot));
        chk_true("状态 1 与状态 2 都采到了", ((u_pv.snap[1] > 0) && (u_pv.snap[2] > 0)));

        // -----------------------------------------------------------------
        // 第 3 节：格式化结果（直接给快照，绕开 64 帧窗口）
        //   ★ v17 的映射（uvw = {w,v,u}，snap[k] = uvw 码 k 的采样数）：
        //       lab 标签 6 行（"U高 V低 W低" … "U低 V高 W高"）← uvw 码 1..6 ⇒ snap[1..6]
        //       底栏 "BAD 000" ← snap[0]（全零）、"111" ← snap[7]（全一）
        //     上板前的老代码把 6 行接到了 snap[0..5]，整列错位一格。
        //   快照：总 1,000,000 拍，uvw 码 0 占 200,000（20.0%），
        //         码 1 占 100,000（10.0%），其余全 0。
        //   于是第一行（码 1）= 10.0%，BAD000（码 0）= 20.0%，111（码 7）= 0.0%
        //   ★ 期望值全部是手算的十进制 —— 不是从 DUT 里抄回来的。
        // -----------------------------------------------------------------
        u_pv.snap[0] = 32'd200000;
        u_pv.snap[1] = 32'd100000;
        u_pv.snap[2] = 32'd0;
        u_pv.snap[3] = 32'd0;
        u_pv.snap[4] = 32'd0;
        u_pv.snap[5] = 32'd0;
        u_pv.snap[6] = 32'd0;
        u_pv.snap[7] = 32'd0;
        u_pv.snap_tot = 32'd1000000;

        pv_frame();                       // 触发一轮渲染
        pv_wait_done();
        repeat (4) @(posedge clk);

        show_fld(6'd9,  6'd33, 5);
        show_fld(6'd10, 6'd33, 5);
        show_fld(6'd22, 6'd18, 5);
        show_fld(6'd22, 6'd32, 5);
        show_fld(6'd9,  6'd28, 5);        // 次数字段（5 位十进制）

        // ★ v30：六个状态行落在 RAM 行 9..14（uvw 码 1..6），占比列从 33 起
        //   （5 格到 37）。旧版面是行 8/10/12/14/16/18 + 列 18..22。
        // 码 1（"U高 V低 W低"）← snap[1] = 100,000 → 100 permille → " 10.0"
        chk_cell(6'd9,  6'd33, 8'd0);     // 百位抑制
        chk_cell(6'd9,  6'd34, 8'd9);     // '1'
        chk_cell(6'd9,  6'd35, 8'd8);     // '0'
        chk_cell(6'd9,  6'd36, 8'd1);     // '.'
        chk_cell(6'd9,  6'd37, 8'd8);     // 十分位 '0'
        // 码 2 ← snap[2] = 0 → "  0.0"（行 10）
        chk_cell(6'd10, 6'd34, 8'd0);     // 十位也抑制
        chk_cell(6'd10, 6'd35, 8'd8);
        chk_cell(6'd10, 6'd37, 8'd8);
        // 码 3 ← snap[3] = 0 → "  0.0"（行 11）
        chk_cell(6'd11, 6'd33, 8'd0);
        chk_cell(6'd11, 6'd34, 8'd0);
        chk_cell(6'd11, 6'd35, 8'd8);
        chk_cell(6'd11, 6'd37, 8'd8);
        // 底栏 000 ← snap[0] = 200,000 → 200 permille → " 20.0"（行 22，列 18..22）
        chk_cell(6'd22, 6'd18, 8'd0);
        chk_cell(6'd22, 6'd19, 8'd10);    // '2'
        chk_cell(6'd22, 6'd20, 8'd8);
        // 底栏 111 ← snap[7] = 0 → "  0.0"（行 22，列 32..36）
        chk_cell(6'd22, 6'd32, 8'd0);
        chk_cell(6'd22, 6'd33, 8'd0);
        chk_cell(6'd22, 6'd34, 8'd8);
        // 次数字段（走 ent_snap，不走 snap）：个位永远显示，是个十进制数字。
        //   值本身取决于上面的窗口跑过什么，所以这里只判"是个数字"。
        chk_true("次数个位是十进制数字",
                 (rdcell(6'd9, 6'd32) >= 8'd8) && (rdcell(6'd9, 6'd32) <= 8'd17));

        // 条形图阈值 = perm * 188 / 1024（量程是第 5 列里的 184 px 槽）
        //   100 permille -> (100*188)>>10 = 18（旧版面是 perm/2 = 50）
        chki("码 1 条形图阈值 (100*188/1024)", pv_t0, 18);
        chki("码 2 条形图阈值 (0)", pv_t1, 0);
        chki("码 3 条形图阈值", pv_t2, 0);
        chki("码 6 条形图阈值", pv_t5, 0);

        // 静态版面：行标签与表头是 p5_view **不该碰**的格子
        //   字符码表（tools/cn_glyphs.py）：' '=0 '.'=1 '0'..'9'=8..17 'A'=18 …
        //   'U'=38 'V'=39 'W'=40 'P'=33 'B'=19；v40（㊱）起状态名的电平写汉字：
        //   '高'=171、'低'=172（CN_ORDER 末尾 "高低"，码 = 51 + CHARS.index）
        chk_cell(6'd9, 6'd4,  8'd9);     // 序号 "1"
        chk_cell(6'd9, 6'd11, 8'd38);    // "U高 V低 W低" 的 'U'
        chk_cell(6'd9, 6'd12, 8'd171);   // '高'
        chk_cell(6'd9, 6'd14, 8'd39);    // 'V'
        chk_cell(6'd9, 6'd15, 8'd172);   // '低'
        chk_cell(6'd9, 6'd17, 8'd40);    // 'W'
        chk_cell(6'd9, 6'd18, 8'd172);   // '低'
        chk_cell(6'd8, 6'd37, 8'd33);    // 表头 "PCT" 的 'P'
        chk_cell(6'd8, 6'd48, 8'd19);    // 表头 "BAR" 的 'B'
        chk_cell(6'd0, 6'd1,  8'd33);    // 标题 "P5 状态" 的 'P'

        // -----------------------------------------------------------------
        // 第 4 节：屏上条形图（给大 DUT 同一组快照）
        // -----------------------------------------------------------------
        u_dut.u_p5_view.snap[0] = 32'd200000;
        u_dut.u_p5_view.snap[1] = 32'd100000;
        u_dut.u_p5_view.snap[2] = 32'd0;
        u_dut.u_p5_view.snap[3] = 32'd0;
        u_dut.u_p5_view.snap[4] = 32'd0;
        u_dut.u_p5_view.snap[5] = 32'd0;
        u_dut.u_p5_view.snap[6] = 32'd0;
        u_dut.u_p5_view.snap[7] = 32'd0;
        u_dut.u_p5_view.snap_tot = 32'd1000000;

        repeat (3 * 853440) @(posedge clk);   // 跑满 3 帧：渲染 + 稳定

        // -----------------------------------------------------------------
        // 第 4 节：条形图（P5 的像素级映射）
        //   ★ 顶层那块 p5_view 由 vf_start 驱动，而 vf_start 只在
        //     `de && pix_y == 599 && pix_x == 1023` 那一拍产生 —— 本测试台
        //     不跑真光栅，所以顶层那块的 bar_t* 永远停在复位值。
        //     这里直接 force 阈值：渲染本身由小参数那个 p5_view 负责验，
        //     顶层只验"阈值 -> 像素"这段映射（和 P2/P3 测试台预置显示面同思路）。
        //   百分比列的文字也预置进顶层那块 p5_lab_ram，用来验证 lab 平面在
        //   P5 页**真的被读**（mux 少接一档就会变 z -> X，整页像素全 XXXXXX）。
        // -----------------------------------------------------------------
        force u_dut.u_p5_view.bar_t0 = 8'd100;
        force u_dut.u_p5_view.bar_t1 = 8'd50;
        force u_dut.u_p5_view.bar_t2 = 8'd0;
        force u_dut.u_p5_view.bar_t3 = 8'd183;    // 满槽
        force u_dut.u_p5_view.bar_t4 = 8'd20;
        force u_dut.u_p5_view.bar_t5 = 8'd90;
        // 行 9 = 地址 9*64 = 576；占比列 33..37 里的 " 20.0"
        u_dut.u_p5_lab_ram.mem[12'd576 + 12'd33] = 8'd0;   // ' '
        u_dut.u_p5_lab_ram.mem[12'd576 + 12'd34] = 8'd10;  // '2'
        u_dut.u_p5_lab_ram.mem[12'd576 + 12'd35] = 8'd8;   // '0'
        u_dut.u_p5_lab_ram.mem[12'd576 + 12'd36] = 8'd1;   // '.'
        u_dut.u_p5_lab_ram.mem[12'd576 + 12'd37] = 8'd8;   // '0'

        // ---- 槽的几何（v30）：第 5 列里 x = 836..1019、行带 r 里 y = 168+30r..185+30r
        //   第 0 行（y = 168..185）：阈值 100 px -> 填充 x = 836..935
        smp(12'd935, 12'd170, c1);  chk24("条形图行0 第 99 px 是填充",       c1, C_ACC);
        smp(12'd936, 12'd170, c1);  chk24("条形图行0 第 100 px 是空槽",      c1, C_TRACK);
        smp(12'd836, 12'd185, c1);  chk24("条形图行0 最后一排也填",          c1, C_ACC);
        // 第 1 行（y = 198..215）：阈值 50 px
        smp(12'd885, 12'd200, c1);  chk24("条形图行1 第 49 px 是填充",       c1, C_ACC);
        smp(12'd886, 12'd200, c1);  chk24("条形图行1 第 50 px 是空槽",       c1, C_TRACK);
        // 第 2 行（y = 228..245）：阈值 0 -> 整行都是空槽（836 那列是刻度线）
        smp(12'd900, 12'd235, c1);  chk24("阈值 0 的行中段是空槽",           c1, C_TRACK);
        // 行带里、条子上下各 7 px 内缩是页底
        smp(12'd900, 12'd160, c1);  chk24("行带内、条子上方是页底",          c1, C_BG);
        smp(12'd900, 12'd167, c1);  chk24("条区上沿之上是页底",              c1, C_BG);
        smp(12'd900, 12'd186, c1);  chk24("条区下沿之下是页底",              c1, C_BG);
        smp(12'd900, 12'd188, c1);  chk24("行分隔线在条区之外",              c1, C_GRID);
        // 槽右端：最后一列 1019 是刻度线（未填充时），1020 是列内缩 -> 页底
        smp(12'd1019, 12'd235, c1); chk24("槽最右一列是刻度线",              c1, C_SEC);
        smp(12'd1020, 12'd235, c1); chk24("槽右端之外是页底",                c1, C_BG);

        // ---- 表格线：外框 x = 81/1023、y = 127/339；4 条列分隔线；6 条行分隔线
        smp(12'd81, 12'd127, c1);   chk24("P5 表格框左上角",             c1, C_GRID);
        smp(12'd1023, 12'd200, c1); chk24("P5 表格框右沿",               c1, C_GRID);
        smp(12'd600, 12'd339, c1);  chk24("P5 表格框下沿",               c1, C_GRID);
        smp(12'd600, 12'd340, c1);  chk24("表格框下沿外是页底",          c1, C_BG);
        smp(12'd600, 12'd126, c1);  chk24("表格框上沿外是页底",          c1, C_BG);
        smp(12'd270, 12'd200, c1);  chk24("P5 第 1 条列分隔线",          c1, C_GRID);
        smp(12'd458, 12'd200, c1);  chk24("P5 第 2 条列分隔线",          c1, C_GRID);
        smp(12'd646, 12'd200, c1);  chk24("P5 第 3 条列分隔线",          c1, C_GRID);
        smp(12'd834, 12'd200, c1);  chk24("P5 第 4 条列分隔线",          c1, C_GRID);
        smp(12'd271, 12'd200, c1);  chk24("列分隔线只占 1 px",           c1, C_BG);
        smp(12'd600, 12'd158, c1);  chk24("P5 第 1 条行分隔线",          c1, C_GRID);
        smp(12'd600, 12'd308, c1);  chk24("P5 第 6 条行分隔线",          c1, C_GRID);
        smp(12'd600, 12'd159, c1);  chk24("行分隔线只占 1 px",           c1, C_BG);
        // ---- 条形图数值刻度线（0 / 25 / 50 / 75 / 100%）
        smp(12'd836, 12'd235, c1);  chk24("P5 0% 刻度线",               c1, C_SEC);
        smp(12'd881, 12'd235, c1);  chk24("P5 25% 刻度线（次级强调色）", c1, C_SEC);
        smp(12'd927, 12'd235, c1);  chk24("P5 50% 刻度线",               c1, C_SEC);
        smp(12'd973, 12'd235, c1);  chk24("P5 75% 刻度线",               c1, C_SEC);
        smp(12'd882, 12'd235, c1);  chk24("刻度线只占 1 px",             c1, C_TRACK);
        //   刻度线是"底"，填充条是"面"：第 3 行阈值 183（满槽），25% 那根线被压住
        smp(12'd881, 12'd260, c1);  chk24("填充条压过刻度线",            c1, C_ACC);

        // -----------------------------------------------------------------
        // 第 5 节：文字层与页门
        //   整行扫一行（y=135 落在表格第一行内）：
        //     卡片框（C_CARD）与图表底色（C_PLOT）都必须为 0 ——
        //     这两条一起证明 in_card 是 P1 专属、P5 也没借用 P2/P3/P4 的框。
        //     同时数一数文字像素：行标签（x 96..223）与百分比列（x 288..367）。
        // -----------------------------------------------------------------
        scan_row(12'd135, 12'd0, 12'd1023);
        chki("P5 整行没有卡片框像素", n_card, 0);
        chki("P5 整行没有图表底色像素", n_plot, 0);
        chk_true("P5 该行有文字像素（导航 + 表头）", (n_text > 0));

        // ★ v30：表头行是 RAM 行 8（y = 135..150），数据行是 9..14（y = 165..180）；
        //   列位置见 P5_LAB —— 状态名列 x = 276..403、占比列 x = 652..731。
        scan_row(12'd140, 12'd276, 12'd403);
        chk_true("表头第 2 列（状态）有文字像素", (n_text > 0));
        scan_row(12'd140, 12'd652, 12'd731);
        chk_true("表头第 4 列（PCT）有文字像素", (n_text > 0));
        scan_row(12'd170, 12'd276, 12'd403);
        chk_true("数据行状态名有文字像素", (n_text > 0));
        scan_row(12'd170, 12'd652, 12'd731);
        chk_true("数据行占比列有文字像素", (n_text > 0));

        // -----------------------------------------------------------------
        // 第 6 节：导航高亮落在第 4 项（页号 == 项号）
        // -----------------------------------------------------------------
        smp(12'd8, 12'd428, c1);  chk24("P5 导航第 4 项被选中", c1, C_SEC);
        smp(12'd8, 12'd100, c1);  chk24("P5 导航第 0 项未选中", c1, C_NAV);
        smp(12'd8, 12'd580, c1);  chk24("P5 导航第 5 项未选中", c1, C_NAV);

        // -----------------------------------------------------------------
        // 第 7 节：状态名的汉字渲染（v40 ㊱ 新增）
        //   ㊱ 把六行状态名从 `U1 V0 W0` 这种 ASCII 写法改成 `U高 V低 W低`。
        //   这是**汉字第一次进入 P5 的虚拟格网**（30 px 行带 / 188 px 列带、
        //   RAM 地址 {8+r, 11c + dx>>4}、字形相位 lab_bits[15 - dx[3:0]]）——
        //   ㊱ 之前这张表里全是 ASCII，这条路从来没跑过。所以判据落在**像素**上：
        //     ① 每一行的 8 格文字墨量必须等于离线（tools/gen_font_rom.py 的字形）
        //        算出来的精确值 —— 少一格、错字、错相位、被裁掉都会变数；
        //     ② 六行各挑 3 个"新写法与旧 ASCII 写法取值相反"的像素 —— 这些点
        //        在旧版本上必然红，所以它们证明的是"换字真的换到屏幕上了"。
        //   坐标：状态名 8 格 = x 276..403（列带 1 = 82+188，再加 P5_INSET=6 的内缩；
        //   188 = 11*16 + 2*6，所以每条列带里真正画字的 176 px 是从 +6 开始的）；
        //   数据行 r 的字形在 y = 128 + 30*r + 7（30 px 行带里 16 px 字形垂直居中）。
        //   ★ 这两个内缩(6/7 px)是从 RTL 里读出来的：第一版判据按 270..397 扫，
        //     六行墨量各少 26/26/26/30/30/30 —— 判据先自己红了一次，才把内缩逼出来。
        // -----------------------------------------------------------------
        chk_ink_band("P5 行 9 状态名墨量（U高 V低 W低）", 12'd165, 12'd276, 12'd403, 483);
        chk_ink_band("P5 行 10 状态名墨量（U低 V高 W低）", 12'd195, 12'd276, 12'd403, 483);
        chk_ink_band("P5 行 11 状态名墨量（U高 V高 W低）", 12'd225, 12'd276, 12'd403, 482);
        chk_ink_band("P5 行 12 状态名墨量（U低 V低 W高）", 12'd255, 12'd276, 12'd403, 483);
        chk_ink_band("P5 行 13 状态名墨量（U高 V低 W高）", 12'd285, 12'd276, 12'd403, 482);
        chk_ink_band("P5 行 14 状态名墨量（U低 V高 W高）", 12'd315, 12'd276, 12'd403, 482);
        // 逐行三个"证伪点"：格 12（第 1 个电平）、格 15、格 18（第 3 个电平），
        //   local (dx=8, dy=8) 是离线挑出来的、新旧写法取值相反的那个像素。
        smp(12'd300, 12'd173, c1);  chk24("行 9 格 12「高」有笔画",      c1, C_TEXT);
        smp(12'd348, 12'd173, c1);  chk24("行 9 格 15「低」同一局部位置是空", c1, C_BG);
        smp(12'd396, 12'd173, c1);  chk24("行 9 格 18「低」同一局部位置是空", c1, C_BG);
        smp(12'd300, 12'd203, c1);  chk24("行 10 格 12「低」同一局部位置是空", c1, C_BG);
        smp(12'd348, 12'd203, c1);  chk24("行 10 格 15「高」有笔画",     c1, C_TEXT);
        smp(12'd396, 12'd203, c1);  chk24("行 10 格 18「低」同一局部位置是空", c1, C_BG);
        smp(12'd300, 12'd233, c1);  chk24("行 11 格 12「高」有笔画",     c1, C_TEXT);
        smp(12'd348, 12'd233, c1);  chk24("行 11 格 15「高」有笔画",     c1, C_TEXT);
        smp(12'd396, 12'd233, c1);  chk24("行 11 格 18「低」同一局部位置是空", c1, C_BG);
        smp(12'd300, 12'd263, c1);  chk24("行 12 格 12「低」同一局部位置是空", c1, C_BG);
        smp(12'd348, 12'd263, c1);  chk24("行 12 格 15「低」同一局部位置是空", c1, C_BG);
        smp(12'd396, 12'd263, c1);  chk24("行 12 格 18「高」有笔画",     c1, C_TEXT);
        smp(12'd300, 12'd293, c1);  chk24("行 13 格 12「高」有笔画",     c1, C_TEXT);
        smp(12'd348, 12'd293, c1);  chk24("行 13 格 15「低」同一局部位置是空", c1, C_BG);
        smp(12'd396, 12'd293, c1);  chk24("行 13 格 18「高」有笔画",     c1, C_TEXT);
        smp(12'd300, 12'd323, c1);  chk24("行 14 格 12「低」同一局部位置是空", c1, C_BG);
        smp(12'd348, 12'd323, c1);  chk24("行 14 格 15「高」有笔画",     c1, C_TEXT);
        smp(12'd396, 12'd323, c1);  chk24("行 14 格 18「高」有笔画",     c1, C_TEXT);

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
