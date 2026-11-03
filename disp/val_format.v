//=============================================================================
// val_format.v -- P1 数值层运行时格式化器
//
// 职责：每帧在消隐期把编码器的实时量算成字符，写进数值层字符 RAM
//       （p1_val_ram 的写口），使 P1 总览上的数值是**真实测量值**而不是
//       生成器里预置的静态文本。
//
// 版面对应（数值层格 32 x 64，格列 = x/32，格行 = y/64）：
//   格行 2  格列 2 ...11   f_in，2 位小数，右对齐，共 10 字符   "  1500.00"
//   格行 2  格列 12...18   倍频/分频，7 字符                     "X 64 /1"
//   格行 2  格列 22...29   转速，1 位小数，共 8 字符              "  1800.0"
//   格行 7  格列 2 ...8    角度+方向，1 位小数，共 7 字符          "  +45.0"
//   格行 7  格列 12...19   累计转数，8 字符                       "      12"
//   格行 7  格列 22...29   ABZ 电平，8 字符                       "A1 B0 Z0"
//
// 设计要点
//  1. **十进制转换不用除法器**：32 位二进制 -> 10 位 BCD 用 double-dabble
//     （每拍先给 >=5 的 BCD 位加 3，再左移进一位二进制），固定 32 拍出结果。
//     只有 rpm / 累计转数两处需要"除以极对数"，共用同一个 fixed_div，
//     一帧各做一次。
//  2. **不在像素路径上**：整个模块跑在消隐期（一帧有 239040 拍空闲），
//     所以状态机可以慢慢来，组合深度也不敏感。
//  3. 字符码**不是 ASCII**：它是字库索引，字符集 =
//     " .-+/:=^0123456789A-Z"（44 个），所以 '0' 对应 8、'A' 对应 18。
//=============================================================================
`timescale 1ns / 1ps

module val_format #(
    // v68 显示版：64 周期/转时用固定 CPR 换算转速/累计转数；
    // 0 = 沿用 cfg_pairs（v13/v62/v66 旧行为）。CPR 只影响 RPM/转数两字段，
    // 不影响角度/ABZ/UVW。
    parameter integer CPR = 0
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,        // 一帧一次的启动脉冲（帧末有效像素）
    input  wire signed [31:0] f_q10,        // 输入频率，1/1024 Hz 定点（有符号）
    input  wire signed [47:0] pos_acc,      // 累计位置（电周期<<16，有符号）
    // ★ v86（任务C）：「累计转数」= Z 计数（disp/z_cnt_lab.v 的 rev_bin）。
    //   本编码器 1 Z / 转，转数的定义就是 Z 脉冲个数；v85 上板同一时刻
    //   屏上 REV=2326、Z计数=1718、硬件 0x054A=4856 三个数互相矛盾，根因就是
    //   REV 走 pos_acc 积分、Z 计数走边沿计数这两条独立路径。
    //   ★ 为什么送**二进制**而不是 BCD：下游的 double-dabble + 数字分支
    //   (fld0/2/3 已经在用) 本来就能把 v32 渲成十进制，fld4 复用它即可，
    //   一行新逻辑都不用加；若给 REV 单开一条 cbuf 写路径，整片综合会多出
    //   ~480 LUT，直接顶破 88% 红线（实测 19,310/90.29%）。
    input  wire        [16:0] rev_bin,
    input  wire        [15:0] angle,        // 电角度 0..65535 = 0..360.00 度
    input  wire        [7:0]  io_state,     // {limiter,dir,w,v,u,z,b,a}
    input  wire        [9:0]  cfg_inter,    // 倍频率 2..256
    input  wire        [2:0]  cfg_div,      // 分频率 1..8
    input  wire        [4:0]  cfg_pairs,    // 极对数
    // ---- v22 编辑面板：字段 1 显示"待应用值"而不是回读值 ----
    //   spec docs/13:267 要求"屏幕绝不允许显示用户想要的理想值，只能显示
    //   回读确认过的实际值"，但同一条规格 §6.2 又要求面板上有"待应用"这一态
    //   （提示用户"你改了但还没写"）。两者并不矛盾：**面板开着时**字段 1 显示
    //   待应用值，面板一关就回到 tap 的回读值（真实寄存器值）。
    //   pnl_on 默认 0 ⇒ 老路径（面板不存在时）行为一位不变。
    input  wire               pnl_on,       // 面板开着（disp_engine 同源信号）
    input  wire        [9:0]  pnl_inter,    // 面板里的待应用倍频（编码 0 = 256）
    input  wire        [2:0]  pnl_div,      // v44（㊶）面板里的待应用分频码 0..7（div = 码+1）
    // ---- v45（㊷）/ v46（㊸）空态：信号不可信时，不给"看起来像测量值"的数字 ----
    //   docs/13:351 反模式 8（"没信号时屏幕一片空白 / 一片 `0`"）：本模块把
    //   f_in / 转速 / 角度 / 累计转数四个**测量**字段整格填成 '-'（小数点保留，
    //   字段骨架还在），标签与单位不动 —— 空白会被当成"这里没画东西"，
    //   '-' 才是明确的"无读数"。倍频分频是**配置回读**、ABZ 电平是**逻辑电平**，
    //   两者与输入信号是否可信无关 ⇒ 原样显示。判据见 disp_engine 的 sig_bad
    //   （v45 定义 = 链路帧 CRC 错（v74 起恒 0）；v46 ㊸ 又并入"**无载波**"
    //    = `tap_amp_sq < tap_amp_low_sq`；信号质量问题**标志位** cor_sat/amp_bad
    //     仍不进空态，它们各自落在卡 3/卡 4 的状态条判据上）。
    // v60（R1）：每个字段一位空态掩码（拆开故障源）。
    //   bit0 f_in（输入频率）/ bit1 倍频分频 / bit2 转速
    //   bit3 角度 / bit4 累计转数 / bit5 ABZ-UVW
    input  wire        [5:0]  nodata_mask,
    output reg                we,
    output reg         [8:0]  waddr,        // {格行[3:0], 格列[4:0]}
    output reg         [5:0]  wdata,
    output reg                busy,
    output reg                done,
    // ★ v82：把"每个字段实际显示了多少字符"报给 disp_engine，供 disp/unit_lab.v
    //   把单位（kHz/RPM/DEG/REV）贴着数值右端写 —— 左对齐之后单位必须跟着数值
    //   长度走，静态坐标做不到（见 unit_lab.v 头注释）。len_o 含 ± 号。
    output reg         [3:0]  len_o,
    output reg         [2:0]  fld_o,
    output reg                len_stb     // 每个字段写完的那一拍（与 done 同构）
);

    // ---- 字库索引（不是 ASCII）----
    localparam [5:0] CH_SP    = 6'd0;
    localparam [5:0] CH_DOT   = 6'd1;
    localparam [5:0] CH_MINUS = 6'd2;
    localparam [5:0] CH_PLUS  = 6'd3;
    localparam [5:0] CH_ZERO  = 6'd8;      // '0'；数字 d -> CH_ZERO + d
    localparam [5:0] CH_A     = 6'd18;
    localparam [5:0] CH_B     = 6'd19;
    localparam [5:0] CH_Z     = 6'd43;     // 'Z'（A=18，故 Z=18+25=43；原先误写 33=P）
    // ★ v23：字库末尾追加了三个符号（见 tools/gen_font_rom.py 的 ASCII_CHARS），
    //   索引分别是 % = 44、× = 45、÷ = 46。规范 §4.5 写的是 `×64` `÷1`，
    //   所以卡片 2 的主值从 ASCII 'X'/'/' 换成真正的乘号/除号。
    localparam [5:0] CH_PCT   = 6'd44;     // '%'
    localparam [5:0] CH_MUL   = 6'd45;     // '×'
    localparam [5:0] CH_DIV   = 6'd46;     // '÷'
    // ★ v52（㊾）：● 与 ○ —— 卡 6 主值从 `A1 B0 Z0` 改成规范原文的 `A● B● Z○`
    //   （docs/13_display_ui_requirements.md §4.5）。● 是 v30 追加的状态字形
    //   （索引 48），○ 是本轮**只加进 val 平面**的新字形（索引 51，见
    //   tools/gen_text_ram.py 的 VAL_EXTRA；汉字码一个都没动）。
    //   为什么值得加一个字模：`A1` 与 `A●` 读起来不是同一种东西 —— 前者像"某个
    //   十六进制数"，后者才是"这一路现在是高电平"。而低电平若继续写 `0`，
    //   `A● B● Z0` 里三个位置用了两套符号系统，扫一眼读不出"三路都正常/有一路低"。
    localparam [5:0] CH_DOTF  = 6'd48;     // ● 实心（高电平）
    localparam [5:0] CH_CIRC  = 6'd51;     // ○ 空心（低电平）

    localparam integer NF = 6;             // 字段个数

    // ---- 状态机 ----
    localparam [2:0] S_IDLE = 3'd0,
                     S_PREP = 3'd1,
                     S_DIV  = 3'd2,
                     S_DIVW = 3'd3,
                     S_DDL  = 3'd4,
                     S_DDR  = 3'd5,
                     S_WRP  = 3'd6,
                     S_WRW  = 3'd7;

    reg [2:0]  state;
    reg [2:0]  fld;                        // 当前字段 0..NF-1
    reg [31:0] v32;                        // 待转换的无符号值
    reg        vneg;                       // 该字段是否显示负号
    reg [9:0]  xin;                        // 字段 1 实际要显示的倍频（回读值或待应用值）

    // ---- 版面：每个字段的行/列/宽/小数位 ----
    //   ★ 数值层格列 3/13/23 = x 96/416/736（导航栏 80 + 16 px 内边距）。
    //     卡片 x = 96/416/736、宽 288 px = 整 9 个数值格，所以字段必须落在
    //     列 f_col .. f_col+8 之内：字段 0（f_in，最长的"dddd.dd" = 8 字符）
    //     因此取 f_wid = 9，正好铺满卡片 0 的 96..383。
    //     旧值 f_col = 2/12/22 + f_wid = 10（320 px）让字段 0 的右端伸到 x384，
    //     越出卡片 32..319 右沿整整 64 px —— 真光栅缩略图和 tb_val_format 都能看出来。
    function [3:0] f_row;
        input [2:0] f;
        begin
            case (f)
                // ★ v59：P1 改 2 列 x 3 行，数值格高 48 px，
                //   三行数值的格行分别是 2 / 6 / 10（y 96 / 288 / 480）。
                3'd0, 3'd1: f_row = 4'd2;
                3'd2, 3'd3: f_row = 4'd6;
                // ★ v83（任务B）：卡 6 的两行改成**同字号**（都走数值面 30x48）。
                //   "U● V● W○" 从标签面挪到数值面第 10 行（本模块的字段 5 让位），
                //   所以字段 5 从行 10 下移到行 11：行 10 = y480..527、
                //   行 11 = y528..575，两行 48 px 正好填满卡 6 的 y464..575 区间
                //   （标题行 28 占 y448..463、底注「状态正常」在行 36 = y576..591）。
                3'd5:       f_row = 4'd11;
                default:    f_row = 4'd10;
            endcase
        end
    endfunction

    function [4:0] f_col;
        input [2:0] f;
        begin
            case (f)
                // ★ v59：只有两列了 —— 卡子 96 / 576 就是格列 3 / 18。
                3'd0, 3'd2, 3'd4: f_col = 5'd3;
                default:          f_col = 5'd18;
            endcase
        end
    endfunction

    function [4:0] f_wid;
        input [2:0] f;
        begin
            case (f)
                3'd0: f_wid = 5'd7;   // v79：频率 7 格 = "dddd.dd"（6 格会丢最高位，
                                      //   1500.00 被写成 "500.00"）；右端 x320 < kHz 的 x336
                3'd1: f_wid = 5'd7;
                3'd2: f_wid = 5'd6;   // v74：转速 6 格（右端 x288 < RPM 的 x320）
                3'd3: f_wid = 5'd7;   // v83：角度 7 格 = 负号 + 4 位整数 + 点 + 1 位小数
                                      //   （" -1234.5"）。v82 是 6 格，而单位落点是
                                      //   unit_lab 的 2*len+1 —— 值一旦占满 7 格就会顶到
                                      //   单位的起始格（上板"数字压住 DEG"）。右端
                                      //   x = 576+7*32 = 800 < 满宽单位落点 816。
                3'd4: f_wid = 5'd8;
                default: f_wid = 5'd8;
            endcase
        end
    endfunction

    function [3:0] f_frac;
        input [2:0] f;
        begin
            case (f)
                3'd0: f_frac = 4'd1;  // v78：输入频率改 kHz + 1 位小数（原 v74 为整数 Hz）
                3'd2: f_frac = 4'd1;
                3'd3: f_frac = 4'd1;
                default: f_frac = 4'd0;
            endcase
        end
    endfunction

    // 10^k 常数表（判"这一位要不要显示前导零"用）
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

    // =========================================================================
    // 1. 定点缩放（全部用移位/加法，绝不写 '*'，避免综合出 DSP）
    // =========================================================================
    wire [39:0] f_mag40 = f_q10[31] ? {8'd0, (~f_q10 + 32'd1)} : {8'd0, f_q10};

    // f_x100 = |f_q10| * 25 / 256 ，即 f_in 的 100 倍（2 位小数）。
    //   +128 是"四舍五入"：截断会带 -0.5 LSB 的系统性偏低，屏上读数会稳定少 0.01 Hz。
    wire [39:0] fx100_full = (f_mag40 << 4) + (f_mag40 << 3) + f_mag40 + 40'd128;
    wire [31:0] f_x100     = fx100_full[39:8];

    // rpm_x10 的分子 = |f_q10| * 75（75 = 64+8+2+1），再除以 (128 * cpr)
    wire [39:0] rpm_num = (f_mag40 << 6) + (f_mag40 << 3) + (f_mag40 << 1) + f_mag40;

    // 角度 0.1 度 = angle * 3600 / 65536 = angle * 225 / 4096（+2048 同样是四舍五入）
    wire [31:0] ang_x = {16'd0, angle};
    wire [31:0] ang225 = (ang_x << 7) + (ang_x << 6) + (ang_x << 5) + ang_x + 32'd2048;
    wire [31:0] ang_x10 = ang225 >> 12;

    // 累计转数 = Z 计数（rev_bin），★ v86 起与 pos_acc 的积分路径彻底解耦。
    //   pos_acc 端口保留（enc_top_disp 的 tap 链路与将来用位置算转数的
    //   回退方案都要它），但本版不再参与任何字段的换算。
    wire [39:0] rev_ext = {23'd0, rev_bin};

    // 每转电周期数：CPR>0 时用固定值（v68 显示 64），否则沿用 cfg_pairs。
    // 极对数保护：0 视为 1（寄存器复位值本来就是 4）。
    wire [4:0]  pairs_s = (cfg_pairs == 5'd0) ? 5'd1 : cfg_pairs;
    wire [15:0] cpr_s   = (CPR > 0) ? CPR : {11'd0, pairs_s};

    // 除法器输入（按当前字段选择）
    // ★ v86：fld4 的商就是 rev_bin 本身（除数 1），后面照旧走
    //   S_DIV → S_DDL → S_DDR → 数字分支，一行渲染逻辑都不用改。
    wire        need_div = (fld == 3'd2) || (fld == 3'd4);
    wire [39:0] div_num = (fld == 3'd2) ? rpm_num : rev_ext;
    wire [19:0] div_den = (fld == 3'd2) ? ({4'd0, cpr_s} << 7) : 20'd1;

    reg  [39:0] div_num_r, div_quot;
    reg  [19:0] div_den_r;
    reg         div_start;
    wire [39:0] div_q;
    wire [39:0] div_rem;
    wire        div_busy, div_done;

    fixed_div #(.W(40), .DW(20)) u_div (
        .clk(clk), .rst_n(rst_n), .start(div_start),
        .dividend(div_num_r), .divisor(div_den_r),
        .quotient(div_q), .remainder(div_rem),
        .busy(div_busy), .done(div_done)
    );

    // =========================================================================
    // 2. double-dabble：32 位二进制 -> 10 位 BCD（32 拍，不用除法）
    // =========================================================================
    reg  [31:0] dd_bin;
    reg  [39:0] dd_bcd;
    reg  [5:0]  dd_cnt;
    integer     k;
    reg  [39:0] dd_adj;

    always @* begin
        dd_adj = dd_bcd;
        for (k = 0; k < 10; k = k + 1)
            if (dd_bcd[k*4 +: 4] >= 4'd5)
                dd_adj[k*4 +: 4] = dd_bcd[k*4 +: 4] + 4'd3;
    end

    // =========================================================================
    // 3. 字段字符缓冲
    // =========================================================================
    reg [5:0]  cbuf [0:15];
    reg [4:0]  wcnt;
    integer    p, di;

    // ★ v82（P1 版面）：数值字段改**左对齐**。
    //   v81 之前数值是右对齐写进 [f_col, f_col+f_wid) 的，于是同一个卡列里
    //   "28.3"（4 字符）贴着字段右端、"12345678"（8 字符）铺满，数值左边界
    //   随字符数漂移 —— 上板就是"输入频率的数值比转速的数值明显靠右"。
    //   现在仍然复用同一套右对齐的字符生成逻辑（cbuf 尾部连续），只在写回
    //   数值层时**把 cbuf 的有效尾部搬到字段左端**，多出来的格子写空格。
    //   代价：只有地址/数据两个 2:1~3:1 mux，没有桶形移位器（LUT 预算只剩
    //   ~220，见 docs 资源表）。
    integer    pmax, q;
    reg [4:0]  ndig;                       // 本字段实际显示的字符数（不含 ± 号）
    reg        sign_on;                    // 本字段是否带 ± 号（只有角度字段）
    reg [5:0]  wlen;                       // = ndig + sign_on，从字段左端起算的字符数
    integer    ndig_c;                     // S_WRP 里的组合临时
    reg        sign_c;

    // 倍频数字的十进制拆分（用有界的减法链，绝不写 '/' 或 '%'：
    // 除数是常数时综合器虽能优化，但这里干脆给出显式结构，读的人也一眼能核）
    integer    xi;
    reg [9:0]  xr;
    reg [3:0]  xh, xt;

    // =========================================================================
    // 4. 状态机
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; fld <= 3'd0; v32 <= 32'd0; vneg <= 1'b0;
            we <= 1'b0; waddr <= 9'd0; wdata <= 6'd0;
            busy <= 1'b0; done <= 1'b0;
            div_start <= 1'b0; div_num_r <= 40'd0; div_den_r <= 20'd1;
            div_quot <= 40'd0;
            dd_bin <= 32'd0; dd_bcd <= 40'd0; dd_cnt <= 6'd0;
            wcnt <= 5'd0;
            len_o <= 4'd0; fld_o <= 3'd0; len_stb <= 1'b0;
        end else begin
            we    <= 1'b0;
            done  <= 1'b0;
            len_stb <= 1'b0;

            case (state)
                // ---------------- 待命 ----------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        fld  <= 3'd0;
                        state <= S_PREP;
                    end
                end

                // ---------------- 准备本字段的待转换值 ----------------
                S_PREP: begin
                    vneg <= 1'b0;
                    // ★ v77（P1 频率显示错）根因：f_q10 是 1/1024 Hz 定点，
                    //   v74 之前这里是 v32 <= f_x100（= f_q10*25/256 = 频率×100），
                    //   而 fld0 的 f_frac 又被改成 0（只显示整数），于是屏上打出来的是
                    //   "频率×100"的整数：25.4 kHz 显示成 2543200，上板那张图里的
                    //   5423200 就是同一回事（54.2 kHz 口径）。不是频率计算错，而是
                    //   **这里取数少除了 100**。
                    //   这里直接取 f_mag40[39:10]（= |f_q10| >> 10 = Hz 整数），与
                    //   f_frac=0 / f_wid=6（可放 5 位 + 1 空格）配套；28602 正好 5 位。
                    // ★ v78：屏上改为 kHz + 1 位小数（用户 2026-11-02 要求"28.3kHz"）。
                    //   f_mag40[39:10] 是 Hz 整数；kHz×10 = Hz/100。
                    //   用 ×41>>12（=0.010010，误差 0.1%）代替除以 100：常数除法 Vivado 也会
                    //   拆成乘法+移位，但显式写出来能保证是 1 个 DSP 或几十个 LUT，且 +2048 是
                    //   四舍五入（0.5 LSB = 0.05 kHz？不，0.5/10 kHz=0.005 kHz，足够）。
                    //   28602 Hz → (28602*41+2048)>>12 = 286 → 屏显 "28.6"（f_frac=1 插小数点）。
                    if (fld == 3'd0) begin                 // f_in，kHz（1 位小数）
                        v32 <= ({8'd0, f_mag40[39:10]} * 32'd41 + 32'd2048) >> 12;
                        state <= S_DDL;
                    end else if (fld == 3'd1) begin        // 倍频/分频，直接铺字符
                        state <= S_WRP;
                    end else if (fld == 3'd2) begin        // 转速，需要除 128*pairs
                        div_num_r <= rpm_num + {20'd0, div_den[19:1]};   // +den/2 = 四舍五入
                        div_den_r <= div_den;
                        state <= S_DIV;
                    end else if (fld == 3'd3) begin        // 角度，1 位小数，带符号
                        v32  <= ang_x10;
                        vneg <= f_q10[31];                 // 负号 = 当前是反转
                        state <= S_DDL;
                    end else if (fld == 3'd4) begin        // 累计转数，需要除 pairs
                        div_num_r <= rev_ext;                 // 商就是 Z 计数本身
                        div_den_r <= 20'd1;
                        vneg      <= 1'b0;                    // 计数永远不带负号
                        state <= S_DIV;
                    end else begin                         // fld==5：ABZ 电平
                        state <= S_WRP;
                    end
                end

                // ---------------- 除法握手 ----------------
                S_DIV: begin
                    div_start <= 1'b1;
                    state <= S_DIVW;
                end

                S_DIVW: begin
                    div_start <= 1'b0;
                    if (div_done) begin
                        v32   <= div_q[31:0];
                        state <= S_DDL;
                    end
                end

                // ---------------- double-dabble 装载 / 迭代 ----------------
                S_DDL: begin
                    dd_bin <= v32;
                    dd_bcd <= 40'd0;
                    dd_cnt <= 6'd0;
                    state  <= S_DDR;
                end

                S_DDR: begin
                    if (dd_cnt == 6'd32) begin
                        state <= S_WRP;
                    end else begin
                        dd_bcd <= {dd_adj[38:0], dd_bin[31]};
                        dd_bin <= {dd_bin[30:0], 1'b0};
                        dd_cnt <= dd_cnt + 6'd1;
                    end
                end

                // ---------------- 铺字符 ----------------
                S_WRP: begin
                    for (p = 0; p < 16; p = p + 1) cbuf[p] = CH_SP;
                    pmax   = 0;
                    ndig_c = f_wid(fld);       // 串字段（fld1/fld5）与空态天然铺满
                    sign_c = 1'b0;

                    if (fld == 3'd1) begin
                        // 倍频/分频："X" + inter(右对齐) + " /" + div
                        // 先把 cfg_inter(0..256) 拆成百/十/个位（纯减法链，无除法）
                        // ★ inter 寄存器 0 在 rtl/abz_gen.v:118 里表示 **256**，
                        //   所以这里必须先映射再拆位，否则复位后屏上显示 "X0 /1"
                        //   而编码器实际在按 256 倍跑 —— 数字与行为不一致是
                        //   docs/13 明令禁止的（"屏只能显示真实值"）。
                        // ★ v22：面板开着时这里显示的是"待应用值"（见端口注释）。
                        xin = pnl_on ? pnl_inter : cfg_inter;
                        xr = {6'b0, (xin == 10'd0) ? 10'd256 : xin};
                        xh = 4'd0;
                        for (xi = 0; xi < 3; xi = xi + 1)
                            if (xr >= 10'd100) begin xr = xr - 10'd100; xh = xh + 4'd1; end
                        xt = 4'd0;
                        for (xi = 0; xi < 10; xi = xi + 1)
                            if (xr >= 10'd10) begin xr = xr - 10'd10; xt = xt + 4'd1; end
                        cbuf[0] = CH_MUL;
                        cbuf[1] = (xh != 4'd0) ? (CH_ZERO + xh) : CH_SP;
                        cbuf[2] = ((xh != 4'd0) || (xt != 4'd0)) ? (CH_ZERO + xt) : CH_SP;
                        cbuf[3] = CH_ZERO + xr[3:0];
                        cbuf[4] = CH_SP;
                        cbuf[5] = CH_DIV;
                        cbuf[6] = CH_ZERO + {3'b0, (pnl_on ? pnl_div : cfg_div)} + 6'd1;
                        //        ↑ v44（㊶）：面板里改了分频也要**先显示待应用值** ——
                        //          div 寄存器 0 表示 ÷1，而面板的 pnl_didx 就是寄存器值。 
                    end else if (fld == 3'd5) begin
                        // ABZ 电平："A● B● Z○"（规范 §4.5 原文；v52 之前是 "A1 B0 Z0"）
                        cbuf[0] = CH_A;
                        cbuf[1] = io_state[0] ? CH_DOTF : CH_CIRC;
                        cbuf[2] = CH_SP;
                        cbuf[3] = CH_B;
                        cbuf[4] = io_state[1] ? CH_DOTF : CH_CIRC;
                        cbuf[5] = CH_SP;
                        cbuf[6] = CH_Z;
                        cbuf[7] = io_state[2] ? CH_DOTF : CH_CIRC;
                        // ★ v83：本支没有数字循环，必须显式给出有效字符数 ——
                        //   否则 ndig_c/sign_c 会留着**上一个字段**（累转数）的值，
                        //   于是 wlen 也错，len_o 报给 unit_lab 的长度随之错一帧。
                        ndig_c = 8;
                        sign_c = 1'b0;
                    end else if (nodata_mask[fld]) begin
                        // v45（㊷）/ v46（㊸）空态：整格 '-'，小数点保留 ⇒ 例如
                        //   f_in 显示 "------.--"（无载波与 CRC 错共用这一支）
                        //   不做前导零抑制、不留空白：空态要**看得出来是空态**。
                        for (p = 0; p < 16; p = p + 1) begin
                            if (p < {1'b0, f_wid(fld)}) begin
                                if ((f_frac(fld) != 4'd0) && (p == {1'b0, f_frac(fld)}))
                                    cbuf[f_wid(fld) - 5'd1 - p] = CH_DOT;
                                else
                                    cbuf[f_wid(fld) - 5'd1 - p] = CH_MINUS;
                            end
                        end
                        // ★ v83：空态同样要显式给有效字符数（整格 '-'，无 ± 号），
                        //   否则 ndig_c/sign_c 沿用上一字段，len_o 会报错长度。
                        ndig_c = f_wid(fld);
                        sign_c = 1'b0;
                    end else begin
                        // 数字字段：右对齐，小数点在从右数第 frac 位
                        // ★ v83：pmax 先清零再进循环 —— 否则"这一帧一位都没输出"
                        //   （理论上到不了）时会沿用上一字段的 pmax，len_o 就错了。
                        pmax = 0;
                        for (p = 0; p < 16; p = p + 1) begin
                            if (p < {1'b0, f_wid(fld)}) begin
                                if ((f_frac(fld) != 4'd0) && (p == {1'b0, f_frac(fld)})) begin
                                    cbuf[f_wid(fld) - 5'd1 - p] = CH_DOT;
                                    pmax = p;              // v82：记下最左的有效格
                                end else begin
                                    // di = 这一位是第几个 BCD 数字。
                                    // 有小数点时：点右边 p<frac 用 di=p，点左边 di=p-1；
                                    // 没有小数点（frac==0）时每一位都只是 di=p。
                                    di = (f_frac(fld) == 4'd0) ? p
                                       : ((p < {1'b0, f_frac(fld)}) ? p : (p - 1));
                                    // 前导零抑制只作用于小数点**左侧**、且高于个位的位；
                                    // 小数位与个位永远显示 —— 否则 0.0 会被削成空白
                                    if ((di <= 9) &&
                                        ((di <= f_frac(fld)) || (v32 >= pow10(di[3:0])))) begin
                                        cbuf[f_wid(fld) - 5'd1 - p] = CH_ZERO + dd_bcd[di*4 +: 4];
                                        pmax = p;              // v82：记下最左的有效格
                                    end
                                end
                            end
                        end
                        // 负号放在最左（只有角度字段用）
                        if (vneg) cbuf[0] = CH_MINUS;
                        else if (fld == 3'd3) cbuf[0] = CH_PLUS;   // 角度固定带方向符号
                        // v82：有效字符数 = pmax+1；角度字段另有 1 个 ± 号
                        ndig_c = pmax + 1;
                        sign_c = (fld == 3'd3);
                    end

                    ndig    <= ndig_c[4:0];
                    sign_on <= sign_c;
                    wlen    <= ndig_c[5:0] + {5'd0, sign_c};

                    wcnt  <= 5'd0;
                    state <= S_WRW;
                end

                // ---------------- 逐字符写回数值层 RAM ----------------
                // v82：左对齐搬运 —— cbuf 的有效字符在尾部 [f_wid-wlen .. f_wid)，
                //   这里把第 q 个（从右数）字符写到 f_col+wlen-1-q，于是有效串落在
                //   字段最左；字段右端剩余 f_wid-wlen 格显式写空格（必须写，否则
                //   上帧更长的数字会留残影）。
                S_WRW: begin
                    we <= 1'b1;
                    q  = wcnt;
                    if (q < wlen) begin
                        waddr <= {f_row(fld), f_col(fld) + wlen[4:0] - 5'd1 - q[4:0]};
                        // q<ndig：数字/小数点（cbuf 尾部）；q==ndig：± 号（cbuf[0]）
                        wdata <= (q < ndig) ? cbuf[f_wid(fld) - 5'd1 - q[4:0]] : cbuf[0];
                    end else begin
                        waddr <= {f_row(fld), f_col(fld) + q[4:0]};
                        wdata <= CH_SP;
                    end
                    wcnt  <= wcnt + 5'd1;

                    if (wcnt == (f_wid(fld) - 5'd1)) begin
                        // ★ v82：本字段写完 —— 把"实际字符数"报给 unit_lab
                        len_o   <= wlen[3:0];
                        fld_o   <= fld;
                        len_stb <= 1'b1;
                        if (fld == (NF - 1)) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            fld   <= fld + 3'd1;
                            state <= S_PREP;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
