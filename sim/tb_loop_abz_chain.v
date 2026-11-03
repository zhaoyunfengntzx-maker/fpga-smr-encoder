`timescale 1ns/1ps
//=============================================================================
// sim/tb_loop_abz_chain.v  —— 全链路回放：loop_filter -> abz_gen
//
// 为什么要这个测试台（接 docs/DEV_STATUS.md §1.33 / §1.37 / §1.38）：
//   ILA 实测（stage2，1 kHz/8 Vpp/90°）：
//     · CORDIC 原始角 dbg_angle_raw 在节拍上抖动很小：255 拍里 |d| 平均 ~23 LSB
//       （1 LSB = 0.0055°，即 ~0.13°），而 ABZ 的**索引单位 = 64 LSB**（inter=256）
//       ⇒ 若把原始角直接给 abz_gen，抖动本来落在一个索引单位之内。
//     · 环路滤波后的 dbg_angle（= pos_ext[23:8]，ABZ/UVW 真正用的角）反而在
//       节拍上抖 |d| 平均 ~117 LSB（~0.64°）= **比原始角大 5 倍**，超过索引单位
//       ⇒ abz_gen 的 r_div_idx 被推着正反点火 ⇒ 台上看到的"ABZ 波形乱"。
//   根因嫌疑：rtl/loop_filter.v 的环路状态 pos/integ **每个 clk 都更新**，而
//   in_valid 是 1/4 分频（cordic_valid=12.5 MHz），所以"每样本"增益被放大 4 倍
//   （ki=3 时 I 项每 clk = err/16 ⇒ 每样本 err/4），环路欠阻尼、把噪声放大。
//
// 本测试台把 ILA 抓到的 dbg_angle_raw 序列（真实 CORDIC 输出，含 1 个毛刺拍）
// 按 12.5 MHz 节拍回放，喂两条**同输入**的链：
//     链 A = loop_filter #(.GATE_STATE(0))  现状（每 clk 更新）
//     链 B = loop_filter #(.GATE_STATE(1))  ★ v8 已采用（见 DEV_STATUS §1.43：B 链 + kp=2/ki=3
//            = 跳变数达理想、|d| 最大 11 LSB、0 次方向反转；只开门控仍用 kp4/ki3 会变成
//            "慢而大幅"摆动，|d| 冲到 3331 LSB ≈ 1.8°、72 次反转 ⇒ 必须成套重调）
// 每条链后面接真实 abz_gen（inter=256, div=1）。
// 每相位跑 NPASS 遍（源序列按 NET_PASS 拼接成连续斜坡），只统计最后 MEAS 遍。
//
// 判据（每个相位、每条链）：
//   · AB 跳变次数（抖动群指标；理想 ≈ 窗口内角度行程/64）
//   · edge_cnt 净增量 vs 理想计数（**不能丢计数**）
//   · 窗口内跟踪误差（相对窗口起点）的带符号均值 = 滞后、均值绝对值/最大 = 抖动
//   · 滤波后角度在节拍上的 |d| 均值/最大/方向翻转数（噪声放大倍数）
//
// 运行：tools\run_sim.ps1 -Only tb_loop_abz_chain
// 依赖：_synth_work/abz_angle_raw_stage2.mem、_synth_work/abz_glitch_stage2.mem
//       （由 _synth_work/dump_abz_angle.py 从 ILA CSV 导出）
//=============================================================================
module tb_loop_abz_chain;

    localparam integer CLK_HALF = 10;      // 50 MHz（与板上 clk_i 同）
    localparam integer DSTEP    = 4;       // in_valid 每 4 拍（LOG2DEC=2）
    localparam integer NSAMP    = 1024;    // ILA 窗口长度（50 MHz 逐拍）
    localparam integer NPASS    = 10;      // 每相位回放遍数（前 4 遍预热不计）
    localparam integer MEAS     = 6;       // 只统计最后 MEAS 遍（窗口 = 6×256 节拍）
    localparam integer NET_PASS = 1342;    // 每遍拼接行程：1 kHz × 20.48 us（LSB）
    localparam integer INTER    = 256;
    localparam integer NPH      = 7;

    integer errors = 0;
    integer ticks_win;

    //-------------------------------------------------------------------------
    // 时钟 / 复位
    //-------------------------------------------------------------------------
    reg clk = 1'b0;
    always #CLK_HALF clk = ~clk;
    reg rst_n = 1'b0;

    //-------------------------------------------------------------------------
    // 节拍产生：in_valid 每 DSTEP 拍一次（与 cordic_valid/filt_valid 同）
    //-------------------------------------------------------------------------
    reg [2:0] divc;
    reg       tick, tick_d;
    always @(posedge clk) begin
        if (divc == DSTEP-1) begin divc <= 3'd0;   tick <= 1'b1; end
        else                 begin divc <= divc + 3'd1; tick <= 1'b0; end
        tick_d <= tick;
    end

    //-------------------------------------------------------------------------
    // 源序列（ILA 抓的 dbg_angle_raw）
    //-------------------------------------------------------------------------
    reg [15:0] mem [0:NSAMP-1];
    reg [15:0] gm  [0:NSAMP-1];
    integer    rp;
    reg [31:0] pass_cnt;
    reg [15:0] ang_in, src_lat;
    reg        in_valid;

    wire [15:0] src_now = mem[rp] + (pass_cnt[15:0] * NET_PASS);

    always @(posedge clk) begin
        if (tick) begin
            // 毛刺拍保持（同 rtl/enc_top.v:456 ang_glitch ? ang_prev : angle_raw）
            ang_in  <= (gm[rp] != 16'd0) ? ang_in : src_now;
            src_lat <= src_now;
            if (rp + DSTEP >= NSAMP) begin rp <= 0; pass_cnt <= pass_cnt + 1'b1; end
            else                            rp <= rp + DSTEP;
        end
        in_valid <= tick_d;
    end

    //-------------------------------------------------------------------------
    // 两条链
    //-------------------------------------------------------------------------
    integer kp_a, ki_a, hy_a;      // 链 A（现状）
    integer kp_b, ki_b, hy_b;      // 链 B（v7 候选）

    wire signed [23:0] a_pos, b_pos;
    wire a_laglim, b_laglim, a_fv, b_fv;

    loop_filter #(.AW(16), .FRAC(8), .GATE_STATE(0)) ua (
        .clk(clk), .rst_n(rst_n), .ang_in(ang_in), .in_valid(in_valid),
        .kp(kp_a[3:0]), .ki(ki_a[1:0]), .freeze(1'b0),
        .pos_out(a_pos), .lag_limit(a_laglim), .out_valid(a_fv));

    loop_filter #(.AW(16), .FRAC(8), .GATE_STATE(1)) ub (
        .clk(clk), .rst_n(rst_n), .ang_in(ang_in), .in_valid(in_valid),
        .kp(kp_b[3:0]), .ki(ki_b[1:0]), .freeze(1'b0),
        .pos_out(b_pos), .lag_limit(b_laglim), .out_valid(b_fv));

    wire [15:0] a_ang = a_pos[23:8];
    wire [15:0] b_ang = b_pos[23:8];

    wire        a_a, a_b, a_z, a_lim, a_lw, a_lf;
    wire        b_a, b_b, b_z, b_lim, b_lw, b_lf;
    wire signed [31:0] a_ec, b_ec;

    abz_gen #(.AW(16), .CLK_PERIOD_NS(20.0)) uz_a (
        .clk(clk), .rst_n(rst_n), .angle(a_ang), .in_valid(a_fv),
        .inter(INTER[9:0]), .div(3'd0), .hyst(hy_a[4:0]), .ablimit(8'd0),
        .apol(1'b0), .bpol(1'b0), .zpol(1'b0), .abzdir(1'b0), .abzen(1'b1),
        .z_window(1'b1), .z_phase(12'd0), .z_width(4'd4),
        .a_out(a_a), .b_out(a_b), .z_out(a_z), .edge_cnt(a_ec),
        .limiter_active(a_lim), .out_valid(), .lag_warn(a_lw), .lag_fatal(a_lf));

    abz_gen #(.AW(16), .CLK_PERIOD_NS(20.0)) uz_b (
        .clk(clk), .rst_n(rst_n), .angle(b_ang), .in_valid(b_fv),
        .inter(INTER[9:0]), .div(3'd0), .hyst(hy_b[4:0]), .ablimit(8'd0),
        .apol(1'b0), .bpol(1'b0), .zpol(1'b0), .abzdir(1'b0), .abzen(1'b1),
        .z_window(1'b1), .z_phase(12'd0), .z_width(4'd4),
        .a_out(b_a), .b_out(b_b), .z_out(b_z), .edge_cnt(b_ec),
        .limiter_active(b_lim), .out_valid(), .lag_warn(b_lw), .lag_fatal(b_lf));

    //-------------------------------------------------------------------------
    // 统计量
    //-------------------------------------------------------------------------
    reg        meas_en, ab_have, src_have, ja_have, jb_have, win_started;
    reg        signa_p, signb_p;
    integer    tr_a, tr_b, up_a, dn_a, up_b, dn_b;
    integer    jsum_a, jnum_a, jmax_a, jflip_a;
    integer    jsum_b, jnum_b, jmax_b, jflip_b;
    integer    esum_a, eabs_a, emax_a, enum_a;
    integer    esum_b, eabs_b, emax_b, enum_b;
    integer    q, p;
    reg signed [31:0] in_cum, in0, a_ec0, b_ec0, a_e0, b_e0;
    reg [15:0] src_prev, a_ang_d, b_ang_d;
    reg        a_a_d, a_b_d, b_a_d, b_b_d;
    reg signed [31:0] a_ec_d, b_ec_d;

    wire signed [15:0] d_src = src_lat - src_prev;
    wire signed [15:0] d_aa  = a_ang - a_ang_d;
    wire signed [15:0] d_bb  = b_ang - b_ang_d;
    wire signed [31:0] a_terr = (a_ec * 32'sd64) - in_cum - a_e0;
    wire signed [31:0] b_terr = (b_ec * 32'sd64) - in_cum - b_e0;

    // AB 跳变 / edge_cnt 增减速（窗口内）
    always @(posedge clk) begin
        if (!ab_have) begin
            a_a_d <= a_a; a_b_d <= a_b; b_a_d <= b_a; b_b_d <= b_b;
            a_ec_d <= a_ec; b_ec_d <= b_ec; ab_have <= 1'b1;
        end else begin
            if (meas_en) begin
                if ((a_a !== a_a_d) || (a_b !== a_b_d)) tr_a <= tr_a + 1;
                if ((b_a !== b_a_d) || (b_b !== b_b_d)) tr_b <= tr_b + 1;
                if      (a_ec > a_ec_d) up_a <= up_a + 1;
                else if (a_ec < a_ec_d) dn_a <= dn_a + 1;
                if      (b_ec > b_ec_d) up_b <= up_b + 1;
                else if (b_ec < b_ec_d) dn_b <= dn_b + 1;
            end
            a_a_d <= a_a; a_b_d <= a_b; b_a_d <= b_a; b_b_d <= b_b;
            a_ec_d <= a_ec; b_ec_d <= b_ec;
        end
    end

    // 节拍统计：源行程、滤波后角抖动、跟踪误差
    always @(posedge clk) begin
        if (in_valid) begin
            if (meas_en) ticks_win <= ticks_win + 1;
            // --- 源行程（模 65536 有符号差）---
            if (!src_have) begin src_have <= 1'b1; src_prev <= src_lat; end
            else begin
                in_cum   <= in_cum + {{16{d_src[15]}}, d_src};
                src_prev <= src_lat;
            end
            // --- 链 A 滤波后角度的节拍步进 ---
            if (!ja_have) begin ja_have <= 1'b1; a_ang_d <= a_ang; end
            else begin
                if (d_aa != 16'sd0) begin
                    jsum_a <= jsum_a + ((d_aa[15]) ? (0 - d_aa) : d_aa);
                    jnum_a <= jnum_a + 1;
                    if (((d_aa[15] == 1'b0) && (signa_p == 1'b1)) ||
                        ((d_aa[15] == 1'b1) && (signa_p == 1'b0))) jflip_a <= jflip_a + 1;
                    signa_p <= d_aa[15];
                    if (((d_aa[15]) ? (0 - d_aa) : d_aa) > jmax_a)
                        jmax_a <= (d_aa[15]) ? (0 - d_aa) : d_aa;
                end
                a_ang_d <= a_ang;
            end
            // --- 链 B ---
            if (!jb_have) begin jb_have <= 1'b1; b_ang_d <= b_ang; end
            else begin
                if (d_bb != 16'sd0) begin
                    jsum_b <= jsum_b + ((d_bb[15]) ? (0 - d_bb) : d_bb);
                    jnum_b <= jnum_b + 1;
                    if (((d_bb[15] == 1'b0) && (signb_p == 1'b1)) ||
                        ((d_bb[15] == 1'b1) && (signb_p == 1'b0))) jflip_b <= jflip_b + 1;
                    signb_p <= d_bb[15];
                    if (((d_bb[15]) ? (0 - d_bb) : d_bb) > jmax_b)
                        jmax_b <= (d_bb[15]) ? (0 - d_bb) : d_bb;
                end
                b_ang_d <= b_ang;
            end
            // --- 窗口起点 ---
            if (meas_en && !win_started) begin
                win_started <= 1'b1;
                in0   <= in_cum;
                a_ec0 <= a_ec;    b_ec0 <= b_ec;
                a_e0  <= (a_ec * 32'sd64) - in_cum;
                b_e0  <= (b_ec * 32'sd64) - in_cum;
            end
            // --- 窗口内跟踪误差 ---
            if (meas_en && win_started) begin
                esum_a <= esum_a + a_terr;
                eabs_a <= eabs_a + ((a_terr[31]) ? (0 - a_terr) : a_terr);
                enum_a <= enum_a + 1;
                if (((a_terr[31]) ? (0 - a_terr) : a_terr) > emax_a)
                    emax_a <= (a_terr[31]) ? (0 - a_terr) : a_terr;
                esum_b <= esum_b + b_terr;
                eabs_b <= eabs_b + ((b_terr[31]) ? (0 - b_terr) : b_terr);
                enum_b <= enum_b + 1;
                if (((b_terr[31]) ? (0 - b_terr) : b_terr) > emax_b)
                    emax_b <= (b_terr[31]) ? (0 - b_terr) : b_terr;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 相位结果（汇总表）
    //-------------------------------------------------------------------------
    integer       ckp [0:NPH-1];
    integer       cki [0:NPH-1];
    integer       chy [0:NPH-1];
    integer       bkp [0:NPH-1];
    integer       bki [0:NPH-1];
    integer       bhy [0:NPH-1];
    reg [8*20-1:0] cnm [0:NPH-1];
    integer       r_tr  [0:NPH-1];
    integer       r_net [0:NPH-1];
    integer       r_ideal[0:NPH-1];
    integer       r_up  [0:NPH-1];
    integer       r_dn  [0:NPH-1];
    integer       r_jm  [0:NPH-1];
    integer       r_trb [0:NPH-1];
    integer       r_netb[0:NPH-1];
    integer       r_jmb [0:NPH-1];
    integer       r_jf  [0:NPH-1];
    integer       r_jfb [0:NPH-1];

    //-------------------------------------------------------------------------
    // 单相位：清统计 -> 跑 NPASS 遍 -> 打印
    //-------------------------------------------------------------------------
    integer ideal, neta, netb, jma, jmb, ea_mean, eab_mean, eb_mean, ebb_mean;

    task run_phase(input [8*20-1:0] nm);
        integer qq;
        begin
            tr_a = 0; tr_b = 0; up_a = 0; dn_a = 0; up_b = 0; dn_b = 0;
            jsum_a = 0; jnum_a = 0; jmax_a = 0; jflip_a = 0;
            jsum_b = 0; jnum_b = 0; jmax_b = 0; jflip_b = 0;
            esum_a = 0; eabs_a = 0; emax_a = 0; enum_a = 0;
            esum_b = 0; eabs_b = 0; emax_b = 0; enum_b = 0;
            ticks_win = 0;
            src_have = 0; ja_have = 0; jb_have = 0; win_started = 0;
            signa_p = 0; signb_p = 0;
            for (qq = 0; qq < NPASS; qq = qq + 1) begin
                meas_en = (qq >= (NPASS - MEAS));
                repeat (NSAMP) @(posedge clk);
            end
            meas_en = 0;
            ideal = (in_cum - in0) / 32'sd64;
            neta  = a_ec - a_ec0;
            netb  = b_ec - b_ec0;
            jma   = (jnum_a > 0) ? (jsum_a / jnum_a) : 0;
            jmb   = (jnum_b > 0) ? (jsum_b / jnum_b) : 0;
            ea_mean  = (enum_a > 0) ? (esum_a / enum_a) : 0;
            eab_mean = (enum_a > 0) ? (eabs_a / enum_a) : 0;
            eb_mean  = (enum_b > 0) ? (esum_b / enum_b) : 0;
            ebb_mean = (enum_b > 0) ? (eabs_b / enum_b) : 0;
            $display("");
            $display("  === [%0s] kp=%0d ki=%0d hyst=%0d ===", nm, kp_a, ki_a, hy_a);
            $display("    理想: 窗口内角度行程 %0d LSB, 理想计数 %0d (idx 单位)",
                     (in_cum - in0), ideal);
            $display("    A(现状 GATE_STATE=0): AB 跳变 %0d, edge_cnt 净 %0d (增 %0d/减 %0d), 计数误差 %0d",
                     tr_a, neta, up_a, dn_a, neta - ideal);
            $display("       滤波角节拍步进 |d| 均值 %0d 最大 %0d LSB, 非零步 %0d, 方向反转 %0d (统计 6 遍共 %0d 拍)",
                     jma, jmax_a, jnum_a, jflip_a, ticks_win);
            $display("       跟踪误差(相对窗口起点): 均值 %0d, 均值绝对值 %0d, 最大 %0d LSB",
                     ea_mean, eab_mean, emax_a);
            $display("    B(候选 GATE_STATE=1): AB 跳变 %0d, edge_cnt 净 %0d (增 %0d/减 %0d), 计数误差 %0d",
                     tr_b, netb, up_b, dn_b, netb - ideal);
            $display("       滤波角节拍步进 |d| 均值 %0d 最大 %0d LSB, 非零步 %0d, 方向反转 %0d",
                     jmb, jmax_b, jnum_b, jflip_b);
            $display("       跟踪误差(相对窗口起点): 均值 %0d, 均值绝对值 %0d, 最大 %0d LSB",
                     eb_mean, ebb_mean, emax_b);
            $display("       limiter A=%0d B=%0d, lag_warn A=%0d B=%0d",
                     a_lim, b_lim, a_lw, b_lw);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        // 初始化（xsim 里 integer/reg 默认 x）
        rp = 0; pass_cnt = 0; ang_in = 0; src_lat = 0; in_valid = 0;
        divc = 0; tick = 0; tick_d = 0;
        meas_en = 0; ab_have = 0; win_started = 0; signa_p = 0; signb_p = 0;
        src_have = 0; ja_have = 0; jb_have = 0;
        tr_a = 0; tr_b = 0; up_a = 0; dn_a = 0; up_b = 0; dn_b = 0;
        jsum_a = 0; jnum_a = 0; jmax_a = 0; jflip_a = 0;
        jsum_b = 0; jnum_b = 0; jmax_b = 0; jflip_b = 0;
        esum_a = 0; eabs_a = 0; emax_a = 0; enum_a = 0;
        esum_b = 0; eabs_b = 0; emax_b = 0; enum_b = 0;
        in_cum = 0; in0 = 0; a_ec0 = 0; b_ec0 = 0; a_e0 = 0; b_e0 = 0;
        src_prev = 0; a_ang_d = 0; b_ang_d = 0;
        kp_a = 4; ki_a = 3; hy_a = 0; kp_b = 4; ki_b = 3; hy_b = 0;

        // 相位表
        // A = 现状链（GATE_STATE=0）；B = 门控链（GATE_STATE=1）
        //   P1/P2 的 B 侧用"kp 降 2 档、ki 升 2 档"补偿门控丢掉的 4 倍增益
        //   （kp_shift: 4->6, 2->4；ki_shift: 1->6, 3->4 ⇒ 每样本增益相同）
        ckp[0]=4; cki[0]=3; chy[0]=0; bkp[0]=4; bki[0]=3; bhy[0]=0; cnm[0]="P0-now-4-3";
        ckp[1]=4; cki[1]=1; chy[1]=0; bkp[1]=2; bki[1]=3; bhy[1]=0; cnm[1]="P1-ki1-cmp";
        ckp[2]=4; cki[2]=0; chy[2]=0; bkp[2]=2; bki[2]=0; bhy[2]=0; cnm[2]="P2-ki0-cmp";
        ckp[3]=4; cki[3]=1; chy[3]=2; bkp[3]=4; bki[3]=1; bhy[3]=2; cnm[3]="P3-ki1-h2";
        ckp[4]=4; cki[4]=0; chy[4]=2; bkp[4]=4; bki[4]=0; bhy[4]=2; cnm[4]="P4-ki0-h2";
        ckp[5]=4; cki[5]=0; chy[5]=1; bkp[5]=4; bki[5]=0; bhy[5]=1; cnm[5]="P5-ki0-h1";
        ckp[6]=4; cki[6]=1; chy[6]=1; bkp[6]=4; bki[6]=1; bhy[6]=1; cnm[6]="P6-ki1-h1";

        // 读源序列
        mem[0] = 16'hxxxx;
        $readmemh("abz_angle_raw_stage2.mem", mem);
        if (mem[0] === 16'hxxxx) $readmemh("../../_synth_work/abz_angle_raw_stage2.mem", mem);
        if (mem[0] === 16'hxxxx) $readmemh("../../../_synth_work/abz_angle_raw_stage2.mem", mem);
        gm[0] = 16'hxxxx;
        $readmemh("abz_glitch_stage2.mem", gm);
        if (gm[0] === 16'hxxxx) $readmemh("../../_synth_work/abz_glitch_stage2.mem", gm);
        if (gm[0] === 16'hxxxx) $readmemh("../../../_synth_work/abz_glitch_stage2.mem", gm);
        if ((mem[0] === 16'hxxxx) || (gm[0] === 16'hxxxx)) begin
            $display("!! 找不到 .mem（abz_angle_raw_stage2.mem / abz_glitch_stage2.mem）");
            $display("TEST FAILED (1 errors)");
            $finish;
        end

        $display("=== tb_loop_abz_chain：ILA 实测 dbg_angle_raw 回放（%0d 点 / 节拍 %0d 个）===",
                 NSAMP, NSAMP / DSTEP);
        $display("    源序列首点 %0d 末点 %0d；每遍拼接行程 %0d LSB", mem[0], mem[NSAMP-1], NET_PASS);

        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        for (p = 0; p < NPH; p = p + 1) begin
            kp_a = ckp[p]; ki_a = cki[p]; hy_a = chy[p];
            kp_b = bkp[p]; ki_b = bki[p]; hy_b = bhy[p];
            run_phase(cnm[p]);
            r_tr[p]    = tr_a;
            r_net[p]   = neta;
            r_ideal[p] = ideal;
            r_up[p]    = up_a;
            r_dn[p]    = dn_a;
            r_jm[p]    = jma;
            r_trb[p]   = tr_b;
            r_netb[p]  = netb;
            r_jmb[p]   = jmb;
            r_jf[p]    = jflip_a;
            r_jfb[p]   = jflip_b;
        end

        // 汇总表
        $display("");
        $display("  ---- 汇总（理想计数 ≈ 21/遍 × %0d 遍 = %0d）----", MEAS, r_ideal[0]);
        $display("  相位          A(kp/ki/hyst) B(kp/ki/hyst) | A:跳变 净 增/减 | B:跳变 净 | |d| A/B | 反转 A/B");
        for (p = 0; p < NPH; p = p + 1) begin
            $display("  %-13s %0d/%0d/%0d        %0d/%0d/%0d        | %4d %4d %4d/%4d | %4d %4d | %3d/%3d | %4d/%4d",
                     cnm[p], ckp[p], cki[p], chy[p], bkp[p], bki[p], bhy[p],
                     r_tr[p], r_net[p], r_up[p], r_dn[p],
                     r_trb[p], r_netb[p], r_jm[p], r_jmb[p],
                     r_jf[p], r_jfb[p]);
        end

        // 软判据
        $display("");
        if (r_tr[0] < 100) begin
            $display("!! P0（现状）没有复现出抖动群（跳变 %0d，板上实测 139）", r_tr[0]);
            errors = errors + 1;
        end else begin
            $display("ok : P0 复现抖动群（跳变 %0d，板上 139）", r_tr[0]);
        end
        if ((r_net[0] < (r_ideal[0] - 3)) || (r_net[0] > (r_ideal[0] + 3))) begin
            $display("!! P0 计数误差过大（净 %0d vs 理想 %0d）", r_net[0], r_ideal[0]);
            errors = errors + 1;
        end else begin
            $display("ok : P0 计数不丢（净 %0d vs 理想 %0d）", r_net[0], r_ideal[0]);
        end
        $display("?? P1(ki1 门控补偿) A/B: 跳变 %0d/%0d, 净 %0d/%0d, |d| %0d/%0d",
                 r_tr[1], r_trb[1], r_net[1], r_netb[1], r_jm[1], r_jmb[1]);
        $display("?? P2(ki0 门控补偿) A/B: 跳变 %0d/%0d, 净 %0d/%0d, |d| %0d/%0d",
                 r_tr[2], r_trb[2], r_net[2], r_netb[2], r_jm[2], r_jmb[2]);
        if (r_tr[2] <= (r_ideal[2] + 2)) begin
            $display("ok : P2(ki=0 纯 P) 达到理想边沿数（%0d vs 理想 %0d）", r_tr[2], r_ideal[2]);
        end else begin
            $display("?? P2(ki=0 纯 P) 边沿数 %0d vs 理想 %0d", r_tr[2], r_ideal[2]);
        end

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
