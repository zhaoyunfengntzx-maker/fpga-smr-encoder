//=============================================================================
// z_cnt_lab.v —— P1 卡 6 左下角「Z计数」的数值（v77 新增）
//
// 为什么有本模块：
//   上板实测（v76）P1 左下角 "Z计数" 只有标签、没有数值，而且底色是红的。
//   红底的原因是 disp_engine 里的状态条反色块还在用 v58 三列卡片的坐标，
//   正好压在这两个格上（已在本版改回 v59 网格，见 disp_engine.v 的 scbar_*）。
//   数值缺失的原因是**根本没人写**：rtl/enc_top.v 的 z_pulse_cnt 只挂在
//   寄存器 0x054A..0x054D（rtl/reg_file.v），没有进显示器侧的 tap 端口，
//   而 rtl/ 本版不许动。所以这里在显示侧自己数一遍 —— 判据与 rtl 那边
//   完全一致（Z 的上升沿计数），只是数据源换成 tap 里的 Z 电平。
//
// 为什么用十进制加法器而不是双 dabble：
//   Z 每转 1 个脉冲（744.8 rpm ⇒ 12.4 次/秒），最坏情况也就 20 Hz，
//   远低于 50 MHz 时钟，进位链可以放心做成一拍内的串行进位；
//   双 dabble 要一个 32 拍状态机 + 5 组 add3，比这里贵 3 倍 LUT，
//   而本版 LUT 只剩 555 个余量（85% 上限），必须省。
//
// 为什么满 99999 就停：
//   只有 5 格（格列 12..16），再多一位也显示不出来；饱和不变比回卷到 0 好，
//   读数至少还是单调的。真实计数值在寄存器 0x054A 里仍是完整 32 位。
//
// ★ v85：5 ms 抑制窗（去抖）
//   上板实测（v84）：P1 的 "Z计数" 打到 99999 饱和，而 "累计转数" 只有 4001 REV，
//   且 rtl 的绝对 Z 计数（0x054A）折算 7.62 Hz ↔ 457 rpm / 8.32 Hz ↔ 499 rpm
//   —— 严格 1 个/转，说明**硬件每转只出 1 个 Z**，是屏上这个计数器把它数爆的。
//   机理（审计已记为已知问题 B8）：转子停在索引位附近时电角度在 0° 抖动，
//   每跨一次零就出一个 Z（折算约 3 kHz）；0x054A 累计到 12,128,530 而转台只转
//   约 4001 转，差额全是停位喘振。50 MHz 下直接数上升沿，几分钟就能满 5 位。
//   判据：只有距**上一个 Z 上升沿**超过 5 ms（250,000 拍）的上升沿才计数。
//   正常转速 720 rpm = 83 ms/转、480 rpm = 125 ms/转，5 ms 门限不会误伤；
//   ms 级喘振被整串压掉（一串抖动只算 1 个）。
//   ★ 窗是**可重触发**的（任何 Z 上升沿都重置窗口），所以短间隔的一串脉冲
//     只会留下"第 1 个"，代价是停位喘振那一串里也会多 1 个 —— 与 4001 转
//     的真值相比是 +1，不是 +1200 万，可以接受（无法区分"喘振第 1 个"与
//     "正常的 1 个/转"，除非再引入转速先验）。
//
// 写口：挂在 P1 标签层的最后一个写者上（disp_engine.v 的 zc_we）。
//   行 36 只有 "Z计数" 标签（列 6/7）和卡 6 的 "状态正常"（列 36）占用，
//   列 12..16 是空的，因此与 stat_chip / pos_hex / pnl_calc / uv_state 都不冲突。
//=============================================================================
`default_nettype none

module z_cnt_lab (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,        // vf_start：帧起始单拍
    input  wire        z,            // Z 电平（q_io_state[2]）
    input  wire        hold,         // 前级写者正在写，本拍不推进

    output reg         we,
    output reg  [11:0] waddr,
    output reg  [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    // 字符码：与 tools/gen_text_ram.py 的 ASCII_CHARS 顺序一致（'0' = 8）
    localparam [7:0] CH_SP = 8'd0;
    localparam [7:0] CH_D0 = 8'd8;

    localparam [5:0] LAB_ROW = 6'd36;
    localparam [5:0] LAB_C0  = 6'd12;
    localparam [3:0] LAB_N   = 4'd4;     // 5 格：k = 0..4

    //------------------------------------------------------------------
    // 1) 上升沿计数（十进制，5 位）+ 5 ms 抑制窗（v85）
    //------------------------------------------------------------------
    reg        z_q;
    reg  [3:0] d0, d1, d2, d3, d4;       // d0 是个位

    // 5 ms @ 50 MHz = 250,000 拍（18 位足够：2^18 = 262,144）
    localparam [17:0] ZGATE = 18'd250_000;

    reg  [17:0] gate_cnt;                // 窗内剩余拍数
    reg         gate_act;                // 窗有效（距上一个 Z 上升沿不足 5 ms）

    wire raw_inc = z & ~z_q;             // 每一个上升沿（含喘振）
    wire inc     = raw_inc & ~gate_act;  // 只有窗已到期的那一个才算数

    wire full = (d0 == 4'd9) && (d1 == 4'd9) && (d2 == 4'd9) &&
                (d3 == 4'd9) && (d4 == 4'd9);
    wire upd  = inc & ~full;

    wire c1 = upd && (d0 == 4'd9);
    wire c2 = c1  && (d1 == 4'd9);
    wire c3 = c2  && (d2 == 4'd9);
    wire c4 = c3  && (d3 == 4'd9);

    // 抑制窗：可重触发。任何上升沿都把窗重新装到 250,000 拍；
    // 窗到期（gate_cnt 减到 0 且没有新的上升沿）才允许下一个上升沿计数。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_cnt <= 18'd0;
            gate_act <= 1'b0;
        end else if (raw_inc) begin
            gate_act <= 1'b1;
            gate_cnt <= ZGATE - 18'd1;
        end else if (gate_act) begin
            if (gate_cnt == 18'd0) gate_act <= 1'b0;
            else                   gate_cnt <= gate_cnt - 18'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z_q <= 1'b0;
            d0  <= 4'd0; d1 <= 4'd0; d2 <= 4'd0; d3 <= 4'd0; d4 <= 4'd0;
        end else begin
            z_q <= z;
            if (upd) begin
                d0 <= c1 ? 4'd0 : (d0 + 4'd1);
                if (c1) d1 <= c2 ? 4'd0 : (d1 + 4'd1);
                if (c2) d2 <= c3 ? 4'd0 : (d2 + 4'd1);
                if (c3) d3 <= c4 ? 4'd0 : (d3 + 4'd1);
                if (c4) d4 <= (d4 == 4'd9) ? 4'd0 : (d4 + 4'd1);
            end
        end
    end

    //------------------------------------------------------------------
    // 2) 每帧把 5 位十进制搬到标签层（高位前导零写空格）
    //   digit(k)：k=0 是最高位（万位），k=4 是个位。
    //   前导零抑制：某一位要显示，当且仅当它自己非零，或比它高的位里
    //   已经出现过非零。否则写空格 —— 这样 "Z计数 0" 而不是 "Z计数 00000"。
    //------------------------------------------------------------------
    reg         started;                   // 高位已出现过非零

    reg [1:0] st;
    reg [3:0] idx;

    wire [3:0] digit = (idx == 4'd0) ? d4 :
                       (idx == 4'd1) ? d3 :
                       (idx == 4'd2) ? d2 :
                       (idx == 4'd3) ? d1 : d0;

    function [7:0] cell_of;
        input [3:0] dg;
        input       vis;
        begin
            cell_of = vis ? (CH_D0 + dg) : CH_SP;
        end
    endfunction

    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            idx       <= 4'd0;
            started   <= 1'b0;
            we        <= 1'b0;
            waddr     <= 12'd0;
            wdata     <= 8'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            we   <= 1'b0;
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                            st      <= S_WR;
                            idx     <= 4'd0;
                            started <= 1'b0;
                            busy    <= 1'b1;
                        end
                S_WR: if (!hold) begin
                            we    <= 1'b1;
                            waddr <= {LAB_ROW, LAB_C0 + {2'd0, idx}};
                            //   个位（idx == LAB_N）无条件显示：否则计数为 0 时
                            //   5 格全被前导零抑制成空格，屏上又变成"没有数值"。
                            wdata <= cell_of(digit, (idx == LAB_N) | started |
                                                    (digit != 4'd0));
                            if (digit != 4'd0) started <= 1'b1;
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
