// ===========================================================================
// disp/seg7.v -- 七段数码管字形（组合，判"这一个像素要不要点亮"）
//
// 为什么需要这个模块：
//   docs/13_display_ui_requirements.md §6.3 要求倍频（2…256）除了「预设档位步进器 +
//   长按加速 + 离散滑条（档位吸附）」之外还要有**数字键盘兜底**。键盘上要画 1..9/0
//   十个数字，可是面板内的字库字形被 disp/disp_engine.v 的 `glyph_pnl_sup` 抑制
//   （面板底下压着 P1 的卡片文字），val 平面的 48 px 数字同样被它抑制 ——
//   所以键盘上的数字只能用**图形**画。本模块就是那套图形。
//
// 为什么不位图化：
//   两种字号（44 px 键内的 20x32、输入窗里的 48x80）用同一套"按比例"的段矩形就够，
//   不需要两块字形 ROM 与两条读通路；段坐标全是常数比较，在像素通路里只是几个
//   AND/OR（与 disp/disp_engine.v 的 P5 条形图、标题带按钮同一纪律）。
//
// 段命名（教科书七段）：
//        aaaa
//       f    b
//       f    b
//        gggg
//       e    c
//       e    c
//        dddd
//   bit 顺序 mask = {a,b,c,d,e,f,g}，g 是最低位。角上两段交叠时按
//   a>b>c>d>e>f>g 取一个 —— 交叠处同一颜色，看上去就是"加粗的角"。
//
// 与使用者的共同契约：
//   调用者给出的 (X0, Y0) 是**字段左上角**，字段大小由 BIG 决定（20x32 / 48x80）。
//   字段之外的像素一律返回 0：`in_box` 显式夹住 dx/dy，否则字段右边一列像素会
//   落进 b/c 段的 `dx >= W-T` 区间里、在字段外面点亮一竖条（这是本模块第一版
//   的真实缺陷，disp/tb_seg7.v 的"字段外必须全灭"就是钉它的）。
// ===========================================================================
`default_nettype none

module seg7 #(
    parameter [11:0] X0   = 12'd0,     // 字段左上角（像素坐标）
    parameter [11:0] Y0   = 12'd0,
    parameter        BIG  = 1'b0       // 0 = 20x32（44 px 键内）/ 1 = 48x80（输入窗）
)(
    input  wire [11:0] cx,
    input  wire [11:0] cy,
    input  wire [3:0]  d,              // 十进制数字 0..9；>9 视为"不画"
    input  wire        blank,          // 空白（前导零不画）
    output wire        on
);

    // ---- 字段几何：W 宽、H 高、T 段厚、MID 腰线 ----
    localparam [11:0] W   = BIG ? 12'd48 : 12'd20;
    localparam [11:0] H   = BIG ? 12'd80 : 12'd32;
    localparam [11:0] T   = BIG ? 12'd8  : 12'd4;
    localparam [11:0] MID = H >> 1;    // 80/2 = 40、32/2 = 16
    localparam [11:0] HALF_T = T >> 1;

    // ★ 字段**左/上**两侧的像素必须显式挡掉：dx/dy 是"钳到 0"的，字段左边一列
    //   像素会因此拿到 dx=0 而落进 f/e 段的 `dx < T` 区间，在字段外面点亮一竖条
    //   （disp/tb_seg7.v 的"字段外必须全灭"就是钉它的：第一版真的亮着，
    //    大字段的亮像素总数因此从 1536 涨到 2146）。
    //   ★ 变量名不能叫 `before` —— 那是 SystemVerilog 的断言关键字，
    //     xvlog 报 `VRFC 10-8549 SystemVerilog 2017 keyword 'before' used in
    //     incorrect context`。
    wire pre_field = (cx < X0) || (cy < Y0);
    wire [11:0] dx = pre_field ? 12'd0 : (cx - X0);
    wire [11:0] dy = pre_field ? 12'd0 : (cy - Y0);

    wire in_box = (!pre_field) && (dx < W) && (dy < H);

    // ---- 七个段矩形（全部相对字段左上角）----
    wire seg_a = in_box && (dy < T) && (dx >= T) && (dx < W - T);
    wire seg_f = in_box && (dx < T) && (dy >= T) && (dy < MID);
    wire seg_b = in_box && (dx >= W - T) && (dy >= T) && (dy < MID);
    wire seg_g = in_box && (dy >= MID - HALF_T) && (dy < MID + HALF_T) &&
                 (dx >= T) && (dx < W - T);
    wire seg_e = in_box && (dx < T) && (dy >= MID) && (dy < H - T);
    wire seg_c = in_box && (dx >= W - T) && (dy >= MID) && (dy < H - T);
    wire seg_d = in_box && (dy >= H - T) && (dx >= T) && (dx < W - T);

    // ---- 数字 → 段掩码 {a,b,c,d,e,f,g} ----
    wire [6:0] mask =
        (d == 4'd0) ? 7'b1111110 :      // 0：g 灭
        (d == 4'd1) ? 7'b0110000 :
        (d == 4'd2) ? 7'b1101101 :
        (d == 4'd3) ? 7'b1111001 :
        (d == 4'd4) ? 7'b0110011 :
        (d == 4'd5) ? 7'b1011011 :
        (d == 4'd6) ? 7'b1011111 :
        (d == 4'd7) ? 7'b1110000 :
        (d == 4'd8) ? 7'b1111111 :
        (d == 4'd9) ? 7'b1111011 :
                      7'b0000000;        // >9：什么都不画

    // ---- 这一像素落在哪一段（优先级 a>b>c>d>e>f>g）----
    wire [6:0] seg = seg_a ? 7'b1000000 :
                     seg_b ? 7'b0100000 :
                     seg_c ? 7'b0010000 :
                     seg_d ? 7'b0001000 :
                     seg_e ? 7'b0000100 :
                     seg_f ? 7'b0000010 :
                     seg_g ? 7'b0000001 :
                             7'b0000000;

    assign on = (~blank) && (|(mask & seg));

endmodule

`default_nettype wire
