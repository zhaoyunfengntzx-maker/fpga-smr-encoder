//=============================================================================
//  disp/touch_view.v -- P8「系统信息 / 自检」页的数值层写入器
//
//  ★ v35（㉛）：spec §4.4 把 P8 定义成「系统信息 / 自检」，五项是
//     ① 设备 ID  ② 固件版本  ③ 链路统计  ④ 资源占用  ⑤ 自检结果。
//     本轮把 ①..④ 落到版面上（⑤ 的判定输出与「通过 / 失败」字模下一轮做），
//     九个字段的**行/列坐标一个没动**，只换了字段的含义与宽度 —— 这样
//     disp/disp_engine.v 的写口仲裁、tools/gen_text_ram.py 的 P8_VAL 占位
//     布局都不必改。
//
//  与 disp/val_format.v 的分工：
//    val_format : P1 总览的测量值（有符号、带小数、除法交给 fixed_div）
//    touch_view : P8 系统信息/自检（三个静态字符串 + 六个数）
//
//  为什么另写一个而不是复用 val_format：val_format 的字段表、符号处理、
//  小数点插入都是为"测量值"定制的，硬塞进系统信息只会让两边都难读。
//  这个模块只有一件事：字符串/整数 -> 逐字符写进数值层 RAM。
//
//  跑在哪：只在消隐期。一帧 853440 拍里有效像素 614400 个，剩 239040 拍，
//  本模块 9 个字段全程约 360 拍，占用不到千分之二。
//
//  ★ 字符码不是 ASCII，是字库索引（字符集 " .-+/:=^0123456789A-Z…"，见
//    tools/gen_font_rom.py 的 ASCII_CHARS）：
//      ' '=0  '.'=1  '-'=2  '0'=8（数字 d -> 8+d）  'A'=18，故 'C'=20 'E'=22
//      'N'=31  'T'=37  'V'=39  '9'=17  '5'=13  '1'=9  '3'=11
//
//  ★ 资源占用那三个百分比是**写死的常量**（RES_* 下面），来源 = 最近一次
//    位流重建后的 _disp_work/impl_util.rpt（LUT 65.05% / BRAM 41.00% /
//    DSP 23.33% ⇒ 取整 65 / 41 / 23）。它们随每一版位流缓慢变化，
//    每轮位流重建后要回来核对这三行 —— 归档的 verify 脚本会把它们与
//    实现报告比对，对不上就报红。
//=============================================================================

`default_nettype none

module touch_view (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    // ---- 触摸诊断输入（来自 disp_engine 里已寄存的 q_tch_*）----
    input  wire [1:0]  tch_type,
    input  wire [2:0]  tch_num,
    input  wire [15:0] tch_x0,
    input  wire [15:0] tch_y0,
    input  wire [7:0]  tch_status,
    input  wire [7:0]  tch_pid,
    input  wire [23:0] tch_reads,
    input  wire [23:0] tch_nack,
    input  wire [23:0] tch_timeout,

    // ---- 数值层写口（waddr = {格行[3:0], 格列[4:0]}）----
    output reg         we,
    output reg  [8:0]  waddr,
    output reg  [5:0]  wdata,
    output reg         busy,
    output reg         done
);

    // ---------------------------------------------------------------- 字符常量
    localparam [5:0] CH_SP   = 6'd0;    // ' '
    localparam [5:0] CH_MI   = 6'd2;    // '-'
    localparam [5:0] CH_ZERO = 6'd8;    // '0'
    localparam [5:0] CH_ONE  = 6'd9;    // '1'
    localparam [5:0] CH_FIVE = 6'd13;   // '5'
    localparam [5:0] CH_NINE = 6'd17;   // '9'
    localparam [5:0] CH_C    = 6'd20;   // 'C'
    localparam [5:0] CH_E    = 6'd22;   // 'E'
    localparam [5:0] CH_F    = 6'd23;   // 'F'
    localparam [5:0] CH_G    = 6'd24;   // 'G'
    localparam [5:0] CH_N    = 6'd31;   // 'N'
    localparam [5:0] CH_T    = 6'd37;   // 'T'
    localparam [5:0] CH_V    = 6'd39;   // 'V'

    // ---------------------------------------------------------------- 固件版本
    //   ★ 屏上「固件版本」（spec §4.4 第 2 项）必须跟**本轮的位流版本**走。
    //     旧版把 "V35" 逐字符写死在下面的 case 里 ⇒ 从 v35 一直挂到 v46 都没人发现
    //     （U-35 那轮它是对的，之后每轮重建位流它就越来越旧）。
    //     现在只留**这一处**来源（两位十进制），归档的 verify 脚本会把它与
    //     DEV_STATUS 最新轮次标题里的版本号比对，对不上就报红。
    //     当前 = **v55**（U-56；上一版 v47 从 U-48 一直挂到 v54 —— 见 DEV_STATUS §U-56）。
    localparam [3:0] FW_MAJ = 4'd5;   // 十位
    localparam [3:0] FW_MIN = 4'd5;   // 个位

    // ---------------------------------------------------------------- 资源占用常量
    //   ★ 来源 = 最近一次位流重建后的 _disp_work/impl_util.rpt：
    //     Slice LUTs 69.68% / Block RAM Tile 41.00% / DSPs 24.44% ⇒ 四舍五入（69.50..69.99 都进到 70）。
    //     ★ 这三个数在 RTL 里只能是"交付位流的快照"：它们参与综合，改一次就要重出一版
    //       位流，所以流程是"先出位流 → 读报告 → 若取整值变了再改这三个常量并重出"。
    //     ★ **U-57 起有机器判据**：`python tools/gen_res_pct.py` 直接读报告与这三个常量比对
    //       （不一致退出码 1；`--write` 可按报告改写，改完必须重出位流）。别再靠人眼抄。
    //       （旧版写 65 而实际 67.51 ⇒ 屏上少报 2.5 个点。）
    localparam [31:0] RES_LUT_PCT  = 32'd70;
    localparam [31:0] RES_BRAM_PCT = 32'd41;
    localparam [31:0] RES_DSP_PCT  = 32'd24;

    // ---------------------------------------------------------------- 字段表
    //   9 个字段 = 3 组 x 3 列，与 tools/gen_text_ram.py 的 P8_LAB/P8_VAL 对齐
    //   列 3/13/23 = x 96/416/736（导航栏 80 + 16 px 内边距）
    //     fld0 (1, 3,5) 设备 ID     字符串 "ENCC1"
    //     fld1 (1,13,3) 固件版本    字符串 "V55"（由 FW_MAJ/FW_MIN 两位拼出）
    //     fld2 (1,23,3) 触摸 IC 型号 字符串 GT9 / FT5 / ---
    //     fld3 (4, 3,6) IIC 读次数   fld4 (4,13,6) 无应答  fld5 (4,23,6) 超时
    //     fld6 (7, 3,2) LUT %        fld7 (7,13,2) BRAM %  fld8 (7,23,2) DSP %
    function [3:0] f_row;
        input [3:0] f;
        begin
            if (f <= 4'd2)       f_row = 4'd1;
            else if (f <= 4'd5)  f_row = 4'd4;
            else                 f_row = 4'd7;
        end
    endfunction

    function [4:0] f_col;
        input [3:0] f;
        begin
            case (f)
                4'd0, 4'd3, 4'd6: f_col = 5'd3;
                4'd1, 4'd4, 4'd7: f_col = 5'd13;
                default:          f_col = 5'd23;
            endcase
        end
    endfunction

    function [3:0] f_wid;
        input [3:0] f;
        begin
            case (f)
                4'd0: f_wid = 4'd5;    // "ENCC1"
                4'd1: f_wid = 4'd3;    // "V55"
                4'd2: f_wid = 4'd3;    // "GT9" / "FT5" / "---"
                4'd3: f_wid = 4'd6;    // IIC 读次数
                4'd4: f_wid = 4'd6;    // NACK
                4'd5: f_wid = 4'd6;    // timeout
                4'd6: f_wid = 4'd2;    // LUT %
                4'd7: f_wid = 4'd2;    // BRAM %
                default: f_wid = 4'd2; // DSP %
            endcase
        end
    endfunction

    // 字符串字段（不走 BCD）：0..2
    function f_str;
        input [3:0] f;
        begin
            f_str = (f <= 4'd2);
        end
    endfunction

    function [31:0] pow10;
        input [3:0] k;
        begin
            case (k)
                4'd0: pow10 = 32'd1;
                4'd1: pow10 = 32'd10;
                4'd2: pow10 = 32'd100;
                4'd3: pow10 = 32'd1000;
                4'd4: pow10 = 32'd10000;
                4'd5: pow10 = 32'd100000;
                4'd6: pow10 = 32'd1000000;
                4'd7: pow10 = 32'd10000000;
                4'd8: pow10 = 32'd100000000;
                default: pow10 = 32'd1000000000;
            endcase
        end
    endfunction

    function [3:0] add3;             // double-dabble 的 ">=5 则 +3"
        input [3:0] d;
        begin
            add3 = (d >= 4'd5) ? (d + 4'd3) : d;
        end
    endfunction

    // ---------------------------------------------------------------- 待格式化值
    reg [3:0] fld;

    reg [31:0] v32;
    always @* begin
        case (fld)
            4'd3:    v32 = {8'd0,  tch_reads};
            4'd4:    v32 = {8'd0,  tch_nack};
            4'd5:    v32 = {8'd0,  tch_timeout};
            4'd6:    v32 = RES_LUT_PCT;
            4'd7:    v32 = RES_BRAM_PCT;
            4'd8:    v32 = RES_DSP_PCT;
            default: v32 = 32'd0;
        endcase
    end

    // ---------------------------------------------------------------- 状态机
    localparam [2:0] S_IDLE = 3'd0,
                     S_PREP = 3'd1,
                     S_DD   = 3'd2,
                     S_WR   = 3'd3,
                     S_NEXT = 3'd4,
                     S_END  = 3'd5;

    reg [2:0]  state;
    reg [3:0]  p;                    // 本字段内已写到第几个字符
    reg [4:0]  dd_cnt;
    reg [31:0] dd_bin;
    reg [39:0] dd_bcd;

    // double-dabble 的 +3 网络（纯组合，10 个 4 位十进制位）
    wire [39:0] dd_adj = { add3(dd_bcd[39:36]), add3(dd_bcd[35:32]),
                           add3(dd_bcd[31:28]), add3(dd_bcd[27:24]),
                           add3(dd_bcd[23:20]), add3(dd_bcd[19:16]),
                           add3(dd_bcd[15:12]), add3(dd_bcd[11:8]),
                           add3(dd_bcd[7:4]),   add3(dd_bcd[3:0]) };

    wire [3:0] cur_wid = f_wid(fld);
    // p 只在 S_WR 中有意义；越界时钳到 0，避免变址位选越界
    wire [3:0] cur_di  = (p < cur_wid) ? (cur_wid - 4'd1 - p) : 4'd0;
    wire [3:0] cur_dig = dd_bcd[{cur_di, 2'b0} +: 4];

    // 前导零抑制：最高位以外的位置，值不够大就写空格。
    // ★ 最低位（di==0）永远显示 —— 否则 0 会显示成空白。
    wire cur_vis = (cur_di == 4'd0) || (v32 >= pow10(cur_di));
    wire [5:0] num_ch = cur_vis ? (CH_ZERO + {2'd0, cur_dig}) : CH_SP;

    // 字符串字段：0 = 设备 ID "ENCC1"、1 = 固件版本 "V55"、2 = 触摸 IC 型号
    //   ★ 型号第三位必须跟着型号走（GT911 结尾 9、FT5206 结尾 5）——
    //     起初两位都写死 '9'，测试台立刻报 "FT9"，这就是字面量比对的用处。
    wire        t_known = (tch_type == 2'd1) || (tch_type == 2'd2);
    reg  [5:0]  str_ch;
    always @* begin
        if (fld == 4'd0) begin          // "ENCC1"
            case (p)
                4'd0:    str_ch = CH_E;
                4'd1:    str_ch = CH_N;
                4'd2:    str_ch = CH_C;
                4'd3:    str_ch = CH_C;
                default: str_ch = CH_ONE;
            endcase
        end else if (fld == 4'd1) begin // "V55"（= v55，U-56 这批；见上面的 FW_MAJ/FW_MIN）
            case (p)
                4'd0:    str_ch = CH_V;
                4'd1:    str_ch = CH_ZERO + {2'd0, FW_MAJ};
                default: str_ch = CH_ZERO + {2'd0, FW_MIN};
            endcase
        end else begin                  // 型号：GT9 / FT5 / ---
            case (p)
                4'd0:    str_ch = (tch_type == 2'd1) ? CH_G :
                                 (tch_type == 2'd2) ? CH_F : CH_MI;
                4'd1:    str_ch = t_known ? CH_T : CH_MI;
                default: str_ch = (tch_type == 2'd1) ? CH_NINE :
                                 (tch_type == 2'd2) ? CH_FIVE : CH_MI;
            endcase
        end
    end

    always @* begin
        we    = (state == S_WR);
        waddr = {f_row(fld), f_col(fld)} + {5'd0, p};
        wdata = f_str(fld) ? str_ch : num_ch;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; fld <= 4'd0; p <= 4'd0; dd_cnt <= 5'd0;
            dd_bin <= 32'd0; dd_bcd <= 40'd0;
            busy <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        fld   <= 4'd0;
                        busy  <= 1'b1;
                        state <= S_PREP;
                    end
                end

                S_PREP: begin
                    p <= 4'd0;
                    if (f_str(fld)) state <= S_WR;       // 字符串字段，不做 BCD
                    else begin
                        dd_bin <= v32;
                        dd_bcd <= 40'd0;
                        dd_cnt <= 5'd0;
                        state  <= S_DD;
                    end
                end

                S_DD: begin
                    dd_bcd <= {dd_adj[38:0], dd_bin[31]};
                    dd_bin <= {dd_bin[30:0], 1'b0};
                    if (dd_cnt == 5'd31) state <= S_WR;
                    else                 dd_cnt <= dd_cnt + 5'd1;
                end

                S_WR: begin
                    if (p == cur_wid - 4'd1) state <= S_NEXT;
                    else                     p <= p + 4'd1;
                end

                S_NEXT: begin
                    if (fld == 4'd8) state <= S_END;
                    else begin
                        fld   <= fld + 4'd1;
                        state <= S_PREP;
                    end
                end

                default: begin                            // S_END
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
