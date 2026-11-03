# FPGA 正余弦细分编码器 —— RTL 接口契约 (v1.4)

> 本文件是全部 RTL 模块的**唯一接口基准**。任何模块实现都必须严格遵守本文件的端口名、位宽、符号性、时钟域与延迟约定，否则无法集成。
>
> 目标器件：Xilinx Artix-7 **XC7A35TFGG484-2**（正点原子 达芬奇-lite）
> 开发工具：Vivado / Vitis **2026.1**（本机实跑版本；竞赛指南推荐 2026.1，次选 2025.2）
> —— 本文件早期写作「Vivado 2020.2 及以上」，那是**未上机前的假设值**；
> 2026-10-15 按本机真实工具链与竞赛指南更正（`README.md` 开发环境段同步）。
> 语言：**Verilog-2001**（禁用 SystemVerilog 语法：`logic`/`always_ff`/`interface`/`typedef` 等一律不可用）

---

## 0. 全局约定

### 0.1 命名与风格
- 端口名、信号名、模块名：**英文小写 + 下划线**。注释：**中文**，允许 UTF-8，文件保存为 **UTF-8 无 BOM**，换行 LF 或 CRLF 均可。
- 端口顺序统一：`clk` → `rst_n` → 输入 → 输出。所有输出若为寄存器输出，端口声明写 `output reg`。
- 复位：**同步复位、低有效**。写法统一为
  ```verilog
  always @(posedge clk) begin
      if (!rst_n) begin ... end
      else begin ... end
  end
  ```
  **禁止**使用异步复位（`always @(posedge clk or negedge rst_n)`），除非模块头注释里明确写明理由。
- **禁止**使用 `initial` 块（除 testbench）、`#delay`（除 testbench）、`inout`、三态（除顶层 IO 的 IOBUF）。
- 位宽必须显式：禁止隐式位宽推断。常数写 `12'd2048` 这种形式（`<宽度>'<进制><值>`）。
- 组合逻辑统一用 `always @(*)` + `begin/end`，每个分支给全部被赋值信号赋值，避免 latch。
- 所有跨时钟域信号必须经过两级同步器（`cdc_sync2.v`）或异步 FIFO。

### 0.2 定点数格式（**全工程统一，不可自行更改**）

| 名称 | 位宽 | 类型 | 含义 |
|---|---|---|---|
| `ADC` 原始码 | 12 | unsigned | AD9238 偏移二进制，`0x800`=0V，`0x000`=-FS，`0xFFF`=+FS |
| `s_raw` / `c_raw` | 12 | **signed** | 去偏置后的 ADC 码（`code - 2048`），范围 −2048…+2047 |
| `s_n` / `c_n` | 16 | **signed** | 归一化正交信号，Q1.15：`+32767` ≈ +1.0，`-32768` ≈ −1.0 |
| `angle` | 16 | **unsigned** | 电角度，`0…65535` 对应 `0°…360°`（一个 sin/cos 输入周期）。**LSB = 360/65536 = 0.0054932°** |
| `pos_frac` | 24 | signed | 扩展位置，`2^24` 对应一个 sin/cos 输入周期（低 8 位是角度的小数位） |
| `pos_full` | 40 | signed | 完整位置 = 多周期计数（高 16 位）+ 周期内角度（低 24 位） |

**角度统一采用"周期归一化"表示（每周期 = 2^16），不要用弧度或浮点。**

### 0.3 时钟域

> **【v1 最终采用的方案，见 `docs/01` §5.1】**
> 全系统只有 **一个时钟域**：板载 50 MHz（引脚 V4，经 BUFG），下文统称 `clk`。
> - ADC 采样时钟 `ad_clk` = `clk` 经 **ODDR(D1=0, D2=1)** 反相 180° 转发到引脚；
> - ADC 数据在同一 `clk` 的**上升沿**捕获（建立余量约 3 ns）；
> - 因此 **不存在跨时钟域问题**，也不需要 MMCM / 任何 IP。
> - 各模块端口里的 `clk` / `clk_cap` / `clk_sys` **在本方案中全部接同一个 `clk`**。
>
> 下表是 v2 升级（把 DSP 链搬到 100 MHz 降延迟）时的规划，仅作参考：

| 时钟 | 频率 | 来源 | 用途 |
|---|---|---|---|
| `clk`（= v1 的 `clk_cap` / `clk_sys`） | 50 MHz | 板载晶振 V4 + BUFG | **v1 全系统唯一时钟** |
| `clk_adc`（v2） | 50 MHz，0° | MMCM CLKOUT0 | 只用于产生送给 AD9238 的采样时钟（经 ODDR） |
| `clk_cap`（v2） | 50 MHz，180° | MMCM CLKOUT1 | AD9238 数据捕获时钟 |
| `clk_sys`（v2） | 100 MHz | MMCM CLKOUT2 | DSP 处理；用 `cdc_pulse` 传 valid |

- ADC 侧握手用一个 `valid` 脉冲（`adc_valid`）。**v1 中该脉冲恒为 1**（ADC 连续采样）；抽取后有效脉冲 `dec_valid` 每 `2^LOG2DEC` 拍出现一次。
- ABZ/UVW 输出由 `clk` 直接产生（频率远低于 50 MHz）。
- BiSS-C 从站：主机时钟 `ma` 最高有限，用 `clk` 过采样 + 边沿检测实现，**不引入新的时钟域**。
  > **MA 上限的定量推导（必须写进报告，不要含糊）**：
  > 从机在 `ma` 下降沿后更新 `SLO`，实现上要经过 2 级同步器 + 1 级输出寄存 = 约 3 个 `clk` 周期。
  > 主机在 `ma` 上升沿采样，因此要求
  > `3 × T_clk + T_setup(master) < T_MA / 2`
  >
  > | 过采样时钟 | 3 周期延迟 | 保守取主机建立时间 | 允许的 `T_MA/2` | **`MA` 上限** |
  > |---|---|---|---|---|
  > | 50 MHz（**v1**） | 60 ns | 20 ns | > 80 ns | **≈ 6 MHz**（保守写 5 MHz） |
  > | 100 MHz（**v2**） | 30 ns | 20 ns | > 50 ns | **≈ 10 MHz** |
  >
  > 也就是说：**v1 能支持到约 5 MHz，v2 能支持到约 10 MHz。**
  > BiSS-C 的典型时钟是 1~10 MHz，因此 v1 已能满足绝大多数主站；若要跑满 10 MHz，把 BiSS 模块放到 100 MHz 域即可。

### 0.4 延迟约定
- 每个模块头注释必须写明 **Latency（从输入 valid 到输出 valid 的 `clk` 周期数）**。
- 数据通路一律采用 **valid 流水**：`in_valid` → N 拍 → `out_valid`。不使用 ready/backpressure。

---

## 1. 模块清单与端口

### 1.1 `ad9238_capture.v` —— ADC 数据捕获与去偏置

```verilog
module ad9238_capture #(
    parameter integer DW = 12            // ADC 位宽
)(
    input  wire                clk_cap,  // 180° 捕获时钟
    input  wire                rst_n,
    input  wire [DW-1:0]       ch1_d,    // CH1 数据（异步输入，来自 AD9238）
    input  wire [DW-1:0]       ch2_d,    // CH2 数据
    input  wire                ch1_otr,  // CH1 超量程标志
    input  wire                ch2_otr,  // CH2 超量程标志
    input  wire                en,       // 1=输出有效数据；0=输出 0（用于上电静默）
    output reg  signed [DW-1:0] s_raw,   // = ch1_d - 2048
    output reg  signed [DW-1:0] c_raw,   // = ch2_d - 2048
    output reg                 otr,      // 两个通道 OTR 的锁存或（写 1 清 */
    output reg                 adc_valid // 每拍都为 1（ADC 连续采样），保持接口一致性
);
```
- **Latency = 3**（2 级同步器 + 1 级运算）。
- OTR 采用 sticky 语义：`otr` 一旦置 1 保持，直到 `rst_n` 或 `en` 下降沿清除。
- 注释中必须写明：AD9238 输出为**偏移二进制**，`0x800` 对应 0 V。

### 1.2 `decim_avg.v` —— 过采样+滑动平均抽取

```verilog
module decim_avg #(
    parameter integer DW       = 13,     // 输入位宽（signed，= ADC位宽+1）
    parameter integer LOG2DEC  = 2       // 抽取率 = 2^LOG2DEC（1,2,4,8,16）
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [DW-1:0] din,
    input  wire                din_valid,
    output reg  signed [DW-1:0] dout,
    output reg                 dout_valid
);
```
- 累加 `2^LOG2DEC` 个样本后算术右移 `LOG2DEC` 位输出，`dout_valid` 拉高 1 拍。
- 内部累加器位宽 = `DW + LOG2DEC`，**必须**用 `$signed()` 参与运算以避免符号问题。
- 溢出行为：饱和到 `{1'b0,{DW-1{1'b1}}}` / `{1'b1,{DW-1{1'b0}}}`。
- **Latency = 2**。
- 一级 CIC（boxcar）在 `f_in=1 kHz`、抽取率 4 时对信号的衰减 < 0.01 dB（在注释里给出该结论）。

### 1.3 `sc_correct.v` —— 六参数误差校正（核心创新点 1）

```verilog
module sc_correct #(
    parameter integer DW = 16            // 输入/输出位宽，Q1.15
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [DW-1:0] s_in,      // 原始正弦（Q1.15）
    input  wire signed [DW-1:0] c_in,      // 原始余弦（Q1.15）
    input  wire                in_valid,
    // ---- 校正系数（由标定状态机/上位机写入，Q1.15 或定点整数）----
    input  wire signed [DW-1:0] ofs_s,     // 正弦直流偏置（Q1.15）
    input  wire signed [DW-1:0] ofs_c,     // 余弦直流偏置（Q1.15）
    input  wire        [DW-1:0] gain_s,    // 正弦增益（Q1.15，1.0 = 16'sd32768）
    input  wire        [DW-1:0] gain_c,    // 余弦增益（Q1.15）
    input  wire signed [DW-1:0] phase_k,   // 正交误差系数 sin(Δφ)（Q1.15）
    output reg  signed [DW-1:0] s_out,
    output reg  signed [DW-1:0] c_out,
    output reg                 out_valid
);
```
**必须实现的数学关系**（与 `model/golden_model.py` 完全一致）：
```
s1 = s_in - ofs_s                              // 去偏置
c1 = c_in - ofs_c
c2 = c1 - ((s1 * phase_k) >>> 15)               // 正交校正（消除非 90° 误差）
s2 = (s1 * gain_s) >>> 15                       // 增益均衡
c3 = (c2 * gain_c) >>> 15
s_out = sat16(s2)
c_out = sat16(c3)
```
- 中间结果位宽必须 ≥ 32 位（`s1 * phase_k` 是 16×16）。**必须**用 `$signed()` 修饰乘法操作数。
- 结果饱和到 16 位有符号范围并置 `sat_flag`（可选输出，若加则追加到端口列表末尾）。
- **Latency = 3**（去偏置 1 拍 + 相位校正 1 拍 + 增益 1 拍）。允许用 3 级流水，但总延迟必须写在注释里。
- **注意**：`>>>` 只对 `signed` 类型是算术移位。所有中间信号必须声明为 `signed`。

### 1.4 `amp_monitor.v` —— 幅值监视（√(s²+c²)，用平方和比较避免开方）

```verilog
module amp_monitor #(
    parameter integer DW = 16
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [DW-1:0] s_n,
    input  wire signed [DW-1:0] c_n,
    input  wire                in_valid,
    input  wire        [31:0]   amp_low_sq,   // 下限的平方（上位机算好）
    input  wire        [31:0]   amp_high_sq,  // 上限的平方
    output reg         [31:0]   amp_sq,       // = s²+c²（Q2.30，无符号）
    output reg                  amp_ok,       // low <= amp_sq <= high
    output reg                  amp_low,      // amp_sq < amp_low_sq
    output reg                  amp_high,     // amp_sq > amp_high_sq
    output reg                  out_valid
);
```
- **Latency = 2**（乘法 1 拍 + 移位/比较 1 拍）。Xilinx DSP48 内乘法 + 后级比较允许 2 拍。
- `amp_sq` 必须饱和到 32 位无符号，不得回绕。
- 注释中说明：专用细分 ASIC 的等效门限是"校准值的 60% / 120%"。

### 1.5 `cordic_atan2.v` —— 全流水向量模式 CORDIC（核心创新点 2）

```verilog
module cordic_atan2 #(
    parameter integer AW    = 16,   // 输出角度位宽（每周期 = 2^AW）
    parameter integer IW    = 16,   // 输入位宽（signed，s_n/c_n 的宽度）
    parameter integer NITER = 17    // 迭代级数（16 级误差 1.19 LSB 超标，17 级 0.9375 LSB）
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
```
**算法（必须逐条实现）**：

1. **象限折叠**，使 `x' ≥ 0`，把角度压到 ±90° 内：
   ```
   x0   = x_in[IW-1] ? (y_in[IW-1] ?  y_in : -y_in) : x_in;
   y0   = x_in[IW-1] ? (y_in[IW-1] ? -x_in :  x_in) : y_in;
   base = x_in[IW-1] ? (y_in[IW-1] ? -(1<<(ZW-2)) : (1<<(ZW-2))) : 0; // ±90°
   ```
   其中 `ZW = AW + 4` 是内部角度累加器位宽。
2. **迭代 NITER 级**，每级 1 拍：
   ```
   d = ~y[i][MSB];                       // y>=0 → d=1；y<0 → d=0
   x[i+1] = d ? (x[i] + (y[i]>>>i)) : (x[i] - (y[i]>>>i));
   y[i+1] = d ? (y[i] - (x[i]>>>i)) : (y[i] + (x[i]>>>i));
   z[i+1] = d ? (z[i] + ATAN[i])    : (z[i] - ATAN[i]);
   ```
   - 内部 `x/y` 位宽 `IW_INT = IW + 3`（CORDIC 增益 1.6468 需要 1 位，再留 2 位余量）。
   - **移位必须"向零截断"**：`>>>` 对负数是向下取整，会引入偏置。实现为
     ```verilog
     wire signed [IW_INT-1:0] y_sh = y[i][IW_INT-1] ? -((~y[i] + 1'b1) >>> i) : (y[i] >>> i);
     ```
     （即先取绝对值移位再恢复符号）。这一点必须体现在注释中，它是 ±1 LSB 级误差的来源。
   - `ATAN[i] = round(atan(2^-i) * 2^ZW / (2*PI))`，`ZW=AW+4`，用 `localparam` 写死成常量数组（见下表，`AW=16, ZW=20`）。
3. **输出**：
   ```
   angle = (base + z[NITER]) >> 4;   // ZW→AW，自然回绕到 [0, 2^AW)
   mag   = x[NITER] 的绝对值，乘 1/1.6468 的补偿（右移 1 位再减 x>>3 近似，或直接给未补偿值并注明）
   ```

**AW=16 / ZW=20 的 ATAN 常量表（十进制）**

> **【已修正】** 下表由定义式 `ATAN[i] = round(atan(2^-i) × 2^20 / (2π))` 重新计算。
> 早期版本手写的 i=2/4/8 三项（40881/10416/651）与定义式不符（正确值 40884/10417/652），
> 三项合计引入约 **-0.383 LSB 的系统性偏置**。**以定义式为准**，
> 且 `model/golden_model.py` 里的 `ATAN_TABLE` 就是按定义式算的，二者必须一致。
> RTL 的 `cordic_atan2.v` 用参数 `ATAN_SRC` 选择：默认 `1` = 定义式值（与黄金模型一致）。

| i | ATAN[i] | i | ATAN[i] |
|---|---|---|---|
| 0 | 131072 | 9 | 326 |
| 1 | 77376 | 10 | 163 |
| 2 | **40884** | 11 | 81 |
| 3 | 20753 | 12 | 41 |
| 4 | **10417** | 13 | 20 |
| 5 | 5213 | 14 | 10 |
| 6 | 2607 | 15 | 5 |
| 7 | 1304 | 16 | 3 |
| 8 | **652** | | |

- **迭代级数 `NITER` 默认取 17**（不是 16）。实测（`model/cordic_model.py`，1/16 LSB 细网格，全圆 1048576 点）：
  - `NITER=16`：最坏角度误差 **1.19 LSB**，**超过 1 LSB 目标**；
  - `NITER=17`：最坏角度误差 **0.9375 LSB = 0.005150°**，RMS **0.3229 LSB**，满足目标；四个正交边界点误差为 0；幅值相对误差 +0.0076%…+0.0111%。
- **Latency = 1（象限折叠）+ NITER + 1（输出寄存）= NITER + 2**。
  `NITER=17` → **19 拍 = 380 ns @50 MHz**。若为了把延迟压到 18 拍而用 `NITER=16`，误差会回到 1.19 LSB —— **这是一个明确的精度/延迟权衡，请在报告里写明所选配置与理由。**
- 象限折叠必须用**修正后的**映射（见上文），否则 Q2/Q3 会收敛到 +x 轴而不是 -x 轴，实测 100°/135°/170° 分别偏 -110°/-145°/-180°。
- `out_valid` 必须与 `angle` 严格对齐（用与数据同深的移位寄存器产生）。
- **必须**提供 `model/cordic_model.py`，用与 RTL **完全相同的定点运算**（含向零截断）逐级仿真，并在全圆上细网格扫描，输出最大/RMS 误差与是否优于 1 LSB 的结论。
  该脚本必须能被 `python cordic_model.py` 直接运行并打印结果表。

### 1.6 `loop_filter.v` —— PI 伺服滤波（抖动抑制 / 滞后控制）

```verilog
module loop_filter #(
    parameter integer AW   = 16,    // 输入角度位宽（每周期 = 2^AW）
    parameter integer FRAC = 8      // 扩展小数位
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire        [AW-1:0] ang_in,     // 输入角度（每周期 2^AW）
    input  wire                in_valid,
    input  wire        [3:0]    kp,         // 0…7（越大滤波越强，与 kp 同义）
    input  wire        [1:0]    ki,         // 0…3
    input  wire                freeze,      // 1=保持当前输出（用于标定/停机抱死）
    output reg  signed [AW+FRAC-1:0] pos_out, // 扩展位置，每周期 = 2^(AW+FRAC)
    output reg                  lag_limit,  // 超前/滞后超过 45°（对应 状态字 laglim）
    output reg                  out_valid
);
```
**数学关系**（内部位置 `pos` 为 `AW+FRAC` 位有符号，周期回绕取模 `2^(AW+FRAC)`）：
```
err = wrap_signed(ang_ext - pos, REV)          // wrap_signed 把差值折到 ±REV/2
integ = integ + (err >>> KI_SHIFT[ki])         // I 项，KI_SHIFT = {7,6,5,4}
pos   = pos + (err >>> KP_SHIFT[kp]) + integ   // P + I
lag_limit = (|err| > REV/8)                    // 45°
```
- `KP_SHIFT = {2,3,4,5,6,7,8}`（kp=0 时用 2，kp=7 时用 8）。
- 必须对 `integ` 做**抗积分饱和**（限幅到 ±REV/4）。
- **Latency = 3**。
- `freeze=1` 时 `pos_out` 保持，`integ` 不清零。
- 端口 `lag_limit` 用于顶层产生 统一的 `STAT_VAL.laglim`。

### 1.7 `pole_counter.v` —— 粗精融合 / 多周期（极）计数与辨向

```verilog
module pole_counter #(
    parameter integer AW = 16,      // 角度位宽
    parameter integer CW = 16       // 多周期计数器位宽（传统方案 = 14，这里给 16 便于扩展）
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire        [AW-1:0] angle,      // 已滤波的周期内角度
    input  wire                in_valid,
    input  wire                z_window,    // Z 门控窗口有效（来自顶层）
    input  wire                clr_on_z,    // 1=Z 上升沿清零多周期计数
    input  wire signed [CW-1:0] preset,     // 多周期计数预置值
    input  wire                preset_en,
    output reg  signed [CW-1:0] cycle_cnt,  // 多周期（极）计数
    output reg  signed [CW+AW-1:0] pos_full,// {cycle_cnt, angle}
    output reg                  dir,        // 1=正转
    output reg                  wrap_pos,   // 正跨零脉冲（1 拍）
    output reg                  wrap_neg,   // 负跨零脉冲（1 拍）
    output reg                  out_valid
);
```
- 跨零判据：上一拍角度在 `[2^AW - 2^(AW-3), 2^AW)` 且本拍在 `[0, 2^(AW-3))` → `wrap_pos`；反向为 `wrap_neg`。门限 `2^(AW-3)` = 45°，与 专用细分 ASIC 的半周期扇区思想一致。
- **必须**用"跨零方向"而不是简单差分来计数，否则在角度抖动时会误计数。这一点写进注释。
- `pos_full` 与 `cycle_cnt` 同拍更新。
- **Latency = 2**。

### 1.8 `abz_gen.v` —— ABZ 增量输出（核心创新点 3）

```verilog
module abz_gen #(
    parameter integer AW   = 16,     // 角度位宽
    parameter integer ZW   = 12,     // Z 相位/宽度位宽（内部）
    parameter integer LIMW = 12      // AB 限频计数器位宽
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire        [AW-1:0] angle,
    input  wire                in_valid,
    input  wire        [9:0]    inter,      // AB 输出周期数/输入周期；0 视为 256；取值 2…256
    input  wire        [2:0]    div,        // 后分频 div = 1…8
    input  wire        [4:0]    hyst,       // 迟滞（0…31），单位 = 360°/2048
    input  wire        [7:0]    ablimit,    // AB 限频；最小边沿间隔 = 20ns*(ablimit+1)*div
    input  wire                apol, bpol, zpol, abzdir,
    input  wire                abzen,
    // ---- Z 通道 ----
    input  wire                z_window,    // 来自顶层 Z 门控窗口
    input  wire        [11:0]   z_phase,    // Z 相位，单位 360°/4096（专用细分 ASIC ZPH 10 位，这里 12 位）
    input  wire        [3:0]    z_width,    // Z 宽度参数（z_width，0…15）；★ v9 起实际脉冲宽 = z_width+1 个 AB 边沿步（1…16）
    output reg                 a_out, b_out, z_out,
    output reg  signed [31:0]  edge_cnt,    // 内部 AB 边沿计数（有符号，用于调试/测速）
    output reg                 limiter_active,
    output reg                 out_valid,
    output reg                 lag_warn,   // 滞后告警（阈值见行为 4b；当前实现 = 180°）
    output reg                 lag_fatal   // 滞后致命（阈值见行为 4b；当前实现 = 360°）
);
```
**必须实现的行为**：
1. **插补**：`edges_per_cycle = 4 * inter`；`edge_idx = (angle * inter) >>> (AW-2)`（等价于 `angle*4*inter / 2^AW`）。

   **A/B 的格雷正交译码有两种等价写法，差别只在"哪一相超前"**（已用 `_tools/check_ab_map.py` 逐点验证）：

   | 写法 | 状态序列 | 相位关系 | 占空 |
   |---|---|---|---|
   | `A = edge_idx[1]^edge_idx[0]`，`B = edge_idx[1]` | 00→10→11→01 | **A 超前 B 90°**（A 首升沿 idx=1，B 首升沿 idx=2） | A 50%、B 50% |
   | `A = edge_idx[1]`，`B = edge_idx[1]^edge_idx[0]`（**本工程 RTL 采用**） | 00→01→11→10 | **B 超前 A 90°**（A 首升沿 idx=2，B 首升沿 idx=1） | A 50%、B 50% |

   两者都是合法正交、都是 50% 占空、都满足 `A ≠ B` 且 `A ≠ ~B`。
   **所以选哪一种只是方向约定问题**，可由 `abzdir`（或交换顶层 a_out/b_out 引脚）完全补偿。

   > ⚠️ 早期版本的模块注释曾断言第一种写法会退化成 "A ≡ ~B、180°、2/3 占空"。**该断言是错误的**：
   > `edge_idx[0]` 每步翻转、`edge_idx[1]` 每两步翻转，二者并不同步翻转。
   > 已用脚本实测更正（证据：`_tools/check_ab_map.py` 输出，A/B 占空均为 50.00%，边沿数各 32/64 步）。
2. **迟滞**：迟滞量为 `hyst * 2^(AW-11)` 个角度 LSB（因为 360°/2048 对应 `2^AW/2048 = 2^(AW-11)`）。仅在"当前边沿索引 + 迟滞"之外才切换，防止静止抖动。实现时用角度比较，不要对边沿索引做模运算比较。
3. **后分频**：`div=1` 时不启用；`div=2…8` 时对边沿索引做 `mod div` 抽取（保留一个 3 位模计数器），得到有效分辨率 `inter/div`。Z 通道**旁路**后分频（与 专用细分 ASIC 一致）。
4. **AB 限频**：内部维护一个以 `clk` 计数的保持计数器 `hold`，当 `hold != 0` 时禁止边沿变化并置 `limiter_active=1`。最小间隔 = `20ns * (ablimit+1) * div`，换算成 `clk_sys` 周期数 = `(20 * (ablimit+1) * div) / 周期ns`。用 `localparam` 参数化时钟周期。
   ★ `limiter_active` **只表示"限频保持/补发"**，不表示"过速跟不上"。过速（`inter*f_in/div > filt_valid`，
   即每拍需要的步数超过"每拍最多点火一次"这条硬上限）走 `lag_warn/lag_fatal`，
   **不得**把它并进 `limiter_active`（否则一次残留会把该位永久拉高，见 `docs/DEV_STATUS.md` §1.33 ⑥ ③）。
4b. **滞后监视**：`lag_mag = |被限频器压住的净步数| + 过速钳位计数`（过速钳位计数见
   `docs/DEV_STATUS.md` §1.33 ⑥，为无方向的 13 位饱和计数），判据
   `lag_mag * div >= (inter + 1) >> 1` → `lag_warn`、
   `lag_mag * div >= 2 * inter` → `lag_fatal`（`inter=0` 按 256 处理）。
   RTL 参数名为 `LAG_WARN_DIV = 2`（右移 2 位 = `/2`）与 `LAG_FATAL_MUL = 2`。
   由于一个输入周期 = `4*inter` 个边沿步（行为 1），这两个阈值换算成角度是
   **45° / 180°**，与标称一致。
   ★ 历史：2026-10-11 前的实现为 `2*inter` / `4*inter`，实际在 **180° / 360°** 才置位
   （标称与实现差 4×，探针实测 180.7° / 361.4°，见 `docs/DEV_STATUS.md` §1.33 ⑦）；
   经定案按 §3 item 18 (b) 重标定为 45° / 180°，本节已同步为**实现值**。
   另注：`lag_mag` 的两个来源都是"每拍最多 +1"，故它是**下界** —— 角度跑得越快，
   同一阈值对应的真实滞后越大（探针实测：64 LSB/拍 → warn 45.0°；256 → 91.1°；
   1024 → 365.3°）；该信号只适合当"严重跟不上"的粗警报，不是精确角度指示。
5. **Z 输出**：当 `z_window=1` 且角度进入 `[z_phase, z_phase + 1)`（单位 360/4096）时，输出 **`z_width + 1`** 个 AB 边沿宽度的 Z 脉冲（★ v9 起按 公开手册口径实现；v8 及以前是 `z_width` 个，`z_width = 0` 时无 Z 输出）；Z 由 `zpol` 反相；`abzen=0` 时 A/B/Z 全部输出 0（高阻由顶层 IOBUF 处理）。
   - ★ **门控边界（v8 明确并修复，见 `docs/DEV_STATUS.md` §1.44）**：`z_window` 只决定**哪一次相位跨零装载 Z**（每 `2^POLE_BITS` 个输入周期一次，顶层 `rtl/enc_top.v` 的 `z_window = (cycle_cnt[...] == 0)`）；**脉冲装载之后的推进、以及 `Z_TIMEOUT` 兜底，不受 `z_window` 关闭影响**。v7 及以前把推进也放在 `z_window` 内，而顶层的窗在装载后 ~2 clk 就关闭（`pole_counter` wrap 延迟）⇒ **集成路径的 Z 脉宽被截成 2 clk = 40 ns**，`z_width` 失效。`abzen=0` 时进行中的脉冲立即中止。
   - 因此**单元级测试台若把 `z_window` 常开，就无法覆盖这条边界**（`sim/tb_abz_gen.v`、`sim/tb_abz_jitter.v`、`sim/tb_loop_abz_chain.v` 都是常开）；集成覆盖在 `sim/tb_enc_top.v` 的 **C5**（TEST C 反向段）。
6. **方向**：`abzdir=1` 时交换 A/B；`apol`/`bpol` 分别反相 A/B。**注意 专用细分 ASIC 行为：只翻转 apol 或 bpol 之一会反转计数方向**，请把该规则写进注释并在 `abzdir` 补偿。
7. **静止时**：不允许 A/B 抖动。

- **Latency ≤ 3**。所有输出寄存器化。
- 必须提供 `sim/tb_abz_gen.v` 自检测试：给定 `inter=64, div=1, hyst=0`，以固定频率推进 `angle` 一个完整周期，检查
  - A/B 边沿总数 = `4*inter`
  - A 与 B 严格 90° 相位差（各占 50%）
  - 一周期内恰好 1 个 Z 脉冲，宽度 = `z_width + 1` 个边沿（★ v9；`z_width = 0` ⇒ 1 步）

> ✅ **规格偏差已修复（2026-10-11，v9）**：通用口径对 Z 宽度写的是 **`(zwidth + 1) / div`** 个边沿（公开数据手册、本设计 §3.5），而 v8 及以前实现是 **`z_width`** 个 —— 差 1 个原始边沿步（默认短 20%），且 `z_width = 0` 在 v8 是"无 Z"而规范语义是 1 个边沿步。两条独立实证：① `sim/logs/tb_enc_top.log` C5 段 Z 高电平 **2042 拍** ≈ 4×512（而非 5×512）；② **板上二值实验**（2026-10-11，AFG 1 kHz、`div = 1`、探头在 `J5-7`）：`z_width = 0`（`0x0108 = 0x4000`）时 **Z 上一个脉冲都没有**、写回 `0x4004` 时 15.625 Hz / 3.906 µs 脉冲立即回来。
> 用户 2026-10-11 选定**按手册修**：`rtl/abz_gen.v` 的 `z_pulse_n = {1'b0, z_width} + 5'd1`、`r_z_left` 由 4 位加宽到 `Z_PULSE_W = 5`、装载拍直接置 `r_z_out <= 1'b1`（`RTL_BUILD_ID` = **v9 = 0x0009**）；`sim/tb_abz_gen.v`（TEST C 扩到 `z_width = 0…8`）、`sim/tb_enc_top.v`（B5 判据收紧为 2304…2816 拍）、`model/abz_uvw_model.py`（跨零拍不计入步数）已同步。详见 `docs/DEV_STATUS.md` §1.47/§1.49 与 §3 item 21。
> ⚠ **极低频截断（v9 起的新约束）**：`Z_TIMEOUT = 4096 clk = 81.9 µs` 是兜底，脉冲长于它会**被截短** ⇒ 需 `(z_width+1)/(1024 × f_in) ≤ 81.9 µs`，即 **`f_in ≥ 11.92 × (z_width + 1) Hz`**（默认 `z_width = 4` ⇒ ≥ 59.6 Hz；`z_width = 15` ⇒ ≥ 190.7 Hz）。超出时读到的脉宽小于名义值，不是缺陷。
  - `div=3` 时 AB 周期数为 `4*inter/3`（允许因除不尽产生的 ±1 误差，测试里说明）

### 1.9 `uvw_gen.v` —— UVW 换向信号

```viv
module uvw_gen #(
    parameter integer AW = 16
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire        [AW-1:0] angle,
    input  wire                in_valid,
    input  wire        [4:0]    pairs,     // 1…32 极对数；0 表示 32（通用语义）
    input  wire                uvwpol, uvwdir,
    input  wire                uwven,
    input  wire signed [15:0]   uvwph,     // UVW 相位偏移，单位 360/1024
    output reg                 u_out, v_out, w_out,
    output reg                 out_valid
);
```
- 电角度 = `angle * pairs`（模 `2^AW`）；再叠加 `uvwph`。
- 6 扇区 120° 六步换向：按电角度落在 60° 区间产生 U/V/W 三相方波（标准梯形换向表：`UVW = {1,1,0},{0,1,0},{0,1,1},{0,0,1},{1,0,1},{1,0,0}`）。
- `uvwdir=1` 反相序；`uvwpol=1` 三相整体反相。
- `uwven=0` 时输出 0。
- **Latency ≤ 3**。
- 提供 `sim/tb_uvw_gen.v`：`pairs=4` 时，一个输入周期内 UVW 应出现 4 个完整电周期，且 6 个状态的驻留时间相等（±1 个 `clk` 采样误差）。

### 1.10 `biss_c_slave.v` —— BiSS-C 从站（核心创新点 4，低阶方案没有、高阶方案才提供）

```verilog
module biss_c_slave #(
    parameter integer ST_BITS = 26,   // 单圈数据位宽（1…32），MSB 先发
    parameter integer MT_BITS = 12,   // 多圈数据位宽（0/12/16/24/32）
    parameter integer LINK_LOST_CYCLES = 100000  // v1.1：链路静默门限（clk_sys 拍）
)(
    input  wire                clk,       // clk_sys，50 MHz（20 ns）
    input  wire                rst_n,
    input  wire                ma,        // BiSS 主机时钟（异步输入，最高 6.25 MHz，保守 5 MHz）
    input  wire                sl,        // BiSS 主机→从机数据线（异步输入）
    output reg                 slo,       // 从机→主机数据线（在 MA 下降沿更新）
    // ---- 待发送数据 ----
    input  wire        [31:0]   st_data,  // 单圈位置
    input  wire        [31:0]   mt_data,  // 多圈位置
    input  wire                err_bit,   // E 位
    input  wire                warn_bit,  // W 位
    // ---- 可选：BiSS 寄存器通信（CDS/CDM）。首版可只做"始终回 0"，但要留出寄存器读接口 ----
    input  wire        [7:0]    reg_addr,
    input  wire        [7:0]    reg_wdata,
    input  wire                reg_we,
    output reg         [15:0]   frame_cnt,
    output reg                 frame_active,
    output reg                 crc_err_seen,
    // ---- v1.1 追加（2026-10-18，见 §5 变更记录）----
    input  wire                crc_err_clr,  // 1 拍脉冲：清 crc_err_seen（W1C，契约 §1.11 0x0405 bit0）
    output reg                 link_lost     // 链路静默：ma 连续 LINK_LOST_CYCLES 拍无边沿
);
```
**BiSS-C 帧格式（必须严格实现）**：
```
  位序:  0        1 .. ST_BITS        +1 .. +MT_BITS      +1  +2   +3 .. +8
  内容:  起始位0   ST 数据(MSB先)       MT 数据(MSB先)      E   W    CRC6(MSB先)
```
- **时序**：`ma` 每个下降沿更新 `slo`；主机在 `ma` 上升沿采样。空闲时（`ma` 与 `sl` 均为高 ≥ 一段时间，超时门限 = 10 个 `clk_sys` 周期 @50 MHz 对应 200 ns，实际用参数 `TIMEOUT_CYCLES`）复位帧计数器。
- 起始位固定为 0，用于让主机同步。
- **CRC6**：多项式 `x^6 + x + 1`（即 `6'b000011` 的 LFSR，初值 0），对 ST、MT、E、W 全部位计算，MSB 先发。必须给出与标准 BiSS-C 一致的实现，并在注释中给出计算示例向量。
- `frame_cnt` 记录本次帧已发送的位数；`frame_active` 在帧内为 1。
- `crc_err_seen`：若检测到主机在 CRC 后仍继续给时钟超过 N 位（协议违例），置位。
- **（v1.1 新增）`crc_err_clr`**：1 拍脉冲，清掉 `crc_err_seen`。语义与 §1.11 的 `clr_otr` 完全一致（同一次 `0x0405 bit0` 写入产生），并且**同拍置位优先**：清位那一拍若恰好又检测到协议违例，`crc_err_seen` 仍为 1。为什么必须有这条通路：`crc_err_seen` 是粘滞位、只有 `rst_n` 能清，而显示侧把它算进空态判据 ⇒ 清一次"锁存故障"后若屏上仍判空态，用户就再也没有退出的手段（屏幕侧会显示"已清除"而读数永远不回来）。
- **（v1.1 新增）`link_lost`**：链路心跳，**非粘滞**。实现是数 `ma` 的边沿间隔：任意边沿（上升或下降）都把间隔计数器清零并让 `link_lost` 落回 0；连续 `LINK_LOST_CYCLES` 拍（默认 100,000 = **2 ms** @50 MHz）无边沿则置 1。口径说明：
  - 门限 2 ms 不会误判合法慢主机：BiSS-C 一帧在 5 MHz（v1 的 `ma` 上限）下约 9.4 us（47 bit），即使帧率降到 1 kHz（帧周期 1 ms），帧间静默也只有 1 ms 左右，2 ms 的门限留了一倍余量；
  - 为什么数"任意边沿"而不是只数下降沿：`ma` 的占空比由主站决定，只认下降沿会把"主机改成窄脉冲但仍在打"误判成静默；
  - 为什么不用 `frame_cnt`/`frame_active` 判断：`TIMEOUT_CYCLES` 只在帧内复位帧状态机，帧间空闲它本来就是 0，无法区分"帧间空闲"与"主机停了"。
  - 显示侧用途见 `docs/13_display_ui_requirements.md` §7 反模式 8：主机停止打时钟时 `crc_err_seen` 不置位、幅值也可能仍在窗口内，屏上会把尸体读数当合法值显示。
- **必须**提供 `sim/tb_biss_c_slave.v`：用行为级 BiSS 主机模型（产生 10 MHz `ma`，按位采样 `slo`，自行做 CRC 校验），随机构造 1000 帧数据，要求 1000 帧全部 CRC 校验通过。

### 1.11 `spi_slave.v` + `reg_file.v` —— 配置接口与寄存器组

```verilog
module spi_slave #(parameter integer AW = 16, parameter integer DW = 8)(
    input  wire          clk, rst_n,
    input  wire          sck, ssi, ss_n,     // 异步输入，内部两级同步
    output reg           sso,
    output reg  [AW-1:0] addr,
    output reg  [DW-1:0] wdata,
    output reg           we,
    input  wire [DW-1:0] rdata
);
```
- **地址位宽必须是 16**（不是 8）：寄存器组里 `0x5xxx` 段的标定结果与状态量都超出 8 位地址，若用 8 位会整段不可访问。这是一个已经踩过的坑。
- 模式 0（CPOL=0, CPHA=0），MSB 先，单次传输 = 1 字节地址 + 1 字节数据（读时 `sso` 在地址字节期间返回上一拍读数据）。
- 为了便于上位机调试，**同时**实现一个更简单的 **32 位命令包**格式（见 `docs/01_technical_solution.md` 第 7 节），两者用参数 `USE_PKT_MODE` 选择。

```verilog
module reg_file (
    input  wire        clk, rst_n,
    input  wire [7:0]  addr, wdata, input wire we,
    output reg  [7:0]  rdata,
    // ---- 1 拍脉冲输出（见下方 W1C 说明）----
    output reg         calib_start,   // 写 CALIB_CTRL[0]
    output reg         clr_otr,       // 写 STAT_LATCH[0]=1 → 清 ADC 内部 sticky OTR
    output reg         clr_biss_crc,  // v1.1：同一个写 → 清 biss_c_slave 的 crc_err_seen
    // ---- 输出到各功能模块的配置 ----
    output reg  [9:0]  cfg_inter, cfg_zphase, ...
    // ---- 输入状态 ----
    input  wire [31:0] stat_amp_sq, ...
);
```
- 地址表必须**优先复用 专用细分 ASIC 的地址**（`0x00 MAIN_CFG`、`0x01 LED_CFG`、`0x10 LED_PWM`、`0x100 UVW_CFG`、`0x101 INTER0`、`0x102 INTER1`、`0x103 AB`、`0x104 UVW`、`0x105 FALARM`、`0x106 ABLIMIT`、`0x107 ZERO0`、`0x108 ZERO1`、`0x109 OUTPUT`、`0x10A ZPHASE`、`0x10B UVWPH`、`0x10C PHASE_LSB`、`0x300 FILT_CFG`、`0x301 FILT_LAG`、`0x302 FILT_K`、`0x404 STAT_VAL`、`0x405 STAT_LATCH`、`0xE000 DEVICE_ID`），扩展寄存器用 `0x5xxx` 段，避免与 专用细分 ASIC 冲突。
- `DEVICE_ID` 必须返回 `8'h0C`（与 专用细分 ASIC 一致，便于上位机复用）。
- `0x0405 STAT_LATCH` 必须是 **W1C（写 1 清对应位）**，与 专用细分 ASIC 的"写 0 清位"**相反**：整字节写入时写 0 清位会一次抹掉全部锁存。**写 bit0（otr 位）时还必须同拍输出 1 拍 `clr_otr` 脉冲**，清 `ad9238_capture` 内部的 sticky OTR —— 该 sticky 与寄存器里的锁存位是两个独立锁存器（前者只有 `clr_otr` / `rst_n` / `en` 下降沿能清），只清锁存位不会让 `led[0]` 与 `irq_n` 恢复。2026-10-10 上板实测：`clr_otr` 原在顶层被硬接 `1'b0`，OTR 一旦锁存即永久保持（led[0] 常亮、irq_n 常低），只能重配置器件。若清位时 OTR 引脚仍为高，数拍后会重新锁存（这是期望语义，用于区分瞬时过载与真过载）。
- **（v1.1 新增）同一次 `0x0405 bit0` 写入还必须输出 `clr_biss_crc`**（口径与 `clr_otr` 逐字相同：1 拍脉冲、同拍置位优先），接到 `biss_c_slave.crc_err_clr`。理由同上一条：`crc_err_seen` 是两个独立粘滞器之一 —— 寄存器里 `0x053A[6]` 只读镜像它，而这个"seen"位本身在 `biss_c_slave` 内部，只有复位能清。显示侧把它算进空态判据（`docs/13_display_ui_requirements.md` §7），所以屏上的"清除锁存故障"按钮必须能把它清掉，否则清完屏上仍判空态、读数永远不回来。

### 1.12 `uart_rx.v` + `uart_spi_bridge.v` —— UART→SPI 桥（没有外部 SPI 主机也能改寄存器）

**为什么存在**：上板调试经常没有 SPI 主机（板上的 USB 串口是唯一的现成上位机通道）。
本桥在 FPGA **内部**当 SPI 主机去驱动 1.11 的 `spi_slave`，上位机只要往串口发 4 个字节
就能读写任意寄存器，不需要任何额外硬件，也顺带把真正的 `spi_slave` 通路测到。
顶层用 `br_ss_n` 在"桥"和"外部引脚"之间二选一，**不占用任何新引脚**。

```verilog
module uart_rx #(parameter integer BAUD_DIV = 25,
                 parameter integer BAUD_DIV_HALF = BAUD_DIV/2)(
    input  wire       clk, rst_n,
    input  wire       rx,
    output reg  [7:0] rx_data,
    output reg        rx_valid,     // 单周期脉冲
    output wire       rx_busy
);

module uart_spi_bridge #(
    parameter integer BAUD_DIV = 25,      // 2 Mbaud @ 50 MHz
    parameter integer SPI_HALF = 8,       // SPI 半周期 8 拍 -> sck 3.125 MHz
    parameter integer GAP      = 16,      // 应答帧间强制间隔
    parameter integer TO_DIV   = 100_000, // 半包超时 = 2 ms
    parameter integer GAP_MIN  = 13*25    // 首字节前线路空闲门限 = 13 位
)(
    input  wire clk, rst_n,
    input  wire rx,
    output wire tx,                       // 与遥测二选一（顶层 uart_tx）
    input  wire scope_tx,                 // 遥测正在发的位
    input  wire scope_idle,               // 遥测行空闲（可以安全抢线）
    output wire scope_hold,               // 1 = 请遥测别启动新帧
    input  wire ext_busy,                 // 外部 SPI 主机占用总线（= ~spi_ss_n）
    output wire spi_sck, spi_ss_n, spi_mosi,
    input  wire spi_miso
);
```

- **帧格式**：命令 4 字节 = 完整 32 位 SPI 包（`st|rm|wm|page|addr[7:0]|data[15:0]`），
  首字节 = `0x80 | (wm<<3) | page`，`st` 位天然为 1。应答 6 字节 =
  `0x5A | resp[31:24] | resp[23:16] | resp[15:8] | resp[7:0] | chk`，`chk = 0x5A ^ 前 4 字节`。
  例：`read 0x05F0` -> `85 F0 00 00`；`write 0x0109 0x00C0` -> `89 09 00 C0`；
  `write 0x0405 0x0001` -> `8C 05 00 01`；`write 0x0502 0x0001` -> `8D 02 00 01`。
- **读命令连发两帧**（专用细分 ASIC 重叠：命令 N 的响应在第 N+1 帧才移出），**写命令只发一帧**
  （`0x0502 CALIB_CTRL` 的 start 位写两次会触发两次标定）。写命令的应答内容是上一帧的，
  没有语义，只用于确认"链路通、命令已被执行"。
- **TX 仲裁**：遥测（`uart_scope`）与应答共用 `uart_tx`。桥抢线前先把 `scope_hold` 拉高
  阻止遥测**启动新帧**，但绝不打断正在发送的遥测帧；等到 `scope_idle`（线为高）才把 TX 切到
  应答。⇒ **`tx_hold`（＝`scope_hold`）与 `tx_drive`（＝TX 二选一）必须是两个条件**：
  2026-10-10 仿真实测，把两者合成一个条件会在进入 `C_REPLY`（SPI 帧刚发完、遥测常常正发到
  一半）时把遥测帧拦腰截断，出现 5/71 帧校验错。应答期间遥测少发几帧是有意代价。
- **帧同步三重保护**：① 首字节 `bit7` 必须为 1，否则整包忽略；② 首字节前线路空闲必须
  ≥ `GAP_MIN`（13 位 ≈ 6.5 µs），防止上一条命令的残尾/多发字节被当成新命令；③ 第 2~4 字节
  之间超过 `TO_DIV`（2 ms）未收齐即丢弃残包。⇒ 上位机**必须**"收到应答再发下一条"。
- **与外部 SPI 主机互斥**：`ext_busy` 期间不启动内部帧；等待超过 `TO_DIV` 就整条命令放弃
  （不写、不应答），由上位机超时重试——宁可这条命令不做，也不与外部主机抢总线。
- **波特率固定 2 Mbaud**（与遥测共用顶层 `BAUD_DIV`），一个 COM 口一套参数。若 CH340E 在
  2 Mbaud 下不稳，退路是把顶层 `BAUD_DIV` 改成 50（1 Mbaud）重出位流。
- **引脚/XDC**：`uart_rxd` = T20、`uart_txd` = W21（板载 CH340E，`docs/ATK_board_digest.md:61`）；
  `uart_rx` 已加入 `constr/enc_top.xdc` 第 7 节异步输入 `set_false_path` 表，并在第 9 节有引脚约束。
- **上位机工具**：`tools/uart_spi.py`（`--selftest` 不接硬件自检编解码；`read/write/dump/ports`
  子命令；`--file` 可离线从抓包文件里找应答）。读命令的响应里 `[31:24]` 是
  `{page,0x3A}` 的读值（page5 即 `0x053A STAT_FLAGS`），`[23:16]` 是地址回显。
- **必须**提供 `sim/tb_uart_spi_bridge.v`：真 `uart_scope`（`SAMPLE_DIV=1000`，50 kHz 遥测
  ≈ 线路几乎满载的最坏仲裁工况）+ 真 `uart_spi_bridge` + 真 `spi_slave(USE_PKT_MODE=1)`
  + 64K 寄存器阵列，覆盖：遥测零错帧、写生效、读回新值（两帧逻辑的唯一证据）、
  `CALIB_CTRL` 只写一帧、坏首字节被丢、半包超时后重同步、波特率 ±2%、外部主机短/长占用。
  实测 **44 checks PASS**（`sim/logs/tb_uart_spi_bridge.log`）。

### 1.13 `uart_scope.v` —— UART 遥测帧（唯一的"长时观测"通道，**帧布局 v2**）

**为什么存在**：ILA 只有 1024 点 = 20.5 µs 单窗，看不到"秒级/分钟级"的行为；遥测帧把每
100 µs 一次的角度/正余弦/位置/状态位打上串口，是唯一能长时间连续观测的通道
（`docs/06` §4.2、`tools/uart_scope.py`）。2026-10-12（RTL `0x000C`）起帧内**同时携带
ABZ/UVW 六路电平**，不用示波器/ILA 也能看输出波形（用户要求的"路线 C"）。

```verilog
module uart_scope #(
    parameter integer BAUD_DIV   = 25,       // 50 MHz / 2 Mbaud
    parameter integer SAMPLE_DIV = 5000      // 50 MHz / 5000 = 10 kHz 帧率
)(
    input  wire        clk, rst_n,
    input  wire        en,                   // 0 = 停发
    input  wire        hold,                 // 1 = 本拍不要启动新帧（桥要抢 TX 发应答）
    input  wire [15:0] angle,
    input  wire signed [15:0] s_n,
    input  wire signed [15:0] c_n,
    input  wire [7:0]  io_state,             // {limiter_active,dir,w,v,u,z,b,a}
    input  wire [7:0]  io_flags,             // {amp_bad,cor_sat,uwven,abzen,uvw_fw,zwin,lagf,lagw}
    input  wire [31:0] pos_full,
    input  wire [7:0]  stat,
    output wire        tx,
    output wire        tx_idle,              // 行空闲：可以安全把发送权让给桥
    output reg  [15:0] frame_cnt             // 已发送帧数（调试用）
);
```

- **帧 = 18 字节定长、大端**，每 `SAMPLE_DIV` 拍打一帧（10 kHz）；帧头 `AA 55`，
  末字节 = XOR 校验。**时间预算**：一帧 = `17×(10×25+2) + 10×25 = 4534 clk = 90.68 µs`，
  `latch` 节拍 = 5000 clk = 100 µs ⇒ **链路占用 90.7%**。想动 `SAMPLE_DIV`/`BAUD_DIV`
  之前必须先按这个算式复核（余量只有 9.3%）。
- **帧布局 v2**（现行）：

  | 偏移 | 内容 |
  |---|---|
  | 0..1 | `AA 55` 帧头（**参与校验**） |
  | 2..3 | `angle[15:0]`（0.0055°/LSB） |
  | 4..5 | `s_n[15:0]`（Q1.15 有符号，校正后） |
  | 6..7 | `c_n[15:0]`（Q1.15 有符号，校正后） |
  | 8 | **`io_state`**：bit0..5 = `a b z u v w` 输出电平、bit6 = `dir`、bit7 = `limiter_active` |
  | 9 | **`0xA2` 帧布局标记**（`FRAME_TAG_IO`） |
  | 10 | **`io_flags`**：bit0 `lag_warn`、bit1 `lag_fatal`、bit2 `z_window`、bit3 `uvw_freq_warn`、bit4 `cfg_abzen`、bit5 `cfg_uwven`、bit6 `cor_sat`、bit7 `amp_bad` |
  | 11 | `0x00`（`FRAME_RESV`，保留且**参与校验**） |
  | 12..15 | `pos_full[31:0]`（原始位置，含多周期） |
  | 16 | `stat` 状态字节 |
  | 17 | `chk = 0xAA ^ 0x55 ^ (偏移 2..16 逐字节 XOR)`（`rtl/uart_scope.v:219-226`） |
- **v1 旧布局**（v11 及更早位流）：偏移 8..11 = `amp_sq[31:0]`。**判别位 = 偏移 9**：
  v2 恒为 `0xA2`；旧布局此处 = `amp_sq[23:16]`，而 `amp_sq` 饱和到 ≤ `0x80000000`
  （`rtl/amp_monitor.v:90`）⇒ 该字节 **≤ 0x80**，**永不会撞上 `0xA2`**。上位机据此分派解析。
- **`amp_sq` 从帧里删掉是无损的**：同帧的 `s_n`/`c_n` 就是 `s_cor`/`c_cor`，
  `amp_sq = sat32(s² + c²)`，而满幅 `int16` 时 `s² + c² ≤ 2³¹` 够不着饱和 ⇒ 上位机
  `(s*s + c*c) & 0xFFFFFFFF` 与 RTL 的 `amp_sq` **逐位相同**（`tools/uart_scope.py` 照旧输出该列）。
- **不能在时间轴上直接看 A/B 波形**：AB 边沿率 = `4×inter/div×f_in`（默认 inter=256@1 kHz
  即 1.024 MHz）**远高于 10 kHz 帧率** ⇒ 按帧序号画必然混叠。真实波形要用**按电角度分箱的
  等效采样**（`tools/uart_scope.py` 的 64 箱第 3 行图、`docs/06` §4.2）。
- **改动纪律（契约的一部分）**：帧内任何字节/线序/校验的改动都必须**同步** ①`sim/tb_uart_scope.v`
  ②`sim/tb_uart_baud.v` ③`sim/tb_uart_period.v` ④`sim/tb_uart_spi_bridge.v`
  ⑤`tools/uart_scope.py` ⑥`tools/check_uart_frame_fixture.py` ⑦`sim/fixtures/uart_frame_rtl.hex`
  （⑦由 `sim/logs/tb_uart_scope.log` 的 `RTL_FRAME_HEX` 行重生成，⑥ 用实拍帧**逐字节**钉死
  RTL 与上位机两侧，含"校验必须含帧头常量、不是纯载荷 XOR"的反事实检查）。另：改 RTL 必须递增
  `rtl/enc_top.v` 的 `RTL_BUILD_ID`（`0x05F2` 可读回）。
- ★ **v12 已重综合（2026-10-12 23:59 / 2026-10-13 07:12）**：生产位流 `_synth_work/enc_top.bit`
  **1,042,208 B @2026-10-12 23:59:27**、SHA256 `D93DEBF92034FF2329117CDE59EB83E0D95620306E7A944C6B0402E8C3AE7725`
  （WNS **+0.959** / 0 失败端点 / 11,275）；ILA 调试版 `enc_top_ila.bit` **1,428,064 B @2026-10-13 07:12:11**（WNS +0.332 / 20,165 端点）。
  **但"位流已产出" ≠ "板上已换版"**：烧写后需读回 `0x05F2` = **`0x000C`**、遥测**偏移 9 = `0xA2`** 才算 v12 生效；
  若仍是 `0x000B`，帧里就没有电平（偏移 9 读到的是 `amp_sq[23:16]`，上位机会自动按 v1 解析并提示）。

---

### 1.14 `cap_regs.v` —— 抓包寄存器组（0x0700 段，v1.2 新增，B1）

`reg_file` 把 `addr[15:8]==0x07` 的读写整段转给本模块（`ext_we/ext_addr/ext_wdata/ext_rdata`），
`reg_file` 的读 `default` 分支回填 `ext_rdata`。**`cap_regs` 自己不做 SPI/帧解析**。

**地址排布：每个寄存器 16 bit 对齐、占 2 个字节地址。** 这是被 `spi_slave` 的 32 位包
格式逼出来的——一次 16 bit 写会在 `addr` 与 `addr+1` 各产生一个 8 bit 写脉冲
（`rtl/spi_slave.v` 的 `P_WR0/P_WR1`）。若按 8 bit/字段紧凑排布，写高字节会踩掉邻居。

| 地址 | 名称 | 说明 |
|---|---|---|
| 0x0700/01 | `MAC[15:0]` | B2 用，B1 只占位 |
| 0x0702/03 | `MAC[31:16]` | |
| 0x0704/05 | `IP[15:0]` | 本机 IP，默认 192.168.1.10 |
| 0x0706/07 | `IP[31:16]` | |
| 0x0708/09 | `HOST_IP[15:0]` | 默认 192.168.1.100 |
| 0x070A/0B | `HOST_IP[31:16]` | |
| 0x070C/0D | `PORT` | 默认 5000 |
| 0x070E/0F | `CTRL` | B2 使能位 |
| 0x0710/11 | `ETH_STATUS` | B1 读 0 |
| 0x0712/13 | `TX_PKT` | B1 读 0 |
| 0x0714/15 | `TX_DROP` | B1 读 0 |
| 0x0716/17 | `RX_PKT` | B1 读 0 |
| 0x0718/19 | `CAP_SRC` | `[0]` 源（0=原始 50 MSPS `s_q15/c_q15`，1=校正 12.5 MSPS `s_cor/c_cor`）；`[2:1]` 抽取 log2（0..3） |
| 0x071A/1B | `CAP_LEN` | 窗口点数，默认 28672（v60 起；恢复值见 §1.15） |
| 0x071C/1D | `TRIG_CFG` | `[1:0]` 0=立即 1=上升沿 2=下降沿 |
| 0x071E/1F | `TRIG_LEVEL` | 有符号门限 |
| 0x0720/21 | `PRE` | 预触发点数，默认 1024 |
| 0x0722/23 | `CAP_CTRL` | `[0]` arm（写 1 启动）、`[1]` abort |
| 0x0724/25 | `CAP_STATUS` | `[0]` done `[1]` armed `[2]` trig `[3]` busy `[4]` ovf |
| 0x0726/27 | `TRIG_IDX` | 触发点在窗口内的下标 |
| 0x0728/29 | `SAMP_LO` | 50 MHz 样点计数 `[15:0]` |
| 0x072A/2B | `SAMP_HI` | 样点计数 `[31:16]` |
| 0x072C/2D | `BUILD` | `0x000D`（v13） |
| 0x072E/2F | `DUMP_CTRL` | `[0]` start、`[1]` abort |
| 0x0730/31 | `DUMP_STATUS` | `[0]` busy `[1]` done |
| 0x0732/33 | `CAP_LEN_EFF` | 被 `DEPTH` 截断后的实际窗口点数 |
| 0x0734/35 | `BLOCKS_DONE` | 已发块数 |
| 0x0750/51 | `RX_CLK_CNT` | RXC 域时钟计数（诊断：RXC 在不在跳）★v61 |
| 0x0752/53 | `RX_DV_CNT` | RXDV 上升沿个数（收到几帧）★v61 |
| 0x0754/55 | `RX_BYTE_CNT` | RXDV 有效字节数 ★v61 |
| 0x0756/57 | `RX_ERR_CNT` | 收帧错误数 ★v61 |
| 0x0758/59 | `IDELAY_TAP` | 写 `[4:0]` tap 并装载（`VAR_LOAD`）；读回 `[5]`=idelay_rdy ★v61 |

**脉冲语义**：`arm/abort/dump_start/dump_abort` 都是"写 1 触发一个 clk 脉冲"，读回自然是 0，
上位机不需要写 0 清除。

**复位默认值**（必须与上位机"零配置也能抓"一致）：`CAP_LEN=28672`、`PRE=1024`、
`CAP_SRC=0x0002`（原始 50 MSPS、抽取 2）、`TRIG_CFG=0`（立即）、`BUILD=0x000D`。

### 1.15 `scope_capture.v` —— 抓包引擎（v1.2 新增，B1）

参数 `DEPTH`（默认 28672）。v60 起拆成三块 bank（16384 + 8192 + 4096）以避开
`32768` 那种 2 的幂容量：`DEPTH ≤ 16384` 时综合成单块 `mem`，`16384 < DEPTH ≤ 28672`
时走三 bank 分支（写口按 `wr_addr[14:13]` 选 bank，读口三块同拍寄存后组合 mux，
相对 `rd_en` 仍是 1 拍）。DEPTH 不要求是 2 的幂，但必须是 1024 的整数倍才能整除
RAMB36。端口：`arm/abort/dec_log2/cap_len/trig_mode/
trig_level/pre_len/s_in/c_in/in_valid/rd_addr/rd_en/rd_data/cap_start/cap_len_eff/trig_idx/
sample_cnt/st_armed/st_done/st_trig/st_busy/st_ovf`。

- **抽取**：每 `2^dec_log2` 个 `in_valid` 样本存 1 个（`dec_cnt3` 计数）。
- **存储**：`mem` 是 32 bit × `DEPTH`（ch1 16 bit + ch2 16 bit），地址环形回绕。
- **立即触发**（`trig_mode=0`）：arm 后第一个样本即触发，`cap_start=0`，收满 `len_eff` 个
  样本置 `st_done`。
- **边沿触发**（`trig_mode=1/2`）：在**抽取后**的样本上比较 `prev_s` 与 `trig_level`；
  触发时 `wr_addr` 即"当前样本地址"，`cap_start = wr_addr - pre_eff`（按 `DEPTH` 回绕），
  `target = len_eff - pre_eff`，此后每收一个样本 `post_cnt+1`，`post_cnt==target` 置 done。
- **溢出**：`cap_len > DEPTH` 时置 `st_ovf`，窗口按 `DEPTH` 截断（`cap_len_eff`）。
- **读口**：`rd_en` 单拍抽样到寄存器，下一拍 `rd_data` 有效（1 拍读延迟）；地址由
  `scope_dump` 给出（已含 `cap_start` 偏移与回绕）。

### 1.16 `scope_dump.v` —— UART 批量 dump（v1.2 新增，B1）

参数 `DEPTH`、`BAUD_DIV`（沿用 `enc_top` 的 25 → 2 Mbaud）、`START_DELAY`（250000 = 5 ms
@50 MHz）、`PTS`（每块点数，默认 64）。

- **块格式**（264 B @64 点）：`AA 55 A2 0x10 | seq | n | 4B×n | XOR`。
  `seq` = 块号低 8 位，`n` = 本块点数（1..64，末块可不足），
  `XOR` 覆盖块头 7 字节 + 全部载荷字节。
- **点格式**：每点 4 B = `s_n[15:0]`（小端）→ `c_n[15:0]`（小端），与遥测帧的
  `s_n/c_n` 同源同量纲。
- **启动**：`start` 单拍脉冲 → 等 `START_DELAY`（覆盖"写 DUMP_CTRL 的 6 B 应答"）→
  等 `line_idle`（线上空闲）→ 推块。
- **仲裁**：`busy` 期间 `enc_top` 把 `uart_spi_bridge` 的 `scope_hold` 拉高（遥测不再起新帧），
  并把 `tx` 切到本模块；dump 起点用 `scope_idle & !br_scope_hold` 三重门控。
- **总量**：28672 点 / 448 块 × 264 B = 118,272 B（载荷 114,688 B），@2 Mbaud（179,954 B/s）
  ≈ **0.66 s**。窗口 1.147 ms @25 MSPS（抽取 2）、0.573 ms @50 MSPS。

### 1.17 `rtl/eth/async_fifo.v` —— 格雷码异步 FIFO（v1.3 新增，B2）

参数 `DW`、`AW`（深度 = 2^AW）、`ALMOST`。端口：写侧 `wr_clk/wr_rst_n/wr_en/din/full/
almost_full`，读侧 `rd_clk/rd_rst_n/rd_en/dout/empty`，另有 `wr_level/rd_level`（二进制占用数）。

- 读/写指针各加 1 bit 作为"绕圈"标志，跨域只同步**格雷码**，每拍仅 1 bit 变化。
- `full` 判定用"高两位相反、低位相等"；`empty` 是格雷码逐位相等。
- `almost_full`/`wr_level`/`rd_level` 先把格雷码还原成二进制再算差（早期版本直接对格雷码做减法，
  读数会错，已修）。

### 1.18 `rtl/eth/rgmii_if.v` —— RGMII 收发原语（v1.3 新增，B2）

参数 `USE_IDELAY`、`IDELAY_VAL`。TX：对 `txd[3:0]`、`tx_ctl`、`txc` 各用一组 `ODDR`
（DDR 双沿），`txd` 的 `D1 = txd[i]`、`D2 = txd[i+4]`（低半字节先出）。RX：`eth_rxc` 经 `BUFG`，
`IDDR(SAME_EDGE_PIPELINED)` 拆成 `rxd_f/rxd_r`，`gmii_rxd = {rxd_f, rxd_r}`、`rx_dv = ctl_r`、
`rx_err = ctl_f`。

- **前置条件**：链路必须协商到 **1000 Mbps**。10/100 Mbps 时 RGMII 走单沿、每拍 1 个半字节，
  本模块的拆半字节方式不适用；要支持需读 MDIO 的速率位。
- `USE_IDELAY=1` 时给 RX 数据/控制加 `IDELAYE2`（B2 默认 0，等上板实测再定抽头）。

### 1.19 `rtl/eth/eth_tx_mac.v` / `eth_rx_mac.v` —— 以太网 MAC 收发（v1.3 新增，B2）

- **TX**：输入 `tx_valid/tx_data/tx_last`（**没有 `tx_req`**：`S_IDLE` 里看到 `tx_valid` 就直接开帧），
  输出 `tx_ready/done/frame_len`。前导码 7×`0x55` + `0xD5`，之后逐字节算 CRC32（反射多项式
  `0xEDB88320`，初值全 1，末尾取反），`S_CRC` 发 4 字节 FCS，`S_IFG` 等 12 字节。
- **RX**：连续 ≥5 个 `0x55` 后遇 `0xD5` 判 SFD；4 字节延迟管道把 FCS 挡在 `rx_eof` 之外；
  帧尾 `crc != 32'h2144_DF1C` 或长度 < 18 报 `rx_err`。输出 `rx_valid/rx_data/rx_sof/rx_eof/
  rx_err/rx_len/rx_done`。

### 1.20 `rtl/eth/eth_reply.v` —— ARP / ICMP 应答（v1.3 新增，B2）

128 字节帧缓冲 `fbuf`（**`buf` 是 Verilog 保留字，不能用作标识符**）。收到完整帧（`rx_eof`）后
判类型：ARP 请求（opcode 1）→ 回 opcode 2，交换 sha/tha、spa/tpa，并把请求方 MAC 学到
`host_mac`；ICMP echo 请求（type 8）→ 回 type 0，原样回 payload。

- **IP 头校验和**用 `function ip_cks(total_len, ident, src, dst)` 组合算；ICMP 校验和在 `S_CKS`
  状态里每拍加 2 字节、折叠后取反。
- 所有帧长比较一律用 `blen`（收到 `rx_eof` 时锁存的长度），不能用还在走的 `bcnt`。
- `tx_hold` 为高（UDP 正在发包）时丢弃本次请求，由主机重试 —— 简单且不会破坏 UDP 时序。

### 1.21 `rtl/eth/scope_udp.v` —— 整窗 UDP 推送（v1.3 新增，B2）

参数 `DEPTH`（32768）、`MAX_PTS`（350，即 1500 B MTU 下的样点数）、`SRC_PORT`（5000）。

- 50 MHz 侧：从 `cap_start` 起按 `n_points` 读抓包缓冲，写进 33 bit 异步 FIFO
  （`{s[15:0], c[15:0]}` + 有效位）。
- 125 MHz 侧：状态 `S_IDLE → S_ARM → S_PRE → S_EMIT → S_DONE`。
- **帧长** `frm_len = 58 + 4*n`（14 ETH + 20 IP + 8 UDP + 16 应用头 + 样点）；
  应用头 = `E7 5A | flags | dec | seq(2) | first(4) | 0(4) | 0(2)`，样点按
  `s 低/高、c 低/高`。
- **首样点下标 `first` 必须累加**（`pkt_first <= pkt_first + pkt_samples`），不能用
  `pkt_seq * MAX_PTS`：乘常数是一条 14 级 `CARRY4` 的长组合链，会把 125 MHz 打穿。
- **末字节**：`tx_valid/tx_data/tx_last` 必须是**组合输出**（`assign tx_valid = (st == S_EMIT)`），
  FSM 只在 `tx_ready` 时推进 `bcnt`；若做成寄存器又在同一拍清零，最后一个字节永远发不出去。
- 4 深前置队列改成"当前字 + 预取字"双缓冲（`cur_word/nxt_word`），避免 push/pop 同拍乱序。

### 1.22 `rtl/eth/eth_top.v` —— 以太网子系统顶层（v1.3 新增，B2）

- **时钟**：`MMCME2_BASE`，`CLKIN1_PERIOD=20.0, DIVCLK_DIVIDE=1, CLKFBOUT_MULT_F=20.0`
  （VCO 1000 MHz）→ `CLKOUT0_DIVIDE_F=8.0` = 125 MHz（GMII）、`CLKOUT1_DIVIDE=5` = 200 MHz
  （给 `IDELAYCTRL` 预留）。各走一个 `BUFG`。
- **复位**：`phy_rst_n` 用 19 位计数器，约 10.5 ms 后释放；`rst_n_125`/`rst_n_rx` 分别两级同步。
- **CDC**：50→125 的配置位（MAC/IP/HOST_IP/PORT/DEC）全部过两级同步；125→50 的 16 bit 计数器
  走**格雷码 + 两级同步**；`udp_done` 单拍脉冲转 toggle 同步后再还原成脉冲并**锁存**
  （`udp_done_sticky`，`udp_start` 清）。
- **仲裁**：ARP/ICMP（`eth_reply`）优先，`rp_tx_valid ? rp : udp` 复用同一个 `eth_tx_mac`；
  `reply_hold = ud_tx_busy`，UDP 发包期间不收 ARP/ICMP。
- **读口复用**：`cap_rd_addr/cap_rd_en = eth_udp_rd_busy ? eth_udp_* : dump_*`（串口 dump 与
  UDP 推送共用 `scope_capture` 的一个读口，靠 `busy` 互斥）。

---

### 1.23 `rtl/eth/stream_tx.v` —— 连续流发送（v1.4 新增，二期）

- **参数**：`DEPTH=28672`（与 `scope_capture` 一致，**非 2 的幂**——回绕必须用
  `rd_ptr == DEPTH_C-1 ? 0 : +1` 的显式比较，不能写 `& (DEPTH-1)`）、
  `MAX_PTS=350`、`SRC_PORT=5000`。
- **50 MHz 侧（追赶读）**：`unread = wr_ptr - rd_ptr`；`overrun = unread > DEPTH/2`
  时整段丢弃——`rd_ptr <= wr_ptr`、`rd_idx <= rd_idx + unread`、`drop_samples += unread`，
  避免把被覆盖的半新半旧样点当成连续波形发出去。
- **跨域**：`async_fifo #(.DW(64), .AW(8), .ALMOST(32))`，每字 `{绝对序号[31:0], rd_data[31:0]}`，
  写完置 `start_tgl`；125 侧 `wr_idx_bin` 走**格雷码 + 两级同步**。
- **125 MHz 侧**：`en` 有效且 `fifo_rd_level >= MAX_PTS + 32` 才开一包（攒够一包再发，
  帧中间不会因为 FIFO 空了而断流）；包格式与 `scope_udp` 完全一致（16 B 应用头 + 4 B/点），
  只有 `flags.bit1 = 1`、首样点序号用满 64 bit。
- **端口**：`clk/rst_n/en/dec_log2/wr_ptr/rd_addr/rd_en/rd_data/drop_samples`（50 MHz）；
  `clk_125/rst_n_125/my_mac/my_ip/host_ip/udp_port/tx_data/tx_valid/tx_last/tx_ready/tx_busy`；
  `pkts[31:0]/fifo_ovf/underflow[31:0]/lag[15:0]`。
- **容量**：读侧 1 样点 / 2 拍 = 25 MSPS 上限 ⇒ **连续流必须抽取 ≥ ×2**；
  50 MSPS 全速需要 1.6 Gbps，超出千兆。
- **已验证的坑**：`S_NEXT` 里若只判 `!fetch` 就发 fetch，会连发两次、多弹出并丢掉一个样点；
  必须写成 `if (!fetch && !rd_v)`（`sim/tb_stream_tx.v` 里 199 项断言覆盖了这一点）。

---

## 2. 顶层 `enc_top.v` 端口（板级）

### 2.1 生产端口（`ENC_DISP_TAP` 未定义时）

定义宏 `ENC_DISP_TAP` 时，端口表末尾**多一个** `output wire [375:0] disp_tap`（v1.1 起；v1.0 是 `[374:0]`，见 2.2）。
生产构建（`tools/synth_check.tcl`、`tools/impl_check.tcl`、交付位流）**不定义**该宏，
所以生产端口清单与本文档以下内容逐字一致。

```verilog
module enc_top (
    input  wire        sys_clk,       // 50 MHz, V4
    input  wire        rst_key_n,     // 复位按键（去抖后作为 rst_n）

    // ---- AD9238 接口（J6 扩展口）----
    output wire        ad_clk,        // 送至模块的采样时钟（CH1_CLK 与 CH2_CLK 同源）
    input  wire [11:0] ad_ch1_d,
    input  wire [11:0] ad_ch2_d,
    input  wire        ad_ch1_otr,
    input  wire        ad_ch2_otr,

    // ---- ABZ / UVW 输出（J6，可选经外部 RS422 驱动器）----
    output wire        a_out, b_out, z_out,
    output wire        u_out, v_out, w_out,

    // ---- BiSS-C 从站 ----
    input  wire        biss_ma,
    input  wire        biss_sl,
    output wire        biss_slo,

    // ---- 配置 SPI（从站）----
    input  wire        spi_sck, spi_ss_n, spi_mosi,
    output wire        spi_miso,

    // ---- 调试 ----
    output wire [3:0]  led,
    output wire        uart_tx,       // 遥测 + UART→SPI 桥应答共用（板载 CH340E RXD，W21）
    input  wire        uart_rx,       // UART→SPI 桥接收脚（板载 CH340E TXD，T20）
    output wire        irq_n
);
```

### 2.2 实验性只读抽头 `disp_tap`（仅 `ENC_DISP_TAP` 构建）

屏 UI 与编码器同片，读数**不走 UART**（`docs/13_display_ui_requirements.md` C2：
遥测余量只有 9.3%）。所以给屏开一条**纯观测**的只读总线。

**硬规矩（三条，违反任何一条都算接口事故）**

1. `ENC_DISP_TAP` **永远不许**出现在生产构建脚本里 —— 唯一合法使用者是
   `tools/synth_disp.tcl`（以及它拉起的 `tools/impl_disp.tcl` / `impl_disp_opt.tcl`）。
   定义它的构建只能用来量时序/资源，**不能出交付位流**。
2. 整个端口（含 `ifdef` 包裹）是"生产构建与 v13 完全一致"的保证：不定义宏时
   `enc_top` 里既无该端口也无该赋值。
3. 总线是**只读快照**，右边只允许出现**已经在寄存器里的既有信号**。绝不要把
   `r_ablimit` 之外的组合中间量（如 `gap_num`、限频比较结果）放进来 —— 那些链
   是全设计最紧的路径。

**位序即契约**（总长 **376 bit**；`[133:0]` 是 v13 原始字段，**一位都没动**，
v14/v15/v21/v22 新增字段一律追加在 `[133]` 以上）：

| 位 | 名称 | 口径 |
|---|---|---|
| `[15:0]` | `angle` | 电角度，0..65535 = 0..360° |
| `[31:16]` | `s_cor` | 校正后 sin（有符号） |
| `[47:32]` | `c_cor` | 校正后 cos（有符号） |
| `[79:48]` | `pos_full` | 全周期位置（32 bit） |
| `[87:80]` | `io_state` | `{limiter_active,dir,w,v,u,z,b,a}` |
| `[95:88]` | `io_flags` | `{amp_bad,cor_sat,uwven,abzen,uvw_warn,z_win,lag_fat,lag_warn}` |
| `[103:96]` | `stat_byte` | 状态字 |
| `[113:104]` | `cfg_inter` | 倍频率（0 视为 256） |
| `[116:114]` | `cfg_div` | 分频率（显示值 = 本值 + 1） |
| `[121:117]` | `cfg_pairs` | 极对数（0 视为 32） |
| `[122]` | `cfg_abzen` | ABZ 使能 |
| `[123]` | `cfg_uwven` | UVW 使能 |
| `[124]` | `calib_busy` | 标定进行中 |
| `[125]` | `calib_done` | 标定完成 |
| `[126]` | `biss_crc_err` | BiSS CRC 错 |
| `[127]` | `otr_lat` | ADC 超量程（锁存） |
| `[128]` | `amp_low \| amp_high` | 幅值越限 |
| `[129]` | `lag_limit \| lag_warn` | 滞后告警 |
| `[130]` | `limiter_active` | AB 限频激活 |
| `[131]` | `z_window` | Z 窗口 |
| `[132]` | `uvw_freq_warn` | UVW 频率告警 |
| `[133]` | `1'b0` | 保留位 |
| `[138:134]` | `cfg_hyst_ab` | **v14** AB 迟滞（`0x0103[4:0]`） |
| `[146:139]` | `cfg_ablimit` | **v14** AB 限频上限（`0x0106`，0..255） |
| `[150:147]` | `cfg_zwidth` | **v14** Z 脉宽（`0x0108[3:0]`） |
| `[162:151]` | `cfg_zphase` | **v14** Z 相位（`0x0109/0x010A`，单位 360/4096） |
| `[178:163]` | `cfg_uvwph` | **v14** UVW 相位（`0x010B`，单位 2^16/周期） |
| `[182:179]` | `cfg_pol` | **v14** `{uvwpol,zpol,bpol,apol}`（`0x010C` 的 bit4/2/1/0） |
| `[198:183]` | `cfg_ofs_s` | **v15** 正弦偏置 Q1.15 有符号（`0x0510/11`） |
| `[214:199]` | `cfg_ofs_c` | **v15** 余弦偏置 Q1.15 有符号（`0x0512/13`） |
| `[230:215]` | `cfg_gain_s` | **v15** 正弦增益 Q1.15 无符号（`0x0514/15`，32768 = 1.0） |
| `[246:231]` | `cfg_gain_c` | **v15** 余弦增益 Q1.15 无符号（`0x0516/17`） |
| `[262:247]` | `cfg_phase_k` | **v15** 正交误差系数 Q1.15 有符号（`0x0518/19`） |
| `[266:263]` | `cfg_shift` | **v15** `{shift_c[1:0], shift_s[1:0]}`（`0x051A[3:0]`） |
| `[278:267]` | — | **v15** 12 bit 填充（`12'b0`），使 `cfg_shift` 对齐到一个 16 bit 字 |
| `[310:279]` | `stat_amp_sq` | **v15** 实测 `s²+c²` Q2.30（`0x0530..0x0533`，只读） |
| `[342:311]` | `cfg_amp_low_sq` | **v21** 幅值下限平方 Q2.30（`0x0520..0x0523`，默认 `(0.60)²·2³⁰`） |
| `[374:343]` | `cfg_amp_high_sq` | **v21** 幅值上限平方 Q2.30（`0x0524..0x0527`，默认 `(1.20)²·2³⁰`） |
| `[375]` | `biss_link_lost` | **v22** BiSS 链路静默（`ma` 连续 2 ms 无边沿 @50 MHz；非粘滞，见 §1.10） |

**为什么 v14 要扩总线**：P6 设置页按 `docs/13_display_ui_requirements.md` §4.4
要显示 9 个**寄存器当前值**（倍频/分频/极对数/迟滞/限幅/Z 脉宽/Z 相位/UVW 相位/极性），
而 v13 的抽头只带了前三个 —— 剩下六个在屏上只能是复位默认值的静态文本，
"实时回读"就名不副实。六个字段全部是 `reg_file.v` 的 `cfg_*` 既有输出（reg 直出），
加进来的代价只是每根 net 多 **1 个负载**（屏侧的输入寄存器）。

**为什么 v15 要再扩一次**：P7"标定与误差可视化"按 §4.4 要显示**标定六参数当前值**
（正弦/余弦偏置、正弦/余弦增益、正交误差系数、粗调移位）与实测幅值 `s²+c²`。
这七个量**在 `reg_file.v` 里早就是既有端口**（`cfg_ofs_s/c`、`cfg_gain_s/c`、
`cfg_phase_k`、`cfg_shift_s/c` 是输出，`stat_amp_sq` 是输入，即 `enc_top.v` 里的 `amp_sq`），
所以 v15 **没有新增任何寄存器，也没有改 `reg_file.v`** —— 只是把已有的线接到抽头上。
注意这与 §7 Q5 记载的"标定前后对比需要新增 `0x0540+` 误差记录寄存器区"是两件事：
本版只抽**当前值**，不做历史记录；"标定前/后两条曲线"由**屏侧**在 `calib_busy`
翻转前后各记一组分箱统计得到，不需要编码器侧新增存储。

屏侧的唯一消费者是 `disp/enc_disp_tap.v`（纯连线，把总线拆成具名端口）。

**为什么 v21 要再扩一次（375 bit）**：P7 的"幅值"一行按 §4.4 与 §7 要显示**百分比**，
而百分比的口径只能是"实测 `s²+c²` 落在编码器自己的两个幅值门限之间什么位置"——
分母必须是 `0x0520`（下限）与 `0x0524`（上限）这两个**已在寄存器里的**门限值。
v15 只抽了实测值 `stat_amp_sq`，没有门限，屏侧就只剩"另写一个额定值当分母"这条路，
那样屏上百分比与 `amp_monitor` 的告警判据会对不上（同一个数在两个地方两种含义）。
两个字段都是 `reg_file.v` 的既有 `cfg_*` 输出（reg 直出，与 v14/v15 同一性质），
`enc_top.v` 里早已有 `wire [31:0] cfg_amp_low_sq / cfg_amp_high_sq` 并喂给 `amp_monitor`
（`rtl/enc_top.v:473`、`:1004-1005`），所以 v21 **同样没有新增寄存器、没有改 `reg_file.v`**，
代价仍是每根 net 多 1 个负载；`[310:0]` 一位没动，追加在最高位。

**为什么 v22 要再扩一次（376 bit）**：屏上的空态判据（`docs/13_display_ui_requirements.md`
§7 反模式 8）到 v21 为止只覆盖"帧来了但校验没过"（`[126]`）与"载波没了"（幅值低于下限）。
**主机停止打时钟**这种纯链路静默两者都不成立：`crc_err_seen` 不置位、幅值可能还停在
窗口内（ADC 采到的是残余/直流）⇒ 屏上继续用尸体读数画"● 正常 + 0.00 Hz"。
这一侧**不改 rtl/ 就观测不到**（`frame_cnt` 是帧内位数、`frame_active` 在帧间本来
就是 0，都分不出"帧间空闲"与"主机停了"），所以 v22 在 `biss_c_slave` 里加了非粘滞的
链路心跳 `link_lost`（§1.10），并把它作为 `[375]` 追加在抽头最高位。

---

## 3. 交付要求（每个模块）

1. `rtl/<module>.v`：可综合 RTL，模块头注释包含：功能、Latency、资源估计（DSP/LUT/FF）、关键假设。
2. `sim/tb_<module>.v`：**自检测试台**，使用 `$display` 打印 `TEST PASSED` / `TEST FAILED`（便于在 Vivado xsim 里 `run all` 后一眼判断），并覆盖至少：正常路径、边界值、复位、饱和/溢出。
3. 不允许在 RTL 里使用 `$display`（只在 testbench 里用）。
4. 每个模块的常量、移位量必须用 `localparam` 或 `parameter`，不允许魔法数字散落。
5. 文件保存为 UTF-8（无 BOM）。

## 4. 已知的本机限制（必须遵守）

- 本机**没有**安装任何 Verilog 仿真器（无 Vivado / xsim / iverilog / verilator）。
- 因此：**不能**声称"已通过仿真"；只能写"已按契约编写，待 Vivado xsim 验证"，除非你用 Python/numpy 对算法做了等价定点建模并给出实测数字。
- `model/*.py` 中的 Python 定点模型，必须与 RTL 的定点语义（位宽、移位方向、截断方式、饱和）**逐位一致**，并输出可复现的数字结论。

> **勘误（v1.1 备注，2026-10-18）**：上面第 1、2 条是 v1.0 时期的陈述，**早已不成立**。
> 本仓库现在有两套 xsim 自检台：编码器侧 `sim/tb_*.v`（入口 `tools/run_sim.ps1`）与
> 显示侧 `disp/tb_*.v`（入口 `python tools/run_sim_disp.py`），两者都是"自检 + 打印
> `TEST PASSED`"形态。本节保留原文只为留下历史，实际纪律以各轮 `docs/DEV_STATUS.md`
> 的"验证"小节为准。

---

## 5. 变更记录

### v1.4（2026-10-19，二期连续流）

**新增文件**

- `rtl/eth/stream_tx.v`（§1.23）：追赶读 + 异步 FIFO + 125 MHz 连续组包。

**端口/行为变更**

- `rtl/scope_capture.v`：新增 `input stream, input [2:0] stream_dec`、
  `output reg [15:0] wr_ptr, output reg [31:0] strm_cnt, output reg st_stream`。
  `stream=1` 时抽取比来自 `stream_dec`（否则来自 `dec_log2`），`wr_ptr` 每写入一点 +1
  （连续流模式下写指针对同一幅图像的翻转是合法的），`strm_cnt` 记录写入总数。
- `rtl/cap_regs.v`：新增 0x0740 段（`STREAM_CTRL/DEC/STATUS/PKTS/DROP/LAG`，见 `docs/18` §2.2）。
- `rtl/eth/eth_top.v`：新增连续流端口，TX 仲裁改三路（ARP/ICMP > 连续流 > 抓包 UDP），
  `reply_hold = udp_busy | stream_busy`。
- `rtl/enc_top.v`：读口仲裁优先级 **连续流 > 抓包 UDP > 串口 dump**；`stream_en` 的上升/下降沿
  产生 `arm/abort` 脉冲送 `scope_capture`。

**为什么读口要按这个优先级**：连续流的读侧必须持续跟得上写侧，一旦被 dump 插进来几百毫秒，
追赶读就会整段丢弃（用户看到的是"波形断了"）；而 dump 与抓包 UDP 都是请求-响应，晚一点没人察觉。

**验证**：`sim/tb_stream_tx.v` 199 checks PASS（包序、64 bit 序号、样点字节序、落后丢弃计数）；
`host/selftest_stream.py` 29 checks PASS（解析/归位/丢包统计/环形缓冲/socket 回环）；
`host/selftest_stream_ui.py` 7 checks PASS（定时器 → 快照 → 出图链路）；
实现 **WNS +0.101 / WHS +0.028，0 failing endpoints**，LUT 47.42%、BRAM Tile 34/50，
位流 `deliverables/data/bitstreams/enc_top_b3_stream_2026-10-19.bit`。

### v1.3（2026-10-18，B2 以太网通道：RGMII + ARP/ICMP + UDP 推送）

**接口新增（新增一个时钟域 `eth_rxc`，新增 15 根板级引脚）**

1. `enc_top`（§2.1）新增以太网端口：`phy_rst_n`(V18)、`eth_txd[3:0]`(U17/U18/P14/R14)、
   `eth_txc`(AA18)、`eth_tx_ctl`(AB18)、`eth_rxd[3:0]`(AA19/AB20/V17/W17)、`eth_rxc`(Y18)、
   `eth_rx_ctl`(V19)，全部 LVCMOS33（Bank 14）。
2. 新增 `rtl/eth/` 七个模块：`async_fifo`（§1.17）、`rgmii_if`（§1.18）、`eth_tx_mac`/`eth_rx_mac`
   （§1.19）、`eth_reply`（§1.20）、`scope_udp`（§1.21）、`eth_top`（§1.22）。
3. `cap_regs`（§1.14）新增 0x0736 `UDP_CTRL`、0x0738 `UDP_STATUS`、0x073A `UDP_PKTS`、
   0x073C `UDP_DROP`，并输出 `eth_mac/eth_ip/eth_host_ip/eth_port/eth_ctrl`。
4. `scope_capture` 的读口与 `scope_dump` 共用，由 `eth_top` 按 `busy` 二选一。

**行为变更**

- 串口链路**完全不变**：遥测 18 B 帧、寄存器读写、`AA 55 A2 10` dump 块都照旧。以太网是
  **并行的第二条数据通道**，两条互不干扰（用户明确要求的"双方案"）。
- 以太网只在抓包完成后推一次窗（`UDP_CTRL.bit0` 触发），不做连续流 —— 连续流受
  千兆 ~950 Mbps 上限限制（双通道 50 MSPS × 12 bit × 2 = 1.2 Gbps），见 `docs/17`。

**已知限制（上板前必须知道）**

- 必须协商到 **1000 Mbps**；10/100 Mbps 下 RGMII 时序不同，本版不支持。
- 不做 MDIO：PHY 用默认配置（自协商、RGMII 延时由 PHY 内部提供）。
- 时序：实现后 **WNS +0.167 ns / WHS +0.058 ns，0 failing endpoints**（2026-10-19 00:14，
  `write_bitstream` 成功，DRC 0 错误，1,439,208 B）。RGMII RX 输入延时按 `-min 3.6 / -max 4.5`
  建模（YT8531C 内部延时约 1.5–2 ns 的经验值），**上板必须用 IDELAY 抽头 + 实测替换**；
  换成实测值之前，这条约束只是"能让工具收敛"的假设，不代表真实板级裕量。

**验证**：`sim/tb_eth_udp.v`（58 条判据：异步 FIFO 顺序、UDP 分包/应用头/样点字节序、
以太网帧前导码+CRC32、ARP 应答字段与 `host_mac` 学习）；`host/selftest_udp.py`（26 条判据：
包解析、seq 归位、缺包标记、无包报错、假串口端到端）。

### v1.2（2026-10-18，B1 抓包通道：0x0700 段 + UART dump）

**接口新增（不改变任何板级引脚、不新增时钟域）**

1. `reg_file`（§1.11）新增扩展总线 `ext_we/ext_addr/ext_wdata/ext_rdata`：`addr[15:8]==0x07`
   的读写整段转给 `cap_regs`，读 `default` 分支回填 `ext_rdata`。其余 0x00xx–0x06xx 行为不变。
2. 新增 `cap_regs`（§1.14）、`scope_capture`（§1.15）、`scope_dump`（§1.16）。
3. `uart_spi_bridge`（§1.12）新增输入 `dump_tx`、`dump_busy`：`dump_busy` 期间遥测被
   `scope_hold` 挡住，`tx` 切到 `dump_tx`。
4. `RTL_BUILD_ID` 0x000C → **0x000D**（`0x05F2` 读回、`0x072C BUILD` 读回一致）。

**为什么升版本号**：新增了一整段 0x07xx 寄存器与一条新的 UART 块格式（`AA 55 A2 10`），
两者都是上位机/工具要按书面契约解析的东西；版本号不动会让后续的人按旧表解包。

**验证**：`sim/tb_scope_chain.v`（57 条判据，含"写进去的样本 == 从 UART 线上解出来的样本"
逐点比对、触发/预触发窗口、抽取 2、块尾 XOR）；`sim/tb_uart_spi_bridge.v` 补 `dump_*` 空连接；
`tb_reg_file`/`tb_spi_slave`/`tb_enc_top` 回归通过。

### v1.1（2026-10-18，U-55 批次 C3+C4）

**接口新增（三处，都会影响所有例化点）**

1. `biss_c_slave`（§1.10）新增输入 `crc_err_clr` 与输出 `link_lost`，新增参数
   `LINK_LOST_CYCLES`（默认 100000 = **2 ms** @50 MHz）。
2. `reg_file`（§1.11）新增输出 `clr_biss_crc`（与 `clr_otr` 同语义、同拍、同源）。
3. `enc_top.disp_tap` 由 **375 bit 扩到 376 bit**，新增 `[375] biss_link_lost`（§2.2）；
   屏侧 `disp/enc_disp_tap.v` 端口同步加 `biss_link_lost`。

**行为变更**

- `0x0405 STAT_LATCH` 写 bit0 现在会**同时**清两个粘滞器（ADC OTR 与 BiSS `crc_err_seen`）。
  寄存器可见行为不变（写入仍是 W1C），变化在屏上："清除锁存故障"按下去之后屏上
  能真的退出空态。
- 显示侧 `sig_bad` 从 `crc_err | amp_gone` 变成 `crc_err | amp_gone | link_lost`，
  空态覆盖"没有数据"的三种形态（帧校验失败 / 没有载波 / 主机不打时钟）。

**为什么升版本号而不是当成实现细节**：位序表是屏侧与编码器之间唯一的书面契约，
总长变了（375 → 376）而版本号不动，等于让下一轮的人按旧表解包；`disp/enc_disp_tap.v`
头注释也写着"一旦这里出现逻辑就说明有人改了观测口径，必须同步改契约"。

**验证（本版随代码一起提交）**：`sim/tb_biss_c_slave.v` 新增 link_lost / crc_err_clr
两组判据（含同拍置位优先）；`disp/tb_disp_engine.v` 新增 §[21]（链路静默 ⇒ 四张测量卡
空态 + 数值 `-`，且 link_lost=0 时读数照常）；两套台 + `tools/lint_all.ps1` + smoke
全部通过，详见 `docs/DEV_STATUS.md` 的 U-55 段。

**勘误（v1.1 errata 1，2026-10-19，U-56）**

v1.1 的 `link_lost` 段把 `LINK_LOST_CYCLES = 100000` 描述成"1 ms @100 MHz"。实测板级
`sys_clk` 周期是 **20 ns（50 MHz）**（`constr/enc_top_disp.xdc` 的 `create_clock`；屏幕
PCLK 也直接取 `sys_clk`），因此 100,000 拍 = **2 ms**。**接口与常数都没变**（不改行为），
只纠正文档里的时间口径；同理 §1.10 的 `TIMEOUT_CYCLES = 10` 是 200 ns 而不是 100 ns，
`ma` 上限是 6.25 MHz（保守 5 MHz）而不是 10 MHz。

### v1.5（2026-10-22，上板调试寄存器）

**新增寄存器（0x0750 段）**

| 地址 | 名称 | 读写 | 含义 |
|------|------|------|------|
| 0x0750 | RX_CLK_CNT | R | eth_rxc 域周期计数（每拍 +1，16 bit 回绕） |
| 0x0752 | RX_DV_CNT | R | 收到帧数（RX_DV 上升沿计数） |
| 0x0754 | RX_BYTE_CNT | R | RX_DV 期间的字节计数 |
| 0x0756 | RX_ERR_CNT | R | 错误帧数（CRC 错/短帧） |
| 0x0758 | IDELAY_STAT | R/W | 读 `{9'd0, rx_swap, idelay_rdy, idelay_val[4:0]}`；写 bit0..4 = IDELAY 抽头，bit6 = RGMII 半字节交换（调试用） |
| 0x075A | RX_DBG5_6 | R | 最近一帧第 5/6 字节 |
| 0x075C | RX_DBG7_8 | R | 最近一帧第 7/8 字节 |

**行为变更**

- `rtl/eth/rgmii_if.v`：RGMII RX 改为 BUFIO 采样 + 5×IDELAYE2（`VAR_LOAD`、
  `IODELAY_GROUP="rgmii_rx"`）+ IDELAYCTRL（REFCLK=`clk_200`），新增
  `idelay_val[4:0] / idelay_ld / idelay_rdy`，`rx_swap` 仅作调试。
- `rtl/eth/stream_tx.v`：`MAX_PTS` 350 → 200。异步 FIFO `AW=8`（256 深），
  启动判据是 `fifo_rd_level >= MAX_PTS + 32`；350+32=382 > 256 时 `start_ok`
  永远不成立（上板表现为流开着但 `pkts=0`、`drop` 疯涨）。200+32=232 ≤ 256。
- `constr/enc_top_eth.xdc`：RGMII 引脚按厂商口径修正 —— `eth_rxd[0..3] =
  W17/V17/AB20/AA19`、`eth_txd[0..3] = R14/P14/U18/U17`；RX input delay
  `-max 2.300 / -min 1.700`（YT8531C 内部延时 2.0±0.3）。

**验证**：`sim/tb_icmp_reply.v` 48 checks PASS（ICMP 应答逐字节 + IP/ICMP
校验和）；上板 `ping` 10/10、UDP 抓包 82/82 包（28,672 点）、串口 dump
448 块 0.66 s。


### v1.6（2026-10-22）连续流调试口

| 地址 | 名称 | 说明 |
|------|------|------|
| 0x0760 | TX_DBG_FRM | 上一帧总字节数（含 MAC 头，不含 FCS） |
| 0x0762 | TX_DBG_IPLEN | 线上 IP 总长字段 |
| 0x0764 | TX_DBG_PORT | 线上 UDP **源**端口（头字节 34/35） |
| 0x0766/0x0768 | TX_DBG_MAC | 线上目的 MAC 高/低 16 位 |
| 0x076A | TX_DBG_IPCK | 线上 IP 头校验和 |
| 0x076C/0x076E | TX_DBG_DIP | 线上目的 IP 高/低 16 位 |

每帧结束时更新一次，2 拍同步到 50 MHz；用于离线判断“主机收不到”是哪个字段的问题。

**v1.6 补充（同日上板复测）**

- `rtl/eth/stream_tx.v` 的 UDP 源/目的端口原来写反：34/35 应放 `SRC_PORT`（5000）、
  36/37 应放 `udp_port`。写反的后果是流包全部发到主机 5000（被 `lkcitdl` 占用），
  主机自己的 socket 收不到；`pktmon` 实证 `192.168.1.10.47234 > 192.168.1.100.5000`。
- `rtl/eth/stream_tx.v` 改成整包缓冲（`pbuf[0:MAX_PTS-1]`）后连续发送，帧内
  `tx_valid` 不再断流；线上帧长回到 **858 B**、与 IP 总长一致。
- 验收：连续流 30 s，板端 1,875,512 包、`drop` 0、`lag` 0，主机收 1,874,985 包（99.97%）。
  `sim/tb_stream_tx.v` 260 checks（含 `no_tx_gap_in_frame` 与源/目的端口逐字节校验）。
