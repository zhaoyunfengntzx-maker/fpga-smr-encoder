//=============================================================================
// 模块名 : amp_monitor
// 文件   : rtl/amp_monitor.v
// 功能   : 幅值监视 —— 用平方和比较代替开方（省一个 sqrt/DSP，也避免定点开方误差）
//          amp_sq = s_n^2 + c_n^2      （Q2.30，无符号）
//          amp_low  = amp_sq < amp_low_sq     （信号太弱，例如磁环脱落/气隙过大）
//          amp_high = amp_sq > amp_high_sq    （信号太强，例如偏置过大/前端饱和）
//          amp_ok   = low <= amp_sq <= high
//          门限由上位机预先平方好写入 amp_low_sq / amp_high_sq，
//          所以本模块只需要乘法 + 比较，不需要开方。
//
// 【与 专用细分 ASIC 的对应关系】
//   专用细分 ASIC 的等效门限是 STAT_VAL.scamp：sqrt(sin^2+cos^2) 超出
//   SC_AMP_LOW … SC_AMP_HIGH 时置位；引脚配置模式下这两个门限固定为
//   **校准值的 60% / 120%**（SC_AMP_TARG 推荐 150，LOW 90，HIGH 180）。
//   本模块把 60% / 120% 折算成平方门限：
//       amp_low_sq  = (0.60 * A_ref)^2
//       amp_high_sq = (1.20 * A_ref)^2
//   例：A_ref = 30000 -> low_sq = 324000000，high_sq = 1296000000。
//
// Latency : 2   （第 1 拍：DSP48 内两个 16x16 乘法 + 加法；第 2 拍：移位/饱和 + 比较输出寄存）
// 资源估计: 1 个 DSP48E1（两路乘法可打包进同一片 DSP 的预加器/P 级）
//           + 约 40 LUT + 约 100 FF
// 关键假设:
//   1. 本模块按 DW = 16（Q1.15 输入 => Q2.30 输出）设计。
//      s_n/c_n 最大值 32768 时 s^2 最大 2^30，两者之和最大 2^31，
//      所以内部累加器取 2*DW+1 = 33 位无符号：
//      **绝不能**直接用 32 位 signed 相加，s=c=-32768 时 2^30+2^30 = 2^31
//      会溢出成 -2^31（这正是本模块最需要验证的边界）。
//   2. amp_sq 饱和到 32 位无符号最大值 0xFFFFFFFF，绝不回绕。
//      （DW=16 时数学上最大 2^31，饱和路径不可达，属防御性保护。）
//   3. amp_low_sq > amp_high_sq（门限写反）时：amp_ok 恒为 0，
//      amp_low 优先（只要低于下限就报"弱"）。
//   4. amp_sq/amp_ok/amp_low/amp_high 每拍都随乘积寄存器更新；
//      out_valid 标记该拍结果是否对应一个有效输入样本（Latency = 2）。
//   5. 无跨时钟域信号。
//=============================================================================
`timescale 1ns / 1ps

module amp_monitor #(
    parameter integer DW = 16
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire signed [DW-1:0] s_n,          // 正弦分量（Q1.15）
    input  wire signed [DW-1:0] c_n,          // 余弦分量（Q1.15）
    input  wire                 in_valid,
    input  wire        [31:0]   amp_low_sq,   // 下限的平方（上位机算好）
    input  wire        [31:0]   amp_high_sq,  // 上限的平方
    output reg         [31:0]   amp_sq,       // = s^2 + c^2（Q2.30，无符号）
    output reg                  amp_ok,       // low <= amp_sq <= high
    output reg                  amp_low,      // amp_sq < amp_low_sq
    output reg                  amp_high,     // amp_sq > amp_high_sq
    output reg                  out_valid
);

    // ---- 派生常量 ----
    localparam integer DWSQ = 2 * DW;              // 32：平方结果位宽
    localparam integer DWAC = 2 * DW + 1;          // 33：平方和累加位宽（无符号）
    localparam [DWAC-1:0] SAT32_MAX = {1'b0, {DWSQ{1'b1}}};   // 2^32-1（DW=16 时正好 33 位）
    localparam [31:0]     AMP_SAT   = 32'hFFFFFFFF;           // 32 位无符号饱和值

    //=========================================================================
    // 第 1 级：平方 + 求和
    //=========================================================================
    wire signed [DWSQ-1:0] s_sq = $signed(s_n) * $signed(s_n);   // 0 … 2^30（非负）
    wire signed [DWSQ-1:0] c_sq = $signed(c_n) * $signed(c_n);

    // 平方值非负，最高位一定是 0，所以零扩展 1 位后可以安全地按无符号相加
    wire [DWAC-1:0] s_sq_u = {1'b0, s_sq};
    wire [DWAC-1:0] c_sq_u = {1'b0, c_sq};
    wire [DWAC-1:0] sq_sum = s_sq_u + c_sq_u;                    // 0 … 2^31

    reg [DWAC-1:0] sq_r;
    reg            v1_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            sq_r <= {DWAC{1'b0}};
            v1_r <= 1'b0;
        end else begin
            sq_r <= sq_sum;
            v1_r <= in_valid;
        end
    end

    //=========================================================================
    // 第 2 级：32 位无符号饱和 + 门限比较 + 输出寄存
    //=========================================================================
    wire [31:0] amp32 = (sq_r > SAT32_MAX) ? AMP_SAT : sq_r[31:0];

    // 门限写反（amp_low_sq > amp_high_sq）时：low 与 high 的原始条件会同时成立，
    // 这里强制 low 优先（high 被 w_low 屏蔽），保证 amp_ok/amp_low/amp_high 三态
    // 严格互斥，与头注释假设 3 一致。
    wire w_low  = (amp32 < amp_low_sq);
    wire w_high = (amp32 > amp_high_sq) & (~w_low);
    wire w_ok   = (~w_low) & (~w_high);

    always @(posedge clk) begin
        if (!rst_n) begin
            amp_sq    <= 32'd0;
            amp_ok    <= 1'b0;
            amp_low   <= 1'b0;
            amp_high  <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            amp_sq    <= amp32;
            amp_low   <= w_low;
            amp_high  <= w_high;
            amp_ok    <= w_ok;
            out_valid <= v1_r;
        end
    end

endmodule
