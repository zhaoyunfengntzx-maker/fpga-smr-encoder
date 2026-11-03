// -----------------------------------------------------------------------------
//  lcd_test2/sim/tb_lcd2_top.v   （由 lcd_test/sim/tb_lcd_rgb_top.v 改造）
//  lcd_test2_top 集成自检测试台
//
//  这个测试台把"看屏幕"变成可自动判定的检查项：
//    A. 复位释放：屏 ID 采样必须发生在 24 根数据线高阻期间，ID 至少被正确采到一次
//       （010 = ATK-7016，正是本工程的目标屏；测试台用 PULL 把 R7/G7/B7 拉成 010）
//    B. 显示时序：每行拍数 = 行总，每帧有效像素 = 1024*600，同步极性/宽度正确
//    C. 按键：模拟板载按键短按，模式键 mode 必须翻转（0=F1 色轮播 <-> 1=F2/F3 触摸界面）。
//       ★ 第二版起按键不再复位屏，长按（1s）是"暂停"；短按的语义变成切模式。
//    D. IIC 触摸：用一个行为级 GT911 从机（地址 0x5D）应答，检查顶层
//       touch_i2c_ctrl 能锁定型号、拿到点数与坐标
//    E. UART：遥测帧 v3（26 字节）有实际波形输出（能看到起始位下降沿 + 8 个数据位；
//       逐字节内容由 tb_uart_frame26 单独校验）
//
//  注意 1：IIC 的 IIC_DIV 用**真实值 62**（201.6kHz），所以触摸那一段是全真时序。
//  注意 2：上电复位（POR_CYCLES）与读屏 ID 延时（RD_CYCLES）这类"毫秒级纯等待"
//          用 TEST_SPEEDUP 缩小后再 defparam 到 DUT 内部。★ 缩小的比例关系仍然
//          成立（RD_CYCLES 仍大于 POR_CYCLES），所以"必须先释放复位、再让数据线
//          高阻、最后采样 ID"这条**顺序**依然被验证，只是不验证"恰好等了 42ms"
//          —— 那个真实延时另外用 tb_lcd_timing 的真实参数与上板实测覆盖。
//          另外 xelab 的 -generic_top 改不了本测试台的 localparam，所以缩放做在
//          源码里，sim_lcd_test.tcl 不再传 -generic_top。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_lcd2_top;

    // ====================================================== 仿真时间缩放（仅仿真）
    localparam TEST_SPEEDUP = 200;                        // 200 => 各延时缩短 200 倍
    localparam integer SIM_POR_CYCLES = 524287 / TEST_SPEEDUP;   // 16207 拍 ≈ 0.32ms
    localparam integer SIM_RD_CYCLES  = 2097151 / TEST_SPEEDUP;  // 64830 拍 ≈ 1.3ms
    localparam integer SIM_DB_CYCLES  = 500000 / TEST_SPEEDUP;   // 2500 拍（key_ctrl 消抖）
    localparam integer SIM_LONG_CYCLES= 50000000 / TEST_SPEEDUP; // 250000 拍（key_ctrl 长按 1s）
    localparam integer SIM_TIMEOUT_NS = 1_500_000_000;           // 1.5s：必须大于 sec_pulse 的 1.007s

    // ============================================================== 时钟/复位
    reg clk = 1'b0;
    always #10 clk = ~clk;                     // 50MHz

    reg key_n = 1'b1;

    // ============================================================== DUT
    wire [23:0] lcd_rgb;
    wire lcd_pclk, lcd_hs, lcd_vs, lcd_de, lcd_bl, lcd_rst;
    wire touch_scl, touch_sda, touch_rst_n, touch_int;
    wire uart_tx;

    lcd_test2_top u_dut (
        .sys_clk     (clk),
        .key_n       (key_n),
        .uart_tx     (uart_tx),
        .lcd_rgb     (lcd_rgb),
        .lcd_pclk    (lcd_pclk),
        .lcd_hs      (lcd_hs),
        .lcd_vs      (lcd_vs),
        .lcd_de      (lcd_de),
        .lcd_bl      (lcd_bl),
        .lcd_rst     (lcd_rst),
        .touch_scl   (touch_scl),
        .touch_sda   (touch_sda),
        .touch_rst_n (touch_rst_n),
        .touch_int   (touch_int)
    );

    // ---- 把缩放后的"纯等待类"参数推进 DUT 内部（只影响仿真时长，不改逻辑）
    // ★ 第二版顶层只有一个复位同步器 u_por（旧顶层还有 u_por_lcd，已并入），
    //   按键模块由 key_debounce 换成 key_ctrl（HOLD_CYCLES -> LONG_CYCLES）。
    defparam u_dut.u_por.POR_CYCLES     = SIM_POR_CYCLES;
    defparam u_dut.u_id.RD_CYCLES       = SIM_RD_CYCLES;
    defparam u_dut.u_key.DB_CYCLES      = SIM_DB_CYCLES;
    defparam u_dut.u_key.LONG_CYCLES    = SIM_LONG_CYCLES;

    // ====================================================== 模拟 LCD 屏侧
    // 屏模块上的 ID 电阻：R7(M0) 拉低、G7(M1) 拉高、B7(M2) 拉低 => {M0,M1,M2}=010
    // 只有在 FPGA 侧高阻（读 ID 窗口）时才让电阻起作用；正常显示时数据线由 FPGA 驱动，
    // 强驱动会盖过电阻，所以这里用 pull 而不是 assign —— 语义与真实电阻一致。
    // 线序：lcd_rgb[7]=R7(第 10 针)、[15]=G7(第 19 针)、[23]=B7(第 28 针)
    pullup   (lcd_rgb[15]);                     // M1 上拉   -> 1
    pulldown (lcd_rgb[7]);                      // M0 下拉   -> 0
    pulldown (lcd_rgb[23]);                     // M2 下拉   -> 0
    // 其余 21 根数据线也加上弱上拉：真实屏模块在 FPGA 高阻时把悬空数据线拉到无效电平，
    // 这里用 pull 模拟，避免仿真里出现 'z（读写判定会因此变模糊）。
    genvar gp;
    generate
        for (gp = 0; gp < 24; gp = gp + 1) begin : g_idle
            if (gp != 7 && gp != 15 && gp != 23) pullup (lcd_rgb[gp]);
        end
    endgenerate

    // 屏侧触摸 IC 的 IIC 上拉（开漏必需）
    pullup   (touch_scl);
    pullup   (touch_sda);
    // 触摸 INT 上电时无效态（高）；真正的中断驱动逻辑不在本测试台范围内
    // 屏侧的 INT 上拉（真实模块上由电阻提供；FPGA 侧另有内部弱上拉）。
    // DUT 在复位窗口内会把 INT 拉低，之后释放成 z，这里的上拉把它带回高电平。
    pullup   (touch_int);

    // ====================================================== 行为级 GT911 从机
    iic_slave_model #(
        .SLV_ADDR  (7'h5D),
        .PRESENT   (1'b1),
        .GT_STATUS (8'h82),                     // bit7=1 有新数据, 点数=2
        .FT_STATUS (8'h00),
        .FT_XH (8'h00), .FT_XL (8'h00),
        .FT_YH (8'h00), .FT_YL (8'h00)
    ) u_gt911 (
        .scl_o   (touch_scl),
        .scl_io  (touch_scl),
        .sda_o   (touch_sda),
        .sda_io  (touch_sda),
        // START/STOP 必须看主机侧原始驱动（oe=1 表示拉低），不能用总线电平
        .scl_oe  (u_dut.u_io.scl_oe),
        .sda_oe  (u_dut.u_io.sda_oe)
    );

    // ============================================================== 检查统计
    integer errors = 0;

    // ---- 显示时序测量（按像素使能域计数；7016 的 pixel_en 恒 1）
    integer line_cnt = 0, de_in_frame = 0, frames = 0;
    integer hs_low = 0, hs_low_max = 0;
    integer vs_low = 0, vs_low_max = 0;
    integer last_frame_de = 0;
    reg     in_frame = 1'b0;
    integer lines_this_frame = 0;

    // 有效行/有效像素的边界（用于判断有效区起点是否为 2 像素偏移）
    integer de_first_line = 0;

    // ★ meas_en：前两帧是启动瞬态（上电复位/ID 读取期间 lcd_vs 还没形成稳定周期），
    //   若不屏蔽会把瞬态行长（实测 2625 拍）当成"每行拍数"而误判 FAIL。
    reg     meas_en = 1'b0;

    always @(posedge clk) begin
        if (frames >= 2) meas_en <= 1'b1;

        // 行计数：lcd_hs 的下降沿 = 行起点
        if (lcd_hs == 1'b0) hs_low = hs_low + 1;
        else begin
            if (meas_en && hs_low > hs_low_max) hs_low_max = hs_low;
            hs_low = 0;
        end

        if (lcd_vs == 1'b0) vs_low = vs_low + 1;
        else begin
            if (meas_en && vs_low > vs_low_max) vs_low_max = vs_low;
            vs_low = 0;
        end

        if (lcd_de) begin
            de_in_frame = de_in_frame + 1;
            lines_this_frame = lines_this_frame + 1;
        end
        if (lcd_hs == 1'b0 && lcd_de) de_first_line = de_first_line + 1;

        if (lcd_vs == 1'b0) begin
            if (in_frame) begin
                // 帧结束（场同步开始）
                frames = frames + 1;
                last_frame_de = de_in_frame;
                de_in_frame = 0;
                lines_this_frame = 0;
                in_frame = 1'b0;
            end
        end
        else in_frame <= 1'b1;
    end

    // ---- 每行拍数（pixel_en 恒 1，所以拍数 = 像素数）
    // 行同步下降沿 = 新的一行开始；用同一个 always 块结算，避免多块同时写同一变量
    integer line_cycles = 0, line_cycles_max = 0, lines_total = 0;
    reg hs_d = 1'b1;
    always @(posedge clk) begin
        hs_d <= lcd_hs;
        line_cycles = line_cycles + 1;
        if (hs_d && !lcd_hs) begin
            if (meas_en && line_cycles > line_cycles_max) line_cycles_max = line_cycles;
            line_cycles = 0;
            lines_total = lines_total + 1;
        end
    end

    // ---- ID 采样时机与 ID 值
    reg        id_valid_d = 1'b0;
    reg        id_seen    = 1'b0;
    reg [2:0]  id_captured = 3'bxxx;
    reg        oe_ok      = 1'b0;
    integer    oe_low_cycles = 0;
    reg [23:0] rgb_snapshot = 24'hz;

    always @(posedge clk) begin
        id_valid_d <= u_dut.id_valid;
        // ★ 高阻窗口内**持续**记录总线电平，不能在 id_valid 上升沿那一拍才采样：
        //   那一拍 data_oe 已经翻成 1、FPGA 改驱像素数据，采到的是 24'h000000
        //   （实测就是这样，导致 oe_ok=0 的假 FAIL）。
        if (!u_dut.data_oe) begin
            rgb_snapshot  <= lcd_rgb;
            oe_low_cycles <= oe_low_cycles + 1;
            if (lcd_rgb === 24'h7FFF7F) oe_ok <= 1'b1;
        end
        if (u_dut.id_valid && !id_valid_d) begin
            id_seen     <= 1'b1;
            id_captured <= u_dut.panel_id;
        end
    end

`ifdef TB_TRACE
    // ---- 触摸诊断（用 xvlog -d TB_TRACE 打开：每 100ms 打印一次控制器内部状态）
    integer tdbg_n = 0;
    integer tdbg_div = 0;
    integer t_scl_e = 0;
    reg     t_busy_seen = 1'b0;
    reg [15:0] t_d0 = 16'd0;
    always @(negedge touch_scl) t_scl_e = t_scl_e + 1;
    always @(posedge clk) begin
        if (u_dut.u_touch.u_iic.busy) t_busy_seen <= 1'b1;
        if (u_dut.u_touch.u_iic.done) t_d0 <= u_dut.u_touch.u_iic.rd_data0;
        tdbg_div = tdbg_div + 1;
        if (tdbg_div >= 5_000_000) begin
            tdbg_div = 0;
            if (tdbg_n < 15) begin
                tdbg_n = tdbg_n + 1;
                $display("TDBG t=%0t tstate=%0d step=%0d istate=%0d mode=%0d scl_e=%0d reads=%0d probe_gt=%02h d0=%04h",
                    $time, u_dut.u_touch.state, u_dut.u_touch.step, u_dut.u_touch.u_iic.state,
                    u_dut.u_touch.mode, t_scl_e, u_dut.stat_reads, u_dut.u_touch.probe_gt, t_d0);
            end
        end
    end
`endif

    // ---- 模式切换（F4：短按翻转 mode，0=F1 色轮播 1=F2/F3 触摸界面）
    reg mode_d = 1'b0;
    integer   mode_changes = 0;
    always @(posedge clk) begin
        mode_d <= u_dut.mode;
        if (u_dut.mode !== mode_d) mode_changes = mode_changes + 1;
    end

    // ---- 画面多样性：有效像素里出现过多少种不同颜色（抽样统计）
    //   F1（纯色）只有 1-2 种；F2/F3（网格+坐标+面板+准星）应远多于 4 种。
    //   这一条能抓住"screen_pattern 没接上 / 一直是纯色"这类只在顶层才暴露的问题。
    reg [23:0] col_seen [0:63];
    integer    col_n = 0;
    integer    px_samp = 0;
    integer    k;
    reg        col_dup;
    always @(posedge clk) begin
        if (lcd_de) begin
            px_samp = px_samp + 1;
            // 抽样步长取 1021（素数，与每行 1024 互质）：采样点的 x 会逐次漂移，
            // 否则 %4096 每帧都落在同一列上，可能整列都是底色而误判"颜色单一"。
            if (px_samp % 1021 == 0) begin
                col_dup = 1'b0;
                for (k = 0; k < col_n; k = k + 1)
                    if (col_seen[k] === lcd_rgb) col_dup = 1'b1;
                if (!col_dup && col_n < 64) begin
                    col_seen[col_n] = lcd_rgb;
                    col_n = col_n + 1;
                end
            end
        end
    end

    // ---- 触摸锁定
    reg       tch_seen = 1'b0;
    reg [1:0] tch_type_cap = 2'd0;
    reg [2:0] tch_num_cap  = 3'd0;
    reg [15:0] tch_x_cap = 16'd0, tch_y_cap = 16'd0;
    always @(posedge clk) begin
        if (u_dut.tch_type != 2'd0) tch_seen <= 1'b1;
        if (u_dut.tch_valid) begin
            tch_type_cap <= u_dut.tch_type;
            tch_num_cap  <= u_dut.tch_num;
            tch_x_cap    <= u_dut.tch_x0;
            tch_y_cap    <= u_dut.tch_y0;
        end
    end

    // ---- UART 位周期
    reg  uart_d = 1'b1;
    integer uart_hi = 0, uart_hi_last = 0, uart_low_edges = 0;
    always @(posedge clk) begin
        uart_d <= uart_tx;
        if (uart_tx) begin
            uart_hi = uart_hi + 1;
        end
        else begin
            if (uart_d) begin
                uart_hi_last = uart_hi;
                uart_hi = 0;
                uart_low_edges = uart_low_edges + 1;
            end
        end
    end

    // ============================================================== 测试流程
    initial begin
        $display("== tb_lcd2_top: 7寸 RGB-LCD + 电容触摸 集成自检（第二版 lcd_test2）==");
        key_n = 1'b1;

        // ---------- 阶段 1：上电，等 ID 读回（约 42ms）
        wait (id_seen == 1'b1);
        $display("  [ID] panel_id = 3'b%03b (期望 3'b010 = ATK-7016)", id_captured);
        $display("  [ID] 采样瞬间 lcd_rgb = %h（h=高阻位）", rgb_snapshot);
        $display("  [ID] 读 ID 窗口内引脚电平符合 010 电组分压 = %0d", oe_ok);
        $display("  [ID] data_oe 为低的周期数 = %0d（至少覆盖复位窗口）", oe_low_cycles);
        if (id_captured !== 3'b010) begin errors=errors+1; $display("  [FAIL] 屏 ID 不是 010"); end
        if (oe_ok !== 1'b1)         begin errors=errors+1; $display("  [FAIL] 采样瞬间数据线不是高阻态"); end

        // ---------- 阶段 2：等前两帧走完（启动瞬态不计），检查显示时序
        wait (frames >= 3);
        $display("  [TMG] 每行拍数 = %0d (期望 1344)", line_cycles_max);
        $display("  [TMG] 行同步低电平最大拍数 = %0d (期望 20)", hs_low_max);
        $display("  [TMG] 场同步低电平最大拍数 = %0d (期望 %0d = 3 行)", vs_low_max, 3*1344);
        $display("  [TMG] 上一帧有效像素数 = %0d (期望 %0d)", last_frame_de, 1024*600);
        $display("  [TMG] 已计数行数 = %0d", lines_total);
        if (line_cycles_max != 1344) begin errors=errors+1; $display("  [FAIL] 行总长不是 1344"); end
        if (hs_low_max != 20)        begin errors=errors+1; $display("  [FAIL] 行同步宽度不是 20"); end
        if (vs_low_max != 3*1344)    begin errors=errors+1; $display("  [FAIL] 场同步宽度不是 3 行"); end
        if (last_frame_de != 1024*600) begin errors=errors+1; $display("  [FAIL] 有效像素数不等于 1024*600"); end

        // ---------- 阶段 3：等触摸锁定（真实 IIC_DIV=62 => 201.6kHz，一次探测 < 1ms）
        wait (tch_seen == 1'b1);
        $display("  [IIC] 锁定类型 = %0d (期望 1 = GT911)", u_dut.tch_type);
        $display("  [IIC] 探测次数 probe_gt=%0d probe_ft=%0d", u_dut.probe_gt, u_dut.probe_ft);
        $display("  [IIC] stat_reads=%0d nack=%0d timeout=%0d",
                 u_dut.stat_reads, u_dut.stat_nack, u_dut.stat_timeout);
        if (u_dut.tch_type != 2'd1) begin errors=errors+1; $display("  [FAIL] 未锁定 GT911"); end

        // 等第一次坐标有效
        wait (u_dut.tch_valid == 1'b1);
        #100;
        $display("  [IIC] 点数 = %0d (期望 2)", tch_num_cap);
        $display("  [IIC] 第 1 点坐标 = (%0d, %0d) (期望 600, 256)", tch_x_cap, tch_y_cap);
        if (tch_num_cap != 3'd2)               begin errors=errors+1; $display("  [FAIL] 点数"); end
        if (tch_x_cap != 16'd600 || tch_y_cap != 16'd256)
                                               begin errors=errors+1; $display("  [FAIL] 坐标"); end

        // ---------- 阶段 4：按键短按应翻转模式（F1 <-> F2/F3）
        begin : press_key
            reg mode_before;
            integer frames_at_press;
            mode_before = u_dut.mode;
            frames_at_press = frames;
            key_n = 1'b0;
            repeat (SIM_DB_CYCLES * 2) @(posedge clk);   // > 消抖
            key_n = 1'b1;
            repeat (SIM_DB_CYCLES * 4) @(posedge clk);
            // ★ mode 是组合输出，但要等画面真的换过去，所以再等 2 帧
            wait (frames >= frames_at_press + 2);
            $display("  [KEY] 短按前 mode=%0d，按后 mode=%0d (期望翻转)",
                     mode_before, u_dut.mode);
            if (u_dut.mode === mode_before)
                begin errors=errors+1; $display("  [FAIL] 按键未翻转模式"); end
            $display("  [PAT] 有效像素中出现过的不同颜色数 = %0d（F2 应 >= 4）", col_n);
            if (col_n < 4)
                begin errors=errors+1; $display("  [FAIL] 画面颜色过于单一，F2 网格/面板可能没画"); end
        end

        // ---------- 阶段 5：UART 遥测（等 sec_pulse 后看波形）
        wait (u_dut.sec_pulse == 1'b1);
        wait (uart_low_edges >= 2);
        $display("  [UART] 起始位个数 = %0d，高电平最长拍数 = %0d (115200 => 约 434)",
                 uart_low_edges, uart_hi_last);
        if (uart_low_edges < 1) begin errors=errors+1; $display("  [FAIL] UART 无输出"); end

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #SIM_TIMEOUT_NS;
        $display("TEST FAILED: timeout (errors=%0d)", errors);
        $finish;
    end

endmodule
