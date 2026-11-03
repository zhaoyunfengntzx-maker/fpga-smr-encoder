//=============================================================================
//  ui_restore.v —— P6「恢复默认」：一条**命令序列播放器** + 全序列回读确认
//-----------------------------------------------------------------------------
//  为什么不是「一条新协议命令」
//    docs/13_display_ui_requirements.md:202 要求危险区有「恢复默认」，:286-292
//    （spec §6.4）把它列进"必须二次确认"的动作里。但 rtl/SPEC_interface_contract.md
//    是**已签核的冻结契约**：加一条新命令要动 rtl/、约束、上位机与签核记录。
//    ★ 不必动：现有的写命令一条就能写**两个连续寄存器**
//      （b2 -> addr+1、b3 -> addr，见 disp/ui_edit.v 的模块头），所以 P6 可见的
//      15 项 + 两个标定偏置（OFS_S / OFS_C）一共只要 **13 条**命令。
//    本模块就是那 13 条命令的播放器，走的是 disp/ui_edit.v 同一条路：
//    在 FPGA 内部当"UART 下面的第二台 PC"，把字节打到 enc_top.uart_rx 上。
//
//  13 条命令（= 16 个寄存器；地址与写入值全部是 reg_file 的**复位默认值**）
//    序号  起始地址   b2（-> addr+1）  b3（-> addr）   覆盖的 P6 项
//     0     0x0100      0x00            0x04        极对数（UVW_CFG = 4）
//     1     0x0101      0x00            0x00        倍频 + 分频（INTER0/INTER1）
//     2     0x0102      0x00            0x00        分频（INTER1 高 2 位）+ 迟滞
//     3     0x0106      0x0A            0x00        限幅（+ ZERO0 的默认 0x0A）
//     4     0x0108      0x40            0x00        Z 脉宽（+ OUTPUT 的默认 0x40）
//     5     0x010A      0x00            0x00        Z 相位 + UVW 相位
//     6     0x010C      0x00            0x00        相位低位（0x010D 未映射，写它被忽略）
//     7     0x0510      0x00            0x00        标定偏置 S（OFS_S）
//     8     0x0512      0x00            0x00        标定偏置 C（OFS_C）
//     9     0x0514      0x80            0x00        增益 S（GAIN_S = 0x8000 = 32768）
//    10     0x0516      0x80            0x00        增益 C（GAIN_C = 0x8000）
//    11     0x0518      0x00            0x00        相位修正（PHASE_K）
//    12     0x051A      0x00            0x00        SHIFT（+ H2_K 的默认 0）
//    ★ 顺带写掉的邻居（ZERO0 / OUTPUT / H2_K / 0x010D）本来就是默认值，
//      写它们等于"恢复默认"，不会引入任何非默认状态。
//
//  为什么"回读确认"是必须的
//    spec §6.2（docs/13_display_ui_requirements.md:258-269，本项目最重要的交互契约）
//    写着「屏幕绝不允许显示『用户想要的理想值』，只能显示寄存器回读确认过的实际值」。
//    所以本模块**不等** settle 就报成功：13 条命令全部发完，再等 SETTLE_CLK（2 ms）
//    让桥释放 uart_tx、遥测帧恢复，然后拿 disp_tap 的 17 个字段逐项比对默认值。
//
//  失败策略 = 用户拍板的 F1：**不回滚** + 红 ✖ 指出是哪一项没回读上
//    · 17 项逐项比对，其中 15 项直接对应 P6 的 15 个行带格位 ⇒ 输出 `bad[14:0]`，
//      位序 = 行*3 + 列（行 0..4 是 5 个 88 px 行带，列 0..2 是三列）；
//    · 显示层在置位的项那一行的标题右侧画一个**红 ✖**（字形 + 颜色，spec §5.2），
//      并把第 2 颗按钮的描边置红；全一致则描边置绿（C_OK）；
//    · OFS_S / OFS_C 在 P6 上没有自己的行，它们的失败折进同通道的「增益S」/「增益C」
//      那一格（标定参数是同一族，✖ 表示"S/C 通道的标定没恢复"）。
//    · ★ 为什么屏上只有 ✖、不再显示十六进制错误码（用户确认，2026-㊴）：
//      `bad[14:0]` 的 15 位与 P6 的 15 个格位**一一对应**，✖ 的位置/形状本身
//      就是"哪一项"的编码，是"位置 + 形状 + 颜色"三重冗余（spec §5.2 要求
//      颜色绝不作为唯一编码）；再叠一个 `ERR 0X0010` 只是把同一信息换成
//      更难读的第二层编码（现场用户没有十六进制码表），还要为此新增一个
//      hex 格式化器。docs/13 那条流程图里的"错误码"就落在这些 ✖ 上。
//    · ★ 为什么不像 ui_edit 那样回滚：恢复默认的"旧值"是用户当前的一整套配置，
//      "写坏一半再回滚一半"比"停在写坏的状态并明确指出来"更危险 —— 前者会留下
//      一个既不是旧配置也不是默认值的**第三种**状态，而后者至少是可以说清的。
//
//  时序预算（clk 50 MHz、BAUD_DIV=25、GAP_CLK=25000、SETTLE_CLK=100_000）
//    一条命令 = 4 字节 x 5 µs + 500 µs 空闲 ≈ 520 µs；13 条 ≈ 6.8 ms，
//    再加 2 ms settle ⇒ **整条序列 ≈ 8.8 ms**（人眼仍然只看到"闪一下"）。
//  ★ 为什么命令之间要空 500 µs（而不是最初写的 80 µs）
//    rtl/uart_spi_bridge.v 是"收 4 字节 -> 内部 SPI 帧（10.56 µs）-> 抢遥测
//    空闲发 6 字节应答"的串行流程：C_SPI1 之后进 C_REPLY（等 scope_idle，
//    uart_scope 以 10 kHz 发 18 字节帧、行空闲窗口只有约 10 µs ⇒ 最坏要 ~100 µs）
//    再进 C_TX（6 字节 = 30 µs）。**这段窗口内它不再看 rx**（bridge 的
//    rtl/uart_spi_bridge.v:207-315 只在 C_IDLE/C_BYTE 里消费 rx_valid），
//    所以下一条命令的首字节如果在这期间到达就被**整条丢掉**（第 2~4 字节
//    因"首字节 bit7 必须为 1"与 GAP_MIN 两条规则被拒绝，不会错位写）。
//    ⇒ 命令之间的空闲必须 > "桥处理一条命令的最坏时长"（约 160 µs），
//      取 500 µs（3 倍余量）。丢了也不会静默：下面的 17 项回读比对会把它
//      标成对应的 bad 位，屏上在该项的格位画红 ✖（spec §6.2 的"只显示回读值"）。
//
//  ★ 与上位机抢线：busy=1 期间层内 uart_rx 被本模块占用（策略层在 UART mux 里
//    把它排在最高优先级），上位机**不能**发命令；docs/15 已写明这一条。
//=============================================================================
`timescale 1ns / 1ps

module ui_restore #(
    parameter integer BAUD_DIV   = 25,        // 50 MHz / 2 Mbaud
    parameter integer GAP_CLK    = 25_000,    // 命令之间的线路空闲（500 µs，见头注释）
    parameter integer SETTLE_CLK = 100_000    // 全序列发完等回读稳定（2 ms）
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- 启动（单拍脉冲；busy=1 时被忽略）----------------
    input  wire        start,

    // ---------------- 回读来源（disp_tap 的 17 个字段，只读）----------------
    input  wire [4:0]  tap_pairs,
    input  wire [9:0]  tap_inter,
    input  wire [2:0]  tap_div,
    input  wire [4:0]  tap_hyst_ab,
    input  wire [7:0]  tap_ablimit,
    input  wire [3:0]  tap_zwidth,
    input  wire [11:0] tap_zphase,
    input  wire [15:0] tap_uvwph,
    input  wire [3:0]  tap_pol,
    input  wire        tap_abzen,
    input  wire        tap_uwven,
    input  wire [3:0]  tap_shift,
    input  wire [15:0] tap_ofs_s,
    input  wire [15:0] tap_ofs_c,
    input  wire [15:0] tap_gain_s,
    input  wire [15:0] tap_gain_c,
    input  wire [15:0] tap_phase_k,

    // ---------------- 占用层内 uart_rx ----------------
    output wire        tx_line,               // 接到 enc_top.uart_rx 的候选源（空闲为 1）
    output wire        busy,                  // 1 = 本模块占用该线
    output reg         done,                  // 序列 + 回读判定结束的单拍脉冲

    // ---------------- 状态给显示层 ----------------
    //   ★ 编码与 disp_engine 的 ui_rst_state 对齐（0 空闲 / 1 全一致 / 2 有不一致 / 3 进行中）
    output reg  [1:0]  state,
    output reg  [14:0] bad                    // 没回读上的 P6 项（位序 = 行*3 + 列）
);

    // ---- 对外状态编码（显示层按这个上色 + 画 ✖）----
    localparam [1:0] RST_IDLE = 2'd0,   // 空闲 / 还没做过
                     RST_OK   = 2'd1,   // 全部回读一致（按钮描边绿）
                     RST_BAD  = 2'd2,   // 有不一致（按钮描边红 + 那一项 ✖）
                     RST_RUN  = 2'd3;   // 序列进行中（按钮描边橙）

    // ---- 序列阶段 ----
    localparam [2:0] S_IDLE   = 3'd0,
                     S_GAP    = 3'd1,   // 命令前/命令后的线路空闲
                     S_LOAD   = 3'd2,   // 装载下一个字节
                     S_WAITB  = 3'd3,   // 等 uart_tx 忙起
                     S_WAITD  = 3'd4,   // 等这一字节发完
                     S_NEXT   = 3'd5,   // 下一条命令 / 全部发完
                     S_SETTLE = 3'd6,   // 等回读稳定
                     S_CHECK  = 3'd7;   // 逐项比对

    localparam [3:0] N_CMD = 4'd13;        // 命令条数

    // ---------------------------------------------------------------
    //  uart_tx（定义在 rtl/uart_scope.v:56；与 disp/ui_edit.v 共用同一个模块）
    // ---------------------------------------------------------------
    reg  [7:0]  utx_data;
    reg         utx_start;
    wire        utx_line;
    wire        utx_busy;

    uart_tx #(.BAUD_DIV (BAUD_DIV)) u_utx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (utx_data),
        .tx_start (utx_start),
        .tx       (utx_line),
        .busy     (utx_busy)
    );

    assign tx_line = utx_line;

    // ---------------------------------------------------------------
    //  命令表：{addr[10:0], data[15:0]}（data 低字节 -> addr、高字节 -> addr+1）
    // ---------------------------------------------------------------
    reg [10:0] cmd_addr;
    reg [15:0] cmd_data;

    //   用函数而不是 ROM：13 条常量在综合里就是一组 mux，比一个分布式 RAM 更省
    //   （和 ui_edit 的 pack_cmd 一样，读起来也能直接对着寄存器表核）。
    task load_cmd;
        input [3:0] i;
        begin
            case (i)
            4'd0:  begin cmd_addr = 11'h100; cmd_data = 16'h0004; end
            4'd1:  begin cmd_addr = 11'h101; cmd_data = 16'h0000; end
            4'd2:  begin cmd_addr = 11'h102; cmd_data = 16'h0000; end
            4'd3:  begin cmd_addr = 11'h106; cmd_data = 16'h0A00; end
            4'd4:  begin cmd_addr = 11'h108; cmd_data = 16'h4000; end
            4'd5:  begin cmd_addr = 11'h10A; cmd_data = 16'h0000; end
            4'd6:  begin cmd_addr = 11'h10C; cmd_data = 16'h0000; end
            4'd7:  begin cmd_addr = 11'h510; cmd_data = 16'h0000; end
            4'd8:  begin cmd_addr = 11'h512; cmd_data = 16'h0000; end
            4'd9:  begin cmd_addr = 11'h514; cmd_data = 16'h8000; end
            4'd10: begin cmd_addr = 11'h516; cmd_data = 16'h8000; end
            4'd11: begin cmd_addr = 11'h518; cmd_data = 16'h0000; end
            default: begin cmd_addr = 11'h51A; cmd_data = 16'h0000; end
            endcase
        end
    endtask

    //   四个字节（MSB 先，与 rtl/uart_spi_bridge.v:16-32 同格式）
    reg [7:0] b0, b1, b2, b3;

    always @(*) begin
        b0 = 8'h80 | 8'h08 | {5'd0, cmd_addr[10:8]};
        b1 = cmd_addr[7:0];
        b2 = cmd_data[15:8];
        b3 = cmd_data[7:0];
    end

    // ---------------------------------------------------------------
    //  序列 FSM
    // ---------------------------------------------------------------
    reg [2:0]  phase;
    reg [3:0]  cmd_idx;
    reg [2:0]  bidx;
    reg [31:0] pcnt;

    //   占用层内 uart_rx 的条件 = 不在空闲阶段（序列一旦启动就一直占着，
    //   直到 SETTLE 结束、S_CHECK 判完才放开）。
    assign busy = (phase != S_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            phase     <= S_IDLE;
            cmd_idx   <= 4'd0;
            bidx      <= 3'd0;
            pcnt      <= 32'd0;
            utx_data  <= 8'd0;
            utx_start <= 1'b0;
            cmd_addr  <= 11'd0;
            cmd_data  <= 16'd0;
            state     <= RST_IDLE;
            bad       <= 15'd0;
            done      <= 1'b0;
        end
        else begin
            utx_start <= 1'b0;               // 默认：单拍脉冲
            done      <= 1'b0;

            case (phase)
            // ---------------- 空闲 ----------------
            S_IDLE: begin
                if (start) begin
                    cmd_idx <= 4'd0;
                    bidx    <= 3'd0;
                    pcnt    <= 32'd0;
                    bad     <= 15'd0;
                    state   <= RST_RUN;
                    load_cmd(4'd0);
                    phase   <= S_GAP;        // 先满足桥的 GAP_MIN 再发第一个字节
                end
            end

            // ---------------- 线路空闲 ----------------
            S_GAP: begin
                if (pcnt >= GAP_CLK) begin
                    pcnt  <= 32'd0;
                    phase <= S_LOAD;
                end
                else pcnt <= pcnt + 32'd1;
            end

            // ---------------- 装载一个字节 ----------------
            //   ★ 两个字都要由本拍写、下一拍才被 uart_tx 采到（与 ui_edit 同一写法）：
            //     utx_data 在本拍更新、utx_start 也在本拍拉高，uart_tx 在下一拍同时
            //     看到新的 data 与 start。
            S_LOAD: begin
                if (!utx_busy) begin
                    case (bidx)
                    3'd0: utx_data <= b0;
                    3'd1: utx_data <= b1;
                    3'd2: utx_data <= b2;
                    default: utx_data <= b3;
                    endcase
                    utx_start <= 1'b1;
                    phase     <= S_WAITB;
                end
            end

            // ---------------- 等 uart_tx 忙起 ----------------
            S_WAITB: begin
                if (utx_busy) phase <= S_WAITD;
            end

            // ---------------- 等这一字节发完 ----------------
            S_WAITD: begin
                if (!utx_busy) begin
                    if (bidx == 3'd3) begin
                        bidx  <= 3'd0;
                        phase <= S_NEXT;         // 四个字节发完 -> 下一条命令
                    end
                    else begin
                        bidx  <= bidx + 3'd1;
                        phase <= S_LOAD;         // 同一命令的下一个字节，紧接着发
                    end
                end
            end

            // ---------------- 下一条命令 / 全部发完 ----------------
            S_NEXT: begin
                if (cmd_idx == N_CMD - 4'd1) begin
                    pcnt  <= 32'd0;
                    phase <= S_SETTLE;           // 全部发完：等桥释放 + 遥测恢复
                end
                else begin
                    cmd_idx <= cmd_idx + 4'd1;
                    load_cmd(cmd_idx + 4'd1);
                    pcnt    <= 32'd0;
                    phase   <= S_GAP;            // 命令之间也要空闲
                end
            end

            // ---------------- 等回读稳定 ----------------
            S_SETTLE: begin
                if (pcnt >= SETTLE_CLK) phase <= S_CHECK;
                else pcnt <= pcnt + 32'd1;
            end

            // ---------------- 逐项比对（**只在这里判成功**）----------------
            S_CHECK: begin
                bad   <= { (tap_phase_k != 16'd0),                       // [14] 相位修正
                          (tap_gain_c  != 16'h8000) | (tap_ofs_c != 16'd0), // [13] 增益C(+偏置C)
                          (tap_gain_s  != 16'h8000) | (tap_ofs_s != 16'd0), // [12] 增益S(+偏置S)
                          (tap_shift   != 4'd0),                         // [11] SHIFT
                          (tap_uwven   != 1'b0),                         // [10] UVW
                          (tap_abzen   != 1'b1),                         // [ 9] ABZ
                          (tap_pol     != 4'd0),                         // [ 8] 极性
                          (tap_uvwph   != 16'd0),                        // [ 7] UVW 相位
                          (tap_zphase  != 12'd0),                        // [ 6] Z 相位
                          (tap_zwidth  != 4'd0),                         // [ 5] Z 脉宽
                          (tap_ablimit != 8'd0),                         // [ 4] 限幅
                          (tap_hyst_ab != 5'd0),                         // [ 3] 迟滞
                          (tap_pairs   != 5'd4),                         // [ 2] 极对数
                          (tap_div     != 3'd0),                         // [ 1] 分频
                          (tap_inter   != 10'd0) };                      // [ 0] 倍频
                state <= (|{ (tap_phase_k != 16'd0),
                             (tap_gain_c  != 16'h8000) | (tap_ofs_c != 16'd0),
                             (tap_gain_s  != 16'h8000) | (tap_ofs_s != 16'd0),
                             (tap_shift   != 4'd0),
                             (tap_uwven   != 1'b0),
                             (tap_abzen   != 1'b1),
                             (tap_pol     != 4'd0),
                             (tap_uvwph   != 16'd0),
                             (tap_zphase  != 12'd0),
                             (tap_zwidth  != 4'd0),
                             (tap_ablimit != 8'd0),
                             (tap_hyst_ab != 5'd0),
                             (tap_pairs   != 5'd4),
                             (tap_div     != 3'd0),
                             (tap_inter   != 10'd0) }) ? RST_BAD : RST_OK;
                done  <= 1'b1;
                phase <= S_IDLE;
            end

            default: phase <= S_IDLE;
            endcase
        end
    end

endmodule
