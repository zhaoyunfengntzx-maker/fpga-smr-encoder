//------------------------------------------------------------------------------
//  tb_dump_start.v —— enc_top dump 启动路径集成测试（v60 上板缺陷的回归）
//
//  背景：2026-10-22 上板发现"写 0x072E 后 dump 永远不启动"。
//        根因是 cap_regs 的 dump_start 只有**单拍**，而写命令那几拍
//        scope_hold = tx_hold | dump_busy 正好为高，enc_top 旧代码的
//        组合门控把这一拍吃掉 → 请求永久丢失。
//        修法：enc_top 里用 dump_req 锁存请求，等门控放开再发单拍。
//
//  本测试台做什么：
//    1) 走真实 UART 命令通道，配置 cap_len=128（2 块）、立即触发、arm；
//    2) 等采集 done（读内部 st_done）；
//    3) **强行把 scope_idle_w 拉低**，在这个窗口里写 0x072E=1 ——
//       等价于上板时"写命令落在 scope_hold 为高的那几拍"；
//    4) 断言：门控期间 dump 不启动、但请求被 dump_req 锁住；
//    5) 放开 scope_idle_w，dump 必须在一个遥测帧间隙内启动，
//       并完整送出 2 块（blocks_done == 2）。
//
//  旧代码在第 5 步会失败（请求已被吃掉，dump 永不启动）。
//  只用 ASCII 注释，避免 Vivado/xsim 的代码页问题。
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_dump_start;

    localparam integer CLK_HALF   = 10;       // 50 MHz
    localparam integer PORBITS    = 8;        // 缩短上电复位计数
    localparam integer BAUD_DIV   = 10;       // 5 Mbaud（50 MHz / 10），加快仿真
    localparam integer BIT_NS     = BAUD_DIV * 20;
    localparam integer CAP_PTS    = 128;      // 128 点 = 2 块 × 64

    reg         sys_clk;
    reg         key_n;
    wire        ad_clk;
    reg  [11:0] ad_ch1_d;
    reg  [11:0] ad_ch2_d;
    reg         ad_ch1_otr;
    reg         ad_ch2_otr;
    wire        a_out, b_out, z_out, u_out, v_out, w_out;
    reg         spi_sck, spi_ss_n, spi_mosi;
    wire        spi_miso;
    wire [3:0]  led;
    wire        uart_tx;
    reg         uart_rx;
    wire        irq_n;

    integer pass_cnt;
    integer fail_cnt;
    integer i;
    integer timeout;
    integer dump_start_cycles;

    // ---- dump 字节流抓取（UART 接收模型）----------------------------------
    integer      rx_cnt;
    reg [7:0]    rxb [0:2047];
    reg          capture_en;
    reg [7:0]    cap_byte;
    integer      k;
    integer      ks;
    integer      base;
    integer      hdr_pos;
    reg          hdr_found;
    reg [7:0]    xacc;

    initial sys_clk = 1'b0;
    always #CLK_HALF sys_clk = ~sys_clk;

    initial begin
        key_n      = 1'b1;
        ad_ch1_d   = 12'h800;
        ad_ch2_d   = 12'h800;
        ad_ch1_otr = 1'b0;
        ad_ch2_otr = 1'b0;
        spi_sck    = 1'b0;
        spi_ss_n   = 1'b1;
        spi_mosi   = 1'b0;
        uart_rx    = 1'b1;
    end

    enc_top #(
        .AW            (16),
        .FRAC          (8),
        .LOG2DEC       (0),
        .BAUD_DIV      (BAUD_DIV),
        .SAMPLE_DIV    (500),
        .CLK_PERIOD_NS (20),
        .POR_BITS      (PORBITS),
        .POLE_BITS     (6)
    ) dut (
        .sys_clk    (sys_clk),
        .key_n      (key_n),
        .ad_clk     (ad_clk),
        .ad_ch1_d   (ad_ch1_d),
        .ad_ch2_d   (ad_ch2_d),
        .ad_ch1_otr (ad_ch1_otr),
        .ad_ch2_otr (ad_ch2_otr),
        .a_out      (a_out),
        .b_out      (b_out),
        .z_out      (z_out),
        .u_out      (u_out),
        .v_out      (v_out),
        .w_out      (w_out),
        .spi_sck    (spi_sck),
        .spi_ss_n   (spi_ss_n),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .led        (led),
        .uart_tx    (uart_tx),
        .irq_n      (irq_n),
        .uart_rx    (uart_rx)
    );

    // ---- UART 8N1 接收模型 ------------------------------------------------
    //   从复位后线路空闲开始连续采样（不等 capture_en），保证字节边界始终
    //   对齐；只有 capture_en=1 的字节才记进 rxb。dump 的 528 B 是背靠背
    //   发的，若改成"每个起始位重新同步"会和帧内 1->0 跳变混淆。
    initial begin
        rx_cnt     = 0;
        capture_en = 1'b0;
        wait (uart_tx === 1'b1);
        #(BIT_NS * 3);
        forever begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS / 2);            // 采样到 bit0 中心
            for (ks = 0; ks < 8; ks = ks + 1) begin
                cap_byte[ks] = uart_tx;
                if (ks != 7) #(BIT_NS);
            end
            if (capture_en && rx_cnt < 2048) begin
                rxb[rx_cnt] = cap_byte;
                rx_cnt      = rx_cnt + 1;
            end
            #(BIT_NS / 2);                     // 停在停止位中心（9.0 bit），
                                               // 留出半位余量再等下一个起始位
        end
    end

    task chk;
        input         cond;
        input [255:0] id;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display(" [FAIL] %0s  (t=%0t)", id, $time);
            end
        end
    endtask

    // ---- UART 8N1 发送：1 位起始 + 8 位数据（LSB 先）+ 1 位停止 -------------
    task uart_byte;
        input [7:0] b;
        begin
            uart_rx = 1'b0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i];
                #(BIT_NS);
            end
            uart_rx = 1'b1;
            #(BIT_NS);
        end
    endtask

    // ---- 一帧写命令：[0x80|0x08|page, addr_lo, data_hi, data_lo] ------------
    task wr16;
        input [10:0]  addr;
        input [15:0]  data;
        begin
            uart_byte(8'h80 | 8'h08 | ((addr >> 8) & 8'h07));
            uart_byte(addr[7:0]);
            uart_byte(data[15:8]);
            uart_byte(data[7:0]);
            // 桥的一条写命令 = 收 4 字节 + SPI 1 帧 10.56us + 回 6 字节 30us
            // （5 Mbaud 下一字节 10 bit = 2us），合计约 50us；留 200us 余量，
            // 否则下一条命令的字节会落在 C_SPI1/C_REPLY 里被丢掉。
            #(BIT_NS * 1000);
        end
    endtask

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        $display("================================================================");
        $display(" tb_dump_start -- dump request latch / start path");
        $display("================================================================");

        // 等上电复位自然释放
        timeout = 0;
        while (dut.rst_n !== 1'b1 && timeout < 2000) begin
            @(posedge sys_clk);
            timeout = timeout + 1;
        end
        chk(dut.rst_n === 1'b1, "D1-reset-released");
        repeat (2000) @(posedge sys_clk);     // 让遥测/桥进入稳定节拍

        // ---- 1) 配置：128 点、立即触发、无预触发 -------------------------
        wr16(11'h71A, CAP_PTS[15:0]);         // CAP_LEN
        wr16(11'h71C, 16'd0);                 // CAP_TRIG = 立即
        wr16(11'h71E, 16'd0);                 // CAP_LEVEL
        wr16(11'h720, 16'd0);                 // CAP_PRE
        wr16(11'h718, 16'd0);                 // CAP_SRC: 原始 50 MSPS, dec=0
        wr16(11'h722, 16'd1);                 // CAP_CTRL: arm

        timeout = 0;
        while (dut.cap_st_done !== 1'b1 && timeout < 20000) begin
            @(posedge sys_clk);
            timeout = timeout + 1;
        end
        chk(dut.cap_st_done === 1'b1, "D2-capture-done");
        chk(dut.cap_len_eff_w === CAP_PTS[15:0], "D3-cap-len-eff-128");

        // ---- 2) 门控被占住时写 DUMP_CTRL：请求必须被锁存而不是丢掉 ------
        force dut.scope_idle_w = 1'b0;
        repeat (20) @(posedge sys_clk);
        wr16(11'h72E, 16'd1);                 // DUMP_CTRL: start

        repeat (200000) @(posedge sys_clk);   // 4 ms，远大于一个遥测帧
        chk(dut.u_dump.busy === 1'b0, "D4-dump-not-started-while-gated");
        chk(dut.dump_req === 1'b1,   "D5-request-latched-while-gated");

        // ---- 3) 放开闸门：dump 必须启动并送完 2 块 -----------------------
        capture_en = 1'b1;
        release dut.scope_idle_w;
        timeout = 0;
        dump_start_cycles = 0;
        while (dut.u_dump.busy !== 1'b1 && timeout < 200000) begin
            @(posedge sys_clk);
            timeout = timeout + 1;
            dump_start_cycles = dump_start_cycles + 1;
        end
        chk(dut.u_dump.busy === 1'b1, "D6-dump-starts-after-gate-release");

        timeout = 0;
        while (dut.u_dump.done !== 1'b1 && timeout < 800000) begin
            @(posedge sys_clk);
            timeout = timeout + 1;
        end
        chk(dut.u_dump.done === 1'b1, "D7-dump-done");
        chk(dut.u_dump.blocks_done === 16'd2, "D8-blocks-done-2");

        // ---- 4) 线上字节流：块头 / 块号 / 点数 / XOR 校验 -----------------
        //    每块 = 7 B 头 (AA 55 A2 10 | blk_lo | blk_hi | n)
        //          + 64 x 4 B 小端载荷 + 1 B XOR(前 263 B) = 264 B。
        #(BIT_NS * 40);
        capture_en = 1'b0;
        hdr_found  = 1'b0;
        hdr_pos    = 0;
        for (i = 0; i <= rx_cnt - 4; i = i + 1) begin
            if (!hdr_found && rxb[i] === 8'hAA && rxb[i+1] === 8'h55 &&
                rxb[i+2] === 8'hA2 && rxb[i+3] === 8'h10) begin
                hdr_found = 1'b1;
                hdr_pos   = i;
            end
        end
        chk(hdr_found === 1'b1, "D9-dump-header-on-wire");
        if (hdr_found) begin
            chk(rx_cnt >= hdr_pos + 528, "D10-two-blocks-on-wire");
            for (k = 0; k < 2; k = k + 1) begin
                base = hdr_pos + k * 264;
                chk(rxb[base+0] === 8'hAA && rxb[base+1] === 8'h55 &&
                    rxb[base+2] === 8'hA2 && rxb[base+3] === 8'h10,
                    "D11-block-header-magic");
                chk(rxb[base+4] === (k % 256) && rxb[base+5] === 8'h00,
                    "D12-block-index");
                chk(rxb[base+6] === 8'd64, "D13-block-points");
                xacc = 8'h00;
                for (i = 0; i < 263; i = i + 1) xacc = xacc ^ rxb[base + i];
                $display("  blk%0d: n=%0d chk_wire=%02h chk_calc=%02h",
                         k, rxb[base+6], rxb[base+263], xacc);
                chk(rxb[base+263] === xacc, "D14-block-xor-checksum");
            end
        end
        $display("  dump bytes captured: %0d (header at %0d)", rx_cnt, hdr_pos);

        $display("  dump start latency after release: %0d cycles", dump_start_cycles);
        $display("================================================================");
        if (fail_cnt == 0)
            $display(" TEST PASSED (%0d checks)", pass_cnt);
        else
            $display(" TEST FAILED: %0d failed / %0d checks", fail_cnt, pass_cnt + fail_cnt);
        $display("================================================================");
        $finish;
    end

    initial begin
        #50_000_000;                          // 50 ms 兜底
        $display(" [FAIL] global timeout");
        $finish;
    end

endmodule
