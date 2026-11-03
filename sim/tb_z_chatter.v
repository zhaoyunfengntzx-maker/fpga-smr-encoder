// ============================================================================
//  tb_z_chatter.v  --  Z 索引脉冲"停位抖动喘振"回归（v75 修复验收）
// ----------------------------------------------------------------------------
//  背景（板上实测，见任务记录）：0x054A 的 Z 计数绝对值曾达 12,128,530，而
//  实际只转约 4001 转；z_rate.py 实测"转动时严格 1 Z/转"（12.00 Hz↔457 rpm、
//  8.32 Hz↔499 rpm、15.56 Hz↔933.8 rpm）⇒ 差额全部来自**转轴停在索引位附近
//  时的抖动**：角度在 0° 附近来回，旧实现的 ang_wrap_f/b 交替触发、rev_cnt
//  在 0/1 之间翻，每翻回 0 就再出一次 Z（抖动频率约 3 kHz）。
//
//  被测链（与 rtl/enc_top.v 内部接线一致）：
//      z_index_gen（rtl/abz_gen.v 内，v75 从 enc_top 抽出）
//          └─ z_window ─→ abz_gen 的 Z 通道 ─→ z_out
//
//  ★ 角度语义：z_index_gen 的 angle 每回绕 2^16 算一个"电周期"；Z 事件对齐到
//    rev_cnt 的低 POLE_BITS 位。生产配置 POLE_BITS=11（每 2048 个电周期一个 Z），
//    本 TB 用 POLE_BITS=0（每个回绕一个 Z，即"1 圈 = 1 个回绕"），这样
//    "3 圈 = 3 个 Z" 才与任务书的口径一致；POLE_BITS=11 的路径另由场景 E 覆盖。
//
//  场景（均在同一份 DUT 上一次跑完；每个场景前复位并清零计数）：
//    A 停位抖动：角度在 0° 附近 ±36 LSB（±0.2°，均匀随机，逐样本）
//                连续 62,500 个有效样点（12.5 MHz 采样 ⇒ 5.0 ms，≈15 个 3 kHz
//                抖动周期），断言 z_out 上升沿 ≤ 1。
//    B 正向匀速：0.73°/样本（≈25 kHz 电信号，131 LSB/样本）转 3 圈，
//                断言恰好 3 个 Z 且两两间隔 40 µs ±2%。
//    C 反向一圈：同样 −131 LSB/样本返回，断言恰好 1 个 Z。
//    D 停位→离开→回来：抖 20,000 样点（1.6 ms，≈5 个 3 kHz 周期）→ 正向
//                半圈（250 样点）→ 反向回到索引位 → 再抖 20,000 样点，
//                断言 Z 总数 = 2（进入时 1 个 + 离开再回来 1 个）。
//    E 生产极对数口径核对：另一份 POLE_BITS=11 的 z_index_gen 实例，转 2048 个
//                电周期，断言恰好 1 个 z_idx_evt（证明 TL 口径没被改坏）。
//
//  用法： vsim -c -do "run -all; quit -f" tb_z_chatter [+LEGACY]
//         +LEGACY：把 u_z.z_armed 强制为 1（复现 v75 之前"无 arm"的行为），
//                   只作对照打印，不计入 PASS/FAIL。
// ============================================================================
`timescale 1ns / 1ps

module tb_z_chatter;

    localparam integer AW        = 16;
    localparam integer POLE_BITS = 0;          // 本 TB：每个角度回绕 = 一个 Z
    localparam integer CW        = 32;
    localparam real    TCLK_NS   = 80.0;       // 12.5 MHz 有效采样
    localparam integer N_JIT     = 62500;      // 场景 A 的抖动样点数（5.0 ms）
    localparam integer N_JIT_D   = 20000;      // 场景 D 每段抖动样点数（1.6 ms）
    localparam integer STEP      = 131;        // 0.73°/样本 = 131 LSB/样本
    localparam integer N_REV     = 1506;       // 3 圈 = 196,608 LSB（502 样点/圈）
    localparam integer N_REV1    = 505;        // 1 圈

    // ---------------------------------------------------------------- 时钟
    reg clk = 1'b0;
    always #(TCLK_NS/2.0) clk = ~clk;

    reg          rst_n     = 1'b0;
    reg  [15:0]  angle     = 16'd0;
    wire         z_window, z_idx_evt, z_armed;

    z_index_gen #(
        .AW        (AW),
        .POLE_BITS (POLE_BITS),
        .CW        (CW)
    ) u_z (
        .clk       (clk),
        .rst_n     (rst_n),
        .angle     (angle),
        .in_valid  (1'b1),
        .z_window  (z_window),
        .z_idx_evt (z_idx_evt),
        .z_armed_o (z_armed)
    );

    wire a_out, b_out, z_out, limiter_active, out_valid, lag_warn, lag_fatal;
    wire signed [31:0] edge_cnt;

    abz_gen #(
        .AW           (AW),
        .CLK_PERIOD_NS(TCLK_NS)
    ) u_abz (
        .clk           (clk),
        .rst_n         (rst_n),
        .angle         (angle),
        .in_valid      (1'b1),
        .inter         (10'd256),
        .div           (3'd0),
        .hyst          (5'd0),
        .ablimit       (8'd0),
        .apol          (1'b0),
        .bpol          (1'b0),
        .zpol          (1'b0),
        .abzdir        (1'b0),
        .abzen         (1'b1),
        .z_window      (z_window),
        .z_phase       (12'd0),
        .z_width       (4'd15),        // 16 个边沿步 ⇒ 脉宽 > 窗口，避免同窗二次装载
        .a_out         (a_out),
        .b_out         (b_out),
        .z_out         (z_out),
        .edge_cnt      (edge_cnt),
        .limiter_active(limiter_active),
        .out_valid     (out_valid),
        .lag_warn      (lag_warn),
        .lag_fatal     (lag_fatal)
    );

    // ------------------------------------------------------- 场景 E（POLE_BITS=11）
    reg  [15:0] ang11 = 16'd0;
    wire        evt11, win11;

    z_index_gen #(
        .AW        (AW),
        .POLE_BITS (11),
        .CW        (CW)
    ) u_z11 (
        .clk       (clk),
        .rst_n     (rst_n),
        .angle     (ang11),
        .in_valid  (1'b1),
        .z_window  (win11),
        .z_idx_evt (evt11),
        .z_armed_o ()
    );

    // ---------------------------------------------------------------- 计数
    integer z_evt_cnt, z_win_cnt, z_out_cnt;
    integer evt11_cnt;
    reg     z_out_d, z_win_d;
    time    t_edge [0:63];

    always @(posedge clk) begin
        if (!rst_n) begin
            z_evt_cnt = 0;
            z_win_cnt = 0;
            z_out_cnt = 0;
            evt11_cnt = 0;
            z_out_d   = 1'b0;
            z_win_d   = 1'b0;
        end else begin
            if (z_idx_evt)                 z_evt_cnt = z_evt_cnt + 1;
            if (z_window && !z_win_d)      z_win_cnt = z_win_cnt + 1;
            if (z_out && !z_out_d) begin
                z_out_cnt = z_out_cnt + 1;
                if (z_out_cnt < 64) t_edge[z_out_cnt] = $time;
            end
            if (evt11)                     evt11_cnt = evt11_cnt + 1;
            z_out_d = z_out;
            z_win_d = z_window;
        end
    end

    // ---------------------------------------------------------------- 工具
    integer i, k, errors;
    integer fwd_n;             // 记录到的 Z 沿数
    time    t0, dt, dt_min, dt_max;

    task do_reset;
        begin
            rst_n = 1'b0;
            angle = 16'd0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            z_evt_cnt = 0; z_win_cnt = 0; z_out_cnt = 0; z_out_d = 1'b0;
            fwd_n = 0;
            @(negedge clk);
        end
    endtask

    task drive;                // 驱动一个样点（时钟周期）
        input [15:0] a;
        begin
            angle = a;
            @(negedge clk);
        end
    endtask

    // ================================================================ 主流程
    integer legacy_a;
    integer dith;
    integer cnt_a, cnt_b, cnt_c, cnt_d, cnt_e;
    real    iv, iv_ref, iv_err;

    initial begin
        errors = 0;
        if (!$value$plusargs("LEGACY=%d", legacy_a)) legacy_a = 0;

        $display("---------------------------------------------------------------");
        $display(" tb_z_chatter : Z index chatter regression (v75 arm fix)");
        $display("   clamp = %0t per sample, N_JIT=%0d, step=%0d LSB", TCLK_NS*1ns, N_JIT, STEP);
        $display("---------------------------------------------------------------");

        // ---------------------------------------------------------- 场景 A
        do_reset;
        if (legacy_a) begin
            force u_z.z_armed = 1'b1;   // 复现"无 arm"的旧行为，仅作对照
            $display("[Z-A][LEGACY] armed forced to 1 (pre-v75 behaviour)");
        end
        for (i = 0; i < N_JIT; i = i + 1) begin
            dith = $random % 37;                    // −36 … +36 LSB = ±0.198°
            drive(dith[15:0]);
        end
        cnt_a = z_out_cnt;
        if (legacy_a) begin
            $display("[Z-A][LEGACY] z_out edges = %0d  (old impl would chatter)",
                     z_out_cnt);
            $display("RESULT-A-LEGACY: %0d edges in %0d samples", z_out_cnt, N_JIT);
            release u_z.z_armed;
            legacy_a = 0;
        end else begin
            $display("[Z-A] samples=%0d (%.3f ms)  z_idx_evt=%0d  z_window=%0d  z_out_edges=%0d",
                     N_JIT, N_JIT*TCLK_NS/1.0e6, z_evt_cnt, z_win_cnt, z_out_cnt);
            if (z_out_cnt <= 1) begin
                $display("RESULT-A: PASS  (z_out edges = %0d <= 1)", z_out_cnt);
            end else begin
                $display("RESULT-A: FAIL  (z_out edges = %0d > 1)  ** CHATTER **", z_out_cnt);
                errors = errors + 1;
            end
        end

        // ---------------------------------------------------------- 场景 B
        do_reset;
        for (i = 0; i < N_REV; i = i + 1) begin
            drive(angle + STEP);
        end
        cnt_b = z_out_cnt;
        $display("[Z-B] samples=%0d  z_idx_evt=%0d  z_out_edges=%0d",
                 N_REV, z_evt_cnt, z_out_cnt);
        if (z_out_cnt == 3) begin
            // 间隔检查
            dt_min = 64'hFFFF_FFFF; dt_max = 0;
            for (k = 2; k <= z_out_cnt; k = k + 1) begin
                dt = t_edge[k] - t_edge[k-1];
                if (dt < dt_min) dt_min = dt;
                if (dt > dt_max) dt_max = dt;
                $display("       interval[%0d] = %0d ns", k-1, dt);
            end
            // 名义间隔 = 65536/131*80ns = 40022 ns；±2% = 784 ns
            iv_ref = (65536.0/STEP) * TCLK_NS;
            iv = (dt_max + dt_min) / 2.0;
            iv_err = ((dt_max - dt_min) / 2.0) / iv_ref;
            $display("       nominal interval = %.1f ns, measured mid = %.1f ns, spread = %.3f%%",
                     iv_ref, iv, iv_err*100.0);
            if (iv_err <= 0.02) begin
                $display("RESULT-B: PASS  (exactly 3 Z, spacing within +-2%%)");
            end else begin
                $display("RESULT-B: FAIL  (spacing spread %.3f%% > 2%%)", iv_err*100.0);
                errors = errors + 1;
            end
        end else begin
            $display("RESULT-B: FAIL  (expected 3 Z, got %0d)", z_out_cnt);
            errors = errors + 1;
        end

        // ---------------------------------------------------------- 场景 C
        do_reset;
        // 从索引位前方 2000 LSB 起步再反向转一圈：避免"起始就压在索引位"时
        // 第一个样点自身就算一次过零（那会把 1 圈数成 2 次过零）。
        drive(16'd2000);
        for (i = 0; i < N_REV1; i = i + 1) begin
            drive(angle - STEP);
        end
        cnt_c = z_out_cnt;
        $display("[Z-C] samples=%0d  z_idx_evt=%0d  z_out_edges=%0d",
                 N_REV1, z_evt_cnt, z_out_cnt);
        if (z_out_cnt == 1) begin
            $display("RESULT-C: PASS  (exactly 1 Z for one reverse revolution)");
        end else begin
            $display("RESULT-C: FAIL  (expected 1 Z, got %0d)", z_out_cnt);
            errors = errors + 1;
        end

        // ---------------------------------------------------------- 场景 D
        do_reset;
        for (i = 0; i < N_JIT_D; i = i + 1) begin
            dith = $random % 37;
            drive(dith[15:0]);
        end
        $display("[Z-D] phase1 (jitter %0d samples): z_out=%0d", N_JIT_D, z_out_cnt);
        for (i = 0; i < 250; i = i + 1) drive(angle + STEP);      // 正向半圈
        for (i = 0; i < 250; i = i + 1) drive(angle - STEP);      // 回到索引位
        for (i = 0; i < N_JIT_D; i = i + 1) begin
            dith = $random % 37;
            drive(dith[15:0]);
        end
        cnt_d = z_out_cnt;
        $display("[Z-D] total z_idx_evt=%0d  z_out_edges=%0d  (expect 2)", z_evt_cnt, z_out_cnt);
        if (z_out_cnt == 2) begin
            $display("RESULT-D: PASS  (2 Z: one entering, one after leaving and returning)");
        end else begin
            $display("RESULT-D: FAIL  (expected 2 Z, got %0d)", z_out_cnt);
            errors = errors + 1;
        end

        // ---------------------------------------------------------- 场景 E
        do_reset;
        // 1024 LSB/样点（64 样点/电周期），恰好转满 2048 个电周期
        for (i = 0; i < 2048*64; i = i + 1) begin
            ang11 = ang11 + 16'd1024;
            @(negedge clk);
        end
        cnt_e = evt11_cnt;
        $display("[Z-E] POLE_BITS=11 instance: %0d samples (2048 electrical cycles), z_idx_evt=%0d (expect 1)",
                 i, evt11_cnt);
        if (evt11_cnt == 1) begin
            $display("RESULT-E: PASS  (production pole alignment unchanged: 1 Z / 2048 cycles)");
        end else begin
            $display("RESULT-E: FAIL  (expected 1 event in 2048 electrical cycles, got %0d)", evt11_cnt);
            errors = errors + 1;
        end

        $display("---------------------------------------------------------------");
        if (errors == 0) $display("TB_Z_CHATTER: TEST PASSED");
        else             $display("TB_Z_CHATTER: TEST FAILED (%0d error(s))", errors);
        $display("---------------------------------------------------------------");
        $finish;
    end

    // 调试探针（+DBG）
    integer dbg_en;
    initial if (!$value$plusargs("DBG=%d", dbg_en)) dbg_en = 0;
    always @(posedge clk) begin
        if (dbg_en && rst_n && (z_idx_evt || u_abz.z_load))
            $display("DBG t=%0t ang=%0d win=%b idx_evt=%b xing=%b ph_hi=%b prev_hi=%b load=%b rza=%b zout=%b inv=%b",
                     $time, angle, z_window, z_idx_evt, u_abz.z_xing, u_abz.z_ph_hi,
                     u_abz.r_z_prev_hi, u_abz.z_load, u_abz.r_z_active, z_out, u_abz.in_valid);
    end

    // 超时保护
    initial begin
        #(50ms);
        $display("TB_Z_CHATTER: TIMEOUT at %0t", $time);
        $finish;
    end

endmodule
