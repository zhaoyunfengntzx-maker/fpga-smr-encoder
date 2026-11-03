//=============================================================================
// tb_val_format.v -- val_format 的定点/排版自检
//
// 验的是"算出来的字符对不对、小数点位置对不对、前导空格对不对、
// 符号对不对"，以及最容易错的一条：**定点缩放是否真的等于数学值**。
// 用真实量纲对准已知答案（不是拿 DUT 的输出当期望值）。
//=============================================================================
`timescale 1ns / 1ps

module tb_val_format;

    reg               clk = 1'b0;
    reg               rst_n = 1'b0;
    reg               start = 1'b0;
    reg signed [31:0] f_q10 = 32'sd0;
    reg signed [47:0] pos_acc = 48'sd0;
    reg        [15:0] angle = 16'd0;
    reg        [7:0]  io_state = 8'd0;
    reg        [9:0]  cfg_inter = 10'd64;
    reg        [2:0]  cfg_div = 3'd0;
    reg        [4:0]  cfg_pairs = 5'd4;
    // v22 面板端口：面板开着时字段 1 显示"待应用值"，面板一关回读值
    reg               pnl_on    = 1'b0;
    reg        [9:0]  pnl_inter = 10'd64;
    reg        [2:0]  pnl_div   = 3'd0;      // v44（㊶）：待应用分频码（div = 码 + 1）
    reg [5:0]         nodata_mask = 6'd0;      // v45（㊷）：空态（信号不可信 ⇒ 测量字段整格 '-'）
    // ★ v86（任务C）：累计转数改成**直接显示 Z 计数**（本编码器 1 Z/转，这是定义）。
    //   val_format 新端口 rev_bin 从 z_cnt_lab 的 5 位十进制直接接过来，
    //   于是屏上的「累计转数」与「Z 计数」从定义上就是同一个数。
    reg [16:0]        rev_bin = 17'd0;

    wire        we;
    wire [8:0]  waddr;
    wire [5:0]  wdata;
    wire        busy, done;

    integer errors = 0;
    integer i;

    always #5 clk = ~clk;      // 100 MHz 仿真时钟（分子只影响速度，不影响定点含义）

    val_format dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .f_q10(f_q10), .pos_acc(pos_acc), .rev_bin(rev_bin),
        .angle(angle), .io_state(io_state),
        .cfg_inter(cfg_inter), .cfg_div(cfg_div), .cfg_pairs(cfg_pairs),
        // v22 面板端口：第 4 轮会把它拉高（前 3 轮都走老路径）
        .pnl_on(pnl_on), .pnl_inter(pnl_inter), .pnl_div(pnl_div),
        .nodata_mask(nodata_mask),
        .we(we), .waddr(waddr), .wdata(wdata), .busy(busy), .done(done)
    );

    // 数值层字符 RAM 的镜像：DUT 写什么就存什么
    reg [5:0] vram [0:511];
    always @(posedge clk) if (we) vram[waddr] <= wdata;

    // ---- 字库索引 -> ASCII（用于打印，人眼核对） ----
    //   ★ v23：字库末尾追加了 %(44) / ×(45) / ÷(46)。本测试台的期望串是
    //     **单字节**的（chkf 逐字节比对），而 × / ÷ 在 Verilog 字符串字面量里
    //     会编成 2 字节 UTF-8（0xC3 0x97 / 0xC3 0xB7），比对必然失败 ——
    //     所以这里只映射成单字节替身：× -> '*'、÷ -> 'd'（文件头的对照表如此写）。
    function [7:0] to_ascii;
        input [5:0] c;
        begin
            if      (c == 6'd0) to_ascii = " ";
            else if (c == 6'd1) to_ascii = ".";
            else if (c == 6'd2) to_ascii = "-";
            else if (c == 6'd3) to_ascii = "+";
            else if (c == 6'd4) to_ascii = "/";
            else if (c == 6'd5) to_ascii = ":";
            else if (c == 6'd6) to_ascii = "=";
            else if (c == 6'd7) to_ascii = "^";
            else if (c == 6'd44) to_ascii = "%";
            else if (c == 6'd45) to_ascii = "*";   // 真身 '×'
            else if (c == 6'd46) to_ascii = "d";   // 真身 '÷'
            // ★ v52（㊾）：两个逻辑电平字形。● = 48、○ = 51（卡 6 主值 `A● B● Z○`）。
            //   这里用大写 'O' 代表实心、小写 'o' 代表空心（控制台上唯一不会混淆的一对），
            //   比原来的 48->'_' / 51->'b' 好读得多。
            else if (c == 6'd48) to_ascii = "O";   // ● 实心（高电平）
            else if (c == 6'd51) to_ascii = "o";   // ○ 空心（低电平）
            else if (c <= 6'd17) to_ascii = 8'h30 + (c - 6'd8);
            else                 to_ascii = 8'h41 + (c - 6'd18);
        end
    endfunction

    // ---- ASCII -> 字库索引（用于写期望值） ----
    function [5:0] to_idx;
        input [7:0] a;
        begin
            if      (a == " ") to_idx = 6'd0;
            else if (a == ".") to_idx = 6'd1;
            else if (a == "-") to_idx = 6'd2;
            else if (a == "+") to_idx = 6'd3;
            else if (a == "/") to_idx = 6'd4;
            else if (a == "%") to_idx = 6'd44;
            else if (a == "*") to_idx = 6'd45;
            else if (a == "d") to_idx = 6'd46;
            else if (a >= "0" && a <= "9") to_idx = 6'd8  + (a - "0");
            else if (a >= "A" && a <= "Z") to_idx = 6'd18 + (a - "A");
            else to_idx = 6'd63;
        end
    endfunction

    // 打印一个字段的实测字符
    task show;
        input [3:0] row;
        input [4:0] col;
        input [4:0] wid;
        begin
            $write("    row=%0d col=%0d : [", row, col);
            for (i = 0; i < wid; i = i + 1)
                $write("%c", to_ascii(vram[{row, col + i[4:0]}]));
            $write("]\n");
        end
    endtask

    // 逐字符比对期望字符串（期望串右对齐到 128 bit，故按 wid 从低位往高位取）
    task chkf;
        input [3:0]      row;
        input [4:0]      col;
        input [4:0]      wid;
        input [8*16-1:0] exp;
        reg [7:0] got;
        integer n;
        begin
            for (n = 0; n < wid; n = n + 1) begin
                got = to_ascii(vram[{row, col + n[4:0]}]);
                if (got !== exp[8*(wid-1-n) +: 8]) begin
                    $display("[FAIL] row=%0d col=%0d pos=%0d got='%c'(%0d) want='%c'",
                             row, col + n, n, got, vram[{row, col + n[4:0]}],
                             exp[8*(wid-1-n) +: 8]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // 跑一轮：给一次 start，等到 done
    task run_once;
        begin
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            while (!done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    initial begin
        for (i = 0; i < 512; i = i + 1) vram[i] = 6'd0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---------------------------------------------------------------
        // 第 1 轮：真实量纲
        //   f_in  = 1500 Hz      -> f_q10 = 1500 * 1024 = 1536000
        //            fld0 显示的是 **kHz、1 位小数**（v78 起的口径）=> "1.5"
        //   极对数 = 10          -> RPM = 60*1500/10 = 9000.0
        //            （fld2 只有 6 格 ⇒ 上限 9999.9；22500 rpm 塞不进去，
        //              这是 v74 起就有的版面限制，本台子用 9000 覆盖）
        //   角度   = 8192/65536 -> 45.0 度（fld3 固定带 ± 号）
        //   累计转数 = Z 计数 rev_bin（v86），本轮给 0
        // ---------------------------------------------------------------
        $display("--- round 1: f_in=1500Hz pairs=10 inter=64 div=1 angle=45.0 z=0 ---");
        f_q10 = 32'sd1536000;
        cfg_pairs = 5'd10;
        cfg_inter = 10'd64;
        cfg_div = 3'd0;
        angle = 16'd8192;
        io_state = 8'b0000_0101;               // a=1 b=0 z=1
        pos_acc = 48'sd48 << 16;               // 48 电周期（本版 REV 已不看它）
        rev_bin = 17'd0;

        run_once;

        show(4'd2,  5'd3,  5'd9);
        show(4'd2,  5'd18, 5'd7);
        show(4'd6,  5'd3,  5'd6);
        show(4'd6,  5'd18, 5'd7);
        show(4'd10, 5'd3,  5'd8);
        show(4'd11, 5'd18, 5'd8);

        // ★ v82 起数值字段是**左对齐**（v81 的期望串全是右对齐，早已过期）
        chkf(4'd2, 5'd3,  5'd9,  "1.5      ");
        chkf(4'd2, 5'd18, 5'd7,  "* 64 d1");
        chkf(4'd6, 5'd3,  5'd6,  "9000.0");
        chkf(4'd6, 5'd18, 5'd7,  "+45.0  ");
        chkf(4'd10, 5'd3, 5'd8,  "0       ");
        chkf(4'd11, 5'd18, 5'd8, "AO Bo ZO");   // a=1 b=0 z=1（O=● 实心 / o=○ 空心），★ v83 行 11

        // ---------------------------------------------------------------
        // 第 2 轮：慢速 / 反转 / 极对数 1 / 倍频 256 / 分频 4
        //   f_in = 2.00 Hz  -> f_q10 = 2048
        //            kHz 口径下 2 Hz = 0.02 kHz ⇒ 1 位小数只剩 "0.0"
        //            （这正是 v78 换量纲的代价：低频段分辨率不够，
        //              但 kHz 是用户 2026-11-02 明确要的口径）
        //   RPM  = 60*2/1 = 120.0
        // ---------------------------------------------------------------
        $display("--- round 2: f_in=2Hz pairs=1 inter=256 div=4 reverse ---");
        f_q10 = -32'sd2048;                    // 负 = 反转
        cfg_pairs = 5'd1;
        cfg_inter = 10'd256;
        cfg_div = 3'd3;                        // 寄存器 3 = 分频 4
        angle = 16'd0;
        io_state = 8'b0000_0000;
        pos_acc = -(48'sd3 << 16);             // 反转 3 转（REV 不看它）
        rev_bin = 17'd0;

        run_once;

        show(4'd2,  5'd3,  5'd9);
        show(4'd2,  5'd18, 5'd7);
        show(4'd6,  5'd3,  5'd6);
        show(4'd6,  5'd18, 5'd7);
        show(4'd10, 5'd3,  5'd8);
        show(4'd11, 5'd18, 5'd8);

        chkf(4'd2, 5'd3,  5'd9,  "0.0      ");
        chkf(4'd2, 5'd18, 5'd7,  "*256 d4");
        chkf(4'd6, 5'd3,  5'd6,  "120.0 ");
        chkf(4'd6, 5'd18, 5'd7,  "-0.0   ");
        chkf(4'd10, 5'd3, 5'd8,  "0       ");
        chkf(4'd11, 5'd18, 5'd8, "Ao Bo Zo");   // 全低：三个 ○

        // ---------------------------------------------------------------
        // 第 3 轮：★ 倍频寄存器 = 0 必须显示成 X256（rtl/abz_gen.v:118 的约定）
        //   这是一个真实存在过的屏上错误：复位后 r_inter0 = 0，编码器按 256 倍
        //   跑，而屏上写的是 "X  0 /1" —— 数字与行为不一致，正是 docs/13 的
        //   "屏只能显示真实值" 所禁止的。本轮把这条映射钉住，防止以后被
        //   "顺手简化" 掉（cfg_inter 直接拆位是最自然的写法，也就会再犯）。
        // ---------------------------------------------------------------
        $display("--- round 3: inter register 0 must display X256 ---");
        cfg_inter = 10'd0;
        cfg_div   = 3'd0;                      // 寄存器 0 = 分频 1
        run_once;

        show(4'd2, 5'd13, 5'd7);
        chkf(4'd2, 5'd18, 5'd7, "*256 d1");

        // ---------------------------------------------------------------
        // 第 4 轮：面板开着时字段 1 显示"待应用值"（docs/13:267 与 §6.2）
        //   面板上点 [+] 到 ×128、还没 APPLY 时，屏上必须显示 ×128 ——
        //   这一轮验的是"待应用"与"回读确认值"必须分得清：
        //     · 面板开着 → 显示待应用值（用户正在改的那个数）
        //     · 面板收起 → 显示寄存器回读值（唯一允许当作"真实值"的那个数）
        //   ★ 这一条是 §6.2 的屏幕侧判据：屏幕绝不允许把"用户想要的理想值"
        //     当成已生效的值显示（当面板收起、还没确认时尤其致命）。
        // ---------------------------------------------------------------
        $display("--- round 4: panel open shows pending, closed shows readback ---");
        cfg_inter = 10'd64;
        cfg_div   = 3'd0;
        pnl_on    = 1'b1;
        pnl_inter = 10'd128;
        run_once;

        show(4'd2, 5'd13, 5'd7);
        chkf(4'd2, 5'd18, 5'd7, "*128 d1");

        pnl_on = 1'b0;                          // 面板收起（不管待应用值还挂着）
        run_once;
        show(4'd2, 5'd13, 5'd7);
        chkf(4'd2, 5'd18, 5'd7, "* 64 d1");

        cfg_inter = 10'd128;                    // 提交成功后的回读值跟上了
        run_once;
        show(4'd2, 5'd13, 5'd7);
        chkf(4'd2, 5'd18, 5'd7, "*128 d1");

        pnl_inter = 10'd64;                     // 还原，避免影响后续新增轮次

        // ---------------------------------------------------------------
        // 第 5 轮：★ v45（㊷）空态 —— 信号不可信时不给"看起来像测量值"的数字
        //   docs/13:351 反模式 8「没信号时屏幕一片空白 / 一片 0」：
        //     四个**测量**字段（输入频率 / 转速 / 角度 / 累计转数）整格 '-'，
        //     小数点保留（字段骨架还在、位置可读，"这不是零、是没有读数"）。
        //   两个**非测量**字段必须**一字不动**：
        //     · 字段 1 倍频分频 = 配置回读（寄存器里的数，与输入信号无关）
        //     · 字段 5 ABZ/UVW  = 逻辑电平（线是什么就是什么）
        //   ★ 这一轮把"空态只作用于测量值"钉死：以后谁把空态铺到配置字段上，
        //     屏就再也说不出"编码器现在配的是 ×64 ÷1"。
        // ---------------------------------------------------------------
        $display("--- round 5: nodata -> measurement fields dash, config/logic fields untouched ---");
        cfg_inter = 10'd64;
        cfg_div   = 3'd0;
        f_q10     = 32'sd1536000;               // 1500.00 Hz（有值，但"不可信"）
        angle     = 16'd8192;                   // 45.0 度
        pos_acc   = 48'sd48 << 16;              // 12 转
        io_state  = 8'b0000_0101;               // a=1 b=0 z=1
        pnl_on    = 1'b0;
        nodata_mask = 6'b011111;
        run_once;

        show(4'd2,  5'd3,  5'd9);
        show(4'd2,  5'd18, 5'd7);
        show(4'd6,  5'd3,  5'd6);
        show(4'd6,  5'd18, 5'd7);
        show(4'd10, 5'd3,  5'd8);
        show(4'd11, 5'd18, 5'd8);

        chkf(4'd2, 5'd3,  5'd9,  "-----.-  ");   // 输入频率：5 位 + '.' + 1 位（f_wid=7）
        chkf(4'd2, 5'd18, 5'd7,  "* 64 d1");     // 配置回读：一字不动
        chkf(4'd6, 5'd3,  5'd6,  "----.-");      // 转速：4 位 + '.' + 1 位（f_wid=6）
        chkf(4'd6, 5'd18, 5'd7,  "-----.-");     // 角度：5 位 + '.' + 1 位
        chkf(4'd10, 5'd3, 5'd8,  "--------");    // 累计转数（Z 计数）：8 位整数
        chkf(4'd11, 5'd18, 5'd8, "AO Bo ZO");    // 逻辑电平：一字不动（O=● 实心 / o=○ 空心）

        // 面板开着时若同时 nodata：字段 1 仍显示"待应用值"（面板优先，配置与信号无关）
        pnl_on    = 1'b1;
        pnl_inter = 10'd128;
        run_once;
        show(4'd2, 5'd13, 5'd7);
        chkf(4'd2, 5'd18, 5'd7,  "*128 d1");

        pnl_on = 1'b0;
        pnl_inter = 10'd64;
        nodata_mask = 6'd0;
        run_once;
        show(4'd2, 5'd3, 5'd9);
        chkf(4'd2, 5'd3, 5'd9, "1.5      ");     // 撤销空态后立刻回到读数

        // ---------------------------------------------------------------
        // 第 6 轮：★ v86（任务C）累计转数 **就是 Z 计数**
        //   本编码器 1 Z/转（定义），所以屏上「累计转数」与「Z 计数」必须是同一个数。
        //   v85 之前 REV 走 pos_acc / cpr 的累加，和 z_out 边沿计数各有一条误差链，
        //   现场出现过 2326 REV vs 1718 Z 计数 vs 硬件 4856 三个数互相矛盾。
        //   现在 val_format 直接吃 z_cnt_lab 的 5 位十进制（rev_bin），
        //   pos_acc 只留给 RPM。
        //   本轮故意把 pos_acc 给成 12 转（=48 电周期/4）：如果 REV 还偷偷走
        //   pos_acc，就会显示 12 而不是 12345 —— 这条断言就是"路由没串"的证据。
        // ---------------------------------------------------------------
        $display("--- round 6: rev_bin=12345 -> REV shows 12345 (pos_acc ignored) ---");
        f_q10 = 32'sd1536000;
        cfg_pairs = 5'd10;
        cfg_inter = 10'd64;
        cfg_div   = 3'd0;
        angle     = 16'd8192;
        io_state  = 8'b0000_0101;
        pos_acc   = 48'sd48 << 16;              // 12 转：REV 必须**无视**它
        nodata_mask = 6'd0;

        rev_bin = 17'd12345;                   // 十进制 12345
        run_once;
        show(4'd10, 5'd3, 5'd8);
        chkf(4'd10, 5'd3, 5'd8, "12345   ");

        rev_bin = 17'd7;                   // 前导零抑制：7 只占 1 格
        run_once;
        show(4'd10, 5'd3, 5'd8);
        chkf(4'd10, 5'd3, 5'd8, "7       ");

        rev_bin = 17'd0;                   // 计数为 0：屏上是 "0"，不是空白
        run_once;
        show(4'd10, 5'd3, 5'd8);
        chkf(4'd10, 5'd3, 5'd8, "0       ");

        rev_bin = 17'd99999;                   // 满量程 99999 不溢出
        run_once;
        show(4'd10, 5'd3, 5'd8);
        chkf(4'd10, 5'd3, 5'd8, "99999   ");

        // 同一轮里 RPM 仍然是 pos_acc/f_q10 那条链（REV 换了源，RPM 没换）
        chkf(4'd6, 5'd3, 5'd6, "9000.0");

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 防呆：卡住就报出来，别静默超时
    initial begin
        #2000000;
        $display("[FAIL] timeout: done never asserted");
        $display("TEST FAILED: 1 errors");
        $finish;
    end

endmodule
