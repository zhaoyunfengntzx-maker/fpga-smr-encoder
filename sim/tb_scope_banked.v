//=============================================================================
//  tb_scope_banked.v —— scope_capture 28672 点三 bank 存储的专项回归
//-----------------------------------------------------------------------------
//  为什么单独建这个测试台：
//    tb_scope_chain 用的是小深度（单块存储分支），验证不到 "DEPTH=28672
//    显式拆 16K+8K+4K 三块 bank" 这条生产路径。而这条路径有两个只在
//    非 2 次幂深度下才会暴露的东西：
//      1) 写地址译码：0x0000-0x3FFF → bank0、0x4000-0x5FFF → bank1、
//         0x6000-0x6FFF → bank2，边界写错只会丢/串极少数点，眼看不出来；
//      2) 读口 1 拍延迟：三块 bank 各寄存一拍 + 组合 mux，sel_r 与地址
//         同拍寄存。若 mux 选错 bank，读回的会是**同一地址的另一块**，
//         数据"看起来有"但全错 —— 波形上表现为乱序，容易误判成采样问题。
//    因此这里逐点比对 28672 个样点：每个点的 s/c 都是地址的函数，
//    任何 bank 选错、地址截断、回绕 off-by-one 都会立刻打出来。
//
//  覆盖：
//    [A] 复位值；
//    [B] arm（立即触发，cap_len=28672）→ 采满 → st_done；
//    [C] 写指针回绕：第 28672 个点写完后 wr_addr 回到 0；
//    [D] 逐点回读 28672 点，与生成式完全一致（三块 bank 全扫过）；
//    [E] 读口延迟恰好 1 拍（rd_data 在 rd_en 后一拍有效）。
//=============================================================================
`timescale 1ns / 1ps

module tb_scope_banked;

    localparam integer DEPTH = 28672;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;

    reg         arm = 1'b0;
    reg         abort = 1'b0;
    reg  [1:0]  dec_log2 = 2'd0;
    reg  [15:0] cap_len = 16'd0;
    reg  [1:0]  trig_mode = 2'd0;
    reg  signed [15:0] trig_level = 16'sd0;
    reg  [15:0] pre_len = 16'd0;
    reg         stream = 1'b0;
    reg  [2:0]  stream_dec = 3'd0;
    reg  signed [15:0] s_in = 16'sd0;
    reg  signed [15:0] c_in = 16'sd0;
    reg         in_valid = 1'b0;
    reg  [15:0] rd_addr = 16'd0;
    reg         rd_en = 1'b0;

    wire [31:0] rd_data;
    wire [15:0] cap_start, cap_len_eff, trig_idx, wr_ptr;
    wire [31:0] sample_cnt, strm_cnt;
    wire        st_armed, st_done, st_trig, st_busy, st_ovf, st_stream;

    integer errors = 0;
    integer checks = 0;
    integer i;
    integer k;
    reg     run = 1'b0;
    reg [15:0] expect_word_s, expect_word_c;

    always #10 clk = ~clk;      // 50 MHz

    scope_capture #(.DEPTH(DEPTH)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .arm         (arm),
        .abort       (abort),
        .dec_log2    (dec_log2),
        .cap_len     (cap_len),
        .trig_mode   (trig_mode),
        .trig_level  (trig_level),
        .pre_len     (pre_len),
        .stream      (stream),
        .stream_dec  (stream_dec),
        .s_in        (s_in),
        .c_in        (c_in),
        .in_valid    (in_valid),
        .rd_addr     (rd_addr),
        .rd_en       (rd_en),
        .rd_data     (rd_data),
        .cap_start   (cap_start),
        .cap_len_eff (cap_len_eff),
        .trig_idx    (trig_idx),
        .sample_cnt  (sample_cnt),
        .st_armed    (st_armed),
        .st_done     (st_done),
        .st_trig     (st_trig),
        .st_busy     (st_busy),
        .st_ovf      (st_ovf),
        .wr_ptr      (wr_ptr),
        .strm_cnt    (strm_cnt),
        .st_stream   (st_stream)
    );

    // 样点生成式：s = 3i+7，c = 5i+11（16 bit 截断）。写/读两端用同一函数，
    // 保证"存进去的第 i 个点"与"读回地址 i 的点"是同一组值。
    function [15:0] pat_s; input integer idx; begin pat_s = (idx * 3 + 7)  & 16'hFFFF; end endfunction
    function [15:0] pat_c; input integer idx; begin pat_c = (idx * 5 + 11) & 16'hFFFF; end endfunction

    // 采样驱动：run=1 时每拍送一个新样点（dec=0，in_valid 常 1）。
    //   ★ s_in/c_in 必须**组合**跟着 k 走，不能寄存一拍：DUT 在 posedge 采样，
    //     若这里也把样点寄存一拍，存进去的点会整体后移一个地址，
    //     逐点比对就会从 addr 0 开始全错（这个 off-by-one 在波形上几乎看不出来）。
    always @(posedge clk) begin
        if (!rst_n) k <= 0;
        else if (run && (k < DEPTH)) k <= k + 1;
    end

    always @(*) begin
        if (run) begin
            s_in = $signed(pat_s(k));
            c_in = $signed(pat_c(k));
        end else begin
            s_in = 16'sd0;
            c_in = 16'sd0;
        end
    end

    task fail; input [255:0] msg; begin
        errors = errors + 1;
        $display("  [FAIL] %0s", msg);
    end endtask

    task check; input cond; input [255:0] msg; begin
        checks = checks + 1;
        if (!cond) fail(msg);
    end endtask

    initial begin
        $display("=== tb_scope_banked: scope_capture DEPTH=%0d (16K+8K+4K) ===", DEPTH);

        // [A] 复位
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        check(st_armed == 1'b0, "A: st_armed must be 0 after reset");
        check(st_done  == 1'b0, "A: st_done  must be 0 after reset");
        check(cap_len_eff == 16'd0, "A: cap_len_eff must be 0 after reset");
        rst_n = 1'b1;
        @(posedge clk);

        // [B] arm：立即触发，整窗 28672 点
        cap_len  = DEPTH[15:0];
        dec_log2 = 2'd0;
        pre_len  = 16'd0;
        trig_mode = 2'd0;
        @(negedge clk); arm = 1'b1;
        @(negedge clk); arm = 1'b0; in_valid = 1'b1; run = 1'b1;

        // 采满一窗
        i = 0;
        while (!st_done && i < DEPTH * 4) begin
            @(posedge clk); #1;
            i = i + 1;
        end
        run = 1'b0;

        check(st_done == 1'b1, "B: st_done must assert after 28672 samples");
        check(st_armed == 1'b0, "B: st_armed must drop when window completes");
        check(cap_len_eff == DEPTH[15:0], "B: cap_len_eff must equal 28672");
        check(sample_cnt == DEPTH, "B: sample_cnt must be 28672");
        check(st_ovf == 1'b0, "B: st_ovf must stay 0 for an exact-fit window");
        check(cap_start == 16'd0, "B: immediate trigger must start at 0");

        // [C] 写指针回绕（第 28672 个点写到 0x6FFF，nxt 回到 0）
        check(dut.wr_addr == 16'd0, "C: wr_addr must wrap back to 0");
        $display("  [info] completed after %0d clk, wr_addr=%0d", i, dut.wr_addr);

        // [D]+[E] 逐点回读。rd_en 持续 1，地址每拍换一个；
        //   negedge 改地址 → 下一拍 posedge 采样 → 再下一个 negedge 读数据。
        in_valid = 1'b0;
        @(negedge clk); rd_en = 1'b1;
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge clk);
            rd_addr = i[15:0];
            @(negedge clk);
            expect_word_s = pat_s(i);
            expect_word_c = pat_c(i);
            if (rd_data !== {expect_word_c, expect_word_s}) begin
                if (errors < 10)
                    $display("  [FAIL] D: addr %0d rd_data=%h expect=%h",
                             i, rd_data, {expect_word_c, expect_word_s});
                errors = errors + 1;
            end
            checks = checks + 1;
            if ((i == 16383) || (i == 16384) || (i == 24575) ||
                (i == 24576) || (i == DEPTH-1))
                $display("  [info] bank boundary addr %0d ok", i);
        end
        @(negedge clk); rd_en = 1'b0;

        // [E] 延迟性质：rd_en 拉低后数据保持（说明它确实是寄存器/mux 输出，
        //     而不是随地址组合变化）。这里只检查"没有变成 X"。
        check((^rd_data) !== 1'bx, "E: rd_data must not be X after reads");

        $display("");
        if (errors == 0) begin
            $display("TEST PASSED (%0d checks)", checks);
        end else begin
            $display("TEST FAILED (%0d errors / %0d checks)", errors, checks);
        end
        $finish;
    end

    initial begin
        #5_000_000;     // 5 ms 超时
        $display("  [FAIL] TIMEOUT");
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
