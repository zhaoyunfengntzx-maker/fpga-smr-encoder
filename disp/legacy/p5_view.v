//=============================================================================
//  disp/p5_view.v  --  P5「六状态表 + 驻留统计」的驻留统计格式化器
//
//  这一页回答的问题：三相六状态各占多少**时间**、各被访问了多少**次**。
//
//  ★ 为什么是时间域直接数，而不是像 P4 那样按电角度装箱：
//    P4 要回答的是"信号在某个角度上是什么电平"，而 A/B 边沿率是
//    4 x inter x f_in（inter=256、f_in=1500 Hz 时 1.536 MHz），屏 58.6 帧/s，
//    直接画时间轴只会画出混叠出来的假波形 —— 所以 P4 必须做等效时间采样。
//    P5 要的是**占比**，这个量在时间域上直接累加计数器就是对的，而且更准：
//    每拍看 uvw = q_io_state[4:2] 落在 8 种组合里的哪一种，各一个 32 位计数器。
//    ★ 用 P4 那种 128 箱直方图的箱数当占比是**错的**：箱数是电角度分辨率，
//      箱数多只说明"信号在那个角度附近停留得久"，不等于"状态被访问得多"。
//      两页统计口径不同是故意的，不是没统一。
//
//  ★ 为什么不需要双缓冲（P2/P3 必须要有）：
//    写地址在这里是"某个计数器加一"，不是内存地址；读者读的是 snap（冻结的
//    快照），而 snap 每 64 帧才更新一次，更新点落在帧首。所以读者在一帧之内
//    看到的内容是常量 —— 不存在"同一地址在读者到达它之前/之后各被写一次"。
//    P2/P3 撕裂的根因是**采样写入与光栅读取共用同一片地址空间**，这里没有。
//
//  口径：
//    - 计数器 8 个（000..111），本页用其中 6 个合法状态 + 2 个退化状态
//      （全零 000 与全一 111 —— 正常情况下两者占比都应该是 0.0%，
//        它们不是 0 就说明接线/换相有问题，所以值得单列）；
//    - 窗口 = WIN_FRAMES + 1 帧（默认 64 帧，约 1.09 s @58.6 fps），边界在帧首拍；
//    - 「占比」= permille（千分之一）渲染成 5 格 "dd.d"，即百分比带一位小数；
//    - 「次数」= **进入该状态的次数**（uvw 码值跳变沿计数），不是采样拍数：
//      采样拍数在 1.09 s 窗口里可以到 1e8，屏上放不下也没人读得动；跳变次数
//      按 A/B 边沿率 4 x inter x f_in 量级（典型千次）正好是 5 位十进制。
//      ★ 它与「占比」口径不同是**故意**的：占比是时间占比（拍数），次数是事件
//        频次（跳变），两者除一除就是平均驻留时长。
//    - 条形图阈值 = perm * 188 / 1024（0..183 px），与百分比同源，两边不会打架。
//
//  ★ 复位后第一个窗口还没冻结，六行都显示 0.0、条形图全空 —— 这是设计如此，
//    不是"没接上"：snap 的复位值就是 0，而"0.0% 且没有条形"正是没有数据的样子。
//    对照 P6 的教训（那块 RAM 的写口一直是空的、屏上数字恰好等于复位默认值，
//    于是不存在的通路被伪装成"通了"）：这一页宁可先显示"没有数据"。
//
//  字段表（与 tools/gen_text_ram.py 的 P5_LAB、disp/disp_engine.v 的 v30 虚拟
//  表格格网是**三处共同契约**）：
//    ★ v30（㉖）：P5 表格按 spec §4.4 严格重排 —— 行距 30 px、列宽 188 px、
//      6 行 x 5 列。30/188 与全局 16 px 文字格网不可通约，所以 disp_engine 给
//      P5 单开了一套"虚拟格网"：格内 x 由列内偏移决定、行号由行带决定，
//      下面是映射之后**RAM 里的**行列号（每页一块独立 lab RAM，所以互不干扰）：
//        表头行  = RAM 行 8
//        数据行 s=0..5 = RAM 行 9..14   （六个合法状态，码值 1..6）
//        底栏    = RAM 行 22            （000 / 111 两个退化状态，全局格网）
//      列（5 列 x 188 px）：0 = 序号、1 = 状态、2 = 次数、3 = 占比、4 = 条形图；
//      每列 11 个字符格（11 x 16 = 176 px + 左右各 6 px 内缩 = 188 px），
//      RAM 列 = c*11 + ci，所以 4 列的分界在 RAM 列 11/22/33/44。
//    - 本模块写**动态**两列：次数（RAM 列 28..32，右对齐 5 格）与
//      占比（RAM 列 33..37，5 格 "dd.d"）；
//    - 序号 / 状态 / 表头 / 底栏标签都是静态文字，由 tools/gen_text_ram.py 生成；
//    - 条形图列（RAM 列 44..54）没有文字，只有 disp_engine 按下面的阈值画的像素。
//    标签与列位置改了这里就必须改 gen_text_ram.py 的 P5_LAB 与 disp_engine 的
//    P5 几何常量，反之亦然。
//=============================================================================
`default_nettype none

module p5_view #(
    parameter [5:0] WIN_FRAMES = 6'd63   // 窗口 = WIN_FRAMES+1 帧
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,        // disp_engine 的 vf_start：帧首一拍
    // v50（㊼）B3：空态 —— sig_bad 时六个状态行的次数/占比各格写 '-'（CH_MINUS = 2），
    //   与 P1 四个测量字段同一口径（`99999` 是 BCD 饱和点、不是哨兵，所以不能靠判数字）。
    input  wire        sig_bad,
    input  wire [2:0]  uvw,          // {w,v,u} = q_io_state[4:2]

    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output wire        busy,
    output wire        done,

    // 条形图阈值：六个状态各一个，单位 px（0..188，占满一列 188 px），直接以寄存器输出
    output reg  [7:0]  bar_t0,
    output reg  [7:0]  bar_t1,
    output reg  [7:0]  bar_t2,
    output reg  [7:0]  bar_t3,
    output reg  [7:0]  bar_t4,
    output reg  [7:0]  bar_t5
);

    // ---------------------------------------------------------------------
    // 1. 累积：每个 clk 采一次 uvw；窗口边界上把计数器冻结进 snap 再清零
    //    两套计数：cnt = 采样拍数（算占比）、ent = 进入次数（算次数）
    // ---------------------------------------------------------------------
    reg [31:0] cnt  [0:7];
    reg [31:0] snap [0:7];
    reg [31:0] ent  [0:7];
    reg [31:0] ent_snap [0:7];
    reg [31:0] tot, snap_tot;
    reg [2:0]  uvw_d;
    reg [5:0]  fdiv;
    integer    k;

    wire win_edge = start && (fdiv == WIN_FRAMES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fdiv     <= 6'd0;
            tot      <= 32'd0;
            snap_tot <= 32'd0;
            uvw_d    <= 3'd0;
            for (k = 0; k < 8; k = k + 1) begin
                cnt[k]      <= 32'd0;
                snap[k]     <= 32'd0;
                ent[k]      <= 32'd0;
                ent_snap[k] <= 32'd0;
            end
        end else if (win_edge) begin
            // 边界那一拍的这一笔不计入（否则要分成"加完再冻"两拍）
            fdiv     <= 6'd0;
            snap_tot <= tot;
            tot      <= 32'd0;
            for (k = 0; k < 8; k = k + 1) begin
                snap[k]     <= cnt[k];
                cnt[k]      <= 32'd0;
                ent_snap[k] <= ent[k];
                ent[k]      <= 32'd0;
            end
        end else begin
            cnt[uvw] <= cnt[uvw] + 32'd1;
            tot      <= tot + 32'd1;
            // ★ 进入次数：只在码值**变化**的那一拍加一。复位后的第一拍 uvw_d = 0，
            //   若上电就停在 000 会数出一次"进入 000" —— 与"窗口内进入次数"的
            //   口径一致（窗口从复位起算，这一次确实算进入）。
            if (uvw != uvw_d) ent[uvw] <= ent[uvw] + 32'd1;
            uvw_d <= uvw;
            if (start) fdiv <= fdiv + 6'd1;
        end
    end

    // ---------------------------------------------------------------------
    // 2. 字段表：14 个字段，每个都是 5 格宽
    //      fld 0..5  : 「次数」六个合法状态（码 1..6）-> RAM 行 9..14，列 28
    //      fld 6..11 : 「占比」六个合法状态（码 1..6）-> RAM 行 9..14，列 33
    //      fld 12/13 : 「占比」两个退化状态（码 0 / 7）-> RAM 行 22，列 18 / 32
    // ---------------------------------------------------------------------
    localparam [3:0] NF = 4'd14;

    // ★ xvlog 要求变量在**使用之前**声明（声明位置在 Verilog-2001 里本来是自由的）。
    //   fld 在第 2 节就要用到（字段表是个组合译码），所以提到这里。
    reg [3:0] fld;

    wire       is_cnt = (fld < 4'd6);                        // 次数字段 / 占比字段
    wire [3:0] fs     = is_cnt ? fld : (fld - 4'd6);         // 0..5 = 六个合法状态
    wire [2:0] code3  = is_cnt ? (fs[2:0] + 3'd1) :          // 码 1..6
                        (fld < 4'd12) ? (fs[2:0] + 3'd1) :
                        (fld == 4'd12) ? 3'd0 : 3'd7;        // 底栏：码 0 / 码 7

    function [5:0] f_row;
        input [3:0] f;
        reg   [3:0] s;
        begin
            if (f < 4'd6)       s = f;
            else if (f < 4'd12) s = f - 4'd6;
            else                s = 4'd0;
            if (f < 4'd12) f_row = 6'd9 + {2'd0, s};         // 六个合法状态：行 9..14
            else           f_row = 6'd22;                    // 000 / 111 在底栏
        end
    endfunction

    function [5:0] f_col;
        input [3:0] f;
        begin
            if (f < 4'd6)       f_col = 6'd28;   // 次数列（右对齐 5 格到列 32）
            else if (f < 4'd12) f_col = 6'd33;   // 占比列
            else if (f == 4'd12) f_col = 6'd18;  // 000 的占比
            else                 f_col = 6'd32;  // 111 的占比
        end
    endfunction

    // ★ v17 修的错位：uvw 是**码值**，不是行号。
    //   uvw = {w,v,u}（见端口注释），所以
    //     000 -> 码 0、U高 V低 W低 -> 码 1、U低 V高 W低 -> 码 2、U高 V高 W低 -> 码 3、
    //     U低 V低 W高 -> 码 4、U高 V低 W高 -> 码 5、U低 V高 W高 -> 码 6、111 -> 码 7。
    //   （上面六个标签的写法是 v40（㊱）起的样子；㊱ 之前是 `U1 V0 W0` 这种 ASCII
    //     三位写法 —— 只是标签文本换了、码值口径与这里的映射一个字都没变。）
    //   而 tools/gen_text_ram.py 的 P5_LAB 六行标签依次是码 1..6，底栏才是 000 与 111。
    //   原先把 4'd0..4'd5 直接接到 snap[0..5]，整张表错位一格 —— 屏上码 1 那一行
    //   显示的其实是码 000 的占比，于是它和底栏的 "BAD 000" 永远同值（实机照片上两个
    //   99.9 就是这么来的）。底栏的 bad000 原来写成 snap_tot 减其余七个状态，
    //   那正好等于 snap[0]，所以两个字段本来就重复。
    reg [31:0] cur_num;
    always @* begin
        case (code3)
            3'd1:    cur_num = snap[1];
            3'd2:    cur_num = snap[2];
            3'd3:    cur_num = snap[3];
            3'd4:    cur_num = snap[4];
            3'd5:    cur_num = snap[5];
            3'd6:    cur_num = snap[6];
            3'd0:    cur_num = snap[0];
            default: cur_num = snap[7];
        endcase
    end

    // 次数：进入次数（32 位），显示上限 65535 —— 5 格十进制放得下 99999，但
    // BCD 通路是 16 bit（double-dabble 迭代 16 次），所以饱和点取 16 位满量程。
    // 真到饱和说明窗口内跳变超过 6.5 万次，那已经是"接线在抖"的量级了。
    wire [15:0] cnt_clamp = (ent_snap[code3] > 32'd65535) ? 16'd65535
                                                         : ent_snap[code3][15:0];

    // ---------------------------------------------------------------------
    // 3. 除法：permille = num * 1000 / total（共享顺序除法器，一拍一位，W 拍）
    //    只有占比字段用它；次数字段直接进 BCD，不经过除法。
    // ---------------------------------------------------------------------
    reg        div_go;
    reg  [9:0] perm;

    wire [39:0] num40 = (snap_tot == 32'd0) ? 40'd0
                                            : ({8'd0, cur_num} * 40'd1000);
    wire [31:0] den32 = (snap_tot == 32'd0) ? 32'd1 : snap_tot;
    wire [39:0] div_q;
    wire        div_done;

    fixed_div #(.W(40), .DW(32)) u_div (
        .clk(clk), .rst_n(rst_n), .start(div_go),
        .dividend(num40), .divisor(den32),
        .quotient(div_q), .remainder(), .busy(), .done(div_done));

    // ---------------------------------------------------------------------
    // 4. double-dabble：16 bit 二进制 -> 20 bit BCD（5 位十进制）
    //    不用除法器逐位取余，是因为 16 次移位 + 5 组加 3 的组合网络比连开
    //    四次除法便宜得多，而且这一页一次要算 14 个字段。
    //    ★ v30：输入从 10 bit（permille）加宽到 16 bit（次数上限 99999 = 5 位），
    //      迭代次数 10 -> 16；位数映射按字段类型分流（见 cur_dig）。
    // ---------------------------------------------------------------------
    reg [4:0]  dd_cnt;
    reg [15:0] dd_bin;
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

    // p = 0..4 -> 五格。
    //   占比（is_cnt = 0）：p0 = 百位（BCD d3）、p1 = 十位（d2）、p2 = 个位（d1）、
    //                      p3 = 小数点（固定码 1）、p4 = 十分位（d0）
    //   次数（is_cnt = 1）：p0 = 万位（d4）、p1 = 千位（d3）、p2 = 百位（d2）、
    //                      p3 = 十位（d1）、p4 = 个位（d0）
    // 前导零抑制只作用在整数的前几格；占比的个位与十分位、次数的个位永远显示。
    localparam [7:0] CH_SP   = 8'd0;
    localparam [7:0] CH_DOT  = 8'd1;
    localparam [7:0] CH_ZERO = 8'd8;

    wire [9:0]  thr     = (p == 3'd0) ? 10'd1000 : (p == 3'd1) ? 10'd100 : 10'd0;
    wire [15:0] thr_cnt = (p == 3'd0) ? 16'd10000 : (p == 3'd1) ? 16'd1000 :
                          (p == 3'd2) ? 16'd100   : (p == 3'd3) ? 16'd10 : 16'd0;
    wire        cur_vis = is_cnt ? ((p == 3'd4) || (cnt_clamp >= thr_cnt))
                                 : ((p == 3'd3) || (p == 3'd4) || (perm >= thr));
    wire [3:0]  cur_dig = is_cnt
                        ? ((p == 3'd0) ? dd_bcd[19:16] :
                           (p == 3'd1) ? dd_bcd[15:12] :
                           (p == 3'd2) ? dd_bcd[11:8]  :
                           (p == 3'd3) ? dd_bcd[7:4]   : dd_bcd[3:0])
                        : ((p == 3'd0) ? dd_bcd[15:12] :
                           (p == 3'd1) ? dd_bcd[11:8]  :
                           (p == 3'd2) ? dd_bcd[7:4]   : dd_bcd[3:0]);
    wire [7:0]  num_ch  = cur_vis ? (CH_ZERO + {4'd0, cur_dig}) : CH_SP;
    wire [7:0]  cur_ch  = (!is_cnt && (p == 3'd3)) ? CH_DOT : num_ch;

    // ---------------------------------------------------------------------
    // 5. 状态机：每帧跑一轮，把 14 个字段写进 lab 文字平面
    //    预算：14 字段 x (40 拍除法 + 16 拍 BCD + 5 拍写) 约 900 拍 / 帧，
    //    而一帧可用 239,040 拍（消隐 + 可见）—— 余量两个数量级。
    // ---------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_DIVW = 3'd2,
                     S_DD   = 3'd3, S_WR   = 3'd4, S_NEXT = 3'd5,
                     S_END  = 3'd6;

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            fld    <= 4'd0;
            p      <= 3'd0;
            div_go <= 1'b0;
            perm   <= 10'd0;
            dd_cnt <= 5'd0;
            dd_bin <= 16'd0;
            dd_bcd <= 20'd0;
            bar_t0 <= 8'd0; bar_t1 <= 8'd0; bar_t2 <= 8'd0;
            bar_t3 <= 8'd0; bar_t4 <= 8'd0; bar_t5 <= 8'd0;
        end else begin
            div_go <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        fld   <= 4'd0;
                        state <= S_PREP;
                    end
                end

                S_PREP: begin
                    if (is_cnt) begin
                        // 次数：不需要除法，直接进 BCD
                        perm   <= 10'd0;
                        dd_bin <= cnt_clamp;
                        dd_bcd <= 20'd0;
                        dd_cnt <= 5'd0;
                        state  <= S_DD;
                    end else begin
                        div_go <= 1'b1;      // 一拍脉冲；被除数/除数此刻已是组合值
                        state  <= S_DIVW;
                    end
                end

                S_DIVW: begin
                    if (div_done) begin
                        perm   <= (div_q[9:0] > 10'd1000) ? 10'd1000 : div_q[9:0];
                        dd_bin <= (div_q[9:0] > 10'd1000) ? 16'd1000 : div_q[15:0];
                        dd_bcd <= 20'd0;
                        dd_cnt <= 5'd0;
                        state  <= S_DD;
                    end
                end

                S_DD: begin
                    dd_bcd <= {dd_adj[18:0], dd_bin[15]};
                    dd_bin <= {dd_bin[14:0], 1'b0};
                    if (dd_cnt == 5'd15) begin
                        state <= S_WR;
                        p     <= 3'd0;
                    end else begin
                        dd_cnt <= dd_cnt + 5'd1;
                    end
                end

                S_WR: begin
                    if (p == 3'd4) begin
                        p     <= 3'd0;
                        state <= S_NEXT;
                    end else begin
                        p <= p + 3'd1;
                    end
                end

                S_NEXT: begin
                    // 条形图阈值：与百分比同源，量程 = 第 5 列里的槽长 184 px
                    //   （x = 836..1019）。184/1000 用 188/1024 近似（误差 0.2%，
                    //   满量程 1000 -> 183 = 槽内最后一列）。
                    //   ★ 乘法必须显式写成 16 位常数：Verilog 里 `perm * 10'd188`
                    //     的结果宽度取两个操作数的**较大者**（10 位），18800 会被截成
                    //     368、右移 10 位之后恒为 0（实测就是这么挂在阈值断言上的）。
                    if (!is_cnt && (fs < 4'd6)) begin
                        case (fs)
                            4'd0: bar_t0 <= (perm * 16'd188) >> 10;
                            4'd1: bar_t1 <= (perm * 16'd188) >> 10;
                            4'd2: bar_t2 <= (perm * 16'd188) >> 10;
                            4'd3: bar_t3 <= (perm * 16'd188) >> 10;
                            4'd4: bar_t4 <= (perm * 16'd188) >> 10;
                            default: bar_t5 <= (perm * 16'd188) >> 10;
                        endcase
                    end

                    if (fld == NF - 4'd1) begin
                        state <= S_END;
                    end else begin
                        fld   <= fld + 4'd1;
                        state <= S_PREP;
                    end
                end

                default: begin               // S_END
                    state <= S_IDLE;
                end
            endcase
        end
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_END);

    always @* begin
        we    = (state == S_WR);
        waddr = {f_row(fld), f_col(fld)} + {9'd0, p};
        wdata = sig_bad ? 8'd2 : cur_ch;   // 空态：整格 '-'
    end

endmodule

`default_nettype wire
