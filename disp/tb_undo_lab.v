//=============================================================================
//  disp/tb_undo_lab.v  --  面板「↩ 回到 ×N ÷M」标签的单元测试（直接例化 undo_lab）
//
//  为什么直接测模块：屏上那 9 格的字全是**运行期数值**（每笔事务成功后才知道），
//  走整机测试台要等 853,440 拍一帧、还要在层次里挖 p1_lab_ram 的写口；
//  直接喂 inter/div 就能把"两位十进制 + 前导零抑制 + 分频个位 + avail=0 的静态
//  版面"逐项钉住。
//
//  判据放在**写口上**（与 disp/tb_p2_badge.v 同一条经验）：每来一次写就比对一次，
//  并记录哪些格被写过 —— 影子内存那一版查不出"某格根本没写"。
//
//  五个用例（v44/㊶ 起标签末尾多写 "÷M"，M = 分频码 + 1）：
//    ① inter = 0,  div = 7 -> 编码 0 表示 ×256；分频码 7 = ÷8   ↩回到×256÷8
//    ② inter = 8,  div = 0 -> 一位数（数字左紧贴 ×）；÷1         ↩回到×8  ÷1
//    ③ inter = 64, div = 1 -> 两位数；÷2                        ↩回到×64 ÷2
//    ④ inter = 128,div = 2 -> 三位数；÷3                        ↩回到×128÷3
//    ⑤ avail = 0   -> 只写「回到」，位置与静态版面一致（46/47），其余格是空格
//
//  写作顺序也一并钉住：一格一拍、从第 46 格起递增 9 格（46..54），写完给一拍 done。
//=============================================================================
`timescale 1ns / 1ps

module tb_undo_lab;

    localparam [5:0] ROW  = 6'd34;        // 标签所在格行（与 undo_lab 的 LAB_ROW 同源）
    localparam [5:0] C0   = 6'd46;        // 标签带第一格
    localparam integer NW = 9;            // 每帧写 9 格（46..54）

    // 字符码（与 disp/undo_lab.v / tools/gen_font_rom.py 的顺序一致）
    localparam [7:0] CH_SP  = 8'd0;
    localparam [7:0] CH_RET = 8'd47;      // '↩'
    localparam [7:0] CH_HUI = 8'd135;     // '回'
    localparam [7:0] CH_DAO = 8'd136;     // '到'
    localparam [7:0] CH_MUL = 8'd45;      // '×'
    localparam [7:0] CH_DIV = 8'd46;      // '÷'（v44/㊶）
    localparam [7:0] CH_1   = 8'd9;       // '0' = 8
    localparam [7:0] CH_2   = 8'd10;
    localparam [7:0] CH_3   = 8'd11;
    localparam [7:0] CH_4   = 8'd12;
    localparam [7:0] CH_5   = 8'd13;
    localparam [7:0] CH_6   = 8'd14;
    localparam [7:0] CH_8   = 8'd16;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg avail = 1'b1;
    reg [9:0] inter = 10'd64;
    reg [2:0] div   = 3'd0;               // v44（㊶）：分频码 0..7 = ÷1..÷8

    always #10 clk = ~clk;               // 50 MHz

    wire        we;
    wire [11:0] waddr;
    wire [7:0]  wdata;
    wire        busy, done;

    undo_lab u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .avail(avail), .inter(inter), .div(div),
        .we(we), .waddr(waddr), .wdata(wdata),
        .busy(busy), .done(done)
    );

    integer errors = 0;
    integer ndone  = 0;                  // done 脉冲数
    integer nwr    = 0;                  // 本帧写次数

    // ---- 期望：本用例 9 格的字符码 + 是否应被写 ----
    reg [7:0] exp_cell [0:NW-1];
    reg       exp_we   [0:NW-1];         // avail=0 时该格应"根本不写"还是"写空格"

    reg       prev_done = 1'b0;

    // ---- 写口判据：每来一次写就比一次 ----
    //   地址 = {34, 列}，列 46..54 对应 k = 0..NW-1；写到带外本身就判错。
    //   （xsim 不允许在 always 里声明局部变量，中间量都用模块级 reg。）
    reg [5:0] wcol;
    reg [3:0] wk;
    reg       en_chk = 1'b0;

    always @(posedge clk) if (we && en_chk) begin
        nwr = nwr + 1;
        if (waddr[11:6] !== ROW) begin
            errors = errors + 1;
            $display("[FAIL] 写到别的格行：row %0d", waddr[11:6]);
        end else begin
            wcol = waddr[5:0];
            if ((wcol < C0) || (wcol > C0 + 6'd8)) begin
                errors = errors + 1;
                $display("[FAIL] 写到标签带之外：col %0d", wcol);
            end else begin
                wk = wcol - C0;                   // 46..54 -> k = 0..8
                if (wdata !== exp_cell[wk]) begin
                    errors = errors + 1;
                    $display("[FAIL] k=%0d col=%0d got %0d want %0d",
                             wk, wcol, wdata, exp_cell[wk]);
                end
                if (!exp_we[wk]) begin
                    errors = errors + 1;
                    $display("[FAIL] k=%0d 这一格不该被写（avail=0 的静态版面）", wk);
                end
                exp_we[wk] = 1'b0;                // 标记"已写过"
            end
        end
    end

    always @(posedge clk) begin
        if (done && !prev_done) ndone = ndone + 1;
        prev_done <= done;
    end

    // ---- 帧首单拍（与 disp/tb_p2_badge.v 的 pulse_start 同一写法）----
    task pulse_start;
    begin
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        repeat (20) @(negedge clk);
    end
    endtask

    // ---- 设定本用例期望并跑一帧 ----
    task run_case;
        input [8*32-1:0] tag;
        integer q;
        begin
            nwr   = 0;
            en_chk = 1'b1;
            pulse_start;
            en_chk = 1'b0;
            if (nwr != NW) begin
                errors = errors + 1;
                $display("[FAIL] %0s 写次数 %0d，期望 %0d", tag, nwr, NW);
            end
            for (q = 0; q < NW; q = q + 1) begin
                if (exp_we[q]) begin
                    errors = errors + 1;
                    $display("[FAIL] %0s 第 %0d 格没被写过", tag, q);
                end
            end
            $display("[info] %0s 写 %0d 次", tag, nwr);
        end
    endtask

    task set_expect;
        input [7:0] e0, e1, e2, e3, e4, e5, e6, e7, e8;
        begin
            exp_cell[0] = e0; exp_cell[1] = e1; exp_cell[2] = e2;
            exp_cell[3] = e3; exp_cell[4] = e4; exp_cell[5] = e5;
            exp_cell[6] = e6; exp_cell[7] = e7; exp_cell[8] = e8;
            exp_we[0] = 1'b1; exp_we[1] = 1'b1; exp_we[2] = 1'b1;
            exp_we[3] = 1'b1; exp_we[4] = 1'b1; exp_we[5] = 1'b1;
            exp_we[6] = 1'b1; exp_we[7] = 1'b1; exp_we[8] = 1'b1;
        end
    endtask

    initial begin
        set_expect(CH_SP, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ---- ① inter = 0（编码 0 = ×256，不是 ×0）、div = 7（÷8）----
        avail = 1'b1; inter = 10'd0; div = 3'd7;
        set_expect(CH_RET, CH_HUI, CH_DAO, CH_MUL, CH_2, CH_5, CH_6, CH_DIV, CH_8);
        run_case("① inter=0 -> ×256, div=7 -> ÷8");

        // ---- ② inter = 8：一位数；div = 0（÷1）----
        inter = 10'd8; div = 3'd0;
        set_expect(CH_RET, CH_HUI, CH_DAO, CH_MUL, CH_8, CH_SP, CH_SP, CH_DIV, CH_1);
        run_case("② inter=8 -> ×8, div=0 -> ÷1");

        // ---- ③ inter = 64：两位数；div = 1（÷2）----
        inter = 10'd64; div = 3'd1;
        set_expect(CH_RET, CH_HUI, CH_DAO, CH_MUL, CH_6, CH_4, CH_SP, CH_DIV, CH_2);
        run_case("③ inter=64 -> ×64, div=1 -> ÷2");

        // ---- ④ inter = 128：三位数；div = 2（÷3）----
        inter = 10'd128; div = 3'd2;
        set_expect(CH_RET, CH_HUI, CH_DAO, CH_MUL, CH_1, CH_2, CH_8, CH_DIV, CH_3);
        run_case("④ inter=128 -> ×128, div=2 -> ÷3");

        // ---- ⑤ avail = 0：只写「回到」（第 46/47 格），其余格写空格 ----
        //   位置与静态版面（text_ram.v 的 P1_LAB）同一个格，上电第一帧与
        //   之后的内容不会左右跳一格；写在带外的格一律判错。
        avail = 1'b0; inter = 10'd0; div = 3'd0;
        set_expect(CH_HUI, CH_DAO, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP, CH_SP);
        en_chk = 1'b1;
        nwr    = 0;
        pulse_start;
        en_chk = 1'b0;
        $display("[info] ⑤ avail=0 写 %0d 次（全部 9 格都写，只有前两格有字）", nwr);
        if (nwr != NW) begin
            errors = errors + 1;
            $display("[FAIL] avail=0 时写次数 %0d，期望 %0d", nwr, NW);
        end

        // ---- done / busy：5 个用例 + 复位后各给一次 done ----
        if (ndone < 5) begin
            errors = errors + 1;
            $display("[FAIL] done 脉冲只有 %0d 次（每个用例都该有一次）", ndone);
        end
        if (busy !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] 空闲时 busy 不是 0");
        end

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule
