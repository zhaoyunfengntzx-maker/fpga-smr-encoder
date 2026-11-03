//==========================================================================
// screen_pattern.v —— 第二版 LCD 屏幕测试程序：画面生成
//   mode=0  F1 标准色轮播（8 色满屏，约 1.0 s/色，四角小字信息）
//   mode=1  F2 触摸点位测试（64px 网格 + 每 128px 坐标数字 + 信息面板）
//           F3 实时点击反馈（准星跟随，抬手保留约 0.5 s）
//
// 约定：像素域 clk / de / pix_x / pix_y 来自 lcd_timing_gen；
//       pixel_data 在 de 有效那拍寄存输出（与第一版 lcd_test_pattern.v 一致）。
//==========================================================================
module screen_pattern #(
    parameter H_DISP      = 1024,
    parameter V_DISP      = 600,
    parameter [5:0] COL_FRAMES  = 6'd58,   // 每色停留帧数（58.6Hz × 58 ≈ 1.0s）
    parameter [5:0] HOLD_FRAMES = 6'd30    // 抬手后准星保留帧数（≈0.5s）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [11:0] pix_x,
    input  wire [11:0] pix_y,
    input  wire        frame_st,
    input  wire        mode,            // 0=F1 标准色  1=F2/F3 点位与反馈
    input  wire        paused,          // 长按：冻结色轮播 / 准星保留
    input  wire        tch_valid,
    input  wire [1:0]  tch_type,        // 0=未识别 1=GT911 2=FT5206
    input  wire [2:0]  tch_num,         // 当前点数
    input  wire [15:0] tch_x0, tch_y0,
    input  wire [15:0] tch_x1, tch_y1,
    input  wire [15:0] tch_x2, tch_y2,
    input  wire [15:0] tch_x3, tch_y3,
    input  wire [15:0] tch_x4, tch_y4,
    input  wire [7:0]  gt_status_raw,   // 0x814E 原始状态字节
    input  wire        int_n,           // GT911 INT 引脚电平（1=空闲）
    output reg  [23:0] pixel_data,
    output reg  [2:0]  color_idx,       // 当前标准色序号（遥测用）
    output reg  [2:0]  disp_num,        // 屏上正在显示的点数
    output reg  [23:0] frame_cnt        // 帧计数（遥测用）
);

    localparam [23:0] C_WHITE   = 24'hFFFFFF;
    localparam [23:0] C_BLACK   = 24'h000000;
    localparam [23:0] C_RED     = 24'hFF0000;
    localparam [23:0] C_GREEN   = 24'h00FF00;
    localparam [23:0] C_BLUE    = 24'h0000FF;
    localparam [23:0] C_CYAN    = 24'h00FFFF;
    localparam [23:0] C_MAGENTA = 24'hFF00FF;
    localparam [23:0] C_YELLOW  = 24'hFFFF00;

    // F1 右下 "FRAME nnnnnn" 的十进制位（fd0=个位 … fd5=十万位），必须声明在函数之前。
    // 用独立 BCD 计数而不是 frame_cnt % 1000000：24 位取模/除法是深进位链，
    // 一旦放进像素组合路径就会把 50 MHz（20 ns）时序顶爆。
    reg [3:0] fd0, fd1, fd2, fd3, fd4, fd5;
    wire bc1 = (fd0 == 4'd9);
    wire bc2 = bc1 && (fd1 == 4'd9);
    wire bc3 = bc2 && (fd2 == 4'd9);
    wire bc4 = bc3 && (fd3 == 4'd9);
    wire bc5 = bc4 && (fd4 == 4'd9);

    //========================================================= 字模 5x7 与工具
    function [4:0] font_row;
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] bits;
        begin
            case (ch)
            8'h20: bits = 35'b00000_00000_00000_00000_00000_00000_00000; // ' '
            8'h2C: bits = 35'b00000_00000_00000_00000_00000_01100_11000; // ','
            8'h2D: bits = 35'b00000_00000_00000_11111_00000_00000_00000; // '-'
            8'h2E: bits = 35'b00000_00000_00000_00000_00000_01100_01100; // '.'
            8'h2F: bits = 35'b00001_00001_00010_00100_01000_10000_10000; // '/'
            8'h30: bits = 35'b01110_10001_10011_10101_11001_10001_01110; // '0'
            8'h31: bits = 35'b00100_01100_00100_00100_00100_00100_01110; // '1'
            8'h32: bits = 35'b01110_10001_00001_00110_01000_10000_11111; // '2'
            8'h33: bits = 35'b11111_00010_00100_00010_00001_10001_01110; // '3'
            8'h34: bits = 35'b00010_00110_01010_10010_11111_00010_00010; // '4'
            8'h35: bits = 35'b11111_10000_11110_00001_00001_10001_01110; // '5'
            8'h36: bits = 35'b00110_01000_10000_11110_10001_10001_01110; // '6'
            8'h37: bits = 35'b11111_00001_00010_00100_01000_01000_01000; // '7'
            8'h38: bits = 35'b01110_10001_10001_01110_10001_10001_01110; // '8'
            8'h39: bits = 35'b01110_10001_10001_01111_00001_00010_01100; // '9'
            8'h3A: bits = 35'b00000_01100_01100_00000_01100_01100_00000; // ':'
            8'h3D: bits = 35'b00000_00000_11111_00000_11111_00000_00000; // '='
            8'h41: bits = 35'b01110_10001_10001_11111_10001_10001_10001; // 'A'
            8'h42: bits = 35'b11110_10001_10001_11110_10001_10001_11110; // 'B'
            8'h43: bits = 35'b01110_10001_10000_10000_10000_10001_01110; // 'C'
            8'h44: bits = 35'b11100_10010_10001_10001_10001_10010_11100; // 'D'
            8'h45: bits = 35'b11111_10000_10000_11110_10000_10000_11111; // 'E'
            8'h46: bits = 35'b11111_10000_10000_11110_10000_10000_10000; // 'F'
            8'h47: bits = 35'b01110_10001_10000_10111_10001_10001_01111; // 'G'
            8'h48: bits = 35'b10001_10001_10001_11111_10001_10001_10001; // 'H'
            8'h49: bits = 35'b01110_00100_00100_00100_00100_00100_01110; // 'I'
            8'h4A: bits = 35'b00111_00010_00010_00010_00010_10010_01100; // 'J'
            8'h4B: bits = 35'b10001_10010_10100_11000_10100_10010_10001; // 'K'
            8'h4C: bits = 35'b10000_10000_10000_10000_10000_10000_11111; // 'L'
            8'h4D: bits = 35'b10001_11011_10101_10101_10001_10001_10001; // 'M'
            8'h4E: bits = 35'b10001_10001_11001_10101_10011_10001_10001; // 'N'
            8'h4F: bits = 35'b01110_10001_10001_10001_10001_10001_01110; // 'O'
            8'h50: bits = 35'b11110_10001_10001_11110_10000_10000_10000; // 'P'
            8'h51: bits = 35'b01110_10001_10001_10001_10101_10010_01101; // 'Q'
            8'h52: bits = 35'b11110_10001_10001_11110_10100_10010_10001; // 'R'
            8'h53: bits = 35'b01111_10000_10000_01110_00001_00001_11110; // 'S'
            8'h54: bits = 35'b11111_00100_00100_00100_00100_00100_00100; // 'T'
            8'h55: bits = 35'b10001_10001_10001_10001_10001_10001_01110; // 'U'
            8'h56: bits = 35'b10001_10001_10001_10001_10001_01010_00100; // 'V'
            8'h57: bits = 35'b10001_10001_10001_10101_10101_11011_10001; // 'W'
            8'h58: bits = 35'b10001_10001_01010_00100_01010_10001_10001; // 'X'
            8'h59: bits = 35'b10001_10001_01010_00100_00100_00100_00100; // 'Y'
            8'h5A: bits = 35'b11111_00001_00010_00100_01000_10000_11111; // 'Z'
            default: bits = 35'b01110_10001_10001_10001_10001_10001_01110;
            endcase
            font_row = bits[35 - (row*5) - 1 -: 5];
        end
    endfunction

    function [7:0] dch;                  // 0..9 → '0'..'9'
        input [3:0] d;
        begin dch = 8'h30 + {4'd0, d}; end
    endfunction

    function [3:0] dg;                   // 十进制第 p 位（p=0 是个位）
        input [23:0] v;
        input [2:0]  p;
        begin
            case (p)
                3'd0: dg = v % 10;
                3'd1: dg = (v / 10) % 10;
                3'd2: dg = (v / 100) % 10;
                3'd3: dg = (v / 1000) % 10;
                3'd4: dg = (v / 10000) % 10;
                default: dg = (v / 100000) % 10;
            endcase
        end
    endfunction

    function [7:0] hexc;                 // 4bit → '0'..'F'
        input [3:0] n;
        begin
            if (n < 4'd10) hexc = 8'h30 + {4'd0, n};
            else           hexc = 8'h41 + {4'd0, n} - 8'd10;
        end
    endfunction

    // 注：原 digit3()/dg() 组合版 3 位十进制换算已从像素路径移除（÷10/÷100 进位链太深），
    //     刻度值改用 tick3() 查表，帧计数改用 fd0..fd5 BCD 寄存器；dg() 仍供面板 pn_dec 使用。

    function [23:0] color_rgb;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: color_rgb = C_WHITE;
                3'd1: color_rgb = C_BLACK;
                3'd2: color_rgb = C_RED;
                3'd3: color_rgb = C_GREEN;
                3'd4: color_rgb = C_BLUE;
                3'd5: color_rgb = C_CYAN;
                3'd6: color_rgb = C_MAGENTA;
                default: color_rgb = C_YELLOW;
            endcase
        end
    endfunction

    function [23:0] point_color;
        input [2:0] i;
        begin
            case (i)
                3'd0: point_color = C_WHITE;
                3'd1: point_color = C_RED;
                3'd2: point_color = C_GREEN;
                3'd3: point_color = C_BLUE;
                default: point_color = C_YELLOW;
            endcase
        end
    endfunction

    function [63:0] color_name;          // 8 字符定宽
        input [2:0] idx;
        begin
            case (idx)
                3'd0: color_name = "WHITE   ";
                3'd1: color_name = "BLACK   ";
                3'd2: color_name = "RED     ";
                3'd3: color_name = "GREEN   ";
                3'd4: color_name = "BLUE    ";
                3'd5: color_name = "CYAN    ";
                3'd6: color_name = "MAGENTA ";
                default: color_name = "YELLOW  ";
            endcase
        end
    endfunction

    function in_win;                     // |a-b| <= w （12bit 模运算，无下溢问题）
        input [11:0] a;
        input [11:0] b;
        input [11:0] w;
        begin in_win = (a + w >= b) && (a <= b + w); end
    endfunction

    // 注意：px/py 必须显式传参。xsim 对"连续赋值里调用函数、函数体又直接引用模块信号"
    // 的敏感度推断不可靠（pix_x/pix_y 变化不会重算），实测 hit0 恒为 0。
    function cross_hit;                  // 十字 + 空心方框
        input [11:0] cx;
        input [11:0] cy;
        input [11:0] px;
        input [11:0] py;
        begin
            cross_hit = (in_win(px, cx, 12'd16) && in_win(py, cy, 12'd1))
                     || (in_win(py, cy, 12'd16) && in_win(px, cx, 12'd1))
                     || (in_win(px, cx, 12'd5) && in_win(py, cy, 12'd5)
                         && !(in_win(px, cx, 12'd3) && in_win(py, cy, 12'd3)));
        end
    endfunction

    function lbl_hit;                    // 准星右侧 "+14,+14" 处的 "Tn"
        input [11:0] cx;
        input [11:0] cy;
        input [2:0]  i;
        input [11:0] px;
        input [11:0] py;
        reg [11:0] lx, ly;
        reg [3:0]  ch;                   // 0 = 'T'，1 = 编号数字
        reg [2:0]  gx, gy;               // 字模内坐标
        begin
            lx = (px >= cx) ? (px - cx) : 12'd0;
            ly = (py >= cy) ? (py - cy) : 12'd0;
            lx = lx - 12'd14;            // 标签左上角为局部原点
            ly = ly - 12'd14;
            ch = lx[3];                  // 0: 局部 x 0..7，1: 8..15
            gx = lx[2:0];
            gy = ly[2:0];
            lbl_hit = (px >= cx + 12'd14) && (py >= cy + 12'd14)
                   && (lx < 12'd16) && (ly < 12'd8)
                   && (gx < 3'd5) && (gy < 3'd7)
                   && font_row(ch ? dch(i + 3'd1) : "T", gy)[4 - gx];
        end
    endfunction

    // F1 左上 12 字符："WHITE  1/8  "
    function [7:0] f1_left_ch;
        input [3:0] i;
        input [2:0] cidx;
        reg [63:0] nm;
        begin
            nm = color_name(cidx);
            case (i)
                4'd0: f1_left_ch = nm[63:56];
                4'd1: f1_left_ch = nm[55:48];
                4'd2: f1_left_ch = nm[47:40];
                4'd3: f1_left_ch = nm[39:32];
                4'd4: f1_left_ch = nm[31:24];
                4'd5: f1_left_ch = nm[23:16];
                4'd6: f1_left_ch = nm[15:8];
                4'd7: f1_left_ch = nm[7:0];
                4'd8: f1_left_ch = 8'h20;
                4'd9: f1_left_ch = dch(cidx + 3'd1);
                4'd10: f1_left_ch = 8'h2F;   // '/'
                default: f1_left_ch = "8";
            endcase
        end
    endfunction

    // F1 右上 6 字符：RGB 十六进制
    function [7:0] f1_rgb_ch;
        input [3:0] i;
        input [2:0] cidx;
        reg [23:0] rgb;
        begin
            rgb = color_rgb(cidx);
            case (i)
                4'd0: f1_rgb_ch = hexc(rgb[23:20]);
                4'd1: f1_rgb_ch = hexc(rgb[19:16]);
                4'd2: f1_rgb_ch = hexc(rgb[15:12]);
                4'd3: f1_rgb_ch = hexc(rgb[11:8]);
                4'd4: f1_rgb_ch = hexc(rgb[7:4]);
                4'd5: f1_rgb_ch = hexc(rgb[3:0]);
                default: f1_rgb_ch = 8'h20;
            endcase
        end
    endfunction

    // F1 右下 12 字符："FRAME nnnnnn"（6 位十进制直接来自 fd0..fd5 寄存器）
    function [7:0] f1_frame_ch;
        input [3:0] i;
        begin
            case (i)
                4'd0: f1_frame_ch = "F";
                4'd1: f1_frame_ch = "R";
                4'd2: f1_frame_ch = "A";
                4'd3: f1_frame_ch = "M";
                4'd4: f1_frame_ch = "E";
                4'd5: f1_frame_ch = 8'h20;
                4'd6: f1_frame_ch = dch(fd5);
                4'd7: f1_frame_ch = dch(fd4);
                4'd8: f1_frame_ch = dch(fd3);
                4'd9: f1_frame_ch = dch(fd2);
                4'd10: f1_frame_ch = dch(fd1);
                default: f1_frame_ch = dch(fd0);
            endcase
        end
    endfunction

    // 刻度值 = idx*128 的 3 位十进制（纯查表，避免 ÷10/÷100 进位链进像素路径）
    function [7:0] tick3;
        input [2:0] idx;
        input [1:0] col;
        begin
            case (idx)
            3'd0: tick3 = (col == 2'd2) ? "0" : 8'h20;                       //   0
            3'd1: tick3 = (col == 2'd0) ? "1" : (col == 2'd1) ? "2" : "8";   // 128
            3'd2: tick3 = (col == 2'd0) ? "2" : (col == 2'd1) ? "5" : "6";   // 256
            3'd3: tick3 = (col == 2'd0) ? "3" : (col == 2'd1) ? "8" : "4";   // 384
            3'd4: tick3 = (col == 2'd0) ? "5" : (col == 2'd1) ? "1" : "2";   // 512
            3'd5: tick3 = (col == 2'd0) ? "6" : (col == 2'd1) ? "4" : "0";   // 640
            3'd6: tick3 = (col == 2'd0) ? "7" : (col == 2'd1) ? "6" : "8";   // 768
            default: tick3 = (col == 2'd0) ? "8" : (col == 2'd1) ? "9" : "6"; // 896
            endcase
        end
    endfunction

    //================================================= 色轮播 / 显示点保持状态
    reg [5:0]  col_cnt;
    reg [5:0]  hold_cnt;
    // 屏上显示用的坐标（12 位足够：屏宽 1024 / 高 600）
    reg [11:0] dxa [0:4];
    reg [11:0] dya [0:4];

    //（fd0..fd5 十进制帧计数位已在文件顶部声明：函数里要用，必须先声明）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            color_idx <= 3'd0;
            col_cnt   <= 6'd0;
            hold_cnt  <= 6'd0;
            disp_num  <= 3'd0;
            frame_cnt <= 24'd0;
            dxa[0] <= 12'd0; dya[0] <= 12'd0;
            dxa[1] <= 12'd0; dya[1] <= 12'd0;
            dxa[2] <= 12'd0; dya[2] <= 12'd0;
            dxa[3] <= 12'd0; dya[3] <= 12'd0;
            dxa[4] <= 12'd0; dya[4] <= 12'd0;
            fd0 <= 4'd0; fd1 <= 4'd0; fd2 <= 4'd0;
            fd3 <= 4'd0; fd4 <= 4'd0; fd5 <= 4'd0;
        end else if (frame_st) begin
            frame_cnt <= frame_cnt + 24'd1;

            // 屏上十进制帧计数 +1（进位在寄存器之间传递，只有 6 级）
            fd0 <= bc1 ? 4'd0 : fd0 + 4'd1;
            fd1 <= bc2 ? 4'd0 : (bc1 ? fd1 + 4'd1 : fd1);
            fd2 <= bc3 ? 4'd0 : (bc2 ? fd2 + 4'd1 : fd2);
            fd3 <= bc4 ? 4'd0 : (bc3 ? fd3 + 4'd1 : fd3);
            fd4 <= bc5 ? 4'd0 : (bc4 ? fd4 + 4'd1 : fd4);
            fd5 <= (bc5 && (fd5 != 4'd9)) ? fd5 + 4'd1 : fd5;

            // F1：每 COL_FRAMES 帧换一色（paused 冻结）
            if (!paused) begin
                if (col_cnt == COL_FRAMES - 6'd1) begin
                    col_cnt   <= 6'd0;
                    color_idx <= color_idx + 3'd1;
                end else begin
                    col_cnt <= col_cnt + 6'd1;
                end
            end

            // F2/F3：有触点就跟踪，抬手后保留 HOLD_FRAMES 帧
            if (tch_num != 3'd0) begin
                hold_cnt <= HOLD_FRAMES;
                disp_num <= tch_num;
                dxa[0] <= tch_x0[11:0]; dya[0] <= tch_y0[11:0];
                dxa[1] <= tch_x1[11:0]; dya[1] <= tch_y1[11:0];
                dxa[2] <= tch_x2[11:0]; dya[2] <= tch_y2[11:0];
                dxa[3] <= tch_x3[11:0]; dya[3] <= tch_y3[11:0];
                dxa[4] <= tch_x4[11:0]; dya[4] <= tch_y4[11:0];
            end else begin
                if (hold_cnt != 6'd0) begin
                    if (!paused) hold_cnt <= hold_cnt - 6'd1;
                end else begin
                    disp_num <= 3'd0;
                end
            end
        end
    end

    //============================================================ F1 四角小字
    wire [11:0] ax    = pix_x - 12'd8;
    wire        a_in  = (pix_x >= 12'd8) && (pix_x < 12'd104) && (pix_y >= 12'd8) && (pix_y < 12'd16);
    wire [3:0]  a_col = ax[6:3];
    wire        a_area = a_in && (a_col < 4'd12) && (ax[2:0] < 3'd5) && (pix_y[2:0] < 3'd7);
    wire        a_bit  = a_area && font_row(f1_left_ch(a_col, color_idx), pix_y[2:0])[4 - ax[2:0]];

    wire [11:0] bx    = pix_x - 12'd968;
    wire        b_in  = (pix_x >= 12'd968) && (pix_y >= 12'd8) && (pix_y < 12'd16);
    wire [3:0]  b_col = bx[6:3];
    wire        b_area = b_in && (b_col < 4'd6) && (bx[2:0] < 3'd5) && (pix_y[2:0] < 3'd7);
    wire        b_bit  = b_area && font_row(f1_rgb_ch(b_col, color_idx), pix_y[2:0])[4 - bx[2:0]];

    wire [11:0] cx2   = pix_x - 12'd920;
    wire        c_in  = (pix_x >= 12'd920) && (pix_y >= 12'd584) && (pix_y < 12'd592);
    wire [3:0]  c_col = cx2[6:3];
    wire        c_area = c_in && (c_col < 4'd12) && (cx2[2:0] < 3'd5) && (pix_y[2:0] < 3'd7);
    wire        c_bit  = c_area && font_row(f1_frame_ch(c_col), pix_y[2:0])[4 - cx2[2:0]];

    //=================================================== F2 网格与坐标数字
    wire grid_v  = (pix_x[5:0] == 6'd0);
    wire grid_h  = (pix_y[5:0] == 6'd0);
    wire grid_mj = (pix_x[6:0] == 7'd0) || (pix_y[6:0] == 7'd0);
    wire [23:0] grid_pix = grid_mj ? 24'h4A6A8A
                         : (grid_v || grid_h) ? 24'h2A3A4A : 24'h101820;

    // 底部 X 坐标（0/128/…/896，3 字符）
    wire        xl_in  = (pix_y >= 12'd584) && (pix_y < 12'd592) && (pix_x[6:0] < 7'd24);
    wire [2:0]  xl_col = pix_x[4:3];
    wire        xl_area = xl_in && (xl_col < 3'd3) && (pix_x[2:0] < 3'd5) && (pix_y[2:0] < 3'd7);
    wire        xl_bit  = xl_area && font_row(tick3(pix_x[9:7], xl_col), pix_y[2:0])[4 - pix_x[2:0]];

    // 右侧 Y 坐标（0/128/…/512，3 字符）
    wire [11:0] yl_dx  = pix_x - 12'd1000;
    wire        yl_in  = (pix_x >= 12'd1000) && (pix_y[6:0] < 7'd24) && (pix_y < 12'd576);
    wire [2:0]  yl_col = yl_dx[4:3];
    wire        yl_area = yl_in && (yl_col < 3'd3) && (yl_dx[2:0] < 3'd5) && (pix_y[2:0] < 3'd7);
    wire        yl_bit  = yl_area && font_row(tick3(pix_y[9:7], yl_col), pix_y[2:0])[4 - yl_dx[2:0]];

    //========================================================= F2 信息面板
    // 20 列 × 8 行，字符格 16×16（5×7 字模放大 2 倍），面板 (8,8) → 320×128
    reg [7:0] pn_buf [0:159];
    integer   pi;
    integer   pj;

    task pn_set;
        input [3:0] row;
        input [4:0] col;
        input [7:0] ch;
        begin pn_buf[row * 5'd20 + col] <= ch; end
    endtask

    task pn_dec;
        input [3:0]  row;
        input [4:0]  col;
        input [23:0] v;
        input [3:0]  nd;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                if (k < nd) pn_set(row, col + nd - 1 - k, dch(dg(v, k[2:0])));
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pi = 0; pi < 160; pi = pi + 1) pn_buf[pi] <= 8'h20;
        end else if (frame_st) begin
            for (pi = 0; pi < 160; pi = pi + 1) pn_buf[pi] <= 8'h20;

            // row0: "TOUCH TEST" + "DOWN"/"UP"
            pn_set(4'd0, 5'd0, "T"); pn_set(4'd0, 5'd1, "O"); pn_set(4'd0, 5'd2, "U");
            pn_set(4'd0, 5'd3, "C"); pn_set(4'd0, 5'd4, "H"); pn_set(4'd0, 5'd5, " ");
            pn_set(4'd0, 5'd6, "T"); pn_set(4'd0, 5'd7, "E"); pn_set(4'd0, 5'd8, "S");
            pn_set(4'd0, 5'd9, "T");
            if (tch_num != 3'd0) begin
                pn_set(4'd0, 5'd11, "D"); pn_set(4'd0, 5'd12, "O");
                pn_set(4'd0, 5'd13, "W"); pn_set(4'd0, 5'd14, "N");
            end else if (hold_cnt != 6'd0) begin
                pn_set(4'd0, 5'd11, "U"); pn_set(4'd0, 5'd12, "P");
            end

            // row1: "PTS n  IC xxxxx"
            pn_set(4'd1, 5'd0, "P"); pn_set(4'd1, 5'd1, "T"); pn_set(4'd1, 5'd2, "S");
            pn_set(4'd1, 5'd3, " "); pn_set(4'd1, 5'd4, dch({1'b0, tch_num}));
            pn_set(4'd1, 5'd5, " "); pn_set(4'd1, 5'd6, " ");
            pn_set(4'd1, 5'd7, "I"); pn_set(4'd1, 5'd8, "C"); pn_set(4'd1, 5'd9, " ");
            if (tch_type == 2'd1) begin
                pn_set(4'd1, 5'd10, "G"); pn_set(4'd1, 5'd11, "T");
                pn_set(4'd1, 5'd12, "9"); pn_set(4'd1, 5'd13, "1");
                pn_set(4'd1, 5'd14, "1");
            end else if (tch_type == 2'd2) begin
                pn_set(4'd1, 5'd10, "F"); pn_set(4'd1, 5'd11, "T");
                pn_set(4'd1, 5'd12, "5"); pn_set(4'd1, 5'd13, "2");
                pn_set(4'd1, 5'd14, "0"); pn_set(4'd1, 5'd15, "6");
            end

            // row2: "STS xx INT n Vn"
            pn_set(4'd2, 5'd0, "S"); pn_set(4'd2, 5'd1, "T"); pn_set(4'd2, 5'd2, "S");
            pn_set(4'd2, 5'd3, " ");
            pn_set(4'd2, 5'd4, hexc(gt_status_raw[7:4]));
            pn_set(4'd2, 5'd5, hexc(gt_status_raw[3:0]));
            pn_set(4'd2, 5'd6, " "); pn_set(4'd2, 5'd7, "I"); pn_set(4'd2, 5'd8, "N");
            pn_set(4'd2, 5'd9, "T"); pn_set(4'd2, 5'd10, " ");
            pn_set(4'd2, 5'd11, dch({3'd0, int_n}));
            pn_set(4'd2, 5'd12, " "); pn_set(4'd2, 5'd13, "V");
            pn_set(4'd2, 5'd14, dch({3'd0, tch_valid}));

            // row3..row7: "Tn xxxx,yyyy"
            for (pj = 0; pj < 5; pj = pj + 1) begin
                pn_set(4'd3 + pj[3:0], 5'd0, "T");
                pn_set(4'd3 + pj[3:0], 5'd1, dch(pj[3:0] + 4'd1));
                pn_set(4'd3 + pj[3:0], 5'd3, " ");
                pn_dec(4'd3 + pj[3:0], 5'd4, {12'd0, dxa[pj]}, 4'd4);
                pn_set(4'd3 + pj[3:0], 5'd8, ",");
                pn_dec(4'd3 + pj[3:0], 5'd9, {12'd0, dya[pj]}, 4'd4);
            end
        end
    end

    wire [11:0] p_dx  = pix_x - 12'd8;
    wire [11:0] p_dy  = pix_y - 12'd8;
    wire        p_bg  = (pix_x >= 12'd8) && (pix_x < 12'd328)
                     && (pix_y >= 12'd8) && (pix_y < 12'd136);
    wire [4:0]  p_col = p_dx[8:4];
    wire [3:0]  p_row = p_dy[7:4];
    wire [8:0]  p_idx = p_row * 5'd20 + {4'd0, p_col};
    wire        p_bit = p_bg && (p_dx[3:1] < 3'd5) && (p_dy[3:1] < 3'd7)
                     && font_row(pn_buf[p_idx[7:0]], p_dy[3:1])[4 - p_dx[3:1]];

    //============================================================= F2/F3 准星
    wire [2:0] n_show = (disp_num > 3'd5) ? 3'd5 : disp_num;
    wire hit0 = (n_show > 3'd0) && cross_hit(dxa[0], dya[0], pix_x, pix_y);
    wire hit1 = (n_show > 3'd1) && cross_hit(dxa[1], dya[1], pix_x, pix_y);
    wire hit2 = (n_show > 3'd2) && cross_hit(dxa[2], dya[2], pix_x, pix_y);
    wire hit3 = (n_show > 3'd3) && cross_hit(dxa[3], dya[3], pix_x, pix_y);
    wire hit4 = (n_show > 3'd4) && cross_hit(dxa[4], dya[4], pix_x, pix_y);
    wire lb0  = (n_show > 3'd0) && lbl_hit(dxa[0], dya[0], 3'd0, pix_x, pix_y);
    wire lb1  = (n_show > 3'd1) && lbl_hit(dxa[1], dya[1], 3'd1, pix_x, pix_y);
    wire lb2  = (n_show > 3'd2) && lbl_hit(dxa[2], dya[2], 3'd2, pix_x, pix_y);
    wire lb3  = (n_show > 3'd3) && lbl_hit(dxa[3], dya[3], 3'd3, pix_x, pix_y);
    wire lb4  = (n_show > 3'd4) && lbl_hit(dxa[4], dya[4], 3'd4, pix_x, pix_y);

    //================================================================= 合成
    reg [23:0] col;
    always @(*) begin
        if (mode == 1'b0) begin
            col = color_rgb(color_idx);
            if (a_area)      col = a_bit ? 24'hFFFFFF : 24'h101010;
            else if (b_area) col = b_bit ? 24'hFFFFFF : 24'h101010;
            else if (c_area) col = c_bit ? 24'hFFFFFF : 24'h101010;
        end else begin
            col = grid_pix;
            if (xl_bit)                    col = 24'hFFFFFF;
            else if (yl_bit)               col = 24'hFFFFFF;
            else if (hit0 || lb0)          col = point_color(3'd0);
            else if (hit1 || lb1)          col = point_color(3'd1);
            else if (hit2 || lb2)          col = point_color(3'd2);
            else if (hit3 || lb3)          col = point_color(3'd3);
            else if (hit4 || lb4)          col = point_color(3'd4);
            if (p_bg) col = p_bit ? 24'hFFFFFF : 24'h080808;   // 面板最后画，保证可读
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   pixel_data <= 24'h000000;
        else if (de)  pixel_data <= col;
        else          pixel_data <= 24'h000000;
    end

endmodule
