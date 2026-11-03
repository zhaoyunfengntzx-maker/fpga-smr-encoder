//=============================================================================
//  scope_dump.v —— 抓包缓冲的 UART 批量回读（B1 第二级）
//-----------------------------------------------------------------------------
//  为什么需要它：
//    用寄存器一条一条读（4 B 命令 + 6 B 应答只换回 2 B 数据）回读 160 KB
//    要 4~5 秒，且会把遥测彻底堵死。本模块把缓冲按"块"整段推流：
//      每块 = 7 B 头 + 64 点 × 4 B + 1 B XOR = 264 B
//      头 = AA 55 A2 10 | blk_lo blk_hi | n
//    以 2 Mbaud 计，每字节约 250 clk，一块 264 B ≈ 1.32 ms，
//    448 块（28672 点）≈ 0.59 s。比逐寄存器读快约 5 倍，且是单向推流。
//-----------------------------------------------------------------------------
//  实现要点：
//    1) start 之后先等 START_DELAY 个 clk（默认 5 ms），确保"写 DUMP_CTRL"
//       的 6 B 应答一定已经发完；再等 line_idle（遥测/桥都空闲）才开始发头。
//       这两条一起消除"应答与数据块在 TX 上打架"的竞争。
//    2) 字节发送器是本文件内的独立小 FSM：10 bit（起始+8 数据+停止），
//       每 bit BAUD_DIV 个 clk，与 uart_scope/uart_spi_bridge 的 uart_tx
//       时序一致，但不需要外部 tx_start 握手（req_pend/ack 是电平+脉冲）。
//    3) req_pend/bval/ack 是一个"单字节信箱"：主 FSM 放字节，发送器取走，
//       取走的同一拍回 ack。这样主 FSM 不需要关心 250 clk 的位时序。
//    4) 读指针从 cap_start 起顺序走，到 DEPTH-1 回绕到 0（DEPTH 非 2 的幂，
//       必须比较回绕）。
//    5) 最后一个块可能不足 64 点，头里的 n 给出实际点数；上位机按 n 拆分，
//       不依赖固定 64。
//    6) abort 立即停发（当前字节发完为止），busy 拉低，上位机靠块头重同步。
//=============================================================================

`timescale 1ns / 1ps

module scope_dump #(
    parameter integer DEPTH       = 28672,
    parameter integer BAUD_DIV    = 25,        // 50 MHz / 2 Mbaud
    parameter integer START_DELAY = 250000,    // 5 ms @50 MHz，等写命令的应答发完
    parameter integer PTS         = 64         // 每块点数
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 命令 ----
    input  wire        start,          // 1 拍
    input  wire        abort,          // 1 拍
    input  wire        line_idle,      // 遥测行与 SPI 桥都空闲

    // ---- 窗口描述（来自 scope_capture）----
    input  wire [15:0] cap_start,
    input  wire [15:0] cap_len,

    // ---- 读口（接到 scope_capture）----
    output reg  [15:0] rd_addr,
    output reg         rd_en,
    input  wire [31:0] rd_data,

    // ---- 状态 ----
    output reg         tx,
    output reg         busy,
    output reg         done,
    output reg  [15:0] blocks_done
);

    //-------------------------------------------------------------------------
    //  状态编码
    //-------------------------------------------------------------------------
    localparam [3:0] S_IDLE = 4'd0,
                     S_DLY  = 4'd1,
                     S_HDR  = 4'd2,
                     S_REQ  = 4'd3,
                     S_W1   = 4'd4,
                     S_W2   = 4'd5,
                     S_DATA = 4'd6,
                     S_CHK  = 4'd7,
                     S_NEXT = 4'd8,
                     S_DONE = 4'd9;

    reg [3:0]  st;
    reg [17:0] dly;

    localparam [15:0] DEPTH_C       = DEPTH;
    localparam [15:0] BAUD_DIV_C    = BAUD_DIV;
    localparam [17:0] START_DELAY_C = START_DELAY;

    reg [15:0] blocks;
    reg [15:0] blk;
    reg [15:0] pts_in_blk;
    reg [15:0] pts_done;
    reg [15:0] rd_ptr;
    reg [15:0] rd_ptr_nxt;
    reg [2:0]  hdr_idx;
    reg [2:0]  byte_idx;
    reg [31:0] word;
    reg [7:0]  xacc;

    // 单字节信箱
    reg [7:0]  bval;
    reg        req_pend;

    // 字节发送器
    reg [7:0]  sh;
    reg [3:0]  bit_idx;
    reg [15:0] baud_cnt;
    reg        sending;

    // ack: byte fully shifted out (end of stop bit). The old !sending form
    // fired one cycle early (at load time), so the final byte of a dump was
    // truncated when busy dropped and the UART mux switched back.
    wire ack = req_pend && sending && (bit_idx == 4'd9) &&
               (baud_cnt == BAUD_DIV_C - 16'd1);

    //-------------------------------------------------------------------------
    //  组合：块头字节 / 载荷字节
    //-------------------------------------------------------------------------
    reg [7:0] hbyte;
    always @(*) begin
        case (hdr_idx)
        3'd0:    hbyte = 8'hAA;
        3'd1:    hbyte = 8'h55;
        3'd2:    hbyte = 8'hA2;
        3'd3:    hbyte = 8'h10;
        3'd4:    hbyte = blk[7:0];
        3'd5:    hbyte = blk[15:8];
        3'd6:    hbyte = pts_in_blk[7:0];
        default: hbyte = 8'h00;
        endcase
    end

    reg [7:0] wbyte;
    always @(*) begin
        case (byte_idx)
        3'd0:    wbyte = word[7:0];
        3'd1:    wbyte = word[15:8];
        3'd2:    wbyte = word[23:16];
        default: wbyte = word[31:24];
        endcase
    end

    //-------------------------------------------------------------------------
    //  字节发送器（10 bit：起始 0 / 8 数据 / 停止 1）
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            sh       <= 8'hFF;
            bit_idx  <= 4'd0;
            baud_cnt <= 16'd0;
            sending  <= 1'b0;
        end else if (req_pend && !sending) begin
            sh       <= bval;
            sending  <= 1'b1;
            bit_idx  <= 4'd0;
            baud_cnt <= 16'd0;
        end else if (sending) begin
            if (baud_cnt == BAUD_DIV_C - 16'd1) begin
                baud_cnt <= 16'd0;
                if (bit_idx == 4'd9) sending <= 1'b0;
                else                 bit_idx <= bit_idx + 4'd1;
            end else begin
                baud_cnt <= baud_cnt + 16'd1;
            end
        end
    end

    always @(*) begin
        if (!sending)                    tx = 1'b1;
        else if (bit_idx == 4'd0)        tx = 1'b0;
        else if (bit_idx == 4'd9)        tx = 1'b1;
        else                             tx = sh[bit_idx-1];
    end

    //-------------------------------------------------------------------------
    //  主状态机
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st          <= S_IDLE;
            dly         <= 18'd0;
            blocks      <= 16'd0;
            blk         <= 16'd0;
            pts_in_blk  <= 16'd0;
            pts_done    <= 16'd0;
            rd_ptr      <= 16'd0;
            rd_ptr_nxt  <= 16'd0;
            hdr_idx     <= 3'd0;
            byte_idx    <= 3'd0;
            word        <= 32'd0;
            xacc        <= 8'h00;
            bval        <= 8'h00;
            req_pend    <= 1'b0;
            rd_addr     <= 16'd0;
            rd_en       <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
            blocks_done <= 16'd0;
        end else if (abort) begin
            st       <= S_IDLE;
            busy     <= 1'b0;
            req_pend <= 1'b0;
            rd_en    <= 1'b0;
            done     <= 1'b0;
        end else begin
            done <= 1'b0;

            case (st)
            //-----------------------------------------------------------------
            S_IDLE: begin
                rd_en    <= 1'b0;
                req_pend <= 1'b0;
                if (start && cap_len != 16'd0) begin
                    blocks      <= (cap_len + 16'd63) >> 6;
                    blk         <= 16'd0;
                    pts_in_blk  <= (cap_len >= 16'd64) ? 16'd64 : cap_len;
                    pts_done    <= 16'd0;
                    rd_ptr      <= cap_start;
                    rd_ptr_nxt  <= (cap_start == DEPTH_C - 16'd1)
                                   ? 16'd0 : (cap_start + 16'd1);
                    hdr_idx     <= 3'd0;
                    byte_idx    <= 3'd0;
                    xacc        <= 8'h00;
                    dly         <= 18'd0;
                    blocks_done <= 16'd0;
                    busy        <= 1'b1;
                    st          <= S_DLY;
                end
            end
            //-----------------------------------------------------------------
            S_DLY: begin
                if (dly != START_DELAY_C - 18'd1) begin
                    dly <= dly + 18'd1;
                end else if (line_idle) begin
                    xacc    <= 8'h00;
                    pts_done <= 16'd0;
                    st      <= S_HDR;
                end
            end
            //-----------------------------------------------------------------
            S_HDR: begin
                if (!req_pend) begin
                    bval     <= hbyte;
                    req_pend <= 1'b1;
                end else if (ack) begin
                    req_pend <= 1'b0;
                    xacc     <= xacc ^ bval;
                    if (hdr_idx == 3'd6) begin
                        hdr_idx <= 3'd0;
                        st      <= S_REQ;
                    end else begin
                        hdr_idx <= hdr_idx + 3'd1;
                    end
                end
            end
            //-----------------------------------------------------------------
            S_REQ: begin
                rd_addr <= rd_ptr;
                rd_en   <= 1'b1;
                st      <= S_W1;
            end
            //-----------------------------------------------------------------
            S_W1: begin
                rd_en <= 1'b0;
                st    <= S_W2;
            end
            //-----------------------------------------------------------------
            S_W2: begin
                word     <= rd_data;
                byte_idx <= 3'd0;
                st       <= S_DATA;
            end
            //-----------------------------------------------------------------
            S_DATA: begin
                if (!req_pend) begin
                    bval     <= wbyte;
                    req_pend <= 1'b1;
                end else if (ack) begin
                    req_pend <= 1'b0;
                    xacc     <= xacc ^ bval;
                    if (byte_idx == 3'd3) begin
                        byte_idx <= 3'd0;
                        pts_done <= pts_done + 16'd1;
                        rd_ptr   <= rd_ptr_nxt;
                        // 下一个点的地址
                        rd_ptr_nxt <= (rd_ptr_nxt == DEPTH_C - 16'd1)
                                      ? 16'd0 : (rd_ptr_nxt + 16'd1);
                        if ((pts_done + 16'd1) == pts_in_blk) st <= S_CHK;
                        else                                  st <= S_REQ;
                    end else begin
                        byte_idx <= byte_idx + 3'd1;
                    end
                end
            end
            //-----------------------------------------------------------------
            S_CHK: begin
                if (!req_pend) begin
                    bval     <= xacc;
                    req_pend <= 1'b1;
                end else if (ack) begin
                    req_pend <= 1'b0;
                    xacc     <= 8'h00;
                    st       <= S_NEXT;
                end
            end
            //-----------------------------------------------------------------
            S_NEXT: begin
                blk         <= blk + 16'd1;
                blocks_done <= blk + 16'd1;
                if ((blk + 16'd1) >= blocks) begin
                    st <= S_DONE;
                end else begin
                    pts_done <= 16'd0;
                    hdr_idx  <= 3'd0;
                    if ((cap_len - (blk + 16'd1) * 16'd64) >= 16'd64)
                        pts_in_blk <= 16'd64;
                    else
                        pts_in_blk <= cap_len - (blk + 16'd1) * 16'd64;
                    st <= S_HDR;
                end
            end
            //-----------------------------------------------------------------
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end
            //-----------------------------------------------------------------
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
