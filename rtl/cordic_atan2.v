//=============================================================================
// cordic_atan2.v —— 全流水向量模式 CORDIC（SPEC_interface_contract.md §1.5）
//-----------------------------------------------------------------------------
// 功能
//   输入已归一化的正交信号 c_n/x_in（cos）、s_n/y_in（sin），输出一个 sin/cos
//   周期内的电角度 angle（0..2^AW-1 对应 0..360deg）与幅值 mag（已做 CORDIC
//   1/1.6468 增益补偿）。
//
// Latency（in_valid -> out_valid，单位 clk）
//   = 1（象限折叠寄存） + NITER（每级 1 拍） + 1（输出寄存） = NITER + 2
//     NITER = 17（本模块默认） -> 19 拍；系统时钟 50 MHz（单时钟域，无 MMCM）
//                              -> 19 * 20 ns = 380 ns
//     NITER = 16（SPEC §1.5 默认值）-> 18 拍 = 360 ns @50 MHz
//   ★ 为什么默认取 17 而不是 SPEC 的 16：见下面"精度与设计取舍"。
//
// 精度与设计取舍（实测数据来自 model/cordic_model.py，1/16 LSB 细网格全圆
// 1048576 点扫描；1 LSB = 360/2^16 = 0.0054932deg）
//   NITER=16 + SPEC §1.5 表里印出的数字        : max 1.3125 LSB  <- 不达标
//   NITER=16 + SPEC §1.5 定义式取整的 ATAN 表  : max 1.1875 LSB  <- 不达标
//   NITER=17 + SPEC §1.5 表里印出的数字        : max 1.1875 LSB  <- 不达标
//   NITER=17 + SPEC §1.5 定义式取整的 ATAN 表  : max 0.9375 LSB  <- **本模块默认**
//   16 级时的误差下限 = 输出四舍五入量化 0.5 + CORDIC 残余旋转 atan(2^-15)=0.318
//   + 输入矢量 16bit 量化 0.16 = 0.978 LSB，再叠加 20bit ATAN 常量的取整误差
//   （非均匀、±0.15 LSB）就必然越过 1 LSB；17 级把残余旋转减半到
//   atan(2^-16)=0.159 LSB，才把峰值压到 1 LSB 以下。
//   若系统必须严格用 SPEC 的 18 拍延迟，实例化时写 NITER(16)，
//   代价是最坏误差回升到 1.19 LSB。
//
// ATAN 常量表（20bit 标度，ZW = AW+4 = 20）
//   SPEC §1.5 同时给了"表"和"定义式" ATAN[i]=round(atan(2^-i)*2^ZW/(2*PI))，
//   但两者在 i=2/4/8 三项上不一致（表印 40881/10416/651，定义式给
//   40884/10417/652），三项合计带来 -0.383 LSB 的系统偏置。本模块用
//   parameter ATAN_SRC 选择：ATAN_SRC=1 用定义式值（默认，与
//   model/golden_model.py 的 round() 取值一致），ATAN_SRC=0 用表里印出的数字。
//   表本身用 function + generate 建成常量数组，Vivado 在综合时全部常量折叠。
//   i>=16 的项 SPEC 表没有，按定义式外推（i=16 -> 3）。
//
// 关键实现点
//   1. 象限折叠（修正版，保证折叠后 x0 >= 0）：
//        x>=0           : x0 =  x, y0 =  y, base =   0
//        x<0, y>=0 (Q2) : x0 =  y, y0 = -x, base = +90deg
//        x<0, y< 0 (Q3) : x0 = -y, y0 =  x, base = -90deg
//      ★ SPEC §1.5 原文写的是 Q2: x0=-y,y0=+x / Q3: x0=+y,y0=-x，等于把 Q2/Q3
//        的折叠矢量整体取反（差 180°），于是 x0<0。向量模式的符号判据
//        d=~y[MSB] 只在 x>0 时才是"把 y 拉向 0"的正确方向；x0<0 时矢量被推向
//        反方向并最终收敛到 +x 轴而不是 -x 轴，输出**整体偏 180deg**（实测
//        100/135/170deg 分别偏 -110/-145/-180deg）。所以本项目与
//        model/golden_model.py::cordic_atan2 一致地把 Q2/Q3 的 x0/y0 各自取反，
//        base 仍按 SPEC 取 ±90°，这样折叠角恒在 ±90° 内（CORDIC 收敛域
//        ±99.88°），0..360° 全程无死区。
//   2. 每级 1 个 clk，全部迭代寄存器化（generate 展开），无组合环路。
//   3. **向零截断**移位：`>>>` 对负数是 floor（-3>>>1 = -2），而向零截断应为
//      -1，会在每次迭代引入固定方向的偏置。所以 x/y 的每一个 >>>i 都显式写成
//      "取绝对值 -> 逻辑右移 -> 恢复符号"（见 sh_tz），这是 SPEC §1.5 明确要求
//      的语义。
//   4. 内部 x/y 附加 FEXT=4 位小数（IXW = IW+3+FEXT = 23bit）：只影响内部
//      位宽、不改接口。向零截断每级丢掉 <1 个内部 LSB，这 1 个 LSB 折算到
//      角度上是 1/(x>>i) 量级；附加 FEXT 位小数把该误差缩小 2^FEXT 倍，同时
//      提高尾部 y 残余的分辨率（实测 FEXT=0 时密集扫描峰值 1.50 LSB，
//      FEXT=4 时 0.94 LSB）。FEXT>=3 后收益饱和。
//   5. 输出 ZW->AW：angle = (z + 2^(ZW-AW-1)) >>> (ZW-AW) 取低 AW 位，即
//      **四舍五入**（SPEC 原文是直接 >>4 截断，会留下固定 -0.5 LSB 偏置）。
//   6. mag = sat(|x|>>FEXT) 的单 DSP48 乘法补偿：MAG_COEF = 79604 = Q0.17 的
//      1/1.6467602。残差（实测）：mag 相对矢量真实模长误差 +0.0076%..+0.0111%
//      （满幅约 +2.5 LSB 来自系数量化，其余来自 CORDIC 实际增益与理论值的差）。
//
// 资源估计（XC7A35TFGG484-2，NITER=17）
//   FF   : 17 * (23 + 23 + 20 + 1) + (16 + 18 + 1) ~= 1174
//   LUT  : 每级 2 个 23bit 加减(约 23 LUT6) + 4 组条件移位(约 30 LUT6)
//          ~= 80 LUT/级 -> 约 1400 LUT
//   DSP48: 1（mag 增益补偿）
//   即 约 7% LUT / 3% FF / 1% DSP，50 MHz 下时序余量充足
//
// 复位：同步、低有效。无 initial / #delay / inout / SystemVerilog 语法。
//=============================================================================
module cordic_atan2 #(
    parameter integer AW    = 16,   // 输出角度位宽（每周期 = 2^AW）
    parameter integer IW    = 16,   // 输入位宽（signed，s_n/c_n 的宽度）
    parameter integer NITER = 17,   // 迭代级数（SPEC 默认 16，见文件头取舍）
    parameter integer FEXT  = 4,    // x/y 附加内部小数位（只加内部位宽）
    parameter integer ATAN_SRC = 1  // 1=SPEC §1.5 定义式取整值；0=SPEC 表印出的数字
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [IW-1:0] x_in,     // cos 分量（c_n）
    input  wire signed [IW-1:0] y_in,     // sin 分量（s_n）
    input  wire                in_valid,
    output reg         [AW-1:0] angle,    // 0…2^AW-1 对应 0…360°
    output reg         [IW+1:0] mag,      // 幅值（CORDIC 增益已补偿，无符号）
    output reg                 out_valid
);

    //-------------------------------------------------------------------------
    // 常量
    //-------------------------------------------------------------------------
    localparam integer ZW      = AW + 4;            // 20，内部角度累加器位宽
    localparam integer IXW     = IW + 3 + FEXT;     // 23，内部 x/y 位宽（有符号）
    localparam integer SFT     = ZW - AW;           // 4，输出右移量
    localparam integer MAGW    = IW + 2;            // 18，mag 端口位宽
    localparam integer MPW     = IXW + 18;          // 41，mag 乘法结果位宽
    localparam integer MSHW    = MPW - 17;          // 24，mag 右移 17 位后的位宽

    localparam signed [ZW-1:0] HALF_Q   = (1 << (ZW - 2));  // +90°（20bit 标度）
    localparam        [17:0]   MAG_COEF = 18'd79604;        // round(2^17/1.6467602)
    localparam integer         MAG_SHIFT = 17;
    localparam        [ZW-1:0] ROUND_ADD = (1 << (SFT - 1)); // 8，输出四舍五入

    //-------------------------------------------------------------------------
    // ATAN 常量表：function 返回第 idx 项（20bit 标度，正数，signed 解释有效）
    //   表项 = round(atan(2^-idx) * 2^ZW / (2*PI))
    //-------------------------------------------------------------------------
    function [ZW-1:0] atan_i;
        input integer idx;
        begin
            case (idx)
            0:  atan_i = 20'd131072;
            1:  atan_i = 20'd77376;
            2:  atan_i = (ATAN_SRC == 1) ? 20'd40884 : 20'd40881;
            3:  atan_i = 20'd20753;
            4:  atan_i = (ATAN_SRC == 1) ? 20'd10417 : 20'd10416;
            5:  atan_i = 20'd5213;
            6:  atan_i = 20'd2607;
            7:  atan_i = 20'd1304;
            8:  atan_i = (ATAN_SRC == 1) ? 20'd652   : 20'd651;
            9:  atan_i = 20'd326;
            10: atan_i = 20'd163;
            11: atan_i = 20'd81;
            12: atan_i = 20'd41;
            13: atan_i = 20'd20;
            14: atan_i = 20'd10;
            15: atan_i = 20'd5;
            16: atan_i = 20'd3;      // SPEC 表只到 15，以下按定义式外推
            17: atan_i = 20'd2;
            18: atan_i = 20'd1;
            default: atan_i = 20'd0;
            endcase
        end
    endfunction

    wire signed [ZW-1:0] atan_table [0:NITER-1];

    genvar gi;
    generate
        for (gi = 0; gi < NITER; gi = gi + 1) begin : g_atan
            assign atan_table[gi] = atan_i(gi);
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 第 0 级：象限折叠（1 拍）
    //-------------------------------------------------------------------------
    wire signed [IXW-1:0] xse = $signed(x_in);   // 符号扩展到 IXW
    wire signed [IXW-1:0] yse = $signed(y_in);

    reg  signed [IXW-1:0] x0, y0;
    reg  signed [ZW-1:0]  z0;

    always @(*) begin
        if (!x_in[IW-1]) begin                  // x >= 0：第一/四象限
            x0 = xse <<< FEXT;
            y0 = yse <<< FEXT;
            z0 = {ZW{1'b0}};
        end else if (!y_in[IW-1]) begin         // x < 0, y >= 0：第二象限
            x0 = yse <<< FEXT;
            y0 = -(xse <<< FEXT);
            z0 = HALF_Q;
        end else begin                          // x < 0, y <  0：第三象限
            x0 = -(yse <<< FEXT);
            y0 = xse <<< FEXT;
            z0 = -HALF_Q;
        end
    end

    //-------------------------------------------------------------------------
    // 流水寄存器：x/y/z 每级 + 与数据同深的 valid 移位寄存器
    //   x_p[k]/y_p[k]/z_p[k]/vld_p[k] 在同一个 clk 沿更新，k=0 为折叠级
    //-------------------------------------------------------------------------
    reg signed [IXW-1:0] x_p  [0:NITER];
    reg signed [IXW-1:0] y_p  [0:NITER];
    reg signed [ZW-1:0]  z_p  [0:NITER];
    reg                  vld_p[0:NITER];

    always @(posedge clk) begin
        if (!rst_n) begin
            x_p[0]   <= {IXW{1'b0}};
            y_p[0]   <= {IXW{1'b0}};
            z_p[0]   <= {ZW{1'b0}};
            vld_p[0] <= 1'b0;
        end else begin
            x_p[0]   <= x0;
            y_p[0]   <= y0;
            z_p[0]   <= z0;
            vld_p[0] <= in_valid;
        end
    end

    //-------------------------------------------------------------------------
    // 第 1..NITER 级：每级 1 拍
    //   d      = ~y[MSB]                                （y>=0 -> 1）
    //   x[i+1] = d ? x + y_sh : x - y_sh
    //   y[i+1] = d ? y - x_sh : y + x_sh
    //   z[i+1] = d ? z + ATAN[i] : z - ATAN[i]
    //   y_sh / x_sh 都是**向零截断**的 y/2^i、x/2^i
    //-------------------------------------------------------------------------
    genvar ii;
    generate
        for (ii = 0; ii < NITER; ii = ii + 1) begin : g_iter
            wire signed [IXW-1:0] xs_i = x_p[ii];
            wire signed [IXW-1:0] ys_i = y_p[ii];

            // 向零截断右移：先取绝对值（二补数取负）逻辑右移，再恢复符号。
            // 若直接用 Verilog 的 >>>，负数是 floor 而不是向零截断，
            // 每次迭代都会引入固定方向的偏置，累积后可达 1 LSB 量级。
            wire signed [IXW-1:0] x_sh = xs_i[IXW-1] ? -((~xs_i + 1'b1) >>> ii)
                                                     :  (xs_i >>> ii);
            wire signed [IXW-1:0] y_sh = ys_i[IXW-1] ? -((~ys_i + 1'b1) >>> ii)
                                                     :  (ys_i >>> ii);
            wire d = ~ys_i[IXW-1];

            wire signed [IXW-1:0] x_nxt = d ? (xs_i + y_sh) : (xs_i - y_sh);
            wire signed [IXW-1:0] y_nxt = d ? (ys_i - x_sh) : (ys_i + x_sh);
            wire signed [ZW-1:0]  z_nxt = d ? (z_p[ii] + atan_table[ii])
                                            : (z_p[ii] - atan_table[ii]);

            always @(posedge clk) begin
                if (!rst_n) begin
                    x_p[ii+1]   <= {IXW{1'b0}};
                    y_p[ii+1]   <= {IXW{1'b0}};
                    z_p[ii+1]   <= {ZW{1'b0}};
                    vld_p[ii+1] <= 1'b0;
                end else begin
                    x_p[ii+1]   <= x_nxt;
                    y_p[ii+1]   <= y_nxt;
                    z_p[ii+1]   <= z_nxt;
                    vld_p[ii+1] <= vld_p[ii];
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 输出级（1 拍）：角度四舍五入到 AW 位；幅值做 1/1.6468 增益补偿
    //-------------------------------------------------------------------------
    wire signed [ZW:0] z_rnd = $signed({z_p[NITER][ZW-1], z_p[NITER]}) + $signed(ROUND_ADD);
    wire        [AW-1:0] ang_nxt = z_rnd[SFT +: AW];

    wire        [IXW-1:0] x_last  = x_p[NITER];
    wire        [IXW-1:0] x_abs   = x_last[IXW-1] ? (~x_last + 1'b1) : x_last;
    wire        [IXW-1:0] x_scale = x_abs >> FEXT;             // 去掉内部附加小数位
    wire        [MPW-1:0] mag_prd = x_scale * MAG_COEF;        // 单 DSP48
    wire        [MSHW-1:0] mag_sh = mag_prd >> MAG_SHIFT;
    wire        [MAGW-1:0] mag_nxt = (|mag_sh[MSHW-1:MAGW]) ? {MAGW{1'b1}}
                                                            : mag_sh[MAGW-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            angle     <= {AW{1'b0}};
            mag       <= {MAGW{1'b0}};
            out_valid <= 1'b0;
        end else begin
            angle     <= ang_nxt;
            mag       <= mag_nxt;
            out_valid <= vld_p[NITER];
        end
    end

endmodule
