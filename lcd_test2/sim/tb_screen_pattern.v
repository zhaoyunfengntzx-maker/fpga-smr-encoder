//==========================================================================
// tb_screen_pattern.v —— 画面生成自检（F1 色轮播 / F2 网格与坐标 / F3 准星与保留）
//   做法：不跑真实扫描时序（那样一个颜色要 3500 万拍），而是
//     ① 直接给 pix_x/pix_y/de 采任意像素（screen_pattern 对像素是纯组合的）
//     ② 用 frame_st 脉冲驱动"帧"级状态（换色、锁存触点、保留计数）
//==========================================================================
`timescale 1ns / 1ps

module tb_screen_pattern;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg [11:0] pix_x = 12'd0, pix_y = 12'd0;
    reg        de = 1'b0;
    reg        frame_st = 1'b0;
    reg        key_mode = 1'b0, key_paused = 1'b0;
    reg        tch_valid = 1'b0, int_n = 1'b1;
    reg [1:0]  tch_type = 2'd1;
    reg [2:0]  tch_num = 3'd0;
    reg [15:0] tch_x0=16'd0, tch_y0=16'd0, tch_x1=16'd0, tch_y1=16'd0,
               tch_x2=16'd0, tch_y2=16'd0, tch_x3=16'd0, tch_y3=16'd0,
               tch_x4=16'd0, tch_y4=16'd0;
    reg [7:0]  gt_status_raw = 8'h00;

    wire [23:0] pixel_data;
    wire [2:0]  color_idx;
    wire [2:0]  disp_num;
    wire [23:0] frame_cnt;

    integer errors = 0;

    always #10 clk = ~clk;      // 50MHz

    screen_pattern u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .de            (de),
        .pix_x         (pix_x),
        .pix_y         (pix_y),
        .frame_st      (frame_st),
        .mode          (key_mode),
        .paused        (key_paused),
        .tch_valid     (tch_valid),
        .tch_type      (tch_type),
        .tch_num       (tch_num),
        .tch_x0        (tch_x0), .tch_y0 (tch_y0),
        .tch_x1        (tch_x1), .tch_y1 (tch_y1),
        .tch_x2        (tch_x2), .tch_y2 (tch_y2),
        .tch_x3        (tch_x3), .tch_y3 (tch_y3),
        .tch_x4        (tch_x4), .tch_y4 (tch_y4),
        .gt_status_raw (gt_status_raw),
        .int_n         (int_n),
        .pixel_data    (pixel_data),
        .color_idx     (color_idx),
        .disp_num      (disp_num),
        .frame_cnt     (frame_cnt)
    );

    task pulse_frame;
        begin
            @(posedge clk);
            frame_st = 1'b1;
            @(posedge clk);
            frame_st = 1'b0;
        end
    endtask

    task frames;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) pulse_frame;
        end
    endtask

    task rd_pix;
        input  [11:0] x;
        input  [11:0] y;
        output [23:0] c;
        begin
            pix_x = x; pix_y = y; de = 1'b1;
            @(posedge clk);
            #1 c = pixel_data;
            de = 1'b0;
            @(posedge clk);
        end
    endtask

    reg [23:0] px;
    integer    i;
    integer    white_cnt;

    task chk24;
        input [8*40:1] name;
        input [23:0]   got;
        input [23:0]   exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %0s: got %06X expected %06X", name, got, exp);
            end else begin
                $display("[ OK ] %0s = %06X", name, got);
            end
        end
    endtask

    task chkint;
        input [8*40:1] name;
        input integer  got;
        input integer  exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %0s: got %0d expected %0d", name, got, exp);
            end else begin
                $display("[ OK ] %0s = %0d", name, got);
            end
        end
    endtask

    initial begin
        $display("== tb_screen_pattern: F1/F2/F3 画面自检 ==");
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ------------------------------------------------ T1 复位状态
        chkint("T1 复位后 color_idx", color_idx, 0);
        chkint("T1 复位后 disp_num", disp_num, 0);
        rd_pix(12'd512, 12'd300, px);
        chk24("T1 首色=WHITE 满屏", px, 24'hFFFFFF);

        // ------------------------------------------------ T2 F1 色轮播 1s/色
        frames(58);
        chkint("T2 58 帧后 color_idx", color_idx, 1);
        rd_pix(12'd512, 12'd300, px);
        chk24("T2 第 2 色=BLACK", px, 24'h000000);
        frames(58);
        chkint("T2 再 58 帧后 color_idx", color_idx, 2);
        rd_pix(12'd512, 12'd300, px);
        chk24("T2 第 3 色=RED", px, 24'hFF0000);

        // ------------------------------------------------ T3 F1 左上角小字
        // color_idx=2(RED) 时左上角应同时有白字与深色底
        white_cnt = 0;
        for (i = 0; i < 96; i = i + 1) begin
            rd_pix(12'd8 + i[11:0], 12'd8, px);       // 字符第 0 行
            if (px == 24'hFFFFFF) white_cnt = white_cnt + 1;
        end
        if (white_cnt == 0) begin
            errors = errors + 1;
            $display("[FAIL] T3 左上角小字：%0d 个白像素（应有）", white_cnt);
        end else begin
            $display("[ OK ] T3 左上角小字白像素 = %0d", white_cnt);
        end
        rd_pix(12'd8, 12'd8, px);
        if (px !== 24'hFFFFFF && px !== 24'h101010) begin
            errors = errors + 1;
            $display("[FAIL] T3 左上角底色异常 %06X", px);
        end

        // ------------------------------------------------ T4 F2 网格
        key_mode = 1'b1;
        pulse_frame;
        rd_pix(12'd500, 12'd300, px);
        chk24("T4 非网格处底色", px, 24'h101820);
        rd_pix(12'd64, 12'd300, px);
        chk24("T4 64px 普通网格线", px, 24'h2A3A4A);
        rd_pix(12'd128, 12'd300, px);
        chk24("T4 128px 主网格线", px, 24'h4A6A8A);

        // ------------------------------------------------ T5 F3 单点准星
        tch_num = 3'd1; tch_x0 = 16'd600; tch_y0 = 16'd256;
        pulse_frame;
        chkint("T5 锁存点数", disp_num, 1);
        rd_pix(12'd600, 12'd256, px);
        chk24("T5 准星中心=T1 白", px, 24'hFFFFFF);
        rd_pix(12'd616, 12'd256, px);
        chk24("T5 准星横臂末端", px, 24'hFFFFFF);
        rd_pix(12'd617, 12'd256, px);
        if (px === 24'hFFFFFF) begin
            errors = errors + 1;
            $display("[FAIL] T5 横臂超长：617 处仍是白色");
        end else begin
            $display("[ OK ] T5 横臂在 +16 处结束");
        end
        // 准星旁编号 T1：在 (+14,+14) 起 2 个字符处应有白像素
        white_cnt = 0;
        for (i = 0; i < 16; i = i + 1) begin
            rd_pix(12'd614 + i[11:0], 12'd272, px);
            if (px == 24'hFFFFFF) white_cnt = white_cnt + 1;
        end
        if (white_cnt == 0) begin
            errors = errors + 1;
            $display("[FAIL] T5 编号 T1 未画出");
        end else begin
            $display("[ OK ] T5 编号 T1 白像素 = %0d", white_cnt);
        end

        // ------------------------------------------------ T6 多点颜色
        tch_num = 3'd3;
        tch_x0 = 16'd600; tch_y0 = 16'd256;
        tch_x1 = 16'd300; tch_y1 = 16'd450;
        tch_x2 = 16'd800; tch_y2 = 16'd500;
        pulse_frame;
        chkint("T6 三点锁存", disp_num, 3);
        rd_pix(12'd300, 12'd450, px);
        chk24("T6 T2=RED", px, 24'hFF0000);
        rd_pix(12'd800, 12'd500, px);
        chk24("T6 T3=GREEN", px, 24'h00FF00);
        rd_pix(12'd600, 12'd256, px);
        chk24("T6 T1 仍在=WHITE", px, 24'hFFFFFF);

        // ------------------------------------------------ T7 抬手保留 0.5s
        tch_num = 3'd0;
        pulse_frame;
        chkint("T7 抬手 1 帧仍在", disp_num, 3);
        rd_pix(12'd300, 12'd450, px);
        chk24("T7 抬手 1 帧准星仍在", px, 24'hFF0000);
        frames(29);
        chkint("T7 抬手 30 帧仍在", disp_num, 3);
        pulse_frame;                       // 第 31 帧：保留计数到 0
        frames(2);
        chkint("T7 抬手 31 帧后消失", disp_num, 0);
        rd_pix(12'd300, 12'd450, px);
        if (px === 24'hFF0000) begin
            errors = errors + 1;
            $display("[FAIL] T7 准星未消失");
        end else begin
            $display("[ OK ] T7 准星已消失");
        end

        // ------------------------------------------------ T8 F2 面板与坐标数字
        rd_pix(12'd10, 12'd10, px);
        if (px !== 24'h080808 && px !== 24'hFFFFFF) begin
            errors = errors + 1;
            $display("[FAIL] T8 信息面板底色异常 %06X", px);
        end else begin
            $display("[ OK ] T8 信息面板已绘制 (%06X)", px);
        end
        white_cnt = 0;
        for (i = 0; i < 320; i = i + 1) begin
            rd_pix(i[11:0], 12'd584, px);
            if (px == 24'hFFFFFF) white_cnt = white_cnt + 1;
        end
        if (white_cnt == 0) begin
            errors = errors + 1;
            $display("[FAIL] T8 底部 X 坐标数字未画出");
        end else begin
            $display("[ OK ] T8 底部坐标数字白像素 = %0d", white_cnt);
        end

        // ------------------------------------------------ T9 暂停冻结色轮播
        key_mode = 1'b0;
        pulse_frame;
        key_paused = 1'b1;
        i = color_idx;
        frames(120);
        chkint("T9 暂停后 color_idx 不变", color_idx, i);
        key_paused = 1'b0;
        frames(58);
        if (color_idx == i) begin
            errors = errors + 1;
            $display("[FAIL] T9 取消暂停后仍未换色");
        end else begin
            $display("[ OK ] T9 取消暂停后恢复换色 -> %0d", color_idx);
        end

        $display("frame_cnt = %0d", frame_cnt);
        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
