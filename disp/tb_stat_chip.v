//=============================================================================
//  disp/tb_stat_chip.v  --  P1 六张卡迷你状态条的单元测试（直接例化 stat_chip）
//
//  为什么直接测模块：状态字与状态词全是**运行期判据**（io_flags/stat 的某一位），
//  走整机测试台要等 853,440 拍一帧、还要在层次里挖 p1_lab_ram 的写口；直接喂
//  io_flags/stat 就能把「六张卡的判据表 + 优先级 + hold 仲裁」逐项钉住。
//
//  判据放在**写口上**（与 disp/tb_undo_lab.v 同一条经验）：每来一次写就比对一次
//  地址与字符码，并记录 24 格各被写过 —— 影子内存那一版查不出"某格根本没写"。
//
//  十六个用例：
//    ① io_flags=0x30（ABZ/UVW 都使能）stat=0        -> 六张卡全 ●正常
//    ② +lag_fatal(bit1)                             -> 卡 1 ✖故障
//    ③ +lag_warn(bit0)                              -> 卡 1 ▲警示
//    ④ stat bit3 inclim                             -> 卡 2 ▲警示
//    ⑤ +amp_bad(bit7)                               -> 卡 3 ✖故障
//    ⑥ stat bit5 scamp                              -> 卡 3 ▲警示
//    ⑦ +cor_sat(bit6)                               -> 卡 4 ✖故障
//    ⑧ stat bit0 oflow（otr_lat 走这一位）          -> 卡 4 ▲警示
//    ⑨ stat bit2 laglim                             -> 卡 5 ▲警示
//    ⑩ io_flags=0x00（ABZ/UVW 都没使能）            -> 卡 6 ✖故障，其余 ●正常
//    ⑪ io_flags=0x10（只关 UVW）                    -> 卡 6 ▲警示
//    ⑫ +uvw_warn(bit3)                              -> 卡 6 ▲警示
//    ⑬ 三张卡同时故障（lag_fatal+amp_bad+cor_sat）  -> 卡 1/3/4 故障，卡 2/5/6 正常
//    ⑭ hold 仲裁：帧首把写口按住 12 拍             -> 按住期间 we 必须为 0，
//                                                     松开后 24 格仍全部写完
//    ⑮（不跑帧）换卡后 wdata 跟着遥测走（记录 53 的回归）
//    ⑯ v45（㊷）空态 sig_bad=1                      -> 卡 1/3/4/5 故障，卡 2/6 不变
//    ⑰ 空态优先级：sig_bad=1 且 lag_warn=1          -> 卡 1 仍是故障
//
//  写作顺序也一并钉住：一格一拍、从卡 1 的第 0 格起到卡 6 的第 3 格止，写完给
//  一拍 done；chip_st 探针在每帧结束后比对六个 2 bit 状态。
//=============================================================================
`timescale 1ns / 1ps

module tb_stat_chip;

    // v59（2 列 × 3 行卡片墙）：状态条格行 7/19/31，格列 32/62
    localparam [5:0] ROW_0 = 6'd7, ROW_1 = 6'd19, ROW_2 = 6'd31;
    localparam [5:0] COL_0 = 6'd30, COL_1 = 6'd60;
    localparam integer NW = 24;           // 每帧写 24 格

    // 字符码（与 disp/stat_chip.v / tools/gen_font_rom.py 的顺序一致）
    localparam [7:0] CH_SP    = 8'd0;
    localparam [7:0] CH_OK    = 8'd48;    // ●
    localparam [7:0] CH_WARN  = 8'd49;    // ▲
    localparam [7:0] CH_FAULT = 8'd50;    // ✖
    localparam [7:0] CH_ZHENG = 8'd134;   // 正
    localparam [7:0] CH_CHANG = 8'd135;   // 常
    localparam [7:0] CH_JING  = 8'd136;   // 警
    localparam [7:0] CH_SHI   = 8'd137;   // 示
    localparam [7:0] CH_GU    = 8'd97;    // 故
    localparam [7:0] CH_ZHANG = 8'd98;    // 障

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [7:0] io_flags = 8'h30;
    reg [7:0] stat = 8'h00;
    reg [5:0] bad_mask = 6'd0;          // v60/R1：每卡一位空态            // v45（㊷）空态：信号不可信（无载波）
    reg hold = 1'b0;

    always #10 clk = ~clk;               // 50 MHz

    wire        we;
    wire [11:0] waddr;
    wire [7:0]  wdata;
    wire        busy, done;
    wire [11:0] chip_st;

    stat_chip u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .io_flags(io_flags), .stat(stat), .hold(hold), .bad_mask(bad_mask),
        .chip_st(chip_st),
        .we(we), .waddr(waddr), .wdata(wdata),
        .busy(busy), .done(done)
    );

    integer errors = 0;
    integer ndone  = 0;
    integer nwr    = 0;
    reg       prev_done = 1'b0;

    // ---- 期望：六张卡各自的状态（0=正常 1=警示 2=故障）----
    reg [1:0] exp_st [0:5];
    reg       seen   [0:5][0:3];         // 24 格各被写过没有

    // ---- 写口判据用的模块级中间量（xsim 不允许在 always 里声明局部变量）----
    reg [5:0]  wrow, wcol;
    reg [2:0]  chip_i;
    reg [1:0]  cell_i;
    reg [5:0]  base_c;
    reg [7:0]  want;
    integer    q, c;

    function [7:0] sym_of;
        input [1:0] s;
        begin
            sym_of = (s == 2'd0) ? CH_OK : (s == 2'd1) ? CH_WARN : CH_FAULT;
        end
    endfunction

    function [7:0] word_of;
        input [1:0] s;
        input       hi;
        begin
            case (s)
                2'd0:    word_of = hi ? CH_CHANG : CH_ZHENG;
                2'd1:    word_of = hi ? CH_SHI   : CH_JING;
                default: word_of = hi ? CH_ZHANG : CH_GU;
            endcase
        end
    endfunction

    function [7:0] expect_cell;
        input [2:0] ci;
        input [1:0] k;
        begin
            expect_cell = (k == 2'd0) ? sym_of(exp_st[ci]) :
                          (k == 2'd1) ? CH_SP :
                          (k == 2'd2) ? word_of(exp_st[ci], 1'b0) :
                                        word_of(exp_st[ci], 1'b1);
        end
    endfunction

    // ---- 写口判据 ----
    always @(posedge clk) begin
        // hold 期间绝不允许写（写口冲突）
        if (we && hold) begin
            errors = errors + 1;
            $display("[FAIL] hold=1 的拍上仍在写（写口冲突）");
        end
        if (we) begin
            nwr = nwr + 1;
            wrow = waddr[11:6];
            wcol = waddr[5:0];
            if (wrow === ROW_0 || wrow === ROW_1 || wrow === ROW_2) begin
                chip_i = (wrow === ROW_0) ? 3'd0 : (wrow === ROW_1) ? 3'd2 : 3'd4;
                if (wcol >= COL_1) begin base_c = COL_1; chip_i = chip_i + 3'd1; end
                else               begin base_c = COL_0; end
            end else begin
                errors = errors + 1;
                $display("[FAIL] 写到别的格行：row %0d col %0d", wrow, wcol);
                chip_i = 3'd0; base_c = COL_0;
            end
            cell_i = wcol - base_c;
            if (cell_i > 2'd3) begin
                errors = errors + 1;
                $display("[FAIL] 写到状态条带之外：row %0d col %0d", wrow, wcol);
            end else begin
                want = expect_cell(chip_i, cell_i);
                if (wdata !== want) begin
                    errors = errors + 1;
                    $display("[FAIL] 卡 %0d 第 %0d 格 got %0d want %0d（状态 %0d）",
                             chip_i + 1, cell_i, wdata, want, exp_st[chip_i]);
                end
                seen[chip_i][cell_i] = 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (done && !prev_done) ndone = ndone + 1;
        prev_done <= done;
    end

    task pulse_start;
    begin
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        repeat (60) @(negedge clk);
    end
    endtask

    // hold 仲裁：帧首把写口按住 HOLD_N 拍再松开
    task pulse_start_hold;
        input integer hold_n;
    begin
        @(negedge clk); start <= 1'b1; hold <= 1'b1;
        @(negedge clk); start <= 1'b0;
        repeat (hold_n) @(negedge clk);
        hold <= 1'b0;
        repeat (80) @(negedge clk);
    end
    endtask

    task clr_case;
    begin
        nwr = 0;
        for (c = 0; c < 6; c = c + 1)
            for (q = 0; q < 4; q = q + 1) seen[c][q] = 1'b0;
    end
    endtask

    task check_case;
        input [8*40-1:0] tag;
        integer k;
    begin
        if (nwr != NW) begin
            errors = errors + 1;
            $display("[FAIL] %0s 写次数 %0d，期望 %0d", tag, nwr, NW);
        end
        for (c = 0; c < 6; c = c + 1) begin
            for (k = 0; k < 4; k = k + 1) begin
                if (!seen[c][k]) begin
                    errors = errors + 1;
                    $display("[FAIL] %0s 卡 %0d 第 %0d 格没被写过", tag, c + 1, k);
                end
            end
            if (chip_st[2*c +: 2] !== exp_st[c]) begin
                errors = errors + 1;
                $display("[FAIL] %0s 卡 %0d chip_st=%0d 期望 %0d",
                         tag, c + 1, chip_st[2*c +: 2], exp_st[c]);
            end
        end
        $display("[info] %0s 写 %0d 次，六卡状态 {%0d,%0d,%0d,%0d,%0d,%0d}",
                 tag, nwr, exp_st[0], exp_st[1], exp_st[2], exp_st[3], exp_st[4], exp_st[5]);
    end
    endtask

    task run_case;
        input [8*40-1:0] tag;
    begin
        pulse_start;
        check_case(tag);
    end
    endtask

    task set_st;
        input [1:0] s0, s1, s2, s3, s4, s5;
    begin
        exp_st[0] = s0; exp_st[1] = s1; exp_st[2] = s2;
        exp_st[3] = s3; exp_st[4] = s4; exp_st[5] = s5;
    end
    endtask

    localparam [1:0] OK = 2'd0, WN = 2'd1, FL = 2'd2;

    initial begin
        for (c = 0; c < 6; c = c + 1)
            for (q = 0; q < 4; q = q + 1) seen[c][q] = 1'b0;
        set_st(OK, OK, OK, OK, OK, OK);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ① 全正常（ABZ/UVW 都使能，状态字 0）
        io_flags = 8'h30; stat = 8'h00;
        set_st(OK, OK, OK, OK, OK, OK);
        clr_case; run_case("① 全正常");

        // ② 卡 1 滞后致命 -> 故障
        io_flags = 8'h32; stat = 8'h00;
        set_st(FL, OK, OK, OK, OK, OK);
        clr_case; run_case("② lag_fatal -> 卡1 故障");

        // ③ 卡 1 滞后告警 -> 警示
        io_flags = 8'h31; stat = 8'h00;
        set_st(WN, OK, OK, OK, OK, OK);
        clr_case; run_case("③ lag_warn -> 卡1 警示");

        // ④ 卡 2 限频/UVW 频率告警（stat bit3）-> 警示
        io_flags = 8'h30; stat = 8'h08;
        set_st(OK, WN, OK, OK, OK, OK);
        clr_case; run_case("④ stat.inclim -> 卡2 警示");

        // ⑤ 卡 3 幅值坏 -> 故障
        io_flags = 8'hB0; stat = 8'h00;
        set_st(OK, OK, FL, OK, OK, OK);
        clr_case; run_case("⑤ amp_bad -> 卡3 故障");

        // ⑥ 卡 3 幅值越限（stat bit5）-> 警示
        io_flags = 8'h30; stat = 8'h20;
        set_st(OK, OK, WN, OK, OK, OK);
        clr_case; run_case("⑥ stat.scamp -> 卡3 警示");

        // ⑦ 卡 4 校正饱和 -> 故障
        io_flags = 8'h70; stat = 8'h00;
        set_st(OK, OK, OK, FL, OK, OK);
        clr_case; run_case("⑦ cor_sat -> 卡4 故障");

        // ⑧ 卡 4 溢出（stat bit0 含 otr_lat）-> 警示
        io_flags = 8'h30; stat = 8'h01;
        set_st(OK, OK, OK, WN, OK, OK);
        clr_case; run_case("⑧ stat.oflow -> 卡4 警示");

        // ⑨ 卡 5 限频/滞后（stat bit2）-> 警示
        io_flags = 8'h30; stat = 8'h04;
        set_st(OK, OK, OK, OK, WN, OK);
        clr_case; run_case("⑨ stat.laglim -> 卡5 警示");

        // ⑩ ABZ 与 UVW 都没使能 -> 卡 6 故障，其余正常
        io_flags = 8'h00; stat = 8'h00;
        set_st(OK, OK, OK, OK, OK, FL);
        clr_case; run_case("⑩ ABZ/UVW 全关 -> 卡6 故障");

        // ⑪ 只关 UVW -> 卡 6 警示
        io_flags = 8'h10; stat = 8'h00;
        set_st(OK, OK, OK, OK, OK, WN);
        clr_case; run_case("⑪ 只关 UVW -> 卡6 警示");

        // ⑫ UVW 频率告警（io_flags bit3）-> 卡 6 警示
        io_flags = 8'h38; stat = 8'h00;
        set_st(OK, OK, OK, OK, OK, WN);
        clr_case; run_case("⑫ uvw_warn -> 卡6 警示");

        // ⑬ 三张卡同时故障（验证"每张卡各看自己的位"，不是全局一个灯）
        io_flags = 8'hF2; stat = 8'h00;
        set_st(FL, OK, FL, FL, OK, OK);
        clr_case; run_case("⑬ 三卡同时故障");

        // ⑭ hold 仲裁：帧首按住写口 12 拍，按住期间 we 必须为 0，松开后 24 格仍全写完
        io_flags = 8'h30; stat = 8'h00;
        set_st(OK, OK, OK, OK, OK, OK);
        clr_case;
        pulse_start_hold(12);
        check_case("⑭ hold 12 拍");

        // ⑮ 写数据对遥测的灵敏度（U-31 / 记录 53 的回归；**不跑帧**，所以不动 ndone）
        //   坑：cell_at() 若在函数体里读模块级 cst，`assign wdata = cell_at(cellk)`
        //   的灵敏度就只由**实参** cellk 决定 ⇒ 改遥测后 wdata 停在旧状态上。屏上的
        //   现象是"字形格慢一张卡"（端到端 [11] 段就是这么抓到的；本台因为同拍竞争的
        //   结局不同，14 个用例全过也照样漏掉它）。
        //   这里不靠竞争结局：把 idx 顶到卡 6 的第 0 格（cellk=0），改遥测让卡 1 故障，
        //   再把 idx 顶到卡 1 的第 0 格 —— **cellk 没变**，只有 cst 变了，wdata 必须跟。
        io_flags = 8'h30; stat = 8'h00;          // 六卡全正常
        repeat (2) @(negedge clk);
        @(negedge clk); u_dut.idx = 5'd20;       // 卡 6 / 第 0 格（cellk=0）
        io_flags = 8'h32;                        // 卡 1 → 故障（lag_fatal），卡 6 仍正常
        #1;
        @(negedge clk); u_dut.idx = 5'd0;        // 卡 1 / 第 0 格（cellk=0，没变）
        #1;
        if (waddr !== {6'd7, 6'd30}) begin
            errors = errors + 1;
            $display("[FAIL] ⑮ 卡 1 第 0 格的写地址 %h 不对（want 1de）", waddr);
        end
        if (wdata !== CH_FAULT) begin
            errors = errors + 1;
            $display("[FAIL] ⑮ 换卡后 wdata 停在旧状态：got %0d want %0d（卡 1 已故障）",
                     wdata, CH_FAULT);
        end else $display("[ OK ] ⑮ 换卡后 wdata 跟着状态走（字形格 %0d）", wdata);
        io_flags = 8'h30;                        // 卡 1 回正常，cellk 仍然没变
        #1;
        if (wdata !== CH_OK) begin
            errors = errors + 1;
            $display("[FAIL] ⑮ 遥测回正常后 wdata 仍是 %0d（want %0d）", wdata, CH_OK);
        end else $display("[ OK ] ⑮ 遥测回正常后 wdata 跟着回到 %0d", wdata);
        u_dut.idx = 5'd0;                        // 还原

        // ⑯ v45（㊷）空态：信号不可信 ⇒ **四个测量卡**（1/3/4/5）故障；
        //   卡 2（倍频分频 = 配置回读）与卡 6（ABZ/UVW = 使能状态）与输入可不可信无关，
        //   必须**不受 sig_bad 影响** —— 否则屏上再也说不出"现在配的是多少、线是什么"。
        io_flags = 8'h30; stat = 8'h00; bad_mask = 6'b011111;
        set_st(FL, OK, FL, FL, FL, OK);
        clr_case; run_case("⑯ sig_bad -> 四测量卡故障，卡2/卡6 不变");

        // ⑰ 优先级：卡 1 本来只是"滞后告警"，空态下必须是**故障**（故障 > 警示）
        io_flags = 8'h31; stat = 8'h00; bad_mask = 6'b011111;
        set_st(FL, OK, FL, FL, FL, OK);
        clr_case; run_case("⑰ sig_bad 压过 lag_warn");

        bad_mask = 6'd0;                        // 复原，别影响后面的判据

        // ---- done / busy ----
        if (ndone < 16) begin
            errors = errors + 1;
            $display("[FAIL] done 脉冲只有 %0d 次（16 个跑帧用例每个都该有一次）", ndone);
        end
        if (busy !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] 空闲时 busy 不是 0");
        end
        if (hold !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] 用例结束后 hold 没有松开");
        end

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule
