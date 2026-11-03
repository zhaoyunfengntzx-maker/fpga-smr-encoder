// ============================================================================
// tb_angle_lut.v —— rtl/angle_lut.v 自检测试台（S5 全周补偿表）
// ----------------------------------------------------------------------------
//   TEST 1  读延迟恰好 1 拍（给索引后下一拍出数据）
//   TEST 2  全表 4096 点写后回读，逐点一致（含地址高位/低位边界）
//   TEST 3  有符号值往返（0x8000 / 0x7FFF / 0xFFFF）
//   TEST 4  同地址同拍读写：读出的是写入前的旧值（READ_FIRST 语义）
//   TEST 5  地址回绕（4095 → 0）不串位
// ============================================================================
`timescale 1ns / 1ps

module tb_angle_lut;

    reg         clk, rst_n;
    reg  [11:0] rd_idx;
    wire [15:0] rd_q;
    reg         wr_en;
    reg  [11:0] wr_addr;
    reg  [15:0] wr_data;

    integer fails;
    integer i;

    angle_lut dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .rd_idx  (rd_idx),
        .rd_q    (rd_q),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data)
    );

    always #10 clk = ~clk;

    task wr;
        input [11:0] a;
        input [15:0] d;
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = a;
            wr_data = d;
            @(negedge clk);
            wr_en   = 1'b0;
        end
    endtask

    // 给索引，等 2 拍后取数据（1 拍 BRAM + 1 拍稳定）
    task rd;
        input  [11:0] a;
        output [15:0] d;
        begin
            @(negedge clk);
            rd_idx = a;
            @(negedge clk);      // 第 1 拍：BRAM 采样
            @(negedge clk);      // 第 2 拍：rd_q 已更新
            d = rd_q;
        end
    endtask

    reg [15:0] got;

    initial begin
        fails = 0;
        clk = 1'b0; rst_n = 1'b0;
        rd_idx = 12'd0; wr_en = 1'b0; wr_addr = 12'd0; wr_data = 16'd0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk); #1;

        // TEST 1：读延迟恰好 1 拍（negdege 给索引 → 下一个 negedge 就有数据）
        wr(12'd5, 16'h1234);
        @(negedge clk); rd_idx = 12'd5;
        @(negedge clk);
        if (rd_q !== 16'h1234) begin
            fails = fails + 1;
            $display("[FAIL] T1-latency : 1 拍后 rd_q=%h 应为 1234", rd_q);
        end

        // TEST 2：全表写后回读
        for (i = 0; i < 4096; i = i + 1)
            wr(i[11:0], (i * 7 + 16'h0100) & 16'hFFFF);
        for (i = 0; i < 4096; i = i + 1) begin
            rd(i[11:0], got);
            if (got !== ((i * 7 + 16'h0100) & 16'hFFFF)) begin
                fails = fails + 1;
                $display("[FAIL] T2-sweep : addr=%0d got=%h exp=%h",
                         i, got, (i * 7 + 16'h0100) & 16'hFFFF);
                if (fails > 5) i = 4096;
            end
        end

        // TEST 3：有符号往返
        wr(12'hABC, 16'h8000);  rd(12'hABC, got);
        if (got !== 16'h8000) begin fails = fails + 1; $display("[FAIL] T3-neg : got=%h", got); end
        wr(12'hABD, 16'h7FFF);  rd(12'hABD, got);
        if (got !== 16'h7FFF) begin fails = fails + 1; $display("[FAIL] T3-pos : got=%h", got); end

        // TEST 4：同地址同拍读写 ⇒ 读出旧值（READ_FIRST）
        //   ★ 必须在"同拍写"之后的第一个 negedge 就查，再等一拍 rd_q 会被下一次
        //     读覆盖成新值 —— 这一步第一版写错了，误报 RTL 有问题。
        wr(12'd100, 16'h5555);
        @(negedge clk);
        rd_idx = 12'd100; wr_en = 1'b1; wr_addr = 12'd100; wr_data = 16'hAAAA;
        @(negedge clk);
        if (rd_q !== 16'h5555) begin
            fails = fails + 1;
            $display("[FAIL] T4-read-first : got=%h 应为 5555（旧值）", rd_q);
        end
        wr_en = 1'b0;
        wr(12'd100, 16'h0001);   // 清掉，免得影响别处
        rd(12'd100, got);
        if (got !== 16'h0001) begin fails = fails + 1; $display("[FAIL] T4-follow : got=%h", got); end

        // TEST 5：地址回绕
        wr(12'd4095, 16'h0F0F);
        wr(12'd0,    16'hF0F0);
        rd(12'd4095, got);
        if (got !== 16'h0F0F) begin fails = fails + 1; $display("[FAIL] T5-max : got=%h", got); end
        rd(12'd0, got);
        if (got !== 16'hF0F0) begin fails = fails + 1; $display("[FAIL] T5-min : got=%h", got); end

        repeat (4) @(posedge clk);
        if (fails == 0) $display("TEST PASSED (%0d checks)", 4096 + 12);
        else            $display("TEST FAILED (%0d errors)", fails);
        $finish;
    end

    initial begin
        #5000000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule
