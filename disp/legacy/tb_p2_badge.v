//=============================================================================
//  disp/tb_p2_badge.v  --  P2 四枚徽标的单元测试（直接例化 p2_badge）
//
//  为什么直接测模块而不走 disp_engine：徽标是**纯格式化的测量**，输入就是
//  一对样本流。走整机测试台要等 853,440 拍一帧，还要在满是 X 的层次里挖信号；
//  直接喂样本能精确控制相位与幅度，期望值可以手算。
//
//  激励的定标（与 disp/p2_badge.v 的 cl_px 是同一把尺子）：
//      ray = 99 - (sn >>> 8)，钳到 0..199
//    样本按 8 点表给（每点 45°），更新间隔 SUPD = 5000 拍 = 100 µs（10 kHz 遥测）。
//    每 8 个样本一个周期 ⇒ f = 10 kHz / 8 = 1250 Hz，周期 800 µs。
//    A 与 B 相差 90°（B = A 相移 -90°）⇒ A 上升过零到 B 上升过零 = 200 µs。
//
//  ★ 判据放在**写口上**，不在影子内存里：影子内存那一版查不出问题（写入对了、
//    读回却是 0，折腾了三轮），改成"每来一次写就比对一次、并记录哪些格被写过"，
//    既省掉 4096 项的数组，也能一眼看出"某格根本没写"。
//
//  四个用例（期望值全部手算，见下面注释）：
//    ① 空帧（没有任何样本）      -> 四枚全 0.0（"没有数据"就是 0.0，不是假值）
//    ② A 幅度 10000 / B 幅度 8000 -> VPP 39.6 / F 1250.0 / DT 200.0 / DV 8.0
//    ③ A 幅度 25600（打满量程）   -> VPP 100.0（四位）/ DV 60.3，测前导零抑制
//    ④ 样本恒 0（静止，无过零）   -> 四枚全 0.0，且不能除零
//=============================================================================
`timescale 1ns / 1ps

module tb_p2_badge;

    localparam integer SUPD  = 5000;      // 样本更新间隔（拍）= 100 µs @50 MHz
    localparam integer WCLK  = 600;       // 消隐期等待：4 个字段 x (40+17+12) ≈ 280 拍
    localparam [5:0]   ROW   = 6'd36;     // 数值格行
    // 四枚字段的**起始列**：节距 10 格（见 disp/p2_badge.v 的字段表）
    //   28..33 / 38..43 / 48..53 / 58..63，中间 34..37 / 44..47 / 54..57 是间隙
    localparam [5:0]   F0    = 6'd28;
    localparam [5:0]   F1    = 6'd38;
    localparam [5:0]   F2    = 6'd48;
    localparam [5:0]   F3    = 6'd58;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg signed [15:0] sn = 16'sd0;
    reg signed [15:0] cn = 16'sd0;

    always #10 clk = ~clk;                // 50 MHz

    wire        we;
    wire [11:0] waddr;
    wire [7:0]  wdata;
    wire        busy, done;

    p2_badge u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .sn(sn), .cn(cn),
        .sig_bad(1'b0),         // v50（㊼）：单元台默认非空态（空态判据见下一轮）
        .we(we), .waddr(waddr), .wdata(wdata),
        .busy(busy), .done(done)
    );

    integer errors = 0;

    // ---- 期望串 -> 字符码：' '->0、'.'->1、数字 d->8+d ----
    function [6:0] code_of;
        input [7:0] a;
        begin
            if (a == 8'd32)      code_of = 7'd0;
            else if (a == 8'd46) code_of = 7'd1;
            else                 code_of = {3'd0, a[3:0]} + 7'd8;
        end
    endfunction

    // ---- 期望文本：四枚徽标各 6 个字符（最高字节是最左字符）----
    reg [47:0] exp_txt [0:3];
    reg [23:0] seen;                       // 24 格是否都被写过

    // ---- 写口判据：每来一次写就比一次 ----
    //   地址 = {36, 列}，列 28..33 / 38..43 / 48..53 / 58..63 对应四枚徽标，
    //   枚内位置 p = 列 - 起始列；字符码 p=4 是小数点。
    //   写到间隙里（或行外）本身就判错 —— v18 第一版正是栽在列地址上
    //   （拼接位宽截断，见 disp/p2_badge.v 里 wc 的注释）。
    //   （xsim 不允许在 always 里声明局部变量，所以中间量都用模块级 reg。）
    reg [5:0]  wcol;
    reg [1:0]  wfld;
    reg [2:0]  wp;
    reg [7:0]  wexp;
    reg        hit;
    reg        chk_en = 1'b0;              // 只有测量帧的写才比对（空转帧不比对）

    always @(posedge clk) if (we && chk_en) begin
`ifdef WTRACE
        $display("[wr] t=%0t a=%0d d=%0d", $time, waddr, wdata);
`endif
        if (waddr[11:6] == ROW) begin
            wcol = waddr[5:0];
            hit  = 1'b1;
            //   ★ 上界写 `<= 起始列 + 5`，**不能写 `< 起始列 + 6`**：F3 + 6 = 64，
            //     在 6 位里回卷成 0，第四枚就永远匹配不上（`wcol < 0` 恒假）——
            //     与 disp/p2_badge.v 里 wc 那个截断是同一类错误，栽在同一份代码上两次。
            if      ((wcol >= F0) && (wcol <= F0 + 6'd5)) begin wfld = 2'd0; wp = wcol - F0; end
            else if ((wcol >= F1) && (wcol <= F1 + 6'd5)) begin wfld = 2'd1; wp = wcol - F1; end
            else if ((wcol >= F2) && (wcol <= F2 + 6'd5)) begin wfld = 2'd2; wp = wcol - F2; end
            else if ((wcol >= F3) && (wcol <= F3 + 6'd5)) begin wfld = 2'd3; wp = wcol - F3; end
            else begin
                hit = 1'b0;
                errors = errors + 1;
                $display("[FAIL] badge write outside the four fields: row %0d col %0d data %0d",
                         waddr[11:6], wcol, wdata);
            end

            if (hit) begin
                wexp = exp_txt[wfld][8*(5-wp) +: 8];
                seen[wfld*6 + wp[2:0]] <= 1'b1;
                if (wdata !== code_of(wexp)) begin
                    errors = errors + 1;
                    $display("[FAIL] badge %0d cell %0d col %0d got %0d want %0d",
                             wfld, wp, wcol, wdata, code_of(wexp));
                end
            end
        end
    end

    // ---- 8 点正弦表（10000 定标，每点 45°）----
    function signed [15:0] sint;
        input [2:0] i;
        begin
            case (i)
                3'd0:    sint = 16'sd0;
                3'd1:    sint = 16'sd7071;
                3'd2:    sint = 16'sd10000;
                3'd3:    sint = 16'sd7071;
                3'd4:    sint = 16'sd0;
                3'd5:    sint = -16'sd7071;
                3'd6:    sint = -16'sd10000;
                default: sint = -16'sd7071;
            endcase
        end
    endfunction

    // ---- 帧首脉冲 + 等消隐期把 24 格写完 ----
    task pulse_start;
    begin
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        repeat (WCLK) @(negedge clk);
    end
    endtask

    // ---- 跑一帧样本：n 个样本，A 幅度 aa、B 幅度 ab ----
    task run_samples;
        input signed [15:0] aa;
        input signed [15:0] ab;
        input integer       n;
        integer m;
        reg signed [31:0] pa, pb;
        begin
            for (m = 0; m < n; m = m + 1) begin
                // ★ 必须过 32 位中间量：写成 `sn <= (a*b)/10000` 时，乘法会按赋值
                //   目标的 **16 位上下文**计算，乘积高位被截掉 —— 首版就栽在这里：
                //   7071*10000 被截成 -12944，再除 10000 只剩 -1，于是"样本几乎不动"
                //   但过零照样发生（看起来像测量全错，其实是激励坏了）。
                pa = sint(m[2:0]) * aa;
                pb = sint((m[2:0] + 3'd6)) * ab;
                sn <= pa / 32'sd10000;
                cn <= pb / 32'sd10000;
                repeat (SUPD) @(negedge clk);
            end
        end
    endtask

    // ---- 设定本帧期望的四个字符串，并从这一帧开始比对 ----
    task expect_frame;
        input [47:0] e0, e1, e2, e3;
        begin
            exp_txt[0] = e0;
            exp_txt[1] = e1;
            exp_txt[2] = e2;
            exp_txt[3] = e3;
            seen       = 24'd0;
            chk_en     = 1'b1;
        end
    endtask

    // ---- 空转一帧：连续样本的**突变**（上一用例的幅度 → 本用例的幅度）
    //      必然落进 min/max，把这一帧冲掉再测，窗口里才是本用例自己。
    //      模块的窗口 = 两次 start 之间的区间，所以"先冲后测"是必须的。 ----
    task flush_case;
        input signed [15:0] aa;
        input signed [15:0] ab;
        begin
            chk_en = 1'b0;
            run_samples(aa, ab, 9);
            pulse_start;
        end
    endtask

    // ---- 打一份冻结快照（排错用：看模块到底冻住了什么）----
    task dump;
        input [8*24-1:0] tag;
        begin
            $display("[snap] %0s sn=%0d cn=%0d | a=%0d..%0d hv=%b b=%0d..%0d hv=%b | nc=%0d np=%0d sum=%0d t1=%0d t2=%0d",
                     tag, sn, cn,
                     u_dut.sv_amin, u_dut.sv_amax, u_dut.sv_ahv,
                     u_dut.sv_bmin, u_dut.sv_bmax, u_dut.sv_bhv,
                     u_dut.sv_nc, u_dut.sv_np, u_dut.sv_sum,
                     u_dut.sv_t1, u_dut.sv_t2);
        end
    endtask

    // ---- 24 格是否都写过（没写过就是"某枚根本没输出"）----
    task check_seen;
        input [8*24-1:0] tag;
        integer q;
        begin
            dump(tag);
            for (q = 0; q < 24; q = q + 1) begin
                if (!seen[q]) begin
                    errors = errors + 1;
                    $display("[FAIL] %0s 第 %0d 格（徽标 %0d，位 %0d）没有被写过",
                             tag, q, q/6, q%6);
                end
            end
        end
    endtask

    initial begin
        exp_txt[0] = 48'd0; exp_txt[1] = 48'd0;
        exp_txt[2] = 48'd0; exp_txt[3] = 48'd0;
        seen = 24'd0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ---- ① 空帧：复位后没有任何样本变化（sn=cn=0 ⇒ 射线 99）----
        //   min=max ⇒ Vpp=0；没有过零 ⇒ F/DT=0 ⇒ 四枚都是 "   0.0"
        expect_frame("   0.0", "   0.0", "   0.0", "   0.0");
        pulse_start;
        $display("[info] ① 空帧");
        check_seen("① 空帧");

        // ---- ② A=10000、B=8000、36 个样本（4.5 个周期）----
        //   A: 99-(10000>>>8)=60、99-(-10000>>>8)=99+40=139 ⇒ Vpp=79 px
        //      ⇒ 79*1000/199 = 396 ⇒ "  39.6"
        //   B: 99-31=68、99+32=131 ⇒ Vpp=63 px ⇒ DV=|79-63|=16 ⇒ 16000/199=80 ⇒ "   8.0"
        //   过零：每 8 个样本一次上升过零，n=5 ⇒ (5-1)*5e8/(160000) = 12500 ⇒ "1250.0"
        //   相位：B 的上升过零在 A 之后 2 个样本 = 2*5000 拍 ⇒ sum/(5*5)=2000 ⇒ " 200.0"
        flush_case(16'sd10000, 16'sd8000);
        expect_frame("  39.6", "1250.0", " 200.0", "   8.0");
        run_samples(16'sd10000, 16'sd8000, 36);
        pulse_start;
        $display("[info] ② A=10000 B=8000");
        check_seen("② A=10000 B=8000");

        // ---- ③ A 打满量程（25600 钳到 0..199）、B=10000 ----
        //   A: 99-100=-1⇒0、99-(-100)=199 ⇒ Vpp=199 ⇒ 199000/199=1000 ⇒ " 100.0"
        //   B: Vpp=79 ⇒ DV=120 ⇒ 120000/199=603 ⇒ "  60.3"
        flush_case(16'sd25600, 16'sd10000);
        expect_frame(" 100.0", "1250.0", " 200.0", "  60.3");
        run_samples(16'sd25600, 16'sd10000, 36);
        pulse_start;
        $display("[info] ③ A=25600（打满）B=10000");
        check_seen("③ A=25600");

        // ---- ④ 静止（样本恒为 0）：冲掉下降沿以后再测，窗口里没有任何变化 ⇒
        //      Vpp=0、没有过零 ⇒ 四枚都是 "   0.0"，且分母为 0 的那两枚不能除零 ----
        flush_case(16'sd0, 16'sd0);
        expect_frame("   0.0", "   0.0", "   0.0", "   0.0");
        run_samples(16'sd0, 16'sd0, 9);
        pulse_start;
        $display("[info] ④ 静止");
        check_seen("④ 静止");

        if (errors == 0) $display("TEST PASSED: 0 errors");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule
