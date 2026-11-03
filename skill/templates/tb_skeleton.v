// ===========================================================================
// tb_skeleton.v —— 自检式测试台骨架（逐点比对 + 超时保护 + 可判读结论行）
//
// 失效条件：假定 DUT 是"一拍进、一拍出"的流式接口（din_* 与 dout_* 一一对应）。
//   有乱序、多周期延迟、或一次输入产生多次输出的模块，必须把比对改成"按事务号配对"，
//   否则 FAIL 会指向错误的原因（本工程在记录 58/59 上吃过这个亏）。
//   另外 plusarg 形式在 xsim 上不可用，只保留 stim.txt 与内部斜坡两条路。
//
// 用法（三分钟）：
//   1. 把 `dut_passthrough` 换成你自己的模块名，改端口名与 W；
//   2. 决定激励来源：
//        A. 内部斜坡（默认，不依赖任何文件）——先确认"测试台本身能跑通"；
//        B. `+STIM=stim.txt`（每行 "输入 期望输出"，十进制或 0x 十六进制），
//           由黄金模型生成，这就是 skill/golden-model-bit-exact.md 的第 4 步。
//   3. 运行：xvlog/xelab 后 `xsim tb_skeleton -R -testplusarg STIM=stim.txt`
//      或 iverilog：`iverilog -o tb tb_skeleton.v dut_passthrough.v && vvp tb`
//
// 这个骨架存在的理由（都是真事，见 docs/ai-collaboration-log.md 记录 1/15/16）：
//   * 没有 $finish 的测试台会挂死，而挂死会被当成"还在跑"；
//   * 没有 #延时 超时保护的测试台在 DUT 不输出时会安静地打印 PASSED（0 次比较）；
//   * 只打印"比较了 N 次、极差很小"的断言会骗人：必须有逐点的期望值；
//   * 结论行必须能被 grep：TEST PASSED (64 checks) / TEST FAILED (3 errors)。
// 本骨架已用 skill/scripts/tb_wiring.py 自检通过（0 条发现），
// 且用 skill/scripts/check_vectors.py 的同一套理念做逐点比对。
// ===========================================================================
`timescale 1ns / 1ps

module tb_skeleton;

    // ---------------- 按题目修改的四个参数 ----------------
    localparam integer W         = 16;        // 数据位宽
    localparam integer N_MAX     = 4096;      // 最多点数（数组上限）
    localparam integer TIMEOUT_NS = 200000;   // 全局超时：到点必须结束
    localparam real    TOL       = 0.0;       // 允许误差，整数比对填 0

    // ---------------- 时钟与 DUT 端口 ----------------
    reg              clk;
    reg              rst_n;
    reg  [W-1:0]     din;
    reg              din_valid;
    wire [W-1:0]     dout;
    wire             dout_valid;

    localparam integer CLK_HALF = 10;         // 10 ns 半周期 → 50 MHz

    always #CLK_HALF clk = ~clk;

    // ---------------- 激励与期望 ----------------
    reg [W-1:0] stim [0:N_MAX-1];
    reg [W-1:0] expc [0:N_MAX-1];
    integer     n;            // 本用例点数
    integer     idx;          // 驱动指针
    integer     checks;       // 已比对点数
    integer     errors;
    integer     fd;
    integer     rc;
    integer     i;
    reg  [8*256-1:0] stim_path;

    // ---------------- DUT 实例化（改成你的模块） ----------------
    dut_passthrough #(.W(W)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (din),
        .din_valid  (din_valid),
        .dout       (dout),
        .dout_valid (dout_valid)
    );

    // ---------------- 逐点比对 ----------------
    // 采样时刻的 dout/dout_valid 是上一拍寄存下来的值，两者天然对齐；
    // 第 k 个 dout_valid 对应第 k 个进入的样本——只要 DUT 不丢点、不乱序。
    // 如果 DUT 会丢点（如滤波器抽头），改成按 valid 计数映射，别直接比。
    always @(posedge clk) begin
        if (rst_n && dout_valid) begin
            if (checks >= n) begin
                errors = errors + 1;
                $display("ERROR 多余输出：第 %0d 个输出（用例只有 %0d 点）", checks + 1, n);
            end else if (dout !== expc[checks]) begin
                errors = errors + 1;
                if (errors <= 20)   // 前 20 条全打，后面只计数，避免刷屏
                    $display("ERROR 点 %0d：期望 %0d (0x%0h) 实测 %0d (0x%0h) 差 %0d",
                             checks, expc[checks], expc[checks], dout, dout, dout - expc[checks]);
            end
            checks = checks + 1;
        end
    end

    // ---------------- 激励：文件优先，否则内部斜坡 ----------------
    // 激励来源优先级：运行目录下的 stim.txt → +STIM=路径 → 内部斜坡。
    // 放在"约定文件名"而不是只靠 plusarg，是因为各仿真器传 plusarg 的方式不一样
    // （本工程实测 Vivado 2026.1 的 xsim.bat 对 -testplusarg 直接打帮助并退出；
    //  而 iverilog 用 `vvp tb +STIM=stim.txt` 就行）。约定文件名两边都能用。
    task load_or_generate;
        begin
            n = 0;
            fd = $fopen("stim.txt", "r");
            if (fd == 0 && $value$plusargs("STIM=%s", stim_path))
                fd = $fopen(stim_path, "r");
            if (fd != 0) begin
                while (!$feof(fd) && n < N_MAX) begin
                    rc = $fscanf(fd, "%d %d\n", stim[n], expc[n]);
                    if (rc == 2) n = n + 1;
                end
                $fclose(fd);
                $display("INFO 读入 %0d 点激励", n);
            end
            if (n == 0) begin
                n = 64;
                for (i = 0; i < n; i = i + 1) begin
                    stim[i] = (i * 37 + 11) % (1 << W);   // 确定性斜坡
                    expc[i] = stim[i];                   // passthrough：恒等
                end
                $display("INFO 内部斜坡模式：%0d 点（无 stim.txt / +STIM=）", n);
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        din = {W{1'b0}};
        din_valid = 1'b0;
        checks = 0;
        errors = 0;
        idx = 0;

        load_or_generate();

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;

        // 每个时钟送一个点；只在无效拍拉低 valid，不要连成常量
        while (idx < n) begin
            @(negedge clk);
            din       = stim[idx];
            din_valid = 1'b1;
            idx       = idx + 1;
        end
        @(negedge clk);
        din_valid = 1'b0;

        // 等最后几个点出来（给 DUT 留余量），然后下判决
        repeat (8) @(posedge clk);

        if (checks != n) begin
            $display("ERROR 输出点数 %0d，期望 %0d（丢了 %0d 个 valid）", checks, n, n - checks);
            errors = errors + 1;
        end

        if (errors == 0) $display("TEST PASSED (%0d checks)", checks);
        else             $display("TEST FAILED (%0d errors, %0d checks)", errors, checks);

        $finish;
    end

    // ---------------- 超时保护：没有它，失败会表现为"卡住" ----------------
    initial begin
        #TIMEOUT_NS;
        $display("TEST FAILED (timeout at %0d ns, %0d/%0d checks done)", TIMEOUT_NS, checks, n);
        $finish;
    end

endmodule
