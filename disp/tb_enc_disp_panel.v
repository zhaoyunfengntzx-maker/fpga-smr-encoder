// =============================================================================
//  disp/tb_enc_disp_panel.v —— 「编码器 + 显示」顶层（disp/enc_top_disp.v）
//                             编辑面板接线的集成测试（v22 / 批次④）
// -----------------------------------------------------------------------------
//  为什么还需要这个台子：批次④ 的四层各自都有单测 ——
//      disp/tb_ui_panel.v     面板状态机（吸附/点按/长按/拖拽/两阶段收尾）
//      disp/tb_hit_test.v     命中层生命周期（held / rel_stb / cur_x,y）
//      disp/tb_val_format.v   待应用值 vs 回读值（spec 6.2 的屏幕侧判据）
//      disp/tb_disp_engine.v  面板像素（框/步进按钮/滑条/进度环/命令按钮）
//    但"谁连谁、什么条件下受理"只写在 disp/enc_top_disp.v 这一份实现里 ——
//    U-26 的第一版就栽在这里：ui_panel 的 page 语义与 enc_top_disp 传进去的
//    相反（29 个断言才发现面板压根没开）。本台子把这条线钉住：
//      点 P1 卡片 2 → 面板开（且待应用值吸附到当前值）
//      → 面板开着时点导航不翻页
//      → [+] 改待应用值（pnl_pend = 1）
//      → APPLY（走 ui_edit 的两阶段提交：写进 enc_top 的 reg_file，
//        再由 disp_tap 回读回来）⇒ 寄存器 == 面板请求的值 + 记住上一次值
//      → BACK ⇒ 寄存器回到写之前的值
//      → CANCEL ⇒ 一个请求都不发
//      → P6 危险区两颗按钮（v42/㊴）：第 2 颗"恢复默认"的完整链路 ——
//        询问态（kind=1）不写寄存器 → OK ⇒ 屏侧 13 条命令 52 字节真的进
//        enc_top 的 reg_file → disp_tap 回读 17 项一致 ⇒ 绿灯 + 抽头回默认。
//        这一条是"提示而不提交/提交了才算数"（spec §6.2/§6.4）的最终证据。
// -----------------------------------------------------------------------------
//  ★ 两处 force（只影响本次仿真，不改 RTL）：
//    ① u_dut.u_enc.por_cnt：enc_top 的上电复位计数器（rtl/enc_top.v:68 的
//       POR_BITS 默认 20 ⇒ 21 ms / 约 105 万拍）。POR_BITS 是 enc_top 的
//       顶层参数，而 disp/enc_top_disp.v:120 例化时没有把它引出来，本台子
//       又只验证显示侧接线，因此直接把计数器强制到终值，省掉这段上电计数。
//    ② u_dut.tch_x0 / tch_y0 / tch_num / tch_toggle：真实触点要经 I2C 时序
//       （disp/touch_ctrl.v + disp/sim/iic_slave_model.v），而那个从机模型的
//       触点坐标与点数都是**编译期常量**（只能给固定的 5 个点、且无法表达
//       "抬起"），做不了"按下-抬起-再按另一处"。触摸控制器本身另有单测
//       （disp/tb_touch_ctrl.v），这里直接给命中层喂快照，把要验证的
//       "策略 + 接线"隔离出来。
//  ★ 本台子**不覆盖**：I2C 触点解析（tb_touch_ctrl）、UART 字节格式
//    （tb_ui_edit）、面板像素（tb_disp_engine）、面板 FSM 细节（tb_ui_panel）。
//    ★ v42（㊴）第 11 段会**主动**在物理 `uart_rx` 引脚上发一条上位机命令
//      （2 Mbaud，与 rtl/enc_top.v:58 的 BAUD_DIV=25 同速），用来把寄存器写脏；
//      其余段它一直保持空闲高电平。
// =============================================================================
//  ★ 本台子必须在 `--define ENC_DISP_TAP` 下编译：rtl/enc_top.v 的 disp_tap
//    端口被 `ifdef ENC_DISP_TAP 门控（rtl/enc_top.v:116 的注释写了原因），没有
//    这个宏时 disp/enc_top_disp.v 根本精化不了。这也是本仓库全量回归的既定命令：
//      python tools\run_sim_disp.py --define ENC_DISP_TAP
//    缺宏时下面给出一次明确的 FAIL，而不是静默空跑（"报 PASS 却什么都没检查"
//    是 disp/tb_touch_ctrl.v:28 记过的坑）。
// =============================================================================
`ifndef ENC_DISP_TAP
module tb_enc_disp_panel;
    initial begin
        $display("[FAIL] tb_enc_disp_panel 需要 --define ENC_DISP_TAP");
        $display("       rtl/enc_top.v 的 disp_tap 端口被 `ifdef ENC_DISP_TAP 门控，");
        $display("       未定义该宏时 disp/enc_top_disp.v 无法精化。");
        $display("       正确命令：python tools\\run_sim_disp.py --define ENC_DISP_TAP");
        $display("TEST FAILED: 1 errors");
        $finish;
    end
endmodule
`else
`timescale 1ns / 1ps

module tb_enc_disp_panel;

    localparam integer CLK_HALF = 10;              // 20 ns 周期 = 50 MHz

    integer errors = 0;

    // ---------------------------------------------------------------------
    //  1. 时钟与板级输入（用不到的输入全部摆到"不动作"电平）
    // ---------------------------------------------------------------------
    reg sys_clk = 1'b0;
    always #CLK_HALF sys_clk = ~sys_clk;

    reg         key_n    = 1'b1;
    reg         key1_n   = 1'b1;
    reg         ui_btn   = 1'b1;
    reg  [11:0] ad_ch1_d = 12'h800;                // 中位码：本台子不看编码器输出
    reg  [11:0] ad_ch2_d = 12'h800;
    reg         ad_ch1_otr = 1'b0;
    reg         ad_ch2_otr = 1'b0;
    reg         spi_sck  = 1'b0;
    reg         spi_ss_n = 1'b1;
    reg         spi_mosi = 1'b0;
    reg         uart_rx  = 1'b1;                   // 物理串口空闲（第 11 段才发字节）

    wire        ad_clk, ad_clk2;
    wire        a_out, b_out, z_out, u_out, v_out, w_out;
    wire [3:0]  led;
    wire        uart_tx, irq_n;
    wire [23:0] lcd_rgb;
    wire        lcd_pclk, lcd_hs, lcd_vs, lcd_de, lcd_bl, lcd_rst;
    wire        touch_rst_n;
    wire [7:0]  disp_test;
    wire        touch_scl, touch_sda, touch_int;

    pullup (touch_scl);
    pullup (touch_sda);
    pullup (touch_int);

    enc_top_disp u_dut (
        .sys_clk      (sys_clk),
        .key_n        (key_n),
        .key1_n       (key1_n),
        .ui_btn       (ui_btn),
        .ad_clk       (ad_clk),
        .ad_clk2      (ad_clk2),
        .ad_ch1_d     (ad_ch1_d),
        .ad_ch2_d     (ad_ch2_d),
        .ad_ch1_otr   (ad_ch1_otr),
        .ad_ch2_otr   (ad_ch2_otr),
        .a_out        (a_out),
        .b_out        (b_out),
        .z_out        (z_out),
        .u_out        (u_out),
        .v_out        (v_out),
        .w_out        (w_out),
        .spi_sck      (spi_sck),
        .spi_ss_n     (spi_ss_n),
        .spi_mosi     (spi_mosi),
        .spi_miso     (spi_miso),
        .led          (led),
        .uart_tx      (uart_tx),
        .uart_rx      (uart_rx),
        .irq_n        (irq_n),
        .lcd_rgb      (lcd_rgb),
        .lcd_pclk     (lcd_pclk),
        .lcd_hs       (lcd_hs),
        .lcd_vs       (lcd_vs),
        .lcd_de       (lcd_de),
        .lcd_bl       (lcd_bl),
        .lcd_rst      (lcd_rst),
        .touch_scl    (touch_scl),
        .touch_sda    (touch_sda),
        .touch_rst_n  (touch_rst_n),
        .touch_int    (touch_int),
        .disp_test    (disp_test)
    );

    // ---------------------------------------------------------------------
    //  2. 触摸注入（force 快照，见文件头 ①②）
    //     tch_num = 0 表示抬起、≠0 表示有接触；每次"新样本"都翻 tch_toggle。
    // ---------------------------------------------------------------------
    reg [1:0] tg = 2'd0;

    task tch_sample;
        input [11:0] sx, sy;
        input        down;
        begin
            @(negedge sys_clk);                    // 力施加在两个时钟沿之间，避免与
            tg = ~tg;                              // hit_test 的 always 抢同一时间步
            force u_dut.tch_x0     = {4'h0, sx};
            force u_dut.tch_y0     = {4'h0, sy};
            force u_dut.tch_num    = down ? 3'd1 : 3'd0;
            force u_dut.tch_toggle = tg[0];
            @(posedge sys_clk);
            @(posedge sys_clk);
        end
    endtask

    //  一次完整点按：按下 → 停几拍 → 抬起 → 停几拍
    task tch_tap;
        input [11:0] sx, sy;
        integer k;
        begin
            tch_sample(sx, sy, 1'b1);
            for (k = 0; k < 6; k = k + 1) @(posedge sys_clk);
            tch_sample(sx, sy, 1'b0);
            for (k = 0; k < 6; k = k + 1) @(posedge sys_clk);
        end
    endtask

    // ---------------------------------------------------------------------
    //  3. 判定小工具（沿用 disp/tb_ui_panel.v 的写法）
    // ---------------------------------------------------------------------
    task chk_true;
        input [8*72-1:0] label;
        input            cond;
        begin
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("[FAIL] %0s", label);
            end else begin
                $display("[ OK ] %0s", label);
            end
        end
    endtask

    task chki;
        input [8*72-1:0] label;
        input integer    got, want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s : got %0d want %0d", label, got, want);
            end else begin
                $display("[ OK ] %0s = %0d", label, got);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    //  3b. 2 Mbaud UART 收发工具（v42 / ㊴ 第 11 段用）
    //      与 disp/ui_edit.v / disp/ui_restore.v 的字节层同一套约定：
    //        b0 = 8'h80 | 8'h08 | addr[10:8]   （"写、2 字节有效载荷"的地址高 3 位）
    //        b1 = addr[7:0]
    //        b2 = data[15:8] -> addr+1
    //        b3 = data[7:0]  -> addr
    //      ⇒ 一条命令写两个**连续**寄存器。第 11 段用它们做两件事：以"上位机"
    //      身份把某个寄存器写脏（走物理 uart_rx，rtl/enc_top.v:58 的 BAUD_DIV=25
    //      就是 2 Mbaud），以及以"观察者"身份收下屏侧发出的 52 字节。
    // ---------------------------------------------------------------------
    localparam integer BIT_NS = 500;               // CLK_HALF*2*25 = 500 ns（2 Mbaud）

    task uart_send_byte;                           // 在物理 uart_rx 引脚上发一个字节
        input [7:0] b;
        integer i;
        begin
            uart_rx = 1'b0;                        // start
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin    // 8 位数据，LSB 先
                uart_rx = b[i];
                #(BIT_NS);
            end
            uart_rx = 1'b1;                        // stop
            #(BIT_NS);
        end
    endtask

    task uart_send_cmd;                            // 上位机的一条"写两个寄存器"
        input [10:0] a;
        input [15:0] d;
        begin
            uart_send_byte(8'h80 | 8'h08 | {5'd0, a[10:8]});
            uart_send_byte(a[7:0]);
            uart_send_byte(d[15:8]);
            uart_send_byte(d[7:0]);
        end
    endtask

    //  接收模型：等起始位下降沿 -> 跳到 bit0 中心 -> 每 500 ns 采一位。
    //  与 disp/tb_ui_restore.v 里那条已经跑通的写法一致（那个台同时验过屏侧发送）。
    //  ★ 顺便在**起始位那一拍**抓两样东西（v42/㊴ 第 11 段的两条真缺陷都出在这里）：
    //      · byte_start_t  = 该字节起始位的时刻 -> 用来量"命令之间的线路空闲"；
    //      · byte_start_cs = 该时刻桥的状态机（u_dut.u_enc.u_bridge.cs）
    //        —— rtl/uart_spi_bridge.v 只在 C_IDLE/C_BYTE 里消费 rx_valid，
    //        首字节如果落在 C_SPI1/C_REPLY/C_TX（内部 SPI 帧 + 等遥测空闲 +
    //        6 字节应答，最坏 ~160 µs）就被**整条丢掉**。
    time       byte_start_t = 0;
    integer    byte_start_cs = 0;
    integer    cmd_gap_min  = 1000000000;          // 命令间隔最小值（ns）
    integer    cs_bad       = 0;                   // 首字节落在桥的非 C_IDLE 态的次数
    time       prev_cmd_end_t = 0;
    integer    cmd_cnt      = 0;

    task uart_get_byte;
        output [7:0] b;
        integer i;
        begin
            @(negedge u_dut.enc_uart_rx);
            byte_start_t  = $time;
            byte_start_cs = u_dut.u_enc.u_bridge.cs;
            #(BIT_NS + BIT_NS/2);                  // start 位中心 -> bit0 中心
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = u_dut.enc_uart_rx;
                #(BIT_NS);
            end
        end
    endtask

    //  收一条命令的 4 个字节并与"黄金字节流"逐字节比对。这条流在三处必须一致：
    //  disp/ui_restore.v 的 load_cmd 表、disp/tb_ui_restore.v 的黄金流、这里。
    integer seq_ok = 0;
    task uart_expect_cmd;
        input [10:0] a;
        input [15:0] d;
        reg [7:0] g0, g1, g2, g3, r0, r1, r2, r3;
        begin
            g0 = 8'h80 | 8'h08 | {5'd0, a[10:8]};
            g1 = a[7:0];
            g2 = d[15:8];
            g3 = d[7:0];
            uart_get_byte(r0);
            //  首字节起始位那一拍的两条判据（见上面 uart_get_byte 的注释）
            if (byte_start_cs !== 3'd0) cs_bad = cs_bad + 1;
            if (cmd_cnt > 0) begin
                if ((byte_start_t - prev_cmd_end_t) < cmd_gap_min)
                    cmd_gap_min = byte_start_t - prev_cmd_end_t;
            end
            cmd_cnt = cmd_cnt + 1;
            uart_get_byte(r1);
            uart_get_byte(r2);
            uart_get_byte(r3);
            prev_cmd_end_t = byte_start_t + 10*BIT_NS;   // 本命令末字节的 stop 位结束
            if ({r0, r1, r2, r3} === {g0, g1, g2, g3}) begin
                seq_ok = seq_ok + 1;
            end else begin
                errors = errors + 1;
                $display("[FAIL] 恢复序列有条命令字节不符：got %h %h %h %h want %h %h %h %h",
                         r0, r1, r2, r3, g0, g1, g2, g3);
            end
        end
    endtask

    //  13 条命令，顺序 = disp/ui_restore.v 的 load_cmd 表（㊴ 的范围决定 A：
    //  P6 可见的 15 项 + 两个标定偏置，全部能在 disp_tap 上回读验证）。
    task uart_expect_restore_seq;
        begin
            seq_ok = 0;
            uart_expect_cmd(11'h100, 16'h0004);    // UVW_CFG（极对数）
            uart_expect_cmd(11'h101, 16'h0000);    // INTER0
            uart_expect_cmd(11'h102, 16'h0000);    // INTER1（倍频/分频）
            uart_expect_cmd(11'h106, 16'h0A00);    // ABLIMIT（+ 邻居 ZERO0 = 0x0A）
            uart_expect_cmd(11'h108, 16'h4000);    // ZERO1（+ 邻居 OUTPUT = 0x40）
            uart_expect_cmd(11'h10A, 16'h0000);    // ZPHASE
            uart_expect_cmd(11'h10C, 16'h0000);    // PHASE_LSB（Z / UVW 相位低位）
            uart_expect_cmd(11'h510, 16'h0000);    // OFS_S
            uart_expect_cmd(11'h512, 16'h0000);    // OFS_C
            uart_expect_cmd(11'h514, 16'h8000);    // GAIN_S
            uart_expect_cmd(11'h516, 16'h8000);    // GAIN_C
            uart_expect_cmd(11'h518, 16'h0000);    // PHASE_K（相位修正）
            uart_expect_cmd(11'h51A, 16'h0000);    // SHIFT（+ 邻居 H2_K = 0）
        end
    endtask

    //  等面板收起（APPLY / BACK / CANCEL 的收尾），最多等 250k 拍
    task wait_pnl_off;
        input [8*72-1:0] label;
        integer k;
        begin
            k = 0;
            while ((u_dut.pnl_on !== 1'b0) && (k < 250000)) begin
                @(posedge sys_clk);
                k = k + 1;
            end
            if (u_dut.pnl_on !== 1'b0) begin
                errors = errors + 1;
                $display("[FAIL] %0s : 面板没有收起（等了 %0d 拍）", label, k);
            end else begin
                $display("[ OK ] %0s （%0d 拍）", label, k);
            end
        end
    endtask

    //   v34（㊲）：等模态询问态收尾（W1C 事务是"数百 µs"级，比几个时钟长得多）。
    //   不先等它收尾，"按下不弹窗"这条判据会被**上一次**事务的忙碌态挡住，
    //   红/绿都说明不了问题 —— 量具自己也要把状态理干净。
    task wait_dlg_off;
        input [8*72-1:0] label;
        integer k;
        begin
            k = 0;
            while ((u_dut.dlg !== 2'd0) && (k < 250000)) begin
                @(posedge sys_clk);
                k = k + 1;
            end
            if (u_dut.dlg !== 2'd0) begin
                errors = errors + 1;
                $display("[FAIL] %0s : 对话框没有收尾（等了 %0d 拍）", label, k);
            end else begin
                $display("[ OK ] %0s （%0d 拍）", label, k);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    //  4. 面板请求观测（只读；用来断言"请求的值 == 寄存器最终的值"）
    // ---------------------------------------------------------------------
    integer    req_cnt = 0;
    reg [9:0]  req_seen_inter = 10'd0;
    reg [2:0]  req_seen_div   = 3'd0;

    always @(posedge sys_clk) begin
        if (u_dut.pnl_req) begin
            req_cnt        <= req_cnt + 1;
            req_seen_inter <= u_dut.pnl_req_inter;
            req_seen_div   <= u_dut.pnl_req_div;
        end
    end

    //  上一次写事务的观测值（在 wait_pnl_off 之后读）
    reg [9:0]  req1_inter = 10'd0;
    reg [9:0]  req2_inter = 10'd0;

    //  单拍脉冲观测：hit_stb / pnl_open_req 都是单拍，事后读不到 ⇒ 用锁存
    //  （断言只在整段结束时查"有没有发生过"，不参与时序判定）。
    integer    stb_cnt   = 0;
    reg [4:0]  last_id   = 5'd31;
    reg        open_seen = 1'b0;
    reg        pnl_seen  = 1'b0;

    always @(posedge sys_clk) begin
        if (u_dut.hit_stb) begin
            stb_cnt <= stb_cnt + 1;
            last_id <= u_dut.hit_id;
        end
        if (u_dut.pnl_open_req) open_seen <= 1'b1;
        if (u_dut.pnl_on)       pnl_seen  <= 1'b1;
    end

    //   v53（㊿）：页号变化次数 —— 第 8b 段的**反骗绿**判据。
    //   那一段一半的断言是"页号仍然是 0"（没翻页），如果翻页链路整个没接通，
    //   那些断言会全部假通过。数一数真的翻了几次，就能把"什么都没发生"排掉。
    integer    pg_chg  = 0;
    reg [2:0]  pg_last = 3'd0;
    always @(posedge sys_clk) begin
        if (u_dut.page !== pg_last) begin
            pg_last <= u_dut.page;
            pg_chg  <= pg_chg + 1;
        end
    end

    //   v33（㉝）：P6 危险区那条 **W1C 通道**的观测（0x0405 <- 1）。
    //   与 pnl_req 是两条不同的链路（策略层 dlg 状态机直接拉 w1c_req），
    //   所以单独计数：问"询问态有没有偷偷写寄存器"、也问"确认后有没有真的发"。
    integer    w1c_cnt   = 0;
    reg        w1c_seen  = 1'b0;
    always @(posedge sys_clk) begin
        if (u_dut.w1c_req) begin
            w1c_cnt  <= w1c_cnt + 1;
            w1c_seen <= 1'b1;
        end
    end

    //   v42（㊴）：屏侧发往 enc_top 这条链路上的**下降沿**计数（线上每个字节至少有
    //   一个下降沿 = 起始位；字节内部的数据位也可能给出下降沿，所以它**不是**
    //   字节数）。enc_uart_rx 是三路 mux 之后的**真实**接收线
    //   （disp/enc_top_disp.v:122-124），第 11 段用它判两件事：
    //     · CANCEL 之后这条线上一个下降沿都不该有（= 一个字节都没发）；
    //     · 收满 52 字节之后到事务收尾之间不该再有新的下降沿（= 没有第 53 个字节）。
    //   为什么不做"按起始位计字节"：disp/ui_restore.v:259 把**同一条命令的 4 个
    //   字节连着发**（只有 1 个位时间的线空闲），靠"线空闲足够久"来切字节会漏掉
    //   命令内部的 3 个字节 —— 字节数由 uart_expect_restore_seq 逐字节比对来钉，
    //   这台机器只负责"有没有活动"。
    integer    line_fall = 0;
    always @(negedge u_dut.enc_uart_rx) line_fall = line_fall + 1;
    integer    rsv0      = 0;                      // 比对用的快照
    integer    rsv1      = 0;
    // ---------------------------------------------------------------------
    //  5. 主序列
    // ---------------------------------------------------------------------
    reg [9:0] v0 = 10'd0;              // 上电后的倍频回读值（写之前）
    reg [9:0] v1 = 10'd0;              // [+] 之后的待应用值（= APPLY 要写的值）
    // v44（㊶）第 12 段：÷分频端到端用
    reg [9:0] iv0    = 10'd0;          // 第 12 段期间的倍频回读值（全程不该变）
    reg [2:0] dv0    = 3'd0;           // 起始分频回读码（div = 码 + 1）
    reg [2:0] dv1    = 3'd0;           // 走过一档之后的期望码
    reg       dir_up = 1'b1;           // 回读在 ÷8（码 7）时改按 [−]

    initial begin
        $display(" tb_enc_disp_panel —— enc_top_disp 编辑面板接线集成测试");

        // ---- 复位 ----
        key_n = 1'b0;
        repeat (20) @(posedge sys_clk);
        key_n = 1'b1;
        repeat (20) @(posedge sys_clk);

        // ---- 跳过 21 ms 上电计数（见文件头 ①）----
        force u_dut.u_enc.por_cnt = {20{1'b1}};
        repeat (200) @(posedge sys_clk);

        // ---- 触摸线初期状态：抬起、坐标给 (0,0) ----
        force u_dut.tch_x0     = 16'd0;
        force u_dut.tch_y0     = 16'd0;
        force u_dut.tch_num    = 3'd0;
        force u_dut.tch_toggle = 1'b0;

        v0 = u_dut.tap_inter;
        $display(" 上电后的倍频回读值 v0 = %0d（tap_div = %0d）", v0, u_dut.tap_div);

        // ---- 0) 还没碰屏幕：面板必须是关的 ----
        chk_true("面板初始关着", u_dut.pnl_on === 1'b0);
        chki("初始请求计数", req_cnt, 0);

        // ---- 1) 点 P1「倍频分频」卡（卡 2：x 416..703 / y 64..319）----
        tch_tap(12'd800, 12'd140);
        chk_true("点 P1 卡片 2 后面板打开", u_dut.pnl_on === 1'b1);
        chk_true("开面板时待应用值吸附到当前回读值（pnl_pend = 0）",
                 u_dut.pnl_pend === 1'b0);
        chk_true("开面板时没有发出写请求", req_cnt === 0);

        // ---- 2) 面板开着时点导航：不翻页、面板不关 ----
        tch_tap(12'd40, 12'd200);
        chki("面板开着时点导航不翻页", u_dut.page, 0);
        chk_true("面板仍然开着", u_dut.pnl_on === 1'b1);

        // ---- 3) [−]：改待应用值（按钮中心 x=192 / y=496）----
        //   ★ 先看清起点：上电回读 v0 = 0，而 ui_edit 的编码里 0 表示 ×256，
        //     也就是**最高档**。所以这里只能按 [−]（按 [+] 会被夹住不动，
        //     那会让后面的断言全部假失败）。
        tch_tap(12'd192, 12'd496);
        v1 = u_dut.pnl_inter;
        chk_true("[−] 之后出现待应用态（pnl_pend = 1）", u_dut.pnl_pend === 1'b1);
        chk_true("[−] 确实改变了待应用值", v1 !== v0);
        $display(" [−] 之后的待应用值 v1 = %0d", v1);

        // ---- 4) APPLY：两阶段提交 + 回读确认 ----
        tch_tap(12'd528, 12'd552);
        wait_pnl_off("APPLY 后面板收起");
        req1_inter = req_seen_inter;
        chki("APPLY 只发了一次写请求", req_cnt, 1);
        chk_true("请求的倍频 = 面板上的待应用值",
                 req_seen_inter === v1);
        chk_true("寄存器回读 = 面板请求的值（回读确认过才显示）",
                 u_dut.tap_inter === req_seen_inter);
        chk_true("APPLY 之后进入已应用态（pnl_pend = 0）", u_dut.pnl_pend === 1'b0);
        chk_true("记住上一次值（pnl_undo_avail = 1）", u_dut.pnl_undo_avail === 1'b1);
        chk_true("上一次值 = 写之前的值", u_dut.pnl_undo_inter === v0);

        // ---- 5) 重开面板 → BACK：写回上一次值 ----
        tch_tap(12'd800, 12'd140);
        chk_true("重开面板（点卡片 2）", u_dut.pnl_on === 1'b1);
        tch_tap(12'd800, 12'd552);                 // BACK
        wait_pnl_off("BACK 后面板收起");
        req2_inter = req_seen_inter;
        chki("BACK 也只发了一次写请求（累计 2）", req_cnt, 2);
        chk_true("BACK 请求的值 = 上一次值", req_seen_inter === v0);
        chk_true("BACK 之后寄存器回到写之前的值", u_dut.tap_inter === v0);
        chk_true("BACK 之后记忆换成 BACK 之前的值", u_dut.pnl_undo_inter === v1);

        // ---- 6) CANCEL：一个请求都不发 ----
        tch_tap(12'd800, 12'd140);
        chk_true("面板再次打开（CANCEL 段）", u_dut.pnl_on === 1'b1);
        tch_tap(12'd192, 12'd496);                 // [−]：制造待应用态
        chk_true("CANCEL 前有待应用态", u_dut.pnl_pend === 1'b1);
        tch_tap(12'd256, 12'd552);                 // CANCEL（x 176..336）
        wait_pnl_off("CANCEL 后面板收起");
        chki("CANCEL 一个写请求都没发（仍为 2）", req_cnt, 2);
        chk_true("CANCEL 之后寄存器没变", u_dut.tap_inter === v0);

        // ---- 7) 面板关着时不该受理面板按钮 ----
        tch_tap(12'd192, 12'd496);                 // 面板已关，这里只是 P1 空白区
        chk_true("面板关着时按 [−] 坐标不会开面板", u_dut.pnl_on === 1'b0);
        chki("面板关着时的请求计数不变", req_cnt, 2);

        // ---- 8) 反向判据：这一段不能"因为什么都没发生"而假通过 ----
        //   U-26 的教训：注入没生效时断言也可能全 OK（复位值恰好等于期望值）。
        chk_true("整段确实发生过按下事件（注入到达命中层）", stb_cnt >= 8);
        chk_true("面板打开事件确实发生过", pnl_seen === 1'b1);
        $display(" 观测：按下 %0d 次、最后一次编号 %0d、开请求 %b",
                 stb_cnt, last_id, open_seen);

        // =====================================================================
        // ---- 8b) v53（㊿）C1+C2：spec §4.6 的两条卡片下钻路径 ----
        //   §4.6 的导航图（docs/13_display_ui_requirements.md:195-204）写死三条：
        //     点卡片 2 → 编辑面板（v22 起，上面第 1 段钉着）；
        //     点卡片 6 → P4 逻辑时序；
        //     点卡片 3 → P7 标定与误差可视化。
        //   v20..v52 只有"卡片 2"与"标题带按钮"两条路在跑，卡片 3 的动作被删掉过
        //   （当时认为 §4.5 的卡片内容与 §4.6 的入口矛盾）；v53 改成双入口。
        //   卡片几何（disp/hit_test.v 的 CARD_X*/CARD_Y*/CARD_W/CARD_H）：
        //     列 x = 96 / 416 / 736，宽 288；行 y = 64 / 336，高 256。
        //     卡片 3 = 列2行0 → 中心 (880,192)；卡片 6 = 列2行1 → 中心 (880,464)。
        //   ★ 反向判据三条，防"翻页是因为别的原因"：
        //     ① 卡片 1/4/5 点了不翻页（它们是纯展示卡，spec 没给目的地）；
        //     ② 到了 P7 之后点卡片 6 的同坐标不翻页（卡片网格只在 P1 生效）；
        //     ③ 面板开着时点卡片 3 不翻页（模态让路，与导航/标题带同一条规矩）。
        //   ★ 最后一条是"双入口"的字面判据：标题带「标定」按钮**仍然**能到 P7。
        // =====================================================================
        chki("8b 起点 P1", u_dut.page, 0);
        tch_tap(12'd200, 12'd300);                     // 卡片 3 中心
        chki("8b 卡3 -> P7", u_dut.page, 6);
        tch_tap(12'd40, 12'd60);                       // 导航「总览」
        chki("8b 导航回 P1", u_dut.page, 0);
        tch_tap(12'd800, 12'd500);                     // 卡片 6 中心
        chki("8b 卡6 -> P4", u_dut.page, 3);
        tch_tap(12'd40, 12'd60);                       // 导航「总览」
        chki("8b 再回 P1", u_dut.page, 0);
        //   ① 纯展示卡不翻页
        tch_tap(12'd200, 12'd140);                     // 卡片 1
        chki("8b 卡1 不翻页", u_dut.page, 0);
        tch_tap(12'd200, 12'd500);                     // 卡片 4
        chki("8b 卡4 不翻页", u_dut.page, 0);
        tch_tap(12'd800, 12'd300);                     // 卡片 5
        chki("8b 卡5 不翻页", u_dut.page, 0);
        //   ③ 面板是模态：开着时卡片下钻必须让路
        tch_tap(12'd800, 12'd140);                     // 卡片 2（v59 右上）→ 开面板
        chk_true("8b 面板已开", u_dut.pnl_on === 1'b1);
        tch_tap(12'd200, 12'd300);                     // 面板开着时点卡片 3
        chki("8b 面板开时卡3不翻页", u_dut.page, 0);
        chk_true("8b 面板仍开着", u_dut.pnl_on === 1'b1);
        tch_tap(12'd256, 12'd552);                     // CANCEL（x 176..336）
        wait_pnl_off("8b CANCEL 后面板收起");
        chki("8b 点卡片没发写请求", req_cnt, 2);
        //   ② 卡片网格只在 P1 生效：到 P7 再点卡片 6 的同坐标
        tch_tap(12'd200, 12'd300);                     // 卡片 3 → P7
        chki("8b 再点卡3 -> P7", u_dut.page, 6);
        tch_tap(12'd800, 12'd500);                     // 同一坐标在 P7 上不是卡片
        chki("8b P7 上点卡6坐标不翻页", u_dut.page, 6);
        tch_tap(12'd40, 12'd60);                       // 导航「总览」
        chki("8b 导航回 P1 三次", u_dut.page, 0);
        //   双入口的另一半：标题带主操作按钮（命中区 x 660..819 / y 24..63）
        tch_tap(12'd740, 12'd44);
        chki("8b 标题带按钮仍到 P7", u_dut.page, 6);
        tch_tap(12'd40, 12'd60);                       // 导航「总览」，回到 P1 收尾
        chki("8b 收尾回 P1", u_dut.page, 0);
        //   反骗绿：本段至少翻过 6 次页（卡片 3/6、导航 3 次、标题带按钮）
        chk_true("8b 本段真的翻过页（>=6）", pg_chg >= 6);
        $display(" 8b 观测：页号变化 %0d 次", pg_chg);

        // =====================================================================
        // ---- 9) v33（㉝）：P6 危险区按钮的命中矩形（画框 64 px + ±8 px 触控外扩）----
        //   几何是两处共同契约：disp/disp_engine.v 的 DZ_BTN_*（画框，y 520..583）
        //   与 disp/enc_top_disp.v 的 DZ_HIT_*（判定，画框 ±8 px ⇒ y 512..591）。
        //   本段专门钉**两者的差**：外扩区内必须受理、扩展区外（哪怕还在 96 px 的
        //   危险区里）必须不受理。只测按钮中心的写法在旧几何（y 528..592）下
        //   同样全绿，一点回归能力都没有 —— 这正是 ㉜ 那条"假绿"教训的用法。
        //   ★ v42（㊴）：画框从"1 颗 x 192..640"改成"两颗 x 180..591 / 608..1019"
        //     ⇒ 命中区 X 也跟着从 184..647 挪到 **172..599**。这一组左右判据就是
        //     钉这次挪动的：x 176 在画框外、命中区内；x 164 两边都不是。
        //     （漏改命中区的后果见 disp/enc_top_disp.v 的 DZ_HIT_* 注释：第 2 颗
        //     按钮左起 40 px 会误触第 1 颗的动作，第 11 段专门钉这一条。）
        //   page 是 enc_top_disp 的内部状态（本测试台只按坐标注入，翻页要走 20 ms
        //   去抖的实体键），所以这里直接 force 到 P6，段末 release。
        // =====================================================================
        force u_dut.page = 3'd5;
        repeat (4) @(posedge sys_clk);

        tch_tap(12'd400, 12'd552);                       // 按钮中心（= 危险区中心）
        chk_true("9a 按钮框内（400,552）→ 二次确认询问态", u_dut.dlg === 2'd1);
        chk_true("9a 询问态不直接写寄存器（W1C 计数 0）", w1c_cnt === 0);
        tch_tap(12'd380, 12'd352);                       // 对话框 CANCEL
        chk_true("9a CANCEL 回到关闭态", u_dut.dlg === 2'd0);

        tch_tap(12'd400, 12'd516);                       // 框上沿 520 之上 4 px
        chk_true("9b 上侧外扩区内（400,516）受理", u_dut.dlg === 2'd1);
        tch_tap(12'd380, 12'd352);
        chk_true("9b CANCEL 回到关闭态", u_dut.dlg === 2'd0);
        tch_tap(12'd400, 12'd508);                       // 危险区内、扩展区外
        chk_true("9c 扩展区外（400,508，危险区内但不是按钮）不受理", u_dut.dlg === 2'd0);

        tch_tap(12'd400, 12'd587);                       // 框下沿 583 之下 4 px
        chk_true("9d 下侧外扩区内（400,587）受理", u_dut.dlg === 2'd1);
        tch_tap(12'd380, 12'd352);
        chk_true("9d CANCEL 回到关闭态", u_dut.dlg === 2'd0);
        tch_tap(12'd400, 12'd595);                       // 扩展区下界 591 之外
        chk_true("9e 扩展区外（400,595）不受理", u_dut.dlg === 2'd0);

        tch_tap(12'd176, 12'd552);                       // 画框左沿 180 之外 4 px
        chk_true("9f 左侧外扩区内（176,552）受理", u_dut.dlg === 2'd1);
        tch_tap(12'd380, 12'd352);
        chk_true("9f CANCEL 回到关闭态", u_dut.dlg === 2'd0);
        tch_tap(12'd164, 12'd552);                       // 命中区左界 172 之外
        chk_true("9g 扩展区外（164,552）不受理", u_dut.dlg === 2'd0);

        //   9h 反向判据：确认一次**真的**发出 0x0405 <- 1 —— 否则整段可能只是
        //      "什么都没发生"（㉖/㉜ 的教训：注入没生效时断言也会全 OK）。
        tch_tap(12'd400, 12'd552);
        chk_true("9h 再进询问态", u_dut.dlg === 2'd1);
        tch_tap(12'd600, 12'd352);                       // 对话框 OK
        repeat (4) @(posedge sys_clk);
        chk_true("9h OK 真的发出 W1C 写请求（0x0405 <- 1）", w1c_seen === 1'b1);
        chki("9h W1C 请求只发了一条（问一次只清一次）", w1c_cnt, 1);
        chk_true("9h 整段确实有过按下事件", stb_cnt >= 14);

        // =====================================================================
        // ---- 10) v34（㊲）：危险区按钮的"按下"语义（按下不弹窗 / 滑出抬起不受理）----
        //   旧版：`tap_dz_clr = hit_stb && …` —— 按下的那一拍就弹询问态，遮罩随即把
        //   这整块按钮盖掉 ⇒ 按下反馈在物理上不可能被看见（这是 U-40.8 第 3 条
        //   "没有按下反馈"的真正原因，不是"少画了一个颜色"）。
        //   新版：按下只上"按下态"（白面 + 内嵌第二道红框，形状编码，spec §5.2
        //   不许只靠颜色），**抬起那一拍**才弹询问态；抬起点必须仍在按钮命中区内
        //   （按住后滑出去再抬 = 用户自己撤回这次危险操作，一个字节都不发）。
        // =====================================================================
        //   等 9h 那条 W1C 事务先收尾（否则"按住不弹窗"会被上次的忙碌态挡住）
        wait_dlg_off("9h W1C 事务收尾、回到关闭态");

        tch_sample(12'd400, 12'd552, 1'b1);              // 按下（先不抬起）
        repeat (8) @(posedge sys_clk);
        chk_true("10a 按住期间**还不许**弹询问态", u_dut.dlg === 2'd0);
        chk_true("10a 按住期间命中层确实给了按下电平", u_dut.hit_held === 1'b1);
        //   光有"按住不进询问态"还不够：还得证明**绘制层真的收到了这本电平**
        //   （否则按钮上那一圈内嵌框没人画，"按下反馈"只剩下一句注释）。
        //   这是端到端台能钉住接线的那一半，真正的像素在 tb_disp_engine 的 ⑥ 段。
        chk_true("10a 按住期间绘制层的按下电平已拉起", u_dut.dz_prs_lvl === 1'b1);
        tch_sample(12'd400, 12'd552, 1'b0);              // 原地抬起
        repeat (8) @(posedge sys_clk);
        chk_true("10b 在按钮上抬起 -> 进询问态", u_dut.dlg === 2'd1);
        chk_true("10b 抬起后绘制层的按下电平已落下", u_dut.dz_prs_lvl === 1'b0);
        chk_true("10b 询问态仍然不直接写寄存器", w1c_cnt === 1);
        tch_tap(12'd380, 12'd352);                       // 对话框 CANCEL
        chk_true("10b CANCEL 回到关闭态", u_dut.dlg === 2'd0);

        tch_sample(12'd400, 12'd552, 1'b1);              // 按下
        repeat (4) @(posedge sys_clk);
        tch_sample(12'd400, 12'd508, 1'b1);              // 按住滑出命中区（危险区内、非按钮）
        repeat (4) @(posedge sys_clk);
        tch_sample(12'd400, 12'd508, 1'b0);              // 在按钮外抬起
        repeat (8) @(posedge sys_clk);
        chk_true("10c 按住后滑出再抬起 -> 不受理（防误触）", u_dut.dlg === 2'd0);
        chki("10c 整段仍然只发过那一条 W1C", w1c_cnt, 1);
        chk_true("10 整段确实有过按下事件", stb_cnt >= 16);
        release u_dut.page;

        // =====================================================================
        // ---- 11) v42（㊴）：P6「恢复默认」的端到端（屏侧字节真的进真寄存器）----
        //   与 disp/tb_ui_restore.v 的分工：
        //     · 那个台把"序列 + 17 项回读比对 + 反例（写不进去 ⇒ bad 置位）"
        //       单独钉死，它自带一个字节级寄存器模型；
        //     · 这个台钉**接线**：enc_top_disp 里例化的是真 enc_top
        //       （disp/tb_enc_disp_panel.v:126-153，.uart_rx(enc_uart_rx)），
        //       屏侧发的字节走三路 mux 真进 reg_file，ui_restore 回读的 disp_tap
        //       也是真寄存器 ⇒ 这里的"绿"= 用户按了恢复默认、**实物寄存器**
        //       真的回到出厂默认（spec §6.4 第二条 + §6.2 的"只显示回读值"）。
        //   三步：① 以上位机身份把 ABLIMIT 写脏（走物理 uart_rx 引脚）；
        //         ② 按第 2 颗按钮 → 询问态（kind=1）→ CANCEL 不发字节；
        //         ③ 再按 → OK → 收 52 字节比对 → 绿 + 抽头回默认。
        // =====================================================================
        //   ① 写脏：0x0106 <- 0x0A55 ⇒ ABLIMIT 抽头 = 0x55（可回读）、
        //      邻居 ZERO0 跟着写 0x0A（与复位默认相同，不引入第二个变量）
        //   ★ 等一下再查：这条命令进的是 rtl/uart_spi_bridge.v（"UART→SPI 桥"），
        //     4 个字节之后它还要跑一帧**内部 SPI**（uart_spi_bridge.v:57 的
        //     10.56 µs）才轮到 reg_file 更新；只等几拍的检查会读到旧值 ——
        //     第一版就是在这里判成"写脏没生效"的（而且后面那条
        //     "恢复后 ABLIMIT = 0" 会**假绿**：它本来就已经是 0）。
        uart_send_cmd(11'h106, 16'h0A55);
        repeat (2000) @(posedge sys_clk);              // 40 µs >> 20 µs 字节 + 10.56 µs 帧
        chki("11a 上位机写入后 ABLIMIT 抽头 = 0x55（写脏生效）",
             u_dut.tap_ablimit, 8'h55);

        force u_dut.page = 3'd5;
        repeat (4) @(posedge sys_clk);

        //   ② 按第 2 颗按钮（"恢复默认"）→ 询问态；询问态不许写寄存器
        tch_tap(12'd800, 12'd552);
        chk_true("11b 按第 2 颗按钮 -> 询问态", u_dut.dlg === 2'd1);
        chk_true("11b 询问态是「恢复默认」（kind=1，不是清除故障）",
                 u_dut.dlg_kind === 1'b1);

        //   CANCEL：一个字节都不许发（等 1.2 ms —— 真跑起来第 1 个字节
        //   在 500 µs 的 GAP_CLK 后就该出现，这个窗口足够暴露"误启动"）
        rsv0 = line_fall;
        tch_tap(12'd380, 12'd352);
        chk_true("11c CANCEL 回到关闭态", u_dut.dlg === 2'd0);
        chk_true("11c CANCEL 后恢复序列不在忙", u_dut.rst_busy === 1'b0);
        repeat (60000) @(posedge sys_clk);
        chki("11c CANCEL 线上一个下降沿都没有（一个字节都没发）",
             line_fall - rsv0, 0);

        //   ③ ㊴ 版面的回归钉：画框挪成两颗（180..591 / 608..1019）之后命中区必须
        //      跟着挪（184..647 → 172..600）。这一条钉的是"第 2 颗按钮左沿附近"
        //      —— 命中区漏改时这里会弹"清除锁存故障"（kind=0）。
        tch_tap(12'd620, 12'd552);
        chk_true("11d 第 2 颗左沿附近（620,552）-> 询问态", u_dut.dlg === 2'd1);
        chk_true("11d 弹出的必须是「恢复默认」（kind=1）", u_dut.dlg_kind === 1'b1);
        tch_tap(12'd380, 12'd352);
        chk_true("11d CANCEL 回到关闭态", u_dut.dlg === 2'd0);

        //   ④ 真正执行：按第 2 颗 → OK → 收 52 字节 → 等收尾 → 判绿 + 抽头回默认
        tch_tap(12'd800, 12'd552);
        chk_true("11e 再进询问态", u_dut.dlg === 2'd1);
        rsv0 = line_fall;
        tch_tap(12'd600, 12'd352);                     // 对话框 OK
        uart_expect_restore_seq();
        chki("11e 恢复序列 13 条命令与黄金字节流逐字节一致", seq_ok, 13);
        //  ★ v42/㊴ 的第一条真缺陷就出在这两条判据上：最初命令之间只空 80 µs，
        //    而桥处理一条命令要 20（收字节）+10.56（内部 SPI）+≤100（等遥测空闲）
        //    +30（应答）≈ 160 µs，期间它不看 rx ⇒ 13 条里除第 1 条外**全被丢掉**，
        //    只是除 ABLIMIT 外的寄存器本来就是默认值，所以只有它暴露出来。
        //    这两条判据把"命令间隔"与"首字节到达时桥在 C_IDLE"直接钉住：
        //    以后谁再调小 GAP_CLK（或把序列改成背靠背发），这里立刻红。
        chk_true("11e 命令间隔 ≥ 300 µs（避开桥的 SPI+应答窗口）",
                 cmd_gap_min >= 300000);
        chki("11e 每条命令首字节到达时桥都在 C_IDLE（没有整条被吞）",
             cs_bad, 0);
        //   字节数（13 × 4 = 52）由上面这行逐字节比对钉死；线上计数器数的是
        //   下降沿不是字节（同一条命令的 4 个字节连着发，只有命令之间才有
        //   500 µs 的 GAP_CLK），所以它只判"有活动"与"没有多余的字节"。
        rsv1 = line_fall;
        chk_true("11e 链路上确实有活动（≥52 个下降沿，计数器没卡住）",
                 (line_fall - rsv0) >= 52);
        wait_dlg_off("11e 恢复序列收尾（2 ms 稳定窗 + 回读比对）");
        chki("11e 收完 52 字节后线上再无新的下降沿（没有第 53 个字节）",
             line_fall - rsv1, 0);
        $display("[dbg] 11e cap_min(µs)=%0d cs_bad=%0d", cmd_gap_min/1000, cs_bad);
        $display("[dbg] 11e rst_state=%0d bad=%h | ablimit=%h pairs=%h inter=%h div=%h hyst=%h zwidth=%h zphase=%h uvwph=%h pol=%h abzen=%b uwven=%b shift=%h ofs_s=%h ofs_c=%h gain_s=%h gain_c=%h phase_k=%h",
                 u_dut.rst_state, u_dut.rst_bad,
                 u_dut.tap_ablimit, u_dut.tap_pairs, u_dut.tap_inter, u_dut.tap_div,
                 u_dut.tap_hyst_ab, u_dut.tap_zwidth, u_dut.tap_zphase, u_dut.tap_uvwph,
                 u_dut.tap_pol, u_dut.tap_abzen, u_dut.tap_uwven, u_dut.tap_shift,
                 u_dut.tap_ofs_s, u_dut.tap_ofs_c, u_dut.tap_gain_s, u_dut.tap_gain_c,
                 u_dut.tap_phase_k);
        //   真寄存器（reg_file 里的 r_*）与抽头对照：用来分辨"寄存器没写进去"
        //   与"写进去了但抽头是旧的"这两种完全不同的故障。
        $display("[dbg] 11e regs r_ablimit=%h r_zero0=%h r_zero1=%h r_output=%h r_uvw_cfg=%h r_shift_s=%h r_shift_c=%h r_gain_s=%h r_gain_c=%h r_inter0=%h r_inter1=%h",
                 u_dut.u_enc.u_regs.r_ablimit, u_dut.u_enc.u_regs.r_zero0,
                 u_dut.u_enc.u_regs.r_zero1, u_dut.u_enc.u_regs.r_output,
                 u_dut.u_enc.u_regs.r_uvw_cfg, u_dut.u_enc.u_regs.r_shift_s,
                 u_dut.u_enc.u_regs.r_shift_c, u_dut.u_enc.u_regs.r_gain_s,
                 u_dut.u_enc.u_regs.r_gain_c, u_dut.u_enc.u_regs.r_inter0,
                 u_dut.u_enc.u_regs.r_inter1);
        chki("11e 恢复结果 = 绿（17 项抽头全部回到默认）", u_dut.rst_state, 2'd1);
        chki("11e 真寄存器被写回默认：ABLIMIT 抽头 = 0x00",
             u_dut.tap_ablimit, 8'h00);
        chki("11e 这条通道没碰 0x0405（W1C 计数不变）", w1c_cnt, 1);
        release u_dut.page;

        repeat (20) @(posedge sys_clk);

        // =====================================================================
        // ---- 12) v44（㊶）：÷分频八档步进的端到端（屏侧字节真的进真寄存器）----
        //   ㊶ 之前的缺口逐字记在 disp/ui_panel.v 的头注释里："分频不动 —— 面板
        //   只改倍频，分频原样带回读值写回"。这一段钉的就是"改掉之后真的成立"：
        //     ① 字段切换按钮（272,376）把活动字段切到 ÷分频，**切换本身不是改动**；
        //     ② 走一档 ⇒ 待应用分频码 = 回读 ± 1（两端夹住，不绕回）；
        //     ③ APPLY 之后**真寄存器**（抽头 tap_div 与 u_enc.u_regs.r_inter1[4:2]）
        //        跟上，而倍频寄存器一动不动 —— 这条最关键：写命令 pack_cmd 一次
        //        同时写 0x0101/0x0102，只改分频时把倍频顺手吸附成档位值就错了
        //        （disp/ui_panel.v 的"打开面板不吸附"正是为它改的）；
        //     ④ BACK 把倍频与分频**一起**写回上一次值。
        //   ★ ③ 里"tap_div 跟上"不是巧合：disp/ui_edit.v 的 VERIFY=1 回读比对
        //     本来就同时比 inter 与 div，对不上会回滚并置 ST_FAILED。
        // =====================================================================
        //   ★ 与第 9/11 段同一个坑：`page` 是 enc_top_disp 的内部状态，`force` 过
        //     之后 `release` **不会**把它带回 P1（它只在翻页事件里被赋值）——
        //     第 11 段 force 到 P6 之后，本节起点其实还在 P6。所以这里必须自己
        //     force 回 P1，否则点卡片 2 根本开不了面板（首跑就是栽在这一条上：
        //     `12 起点仍在 P1 : got 5 want 0`，后面 16 条全是它的连锁）。
        force u_dut.page = 3'd0;
        repeat (4) @(posedge sys_clk);
        chki("12 起点已回到 P1", u_dut.page, 0);
        iv0    = u_dut.tap_inter;
        dv0    = u_dut.tap_div;
        dir_up = (dv0 !== 3'd7);                       // 已经在 ÷8 就改按 [−]
        dv1    = dir_up ? (dv0 + 3'd1) : (dv0 - 3'd1);
        $display(" 12 起始：倍频回读 = %0d，分频回读码 = %0d（÷%0d）→ 目标码 %0d（÷%0d）",
                 iv0, dv0, dv0 + 3'd1, dv1, dv1 + 3'd1);

        // ---- 12a 开面板：默认活动字段是 ×倍频，分频待应用值 = 回读值 ----
        tch_tap(12'd800, 12'd140);
        chk_true("12a 面板打开", u_dut.pnl_on === 1'b1);
        chk_true("12a 默认活动字段 = ×倍频", u_dut.pnl_fld === 1'b0);
        chk_true("12a 待应用分频码 = 回读值", u_dut.pnl_didx === dv0);
        chk_true("12a 刚打开没有待应用（pnl_pend = 0）", u_dut.pnl_pend === 1'b0);

        // ---- 12b 切到 ÷字段：切换本身不是"改动" ----
        tch_tap(12'd272, 12'd376);                     // FLD 按钮中心
        chk_true("12b 切到 ÷ 字段", u_dut.pnl_fld === 1'b1);
        chk_true("12b 切字段不产生待应用（pnl_pend = 0）", u_dut.pnl_pend === 1'b0);
        chki("12b 切字段不写寄存器（仍 2）", req_cnt, 2);

        // ---- 12c 走一档：分频动、倍频一动不动 ----
        if (dir_up) tch_tap(12'd832, 12'd496);         // [+]
        else        tch_tap(12'd192, 12'd496);         // [−]
        chk_true("12c 走一档后进入待应用态", u_dut.pnl_pend === 1'b1);
        chk_true("12c 待应用分频码 = 回读 ± 1", u_dut.pnl_didx === dv1);
        chk_true("12c 待应用倍频仍是回读真值（没被吸附成档位）",
                 u_dut.pnl_inter === iv0);

        // ---- 12d APPLY：真寄存器跟上 ----
        tch_tap(12'd528, 12'd552);
        wait_pnl_off("12d APPLY 后面板收起");
        chki("12d APPLY 只发一次写请求（累计 3）", req_cnt, 3);
        chk_true("12d 请求带的分频码 = 面板待应用值", req_seen_div === dv1);
        chk_true("12d 请求带的倍频 = 回读真值", req_seen_inter === iv0);
        chk_true("12d 真寄存器抽头跟上（tap_div）", u_dut.tap_div === dv1);
        chk_true("12d 真寄存器本体 r_inter1[4:2] = 分频码",
                 u_dut.u_enc.u_regs.r_inter1[4:2] === dv1);
        chk_true("12d 倍频寄存器一动不动", u_dut.tap_inter === iv0);
        chk_true("12d 已应用态（pnl_pend = 0）", u_dut.pnl_pend === 1'b0);
        chk_true("12d 上一次值记住分频", u_dut.pnl_undo_div === dv0);
        chk_true("12d 上一次值记住倍频", u_dut.pnl_undo_inter === iv0);

        // ---- 12e BACK：倍频与分频一起回到上一次值 ----
        tch_tap(12'd800, 12'd140);
        chk_true("12e 重开面板", u_dut.pnl_on === 1'b1);
        tch_tap(12'd800, 12'd552);                     // BACK
        wait_pnl_off("12e BACK 后面板收起");
        chki("12e BACK 也只发一次写请求（累计 4）", req_cnt, 4);
        chk_true("12e BACK 请求带回上一次值的分频", req_seen_div === dv0);
        chk_true("12e 真寄存器分频回到写之前", u_dut.tap_div === dv0);
        chk_true("12e 倍频仍然是回读真值", u_dut.tap_inter === iv0);
        chk_true("12e 记忆换成 BACK 之前的分频", u_dut.pnl_undo_div === dv1);
        //   反向判据（㉖/㉜ 的教训）：这一段必须真的按过屏幕，否则上面可能
        //   全是"什么都没发生"的假绿。
        chk_true("12 整段确实有过按下事件（≥22 次）", stb_cnt >= 22);
        release u_dut.page;

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // ---------------------------------------------------------------------
    //  6. 看门狗（v42/㊴：第 11 段加了一段真恢复序列 —— 13 条命令 × 约 520 µs
    //     + 2 ms 稳定窗 ≈ 8.8 ms，所以全程从约 4.4 ms 涨到约 13 ms。
    //     这里放到 30 ms：它只是"仿真没卡死"的兜底，不是时序判据。）
    // ---------------------------------------------------------------------
    initial begin
        #30_000_000;                               // 30 ms
        $display("[FAIL] 看门狗超时：仿真没有在预期时间内结束");
        $display("TEST FAILED: %0d errors", errors + 1);
        $finish;
    end

endmodule
`endif
