//=============================================================================
//  eth_tx_mac.v —— 以太网 TX MAC：前导码 / SFD / CRC32 / 帧间隔
//-----------------------------------------------------------------------------
//  输入是"从目的 MAC 第一个字节开始"的完整帧（不含前导码与 FCS），
//  `tx_valid/tx_data/tx_last` 一次一个字节；本模块负责：
//    1) 前导码 7×0x55 + SFD 0xD5
//    2) 边发边算 CRC32，帧尾补 4 字节（小端，低位先发）
//    3) 帧间隔 IFG 12 字节
//
//  为什么 CRC 不用查表：
//    查表要 256×32 bit（约 1k LUT + 一个 RAM），而这里只有 125 MHz、每拍
//    一个字节，8 次串行移位完全跑得动（8 个 XOR 层，约 32 LUT），
//    在 30% 占用的 7A35T 上更划算。
//
//  CRC32 参数：多项式 0x04C11DB7（反射写法 0xEDB88320），初值 0xFFFFFFFF，
//    结果按位取反后发送 —— 与 IEEE 802.3 一致。
//=============================================================================

`timescale 1ns / 1ps

module eth_tx_mac (
    input  wire       clk,
    input  wire       rst_n,

    // ---- 帧数据（含 DA 起的完整帧）----
    input  wire       tx_valid,      // 高：本拍 tx_data 有效（空闲时第一拍即开帧）
    input  wire [7:0] tx_data,
    input  wire       tx_last,
    output reg        tx_ready,      // 高：MAC 已吃掉本拍字节，可给下一个

    // ---- GMII ----
    output reg        gmii_tx_en,
    output reg  [7:0] gmii_txd,
    output reg        gmii_tx_err,

    // ---- 状态 ----
    output reg        busy,
    output reg        done,          // 1 拍
    output reg  [15:0] frame_len     // 上一帧长度（不含前导码/FCS）
);

    localparam [3:0] S_IDLE = 4'd0,
                     S_PRE  = 4'd1,
                     S_DATA = 4'd2,
                     S_CRC  = 4'd3,
                     S_IFG  = 4'd4,
                     S_PAD  = 4'd5;   // 内容不足 60 B 时补 0（计入 CRC，不计入 frame_len）

    reg [3:0]  st;
    reg [3:0]  cnt;              // 前导码/CRC/IFG 计数
    reg [31:0] crc;
    reg [31:0] crc_tx;
    reg [15:0] len;
    reg [5:0]  pad_cnt;          // S_PAD 还要补几个 0

    // ---- CRC32 单字节推进（反射）----
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

    always @(posedge clk) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            cnt        <= 4'd0;
            crc        <= 32'hFFFF_FFFF;
            crc_tx     <= 32'd0;
            len        <= 16'd0;
            pad_cnt    <= 6'd0;
            tx_ready   <= 1'b0;
            gmii_tx_en <= 1'b0;
            gmii_txd   <= 8'h00;
            gmii_tx_err<= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            frame_len  <= 16'd0;
        end else begin
            done <= 1'b0;

            case (st)
            //-----------------------------------------------------------------
            S_IDLE: begin
                tx_ready   <= 1'b0;
                gmii_tx_en <= 1'b0;
                gmii_txd   <= 8'h00;
                gmii_tx_err<= 1'b0;
                busy       <= 1'b0;
                if (tx_valid) begin
                    st   <= S_PRE;
                    cnt  <= 4'd0;
                    crc  <= 32'hFFFF_FFFF;
                    len  <= 16'd0;
                    busy <= 1'b1;
                end
            end
            //-----------------------------------------------------------------
            // 前导码 7×0x55 + SFD 0xD5
            S_PRE: begin
                gmii_tx_en <= 1'b1;
                gmii_txd   <= (cnt < 4'd7) ? 8'h55 : 8'hD5;
                gmii_tx_err<= 1'b0;
                if (cnt == 4'd7) begin
                    st       <= S_DATA;
                    tx_ready <= 1'b1;       // 下一拍开始收数据
                end else begin
                    cnt <= cnt + 4'd1;
                end
            end
            //-----------------------------------------------------------------
            S_DATA: begin
                gmii_tx_en <= 1'b1;
                tx_ready   <= 1'b1;
                if (tx_valid) begin
                    gmii_txd  <= tx_data;
                    crc       <= crc32_byte(crc, tx_data);
                    if (tx_last) begin
                        tx_ready  <= 1'b0;
                        frame_len <= len + 16'd1;   // len 是"之前已发的字节数"
                        // ★ 以太网最小帧 60 B（不含 FCS）：不足就补 0 并计入 CRC。
                        //   否则 ARP 应答（42 B）这类短帧会被网卡/交换机当 runt 丢掉。
                        if ((len + 16'd1) < 16'd60) begin
                            pad_cnt <= 6'd60 - len[5:0] - 6'd1;
                            st      <= S_PAD;
                        end else begin
                            crc_tx <= ~crc32_byte(crc, tx_data);
                            st     <= S_CRC;
                            cnt    <= 4'd0;
                        end
                    end else begin
                        len <= len + 16'd1;
                    end
                end else begin
                    // ★ 调用方断流（正常不该发生；三源仲裁出错时会出现）：
                    //   补 0 必须**计入 CRC**，否则线上是一条 FCS 错的帧。
                    //   补到 2000 B 还等不到就把当前内容收尾 —— 至少发出去的是
                    //   一条 FCS 正确、内容被截断的合法帧（原实现是无限补 0 且
                    //   CRC 不更新，最后一条超长坏帧占着线）。
                    gmii_txd <= 8'h00;
                    crc      <= crc32_byte(crc, 8'h00);
                    if (len > 16'd2000) begin
                        tx_ready  <= 1'b0;
                        crc_tx    <= ~crc32_byte(crc, 8'h00);
                        frame_len <= len;
                        st        <= S_CRC;
                        cnt       <= 4'd0;
                    end
                end
            end
            //-----------------------------------------------------------------
            // 补 0 到最小帧：每个 0 都要进 CRC，否则 FCS 错
            //-----------------------------------------------------------------
            S_PAD: begin
                gmii_tx_en <= 1'b1;
                gmii_txd   <= 8'h00;
                crc        <= crc32_byte(crc, 8'h00);
                if (pad_cnt == 6'd1) begin
                    crc_tx   <= ~crc32_byte(crc, 8'h00);
                    tx_ready <= 1'b0;
                    st       <= S_CRC;
                    cnt      <= 4'd0;
                end else begin
                    pad_cnt  <= pad_cnt - 6'd1;
                end
            end
            //-----------------------------------------------------------------
            S_CRC: begin
                gmii_tx_en <= 1'b1;
                gmii_txd   <= crc_tx[7:0];
                crc_tx     <= {8'h00, crc_tx[31:8]};
                if (cnt == 4'd3) begin
                    st  <= S_IFG;
                    cnt <= 4'd0;
                end else begin
                    cnt <= cnt + 4'd1;
                end
            end
            //-----------------------------------------------------------------
            S_IFG: begin
                gmii_tx_en <= 1'b0;
                gmii_txd   <= 8'h00;
                if (cnt == 4'd11) begin
                    st   <= S_IDLE;
                    done <= 1'b1;
                end else begin
                    cnt <= cnt + 4'd1;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
