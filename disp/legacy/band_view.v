//=============================================================================
// disp/band_view.v -- P8 底栏三个小数字的运行期格式化器
//-----------------------------------------------------------------------------
// 为什么需要单独一个：P8 底栏（中断电平 / 翻转 / 复位次数）按 spec 的排版是
// 16 px 小字，只能落在**文字层**（64x38 格、格 16x16）。而 disp/touch_view.v
// 写的是**数值层**（32x10 格、格 32x64）—— 数值层第 9 格行就是 y576..639，
// 已经越过 600 px 屏高，写下去看不见。所以这三个数只能回到文字层用 16x16 写。
//
// 三个字段的位置与 tools/gen_text_ram.py 里 P8_LAB 底栏的空列是**同一个契约**：
//     中断电平 @列 6（宽 1）、翻转 @列 13（宽 1）、复位次数 @列 22（宽 3）
// 全部在第 36 格行（y576..591，屏高 600 之内）。改列位置必须同时改那边的静态版面。
//     排版读出来是：中断电平 0 / 翻转 1 / 复位次数  0
//
// 数值都很小（0/1 与 0..15），所以**不做 double-dabble**：十进制拆分用一条
// 比较 + 一条减法就够（比搬 touch_view 那套 32 拍 BCD 移位链省 30 多拍和一堆寄存器）。
// 前导零抑制的规则与 touch_view/val_format 一致：**最低位永远显示**，
// 否则值为 0 时整个字段会变成空白（val_format 当年就栽在这一条上）。
//
// 接口与 disp/touch_view.v 同形（we/waddr/wdata/busy/done），
// 所以在 disp_engine 里可以和它共用同一个每帧启动脉冲。
//=============================================================================
`default_nettype none

module band_view (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    // 三个诊断量（来自 disp_engine 解包后的寄存器）
    input  wire        int_pin,       // 触摸 INT 引脚当前电平
    input  wire        toggle,        // tch_toggle：每完成一次有效触点就翻转
    input  wire [3:0]  rst_cnt,       // tch_rst_cnt[3:0]：GC 复位次数低 4 位
    // 写口：直接接 p8_lab_ram（文字层，8 bit 字符码、12 bit 地址）
    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    localparam [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_WR = 3'd2,
                     S_NEXT = 3'd3, S_END  = 3'd4;

    // 字符码：与 tools/gen_font_rom.py 的 CHARS 顺序一致（ASCII 段）
    //   " .-+/:=^0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ%×÷"  ->  ' '=0, '0'=8
    //   ★ v23：lab 码宽 7 -> 8 bit（字库扩容到 136 码），这三个符号追加在
    //     末尾（% = 44、× = 45、÷ = 46），没有挪动任何既有索引。
    localparam [7:0] CH_SP   = 8'd0;
    localparam [7:0] CH_ZERO = 8'd8;

    localparam [5:0] BAND_ROW = 6'd36;   // 底栏所在格行

    reg [2:0] state;
    reg [1:0] fld;      // 字段号 0..2
    reg [1:0] p;        // 字段内位置（0 = 最左）
    reg [1:0] wid;      // 当前字段宽度（1/1/3）
    reg [5:0] col;      // 当前字段起始列
    reg [3:0] val;      // 当前字段的数值

    // ---- 字段表：列位置与 tools/gen_text_ram.py 的 P8_LAB 底栏空列一一对应 ----
    //   列 11/18/27 = x 176/288/432（底栏整行从格列 6 = x96 起，不再压导航栏）
    always @* begin
        case (fld)
            2'd0:    begin wid = 2'd1; col = 6'd11; val = {3'b000, int_pin}; end
            2'd1:    begin wid = 2'd1; col = 6'd18; val = {3'b000, toggle};  end
            default: begin wid = 2'd3; col = 6'd27; val = rst_cnt;           end
        endcase
    end

    // ---- 十进制拆分（val <= 15，所以十位只有 0/1、百位恒 0）----
    wire       dec   = (val >= 4'd10);
    wire [3:0] d_one = dec ? (val - 4'd10) : val;   // 个位
    wire [3:0] d_ten = dec ? 4'd1 : 4'd0;           // 十位

    function [7:0] pow10(input [1:0] d);
        case (d)
            2'd1:    pow10 = 8'd10;
            2'd2:    pow10 = 8'd100;
            default: pow10 = 8'd1;
        endcase
    endfunction

    wire [1:0] cur_di  = (p < wid) ? (wid - 2'd1 - p) : 2'd0;   // 0 = 个位
    wire [3:0] cur_dig = (cur_di == 2'd0) ? d_one :
                         (cur_di == 2'd1) ? d_ten : 4'd0;
    wire       cur_vis = (cur_di == 2'd0) || ({4'b0, val} >= pow10(cur_di));
    wire [7:0] cur_ch  = cur_vis ? (CH_ZERO + {4'b0000, cur_dig}) : CH_SP;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            fld   <= 2'd0;
            p     <= 2'd0;
            we    <= 1'b0;
            waddr <= 12'd0;
            wdata <= 8'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            we   <= 1'b0;
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        fld   <= 2'd0;
                        p     <= 2'd0;
                        busy  <= 1'b1;
                        state <= S_PREP;
                    end
                end

                // 单独一拍：让 fld/p 决定的 wid/col/val 组合结果先稳定下来，
                // 这一拍也让波形上"启动 -> 第一个写"有个清晰的边界。
                S_PREP: state <= S_WR;

                S_WR: begin
                    we    <= 1'b1;
                    waddr <= {BAND_ROW, (col + {4'b0, p})};
                    wdata <= cur_ch;
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    if (p + 2'd1 >= wid) begin
                        p <= 2'd0;
                        if (fld == 2'd2) state <= S_END;
                        else begin
                            fld   <= fld + 2'd1;
                            state <= S_PREP;
                        end
                    end else begin
                        p     <= p + 2'd1;
                        state <= S_PREP;
                    end
                end

                S_END: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
