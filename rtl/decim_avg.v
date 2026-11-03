//=============================================================================
// 模块名 : decim_avg
// 文件   : rtl/decim_avg.v
// 功能   : 过采样 + 滑动平均抽取（一级 CIC / boxcar 滤波器 + 抽取器）
//          累加 2^LOG2DEC 个输入样本，算术右移 LOG2DEC 位输出，
//          每 2^LOG2DEC 个输入 valid 输出 1 拍 dout_valid。
//
// Latency : 2   （第 1 拍：累加并锁存整组和；第 2 拍：算术右移 + 饱和 + 输出寄存）
//              注：这里的"2 拍"是从**本组最后一个 din_valid** 算到 dout_valid。
// 资源估计: 1 个 DW+LOG2DEC 位加法器 + 1 个 DW+LOG2DEC 位寄存器组
//           （DW=13, LOG2DEC=2 时约 15 FF + 15 LUT，0 DSP）
// 关键假设:
//   1. 输入 din 是 signed；所有中间运算都用 $signed() 包裹，避免符号扩展出错。
//   2. din_valid 不要求连续。累加器只在 din_valid=1 时推进，
//      cnt 记录"本组已收样本数"，收满 2^LOG2DEC 个就输出一次。
//   3. 累加器位宽 = DW + LOG2DEC（契约要求）。数学上 2^LOG2DEC 个 DW 位有符号数
//      之和最大为 2^(DW-1) * 2^LOG2DEC = 2^(DW+LOG2DEC-1)，正好需要
//      DW+LOG2DEC 位有符号表示，所以**不会**溢出。
//      条文要求的饱和处理在这里是纯防御性保护（正常数据路径不可达），
//      实现为：结果超出 DW 位有符号范围时钳位到
//      {1'b0,{DW-1{1'b1}}}（最大）/ {1'b1,{DW-1{1'b0}}}（最小），绝不回绕。
//   4. 【CIC/boxcar 幅频结论】一级 boxcar（长度 N=2^LOG2DEC）的幅频响应为
//           |H(f)| = |sin(pi*f*N/fs) / (N*sin(pi*f/fs))|
//      在 f_in = 1 kHz、抽取率 N = 4、输入采样率 fs = 50 MHz 时：
//           (pi*f/fs) = 6.2832e-5
//           |H| ~= 1 - ((N^2-1)/6)*(pi*f/fs)^2 = 1 - 2.5*3.948e-9 = 1 - 9.87e-9
//           衰减 = 20*log10(|H|) ~= 8.6e-8 dB  **远小于 0.01 dB**
//      即：1 kHz 的 sin/cos 信号经过 4 倍抽取平均后幅度衰减可忽略
//      （< 0.01 dB 的要求有约 1e5 倍余量）。抽取对白噪声还有
//      (1/2)*LOG2DEC 比特的等效位数增益（LOG2DEC=2 -> 1 bit）。
//   5. 无跨时钟域信号。
//=============================================================================
`timescale 1ns / 1ps

module decim_avg #(
    parameter integer DW      = 13,      // 输入位宽（signed，= ADC位宽+1）
    parameter integer LOG2DEC = 2        // 抽取率 = 2^LOG2DEC（1,2,4,8,16）
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire signed [DW-1:0] din,
    input  wire                 din_valid,
    output reg  signed [DW-1:0] dout,
    output reg                  dout_valid
);

    // ---- 派生常量（全部参数化，无魔法数字）----
    localparam integer NDEC = 1 << LOG2DEC;                        // 抽取率
    localparam integer AW   = DW + LOG2DEC;                        // 累加器位宽（signed）
    localparam integer CW   = (LOG2DEC < 1) ? 1 : LOG2DEC;         // 样本计数器位宽
    localparam [CW-1:0] CNT_LAST = NDEC - 1;                       // 本组最后一个样本的计数值

    // ---- 输出饱和门限（DW 位有符号极值）----
    localparam signed [DW-1:0] OUT_MAX = {1'b0, {(DW-1){1'b1}}};   //  2^(DW-1)-1
    localparam signed [DW-1:0] OUT_MIN = {1'b1, {(DW-1){1'b0}}};   // -2^(DW-1)

    //=========================================================================
    // 第 1 级：累加 + 整组和锁存
    //=========================================================================
    reg signed [AW-1:0] acc;        // 组内累加器
    reg signed [AW-1:0] sum_r;      // 整组和（锁存给第 2 级）
    reg [CW-1:0]        cnt;        // 组内已收样本数
    reg                 sum_valid;  // 整组和有效（1 拍）

    always @(posedge clk) begin
        if (!rst_n) begin
            acc       <= {AW{1'b0}};
            sum_r     <= {AW{1'b0}};
            cnt       <= {CW{1'b0}};
            sum_valid <= 1'b0;
        end else begin
            sum_valid <= 1'b0;                       // 默认只拉高 1 拍
            if (din_valid) begin
                if (cnt == CNT_LAST) begin
                    // 收到本组最后一个样本：连同它一起锁存整组和
                    sum_r     <= $signed(acc) + $signed(din);
                    sum_valid <= 1'b1;
                    acc       <= {AW{1'b0}};
                    cnt       <= {CW{1'b0}};
                end else begin
                    acc <= $signed(acc) + $signed(din);
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

    //=========================================================================
    // 第 2 级：算术右移 + 饱和 + 输出寄存
    //   sum_r 是 signed，所以 >>> 是算术移位（向 -inf 取整），与模型一致。
    //=========================================================================
    wire signed [AW-1:0] shifted = $signed(sum_r) >>> LOG2DEC;

    always @(posedge clk) begin
        if (!rst_n) begin
            dout       <= {DW{1'b0}};
            dout_valid <= 1'b0;
        end else begin
            dout_valid <= sum_valid;
            if (sum_valid) begin
                if (shifted > $signed(OUT_MAX)) begin
                    dout <= OUT_MAX;                 // 正向饱和
                end else if (shifted < $signed(OUT_MIN)) begin
                    dout <= OUT_MIN;                 // 负向饱和
                end else begin
                    dout <= $signed(shifted[DW-1:0]); // 正常：截掉冗余符号位
                end
            end
        end
    end

endmodule
