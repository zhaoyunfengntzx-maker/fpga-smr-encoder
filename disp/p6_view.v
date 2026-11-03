//=============================================================================
//  disp/p6_view.v -- 把 P6 设置页的 15 个字段画成**寄存器当前值**
//
//  为什么需要它（这块 RAM 的写口在此之前一直接 1'b0）：
//    P6 数值层原来只有 tools/gen_text_ram.py 的 initial 静态预置 ——
//    也就是说，屏上那些数字**恰好等于编码器复位默认值**时就看着像真的，
//    其实从来没有反映过寄存器。上电后只要改过任何一个设置，屏上就是假数据。
//    本模块每帧在消隐期把 15 个字段按 **disp_tap 回读回来的 cfg_*** 重写一遍。
//
//  与 disp/val_format.v / disp/touch_view.v 的分工：
//    val_format : P1 总览的测量值（有符号、带小数、除法交给 fixed_div）
//    touch_view : P8 触摸诊断（无符号整数）
//    p6_view    : P6 设置回读（无符号整数 + 前缀字段 + 两种枚举串 + Q1.15 定点数）
//  三个模块都只写自己那一页的数值层 RAM，由 disp_engine 用页号门控。
//
//  字段表（与 tools/gen_text_ram.py 的 P6_LAB/P6_VAL **两处共同契约**）：
//    fld  lab 标题     val 格行/格列  宽  来源（disp_tap 字段）        渲染
//     0   倍频          1 / 2          4  cfg_inter（0 视为 256）      "X" + 右对齐十进制
//     1   分频          1 / 12         3  cfg_div + 1                  "/" + 右对齐十进制
//     2   极对数        1 / 22         2  cfg_pairs（0 视为 32）       右对齐十进制
//     3   迟滞          2 / 2          2  cfg_hyst_ab
//     4   限幅          2 / 12         4  cfg_ablimit
//     5   Z脉宽         2 / 22         2  cfg_zwidth
//     6   Z相位         3 / 2          4  cfg_zphase（单位 360/4096）
//     7   UVW相位       3 / 12         5  cfg_uvwph（单位 2^16/周期）
//     8   极性          3 / 22         8  cfg_pol = {uvwpol,zpol,bpol,apol}
//                                          -> "A+B+Z+U+"，'+' 表示未反相、'-' 表示反相
//     9   ABZ           4 / 2          3  tap_abzen（0x0109）         "ON " / "OFF"
//    10   UVW           4 / 12         3  tap_uwven（0x0109）         "ON " / "OFF"
//    11   SHIFT         4 / 22         4  tap_shift（0x051A[3:0]）    "S<ss>C<cc>"
//                                          = {shift_c[1:0], shift_s[1:0]}
//    12   增益S         5 / 2          5  cfg_gain_s（无符号 Q1.15）   "d.ddd"（千分位，见下）
//    13   增益C         5 / 12         5  cfg_gain_c（无符号 Q1.15）   同上
//    14   相位修正      5 / 22         6  cfg_phase_k（有符号 Q1.15）  "+d.ddd" / "-d.ddd"
//    ★ 9/10/11 是 v19 新增的（spec 4.4 的 P6 是 **3 列 x 4 项**，此前只有 9 项）。
//      三个信号在本模块新增端口前**早就在 disp_engine 的端口表里**（tap_abzen /
//      tap_uwven / tap_shift，分别为 rtl 的 0x0109 与 0x051A 回读），所以那一版
//      没有动 rtl/，只是把它们接到了本模块。
//    ★ 12/13/14 是 v41（㊳）新增的：spec 4.4 的字面版面是"项高 88 px"，照字面做
//      会在危险区上方空出 88 px ⇒ 本轮**补第 5 行**把这 88 px 填掉。放的是 v15
//      起就在 disp_tap 里、却从来没上过屏的三个修正参数（增益S / 增益C / 相位修正）。
//      三个信号同样早就在 disp_engine 端口上（tap_gain_s / tap_gain_c / tap_phase_k）。
//    ★ 标题写 ASCII（`ABZ` / `UVW` / `SHIFT`）而不是"使能/粗调移位"：那五个汉字
//      当时不在字库里（lab 码已拓到 8 bit，门槛只剩"有没有栅格化"）。
//    ★ "极性" 一格里没有 4 个独立读数可选：uvwpol 对 U/V/W **整组**生效，
//      所以第 8 格写 'U' 加一个符号，含义是"UVW 这组反没反"，不是"只有 U 相"。
//    ★ 每列可用宽度是 10 格（col 2 -> 2..11、col 12 -> 12..21、col 22 -> 22..31），
//      上表的宽都在各自列的 10 格预算内，改宽时先数这个。
//    ★ v41（㊳）：档距改成 spec 4.4 的字面值 **88 px**（5 项铺满 y 64..503），由
//      disp/disp_engine.v 的"P6 虚拟格网"折算 —— 所以 val 格行不再与服务端 64 px
//      格网对齐：行号 = 1 + 项号 k，格内 y = 带内 y - 13（见那边的 P6_* 常量）。
//      本模块只管"往第 k 行的格子里写什么字符"，与映射无关。
//    ★ Q1.15 的显示口径：值 = raw/32768 ∈ [-1, 1)，屏上写成 3 位小数的定点数
//      （千分数）。算法只有移位与减：`m*125 >> 12`（m = 幅值，负数先取补）——
//      m*125 = (m<<7) - (m<<1) - m。小数三位**不做前导零抑制**（0.005 必须写出
//      两个 0），千位照常显示，所以 5 格（无符号）/ 6 格（带 +- 号）。
//
//  跑在哪：只在消隐期（与 touch_view、band_view 共用 disp_engine 的 vf_start）。
//  一帧 853440 拍里有效像素 614400 个，剩 239040 拍；本模块 15 个字段约 620 拍。
//
//  ★ 字符码不是 ASCII，是字库索引（字符集 " .-+/:..."，见 gen_text_ram.py）：
//      ' '=0  '.'=1  '-'=2  '+'=3  '/'=4  '0'=8（数字 d -> 8+d）
//      'A'=18 'B'=19 'C'=20 'F'=23 'N'=31 'O'=32 'S'=36 'U'=38 'X'=41 'Z'=43
//=============================================================================

`default_nettype none

module p6_view (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    // ---- P6 设置回读输入（来自 disp/enc_disp_tap.v 的具名端口）----
    input  wire [9:0]  cfg_inter,     // 倍频率，0 视为 256
    input  wire [2:0]  cfg_div,       // 分频率编码，显示值 = 本值 + 1
    input  wire [4:0]  cfg_pairs,     // 极对数，0 视为 32
    input  wire [4:0]  cfg_hyst_ab,   // AB 迟滞
    input  wire [7:0]  cfg_ablimit,   // AB 限频上限
    input  wire [3:0]  cfg_zwidth,    // Z 脉宽
    input  wire [11:0] cfg_zphase,    // Z 相位
    input  wire [15:0] cfg_uvwph,     // UVW 相位
    input  wire [3:0]  cfg_pol,       // {uvwpol,zpol,bpol,apol}
    // ---- v19：第 4 行的三项（早就在 disp_tap 里，本版才接到 P6）----
    input  wire        cfg_abzen,     // 0x0109: ABZ 使能
    input  wire        cfg_uwven,     // 0x0109: UVW 使能
    input  wire [3:0]  cfg_shift,     // 0x051A[3:0]: {shift_c[1:0], shift_s[1:0]}
    // ---- v41（㊳）：第 5 行的三项（v15 起就在 disp_engine 端口上，本版接到 P6）----
    //   都是 Q1.15（0x0510/0x0512/0x0518 系的回读），显示成 3 位小数定点数。
    input  wire [15:0] cfg_gain_s,    // 增益 S：无符号 Q1.15（0..1.999）
    input  wire [15:0] cfg_gain_c,    // 增益 C：无符号 Q1.15
    input  wire [15:0] cfg_phase_k,   // 相位修正：**有符号** Q1.15（-1.000..+0.999）

    // ---- 数值层写口（waddr = {格行[3:0], 格列[4:0]}）----
    output reg         we,
    output reg  [8:0]  waddr,
    output reg  [5:0]  wdata,
    output reg         busy,
    output reg         done
);

    // ---------------------------------------------------------------- 字符常量
    localparam [5:0] CH_SP    = 6'd0;    // ' '
    localparam [5:0] CH_DOT   = 6'd1;    // '.'（Q1.15 的小数点，v41 起用到）
    localparam [5:0] CH_MI    = 6'd2;    // '-'
    localparam [5:0] CH_PL    = 6'd3;    // '+'
    localparam [5:0] CH_DIV   = 6'd46;   // '÷'
    localparam [5:0] CH_ZERO  = 6'd8;    // '0'
    localparam [5:0] CH_A     = 6'd18;
    localparam [5:0] CH_B     = 6'd19;
    localparam [5:0] CH_C     = 6'd20;   // 'C'
    localparam [5:0] CH_F     = 6'd23;   // 'F'
    localparam [5:0] CH_N     = 6'd31;   // 'N'
    localparam [5:0] CH_O     = 6'd32;   // 'O'
    localparam [5:0] CH_S     = 6'd36;   // 'S'
    localparam [5:0] CH_U     = 6'd38;
    localparam [5:0] CH_MUL   = 6'd45;   // '×'
    localparam [5:0] CH_Z     = 6'd43;

    // 字段种类
    localparam [2:0] K_NUM   = 3'd0;     // 右对齐十进制
    localparam [2:0] K_PFX   = 3'd1;     // 固定前缀字符 + 右对齐十进制
    localparam [2:0] K_STR   = 3'd2;     // 纯字符串（极性）
    localparam [2:0] K_ENA   = 3'd3;     // 使能枚举："ON " / "OFF"
    localparam [2:0] K_SHIFT = 3'd4;     // "S<shift_s>C<shift_c>"
    localparam [2:0] K_Q15   = 3'd5;     // Q1.15 定点数："d.ddd" / "+d.ddd"（千分位）
    //   ★ K_Q15 也要走 BCD（见下面 cur_bcd），但它的编号大于 K_STR ⇒ 不能再拿
    //     "cur_kind >= K_STR" 当"不做 BCD"的判据，必须用显式的 cur_bcd。

    // ---------------------------------------------------------------- 字段表
    function [3:0] f_row;
        input [3:0] f;
        begin
            if (f <= 4'd2)       f_row = 4'd1;
            else if (f <= 4'd5)  f_row = 4'd2;
            else if (f <= 4'd8)  f_row = 4'd3;
            else if (f <= 4'd11) f_row = 4'd4;
            else                 f_row = 4'd5;      // v41：第 5 行（88 px 行带 4）
        end
    endfunction

    function [4:0] f_col;
        input [3:0] f;
        begin
            case (f)
                4'd0, 4'd3, 4'd6, 4'd9,  4'd12: f_col = 5'd3;
                4'd1, 4'd4, 4'd7, 4'd10, 4'd13: f_col = 5'd13;
                default:                        f_col = 5'd23;
            endcase
        end
    endfunction

    function [3:0] f_wid;
        input [3:0] f;
        begin
            case (f)
                4'd0: f_wid = 4'd4;    // "× 64" / "×256"
                4'd1: f_wid = 4'd3;    // "÷ 1"
                4'd2: f_wid = 4'd2;    // 极对数
                4'd3: f_wid = 4'd2;    // 迟滞
                4'd4: f_wid = 4'd4;    // 限幅
                4'd5: f_wid = 4'd2;    // Z 脉宽
                4'd6: f_wid = 4'd4;    // Z 相位
                4'd7: f_wid = 4'd5;    // UVW 相位
                4'd8: f_wid = 4'd8;    // 极性 "A+B+Z+U+"
                4'd9: f_wid = 4'd3;    // ABZ 使能 "ON " / "OFF"
                4'd10: f_wid = 4'd3;   // UVW 使能 "ON " / "OFF"
                4'd11: f_wid = 4'd4;   // SHIFT "S2C1"
                4'd12: f_wid = 4'd5;   // 增益S "1.000"
                4'd13: f_wid = 4'd5;   // 增益C "1.000"
                default: f_wid = 4'd6; // 相位修正 "+0.000" / "-0.125"
            endcase
        end
    endfunction

    function [2:0] f_kind;
        input [3:0] f;
        begin
            case (f)
                4'd0, 4'd1: f_kind = K_PFX;
                4'd8:       f_kind = K_STR;
                4'd9, 4'd10: f_kind = K_ENA;
                4'd11:      f_kind = K_SHIFT;
                4'd12, 4'd13, 4'd14: f_kind = K_Q15;
                default:    f_kind = K_NUM;
            endcase
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
                default: pow10 = 32'd100000;
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

    // ★ 三个"显示口径"的修正都在这里，别改到别处去：
    //   倍频 0 -> 256（0x0101/0x0102 的全 0 组合表示最大倍频）
    //   分频编码 -> +1（0x0102[4:2] 存的是编码，不是分频值）
    //   极对数 0 -> 32（0x0100[4:0]=0 表示 32）
    wire [9:0] inter_disp = (cfg_inter == 10'd0) ? 10'd256 : cfg_inter;
    wire [3:0] div_disp   = {1'b0, cfg_div} + 4'd1;
    wire [5:0] pairs_disp = (cfg_pairs == 5'd0) ? 6'd32 : {1'b0, cfg_pairs};

    // ---- v41（㊳）第 5 行：Q1.15 定点数 ----------------------------------
    //   ★ 幅值：相位修正是**有符号** Q1.15，先取补；两个增益是无符号（0..1.999）。
    //   ★ 千分数 = m*1000/32768 = (m*125) >> 12。m*125 只有移位与减法：
    //       m*125 = (m<<7) - (m<<1) - m     ⇒ 两个减法器，不要乘法器/DSP。
    wire [15:0] q15_phk_mag = cfg_phase_k[15] ? (~cfg_phase_k + 16'd1) : cfg_phase_k;
    wire [15:0] q15_raw     = (fld == 4'd12) ? cfg_gain_s :
                              (fld == 4'd13) ? cfg_gain_c : q15_phk_mag;
    wire [22:0] q15_a7      = {q15_raw, 7'd0};          // m * 128
    wire [22:0] q15_a2      = {6'd0, q15_raw, 1'b0};    // m * 2
    wire [22:0] q15_a1      = {7'd0, q15_raw};          // m * 1
    wire [22:0] q15_mul     = q15_a7 - q15_a2 - q15_a1;
    wire [10:0] q15_perm    = q15_mul[22:12];           // 0..1999（千分数）

    reg [31:0] v32;
    always @* begin
        case (fld)
            4'd0:    v32 = {22'd0, inter_disp};
            4'd1:    v32 = {28'd0, div_disp};
            4'd2:    v32 = {26'd0, pairs_disp};
            4'd3:    v32 = {27'd0, cfg_hyst_ab};
            4'd4:    v32 = {24'd0, cfg_ablimit};
            4'd5:    v32 = {28'd0, cfg_zwidth};
            4'd6:    v32 = {20'd0, cfg_zphase};
            4'd7:    v32 = {16'd0, cfg_uvwph};
            4'd12, 4'd13, 4'd14: v32 = {21'd0, q15_perm};   // v41：Q1.15 的千分数
            default: v32 = 32'd0;            // 8..11 不走 BCD
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
    reg [19:0] dd_bcd;               // 5 位十进制（最大字段是 UVW 相位的 65535）

    // double-dabble 的 +3 网络（纯组合，5 个 4 位十进制位）
    wire [19:0] dd_adj = { add3(dd_bcd[19:16]), add3(dd_bcd[15:12]),
                           add3(dd_bcd[11:8]),  add3(dd_bcd[7:4]),
                           add3(dd_bcd[3:0]) };

    wire [3:0]  cur_wid  = f_wid(fld);
    wire [2:0]  cur_kind = f_kind(fld);

    // 前缀字段：第 0 格写前缀，数字部分占剩下的 (wid-1) 格
    wire        cur_pfx  = (cur_kind == K_PFX) && (p == 4'd0);
    wire [3:0]  num_p    = (cur_kind == K_PFX) ? (p - 4'd1) : p;
    wire [3:0]  num_wid  = (cur_kind == K_PFX) ? (cur_wid - 4'd1) : cur_wid;
    // p 只在 S_WR 中有意义；越界时钳到 0，避免变址位选越界
    wire [3:0]  cur_di   = (num_p < num_wid) ? (num_wid - 4'd1 - num_p) : 4'd0;
    wire [3:0]  cur_dig  = dd_bcd[{cur_di, 2'b0} +: 4];

    // 前导零抑制：最高位以外的位置，值不够大就写空格。
    // ★ 最低位（di==0）永远显示 —— 否则 0 会显示成空白。
    wire        cur_vis  = (cur_di == 4'd0) || (v32 >= pow10(cur_di));
    wire [5:0]  num_ch   = cur_vis ? (CH_ZERO + {2'd0, cur_dig}) : CH_SP;

    // 前缀字符：fld0 是 'X'、fld1 是 '/'
    wire [5:0]  pfx_ch   = (fld == 4'd0) ? CH_MUL : CH_DIV;

    // 极性字符串 "A+B+Z+U+"：奇数格是字母，偶数格是该组的符号
    function [5:0] pola_ch;
        input [3:0] k;
        begin
            case (k)
                4'd0:    pola_ch = CH_A;
                4'd1:    pola_ch = cfg_pol[0] ? CH_MI : CH_PL;   // apol
                4'd2:    pola_ch = CH_B;
                4'd3:    pola_ch = cfg_pol[1] ? CH_MI : CH_PL;   // bpol
                4'd4:    pola_ch = CH_Z;
                4'd5:    pola_ch = cfg_pol[2] ? CH_MI : CH_PL;   // zpol
                4'd6:    pola_ch = CH_U;
                default: pola_ch = cfg_pol[3] ? CH_MI : CH_PL;   // uvwpol（整组）
            endcase
        end
    endfunction

    // 使能枚举："ON " / "OFF"（左对齐 3 格；两个字段共用，只是源不同）
    wire        cur_ena = (fld == 4'd10) ? cfg_uwven : cfg_abzen;
    function [5:0] ena_ch;
        input [3:0] k;
        input       en;
        begin
            case (k)
                4'd0:    ena_ch = CH_O;
                4'd1:    ena_ch = en ? CH_N : CH_F;
                default: ena_ch = en ? CH_SP : CH_F;
            endcase
        end
    endfunction

    // SHIFT "S<shift_s>C<shift_c>"：shift = {shift_c[1:0], shift_s[1:0]}
    function [5:0] shift_ch;
        input [3:0] k;
        begin
            case (k)
                4'd0:    shift_ch = CH_S;
                4'd1:    shift_ch = CH_ZERO + {4'd0, cfg_shift[1:0]};
                4'd2:    shift_ch = CH_C;
                default: shift_ch = CH_ZERO + {4'd0, cfg_shift[3:2]};
            endcase
        end
    endfunction

    // ★ v41：K_Q15 的编号**大于** K_STR，但它要 BCD ⇒ 显式判据，
    //   不能再用 "cur_kind >= K_STR" 当"不做 BCD"的条件（否则会跳过 BCD 直接查表）。
    wire        cur_bcd  = (cur_kind == K_NUM) || (cur_kind == K_PFX) || (cur_kind == K_Q15);

    // ---- v41：Q1.15 的字符布局 ------------------------------------------
    //   无符号（增益S/增益C）宽 5：千位 '.' 百位 十位 个位
    //   有符号（相位修正）    宽 6：符号 千位 '.' 百位 十位 个位
    //   ★ 小数三位**不做前导零抑制**（0.005 要写出两个 0）⇒ 本支不用 cur_vis。
    wire [3:0]  q15_signed = {(fld == 4'd14)};
    wire [3:0]  q15_p   = q15_signed[0] ? (p - 4'd1) : p;
    wire [3:0]  q15_di  = (q15_p == 4'd0) ? 4'd3 :        // 千位（BCD 位 3）
                          (q15_p == 4'd2) ? 4'd2 :        // 百位
                          (q15_p == 4'd3) ? 4'd1 :        // 十位
                                            4'd0;         // 个位
    wire [3:0]  q15_dig = dd_bcd[{q15_di, 2'b0} +: 4];
    wire [5:0]  q15_ch  = (q15_signed[0] && (p == 4'd0))
                            ? (cfg_phase_k[15] ? CH_MI : CH_PL) :
                          (q15_p == 4'd1) ? CH_DOT :
                                            (CH_ZERO + {2'd0, q15_dig});

    wire [5:0] cur_ch = (cur_kind == K_STR)   ? pola_ch(p) :
                        (cur_kind == K_ENA)   ? ena_ch(p, cur_ena) :
                        (cur_kind == K_SHIFT) ? shift_ch(p) :
                        (cur_kind == K_Q15)   ? q15_ch :
                        cur_pfx               ? pfx_ch :
                                                num_ch;

    always @* begin
        we    = (state == S_WR);
        waddr = {f_row(fld), f_col(fld)} + {5'd0, p};
        wdata = cur_ch;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; fld <= 4'd0; p <= 4'd0; dd_cnt <= 5'd0;
            dd_bin <= 32'd0; dd_bcd <= 20'd0;
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
                    // ★ 只有"十进制字段"（K_NUM / K_PFX / K_Q15）做 BCD：
                    //   字符串类（极性 / 使能 / SHIFT）逐格查表出字符，没有十进制位。
                    if (!cur_bcd) state <= S_WR;
                    else begin
                        dd_bin <= v32;
                        dd_bcd <= 20'd0;
                        dd_cnt <= 5'd0;
                        state  <= S_DD;
                    end
                end

                S_DD: begin
                    dd_bcd <= {dd_adj[18:0], dd_bin[31]};
                    dd_bin <= {dd_bin[30:0], 1'b0};
                    if (dd_cnt == 5'd31) state <= S_WR;
                    else                 dd_cnt <= dd_cnt + 5'd1;
                end

                S_WR: begin
                    if (p == cur_wid - 4'd1) state <= S_NEXT;
                    else                     p <= p + 4'd1;
                end

                S_NEXT: begin
                    if (fld == 4'd14) state <= S_END;        // v41：15 个字段（0..14）
                    else begin
                        fld   <= fld + 4'd1;
                        state <= S_PREP;
                    end
                end

                default: begin                             // S_END
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
