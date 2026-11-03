// ============================================================================
//  tb_abz_jitter.v —— ABZ 边沿抖动**量化**测试台（生产配置复核，2026-10-11）
// ----------------------------------------------------------------------------
//  目的（接 docs/DEV_STATUS.md §2.7"剩余（v6）"第 1 项"ABZ 抖动复看"）
//    用**上板实测的同一组配置**，把"ABZ 边沿到底抖多少、抖在哪里、极限在哪"
//    变成可复测的数字，供示波器实测对照。
//
//  为什么会有抖动（机理，先看这段再读代码）
//    abz_gen 的整个时序块是 `if (in_valid)` 门控的（rtl/abz_gen.v:435），
//    而生产配置里 in_valid = loop_filter.out_valid = 抽取后的**样点节拍**：
//        LOG2DEC = 2（rtl/enc_top.v:38）-> filt_valid = 50 MHz / 4 = 12.5 MHz
//        （rtl/decim_avg.v:6 "每 2^LOG2DEC 个输入 valid 输出 1 拍 dout_valid"；
//          rtl/loop_filter.v:189-191 out_valid 只是把 in_valid 打 3 拍，1:1 输出）
//    于是：
//      ① **边沿只能落在 80 ns 的节拍栅格上**（1 节拍 = 4 clk = 80 ns）。
//         理想均匀边沿间隔 = 1 / (4*inter*f_in/div)。inter=256/div=1/f_in=1 kHz
//         时 = 976.6 ns = 12.207 节拍，不是整数 ⇒ 实际间隔只能在 12 与 13 节拍
//         之间交替 ⇒ **峰峰抖动 = 1 节拍 = 80 ns（±40 ns，约 ±4%）**。
//      ② 每个 in_valid 拍**最多点火一次**（rtl/abz_gen.v:489/495 的 ±1），
//         所以 AB 边沿率有硬上限 = filt_valid = 12.5 MHz，
//         即 **inter*f_in/div ≤ 3.125 MHz**（A/B 周期频率 ≤ 3.125 MHz）。
//         越过上限就丢边沿（r_slc_fwd 累积）→ lag_warn/lag_fatal 才会动。
//      ③ 抖动是**节拍量化**而不是"毛刺"：与本项目 v6 治的角度毛刺（5.6° 阈值
//         + 3 拍保持，密度 0.00444 次/输入周期）是**两回事**，后者在进环路前
//         就被按住，不会到这里。
//
//  本测试台的做法
//    隔离例化 abz_gen，喂**理想角度斜坡**（32 位相位累加器，每节拍累加
//    ph_step，angle = ph[31:16]），相位累加器给出的是"实数角度被量化到 16 位"
//    的效果 —— 与板上的 angle 完全同阶（板上 1 kHz/12.5 MHz 时 ≈ 5.24 LSB/拍）。
//    in_valid 按生产节拍（每 4 clk 一个脉冲）驱动。
//
//  三个相位（都与板上真实条件对应）
//    PH1  f_in = 1.000 kHz，in_valid = 12.5 MHz —— **生产配置**（板上 1.002 kHz）
//    PH2  f_in = 10.000 kHz，in_valid = 12.5 MHz —— docs/07 里"10 kHz 输入验证
//         256 倍细分"那一档：需要的边沿率 10.24 MHz 已接近 12.5 MHz 上限，
//         平均间隔只有 1.22 节拍 ⇒ 抖动相对量被放大
//    PH3  f_in = 20.000 kHz，in_valid = 12.5 MHz —— 越过上限（需 20.48 MHz 边沿）
//         ⇒ 必须丢边沿，用来验证 lag_warn 真的会报
//
//  判据（硬断言）
//    PH1: 边沿数 = 4*inter/div * 周期数（±2）；与理想均匀栅格的最大偏差 ≤ 80 ns
//         （1 节拍）；A 占空 50% ±1 节拍；A->B / B->A 相位间隔 = 1 个边沿间隔
//         ±1 节拍（正交关系没坏）；Z = 1 次/输入周期；limiter/lag 全程 0
//    PH2: 边沿数仍精确（未丢沿）；limiter/lag 仍为 0；量化抖动量级打印出来对比
//    PH3: 边沿数明显少于理想（丢沿）；**lag_warn/lag_fatal 必须出现、且无反向点火**
//
//  ★ 2026-10-11（v8 / docs/DEV_STATUS.md §3 item 16 ①+② 修复后）
//    rtl/abz_gen.v 增加了**累加器双向钳位**（r_acc 恒在 [0, acc_th-1]，不再越界
//    回绕成负 ⇒ 不再反向点火），并把钳位拍计入**独立的过速计数 r_ovl**
//    （lag_mag = |pend| + r_ovl）⇒ lag 监视器能看见"每 in_valid 拍最多点火一次"
//    这条硬上限造成的丢沿。r_ovl **不进** limiter_active（后者按契约只表示
//    "限频保持/补发"，见 rtl/abz_gen.v 文件头）。
//    本测试台 PH3 的断言相应由"warn 恒为 0（KNOWN BLIND SPOT）"改为
//    "warn/fatal 必须出现 + 反向点火必须为 0 + limiter 必须仍为 0（只喂 lag）"。
//    PH1/PH2 的判据不变（正常工况单拍步进 << acc_th，永远不进钳位分支）。
//
//  输出
//    - 每个相位的统计表（stdout / sim/logs/tb_abz_jitter.log）
//    - PH1 前 200 个边沿的明细 CSV：abz_edges_ph1.csv
//      （列：edge#, t_clk, interval_clk, err_ns；写在 xsim 工作目录下）
// ============================================================================
`timescale 1ns / 1ps

module tb_abz_jitter;

    localparam integer CLK_HALF  = 10;          // 50 MHz -> 周期 20 ns
    localparam integer DEC       = 4;           // filt_valid = f_clk / 4（LOG2DEC=2）
    localparam integer INTER     = 256;         // 板上 0x0101/0x0102 = 0 -> inter = 256
    localparam integer INTER_W   = 256;         // 同 INTER（10 位口）
    localparam integer DIV       = 1;           // 板上 div = 1
    localparam real    FS_VALID  = 12.5e6;      // 样点节拍频率

    integer errors;

    reg clk;
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // ---------------------------------------------------------------- 激励
    reg         rst_n;
    reg  [1:0]  divc;
    reg         in_valid;
    reg  [31:0] ph;
    reg  [31:0] ph_step;
    reg  [15:0] angle;
    integer     tclk;                            // clk 计数（20 ns 分辨率）
    integer     tick;                            // in_valid 节拍计数

    wire [31:0] ph_nxt = ph + ph_step;

    always @(posedge clk) begin
        if (!rst_n) begin
            divc     <= 2'd0;
            in_valid <= 1'b0;
        end else begin
            divc     <= divc + 2'd1;
            in_valid <= (divc == 2'd2);          // 每 4 拍一个 1 拍宽脉冲
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            ph    <= 32'd0;
            angle <= 16'd0;
            tclk  <= 0;
            tick  <= 0;
        end else begin
            tclk <= tclk + 1;
            if (in_valid) begin
                ph    <= ph_nxt;
                angle <= ph_nxt[31:16];
                tick  <= tick + 1;
            end
        end
    end

    // ---------------------------------------------------------------- DUT
    wire                 a_out, b_out, z_out;
    wire signed [31:0]   edge_cnt;
    wire                 limiter_active, abz_valid, lag_warn, lag_fatal;

    abz_gen #(
        .AW            (16),
        .CLK_PERIOD_NS (20.0)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .angle          (angle),
        .in_valid       (in_valid),
        .inter          (INTER_W[9:0]),
        .div            (3'd0),                 // div = 1
        .hyst           (5'd0),                 // 板上 0x0103 = 0
        .ablimit        (8'd0),                 // 板上 0x0106 = 0 -> 最小间隔 20 ns
        .apol           (1'b0),
        .bpol           (1'b0),
        .zpol           (1'b0),
        .abzdir         (1'b0),
        .abzen          (1'b1),                 // 板上 0x0109 = 0x40
        .z_window       (1'b1),                 // 常开：每输入周期一次 Z
        .z_phase        (12'd0),
        .z_width        (4'd4),                 // 板上 0x0108 低字节 = 4（★ v9 起实际脉冲宽 = 5 个边沿步）
        .a_out          (a_out),
        .b_out          (b_out),
        .z_out          (z_out),
        .edge_cnt       (edge_cnt),
        .limiter_active (limiter_active),
        .out_valid      (abz_valid),
        .lag_warn       (lag_warn),
        .lag_fatal      (lag_fatal)
    );

    // ---------------------------------------------------------------- 统计量
    reg         meas_en;
    reg         a_x, b_x, z_x;                   // 上一拍采样（本块内阻塞赋值）
    real        e_ideal_ns;                      // 理想均匀边沿间隔（ns）
    integer     t_anchor;                        // 第一个边沿的时刻（栅格锚点）
    integer     e_cnt;
    integer     e_iv_min, e_iv_max;
    real        e_iv_sum;
    real        err_absmax;
    integer     arr_cnt, arr_min, arr_max;       // A 上升->上升
    real        arr_sum;
    integer     ahi_cnt, ahi_min, ahi_max;       // A 高电平宽度
    real        ahi_sum;
    integer     qab_cnt, qab_min, qab_max;       // A 跳变 -> 下一个 B 跳变
    real        qab_sum;
    integer     qba_cnt, qba_min, qba_max;       // B 跳变 -> 下一个 A 跳变
    real        qba_sum;
    integer     z_cnt, z_min, z_max;             // Z 脉冲宽度
    integer     lim_hi, warn_hi, fatal_hi;
    integer     cnt_inc, cnt_dec;                // edge_cnt 加/减（正/反向点火）次数
    integer     ec_last;
    reg         ec_v;
    integer     csv_fd, csv_left, csv_on;

    reg         e_last_v;
    integer     e_last_t, iv, i;
    real        err;
    reg         qab_pend, qba_pend;
    integer     qab_t0, qba_t0;
    reg         ahi_v;
    integer     ahi_t0;
    reg         arr_v;
    integer     arr_t0;
    reg         z_v;
    integer     z_t0;

    always @(posedge clk) begin
        if (rst_n && meas_en) begin
            // ---- AB 任意跳变：间隔 + 与理想均匀栅格的偏差 ----
            if ((a_out !== a_x) || (b_out !== b_x)) begin
                e_cnt = e_cnt + 1;
                if (e_cnt == 1) t_anchor = tclk;
                if (e_last_v) begin
                    iv = tclk - e_last_t;
                    if (iv < e_iv_min) e_iv_min = iv;
                    if (iv > e_iv_max) e_iv_max = iv;
                    e_iv_sum = e_iv_sum + iv;
                end
                e_last_t = tclk;
                e_last_v = 1'b1;
                err = (tclk - t_anchor) * 20.0 - (e_cnt - 1) * e_ideal_ns;
                if (err < 0.0) err = -err;
                if (err > err_absmax) err_absmax = err;
                if (csv_on && csv_left > 0) begin
                    $fwrite(csv_fd, "%0d,%0d,%0d,%.1f\n", e_cnt, tclk, iv, err);
                    csv_left = csv_left - 1;
                end
            end

            // ---- A 上升 / 下降 ----
            if ((a_out === 1'b1) && (a_x === 1'b0)) begin
                arr_cnt = arr_cnt + 1;
                if (arr_v) begin
                    iv = tclk - arr_t0;
                    if (iv < arr_min) arr_min = iv;
                    if (iv > arr_max) arr_max = iv;
                    arr_sum = arr_sum + iv;
                end
                arr_t0 = tclk;
                arr_v  = 1'b1;
                ahi_t0 = tclk;
                ahi_v  = 1'b1;
                if (qba_pend) begin
                    iv = tclk - qba_t0;
                    qba_cnt = qba_cnt + 1;
                    if (iv < qba_min) qba_min = iv;
                    if (iv > qba_max) qba_max = iv;
                    qba_sum = qba_sum + iv;
                    qba_pend = 1'b0;
                end
                qab_pend = 1'b1;
                qab_t0   = tclk;
            end else if ((a_out === 1'b0) && (a_x === 1'b1)) begin
                if (ahi_v) begin
                    iv = tclk - ahi_t0;
                    ahi_cnt = ahi_cnt + 1;
                    if (iv < ahi_min) ahi_min = iv;
                    if (iv > ahi_max) ahi_max = iv;
                    ahi_sum = ahi_sum + iv;
                    ahi_v   = 1'b0;
                end
            end

            // ---- B 跳变：完成 A->B，武装 B->A ----
            if (b_out !== b_x) begin
                if (qab_pend) begin
                    iv = tclk - qab_t0;
                    qab_cnt = qab_cnt + 1;
                    if (iv < qab_min) qab_min = iv;
                    if (iv > qab_max) qab_max = iv;
                    qab_sum = qab_sum + iv;
                    qab_pend = 1'b0;
                end
                qba_pend = 1'b1;
                qba_t0   = tclk;
            end

            // ---- Z ----
            if ((z_out === 1'b1) && (z_x === 1'b0)) begin
                z_cnt = z_cnt + 1;
                z_t0  = tclk;
                z_v   = 1'b1;
            end else if ((z_out === 1'b0) && (z_x === 1'b1)) begin
                if (z_v) begin
                    iv = tclk - z_t0;
                    if (iv < z_min) z_min = iv;
                    if (iv > z_max) z_max = iv;
                    z_v = 1'b0;
                end
            end

            // ---- 状态位占空统计 ----
            if (limiter_active) lim_hi   = lim_hi   + 1;
            if (lag_warn)       warn_hi  = warn_hi  + 1;
            if (lag_fatal)      fatal_hi = fatal_hi + 1;

            // ---- 点火方向统计（edge_cnt 加/减）----
            if (edge_cnt !== ec_last) begin
                if (ec_v) begin
                    if (edge_cnt > ec_last) cnt_inc = cnt_inc + 1;
                    else                    cnt_dec = cnt_dec + 1;
                end
                ec_last = edge_cnt;
                ec_v    = 1'b1;
            end

            a_x = a_out;
            b_x = b_out;
            z_x = z_out;
        end
    end

    // ---------------------------------------------------------------- 工具
    task chk(input cond, input [8*80-1:0] label);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("    FAIL: %0s", label);
            end else begin
                $display("    ok  : %0s", label);
            end
        end
    endtask

    task reset_stats;
        begin
            e_cnt = 0; e_iv_min = 1000000; e_iv_max = 0; e_iv_sum = 0.0;
            err_absmax = 0.0; t_anchor = 0;
            arr_cnt = 0; arr_min = 1000000; arr_max = 0; arr_sum = 0.0;
            ahi_cnt = 0; ahi_min = 1000000; ahi_max = 0; ahi_sum = 0.0;
            qab_cnt = 0; qab_min = 1000000; qab_max = 0; qab_sum = 0.0;
            qba_cnt = 0; qba_min = 1000000; qba_max = 0; qba_sum = 0.0;
            z_cnt = 0; z_min = 1000000; z_max = 0;
            lim_hi = 0; warn_hi = 0; fatal_hi = 0;
            cnt_inc = 0; cnt_dec = 0; ec_v = 1'b0;
            e_last_v = 1'b0; e_last_t = 0;
            qab_pend = 1'b0; qba_pend = 1'b0;
            ahi_v = 1'b0; arr_v = 1'b0; z_v = 1'b0;
            a_x = a_out; b_x = b_out; z_x = z_out;
        end
    endtask

    // 跑一个相位：step = 每节拍相位增量，settle/meas 以 clk 计
    task run_phase(input integer step, input integer settle_clk,
                   input integer meas_clk, input [8*8-1:0] nm);
        real f_in, e_rate, rel;
        begin
            ph_step   = step;
            e_ideal_ns = 1.0e9 * 4294967296.0 /
                         (step * FS_VALID * (4.0*INTER/DIV));
            f_in  = step * FS_VALID / 4294967296.0;
            e_rate = (4.0*INTER/DIV) * f_in;
            meas_en = 1'b0;
            reset_stats;
            repeat (settle_clk) @(posedge clk);
            reset_stats;
            meas_en = 1'b1;
            repeat (meas_clk) @(posedge clk);
            meas_en = 1'b0;
            @(posedge clk);

            $display("");
            $display("  === [%0s] f_in = %.3f Hz, filt_valid = 12.5 MHz, inter=%0d div=%0d ===",
                     nm, f_in, INTER, DIV);
            $display("      理想: AB 边沿率 = %.0f /s, 边沿间隔 = %.3f ns = %.3f 节拍",
                     e_rate, e_ideal_ns, e_ideal_ns / 80.0);
            $display("      窗口 %.3f ms", meas_clk * 20.0 / 1.0e6);
            $display("      AB 边沿: n=%0d, 实测平均间隔 = %.3f clk (%.1f ns) = %.3f 节拍",
                     e_cnt, e_iv_sum / (e_cnt - 1), 20.0*e_iv_sum/(e_cnt-1),
                     20.0*e_iv_sum/(e_cnt-1)/80.0);
            $display("               最小 %0d clk, 最大 %0d clk -> 峰峰 = %0d ns (%.2f 节拍)",
                     e_iv_min, e_iv_max, 20*(e_iv_max-e_iv_min),
                     20.0*(e_iv_max-e_iv_min)/80.0);
            rel = 20.0*(e_iv_max-e_iv_min) / (20.0*e_iv_sum/(e_cnt-1)) * 100.0;
            $display("               峰峰抖动/平均间隔 = %.2f %%", rel);
            $display("      与理想均匀栅格的最大偏差 = %.0f ns (%.2f 节拍)",
                     err_absmax, err_absmax/80.0);
            $display("      A 上升->上升: n=%0d, 平均 %.3f clk (%.1f ns), 峰峰 %0d ns",
                     arr_cnt, arr_sum/arr_cnt, 20.0*arr_sum/arr_cnt,
                     20*(arr_max-arr_min));
            $display("      A 高电平:     n=%0d, 平均 %.3f clk (%.1f ns), 峰峰 %0d ns  (占空 %.2f %%)",
                     ahi_cnt, ahi_sum/ahi_cnt, 20.0*ahi_sum/ahi_cnt,
                     20*(ahi_max-ahi_min),
                     100.0*ahi_sum/ahi_cnt/(arr_sum/arr_cnt));
            $display("      A->B 相位:    n=%0d, 平均 %.3f clk (%.1f ns), 峰峰 %0d ns",
                     qab_cnt, qab_sum/qab_cnt, 20.0*qab_sum/qab_cnt,
                     20*(qab_max-qab_min));
            $display("      B->A 相位:    n=%0d, 平均 %.3f clk (%.1f ns), 峰峰 %0d ns",
                     qba_cnt, qba_sum/qba_cnt, 20.0*qba_sum/qba_cnt,
                     20*(qba_max-qba_min));
            $display("      Z: 脉冲 %0d 次, 宽度 %.1f clk (%.3f us) 峰峰 %0d ns",
                     z_cnt, 1.0*z_max, 20.0*z_max/1000.0, 20*(z_max-z_min));
            $display("      limiter 高电平 %0d clk, lag_warn %0d clk, lag_fatal %0d clk",
                     lim_hi, warn_hi, fatal_hi);
            $display("      点火方向: 正向 %0d 次, 反向 %0d 次 (edge_cnt 末值 = %0d)",
                     cnt_inc, cnt_dec, edge_cnt);
        end
    endtask

    // 期望边沿数（实数，按窗口实际时钟数与频率算）
    function real exp_edges;
        input integer step;
        input integer meas_clk;
        begin
            exp_edges = (meas_clk * 1.0) / DEC * (4.0*INTER/DIV) *
                        (step * FS_VALID / 4294967296.0) / FS_VALID;
        end
    endfunction

    // ---------------------------------------------------------------- 主流程
    integer exp_n;

    initial begin
        errors = 0;
        rst_n  = 1'b0;
        ph_step = 32'd343597;                    // 先给个安全值
        meas_en = 1'b0;
        csv_on  = 0;
        csv_left = 0;
        ph = 32'd0; angle = 16'd0;

        $display("================================================================");
        $display(" tb_abz_jitter —— ABZ 边沿抖动量化测试台");
        $display(" 生产配置复核: inter=%0d div=%0d hyst=0 ablimit=0 zwidth=4(★ v9 起宽 = 5 步)", INTER, DIV);
        $display(" 样点节拍 filt_valid = 12.5 MHz (= 50 MHz / 2^LOG2DEC, LOG2DEC=2)");
        $display("================================================================");

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);

        // ---------------- PH1: 1 kHz（生产条件）----------------
        csv_fd = $fopen("abz_edges_ph1.csv", "w");
        if (csv_fd != 0) begin
            $fwrite(csv_fd, "edge,t_clk,interval_clk,err_ns\n");
            csv_on = 1; csv_left = 200;
        end
        run_phase(32'd343597, 4*12500*2, 4*12500*10, "PH1-1kHz");
        csv_on = 0;
        if (csv_fd != 0) $fclose(csv_fd);

        exp_n = 4*INTER/DIV * 10;                // 10 个输入周期的理想边沿数
        $display("");
        $display("  ---- PH1 判据（10 个输入周期 = %0d 个理想 AB 边沿）----", exp_n);
        chk((e_cnt >= exp_n-2) && (e_cnt <= exp_n+2), "PH1-edge-count = 4*inter/div * N");
        chk(err_absmax <= 81.0,  "PH1-jitter <= 1 tick (80ns) vs ideal grid");
        chk((e_iv_max - e_iv_min) <= 8, "PH1-edge-interval pk-pk <= 2 ticks");
        chk((ahi_max - ahi_min) <= 8,   "PH1-A-high-width pk-pk <= 2 ticks");
        chk(lim_hi == 0,        "PH1-limiter never active");
        chk(warn_hi == 0,       "PH1-lag_warn never set");
        chk(fatal_hi == 0,      "PH1-lag_fatal never set");
        chk((z_cnt >= 9) && (z_cnt <= 11), "PH1-Z = 1 per input period (10+-1)");
        chk(cnt_dec == 0,       "PH1-no reverse fire");

        // ---------------- PH2: 10 kHz（docs/07 的高频档）----------------
        // ph_step = 2^32 * 10000 / 12.5e6 = 3435973.8368 -> 3435974
        run_phase(32'd3435974, 4*1250*2, 4*1250*10, "PH2-10kHz");
        exp_n = 4*INTER/DIV * 10;
        $display("");
        $display("  ---- PH2 判据（10 kHz：理想边沿率 10.24 MHz，已贴近 12.5 MHz 上限）----");
        chk((e_cnt >= exp_n-4) && (e_cnt <= exp_n+4), "PH2-edge-count exact (no drop)");
        chk(lim_hi == 0,   "PH2-limiter not active");
        chk(warn_hi == 0,  "PH2-lag_warn not set");
        chk(cnt_dec == 0,  "PH2-no reverse fire");
        $display("      注: 理想平均边沿间隔仅 %.3f 节拍(%.1f ns)，1 节拍量化抖动即占 %.1f %%",
                 e_ideal_ns/80.0, e_ideal_ns, 80.0/e_ideal_ns*100.0);
        $display("          这是 filt_valid = 12.5 MHz 这个**配置**决定的，不是 RTL 缺陷。");

        // ---------------- PH3: 20 kHz（越过上限，20 个输入周期）----------------
        // 20 kHz 时需要的边沿率 = 1024 * 20 kHz = 20.48 MHz > filt_valid 12.5 MHz。
        // 预期（v8 起，item 16 ①+② 修复后）：
        //   ① 边沿被钳在 12.5 MHz（每 in_valid 拍最多点火一次）；
        //   ② r_acc 被**双向钳位**在 [0, acc_th-1] ⇒ 不再越界回绕 ⇒ **无反向点火**；
        //   ③ 钳位拍计入 pending ⇒ lag_warn / lag_fatal **必须出现**。
        // 窗口取 20 个输入周期（1 ms）—— 修复前 r_acc 每拍净增
        // (step_val - acc_th) ≈ 1.6384 - 1 = 0.6384，约 6400 拍（0.51 ms）后
        // 13 位有符号越过 +4095 回绕成负 -> **反向点火突发**，而 lag 全程为 0。
        run_phase(32'd6871948, 4*625*2, 4*625*20, "PH3-20kHz");
        $display("");
        $display("  ---- PH3 判据（20 kHz：需 20.48 MHz 边沿 > 12.5 MHz 上限）----");
        chk(e_cnt < (4*INTER/DIV * 20 * 4 / 5), "PH3-edge-count far below ideal (dropped)");
        chk((e_iv_sum/(e_cnt-1) > 3.9) && (e_iv_sum/(e_cnt-1) < 4.1),
            "PH3-rate pinned to filt_valid (=12.5 MHz, 4 clk)");
        // ★ 2026-10（v8 / item 16 ①+②）：这条从"记录已知盲区（warn 恒 0）"改成
        //   **必须报警**：过速丢沿现在由独立的 r_ovl 计数进入 lag 判据
        //   （lag_mag = |pend| + r_ovl），监视器不再瞎。
        chk(warn_hi > 0,  "PH3-lag_warn SET on overload (blind spot closed)");
        chk(fatal_hi > 0, "PH3-lag_fatal SET on gross overload");
        // ★ 修复前这里是"反向点火 1553 次"的现场告警；钳位后必须为 0。
        chk(cnt_dec == 0, "PH3-no reverse fire (acc clamped, no wrap)");
        // ★★ 设计边界（防止后人把两条路径又合回一个计数器）：过速证据只喂 lag，
        //    **不喂** limiter_active。ablimit=0 时 r_hold 恒空、r_slc_* 恒 0，
        //    所以过载下 limiter 必须仍为 0 —— limiter_active 只表示"限频保持/补发"。
        chk(lim_hi == 0, "PH3-limiter NOT active (overload only sets lag)");
        $display("");
        $display("  ★ 过速保护生效: r_acc 恒在 [0,acc_th-1]，越界量计入独立过速计数 r_ovl");
        $display("     （只喂 lag_warn/lag_fatal，不进 limiter_active —— 见文件头说明）。");
        $display("     实用约束（不变）: inter*f_in/div <= filt_valid/2 = 6.25 MHz（留一半余量）");
        $display("       本配置 inter=256/div=1 -> f_in <= 24.4 kHz；");
        $display("       要跑更高输入率就把 LOG2DEC 从 2 降到 0（filt_valid=50 MHz，需重综合），");
        $display("       或减小 inter。");

        $display("");
        $display("================================================================");
        if (errors == 0) $display(" TEST PASSED (0 errors)");
        else             $display(" TEST FAILED (%0d errors)", errors);
        $display("================================================================");
        $finish;
    end

    // 仿真看门狗
    initial begin
        #200ms;
        $display(" TEST FAILED (watchdog timeout)");
        $finish;
    end

endmodule
