//=============================================================================
// uart_tx_8n1.v —— 极简 8N1 串口发送（bring-up 调试用）
//   * 只有发送方向，无 FIFO；start 在 !busy 时被接收一拍
//   * 位序 LSB first：起始位 0 → data[0..7] → 停止位 1
//   * 时钟频率随口令参数给，默认 50 MHz / 115200（DIV=434）
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module uart_tx_8n1 #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] din,
    input  wire       start,     // 单拍请求，busy 为低时才有效
    output reg        busy,
    output reg        tx
);

    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;

    reg [15:0] cnt;
    reg [3:0]  bit_i;
    reg [9:0]  sh;               // {stop, data[7:0], start}

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= 16'd0;
            bit_i <= 4'd0;
            sh    <= 10'h3FF;
            busy  <= 1'b0;
            tx    <= 1'b1;
        end else if (!busy) begin
            if (start) begin
                sh    <= {1'b1, din, 1'b0};
                busy  <= 1'b1;
                bit_i <= 4'd0;
                cnt   <= 16'd0;
                tx    <= 1'b0;               // 起始位
            end else begin
                tx <= 1'b1;
            end
        end else begin
            if (cnt == DIV - 1) begin
                cnt <= 16'd0;
                if (bit_i == 4'd9) begin
                    busy <= 1'b0;            // 停止位发完
                    tx   <= 1'b1;
                end else begin
                    bit_i <= bit_i + 4'd1;
                    tx    <= sh[bit_i + 4'd1];
                end
            end else begin
                cnt <= cnt + 16'd1;
            end
        end
    end

endmodule

`default_nettype wire
