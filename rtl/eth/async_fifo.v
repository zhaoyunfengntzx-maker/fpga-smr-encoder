//=============================================================================
//  async_fifo.v —— 格雷码指针异步 FIFO（以太网 CDC 用）
//-----------------------------------------------------------------------------
//  为什么自己写、不用 XPM：
//    1) 本工程是纯 RTL + tcl 脚本流程（tools/synth_check.tcl 只 read_verilog），
//       没有 IP 工程；XPM 需要额外库依赖，xsim 里还得手动 -L xpm。
//    2) 以太网只用两处：RX 字节流（rxc → 125M）与抓包数据（50M → 125M），
//       都是"宽深比小、单写单读"，格雷码 CDC 足够，且能在仿真里逐拍验证。
//
//  保守设计：
//    · 读写指针多 1 位用于区分"满/空"（标准做法）；
//    · 空/满都用"同步后的对方指针"判断，因此有 1~2 拍迟滞 —— 调用方必须
//      把 almost_full 提前 2 拍用（本文件提供 almost_full = 剩余 < 4）。
//    · 复位：写侧 rst_n 清写指针，读侧 rst_n 清读指针。两侧必须同时复位
//      （本工程只有一个 POR 复位，跨域各打两拍后使用）。
//=============================================================================

`timescale 1ns / 1ps

module async_fifo #(
    parameter integer DW    = 8,
    parameter integer AW    = 9,             // 深度 = 2**AW
    parameter integer ALMOST = 4             // almost_full 留的余量（字数）
) (
    input  wire          wr_clk,
    input  wire          wr_rst_n,
    input  wire          wr_en,
    input  wire [DW-1:0] din,
    output wire          full,
    output wire          almost_full,

    input  wire          rd_clk,
    input  wire          rd_rst_n,
    input  wire          rd_en,
    output reg  [DW-1:0] dout,
    output wire          empty,
    output wire [AW:0]   wr_level,
    output wire [AW:0]   rd_level
);

    localparam integer DEPTH = (1 << AW);

    reg [DW-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wr_ptr, rd_ptr;                 // 二进制（多 1 位）
    reg  [AW:0] wr_gray, rd_gray;               // 格雷码
    reg  [AW:0] wr_gray_s1, wr_gray_s2;         // 读侧看到的写指针
    reg  [AW:0] rd_gray_s1, rd_gray_s2;         // 写侧看到的读指针

    wire [AW:0] wr_bin_nxt = wr_ptr + {{AW{1'b0}}, 1'b1};
    wire [AW:0] rd_bin_nxt = rd_ptr + {{AW{1'b0}}, 1'b1};
    wire [AW:0] wr_gray_nxt = (wr_bin_nxt >> 1) ^ wr_bin_nxt;
    wire [AW:0] rd_gray_nxt = (rd_bin_nxt >> 1) ^ rd_bin_nxt;

    // ---- 写侧 ----
    always @(posedge wr_clk) begin
        if (!wr_rst_n) begin
            wr_ptr  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else if (wr_en && !full) begin
            mem[wr_ptr[AW-1:0]] <= din;
            wr_ptr  <= wr_bin_nxt;
            wr_gray <= wr_gray_nxt;
        end
    end

    // ---- 读侧 ----
    always @(posedge rd_clk) begin
        if (!rd_rst_n) begin
            rd_ptr  <= {(AW+1){1'b0}};
            rd_gray <= {(AW+1){1'b0}};
            dout    <= {DW{1'b0}};
        end else if (rd_en && !empty) begin
            dout    <= mem[rd_ptr[AW-1:0]];
            rd_ptr  <= rd_bin_nxt;
            rd_gray <= rd_gray_nxt;
        end
    end

    // ---- 指针同步（各两拍） ----
    always @(posedge rd_clk) begin
        if (!rd_rst_n) begin
            wr_gray_s1 <= {(AW+1){1'b0}};
            wr_gray_s2 <= {(AW+1){1'b0}};
        end else begin
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;
        end
    end

    always @(posedge wr_clk) begin
        if (!wr_rst_n) begin
            rd_gray_s1 <= {(AW+1){1'b0}};
            rd_gray_s2 <= {(AW+1){1'b0}};
        end else begin
            rd_gray_s1 <= rd_gray;
            rd_gray_s2 <= rd_gray_s1;
        end
    end

    // ---- 满 / 空 / 余量 ----
    // 空：读侧同步到的写指针 == 本地读指针（格雷码相等）
    assign empty = (wr_gray_s2 == rd_gray);

    // 满：写指针追上读指针的"下一圈"（高两位相反、其余相同）
    assign full = (wr_gray[AW:AW-1] == ~rd_gray_s2[AW:AW-1]) &&
                  (wr_gray[AW-2:0] == rd_gray_s2[AW-2:0]);

    // 同步过来的是格雷码，算"用量"必须先还原成二进制
    function [AW:0] gray2bin;
        input [AW:0] g;
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i + 1] ^ g[i];
        end
    endfunction

    wire [AW:0] rd_bin_s2 = gray2bin(rd_gray_s2);
    wire [AW:0] wr_bin_s2 = gray2bin(wr_gray_s2);

    wire [AW:0] wr_used = wr_ptr - rd_bin_s2;    // 仅用于保守的 almost_full
    assign almost_full = (wr_used >= (DEPTH - ALMOST));

    assign wr_level = wr_ptr - rd_bin_s2;
    assign rd_level = wr_bin_s2 - rd_ptr;

endmodule
