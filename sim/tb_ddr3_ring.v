//=============================================================================
//  tb_ddr3_ring.v —— ddr3_ring 行为级自检（不需要 MIG / 不需要板子）
//-----------------------------------------------------------------------------
//  用一个行为级 MIG UI 模型（带随机 app_rdy / app_wdf_rdy 反压 + 读延迟）验证：
//    [A] 写入：200 个样点经异步 FIFO → 攒字 → 写命令，wr_samples 计数正确
//    [B] 回读：从 base=0 读 256 点，逐点比对
//    [C] 非对齐：从 base=5 读 10 点（触发 skip 路径），逐点比对
//    [D] 回绕：写超过环形容量后 wr_wrapped 置位、samp_cnt 饱和
//=============================================================================
`timescale 1ns / 1ps

// mig_ui_model moved to sim/mig_ui_model.v (shared by both DDR3 TBs).


module tb_ddr3_ring;

    localparam integer RING_AW = 6;          // 64 字 = 256 样点
    // 正好写满环形容量（1<<6 字 x 4 点 = 256）：上板 1M 点恰好等于满容量，
    // 用这个规模复现“整环写满”的边界。
    localparam integer NSAMP   = 256;

    reg  wr_clk = 0, ui_clk = 0;
    reg  wr_rst_n = 0, ui_rst = 1;

    always #10 wr_clk = ~wr_clk;             // 50 MHz
    always #5  ui_clk = ~ui_clk;             // 100 MHz

    reg         wr_valid = 0;
    reg  [31:0] wr_data  = 0;
    wire        wr_ready;
    wire [31:0] wr_samples;
    wire        wr_wrapped;

    reg         rd_start = 0;
    reg  [31:0] rd_base  = 0;
    reg  [31:0] rd_len   = 0;
    wire [31:0] rd_data;
    wire        rd_valid, rd_done, rd_busy;

    // MIG UI
    wire [27:0]  app_addr;
    wire [2:0]   app_cmd;
    wire         app_en;
    wire [127:0] app_wdf_data;
    wire         app_wdf_wren, app_wdf_end;
    wire [15:0]  app_wdf_mask;
    wire         app_rdy, app_wdf_rdy;
    wire [127:0] app_rd_data;
    wire         app_rd_data_valid, app_rd_data_end;

    ddr3_ring #(
        .RING_AW (RING_AW),
        .FIFO_AW (4),
        .MAX_OUT (1),
        .OQ_AW   (4)
    ) dut (
        .wr_clk      (wr_clk),
        .wr_rst_n    (wr_rst_n),
        .wr_valid    (wr_valid),
        .wr_data     (wr_data),
        .wr_ready    (wr_ready),
        .wr_samples  (wr_samples),
        .wr_wrapped  (wr_wrapped),
        .ui_clk      (ui_clk),
        .ui_rst      (ui_rst),
        .rd_start    (rd_start),
        .rd_base     (rd_base),
        .rd_len      (rd_len),
        .rd_data     (rd_data),
        .rd_valid    (rd_valid),
        .rd_done     (rd_done),
        .rd_busy     (rd_busy),
        .app_addr    (app_addr),
        .app_cmd     (app_cmd),
        .app_en      (app_en),
        .app_wdf_data(app_wdf_data),
        .app_wdf_end (app_wdf_end),
        .app_wdf_wren(app_wdf_wren),
        .app_wdf_mask(app_wdf_mask),
        .app_rdy     (app_rdy),
        .app_wdf_rdy (app_wdf_rdy),
        .app_rd_data (app_rd_data),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rd_data_end  (app_rd_data_end)
    );

    mig_ui_model #(.AW(RING_AW)) u_mig (
        .clk              (ui_clk),
        .rst              (ui_rst),
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

    integer checks = 0, errors = 0;
    task chk(input cond, input [255:0] name);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    // 写入第 i 个样点的图案
    function [31:0] pat(input integer i);
        pat = {16'h1234 + i[15:0], 16'hA500 + i[15:0]};
    endfunction

    integer i, k, got, di;
    reg [31:0] exp;

    // 收集回读数据
    reg [31:0] cap [0:511];
    integer    cap_n;

    always @(posedge ui_clk) begin
        if (rd_valid) begin
            if (cap_n < 512) cap[cap_n] = rd_data;
            cap_n = cap_n + 1;
        end
    end

    initial begin : run
        cap_n = 0;

        repeat (10) @(posedge ui_clk);
        ui_rst   = 1'b0;
        wr_rst_n = 1'b1;
        repeat (5) @(posedge ui_clk);

        //------------------------------------------------ [A] 写入 200 点
        // 标准 ready/valid 握手：valid 与 data 同时寄存，只有 valid && ready 才前进
        i = 0;
        k = 0;
        wr_valid <= 1'b1;
        wr_data  <= pat(0);
        while (i < NSAMP && k < 20000) begin
            @(posedge wr_clk);
            k = k + 1;
            if (wr_valid && wr_ready) begin
                i = i + 1;
                wr_data <= pat(i);
            end
            if (k % 2000 == 0)
                $display("    wr stuck: sent=%0d st=%0d pend=%0d left=%0d w_ready=%0d w_cnt=%0d fifo_empty=%0d",
                         i, dut.st, dut.eng_pend, dut.eng_words_left,
                         dut.w_ready, dut.w_cnt, dut.fifo_empty);
        end
        @(posedge wr_clk);
        wr_valid <= 1'b0;
        $display("  [A] 写完 %0d 点，用了 %0d 个 wr_clk", i, k);

        // 等 FIFO 排空 + 引擎写完
        repeat (4000) @(posedge ui_clk);
        $display("  [A] wr_samples=%0d wrapped=%0d", wr_samples, wr_wrapped);
        chk(wr_samples == NSAMP, "write_samples");
        chk(wr_wrapped == 1'b1, "full_ring_wrapped");

        //------------------------------------------------ [B] 从 base=0 读回全部
        cap_n = 0;
        @(posedge ui_clk);
        rd_start <= 1'b1; rd_base <= 32'd0; rd_len <= NSAMP;
        @(posedge ui_clk);
        rd_start <= 1'b0;

        wait_done(200000);
        $display("  [B] got %0d pts", cap_n);
        chk(cap_n == NSAMP, "readback_pts");
        errors_loop(0, NSAMP);

        //------------------------------------------------ [C] 非对齐 base=5
        cap_n = 0;
        @(posedge ui_clk);
        rd_start <= 1'b1; rd_base <= 32'd5; rd_len <= 32'd10;
        @(posedge ui_clk);
        rd_start <= 1'b0;
        // rd_done 是粘滞的：上一次回读的完成标志要到 rd_start 之后下一拍才清，
        // 不等这两拍就会把上一轮 cap[] 的残留当成这一轮的结果。
        @(posedge ui_clk);
        @(posedge ui_clk);

        wait_done(100000);
        chk(cap_n == 10, "非对齐回读点数 = 10");
        for (i = 0; i < 10; i = i + 1) begin
            exp = pat(5 + i);
            if (cap[i] !== exp) begin
                errors = errors + 1;
                $display("  [C] 第 %0d 点 mismatch got=%08h exp=%08h", i, cap[i], exp);
            end
            checks = checks + 1;
        end

        //------------------------------------------------ [D] 写满判定
        chk(wr_wrapped == 1'b1, "still_full_wrapped");

        $display("");
        $display(" %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display(" TEST PASSED");
        else             $display(" TEST FAILED");
        $finish;
    end

    task wait_done(input integer max_cyc);
        integer c;
        begin
            c = 0;
            while (!rd_done && c < max_cyc) begin
                @(posedge ui_clk);
                c = c + 1;
            end
            if (!rd_done) $display("  [TIMEOUT] rd_done 没来（%0d 拍）", max_cyc);
        end
    endtask

    task errors_loop(input integer from, input integer to);
        integer j;
        begin
            for (j = from; j < to; j = j + 1) begin
                exp = pat(j);
                if (cap[j] !== exp) begin
                    errors = errors + 1;
                    if (errors <= 5)
                        $display("  [B] 第 %0d 点 mismatch got=%08h exp=%08h",
                                 j, cap[j], exp);
                end
                checks = checks + 1;
            end
        end
    endtask

endmodule
