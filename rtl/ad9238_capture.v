//=============================================================================
// 模块名 : ad9238_capture
// 文件   : rtl/ad9238_capture.v
// 功能   : AD9238 双通道 12bit ADC 数据捕获 + 去偏置（偏移二进制 -> 二进制补码）
//          s_raw = ch1_d - 2048      （CH1 = 正弦通道）
//          c_raw = ch2_d - 2048      （CH2 = 余弦通道）
//
// 【ADC 接口与时钟说明 —— 必读】
//   * AD9238 是双通道 12bit、65 MSPS 的并行输出 ADC，两个通道各有**独立**的
//     12bit 并行数据总线，输出编码为**偏移二进制（offset binary）**：
//         0x000 = -FS，0x800 = 0 V，0xFFF = +FS
//     本模块把它转成二进制补码：code - 2048，范围 -2048…+2047。
//   * 本设计使用的 AD9238 模块上**没有可用的输出数据时钟 DCO**（模块的
//     CH1_CLK/CH2_CLK 引脚被用作采样时钟输入，由 FPGA 驱动）。因此：
//         FPGA 通过 ODDR 驱动 CLK_A / CLK_B（50 MHz）；
//         ADC 在时钟上升沿采样，数据在 tPD = 2…6 ns 之后出现在数据总线上；
//         ADC 内部为 7 级流水线（7 个采样时钟周期后数据才对应本次采样）。
//     因为数据是"随采样时钟一起送出去"的，没有随路时钟，所以 FPGA 侧**必须**
//     用一个与 clk_adc 同源、相位固定的时钟去捕获数据。
//     【实现口径 —— 与早期文档不同，以代码为准】本设计**没有**用 MMCM 产生相移
//     时钟，而是：
//         * rtl/enc_top.v:139-160 用两个 ODDR（D1=1'b0, D2=1'b1）把 50 MHz clk_i
//           反相输出成 ad_clk（= clk_i 的 180° 反相），ADC 就在**这一沿**采样；
//         * rtl/enc_top.v:228 把捕获时钟 `.clk_cap(clk_i)` 直接接成未反相的 clk_i。
//     两者相差正好 180°（半周期 10 ns），等效于"把捕获沿放在数据窗口中心"：
//     ADC 在 clk_i 下降沿采样 → 数据经 tPD = 2…6 ns 在周期内 ~12…16 ns 处稳定，
//     而 clk_i 的上升沿在 ~20 ns 处捕获它 ⇒ 建立余量约 4 ns、保持余量约 12 ns，
//     无需 MMCM 也成立（时序分析见 constr/enc_top.xdc:150-249 的推导与
//     docs/DEV_STATUS.md §1.19 —— 那里的 set_input_delay 是诚实值而非笔误）。
//     7 级流水线延迟只影响"数据对应哪一次采样"的绝对时刻，不影响每拍的捕获正确性，
//     顶层做相位/位置对齐时按 7 拍（外加本模块的 3 拍）一起补偿即可。
//   * 每个数据位都过两级同步器（ASYNC_REG），第 1 级用 clk_cap 在数据有效窗口
//     中心采样，第 2 级提供整周期余量并隔离亚稳态。
//
// Latency : 3   （第 1 拍：一级同步；第 2 拍：二级同步；第 3 拍：减 2048）
// 资源估计: 2*12*2 = 48 FF（数据同步器）+ 2 OTR 同步 FF + 26 FF（第 3 级与标志）
//           + 约 24 LUT（12bit 减法器 x2）。0 DSP。
// 关键假设:
//   1. clk_cap 与驱动 ADC 的 clk_adc 同源、相位差固定 180°
//      （本设计：ad_clk = ODDR 反相输出、clk_cap = 未反相的 clk_i，见上文）。
//   2. en / clr_otr 视为**已经同步到 clk_cap 域**的同步信号
//      （顶层若从 clk_sys 域写入，必须先过 cdc_sync2）。
//   3. OTR 是 ADC 给出的电平（超量程指示），本模块把它做成 sticky 标志：
//      一旦置 1 就保持，直到 clr_otr=1、rst_n=0 或 en 的下降沿清除。
//      清除优先于置位（同一拍既有清除又有超量程时，清除获胜）。
//   4. adc_valid 在非复位期间恒为 1（ADC 连续采样、每拍都有新样本），
//      保持全工程"valid 流水"接口一致性；en=0 时数据被强制为 0（上电静默）。
//=============================================================================
`timescale 1ns / 1ps

module ad9238_capture #(
    parameter integer DW = 12            // ADC 位宽
)(
    input  wire                clk_cap,  // 180° 捕获时钟（50 MHz，与 clk_adc 同源）
    input  wire                rst_n,    // 同步复位，低有效
    input  wire [DW-1:0]       ch1_d,    // CH1 数据（异步输入，来自 AD9238）
    input  wire [DW-1:0]       ch2_d,    // CH2 数据
    input  wire                ch1_otr,  // CH1 超量程标志
    input  wire                ch2_otr,  // CH2 超量程标志
    input  wire                en,       // 1=输出有效数据；0=输出 0（用于上电静默）
    input  wire                clr_otr,  // 1=清除 sticky 的 OTR 标志（写 1 清）
    output reg  signed [DW-1:0] s_raw,   // = ch1_d - 2048（二进制补码）
    output reg  signed [DW-1:0] c_raw,   // = ch2_d - 2048
    output reg                 otr,      // 两个通道 OTR 的锁存或（sticky）
    output reg                 adc_valid // 每拍都为 1（ADC 连续采样）
);

    // ---- 常量 ----
    localparam integer DWP = DW + 1;                          // 中间位宽（13）
    localparam signed [DWP-1:0] OFS_CODE = (1 << (DW - 1));   // 2048 = 0x800 = 0 V

    //=========================================================================
    // 第 1/2 级：每个数据位两级同步器（ASYNC_REG 保证就近布局）
    //=========================================================================
    (* ASYNC_REG = "TRUE" *) reg [DW-1:0] ch1_meta;
    (* ASYNC_REG = "TRUE" *) reg [DW-1:0] ch2_meta;
    (* ASYNC_REG = "TRUE" *) reg [DW-1:0] ch1_sync;
    (* ASYNC_REG = "TRUE" *) reg [DW-1:0] ch2_sync;

    (* ASYNC_REG = "TRUE" *) reg        otr1_meta;
    (* ASYNC_REG = "TRUE" *) reg        otr2_meta;
    (* ASYNC_REG = "TRUE" *) reg        otr1_sync;
    (* ASYNC_REG = "TRUE" *) reg        otr2_sync;

    // ---- en 下降沿检测（clk_cap 域）----
    reg en_d;

    always @(posedge clk_cap) begin
        if (!rst_n) begin
            en_d <= 1'b0;
        end else begin
            en_d <= en;
        end
    end

    wire en_fall = en_d & (~en);      // en 的下降沿（clk_cap 域）

    // 清除请求：clr_otr=1 或 en 下降沿。清除时必须同时冲刷 OTR 同步流水线，
    // 否则"清除前"仍留在同步器里的旧 OTR 电平会在下一拍把 sticky 标志重新置起，
    // 使"清除优先于置位 / en 下降沿清除"失效。
    wire otr_flush = clr_otr | en_fall;

    always @(posedge clk_cap) begin
        if (!rst_n) begin
            ch1_meta  <= {DW{1'b0}};
            ch2_meta  <= {DW{1'b0}};
            ch1_sync  <= {DW{1'b0}};
            ch2_sync  <= {DW{1'b0}};
            otr1_meta <= 1'b0;
            otr2_meta <= 1'b0;
            otr1_sync <= 1'b0;
            otr2_sync <= 1'b0;
        end else begin
            ch1_meta  <= ch1_d;      // 第 1 级：数据有效窗口中心采样
            ch2_meta  <= ch2_d;
            ch1_sync  <= ch1_meta;   // 第 2 级：整周期余量 / 抗亚稳态
            ch2_sync  <= ch2_meta;
            if (otr_flush) begin     // 清除请求：丢弃流水线中"清除前"的旧 OTR 电平
                otr1_meta <= 1'b0;
                otr2_meta <= 1'b0;
                otr1_sync <= 1'b0;
                otr2_sync <= 1'b0;
            end else begin
                otr1_meta <= ch1_otr;
                otr2_meta <= ch2_otr;
                otr1_sync <= otr1_meta;
                otr2_sync <= otr2_meta;
            end
        end
    end

    //=========================================================================
    // 第 3 级：偏移二进制 -> 二进制补码（code - 2048）
    //   先把无符号码零扩展一位再当有符号数用，避免 code=0x800 被误当负数。
    //=========================================================================
    wire signed [DWP-1:0] ch1_ext = {1'b0, ch1_sync};         // 0…4095（正数）
    wire signed [DWP-1:0] ch2_ext = {1'b0, ch2_sync};

    wire signed [DWP-1:0] s_calc = ch1_ext - $signed(OFS_CODE);   // -2048…+2047
    wire signed [DWP-1:0] c_calc = ch2_ext - $signed(OFS_CODE);

    // ---- OTR 合并（同步后的电平）----
    wire otr_now = otr1_sync | otr2_sync;

    //=========================================================================
    // 输出级：数据 + OTR sticky 标志 + adc_valid
    //=========================================================================
    always @(posedge clk_cap) begin
        if (!rst_n) begin
            s_raw     <= {DW{1'b0}};
            c_raw     <= {DW{1'b0}};
            otr       <= 1'b0;
            adc_valid <= 1'b0;
        end else begin
            // ---- 数据：en=0 时强制 0（上电静默） ----
            if (en) begin
                s_raw <= s_calc[DW-1:0];   // 截掉冗余符号位（数值范围正好 12bit）
                c_raw <= c_calc[DW-1:0];
            end else begin
                s_raw <= {DW{1'b0}};
                c_raw <= {DW{1'b0}};
            end

            // ---- OTR sticky：清除优先 ----
            if (clr_otr | en_fall) begin
                otr <= 1'b0;
            end else if (otr_now) begin
                otr <= 1'b1;
            end

            // ---- 连续采样：非复位期间恒为 1 ----
            adc_valid <= 1'b1;
        end
    end

endmodule
