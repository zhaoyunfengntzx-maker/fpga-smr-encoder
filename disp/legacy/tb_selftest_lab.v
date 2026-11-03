//=============================================================================
//  disp/tb_selftest_lab.v  --  P8「自检结果」结论的单元测试（直接例化 selftest_lab）
//
//  为什么直接测模块：屏上那两格的字是**运行期结论**（三个 IIC 计数算出来的），
//  走整机测试台要等 853,440 拍一帧、还要在层次里挖 p8_lab_ram 的写口；直接喂
//  reads / nack / timeout 就能把"三项判据 + 两种结论"逐项钉住。
//
//  判据放在**写口上**（与 disp/tb_undo_lab.v / tb_stat_chip.v 同一条经验）：
//  每来一次写就比一次，并记录哪些格被写过 —— 影子内存那一版查不出"某格根本没写"。
//
//  六个用例：
//    ① 读 1234 / 无应答 0 / 超时 0  -> 通过（通 159、过 160）
//    ② 读 0（IIC 停摆）             -> 失败（失 161、败 162）
//    ③ 读 100 / 无应答 3            -> 失败
//    ④ 读 100 / 超时 1              -> 失败
//    ⑤ 读 5 / 无应答 0 / 超时 0     -> 通过（结论能变回来，不是一次性的）
//    ⑥ hold 拉高 5 拍（band_view 占着写口）-> hold 期间 we 必须为 0，
//       放手后两格仍然全部写完（㉗/记录 53 的"被仲裁吃掉的写会静默消失"）
//
//  写作顺序也一并钉住：一格一拍、从第 36 格起递增，写完给一拍 done。
//=============================================================================
`timescale 1ns / 1ps

module tb_selftest_lab;

    localparam [5:0] ROW  = 6'd36;        // 底栏格行（与 selftest_lab 的 LAB_ROW 同源）
    localparam [5:0] C0   = 6'd36;        // 结论第一格
    localparam integer NW = 2;            // 每帧写 2 格

    // 字符码（与 disp/selftest_lab.v / tools/cn_glyphs.py 的顺序一致）
    localparam [7:0] CH_TONG = 8'd159;    // 通
    localparam [7:0] CH_GUO  = 8'd160;    // 过
    localparam [7:0] CH_SHI  = 8'd161;    // 失
    localparam [7:0] CH_BAI  = 8'd162;    // 败

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg hold = 1'b0;
    reg [23:0] reads = 24'd0;
    reg [23:0] nack = 24'd0;
    reg [23:0] timeout = 24'd0;

    always #10 clk = ~clk;               // 50 MHz

    wire        we;
    wire [11:0] waddr;
    wire [7:0]  wdata;
    wire        busy, done;

    selftest_lab u_dut (
        .clk(clk), .rst_n(rst_n), .start(start), .hold(hold),
        .reads(reads), .nack(nack), .timeout(timeout),
        .we(we), .waddr(waddr), .wdata(wdata),
        .busy(busy), .done(done)
    );

    integer errors = 0;
    integer ndone  = 0;                  // done 脉冲数
    integer nwr    = 0;                  // 本帧写次数
    integer nhold  = 0;                  // hold 期间 we 违规次数

    // ---- 期望：本用例 2 格的字符码 + 是否应被写 ----
    reg [7:0] exp_cell [0:NW-1];
    reg       exp_we   [0:NW-1];

    reg       prev_done = 1'b0;

    // ---- 写口判据：每来一次写就比一次 ----
    reg [5:0] wcol;
    reg [0:0] wk;
    reg       en_chk = 1'b0;

    always @(posedge clk) if (en_chk && hold && we) nhold = nhold + 1;

    always @(posedge clk) if (we && en_chk) begin
        nwr = nwr + 1;
        if (waddr[11:6] !== ROW) begin
            errors = errors + 1;
            $display("[FAIL] 写到别的格行：row %0d", waddr[11:6]);
        end else begin
            wcol = waddr[5:0];
            if ((wcol < C0) || (wcol > C0 + 6'd1)) begin
                errors = errors + 1;
                $display("[FAIL] 写到结论带之外：col %0d", wcol);
            end else begin
                wk = wcol[0:0];                   // 36/37 -> k = 0/1
                if (wdata !== exp_cell[wk]) begin
                    errors = errors + 1;
                    $display("[FAIL] k=%0d col=%0d got %0d want %0d",
                             wk, wcol, wdata, exp_cell[wk]);
                end
                if (!exp_we[wk]) begin
                    errors = errors + 1;
                    $display("[FAIL] k=%0d 这一格不该被写", wk);
                end
                exp_we[wk] = 1'b0;                // 标记"已写过"
            end
        end
    end

    always @(posedge clk) begin
        if (done && !prev_done) ndone = ndone + 1;
        prev_done <= done;
    end

    // ---- 帧首单拍（与 disp/tb_undo_lab.v 的 pulse_start 同一写法）----
    task pulse_start;
    begin
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        repeat (20) @(negedge clk);
    end
    endtask

    task set_expect;
        input [7:0] e0, e1;
        begin
            exp_cell[0] = e0; exp_cell[1] = e1;
            exp_we[0]   = 1'b1; exp_we[1]   = 1'b1;
        end
    endtask

    // ---- 设定本用例期望并跑一帧 ----
    task run_case;
        input [8*32-1:0] tag;
        integer q;
        begin
            nwr    = 0;
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

    initial begin
        set_expect(CH_TONG, CH_GUO);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ---- ① 链路正常 -> 通过 ----
        reads = 24'd1234; nack = 24'd0; timeout = 24'd0;
        set_expect(CH_TONG, CH_GUO);
        run_case("① 读1234/NAK0/TO0 -> 通过");

        // ---- ② IIC 停摆（读次数 0）-> 失败 ----
        reads = 24'd0; nack = 24'd0; timeout = 24'd0;
        set_expect(CH_SHI, CH_BAI);
        run_case("② 读0 -> 失败（IIC 停摆）");

        // ---- ③ 有不应答 -> 失败 ----
        reads = 24'd100; nack = 24'd3; timeout = 24'd0;
        set_expect(CH_SHI, CH_BAI);
        run_case("③ 读100/NAK3 -> 失败");

        // ---- ④ 有超时 -> 失败 ----
        reads = 24'd100; nack = 24'd0; timeout = 24'd1;
        set_expect(CH_SHI, CH_BAI);
        run_case("④ 读100/TO1 -> 失败");

        // ---- ⑤ 结论能变回来（不是一次性的）----
        reads = 24'd5; nack = 24'd0; timeout = 24'd0;
        set_expect(CH_TONG, CH_GUO);
        run_case("⑤ 读5/NAK0/TO0 -> 通过");

        // ---- ⑥ hold 仲裁：hold 期间 we 必须为 0，放手后两格仍全部写完 ----
        //   ㉗/记录 53 的教训：写口被别人占住时，寄存版的 we 会在下一拍被
        //   仲裁吃掉而 idx 照常推进 ⇒ 那一格永远不写。本模块 hold 期间既不写
        //   也不推进，所以下面这两个断言必须同时成立。
        reads = 24'd777; nack = 24'd0; timeout = 24'd0;
        set_expect(CH_TONG, CH_GUO);
        nwr    = 0;
        nhold  = 0;
        en_chk = 1'b1;
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        @(negedge clk); hold <= 1'b1;         // 帧首后立刻占住写口
        repeat (5) @(negedge clk);
        hold <= 1'b0;
        repeat (20) @(negedge clk);
        en_chk = 1'b0;
        if (nhold != 0) begin
            errors = errors + 1;
            $display("[FAIL] hold 期间 still we=1 出现了 %0d 次", nhold);
        end
        if (nwr != NW) begin
            errors = errors + 1;
            $display("[FAIL] ⑥ hold 之后写次数 %0d，期望 %0d（被仲裁吃掉）", nwr, NW);
        end
        if (exp_we[0] || exp_we[1]) begin
            errors = errors + 1;
            $display("[FAIL] ⑥ hold 之后第 0/1 格没写全：%b %b", exp_we[0], exp_we[1]);
        end
        $display("[info] ⑥ hold 5 拍 -> 写 %0d 次、hold 违规 %0d 次", nwr, nhold);

        // ---- done / busy：复位后 6 个用例各给一次 done ----
        if (ndone < 6) begin
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
