//=============================================================================
//  disp/tb_hit_test.v -- hit_test 的边界级自检
//
//  验的不是"模块跑起来了"，而是"**哪块矩形**被点中" —— 所以每一条判据都写在
//  边界上（差 1 px 就会点错控件，而这种错在屏上看起来只是"点了没反应"）：
//
//    * 导航项分界 y = 24/120/216/312/408/504，左边界 x = 79/80
//    * 状态条 y < 24 通栏
//    * 卡片原点 x = 96/416/736（宽 288）、y = 64/336（高 256）
//    * 卡片与导航列**不再相交**：卡片左沿 x=96 与导航列右边界 x=80 之间
//      留了 16 px 内边距，x ∈ [80,96) 在卡片行上必须是"空命中"
//      （旧原点 32 时卡片压住导航列右半，x ∈ [32,80) 要点出卡片）
//    * 一次接触只报一次：按住不放不连发、按住滑动不触发
//    * 抬起之后才能再报
//    * 越界坐标（x>=1024 / y>=600）不算命中
//
//  ★ 最后一条是这里最要紧的一条：若坐标只取低 12 位再比较，1024 会折成 0，
//    于是面板一旦报出越界垃圾值，就会在状态条左端**凭空**产生一次命中。
//    上板表现是"没碰屏自己翻页"，而且不会在任何静态检查里露出来。
//
//  ★ 关于"两处共同契约"：本测试台断言的 24/96/80/96/416/736/288/64/336/256
//    与 disp/disp_engine.v 第 1 节的版面常量是同一个契约的两份抄写。改版面时
//    两份都要改 —— 只改一边，这里会直接报出来（而不是上板点不中才发现）。
//=============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_hit_test;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;

    reg [2:0]  tch_num    = 3'd0;
    reg [15:0] tch_x0     = 16'd0;
    reg [15:0] tch_y0     = 16'd0;
    reg        tch_toggle = 1'b0;

    wire        hit_stb;
    wire [4:0]  hit_id;
    wire [11:0] hit_x, hit_y;
    // v22：触摸生命周期（批次④ 的拖拽/长按要用）
    wire        hit_held, hit_rel;
    wire [11:0] hit_cur_x, hit_cur_y;

    integer errors = 0;
    integer n_chk  = 0;

    // 控件编号（必须与 disp/hit_test.v 的表一致）
    localparam [4:0] HIT_NONE = 5'd31;
    localparam [4:0] HIT_SBAR = 5'd6;

    hit_test u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .tch_num    (tch_num),
        .tch_x0     (tch_x0),
        .tch_y0     (tch_y0),
        .tch_toggle (tch_toggle),
        .hit_stb    (hit_stb),
        .hit_id     (hit_id),
        .hit_x      (hit_x),
        .hit_y      (hit_y),
        .held       (hit_held),
        .rel_stb    (hit_rel),
        .cur_x      (hit_cur_x),
        .cur_y      (hit_cur_y)
    );

    always #10 clk = ~clk;              // 50 MHz

    // -------------------------------------------------------------------------
    // 送一组新样本：坐标与 num 一起更新 + toggle 翻转
    //   与 disp/touch_ctrl.v:381-388 的更新方式逐条对齐（同一时钟沿、
    //   tch_toggle 与 tch_num/tch_x0 同时更新）。
    // -------------------------------------------------------------------------
    task sample;
        input  [2:0]  num;
        input  [15:0] x;
        input  [15:0] y;
        output        stb;
        output [4:0]  id;
        begin
            @(negedge clk);
            tch_num    = num;
            tch_x0     = x;
            tch_y0     = y;
            tch_toggle = ~tch_toggle;
            @(posedge clk);             // DUT 在这一拍看到"新样本"
            #1;
            stb = hit_stb;
            id  = hit_id;
        end
    endtask

    // -------------------------------------------------------------------------
    // 一次完整点击：先抬起（重新武装）再按下，期望打中 want
    // -------------------------------------------------------------------------
    task chk_tap;
        input [15:0]     x;
        input [15:0]     y;
        input [4:0]      want;
        input [8*64-1:0] label;
        reg              stb;
        reg [4:0]        id;
        begin
            sample(3'd0, x, y, stb, id);        // 抬起
            sample(3'd1, x, y, stb, id);        // 按下
            n_chk = n_chk + 1;
            if (!stb) begin
                errors = errors + 1;
                $display("[FAIL] %0s: (%0d,%0d) 没有报出接触事件（期望 id=%0d）",
                         label, x, y, want);
            end else if (id !== want) begin
                errors = errors + 1;
                $display("[FAIL] %0s: (%0d,%0d) 命中 id=%0d，期望 id=%0d",
                         label, x, y, id, want);
            end else begin
                $display("[ OK ] %0s: (%0d,%0d) -> id=%0d", label, x, y, id);
            end
        end
    endtask

    // 期望"这一次接触什么都没打中"
    task chk_miss;
        input [15:0]     x;
        input [15:0]     y;
        input [8*64-1:0] label;
        begin
            chk_tap(x, y, HIT_NONE, label);
        end
    endtask

    // 期望"按住不放时不再报事件"
    task chk_no_repeat;
        input [15:0]     x;
        input [15:0]     y;
        input [8*64-1:0] label;
        reg              stb;
        reg [4:0]        id;
        begin
            sample(3'd1, x, y, stb, id);        // 同一根手指的下一组样本
            n_chk = n_chk + 1;
            if (stb) begin
                errors = errors + 1;
                $display("[FAIL] %0s: 按住不放时又报了一次事件（id=%0d）", label, id);
            end else begin
                $display("[ OK ] %0s: 按住不放不连发", label);
            end
        end
    endtask

    reg       stb;
    reg [4:0] id;

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5)  @(posedge clk);

        // =====================================================================
        $display("---- 1. 无触点样本不产生事件 ----");
        // =====================================================================
        sample(3'd0, 16'd500, 16'd300, stb, id);
        n_chk = n_chk + 1;
        if (stb) begin
            errors = errors + 1;
            $display("[FAIL] 无触点样本报出了事件（id=%0d）", id);
        end else begin
            $display("[ OK ] 无触点样本不产生事件");
        end

        // =====================================================================
        $display("---- 2. 导航项：96 px 一档的六条边界 ----");
        //   ★ 导航列整宽 80 px 都可用（卡片左沿已退到 x=96），所以这里用
        //     贴左边界的 x=16 与贴右边界的 x=79 各验一遍。
        // =====================================================================
        chk_tap(16'd16, 16'd23,  HIT_SBAR, "状态条 y=23");
        chk_tap(16'd16, 16'd0,   HIT_SBAR, "状态条 y=0");
        chk_tap(16'd16, 16'd24,  5'd0,     "nav0 y=24 上边界");
        chk_tap(16'd16, 16'd71,  5'd0,     "nav0 中心");
        chk_tap(16'd16, 16'd119, 5'd0,     "nav0 y=119");
        chk_tap(16'd16, 16'd120, 5'd1,     "nav1 y=120 下边界");
        chk_tap(16'd16, 16'd215, 5'd1,     "nav1 y=215");
        chk_tap(16'd16, 16'd216, 5'd2,     "nav2 y=216");
        chk_tap(16'd16, 16'd311, 5'd2,     "nav2 y=311");
        chk_tap(16'd16, 16'd312, 5'd3,     "nav3 y=312");
        chk_tap(16'd16, 16'd407, 5'd3,     "nav3 y=407");
        chk_tap(16'd16, 16'd408, 5'd4,     "nav4 y=408");
        chk_tap(16'd16, 16'd503, 5'd4,     "nav4 y=503");
        chk_tap(16'd16, 16'd504, 5'd5,     "nav5 y=504 下边界");
        chk_tap(16'd16, 16'd599, 5'd5,     "nav5 y=599 最后一行");

        // 导航列右边界（y=30 在卡片起始行 64 之前，不会撞上卡片）
        chk_tap(16'd79, 16'd30,  5'd0,     "导航列 x=79 内");
        chk_miss(16'd80, 16'd30,            "导航列 x=80 外");

        // =====================================================================
        $display("---- 3. 卡片 3 列 x 2 行：原点与远角 ----");
        // =====================================================================
        chk_tap(16'd96,  16'd64,  5'd8,  "卡片 00 原点 (96,64)");
        chk_tap(16'd383, 16'd319, 5'd8,  "卡片 00 远角 (383,319)");
        chk_tap(16'd416, 16'd64,  5'd9,  "卡片 10 原点 (416,64)");
        chk_tap(16'd703, 16'd319, 5'd9,  "卡片 10 远角 (703,319)");
        chk_tap(16'd736, 16'd64,  5'd10, "卡片 20 原点 (736,64)");
        chk_tap(16'd1023,16'd319, 5'd10, "卡片 20 远角 (1023,319)");
        chk_tap(16'd96,  16'd336, 5'd11, "卡片 01 原点 (96,336)");
        chk_tap(16'd383, 16'd591, 5'd11, "卡片 01 远角 (383,591)");
        chk_tap(16'd416, 16'd336, 5'd12, "卡片 11 原点 (416,336)");
        chk_tap(16'd736, 16'd336, 5'd13, "卡片 21 原点 (736,336)");
        chk_tap(16'd1023,16'd591, 5'd13, "卡片 21 远角 (1023,591)");

        // 卡片外沿
        chk_miss(16'd384, 16'd100,          "卡片 00 右侧 x=384");
        chk_miss(16'd704, 16'd100,          "卡片 10 右侧 x=704");
        chk_miss(16'd96,  16'd592,          "卡片 01 下侧 y=592");
        chk_miss(16'd1023, 16'd599,         "屏右下角 (1023,599) 在卡片行 1 之下");

        // =====================================================================
        $display("---- 4. 卡片左沿与导航列之间的 16 px 内边距：必须是空命中 ----");
        //   x ∈ [80,96) 既不在导航列（要求 x<80）也不在任何卡片（要求 x>=96）。
        //   ★ 这是旧版"卡片压在导航列右半上、命中必须给卡片"那条诊断的反面：
        //     版面向右挪 16 px（导航栏 80 + 内边距）之后两者不再相交，
        //     所以这块空隙必须点不出任何东西。
        // =====================================================================
        chk_miss(16'd88,  16'd100,          "内边距 (88,100) 空命中");
        chk_miss(16'd95,  16'd319,          "内边距 (95,319) 空命中");
        chk_tap(16'd79,   16'd100, 5'd0,    "导航列 x=79（卡片行上）仍是 nav0");
        chk_tap(16'd96,   16'd100, 5'd8,    "卡片 00 左沿 (96,100)");

        // =====================================================================
        $display("---- 4b. v19 状态条 [系统 ⚙]：x 864..928、y 0..47 ----");
        //   ★ ⚙ 是状态条右端唯一的入口（spec 4.1：状态条里只有它算顶层入口，
        //     → P8）；命中区在 y 上伸进标题带到 47 —— 状态条本体只有 24 px 高，
        //     单靠它撑不到 spec 6.1 的 40 px 最小触控目标。
        //   ★ [信号 ●] / [告警 ▲] 是**纯指示器、没有编号**：点它们只落到
        //     状态条本体 id=6，策略层不消费。
        // =====================================================================
        chk_tap(16'd864, 16'd12, 5'd7,       "⚙ 左沿 x=864");
        chk_tap(16'd896, 16'd12, 5'd7,       "⚙ 中心 (896,12)");
        chk_tap(16'd927, 16'd12, 5'd7,       "⚙ 右沿 x=927");
        chk_tap(16'd896, 16'd47, 5'd7,       "⚙ 命中区下沿 y=47");
        chk_tap(16'd863, 16'd12, HIT_SBAR,   "⚙ 左侧 x=863 仍是状态条本体");
        chk_tap(16'd928, 16'd12, HIT_SBAR,   "⚙ 右侧 x=928 仍是状态条本体");
        chk_tap(16'd896, 16'd48, HIT_NONE,   "⚙ 下方 y=48 空命中");
        chk_tap(16'd768, 16'd12, HIT_SBAR,   "[信号 ●] 无编号 ⇒ 状态条本体");
        chk_tap(16'd832, 16'd12, HIT_SBAR,   "[告警 ▲] 无编号 ⇒ 状态条本体");
        chk_tap(16'd1000,16'd12, HIT_SBAR,   "活性灯区 x=1000 仍是状态条本体");

        //   ★ v19 的 P6 危险区按钮**故意不在这张表里**：它的矩形
        //     184..648 x 512..592 与下面这两张卡片完全重叠，而本模块不认识
        //     页号 ⇒ 放这里只会"抢卡片"或"被卡片抢走"（只剩 32 px 缝能点中）。
        //     P6 上由策略层按坐标 + page==5 判（disp/enc_top_disp.v 4.9 节）。
        //     下面两条把这个几何事实钉住：谁要是将来又把危险区矩形塞进
        //     hit_test，这里会立刻报出来。
        chk_tap(16'd300, 16'd560, 5'd11, "危险区左半（几何上是卡片 01）");
        chk_tap(16'd500, 16'd560, 5'd12, "危险区右半（几何上是卡片 11）");

        // =====================================================================
        $display("---- 4c. v20 标题带主操作按钮：x 660..820、y 24..64 ----");
        //   ★ 这个矩形与卡片（y >= 64）、导航（x < 80）、状态条（y < 24）、
        //     ⚙（x >= 864）**都不相交** ⇒ 可以进本表（与 P2/P3 的 Tab 栏相反：
        //     那条压在卡片 01/02 上，只能由策略层按坐标 + 页号判）。
        //   ★ 左沿 660、右沿 819/820、下沿 63/64 三条都在这里钉住：
        //     谁改了 disp/hit_test.v 的 TBTN_* 参数，这里立刻报出来。
        //   ★ 本表**不认识页号** —— 它在 P1 上是「标定」、在 P4 上是「展开」，
        //     两页共用同一个矩形是设计（disp/enc_top_disp.v 4.9 节按 page 分派）。
        // =====================================================================
        chk_tap(16'd660, 16'd24, 5'd15,      "标题带按钮 左上角 (660,24)");
        chk_tap(16'd819, 16'd63, 5'd15,      "标题带按钮 右下角 (819,63)");
        chk_tap(16'd700, 16'd44, 5'd15,      "标题带按钮 中心 (700,44)");
        chk_tap(16'd659, 16'd24, HIT_NONE,   "左沿外 x=659 空命中");
        chk_tap(16'd820, 16'd24, HIT_NONE,   "右沿外 x=820 空命中");
        chk_tap(16'd700, 16'd23, HIT_SBAR,   "上沿外 y=23 落回状态条本体");
        chk_tap(16'd710, 16'd64, HIT_NONE,   "下沿外 y=64 空命中（x=710 在卡片列的缝里）");

        // =====================================================================
        $display("---- 5. 一次接触只报一次 ----");
        // =====================================================================
        sample(3'd0, 16'd496, 16'd192, stb, id);        // 抬起
        sample(3'd1, 16'd496, 16'd192, stb, id);        // 按下
        n_chk = n_chk + 1;
        if (!stb || (id !== 5'd9)) begin
            errors = errors + 1;
            $display("[FAIL] 第一次接触未按预期报出 id=9（stb=%0d id=%0d）", stb, id);
        end else begin
            $display("[ OK ] 第一次接触报出 id=9 (496,192)");
        end
        // hit_x/hit_y 是给上层调试用的，必须与触发坐标一致
        n_chk = n_chk + 1;
        if ((hit_x !== 12'd496) || (hit_y !== 12'd192)) begin
            errors = errors + 1;
            $display("[FAIL] hit_x/hit_y = (%0d,%0d)，期望 (496,192)", hit_x, hit_y);
        end else begin
            $display("[ OK ] hit_x/hit_y 记录了触发坐标 (496,192)");
        end

        chk_no_repeat(16'd496, 16'd192, "同一位置的后续样本");
        chk_no_repeat(16'd480, 16'd400, "按住滑动到另一张卡");

        // 抬起后重新武装
        sample(3'd0, 16'd480, 16'd400, stb, id);
        sample(3'd1, 16'd480, 16'd400, stb, id);
        n_chk = n_chk + 1;
        if (!stb || (id !== 5'd12)) begin
            errors = errors + 1;
            $display("[FAIL] 抬起后再按未触发（stb=%0d id=%0d，期望 id=12）", stb, id);
        end else begin
            $display("[ OK ] 抬起后再按可再次触发（id=%0d）", id);
        end

        // 从别处拖进控件：起点已消耗掉这次接触，拖进来不应触发
        sample(3'd0, 16'd500, 16'd10, stb, id);         // 抬起
        sample(3'd1, 16'd500, 16'd10, stb, id);         // 落在状态条上
        n_chk = n_chk + 1;
        if (!stb || (id !== HIT_SBAR)) begin
            errors = errors + 1;
            $display("[FAIL] 状态条上的接触未报出（stb=%0d id=%0d，期望 id=6）", stb, id);
        end else begin
            $display("[ OK ] 状态条上的接触报出 id=6");
        end
        chk_no_repeat(16'd496, 16'd192, "拖进卡片");

        // =====================================================================
        $display("---- 6. hit_stb 是单拍脉冲 ----");
        // =====================================================================
        sample(3'd0, 16'd16, 16'd300, stb, id);
        sample(3'd1, 16'd16, 16'd300, stb, id);         // 触发
        @(posedge clk); #1;                             // 再等一拍
        n_chk = n_chk + 1;
        if (hit_stb !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] hit_stb 持续了不只一拍");
        end else begin
            $display("[ OK ] hit_stb 是单拍脉冲");
        end

        // =====================================================================
        $display("---- 7. 越界坐标不算命中 ----");
        //   若实现里把 16 位坐标直接截成低 12 位，1024 会折成 0 ⇒ 在状态条
        //   左端凭空多出一次命中。这一节就是那个缺陷的回归判据。
        // =====================================================================
        chk_miss(16'd1024, 16'd100,         "x=1024（不是 x=0）");
        chk_miss(16'd2048, 16'd100,         "x=2048（低 12 位为 0）");
        chk_miss(16'd500,  16'd600,         "y=600");
        chk_miss(16'd500,  16'd4096,        "y=4096（低 12 位为 0）");
        chk_miss(16'hFFFF, 16'hFFFF,        "坐标全 1（面板未锁定时的垃圾值）");

        // =====================================================================
        $display("---- 8. 复位后第一拍即可响应 ----");
        // =====================================================================
        //   ★ 同时把 tch_toggle 拉回 0 —— 实机上 touch_i2c_ctrl 复位时
        //     tch_toggle <= 1'b0（disp/touch_ctrl.v:292），两边必须从同一个
        //     相位出发；否则复位后 DUT 会把"当前这组旧样本"当成一次新样本。
        rst_n      = 1'b0;
        tch_toggle = 1'b0;
        tch_num    = 3'd0;
        tch_x0     = 16'd0;
        tch_y0     = 16'd0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        chk_tap(16'd16, 16'd71, 5'd0, "复位后第一次接触");

        // =====================================================================
        $display("---- 9. v22 触摸生命周期：held / rel_stb / cur_x,y ----");
        //   批次④ 的拖拽与长按必须知道"现在还有没有手指、手指在哪、
        //   什么时候抬起来"。这三件事以前只有 I2C 层知道，命中层把
        //   "按住"当成"已经处理过的一次接触"就丢掉了（armed 机制）。
        //   ★ 老的 hit_stb/hit_id 语义一位没变，这一节只验新增的那三样。
        // =====================================================================
        //   上一节的最后一次接触还按着，先把它抬起来 —— 这一拍恰好就是
        //   "抬起"事件本身（rel_stb 必须报出来，且只报一拍）
        sample(3'd0, 16'd496, 16'd192, stb, id);
        n_chk = n_chk + 1;
        if (hit_held !== 1'b0 || hit_rel !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] 抬起那拍 held=%0d rel=%0d，期望 0/1", hit_held, hit_rel);
        end else begin
            $display("[ OK ] 抬起那拍 held=0 rel=1");
        end

        @(posedge clk); #1;
        n_chk = n_chk + 1;
        if (hit_rel !== 1'b0 || hit_held !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] rel 不是单拍（held=%0d rel=%0d）", hit_held, hit_rel);
        end else begin
            $display("[ OK ] rel 是单拍脉冲，无接触时 held=0");
        end

        //   按下：held 起来、rel 不起、坐标就是按下点
        sample(3'd1, 16'd496, 16'd192, stb, id);
        n_chk = n_chk + 1;
        if (hit_held !== 1'b1 || hit_rel !== 1'b0 ||
            hit_cur_x !== 12'd496 || hit_cur_y !== 12'd192) begin
            errors = errors + 1;
            $display("[FAIL] 按下后 held=%0d rel=%0d cur=(%0d,%0d)，期望 1/0/(496,192)",
                     hit_held, hit_rel, hit_cur_x, hit_cur_y);
        end else begin
            $display("[ OK ] 按下后 held=1 rel=0 cur=(496,192)");
        end

        //   按住拖到别处：held 保持、坐标跟着走、但不再报点击事件
        sample(3'd1, 16'd700, 16'd300, stb, id);
        n_chk = n_chk + 1;
        if (hit_held !== 1'b1 || hit_cur_x !== 12'd700 || hit_cur_y !== 12'd300) begin
            errors = errors + 1;
            $display("[FAIL] 拖拽中 held=%0d cur=(%0d,%0d)，期望 1/(700,300)",
                     hit_held, hit_cur_x, hit_cur_y);
        end else if (stb !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] 拖拽中又报了一次点击事件（按住不连发被破坏了）");
        end else begin
            $display("[ OK ] 拖拽中 held=1 cur=(700,300) 且不连发");
        end

        //   垃圾坐标（面板没锁定时 I2C 会给全 1）：held 保持，但坐标不能被污染
        sample(3'd1, 16'hFFFF, 16'hFFFF, stb, id);
        n_chk = n_chk + 1;
        if (hit_held !== 1'b1 || hit_cur_x !== 12'd700 || hit_cur_y !== 12'd300) begin
            errors = errors + 1;
            $display("[FAIL] 垃圾坐标被采信了：held=%0d cur=(%0d,%0d)，期望 1/(700,300)",
                     hit_held, hit_cur_x, hit_cur_y);
        end else begin
            $display("[ OK ] 垃圾坐标不污染 cur（保持 (700,300)）");
        end

        //   抬起：rel 是单拍脉冲、held 落下、坐标冻结在最后合法值
        sample(3'd0, 16'd700, 16'd300, stb, id);
        n_chk = n_chk + 1;
        if (hit_held !== 1'b0 || hit_rel !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] 抬起那拍 held=%0d rel=%0d，期望 0/1", hit_held, hit_rel);
        end else begin
            $display("[ OK ] 抬起那拍 held=0 rel=1");
        end

        @(posedge clk); #1;
        n_chk = n_chk + 1;
        if (hit_rel !== 1'b0 || hit_cur_x !== 12'd700 || hit_cur_y !== 12'd300) begin
            errors = errors + 1;
            $display("[FAIL] rel 不是单拍（=%0d）或坐标没冻结（=(%0d,%0d)）",
                     hit_rel, hit_cur_x, hit_cur_y);
        end else begin
            $display("[ OK ] rel 是单拍脉冲，坐标冻结在 (700,300)");
        end

        //   再按一次：held 重新起来（长按/拖拽可以被连续触发）
        sample(3'd0, 16'd700, 16'd300, stb, id);
        sample(3'd1, 16'd300, 16'd496, stb, id);
        n_chk = n_chk + 1;
        if (hit_held !== 1'b1 || hit_cur_x !== 12'd300 || hit_cur_y !== 12'd496) begin
            errors = errors + 1;
            $display("[FAIL] 第二次按下 held=%0d cur=(%0d,%0d)，期望 1/(300,496)",
                     hit_held, hit_cur_x, hit_cur_y);
        end else begin
            $display("[ OK ] 第二次按下重新武装（held=1 cur=(300,496)）");
        end
        sample(3'd0, 16'd300, 16'd496, stb, id);

        //   复位把 held 清掉（否则上电后会以为手指一直按着）
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        n_chk = n_chk + 1;
        if (hit_held !== 1'b0 || hit_rel !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] 复位后 held=%0d rel=%0d，期望 0/0", hit_held, hit_rel);
        end else begin
            $display("[ OK ] 复位把 held/rel 清零");
        end
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("================================================");
        $display(" 判据 %0d 条", n_chk);
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED (%0d errors)", errors);
        $display("================================================");
        $finish;
    end

endmodule

`default_nettype wire
