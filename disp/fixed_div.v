// =============================================================================
//  disp/fixed_div.v  --  共享顺序除法器（屏幕本机 UI 的显示格式化用）
//
//  为什么需要它（2026-10-15 定案，见 docs/13_display_ui_requirements.md §7）：
//
//    屏上要显示的两个量都需要「除以极对数 pairs」：
//        转速   rpm_x10 = (600 x f_q10) / (1024 x pairs)     -- 0.1 rpm 定点
//        累计转数 revs  = (pos_acc >> 16) / pairs
//    另外 输入频率两位小数 直接是 (25 x f_q10) >> 8，不需要除法（2 的幂）。
//
//    否定掉的方案：**倒数 ROM + DSP 乘法**（K[pairs] = round(153600/pairs)）。
//    理由是它同时踩两个坑：
//      (a) pairs 不整除 153600 时（7/9/11/13/...) 引入约 3.3e-6 的相对误差，
//          在 pairs=1、转速上万时就是 0.03 rpm 的显示抖动；
//      (b) f_q10 有 32 bit，乘 18 bit 倒数要拆成两个 16 bit 半再合并 —— 二乘法。
//    而**除法只在消隐期做**：一帧有 239,040 拍空闲（1344x635 一帧 = 853,440 拍，
//    有效像素只有 614,400 个），40 拍一次的序贯除法器占用不到万分之二。
//    所以这里选「用时间换精度和面积」：一个除法器 + 一个很短的 FSM，
//    商是**精确**的，LUT 占用接近 0，DSP 占用 0。
//
//  算法：经典恢复余数法（restoring division），每拍产生 1 位商。
//        共 W 拍出结果。除数 = 0 时商自然饱和到全 1（r_sh >= 0 恒真），
//        这正是我们想要的「除零不锁死」行为。
//
//  ★ 调用纪律：同一时刻只能有一个调用者在使用（本模块不自带仲裁）。
//    目前由显示引擎在 VBlank 内的格式化阶段串行发起。
// =============================================================================
`timescale 1ns / 1ps

module fixed_div #(
    parameter integer W  = 40,   // 被除数 / 商 / 余数的位宽
    parameter integer DW = 16    // 除数位宽（必须 <= W）
)(
    input  wire           clk,
    input  wire           rst_n,
    input  wire           start,        // 拉高一拍即开始（busy 期间忽略）
    input  wire [W-1:0]   dividend,
    input  wire [DW-1:0]  divisor,
    output reg  [W-1:0]   quotient,
    output reg  [W-1:0]   remainder,
    output reg            busy,
    output reg            done          // 完成脉冲，一拍的 valid
);

    localparam [7:0] W8 = W;            // 迭代次数（W <= 255）

    reg [W-1:0] q, r;
    reg [7:0]   cnt;
    reg         run;

    wire [W-1:0] divisor_x = {{(W-DW){1'b0}}, divisor};
    wire [W-1:0] r_sh      = {r[W-2:0], q[W-1]};       // 余数左移，从被除数取下一位
    wire [W-1:0] q_sh      = {q[W-2:0], 1'b0};         // 商左移，空出最低位
    wire         ge        = (r_sh >= divisor_x);
    wire [W-1:0] r_nx      = ge ? (r_sh - divisor_x) : r_sh;
    wire [W-1:0] q_nx      = ge ? (q_sh | {{(W-1){1'b0}}, 1'b1}) : q_sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q         <= {W{1'b0}};
            r         <= {W{1'b0}};
            cnt       <= 8'd0;
            run       <= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
            quotient  <= {W{1'b0}};
            remainder <= {W{1'b0}};
        end else begin
            done <= 1'b0;
            if (start && !run) begin
                // 启动：把被除数整份搬进 q，余数清零，跑 W 拍
                q    <= dividend;
                r    <= {W{1'b0}};
                cnt  <= W8;
                run  <= 1'b1;
                busy <= 1'b1;
            end else if (run) begin
                q   <= q_nx;
                r   <= r_nx;
                cnt <= cnt - 8'd1;
                if (cnt == 8'd1) begin
                    // 最后一拍：结果落盘，释放 busy
                    run       <= 1'b0;
                    busy      <= 1'b0;
                    done      <= 1'b1;
                    quotient  <= q_nx;
                    remainder <= r_nx;
                end
            end
        end
    end

endmodule
