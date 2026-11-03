//=============================================================================
// p7_gate_lab.v —— P7 误差曲线的两条**闸线百分比标签**（v77 新增）
//
// 为什么有本模块：
//   上板实测（v76）P7 的误差曲线有数据，但纵轴没有刻度与量纲；右栏那个
//   "幅值 26.4%" 与曲线如何对照，屏上没有任何提示。26.4% 的定义在
//   disp/p7_view.v:263-293：0% = 幅值到达**下限**门限 amp_low_sq，
//   100% = 到达**上限**门限 amp_high_sq，中间按 (hi-lo) 线性插值。
//   所以"两条纵轴参考刻度"就是这两条门限对应的**行**：
//       行 = amp_XX_sq[30:22]（曲线本身也是 amp_sq[30:15] >> 7 得到的行号，
//       见 p7_view.v 的 dump 相 lo_y/hi_y），屏上 y = P7_CVY0 + 行。
//   曲线会画在闸线之上（数据优先），所以闸线只是"标尺"。
//
// 为什么标签要每帧重写：门限寄存器（0x0520/0x0524）随便可以改，行号跟着变，
//   静态版面（tools/gen_text_ram.py 的 P7_LAB）写不了会动的坐标。
//   这也解释了为什么本模块只写 2 个短标签（"0%"/"100%"），而不是一套刻度。
//
// 为什么标签放在格列 7..10：曲线区左沿是 x=112（格列 7），格列 6 = x 96..111
//   在卡片内、曲线区之外，已有静态的 "0"（零线标签，P7_LAB 的 (17,6)）放在那。
//   本模块从格列 7 起写，既不盖掉那个 "0"，也与 p7_view 的数值列（11..16 / 52..57）
//   不重叠。标签只压在曲线的极左 4 格（≈64 px），读图时当作标尺。
//
// 写口：p7_lab_ram 只有一个写口，写者原本只有 p7_view（字段值，格列 52..57
//   与 11..16）。本模块用**更高优先级**并且把 hold 送进 p7_view，
//   两边的地址本来不重叠，hold 只是保证同一拍不会丢格。
//=============================================================================
`default_nettype none

module p7_gate_lab (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,        // vf_start：帧起始单拍
    input  wire [7:0]  lo_row,       // 0% 闸线的行号（0..239）
    input  wire [7:0]  hi_row,       // 100% 闸线的行号（0..239）
    input  wire        hold,         // p7_view 正在写，本拍不推进

    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    // 字符码：与 tools/gen_text_ram.py 的 ASCII_CHARS 顺序一致
    localparam [7:0] CH_D0  = 8'd8;      // '0'，数字 d 的码是 8+d
    localparam [7:0] CH_PCT = 8'd44;     // '%'
    localparam [7:0] CH_ONE = 8'd9;      // '1'

    // 行号 → 格行：屏上 y = P7_CVY0(160) + row，160 是 16 的整倍数，
    // 所以格行 = 10 + (row >> 4)，与 P7_LAB 里零线 (17,6) 的算法一致。
    localparam [5:0] LAB_COL = 6'd7;

    reg [1:0] st;
    reg [3:0] idx;

    // idx：0..1 = "0%"（两格），2..5 = "100%"（四格）
    wire [5:0] lab_row = (idx < 4'd2) ? (6'd10 + {2'd0, lo_row[7:4]})
                                      : (6'd10 + {2'd0, hi_row[7:4]});
    wire [5:0] lab_col = (idx == 4'd0) ? (LAB_COL)      :
                         (idx == 4'd1) ? (LAB_COL + 6'd1) :
                         (idx == 4'd2) ? (LAB_COL)      :
                         (idx == 4'd3) ? (LAB_COL + 6'd1) :
                         (idx == 4'd4) ? (LAB_COL + 6'd2) : (LAB_COL + 6'd3);

    function [7:0] cell_of;
        input [3:0] k;
        begin
            case (k)
                4'd0: cell_of = CH_D0;                 // '0'
                4'd1: cell_of = CH_PCT;                // '%'
                4'd2: cell_of = CH_ONE;                // '1'
                4'd3: cell_of = CH_D0;
                4'd4: cell_of = CH_D0;
                default: cell_of = CH_PCT;             // '100%'
            endcase
        end
    endfunction

    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;

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
                S_WR: if (!hold) begin
                            we    <= 1'b1;
                            waddr <= {lab_row, lab_col};
                            wdata <= cell_of(idx);
                            if (idx == 4'd5) st <= S_DONE;
                            else             idx <= idx + 4'd1;
                        end
                default: begin
                            st   <= S_IDLE;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
            endcase
        end
    end

endmodule

`default_nettype wire
