//=============================================================================
// undo_lab.v -- 面板"回到上一次值"按钮的标签（规范 §6.5 的「↩ 回到 ×N」）
//
// 职责：每帧把 ui_panel 记忆的"上一次值"（倍频 + 分频）写进 P1 的 lab 平面第 34
//       格行的 46..54 格，也就是 BACK 按钮的标签带（按钮 x 720..879 = 格列 45..54，
//       面板里 CANCEL/APPLY 的标签也都是"按钮左沿 + 1 格"，所以这里从 46 起）。
//
// 屏上长这样（avail=1，倍频 = 8 / 64 / 256，分频 = ÷2）：
//       46   47   48   49   50   51   52   53   54
//       ↩    回   到   ×    8    (空) (空) ÷    2
//       ↩    回   到   ×    6    4    (空) ÷    2
//       ↩    回   到   ×    2    5    6    ÷    8
// 倍频数字**左紧贴 ×**（不是右对齐到 52）：1 位数时值只占第 50 格，右对齐会在
// "×"和数字之间留两个空格，看着像渲染坏了。前导零一律不写。
// ★ v44（㊶）：面板现在**也会改分频**（八档步进 / 滑条 / 数字键盘），所以标签把
//   分频也写出来（"÷M"，M = 分频码 + 1）。被撤销的那笔事务里倍频与分频是一起写
//   的（ui_edit 的 pack_cmd 同时写 0x0101/0x0102），两者一起回到上一次值。
// avail=0（还没有"上一次值"）时只写「回到」，而且位置与 text_ram.v 的静态
// 版面**同一个格**（46/47），这样上电第一帧与之后的内容不会左右跳一格；
// BACK 按钮本身也会变灰（disp_engine 的 bck_* 配色看 pnl_undo_avail）。
//
// 为什么要单独一个模块：上一次值是运行期才知道的（每笔事务成功后才更新），
// 而静态版面在 text_ram.v 的 initial 里一次成型、改不了。P1 的 lab 平面又是
// **唯一**没有被运行期写者占用的那一块（p2/p5/p7/p8 的 lab 分别被
// p2_badge / p5_view / p7_view / band_view 占着），所以这里直接接它的写口，
// 不需要任何仲裁——只在 disp_engine 里把 p1_lab_ram 的 we/waddr/wdata 从
// 常量 0 换成这个模块的输出。
//
// 时序：start 是帧起始单拍（disp_engine 的 vf_start，与 p2_badge/p5_view 同一个
// 信号）。9 个格子 9 拍写完，一帧 1024x600 像素，写窗口绰绰有余。
//=============================================================================
`default_nettype none

module undo_lab (
    input  wire        clk,
    input  wire        rst_n,          // 异步复位、低有效（与 p2_badge/p5_view 一致）
    input  wire        start,          // vf_start：帧起始单拍
    input  wire        avail,          // 有"上一次值"（ui_panel 的 pnl_undo_avail）
    input  wire [9:0]  inter,          // 上一次值的倍频码（0 表示 256）
    input  wire [2:0]  div,            // v44（㊶）上一次值的分频码 0..7（÷1..÷8）

    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    // 字符码：与 tools/gen_font_rom.py 的 ASCII_CHARS / tools/cn_glyphs.py 的顺序一致
    //   ASCII: ' '=0, '0'=8, '×'=45, '↩'=47（v24 追加在 ASCII 段末尾）
    //   汉字 : 码 = ASCII_COUNT(48) + cn_glyphs.CHARS 的下标 -> '回'=135, '到'=136
    localparam [7:0] CH_SP   = 8'd0;
    localparam [7:0] CH_ZERO = 8'd8;
    localparam [7:0] CH_MUL  = 8'd45;
    localparam [7:0] CH_DIV  = 8'd46;     // '÷'（v44/㊶ 起标签里要写分频）
    localparam [7:0] CH_RET  = 8'd47;
    localparam [7:0] CH_HUI  = 8'd135;
    localparam [7:0] CH_DAO  = 8'd136;

    localparam [5:0]  LAB_ROW = 6'd34;    // 按钮标签所在格行（gen_text_ram.py 的 P1_LAB）
    localparam [5:0]  LAB_C0  = 6'd46;    // 标签带第一格
    localparam [3:0]  LAB_N   = 4'd8;     // 写 9 格（k = 0..8）

    // ---------------------------------------------------------------------
    // 1. 倍频码 -> 三位十进制（double dabble）
    //    编码 0 是 ×256（见 ui_edit.v），其余就是倍频本身。
    // ---------------------------------------------------------------------
    wire [9:0] mag = (inter == 10'd0) ? 10'd256 : inter;

    reg [11:0] bcd;                        // {百[3:0], 十[3:0], 个[3:0]}
    integer    i;
    always @* begin
        bcd = 12'd0;
        for (i = 9; i >= 0; i = i - 1) begin
            if (bcd[11:8] >= 4'd5) bcd[11:8] = bcd[11:8] + 4'd3;
            if (bcd[7:4]  >= 4'd5) bcd[7:4]  = bcd[7:4]  + 4'd3;
            if (bcd[3:0]  >= 4'd5) bcd[3:0]  = bcd[3:0]  + 4'd3;
            bcd = {bcd[10:0], mag[i]};
        end
    end

    wire [3:0] d_h = bcd[11:8];
    wire [3:0] d_t = bcd[7:4];
    wire [3:0] d_o = bcd[3:0];
    wire       show_h = (d_h != 4'd0);              // 前导零抑制
    wire       show_t = show_h || (d_t != 4'd0);

    // ---------------------------------------------------------------------
    // 2. 每格写什么
    // ---------------------------------------------------------------------
    function [7:0] cell_at;
        input [3:0] k;
        begin
            if (!avail) begin
                // 没有"上一次值"：只写「回到」，位置与静态版面一致（46/47）
                cell_at = (k == 4'd0) ? CH_HUI :
                          (k == 4'd1) ? CH_DAO : CH_SP;
            end else begin
                // 数字左紧贴 ×：三位 -> 50/51/52；两位 -> 50/51；一位 -> 50
                // v44（㊶）：末尾再写 "÷" + 分频（53/54）
                case (k)
                    4'd0:    cell_at = CH_RET;
                    4'd1:    cell_at = CH_HUI;
                    4'd2:    cell_at = CH_DAO;
                    4'd3:    cell_at = CH_MUL;
                    4'd4:    cell_at = show_h ? (CH_ZERO + {4'd0, d_h}) :
                                       show_t ? (CH_ZERO + {4'd0, d_t}) :
                                                (CH_ZERO + {4'd0, d_o});
                    4'd5:    cell_at = show_h ? (CH_ZERO + {4'd0, d_t}) :
                                       show_t ? (CH_ZERO + {4'd0, d_o}) : CH_SP;
                    4'd6:    cell_at = show_h ? (CH_ZERO + {4'd0, d_o}) : CH_SP;
                    4'd7:    cell_at = CH_DIV;
                    4'd8:    cell_at = CH_ZERO + {5'd0, div} + 8'd1;   // 分频码 0..7 -> ÷1..÷8
                    default: cell_at = CH_SP;
                endcase
            end
        end
    endfunction

    // ---------------------------------------------------------------------
    // 3. 写序列：帧起始开始，9 拍写完，再给一拍 done
    // ---------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;

    reg [1:0] st;
    reg [3:0] idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            idx   <= 4'd0;
            we    <= 1'b0;
            waddr <= 12'd0;
            wdata <= 8'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            we   <= 1'b0;
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                            st   <= S_WR;
                            idx  <= 4'd0;
                            busy <= 1'b1;
                        end
                S_WR: begin
                            we    <= 1'b1;
                            waddr <= {LAB_ROW, LAB_C0 + {2'd0, idx}};
                            wdata <= cell_at(idx);
                            if (idx == LAB_N) st <= S_DONE;
                            else              idx <= idx + 4'd1;
                        end
                default: begin                 // S_DONE
                            st   <= S_IDLE;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
            endcase
        end
    end

endmodule

`default_nettype wire
