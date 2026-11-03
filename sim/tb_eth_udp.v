//=============================================================================
//  tb_eth_udp.v —— B2 以太网数据通路测试台
//-----------------------------------------------------------------------------
//  为什么必须单独测：
//    以太网这部分是"纯新增、无先例"的：异步 FIFO、UDP 组帧、CRC、ARP 应答，
//    任何一处错位都不会让设计编译失败，只会在上板时表现为"ping 不通 / 波形乱"。
//    这里用行为级模型把 50 MHz 读侧和 125 MHz 发侧分别钉住：
//      [A] async_fifo   跨时钟域取数，顺序不能乱、不能丢
//      [B] scope_udp    20 个样点切成 3 包，逐字节核对以太网/IP/UDP/应用头
//      [C] eth_tx_mac   前导码 + SFD + 数据 + CRC32（与参考实现逐位比）
//      [D] eth_reply    ARP 请求 → 应答（opcode/字段/SHA 全查）
//=============================================================================

`timescale 1ns / 1ps

module tb_eth_udp;

    //=========================================================================
    //  公共时钟
    //=========================================================================
    localparam real T50  = 20.0;     // 50 MHz
    localparam real T125 = 8.0;      // 125 MHz

    reg clk = 0;
    reg clk_125 = 0;
    always #(T50 / 2.0)  clk = ~clk;
    always #(T125 / 2.0) clk_125 = ~clk_125;

    reg rst_n = 0;
    reg rst_n_125 = 0;

    integer checks = 0;
    integer errors = 0;

    task chk(input cond, input [1023:0] name);
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    task chk8(input [1023:0] name, input [7:0] got, input [7:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %0s: got %02h exp %02h", name, got, exp);
            end
        end
    endtask

    task chk16(input [1023:0] name, input [15:0] got, input [15:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %0s: got %04h exp %04h", name, got, exp);
            end
        end
    endtask

    //=========================================================================
    //  [A] 异步 FIFO
    //=========================================================================
    localparam integer AF_DW = 8;
    localparam integer AF_AW = 4;

    reg          af_wr_en, af_rd_en;
    reg  [7:0]   af_din;
    wire [7:0]   af_dout;
    wire         af_full, af_almost_full, af_empty;
    wire [AF_AW:0] af_wr_level, af_rd_level;

    async_fifo #(.DW(AF_DW), .AW(AF_AW), .ALMOST(2)) u_af (
        .wr_clk      (clk),
        .wr_rst_n    (rst_n),
        .wr_en       (af_wr_en),
        .din         (af_din),
        .full        (af_full),
        .almost_full (af_almost_full),
        .rd_clk      (clk_125),
        .rd_rst_n    (rst_n_125),
        .rd_en       (af_rd_en),
        .dout        (af_dout),
        .empty       (af_empty),
        .wr_level    (af_wr_level),
        .rd_level    (af_rd_level)
    );

    //=========================================================================
    //  [B] scope_udp
    //=========================================================================
    localparam integer DEPTH = 256;
    localparam integer NPTS  = 20;
    localparam integer MAXP  = 8;
    localparam integer CAPSTART = 200;

    wire [15:0] ud_rd_addr;
    wire        ud_rd_en;
    reg  [31:0] ud_rd_data;
    wire        ud_rd_busy;
    wire [7:0]  ud_tx_data;
    wire        ud_tx_valid, ud_tx_last;
    wire        ud_tx_ready;
    wire        ud_tx_busy;
    reg         ud_start, ud_abort;
    wire        ud_busy, ud_done;
    wire [15:0] ud_pkts, ud_drops;

    // 假缓冲：mem[k] = {c, s}，s = k，c = 100 + k
    reg [31:0] mem [0:DEPTH-1];
    integer mi;
    initial begin
        for (mi = 0; mi < DEPTH; mi = mi + 1)
            mem[mi] = {16'd100 + mi[15:0], mi[15:0]};
    end

    always @(posedge clk) begin
        if (ud_rd_en) ud_rd_data <= mem[ud_rd_addr & (DEPTH-1)];
    end

    integer ui;
    initial begin
        ud_rd_data = 32'd0;
    end

    scope_udp #(.DEPTH(DEPTH), .MAX_PTS(MAXP), .SRC_PORT(5000)) u_udp (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (ud_start),
        .abort      (ud_abort),
        .cap_start  (16'd0),
        .n_points   (16'd20),
        .rd_addr    (ud_rd_addr),
        .rd_en      (ud_rd_en),
        .rd_data    (ud_rd_data),
        .rd_busy    (ud_rd_busy),
        .clk_125    (clk_125),
        .rst_n_125  (rst_n_125),
        .dec_log2   (2'd1),
        .udp_port   (16'd5000),
        .my_ip      (32'hC0_A8_01_0A),
        .host_ip    (32'hC0_A8_01_64),
        .my_mac     (48'h02_00_00_00_00_01),
        .host_mac   (48'hAA_BB_CC_DD_EE_FF),
        .tx_hold    (1'b0),
        .tx_data    (ud_tx_data),
        .tx_valid   (ud_tx_valid),
        .tx_last    (ud_tx_last),
        .tx_ready   (ud_tx_ready),
        .tx_busy    (ud_tx_busy),
        .busy       (ud_busy),
        .done       (ud_done),
        .pkt_cnt    (ud_pkts),
        .drop_cnt   (ud_drops)
    );

    assign ud_tx_ready = 1'b1;      // 不施加背压，专测组帧

    // 抓每帧字节
    reg  [7:0] fr [0:2047];
    integer    fpos;
    integer    fcount;
    always @(posedge clk_125) begin
        if (ud_tx_valid && ud_tx_ready) begin
            if (fpos < 2048) fr[fpos] <= ud_tx_data;
            if (ud_tx_last) begin
                fcount <= fcount + 1;
                fpos   <= 0;
            end else begin
                fpos <= fpos + 1;
            end
        end
    end

    //=========================================================================
    //  [C] eth_tx_mac
    //=========================================================================
    reg        tm_valid;
    reg  [7:0] tm_data;
    reg        tm_last;
    wire       tm_ready;
    wire       tm_en;
    wire [7:0] tm_txd;
    wire       tm_err;
    wire       tm_busy, tm_done;
    wire [15:0] tm_len;

    eth_tx_mac u_tm (
        .clk        (clk_125),
        .rst_n      (rst_n_125),
        .tx_valid   (tm_valid),
        .tx_data    (tm_data),
        .tx_last    (tm_last),
        .tx_ready   (tm_ready),
        .gmii_tx_en (tm_en),
        .gmii_txd   (tm_txd),
        .gmii_tx_err(tm_err),
        .busy       (tm_busy),
        .done       (tm_done),
        .frame_len  (tm_len)
    );

    // 线上抓字节（只在 tx_en 时有效）
    reg  [7:0] line [0:255];
    integer    lpos;
    always @(posedge clk_125) begin
        if (tm_en) begin
            if (lpos < 256) line[lpos] <= tm_txd;
            lpos <= lpos + 1;
        end
    end

    // done 那一拍把 frame_len 抓住（之后 MAC 回 IDLE 会清零）
    reg [15:0] len_snap;
    always @(posedge clk_125) begin
        if (tm_done) len_snap <= tm_len;
    end

    // CRC32 参考实现（与 RTL 同参数）
    function [31:0] crc_ref;
        input [31:0] c_in;
        input [7:0]  d;
        integer k;
        reg [31:0] c;
        begin
            c = c_in ^ {24'd0, d};
            for (k = 0; k < 8; k = k + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
            crc_ref = c;
        end
    endfunction

    //=========================================================================
    //  [D] eth_reply（ARP 应答）
    //=========================================================================
    reg  [7:0]  rp_rx_data;
    reg         rp_rx_valid, rp_rx_eof, rp_rx_sof;
    wire [7:0]  rp_tx_data;
    wire        rp_tx_valid, rp_tx_last;
    reg         rp_tx_ready;
    wire        rp_busy;
    wire [47:0] rp_host_mac;
    wire        rp_arp, rp_icmp;

    eth_reply u_rp (
        .clk      (clk_125),
        .rst_n    (rst_n_125),
        .rx_data  (rp_rx_data),
        .rx_valid (rp_rx_valid),
        .rx_eof   (rp_rx_eof),
        .rx_sof   (rp_rx_sof),
        .rx_err   (1'b0),
        .tx_hold  (1'b0),
        .my_mac   (48'h02_00_00_00_00_01),
        .my_ip    (32'hC0_A8_01_0A),
        .tx_data  (rp_tx_data),
        .tx_valid (rp_tx_valid),
        .tx_last  (rp_tx_last),
        .tx_ready (rp_tx_ready),
        .busy     (rp_busy),
        .host_mac (rp_host_mac),
        .host_ip  (),
        .arp_seen (rp_arp),
        .icmp_seen(rp_icmp),
        .rx_bad_pulse()
    );

    reg  [7:0] rfr [0:127];
    integer    rpos, rcount;
    always @(posedge clk_125) begin
        if (rp_tx_valid && rp_tx_ready) begin
            if (rpos < 128) rfr[rpos] <= rp_tx_data;
            if (rp_tx_last) begin
                rcount <= rcount + 1;
                rpos   <= 0;
            end else begin
                rpos <= rpos + 1;
            end
        end
    end

    //=========================================================================
    //  主流程
    //=========================================================================
    integer i, k;
    reg [31:0] c;
    reg [7:0]  arp_req [0:41];

    initial begin
        af_wr_en = 0; af_rd_en = 0; af_din = 8'h00;
        ud_start = 0; ud_abort = 0;
        tm_valid = 0; tm_data = 8'h00; tm_last = 0;
        rp_rx_data = 0; rp_rx_valid = 0; rp_rx_eof = 0; rp_rx_sof = 0; rp_tx_ready = 1;
        fpos = 0; fcount = 0; lpos = 0; rpos = 0; rcount = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk_125);
        rst_n_125 = 1;
        repeat (20) @(posedge clk);

        //---------------------------------------------------------------------
        $display("\n[A] async_fifo：写 10 个字节，读回顺序");
        for (i = 0; i < 10; i = i + 1) begin
            @(negedge clk);
            af_wr_en = 1; af_din = 8'hA0 + i[7:0];
        end
        @(negedge clk);
        af_wr_en = 0;
        repeat (10) @(posedge clk_125);
        chk(af_empty === 1'b0, "A1-写入后 non-empty");
        for (i = 0; i < 10; i = i + 1) begin
            @(negedge clk_125);
            af_rd_en = 1;
            @(posedge clk_125);
            #1;
            chk8("A2-读回字节", af_dout, 8'hA0 + i[7:0]);
        end
        @(negedge clk_125);
        af_rd_en = 0;
        repeat (10) @(posedge clk_125);
        chk(af_empty === 1'b1, "A3-读完 empty");

        //---------------------------------------------------------------------
        $display("\n[B] scope_udp：20 点 → 3 包（8/8/4）");
        @(negedge clk);
        ud_start = 1;
        @(negedge clk);
        ud_start = 0;
        // 等 done
        wait (fcount == 3);
        repeat (20) @(posedge clk_125);

        chk16("B1-包数", ud_pkts, 16'd3);
        chk(ud_drops === 16'd0, "B2-无丢点");
        // 包 0 的头（fcount 已归零前内容保留在 fr）
        // 注意 fr 在每包结束时被后续包覆盖，这里检查最后一包（pkt2，4 点）
        chk8("B3-包2 DA0", fr[0], 8'hAA);
        chk8("B4-包2 DA5", fr[5], 8'hFF);
        chk8("B5-包2 SA0", fr[6], 8'h02);
        chk8("B6-包2 type", fr[12], 8'h08);
        chk8("B7-包2 ip ver", fr[14], 8'h45);
        chk8("B8-包2 proto", fr[23], 8'h11);
        chk8("B9-包2 src port hi", fr[34], 8'h13);   // 5000 = 0x1388
        chk8("B10-包2 src port lo", fr[35], 8'h88);
        chk8("B11-包2 魔数0", fr[42], 8'hE7);
        chk8("B12-包2 魔数1", fr[43], 8'h5A);
        chk8("B13-包2 last 标志", fr[44], 8'h01);
        chk8("B14-包2 抽取 log2", fr[45], 8'h01);
        chk8("B15-包2 包序号 lo", fr[46], 8'h02);
        chk8("B16-包2 首样点 lo", fr[48], 8'd16);
        // 包 2 的 4 个样点：s=16..19, c=116..119
        chk8("B17-包2 样点0 s_lo", fr[58], 8'd16);
        chk8("B18-包2 样点0 s_hi", fr[59], 8'd0);
        chk8("B19-包2 样点0 c_lo", fr[60], 8'd116);
        chk8("B20-包2 样点0 c_hi", fr[61], 8'd0);
        chk8("B21-包2 样点3 s_lo", fr[70], 8'd19);
        chk8("B22-包2 样点3 c_lo", fr[72], 8'd119);

        // 调试：把包 2 的 34..74 字节打出来
        $write("[B-DBG] len_bytes=");
        for (k = 34; k < 74; k = k + 1) $write("%02h ", fr[k]);
        $write("\n");

        //---------------------------------------------------------------------
        $display("\n[C] eth_tx_mac：前导码 / SFD / CRC32");
        @(negedge clk_125);
        tm_valid = 1; tm_data = 8'h00; tm_last = 0;
        // 60 字节帧：0,1,2,...59。tx_ready 为高表示"下一个上升沿消费本字节"，
        // 所以每看到 ready 就等那个上升沿过去，再换下一个字节。
        i = 0;
        while (i < 60) begin
            @(negedge clk_125);
            if (tm_ready) begin
                @(posedge clk_125);
                #1;                      // 避开与 DUT 采样的同一时间步竞争
                i = i + 1;
                if (i < 60) begin
                    tm_data = i[7:0];
                    tm_last = (i == 59);
                end
            end
        end
        tm_valid = 0;
        tm_last  = 0;
        wait (tm_done === 1'b1);
        repeat (5) @(posedge clk_125);

        chk8("C1-前导码0", line[0], 8'h55);
        chk8("C2-前导码6", line[6], 8'h55);
        chk8("C3-SFD", line[7], 8'hD5);
        chk8("C4-数据首字节", line[8], 8'h00);
        chk8("C5-数据末字节", line[67], 8'd59);
        // CRC 参考
        c = 32'hFFFF_FFFF;
        for (i = 0; i < 60; i = i + 1) c = crc_ref(c, i[7:0]);
        c = ~c;
        chk8("C6-CRC0", line[68], c[7:0]);
        chk8("C7-CRC1", line[69], c[15:8]);
        chk8("C8-CRC2", line[70], c[23:16]);
        chk8("C9-CRC3", line[71], c[31:24]);
        chk16("C10-frame_len", len_snap, 16'd60);

        //---------------------------------------------------------------------
        $display("\n[D] eth_reply：ARP 请求 → 应答");
        // 组 ARP 请求
        for (i = 0; i < 6; i = i + 1) arp_req[i] = 8'hFF;
        arp_req[6]=8'hAA; arp_req[7]=8'hBB; arp_req[8]=8'hCC;
        arp_req[9]=8'hDD; arp_req[10]=8'hEE; arp_req[11]=8'hFF;
        arp_req[12]=8'h08; arp_req[13]=8'h06;
        arp_req[14]=8'h00; arp_req[15]=8'h01;
        arp_req[16]=8'h08; arp_req[17]=8'h00;
        arp_req[18]=8'h06; arp_req[19]=8'h04;
        arp_req[20]=8'h00; arp_req[21]=8'h01;      // request
        arp_req[22]=8'hAA; arp_req[23]=8'hBB; arp_req[24]=8'hCC;
        arp_req[25]=8'hDD; arp_req[26]=8'hEE; arp_req[27]=8'hFF;
        arp_req[28]=8'hC0; arp_req[29]=8'hA8; arp_req[30]=8'h01; arp_req[31]=8'h64;
        arp_req[32]=0; arp_req[33]=0; arp_req[34]=0;
        arp_req[35]=0; arp_req[36]=0; arp_req[37]=0;
        arp_req[38]=8'hC0; arp_req[39]=8'hA8; arp_req[40]=8'h01; arp_req[41]=8'h0A;

        for (i = 0; i < 42; i = i + 1) begin
            @(negedge clk_125);
            rp_rx_data  = arp_req[i];
            rp_rx_valid = 1;
            rp_rx_eof   = 0;
            rp_rx_sof   = (i == 0);
        end
        @(negedge clk_125);
        rp_rx_valid = 1; rp_rx_eof = 1; rp_rx_data = 0; rp_rx_sof = 0;
        @(negedge clk_125);
        rp_rx_valid = 0; rp_rx_eof = 0; rp_rx_sof = 0;

        wait (rcount >= 1);
        repeat (10) @(posedge clk_125);

        chk(rcount >= 1, "D1-回了 ARP");
        chk8("D2-DA0", rfr[0], 8'hAA);
        chk8("D3-DA5", rfr[5], 8'hFF);
        chk8("D4-SA0", rfr[6], 8'h02);
        chk8("D5-type", rfr[12], 8'h08);
        chk8("D6-htype", rfr[14], 8'h00);
        chk8("D7-opcode hi", rfr[20], 8'h00);
        chk8("D8-opcode lo", rfr[21], 8'h02);
        chk8("D9-sha0", rfr[22], 8'h02);
        chk8("D10-spa0", rfr[28], 8'hC0);
        chk8("D11-spa3", rfr[31], 8'h0A);
        chk8("D12-tha0", rfr[32], 8'hAA);
        chk8("D13-tpa3", rfr[41], 8'h64);
        chk(rp_host_mac === 48'hAA_BB_CC_DD_EE_FF, "D15-学到 host_mac");

        //---------------------------------------------------------------------
        if (errors == 0) $display("\n TEST PASSED (%0d checks)", checks);
        else             $display("\n TEST FAILED (%0d errors / %0d checks)", errors, checks);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("\n TEST FAILED (timeout)");
        $finish;
    end

    // 临时调试：看 UDP 状态机卡在哪
    integer dbg;
    initial begin
        for (dbg = 0; dbg < 8; dbg = dbg + 1) begin
            #(20_000);
            $display("[DBG t=%0t] st=%0d hcur=%b hnxt=%b empty=%b af=%b wlvl=%0d rd_run=%b rdv1=%b pkts=%0d fcount=%0d fpos=%0d",
                     $time, u_udp.st, u_udp.have_cur, u_udp.have_nxt, u_udp.fifo_empty, u_udp.fifo_almost_full,
                     u_udp.fifo_wr_level, u_udp.rd_run, u_udp.rd_v1, u_udp.pkt_cnt,
                     fcount, fpos);
        end
    end

endmodule
