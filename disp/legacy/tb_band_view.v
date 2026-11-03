//=============================================================================
// disp/tb_band_view.v -- P8 底栏三个小数字的逐格自检
//-----------------------------------------------------------------------------
// 这个 tb 做的是**端到端**检查，而不是只看 band_view 的输出引脚：
//   band_view 的写口直接接到真的 `p8_lab_ram`（disp/text_ram.v 里带 initial
//   静态版面的那块），然后按格行 36 逐列回读。
// 于是它同时验证了两件事：
//   (1) tools/gen_text_ram.py 里 P8_LAB 底栏的**标签/斜杠落在 band_view 期望的列**；
//   (2) band_view 把数值填进了那些空列，且**没有踩到标签**。
// 这正是这条需求最容易出错的地方 —— 两边分别看都对，合起来错位一格。
//
// 判据：
//   [1] 值列内容逐字符正确（含前导零抑制：最小一位必须显示）
//   [2] 标签列仍是汉字码（>= 44），即没被数值覆盖
//   [3] 两个 '/' 分隔符位置不变（列 8、15）
//   [4] 整轮写操作**只落在** row36 的 6/13/22/23/24 这 5 个格子上
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_band_view;

    reg clk = 1'b0;
    always #10 clk = ~clk;          // 50 MHz

    integer errors = 0;

    reg         rst_n   = 1'b0;
    reg         start   = 1'b0;
    reg         int_pin = 1'b0;
    reg         toggle  = 1'b0;
    reg  [3:0]  rst_cnt = 4'd0;

    wire        we;
    wire [11:0] waddr;
    wire [7:0]  wdata;
    wire        busy, done;

    band_view u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .int_pin(int_pin), .toggle(toggle), .rst_cnt(rst_cnt),
        .we(we), .waddr(waddr), .wdata(wdata), .busy(busy), .done(done)
    );

    // 真文字平面，写口接 band_view，读口用于逐格回读
    reg  [11:0] raddr = 12'd0;
    wire [7:0]  rdata;

    p8_lab_ram u_ram (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata)
    );

    localparam [11:0] ROW36 = 12'd36 * 12'd64;

    // ---- 写操作审计：本轮写了哪些格子 ----
    reg [63:0] touched;             // 位图，只关心 row36 的列
    reg        stray;

    always @(posedge clk) begin
        if (we) begin
            if (waddr[11:6] == 6'd36) touched[waddr[5:0]] <= 1'b1;
            else                      stray <= 1'b1;
        end
    end

    // ---- 字符码 -> ASCII（>= 48 是汉字，映射成 '#' 便于整行打印）----
    //   ★ 参数必须是 8 bit：v23 起 ASCII 段有 44..47（% × ÷ ↩），v24 起更有
    //     '↩'；汉字码是 48..136，用 7 bit 接参会被截掉高位（135 变成 7），
    //     于是汉字标签全都印成空格 —— 这纯粹是打印用，不影响任何判据。
    function [7:0] aa(input [7:0] c);
        begin
            if (c >= 8'd48)                       aa = "#";
            else if (c == 8'd44)                  aa = "%";
            else if (c == 8'd45)                  aa = "*";   // '×'
            else if (c == 8'd46)                  aa = "d";   // '÷'
            else if (c == 8'd47)                  aa = "<";   // '↩'
            else if (c == 7'd4)                   aa = "/";
            else if (c >= 7'd8 && c <= 7'd17)     aa = "0" + (c - 7'd8);
            else if (c >= 7'd18 && c <= 7'd43)    aa = "A" + (c - 7'd18);
            else                                  aa = " ";
        end
    endfunction

    reg [63:0] rowbits;
    reg [7:0]  raw [0:63];

    task read_row36;
        integer c;
        begin
            rowbits = 64'd0;
            for (c = 0; c <= 63; c = c + 1) begin
                raddr = ROW36 + c[11:0];
                @(posedge clk);
                #1;
                raw[c] = aa(rdata);
                if (rdata >= 7'd44) rowbits[c] = 1'b1;   // 记录"这一列是汉字"
            end
        end
    endtask

    task dump_row36;
        integer c;
        begin
            $write("      row36: |");
            for (c = 0; c <= 30; c = c + 1) $write("%s", raw[c]);
            $write("|\n");
        end
    endtask

    // 检查某一列等于期望 ASCII
    task chk_col(input [5:0] col, input [7:0] exp, input [255:0] label);
        begin
            if (raw[col] !== exp) begin
                $display("[FAIL] %0s: col %0d = '%s', expected '%s'",
                         label, col, raw[col], exp);
                errors = errors + 1;
            end else begin
                $display("[ok]   %0s: col %0d = '%s'", label, col, raw[col]);
            end
        end
    endtask

    // 检查某一列仍是汉字（标签没被踩掉）
    task chk_cjk(input [5:0] col, input [255:0] label);
        begin
            if (rowbits[col] !== 1'b1) begin
                $display("[FAIL] %0s: col %0d lost its CJK label (now '%s')",
                         label, col, raw[col]);
                errors = errors + 1;
            end
        end
    endtask

    task run_once(input ip, input tg, input [3:0] rc, input [255:0] label);
        begin
            // 本轮审计清零
            touched = 64'd0;
            stray   = 1'b0;

            int_pin = ip;
            toggle  = tg;
            rst_cnt = rc;

            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            // 等 done（正常 10 拍左右，给足余量）
            fork : wait_done
                begin
                    wait (done === 1'b1);
                    disable wait_done;
                end
                begin
                    #20000;
                    $display("[FAIL] %0s: timeout waiting for done", label);
                    errors = errors + 1;
                    disable wait_done;
                end
            join

            @(posedge clk);
            read_row36;
            dump_row36;

            $display("--- %0s : int=%0d toggle=%0d rst_cnt=%0d ---", label, ip, tg, rc);
            $display("      touched cols=%b  stray=%0d", touched[31:0], stray);
        end
    endtask

    initial begin
        touched = 64'd0;
        stray   = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---------- 轮 1：全 0（最小一位必须显示，不能变空白）----------
        run_once(1'b0, 1'b0, 4'd0, "r1 all-zero");
        chk_col(6'd11, "0", "r1 int level");
        chk_col(6'd18, "0", "r1 toggle");
        chk_col(6'd27, " ", "r1 rst_cnt hundreds");
        chk_col(6'd28, " ", "r1 rst_cnt tens");
        chk_col(6'd29, "0", "r1 rst_cnt ones");
        chk_cjk(6'd6, "r1 label 6"); chk_cjk(6'd9, "r1 label 9");
        chk_cjk(6'd15, "r1 label 15"); chk_cjk(6'd25, "r1 label 25");
        chk_col(6'd13, "/", "r1 sep 1");
        chk_col(6'd20, "/", "r1 sep 2");
        if (touched[31:0] !== 32'b0011_1000_0000_0100_0000_1000_0000_0000) begin
            $display("[FAIL] r1 touched bitmap = %b, expected only cols 11/18/27/28/29",
                     touched[31:0]);
            errors = errors + 1;
        end
        if (stray) begin
            $display("[FAIL] r1 wrote outside row 36"); errors = errors + 1; end

        // ---------- 轮 2：12（十位要出现，百位仍是空格）----------
        run_once(1'b1, 1'b1, 4'd12, "r2 1/1/12");
        chk_col(6'd11, "1", "r2 int level");
        chk_col(6'd18, "1", "r2 toggle");
        chk_col(6'd27, " ", "r2 hundreds");
        chk_col(6'd28, "1", "r2 tens");
        chk_col(6'd29, "2", "r2 ones");
        chk_cjk(6'd22, "r2 label 22");

        // ---------- 轮 3：15（个位是减出来的）----------
        run_once(1'b0, 1'b0, 4'd15, "r3 0/0/15");
        chk_col(6'd28, "1", "r3 tens");
        chk_col(6'd29, "5", "r3 ones");

        // ---------- 轮 4：9（一位数，左边两列都该是空格）----------
        run_once(1'b1, 1'b0, 4'd9, "r4 1/0/9");
        chk_col(6'd11, "1", "r4 int level");
        chk_col(6'd18, "0", "r4 toggle");
        chk_col(6'd27, " ", "r4 hundreds");
        chk_col(6'd28, " ", "r4 tens");
        chk_col(6'd29, "9", "r4 ones");

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("TEST FAILED: global timeout");
        $finish;
    end

endmodule

`default_nettype wire
