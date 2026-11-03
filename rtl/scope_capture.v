//=============================================================================
//  scope_capture.v —— 深存储抓包引擎（B1 第一级）
//-----------------------------------------------------------------------------
//  为什么需要它：
//    连续遥测只有 10 kHz 帧率，对 50 MSPS 的 ADC 来说等效采样间隔 100 µs，
//    50 kHz 以上的波形全是混叠，20 ns 级的时间分辨率根本无从谈起。
//    本模块在 50 MHz 时钟域把 s/c 两路 16 bit 样本连续写进片内 BRAM，
//    抓满一窗后由 scope_dump / scope_udp 全速回读，从而拿到"原始波形"。
//    28672 点 @50 MSPS = 0.57 ms；@25 MSPS（抽取 2）= 1.15 ms。
//-----------------------------------------------------------------------------
//  实现要点（对应 SPEC §0 的全局约定）：
//    1) 单时钟、同步复位低有效、无 initial / #delay / inout。
//    2) 写地址按 DEPTH 回绕。DEPTH=28672 时**显式拆成 3 个 bank**
//       （16384 + 8192 + 4096，共 28 个 RAMB36）。为什么不能直接写 28672：
//       Vivado 会把非 2 次幂深度向上取整到 2 的幂再铺 BRAM（40960 实测被
//       算成 65536），直接写 28672 仍会铺 32 片；而"显示屏 + 以太网 + 抓包"
//       在 7A35T 上只剩 28 片（32768 实测 50.5 片 → DRC UTLZ-1 布不通，
//       见 _merge_work/共存可行性评估.md）。
//    3) 触发窗口 = [trig_addr - pre_eff, +cap_len)。trig_addr 是"触发样本
//       将要写入的地址"，因此触发样本在窗口内的下标恰好是 pre_eff。
//       cap_start = (trig_addr - pre_eff) mod DEPTH，读侧从 cap_start
//       顺序读、回绕一次即可覆盖整窗。
//    4) 抽取在"有效样本"上做：dec_log2=0/1/2/3 对应每 1/2/4/8 个有效
//       样本存 1 个。触发判决放在抽取之后，保证"判决用的样本 = 存下的样本"。
//    5) 立即触发（trig_mode==0）在 arm 当拍就把触发标记置起，pre 无效，
//       窗口从地址 0 开始，等价于"抓 arm 之后的 cap_len 个样本"。
//    6) 窗口结束用 post_cnt/target 两个量判断，避免"触发样本算不算一个"
//       的经典 off-by-one：立即触发 target=len，触发模式 target=len-pre。
//    7) st_done 一直保持到下一次 arm 或 abort，上位机可以慢慢轮询；
//       st_ovf 表示 cap_len 超过 DEPTH，实际只抓了 DEPTH 点。
//    8) 读口仍是**1 拍延迟**：三个 bank 的读数据各自寄存一拍，bank 选择
//       信号与地址同拍寄存，再用一个组合 mux 合流。读者
//       （scope_dump / scope_udp / stream_tx）的时序一行都不用改。
//    9) DEPTH<=16384 或 >28672 时退回"单块存储"实现（仿真小深度、或旧配置），
//       行为完全相同，只是综合时会按 2 次幂取整 —— 生产配置永远走 bank 路径。
//-----------------------------------------------------------------------------
//  资源：28672 x 32 bit → 28 个 RAMB36（16K 16 片 + 8K 8 片 + 4K 4 片）；
//       其余逻辑约 250 LUT / 200 FF（含触发比较、地址回绕与 bank 译码）。
//=============================================================================

`timescale 1ns / 1ps

module scope_capture #(
    parameter integer DEPTH = 28672          // 样本深度（32 bit/点：c[31:16] | s[15:0]）
)(
    input  wire               clk,
    input  wire               rst_n,

    // ---- 控制（全部来自 cap_regs，arm/abort 是 1 拍脉冲）----
    input  wire               arm,
    input  wire               abort,
    input  wire [1:0]         dec_log2,
    input  wire [15:0]        cap_len,
    input  wire [1:0]         trig_mode,      // 0=立即 1=上升沿 2=下降沿
    input  wire signed [15:0] trig_level,
    input  wire [15:0]        pre_len,

    // ---- 连续流模式（B2 二期）：stream=1 时不按 cap_len 停，一直写到 abort ----
    input  wire               stream,
    input  wire [2:0]         stream_dec,     // 连续流的抽取 log2（0..4）

    // ---- 样本输入（s = 正弦/CH1，c = 余弦/CH2，16 bit 补码）----
    input  wire signed [15:0] s_in,
    input  wire signed [15:0] c_in,
    input  wire               in_valid,

    // ---- 读口（给 scope_dump / scope_udp / stream_tx；同步读，rd_data 比 rd_en 晚 1 拍）----
    input  wire [15:0]        rd_addr,
    input  wire               rd_en,
    output wire [31:0]        rd_data,

    // ---- 状态回读 ----
    output reg  [15:0]        cap_start,
    output reg  [15:0]        cap_len_eff,
    output reg  [15:0]        trig_idx,
    output reg  [31:0]        sample_cnt,
    output reg                st_armed,
    output reg                st_done,
    output reg                st_trig,
    output reg                st_busy,
    output reg                st_ovf,

    // ---- 连续流：写指针与"已存样点数"给 stream_tx 做追赶读 ----
    output reg  [15:0]        wr_ptr,
    output reg  [31:0]        strm_cnt,
    output reg                st_stream
);

    //-------------------------------------------------------------------------
    //  本地常量
    //-------------------------------------------------------------------------
    localparam [15:0] DEPTH_C  = DEPTH;
    localparam [15:0] DEPTH_M1 = DEPTH_C - 16'd1;

    // 28672 = 16384 + 8192 + 4096 恰好铺满 28 个 RAMB36。
    // 深度落在这个区间时才走 bank 路径；其余情况（仿真小深度 / 旧配置）走单块。
    localparam integer BANKED = (DEPTH > 16384) && (DEPTH <= 28672);

    //-------------------------------------------------------------------------
    //  抓包状态
    //-------------------------------------------------------------------------
    reg        trig_seen;       // 已捕获触发
    reg [15:0] pre_eff;
    reg [15:0] len_eff;
    reg [15:0] target;          // 触发后总共要收的样本数（含触发样本）
    reg [15:0] post_cnt;        // 触发后已收的样本数（触发样本记 1）
    reg [3:0]  dec_cnt3;
    reg signed [15:0] prev_s;
    reg        stream_mode;     // 本次 arm 是连续流模式
    reg [15:0] wr_addr;
    reg [15:0] wr_addr_nxt;

    wire [15:0] len_clamped = (cap_len > DEPTH_C) ? DEPTH_C : cap_len;
    wire [15:0] pre_clamped = (pre_len >= len_clamped) ? (len_clamped - 16'd1) : pre_len;

    // 抽取周期：dec_log2=0/1/2/3 → 1/2/4/8 个有效样本存 1 个
    // 连续流模式用 stream_dec（0..4 → 1/2/4/8/16），所以位宽要 5 bit
    wire [2:0] dec_sel = stream ? stream_dec : {1'b0, dec_log2};
    wire [4:0] dec_period = (dec_sel == 3'd0) ? 5'd1 :
                            (dec_sel == 3'd1) ? 5'd2 :
                            (dec_sel == 3'd2) ? 5'd4 :
                            (dec_sel == 3'd3) ? 5'd8 : 5'd16;
    wire       samp_en = in_valid && (dec_cnt3 == 4'd0);

    // 触发比较（在抽取后的样本上做）
    wire trig_cross_up = (prev_s <  trig_level) && (s_in >= trig_level);
    wire trig_cross_dn = (prev_s >  trig_level) && (s_in <= trig_level);

    //-------------------------------------------------------------------------
    //  抽取计数
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            dec_cnt3 <= 4'd0;
        end else if (in_valid) begin
            if (dec_cnt3 >= dec_period - 4'd1) dec_cnt3 <= 4'd0;
            else                               dec_cnt3 <= dec_cnt3 + 4'd1;
        end
    end

    //-------------------------------------------------------------------------
    //  主状态机
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_addr     <= 16'd0;
            wr_addr_nxt <= 16'd0;
            trig_seen   <= 1'b0;
            pre_eff     <= 16'd0;
            len_eff     <= 16'd0;
            target      <= 16'd0;
            post_cnt    <= 16'd0;
            prev_s      <= 16'sd0;
            cap_start   <= 16'd0;
            cap_len_eff <= 16'd0;
            trig_idx    <= 16'd0;
            sample_cnt  <= 32'd0;
            st_armed    <= 1'b0;
            st_done     <= 1'b0;
            st_trig     <= 1'b0;
            st_busy     <= 1'b0;
            st_ovf      <= 1'b0;
            stream_mode <= 1'b0;
            wr_ptr      <= 16'd0;
            strm_cnt    <= 32'd0;
            st_stream   <= 1'b0;
        end else begin
            // ---------------- 命令 ----------------
            if (abort) begin
                st_armed  <= 1'b0;
                st_busy   <= 1'b0;
                st_trig   <= 1'b0;
                st_stream <= 1'b0;
            end else if (arm) begin
                wr_addr     <= 16'd0;
                wr_addr_nxt <= 16'd1;
                sample_cnt  <= 32'd0;
                st_done     <= 1'b0;
                st_armed    <= 1'b1;
                st_busy     <= 1'b1;
                st_ovf      <= (cap_len > DEPTH_C);
                len_eff     <= len_clamped;
                cap_len_eff <= len_clamped;
                cap_start   <= 16'd0;
                pre_eff     <= 16'd0;
                trig_idx    <= 16'd0;
                prev_s      <= s_in;
                post_cnt    <= 16'd0;
                stream_mode <= stream;
                st_stream   <= stream;
                wr_ptr      <= 16'd0;
                strm_cnt    <= 32'd0;
                if (stream || trig_mode == 2'd0) begin
                    // 立即触发 / 连续流：窗口从 0 开始
                    trig_seen <= 1'b1;
                    st_trig   <= 1'b1;
                    target    <= len_clamped;
                end else begin
                    trig_seen <= 1'b0;
                    st_trig   <= 1'b0;
                    target    <= 16'd0;
                end
            end else if (st_armed && samp_en) begin
                // ---------------- 推进一个样本（存储写入在下方独立块）----------------
                sample_cnt   <= sample_cnt + 32'd1;
                wr_addr      <= wr_addr_nxt;
                wr_addr_nxt  <= (wr_addr_nxt == DEPTH_M1) ? 16'd0 : (wr_addr_nxt + 16'd1);

                if (stream_mode) begin
                    // 连续流：永不完成，只累计已存点数；
                    // wr_ptr = 下一次要写的地址，读侧的可读区间是 [rd_ptr, wr_ptr)（按 DEPTH 回绕）
                    wr_ptr   <= wr_addr_nxt;
                    strm_cnt <= strm_cnt + 32'd1;
                end else if (!trig_seen) begin
                    prev_s <= s_in;
                    if ((trig_mode == 2'd1 && trig_cross_up) ||
                        (trig_mode == 2'd2 && trig_cross_dn)) begin
                        trig_seen <= 1'b1;
                        st_trig   <= 1'b1;
                        pre_eff   <= pre_clamped;
                        trig_idx  <= pre_clamped;
                        post_cnt  <= 16'd1;                  // 触发样本本身算第 1 个
                        target    <= len_clamped - pre_clamped;
                        // ★ pre_len = cap_len-1 时 target=1：窗口在触发沿就已满，
                        //   而下面的完成判据至少要走一个后触发样本，原来会永远
                        //   等不到（(post_cnt+1)==1 不成立）→ 采满后一直不 done。
                        if ((len_clamped - pre_clamped) <= 16'd1) begin
                            st_armed <= 1'b0;
                            st_busy  <= 1'b0;
                            st_done  <= 1'b1;
                        end
                        // cap_start = (wr_addr - pre_clamped) mod DEPTH
                        cap_start <= (wr_addr >= pre_clamped)
                                     ? (wr_addr - pre_clamped)
                                     : (wr_addr + DEPTH_C - pre_clamped);
                    end
                end else begin
                    // 触发之后：post_cnt 从 1 开始累加，到 target 收工
                    // （用 >= ：target=1 的边界已在触发沿处理，这里再兜一层）
                    post_cnt <= post_cnt + 16'd1;
                    if ((post_cnt + 16'd1) >= target) begin
                        st_armed <= 1'b0;
                        st_busy  <= 1'b0;
                        st_done  <= 1'b1;
                    end
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    //  存储阵列 + 读写口
    //   写：arm/abort 当拍不写（与原 FSM 的 if/else 优先级一致），
    //       其余 st_armed && samp_en 的拍写 wr_addr 指向的 bank。
    //   读：三块 bank 各自寄存一拍，bank 选择与地址同拍寄存，
    //       组合 mux 合流 → rd_data 相对 rd_en 仍是 1 拍。
    //-------------------------------------------------------------------------
    wire [31:0] wr_din = {c_in, s_in};
    wire        wr_en  = st_armed && samp_en && !arm && !abort;
    wire [31:0] rd_data_w;

    generate
    if (BANKED) begin : g_banked
        reg [31:0] bank0 [0:16383];      // 0x0000 - 0x3FFF
        reg [31:0] bank1 [0:8191];       // 0x4000 - 0x5FFF
        reg [31:0] bank2 [0:4095];       // 0x6000 - 0x6FFF

        always @(posedge clk) begin
            if (wr_en) begin
                if (!wr_addr[14])      bank0[wr_addr[13:0]] <= wr_din;
                else if (!wr_addr[13]) bank1[wr_addr[12:0]] <= wr_din;
                else                   bank2[wr_addr[11:0]] <= wr_din;
            end
        end

        reg [31:0] q0, q1, q2;
        reg [1:0]  sel_r;

        always @(posedge clk) begin
            if (rd_en) begin
                q0    <= bank0[rd_addr[13:0]];
                q1    <= bank1[rd_addr[12:0]];
                q2    <= bank2[rd_addr[11:0]];
                sel_r <= rd_addr[14:13];
            end
        end

        // sel_r: 00/01 → bank0，10 → bank1，11 → bank2
        assign rd_data_w = (!sel_r[1]) ? q0 :
                           (!sel_r[0]) ? q1 : q2;
    end else begin : g_flat
        reg [31:0] mem [0:DEPTH-1];
        reg [31:0] rd_q;

        always @(posedge clk) begin
            if (wr_en) mem[wr_addr] <= wr_din;
        end

        always @(posedge clk) begin
            if (rd_en) rd_q <= mem[rd_addr];
        end

        assign rd_data_w = rd_q;
    end
    endgenerate

    assign rd_data = rd_data_w;

endmodule
