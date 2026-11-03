//=============================================================================
// stat_chip.v -- P1 六张卡的"迷你状态条"（规范 4.3 / 5.2 的状态字模上屏）
//
// 职责：每帧把六张卡各自的状态判据渲染成 "字形 + 两字状态词"，写进 P1 的 lab
//       平面。每张卡四格：第 0 格字形（●/▲/✖）、第 1 格空格、第 2/3 格状态词。
//       格行/格列与 tools/gen_text_ram.py 的 P1_LAB 静态兜底**逐格相同**：
//         卡 1/2/3（第一排）格行 15，格列 6/26/46
//         卡 4/5/6（第二排）格行 36，格列 6/26/46
//
// 屏上长这样（卡 1 = 正常、卡 2 = 警示、卡 3 = 故障）：
//        6    7    8    9
//        ●    (空) 正   常
//        ▲    (空) 警   示
//        ✖    (空) 故   障
//
// 为什么不是规范原文的 "y+148"：本工程的卡片是 288x256 @ y 64/336（不是规范样例
// 的 300x264 @ y 100/372），第二排卡片的 y+148 正好压在 48 px 数值字形上。所以
// 迷你状态条落在"数值/次级信息之下、卡框之内"的最后一行空行上；两排的行号差 21
// 格是卡片几何决定的（见 docs/DEV_STATUS.md 的 U-31）。
//
// ★ 规范 5.2 的"四重冗余"：**字形（●▲✖）+ 中文文字（正常/警示/故障）** 由本模块
//   产出；另两重（第三重"反转视频（白字反色块）"、第四重"可关闭的 ~2 Hz 闪烁"）由
//   `disp/disp_engine.v` 的状态条图层实现（v31 反转 `scbar_inv` / v32 闪烁 `scbar_blk`，
//   开关 `ui_blink_en` 来自 `disp/enc_top_disp.v` 的 scr_blink）—— 它们读的正是本模块
//   的 `sc_chip_st`，所以**改本模块的判据表，那两重会跟着走**。
//   ★ 本文件 v31 之前写的"反转/闪烁本版明确不做"已过时（㊷ 勘误）：那两重在 v31/v32
//     就落地了，只是落在像素层的状态条图层上，不在这个字符写口模块里。
//
// 判据表（本表是唯一出处；改了这里就要同步 tb_stat_chip.v 与 U-31 的文档）：
//   ★ v46（㊸）空态：`sig_bad` = **测量数据不可信**（判据在 disp_engine，唯一来源
//                   **无载波** = `tap_amp_sq < tap_amp_low_sq`（幅值低于下限门限）；
//                   v45 的原链路 CRC 项与 v54 的原链路静默项在 v74 后恒 0）。
//                   ★ 仍**不含** cor_sat / amp_bad 这两个**标志位** —— 它们已经各自
//                   落在卡 3/卡 4 的判据上，见下面那张表，并进 sig_bad 会丢信息）。
//     四个**测量**卡（输入频率/转速/角度/累计转数）在 sig_bad
//     时一律 ✖ 故障 —— 读数已经没有意义，不能继续报"● 正常 + 0.00 Hz"。
//     卡 2（倍频分频）是配置回读、卡 6（ABZ/UVW）是使能状态，与输入信号无关 ⇒ 不变。
//   卡 1 输入频率  ✖ lag_fatal(io_flags[1]) 或 sig_bad   ▲ lag_warn(io_flags[0])
//   卡 2 倍频分频  ✖ --                              ▲ stat[3] inclim（限频或 UVW 频率告警）
//   卡 3 转速      ✖ amp_bad(io_flags[7]) 或 sig_bad    ▲ stat[5] scamp（幅值越限）
//   卡 4 角度      ✖ cor_sat(io_flags[6]) 或 sig_bad    ▲ stat[0] oflow（cor_sat | otr_lat）
//   卡 5 累计转数  ✖ sig_bad                         ▲ stat[2] laglim（限频/滞后 ⇒ 计数不可信）
//   卡 6 ABZ/UVW   ✖ ABZ 与 UVW 都未使能             ▲ uvw_warn(io_flags[3]) 或任一路未使能
// 优先级：故障 > 警示 > 正常（与 disp_engine 的告警灯 alert_col 同一口径）。
//
// 仲裁：P1 的 lab 写口还接着 disp/undo_lab.v（面板「↩ 回到 ×N」按钮标签，第 34 行
//   46..52 格）。两个写者的**行号从不冲突**（15/36 对 34），但 RAM 只有一个写口，
//   所以由 disp_engine 做优先权选择：面板标签优先，本模块在 hold=1 的拍上**既不写
//   也不推进**（stall），等空闲拍再写。面板一帧只占 7 拍，本模块 24 拍，一帧 1024x600
//   个时钟，绝不会饿死；hold 只影响"第几拍写完"，不影响写完的结果。
//   ★ "stall" 要成立，本模块的 we 必须是**组合**输出（见第 3 节的坑）：寄存一拍就等于
//     提前一拍猜 hold，会让"已经发出的 we"在下一拍被别人抢走 —— 那一格静默丢一帧。
//   ★ 第二条同类的坑（见 cell_at 的注释）：状态必须走**函数参数**。函数体里读模块级
//     变量不会进连续赋值的灵敏度表 ⇒ 字形格会整张卡停在上一张卡的状态上（U-31 记录 53）。
//
// 时序：start = disp_engine 的 vf_start（帧起始单拍，与 undo_lab/p2_badge 同一个信号）。
//=============================================================================
`default_nettype none

module stat_chip (
    input  wire        clk,
    input  wire        rst_n,          // 异步复位、低有效
    input  wire        start,          // vf_start：帧起始单拍
    input  wire [7:0]  io_flags,       // telemetry {amp_bad,cor_sat,uwven,abzen,uvw_warn,z_win,lag_fat,lag_warn}
    input  wire [7:0]  stat,           // TW28 兼容状态字 {res,adapt,scamp,lagfatl,inclim,laglim,falarm,oflow}
    input  wire [5:0]  bad_mask,       // v60/R1：每卡一位"本卡数据不可信"（拆开故障源）
    input  wire        hold,           // 写口被占用（面板标签正在写）→ 本拍不写、不推进

    output wire [11:0] chip_st,        // 每卡 2 bit 状态：0=正常 1=警示 2=故障（探针/测试用）
    output wire        we,
    output wire [11:0] waddr,
    output wire [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    // 字符码：与 tools/gen_font_rom.py 的 ASCII_CHARS / tools/cn_glyphs.py 的顺序一致
    //   ASCII: ' '=0, '●'=48, '▲'=49, '✖'=50（v30 追加在 ASCII 段末尾）
    //   汉字 : 码 = ASCII_COUNT(51) + cn_glyphs.CHARS 的下标
    //          '故'=97 '障'=98（v23 就在表内）／'正'=134 '常'=135 '警'=136 '示'=137
    localparam [7:0] CH_SP    = 8'd0;
    localparam [7:0] CH_OK    = 8'd48;    // ●
    localparam [7:0] CH_WARN  = 8'd49;    // ▲
    localparam [7:0] CH_FAULT = 8'd50;    // ✖
    localparam [7:0] CH_ZHENG = 8'd134;   // 正
    localparam [7:0] CH_CHANG = 8'd135;   // 常
    localparam [7:0] CH_JING  = 8'd136;   // 警
    localparam [7:0] CH_SHI   = 8'd137;   // 示
    localparam [7:0] CH_GU    = 8'd97;    // 故
    localparam [7:0] CH_ZHANG = 8'd98;    // 障

    localparam [1:0] ST_OK = 2'd0, ST_WARN = 2'd1, ST_FAULT = 2'd2;

    // ★ v59：P1 卡片墙 2 列 x 3 行，状态行随卡片走：
    //   行 10 / 23 / 35（y 160 / 368 / 560）、列 6 / 36（x 96 / 576）。
    localparam [5:0] ROW_0   = 6'd7;     // 第 1 行卡片的状态条格行
    localparam [5:0] ROW_1   = 6'd19;     // 第 2 行卡片
    localparam [5:0] ROW_2   = 6'd31;     // 第 3 行卡片
    localparam [5:0] COL_0   = 6'd30;      // 左列卡片状态格 30..33（卡右沿 33）
    localparam [5:0] COL_1   = 6'd60;      // 右列卡片状态格 60..63（格列 6 bit，>60 会回卷）
    localparam [4:0] N_CELL  = 5'd23;     // 写 24 格（idx = 0..23）

    // ---------------------------------------------------------------------
    // 1. 六张卡的状态（判据表见文件头）
    //    ★ v45（㊷）/ v46（㊸）：四个测量卡（频率/转速/角度/累计转数）在 sig_bad
    //      （链路 CRC 错 或 无载波）时直接 ✖ 故障。
    //      优先级仍是 故障 > 警示 > 正常（与 disp_engine 的告警灯 alert_col 同口径）。
    // ---------------------------------------------------------------------
    wire [1:0] st_vfreq = (bad_mask[0] || io_flags[1]) ? ST_FAULT : (io_flags[0] ? ST_WARN : ST_OK);
    wire [1:0] st_ratio = stat[3]     ? ST_WARN  : ST_OK;
    wire [1:0] st_rpm   = (bad_mask[2] || io_flags[7]) ? ST_FAULT : (stat[5] ? ST_WARN : ST_OK);
    wire [1:0] st_angle = (bad_mask[3] || io_flags[6]) ? ST_FAULT : (stat[0] ? ST_WARN : ST_OK);
    wire [1:0] st_revs  = bad_mask[4] ? ST_FAULT : (stat[2] ? ST_WARN : ST_OK);
    wire [1:0] st_abzuvw = (!io_flags[4] && !io_flags[5]) ? ST_FAULT :
                           ((io_flags[3] || !io_flags[4] || !io_flags[5]) ? ST_WARN : ST_OK);

    assign chip_st = {st_abzuvw, st_revs, st_angle, st_rpm, st_ratio, st_vfreq};

    // ---------------------------------------------------------------------
    // 2. 每格写什么：idx[4:2] = 第几张卡，idx[1:0] = 卡内第几格
    //    （idx 是下面的写序列状态机的索引，这里提前声明：Verilog 要求先用后声明
    //     不允许，xsim 直接报 "identifier 'idx' is used before its declaration"）
    // ---------------------------------------------------------------------
    reg [4:0] idx;

    wire [2:0] chip = idx[4:2];
    wire [1:0] cellk = idx[1:0];       // 注意：`cell` 是 Verilog 保留字，不能用

    reg [1:0] cst;
    always @* begin
        case (chip)
            3'd0:    cst = st_vfreq;
            3'd1:    cst = st_ratio;
            3'd2:    cst = st_rpm;
            3'd3:    cst = st_angle;
            3'd4:    cst = st_revs;
            default: cst = st_abzuvw;
        endcase
    end

    // 第 2/3 格的字：两字词按状态选（正常/警示/故障）
    function [7:0] word_at;
        input [1:0] s;
        input       hi;         // 1 = 词的第 2 个字
        begin
            case (s)
                ST_OK:    word_at = hi ? CH_CHANG : CH_ZHENG;
                ST_WARN:  word_at = hi ? CH_SHI   : CH_JING;
                default:  word_at = hi ? CH_ZHANG : CH_GU;
            endcase
        end
    endfunction

    function [7:0] cell_at;
        input [1:0] k;          // 卡内第几格
        input [1:0] s;          // 该卡的状态
        // ★ 状态必须走**参数**，不能在函数体里直接读模块级的 cst：
        //   连续赋值 `assign wdata = cell_at(cellk)` 的灵敏度表只由**实参**决定，
        //   函数体里读的模块级变量**不进灵敏度表** ⇒ wdata 只在 cellk 变化时重算。
        //   cellk 每张卡才换一次（3→0），而那一拍 cst 也刚更新，两个进程在同一个
        //   时间步里抢先后：xsim 里 cellk 先算 ⇒ 字形格整整一张卡都停在上一张卡的
        //   状态上（文字格因为走 word_at(s,…) 参数所以是对的，现象极其误导）。
        //   端到端 [11] 段就是这么红的（U-31 / 记录 53）。
        begin
            case (k)
                2'd0:    cell_at = (s == ST_OK)   ? CH_OK :
                                   (s == ST_WARN) ? CH_WARN : CH_FAULT;
                2'd1:    cell_at = CH_SP;
                2'd2:    cell_at = word_at(s, 1'b0);
                default: cell_at = word_at(s, 1'b1);
            endcase
        end
    endfunction

    // ★ v59：chip 编号仍是 0..5，但排布改成**行优先**：
    //   chip = 2*row + col（与 hit_test 的 card_id = 8 + col + 2*row 同一套）。
    wire [5:0] row = (chip < 3'd2) ? ROW_0 :
                     (chip < 3'd4) ? ROW_1 : ROW_2;
    // 列序 = 卡内的第几列（0/1/2）。**不能直接用 chip[1:0]**：卡 4/5/6 的 chip 是
    // 3/4/5，低两位是 3/0/1，会把三列顺序搅成 2/0/1（单元测试第一次就是这么红的）。
    wire [5:0] col = chip[0] ? COL_1 : COL_0;

    // ---------------------------------------------------------------------
    // 3. 写序列：帧起始开始，每个可写拍写一格，写完 24 格再给一拍 done
    //    hold=1 的拍上 we=0 且 idx 不推进（面板标签优先占写口）
    //   ★ 三个写信号是**组合**的（we = 在写状态 ∧ !hold），不是寄存的。
    //     踩过的坑（U-31 / 记录 53）：寄存版把"这一拍是不是被面板占了"提前一拍
    //     猜了 —— 决定写的那拍 hold=0，下一拍 hold 可能变成 1，此时 disp_engine
    //     的写口 mux 已让给 undo_lab，这笔 we（连同 waddr/wdata）就被无声吃掉，
    //     而 idx 照常推进 ⇒ **每帧丢一格**。屏上的现象极隐蔽：只有每帧第一格停在
    //     上一帧的值上（正常轮看不出来，因为静态兜底恰好也是"●正常"）。
    //     改成组合后，"在写 ∧ !hold"是同一拍的一件事：要么这一拍真的写进去，
    //     要么根本没发出 we（idx 也不推进），不存在"发出去了没人收"的中间态。
    //     waddr/wdata 同样是 idx 的纯组合函数，we 有效的拍上地址必然有效。
    // ---------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;

    reg [1:0] st;

    assign we    = (st == S_WR) && !hold;
    assign waddr = {row, col + {4'd0, cellk}};
    assign wdata = cell_at(cellk, cst);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            idx  <= 5'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                            st   <= S_WR;
                            idx  <= 5'd0;
                            busy <= 1'b1;
                        end
                S_WR: if (!hold) begin
                            if (idx == N_CELL) st <= S_DONE;
                            else               idx <= idx + 5'd1;
                        end
                default: begin                 // S_DONE
                            st   <= S_IDLE;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
            endcase
        end
    end

endmodule

`default_nettype wire
