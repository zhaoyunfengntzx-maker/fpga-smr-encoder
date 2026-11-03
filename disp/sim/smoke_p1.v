//=============================================================================
// smoke_p1.v -- 冒烟：渲染一整帧 P1，把文字层导出成 ASCII 缩略图
//
// 这一层要回答的是"版面和人眼看到的像不像"，它**替代不了** testbench：
//   - 它不断言任何东西，只打印；
//   - 它不测边界（行/帧计数、消隐期必须为黑、流水线对齐）——那些是
//     disp/tb_disp_engine.v 的职责。
//
// 放在 disp/sim/ 而不是 disp/ 是刻意的：tools/run_sim_disp.py 的源集合是
// disp/*.v，冒烟件若放在那里会被当成设计源参与回归。
//
// 用法：python tools/run_smoke_disp.py
//=============================================================================
`timescale 1ns / 1ps

module smoke_p1;

    reg clk = 1'b0;
    always #10 clk = ~clk;                   // 50 MHz

    localparam integer H_TOTAL = 1344;
    localparam integer V_TOTAL = 635;
    localparam integer H_START = 160;        // 20 + 140
    localparam integer V_START = 23;         // 3 + 20
    localparam integer H_DISP  = 1024;
    localparam integer V_DISP  = 600;

    localparam integer SX = 4;               // 每 4 px 取一个样
    localparam integer SY = 4;               // 每 4 行取一个样

    reg [11:0] hcnt = 12'd0;
    reg [11:0] vcnt = 12'd0;

    always @(posedge clk) begin
        if (hcnt == H_TOTAL - 1) begin
            hcnt <= 12'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 12'd0 : vcnt + 12'd1;
        end else begin
            hcnt <= hcnt + 12'd1;
        end
    end

    wire in_active = (hcnt >= H_START) && (hcnt < H_START + H_DISP) &&
                     (vcnt >= V_START) && (vcnt < V_START + V_DISP);
    wire [11:0] pix_x = hcnt - H_START;
    wire [11:0] pix_y = vcnt - V_START;

    reg  [23:0] lcd_rgb;
    wire        de_o;
    wire [11:0] dbg_x, dbg_y;

    // 复位：必须真的给一次复位脉冲。
    //   freq_meter / val_format 的寄存器只有异步复位一条初始化路径（这是可综合写法），
    //   若像早先那样把 rst_n 恒接 1'b1，仿真里它们永远是 x —— 实测症状就是
    //   数值层抓到 '?'（字符码 x）。硬件上上电会由 key_n 产生一次复位，仿真要照着做。
    reg rst_n = 1'b0;
    initial begin
        #1000;
        rst_n = 1'b1;
    end

    // 注意 pos_cnt 必须也被复位钳住：否则它在复位期间往前跑，而 freq_meter 的
    // pos_prev 被复位钉在 0，第一个增量会变成"复位期间的累计位移"（实测多算 48 拍，
    // 让 f_in 假性偏高 0.006%）。真实设计里编码器的 pos_full 与显示引擎同复位，没有这个跳变。
    reg [21:0] pos_cnt = 22'd0;
    always @(posedge clk) if (rst_n) pos_cnt <= pos_cnt + 22'd2;

    // 页选择（v15 起按 spec 4.4 页序）：0 = P1 总览，5 = P6 设置，7 = P8 触摸诊断。
    //   冒烟件用 `+define+PAGE6` / `+define+PAGE8` 换页。
    //   ★ tch_diag 一并在 P8 下给一组**非零假数据** —— 否则解包全 0，
    //     既看不出字段位置对不对，也证明不了 touch_view 真的在写。
`ifdef PAGE8
    reg [2:0] page_sel = 3'd7;
`else
    `ifdef PAGE7
    reg [2:0] page_sel = 3'd6;
    `else
    `ifdef PAGE6
    reg [2:0] page_sel = 3'd5;
    `else
    reg [2:0] page_sel = 3'd0;
    `endif
    `endif
`endif

    // P7 冒烟的抽头值：六个参数各不相同（三个有符号、两个无符号、一个 4 位），
    // 这样右栏每一格的"符号位 / 前导零抑制 / 数码"都被真实地走一遍；
    // 幅值随电角度箱起伏，左框画出来才是"带子"而不是一条线（能看出上下边界
    // 有没有接反）。默认档（P1/P6/P8）保持常量，避免影响那几页的缩略图。
`ifdef PAGE7
    localparam signed [15:0] SM_OFS_S   = -16'sd1234;
    localparam signed [15:0] SM_OFS_C   =  16'sd7;
    localparam        [15:0] SM_GAIN_S  =  16'd32768;
    localparam        [15:0] SM_GAIN_C  =  16'd40000;
    localparam signed [15:0] SM_PHASE_K = -16'sd32768;
    localparam         [3:0] SM_SHIFT   =  4'd5;
    // 12000 + 箱号*40 ⇒ 12000..17080 ⇒ 屏上 y = mag>>7 = 93..133（固定的
    // y = clamp(mag>>7, 0, 239) 映射，见 disp/p7_view.v）。
    wire [15:0] smoke_mag    = 16'd12000 + ({7'b0, pos_cnt[15:9]} * 16'd40);
    // mag = amp_sq[30:15]，所以 amp_sq = mag << 15。
    wire [31:0] smoke_amp_sq = {16'b0, smoke_mag} << 15;
`else
    localparam signed [15:0] SM_OFS_S   = 16'sd0;
    localparam signed [15:0] SM_OFS_C   = 16'sd0;
    localparam        [15:0] SM_GAIN_S  = 16'd32768;
    localparam        [15:0] SM_GAIN_C  = 16'd32768;
    localparam signed [15:0] SM_PHASE_K = 16'sd0;
    localparam         [3:0] SM_SHIFT   = 4'd0;
    wire [31:0] smoke_amp_sq = 32'h2000_0000;
`endif

    // P8 假诊断：[1:0]type=1(GT911)、[4:2]num=3、[20:5]x0=600、[36:21]y0=256、
    //          [44:37]status=0x05、[52:45]pid=0x39、[56:53]rst_cnt=2、
    //          [57]valid=1、[65:58]probe_gt=0x05、[73:66]probe_ft=0、
    //          [74]int_pin=1、[75]toggle=1、[99:76]reads=1234、
    //          [123:100]nack=0、[147:124]timeout=0
    wire [159:0] smoke_tch_diag = {
        12'hA5C, 24'd0, 24'd0, 24'd1234, 1'b1, 1'b1, 8'h00, 8'h05,
        1'b1, 4'd2, 8'h39, 8'h05, 16'd256, 16'd600, 3'd3, 2'd1
    };

    disp_engine u_dut (
        .clk(clk), .rst_n(rst_n),
    .page(page_sel),
        .pix_x(pix_x), .pix_y(pix_y), .de(in_active),
        .tap_angle(pos_cnt[15:0]), .tap_s_n(16'h0F00), .tap_c_n(16'h0A00),
        .tap_pos_full({10'b0, pos_cnt}),
        .tap_io_state(8'b0100_0001),
        .tap_io_flags(8'b0001_0001),
        .tap_stat(8'h00),
        .tap_cfg_inter(10'd64), .tap_cfg_div(3'd0), .tap_cfg_pairs(5'd4),
        // v14：P6 回读字段（本冒烟件只看 P1 版面，给固定值避免 P6 页写入 X）
        .tap_cfg_hyst_ab(5'd2), .tap_cfg_ablimit(8'd255), .tap_cfg_zwidth(4'd5),
        .tap_cfg_zphase(12'd0), .tap_cfg_uvwph(16'd0), .tap_cfg_pol(4'b0000),
        // P7 的七个抽头（v15）：默认档给固定值 —— 漏接的输入是 z，
        // 会让那一页的通路整片变 X（见 U-17 记录 28）。
        .tap_ofs_s(SM_OFS_S), .tap_ofs_c(SM_OFS_C),
        .tap_gain_s(SM_GAIN_S), .tap_gain_c(SM_GAIN_C),
        .tap_phase_k(SM_PHASE_K), .tap_shift(SM_SHIFT), .tap_amp_sq(smoke_amp_sq),
        .tap_abzen(1'b1), .tap_uwven(1'b0), .tap_calib_busy(1'b0), .tap_biss_crc_err(1'b0), .tap_biss_link_lost(1'b0),
        .tch_diag(smoke_tch_diag),
        .ui_state(2'd0),        // 改值事务：空闲
        .ui_err  (4'd0),
        .ui_dlg  (2'd0),        // v19 模态：本冒烟件不弹对话框（漏接 = X 会把整屏染成 X，
                                //            这行是 U-23 实测踩出来的：p1 光栅文字检查曾经 FAIL）
        .ui_dz_press(1'b0),     // v34（㊲）：按住电平同样必须绑死（同上，漏接 = X）
        .ui_dz_press2(1'b0), .ui_dlg_kind(1'b0), .ui_rst_state(2'd0), .ui_rst_bad(15'd0),
        // v22 编辑面板：本冒烟件不开面板（绑不激活值，理由同上）
        .pnl_on(1'b0), .pnl_inter(10'd64), .pnl_prog(6'd0), .pnl_press(4'd0),
        .pnl_fld(1'b0), .pnl_didx(3'd0),
        .pnl_pend(1'b0), .pnl_idx(3'd0), .pnl_undo_avail(1'b0), .pnl_undo_inter(10'd64),
        .pnl_undo_div(3'd0),
        .lcd_rgb(lcd_rgb), .de_o(de_o), .dbg_x(dbg_x), .dbg_y(dbg_y)
    );

    localparam [23:0] C_TEXT = 24'h1F2D3D;

    reg img [0:V_DISP/SY-1][0:H_DISP/SX-1];

    // 缩略图看不出 1~2 px 的对齐错误，所以另开两个 1:1 窗口：
    //   WIN A: x 0..175, y 60..84   —— 导航栏标签 + 中间 16 px 空隙 + 卡片 1 标签
    //   WIN B: x 160..383, y 139..180 —— 卡片 1 数值层 "1500.00" 的数字本体
`ifdef PAGE7
    // P7 的两个 1:1 窗口。缩略图每个 4x4 块只留一个像素（本文件 :202 的
    // `img[dbg_y>>2][dbg_x>>2] <= (lcd_rgb === C_TEXT)`，非阻塞赋值后写覆盖
    // 前写，等价于只取 x%4==3 && y%4==3 这个固定亚网格），16x16 汉字的笔画
    // 只有 1~2 px，正好落在这个网格的缝里 —— 汉字到底画出来没有，只能 1:1 看。
    //   WIN-A：左框标题「误差曲线」（格行 8 ⇒ y128；格列 7..10 ⇒ x112..175）
    //   WIN-B：图例「前」（格列 30 ⇒ x480）/「后」（格列 34 ⇒ x544）
    //          + 右框标题「参数」（格列 42 ⇒ x672）
    localparam integer WA_X0 = 96,  WA_X1 = 352, WA_Y0 = 120, WA_Y1 = 152;
    localparam integer WB_X0 = 480, WB_X1 = 800, WB_Y0 = 120, WB_Y1 = 152;
`else
    localparam integer WA_X0 = 0,   WA_X1 = 176, WA_Y0 = 60,  WA_Y1 = 85;
    //  导航栏标签「总览」（格列 1 ⇒ x16..47）与卡片 1 标签「输入频率」
    //  （格列 6 ⇒ x96..159）都落在 y60..84 这条带里，中间 x80..95 必须是空白 ——
    //  这就是"内容不许压进导航栏"的那 16 px 内边距，用眼睛就能验。
    //  WIN-B 看卡片 1（fld0 输入频率）的**数字本体**。fld0 是 9 字符宽的右对齐字段，
    //  起点在数值层格列 3（x=96），「  1525.88」里 2 个前导空格占 x96..159，
    //  数字从格列 5（x=160）开始 —— 窗口必须从这里切，否则只看到空格。
    //  数值字形是 30x42 放在 32x64 的格里、y_off=11，所以字形带就是 y139..180。
    localparam integer WB_X0 = 160, WB_X1 = 384, WB_Y0 = 139, WB_Y1 = 181;
`endif
    reg winA [0:WA_Y1-WA_Y0-1][0:WA_X1-WA_X0-1];
    reg winB [0:WB_Y1-WB_Y0-1][0:WB_X1-WB_X0-1];

    integer r, c;

    // ---- 直接从数值格式化器的写口抓字符 ----
    //   这是"卡上的读数是真实测量值"最直接的证据：它证明 disp_engine 里的
    //   freq_meter -> val_format -> 字符 RAM 这条通路在每帧消隐期真的跑了，
    //   而且写下去的字符就是由 pos_full 算出来的频率/转速。
    reg [5:0] vcap [0:511];
    integer fld, n;
    // 字段表：{格行, 格列, 宽度}，与 disp/val_format.v 的 f_row/f_col/f_wid 对应
    reg [3:0] frow [0:5];
    reg [4:0] fcol [0:5];
    reg [4:0] fwid [0:5];
    reg [3:0] trow [0:8];
    reg [4:0] tcol [0:8];
    reg [4:0] twid [0:8];

    always @(posedge clk) if (u_dut.vf_we) vcap[u_dut.vf_waddr] <= u_dut.vf_wdata;

    // v58：P8（触摸诊断页）与 touch_view 已删，这里不再拓 tcap 写口。

    function [7:0] to_ascii;
        input [5:0] ch;
        begin
            if      (ch == 6'd0) to_ascii = " ";
            else if (ch == 6'd1) to_ascii = ".";
            else if (ch == 6'd2) to_ascii = "-";
            else if (ch == 6'd3) to_ascii = "+";
            else if (ch == 6'd4) to_ascii = "/";
            else if (ch <= 6'd17) to_ascii = 8'h30 + (ch - 6'd8);
            else                  to_ascii = 8'h41 + (ch - 6'd18);
        end
    endfunction

    // ---- 取样：只在有效像素上取（消隐期 pix_x/pix_y 是无意义的下溢值）----
    always @(posedge clk) begin
        if (de_o && dbg_x[1:0] == 2'd0 && dbg_y[1:0] == 2'd0)
            img[dbg_y>>2][dbg_x>>2] <= (lcd_rgb === C_TEXT);
        if (de_o && dbg_x >= WA_X0 && dbg_x < WA_X1 && dbg_y >= WA_Y0 && dbg_y < WA_Y1)
            winA[dbg_y-WA_Y0][dbg_x-WA_X0] <= (lcd_rgb === C_TEXT);
        if (de_o && dbg_x >= WB_X0 && dbg_x < WB_X1 && dbg_y >= WB_Y0 && dbg_y < WB_Y1)
            winB[dbg_y-WB_Y0][dbg_x-WB_X0] <= (lcd_rgb === C_TEXT);
    end

    initial begin
        for (r = 0; r < V_DISP/SY; r = r + 1)
            for (c = 0; c < H_DISP/SX; c = c + 1)
                img[r][c] = 1'b0;
        for (r = 0; r < WA_Y1-WA_Y0; r = r + 1)
            for (c = 0; c < WA_X1-WA_X0; c = c + 1)
                winA[r][c] = 1'b0;
        for (r = 0; r < WB_Y1-WB_Y0; r = r + 1)
            for (c = 0; c < WB_X1-WB_X0; c = c + 1)
                winB[r][c] = 1'b0;

        // 一帧 = 635 * 1344 拍 * 20 ns = 17.0688 ms；留 25 ms 保证第一帧填完
        #25_000_000;

        $display("");
        $display("================ P1 smoke (%0dx%0d, '#'=text) ================",
                 H_DISP/SX, V_DISP/SY);
        for (r = 0; r < V_DISP/SY; r = r + 1) begin
            $write("  ");
            for (c = 0; c < H_DISP/SX; c = c + 1)
                $write("%s", img[r][c] ? "#" : ".");
            $write("\n");
        end
        $display("==============================================================");

        $display("WIN-A x%0d..%0d y%0d..%0d", WA_X0, WA_X1-1, WA_Y0, WA_Y1-1);
        for (r = 0; r < WA_Y1-WA_Y0; r = r + 1) begin
            $write("A%0d|", WA_Y0+r);
            for (c = 0; c < WA_X1-WA_X0; c = c + 1)
                $write("%s", winA[r][c] ? "#" : ".");
            $write("|\n");
        end

        $display("WIN-B x%0d..%0d y%0d..%0d", WB_X0, WB_X1-1, WB_Y0, WB_Y1-1);
        for (r = 0; r < WB_Y1-WB_Y0; r = r + 1) begin
            $write("B%0d|", WB_Y0+r);
            for (c = 0; c < WB_X1-WB_X0; c = c + 1)
                $write("%s", winB[r][c] ? "#" : ".");
            $write("|\n");
        end

        // ---- 数值层实测字符（由 val_format 在消隐期写入）----
        frow[0]=4'd2; fcol[0]=5'd3;  fwid[0]=5'd9;    // f_in   (2 位小数)
        frow[1]=4'd2; fcol[1]=5'd13; fwid[1]=5'd7;    // 倍频/分频
        frow[2]=4'd2; fcol[2]=5'd23; fwid[2]=5'd8;    // 转速   (1 位小数)
        frow[3]=4'd7; fcol[3]=5'd3;  fwid[3]=5'd7;    // 角度   (1 位小数)
        frow[4]=4'd7; fcol[4]=5'd13; fwid[4]=5'd8;    // 累计转数
        frow[5]=4'd7; fcol[5]=5'd23; fwid[5]=5'd8;    // ABZ 电平

        $display("MEASURED  f_q10 = %0d  (f_in = %0d.%02d Hz)", u_dut.fm_f_q10,
                 (u_dut.fm_f_q10 < 0 ? -u_dut.fm_f_q10 : u_dut.fm_f_q10) / 1024,
                 (((u_dut.fm_f_q10 < 0 ? -u_dut.fm_f_q10 : u_dut.fm_f_q10) % 1024) * 100) / 1024);
        $display("MEASURED  pos_acc = %0d  dir = %0d", u_dut.fm_pos_acc, u_dut.fm_dir);
        $display("VAL LAYER (captured from val_format write port):");
        for (fld = 0; fld < 6; fld = fld + 1) begin
            $write("  fld%0d row=%0d col=%0d : [", fld, frow[fld], fcol[fld]);
            for (n = 0; n < fwid[fld]; n = n + 1)
                $write("%c", to_ascii(vcap[{frow[fld], fcol[fld] + n[4:0]}]));
            $write("]\n");
        end

        $display("SMOKE DONE");        $finish;    end

    initial begin
        #40_000_000;
        $display("SMOKE TIMEOUT");
        $finish;
    end

endmodule
