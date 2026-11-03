//=============================================================================
//  disp/tb_p7_page.v  --  P7「标定与误差可视化」自检
//
//  一个顶层放两个被测件：
//    ① disp_engine（page = 3'd6）—— 验屏上的东西：左框（曲线）/ 右框（参数）、
//       两个图例色块、曲线区间比较、导航在 P7 不高亮任何项；
//    ② 独立的 p7_view + **三块真正的 p7_ram** —— 验格式化与统计本身：
//       分箱 min/max、calib_busy 两个边沿（清箱与换 bank）、七个字段的字符。
//
//  ★ 采样规则与其它显示测试台一致：把 pix_x/pix_y 停住 >=5 拍再读 lcd_rgb，
//    读到的是**组合映射**；管线级数由 disp/tb_pipe_align.v 用移动光栅单独把关。
//
//  ★ 曲线那一段用 force 把被测件的 frz 拉住，防止它每帧的 dump 把预置数据盖掉。
//    这么做是**故意**的：预置数据与被测逻辑用的是同一块 RAM，而这一节要验的是
//    "RAM 里的值怎么变成屏上的像素"，不是"dump 写对了没有"（后者在第 4 节验）。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_p7_page;

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
    localparam [23:0] C_EPRE  = 24'hC2185B;   // 标定前
    localparam [23:0] C_EPOST = 24'h2E7D32;   // 标定后

    // ---- P7 版面（与 disp/disp_engine.v 的 localparam 同源）----
    localparam [11:0] P7_BX0 = 12'd96,  P7_BX1 = 12'd640;
    localparam [11:0] P7_BY0 = 12'd112, P7_BY1 = 12'd416;
    localparam [11:0] CV_X0  = 12'd112, CV_Y0  = 12'd160;
    localparam [11:0] P7_RX0 = 12'd656;
    localparam [11:0] SW0    = 12'd462, SW1    = 12'd526;

    integer errors = 0;

    // =====================================================================
    // 被测件 ①：整页的 disp_engine（page = 3'd6）
    // =====================================================================
    disp_engine u_dut (
        .clk(clk), .rst_n(rst_n), .page(3'd6),
        .pix_x(px), .pix_y(py), .de(de),
        .tap_angle(16'h2000), .tap_s_n(16'h0A00), .tap_c_n(16'h0500),
        .tap_pos_full(32'h0000_1234),
        .tap_io_state(8'b0000_0100), .tap_io_flags(8'h00), .tap_stat(8'h00),
        .tap_cfg_inter(10'd64), .tap_cfg_div(3'd0), .tap_cfg_pairs(5'd4),
        .tap_cfg_hyst_ab(5'd2), .tap_cfg_ablimit(8'd255), .tap_cfg_zwidth(4'd5),
        .tap_cfg_zphase(12'd0), .tap_cfg_uvwph(16'd0), .tap_cfg_pol(4'b0000),
        .tap_ofs_s(16'sd0), .tap_ofs_c(16'sd0),
        .tap_gain_s(16'd32768), .tap_gain_c(16'd32768),
        .tap_phase_k(16'sd0), .tap_shift(4'd0), .tap_amp_sq(32'h2000_0000),
        // v21：P7 幅值百分比的门限（真实默认值 0x0520/0x0524）
        .tap_amp_low_sq(32'h170A_3D71), .tap_amp_high_sq(32'h5C28_F5C3),
        .tap_abzen(1'b1), .tap_uwven(1'b1), .tap_calib_busy(1'b0), .tap_link_crc_err(1'b0), .tap_link_lost(1'b0),
        .tch_diag(160'd0), .ui_state(2'd0), .ui_err(4'd0), .ui_dlg(2'd0), .ui_dz_press(1'b0),
        .ui_dz_press2(1'b0), .ui_dlg_kind(1'b0), .ui_rst_state(2'd0), .ui_rst_bad(15'd0),
        .pnl_on(1'b0), .pnl_inter(10'd64), .pnl_prog(6'd0), .pnl_press(4'd0),
        .pnl_fld(1'b0), .pnl_didx(3'd0),
        .pnl_pend(1'b0), .pnl_idx(3'd0), .pnl_undo_avail(1'b0), .pnl_undo_inter(10'd64),
        .pnl_undo_div(3'd0),
        .lcd_rgb(lcd_rgb), .de_o(de_o), .dbg_x(dbg_x), .dbg_y(dbg_y)
    );

    // =====================================================================
    // 被测件 ②：独立的 p7_view + 三块真正的 p7_ram
    // =====================================================================
    reg         pv_fst  = 1'b0;
    reg  [15:0] pv_ang  = 16'd0;
    reg  [31:0] pv_amp  = 32'h0000_8000;
    reg         pv_cbusy= 1'b0;
    reg  signed [15:0] pv_ofs_s = 16'sd0;
    reg  signed [15:0] pv_ofs_c = 16'sd0;
    reg  [15:0] pv_gain_s = 16'd32768;
    reg  [15:0] pv_gain_c = 16'd32768;
    reg  signed [15:0] pv_phk   = 16'sd0;
    reg  [3:0]  pv_shift  = 4'd0;
    // v21：幅值百分比的两个门限。默认 = 真实寄存器默认值（0.60 / 1.20 的平方），
    //   测试里可以改成别的值来验算百分比口径。
    reg  [31:0] pv_alo   = 32'h170A_3D71;
    reg  [31:0] pv_ahi   = 32'h5C28_F5C3;

    wire        pv_we, pv_busy, pv_done;
    wire [11:0] pv_waddr;
    wire [7:0]  pv_wdata;
    wire        pv_acc_we, pv_bef_we, pv_aft_we;
    wire [6:0]  pv_acc_waddr, pv_bef_waddr, pv_aft_waddr;
    wire [31:0] pv_acc_wdata;
    wire [15:0] pv_bef_wdata, pv_aft_wdata;
    wire [6:0]  pv_acc_raddr;
    wire [31:0] pv_acc_rdata;
    wire [7:0]  pv_rdata;

    p7_view u_pv (
        .clk(clk), .rst_n(rst_n), .start(pv_fst), .hold(1'b0),
        .angle(pv_ang), .amp_sq(pv_amp), .calib_busy(pv_cbusy),
        .ofs_s(pv_ofs_s), .ofs_c(pv_ofs_c),
        .gain_s(pv_gain_s), .gain_c(pv_gain_c),
        .phase_k(pv_phk), .shift(pv_shift),
        .amp_low_sq(pv_alo), .amp_high_sq(pv_ahi),
        .acc_we(pv_acc_we), .acc_waddr(pv_acc_waddr), .acc_wdata(pv_acc_wdata),
        .acc_raddr(pv_acc_raddr), .acc_rdata(pv_acc_rdata),
        .bef_we(pv_bef_we), .bef_waddr(pv_bef_waddr), .bef_wdata(pv_bef_wdata),
        .aft_we(pv_aft_we), .aft_waddr(pv_aft_waddr), .aft_wdata(pv_aft_wdata),
        .we(pv_we), .waddr(pv_waddr), .wdata(pv_wdata),
        .busy(pv_busy), .done(pv_done)
    );

    p7_ram #(.DW(32), .INIT({16'd0, 16'hFFFF})) u_acc (
        .clk(clk), .we(pv_acc_we), .waddr(pv_acc_waddr), .wdata(pv_acc_wdata),
        .raddr(pv_acc_raddr), .rdata(pv_acc_rdata)
    );
    p7_ram #(.DW(16), .INIT({8'd120, 8'd120})) u_bef (
        .clk(clk), .we(pv_bef_we), .waddr(pv_bef_waddr), .wdata(pv_bef_wdata),
        .raddr(7'd0), .rdata()
    );
    p7_ram #(.DW(16), .INIT({8'd120, 8'd120})) u_aft (
        .clk(clk), .we(pv_aft_we), .waddr(pv_aft_waddr), .wdata(pv_aft_wdata),
        .raddr(7'd0), .rdata()
    );

    // 文字层：真正的 p7_lab_ram，用来回读渲染出来的字符
    p7_lab_ram u_pram (
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

    task chk32;
        input [8*72-1:0] label;
        input [31:0]     got, want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : got %h want %h", label, got, want);
            end else begin
                $display("[ OK ] %0s : %h", label, got);
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

    // 把像素坐标停住 >=5 拍再读
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
    function [6:0] rdcell;
        input [5:0] r, c;
        begin
            rdcell = u_pram.mem[{r, 6'd0} + {6'd0, c}];
        end
    endfunction

    task chk_cell;
        input [5:0] r, c;
        input [6:0] want;
        begin
            if (rdcell(r, c) !== want) begin
                errors = errors + 1;
                $display("[FAIL] lab cell (%0d,%0d) = %0d want %0d", r, c, rdcell(r, c), want);
            end
        end
    endtask

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

    // 发一个帧首脉冲并等这一轮渲染 + dump 跑完。
    // ★ 不能只等固定拍数：S_IDLE 只在 !clr_req && !clr_run 时受理 start，
    //   而 done 只高一拍 —— 逐拍轮询 busy 比 wait(done) 稳。
    task pv_frame;
        integer k;
        begin
            @(negedge clk);
            pv_fst = 1'b1;
            @(negedge clk);
            pv_fst = 1'b0;
            // 先等 busy 起来（start 要一拍的 start_r 才被受理），再等它落。
            for (k = 0; (k < 40) && !pv_busy; k = k + 1) @(posedge clk);
            for (k = 0; (k < 20000) && pv_busy; k = k + 1) @(posedge clk);
            #1;
        end
    endtask

    // 给 p7_view 的累积器喂一个样本（保持 n 拍，让它进 min/max）
    // ★ 末尾的 #1 是必须的：非阻塞赋值在 NBA 区生效，而 @(posedge clk) 之后
    //   立刻读层次信号会读到**跳变前**的旧值。
    task pv_sample;
        input [15:0] ang;
        input [31:0] amp;
        input integer n;
        begin
            pv_ang = ang; pv_amp = amp;
            repeat (n) @(posedge clk);
            #1;
        end
    endtask

    // 整数型字符码：'0' = 8，数字 d -> 8+d，'A' = 18
    function [6:0] dg;
        input [3:0] d;
        begin
            dg = 7'd8 + {3'b000, d};
        end
    endfunction

    integer k;
    reg [23:0] col;
    integer n_card, n_text, n_plot;

    initial begin
        // 手工帧首：整页的 disp_engine 由它自己的内部时序驱动，这里只驱动小件。
        rst_n = 1'b0;
        px = 12'd0; py = 12'd0; de = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // -----------------------------------------------------------------
        $display("--- 1. 复位初值 ---");
        // -----------------------------------------------------------------
        chk32("acc_ram 复位 = {hi=0, lo=FFFF}（空白带）", u_acc.mem[0],   32'h0000_FFFF);
        chk32("acc_ram 箱 77 同上",                    u_acc.mem[77],  32'h0000_FFFF);
        chk32("bef_ram 复位 = 120/120（中间横线）",     {16'd0, u_bef.mem[0]},  32'h0000_7878);
        chk32("aft_ram 复位 = 120/120",                {16'd0, u_aft.mem[127]},32'h0000_7878);
        chki("复位后 cur_bin 已跟随电角度",             u_pv.cur_bin, 0);

        // -----------------------------------------------------------------
        $display("--- 2. 分箱累积：箱 5 收三个样本，换箱时写出 min/max ---");
        // -----------------------------------------------------------------
        pv_sample(16'd2560, 32'h0005_0000, 2);   // angle[15:9] = 5, mag = 10
        pv_sample(16'd2560, 32'h000F_0000, 2);   // mag = 30
        pv_sample(16'd2560, 32'h000A_0000, 2);   // mag = 20
        chki("箱 5 的 cur_lo", u_pv.cur_lo, 10);
        chki("箱 5 的 cur_hi", u_pv.cur_hi, 30);
        pv_sample(16'd3072, 32'h0005_0000, 2);   // 换到箱 6 => 箱 5 被写出去
        chk32("箱 5 写出 = {hi=30, lo=10}", u_acc.mem[5], 32'h001E_000A);

        // -----------------------------------------------------------------
        $display("--- 3. 文字层：七个字段的字符 ---");
        // -----------------------------------------------------------------
        pv_ofs_s = -16'sd1234;
        pv_ofs_c =  16'sd7;
        pv_gain_s=  16'd32768;
        pv_gain_c=  16'd40000;
        pv_phk   = -16'sd32768;
        pv_shift =  4'd5;
        pv_amp   =  32'h0000_8000;              // amp_sq[30:15] = 1
        pv_frame;
        show_fld(6'd10, 6'd52, 6);  show_fld(6'd14, 6'd52, 6);
        show_fld(6'd18, 6'd52, 6);  show_fld(6'd22, 6'd52, 6);
        show_fld(6'd31, 6'd9,  6);  show_fld(6'd31, 6'd23, 6);
        // 字段布局：第 0 格是符号位（有符号量显示 + / -，无符号量显示空格），
        // 第 1..5 格是 5 位十进制、高位前导零抑制、最低位永远显示。
        // 四个参数在列 52..57（格行 10/14/18/22）；「幅值」在列 11..16（格行 31，v60）。
        // OFS-S = -1234（有符号）-> "- 1234"
        chk_cell(6'd10, 6'd52, 7'd2);
        chk_cell(6'd10, 6'd53, 7'd0);
        chk_cell(6'd10, 6'd54, dg(4'd1));
        chk_cell(6'd10, 6'd55, dg(4'd2));
        chk_cell(6'd10, 6'd56, dg(4'd3));
        chk_cell(6'd10, 6'd57, dg(4'd4));
        // OFS-C = +7（有符号）-> "+    7"
        chk_cell(6'd14, 6'd52, 7'd3);
        chk_cell(6'd14, 6'd53, 7'd0);
        chk_cell(6'd14, 6'd57, dg(4'd7));
        // GAIN-S = 32768（Q15 定点）-> gain_milli = 32768*1000>>15 = 1000 -> " 1.000"
        //   ★ v85 起按盘上真值显示（"d.ddd"）：上板标定就是 1.000 -> 0.988 这两档。
        chk_cell(6'd18, 6'd52, 7'd0);
        chk_cell(6'd18, 6'd53, dg(4'd1));
        chk_cell(6'd18, 6'd54, 7'd1);          // '.'
        chk_cell(6'd18, 6'd55, dg(4'd0));
        chk_cell(6'd18, 6'd56, dg(4'd0));
        chk_cell(6'd18, 6'd57, dg(4'd0));
        // GAIN-C = 40000 -> 40000*1000>>15 = 1220 -> " 1.220"
        chk_cell(6'd22, 6'd52, 7'd0);
        chk_cell(6'd22, 6'd53, dg(4'd1));
        chk_cell(6'd22, 6'd54, 7'd1);          // '.'
        chk_cell(6'd22, 6'd55, dg(4'd2));
        chk_cell(6'd22, 6'd56, dg(4'd2));
        chk_cell(6'd22, 6'd57, dg(4'd0));
        //   ★ v60：PHASE-K / SHIFT 两行已随 P7 减参删掉
        //   ★ v85：底栏的「幅值百分比」已删（它和曲线不同口径），改成
        //     "P-P"（峰峰）与 "RMS" 两个同口径统计量，取值全部来自 dump 相，
        //     所以在 §7 里用受控的 128 箱数据单独断言（这里只确认四个参数行）。

        // -----------------------------------------------------------------
        $display("--- 3b. （v85 删）底栏不再是「幅值百分比」，见 §7 ---");
        // -----------------------------------------------------------------
        //   旧口径 pct = (mag-lo)/(hi-lo) 与曲线无关（曲线现在是相对误差 dev），
        //   相关断言（0.0%/100.0%/越界负值/除零夹紧 999.9）随口径一起删除。
        //   新口径 = 128 箱 dev 的峰峰值与 RMS，见 §7。

        // -----------------------------------------------------------------
        $display("--- 4. 屏上：两个框、图例、曲线 ---");
        // -----------------------------------------------------------------
        // 把被测件的 dump 冻住，避免它每帧把预置数据盖掉
        force u_dut.u_p7_view.frz = 1'b1;
        // 箱 50 => 屏上 x = 112 + 50*4 = 312..315
        u_dut.u_p7_bef_ram.mem[7'd50] = {8'd200, 8'd100};
        u_dut.u_p7_aft_ram.mem[7'd50] = {8'd180, 8'd120};

        smp(12'd300, 12'd112, col); chk24("左框上沿是框线", col, C_GRID);
        smp(12'd96,  12'd200, col); chk24("左框左沿是框线", col, C_GRID);
        smp(12'd639, 12'd200, col); chk24("左框右沿是框线", col, C_GRID);
        smp(12'd300, 12'd479, col); chk24("左框下沿是框线", col, C_GRID);
        smp(12'd300, 12'd300, col); chk24("左框内部底色是绘图底", col, C_PLOT);
        smp(12'd200, 12'd160, col); chk24("曲线区上沿是网格线", col, C_GRID);

        smp(12'd656, 12'd200, col); chk24("右框左沿是框线", col, C_GRID);
        smp(12'd700, 12'd300, col); chk24("右框内部底色是卡片白", col, C_CARD);

        // 曲线：y = 160+150 = 310 落在"后"的 [120,180] 里 -> 绿
        smp(12'd312, 12'd310, col); chk24("箱 50 的 y=150 落在标定后带内", col, C_EPOST);
        // y = 160+105 = 265：在"前"的 [100,200] 内、"后"的 [120,180] 外 -> 品红
        smp(12'd312, 12'd265, col); chk24("y=105 只落在标定前带内", col, C_EPRE);
        // y = 160+238 = 398：两条带都不覆盖（399 恰好是曲线区的下沿框线）
        smp(12'd312, 12'd398, col); chk24("带外是绘图底", col, C_PLOT);
        // 相邻箱 51 没预置（120/120），y=150 不在 [120,120] 内
        smp(12'd316, 12'd310, col); chk24("未预置的箱不画带", col, C_PLOT);

        smp(12'd462, 12'd135, col); chk24("图例 1 色块 = 标定前色", col, C_EPRE);
        smp(12'd526, 12'd135, col); chk24("图例 2 色块 = 标定后色", col, C_EPOST);

        smp(12'd8, 12'd100, col);   chk24("P7 上导航第 0 项不高亮", col, C_NAV);

        // 左框内扫一行：不该出现卡片白，且必须有文字像素
        n_card = 0; n_text = 0; n_plot = 0;
        de = 1'b1;
        for (k = 0; k < 544; k = k + 1) begin
            @(negedge clk);
            px = P7_BX0 + k; py = 12'd135;
            repeat (5) @(posedge clk);
            #1;
            if (lcd_rgb === C_CARD) n_card = n_card + 1;
            if (lcd_rgb === C_TEXT) n_text = n_text + 1;
            if (lcd_rgb === C_PLOT) n_plot = n_plot + 1;
        end
        chki("左框内没有卡片白像素", n_card, 0);
        chk_true("左框内有标题文字像素", n_text > 0);
        chk_true("左框内以绘图底为主", n_plot > 400);
        release u_dut.u_p7_view.frz;

        // -----------------------------------------------------------------
        $display("--- 5. calib_busy 上升沿：清箱 + 冻结 ---");
        // -----------------------------------------------------------------
        pv_cbusy = 1'b1;
        repeat (140) @(posedge clk);
        chk32("清箱后箱 0 = {0,FFFF}",   u_acc.mem[0],   32'h0000_FFFF);
        chk32("清箱后箱 127 = {0,FFFF}", u_acc.mem[127], 32'h0000_FFFF);
        chki("清箱结束（clr_run 落）",   u_pv.clr_run, 0);
        chki("上升沿后 frz = 1",         u_pv.frz, 1);
        chki("上升沿后仍是「前」bank",   u_pv.mode, 0);

        // 冻结期间发一帧：只渲文字，不做 dump
        u_bef.mem[7'd40] = {8'd111, 8'd99};
        pv_frame;
        chk32("冻结期间 bef_ram 没被改写", {16'd0, u_bef.mem[7'd40]}, 32'h0000_6F63);

        // -----------------------------------------------------------------
        $display("--- 6. calib_busy 下降沿：换到「后」bank 并 dump ---");
        // -----------------------------------------------------------------
        pv_cbusy = 1'b0;
        repeat (4) @(posedge clk);
        chki("下降沿后 mode = 1", u_pv.mode, 1);
        chki("下降沿后 frz = 0",  u_pv.frz,  0);

        // 箱 40 收两个样本：mag 1006 / 1015（amp_sq = mag << 15）
        // ★ v85：dump 存的不再是"绝对幅值行"，而是"相对全帧均值的偏差行"，
        //   所以断言必须先把全帧均值钉死：把 128 箱全部预置成 {1000,1000}，
        //   再让箱 40 收 1006/1015 两个样本 => 均值 = (127*2000 + 2021)/256 = 1000
        //     dev_lo = (1006-1000)*10000/1000 = 60  (0.6%) -> y = 120 - 36  = 84
        //     dev_hi = (1015-1000)*10000/1000 = 150 (1.5%) -> y = 120 - 90  = 30
        //   => aft_ram[40] = {hi=30, lo=84} = 0x1E54
        for (k = 0; k < 128; k = k + 1) u_acc.mem[k] = {16'd1000, 16'd1000};
        pv_sample(16'd20480, 32'h01F7_0000, 2);   // angle 40*512, mag 1006
        pv_sample(16'd20480, 32'h01FB_8000, 2);   // mag 1015
        chki("箱 40 的 cur_lo", u_pv.cur_lo, 1006);
        chki("箱 40 的 cur_hi", u_pv.cur_hi, 1015);
        // 换到箱 41 也喂 1000：既有换箱写出，也让 flush 写回的箱 41 不污染均值
        pv_sample(16'd20992, 32'h01F4_0000, 2);   // angle 41*512, mag 1000 (amp_sq = 1000<<15)
        chki("换箱时 acc_ram 箱 40 已写出 hi", u_acc.mem[7'd40][31:16], 16'd1015);
        chki("换箱时 acc_ram 箱 40 已写出 lo", u_acc.mem[7'd40][15:0],  16'd1006);
        // 上式会把 acc[41] 写回 {1000,1000}；再把整表钉成"127×1000 + 箱40=1006/1015"，
        // 这样均值恰好 1000.08 -> 1000，行号断言才有确定值。
        for (k = 0; k < 128; k = k + 1) u_acc.mem[k] = {16'd1000, 16'd1000};
        u_acc.mem[7'd40] = {16'd1015, 16'd1006};
        pv_frame;
        chk32("aft_ram 箱 40 = {hi=30(+1.5%), lo=84(+0.6%)}",
              {16'd0, u_aft.mem[7'd40]}, 32'h0000_1E54);
        chk32("bef_ram 箱 40 未被改写", {16'd0, u_bef.mem[7'd40]}, 32'h0000_6F63);

        // -----------------------------------------------------------------
        $display("--- 7. 新纵轴：dev -> 行号（+1.5%% / 0 / -1.0%%）与 P-P/RMS 文字 ---");
        // -----------------------------------------------------------------
        //   口径（disp/p7_view.v §5/§6）：
        //     dev_0.1‰ = (bin - mean) * (10000<<12 / mean) >> 12
        //     y        = 120 - floor(0.6 * |dev|)      （+2% -> 0，-2% -> 239）
        //     P-P      = (max_dev - min_dev)/100  %    （两位小数，列 9..14）
        //     RMS      = 1.1128 * mean|dev_mid| /100 % （两位小数，列 23..28）
        //   为了让均值精确等于 1000，偏差只加在两箱上并相互平衡（+15 / -10）。
        for (k = 0; k < 128; k = k + 1) u_acc.mem[k] = {16'd1000, 16'd1000};
        u_acc.mem[7'd10] = {16'd1015, 16'd1015};      // dev = +150 (1.5%)
        u_acc.mem[7'd20] = {16'd990,  16'd990};       // dev = -100 (-1.0%)
        pv_frame;
        show_fld(6'd31, 6'd9,  6);
        show_fld(6'd31, 6'd23, 6);
        //   均值 = (126*2000 + 2030 + 1980)/256 = 1000（整数除法）
        chk32("箱 10 (+1.5%) -> 行号 {30,30}", {16'd0, u_aft.mem[7'd10]}, 32'h0000_1E1E);
        chk32("箱 20 (-1.0%) -> 行号 {180,180}",
              {16'd0, u_aft.mem[7'd20]}, 32'h0000_B4B4);
        chk32("箱 0  (0)      -> 行号 {120,120}",
              {16'd0, u_aft.mem[7'd0]},  32'h0000_7878);
        //   P-P = 150 - (-100) = 250 (0.01%) = 2.50% -> "  2.50"
        chk_cell(6'd31, 6'd9,  7'd0);            // 百位 0 -> 空格
        chk_cell(6'd31, 6'd10, 7'd0);            // 十位 0 -> 空格
        chk_cell(6'd31, 6'd11, dg(4'd2));
        chk_cell(6'd31, 6'd12, 7'd1);            // '.'
        chk_cell(6'd31, 6'd13, dg(4'd5));
        chk_cell(6'd31, 6'd14, dg(4'd0));
        //   RMS（v85.1 近似口径）= 1.1128 * 平均绝对偏差：
        //     (|+150| + |-100|)/128 = 1.95 (0.1‰) ⇒ 1.1128*1.95 = 2.17 (0.1‰)
        //     = 0.217 % ⇒ 取两位小数 "  0.21"
        //   ★ 原来的真 RMS（sqrt(Σdev²/cnt)）对只有两箱有偏差的稀疏分布是 0.15，
        //     但那条链要 mean² -> DSP 平方 -> 26 位累加，WNS 被打到 -1.31 ns；
        //     换成平均绝对偏差后只差 0.06 个百分点，量级完全够用。
        chk_cell(6'd31, 6'd23, 7'd0);
        chk_cell(6'd31, 6'd24, 7'd0);
        chk_cell(6'd31, 6'd25, dg(4'd0));
        chk_cell(6'd31, 6'd26, 7'd1);            // '.'
        chk_cell(6'd31, 6'd27, dg(4'd2));
        chk_cell(6'd31, 6'd28, dg(4'd1));
        //   没有样本越出 ±2% -> 溢出标记那一格是空格
        chk_cell(6'd9, 6'd37, 7'd0);

        // -----------------------------------------------------------------
        $display("--- 7b. 越出 ±2%%：行号钳在框内 + 角落溢出标记 '▲' ---");
        // -----------------------------------------------------------------
        for (k = 0; k < 128; k = k + 1) u_acc.mem[k] = {16'd1000, 16'd1000};
        u_acc.mem[7'd20] = {16'd990,  16'd990};      // dev = -100
        u_acc.mem[7'd5]  = {16'd1030, 16'd1030};     // dev = +300 (3.0%) 越界
        pv_frame;
        //   均值 = (126*2000 + 2060 + 1980)/256 = 1000（同 §7 的平衡法）
        chk32("箱 5  (+3.0%) -> 钳到行 0", {16'd0, u_aft.mem[7'd5]}, 32'h0000_0000);
        chk32("箱 20 (-1.0%) -> 行 180",   {16'd0, u_aft.mem[7'd20]}, 32'h0000_B4B4);
        chk_cell(6'd9, 6'd37, 7'd49);                // '▲' = 49：曲线区右上角

        // -----------------------------------------------------------------
        $display("--- 8. 计数 ---");
        // -----------------------------------------------------------------
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("[FAIL] timeout");
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule

`default_nettype wire
