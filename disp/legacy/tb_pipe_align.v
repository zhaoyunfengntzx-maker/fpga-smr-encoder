//=============================================================================
// disp/tb_pipe_align.v —— 「移动光栅」下的管线级数测量（v16）
//-----------------------------------------------------------------------------
//   为什么需要这个测试台，而不是继续用 tb_p2_page / tb_p3_page 的列对齐断言：
//
//     tb_p2_page / tb_p3_page 的做法是「把 pix_x/pix_y 停在某一点、等 5 拍、
//     再读 lcd_rgb」。**坐标停住之后，数据通路是几级寄存都无所谓** ——
//     RAM 的读地址不变，wave_q / wave_d1 / wave_d2 / lg_w … 全部收敛到同一个
//     值。也就是说那些断言测的是**组合映射**（"位图第 50 格对应屏上 x=420"），
//     而**测不到级数**（"这个 420 是当拍就出来，还是晚一拍才出来"）。
//
//     级数错位的表现不是"某个点不在"，而是整块内容在屏上横移 1 px ——
//     它不会让任何"跑满帧 / 查帧率 / 查颜色"的检查变红。
//
//   所以本测试台用**连续光栅**：pix_x 每拍 +1 走满一行，然后只在
//   `de_o && dbg_y == 目标行` 时看 `lcd_rgb`。这样"坐标"和"数据"是两个
//   先后到来的序列，级数差 1 就会让内容整体平移 1 px，可直接读出。
//
//   预置数据全部写在**显示面**（face=1）并把两个写面的指针 force 住，
//   于是被测逻辑照常跑、只碰另一面 —— 不需要为了"让测试稳定"去关掉它。
//   （"关掉被测逻辑再测"会让测试台自己变成最大的未测部分。）
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_pipe_align;

    // ---------------------------------------------------------------- 色板 --
    localparam [23:0] C_ACC   = 24'h2E7DD1;     // P3 描点色 = P2 的 A 通道色
    localparam [23:0] C_TR_A  = 24'h2E7DD1;
    localparam [23:0] C_EPRE  = 24'hC2185B;     // P7「标定前」曲线色
    localparam [23:0] C_EPOST = 24'h2E7D32;     // P7「标定后」曲线色
    localparam [23:0] C_GRID  = 24'hD6E3F0;     // 网格/描边（v21：P4 角度刻度）
    localparam [23:0] C_BLACK = 24'h000000;

    // ------------------------------------------------------------- 时钟复位 --
    reg clk = 1'b0;
    always #10 clk = ~clk;                      // 50 MHz

    reg rst_n = 1'b0;

    // ======================================================= 被测件 disp_engine
    reg  [2:0]  page = 3'd1;
    reg  [11:0] px = 12'd0, py = 12'd0;
    reg         de = 1'b0;

    reg  [15:0] t_angle = 16'd0, t_s_n = 16'd0, t_c_n = 16'd0;
    reg  [31:0] t_pos = 32'd0;
    reg  [7:0]  t_io_state = 8'd0, t_io_flags = 8'd0, t_stat = 8'd0;

    wire [23:0] lcd_rgb;
    wire        de_o;
    wire [11:0] dbg_x, dbg_y;

    disp_engine u_dut (
        .clk(clk), .rst_n(rst_n), .page(page),
        .pix_x(px), .pix_y(py), .de(de),
        .tap_angle(t_angle), .tap_s_n(t_s_n), .tap_c_n(t_c_n),
        .tap_pos_full(t_pos),
        .tap_io_state(t_io_state), .tap_io_flags(t_io_flags), .tap_stat(t_stat),
        .tap_cfg_inter(10'd256), .tap_cfg_div(3'd0), .tap_cfg_pairs(5'd4),
        .tap_cfg_hyst_ab(5'd0), .tap_cfg_ablimit(8'd0),
        .tap_cfg_zwidth(4'd4), .tap_cfg_zphase(12'd0), .tap_cfg_uvwph(16'd0),
        .tap_cfg_pol(4'b0000),
        // P7 的七个抽头（v15）：本测试台不测 P7，给固定值 —— 漏接的输入是 z，
        // 会让那一页的通路整片变 X（见 U-17 记录 28）。
        .tap_ofs_s(16'sd0), .tap_ofs_c(16'sd0),
        .tap_gain_s(16'd32768), .tap_gain_c(16'd32768),
        .tap_phase_k(16'sd0), .tap_shift(4'd0), .tap_amp_sq(32'h2000_0000),
        // v21：P7 幅值百分比的门限（本测试台不测 P7 的文字，但给了值才不出 X）
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

    // ------------------------------------------------------------- 计数与断言 --
    integer errors = 0;

    task chki; input [8*72-1:0] label; input integer got, want;
    begin
        if (got !== want) begin
            errors = errors + 1;
            $display("[FAIL] %0s : got %0d want %0d", label, got, want);
        end else
            $display("[ OK ] %0s : %0d", label, got);
    end
    endtask

    // ------------------------------------------------------- 移动光栅上的取样 --
    //   rec_en / rec_y / rec_col 设好之后扫若干行，记录目标行上目标色的首尾 x。
    reg         rec_en  = 1'b0;
    reg  [11:0] rec_y   = 12'd0;
    reg  [23:0] rec_col = 24'hFFFFFF;
    reg  [11:0] rec_x0  = 12'd0, rec_x1 = 12'd4095;
    reg  [11:0] rec_f, rec_l;
    integer     rec_n;

    always @(posedge clk) begin
        if (de_o && rec_en && (dbg_y == rec_y) &&
            (dbg_x >= rec_x0) && (dbg_x <= rec_x1) && (lcd_rgb == rec_col)) begin
            if (rec_n == 0) rec_f <= dbg_x;
            rec_l <= dbg_x;
            rec_n <= rec_n + 1;
        end
    end

    integer sx, sy;

    //   连续光栅：x 每拍 +1（这才是"移动"）；只扫需要的那几行，省仿真时间。
    task sweep_rows; input integer y0, y1;
    begin
        for (sy = y0; sy <= y1; sy = sy + 1) begin
            for (sx = 0; sx < 1024; sx = sx + 1) begin
                @(negedge clk);
                px = sx[11:0]; py = sy[11:0]; de = 1'b1;
            end
        end
        @(negedge clk); de = 1'b0;
    end
    endtask

    task measure_r; input integer y_target; input [23:0] col; input integer x0, x1;
    begin
        rec_y = y_target[11:0]; rec_col = col;
        rec_x0 = x0[11:0];      rec_x1 = x1[11:0];
        rec_n = 0; rec_f = 12'hFFF; rec_l = 12'hFFF;
        @(negedge clk);
        rec_en = 1'b1;
        sweep_rows(y_target - 2, y_target + 2);
        @(posedge clk);
        rec_en = 1'b0;
    end
    endtask

    task measure; input integer y_target; input [23:0] col;
    begin
        measure_r(y_target, col, 0, 4095);
    end
    endtask

    // ============================================================ 预置与激励 --
    integer c, k;

    task prep_p2;
    begin
        //   显示面（face=1）整面铺"A 只占第 5 行"，唯独第 100 列是"A 只占第 50 行"。
        //   于是扫 y = 140+50 这一行时，只有第 100 列会命中 A 轨迹色。
        for (c = 0; c < 1024; c = c + 1)
            u_dut.u_wave_ram.mem[11'h400 | c] =
                (c == 100) ? 32'h3232_6363 : 32'h0505_6363;
        force u_dut.u_wave_trace.disp_buf = 1'b1;
        force u_dut.u_wave_trace.wr_buf   = 1'b0;
    end
    endtask

    task prep_p3;
    begin
        for (c = 0; c < 131072; c = c + 1)
            u_dut.u_xy_ram.mem[c] = 1'b0;
        u_dut.u_xy_ram.mem[{1'b1, 8'd70, 8'd50}] = 1'b1;   // 位图格 (bx=50, by=70)
        force u_dut.u_xy_plot.disp_buf = 1'b1;
        force u_dut.u_xy_plot.wr_buf   = 1'b0;
    end
    endtask

    //   P4 的存储不吃预置：它认的是"电角度落在哪一箱"，所以这里**真的把角度推一圈**，
    //   让被测逻辑自己填满 128 个箱 —— 这才是等效时间采样的通路本身。
    task fill_p4;
    begin
        for (k = 0; k < 128; k = k + 1) begin
            @(negedge clk);
            px = 12'd0; py = 12'd0; de = 1'b1;
            t_angle   = k[15:0] * 16'd512;          // 落在第 k 箱
            t_io_state = (k >= 50) ? 8'h01 : 8'h00; // A 在 50 号箱之后为高
            @(posedge clk);
        end
        @(negedge clk); de = 1'b0;
    end
    endtask

    //   P7 的两块曲线 RAM 也不吃预置压力：和第 k 箱对应的屏上列是
    //   x = P7_CVX0 + 4*k = 112 + 4k，带就是 [lo, hi]（相对 P7_CVY0 = 160 的行号）。
    //   第 50 箱：标定前那条只有第 30 行（屏上 y = 190），标定后那条只有第 100 行
    //   （屏上 y = 260）—— 两条不同色、不同行，一次只命中一条。
    task prep_p7;
    begin
        u_dut.u_p7_bef_ram.mem[7'd50] = {8'd30,  8'd30};
        u_dut.u_p7_aft_ram.mem[7'd50] = {8'd100, 8'd100};
        //   本测试台的光栅永远走不到 (1023,599)，所以 vf_start 不会来、p7_view 也就
        //   不会覆写这两块 RAM；仍然把 frz 按住，免得以后改了扫描范围就悄悄失效。
        force u_dut.u_p7_view.frz = 1'b1;
    end
    endtask

    // ================================================================== 主流程 ==
    initial begin
        $display("---- tb_pipe_align: 移动光栅下的管线级数 ----");

        px = 12'd0; py = 12'd0; de = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ---- 预置 ----
        prep_p2;
        prep_p3;
        prep_p7;
        fill_p4;
        repeat (20) @(posedge clk);

        // ---- ① P2：第 100 列的轨迹必须落在 x = 80 + 100 = 180 ----
        page = 3'd1;
        repeat (5) @(posedge clk);
        measure(190, C_TR_A);
        $display("[info] P2 y=190  A 轨迹首/尾 x = %0d / %0d（%0d 个像素）", rec_f, rec_l, rec_n);
        chki("P2 波形第 100 列的落点（移动光栅）", rec_f, 180);

        // ---- ② P3：位图格 (50,70) 必须落在 x = 320 + 2*50 = 420 ----
        page = 3'd2;
        repeat (5) @(posedge clk);
        measure(318, C_ACC);
        $display("[info] P3 y=318  描点首/尾 x = %0d / %0d（%0d 个像素）", rec_f, rec_l, rec_n);
        chki("P3 位图格 (50,70) 的起始列（移动光栅）", rec_f, 420);

        // ---- ③ P4：A 通道在 50 号箱由低变高。v18 起轨迹区是 x=168..1023（856 px）
        //      摊给 128 箱 ⇒ 第 k 箱的列号 = (dx*153)>>10，第 50 箱从 dx=335 起
        //      （(335*153)>>10 = 50.05）⇒ x = 168 + 335 = 503。
        //      高轨 y = 152 + 10 = 162，低轨 y = 152 + 30 = 182。
        page = 3'd3;
        repeat (5) @(posedge clk);
        measure_r(162, C_ACC, 168, 1023);           // C_CH_A 与 C_ACC 同色
        $display("[info] P4 y=162  A 高轨首/尾 x = %0d / %0d（%0d 个像素）", rec_f, rec_l, rec_n);
        //   522 = x=168 的**回绕边沿**（箱 127 高 → 箱 0 低，是真实翻转）1 px
        //       + 箱 50..127 的高轨 521 px（x=503..1023）。
        chki("P4 y=162 A 高轨像素数（含左沿回绕边沿）", rec_n, 522);
        chki("P4 A 高轨右端 = 轨迹区右沿", rec_l, 1023);
        measure_r(162, C_ACC, 169, 502);
        chki("P4 y=162 箱 0..49 段没有高轨（这段只有低轨）", rec_n, 0);
        measure_r(182, C_ACC, 168, 1023);
        $display("[info] P4 y=182  A 低轨首/尾 x = %0d / %0d（%0d 个像素）", rec_f, rec_l, rec_n);
        chki("P4 A 低轨起点 = 轨迹区左沿", rec_f, 168);
        chki("P4 A 低轨终点 = 箱 50 的竖直边沿", rec_l, 503);

        // ---- ③b v21：P4 角度刻度线每 45° 一根 ----
        //      时间轴 y = 452，刻度带 y = 453..461；x = 168 + 107k（0/45/…/315°）。
        //      框线在 x = 80 / 1023、标签分隔线在 x = 167，所以量程取
        //      168..1022 —— 正好只剩这 8 根刻度，数目、首尾位置都能断言。
        measure_r(455, C_GRID, 168, 1022);
        $display("[info] P4 y=455 刻度首/尾 x = %0d / %0d（%0d 个像素）", rec_f, rec_l, rec_n);
        chki("P4 角度刻度根数 = 8（每 45°）", rec_n, 8);
        chki("P4 第 1 根刻度 = 0°", rec_f, 168);
        chki("P4 最后一根刻度 = 315°", rec_l, 917);
        //   旧实现是 lg_tx[6:0] == 0（每 128 px 一根），296 那时是一根刻度；
        //   现在 45° 的刻度在 275 / 382，296 处必须是空的 —— 这条就是"刻度周期
        //   真的改了"的证据，只数根数分不清"8 根 107 px"和"8 根别的间距"。
        measure_r(455, C_GRID, 280, 380);
        chki("P4 刻度不再是 128 px 周期（x=296 处没有线）", rec_n, 0);

        // ---- ④ P7：曲线 RAM 读 + 一级寄存，两块 RAM 同箱号同时读 ----
        //      第 50 箱从 x = P7_CVX0 + 4*50 = 312 起，宽 4 px（箱宽）。
        //      两条曲线各测一次：它们共用同一个箱号，级数一旦不对，两条会**一起**
        //      平移 —— 所以必须都测，只测一条分不清是"箱号算错"还是"级数算错"。
        page = 3'd6;
        repeat (5) @(posedge clk);
        measure_r(190, C_EPRE, 0, 1023);
        $display("[info] P7 y=190  标定前曲线首/尾 x = %0d / %0d（%0d 个像素）", rec_f, rec_l, rec_n);
        chki("P7 第 50 箱「标定前」带的起列（移动光栅）", rec_f, 312);
        chki("P7 第 50 箱「标定前」带的宽度 = 1 个箱宽", rec_n, 4);
        measure_r(260, C_EPOST, 0, 1023);
        $display("[info] P7 y=260  标定后曲线首/尾 x = %0d / %0d（%0d 个像素）", rec_f, rec_l, rec_n);
        chki("P7 第 50 箱「标定后」带的起列（移动光栅）", rec_f, 312);
        chki("P7 第 50 箱「标定后」带的宽度 = 1 个箱宽", rec_n, 4);

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule

`default_nettype wire
