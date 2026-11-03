//=============================================================================
//  ddr3_top.v —— DDR3 上板自检（独立顶层，先验证硬件，再接连续流）
//
//  为什么先做"自检"而不是直接接抓包：
//    DDR3 这条路上任何一环不对（MIG 参数、引脚、BANK 电压、200 MHz 时钟、
//    PCB 走线）都会表现成"读出来是乱的"。如果一开始就把它接进数据通路，
//    出了问题分不清是 MIG 还是自己的读写引擎。所以先跑一个最小闭环：
//    写 1024 个 128 bit 字 → 读回来逐个比较 → 用 LED 报结果。
//
//  状态（板载 LED）：
//    led[0] 常亮 = MIG 校准完成（init_calib_complete）
//    led[1] 常亮 = 全部比对通过；闪烁 = 有错（错误计数见 err_cnt）
//
//  时钟：50 MHz → MMCM → 200 MHz（MIG 的 sys_clk_i）；
//        MIG 自己产生 ui_clk = 100 MHz（400 MHz DDR / 4:1）。
//=============================================================================
`timescale 1ns / 1ps

module ddr3_top (
    input  wire        sys_clk,        // V4, 50 MHz
    output reg  [1:0]  led,            // AB21 / AB22

    // DDR3（BANK35, 1.35/1.5 V）
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
    // 时钟：50 MHz → 200 MHz
    //   VCO = 50 × 20 = 1000 MHz；CLKOUT0 = 1000 / 5 = 200 MHz
    //-------------------------------------------------------------------------
    wire clk200;
    wire mmcm_locked;

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
    wire clkfb, clk200_raw;

    BUFG u_bufg_200 (.I(clk200_raw), .O(clk200));

    //-------------------------------------------------------------------------
    // 复位：上电计数器在 200 MHz 域里跑，sys_rst 是高有效
    //-------------------------------------------------------------------------
    reg [15:0] por_cnt = 16'd0;
    reg        sys_rst_r = 1'b1;
    always @(posedge clk200) begin
        if (!mmcm_locked) begin
            por_cnt   <= 16'd0;
            sys_rst_r <= 1'b1;
        end else if (!por_cnt[15]) begin
            por_cnt   <= por_cnt + 16'd1;
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

    wire ui_clk;
    wire ui_clk_sync_rst;
    wire init_calib_complete;

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
        // MIG 的 sys_rst 低有效（生成 RTL 里 RST_ACT_LOW=1，内部 ~sys_rst）
        .sys_rst             (~sys_rst_r)
    );

    //-------------------------------------------------------------------------
    // 自检状态机（ui_clk 域）
    //   写：1024 个地址，每个地址发一条写命令 + 1 个 128 bit 数据
    //   读：同样的地址重发读命令，按到达顺序比对
    //-------------------------------------------------------------------------
    localparam [9:0]  N_WORDS = 10'd1024;      // 16 KB
    localparam [2:0]  CMD_WR  = 3'b000;
    localparam [2:0]  CMD_RD  = 3'b001;

    localparam [2:0]  S_IDLE  = 3'd0,          // 等校准
                      S_WR    = 3'd1,          // 写
                      S_WREND = 3'd2,          // 等最后一个写数据被接收
                      S_RD    = 3'd3,          // 读
                      S_DONE  = 3'd4;          // 比对结果

    reg [2:0]  st;
    reg [9:0]  wr_idx, rd_idx;
    reg [31:0] err_cnt;
    reg        wr_data_sent;
    reg        pass_r;

    // 每个地址对应的期望值：{4{16'hA5A5 ^ addr}} 做成 128 bit
    function [127:0] pattern(input [9:0] a);
        reg [15:0] p;
        begin
            p = 16'hA5A5 ^ {6'd0, a};
            pattern = {p, p, p, p};
        end
    endfunction

    wire app_cmd_ready = app_rdy;
    wire app_wdf_ready = app_wdf_rdy;

    // 写：app_en 与 app_wdf_wren 同拍给出（4:1 + x16 ⇒ 一条命令只带 1 个 UI 字）
    assign app_cmd      = (st == S_RD) ? CMD_RD : CMD_WR;
    assign app_en       = ((st == S_WR) && app_cmd_ready && app_wdf_ready) ||
                          ((st == S_RD) && app_cmd_ready);
    assign app_wdf_wren = (st == S_WR) && app_cmd_ready && app_wdf_ready;
    assign app_wdf_end  = app_wdf_wren;
    assign app_wdf_data = pattern(wr_idx);
    assign app_wdf_mask = 16'h0000;
    assign app_addr     = (st == S_RD) ? {18'd0, rd_idx} : {18'd0, wr_idx};

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            st       <= S_IDLE;
            wr_idx   <= 10'd0;
            rd_idx   <= 10'd0;
            err_cnt  <= 32'd0;
            pass_r   <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                if (init_calib_complete) begin
                    st     <= S_WR;
                    wr_idx <= 10'd0;
                end
            end

            S_WR: begin
                if (app_cmd_ready && app_wdf_ready) begin
                    if (wr_idx == N_WORDS - 10'd1) begin
                        st     <= S_WREND;
                    end else begin
                        wr_idx <= wr_idx + 10'd1;
                    end
                end
            end

            S_WREND: begin
                // 写命令都发完了；MIG 内部还有几个字在飞，等它把 wdf 收完
                if (app_wdf_rdy) begin
                    st     <= S_RD;
                    rd_idx <= 10'd0;
                end
            end

            S_RD: begin
                if (app_rd_data_valid) begin
                    if (app_rd_data !== pattern(rd_idx)) begin
                        err_cnt <= err_cnt + 32'd1;
                    end
                    if (rd_idx == N_WORDS - 10'd1) begin
                        st <= S_DONE;
                    end else begin
                        rd_idx <= rd_idx + 10'd1;
                    end
                end
            end

            S_DONE: begin
                pass_r <= (err_cnt == 32'd0);
            end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // 结果锁存（ui_clk 域）→ 同步到 50 MHz 域
    //   test_done_r / test_fail_r 是单 bit 电平，两级同步即可
    //-------------------------------------------------------------------------
    reg test_done_r = 1'b0;
    reg test_fail_r = 1'b0;
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            test_done_r <= 1'b0;
            test_fail_r <= 1'b0;
        end else if (st == S_DONE) begin
            test_done_r <= 1'b1;
            test_fail_r <= (err_cnt != 32'd0);
        end
    end

    reg [1:0] done_s, fail_s, calib_s;
    always @(posedge sys_clk) begin
        done_s  <= {done_s[0],  test_done_r};
        fail_s  <= {fail_s[0],  test_fail_r};
        calib_s <= {calib_s[0], init_calib_complete};
    end

    //-------------------------------------------------------------------------
    // LED（全部在 sys_clk 域，即使 MIG 没起来也能看见心跳）
    //
    //   led[0] = 1 Hz 心跳：只要位流在跑、50 MHz 时钟正常、引脚没错，它就一定闪。
    //            这是"什么都没发生"时第一个要看的东西。
    //   led[1] = 常亮：校准完成且 1024 字全部比对通过
    //            2 Hz 闪：校准完成但比对有错
    //            不亮：还没校准完（此时 led[0] 应该在闪）
    //-------------------------------------------------------------------------
    reg [24:0] hb_cnt;            // 2^25 / 50 MHz ≈ 0.67 s 翻转一次
    reg        hb;
    always @(posedge sys_clk) begin
        hb_cnt <= hb_cnt + 25'd1;
        if (hb_cnt == 25'd0) hb <= ~hb;
    end

    reg [23:0] fast_cnt;          // 2^24 / 50 MHz ≈ 0.34 s
    reg        fast;
    always @(posedge sys_clk) begin
        fast_cnt <= fast_cnt + 24'd1;
        if (fast_cnt == 24'd0) fast <= ~fast;
    end

    reg [1:0] led_r;
    always @(posedge sys_clk) begin
        led_r[0] <= hb;
        if (!calib_s[1]) begin
            led_r[1] <= 1'b0;
        end else if (!done_s[1]) begin
            led_r[1] <= 1'b0;             // 校准完成、测试还在跑：灭
        end else if (fail_s[1]) begin
            led_r[1] <= fast;             // 有错：闪
        end else begin
            led_r[1] <= 1'b1;             // 全对：常亮
        end
    end

    always @(*) led = led_r;

endmodule
