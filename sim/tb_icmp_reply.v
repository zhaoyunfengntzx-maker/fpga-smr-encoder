`timescale 1ns / 1ps
//=============================================================================
//  tb_icmp_reply.v —— eth_reply 的 ICMP echo 应答"线上字节"检查
//
//  背景：上板 ping 不通，但 ARP 应答正常（PC 学到了板子 MAC）、UDP 抓包正常。
//  说明 TX 通路与 ARP 帧没问题，问题只可能在 ICMP 应答的 IP/ICMP 头里。
//  这个测试台不喂"抽象请求"，而是喂一帧和 Windows ping 完全同构的 74 B 请求
//  （14 ETH + 20 IP + 8 ICMP + 32 数据），再把应答逐字节抓下来自己算校验和。
//
//  判据（全部按 RFC 1071 的"和为 0xFFFF"形式）：
//    · 应答长度 74、MAC/类型/IP 版本/长度/ID/TTL/协议 逐字段正确
//    · IP 头 10 个 16 bit 字之和 == 0xFFFF
//    · ICMP 消息（从 type 到 payload 末）16 bit 字之和 == 0xFFFF
//    · payload 与请求逐字节相同、icmp_seen 出过一拍
//=============================================================================
module tb_icmp_reply;

    reg clk = 0;
    always #4 clk = ~clk;

    reg         rst_n = 0;
    reg  [7:0]  rx_data = 0;
    reg         rx_valid = 0;
    reg         rx_eof = 0;
    reg         rx_sof = 0;      // 帧起点标记（eth_reply 新增端口）
    reg         rx_err = 0;
    reg         tx_hold = 0;
    reg         tx_ready = 1;

    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_last;
    wire        busy;
    wire [47:0] host_mac;
    wire [31:0] host_ip;
    wire        arp_seen, icmp_seen, rx_bad;

    localparam [47:0] MY_MAC   = 48'h02_00_00_00_00_01;
    localparam [31:0] MY_IP    = 32'hC0A8_010A;      // 192.168.1.10
    localparam [47:0] HOST_MAC = 48'h00_11_22_33_44_55;
    localparam [31:0] HOST_IP  = 32'hC0A8_0164;      // 192.168.1.100

    integer errors = 0;
    integer checks = 0;

    task chk;
        input        cond;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("[FAIL] %0s", name);
            end
        end
    endtask

    eth_reply u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .rx_eof     (rx_eof),
        .rx_sof     (rx_sof),
        .rx_err     (rx_err),
        .tx_hold    (tx_hold),
        .my_mac     (MY_MAC),
        .my_ip      (MY_IP),
        .tx_data    (tx_data),
        .tx_valid   (tx_valid),
        .tx_last    (tx_last),
        .tx_ready   (tx_ready),
        .busy       (busy),
        .host_mac   (host_mac),
        .host_ip    (host_ip),
        .arp_seen   (arp_seen),
        .icmp_seen  (icmp_seen),
        .rx_bad_pulse (rx_bad)
    );

    //-------------------------------------------------------------------------
    //  请求帧：74 B，与 Windows `ping -l 32` 同构
    //-------------------------------------------------------------------------
    reg [7:0] req [0:73];
    reg [7:0] rep [0:255];
    integer rep_len = 0;
    reg       saw_icmp = 0;

    integer i;
    reg [31:0] acc;
    reg [15:0] ck;

    initial begin
        // --- Ethernet ---
        req[0]=8'h02; req[1]=8'h00; req[2]=8'h00; req[3]=8'h00; req[4]=8'h00; req[5]=8'h01;
        req[6]=8'h00; req[7]=8'h11; req[8]=8'h22; req[9]=8'h33; req[10]=8'h44; req[11]=8'h55;
        req[12]=8'h08; req[13]=8'h00;
        // --- IPv4（20 B）---
        req[14]=8'h45; req[15]=8'h00;
        req[16]=8'h00; req[17]=8'h3C;          // total length = 60
        req[18]=8'h1A; req[19]=8'h2B;          // id
        req[20]=8'h40; req[21]=8'h00;          // DF
        req[22]=8'h40; req[23]=8'h01;          // TTL 64, ICMP
        req[24]=8'h00; req[25]=8'h00;          // checksum 占位
        req[26]=8'hC0; req[27]=8'hA8; req[28]=8'h01; req[29]=8'h64;
        req[30]=8'hC0; req[31]=8'hA8; req[32]=8'h01; req[33]=8'h0A;
        // --- ICMP（8 B 头 + 32 B 数据）---
        req[34]=8'h08; req[35]=8'h00;
        req[36]=8'h00; req[37]=8'h00;
        req[38]=8'h00; req[39]=8'h04;          // ident
        req[40]=8'h00; req[41]=8'h01;          // seq
        for (i = 0; i < 32; i = i + 1)
            req[42 + i] = 8'h61 + (i % 23);     // a..w 循环

        // IP 头校验和
        acc = 0;
        for (i = 14; i < 34; i = i + 2)
            acc = acc + {req[i], req[i+1]};
        acc = (acc & 32'hFFFF) + (acc >> 16);
        acc = (acc & 32'hFFFF) + (acc >> 16);
        ck  = ~acc[15:0];
        req[24] = ck[15:8];
        req[25] = ck[7:0];

        // ICMP 校验和
        acc = 0;
        for (i = 34; i < 74; i = i + 2)
            acc = acc + {req[i], req[i+1]};
        acc = (acc & 32'hFFFF) + (acc >> 16);
        acc = (acc & 32'hFFFF) + (acc >> 16);
        ck  = ~acc[15:0];
        req[36] = ck[15:8];
        req[37] = ck[7:0];
    end

    //-------------------------------------------------------------------------
    //  逐字节送入（rx_valid 连续拉高，最后一拍 rx_eof）
    //-------------------------------------------------------------------------
    initial begin
        rst_n = 0;
        repeat (8) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        for (i = 0; i < 74; i = i + 1) begin
            rx_data  = req[i];
            rx_valid = 1;
            rx_eof   = 0;
            rx_sof   = (i == 0);        // 只有第一个字节是帧起点
            @(negedge clk);
        end
        rx_sof   = 0;
        rx_data  = 8'h00;
        rx_valid = 1;
        rx_eof   = 1;
        @(negedge clk);
        rx_valid = 0;
        rx_eof   = 0;
    end

    //-------------------------------------------------------------------------
    //  抓应答字节
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && tx_valid) begin
            rep[rep_len] = tx_data;
            rep_len = rep_len + 1;
            if (tx_last) begin
                // 交给下面的检查
            end
        end
        if (rst_n && icmp_seen) saw_icmp <= 1'b1;
    end

    //-------------------------------------------------------------------------
    //  检查
    //-------------------------------------------------------------------------
    reg [15:0] sum;
    integer j;
    initial begin
        wait (rst_n == 1'b1);
        // 最长等 5000 拍（应答 74 B，S_CKS 18 拍 + S_EMIT 74 拍）
        for (j = 0; j < 5000 && !(rep_len >= 74); j = j + 1)
            @(posedge clk);
        repeat (20) @(posedge clk);

        $display("---- ICMP echo reply ----");
        $display("rep_len = %0d", rep_len);

        begin : show_hdr
            integer q;
            for (q = 0; q < 36; q = q + 1) $write("%02X ", rep[q]);
            $write("\n");
        end
        chk(rep_len == 74, "R1 应答长度 = 74");
        chk(saw_icmp,      "R2 icmp_seen 出过脉冲");

        chk(rep[0]==8'h00 && rep[1]==8'h11 && rep[2]==8'h22 &&
            rep[3]==8'h33 && rep[4]==8'h44 && rep[5]==8'h55, "R3 目的 MAC = 主机 MAC");
        chk(rep[6]==8'h02 && rep[7]==8'h00 && rep[8]==8'h00 &&
            rep[9]==8'h00 && rep[10]==8'h00 && rep[11]==8'h01, "R4 源 MAC = 板子 MAC");
        chk(rep[12]==8'h08 && rep[13]==8'h00, "R5 EtherType = 0800");
        chk(rep[14]==8'h45, "R6 IP 版本/IHL = 0x45");
        chk(rep[16]==8'h00 && rep[17]==8'h3C, "R7 IP total length = 60");
        chk(rep[18]==8'h1A && rep[19]==8'h2B, "R8 IP ID 沿用请求");
        chk(rep[20]==8'h00 && rep[21]==8'h00, "R9 flags/frag = 0");
        chk(rep[22]==8'h40 && rep[23]==8'h01, "R10 TTL/proto = 64/1");
        chk(rep[26]==8'hC0 && rep[27]==8'hA8 && rep[28]==8'h01 && rep[29]==8'h0A,
            "R11 源 IP = 192.168.1.10");
        chk(rep[30]==8'hC0 && rep[31]==8'hA8 && rep[32]==8'h01 && rep[33]==8'h64,
            "R12 目的 IP = 192.168.1.100");
        chk(rep[34]==8'h00 && rep[35]==8'h00, "R13 ICMP type/code = 0/0");
        chk(rep[38]==8'h00 && rep[39]==8'h04 && rep[40]==8'h00 && rep[41]==8'h01,
            "R14 ICMP ident/seq 沿用请求");

        // IP 头校验和
        sum = 16'h0000;
        for (j = 14; j < 34; j = j + 2) begin
            acc = sum + {rep[j], rep[j+1]};
            acc = (acc & 32'hFFFF) + (acc >> 16);
            sum = acc[15:0];
        end
        $display("IP 头 16 bit 字之和 = 0x%04X（应为 0xFFFF）", sum);
        chk(sum == 16'hFFFF, "R15 IP 头校验和");

        // ICMP 消息校验和
        sum = 16'h0000;
        for (j = 34; j < 74; j = j + 2) begin
            acc = sum + {rep[j], rep[j+1]};
            acc = (acc & 32'hFFFF) + (acc >> 16);
            sum = acc[15:0];
        end
        $display("ICMP 16 bit 字之和 = 0x%04X（应为 0xFFFF）", sum);
        chk(sum == 16'hFFFF, "R16 ICMP 校验和");

        // payload 原样回
        for (j = 42; j < 74; j = j + 1)
            chk(rep[j] == req[j], "R17 payload 逐字节相同");

        $display("checks = %0d, errors = %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end

endmodule
