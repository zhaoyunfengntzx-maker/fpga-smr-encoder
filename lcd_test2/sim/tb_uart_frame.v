`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
//  tb_uart_frame.v —— uart_frame_sender + uart_tx_byte 的“帧级”自检
//
//  为什么要有这个测试台：
//    集成台 tb_lcd_rgb_top 只检查了“UART 有起始位输出”，从不校验一帧 16 字节
//    是否**逐字节正确**。上板实测才发现问题：115200 8N1 下每字节被发成 11 位
//    （起始 + 8 数据 + 重复的 MSB + 停止），PC 侧看到的是帧被截断 + 字节错。
//    这个测试台用一个 8N1 接收模型逐位采样，把 16 字节全解出来逐个比对，
//    于是“每字节多一位”这种错会被立刻抓住（framing error）。
//
//  跑法（Vivado 2026.1，工作目录任意）：
//    xvlog lcd_test/sim/tb_uart_frame.v lcd_test/rtl/lcd_test_support.v `
//          lcd_test/sim/iobuf_stub.v sim/xilinx_prims_stub.v
//    xelab tb_uart_frame -s simf -debug typical
//    xsim simf -R
// -----------------------------------------------------------------------------
module tb_uart_frame;

    // 与真实设计相同的 DIV（=115200 baud @50MHz）。整帧 16 字节只要 ~70k clk。
    localparam integer DIV     = 434;
    localparam integer NBYTES  = 16;
    localparam integer BITCLK  = DIV;          // 1 bit = DIV clk

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz

    reg         send = 1'b0;
    reg  [7:0]  b0, b1, b2, b3, b4, b5, b6, b7,
                b8, b9, b10, b11, b12, b13, b14, b15;
    wire        tx;
    wire        busy;

    integer     errors = 0;

    // ---- 期望的一帧（故意同时含 MSB=1 与 MSB=0 的字节）--------------------
    localparam [7:0] E0  = 8'hA5, E1  = 8'h4C, E2  = 8'h01, E3  = 8'h84,
                     E4  = 8'h00, E5  = 8'h8E, E6  = 8'h02, E7  = 8'h02,
                     E8  = 8'h02, E9  = 8'h58, E10 = 8'h01, E11 = 8'h00,
                     E12 = 8'h03, E13 = 8'h00, E14 = 8'h0A, E15 = 8'h00;

    uart_frame_sender u_send (
        .clk (clk), .rst_n (rst_n), .send (send),
        .b0 (b0), .b1 (b1), .b2 (b2),  .b3 (b3),
        .b4 (b4), .b5 (b5), .b6 (b6),  .b7 (b7),
        .b8 (b8), .b9 (b9), .b10(b10), .b11(b11),
        .b12(b12), .b13(b13), .b14(b14), .b15(b15),
        .tx (tx), .busy (busy)
    );

    // ---- 8N1 接收模型：在每个数据位的中点采样 ----------------------------
    reg  [7:0]  rx_sh;
    reg  [3:0]  rx_n;            // 0=起始位 1..8=数据位 9=停止位
    reg         rx_act;
    integer     rx_c;
    integer     got;
    reg  [7:0]  got_b [0:NBYTES-1];
    integer     rxfrm;           // framing error 计数

    function [7:0] exp_of;
        input integer i;
        begin
            case (i)
            0:  exp_of = E0;  1:  exp_of = E1;  2:  exp_of = E2;  3:  exp_of = E3;
            4:  exp_of = E4;  5:  exp_of = E5;  6:  exp_of = E6;  7:  exp_of = E7;
            8:  exp_of = E8;  9:  exp_of = E9;  10: exp_of = E10; 11: exp_of = E11;
            12: exp_of = E12; 13: exp_of = E13; 14: exp_of = E14; default: exp_of = E15;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_act <= 1'b0;  rx_c <= 0;  rx_n <= 4'd0;  rx_sh <= 8'h00;
            got <= 0;  rxfrm <= 0;
        end
        else if (!rx_act) begin
            // 空闲：等 tx 的下降沿（起始位）
            if (tx == 1'b0) begin
                rx_act <= 1'b1;
                rx_c   <= 0;
                rx_n   <= 4'd0;
            end
        end
        else begin
            rx_c <= rx_c + 1;
            // 采样点：起始位中点 = BITCLK/2，之后每位再 +BITCLK
            if (rx_c == (BITCLK/2) + BITCLK*rx_n) begin
                if (rx_n == 4'd0) begin
                    if (tx !== 1'b0) begin
                        $display("[FAIL] start bit not low at t=%0t", $time);
                        errors = errors + 1;
                    end
                end
                else if (rx_n <= 4'd8) begin
                    rx_sh[rx_n - 4'd1] <= tx;
                end
                else begin
                    // 停止位：必须为高，否则就是 8N1 帧错（本次上板故障的直接判据）
                    if (tx !== 1'b1) begin
                        $display("[FAIL] framing error (stop bit low) on byte #%0d, partial data = %02h",
                                 got, {rx_sh[7:1], tx});
                        rxfrm  = rxfrm + 1;
                        errors = errors + 1;
                    end
                    if (got < NBYTES) got_b[got] = rx_sh;
                    got    <= got + 1;
                    rx_act <= 1'b0;
                end
                rx_n <= rx_n + 4'd1;
            end
        end
    end

    // ---- 主流程 ----------------------------------------------------------
    integer i;
    integer guard;
    initial begin
        $display("== tb_uart_frame: 8N1 frame-level check (DIV=%0d) ==", DIV);
        b0=E0; b1=E1; b2=E2; b3=E3; b4=E4; b5=E5; b6=E6; b7=E7;
        b8=E8; b9=E9; b10=E10; b11=E11; b12=E12; b13=E13; b14=E14; b15=E15;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        @(posedge clk);
        send = 1'b1;
        @(posedge clk);
        send = 1'b0;

        // 等收满 16 字节
        guard = 0;
        while (got < NBYTES && guard < 400000) begin
            @(posedge clk);
            guard = guard + 1;
        end

        if (got != NBYTES) begin
            $display("[FAIL] only %0d of %0d bytes received", got, NBYTES);
            errors = errors + 1;
        end
        else begin
            for (i = 0; i < NBYTES; i = i + 1) begin
                if (got_b[i] !== exp_of(i)) begin
                    $display("[FAIL] byte %0d: got %02h expected %02h", i, got_b[i], exp_of(i));
                    errors = errors + 1;
                end
                else begin
                    $display("[ OK ] byte %2d: %02h", i, got_b[i]);
                end
            end
        end

        $display("framing_errors=%0d  bytes_received=%0d", rxfrm, got);
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #50_000_000;                       // 1 ms 超时保护
        $display("[FAIL] timeout");
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
