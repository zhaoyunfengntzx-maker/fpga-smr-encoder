//=============================================================================
//  scope_udp.v —— 抓包缓冲 → UDP 包流（B2 的"高速通道"）
//-----------------------------------------------------------------------------
//  为什么需要它：
//    串口批量 dump（B1）能把原始波形拿下来，但 112 KB 要 0.75 s，只能"抓一帧、
//    看一眼"。UDP 推送把同样一窗数据压到 ~1.1 ms，才谈得上"波形观察"。
//
//  数据流：
//    50 MHz 侧：从 scope_capture 的读口顺序取点（cap_start 起 n_points 个），
//               写进 33 bit 异步 FIFO（32 bit 样本 + 1 bit 保留）。
//    125 MHz 侧：按 350 点/包切成 UDP 帧，交给 eth_tx_mac。
//                每帧 = 14 ETH + 20 IP + 8 UDP + 16 应用头 + 4×点数。
//                最大 1458 B < 1500 MTU。
//
//  为什么"整窗一次推完"而不是"抓一包发一包"：
//    抓包是 BRAM 里的静止数据，发的时候不需要与采样同步，越简单越不容易错。
//
//  应用层头 16 B（小端）：
//    [0:1] 魔数 E7 5A   [2] 标志(bit0=本窗最后一包)   [3] 抽取 log2
//    [4:5] 包序号       [6:9] 首个样点在本窗内的下标
//    [10:13] 50 MHz 样点计数（0 = 未用）             [14:15] 保留
//=============================================================================

`timescale 1ns / 1ps

module scope_udp #(
    parameter integer DEPTH    = 28672,      // 必须与 scope_capture 的 DEPTH 一致（28672，非 2 的幂）
    parameter integer MAX_PTS  = 350,        // 每包最多样点数（1458 B 帧）
    parameter integer SRC_PORT = 5000
) (
    // ---- 50 MHz 侧 ----
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,                // 1 拍：开始推送
    input  wire        abort,
    input  wire [15:0] cap_start,            // 窗口首地址
    input  wire [15:0] n_points,             // 本次推送点数
    output reg  [15:0] rd_addr,
    output reg         rd_en,
    input  wire [31:0] rd_data,
    output wire        rd_busy,              // 高：正在读缓冲（eth_top 据此切读口 mux）

    // ---- 125 MHz 侧 ----
    input  wire        clk_125,
    input  wire        rst_n_125,
    input  wire [1:0]  dec_log2,
    input  wire [15:0] udp_port,
    input  wire [31:0] my_ip,
    input  wire [31:0] host_ip,
    input  wire [47:0] my_mac,
    input  wire [47:0] host_mac,
    input  wire        tx_hold,              // 其他协议栈占用（ARP/ICMP），本侧让路

    // ---- 到 eth_tx_mac ----
    //  ★ 这三根是**组合输出**：fbyte 由 bcnt 现算，MAC 在 tx_ready 的同一拍取走。
    //    早期版本把它们做成寄存器（tx_valid/tx_data <= ... 再判断 tx_ready），
    //    结果"最后一字节"在同一个沿里既被置 1 又被清 0，永远发不出去 —— 见
    //    sim/tb_eth_udp.v 的 [B] 用例。
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output wire        tx_busy,

    // ---- 状态/统计（125 MHz 侧，eth_top 打拍到 50 MHz）----
    output reg         busy,
    output reg         done,                 // 1 拍：整窗发完
    output reg  [15:0] pkt_cnt,
    output reg  [15:0] drop_cnt
);

    localparam [15:0] DEPTH_C  = DEPTH;
    localparam [15:0] MAX_PTS_C = MAX_PTS;

    //=========================================================================
    //  1) 50 MHz 侧：读缓冲 → FIFO
    //=========================================================================
    reg  [15:0] remain;
    reg  [15:0] raddr;
    reg         rd_run;
    reg  abort_tgl;               // 50 MHz：每次 abort 翻转一次，过域给 125 侧
    reg         rd_v1;            // 读命令在途：v1=数据本拍有效

    wire        fifo_full, fifo_almost_full, fifo_empty;
    wire        fifo_wr;
    wire [32:0] fifo_din;
    wire [32:0] fifo_dout;
    wire        fifo_rd;
    wire [9:0]  fifo_wr_level, fifo_rd_level;

    async_fifo #(.DW(33), .AW(9), .ALMOST(4)) u_fifo (
        .wr_clk      (clk),
        .wr_rst_n    (rst_n),
        .wr_en       (fifo_wr),
        .din         (fifo_din),
        .full        (fifo_full),
        .almost_full (fifo_almost_full),
        .rd_clk      (clk_125),
        .rd_rst_n    (rst_n_125),
        .rd_en       (fifo_rd),
        .dout        (fifo_dout),
        .empty       (fifo_empty),
        .wr_level    (fifo_wr_level),
        .rd_level    (fifo_rd_level)
    );

    // 读命令与数据之间只隔 1 拍（scope_capture 的 BRAM 输出寄存器）：
    //   T 拍发 rd_en/rd_addr → T+1 拍 rd_data 有效，同拍 rd_v1=1。
    // ★ 原来多算了一拍（fifo_wr 用 rd_v2）：连续读时每个突发丢首点、
    //   末点再重复一次，整窗静默错位且 drop 计数看不出来。已改回 rd_v1。
    assign fifo_wr  = rd_v1 && !fifo_full;
    assign fifo_din = {1'b0, rd_data};

    assign rd_busy = rd_run || rd_v1;

    reg start_tgl;

    always @(posedge clk) begin
        if (!rst_n) begin
            remain    <= 16'd0;
            raddr     <= 16'd0;
            rd_run    <= 1'b0;
            rd_v1     <= 1'b0;
            rd_en     <= 1'b0;
            rd_addr   <= 16'd0;
            start_tgl <= 1'b0;
            abort_tgl <= 1'b0;
        end else begin
            rd_en <= 1'b0;
            // ★ 数据比读命令晚 1 拍：N 拍发 rd_en/rd_addr（这里"发"指寄存器
            //   在 N 拍边沿置 1），scope_capture 在 N+1 拍边沿把 mem[addr]
            //   打进 q，所以 FIFO 写使能必须在 N+1 拍为 1、N+2 拍边沿取数。
            //   直接写 `rd_v1 <= 1'b1`（与 rd_en 同拍）会早一拍，读到的是
            //   上一个地址的陈旧数据 —— tb_eth_udp 报 "got 0f exp 10"。
            rd_v1 <= rd_en;

            if (start) begin
                remain    <= n_points;
                raddr     <= cap_start;
                rd_run    <= (n_points != 16'd0);
                rd_v1     <= 1'b0;
                start_tgl <= ~start_tgl;
            end

            if (abort) begin
                rd_run <= 1'b0;
                rd_v1  <= 1'b0;
                remain <= 16'd0;
                // 125 侧还在发剩下的包；用翻转位告诉它"这一窗作废"。
                abort_tgl <= ~abort_tgl;
            end

            // 每拍最多发一个读命令；FIFO 快满时停一下（写入在 2 拍后发生）
            // ★ 回绕不能用 `raddr & (DEPTH-1)`：DEPTH=28672 不是 2 的幂，
            //   掩码会落到不存在的地址（旧 32768 版本才成立）。这里显式比较，
            //   raddr 始终 < DEPTH，读地址直接就是 raddr。
            if (rd_run && !fifo_almost_full) begin
                rd_en   <= 1'b1;
                rd_addr <= raddr;
                raddr   <= (raddr == DEPTH_C - 16'd1) ? 16'd0 : (raddr + 16'd1);
                if (remain == 16'd1) begin
                    rd_run <= 1'b0;
                    remain <= 16'd0;
                end else begin
                    remain <= remain - 16'd1;
                end
            end
        end
    end

    //=========================================================================
    //  2) 125 MHz 侧：读 FIFO → 组帧 → 发送
    //     用"当前字 + 预取字"双缓冲，而不是 4 深移位队列：
    //     样点 4 字节/字，发一个字的时间（32 ns）远大于 FIFO 读延迟（16 ns），
    //     预取 1 个字就够。早先的移位队列在 push/pop 同拍时会打乱顺序。
    //=========================================================================
    reg  [31:0] cur_word;
    reg  [31:0] nxt_word;
    reg         have_cur, have_nxt, pf_req;
    reg         fifo_rd_r;

    assign fifo_rd = fifo_rd_r;

    reg  rd_v_d;
    reg  start_s1, start_s2, start_d;
    // abort 跨域：50 MHz 的 abort 是单拍脉冲，用翻转位带到 125 域；125 侧
    // 看完当前帧后进 S_ABORT 把 FIFO 冲空，否则残留的 have_cur/have_nxt 和
    // FIFO 里的旧样点会污染下一次抓包（审查 2026-10-22 第 9 条）。
    reg  abort_s1, abort_s2, abort_d, abort_pending;
    reg  [15:0] pkt_remain;
    reg  [15:0] pkt_samples;
    reg  [15:0] pkt_first;
    reg  [15:0] pkt_seq;
    reg  [15:0] bcnt;
    reg  [2:0]  st;

    localparam [2:0] S_IDLE = 3'd0,
                     S_ARM  = 3'd1,
                     S_PRE  = 3'd2,
                     S_PRE2 = 3'd5,
                     S_EMIT = 3'd3,
                     S_DONE = 3'd4,
                     S_ABORT = 3'd6;

    assign tx_busy = (st == S_EMIT);

    // 配置跨域（准静态，三拍同步）
    reg  [15:0] npts_s1, npts_s2, npts_sync;
    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            npts_s1 <= 16'd0; npts_s2 <= 16'd0; npts_sync <= 16'd0;
        end else begin
            npts_s1   <= n_points;
            npts_s2   <= npts_s1;
            npts_sync <= npts_s2;
        end
    end

    // 帧长/头长在进入 S_ARM 时**寄存**一次。
    // 若直接用 pkt_samples 组合算（58 + 4*n 是移位加法），这条进位链会
    // 和 CRC32 的 8 级级联串在同一拍里，125 MHz 建立时间差 ~4.4 ns。
    reg  [15:0] frm_len_r, ip_len_r, udp_len_r;
    reg         is_last_r;

    wire [15:0] frm_len = frm_len_r;
    wire [15:0] ip_len  = ip_len_r;
    wire [15:0] udp_len = udp_len_r;
    wire        is_last = is_last_r;
    wire [1:0]  kpos    = (bcnt - 16'd58) & 16'h0003;
    wire [15:0] nxt_n   = (pkt_remain > MAX_PTS_C) ? MAX_PTS_C : pkt_remain;

    //-------------------------------------------------------------------------
    function [7:0] b48;
        input [47:0] v;
        input [3:0]  k;
        begin
            case (k)
            4'd0: b48 = v[47:40];
            4'd1: b48 = v[39:32];
            4'd2: b48 = v[31:24];
            4'd3: b48 = v[23:16];
            4'd4: b48 = v[15:8];
            default: b48 = v[7:0];
            endcase
        end
    endfunction

    function [7:0] b32;
        input [31:0] v;
        input [3:0]  k;
        begin
            case (k)
            4'd0: b32 = v[31:24];
            4'd1: b32 = v[23:16];
            4'd2: b32 = v[15:8];
            default: b32 = v[7:0];
            endcase
        end
    endfunction

    function [15:0] ip_cks;
        input [15:0] total_len;
        input [31:0] src;
        input [31:0] dst;
        reg [31:0] s;
        begin
            s = 32'h4500 + {16'd0, total_len} + 32'h0000
              + 32'h4001 + {16'd0, src[31:16]} + {16'd0, src[15:0]}
              + {16'd0, dst[31:16]} + {16'd0, dst[15:0]};
            s = (s & 32'h0000_FFFF) + (s >> 16);
            s = (s & 32'h0000_FFFF) + (s >> 16);
            ip_cks = ~s[15:0];
        end
    endfunction

    // IP 头校验和也寄存：它由 ip_len / IP 地址做 3 次加法折叠，若和 CRC32
    // 的 8 级链串在同一拍，同样过不了 125 MHz。这里在 S_ARM 里算好寄存。
    reg  [15:0] ipck_r;
    reg  [31:0] ipacc_r;
    wire [31:0] ipck_sum = ipacc_r + {16'd0, host_ip[31:16]} + {16'd0, host_ip[15:0]};
    wire [31:0] ipck_f1  = (ipck_sum & 32'h0000_FFFF) + (ipck_sum >> 16);
    wire [31:0] ipck_f2  = (ipck_f1  & 32'h0000_FFFF) + (ipck_f1  >> 16);

    //-------------------------------------------------------------------------
    //  帧内字节（按 bcnt 出）
    //-------------------------------------------------------------------------
    reg [7:0] fbyte;
    always @(*) begin
        fbyte = 8'h00;
        if (bcnt <= 16'd5)                        fbyte = b48(host_mac, bcnt[3:0]);
        else if (bcnt <= 16'd11)                  fbyte = b48(my_mac,   (bcnt - 16'd6));
        else if (bcnt == 16'd12)                  fbyte = 8'h08;
        else if (bcnt == 16'd13)                  fbyte = 8'h00;
        // IP
        else if (bcnt == 16'd14)                  fbyte = 8'h45;
        else if (bcnt == 16'd15)                  fbyte = 8'h00;
        else if (bcnt == 16'd16)                  fbyte = ip_len[15:8];
        else if (bcnt == 16'd17)                  fbyte = ip_len[7:0];
        else if (bcnt == 16'd18)                  fbyte = 8'h00;
        else if (bcnt == 16'd19)                  fbyte = pkt_seq[7:0];
        else if (bcnt == 16'd20)                  fbyte = 8'h40;   // DF
        else if (bcnt == 16'd21)                  fbyte = 8'h00;
        else if (bcnt == 16'd22)                  fbyte = 8'h40;   // TTL 64
        else if (bcnt == 16'd23)                  fbyte = 8'h11;   // UDP
        else if (bcnt == 16'd24)                  fbyte = ipck_r[15:8];
        else if (bcnt == 16'd25)                  fbyte = ipck_r[7:0];
        else if (bcnt == 16'd26)                  fbyte = b32(my_ip,   4'd0);
        else if (bcnt == 16'd27)                  fbyte = b32(my_ip,   4'd1);
        else if (bcnt == 16'd28)                  fbyte = b32(my_ip,   4'd2);
        else if (bcnt == 16'd29)                  fbyte = b32(my_ip,   4'd3);
        else if (bcnt == 16'd30)                  fbyte = b32(host_ip, 4'd0);
        else if (bcnt == 16'd31)                  fbyte = b32(host_ip, 4'd1);
        else if (bcnt == 16'd32)                  fbyte = b32(host_ip, 4'd2);
        else if (bcnt == 16'd33)                  fbyte = b32(host_ip, 4'd3);
        // UDP
        else if (bcnt == 16'd34)                  fbyte = SRC_PORT[15:8];
        else if (bcnt == 16'd35)                  fbyte = SRC_PORT[7:0];
        else if (bcnt == 16'd36)                  fbyte = udp_port[15:8];
        else if (bcnt == 16'd37)                  fbyte = udp_port[7:0];
        else if (bcnt == 16'd38)                  fbyte = udp_len[15:8];
        else if (bcnt == 16'd39)                  fbyte = udp_len[7:0];
        else if (bcnt == 16'd40)                  fbyte = 8'h00;
        else if (bcnt == 16'd41)                  fbyte = 8'h00;
        // 应用头 16 B
        else if (bcnt == 16'd42)                  fbyte = 8'hE7;
        else if (bcnt == 16'd43)                  fbyte = 8'h5A;
        else if (bcnt == 16'd44)                  fbyte = {7'd0, is_last};
        else if (bcnt == 16'd45)                  fbyte = {6'd0, dec_log2};
        else if (bcnt == 16'd46)                  fbyte = pkt_seq[7:0];
        else if (bcnt == 16'd47)                  fbyte = pkt_seq[15:8];
        else if (bcnt == 16'd48)                  fbyte = pkt_first[7:0];
        else if (bcnt == 16'd49)                  fbyte = pkt_first[15:8];
        else if (bcnt <= 16'd57)                  fbyte = 8'h00;
        // 样点：s 低/高、c 低/高（小端 int16）
        else begin
            case (kpos)
            2'd0: fbyte = cur_word[7:0];
            2'd1: fbyte = cur_word[15:8];
            2'd2: fbyte = cur_word[23:16];
            default: fbyte = cur_word[31:24];
            endcase
        end
    end

    // 组合输出：MAC 在 tx_ready 的同一拍取走 fbyte。
    // （寄存器版会在"最后一字节"的那一拍里既置 1 又清 0，导致末字节永远丢失。）
    assign tx_valid = (st == S_EMIT);
    assign tx_data  = fbyte;
    assign tx_last  = (st == S_EMIT) && (bcnt == (frm_len - 16'd1));

    //-------------------------------------------------------------------------
    //  125 MHz 主状态机
    //-------------------------------------------------------------------------
    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            st          <= S_IDLE;
            rd_v_d      <= 1'b0;
            cur_word    <= 32'd0;
            nxt_word    <= 32'd0;
            have_cur    <= 1'b0;
            have_nxt    <= 1'b0;
            pf_req      <= 1'b0;
            fifo_rd_r   <= 1'b0;
            pkt_remain  <= 16'd0;
            pkt_samples <= 16'd0;
            pkt_first   <= 16'd0;
            frm_len_r   <= 16'd58;
            ip_len_r    <= 16'd44;
            udp_len_r   <= 16'd24;
            is_last_r   <= 1'b0;
            pkt_seq     <= 16'd0;
            bcnt        <= 16'd0;
            busy        <= 1'b0;
            done        <= 1'b0;
            pkt_cnt     <= 16'd0;
            drop_cnt    <= 16'd0;
            start_s1 <= 1'b0; start_s2 <= 1'b0; start_d <= 1'b0;
            abort_s1 <= 1'b0; abort_s2 <= 1'b0; abort_d <= 1'b0;
            abort_pending <= 1'b0;
        end else begin
            done     <= 1'b0;

            // 跨域：start_tgl → 125 域
            start_s1 <= start_tgl;
            start_s2 <= start_s1;
            start_d  <= start_s2;

            // abort 边沿 → 挂起位（粘滞到 FSM 处理）
            abort_s1 <= abort_tgl;
            abort_s2 <= abort_s1;
            abort_d  <= abort_s2;
            if (abort_s2 != abort_d) abort_pending <= 1'b1;

            //-----------------------------------------------------------------
            //  双缓冲预取：FIFO 读 1 拍命令 + 1 拍数据
            //-----------------------------------------------------------------
            fifo_rd_r <= 1'b0;
            rd_v_d    <= fifo_rd_r;
            if (rd_v_d) begin
                nxt_word <= fifo_dout[31:0];
                have_nxt <= 1'b1;
            end
            if (pf_req && rd_v_d) pf_req <= 1'b0;
            // 下一个字还没到、也没有在途请求 → 发一个读命令
            if (!have_nxt && !pf_req && !fifo_empty) begin
                fifo_rd_r <= 1'b1;
                pf_req    <= 1'b1;
            end
            // 当前字用掉后，把预取字顶上
            if (!have_cur && have_nxt) begin
                cur_word <= nxt_word;
                have_cur <= 1'b1;
                have_nxt <= 1'b0;
            end

            case (st)
            //-----------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (abort_pending) begin
                    abort_pending <= 1'b0;
                    st            <= S_ABORT;
                end else if (start_s2 != start_d) begin
                    pkt_remain <= npts_sync;
                    pkt_seq    <= 16'd0;
                    pkt_first  <= 16'd0;
                    pkt_cnt    <= 16'd0;
                    // ★ 新一窗必须从"没有预取"开始：上一次 abort 可能在
                    //   have_cur/have_nxt 里留下半个旧样点。
                    have_cur   <= 1'b0;
                    have_nxt   <= 1'b0;
                    pf_req     <= 1'b0;
                    busy       <= 1'b1;
                    st         <= S_ARM;
                end
            end
            //-----------------------------------------------------------------
            S_ARM: begin
                if (abort_pending) begin
                    abort_pending <= 1'b0;
                    st            <= S_ABORT;
                end else if (tx_hold) begin
                    st <= S_ARM;
                end else if (pkt_remain == 16'd0) begin
                    st <= S_DONE;
                end else if (have_cur) begin
                    pkt_samples <= nxt_n;
                    frm_len_r   <= 16'd58 + {nxt_n[13:0], 2'b00};
                    ip_len_r    <= 16'd44 + {nxt_n[13:0], 2'b00};
                    udp_len_r   <= 16'd24 + {nxt_n[13:0], 2'b00};
                    is_last_r   <= (pkt_remain <= MAX_PTS_C);
                    bcnt        <= 16'd0;
                    st          <= S_PRE;
                end
            end
            //-----------------------------------------------------------------
            //  校验和单独一拍：它要 3 次 32 bit 折叠，和"比较 + 移位加"串在
            //  同一拍会打穿 125 MHz（−3.2 ns）。这里拆成两级流水。
            //-----------------------------------------------------------------
            S_PRE: begin
                // 第一级：只把与 ip_len / 本机 IP 有关的部分加起来（4 个 16 bit 加法）
                // ★ 必须和 S_EMIT 实发的头逐字对齐（bcnt 18..23）：
                //   18/19 = IP ID = {0x00, pkt_seq[7:0]}、20/21 = 0x4000(DF)、
                //   22/23 = 0x4011(TTL 64/UDP)。原来漏了 ID 和 DF、还把 0x4011
                //   写成 0x4001，每个 UDP 包的 IP 校验和都是错的，主机会全丢。
                ipacc_r <= 32'h0000_4500 + {16'd0, ip_len_r}
                         + {16'd0, pkt_seq[7:0]}
                         + 32'h0000_4000
                         + 32'h0000_4011
                         + {16'd0, my_ip[31:16]} + {16'd0, my_ip[15:0]};
                st      <= S_PRE2;
            end
            //-----------------------------------------------------------------
            //  第二级：再叠目的 IP 的两个字并折叠两次（折叠本身也有 2 级）
            //  拆成两拍后这条路径从 −0.14 ns 变成正裕量。
            //-----------------------------------------------------------------
            S_PRE2: begin
                ipck_r <= ~ipck_f2[15:0];
                st     <= S_EMIT;
            end
            //-----------------------------------------------------------------
            S_EMIT: begin
                if (tx_ready) begin
                    if (bcnt == (frm_len - 16'd1)) begin
                        pkt_remain<= pkt_remain - pkt_samples;
                        pkt_seq   <= pkt_seq + 16'd1;
                        pkt_cnt   <= pkt_cnt + 16'd1;
                        // 首个样点下标用累加，而不是 pkt_seq * MAX_PTS：
                        // 乘法（乘常数 350）是一条 14 级 CARRY4 的长组合链，
                        // 会把 125 MHz 的建立时间打穿（见 docs/17 §B2-3）。
                        pkt_first <= pkt_first + pkt_samples;
                        // 帧尾那一字节走的是这个分支，不会经过下面的 kpos 逻辑，
                        // 所以这里也要把预取字顶上来，否则每帧丢一个样点。
                        cur_word <= nxt_word;
                        have_nxt <= 1'b0;
                        if (!have_nxt) have_cur <= 1'b0;
                        // 帧边界是唯一安全的 abort 点：帧中间切换会让 MAC 发出残帧
                        if (abort_pending) begin
                            abort_pending <= 1'b0;
                            st            <= S_ABORT;
                        end else begin
                            st            <= S_ARM;
                        end
                    end else begin
                        bcnt <= bcnt + 16'd1;
                        // 一个样点 4 字节发完 → 立刻把预取字顶上来
                        // （下一拍的 bcnt 已经指向新样点的首字节，不能晚一拍）
                        if ((bcnt >= 16'd58) && (kpos == 2'd3)) begin
                            cur_word <= nxt_word;
                            have_nxt <= 1'b0;
                            if (!have_nxt) begin
                                have_cur <= 1'b0;
                                drop_cnt <= drop_cnt + 16'd1;
                            end
                        end
                    end
                end
            end
            //-----------------------------------------------------------------
            //  abort：把 FIFO 读空再回 IDLE。
            //  不冲 FIFO 的话，abort 时残留的 ~500 个旧样点会出现在下一次
            //  抓包的开头（而且 drop 计数看不出来）。最多 512 拍 = 4 µs。
            //-----------------------------------------------------------------
            S_ABORT: begin
                busy      <= 1'b0;
                pf_req    <= 1'b0;
                have_cur  <= 1'b0;
                have_nxt  <= 1'b0;
                if (!fifo_empty) begin
                    fifo_rd_r <= 1'b1;
                end else if (!rd_v_d && !fifo_rd_r) begin
                    st <= S_IDLE;
                end
            end
            //-----------------------------------------------------------------
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
