`timescale 1ns / 1ps
//=============================================================================
// tb_pole_counter.v —— pole_counter 自检测试台（打印 TEST PASSED / TEST FAILED）
//-----------------------------------------------------------------------------
// 覆盖内容（★ 2026-11-02 按 v70 的"增量展开"实现更新）
//   1. 复位
//   2. 正转扫描（5 圈）：cycle_cnt += 5，wrap_pos 脉冲 5 次，wrap_neg 0 次，dir=1
//   3. 反转扫描（5 圈）：cycle_cnt -= 5，wrap_neg 5 次，dir=0
//   4. 满周判据（v70 起没有 315°/45° 窗口）：
//        a. 单对 315°→0°、0°→315°（±45°）不得计数
//        b. 8 个 ±90° 步进 = ±2 整周 ⇒ ±2
//   5. 跨零点抖动：
//        a. 350° <-> 0.24° 平衡抖动：净计数 0，且不产生任何满周脉冲
//        b. 13 个样点（= 12 个 +120° 步进）= 4 周 ⇒ glitch_guard=0 计 4 次；
//           glitch_guard=8 时 8 拍保护窗把连续跨周压成 2 次（第 3、12 个样点）
//        c. 扇区内小幅抖动（40.1°..43.4° 内来回）不得产生任何跨零
//   6. in_valid 稀疏（每 4 拍一个有效样点）时仍能正确计数（不假设每拍新样本）
//   7. preset / preset_en、z_window 上升沿 + clr_on_z 清零
//   8. pos_full = {cycle_cnt, angle} 同拍一致
//
// 说明：v70 起 pole_counter 改为"相邻有效样点差分累加、累加量跨 ±2^AW 计一圈"，
//       判据是"真正累积满一周"，因此单看一对样点是否跨零已不足以计数。
//       ★ 差分按 16 位最短有符号弧解释 ⇒ 单步真实转角必须 ≤180°；
//         本板有效样点率 12.5 MHz、电信号 25 kHz，单步仅 0.73°，余量极大。
//=============================================================================
module tb_pole_counter;

    localparam integer AW     = 16;
    localparam integer CW     = 16;
    localparam integer GUARDW = 4;

    reg clk, rst_n;
    reg  [AW-1:0]      angle;
    reg                in_valid;
    reg                z_window;
    reg                clr_on_z;
    reg  signed [CW-1:0] preset;
    reg                preset_en;
    reg  [GUARDW-1:0]  glitch_guard;
    wire signed [CW-1:0] cycle_cnt;
    wire signed [CW+AW-1:0] pos_full;
    wire               dir;
    wire               wrap_pos;
    wire               wrap_neg;
    wire               out_valid;

    pole_counter #(.AW(AW), .CW(CW), .GUARDW(GUARDW)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .angle        (angle),
        .in_valid     (in_valid),
        .z_window     (z_window),
        .clr_on_z     (clr_on_z),
        .preset       (preset),
        .preset_en    (preset_en),
        .glitch_guard (glitch_guard),
        .cycle_cnt    (cycle_cnt),
        .pos_full     (pos_full),
        .dir          (dir),
        .wrap_pos     (wrap_pos),
        .wrap_neg     (wrap_neg),
        .out_valid    (out_valid)
    );

    initial clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz

    integer npos, nneg, fail_cnt, i, t;
    integer cnt_at;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (wrap_pos) npos = npos + 1;
            if (wrap_neg) nneg = nneg + 1;
        end
    end

    task do_reset;
        begin
            rst_n = 1'b0; in_valid = 1'b0; angle = 16'd0;
            z_window = 1'b0; clr_on_z = 1'b0;
            preset = 16'sd0; preset_en = 1'b0; glitch_guard = 4'd0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // 连续推 n 个样点，步进 step（16bit 角度单位，可正可负）
    task sweep;
        input integer n;
        input integer step;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                angle    <= (angle + step) & 16'hFFFF;
                in_valid <= 1'b1;
            end
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (6) @(posedge clk);
        end
    endtask

    // 推一对连续有效样点 a0 -> a1，返回两个跨零脉冲（先补一拍基准）
    task pair;
        input  [AW-1:0] a0;
        input  [AW-1:0] a1;
        output wp;
        output wn;
        begin
            @(posedge clk); angle <= a0; in_valid <= 1'b1;
            @(posedge clk); angle <= a0; in_valid <= 1'b1;
            @(posedge clk); angle <= a1; in_valid <= 1'b1;
            @(posedge clk); in_valid <= 1'b0;
            // a1 这一拍跨零脉冲与 out_valid 同拍寄存（Latency = 2 拍），
            // 必须再等 1 拍才能采到，否则读到的是上一拍的 0
            @(posedge clk);
            @(negedge clk);
            wp = wrap_pos;
            wn = wrap_neg;
        end
    endtask

    // 快速抖动串：连续推入 angles[]（每个样点间隔 1 拍）
    task burst;
        input integer n;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                angle    <= (i % 2 == 0) ? 16'd63716 : 16'd44;  // 350deg / 0.24deg
                in_valid <= 1'b1;
            end
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (20) @(posedge clk);      // 等保护窗过期 + 流水排空
        end
    endtask

    integer wp, wn;
    localparam [AW-1:0] A315 = 16'd57344;   // 315deg
    localparam [AW-1:0] A350 = 16'd63716;   // ~350deg
    localparam [AW-1:0] A044 = 16'd44;      // 0.24deg
    localparam [AW-1:0] A045 = 16'd8192;    // 45.000deg（窗口外）

    initial begin
        fail_cnt = 0;
        $display("================================================================");
        $display(" tb_pole_counter : AW=%0d CW=%0d  跨零窗口 = [2^AW-2^(AW-3), 2^AW) -> [0, 2^(AW-3))",
                 AW, CW);
        $display("   = [57344,65536) -> [0,8192)  即 315deg -> 45deg，Latency = 2 拍");
        $display("================================================================");

        // ---- 1. 复位 -------------------------------------------------------
        do_reset;
        if (cycle_cnt !== 0 || dir !== 1'b1 || wrap_pos !== 1'b0 || wrap_neg !== 1'b0) begin
            $display("  [RESET FAIL] cnt=%0d dir=%b wp=%b wn=%b", cycle_cnt, dir, wrap_pos, wrap_neg);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  [RESET ok  ] cycle_cnt=0 dir=1 无脉冲");
        end

        // ---- 2. 正转 5 圈 --------------------------------------------------
        do_reset; npos = 0; nneg = 0;
        angle = 16'd0;
        sweep(700, 512);                    // 128 拍/圈 -> 5 圈多
        $display("----------------------------------------------------------------");
        $display(" 正转扫描（+512 LSB16/拍）：cycle_cnt=%0d  wrap_pos=%0d  wrap_neg=%0d  dir=%b",
                 cycle_cnt, npos, nneg, dir);
        if (cycle_cnt == 16'sd5 && npos == 5 && nneg == 0 && dir == 1'b1) begin
            $display("  [FWD ok    ] 5 圈 = +5，5 个正跨零脉冲，方向正确");
        end else begin
            $display("  [FWD FAIL  ] 期望 cnt=5 pos=5 neg=0 dir=1");
            fail_cnt = fail_cnt + 1;
        end

        // ---- 3. 反转 5 圈 --------------------------------------------------
        do_reset; npos = 0; nneg = 0;
        angle = 16'd0;
        sweep(700, -512);
        $display("----------------------------------------------------------------");
        $display(" 反转扫描（-512 LSB16/拍）：cycle_cnt=%0d  wrap_pos=%0d  wrap_neg=%0d  dir=%b",
                 cycle_cnt, npos, nneg, dir);
        if (cycle_cnt == -16'sd5 && nneg == 5 && npos == 0 && dir == 1'b0) begin
            $display("  [REV ok    ] 5 圈 = -5，5 个负跨零脉冲，方向正确");
        end else begin
            $display("  [REV FAIL  ] 期望 cnt=-5 pos=0 neg=5 dir=0");
            fail_cnt = fail_cnt + 1;
        end

        // ---- 4. 满周判据（v70 增量展开：必须累积满 360° 才计数） ----------------
        $display("----------------------------------------------------------------");
        $display(" 满周判据：单对 ±45° 不得计数；8 个 ±90° 步进 = ±2 周");
        do_reset; npos = 0; nneg = 0;
        pair(A315, 16'd0, wp, wn);                 // +45°
        if (!wp && !wn) $display("   [HALF45 ok ] 315deg -> 0deg (+45deg) 不计数");
        else begin $display("   [HALF45 FAIL] 315deg/0deg 误计数 wp=%b wn=%b", wp, wn); fail_cnt = fail_cnt + 1; end

        pair(16'd0, A315, wp, wn);                 // −45°
        if (!wp && !wn) $display("   [HALF45 ok ] 0deg -> 315deg (-45deg) 不计数");
        else begin $display("   [HALF45 FAIL] 0deg/315deg 误计数 wp=%b wn=%b", wp, wn); fail_cnt = fail_cnt + 1; end

        // 8 个 +90° 步进 = 恰好 2 整周
        do_reset; npos = 0; nneg = 0; angle = 16'd0;
        @(posedge clk); angle <= 16'd0; in_valid <= 1'b1;      // 基准样点
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk); angle <= (angle + 16'd16384) & 16'hFFFF; in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0; repeat (8) @(posedge clk);
        if (cycle_cnt == 16'sd2 && npos == 2 && nneg == 0) begin
            $display("   [HALF2FWD ok] +90deg x8 = 720deg -> cnt=%0d pos=%0d", cycle_cnt, npos);
        end else begin
            $display("   [HALF2FWD FAIL] 期望 cnt=2 pos=2 neg=0，实得 cnt=%0d pos=%0d neg=%0d",
                     cycle_cnt, npos, nneg);
            fail_cnt = fail_cnt + 1;
        end

        // 8 个 −90° 步进 = 恰好 −2 整周
        do_reset; npos = 0; nneg = 0; angle = 16'd0;
        @(posedge clk); angle <= 16'd0; in_valid <= 1'b1;
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk); angle <= (angle - 16'd16384) & 16'hFFFF; in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0; repeat (8) @(posedge clk);
        if (cycle_cnt == -16'sd2 && nneg == 2 && npos == 0) begin
            $display("   [HALF2REV ok] -90deg x8 = -720deg -> cnt=%0d neg=%0d", cycle_cnt, nneg);
        end else begin
            $display("   [HALF2REV FAIL] 期望 cnt=-2 pos=0 neg=2，实得 cnt=%0d pos=%0d neg=%0d",
                     cycle_cnt, npos, nneg);
            fail_cnt = fail_cnt + 1;
        end

        // ---- 5a. 平衡抖动：净计数必须为 0，且不产生任何"满周"脉冲 -------------
        $display("----------------------------------------------------------------");
        $display(" 跨零点平衡抖动（350deg <-> 0.24deg 交替，glitch_guard=0）");
        do_reset; npos = 0; nneg = 0; glitch_guard = 4'd0;
        cnt_at = cycle_cnt;
        burst(9);
        if (cycle_cnt == 0 && npos == 0 && nneg == 0) begin
            $display("   [JITTER ok ] 净计数 0，±10deg 抖动累积不到 1 周，无脉冲");
        end else begin
            $display("   [JITTER FAIL] 期望 cnt=0 pos=0 neg=0，实得 cnt=%0d pos=%0d neg=%0d",
                     cycle_cnt, npos, nneg);
            fail_cnt = fail_cnt + 1;
        end

        // ---- 5b. 快速单向串：glitch_guard 的作用 ------------------------------
        $display("----------------------------------------------------------------");
        $display(" 快速单向串（13 个样点 = 12 个 +120deg 步进 = 4 周）");
        do_reset; npos = 0; nneg = 0; glitch_guard = 4'd0; angle = 16'd0;
        for (i = 0; i < 13; i = i + 1) begin
            @(posedge clk); angle <= (i == 0) ? 16'd0 : ((angle + 16'd21846) & 16'hFFFF); in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0; repeat (20) @(posedge clk);
        if (cycle_cnt == 16'sd4 && npos == 4 && nneg == 0) begin
            $display("   [GUARD0 ok ] glitch_guard=0：4 周 -> 4 个脉冲");
        end else begin
            $display("   [GUARD0 FAIL] 期望 cnt=4 pos=4 neg=0，实得 cnt=%0d pos=%0d neg=%0d",
                     cycle_cnt, npos, nneg);
            fail_cnt = fail_cnt + 1;
        end

        do_reset; npos = 0; nneg = 0; glitch_guard = 4'd8; angle = 16'd0;
        for (i = 0; i < 13; i = i + 1) begin
            @(posedge clk); angle <= (i == 0) ? 16'd0 : ((angle + 16'd21846) & 16'hFFFF); in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0; repeat (20) @(posedge clk);
        if (npos + nneg == 2) begin
            $display("   [GUARD ok  ] glitch_guard=8：8 拍保护窗把 4 次跨周压成 2 次计数（第 3 拍、第 12 拍）");
        end else begin
            $display("   [GUARD8 FAIL] 期望计 2 次，实得 pos=%0d neg=%0d", npos, nneg);
            fail_cnt = fail_cnt + 1;
        end

        // ---- 5c. 扇区内抖动不得产生任何跨零 --------------------------------
        do_reset; npos = 0; nneg = 0; glitch_guard = 4'd0;
        for (i = 0; i < 60; i = i + 1) begin
            @(posedge clk);
            angle    <= (i % 2 == 0) ? 16'd7300 : 16'd7900;   // 40.1deg / 43.4deg，都在 [0,45)
            in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0; repeat (8) @(posedge clk);
        $display(" 扇区内抖动（40.1deg <-> 43.4deg）：cycle_cnt=%0d 脉冲 pos=%0d neg=%0d",
                 cycle_cnt, npos, nneg);
        if (cycle_cnt == 0 && npos == 0 && nneg == 0) begin
            $display("   [SECTOR ok ] 无跨零、无虚假计数");
        end else begin
            $display("   [SECTOR FAIL] 出现虚假计数");
            fail_cnt = fail_cnt + 1;
        end

        // ---- 6. in_valid 稀疏（每 4 拍一个样点） ---------------------------
        do_reset; npos = 0; nneg = 0;
        angle = 16'd0;
        for (i = 0; i < 700; i = i + 1) begin
            @(posedge clk);
            in_valid <= 1'b1;
            angle    <= (angle + 512) & 16'hFFFF;
            @(posedge clk); in_valid <= 1'b0;
            @(posedge clk);
            @(posedge clk);
        end
        repeat (8) @(posedge clk);
        $display("----------------------------------------------------------------");
        $display(" in_valid 稀疏（每 4 拍 1 个有效样点，+512/样点）：cycle_cnt=%0d 脉冲 pos=%0d",
                 cycle_cnt, npos);
        if (cycle_cnt == 16'sd5 && npos == 5) begin
            $display("   [SPARSE ok ] 稀疏 valid 下计数仍正确（用上一个有效样点做基准）");
        end else begin
            $display("   [SPARSE FAIL] 期望 cnt=5 pos=5");
            fail_cnt = fail_cnt + 1;
        end

        // ---- 7. preset 与 Z 清零 -------------------------------------------
        do_reset;
        preset = 16'sd1000; preset_en = 1'b1;
        @(posedge clk); in_valid <= 1'b1; angle <= 16'd0;
        @(posedge clk); preset_en <= 1'b0; in_valid <= 1'b0;
        repeat (6) @(posedge clk);
        $display("----------------------------------------------------------------");
        if (cycle_cnt == 16'sd1000) begin
            $display("   [PRESET ok ] preset_en 后 cycle_cnt = %0d", cycle_cnt);
        end else begin
            $display("   [PRESET FAIL] cycle_cnt = %0d，期望 1000", cycle_cnt);
            fail_cnt = fail_cnt + 1;
        end

        do_reset;
        clr_on_z = 1'b1;
        angle = 16'd0; in_valid = 1'b1;
        sweep(700, 512);                       // 先走到 +5 圈
        cnt_at = cycle_cnt;
        // Z 上升沿必须落在"有效样点"上才会被执行（非有效样点会挂起等下一个
        // 有效样点），所以这里持续给有效样点，同时制造 z_window 上升沿。
        @(posedge clk); angle <= 16'd40000; in_valid <= 1'b1;
        @(posedge clk); angle <= 16'd40000; in_valid <= 1'b1; z_window <= 1'b1;
        @(posedge clk); angle <= 16'd40000; in_valid <= 1'b1; z_window <= 1'b0;
        repeat (4) @(posedge clk);
        in_valid <= 1'b0;
        repeat (6) @(posedge clk);
        $display("   Z 上升沿清零：%0d -> %0d", cnt_at, cycle_cnt);
        if (cnt_at == 16'sd5 && cycle_cnt == 0) begin
            $display("   [ZCLR ok   ] clr_on_z 生效");
        end else begin
            $display("   [ZCLR FAIL] 期望 5 -> 0");
            fail_cnt = fail_cnt + 1;
        end

        // ---- 8. pos_full 一致性 --------------------------------------------
        do_reset;
        angle = 16'd0; in_valid = 1'b1;
        sweep(300, 512);
        if (pos_full[CW+AW-1:CW] == cycle_cnt[15:0]) begin
            $display("   [POSFULL ok] pos_full 高位 = cycle_cnt = %0d，低位 = 角度", cycle_cnt);
        end else begin
            $display("   [POSFULL FAIL] pos_full=%h cnt=%0d", pos_full, cycle_cnt);
            fail_cnt = fail_cnt + 1;
        end

        $display("================================================================");
        if (fail_cnt == 0)
            $display(" TEST PASSED");
        else
            $display(" TEST FAILED  (fail_cnt=%0d)", fail_cnt);
        $display("================================================================");
        $finish;
    end

endmodule
