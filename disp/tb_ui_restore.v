//=============================================================================
//  tb_ui_restore.v —— 「恢复默认」命令序列 + 全序列回读确认 的定向台
//-----------------------------------------------------------------------------
//  这个台**不是**只看"13 条命令发出去了"，而是把整条链路闭起来：
//    ① 一个 2 Mbaud 的 UART 接收模型收下 dut 发的字节；
//    ② 一个**字节级寄存器模型**（2048 字节数组）按 uart_spi_bridge 的语义落盘：
//       b3 -> addr、b2 -> addr+1；
//    ③ dut 要回读的那 17 个 tap 字段**直接从模型里拼出来**（和 rtl/reg_file.v 的
//       位序一一对应）⇒ "写进去的"与"读回来的"是同一份数据，任何编码错误都会
//       在 state/bad 上现形。
//  三个方向都钉住：
//    [1] 空转：没启动时 state=0、busy=0、一个字节都不发
//    [2] 正例：先把 16 个寄存器写成"非默认值"，跑一遍 ⇒ 52 个字节**逐个**等于
//        黄金字节流、state=全一致、bad=0、模型里 16 个寄存器全部回到复位默认值
//    [3] 反例：把 0x0106（限幅）设成"写不进去"（stuck），再跑一遍 ⇒ state=有不
//        一致、bad **只有第 4 位**（= 限幅那一项）置位、其余 14 位为 0
//        ⇒ 证明 ✖ 能**指到具体是哪一项**，而不是笼统报"失败"
//    [4] 占用语义：序列期间 busy=1（UART mux 据此挡住上位机），结束后 busy=0
//=============================================================================
`timescale 1ns / 1ps

module tb_ui_restore;

    localparam integer CLK_HALF = 10;          // 20 ns = 50 MHz
    localparam integer BIT_NS   = CLK_HALF * 2 * 25;   // 1 个位 = 25 clk = 500 ns

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    integer errors = 0;

    task chk_true;
        input [8*56-1:0] label;
        input            cond;
        begin
            if (cond) $display("[ OK ] %0s", label);
            else begin
                $display("[FAIL] %0s", label);
                errors = errors + 1;
            end
        end
    endtask

    task chki;
        input [8*56-1:0] label;
        input integer    got;
        input integer    want;
        begin
            if (got === want) $display("[ OK ] %0s = %0d", label, got);
            else begin
                $display("[FAIL] %0s : got %0d want %0d", label, got, want);
                errors = errors + 1;
            end
        end
    endtask

    //=========================================================================
    // 字节级寄存器模型（2048 字节 = 11 位地址空间）
    //=========================================================================
    reg [7:0] rby [0:2047];
    reg       stuck_106 = 1'b0;                // 1 = 0x0106 写不进去（反例用）

    // 17 个 tap 字段（位序与 rtl/reg_file.v 的 disp_tap 解包一致）
    wire [4:0]  m_pairs   = rby[11'h100][4:0];
    wire [9:0]  m_inter   = {rby[11'h102][1:0], rby[11'h101]};
    wire [2:0]  m_div     = rby[11'h102][4:2];
    wire [4:0]  m_hyst_ab = rby[11'h103][4:0];
    wire [7:0]  m_ablimit = rby[11'h106];
    wire [3:0]  m_zwidth  = rby[11'h108][3:0];
    wire [11:0] m_zphase  = {rby[11'h10A], rby[11'h10C][1:0]};
    wire [15:0] m_uvwph   = {rby[11'h10B], rby[11'h10C][3:2]};
    wire [3:0]  m_pol     = rby[11'h109][3:0];
    wire        m_abzen   = rby[11'h109][6];
    wire        m_uwven   = rby[11'h109][7];
    wire [3:0]  m_shift   = rby[11'h51A][3:0];
    wire [15:0] m_ofs_s   = {rby[11'h511], rby[11'h510]};
    wire [15:0] m_ofs_c   = {rby[11'h513], rby[11'h512]};
    wire [15:0] m_gain_s  = {rby[11'h515], rby[11'h514]};
    wire [15:0] m_gain_c  = {rby[11'h517], rby[11'h516]};
    wire [15:0] m_phase_k = {rby[11'h519], rby[11'h518]};

    //=========================================================================
    // 被测模块
    //=========================================================================
    reg         start = 1'b0;
    wire        tx_line, busy, done;
    wire [1:0]  state;
    wire [14:0] bad;

    // （v42/㊴）GAP_CLK 用**生产值** 25_000（500 µs，见 disp/ui_restore.v 头注释）：
    //   本台是"无桥"的字节级模型，间隔长短不影响任何判据，但留一个与生产值不同的
    //   旧常数（80 µs）会让人以为序列跑得比实际快 —— 而 80 µs 正是 ㊴ 抓到的
    //   真缺陷（命令整条被 uart_spi_bridge 的 SPI+应答窗口吞掉，见端到端台第 11 段
    //   的 cmd_gap_min / cs_bad 两条判据）。参数与 enc_top_disp 的例化保持同值。
    ui_restore #(
        .BAUD_DIV   (25),
        .GAP_CLK    (25_000),
        .SETTLE_CLK (100_000)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .tap_pairs  (m_pairs),
        .tap_inter  (m_inter),
        .tap_div    (m_div),
        .tap_hyst_ab(m_hyst_ab),
        .tap_ablimit(m_ablimit),
        .tap_zwidth (m_zwidth),
        .tap_zphase (m_zphase),
        .tap_uvwph  (m_uvwph),
        .tap_pol    (m_pol),
        .tap_abzen  (m_abzen),
        .tap_uwven  (m_uwven),
        .tap_shift  (m_shift),
        .tap_ofs_s  (m_ofs_s),
        .tap_ofs_c  (m_ofs_c),
        .tap_gain_s (m_gain_s),
        .tap_gain_c (m_gain_c),
        .tap_phase_k(m_phase_k),
        .tx_line    (tx_line),
        .busy       (busy),
        .done       (done),
        .state      (state),
        .bad        (bad)
    );

    //=========================================================================
    // UART 接收模型 + 命令落盘（b0 b1 b2 b3 -> addr/addr+1）
    //=========================================================================
    reg [7:0] cap [0:63];          // 抓到的字节流（最多 64 个）
    integer   ncap = 0;
    reg [7:0] cb0, cb1, cb2, cb3;
    integer   bi = 0;

    task uart_get_byte;
        output [7:0] b;
        integer k;
        begin
            @(negedge tx_line);                 // 起始位
            #(CLK_HALF * 2 * 25 + CLK_HALF * 2 / 2);   // 跳到第 1 个数据位中心
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = tx_line;
                #(BIT_NS);
            end
            #(BIT_NS);                          // 停位
        end
    endtask

    //   把一条命令落进模型（与 rtl/uart_spi_bridge.v 同语义：低字节 -> addr）
    //   ★ 地址是 **11 位**：b0 的低 3 位是 addr[10:8]（page），b1 是 addr[7:0] ——
    //     只拿 b1 会把它当成 0x000 区（第一版就是这么错的，全部写歪）。
    task apply_cmd;
        reg [10:0] a;
        begin
            a = {cb0[2:0], cb1};
            if (!(stuck_106 && (a == 11'h106))) rby[a] = cb3;
            if (!(stuck_106 && ((a + 11'd1) == 11'h106))) rby[a + 11'd1] = cb2;
        end
    endtask

    initial begin : rx_loop
        forever begin
            uart_get_byte(cb0);
            cap[ncap] = cb0;  ncap = ncap + 1;
            uart_get_byte(cb1);
            cap[ncap] = cb1;  ncap = ncap + 1;
            uart_get_byte(cb2);
            cap[ncap] = cb2;  ncap = ncap + 1;
            uart_get_byte(cb3);
            cap[ncap] = cb3;  ncap = ncap + 1;
            apply_cmd;
        end
    end

    //=========================================================================
    // 黄金字节流：13 条命令 x 4 字节
    //=========================================================================
    reg [7:0] gold [0:103];
    integer   g;
    task gold_init;
        begin
            for (g = 0; g < 104; g = g + 1) gold[g] = 8'hFF;
            // cmd 0: 0x0100 <- 0x0004
            gold[ 0]=8'h89; gold[ 1]=8'h00; gold[ 2]=8'h00; gold[ 3]=8'h04;
            // cmd 1: 0x0101 <- 0x0000
            gold[ 4]=8'h89; gold[ 5]=8'h01; gold[ 6]=8'h00; gold[ 7]=8'h00;
            // cmd 2: 0x0102 <- 0x0000
            gold[ 8]=8'h89; gold[ 9]=8'h02; gold[10]=8'h00; gold[11]=8'h00;
            // cmd 3: 0x0106 <- 0x0A00 （低字节 0x00 进 0x0106、高字节 0x0A 进 0x0107）
            gold[12]=8'h89; gold[13]=8'h06; gold[14]=8'h0A; gold[15]=8'h00;
            // cmd 4: 0x0108 <- 0x4000
            gold[16]=8'h89; gold[17]=8'h08; gold[18]=8'h40; gold[19]=8'h00;
            // cmd 5: 0x010A <- 0x0000
            gold[20]=8'h89; gold[21]=8'h0A; gold[22]=8'h00; gold[23]=8'h00;
            // cmd 6: 0x010C <- 0x0000
            gold[24]=8'h89; gold[25]=8'h0C; gold[26]=8'h00; gold[27]=8'h00;
            // cmd 7: 0x0510 <- 0x0000
            gold[28]=8'h8D; gold[29]=8'h10; gold[30]=8'h00; gold[31]=8'h00;
            // cmd 8: 0x0512 <- 0x0000
            gold[32]=8'h8D; gold[33]=8'h12; gold[34]=8'h00; gold[35]=8'h00;
            // cmd 9: 0x0514 <- 0x8000（GAIN_S = 32768）
            gold[36]=8'h8D; gold[37]=8'h14; gold[38]=8'h80; gold[39]=8'h00;
            // cmd 10: 0x0516 <- 0x8000
            gold[40]=8'h8D; gold[41]=8'h16; gold[42]=8'h80; gold[43]=8'h00;
            // cmd 11: 0x0518 <- 0x0000
            gold[44]=8'h8D; gold[45]=8'h18; gold[46]=8'h00; gold[47]=8'h00;
            // cmd 12: 0x051A <- 0x0000
            gold[48]=8'h8D; gold[49]=8'h1A; gold[50]=8'h00; gold[51]=8'h00;
        end
    endtask

    //=========================================================================
    // 把 16 个受测寄存器写成"非默认值"（正例的起点）
    //=========================================================================
    task dirty_all;
        begin
            rby[11'h100] = 8'h07;              // 极对数 = 7（默认 4）
            rby[11'h101] = 8'h7B;              // INTER0 = 123（默认 0）
            rby[11'h102] = 8'h15;              // INTER1 = {2'd0, div=5}（默认 0）
            rby[11'h103] = 8'h09;              // 迟滞 = 9
            rby[11'h106] = 8'h55;              // 限幅 = 0x55
            rby[11'h107] = 8'h00;              // ZERO0 = 0（默认 0x0A，也顺手写脏）
            rby[11'h108] = 8'h06;              // Z 脉宽 = 6
            rby[11'h109] = 8'h8A;              // OUTPUT：uwven=1, abzen=0, pol=0xA
            rby[11'h10A] = 8'h33;              // ZPHASE[9:2]
            rby[11'h10B] = 8'h12;              // UVWPH[9:2]
            rby[11'h10C] = 8'h0F;              // 相位低位：z=3, uvw=3
            rby[11'h510] = 8'h11; rby[11'h511] = 8'h11;
            rby[11'h512] = 8'h22; rby[11'h513] = 8'h22;
            rby[11'h514] = 8'h00; rby[11'h515] = 8'h10;   // GAIN_S = 0x1000
            rby[11'h516] = 8'h00; rby[11'h517] = 8'h20;   // GAIN_C = 0x2000
            rby[11'h518] = 8'h00; rby[11'h519] = 8'h08;   // PHASE_K = 0x0800
            rby[11'h51A] = 8'h09;              // SHIFT = 9
            rby[11'h51B] = 8'h03;              // H2_K（邻居，也写脏）
        end
    endtask

    //=========================================================================
    // 主流程
    //=========================================================================
    integer tmo;
    integer k;
    integer nbad;

    task run_seq;
        input [8*48-1:0] label;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            tmo = 0;
            while (!done && (tmo < 2_000_000)) begin
                @(negedge clk);
                tmo = tmo + 1;
            end
            if (tmo >= 2_000_000) begin
                $display("[FAIL] %0s : 等 done 超时", label);
                errors = errors + 1;
            end
            @(negedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        gold_init;
        for (k = 0; k < 2048; k = k + 1) rby[k] = 8'h00;
        dirty_all;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ---------------- [1] 空转 ----------------
        chki("1 空闲时 state = 0（还没做过）", state, 0);
        chk_true("1 空闲时 busy = 0（不占 UART）", busy === 1'b0);
        chk_true("1 空闲时 tx 线为高（等同直连）", tx_line === 1'b1);
        chki("1 空闲时没有发出任何字节", ncap, 0);

        // ---------------- [2] 正例 ----------------
        run_seq("2a 正例：序列跑完");
        chki("2b 正例：state = 1（全一致）", state, 1);
        chki("2c 正例：bad = 0（15 项全部回读上）", bad, 0);
        chk_true("2d 正例：序列结束后 busy = 0（放开 UART）", busy === 1'b0);
        chki("2e 正例：一共发了 52 个字节（13 条 x 4）", ncap, 52);
        begin : gold_chk
            integer gb;
            integer gbad;
            gbad = 0;
            for (gb = 0; gb < 52; gb = gb + 1) begin
                if (cap[gb] !== gold[gb]) begin
                    if (gbad < 4)
                        $display("[FAIL] 2f 字节 %0d = %h, want %h", gb, cap[gb], gold[gb]);
                    gbad = gbad + 1;
                end
            end
            chki("2f 正例：52 个字节逐个等于黄金字节流", gbad, 0);
        end
        // 模型里 16 个寄存器是否回到复位默认值
        begin : model_chk
            integer mb;
            mb = 0;
            if (rby[11'h100] !== 8'h04) mb = mb + 1;
            if (rby[11'h101] !== 8'h00) mb = mb + 1;
            if (rby[11'h102] !== 8'h00) mb = mb + 1;
            if (rby[11'h103] !== 8'h00) mb = mb + 1;
            if (rby[11'h106] !== 8'h00) mb = mb + 1;
            if (rby[11'h107] !== 8'h0A) mb = mb + 1;
            if (rby[11'h108] !== 8'h00) mb = mb + 1;
            if (rby[11'h109] !== 8'h40) mb = mb + 1;
            if (rby[11'h10A] !== 8'h00) mb = mb + 1;
            if (rby[11'h10B] !== 8'h00) mb = mb + 1;
            if (rby[11'h10C] !== 8'h00) mb = mb + 1;
            if (rby[11'h510] !== 8'h00 || rby[11'h511] !== 8'h00) mb = mb + 1;
            if (rby[11'h512] !== 8'h00 || rby[11'h513] !== 8'h00) mb = mb + 1;
            if (rby[11'h514] !== 8'h00 || rby[11'h515] !== 8'h80) mb = mb + 1;
            if (rby[11'h516] !== 8'h00 || rby[11'h517] !== 8'h80) mb = mb + 1;
            if (rby[11'h518] !== 8'h00 || rby[11'h519] !== 8'h00) mb = mb + 1;
            if (rby[11'h51A] !== 8'h00) mb = mb + 1;
            if (rby[11'h51B] !== 8'h00) mb = mb + 1;
            chki("2g 正例：模型里 16 个寄存器全部回到复位默认值", mb, 0);
        end

        // ---------------- [3] 反例（0x0106 写不进去）----------------
        dirty_all;
        ncap = 0;
        stuck_106 = 1'b1;
        run_seq("3a 反例：序列跑完");
        chki("3b 反例：state = 2（有不一致）", state, 2);
        chki("3c 反例：bad 只有第 4 位（限幅）置位", bad, 15'h0010);
        chk_true("3d 反例：bad 第 4 位确实是 1", bad[4] === 1'b1);
        nbad = 0;
        for (k = 0; k < 15; k = k + 1) if ((k != 4) && bad[k]) nbad = nbad + 1;
        chki("3e 反例：其余 14 项都没有被误报", nbad, 0);
        chki("3f 反例：这一次仍然发了 52 个字节", ncap, 52);
        stuck_106 = 1'b0;

        // ---------------- [4] 再跑一次正例（确认可以从失败态恢复）----------------
        dirty_all;
        ncap = 0;
        run_seq("4a 复位刺后重跑");
        chki("4b 重跑后 state = 1（绿）", state, 1);
        chki("4c 重跑后 bad = 0", bad, 0);

        // ---------------- 结论 ----------------
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 看门狗（v42/㊴：GAP_CLK 抬到 500 µs 后一条序列 ≈ 8.8 ms，本台跑三遍
    //   （正例 / 反例 / 去刺重跑）⇒ 约 27 ms，兜底取 150 ms）
    initial begin
        #150_000_000;                     // 150 ms
        $display("[FAIL] 看门狗超时（序列没有收尾）");
        $display("TEST FAILED: 1 errors");
        $finish;
    end

endmodule
