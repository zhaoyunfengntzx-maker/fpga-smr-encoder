//=============================================================================
//  stream_tx.v —— 连续流发送（二期）
//-----------------------------------------------------------------------------
//  为什么需要它：
//    scope_udp 是"抓一窗 → 停 → 一次性推 N 个包 → 结束"，本质是一次性回读。
//    连续流要的是：ADC 一直在采、网口一直在发、主机滚动显示、永不结束。
//    两者包格式完全相同（主机复用同一个解析器），只多一个 flags.bit1 标志。
//-----------------------------------------------------------------------------
//  数据通路：
//    50 MHz 侧：追 wr_ptr 读 BRAM（scope_capture 的读口）→ {idx, s, c} → 异步 FIFO
//   125 MHz 侧：从 FIFO 取样本 → 42 B 头 + 4 B/样本 → eth_tx_mac
//
//  三个关键设计决定：
//    1) **读侧永远追不上写侧**，所以用"落后多少"做流控而不是握手：
//       unread > DEPTH/2 就把 rd_ptr 直接跳到 wr_ptr（丢样点并记账），
//       主机从 64 bit 绝对序号的跳变就能知道"这里少了 N 个点"，不会画出假波形。
//    2) **包内不断流**：FIFO 里攒够 MAX_PTS+32 个样本才开始发一包，
//       这样 1500 B 的帧不会发到一半卡住（以太网帧不能有洞）。
//    3) 绝对序号 **64 bit**：低位 32 bit 跟着样点穿过 FIFO，高位在 125 MHz 侧
//       靠"低位回绕"检测累加（@12.5 MSPS 回绕约 5.7 min，必须处理）。
//
//  吞吐：50 MHz 侧读一个样本要 2 拍（读延迟 1 拍 + FIFO 写 1 拍）= 25 MSPS 上限，
//        125 MHz 侧每样本 5~6 拍 = 20~25 MSPS，因此**连续流要求 dec_log2 ≥ 1**
//        （即 ≤25 MSPS）；实践中推荐 dec_log2=2（12.5 MSPS / 400 Mbps）。
//=============================================================================

`timescale 1ns / 1ps

module stream_tx #(
    parameter integer DEPTH    = 28672,    // 必须与 scope_capture 一致（非 2 的幂，回绕用显式比较）
    parameter integer MAX_PTS  = 350,      // 每包样点数（1500 B MTU）
    parameter integer SRC_PORT = 5000
)(
    // ---- 50 MHz 侧（样本源 = scope_capture 的读口）----
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,
    input  wire [2:0]         dec_log2,
    input  wire [15:0]        wr_ptr,
    output wire [15:0]        rd_addr,
    output wire               rd_en,
    input  wire [31:0]        rd_data,
    output reg  [31:0]        drop_samples,

    // ---- 125 MHz 侧（发到 eth_tx_mac）----
    input  wire               clk_125,
    input  wire               rst_n_125,
    input  wire [47:0]        my_mac,
    input  wire [47:0]        host_mac,
    input  wire [31:0]        my_ip,
    input  wire [31:0]        host_ip,
    input  wire [15:0]        udp_port,
    output wire [7:0]         tx_data,
    output wire               tx_valid,
    output wire               tx_last,
    input  wire               tx_ready,
    output wire               tx_busy,

    output reg  [31:0]        pkts,
    output wire               fifo_ovf,
    output reg  [31:0]        underflow,
    output wire [15:0]        lag
);

    //=========================================================================
    //  跨域 FIFO：{idx_lo[31:0], s[15:0], c[15:0]}
    //=========================================================================
    wire        fifo_full, fifo_empty;
    wire [8:0]  fifo_rd_level;      // async_fifo 的 rd_level 是 AW+1 = 9 bit
    wire [63:0] fifo_din, fifo_dout;
    reg         fifo_wr_en;
    wire        fifo_rd;

    async_fifo #(.DW(64), .AW(8), .ALMOST(32)) u_fifo (
        .wr_clk(clk), .wr_rst_n(rst_n),
        .wr_en(fifo_wr_en), .din(fifo_din), .full(fifo_full),
        .almost_full(), .wr_level(),
        .rd_clk(clk_125), .rd_rst_n(rst_n_125),
        .rd_en(fifo_rd), .dout(fifo_dout), .empty(fifo_empty),
        .rd_level(fifo_rd_level)
    );

    //=========================================================================
    //  50 MHz 侧：追赶读（2 拍一个样本）
    //=========================================================================
    localparam [15:0] DEPTH_C = DEPTH;
    localparam [15:0] HALF    = DEPTH_C >> 1;

    reg  [15:0] rd_ptr;
    reg  [31:0] rd_idx, rd_idx_q;
    reg         rd_pend;

    // ★ DEPTH=28672 不是 2 的幂：wr_ptr 从 28671 回绕到 0 的那一下，
    //   16 位模减 `wr_ptr - rd_ptr` = 0 - 28270 = 37266，会被当成 overrun，
    //   于是每绕一圈就整段丢弃（rd_ptr 跳 wr_ptr、drop_samples 暴涨）。
    //   环形缓冲的"已用字数"必须显式算：(wr-rd) 或 (DEPTH-rd+wr)。
    wire [15:0] unread  = (wr_ptr >= rd_ptr) ? (wr_ptr - rd_ptr)
                                             : (DEPTH_C - rd_ptr + wr_ptr);
    wire        overrun = (unread > HALF);
    wire        can_rd  = en && !rd_pend && !fifo_full && (unread != 16'd0) && !overrun;

    assign rd_addr  = rd_ptr;
    assign rd_en    = can_rd;
    assign fifo_din = {rd_idx_q, rd_data};
    assign fifo_ovf = (unread > (DEPTH_C - 16'd8));
    assign lag      = unread;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr       <= 16'd0;
            rd_idx       <= 32'd0;
            rd_idx_q     <= 32'd0;
            rd_pend      <= 1'b0;
            fifo_wr_en   <= 1'b0;
            drop_samples <= 32'd0;
        end else if (!en) begin
            rd_ptr     <= wr_ptr;                 // 停流时对齐，避免下次启动读到旧数据
            rd_idx     <= rd_idx + unread;
            rd_pend    <= 1'b0;
            fifo_wr_en <= 1'b0;
        end else begin
            fifo_wr_en <= 1'b0;

            if (rd_pend) begin                    // 上一拍发出的读，数据这拍有效
                rd_pend    <= 1'b0;
                fifo_wr_en <= 1'b1;
            end

            if (can_rd) begin
                rd_pend  <= 1'b1;
                rd_idx_q <= rd_idx;
                rd_idx   <= rd_idx + 32'd1;
                rd_ptr   <= (rd_ptr == DEPTH_C - 16'd1) ? 16'd0 : (rd_ptr + 16'd1);
            end

            // 写侧追上来了：整段丢弃，序号跟着跳（主机能看出来）
            if (overrun) begin
                rd_ptr       <= wr_ptr;
                rd_idx       <= rd_idx + unread;
                drop_samples <= drop_samples + {16'd0, unread};
                rd_pend      <= 1'b0;
            end
        end
    end

    //=========================================================================
    //  125 MHz 侧：组包
    //=========================================================================
    // ★ 上板缺陷 #32：原来每发一个采样点都要绕一次 S_NEXT（tx_valid=0 一拍），
    //   eth_tx_mac 的“断流补 0”逻辑会把这些空隙填成 0 字节，线上帧长 1369 B
    //   而 IP 头写 844 B，Windows 在 IP 层整包丢弃（网卡计数在涨、socket 收不到）。
    //   现在改成：先把整包 MAX_PTS 个点收进 pbuf，再连续发 58 B 头 + 800 B 载荷，
    //   帧内 tx_valid 一直接住，帧长与 IP 总长严格相等。
    localparam [2:0] S_IDLE = 3'd0,   // 等 FIFO 攒够
                     S_HDR  = 3'd1,   // 发 58 B 头
                     S_DATA = 3'd2,   // 连续发 pbuf 里的 MAX_PTS 个点
                     S_FILL = 3'd5;   // 先把整包样本收进 pbuf

    reg  [2:0]  st;
    reg         fetch;            // 请求一次 FIFO 读（1 拍）
    reg         rd_v;             // 上一拍的请求已生效（fifo_dout 有效）

    reg  [7:0]  bcnt;
    reg  [15:0] scnt;
    reg  [1:0]  kpos;
    reg  [63:0] cur;
    reg  [31:0] pbuf [0:MAX_PTS-1];   // 整包样本缓冲（发送阶段连续读）
    reg  [15:0] fill;                 // 已收进 pbuf 的点数
    reg  [31:0] pkt_first_lo, pkt_first_hi;
    reg  [31:0] hi_q, last_lo;
    reg  [15:0] seq;


    assign tx_busy = (st != S_IDLE);

    assign fifo_rd = fetch;

    // 攒够一包才开帧：MAX_PTS + 32 个样本
    wire [8:0]  need_pts = MAX_PTS[8:0] + 9'd32;
    wire        start_ok = en && (fifo_rd_level >= need_pts);

    // ---- IP / UDP 长度 ----
    // ★ 长度必须把 16 B 的流头算进去（与 scope_udp 的 24/44 口径一致）：
    //   udp_len = 8(UDP) + 16(流头) + n*4，ip_len = 20 + udp_len。
    //   原来写成 8 + n*4，IP 总长比实际少 16 B —— 主机按 IP 长度截断后
    //   UDP 长度 > 可用负载，Windows 直接丢包（网卡计数在涨、socket 收不到），
    //   而且 MAC 只发 14+ip_len 字节，每包最后 4 个样点被截掉。
    wire [15:0] udp_len = 16'd24 + MAX_PTS[15:0] * 16'd4;
    wire [15:0] ip_len  = 16'd44 + MAX_PTS[15:0] * 16'd4;

    // ---- IP 头校验和：两拍折叠（与 scope_udp 同一套做法） ----
    reg  [31:0] ipacc_r;
    reg  [15:0] ipck_r;
    wire [31:0] ipck_sum = ipacc_r + {16'd0, host_ip[31:16]} + {16'd0, host_ip[15:0]};
    wire [31:0] ipck_f1  = (ipck_sum & 32'h0000_FFFF) + (ipck_sum >> 16);
    wire [31:0] ipck_f2  = (ipck_f1  & 32'h0000_FFFF) + (ipck_f1  >> 16);

    // ---- 头字节 ----
    reg [7:0] fbyte;
    always @(*) begin
        case (bcnt)
            8'd0:  fbyte = host_mac[47:40];      // 目的 MAC = 主机（学自 ARP/ICMP）
            8'd1:  fbyte = host_mac[39:32];      // ★ 原来发广播 FF:FF:FF:FF:FF:FF，
            8'd2:  fbyte = host_mac[31:24];      //   实测 PC 网卡收到字节（~690 Mbps）
            8'd3:  fbyte = host_mac[23:16];      //   但 socket 一个包都收不到；
            8'd4:  fbyte = host_mac[15:8];       //   scope_udp 用 host_mac 就能收。
            8'd5:  fbyte = host_mac[7:0];
            8'd6:  fbyte = my_mac[47:40];
            8'd7:  fbyte = my_mac[39:32];
            8'd8:  fbyte = my_mac[31:24];
            8'd9:  fbyte = my_mac[23:16];
            8'd10: fbyte = my_mac[15:8];
            8'd11: fbyte = my_mac[7:0];
            8'd12: fbyte = 8'h08;                 // IPv4
            8'd13: fbyte = 8'h00;
            8'd14: fbyte = 8'h45;
            8'd15: fbyte = 8'h00;
            8'd16: fbyte = ip_len[15:8];
            8'd17: fbyte = ip_len[7:0];
            8'd18: fbyte = 8'h00;                 // ID 固定 0（不分片）
            8'd19: fbyte = 8'h00;
            8'd20: fbyte = 8'h40;                 // DF
            8'd21: fbyte = 8'h00;
            8'd22: fbyte = 8'h40;                 // TTL 64
            8'd23: fbyte = 8'h11;                 // UDP
            8'd24: fbyte = ipck_r[15:8];
            8'd25: fbyte = ipck_r[7:0];
            8'd26: fbyte = my_ip[31:24];
            8'd27: fbyte = my_ip[23:16];
            8'd28: fbyte = my_ip[15:8];
            8'd29: fbyte = my_ip[7:0];
            8'd30: fbyte = host_ip[31:24];
            8'd31: fbyte = host_ip[23:16];
            8'd32: fbyte = host_ip[15:8];
            8'd33: fbyte = host_ip[7:0];
            // ★ 上板缺陷 #33：UDP 头的第 0/1 字节是“源端口”，2/3 字节才是
            //   “目的端口”。原来把 udp_port 写在 34/35（源端口位）、把常量
            //   SRC_PORT 写在 36/37（目的端口位），于是每个流包都发到主机的
            //   5000 端口（被 lkcitdl 吃掉），主机 socket 永远收不到。
            //   pktmon 抓包实证：192.168.1.10.47234 > 192.168.1.100.5000。
            8'd34: fbyte = SRC_PORT[15:8];
            8'd35: fbyte = SRC_PORT[7:0];
            8'd36: fbyte = udp_port[15:8];
            8'd37: fbyte = udp_port[7:0];
            8'd38: fbyte = udp_len[15:8];
            8'd39: fbyte = udp_len[7:0];
            8'd40: fbyte = 8'h00;                 // UDP 校验和 = 0（IPv4 允许）
            8'd41: fbyte = 8'h00;
            8'd42: fbyte = 8'hE7;                 // 魔数
            8'd43: fbyte = 8'h5A;
            8'd44: fbyte = 8'h02;                 // flags: bit1 = 连续流
            8'd45: fbyte = {5'd0, dec_log2};
            8'd46: fbyte = seq[7:0];             // ★ 小端，与 scope_udp 一致
            8'd47: fbyte = seq[15:8];            //   （原实现先发高字节，host 按
            8'd48: fbyte = pkt_first_lo[7:0];    //    "包格式与 scope_udp 完全一致"
            8'd49: fbyte = pkt_first_lo[15:8];   //    解析，first 会被字节反转，
            8'd50: fbyte = pkt_first_lo[23:16];  //    环形缓冲写到错位置）
            8'd51: fbyte = pkt_first_lo[31:24];
            8'd52: fbyte = pkt_first_hi[7:0];
            8'd53: fbyte = pkt_first_hi[15:8];
            8'd54: fbyte = pkt_first_hi[23:16];
            8'd55: fbyte = pkt_first_hi[31:24];
            8'd56: fbyte = 8'h00;
            8'd57: fbyte = 8'h00;
            default: fbyte = 8'h00;
        endcase
    end

    // 每个点 4 字节 = {s[15:0], c[15:0]} 的小端
    wire [31:0] wdat = pbuf[scnt[7:0]];
    wire [7:0] dbyte = (kpos == 2'd0) ? wdat[7:0]  :
                       (kpos == 2'd1) ? wdat[15:8] :
                       (kpos == 2'd2) ? wdat[23:16]: wdat[31:24];

    assign tx_valid = (st == S_HDR) || (st == S_DATA);
    assign tx_data  = (st == S_HDR) ? fbyte : dbyte;
    assign tx_last  = (st == S_DATA) && (scnt == MAX_PTS[15:0] - 16'd1) && (kpos == 2'd3);

    // FIFO 读出：fetch 的下一拍 fifo_dout 有效
    always @(posedge clk_125) begin
        if (!rst_n_125) rd_v <= 1'b0;
        else            rd_v <= fetch && !fifo_empty;
    end

    always @(posedge clk_125) begin
        if (!rst_n_125) begin
            st           <= S_IDLE;
            fetch        <= 1'b0;
            bcnt         <= 8'd0;
            scnt         <= 16'd0;
            kpos         <= 2'd0;
            fill         <= 16'd0;
            cur          <= 64'd0;
            pkt_first_lo <= 32'd0;
            pkt_first_hi <= 32'd0;
            hi_q         <= 32'd0;
            last_lo      <= 32'd0;
            seq          <= 16'd0;
            pkts         <= 32'd0;
            underflow    <= 32'd0;
            ipacc_r      <= 32'd0;
            ipck_r       <= 16'd0;
        end else begin
            fetch <= 1'b0;

            // 校验和一直滚（只依赖配置，不依赖数据）
            // ★ 与 fbyte 实发的 IP 头逐字对齐：18/19=0x0000（ID）、20/21=0x4000（DF）、
            //   22/23=0x4011（TTL 64/UDP）、26..29=my_ip；原来漏了 DF 与源 IP，
            //   每个连续流包的 IP 校验和都错，主机会全丢。
            ipacc_r <= 32'h0000_4500 + {16'd0, ip_len}
                     + 32'h0000_4000 + 32'h0000_4011
                     + {16'd0, my_ip[31:16]} + {16'd0, my_ip[15:0]};
            ipck_r  <= ~ipck_f2[15:0];

            // 序号高位：低位回绕就借位
            if (rd_v) begin
                if (fifo_dout[63:32] < last_lo) hi_q <= hi_q + 32'd1;
                last_lo <= fifo_dout[63:32];
            end

            case (st)
                //-------------------------------------------------------
                S_IDLE: begin
                    if (start_ok) begin
                        fetch    <= 1'b1;          // 取第一个样本
                        seq      <= seq + 16'd1;
                        bcnt     <= 8'd0;
                        scnt     <= 16'd0;
                        kpos     <= 2'd0;
                        fill     <= 16'd0;
                        st       <= S_FILL;
                    end
                end

                //-------------------------------------------------------
                // 收整包：每拍一个点，先进 pbuf，攒满再发（帧内不断流）
                S_FILL: begin
                    if (rd_v) begin
                        pbuf[fill[7:0]] <= fifo_dout[31:0];
                        if (fill == 16'd0) begin
                            pkt_first_lo <= fifo_dout[63:32];
                            pkt_first_hi <= hi_q + ((fifo_dout[63:32] < last_lo) ? 32'd1 : 32'd0);
                        end
                        fill <= fill + 16'd1;
                        if (fill == MAX_PTS[15:0] - 16'd1) begin
                            bcnt <= 8'd0;
                            st   <= S_HDR;
                        end else begin
                            fetch <= 1'b1;          // 再取下一个点
                        end
                    end else if (fifo_empty) begin
                        underflow <= underflow + 32'd1;
                        if (!fetch) fetch <= 1'b1;
                    end else if (!fetch) begin
                        fetch <= 1'b1;
                    end
                end

                //-------------------------------------------------------
                S_HDR: begin
                    if (tx_ready) begin
                        if (bcnt == 8'd57) begin
                            bcnt <= 8'd0;
                            st   <= S_DATA;
                        end else begin
                            bcnt <= bcnt + 8'd1;
                        end
                    end
                end

                //-------------------------------------------------------
                S_DATA: begin
                    if (tx_ready) begin
                        if (kpos == 2'd3) begin
                            kpos <= 2'd0;
                            if (scnt == MAX_PTS[15:0] - 16'd1) begin
                                pkts <= pkts + 32'd1;
                                st   <= S_IDLE;
                            end else begin
                                scnt <= scnt + 16'd1;   // 下一点，tx_valid 不断流
                            end
                        end else begin
                            kpos <= kpos + 2'd1;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
