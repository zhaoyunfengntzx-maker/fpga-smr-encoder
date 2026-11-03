`timescale 1ns / 1ps
// ============================================================================
//  tb_spi_slave.v —— SPI 从站 + 寄存器组 自检测试台 (模式 0 / CPOL=0 / CPHA=0)
// ----------------------------------------------------------------------------
//  行为级 SPI 主机模型（sck = 10 MHz，周期 100 ns）：
//    · sck 空闲低；SS 拉低后开始；MOSI 在 sck 低电平期间改变；
//    · 从机在 sck 上升沿采样 MOSI；主机在 sck 上升沿后 5 ns 采样 MISO(sso)。
//
//  两套 DUT 并行（各自带一个 reg_file）：
//    A) spi_slave #(USE_PKT_MODE=0)：简单 2 字节模式
//       byte0 = {rw, addr[6:0]}，byte1 = data；byte0 期间返回上一帧读数据，
//       byte1 期间返回本帧地址的数据。
//    B) spi_slave #(USE_PKT_MODE=1)：32 位包
//       命令 bit31 st=1, [30:29]rm, [28:27]wm, [26:24]page, [23:16]addr, [15:0]data
//       写: 低字节写 addr，高字节写 addr+1；读: 响应在下一帧移出，
//       格式 {状态字节(读 {page,0x3A}), addr 回显, reg[addr+1], reg[addr]}
//
//  覆盖要求：写一个值再读回、检查 DEVICE_ID、检查配置位是否落到正确的
//            扁平化输出（cfg_*）。
//  全部通过才打印 TEST PASSED。
// ============================================================================
module tb_spi_slave;

    reg clk, rst_n;
    integer errors;

    // ==================================================================
    // A) 简单字节模式
    // ==================================================================
    reg         sck_a, ssi_a, ssn_a;
    wire        sso_a;
    wire [15:0] addr_a;
    wire [7:0]  wdata_a;
    wire        we_a;
    wire [7:0]  rdata_a;
    wire [9:0]  cfg_inter_a;
    wire [4:0]  cfg_pairs_a;

    wire calib_start_a;

    spi_slave #(.AW(16), .DW(8), .USE_PKT_MODE(0)) spi_a (
        .clk(clk), .rst_n(rst_n),
        .sck(sck_a), .ssi(ssi_a), .ss_n(ssn_a), .sso(sso_a),
        .addr(addr_a), .wdata(wdata_a), .we(we_a), .rdata(rdata_a)
    );

    reg_file #(.AW(16), .DW(8)) rf_a (
        .clk(clk), .rst_n(rst_n),
        .addr(addr_a), .wdata(wdata_a), .we(we_a), .rdata(rdata_a),
        .calib_we(1'b0), .calib_addr(16'h0000), .calib_wdata(8'h00),
        .calib_busy(1'b0), .calib_done(1'b0), .calib_trunc(1'b0),
        .calib_retry(3'd0), .calib_bad(1'b0),
        .cfg_inter(cfg_inter_a), .cfg_div(), .cfg_ablimit(),
        .cfg_hyst_ab(), .cfg_hyst_uvw(), .cfg_pairs(cfg_pairs_a),
        .cfg_zphase(), .cfg_zwidth(), .cfg_uvwph(), .cfg_kp(), .cfg_ki(),
        .cfg_apol(), .cfg_bpol(), .cfg_zpol(), .cfg_abzdir(), .cfg_uvwpol(),
        .cfg_uvwdir(), .cfg_abzen(), .cfg_uwven(),
        .cfg_ofs_s(), .cfg_ofs_c(), .cfg_gain_s(), .cfg_gain_c(),
        .cfg_phase_k(), .cfg_shift_s(), .cfg_shift_c(),
        .cfg_amp_low_sq(), .cfg_amp_high_sq(),
        .cfg_h2_k(), .calib_start(calib_start_a),
        .stat_amp_sq(32'h0000_0000), .stat_lag_limit(1'b0),
        .stat_amp_low(1'b0), .stat_amp_high(1'b0), .stat_otr(1'b0),
        .stat_cycle_cnt(16'h0000), .stat_pos_full(32'h0000_0000),
        .stat_inclim(1'b0)
    );

    // ==================================================================
    // B) 32 位包模式
    // ==================================================================
    reg         sck_b, ssi_b, ssn_b;
    wire        sso_b;
    wire [15:0] addr_b;
    wire [7:0]  wdata_b;
    wire        we_b;
    wire [7:0]  rdata_b;
    wire [15:0] cfg_gain_s_b, cfg_gain_c_b;
    wire [9:0]  cfg_inter_b;
    wire [4:0]  cfg_pairs_b, cfg_hyst_ab_b;
    wire [7:0]  cfg_ablimit_b;
    wire [3:0]  cfg_kp_b;
    wire [1:0]  cfg_ki_b;
    wire        cfg_apol_b, cfg_bpol_b, cfg_zpol_b, cfg_abzdir_b;
    wire        cfg_uvwpol_b, cfg_uvwdir_b, cfg_abzen_b, cfg_uwven_b;
    wire [11:0] cfg_zphase_b;
    wire [15:0] cfg_uvwph_b;
    wire [31:0] cfg_amp_low_sq_b;

    reg  [31:0] b_stat_amp_sq;
    reg  [15:0] b_stat_cycle_cnt;
    reg  [31:0] b_stat_pos_full;
    reg         b_laglim, b_amplo, b_amphi, b_otr;

    spi_slave #(.AW(16), .DW(8), .USE_PKT_MODE(1)) spi_b (
        .clk(clk), .rst_n(rst_n),
        .sck(sck_b), .ssi(ssi_b), .ss_n(ssn_b), .sso(sso_b),
        .addr(addr_b), .wdata(wdata_b), .we(we_b), .rdata(rdata_b)
    );

    reg_file #(.AW(16), .DW(8)) rf_b (
        .clk(clk), .rst_n(rst_n),
        .addr(addr_b), .wdata(wdata_b), .we(we_b), .rdata(rdata_b),
        .calib_we(1'b0), .calib_addr(16'h0000), .calib_wdata(8'h00),
        .calib_busy(1'b0), .calib_done(1'b0), .calib_trunc(1'b0),
        .calib_retry(3'd0), .calib_bad(1'b0),
        .cfg_inter(cfg_inter_b), .cfg_div(), .cfg_ablimit(cfg_ablimit_b),
        .cfg_hyst_ab(cfg_hyst_ab_b), .cfg_hyst_uvw(), .cfg_pairs(cfg_pairs_b),
        .cfg_zphase(cfg_zphase_b), .cfg_zwidth(), .cfg_uvwph(cfg_uvwph_b),
        .cfg_kp(cfg_kp_b), .cfg_ki(cfg_ki_b),
        .cfg_apol(cfg_apol_b), .cfg_bpol(cfg_bpol_b), .cfg_zpol(cfg_zpol_b),
        .cfg_abzdir(cfg_abzdir_b), .cfg_uvwpol(cfg_uvwpol_b),
        .cfg_uvwdir(cfg_uvwdir_b), .cfg_abzen(cfg_abzen_b), .cfg_uwven(cfg_uwven_b),
        .cfg_ofs_s(), .cfg_ofs_c(),
        .cfg_gain_s(cfg_gain_s_b), .cfg_gain_c(cfg_gain_c_b),
        .cfg_phase_k(), .cfg_shift_s(), .cfg_shift_c(),
        .cfg_amp_low_sq(cfg_amp_low_sq_b), .cfg_amp_high_sq(),
        .stat_amp_sq(b_stat_amp_sq), .stat_lag_limit(b_laglim),
        .stat_amp_low(b_amplo), .stat_amp_high(b_amphi), .stat_otr(b_otr),
        .stat_cycle_cnt(b_stat_cycle_cnt), .stat_pos_full(b_stat_pos_full),
        .stat_inclim(1'b0)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ==================================================================
    // SPI 主机模型
    // ==================================================================
    integer k;

    task spi_bit_a;
        input        txb;
        output reg   rxb;
        begin
            ssi_a = txb;
            #50;
            sck_a = 1'b1;  #5;
            rxb   = sso_a;
            #45;
            sck_a = 1'b0;  #50;
        end
    endtask

    task spi_byte_a;
        input [7:0]  tx;
        output reg [7:0] rx;
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) spi_bit_a(tx[b], rx[b]);
        end
    endtask

    // 一次 2 字节传输（简单模式）
    task xfer_a;
        input [7:0]  b0, b1;
        output reg [7:0] r0, r1;
        begin
            ssn_a = 1'b0; #30;
            spi_byte_a(b0, r0);
            spi_byte_a(b1, r1);
            #30; ssn_a = 1'b1; #200;
        end
    endtask

    task spi_bit_b;
        input        txb;
        output reg   rxb;
        begin
            ssi_b = txb;
            #50;
            sck_b = 1'b1;  #5;
            rxb   = sso_b;
            #45;
            sck_b = 1'b0;  #50;
        end
    endtask

    // 一次 32 位包传输
    task pkt_b;
        input [31:0] tx;
        output reg [31:0] rx;
        integer b;
        begin
            ssn_b = 1'b0; #30;
            for (b = 31; b >= 0; b = b - 1) spi_bit_b(tx[b], rx[b]);
            #30; ssn_b = 1'b1; #300;
        end
    endtask

    // 组包：st=1, rm, wm, page, addr8, data16
    function [31:0] mkpkt;
        input [1:0]  rm, wm;
        input [2:0]  page;
        input [7:0]  a8;
        input [15:0] d16;
        begin
            mkpkt = {1'b1, rm, wm, page, a8, d16};
        end
    endfunction

    // 读一个 16 位寄存器对（包模式，重叠响应：需要一次空包把响应移出）
    task pkt_read16;
        input [2:0]  page;
        input [7:0]  a8;
        output reg [31:0] resp;
        reg [31:0] dummy;
        begin
            pkt_b(mkpkt(2'b11, 2'b00, page, a8, 16'h0000), dummy);
            pkt_b(mkpkt(2'b00, 2'b00, page, 8'h00, 16'h0000), resp);
        end
    endtask

    // ==================================================================
    // 检查
    // ==================================================================
    task chk8;
        input [511:0] name;
        input [7:0]   got, exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %s = 0x%02X 期望 0x%02X", name, got, exp);
            end else begin
                $display("[OK]   %s = 0x%02X", name, got);
            end
        end
    endtask

    task chk16;
        input [511:0] name;
        input [15:0]  got, exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %s = 0x%04X 期望 0x%04X", name, got, exp);
            end else begin
                $display("[OK]   %s = 0x%04X", name, got);
            end
        end
    endtask

    task chk1;
        input [511:0] name;
        input         got, exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %s = %b 期望 %b", name, got, exp);
            end else begin
                $display("[OK]   %s = %b", name, got);
            end
        end
    endtask

    reg [7:0]  ra0, ra1;
    reg [7:0]  rb0, rb1;
    reg [31:0] rsp, rsp2;
    reg [31:0] dummy32;

    initial begin
        errors = 0;
        rst_n = 1'b0;

        sck_a = 1'b0; ssi_a = 1'b0; ssn_a = 1'b1;
        sck_b = 1'b0; ssi_b = 1'b0; ssn_b = 1'b1;
        b_stat_amp_sq   = 32'h0000_0000;
        b_stat_cycle_cnt= 16'h0000;
        b_stat_pos_full = 32'h0000_0000;
        b_laglim = 1'b0; b_amplo = 1'b0; b_amphi = 1'b0; b_otr = 1'b0;
        ra0 = 8'h00; ra1 = 8'h00; rb0 = 8'h00; rb1 = 8'h00;
        rsp = 32'h0; rsp2 = 32'h0; dummy32 = 32'h0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ============================================================
        // A) 简单字节模式
        // ============================================================
        $display("---- A) 简单字节模式 (2 字节) ----");
        // 写 MAIN_CFG(0x00) = 0x5A：byte0 的 bit7=0 -> 写
        xfer_a(8'h00, 8'h5A, ra0, ra1);
        // 读回 MAIN_CFG：byte0 = 0x80|0x00 = 0x80 (rw=1)，byte1 返回本帧数据
        xfer_a(8'h80, 8'h00, ra0, ra1);
        chk8("A:MAIN_CFG 读回(byte1)", ra1, 8'h5A);
        // 再读一次，验证 byte0 期间返回"上一拍读数据"
        xfer_a(8'h80, 8'h00, ra0, ra1);
        chk8("A:MAIN_CFG 上一拍数据(byte0)", ra0, 8'h5A);
        // DEVICE_ID 别名 0x7E -> byte0 = 0xFE
        xfer_a(8'hFE, 8'h00, ra0, ra1);
        chk8("A:DEVICE_ID(0x7E)", ra1, 8'h0C);
        // REV 别名 0x7F -> byte0 = 0xFF
        xfer_a(8'hFF, 8'h00, ra0, ra1);
        chk8("A:REV(0x7F)", ra1, 8'h10);
        // 写 LED_START(0x02) 后检查寄存器被真正写入（用 0x02 地址读回）
        xfer_a(8'h02, 8'hA5, ra0, ra1);
        xfer_a(8'h82, 8'h00, ra0, ra1);
        chk8("A:LED_START 读回", ra1, 8'hA5);

        // ============================================================
        // B) 32 位包模式
        // ============================================================
        $display("---- B) 32 位 32 位包包模式 ----");
        // ---- 写一个 16 位寄存器（0x0514 GAIN_S = 0x4000，低字节 0x00 高字节 0x40）
        pkt_b(mkpkt(2'b00, 2'b11, 3'd5, 8'h14, 16'h4000), dummy32);
        chk16("B:cfg_gain_s(写 0x4000)", cfg_gain_s_b, 16'h4000);
        // ---- 读回该 16 位寄存器
        pkt_read16(3'd5, 8'h14, rsp);
        chk8("B:resp[7:0]  (0x0514)", rsp[7:0],  8'h00);
        chk8("B:resp[15:8] (0x0515)", rsp[15:8], 8'h40);
        chk8("B:resp[23:16] addr 回显", rsp[23:16], 8'h14);
        chk8("B:resp[31:24] 状态字节(0x053A)", rsp[31:24], 8'h00);
        // ---- DEVICE_ID (page5, 0xF0) 与 REV (page5, 0xF1)
        pkt_read16(3'd5, 8'hF0, rsp);
        chk8("B:DEVICE_ID(0x5F0)", rsp[7:0],  8'h0C);
        chk8("B:REV(0x5F1)",       rsp[15:8], 8'h10);
        // ---- 配置位落点：INTER
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h01, 16'h0040), dummy32);  // 0x0101=0x40 0x0102=0x00
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h02, 16'h0002), dummy32);  // 0x0102=0x02 0x0103=0x00
        chk16("B:cfg_inter", {6'd0, cfg_inter_b}, 16'h0240);
        // ---- ABLIMIT = 0x37
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h06, 16'h0037), dummy32);
        chk8("B:cfg_ablimit", cfg_ablimit_b, 8'h37);
        // ---- OUTPUT = 0xC3 (apol=1,bpol=1,abzen=1,uwven=1)
        // 注意：abzen 是 OUTPUT 的 bit6（reg_file.v 地址表 0x0109 [6]abzen），
        //       原数据 0x83=1000_0011 的 bit6=0，与本行注释/期望值不符，故改为
        //       0xC3=1100_0011（bit0 apol, bit1 bpol, bit6 abzen, bit7 uwven）。
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h09, 16'h00C3), dummy32);
        chk1("B:cfg_apol",   cfg_apol_b,   1'b1);
        chk1("B:cfg_bpol",   cfg_bpol_b,   1'b1);
        chk1("B:cfg_zpol",   cfg_zpol_b,   1'b0);
        chk1("B:cfg_abzdir", cfg_abzdir_b, 1'b0);
        chk1("B:cfg_abzen",  cfg_abzen_b,  1'b1);
        chk1("B:cfg_uwven",  cfg_uwven_b,  1'b1);
        // ---- FILT_K = kp=5, ki=2 -> 0b0001_0101
        pkt_b(mkpkt(2'b00, 2'b11, 3'd3, 8'h02, 16'h0015), dummy32);
        chk16("B:cfg_kp", {12'd0,cfg_kp_b}, 16'd5);
        chk16("B:cfg_ki", {14'd0,cfg_ki_b}, 16'd2);
        // ---- UVW_CFG pairs = 7
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h00, 16'h0007), dummy32);
        chk16("B:cfg_pairs", {11'd0,cfg_pairs_b}, 16'd7);
        // ---- ZPHASE / PHASE_LSB
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h0A, 16'h00AB), dummy32);  // ZPHASE[9:2]=0xAB
        // UVWPH 是**独立**寄存器 0x010B（reg_file.v 地址表），cfg_uvwph 只由
        // {UVWPH[7:0],PHASE_LSB[3:2],6'b0} 组合而成，原测试台漏写了 0x010B，
        // cfg_uvwph 才恒为 0x0040。每个写包同时写 addr+1（低字节写 addr、
        // 高字节写 addr+1），故本写必须排在 0x010A 包之后（否则被其高字节清零）、
        // 且在 0x010C 包之前。
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h0B, 16'h00AB), dummy32);  // UVWPH[9:2]=0xAB
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h0C, 16'h0005), dummy32);  // z=1 uvw=1
        chk16("B:cfg_zphase", {4'd0,cfg_zphase_b}, 16'h0AB4);
        chk16("B:cfg_uvwph",  cfg_uvwph_b,         16'hAB40);
        // ---- AB hyst = 0x1D
        pkt_b(mkpkt(2'b00, 2'b11, 3'd1, 8'h03, 16'h001D), dummy32);
        chk16("B:cfg_hyst_ab", {11'd0,cfg_hyst_ab_b}, 16'h001D);
        // ---- AMP_LOW_SQ 32 位写（4 字节，用两次 16 位包写）
        pkt_b(mkpkt(2'b00, 2'b11, 3'd5, 8'h20, 16'h2211), dummy32);  // 0x0520=0x11 0x0521=0x22
        pkt_b(mkpkt(2'b00, 2'b11, 3'd5, 8'h22, 16'h4433), dummy32);  // 0x0522=0x33 0x0523=0x44
        chk16("B:cfg_amp_low_sq[15:0]",  cfg_amp_low_sq_b[15:0],  16'h2211);
        chk16("B:cfg_amp_low_sq[31:16]", cfg_amp_low_sq_b[31:16], 16'h4433);
        // ---- 状态读回（上位机绘图用）
        b_stat_amp_sq    = 32'h00AB_CDEF;
        b_stat_cycle_cnt = 16'h1234;
        b_stat_pos_full  = 32'h89AB_CDEF;
        b_laglim = 1'b1; b_amphi = 1'b1; b_otr = 1'b0; b_amplo = 1'b0;
        #50;
        pkt_read16(3'd5, 8'h30, rsp);
        chk8("B:stat_amp_sq[7:0]",  rsp[7:0],  8'hEF);
        chk8("B:stat_amp_sq[15:8]", rsp[15:8], 8'hCD);
        pkt_read16(3'd5, 8'h32, rsp);
        chk8("B:stat_amp_sq[23:16]", rsp[7:0],  8'hAB);
        chk8("B:stat_amp_sq[31:24]", rsp[15:8], 8'h00);
        pkt_read16(3'd5, 8'h34, rsp);
        chk8("B:stat_cycle_cnt[7:0]",  rsp[7:0],  8'h34);
        chk8("B:stat_cycle_cnt[15:8]", rsp[15:8], 8'h12);
        pkt_read16(3'd5, 8'h36, rsp);
        chk8("B:stat_pos_full[7:0]",  rsp[7:0],  8'hEF);
        chk8("B:stat_pos_full[15:8]", rsp[15:8], 8'hCD);
        // STAT_FLAGS: {frame_active=0, crc_err=0, calbusy=0, caldone=0, otr=0, amphi=1, amplo=0, laglim=1}
        pkt_read16(3'd5, 8'h3A, rsp);
        // 注意: {page,0x3A} 读值出现在响应的 bit31:24，而 resp[7:0] 是 0x053A 本身
        chk8("B:STAT_FLAGS(0x053A)", rsp[7:0], 8'b0000_0101);
        chk8("B:响应状态字节=0x053A", rsp[31:24], 8'b0000_0101);
        // ---- st 位为 0 的包应被忽略
        pkt_b({1'b0, 2'b00, 2'b11, 3'd5, 8'h14, 16'hFFFF}, dummy32);
        chk16("B:st=0 包被忽略", cfg_gain_s_b, 16'h4000);

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
        #500_000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
