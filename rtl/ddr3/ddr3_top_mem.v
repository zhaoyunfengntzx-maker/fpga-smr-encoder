//=============================================================================
//  ddr3_top_mem.v —— DDR3 深存储上板验证（1 M 点写入 → 回读 → 逐点比对）
//
//  和 ddr3_top.v 的区别：ddr3_top 只测 MIG 的最小闭环（1024 个 128 bit 字），
//  这个顶层把真正要用的引擎 rtl/ddr3/ddr3_ring.v 接进来，按生产用法跑：
//    ① 50 MHz 域连续灌 1,048,576 个样点（每个样点 32 bit 递增图样）
//    ② 走异步 FIFO → ui_clk 域 → MIG 128 bit 写
//    ③ 再从 base=0 回读同样 1,048,576 点，下游每拍取一个、逐个比对
//    ④ 结果用 LED 报，命令串口/网口协议都不用改
//
//  为什么容量选 1 M 点：ds18 里规划的深存储是 256 MB，但上板验证先要一个
//  "跑得完、等得起"的规模。1 M 点 = 4 MB = 262144 个 128 bit 字，
//  已经把环形指针回绕（RING_AW=18）、跨 FIFO 时钟域、长突发这三件事全覆盖。
//
//  LED（全部在 50 MHz 域，MIG 没起来也能看见心跳）：
//    led[0] 1 Hz 心跳
//    led[1] 常亮 = 校准完成且 1 M 点全部比对通过
//           2 Hz 闪 = 有错
//           不亮   = 还在跑（或没校准）
//=============================================================================
`timescale 1ns / 1ps

module ddr3_top_mem (
    input  wire        sys_clk,        // V4, 50 MHz
    output reg  [1:0]  led,
    output wire        uart_tx,        // W21, 115200 8N1，打印比对结果

    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_cas_n,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [1:0]  ddr3_dm,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_n,
    inout  wire [1:0]  ddr3_dqs_p,
    output wire [0:0]  ddr3_odt,
    output wire        ddr3_ras_n,
    output wire        ddr3_reset_n,
    output wire        ddr3_we_n
);

    //-------------------------------------------------------------------------
    // 分级自检：小 → 中 → 大。任何一级出错就停在该级并报错，
    // 这样一次上板就能回答"多大规模开始坏"，而不是只有一个 1 M 点的黑盒结果。
    //   round 0: 16384 点 (4096 字)
    //   round 1: 262144 点 (65536 字)
    //   round 2: 1048576 点 (262144 字) —— RING_AW=18 正好一圈
    // 三级都从地址 0 开始回读；写是追加的，前面几级写过的内容不会被破坏
    // （pattern 只跟绝对序号有关），所以不需要复位环形指针。
    //-------------------------------------------------------------------------
    localparam integer RING_AW  = 18;
    localparam [31:0]  NSAMP    = 32'd1048576;
    localparam [31:0]  N0       = 32'd16384;
    localparam [31:0]  N1       = 32'd262144;
    localparam [31:0]  N2       = 32'd1048576;

    // 当前这一级要跑多少点（分级自检）
    reg  [1:0]  round;
    wire [31:0] cur_n = (round == 2'd0) ? N0 : (round == 2'd1) ? N1 : N2;

    //-------------------------------------------------------------------------
    // 时钟：50 MHz → 200 MHz（MIG sys_clk_i）
    //-------------------------------------------------------------------------
    wire clk200, clkfb, clk200_raw, mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (20.000),
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (20.000),
        .CLKOUT0_DIVIDE_F   (5.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKIN1   (sys_clk),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk200_raw),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_bufg_200 (.I(clk200_raw), .O(clk200));

    //-------------------------------------------------------------------------
    // 复位：200 MHz 域上电计数，高有效
    //
    // ★ 计数长度取 20 bit（≈5.2 ms）而不是 16 bit（164 µs）：MIG 内部的
    //   PLL 锁定、DDR3 的 tINIT（上电 200 µs + 500 µs 初始化）都要时间，
    //   复位太短时上电时序会靠运气（同一份位流有时校准、有时不校准）。
    //-------------------------------------------------------------------------
    reg [19:0] por_cnt = 20'd0;
    reg        sys_rst_r = 1'b1;
    always @(posedge clk200) begin
        if (!mmcm_locked) begin
            por_cnt   <= 20'd0;
            sys_rst_r <= 1'b1;
        end else if (!por_cnt[19]) begin
            por_cnt   <= por_cnt + 20'd1;
            sys_rst_r <= 1'b1;
        end else begin
            sys_rst_r <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // MIG
    //-------------------------------------------------------------------------
    wire [27:0]  app_addr;
    wire [2:0]   app_cmd;
    wire         app_en;
    wire [127:0] app_wdf_data;
    wire         app_wdf_end;
    wire         app_wdf_wren;
    wire [15:0]  app_wdf_mask;
    wire [127:0] app_rd_data;
    wire         app_rd_data_end;
    wire         app_rd_data_valid;
    wire         app_rdy;
    wire         app_wdf_rdy;
    wire         ui_clk, ui_clk_sync_rst, init_calib_complete;

    mig_7series_0 u_mig (
        .ddr3_addr           (ddr3_addr),
        .ddr3_ba             (ddr3_ba),
        .ddr3_cas_n          (ddr3_cas_n),
        .ddr3_ck_n           (ddr3_ck_n),
        .ddr3_ck_p           (ddr3_ck_p),
        .ddr3_cke            (ddr3_cke),
        .ddr3_ras_n          (ddr3_ras_n),
        .ddr3_reset_n        (ddr3_reset_n),
        .ddr3_we_n           (ddr3_we_n),
        .ddr3_dq             (ddr3_dq),
        .ddr3_dqs_n          (ddr3_dqs_n),
        .ddr3_dqs_p          (ddr3_dqs_p),
        .init_calib_complete (init_calib_complete),
        .ddr3_cs_n           (ddr3_cs_n),
        .ddr3_dm             (ddr3_dm),
        .ddr3_odt            (ddr3_odt),
        .app_addr            (app_addr),
        .app_cmd             (app_cmd),
        .app_en              (app_en),
        .app_wdf_data        (app_wdf_data),
        .app_wdf_end         (app_wdf_end),
        .app_wdf_wren        (app_wdf_wren),
        .app_rd_data         (app_rd_data),
        .app_rd_data_end     (app_rd_data_end),
        .app_rd_data_valid   (app_rd_data_valid),
        .app_rdy             (app_rdy),
        .app_wdf_rdy         (app_wdf_rdy),
        .app_sr_req          (1'b0),
        .app_ref_req         (1'b0),
        .app_zq_req          (1'b0),
        .app_sr_active       (),
        .app_ref_ack         (),
        .app_zq_ack          (),
        .ui_clk              (ui_clk),
        .ui_clk_sync_rst     (ui_clk_sync_rst),
        .app_wdf_mask        (app_wdf_mask),
        .sys_clk_i           (clk200),
        // ★ MIG 的 sys_rst 是**低有效**：生成的 mig_7series_0_mig.v 里
        //   parameter RST_ACT_LOW = 1，内部是 sys_rst_act_hi = ~sys_rst。
        //   之前直接接 sys_rst_r（高有效），等于上电 164 µs 之后把 MIG
        //   永久按在复位里 —— 表现就是 MMCM 锁、por_cnt 跑、但 ui_clk 不动、
        //   校准永远不开始、led[1] 全灭。这里取反修正。
        .sys_rst             (~sys_rst_r)
    );

    //-------------------------------------------------------------------------
    // 图样：样点 i 的期望值。用 XOR 而不是加法，相邻点差异大，
    // 一旦错位一个字就立刻在低位看出差别。
    //-------------------------------------------------------------------------
    function [31:0] pat(input [31:0] i);
        begin
            pat = i ^ 32'h5A5A0000;
        end
    endfunction

    //-------------------------------------------------------------------------
    // 写侧：50 MHz 域按 wr_ready 节奏灌点（ring 内部 FIFO 会反压）
    //
    // ★ 必须用"组合 valid + 只有握手成功才前进"的写法。如果像测试台那样
    //   先看 wr_ready 再打一拍 wr_valid，wr_ready 掉下来的那一拍，
    //   已经递增过的样点就丢了（1 M 点会灌不满，而且图样整体错位）。
    //-------------------------------------------------------------------------
    reg  [31:0] wr_idx;
    wire        wr_ready;
    wire [31:0] wr_samples;
    wire        wr_wrapped;

    // 50 MHz 域自己的上电复位（1024 拍 ≈ 20 µs）。不借用 clk200 域的 sys_rst_r：
    // 那样 Vivado 会按 clk200_raw→sys_clk 的跨域复位路径做 setup 分析，
    // 实测 WNS -0.002 ns、4 个端点失败（都是这条复位路径）。
    reg  [9:0] wrst_cnt = 10'd0;
    wire       wr_rst   = ~wrst_cnt[9];
    always @(posedge sys_clk)
        if (!wrst_cnt[9]) wrst_cnt <= wrst_cnt + 10'd1;

    wire [31:0] wr_data  = pat(wr_idx);
    wire        wr_valid = (wr_idx < cur_n);

    always @(posedge sys_clk) begin
        if (wr_rst)                   wr_idx <= 32'd0;
        else if (wr_valid && wr_ready) wr_idx <= wr_idx + 32'd1;
    end

    // 读侧
    reg         rd_start;
    reg  [31:0] rd_base, rd_len;
    wire [31:0] rd_data;
    wire        rd_valid, rd_done, rd_busy;

    wire [31:0] dbg_need, dbg_pend, dbg_wleft;
    wire [27:0] dbg_addr;

    //-------------------------------------------------------------------------
    // 测试状态机（ui_clk 域）
    //-------------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0,
                     S_WR   = 3'd1,
                     S_FLSH = 3'd2,   // 等写侧全部落盘
                     S_RQ   = 3'd3,   // 拉 rd_start 直到引擎真的接住（写引擎可能还在排空）
                     S_RD   = 3'd4,
                     S_DONE = 3'd5;

    reg [2:0]  st;
    reg [31:0] got_cnt;
    reg [31:0] err_cnt;
    reg [31:0] flush_cnt;
    reg [31:0] rq_cnt;
    reg        pass_r;


    // 首个错点：位置、期望值、实际值（只记第一次，方便从串口看根因）
    reg        fe_seen;
    reg [31:0] fe_idx, fe_exp, fe_got;

    wire wr_done = (wr_samples >= cur_n);

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            st        <= S_IDLE;
            round     <= 2'd0;
            rd_start  <= 1'b0;
            rd_base   <= 32'd0;
            rd_len    <= 32'd0;
            got_cnt   <= 32'd0;
            err_cnt   <= 32'd0;
            flush_cnt <= 32'd0;
            rq_cnt    <= 32'd0;
            pass_r    <= 1'b0;
            fe_seen   <= 1'b0;
            fe_idx    <= 32'd0;
            fe_exp    <= 32'd0;
            fe_got    <= 32'd0;
        end else begin
            case (st)
            S_IDLE: begin
                if (init_calib_complete)
                    st <= S_WR;
            end

            S_WR: begin
                if (wr_done)
                    st <= S_FLSH;
            end

            S_FLSH: begin
                // ★ MIG 的 UI 不保证"读能看见刚发出的写"：写命令只是被塞进
                //   MIG 内部的写缓冲，真正的 burst 还在往后排。1 M 点 = 262144 个
                //   128 bit 突发，@400 MHz 按 tCCD=4 拍算要 ~1.3 ms 才排空，
                //   原来的 5000 拍（50 µs）远远不够 —— 直接测试版里
                //   A=0/A=1 读回 0000FFFF/1111BBBB（旧内容）、A=2 以后才正确，
                //   就是这个"读抢在写落盘之前"的现场。
                //   这里放到 400000 拍（100 MHz ui_clk 下 4 ms），足以排空全部突发。
                if (flush_cnt == 32'd400000) begin
                    rd_base <= 32'd0;
                    rd_len  <= cur_n;
                    st      <= S_RQ;
                end else begin
                    flush_cnt <= flush_cnt + 32'd1;
                end
            end

            S_RQ: begin
                // rd_start 是电平：引擎在 eng_active 为 0 时才接。写引擎可能还在
                // 排最后几条命令，所以这里保持高，直到 rd_busy 起来再撤。
                rd_start <= 1'b1;
                if (rd_busy) begin
                    rd_start <= 1'b0;
                    st       <= S_RD;
                end else if (rq_cnt == 32'd2000000) begin
                    // 2 千万 ns 还没启动回读：判失败，别让 LED 一直不亮无法区分
                    rd_start <= 1'b0;
                    err_cnt  <= 32'd1;
                    st       <= S_DONE;
                end else begin
                    rq_cnt <= rq_cnt + 32'd1;
                end
            end

            S_RD: begin
                rd_start <= 1'b0;
                if (rd_valid) begin
                    if (rd_data !== pat(got_cnt)) begin
                        err_cnt <= err_cnt + 32'd1;
                        if (!fe_seen) begin
                            fe_seen <= 1'b1;
                            fe_idx  <= got_cnt;
                            fe_exp  <= pat(got_cnt);
                            fe_got  <= rd_data;
                        end
                    end
                    got_cnt <= got_cnt + 32'd1;
                end
                if (rd_done) begin
                    // 这一级有错就停在这里（ERR/GOT/IDX/EXP/GTD 就是这一级的数据）；
                    // 没错就升级到更大的规模继续。
                    if (err_cnt != 32'd0) begin
                        st <= S_DONE;
                    end else if (round != 2'd2) begin
                        round    <= round + 2'd1;
                        got_cnt  <= 32'd0;
                        err_cnt  <= 32'd0;
                        fe_seen  <= 1'b0;
                        flush_cnt<= 32'd0;
                        st       <= S_WR;
                    end else begin
                        st <= S_DONE;
                    end
                end
            end

            S_DONE: begin
                pass_r <= (err_cnt == 32'd0) && (got_cnt == cur_n);
            end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // ddr3_ring
    //-------------------------------------------------------------------------
    ddr3_ring #(
        .RING_AW (RING_AW),
        .FIFO_AW (8),
        .MAX_OUT (1),
        .OQ_AW   (4)
    ) u_ring (
        .wr_clk      (sys_clk),
        .wr_rst_n    (~wr_rst),
        .wr_valid    (wr_valid),
        .wr_data     (wr_data),
        .wr_ready    (wr_ready),
        .wr_samples  (wr_samples),
        .wr_wrapped  (wr_wrapped),

        .ui_clk      (ui_clk),
        .ui_rst      (ui_clk_sync_rst),
        .rd_start    (rd_start),
        .rd_base     (rd_base),
        .rd_len      (rd_len),
        .rd_data     (rd_data),
        .rd_valid    (rd_valid),
        .rd_done     (rd_done),
        .rd_busy     (rd_busy),

        .app_addr       (app_addr),
        .app_cmd        (app_cmd),
        .app_en         (app_en),
        .app_wdf_data   (app_wdf_data),
        .app_wdf_end    (app_wdf_end),
        .app_wdf_wren   (app_wdf_wren),
        .app_wdf_mask   (app_wdf_mask),
        .app_rdy        (app_rdy),
        .app_wdf_rdy    (app_wdf_rdy),
        .app_rd_data    (app_rd_data),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rd_data_end(app_rd_data_end),

        .dbg_need       (dbg_need),
        .dbg_pend       (dbg_pend),
        .dbg_wleft      (dbg_wleft),
        .dbg_addr       (dbg_addr)
    );

    //-------------------------------------------------------------------------
    // 结果同步到 50 MHz 域 + LED
    //-------------------------------------------------------------------------
    reg test_done_r = 1'b0;
    reg test_fail_r = 1'b0;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            test_done_r <= 1'b0;
            test_fail_r <= 1'b0;
        end else if (st == S_DONE) begin
            test_done_r <= 1'b1;
            test_fail_r <= (err_cnt != 32'd0) || (got_cnt != cur_n);
        end
    end

    reg [1:0] done_s, fail_s, calib_s;
    always @(posedge sys_clk) begin
        done_s  <= {done_s[0],  test_done_r};
        fail_s  <= {fail_s[0],  test_fail_r};
        calib_s <= {calib_s[0], init_calib_complete};
    end

    // 一个 27 bit 自由计数器，取不同的位当不同频率（50 MHz 下）：
    //   bit22：翻转 84 ms → 约 6 Hz
    //   bit24：翻转 335 ms → 约 1.5 Hz
    //   bit25：翻转 671 ms → 约 0.75 Hz
    //   bit26：翻转 1.34 s → 约 0.37 Hz（很慢，一眼能数）
    reg [26:0] div_cnt;
    always @(posedge sys_clk) div_cnt <= div_cnt + 27'd1;

    //-------------------------------------------------------------------------
    // ui_clk 活着的证据：MIG 内部 PLL 锁定后 ui_clk 才会跑。
    // 在 ui_clk 域做个慢翻转，再同步到 50 MHz 域：它会闪 ⇔ ui_clk 在跑。
    //-------------------------------------------------------------------------
    reg [24:0] ui_div;
    always @(posedge ui_clk) ui_div <= ui_div + 25'd1;   // 100 MHz / 2^24 ≈ 0.17 s 翻转

    reg [1:0] ui_alive_s;
    always @(posedge sys_clk) ui_alive_s <= {ui_alive_s[0], ui_div[24]};

    // MMCM 锁定 与 sys_rst 释放，都同步到 sys_clk 域看
    reg [2:0] lock_s;
    reg [2:0] sysrst_s;
    always @(posedge sys_clk) begin
        lock_s   <= {lock_s[1:0],   mmcm_locked};
        sysrst_s <= {sysrst_s[1:0], sys_rst_r};
    end

    //-------------------------------------------------------------------------
    // LED 编码（2 个灯区分 6 种状态，全部由 `led[1]` 的频率表达）
    //   led[0] 约 0.75 Hz 慢闪 = 心跳（50 MHz + 位流在跑）
    //   led[1] 约 6 Hz 闪      = MMCM 没锁      → 50→200 MHz 这段就断了
    //   led[1] 约 3 Hz 闪      = MMCM 锁了但 sys_rst 一直高（正常只 0.33 ms）
    //   led[1] 约 1.5 Hz 闪    = 复位已放、ui_clk 在跑，但没校准 → 卡在训练
    //   led[1] 全灭            = 复位已放、但 ui_clk 没跑 → MIG 内部 PLL 没锁
    //   led[1] 常亮            = 全部通过
    //   led[1] 约 0.37 Hz 极慢 = 测试跑完但有错 / 超时
    //-------------------------------------------------------------------------
    reg [1:0] led_r;
    always @(posedge sys_clk) begin
        led_r[0] <= div_cnt[25];                              // 心跳
        if (!lock_s[2])        led_r[1] <= div_cnt[22];       // 6 Hz：MMCM 没锁
        else if (sysrst_s[2])  led_r[1] <= div_cnt[23];       // 3 Hz：sys_rst 卡高
        else if (!calib_s[1])  led_r[1] <= ui_alive_s[1];     // ui 活=1.5 Hz，死=灭
        else if (!done_s[1])   led_r[1] <= div_cnt[24];       // 1.5 Hz：在跑
        else if (fail_s[1])    led_r[1] <= div_cnt[26];       // 0.37 Hz：有错
        else                   led_r[1] <= 1'b1;              // 常亮：通过
    end

    always @(*) led = led_r;

    //-------------------------------------------------------------------------
    // 串口调试输出（115200 8N1，W21）
    //-------------------------------------------------------------------------

    // 观测值：ui_clk 域 → sys_clk 域，两级打拍（调试用，允许撕裂）
    reg [31:0] got_s1, got_s2, err_s1, err_s2;
    reg [31:0] need_s1, need_s2, pend_s1, pend_s2, wl_s1, wl_s2, ad_s1, ad_s2;
    reg [2:0]  st_s1, st_s2;
    always @(posedge sys_clk) begin
        got_s1  <= got_cnt;   got_s2  <= got_s1;
        err_s1  <= err_cnt;   err_s2  <= err_s1;
        need_s1 <= dbg_need;  need_s2 <= need_s1;
        pend_s1 <= dbg_pend;  pend_s2 <= pend_s1;
        wl_s1   <= dbg_wleft; wl_s2   <= wl_s1;
        ad_s1   <= {4'd0, dbg_addr}; ad_s2 <= ad_s1;
        st_s1   <= st;        st_s2   <= st_s1;
    end

    // 每 500 ms 无条件打一行状态，卡在任何一步都能看出来：
    //   ST  : 0 等校准 / 1 写 / 2 冲刷 / 3 等回读启动 / 4 回读中 / 5 完成
    //   GOT : 已回读点数        ERR : 错点数
    //   NEED: 还要吐的样点数    PEND: 在飞读命令数   WL: 还没发出的读命令数
    //   AD  : 当前读地址
    //   IDX : 第一个错点的样点号        EXP : 该点期望值     GTD : 实际读到的值
    //   W0..W3 : 回读到的第一个 128 位字的 4 个样点（看有没有我们的图样）
    //   WC/WD/RC/RV : 写命令 / 写数据 / 读命令 / 读数据 的握手次数
    localparam integer MSG_LEN = 262;
    localparam [24:0]  PERIOD  = 25'd24_999_999;   // 50 MHz × 0.5 s

    // ui_clk 域的观测寄存器（跑完就静止）→ 统一 2FF 同步到 sys_clk 域
    reg [31:0] cnt_wc, cnt_wd, cnt_rc, cnt_rv;
    reg [31:0] w0, w1, w2, w3;
    reg [31:0] w4, w5, w6, w7;
    reg [31:0] t0, t1, t2, t3;     // 第一个真正送进 MIG 的写数据字

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            cnt_wc <= 32'd0; cnt_wd <= 32'd0; cnt_rc <= 32'd0; cnt_rv <= 32'd0;
            w0 <= 32'd0; w1 <= 32'd0; w2 <= 32'd0; w3 <= 32'd0;
            w4 <= 32'd0; w5 <= 32'd0; w6 <= 32'd0; w7 <= 32'd0;
            t0 <= 32'd0; t1 <= 32'd0; t2 <= 32'd0; t3 <= 32'd0;
        end else begin
            if (app_en && app_rdy && app_cmd == 3'd0) cnt_wc <= cnt_wc + 32'd1;
            if (app_wdf_wren && app_wdf_rdy) begin
                if (cnt_wd == 32'd0) begin
                    t0 <= app_wdf_data[ 31:  0];
                    t1 <= app_wdf_data[ 63: 32];
                    t2 <= app_wdf_data[ 95: 64];
                    t3 <= app_wdf_data[127: 96];
                end
                cnt_wd <= cnt_wd + 32'd1;
            end
            if (app_en && app_rdy && app_cmd == 3'd1) cnt_rc <= cnt_rc + 32'd1;
            if (app_rd_data_valid)                    cnt_rv <= cnt_rv + 32'd1;
            if (rd_valid) begin
                if (got_cnt == 32'd0) w0 <= rd_data;
                if (got_cnt == 32'd1) w1 <= rd_data;
                if (got_cnt == 32'd2) w2 <= rd_data;
                if (got_cnt == 32'd3) w3 <= rd_data;
                if (got_cnt == 32'd4) w4 <= rd_data;
                if (got_cnt == 32'd5) w5 <= rd_data;
                if (got_cnt == 32'd6) w6 <= rd_data;
                if (got_cnt == 32'd7) w7 <= rd_data;
            end
        end
    end

    wire [31:0] dsrc [0:20];
    assign dsrc[ 0] = got_cnt;
    assign dsrc[ 1] = err_cnt;
    assign dsrc[ 2] = fe_idx;
    assign dsrc[ 3] = fe_exp;
    assign dsrc[ 4] = fe_got;
    assign dsrc[ 5] = w0;
    assign dsrc[ 6] = w1;
    assign dsrc[ 7] = w2;
    assign dsrc[ 8] = w3;
    assign dsrc[ 9] = cnt_wc;
    assign dsrc[10] = cnt_wd;
    assign dsrc[11] = cnt_rc;
    assign dsrc[12] = cnt_rv;
    assign dsrc[13] = t0;
    assign dsrc[14] = t1;
    assign dsrc[15] = t2;
    assign dsrc[16] = t3;
    assign dsrc[17] = w4;
    assign dsrc[18] = w5;
    assign dsrc[19] = w6;
    assign dsrc[20] = w7;

    reg [31:0] ds1 [0:20];
    reg [31:0] ds2 [0:20];
    integer di;
    always @(posedge sys_clk) begin
        for (di = 0; di < 21; di = di + 1) begin
            ds1[di] <= dsrc[di];
            ds2[di] <= ds1[di];
        end
    end

    reg [7:0] msg [0:MSG_LEN-1];

    task put_hex;
        input integer pos;
        input [31:0]  v;
        integer       k;
        reg   [3:0]   nib;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                nib = v[31 - 4*k -: 4];
                msg[pos+k] <= {4'h3, nib} + ((nib < 4'd10) ? 8'd0 : 8'd7);
            end
        end
    endtask

    task fill_msg;
        begin
            msg[ 0] <= "S"; msg[ 1] <= "T"; msg[ 2] <= "=";
            msg[ 3] <= {4'h3, {1'b0, st_s2}};
            msg[ 4] <= " ";
            msg[ 5] <= "G"; msg[ 6] <= "O"; msg[ 7] <= "T"; msg[ 8] <= "=";
            msg[17] <= " ";
            msg[18] <= "E"; msg[19] <= "R"; msg[20] <= "R"; msg[21] <= "=";
            msg[30] <= " ";
            msg[31] <= "I"; msg[32] <= "D"; msg[33] <= "X"; msg[34] <= "=";
            msg[43] <= " ";
            msg[44] <= "E"; msg[45] <= "X"; msg[46] <= "P"; msg[47] <= "=";
            msg[56] <= " ";
            msg[57] <= "G"; msg[58] <= "T"; msg[59] <= "D"; msg[60] <= "=";
            msg[69] <= " ";
            msg[70] <= "W"; msg[71] <= "0"; msg[72] <= "=";
            msg[81] <= " ";
            msg[82] <= "W"; msg[83] <= "1"; msg[84] <= "=";
            msg[93] <= " ";
            msg[94] <= "W"; msg[95] <= "2"; msg[96] <= "=";
            msg[105] <= " ";
            msg[106] <= "W"; msg[107] <= "3"; msg[108] <= "=";
            msg[117] <= " ";
            msg[118] <= "W"; msg[119] <= "C"; msg[120] <= "=";
            msg[129] <= " ";
            msg[130] <= "W"; msg[131] <= "D"; msg[132] <= "=";
            msg[141] <= " ";
            msg[142] <= "R"; msg[143] <= "C"; msg[144] <= "=";
            msg[153] <= " ";
            msg[154] <= "R"; msg[155] <= "V"; msg[156] <= "=";
            msg[165] <= " ";
            msg[166] <= "T"; msg[167] <= "0"; msg[168] <= "=";
            msg[177] <= " ";
            msg[178] <= "T"; msg[179] <= "1"; msg[180] <= "=";
            msg[189] <= " ";
            msg[190] <= "T"; msg[191] <= "2"; msg[192] <= "=";
            msg[201] <= " ";
            msg[202] <= "T"; msg[203] <= "3"; msg[204] <= "=";
            msg[213] <= " ";
            msg[214] <= "W"; msg[215] <= "4"; msg[216] <= "=";
            msg[225] <= " ";
            msg[226] <= "W"; msg[227] <= "5"; msg[228] <= "=";
            msg[237] <= " ";
            msg[238] <= "W"; msg[239] <= "6"; msg[240] <= "=";
            msg[249] <= " ";
            msg[250] <= "W"; msg[251] <= "7"; msg[252] <= "=";
            msg[261] <= 8'h0A;
            put_hex(  9, ds2[ 0]);   // GOT
            put_hex( 22, ds2[ 1]);   // ERR
            put_hex( 35, ds2[ 2]);   // IDX
            put_hex( 48, ds2[ 3]);   // EXP
            put_hex( 61, ds2[ 4]);   // GTD
            put_hex( 73, ds2[ 5]);   // W0
            put_hex( 85, ds2[ 6]);   // W1
            put_hex( 97, ds2[ 7]);   // W2
            put_hex(109, ds2[ 8]);   // W3
            put_hex(121, ds2[ 9]);   // WC
            put_hex(133, ds2[10]);   // WD
            put_hex(145, ds2[11]);   // RC
            put_hex(157, ds2[12]);   // RV
            put_hex(169, ds2[13]);   // T0
            put_hex(181, ds2[14]);   // T1
            put_hex(193, ds2[15]);   // T2
            put_hex(205, ds2[16]);   // T3
            put_hex(217, ds2[17]);   // W4
            put_hex(229, ds2[18]);   // W5
            put_hex(241, ds2[19]);   // W6
            put_hex(253, ds2[20]);   // W7
        end
    endtask

    reg [1:0]  dbg_st;
    reg [8:0]  tx_idx;   // MSG_LEN=262 需要 9 bit（曾经写成 7 bit：tx_idx 永远
                         // 到不了 261，串口只发前 128 字节、永远发不完整行）
    reg [7:0]  tx_byte;
    reg        tx_req;
    wire       tx_busy;
    reg [24:0] per_cnt;

    uart_tx_8n1 #(
        .CLK_HZ (50_000_000),
        .BAUD   (115200)
    ) u_uart (
        .clk   (sys_clk),
        .rst_n (~wr_rst),
        .din   (tx_byte),
        .start (tx_req),
        .busy  (tx_busy),
        .tx    (uart_tx)
    );

    always @(posedge sys_clk) begin
        tx_req <= 1'b0;
        if (wr_rst) begin
            dbg_st  <= 2'd0;
            tx_idx  <= 7'd0;
            per_cnt <= 25'd0;
        end else begin
            case (dbg_st)
            2'd0: begin
                if (per_cnt == 25'd0) begin
                    fill_msg;
                    dbg_st <= 2'd1;
                    tx_idx <= 9'd0;
                end else begin
                    per_cnt <= per_cnt - 25'd1;
                end
            end
            2'd1: begin
                if (!tx_busy && !tx_req) begin
                    tx_byte <= msg[tx_idx];
                    tx_req  <= 1'b1;
                    if (tx_idx == MSG_LEN - 1) begin
                        dbg_st <= 2'd2;
                        tx_idx <= 9'd0;
                    end else begin
                        tx_idx <= tx_idx + 9'd1;
                    end
                end
            end
            2'd2: begin
                per_cnt <= PERIOD;
                dbg_st  <= 2'd0;
            end
            default: dbg_st <= 2'd0;
            endcase
        end
    end

endmodule
