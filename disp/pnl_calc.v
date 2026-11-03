`timescale 1ns / 1ps
// =============================================================================
// disp/pnl_calc.v —— v51（㊽）B4：面板上"改前就能看到后果"的两个数
//
// spec §6.3（docs/13_display_ui_requirements.md:284）：
//   "编辑面板同时显示 `等效倍率 = inter/div` 与预测的 AB 边沿率，**改前就能看到后果**。"
// 现状（v50）：面板上只有活动字段的待应用值（三位 seg7 大窗），这两个**算出来的数**
// 一个也没有；读者得自己在 P1 卡片 2 的 `×N ÷M` 之间做除法，边沿率还得再乘 F。
//
// 本模块做两件事（只在面板开着时跑，每帧一次，全程在垂直消隐期）：
//   ① 等效倍率 = inter / div，显示成一位小数（`64.0` / `33.3` / `256.0`）；
//   ② 预测 AB 边沿率 = 4 × 等效倍率 × f_in，显示成 kHz 一位小数（`17.4`），
//      超过 999.9 kHz 就饱和（四位数窗的物理上限）。
//
// 口径与三处记账（写进归档，不自己发明术语）：
//   ★ 边沿率用**等效倍率**（inter/div），不是只用 inter：spec 卡片 2 的静态标签
//     写的是"边沿率 4×倍频×F"，那是 `div` 引入之前（v44/㊶ 之前没有 ÷ 字段）的写法。
//   ★ 4 是正交四倍频（A/B 两相各两个边沿），与 spec :186 的 `4×64×f_in` 同口径。
//   ★ f_in 取 `freq_meter` 的 `f_q10`（1/1024 Hz 定点，见 disp_engine.v §2b 的推导：
//     f = Δ/1024）；本模块只用**幅值**（倒转时 f 为负，边沿率是速率、不带方向）。
//   ★ 空态：`sig_bad`（无载波）时边沿率显示
//     `-` —— 它依赖**测出来的** f_in，没有 f_in 就没有预测值；而等效倍率只依赖两个
//     设置值，永远有效。这与 ㊷/㊸/㊼ 的空态是同一口径（B3 已经把这条纪律定在
//     P1/P5/P2 三页）。
//
// 资源与做法：
//   两次串行除法（12 位 / 24 位）复用同一个 32 位恢复余数除法器，一帧一次，
//   24 拍 ≪ 消隐期 239,040 拍；不进像素路径、不用 DSP 除法核、不查表。
//   十进制拆位沿用 disp_engine.v 里 U-45 的"并行比较"写法（**不用串行减法链**，
//   那条链在 U-45 首版实测就是关键路径：20.472 ns / 32 级逻辑）。
//
// 写口：与 disp/pos_hex.v 完全同构 —— 组合 `we` + `hold` 停拍（时序赋值的 `we`
//   每帧会丢一拍，U-49 踩过）。仲裁在 disp_engine.v 里排最后一位（标签 > 状态条 > 十六进制 > 本模块）。
// =============================================================================
module pnl_calc #(
    // 等效倍率那一行：格行 23（y 368..383）、数值 5 格在格列 41..45（x 656..735）
    parameter [5:0] EQ_ROW = 6'd23,
    parameter [5:0] EQ_COL = 6'd41,
    // AB 边沿率那一行：格行 25（y 400..415）、数值 5 格在格列 42..46（x 672..751）
    parameter [5:0] RT_ROW = 6'd25,
    parameter [5:0] RT_COL = 6'd42
)(
    input  wire        clk,
    input  wire        rst_n,

    // 面板状态（disp/ui_panel.v 的待应用值；只在 pnl_on 时用）
    input  wire        pnl_on,
    input  wire [9:0]  inter_enc,     // 待应用倍频编码（0 表示 256）
    input  wire [2:0]  div_code,      // 待应用分频码（div = 码 + 1）
    input  wire signed [31:0] f_q10,  // 输入频率，1/1024 Hz 定点（带方向）

    input  wire        start,         // 一帧一次的启动脉冲（disp_engine 的 vf_start）
    input  wire        sig_bad,       // 信号不可信（㊷/㊸/㊿ 判据：CRC 错 ｜ 无载波 ｜ 链路静默）
    input  wire        hold,          // lab 写口被别人占用（本拍不写）

    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         we,
    output reg         busy,
    output reg         done
);

    // 字符码（与 tools/gen_text_ram.py 的 ASCII_CHARS 同表）
    localparam [7:0] CH_SP = 8'd0, CH_DOT = 8'd1, CH_MINUS = 8'd2, CH_D0 = 8'd8;

    localparam [3:0] S_IDLE = 4'd0,
                     S_LAT  = 4'd1,
                     S_DIV  = 4'd2,
                     S_RND  = 4'd3,
                     S_FMT  = 4'd4,
                     S_WR   = 4'd5,
                     S_NEXT = 4'd6,
                     S_DONE = 4'd7;

    reg  [3:0]  st;
    reg  [11:0] iv;            // 2..256
    reg  [3:0]  dv;            // 1..8
    reg  [19:0] fhz;           // |f_in| 的整数部分（Hz），上限 1,000,000
    reg         ph;            // 0 = 等效倍率、1 = 边沿率
    reg  [30:0] sh;            // 除法：被除数移位寄存器（被除数左对齐到 bit30）
    reg  [10:0] rem;           // 除法：余数（< 100*dv ≤ 800）
    reg  [10:0] dvs;           // 除法：除数
    reg  [16:0] quot;          // 除法：商（相位 1 最大 7,999,200/100 = 79,992 ⇒ 17 位）
    reg  [5:0]  nbit;          // 除法：剩余拍数
    reg  [16:0] val;           // 待格式化的数（一位小数的定点：值 = val/10）
    reg  [16:0] m;             // 拆位：余数推进
    reg  [3:0]  d3, d2, d1, d0;
    reg  [1:0]  fcnt;          // 拆位：0→d3, 1→d2, 2→d1, 3→d0
    reg  [2:0]  wc;            // 写格：0..4

    // ---- 只读组合量 ---------------------------------------------------------
    wire [11:0] iv_w = (inter_enc == 10'd0) ? 12'd256 : {2'b0, inter_enc};
    wire [3:0]  dv_w = {1'b0, div_code} + 4'd1;
    //  |f|：负数取补码幅值；>>10 得整数 Hz；> 1e6 直接夹住（边沿率窗口只有四位）
    wire [31:0] fab  = f_q10[31] ? (~f_q10 + 32'd1) : f_q10;
    wire [19:0] fhz_w = (fab[31:20] != 12'd0) ? 20'd1_000_000 : fab[19:10];
    //  4 × iv × f（≤ 4×256×1e6 = 1.024e9 < 2^30，32 位够）
    wire [31:0] prod4 = ({20'd0, iv} * {12'd0, fhz}) << 2;
    //  ★ 被除数先夹到 7,999,200 = 9999 × 100 × 8（最大除数），这样"商 ≤ 79,992"；
    //    真正的显示饱和在 S_RND 里按**商**判（999.9 kHz = 9999），否则 100*dv=100 时
    //    商能到 79,992，14 位窗口装不下 —— 第一版就是这么溢出成 `0` 的。
    wire [22:0] dvnd_rt = (prod4 > 32'd7_999_200) ? 23'd7_999_200 : prod4[22:0];

    //  拆位用**并行比较**（U-45 的写法；串行减法链会压时序）
    function [3:0] c_div1000;   // 0..9
        input [16:0] x;
        begin
            c_div1000 = (x >= 14'd9000) ? 4'd9 : (x >= 14'd8000) ? 4'd8 :
                        (x >= 14'd7000) ? 4'd7 : (x >= 14'd6000) ? 4'd6 :
                        (x >= 14'd5000) ? 4'd5 : (x >= 14'd4000) ? 4'd4 :
                        (x >= 14'd3000) ? 4'd3 : (x >= 14'd2000) ? 4'd2 :
                        (x >= 14'd1000) ? 4'd1 : 4'd0;
        end
    endfunction
    function [3:0] c_div100;    // x < 1000 ⇒ 0..9
        input [16:0] x;
        begin
            c_div100 = (x >= 14'd900) ? 4'd9 : (x >= 14'd800) ? 4'd8 :
                       (x >= 14'd700) ? 4'd7 : (x >= 14'd600) ? 4'd6 :
                       (x >= 14'd500) ? 4'd5 : (x >= 14'd400) ? 4'd4 :
                       (x >= 14'd300) ? 4'd3 : (x >= 14'd200) ? 4'd2 :
                       (x >= 14'd100) ? 4'd1 : 4'd0;
        end
    endfunction
    function [3:0] c_div10;     // x < 100 ⇒ 0..9
        input [16:0] x;
        begin
            c_div10 = (x >= 14'd90) ? 4'd9 : (x >= 14'd80) ? 4'd8 :
                      (x >= 14'd70) ? 4'd7 : (x >= 14'd60) ? 4'd6 :
                      (x >= 14'd50) ? 4'd5 : (x >= 14'd40) ? 4'd4 :
                      (x >= 14'd30) ? 4'd3 : (x >= 14'd20) ? 4'd2 :
                      (x >= 14'd10) ? 4'd1 : 4'd0;
        end
    endfunction

    // ---- 除法器的一拍（恢复余数法）：rem*2 + 下一位 → 试减 --------------------
    wire [11:0] rsh = {rem, sh[30]};
    wire        ge  = (rsh >= {1'b0, dvs});
    //  商的四舍五入（2*rem ≥ 除数则进位）+ 显示饱和（9999 = 999.9，窗口只有三位整数）
    wire [16:0] qr  = ({rem[9:0], 1'b0} >= {1'b0, dvs}) ? (quot + 17'd1) : quot;
    wire [16:0] vq  = (qr > 17'd9999) ? 17'd9999 : qr;

    // ---- 5 格里的第 wc 格写什么 ---------------------------------------------
    //  格式：一位小数、右对齐、前导零留空；`-` 只出现在空态时的最后一格。
    reg  [7:0] cell_ch;
    always @* begin
        case (wc)
            3'd0:    cell_ch = (val >= 17'd1000) ? (CH_D0 + d3) : CH_SP;
            3'd1:    cell_ch = (val >= 17'd100)  ? (CH_D0 + d2) : CH_SP;
            //   整数位至少留一个 0：0.3 要打成 `  0.3`，不能打成 `   .3`
            3'd2:    cell_ch = (val >= 17'd10)   ? (CH_D0 + d1) : CH_D0;
            3'd3:    cell_ch = CH_DOT;
            default: cell_ch = (CH_D0 + d0);
        endcase
        if (ph && sig_bad) cell_ch = (wc == 3'd4) ? CH_MINUS : CH_SP;
    end

    wire [11:0] cell_addr = ph ? {RT_ROW, RT_COL + wc}
                              : {EQ_ROW, EQ_COL + wc};

    // ---- 主状态机 -----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            iv    <= 12'd2;
            dv    <= 4'd1;
            fhz   <= 20'd0;
            ph    <= 1'b0;
            sh    <= 31'd0;
            rem   <= 11'd0;
            dvs   <= 11'd1;
            quot  <= 15'd0;
            nbit  <= 6'd0;
            val   <= 14'd0;
            m     <= 14'd0;
            d3    <= 4'd0;
            d2    <= 4'd0;
            d1    <= 4'd0;
            d0    <= 4'd0;
            fcnt  <= 2'd0;
            wc    <= 3'd0;
            waddr <= 12'd0;
            wdata <= 8'd0;
            we    <= 1'b0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            // 默认：不写、done 是单拍
            we   <= 1'b0;
            done <= 1'b0;

            case (st)
            // ---------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (pnl_on && start) begin
                    iv   <= iv_w;
                    dv   <= dv_w;
                    fhz  <= fhz_w;
                    busy <= 1'b1;
                    st   <= S_LAT;
                end
            end
            // ---------------------------------------------------------------
            // 锁存除法初值：相位 0 = 等效倍率（iv*10 ÷ dv，12 拍）
            S_LAT: begin
                ph   <= 1'b0;
                //  ★ 被除数必须**左对齐**到 sh[30]（恢复余数法每拍取 sh[30]）：
                //    12 位被除数 ⇒ 左移 19 位。第一版写成 {19'd0, iv*10} 把被除数
                //    塞在低位，每拍取到的都是 0 ⇒ 商恒为 0（仿真实得 `  .0`）。
                sh   <= {iv * 4'd10, 19'd0};      // iv*10 ≤ 2560，12 位 + 19 位 = 31
                dvs  <= {7'd0, dv};
                nbit <= 6'd12;
                rem  <= 11'd0;
                quot <= 15'd0;
                st   <= S_DIV;
            end
            // ---------------------------------------------------------------
            S_DIV: begin
                if (nbit != 6'd0) begin
                    rem  <= ge ? (rsh - {1'b0, dvs}) : rsh;
                    quot <= {quot[15:0], ge};
                    sh   <= {sh[29:0], 1'b0};
                    nbit <= nbit - 6'd1;
                end else begin
                    st <= S_RND;
                end
            end
            // ---------------------------------------------------------------
            // 四舍五入到一位小数：2*rem >= dv 则商加一
            S_RND: begin
                val  <= vq;
                m    <= vq;
                fcnt <= 2'd0;
                st   <= S_FMT;
            end
            // ---------------------------------------------------------------
            // 四位十进制拆位（每拍一位，串行推进；每拍只有一条并行比较链）
            //   ★ 减掉的必须真是「位权 × 位值」，**不能直接用移位当 ×100/×1000**：
            //     shift 的单位是 2 的幂。第一版写成 `{d,8'd0}`（= ×256）与 `{d,10'd0}`
            //     （= ×1024），333 减 3×256 直接借位，屏上打出 ` 39.3`（实测）。
            //     ×1000 = 1024 - 16 - 8；×100 = 64 + 32 + 4；×10 = 8 + 2。
            S_FMT: begin
                case (fcnt)
                    2'd0: begin d3 <= c_div1000(m);
                                m <= m - ({c_div1000(m), 10'd0} -
                                          {c_div1000(m), 4'd0} -
                                          {c_div1000(m), 3'd0}); end
                    2'd1: begin d2 <= c_div100(m);
                                m <= m - ({c_div100(m), 6'd0} +
                                          {c_div100(m), 5'd0} +
                                          {c_div100(m), 2'd0}); end
                    2'd2: begin d1 <= c_div10(m);   m <= m - ({c_div10(m), 3'b0} +
                                                               {c_div10(m), 1'b0}); end
                    default: begin d0 <= m[3:0];   end
                endcase
                if (fcnt == 2'd3) begin
                    wc <= 3'd0;
                    st <= S_WR;
                end else begin
                    fcnt <= fcnt + 2'd1;
                end
            end
            // ---------------------------------------------------------------
            // 写 5 格；hold 时原地等（组合 we 的代价就是这一条）
            S_WR: begin
                if (!hold) begin
                    we    <= 1'b1;
                    waddr <= cell_addr;
                    wdata <= cell_ch;
                    if (wc == 3'd4) st <= S_NEXT;
                    else            wc <= wc + 3'd1;
                end
            end
            // ---------------------------------------------------------------
            // 相位 0 做完 → 起相位 1（4*iv*f ÷ (100*dv)，24 拍）
            S_NEXT: begin
                if (!ph) begin
                    ph   <= 1'b1;
                    //  23 位被除数左移 8 位对齐到 bit30；除数 = 100×dv（100..800）
                    sh   <= {dvnd_rt, 8'd0};
                    dvs  <= {1'b0, dv} * 11'd100;
                    nbit <= 6'd23;
                    rem  <= 11'd0;
                    quot <= 15'd0;
                    st   <= S_DIV;
                end else begin
                    st <= S_DONE;
                end
            end
            // ---------------------------------------------------------------
            S_DONE: begin
                done <= 1'b1;
                busy <= 1'b0;
                st   <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
