//=============================================================================
//  uart_rx.v —— 极简 8N1 UART 接收器（1 字节 / 次）
//-----------------------------------------------------------------------------
//  用途
//    · 与 rtl/uart_scope.v 里的 uart_tx 配对，构成 UART→SPI 桥的接收侧
//      （见 rtl/uart_spi_bridge.v）。板载 USB 串口（CH340E）的 FPGA 接收脚
//      uart_rxd = T20；命令通道固定 2 Mbaud，即 BAUD_DIV = CLK_HZ/BAUD =
//      50e6/2e6 = 25（与 uart_tx 用同一个参数语义：1 位 = BAUD_DIV 个 clk）。
//
//  接收时序（全部在 clk 域，rx 是异步输入）
//    1) rx 先过两级同步器 rx_s1/rx_s2（不引入新时钟域，与契约 0.3 一致）；
//    2) S_IDLE 等起始位下降沿（rx_s2 由高变低）；
//    3) S_START 等 BAUD_DIV/2 拍后在起始位**中点**复采一次：仍为低才认这一帧，
//       否则判为窄脉冲（毛刺）并回 S_IDLE —— 这是本模块唯一的抗干扰措施，
//       对"线太长/旁边有 ADC 时钟"的板子很关键；
//    4) S_DATA 每 BAUD_DIV 拍采一位、LSB 先收，共 8 位；
//    5) S_STOP 等 BAUD_DIV 拍后输出 rx_valid 单周期脉冲 + rx_data（不校验
//       停止位：上位机是 PC，帧错误只会来自波特率不匹配，由上层超时处理）。
//
//  波特率容差
//    采样点固定在"起始沿 + 0.5 位"以及之后每 1.0 位的整数倍处，10 位内累计
//    漂移 ≈ 9.5 位 × 相对误差，与非同步 8N1 一致，约 ±4% 可正确接收。
//    sim/tb_uart_spi_bridge.v 覆盖发送方 +2%（25/26 拍交替）的极限工况。
//
//  为什么不做 16 倍过采样
//    本设计单时钟域 50 MHz、波特率固定，BAUD_DIV=25 已是 25 倍过采样；再拆
//    16 分频只会让"发一拍歇一拍"的时序更难写。保持与 uart_tx 相同的 BAUD_DIV
//    语义，两个方向共用一个参数（顶层 parameter BAUD_DIV）。
//
//  资源：FF ≈ 22，LUT ≈ 28，无 DSP/BRAM。
//=============================================================================
`timescale 1ns / 1ps

module uart_rx #(
    parameter integer BAUD_DIV      = 25,           // = CLK_HZ / BAUD（50MHz/2Mbaud）
    parameter integer BAUD_DIV_HALF = BAUD_DIV / 2  // 起始位中点（向下取整）
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // 异步串行输入（空闲为高）
    output reg  [7:0] rx_data,     // 收到的字节（rx_valid 当拍有效）
    output reg        rx_valid,    // 单周期脉冲
    output wire       rx_busy      // 正在收一帧（调试/统计用）
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bidx;
    reg [7:0]  sh;
    reg        rx_s1, rx_s2;

    assign rx_busy = (st != S_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            cnt      <= 16'd0;
            bidx     <= 3'd0;
            sh       <= 8'd0;
            rx_data  <= 8'd0;
            rx_valid <= 1'b0;
            rx_s1    <= 1'b1;
            rx_s2    <= 1'b1;
        end
        else begin
            rx_s1    <= rx;
            rx_s2    <= rx_s1;
            rx_valid <= 1'b0;               // 默认拉低：只发单周期脉冲

            case (st)
                // ---- 等起始位下降沿 ----
                S_IDLE: begin
                    if (!rx_s2) begin
                        st  <= S_START;
                        cnt <= (BAUD_DIV_HALF == 0) ? 16'd0 : (BAUD_DIV_HALF - 1);
                    end
                end
                // ---- 起始位中点复采：仍为低才认帧 ----
                S_START: begin
                    if (cnt == 16'd0) begin
                        if (!rx_s2) begin
                            st   <= S_DATA;
                            bidx <= 3'd0;
                            cnt  <= BAUD_DIV - 1;
                        end
                        else begin
                            st <= S_IDLE;       // 窄脉冲：不是起始位
                        end
                    end
                    else begin
                        cnt <= cnt - 1'b1;
                    end
                end
                // ---- 8 个数据位，LSB 先收 ----
                S_DATA: begin
                    if (cnt == 16'd0) begin
                        sh <= {rx_s2, sh[7:1]};
                        if (bidx == 3'd7) begin
                            st  <= S_STOP;
                            cnt <= BAUD_DIV - 1;
                        end
                        else begin
                            bidx <= bidx + 1'b1;
                            cnt  <= BAUD_DIV - 1;
                        end
                    end
                    else begin
                        cnt <= cnt - 1'b1;
                    end
                end
                // ---- 停止位：只等满一位 ----
                S_STOP: begin
                    if (cnt == 16'd0) begin
                        rx_data  <= sh;
                        rx_valid <= 1'b1;
                        st       <= S_IDLE;
                    end
                    else begin
                        cnt <= cnt - 1'b1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
