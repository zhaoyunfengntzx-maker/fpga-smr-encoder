//=============================================================================
//  eth_top.v —— 千兆以太网子系统（B2 顶层）
//-----------------------------------------------------------------------------
//  组成：
//    MMCM 50 → 125 MHz（GMII 时钟）+ 200 MHz（IDELAYCTRL 备用）
//    rgmii_if       RGMII 双沿 ↔ GMII 单沿
//    eth_rx_mac     RX：SFD/CRC 校验 → 字节流（rxc 域）
//    async_fifo     RX 字节流跨到 125 MHz 域（rxc 与 clk_125 不同源）
//    eth_reply      ARP 应答 + ICMP echo 应答（125 域）
//    scope_udp      抓包缓冲 → UDP 包流（50 域读、125 域发）
//    eth_tx_mac     TX：前导码/CRC/IFG
//
//  时钟域：
//    clk       50 MHz   （系统/ADC/寄存器）
//    clk_125   125 MHz  （MMCM 输出，TX 与协议栈）
//    rx_clk    125 MHz  （PHY 的 RXC，仅 RX MAC 用；与 clk_125 无固定相位）
//
//  ★ 限制：要求链路协商到 **1000 Mbps**。10/100 Mbps 时 RGMII 只用单沿，
//    本模块的 IDDR 拆分方式不适用（要支持需读 MDIO 的速率位再切模式）。
//    直连 PC 千兆网口时默认就是 1000M，故先不做。
//
//  ★ IDELAY：默认关闭（rgmii_if 的 USE_IDELAY=0）。正点原子板 RGMII 等长、
//    PHY 内部默认带 RX 延时；万一 ping 不通，把 USE_IDELAY 打开并扫 IDELAY_VAL。
//=============================================================================

`timescale 1ns / 1ps

module eth_top #(
    parameter integer DEPTH = 28672       // 抓包缓冲深度，必须与 scope_capture 的 DEPTH 一致
)(
    input  wire        clk,               // 50 MHz
    input  wire        rst_n,             // 同步复位，低有效

    // ---- 板级 PHY ----
    output wire        phy_rst_n,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_txc,
    output wire        rgmii_tx_ctl,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rxc,
    input  wire        rgmii_rx_ctl,

    // ---- 配置（来自 cap_regs，准静态）----
    input  wire [31:0] cfg_ip,
    input  wire [31:0] cfg_host_ip,
    input  wire [31:0] cfg_mac_low,       // MAC = {16'h0200, cfg_mac_low}
    input  wire [15:0] cfg_port,
    input  wire [1:0]  dec_log2,

    // ---- RX 采样延时（IDELAYE2 VAR_LOAD，运行时可调）----
    input  wire [4:0]  idelay_val,
    input  wire        idelay_ld,
    output wire        idelay_rdy,

    // ---- RX 字节对齐调试：半字节顺序翻转 + 每帧前 4 个非前导码字节快照 ----
    input  wire        rx_swap,
    output wire [31:0] rx_dbg,

    // ---- 抓包 → UDP 推送 ----
    input  wire        udp_start,
    input  wire        udp_abort,
    input  wire [15:0] cap_start,
    input  wire [15:0] cap_len,
    output wire [15:0] udp_rd_addr,
    output wire        udp_rd_en,
    input  wire [31:0] udp_rd_data,
    output wire        udp_rd_busy,

    // ---- 状态 ----
    output wire [15:0] tx_pkt,
    output wire [15:0] tx_drop,
    output wire [15:0] rx_pkt,
    output wire        arp_seen,
    output wire        icmp_seen,
    output wire        host_known,
    output wire        udp_busy,
    output wire        udp_done,
    output wire [15:0] udp_pkts,
    output wire [15:0] udp_drop,

    // ---- RX 调试计数器（上板定位"RXC 是否在跳、RXDV 有没有"）----
    output wire [15:0] rx_clk_cnt,
    output wire [15:0] rx_dv_cnt,
    output wire [15:0] rx_byte_cnt,
    output wire [15:0] rx_err_cnt,

    // ---- 连续流（二期）----
    input  wire [15:0] wr_ptr,            // scope_capture 的写前沿
    output wire [15:0] st_rd_addr,
    output wire        st_rd_en,
    input  wire [31:0] st_rd_data,
    input  wire        stream_en,
    input  wire [2:0]  stream_dec,
    output wire        stream_run,
    output wire [31:0] stream_pkts,
    output wire [31:0] stream_drop,
    output wire [15:0] stream_lag,

    // ---- TX 线上头字段快照（调试：连续流为什么主机收不到）----
    output wire [15:0] tx_dbg_frm,        // 上一帧总字节数（含 MAC 头）
    output wire [15:0] tx_dbg_len,        // 线上 IP 总长字段
    output wire [15:0] tx_dbg_port,       // 线上 UDP 目的端口
    output wire [15:0] tx_dbg_mac0,       // 线上目的 MAC 高 16 位
    output wire [15:0] tx_dbg_mac1,       // 线上目的 MAC 低 16 位
    output wire [15:0] tx_dbg_ck,         // 线上 IP 头校验和
    output wire [15:0] tx_dbg_dip0,       // 线上目的 IP 高 16 位
    output wire [15:0] tx_dbg_dip1        // 线上目的 IP 低 16 位
);

    //=========================================================================
    //  1) 时钟
    //=========================================================================
    wire clk_125_raw, clk_200_raw, mmcm_locked, clkfb;
    wire clk_125, clk_200;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (20.000),
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (20.000),      // VCO = 1000 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (8.000),       // 125 MHz
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT1_DIVIDE     (5),           // 200 MHz（IDELAYCTRL 备用）
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk_125_raw),
        .CLKOUT1  (clk_200_raw),
        .CLKOUT2  (),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_bufg_125 (.I(clk_125_raw), .O(clk_125));
    BUFG u_bufg_200 (.I(clk_200_raw), .O(clk_200));

    // 复位：50 域直接同步；125 域等 locked 后再放行
    // ★ 必须把 mmcm_locked 并进异步复位：锁定之前 clk_125 不是干净时钟，
    //   只靠"clk 没跑所以不搬移"是运气，毛刺会把 1 移进同步器。
    reg  [1:0] rst125_sync;
    always @(posedge clk_125) begin
        if (!rst_n || !mmcm_locked) rst125_sync <= 2'b00;
        else                        rst125_sync <= {rst125_sync[0], 1'b1};
    end
    wire rst_n_125 = rst125_sync[1];

    //=========================================================================
    //  2) PHY 复位（上电低 10 ms）
    //=========================================================================
    reg [19:0] phy_rst_cnt;
    reg        phy_rst_n_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            phy_rst_cnt <= 20'd0;
            phy_rst_n_r <= 1'b0;
        end else if (!phy_rst_cnt[19]) begin
            // ★ 2026-10-28 修复：原为 19 bit（2^18/50 MHz = 5.24 ms），
            //   与注释"低 10 ms"不符，也低于 YT8531C 要求的复位脉宽 >=10 ms。
            //   现在 2^19/50 MHz = 10.49 ms。
            phy_rst_cnt <= phy_rst_cnt + 20'd1;
            phy_rst_n_r <= 1'b0;
        end else begin
            phy_rst_n_r <= 1'b1;
        end
    end
    assign phy_rst_n = phy_rst_n_r;

    //=========================================================================
    //  3) RGMII → GMII
    //=========================================================================
    wire [7:0] gmii_txd;
    wire       gmii_tx_en, gmii_tx_err;
    wire [7:0] gmii_rxd;
    wire       gmii_rx_dv, gmii_rx_err, rx_clk;

    rgmii_if u_rgmii (
        .clk_125     (clk_125),
        .rst_n       (rst_n_125),
        .gmii_txd    (gmii_txd),
        .gmii_tx_en  (gmii_tx_en),
        .gmii_tx_err (gmii_tx_err),
        .gmii_rxd    (gmii_rxd),
        .gmii_rx_dv  (gmii_rx_dv),
        .gmii_rx_err (gmii_rx_err),
        .gmii_rx_clk (rx_clk),
        .rgmii_txd   (rgmii_txd),
        .rgmii_txc   (rgmii_txc),
        .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_rxd   (rgmii_rxd),
        .rgmii_rxc   (rgmii_rxc),
        .rgmii_rx_ctl(rgmii_rx_ctl),
        .idelay_val  (idelay_val),
        .idelay_ld   (idelay_ld),
        .idelay_clk  (clk_200),
        .idelay_rdy  (idelay_rdy),
        .rx_swap     (rx_swap)
    );

    //=========================================================================
    //  4) RX MAC + 跨域 FIFO
    //=========================================================================
    reg [1:0] rst_rx_sync;
    always @(posedge rx_clk) begin
        if (!rst_n) rst_rx_sync <= 2'b00;
        else        rst_rx_sync <= {rst_rx_sync[0], (rst_n & mmcm_locked)};
    end
    wire rst_n_rx = rst_rx_sync[1];

    wire       rx_valid, rx_sof, rx_eof, rx_err, rx_done;
    wire [7:0] rx_data;
    wire [15:0] rx_len;

    eth_rx_mac u_rx (
        .clk        (rx_clk),
        .rst_n      (rst_n_rx),
        .gmii_rxd   (gmii_rxd),
        .gmii_rx_dv (gmii_rx_dv),
        .gmii_rx_err(gmii_rx_err),
        .rx_valid   (rx_valid),
        .rx_data    (rx_data),
        .rx_sof     (rx_sof),
        .rx_eof     (rx_eof),
        .rx_err     (rx_err),
        .rx_len     (rx_len),
        .rx_done    (rx_done)
    );

    //=========================================================================
    //  4b) RX 调试计数器（rx_clk 域 → 2 拍同步到 50 MHz）
    //=========================================================================
    //  上板第一件事：看 RXC 有没有在跳（rxc_cnt）、有没有 RXDV（rx_dv_cnt）。
    //  多比特 CDC 只用于诊断（值单调慢变），不做握手。
    reg [15:0] rxc_cnt, rxdv_cnt_r, rxbyte_cnt_r, rxerr_cnt_r;
    reg        rx_dv_d;
    always @(posedge rx_clk) begin
        if (!rst_n_rx) begin
            rxc_cnt       <= 16'd0;
            rxdv_cnt_r    <= 16'd0;
            rxbyte_cnt_r  <= 16'd0;
            rxerr_cnt_r   <= 16'd0;
            rx_dv_d       <= 1'b0;
        end else begin
            rxc_cnt <= rxc_cnt + 16'd1;
            rx_dv_d <= gmii_rx_dv;
            if (gmii_rx_dv && !rx_dv_d) rxdv_cnt_r    <= rxdv_cnt_r + 16'd1;
            if (gmii_rx_dv)             rxbyte_cnt_r  <= rxbyte_cnt_r + 16'd1;
            if (rx_err && rx_eof)       rxerr_cnt_r   <= rxerr_cnt_r + 16'd1;
        end
    end

    reg [15:0] rxc_s1, rxc_s2, rxdv_s1, rxdv_s2, rxby_s1, rxby_s2, rxer_s1, rxer_s2;
    always @(posedge clk) begin
        rxc_s1  <= rxc_cnt;        rxc_s2  <= rxc_s1;
        rxdv_s1 <= rxdv_cnt_r;     rxdv_s2 <= rxdv_s1;
        rxby_s1 <= rxbyte_cnt_r;   rxby_s2 <= rxby_s1;
        rxer_s1 <= rxerr_cnt_r;    rxer_s2 <= rxer_s1;
    end
    assign rx_clk_cnt  = rxc_s2;
    assign rx_dv_cnt   = rxdv_s2;
    assign rx_byte_cnt = rxby_s2;
    assign rx_err_cnt  = rxer_s2;

    // ---- 每帧第 5..8 字节快照（正常 55 55 D5 FF = SFD + DA 首字节）----
    //  半字节顺序反了会看到 55 55 5D FF；数据错位会看到别的组合。
    //  上板读 0x075A/0x075C 就能定性，不用再猜。
    reg [7:0] dbg_b5, dbg_b6, dbg_b7, dbg_b8;
    reg [3:0] dbg_idx;
    always @(posedge rx_clk) begin
        if (!rst_n_rx)
            dbg_idx <= 4'd0;
        else if (!gmii_rx_dv)
            dbg_idx <= 4'd0;
        else begin
            case (dbg_idx)
                4'd5: dbg_b5 <= gmii_rxd;
                4'd6: dbg_b6 <= gmii_rxd;
                4'd7: dbg_b7 <= gmii_rxd;
                4'd8: dbg_b8 <= gmii_rxd;
            endcase
            dbg_idx <= dbg_idx + 4'd1;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [7:0] s5a, s5b, s6a, s6b, s7a, s7b, s8a, s8b;
    always @(posedge clk) begin
        s5a <= dbg_b5; s5b <= s5a;
        s6a <= dbg_b6; s6b <= s6a;
        s7a <= dbg_b7; s7b <= s7a;
        s8a <= dbg_b8; s8b <= s8a;
    end
    assign rx_dbg = {s8b, s7b, s6b, s5b};

    // 字节 + {err, eof, sof} 标记，11 bit
    wire        rxq_full, rxq_almost_full, rxq_empty;
    wire        rxq_wr;
    wire [10:0] rxq_din, rxq_dout;
    wire        rxq_rd;
    wire [9:0]  rxq_wr_level, rxq_rd_level;

    // ★ 2026-10-28 修复：必须把 rx_sof 一起送进 FIFO。
    //   原来 RX FIFO 只带 {err, eof}，而读出是无条件排空的；eth_reply 在
    //   S_DEC/S_PRE/S_CKS/S_EMIT 期间不接收字节 ⇒ 这些字节被读走丢弃，下一帧
    //   从**中间**开始解析，fbuf[12] 判不过，于是 ARP 静默不回。
    //   带 sof 之后，eth_reply 在 S_IDLE 收到 sof 就重新对齐 bcnt。
    assign rxq_din = {rx_err, rx_eof, rx_sof, rx_data};
    assign rxq_wr  = rx_valid || rx_eof;

    async_fifo #(.DW(11), .AW(9), .ALMOST(4)) u_rxq (
        .wr_clk      (rx_clk),
        .wr_rst_n    (rst_n_rx),
        .wr_en       (rxq_wr),
        .din         (rxq_din),
        .full        (rxq_full),
        .almost_full (rxq_almost_full),
        .rd_clk      (clk_125),
        .rd_rst_n    (rst_n_125),
        .rd_en       (rxq_rd),
        .dout        (rxq_dout),
        .empty       (rxq_empty),
        .wr_level    (rxq_wr_level),
        .rd_level    (rxq_rd_level)
    );

    //=========================================================================
    //  5) 协议栈：ARP / ICMP
    //=========================================================================
    //-------------------------------------------------------------------------
    //  50 MHz → 125 MHz 的配置位（准静态）：必须两级同步。
    //  直连会被静态时序分析当成同域路径，报出 −6 ns 的违例；
    //  在硬件上则是亚稳态风险。配置只在打开连接时变，两级同步足够。
    //-------------------------------------------------------------------------
    reg [15:0] s_mac1,  s_mac2;
    reg [15:0] s_port1, s_port2;
    reg [31:0] s_ip1,   s_ip2;
    reg [31:0] s_hip1,  s_hip2;
    reg [1:0]  s_dec1,  s_dec2;
    reg [2:0]  s_sdec1, s_sdec2;   // 连续流抽取比也要两级同步（否则 stream_dec 直跨 125 域）

    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            s_mac1 <= 16'd0;  s_mac2 <= 16'd0;
            s_port1 <= 16'd0; s_port2 <= 16'd0;
            s_ip1 <= 32'd0;   s_ip2 <= 32'd0;
            s_hip1 <= 32'd0;  s_hip2 <= 32'd0;
            s_dec1 <= 2'd0;   s_dec2 <= 2'd0;
            s_sdec1 <= 3'd0;  s_sdec2 <= 3'd0;
        end else begin
            s_mac1  <= cfg_mac_low; s_mac2  <= s_mac1;
            s_port1 <= cfg_port;    s_port2 <= s_port1;
            s_ip1   <= cfg_ip;      s_ip2   <= s_ip1;
            s_hip1  <= cfg_host_ip; s_hip2  <= s_hip1;
            s_dec1  <= dec_log2;    s_dec2  <= s_dec1;
            s_sdec1 <= stream_dec;  s_sdec2 <= s_sdec1;
        end
    end

    wire [47:0] my_mac   = {16'h0200, s_mac2};
    wire [47:0] host_mac;
    wire        arp_p, icmp_p, reply_busy, reply_hold;

    wire [7:0]  rp_tx_data;
    wire        rp_tx_valid, rp_tx_last, rp_tx_ready;

    // RX FIFO 读出：只在 eth_reply 能收字节（S_IDLE）时推进，一拍一个字节。
    // ★ 2026-10-28：原为无条件 !rxq_empty —— eth_reply 处理上一帧期间到达的
    //   字节会被读走丢弃，帧边界全乱。现在由 rx_ready 反压，整帧留在 FIFO 里。
    wire reply_rx_ready;
    wire rxq_rd_en = !rxq_empty && reply_rx_ready;
    assign rxq_rd  = rxq_rd_en;

    reg rl_v;      // 读出的数据下一拍有效
    always @(posedge clk_125) begin
        if (!rst_n_125) rl_v <= 1'b0;
        else            rl_v <= rxq_rd_en;
    end

    eth_reply u_reply (
        .clk        (clk_125),
        .rst_n      (rst_n_125),
        .rx_data    (rxq_dout[7:0]),
        .rx_valid   (rl_v),
        .rx_sof     (rxq_dout[8]),
        .rx_eof     (rxq_dout[9]),
        .rx_err     (rxq_dout[10]),
        .rx_ready   (reply_rx_ready),
        .tx_hold    (reply_hold),
        .my_mac     (my_mac),
        .my_ip      (s_ip2),
        .tx_data    (rp_tx_data),
        .tx_valid   (rp_tx_valid),
        .tx_last    (rp_tx_last),
        .tx_ready   (rp_tx_ready),
        .busy       (reply_busy),
        .host_mac   (host_mac),
        .host_ip    (),
        .arp_seen   (arp_p),
        .icmp_seen  (icmp_p),
        .rx_bad_pulse()
    );

    //=========================================================================
    //  6) 抓包 → UDP
    //=========================================================================
    wire [7:0]  ud_tx_data;
    wire        ud_tx_valid, ud_tx_last, ud_tx_ready;
    wire        ud_tx_busy;

    // 抓包 UDP 侧的计数器在 125 MHz 域，先落到内部原始名上，
    // 再经格雷码同步后驱动对外端口（不能把 125 域寄存器直接接到 50 域）。
    wire [15:0] u_pkts_raw, u_drop_raw;
    wire        udp_busy_raw, udp_done_p125;

    scope_udp #(.DEPTH(DEPTH), .MAX_PTS(350), .SRC_PORT(5000)) u_udp (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (udp_start),
        .abort       (udp_abort),
        .cap_start   (cap_start),
        .n_points    (cap_len),
        .rd_addr     (udp_rd_addr),
        .rd_en       (udp_rd_en),
        .rd_data     (udp_rd_data),
        .rd_busy     (udp_rd_busy),
        .clk_125     (clk_125),
        .rst_n_125   (rst_n_125),
        .dec_log2    (s_dec2),
        .udp_port    (s_port2),
        .my_ip       (s_ip2),
        .host_ip     (s_hip2),
        .my_mac      (my_mac),
        .host_mac    (host_mac),
        .tx_hold     (reply_busy),
        .tx_data     (ud_tx_data),
        .tx_valid    (ud_tx_valid),
        .tx_last     (ud_tx_last),
        .tx_ready    (ud_tx_ready),
        .tx_busy     (ud_tx_busy),
        .busy        (udp_busy_raw),
        .done        (udp_done_p125),
        .pkt_cnt     (u_pkts_raw),
        .drop_cnt    (u_drop_raw)
    );

    //=========================================================================
    //  6b) 连续流发送
    //=========================================================================
    wire        st_tx_valid, st_tx_last, st_tx_ready, st_tx_busy;
    wire [7:0]  st_tx_data;
    wire [31:0] st_pkts_125, st_drop_50;
    wire [31:0] st_underflow;      // stream_tx 的 underflow 是 32 bit，别接成 1 bit
    wire [15:0] st_lag;

    // ★ MAX_PTS 必须 ≤ 异步 FIFO 深度（AW=8 → 256）：启动判据是
    //   fifo_rd_level >= MAX_PTS + 32，350+32=382 > 256 时 start_ok 永远
    //   不成立 —— 上板表现为流开着但 pkts=0、drop 疯涨。改成 200 后
    //   232 ≤ 256，一包 200 点 = 800 B 载荷，12.5 MSPS 下 62.5 k 包/s、
    //   约 421 Mbps，仍在千兆以内。
    stream_tx #(.DEPTH(DEPTH), .MAX_PTS(200), .SRC_PORT(5000)) u_stream (
        .host_mac  (host_mac),
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (stream_en),
        .dec_log2    (s_sdec2),
        .wr_ptr      (wr_ptr),
        .rd_addr     (st_rd_addr),
        .rd_en       (st_rd_en),
        .rd_data     (st_rd_data),
        .drop_samples(st_drop_50),
        .clk_125     (clk_125),
        .rst_n_125   (rst_n_125),
        .my_mac      (my_mac),
        .my_ip       (s_ip2),
        .host_ip     (s_hip2),
        .udp_port    (s_port2),
        .tx_data     (st_tx_data),
        .tx_valid    (st_tx_valid),
        .tx_last     (st_tx_last),
        .tx_ready    (st_tx_ready),
        .tx_busy     (st_tx_busy),
        .pkts        (st_pkts_125),
        .fifo_ovf    (),
        .underflow   (st_underflow),
        .lag         (st_lag)
    );

    assign stream_lag  = st_lag;
    assign stream_run  = stream_en;

    // ★ 交叉域加法会撑爆 3 ns 的 CDC 预算：st_underflow 是 clk_125 域的 32 位
    //   计数器，若直接和 st_drop_50 相加，综合出的是"125M 寄存器 → 32 位加法器
    //   → 状态读回 mux → sys 寄存器"共 15 级逻辑的一条路，实测 4.94 ns
    //   （约束 3.000），WNS 直接被它拖到 -1.974。把两个操作数先在 sys 域各打
    //   一拍，跨域部分就只剩单根寄存器的布线；加法器留在 sys 域，20 ns 预算。
    //   （计数器只用于诊断，慢变，不做多比特握手。）
    reg [31:0] st_underflow_s, st_drop_s;
    always @(posedge clk) begin
        if (!rst_n) begin
            st_underflow_s <= 32'd0;
            st_drop_s      <= 32'd0;
        end else begin
            st_underflow_s <= st_underflow;
            st_drop_s      <= st_drop_50;
        end
    end
    assign stream_drop = st_underflow_s + st_drop_s;

    // 125 域包计数 → 50 域（格雷码 + 两级同步，32 bit）
    function [31:0] b2g32;
        input [31:0] b;
        begin
            b2g32 = b ^ (b >> 1);
        end
    endfunction

    function [31:0] g2b32;
        input [31:0] g;
        integer k;
        begin
            g2b32[31] = g[31];
            for (k = 30; k >= 0; k = k - 1)
                g2b32[k] = g2b32[k+1] ^ g[k];
        end
    endfunction

    wire [31:0] st_pkts_g = b2g32(st_pkts_125);
    reg  [31:0] st_p1, st_p2;
    always @(posedge clk) begin
        if (!rst_n) begin
            st_p1 <= 32'd0;
            st_p2 <= 32'd0;
        end else begin
            st_p1 <= st_pkts_g;
            st_p2 <= st_p1;
        end
    end
    assign stream_pkts = g2b32(st_p2);

    //=========================================================================
    //  7) TX 仲裁：ARP/ICMP 优先（它帧短、且主机在等），其次抓包 UDP，最后连续流
    //=========================================================================
    // ★ 2026-10-28 修复（"以太网容易连不上"的头号嫌疑）：
    //   原来 reply_hold = ud_tx_busy | st_tx_busy ⇒ 连续流一开（st_tx_busy 几乎
    //   恒 1）、抓包推流 82 包≈2 ms 窗口内（ud_tx_busy 恒 1），**所有 ARP/ICMP
    //   请求被直接丢弃**。PC 的 ARP 缓存 15~45 s 过期后正好撞上推流 ⇒ ping 不通、
    //   抓包没数据，而串口一切正常。docs/24 实测：停流 ping 20/20，满速约 1/3。
    //   eth_reply 在 S_EMIT 里会一直举着 tx_valid 等仲裁器给 grant，不需要丢帧：
    //   仲裁器是**帧级** grant（gnt_act），下一个帧间隙就会把总线让给它。
    //   代价只是流期间每帧间插一个 60 B 的应答（<0.5% 带宽）。
    assign reply_hold = 1'b0;

    // 三个发送源共用一个 MAC：谁在发帧，ready 就只回给谁。
    // ★ 必须是**帧级 grant**：原来按拍做组合优先级（reply > stream > udp），
    //   而 eth_reply 查到 ARP 后要 ~20 拍才拉 valid、stream 从 IDLE 到 HDR 只
    //   2-3 拍，帧间隙 tx_busy 只低 1 拍 —— 抓到这个缝就会在别人帧中间换源，
    //   两帧混成一条废帧。现在把源锁到 tx_last 被 MAC 接收为止。
    wire mac_ready;

    reg  [1:0] gnt;          // 0=空闲, 1=ARP/ICMP, 2=连续流, 3=抓包 UDP
    reg        gnt_act;      // 一帧进行中：锁住 gnt 直到 tx_last 被接收

    wire [7:0] m_tx_data  = (gnt == 2'd1) ? rp_tx_data  :
                            (gnt == 2'd2) ? st_tx_data  : ud_tx_data;
    wire       m_tx_valid = (gnt == 2'd1) ? rp_tx_valid :
                            (gnt == 2'd2) ? st_tx_valid :
                            (gnt == 2'd3) ? ud_tx_valid : 1'b0;
    wire       m_tx_last  = (gnt == 2'd1) ? rp_tx_last  :
                            (gnt == 2'd2) ? st_tx_last  : ud_tx_last;

    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            gnt     <= 2'd0;
            gnt_act <= 1'b0;
        end else if (!gnt_act) begin
            // 空闲才换源；优先级不变（应答帧短、主机在等）
            if (rp_tx_valid) begin
                gnt <= 2'd1; gnt_act <= 1'b1;
            end else if (st_tx_valid) begin
                gnt <= 2'd2; gnt_act <= 1'b1;
            end else if (ud_tx_valid) begin
                gnt <= 2'd3; gnt_act <= 1'b1;
            end
        end else if (m_tx_valid && mac_ready && m_tx_last) begin
            gnt_act <= 1'b0;     // 帧尾交出去，下一拍才允许换源
        end
    end

    // ---- TX 线上头字段快照 ----------------------------------------------------
    // 直接抓 MAC 口上的字节（m_tx_*），与主机 socket 收不到时的猜测无关：
    //   byte 16/17 = IP 总长，byte 34/35 = UDP 目的端口，末字节计数 = 帧长。
    reg [15:0] txdbg_cnt, txdbg_frm_r, txdbg_len_r, txdbg_port_r;
    reg [15:0] txdbg_mac0_r, txdbg_mac1_r, txdbg_ck_r, txdbg_dip0_r, txdbg_dip1_r;
    reg [15:0] tf1, tf2, tl1, tl2, tp1, tp2;
    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            txdbg_cnt    <= 16'd0;
            txdbg_frm_r  <= 16'd0;
            txdbg_len_r  <= 16'd0;
            txdbg_port_r <= 16'd0;
        end else if (m_tx_valid && mac_ready) begin
            txdbg_cnt <= m_tx_last ? 16'd0 : (txdbg_cnt + 16'd1);
            if (txdbg_cnt == 16'd16) txdbg_len_r[15:8] <= m_tx_data;
            if (txdbg_cnt == 16'd17) txdbg_len_r[7:0]  <= m_tx_data;
            if (txdbg_cnt == 16'd34) txdbg_port_r[15:8] <= m_tx_data;
            if (txdbg_cnt == 16'd35) txdbg_port_r[7:0]  <= m_tx_data;
            if (txdbg_cnt == 16'd0)  txdbg_mac0_r[15:8] <= m_tx_data;
            if (txdbg_cnt == 16'd1)  txdbg_mac0_r[7:0]  <= m_tx_data;
            if (txdbg_cnt == 16'd4)  txdbg_mac1_r[15:8] <= m_tx_data;
            if (txdbg_cnt == 16'd5)  txdbg_mac1_r[7:0]  <= m_tx_data;
            if (txdbg_cnt == 16'd24) txdbg_ck_r[15:8]   <= m_tx_data;
            if (txdbg_cnt == 16'd25) txdbg_ck_r[7:0]    <= m_tx_data;
            if (txdbg_cnt == 16'd30) txdbg_dip0_r[15:8] <= m_tx_data;
            if (txdbg_cnt == 16'd31) txdbg_dip0_r[7:0]  <= m_tx_data;
            if (txdbg_cnt == 16'd32) txdbg_dip1_r[15:8] <= m_tx_data;
            if (txdbg_cnt == 16'd33) txdbg_dip1_r[7:0]  <= m_tx_data;
            if (m_tx_last)           txdbg_frm_r <= txdbg_cnt + 16'd1;
        end
    end

    // 慢变调试值：2 拍同步到 50 MHz（多 bit 不做握手，只用于观察）
    reg [15:0] m01, m02, m11, m12, ck1, ck2, d01, d02, d11, d12;
    always @(posedge clk) begin
        m01 <= txdbg_mac0_r; m02 <= m01;
        m11 <= txdbg_mac1_r; m12 <= m11;
        ck1 <= txdbg_ck_r;   ck2 <= ck1;
        d01 <= txdbg_dip0_r; d02 <= d01;
        d11 <= txdbg_dip1_r; d12 <= d11;
        tf1 <= txdbg_frm_r;  tf2 <= tf1;
        tl1 <= txdbg_len_r;  tl2 <= tl1;
        tp1 <= txdbg_port_r; tp2 <= tp1;
    end
    assign tx_dbg_frm  = tf2;
    assign tx_dbg_len  = tl2;
    assign tx_dbg_port = tp2;
    assign tx_dbg_mac0 = m02;
    assign tx_dbg_mac1 = m12;
    assign tx_dbg_ck   = ck2;
    assign tx_dbg_dip0 = d02;
    assign tx_dbg_dip1 = d12;

    assign rp_tx_ready = mac_ready & (gnt == 2'd1);
    assign st_tx_ready = mac_ready & (gnt == 2'd2);
    assign ud_tx_ready = mac_ready & (gnt == 2'd3);

    wire       tx_done_p;

    //=========================================================================
    //  8) TX MAC
    //=========================================================================
    eth_tx_mac u_tx (
        .clk        (clk_125),
        .rst_n      (rst_n_125),
        .tx_valid   (m_tx_valid),
        .tx_data    (m_tx_data),
        .tx_last    (m_tx_last),
        .tx_ready   (mac_ready),
        .gmii_tx_en (gmii_tx_en),
        .gmii_txd   (gmii_txd),
        .gmii_tx_err(gmii_tx_err),
        .busy       (),
        .done       (tx_done_p),
        .frame_len  ()
    );

    //=========================================================================
    //  9) 统计与状态（125 域 → 50 域准静态同步）
    //=========================================================================
    reg [15:0] tx_pkt_r, tx_drop_r;
    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            tx_pkt_r  <= 16'd0;
            tx_drop_r <= 16'd0;
        end else begin
            if (tx_done_p) tx_pkt_r <= tx_pkt_r + 16'd1;
            tx_drop_r <= u_drop_raw;      // 必须是 125 域原值；用同步后的值会再跨回 125
        end
    end

    // ARP / ICMP 粘滞标志（125 域）
    reg arp_sticky, icmp_sticky;
    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            arp_sticky  <= 1'b0;
            icmp_sticky <= 1'b0;
        end else begin
            if (arp_p)  arp_sticky  <= 1'b1;
            if (icmp_p) icmp_sticky <= 1'b1;
        end
    end

    // RX 帧计数：rx 域 toggle → 125 域计数
    reg rx_done_tgl;
    always @(posedge rx_clk) begin
        if (!rst_n_rx) rx_done_tgl <= 1'b0;
        else if (rx_done) rx_done_tgl <= ~rx_done_tgl;
    end

    reg rx_t_s1, rx_t_s2, rx_t_d, rx_done_rx;
    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            rx_t_s1 <= 1'b0; rx_t_s2 <= 1'b0; rx_t_d <= 1'b0;
            rx_done_rx <= 1'b0;
        end else begin
            rx_t_s1 <= rx_done_tgl;
            rx_t_s2 <= rx_t_s1;
            rx_t_d  <= rx_t_s2;
            if (rx_t_s2 != rx_t_d) rx_done_rx <= 1'b1;
            else                   rx_done_rx <= 1'b0;
        end
    end

    reg [1:0] s_arp, s_icmp, s_host;
    reg [15:0] rx_pkt_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_arp <= 2'b00; s_icmp <= 2'b00; s_host <= 2'b00;
            rx_pkt_r <= 16'd0;
        end else begin
            s_arp  <= {s_arp[0],  arp_sticky};
            s_icmp <= {s_icmp[0], icmp_sticky};
            s_host <= {s_host[0], (host_mac != 48'hFF_FF_FF_FF_FF_FF)};
            if (rx_done_rx) rx_pkt_r <= rx_pkt_r + 16'd1;
        end
    end

    assign arp_seen   = s_arp[1];
    assign icmp_seen  = s_icmp[1];
    assign host_known = s_host[1];

    //-------------------------------------------------------------------------
    //  125 域 16 bit 计数器 → 50 域：走**格雷码**，每拍只变 1 bit，
    //  再用两级触发器同步（多 bit 二进制直接跨域会在采样瞬间出现乱码值）。
    //-------------------------------------------------------------------------
    function [15:0] bin2gray;
        input [15:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [15:0] gray2bin;
        input [15:0] g;
        integer k;
        begin
            gray2bin[15] = g[15];
            for (k = 14; k >= 0; k = k - 1)
                gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

    //-------------------------------------------------------------------------
    //  125 → 50：busy 是电平（两级同步即可），done 是单拍脉冲（必须转 toggle）
    //-------------------------------------------------------------------------
    reg         udp_done_tgl;
    always @(posedge clk_125) begin
        if (!rst_n_125)         udp_done_tgl <= 1'b0;
        else if (udp_done_p125) udp_done_tgl <= ~udp_done_tgl;
    end

    reg [2:0] udp_busy_s, udp_done_s;
    always @(posedge clk) begin
        if (!rst_n) begin
            udp_busy_s <= 3'd0;
            udp_done_s <= 3'd0;
        end else begin
            udp_busy_s <= {udp_busy_s[1:0], udp_busy_raw};
            udp_done_s <= {udp_done_s[1:0], udp_done_tgl};
        end
    end

    wire udp_done_p = udp_done_s[2] ^ udp_done_s[1];   // 50 域单拍脉冲

    // done 做成"粘滞到下一次抓包开始"，否则上位机轮询状态位会漏掉
    reg udp_done_sticky;
    always @(posedge clk) begin
        if (!rst_n)          udp_done_sticky <= 1'b0;
        else if (udp_start)  udp_done_sticky <= 1'b0;
        else if (udp_done_p) udp_done_sticky <= 1'b1;
    end

    assign udp_busy = udp_busy_s[1];
    assign udp_done = udp_done_sticky;

    // 把 udp_pkts/udp_drop（来自 scope_udp，125 域）与 tx_pkt_r/tx_drop_r
    // 都先转格雷码，再跨到 50 MHz。
    wire [15:0] udp_pkts_g  = bin2gray(u_pkts_raw);
    wire [15:0] udp_drop_g  = bin2gray(u_drop_raw);
    wire [15:0] tx_pkt_g    = bin2gray(tx_pkt_r);
    wire [15:0] tx_drop_g   = bin2gray(tx_drop_r);

    reg [15:0] udp_pkts_s1, udp_pkts_s2;
    reg [15:0] udp_drop_s1, udp_drop_s2;
    reg [15:0] tx_pkt_s1,   tx_pkt_s2;
    reg [15:0] tx_drop_s1,  tx_drop_s2;

    always @(posedge clk) begin
        if (!rst_n) begin
            udp_pkts_s1 <= 16'd0; udp_pkts_s2 <= 16'd0;
            udp_drop_s1 <= 16'd0; udp_drop_s2 <= 16'd0;
            tx_pkt_s1   <= 16'd0; tx_pkt_s2   <= 16'd0;
            tx_drop_s1  <= 16'd0; tx_drop_s2  <= 16'd0;
        end else begin
            udp_pkts_s1 <= udp_pkts_g;  udp_pkts_s2 <= udp_pkts_s1;
            udp_drop_s1 <= udp_drop_g;  udp_drop_s2 <= udp_drop_s1;
            tx_pkt_s1   <= tx_pkt_g;    tx_pkt_s2   <= tx_pkt_s1;
            tx_drop_s1  <= tx_drop_g;   tx_drop_s2  <= tx_drop_s1;
        end
    end

    assign tx_pkt   = gray2bin(tx_pkt_s2);
    assign tx_drop  = gray2bin(tx_drop_s2);
    assign udp_pkts = gray2bin(udp_pkts_s2);
    assign udp_drop = gray2bin(udp_drop_s2);
    assign rx_pkt   = rx_pkt_r;

endmodule
