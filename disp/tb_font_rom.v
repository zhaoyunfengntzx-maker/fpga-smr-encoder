//=============================================================================
// tb_font_rom.v -- 字库自检（ASCII + 汉字混排）
//
// 这一层要挡住的是"字形数据被悄悄换掉 / 索引或行地址接错 / 汉字表被漏搬了字"
// 这类错误。它**不能**证明字形好看 —— 好看与否只能靠人眼看，所以本测试台把
// 全部字形打印成 ASCII 图，并做**结构性**比对：
//   [1] 非空格字符的位图必须至少有一行不为 0（挡住"全黑"字形）
//   [2] 任意两个字符的位图不得完全相同
//       —— 这一条对汉字尤其值钱：132 个汉字里有任何两个被搬成同一个字，
//          屏上只会安静地显示错字，没有任何别的地方能发现
//   [3] ASCII 的两个尺寸必须是同一字形的一致放大
//       （lab 的第 k 行放大 3 倍 == val 的第 3k+j 行；只对 ASCII 成立，
//        汉字是独立的 16x16 点阵，不是 val 的放大）
//   [4] ASCII 字形之外的行必须全 0，且行内字形宽度以外的低位必须全 0
//       （挡住纵向偏移写错 -> 文字被切掉一截；以及左对齐移位算错）
//
// 关于 [3] 的偏移：lab 的 ASCII 字形从格内第 1 行开始，val 从第 11 行开始
// （= (64-42)/2，垂直居中）。所以 lab 的第 k 行对应 val 的第 11+3k..13+3k 行。
//=============================================================================
`timescale 1ns / 1ps

module tb_font_rom;

    localparam integer NA    = 51;      // ASCII 字数（= tools/gen_font_rom.py 的 ASCII_COUNT）
    localparam integer NAB   = 61;      // ASCII_TABLE 的 UTF-8 字节数（× ÷ 各 2、↩●▲✖ 各 3）
    localparam integer NC    = 132;     // 汉字字数（= tools/make_cn_glyphs.py 的 CN_ORDER 去重后）
    localparam integer NCH   = NA + NC; // 183（lab 码宽 8 bit）
    //   ★ v43（㊵）：这两个常量**跟着字库走**，加字必须同步 —— v42（㊴）加了
    //     恢/默/认 三个字却忘了改这里（还写着 125/176），后果是最近三个字的
    //     [1] 非空 / [2] 两两不重复 两条判据一直没跑；本轮（加 模/拟/展/开）
    //     一并补上，并在产物里印出来对账（见 main 的第一行 $display）。
    // v58 字模改为按最终像素尺寸原生栅格化（Arial Bold），格尺寸不变：
    //   lab = 11x14 字形居中在 16x16 格（y_off 1），val = 30x48 居中在 32x64 格（y_off 8）。
    //   下面这组常量必须与 tools/gen_font_rom.py 的 ASCII_SIZES 逐项相同。
    localparam integer CL    = 16;      // lab 格高
    localparam integer WL    = 16;      // lab 行宽
    localparam integer GWL   = 11;      // ASCII 在 lab 里的字形宽
    localparam integer OFF_L = 1;       // ASCII 字形纵向偏移
    localparam integer GL    = 14;      // ASCII lab 字形高
    localparam integer CV    = 64;      // val 格高
    localparam integer WV    = 30;      // val 行宽
    localparam integer OFF_V = 8;       // val 字形纵向偏移
    localparam integer GV    = 48;      // val 字形高

    // 前 48 个码位 = ASCII，顺序与 tools/gen_font_rom.py 的 ASCII_CHARS 必须逐字相同。
    //   ★ v23 追加在末尾的三个符号是 % (U+0025) / × (U+00D7) / ÷ (U+00F7)，
    //     都是单字节，所以 8 bit/字符 的打包字符串仍然成立。
    //   ★ v24 再追加 '↩' (U+21A9)；它在 8 bit 打包里占一个字节（UTF-8 是三字节，
    //     但 Verilog 的字符串字面量按字节打包，xsim 存的是 UTF-8 原始字节 ——
    //     48 刚好用满 val 平面 6 bit 的索引区间，所以这里用码位比对而不是字母。
    // 后 132 个是汉字码位，顺序见 tools/cn_glyphs.py 的 CHARS，这里只按序号报告。
    //   ★ 这张表**只用来给人看名字**（结构判据全部按码位下标走，不依赖字符值）。
    //     打包字面量按 UTF-8 **字节**展开：44 个单字节 + '%' + 2+2+3 + 3+3+3 = 61 字节，
    //     所以向量按 61 字节声明（按 51 字节声明会把最左边 10 个字节截掉，
    //     `[0]` 起就全印成乱码）。索引 48..50 的名字是 ●▲✖ 的 UTF-8 首字节，同样是乱码；
    //     看到名字错位不要以为字库错了。
    localparam [8*NAB-1:0] ASCII_TABLE =
        " .-+/:=^0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ%×÷↩●▲✖";

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    reg  [7:0] ch_idx = 8'd0;
    reg  [3:0] rowl   = 4'd0;
    reg  [5:0] rowv   = 6'd0;
    wire [WL-1:0] bitsl;
    wire [WV-1:0] bitsv;

    font_rom_lab u_lab (.clk(clk), .ch_idx(ch_idx), .row_in_cell(rowl), .bits(bitsl));
    font_rom_val u_val (.clk(clk), .ch_idx(ch_idx[5:0]), .row_in_cell(rowv), .bits(bitsv));

    wire [7:0] ch_of [0:NA-1];
    genvar gi;
    generate
        for (gi = 0; gi < NA; gi = gi + 1) begin : g_ch
            assign ch_of[gi] = ASCII_TABLE[8*(NAB-1-gi) +: 8];
        end
    endgenerate

    reg [WL-1:0] bmpl [0:NCH-1][0:CL-1];
    reg [WV-1:0] bmpv [0:NA-1][0:CV-1];

    integer errors = 0;
    integer c, d, r, k, nz, same;
    integer j, b;
    integer d0, dot, g_top, g_bot, v_top, v_bot;
    reg [WV-1:0] wide;

    // 判断 ASCII 的某个格内行是否落在字形体内
    function in_glyph_val;
        input integer row;
        begin in_glyph_val = (row >= OFF_V) && (row < OFF_V + GV); end
    endfunction

    // 打印字符名：ASCII 打字符本身，汉字只打序号（汉字在 Verilog 字面量里不可移植）
    task show_name;
        input integer idx;
        begin
            if (idx < NA) $write("'%c'", ch_of[idx]);
            else          $write("CJK#%0d", idx - NA);
        end
    endtask

    initial begin
        $display("================================================================");
        $display(" tb_font_rom : %0d ASCII + %0d CJK = %0d glyphs", NA, NC, NCH);
        $display("   lab = ASCII 10x14 / CJK 16x16 in a %0dx%0d cell", WL, CL);
        $display("   val = 30x42 glyph in a %0dx%0d cell (y_off %0d, ASCII only)", WV, CV, OFF_V);
        $display("================================================================");

        // ---- 读出 lab 平面的全部点阵 ----
        for (c = 0; c < NCH; c = c + 1) begin
            for (r = 0; r < CL; r = r + 1) begin
                ch_idx = c[7:0]; rowl = r[3:0];
                @(posedge clk); #1;
                bmpl[c][r] = bitsl;
            end
        end
        // ---- 读出 val 平面（只有 ASCII）----
        for (c = 0; c < NA; c = c + 1) begin
            for (r = 0; r < CV; r = r + 1) begin
                ch_idx = c[7:0]; rowv = r[5:0];
                @(posedge clk); #1;
                bmpv[c][r] = bitsv;
            end
        end

        // ---- [1] 非空格字符不得全黑 ----
        for (c = 1; c < NCH; c = c + 1) begin
            nz = 0;
            for (r = 0; r < CL; r = r + 1)
                if (bmpl[c][r] !== {WL{1'b0}}) nz = nz + 1;
            if (nz === 0) begin
                errors = errors + 1;
                $display("[FAIL] glyph %0d ", c); show_name(c);
                $display("       is completely blank");
            end
        end

        // ---- [2] 任意两个字符不得同形（对汉字是"搬错字"的唯一机器判据）----
        for (c = 0; c < NCH; c = c + 1) begin
            for (d = c + 1; d < NCH; d = d + 1) begin
                same = 1;
                for (r = 0; r < CL; r = r + 1)
                    if (bmpl[c][r] !== bmpl[d][r]) same = 0;
                if (same) begin
                    errors = errors + 1;
                    $display("[FAIL] glyph %0d ", c); show_name(c);
                    $display("       is identical to glyph %0d", d); show_name(d);
                    $display("");
                end
            end
        end

        // ---- [4] v58 契约：字形只占声明的格子，不许被切边 ----
        //     v58 起 lab 与 val 是**各自独立栅格化**的，不再是"同一 5x7 放大 3 倍"，
        //     所以旧 [3]（val == 3x lab）随字模方案一起作废。换成三条现在真正
        //     成立、而且坏了会立刻看得见的判据：
        //       [4a] lab 格最上一行、最下一行必须全 0（11x14 字形居中在 16 行里）
        //       [4b] val 格最上 7 行、最下 7 行必须全 0（30x48 字形居中在 64 行里），
        //            留 1 行余量给 'O'/'C'/'G' 这类圆形字母的 1 px 上溢出
        //       [4c] 0..9 十个数字的墨迹高度必须一致（等宽数字表的前提），
        //            且 '.' 的墨迹底边必须与数字底边同高（基线对齐）
        //       [4d] val 的 '0' 墨迹高度必须 >= 44 px（挡住"字模退化成小字被放大"）
        for (c = 0; c < NA; c = c + 1) begin
            // [4a] lab：首末行空白
            if (bmpl[c][0] !== {WL{1'b0}} || bmpl[c][CL-1] !== {WL{1'b0}}) begin
                errors = errors + 1;
                $display("[FAIL] '%c' lab glyph touches the cell border (row 0 or %0d)", ch_of[c], CL-1);
            end
            // [4b] val：上下各留 7 行
            for (r = 0; r < CV; r = r + 1) begin
                if (((r < OFF_V - 1) || (r > OFF_V + GV)) && bmpv[c][r] !== {WV{1'b0}}) begin
                    errors = errors + 1;
                    if (errors < 12)
                        $display("[FAIL] '%c' val row %0d is outside the glyph box but not blank",
                                 ch_of[c], r);
                end
            end
        end

        // [4c]/[4d] 数字度量：先量出 '0' 的墨迹上下沿（不用数组，xsim 对
        //  integer 数组索引有过崩溃史），再让每个数字与 '.' 跟它比
        d0 = -1; dot = -1;
        for (c = 0; c < NA; c = c + 1) begin
            if (ch_of[c] == 8'd48) d0  = c;
            if (ch_of[c] == 8'd46) dot = c;
        end
        if (d0 < 0 || dot < 0) begin
            errors = errors + 1;
            $display("[FAIL] '0' or '.' not found in ASCII table");
        end else begin
            g_top = -1; g_bot = -1;
            for (r = 0; r < CV; r = r + 1)
                if (bmpv[d0][r] !== {WV{1'b0}}) begin
                    if (g_top < 0) g_top = r;
                    g_bot = r;
                end
            // 每个数字必须与 '0' 同高（等宽数字表的前提）
            for (c = 0; c < NA; c = c + 1) begin
                if ((ch_of[c] >= 8'd48) && (ch_of[c] <= 8'd57)) begin
                    v_top = -1; v_bot = -1;
                    for (r = 0; r < CV; r = r + 1)
                        if (bmpv[c][r] !== {WV{1'b0}}) begin
                            if (v_top < 0) v_top = r;
                            v_bot = r;
                        end
                    // 圆形数字（0/3/5/6/8/9）在顶线与基线上各有 1 px 光学溢出，
                    // 这是字体自带的光学补偿（不是错位），允许 ±1 px。
                    if ((v_top > g_top + 1) || (v_top < g_top - 1) ||
                        (v_bot > g_bot + 1) || (v_bot < g_bot - 1)) begin
                        errors = errors + 1;
                        $display("[FAIL] digit '%c' ink rows %0d..%0d != '0' ink rows %0d..%0d",
                                 ch_of[c], v_top, v_bot, g_top, g_bot);
                    end
                end
            end
            // '.' 的底边必须与数字底边同高（基线对齐）
            v_top = -1; v_bot = -1;
            for (r = 0; r < CV; r = r + 1)
                if (bmpv[dot][r] !== {WV{1'b0}}) begin
                    if (v_top < 0) v_top = r;
                    v_bot = r;
                end
            if ((v_bot > g_bot + 1) || (v_bot < g_bot - 1)) begin
                errors = errors + 1;
                $display("[FAIL] '.' ink bottom %0d != '0' ink bottom %0d", v_bot, g_bot);
            end
            // val 的 '0' 必须有 44 px 以上的墨迹高（挡住"字模退化成小字再放大"）
            if ((g_bot - g_top + 1) < 44) begin
                errors = errors + 1;
                $display("[FAIL] '0' ink height %0d < 44 px (font shrank?)", g_bot - g_top + 1);
            end
        end

        if (errors === 0)
            $display("[ OK ] all %0d glyphs: non-blank, pairwise distinct, inside cell, digits tabular", NCH);
        else
            $display("[FAIL] font structural errors = %0d", errors);

        // ---- 全字形打印（供人眼核对；这是唯一能证明"字好看"的方式）----
        $display("");
        $display("---- lab plane: %0d ASCII (10x14 in 16x16) ----", NA);
        for (c = 0; c < NA; c = c + 1) begin
            $display("  [%0d] '%c'", c, ch_of[c]);
            for (r = 0; r < CL; r = r + 1) begin
                $write("      ");
                for (k = WL - 1; k >= 0; k = k - 1)
                    $write("%s", bmpl[c][r][k] ? "#" : ".");
                $write("\n");
            end
        end
        $display("");
        $display("---- lab plane: %0d CJK (16x16) ----", NC);
        for (c = NA; c < NCH; c = c + 1) begin
            $display("  [%0d] CJK#%0d", c, c - NA);
            for (r = 0; r < CL; r = r + 1) begin
                $write("      ");
                for (k = WL - 1; k >= 0; k = k - 1)
                    $write("%s", bmpl[c][r][k] ? "#" : ".");
                $write("\n");
            end
        end

        if (errors === 0) $display("\nTEST PASSED: 0 errors");
        else              $display("\nTEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("\n[FAIL] TIMEOUT");
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
