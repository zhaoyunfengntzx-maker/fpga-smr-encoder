//=============================================================================
// trace_cap.v — P4 逻辑时序页的**触发式时域捕获**（v60 / T7）
//
// 为什么换掉原来的 logic_scope（按电角度 128 箱重建）：
//   上板现象是 A/B 两条方波"一直在流动"。根因是那个做法按**电角度**分箱，
//   每个箱里存"最后一次落在该角度的采样"。只有当 A/B 与电角度严格锁相时，
//   重建出来的波形才稳定；用信号发生器单独喂 A/B（或 A/B 与 SIN/COS 不同源）
//   时两者毫不相干，于是每帧每箱采到的相位都不同 ⇒ 波形逐帧乱跳。
//
// 现在的做法就是示波器：**固定采样率 + 触发点对齐 + 双缓冲整帧换图**
//   ① 采样：每 PRESCALE 个 clk 采一次 io6（默认 100 ⇒ 50 MHz / 100 = 2 µs/点）；
//   ② 触发：trig_sel 选源（0=Z 上升沿、1=A 上升沿、2=角度过零、3=自由运行），
//      触发后线性填满 DEPTH 点；
//   ③ 交换：填满后把捕获缓冲整块拷进显示缓冲，再重新武装 —— 屏上永远是
//      **一整帧完整捕获**，不会出现"半新半旧"的撕裂；
//   ④ 显示：x 像素 → 采样序号 = dx >> 1（两点 2 px），q/qp 给相邻两像素的
//      电平（qp 用来画 1 px 的竖直边沿，与旧渲染器的契约一致）。
//
// 资源：两块 512x6 = 6,144 bit。**故意用分布式 RAM（LUTRAM）**：本设计的
//   BRAM 已到 97%，而 6 kbit 走 LUTRAM 约 100 个 LUT，占比可忽略。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module trace_cap #(
    parameter integer DEPTH = 512          // 采样深度（2 的幂，<= 1024）
) (
    input  wire        clk,
    input  wire        rst_n,

    // 采样源
    input  wire [5:0]  io6,                // {w,v,u,z,b,a}
    input  wire [15:0] angle,              // 电角度 0..65535，用于"过零"触发
    input  wire [1:0]  trig_sel,           // 0=Z↑ 1=A↑ 2=角度过零 3=自由
    input  wire [16:0] prescale,           // 采样分频（>=1）

    // 读口（像素通路：给 dx，拿这一点与上一点的电平）
    input  wire [9:0]  dx,
    output wire [5:0]  q,
    output wire [5:0]  qp,

    // 观测量（调试/诊断用）
    output reg         armed,
    output reg  [1:0]  frames             // 每换一帧 +1（低两位）
);

    localparam integer AW = $clog2(DEPTH);
    // ★ 注意：不能用 DEPTH[AW-1:0]-1 当终点 —— DEPTH=512 的低 AW 位全是 0，
    //   减 1 得到 -1（32 位全 1），永远等不到，状态机就会卡在交换态。
    localparam integer LASTI = DEPTH - 1;

    //   ★ v60 首轮实现把这两个数组推成了寄存器（FF 8.6k → 17.5k、LUT 到 98.8%）。
    //     9,216 bit 就该是 **分布式 RAM**，不能占寄存器：两块都显式注解。
    //     写口各自独立成块（同一个 always 块里“读 A 写 B”会让推断器放弃）。
    (* ram_style = "distributed" *) reg [5:0] cap_mem [0:DEPTH-1];
    (* ram_style = "distributed" *) reg [5:0] dsp_mem [0:DEPTH-1];

    // ---- 采样节拍 ----
    reg [16:0] psc;
    wire       tick = (psc == 17'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) psc <= 17'd0;
        else        psc <= tick ? (prescale - 17'd1) : (psc - 17'd1);
    end

    // ---- 触发沿检测 ----
    reg z_d, a_d, ang_msb_d;
    wire z_now = io6[3];                   // io6 = {w,v,u,z,b,a}
    wire a_now = io6[0];
    wire ang_now = angle[15];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z_d <= 1'b0; a_d <= 1'b0; ang_msb_d <= 1'b0;
        end else begin
            z_d <= z_now; a_d <= a_now; ang_msb_d <= ang_now;
        end
    end
    wire trig_ev = (trig_sel == 2'd0) ? (z_now & ~z_d) :
                   (trig_sel == 2'd1) ? (a_now & ~a_d) :
                   (trig_sel == 2'd2) ? (ang_msb_d & ~ang_now) :  // 65535 -> 0
                                       1'b1;

    // ---- 捕获状态机：0 等触发 / 1 采样 / 2 拷进显示缓冲 ----
    reg [1:0]  st;
    reg [AW:0] widx;
    reg [AW-1:0] cidx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= 2'd0;
            widx  <= {(AW+1){1'b0}};
            cidx  <= {AW{1'b0}};
            armed <= 1'b1;
            frames <= 2'd0;   // 不清零会停在 X（X+1=X），帧计数永远不动
        end else begin
            case (st)
            2'd0: begin
                armed <= 1'b1;
                if (trig_ev) begin
                    st   <= 2'd1;
                    widx <= {(AW+1){1'b0}};
                    armed <= 1'b0;
                end
            end
            2'd1: begin
                // 触发点本身也算第 0 个点，所以这里用"先采后停"的写法
                //   ★ v60：写动作已移到下面独立的 always 块（RAM 推断）
                if (tick) begin
                    if (widx == DEPTH[AW:0] - 1) begin
                        st   <= 2'd2;
                        cidx <= {AW{1'b0}};
                    end else begin
                        widx <= widx + 1'b1;
                    end
                end
            end
            2'd2: begin
                //   ★ v60：拷贝已移到独立 always 块
                if (cidx == LASTI[AW-1:0]) begin
                    st     <= 2'd0;
                    frames <= frames + 2'd1;
                end else begin
                    cidx <= cidx + 1'b1;
                end
            end
            default: st <= 2'd0;
            endcase
        end
    end

    // ---- 存储器写口（与状态机分开，保证分布式 RAM 推断）----
    wire        cap_we = (st == 2'd1) && tick;
    always @(posedge clk) begin
        if (cap_we) cap_mem[widx[AW-1:0]] <= io6;
    end
    always @(posedge clk) begin
        if (st == 2'd2) dsp_mem[cidx] <= cap_mem[cidx];
    end

    // ---- 读口：两点 2 px ----
    //   dx = 0..855（轨迹区宽），采样序号 = dx >> 1 ⇒ 用 428 点覆盖 856 px。
    wire [AW-1:0] ridx = dx[9:1];
    assign q  = dsp_mem[ridx];
    assign qp = dsp_mem[(ridx == {AW{1'b0}}) ? {AW{1'b0}} : (ridx - 1'b1)];

endmodule

`default_nettype wire
