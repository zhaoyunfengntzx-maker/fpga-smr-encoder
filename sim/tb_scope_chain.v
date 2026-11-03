//=============================================================================
//  tb_scope_chain.v —— 抓包链路自检测试台（cap_regs + scope_capture + scope_dump）
//-----------------------------------------------------------------------------
//  覆盖对象：
//    DUT1 = cap_regs       （0x0700 段寄存器的字节写/读、脉冲生成）
//    DUT2 = scope_capture  （arm/触发/预触发/抽取/回绕/done）
//    DUT3 = scope_dump     （UART 字节时序、块头、块尾 XOR、点数据还原）
//
//  为什么必须测：
//    这条链路是 B1 的全部交付物——上位机看到的"原始波形"就是这三级串起来
//    的结果。任何一级错位（比如 dump 少发/多发一个点、块头 seq 错、XOR 覆盖
//    范围错）在 PC 端都表现为"波形整体平移"或"偶尔一帧花掉"，极难定位。
//    所以这里在 RTL 层把"写进去的样本"和"从 UART 线上解出来的样本"逐点比对。
//
//  测试分组：
//    [A] cap_regs：默认值 / 16 位字节写 / 读回 / BUILD
//    [B] 立即触发：8 点抓包 → dump → 逐点比对
//    [C] 上升沿触发 + 预触发 2 点：窗口起点/触发下标/数据比对
//    [D] 抽取 2：喂 8 个样本只应存 4 个
//=============================================================================

`timescale 1ns / 1ps

module tb_scope_chain;

    //-------------------------------------------------------------------------
    //  参数
    //-------------------------------------------------------------------------
    localparam integer DEPTH       = 256;      // 小缓冲，便于回绕测试
    localparam integer BAUD_DIV    = 4;        // 每位 4 clk（仿真加速）
    localparam integer START_DELAY = 50;
    localparam integer PTS         = 8;
    localparam integer CLK_PD      = 20;       // 50 MHz
    localparam integer HALF        = CLK_PD / 2;
    localparam integer BIT         = BAUD_DIV * CLK_PD;

    //-------------------------------------------------------------------------
    //  时钟 / 复位 / 计数
    //-------------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    integer cycle = 0;

    always #(HALF) clk = ~clk;
    always @(posedge clk) cycle = cycle + 1;

    //-------------------------------------------------------------------------
    //  统计
    //-------------------------------------------------------------------------
    integer checks = 0;
    integer errors = 0;

    task chk;
        input          cond;
        input [1023:0] name;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s   (t=%0t ns)", name, $time);
            end
        end
    endtask

    task chk16;
        input [1023:0] name;
        input [15:0]   got, exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got 0x%04X , expected 0x%04X   (t=%0t ns)",
                         name, got, exp, $time);
            end
        end
    endtask

    task chk8;
        input [1023:0] name;
        input [7:0]    got, exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got 0x%02X , expected 0x%02X   (t=%0t ns)",
                         name, got, exp, $time);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    //  DUT 互联信号
    //-------------------------------------------------------------------------
    reg         reg_we    = 1'b0;
    reg  [15:0] reg_addr  = 16'h0000;
    reg  [7:0]  reg_wdata = 8'h00;
    wire [7:0]  reg_rdata;

    wire        cap_arm, cap_abort;
    wire [1:0]  cap_dec_log2;
    wire [15:0] cap_len_cfg, cap_pre_cfg, cap_trig_level_cfg;
    wire [1:0]  cap_trig_mode;
    wire        cap_src_sel;
    wire        dump_start_cfg, dump_abort;

    reg  signed [15:0] s_in = 16'sd0;
    reg  signed [15:0] c_in = 16'sd0;
    reg                in_valid = 1'b0;

    wire [15:0] cap_rd_addr;
    wire        cap_rd_en;
    wire [31:0] cap_rd_data;

    wire [15:0] cap_start_w, cap_len_eff_w, cap_trig_idx_w;
    wire [31:0] cap_sample_cnt;
    wire        st_armed, st_done, st_trig, st_busy, st_ovf;

    wire        dump_tx, dump_busy, dump_done;
    wire [15:0] blocks_done;

    //-------------------------------------------------------------------------
    //  DUT1 : cap_regs
    //-------------------------------------------------------------------------
    wire [4:0] idly_val;
    wire       idly_ld;

    cap_regs u_capregs (
        .clk         (clk),
        .rst_n       (rst_n),
        .addr        (reg_addr),
        .we          (reg_we),
        .wdata       (reg_wdata),
        .rdata       (reg_rdata),
        .arm         (cap_arm),
        .abort       (cap_abort),
        .dec_log2    (cap_dec_log2),
        .cap_len     (cap_len_cfg),
        .trig_mode   (cap_trig_mode),
        .trig_level  (cap_trig_level_cfg),
        .pre_len     (cap_pre_cfg),
        .src_sel     (cap_src_sel),
        .cap_start   (cap_start_w),
        .cap_len_eff (cap_len_eff_w),
        .trig_idx    (cap_trig_idx_w),
        .sample_cnt  (cap_sample_cnt),
        .st_armed    (st_armed),
        .st_done     (st_done),
        .st_trig     (st_trig),
        .st_busy     (st_busy),
        .st_ovf      (st_ovf),
        .dump_start  (dump_start_cfg),
        .dump_abort  (dump_abort),
        .dump_busy   (dump_busy),
        .dump_done   (dump_done),
        .blocks_done (blocks_done),
        // RX 采样延时 / 诊断计数器：本台不测，接常量避免 Z→X
        .eth_idelay_val  (idly_val),
        .eth_idelay_ld   (idly_ld),
        .eth_idelay_rdy  (1'b1),
        .eth_rx_clk_cnt  (16'd0),
        .eth_rx_dv_cnt   (16'd0),
        .eth_rx_byte_cnt (16'd0),
        .eth_rx_err_cnt  (16'd0)
    );

    //-------------------------------------------------------------------------
    //  DUT2 : scope_capture
    //-------------------------------------------------------------------------
    scope_capture #(
        .DEPTH (DEPTH)
    ) u_cap (
        .clk         (clk),
        .rst_n       (rst_n),
        .arm         (cap_arm),
        .abort       (cap_abort),
        .dec_log2    (cap_dec_log2),
        .cap_len     (cap_len_cfg),
        .trig_mode   (cap_trig_mode),
        .trig_level  (cap_trig_level_cfg),
        .pre_len     (cap_pre_cfg),
        .s_in        (s_in),
        .c_in        (c_in),
        .in_valid    (in_valid),
        // v1.4 新增（连续流）端口：本台不测连续流，但必须显式接常量——
        // 悬空会让 stream 变 Z，进而让 dec_sel 变 X，整条抓包链都动不了。
        .stream      (1'b0),
        .stream_dec  (3'd0),
        .wr_ptr      (),
        .strm_cnt    (),
        .st_stream   (),
        .rd_addr     (cap_rd_addr),
        .rd_en       (cap_rd_en),
        .rd_data     (cap_rd_data),
        .cap_start   (cap_start_w),
        .cap_len_eff (cap_len_eff_w),
        .trig_idx    (cap_trig_idx_w),
        .sample_cnt  (cap_sample_cnt),
        .st_armed    (st_armed),
        .st_done     (st_done),
        .st_trig     (st_trig),
        .st_busy     (st_busy),
        .st_ovf      (st_ovf)
    );

    //-------------------------------------------------------------------------
    //  DUT3 : scope_dump
    //-------------------------------------------------------------------------
    scope_dump #(
        .DEPTH       (DEPTH),
        .BAUD_DIV    (BAUD_DIV),
        .START_DELAY (START_DELAY),
        .PTS         (PTS)
    ) u_dump (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (dump_start_cfg),
        .abort       (dump_abort),
        .line_idle   (1'b1),
        .cap_start   (cap_start_w),
        .cap_len     (cap_len_eff_w),
        .rd_addr     (cap_rd_addr),
        .rd_en       (cap_rd_en),
        .rd_data     (cap_rd_data),
        .tx          (dump_tx),
        .busy        (dump_busy),
        .done        (dump_done),
        .blocks_done (blocks_done)
    );

    //-------------------------------------------------------------------------
    //  寄存器字节写 / 读
    //-------------------------------------------------------------------------
    task reg_write_byte(input [15:0] a, input [7:0] d);
    begin
        @(negedge clk);
        reg_addr  = a;
        reg_wdata = d;
        reg_we    = 1'b1;
        @(negedge clk);
        reg_we    = 1'b0;
    end
    endtask

    // 一次 16 位写 = spi_slave 的 WR0/WR1 两个字节写
    task reg_write16(input [15:0] a, input [15:0] d);
    begin
        reg_write_byte(a,       d[7:0]);
        reg_write_byte(a + 16'd1, d[15:8]);
    end
    endtask

    task reg_read16(input [15:0] a, output [15:0] d);
    begin
        @(negedge clk);
        reg_addr = a;
        #1 d[7:0] = reg_rdata;
        @(negedge clk);
        reg_addr = a + 16'd1;
        #1 d[15:8] = reg_rdata;
    end
    endtask

    //-------------------------------------------------------------------------
    //  样本注入（每调用一次推一个有效样本）
    //-------------------------------------------------------------------------
    task push(input signed [15:0] sv, input signed [15:0] cv);
    begin
        @(negedge clk);
        s_in = sv;
        c_in = cv;
        in_valid = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;
    end
    endtask

    task do_arm;
    begin
        @(negedge clk);
        reg_addr = 16'h0722;
        reg_wdata = 8'h01;
        reg_we = 1'b1;
        @(negedge clk);
        reg_we = 1'b0;
    end
    endtask

    task do_dump_start;
    begin
        @(negedge clk);
        reg_addr = 16'h072E;
        reg_wdata = 8'h01;
        reg_we = 1'b1;
        @(negedge clk);
        reg_we = 1'b0;
    end
    endtask

    //-------------------------------------------------------------------------
    //  UART 字节接收（在被测线上按位采样）
    //-------------------------------------------------------------------------
    task uart_get(output [7:0] b);
        integer i;
        begin
            @(negedge dump_tx);
            #(BIT + HALF);              // 1.5 bit → 第 0 位中心
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = dump_tx;
                #(BIT);
            end
            #(HALF);                    // 跨过停止位中心
        end
    endtask

    //-------------------------------------------------------------------------
    //  收一个块并检查块头 / XOR，把点数据放进 pl[]
    //-------------------------------------------------------------------------
    reg [7:0] hdr [0:7];
    reg [7:0] pl  [0:4*PTS-1];
    integer   npts;
    reg [7:0] xacc;
    integer   k;

    task get_block;
    begin
        for (k = 0; k < 7; k = k + 1) uart_get(hdr[k]);
        npts = hdr[6];
        xacc = hdr[0] ^ hdr[1] ^ hdr[2] ^ hdr[3] ^ hdr[4] ^ hdr[5] ^ hdr[6];
        for (k = 0; k < 4*npts; k = k + 1) begin
            uart_get(pl[k]);
            xacc = xacc ^ pl[k];
        end
        uart_get(hdr[7]);               // 校验字节
        chk8("block checksum", hdr[7], xacc);
    end
    endtask

    //-------------------------------------------------------------------------
    //  主流程
    //-------------------------------------------------------------------------
    reg [15:0] rv;
    integer    i;

    initial begin
        $display("================================================================");
        $display(" tb_scope_chain : 抓包链路自检");
        $display("================================================================");

        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        //=====================================================================
        $display("\n[A] cap_regs：默认值 / 字节写 / 读回");
        //=====================================================================
        reg_read16(16'h072C, rv);
        chk16("A0-BUILD 默认 0x000D", rv, 16'h000D);

        reg_read16(16'h071A, rv);
        chk16("A1-CAP_LEN 默认 28672", rv, 16'd28672);

        reg_read16(16'h0718, rv);
        chk16("A2-CAP_SRC 默认 src=0/dec=1", rv, 16'h0002);

        reg_read16(16'h0720, rv);
        chk16("A3-PRE 默认 1024", rv, 16'd1024);

        reg_write16(16'h071A, 16'h1234);
        reg_read16(16'h071A, rv);
        chk16("A4-CAP_LEN 写 0x1234 读回", rv, 16'h1234);

        reg_write16(16'h0718, 16'h0006);    // src=0, dec_log2=3 (bits[2:1]=11)
        reg_read16(16'h0718, rv);
        chk16("A5-CAP_SRC 写 dec=3 读回", rv, 16'h0006);

        reg_write16(16'h0718, 16'h0000);    // 还原：dec=0
        reg_read16(16'h0718, rv);
        chk16("A6-CAP_SRC 还原 dec=0", rv, 16'h0000);

        //=====================================================================
        $display("\n[B] 立即触发：8 点抓包 → dump → 逐点比对");
        //=====================================================================
        reg_write16(16'h071A, 16'd8);       // CAP_LEN = 8
        reg_write16(16'h071C, 16'd0);       // 立即触发
        reg_write16(16'h0718, 16'h0000);    // 原始、不抽取

        do_arm();
        for (i = 0; i < 8; i = i + 1) push(100 + i, 200 + i);

        repeat (4) @(negedge clk);
        chk(st_done === 1'b1, "B0-st_done 置起");
        chk16("B1-cap_len_eff=8", cap_len_eff_w, 16'd8);
        chk16("B2-cap_start=0",  cap_start_w, 16'd0);
        chk16("B3-trig_idx=0",   cap_trig_idx_w, 16'd0);
        chk16("B4-sample_cnt=8", cap_sample_cnt[15:0], 16'd8);

        do_dump_start();
        get_block();
        chk8("B5-块头 AA", hdr[0], 8'hAA);
        chk8("B6-块头 55", hdr[1], 8'h55);
        chk8("B7-块头 A2", hdr[2], 8'hA2);
        chk8("B8-块类型 10", hdr[3], 8'h10);
        chk8("B9-块号 0", hdr[4], 8'h00);
        chk8("B10-点数 8", hdr[6], 8'd8);

        for (i = 0; i < 8; i = i + 1) begin
            chk16("B11-s 点比对", {pl[4*i+1], pl[4*i]}, 100 + i);
            chk16("B12-c 点比对", {pl[4*i+3], pl[4*i+2]}, 200 + i);
        end
        // busy 在最后一个字节的停止位结束才落低（scope_dump 的 ack 判据），
        // 固定等 5 拍不够，改成有界等待。
        begin : wait_dump_idle
            integer wi;
            wi = 0;
            while (dump_busy !== 1'b0 && wi < 2000) begin
                @(negedge clk);
                wi = wi + 1;
            end
        end
        chk(dump_busy === 1'b0, "B13-dump 结束（busy 落低）");

        //=====================================================================
        $display("\n[C] 上升沿触发 + 预触发 2 点");
        //=====================================================================
        reg_write16(16'h071A, 16'd8);
        reg_write16(16'h071C, 16'd1);       // 上升沿
        reg_write16(16'h071E, 16'd5);       // 门限 5
        reg_write16(16'h0720, 16'd2);       // pre = 2

        do_arm();
        // 0..10 递增：门限 5 在第 6 个样本（下标 5）处上升沿触发，
        // 窗口 = 下标 5 的前 2 个到后 5 个 = 值 3..10
        for (i = 0; i < 11; i = i + 1) push(i, 100 + i);

        repeat (4) @(negedge clk);
        chk(st_done === 1'b1, "C0-st_done 置起");
        chk16("C1-cap_start=3", cap_start_w, 16'd3);
        chk16("C2-trig_idx=2",  cap_trig_idx_w, 16'd2);
        chk16("C3-cap_len_eff=8", cap_len_eff_w, 16'd8);

        do_dump_start();
        get_block();
        chk8("C4-点数 8", hdr[6], 8'd8);
        // 窗口 = 地址 3..10 → 样本 3..10
        for (i = 0; i < 8; i = i + 1) begin
            chk16("C5-s 点比对", {pl[4*i+1], pl[4*i]}, 3 + i);
        end

        //=====================================================================
        $display("\n[D] 抽取 2：喂 8 个样本只应存 4 个");
        //=====================================================================
        reg_write16(16'h071A, 16'd4);
        reg_write16(16'h071C, 16'd0);       // 立即
        reg_write16(16'h0718, 16'h0002);    // dec_log2 = 1

        do_arm();
        for (i = 0; i < 8; i = i + 1) push(i, 100 + i);

        repeat (4) @(negedge clk);
        chk(st_done === 1'b1, "D0-st_done 置起");
        do_dump_start();
        get_block();
        chk8("D1-点数 4", hdr[6], 8'd4);
        chk16("D2-s0 = 0", {pl[1],  pl[0]},  16'sd0);
        chk16("D3-s1 = 2", {pl[5],  pl[4]},  16'sd2);
        chk16("D4-s2 = 4", {pl[9],  pl[8]},  16'sd4);
        chk16("D5-s3 = 6", {pl[13], pl[12]}, 16'sd6);

        //---------------------------------------------------------------------
        $display("\n================================================================");
        if (errors == 0)
            $display(" TEST PASSED (%0d checks)", checks);
        else
            $display(" TEST FAILED (%0d errors / %0d checks)", errors, checks);
        $display("================================================================");
        $finish;
    end

    //-------------------------------------------------------------------------
    //  全局超时保护
    //-------------------------------------------------------------------------
    initial begin
        #20_000_000;
        $display(" TEST FAILED (timeout)");
        $finish;
    end

endmodule
