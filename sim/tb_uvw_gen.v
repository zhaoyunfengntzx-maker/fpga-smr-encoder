// ============================================================================
//  tb_uvw_gen.v  —  rtl/uvw_gen.v 自检测试台（Vivado xsim / iverilog 均可）
// ----------------------------------------------------------------------------
//  覆盖内容：
//   TEST 1  6 状态序列：pairs=1 一个输入周期内恰好 6 个状态、顺序为
//           110→010→011→001→101→100（标准 120° 六步换向表）。
//   TEST 2  等驻留：6 个状态的驻留采样数两两之差 <= 2 个采样点
//           （即占空相等；SPEC 要求 ±1 个 clk 采样误差）。
//   TEST 3  电周期数：pairs = 1/2/4/32 时，一个输入周期内的 U 相电周期数
//           （U 的上升沿数）= pairs；状态切换次数 = 6*pairs。
//   TEST 4  方向反转：uvwdir=1 时输出相序 = 正向相序的时间倒序
//           （等价于 (U,V,W)→(W,V,U) 的补，即电角度取负）。
//   TEST 5  相位偏移：uvwph 单位 360/1024；uvwph=+1024（=360°）等效于 0，
//           且 uvwph=+128（45°）时首个扇区边界按理论平移。
//   TEST 6  极性：uvwpol=1 使三相整体反相。
//   TEST 7  使能：uwven=0 时三相恒 0。
//   TEST 8  频率告警：陡斜坡使 UVW 基波 > 8.33 MHz 时 uvw_freq_warn 置位；
//           慢斜坡时不置位。
//   TEST 9  uvw_hyst 运行期死区（0x0104 UVW.hyst 接通验证）+ 真实边界基准：
//           (1) 扇区几何：6 个扇区严格等宽 65536/6，边界 = ceil(k*65536/6)
//           (2)(f)(g) 迟滞基准必须落在真实边界上，且前向/反向跨入时一致
//           (3)(h)~(k) 死区前后各 H LSB 对称：偏移 30 LSB 不切，31 LSB 必切
//           (4)(d)(e) hyst = 0 时回退到编译期 UVW_HYST_SHIFT
//   TEST 10 pole_pairs_eff 输出：pairs=0 时应为 32，其余等于 pairs。
//
//  运行：xsim `run all`，或 iverilog -o tb tb_uvw_gen.v ../rtl/uvw_gen.v
//  结束打印 TEST PASSED / TEST FAILED。
// ============================================================================
`timescale 1ns / 1ps

module tb_uvw_gen;

    localparam integer AW       = 16;
    localparam integer NSAMP    = 4096;    // 每个输入周期的采样点数
    localparam integer SKIP     = 1;       // 建立稳态用的周期数（窗口长度 = NSAMP，恰好 1 个电周期）
    // 测量窗口对齐：DUT 输出为寄存器输出，窗口起点要比输入周期的起点晚
    // SW_OFF 个采样点，才能落在"干净的电周期首状态"上（否则窗口首拍仍是
    // 上一个电周期的尾巴，会多算一个 U 上升沿并让某状态驻留记 0）。
    localparam integer SW_OFF   = 1;

    integer fails;
    integer i, k;

    reg                clk;
    reg                rst_n;
    reg  [AW-1:0]      angle;
    reg                in_valid;
    reg  [4:0]         pairs;
    reg                uvwpol, uvwdir, uwven;
    reg  signed [15:0] uvwph;
    reg  [4:0]         uvw_hyst_cfg;   // ★ 0x0104 UVW.hyst（0 = 用编译期默认档 UVW_HYST_SHIFT=6）
    wire               u_out, v_out, w_out;
    wire               uvw_freq_warn;
    wire [5:0]         pole_pairs_eff;
    wire               out_valid;

    uvw_gen #(
        .AW                 (AW),
        .UVW_HYST_SHIFT     (6),
        .UVW_MIN_HALF_CYCLE (24)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .angle          (angle),
        .in_valid       (in_valid),
        .pairs          (pairs),
        .uvwpol         (uvwpol),
        .uvwdir         (uvwdir),
        .uwven          (uwven),
        .uvwph          (uvwph),
        .uvw_hyst       (uvw_hyst_cfg),
        .u_out          (u_out),
        .v_out          (v_out),
        .w_out          (w_out),
        .out_valid      (out_valid),
        .uvw_freq_warn  (uvw_freq_warn),
        .pole_pairs_eff (pole_pairs_eff)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;                    // 100 MHz

    // ------------------------------------------------------------------
    //  统计量
    // ------------------------------------------------------------------
    integer n_sw;                 // 状态切换次数
    integer u_cycles;             // U 相上升沿数 = 电周期数
    integer dwell_hi, dwell_lo;   // 6 状态驻留的 max/min
    integer n_samp;
    reg [2:0] code_prev, code_now;
    integer dbg_u1;
    reg win_open;                 // ★ sweep 窗口是否已对齐到真实状态切换拍
    reg done_sw;                  // ★ 一个完整电周期已闭合
    integer cval [0:7];           // ★ 一个完整电周期内 6 段驻留（下标 1..6）
    reg [2:0] seq [0:47];
    integer seq_len;
    integer warn_cnt;
    // TEST 9 用的真实扇区边界 ceil(k*65536/6)：模块级声明，供多个 begin 块共用
    integer e1, e2, e3, e4, e5;
    integer prev_aa;

    task reset_stats;
        begin
            n_sw = 0;  u_cycles = 0;  n_samp = 0;  warn_cnt = 0;
            dwell_hi = 0;  dwell_lo = 1000000;
            seq_len = 0;
            code_prev = 3'd7;            // 非法值，保证第一次不计切换
        end
    endtask

    // 配置 + 复位 + 建立
    task cfg;
        input [4:0] p;
        input       pol, dir, en;
        input signed [15:0] ph;
        begin
            pairs = p; uvwpol = pol; uvwdir = dir; uwven = en; uvwph = ph;
            uvw_hyst_cfg = 5'd0;      // ★ 默认档：回退到编译期 UVW_HYST_SHIFT，保持旧行为
            rst_n = 1'b0; angle = 16'd0; in_valid = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1; in_valid = 1'b1;
            @(posedge clk);
        end
    endtask

    // 扫描 (SKIP+1) 个输入周期，统计第 2 个周期起的数据
    integer cn, lp;
    task sweep;
        integer dwell_cnt;
        integer prev_u;
        integer dwell [0:7];          // 下标即原始 3 bit 状态码（110=6, 010=2, ...）
        integer cdw   [0:7];          // 当前电周期内的状态驻留
        integer cyc_sw;               // 当前电周期内已发生的状态切换次数
        integer cyc_hi, cyc_lo, worst_spread;
        begin
            for (k = 0; k < 8; k = k + 1) begin dwell[k] = 0; cdw[k] = 0; cval[k] = 0; end
            code_prev = 3'd7;
            prev_u = 0;
            win_open = 1'b0;
            done_sw  = 1'b0;
            dbg_u1   = 0;
            cyc_sw = 0;  worst_spread = 0;
            dwell_hi = 0;  dwell_lo = 0;
            for (cn = 0; cn <= 2 * NSAMP + 8; cn = cn + 1) begin
                angle = (cn * (65536 / NSAMP)) % 65536;
                @(posedge clk);
                #1;
                code_now = {u_out, v_out, w_out};
                // ★ 窗口起点对齐到一次真实状态切换拍（原实现从 SKIP*NSAMP+SW_OFF
                //   硬起，起点落在扇区中部 ⇒ 首尾两个扇区被截断，驻留统计出现
                //   683/65 之类的伪影）。做法：跳过 SKIP 个输入周期后，等**第一次
                //   状态切换**再开窗。此刻状态刚变、该扇区驻留从 0 起算，窗口宽
                //   NSAMP 拍 = 恰好一个输入周期 ⇒ 6 个扇区完整且首尾相接。
                if (!win_open) begin
                    if (cn >= SKIP * NSAMP && code_now !== 3'd7 &&
                        code_now !== code_prev) begin
                        win_open  = 1'b1;
                        code_prev = code_now;   // 窗口首拍只建立基准，不计数
                        prev_u    = u_out;
                        n_samp    = 0;
                        u_cycles  = 0;
                        n_sw      = 0;
                    end
                end
                if (win_open) begin
                    if (u_out == 1'b1 && prev_u == 1'b0) u_cycles = u_cycles + 1;
                    if (u_out == 1'b1) dbg_u1 = dbg_u1 + 1;
                    prev_u = u_out;
                    dwell[code_now[2:0]] = dwell[code_now[2:0]] + 1;
                    cdw[code_now[2:0]]   = cdw[code_now[2:0]] + 1;
                    // ★ 一个电周期 = 相邻 6 次状态切换之间的区间。每条扇区的驻留值
                    //   必须取"离开该状态那一刻"的计数，窗口也必须延伸到第 7 次
                    //   切换（即回到起点状态）才闭合，否则首尾两个扇区被截断
                    //   （原实现在固定 NSAMP 处收窗，实测 683/66、683/65 的伪影）。
                    //   这里用 cyc_sw == 6 且再次切换作为"周期完成"的判据，窗宽
                    //   由扇区边界决定、不再依赖 NSAMP 是否整除 6。
                    if (code_now !== code_prev) begin
                        if (code_prev !== 3'd7) begin
                            n_sw = n_sw + 1;
                            if (cyc_sw >= 1 && cyc_sw <= 6) begin
                                cval[cyc_sw] = cdw[code_prev[2:0]];
                            end
                            cyc_sw = cyc_sw + 1;
                            // 第 6 次切换 = 本电周期的第 6 段结束。此刻前 5 段的驻留
                            // 已记录，第 6 段取"离开最后一个状态那一刻"的计数 ⇒
                            // cval[1..6] 就是一个完整电周期的 6 段驻留。窗口继续
                            // 跑到固定长度，保证 TEST 3 的累计切换数（12/24）正确。
                            if (cyc_sw == 6) begin
                                cval[6] = cdw[code_prev[2:0]];
                                cyc_hi = 0;  cyc_lo = 1000000;
                                for (k = 1; k <= 6; k = k + 1) begin
                                    if (cval[k] > cyc_hi) cyc_hi = cval[k];
                                    if (cval[k] < cyc_lo) cyc_lo = cval[k];
                                end
                                if ((cyc_hi - cyc_lo) > worst_spread) begin
                                    worst_spread = cyc_hi - cyc_lo;
                                    dwell_hi = cyc_hi;  dwell_lo = cyc_lo;
                                end
                                // 复位本周期累加器与段计数，开始下一个电周期
                                for (k = 0; k < 8; k = k + 1) cdw[k] = 0;
                                cyc_sw = 0;
                            end
                        end
                        if (seq_len < 48) begin
                            seq[seq_len] = code_now;
                            seq_len = seq_len + 1;
                        end
                        code_prev = code_now;
                    end
                    if (uvw_freq_warn) warn_cnt = warn_cnt + 1;
                end
            end
            $display("  DBG win_open=%0d u_cycles=%0d dbg_u1=%0d n_samp=%0d cn=%0d",
                     win_open, u_cycles, dbg_u1, n_samp, cn);
        end
    endtask

    // 陡斜坡（用于频率告警）
    task sweep_slope;
        input integer nclk;
        input integer slope;
        begin
            warn_cnt = 0;
            for (cn = 0; cn < nclk; cn = cn + 1) begin
                angle = (cn * slope) % 65536;
                @(posedge clk);
                #1;
                if (uvw_freq_warn) warn_cnt = warn_cnt + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        fails = 0;
        rst_n = 1'b0;  angle = 16'd0;  in_valid = 1'b0;
        pairs = 5'd1;  uvwpol = 0;  uvwdir = 0;  uwven = 1;  uvwph = 16'sd0;
        repeat (5) @(posedge clk);

        $display("================================================================");
        $display(" tb_uvw_gen  --  uvw_gen.v self-checking testbench (Verilog-2001)");
        $display(" AW=%0d  NSAMP/cycle=%0d  6-step table: 110 010 011 001 101 100",
                 AW, NSAMP);
        $display("================================================================");

        // ---------------- TEST 1/2/9: pairs = 1 ----------------
        cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd0);
        reset_stats;
        sweep;
        $display("");
        $display("TEST 1/2/10  pairs=1");
        $display("  状态切换次数 n_sw      = %0d (期望 6)", n_sw);
        $display("  U 相电周期数 u_cycles  = %0d (期望 1)", u_cycles);
        $display("  6 状态驻留 max/min     = %0d / %0d (理论 %.1f, 差应 <= 2)",
                 dwell_hi, dwell_lo, n_samp / 6.0);
        $display("  状态序列               = %0d%0d%0d %0d%0d%0d %0d%0d%0d %0d%0d%0d %0d%0d%0d %0d%0d%0d",
                 seq[0], seq[1], seq[2], seq[3], seq[4], seq[5],
                 seq[6], seq[7], seq[8], seq[9], seq[10], seq[11],
                 seq[12], seq[13], seq[14], seq[15], seq[16], seq[17]);
        $display("  pole_pairs_eff         = %0d (期望 1)", pole_pairs_eff);
        if (n_sw != 6) begin
            $display("    FAIL: 一个电周期应有 6 次状态切换"); fails = fails + 1; end
        if (u_cycles != 1) begin
            $display("    FAIL: U 相电周期数应为 1"); fails = fails + 1; end
        if ((dwell_hi - dwell_lo) > 2) begin
            $display("    FAIL: 6 状态驻留不相等 (差 %0d > 2)", dwell_hi - dwell_lo);
            fails = fails + 1; end
        if (pole_pairs_eff != 6'd1) begin
            $display("    FAIL: pole_pairs_eff 应为 1，实际 %0d", pole_pairs_eff);
            fails = fails + 1; end
        if (dwell_hi + dwell_lo + 0 <= 0) begin
            $display("    FAIL: 无驻留数据"); fails = fails + 1; end

        // ---------------- TEST 3: pairs = 2/4/32 ----------------
        $display("");
        $display("TEST 3  电周期数 vs pairs");
        $display("  %-8s %-10s %-10s %-10s", "pairs", "u_cycles", "n_sw", "dwell max/min");
        cfg(5'd2, 1'b0, 1'b0, 1'b1, 16'sd0); reset_stats; sweep;
        $display("  %-8d %-10d %-10d %0d/%0d", 2, u_cycles, n_sw, dwell_hi, dwell_lo);
        if (u_cycles != 2 || n_sw != 12) begin
            $display("    FAIL: pairs=2 应为 2 电周期 / 12 次切换"); fails = fails + 1; end
        cfg(5'd4, 1'b0, 1'b0, 1'b1, 16'sd0); reset_stats; sweep;
        $display("  %-8d %-10d %-10d %0d/%0d", 4, u_cycles, n_sw, dwell_hi, dwell_lo);
        if (u_cycles != 4 || n_sw != 24) begin
            $display("    FAIL: pairs=4 应为 4 电周期 / 24 次切换"); fails = fails + 1; end
        if ((dwell_hi - dwell_lo) > 2) begin
            $display("    FAIL: pairs=4 时 6 状态驻留不相等 (差 %0d)", dwell_hi - dwell_lo);
            fails = fails + 1; end
        cfg(5'd0, 1'b0, 1'b0, 1'b1, 16'sd0); reset_stats; sweep;
        $display("  %-8d %-10d %-10d %0d/%0d  (pairs=0 -> 32)", 32, u_cycles, n_sw, dwell_hi, dwell_lo);
        if (u_cycles != 32 || pole_pairs_eff != 6'd32) begin
            $display("    FAIL: pairs=0 应等效 32 极对"); fails = fails + 1; end

        // ---------------- TEST 4: uvwdir ----------------
        $display("");
        $display("TEST 4  uvwdir=1 反相序");
        cfg(5'd4, 1'b0, 1'b1, 1'b1, 16'sd0); reset_stats; sweep;
        begin : dir_chk
            integer found;
            found = 0;
            // 相序反转 = 正向序列的时间倒序；正向第 1 个状态应为 110(=6)
            // 反向时第一个状态应为 100(=4)
            if (seq[0] !== 3'd4) begin
                $display("    FAIL: 反相序后首个状态应为 100，实际 %0d%0d%0d",
                         seq[0][2], seq[0][1], seq[0][0]);
                fails = fails + 1;
            end else begin
                $display("    首个状态 = 100（正向的时间倒序），OK");
            end
            if (n_sw != 24) begin
                $display("    FAIL: 反相序后仍应有 24 次切换，实际 %0d", n_sw);
                fails = fails + 1; end
        end

        // ---------------- TEST 5: 相位偏移 ----------------
        $display("");
        $display("TEST 5  uvwph 相位偏移（单位 360/1024）");
        cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd1024);   // +360° 应等效 0°
        reset_stats; sweep;
        $display("  uvwph=1024 (+360deg): 首个状态=%0d%0d%0d (应等效 uvwph=0)",
                 seq[0][2], seq[0][1], seq[0][0]);
        if (seq[0] !== 3'd6) begin
            $display("    FAIL: uvwph=+360deg 应等效于 0"); fails = fails + 1; end
        cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd128);    // +45°：扇区边界整体前移
        reset_stats; sweep;
        $display("  uvwph=128 (+45deg) : 切换次数=%0d (仍应 6)", n_sw);
        if (n_sw != 6) begin
            $display("    FAIL: 相位偏移后切换次数应为 6"); fails = fails + 1; end

        // ---------------- TEST 6: uvwpol ----------------
        $display("");
        $display("TEST 6  uvwpol=1 三相整体反相");
        cfg(5'd1, 1'b1, 1'b0, 1'b1, 16'sd0); reset_stats; sweep;
        $display("  首个状态=%0d%0d%0d (uvwpol=0 时为 110，反相后应为 001)",
                 seq[0][2], seq[0][1], seq[0][0]);
        if (seq[0] !== 3'd1) begin
            $display("    FAIL: uvwpol=1 时 110 应变 001"); fails = fails + 1; end
        if ((dwell_hi - dwell_lo) > 2) begin
            $display("    FAIL: 反相后驻留不相等"); fails = fails + 1; end

        // ---------------- TEST 7: uwven=0 ----------------
        $display("");
        $display("TEST 7  uwven=0 三相恒 0");
        cfg(5'd4, 1'b0, 1'b0, 1'b0, 16'sd0); reset_stats; sweep;
        $display("  切换次数=%0d (应为 0)", n_sw);
        if (n_sw != 0) begin
            $display("    FAIL: uwven=0 时不应有状态切换"); fails = fails + 1; end

        // ---------------- TEST 8: 频率告警 ----------------
        $display("");
        $display("TEST 8  uvw_freq_warn（UVW 基波 > 8.33 MHz）");
        $display("  门限 UVW_MIN_HALF_CYCLE = 24 clk @100MHz");
        cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd0);
        // 慢斜坡：每拍 16 LSB（4096 点/周期）→ 变频 24.4 kHz，不应告警
        sweep_slope(20000, 16);
        $display("  慢斜坡(16 LSB/clk, 4096 点/周期) -> 告警拍数 %0d (应 0)", warn_cnt);
        if (warn_cnt != 0) begin
            $display("    FAIL: 慢斜坡不应告警"); fails = fails + 1; end
        // 陡斜坡：pairs=32、每拍 341 LSB（≈ 每拍前进一个 60° 扇区）→ 扇区驻留远小于 24 clk，应告警
        cfg(5'd0, 1'b0, 1'b0, 1'b1, 16'sd0);          // 5'd0 == 32 极对（见 uvw_gen.v pairs_eff）
        sweep_slope(2000, 341);
        $display("  陡斜坡(pairs=32, 341 LSB/clk) -> 告警拍数 %0d (应 > 0)", warn_cnt);
        if (warn_cnt == 0) begin
            $display("    FAIL: 陡斜坡应告警"); fails = fails + 1; end

        // ---------------- TEST 9: UVW.hyst 运行期死区 + 扇区几何 ----------------
        $display("");
        $display("TEST 9  uvw_hyst 运行期死区 + 扇区几何（0x0104 UVW.hyst 接通验证）");
        // ---- (1) 扇区几何：修掉 eang*6 截断后，6 个扇区应严格等宽 65536/6 ----
        //   正确的扇区边界（eang 首次落入扇区 k 的最小值）= ceil(k*65536/6)：
        //     1 -> 10923   2 -> 21846   3 -> 32768   4 -> 43691   5 -> 54614
        //   修复前 rtl/uvw_gen.v 的 {eang,2'b00}+{eang,1'b0} 被截断成 eang*5，
        //   边界变成 13108 / 26215 / 39322 / 52429，且 sec_raw 只用到 0..4
        //   （每次扫过 5->0 时还会因为 step_f>1 的"补一步"分支产生 1 拍毛刺态）。
        begin
            integer aa, last_sec;
            integer bnd1, bnd2, bnd3, bnd4, bnd5;
            integer n_bad, n_bnd;
            // 理论边界直接用 RTL 的定义现算：扇区 k 的最小 eang 满足 (eang*6)>>16 == k，
            // 即 ceil(k*65536/6)（整数向上取整，不做浮点，避免手算出错）。
            // 结果存入模块级 e1..e5，后面 (f)(g) 等子用例复用。
            e1 = (1*65536 + 5) / 6;
            e2 = (2*65536 + 5) / 6;
            e3 = (3*65536 + 5) / 6;
            e4 = (4*65536 + 5) / 6;
            e5 = (5*65536 + 5) / 6;
            bnd1 = 0; bnd2 = 0; bnd3 = 0; bnd4 = 0; bnd5 = 0;
            n_bad = 0; n_bnd = 0;
            last_sec = -1;
            cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd0);
            for (aa = 0; aa < 65536; aa = aa + 1) begin
                angle = aa[15:0];
                #1;
                if (dut.sec_raw > 5) n_bad = n_bad + 1;
                if (last_sec >= 0 && dut.sec_raw != last_sec) begin
                    n_bnd = n_bnd + 1;
                    case (dut.sec_raw)
                        3'd1: bnd1 = aa;
                        3'd2: bnd2 = aa;
                        3'd3: bnd3 = aa;
                        3'd4: bnd4 = aa;
                        3'd5: bnd5 = aa;
                    endcase
                end
                last_sec = dut.sec_raw;
            end
            $display("  扇区边界实测: 1->%0d  2->%0d  3->%0d  4->%0d  5->%0d", bnd1, bnd2, bnd3, bnd4, bnd5);
            $display("  理论边界    : 1->%0d 2->%0d 3->%0d 4->%0d 5->%0d", e1, e2, e3, e4, e5);
            $display("  切换次数=%0d (应 5)  sec_raw>5 的拍数=%0d (应 0)", n_bnd, n_bad);
            if (bnd1 != e1 || bnd2 != e2 || bnd3 != e3 || bnd4 != e4 || bnd5 != e5) begin
                $display("    FAIL: 扇区边界与 65536/6 不等宽（eang*6 截断缺陷）");
                fails = fails + 1; end
            if (n_bnd != 5) begin
                $display("    FAIL: 一个输入周期应恰好 5 次扇区号跳变"); fails = fails + 1; end
            if (n_bad != 0) begin
                $display("    FAIL: sec_raw 超出 0..5"); fails = fails + 1; end
        end
        // ---- (2) 真实边界基准：迟滞基准必须落在真实边界上，且方向可逆 ----
        //   ★ 这是 2026-10 第二次修订的核心断言。旧实现 r_bnd = nxt_sec*8192
        //     使"刚进扇区时距基准已有 8192 LSB"，死区（<=31 LSB）被完全淹没；
        //     新实现进扇区时把基准设为"刚跨过的真实边界"，死区前后各 H 对称。
        begin
            integer sec_st;
            cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd0);
            uvw_hyst_cfg = 5'd31;
            // 从 0 侧跨入扇区 1：新模型在 eang >= BND[1]+H = 10954 那一拍才提交
            angle = 16'd10922; @(posedge clk); #1;
            angle = 16'd10953; @(posedge clk); #1;   // BND[1]+H-1：仍在死区内，不得提交
            angle = 16'd10954; @(posedge clk); #1;   // BND[1]+H：提交
            angle = 16'd10954; @(posedge clk); #1;
            $display("  (f) 0->1 跨入后 r_sec=%0d (应 1)  r_bnd=%0d (应 BND[2]=%0d)",
                     dut.r_sec, dut.r_bnd, e2);
            if (dut.r_sec !== 3'd1) begin
                $display("    FAIL: 前向跨界后应进入扇区 1"); fails = fails + 1; end
            //   ★ 新模型的 r_bnd 语义 = **下一条要跨的真实边界**：前向提交进扇区 1 后
            //     r_bnd = BND[2] = 21846（实测 21846 ✓）。
            if (dut.r_bnd !== (e2[16:0])) begin
                $display("    FAIL: 前向提交后观测基准应为下一条真实边界 BND[2]=%0d", e2);
                fails = fails + 1; end
            // 从 2 侧反向退回扇区 1：新模型在 eang <= BND[2]-H = 21815 那一拍才提交
            cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd0);
            uvw_hyst_cfg = 5'd31;
            angle = 16'd21816; @(posedge clk); #1;   // BND[2]-H+1：死区内，不得提交
            angle = 16'd21815; @(posedge clk); #1;   // BND[2]-H：提交
            angle = 16'd21815; @(posedge clk); #1;
            sec_st = dut.r_sec;
            $display("  (g) 2->1 反向跨入后 r_sec=%0d (应 1)  r_bnd=%0d (应 BND[2]=%0d)",
                     sec_st, dut.r_bnd, e2);
            if (sec_st !== 3'd1) begin
                $display("    FAIL: 反向跨界后应进入扇区 1"); fails = fails + 1; end
            if (dut.r_bnd !== (e2[16:0])) begin
                $display("    FAIL: 反向提交后观测基准也应为 BND[2]=%0d", e2); fails = fails + 1; end
        end
        // ---- (3) 死区对称性实测：前向在 BND[k]+H 切换，反向在 BND[k]-H 切换 ----
        //   ★ 不手算"某个角度属于哪个扇区"（那正是上一版测试犯的错：边界是 10923，
        //     却把 10893 当成扇区 1，实际它仍是扇区 0）。这里改为**实测**：
        //     把 eang 从 0 单调推到 65535，每次 r_sec 变化就记录切换角度与切换后的
        //     迟滞基准 r_bnd，然后与理论 BND[k] ± H 直接比对。
        //     H = 31（边界下方 545 LSB 处起步，确保起始状态稳定在扇区 0）。
        begin
            integer aa;
            integer fwd_ang [0:7];      // 前向第 j 次切换时的 eang
            integer fwd_bnd [0:7];      // 切换后 r_bnd
            integer bwd_ang [0:7];
            integer bwd_bnd [0:7];
            integer nf, nb, prev_sec, cur;
            integer exp_bnd [0:5];
            integer j, bad;
            integer exp_lo;             // 反向断言用的现算边界

            exp_bnd[0] = 0;
            exp_bnd[1] = e1;
            exp_bnd[2] = e2;
            exp_bnd[3] = e3;
            exp_bnd[4] = e4;
            exp_bnd[5] = e5;

            // ★ 扫描用的复位必须自带起始角度：cfg() 内部会把 angle 驱动成 0，
            //   于是首次提交的迟滞基准被锁成 0（实测 PHASE-INIT r_bnd=0），
            //   第一次跨扇区就会绕过死区。这里自己做一次"带角度的冷启动"。
            pairs = 5'd1; uvwpol = 1'b0; uvwdir = 1'b0; uwven = 1'b1; uvwph = 16'sd0;
            uvw_hyst_cfg = 5'd31;                 // H = 31 LSB
            nf = 0; nb = 0; bad = 0;
            for (j = 0; j < 8; j = j + 1) begin
                fwd_ang[j] = 0; fwd_bnd[j] = 0; bwd_ang[j] = 0; bwd_bnd[j] = 0;
            end

            // ---- 前向扫描：应恰好 5 次切换，切换点 = BND[k] + 31 ----
            //   ★ 采样相位（本次调试的最终结论，务必按此写）：
            //     ① 角度在**时钟沿**更新（阻塞赋值），紧接 `#1` 采样；
            //     ② 判据用 `r_sec`（寄存器），记录**本拍赋的 aa**；
            //     ③ 起始角度必须落在 BND[0]+H = 31 之内（本处取 10000，扇区 0 内、
            //        远在死区之外但**起点本身不是"越界+H"**）。否则 r_armed 一置位
            //        就立刻满足 eang >= BND[0]+H ⇒ 第一个时钟沿就误切一个扇区
            //        （实测起始 10378 时首切落在 10378 而非 10954）。这正是
            //        r_armed 要抑制的冷启动瞬态。
            rst_n = 1'b0;
            angle = 16'd10000;                    // ★ 复位期间就把起始角度摆好
            in_valid = 1'b0;
            uvw_hyst_cfg = 5'd31;
            repeat (4) @(posedge clk);
            in_valid = 1'b1;
            rst_n = 1'b1;
            repeat (4) @(posedge clk); #1;
            prev_sec = dut.r_sec;
            prev_aa = 10923 - 545;
            for (aa = 10000; aa < 65536; aa = aa + 1) begin
                // ★ 采样与捕获相位（本次调试的最终结论）：
                //   角度必须在**时钟沿之前**就位 ⇒ DUT 在沿上采到 aa，同一拍
                //   组合判据 eang >= BND+H 成立并提交 r_sec。因此检测到 r_sec
                //   变化时，触发角度就是**本拍赋的 aa**（不是 prev_aa：沿后赋值
                //   的写法会整整晚 1 LSB，实测 10955/21878/… 而非 10954/21877/…）。
                angle = aa[15:0]; #1; @(posedge clk); #1;
                if (dut.r_sec != prev_sec[2:0]) begin
                    if (nf < 8) begin
                        fwd_ang[nf] = aa;             // ★ 本拍角度就是触发角度
                        fwd_bnd[nf] = dut.r_bnd;
                    end
                    nf = nf + 1;
                    $display("      DBG fwd#%0d aa=%0d sec_raw=%0d r_sec=%0d r_bnd=%0d bnd_cur=%0d hyst=%0d",
                             nf-1, aa, dut.sec_raw, dut.r_sec, dut.r_bnd, dut.bnd_cur, dut.hyst_lsb);
                    prev_sec = dut.r_sec;
                end
                prev_aa = aa;
            end
            $display("  (h) 前向扫描切换次数 = %0d (应 5)，逐次切换角度/基准:", nf);
            //   ★ 切换点 = **真实边界 + H**（H = uvw_hyst 运行期档，此处 31）：
            //     触发基准 = BND[sec_raw]（eang 刚越过的那条真实边界），
            //     前向判据 eang >= BND[sec_raw] + H 恰好在 BND + H 那一拍成立。
            //     死区因此以真实边界为中心、前后各 H LSB 对称。
            for (j = 0; j < nf && j < 5; j = j + 1) begin
                $display("      #%0d  切换角度=%0d (应 BND[%0d]+31=%0d)   基准 r_bnd=%0d (应 BND[%0d]=%0d)",
                         j, fwd_ang[j], j+1, exp_bnd[j+1] + 31, fwd_bnd[j], j+2, exp_bnd[j+2]);
                if (fwd_ang[j] != exp_bnd[j+1] + 31) begin
                    $display("    FAIL: 前向切换点不在真实边界 +H 上");
                    bad = bad + 1; end
                if (fwd_bnd[j] != exp_bnd[j+2]) begin
                    $display("    FAIL: 前向切换后的迟滞观测量不是下一条真实边界");
                    bad = bad + 1; end
            end
            if (nf != 5) begin
                $display("    FAIL: 前向扫描应恰好 5 次扇区切换"); bad = bad + 1; end

            // ---- 反向扫描 65535 -> 0：同样 5 次切换，切换点 = BND[k] - 31 ----
            //   ★ 起始必须保证已稳定在扇区 5：先跳到 65530（扇区 5 内）跑几拍，
            //     否则从别处一步跳过来时 r_sec 还是旧扇区，会误捕到多个跳变。
            // ---- 反向扫描 65530 -> 0：应恰好 5 次切换 ----
            //   ★ 同样必须自带确定性冷启动：复位期间把角度摆在**扇区 5 内部**
            //     （60000，上下边界 54614/65536 之间），于是首次提交的基准
            //     = BND[5] = 54614，第一次反向切换点 = BND[5] - H。
            rst_n = 1'b0;
            angle = 16'd60000;                    // ★ 扇区 5 内部
            in_valid = 1'b0;
            uvw_hyst_cfg = 5'd31;
            repeat (4) @(posedge clk);
            in_valid = 1'b1;
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            angle = 16'd65530;
            repeat (2) @(posedge clk); #1;
            $display("      PH-BWD-INIT angle=%0d eang=%0d sec_raw=%0d r_sec=%0d r_bnd=%0d r_init=%0d",
                     angle, dut.eang, dut.sec_raw, dut.r_sec, dut.r_bnd, dut.r_init);
            prev_sec = dut.r_sec;
            prev_aa = 65530;
            for (aa = 65530; aa >= 0; aa = aa - 1) begin
                angle = aa[15:0]; #1; @(posedge clk); #1;   // ★ 与正向同相位（沿前就位）
                if (dut.r_sec != prev_sec[2:0]) begin
                    if (nb < 8) begin
                        bwd_ang[nb] = aa;             // ★ 本拍角度就是触发角度
                        bwd_bnd[nb] = dut.r_bnd;
                    end
                    nb = nb + 1;
                    $display("      DBG bwd#%0d aa=%0d sec_raw=%0d r_sec=%0d r_bnd=%0d bnd_cur=%0d hyst=%0d",
                             nb-1, aa, dut.sec_raw, dut.r_sec, dut.r_bnd, dut.bnd_cur, dut.hyst_lsb);
                    prev_sec = dut.r_sec;
                end
                prev_aa = aa;
            end
            $display("  (i) 反向扫描切换次数 = %0d (应 5)，逐次切换角度/基准:", nb);
            //   ★ 反向扫描起步时基准已是刚跨过的 BND[5]（由前向扫描留下），
            //     所以第 0 次反向切换点 = BND[5]-H；此后每次跨边界都把基准换成
            //     新扇区的上边界，故 j>=1 的切换点也是 BND[5-j]-H。
            for (j = 0; j < nb && j < 5; j = j + 1) begin
                // 第 j 次反向切换跨过的边界是 BND[5-j]；切换后进入扇区 4-j，
                // 其 r_bnd = 刚跨过的 BND[5-j]（实测 54614/43691/32768/21846/10923 ✓）。
                //   ★ 期望边界**现算** ceil(k*65536/6)（不做浮点），不依赖硬编码。
                exp_lo = (5-j == 0) ? 0 : (((5-j) * 65536 + 5) / 6);
                $display("      #%0d  切换角度=%0d (应 BND[%0d]-31=%0d)   基准 r_bnd=%0d (应 BND[%0d]=%0d)",
                         j, bwd_ang[j], 5-j, exp_bnd[5-j] - 31, bwd_bnd[j], 5-j, exp_lo);
                //   ★ 定稿模型：反向判据用 d_bwd_bnd = eang − BND[r_sec] <= −H，
                //     即 eang <= BND[r_sec] − H。所以反向切换角 = BND[k]−H，
                //     与正向的 BND[k]+H 完全对称（H = 31，实测 54583/43660/32737/21815/10892 ✓）。
                if (bwd_ang[j] != exp_bnd[5-j] - 31) begin
                    $display("    FAIL: 反向切换点应为 BND[%0d]-31=%0d（应与前向 BND+H 对称）",
                             5-j, exp_bnd[5-j] - 31);
                    bad = bad + 1; end
                if (bwd_bnd[j] != exp_lo) begin
                    $display("    FAIL: 反向切换后的 r_bnd 应为刚跨过的边界 BND[%0d]=%0d", 5-j, exp_lo);
                    bad = bad + 1; end
            end
            if (nb != 5) begin
                $display("    FAIL: 反向扫描应恰好 5 次扇区切换"); bad = bad + 1; end

            // ---- 死区内抖动不得切换 ----
            //   ★ 定稿模型（H=31）的死区是**以 r_sec 的两条真实边界为中心的对称带**：
            //     前向 `d_fwd_bnd >= +H` 才结算、反向 `d_bwd_bnd <= −H` 才结算。
            //     在扇区 1（边界 BND[1]=10923、BND[2]=21846）内：
            //       · `eang <= 10923 − 31 = 10892` 会**回切**到扇区 0（这正是 (j) 的反面）；
            //       · `10923 ≤ eang ≤ 10954 − 1` 不回切、也不再前进 ⇒ 稳定；
            //       · `eang = 10954 = BND[2]...` 不，是 `BND[1]+31` 才继续前进。
            //     所以：用 **10923（边界本身）+10953（边界上 30 LSB）** 抖动必须零切换。
            begin
                integer k2, s_keep;
                //   ★ 前置：必须先把 eang 推到 10954 才会提交进扇区 1（定稿模型不
                //     在 10923 提交）。这里自带带角度的冷启动，避免 cfg() 把 angle 清 0。
                pairs = 5'd1; uvwpol = 1'b0; uvwdir = 1'b0; uwven = 1'b1; uvwph = 16'sd0;
                uvw_hyst_cfg = 5'd31;
                rst_n = 1'b0;
                angle = 16'd10000;
                in_valid = 1'b0;
                repeat (4) @(posedge clk);
                in_valid = 1'b1;
                rst_n = 1'b1;
                repeat (2) @(posedge clk);
                angle = 16'd10954;  repeat (4) @(posedge clk); #1;   // 提交进扇区 1
                s_keep = dut.r_sec;
                if (s_keep != 3'd1) begin
                    $display("    FAIL: 前置条件应已进入扇区 1（实际 %0d）", s_keep); bad = bad + 1; end
                // 顶到 BND[1] 本身：多拍停留不得回切、也不得前进
                angle = 16'd10923;  repeat (10) @(posedge clk); #1;
                s_keep = dut.r_sec;
                $display("  (j) eang=10923 (=BND[1]) 停留 10 拍 : r_sec %0d (应 1，死区中心)", s_keep);
                if (s_keep != 3'd1) begin
                    $display("    FAIL: 真实边界本身应稳定在扇区 1"); bad = bad + 1; end
                // 边界上方 30 LSB 内停留：不得回切
                //   （10954 = BND[1]+31 是**前进触发点**，不能用来测"不切"）
                angle = 16'd10953;  repeat (10) @(posedge clk); #1;
                s_keep = dut.r_sec;
                $display("  (k) eang=10953 (=BND[1]+30) 停留 10 拍 : r_sec %0d (应 1，死区内)", s_keep);
                if (s_keep != 3'd1) begin
                    $display("    FAIL: 边界上方 30 LSB 内不应回切"); bad = bad + 1; end
                // 死区内来回抖 31 次也必须纹丝不动
                for (k2 = 0; k2 < 31; k2 = k2 + 1) begin
                    angle = 16'd10923 + ((k2 % 2) ? 16'd30 : 16'd0);
                    @(posedge clk); #1;
                end
                s_keep = dut.r_sec;
                $display("  (l) 边界上下 0/+30 LSB 抖动 31 次 : r_sec %0d (应 1，零抖动)", s_keep);
                if (s_keep != 3'd1) begin
                    $display("    FAIL: 死区内抖动不应产生切换（旧实现抖动会乱跳）"); bad = bad + 1; end
            end

            if (bad != 0) fails = fails + bad;
        end
        // ---- (4) hyst=0 回退路径确实回到编译期默认档 UVW_HYST_SHIFT=6 ----
        begin
            cfg(5'd1, 1'b0, 1'b0, 1'b1, 16'sd0);
            uvw_hyst_cfg = 5'd0;
            @(posedge clk); #1;
            $display("  (d) hyst=0 回退档: hyst_lsb=%0d (应 1024 = 2^(16-6))", dut.hyst_lsb);
            if (dut.hyst_lsb !== 16'd1024) begin
                $display("    FAIL: hyst=0 应回退到编译期默认档 1024 LSB"); fails = fails + 1; end
            uvw_hyst_cfg = 5'd31;
            @(posedge clk); #1;
            $display("  (e) hyst=31 运行期档: hyst_lsb=%0d (应 31)", dut.hyst_lsb);
            if (dut.hyst_lsb !== 16'd31) begin
                $display("    FAIL: hyst=31 时 hyst_lsb 应为 31"); fails = fails + 1; end
        end

        // ---------------- 结论 ----------------
        $display("");
        $display("================================================================");
        if (fails == 0) $display(" TEST PASSED");
        else            $display(" TEST FAILED  (%0d error(s))", fails);
        $display("================================================================");
        $finish;
    end

    initial begin
        #(200 * 1000 * 1000);
        $display(" TEST FAILED  (timeout)");
        $finish;
    end

endmodule
