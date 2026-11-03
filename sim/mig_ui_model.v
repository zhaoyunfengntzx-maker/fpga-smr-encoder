//=============================================================================
//  mig_ui_model.v —— 行为级 MIG UI 模型（DDR3 测试台共用，不需要 MIG IP / 板子）
//-----------------------------------------------------------------------------
//  从 sim/tb_ddr3_ring.v 里提取出来的：原来模型是写在 tb_ddr3_ring.v 内部的，
//  tb_ddr3_full.v 注释说"复用 tb_ddr3_ring.v 里的 mig_ui_model"，但每个测试台
//  是**单独** xelab 的，另一个 tb 文件里的 module 根本不可见 —— 于是
//  tb_ddr3_full 的 xelab 一直报
//      ERROR: [VRFC 10-2063] Module <mig_ui_model> not found while processing
//      module instance <u_model> [sim/tb_ddr3_full.v:122]
//  全量回归里这一条因此长期是 BUILD-ERR。提取成独立文件后由 tools/run_sim.ps1
//  统一编译，两个 DDR3 测试台都能用。
//
//  行为：128 bit 字宽，命令/写数据各自独立握手（数据可先到/后到/同拍到），
//  约 1/8 的拍随机拉低 app_rdy / app_wdf_rdy 制造反压，读延迟 8..15 拍。
//=============================================================================

`timescale 1ns / 1ps

module mig_ui_model #(
    parameter integer AW = 6
) (
    input  wire         clk,
    input  wire         rst,            // 高有效
    input  wire [27:0]  app_addr,
    input  wire [2:0]   app_cmd,
    input  wire         app_en,
    input  wire [127:0] app_wdf_data,
    input  wire         app_wdf_wren,
    input  wire         app_wdf_end,
    output reg          app_rdy,
    output reg          app_wdf_rdy,
    output reg  [127:0] app_rd_data,
    output reg          app_rd_data_valid,
    output reg          app_rd_data_end
);
    localparam integer DEPTH = (1 << AW);

    reg [127:0] mem [0:DEPTH-1];
    reg [27:0]  wr_addr_q;

    // 读响应队列（先进先出，保证顺序）
    reg [AW-1:0] rq [0:15];
    reg [3:0]    rq_wr, rq_rd;
    integer      rd_log = 0;
    reg [4:0]    delay_cnt;
    reg          delay_run;

    // 伪随机反压
    reg [7:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= 8'hA5;
        else     lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
    end

    always @(posedge clk) begin
        if (rst) begin
            app_rdy     <= 1'b1;
            app_wdf_rdy <= 1'b1;
        end else begin
            // 约 1/8 的拍把 ready 拉低，制造握手停顿
            app_rdy     <= (lfsr[2:0] != 3'b000);
            app_wdf_rdy <= (lfsr[5:3] != 3'b000);
        end
    end

    // 写：命令与数据各自独立握手，按到达顺序配对（数据可以先到、后到、或同拍到）
    reg [AW-1:0]  cq [0:7];   // 已接收、还没配到数据的命令地址
    reg [127:0]   dq [0:7];   // 已接收、还没配到命令的数据
    reg [3:0]     cq_w, cq_r, dq_w, dq_r;

    always @(posedge clk) begin
        if (rst) begin
            cq_w <= 4'd0; cq_r <= 4'd0; dq_w <= 4'd0; dq_r <= 4'd0;
        end else begin
            if (!rst && app_en && app_rdy && app_cmd == 3'd0) begin
                cq[cq_w[2:0]] <= app_addr[AW+3:4];
                cq_w <= cq_w + 4'd1;
            end
            if (!rst && app_wdf_wren && app_wdf_rdy) begin
                dq[dq_w[2:0]] <= app_wdf_data;
                dq_w <= dq_w + 4'd1;
            end
            if ((cq_w != cq_r) && (dq_w != dq_r)) begin
                mem[cq[cq_r[2:0]]] <= dq[dq_r[2:0]];
                cq_r <= cq_r + 4'd1;
                dq_r <= dq_r + 4'd1;
            end
        end
    end

    // 读：命令被接收后排进队列
    always @(posedge clk) begin
        if (rst) begin
            rq_wr     <= 4'd0;
            rq_rd     <= 4'd0;
            delay_run <= 1'b0;
            delay_cnt <= 5'd0;
            app_rd_data_valid <= 1'b0;
            app_rd_data_end   <= 1'b0;
        end else begin
            app_rd_data_valid <= 1'b0;
            app_rd_data_end   <= 1'b0;

            if (app_en && app_rdy && app_cmd == 3'd1) begin
                rq[rq_wr[3:0]] <= app_addr[AW+3:4];
                rq_wr <= rq_wr + 4'd1;
            end

            if (!delay_run && (rq_wr != rq_rd)) begin
                delay_run <= 1'b1;
                delay_cnt <= 5'd8 + {2'b00, lfsr[3:1]};   // 8..15 拍
            end else if (delay_run) begin
                if (delay_cnt != 5'd0) begin
                    delay_cnt <= delay_cnt - 5'd1;
                end else begin
                    app_rd_data       <= mem[rq[rq_rd[3:0]]];
                    app_rd_data_valid <= 1'b1;
                    app_rd_data_end   <= 1'b1;
                    rq_rd     <= rq_rd + 4'd1;
                    delay_run <= 1'b0;
                end
            end
        end
    end
endmodule
