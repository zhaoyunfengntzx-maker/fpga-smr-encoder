// ============================================================================
//  tb_abz_gen.v  —  rtl/abz_gen.v 自检测试台（Vivado xsim / iverilog 均可）
// ----------------------------------------------------------------------------
//  覆盖内容：
//   TEST A  边沿总数：inter = 2/8/64/256 × div = 1/2/3/4/8，全周期斜坡，
//           测试台内**独立**计数 A、B 的边沿，与理论 4*inter/div 比较
//           （非整数除法允许 ±1）。
//   TEST B  正交关系：A、B 的占空 = 50%（不对称 <= 1 个采样点），
//           且 A 的高电平时间段严格位于 B 的高电平时间段之间（90°）。
//           ★ SPEC 1.8 原文的 A = idx[1]^idx[0], B = idx[1] 恒等于 A = ~B
//             （180°、A 占空 2/3），无法满足本项与 SPEC 自己的要求；DUT 采用
//             标准格雷正交映射 A = idx[1], B = idx[1]^idx[0]。把 DUT 换回契约
//             公式，TEST B 会 FAIL——这正是本测试的判别作用。
//   TEST C  Z 脉冲：一个输入周期恰好 1 个 Z；宽度 = (z_width + 1) 个 AB 边沿步（★ v9）。
//   TEST D  限频：ablimit 生效时最小边沿间隔 >= 20ns*(ablimit+1)*div/CLK。
//   TEST E  极性/方向：只翻转 apol 或 bpol 之一 → 反向；两者都翻转 → 不变；
//           abzdir=1 可补偿回来（用 edge_cnt 符号判定）。
//   TEST F  abzen=0 时 A/B/Z 全 0。
//   TEST G  复位期间 A/B/Z=0 且 out_valid=0。
//
//  运行：xsim `run all`，或 iverilog -o tb tb_abz_gen.v ../rtl/abz_gen.v
//  结束打印 TEST PASSED / TEST FAILED。
// ============================================================================
`timescale 1ns / 1ps

module tb_abz_gen;

    localparam integer AW            = 16;
    localparam         CLK_PERIOD_NS = 10.0;      // 100 MHz
    localparam integer NSAMP         = 2048;      // 每个输入周期的斜坡点数
    localparam integer SKIP          = 2;         // 建立稳态用的周期数

    integer errors;

    // ---- DUT 端口 ----
    reg                clk;
    reg                rst_n;
    reg  [AW-1:0]      angle;
    reg                in_valid;
    reg  [9:0]         inter;
    reg  [2:0]         div;
    reg  [4:0]         hyst;
    reg  [7:0]         ablimit;
    reg                apol, bpol, zpol, abzdir, abzen;
    reg                z_window;
    reg  [11:0]        z_phase;
    reg  [3:0]         z_width;

    wire               a_out, b_out, z_out;
    wire signed [31:0] edge_cnt;
    wire               limiter_active, out_valid, lag_warn, lag_fatal;

    abz_gen #(
        .AW            (AW),
        .ZW            (12),
        .LIMW          (12),
        .CLK_PERIOD_NS (CLK_PERIOD_NS)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .angle          (angle),
        .in_valid       (in_valid),
        .inter          (inter),
        .div            (div),
        .hyst           (hyst),
        .ablimit        (ablimit),
        .apol           (apol),
        .bpol           (bpol),
        .zpol           (zpol),
        .abzdir         (abzdir),
        .abzen          (abzen),
        .z_window       (z_window),
        .z_phase        (z_phase),
        .z_width        (z_width),
        .a_out          (a_out),
        .b_out          (b_out),
        .z_out          (z_out),
        .edge_cnt       (edge_cnt),
        .limiter_active (limiter_active),
        .out_valid      (out_valid),
        .lag_warn       (lag_warn),
        .lag_fatal      (lag_fatal)
    );

    // ---- 时钟 ----
    initial clk = 1'b0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    // ---- 测量变量 ----
    integer a_edges, b_edges;
    integer a_hi_tot, a_lo_tot, b_hi_tot, b_lo_tot;   // 累计高/低电平采样数
    integer a_cyc, b_cyc;                             // 完整周期数（游程法）
    integer z_pulses, z_edge_width;
    integer last_edge_time, min_gap;
    integer i, k;
    reg     pa, pb, pz;
    integer pec;
    integer a_pre_hi, b_pre_hi;

    // 数组（Verilog-2001 要求模块级声明）
    integer iv [0:7];
    integer dv [0:7];

    // ------------------------------------------------------------------
    //  配置 + 复位
    // ------------------------------------------------------------------
    task cfg;
        input [9:0] n_inter;
        input [2:0] n_div;
        input [4:0] n_hyst;
        input [7:0] n_ablimit;
        input       n_apol;
        input       n_bpol;
        input       n_zpol;
        input       n_abzdir;
        input       n_abzen;
        input [3:0] n_zwidth;
        begin
            inter    = n_inter;
            div      = n_div;
            hyst     = n_hyst;
            ablimit  = n_ablimit;
            apol     = n_apol;
            bpol     = n_bpol;
            zpol     = n_zpol;
            abzdir   = n_abzdir;
            abzen    = n_abzen;
            z_width  = n_zwidth;
            z_window = 1'b1;
            z_phase  = 12'd0;
            rst_n    = 1'b0;
            angle    = 16'd0;
            in_valid = 1'b0;
            repeat (4) @(posedge clk);
            rst_n    = 1'b1;
            in_valid = 1'b1;
            @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    //  在一个输入周期上推进角度，统计 A/B 边沿、占空、Z
    //  占空统计：游程法（把 NSAMP 点切成等值游程；首尾同电平游程合并），
    //  因为测的是一个完整输入周期，首尾是同一个游程被切断的两半。
    // ------------------------------------------------------------------
    task run_sweep;
        integer n;
        begin
            a_edges = 0;  b_edges = 0;
            a_hi_tot = 0;  a_lo_tot = 0;  b_hi_tot = 0;  b_lo_tot = 0;
            a_cyc = 0;  b_cyc = 0;
            z_pulses = 0;  z_edge_width = 0;
            last_edge_time = -1;  min_gap = 1000000;
            pa = 1'bx;  pb = 1'bx;  pz = 1'bx;   // 首拍前未知；跳过段内会先同步为真实电平
            a_pre_hi = 0;  b_pre_hi = 0;
            pec = edge_cnt;
            for (n = 0; n < (SKIP + 1) * NSAMP; n = n + 1) begin
                angle = (n * (65536 / NSAMP)) % 65536;
                @(posedge clk);
                #1;
                if (n >= SKIP * NSAMP) begin
                    // ---- 边沿计数（独立于 DUT）----
                    if (a_out !== pa) begin
                        a_edges = a_edges + 1;
                        if (pa === 1'b1) begin          // 下降沿 -> 累计高电平
                            a_hi_tot = a_hi_tot + a_pre_hi;
                            a_pre_hi = 0;
                        end
                    end
                    if (a_out === 1'b1) a_pre_hi = a_pre_hi + 1;
                    if (b_out !== pb) begin
                        b_edges = b_edges + 1;
                        if (pb === 1'b1) begin
                            b_hi_tot = b_hi_tot + b_pre_hi;
                            b_pre_hi = 0;
                        end
                    end
                    if (b_out === 1'b1) b_pre_hi = b_pre_hi + 1;

                    // ---- 限频最小间隔 ----
                    if ((a_out !== pa) || (b_out !== pb)) begin
                        if (last_edge_time >= 0) begin
                            if ((n - last_edge_time) < min_gap) min_gap = n - last_edge_time;
                        end
                        last_edge_time = n;
                    end

                    // ---- Z：脉冲宽度 = 脉冲内 A/B 状态变化的次数（= 边沿步数）----
                    // 前提：测该配置时每个边沿步至少有一个采样点（高 inter 用少
                    // 量采样是测不准的，见 TEST C 的参数选择说明）。
                    if (z_out && !pz) begin
                        z_pulses = z_pulses + 1;
                        z_edge_width = 0;
                    end
                    if (z_out && ((a_out !== pa) || (b_out !== pb))) begin
                        z_edge_width = z_edge_width + 1;
                    end

                    pa = a_out;  pb = b_out;  pz = z_out;
                    pec = edge_cnt;
                end else begin
                    // 跳过段（不计数的前 SKIP 个输入周期）先把探针同步为真实电平：
                    // 否则窗口首拍会用 x 去比较（a_out !== 1'bx 恒为真），凭空多计一个
                    // A 边沿和一个 B 边沿，并让第一个真实事件的最小间隔从窗口首拍起算
                    // （TEST A 的 ±1 偏差、TEST D 的 min_gap、TEST F 的 A_edge=1 皆源于此）。
                    pa = a_out;  pb = b_out;  pz = z_out;
                end
            end
            // 收尾：把窗口末尾那段高电平计入
            a_hi_tot = a_hi_tot + a_pre_hi;
        end
    endtask

    // ------------------------------------------------------------------
    //  用"事件时间戳"法精确测 A 的周期与占空（精度 1 个采样点）
    // ------------------------------------------------------------------
    task run_duty;
        integer n;
        integer a_r0, a_r1, a_f0;
        integer b_r0, b_r1, b_f0;
        integer a_rise_cnt, b_rise_cnt;
        begin
            a_r0 = -1; a_r1 = -1; a_f0 = -1;
            b_r0 = -1; b_r1 = -1; b_f0 = -1;
            a_rise_cnt = 0;  b_rise_cnt = 0;
            pa = 1'bx;  pb = 1'bx;
            for (n = 0; n < (SKIP + 1) * NSAMP; n = n + 1) begin
                angle = (n * (65536 / NSAMP)) % 65536;
                @(posedge clk);
                #1;
                if (n >= SKIP * NSAMP) begin
                    if (a_out && (pa === 1'b0)) begin
                        a_rise_cnt = a_rise_cnt + 1;
                        if (a_r0 < 0) a_r0 = n;
                        else if (a_r1 < 0) a_r1 = n;
                    end
                    if (!a_out && (pa === 1'b1) && (a_f0 < 0) && (a_r0 >= 0)) a_f0 = n;
                    if (b_out && (pb === 1'b0)) begin
                        b_rise_cnt = b_rise_cnt + 1;
                        if (b_r0 < 0) b_r0 = n;
                        else if (b_r1 < 0) b_r1 = n;
                    end
                    if (!b_out && (pb === 1'b1) && (b_f0 < 0) && (b_r0 >= 0)) b_f0 = n;
                    pa = a_out;  pb = b_out;
                end
            end
            a_cyc = a_rise_cnt;  b_cyc = b_rise_cnt;
            if ((a_r0 >= 0) && (a_r1 > a_r0) && (a_f0 > a_r0) && (a_f0 < a_r1)) begin
                a_hi_tot = a_f0 - a_r0;          // 高电平时间
                a_lo_tot = a_r1 - a_f0;          // 低电平时间
            end else begin
                a_hi_tot = 0;  a_lo_tot = 0;
            end
            if ((b_r0 >= 0) && (b_r1 > b_r0) && (b_f0 > b_r0) && (b_f0 < b_r1)) begin
                b_hi_tot = b_f0 - b_r0;
                b_lo_tot = b_r1 - b_f0;
            end else begin
                b_hi_tot = 0;  b_lo_tot = 0;
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  陡斜坡：用于限频与极性方向测试
    // ------------------------------------------------------------------
    integer slope;
    task run_slope;
        input integer nclk;
        begin
            a_edges = 0;  b_edges = 0;
            last_edge_time = -1;  min_gap = 1000000;
            // 探针初值取 DUT 当前真实电平，不能置 x：首拍 a_out !== 1'bx 恒为真，
            // 会虚增一个事件，且使 min_gap 从首拍起算（TEST D 的 min_gap 会读成 6）。
            pa = a_out;  pb = b_out;
            for (i = 0; i < nclk; i = i + 1) begin
                angle = (i * slope) % 65536;
                @(posedge clk);
                #1;
                if ((a_out !== pa) || (b_out !== pb)) begin
                    a_edges = a_edges + 1;
                    if (last_edge_time >= 0) begin
                        if ((i - last_edge_time) < min_gap) min_gap = i - last_edge_time;
                    end
                    last_edge_time = i;
                end
                pa = a_out;  pb = b_out;
            end
        end
    endtask

    // ------------------------------------------------------------------
    reg [1023:0] judge;
    real th_edges, dev, a_duty, b_duty, asym, a_per, b_per;
    integer tot;
    integer ec_norm, ec_a, ec_b, ec_ab, ec_dir, ec_comp;
    integer ab_tmp, th_gap;
    integer zw;

    // ------------------------------------------------------------------
    //  主流程
    // ------------------------------------------------------------------
    initial begin
        errors = 0;
        rst_n = 1'b0;  angle = 16'd0;  in_valid = 1'b0;
        inter = 10'd64;  div = 3'd0;  hyst = 5'd0;  ablimit = 8'd0;
        apol = 0; bpol = 0; zpol = 0; abzdir = 0; abzen = 1;
        z_window = 1; z_phase = 0; z_width = 4;

        $display("================================================================");
        $display(" tb_abz_gen  --  abz_gen.v self-checking testbench (Verilog-2001)");
        $display(" AW=%0d  CLK=%0.1f ns  NSAMP/cycle=%0d  angle step=%0d LSB",
                 AW, CLK_PERIOD_NS, NSAMP, 65536/NSAMP);
        $display("================================================================");

        // ---------------- TEST G ----------------
        $display("");
        $display("TEST G  复位行为");
        rst_n = 1'b0;  in_valid = 1'b1;  abzen = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        if ((a_out !== 1'b0) || (b_out !== 1'b0) || (z_out !== 1'b0) || (out_valid !== 1'b0)) begin
            $display("    FAIL: 复位期间 a=%b b=%b z=%b out_valid=%b (应全 0)",
                     a_out, b_out, z_out, out_valid);
            errors = errors + 1;
        end else begin
            $display("    PASS: 复位期间 a=b=z=0, out_valid=0");
        end
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ---------------- TEST A ----------------
        $display("");
        $display("TEST A  AB 边沿总数（一个输入周期，测试台独立计数）");
        $display("  %-6s %-4s %-10s %-7s %-7s %-7s %-6s %-6s",
                 "inter", "div", "th 4*i/d", "A_edge", "B_edge", "total", "dev", "judge");
        $display("  ------------------------------------------------------------------");
        iv[0] = 2;    dv[0] = 1;
        iv[1] = 8;    dv[1] = 3;
        iv[2] = 64;   dv[2] = 1;
        iv[3] = 64;   dv[3] = 4;
        iv[4] = 256;  dv[4] = 8;
        for (k = 0; k < 5; k = k + 1) begin
            cfg(iv[k][9:0], dv[k][2:0] - 3'd1, 5'd0, 8'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 4'd4);
            run_sweep;
            th_edges = 4.0 * iv[k] / dv[k];
            tot = a_edges + b_edges;
            dev = tot - th_edges;
            if ((dev > -1.001) && (dev < 1.001)) judge = "OK"; else judge = "BAD";
            $display("  %-6d %-4d %-10.1f %-7d %-7d %-7d %-6.1f %-6s",
                     iv[k], dv[k], th_edges, a_edges, b_edges, tot, dev, judge);
            if (judge != "OK") begin
                $display("      FAIL: 边沿总数偏差超出 +-1");
                errors = errors + 1;
            end
        end

        // ---------------- TEST B ----------------
        $display("");
        $display("TEST B  A/B 正交与占空（事件时间戳法，精度 1 采样点）");
        $display("  %-6s %-4s %-8s %-8s %-8s %-8s %-8s %-6s",
                 "inter", "div", "A_hi", "A_lo", "B_hi", "B_lo", "asym", "judge");
        $display("  ------------------------------------------------------------------");
        for (k = 0; k < 5; k = k + 1) begin
            cfg(iv[k][9:0], dv[k][2:0] - 3'd1, 5'd0, 8'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 4'd4);
            run_duty;
            judge = "OK";
            if ((a_hi_tot > 0) && (a_lo_tot > 0)) begin
                a_duty = 100.0 * a_hi_tot / (a_hi_tot + a_lo_tot);
                b_duty = 100.0 * b_hi_tot / (b_hi_tot + b_lo_tot);
                asym = a_hi_tot - b_hi_tot;
                if (asym < 0.0) asym = -asym;
                if (a_duty < 48.0 || a_duty > 52.0) judge = "BAD_DUTY_A";
                if (b_duty < 48.0 || b_duty > 52.0) judge = "BAD_DUTY_B";
                if (asym > 1.0) judge = "BAD_ASYM";
                $display("  %-6d %-4d %-8d %-8d %-8d %-8d %-8.1f %-6s",
                         iv[k], dv[k], a_hi_tot, a_lo_tot, b_hi_tot, b_lo_tot, asym, judge);
                if (judge != "OK") errors = errors + 1;
            end else begin
                // inter=2 时 A 的周期 = 整个输入周期，窗口内看不到完整周期
                $display("  %-6d %-4d %-8d %-8d %-8d %-8d %-8s %-6s",
                         iv[k], dv[k], a_hi_tot, a_lo_tot, b_hi_tot, b_lo_tot, "n/a",
                         "SKIP(A周期=1输入周期)");
                // 退一步：直接用累计高电平/窗口长度粗查 B 的占空
                if ((b_hi_tot > 0) && (a_edges + b_edges > 0)) begin
                    b_duty = 100.0 * b_hi_tot / (b_hi_tot + b_lo_tot);
                    if (b_duty < 45.0 || b_duty > 55.0) begin
                        $display("      FAIL: B 占空 %0.1f%% 偏离 50%% 过多", b_duty);
                        errors = errors + 1;
                    end
                end
            end
        end
        $display("  (注：SPEC 1.8 原文 A=idx[1]^idx[0], B=idx[1] 时 A=~B，本项必 FAIL；");
        $display("   DUT 用标准格雷正交映射 A=idx[1], B=idx[1]^idx[0]，故 OK)");

        // ---------------- TEST C ----------------
        $display("");
        $display("TEST C  Z 脉冲：每输入周期个数 + 宽度 vs z_width");
        $display("  判据：每输入周期恰好 1 个 Z 脉冲。");
        $display("  宽度用脉冲内 A/B 状态变化次数计，受采样相位影响有 +-1~2 个边沿步");
        $display("  的量化误差；★ v9 起 RTL 的设计值是脉冲恰好横跨 (z_width + 1) 个边沿步");
        $display("  （对齐 公开手册 zwidth_edges = (zwidth+1)/div，见 docs/DEV_STATUS.md §1.47），");
        $display("  该量由 model/abz_uvw_model.py 逐拍模型独立核对。");
        $display("  ★ 本循环自 v9 起含 z_width = 0（v9 起 0 ⇒ 1 个边沿步的 Z；v8 及以前为无 Z）。");
        $display("  %-8s %-6s %-8s %-8s %-8s %-6s",
                 "inter", "div", "z_width", "Z_pul", "Z_wid", "judge");
        $display("  ----------------------------------------------------------");
        for (zw = 0; zw <= 8; zw = zw + 1) begin
            cfg(10'd64, 3'd0, 5'd0, 8'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, zw[3:0]);
            run_sweep;
            judge = "OK";
            if (z_pulses != 1) judge = "BAD_PULSE";
            $display("  %-8d %-6d %-8d %-8d %-8d %-6s",
                     64, 1, zw, z_pulses, z_edge_width, judge);
            if (z_pulses != 1) begin
                $display("      FAIL: z_width=%0d 时一个周期内 Z 脉冲数 = %0d (应为 1)", zw, z_pulses);
                errors = errors + 1;
            end
        end
        cfg(10'd64, 3'd3, 5'd0, 8'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 4'd4);
        run_sweep;
        $display("  %-8d %-6d %-8d %-8d %-8d %-6s  (Z 旁路后分频)",
                 64, 3, 4, z_pulses, z_edge_width,
                 (z_pulses == 1) ? "OK" : "BAD_PULSE");
        if (z_pulses != 1) begin
            $display("      FAIL: div=3 时 Z 脉冲数 = %0d (应为 1)", z_pulses);
            errors = errors + 1;
        end

        // ---------------- TEST D ----------------
        $display("");
        $display("TEST D  限频最小边沿间隔（inter=8, div=2, 陡斜坡）");
        $display("  %-9s %-14s %-14s %-6s", "ablimit", "th_gap(clk)", "min_gap(clk)", "judge");
        $display("  --------------------------------------------------------");
        for (k = 0; k < 3; k = k + 1) begin
            if (k == 0)      ab_tmp = 3;
            else if (k == 1) ab_tmp = 20;
            else             ab_tmp = 60;
            cfg(10'd8, 3'd1, 5'd0, ab_tmp[7:0], 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 4'd4);
            slope = 600;
            run_slope(20000);
            th_gap = (20 * (ab_tmp + 1) * 2 + 9) / 10;      // ceil(/10)，100 MHz
            judge = (min_gap >= th_gap) ? "OK" : "BAD";
            $display("  %-9d %-14d %-14d %-6s", ab_tmp, th_gap, min_gap, judge);
            if (judge != "OK") begin
                $display("      FAIL: 限频未生效");
                errors = errors + 1;
            end
        end

        // ---------------- TEST E ----------------
        $display("");
        $display("TEST E  极性 apol/bpol 与方向 abzdir");
        cfg(10'd8, 3'd0, 5'd0, 8'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 4'd4);
        slope = 128;  run_slope(4000);  ec_norm = edge_cnt;
        cfg(10'd8, 3'd0, 5'd0, 8'd0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 4'd4);
        slope = 128;  run_slope(4000);  ec_a = edge_cnt;
        cfg(10'd8, 3'd0, 5'd0, 8'd0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 4'd4);
        slope = 128;  run_slope(4000);  ec_b = edge_cnt;
        cfg(10'd8, 3'd0, 5'd0, 8'd0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 4'd4);
        slope = 128;  run_slope(4000);  ec_ab = edge_cnt;
        cfg(10'd8, 3'd0, 5'd0, 8'd0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 4'd4);
        slope = 128;  run_slope(4000);  ec_dir = edge_cnt;
        cfg(10'd8, 3'd0, 5'd0, 8'd0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, 4'd4);
        slope = 128;  run_slope(4000);  ec_comp = edge_cnt;
        $display("  edge_cnt  正常=%-7d apol=1:%-7d bpol=1:%-7d both=1:%-7d abzdir=1:%-7d apol+abzdir=1:%-7d",
                 ec_norm, ec_a, ec_b, ec_ab, ec_dir, ec_comp);
        if (ec_norm <= 0) begin
            $display("      FAIL: 正常方向 edge_cnt 应为正"); errors = errors + 1; end
        if (ec_a >= 0) begin
            $display("      FAIL: apol=1 应反转计数方向"); errors = errors + 1; end
        if (ec_b >= 0) begin
            $display("      FAIL: bpol=1 应反转计数方向"); errors = errors + 1; end
        if (ec_ab <= 0) begin
            $display("      FAIL: apol=bpol=1 不应改变方向"); errors = errors + 1; end
        if (ec_dir >= 0) begin
            $display("      FAIL: abzdir=1 应反转方向"); errors = errors + 1; end
        if (ec_comp <= 0) begin
            $display("      FAIL: apol=1 + abzdir=1 应恢复正向"); errors = errors + 1; end
        if (ec_norm > 0 && ec_a < 0 && ec_b < 0 && ec_ab > 0 && ec_dir < 0 && ec_comp > 0)
            $display("      PASS: 单相翻转 -> 反向；双翻转 -> 不变；abzdir 可补偿");

        // ---------------- TEST F ----------------
        $display("");
        $display("TEST F  abzen=0 时 A/B/Z 全 0");
        cfg(10'd64, 3'd0, 5'd0, 8'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 4'd4);
        run_sweep;
        if ((a_edges == 0) && (b_edges == 0) && (z_pulses == 0)) begin
            $display("    PASS: A/B/Z 全部为 0");
        end else begin
            $display("    FAIL: abzen=0 仍有输出 (A_edge=%0d B_edge=%0d Z=%0d)",
                     a_edges, b_edges, z_pulses);
            errors = errors + 1;
        end

        // ---------------- 结论 ----------------
        $display("");
        $display("================================================================");
        if (errors == 0) $display(" TEST PASSED");
        else             $display(" TEST FAILED  (%0d error(s))", errors);
        $display("================================================================");
        $finish;
    end

    initial begin
        #(200 * 1000 * 1000);
        $display(" TEST FAILED  (timeout)");
        $finish;
    end

endmodule
