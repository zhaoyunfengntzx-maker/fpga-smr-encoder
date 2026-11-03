//=============================================================================
// disp/tb_wave_trace.v —— P2「预触发环形缓冲 + 读侧反旋转」自检（v87 任务 A）
//-----------------------------------------------------------------------------
//   v86 的做法是"写指针从第 472 列起、写满 944 列后回绕"，读侧却按 0..943
//   线性读 ⇒ 屏上中线（列 472/473）处时间轴错位。v87 改成标准做法：
//     · 写侧自由跑的 1024 深环形缓冲（wcol 0..1023 自增回绕），不再等触发；
//     · 触发只"打点"：sin 由负穿正那一拍记为 t0；
//     · 抓满 472 个触发后样本时封帧，记下窗口起点 win_start；
//     · 读侧 raddr = {disp_buf, (win_start + col) & 0x3FF}。
//
//   本测试台逐笔监视写口（地址/数据/采样时刻），并在封帧后按**读侧公式**
//   把 944 列还原出来，逐列验证：
//     ① win_start 与触发样本地址之差恰好 472（触发样本在窗口第 472 列）；
//     ② 944 列的采样时刻严格等于 t0 + (col-472)*div —— 相邻列间隔恒为 div，
//        中线处**没有**跨触发的跳变（这正是 v86 断裂的量化判据）；
//     ③ 第 472 列读到的样本就是触发样本（sin 上升过零 ⇒ 行号 99）；
//     ④ 封帧后新写入只落在另一面，已封好的 944 列一个字节都不变；
//     ⑤ 写指针从不在 frame_st 复位（wcol 连续自增，0..1023 回绕）。
//
//   三档全测：gear 0/1/2 ⇒ div 128/16/2。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_wave_trace;

    //-------------------------------------------------------------------------
    // 50 MHz 时钟 + 全局拍计数（s_n 是 tcnt 的纯函数 ⇒ 时刻可精确预言）
    //   400 拍一个周期，x = -200..+199，s_n = x*128；tcnt%400 == 200 是上升
    //   过零点，也就是触发点。
    //-------------------------------------------------------------------------
    reg clk = 1'b0;
    always #10 clk = ~clk;

    integer tcnt = 0;
    always @(posedge clk) tcnt <= tcnt + 1;

    function signed [15:0] s_at;
        input integer tt;
        integer x;
        begin
            x = (tt % 400) - 200;
            s_at = x * 128;
        end
    endfunction

    function integer ya_at;           // RTL：ya = 99 - (s_n >>> 8)，s_n = x*128
        input integer tt;
        integer x;
        begin
            x = (tt % 400) - 200;
            ya_at = 99 - (x >>> 1);
        end
    endfunction

    function integer yb_at;           // c_n 比 s_n 超前 100 拍
        input integer tt;
        integer x;
        begin
            x = ((tt + 100) % 400) - 200;
            yb_at = 99 - (x >>> 1);
        end
    endfunction

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    reg        rst_n    = 1'b0;
    reg        frame_st = 1'b0;
    reg  [1:0] gear     = 2'd0;

    wire signed [15:0] s_n = s_at(tcnt);
    wire signed [15:0] c_n = s_at(tcnt + 100);

    wire        we;
    wire [10:0] waddr;
    wire [31:0] wdata;
    wire [10:0] wr_ptr;
    wire        wr_buf, disp_buf, cap_stb;
    wire [9:0]  win_start;

    wave_trace u_dut (
        .clk(clk), .rst_n(rst_n), .frame_st(frame_st), .de(1'b1),
        .s_n(s_n), .c_n(c_n), .gear(gear),
        .we(we), .waddr(waddr), .wdata(wdata),
        .wr_ptr(wr_ptr), .wr_buf(wr_buf), .disp_buf(disp_buf),
        .win_start(win_start), .cap_stb(cap_stb)
    );

    //-------------------------------------------------------------------------
    // RAM 影子模型：地址 -> {数据, 采样时刻}
    //-------------------------------------------------------------------------
    reg [31:0] mem   [0:2047];
    integer    mem_t [0:2047];
    reg        mem_v [0:2047];

    integer errors = 0;

    task fail;
        input [1023:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 12) $display("  [ERR] t=%0d : %0s", tcnt, msg);
        end
    endtask

    //-------------------------------------------------------------------------
    // 写口监视：记录影子 RAM + 触发地址 + 列间隔
    //-------------------------------------------------------------------------
    integer    dt_last  = -1;
    integer    div_c    = 128;
    integer    n_wr     = 0;
    integer    wr_gap   = 0;         // 写间隔 != div 的次数
    integer    col_gap  = 0;

    reg [10:0] addr_d1  = 11'd0;
    integer    ts_d1    = 0;
    reg        armed_q  = 1'b0;
    integer    trig_addr = -1;
    integer    trig_t    = -1;
    integer    ycur = 0;
    integer    yprev = 0;
    integer    exp_col  = 0;         // 期望的下一个 wcol（连续自增）

    always @(posedge clk) begin
        // armed 由 0 变 1 的那一拍，**本拍正在落的那一笔写**就是 t0：
        //   DUT 在决策沿 D 把 armed 置 1，同一沿发出的 we/waddr/wdata 在 D+1
        //   才真正落进 RAM ⇒ 看到 armed=1 的这一拍（D+1）的写正是 t0。
        if (u_dut.armed && !armed_q && we) begin
            trig_addr = waddr;
            trig_t    = tcnt - 1;
        end
        armed_q <= u_dut.armed;

        if (rst_n && we) begin
            mem[waddr]   <= wdata;
            mem_t[waddr] <= tcnt - 1;
            mem_v[waddr] <= 1'b1;

            // 写间隔：档位不变时必须恒为 div
            if (dt_last >= 0) begin
                if ((tcnt - 1 - dt_last) != div_c) wr_gap = wr_gap + 1;
            end
            dt_last = tcnt - 1;

            // 写指针必须连续自增回绕（0..1023），frame_st 不许复位它
            if ((waddr[9:0] !== exp_col[9:0])) col_gap = col_gap + 1;
            exp_col = (waddr[9:0] + 1) & 1023;

            n_wr = n_wr + 1;
            addr_d1 <= waddr;
            ts_d1   <= tcnt - 1;
        end
    end

    //-------------------------------------------------------------------------
    // 一次封帧：跑起来 -> 等 cap_stb -> 校验
    //-------------------------------------------------------------------------
    integer c, a;
    integer t472;
    integer wr0 = 0;
    integer base = 0, saved_win = 0, saved_bank = 0;
    integer win_snap [0:943];

    task run_capture;
        input [1:0]   g;
        input integer e_div;
        begin
            gear      = g;
            div_c     = e_div;
            dt_last   = -1;
            wr_gap    = 0;
            col_gap   = 0;
            trig_addr = -1;
            trig_t    = -1;

            // 先让新档位把至少一整个窗口（944 列）都按新 div 写满：
            //   换档瞬间窗口里会混着旧 div 的样本，那不是时间轴缺陷，
            //   而是"换档那一帧"的固有现象（板上 0.5 s 驻留后同理）。
            wr0 = n_wr;
            while (n_wr < wr0 + 1100) @(posedge clk);
            dt_last = -1;
            wr_gap  = 0;
            col_gap = 0;

            // 等新的封帧（cap_stb 是一拍脉冲，与 win_start/disp_buf 同拍更新）
            @(posedge cap_stb);
            @(posedge clk);
            #1;

            // ★ 冻结本次封帧的窗口参数：div=2 时 4000 拍内会再次封帧，
            //   若继续用实时的 win_start/disp_buf 会读到第三帧。
            saved_win  = win_start;
            saved_bank = disp_buf;
            base       = saved_bank ? 1024 : 0;

            if (trig_addr < 0) fail("armed never rose: no trigger captured");

            // ---- ① win_start 与触发样本地址恰好相差 472（预触发半屏）----
            //   win_start 是窗口**最老**样本的地址，触发样本在窗口第 472 列：
            //     win_start = trig_addr - 472 (mod 1024)
            if (((trig_addr - saved_win) & 1023) !== 472) begin
                $display("  [ERR] gear%0d: (trig_addr - win_start) = %0d (expect 472)",
                         g, (trig_addr - saved_win) & 1023);
                errors = errors + 1;
            end
            // ---- ③ 第 472 列读到的必须是触发样本本身 ----
            if (((saved_win + 472) & 1023) !== trig_addr[9:0]) begin
                $display("  [ERR] gear%0d: col 472 addr = %0d, trig addr = %0d",
                         g, (saved_win + 472) & 1023, trig_addr[9:0]);
                errors = errors + 1;
            end
            if (s_at(trig_t) < 0 || s_at(trig_t - e_div) >= 0) begin
                $display("  [ERR] gear%0d: trigger t=%0d is not a negative->positive crossing",
                         g, trig_t);
                errors = errors + 1;
            end

            // ---- ② 944 列的时刻必须严格等间隔、且中线处不跳变 ----
            t472 = mem_t[base + ((saved_win + 472) & 1023)];
            if (t472 !== trig_t) begin
                $display("  [ERR] gear%0d: col472 sample time %0d != trig time %0d",
                         g, t472, trig_t);
                errors = errors + 1;
            end
            for (c = 0; c < 944; c = c + 1) begin
                a = base + ((saved_win + c) & 1023);
                if (mem_v[a] !== 1'b1) begin
                    if (errors < 12) $display("  [ERR] gear%0d: col%0d never written", g, c);
                    errors = errors + 1;
                end else begin
                    if (mem_t[a] !== (t472 + (c - 472) * e_div)) begin
                        if (errors < 12)
                            $display("  [ERR] gear%0d col%0d: t=%0d expect %0d (dt=%0d)",
                                     g, c, mem_t[a], t472 + (c - 472) * e_div,
                                     mem_t[a] - t472);
                        errors = errors + 1;
                    end
                    // 数值：word = {a_hi,a_lo,b_hi,b_lo}，每个 = max/min(本列, 上一列)
                    ycur  = ya_at(mem_t[a]);
                    yprev = ya_at(mem_t[a] - e_div);
                    if (mem[a][23:16] !== (ycur < yprev ? ycur : yprev)) errors = errors + 1;
                    if (mem[a][31:24] !== (ycur < yprev ? yprev : ycur)) errors = errors + 1;
                    ycur  = yb_at(mem_t[a]);
                    yprev = yb_at(mem_t[a] - e_div);
                    if (mem[a][7:0]  !== (ycur < yprev ? ycur : yprev)) errors = errors + 1;
                    if (mem[a][15:8] !== (ycur < yprev ? yprev : ycur)) errors = errors + 1;
                end
            end
            // 中线两侧实测间隔（= div 的量化证据）
            $display("  gear%0d: div=%0d win_start=%0d trig_addr=%0d (trig-win)&1023=%0d",
                     g, e_div, saved_win, trig_addr[9:0],
                     (trig_addr - saved_win) & 1023);
            $display("          dt 470->471=%0d, 471->472=%0d, 472->473=%0d",
                     mem_t[base + ((saved_win + 471) & 1023)] - mem_t[base + ((saved_win + 470) & 1023)],
                     mem_t[base + ((saved_win + 472) & 1023)] - mem_t[base + ((saved_win + 471) & 1023)],
                     mem_t[base + ((saved_win + 473) & 1023)] - mem_t[base + ((saved_win + 472) & 1023)]);

            // ---- ④ 封帧后写另一面，已显示面的 944 列不许变 ----
            for (c = 0; c < 944; c = c + 1) begin
                win_snap[c] = mem[base + ((saved_win + c) & 1023)];
            end
            // 让新一面被写若干笔（div=2 时 600 拍 = 300 笔；div=128 时 4 笔），
            // 但**不能**多到再凑满一整个窗口（943 笔）——那样旧面会被重新写入，
            // "已显示面不变"就不再是这一条要证的东西了。
            repeat (600) @(posedge clk);
            for (c = 0; c < 944; c = c + 1) begin
                if (mem[base + ((saved_win + c) & 1023)] !== win_snap[c]) begin
                    if (errors < 12)
                        $display("  [ERR] gear%0d: displayed col %0d changed after flip", g, c);
                    errors = errors + 1;
                end
            end
            if (u_dut.wr_buf === disp_buf) fail("after flip wr_buf == disp_buf (same bank)");

            // ---- ⑤ 写间隔与写指针连续性 ----
            if (wr_gap != 0) begin
                $display("  [ERR] gear%0d: %0d write interval(s) != %0d clk",
                         g, wr_gap, e_div);
                errors = errors + 1;
            end
            if (col_gap != 0) begin
                $display("  [ERR] gear%0d: %0d write-pointer discontinuities", g, col_gap);
                errors = errors + 1;
            end
            $display("  gear%0d: %0d writes monitored, gaps=%0d/%0d",
                     g, n_wr, wr_gap, col_gap);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        $display("=== tb_wave_trace: pre-trigger ring + read-side de-rotation (v87) ===");
        for (c = 0; c < 2048; c = c + 1) begin
            mem[c] = 32'd0; mem_v[c] = 1'b0; mem_t[c] = -1;
        end
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // frame_st 现在是"不用的端口"，全程保持低：证明换面不靠它。
        frame_st <= 1'b0;

        run_capture(2'd0, 128);
        run_capture(2'd1, 16);
        run_capture(2'd2, 2);

        if (errors == 0)
            $display("TEST PASSED: 0 errors (three gears: trig-win=472, col dt == div)");
        else
            $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #500_000_000;                    // 500 ms
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule

`default_nettype wire
