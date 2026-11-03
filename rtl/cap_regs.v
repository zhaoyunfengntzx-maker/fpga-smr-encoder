//=============================================================================
//  cap_regs.v —— 0x0700 段抓包寄存器组（B1 第三级）
//-----------------------------------------------------------------------------
//  为什么单独一个模块：
//    reg_file.v 已经有 500+ 行、60 多个端口，再塞进抓包控制会把"寄存器解码"
//    和"抓包时序"耦在一起。这里用一个 8 bit 从口（ext_we/ext_addr/ext_wdata）
//    挂到 reg_file 的 0x0700 段，抓包相关的全部状态都在本文件里。
//-----------------------------------------------------------------------------
//  地址排布（**每个寄存器 16 bit 对齐、占 2 个字节地址**）：
//    这是被 spi_slave 的 32 位包格式逼出来的——一次 16 bit 写会在 addr 和
//    addr+1 各产生一个 8 bit 写脉冲（见 rtl/spi_slave.v:244-251）。如果按
//    8 bit/字段紧凑排布，写 0x0708 的高字节会踩掉 0x0709 的邻居。
//
//    0x0700/01  MAC[15:0]        0x0702/03  MAC[31:16]
//    0x0704/05  IP[15:0]         0x0706/07  IP[31:16]
//    0x0708/09  HOST_IP[15:0]    0x070A/0B  HOST_IP[31:16]
//    0x070C/0D  PORT             0x070E/0F  CTRL
//    0x0710/11  ETH_STATUS       0x0712/13  TX_PKT
//    0x0714/15  TX_DROP          0x0716/17  RX_PKT
//    0x0718/19  CAP_SRC          [0]源(0=原始50M,1=校正12.5M) [2:1]抽取log2(0..3)
//    0x071A/1B  CAP_LEN          窗口点数（默认 28672）
//    0x071C/1D  TRIG_CFG         [1:0] 0=立即 1=上升沿 2=下降沿
//    0x071E/1F  TRIG_LEVEL       有符号触发门限
//    0x0720/21  PRE              预触发点数
//    0x0722/23  CAP_CTRL         [0]arm(写1启动) [1]abort
//    0x0724/25  CAP_STATUS       [0]done [1]armed [2]trig [3]busy [4]ovf
//    0x0726/27  TRIG_IDX         触发点在窗口内的下标
//    0x0728/29  SAMP_LO          50 MHz 样点计数[15:0]
//    0x072A/2B  SAMP_HI          样点计数[31:16]
//    0x072C/2D  BUILD            RTL 版本（0x000D）
//    0x072E/2F  DUMP_CTRL        [0]start [1]abort
//    0x0730/31  DUMP_STATUS      [0]busy [1]done [15:8]已发块数低 8 位
//    0x0732/33  CAP_LEN_EFF      实际窗口点数（被 DEPTH 截断后的值）
//    0x0734/35  BLOCKS_DONE      已发块数（16 bit）
//    0x0736/37  UDP_CTRL         [0]start（整窗 UDP 推送）[1]abort
//    0x0738/39  UDP_STATUS       [0]busy [1]done [2]host_mac 已学到
//    0x073A/3B  UDP_PKTS         本窗已发 UDP 包数
//    0x073C/3D  UDP_DROP         发送侧队列饥饿次数
//    0x0750/51  RX_CLK_CNT       RXC 域时钟计数（诊断：RXC 在不在跳）
//    0x0752/53  RX_DV_CNT        RXDV 上升沿个数（收到几帧）
//    0x0754/55  RX_BYTE_CNT      RXDV 有效字节数
//    0x0756/57  RX_ERR_CNT       收帧错误数
//    0x0758/59  IDELAY_TAP       [4:0] 写 tap 并装载；读回 [5]=idelay_rdy
//
//  ETH_STATUS（0x0710）：[0] 收到过 ARP [1] 回过 ICMP [2] host_mac 已知
//  TX_PKT/TX_DROP/RX_PKT：以太网帧计数（16 bit 饱和）
//
//  脉冲约定：
//    arm / abort / dump_start / dump_abort 都是"写 1 触发一个 clk 脉冲"，
//    读完自然是 0；上位机不需要写 0 去清除。
//=============================================================================

`timescale 1ns / 1ps

module cap_regs (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 来自 reg_file 的 8 bit 扩展口 ----
    input  wire [15:0] addr,          // 保证 addr[15:8]==0x07 才会来
    input  wire        we,            // 1 拍脉冲
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,         // 组合读

    // ---- 抓包引擎控制 ----
    output reg         arm,
    output reg         abort,
    output reg  [1:0]  dec_log2,
    output reg  [15:0] cap_len,
    output reg  [1:0]  trig_mode,
    output reg  [15:0] trig_level,
    output reg  [15:0] pre_len,
    output reg         src_sel,

    // ---- 抓包引擎回读 ----
    input  wire [15:0] cap_start,
    input  wire [15:0] cap_len_eff,
    input  wire [15:0] trig_idx,
    input  wire [31:0] sample_cnt,
    input  wire        st_armed,
    input  wire        st_done,
    input  wire        st_trig,
    input  wire        st_busy,
    input  wire        st_ovf,

    // ---- dump 控制/回读 ----
    output reg         dump_start,
    output reg         dump_abort,
    input  wire        dump_busy,
    input  wire        dump_done,
    input  wire [15:0] blocks_done,

    // ---- 以太网（B2）配置输出 ----
    output wire [31:0] eth_mac,
    output wire [31:0] eth_ip,
    output wire [31:0] eth_host_ip,
    output wire [15:0] eth_port,
    output reg         stream_en,
    output reg  [2:0]  stream_dec,
    output wire [15:0] eth_ctrl_o,
    output reg         udp_start,
    output reg         udp_abort,
    // ---- 以太网状态回读 ----
    input  wire [15:0] eth_tx_pkt,
    input  wire [15:0] eth_tx_drop,
    input  wire [15:0] eth_rx_pkt,
    input  wire        eth_arp_ok,
    input  wire        eth_icmp_ok,
    input  wire        eth_host_known,
    input  wire        udp_busy,
    input  wire        udp_done,
    input  wire [15:0] udp_pkts,
    input  wire [15:0] udp_drop,
    input  wire        stream_run,
    input  wire        stream_ovf,
    input  wire [31:0] stream_pkts,
    input  wire [31:0] stream_drop,
    input  wire [15:0] stream_lag,

    // ---- RX 采样延时（IDELAYE2 VAR_LOAD）----
    output reg  [4:0]  eth_idelay_val,
    output reg         eth_idelay_ld,
    input  wire        eth_idelay_rdy,
    output reg         eth_rx_swap,        // 0x0758 bit6：IDDR 半字节顺序翻转
    // ---- RX 调试计数器回读 ----
    input  wire [15:0] eth_rx_clk_cnt,
    input  wire [15:0] eth_rx_dv_cnt,
    input  wire [15:0] eth_rx_byte_cnt,
    input  wire [15:0] eth_rx_err_cnt,
    input  wire [31:0] eth_rx_dbg,        // 每帧第 5..8 字节快照
    input  wire [15:0] eth_tx_dbg_frm,    // TX 上一帧字节数
    input  wire [15:0] eth_tx_dbg_len,    // TX 线上 IP 总长
    input  wire [15:0] eth_tx_dbg_port,   // TX 线上 UDP 目的端口
    input  wire [15:0] eth_tx_dbg_mac0,
    input  wire [15:0] eth_tx_dbg_mac1,
    input  wire [15:0] eth_tx_dbg_ck,
    input  wire [15:0] eth_tx_dbg_dip0,
    input  wire [15:0] eth_tx_dbg_dip1
);

    //-------------------------------------------------------------------------
    //  存储寄存器
    //-------------------------------------------------------------------------
    reg [31:0] mac;
    reg [31:0] ip;
    reg [31:0] host_ip;
    reg [15:0] port;
    reg [15:0] eth_ctrl;

    assign eth_mac     = mac;
    assign eth_ip      = ip;
    assign eth_host_ip = host_ip;
    assign eth_port    = port;
    assign eth_ctrl_o  = eth_ctrl;

    //-------------------------------------------------------------------------
    //  写
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            mac        <= 32'h0200_0001;        // B2 再扩成 48 位，B1 只占位
            ip         <= 32'hC0_A8_01_0A;      // 192.168.1.10（B2 用，B1 只存不使能）
            host_ip    <= 32'hC0_A8_01_64;      // 192.168.1.100
            port       <= 16'd5000;
            eth_ctrl   <= 16'h0000;
            arm        <= 1'b0;
            abort      <= 1'b0;
            dec_log2   <= 2'd1;                 // 默认抽取 2 → 25 MSPS
            cap_len    <= 16'd28672;            // 默认整窗 28672 点（= 28 个 RAMB36，见 scope_capture 分 bank 注释）
            trig_mode  <= 2'd0;                 // 默认立即触发
            trig_level <= 16'sd0;
            pre_len    <= 16'd1024;
            src_sel    <= 1'b0;                 // 默认原始 50 MSPS
            dump_start <= 1'b0;
            dump_abort <= 1'b0;
            udp_start  <= 1'b0;
            udp_abort  <= 1'b0;
            stream_en  <= 1'b0;
            stream_dec <= 3'd2;
            eth_idelay_val <= 5'd0;
            eth_idelay_ld  <= 1'b0;
            eth_rx_swap    <= 1'b0;
        end else begin
            // 脉冲默认清零
            arm        <= 1'b0;
            abort      <= 1'b0;
            dump_start <= 1'b0;
            dump_abort <= 1'b0;
            udp_start  <= 1'b0;
            udp_abort  <= 1'b0;
            eth_idelay_ld <= 1'b0;

            if (we) begin
                case (addr[7:1])
                //---------------- MAC ----------------
                7'd0: if (!addr[0]) mac[7:0]   <= wdata;
                      else          mac[15:8]  <= wdata;
                7'd1: if (!addr[0]) mac[23:16] <= wdata;
                      else          mac[31:24] <= wdata;
                //---------------- IP -----------------
                7'd2: if (!addr[0]) ip[7:0]    <= wdata;
                      else          ip[15:8]   <= wdata;
                7'd3: if (!addr[0]) ip[23:16]  <= wdata;
                      else          ip[31:24]  <= wdata;
                //---------------- HOST IP ------------
                7'd4: if (!addr[0]) host_ip[7:0]   <= wdata;
                      else          host_ip[15:8]  <= wdata;
                7'd5: if (!addr[0]) host_ip[23:16] <= wdata;
                      else          host_ip[31:24] <= wdata;
                //---------------- 端口 / 控制 ---------
                7'd6: if (!addr[0]) port[7:0]      <= wdata;
                      else          port[15:8]     <= wdata;
                7'd7: if (!addr[0]) eth_ctrl[7:0]  <= wdata;
                      else          eth_ctrl[15:8] <= wdata;
                //---------------- 抓包 ----------------
                7'd12: if (!addr[0]) begin
                           src_sel  <= wdata[0];
                           dec_log2 <= wdata[2:1];
                       end
                7'd13: if (!addr[0]) cap_len[7:0]      <= wdata;
                       else          cap_len[15:8]     <= wdata;
                7'd14: if (!addr[0]) trig_mode         <= wdata[1:0];
                7'd15: if (!addr[0]) trig_level[7:0]   <= wdata;
                       else          trig_level[15:8]  <= wdata;
                7'd16: if (!addr[0]) pre_len[7:0]      <= wdata;
                       else          pre_len[15:8]     <= wdata;
                7'd17: if (!addr[0]) begin
                           arm   <= wdata[0];
                           abort <= wdata[1];
                       end
                //---------------- dump -----------------
                7'd23: if (!addr[0]) begin
                           dump_start <= wdata[0];
                           dump_abort <= wdata[1];
                       end
                //---------------- UDP 推送 ---------------
                7'd27: if (!addr[0]) begin
                           udp_start <= wdata[0];
                           udp_abort <= wdata[1];
                       end
                7'd32: if (!addr[0]) stream_en  <= wdata[0];
                7'd33: if (!addr[0]) stream_dec <= wdata[2:0];
                //---------------- RX 采样延时 -------------
                7'd44: if (!addr[0]) begin
                           eth_idelay_val <= wdata[4:0];
                           eth_rx_swap    <= wdata[6];
                           eth_idelay_ld  <= 1'b1;
                       end
                default: ;
                endcase
            end
        end
    end

    //-------------------------------------------------------------------------
    //  读（组合）。addr[0]=0 取低字节，=1 取高字节。
    //-------------------------------------------------------------------------
    always @(*) begin
        rdata = 8'h00;
        case (addr[7:1])
        7'd0:  rdata = addr[0] ? mac[15:8]      : mac[7:0];
        7'd1:  rdata = addr[0] ? mac[31:24]     : mac[23:16];
        7'd2:  rdata = addr[0] ? ip[15:8]       : ip[7:0];
        7'd3:  rdata = addr[0] ? ip[31:24]      : ip[23:16];
        7'd4:  rdata = addr[0] ? host_ip[15:8]  : host_ip[7:0];
        7'd5:  rdata = addr[0] ? host_ip[31:24] : host_ip[23:16];
        7'd6:  rdata = addr[0] ? port[15:8]     : port[7:0];
        7'd7:  rdata = addr[0] ? eth_ctrl[15:8] : eth_ctrl[7:0];
        7'd8:  rdata = addr[0] ? 8'h00
                               : {5'd0, eth_host_known, eth_icmp_ok, eth_arp_ok};
        7'd9:  rdata = addr[0] ? eth_tx_pkt[15:8] : eth_tx_pkt[7:0];
        7'd10: rdata = addr[0] ? eth_tx_drop[15:8] : eth_tx_drop[7:0];
        7'd11: rdata = addr[0] ? eth_rx_pkt[15:8] : eth_rx_pkt[7:0];
        7'd12: rdata = addr[0] ? 8'h00 : {5'd0, dec_log2, src_sel};
        7'd13: rdata = addr[0] ? cap_len[15:8]  : cap_len[7:0];
        7'd14: rdata = {6'd0, trig_mode};
        7'd15: rdata = addr[0] ? trig_level[15:8] : trig_level[7:0];
        7'd16: rdata = addr[0] ? pre_len[15:8]    : pre_len[7:0];
        7'd17: rdata = 8'h00;
        7'd18: rdata = {3'd0, st_ovf, st_busy, st_trig, st_armed, st_done};
        7'd19: rdata = addr[0] ? trig_idx[15:8]   : trig_idx[7:0];
        7'd20: rdata = addr[0] ? sample_cnt[15:8] : sample_cnt[7:0];
        7'd21: rdata = addr[0] ? sample_cnt[31:24]: sample_cnt[23:16];
        7'd22: rdata = addr[0] ? 8'h00 : 8'h0D;   // BUILD = 0x000D
        7'd23: rdata = 8'h00;
        7'd24: rdata = addr[0] ? blocks_done[15:8]
                               : {6'b00_0000, dump_done, dump_busy};
        7'd25: rdata = addr[0] ? cap_len_eff[15:8] : cap_len_eff[7:0];
        7'd26: rdata = addr[0] ? blocks_done[15:8] : blocks_done[7:0];
        7'd27: rdata = 8'h00;
        7'd28: rdata = addr[0] ? 8'h00
                               : {5'd0, eth_host_known, udp_done, udp_busy};
        7'd29: rdata = addr[0] ? udp_pkts[15:8] : udp_pkts[7:0];
        7'd30: rdata = addr[0] ? udp_drop[15:8] : udp_drop[7:0];
        7'd32: rdata = addr[0] ? 8'h00 : {7'd0, stream_en};
        7'd33: rdata = addr[0] ? 8'h00 : {5'd0, stream_dec};
        7'd34: rdata = addr[0] ? 8'h00
                               : {5'd0, stream_ovf, stream_run, stream_en};
        7'd35: rdata = addr[0] ? stream_pkts[15:8]  : stream_pkts[7:0];
        7'd36: rdata = addr[0] ? stream_pkts[31:24] : stream_pkts[23:16];
        7'd37: rdata = addr[0] ? stream_drop[15:8]  : stream_drop[7:0];
        7'd38: rdata = addr[0] ? stream_drop[31:24] : stream_drop[23:16];
        7'd39: rdata = addr[0] ? stream_lag[15:8]   : stream_lag[7:0];
        7'd40: rdata = addr[0] ? eth_rx_clk_cnt[15:8]  : eth_rx_clk_cnt[7:0];
        7'd41: rdata = addr[0] ? eth_rx_dv_cnt[15:8]   : eth_rx_dv_cnt[7:0];
        7'd42: rdata = addr[0] ? eth_rx_byte_cnt[15:8] : eth_rx_byte_cnt[7:0];
        7'd43: rdata = addr[0] ? eth_rx_err_cnt[15:8]  : eth_rx_err_cnt[7:0];
        7'd44: rdata = addr[0] ? 8'h00 : {2'd0, eth_idelay_rdy, eth_idelay_val};
        7'd45: rdata = addr[0] ? eth_rx_dbg[15:8]  : eth_rx_dbg[7:0];
        7'd46: rdata = addr[0] ? eth_rx_dbg[31:24] : eth_rx_dbg[23:16];
        7'd48: rdata = addr[0] ? eth_tx_dbg_frm[15:8]  : eth_tx_dbg_frm[7:0];
        7'd49: rdata = addr[0] ? eth_tx_dbg_len[15:8]  : eth_tx_dbg_len[7:0];
        7'd50: rdata = addr[0] ? eth_tx_dbg_port[15:8] : eth_tx_dbg_port[7:0];
        7'd51: rdata = addr[0] ? eth_tx_dbg_mac0[15:8] : eth_tx_dbg_mac0[7:0];
        7'd52: rdata = addr[0] ? eth_tx_dbg_mac1[15:8] : eth_tx_dbg_mac1[7:0];
        7'd53: rdata = addr[0] ? eth_tx_dbg_ck[15:8]   : eth_tx_dbg_ck[7:0];
        7'd54: rdata = addr[0] ? eth_tx_dbg_dip0[15:8] : eth_tx_dbg_dip0[7:0];
        7'd55: rdata = addr[0] ? eth_tx_dbg_dip1[15:8] : eth_tx_dbg_dip1[7:0];
        default: rdata = 8'h00;
        endcase
    end

endmodule
