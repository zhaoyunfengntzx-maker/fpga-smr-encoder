//=============================================================================
//  tb_stream_tx.v —— 连续流发送的离线验证
//-----------------------------------------------------------------------------
//  为什么必须测：
//    连续流没有"抓完"这个终点，坏掉的方式不是"少一个包"，而是
//      (a) 包序号不连续（主机拼不起来）；
//      (b) 64 bit 绝对序号没跟着走（主机以为连续，其实中间缺了一段）；
//      (c) 读侧落后太多时没有整段丢弃（读到被覆盖的半新半旧数据 → 假波形）。
//    这三件事在板上都看不出来（波形总是"像"的），只能逐字节核对。
//
//  注意：断言名一律用 ASCII，xsim 的 $display 走本地代码页，中文会乱码。
//=============================================================================

`timescale 1ns / 1ps

module tb_stream_tx;

    localparam integer T50  = 20;      // 50 MHz
    localparam integer T125 = 8;       // 125 MHz
    localparam integer PTS  = 8;       // 每包样点数（缩小以便快速跑完）
    localparam integer FRM  = 58 + 4*PTS;

    reg clk = 0, clk_125 = 0;
    always #(T50/2.0)  clk     = ~clk;
    always #(T125/2.0) clk_125 = ~clk_125;

    reg rst_n = 0, rst_n_125 = 0;

    reg         en = 0;
    reg  [15:0] wr_ptr = 0;
    wire [15:0] rd_addr;
    wire        rd_en;
    reg  [31:0] rd_data;
    wire [31:0] drop_samples;

    wire [7:0]  tx_data;
    wire        tx_valid, tx_last, tx_busy;
    wire [31:0] pkts, underflow;
    wire        fifo_ovf;
    wire [15:0] lag;

    // 假缓冲：mem[i] = {c = 1000+i, s = 100+i}
    reg [31:0] mem [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) mem[i] = {16'd1000 + i[15:0], 16'd100 + i[15:0]};
    end

    always @(posedge clk) begin
        if (rd_en) rd_data <= mem[rd_addr[7:0]];
    end

    stream_tx #(.DEPTH(256), .MAX_PTS(PTS), .SRC_PORT(16'd5000)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .dec_log2(3'd2),
        .wr_ptr(wr_ptr), .rd_addr(rd_addr), .rd_en(rd_en), .rd_data(rd_data),
        .drop_samples(drop_samples),
        .clk_125(clk_125), .rst_n_125(rst_n_125),
        .my_mac(48'h02_00_00_00_00_01),
        .my_ip(32'hC0_A8_01_0A), .host_ip(32'hC0_A8_01_64),
        .udp_port(16'd41000),   // 与 SRC_PORT(5000) 不同，才能证明端口没写反
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_last(tx_last),
        .tx_ready(1'b1), .tx_busy(tx_busy),
        .pkts(pkts), .fifo_ovf(fifo_ovf), .underflow(underflow), .lag(lag)
    );

    // ---- 监视 FIFO 写/读（调试用，跑通后删掉）----
    integer n_wr = 0, n_rd = 0;
    always @(posedge clk) begin
        if (dut.fifo_wr_en) begin
            if (n_wr < 20)
                $display("  WR[%0d] idx=%0d data=%04h", n_wr, dut.rd_idx_q, dut.rd_data);
            n_wr = n_wr + 1;
        end
    end
    always @(posedge clk_125) begin
        if (dut.fifo_rd && !dut.fifo_empty) begin
            if (n_rd < 20)
                $display("  RD[%0d] idx=%0d data=%04h", n_rd, dut.fifo_dout[63:32], dut.fifo_dout[15:0]);
            n_rd = n_rd + 1;
        end
    end

    integer checks = 0, errors = 0;
    task chk(input cond, input [8*40-1:0] name);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    task chk8(input [8*40-1:0] name, input [7:0] got, input [7:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %0s: got %02h exp %02h", name, got, exp);
            end
        end
    endtask

    // ---- 收帧 + 逐字节检查 ----
    reg [7:0] frm [0:1023];
    integer   plen = 0;
    integer   npkt = 0;
    integer   pk, bad, j, bad_i;
    reg [31:0] first_lo, first_hi;
    reg [15:0] exp_s, exp_c;

    // ★ 上板缺陷 #32 的回归哨兵：帧内 tx_valid 不许断流。
    //   断一拍 → eth_tx_mac 的“断流补 0”会塞 0 字节，线上帧长 ≠ IP 总长。
    integer gap_err = 0;
    reg     in_frm = 1'b0;

    always @(posedge clk_125) begin
        if (in_frm && !tx_valid) begin
            gap_err = gap_err + 1;
            in_frm  = 1'b0;
        end
        if (tx_valid) begin
            in_frm = 1'b1;
            frm[plen] <= tx_data;
            if (tx_last) begin
                in_frm = 1'b0;
                chk8("eth_type_hi", frm[12], 8'h08);
                chk8("eth_type_lo", frm[13], 8'h00);
                chk8("ip_ver_ihl",  frm[14], 8'h45);
                chk8("ip_proto",    frm[23], 8'h11);
                chk8("src_port_hi", frm[34], 8'h13);   // SRC_PORT=5000
                chk8("src_port_lo", frm[35], 8'h88);
                chk8("dst_port_hi", frm[36], 8'hA0);   // 41000
                chk8("dst_port_lo", frm[37], 8'h28);
                chk8("magic_hi",    frm[42], 8'hE7);
                chk8("magic_lo",    frm[43], 8'h5A);
                chk8("flags_stream",frm[44], 8'h02);
                chk8("dec_log2",    frm[45], 8'd2);
                chk((plen + 1) == FRM, "frame_len");

                // 包序号从 1 开始（复位后第一包是 1）；★ 小端，与 scope_udp 一致
                chk({frm[47], frm[46]} == (npkt[15:0] + 16'd1), "seq++");

                first_lo = {frm[51], frm[50], frm[49], frm[48]};
                first_hi = {frm[55], frm[54], frm[53], frm[52]};
                chk(first_hi == 32'd0, "idx_hi_zero");
                chk(first_lo == (npkt[31:0] * PTS), "idx_low");

                bad = 0;
                bad_i = -1;
                for (pk = 0; pk < PTS; pk = pk + 1) begin
                    exp_s = 16'd100  + first_lo[15:0] + pk[15:0];
                    exp_c = 16'd1000 + first_lo[15:0] + pk[15:0];
                    // 最后一个字节这一拍还没写进 frm（它就在 tx_data 上）
                    if (58+4*pk+1 <= plen) begin
                        if ({frm[58+4*pk+1], frm[58+4*pk]}   !== exp_s) begin
                            bad = bad + 1;
                            if (bad_i < 0) begin
                                bad_i = pk;
                                $display("    MISMATCH pkt=%0d k=%0d got_s=%04h exp_s=%04h plen=%0d",
                                         npkt, pk, {frm[58+4*pk+1], frm[58+4*pk]}, exp_s, plen);
                            end
                        end
                    end
                    // 注意用 < 而不是 <=：索引恰好等于 plen 的字节还没写进 frm，
                    // 它就在这一拍的 tx_data 上（帧长 90、plen=89 时正好是最后一个字节）
                    if (58+4*pk+3 < plen) begin
                        if ({frm[58+4*pk+3], frm[58+4*pk+2]} !== exp_c) bad = bad + 1;
                    end else begin
                        if ({tx_data, frm[58+4*pk+2]} !== exp_c) bad = bad + 1;
                    end
                end
                chk(bad == 0, "samples");

                $display("  pkt %0d: seq=%0d first_lo=%0d plen=%0d",
                         npkt, {frm[47], frm[46]}, first_lo, plen);
                if (npkt == 0) begin
                    for (j = 58; j < FRM - 1; j = j + 1) $display("    s[%0d] %02h", j, frm[j]);
                end

                npkt <= npkt + 1;
                plen <= 0;
            end else begin
                plen <= plen + 1;
            end
        end
    end

    // 生产样点：每 4 拍写一个，共 100 个
    integer prod = 0;
    reg     run_prod = 0;
    reg [1:0] pcnt = 0;
    always @(posedge clk) begin
        if (run_prod && prod < 200) begin
            pcnt <= pcnt + 2'd1;
            if (pcnt == 2'd3) begin
                wr_ptr <= wr_ptr + 16'd1;
                prod   <= prod + 1;
            end
        end
    end

    integer k;
    initial begin
        $display("\n[stream_tx] continuous stream check");

        repeat (4) @(posedge clk);
        rst_n = 1; rst_n_125 = 1;
        repeat (4) @(posedge clk);

        $display("\n[A] disabled: no frame");
        en = 0;
        repeat (300) @(posedge clk_125);
        chk(npkt == 0, "no_frame_when_disabled");

        $display("\n[B] enable + 100 samples");
        en = 1; run_prod = 1;
        k = 0;
        while (npkt < 12 && k < 400000) begin
            @(posedge clk_125);
            k = k + 1;
        end
        run_prod = 0;
        repeat (200) @(posedge clk_125);
        chk(npkt >= 12, "at_least_12_pkts");
        $display("  pkts=%0d drop=%0d lag=%0d prod=%0d lvl=%0d full=%b empty=%b rdp=%0d wr=%0d",
                 npkt, drop_samples, lag, prod, dut.fifo_rd_level,
                 dut.fifo_full, dut.fifo_empty, dut.rd_ptr, wr_ptr);

        $display("\n[C] overrun: reader falls too far behind");
        repeat (5) @(posedge clk);
        wr_ptr <= wr_ptr + 16'd200;
        repeat (40) @(posedge clk);
        chk(drop_samples > 0, "drop_counted");

        $display("\n[D] disable: no hang");
        en = 0;
        repeat (40) @(posedge clk);
        chk(1'b1, "no_hang");

        chk(gap_err == 0, "no_tx_gap_in_frame");
        if (errors == 0) $display("\n TEST PASSED (%0d checks)", checks);
        else             $display("\n TEST FAILED (%0d errors / %0d checks)", errors, checks);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("\n TEST FAILED (timeout)");
        $finish;
    end

endmodule
