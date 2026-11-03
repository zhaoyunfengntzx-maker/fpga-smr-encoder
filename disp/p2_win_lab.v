//=============================================================================
// p2_win_lab.v —— P2 底栏的"窗口 XMS/XUS"数值（v75 的 A 项）
//
// 职责：每帧把当前时基档位的**真实窗宽**写进 P2 lab 平面的第 36 格行第 58..62 格。
//   ★ v77（上板：宽度标签字号偏小、贴左下有压线感）：整条标签从格列 6 右移到 55
//     （x 880..1007，右沿离波形框右沿 16 px，与原来贴左沿的 16 px 内缩对称），并在
//     disp_engine 里给它垫一块强调色底。字库只有 11x14 一档（另一档是数值层的
//     30x48，一行放不下），字号改不了，能改的是位置与对比度：白字压深蓝底比
//     深灰字压浅蓝页底明显一档，同时不再贴左下、不压框底线。
//       静态版面（tools/gen_text_ram.py 的 P2_LAB）在那 5 格写的是默认档
//       "300US"，所以上电第一帧之前也是对的；本模块只是把它换成当前档位。
//
// 三档窗宽 = SWEEP_LEN x 分频比 / 50 MHz（见 disp/wave_trace.v 的 gear 注释）：
//   gear=0 : 944 x 128 / 50e6 = 2.4166 ms  -> "2.4MS"
//   gear=1 : 944 x  16 / 50e6 = 302.08 us  -> "300US"
//   gear=2 : 944 x   2 / 50e6 =  37.76 us  -> "38US"（末格补空格，保持左对齐）
// 旧口径"等效采样 100US"是 v74 及以前的固定分频比，三档可切之后它必然错，
// 所以 A 项把这条底栏改成真实窗宽。
//
// 为什么是"数值在 RTL、文字在 gen_text_ram.py"：
//   "窗口"两个字是**静态标签**，放在 tools/gen_text_ram.py 的 P2_LAB 里；
//   而这 5 格是**运行期测量值**（随档位变），静态版面改不了，只能每帧重写。
//   这是本项目既有的分工（见 disp/undo_lab.v 的头注释：静态版面进 initial，
//   运行期值走运行期写者）。字符串本身仍集中在本文件的 cell_at 里，改文案
//   只需改这一处 + gen_text_ram.py 的默认档那一行，二者必须同时改。
//
// 写口：disp_engine 里 p2_lab_ram 的写口（p2b_we/p2b_waddr/p2b_wdata）自 v58
//   删掉 p2_badge 之后一直是空的（we 恒 0），这里直接接管，不需要仲裁。
//=============================================================================
`default_nettype none

module p2_win_lab (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,        // vf_start：帧起始单拍
    input  wire [1:0]  gear,         // 0 = 2.4 ms / 1 = 300 µs / 2 = 38 µs

    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    // 字符码：与 tools/gen_text_ram.py 的 ASCII_CHARS 顺序一致
    localparam [7:0] CH_SP = 8'd0;
    localparam [7:0] CH_DT = 8'd1;      // '.'
    localparam [7:0] CH_D0 = 8'd8;      // '0'，数字 d 的码是 8+d
    localparam [7:0] CH_M  = 8'd30;
    localparam [7:0] CH_S  = 8'd36;
    localparam [7:0] CH_U  = 8'd38;

    localparam [5:0] LAB_ROW = 6'd36;
    localparam [5:0] LAB_C0  = 6'd58;
    localparam [3:0] LAB_N   = 4'd4;    // 5 格：k = 0..4

    function [7:0] cell_at;
        input [3:0] k;
        begin
            case (gear)
                2'd0: begin   // "2.4MS"
                    case (k)
                        4'd0: cell_at = CH_D0 + 8'd2;   // '2'
                        4'd1: cell_at = CH_DT;
                        4'd2: cell_at = CH_D0 + 8'd4;   // '4'
                        4'd3: cell_at = CH_M;
                        default: cell_at = CH_S;
                    endcase
                end
                2'd1: begin   // "300US"
                    case (k)
                        4'd0: cell_at = CH_D0 + 8'd3;
                        4'd1: cell_at = CH_D0;
                        4'd2: cell_at = CH_D0;
                        4'd3: cell_at = CH_U;
                        default: cell_at = CH_S;
                    endcase
                end
                default: begin // "38US "（第 5 格留空格，左对齐）
                    case (k)
                        4'd0: cell_at = CH_D0 + 8'd3;
                        4'd1: cell_at = CH_D0 + 8'd8;
                        4'd2: cell_at = CH_U;
                        4'd3: cell_at = CH_S;
                        default: cell_at = CH_SP;
                    endcase
                end
            endcase
        end
    endfunction

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
