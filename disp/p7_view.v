// ===========================================================================
// disp/p7_view.v -- P7 标定页（v85：相对误差曲线）
//
// v85 重写要点（v84 的绝对幅值带子已废弃）：
//   1) 每帧把 128 个电角度箱的 amp_sq 中值记成 min/max（沿用 v84 的累积机制），
//      dump 时换算成"相对全帧均值的偏差"：
//          mean = Σ(lo+hi)/(2·n)                      （只统计有样本的箱）
//          dev  = (bin - mean) * inv >> 10            （单位 0.1‰ = 0.01%）
//          inv  = 10240000 / mean                     （饱和 0xFFFF）
//      不直接画幅度，是因为幅度本身跟转速/温度一起漂，误差只能看"相对均值"。
//   2) 纵轴零线居中、满量程 ±2%（±20‰）：
//          y = 120 - 0.6·|dev|   ⇒ +20‰→0、0→120、-20‰→239
//      超量程的样本钳在框内，并在曲线区右上角一格标 '▲'（不许静默裁剪）。
//   3) 底栏换成同口径的两个统计量（单位 %，两位小数）：
//          P-P = (max_dev - min_dev)/100
//          RMS ≈ 1.1128·mean|dev|/100   （平均绝对偏差近似，见 §5 的说明）
//   4) 帧首把当前箱（cur_lo/cur_hi）先落盘，消掉换帧时左端的台阶；
//      从没访问过的箱 dump 成 dev=0（y=120），不再残留上一帧。
//
// 时序：dump 相切成两级（先寄存 dev，再算行号/统计），RMS 不再做平方与开方，
//       否则 mean→DSP×2→进位链的 38 级组合路径会把 WNS 打到 -1.3 ns（见 v85.1）。
// ===========================================================================
`timescale 1ns / 1ps

module p7_view (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,          // 每帧脉冲一次
    input  wire        hold,           // 高：暂停写 lab（本版由上层接 0）

    input  wire [15:0] angle,          // 电角度（低 9 位给 128 箱）
    input  wire [31:0] amp_sq,         // 抽头 v15：s^2+c^2（Q2.30）

    input  wire [31:0] amp_low_sq,     // v85 起不用（保留端口兼容旧连线）
    input  wire [31:0] amp_high_sq,
    input  wire        calib_busy,

    input  wire [15:0] ofs_s, ofs_c,   // 参数（有符号）
    input  wire [15:0] gain_s, gain_c, // 增益（Q15）
    input  wire [15:0] phase_k,
    input  wire [3:0]  shift,

    // 分箱累积 RAM（128 x 32：{hi, lo}）
    output reg         acc_we,
    output reg  [6:0]  acc_waddr,
    output reg  [31:0] acc_wdata,
    output wire [6:0]  acc_raddr,
    input  wire [31:0] acc_rdata,

    // 两条曲线的行号 RAM（128 x 16：{hi_row, lo_row}）
    output reg         bef_we,
    output reg  [6:0]  bef_waddr,
    output reg  [15:0] bef_wdata,
    output reg         aft_we,
    output reg  [6:0]  aft_waddr,
    output reg  [15:0] aft_wdata,

    // 文字写口
    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,

    output reg         busy,
    output reg         done
);

    // 字符码：与 tools/gen_text_ram.py 的 ASCII_CHARS 顺序一致
    localparam [7:0] CH_SP   = 8'd0;
    localparam [7:0] CH_DP   = 8'd1;
    localparam [7:0] CH_MI   = 8'd2;   // '-'
    localparam [7:0] CH_PL   = 8'd3;   // '+'
    localparam [7:0] CH_ZERO = 8'd8;   // '0'
    localparam [7:0] CH_UP   = 8'd49;  // '▲'（字库没有 '!' 与 '>'，用它当溢出标记）

    localparam [16:0] DEV_CLMP = 17'd30000;   // 统计口径上限 ±300.0%
    localparam [16:0] DEV_FS   = 17'd200;     // ±2% 满量程 = ±200 个 0.1‰
    localparam [23:0] INV_NUM  = 24'd10_240_000;  // 10000 << 10

    // 状态编码（必须声明在所有引用它的 always 之前）
    localparam [3:0] S_IDLE = 4'd0, S_PREP = 4'd1, S_DD   = 4'd2, S_WR   = 4'd3,
                     S_NEXT = 4'd4, S_FW   = 4'd5, S_MEAN = 4'd6, S_MDIV = 4'd7,
                     S_INVD = 4'd8, S_DUMP = 4'd9, S_SQ0  = 4'd10, S_SQ1 = 4'd11,
                     S_MARK = 4'd12, S_END = 4'd13;

    reg  [3:0]  state;
    reg  [2:0]  fld;          // 0..3 参数、4 P-P、5 RMS
    reg  [2:0]  p;            // 字段内第几格
    reg  [4:0]  dd_cnt;
    reg  [15:0] dd_bin;
    reg  [19:0] dd_bcd;
    reg  [15:0] f_mag;
    reg         f_neg, fmt_gain, fmt_stat;
    reg  [7:0]  dp;
    reg         dump_to_aft;
    reg         frz, mode;
    reg         clr_run;
    reg  [7:0]  clr_i;
    reg         cb_q;
    reg         flush_req;
    reg         start_r;

    wire        cb_rise = calib_busy & ~cb_q;
    wire        cb_fall = ~calib_busy & cb_q;

    // -----------------------------------------------------------------------
    // 1) 分箱累积：128 箱 × {hi, lo}
    // -----------------------------------------------------------------------
    reg  [6:0]  cur_bin;
    reg  [15:0] cur_lo, cur_hi;
    reg         have;
    reg         bin_we;
    reg  [6:0]  bin_wa;
    reg  [31:0] bin_wd;

    wire [6:0]  in_bin = angle[15:9];
    wire [15:0] mag    = amp_sq[30:15];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_bin <= 7'd0; cur_lo <= 16'd0; cur_hi <= 16'd0; have <= 1'b0;
            bin_we  <= 1'b0; bin_wa <= 7'd0;  bin_wd <= 32'd0;
        end else begin
            bin_we <= 1'b0;
            if (in_bin != cur_bin) begin
                if (have) begin
                    bin_we <= 1'b1;
                    bin_wa <= cur_bin;
                    bin_wd <= {cur_hi, cur_lo};
                end
                cur_bin <= in_bin;
                cur_lo  <= mag;
                cur_hi  <= mag;
                have    <= 1'b1;
            end else begin
                if (mag < cur_lo) cur_lo <= mag;
                if (mag > cur_hi) cur_hi <= mag;
                have <= 1'b1;
            end
        end
    end

    // 标定忙沿：上升沿清箱并冻结"前"曲线，下降沿之后转画"后"曲线
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cb_q <= 1'b0; frz <= 1'b0; mode <= 1'b0;
            clr_run <= 1'b0; clr_i <= 8'd0;
        end else begin
            cb_q <= calib_busy;
            if (cb_rise) begin
                frz     <= 1'b1;
                clr_run <= 1'b1;
                clr_i   <= 8'd0;
            end else if (clr_run) begin
                clr_i <= clr_i + 8'd1;
                if (clr_i == 8'd127) clr_run <= 1'b0;
            end
            if (cb_fall) begin
                frz  <= 1'b0;
                mode <= 1'b1;
            end
        end
    end

    // 累积 RAM 写口：清箱 > 帧首落盘 > 换箱
    always @* begin
        acc_we   = 1'b0;
        acc_waddr = 7'd0;
        acc_wdata = 32'd0;
        if (clr_run) begin
            acc_we    = 1'b1;
            acc_waddr = clr_i[6:0];
            acc_wdata = {16'd0, 16'hFFFF};      // lo > hi ⇒ "没有样本"
        end else if (bin_we) begin
            acc_we    = 1'b1;
            acc_waddr = bin_wa;
            acc_wdata = bin_wd;
        end else if (flush_req && have) begin
            acc_we    = 1'b1;
            acc_waddr = cur_bin;
            acc_wdata = {cur_hi, cur_lo};
        end
    end

    // -----------------------------------------------------------------------
    // 2) 定点除法（三次串行复用：mean / inv / RMS）
    // -----------------------------------------------------------------------
    reg  [23:0] dv_a;
    reg  [15:0] dv_b;
    reg         dv_start;
    reg  [1:0]  dv_st;
    wire [23:0] dv_quo;
    wire        dv_done;

    fixed_div #(.W(24), .DW(16)) u_div (
        .clk(clk), .rst_n(rst_n), .start(dv_start),
        .dividend(dv_a), .divisor(dv_b),
        .quotient(dv_quo), .remainder(), .busy(), .done(dv_done)
    );

    // -----------------------------------------------------------------------
    // 3) 文字格式化
    // -----------------------------------------------------------------------
    function [3:0] add3;
        input [3:0] d;
        begin
            add3 = (d >= 4'd5) ? (d + 4'd3) : d;
        end
    endfunction

    function [15:0] pow10;
        input [3:0] n;
        begin
            case (n)
                4'd0: pow10 = 16'd1;
                4'd1: pow10 = 16'd10;
                4'd2: pow10 = 16'd100;
                4'd3: pow10 = 16'd1000;
                4'd4: pow10 = 16'd10000;
                default: pow10 = 16'd1;
            endcase
        end
    endfunction

    // 0.6 * m（m = |dev|，0..200，单位 0.1‰）。0.6*65536 = 39321.6
    function [8:0] y_off;
        input [7:0] m;
        reg [24:0] pr;
        begin
            pr    = {17'd0, m} * 25'd39322;
            y_off = pr[24:16];
        end
    endfunction

    wire [19:0] dd_adj = { add3(dd_bcd[19:16]), add3(dd_bcd[15:12]),
                           add3(dd_bcd[11:8]),  add3(dd_bcd[7:4]),
                           add3(dd_bcd[3:0]) };



    wire        p_sign  = (p == 3'd0);
    wire [3:0]  cur_di  = p_sign ? 4'd0 : (4'd5 - {1'b0, p});
    wire [3:0]  cur_dig = dd_bcd[{cur_di, 2'b0} +: 4];
    wire        cur_vis = p_sign || (cur_di == 4'd0) || (f_mag >= pow10(cur_di));
    wire [7:0]  cur_ch_std = p_sign
                             ? (f_neg ? CH_MI : CH_PL)
                             : (cur_vis ? (CH_ZERO + {4'd0, cur_dig}) : CH_SP);

    // GAIN：五位 BCD 的 [15:12] 是整数位，[11:8]/[7:4]/[3:0] 是三位小数 ⇒ "d.ddd"
    wire [7:0]  gain_ch = (p == 3'd0) ? CH_SP :
                          (p == 3'd1) ? (CH_ZERO + {4'd0, dd_bcd[15:12]}) :
                          (p == 3'd2) ? CH_DP :
                          (p == 3'd3) ? (CH_ZERO + {4'd0, dd_bcd[11:8]}) :
                          (p == 3'd4) ? (CH_ZERO + {4'd0, dd_bcd[7:4]}) :
                                        (CH_ZERO + {4'd0, dd_bcd[3:0]});

    // 统计量："ddd.dd"（0.01% 单位，高两位前导零抑制）
    wire [7:0]  stat_ch = (p == 3'd0) ? ((dd_bcd[19:16] != 4'd0)
                                         ? (CH_ZERO + {4'd0, dd_bcd[19:16]}) : CH_SP) :
                          (p == 3'd1) ? (((dd_bcd[19:16] != 4'd0) || (dd_bcd[15:12] != 4'd0))
                                         ? (CH_ZERO + {4'd0, dd_bcd[15:12]}) : CH_SP) :
                          (p == 3'd2) ? (CH_ZERO + {4'd0, dd_bcd[11:8]}) :
                          (p == 3'd3) ? CH_DP :
                          (p == 3'd4) ? (CH_ZERO + {4'd0, dd_bcd[7:4]}) :
                                        (CH_ZERO + {4'd0, dd_bcd[3:0]});

    wire [7:0]  cur_ch = fmt_stat ? stat_ch : (fmt_gain ? gain_ch : cur_ch_std);

    function [5:0] f_row;
        input [2:0] f;
        begin
            case (f)
                3'd0: f_row = 6'd10;
                3'd1: f_row = 6'd14;
                3'd2: f_row = 6'd18;
                3'd3: f_row = 6'd22;
                default: f_row = 6'd31;
            endcase
        end
    endfunction

    function [5:0] f_col;
        input [2:0] f;
        begin
            case (f)
                3'd0: f_col = 6'd52;
                3'd1: f_col = 6'd52;
                3'd2: f_col = 6'd52;
                3'd3: f_col = 6'd52;
                3'd4: f_col = 6'd9;
                default: f_col = 6'd23;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // 4) 统计量寄存器与 dump 的两级流水
    // -----------------------------------------------------------------------
    reg  [7:0]  cnt;
    reg  [24:0] sum2;         // Σ(lo+hi)
    reg  [15:0] mean_q;
    reg  [15:0] inv_q;
    reg  signed [16:0] pk_max, pk_min;
    reg  [16:0] pk_c;
    reg  [16:0] rms_c;
    // 这一帧要格式化的原值：0/1 = 有符号参数，2/3 = Q15 增益，4/5 = 统计量
    wire [15:0] src_val = (fld == 3'd0) ? ofs_s  :
                          (fld == 3'd1) ? ofs_c  :
                          (fld == 3'd2) ? gain_s :
                          (fld == 3'd3) ? gain_c :
                          (fld == 3'd4) ? pk_c   : rms_c;

    // 送进 double-dabble 的值：参数取 |raw|，增益取 milli（d.ddd），统计量原样
    wire [31:0] gain_milli = ({16'd0, src_val} * 32'd1000) >> 15;
    wire [15:0] conv_val   = (fld <= 3'd1) ? (src_val[15] ? (~src_val + 16'd1) : src_val)
                            : (fld <= 3'd3) ? gain_milli[15:0]
                                            : src_val;
    reg  [31:0] absum;        // Σ|dev_mid|
    reg         ovf;

    // RMS ≈ 1.1128·mean|dev| = (Σ|dev|·111/cnt)/10，先乘后除避免截断丢精度
    wire [23:0] absum_m    = (absum > 32'd100_000) ? 24'd100_000 : absum[23:0];
    wire [23:0] absum_x111 = absum_m * 24'd111;

    wire [15:0] acc_lo = acc_rdata[15:0];
    wire [15:0] acc_hi = acc_rdata[31:16];
    wire        acc_ok = (acc_lo <= acc_hi);

    // 第 1 级：一次乘法，结果直接进寄存器
    wire        s_lo_neg = (acc_lo < mean_q);
    wire [16:0] s_lo_abs = s_lo_neg ? ({1'b0, mean_q} - {1'b0, acc_lo})
                                    : ({1'b0, acc_lo} - {1'b0, mean_q});
    wire [33:0] s_lo_prd = s_lo_abs * inv_q;
    wire [16:0] s_lo_q   = (s_lo_prd[33:10] > 24'd30000) ? DEV_CLMP
                                                         : s_lo_prd[26:10];
    wire        s_hi_neg = (acc_hi < mean_q);
    wire [16:0] s_hi_abs = s_hi_neg ? ({1'b0, mean_q} - {1'b0, acc_hi})
                                    : ({1'b0, acc_hi} - {1'b0, mean_q});
    wire [33:0] s_hi_prd = s_hi_abs * inv_q;
    wire [16:0] s_hi_q   = (s_hi_prd[33:10] > 24'd30000) ? DEV_CLMP
                                                         : s_hi_prd[26:10];

    reg  signed [17:0] d1_lo, d1_hi;
    reg                d1_ok;

    // 第 2 级：只用寄存值
    wire        dlo_neg = d1_lo[17];
    wire        dhi_neg = d1_hi[17];
    wire [16:0] qlo     = dlo_neg ? (-d1_lo[16:0]) : d1_lo[16:0];
    wire [16:0] qhi     = dhi_neg ? (-d1_hi[16:0]) : d1_hi[16:0];

    wire signed [16:0] dev_a = dlo_neg ? (-$signed({1'b0, qlo})) : $signed({1'b0, qlo});
    wire signed [16:0] dev_b = dhi_neg ? (-$signed({1'b0, qhi})) : $signed({1'b0, qhi});

    wire signed [16:0] dev_mx = (dev_a > dev_b) ? dev_a : dev_b;
    wire signed [16:0] dev_mn = (dev_a < dev_b) ? dev_a : dev_b;

    wire [16:0] dev_mid_abs = ({1'b0, qlo} + {1'b0, qhi}) >> 1;

    wire        ovf_now = d1_ok && ((qlo > DEV_FS) || (qhi > DEV_FS));

    wire [7:0]  lo_m200 = (qlo > DEV_FS) ? 8'd200 : qlo[7:0];
    wire [7:0]  hi_m200 = (qhi > DEV_FS) ? 8'd200 : qhi[7:0];
    wire [8:0]  lo_off9 = y_off(lo_m200);
    wire [8:0]  hi_off9 = y_off(hi_m200);
    wire [8:0]  lo_row9 = dlo_neg ? (9'd120 + lo_off9) : (9'd120 - lo_off9);
    wire [8:0]  hi_row9 = dhi_neg ? (9'd120 + hi_off9) : (9'd120 - hi_off9);
    wire [7:0]  y_lo    = !d1_ok ? 8'd120 : ((lo_row9 > 9'd239) ? 8'd239 : lo_row9[7:0]);
    wire [7:0]  y_hi    = !d1_ok ? 8'd120 : ((hi_row9 > 9'd239) ? 8'd239 : hi_row9[7:0]);

    // 文字写口
    always @* begin
        we    = ((state == S_WR) || (state == S_MARK)) && !hold;
        waddr = (state == S_MARK) ? {6'd9, 6'd37} : ({f_row(fld), f_col(fld)} + {9'd0, p});
        wdata = (state == S_MARK) ? (ovf ? CH_UP : CH_SP) : cur_ch;
    end


    // -----------------------------------------------------------------------
    // 5) 状态机
    // -----------------------------------------------------------------------
    reg [6:0] raddr_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; p <= 3'd0; fld <= 3'd0; dd_cnt <= 5'd0;
            dd_bin <= 16'd0; dd_bcd <= 20'd0; f_mag <= 16'd0;
            f_neg <= 1'b0; fmt_gain <= 1'b0; fmt_stat <= 1'b0;
            dp <= 8'd0; dump_to_aft <= 1'b0; flush_req <= 1'b0; start_r <= 1'b0;
            cnt <= 8'd0; sum2 <= 25'd0; mean_q <= 16'd0; inv_q <= 16'd0;
            pk_max <= -17'sd30000; pk_min <= 17'sd30000;
            pk_c <= 17'd0; rms_c <= 17'd0; absum <= 32'd0; ovf <= 1'b0;
            d1_lo <= 18'sd0; d1_hi <= 18'sd0; d1_ok <= 1'b0;
            dv_a <= 24'd0; dv_b <= 16'd1; dv_start <= 1'b0; dv_st <= 2'd0;
            raddr_r <= 7'd0;
            bef_we <= 1'b0; bef_waddr <= 7'd0; bef_wdata <= 16'd0;
            aft_we <= 1'b0; aft_waddr <= 7'd0; aft_wdata <= 16'd0;
            busy <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)

                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy        <= 1'b1;
                        fld         <= 3'd0;
                        dump_to_aft <= mode;      // 帧首锁死画哪条
                        ovf         <= 1'b0;
                        state       <= S_PREP;
                    end
                end

                S_PREP: begin
                    // src_val/conv_val 是组合译码（fld 决定），这里一次性打进寄存器
                    dd_bin   <= conv_val;
                    f_mag    <= conv_val;
                    f_neg    <= (fld <= 3'd1) && src_val[15];
                    fmt_gain <= (fld == 3'd2) || (fld == 3'd3);
                    fmt_stat <= (fld >= 3'd4);
                    dd_bcd   <= 20'd0;
                    dd_cnt   <= 5'd0;
                    state    <= S_DD;
                end

                S_DD: begin
                    // 16 拍 double-dabble：每拍 {add3, 左移一位}
                    dd_bcd <= {dd_adj[18:0], dd_bin[15]};
                    dd_bin <= {dd_bin[14:0], 1'b0};
                    if (dd_cnt == 5'd15) begin
                        dd_cnt <= 5'd0;
                        p      <= 3'd0;
                        state  <= S_WR;
                    end else begin
                        dd_cnt <= dd_cnt + 5'd1;
                        state  <= S_DD;
                    end
                end

                S_WR: begin
                    if (p == 3'd5) begin
                        p     <= 3'd0;
                        state <= S_NEXT;
                    end else begin
                        p <= p + 3'd1;
                    end
                end

                S_NEXT: begin
                    if (fld == 3'd3) begin
                        if (frz) begin
                            state <= S_END;          // 冻结期只显示参数，不 dump
                        end else begin
                            dp        <= 8'd0;
                            flush_req <= 1'b0;
                            state     <= S_FW;
                        end
                    end else if (fld == 3'd5) begin
                        state <= S_MARK;
                    end else begin
                        fld   <= fld + 3'd1;
                        state <= S_PREP;
                    end
                end

                // 帧首：把当前箱（还没写回的那个）落盘，消掉左端台阶
                S_FW: begin
                    if (dp == 8'd0) begin
                        flush_req <= 1'b1;
                        dp        <= 8'd1;
                    end else if (dp == 8'd4) begin
                        flush_req <= 1'b0;
                        dp        <= 8'd0;
                        state     <= S_MEAN;
                    end else begin
                        dp <= dp + 8'd1;
                    end
                end

                // 第一遍：求全帧均值（只统计有样本的箱）
                S_MEAN: begin
                    if (dp == 8'd0) begin
                        raddr_r <= 7'd0;
                        sum2    <= 25'd0;
                        cnt     <= 8'd0;
                        dp      <= 8'd1;
                    end else begin
                        if (dp <= 8'd127) raddr_r <= dp[6:0];
                        if ((dp >= 8'd2) && (dp <= 8'd129) && acc_ok) begin
                            sum2 <= sum2 + {1'b0, acc_lo} + {1'b0, acc_hi};
                            cnt  <= cnt + 8'd1;
                        end
                        if (dp == 8'd130) begin
                            dp    <= 8'd0;
                            dv_st <= 2'd0;
                            state <= S_MDIV;
                        end else begin
                            dp <= dp + 8'd1;
                        end
                    end
                end

                // mean = sum2 / (2*cnt)
                S_MDIV: begin
                    if (dv_st == 2'd0) begin
                        dv_a     <= sum2[23:0];
                        dv_b     <= (cnt == 8'd0) ? 16'd1 : ({7'd0, cnt, 1'b0});
                        dv_start <= 1'b1;
                        dv_st    <= 2'd1;
                    end else if (dv_st == 2'd1) begin
                        dv_start <= 1'b0;
                        dv_st    <= 2'd2;
                    end else if (dv_done) begin
                        mean_q <= (dv_quo[23:16] != 8'd0) ? 16'hFFFF : dv_quo[15:0];
                        dv_st  <= 2'd0;
                        state  <= S_INVD;
                    end
                end

                // inv = 10240000 / mean
                S_INVD: begin
                    if (dv_st == 2'd0) begin
                        dv_a     <= INV_NUM;
                        dv_b     <= (mean_q == 16'd0) ? 16'd1 : mean_q;
                        dv_start <= 1'b1;
                        dv_st    <= 2'd1;
                    end else if (dv_st == 2'd1) begin
                        dv_start <= 1'b0;
                        dv_st    <= 2'd2;
                    end else if (dv_done) begin
                        inv_q <= (dv_quo[23:16] != 8'd0) ? 16'hFFFF : dv_quo[15:0];
                        dv_st <= 2'd0;
                        dp    <= 8'd0;
                        state <= S_DUMP;
                    end
                end

                // 第二遍：逐箱算 dev -> 行号 -> 两条曲线 RAM + 统计
                S_DUMP: begin
                    if (dp == 8'd0) begin
                        bef_we    <= 1'b0;
                        aft_we    <= 1'b0;
                        raddr_r   <= 7'd0;
                        pk_max    <= -17'sd30000;
                        pk_min    <=  17'sd30000;
                        absum     <= 32'd0;
                        d1_lo     <= 18'sd0;
                        d1_hi     <= 18'sd0;
                        d1_ok     <= 1'b0;
                        dp        <= 8'd1;
                    end else begin
                        if (dp <= 8'd127) raddr_r <= dp[6:0];
                        if ((dp >= 8'd2) && (dp <= 8'd129)) begin
                            d1_lo <= s_lo_neg ? (-$signed({1'b0, s_lo_q}))
                                              :   $signed({1'b0, s_lo_q});
                            d1_hi <= s_hi_neg ? (-$signed({1'b0, s_hi_q}))
                                              :   $signed({1'b0, s_hi_q});
                            d1_ok <= acc_ok;
                        end
                        if (dp >= 8'd3) begin
                            if (dump_to_aft) begin
                                aft_we    <= 1'b1;
                                aft_waddr <= dp[6:0] - 7'd3;
                                aft_wdata <= {y_hi, y_lo};
                            end else begin
                                bef_we    <= 1'b1;
                                bef_waddr <= dp[6:0] - 7'd3;
                                bef_wdata <= {y_hi, y_lo};
                            end
                            if (d1_ok) begin
                                if (dev_mx > pk_max) pk_max <= dev_mx;
                                if (dev_mn < pk_min) pk_min <= dev_mn;
                                absum <= absum + {15'd0, dev_mid_abs};
                            end
                            if (ovf_now) ovf <= 1'b1;
                        end
                        if (dp == 8'd130) begin
                            dp    <= 8'd0;
                            dv_st <= 2'd0;
                            state <= S_SQ0;
                        end else begin
                            dp <= dp + 8'd1;
                        end
                    end
                end

                // RMS ≈ 1.1128·mean|dev|：先 mean|dev| = absum/cnt，再 ×111/10
                S_SQ0: begin
                    bef_we <= 1'b0;
                    aft_we <= 1'b0;
                    if (dv_st == 2'd0) begin
                        dv_a     <= absum_x111;
                        dv_b     <= (cnt == 8'd0) ? 16'd1 : {8'd0, cnt};
                        dv_start <= 1'b1;
                        dv_st    <= 2'd1;
                    end else if (dv_st == 2'd1) begin
                        dv_start <= 1'b0;
                        dv_st    <= 2'd2;
                    end else if (dv_done) begin
                        dv_a     <= (dv_quo > 24'd30000) ? 24'd30000 : dv_quo;
                        dv_b     <= 16'd10;
                        dv_start <= 1'b1;
                        dv_st    <= 2'd3;
                        state    <= S_SQ1;
                    end
                end

                S_SQ1: begin
                    if (dv_st == 2'd3) begin
                        dv_start <= 1'b0;
                        dv_st    <= 2'd0;
                    end else if (dv_done) begin
                        rms_c <= (dv_quo[23:17] != 7'd0) ? 17'h0_FFFF : dv_quo[16:0];
                        pk_c  <= (pk_max > pk_min) ? (pk_max - pk_min) : 17'd0;
                        dp    <= 8'd0;
                        state <= S_PREP;
                        fld   <= 3'd4;
                    end
                end

                S_MARK: state <= S_END;

                default: begin   // S_END
                    bef_we <= 1'b0;
                    aft_we <= 1'b0;
                    done   <= 1'b1;
                    busy   <= 1'b0;
                    state  <= S_IDLE;
                end
            endcase
        end
    end

    // 读地址走寄存器（RAM 单级寄存输出，数据在 dp+2 有效）
    assign acc_raddr = raddr_r;
endmodule

`default_nettype wire
