//=============================================================================
//  tb_ddr3_full.v —— 满容量（RING_AW=18, 1 M 样点）一轮写满 + 完整回读
//-----------------------------------------------------------------------------
//  目的：复现上板现象（GOT=1 M、ERR=1 M、第一个错点是 pat(252)）。
//  与 tb_ddr3_ring 的区别：
//    * RING_AW=18（真容量 262144 字 = 1048576 样点），写满一圈；
//    * 统计写命令数 wc（应当 = 262144）与写数据握手数 wd；
//    * 回读打印前 12 个样点，并逐点比对到第 1 个错点为止。
//  MIG 模型复用 tb_ddr3_ring.v 里的 mig_ui_model。
//=============================================================================
`timescale 1ns / 1ps

module tb_ddr3_full;

    // 默认跑“小容量满圈”快速版（RING_AW=10 → 1024 字 = 4096 样点，绕 2 圈）；
    // 需要 1 M 样点全容量版时给 xvlog 加 -d FULLSIM。
`ifdef FULLSIM
    localparam integer RING_AW  = 18;
    localparam integer NSAMP    = 1048576;
`else
    localparam integer RING_AW  = 10;
    localparam integer NSAMP    = 8192;
`endif
    localparam [31:0]  PAT_XOR  = 32'h5A5A0000;

    reg clk50 = 0;
    reg clk100 = 0;
    reg rst = 1;
    always #10 clk50  = ~clk50;      // 50 MHz
    always #5  clk100 = ~clk100;     // 100 MHz

    function [31:0] pat(input [31:0] i);
        begin
            pat = i ^ PAT_XOR;
        end
    endfunction

    // 环形语义：逻辑序号 idx 对应的物理槽里存的是“最后一次写到该槽”的样点。
    localparam integer CAP = (1 << RING_AW) * 4;
    function [31:0] pat_slot(input [31:0] idx);
        integer e;
        begin
            e = idx + ((NSAMP - 1 - idx) / CAP) * CAP;
            pat_slot = e[31:0] ^ PAT_XOR;
        end
    endfunction

    //-------------------------------------------------------------------------
    // 写侧（仿 ddr3_top_mem 的写法：组合 valid + 握手成功才前进）
    //-------------------------------------------------------------------------
    reg  [31:0] wr_idx;
    wire [31:0] wr_data = pat(wr_idx);
    wire        wr_valid = (wr_idx < NSAMP);
    wire        wr_ready;
    wire [31:0] wr_samples;
    wire        wr_wrapped;

    //-------------------------------------------------------------------------
    // 读侧
    //-------------------------------------------------------------------------
    reg         rd_start;
    reg  [31:0] rd_base;
    reg  [31:0] rd_len;
    wire [31:0] rd_data;
    wire        rd_valid;
    wire        rd_done;
    wire        rd_busy;

    wire [27:0] app_addr;
    wire [2:0]  app_cmd;
    wire        app_en;
    wire [127:0] app_wdf_data;
    wire        app_wdf_wren;
    wire        app_wdf_end;
    wire        app_rdy;
    wire        app_wdf_rdy;
    wire [127:0] app_rd_data;
    wire        app_rd_data_valid;
    wire        app_rd_data_end;
    wire [15:0] app_wdf_mask;

    ddr3_ring #(
        .RING_AW (RING_AW),
        .FIFO_AW (8),
        .MAX_OUT (1),
        .OQ_AW   (4)
    ) dut (
        .ui_clk          (clk100),
        .ui_rst          (rst),
        .wr_clk          (clk50),
        .wr_rst_n        (~rst),
        .wr_valid        (wr_valid),
        .wr_data         (wr_data),
        .wr_ready        (wr_ready),
        .wr_samples      (wr_samples),
        .wr_wrapped      (wr_wrapped),
        .rd_start        (rd_start),
        .rd_base         (rd_base),
        .rd_len          (rd_len),
        .rd_data         (rd_data),
        .rd_valid        (rd_valid),
        .rd_done         (rd_done),
        .rd_busy         (rd_busy),
        .app_addr        (app_addr),
        .app_cmd         (app_cmd),
        .app_en          (app_en),
        .app_wdf_data    (app_wdf_data),
        .app_wdf_wren    (app_wdf_wren),
        .app_wdf_end     (app_wdf_end),
        .app_rdy         (app_rdy),
        .app_wdf_rdy     (app_wdf_rdy),
        .app_rd_data     (app_rd_data),
        .app_rd_data_valid (app_rd_data_valid),
        .app_rd_data_end (app_rd_data_end),
        .app_wdf_mask    (app_wdf_mask),
        .dbg_need        (),
        .dbg_pend        (),
        .dbg_wleft       (),
        .dbg_addr        ()
    );

    mig_ui_model #(.AW(RING_AW)) u_model (
        .clk              (clk100),
        .rst              (rst),
        .app_addr         (app_addr),
        .app_cmd          (app_cmd),
        .app_en           (app_en),
        .app_wdf_data     (app_wdf_data),
        .app_wdf_wren     (app_wdf_wren),
        .app_wdf_end      (app_wdf_end),
        .app_rdy          (app_rdy),
        .app_wdf_rdy      (app_wdf_rdy),
        .app_rd_data      (app_rd_data),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rd_data_end  (app_rd_data_end)
    );

    //-------------------------------------------------------------------------
    // 握手计数
    //-------------------------------------------------------------------------
    integer wc = 0;
    integer wd = 0;
    integer rc = 0;
    integer rv = 0;
    always @(posedge clk100) begin
        if (!rst) begin
            if (app_en && app_rdy && app_cmd == 3'd0) wc = wc + 1;
            if (app_wdf_wren && app_wdf_rdy)          wd = wd + 1;
            if (app_en && app_rdy && app_cmd == 3'd1) rc = rc + 1;
            if (app_rd_data_valid)                    rv = rv + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    localparam [3:0] S_IDLE = 4'd0, S_WR = 4'd1, S_FLSH = 4'd2,
                     S_RQ = 4'd3, S_RD = 4'd4, S_DONE = 4'd5;

    reg [3:0]  st;
    integer    flush_cnt;
    integer    got;
    integer    err;
    integer    first_bad_idx;
    reg [31:0] first_bad_exp, first_bad_got;
    integer    shown;
    integer    ib;

    always @(posedge clk50) begin
        if (rst) begin
            st        <= S_IDLE;
            flush_cnt <= 0;
        end else begin
            if (wr_valid && wr_ready) wr_idx <= wr_idx + 32'd1;
            case (st)
            S_IDLE: st <= S_WR;
            S_WR:   if (wr_idx >= NSAMP) st <= S_FLSH;
            S_FLSH: begin
                flush_cnt <= flush_cnt + 1;
                if (flush_cnt == 5000) st <= S_RQ;
            end
            S_RQ: begin
                if (rd_busy) st <= S_RD;
            end
            default: ;
            endcase
        end
    end

    // rd_start / rd_base 用 clk100 域（和 dut 同一个域，直接驱动）
    always @(posedge clk100) begin
        if (rst) begin
            rd_start <= 1'b0;
            rd_base  <= 32'd0;
            rd_len   <= 32'd0;
        end else begin
            if (st == S_RQ) begin
                rd_base  <= 32'd0;
                rd_len   <= NSAMP;
                rd_start <= 1'b1;
            end else begin
                rd_start <= 1'b0;
            end
        end
    end

    always @(posedge clk100) begin
        if (rst) begin
            got  <= 0;
            err  <= 0;
            shown <= 0;
            first_bad_idx <= -1;
        end else if (rd_valid) begin
            if (shown < 12) begin
                $display("  [read %0d] data=%08h exp=%08h %s", got, rd_data,
                         pat_slot(got), (rd_data === pat_slot(got)) ? "ok" : "MISMATCH");
                shown <= shown + 1;
            end
            if (rd_data !== pat_slot(got)) begin
                err <= err + 1;
                if (first_bad_idx < 0) begin
                    first_bad_idx <= got;
                    first_bad_exp <= pat_slot(got);
                    first_bad_got <= rd_data;
                end
            end
            got <= got + 1;
            if (got >= NSAMP - 1) begin
                $display("");
                $display("RESULT: got=%0d err=%0d wc=%0d wd=%0d rc=%0d rv=%0d",
                         got + 1, err, wc, wd, rc, rv);
                $display("        words_expect=%0d (cmd per word = %0f)",
                         NSAMP / 4, wc * 1.0 / (NSAMP / 4.0));
                if (first_bad_idx >= 0)
                    $display("        first_bad idx=%0d exp=%08h got=%08h",
                             first_bad_idx, first_bad_exp, first_bad_got);
                if (err == 0) $display("TEST PASSED");
                else          $display("TEST FAILED");
                $finish;
            end
        end
    end

    // 超时保护
    initial begin
        #2_000_000;
        $display("TIMEOUT: st=%0d wr_idx=%0d got=%0d", st, wr_idx, got);
        $finish;
    end

    // 进度观察：每 20 us 打一次内部状态
    initial begin
        forever begin
            #5_000;
            if (rst === 1'b0)
                $display("[%0t] wr_idx=%0d wrrdy=%b afull=%b wp=%0d rp=%0d rdg=%b rgs2=%b fifo_rd_en=%b rd_pend=%b wcnt=%0d wready=%b cons=%b",
                         $time, wr_idx, wr_ready, dut.fifo_almost_full,
                         dut.u_wfifo.wr_ptr, dut.u_wfifo.rd_ptr, dut.u_wfifo.rd_gray,
                         dut.u_wfifo.rd_gray_s2, dut.fifo_rd_en, dut.rd_pend, dut.w_cnt,
                         dut.w_ready, dut.w_consume);
        end
    end

    initial begin
        wr_idx = 32'd0;
        rst    = 1'b1;
        #200 rst = 1'b0;
    end

endmodule
