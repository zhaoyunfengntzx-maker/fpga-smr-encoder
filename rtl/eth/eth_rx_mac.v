//=============================================================================
//  eth_rx_mac.v —— 以太网 RX MAC：SFD 对齐 / 去前导码 / CRC32 校验 / 去 FCS
//-----------------------------------------------------------------------------
//  输入是 rgmii_if 出来的 125 MHz GMII 字节流，输出是"从 DA 第一个字节开始、
//  到 payload 最后一个字节结束"的干净帧（不含前导码、不含 4 字节 FCS）。
//
//  两个关键处理：
//    · SFD 对齐：上电/丢包后不知道字节边界，靠连续 0x55 后跟 0xD5 重新对齐。
//    · 去 FCS：以太网 FCS 是"整帧（含 FCS）CRC 余数 = 0x2144DF1C"。所以不能
//      边收边发 —— 必须把数据压后 4 个字节发，帧结束时最后 4 个字节正好在
//      管道里，直接丢掉；此时正在发的那一字节才是 payload 末尾（打 rx_eof）。
//
//  输出协议：rx_valid/rx_data 逐字节，首字节带 rx_sof，末字节带 rx_eof；
//  帧尾若 rx_err 为 1（CRC 错/超短帧），消费方应整帧丢弃。
//=============================================================================

`timescale 1ns / 1ps

module eth_rx_mac (
    input  wire        clk,
    input  wire        rst_n,

    // ---- GMII ----
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_err,

    // ---- 字节流输出 ----
    output reg         rx_valid,
    output reg  [7:0]  rx_data,
    output reg         rx_sof,
    output reg         rx_eof,
    output reg         rx_err,
    output reg  [15:0] rx_len,       // 上一帧长度（不含 FCS）
    output reg         rx_done       // 1 拍：一帧结束
);

    // ---- CRC32（与 TX 同参数）----
    function [31:0] crc32_byte;
        input [31:0] c_in;
        input [7:0]  d;
        integer k;
        reg [31:0] c;
        begin
            c = c_in ^ {24'd0, d};
            for (k = 0; k < 8; k = k + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    localparam [31:0] CRC_RESIDUE = 32'h2144_DF1C;

    reg [2:0]  pre_cnt;          // 已连续收到的 0x55 个数
    reg        in_frame;
    reg [31:0] crc;
    reg [15:0] cnt;              // 本帧已收字节数（含 FCS）
    reg [7:0]  pipe0, pipe1, pipe2, pipe3;   // 4 字节延迟管道

    always @(posedge clk) begin
        if (!rst_n) begin
            pre_cnt  <= 3'd0;
            in_frame <= 1'b0;
            crc      <= 32'hFFFF_FFFF;
            cnt      <= 16'd0;
            pipe0 <= 8'h00; pipe1 <= 8'h00; pipe2 <= 8'h00; pipe3 <= 8'h00;
            rx_valid <= 1'b0; rx_data <= 8'h00;
            rx_sof   <= 1'b0; rx_eof  <= 1'b0; rx_err <= 1'b0;
            rx_len   <= 16'd0; rx_done <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            rx_sof   <= 1'b0;
            rx_eof   <= 1'b0;
            rx_done  <= 1'b0;

            if (!in_frame) begin
                //---------------- 找 SFD ----------------
                if (gmii_rx_dv) begin
                    if (gmii_rxd == 8'h55 && pre_cnt < 3'd7) begin
                        pre_cnt <= pre_cnt + 3'd1;
                    end else if (gmii_rxd == 8'hD5 && pre_cnt >= 3'd5) begin
                        in_frame <= 1'b1;
                        pre_cnt  <= 3'd0;
                        crc      <= 32'hFFFF_FFFF;
                        cnt      <= 16'd0;
                        pipe0 <= 8'h00; pipe1 <= 8'h00;
                        pipe2 <= 8'h00; pipe3 <= 8'h00;
                    end else begin
                        pre_cnt <= 3'd0;
                    end
                end else begin
                    pre_cnt <= 3'd0;
                end
            end else begin
                //---------------- 收帧 ----------------
                if (gmii_rx_dv) begin
                    crc  <= crc32_byte(crc, gmii_rxd);
                    cnt  <= cnt + 16'd1;

                    // 4 字节流水：新字节进 pipe0，pipe3 是最早的
                    pipe0 <= gmii_rxd;
                    pipe1 <= pipe0;
                    pipe2 <= pipe1;
                    pipe3 <= pipe2;

                    // 收满 4 字节后才开始输出（前 4 字节还在管道里）
                    if (cnt >= 16'd4) begin
                        rx_valid <= 1'b1;
                        rx_data  <= pipe3;
                        rx_sof   <= (cnt == 16'd4);
                    end
                end else begin
                    //---------------- 帧结束 ----------------
                    in_frame <= 1'b0;
                    cnt      <= 16'd0;
                    rx_done  <= 1'b1;

                    // 此时 pipe0..pipe3 是最后 4 字节（FCS），不发；
                    // 上一拍已发出的字节就是 payload 末字节 → 打 eof。
                    rx_eof <= 1'b1;
                    rx_len <= (cnt >= 16'd4) ? (cnt - 16'd4) : 16'd0;
                    rx_err <= (gmii_rx_err || crc != CRC_RESIDUE || cnt < 16'd18);
                end
            end
        end
    end

endmodule
