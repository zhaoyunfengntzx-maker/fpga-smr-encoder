//=============================================================================
// disp/p2_auto.v —— P2 时基的 AUTO 选档 + 迟滞 + 停留（v87 任务 A2）
//
// 背景：v86 的时基只有三档手切（2.4 ms / 300 µs / 38 µs），用户要求默认
//   **AUTO**：按电气频率自动挑一档，让屏幕上大约有 2~4 个完整周期。
//   档位 → 窗宽（见 disp/wave_trace.v 与 p2_win_lab.v）：
//     gear0 = 944×128/50e6 = 2.417 ms
//     gear1 = 944× 16/50e6 = 302.1 µs
//     gear2 = 944×  2/50e6 =  37.8 µs
//   想让 2~4 个周期铺满 944 列，档位边界就落在"一个窗宽里有 1 个周期"处：
//     gear0 覆盖 1/2.417ms = 414 Hz  … 上界 gear1 的 1 周期 = 3.31 kHz
//     gear1 覆盖 3.31 kHz … 26.5 kHz
//     gear2 覆盖 26.5 kHz … 任意高
//   但用户给的边界是 "6.6 kHz / 53 kHz"，比"1 周期"高 2 倍 —— 也就是屏上
//   显示 **1~2 个周期**（他现场就是这么看的，按他的口径来）。这里照用户
//   给的数：< 6.6 kHz ⇒ gear0、6.6…53 kHz ⇒ gear1、≥ 53 kHz ⇒ gear2。
//
// 迟滞（约 15%）：同一档位在边界附近来回抖会让屏幕上的窗宽每秒变一次，
//   肉眼极刺眼。所以升档与降档用**不同**的门限：
//     gear0 → gear1：f ≥ 6.6 kHz       gear1 → gear0：f < 5.6 kHz
//     gear1 → gear2：f ≥ 53  kHz       gear2 → gear1：f < 45 kHz
//
// 停留（dwell，0.5 s）：频率计每 1/64 s 出一个 valid 脉冲，所以 0.5 s =
//   32 个脉冲。换档后计数清零，期间无论读到哪里都不换 —— 避免"加速过程中
//   一连换三档"的闪屏。
//
// 无效频率（没锁相/幅值不足）：保持当前档位。判据由调用方给出（f_ok），
//   本模块不自己判"锁定"——锁定状态在别处有唯一定义，重复判会分叉。
//
// ★ 为什么不在这里按"每档窗宽里的周期数"算：那样要除法，而频率本身就是
//   频率计给的低精度量；按频率分档只需常数比较（几个 LUT），且与用户在
//   现场看到的档位切换点一一对应，可解释性强。
//=============================================================================
`default_nettype none

module p2_auto (
    input  wire               clk,
    input  wire               rst_n,

    input  wire [1:0]         mode,     // 0 = AUTO，1/2/3 = 固定 gear0/1/2
    input  wire signed [31:0] f_q10,    // 电气频率，单位 1/1024 Hz（带符号：负 = 反转）
    input  wire               f_valid,  // 频率更新脉冲（1/64 s 一次）
    input  wire               f_ok,     // 频率可信（已锁定且幅值在位）

    output reg  [1:0]         gear      // 实际使用的档位 0/1/2
);

    // 门限（Hz），写成 1024 倍后直接和 f_q10 比，避免运行期乘法
    localparam signed [31:0] F_UP_1  = 32'sd6_758_400;   //  6.6 kHz
    localparam signed [31:0] F_DN_1  = 32'sd5_734_400;   //  5.6 kHz（-15%）
    localparam signed [31:0] F_UP_2  = 32'sd54_272_000;  // 53.0 kHz
    localparam signed [31:0] F_DN_2  = 32'sd46_080_000;  // 45.0 kHz（-15%）

    localparam [5:0] DWELL_MAX = 6'd32;                  // 32/64 s = 0.5 s

    // |f_q10|：反转时频率为负，档位只看大小
    wire [31:0] f_abs = f_q10[31] ? (~f_q10 + 32'd1) : f_q10;

    reg  [5:0]  dwell;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gear  <= 2'd1;
            dwell <= DWELL_MAX;          // 上电即允许第一次选档
        end else if (mode != 2'd0) begin
            // 固定档：立刻跟随，不受迟滞/停留约束
            gear  <= mode - 2'd1;        // 1->0, 2->1, 3->2
            dwell <= DWELL_MAX;
        end else begin
            // ★ dwell 必须按 **f_valid 脉冲**计数（1/64 s 一个），不是按 clk：
            //   按 clk 数的话 32 拍只有 0.64 µs，"停留 0.5 s"就形同虚设。
            if (f_valid) begin
                if (dwell != DWELL_MAX) dwell <= dwell + 6'd1;
                if (f_ok && (dwell == DWELL_MAX)) begin
                    case (gear)
                        2'd0: if (f_abs >= F_UP_1) begin
                                  gear  <= 2'd1;
                                  dwell <= 6'd0;
                              end
                        2'd1: if (f_abs < F_DN_1) begin
                                  gear  <= 2'd0;
                                  dwell <= 6'd0;
                              end else if (f_abs >= F_UP_2) begin
                                  gear  <= 2'd2;
                                  dwell <= 6'd0;
                              end
                        default: if (f_abs < F_DN_2) begin
                                  gear  <= 2'd1;
                                  dwell <= 6'd0;
                              end
                    endcase
                end
            end
        end
    end

endmodule

`default_nettype wire
