//=============================================================================
// 测试台 : tb_sc_correct
// 文件   : sim/tb_sc_correct.v
// 被测   : rtl/sc_correct.v （六参数校正 + 2bit 粗调增益）
//
// 【测试内容】
//   1) 逐点位精确对照：每个样本都把 DUT 输出与测试台内**独立写的**行为表达式
//      （64 位中间量的定点表达式，语义与契约一致）比较，必须完全相等。
//      这一项能抓出：流水线深度错、符号/位宽错、>>> 的 floor 语义错、mux 接错。
//   2) 圆度检查：1024 点扫一个完整周期，逐点算 |sqrt(s^2+c^2) - 30000|，
//      要求校正后最大值小于门限（见下）。
//   3) 正交误差检查：用去直流后的互相关估计
//          sin(dphi_est) = sum(s'*c') / sqrt(sum(s'^2)*sum(c'^2))
//      校正后应接近 0 度。
//   4) 功能边界：粗调 shift=0..3、正负饱和、sat_flag、
//      以及 >>> 必须是"向 -inf 取整"（floor）而不是向零截断。
//
// 【四个损伤工况】（理想圆半径 R = 30000，1024 点/周期）
//   (a) 无损伤        ：圆周整数化自带的 0.53 LSB 量化误差
//   (b) 两通道 +1000 LSB 直流偏置
//   (c) 余弦通道幅值小 1.2 倍（gain_c = 39322 = 1.2 的 Q1.15）
//   (d) 正交误差 5 度（剪切注入 c += s*sin(dphi)，phase_k = 2856 = sin5deg 的 Q1.15）
//
// 【门限为什么分两档】—— 这是定点实现的**量化下限**，不是算法缺陷：
//   残差 = floor 截断偏置（|floor(m*x)-m*x| < 1 LSB，均值恒约 -0.5 LSB，与 m 无关）
//        + 输入整数量化被有效增益 m = (g/2^15)<<shift 放大。
//   (a)(b)(d) 的 gain 都是 GAIN_ONE=32768 且 shift=0 ⇒ m = 1.0，映射 y=(x*32768)>>>15
//   就是恒等映射，除了理想圆自身的整数量化（0.525 LSB）没有任何附加误差；
//   (c) 的 gain_c=GAIN_12X、shift=0 ⇒ m = 1.2：输入 ±0.5 LSB 的整数化误差被放大到
//   ~±0.6 LSB，再叠加 floor 的 <1 LSB ⇒ 最坏约 1.5 LSB，所以 (c) 必须用 2.0 LSB 门限。
//   ★ 早期注释把这段写成"总增益 >1 时桶宽 <1、约 16% 整数目标不可达 ⇒ 残差"，
//     方向是反的：桶宽 >= 1 才是多对一（不可逆），而本设计从不做反演，
//     目标不可达不产生误差。2026-10-10 P1 定案与实测见 tools/calib_shift_judge.py。
//
// 【预期打印结果】（由 _tools/sc_correct_model.py 逐位模型预先算出，
//   若 xsim 打印的数字与此不符，说明 RTL 与模型存在偏差，必须查）
//   工况            校正前径向   校正前正交   校正后径向   校正后正交
//   (a) ideal          0.525       0.0000       0.525       0.0000
//   (b) offset       1414.501      0.0000       0.525       0.0000
//   (c) gain 1.2x    5000.323      0.0000       1.499       0.0000
//   (d) quad 5deg    1336.226      4.9812       0.525       0.0000
//   注：(d) 注入的正交误差按 sin(dphi)=sin(5deg) 定义（契约里 phase_k 的物理含义），
//       它对应的几何相位差是 atan(sin 5deg) = 4.989 度，所以估计器读数约 4.98 度，
//       与设计值 5 度一致（差 0.011 度 = 定点估计器的分辨率噪声）。
//
// 【运行方式】Vivado xsim：
//   xvlog rtl/sc_correct.v sim/tb_sc_correct.v ; xelab -debug typical tb_sc_correct -s tb ; xsim tb -R
//=============================================================================
`timescale 1ns / 1ps

module tb_sc_correct;

    //-------------------------------------------------------------------------
    // 参数
    //-------------------------------------------------------------------------
    localparam integer DW           = 16;          // DUT 位宽
    localparam integer NSTEP        = 1024;        // 每工况扫描点数（一个完整周期）
    localparam [DW-1:0] PHASE_K_5DEG = 16'd2856;   // round(sin(5deg)*2^15) = 2856
    localparam [DW-1:0] GAIN_12X     = 16'd39322;  // round(1.2*2^15)      = 39322
    localparam [DW-1:0] GAIN_ONE     = 16'd32768;  // 1.0 的 Q1.15
    localparam [DW-1:0] GAIN_MAX     = 16'hFFFF;   // 1.99997 的 Q1.15
    localparam [DW-1:0] OFS_1000     = 16'd1000;   // 偏置 1000 LSB

    localparam real    PI           = 3.141592653589793;
    localparam real    R_IDEAL      = 30000.0;     // 理想圆半径（LSB）
    localparam real    TOL_RAD_EXACT = 1.0;        // 可精确反演工况的径向门限（LSB）
    localparam real    TOL_RAD_GAIN  = 2.0;        // 增益>1 工况的径向门限（LSB）
    localparam real    TOL_QUAD      = 0.05;       // 校正后正交误差门限（度）

    //-------------------------------------------------------------------------
    // DUT 端口
    //-------------------------------------------------------------------------
    reg                 clk;
    reg                 rst_n;
    reg  signed [DW-1:0] s_in;
    reg  signed [DW-1:0] c_in;
    reg                 in_valid;
    reg  signed [DW-1:0] ofs_s;
    reg  signed [DW-1:0] ofs_c;
    reg         [DW-1:0] gain_s;
    reg         [DW-1:0] gain_c;
    reg         [1:0]    shift_s;
    reg         [1:0]    shift_c;
    reg  signed [DW-1:0] phase_k;
    wire signed [DW-1:0] s_out;
    wire signed [DW-1:0] c_out;
    wire                out_valid;
    wire                sat_flag;

    sc_correct #(
        .DW (DW)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .s_in      (s_in),
        .c_in      (c_in),
        .in_valid  (in_valid),
        .ofs_s     (ofs_s),
        .ofs_c     (ofs_c),
        .gain_s    (gain_s),
        .gain_c    (gain_c),
        .shift_s   (shift_s),
        .shift_c   (shift_c),
        .phase_k   (phase_k),
        .s_out     (s_out),
        .c_out     (c_out),
        .out_valid (out_valid),
        .sat_flag  (sat_flag)
    );

    //-------------------------------------------------------------------------
    // 时钟与全局计数
    //-------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;          // 100 MHz
    end

    integer errors;                     // 总错误数
    integer i;

    //-------------------------------------------------------------------------
    // 统计量
    //-------------------------------------------------------------------------
    real sum_sb, sum_cb, sum_ssb, sum_ccb, sum_scb;   // 校正前的一/二阶矩
    real sum_sa, sum_ca, sum_ssa, sum_cca, sum_sca;   // 校正后
    real rad_b, rad_a;                                // 最大径向误差
    real quad_b, quad_a;                              // 正交误差（度）

    //-------------------------------------------------------------------------
    // 函数 / 任务
    //-------------------------------------------------------------------------

    // 四舍五入（half away from zero），与 Python 模型 rnd_half_away 一致
    function integer rnd;
        input real x;
        begin
            if (x >= 0.0) rnd = $rtoi(x + 0.5);
            else          rnd = $rtoi(x - 0.5);
        end
    endfunction

    function real absr;
        input real x;
        begin
            if (x < 0.0) absr = -x;
            else         absr = x;
        end
    endfunction

    // 独立行为参考：s1 = s - ofs; c2 = c1 - ((s1*pk)>>>15); s2 = (s1*g)>>>(15-sh)
    //   中间量用 64 位，饱和到 16 位。与 RTL 是**不同的代码路径**。
    function signed [DW-1:0] ref_sat;
        input signed [63:0] v;
        begin
            if (v > 64'sd32767)       ref_sat = 16'sd32767;
            else if (v < -64'sd32768) ref_sat = -16'sd32768;
            else                      ref_sat = v[DW-1:0];
        end
    endfunction

    function signed [63:0] ref_s2;
        input signed [DW-1:0] si;
        input signed [DW-1:0] oi;
        input        [DW-1:0] g;
        input        [1:0]    sh;
        reg   signed [63:0]   t1;
        begin
            t1 = si - oi;                                    // 64bit
            ref_s2 = (t1 * $signed({1'b0, g})) >>> (15 - sh); // 算术右移 = floor
        end
    endfunction

    function signed [63:0] ref_c3;
        input signed [DW-1:0] si;
        input signed [DW-1:0] ci;
        input signed [DW-1:0] os;
        input signed [DW-1:0] oc;
        input signed [DW-1:0] pk;
        input        [DW-1:0] g;
        input        [1:0]    sh;
        reg   signed [63:0]   a1, a2;
        begin
            a1 = si - os;                     // 先在 64 位里算，避免 16 位相减溢出
            a2 = ci - oc;
            a2 = a2 - ((a1 * pk) >>> 15);     // 正交校正
            ref_c3 = (a2 * $signed({1'b0, g})) >>> (15 - sh);
        end
    endfunction

    // 去直流互相关正交误差估计（度）：sum(s'c') / sqrt(sum s'^2 * sum c'^2)
    function real quad_est;
        input real ss;
        input real sc;
        input real sss;
        input real scc;
        input real ssc0;
        input integer n;
        real num, den, v;
        begin
            num = ssc0 - (ss * sc) / $itor(n);
            den = $sqrt( (sss - (ss * ss) / $itor(n)) * (scc - (sc * sc) / $itor(n)) );
            if (den <= 0.0) begin
                quad_est = 0.0;
            end else begin
                v = num / den;
                if (v >  1.0) v =  1.0;
                if (v < -1.0) v = -1.0;
                quad_est = $asin(v) * 180.0 / PI;
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 单点：送激励 -> 等 3 拍 -> 在负沿检查（避开 NBA 竞争）
    //-------------------------------------------------------------------------
    task step_and_check;
        input integer         idx;
        input signed [DW-1:0] si;
        input signed [DW-1:0] ci;
        begin
            @(negedge clk);
            s_in     = si;
            c_in     = ci;
            in_valid = 1'b1;

            repeat (3) @(posedge clk);      // 3 级流水
            @(negedge clk);                 // 负沿采样，结果已稳定

            if (out_valid !== 1'b1) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  [FAIL] idx=%0d out_valid=%b (应为 1；Latency 必须 = 3)",
                             idx, out_valid);
            end
            if (s_out !== ref_sat(ref_s2(si, ofs_s, gain_s, shift_s))) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  [FAIL] idx=%0d s_out=%0d 期望=%0d (si=%0d ofs_s=%0d gain_s=%0d shift_s=%0d)",
                             idx, $signed(s_out), $signed(ref_sat(ref_s2(si, ofs_s, gain_s, shift_s))),
                             $signed(si), $signed(ofs_s), gain_s, shift_s);
            end
            if (c_out !== ref_sat(ref_c3(si, ci, ofs_s, ofs_c, phase_k, gain_c, shift_c))) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  [FAIL] idx=%0d c_out=%0d 期望=%0d (ci=%0d ofs_c=%0d phase_k=%0d gain_c=%0d)",
                             idx, $signed(c_out),
                             $signed(ref_sat(ref_c3(si, ci, ofs_s, ofs_c, phase_k, gain_c, shift_c))),
                             $signed(ci), $signed(ofs_c), $signed(phase_k), gain_c);
            end
            if (sat_flag !== 1'b0) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  [FAIL] idx=%0d 意外饱和 sat_flag=1", idx);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 指标累加（校正前用输入，校正后用输出）
    //-------------------------------------------------------------------------
    task accum;
        input real sb, cb, sa, ca;
        real rb, ra;
        begin
            sum_sb  = sum_sb  + sb;
            sum_cb  = sum_cb  + cb;
            sum_ssb = sum_ssb + sb * sb;
            sum_ccb = sum_ccb + cb * cb;
            sum_scb = sum_scb + sb * cb;

            sum_sa  = sum_sa  + sa;
            sum_ca  = sum_ca  + ca;
            sum_ssa = sum_ssa + sa * sa;
            sum_cca = sum_cca + ca * ca;
            sum_sca = sum_sca + sa * ca;

            rb = absr($sqrt(sb * sb + cb * cb) - R_IDEAL);
            ra = absr($sqrt(sa * sa + ca * ca) - R_IDEAL);
            if (rb > rad_b) rad_b = rb;
            if (ra > rad_a) rad_a = ra;
        end
    endtask

    //-------------------------------------------------------------------------
    // 全工况扫描
    //-------------------------------------------------------------------------
    integer lv_ideal_s, lv_ideal_c;
    integer lv_si, lv_ci;
    real    th, lv_sr, lv_cr;
    real    tol_used;

    task run_case;
        input integer cid;
        begin
            // ---- 1) 设定本工况系数（在复位期间就位，流水线里不会混系数）----
            in_valid = 1'b0;
            case (cid)
                0: begin      // (a) 无损伤
                    ofs_s = 16'sd0;   ofs_c = 16'sd0;
                    gain_s = GAIN_ONE; gain_c = GAIN_ONE;
                    shift_s = 2'd0;   shift_c = 2'd0;
                    phase_k = 16'sd0;
                    tol_used = TOL_RAD_EXACT;
                end
                1: begin      // (b) 两通道各 +1000 LSB 偏置
                    ofs_s = OFS_1000; ofs_c = OFS_1000;
                    gain_s = GAIN_ONE; gain_c = GAIN_ONE;
                    shift_s = 2'd0;    shift_c = 2'd0;
                    phase_k = 16'sd0;
                    tol_used = TOL_RAD_EXACT;
                end
                2: begin      // (c) 余弦通道幅值小 1.2 倍，用 gain_c = 1.2 校正
                    ofs_s = 16'sd0;   ofs_c = 16'sd0;
                    gain_s = GAIN_ONE; gain_c = GAIN_12X;
                    shift_s = 2'd0;   shift_c = 2'd0;
                    phase_k = 16'sd0;
                    tol_used = TOL_RAD_GAIN;
                end
                default: begin // (d) 正交误差 5 度
                    ofs_s = 16'sd0;   ofs_c = 16'sd0;
                    gain_s = GAIN_ONE; gain_c = GAIN_ONE;
                    shift_s = 2'd0;   shift_c = 2'd0;
                    phase_k = PHASE_K_5DEG;
                    tol_used = TOL_RAD_EXACT;
                end
            endcase

            // ---- 2) 复位 DUT，清空 3 级流水 ----
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;

            // ---- 3) 统计量清零 ----
            sum_sb = 0.0; sum_cb = 0.0; sum_ssb = 0.0; sum_ccb = 0.0; sum_scb = 0.0;
            sum_sa = 0.0; sum_ca = 0.0; sum_ssa = 0.0; sum_cca = 0.0; sum_sca = 0.0;
            rad_b  = 0.0; rad_a  = 0.0;

            // ---- 4) 扫一个完整周期 ----
            for (i = 0; i < NSTEP; i = i + 1) begin
                th    = 2.0 * PI * $itor(i) / $itor(NSTEP);
                lv_sr = R_IDEAL * $sin(th);
                lv_cr = R_IDEAL * $cos(th);
                lv_ideal_s = rnd(lv_sr);
                lv_ideal_c = rnd(lv_cr);

                case (cid)
                    0: begin
                        lv_si = lv_ideal_s;
                        lv_ci = lv_ideal_c;
                    end
                    1: begin
                        lv_si = lv_ideal_s + 1000;
                        lv_ci = lv_ideal_c + 1000;
                    end
                    2: begin
                        lv_si = lv_ideal_s;
                        lv_ci = rnd($itor(lv_ideal_c) / 1.2);
                    end
                    default: begin
                        // 剪切注入：c += (s*sin(dphi))>>>15（与 RTL 同语义的 floor）
                        // 乘数用 $signed() 包裹，保证乘积是 signed，>>> 才是算术移位
                        lv_si = lv_ideal_s;
                        lv_ci = lv_ideal_c + ((lv_ideal_s * $signed(PHASE_K_5DEG)) >>> 15);
                    end
                endcase

                step_and_check(i, lv_si[15:0], lv_ci[15:0]);
                accum($itor(lv_si), $itor(lv_ci), $itor($signed(s_out)), $itor($signed(c_out)));
            end

            // ---- 5) 结果 ----
            quad_b = quad_est(sum_sb, sum_cb, sum_ssb, sum_ccb, sum_scb, NSTEP);
            quad_a = quad_est(sum_sa, sum_ca, sum_ssa, sum_cca, sum_sca, NSTEP);

            case (cid)
                0: $display("  (a) 无损伤          : rad %9.3f -> %9.3f LSB | quad %8.4f -> %8.4f deg | tol %4.1f",
                            rad_b, rad_a, quad_b, quad_a, tol_used);
                1: $display("  (b) 偏置 +1000 LSB  : rad %9.3f -> %9.3f LSB | quad %8.4f -> %8.4f deg | tol %4.1f",
                            rad_b, rad_a, quad_b, quad_a, tol_used);
                2: $display("  (c) 增益失配 1.2x   : rad %9.3f -> %9.3f LSB | quad %8.4f -> %8.4f deg | tol %4.1f",
                            rad_b, rad_a, quad_b, quad_a, tol_used);
                default:
                   $display("  (d) 正交误差 5deg   : rad %9.3f -> %9.3f LSB | quad %8.4f -> %8.4f deg | tol %4.1f",
                            rad_b, rad_a, quad_b, quad_a, tol_used);
            endcase

            if (rad_a > tol_used) begin
                errors = errors + 1;
                $display("  [FAIL] 校正后径向误差 %.3f LSB > 门限 %.1f LSB", rad_a, tol_used);
            end
            if (quad_a > TOL_QUAD) begin
                errors = errors + 1;
                $display("  [FAIL] 校正后正交误差 %.4f deg > 门限 %.2f deg", quad_a, TOL_QUAD);
            end
            if (cid == 0) begin
                // 无损伤时校正不应该改变数据（纯单位增益通路）
                if (rad_b > 1.0) begin
                    errors = errors + 1;
                    $display("  [FAIL] 工况(a) 校正前径向误差 %.3f LSB 已 > 1（激励生成有问题）", rad_b);
                end
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 功能边界：粗调移位 / 饱和 / floor 语义
    //-------------------------------------------------------------------------
    task check_one;
        input signed [DW-1:0] si;
        input signed [DW-1:0] ci;
        input signed [DW-1:0] os;
        input signed [DW-1:0] oc;
        input signed [DW-1:0] pk;
        input        [DW-1:0] gs;
        input        [DW-1:0] gc;
        input        [1:0]    shs;
        input        [1:0]    shc;
        input signed [DW-1:0] es;
        input signed [DW-1:0] ec;
        input                esat;
        begin
            @(negedge clk);
            ofs_s = os; ofs_c = oc; phase_k = pk;
            gain_s = gs; gain_c = gc;
            shift_s = shs; shift_c = shc;
            s_in = si; c_in = ci; in_valid = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            if (s_out !== es || c_out !== ec || sat_flag !== esat) begin
                errors = errors + 1;
                $display("  [FAIL] 边界点: si=%0d ci=%0d gs=%0d gc=%0d shs=%0d shc=%0d => s=%0d c=%0d sat=%b  期望 s=%0d c=%0d sat=%b",
                         $signed(si), $signed(ci), gs, gc, shs, shc,
                         $signed(s_out), $signed(c_out), sat_flag,
                         $signed(es), $signed(ec), esat);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        errors   = 0;
        in_valid = 1'b0;
        rst_n    = 1'b0;
        s_in     = 16'sd0;  c_in   = 16'sd0;
        ofs_s    = 16'sd0;  ofs_c  = 16'sd0;
        gain_s   = GAIN_ONE; gain_c = GAIN_ONE;
        shift_s  = 2'd0;    shift_c = 2'd0;
        phase_k  = 16'sd0;

        $display("================================================================");
        $display(" tb_sc_correct : sc_correct 六参数校正自检测试");
        $display(" 理想圆半径 R = %0.0f LSB, 每工况扫描 %0d 点 (一个完整周期)", R_IDEAL, NSTEP);
        $display("================================================================");
        $display(" 【1】四个损伤工况的圆度/正交误差对比");
        $display(" ---------------------------------------------------------------");

        run_case(0);
        run_case(1);
        run_case(2);
        run_case(3);

        $display(" ---------------------------------------------------------------");
        $display(" 说明：>>> 对负数向下取整(floor)。m=1.0 的工况（a/b/d）映射是恒等映射，");
        $display("       残差只有理想圆自身整数量化 0.525 LSB；工况(c) m=1.2，把输入");
        $display("       +-0.5 LSB 的整数化误差放大到 ~0.6 LSB，再叠加 floor 的 <1 LSB，");
        $display("       最坏约 1.5 LSB（系数量化下限，非算法缺陷）。");
        $display("       （早期版本此处写'桶宽<1 导致 16%% 目标不可达'，论证方向是反的，");
        $display("         2026-10-10 P1 定案：见 tools/calib_shift_judge.py）");

        // ---- 功能边界 ----
        $display("");
        $display(" 【2】粗调移位 / 饱和 / floor 语义");
        $display(" ---------------------------------------------------------------");

        // (e1) shift=2 时总增益 x4，精确无误差
        check_one(16'sd8000, 16'sd6000, 16'sd0, 16'sd0, 16'sd0,
                  GAIN_ONE, GAIN_ONE, 2'd2, 2'd2,
                  16'sd32000, 16'sd24000, 1'b0);
        $display("  [ok  ] shift=2 (总增益 x4): 8000->32000, 6000->24000");

        // (e2) 正饱和：gain=65535(2.0), shift=3(总增益 x16) -> 10000*16 = 160000 -> 32767
        check_one(16'sd10000, 16'sd6000, 16'sd0, 16'sd0, 16'sd0,
                  GAIN_MAX, GAIN_MAX, 2'd3, 2'd3,
                  16'sd32767, 16'sd32767, 1'b1);
        $display("  [ok  ] 正向饱和: 10000 x16 -> 32767 (sat=1)");

        // (e3) 负饱和
        check_one(-16'sd10000, -16'sd6000, 16'sd0, 16'sd0, 16'sd0,
                  GAIN_MAX, GAIN_MAX, 2'd3, 2'd3,
                  -16'sd32768, -16'sd32768, 1'b1);
        $display("  [ok  ] 负向饱和: -10000 x16 -> -32768 (sat=1)");

        // (e4) 偏置把 s1 推出 16 位范围 -> 必须饱和（s1 = -20000-20000 = -40000）
        check_one(-16'sd20000, 16'sd100, 16'sd20000, 16'sd0, 16'sd0,
                  GAIN_ONE, GAIN_ONE, 2'd0, 2'd0,
                  -16'sd32768, 16'sd100, 1'b1);
        $display("  [ok  ] 去偏置后越界: (-20000-20000) -> -32768 (sat=1)");

        // (e5) floor 语义：(-5 * 20000) >>> 15 = floor(-3.0518) = -4（不是 -3）
        check_one(-16'sd5, 16'sd0, 16'sd0, 16'sd0, 16'sd0,
                  16'd20000, GAIN_ONE, 2'd0, 2'd0,
                  -16'sd4, 16'sd0, 1'b0);
        $display("  [ok  ] floor 语义: (-5x20000)>>>15 = -4 (向 -inf 取整)");

        // (e6) 相位支路同一条 floor 语义：c2 = 0 - ((-5*20000)>>>15) = +4
        check_one(-16'sd5, 16'sd0, 16'sd0, 16'sd0, 16'sd20000,
                  GAIN_ONE, GAIN_ONE, 2'd0, 2'd0,
                  -16'sd5, 16'sd4, 1'b0);
        $display("  [ok  ] 相位支路 floor: c2 = 0-(-4) = +4");

        $display(" ---------------------------------------------------------------");
        $display("");
        $display("================================================================");
        if (errors == 0) begin
            $display(" TEST PASSED (0 errors)");
        end else begin
            $display(" TEST FAILED (%0d errors)", errors);
        end
        $display("================================================================");
        $finish;
    end

endmodule
