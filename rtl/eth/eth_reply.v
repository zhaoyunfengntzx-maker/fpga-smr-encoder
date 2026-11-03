//=============================================================================
//  eth_reply.v —— 最小协议栈：ARP 应答 + ICMP echo 应答 + 主机 MAC 学习
//-----------------------------------------------------------------------------
//  为什么只做这两样（B2 范围）：
//    · ARP 必须有：PC 发包前要先问 "192.168.1.10 的 MAC 是多少"，不回就
//      连 ping 都发不出去。
//    · ICMP echo 是"链路通了没有"的最短验证路径（ping 一下就知道 RGMII/
//      时钟/CRC 全对没有），比写上位机还快。
//    · UDP 接收（改 IP/端口）不做：配置走串口，少一条状态机少一堆边界。
//
//  数据通路：eth_rx_mac 的字节流 → 本模块缓存 → 按需生成应答帧字节 →
//  eth_tx_mac。全部在 125 MHz 单时钟域，RX 侧只经过一个异步 FIFO。
//
//  校验和：
//    · IP 头 20 字节固定，用组合逻辑一次算完（9 个 16 bit 字相加）；
//    · ICMP 校验和依赖 payload，先用一个 FSM 逐字累加（每拍 2 字节），
//      算完再开始发 —— 帧短（<=128 B），最多 64 拍，不影响手感。
//=============================================================================

`timescale 1ns / 1ps

module eth_reply (
    input  wire        clk,
    input  wire        rst_n,

    // ---- RX 字节流（eth_rx_mac 输出，经异步 FIFO 后每拍一个字节）----
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,        // 本拍有字节（含 eof 标记拍）
    input  wire        rx_sof,          // ★ 本拍是本帧第一个字节（帧起点对齐）
    input  wire        rx_eof,          // 本拍是帧尾标记（此时 rx_data 无效）
    input  wire        rx_err,          // 本帧 CRC/长度错

    // ---- RX 反压：只有 S_IDLE 才能收字节（★ 2026-10-28 新增）----
    output wire        rx_ready,

    // ---- 发送让路：UDP 正在发帧时为高，本模块丢弃当前请求 ----
    input  wire        tx_hold,

    // ---- 本机配置 ----
    input  wire [47:0] my_mac,
    input  wire [31:0] my_ip,

    // ---- TX 字节流（到 eth_tx_mac）----
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output reg         busy,

    // ---- 学到的对端信息 / 统计 ----
    output reg  [47:0] host_mac,
    output reg  [31:0] host_ip,
    output reg         arp_seen,        // 1 拍：回了一帧 ARP
    output reg         icmp_seen,       // 1 拍：回了一帧 ICMP
    output reg         rx_bad_pulse     // 1 拍：收到坏帧（给计数器用）
);

    //-------------------------------------------------------------------------
    //  字节选择小函数（Verilog-2001 没有变量部分选择）
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

    //-------------------------------------------------------------------------
    //  RX 缓存与解析
    //-------------------------------------------------------------------------
    reg  [7:0]  fbuf [0:127];
    reg  [7:0]  bcnt;                // 本帧已收字节数（饱和到 127）
    reg  [7:0]  blen;                // 上一帧长度（饱和）
    reg  [7:0]  idx;    reg  [7:0]  rlen;                // 应答帧长度
    reg  [1:0]  kind;                // 0=无 1=ARP 2=ICMP
    reg  [2:0]  st;

    localparam [2:0] S_IDLE = 3'd0,
                     S_DEC  = 3'd1,
                     S_PRE  = 3'd2,
                     S_CKS  = 3'd3,
                     S_EMIT = 3'd4;

    reg [7:0]  cks_i;
    reg [31:0] cks_sum;
    reg [15:0] icksum;
    reg [15:0] ipcksum;
    reg [15:0] tot_len;
    // ICMP 应答要用的 4 个 16 bit 字（ident/src/dst）先在 S_DEC 拍寄存，
    // 免得 ip_cks 的加法链直接挂在 fbuf 的 LUTRAM 读出上（−1.1 ns）。
    reg [15:0] w_id;
    // ★ 目的 IP 是 32 bit：原来写成 reg [15:0] 只留下低 16 位，
    //   IP 头校验和少加 0xC0A8（host=192.168.1.100），每个 ICMP 应答都被
    //   主机的 IP 层当"校验和错"丢掉 —— ping 永远不通。
    reg [31:0] w_dst;

    // 32 位部分和折叠到 16 位（两次 + 回卷）
    wire [31:0] fold1 = cks_sum[31:16] + cks_sum[15:0];
    wire [16:0] fold2 = fold1[15:0] + {16'd0, fold1[16]};

    // IP 头校验和分两拍算：
    //   S_DEC 先把与 fbuf 无关的部分（版本/长度/ID/标志/本机 IP）累加成 ipacc_r；
    //   S_PRE 再加两个目的地址字并折叠。
    //   一次性组合算（8 个 16 bit 加法 + 两次折叠）在 125 MHz 下 −0.79 ns，
    //   而且会把同步后的 my_ip 寄存器直接拽进关键路径。
    reg [31:0] ipacc_r;
    wire [31:0] ipacc_sum = ipacc_r + {16'd0, w_dst[31:16]} + {16'd0, w_dst[15:0]};
    wire [31:0] ipacc_f1  = (ipacc_sum & 32'h0000_FFFF) + (ipacc_sum >> 16);
    wire [31:0] ipacc_f2  = (ipacc_f1  & 32'h0000_FFFF) + (ipacc_f1  >> 16);

    //-------------------------------------------------------------------------
    //  应答内容组装（组合，按 idx 出字节）
    //-------------------------------------------------------------------------
    reg [7:0] gbyte;
    always @(*) begin
        gbyte = 8'h00;
        if (kind == 2'd1) begin
            //---------------- ARP reply（42 B）----------------
            if (idx <= 8'd5)        gbyte = b48(host_mac, idx[3:0]);
            else if (idx <= 8'd11)  gbyte = b48(my_mac,   (idx - 8'd6));
            else if (idx == 8'd12)  gbyte = 8'h08;
            else if (idx == 8'd13)  gbyte = 8'h06;
            else if (idx == 8'd14)  gbyte = 8'h00;
            else if (idx == 8'd15)  gbyte = 8'h01;   // Ethernet
            else if (idx == 8'd16)  gbyte = 8'h08;   // IPv4
            else if (idx == 8'd17)  gbyte = 8'h00;
            else if (idx == 8'd18)  gbyte = 8'h06;   // hlen
            else if (idx == 8'd19)  gbyte = 8'h04;   // plen
            else if (idx == 8'd20)  gbyte = 8'h00;
            else if (idx == 8'd21)  gbyte = 8'h02;   // reply
            else if (idx <= 8'd27)  gbyte = b48(my_mac,   (idx - 8'd22));
            else if (idx <= 8'd31)  gbyte = b32(my_ip,    (idx - 8'd28));
            else if (idx <= 8'd37)  gbyte = b48(host_mac, (idx - 8'd32));
            else if (idx <= 8'd41)  gbyte = b32(host_ip,  (idx - 8'd38));
            else                    gbyte = 8'h00;   // 补齐到 60 B 最小帧
        end else if (kind == 2'd2) begin
            //---------------- ICMP echo reply（长度 = 请求长度）----------------
            if (idx <= 8'd5)        gbyte = b48(host_mac, idx[3:0]);
            else if (idx <= 8'd11)  gbyte = b48(my_mac,   (idx - 8'd6));
            else if (idx == 8'd12)  gbyte = 8'h08;
            else if (idx == 8'd13)  gbyte = 8'h00;
            else if (idx == 8'd14)  gbyte = 8'h45;
            else if (idx == 8'd15)  gbyte = 8'h00;
            else if (idx == 8'd16)  gbyte = tot_len[15:8];
            else if (idx == 8'd17)  gbyte = tot_len[7:0];
            else if (idx == 8'd18)  gbyte = fbuf[18];
            else if (idx == 8'd19)  gbyte = fbuf[19];
            else if (idx == 8'd20)  gbyte = 8'h00;
            else if (idx == 8'd21)  gbyte = 8'h00;
            else if (idx == 8'd22)  gbyte = 8'h40;   // TTL 64
            else if (idx == 8'd23)  gbyte = 8'h01;   // ICMP
            else if (idx == 8'd24)  gbyte = ipcksum[15:8];
            else if (idx == 8'd25)  gbyte = ipcksum[7:0];
            else if (idx == 8'd26)  gbyte = b32(my_ip,   4'd0);
            else if (idx == 8'd27)  gbyte = b32(my_ip,   4'd1);
            else if (idx == 8'd28)  gbyte = b32(my_ip,   4'd2);
            else if (idx == 8'd29)  gbyte = b32(my_ip,   4'd3);
            else if (idx == 8'd30)  gbyte = b32(host_ip, 4'd0);
            else if (idx == 8'd31)  gbyte = b32(host_ip, 4'd1);
            else if (idx == 8'd32)  gbyte = b32(host_ip, 4'd2);
            else if (idx == 8'd33)  gbyte = b32(host_ip, 4'd3);
            else if (idx == 8'd34)  gbyte = 8'h00;   // echo reply
            else if (idx == 8'd35)  gbyte = 8'h00;
            else if (idx == 8'd36)  gbyte = icksum[15:8];
            else if (idx == 8'd37)  gbyte = icksum[7:0];
            else if (idx < blen)    gbyte = fbuf[idx]; // id/seq + payload 原样回
            else                    gbyte = 8'h00;   // 补齐到 60 B 最小帧
        end
    end

    // 组合输出（与 scope_udp 同理：寄存器版会丢掉最后一字节）
    assign tx_valid = (st == S_EMIT);
    assign tx_data  = gbyte;
    assign tx_last  = (st == S_EMIT) && (idx == (rlen - 8'd1));

    // ★ 2026-10-28：S_IDLE 是唯一能接收 RX 字节的状态，用它反压 RX FIFO，
    //   避免"处理上一帧期间到达的字节被读走丢弃"。
    assign rx_ready = (st == S_IDLE);

    //-------------------------------------------------------------------------
    //  主状态机
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            bcnt      <= 8'd0;
            blen      <= 8'd0;
            idx       <= 8'd0;
            rlen      <= 8'd0;
            kind      <= 2'd0;
            cks_i     <= 8'd0;
            cks_sum   <= 32'd0;
            icksum    <= 16'd0;
            ipcksum   <= 16'd0;
            tot_len   <= 16'd0;
            busy      <= 1'b0;
            host_mac  <= 48'hFF_FF_FF_FF_FF_FF;
            host_ip   <= 32'd0;
            arp_seen  <= 1'b0;
            icmp_seen <= 1'b0;
            rx_bad_pulse <= 1'b0;
        end else begin
            arp_seen  <= 1'b0;
            icmp_seen <= 1'b0;
            rx_bad_pulse <= 1'b0;

            case (st)
            //-----------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (rx_valid) begin
                    if (rx_eof) begin
                        blen <= rx_sof ? 8'd0 : bcnt;
                        bcnt <= 8'd0;
                        // UDP 正在发帧时丢弃本次请求：ARP/ICMP 由主机重试，
                        // 比在帧中间切换发送源安全得多。
                        // （2026-10-28：eth_top 已把 tx_hold 恒置 0，改为排队等
                        //   帧级 grant，所以正常路径不会再走到这里丢弃。）
                        st   <= tx_hold ? S_IDLE : S_DEC;
                        if (rx_err) rx_bad_pulse <= 1'b1;
                    end else if (rx_sof) begin
                        // ★ 2026-10-28：帧起点对齐。上一帧可能被丢弃或截断，
                        //   没有 sof 时 bcnt 会从中间接着数，导致整帧解析错位。
                        fbuf[8'd0] <= rx_data;
                        bcnt       <= 8'd1;
                    end else begin
                        if (bcnt < 8'd127) fbuf[bcnt] <= rx_data;
                        bcnt <= (bcnt < 8'd127) ? (bcnt + 8'd1) : 8'd127;
                    end
                end
            end
            //-----------------------------------------------------------------
            //  识别：只认"发给我们"的 ARP 请求与 ICMP echo 请求
            S_DEC: begin
                kind <= 2'd0;
                // ★ 2026-10-28：host_mac 的**学习条件收紧**。
                //   原来"任何帧都学"，链路上任何设备的广播帧（别的 PC 的 ARP）
                //   都会把 host_mac 污染成别人的地址；而 eth_top 的 host_known
                //   一旦置位永不清零 ⇒ 换 PC/换网口后板子的 UDP 打向旧 MAC，
                //   表现为"串口正常、抓包一个包都收不到"。
                //   现在只在**发给本机**的 ARP 请求 / ICMP echo 请求里学。

                //---------------- ARP request for my_ip ----------------
                if (blen >= 8'd42 &&
                    fbuf[12] == 8'h08 && fbuf[13] == 8'h06 &&
                    fbuf[20] == 8'h00 && fbuf[21] == 8'h01 &&
                    fbuf[38] == my_ip[31:24] && fbuf[39] == my_ip[23:16] &&
                    fbuf[40] == my_ip[15:8]  && fbuf[41] == my_ip[7:0]) begin
                    kind    <= 2'd1;
                    if (blen >= 8'd12)
                        host_mac <= {fbuf[6], fbuf[7], fbuf[8], fbuf[9], fbuf[10], fbuf[11]};
                    // ★ 42 B 的 ARP 应答是 runt，网卡/交换机会直接丢；
                    //   补 0 到以太网最小帧 60 B（不含 FCS）。
                    rlen    <= 8'd60;
                    host_ip <= {fbuf[28], fbuf[29], fbuf[30], fbuf[31]};
                    idx     <= 8'd0;
                    st      <= S_EMIT;
                //---------------- ICMP echo request ----------------
                end else if (blen >= 8'd42 &&
                    fbuf[12] == 8'h08 && fbuf[13] == 8'h00 &&
                    fbuf[23] == 8'h01 && fbuf[34] == 8'h08 &&
                    fbuf[30] == my_ip[31:24] && fbuf[31] == my_ip[23:16] &&
                    fbuf[32] == my_ip[15:8]  && fbuf[33] == my_ip[7:0]) begin
                    kind    <= 2'd2;
                    if (blen >= 8'd12)
                        host_mac <= {fbuf[6], fbuf[7], fbuf[8], fbuf[9], fbuf[10], fbuf[11]};
                    rlen    <= (blen < 8'd60) ? 8'd60 : blen;   // 同样补到最小帧
                    tot_len <= {8'd0, blen} - 16'd14;
                    host_ip <= {fbuf[26], fbuf[27], fbuf[28], fbuf[29]};
                    ipacc_r <= 32'h0000_4500
                             + {16'd0, ({8'd0, blen} - 16'd14)}
                             + {16'd0, fbuf[18], fbuf[19]}
                             + 32'h0000_4001
                             + {16'd0, my_ip[31:16]} + {16'd0, my_ip[15:0]};
                    w_id    <= {fbuf[18], fbuf[19]};
                    // ★ 目的地址 = 请求的**源** IP（fbuf[26..29]）；原来取的是
                    //   fbuf[30..33]（= 本机 IP），于是校验和把本机地址加了
                    //   两遍、主机的漏掉 → 每个 ICMP 应答的 IP 校验和恒差
                    //   0x005A（192.168.1.10 与 .100 的两个字之差），主机全丢。
                    w_dst   <= {fbuf[26], fbuf[27], fbuf[28], fbuf[29]};
                    // ★ ICMP 校验和从 38 起算（跳过 type/code/checksum 三字）：
                    //   应答的 type 是 0x00，而请求是 0x08；原来从 34 起把 0x0800
                    //   算进去、还把请求自己的校验和字段也加进和里，结果恒定错
                    //   0x0800（实际算出来常常是 0x0000）—— 所有 ping 应答被丢。
                    cks_i   <= 8'd38;
                    cks_sum <= 32'd0;
                    // IP 校验和单独一拍算：它由 blen 做多次 16 bit 折叠，
                    // 若和 S_DEC 的字节比较串在同一拍，125 MHz 差 −1.9 ns。
                    st      <= S_PRE;
                end else begin
                    st <= S_IDLE;
                end
            end
            //-----------------------------------------------------------------
            //  单独一拍：IP 头校验和（输入都已寄存）
            //-----------------------------------------------------------------
            S_PRE: begin
                ipcksum <= ~ipacc_f2[15:0];
                st      <= S_CKS;
            end
            //-----------------------------------------------------------------
            //  ICMP 校验和：每拍加 2 字节
            S_CKS: begin
                if (cks_i + 8'd1 < blen) begin
                    cks_sum <= cks_sum + ({24'd0, fbuf[cks_i]} << 8)
                                        + {24'd0, fbuf[cks_i + 8'd1]};
                    cks_i   <= cks_i + 8'd2;
                end else if (cks_i < blen) begin
                    cks_sum <= cks_sum + ({24'd0, fbuf[cks_i]} << 8);
                    cks_i   <= cks_i + 8'd1;
                end else begin
                    icksum <= ~fold2[15:0];
                    idx    <= 8'd0;
                    st     <= S_EMIT;
                end
            end
            //-----------------------------------------------------------------
            S_EMIT: begin
                busy     <= 1'b1;
                if (tx_ready) begin
                    if (idx == (rlen - 8'd1)) begin
                        st       <= S_IDLE;
                        if (kind == 2'd1) arp_seen  <= 1'b1;
                        if (kind == 2'd2) icmp_seen <= 1'b1;
                    end else begin
                        idx <= idx + 8'd1;
                    end
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
