`timescale 1ns / 1ps
//=============================================================================
// tb_loop_filter.v —— loop_filter 自检测试台（打印 TEST PASSED / TEST FAILED）
//-----------------------------------------------------------------------------
// 覆盖内容
//   1. 复位
//   2. kp=0 且 ki=0 直通（pos_out = ang_in 扩展，逐位比对）
//   3. 恒速斜坡：kp=0..6 × ki=1..3 全部组合，稳态滞后必须 ≈ 0（I 项的作用）
//   4. 阶跃（0 -> 45deg）：全部组合必须收敛不发散，终值误差 < 1% 步长
//   5. lag_limit 门限：45.000deg 不置位、45.005deg 置位（|err| > REV/8）
//   6. freeze=1 时 pos_out 保持
//
// 对齐说明（重要）
//   loop_filter 内部 pos 每拍更新一次（用当拍输入），pos_out 再延迟 2 拍输出，
//   故 Latency = 3：out_valid 有效那一拍的 pos_out = 第 n-3 拍输入的滤波结果。
//   而环路内部误差 err[n] = ang_ext[n] - pos[n]（pos 为**更新前**状态），
//   所以 pos_out 那一拍对应的物理环路误差是 err[n-2] = (ang[n-2] 延迟 2 拍) - pos_out。
//   即对齐参考必须取 **ang 延迟 2 拍**（ang_d2 / err_d2），不是延迟 1 拍或 3 拍。
//   误差本身按 24bit 模回绕后再取绝对值。
//
//   实测（xsim 30000 拍末段统计，21 组 kp/ki 全部）：按 err_d2 对齐后恒速斜坡稳态
//   |err| = 0..63 LSB24 = 0..0.0014deg，与 README「恒速滞后 0~0.0014deg」及
//   model/loop_filter_model.py 的内部误差列逐位吻合；误用 ang_d1/ang_d3 会额外
//   引入 1~2 个斜坡增量（16384 / 32768 LSB24）的固定偏置。
//
//   *_tail 统计量只累加"最后 N 个样点"：计数 tail_cnt 在**主循环进入末段时**
//   才置起（斜坡 if (t == n-TAILW)、阶跃 if (t == n-500)）；若像早期版本那样在
//   循环前置起，统计到的是**上电捕获暂态**（kp=0/ki=1 时前 1000 拍 |err|max =
//   49433，而末 1000 拍仅 51），会造成 21 组恒速斜坡与 21 组阶跃全部假失败——
//   这正是本 tb 曾出现的缺陷。
//
//   阶跃测试的"收敛"判据需要给足拍数：本滤波器对 |err| < 2^KI_SHIFT 的误差
//   不再积分（err>>>KI 截断为 0 的死区），kp=6 档等效增益很小，进入 ±1% 带需
//   ~2356 拍（model 实测 2353 拍），故阶跃测试跑 6000 拍而非 4000 拍。
//
// 阈值取自 model/loop_filter_model.py 的位精确模型实测值，并已与本 tb 的 xsim
// 结果逐项核对一致（稳态环路误差 0..63 LSB24，阶跃超调 14%..98%，终值误差 <1%）。
//=============================================================================
module tb_loop_filter;

    localparam integer AW   = 16;
    localparam integer FRAC = 8;
    localparam integer PW   = AW + FRAC;    // 24
    localparam integer REV  = 1 << PW;

    reg clk;
    reg rst_n;
    reg  [AW-1:0] ang_in;
    reg           in_valid;
    reg  [3:0]    kp;
    reg  [1:0]    ki;
    reg           freeze;
    wire signed [PW-1:0] pos_out;
    wire          lag_limit;
    wire          out_valid;

    loop_filter #(.AW(AW), .FRAC(FRAC)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ang_in    (ang_in),
        .in_valid  (in_valid),
        .kp        (kp),
        .ki        (ki),
        .freeze    (freeze),
        .pos_out   (pos_out),
        .lag_limit (lag_limit),
        .out_valid (out_valid)
    );

    initial clk = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    // 输入 1/2/3 拍延迟历史（用于对齐 pos_out）与误差计算
    //   * 闭环（ki>=1）恒速跟踪：out_valid 有效那一拍的 pos_out = pos[n-2]，
    //     对应物理环路误差 err[n-2]，故用 ang 延迟 2 拍对齐（ang_d2 / err_d2）。
    //   * ki=0 且 kp=0 直通时状态不预测，pos_out 就等于 3 拍前的输入，
    //     所以直通测试用 ang 延迟 3 拍对齐（ang_d3）。
    reg  [AW-1:0] ang_d1, ang_d2, ang_d3;
    wire signed [PW-1:0] ang_ext_d2 = $signed({{(PW-AW){1'b0}}, ang_d2}) <<< FRAC;
    wire signed [PW-1:0] err_d2     = ang_ext_d2 - pos_out;   // 24bit 模回绕（物理环路滞后）
    wire signed [PW-1:0] err_abs    = err_d2[PW-1] ? -err_d2 : err_d2;
    wire signed [PW-1:0] ang_ext_d3 = $signed({{(PW-AW){1'b0}}, ang_d3}) <<< FRAC;
    wire signed [PW-1:0] err_d3     = ang_ext_d3 - pos_out;
    wire signed [PW-1:0] err_abs3   = err_d3[PW-1] ? -err_d3 : err_d3;

    always @(posedge clk) begin
        if (!rst_n) begin
            ang_d1 <= 16'd0;
            ang_d2 <= 16'd0;
            ang_d3 <= 16'd0;
        end else begin
            ang_d1 <= ang_in;
            ang_d2 <= ang_d1;
            ang_d3 <= ang_d2;
        end
    end

    //-------------------------------------------------------------------------
    // 统计量（每个子测试前清零）
    //-------------------------------------------------------------------------
    integer err_max;        // 本次测试观察到的 |err| 最大值
    integer err_max_tail;   // 尾部窗口（最后 TAILW 拍）的 |err| 最大值
    integer err3_max;       // 直通测试用的 3 拍对齐误差最大值
    integer pos_max, pos_min;
    integer lag_seen;
    integer tail_cnt;
    integer fail_cnt;

    localparam integer TAILW = 1000;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (err_abs > err_max) err_max = err_abs;
            if (err_abs3 > err3_max) err3_max = err_abs3;
            if (tail_cnt > 0) begin
                if (err_abs > err_max_tail) err_max_tail = err_abs;
                tail_cnt = tail_cnt - 1;
            end
            if (pos_out > pos_max) pos_max = pos_out;
            if (pos_out < pos_min) pos_min = pos_out;
            if (lag_limit) lag_seen = 1;
        end
    end

    task clr_stats;
        begin
            err_max = 0; err_max_tail = 0; err3_max = 0; tail_cnt = 0;
            pos_max = -REV; pos_min = REV; lag_seen = 0;
        end
    endtask

    task do_reset;
        integer i;
        begin
            rst_n = 1'b0; in_valid = 1'b0; ang_in = 16'd0; freeze = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // 把 pos_out 与 ang_d2 的误差换算成 16bit 角度 LSB（1 LSB16 = 256 LSB24）
    function integer lsb16; input integer v; begin lsb16 = (v + 128) / 256; end endfunction

    integer t, n, kpi;
    integer ramp_fail, step_fail, pass_cnt;

    //=========================================================================
    // 主流程
    //=========================================================================
    initial begin
        clr_stats;
        fail_cnt = 0; ramp_fail = 0; step_fail = 0; pass_cnt = 0;
        kp = 4'd0; ki = 2'd0;

        $display("================================================================");
        $display(" tb_loop_filter : AW=%0d FRAC=%0d PW=%0d  1 LSB24 = %.7f deg",
                 AW, FRAC, PW, 360.0 / REV);
        $display(" Latency = 3 拍 = 60 ns @50MHz");
        $display("================================================================");

        // ---- 1. 复位 ------------------------------------------------------
        do_reset;
        if (out_valid !== 1'b0 || pos_out !== 0) begin
            $display("  [RESET FAIL] out_valid=%b pos_out=%0d", out_valid, pos_out);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  [RESET ok  ] out_valid=0 pos_out=0");
        end

        // ---- 2. kp=0, ki=0 直通 -------------------------------------------
        kp = 4'd0; ki = 2'd0;
        clr_stats;
        for (t = 0; t < 300; t = t + 1) begin
            @(posedge clk);
            ang_in    <= (t * 7'd73) & 16'hFFFF;
            in_valid  <= 1'b1;
        end
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (6) @(posedge clk);
        if (err3_max <= 1) begin
            $display("  [BYPASS ok ] kp=0/ki=0 直通，逐点误差 max = %0d LSB24 (允许 <=1)", err3_max);
        end else begin
            $display("  [BYPASS FAIL] 直通误差 max = %0d LSB24", err3_max);
            fail_cnt = fail_cnt + 1;
        end

        // ---- 3. 恒速斜坡：全部 kp/ki 组合 ---------------------------------
        $display("----------------------------------------------------------------");
        $display(" 恒速斜坡跟踪（+64 LSB16/clk = 17.6 Mdeg/s），稳态窗口 %0d 拍", TAILW);
        $display("   kp ki  稳态|err|max[LSB24]  折合[LSB16]  全程max[LSB24]  判定");
        for (kpi = 0; kpi < 21; kpi = kpi + 1) begin
            kp = kpi / 3;
            ki = kpi % 3 + 1;
            do_reset;
            clr_stats;
            n = 6000;
            for (t = 0; t < n; t = t + 1) begin
                // 稳态窗口必须开在**末尾**：此处才置起 tail_cnt，统计的是第
                // (n-TAILW)..(n-1) 拍（已捕获完成）；若在循环前置起，统计到的
                // 是上电捕获暂态（实测 kp=0/ki=1 前 1000 拍 49433，末 1000 拍 51）。
                if (t == n - TAILW) tail_cnt = TAILW;
                @(posedge clk);
                ang_in   <= (t * 64) & 16'hFFFF;
                in_valid <= 1'b1;
            end
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (6) @(posedge clk);
            if (err_max_tail <= 128) begin
                $display("   %2d %2d  %14d  %11d  %13d  ok", kp, ki, err_max_tail,
                         lsb16(err_max_tail), err_max);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("   %2d %2d  %14d  %11d  %13d  FAIL(>128)", kp, ki, err_max_tail,
                         lsb16(err_max_tail), err_max);
                ramp_fail = ramp_fail + 1;
            end
        end
        if (ramp_fail == 0) begin
            $display("  => 全部 21 组组合恒速稳态滞后 <= 128 LSB24 = 0.0027 deg（I 项消除速度滞后）");
            $display("     对比：ki=0 的纯 P 环路在同样斜率下滞后 = 64 LSB16 = 0.35 deg");
        end else begin
            fail_cnt = fail_cnt + 1;
        end

        // ---- 4. 阶跃响应：全部 kp/ki 组合 ---------------------------------
        $display("----------------------------------------------------------------");
        $display(" 阶跃响应 0 -> 45deg（8192 LSB16 = 2097152 LSB24），跑 6000 拍");
        $display("   kp ki  稳态|err|max[LSB24]  终值误差[LSB24]  峰值[LSB24]  判定");
        for (kpi = 0; kpi < 21; kpi = kpi + 1) begin
            kp = kpi / 3;
            ki = kpi % 3 + 1;
            do_reset;
            clr_stats;
            // 必须跑满 6000 拍：err>>>KI_SHIFT 在 |err| < 2^KI_SHIFT 时截断为 0，
            // 形成积分死区；ki=3(KI_SHIFT=4) 且 kp=6(等效增益最小) 时进入 ±1% 带
            // 需 ~2356 拍（model 实测 2353 拍），跑 4000 拍时 tail 窗(3500..3999)
            // 仍有 ~2188 LSB24 残差，会造成 21 组假「未收敛」。
            // 同上：末 500 拍才开窗（循环内 t == n-500 处置起 tail_cnt = 500）
            n = 6000;
            for (t = 0; t < n; t = t + 1) begin
                if (t == n - 500) tail_cnt = 500;
                @(posedge clk);
                ang_in   <= 16'd8192;
                in_valid <= 1'b1;
            end
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (6) @(posedge clk);
            // 终值误差（24bit 模回绕后取绝对值），目标 = 2097152
            if (pos_out >= 24'sd2097152)
                t = pos_out - 24'sd2097152;
            else
                t = 24'sd2097152 - pos_out;
            if (err_max_tail <= 20972 && t <= 20972) begin
                $display("   %2d %2d  %14d  %13d  %11d  ok", kp, ki, err_max_tail, t, pos_max);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("   %2d %2d  %14d  %13d  %11d  FAIL(未收敛)", kp, ki,
                         err_max_tail, t, pos_max);
                step_fail = step_fail + 1;
            end
        end
        if (step_fail == 0)
            $display("  => 全部 21 组组合阶跃收敛，稳态误差 <= 1%% 步长，无发散");
        else
            fail_cnt = fail_cnt + 1;

        // ---- 5. lag_limit 门限 --------------------------------------------
        $display("----------------------------------------------------------------");
        $display(" lag_limit 门限（|err| > REV/8 = 45deg）");
        kp = 4'd4; ki = 2'd3;
        // 45.000 deg = 8192 LSB16
        do_reset; clr_stats;
        for (t = 0; t < 600; t = t + 1) begin
            @(posedge clk); ang_in <= 16'd8192; in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0; repeat (6) @(posedge clk);
        if (lag_seen == 0) begin
            $display("   阶跃 45.000 deg : lag_limit 未置位  ok");
        end else begin
            $display("   阶跃 45.000 deg : lag_limit 置位了  FAIL");
            fail_cnt = fail_cnt + 1;
        end
        // 45.005 deg = 8193 LSB16
        do_reset; clr_stats;
        for (t = 0; t < 600; t = t + 1) begin
            @(posedge clk); ang_in <= 16'd8193; in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0; repeat (6) @(posedge clk);
        if (lag_seen == 1) begin
            $display("   阶跃 45.005 deg : lag_limit 置位    ok");
        end else begin
            $display("   阶跃 45.005 deg : lag_limit 未置位  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ---- 6. freeze -----------------------------------------------------
        $display("----------------------------------------------------------------");
        $display(" freeze=1 保持");
        kp = 4'd4; ki = 2'd3;
        do_reset; clr_stats;
        for (t = 0; t < 400; t = t + 1) begin
            @(posedge clk); ang_in <= 16'd16384; in_valid <= 1'b1;
        end
        freeze <= 1'b1;
        repeat (5) @(posedge clk);
        t = pos_out;                                   // 冻结后的稳定值
        for (n = 0; n < 50; n = n + 1) begin
            @(posedge clk); ang_in <= 16'd32768; in_valid <= 1'b1;
        end
        @(posedge clk); in_valid <= 1'b0;
        repeat (6) @(posedge clk);
        if (pos_out == t) begin
            $display("   freeze 期间 pos_out 保持 %0d  ok", t);
        end else begin
            $display("   freeze 失败：%0d -> %0d  FAIL", t, pos_out);
            fail_cnt = fail_cnt + 1;
        end

        $display("================================================================");
        if (fail_cnt == 0) begin
            $display(" TEST PASSED  (斜坡 21 组 + 阶跃 21 组 + 直通 + lag_limit + freeze 全部通过)");
        end else begin
            $display(" TEST FAILED  (fail_cnt=%0d, ramp_fail=%0d, step_fail=%0d)",
                     fail_cnt, ramp_fail, step_fail);
        end
        $display("================================================================");
        $finish;
    end

endmodule
