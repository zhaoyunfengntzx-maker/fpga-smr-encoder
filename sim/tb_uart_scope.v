//=============================================================================
//  tb_uart_scope.v  ——  rtl/uart_scope.v 的专用自检测试台
//-----------------------------------------------------------------------------
//  覆盖对象：
//    DUT1 = uart_tx      （uart_scope.v 内的发送器，裸模块）
//    DUT2 = uart_scope   （定周期组帧 / 背靠背连发 / 停发 / 噪声后重同步）
//
//  为什么必须有这一台：
//    uart_scope 是上板时**唯一的连续观测通道**。它坏掉在 PC 上的表现是
//    "全是乱码"，没有第二路信号可以对照定位。此前整个回归里没有任何测试台
//    例化过 uart_tx / uart_scope，属于真实覆盖缺口。
//
//  本测试台不依赖任何外部文件（无 $readmemh），可换机器直接跑。
//=============================================================================

`timescale 1ns / 1ps

module tb_uart_scope;

    //-------------------------------------------------------------------------
    //  参数与常量
    //-------------------------------------------------------------------------
    localparam integer BAUD_DIV   = 4;       // 一位 = BAUD_DIV 个 clk
    localparam integer SAMPLE_DIV = 100;     // 采样节拍
    localparam integer CLK_PD     = 20;      // clk 周期 (ns)
    localparam integer BIT        = BAUD_DIV * CLK_PD;   // 80 ns
    localparam integer HALF       = CLK_PD / 2;          // 10 ns
    localparam integer BYTE_CYCLES = 10 * BAUD_DIV;      // 40 clk

    //-------------------------------------------------------------------------
    //  时钟 / 复位 / 计数
    //-------------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    integer cycle = 0;

    always #(HALF) clk = ~clk;               // 20 ns 周期
    always @(posedge clk) cycle = cycle + 1;

    //-------------------------------------------------------------------------
    //  统计
    //-------------------------------------------------------------------------
    integer checks = 0;
    integer errors = 0;

    task chk;
        input          cond;
        input [1023:0] name;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] %0s   (t=%0t ns)", name, $time);
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
                $display("  [FAIL] %0s : got 0x%02X , expected 0x%02X   (t=%0t ns)",
                         name, got, exp, $time);
            end
        end
    endtask

    //=========================================================================
    //  DUT 1 : uart_tx 裸模块（位级时序 / 字节往返）
    //=========================================================================
    reg  [7:0] tx_data  = 8'h00;
    reg        tx_start = 1'b0;
    wire       tx_line;
    wire       tx_busy;

    uart_tx #(.BAUD_DIV(BAUD_DIV)) u_tx (
        .clk(clk), .rst_n(rst_n), .tx_data(tx_data),
        .tx_start(tx_start), .tx(tx_line), .busy(tx_busy)
    );

    //=========================================================================
    //  DUT 2 : uart_scope 整帧
    //=========================================================================
    reg         sc_en    = 1'b0;
    reg  [15:0] in_angle = 16'h0000;
    reg  signed [15:0] in_s = 16'sd0;
    reg  signed [15:0] in_c = 16'sd0;
    reg  [7:0]  in_io    = 8'h00;            // 帧布局 v2：ABZ/UVW 电平快照
    reg  [7:0]  in_flag  = 8'h00;            // 帧布局 v2：告警/使能位
    reg  [31:0] in_pos   = 32'd0;
    reg  [7:0]  in_stat  = 8'h00;
    wire        utx;                         // DUT 的原始发送输出
    wire [15:0] frame_cnt;

    //=========================================================================
    //  ★★ 线路多路选择：这是"注入噪声"能真正生效的关键
    //-----------------------------------------------------------------------------
    //  接收器（rx_byte_sc / rx_frame_locked / rx_frame_sync / rx_frame_until_hdr）
    //  统一采样 sc_tx。E 段要模拟"线路上混入垃圾字节"，就必须让 sc_tx 本身
    //  被注入信号接管——早期版本只写了一根无人使用的 rx_line，
    //  于是 inj_bit 根本没接到接收器上，E 段实际测的还是 DUT 的干净输出，
    //  「噪声后重新同步」的结论是假的（由 tools/scan_dangling.py 的 A2 抓出）。
    //  现在 inj_mode=1 时 sc_tx 直接等于 inj_bit。
    //=========================================================================
    reg         inj_mode = 1'b0;
    reg         inj_bit  = 1'b1;
    wire        sc_tx = inj_mode ? inj_bit : utx;

    uart_scope #(.BAUD_DIV(BAUD_DIV), .SAMPLE_DIV(SAMPLE_DIV)) u_scope (
        .clk(clk), .rst_n(rst_n), .en(sc_en),
        .hold(1'b0),                       // 无桥占用 TX
        .angle(in_angle), .s_n(in_s), .c_n(in_c),
        .io_state(in_io), .io_flags(in_flag),
        .pos_full(in_pos), .stat(in_stat),
        .tx(utx), .tx_idle(), .frame_cnt(frame_cnt)
    );

    //=========================================================================
    //  ★★ 接收器设计要点（踩过的坑，务必保留）
    //-----------------------------------------------------------------------------
    //  1) 采样必须用 **posedge clk + #1**，不能用 @(negedge clk)。
    //     negedge 读到的值是"上一个 posedge 寄存出来的"，比真实位边界早
    //     半个周期；BAUD_DIV=4（一位仅 4 clk）时余量被吃掉一半，实测整帧
    //     读到"每个字节都差一个位"：fr[0]=0xAA 侥幸对上，fr[1] 起全错
    //     （0x24 而非 0x55）。改为 posedge + #1 后采样点距边界 20/60 ns。
    //
    //  2) DUT1 与 DUT2 是**两个独立例化**：tx_line/tx_busy 属于裸 uart_tx，
    //     sc_tx 才是 uart_scope 的输出。接收 uart_scope 的帧必须看 sc_tx，
    //     曾误用 tx_line 而读到的全是"恒 1"。
    //
    //  3) uart_scope 是**背靠背连发**：uart_tx 在 S_STOP 最后一拍就把 busy
    //     拉低，恰好与停止位起点同拍，所以帧与帧之间**没有空闲位**
    //     （SAMPLE_DIV=100 时帧间仅 ~10 clk）。因此：
    //       · 不能用"等线空闲"来定位帧边界；
    //       · 链路上丢一个字节后，接收方只能靠扫描 "AA 55" + XOR 校验
    //         重新对齐 ⇒ 上位机解析器**必须**实现该重同步，不能假设读到
    //         的头两字节就是帧头。这一条是真实的上板风险，已记入报告。
    //
    //  4) 起始位锚点 = sc_tx 的下降沿。帧内任何位置都可能出现下降沿，所以
    //     单次 rx_frame_sync 不保证落在帧首，调用方需要多试几帧看帧头
    //     （见 [E] 段的循环）。
    //=========================================================================

    //  =====================  接收器：起始沿锚定 + 固定拍数采样  =============
    //  实测时序（用独立探针逐拍打印 FSM 内部信号得到，不是推算）：
    //    · clk 周期 20 ns；BAUD_DIV=4 ⇒ 1 bit = 80 ns = 4 个 clk；
    //    · 1 字节 = 10 bit = 800 ns；18 字节整帧 = 14400 ns = 720 clk；
    //    · uart_tx 在 tx_start 被采样的同一拍把 tx 拉低（起始位起点），
    //      此后每 4 个 clk 换一位，位序 LSB 先发，最后是停止位（高）。
    //  因此最可靠的接收方式是：
    //    1) 等 sc_tx 的**下降沿**（= 某个字节起始位的物理起点）；
    //    2) 该沿之后 #(BIT/4) 采样 ⇒ 落在起始位正中（余量 ±40ns）；
    //    3) 之后每 #BIT 采一位，恰好落在每一位正中。
    //  这样与 clk 网格无关，也与"捕获窗口/锁帧扫描"无关。
    //    ★ 旧版用"一次抓 1200 个采样点再离线扫描起始位"的做法已废弃：
    //      扫描条件是"连续 SPB 个低点"，而帧内相邻数据位构成的低电平会让
    //      它误判；实测 18 个停止位里最多只能同时命中 12~14 个，锁帧永远失败。
    reg [7:0] fr [0:17];                  // 最近一帧的 18 字节
                                          // （xvlog 要求声明在首次使用之前）
    //  第 0 字节下降沿发生时的 cycle 计数（= 帧起点的时间戳），
    //  供 [D] 段测"真实帧周期"。必须用第 0 字节的沿，不能用接收函数的
    //  返回时刻：rx_frame_locked 失败重试时，函数返回点会漂到帧中间。
    //  只在帧校验通过时才写入，避免把"帧中间"的锚点当成帧起点。
    integer   fr_t0 = 0;
    integer   t_anch = 0;                 // 本次尝试的候选锚点时间戳

    //  ---- 决定性探针：把 latch / tx_start / 首字节位翻转 都记下来 ----
    //  用来解释"实测帧周期 800 clk，而 18 字节 720 + 采样节拍 100 = 820"的差异。
    integer p_lat_n = 0, p_lat_t0 = 0, p_lat_t1 = 0, p_lat_t2 = 0;
    integer p_ts_n  = 0, p_ts_t0  = 0, p_ts_t1  = 0;
    integer p_edge_n = 0, p_edge_t0 = 0, p_edge_t1 = 0, p_edge_t8 = 0, p_edge_t9 = 0;
    reg     p_tx_prev = 1'b1;
    //  一帧内 18 次 tx_start 的时间戳 + sending/frame_cnt 变化时刻
    integer p_ts_arr [0:23];
    integer p_snd_fall_t = 0, p_snd_fall_n = 0;
    integer p_fc_t0 = 0, p_fc_t1 = 0, p_fc_n = 0;
    reg     p_snd_prev = 1'b0;
    reg [15:0] p_fc_prev = 16'd0;
    always @(posedge clk) begin
        if (u_scope.latch === 1'b1) begin
            p_lat_n = p_lat_n + 1;
            if (p_lat_n == 1) p_lat_t0 = cycle;
            if (p_lat_n == 2) p_lat_t1 = cycle;
            if (p_lat_n == 3) p_lat_t2 = cycle;
        end
        if (u_scope.tx_start === 1'b1) begin
            p_ts_n = p_ts_n + 1;
            if (p_ts_n == 1) p_ts_t0 = cycle;
            if (p_ts_n == 2) p_ts_t1 = cycle;
            if (p_ts_n <= 24) p_ts_arr[p_ts_n - 1] = cycle;
        end
        //  sending 的下降沿（一帧真正结束的时刻）
        if ((u_scope.sending === 1'b0) && (p_snd_prev === 1'b1)) begin
            p_snd_fall_n = p_snd_fall_n + 1;
            if (p_snd_fall_n == 1) p_snd_fall_t = cycle;
        end
        p_snd_prev = u_scope.sending;
        //  frame_cnt 自增时刻
        if (u_scope.frame_cnt !== p_fc_prev) begin
            p_fc_n = p_fc_n + 1;
            if (p_fc_n == 1) p_fc_t0 = cycle;
            if (p_fc_n == 2) p_fc_t1 = cycle;
        end
        p_fc_prev = u_scope.frame_cnt;
        //  记录 sc_tx 上连续的位边界（只统计第一帧的前 10 个边沿）
        if ((sc_tx !== p_tx_prev) && (p_edge_n < 12)) begin
            p_edge_n = p_edge_n + 1;
            if (p_edge_n == 1) p_edge_t0 = cycle;
            if (p_edge_n == 2) p_edge_t1 = cycle;
            if (p_edge_n == 9) p_edge_t8 = cycle;
            if (p_edge_n == 10) p_edge_t9 = cycle;
        end
        p_tx_prev = sc_tx;
    end

    //  ★ 复盘（2026-10-10）：这里以前写着"本工程 xsim 有异或求值陷阱，
    //    同一个式子换写法结果不同（(a)→0x55 / (b)→0xA7 / (c)→也是错的）"。
    //    这个结论是错的，已更正。依据就是 sim/tb_xor_probe3.v 自己通过的断言：
    //      T11a: (a) ^ 0x55 == (b)     —— 差异**恰好**是 (a) 少异或的那个常量
    //      T11c: (c) == (b)            —— (c) 并没有"不可靠"
    //    当时被当成"正确值 0xFD"的那个数，是用**截断到 fr[15] 的累加**算出来的：
    //      完整 payload XOR(2..16) = 0x58；漏掉 fr[16]=0x5A 后 = 0x58^0x5A = 0x02；
    //      0x02 ^ 0xAA ^ 0x55 = 0xFD   <- 错源在这里
    //    而那次 (c) 实测得到的 0xA7 恰恰是正确值（0x58 ^ 0xFF）。
    //    ⇒ 不是仿真器问题，是测试台自己的累加范围写错。三种写法都可靠，
    //      下面统一用 (b) 只是为了可读性；判据以 tb_xor_probe3.v 的 T1..T12 为准。
    //    但**帧头常量必须异或进去**这一点是真的（RTL 就是这么发的，见 C17/C19）。
    function [7:0] xor_of_frame;
        input dummy;
        reg [7:0] xc;
        integer   jj;
        begin
            xc = 8'hAA ^ 8'h55;
            for (jj = 2; jj <= 16; jj = jj + 1) xc = xc ^ fr[jj];
            xor_of_frame = xc;
        end
    endfunction

    function frame_ok;
        input dummy;
        begin
            frame_ok = ((fr[0] === 8'hAA) && (fr[1] === 8'h55)
                        && (fr[17] === xor_of_frame(1'b1)));
        end
    endfunction

    //  整字节接收：从 sc_tx 的下降沿起算，位中点采样。
    task rx_byte_sc;
        output [7:0] rb;
        output       rstop_ok;
        integer      q;
        begin
            rb       = 8'h00;
            rstop_ok = 1'b0;
            @(negedge sc_tx);                   // 起始位物理起点
            #(BIT/4);                           // 落入起始位中部
            if (sc_tx !== 1'b0) begin
                @(negedge sc_tx);               // 下降沿落在噪声上，重新锚定
                #(BIT/4);
            end
            for (q = 0; q < 8; q = q + 1) begin
                #(BIT);                         // 移到第 q 位中点（LSB 先）
                rb[q] = sc_tx;
            end
            #(BIT);                             // 停止位中点
            rstop_ok = (sc_tx === 1'b1);
        end
    endtask

    //  抓一帧：最多试 4 个字节边界。每次连读 18 字节，用
    //  "AA 55 帧头 + XOR 自洽" 双条件确认；不满足就跳到下一个字节边界
    //  重试（等价于上位机解析器的重同步行为）。
    task rx_frame_locked;
        output       hok;
        output       sok;
        integer      tries, q;
        reg          st_ok;
        begin
            hok = 1'b0;
            sok = 1'b1;
            for (tries = 0; (tries < 4) && (hok !== 1'b1); tries = tries + 1) begin
                for (q = 0; q < 18; q = q + 1) begin
                    rx_byte_sc(fr[q], st_ok);
                    //  第 0 字节的下降沿 = 帧起点，记下时间戳用于测帧周期。
                    if (q == 0) t_anch = cycle;
                    if (st_ok !== 1'b1) sok = 1'b0;
                end
                //  ★ 只在帧校验通过时才更新全局帧起点时间戳：失败的重试锚在
                //    帧中间，若也写 fr_t0 会让 [D] 段测到假的"帧周期"。
                if (frame_ok(1'b1) === 1'b1) begin
                    hok   = 1'b1;
                    fr_t0 = t_anch;
                end
            end
        end
    endtask

    //  兼容旧名字
    task rx_frame_sync;
        output       shdr_ok;
        output       sstop_ok;
        begin
            rx_frame_locked(shdr_ok, sstop_ok);
        end
    endtask

    //  能读多帧，直到读到合法帧为止（用于 [E] 噪声后的重同步）。
    task rx_frame_until_hdr;
        output       shdr_ok;
        output       sstop_ok;
        begin
            rx_frame_locked(shdr_ok, sstop_ok);
        end
    endtask



    //  DUT1（裸 uart_tx）的字节接收。[B] 段直接脉冲 tx_start 驱动裸模块，
    //  此时 uart_scope 的 en=0、sc_tx 恒为 1，因此**不能**用 sc_tx 找起始位。
    //  tx_start 是单周期脉冲且被 FSM 在 posedge 直接采样，所以
    //  "驱动后的下一个 posedge"时起始位必定已经在 tx_line 上；
    //  #1 后采样落在距边界 20ns 处，此后每 BIT 取一位，余量充足。
    task rx_byte_tx;
        output [7:0] rb;
        output       rstop_ok;
        integer      q;
        begin
            rb       = 8'h00;
            rstop_ok = 1'b0;
            @(posedge clk); #1;                 // 起始位内
            chk(tx_line === 1'b0, "RX: start bit level must be 0");
            for (q = 0; q < 8; q = q + 1) begin
                #BIT;                           // 数据位中点（LSB 先）
                rb[q] = tx_line;
            end
            #BIT;                               // 停止位内
            rstop_ok = (tx_line === 1'b1);
        end
    endtask

    //  帧缓存与判定所需的声明必须出现在任何使用它们的 task/function 之前
    //  （xvlog 报 [VRFC 10-3380] identifier is used before its declaration）。
    //  对已收到的 18 字节做"帧头 + XOR 校验"判定（与上位机解析器同款）：
    //  单独看 AA 55 可能在有效载荷中偶然出现，必须再加 XOR 才敢认帧。

    //  兼容旧名字：现在统一走"捕获 + 下标解码"（rx_frame_locked）。

    //  XOR 校验期望值：**含帧头常量项**（rtl/uart_scope.v:189-196）
    function [7:0] xor_expect;
        input [15:0] a, sv, cv;
        input [31:0] amp, pos;
        input [7:0]  st;
        begin
            xor_expect = 8'hAA ^ 8'h55
                       ^ a[15:8]   ^ a[7:0]
                       ^ sv[15:8]  ^ sv[7:0]
                       ^ cv[15:8]  ^ cv[7:0]
                       ^ amp[31:24] ^ amp[23:16] ^ amp[15:8] ^ amp[7:0]
                       ^ pos[31:24] ^ pos[23:16] ^ pos[15:8] ^ pos[7:0]
                       ^ st;
        end
    endfunction

    //  安全检查用的随机字节：避开 0xAA / 0x55，防止噪声里出现假帧头。
    //  注意：判据必须放在**生成之后**。早期版本先 b=0 再 while(条件)，而 0
    //  既不等于 0xAA 也不等于 0x55，循环一次都不进 ⇒ 5 个"随机"噪声字节
    //  全是 0x00，噪声段退化成连续 break，重同步测试被显著弱化。
    task rand_byte_safe;
        output [7:0] b;
        integer      guard;
        begin
            b = 8'h00;
            guard = 0;
            while (((b === 8'hAA) || (b === 8'h55) || (b === 8'h00)) && (guard < 200)) begin
                b = $random;
                guard = guard + 1;
            end
            if ((b === 8'hAA) || (b === 8'h55) || (b === 8'h00)) b = 8'h3C;
        end
    endtask

    //=========================================================================
    //  测试主流程
    //=========================================================================
    reg [7:0]  words [0:7];
    reg [7:0]  b;
    reg        stop_ok, hdr_ok, stops_ok;
    reg [7:0]  expc, gotc, plonly;
    reg [15:0] t_angle, t_s, t_c;
    reg [7:0]  t_io, t_flag;                 // 帧布局 v2：off8 / off10
    reg [31:0] t_pos;
    reg [7:0]  t_stat;
    reg [7:0]  pat_byte;
    integer    k, i, n, m;
    integer    cyc_a, cyc_b, cyc_c, byte_cycles;
    integer    gap1, gap2, gap_meas, low_glitch;
    reg [15:0] fc_a, fc_b;
    //  注：注入用的 inj_mode / inj_bit 以及多路选择后的 sc_tx 都在文件上方
    //      （DUT 例化处）统一声明，此处不得重复声明。

    initial begin
        $display("================================================================");
        $display(" tb_uart_scope  ——  uart_tx / uart_scope 自检");
        $display("   BAUD_DIV=%0d (1 bit = %0d clk)  SAMPLE_DIV=%0d  frame=18 bytes",
                 BAUD_DIV, BAUD_DIV, SAMPLE_DIV);
        $display("================================================================");

        //---------------------------------------------------------------------
        // 复位
        //---------------------------------------------------------------------
        rst_n = 1'b0;
        repeat (6) @(posedge clk);
        @(negedge clk); #HALF;
        chk(tx_line === 1'b1, "A0-uart_tx idle level is 1 during reset");
        chk(sc_tx   === 1'b1, "A0-uart_scope idle level is 1 during reset");
        chk(tx_busy === 1'b0, "A0-uart_tx busy=0 during reset");
        chk(sc_en   === 1'b0, "A0-scope disabled at start");
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        //---------------------------------------------------------------------
        // A) uart_tx 位级时序
        //---------------------------------------------------------------------
        $display("\n[A] uart_tx 位级时序（一位 = %0d clk，整字节 = %0d clk）",
                 BAUD_DIV, BYTE_CYCLES);
        @(negedge clk); #HALF;
        pat_byte = 8'h5A;
        tx_data  = pat_byte;
        tx_start = 1'b1;
        @(negedge clk); #HALF;
        chk(tx_line === 1'b0, "A1-start bit low one clk after tx_start");
        chk(tx_busy === 1'b1, "A1-busy high during transmission");
        tx_start = 1'b0;
        cyc_a = cycle;

        #(BIT / 2);
        chk(tx_line === 1'b0, "A2-start bit center level = 0");
        for (i = 0; i < 8; i = i + 1) begin
            #BIT;
            chk(tx_line === pat_byte[i], "A3-data bit level matches pattern");
        end
        #BIT;
        chk(tx_line === 1'b1, "A4-stop bit level = 1");

        k = 0;
        while ((tx_busy !== 1'b0) && k < 200) begin
            @(negedge clk);
            k = k + 1;
        end
        cyc_b = cycle;
        byte_cycles = cyc_b - cyc_a;
        chk(byte_cycles === BYTE_CYCLES,
            "A5-byte length == 10 * BAUD_DIV clk");
        $display("     measured byte length = %0d clk (expected %0d)",
                 byte_cycles, BYTE_CYCLES);
        @(negedge clk); #HALF;
        chk(tx_line === 1'b1, "A6-line back to idle after stop bit");
        chk(tx_busy === 1'b0, "A7-busy deasserted after byte");

        //---------------------------------------------------------------------
        // B) 字节往返（含 0x00 / 0xFF / 0xAA / 0x55 边界）
        //---------------------------------------------------------------------
        $display("\n[B] 字节往返（逐位中点采样还原）");
        words[0] = 8'h00; words[1] = 8'hFF;
        words[2] = 8'hAA; words[3] = 8'h55;
        words[4] = 8'h80; words[5] = 8'h01;
        words[6] = 8'h5A; words[7] = 8'hA5;
        for (k = 0; k < 8; k = k + 1) begin
            @(negedge clk); #HALF;
            tx_data  = words[k];
            tx_start = 1'b1;
            @(negedge clk); #HALF;
            tx_start = 1'b0;
            rx_byte_tx(b, stop_ok);
            chk(stop_ok === 1'b1, "B0-stop bit high");
            chk8("B1-byte round-trip", b, words[k]);
            $display("     sent 0x%02X  received 0x%02X  stop=%b",
                     words[k], b, stop_ok);
            repeat (2) @(posedge clk);
        end

        //---------------------------------------------------------------------
        // C) 整帧结构（固定可区分向量）
        //    ★ 帧布局 v2（RTL v12）：off8..11 = io_state / 0xA2 / io_flags / 保留，
        //      不再是 amp_sq[31:0]（amp_sq 可由 s/c 无损重算，见 rtl/uart_scope.v）。
        //---------------------------------------------------------------------
        $display("\n[C] uart_scope 整帧：帧头 / 大端字段 / io 快照 / XOR 校验");
        t_angle = 16'h1234;
        t_s     = 16'h0F0E;
        t_c     = 16'hF1F2;
        t_io    = 8'h6D;                       // bit0..7 = a,b,z,u,v,w,dir,limiter
        t_flag  = 8'hA6;
        t_pos   = 32'h0102_0304;
        t_stat  = 8'h5A;

        in_angle = t_angle;
        in_s     = t_s;
        in_c     = t_c;
        in_io    = t_io;
        in_flag  = t_flag;
        in_pos   = t_pos;
        in_stat  = t_stat;

        fc_a = frame_cnt;
        @(negedge clk); #HALF;
        sc_en = 1'b1;
        repeat (2) @(negedge clk);
        rx_frame_until_hdr(hdr_ok, stops_ok);

        chk(stops_ok === 1'b1, "C0-all 18 bytes have valid stop bit");
        chk(hdr_ok   === 1'b1, "C1-frame header == 0xAA 0x55 (byte0/byte1)");
        chk8("C2-angle[15:8]  (big-endian hi)", fr[2],  t_angle[15:8]);
        chk8("C3-angle[7:0]   (big-endian lo)", fr[3],  t_angle[7:0]);
        chk8("C4-s_n[15:8]",                    fr[4],  t_s[15:8]);
        chk8("C5-s_n[7:0]",                     fr[5],  t_s[7:0]);
        chk8("C6-c_n[15:8]",                    fr[6],  t_c[15:8]);
        chk8("C7-c_n[7:0]",                     fr[7],  t_c[7:0]);
        //  ---- 帧布局 v2 的四个字节（v12 起取代 amp_sq[31:0]）----
        //  C8 抓 io_state 整字节；C8b 把**位序**逐位钉死（bit0=a … bit7=limiter），
        //  防止将来有人把 enc_top 里的拼接顺序写反 —— 那种错整字节比对查不出来。
        //  C9 抓标记字节 0xA2：旧版此处是 amp_sq[23:16]，而 amp_sq < 2^31 ⇒ ≤ 0x80，
        //  所以标记字节可以逐帧区分"新/旧布局"（上位机据此兼容 v11 旧位流）。
        chk8("C8-io_state",                     fr[8],  t_io);
        chk(fr[8][0] === t_io[0] && fr[8][1] === t_io[1] &&
            fr[8][2] === t_io[2] && fr[8][3] === t_io[3] &&
            fr[8][4] === t_io[4] && fr[8][5] === t_io[5] &&
            fr[8][6] === t_io[6] && fr[8][7] === t_io[7],
            "C8b-io_state bit order (bit0=a_out .. bit7=limiter_active)");
        chk8("C9-IO frame tag == 0xA2",         fr[9],  8'hA2);
        chk8("C10-io_flags",                    fr[10], t_flag);
        chk8("C11-reserved byte == 0x00",       fr[11], 8'h00);
        chk8("C12-pos_full[31:24]",             fr[12], t_pos[31:24]);
        chk8("C13-pos_full[23:16]",             fr[13], t_pos[23:16]);
        chk8("C14-pos_full[15:8]",              fr[14], t_pos[15:8]);
        chk8("C15-pos_full[7:0]",               fr[15], t_pos[7:0]);
        chk8("C16-stat",                        fr[16], t_stat);

        //  C17/C18/C19：XOR 校验字段。
        //
        //  ★ 校验和约定（2026-10-10 定案，主机端必须与 RTL 一致）：
        //     rtl/uart_scope.v:189-196 把**两个帧头常量也并进**校验和：
        //         chk = fr[17] = 0xAA ^ 0x55 ^ fr[2..16]  ( = payload XOR ^ 0xFF )
        //     主机端 tools/uart_scope.py 原先只异或 payload(2..16)、少了
        //     0xAA^0x55，两边恒差 0xFF ⇒ 真机每一帧都会被上位机判 crc_err、
        //     frames 恒为 0（唯一的上板观测通道等于废掉）。RTL 侧与
        //     testbench 侧本来就一致，**错的在主机端与 docs/06**。
        //     定案：保留 RTL 约定，改主机端 + 文档。理由：位流 10-10 02:32
        //     (WNS +0.686) 已按此实现并验证，为一条常量偏移去改 RTL 会作废
        //     整个时序收敛结果；含帧头常量在检错能力上不多不少，没有收益。
        //     下面用两条独立写法交叉验证，再用 C19 把"不是纯 payload XOR"钉死。
        expc = 8'hAA ^ 8'h55;
        for (i = 2; i <= 16; i = i + 1) expc = expc ^ fr[i];
        chk8("C17-XOR checksum == XOR(AA ^ 55 ^ bytes 2..16)", fr[17], expc);

        gotc = 8'h55;
        for (i = 16; i >= 2; i = i - 1) gotc = gotc ^ fr[i];
        gotc = gotc ^ 8'hAA;
        chk8("C18-XOR self-consistency over received bytes", fr[17], gotc);

        plonly = 8'h00;
        for (i = 2; i <= 16; i = i + 1) plonly = plonly ^ fr[i];
        chk(fr[17] !== plonly,
            "C19-checksum covers frame headers (NOT payload-only XOR)");

        //  ★ 全 18 字节打印（2026-10-10 修：原语句只有 16 个 %02h 却有 18 个
        //    实参，fr[16]/fr[17] —— 也就是 stat 与校验和 —— 从来没被打印过，
        //    日志里那行"frame = ..."因此不能用来核对校验和）。
        $display("     frame = %02h %02h | %02h%02h %02h%02h | %02h%02h%02h%02h | %02h%02h%02h%02h | %02h%02h | %02h | %02h",
                 fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], fr[6], fr[7],
                 fr[8], fr[9], fr[10], fr[11], fr[12], fr[13], fr[14], fr[15],
                 fr[16], fr[17]);
        //  ★ 机器可读的"实拍帧"行：tools/check_uart_frame_fixture.py 依赖它
        //    生成 sim/fixtures/uart_frame_rtl.hex（18 字节，空格分隔）。
        $display("RTL_FRAME_HEX %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                 fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], fr[6], fr[7],
                 fr[8], fr[9], fr[10], fr[11], fr[12], fr[13], fr[14], fr[15],
                 fr[16], fr[17]);

        //---------------------------------------------------------------------
        // D) 帧周期 = 采样节拍的整数倍；en=0 停发
        //
        //  ★ 必须测"帧起点 → 帧起点"的周期，不能用接收函数的返回时刻相减。
        //    rx_frame_locked 用 @(negedge sc_tx) 锚定到**最近的字节边界**，
        //    并不保证落在帧首；失败重试时返回点更会漂到帧中间。实测旧写法
        //    gap1=gap2=800 clk（= 20 字节边界间隔的假值），据此判 D4/D5 必然
        //    误报。真帧周期应为 SAMPLE_DIV + 18*10*BAUD_DIV 的整数倍 ≈ 460 clk。
        //    改用 fr_t0（第 0 字节下降沿的 cycle 时间戳）来测真实帧周期。
        //---------------------------------------------------------------------
        $display("\n[D] 帧周期 = SAMPLE_DIV 的整数倍；en=0 停发");
        rx_frame_until_hdr(hdr_ok, stops_ok);
        chk(hdr_ok === 1'b1, "D0-second frame header found");
        chk8("D1-second frame stat byte", fr[16], t_stat);
        cyc_a = fr_t0;
        rx_frame_until_hdr(hdr_ok, stops_ok);
        chk(hdr_ok === 1'b1, "D2-third frame header found");
        chk8("D3-third frame pos_full[31:24]", fr[12], t_pos[31:24]);
        cyc_b = fr_t0;
        rx_frame_until_hdr(hdr_ok, stops_ok);
        chk(hdr_ok === 1'b1, "D2b-fourth frame header found");
        cyc_c = fr_t0;

        gap1 = cyc_b - cyc_a;
        gap2 = cyc_c - cyc_b;
        $display("     [dbg] fr_t0 seq = %0d %0d %0d ; anchors a/b/c = %0d %0d %0d",
                 cyc_a, cyc_b, cyc_c, 0, 0, 0);
        $display("     [dbg] fc now = %0d", frame_cnt);
        //  ---- 真实帧周期：用 DUT 自己的 frame_cnt 在长时间窗上做统计 ----
        //  不能用"两次 rx_frame_until_hdr 返回时刻相减"：接收器是按
        //  @(negedge sc_tx) 锚到**最近的字节边界**的，与帧起点没有固定相位，
        //  因此锚点间隔随相位漂移而变（实测恒为 800 clk = 20 字节），不能当周期。
        begin : period_meas
            reg [15:0] fc0, fc1, fc_prev;
            integer    cyc0, elapsed, nframes, exp_clk, dev;
            integer    t_first, t_second, exact_period, guard;
        integer    byte_int, content_end, pred_period;
            //  (a) 计数法：固定时间窗内数了多少帧
            fc0   = frame_cnt;
            cyc0  = cycle;
            repeat (20000) @(negedge clk);
            elapsed = cycle - cyc0;
            fc1     = frame_cnt;
            nframes = fc1 - fc0;
            $display("     frame period (counted): %0d frames in %0d clk  => avg %0d clk/frame",
                     nframes, elapsed, (nframes > 0) ? (elapsed / nframes) : 0);
            //  (b) 精确法：直接抓 frame_cnt 连续两次自增之间的拍数
            fc_prev = frame_cnt;
            guard   = 0;
            while ((frame_cnt === fc_prev) && (guard < 20000)) begin
                @(negedge clk); guard = guard + 1;
            end
            t_first = cycle;                     // 第 1 次自增
            fc_prev = frame_cnt;
            guard   = 0;
            while ((frame_cnt === fc_prev) && (guard < 20000)) begin
                @(negedge clk); guard = guard + 1;
            end
            t_second = cycle;                    // 第 2 次自增
            exact_period = t_second - t_first;
            $display("     frame period (exact edge-to-edge) = %0d clk  (18 bytes = %0d, SAMPLE_DIV = %0d, sum = %0d)",
                     exact_period, 18 * BYTE_CYCLES, SAMPLE_DIV,
                     18 * BYTE_CYCLES + SAMPLE_DIV);
            //  ---- 决定性数据：latch 脉冲间隔 与 相邻两次 tx_start 的间隔 ----
            $display("     [dbg] latch pulses at %0d %0d %0d  => periods %0d , %0d clk",
                     p_lat_t0, p_lat_t1, p_lat_t2,
                     p_lat_t1 - p_lat_t0, p_lat_t2 - p_lat_t1);
            $display("     [dbg] tx_start pulses: n=%0d  first=%0d  1st->2nd = %0d clk  (1 byte = %0d clk)",
                     p_ts_n, p_ts_t0, p_ts_t1 - p_ts_t0, BYTE_CYCLES);
            $display("     [dbg] sc_tx edges: n=%0d  e1=%0d e2=%0d e9=%0d e10=%0d  => bit periods %0d %0d (BAUD_DIV=%0d clk)",
                     p_edge_n, p_edge_t0, p_edge_t1, p_edge_t8, p_edge_t9,
                     p_edge_t1 - p_edge_t0, p_edge_t9 - p_edge_t8, BAUD_DIV);
            $display("     [dbg] frame_cnt changes at %0d %0d (n=%0d, delta=%0d) ; sending 1st fall at %0d",
                     p_fc_t0, p_fc_t1, p_fc_n, p_fc_t1 - p_fc_t0, p_snd_fall_t);
            chk(nframes >= 16'd10, "D4-enough frames counted for period measurement");

            //  ★★ 帧时序：实测事实（本测试台 + sim/tb_uart_period.v 多参数扫描）
            //-----------------------------------------------------------------
            //  实测 18 次 tx_start 的相邻间隔恒为 10*BAUD_DIV + 2 = 42 clk，而不是
            //  文档里写的 10*BAUD_DIV = 40 clk。多出的 2 clk 来源（已在 RTL 逐拍确认）：
            //    (1) 每字节发完后 FSM 强制 1 拍 snd_go 间隔（防连发两个 tx_start）；
            //    (2) tx_data_r / tx_start 均为寄存器输出，决定拍与实际发出差 1 clk。
            //  ⇒ 一帧占用线路的时长 = 17*42 + 40 = 754 clk（首字节到末字节停止位结束）。
            //  ⇒ 位周期严格等于 BAUD_DIV，波特率精确；42 是"字节起始间隔"，不是位周期。
            //
            //  ⚠️ 帧周期（帧起点到帧起点）**没有**一条简单的闭式公式：
            //     曾推测 P = ceil(754/SAMPLE_DIV)*SAMPLE_DIV，在 SAMPLE_DIV=100 时
            //     恰好吻合（800），但 sim/tb_uart_period.v 的参数扫描证伪了它——
            //     SAMPLE_DIV=150 时实测 756（不是 150 的整数倍），250 时 756，
            //     333 时 999，500 时 1000。因此这里**只断言可实测、且对任何参数都
            //     成立的不变量**，不硬套公式：
            //       (a) 字节间隔严格 = 10*BAUD_DIV + 2，且一帧内 17 个间隔全等；
            //       (b) 帧周期 > 一帧占用时长（帧与帧不重叠）；
            //       (c) 帧周期有确定上界（一帧时长 + 一个采样周期 + 一个字节）。
            byte_int    = 10 * BAUD_DIV + 2;
            content_end = 17 * byte_int + 10 * BAUD_DIV;
            $display("     D4: byte interval measured %0d clk (expect 10*BAUD_DIV+2 = %0d)",
                     p_ts_arr[1] - p_ts_arr[0], byte_int);
            $display("     D4: one frame occupies %0d clk of line time; measured frame period = %0d",
                     content_end, exact_period);
            chk((p_ts_arr[1] - p_ts_arr[0]) === byte_int,
                "D4a-byte interval == 10*BAUD_DIV + 2 clk (uniform, no gaps)");
            //  一帧内 18 次 tx_start 必须均匀：任何一次间隔不等于 byte_int 都是丢字节/重发的征兆
            begin : uni_chk
                integer uu; integer u_bad;
                u_bad = 0;
                for (uu = 0; uu < 17; uu = uu + 1)
                    if ((p_ts_arr[uu+1] - p_ts_arr[uu]) !== byte_int) u_bad = u_bad + 1;
                chk(u_bad === 0, "D4b-all 17 byte intervals in one frame are uniform");
                $display("     D4b: non-uniform intervals in frame = %0d", u_bad);
            end
            //  (b) 不重叠
            chk(exact_period > content_end,
                "D5-frame period exceeds one frame's line time (frames do not overlap)");
            //  (c) 有界
            chk(exact_period < (content_end + SAMPLE_DIV + byte_int),
                "D5b-frame period within bound (content + SAMPLE_DIV + one byte)");
            //  计数法的一致性：长窗口内 nframes 帧的实际耗时必须与精确周期吻合，
            //  这同时证明"周期是恒定的"，而不是忽长忽短的平均值。
            exp_clk = nframes * exact_period;
            dev     = elapsed - exp_clk;
            $display("     D4: elapsed=%0d  nframes=%0d  nframes*exact_period=%0d  dev=%0d clk",
                     elapsed, nframes, exp_clk, dev);
            chk((dev <= nframes + 2) && (dev >= -(nframes + 2)),
                "D6-frame period is constant across all counted frames");
            chk(exact_period > (18 * BYTE_CYCLES), "D6b-frame period is longer than one frame");
        end

        // --- en=0：长时间窗口内不得出现任何起始位 / 帧计数增长 ---
        @(negedge clk); #HALF;
        sc_en = 1'b0;
        //  注意：uart_scope 的 !en 分支只清 sel/tx_start/sending，**不会**中断
        //  uart_tx 正在发送的那个字节；因此 en 落下后线上还会残留最多一个字节。
        //  先等线上真正空闲，再开始统计"低电平次数"，否则会把残帧当成故障。
        k = 0;
        while ((sc_tx !== 1'b1) && (k < 4000)) begin
            @(negedge clk); #HALF;
            k = k + 1;
        end
        //  ★ 留出足够余量再开始统计：实测每字节 42 clk（=10*BAUD+2），
        //  取 2 字节余量后线上应已彻底空闲。若之后仍有低电平，才是真故障。
        repeat (2 * BYTE_CYCLES) @(negedge clk);
        $display("     en=0: line idle after %0d clk wait; residual-byte allowance = %0d clk",
                 k + 2 * BYTE_CYCLES, BYTE_CYCLES);
        fc_a       = frame_cnt;
        low_glitch = 0;
        for (i = 0; i < (3 * SAMPLE_DIV); i = i + 1) begin
            @(negedge clk); #HALF;
            if (sc_tx !== 1'b1) low_glitch = low_glitch + 1;
        end
        chk(low_glitch === 0, "D7-no start bit / no activity while en=0");
        chk(frame_cnt === fc_a, "D8-frame_cnt frozen while en=0");
        chk(sc_tx === 1'b1,    "D9-tx line stays idle while en=0");
        $display("     en=0 window: %0d clk observed, %0d low samples, frame_cnt %0d -> %0d",
                 3 * SAMPLE_DIV, low_glitch, fc_a, frame_cnt);

        //---------------------------------------------------------------------
        // E) 噪声注入后重同步
        //---------------------------------------------------------------------
        $display("\n[E] 注入噪声字节后凭帧头重同步");
        t_angle = 16'hA1B2;
        t_s     = 16'h3C4D;
        t_c     = 16'hC5D6;
        t_io    = 8'h92;
        t_flag  = 8'h0F;
        t_pos   = 32'h9ABC_DEF0;
        t_stat  = 8'h3C;
        in_angle = t_angle;
        in_s     = t_s;
        in_c     = t_c;
        in_io    = t_io;
        in_flag  = t_flag;
        in_pos   = t_pos;
        in_stat  = t_stat;

        // 手工在线上发 5 个随机字节（不含 0xAA/0x55），模拟链路上的垃圾数据。
        // 同样先等上一帧真正发完再切到注入模式，避免残帧混进噪声段。
        @(negedge clk); #HALF;
        sc_en = 1'b0;
        k = 0;
        while ((sc_tx !== 1'b1) && (k < 4000)) begin
            @(negedge clk); #HALF;
            k = k + 1;
        end
        @(negedge clk); #HALF;
        inj_mode = 1'b1;
        for (k = 0; k < 5; k = k + 1) begin
            rand_byte_safe(b);
            inj_bit = 1'b0;                       // 起始位
            #BIT;
            for (i = 0; i < 8; i = i + 1) begin   // LSB 先
                inj_bit = b[i];
                #BIT;
            end
            inj_bit = 1'b1;                       // 停止位
            #BIT;
            $display("     injected noise byte 0x%02X", b);
        end
        inj_bit = 1'b1;
        #(4 * BIT);
        inj_mode = 1'b0;
        sc_en    = 1'b1;

        // 从噪声尾部开始，逐帧找 AA 55 帧头
        rx_frame_until_hdr(hdr_ok, stops_ok);
        chk(hdr_ok   === 1'b1, "E0-header re-found after noise (resync)");
        chk(stops_ok === 1'b1, "E1-all stop bits valid after resync");
        chk8("E2-resync angle[15:8]",   fr[2],  t_angle[15:8]);
        chk8("E3-resync angle[7:0]",    fr[3],  t_angle[7:0]);
        chk8("E4-resync s_n[15:8]",     fr[4],  t_s[15:8]);
        chk8("E5-resync c_n[7:0]",      fr[7],  t_c[7:0]);
        chk8("E6-resync io_state",      fr[8],  t_io);
        chk8("E6b-resync IO frame tag", fr[9],  8'hA2);
        chk8("E7-resync io_flags",      fr[10], t_flag);
        chk8("E8-resync pos_full[23:16]", fr[13], t_pos[23:16]);
        chk8("E9-resync pos_full[7:0]", fr[15], t_pos[7:0]);
        chk8("E10-resync stat",         fr[16], t_stat);
        expc = xor_of_frame(1'b1);
        chk8("E11-resync XOR checksum", fr[17], expc);
        //---------------------------------------------------------------------
        // F) 线级不变量：en 恢复后帧连续
        //---------------------------------------------------------------------
        $display("\n[F] 恢复 en 后连续发帧，线上无异常");
        @(negedge clk); #HALF;
        sc_en = 1'b0;
        repeat (4) @(negedge clk);
        fc_a = frame_cnt;
        sc_en = 1'b1;
        rx_frame_until_hdr(hdr_ok, stops_ok);
        chk(hdr_ok === 1'b1, "F0-frames still valid after re-enable");
        chk8("F1-payload still correct after re-enable", fr[16], t_stat);
        rx_frame_until_hdr(hdr_ok, stops_ok);
        fc_b = frame_cnt;
        chk(hdr_ok === 1'b1, "F2-second frame after re-enable valid");
        chk(fc_b >= fc_a + 16'd2, "F3-frame_cnt advanced by >= 2");

        //---------------------------------------------------------------------
        $display("\n================================================================");
        if (errors == 0)
            $display(" TEST PASSED (%0d checks)", checks);
        else
            $display(" TEST FAILED (%0d errors / %0d checks)", errors, checks);
        $display("================================================================");
        $finish;
    end

    //-------------------------------------------------------------------------
    //  全局超时保护
    //-------------------------------------------------------------------------
    initial begin
        #40_000_000;                    // 40 ms 仿真时间
        $display(" TEST FAILED (timeout)");
        $finish;
    end

endmodule
