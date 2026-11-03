//=============================================================================
//  disp/tb_p6_view.v -- 验 disp/p6_view.v：P6 设置页的 **15 个字段**是否画成了
//                      **寄存器当前值**
//
//  为什么不能只看 p6_view 的写口：
//    写口写的东西对不对，只有从**真正那块 p6_val_ram** 里读回来才算数
//    （RAM 是 `if (we) mem[waddr] <= wdata`，地址拼接错一位就把字符写进隔壁格）。
//    所以本测试台例化的是 `disp/text_ram.v` 里那块 `p6_val_ram`，
//    每一轮都逐格回读第 1 / 2 / 3 / 4 / 5 格行的字段矩形，再和期望字符串比。
//
//  v19 起是 3 列 x 4 行 = 12 项（spec 4.4 的"3x4 网格"）；**v41（㊳）补第 5 行
//  成 3 列 x 5 行 = 15 项**（spec 4.4 的"项高 88"照字面铺满 y 64..503，见
//  tools/gen_text_ram.py 的 P6 段与 disp/disp_engine.v 的 P6 虚拟格网）：
//     第 4 行三项（ABZ 使能 / UVW 使能 / 粗调移位）**不进 BCD**，
//     走逐格查表的枚举串（"ON "/"OFF" 和 "S<ss>C<cc>"）；
//     第 5 行三项（增益S / 增益C / 相位修正）是 **Q1.15 定点数**，
//     走 32 拍 double-dabble 出千分数（"d.ddd" / "+d.ddd"）—— 新种类 K_Q15。
//  三层判据：
//    ① 字段内容：15 个字段逐个回读，含"倍频 0→256 / 分频编码 +1 / 极对数 0→32"
//       三个显示口径，前导零抑制（inter=1 要写成 "*  1" 而不是 "*001"；
//       ★ v24：前缀乘号/除号从 ASCII 'X' '/'（码 41 / 4）换成真正的 '×' '÷'
//       （码 45 / 46，见 disp/p6_view.v），期望串里用 '*' / 'd' 当替身打印），
//       两个枚举字段的 ON/OFF 两个分支，以及 **Q1.15 的三条口径**：
//       千分数 = m*125>>12、小数三位**不做前导零抑制**（0.005 要写出两个 0）、
//       有符号字段（相位修正）带 '+'/'-' 且负数先取补再算幅值。
//    ② 写口覆盖面：15 个字段矩形的并集**恰好**是写过的格子（512 项位图覆盖
//       整块 32x10 数值层）。任何落在矩形外的写都置 stray。
//    ③ 握手：busy 在跑的时候为 1，done 每轮只脉冲一次。
//
//  期望值从哪来：`rtl/reg_file.v:255-278` 的复位默认值（inter=0/div=0/pairs=4/
//    hyst=0/ablimit=0/zwidth=4/zphase=0/uvwph=0/pol=0）与 `rtl/abz_gen.v:154`
//    （`INTER_MAX = 10'd256`，inter==0 的等价值）。使能/移位没有"复位默认"的
//    屏上契约（它们是抽头直读、不在 0x0101 那条链上），所以本台的 4 轮把它们
//    当普通输入扫一遍两个分支 —— 这里验的是**格式化**，不是寄存器默认值。
//    ★ v41 的三个 Q1.15 同理：本台验的是"给定 raw 该怎么显示"。取值刻意覆盖
//      0 / 1 千分位以下（0.005）/ 满量程（1.999）/ ±0.999 / -1.000 / 有符号零。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_p6_view;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    reg start = 1'b0;

    reg [9:0]  cfg_inter   = 10'd0;
    reg [2:0]  cfg_div     = 3'd0;
    reg [4:0]  cfg_pairs   = 5'd0;
    reg [4:0]  cfg_hyst_ab = 5'd0;
    reg [7:0]  cfg_ablimit = 8'd0;
    reg [3:0]  cfg_zwidth  = 4'd0;
    reg [11:0] cfg_zphase  = 12'd0;
    reg [15:0] cfg_uvwph   = 16'd0;
    reg [3:0]  cfg_pol     = 4'b0000;
    // v19 第 4 行三项：使能位与粗调移位（disp/disp_engine.v 的 tap_abzen /
    //   tap_uwven / tap_shift，直读抽头，不经 0x0101 那条写链）
    reg        cfg_abzen   = 1'b0;
    reg        cfg_uwven   = 1'b0;
    reg [3:0]  cfg_shift   = 4'd0;
    // v41（㊳）第 5 行三项：Q1.15 定点数（disp/disp_engine.v 的 tap_gain_s /
    //   tap_gain_c 无符号、tap_phase_k 有符号，都从 disp_tap 回读）
    reg [15:0] cfg_gain_s  = 16'd0;
    reg [15:0] cfg_gain_c  = 16'd0;
    reg [15:0] cfg_phase_k = 16'd0;

    wire        we;
    wire [8:0]  waddr;
    wire [5:0]  wdata;
    wire        busy, done;

    p6_view u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .cfg_inter(cfg_inter), .cfg_div(cfg_div), .cfg_pairs(cfg_pairs),
        .cfg_hyst_ab(cfg_hyst_ab), .cfg_ablimit(cfg_ablimit),
        .cfg_zwidth(cfg_zwidth), .cfg_zphase(cfg_zphase),
        .cfg_uvwph(cfg_uvwph), .cfg_pol(cfg_pol),
        .cfg_abzen(cfg_abzen), .cfg_uwven(cfg_uwven), .cfg_shift(cfg_shift),
        .cfg_gain_s(cfg_gain_s), .cfg_gain_c(cfg_gain_c), .cfg_phase_k(cfg_phase_k),
        .we(we), .waddr(waddr), .wdata(wdata),
        .busy(busy), .done(done)
    );

    // ---- 真正那块数值层 RAM（32 x 10 格，9 bit 地址 = {格行[3:0], 格列[4:0]}）----
    reg  [8:0] raddr = 9'd0;
    wire [5:0] rdata;

    p6_val_ram u_ram (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata)
    );

    integer errors = 0;

    // ---------------------------------------------------------------- 字符码 -> ASCII
    //   字符码不是 ASCII，是字库索引：字符集 " .-+/:=^0123456789A-Z%×÷↩"（48 个）
    //   ★ v24：'×' = 45、'÷' = 46 用 '*' / 'd' 当**替身**打印 —— Verilog 字符串
    //     字面量里的多字节字符会按 UTF-8 拆成好几个字节，期望串就再也比不上了
    //     （㉓ 在 tb_val_format.v 上栽过同一跤）。
    function [7:0] aa;
        input [5:0] c;
        begin
            case (c)
                6'd0: aa = " ";
                6'd1: aa = ".";
                6'd2: aa = "-";
                6'd3: aa = "+";
                6'd4: aa = "/";
                6'd5: aa = ":";
                6'd6: aa = "=";
                6'd7: aa = "^";
                6'd44: aa = "%";
                6'd45: aa = "*";       // '×' 的替身
                6'd46: aa = "d";       // '÷' 的替身
                6'd47: aa = "<";       // '↩' 的替身
                default: aa = (c < 6'd18) ? (8'd48 + (c - 6'd8)) : (8'd65 + (c - 6'd18));
            endcase
        end
    endfunction

    // ---------------------------------------------------------------- 写口监控
    reg touched [0:511];
    reg exp_t   [0:511];
    integer wi, stray, n_done, n_we;

    task tch_clear;
        begin
            for (wi = 0; wi < 512; wi = wi + 1) begin
                touched[wi] = 1'b0;
                exp_t[wi]   = 1'b0;
            end
            n_we = 0;
        end
    endtask

    task tch_exp;
        input [3:0] row;
        input [4:0] col;
        input [3:0] wid;
        integer k;
        begin
            for (k = 0; k < wid; k = k + 1) exp_t[{row, (col + k[4:0])}] = 1'b1;
        end
    endtask

    always @(posedge clk) if (we) begin
        touched[waddr] = 1'b1;
        n_we = n_we + 1;
    end

    reg [8:0] a9;

    task tch_verify;
        input [8*40-1:0] label;
        integer bad;
        begin
            bad = 0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                a9 = wi[8:0];
                if (touched[wi] !== exp_t[wi]) begin
                    if (bad < 5)
                        $display("[FAIL] %0s 越界写: 格行 %0d 格列 %0d touched=%b expect=%b",
                                 label, a9[8:5], a9[4:0], touched[wi], exp_t[wi]);
                    bad = bad + 1;
                end
            end
            if (bad != 0) begin
                errors = errors + 1;
                $display("[FAIL] %0s 写口覆盖面差 %0d 处", label, bad);
            end else begin
                $display("[ OK ] %0s 写口只落在 15 个字段矩形内（无越界写）", label);
            end
        end
    endtask

    // ---------------------------------------------------------------- 单轮驱动
    task run_one;
        input [8*40-1:0] label;
        integer guard;
        begin
            n_done  = 0;
            stray   = 0;
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            guard = 0;
            while ((done !== 1'b1) && (guard < 20000)) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (done !== 1'b1) begin
                errors = errors + 1;
                $display("[FAIL] %0s 等不到 done（%0d 拍）", label, guard);
            end else begin
                $display("[ OK ] %0s done 在 %0d 拍后脉冲（一帧有 239040 拍可用）", label, guard);
            end
            @(negedge clk);
            if (busy !== 1'b0) begin
                errors = errors + 1;
                $display("[FAIL] %0s done 之后 busy 还高", label);
            end
        end
    endtask

    // ---------------------------------------------------------------- 字段回读
    //   读 row 行的 col..col+wid-1，拼成 wid 字节的串（首字符在最高有效字节），
    //   与 Verilog 字符串字面量的左补 NUL 对齐方式一致，所以直接整字比。
    task chk_fld;
        input [8*44-1:0] label;
        input [3:0]      row;
        input [4:0]      col;
        input [3:0]      wid;
        input [8*12-1:0] want;
        integer c;
        reg [8*12-1:0] got;
        begin
            got = {8*12{1'b0}};
            for (c = 0; c < wid; c = c + 1) begin
                raddr = {row, (col + c[4:0])};
                @(posedge clk); #1;
                got = {got[8*11-1:0], aa(rdata)};
            end
            if (got !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : got '%0s' want '%0s'", label, got, want);
            end else begin
                $display("[ OK ] %0s : '%0s'", label, got);
            end
        end
    endtask

    // 3 列 x 5 行的坐标（与 disp/p6_view.v 的字段表和 tools/gen_text_ram.py 的
    //  P6_LAB/P6_VAL 是同一份契约）
    task chk_all;
        input [8*32-1:0] tag;
        input [8*12-1:0] v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11,
                         v12, v13, v14;
        begin
            chk_fld({tag, ".倍频"},    4'd1, 5'd3,  4'd4, v0);
            chk_fld({tag, ".分频"},    4'd1, 5'd13, 4'd3, v1);
            chk_fld({tag, ".极对数"},  4'd1, 5'd23, 4'd2, v2);
            chk_fld({tag, ".迟滞"},    4'd2, 5'd3,  4'd2, v3);
            chk_fld({tag, ".限幅"},    4'd2, 5'd13, 4'd4, v4);
            chk_fld({tag, ".Z脉宽"},   4'd2, 5'd23, 4'd2, v5);
            chk_fld({tag, ".Z相位"},   4'd3, 5'd3,  4'd4, v6);
            chk_fld({tag, ".UVW相位"}, 4'd3, 5'd13, 4'd5, v7);
            chk_fld({tag, ".极性"},    4'd3, 5'd23, 4'd8, v8);
            chk_fld({tag, ".ABZ"},     4'd4, 5'd3,  4'd3, v9);
            chk_fld({tag, ".UVW"},     4'd4, 5'd13, 4'd3, v10);
            chk_fld({tag, ".SHIFT"},   4'd4, 5'd23, 4'd4, v11);
            chk_fld({tag, ".增益S"},   4'd5, 5'd3,  4'd5, v12);
            chk_fld({tag, ".增益C"},   4'd5, 5'd13, 4'd5, v13);
            chk_fld({tag, ".相位修正"}, 4'd5, 5'd23, 4'd6, v14);
        end
    endtask

    task exp_all;
        begin
            tch_exp(4'd1, 5'd3,  4'd4);
            tch_exp(4'd1, 5'd13, 4'd3);
            tch_exp(4'd1, 5'd23, 4'd2);
            tch_exp(4'd2, 5'd3,  4'd2);
            tch_exp(4'd2, 5'd13, 4'd4);
            tch_exp(4'd2, 5'd23, 4'd2);
            tch_exp(4'd3, 5'd3,  4'd4);
            tch_exp(4'd3, 5'd13, 4'd5);
            tch_exp(4'd3, 5'd23, 4'd8);
            tch_exp(4'd4, 5'd3,  4'd3);
            tch_exp(4'd4, 5'd13, 4'd3);
            tch_exp(4'd4, 5'd23, 4'd4);
            tch_exp(4'd5, 5'd3,  4'd5);
            tch_exp(4'd5, 5'd13, 4'd5);
            tch_exp(4'd5, 5'd23, 4'd6);
        end
    endtask

    integer k;

    initial begin
        $display("==== tb_p6_view: P6 设置页实时回读 ====");
        rst_n = 1'b0; start = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ================= 第 1 轮：编码器复位默认值 =================
        //   rtl/reg_file.v:255-278 → inter=0(⇒256) div=0(⇒1) pairs=4
        //                            hyst=0 ablimit=0 zwidth=4 zphase=0 uvwph=0 pol=0
        cfg_inter = 10'd0;  cfg_div = 3'd0;  cfg_pairs = 5'd4;
        cfg_hyst_ab = 5'd0; cfg_ablimit = 8'd0; cfg_zwidth = 4'd4;
        cfg_zphase = 12'd0; cfg_uvwph = 16'd0; cfg_pol = 4'b0000;
        cfg_abzen = 1'b1; cfg_uwven = 1'b1; cfg_shift = 4'd0;
        // rtl/reg_file.v:309-311 → gain_s = gain_c = 32768（Q1.15 单位增益）、phase_k = 0
        cfg_gain_s = 16'd32768; cfg_gain_c = 16'd32768; cfg_phase_k = 16'd0;

        tch_clear; exp_all;
        run_one("复位默认值");
        chk_all("复位默认值", "*256", "d 1", " 4", " 0", "   0", " 4",
                "   0", "    0", "A+B+Z+U+", "ON ", "ON ", "S0C0",
                "1.000", "1.000", "+0.000");
        tch_verify("复位默认值");
        if (n_we != 60) begin
            errors = errors + 1;
            $display("[FAIL] 复位默认值 写次数 = %0d（期望 60 = 4+3+2+2+4+2+4+5+8+3+3+4+5+5+6）", n_we);
        end else begin
            $display("[ OK ] 复位默认值 写次数 = 60（15 个字段的宽度之和，一个不多一个不少）");
        end

        // ================= 第 2 轮：字段满量程 =================
        //   categories: inter=256 div=7(⇒8) pairs=0(⇒32) hyst=31 ablimit=255
        //               zwidth=15 zphase=4095 uvwph=65535 pol=4'b1111
        //               shift=4'b1111 ⇒ {shift_c=3, shift_s=3} ⇒ "S3C3"
        cfg_inter = 10'd256; cfg_div = 3'd7;  cfg_pairs = 5'd0;
        cfg_hyst_ab = 5'd31; cfg_ablimit = 8'd255; cfg_zwidth = 4'd15;
        cfg_zphase = 12'd4095; cfg_uvwph = 16'd65535; cfg_pol = 4'b1111;
        cfg_abzen = 1'b1; cfg_uwven = 1'b1; cfg_shift = 4'b1111;
        // Q1.15 满量程：无符号 65535 -> 1999 千分（1.999）；有符号最小 -32768 -> 1.000（负）
        cfg_gain_s = 16'd65535; cfg_gain_c = 16'd65535; cfg_phase_k = 16'h8000;

        tch_clear; exp_all;
        run_one("满量程");
        chk_all("满量程", "*256", "d 8", "32", "31", " 255", "15",
                "4095", "65535", "A-B-Z-U-", "ON ", "ON ", "S3C3",
                "1.999", "1.999", "-1.000");
        tch_verify("满量程");

        // ================= 第 3 轮：前导零抑制 + 极性逐位 + 枚举取反 =========
        //   inter=1 写成 "*  1"（不是 "X001"）、ablimit=7 写成 "   7"、
        //   uvwph=10 写成 "   10"；pol=4'b0010 只反相 B 相 ⇒ "A+B-Z+U+"；
        //   ABZ 使能关 ⇒ "OFF"，shift=4'b0001 ⇒ {shift_c=0, shift_s=1} ⇒ "S1C0"
        cfg_inter = 10'd1;  cfg_div = 3'd1;  cfg_pairs = 5'd0;
        cfg_hyst_ab = 5'd0; cfg_ablimit = 8'd7; cfg_zwidth = 4'd0;
        cfg_zphase = 12'd1; cfg_uvwph = 16'd10; cfg_pol = 4'b0010;
        cfg_abzen = 1'b0; cfg_uwven = 1'b1; cfg_shift = 4'b0001;
        // Q1.15 的小数三位**不做前导零抑制**：164 -> 5 千分（0.005，两个 0 都要写出来）
        //   41 -> 1 千分（0.001）；-500 -> -0.015（有符号，幅值先取补）
        cfg_gain_s = 16'd164; cfg_gain_c = 16'd41; cfg_phase_k = 16'hFE0C;

        tch_clear; exp_all;
        run_one("前导零抑制");
        chk_all("前导零抑制", "*  1", "d 2", "32", " 0", "   7", " 0",
                "   1", "   10", "A+B-Z+U+", "OFF", "ON ", "S1C0",
                "0.005", "0.001", "-0.015");
        tch_verify("前导零抑制");

        // ================= 第 4 轮：all-zero 也要出数 =================
        //   ★ 最低位永远显示，否则 0 会变成空格 ⇒ 屏幕上整格空白，看不出是 0。
        cfg_inter = 10'd0;  cfg_div = 3'd0;  cfg_pairs = 5'd0;
        cfg_hyst_ab = 5'd0; cfg_ablimit = 8'd0; cfg_zwidth = 4'd0;
        cfg_zphase = 12'd0; cfg_uvwph = 16'd0; cfg_pol = 4'b0000;
        cfg_abzen = 1'b0; cfg_uwven = 1'b0; cfg_shift = 4'd0;
        cfg_gain_s = 16'd0; cfg_gain_c = 16'd0; cfg_phase_k = 16'd0;

        tch_clear; exp_all;
        run_one("全零");
        chk_all("全零", "*256", "d 1", "32", " 0", "   0", " 0",
                "   0", "    0", "A+B+Z+U+", "OFF", "OFF", "S0C0",
                "0.000", "0.000", "+0.000");
        tch_verify("全零");

        repeat (4) @(posedge clk);

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 看门狗：任何一轮卡住都不许永远挂着
    initial begin
        #2_000_000;
        $display("[FAIL] 看门狗超时");
        $display("TEST FAILED: watchdog");
        $finish;
    end

endmodule

`default_nettype wire
