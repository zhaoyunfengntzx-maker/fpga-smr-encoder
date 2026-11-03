//=============================================================================
//  rgmii_if.v —— RGMII 物理接口（TX 用 ODDR 转发时钟，RX 用 IDDR 双沿采样）
//-----------------------------------------------------------------------------
//  只做"电平/边沿"这一层，不含任何协议：GMII 侧仍是 125 MHz 的 8 bit 数据。
//
//  RGMII 的约定（千兆）：
//    · TX：TXD[3:0] 在 TXC 上升沿送出低 4 位、下降沿送出高 4 位；
//          TX_CTL 同样：上升沿 = TXEN，下降沿 = TXEN ^ TXERR。
//    · RX：RXD[3:0] 与 RX_CTL 用 IDDR 双沿采样，拼成 8 bit。
//
//  为什么 TX 用 ODDR 而不是 "always @(posedge) 直接输出"：
//    RGMII 要求时钟与数据严格同相（skew < 0.5 ns）。ODDR 用同一时钟驱动
//    TXC 与 TXD，综合后走的是同类 IOB 资源，PCB 上再等长，才能满足这条。
//
//  IDELAY / 时钟：数据与控制先过 IDELAYE2（VAR_LOAD），tap 由寄存器在运行时写，
//    上板扫 0..31 找眼心，不必为每个 tap 重综合；IDDR 的采样时钟走 BUFIO 而不是
//    BUFG —— BUFG 的插入延迟在 125 MHz（8 ns）下足以把采样点推出数据眼，
//    这是 v60 首板上板 ping 不通的直接原因（IDDR 原来接的是 BUFG 输出）。
//=============================================================================

`timescale 1ns / 1ps

module rgmii_if (
    // ---- GMII 侧（125 MHz，来自 MMCM）----
    input  wire        clk_125,
    input  wire        rst_n,
    input  wire [7:0]  gmii_txd,
    input  wire        gmii_tx_en,
    input  wire        gmii_tx_err,
    output wire [7:0]  gmii_rxd,
    output wire        gmii_rx_dv,
    output wire        gmii_rx_err,
    output wire        gmii_rx_clk,          // 供 RX 逻辑使用的 BUFG 后时钟

    // ---- RGMII 侧（板级引脚）----
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_txc,
    output wire        rgmii_tx_ctl,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rxc,
    input  wire        rgmii_rx_ctl,

    // ---- IDELAY 控制（VAR_LOAD：tap 运行时可写）----
    input  wire [4:0]  idelay_val,           // 0..31，78 ps/档
    input  wire        idelay_ld,            // 单拍装载脉冲
    input  wire        idelay_clk,           // 200 MHz，IDELAYCTRL 参考时钟
    input  wire        rx_swap,              // 1 = 交换 IDDR 两个半字节（上板调试位）
    output wire        idelay_rdy
);

    //=========================================================================
    //  TX：125 MHz 单沿 → 双沿
    //=========================================================================
    // 上升沿发 [3:0]，下降沿发 [7:4]
    genvar i;
    generate
    for (i = 0; i < 4; i = i + 1) begin : g_txd
        ODDR #(
            .DDR_CLK_EDGE("SAME_EDGE"),
            .INIT(1'b0),
            .SRTYPE("SYNC")
        ) u_oddr_txd (
            .Q  (rgmii_txd[i]),
            .C  (clk_125),
            .CE (1'b1),
            .D1 (gmii_txd[i]),
            .D2 (gmii_txd[i+4]),
            .R  (1'b0),
            .S  (1'b0)
        );
    end
    endgenerate

    // TX_CTL：上升沿 = TXEN，下降沿 = TXEN ^ TXERR
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0),
        .SRTYPE("SYNC")
    ) u_oddr_ctl (
        .Q  (rgmii_tx_ctl),
        .C  (clk_125),
        .CE (1'b1),
        .D1 (gmii_tx_en),
        .D2 (gmii_tx_en ^ gmii_tx_err),
        .R  (1'b0),
        .S  (1'b0)
    );

    // TXC：D1=1 / D2=0 ⇒ 与数据同相位的 125 MHz 时钟
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0),
        .SRTYPE("SYNC")
    ) u_oddr_clk (
        .Q  (rgmii_txc),
        .C  (clk_125),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );

    //=========================================================================
    //  RX：双沿采样 → 125 MHz 单沿
    //=========================================================================
    //  RXC 是 PHY 送来的 125 MHz，两路缓冲：
    //    · BUFG  → 给 fabric 用（gmii_rx_clk，eth_rx_mac 的时钟域）
    //    · BUFIO → 给 IDDR 用（IO 时钟网，与 IOB 走线匹配、skew 最小）
    wire rx_clk_buf, rx_clk_io;
    BUFG  u_bufg_rxc  (.I(rgmii_rxc), .O(rx_clk_buf));
    BUFIO u_bufio_rxc (.I(rgmii_rxc), .O(rx_clk_io));
    assign gmii_rx_clk = rx_clk_buf;

    // 数据/控制先过 IDELAYE2（VAR_LOAD）：tap 由 0x0758 运行时写，
    // 上板扫 0..31 找眼心；REFCLK 必须是 200 MHz（IDELAYCTRL 参考）。
    wire [3:0] rxd_dly;
    wire       rx_ctl_dly;

    (* IODELAY_GROUP = "rgmii_rx" *)
    IDELAYCTRL u_idelayctrl (
        .RDY    (idelay_rdy),
        .REFCLK (idelay_clk),
        .RST    (~rst_n)
    );

    genvar k;
    generate
    for (k = 0; k < 4; k = k + 1) begin : g_rxd_dly
        (* IODELAY_GROUP = "rgmii_rx" *)
        IDELAYE2 #(
            .IDELAY_TYPE      ("VAR_LOAD"),
            .IDELAY_VALUE     (0),
            .DELAY_SRC        ("IDATAIN"),
            .SIGNAL_PATTERN   ("DATA"),
            .REFCLK_FREQUENCY (200.0),
            .HIGH_PERFORMANCE_MODE ("TRUE"),
            .CINVCTRL_SEL     ("FALSE"),
            .PIPE_SEL         ("FALSE")
        ) u_idelay (
            .C          (clk_125),
            .CE         (1'b0),
            .INC        (1'b0),
            .LD         (idelay_ld),
            .LDPIPEEN   (1'b0),
            .REGRST     (1'b0),
            .CNTVALUEIN (idelay_val),
            .CNTVALUEOUT(),
            .IDATAIN    (rgmii_rxd[k]),
            .DATAIN     (1'b0),
            .DATAOUT    (rxd_dly[k])
        );
    end
    endgenerate

    (* IODELAY_GROUP = "rgmii_rx" *)
    IDELAYE2 #(
        .IDELAY_TYPE      ("VAR_LOAD"),
        .IDELAY_VALUE     (0),
        .DELAY_SRC        ("IDATAIN"),
        .SIGNAL_PATTERN   ("DATA"),
        .REFCLK_FREQUENCY (200.0),
        .HIGH_PERFORMANCE_MODE ("TRUE"),
        .CINVCTRL_SEL     ("FALSE"),
        .PIPE_SEL         ("FALSE")
    ) u_idelay_ctl (
        .C(clk_125), .CE(1'b0), .INC(1'b0), .LD(idelay_ld), .LDPIPEEN(1'b0),
        .REGRST(1'b0), .CNTVALUEIN(idelay_val), .CNTVALUEOUT(),
        .IDATAIN(rgmii_rx_ctl), .DATAIN(1'b0), .DATAOUT(rx_ctl_dly)
    );

    wire [3:0] rxd_r, rxd_f;         // 上升沿/下降沿采到的半字节
    wire       ctl_r, ctl_f;

    generate
    for (k = 0; k < 4; k = k + 1) begin : g_iddr
        IDDR #(
            .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
            .INIT_Q1(1'b0),
            .INIT_Q2(1'b0),
            .SRTYPE("SYNC")
        ) u_iddr (
            .Q1 (rxd_r[k]),
            .Q2 (rxd_f[k]),
            .C  (rx_clk_io),
            .CE (1'b1),
            .D  (rxd_dly[k]),
            .R  (1'b0),
            .S  (1'b0)
        );
    end
    endgenerate

    IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .INIT_Q1(1'b0),
        .INIT_Q2(1'b0),
        .SRTYPE("SYNC")
    ) u_iddr_ctl (
        .Q1 (ctl_r),
        .Q2 (ctl_f),
        .C  (rx_clk_io),
        .CE (1'b1),
        .D  (rx_ctl_dly),
        .R  (1'b0),
        .S  (1'b0)
    );

    // 上升沿 = 低 4 位（含 RXDV），下降沿 = 高 4 位（含 RXERR）
    // 半字节顺序反了的话，前导码 0x55 翻转后仍是 0x55（看不出来），但 SFD 0xD5
    // 会变成 0x5D —— 现象恰好是"RXDV 在数、一帧都收不全"。rx_swap 让上板时
    // 运行时翻一次，不用为这一个 bit 重新布局布线。
    assign gmii_rxd    = rx_swap ? {rxd_r, rxd_f} : {rxd_f, rxd_r};
    assign gmii_rx_dv  = rx_swap ? ctl_f : ctl_r;
    // ★ 2026-10-28 修复：RGMII 下降沿是 RXDV^RXERR，不是 RXERR 本身。
    //   原写法把 ctl_f（下降沿采到的 RXDV^RXERR）直接当 err，而帧内 RXDV≡1
    //   ⇒ 每一帧都被标成错帧，0x0756 的 err 计数与 CRC 诊断全部失真。
    assign gmii_rx_err = gmii_rx_dv ^ (rx_swap ? ctl_r : ctl_f);

endmodule
