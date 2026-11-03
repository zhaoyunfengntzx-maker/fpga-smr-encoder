//=============================================================================
// disp/unit_lab.v —— 把四个单位（kHz / RPM / DEG / REV）**贴着数值右端**写到
//                    P1 标签层（v82 新增，任务B）
//-----------------------------------------------------------------------------
// 为什么需要它（问题链）：
//   v82 之前数值字段是**右对齐**的：任何长度的数字都贴着字段右边界，单位固定写在
//   "字段右边界 + 16 px"，于是单位与数字的墨迹间距恒为 22 px —— 好看，但数字的
//   **左边界随字符数漂移**（"28.3" 从 x224 起、"12345678" 从 x96 起），上板就是
//   用户投诉的"输入频率的数值比转速的数值明显靠右"。
//   v82 把数值改成**左对齐**（disp/val_format.v 的 S_WRW）：四张卡的数值左边界
//   恒为 x 96 / 576。代价是数字右端位置随字符数变，静态坐标的单位就跟不上了 ——
//   "28.3"（4 字符）时 kHz 会飘到 x 300 开外，中间空出 100 多 px。
//   所以单位必须**跟着数值长度走**：本模块每帧按 val_format 报上来的
//   `len_o`（该字段实际字符数，含 ± 号）算一次落点，把 3 个字符写进标签层。
//
// 坐标（与 tools/gen_text_ram.py 的 P1_UNITS 是两处共同契约，改一边必须改另一边）：
//   标签层格 16 px，数值层格 32 px ⇒ 数值字段的第 f_col 格 = 标签层第 2*f_col 格。
//   单位左格 = 2*f_col + 2*len + 1：
//     卡片        数值行   标签行   2*f_col   满宽 len   满宽时落格   16 px 格号
//     输入频率    2        8        6         7          21           x 336
//     转速        6        20       6         6          19           x 304
//     角度        6        20       36        6          49           x 784
//     累计转数    10       32       6         8          23           x 368
//   满宽时与 v79 手写的静态列**完全相同**（21/19/49/23），所以这不是"换了版面"，
//   而是把那一列从常量改成"跟着数值长度走"的函数：只有当数字比字段窄时，单位
//   才会往左收，收到永远离数字墨迹 22 px（16 px 格距 + 标签字模 0 左边距
//   + 数值字模 6 px 右边距）的位置。
//
//   行：单位墨迹要与数值同基线。数值行高 48 px（格行 6k 的墨迹底 = 48k+47），
//      单位在 16 px 格里的墨迹底 = 16R+14 ⇒ R = 3k+2 ⇒ 8 / 20 / 32（k = 2/6/10）。
//
// 为什么要"先擦整条再写"：
//   数值长度会变（f_in 从 "1500.00" 7 格缩到 "28.3" 4 格），单位的落点也就跟着
//   左移 6 格。若只写新位置，旧位置的字会留在屏上（RAM 是持久的）—— 屏上会同时
//   出现 "kHz" 和 "Hz" 的残影。所以每帧先把这个字段**整条可能落点区间**擦成空格，
//   再把 3 个字写在该落的位置：区间固定 20 格（2*8+1+3 ⇒ 覆盖累计转数的满宽），
//   四张卡共 80 格/帧，一格一拍。
//
// 代价：80 格/帧（4 张卡 x 20 格），1 个 2 位 + 1 个 5 位计数器 + 一个 12 项 case +
//      三个 6 位加法器。写口仲裁见 disp_engine.v 的 p1 标签层写口 mux（本模块
//      优先级最低：它写的格子与其它五个写者的地址互不相交）。
//=============================================================================
`default_nettype none

module unit_lab (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,       // 帧起始单拍（disp_engine 的 vf_start）
    input  wire        hold,        // 写口被更高优先级写者占用 → 本拍不写、不推进

    // 四个数值字段的实际字符数（含 ± 号），来自 disp/val_format.v 的 len_o
    input  wire [3:0]  len_fin,     // 字段 0：输入频率（无符号）
    input  wire [3:0]  len_rpm,     // 字段 2：转速
    input  wire [3:0]  len_ang,     // 字段 3：角度（含 + / -）
    input  wire [3:0]  len_rev,     // 字段 4：累计转数

    output reg         we,
    output reg  [11:0] waddr,       // {格行[5:0], 格列[5:0]}
    output reg  [7:0]  wdata,       // 标签层字库码
    output reg         busy
);

    // ---- 标签层字库码（'A'=18 起算：kHz 的 k/z 是字库末尾追加的 184/185）----
    localparam [7:0] CH_SP = 8'd0;
    localparam [7:0] CH_k  = 8'd184;
    localparam [7:0] CH_H  = 8'd25;
    localparam [7:0] CH_z  = 8'd185;
    localparam [7:0] CH_R  = 8'd35;
    localparam [7:0] CH_P  = 8'd33;
    localparam [7:0] CH_M  = 8'd30;
    localparam [7:0] CH_D  = 8'd21;
    localparam [7:0] CH_E  = 8'd22;
    localparam [7:0] CH_G  = 8'd24;
    localparam [7:0] CH_V  = 8'd39;

    // ---- 每张卡：格行 / 起始格（= 2*f_col）/ 长度 ----
    reg  [1:0]  un;                 // 0..3 = 频率 / 转速 / 角度 / 累计
    reg  [5:0]  urow, ubase;
    reg  [3:0]  ulen;

    always @(*) begin
        case (un)
            2'd0: begin urow = 6'd8;  ubase = 6'd6;  ulen = len_fin; end
            2'd1: begin urow = 6'd20; ubase = 6'd6;  ulen = len_rpm; end
            2'd2: begin urow = 6'd20; ubase = 6'd36; ulen = len_ang; end
            default: begin urow = 6'd32; ubase = 6'd6; ulen = len_rev; end
        endcase
    end

    // 单位第一个字符的格号（相对 ubase）= 2*len + 1
    wire [5:0] ustart = {1'b0, ulen, 1'b0} + 6'd1;

    // ---- 当前拍：cell 0..19 ----
    reg  [4:0]  cx;                 // 本单元内的第几格（0..19）
    wire [5:0]  rel = {1'b0, cx} - ustart;        // 0..2 = 单位字符，其余 = 空格

    reg  [7:0]  uch;
    always @(*) begin
        case (un)
            2'd0: uch = (rel == 6'd0) ? CH_k : (rel == 6'd1) ? CH_H : CH_z;
            2'd1: uch = (rel == 6'd0) ? CH_R : (rel == 6'd1) ? CH_P : CH_M;
            2'd2: uch = (rel == 6'd0) ? CH_D : (rel == 6'd1) ? CH_E : CH_G;
            default: uch = (rel == 6'd0) ? CH_R : (rel == 6'd1) ? CH_E : CH_V;
        endcase
    end

    wire [7:0] ucell_ch = (cx >= ustart && cx < ustart + 6'd3) ? uch : CH_SP;

    // ---- 一格一拍 ----
    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;
    reg [1:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            un    <= 2'd0;
            cx    <= 5'd0;
            we    <= 1'b0;
            waddr <= 12'd0;
            wdata <= 8'd0;
            busy  <= 1'b0;
        end else begin
            we <= 1'b0;
            case (st)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    st   <= S_WR;
                    un   <= 2'd0;
                    cx   <= 5'd0;
                    busy <= 1'b1;
                end
            end
            S_WR: begin
                busy <= 1'b1;
                if (!hold) begin
                    we    <= 1'b1;
                    waddr <= {urow, ubase + cx};
                    wdata <= ucell_ch;
                    if (cx == 5'd19) begin
                        cx <= 5'd0;
                        if (un == 2'd3) st <= S_DONE;
                        else            un <= un + 2'd1;
                    end else begin
                        cx <= cx + 5'd1;
                    end
                end
            end
            default: begin
                busy <= 1'b0;
                st   <= S_IDLE;
            end
            endcase
        end
    end

endmodule

`default_nettype wire
