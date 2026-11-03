//=============================================================================
//  tb_uart_baud.v —— 验证"字节起始间隔 = 10*BAUD_DIV + 2"与 BAUD_DIV 无关
//-----------------------------------------------------------------------------
//  为什么需要这个测试台
//  --------------------
//  sim/tb_uart_scope.v 为了跑得快，把 BAUD_DIV 从真实值 25 降到 4，于是每字节
//  只占 40 clk、每帧只占约 754 clk。该台实测"相邻两次 tx_start 的间隔恒为
//  10*BAUD_DIV + 2 = 42 clk"，但 42 这个数是在 BAUD_DIV=4 下量的。
//
//  真实硬件 BAUD_DIV = 25（rtl/uart_scope.v:132，50 MHz / 25 = 2 Mbaud），
//  每字节 250 clk、每帧 18*250 = 4500 clk = 90 µs。如果那"多出的 2 clk"其实
//  与 BAUD_DIV 成比例（拟合假象），真机上的字节间隔就不是 252 clk，帧率与
//  UART 吞吐估算都要重算。
//
//  做法：同一时刻例化 4 个 uart_scope，BAUD_DIV 分别 = 4 / 7 / 10 / 25，
//  各自接同一个 clk，各自给自己的 latch。逐个量：
//        bit_period    == BAUD_DIV          （位周期精确，波特率无误差）
//        byte_interval == 10*BAUD_DIV + 2   （固定 FSM 开销，与 BAUD_DIV 无关）
//        (elapsed - 1) % (10*BAUD_DIV + 2) == 0   （一帧内 17 个间隔全等）
//
//  其中 BAUD_DIV=25 就是上板真实值，因此本台同时给出真机的字节间隔结论。
//=============================================================================
`timescale 1ns/1ps
module tb_uart_baud;

    localparam integer CLK_PD = 20;          // 50 MHz

    integer checks = 0, errors = 0;

    task chk_int;
        input integer    got;
        input integer    want;
        input [8*78-1:0] name;
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display(" [FAIL] %0s : got %0d, want %0d", name, got, want);
            end
        end
    endtask

    //------------------------------------------------------------------
    //  时钟与共同复位
    //------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_PD/2) clk = ~clk;

    //------------------------------------------------------------------
    //  4 个 DUT，不同 BAUD_DIV
    //------------------------------------------------------------------
    localparam integer B0 = 4;
    localparam integer B1 = 7;
    localparam integer B2 = 10;
    localparam integer B3 = 25;
    localparam integer SAMPLE_DIV_W = 100000;    // 远大于一帧占用时长，
                                                 // 保证"发完时下一次 latch 还没到"

    reg  en0 = 1'b1, en1 = 1'b1, en2 = 1'b1, en3 = 1'b1;
    wire tx0, tx1, tx2, tx3;

    //  注意：本台刻意只用"一次 latch"来观测一帧，所以每个 DUT 在第一帧发完后
    //  把 en 拉低，避免后续 latch 又启动新帧、污染 tx_start 计数。
    //  （uart_scope 的 !en 分支只清 latch 节拍，不打断正在发送的字节。）
    uart_scope #(.BAUD_DIV(B0), .SAMPLE_DIV(SAMPLE_DIV_W)) u0 (
        .clk(clk), .rst_n(rst_n), .en(en0),
        .hold(1'b0), .tx_idle(),
        .angle(16'h1234), .s_n(16'h0F0E), .c_n(16'hF1F2),
        .io_state(8'h6D), .io_flags(8'hA6), .pos_full(32'h01020304), .stat(8'h5A),
        .tx(tx0), .frame_cnt());
    uart_scope #(.BAUD_DIV(B1), .SAMPLE_DIV(SAMPLE_DIV_W)) u1 (
        .clk(clk), .rst_n(rst_n), .en(en1),
        .hold(1'b0), .tx_idle(),
        .angle(16'h1234), .s_n(16'h0F0E), .c_n(16'hF1F2),
        .io_state(8'h6D), .io_flags(8'hA6), .pos_full(32'h01020304), .stat(8'h5A),
        .tx(tx1), .frame_cnt());
    uart_scope #(.BAUD_DIV(B2), .SAMPLE_DIV(SAMPLE_DIV_W)) u2 (
        .clk(clk), .rst_n(rst_n), .en(en2),
        .hold(1'b0), .tx_idle(),
        .angle(16'h1234), .s_n(16'h0F0E), .c_n(16'hF1F2),
        .io_state(8'h6D), .io_flags(8'hA6), .pos_full(32'h01020304), .stat(8'h5A),
        .tx(tx2), .frame_cnt());
    uart_scope #(.BAUD_DIV(B3), .SAMPLE_DIV(SAMPLE_DIV_W)) u3 (
        .clk(clk), .rst_n(rst_n), .en(en3),
        .hold(1'b0), .tx_idle(),
        .angle(16'h1234), .s_n(16'h0F0E), .c_n(16'hF1F2),
        .io_state(8'h6D), .io_flags(8'hA6), .pos_full(32'h01020304), .stat(8'h5A),
        .tx(tx3), .frame_cnt());

    //------------------------------------------------------------------
    //  观测：对每个 DUT 记录 tx_start 时间戳与位边沿时间戳
    //------------------------------------------------------------------
    integer ts_n0=0, ts_a0=0, ts_b0=0, ts_l0=0;
    integer ts_n1=0, ts_a1=0, ts_b1=0, ts_l1=0;
    integer ts_n2=0, ts_a2=0, ts_b2=0, ts_l2=0;
    integer ts_n3=0, ts_a3=0, ts_b3=0, ts_l3=0;
    integer eg_n0=0, eg_a0=0, eg_b0=0, eg_c0=0;
    integer eg_n1=0, eg_a1=0, eg_b1=0, eg_c1=0;
    integer eg_n2=0, eg_a2=0, eg_b2=0, eg_c2=0;
    integer eg_n3=0, eg_a3=0, eg_b3=0, eg_c3=0;
    integer cyc = 0;
    reg p0=1'b1, p1=1'b1, p2=1'b1, p3=1'b1;
    //  位边沿统计必须只在"发送已开始"之后打开：复位释放时 tx 的 idle 电平会带来
    //  一次与数据无关的跳变，若计入就会把 edge1->2 量成半个 bit 周期。
    reg armed0=1'b0, armed1=1'b0, armed2=1'b0, armed3=1'b0;

    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            cyc = cyc + 1;
            if (u0.tx_start === 1'b1) begin ts_n0=ts_n0+1; armed0=1'b1; if (ts_n0==1) ts_a0=cyc; if (ts_n0==2) ts_b0=cyc; if (ts_n0==18) ts_l0=cyc; end
            if (u1.tx_start === 1'b1) begin ts_n1=ts_n1+1; armed1=1'b1; if (ts_n1==1) ts_a1=cyc; if (ts_n1==2) ts_b1=cyc; if (ts_n1==18) ts_l1=cyc; end
            if (u2.tx_start === 1'b1) begin ts_n2=ts_n2+1; armed2=1'b1; if (ts_n2==1) ts_a2=cyc; if (ts_n2==2) ts_b2=cyc; if (ts_n2==18) ts_l2=cyc; end
            if (u3.tx_start === 1'b1) begin ts_n3=ts_n3+1; armed3=1'b1; if (ts_n3==1) ts_a3=cyc; if (ts_n3==2) ts_b3=cyc; if (ts_n3==18) ts_l3=cyc; end
            if ((tx0 !== p0) && armed0) begin eg_n0=eg_n0+1; if (eg_n0==1) eg_a0=cyc; if (eg_n0==2) eg_b0=cyc; if (eg_n0==3) eg_c0=cyc; end
            if ((tx1 !== p1) && armed1) begin eg_n1=eg_n1+1; if (eg_n1==1) eg_a1=cyc; if (eg_n1==2) eg_b1=cyc; if (eg_n1==3) eg_c1=cyc; end
            if ((tx2 !== p2) && armed2) begin eg_n2=eg_n2+1; if (eg_n2==1) eg_a2=cyc; if (eg_n2==2) eg_b2=cyc; if (eg_n2==3) eg_c2=cyc; end
            if ((tx3 !== p3) && armed3) begin eg_n3=eg_n3+1; if (eg_n3==1) eg_a3=cyc; if (eg_n3==2) eg_b3=cyc; if (eg_n3==3) eg_c3=cyc; end
            p0=tx0; p1=tx1; p2=tx2; p3=tx3;
        end
    end

    //------------------------------------------------------------------
    //  第 5 个 DUT：直接驱动 uart_tx，用来精确量"一个字节在线上的时长"
    //------------------------------------------------------------------
    localparam integer B4 = 25;              // 上板真实值
    reg  [7:0] bdata = 8'h00;
    reg        bstart = 1'b0;
    wire       btx, bbusy;

    uart_tx #(.BAUD_DIV(B4)) u4 (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (bdata),
        .tx_start (bstart),
        .tx       (btx),
        .busy     (bbusy)
    );

    integer b_span = -1;
    integer b_span0 = -1, b_span1 = -1;
    integer b_t0 = 0;
    reg     b_en  = 1'b0;          // 只有 b 段才允许触发测量（前面 4 个 uart_scope 也在跑）
    reg     b_busy_prev = 1'b0;    // 用 busy 的上升沿来启动一次测量

    //  b 段的位边界日志：记录 busy 区间内 sc_tx 的每个跳变相对起始下降沿的偏移
    integer b_ne = 0;
    integer b_off0 = -1, b_off1 = -1, b_off2 = -1, b_off3 = -1;
    integer b_off_a = -1, b_off_b = -1;
    reg     b_prev = 1'b1;

    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            //  busy 上升沿 + b_en -> 开始测量
            if (bbusy === 1'b1 && b_busy_prev === 1'b0 && b_en === 1'b1) begin
                b_t0   = cyc;
                b_ne   = 0;
                b_prev = btx;
                b_off0 = -1; b_off1 = -1; b_off2 = -1; b_off3 = -1;
            end
            //  busy 为高期间记录跳变偏移
            if (bbusy === 1'b1) begin
                if (btx !== b_prev) begin
                    b_ne = b_ne + 1;
                    if (b_ne == 1) b_off0 = cyc - b_t0;
                    if (b_ne == 2) b_off1 = cyc - b_t0;
                    if (b_ne == 3) b_off2 = cyc - b_t0;
                    if (b_ne == 4) b_off3 = cyc - b_t0;
                end
                b_prev = btx;
            end
            //  busy 下降沿 -> 记录这个字节在线上的总时长
            if (bbusy === 1'b0 && b_busy_prev === 1'b1 && b_en === 1'b1) begin
                b_span = cyc - b_t0;
            end
            b_busy_prev = bbusy;
        end
    end

    task drive_byte;
        input [7:0] val;
        begin
            @(negedge clk);
            bdata  = val;
            bstart = 1'b1;
            @(negedge clk);
            bstart = 1'b0;
        end
    endtask

    integer i;

    initial begin
        $display("================================================================");
        $display(" tb_uart_baud : 字节起始间隔 == 10*BAUD_DIV + 2 ?（BAUD_DIV 扫描）");
        $display("================================================================");

        //  共同复位
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        //  同时给 4 个 DUT 一个 latch 脉冲
        //  （latch 是 uart_scope 的内部信号，只能靠"让节拍自然到点"来产生：
        //   这里把 en 保持 1，等 SAMPLE_DIV 个 clk 后内部 latch 会自动脉冲一次。）
        @(negedge clk); en0=1'b1; en1=1'b1; en2=1'b1; en3=1'b1;

        //  等最长的一路（BAUD_DIV=25）把 18 字节发完（末字节 tx_start 后再等 1 字节），
        //  然后把 en 全部拉低，冻结 tx_start 计数。
        //  SAMPLE_DIV_W=100000 远大于一帧 4534 clk，所以这期间不会有第二个 latch。
        wait (ts_n3 >= 18);
        repeat (10*B3 + 20) @(negedge clk);
        en0=1'b0; en1=1'b0; en2=1'b0; en3=1'b0;

        //  再多跑一段时间，确认 en=0 后不再有新的 tx_start
        repeat (20000) @(negedge clk);

        //==================================================================
        //  b 段：单独驱动 uart_tx（B4 = 25 = 上板真实 BAUD_DIV）
        //==================================================================
        repeat (20) @(negedge clk);
        b_en = 1'b1;
        //  注意：BAUD_DIV=25 时一个字节在线上一共要 250 clk，等待必须显著长于它，
        //  否则读到的 b_span 还是上一轮的 -1（这个坑踩过一次）。
        drive_byte(8'h55);                     // 起始位0 -> bit0=1，第一个位边界必有跳变
        repeat (400) @(negedge clk);
        b_span0 = b_span;
        b_off_a = b_off0; b_off_b = b_off1;

        repeat (20) @(negedge clk);
        drive_byte(8'hAA);                     // 起始位0 与 bit0=0 合并，故意做对照
        repeat (400) @(negedge clk);
        b_span1 = b_span;
        b_en = 1'b0;

        $display("");
        $display(" DUT   BAUD_DIV   tx_start数   latch->1st   1st->2nd   1st->18th");
        $display(" ----  --------   ----------   ---------   ---------   ---------");
        $display("  0       %0d           %0d         %0d        %0d        %0d",
                 B0, ts_n0, ts_a0, ts_b0-ts_a0, ts_l0-ts_a0);
        $display("  1       %0d           %0d         %0d        %0d        %0d",
                 B1, ts_n1, ts_a1, ts_b1-ts_a1, ts_l1-ts_a1);
        $display("  2       %0d           %0d         %0d        %0d        %0d",
                 B2, ts_n2, ts_a2, ts_b2-ts_a2, ts_l2-ts_a2);
        $display("  3       %0d           %0d         %0d        %0d        %0d",
                 B3, ts_n3, ts_a3, ts_b3-ts_a3, ts_l3-ts_a3);
        $display("");
        $display(" 注：不要用\"相邻两次 sc_tx 跳变的时间差\"来量位周期。UART 的位边界");
        $display("     只有在【相邻两位电平不同】时才有跳变，连续相同的位会把跳变合并");
        $display("     （例如 0xAA 的 起始位=0 与 bit0=0 连成一段 2*BAUD_DIV 的低电平）。");
        $display("     位周期必须用\"起始位下降沿 -> busy 下降沿 == 10*BAUD_DIV\"来判定，");
        $display("     见下面 b0/b1 两段专门验证。");
        $display("");

        //  ---- BAUD_DIV = 4 ----
        chk_int(ts_b0-ts_a0, 10*B0 + 2, "BDIV=4  byte interval == 10*BAUD_DIV + 2");
        chk_int((ts_l0-ts_a0) - 17*(10*B0+2), 0, "BDIV=4  17 byte intervals are all equal");
        chk_int(ts_n0, 18,              "BDIV=4  exactly 18 tx_start pulses (one per byte)");

        //  ---- BAUD_DIV = 7 ----
        chk_int(ts_b1-ts_a1, 10*B1 + 2, "BDIV=7  byte interval == 10*BAUD_DIV + 2");
        chk_int((ts_l1-ts_a1) - 17*(10*B1+2), 0, "BDIV=7  17 byte intervals are all equal");
        chk_int(ts_n1, 18,              "BDIV=7  exactly 18 tx_start pulses (one per byte)");

        //  ---- BAUD_DIV = 10 ----
        chk_int(ts_b2-ts_a2, 10*B2 + 2, "BDIV=10 byte interval == 10*BAUD_DIV + 2");
        chk_int((ts_l2-ts_a2) - 17*(10*B2+2), 0, "BDIV=10 17 byte intervals are all equal");
        chk_int(ts_n2, 18,              "BDIV=10 exactly 18 tx_start pulses (one per byte)");

        //  ---- BAUD_DIV = 25（上板真实值）----
        chk_int(ts_b3-ts_a3, 10*B3 + 2, "BDIV=25 byte interval == 10*BAUD_DIV + 2 (real HW)");
        chk_int((ts_l3-ts_a3) - 17*(10*B3+2), 0, "BDIV=25 17 byte intervals are all equal (real HW)");
        chk_int(ts_n3, 18, "BDIV=25 exactly 18 tx_start pulses (one per byte)");

        //==================================================================
        //  b 段：位周期的正确测法
        //    一个 8N1 字节的线上一共 10 个位，起始位下降沿到 busy 下降沿
        //    必须正好是 10*BAUD_DIV 个 clk。这也是"波特率精确"的充分判据。
        //==================================================================
        $display("");
        $display(" [b] 位周期 = 起始位下降沿 -> busy 下降沿，必须 == 10*BAUD_DIV");
        $display("     BAUD_DIV   byte=0x55 时长   期望    byte=0xAA 时长   期望");
        $display("     --------   --------------   ----    --------------   ----");
        $display("         %0d             %0d     %0d              %0d     %0d",
                 B4, b_span0, 10*B4, b_span1, 10*B4);
        $display("     0x55 的位边界偏移（相对起始下降沿）：%0d, %0d clk   (期望 %0d, %0d)",
                 b_off_a, b_off_b, B4, 2*B4);
        $display("");

        chk_int(b_span0, 10*B4, "BDIV=25 byte on-wire duration (0x55) == 10*BAUD_DIV");
        chk_int(b_span1, 10*B4, "BDIV=25 byte on-wire duration (0xAA) == 10*BAUD_DIV");
        chk_int(b_off_a, B4,    "BDIV=25 first bit boundary at exactly 1*BAUD_DIV");
        chk_int(b_off_b, 2*B4,  "BDIV=25 second bit boundary at exactly 2*BAUD_DIV");

        $display(" 真机（BAUD_DIV=25，clk = 50 MHz / 20 ns）推算：");
        $display("   位周期   = %0d clk = %0d ns  -> 波特率 = %.4f Mbaud",
                 B3, B3*CLK_PD, 1000.0/(B3*CLK_PD));
        $display("   字节间隔 = %0d clk = %0d ns", 10*B3+2, (10*B3+2)*CLK_PD);
        $display("   一帧占用 = %0d clk = %0d us  (17*间隔 + 10*BAUD_DIV)",
                 17*(10*B3+2) + 10*B3, (17*(10*B3+2) + 10*B3)*CLK_PD/1000);
        $display("   latch 节拍 = 5000 clk = 100 us  -> 链路占用率 = %.1f %%",
                 (17*(10*B3+2) + 10*B3) * 100.0 / 5000.0);
        $display("");

        $display("================================================================");
        if (errors == 0) $display(" TEST PASSED (%0d checks)", checks);
        else             $display(" TEST FAILED (%0d errors / %0d checks)", errors, checks);
        $display("================================================================");
        $finish;
    end

    //  超时保护
    initial begin
        #200000000;
        $display(" TEST FAILED (timeout)");
        $finish;
    end

endmodule
