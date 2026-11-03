//=============================================================================
//  disp/p2_badge.v  --  P2 右下角四枚徽标（VPP-PC / F-HZ / DT-US / DV-PC）
//
//  这一页的波形来自遥测帧里的 s_n / c_n（16 bit 正弦/余弦，遥测帧率 10 kHz
//  ⇒ 100 µs 一个样本，屏上那行"等效采样 100US"说的就是它）。四枚徽标全部是
//  **对同一条数据流做真实测量**，屏幕上没有一个常数：
//
//    VPP-PC  A 通道一帧内的 (max - min)，换算成占波形带宽（199 px）的百分比
//    F-HZ    A 通道上升过零的周期：帧内**首末两个过零的时间差**除以过零个数
//    DT-US   每一对"A 上升过零 → 其后第一个 B 上升过零"的间隔，帧内取平均
//    DV-PC   A、B 两个通道 Vpp 之差的绝对值，同一把尺子量
//
//  ★ 为什么不摆常数：一个"永远是 0.0"的徽标比没有徽标更坏 —— 它看起来像
//    测出来的（P6 那块写口一直为空的 RAM 把复位默认值伪装成"通了"，见 U-14）。
//    spec §4.5 要求这四枚徽标，但没规定必须由编码器算 —— 显示侧能测的就自己测，
//    不新增遥测带宽、不动 rtl/。
//
//  ★ 时间基准：帧内自由计数器 t（帧首清零；一帧 853,440 拍，24 位有余量）。
//    过零的**观测**只能发生在遥测样本更新的那一拍（值变化时），而更新栅格是
//    100 µs —— 所以单次过零带 ±100 µs 量化误差。这里取**区间中点**当做过零时刻，
//    把误差变成零均值的 ±50 µs 抖动（F 与 DT 都是帧内平均，收敛到 1% 量级）；
//    "取新样本那一拍"则是系统性 +50 µs，不随帧数收敛。这一条要写进 docs/15 的
//    复检清单：它是"等效采样"口径下的频率/相位，不是 ns 级示波器的读数。
//
//  ★ 除法复用 disp/fixed_div.v（W=40 / DW=32），每帧 4 次；十进制用
//    double-dabble（17 位二进制 → 20 位 BCD = 5 位十进制），每帧 4 次。
//    合计约 4 x (40 + 17 + 12) ≈ 280 拍，而垂直消隐有 47,040 拍。
//
//  ★ 字段表（与 tools/gen_text_ram.py 的 P2_LAB 是**两处共同契约**）：
//      节距 10 格（160 px），四枚字段起点 = 格列 28 / 38 / 48 / 58
//                          （x 448 / 608 / 768 / 928）
//      六格字段末格 = 列 33 / 43 / 53 / 63 ⇒ 最右一枚贴内容区右沿 x 1023
//      lab 行 35 -> 静态标签 VPP-PC / F-HZ / DT-US / DV-PC，从字段起始列开始
//      lab 行 36 -> 本模块每帧覆写的六个字符，**与标签同一左沿**（列 28/38/48/58）
//    六个字符固定排成 "dddd.d"（值 x10，右贴、前导空格抑制），
//    所以最小可显示 0.0、最大 9999.9（超出按 9999.9 截顶）。
//    ★ 第一版按"各占 6 格"排在列 40/46/52/58，六格字段配六格节距**没有间隙**，
//      出图后标签连成 "VPP-PCF-HZ"（见 _disp_work/page_p2.png）—— 因此改成
//      10 格节距，字段整体右移贴到内容区右沿（第 36 行左边的 "等效采样 100US"
//      只到列 19，列 28..63 这 36 格放 4 x 10 格绰绰有余）。
//    改列位置必须同时改 gen_text_ram.py 的 P2_LAB，反之亦然。
//
//  ★ 复位后第一个窗口还没冻结，四枚都显示 0.0 —— 这是设计如此（没有数据），
//    与 p5_view 的处理一致。
//=============================================================================
`default_nettype none

module p2_badge (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,             // vf_start：帧末一拍（垂直消隐起点）
    // v50（㊼）B3：空态 —— sig_bad 时四枚徽标逐格写 '-'（CH_MINUS = 2）。
    input  wire        sig_bad,
    input  wire signed [15:0] sn,         // 遥测 sin（原始值，与 wave_trace 同源）
    input  wire signed [15:0] cn,         // 遥测 cos

    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    localparam [5:0] BADGE_ROW = 6'd36;   // 数值所在格行（标签在 35）

    // 字符码：与 tools/gen_font_rom.py 的 CHARS 的 ASCII 段一致
    //   " .-+/:=^0123456789ABC..."  ->  ' '=0, '.'=1, '0'=8
    localparam [7:0] CH_SP   = 8'd0;
    localparam [7:0] CH_DOT  = 8'd1;
    localparam [7:0] CH_ZERO = 8'd8;

    // ---------------------------------------------------------------------
    // 1. 帧内时基（帧首清零）
    // ---------------------------------------------------------------------
    reg [23:0] t;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      t <= 24'd0;
        else if (start)  t <= 24'd0;
        else             t <= t + 24'd1;
    end

    // ---------------------------------------------------------------------
    // 2. 样本 → 屏上行号（与 disp/wave_trace.v **同一式**；两处共同契约）
    //    波形带 200 px（0..199），99 是零线。
    // ---------------------------------------------------------------------
    function [7:0] cl_px;
        input signed [15:0] v;
        reg   signed [15:0] r;
        begin
            r = 16'sd99 - (v >>> 8);
            if      (r < 16'sd0)   cl_px = 8'd0;
            else if (r > 16'sd199) cl_px = 8'd199;
            else                   cl_px = r[7:0];
        end
    endfunction

    wire [7:0] ra = cl_px(sn);
    wire [7:0] rb = cl_px(cn);

    // ---------------------------------------------------------------------
    // 3. 帧内累积：Vpp 的 min/max、上升过零的时刻与配对数
    //    样本更新靠"值变了"判定（100 µs 栅格上，正弦每拍都会变，
    //    只有顶点附近可能连着两拍相同，代价是丢一次配对 —— 可接受）。
    // ---------------------------------------------------------------------
    reg signed [15:0] snp, cnp;
    reg [23:0] tup;                        // 上一次样本更新的时刻
    reg [23:0] dup;                        // 上一次的更新间隔（跨帧保留）
    wire chg = (sn != snp) || (cn != cnp);

    //   过零时刻取**区间中点**：真值均匀落在两次更新之间，取中点把误差变成
    //   零均值的 ±50 µs 抖动；用"本次时刻减去上一段间隔的一半"算，dup 跨帧保留，
    //   所以帧首那一次过零也算得对（若存绝对时刻，帧首 t 刚清零会算出巨大值）。
    wire [23:0] tmid = t - (dup >> 1);

    wire a_r = chg && (snp <  16'sd0) && (sn >= 16'sd0);   // A 上升过零
    wire b_r = chg && (cnp <  16'sd0) && (cn >= 16'sd0);   // B 上升过零

    reg [7:0]  amin, amax, bmin, bmax;
    reg        ahv,  bhv;                  // 本帧是否采到过样本
    reg [23:0] tfirst, tlast;              // 首末过零时刻
    reg        fhv;                        // 已有第一个过零
    reg [7:0]  ncross;                     // A 上升过零个数
    reg [23:0] sumdt;                      // Σ(t_b - t_a)
    reg [7:0]  npair;                      // 配对数
    reg [23:0] ta;                         // 待配对的 A 过零时刻
    reg        aseen;

    // 帧边界冻结的快照
    reg [7:0]  sv_amin, sv_amax, sv_bmin, sv_bmax;
    reg [7:0]  sv_nc, sv_np;
    reg [23:0] sv_t1, sv_t2, sv_sum;
    reg        sv_ahv, sv_bhv;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amin <= 8'd199; amax <= 8'd0; ahv <= 1'b0;
            bmin <= 8'd199; bmax <= 8'd0; bhv <= 1'b0;
            tfirst <= 24'd0; tlast <= 24'd0; fhv <= 1'b0; ncross <= 8'd0;
            sumdt <= 24'd0; npair <= 8'd0; ta <= 24'd0; aseen <= 1'b0;
            snp <= 16'sd0; cnp <= 16'sd0; tup <= 24'd0; dup <= 24'd5000;
            sv_amin <= 8'd0; sv_amax <= 8'd0; sv_bmin <= 8'd0; sv_bmax <= 8'd0;
            sv_nc <= 8'd0; sv_np <= 8'd0;
            sv_t1 <= 24'd0; sv_t2 <= 24'd0; sv_sum <= 24'd0;
            sv_ahv <= 1'b0; sv_bhv <= 1'b0;
        end else if (start) begin
            // 冻结（非阻塞赋值读的是本拍之前的值 ⇒ 与下面的清零同拍不冲突）
            sv_amin <= ahv ? amin : 8'd0;
            sv_amax <= ahv ? amax : 8'd0;
            sv_bmin <= bhv ? bmin : 8'd0;
            sv_bmax <= bhv ? bmax : 8'd0;
            sv_ahv  <= ahv;
            sv_bhv  <= bhv;
            sv_nc   <= ncross;
            sv_t1   <= tfirst;
            sv_t2   <= tlast;
            sv_sum  <= sumdt;
            sv_np   <= npair;
            // 清零
            amin <= 8'd199; amax <= 8'd0; ahv <= 1'b0;
            bmin <= 8'd199; bmax <= 8'd0; bhv <= 1'b0;
            tfirst <= 24'd0; tlast <= 24'd0; fhv <= 1'b0; ncross <= 8'd0;
            sumdt <= 24'd0; npair <= 8'd0; aseen <= 1'b0;
            snp <= sn; cnp <= cn;            // 免得跨帧误判一次过零
            tup <= 24'd0;                    // t 在帧首清零，tup 也要跟上（dup 保留）
        end else begin
            if (chg) begin
                dup <= t - tup;              // 本次 vs 上次更新的间隔
                tup <= t;
            end
            snp <= sn; cnp <= cn;

            if (!ahv) begin amin <= ra; amax <= ra; ahv <= 1'b1; end
            else begin
                if (ra < amin) amin <= ra;
                if (ra > amax) amax <= ra;
            end
            if (!bhv) begin bmin <= rb; bmax <= rb; bhv <= 1'b1; end
            else begin
                if (rb < bmin) bmin <= rb;
                if (rb > bmax) bmax <= rb;
            end

            if (a_r) begin
                ncross <= ncross + 8'd1;
                ta     <= tmid;
                aseen  <= 1'b1;
                if (!fhv) begin tfirst <= tmid; fhv <= 1'b1; end
                tlast <= tmid;
            end

            if (b_r && aseen) begin
                sumdt <= sumdt + (tmid - ta);
                npair <= npair + 8'd1;
                aseen <= 1'b0;               // 一对只用最近的一次 A 过零
            end
        end
    end

    // ---------------------------------------------------------------------
    // 4. 四个字段的被除数 / 除数（都是快照的组合函数）
    //    S = 屏上显示的值 x10，统一 "dddd.d" 六格
    //      VPP/DV: 百分比 x10  = px * 1000 / 199
    //      F     : Hz x10      = (过零个数-1) * 5e8 / 首末拍数
    //      DT    : µs x10      = Σ拍数 / (5 * 对数)
    // ---------------------------------------------------------------------
    wire [7:0]  vpp_a = (sv_ahv && (sv_amax >= sv_amin)) ? (sv_amax - sv_amin) : 8'd0;
    wire [7:0]  vpp_b = (sv_bhv && (sv_bmax >= sv_bmin)) ? (sv_bmax - sv_bmin) : 8'd0;
    wire [7:0]  dv_px = (vpp_a > vpp_b) ? (vpp_a - vpp_b) : (vpp_b - vpp_a);
    wire [23:0] dclk  = sv_t2 - sv_t1;
    wire [7:0]  nc1   = (sv_nc == 8'd0) ? 8'd0 : (sv_nc - 8'd1);
    wire [11:0] np5   = {4'd0, sv_np} * 12'd5;
    wire        f_ok  = (nc1 != 8'd0) && (dclk != 24'd0);

    reg [1:0]   fld;
    reg [39:0]  num40;
    reg [31:0]  den32;

    always @* begin
        // 先给默认值，免得 case 漏项时进组合环
        num40 = 40'd0;
        den32 = 32'd1;
        case (fld)
            2'd0: begin                                   // VPP-PC
                num40 = ({32'd0, vpp_a} * 40'd1000);
                den32 = 32'd199;
            end
            2'd1: begin                                   // F-HZ
                // f = nc1 / (首末过零拍数 x 20 ns) ⇒ f x10 = nc1 x 5e8 / 拍数
                num40 = f_ok ? ({32'd0, nc1} * 40'd500_000_000) : 40'd0;
                den32 = (dclk == 24'd0) ? 32'd1 : {8'd0, dclk};
            end
            2'd2: begin                                   // DT-US
                num40 = {16'd0, sv_sum};
                den32 = (np5 == 12'd0) ? 32'd1 : {20'd0, np5};
            end
            default: begin                                // DV-PC
                num40 = ({32'd0, dv_px} * 40'd1000);
                den32 = 32'd199;
            end
        endcase
    end

    wire [39:0] div_q;
    wire        div_done;
    reg         div_go;

    fixed_div #(.W(40), .DW(32)) u_div (
        .clk(clk), .rst_n(rst_n), .start(div_go),
        .dividend(num40), .divisor(den32),
        .quotient(div_q), .remainder(), .busy(), .done(div_done));

    // ---------------------------------------------------------------------
    // 5. double-dabble：17 位二进制 → 20 位 BCD（5 位十进制，够放 99999）
    //    ★ dd_cnt 必须 **5 位**：17 次迭代要数到 16，而 4 位放不下 16 ——
    //      `4'd16` 在 4 位里等于 0，循环会在第一拍就"满足"退出，BCD 永远是 0
    //      （首跑就是四枚全 0.0，而测量快照其实完全正确）。
    // ---------------------------------------------------------------------
    reg [4:0]  dd_cnt;
    reg [16:0] dd_bin;
    reg [19:0] dd_bcd;
    reg [2:0]  p;

    function [3:0] add3;
        input [3:0] d;
        begin
            add3 = (d >= 4'd5) ? (d + 4'd3) : d;
        end
    endfunction

    wire [19:0] dd_adj = { add3(dd_bcd[19:16]), add3(dd_bcd[15:12]),
                           add3(dd_bcd[11:8]),  add3(dd_bcd[7:4]),
                           add3(dd_bcd[3:0]) };

    // ---------------------------------------------------------------------
    // 6. 字符生成：p=0..3 -> 万/千/百/十位，p=4 -> 小数点，p=5 -> 个位
    //    （小数点固定在最后一位之前，所以 p=3 是整数部分的最低位）
    //    前导空格抑制：万/千/百位只有在"值够大"时才显示；
    //    ★ **p=3 与 p=5 永远显示** —— 少了这一条，值 0.0 会渲染成 "     .0"
    //      （p5_view 的"最低位永远显示"是同一条纪律）。
    // ---------------------------------------------------------------------
    reg [16:0] sv10;                      // 截顶后的显示值（= 值 x10）

    wire [3:0] cur_dig = (p == 3'd0) ? dd_bcd[19:16] :
                         (p == 3'd1) ? dd_bcd[15:12] :
                         (p == 3'd2) ? dd_bcd[11:8]  :
                         (p == 3'd3) ? dd_bcd[7:4]   : dd_bcd[3:0];
    wire [16:0] thr = (p == 3'd0) ? 17'd10000 :
                      (p == 3'd1) ? 17'd1000  :
                      (p == 3'd2) ? 17'd100   : 17'd0;
    wire       cur_vis = (p >= 3'd3) || (sv10 >= thr);
    wire [7:0] cur_ch  = (p == 3'd4) ? CH_DOT
                                     : (cur_vis ? (CH_ZERO + {4'd0, cur_dig}) : CH_SP);

    // ---------------------------------------------------------------------
    // 7. 状态机：每帧 4 个字段，各一次除法 + 一次 BCD + 6 格写入
    //    ★ f_col 必须在**使用之前**声明：本项目用 xvlog/xelab，
    //      它按文本顺序解析标识符（已踩过 VRFC 10-3380 三次）。
    // ---------------------------------------------------------------------
    //    f_col 给的是**六格字段的起始列**（右对齐到字段末格 = 起始列 + 5）：
    //    节距 10 格 -> 起始列 28 / 38 / 48 / 58（末格 33 / 43 / 53 / 63 = 右沿 1023）。
    function [5:0] f_col;
        input [1:0] f;
        begin
            case (f)
                2'd0:    f_col = 6'd28;
                2'd1:    f_col = 6'd38;
                2'd2:    f_col = 6'd48;
                default: f_col = 6'd58;
            endcase
        end
    endfunction

    localparam [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_DIVW = 3'd2,
                     S_DD   = 3'd3, S_WR   = 3'd4, S_NEXT = 3'd5,
                     S_END  = 3'd6;

    // ★ 列地址单独算成 6 位：写成 `waddr <= {BADGE_ROW, (f_col(fld) + {9'd0, p})}`
    //   时，内层 `{9'd0, p}` 是 **12 位**，拼接结果 18 位，赋给 12 位 waddr 时把自己
    //   的高 6 位（= BADGE_ROW）截掉 —— 数值会被写到第 0 行、列 40..63。
    //   （曾误判为"影子内存读回总是 0"：其实影子内存没错，是地址本来就少了一行。）
    wire [5:0] wc = f_col(fld) + {3'd0, p};

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            fld    <= 2'd0;
            p      <= 3'd0;
            div_go <= 1'b0;
            we     <= 1'b0;
            waddr  <= 12'd0;
            wdata  <= 8'd0;
            busy   <= 1'b0;
            done   <= 1'b0;
            sv10   <= 17'd0;
            dd_cnt <= 5'd0;
            dd_bin <= 17'd0;
            dd_bcd <= 20'd0;
        end else begin
            div_go <= 1'b0;
            we     <= 1'b0;
            done   <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        fld   <= 2'd0;
                        p     <= 3'd0;
                        busy  <= 1'b1;
                        state <= S_PREP;
                    end
                end

                S_PREP: begin
                    div_go <= 1'b1;          // 一拍脉冲（此时快照已稳定）
                    state  <= S_DIVW;
                end

                S_DIVW: begin
                    if (div_done) begin
                        sv10   <= (div_q[16:0] > 17'd99999) ? 17'd99999 : div_q[16:0];
                        dd_bin <= (div_q[16:0] > 17'd99999) ? 17'd99999 : div_q[16:0];
                        dd_bcd <= 20'd0;
                        dd_cnt <= 5'd0;
                        state  <= S_DD;
                    end
                end

                S_DD: begin
                    dd_bcd <= {dd_adj[18:0], dd_bin[16]};
                    dd_bin <= {dd_bin[15:0], 1'b0};
                    if (dd_cnt == 5'd16) begin
                        p     <= 3'd0;
                        state <= S_WR;
                    end else begin
                        dd_cnt <= dd_cnt + 5'd1;
                    end
                end

                S_WR: begin
                    we    <= 1'b1;
                    waddr <= {BADGE_ROW, wc};
                    wdata <= sig_bad ? 8'd2 : cur_ch;   // 空态：整格 '-'
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    if (p == 3'd5) begin
                        p <= 3'd0;
                        if (fld == 2'd3) begin
                            state <= S_END;
                        end else begin
                            fld   <= fld + 2'd1;
                            state <= S_PREP;
                        end
                    end else begin
                        p     <= p + 3'd1;
                        state <= S_WR;
                    end
                end

                default: begin               // S_END
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
