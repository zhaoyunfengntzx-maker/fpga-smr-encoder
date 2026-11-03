// -----------------------------------------------------------------------------
//  lcd_test/rtl/lcd_test_pattern.v
//  LCD 测试画面发生器：负责"这一像素该是什么颜色"，共 10 组测试画面。
//
//  画面清单（按键切换；无按键时每 256 帧 ≈ 4.4 秒自动切一格）：
//    0  彩条        白/黑/红/绿/蓝 5 等分 —— 与指南官方例程一致，确认 RGB 三通道
//                   没有接反、灰度台阶正常
//    1  单色轮换    红/绿/蓝/白/黑 按帧轮换 —— 确认"该纯的地方纯"
//    2  灰阶渐变    R=G=B=0..255 左右扫 —— 8bit 灰度与伽马
//    3  1 像素棋盘  奇偶像素黑白交替 —— 最狠的像素级测试，糊成灰白=采样时序有问题
//    4  边框+网格   外框 + 128x64 网格 + 中心十字 —— 确认有效区起点/终点、无偏移
//    5  运动块      白块沿屏幕跑圈 —— 主观判断流畅度与撕裂
//    6  纯黑        漏光/亮点暗点
//    7  纯白        亮度均匀性/暗角（也顺带压电源）
//    8  触控可视化  5 点十字准星 + 触摸 IC 型号 + 每秒读写/错误/触摸统计
//    9  触控响应格  10x10 大格，摸到哪格哪格亮 —— 覆盖范围与多点并发一目了然
//
//  为什么不是"只有彩条"：彩条只能证明"能亮"。1 像素棋盘能暴露像素时钟相位/采样沿
//  错误（表现为整屏灰白糊成一片）；10x10 触控格能一眼看出触摸坐标是否线性映射到全屏
//  （常见故障：x/y 少一位、或映射到错误的轴上）。
//
//  文本渲染说明：屏幕宽 1024 是 6 的整数倍、600 是 8 和 12 的整数倍，所以
//  "第几列/第几行/字内行列"都可以用整除取模直接算，不需要整行字模数组。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module lcd_test_pattern (
    input               clk_pix,
    input               rst_n,

    input  [11:0]       pix_x,
    input  [11:0]       pix_y,
    input               frame_st,        // 每帧第一个有效像素
    input               de,

    input               pat_adv,         // 单周期脉冲：切到下一幅画面

    // ---- 触摸数据（已同步到 clk_pix 域） ----
    input  [1:0]        tch_type,        // 0=未知 1=GT911 2=FT5x06
    input               tch_valid,
    input  [2:0]        tch_num,
    input  [15:0]       tch_x0, tch_y0,
    input  [15:0]       tch_x1, tch_y1,
    input  [15:0]       tch_x2, tch_y2,
    input  [15:0]       tch_x3, tch_y3,
    input  [15:0]       tch_x4, tch_y4,
    // ---- 统计（每秒门控后的快照） ----
    input  [15:0]       reads_ps,        // 本秒完成传输次数
    input  [15:0]       err_ps,          // 本秒 NACK + 超时 次数
    input  [15:0]       touch_ps,        // 本秒检测到触摸的次数
    input  [7:0]        probe_code,      // 探测状态（1=正在探 GT911 2=正在探 FT）

    output reg          frame_tick,      // 每帧一个脉冲
    output reg  [3:0]   pattern,
    output reg  [23:0]  pixel_data
);

    // ======================================================== 常量与局部声明
    localparam [23:0] C_WHITE = 24'hFFFFFF,
                      C_BLACK = 24'h000000,
                      C_RED   = 24'hFF0000,
                      C_GREEN = 24'h00FF00,
                      C_BLUE  = 24'h0000FF,
                      C_YELLOW= 24'hFFFF00,
                      C_CYAN  = 24'h00FFFF,
                      C_MAG   = 24'hFF00FF,
                      C_GRAY  = 24'h808080,
                      C_DARK  = 24'h202020,
                      C_ORANGE= 24'hFF8000,
                      C_BG    = 24'h101820;

    localparam [11:0] H_DISP = 12'd1024;
    localparam [11:0] V_DISP = 12'd600;

    reg [7:0]  auto_cnt;
    reg        pat_pend;      // 画面切换请求锁存（pat_adv 单周期脉冲 -> 等帧边界）
    reg [9:0]  anim;              // 运动块动画（按帧）
    reg [2:0]  blink;             // 单色轮换/闪烁
    reg [23:0] col;
    reg        in_text;

    wire [11:0] cwidth = H_DISP / 12'd5;

    // ============================================================== 字模 5x7
    // 一行 = 5bit（bit4 是左边一列），共 7 行；索引 = ASCII。
    function [4:0] font_row;
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] bits;
        begin
            case (ch)
            8'h20: bits = 35'b00000_00000_00000_00000_00000_00000_00000; // ' '
            8'h2D: bits = 35'b00000_00000_00000_11111_00000_00000_00000; // '-'
            8'h2E: bits = 35'b00000_00000_00000_00000_00000_01100_01100; // '.'
            8'h3A: bits = 35'b00000_01100_01100_00000_01100_01100_00000; // ':'
            8'h3D: bits = 35'b00000_00000_11111_00000_11111_00000_00000; // '='
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
            default: bits = 35'b01110_10001_10001_10001_10001_10001_01110; // 未知=0
            endcase
            font_row = bits[35 - (row*5) - 1 -: 5];
        end
    endfunction

    // ==================================================== 文本行的字符内容
    // 只有 8/9 两幅画面用文本。line 0..6 是标题/状态/统计，7..11 是 5 个点的坐标。
    function [7:0] char_at;
        input [3:0]  line;
        input [5:0]  col;
        reg [7:0] ch;
        reg [5:0] pos;      // 该行内"数据字段"的起始列
        reg [3:0] d;        // 十六进制数字
        begin
            ch  = " ";      // 默认空格
            pos = 6'd0;
            case (line)
            // ---------------------------------------- 0: 标题
            4'd0: begin
                case (col)
                6'd0: ch="L"; 6'd1: ch="C"; 6'd2: ch="D"; 6'd3: ch=" ";
                6'd4: ch="T"; 6'd5: ch="E"; 6'd6: ch="S"; 6'd7: ch="T";
                6'd8: ch=" "; 6'd9: ch="1"; 6'd10: ch="0"; 6'd11: ch="2";
                6'd12: ch="4"; 6'd13: ch="X"; 6'd14: ch="6"; 6'd15: ch="0";
                6'd16: ch="0"; 6'd17: ch=" "; 6'd18: ch="P"; 6'd19: ch="A";
                6'd20: ch="T"; 6'd21: ch="T"; 6'd22: ch="E"; 6'd23: ch="R";
                6'd24: ch="N"; 6'd25: ch=" "; 6'd26: ch="0" + pattern;
                default: ch=" ";
                endcase
            end
            // ---------------------------------------- 1: 触摸 IC 型号 + 点数
            4'd1: begin
                case (col)
                6'd0: ch="T"; 6'd1: ch="O"; 6'd2: ch="U"; 6'd3: ch="C";
                6'd4: ch="H"; 6'd5: ch=" "; 6'd6: ch="I"; 6'd7: ch="C";
                6'd8: ch="=";
                6'd9:  ch = (tch_type == 2'd1) ? "G" : (tch_type == 2'd2) ? "F" : "?";
                6'd10: ch = (tch_type == 2'd1) ? "T" : (tch_type == 2'd2) ? "T" : " ";
                6'd11: ch = (tch_type == 2'd1) ? "9" : (tch_type == 2'd2) ? "5" : " ";
                6'd12: ch = (tch_type == 2'd1) ? "1" : (tch_type == 2'd2) ? "X" : " ";
                6'd13: ch = (tch_type == 2'd1) ? "1" : (tch_type == 2'd2) ? "X" : " ";
                6'd14: ch = (tch_type == 2'd2) ? "6" : " ";
                6'd16: ch="P"; 6'd17: ch="T"; 6'd18: ch="S"; 6'd19: ch="=";
                6'd20: ch = "0" + {1'b0, tch_num};
                6'd22: ch = (probe_code == 8'd1) ? "P" : " ";
                6'd23: ch = (probe_code == 8'd1) ? "R" : " ";
                6'd24: ch = (probe_code == 8'd1) ? "O" : " ";
                6'd25: ch = (probe_code == 8'd1) ? "B" : " ";
                6'd26: ch = (probe_code == 8'd2) ? "P" : " ";
                6'd27: ch = (probe_code == 8'd2) ? "R" : " ";
                6'd28: ch = (probe_code == 8'd2) ? "O" : " ";
                6'd29: ch = (probe_code == 8'd2) ? "B" : " ";
                default: ch=" ";
                endcase
            end
            // ---------------------------------------- 2: 每秒读写次数
            4'd2: begin
                case (col)
                6'd0: ch="R"; 6'd1: ch="D"; 6'd2: ch="/"; 6'd3: ch="S";
                6'd4: ch="=";
                6'd5: ch = "0" + (reads_ps / 16'd1000) % 16'd10;
                6'd6: ch = "0" + (reads_ps / 16'd100)  % 16'd10;
                6'd7: ch = "0" + (reads_ps / 16'd10)   % 16'd10;
                6'd8: ch = "0" +  reads_ps             % 16'd10;
                6'd10: ch="E"; 6'd11: ch="R"; 6'd12: ch="R"; 6'd13: ch="=";
                6'd14: ch = "0" + (err_ps / 16'd1000) % 16'd10;
                6'd15: ch = "0" + (err_ps / 16'd100)  % 16'd10;
                6'd16: ch = "0" + (err_ps / 16'd10)   % 16'd10;
                6'd17: ch = "0" +  err_ps             % 16'd10;
                6'd19: ch="T"; 6'd20: ch="C"; 6'd21: ch="H"; 6'd22: ch="=";
                6'd23: ch = "0" + (touch_ps / 16'd1000) % 16'd10;
                6'd24: ch = "0" + (touch_ps / 16'd100)  % 16'd10;
                6'd25: ch = "0" + (touch_ps / 16'd10)   % 16'd10;
                6'd26: ch = "0" +  touch_ps             % 16'd10;
                default: ch=" ";
                endcase
            end
            // ---------------------------------------- 3: 按键提示
            4'd3: begin
                case (col)
                6'd0: ch="K"; 6'd1: ch="E"; 6'd2: ch="Y"; 6'd3: ch=" ";
                6'd4: ch="="; 6'd5: ch=" "; 6'd6: ch="N"; 6'd7: ch="E";
                6'd8: ch="X"; 6'd9: ch="T"; 6'd10: ch=" "; 6'd11: ch="P";
                6'd12: ch="A"; 6'd13: ch="T"; 6'd14: ch="T"; 6'd15: ch="E";
                6'd16: ch="R"; 6'd17: ch="N"; 6'd18: ch=" ";
                6'd19: ch="A"; 6'd20: ch="U"; 6'd21: ch="T"; 6'd22: ch="O";
                default: ch=" ";
                endcase
            end
            // ---------------------------------------- 4..11: 5 个点的坐标
            default: begin
                d = (line >= 4'd4 && line <= 4'd11) ? line - 4'd4 : 4'd0;
                // 每 2 行显示一个点：偶数行 X，奇数行 Y
                if (col == 6'd0) ch = (d[0] == 1'b0) ? "X" : "Y";
                else if (col == 6'd1) ch = "0" + (d >> 1);
                else if (col == 6'd2) ch = "=";
                else if (col >= 6'd3 && col <= 6'd6) begin
                    // 4 位十进制
                    case (col)
                    6'd3: ch = "0" + ((d[0]==1'b0 ? tch_x0 : tch_y0) / 16'd1000) % 16'd10;
                    6'd4: ch = "0" + ((d[0]==1'b0 ? tch_x0 : tch_y0) / 16'd100)  % 16'd10;
                    6'd5: ch = "0" + ((d[0]==1'b0 ? tch_x0 : tch_y0) / 16'd10)   % 16'd10;
                    default: ch = "0" + ((d[0]==1'b0 ? tch_x0 : tch_y0))         % 16'd10;
                    endcase
                end
                else ch = " ";
            end
            endcase
            char_at = ch;
        end
    endfunction

    // ============================================================== 叠加文本
    wire text_area = (pix_y < 12'd96);            // 屏幕上方 12 行 x 8px
    wire [3:0]  tline = pix_y[6:3];               // 0..7（只需要前 5 行）
    wire [11:0] ty    = pix_y - {tline, 3'b000};  // 字内行 0..7
    wire [5:0]  tcol  = pix_x / 12'd6;            // 第几个字符（0..170，比较时截断）
    wire [11:0] tx    = pix_x % 12'd6;            // 字内列 0..5

    // ========================================================= 触摸十字准星
    function cross_hit;
        input [15:0] cx, cy;
        input [15:0] tx0, ty0;
        input        en;
        begin
            cross_hit = ((en && (cy >= ty0 - 16'd24) && (cy <= ty0 + 16'd24) &&
                              (cx >= tx0 - 16'd2)  && (cx <= tx0 + 16'd2))
                      || (en && (cx >= tx0 - 16'd24) && (cx <= tx0 + 16'd24) &&
                              (cy >= ty0 - 16'd2)  && (cy <= ty0 + 16'd2)));
        end
    endfunction

    wire cross0 = cross_hit(pix_x, pix_y, tch_x0, tch_y0, tch_valid && (tch_num > 3'd0));
    wire cross1 = cross_hit(pix_x, pix_y, tch_x1, tch_y1, tch_valid && (tch_num > 3'd1));
    wire cross2 = cross_hit(pix_x, pix_y, tch_x2, tch_y2, tch_valid && (tch_num > 3'd2));
    wire cross3 = cross_hit(pix_x, pix_y, tch_x3, tch_y3, tch_valid && (tch_num > 3'd3));
    wire cross4 = cross_hit(pix_x, pix_y, tch_x4, tch_y4, tch_valid && (tch_num > 3'd4));

    // ======================================================== 10x10 触控响应格
    wire [11:0] gcx = pix_x / 12'd102;
    wire [11:0] gcy = pix_y / 12'd60;
    wire grid_line = (pix_x % 12'd102 < 12'd2) || (pix_y % 12'd60 < 12'd2);
    wire cell0 = tch_valid && (tch_num > 3'd0) &&
                 (gcx == (tch_x0 / 12'd102)) && (gcy == (tch_y0 / 12'd60));
    wire cell1 = tch_valid && (tch_num > 3'd1) &&
                 (gcx == (tch_x1 / 12'd102)) && (gcy == (tch_y1 / 12'd60));
    wire cell2 = tch_valid && (tch_num > 3'd2) &&
                 (gcx == (tch_x2 / 12'd102)) && (gcy == (tch_y2 / 12'd60));
    wire cell3 = tch_valid && (tch_num > 3'd3) &&
                 (gcx == (tch_x3 / 12'd102)) && (gcy == (tch_y3 / 12'd60));
    wire cell4 = tch_valid && (tch_num > 3'd4) &&
                 (gcx == (tch_x4 / 12'd102)) && (gcy == (tch_y4 / 12'd60));

    // =============================================================== 运动块位置
    // 白块沿矩形跑圈：总周长 2*(944+480) = 2848，每帧走 8 像素，约 356 帧一圈
    wire [11:0] per = anim[9:0] * 12'd8 % 12'd2848;
    wire [11:0] bx, by;
    assign bx = (per < 12'd944)  ? (12'd40 + per) :
                (per < 12'd1424) ? 12'd984 :
                (per < 12'd2368) ? (12'd984 - (per - 12'd1424)) : 12'd40;
    assign by = (per < 12'd944)  ? 12'd40 :
                (per < 12'd1424) ? (12'd40 + (per - 12'd944)) :
                (per < 12'd2368) ? 12'd520 : (12'd520 - (per - 12'd2368));
    wire ring_hit = (pix_x >= bx && pix_x < bx + 12'd32) &&
                    (pix_y >= by && pix_y < by + 12'd32);

    // ============================================================== 画面生成
    always @(*) begin
        col     = C_BLACK;
        in_text = 1'b0;

        case (pattern)
        // ---------------------------------------------------------- 0 彩条
        4'd0: begin
            if      (pix_x < cwidth)        col = C_WHITE;
            else if (pix_x < cwidth * 2)    col = C_BLACK;
            else if (pix_x < cwidth * 3)    col = C_RED;
            else if (pix_x < cwidth * 4)    col = C_GREEN;
            else                            col = C_BLUE;
        end
        // ---------------------------------------------------- 1 单色轮换
        4'd1: begin
            case (blink)
            3'd0: col = C_RED;
            3'd1: col = C_GREEN;
            3'd2: col = C_BLUE;
            3'd3: col = C_WHITE;
            3'd4: col = C_BLACK;
            default: col = C_GRAY;
            endcase
        end
        // ---------------------------------------------------------- 2 灰阶
        4'd2: col = {pix_x[9:2], pix_x[9:2], pix_x[9:2]};
        // ------------------------------------------------------ 3 像素棋盘
        4'd3: col = (pix_x[0] ^ pix_y[0]) ? C_WHITE : C_BLACK;
        // ------------------------------------------------------ 4 边框+网格
        4'd4: begin
            if (pix_x < 12'd2 || pix_x >= H_DISP - 12'd2 ||
                pix_y < 12'd2 || pix_y >= V_DISP - 12'd2)
                col = C_WHITE;                                              // 外框
            else if ((pix_x % 12'd128 == 12'd0) || (pix_y % 12'd64 == 12'd0))
                col = C_DARK;                                               // 网格
            else if ((pix_x >= 12'd509 && pix_x <= 12'd514) ||
                     (pix_y >= 12'd297 && pix_y <= 12'd302))
                col = C_YELLOW;                                             // 中心十字
            else col = C_BLACK;
        end
        // -------------------------------------------------------- 5 运动块
        4'd5: begin
            if ((pix_x % 12'd128 < 12'd4) || (pix_y % 12'd64 < 12'd4)) col = C_DARK;
            if (ring_hit) col = C_WHITE;
        end
        // ---------------------------------------------------------- 6 纯黑
        4'd6: col = C_BLACK;
        // ---------------------------------------------------------- 7 纯白
        4'd7: col = C_WHITE;
        // ---------------------------------------------------- 8 触控可视化
        4'd8: begin
            col = C_BLACK;
            if ((pix_x % 12'd100 < 12'd1) || (pix_y % 12'd100 < 12'd1)) col = C_DARK;
            if (pix_y >= V_DISP - 12'd120) col = C_BG;
            if (pix_y == V_DISP - 12'd120) col = C_CYAN;
            if (cross0) col = C_RED;
            if (cross1) col = C_GREEN;
            if (cross2) col = C_BLUE;
            if (cross3) col = C_YELLOW;
            if (cross4) col = C_MAG;
            in_text = 1'b1;
        end
        // ---------------------------------------------------- 9 触控响应格
        default: begin
            col = C_BLACK;
            if (grid_line) col = 24'h404040;
            if (cell0) col = C_GREEN;
            if (cell1) col = C_ORANGE;
            if (cell2) col = C_CYAN;
            if (cell3) col = C_YELLOW;
            if (cell4) col = C_MAG;
            in_text = 1'b1;
        end
        endcase

        // ------------------------------------------------------ 文本叠加
        if (in_text && pix_x < 12'd720 && ty < 12'd7 && tx < 12'd5) begin
            if (font_row(char_at(tline, tcol), ty[2:0])[4 - tx[2:0]]) col = C_WHITE;
        end
    end

    // ============================================================ 时序/输出
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            pattern     <= 4'd0;
            auto_cnt    <= 8'd0;
            pat_pend    <= 1'b0;
            anim        <= 10'd0;
            blink       <= 3'd0;
            frame_tick  <= 1'b0;
            pixel_data  <= C_BLACK;
        end
        else begin
            frame_tick <= 1'b0;
            // ★ pat_adv 是单周期脉冲，而画面切换只在帧边界（frame_st，每帧一次）进行：
            //   直接把脉冲拿去和 frame_st 对齐，命中的概率只有 1/853440 拍 —— 按键
            //   实际上几乎永远不会切画面。所以这里把脉冲**锁存成请求**，到帧边界消费。
            if (pat_adv) pat_pend <= 1'b1;
            if (frame_st) begin
                frame_tick <= 1'b1;
                anim  <= anim + 10'd1;
                blink <= blink + 3'd1;
                if (pat_pend || auto_cnt == 8'd255) begin
                    pattern  <= (pattern == 4'd9) ? 4'd0 : pattern + 4'd1;
                    auto_cnt <= 8'd0;
                    pat_pend <= 1'b0;
                end
                else auto_cnt <= auto_cnt + 8'd1;
            end
            if (de) pixel_data <= col;
            else    pixel_data <= C_BLACK;      // 消隐期输出黑，避免屏幕上出现彩边
        end
    end

endmodule
