//=============================================================================
//  uart_spi_bridge.v —— UART→SPI 桥：用板载 USB 串口直接读写任意寄存器
//-----------------------------------------------------------------------------
//  为什么需要它
//    rtl/spi_slave.v 是 TW28 风格 32 位 SPI 从站，但板上若没有 SPI 主机，
//    0x0109(OUTPUT)/0x0405(STAT_LATCH)/0x0502(CALIB_CTRL) 这类配置寄存器一个
//    都改不了（只能按 KEY0 做一键标定）。本模块在 FPGA 内部充当"SPI 主机"，
//    把 UART 收到的 4 个字节原样搬成一帧 SPI 命令，于是 PC 端用**板载 USB
//    串口**（COM 口，2 Mbaud）就能读写任意寄存器，不需要任何额外硬件。
//
//  链路
//    PC(COM) --2Mbaud--> uart_rxd(T20) --> uart_rx --> 本模块（SPI 主机）
//            --> u_spi(rtl/spi_slave.v，包模式) --> reg_file
//    本模块 --> uart_tx --> uart_txd(W21) --2Mbaud--> PC(COM)
//
//  命令（4 字节，MSB 先，与 spi_slave 的 32 位包逐位一致）
//    一次发 4 个字节 = 一帧 SPI 命令，字节内容按 spi_slave 协议算好：
//        写 0x0109 = 0x00C0  ->  89 09 00 C0
//        写 0x0405 = 0x0001  ->  8C 05 00 01
//        读 0x05F0           ->  85 F0 00 00
//    （首字节 = {st=1, rm[1:0], wm[1:0], page[2:0]}；算法见 tools/uart_spi.py。）
//    帧同步规则（三条，都会在失步时把状态机拉回"等首字节"）：
//      · 首字节 bit7 必须为 1（= spi_slave 的 st 位），否则丢弃；
//      · 首字节之前线路要空闲 ≥ GAP_MIN 拍（默认 13 位时长 ≈ 6.5 µs）——
//        只对"首字节"要求，命令内部的第 2~4 字节是连续的，不受影响。这条
//        防止"多发了一个字节/上一条命令的残尾"被当成一条新命令执行；
//      · 第 2~4 字节之间超过 TO_DIV 拍（默认 2 ms）没到 ⇒ 丢弃残包回 C_IDLE。
//
//  应答（6 字节，MSB 先）
//    0x5A | resp[31:24] | resp[23:16] | resp[15:8] | resp[7:0] | chk
//    chk = 0x5A ^ resp[31:24] ^ resp[23:16] ^ resp[15:8] ^ resp[7:0]
//    0x5A 与遥测帧头 0xAA/0x55 不同，上位机据此分流（见 tools/uart_spi.py）。
//
//  读为什么要连发两帧
//    spi_slave 是 TW28 重叠式：**命令 N 的响应在命令 N+1 帧才移出**。所以一条
//    "读"命令本帧收到的 MISO 其实是上一条命令的响应。本模块对读命令自动连发
//    两帧（内容完全相同），取**第二帧**的 MISO 作应答 —— 于是"发一次读命令就
//    能拿到该地址的值"，不必像手工 SPI 主机那样同包连发两次。
//    写命令只发一帧，绝不重复写：0x0502 CALIB_CTRL 的 start 位写两次会触发
//    两次标定，这一点在 sim/tb_uart_spi_bridge.v 里有专项检查（T-CALIB）。
//    读写判定与 spi_slave.v:224 完全一致：wm != 00 且 rm != 11 才是写。
//    写命令的应答里 resp 是"上一次读的旧响应"（spi_slave 只在读路径更新
//    resp），上位机对写命令只应把应答当作"链路通+同步"的证据。
//
//  与遥测共用一根 TX
//    uart_scope 以 10 kHz 连续发 18 字节帧（2 Mbaud 下占空约 91%），因此应答
//    必须**抢帧**发送。握手用三根线（都在顶层 enc_top 里连）：
//      scope_idle : 遥测"行空闲且在帧间"（uart_scope 输出 tx_idle）
//      scope_hold : 本模块请求遥测不要再启动新帧（进 uart_scope 输入 hold）
//      tx         : 本模块的 uart_tx 与 scope_tx 二选一输出。切换只发生在
//                   双方都空闲（线为高）时 ⇒ 线上永远不会出现"半个字节"。
//    代价只是应答期间遥测少发几帧，上位机照常解析余下的帧（模拟里专门校验
//    整段过程中遥测帧的 XOR 全部正确，见 tb_uart_spi_bridge 的 tm_bad）。
//
//  与外部 SPI 主机共存
//    ext_busy = 外部 SPI 片选有效（= ~spi_ss_n）。本模块启动自己的帧之前会等
//    ext_busy 释放；但一旦内部帧开始（10.56 µs），外部主机若在同一窗口插进来
//    会被忽略 —— 单板调试场景下两者不会同时用（docs/06 有说明）。
//
//  时序预算（clk 50 MHz、BAUD_DIV=25、SPI_HALF=8）
//    4 字节命令 40 bit = 20.0 µs；一帧 SPI = 8 + 32×(8+8) + 8 = 528 clk
//    = 10.56 µs（sck = 50/16 = 3.125 MHz）；读两帧 ≈ 21.1 µs + 帧间隔；
//    等遥测空闲 ≤ ~100 µs；应答 6 字节 60 bit = 30.0 µs。
//    ⇒ 一条命令往返 ≈ 60 ~ 200 µs（tools/uart_spi.py 的默认超时 0.5 s 足够）。
//
//  sck 上限核对
//    spi_slave 要求每个 sck 周期 ≥ 4 个 clk（过采样 ≥4）；本模块半周期
//    SPI_HALF = 8 拍 ⇒ 周期 16 拍、16 倍过采样，远优于"建议 sck ≤ 10 MHz"。
//
//  资源估计：FF ≈ 200，LUT ≈ 260（含 uart_rx），无 DSP/BRAM。
//=============================================================================
`timescale 1ns / 1ps

module uart_spi_bridge #(
    parameter integer BAUD_DIV = 25,        // UART 位宽（clk 数）；50MHz/2Mbaud
    parameter integer SPI_HALF = 8,         // SPI 半周期（clk 数）
    parameter integer GAP      = 16,        // 帧间隔 / 片选建立-释放（clk 数）
    parameter integer TO_DIV   = 100_000,   // 命令字节间超时（clk 数，2 ms @50MHz）
    parameter integer GAP_MIN  = 13 * 25    // 首字节前的最小线路空闲（clk 数）
)(
    input  wire       clk,
    input  wire       rst_n,

    // ---- UART 侧 ----
    input  wire       rx,             // ← uart_rxd (T20)
    output wire       tx,             // → uart_txd (W21)，与遥测共用一根线
    input  wire       scope_tx,       // 遥测数据泵的 TX（空闲为高）
    input  wire       scope_idle,     // 遥测行空闲（帧间、uart_tx 不忙）
    input  wire       dump_tx,        // 抓包 dump 的 TX（空闲为高，B1 新增）
    input  wire       dump_busy,      // 抓包 dump 正在推流（B1 新增）
    output wire       scope_hold,     // 请求遥测暂停启动新帧
    output wire       tx_hold,        // reply owns the line (dump_busy excluded)

    // ---- 外部 SPI 主机占用检测 ----
    input  wire       ext_busy,       // 外部 SPI 片选有效（低有效片选的取反）

    // ---- 内部 SPI 主机 → u_spi 从站 ----
    output reg        spi_sck,
    output reg        spi_ss_n,
    output reg        spi_mosi,
    input  wire       spi_miso
);

    //=========================================================================
    // 1) UART 接收 + 首字节间隔测量
    //=========================================================================
    wire [7:0] rx_byte;
    wire       rx_valid;

    uart_rx #(
        .BAUD_DIV (BAUD_DIV)
    ) u_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx       (rx),
        .rx_data  (rx_byte),
        .rx_valid (rx_valid),
        .rx_busy  ()
    );

    // 两次 rx_valid 之间的拍数（饱和），用于判定"这一字节是命令的首字节"
    // 还是"上一条命令的连续后续字节"。饱和在 GAP_MIN，避免大计数器。
    reg [15:0] gap_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            gap_cnt <= 16'd0;
        end
        else if (rx_valid) begin
            gap_cnt <= 16'd0;               // 本拍 rx_valid 仍读到"旧"值，见下
        end
        else if (gap_cnt < GAP_MIN[15:0]) begin
            gap_cnt <= gap_cnt + 1'b1;
        end
    end

    //=========================================================================
    // 2) 命令状态机
    //=========================================================================
    localparam [2:0] C_IDLE  = 3'd0,   // 等首字节
                     C_BYTE  = 3'd1,   // 收第 2~4 字节
                     C_ARM   = 3'd2,   // 等外部 SPI 主机释放
                     C_SPI1  = 3'd3,   // 第 1 帧
                     C_GAP2  = 3'd4,   // 读命令的帧间隔
                     C_SPI2  = 3'd5,   // 第 2 帧（仅读命令）
                     C_REPLY = 3'd6,   // 等遥测行空闲
                     C_TX    = 3'd7;   // 发应答，占用 TX

    reg [2:0]  cs;
    reg [31:0] cmd;
    reg [2:0]  bidx;
    reg [19:0] tmo;
    reg [15:0] gap2_cnt;
    reg        is_write;
    reg [31:0] resp_word;
    reg        sp_req;                 // 请求 SPI 主机发一帧（只由本状态机驱动）

    // ---- 下列信号由第 3/4 节的 SPI 主机与应答发送器驱动，但第 2 节的状态机
    //      要读它们。Verilog 要求标识符"先声明后使用"（rtl/spi_slave.v:111
    //      记过同一个坑），所以在这里提前声明。----
    reg [2:0]  sp;
    reg [15:0] spcnt;
    reg [5:0]  spbit;
    reg [31:0] sp_out, sp_in, sp_dout;
    reg        sp_done;
    wire       br_tx;

    // 应答发送
    reg [2:0]  rp_idx;
    reg        rp_go;
    reg [7:0]  tx_data_r;
    reg        tx_start;
    wire       rp_busy;

    // 命令收齐时 cmd 的"下一拍值"（非阻塞赋值，故不能直接用 cmd 判读写）
    wire [31:0] cmd_next = {cmd[23:0], rx_byte};

    function [7:0] reply_byte;
        input [2:0] idx;
        begin
            case (idx)
                3'd0:    reply_byte = 8'h5A;
                3'd1:    reply_byte = resp_word[31:24];
                3'd2:    reply_byte = resp_word[23:16];
                3'd3:    reply_byte = resp_word[15:8];
                3'd4:    reply_byte = resp_word[7:0];
                default: reply_byte = 8'h5A ^ resp_word[31:24] ^ resp_word[23:16]
                                             ^ resp_word[15:8]  ^ resp_word[7:0];
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            cs        <= C_IDLE;
            cmd       <= 32'd0;
            bidx      <= 3'd0;
            tmo       <= 20'd0;
            gap2_cnt  <= 16'd0;
            is_write  <= 1'b0;
            resp_word <= 32'd0;
            sp_req    <= 1'b0;
            rp_idx    <= 3'd0;
            rp_go     <= 1'b0;
            tx_data_r <= 8'd0;
            tx_start  <= 1'b0;
        end
        else begin
            tx_start <= 1'b0;                  // 默认拉低：只发单周期脉冲

            case (cs)
                // ---- 等首字节：st=1 且前面有足够空闲 ----
                C_IDLE: begin
                    tmo      <= 20'd0;
                    gap2_cnt <= 16'd0;
                    if (rx_valid && rx_byte[7] && (gap_cnt >= GAP_MIN[15:0])) begin
                        cmd  <= {24'd0, rx_byte};
                        bidx <= 3'd1;
                        cs   <= C_BYTE;
                    end
                end
                // ---- 收第 2~4 字节（连续，不要求空闲）----
                C_BYTE: begin
                    if (rx_valid) begin
                        tmo <= 20'd0;
                        cmd <= cmd_next;
                        if (bidx == 3'd3) begin
                            // 命令收齐：cmd 的下一拍值就是完整的 32 位帧
                            is_write <= ((cmd_next[28:27] != 2'b00) &&
                                         (cmd_next[30:29] != 2'b11));
                            cs <= C_ARM;
                        end
                        else begin
                            bidx <= bidx + 1'b1;
                        end
                    end
                    else if (tmo >= TO_DIV[19:0]) begin
                        cs <= C_IDLE;          // 半包超时：丢弃残包重新同步
                    end
                    else begin
                        tmo <= tmo + 1'b1;
                    end
                end
                // ---- 等外部主机释放（内部帧 10.56 µs，期间外部被忽略）----
                //   若外部片选长期有效（例如 SPI 主机挂死/引脚悬空），2 ms 后
                //   放弃这条命令：不发应答、不做任何写操作，上位机超时重试即可。
                //   —— 宁可不执行，也不与外部主机抢总线。
                C_ARM: begin
                    if (!ext_busy) begin
                        sp_req <= 1'b1;        // SPI 主机在 SP_IDLE 下一拍起帧
                        tmo    <= 20'd0;
                        cs     <= C_SPI1;
                    end
                    else if (tmo >= TO_DIV[19:0]) begin
                        tmo <= 20'd0;
                        cs  <= C_IDLE;
                    end
                    else begin
                        tmo <= tmo + 1'b1;
                    end
                end
                // ---- 第 1 帧结束 ----
                C_SPI1: begin
                    if (sp_done) begin
                        sp_req    <= 1'b0;
                        resp_word <= sp_dout;
                        if (is_write) begin
                            cs       <= C_REPLY;   // 写：只发一帧，绝不重复写
                        end
                        else begin
                            cs       <= C_GAP2;
                            gap2_cnt <= GAP[15:0];
                        end
                    end
                end
                // ---- 读命令：帧间隔后发第 2 帧 ----
                C_GAP2: begin
                    if ((gap2_cnt == 16'd0) && !ext_busy) begin
                        sp_req <= 1'b1;
                        cs     <= C_SPI2;
                    end
                    else if (gap2_cnt != 16'd0) begin
                        gap2_cnt <= gap2_cnt - 1'b1;
                    end
                end
                // ---- 第 2 帧结束：这一帧的 MISO 才是本命令要读的值 ----
                C_SPI2: begin
                    if (sp_done) begin
                        sp_req    <= 1'b0;
                        resp_word <= sp_dout;
                        cs        <= C_REPLY;
                    end
                end
                // ---- 等遥测行空闲（scope_hold 从 C_REPLY 起已拉高）----
                C_REPLY: begin
                    if (scope_idle) begin
                        rp_idx <= 3'd0;
                        cs     <= C_TX;
                    end
                end
                // ---- 发 6 字节应答（"发一拍歇一拍"，与 uart_scope 同规矩）----
                C_TX: begin
                    if (rp_go) begin
                        rp_go <= 1'b0;
                    end
                    else if (!rp_busy) begin
                        tx_data_r <= reply_byte(rp_idx);
                        tx_start  <= 1'b1;
                        rp_go     <= 1'b1;
                        if (rp_idx == 3'd5) begin
                            cs <= C_IDLE;      // 最后一个字节已在线上
                        end
                        else begin
                            rp_idx <= rp_idx + 1'b1;
                        end
                    end
                end
                default: cs <= C_IDLE;
            endcase
        end
    end

    //=========================================================================
    // 3) SPI 主机（模式 0：sck 空闲低；MOSI 在 sck 低电平期间变化，
    //    MISO 在 sck 上升沿后半个周期由本模块采样）
    //=========================================================================
    localparam [2:0] SP_IDLE  = 3'd0,
                     SP_SETUP = 3'd1,   // 片选建立
                     SP_LOW   = 3'd2,   // sck 低（MOSI 已稳定）
                     SP_HIGH  = 3'd3,   // sck 高（采 MISO）
                     SP_HOLD  = 3'd4;   // 片选释放

    // 说明：sp / spcnt / spbit / sp_out / sp_in / sp_dout / sp_done 已在第 2 节
    // 之前统一声明（Verilog 要求"先声明后使用"），此处不再重复声明。
    always @(posedge clk) begin
        if (!rst_n) begin
            sp        <= SP_IDLE;
            spcnt     <= 16'd0;
            spbit     <= 6'd0;
            sp_out    <= 32'd0;
            sp_in     <= 32'd0;
            sp_dout   <= 32'd0;
            sp_done   <= 1'b0;
            spi_sck   <= 1'b0;
            spi_ss_n  <= 1'b1;
            spi_mosi  <= 1'b0;
        end
        else begin
            sp_done <= 1'b0;               // 默认拉低：只发单周期脉冲

            case (sp)
                SP_IDLE: begin
                    spi_sck  <= 1'b0;
                    spi_ss_n <= 1'b1;
                    spi_mosi <= 1'b0;
                    // !sp_done 保证"上一帧刚结束那一拍"不会被误当成新请求
                    if (sp_req && !sp_done) begin
                        sp_out   <= cmd;       // 移出命令帧（MSB 先）
                        spi_ss_n <= 1'b0;
                        spi_mosi <= cmd[31];
                        spbit    <= 6'd31;
                        spcnt    <= SPI_HALF - 1;
                        sp       <= SP_SETUP;
                    end
                end
                SP_SETUP: begin
                    if (spcnt == 16'd0) begin
                        spcnt <= SPI_HALF - 1;
                        sp    <= SP_LOW;
                    end
                    else begin
                        spcnt <= spcnt - 1'b1;
                    end
                end
                SP_LOW: begin
                    if (spcnt == 16'd0) begin
                        spi_sck <= 1'b1;
                        spcnt   <= SPI_HALF - 1;
                        sp      <= SP_HIGH;
                    end
                    else begin
                        spcnt <= spcnt - 1'b1;
                    end
                end
                SP_HIGH: begin
                    if (spcnt == 16'd0) begin
                        sp_in   <= {sp_in[30:0], spi_miso};   // 上升沿采样
                        spi_sck <= 1'b0;
                        spcnt   <= SPI_HALF - 1;
                        if (spbit == 6'd0) begin
                            sp <= SP_HOLD;
                        end
                        else begin
                            spi_mosi <= sp_out[spbit - 6'd1];
                            spbit    <= spbit - 6'd1;
                            sp       <= SP_LOW;
                        end
                    end
                    else begin
                        spcnt <= spcnt - 1'b1;
                    end
                end
                SP_HOLD: begin
                    if (spcnt == 16'd0) begin
                        spi_ss_n <= 1'b1;
                        sp_dout  <= sp_in;
                        sp_done  <= 1'b1;
                        sp       <= SP_IDLE;
                    end
                    else begin
                        spcnt <= spcnt - 1'b1;
                    end
                end
                default: sp <= SP_IDLE;
            endcase
        end
    end

    //=========================================================================
    // 4) 应答发送器 + TX 二选一
    //=========================================================================
    uart_tx #(
        .BAUD_DIV (BAUD_DIV)
    ) u_reply_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data_r),
        .tx_start (tx_start),
        .tx       (br_tx),
        .busy     (rp_busy)
    );

    // ★ 两件事必须分开，不能共用一个条件（这是仿真里抓到的真实缺陷）：
    //
    //   scope_hold —— "别再启动新帧"。从 C_REPLY 就可以拉高：此刻 SPI 两帧
    //     已经发完，正是通知遥测"下一帧别开"的最早时刻。拉高后遥测仍会把
    //     正在发送的那一帧发完（hold 只挡起帧，不打断在发的帧）。
    //
    //   tx_drive   —— "线上现在归我"。**只能**在应答真的在发（C_TX）或最后
    //     一个字节还在线上（rp_busy）时拉高。若像 scope_hold 那样从 C_REPLY
    //     就抢线，就会在遥测帧**发到一半**时把 TX 切到空闲的 br_tx 上，把那一帧
    //     拦腰截断（表现为遥测帧错、字节数对不上）。
    //     C_TX 之前已等到 scope_idle，所以切换必然发生在"线上空闲（高）"时，
    //     不会出现半个字节；最后一个字节的 stop 位由 rp_busy 兜住。
    assign tx_hold = (cs == C_REPLY) || (cs == C_TX) || rp_busy;
    wire tx_drive = (cs == C_TX) || rp_busy;

    //  dump_busy 期间：① 遥测不许起新帧（scope_hold）；② 线上归 dump。
    //  dump 的启动在 enc_top 里用 scope_idle/!scope_hold 门控过，且 scope_dump
    //  自己还等 START_DELAY + line_idle，因此切换一定发生在线上空闲时。
    assign scope_hold = tx_hold | dump_busy;
    assign tx         = tx_drive ? br_tx : (dump_busy ? dump_tx : scope_tx);

endmodule
