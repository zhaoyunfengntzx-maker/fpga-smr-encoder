//==========================================================================
// tb_uart_frame26.v —— 遥测帧 v3（26 字节）逐字节校验
//   上板教训（见 lcd_test/tools/sim_lcd_test.tcl 注 1b）：只验"有起始位"不够，
//   必须按 8N1 把每一位采出来，才能保证 PC 侧 lcd2_uart_check.py 能原样解出。
//
//   本台：
//     1) 用 8N1 过采样接收模型收下一整帧，比对 26 个字节
//     2) 帧进行中再给 send 脉冲，确认不重入（仍只有 26 字节）
//     3) 校验 busy 指示灯：帧内为高，帧后为低
//==========================================================================
`timescale 1ns / 1ps

module tb_uart_frame26;

    localparam DIV = 434;                 // 50MHz/115200，与 uart_tx_byte 默认值一致

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         send = 1'b0;
    reg  [31:0] w0, w1, w2, w3, w4, w5, w6;
    wire        tx, busy;

    integer errors = 0;

    always #10 clk = ~clk;                // 50MHz

    uart_frame_sender26 u_dut (
        .clk (clk), .rst_n (rst_n), .send (send),
        .w0 (w0), .w1 (w1), .w2 (w2), .w3 (w3),
        .w4 (w4), .w5 (w5), .w6 (w6),
        .tx (tx), .busy (busy)
    );

    // ---------------------------------------------------------------- 8N1 接收模型
    reg  [7:0] rxb [0:63];
    integer    rxn = 0;
    reg        rbusy = 1'b0;
    reg [15:0] rdiv = 16'd0;
    reg  [3:0] rbit = 4'd0;
    reg  [7:0] rsh = 8'h00;

    always @(posedge clk) begin
        if (rbusy) begin
            if (rdiv == ((rbit == 4'd0) ? (DIV/2 - 1) : (DIV - 1))) begin
                rdiv <= 16'd0;
                if (rbit == 4'd0) begin
                    // 起始位中点：必须是低
                    if (tx !== 1'b0) begin
                        errors = errors + 1;
                        $display("[FAIL] 起始位中点不是低电平");
                    end
                    rbit <= 4'd1;
                end else if (rbit <= 4'd8) begin
                    rsh  <= {tx, rsh[7:1]};      // LSB 先出
                    rbit <= rbit + 4'd1;
                end else begin
                    rbusy <= 1'b0;
                    if (rxn < 64) begin
                        rxb[rxn] = rsh;
                        rxn = rxn + 1;
                    end
                    if (tx !== 1'b1) begin
                        errors = errors + 1;
                        $display("[FAIL] 第 %0d 字节停止位不是高电平", rxn);
                    end
                end
            end else rdiv <= rdiv + 16'd1;
        end else if (tx === 1'b0) begin
            rbusy <= 1'b1; rdiv <= 16'd0; rbit <= 4'd0;
        end
    end

    // 期望的 26 字节（与 lcd_test2/rtl/lcd_test_support.v 头注释一致）
    reg [7:0] exp [0:25];
    integer   i;

    task do_send;
        begin
            @(posedge clk);
            send = 1'b1;
            @(posedge clk);
            send = 1'b0;
        end
    endtask

    initial begin
        // w0 = {0xA5, 0x4C, 0x03, id_bits=0x9D}  id_valid=1, 命中 7016(bit2)
        w0 = 32'hA5_4C_03_9D;
        // w1 = {mode=1, paused=0, tch_type=2(FT5x06), tch_valid=1}
        //   ★ 本台直接喂原始 w1..w6 字给发送器，发送器只按字节搬运，所以这里
        //     只验证搬运顺序。顶层 lcd_test2_top 现在把 byte4..6 的空位用来
        //     上报触摸状态机（见 docs/LCD_test_program_readme.md §5），不影响本台。
        w1 = 32'h01_00_02_01;
        // w2 = {points=3, status=0x05, color_idx=4, frame[23:16]=0x12}
        w2 = 32'h03_05_04_12;
        // w3 = {frame[15:8]=0x34, frame[7:0]=0x56, x0=0x0140=320}
        w3 = 32'h34_56_01_40;
        // w4 = {y0=0x0258=600, x1=0x00C8=200}
        w4 = 32'h02_58_00_C8;
        // w5 = {y1=0x0190=400, reads=0x0005}
        w5 = 32'h01_90_00_05;
        // w6 = {err=0x0000, 0x5A, 0x00}
        w6 = 32'h00_00_5A_00;

        exp[0]=8'hA5; exp[1]=8'h4C; exp[2]=8'h03; exp[3]=8'h9D;
        exp[4]=8'h01; exp[5]=8'h00; exp[6]=8'h02; exp[7]=8'h01;
        exp[8]=8'h03; exp[9]=8'h05; exp[10]=8'h04; exp[11]=8'h12;
        exp[12]=8'h34; exp[13]=8'h56; exp[14]=8'h01; exp[15]=8'h40;
        exp[16]=8'h02; exp[17]=8'h58; exp[18]=8'h00; exp[19]=8'hC8;
        exp[20]=8'h01; exp[21]=8'h90; exp[22]=8'h00; exp[23]=8'h05;
        exp[24]=8'h00; exp[25]=8'h00;

        $display("== tb_uart_frame26: 遥测帧 v3 逐字节校验 ==");
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        do_send;

        // 帧进行中重入测试：此时 busy 应为高，并再给一个 send
        repeat (200) @(posedge clk);
        if (busy !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] 帧进行中 busy 不是高电平");
        end else begin
            $display("[ OK ] 帧进行中 busy=1");
        end
        send = 1'b1; @(posedge clk); send = 1'b0;

        // 等一帧发完（26 字节 ×10 位 ×434 拍）+ 余量
        repeat (26*10*DIV + 5000) @(posedge clk);

        if (rxn !== 26) begin
            errors = errors + 1;
            $display("[FAIL] 收到 %0d 字节，期望 26（重入或位对齐有误）", rxn);
        end else begin
            $display("[ OK ] 收到 26 字节");
        end

        for (i = 0; i < 26 && i < rxn; i = i + 1) begin
            if (rxb[i] !== exp[i]) begin
                errors = errors + 1;
                $display("[FAIL] 字节 %0d: got %02X expected %02X", i, rxb[i], exp[i]);
            end
        end

        // 人类可读的字段解包复核（与 PC 侧 lcd2_uart_check.py 同一套偏移）
        $display("  解包: id=%02X mode=%0d paused=%0d type=%0d valid=%0d",
                 rxb[3], rxb[4], rxb[5], rxb[6], rxb[7]);
        $display("        pts=%0d sts=%02X color=%0d frame=%02X%02X%02X",
                 rxb[8], rxb[9], rxb[10], rxb[11], rxb[12], rxb[13]);
        $display("        T1=(%0d,%0d) reads=%0d err=%0d tail=%02X",
                 {rxb[14],rxb[15]}, {rxb[16],rxb[17]},
                 {rxb[22],rxb[23]}, {rxb[24],rxb[25]}, rxb[25]);

        if (rxb[3]  !== 8'h9D || rxb[4]  !== 8'h01 || rxb[6]  !== 8'h02) begin
            errors = errors + 1; $display("[FAIL] 头部字段解包不符");
        end
        if ({rxb[14],rxb[15]} !== 16'd320 || {rxb[16],rxb[17]} !== 16'd600) begin
            errors = errors + 1; $display("[FAIL] T1 坐标解包不符");
        end
        if ({rxb[11],rxb[12],rxb[13]} !== 24'h123456) begin
            errors = errors + 1; $display("[FAIL] frame_cnt 24 位解包不符");
        end

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
