//=============================================================================
//  ui_edit.v —— 屏上改值的「两阶段提交 + 回读确认」写侧执行器
//-----------------------------------------------------------------------------
//  为什么走 UART，而不是给 reg_file 加一个端口
//    rtl/reg_file.v 只有一个主机写口（SPI 从站）和一个标定写口（calib_ctrl）。
//    屏要写寄存器，最干净的办法**不是**给 enc_top / reg_file 加端口 —— 那会牵动
//    rtl/enc_top.v 的端口表、enc_top.xdc 与 enc_top_disp.xdc 两套约束，还会破坏
//    与编码器 v12 那次签核的横向可比性。
//    本模块改为在 FPGA 内部充当「UART 下面的第二台 PC」：把
//    rtl/uart_spi_bridge.v 认的 4 字节命令直接打到 enc_top.uart_rx 上。
//    ⇒ rtl/ 一行不改、约束一行不改，而且走的是**与上位机完全相同的那条路径**，
//      所以「回读确认」确认的是真链路，不是屏自己的影子寄存器。
//
//  命令格式（4 字节，MSB 先；见 rtl/uart_spi_bridge.v:16-32 与 tools/uart_spi.py:161）
//    b0 = 0x80 | 0x08 | addr[10:8]     （st=1, rm=00, wm=01, page=addr[10:8]）
//    b1 = addr[7:0]
//    b2 = data[15:8]   -> 写到 addr+1
//    b3 = data[7:0]    -> 写到 addr
//    ★ 一条写命令实际写**两个连续寄存器**（低字节->addr，高字节->addr+1），
//      所以 INTER 的两个字节 0x0101(INTER[7:0]) / 0x0102(INTER[9:8],div)
//      一条命令就能一起改完 —— 这是"要么全改、要么不改"的天然保证。
//
//  回读从哪来
//    tap_inter / tap_div 直接来自 rtl/reg_file.v 的输出：
//      assign cfg_inter = {r_inter1[1:0], r_inter0[7:0]};   // 10 位（:559）
//      assign cfg_div   = r_inter1[4:2];                    // = div-1（:560）
//    它们经 enc_top.disp_tap 抽头回到合并顶层 ⇒ 屏看到的**永远是寄存器里真实的值**。
//    ★ docs/13_display_ui_requirements.md:258-269（本项目最重要的交互契约）：
//      「屏幕绝不允许显示『用户想要的理想值』，只能显示寄存器回读确认过的实际值。」
//
//  编码约定（本模块不做语义转换，只搬运 + 核对）
//    inter_enc : 倍频率的寄存器编码。rtl/abz_gen.v:118 写明
//                "inter, // AB 输出周期数/输入周期；0 视为 256；2…256"
//                ⇒ 256 必须编码成 0。
//    div_code  : 分频的寄存器编码。rtl/abz_gen.v:119 写明
//                "div, // 后分频 1…8（寄存器值 = div-1）" ⇒ ÷1 编码成 0。
//
//  失败与回滚
//    SETTLE_CLK 到点后回读对不上，就**用请求时刻抓到的那组旧值再写一遍**（同样一条
//    命令），然后置 state=ST_FAILED、err_code 区分"不一致"与"回滚也失败"。
//    ⇒ 屏上永远只显示两种东西：回读确认过的新值，或回读确认过的旧值。
//
//  时序预算（clk 50 MHz、BAUD_DIV=25、GAP_CLK=4000、SETTLE_CLK=100000）
//    一字节 10 位 = 250 clk = 5 µs；4 字节 20 µs + 两段 GAP 160 µs + SETTLE 2 ms
//    ⇒ 一条事务 ≈ 2.2 ms（人眼无感）。rtl/uart_spi_bridge.v:60-64 自己的估计是
//      一条命令 60~200 µs；SETTLE 取 2 ms 是留足余量，并保证桥已释放 uart_tx、
//      遥测帧已恢复，回读到的不是半路的值。
//
//  ★ 与上位机抢线
//    本模块 tx_busy=1 期间（整条事务）层内 uart_rx 被占用，上位机**不能**发命令。
//    docs/15_display_touch_bringup.md 有说明：控制台上做完屏上操作再发命令即可。
//=============================================================================
`timescale 1ns / 1ps

module ui_edit #(
    parameter integer BAUD_DIV   = 25,        // 50 MHz / 2 Mbaud
    parameter integer GAP_CLK    = 4000,      // 命令前后的线路空闲（80 µs）
    parameter integer SETTLE_CLK = 100_000,   // 写完等回读稳定（2 ms）

    // ---------------- v19：地址与"是否回读校验"参数化 ----------------
    //   同一个事务 FSM 现在服务两种命令，靠参数区分，不复制一份状态机：
    //     ① 0x0101（INTER0，倍频/分频）—— 默认值，VERIFY = 1（回读确认 + 回滚）
    //     ② 0x0405（STAT_LATCH，W1C"写 1 清"）—— CMD_B0 = 8'h8C / CMD_B1 = 8'h05
    //        / VERIFY = 0。为什么必须关掉校验：
    //          · 0x0405 **不在 disp_tap 的 311 位上**（rtl/SPEC_interface_contract.md），
    //            根本没有回读目标；
    //          · 而且 W1C 的语义是"写成功 ⇒ 读回 0"，与目标值 1 永远不等 ⇒
    //            走 P_CHECK 必然判失败，还会触发一次**多余的回滚写**，把
    //            {old_inter, old_div} 重新写进 0x0101/0x0102（清个故障却顺手
    //            改了倍频/分频）。
    //        清成功的**证据**在屏上：tap 的 stat[0] 是锁存故障位，清了以后
    //        状态条 [告警 ▲] 与左端告警条会自己变回正常色（见 disp_engine 的
    //        alert_fault = q_stat[0] | ...）—— 那是比"读回自己刚写的 1"
    //        更可信的确认，因为它读的是**故障状态**而不是写入值。
    parameter [7:0]   CMD_B0     = 8'h80 | 8'h08 | 8'h01,   // = 8'h89 写命令
    parameter [7:0]   CMD_B1     = 8'h01,                   // addr[7:0]
    parameter integer VERIFY     = 1
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- 请求（单拍脉冲）----------------
    input  wire        req,
    input  wire [9:0]  inter_enc,        // 目标倍频编码（0 表示 256）
    input  wire [2:0]  div_code,         // 目标分频编码（寄存器值 = div-1）

    // ---------------- 回读（来自 disp_tap）----------------
    input  wire [9:0]  tap_inter,
    input  wire [2:0]  tap_div,

    // ---------------- 占用层内 uart_rx ----------------
    output wire        tx_line,          // 接到 enc_top.uart_rx 的候选源（空闲为 1）
    output reg         tx_busy,          // 1 = 本模块占用该线

    // ---------------- 状态给显示层 ----------------
    output reg  [1:0]  state,            // ST_IDLE / ST_BUSY / ST_OK / ST_FAILED
    output reg         done,             // 事务结束的单拍脉冲（成功或失败）
    output reg  [9:0]  ok_inter,         // 最近一次"回读确认过"的值
    output reg  [2:0]  ok_div,
    output reg  [3:0]  err_code,         // 0 = 无错；非 0 见下方 ERR_*
    output reg  [15:0] txn_cnt,          // 事务次数（诊断）
    output reg  [15:0] fail_cnt
);

    // ---- 对外状态编码（显示层按这个上色）----
    localparam [1:0] ST_IDLE   = 2'd0,   // 空闲（还没做过）
                     ST_BUSY   = 2'd1,   // 应用中…（黄）
                     ST_OK     = 2'd2,   // 已应用（绿，ok_* 有效）
                     ST_FAILED = 2'd3;   // 不一致且已回滚（红）

    // ---- 错误码 ----
    localparam [3:0] ERR_NONE     = 4'd0,
                     ERR_MISMATCH = 4'd1,   // 回读 != 目标（已回滚）
                     ERR_RB_FAIL  = 4'd2;   // 回滚后回读 != 旧值

    // ---- 事务阶段 ----
    localparam [3:0] P_IDLE   = 4'd0,
                     P_GAP    = 4'd1,   // 线路空闲
                     P_LOAD   = 4'd2,   // 装载下一字节
                     P_WAITB  = 4'd3,   // 等 uart_tx 忙起
                     P_WAITD  = 4'd4,   // 等这一字节发完
                     P_SETTLE = 4'd5,   // 等回读稳定
                     P_CHECK  = 4'd6;   // 比对

    // ---------------------------------------------------------------
    //  uart_tx（定义在 rtl/uart_scope.v:56；本设计共用，不重复实现）
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
    //  命令字节（默认 addr = 0x0101 = INTER0，一条命令同时写 0x0102）
    //  v19 起这两个字节的值由参数给出（见模块头），好让 W1C 命令复用本 FSM。
    // ---------------------------------------------------------------
    reg [7:0]  b0, b1, b2, b3;
    reg [2:0]  bidx;
    reg        sent;            // 0 = 命令还没发完；1 = 4 字节已发完
    reg        rolling;         // 1 = 本次发送是回滚（发旧值）
    reg [9:0]  want_inter;
    reg [2:0]  want_div;
    reg [9:0]  old_inter;
    reg [2:0]  old_div;

    reg [3:0]  phase;
    reg [31:0] pcnt;

    // 打包一条写命令：b1 = 起始地址、b3 = 该地址的数据、b2 = 地址 +1 的数据
    //   · 默认实例（0x0101/0x0102）：b3 = 倍频低 8 位，b2 = {倍频高 2 位, 分频码}
    //   · W1C 实例（0x0405/0x0406）：调用方传 inter_enc = 1、div_code = 0，
    //     于是 b3 = 0x01（写 1 到 0x0405 清锁存）、b2 = 0x00（0x0406 是只读
    //     的 STAT_FATAL，恒 0，写 0 无副作用 —— rtl/reg_file.v:84/:475）。
    task pack_cmd;
        input [9:0] i_enc;
        input [2:0] d_code;
        begin
            b0 = CMD_B0;
            b1 = CMD_B1;
            b2 = {3'b000, d_code, i_enc[9:8]};      // -> 0x0102
            b3 = i_enc[7:0];                        // -> 0x0101
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            phase      <= P_IDLE;
            pcnt       <= 32'd0;
            bidx       <= 3'd0;
            sent       <= 1'b0;
            rolling    <= 1'b0;
            utx_data   <= 8'd0;
            utx_start  <= 1'b0;
            tx_busy    <= 1'b0;
            state      <= ST_IDLE;
            done       <= 1'b0;
            ok_inter   <= 10'd0;
            ok_div     <= 3'd0;
            err_code   <= ERR_NONE;
            txn_cnt    <= 16'd0;
            fail_cnt   <= 16'd0;
            want_inter <= 10'd0;
            want_div   <= 3'd0;
            old_inter  <= 10'd0;
            old_div    <= 3'd0;
            b0 <= 8'd0;  b1 <= 8'd0;  b2 <= 8'd0;  b3 <= 8'd0;
        end
        else begin
            utx_start <= 1'b0;                      // 默认：单拍脉冲
            done      <= 1'b0;

            case (phase)
            // ---------------- 空闲 ----------------
            P_IDLE: begin
                tx_busy <= 1'b0;
                if (req) begin
                    // ★ 请求时刻先把"当下真实寄存器值"抓下来 —— 回滚就回滚到这组值
                    old_inter  <= tap_inter;
                    old_div    <= tap_div;
                    want_inter <= inter_enc;
                    want_div   <= div_code;
                    pack_cmd(inter_enc, div_code);
                    rolling    <= 1'b0;
                    sent       <= 1'b0;
                    bidx       <= 3'd0;
                    txn_cnt    <= txn_cnt + 16'd1;
                    state      <= ST_BUSY;
                    err_code   <= ERR_NONE;
                    tx_busy    <= 1'b1;
                    pcnt       <= 32'd0;
                    phase      <= P_GAP;            // 先满足桥的 GAP_MIN
                end
            end

            // ---------------- 线路空闲 ----------------
            P_GAP: begin
                if (pcnt >= GAP_CLK) begin
                    pcnt  <= 32'd0;
                    phase <= sent ? P_SETTLE : P_LOAD;
                end
                else pcnt <= pcnt + 32'd1;
            end

            // ---------------- 装载一个字节 ----------------
            P_LOAD: begin
                if (!utx_busy) begin
                    case (bidx)
                    3'd0: utx_data <= b0;
                    3'd1: utx_data <= b1;
                    3'd2: utx_data <= b2;
                    default: utx_data <= b3;
                    endcase
                    utx_start <= 1'b1;
                    phase     <= P_WAITB;
                end
            end

            // ---------------- 等 uart_tx 忙起 ----------------
            P_WAITB: begin
                if (utx_busy) phase <= P_WAITD;
            end

            // ---------------- 等这一字节发完 ----------------
            P_WAITD: begin
                if (!utx_busy) begin
                    if (bidx == 3'd3) begin
                        bidx  <= 3'd0;
                        sent  <= 1'b1;
                        pcnt  <= 32'd0;
                        phase <= P_GAP;             // 命令后也要空闲
                    end
                    else begin
                        bidx  <= bidx + 3'd1;
                        phase <= P_LOAD;
                    end
                end
            end

            // ---------------- 等回读稳定 ----------------
            P_SETTLE: begin
                if (pcnt >= SETTLE_CLK) begin
                    pcnt  <= 32'd0;
                    phase <= P_CHECK;
                end
                else pcnt <= pcnt + 32'd1;
            end

            // ---------------- 比对 ----------------
            P_CHECK: begin
                // v19：VERIFY = 0 的实例（W1C 清锁存）只等命令发完就报成功 ——
                // 理由见模块头参数区的三行注释（没有回读目标 + W1C 语义与相等
                // 比较天生不符 + 走原路会触发多余的回滚写）。
                if (VERIFY == 0) begin
                    ok_inter <= tap_inter;
                    ok_div   <= tap_div;
                    state    <= ST_OK;
                    done     <= 1'b1;
                    phase    <= P_IDLE;
                end
                else if (!rolling) begin
                    if ((tap_inter == want_inter) && (tap_div == want_div)) begin
                        // 回读确认成功：ok_* 就是寄存器里真实的值
                        ok_inter <= tap_inter;
                        ok_div   <= tap_div;
                        state    <= ST_OK;
                        done     <= 1'b1;
                        phase    <= P_IDLE;
                    end
                    else begin
                        // 不一致 -> 自动回滚：把请求时刻的旧值再写一遍
                        pack_cmd(old_inter, old_div);
                        rolling  <= 1'b1;
                        sent     <= 1'b0;
                        bidx     <= 3'd0;
                        pcnt     <= 32'd0;
                        err_code <= ERR_MISMATCH;
                        fail_cnt <= fail_cnt + 16'd1;
                        phase    <= P_GAP;
                    end
                end
                else begin
                    // 回滚之后：旧值回来了才算"干净地失败"
                    ok_inter <= tap_inter;
                    ok_div   <= tap_div;
                    if ((tap_inter != old_inter) || (tap_div != old_div))
                        err_code <= ERR_RB_FAIL;
                    state   <= ST_FAILED;
                    done    <= 1'b1;
                    rolling <= 1'b0;
                    phase   <= P_IDLE;
                end
            end

            default: phase <= P_IDLE;
            endcase
        end
    end

endmodule
