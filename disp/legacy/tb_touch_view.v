//=============================================================================
//  disp/tb_touch_view.v -- touch_view 的字符级自检
//
//  验的不是"跑了没跑"，而是"写进 RAM 的到底是不是对的字符"：
//  把 DUT 的写口逐笔抓下来按 (行,列) 存好，等 done 之后把 9 个字段各自
//  拼回 ASCII 串，与期望字面量逐个 6 字符窗口比对。
//
//  ★ 为什么必须做字符级比对：BCD 拆分、前导零抑制、小数点插入这三件事
//    出错时画面依然"有字"（只是位置或字符错），肉眼很难发现。
//    val_format 的三个真缺陷（小数点字段右移、前导零把个位也削掉、
//    CH_Z 写成 33 变成 'P'）全都是靠这种逐字符比对抓出来的。
//=============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_touch_view;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    reg        start = 1'b0;

    reg [1:0]  tch_type;
    reg [2:0]  tch_num;
    reg [15:0] tch_x0, tch_y0;
    reg [7:0]  tch_status, tch_pid;
    reg [23:0] tch_reads, tch_nack, tch_timeout;

    wire        we;
    wire [8:0]  waddr;
    wire [5:0]  wdata;
    wire        busy, done;

    integer errors = 0;
    integer i, r, c;

    touch_view u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .tch_type(tch_type), .tch_num(tch_num),
        .tch_x0(tch_x0), .tch_y0(tch_y0),
        .tch_status(tch_status), .tch_pid(tch_pid),
        .tch_reads(tch_reads), .tch_nack(tch_nack), .tch_timeout(tch_timeout),
        .we(we), .waddr(waddr), .wdata(wdata), .busy(busy), .done(done)
    );

    always #10 clk = ~clk;          // 50 MHz

    // ---- 抓写口：waddr = {格行[3:0], 格列[4:0]} ----
    reg [5:0] cells [0:9][0:31];
    always @(posedge clk) begin
        if (we) cells[waddr[8:5]][waddr[4:0]] <= wdata;
    end

    // ---- 字库索引 -> ASCII（与 tools/gen_font_rom.py 的 CHARS 一致）----
    function [7:0] idx2a;
        input [5:0] ch;
        begin
            if (ch >= 6'd18)     idx2a = 8'h41 + (ch - 6'd18);   // 'A'..'Z'
            else if (ch >= 6'd8) idx2a = 8'h30 + (ch - 6'd8);    // '0'..'9'
            else case (ch)
                6'd0:    idx2a = 8'h20;   // ' '
                6'd1:    idx2a = 8'h2E;   // '.'
                6'd2:    idx2a = 8'h2D;   // '-'
                6'd3:    idx2a = 8'h2B;   // '+'
                6'd4:    idx2a = 8'h2F;   // '/'
                6'd5:    idx2a = 8'h3A;   // ':'
                6'd6:    idx2a = 8'h3D;   // '='
                default: idx2a = 8'h5E;   // '^'
            endcase
        end
    endfunction

    // 字段基准地址与宽度（必须与 DUT 的字段表逐项一致）
    function [8:0] f_base;
        input [3:0] f;
        begin
            case (f)
                4'd0: f_base = 9'd35;    // row 1, col 3
                4'd1: f_base = 9'd45;    // row 1, col 13
                4'd2: f_base = 9'd55;    // row 1, col 23
                4'd3: f_base = 9'd131;   // row 4, col 3
                4'd4: f_base = 9'd141;   // row 4, col 13
                4'd5: f_base = 9'd151;   // row 4, col 23
                4'd6: f_base = 9'd227;   // row 7, col 3
                4'd7: f_base = 9'd237;   // row 7, col 13
                default: f_base = 9'd247; // row 7, col 23
            endcase
        end
    endfunction

    function [3:0] f_wid;
        input [3:0] f;
        begin
            case (f)
                4'd0: f_wid = 4'd5;    // "ENCC1"
                4'd1: f_wid = 4'd3;    // "V55"
                4'd2: f_wid = 4'd3;    // 型号
                4'd3: f_wid = 4'd6;    // IIC 读次数
                4'd4: f_wid = 4'd6;    // 无应答
                4'd5: f_wid = 4'd6;    // 超时
                4'd6: f_wid = 4'd2;    // LUT %
                4'd7: f_wid = 4'd2;    // BRAM %
                default: f_wid = 4'd2; // DSP %
            endcase
        end
    endfunction

    // 把第 f 个字段拼成 6 字符（不足补空格）的 ASCII
    function [47:0] field_ascii;
        input [3:0] f;
        integer k;
        reg [8:0] base;
        reg [3:0] w;
        begin
            base = f_base(f);
            w    = f_wid(f);
            field_ascii = 48'h202020202020;
            for (k = 0; k < 6; k = k + 1) begin
                if (k < w)
                    field_ascii[(5 - k) * 8 +: 8] = idx2a(cells[base / 32][base % 32 + k]);
            end
        end
    endfunction

    // 打印用：把 6 字符窗口转成可读串（必须声明在 chk 之前）
    function [8*8-1:0] ascii_of;
        input [3:0] f;
        integer k;
        reg [8:0] base;
        reg [3:0] w;
        begin
            base = f_base(f);
            w    = f_wid(f);
            ascii_of = "        ";
            for (k = 0; k < 8; k = k + 1)
                if (k < w) ascii_of[(7 - k) * 8 +: 8] = idx2a(cells[base / 32][base % 32 + k]);
        end
    endfunction

    task chk;
        input [3:0]        f;
        input [47:0]       exp;
        input [8*24-1:0]   label;
        begin
            if (field_ascii(f) !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %0s : got %s  expected %s",
                         label, ascii_of(f), exp);
            end else begin
                $display("[ ok ] %0s : %s", label, ascii_of(f));
            end
        end
    endtask

    task run_one;
        begin
            for (r = 0; r < 10; r = r + 1)
                for (c = 0; c < 32; c = c + 1) cells[r][c] = 6'd0;

            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            i = 0;
            while (!done && i < 5000) begin
                @(posedge clk);
                i = i + 1;
            end
            if (i >= 5000) begin
                errors = errors + 1;
                $display("[FAIL] timeout waiting for done");
            end
            @(posedge clk);
        end
    endtask

    initial begin
        tch_type = 2'd0; tch_num = 3'd0;
        tch_x0 = 16'd0; tch_y0 = 16'd0;
        tch_status = 8'd0; tch_pid = 8'd0;
        tch_reads = 24'd0; tch_nack = 24'd0; tch_timeout = 24'd0;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---------------- 第 1 轮：GT911，有触点 ----------------
        $display("---- round 1 : GT911 with one touch point ----");
        tch_type = 2'd1; tch_num = 3'd5;
        tch_x0 = 16'd600; tch_y0 = 16'd256;
        tch_status = 8'h05; tch_pid = 8'h39;
        tch_reads = 24'd1234; tch_nack = 24'd0; tch_timeout = 24'd0;
        run_one;

        chk(4'd0, "ENCC1 ", "device id");
        chk(4'd1, "V55   ", "firmware ");
        chk(4'd2, "GT9   ", "touch ic ");
        chk(4'd3, "  1234", "iic reads");
        chk(4'd4, "     0", "nack     ");
        chk(4'd5, "     0", "timeout  ");
        chk(4'd6, "70    ", "lut %    ");
        chk(4'd7, "41    ", "bram %   ");
        chk(4'd8, "24    ", "dsp %    ");

        // ---------------- 第 2 轮：FT5206，无触点 + 有失败 ----------------
        $display("---- round 2 : FT5206, no point, with nack/timeout ----");
        tch_type = 2'd2; tch_num = 3'd0;
        tch_x0 = 16'd0; tch_y0 = 16'd0;
        tch_status = 8'h00; tch_pid = 8'h14;
        tch_reads = 24'd999999; tch_nack = 24'd3; tch_timeout = 24'd1;
        run_one;

        chk(4'd0, "ENCC1 ", "device id");
        chk(4'd1, "V55   ", "firmware ");
        chk(4'd2, "FT5   ", "touch ic ");
        chk(4'd3, "999999", "iic reads");
        chk(4'd4, "     3", "nack     ");
        chk(4'd5, "     1", "timeout  ");

        // ---------------- 第 3 轮：未知型号 ----------------
        $display("---- round 3 : unknown controller ----");
        tch_type = 2'd0; tch_num = 3'd0;
        tch_x0 = 16'd1023; tch_y0 = 16'd599;
        tch_status = 8'hff; tch_pid = 8'hff;
        tch_reads = 24'd0; tch_nack = 24'd0; tch_timeout = 24'd0;
        run_one;

        chk(4'd0, "ENCC1 ", "device id");
        chk(4'd2, "---   ", "touch ic ");
        chk(4'd3, "     0", "iic reads");
        chk(4'd6, "70    ", "lut %    ");

        $display("================================================");
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $display("================================================");
        $finish;
    end

endmodule

`default_nettype wire
