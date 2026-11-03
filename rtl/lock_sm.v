//=============================================================================
// lock_sm.v —— 锁定状态机 + 连续故障计数（S3）
//-----------------------------------------------------------------------------
// 为什么需要
//   v8 以前故障只有一个"粘滞位"，主机看到的是"曾经坏过"，无法区分：
//     · 刚上电还没建立跟踪（正常，不该报警）
//     · 正在跟踪但信号瞬间抖动（毛刺，需容忍）
//     · 已经丢信号（必须报警 / 停伺服）
//   把这三件事混成一个位，上位机和屏幕就只能靠猜。本模块把它们分开，
//   并给出"连续坏了多少拍"，让故障是可观测、可验收的。
//
// 状态机（全部在 in_valid 拍推进，12.5 MHz）
//
//        ┌────────┐  good 连续 GOOD_N 拍   ┌─────────┐
//        │  INIT  │ ─────────────────────> │  TRACK  │
//        └────────┘                        └─────────┘
//             ^                                 │ bad 连续 BAD_N 拍
//             │                                 v
//             │        good 连续 RECOV_N 拍 ┌────────┐
//             └──────────────────────────── │  LOST  │
//                                           └────────┘
//
//   默认 GOOD_N = RECOV_N = 12500（1 ms），BAD_N = 2500（0.2 ms）：
//     · 1 ms 捕获：上电后到锁定 ≈ 1 ms，够快；
//     · 0.2 ms 丢锁：1200 rpm 时一个正弦周期 24 µs，0.2 ms ≈ 8 个周期，
//       单周期掉幅、单点毛刺都不会误报；
//     · 1 ms 恢复：避免信号在门限附近抖动时反复进出 LOST。
//
// bad 条件 = 幅值越限 | lag_fatal（>45° 失锁）| 校正饱和
// good 条件 = 幅值正常 且 未失锁 且 未饱和
//
// 输出
//   state      : 0=INIT 1=TRACK 2=LOST
//   locked     : state==TRACK（组合，给遥测/屏幕用）
//   lost_evt   : 1 拍脉冲（进入 LOST）
//   acq_evt    : 1 拍脉冲（进入 TRACK，含上电首次捕获与故障恢复）
//   lost_cnt   : 累计进入 LOST 的次数（16 位，饱和）
//   bad_run    : TRACK 状态下"连续坏样本"数（16 位，饱和），good 拍清零；
//                它直接回答"这次故障是 1 个毛刺还是持续掉幅"
//
// 复位：同步、低有效。无 initial / #delay / inout / SystemVerilog 语法。
// 资源：约 60 LUT / 70 FF。
//=============================================================================
module lock_sm #(
    parameter integer GOOD_N  = 12500,   // 1 ms @12.5 MHz
    parameter integer BAD_N   = 2500,    // 0.2 ms
    parameter integer RECOV_N = 12500    // 1 ms
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        amp_ok,
    input  wire        amp_low,
    input  wire        amp_high,
    input  wire        lag_fatal,      // |err| > 45°（loop_filter.lag_limit 再确认）
    input  wire        cor_sat,        // sc_correct 饱和
    output reg  [1:0]  state,
    output reg         lost_evt,
    output reg         acq_evt,
    output reg  [15:0] lost_cnt,
    output reg  [15:0] bad_run
);

    localparam [1:0] S_INIT  = 2'd0;
    localparam [1:0] S_TRACK = 2'd1;
    localparam [1:0] S_LOST  = 2'd2;

    wire bad  = amp_low | amp_high | lag_fatal | cor_sat;
    wire good = amp_ok & ~lag_fatal & ~cor_sat;

    reg [15:0] good_cnt;
    reg [15:0] bad_cnt;

    wire locked = (state == S_TRACK);

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_INIT;
            lost_evt  <= 1'b0;
            acq_evt   <= 1'b0;
            lost_cnt  <= 16'd0;
            bad_run   <= 16'd0;
            good_cnt  <= 16'd0;
            bad_cnt   <= 16'd0;
        end else begin
            lost_evt <= 1'b0;
            acq_evt  <= 1'b0;

            if (in_valid) begin
                case (state)
                //---------------------------------------------------------
                S_INIT: begin
                    bad_run <= 16'd0;
                    if (good) begin
                        if (good_cnt != GOOD_N) good_cnt <= good_cnt + 16'd1;
                        if (good_cnt >= GOOD_N - 1) begin
                            state    <= S_TRACK;
                            good_cnt <= 16'd0;
                            acq_evt  <= 1'b1;
                        end
                    end else begin
                        good_cnt <= 16'd0;
                    end
                end
                //---------------------------------------------------------
                S_TRACK: begin
                    if (bad) begin
                        if (bad_run != 16'hFFFF) bad_run <= bad_run + 16'd1;
                        if (bad_cnt != BAD_N) bad_cnt <= bad_cnt + 16'd1;
                        if (bad_cnt >= BAD_N - 1) begin
                            state    <= S_LOST;
                            bad_cnt  <= 16'd0;
                            good_cnt <= 16'd0;
                            lost_evt <= 1'b1;
                            lost_cnt <= lost_cnt + 16'd1;
                        end
                    end else begin
                        bad_cnt <= 16'd0;
                        bad_run <= 16'd0;
                    end
                end
                //---------------------------------------------------------
                S_LOST: begin
                    bad_run <= 16'd0;
                    if (good) begin
                        if (good_cnt != RECOV_N) good_cnt <= good_cnt + 16'd1;
                        if (good_cnt >= RECOV_N - 1) begin
                            state    <= S_TRACK;
                            good_cnt <= 16'd0;
                            acq_evt  <= 1'b1;
                        end
                    end else begin
                        good_cnt <= 16'd0;
                    end
                end
                //---------------------------------------------------------
                default: state <= S_INIT;
                endcase
            end
        end
    end

    // locked 是组合输出（state 的派生），单独给一个端口方便上层直接用
    // （Verilog-2001 不允许 output reg + assign，这里用 wire 别名的方式：
    //   在 enc_top 里直接比较 state 即可，不额外占端口）

endmodule
