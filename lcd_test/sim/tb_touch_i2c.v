// -----------------------------------------------------------------------------
//  lcd_test/sim/tb_touch_i2c.v
//  IIC 触摸路径自检测试台（touch_i2c_ctrl + i2c_master_seq）
//
//  为什么要有一台"假触摸 IC"：真屏只有一个，而 GT911 / FT5x06 的寄存器布局、
//  坐标高低位摆放都不一样；只靠上板试无法区分"是没接好"还是"解码写错了"。
//  这里用行为级 IIC 从机把两种 IC 的帧结构、地址、寄存器指针、坐标拼接独立复现
//  一遍，与 RTL 形成交叉验证。
//
//  测试内容（由 `define 选择，默认 GT911）：
//    GT911 模式：应锁定 MODE_GT，2 个触摸点，坐标 (600,256) / (900,400)
//    FT    模式：GT 探测必须失败且不污染统计，随后锁定 MODE_FT，1 个点 (0x102,0x304)
//    NONE  模式：从机完全不应答，stat_reads 必须保持 0 且不死锁
//
//  从机模型：板级 IIC 是开漏，SCL 由主机与从机任一拉低即为低。测试台里两者都只
//  "拉低或释放"，用三态线汇合。从机在收到字节后于 SCL 低电平期间拉低 SDA 应答。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

// ★ 必须显式打开一个模式！`ifdef 里的断言才是真正的判据；一个都不定义时
//   模块级 `else 分支虽然把从机建模成 GT911，但断言段全被预处理掉，
//   测试台会变成"什么都不检查"的空跑（2026-10-14 真实踩过：报 TEST PASSED
//   而 tch_type=0、stat_reads=0 —— 是空跑，不是通过）。
//
// 三种从机配置（默认 GT911）：
//   xvlog tb_touch_i2c.v ...                                   -> GT911
//   xvlog -d SLAVE_FT5206 tb_touch_i2c.v ...                   -> FT5206
//   xvlog -d SLAVE_NONE   tb_touch_i2c.v ...                   -> 总线上没有任何从机
//   （注意 xvlog 只支持 `-d 名字`，不支持 `-d 名字=值`）
`ifndef SLAVE_FT5206
`ifndef SLAVE_NONE
  `define SLAVE_GT911
`endif
`endif
// 想手动改默认时改下面这两行的注释即可：
// `define SLAVE_GT911
// `define SLAVE_FT5206
// `define SLAVE_NONE

`ifdef SLAVE_FT5206
  `define SLV_ADDR_V 7'h38
  `define SLV_PRESENT 1
  `define GT_STATUS  8'h00        // GT911 寄存器读回 0（不会被误判为点数 <=5）
  `define FT_STATUS  8'h01
  `define FT_XH 8'h01
  `define FT_XL 8'h02
  `define FT_YH 8'h03
  `define FT_YL 8'h04
`elsif SLAVE_NONE
  `define SLV_ADDR_V 7'h38
  `define SLV_PRESENT 0
  `define GT_STATUS  8'h00
  `define FT_STATUS  8'h00
  `define FT_XH 8'h00
  `define FT_XL 8'h00
  `define FT_YH 8'h00
  `define FT_YL 8'h00
`else
  `define SLV_ADDR_V 7'h5D
  `define SLV_PRESENT 1
  `define GT_STATUS  8'h02        // 2 个点
  `define FT_STATUS  8'h00
  `define FT_XH 8'h00
  `define FT_XL 8'h00
  `define FT_YH 8'h00
  `define FT_YL 8'h00
`endif

// ★ 仿真用 IIC 分频：默认为 4（快）。用 xvlog -d IIC_DIV_OVERRIDE=62 可以在**真实分频**
//   （SCL = 50MHz/(4*62) = 201.6kHz）下复跑同一套断言，验证与真机一致的时序。
`ifndef IIC_DIV_OVERRIDE
  `define IIC_DIV_OVERRIDE 4
`endif

module tb_touch_i2c;

    // 仿真用 CLK_DIV：真值 62（201.6kHz），仿真用 4 让波形短、跑得快。
    // 注意：touch_i2c_ctrl 内部的复位同步链长度 ≥ 1 个 IIC 位时间，
    //       所以仿真必须把 CLK_DIV 一起改小，否则要跑很久才能看到第一次传输。
    localparam IIC_DIV_SIM = `IIC_DIV_OVERRIDE;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;              // 50MHz

    // ---------------------------------------------------------------- 引脚
    wire scl_oe, sda_oe, scl_line, sda_line;
    wire scl_io, sda_io;
    reg  int_n = 1'b1;

    i2c_io_wrap u_io (
        .clk    (clk),
        .rst_n  (rst_n),
        .scl_oe (scl_oe),
        .sda_oe (sda_oe),
        .scl_o  (scl_line),
        .sda_o  (sda_line),
        .scl_io (scl_io),
        .sda_io (sda_io)
    );

    // 无外部上拉时开漏线会悬空；这里显式加弱上拉（真实板子由 LCD 模块提供）
    pullup (scl_io);
    pullup (sda_io);

    // ---------------------------------------------------- 总线活动探针（诊断用）    // scl_edges = 0 说明主机根本没发起传输（问题在 touch_i2c_ctrl / i2c_master_seq 内部）；
    // scl_edges > 0 而 stat_reads = 0 说明传输发起了但协议层没走通。
    integer scl_edges = 0;
    integer sda_changes = 0;
    always @(negedge scl_io) scl_edges = scl_edges + 1;
    always @(sda_io)         sda_changes = sda_changes + 1;

    // 诊断：锁存"读到坐标那一刻"的原始字（结束时 rd_buf 已被后续传输清零）
    reg [15:0] d0_s, d1_s, d2_s, d3_s, d4_s, d5_s;
    reg [7:0]  probe_s;

    // ---------------------------------------------------------------- 被测
    wire        tch_valid, tch_toggle;
    wire [1:0]  tch_type;
    wire [2:0]  tch_num;
    wire [15:0] tch_x0, tch_y0, tch_x1, tch_y1, tch_x2, tch_y2,
                tch_x3, tch_y3, tch_x4, tch_y4;
    wire [23:0] stat_reads, stat_nack, stat_timeout, stat_touch;
    wire [7:0]  rst_cnt, probe_gt, probe_ft, int_low_cnt, prod_id;
    wire [7:0]  gt_status_raw;
    wire [15:0] gt_xmax, gt_ymax;

    touch_i2c_ctrl #(.IIC_DIV(IIC_DIV_SIM)) u_touch (
        .clk         (clk),
        .rst_n       (rst_n),
        .scl_i       (scl_line),
        .scl_oe      (scl_oe),
        .sda_i       (sda_line),
        .sda_oe      (sda_oe),
        .int_n_i     (int_n),
        .tch_valid   (tch_valid),
        .tch_toggle  (tch_toggle),
        .tch_type    (tch_type),
        .tch_num     (tch_num),
        .tch_x0      (tch_x0), .tch_y0 (tch_y0),
        .tch_x1      (tch_x1), .tch_y1 (tch_y1),
        .tch_x2      (tch_x2), .tch_y2 (tch_y2),
        .tch_x3      (tch_x3), .tch_y3 (tch_y3),
        .tch_x4      (tch_x4), .tch_y4 (tch_y4),
        .stat_reads  (stat_reads),
        .stat_nack   (stat_nack),
        .stat_timeout(stat_timeout),
        .stat_touch  (stat_touch),
        .rst_cnt     (rst_cnt),
        .probe_gt    (probe_gt),
        .probe_ft    (probe_ft),
        .prod_id     (prod_id),
        .gt_status_raw (gt_status_raw),
        .gt_xmax     (gt_xmax),
        .gt_ymax     (gt_ymax),
        .int_low_cnt (int_low_cnt)
    );

    // ★ 必须在 tch_toggle 的**上升沿**锁存，而不能用 `if (tch_valid)` 的电平：
    //   tch_valid 一旦置起就一直为 1，而下一次传输（清标记）一开始就会把
    //   rd_buf 清 0，电平式锁存会被反复覆盖，最终印出全 0（"看着像没读到"）。
    reg tch_tog_d;
    always @(posedge clk) begin
        tch_tog_d <= tch_toggle;
        if (tch_toggle && !tch_tog_d) begin
            d0_s <= u_touch.d0; d1_s <= u_touch.d1; d2_s <= u_touch.d2;
            d3_s <= u_touch.d3; d4_s <= u_touch.d4; d5_s <= u_touch.d5;
        end
        if (u_touch.probe_gt != 8'h00) probe_s <= u_touch.probe_gt;
    end

    // ---------------------------------------------------------- 假从机（可选）
`ifdef SLAVE_NONE
    // 完全不接：两条线只有上拉
`else
    iic_slave_model #(
        .SLV_ADDR (`SLV_ADDR_V),
        .PRESENT  (`SLV_PRESENT),
        .GT_STATUS(`GT_STATUS),
        .FT_STATUS(`FT_STATUS),
        .FT_XH(`FT_XH), .FT_XL(`FT_XL), .FT_YH(`FT_YH), .FT_YL(`FT_YL)
    ) u_slv (
        .scl_o (scl_line),
        .scl_io(scl_io),
        .sda_o (sda_line),
        .sda_io(sda_io),
        .scl_oe(scl_oe),
        .sda_oe(sda_oe)
    );
`endif

`ifdef I2C_TRACE
    // ------------------------------------------------ 逐位跟踪（诊断用）
    integer trace_n = 0;
    always @(negedge scl_io) begin
        if (trace_n < 200) begin
            trace_n = trace_n + 1;
            if (trace_n > 50)
            $display("TRC t=%0t MST st=%0d ph=%0d bit=%0d rcnt=%0d wcnt=%0d | SLV st=%0d bit=%0d bc=%0d ptr=%04h tx=%02h sr=%02h | sda_line=%b sda_drv=%b",
                $time, u_touch.u_iic.state, u_touch.u_iic.ph, u_touch.u_iic.bitcnt,
                u_touch.u_iic.rcnt, u_touch.u_iic.wcnt,
                u_slv.st, u_slv.bit, u_slv.bytecnt, u_slv.regptr, u_slv.txval, u_slv.shreg,
                sda_line, u_slv.sda_drv);
        end
    end
`endif

    // ---------------------------------------------------------------- 检查
    integer errors = 0;
    integer reads_at_1ms = 0;

    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // 跑到第一次成功传输（探测 + 锁定型号 + 第一轮轮询）
        // 等到"探测 + 锁定型号 + 第一轮轮询"都走完。FT5206 配置下要先把 GT911
        // 探测失败一次（该分支只等 2ms 就排下一个探测），所以整体多花 2ms。
        // GT911 配置下多了一步"读产品 ID（0x8140）"，也再多花 2ms。
`ifdef SLAVE_FT5206
        #11_000_000;    // 11ms
`else
        #10_000_000;    // 10ms（探测 + 产品 ID + 分辨率 + 数轮轮询）
`endif

        $display("---- IIC 触摸路径自检 ----");
        $display("  tch_type   = %0d (期望 %s)", tch_type,
                 `ifdef SLAVE_GT911 "1" `elsif SLAVE_FT5206 "2" `else "0 或 2" `endif);
        $display("  tch_num    = %0d", tch_num);
        $display("  tch_x0     = %0d (期望 %s)", tch_x0,
                 `ifdef SLAVE_GT911 "600" `elsif SLAVE_FT5206 "258" `else "0" `endif);
        $display("  tch_y0     = %0d (期望 %s)", tch_y0,
                 `ifdef SLAVE_GT911 "256" `elsif SLAVE_FT5206 "772" `else "0" `endif);
        $display("  tch_x1     = %0d (期望 %s)", tch_x1,
                 `ifdef SLAVE_GT911 "900" `else "0" `endif);
        $display("  tch_y1     = %0d (期望 %s)", tch_y1,
                 `ifdef SLAVE_GT911 "400" `else "0" `endif);
        $display("  stat_reads = %0d", stat_reads);
        $display("  stat_nack  = %0d", stat_nack);
        $display("  stat_to    = %0d", stat_timeout);
        $display("  probe_gt   = 0x%02h  probe_ft = 0x%02h", probe_gt, probe_ft);
        $display("  prod_id    = 0x%02h (期望 0x39 = '9')", prod_id);
        $display("  0x814E     = 0x%02h   分辨率 X=%0d Y=%0d (期望 1024/600)",
                 gt_status_raw, gt_xmax, gt_ymax);
        $display("  scl_edges  = %0d   sda_changes = %0d", scl_edges, sda_changes);
        $display("  rd_buf     = %032h", u_touch.u_iic.rd_buf);
        $display("  d0..d5     = %04h %04h %04h %04h %04h %04h",
                 u_touch.d0, u_touch.d1, u_touch.d2, u_touch.d3, u_touch.d4, u_touch.d5);
        $display("  LATCH d0..d5 = %04h %04h %04h %04h %04h %04h   probe=%02h",
                 d0_s, d1_s, d2_s, d3_s, d4_s, d5_s, probe_s);

`ifdef SLAVE_GT911
        if (tch_type !== 2'd1)      begin errors=errors+1; $display("  [FAIL] 未锁定 GT911"); end
        if (prod_id  !== 8'h39)     begin errors=errors+1; $display("  [FAIL] 产品 ID 不是 0x39('9')"); end
        if (tch_num  !== 3'd2)      begin errors=errors+1; $display("  [FAIL] 点数不是 2"); end
        if (tch_x0   !== 16'd600)   begin errors=errors+1; $display("  [FAIL] x0 解码错误"); end
        if (tch_y0   !== 16'd256)   begin errors=errors+1; $display("  [FAIL] y0 解码错误"); end
        if (tch_x1   !== 16'd900)   begin errors=errors+1; $display("  [FAIL] x1 解码错误"); end
        if (tch_y1   !== 16'd400)   begin errors=errors+1; $display("  [FAIL] y1 解码错误"); end
        if (stat_reads < 24'd2)     begin errors=errors+1; $display("  [FAIL] 读取次数过少"); end
        if (gt_xmax  !== 16'd1024)  begin errors=errors+1; $display("  [FAIL] 分辨率 X 解码错误"); end
        if (gt_ymax  !== 16'd600)   begin errors=errors+1; $display("  [FAIL] 分辨率 Y 解码错误"); end
`endif
`ifdef SLAVE_FT5206
        if (tch_type !== 2'd2)      begin errors=errors+1; $display("  [FAIL] 未锁定 FT5x06"); end
        if (tch_num  !== 3'd1)      begin errors=errors+1; $display("  [FAIL] 点数不是 1"); end
        if (tch_x0   !== 16'h102)   begin errors=errors+1; $display("  [FAIL] x0 解码错误"); end
        if (tch_y0   !== 16'h304)   begin errors=errors+1; $display("  [FAIL] y0 解码错误"); end
        if (stat_reads < 24'd1)     begin errors=errors+1; $display("  [FAIL] 读取次数过少"); end
`endif
`ifdef SLAVE_NONE
        if (stat_reads !== 24'd0)   begin errors=errors+1; $display("  [FAIL] 无从机却有成功传输"); end
`endif

        if (errors == 0) $display("TEST PASSED: %0d errors", errors);
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

    // ------------------------------------------------- 临时诊断：内部状态打印
    initial begin
        #450;
        repeat (10) begin
            $display("DBG t=%0t tstate=%0d step=%0d mreq=%b slow=%0d rdy=%0d istate=%0d busy=%b scl_oe=%b sda_oe=%b scl_io=%b sda_io=%b",
                     $time, u_touch.state, u_touch.step, u_touch.m_req, u_touch.slow_cnt,
                     u_touch.rdy_to, u_touch.u_iic.state, u_touch.u_iic.busy,
                     scl_oe, sda_oe, scl_io, sda_io);
            #500000;
        end
    end

endmodule

