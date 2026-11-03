// =============================================================================
//  disp/tb_seg7.v  --  seg7（七段字形）自检
//
//  验证四件事：
//    1. 十个数字的**段掩码**（在每段的中心各取一个像素，拼出 {a,b,c,d,e,f,g}）
//       —— 这钉住 mask 查表，也钉住"段中心确实在段里"。
//    2. 十种数字的**亮像素总数**（20x32 与 48x80 两种字号各一张表）
//       —— 这钉住段矩形的几何：宽度/厚度/腰线错一像素，总数就对不上。
//       ★ 七段**互不重叠**：腰线段 g 的 x 范围是 [T, W-T)，与竖段 f/e 的 [0, T)、
//         b/c 的 [W-T, W) 完全不相交（这正是"段矩形按比例切"的好处）。
//         所以亮像素数 = 点亮的段数 x 段面积（小 48 / 大 256），表里能直接对账。
//
//  两张尺寸表（SMALL = 20x32 段厚 4；BIG = 48x80 段厚 8）：
//      数字 : 0    1    2    3    4    5    6    7    8    9
//      段数 : 6    2    5    5    4    5    6    3    7    6
//      SMALL: 288   96  240  240  192  240  288  144  336  288
//      BIG  :1536  512 1280 1280 1024 1280 1536  768 1792 1536
//    3. 字段外必须全灭（右侧一列 / 下面一行 / 两个角）—— seg7 第一版没有
//       `in_box` 夹取，字段右边那列像素会在 b/c 段的 `dx >= W-T` 区间里点亮。
//    4. blank=1 时十个数字都必须全灭（前导零不画）。
//
//  两张尺寸表（SMALL = 20x32 段厚 4；BIG = 48x80 段厚 8）：
//      数字 : 0    1    2    3    4    5    6    7    8    9
//      SMALL: 288   96  224  224  176  224  272  144  304  272
//      BIG  :1536  512 1216 1216  960 1216 1472  768 1664 1472
// =============================================================================
`timescale 1ns / 1ps

module tb_seg7;

    reg  [11:0] cx = 12'd0, cy = 12'd0;
    reg  [3:0]  d  = 4'd0;
    reg         blank = 1'b0;
    wire        on_s, on_b;

    seg7 #(.X0(12'd0),  .Y0(12'd0), .BIG(1'b0)) u_s (
        .cx(cx), .cy(cy), .d(d), .blank(blank), .on(on_s));
    seg7 #(.X0(12'd64), .Y0(12'd0), .BIG(1'b1)) u_b (
        .cx(cx), .cy(cy), .d(d), .blank(blank), .on(on_b));

    integer errs = 0;
    integer i;
    integer n;
    reg [6:0] obs_s, obs_b;

    function [6:0] exp_mask;
        input [3:0] k;
        begin
            case (k)
                4'd0: exp_mask = 7'b1111110;
                4'd1: exp_mask = 7'b0110000;
                4'd2: exp_mask = 7'b1101101;
                4'd3: exp_mask = 7'b1111001;
                4'd4: exp_mask = 7'b0110011;
                4'd5: exp_mask = 7'b1011011;
                4'd6: exp_mask = 7'b1011111;
                4'd7: exp_mask = 7'b1110000;
                4'd8: exp_mask = 7'b1111111;
                4'd9: exp_mask = 7'b1111011;
                default: exp_mask = 7'b0000000;
            endcase
        end
    endfunction

    function integer exp_cnt;
        input [3:0] k;
        input       big;
        integer     v;
        begin
            case (k)
                4'd0: v = 288;   4'd1: v = 96;    4'd2: v = 240;
                4'd3: v = 240;   4'd4: v = 192;   4'd5: v = 240;
                4'd6: v = 288;   4'd7: v = 144;   4'd8: v = 336;
                4'd9: v = 288;
                default: v = 0;
            endcase
            // 大字段：每段面积都是 256（= 32 x 8），七段互不重叠
            if (big) begin
                case (k)
                    4'd0: v = 1536;  4'd1: v = 512;   4'd2: v = 1280;
                    4'd3: v = 1280;  4'd4: v = 1024;  4'd5: v = 1280;
                    4'd6: v = 1536;  4'd7: v = 768;   4'd8: v = 1792;
                    4'd9: v = 1536;
                    default: v = 0;
                endcase
            end
            exp_cnt = v;
        end
    endfunction

    // 七个段中心（相对字段左上角）-> 拼出段掩码。位序 {a,b,c,d,e,f,g}
    task sample_masks;
        begin
            obs_s = 7'd0;
            obs_b = 7'd0;
            // a
            cx = 12'd9;  cy = 12'd1;  #1; if (on_s) obs_s[6] = 1'b1;
            cx = 12'd88; cy = 12'd3;  #1; if (on_b) obs_b[6] = 1'b1;
            // b
            cx = 12'd17; cy = 12'd9;  #1; if (on_s) obs_s[5] = 1'b1;
            cx = 12'd108; cy = 12'd20; #1; if (on_b) obs_b[5] = 1'b1;
            // c
            cx = 12'd17; cy = 12'd21; #1; if (on_s) obs_s[4] = 1'b1;
            cx = 12'd108; cy = 12'd56; #1; if (on_b) obs_b[4] = 1'b1;
            // d
            cx = 12'd9;  cy = 12'd30; #1; if (on_s) obs_s[3] = 1'b1;
            cx = 12'd88; cy = 12'd76; #1; if (on_b) obs_b[3] = 1'b1;
            // e
            cx = 12'd1;  cy = 12'd21; #1; if (on_s) obs_s[2] = 1'b1;
            cx = 12'd67; cy = 12'd56; #1; if (on_b) obs_b[2] = 1'b1;
            // f
            cx = 12'd1;  cy = 12'd9;  #1; if (on_s) obs_s[1] = 1'b1;
            cx = 12'd67; cy = 12'd20; #1; if (on_b) obs_b[1] = 1'b1;
            // g
            cx = 12'd9;  cy = 12'd15; #1; if (on_s) obs_s[0] = 1'b1;
            cx = 12'd88; cy = 12'd40; #1; if (on_b) obs_b[0] = 1'b1;
        end
    endtask

    integer sx, sy, cnt_s, cnt_b;

    task scan_counts;
        begin
            cnt_s = 0;
            cnt_b = 0;
            for (sy = -1; sy <= 33; sy = sy + 1) begin
                for (sx = -1; sx <= 20; sx = sx + 1) begin
                    cx = sx[11:0]; cy = sy[11:0]; #1;
                    if (on_s === 1'b1) cnt_s = cnt_s + 1;
                    if (on_b === 1'b1) cnt_b = cnt_b + 1;
                end
            end
            for (sy = -1; sy <= 81; sy = sy + 1) begin
                for (sx = 63; sx <= 112; sx = sx + 1) begin
                    cx = sx[11:0]; cy = sy[11:0]; #1;
                    if (on_b === 1'b1) cnt_b = cnt_b + 1;
                end
            end
        end
    endtask

    task chk_off;
        input [11:0] x, y;
        input [8*28-1:0] tag;
        begin
            cx = x; cy = y; #1;
            if (on_s !== 1'b0) begin
                errs = errs + 1;
                $display("[FAIL] 小字段外亮起 %0s @ (%0d,%0d)", tag, x, y);
            end
            if (on_b !== 1'b0) begin
                errs = errs + 1;
                $display("[FAIL] 大字段外亮起 %0s @ (%0d,%0d)", tag, x, y);
            end
        end
    endtask

    initial begin
        $display("==== tb_seg7 ====");

        // ---- 1/2. 十个数字：段掩码 + 亮像素总数（两种字号）----
        blank = 1'b0;
        for (i = 0; i <= 9; i = i + 1) begin
            d = i[3:0];
            sample_masks;
            scan_counts;
            if (obs_s !== exp_mask(i[3:0])) begin
                errs = errs + 1;
                $display("[FAIL] 小字段 数字 %0d 段掩码 = %b, 期望 %b", i, obs_s, exp_mask(i[3:0]));
            end
            if (obs_b !== exp_mask(i[3:0])) begin
                errs = errs + 1;
                $display("[FAIL] 大字段 数字 %0d 段掩码 = %b, 期望 %b", i, obs_b, exp_mask(i[3:0]));
            end
            if (cnt_s !== exp_cnt(i[3:0], 1'b0)) begin
                errs = errs + 1;
                $display("[FAIL] 小字段 数字 %0d 亮像素 = %0d, 期望 %0d",
                         i, cnt_s, exp_cnt(i[3:0], 1'b0));
            end
            if (cnt_b !== exp_cnt(i[3:0], 1'b1)) begin
                errs = errs + 1;
                $display("[FAIL] 大字段 数字 %0d 亮像素 = %0d, 期望 %0d",
                         i, cnt_b, exp_cnt(i[3:0], 1'b1));
            end
            if ((obs_s === exp_mask(i[3:0])) && (obs_b === exp_mask(i[3:0])) &&
                (cnt_s === exp_cnt(i[3:0], 1'b0)) && (cnt_b === exp_cnt(i[3:0], 1'b1))) begin
                $display("[ OK ] 数字 %0d 段掩码 %b，亮像素 小 %0d / 大 %0d",
                         i, obs_s, cnt_s, cnt_b);
            end
        end

        // ---- 3. 字段外必须全灭（含"贴着字段外一列/一行"与两个角）----
        d = 4'd8;
        i = errs;
        chk_off(12'd20, 12'd10, "小-右侧一列");
        chk_off(12'd10, 12'd32, "小-下面一行");
        chk_off(12'd20, 12'd32, "小-右下角外");
        chk_off(12'd112, 12'd20, "大-右侧一列");
        chk_off(12'd88,  12'd80, "大-下面一行");
        chk_off(12'd112, 12'd80, "大-右下角外");
        chk_off(12'd19,  12'd31, "小-字段内右下角（本就不该有段）");
        chk_off(12'd111, 12'd79, "大-字段内右下角（本就不该有段）");
        if (errs == i) $display("[ OK ] 字段外与两个内角全灭（8 个点）");

        // ---- 大字段**左上**两侧也要挡（dx/dy 钳 0 的老坑，见 disp/seg7.v）----
        i = errs;
        chk_off(12'd63, 12'd10, "大-左侧一列");
        chk_off(12'd70, 12'd0,  "大-上面一行");
        if (errs == i) $display("[ OK ] 大字段左上两侧全灭（2 个点）");

        // ---- 4. blank=1：十个数字全灭（前导零不画）----
        blank = 1'b1;
        for (i = 0; i <= 9; i = i + 1) begin
            d = i[3:0];
            sample_masks;
            if ((obs_s !== 7'd0) || (obs_b !== 7'd0)) begin
                errs = errs + 1;
                $display("[FAIL] blank=1 时数字 %0d 还有段亮（小 %b / 大 %b)", i, obs_s, obs_b);
            end
        end
        // 超出 0..9 的编码也必须全灭
        d = 4'd15;
        sample_masks;
        if ((obs_s !== 7'd0) || (obs_b !== 7'd0)) begin
            errs = errs + 1;
            $display("[FAIL] 数字码 15 还有段亮（小 %b / 大 %b）", obs_s, obs_b);
        end
        $display("[ OK ] blank=1 与越界数字码（0..9 之外）全灭");
        blank = 1'b0;

        if (errs == 0) $display("TEST PASSED: 0 errors");
        else           $display("TEST FAILED: %0d errors", errs);
        $finish;
    end

endmodule
