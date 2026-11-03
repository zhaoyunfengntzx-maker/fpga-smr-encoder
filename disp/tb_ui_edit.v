//=============================================================================
//  tb_ui_edit.v —— disp/ui_edit.v 的自检台
//-----------------------------------------------------------------------------
//  这个台子回答三个问题，每个问题对应线上真实会发生的故障：
//    T1  正常：写 64 -> 回读 64 -> ST_OK，且线上字节**逐字节**符合
//        rtl/uart_spi_bridge.v:16-21 的命令格式（89 01 00 40）。
//    T2  写根本没进去（桥没收到 / 从机不应答 / 链路假死）：
//        回读还是旧值 -> 必须自动回滚 -> ST_FAILED + ERR_MISMATCH，
//        并且回滚那条命令发的必须是**旧值**，不是目标值。
//    T3  写进去了但值不对（亚稳态/位错）：
//        回滚写旧值，而寄存器被模型弄坏了 -> ERR_RB_FAIL。
//  模型故意做得像 rtl/reg_file.v 的真身：
//    cfg_inter = {r_inter1[1:0], r_inter0[7:0]};  cfg_div = r_inter1[4:2];
//  命令解码器故意只用 uart_spi_bridge 的**字节级**定义，不引用被测代码，
//  这样"线上发对了没有"是独立判据，而不是自证。
//=============================================================================
`timescale 1ns / 1ps

module tb_ui_edit;

    // ---------------- 时钟 ----------------
    localparam integer CLK_P     = 20;      // 50 MHz
    localparam integer BAUD_DIV  = 25;      // 2 Mbaud
    localparam integer GAP_CLK   = 200;     // 4 µs（真值 4000，仿真缩小）
    localparam integer SETTLE_CLK= 1000;    // 20 µs（真值 100000）
    localparam integer RBE_DELAY = 120;     // 仿真桥的往返延迟

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_P/2) clk = ~clk;

    integer errors = 0;
    task chk;
        input        cond;
        input [255:0] name;
        begin
            if (cond) $display("  [ok]   %0s", name);
            else begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    // ---------------- 被测模块 ----------------
    reg         req = 1'b0;
    reg  [9:0]  inter_enc = 10'd0;
    reg  [2:0]  div_code  = 3'd0;
    wire [9:0]  tap_inter;
    wire [2:0]  tap_div;
    wire        tx_line;
    wire        tx_busy;
    wire [1:0]  state;
    wire        done;
    wire [9:0]  ok_inter;
    wire [2:0]  ok_div;
    wire [3:0]  err_code;
    wire [15:0] txn_cnt, fail_cnt;

    ui_edit #(
        .BAUD_DIV   (BAUD_DIV),
        .GAP_CLK    (GAP_CLK),
        .SETTLE_CLK (SETTLE_CLK)
    ) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (req),
        .inter_enc (inter_enc),
        .div_code  (div_code),
        .tap_inter (tap_inter),
        .tap_div   (tap_div),
        .tx_line   (tx_line),
        .tx_busy   (tx_busy),
        .state     (state),
        .done      (done),
        .ok_inter  (ok_inter),
        .ok_div    (ok_div),
        .err_code  (err_code),
        .txn_cnt   (txn_cnt),
        .fail_cnt  (fail_cnt)
    );

    // ---------------- 寄存器模型（照 rtl/reg_file.v:559-560 的位序）----------------
    localparam integer MODE_NORMAL  = 0;
    localparam integer MODE_DROP    = 1;    // 写不进去
    localparam integer MODE_CORRUPT = 2;    // 写进去但值不对
    integer mode = MODE_NORMAL;

    reg [7:0] r_inter0 = 8'h00;
    reg [7:0] r_inter1 = 8'h00;

    assign tap_inter = {r_inter1[1:0], r_inter0[7:0]};
    assign tap_div   = r_inter1[4:2];

    // ---------------- 线上命令解码（只用桥的字节级定义）----------------
    reg [7:0]  rxsh;
    integer    i;
    reg [7:0]  cmd_b0, cmd_b1, cmd_b2, cmd_b3;
    integer    nbyte = 0;
    reg [15:0] cmd_addr, cmd_data;
    reg        cmd_is_wr;
    reg        cmd_valid;
    integer    cmd_count = 0;
    reg [7:0]  hist [0:7];           // 最近 8 个字节，失败时打印出来
    integer    hist_n = 0;

    initial begin
        rxsh = 8'd0;
        cmd_valid = 1'b0;
        forever begin
            @(negedge tx_line);                 // 起始位
            #(BAUD_DIV/2 * CLK_P);              // 到起始位中点
            for (i = 0; i < 8; i = i + 1) begin
                #(BAUD_DIV * CLK_P);            // 下一位的中点
                rxsh[i] = tx_line;              // LSB 先收
            end
            #(BAUD_DIV * CLK_P);                // 停止位中点：顺手查帧错
            if (tx_line !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] UART 停止位不是 1（发送侧帧错）");
            end
            @(posedge clk);
            // 攒 4 个字节 = 一条命令
            if (nbyte == 0)      cmd_b0 = rxsh;
            else if (nbyte == 1) cmd_b1 = rxsh;
            else if (nbyte == 2) cmd_b2 = rxsh;
            else begin
                cmd_b3 = rxsh;
                // b0 = {st=1, rm[1:0], wm[1:0], page[2:0]}
                cmd_addr  = {5'd0, cmd_b0[2:0], cmd_b1};
                cmd_data  = {cmd_b2, cmd_b3};
                cmd_is_wr = cmd_b0[3];
                @(posedge clk);
                cmd_valid = 1'b1;
                @(posedge clk);
                cmd_valid = 1'b0;
            end
            if (hist_n < 8) begin hist[hist_n] = rxsh; hist_n = hist_n + 1; end
            nbyte = (nbyte == 3) ? 0 : (nbyte + 1);
        end
    end

    // ---------------- 模型应用（延迟 = 仿真桥的往返）----------------
    initial begin
        forever begin
            @(posedge cmd_valid);
            cmd_count = cmd_count + 1;
            repeat (RBE_DELAY) @(posedge clk);
            if (mode == MODE_DROP) begin
                // 桥没收到：寄存器一个字节都不动
            end
            else if (mode == MODE_CORRUPT) begin
                r_inter0 <= (cmd_data[7:0] ^ 8'h01);   // 值被弄错
                r_inter1 <= cmd_data[15:8];
            end
            else begin
                r_inter0 <= cmd_data[7:0];
                r_inter1 <= cmd_data[15:8];
            end
        end
    end

    // ---------------- 发一次请求并等 done ----------------
    task do_req;
        input [9:0] i_enc;
        input [2:0] d_code;
        begin
            @(negedge clk);
            inter_enc = i_enc;
            div_code  = d_code;
            req       = 1'b1;
            @(negedge clk);
            req       = 1'b0;
            @(posedge done);
            @(posedge clk);
        end
    endtask

    task dump_hist;
        integer k;
        begin
            $write("    线上字节: ");
            for (k = 0; k < hist_n; k = k + 1) $write("%02X ", hist[k]);
            $write("\n");
        end
    endtask

    // ---------------- T5 专用：W1C 通道（VERIFY=0）----------------
    //   disp/enc_top_disp.v 里为了"清除锁存故障"（0x0405 写 1 清）例化了**第二个**
    //   ui_edit，只换三个参数：地址换成 0x0405、关掉回读校验。
    //   为什么必须关校验（写进模块头的那条）：0x0405 是 W1C —— 清成功之后回读是
    //   0，而写进去的是 1 ⇒ P_CHECK 的"逐位相等"永远不成立，会走回滚分支把
    //   {old_inter, old_div} 又写回 0x0101/0x0102（顺手改掉倍频/分频）。
    //   而且 0x0405 根本不在这条 disp_tap 的 311 位上，本来也无从回读。
    reg         w1c_req = 1'b0;
    wire        w1c_tx, w1c_busy, w1c_done;
    wire [1:0]  w1c_state;
    wire [3:0]  w1c_err;

    ui_edit #(
        .BAUD_DIV   (BAUD_DIV),
        .GAP_CLK    (GAP_CLK),
        .SETTLE_CLK (SETTLE_CLK),
        .CMD_B0     (8'h80 | 8'h08 | 8'h04),   // st=1 wm=01 page=100 -> 地址 0x04xx
        .CMD_B1     (8'h05),                   // 地址低字节 -> 0x0405
        .VERIFY     (0)
    ) u_w1c (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (w1c_req),
        .inter_enc (10'd1),                    // b3 = 0x01 = 写进 0x0405 的值
        .div_code  (3'd0),                     // b2 = 0x00 = 落到 0x0406（只读，写 0 无害）
        .tap_inter (tap_inter),                // 读回值本通道不用（VERIFY=0）
        .tap_div   (tap_div),
        .tx_line   (w1c_tx),
        .tx_busy   (w1c_busy),
        .state     (w1c_state),
        .done      (w1c_done),
        .ok_inter  (),
        .ok_div    (),
        .err_code  (w1c_err),
        .txn_cnt   (),
        .fail_cnt  ()
    );

    reg [7:0] w1c_b0, w1c_b1, w1c_b2, w1c_b3;
    integer   w1c_n = 0;
    integer   w1c_cmds = 0;
    integer   w1c_i;
    reg [7:0] w1c_rxsh;

    initial begin
        w1c_rxsh = 8'd0;
        forever begin
            @(negedge w1c_tx);
            #(BAUD_DIV/2 * CLK_P);
            for (w1c_i = 0; w1c_i < 8; w1c_i = w1c_i + 1) begin
                #(BAUD_DIV * CLK_P);
                w1c_rxsh[w1c_i] = w1c_tx;
            end
            #(BAUD_DIV * CLK_P);
            if (w1c_n == 0)      w1c_b0 = w1c_rxsh;
            else if (w1c_n == 1) w1c_b1 = w1c_rxsh;
            else if (w1c_n == 2) w1c_b2 = w1c_rxsh;
            else                 w1c_b3 = w1c_rxsh;
            if (w1c_n == 3) begin
                w1c_n    = 0;
                w1c_cmds = w1c_cmds + 1;
            end else begin
                w1c_n = w1c_n + 1;
            end
        end
    end

    // ---------------- 主流程 ----------------
    initial begin
        $display("=== tb_ui_edit ===");
        req = 0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // =============== T1：正常提交 ===============
        $display("-- T1 正常提交：64 / div1 --");
        mode = MODE_NORMAL;
        hist_n = 0; cmd_count = 0;
        do_req(10'd64, 3'd0);
        chk(state == 2'd2,            "T1 state == ST_OK");
        chk(ok_inter == 10'd64,       "T1 ok_inter == 64（回读确认值）");
        chk(ok_div == 3'd0,           "T1 ok_div == 0（÷1）");
        chk(err_code == 4'd0,         "T1 err_code == 0");
        chk(tap_inter == 10'd64,      "T1 寄存器真的变成 64");
        chk(cmd_count == 1,           "T1 只发了一条命令（成功不重发）");
        dump_hist;
        chk((hist[0] == 8'h89) && (hist[1] == 8'h01) &&
            (hist[2] == 8'h00) && (hist[3] == 8'h40),
            "T1 线上 = 89 01 00 40（桥的命令格式）");

        // =============== T2：写不进去 -> 自动回滚 ===============
        $display("-- T2 写不进去：请求 128，回读应仍是 64 --");
        mode = MODE_DROP;
        hist_n = 0; cmd_count = 0;
        do_req(10'd128, 3'd0);
        chk(state == 2'd3,            "T2 state == ST_FAILED");
        chk(err_code == 4'd1,         "T2 err_code == ERR_MISMATCH");
        chk(ok_inter == 10'd64,       "T2 ok_inter 仍是旧值 64（绝不是 128）");
        chk(tap_inter == 10'd64,      "T2 寄存器没被改动");
        chk(cmd_count == 2,           "T2 发了 2 条命令（目标 + 回滚）");
        dump_hist;
        chk((hist[4] == 8'h89) && (hist[5] == 8'h01) &&
            (hist[6] == 8'h00) && (hist[7] == 8'h40),
            "T2 第 2 条命令发的是**旧值** 64 而不是目标 128");
        chk((hist[2] == 8'h00) && (hist[3] == 8'h80),
            "T2 第 1 条命令发的才是目标 128");

        // =============== T3：回滚也回不去 ===============
        $display("-- T3 值被弄坏：回滚写旧值，但寄存器被模型破坏 --");
        mode = MODE_CORRUPT;
        hist_n = 0; cmd_count = 0;
        do_req(10'd128, 3'd0);
        chk(state == 2'd3,            "T3 state == ST_FAILED");
        chk(err_code == 4'd2,         "T3 err_code == ERR_RB_FAIL");
        chk(tap_inter != 10'd128,     "T3 寄存器不是目标值（链路有故障）");

        // =============== T4：走一遍正常路径，确认能恢复 ===============
        $display("-- T4 链路恢复后再提交一次 256（编码 0）--");
        mode = MODE_NORMAL;
        hist_n = 0; cmd_count = 0;
        do_req(10'd0, 3'd0);          // inter=256 编码为 0
        chk(state == 2'd2,            "T4 state == ST_OK");
        chk(ok_inter == 10'd0,        "T4 ok_inter == 0（= 256×）");
        chk(tap_inter == 10'd0,       "T4 寄存器 = 0（abz_gen 视为 256）");
        dump_hist;

        // =============== T5：W1C 通道（VERIFY=0，P6 危险区那条路）===============
        $display("-- T5 W1C 通道：线上必须是 8C 05 00 01，且只有这一条命令 --");
        w1c_cmds = 0;  w1c_n = 0;
        @(negedge clk); w1c_req = 1'b1;
        @(negedge clk); w1c_req = 1'b0;
        @(posedge w1c_done);
        repeat (4) @(posedge clk);
        chk(w1c_state == 2'd2,  "T5 state == ST_OK（VERIFY=0：不拿回读判成败）");
        chk(w1c_err   == 4'd0,  "T5 err_code == 0（没有回滚、没有失败）");
        chk(w1c_cmds  == 1,     "T5 只发一条命令（W1C 清成功时回读是 0，绝不能回滚）");
        chk((w1c_b0 == 8'h8C) && (w1c_b1 == 8'h05) && (w1c_b2 == 8'h00) && (w1c_b3 == 8'h01),
            "T5 线上 = 8C 05 00 01（0x0405 <- 1；b2 落在只读的 0x0406）");

        repeat (20) @(posedge clk);
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #(200_000 * CLK_P);
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
