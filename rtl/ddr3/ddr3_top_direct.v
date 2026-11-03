//=============================================================================
//  ddr3_top_direct.v —— MIG 最小闭环自检（不经过 ddr3_ring）
//
//  目的：把「DDR3 到底能不能存住数据」和「环形引擎有没有 bug」彻底分开。
//  做法和 MIG 自己的 example design 一致：命令与写数据同拍给出（app_en 与
//  app_wdf_wren 同时拉高），写 8 个不同地址，冲刷后逐个读回比对，
//  8 行结果全部从串口打出来（地址 / 期望 / 实际）。
//
//  样点图样：地址 a 的第 k 个 32 bit = 32'hA5A50000 | (a<<8) | k，
//  地址和序号都写在数据里，一眼能看出是错位、丢字还是全零。
//
//  串口 115200 8N1（W21），输出形如：
//      A=0 EXP=A5A50000 GOT=A5A50000
//      ...
//      DONE ERR=00000000
//=============================================================================
`timescale 1ns / 1ps

module ddr3_top_direct (
    input  wire        sys_clk,        // V4, 50 MHz
    output reg  [1:0]  led,
    output wire        uart_tx,        // W21

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

    localparam integer NW = 8;          // 测 8 个字

    //-------------------------------------------------------------------------
    // 时钟：50 MHz → 200 MHz
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
    reg  [27:0]  app_addr;
    reg  [2:0]   app_cmd;
    reg          app_en;
    reg  [127:0] app_wdf_data;
    reg          app_wdf_end;
    reg          app_wdf_wren;
    wire [15:0]  app_wdf_mask = 16'h0000;   // 0 = 全部字节都写（1 才是屏蔽）
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
        .sys_rst             (~sys_rst_r)      // MIG 的 sys_rst 低有效
    );

    //-------------------------------------------------------------------------
    // 图样（PAT_XOR 每次构建换一个值 —— 这样“读回正确”只可能来自本次写入，
    //        上一版位流留在 DRAM 里的旧数据不会冒充成功）
    //-------------------------------------------------------------------------
    localparam [31:0] PAT_XOR = 32'h5A17_C0DE;

    function [127:0] wpat(input [31:0] a);
        reg [31:0] s0, s1, s2, s3;
        begin
            s0 = (32'hA5A5_0000 | (a << 8) | 32'd0) ^ PAT_XOR;
            s1 = (32'hA5A5_0000 | (a << 8) | 32'd1) ^ PAT_XOR;
            s2 = (32'hA5A5_0000 | (a << 8) | 32'd2) ^ PAT_XOR;
            s3 = (32'hA5A5_0000 | (a << 8) | 32'd3) ^ PAT_XOR;
            wpat = {s3, s2, s1, s0};
        end
    endfunction

    // 地址 a 的第 0 个样点（低 32 bit），用来做期望值比较
    function [31:0] spat(input [31:0] a);
        begin
            spat = (32'hA5A5_0000 | (a << 8)) ^ PAT_XOR;
        end
    endfunction

    //-------------------------------------------------------------------------
    // 测试状态机
    //-------------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0,
                     S_WR    = 3'd1,
                     S_WWAIT = 3'd2,
                     S_FLSH  = 3'd3,
                     S_RD    = 3'd4,
                     S_RWAIT = 3'd5,
                     S_DONE  = 3'd6;

    reg [2:0]  st;
    reg [3:0]  idx;
    // 五轮：0=写 0..7 后等 20 µs 读；1..4 = 只读（不写），分别在 100 µs / 1 ms /
    //       5 ms / 20 ms 后重读同一批地址 —— 用来画“数据能活多久”的衰减曲线。
    //       同时统计 init_calib_complete 的下降沿次数（重新校准会把 DRAM 内容写花）。
    reg [2:0]  rnd;
    localparam integer NROUND = 6;      // A B C D E + 一轮读 8..15（F）
    reg [31:0] got [0:NROUND*NW-1];
    reg        calib_d;
    reg [31:0] cal_fall;
    reg [31:0] err_cnt;
    reg [31:0] fl_cnt;
    reg [31:0] fl_tgt;
    reg        done_r;
    reg [31:0] wc_cnt;      // 写命令被 MIG 接收的次数
    reg [31:0] wd_cnt;      // 写数据被 MIG 接收的次数
    reg [31:0] rbase;       // 本轮读的起始字地址（0 或 8）

    // 本轮访问的绝对字地址
    wire [31:0] wa = rbase + {28'd0, idx};

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            st           <= S_IDLE;
            idx          <= 4'd0;
            rnd          <= 3'd0;
            err_cnt      <= 32'd0;
            fl_cnt       <= 32'd0;
            fl_tgt       <= 32'd2000;
            done_r       <= 1'b0;
            wc_cnt       <= 32'd0;
            wd_cnt       <= 32'd0;
            rbase        <= 32'd0;
            app_en       <= 1'b0;
            app_cmd      <= 3'd0;
            app_addr     <= 28'd0;
            app_wdf_data <= 128'd0;
            app_wdf_wren <= 1'b0;
            app_wdf_end  <= 1'b0;
            app_addr     <= 28'd0;
            got[0] <= 32'd0; got[1] <= 32'd0; got[2] <= 32'd0; got[3] <= 32'd0;
            got[4] <= 32'd0; got[5] <= 32'd0; got[6] <= 32'd0; got[7] <= 32'd0;
            got[8] <= 32'd0; got[9] <= 32'd0; got[10]<= 32'd0; got[11]<= 32'd0;
            got[12]<= 32'd0; got[13]<= 32'd0; got[14]<= 32'd0; got[15]<= 32'd0;
            got[16]<= 32'd0; got[17]<= 32'd0; got[18]<= 32'd0; got[19]<= 32'd0;
            got[20]<= 32'd0; got[21]<= 32'd0; got[22]<= 32'd0; got[23]<= 32'd0;
            got[24]<= 32'd0; got[25]<= 32'd0; got[26]<= 32'd0; got[27]<= 32'd0;
            got[28]<= 32'd0; got[29]<= 32'd0; got[30]<= 32'd0; got[31]<= 32'd0;
            got[32]<= 32'd0; got[33]<= 32'd0; got[34]<= 32'd0; got[35]<= 32'd0;
            got[36]<= 32'd0; got[37]<= 32'd0; got[38]<= 32'd0; got[39]<= 32'd0;
            got[40]<= 32'd0; got[41]<= 32'd0; got[42]<= 32'd0; got[43]<= 32'd0;
            got[44]<= 32'd0; got[45]<= 32'd0; got[46]<= 32'd0; got[47]<= 32'd0;
        end else begin
            case (st)
            S_IDLE: begin
                if (init_calib_complete) begin
                    idx    <= 4'd0;
                    fl_cnt <= 32'd0;
                    fl_tgt <= 32'd2000;
                    st     <= S_FLSH;      // 第 0 轮：写入之前先读一遍（A 行 = 写前旧内容）
                end
            end

            // 命令与写数据同拍给出（MIG 推荐的写法）
            S_WR: begin
                app_en       <= 1'b1;
                app_cmd      <= 3'd0;                     // 0 = write
                app_addr     <= {{(28-16){1'b0}}, wa[11:0], 4'b0000};  // 字节地址：一次突发 = 16 B
                app_wdf_data <= wpat(wa);
                app_wdf_wren <= 1'b1;
                app_wdf_end  <= 1'b1;
                st           <= S_WWAIT;
            end

            S_WWAIT: begin
                if (app_en && app_rdy) begin
                    app_en <= 1'b0;
                    wc_cnt <= wc_cnt + 32'd1;
                end
                if (app_wdf_wren && app_wdf_rdy) begin
                    app_wdf_wren <= 1'b0;
                    app_wdf_end  <= 1'b0;
                    wd_cnt       <= wd_cnt + 32'd1;
                end
                if (!app_en && !app_wdf_wren) begin
                    if (idx == NW-1) begin
                        fl_cnt <= 16'd0;
                        st     <= S_FLSH;
                    end else begin
                        idx <= idx + 4'd1;
                        st  <= S_WR;
                    end
                end
            end

            S_FLSH: begin
                if (fl_cnt == fl_tgt) begin
                    idx <= 4'd0;
                    st  <= S_RD;
                end else begin
                    fl_cnt <= fl_cnt + 32'd1;
                end
            end

            S_RD: begin
                app_en   <= 1'b1;
                app_cmd  <= 3'd1;                         // 1 = read
                app_addr <= {{(28-16){1'b0}}, wa[11:0], 4'b0000};   // 字节地址
                st       <= S_RWAIT;
            end

            S_RWAIT: begin
                if (app_en && app_rdy)
                    app_en <= 1'b0;
                if (app_rd_data_valid) begin
                    got[{rnd, idx[2:0]}] <= app_rd_data[31:0];
                    idx <= idx + 4'd1;
                    if (idx == NW-1) begin
                        // A=写之前先读（旧内容）→ 然后写 0..7
                        // B=写后 20 µs 读，C=紧接着立刻再读一遍，
                        // D=再等 100 µs 读，E=再等 5 ms 读
                        fl_cnt <= 32'd0;
                        idx    <= 4'd0;
                        if (rnd == 3'd5) begin
                            st <= S_DONE;
                        end else begin
                            rnd <= rnd + 3'd1;
                            case (rnd)
                                3'd0:    begin fl_tgt <= 32'd2000;     st <= S_WR;    end  // 写 0..7
                                3'd1:    begin fl_tgt <= 32'd1;        st <= S_FLSH;  end  // 紧接再读
                                3'd2:    begin fl_tgt <= 32'd10_000;   st <= S_FLSH;  end  // 100 µs
                                3'd3:    begin fl_tgt <= 32'd500_000;  st <= S_FLSH;  end  // 5 ms
                                3'd4:    begin rbase <= 32'd8; fl_tgt <= 32'd1; st <= S_FLSH; end  // 读 8..15
                                default: begin fl_tgt <= 32'd1;        st <= S_FLSH;  end
                            endcase
                        end
                    end else begin
                        st <= S_RD;
                    end
                end
            end

            S_DONE: begin
                app_en  <= 1'b0;
                done_r  <= 1'b1;
            end

            default: st <= S_IDLE;
            endcase

            // 错误计数（读回之后才有意义）
            if (app_rd_data_valid && (app_rd_data[31:0] !== spat(wa)))
                err_cnt <= err_cnt + 32'd1;
        end
    end

    //-------------------------------------------------------------------------
    // init_calib_complete 下降沿计数：>0 说明 MIG 在跑的过程中又重新初始化过
    // （重新校准会把 DRAM 内容写花，正好能解释“数据 5 ms 后消失”）
    //-------------------------------------------------------------------------
    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            calib_d  <= 1'b0;
            cal_fall <= 32'd0;
        end else begin
            calib_d <= init_calib_complete;
            if (calib_d && !init_calib_complete)
                cal_fall <= cal_fall + 32'd1;
        end
    end

    //-------------------------------------------------------------------------
    // LED：led[0] 心跳（50 MHz 域），led[1] 完成=亮 / 跑动=闪
    //-------------------------------------------------------------------------
    reg [24:0] div_cnt;
    always @(posedge sys_clk) div_cnt <= div_cnt + 25'd1;

    always @(*) begin
        led[0] = div_cnt[24];
        led[1] = done_r ? (err_cnt == 32'd0) : div_cnt[21];
    end

    //-------------------------------------------------------------------------
    // 串口输出（115200）
    //   8 行 "A=n EXP=xxxxxxxx GOT=xxxxxxxx\n" + 一行 "DONE ERR=xxxxxxxx\n"
    //-------------------------------------------------------------------------
    localparam integer LINE = 30;
    localparam integer TDONE = 56;
    localparam integer MSG_LEN = NROUND * NW * LINE + TDONE;

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

    integer fi;
    integer rr;
    reg [31:0] fexp;
    reg [31:0] fwa;
    reg [7:0]  fad;

    task fill_msg;
        begin
            for (fi = 0; fi < NROUND*NW; fi = fi + 1) begin
                rr   = fi / NW;                      // 0..NROUND-1 轮
                fad  = {4'd0, fi[2:0]} + ((rr == 5) ? 8'd8 : 8'd0);  // 第 6 轮读 8..15
                fwa  = {24'd0, fad};
                fexp = spat(fwa);
                msg[fi*LINE +  0] <= 8'd65 + rr[7:0];   // 'A' + 轮号
                msg[fi*LINE +  1] <= "=";
                msg[fi*LINE +  2] <= 8'd48 + fad;
                msg[fi*LINE +  3] <= " ";
                msg[fi*LINE +  4] <= "E";
                msg[fi*LINE +  5] <= "X";
                msg[fi*LINE +  6] <= "P";
                msg[fi*LINE +  7] <= "=";
                put_hex(fi*LINE +  8, fexp);
                msg[fi*LINE + 16] <= " ";
                msg[fi*LINE + 17] <= "G";
                msg[fi*LINE + 18] <= "O";
                msg[fi*LINE + 19] <= "T";
                msg[fi*LINE + 20] <= "=";
                put_hex(fi*LINE + 21, got[fi]);
                msg[fi*LINE + 29] <= 8'h0A;
            end
            msg[NROUND*NW*LINE +  0] <= "D";
            msg[NROUND*NW*LINE +  1] <= "O";
            msg[NROUND*NW*LINE +  2] <= "N";
            msg[NROUND*NW*LINE +  3] <= "E";
            msg[NROUND*NW*LINE +  4] <= " ";
            msg[NROUND*NW*LINE +  5] <= "C";
            msg[NROUND*NW*LINE +  6] <= "A";
            msg[NROUND*NW*LINE +  7] <= "L";
            msg[NROUND*NW*LINE +  8] <= "=";
            put_hex(NROUND*NW*LINE +  9, cal_fall);
            msg[NROUND*NW*LINE + 17] <= " ";
            msg[NROUND*NW*LINE + 18] <= "E";
            msg[NROUND*NW*LINE + 19] <= "R";
            msg[NROUND*NW*LINE + 20] <= "R";
            msg[NROUND*NW*LINE + 21] <= "=";
            put_hex(NROUND*NW*LINE + 22, err_cnt);
            msg[NROUND*NW*LINE + 30] <= " ";
            msg[NROUND*NW*LINE + 31] <= "W";
            msg[NROUND*NW*LINE + 32] <= "C";
            msg[NROUND*NW*LINE + 33] <= "=";
            put_hex(NROUND*NW*LINE + 34, wc_cnt);
            msg[NROUND*NW*LINE + 42] <= " ";
            msg[NROUND*NW*LINE + 43] <= "W";
            msg[NROUND*NW*LINE + 44] <= "D";
            msg[NROUND*NW*LINE + 45] <= "=";
            put_hex(NROUND*NW*LINE + 46, wd_cnt);
            msg[NROUND*NW*LINE + 54] <= 8'h0A;
        end
    endtask

    // 50 MHz 域自己的上电复位
    reg  [9:0] wrst_cnt = 10'd0;
    wire       wr_rst   = ~wrst_cnt[9];
    always @(posedge sys_clk)
        if (!wrst_cnt[9]) wrst_cnt <= wrst_cnt + 10'd1;

    reg [1:0]  dbg_st;
    reg [10:0] tx_idx;
    reg [7:0]  tx_byte;
    reg        tx_req;
    wire       tx_busy;
    reg [23:0] gap_cnt;

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
            tx_idx  <= 10'd0;
            gap_cnt <= 24'd0;
        end else begin
            case (dbg_st)
            2'd0: begin
                if (done_r) begin
                    fill_msg;
                    dbg_st <= 2'd1;
                    tx_idx <= 10'd0;
                end
            end
            2'd1: begin
                if (!tx_busy && !tx_req) begin
                    tx_byte <= msg[tx_idx];
                    tx_req  <= 1'b1;
                    if (tx_idx == MSG_LEN - 1) begin
                        dbg_st  <= 2'd2;
                        tx_idx  <= 10'd0;
                        gap_cnt <= 24'd12_000_000;   // 约 0.25 s 后重发
                    end else begin
                        tx_idx <= tx_idx + 10'd1;
                    end
                end
            end
            2'd2: begin
                if (gap_cnt == 24'd0) dbg_st <= 2'd0;
                else                  gap_cnt <= gap_cnt - 24'd1;
            end
            default: dbg_st <= 2'd0;
            endcase
        end
    end

endmodule
