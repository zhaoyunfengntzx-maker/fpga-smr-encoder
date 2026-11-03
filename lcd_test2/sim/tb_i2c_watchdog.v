`timescale 1ns/1ps
// =============================================================================
//  tb_i2c_watchdog.v —— IIC 主机看门狗 / S_RECOVER 恢复路径自检
//
//  背景（2026-10-15 上板故障）：GT911 长读期间拉长 SCL 时，主机某一相位若被
//  长时间拖住，旧版看门狗是死代码（判据被截断成 16 位 + 每拍把计数清零），
//  于是"done 永远不来、上层 ST_WAIT 死等"⇒ 触摸功能永久停摆。
//
//  本台用**两个实例 + 不同的 BUSY_LIMIT**分别验证两条路径：
//    dut_wd  ：BUSY_LIMIT 很小 ⇒ 相位里等几拍就被判超时 ⇒ 必须进 S_RECOVER、
//              打完时钟后照常给出 done（timeout=1），而且**第二次请求也照样能完成**
//              （证明是"恢复"而不是"卡住"）。
//    dut_norm：BUSY_LIMIT 正常 ⇒ 总线无应答（sda_i 恒 1）时必须走 NACK 正常结束
//              （done=1 / nack=1 / timeout=0），并且**不能**误触发 S_RECOVER。
//
//  判定：全部断言通过打印 "TEST PASSED: 0 errors"（与其它自检台一致）。
// =============================================================================
module tb_i2c_watchdog;

    // ---------------------------------------------------------------- 时钟复位
    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz
    reg rst_n = 1'b0;

    integer errors = 0;

    // 总线：无人应答（sda_i 恒 1），SCL 恒高
    reg scl_i = 1'b1;
    reg sda_i = 1'b1;

    // ---------------------------------------------------------------- 激励信号
    reg        req_wd   = 1'b0, req_nm = 1'b0;
    reg        wr       = 1'b0;      // 读传输
    reg        rep      = 1'b1;
    reg [7:0]  slv_addr = 8'h5D;
    reg [7:0]  tx_byte  = 8'h81;     // GT911 状态寄存器高字节
    reg [7:0]  tx_byte2 = 8'h4E;     // 低字节
    reg [7:0]  tx_byte3 = 8'h00;
    reg [1:0]  tx_cnt   = 2'd2;      // 两个指针字节
    reg [3:0]  rd_words = 4'd15;     // 15 个字 = 30 字节

    // ---------------------------------------------------------------- 看门狗实例
    wire        wd_busy, wd_done, wd_nack, wd_timeout;
    wire        wd_scl_oe, wd_sda_oe;
    wire [3:0]  wd_state;
    wire        wd_dbg_busy;

    i2c_master_seq #(
        .CLK_DIV    (40),            // 每相位 40 clk
        // 看门狗的新语义：计"当前状态停留拍数"，状态一变就清零。
        // CLK_DIV=40 时一个字节的收发状态 = 8bit × 4相 × 40 = 1280 拍，
        // 而 START/ACK/STOP 这类状态 = 4相 × 40 = 160 拍。
        // 阈值取 400：正常短状态不误报，一进"发字节/收字节"就必然触发。
        .BUSY_LIMIT (25'd400)
    ) dut_wd (
        .clk (clk), .rst_n (rst_n),
        .req (req_wd), .wr (wr), .rep (rep), .slv_addr (slv_addr),
        .tx_byte (tx_byte), .tx_byte2 (tx_byte2), .tx_byte3 (tx_byte3),
        .tx_cnt (tx_cnt), .rd_words (rd_words),
        .busy (wd_busy), .done (wd_done), .nack (wd_nack), .timeout (wd_timeout),
        .rd_data0 (), .rd_data1 (), .rd_data2 (), .rd_data3 (),
        .rd_data4 (), .rd_data5 (), .rd_data6 (), .rd_data7 (),
        .rd_data8 (), .rd_data9 (), .rd_data10 (), .rd_data11 (),
        .rd_data12 (), .rd_data13 (), .rd_data14 (), .rd_data15 (),
        .scl_i (scl_i), .sda_i (sda_i),
        .scl_oe (wd_scl_oe), .sda_oe (wd_sda_oe),
        .dbg_state (wd_state), .dbg_busy (wd_dbg_busy)
    );

    // ---------------------------------------------------------------- 常规实例
    wire        nm_busy, nm_done, nm_nack, nm_timeout;
    wire        nm_scl_oe, nm_sda_oe;
    wire [3:0]  nm_state;
    wire        nm_dbg_busy;

    i2c_master_seq #(
        .CLK_DIV    (8),
        .BUSY_LIMIT (25'd2000)       // 远超单个状态的最长驻留（8bit×4相×8=256），绝不误报
    ) dut_nm (
        .clk (clk), .rst_n (rst_n),
        .req (req_nm), .wr (wr), .rep (rep), .slv_addr (slv_addr),
        .tx_byte (tx_byte), .tx_byte2 (tx_byte2), .tx_byte3 (tx_byte3),
        .tx_cnt (tx_cnt), .rd_words (rd_words),
        .busy (nm_busy), .done (nm_done), .nack (nm_nack), .timeout (nm_timeout),
        .rd_data0 (), .rd_data1 (), .rd_data2 (), .rd_data3 (),
        .rd_data4 (), .rd_data5 (), .rd_data6 (), .rd_data7 (),
        .rd_data8 (), .rd_data9 (), .rd_data10 (), .rd_data11 (),
        .rd_data12 (), .rd_data13 (), .rd_data14 (), .rd_data15 (),
        .scl_i (scl_i), .sda_i (sda_i),
        .scl_oe (nm_scl_oe), .sda_oe (nm_sda_oe),
        .dbg_state (nm_state), .dbg_busy (nm_dbg_busy)
    );

    // ------------------------------------------------- 监视：是否进过 S_RECOVER
    localparam [3:0] S_RECOVER = 4'd10;
    reg wd_saw_recover = 1'b0;
    reg nm_saw_recover = 1'b0;
    always @(posedge clk) begin
        if (wd_state == S_RECOVER) wd_saw_recover <= 1'b1;
        if (nm_state == S_RECOVER) nm_saw_recover <= 1'b1;
    end

    // ---------------------------------------------------------------- 断言助手
    task chk;
        input        cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    // 发一次请求，等 done；返回等待的拍数（超上限返回 -1）
    // ★ 注意：done / nack / timeout / busy 都只在那一拍有效（回到 S_IDLE 就被清），
    //   所以必须在看到 done 的**同一拍**取样，事后再读一定是 0 —— 这是本台
    //   第一版失败的教训。
    integer wait_cyc;
    reg     cap_nack = 1'b0, cap_to = 1'b0, cap_busy = 1'b0;
    task req_and_wait;
        input         which;        // 0 = dut_wd，1 = dut_nm
        input integer cap;
        begin
            wait_cyc = -1;
            cap_nack = 1'b0; cap_to = 1'b0; cap_busy = 1'b0;
            if (which == 0) req_wd = 1'b1; else req_nm = 1'b1;
            @(posedge clk);
            if (which == 0) req_wd = 1'b0; else req_nm = 1'b0;
            for (wait_cyc = 0; wait_cyc < cap; wait_cyc = wait_cyc + 1) begin
                @(posedge clk);
                if ((which == 0) ? wd_done : nm_done) begin
                    if (which == 0) begin
                        cap_nack = wd_nack; cap_to = wd_timeout; cap_busy = wd_busy;
                    end
                    else begin
                        cap_nack = nm_nack; cap_to = nm_timeout; cap_busy = nm_busy;
                    end
                    wait_cyc = wait_cyc + 1;
                    disable req_and_wait;   // 跳出
                end
            end
            wait_cyc = -1;                  // 没等到
        end
    endtask

    // ---------------------------------------------------------------- 主流程
    integer t1, t2, t3;
    initial begin
        $display("=== tb_i2c_watchdog: IIC 看门狗 / S_RECOVER 恢复路径 ===");

        // 复位
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ------------------------------------------------ 用例 1：看门狗恢复
        req_and_wait(0, 20000);
        t1 = wait_cyc;
        chk(t1 > 0, "看门狗实例：第一次请求没有等到 done（死等人的老毛病）");
        if (t1 > 0) $display("  [1] 第一次请求：done 在第 %0d 拍", t1);
        chk(wd_saw_recover == 1'b1, "看门狗实例：没有观察到 S_RECOVER（看门狗没触发）");
        chk(cap_to   == 1'b1,        "看门狗实例：done 时 timeout 不是 1（没上报超时）");
        chk(cap_busy == 1'b0,        "看门狗实例：done 时 busy 不是 0");
        repeat (5) @(posedge clk);

        // ------------------------------------------------ 用例 2：恢复后还能再干
        req_and_wait(0, 20000);
        t2 = wait_cyc;
        chk(t2 > 0, "看门狗实例：恢复后的第二次请求又卡住了");
        if (t2 > 0) $display("  [2] 第二次请求：done 在第 %0d 拍（恢复后可复用）", t2);

        // ------------------------------------------------ 用例 3：常规路径不被误伤
        req_and_wait(1, 20000);
        t3 = wait_cyc;
        chk(t3 > 0,          "常规实例：无应答总线上的请求没有结束");
        chk(nm_saw_recover == 1'b0, "常规实例：误触发了 S_RECOVER（看门狗阈值太敏感）");
        chk(cap_to     == 1'b0,     "常规实例：timeout 不该置起");
        chk(cap_nack   == 1'b1,     "常规实例：无应答时 nack 应为 1（区分 NACK 与超时）");
        chk(cap_busy   == 1'b0,     "常规实例：done 时 busy 不是 0");
        if (t3 > 0) $display("  [3] 常规实例：done 在第 %0d 拍，nack=%0d timeout=%0d",
                             t3, cap_nack, cap_to);

        repeat (10) @(posedge clk);

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // 兜底看门狗：防止测试台本身挂死
    initial begin
        #2_000_000;
        $display("[FAIL] 仿真超时（2 ms 内没跑完）");
        $display("TEST FAILED: 1 errors");
        $finish;
    end

endmodule
