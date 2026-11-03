//=============================================================================
// disp/xy_plot.v —— P3 李萨如 XY 页的描点器（v16）
//-----------------------------------------------------------------------------
//   把两路 16 bit 有符号样本（校正后 sin / cos）当成 (x, y) 的**坐标**，
//   一帧之内把 192 x 192 的点阵画满，供 disp/disp_engine.v 的像素通路一次查表。
//
//   ★ 与 disp/wave_trace.v 的关系：两者取同一对样本、同一个 frame_st，
//     但语义完全不同 —— wave_trace 把样本当"随时间的幅度"（x = 时间列），
//     xy_plot 把样本当"平面上的坐标"（x = 样本 1, y = 样本 2）。所以一个是
//     每列一个区间，一个是整面点阵，不能合并。
//
//   ★ 一帧两相：擦（清写面 65536 拍）→ 画（每 SAMPLE_DIV 拍打一个点）。
//     SAMPLE_DIV = 16 时一帧能打约 49000 个点，而输入信号一帧才走
//     ~26 个周期（1500 Hz / 58.6 Hz）⇒ 每个周期被打上 ~1900 个点，
//     曲线是"画出来的"而不是"连出来的"，因此像素通路不需要连线逻辑。
//
//   ★ 标度：±32768 映射成"以位图中心为原点 ±128"，再钳到 0..191。
//     也就是**满量程占 192 格里的 128 格**（67%），与 P2 的 64% 同一个口径：
//     留出余量后，超量程表现为**贴在方框边上**（可见、诚实），而不是被缩放
//     到看不出饱和。做成满量程映射要多一个组合乘法，属于把时序余量花在装饰上。
//
//   ★ 为什么 y 要取反：位图 by 向下增长，而数学坐标 y 向上为正。
//     `ry = 96 - (c_n >>> 8)` 这一处减法就是唯一的坐标系差异，
//     把它放在这里而不是放在像素通路里，是为了让屏上的 y 轴与用户直觉一致。
//=============================================================================
`default_nettype none

module xy_plot #(
    parameter [7:0] SAMPLE_DIV = 8'd16       // 每多少拍打一个点
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               frame_st,      // 帧首单拍（disp_engine 的 vf_start）
    input  wire signed [15:0] s_n,           // 校正后 sin -> 位图 x
    input  wire signed [15:0] c_n,           // 校正后 cos -> 位图 y（取反）

    output reg                we,
    output reg  [16:0]        waddr,
    output reg                wdata,
    output reg                wr_buf,        // 正在写（擦/画）的那一面
    output reg                disp_buf       // 正在显示的那一面（帧首取自上一轮的 wr_buf）
);

    // ---- 样本 -> 位图坐标（0 = 左/上，191 = 右/下，96 = 中心）----
    wire signed [15:0] rx = 16'sd96 + (s_n >>> 8);   // +-128，中心 96
    wire signed [15:0] ry = 16'sd96 - (c_n >>> 8);   // 取反见文件头

    wire [7:0] bx = (rx < 16'sd0)   ? 8'd0   :
                    (rx > 16'sd191) ? 8'd191 : rx[7:0];
    wire [7:0] by = (ry < 16'sd0)   ? 8'd0   :
                    (ry > 16'sd191) ? 8'd191 : ry[7:0];

    reg        clr_phase;
    reg [15:0] clr;
    reg [7:0]  div;
    reg        started;      // 复位后先等第一次帧首，见下面的 ★

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            we        <= 1'b0;
            waddr     <= 17'd0;
            wdata     <= 1'b0;
            wr_buf    <= 1'b0;
            disp_buf  <= 1'b0;
            clr_phase <= 1'b0;
            clr       <= 16'd0;
            div       <= 8'd0;
            started   <= 1'b0;
        end else begin
            we <= 1'b0;

            if (frame_st) begin
                // 换面：刚写满的那一面变成显示面，另一面拿来擦 + 画。
                // 注意此处读到的是**旧** wr_buf（非阻塞），所以新写面是 ~wr_buf。
                disp_buf  <= wr_buf;
                wr_buf    <= ~wr_buf;
                clr_phase <= 1'b1;
                clr       <= 16'd0;
                div       <= 8'd0;
                we        <= 1'b1;
                waddr     <= {~wr_buf, 16'd0};
                wdata     <= 1'b0;
                started   <= 1'b1;
            end else if (!started) begin
                //   ★ 复位之后、第一次 frame_st 之前：**一次都不写**。
                //     双缓冲的两个指针在复位时必然相同（wr_buf = disp_buf = 0），
                //     只有"换面"才能把它们分开；而换面只发生在 frame_st。
                //     若此时就开始画，写面就是显示面 —— 这边正在置位、那边正在扫描，
                //     屏幕上会看到半帧新点混着半帧旧点。等一拍帧首的代价是一帧（17 ms），
                //     换来的是"写面永远不等于显示面"这条不变量在最开始就成立。
                //     复位后显示面是全 0（xy_ram 的 initial 铺的就是 0），所以这一帧
                //     屏上是空点阵，不是错点阵。
            end else if (clr_phase) begin
                // 整面清零：65536 个地址一拍一个。清的是**写面**，显示面不动。
                if (clr == 16'd65535) begin
                    clr_phase <= 1'b0;
                    clr       <= 16'd0;
                end else begin
                    clr   <= clr + 16'd1;
                    we    <= 1'b1;
                    waddr <= {wr_buf, clr + 16'd1};
                    wdata <= 1'b0;
                end
            end else if (div == SAMPLE_DIV - 8'd1) begin
                div <= 8'd0;
                // 只置 1、不清 0：清零是整面做的（上面那一相），这里不读改写。
                we    <= 1'b1;
                waddr <= {wr_buf, by, bx};
                wdata <= 1'b1;
            end else begin
                div <= div + 8'd1;
            end
        end
    end

endmodule

`default_nettype wire
