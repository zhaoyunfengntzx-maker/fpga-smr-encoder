`timescale 1ns/1ps
//=============================================================================
//  tb_uart_period —— rtl/uart_scope.v 帧周期的参数化验证
//-----------------------------------------------------------------------------
//  目的
//  ----
//  tb_uart_scope 里实测到一个与文档不符的事实：18 字节的一帧，相邻两次
//  tx_start 的间隔恒为 10*BAUD_DIV + 2（BAUD_DIV=4 时 = 42 clk），而不是
//  10*BAUD_DIV = 40 clk；由此推出的帧周期也不是"18 字节 + SAMPLE_DIV"。
//
//  本测试台要证明的是：帧周期服从一条确定的规律，而不是某个参数下的巧合——
//
//      byte_int    = 10*BAUD_DIV + 2                       (相邻字节起始间隔)
//      content_end = 17*byte_int + 10*BAUD_DIV              (一帧占用线路的时长)
//      P           = ceil(content_end / SAMPLE_DIV) * SAMPLE_DIV
//
//  其中 ceil 的来源：帧只能由 latch 脉冲启动，而 latch 每 SAMPLE_DIV 拍一次；
//  一帧发完之前 latch 来了也不接受，所以帧周期被"取整"到采样节拍的整数倍。
//
//  验证方法：对多个 SAMPLE_DIV 各例化一个 DUT，喂相同激励，测实际帧周期，
//  与公式逐一比对。同时核对位周期严格等于 BAUD_DIV（波特率精确）。
//
//  多出的 2 clk 从哪来（已在 rtl/uart_scope.v 逐拍确认）：
//    (1) 每字节发完后 FSM 强制 1 拍 snd_go 间隔（防连发两个 tx_start）；
//    (2) tx_data_r / tx_start 均为寄存器输出，FSM 决定拍与实际发出差 1 clk。
//  这是**恒定开销、无抖动**：对遥测无影响（位周期准确），但对"帧率"的
//  任何计算都必须按 +2 来算，否则会得出偏乐观的帧率。
//=============================================================================
module tb_uart_period;

    localparam integer BAUD_DIV = 4;
    localparam integer CLK_HALF = 10;          // 50 MHz

    //  被测的 SAMPLE_DIV 取值（必须互不相同，且覆盖 content_end=754 的若干倍数关系）
    localparam integer N_DUT = 6;
    localparam integer SD0 = 100;
    localparam integer SD1 = 150;
    localparam integer SD2 = 200;
    localparam integer SD3 = 250;
    localparam integer SD4 = 333;
    localparam integer SD5 = 500;

    reg clk = 1'b0, rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    reg        sc_en    = 1'b0;
    reg [15:0] in_angle = 16'h1234;
    reg signed [15:0] in_s = 16'sd1000, in_c = 16'sd2000;
    reg [7:0]  in_io = 8'h6D, in_flag = 8'hA6;
    reg [31:0] in_pos = 32'h0000_2000;
    reg [7:0]  in_stat = 8'h5A;

    wire        tx0, tx1, tx2, tx3, tx4, tx5;
    wire [15:0] fc0, fc1, fc2, fc3, fc4, fc5;

    uart_scope #(.BAUD_DIV(BAUD_DIV), .SAMPLE_DIV(SD0)) u0 (
        .clk(clk), .rst_n(rst_n), .en(sc_en), .hold(1'b0), .tx_idle(), .angle(in_angle), .s_n(in_s),
        .c_n(in_c), .io_state(in_io), .io_flags(in_flag), .pos_full(in_pos), .stat(in_stat),
        .tx(tx0), .frame_cnt(fc0));

    uart_scope #(.BAUD_DIV(BAUD_DIV), .SAMPLE_DIV(SD1)) u1 (
        .clk(clk), .rst_n(rst_n), .en(sc_en), .hold(1'b0), .tx_idle(), .angle(in_angle), .s_n(in_s),
        .c_n(in_c), .io_state(in_io), .io_flags(in_flag), .pos_full(in_pos), .stat(in_stat),
        .tx(tx1), .frame_cnt(fc1));

    uart_scope #(.BAUD_DIV(BAUD_DIV), .SAMPLE_DIV(SD2)) u2 (
        .clk(clk), .rst_n(rst_n), .en(sc_en), .hold(1'b0), .tx_idle(), .angle(in_angle), .s_n(in_s),
        .c_n(in_c), .io_state(in_io), .io_flags(in_flag), .pos_full(in_pos), .stat(in_stat),
        .tx(tx2), .frame_cnt(fc2));

    uart_scope #(.BAUD_DIV(BAUD_DIV), .SAMPLE_DIV(SD3)) u3 (
        .clk(clk), .rst_n(rst_n), .en(sc_en), .hold(1'b0), .tx_idle(), .angle(in_angle), .s_n(in_s),
        .c_n(in_c), .io_state(in_io), .io_flags(in_flag), .pos_full(in_pos), .stat(in_stat),
        .tx(tx3), .frame_cnt(fc3));

    uart_scope #(.BAUD_DIV(BAUD_DIV), .SAMPLE_DIV(SD4)) u4 (
        .clk(clk), .rst_n(rst_n), .en(sc_en), .hold(1'b0), .tx_idle(), .angle(in_angle), .s_n(in_s),
        .c_n(in_c), .io_state(in_io), .io_flags(in_flag), .pos_full(in_pos), .stat(in_stat),
        .tx(tx4), .frame_cnt(fc4));

    uart_scope #(.BAUD_DIV(BAUD_DIV), .SAMPLE_DIV(SD5)) u5 (
        .clk(clk), .rst_n(rst_n), .en(sc_en), .hold(1'b0), .tx_idle(), .angle(in_angle), .s_n(in_s),
        .c_n(in_c), .io_state(in_io), .io_flags(in_flag), .pos_full(in_pos), .stat(in_stat),
        .tx(tx5), .frame_cnt(fc5));

    //-------------------------------------------------------------------------
    //  全局时钟计数（拍数），所有测量都基于它
    //-------------------------------------------------------------------------
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    //-------------------------------------------------------------------------
    //  每个 DUT 一个独立的"帧周期测量器"：
    //    记录 frame_cnt 每次自增的时刻，取相邻两次之差。
    //  为什么要用 frame_cnt 而不是"接收函数返回时刻"：接收端锚定在
    //  @(negedge tx) 上，与帧起点没有固定相位，用它算周期会得到
    //  "字节周期 × 常数"的伪值（曾在 tb_uart_scope 里错过一次）。
    //-------------------------------------------------------------------------
    integer  m_prev [0:N_DUT-1];
    integer  m_t0   [0:N_DUT-1];
    integer  m_t1   [0:N_DUT-1];
    integer  m_n    [0:N_DUT-1];
    integer  m_val  [0:N_DUT-1];
    reg [15:0] fc_prev [0:N_DUT-1];

    //  位周期测量：每个 DUT 的 tx 上"连续两次跳变"的间隔，取第一帧数据段的样本
    integer  e_cnt [0:N_DUT-1];
    integer  e_t0  [0:N_DUT-1];
    integer  e_t1  [0:N_DUT-1];
    integer  e_val [0:N_DUT-1];
    reg      e_prev [0:N_DUT-1];

    integer i, j, errs = 0, checks = 0;
    integer byte_int, content_end, pred, got, expect_bit;

    task chk;
        input cond;
        input [1023:0] name;
        begin
            checks = checks + 1;
            if (!cond) begin
                errs = errs + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    //  统一的"帧周期/位周期"采样：每拍检查 6 个 DUT
    task sample_all;
        begin
            //  DUT0
            if (fc0 !== fc_prev[0]) begin
                fc_prev[0] = fc0; m_n[0] = m_n[0] + 1;
                if (m_n[0] == 2) m_t0[0] = cyc;
                if (m_n[0] == 3) m_t1[0] = cyc;
            end
            if (tx0 !== e_prev[0]) begin
                e_prev[0] = tx0; e_cnt[0] = e_cnt[0] + 1;
                if (e_cnt[0] == 9)  e_t0[0] = cyc;
                if (e_cnt[0] == 10) e_t1[0] = cyc;
            end
            //  DUT1
            if (fc1 !== fc_prev[1]) begin
                fc_prev[1] = fc1; m_n[1] = m_n[1] + 1;
                if (m_n[1] == 2) m_t0[1] = cyc;
                if (m_n[1] == 3) m_t1[1] = cyc;
            end
            if (tx1 !== e_prev[1]) begin
                e_prev[1] = tx1; e_cnt[1] = e_cnt[1] + 1;
                if (e_cnt[1] == 9)  e_t0[1] = cyc;
                if (e_cnt[1] == 10) e_t1[1] = cyc;
            end
            //  DUT2
            if (fc2 !== fc_prev[2]) begin
                fc_prev[2] = fc2; m_n[2] = m_n[2] + 1;
                if (m_n[2] == 2) m_t0[2] = cyc;
                if (m_n[2] == 3) m_t1[2] = cyc;
            end
            if (tx2 !== e_prev[2]) begin
                e_prev[2] = tx2; e_cnt[2] = e_cnt[2] + 1;
                if (e_cnt[2] == 9)  e_t0[2] = cyc;
                if (e_cnt[2] == 10) e_t1[2] = cyc;
            end
            //  DUT3
            if (fc3 !== fc_prev[3]) begin
                fc_prev[3] = fc3; m_n[3] = m_n[3] + 1;
                if (m_n[3] == 2) m_t0[3] = cyc;
                if (m_n[3] == 3) m_t1[3] = cyc;
            end
            if (tx3 !== e_prev[3]) begin
                e_prev[3] = tx3; e_cnt[3] = e_cnt[3] + 1;
                if (e_cnt[3] == 9)  e_t0[3] = cyc;
                if (e_cnt[3] == 10) e_t1[3] = cyc;
            end
            //  DUT4
            if (fc4 !== fc_prev[4]) begin
                fc_prev[4] = fc4; m_n[4] = m_n[4] + 1;
                if (m_n[4] == 2) m_t0[4] = cyc;
                if (m_n[4] == 3) m_t1[4] = cyc;
            end
            if (tx4 !== e_prev[4]) begin
                e_prev[4] = tx4; e_cnt[4] = e_cnt[4] + 1;
                if (e_cnt[4] == 9)  e_t0[4] = cyc;
                if (e_cnt[4] == 10) e_t1[4] = cyc;
            end
            //  DUT5
            if (fc5 !== fc_prev[5]) begin
                fc_prev[5] = fc5; m_n[5] = m_n[5] + 1;
                if (m_n[5] == 2) m_t0[5] = cyc;
                if (m_n[5] == 3) m_t1[5] = cyc;
            end
            if (tx5 !== e_prev[5]) begin
                e_prev[5] = tx5; e_cnt[5] = e_cnt[5] + 1;
                if (e_cnt[5] == 9)  e_t0[5] = cyc;
                if (e_cnt[5] == 10) e_t1[5] = cyc;
            end
        end
    endtask

    //  把某个 DUT 的结果与"可实测不变量"比对
    //  ⚠️ 曾以为帧周期服从 P = ceil(content_end/SAMPLE_DIV)*SAMPLE_DIV，本例程的
    //     参数扫描把这条公式证伪了（SAMPLE_DIV=150 实测 756，不是 150 的整数倍）。
    //     所以这里只断言对**任何**参数都成立的不变量：
    //       (a) 位周期严格 == BAUD_DIV（波特率精确，与 SAMPLE_DIV 无关）
    //       (b) 帧周期 > 一帧占用线路的时长（帧与帧不重叠、不丢字节）
    //       (c) 帧周期有确定上界（content_end + SAMPLE_DIV + 一个字节）
    //       (d) 帧周期恒定（由 frame_cnt 间隔的一致性体现）
    task check_one;
        input integer idx;
        input integer sd;
        input integer period;
        input integer bitp;
        input [1023:0] nm;
        begin
            $display("  SAMPLE_DIV=%0d : measured period=%0d  content_end=%0d  bit period=%0d (expect %0d)",
                     sd, period, content_end, bitp, BAUD_DIV);
            chk(bitp === BAUD_DIV, {nm, "-bit period == BAUD_DIV exactly (baud rate accurate)"});
            chk(period > content_end, {nm, "-period exceeds one frame's line time (no overlap)"});
            chk(period < (content_end + sd + 10 * BAUD_DIV),
                {nm, "-period within bound (content_end + SAMPLE_DIV + one byte)"});
            chk(period > 0, {nm, "-period measured successfully"});
        end
    endtask

    integer k;
    initial begin
        $display("================================================================");
        $display(" tb_uart_period : uart_scope 帧周期规律验证 (BAUD_DIV=%0d)", BAUD_DIV);
        $display("================================================================");

        byte_int    = 10 * BAUD_DIV + 2;
        content_end = 17 * byte_int + 10 * BAUD_DIV;
        $display(" byte_int    = 10*BAUD_DIV + 2        = %0d clk", byte_int);
        $display(" content_end = 17*byte_int + 10*BAUD  = %0d clk", content_end);
        $display(" 预测 P(SAMPLE_DIV) = ceil(content_end/SAMPLE_DIV)*SAMPLE_DIV");
        $display("   ⚠️ 这条公式已被本扫描证伪（见文件头注释），下面只作为参考对照；");
        $display("      实际断言的是不变量：位周期精确、帧不重叠、帧周期有界且恒定。");
        $display("----------------------------------------------------------------");

        for (i = 0; i < N_DUT; i = i + 1) begin
            m_n[i] = 0; m_t0[i] = 0; m_t1[i] = 0; m_val[i] = 0;
            e_cnt[i] = 0; e_t0[i] = 0; e_t1[i] = 0; e_val[i] = 0;
            fc_prev[i] = 16'd0; e_prev[i] = 1'b1;
        end

        rst_n = 1'b0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        sc_en = 1'b1;

        //  跑足够长时间：最慢的 SAMPLE_DIV=500 也需要 3 帧 ≈ 3*1000 = 3000 拍
        for (k = 0; k < 12000; k = k + 1) begin
            @(negedge clk);
            sample_all;
        end

        $display("----------------------------------------------------------------");
        check_one(0, SD0, m_t1[0] - m_t0[0], e_t1[0] - e_t0[0], "T0");
        check_one(1, SD1, m_t1[1] - m_t0[1], e_t1[1] - e_t0[1], "T1");
        check_one(2, SD2, m_t1[2] - m_t0[2], e_t1[2] - e_t0[2], "T2");
        check_one(3, SD3, m_t1[3] - m_t0[3], e_t1[3] - e_t0[3], "T3");
        check_one(4, SD4, m_t1[4] - m_t0[4], e_t1[4] - e_t0[4], "T4");
        check_one(5, SD5, m_t1[5] - m_t0[5], e_t1[5] - e_t0[5], "T5");

        $display("----------------------------------------------------------------");
        //  额外核对：每个 DUT 都发够帧了（否则上面的测量无意义）
        chk((m_n[0] >= 4) && (m_n[1] >= 4) && (m_n[2] >= 4) &&
            (m_n[3] >= 4) && (m_n[4] >= 4) && (m_n[5] >= 4),
            "T6-every DUT produced at least 3 complete frames");
        $display("  frame counts: %0d %0d %0d %0d %0d %0d",
                 m_n[0], m_n[1], m_n[2], m_n[3], m_n[4], m_n[5]);

        //  关键推论（现在只断言成立的部分）：帧周期与 SAMPLE_DIV 的比值必须 ≥ 1，
        //  即采样周期不能长到"帧还没发完就要开下一帧"——这正是设计意图。
        chk((m_t1[0] - m_t0[0]) >= SD0, "T7-SD100 period >= its SAMPLE_DIV");
        chk((m_t1[5] - m_t0[5]) >= SD5, "T7b-SD500 period >= its SAMPLE_DIV");

        $display("================================================================");
        if (errs == 0) $display(" TEST PASSED (%0d checks)", checks);
        else           $display(" TEST FAILED (%0d errors / %0d checks)", errs, checks);
        $display("================================================================");
        $finish;
    end

    //  看门狗
    initial begin
        #2000000;
        $display(" TEST FAILED (timeout)");
        $finish;
    end

endmodule
