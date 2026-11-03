// -----------------------------------------------------------------------------
//  disp/pos_hex.v —— v48（㊺）A2：P1 卡 4 的次级信息「pos_full 十六进制」写口
//
//  为什么需要它：
//    spec §4.5（docs/13_display_ui_requirements.md:188）把卡 4 的次级信息定为
//    `pos_full 0x003A1B2C` —— 那是一个**会变的** 32 位值，不能写进静态版面
//    （tools/gen_text_ram.py 只能铺首帧之前的占位）。静态版面只放标签 `POS 0X`
//    （P1_LAB 的 (35,6)，6 格），本模块每帧把 8 位十六进制写到它右边的 8 格。
//
//  为什么走**标签层**（lab 平面）而不是数值层：
//    数值层的格是 32x64 px，只落在「格行 2 / 格行 7」两条带上（大号 48 px 数字），
//    卡 4 的次级行（y 544..575）不在那两条带里。标签层是 16x16 文字格网，
//    行 35 = y 560..575、列 12..19 = x 192..319 —— 正好在卡 4（x 96..383）内部。
//
//  写口仲裁（与 undo_lab / stat_chip 共用一个 P1 标签层写口）：
//    行号互不冲突（本模块 35，undo_lab 34，stat_chip 15/36），所以只需要优先权：
//    面板标签 > 状态条 > 本模块。`hold` 由 disp_engine 给（前两个写者正在写的那拍），
//    本模块在 hold 拍**不写也不推进**（与 stat_chip 同一套语义；原因见 stat_chip.v 的
//    第 3 节：we 必须是组合输出，否则"发出去了没人收"会每帧丢一格）。
//
//  位序：从最高位 nibble 开始写（idx=0 → bit[31:28]），屏上读起来才是正常的十六进制。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module pos_hex (
    input  wire        clk,
    input  wire        rst_n,        // 异步复位、低有效
    input  wire        start,        // vf_start：帧起始单拍（与 undo_lab/stat_chip 同一个）
    input  wire [31:0] pos_full,     // 抽头 pos_full 的低 32 位（disp_engine 里已寄存的 q_pos_full）
    input  wire        hold,         // 写口被占（面板标签 / 状态条正在写）→ 本拍不写、不推进

    output wire        we,
    output wire [11:0] waddr,        // {格行[5:0], 格列[5:0]}（标签层 64x38 格网）
    output wire [7:0]  wdata,
    output reg         busy,         // 写序列进行中（探针）
    output reg         done          // 写序列结束单拍（探针）
);

    // ★ v59：角度卡挪到第 2 行右列（x 576），标签 "POS 0X" 在格行 24 、格列 36..41，
    //   所以十六进制数值从格列 43 开始（x 688）。
    localparam [5:0] ROW    = 6'd24;   // 角度卡的次级信息行（y 384..399）
    localparam [5:0] COL    = 6'd43;   // 静态标签 "POS 0X" 占 36..41 ⇒ 数值从 43 开始
    localparam [2:0] N_CELL = 3'd7;    // 8 格（idx = 0..7）

    // 十六进制字符码：字符集是 " .-+/:=^0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ…"
    //   ⇒ '0'..'9' = 8..17、'A'..'F' = 18..23
    function [7:0] hex_ch;
        input [3:0] d;
        begin
            hex_ch = (d <= 4'd9) ? (8'd8 + {4'd0, d}) : (8'd18 + {4'd0, d} - 8'd10);
        end
    endfunction

    reg  [2:0] idx;
    reg  [3:0] nib;

    always @* begin
        case (idx)
            3'd0:    nib = pos_full[31:28];
            3'd1:    nib = pos_full[27:24];
            3'd2:    nib = pos_full[23:20];
            3'd3:    nib = pos_full[19:16];
            3'd4:    nib = pos_full[15:12];
            3'd5:    nib = pos_full[11:8];
            3'd6:    nib = pos_full[7:4];
            default: nib = pos_full[3:0];
        endcase
    end

    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;
    reg [1:0] st;

    assign we    = (st == S_WR) && !hold;
    assign waddr = {ROW, COL + {3'd0, idx}};
    assign wdata = hex_ch(nib);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            idx  <= 3'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                            st   <= S_WR;
                            idx  <= 3'd0;
                            busy <= 1'b1;
                        end
                S_WR: if (!hold) begin
                            if (idx == N_CELL) st <= S_DONE;
                            else               idx <= idx + 3'd1;
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
