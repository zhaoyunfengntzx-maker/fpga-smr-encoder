`timescale 1ns / 1ps
// ============================================================================
//  tb_reg_file.v —— 寄存器组自检测试台
// ----------------------------------------------------------------------------
//  覆盖：
//    · 复位默认值（MAIN_CFG / OUTPUT / FILT_K / AMP_LOW_SQ ...）
//    · DEVICE_ID = 0x0C 及其 3 个别名（0x007E / 0x05F0 / 0xE000）、REV
//    · 所有扁平化配置输出（cfg_*）逐位落点是否正确
//    · 16/32 位寄存器的小端字节序
//    · 只读地址写入无效
//    · 状态寄存器读回（stat_amp_sq / stat_cycle_cnt / stat_pos_full / STAT_FLAGS）
//    · STAT_LATCH 的写 1 清除
//    · clr_otr 脉冲（写 0x0405[0] 同时清 ADC sticky OTR；非 bit0 不得触发）
//    · calib_start 脉冲与 calib 写口（模拟 calib_ctrl 写结果）
//  全部通过才打印 TEST PASSED。
// ============================================================================
module tb_reg_file;

    reg         clk, rst_n;
    reg  [15:0] addr;
    reg  [7:0]  wdata;
    reg         we;
    wire [7:0]  rdata;
    reg         calib_we;
    reg  [15:0] calib_addr;
    reg  [7:0]  calib_wdata;

    reg  [31:0] stat_amp_sq;
    reg         stat_lag_limit, stat_amp_low, stat_amp_high, stat_otr;
    reg  [15:0] stat_cycle_cnt;
    reg  [31:0] stat_pos_full;
    reg         stat_inclim, stat_crc_err_seen, stat_frame_active;
    reg  [15:0] stat_frame_cnt;

    wire [9:0]        cfg_inter;
    wire [2:0]        cfg_div;
    wire [7:0]        cfg_ablimit;
    wire [4:0]        cfg_hyst_ab, cfg_hyst_uvw, cfg_pairs;
    wire [11:0]       cfg_zphase;
    wire [3:0]        cfg_zwidth, cfg_kp;
    wire [1:0]        cfg_ki;
    wire [15:0]       cfg_uvwph;
    wire              cfg_apol, cfg_bpol, cfg_zpol, cfg_abzdir;
    wire              cfg_uvwpol, cfg_uvwdir, cfg_abzen, cfg_uwven;
    wire signed [15:0] cfg_ofs_s, cfg_ofs_c, cfg_phase_k;
    wire [15:0]       cfg_gain_s, cfg_gain_c;
    wire [1:0]        cfg_shift_s, cfg_shift_c;
    wire [31:0]       cfg_amp_low_sq, cfg_amp_high_sq;
    wire [7:0]        cfg_st_bits, cfg_mt_bits;
    wire [15:0]       cfg_h2_k;
    wire              calib_start;
    wire              clr_otr;

    integer errors;
    reg [7:0] rd;

    reg_file #(
        .AW(16), .DW(8), .DEVICE_ID(8'h0C), .REV(8'h10)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .we(we), .rdata(rdata),
        .calib_we(calib_we), .calib_addr(calib_addr), .calib_wdata(calib_wdata),
        .calib_busy(1'b0), .calib_done(1'b0), .calib_trunc(1'b0),
        .calib_retry(3'd0), .calib_bad(1'b0),
        .cfg_inter(cfg_inter), .cfg_div(cfg_div), .cfg_ablimit(cfg_ablimit),
        .cfg_hyst_ab(cfg_hyst_ab), .cfg_hyst_uvw(cfg_hyst_uvw),
        .cfg_pairs(cfg_pairs), .cfg_zphase(cfg_zphase), .cfg_zwidth(cfg_zwidth),
        .cfg_uvwph(cfg_uvwph), .cfg_kp(cfg_kp), .cfg_ki(cfg_ki),
        .cfg_apol(cfg_apol), .cfg_bpol(cfg_bpol), .cfg_zpol(cfg_zpol),
        .cfg_abzdir(cfg_abzdir), .cfg_uvwpol(cfg_uvwpol),
        .cfg_uvwdir(cfg_uvwdir), .cfg_abzen(cfg_abzen), .cfg_uwven(cfg_uwven),
        .cfg_ofs_s(cfg_ofs_s), .cfg_ofs_c(cfg_ofs_c),
        .cfg_gain_s(cfg_gain_s), .cfg_gain_c(cfg_gain_c),
        .cfg_phase_k(cfg_phase_k),
        .cfg_shift_s(cfg_shift_s), .cfg_shift_c(cfg_shift_c),
        .cfg_amp_low_sq(cfg_amp_low_sq), .cfg_amp_high_sq(cfg_amp_high_sq),
        .cfg_h2_k(cfg_h2_k), .calib_start(calib_start), .clr_otr(clr_otr),
        .stat_amp_sq(stat_amp_sq), .stat_lag_limit(stat_lag_limit),
        .stat_amp_low(stat_amp_low), .stat_amp_high(stat_amp_high),
        .stat_otr(stat_otr), .stat_cycle_cnt(stat_cycle_cnt),
        .stat_pos_full(stat_pos_full), .stat_inclim(stat_inclim)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // 单字节写 / 读
    task wr;
        input [15:0] a;
        input [7:0]  d;
        begin
            @(negedge clk);
            addr = a; wdata = d; we = 1'b1;
            @(negedge clk);
            we = 1'b0;
            @(negedge clk);
        end
    endtask

    task rd_chk;
        input [15:0] a;
        input [7:0]  exp;
        input [255:0] name;      // 名字仅用于打印(最多 16 字符)
        begin
            addr = a;
            #1;
            rd = rdata;
            if (rd !== exp) begin
                errors = errors + 1;
                $display("[FAIL] 读 0x%04X 得到 0x%02X 期望 0x%02X", a, rd, exp);
            end else begin
                $display("[OK]   读 0x%04X = 0x%02X", a, rd);
            end
        end
    endtask

    task chk16;
        input [255:0] name;
        input [15:0]  got;
        input [15:0]  exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %s = 0x%04X 期望 0x%04X", name, got, exp);
            end else begin
                $display("[OK]   %s = 0x%04X", name, got);
            end
        end
    endtask

    task chk32;
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %s = 0x%08X 期望 0x%08X", name, got, exp);
            end else begin
                $display("[OK]   %s = 0x%08X", name, got);
            end
        end
    endtask

    task chk1;
        input [255:0] name;
        input         got;
        input         exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %s = %b 期望 %b", name, got, exp);
            end else begin
                $display("[OK]   %s = %b", name, got);
            end
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        addr = 16'h0000; wdata = 8'h00; we = 1'b0;
        calib_we = 1'b0; calib_addr = 16'h0000; calib_wdata = 8'h00;
        stat_amp_sq = 32'h0000_0000;
        stat_lag_limit = 0; stat_amp_low = 0; stat_amp_high = 0; stat_otr = 0;
        stat_cycle_cnt = 16'h0000; stat_pos_full = 32'h0000_0000;
        stat_inclim = 0; stat_crc_err_seen = 0; stat_frame_active = 0;
        stat_frame_cnt = 16'h0000;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---------------- 1. 复位默认值 ----------------
        $display("---- 复位默认值 ----");
        chk16("cfg_inter(默认)",   cfg_inter,   10'd32);  // v68 起默认 32          // v63：转台默认 inter=2（4096 线/转）
        chk16("cfg_div(默认)",     {13'd0,cfg_div}, 16'd0);      // cfg_div = INTER1[4:2] 寄存器字段 = 0（实际分频 = 字段+1 = 1，见 abz_gen div 端口）
        chk16("cfg_pairs(默认)",   {11'd0,cfg_pairs}, 16'd4);
        chk16("cfg_kp(默认)",      {12'd0,cfg_kp}, 16'd2);
        chk16("cfg_ki(默认)",      {14'd0,cfg_ki}, 16'd3);      // ★ v8：复位值改为 kp2/ki3
                                                                //   （v7 曾为 kp4/ki0 纯 P；v8 起
                                                                //   enc_top 的 loop_filter 传 GATE_STATE=1
                                                                //   ⇒ 增益恢复每样本语义，可带 I 项，
                                                                //   依据 sim/tb_loop_abz_chain.v 的 B 链回放）
        chk1 ("cfg_abzen(默认)",   cfg_abzen, 1'b1);
        chk1 ("cfg_uwven(默认)",   cfg_uwven, 1'b1);   // ★ 2026-10-28：UVW 改机械角驱动后默认开
        chk16("cfg_gain_s(默认)",  cfg_gain_s, 16'd32768);
        chk16("cfg_gain_c(默认)",  cfg_gain_c, 16'd32768);
        chk32("cfg_amp_low_sq",    cfg_amp_low_sq, 32'h170A3D71);
        chk32("cfg_amp_high_sq",   cfg_amp_high_sq,32'h5C28F5C3);
        // v74：cfg_st_bits / cfg_mt_bits 两项检查随原从站模块删除（端口已去掉）

        // ---------------- 2. 器件识别 ----------------
        $display("---- DEVICE_ID / REV ----");
        rd_chk(16'h007E, 8'h0C, "DEVICE_ID@0x7E");
        rd_chk(16'h007F, 8'h10, "REV@0x7F");
        rd_chk(16'h05F0, 8'h0C, "DEVICE_ID@0x5F0");
        rd_chk(16'h05F1, 8'h10, "REV@0x5F1");
        rd_chk(16'hE000, 8'h0C, "DEVICE_ID@0xE000");
        rd_chk(16'hE002, 8'h10, "REV0@0xE002");
        rd_chk(16'hE003, 8'h00, "REV1@0xE003");

        // ---------------- 3. 扁平化输出落点 ----------------
        $display("---- 配置位落点 ----");
        wr(16'h0101, 8'h40);                     // INTER0 = 0x40
        wr(16'h0102, 8'h02);                     // INTER1 msbs = 2 -> inter=0x240
        chk16("cfg_inter", {6'd0,cfg_inter}, 16'h0240);
        wr(16'h0102, 8'h02 | 8'h0C);             // div = 3 (bits[4:2])
        chk16("cfg_div",   {13'd0,cfg_div}, 16'd3);
        wr(16'h0102, 8'h02);
        wr(16'h0100, 8'h05);                     // pairs = 5
        chk16("cfg_pairs", {11'd0,cfg_pairs}, 16'd5);
        wr(16'h0103, 8'h15);                     // hyst_ab = 0x15
        chk16("cfg_hyst_ab", {11'd0,cfg_hyst_ab}, 16'h0015);
        wr(16'h0104, 8'h1F);                     // hyst_uvw = 0x1F
        chk16("cfg_hyst_uvw", {11'd0,cfg_hyst_uvw}, 16'h001F);
        wr(16'h0106, 8'hA5);                     // ablimit
        chk16("cfg_ablimit", {8'd0,cfg_ablimit}, 16'h00A5);
        wr(16'h010A, 8'hAB);                     // ZPHASE[9:2] = 0xAB
        wr(16'h010B, 8'hAB);                     // UVWPH[9:2] = 0xAB
        wr(16'h010C, 8'h05);                     // z=1, uvw=1
        chk16("cfg_zphase", {4'd0,cfg_zphase}, 16'h0AB4);   // (0xAB*4+1)*4
        chk16("cfg_uvwph",  cfg_uvwph,          16'hAB40);   // (0xAB*4+1)*64
        wr(16'h0108, 8'h0F);                     // zwidth = 15
        chk16("cfg_zwidth", {12'd0,cfg_zwidth}, 16'd15);
        wr(16'h0302, 8'h15);                     // kp = 5 (b2:0), ki = 2 (b4:3)
        chk16("cfg_kp", {12'd0,cfg_kp}, 16'd5);
        chk16("cfg_ki", {14'd0,cfg_ki}, 16'd2);
        wr(16'h0109, 8'hC7);                     // apol,bpol,zpol=1 abzdir=0 uvwpol=0 uvwdir=0 abzen=1 uwven=1
        chk1("cfg_apol",   cfg_apol,   1'b1);
        chk1("cfg_bpol",   cfg_bpol,   1'b1);
        chk1("cfg_zpol",   cfg_zpol,   1'b1);
        chk1("cfg_abzdir", cfg_abzdir, 1'b0);
        chk1("cfg_uvwpol", cfg_uvwpol, 1'b0);
        chk1("cfg_uvwdir", cfg_uvwdir, 1'b0);
        chk1("cfg_abzen",  cfg_abzen,  1'b1);
        chk1("cfg_uwven",  cfg_uwven,  1'b1);
        wr(16'h0109, 8'h38);                     // 只置 uvwpol/uvwdir/abzdir
        chk1("cfg_abzdir2",cfg_abzdir, 1'b1);
        chk1("cfg_uvwpol2",cfg_uvwpol, 1'b1);
        chk1("cfg_uvwdir2",cfg_uvwdir, 1'b1);
        chk1("cfg_apol2",  cfg_apol,   1'b0);

        // ---------------- 4. 16/32 位寄存器与字节序 ----------------
        $display("---- 16/32 位寄存器(小端) ----");
        wr(16'h0514, 8'h34); wr(16'h0515, 8'h12);      // gain_s = 0x1234
        chk16("cfg_gain_s(小端)", cfg_gain_s, 16'h1234);
        wr(16'h0518, 8'hFE); wr(16'h0519, 8'hFF);      // phase_k = 0xFFFE = -2
        chk16("cfg_phase_k(-2)",  cfg_phase_k, 16'hFFFE);
        wr(16'h0511, 8'hFF); wr(16'h0510, 8'h00);      // ofs_s = 0xFF00 = -256
        chk16("cfg_ofs_s(-256)",  cfg_ofs_s, 16'hFF00);
        wr(16'h0520, 8'h11); wr(16'h0521, 8'h22);
        wr(16'h0522, 8'h33); wr(16'h0523, 8'h44);
        chk32("cfg_amp_low_sq", cfg_amp_low_sq, 32'h44332211);
        wr(16'h051A, 8'h07);                            // shift_s=3, shift_c=1
        chk16("cfg_shift_s", {14'd0,cfg_shift_s}, 16'd3);
        chk16("cfg_shift_c", {14'd0,cfg_shift_c}, 16'd1);

        // ---------------- 5. 只读地址写入无效 ----------------
        $display("---- 只读地址写入无效 ----");
        wr(16'h05F0, 8'hAA);
        rd_chk(16'h05F0, 8'h0C, "DEVICE_ID 只读");
        wr(16'h0404, 8'hFF);
        rd_chk(16'h0404, 8'h00, "STAT_VAL 只读");

        // ---------------- 6. 状态读回 ----------------
        $display("---- 状态读回 ----");
        stat_amp_sq   = 32'h1234_5678;
        stat_cycle_cnt= 16'hABCD;
        stat_pos_full = 32'hDEAD_BEEF;
        stat_lag_limit = 1'b1; stat_amp_low = 1'b0; stat_amp_high = 1'b1;
        stat_otr = 1'b1;      stat_inclim = 1'b1;
        stat_crc_err_seen = 1'b1; stat_frame_active = 1'b1;
        stat_frame_cnt = 16'h0047;
        #20;
        rd_chk(16'h0530, 8'h78, "amp_sq[7:0]");
        rd_chk(16'h0531, 8'h56, "amp_sq[15:8]");
        rd_chk(16'h0532, 8'h34, "amp_sq[23:16]");
        rd_chk(16'h0533, 8'h12, "amp_sq[31:24]");
        rd_chk(16'h0534, 8'hCD, "cycle_cnt[7:0]");
        rd_chk(16'h0535, 8'hAB, "cycle_cnt[15:8]");
        rd_chk(16'h0536, 8'hEF, "pos_full[7:0]");
        rd_chk(16'h0539, 8'hDE, "pos_full[31:24]");
        // STAT_FLAGS = {frame_active, crc_err, calbusy, caldone, otr, amphi, amplo, laglim}
        rd_chk(16'h053A, 8'b0000_1101, "STAT_FLAGS");   // v74: bit7/6 保留位恒 0
        rd_chk(16'h053B, 8'h00, "frame_cnt[7:0]");      // v74: 原帧计数已删
        // STAT_VAL = {2'b0, scamp, 1'b0, inclim, laglim, 1'b0, otr}
        rd_chk(16'h0404, 8'b0010_1101, "STAT_VAL");
        // STAT_LATCH 锁存后清 stat 输入，锁存值应保持
        stat_lag_limit = 1'b0; stat_amp_high = 1'b0; stat_otr = 1'b0;
        stat_inclim = 1'b0;
        #20;
        rd_chk(16'h0405, 8'b0010_1101, "STAT_LATCH 锁存");
        wr(16'h0405, 8'b0000_0001);                     // 写 1 清 bit0
        #20;
        rd_chk(16'h0405, 8'b0010_1100, "STAT_LATCH W1C");

        // ---------------- 6b. clr_otr 脉冲（ADC sticky OTR 清位）----------------
        // 写 0x0405 的 bit0（= STAT_LATCH 的 otr 位）时，reg_file 同拍发出 1 拍
        // clr_otr 脉冲给 ad9238_capture 清内部 sticky OTR（rtl/reg_file.v 的
        // 「ADC sticky OTR 清位脉冲」块、rtl/enc_top.v 的 clr_otr_adc 接线）。
        // 脉冲 1 拍宽，必须在 negedge 处检查；非 bit0 的写不得产生脉冲。
        $display("---- OTR 清位脉冲 ----");
        @(negedge clk);
        addr = 16'h0405; wdata = 8'b0000_0001; we = 1'b1;
        @(negedge clk);                                 // 此处 clr_otr 已置 1
        we = 1'b0;
        if (clr_otr !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] clr_otr 未拉高");
        end else begin
            $display("[OK]   clr_otr 脉冲（写 0x0405[0]）");
        end
        @(posedge clk); #1;
        if (clr_otr !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] clr_otr 未自清");
        end else begin
            $display("[OK]   clr_otr 自清");
        end
        @(negedge clk);
        addr = 16'h0405; wdata = 8'b0000_0100; we = 1'b1;  // 只清 laglim，不含 bit0
        @(negedge clk);
        we = 1'b0;
        if (clr_otr !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] clr_otr 被 0x0405 非 bit0 写触发");
        end else begin
            $display("[OK]   clr_otr 不被 0x0405 其它位触发");
        end
        #20;

        // ---------------- 7. calib_start 脉冲 + calib 写口 ----------------
        $display("---- 标定接口 ----");
        // 注意：calib_start 只在 we 有效的那一拍之后为高，必须在 negedge 处检查
        @(negedge clk);
        addr = 16'h0502; wdata = 8'h01; we = 1'b1;
        @(negedge clk);                                 // 此处 calib_start 已置 1
        we = 1'b0;
        if (calib_start !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] calib_start 未拉高");
        end else begin
            $display("[OK]   calib_start 脉冲");
        end
        @(posedge clk); #1;
        if (calib_start !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] calib_start 未自清");
        end else begin
            $display("[OK]   calib_start 自清");
        end
        // 模拟 calib_ctrl 写标定结果
        @(negedge clk);
        calib_we = 1'b1; calib_addr = 16'h0516; calib_wdata = 8'h78;
        @(negedge clk);
        calib_addr = 16'h0517; calib_wdata = 8'h56;
        @(negedge clk);
        calib_addr = 16'h051A; calib_wdata = 8'h06;     // shift_s=2, shift_c=1
        @(negedge clk);
        calib_we = 1'b0;
        @(negedge clk);
        chk16("cfg_gain_c(calib 写口)", cfg_gain_c, 16'h5678);
        chk16("cfg_shift_s(calib)", {14'd0,cfg_shift_s}, 16'd2);
        chk16("cfg_shift_c(calib)", {14'd0,cfg_shift_c}, 16'd1);

        // ---------------- 8. 复位 ----------------
        $display("---- 复位 ----");
        rst_n = 1'b0; #40; rst_n = 1'b1; #20;
        chk16("cfg_gain_c(复位后)", cfg_gain_c, 16'd32768);
        chk16("cfg_inter(复位后)", {6'd0,cfg_inter}, 16'd32);   // v68 起默认 32   // v63：inter 复位值 2

        $display("--------------------------------------------------");
        if (errors == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("错误总数 = %0d", errors);
            $display("TEST FAILED");
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
