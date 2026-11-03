//=============================================================================
// disp/wave_trace.v —— P2 输入波形页的轨迹采样器（v15）
//-----------------------------------------------------------------------------
//   把连续的两路 16 bit 有符号样本（校正后 sin / cos）变成一张**每列一条
//   竖直线段**的表，供 disp/disp_engine.v 的像素通路做一次区间比较。
//
//   ★ 为什么不存"每个采样点的行号"而存"线段的上下沿"：
//     spec 7.2 明令**禁止在像素通路里实时栅格化折线**。存单点行号的话，
//     两个相邻列的点之间要靠像素通路连线（斜率计算 + 循环），组合深度不可控；
//     存 [lo, hi] 之后，像素通路只剩 `lo <= ry <= hi` 两个比较器 —— 几何
//     全部在消隐期/帧内预栅格化完成。存储代价是每列 2 字节而不是 1 字节
//     （2048 x 32 bit 仍然只要 2 块 RAMB36）。
//
//   ★ 双缓冲：写面 wr_buf 与显示面 disp_buf 在帧首互换。见 disp/wave_ram.v
//     的头注释（单缓冲会把同一帧的波形撕成两半）。
//
//   ★ 扫描与帧的同步：frame_st 一到就 wr_ptr 归零、换面。SWEEP_DIV=128 时
//     944 列只需 120,832 **个可见拍**，而一帧可见区是 600*1024 = 614,400 拍
//     （含消隐 853,440 拍）⇒ 每次扫描都能在帧内跑完并留出余量，不会"边扫边显示"。
//     余量也是**故意留的**：它保证换面发生在两次扫描之间，而不是扫描中途。
//
//   ★ v17：扫描必须门控在 de（可见像素）上。原来 div 每个 clk 都自增，消隐期
//     照样每 128 拍写一列，写进去的是 q_s_n/q_c_n 在消隐期冻结的同一个样本
//     （disp_engine 的样本寄存器只在 de 时更新）⇒ 屏上最左 ~367 列是平线。
//     上板照片（2026-10-15）上 x 80..447 那条直线就是这个。
//   ★ v77：上面那条 de 门控**已撤掉**，但配套条件变了 —— disp_engine 的
//     q_s_n/q_c_n 现在每拍都采（消隐期也是新样本），所以时基必须连续，
//     否则 38 µs 档每行末尾会留一个 3.7 µs 的空洞（屏上是被劈成两半的曲线）。
//
//   标度：16 bit 有符号样本 ±32768 映射成居中 ±128 行（`>>> 8`），再钳到
//     0..199。也就是说**满量程只占 200 行里的 128 行**（64%）。
//     为什么不做满量程映射：那需要乘一个 100/128 的系数，而这是每 128 拍
//     一次的组合乘法，属于"为了好看把时序余量花在装饰上"。样本超出 ±128
//     行时钳位，钳位是**可见且诚实**的（波形削顶），不会伪装成小信号。
//=============================================================================
`default_nettype none

module wave_trace #(
    parameter [10:0] SWEEP_LEN = 11'd944    // 一屏多少列（= 可画宽度）
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               frame_st,     // 帧首单拍（disp_engine 的 vf_start）
    input  wire               de,           // v77 起不再使用（时基连续推进，见头注释）
    input  wire signed [15:0] s_n,          // 校正后 sin（A 通道）
    input  wire signed [15:0] c_n,          // 校正后 cos（B 通道）
    // ★ v75（A）：时基三档。0 = 2.4 ms（每列 128 拍）、1 = 300 µs（16 拍）、
    //   2 = 38 µs（2 拍）。档位由 enc_top_disp 的触摸状态给出，因此这里的
    //   分频比是**运行期**信号，不再是编译期参数 —— 参数化的话每换一档都要
    //   重新综合，屏上就不可能"切换"了。窗宽 = 944 x 分频比 / 50 MHz：
    //   128 -> 2.416 ms、16 -> 302.1 µs、2 -> 37.8 µs，与 P2 底栏标签
    //   "窗口 2.4MS / 300US / 38US" 一一对应（标签由 disp/p2_win_lab.v 写）。
    input  wire [1:0]         gear,

    output reg                we,
    output reg  [10:0]        waddr,
    output reg  [31:0]        wdata,
    output reg  [10:0]        wr_ptr,
    output reg                wr_buf,       // 正在写的那一面
    output reg                disp_buf      // 正在显示的那一面（帧首取自上一轮的 wr_buf）
);

    // ---- 样本 -> 通道内相对行（0 = 顶端，199 = 底端，99 = 中线）----
    wire signed [15:0] ra = 16'sd99 - (s_n >>> 8);
    wire signed [15:0] rb = 16'sd99 - (c_n >>> 8);

    wire [7:0] ya = (ra < 16'sd0)   ? 8'd0   :
                    (ra > 16'sd199) ? 8'd199 : ra[7:0];
    wire [7:0] yb = (rb < 16'sd0)   ? 8'd0   :
                    (rb > 16'sd199) ? 8'd199 : rb[7:0];

    // ---- 与上一列连成线段：取两列行的 min/max ----
    reg [7:0] ya_p, yb_p;

    wire [7:0] a_lo = (ya < ya_p) ? ya    : ya_p;
    wire [7:0] a_hi = (ya < ya_p) ? ya_p  : ya;
    wire [7:0] b_lo = (yb < yb_p) ? yb    : yb_p;
    wire [7:0] b_hi = (yb < yb_p) ? yb_p  : yb;

    wire [31:0] word = {a_hi, a_lo, b_hi, b_lo};

    reg [7:0] div;
    // ★ v75（A）：一列占多少个可见拍。128 需要 8 bit，故 div 从 12 bit 收到 8 bit
    //   （原来是参数 SWEEP_DIV=12'd5 的部分比较，收敛到运行期档位后 8 bit 足够）。
    wire [7:0] sweep_div = (gear == 2'd0) ? 8'd128 :
                           (gear == 2'd1) ? 8'd16  : 8'd2;
    // v74：扫描等 sin 由负穿正再开始（原来 frame_st 一到就扫，起始相位随机 ⇒ 屏上横向乱晃）
    reg        s_neg_q;   // 上一拍 sin 是否为负
    reg        started;   // 本帧是否已触发

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div      <= 8'd0;
            we       <= 1'b0;
            waddr    <= 11'd0;
            wdata    <= 32'd0;
            wr_ptr   <= 11'd0;
            wr_buf   <= 1'b0;
            disp_buf <= 1'b0;
            ya_p     <= 8'd99;
            yb_p     <= 8'd99;
        end else begin
            we <= 1'b0;

            s_neg_q <= (s_n < 16'sd0);
            if (frame_st) begin
                // 换面 + 归零。上一轮写满的那一面变成显示面。
                disp_buf <= wr_buf;
                wr_buf   <= ~wr_buf;
                wr_ptr   <= 11'd0;
                div      <= 8'd0;
                started  <= 1'b0;
                ya_p     <= 8'd99;
                yb_p     <= 8'd99;
            end else if (!started) begin
                // 等一个上升沿零交叉；等不到就一直等（下一帧 frame_st 会重新武装）
                div <= 8'd0;
                if (s_n >= 16'sd0 && s_neg_q) started <= 1'b1;
            end else if (div >= sweep_div - 8'd1) begin
                // ★ v75（A）：用 >= 而不是 == —— 档位是运行期可点的，切换那一拍
                //   div 可能已经越过新档位的上限；用 == 会永远对不上，扫描卡死。
                // ★ v77（P2 38 µs 档撕裂，根因）：v17 加的 `else if (!de) div<=div`
                //   在**行消隐**里冻结时基，但信号本身不停 —— 一列 = 2 拍时整屏
                //   37.8 µs 窗只有 ~1.84 行，每行末尾留 3.7 µs（≈10% 窗宽）的
                //   时间空洞，于是 944 列里被塞进 2 段不同相位的样本，屏上就是
                //   那条把曲线劈成两半的竖直跳变（300 µs 档只占 1.2%、2.4 ms 档
                //   0.15%，所以只有 38 µs 档看得出来）。
                //   现在时基**连续推进**（消隐期也采），前提是 disp_engine 把
                //   q_s_n/q_c_n 改成每拍采（原来只在 de 时更新，消隐期是冻结值，
                //   那才是 v17 要挡的东西）。两边必须一起改，只改一边会退化成
                //   "消隐期写同一列/写冻结样本"。
                div <= 8'd0;
                // 写满 SWEEP_LEN 列之后停手：表里始终是一整屏，不跨面回卷。
                if (wr_ptr < SWEEP_LEN) begin
                    we    <= 1'b1;
                    waddr <= {wr_buf, wr_ptr[9:0]};
                    wdata <= word;
                    wr_ptr <= wr_ptr + 11'd1;
                end
                ya_p <= ya;
                yb_p <= yb;
            end else begin
                div <= div + 8'd1;
            end
        end
    end

endmodule

`default_nettype wire
