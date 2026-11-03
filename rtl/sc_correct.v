//=============================================================================
// 模块名 : sc_correct
// 文件   : rtl/sc_correct.v
// 功能   : sin/cos 六参数误差校正（核心创新点 1）—— 3 级全流水定点数据通路
//
//        s1  = s_in - ofs_s                         // 去直流偏置（第 1 级）
//        c1  = c_in - ofs_c
//        c2  = c1 - ((s1 * phase_k) >>> 15)          // 正交校正（第 2 级）
//        s2  = (s1 * gain_s) >>> (15 - shift_s)      // 增益均衡（第 3 级）
//        c3  = (c2 * gain_c) >>> (15 - shift_c)
//        s_out = sat16(s2);  c_out = sat16(c3)       // 16bit 有符号饱和
//
// 【六个可标定参数】
//   本模块实现的 5 个可标定参数：
//       1) ofs_s    正弦直流偏置      signed Q1.15
//       2) ofs_c    余弦直流偏置      signed Q1.15
//       3) gain_s   正弦细调增益      **无符号** Q1.15（1.0 = 16'd32768）
//       4) gain_c   余弦细调增益      **无符号** Q1.15
//       5) phase_k  正交误差系数      signed Q1.15 = sin(delta_phi)
//   第 6 个参数是**谐波扩展系数**（二次谐波 h2_k，用于补偿磁环/光栅的
//   二阶谐波畸变），它在**系统级**由 reg_file.v 的 0x051B/0x051C 提供
//   （cfg_h2_k），由 calib_ctrl.v 估计，本模块暂不参与运算。
//   预留该位置的理由：16bit 角度下本模块校正后的残差已落到量化底噪
//   （见下表工况 A…E），进一步提精度必须补偿二次谐波（工况 F 的 0.357 deg
//   残差就是 0.5% 二次谐波造成的）；届时只需在本模块第 2 级并行插入一条
//   h2 支路（s -= (h2_k*s2_est)>>>15, c -= (h2_k*c2_est)>>>15），
//   三级流水的深度和时序完全不变。系数寄存器地址（与 calib_ctrl.v 一致）：
//       ofs_s  0x0510/11(LE)   ofs_c  0x0512/13   gain_s 0x0514/15
//       gain_c 0x0516/17       phase_k 0x0518/19   shift  0x051A[3:0]
//       h2_k   0x051B/1C（预留，未接入本模块）
//
// 【相位校正的物理意义（为什么写成 c2 = c1 - s1*sin(dphi)）】
//   理想的 sin/cos 传感器两路信号相位差应严格是 90 度。实际磁环/光栅的
//   励磁与拾取几何不可能完全正交，加上两路模拟前端（PGA、滤波、ADC）
//   的群延时不一致，余弦通道实际是
//       c = A_c * cos(theta + dphi)
//   即两路之间存在固定的**非 90 度正交误差** dphi（也叫相位/正交误差）。
//   把它展开：
//       c = A_c*cos(dphi)*cos(theta) - A_c*sin(dphi)*sin(theta)
//   第二项是"正弦通道串到余弦通道"的**串扰项**（串扰系数 -A_c*sin(dphi)），
//   它使 sin/cos 轨迹从圆变成**斜椭圆**，直接造成 arctan 的角度误差
//   （在 45 度附近最大，dphi=5 度时可造成约 5 度电角度误差）。
//   把正弦通道乘上系数 phase_k = -(A_c/A_s)*sin(dphi) 再从余弦里减掉，
//   就正好抵消这个串扰项：
//       c2 = c1 - s1*phase_k
//          = A_c*cos(dphi)*cos(theta)        （串扰项被完全消掉）
//   剩下的 A_c*cos(dphi) 只是余弦通道的一个**纯增益缩放**，交给后面的
//   gain_c 一起补掉即可。所以 phase_k 的物理含义就是"sin(dphi)"，
//   本模块用一次 16x16 乘法 + 一次减法就把非 90 度误差彻底去掉。
//   （专用细分 ASIC 的 SC_PH_COR 0x4019 就是这个系数的定点版本，可校正 +-26 度。）
//
// 【系数怎么来的：闭式标定解（由 calib_ctrl.v 按此闭式解算出）】
//   信号模型（与真实 AMR/TMR/光学前端一致）：
//       s = A_s*sin(theta) + O_s
//       c = A_c*cos(theta + dphi) + O_c
//   在整数个输入周期上取一阶/二阶矩（抗噪、抗谐波、抗非整数周期）：
//       O_s = mean(s)                                   // 偏置 = 一阶矩
//       O_c = mean(c)
//       A_s = sqrt(2*mean((s-O_s)^2))                   // 注意是 2*mean，幅度不是 RMS
//       A_c = sqrt(2*mean((c-O_c)^2))
//       sd  = mean((s-O_s)*(c-O_c)) = -A_s*A_c*sin(dphi)/2
//   由此：
//       sin_dp = -2*sd/(A_s*A_c)                        // 正交误差的正弦
//       cos_dp = sqrt(1 - sin_dp^2)
//       phase_k(Q1.15) = 32768 * 2*sd/A_s^2             // = -32768*(A_c/A_s)*sin(dphi)
//       total_gain_s   = ref/A_s
//       total_gain_c   = ref/(A_c*cos_dp)               // ref = 0.80*32768 = 26214
//       shift = 满足 total_gain/2^shift <= 1.999 的**最小** sh (0..3)
//       gain(Q1.15)    = 32768 * total_gain / 2^shift
//   一次求解即精确，无需迭代搜索（传统方案用极值法 + 固定步长自适应，慢且怕噪声）。
//
// 【增益动态范围】
//   总增益 = (gain/2^15) * 2^shift
//       细调 gain  : 0.5x … 2.0x
//       粗调 2^shift: 1x … 8x
//       => 总范围 0.5x … 16x（-6 dB … +24 dB），覆盖弱信号（小磁环 / 大间隙）。
//   shift_s/shift_c 运行期静态（由标定状态机写入后保持不变），
//   所以移位用 4 选 1 的 case 实现（纯 LUT），不引入桶形移位器。
//
// 【定点量化下限（2026-10-10 P1 定案；实测见 tools/calib_shift_judge.py）】
//   >>>15 对负数向下取整，残差由两部分决定：
//     (1) floor 截断偏置：|floor(m*x) - m*x| < 1 LSB，均值恒约 -0.5 LSB，与 m 无关；
//     (2) 输入整数量化被有效增益 m = (g/2^15)*2^shift 放大：m 越大，前级 ±0.5 LSB
//         量化噪声放大得越多（物理性质，不是算法缺陷）。
//   ★ 本文件早期注释曾写"桶宽 = 2^(15-shift)/g，总增益 > 1.0 时桶宽 < 1 ⇒ 约 1 LSB
//     不可消除的径向残差，必须把总增益压到 <= 1.0"——该论证方向是反的：桶宽 >= 1
//     表示多个 x 映射到同一个 y（多对一、不可逆）；总增益 > 1 时映射是"单射但不满射"
//     （部分整数目标取不到），而校正后的矢量是**直接送 CORDIC 使用、从不做反演**，
//     所以目标不可达不产生误差。实测同一总增益换 (g, shift) 输出逐点恒等，
//     两条判据在 8 个工况下最终角度误差完全相同（judge [A][B]）。
//   本设计取 <= 1.999 而非 1.0 的理由：总增益 <= 2 时 shift=0 ⇒ gain 与 tg 逐位相同、
//   无截断；<= 1.0 会在同区间多移一位，通道间比例误差最大 2/32768。
//
// 【实测结果（model/golden_model.py 全链路定点仿真，16bit 角度，单周期内电角度误差）】
//   工况                                    校正前max      校正后max
//   A 理想信号(仅12bit量化)                 0.0165 deg  -> 0.0165 deg
//   B 直流偏置                              13.9856     -> 0.0165
//   C 幅值失衡 1.25x                        6.3885      -> 0.0165
//   D 正交误差 5deg                         5.0043      -> 0.0220
//   E 三类误差叠加                          20.9839     -> 0.0165   （改善 1273 倍）
//   F E+二次谐波0.5%+ADC噪声1LSB            21.0773     -> 0.3571   （残差由未补偿的二次谐波主导）
//   G 20%满量程小信号                       18.6603     -> 0.3131
//   注：A…E 校正后的残余误差都已落在 **16bit 角度输出的量化底噪**上
//       （复合畸变 E 为 0.0165 deg = 3 LSB；可标定工况里最差的 D 为 0.0220 deg = 4 LSB；
//        1 LSB = 0.0054932 deg），即此时限制精度的是
//       数据通路字长/ADC 前端，而不是标定算法本身。
//
// Latency : 3   （第 1 拍去偏置 / 第 2 拍正交校正 / 第 3 拍增益+饱和）
// 资源估计: 2 个 DSP48E1（17x17 与 18x17 各 1）+ 约 260 LUT + 约 180 FF
//           （移位是 4 选 1 mux；两个饱和比较各约 2 级 LUT）
// 关键假设:
//   1. 所有中间信号显式声明为 signed；>>> 只有对 signed 才是算术移位。
//      未声明的中间量会被当成 unsigned，负数的右移会变成逻辑移位 -> 结果错误。
//   2. 每一处乘法操作数都用 $signed() 包裹。gain_s/gain_c 端口是**无符号**
//      Q1.15（1.0 = 32768），所以必须写成 $signed({1'b0, gain_s})：
//      先零扩展 1 位再解释成有符号，这样 1.2x(=39322)、2.0x(=65535) 等
//      "大于 1.0"的增益才不会被当成负数（若直接 $signed(gain_s)，
//      32768 会变成 -32768，增益符号就反了）。
//   3. 中间位宽：s1/c1 为 17 位（-32768-32767 = -65535 必须 17 位才装得下）；
//      s1*phase_k 为 33 位；c2 为 18 位（|c2| <= 131070 恰好落在 18 位
//      有符号范围内，余量 1 LSB）；增益乘法 34/35 位；粗调移位后 24 位。
//      位宽下限都由上面的极值推导给出，不允许依赖隐式位宽推断。
//   4. 系数（ofs/gain/shift/phase_k）必须在 in_valid 有效期间保持稳定，
//      中途改变会在 3 拍流水里混用新旧系数（标定时应停 valid 或接受过渡）。
//   5. 无任何跨时钟域信号：系数来自 clk 域的 reg_file，标定期间静态。
//   6. sat_flag 与 s_out/c_out/out_valid **同拍**有效（每样本一个标志，
//      不是 sticky）；顶层若要 专用细分 ASIC 的 STAT_VAL.oflow 语义，请自行锁存。
//=============================================================================
`timescale 1ns / 1ps

module sc_correct #(
    parameter integer DW = 16            // 输入/输出位宽，Q1.15
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire signed [DW-1:0] s_in,      // 原始正弦（Q1.15）
    input  wire signed [DW-1:0] c_in,      // 原始余弦（Q1.15）
    input  wire                 in_valid,
    // ---- 校正系数（由标定状态机/上位机写入，Q1.15 或定点整数）----
    input  wire signed [DW-1:0] ofs_s,     // 正弦直流偏置（Q1.15）
    input  wire signed [DW-1:0] ofs_c,     // 余弦直流偏置（Q1.15）
    input  wire        [DW-1:0] gain_s,    // 正弦增益（无符号 Q1.15，1.0 = 16'd32768）
    input  wire        [DW-1:0] gain_c,    // 余弦增益（无符号 Q1.15）
    input  wire        [1:0]    shift_s,   // 粗调移位 0..3，总增益 = (gain_s/2^15) << shift_s
    input  wire        [1:0]    shift_c,   // 粗调移位 0..3
    input  wire signed [DW-1:0] phase_k,   // 正交误差系数 sin(delta_phi)（Q1.15）
    output reg  signed [DW-1:0] s_out,
    output reg  signed [DW-1:0] c_out,
    output reg                  out_valid,
    output reg                  sat_flag   // 任一通道饱和（与输出同拍）
);

    //=========================================================================
    // 派生常量
    //=========================================================================
    localparam integer SH   = 15;            // Q1.15 小数位
    localparam integer DWP  = DW + 1;        // 17：去偏置后位宽
    localparam integer DWM  = DWP + DW;      // 33：s1*phase_k 结果（17x16）
    localparam integer DWC  = DW + 2;        // 18：c2 位宽
    localparam integer DWS  = DWP + DWP;     // 34：s1*gain_s 结果（17x17）
    localparam integer DWM2 = DWC + DWP;     // 35：c2*gain_c 结果（18x17）
    localparam integer DWSH = DW + 8;        // 24：粗调移位后的中间位宽（含 2bit 粗调余量）

    localparam signed [DW-1:0] SAT_MAX = {1'b0, {(DW-1){1'b1}}};   //  32767
    localparam signed [DW-1:0] SAT_MIN = {1'b1, {(DW-1){1'b0}}};   // -32768

    //=========================================================================
    // 第 1 级：去偏置（显式符号扩展 1 位后再相减，17 位不会溢出）
    //=========================================================================
    wire signed [DWP-1:0] s_in_e  = {s_in[DW-1],  s_in};    // 符号扩展 -> 17bit
    wire signed [DWP-1:0] c_in_e  = {c_in[DW-1],  c_in};
    wire signed [DWP-1:0] ofs_s_e = {ofs_s[DW-1], ofs_s};
    wire signed [DWP-1:0] ofs_c_e = {ofs_c[DW-1], ofs_c};

    reg signed [DWP-1:0] s1_r;      // s1 = s_in - ofs_s
    reg signed [DWP-1:0] c1_r;      // c1 = c_in - ofs_c
    reg                  v1_r;

    //=========================================================================
    // 第 2 级：正交校正
    //   prod = s1 * phase_k                （33 位，17x16 全精度）
    //   ph_sh = prod >>> 15                （|ph_sh| <= 65535，17bit 足够，18bit 有余量）
    //   c2 = c1 - ph_sh                    （|c2| <= 131070，正好 18bit 有符号装得下）
    //=========================================================================
    wire signed [DWM-1:0] ph_prod = $signed(s1_r) * $signed(phase_k);
    wire signed [DWC-1:0] ph_sh   = $signed(ph_prod) >>> SH;

    reg signed [DWP-1:0] s1_d;      // s1 再延迟 1 拍，供第 3 级使用
    reg signed [DWC-1:0] c2_r;      // c2
    reg                  v2_r;

    //=========================================================================
    // 第 3 级：增益均衡（细调乘法 + 粗调 4 选 1 移位）+ 饱和
    //   gain 端口是无符号 Q1.15，先 {1'b0,gain} 零扩展再 $signed() 才能正确
    //   表示 >1.0 的增益。
    //=========================================================================
    wire signed [DWP-1:0] gs_ext = $signed({1'b0, gain_s});   // 17bit 有符号，0..65535
    wire signed [DWP-1:0] gc_ext = $signed({1'b0, gain_c});

    wire signed [DWS-1:0]  gs_prod = $signed(s1_d) * $signed(gs_ext);   // 34 位
    wire signed [DWM2-1:0] gc_prod = $signed(c2_r) * $signed(gc_ext);   // 35 位

    // 粗调移位：4 选 1（静态配置），综合成 LUT mux，不产生桶形移位器
    reg signed [DWSH-1:0] s2_sh;    // s1*gain_s 粗调移位后
    reg signed [DWSH-1:0] c3_sh;    // c2*gain_c 粗调移位后

    always @(*) begin
        case (shift_s)
            2'd0:    s2_sh = gs_prod >>> 15;
            2'd1:    s2_sh = gs_prod >>> 14;
            2'd2:    s2_sh = gs_prod >>> 13;
            default: s2_sh = gs_prod >>> 12;
        endcase
    end

    always @(*) begin
        case (shift_c)
            2'd0:    c3_sh = gc_prod >>> 15;
            2'd1:    c3_sh = gc_prod >>> 14;
            2'd2:    c3_sh = gc_prod >>> 13;
            default: c3_sh = gc_prod >>> 12;
        endcase
    end

    // 饱和判据（24 位有符号 与 16 位有符号门限 比较 -> 门限自动符号扩展到 24 位）
    wire s_sat_hi = (s2_sh > $signed(SAT_MAX));
    wire s_sat_lo = (s2_sh < $signed(SAT_MIN));
    wire c_sat_hi = (c3_sh > $signed(SAT_MAX));
    wire c_sat_lo = (c3_sh < $signed(SAT_MIN));

    wire sat_now = s_sat_hi | s_sat_lo | c_sat_hi | c_sat_lo;

    //=========================================================================
    // 三级流水寄存器
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            // ---- 第 1 级 ----
            s1_r <= {DWP{1'b0}};
            c1_r <= {DWP{1'b0}};
            v1_r <= 1'b0;
            // ---- 第 2 级 ----
            s1_d <= {DWP{1'b0}};
            c2_r <= {DWC{1'b0}};
            v2_r <= 1'b0;
            // ---- 第 3 级 ----
            s_out    <= {DW{1'b0}};
            c_out    <= {DW{1'b0}};
            out_valid <= 1'b0;
            sat_flag  <= 1'b0;
        end else begin
            // ---- 第 1 级：去偏置 ----
            s1_r <= s_in_e - ofs_s_e;
            c1_r <= c_in_e - ofs_c_e;
            v1_r <= in_valid;

            // ---- 第 2 级：正交校正 ----
            s1_d <= s1_r;
            c2_r <= c1_r - ph_sh;
            v2_r <= v1_r;

            // ---- 第 3 级：增益 + 饱和 ----
            if (s_sat_hi) begin
                s_out <= SAT_MAX;
            end else if (s_sat_lo) begin
                s_out <= SAT_MIN;
            end else begin
                s_out <= $signed(s2_sh[DW-1:0]);
            end

            if (c_sat_hi) begin
                c_out <= SAT_MAX;
            end else if (c_sat_lo) begin
                c_out <= SAT_MIN;
            end else begin
                c_out <= $signed(c3_sh[DW-1:0]);
            end

            out_valid <= v2_r;
            sat_flag  <= sat_now;
        end
    end

endmodule
