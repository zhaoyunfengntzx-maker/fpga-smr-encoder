//=============================================================================
// bias_track.v —— 偏置慢跟踪（S4，v9.1 改为"分块积分"，默认关闭）
//-----------------------------------------------------------------------------
// 为什么需要
//   一键标定只能测到"标定那一刻"的偏置。传感器与放大链的偏置会随温度、供电、
//   探头位置缓慢漂移（典型几百 LSB）。偏置在角度上不是常数误差：θ 由
//   atan2(s,c) 算出，偏置把圆搬离原点，造成的角度误差是 **2θ 的正弦**，
//   单点补偿必然"按下葫芦浮起瓢"。
//
// ★ v9.1 重写的原因（第一版是 EMA 反馈，实测把环路带崩了）
//   第一版：bias ← EMA(s_cor)，而 s_cor = s − (cfg_ofs + bias)
//           ⇒ 稳态方程 bias = (m − cfg_ofs) − bias ⇒ bias = (m − cfg_ofs)/2，
//           只能补一半；而且它是个嵌在校正通路上的持续反馈环，与 PI 环路耦合，
//           tb_enc_top 里表现为角度抖动（max_dev 1763 LSB16）、UVW 扇区丢跳变
//           （24→22）、A 相边沿 2048→4611。教训：估计器不要在校正回路上闭环。
//
//   现版本：**分块积分**。在一个窗口（2^LOG2N 个样本）内累加，窗口结束时
//   bias += 平均残差，然后窗口重新开始。窗口内 bias 恒定 ⇒ 与环路无连续耦合；
//   稳态要求"残差均值为 0"，一个窗口就能把残差补干净（理论上一块收敛）。
//     · LOG2N=15（32768 样本 = 2.62 ms @12.5 MHz）
//     · 转速很低时窗口不足一个电周期，均值会带半周期残差 —— 已知边界，
//       低速段仍靠一键标定（12 rpm 时一个电周期 = 24 ms > 窗口）。
//   窗口样本数 N、累加位宽 32 bit：最坏 32768 × 32768 = 2^30，不溢出。
//
// 默认关闭：`enc_top` 用 cfg_bias_en（0x0122 bit1，复位值 0）控制，主机显式
//   置 1 才启用。理由：它改的是校正通路的偏置，属于"改变既有行为"的功能，
//   第一次上板先保持与 v64 完全一致的默认行为，验证过再打开。
//
// 端口语义：en=1 且 in_valid 时累加；en=0 时清空当前窗口（避免半窗口数据）。
//   restart（一键标定的写回脉冲）清 bias 与窗口。
// 资源：2 个 32 位累加器 + 2 个 16 位加法 + 2 个比较器，约 150 LUT / 100 FF，无 DSP。
// 复位：同步、低有效。无 initial / #delay / inout / SystemVerilog 语法。
//=============================================================================
module bias_track #(
    parameter integer LOG2N = 15            // 窗口 = 2^LOG2N 个样本
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               in_valid,
    input  wire signed [15:0] s_in,         // 校正后的 sin（残差）
    input  wire signed [15:0] c_in,         // 校正后的 cos
    input  wire               en,
    input  wire               restart,
    output reg  signed [15:0] bias_s,
    output reg  signed [15:0] bias_c,
    output reg                bias_valid,   // 至少完成一个窗口
    output reg                bias_big      // 偏置超限（粘滞，restart 清）
);

    localparam integer        N        = (1 << LOG2N);
    localparam signed [15:0]  BIAS_MAX =  16'sd8191;   // ±25% 满量程
    localparam signed [15:0]  BIAS_MIN = -16'sd8192;

    reg signed [31:0]    sum_s, sum_c;
    reg        [LOG2N:0] cnt;
    reg signed [15:0]    bias_s_r, bias_c_r;
    reg                  valid_r, big_r;

    // 含当前样本的窗口均值
    wire signed [31:0] sum_s_nxt = sum_s + {{16{s_in[15]}}, s_in};
    wire signed [31:0] sum_c_nxt = sum_c + {{16{c_in[15]}}, c_in};
    wire signed [15:0] mean_s    = sum_s_nxt >>> LOG2N;
    wire signed [15:0] mean_c    = sum_c_nxt >>> LOG2N;

    wire signed [16:0] bias_s_sum = {bias_s_r[15], bias_s_r} + {mean_s[15], mean_s};
    wire signed [16:0] bias_c_sum = {bias_c_r[15], bias_c_r} + {mean_c[15], mean_c};

    wire signed [15:0] bias_s_nxt = (bias_s_sum > 17'sd8191)  ? BIAS_MAX :
                                    (bias_s_sum < -17'sd8192) ? BIAS_MIN : bias_s_sum[15:0];
    wire signed [15:0] bias_c_nxt = (bias_c_sum > 17'sd8191)  ? BIAS_MAX :
                                    (bias_c_sum < -17'sd8192) ? BIAS_MIN : bias_c_sum[15:0];

    wire sat_s = (bias_s_sum > 17'sd8191) || (bias_s_sum < -17'sd8192);
    wire sat_c = (bias_c_sum > 17'sd8191) || (bias_c_sum < -17'sd8192);

    always @(posedge clk) begin
        if (!rst_n) begin
            sum_s <= 32'sd0; sum_c <= 32'sd0;
            cnt   <= {(LOG2N+1){1'b0}};
            bias_s_r <= 16'sd0; bias_c_r <= 16'sd0;
            valid_r  <= 1'b0;   big_r    <= 1'b0;
            bias_s   <= 16'sd0; bias_c   <= 16'sd0;
            bias_valid <= 1'b0; bias_big <= 1'b0;
        end else if (restart) begin
            sum_s <= 32'sd0; sum_c <= 32'sd0;
            cnt   <= {(LOG2N+1){1'b0}};
            bias_s_r <= 16'sd0; bias_c_r <= 16'sd0;
            valid_r  <= 1'b0;   big_r    <= 1'b0;
            bias_s   <= 16'sd0; bias_c   <= 16'sd0;
            bias_valid <= 1'b0; bias_big <= 1'b0;
        end else if (!en) begin
            // 关闭时清窗口，并把已学的偏置继续输出（valid 保持）
            sum_s <= 32'sd0; sum_c <= 32'sd0;
            cnt   <= {(LOG2N+1){1'b0}};
            bias_s   <= valid_r ? bias_s_r : 16'sd0;
            bias_c   <= valid_r ? bias_c_r : 16'sd0;
            bias_valid <= valid_r;
            bias_big   <= big_r;
        end else if (in_valid) begin
            if (cnt == N - 1) begin
                // 窗口结束：bias += 均值，窗口清零
                bias_s_r <= bias_s_nxt;
                bias_c_r <= bias_c_nxt;
                valid_r  <= 1'b1;
                big_r    <= big_r | sat_s | sat_c;
                sum_s    <= 32'sd0;
                sum_c    <= 32'sd0;
                cnt      <= {(LOG2N+1){1'b0}};
                bias_s   <= bias_s_nxt;
                bias_c   <= bias_c_nxt;
                bias_valid <= 1'b1;
                bias_big   <= big_r | sat_s | sat_c;
            end else begin
                sum_s <= sum_s_nxt;
                sum_c <= sum_c_nxt;
                cnt   <= cnt + 1'b1;
            end
        end
    end

endmodule
