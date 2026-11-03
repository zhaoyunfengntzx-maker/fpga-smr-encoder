`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
//  tb_lcd_timing.v  --  lcd_test/rtl/lcd_timing_gen.v 自检台
//
//  被测屏：正点原子 ATK-7016（7 寸 1024x600）
//      H = 20 / 140 / 1024 / 160  ->  行总 1344
//      V =  3 /  20 /  600 /  12  ->  帧总  635
//      帧时钟数 = 635 * 1344 = 853440，50MHz => 58.60 Hz
//
//  ★★ 两个"单位"陷阱（第一版测试台就是栽在这两处，务必看清）★★
//
//  1) H_* 的单位是「像素」，V_* 的单位是「行」。
//     场同步低电平不是 3 个 clk，而是横跨 v_sync 个**整行** = 3 * 1344 = 4032 个 clk。
//     第一版把 vs 低电平期望写成 3，实测 4031，误判成 RTL 错误。
//
//  2) 本模块的输出寄存器**只在 pixel_en 有效的那拍更新**，所以
//     "像素域计数器"（line_gap / de_line / de_frame / hs_low）计到的是**像素数**，
//     不论 pixel_en = 1 还是 1/2，它们的值都一样；
//     只有**原始 clk 域计数器**（frame_clk_cap / vs_low_clk）才能反映"一帧真实花了多少时间"。
//     第一版用像素域计数器去判"pixel_en=1/2 时帧周期应翻倍"，必然 FAIL，且掩盖了真正要看的东西。
//
//  ★ 本测试台的核心回归判据（测试 2）：
//      像素域数字**不变**（行周期 1344 像素、每帧 614400 像素）
//      原始 clk 域帧周期**翻倍**（1706880 clk）
//    这两条同时成立，才证明 lcd_timing_gen 的 vcnt **没有**被 pixel_en 门控
//    （早期版本把 hcnt/vcnt 一起放进 `else if (ce)`，会让 58.6Hz 的屏掉到 29.3Hz，
//     而画面只是"暗一点"，极难发现）。
//
//  日志标签一律用 ASCII：本机控制台是 GBK，xsim 输出 UTF-8 中文会变乱码，
//  ASCII 标签可以直接 grep，不受代码页影响。
// -----------------------------------------------------------------------------

module tb_lcd_timing;

    // ---- ATK-7016 时序参数 ----
    localparam H_SYNC = 20, H_BACK = 140, H_DISP = 1024, H_FRONT = 160;
    localparam V_SYNC =  3, V_BACK =  20, V_DISP =  600, V_FRONT =  12;
    localparam H_TOTAL = H_SYNC + H_BACK + H_DISP + H_FRONT;   // 1344
    localparam V_TOTAL = V_SYNC + V_BACK + V_DISP + V_FRONT;   //  635

    reg clk = 1'b0;
    always #10 clk = ~clk;                                     // 50 MHz

    reg  rst_n  = 1'b0;
    reg  [3:0] ce_div = 4'd1;
    reg  [3:0] ce_cnt = 4'd0;
    wire pixel_en = (ce_cnt == (ce_div - 4'd1));               // ce_div=1 时恒为 1

    wire        lcd_hs, lcd_vs, lcd_de;
    wire [11:0] pix_x, pix_y;
    wire        frame_st, line_st;

    lcd_timing_gen u_tmg (
        .clk_pix  (clk),
        .rst_n    (rst_n),
        .pixel_en (pixel_en),
        .h_sync   (H_SYNC[11:0]),
        .h_back   (H_BACK[11:0]),
        .h_disp   (H_DISP[11:0]),
        .h_front  (H_FRONT[11:0]),
        .v_sync   (V_SYNC[11:0]),
        .v_back   (V_BACK[11:0]),
        .v_disp   (V_DISP[11:0]),
        .v_front  (V_FRONT[11:0]),
        .lcd_hs   (lcd_hs),
        .lcd_vs   (lcd_vs),
        .lcd_de   (lcd_de),
        .pix_x    (pix_x),
        .pix_y    (pix_y),
        .frame_st (frame_st),
        .line_st  (line_st)
    );

    // 像素使能分频器：ce_cnt 在 0..ce_div-1 循环
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             ce_cnt <= 4'd0;
        else if (pixel_en)      ce_cnt <= 4'd0;
        else                    ce_cnt <= ce_cnt + 4'd1;
    end

    // ---- 计数器：像素域（pixel_en 门控，单位 = 像素） ----
    integer de_frame, de_frame_cap;     // 一帧内 de 高电平的像素数
    integer de_line,  de_line_max;      // 一行内 de 高电平的像素数（取最大）
    integer lines_frame, lines_frame_cap;   // 一帧内的行同步下降沿数
    integer line_gap, line_gap_cap;     // 相邻两次 line_st 之间的像素数
    integer hs_low,  hs_low_cap;        // 行同步低电平的像素数（取最大）

    // ---- 计数器：原始 clk 域（不受 pixel_en 门控，单位 = 50MHz clk） ----
    integer frame_clk, frame_clk_cap;   // 相邻两次场同步下降沿之间的 clk 数
    integer vs_low_clk, vs_low_last;    // 场同步低电平横跨的 clk 数

    integer frames_seen;                // 场同步下降沿计数（用于对齐测量窗口）
    reg     vs_d;
    reg     hs_prev;                    // 像素域行同步历史（判沿用，只在 pixel_en 拍更新）
    integer errors;
    real    fps;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_frame <= 0; de_frame_cap <= 0;
            de_line  <= 0; de_line_max  <= 0;
            lines_frame <= 0; lines_frame_cap <= 0;
            line_gap <= 0; line_gap_cap <= 0;
            hs_low   <= 0; hs_low_cap   <= 0;
            frame_clk <= 0; frame_clk_cap <= 0;
            vs_low_clk <= 0; vs_low_last <= 0;
            frames_seen <= 0;
            hs_prev <= 1'b1; vs_d <= 1'b1;
        end
        else begin
            vs_d <= lcd_vs;
            frame_clk <= frame_clk + 1;

            // 场同步低电平宽度（原始 clk 域；上升沿时把本次宽度锁存到 vs_low_last）
            if (vs_d && !lcd_vs) begin
                vs_low_clk <= 0;
            end
            else if (!vs_d && lcd_vs) begin
                vs_low_last <= vs_low_clk + 1;
                vs_low_clk  <= 0;
            end
            else if (!lcd_vs) begin
                vs_low_clk <= vs_low_clk + 1;
            end
            else begin
                vs_low_clk <= 0;
            end

            // ---------------- 像素域 ----------------
            if (pixel_en) begin
                if (lcd_de) begin
                    de_frame <= de_frame + 1;
                    de_line  <= de_line + 1;
                    if ((de_line + 1) > de_line_max) de_line_max <= de_line + 1;
                end

                // 行同步下降沿：必须用「像素域历史值」hs_prev 判沿，不能用每 clk 采样的 hs_d。
                // 原因：lcd_hs 只在 pixel_en 有效的那拍更新；pixel_en=1/2 时，
                // 若用 hs_d（每 clk 更新），下降沿会在两个 pixel_en 拍之间"漏掉"，
                // 实测会把 635 行数成 0 行。
                if (hs_prev && !lcd_hs) begin
                    lines_frame <= lines_frame + 1;
                    de_line     <= 0;
                end
                hs_prev <= lcd_hs;

                if (!lcd_hs) begin                  // 行同步低电平宽度（像素计）
                    hs_low <= hs_low + 1;
                end
                else begin
                    if (hs_low > hs_low_cap) hs_low_cap <= hs_low;
                    hs_low <= 0;
                end

                if (line_st) begin                  // 相邻 line_st 间距（+1 补上本拍）
                    line_gap_cap <= line_gap + 1;
                    line_gap     <= 0;
                end
                else begin
                    line_gap <= line_gap + 1;
                end
            end

            // ---------------- 帧边界（放在最后，边界拍的重置优先） ----------------
            if (vs_d && !lcd_vs) begin
                frames_seen   <= frames_seen + 1;
                frame_clk_cap <= frame_clk + 1;     // +1 补上本拍
                frame_clk     <= 0;
                de_frame_cap  <= de_frame;
                de_frame      <= 0;
                lines_frame_cap <= lines_frame;
                lines_frame     <= 0;
            end
        end
    end

    // ---- 判据：区间检查 ----
    task check_range;
        input [8*40:1] name;
        input integer  got;
        input integer  exp;
        input integer  tol;
        begin
            if ((got >= (exp - tol)) && (got <= (exp + tol))) begin
                $display("  [ OK ] %0s = %0d  (expect %0d +/-%0d)", name, got, exp, tol);
            end
            else begin
                $display("  [FAIL] %0s = %0d  (expect %0d +/-%0d)", name, got, exp, tol);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        rst_n  = 1'b0;
        ce_div = 4'd1;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;

        // ================= 测试 1：pixel_en 恒 1（50MHz 直驱 1024x600） =================
        wait (frames_seen == 2);        // 第 1 帧已完整走完
        #1;
        $display("---- TEST 1: pixel_en = 1 (50MHz direct, ATK-7016) ----");
        check_range("line_period(pix)",   line_gap_cap,    H_TOTAL,              0);
        check_range("de_per_line(pix)",   de_line_max,    H_DISP,               0);
        check_range("de_per_frame(pix)",  de_frame_cap,   H_DISP * V_DISP,      0);
        check_range("lines_per_frame",    lines_frame_cap, V_TOTAL,             1);
        check_range("frame_period(clk)",  frame_clk_cap,  H_TOTAL * V_TOTAL,    2);
        check_range("hs_low(pix)",        hs_low_cap,     H_SYNC,               1);
        check_range("vs_low(clk)",        vs_low_last,    V_SYNC * H_TOTAL,     4);
        fps = 50000000.0 / frame_clk_cap;
        $display("  refresh = %0.2f Hz  (frame = %0d clk = %0.3f ms)",
                 fps, frame_clk_cap, frame_clk_cap * 20.0 / 1000000.0);

        // ================= 测试 2：pixel_en = 1/2（等效 25MHz 像素时钟） =================
        ce_div = 4'd2;
        wait (frames_seen == 4);        // 第 3 帧是切换瞬间的混合帧，第 4 帧才是完整的
        #1;
        $display("---- TEST 2: pixel_en = 1/2 (equiv 25MHz pixel clock) ----");
        // 像素域数字必须**不变**（单位是像素，与 pixel_en 无关）
        check_range("line_period(pix)",   line_gap_cap,    H_TOTAL,              0);
        check_range("de_per_frame(pix)",  de_frame_cap,   H_DISP * V_DISP,      0);
        check_range("lines_per_frame",    lines_frame_cap, V_TOTAL,             1);
        // 原始 clk 域必须**翻倍** —— 这一条才是"vcnt 未被 pixel_en 门控"的回归判据
        check_range("frame_period(clk) x2", frame_clk_cap, 2 * H_TOTAL * V_TOTAL, 4);
        check_range("vs_low(clk) x2",       vs_low_last,   2 * V_SYNC * H_TOTAL,  8);
        fps = 50000000.0 / frame_clk_cap;
        $display("  refresh = %0.2f Hz  (frame = %0d clk)", fps, frame_clk_cap);

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 超时保护（正常情况下约 85ms 仿真时间即可跑完）
    initial begin
        #200_000_000;
        $display("TEST FAILED: timeout (frames_seen = %0d)", frames_seen);
        $finish;
    end

endmodule
