//=============================================================================
//  tb_uart_spi_bridge.v —— rtl/uart_spi_bridge.v 的专用自检测试台
//-----------------------------------------------------------------------------
//  被测链路（全部是**真实模块**，只有寄存器堆用行为模型）：
//      PC(本台) --2Mbaud--> uart_spi_bridge --SPI--> spi_slave --读写--> mock reg
//      uart_scope(遥测 50kHz 满载) --仲裁--> 与桥共用一根 TX
//
//  为什么用"寄存器堆行为模型 + 其余真模块"的混合台：
//    · 桥的价值就是"走真正的 spi_slave 协议"，所以 spi_slave 必须是真的
//      （包模式 PKT=1，与 rtl/enc_top.v 里 u_spi 的配置一致）；
//    · reg_file 不参与协议验证，用 64K 字节数组代替，才能直接断言
//      "某地址确实被写成某值 / 只写了一次"；
//    · 遥测用真 uart_scope，SAMPLE_DIV 调到 1000（50 kHz，远高于设计的
//      10 kHz）—— 线上几乎满载，是 TX 仲裁的**最坏工况**。
//
//  ★ 四个最关键的设计点（复查先看这里）
//    1) 应答字节的识别不靠内容猜测，而靠**仲裁状态**：起始位出现那一拍若
//       scope_idle=1 且 scope_hold=1，该字节就属于桥（recv_byte 里的
//       owner_at_start）。理由：桥只在遥测行空闲(tx_idle)时才抢线，而
//       tx_idle=1 期间遥测绝不会启动新帧；反之遥测帧内任何字节起始拍都是
//       scope_idle=0（帧内 sending=1；末字节 sending=0 但 tx_busy=1）。
//    2) 写命令**只发一帧**：0x0502 CALIB_CTRL 的 start 位写两次会触发两次
//       标定。本台用 calib_wr_cnt 直接数"对 0x0502 的 we 次数"，==1 才算过。
//    3) 读命令**连发两帧**：spi_slave 是 应答滞后一帧的重叠式（命令 N 的响应在命令
//       N+1 帧才移出）。用例 [D]/[G] 的期望就是"第二帧的 MISO"，只发一帧会
//       得到上一次读的旧值，必然失败 —— 这是两帧逻辑的唯一证据。
//    4) scope_hold（别再起新帧）与 tx_drive（线上归我）必须分开：
//       若从 C_REPLY 就把 TX 切给桥，会在遥测帧发到一半时截断它。本台 [I]
//       的"遥测字节数 == 18×帧数 + 0 帧错"就是这条的守门测试（第一版实现
//       用同一个条件兼做两件事，实测 1336 字节/5 帧错被抓出来）。
//
//  用例：[A] 遥测基线  [B] 写 0x0109  [C] 写 0x0502 只写一次  [D] 读 0x05F0
//        [E] 首字节 bit7=0 整体丢弃  [F] 半包 2ms 超时后重同步
//        [G] 连发两条  [H] 波特率慢 2%  [I] 全程统计
//        [J] 外部 SPI 主机短占(100µs)  [K] 外部 SPI 主机长占(>2ms)
//=============================================================================
`timescale 1ns / 1ps

module tb_uart_spi_bridge;

    //-------------------------------------------------------------------------
    // 参数与时钟
    //-------------------------------------------------------------------------
    localparam integer CLK_PD     = 20;                 // 50 MHz
    localparam integer CLK_HALF   = CLK_PD / 2;
    localparam integer CLK_PER_US = 1000 / CLK_PD;      // 50 clk / µs
    localparam integer BAUD_DIV   = 25;                 // 50MHz / 2Mbaud = 25
    localparam integer BIT_NS     = BAUD_DIV * CLK_PD;  // 一位 = 500 ns
    localparam integer SAMPLE_DIV = 1000;               // 遥测 50 kHz（最坏仲裁工况）
    localparam integer TO_DIV     = 100_000;            // 桥的命令/仲裁超时 = 2 ms

    reg clk, rst_n;
    initial clk = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    //-------------------------------------------------------------------------
    // 遥测输入（常量，期望帧由这些值算出）
    //-------------------------------------------------------------------------
    localparam [15:0]        TM_ANG  = 16'h1234;
    localparam signed [15:0] TM_S    = 16'h0F0E;
    localparam signed [15:0] TM_C    = 16'hF1F2;
    localparam [7:0]         TM_IO   = 8'h6D;      // 帧布局 v2：off8 io_state
    localparam [7:0]         TM_FLAG = 8'hA6;      // 帧布局 v2：off10 io_flags
    localparam [31:0]        TM_POS  = 32'h01020304;
    localparam [7:0]         TM_STAT = 8'h5A;

    reg sc_en;

    //-------------------------------------------------------------------------
    // DUT 互连
    //-------------------------------------------------------------------------
    reg         rx_line;                 // 主机 → FPGA（模拟 PC 的 COM 口 TXD）
    wire        tx_line;                 // 仲裁后的 TX（遥测 or 应答）
    wire        scope_tx, scope_idle, scope_hold;
    wire        spi_sck, spi_ss_n, spi_mosi, spi_miso;
    wire [15:0] spi_addr;
    wire [7:0]  spi_wdata, spi_rdata;
    wire        spi_we;
    reg         ext_busy;                // 外部 SPI 主机占用（= ~外部片选）

    //-------------------------------------------------------------------------
    // 真模块 1：遥测（SAMPLE_DIV=1000 ⇒ 50 kHz，线几乎满载）
    //-------------------------------------------------------------------------
    uart_scope #(
        .BAUD_DIV   (BAUD_DIV),
        .SAMPLE_DIV (SAMPLE_DIV)
    ) u_scope (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (sc_en),
        .hold     (scope_hold),
        .angle    (TM_ANG),
        .s_n      (TM_S),
        .c_n      (TM_C),
        .io_state (TM_IO),
        .io_flags (TM_FLAG),
        .pos_full (TM_POS),
        .stat     (TM_STAT),
        .tx       (scope_tx),
        .tx_idle  (scope_idle),
        .frame_cnt()
    );

    //-------------------------------------------------------------------------
    // 真模块 2：被测量的桥
    //-------------------------------------------------------------------------
    uart_spi_bridge #(
        .BAUD_DIV (BAUD_DIV),
        .SPI_HALF (8),
        .GAP      (16),
        .TO_DIV   (TO_DIV),
        .GAP_MIN  (13 * BAUD_DIV)
    ) u_bridge (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx         (rx_line),
        .tx         (tx_line),
        .scope_tx   (scope_tx),
        .scope_idle (scope_idle),
        .dump_tx    (1'b1),             // B1 新增端口：本 tb 不测 dump，恒空闲
        .dump_busy  (1'b0),
        .scope_hold (scope_hold),
        .ext_busy   (ext_busy),
        .spi_sck    (spi_sck),
        .spi_ss_n   (spi_ss_n),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso)
    );

    //-------------------------------------------------------------------------
    // 真模块 3：SPI 从站（包模式，与 rtl/enc_top.v 的 u_spi 配置一致）
    //-------------------------------------------------------------------------
    spi_slave #(
        .AW              (16),
        .DW              (8),
        .USE_PKT_MODE (1)
    ) u_spi (
        .clk   (clk),
        .rst_n (rst_n),
        .sck   (spi_sck),
        .ssi   (spi_mosi),
        .ss_n  (spi_ss_n),
        .sso   (spi_miso),
        .addr  (spi_addr),
        .wdata (spi_wdata),
        .we    (spi_we),
        .rdata (spi_rdata)
    );

    //-------------------------------------------------------------------------
    // 行为模型：64K 寄存器堆 + "对 0x0502 的写次数"计数器
    //-------------------------------------------------------------------------
    reg [7:0]  mem [0:65535];
    reg [31:0] calib_wr_cnt;
    reg        clr_calib;

    assign spi_rdata = mem[spi_addr];

    always @(posedge clk)
        if (spi_we) mem[spi_addr] <= spi_wdata;

    always @(posedge clk) begin
        if (!rst_n || clr_calib)                   calib_wr_cnt <= 32'd0;
        else if (spi_we && (spi_addr == 16'h0502)) calib_wr_cnt <= calib_wr_cnt + 1'b1;
    end

    //-------------------------------------------------------------------------
    // 检查框架（失败才打印，末尾汇总 PASS/FAIL）
    //-------------------------------------------------------------------------
    integer checks, errors;

    task chk;
        input          cond;
        input [1023:0] name;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    task chk8;
        input [1023:0] name;
        input [7:0]    got, exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %0s : got 0x%02x exp 0x%02x", name, got, exp);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主机侧发送（模拟 PC 串口）
    //-------------------------------------------------------------------------
    task send_byte_bt;                   // 8N1，LSB 先
        input [7:0]   b;
        input integer bit_ns;            // 一位的时长（ns）
        integer i;
        begin
            @(posedge clk);              // 与时钟对齐（bit_ns 为 CLK_PD 整数倍时精确）
            rx_line = 1'b0;  #(bit_ns);
            for (i = 0; i < 8; i = i + 1) begin
                rx_line = b[i];  #(bit_ns);
            end
            rx_line = 1'b1;  #(bit_ns);
        end
    endtask

    task send_cmd_bt;
        input [7:0]   b0, b1, b2, b3;
        input integer bit_ns;
        begin
            send_byte_bt(b0, bit_ns);
            send_byte_bt(b1, bit_ns);
            send_byte_bt(b2, bit_ns);
            send_byte_bt(b3, bit_ns);
        end
    endtask

    task wait_us;
        input integer us;
        integer t;
        begin
            for (t = 0; t < us * CLK_PER_US; t = t + 1) @(posedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    // 线路监测：常驻字节接收器 + 两条流的分流统计
    //-------------------------------------------------------------------------
    reg [7:0]  rep [0:5];                // 最近一条应答的 6 个字节
    integer    rep_n;                    // 已收应答字节数（0 = 不在收应答）
    integer    rep_seq;                  // 收到的应答条数
    integer    telem_frames, telem_bad, telem_bytes;
    reg [7:0]  t_buf [0:15];
    integer    t_st, t_cnt, tm_bad_now;
    reg [7:0]  exp_tm [0:17];

    integer mon_i, mon_j;
    reg [7:0] mon_b;
    reg       mon_owner;

    // 期望遥测帧（帧布局 v2）：AA 55 | angle[15:0] | s | c | io_state | A2 | io_flags |
    //                            0x00 | pos[31:0] | stat | chk
    initial begin
        exp_tm[0]  = 8'hAA;
        exp_tm[1]  = 8'h55;
        exp_tm[2]  = TM_ANG[15:8];
        exp_tm[3]  = TM_ANG[7:0];
        exp_tm[4]  = TM_S[15:8];
        exp_tm[5]  = TM_S[7:0];
        exp_tm[6]  = TM_C[15:8];
        exp_tm[7]  = TM_C[7:0];
        exp_tm[8]  = TM_IO;
        exp_tm[9]  = 8'hA2;                    // IO 帧标记
        exp_tm[10] = TM_FLAG;
        exp_tm[11] = 8'h00;                    // 保留
        exp_tm[12] = TM_POS[31:24];
        exp_tm[13] = TM_POS[23:16];
        exp_tm[14] = TM_POS[15:8];
        exp_tm[15] = TM_POS[7:0];
        exp_tm[16] = TM_STAT;
        exp_tm[17] = 8'hAA ^ 8'h55
                   ^ TM_ANG[15:8] ^ TM_ANG[7:0]
                   ^ TM_S[15:8]   ^ TM_S[7:0]
                   ^ TM_C[15:8]   ^ TM_C[7:0]
                   ^ TM_IO ^ 8'hA2 ^ TM_FLAG ^ 8'h00
                   ^ TM_POS[31:24] ^ TM_POS[23:16] ^ TM_POS[15:8] ^ TM_POS[7:0]
                   ^ TM_STAT;
    end

    //  ★ 只统计"属于完整帧"的字节：帧头两字节在校验通过（0xAA 0x55）后才随
    //    整帧 +18 计入。这样监视器上电时若正赶上某帧已发到一半（开头那十几个
    //    孤儿字节），不会污染 telem_bytes == 18×frames 这条等式。
    task parse_telem;
        input [7:0] b;
        begin
            case (t_st)
                0: begin
                    if (b == 8'hAA) t_st = 1;
                end
                1: begin
                    if (b == 8'h55)      begin t_st = 2; t_cnt = 0; end
                    else if (b == 8'hAA) t_st = 1;    // AA AA 55 也能同步
                    else                 t_st = 0;
                end
                default: begin
                    t_buf[t_cnt] = b;
                    t_cnt = t_cnt + 1;
                    if (t_cnt == 16) begin
                        telem_frames = telem_frames + 1;
                        telem_bytes  = telem_bytes + 18;   // 含已校验的 2 字节帧头
                        tm_bad_now = 0;
                        for (mon_j = 0; mon_j < 16; mon_j = mon_j + 1)
                            if (t_buf[mon_j] !== exp_tm[mon_j + 2]) tm_bad_now = 1;
                        if (tm_bad_now) telem_bad = telem_bad + 1;
                        t_st = 0;
                    end
                end
            endcase
        end
    endtask

    // ★ 收一个字节；owner_at_start 见文件头"最关键设计点 1"
    task recv_byte;
        output [7:0] b;
        output       owner_at_start;
        integer i;
        begin
            @(negedge tx_line);                     // 起始位沿
            owner_at_start = scope_idle && scope_hold;
            repeat (BAUD_DIV/2) @(posedge clk);     // 到起始位中点
            for (i = 0; i < 8; i = i + 1) begin
                repeat (BAUD_DIV) @(posedge clk);   // 每位中点采样（LSB 先）
                b[i] = tx_line;
            end
            repeat (BAUD_DIV/2 + 1) @(posedge clk); // 越过停止位，准备下一个起始沿
        end
    endtask

    initial begin
        rep_n = 0; rep_seq = 0;
        telem_frames = 0; telem_bad = 0; telem_bytes = 0;
        t_st = 0; t_cnt = 0;
        wait (rst_n === 1'b1);
        repeat (200) @(posedge clk);                // 等复位后线上电平稳定
        forever begin
            recv_byte(mon_b, mon_owner);
            if (rep_n == 0) begin
                if (mon_owner) begin
                    rep[0] = mon_b;                 // 应答第 1 字节
                    rep_n  = 1;
                end
                else parse_telem(mon_b);            // 遥测字节
            end
            else begin
                rep[rep_n] = mon_b;                 // 应答第 2~6 字节（连续发）
                rep_n = rep_n + 1;
                if (rep_n == 6) begin
                    rep_n   = 0;
                    rep_seq = rep_seq + 1;
                end
            end
        end
    end

    task wait_rep;
        input  integer target;
        input  integer tout_us;
        output integer ok;
        integer t;
        begin
            t  = 0;
            ok = 0;
            while ((rep_seq < target) && (t < tout_us * CLK_PER_US)) begin
                @(posedge clk);
                t = t + 1;
            end
            if (rep_seq >= target) ok = 1;
        end
    endtask

    // 应答快照（本台每条命令都"先等到应答再发下一条"，不会被覆盖）
    reg [7:0] snap [0:5];
    task snap_rep;
        integer i;
        begin
            for (i = 0; i < 6; i = i + 1) snap[i] = rep[i];
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer t0, ok;
    integer i;

    initial begin
        $display(" tb_uart_spi_bridge —— UART→SPI 桥自检 (BAUD_DIV=%0d, SAMPLE_DIV=%0d)",
                 BAUD_DIV, SAMPLE_DIV);

        checks = 0; errors = 0; t0 = 0; ok = 0;
        rst_n   = 1'b0;
        rx_line = 1'b1;                    // 串口空闲
        sc_en   = 1'b1;
        ext_busy = 1'b0;
        clr_calib = 1'b0;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        // 与真实 reg_file 对应的几个默认值
        mem[16'h05F0] = 8'h0C;             // DEVICE_ID
        mem[16'h05F1] = 8'h10;             // REV
        mem[16'h053A] = 8'h01;             // page5 状态字节（应答 [31:24]）
        mem[16'h0100] = 8'h04;             // UVW_CFG：极对 4
        mem[16'h0109] = 8'h40;             // OUTPUT 默认
        mem[16'h0108] = 8'h00;             // ZERO1 默认
        mem[16'h0502] = 8'h00;             // CALIB_CTRL
        repeat (40) @(posedge clk);
        rst_n = 1'b1;
        wait_us(50);

        //=====================================================================
        $display("\n[A] 遥测基线（无命令）");
        //=====================================================================
        t0 = 0;
        while ((telem_frames < 3) && (t0 < 2_000_000)) begin
            @(posedge clk); t0 = t0 + 1;
        end
        chk(telem_frames >= 3, "A0 遥测 >= 3 帧");
        chk(telem_bad    == 0, "A1 遥测 0 帧错");
        chk8("A2 期望校验和(编译期常量)", exp_tm[17], 8'hEC);

        //=====================================================================
        $display("\n[B] 写 0x0109 = 0x00C0（89 09 00 C0）");
        //=====================================================================
        t0 = rep_seq;
        send_cmd_bt(8'h89, 8'h09, 8'h00, 8'hC0, BIT_NS);
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "B0 有应答（遥测满载下仍抢到缝隙）");
        snap_rep;
        chk8("B1 应答头", snap[0], 8'h5A);
        chk(snap[5] === (snap[0] ^ snap[1] ^ snap[2] ^ snap[3] ^ snap[4]),
            "B2 应答 XOR 自洽");
        chk8("B3 0x0109 低字节", mem[16'h0109], 8'hC0);
        chk8("B4 0x010A 高字节", mem[16'h010A], 8'h00);

        //=====================================================================
        $display("\n[C] 写 0x0502 = 0x0001（8D 02 00 01）：只写一帧");
        //=====================================================================
        clr_calib = 1'b1; @(posedge clk); clr_calib = 1'b0;
        t0 = rep_seq;
        send_cmd_bt(8'h8D, 8'h02, 8'h00, 8'h01, BIT_NS);
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "C0 有应答");
        wait_us(50);                       // 留出"可能的第二帧"时间
        chk(calib_wr_cnt == 32'd1, "C1 0x0502 只被写 1 次（读命令才连发两帧）");
        chk8("C2 0x0503 高字节", mem[16'h0503], 8'h00);

        //=====================================================================
        $display("\n[D] 读 0x05F0（85 F0 00 00）⇒ 期望 5A 01 F0 10 0C B7");
        //=====================================================================
        t0 = rep_seq;
        send_cmd_bt(8'h85, 8'hF0, 8'h00, 8'h00, BIT_NS);
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "D0 有应答");
        snap_rep;
        chk8("D1 应答[31:24]=page5 状态字节", snap[1], 8'h01);
        chk8("D2 应答[23:16]=地址回显",       snap[2], 8'hF0);
        chk8("D3 应答[15:8]=reg[0x05F1]",     snap[3], 8'h10);
        chk8("D4 应答[7:0]=reg[0x05F0]",      snap[4], 8'h0C);
        chk(snap[5] === (snap[0] ^ snap[1] ^ snap[2] ^ snap[3] ^ snap[4]),
            "D5 应答 XOR 自洽（证明用的是第二帧 MISO）");

        //=====================================================================
        $display("\n[E] 首字节 bit7=0（04 09 00 C0）⇒ 整体丢弃，不能执行");
        //=====================================================================
        t0 = rep_seq;
        send_cmd_bt(8'h04, 8'h09, 8'h00, 8'hC0, BIT_NS);
        wait_rep(t0 + 1, 1000, ok);
        chk(!ok, "E0 1 ms 内无应答（命令未被识别）");
        chk8("E1 0x0109 未被改动", mem[16'h0109], 8'hC0);
        t0 = rep_seq;
        send_cmd_bt(8'h89, 8'h08, 8'h00, 8'h08, BIT_NS);   // 写 0x0108=0x0008
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "E2 随后正常命令仍能执行（GAP_MIN 保护后状态机自愈）");
        chk8("E3 0x0108 写入 0x08", mem[16'h0108], 8'h08);

        //=====================================================================
        $display("\n[F] 半包 + 2 ms 超时 ⇒ 丢弃残包重新同步");
        //=====================================================================
        send_byte_bt(8'h89, BIT_NS);
        send_byte_bt(8'h09, BIT_NS);        // 只发 2 字节就停
        wait_us(2500);                      // > TO_DIV（2 ms）
        t0 = rep_seq;
        send_cmd_bt(8'h89, 8'h09, 8'h00, 8'h40, BIT_NS);   // 写 0x0109=0x0040
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "F0 超时重同步后有应答");
        chk8("F1 0x0109 写入 0x40（残包没有污染这条命令）", mem[16'h0109], 8'h40);

        //=====================================================================
        $display("\n[G] 连发两条：读 0x0108（首字节 0x81 = 读+page1）⇒ 期望 5A 00 08 40 08 1A");
        //=====================================================================
        //  ★ 首字节编码（本台所有命令都按这张表写，别把 page 写错）：
        //      bit31 st=1 | bit30:29 rm | bit28:27 wm | bit26:24 page
        //      写 page1 = 0x89、写 page4 = 0x8C、写 page5 = 0x8D；
        //      读 page1 = 0x81、读 page5 = 0x85。
        //    所以"读 0x0108"必须发 81 08 00 00；发 85 08 00 00 读到的是 0x0508
        //    （page5 的 0x053A 状态字节会读出 0x01，反而更像"对"了 —— 第一版
        //    测试就是在这里写错 page 才误判，见 DEV_STATUS 的记录）。
        t0 = rep_seq;
        send_cmd_bt(8'h81, 8'h08, 8'h00, 8'h00, BIT_NS);
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "G0 有应答");
        snap_rep;
        chk8("G1 应答[31:24]=page1 的 0x013A（本模型未定义 ⇒ 0）", snap[1], 8'h00);
        chk8("G2 应答[23:16]=地址回显",        snap[2], 8'h08);
        chk8("G3 应答[15:8]=reg[0x0109]",     snap[3], 8'h40);
        chk8("G4 应答[7:0]=reg[0x0108]",      snap[4], 8'h08);
        chk(snap[5] === (snap[0] ^ snap[1] ^ snap[2] ^ snap[3] ^ snap[4]),
            "G4b 应答 XOR 自洽（第二帧 MISO）");
        //  注意：上一条"读"是 [D]（resp 还停在 {01,F0,10,0C}）。若桥只发一帧，
        //  本条应答就会是那个旧值；期望里出现 40/08 即证明第二帧生效。
        t0 = rep_seq;
        send_cmd_bt(8'h89, 8'h09, 8'h00, 8'hC0, BIT_NS);   // 再来一条写，验证连发
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "G5 紧接的第二条命令也有应答");
        chk8("G6 0x0109 写回 0xC0", mem[16'h0109], 8'hC0);

        //=====================================================================
        $display("\n[H] 波特率慢 2%%（510 ns/位）仍能正确接收");
        //=====================================================================
        t0 = rep_seq;
        send_cmd_bt(8'h89, 8'h09, 8'h00, 8'h40, BIT_NS + 10);
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "H0 慢 2% 的命令有应答");
        chk8("H1 0x0109 写入 0x40", mem[16'h0109], 8'h40);

        //=====================================================================
        $display("\n[J] 外部 SPI 主机短时占用（100 µs）⇒ 桥等待后照常完成");
        //=====================================================================
        ext_busy = 1'b1;
        t0 = rep_seq;
        send_cmd_bt(8'h8D, 8'h02, 8'h00, 8'h01, BIT_NS);   // 写 CALIB_CTRL
        wait_us(100);
        chk(rep_seq == t0, "J0 外部占用期间不发应答（桥停在 C_ARM）");
        wait_us(20);
        ext_busy = 1'b0;
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "J1 释放后命令立刻完成");
        chk8("J2 CALIB_CTRL 低字节写入", mem[16'h0502], 8'h01);

        //=====================================================================
        $display("\n[K] 外部 SPI 主机长期占用（> 2 ms）⇒ 命令被放弃，零写入");
        //=====================================================================
        ext_busy = 1'b1;
        t0 = rep_seq;
        send_cmd_bt(8'h89, 8'h09, 8'h00, 8'hC0, BIT_NS);   // 想让 0x0109 = 0xC0
        wait_us(2500);                                     // > TO_DIV
        ext_busy = 1'b0;
        wait_us(200);
        chk(rep_seq == t0, "K0 超时放弃：始终没有应答");
        chk8("K1 0x0109 未被写入（宁可不执行也不抢总线）", mem[16'h0109], 8'h40);
        t0 = rep_seq;
        send_cmd_bt(8'h89, 8'h09, 8'h00, 8'hC0, BIT_NS);
        wait_rep(t0 + 1, 1000, ok);
        chk(ok, "K2 释放后链路恢复");
        chk8("K3 0x0109 写入 0xC0", mem[16'h0109], 8'hC0);

        //=====================================================================
        $display("\n[I] 全程统计：遥测完整性 + 应答条数");
        //=====================================================================
        wait_us(500);                       // 再多收几帧遥测
        $display("   遥测：%0d 帧 / %0d 字节 / %0d 帧错；应答：%0d 条",
                 telem_frames, telem_bytes, telem_bad, rep_seq);
        chk(telem_bad == 0, "I0 全程 0 帧错（TX 仲裁没有破坏遥测）");
        chk(telem_bytes == 18 * telem_frames,
            "I1 遥测字节数 == 18×帧数（没有字节被误判成应答）");
        chk(telem_frames >= 10, "I2 遥测帧数 >= 10（一直有数据在跑）");
        chk(rep_seq == 10, "I3 应答条数 == 成功命令条数(10)：B,C,D,E2,F,G,G5,H,J1,K2");

        //=====================================================================
        if (errors == 0) $display("\n TEST PASSED (%0d checks)", checks);
        else             $display("\n TEST FAILED (%0d errors / %0d checks)", errors, checks);
        $finish;
    end

    // 全局超时（正常总时长约 10 ms）
    initial begin
        #20_000_000;
        $display(" TEST FAILED (timeout)");
        $finish;
    end

endmodule
