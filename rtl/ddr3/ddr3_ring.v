//=============================================================================
//  ddr3_ring.v —— DDR3 环形缓冲（写引擎 + 回读引擎，接 MIG 原生 UI）
//-----------------------------------------------------------------------------
//  数据单位：一个"样点" = 32 bit（ch1 int16 在低 16 位、ch2 在高 16 位），
//  与工程里 scope_capture 的 {c,s} 打包方式一致。
//
//  一个 128 bit UI 字装 4 个样点：word = { s3, s2, s1, s0 }，s0 在 bits[31:0]，
//  即"按时间先后从低到高"，回读时按 32 bit 切即可。
//
//  容量：RING_AW=24 ⇒ 16,777,216 字 × 4 点 = 67,108,864 点 = 256 MB
//        @25 MSPS ≈ 2.68 s，@50 MSPS ≈ 1.34 s
//
//  三个部件，每个 always 块只写自己拥有的寄存器（避免多驱动）：
//    ① 写收集器 coll_*：从 FIFO 每拍取一个样点，攒满 4 个 → w_word / w_ready
//    ② 命令引擎 eng_*：唯一驱动 app_* 的地方；写优先，读补空
//    ③ 回读解包 unp_*：收 128 bit → 跳过 rd_base 低 2 位之前的点 → 推输出 FIFO
//
//  为什么回读只允许 1 条命令在飞（MAX_OUT=1）：
//    7 系列 MIG 的 UI 在 Number of Bank Machines > 1 时，不同 bank machine 的读
//    各自完成，**返回顺序不保证**；返回数据里没有地址标签，乱序就无法重排。
//    所以这里串行发命令，用"一条一个来回"换严格顺序。代价约 2.5~4 M 字/s
//    （= 10~16 M 样点/s），12.5 MSPS 回放够用但不宽裕；提速需上板验证顺序性。
//=============================================================================
`timescale 1ns / 1ps

module ddr3_ring #(
    parameter integer RING_AW = 24,     // 字数 = 2**RING_AW
    parameter integer FIFO_AW = 8,      // 写侧异步 FIFO 深度 = 2**FIFO_AW 个样点
    parameter integer MAX_OUT = 1,      // 同时在飞的读命令数
    parameter integer OQ_AW   = 4       // 输出 FIFO 深度 = 2**OQ_AW 个样点
) (
    // ---------------- 写侧：50 MHz ADC 域 ----------------
    input  wire         wr_clk,
    input  wire         wr_rst_n,
    input  wire         wr_valid,
    input  wire [31:0]  wr_data,
    output wire         wr_ready,
    output wire [31:0]  wr_samples,
    output wire         wr_wrapped,

    // ---------------- 读侧：ui_clk 域 ----------------
    input  wire         ui_clk,
    input  wire         ui_rst,          // 高有效
    input  wire         rd_start,        // 单拍脉冲
    input  wire [31:0]  rd_base,         // 起始样点绝对序号
    input  wire [31:0]  rd_len,          // 样点数
    output wire [31:0]  rd_data,
    output wire         rd_valid,        // 输出 FIFO 非空，下游每拍取一个
    output wire         rd_done,         // 单拍脉冲
    output wire         rd_busy,

    // ---------------- MIG 原生 UI ----------------
    output reg  [27:0]  app_addr,
    output reg  [2:0]   app_cmd,
    output reg          app_en,
    output reg  [127:0] app_wdf_data,
    output reg          app_wdf_end,
    output reg          app_wdf_wren,
    output wire [15:0]  app_wdf_mask,
    input  wire         app_rdy,
    input  wire         app_wdf_rdy,
    input  wire [127:0] app_rd_data,
    input  wire         app_rd_data_valid,
    input  wire         app_rd_data_end,

    // ---------------- 调试观测（仅供 bring-up 顶层接串口用）----------------
    output wire [31:0]  dbg_need,        // 还要吐几个样点
    output wire [31:0]  dbg_pend,        // 在飞读命令数
    output wire [31:0]  dbg_wleft,       // 还没发出的读命令数
    output wire [27:0]  dbg_addr         // 当前读地址
);

    localparam integer RING_WORDS = (1 << RING_AW);
    localparam integer CAP_SAMPS  = RING_WORDS * 4;
    localparam [2:0]   CMD_WRITE  = 3'd0;
    localparam [2:0]   CMD_READ   = 3'd1;

    assign app_wdf_mask = 16'h0000;

    //=========================================================================
    // 写侧：50 MHz 样点 → 异步 FIFO
    //=========================================================================
    wire             fifo_empty;
    wire [31:0]      fifo_dout;
    wire             fifo_almost_full;
    reg              fifo_rd_en;

    async_fifo #(
        .DW     (32),
        .AW     (FIFO_AW),
        .ALMOST (4)
    ) u_wfifo (
        .wr_clk      (wr_clk),
        .wr_rst_n    (wr_rst_n),
        .wr_en       (wr_valid && wr_ready),
        .din         (wr_data),
        .full        (),
        .almost_full (fifo_almost_full),
        .rd_clk      (ui_clk),
        .rd_rst_n    (~ui_rst),
        .rd_en       (fifo_rd_en),
        .dout        (fifo_dout),
        .empty       (fifo_empty),
        .wr_level    (),
        .rd_level    ()
    );

    assign wr_ready = ~fifo_almost_full;

    //=========================================================================
    // ① 写收集器
    //=========================================================================
    reg  [127:0]      w_word;
    reg  [1:0]        w_cnt;
    reg               w_ready;
    reg               rd_pend;
    reg               rd_en_d;           // 上一拍发过 rd_en，等 dout 更新
    reg  [31:0]       samp_cnt;
    reg               wrapped;
    reg  [RING_AW-1:0] wptr;
    reg               w_consume;         // 命令引擎：这个字已写进 DDR3（collector 只读）
    reg               cmd_ok, dat_ok;    // 写命令 / 写数据 各自握手完成
    reg               upend;             // 解包侧：当前 word 还没排完（引擎据此反压）

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            fifo_rd_en <= 1'b0;
            rd_pend    <= 1'b0;
            rd_en_d    <= 1'b0;
            w_word     <= 128'd0;
            w_cnt      <= 2'd0;
            w_ready    <= 1'b0;
            samp_cnt   <= 32'd0;
            wrapped    <= 1'b0;
            wptr       <= {RING_AW{1'b0}};
        end else begin
            fifo_rd_en <= 1'b0;

            if (w_consume) begin
                w_ready <= 1'b0;
                w_cnt   <= 2'd0;
            end

            if (!rd_pend) begin
                if (!fifo_empty && !w_ready && !rd_en_d) begin
                    fifo_rd_en <= 1'b1;
                    rd_en_d    <= 1'b1;
                end
            end

            // async_fifo 的 dout 是"rd_en 之后下一拍"才有效：rd_en 在 N 拍发出，
            // dout 在 N+1 拍才更新。所以必须再等一拍（rd_en_d）才能取数，
            // 否则每个字都会拿到上一个字的数据（表现为整段样点平移）。
            if (rd_en_d) begin
                rd_en_d <= 1'b0;
                rd_pend <= 1'b1;
            end else if (rd_pend) begin
                rd_pend <= 1'b0;
                w_word[w_cnt*32 +: 32] <= fifo_dout;   // 时间顺序：先到的在低位
                if (w_cnt == 2'd3)
                    w_ready <= 1'b1;
                w_cnt <= w_cnt + 2'd1;
            end

            if (w_consume) begin
                wptr <= wptr + 1'b1;
                if (samp_cnt < CAP_SAMPS)
                    samp_cnt <= samp_cnt + 32'd4;
                if (wptr == RING_WORDS - 1)
                    wrapped <= 1'b1;
            end
        end
    end

    assign wr_samples = samp_cnt;
    assign wr_wrapped = wrapped;

    //=========================================================================
    // ② 命令引擎（唯一驱动 app_*）
    //=========================================================================
    reg  [1:0]  st;
    reg  [27:0] addr_r;
    reg  [31:0] eng_words_left;
    reg  [31:0] eng_pend;
    reg         eng_active;
    reg         eng_done_r;

    wire eng_slot_free = eng_active && (eng_words_left != 32'd0) &&
                         (eng_pend < MAX_OUT) && !upend;

    reg  [31:0] pend_nxt;

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            st            <= 2'd0;
            app_en        <= 1'b0;
            app_cmd       <= CMD_WRITE;
            app_addr      <= 28'd0;
            app_wdf_data  <= 128'd0;
            app_wdf_wren  <= 1'b0;
            app_wdf_end   <= 1'b0;
            addr_r        <= 28'd0;
            eng_words_left<= 32'd0;
            eng_pend      <= 32'd0;
            eng_active    <= 1'b0;
            eng_done_r    <= 1'b0;
            w_consume     <= 1'b0;
            cmd_ok        <= 1'b0;
            dat_ok        <= 1'b0;
        end else begin
            w_consume <= 1'b0;
            // eng_done_r 必须是"粘滞"的：它只在 read 命令全部发完的那一拍置 1，
            // 而解包此时往往还没把 oq 吐完。以前这里每拍清 0，rd_done 就永远等不到。

            // 在飞读计数：本拍可能"发一条 + 回一条"，用阻塞临时量合并，
            // 否则两个非阻塞赋值会互相覆盖，计数器一路下溢（曾经下溢到 0xFFFFFFFC）。
            pend_nxt = eng_pend;
            if (app_rd_data_valid)
                pend_nxt = pend_nxt - 32'd1;

            case (st)
            2'd0: begin
                // ★ 不能用裸 w_ready：w_consume 是引擎发出的单拍脉冲，collector 要到
                //   那一拍末尾才清掉 w_ready，同拍 st=0 会看到 w_ready 仍为 1 并把
                //   同一个字再写一遍（地址 0,0,2,2…，每个字占两个地址）。
                if (w_ready && !w_consume) begin
                    app_en       <= 1'b1;
                    app_cmd      <= CMD_WRITE;
                    // app_addr 是"字节地址"：一个 128 bit 突发 = 16 字节，
                    // 所以字指针要左移 4 位。加 1 会让 8 次写全落在同一个 16 字节里。
                    app_addr     <= {{(28-RING_AW-4){1'b0}}, wptr, 4'b0000};
                    app_wdf_data <= w_word;
                    // ★ 写数据必须和写命令同拍给出（与 MIG 例程一致）：先发命令、
                    //   过几拍再给数据，数据会和后一条命令配对，落到错地址上。
                    app_wdf_wren <= 1'b1;
                    app_wdf_end  <= 1'b1;
                    st           <= 2'd1;
                end else if (eng_slot_free) begin
                    app_en   <= 1'b1;
                    app_cmd  <= CMD_READ;
                    app_addr <= {{(28-RING_AW-4){1'b0}}, addr_r[RING_AW-1:0], 4'b0000};
                    st       <= 2'd2;
                end else if (eng_active && eng_words_left == 32'd0 && eng_pend == 32'd0) begin
                    eng_active <= 1'b0;
                    eng_done_r <= 1'b1;
                end
            end
            2'd1: begin
                // 命令与数据同拍发出，各自等自己的握手；两边都完成才算这个字写完。
                if (app_en && app_rdy) begin
                    app_en <= 1'b0;
                    cmd_ok <= 1'b1;
                end
                if (app_wdf_wren && app_wdf_rdy) begin
                    app_wdf_wren <= 1'b0;
                    app_wdf_end  <= 1'b0;
                    dat_ok       <= 1'b1;
                end
                if (cmd_ok && dat_ok) begin
                    cmd_ok    <= 1'b0;
                    dat_ok    <= 1'b0;
                    w_consume <= 1'b1;
                    st        <= 2'd0;
                end
            end
            2'd2: begin
                // 必须停留在 st=2 直到命令被接收：否则 app_en 会一直挂着，
                // 后续每个 app_rdy 高的拍都被当成一次新命令（读命令被重复执行）。
                if (app_en && app_rdy) begin
                    app_en        <= 1'b0;
                    addr_r        <= addr_r + 1'b1;
                    eng_words_left<= eng_words_left - 32'd1;
                    pend_nxt      = pend_nxt + 32'd1;
                    st            <= 2'd0;
                end
            end
            default: st <= 2'd0;
            endcase

            if (rd_start && !eng_active) begin
                addr_r         <= rd_base[RING_AW+1:2];
                eng_words_left <= (rd_len + {30'd0, rd_base[1:0]} + 32'd3) >> 2;
                pend_nxt       = 32'd0;
                eng_active     <= 1'b1;
                eng_done_r     <= 1'b0;      // 新一次回读：清掉上一轮的完成标志
            end

            eng_pend <= pend_nxt;
        end
    end

    //=========================================================================
    // ③ 回读解包
    //=========================================================================
    reg          unp_valid;
    reg  [127:0] unp_word;
    reg  [31:0]  unp_need;
    reg  [1:0]   unp_skip;
    reg          unp_first;

    reg  [31:0]    oq_mem [0:(1<<OQ_AW)-1];
    reg  [OQ_AW:0] oq_wr, oq_rd;
    wire [OQ_AW:0] oq_count = oq_wr - oq_rd;
    wire           oq_full  = (oq_count >= (1 << OQ_AW) - 4);

    reg            rd_done_r;

    assign rd_data  = oq_mem[oq_rd[OQ_AW-1:0]];
    assign rd_valid = (oq_count != 0);
    assign rd_done  = rd_done_r;
    assign rd_busy  = eng_active;

    assign dbg_need  = unp_need;
    assign dbg_pend  = eng_pend;
    assign dbg_wleft = eng_words_left;
    assign dbg_addr  = addr_r;

    reg  [127:0] uw;                     // 正在排出的 word
    reg  [2:0]   uidx;                   // 下一个待取样点下标（0..3）

    // 本拍能往输出 FIFO 塞几个样点：受「本 word 还剩几个」「还要吐几个」「FIFO 空间」三重限制。
    // ★ 不能写成 for 循环里累加 npush：4 次迭代互相依赖，综合出 20 级 CARRY4，
    //   100 MHz 下 WNS = -1.136 ns（2026-10-19 实测）。改成先算 push_n，再并行写。
    wire [127:0]  ush    = uw >> {uidx, 5'b0};          // 把当前位置对齐到最低位
    wire [3:0]    uleft  = 4'd4 - {1'b0, uidx};         // 本 word 还剩几个样点（0..4，要 4 bit）
    wire [OQ_AW:0] ofree = (1 << OQ_AW) - oq_count;     // 输出 FIFO 剩几个空位

    reg  [3:0]    push_n;
    reg  [3:0]    uidx_nx;
    reg  [31:0]   unp_need_nx;
    always @(*) begin
        push_n = uleft;
        if (ofree < push_n) push_n = ofree;
        if (unp_need < push_n) push_n = unp_need[3:0];
        uidx_nx     = {1'b0, uidx} + push_n;
        unp_need_nx = unp_need - push_n;
    end

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            oq_wr     <= {(OQ_AW+1){1'b0}};
            oq_rd     <= {(OQ_AW+1){1'b0}};
            unp_valid <= 1'b0;
            unp_word  <= 128'd0;
            unp_need  <= 32'd0;
            unp_skip  <= 2'd0;
            unp_first <= 1'b0;
            uw        <= 128'd0;
            uidx      <= 3'd0;
            upend     <= 1'b0;
            rd_done_r <= 1'b0;
        end else begin
            rd_done_r <= 1'b0;

            // 下游每拍取一个（rd_valid 为高的拍）
            if (oq_count != 0)
                oq_rd <= oq_rd + 1'b1;

            // 收 word：base 之前的点（unp_skip）只在第一个 word 上生效
            if (app_rd_data_valid) begin
                uw        <= app_rd_data;
                uidx      <= unp_first ? {1'b0, unp_skip} : 3'd0;
                upend     <= 1'b1;
                unp_first <= 1'b0;
            end

            // 排出：push_n 已经算好，4 个位置并行写，彼此不构成依赖链
            // ★ 必须排除 "本拍来了新 word" 的拍：那一拍 uidx 会被改成 0/偏置，
            //   和这里的 `uidx <= uidx + push_n` 撞车（后面的赋值赢），整段 word 被吞掉
            //   ——之前第 17 个 word 就是这样消失的（第 68 点开始整体错位）。
            if (upend && !app_rd_data_valid) begin
                if (push_n > 4'd3) oq_mem[(oq_wr + 3'd3) & ((1 << OQ_AW) - 1)] <= ush[127:96];
                if (push_n > 4'd2) oq_mem[(oq_wr + 3'd2) & ((1 << OQ_AW) - 1)] <= ush[95:64];
                if (push_n > 4'd1) oq_mem[(oq_wr + 3'd1) & ((1 << OQ_AW) - 1)] <= ush[63:32];
                if (push_n > 4'd0) oq_mem[oq_wr[OQ_AW-1:0]]          <= ush[31:0];
                if (push_n != 4'd0) begin
                    oq_wr    <= oq_wr + push_n;   // 不能写 push_n[OQ_AW:0]：push_n 只有 4 bit，高位取到 X
                    unp_need <= unp_need_nx;
                end
                if (uidx_nx >= 4'd4 || unp_need_nx == 32'd0)
                    upend <= 1'b0;
                uidx <= uidx_nx[2:0];
            end

            if (rd_start && !eng_active) begin
                unp_need  <= rd_len;
                unp_skip  <= rd_base[1:0];
                unp_first <= 1'b1;
                uw        <= 128'd0;
                uidx      <= 3'd0;
                upend     <= 1'b0;
            end

            // 结束条件：引擎发完、全收完、要吐的点也吐完了
            if (eng_done_r && unp_need == 32'd0 && !upend && oq_count <= 1)
                rd_done_r <= 1'b1;
        end
    end

`ifdef DBG
    reg eng_active_d;
    always @(posedge ui_clk) eng_active_d <= eng_active;
    always @(posedge ui_clk) if (!ui_rst) begin
        if (rd_start) $display("t=%0t RDSTART len=%0d eng_active=%b", $time, rd_len, eng_active);
        if (eng_active && !eng_active_d) $display("t=%0t ENG_START", $time);
        if (app_rd_data_valid) $display("t=%0t RDVALID", $time);
        if (upend && !app_rd_data_valid && push_n != 0)
            $display("t=%0t PUSH n=%0d uidx=%0d oq_wr=%0d need=%0d", $time, push_n, uidx, oq_wr, unp_need);
        if (rd_done_r) $display("t=%0t RD_DONE oq_wr=%0d oq_rd=%0d need=%0d", $time, oq_wr, oq_rd, unp_need);
    end
`endif

endmodule
