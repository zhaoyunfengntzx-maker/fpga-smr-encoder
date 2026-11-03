//=============================================================================
// tb_calib_min.v -- rtl/calib_ctrl.v 最小自检测试台（自包含，无文件 IO）
//=============================================================================
// 为什么单独写这个"最小"测试台：
//   sim/tb_calib_ctrl.v 是数据驱动的向量测试台，但它对二维数组做了三维索引
//   （pulse_v[ci][i][0] 而 pulse_v 只声明了两维），而 xsim 对这种写法
//   **不报错、不警告、静默返回 0** ⇒ d_pulse 恒 0 ⇒ DUT 永远停在 S_ACCUM。
//   排查那个假象花了很多轮，因此另写这个最小台，把"测试台有问题"和
//   "RTL 有问题"彻底分开：激励全部由本文件内部算出，不依赖任何向量文件。
//
// 被测对象：rtl/calib_ctrl.v
//   标定窗口 = win_cycles 个输入周期；每个周期 P 个样本（本台 P = 8）。
//   本台用理想正交正余弦（无偏置、无增益失衡、无正交误差），因此期望：
//       ofs_s = 0, ofs_c = 0, phase_k = 0, gain_s == gain_c, shift_s == shift_c
//   这样任何非零结果都直接指向 RTL 的问题，不需要再怀疑激励。
//
// 激励相位对齐（关键，容易踩坑）：
//   窗口在 S_ACCUM 的第一个采样沿打开，而那时首个 cycle_pulse 已经为高
//   （由 enc_top 的 wrap_pos|wrap_neg 给出，与样本同拍）。因此本台让
//   第 i 拍送 sine_lut[i % 32]，累加到的正好是样本 0..31 这一完整周期，
//   于是 sum(s) = sum(c) = sum(s*c) = 0 精确成立。
//
// ★ 记录一次真实的激励退化（务必不要重犯）：
//   最初把"32 点表"写成了周期 8 的波形（第 16..31 项与前 16 项同号），
//   却用 c = table[(k+8)%32] 取余弦。这要求表是**周期 32** 的，实际不是，
//   于是 s 与 c 只差 45 度而不是 90 度 ⇒ mean(s*c) 不为 0 ⇒
//   sin_dp 被限幅到 16384（= 0.5 上限）、phase_k 饱和到 -32767。
//   表现为"RTL 算错了"，实际是激励错了。
//   **判据：理想输入下 sin_dp 必须接近 0，若它顶到 16384 就是激励相位错。**
//
// 判定：TEST PASSED / TEST FAILED（tools/run_sim.ps1 只认这两个字符串）
//=============================================================================

`timescale 1ns / 1ps

module tb_calib_min;

    // ---------------------------------------------------------------
    // 时钟 / 复位
    // ---------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    always #10 clk = ~clk;          // 50 MHz

    // 单一沿风格：本台全部用 negedge 驱动，posedge 采样。
    // （xsim 在同一 TB 内混用两种沿风格曾触发内核 FATAL_ERROR）
    task nedge; begin @(negedge clk); #1; end endtask

    // ---------------------------------------------------------------
    // DUT 端口
    // ---------------------------------------------------------------
    reg               d_start = 1'b0;
    reg  [15:0]       d_win   = 16'd4;      // win_cycles = 4 个输入周期
    reg  signed [15:0] d_s     = 16'sd0;
    reg  signed [15:0] d_c     = 16'sd0;
    reg               d_valid = 1'b0;
    reg               d_pulse = 1'b0;
    integer iv_edges = 0;

    wire              d_busy, d_done, d_trunc;
    wire [2:0]        d_retry;              // ★ 非整周期窗口的重标次数
    wire              d_bad;                // ★ 重试用尽仍非整周期
    wire signed [15:0] d_ofs_s, d_ofs_c, d_phk;
    wire [15:0]       d_gs, d_gc;
    wire [1:0]        d_shs, d_shc;
    wire              d_we;
    wire [15:0]       d_addr;
    wire [7:0]        d_wdata;
    wire [3:0]        d_state;

    calib_ctrl #(.MAX_SAMPLES(65536)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(d_start), .win_cycles(d_win),
        .busy(d_busy), .done(d_done), .truncated(d_trunc),
        .retry_cnt(d_retry), .win_bad(d_bad),
        .s_n(d_s), .c_n(d_c), .in_valid(d_valid), .cycle_pulse(d_pulse),
        .res_ofs_s(d_ofs_s), .res_ofs_c(d_ofs_c), .res_phase_k(d_phk),
        .res_gain_s(d_gs), .res_gain_c(d_gc),
        .res_shift_s(d_shs), .res_shift_c(d_shc),
        .calib_we(d_we), .calib_addr(d_addr), .calib_wdata(d_wdata),
        .state_dbg(d_state)
    );

    // ---------------------------------------------------------------
    // 判定工具
    // ---------------------------------------------------------------
    integer errors   = 0;
    integer checks   = 0;
    integer we_cnt   = 0;
    integer busy_cyc = 0;
    integer pulse_cnt = 0;
    integer i;
    integer nsamp_max = 0;
    reg [15:0] we_addr [0:15];
    reg  [7:0] we_data [0:15];
    reg [15:0] st_seen = 16'd0;         // 每访问过一个 state_dbg 就置位

    task chk;
        input cond;
        input [255:0] name;
        begin
            checks = checks + 1;
            if (cond) $display(" [ok]   %0s", name);
            else begin
                errors = errors + 1;
                $display(" [FAIL] %0s   (t=%0t)", name, $time);
            end
        end
    endtask

    // 写回捕获 / 状态覆盖（并行监视，与主流程解耦）
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (d_we === 1'b1 && we_cnt < 16) begin
                we_addr[we_cnt] = d_addr;
                we_data[we_cnt] = d_wdata;
                we_cnt = we_cnt + 1;
            end
            if (d_busy === 1'b1)  busy_cyc = busy_cyc + 1;
            if (d_pulse === 1'b1) pulse_cnt = pulse_cnt + 1;
            if (d_valid === 1'b1) iv_edges = iv_edges + 1;
            st_seen[d_state] = 1'b1;
            if (u_dut.nsamp > nsamp_max) nsamp_max = u_dut.nsamp;
        end
    end

    // ---------------------------------------------------------------
    // 理想正交激励表：sine_lut[k] = round(10000*sin(2*pi*k/32))
    //   s(i) = sine_lut[i % 32]
    //   c(i) = sine_lut[(i + 8) % 32]   （正好超前 90 度）
    // ---------------------------------------------------------------
    integer sine_lut [0:31];

    // 本台期望的黄金值（与 model/calib_ref.py 独立算出的一致）
    localparam integer EXP_NSAMP  = 32;
    localparam integer EXP_GAIN_S = 42949;
    localparam integer EXP_GAIN_C = 42949;

    initial begin
        // 32 点正弦表，幅度 ±10000。角度步进 11.25 度。
        //   ★ 必须严格是周期 32：第 0..7 项与第 16..23 项符号相反。
        sine_lut[ 0]=     0; sine_lut[ 1]=  3827; sine_lut[ 2]=  7071; sine_lut[ 3]=  9239;
        sine_lut[ 4]= 10000; sine_lut[ 5]=  9239; sine_lut[ 6]=  7071; sine_lut[ 7]=  3827;
        sine_lut[ 8]=     0; sine_lut[ 9]= -3827; sine_lut[10]= -7071; sine_lut[11]= -9239;
        sine_lut[12]=-10000; sine_lut[13]= -9239; sine_lut[14]= -7071; sine_lut[15]= -3827;
        sine_lut[16]=     0; sine_lut[17]= -3827; sine_lut[18]= -7071; sine_lut[19]= -9239;
        sine_lut[20]=-10000; sine_lut[21]= -9239; sine_lut[22]= -7071; sine_lut[23]= -3827;
        sine_lut[24]=     0; sine_lut[25]=  3827; sine_lut[26]=  7071; sine_lut[27]=  9239;
        sine_lut[28]= 10000; sine_lut[29]=  9239; sine_lut[30]=  7071; sine_lut[31]=  3827;

        $display("=================================================================");
        $display(" tb_calib_min -- rtl/calib_ctrl.v 最小自检");
        $display(" win_cycles=%0d  理想正交输入，期望 ofs=0 phase_k=0 gain_s==gain_c",
                 d_win);
        $display("=================================================================");

        // ---------- T1：复位 ----------
        repeat (4) nedge;
        chk(d_state === 4'd0, "T1a-复位后 state == S_IDLE");
        chk(d_busy  === 1'b0, "T1b-复位后 busy == 0");
        chk(d_done  === 1'b0, "T1c-复位后 done == 0");

        rst_n = 1'b1;
        repeat (2) nedge;

        // ---------- T2：启动 ----------
        d_start = 1'b1;
        nedge;
        d_start = 1'b0;
        nedge;
        chk(d_state !== 4'd0, "T2a-start 后离开 S_IDLE");
        chk(d_busy  === 1'b1, "T2b-start 后 busy == 1");

        // ---------- T3：喂样本 ----------
        // 40 拍激励：第 i 拍送 sine_lut[i % 32]。窗口在第 5 个周期边界
        // （i = 40，即 (wcnt+1) > win_n = 4）关闭，正好覆盖样本 0..31。
        //  ★ 激励必须超过窗口边界：i = 0..39 时 DUT 才看到 5 个 cycle_pulse。
        d_s = sine_lut[0]; d_c = sine_lut[8];
        d_valid = 1'b1; d_pulse = 1'b1;
        nedge;
        for (i = 1; i < 40; i = i + 1) begin
            d_s     = sine_lut[i % 32];
            d_c     = sine_lut[(i + 8) % 32];
            d_pulse = ((i % 8) == 0) ? 1'b1 : 1'b0;
            nedge;
        end
        //  ★ d_pulse 必须清零后再推进：残留高电平会被 DUT 当成又一次周期边界。
        d_valid = 1'b0; d_pulse = 1'b0;

        // ---------- T4：跑到 done ----------
        // 标定收尾（除法/开方/写回）约需几百拍，用固定拍数兜底，
        // 不用"循环里改 i"的写法（容易和循环上界打架）。
        repeat (4000) nedge;

        $display(" 观测：nsamp_max=%0d  pulse_cnt=%0d  we_cnt=%0d  busy_cyc=%0d",
                 nsamp_max, pulse_cnt, we_cnt, busy_cyc);

        chk(nsamp_max === EXP_NSAMP, "T3a-累加样本数 == win_cycles x 每周期样本数");
        chk(nsamp_max > 0,           "T3b-窗口非空（win_cycles=1 时曾算成 0）");
        chk(d_trunc === 1'b0,        "T3c-未触发 MAX_SAMPLES 截断");
        chk(pulse_cnt === 5,         "T3d-窗口内看到 5 个周期边界（4 个周期）");
        chk(d_retry === 3'd0,        "T3e-整周期窗口不触发重标（retry_cnt == 0）");

        chk(d_done === 1'b1, "T4a-标定完成 done == 1");
        chk(d_busy === 1'b0, "T4b-done 后 busy == 0");
        chk(d_bad  === 1'b0, "T4c-整周期窗口不置 win_bad");

        $display(" 结果：ofs_s=%0d ofs_c=%0d gain_s=%0d gain_c=%0d phase_k=%0d sh=%0d/%0d",
                 $signed(d_ofs_s), $signed(d_ofs_c), d_gs, d_gc,
                 $signed(d_phk), d_shs, d_shc);

        // ---------- T5：理想输入下的数值正确性 ----------
        chk(d_ofs_s === 16'sd0,  "T5a-理想输入 ofs_s == 0");
        chk(d_ofs_c === 16'sd0,  "T5b-理想输入 ofs_c == 0");
        chk(d_phk   === 16'sd0,  "T5c-理想正交 phase_k == 0（±32767 说明激励相位错）");
        chk(d_gs    === d_gc,    "T5d-对称输入 gain_s == gain_c");
        chk(d_shs   === d_shc,   "T5e-对称输入 shift_s == shift_c");
        chk(d_gs === EXP_GAIN_S[15:0], "T5f-gain_s 等于参考模型值 42949");
        chk(d_gc === EXP_GAIN_C[15:0], "T5g-gain_c 等于参考模型值 42949");

        // ---------- T6：写回 ----------
        chk(we_cnt === 11, "T6a-写回 11 个字节");
        chk(we_addr[ 0] === 16'h0510, "T6b-写回[0]  addr=0x0510 OFS_S 低字节");
        chk(we_addr[ 1] === 16'h0511, "T6c-写回[1]  addr=0x0511 OFS_S 高字节");
        chk(we_addr[ 2] === 16'h0512, "T6d-写回[2]  addr=0x0512 OFS_C 低字节");
        chk(we_addr[ 3] === 16'h0513, "T6e-写回[3]  addr=0x0513 OFS_C 高字节");
        chk(we_addr[ 4] === 16'h0514, "T6f-写回[4]  addr=0x0514 GAIN_S 低字节");
        chk(we_addr[ 5] === 16'h0515, "T6g-写回[5]  addr=0x0515 GAIN_S 高字节");
        chk(we_addr[ 6] === 16'h0516, "T6h-写回[6]  addr=0x0516 GAIN_C 低字节");
        chk(we_addr[ 7] === 16'h0517, "T6i-写回[7]  addr=0x0517 GAIN_C 高字节");
        chk(we_addr[ 8] === 16'h0518, "T6j-写回[8]  addr=0x0518 PHASE_K 低字节");
        chk(we_addr[ 9] === 16'h0519, "T6k-写回[9]  addr=0x0519 PHASE_K 高字节");
        chk(we_addr[10] === 16'h051A, "T6l-写回[10] addr=0x051A SHIFT");
        // 写回内容与端口最终值的关系：OFS 写的是 0，GAIN 写的是 gain_s_fin，
        // PHASE_K 写的是 ±phase_k_mag。此处只校验与端口最终值一致的部分。
        //  ★ 字节序：rtl/calib_ctrl.v:590-617 的写回是 **低字节在前**（小端）：
        //      sub0 -> ADDR_OFS_S   = o_s[7:0]
        //      sub1 -> ADDR_OFS_S+1 = o_s[15:8]
        //    （与"寄存器组按 16 位小端读取"一致；旧版本注释里写的
        //      "OFS_S_H/OFS_S_L" 是错的，已按实际实现改写。）
        chk(we_data[ 0] === d_ofs_s[7:0],   "T6m-写回 OFS_S 低字节 == res_ofs_s[7:0]");
        chk(we_data[ 1] === d_ofs_s[15:8],  "T6n-写回 OFS_S 高字节 == res_ofs_s[15:8]");
        chk(we_data[ 2] === d_ofs_c[7:0],   "T6o-写回 OFS_C 低字节 == res_ofs_c[7:0]");
        chk(we_data[ 3] === d_ofs_c[15:8],  "T6p-写回 OFS_C 高字节 == res_ofs_c[15:8]");
        chk(we_data[ 4] === d_gs[7:0],      "T6q-写回 GAIN_S 低字节 == res_gain_s[7:0]");
        chk(we_data[ 5] === d_gs[15:8],     "T6r-写回 GAIN_S 高字节 == res_gain_s[15:8]");
        chk(we_data[ 6] === d_gc[7:0],      "T6s-写回 GAIN_C 低字节 == res_gain_c[7:0]");
        chk(we_data[ 7] === d_gc[15:8],     "T6t-写回 GAIN_C 高字节 == res_gain_c[15:8]");
        chk(we_data[ 8] === d_phk[7:0],     "T6u-写回 PHASE_K 低字节 == res_phase_k[7:0]");
        chk(we_data[ 9] === d_phk[15:8],    "T6v-写回 PHASE_K 高字节 == res_phase_k[15:8]");
        chk(we_data[10][1:0] === d_shs && we_data[10][3:2] === d_shc,
            "T6w-写回 SHIFT：[1:0]=shift_s [3:2]=shift_c");

        // ---------- T8：★ 非整周期窗口必须被识别 + 自动重标 ----------
        //  复现 enc_top 里真实的失效模式（docs §1.28）：angle_raw 的 MSB 在过零点
        //  抖动 ⇒ 周期脉冲相对"θ=0 折返"错开半个周期 ⇒ 标定窗口变成奇数个半周期
        //  （实测 O_s 错 ±1800…2300）。本台用脉冲间隔人为制造同一几何：
        //      第 1 段间隔 = 8, 8, 4(半周期！), 12 …
        //  ⇒ 第一次窗口 min=4 / max=8 ⇒ 必须判 win_bad、丢弃本轮（retry_cnt+1）；
        //  第 2 段恢复每 8 个样本一个脉冲 ⇒ 整周期窗口，必须成功且结果正确。
        //  判据：retry_cnt == 1、win_bad == 0、truncated == 0、OFS 仍为 0。
        begin : retry_t
            integer k;
            d_start = 1'b0; nedge;
            d_start = 1'b1; nedge; d_start = 1'b0; nedge;

            d_valid = 1'b1;
            for (k = 0; k < 84; k = k + 1) begin
                d_s = sine_lut[k % 32];
                d_c = sine_lut[(k + 8) % 32];
                // 脉冲位置：0,8,16,20（半周期！）,32 | 40,48,56,64,72（恢复整周期）
                //   第 1 段：第 4 个脉冲在 k=32 关门，间隔 {8,7,3,11} ⇒ win_bad
                //   第 2 段：k=40 arming，k=72 关门，间隔 {8,7,7,7} ⇒ 正常
                d_pulse = ((k == 0) || (k == 8) || (k == 16) || (k == 20) ||
                           (k == 32) || (k == 40) || (k == 48) || (k == 56) ||
                           (k == 64) || (k == 72))
                          ? 1'b1 : 1'b0;
                nedge;
            end
            d_valid = 1'b0; d_pulse = 1'b0;
            repeat (6000) nedge;

            $display(" T8 观测：retry_cnt=%0d win_bad=%b truncated=%b nsamp=%0d wcnt=%0d",
                     d_retry, d_bad, d_trunc, u_dut.nsamp, u_dut.wcnt);
            chk(d_retry === 3'd1, "T8a-非整周期窗口被识别并重标一次");
            chk(d_bad   === 1'b0, "T8b-重标后窗口正常，未置 win_bad");
            chk(d_trunc === 1'b0, "T8c-重标后未被截断");
            chk(d_ofs_s === 16'sd0, "T8d-重标后 ofs_s == 0（用第二段整周期窗口解出）");
            chk(d_ofs_c === 16'sd0, "T8e-重标后 ofs_c == 0");
            chk(d_done  === 1'b1, "T8f-重标后标定完成 done == 1");
        end

        // ---------- T7：状态覆盖 ----------
        // S_IDLE=0 S_ACCUM=1 S_OFFSET=2 S_AMP=3 S_SQRT1=4 S_SQRT2=5
        // S_PHASE=6 S_GAIN=7 S_DIV=8 S_SHIFT=9 S_WRITE=10 S_DONE=11
        chk(st_seen[0]  === 1'b1, "T7a-遍历 S_IDLE");
        chk(st_seen[1]  === 1'b1, "T7b-遍历 S_ACCUM");
        chk(st_seen[2]  === 1'b1, "T7c-遍历 S_OFFSET");
        chk(st_seen[3]  === 1'b1, "T7d-遍历 S_AMP");
        chk(st_seen[4]  === 1'b1, "T7e-遍历 S_SQRT1");
        chk(st_seen[5]  === 1'b1, "T7f-遍历 S_SQRT2");
        chk(st_seen[6]  === 1'b1, "T7g-遍历 S_PHASE");
        chk(st_seen[7]  === 1'b1, "T7h-遍历 S_GAIN");
        chk(st_seen[8]  === 1'b1, "T7i-遍历 S_DIV");
        chk(st_seen[9]  === 1'b1, "T7j-遍历 S_SHIFT");
        chk(st_seen[10] === 1'b1, "T7k-遍历 S_WRITE");
        chk(st_seen[11] === 1'b1, "T7l-遍历 S_DONE");
        chk(d_state === 4'd0,     "T7m-收尾回到 S_IDLE");

        // ---------- 汇总 ----------
        $display("=================================================================");
        if (errors == 0) $display(" TEST PASSED  (%0d checks)", checks);
        else             $display(" TEST FAILED  (%0d error(s) / %0d checks)", errors, checks);
        $display("=================================================================");
        $finish;
    end

    // 全局超时保护（正常 < 200 us）
    initial begin
        #5_000_000;
        $display(" [FAIL] GLOBAL-TIMEOUT 仿真超过 5 ms 未结束");
        $display(" TEST FAILED  (timeout)");
        $finish;
    end

endmodule
