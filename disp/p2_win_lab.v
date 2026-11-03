//=============================================================================
// disp/p2_win_lab.v —— P2 底栏的时基标签（v87：AUTO / 固定 + 真实窗宽）
//
// 职责：每帧把"当前时基模式 + 该档位的真实窗宽"写进 P2 lab 平面的第 36 格行
//   第 54..63 格（10 格，x 864..1023，右沿贴波形框右沿；v86 是 55..62 八格）。
//
// 文案（为什么是 "AUTO" 而不是 "自动"）：
//   字库 tools/cn_glyphs.py 的 132 个汉字里**没有"动"（U+52A8）**，而字模
//   与字库索引是 tools/make_cn_glyphs.py 生成的、不由本工程的 RTL 决定。
//   为了不改字库（改它会让 132 个汉字码整体位移，且超出本次允许改动的文件
//   范围），AUTO 档写成 ASCII 的 "AUTO"，固定档仍用汉字 "固定"（两字都有
//   字模）。语义清楚、且与本页其它 ASCII 字段（OFS-S / GAIN-C 等）一致。
//
// 三档窗宽 = SWEEP_LEN × 分频比 / 50 MHz（见 disp/wave_trace.v 的 gear 注释）：
//   gear=0 : 944 × 128 / 50e6 = 2.4166 ms  -> "2.4MS"
//   gear=1 : 944 ×  16 / 50e6 = 302.08 us  -> "300US"
//   gear=2 : 944 ×   2 / 50e6 =  37.76 us  -> "38US"（末格补空格）
//
// 布局（10 格，v87 上板复查后挪回**左下角**）：
//   AUTO  : [6]A [7]U [8]T [9]O [10]空 [11..15]窗宽
//   固定  : [6]空 [7]空 [8]固 [9]定 [10]空 [11..15]窗宽
//   窗宽永远落在 11..15（左对齐固定起点，长度变化只向右长，不挤压），模式字
//   占左 4 格 —— 两种模式共用一块 10 格的反色底（disp_engine 的 p2w_chip 覆盖
//   6..15）。位置落在触摸条 enc_top_disp.v 的 P2W_HIT（x 88..360、y 566..600）
//   里，用户点得到、也看得见；v87 之前误放在 54..63（屏幕最右沿压网格上）。
//
// 为什么是"数值在 RTL、文字在 gen_text_ram.py"：
//   静态版面（tools/gen_text_ram.py 的 P2_LAB）在同样 10 格里预置
//   "AUTO 300US"，所以上电第一帧之前也是对的；本模块每帧把它改成当前值。
//   改文案要同时改这两处（cell_at 与 P2_LAB 那一行）。
//
// 写口：disp_engine 里 p2_lab_ram 的写口（p2b_we/p2b_waddr/p2b_wdata）由本
//   模块独占，不需要仲裁。
//=============================================================================
`default_nettype none

module p2_win_lab (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,        // vf_start：帧起始单拍
    input  wire [1:0]  mode,         // 0 = AUTO，1/2/3 = 固定 gear0/1/2
    input  wire [1:0]  gear,         // 实际档位 0 = 2.4 ms / 1 = 300 µs / 2 = 38 µs

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
    localparam [7:0] CH_A  = 8'd18;
    localparam [7:0] CH_M  = 8'd30;
    localparam [7:0] CH_O  = 8'd32;
    localparam [7:0] CH_S  = 8'd36;
    localparam [7:0] CH_T  = 8'd37;
    localparam [7:0] CH_U  = 8'd38;
    localparam [7:0] CH_GU = 8'd147;    // 固
    localparam [7:0] CH_DI = 8'd118;    // 定

    localparam [5:0] LAB_ROW = 6'd36;
    localparam [5:0] LAB_C0  = 6'd6;
    localparam [3:0] LAB_N   = 4'd9;    // 10 格：k = 0..9

    // 模式字（左 4 格）
    function [7:0] mode_ch;
        input [1:0] m;
        input [1:0] k;
        begin
            if (m == 2'd0) begin            // "AUTO"
                case (k)
                    2'd0: mode_ch = CH_A;
                    2'd1: mode_ch = CH_U;
                    2'd2: mode_ch = CH_T;
                    default: mode_ch = CH_O;
                endcase
            end else begin                  // "  固定"
                case (k)
                    2'd0: mode_ch = CH_SP;
                    2'd1: mode_ch = CH_SP;
                    2'd2: mode_ch = CH_GU;
                    default: mode_ch = CH_DI;
                endcase
            end
        end
    endfunction

    // 窗宽 5 格（k = 0..4）
    function [7:0] win_ch;
        input [1:0] g;
        input [2:0] k;
        begin
            case (g)
                2'd0: begin   // "2.4MS"
                    case (k)
                        3'd0: win_ch = CH_D0 + 8'd2;
                        3'd1: win_ch = CH_DT;
                        3'd2: win_ch = CH_D0 + 8'd4;
                        3'd3: win_ch = CH_M;
                        default: win_ch = CH_S;
                    endcase
                end
                2'd1: begin   // "302US"
                    // ★ 真实窗宽 = 944*16/50e6 = 302.08 µs。v86 一直写 "300US"，
                    //   是当年按"档位名字"取的整数；v87 改成真实值（差 2 µs 会被
                    //   任务书的 ±1 µs 断言判失败，而且用户已经在追问口径）。
                    case (k)
                        3'd0: win_ch = CH_D0 + 8'd3;
                        3'd1: win_ch = CH_D0;
                        3'd2: win_ch = CH_D0 + 8'd2;
                        3'd3: win_ch = CH_U;
                        default: win_ch = CH_S;
                    endcase
                end
                default: begin // "38US "
                    case (k)
                        3'd0: win_ch = CH_D0 + 8'd3;
                        3'd1: win_ch = CH_D0 + 8'd8;
                        3'd2: win_ch = CH_U;
                        3'd3: win_ch = CH_S;
                        default: win_ch = CH_SP;
                    endcase
                end
            endcase
        end
    endfunction

    function [7:0] cell_at;
        input [3:0] k;
        begin
            if (k < 4'd4)      cell_at = mode_ch(mode, k[1:0]);
            else if (k == 4'd4) cell_at = CH_SP;
            else                cell_at = win_ch(gear, k[2:0] - 3'd5);
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
