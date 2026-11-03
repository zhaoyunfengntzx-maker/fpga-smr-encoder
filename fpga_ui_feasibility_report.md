# 在 XC7A35T（225 KB BRAM、无帧缓存）上实现实时监控 UI 的工程可行性报告

目标平台：正点原子 达芬奇-lite / Xilinx Artix-7 **XC7A35TFGG484-2**
资源：20,800 LUT6 / 41,600 FF / 90 DSP48E1 / **50 × RAMB36（=100 RAMB18）= 1800 Kb = 225 KB** / 5 CMT（5 MMCM + 5 PLL）
外设：256 MB DDR3（NT5CC128M16JR，x16，400 MHz 时钟 / 800 Mbps）、16 MB QSPI、7" 1024×600 RGB888 屏（ATK-7016，GT911 电容触摸 / I2C）、自写 Verilog 时序产生器（像素时钟 ≈51.2 MHz）。

---

## 0. 先算清楚基线数字（后面所有结论都基于此）

| 量 | 值 | 来源/推导 |
|---|---|---|
| 像素率 | 1024×600×59.99 Hz = **36.86 Mpixel/s** | 由 51.2 MHz 像素时钟推得（见下） |
| 行/帧总像素 | H_total 1344 × V_total 635 = **853,440 clk/frame** | 51.2e6 / 853440 = **59.99 Hz**，与你给的 ≈51.2 MHz/59 Hz 完全自洽 |
| 有效像素占比 | 614,400 / 853,440 = **72.0%** → 消隐占 **28.0%** | 推导值 |
| 每帧消隐时钟预算 | **239,040 clk ≈ 4.67 ms** | 这是你的"免费算力" |
| 每有效像素预算 | 51.2 MHz → **19.53 ns**（1 clk/pixel） | 必须 1 pixel/clk，不能停顿 |
| 一个 24bpp 全屏帧 | 1,843,200 B | 1024×600×3 |
| RGB565 全屏帧 | 1,228,800 B | |
| 8bpp 索引全屏帧 | 614,400 B | |
| BRAM 总容量 | 225 KB = 50 × 4608 B | RAMB36 = 36 Kb = 4608 B |

> ⚠️ **不确定项**：1344×635 这组消隐参数是我从你给的 51.2 MHz / 59 Hz 反推的，不是查到的原厂值。
> 正点原子 1024×600 RGB LCD 教程常用的组合是 HSW/HBP/HFP = 20/140/160、VSW/VBP/VFP = 3/20/12，
> 正好得到 1344×635 与 59.99 Hz，但请以你自己的 `scanout_timing.v` 参数为准。

**结论 0（贯穿全文）**：全屏 8bpp 帧缓存需要 **614,400 B ≈ 133 个 RAMB36**，是全片 50 个的 **2.67 倍**；
RGB565 需要 267 个（5.3 倍）。**板载 BRAM 不够做任何全屏帧缓存，这一条没有商量余地。**
但"完整 UI"并不需要全屏帧缓存——下面是量化证明。

---

## 1. 四种架构的定量对比

### (a) 全程序化 / 逐像素实时生成（registered pipeline）

**成本**
- 帧缓存 BRAM：**0**。仅需字库 ROM 1–2 tile。
- LUT：区域译码每矩形 ≈ 4 个 10bit 量值比较器 ≈ **12–15 LUT**；24 个区域 ≈ 290 LUT，加优先级 mux ≈ 120 LUT；
  文本通路 ≈ 90 LUT；调色/合成 ≈ 60 LUT。
  → 纯形状版 **≈ 800–1,500 LUT**；带文本 + 2 条曲线平面 **≈ 2,000–3,500 LUT**（占 20,800 的 10–17%）。
- FF：4–8 级流水 × 40–56 bit/stage ≈ **300–450 FF**。
- DSP：**0**。若加圆形表盘/指针，(x−cx)²+(y−cy)²<r² 需 2–4 个 DSP48，或用增量平方和累加器省掉。

**视觉能力边界（关键）**：只能画"能用廉价的 f(x,y) 谓词表达"的图形——
矩形、进度条、刻度、网格、环形、任意多边形凹槽（用半平面交集）、点阵文本。
**画不出任意折线、任意填充多边形、任意字形**——因为折线不是 (x,y) 的廉价谓词。这正是必须有"平面"的原因。

**延迟**：1 pixel/clk，流水线延迟 3–8 clk = **60–160 ns**（完全不可见；把 hsync/vsync 延迟同样级数即可对齐）。
**复杂度**：低。**风险**：低。
**判断**：**这是必须的地基，但单独用不够**（画不了波形和 Lissajous）。

### (b) 局部/分块帧缓存（BRAM 位平面）

按区域开一块像素缓冲，而不是全屏。以 8bpp 为例：

| 区域 | 字节 | RAMB36 tile | 占全片 |
|---|---|---|---|
| 512×300×8bpp | 153,600 | **33.3** | 67% ❌ |
| 1024×150×8bpp | 153,600 | 33.3 | 67% ❌ |
| 512×300×4bpp | 76,800 | 16.7 | 33% ⚠️ |
| 512×256×4bpp | 65,536 | 14.2 | 28% ⚠️ |
| 512×300×1bpp | 19,200 | 4.2 | 8% ✅ |
| 1024×300×1bpp | 38,400 | 8.3 | 17% ✅ |
| 512×512×1bpp | 32,768 | 7.1 | 14% ✅ |
| 512×512×2bpp | 65,536 | 14.2 | 28% ✅ |

**8bpp 位图在 225 KB 上是奢侈品**：512×300 就要吃掉 2/3 的 BRAM。
**正确做法：1bpp 位平面 + 平面颜色寄存器**（Amiga/SAGA "bitplane" 模型）——
颜色来自小调色板而不是帧缓存，同样面积的成本降到 1/8。

**读侧带宽**：位平面按 X 方向、32bit 字存储：`addr = row × (W/32) + (x>>5)`，
每 32 个像素读 1 次 BRAM。36.86 Mpixel/s ÷ 32 = **1.15 M 次读/s**，
单端口 51.2 MHz 的占用率仅 **2.3%**。读侧几乎免费。
**写侧**（栅格化）才是真工作量，见第 3 节。

**复杂度**：中（需要地址产生 + 填充/光栅器 + 双端口仲裁）。**风险**：低–中。
**判断**：**只给真正需要位图自由的区域用，而且用 1bpp** ——即 **Lissajous/X-Y 图**（唯一 X 非单调的图）。

### (c) DDR3 全帧缓存（Xilinx MIG）

**容量**：全屏 RGB888 = 1.84 MB，RGB565 = 1.23 MB，8bpp = 614 KB —— 256 MB 里随便放。
**BRAM 成本**：帧缓存本身 0，但 **读前推 FIFO / 行缓冲需要 2–4 tile**，MIG 内部 FIFO 再占 1–2 tile。
**LUT 成本**：MIG 7 Series 16-bit DDR3（PHY + MC + native UI）量级约 **2,000–3,500 LUT、2,000–3,000 FF**
（占 20,800 LUT 的 10–17%）。
> ⚠️ 本次会话中 UG586（mig_7series v4.1）PDF 与 AMD 产品页均无法取回（403 / 连接失败），
> **这个数字是量级估计，不是查到的表格值**。请以 Vivado 生成核后的 utilization report 为准。

**带宽核算**：DDR3-800 × 16bit = 800 MT/s × 2 B = **1,600 MB/s 理论**；
简单 native UI + 刷新开销，实测经验 **55–70% → 0.9–1.1 GB/s**。
显示读 110.6 MB/s（RGB888）+ 渲染回写 110.6 MB/s + 画线的读改写 → 总需求 300–450 MB/s。
**带宽完全够**——所以 DDR3 的问题从来不是带宽，是**校准和实时性**。

**延迟**：至少 1 帧（16.7 ms）。渲染进后缓冲再交换则再加 1 帧；直接渲染可见缓冲会撕裂。
**复杂度**：**高**。**风险**：**高**——MIG 校准是整个项目最大的进度风险（见第 6 节）。
**判断**：**仅为 UI 不值得。** 只有当你以后要"长采集样本存储 + 图像回放"时才值得引入。

### (d) 混合架构（**推荐**）

> 程序化背景/网格/仪表 + **1bpp 位平面**给自由曲线 + **字库 ROM + 字符单元缓冲**给文本 +
> **Copper 式逐行参数表**让同一个合成器每行换颜色/换页。

**BRAM 预算（两档）**

| 模块 | bit | RAMB36 |
|---|---|---|
| 字库 8×16 / 256 字形 / 1bpp | 32,768 | 1 |
| 大号数字字库 16×32 / 96 字形 / 1bpp | 49,152 | 1.5 |
| 中文/图标 16×16 / 256 字形 / 1bpp | 65,536 | 1.8 |
| 字符单元缓冲 128×37×1B（颜色走 Copper） | 37,888 | 1 |
| 时域包络（2ch × 1024列 × (ymin,ymax) × 12bit） | 49,152 | 1.4 |
| 逻辑时序列状态（1024列 × 6bit + 历史） | 12,288 | 0.5 |
| XY 位平面 512×512×1bpp | 262,144 | 7.1 |
| （可选）XY 位平面第二块（双缓冲/余辉） | 262,144 | 7.1 |
| ADC 环形缓冲 2ch × 4096 × 12bit | 98,304 | 2.7 |
| 数字通道环形缓冲 6ch × 4096 × 6bit | 147,456 | 4.0 |
| 行缓冲/FIFO/暂存 | 73,728 | 2.0 |
| **合计** | | **≈ 30（精简）/ ≈ 37（豪华）** |

- **精简档 ≈ 30/50 tile**：XY 用 256×256（1.8 tile），其余同上 → **≈ 24/50 tile**。
- **豪华档 ≈ 37/50 tile**：含双缓冲 XY 与 4096 深度双通道采集环。

**LUT 估算**：区域译码 ≈ 410 + Copper ≈ 30 + 文本引擎 ≈ 120 + 包络绘图 ≈ 60 + 逻辑绘图 ≈ 54 + 位平面读 ≈ 60 +
调色/合成/输出流水 ≈ 150 + 采集前端 ≈ 200 + 二→BCD→ASCII ≈ 250 + 触摸 I²C + 命中测试 ≈ 300
→ **UI 引擎 ≈ 2,150 LUT、≈ 1,000 FF、0–8 DSP**。剩下 **≈ 17,000 LUT 全部留给你的测量逻辑**。

**延迟**：1 pixel/clk，3–6 级流水。**复杂度**：中，但**可增量交付**。
**风险**：**低**。
**判断：这是答案。** 可以先只做程序化 + 文本上线第 1 页，之后每个图作为独立模块挂到同一个合成器后面，互不影响。

### 对比速查表

| | BRAM | LUT | 视觉丰富度 | 延迟 | 复杂度 | 风险 |
|---|---|---|---|---|---|---|
| (a) 纯程序化 | 1–2 tile | 0.8–3.5 K | 矩形/条/环/文本，画不了任意折线 | 3–8 clk | 低 | 低 |
| (b) 局部位图 8bpp | 14–33 tile | +0.5 K | 区域内完全自由 | 0（读侧） | 中 | 低-中 |
| (b') 局部位图 1bpp | **4–8 tile** | +0.5 K | 区域内自由，颜色走调色板 | 0 | 中 | 低-中 |
| (c) DDR3 全帧缓存 | 3–6 tile + MIG | +2.0–3.5 K | 无限制 | ≥1 帧 | **高** | **高** |
| (d) 混合 | **24–37 tile** | 2.2 K | 足够做完整监控 UI + 三类图 | 3–6 clk | 中 | **低** |

---

## 2. 无帧缓存怎么画文本（真实工程做法）

### 标准数据通路
```
x[9:0], y[9:0]  (像素计数)
  col = x[9:3]           // 8×16 字形
  row = y[9:4]
  char_code = cell_ram[row*MAX_COLS + col]     // BRAM 读
  glyph_addr = char_code*16 + y[3:0]
  glyph_row  = font_rom[glyph_addr]            // BRAM 读，8 bit
  shift_reg <= glyph_row                       // 每字符单元装载一次
  pixel_bit <= shift_reg[7]                    // 每像素右移一位
  color <= pixel_bit ? fg : bg
```

### 关键优化（把 BRAM 读从 2 次/像素降到 2 次/8 像素）
1. **单元边界装载**：只在 `x[2:0]==0` 时读 `cell_ram`，把 `char_code` 寄存在寄存器里保持 8 个像素。
2. **每字符行只读一次字库**：`glyph_addr` 由寄存的 `char_code` 算，`y[3:0]` 一整行不变，
   所以 `font_rom` 读结果可以整行复用（或仅在 `x[2:0]==0` 时读一次）。
3. 结果：**2 次 BRAM 读 / 8 像素 = 0.25 次/像素**。36.86 Mpixel/s × 0.25 = **9.2 M 读/s**，
   单端口 51.2 MHz 的 **18%**。完全不是瓶颈。
4. `char_code*16` 是一个乘法——**必须在像素路径外预先算好或打进流水线**，不要组合逻辑现算。

### 颜色属性：两种做法，差 8 倍
- 做法 A（贵）：第二块属性平面，每单元多一个字节 → 单元缓冲翻倍，每单元多一次 BRAM 读。
- 做法 B（**推荐**）：**Copper 式逐行前景色寄存器**——Copper 表在每行起始时更新 `fg`/`bg`。
  0 额外 BRAM，且这正是 Amiga/Atari/街机文本的做法。监控 UI 每行一种颜色，绰绰有余。

### 每字形 BRAM 成本（1bpp）
`字节数 = 字形数 × 高度 × ceil(宽度/8) × bpp`

| 字形规格 | 96 字形 | 256 字形 |
|---|---|---|
| 5×7 | 672 B | 1,792 B |
| 8×8 | 768 B | 2,048 B |
| **8×16** | **1,536 B** | **4,096 B** |
| 8×16 4bpp 抗锯齿 | 6,144 B | 16,384 B |
| 16×32 | 6,144 B | 16,384 B |
| 24×32 | 9,216 B | 24,576 B |
| 16×16 中文/图标（1bpp, 32 B/字） | 3,072 B | 8,192 B |

### 字符单元容量（225 KB 全用来放 8×16 1bpp 文本平面的话）
- 225 × 1024 / 16 = **14,400 个字符单元** ≈ 3 屏 128×37。
- 实际屏幕规格：8×16 → **128 列 × 37 行 = 4,736 单元**；16×32 → **64 × 18 = 1,152 单元**。
- 一个 1 字节/单元的 128×37 单元缓冲 = **4,736 B = 1.03 tile**。
  → **文本的 BRAM 成本基本上可以忽略。**

### 实用配方（本项目的具体建议）
- 标签/菜单：**8×16，256 字形，1bpp** → 1 tile。
- 大号数字读数（RPM/频率/角度/计数）：**16×32 或 24×48 点阵数字**，只需 16 个字形
  （`0-9 . - + : % 空格`）→ 16×64 B = **1,024 B = 0.22 tile** ← 极其便宜。
- 中文标签：**16×16 CJK，1bpp，32 B/字**。500 个汉字 = 16,000 B = **3.5 tile**。中文 UI 完全可行。
- 抗锯齿：4bpp 字库成本 ×4（8×16/96 字形 = 6,144 B ≈ 1.3 tile），
  在像素路径上只是把 1 bit 换成 4 bit 去索引 16 色调色板，逻辑几乎不增加。**值得做**，小字号观感提升明显。
- 另一种选择：把字库放进 **LUT**（`case` 语句，96×16 = 1,536 bit ≈ 256 个 LUT6）。
  参考 [naelolaiz/learning_fpga 的 font_rom.v](https://github.com/naelolaiz/learning_fpga/blob/master/display/vga/text_generator/font_rom.v)
  是一个现成可抄的 Verilog 字库 ROM。**但在你这个规模上没必要省这点 BRAM，用 BRAM 更省 LUT。**

---

## 3. 无帧缓存怎么画波形/图（核心难题与标准技巧）

### 3.1 难题的本质
扫描流水线按 (x 递增, y 递增) 走，每个时钟必须当场给出 (x,y) 的颜色。
但折线需要"上一个采样点"，而且一条线段的像素分布在多个 x 上。
**Bresenham 本质上是沿线段顺序推进的状态机，与扫描顺序不兼容。**

### 3.2 标准技巧（按推荐优先级）

**技巧 1：先栅格化进位平面，扫描时只做查表。**
把"光栅化"和"扫描输出"彻底解耦。可见时段是纯查表（1 BRAM 读 / 32 像素），
光栅化在消隐期或 BRAM 第二端口做。**几乎所有真实设计都这么做。**

**技巧 2：逐列 min/max 包络（时域图的正确答案）**
时域波形是 x 的**函数**（单调），所以可以按显示列 x 预先归约：
```
lo(x) = min(ymin[x], ymin[x-1])
hi(x) = max(ymax[x], ymax[x-1])      // 跨列合并，覆盖两列间的连接段
```
像素时刻的判据就是 `lo(x) <= y <= hi(x)` —— **2 个比较器，零历史状态，完全流水，1 pixel/clk**。
**这直接消灭了"需要上一个采样"的问题。** 这也是音频波形显示和 DSO 包络显示的标准做法。
- 存储：1024 列 × (ymin,ymax) × 12 bit = **24,576 bit ≈ 0.67 tile / 每通道**。
- 代价：极度缩小时丢失列内细节（无法避免）；要保留过冲毛刺需用 min/max 语义而非首/末样本。
- **MIT 6.111 的 FPGA-Scope 报告里明确记录了这点**：点绘（"area unfilled"）对低频连续信号表现好，
  但"对高频或非连续信号（如方波）"就不行 —— 即 min/max 包络 vs 点绘的取舍
  （[klinke_Project_Final_Report.pdf](https://web.mit.edu/6.111/www/f2011/projects/klinke_Project_Final_Report.pdf)）。

**技巧 3：数字时序图的逐列状态（同理）**
每个信道是时间的阶跃函数。每列存 6 bit 总线值：**1024 × 6 bit = 6,144 bit = 0.17 tile**。
像素时刻把该列的 bit 与该通道的行带比较；值发生变化的列画一根竖直跳变条。
当前列和前一列的值放寄存器（12 FF），不占 BRAM。

**技巧 4：单周期/列的 running-Y DDA（你问的那个 "running Y interpolation"）**
如果坚持要在像素率下直接画线：直线段内每个 x 的正确 y 是 `y0 + (dy/dx)(x−x0)`，
用**小数累加器**精确复现 Bresenham：
```verilog
always @(posedge clk) begin
  err <= err + dy;                 // dx 位宽累加器
  if (err >= dx) begin err <= err - dx; y <= y + 1; end
end
```
**一个 11bit 加法器 + 一个 10bit 加法器 + 1 个比较器 ≈ 25 LUT + 21 FF**，1 pixel/clk 精确。
"上一个采样"只在**段边界**需要——把每段的 `(y0, dy, dx)` 在帧起始预计算进一个小 FIFO/ROM 即可。
**这就是你说的"单周期每列 + running Y 插值"，它是可行的。**

**技巧 5：span/run 展开（水平游程法）**
离线把每行栅格化成 `(x_start, x_end, 颜色/平面)` 游程表，扫描时用窗口比较器 + 小 FIFO。
适合"游程少而宽"的内容（逻辑时序图、柱状图）。
游程 FIFO 64 项 × 32 bit = 2,048 bit = **0.06 tile**。

**技巧 6：Copper 式逐行参数表**
每行起始时重编程合成器寄存器（颜色、滚动偏移、平面使能）。
635 行 × 32 bit = 20,320 bit = **0.55 tile**（每行 1 次 BRAM 读）。
只存"变化点"的稀疏表更省。**这是零成本大幅提升视觉丰富度的关键手段**
（Amiga Copper 概念：[amiga-bootcamp copper.md](https://github.com/alfishe/amiga-bootcamp/blob/main/08_graphics/copper/copper.md)）。

**技巧 7：消隐期批量渲染 + 双缓冲交换。**
每帧 **239,040 clk（4.67 ms）** 空闲。1000 点 × ~4 clk = 4,000 clk/条曲线；
3 条曲线 + 6 个逻辑通道 + BCD 转换 + 触摸轮询合计约 20,000–40,000 clk
→ **余量 6–12 倍**。
双缓冲（两块平面在 VBlank 交换）消除撕裂，代价是平面面积 ×2。

**技巧 8：2×/4× 渲染时钟 + gearbox。** 只有在"什么都想在像素时刻算"时才需要。
本文推荐架构**不需要**。

### 3.3 栅格化写侧的具体账
- Bresenham 每采样点 = 1 次读 + 1 次写（读改写）= 2 次访问。
- 1000 点 → 2,000 次访问；若按 x 序处理并缓存当前字（只有字地址变化时才回写），
  实际只需 **300–600 次访问**。
- 100 MHz 下 = **3–6 µs** —— 一条 HBlank 是 320 px / 51.2 MHz = **6.25 µs**。
  → **单条 HBlank 就能画完一整条曲线。**

### 3.4 Lissajous/X-Y：唯一必须用位图的地方
X 不单调 ⇒ 列归约技巧失效 ⇒ **必须有一个真正的位图平面**。但：
- **256×256×1bpp = 65,536 bit = 1.8 tile**
- **512×512×1bpp = 262,144 bit = 7.1 tile**
两者都能轻松塞进 50 tile。用**双端口 BRAM**：A 口给扫描读（每 32 像素 1 次读），
B 口给 Bresenham 写，硬件天然解决读写冲突。
余辉/持续显示：2bpp 饱和计数平面（512×512×2 = 14.2 tile），或每帧把平面右移一位再 OR 上新轨迹（0 额外 BRAM）。

---

## 4. 值得抄的开源参考设计（每个都说清"抄什么"）

1. **Project F / projf-explore** — <https://github.com/projf/projf-explore> ｜ <https://projectf.io>
   关键子目录：`graphics/framebuffers/README.md`、`graphics/hardware-sprites/README.md` 与
   [`graphics/hardware-sprites/sprite.sv`](https://github.com/projf/projf-explore/blob/main/graphics/hardware-sprites/sprite.sv)、
   `graphics/lines-and-triangles/README.md`、
   [`demos/ad-astra/sprite.sv`](https://raw.githubusercontent.com/danodus/projf-explore/4b9743c4cafc9340f6e5d270a9e58aba0e2aa4ac/demos/ad-astra/sprite.sv)、`lib/display/`。
   **抄**：①"**扫描行缓冲 + 精灵**"合成器（正是"无全帧缓存"的范式，直接对应你的需求）；
   ②SystemVerilog 写的 Bresenham 直线/三角形光栅器（带 Verilator 仿真）；
   ③**把每个字形当成一个小精灵**（`ad-astra/sprite.sv` 即"Sprite for Fonts"）——
   这样文本和图形走同一条合成通路，代码量减半；
   ④`lib/display` 的时序/时钟模块。
   > ⚠️ 本会话中 raw.githubusercontent 取回失败，以上是基于搜索结果摘要 + 仓库结构知识，请自行 clone 核对。

2. **GMU ECE 448"OSD core"讲义** — <https://people-ece.vse.gmu.edu/coursewebpages/ECE/ECE448/S23/viewgraphs/ECE448_lecture23_OSD_core.pdf>
   （配套 VGA 讲义 <https://people-ece.vse.gmu.edu/coursewebpages/ECE/ECE448/S18/viewgraphs/ECE448_lecture13_VGA_4.pdf>，其中有
   `rgb_text <= "000"; --black` 这类视频/OSD 优先级混叠代码）
   **抄**：完整逐像素 OSD 数据通路 —— 像素计数 → 字符单元地址 → 字库 ROM → 移位寄存器 →
   与视频的优先级/alpha 混叠器。这就是第 2 节那张图的原型。

3. **Columbia CS4840《A Video Controller》+ Bresenham 讲义**
   <https://www.cs.columbia.edu/~sedwards/classes/2005/4840/video-controller.9up.pdf> ｜
   <https://www.cs.columbia.edu/~sedwards/classes/2016/4840-spring/lines.pdf>
   **抄**：最小可读的"文本 + 图形"VGA 控制器；以及 Bresenham 的**增量（误差累加器）形式**——
   它能 1:1 映射成"一个加法器 + 一个比较器"，就是技巧 4。

4. **naelolaiz/learning_fpga 的 font_rom.v** —
   <https://github.com/naelolaiz/learning_fpga/blob/master/display/vga/text_generator/font_rom.v>
   **抄**：一个现成的、`case` 语句形式的 Verilog 字形 ROM（`rom[1693] = 8'b00000000;` 这种）。
   用途：**今天就能让文本上屏**，同时并行开发 BRAM 版字库。

5. **Apollo / Vampire "SAGA" 视频核** —
   <https://wiki.apollo-accelerators.com/doku.php/saga_core_video> ｜
   <https://wiki.apollo-accelerators.com/doku.php/saga:video> ｜
   <http://www2.apollo-computer.com/superaga.php>
   **抄**：一个真实存在于 FPGA 上的 chunky-pixel + sprite + bitplane 视频核，
   有完整寄存器映射（`VIDEO_HTOTAL` 等，见 <https://wiki.apollo-accelerators.com/doku.php/saga_video_htotal>）。
   它是"平面 + 精灵 + 优先级混叠 = 无帧缓存的丰富 UI"的实物证明，
   也是 Copper 式可编程扫描输出的模板。
   配套读 [amiga-bootcamp copper.md](https://github.com/alfishe/amiga-bootcamp/blob/main/08_graphics/copper/copper.md)。

6. **LiteScope（enjoy-digital）** — <https://github.com/enjoy-digital/litescope> ｜
   概览 <https://deepwiki.com/enjoy-digital/litescope/1-overview>
   **只抄采集前端**：`Storage`（BRAM 环形缓冲）、`SubSampler`（抽取/降采样）、`Trigger`、`Analyzer`。
   这正是喂给你"1000 点时域图"和"6 通道逻辑采集"的东西，是纯 Verilog/Migen，可直接移植。
   **它的上位机显示部分不要抄**。

7. **MIT 6.111 示波器系列**（都是可下载的设计报告）
   - FPGA-Scope (2011)：<https://web.mit.edu/6.111/www/f2011/projects/klinke_Project_Final_Report.pdf>
     ——明确讨论了点绘 vs 包络对高频/非连续信号的差异（第 3.2 节技巧 2 引用了它）。
   - Digital Storage Oscilloscope (2021 team15)：<https://fpga.mit.edu/videos/2021/team15/report.pdf>
   - (2022 team16)：<https://fpga.mit.edu/videos/2022/team16/report.pdf>
     ——报告里写着 "The framebuffer was the first graphics module to be implemented…"，
     可以在小 FPGA 上做 BRAM 帧缓存式 DSO，**把它当年的 BRAM 预算和你的 225 KB 对比一下**，很有参考价值。
   - (2019 team06)：<https://fpga.mit.edu/videos/2019/team06/report.pdf>
     ——有 `min_frequency_window` / `max_frequency_window` / `display_position` 这类变量，
     是频谱分析仪式 UI 的现成结构。

8. **Cornell ECE 5760 "ADIOS – A Deployable Internal Oscilloscope"** —
   <https://people.ece.cornell.edu/land/courses/ece5760/FinalProjects/s2023/kae87ber72gly6/kae87ber72gly6/>
   **抄**：片上示波器整体架构 —— 采样 RAM 寻址、触发、屏幕测量标注叠加。

**补充（代码骨架，质量参差，仅作参考）**
- <https://github.com/mert137/An-FPGA-Based-Oscilloscope>（DE1-SoC，Verilog DSO）
- <https://github.com/Oguzhanka/Digital-Signal-Oscilloscope>（DE1-SoC，VGA 显示）
- CV1000 blitter 研究 <http://buffis.com/docs/CV1000_Blitter_Research_by_buffi.pdf>
  ——若将来要加 tile 帧缓存，可抄其 blitter 语义（copy/fill/line）。

---

## 5. "FPGA 上的频谱仪 / 示波器 UI"有没有成熟范式可抄？

**有，而且非常成熟。** 可照搬的范式清单：

| UI 元素 | 实现 | 成本 |
|---|---|---|
| 网格/刻度线（graticule） | 程序化：`(x mod 64)==0` 或 `(y mod 50)==0` 画 1 像素线 | ~30 LUT |
| 时域轨迹 | **逐列 min/max 包络**（技巧 2） | 2 比较器/通道 + 1.4 tile |
| 触发游标 / 触发电平线 | 2 个比较器 | ~10 LUT |
| 余辉 / afterglow | 位平面右移一位 OR 新轨迹（0 额外 BRAM），或 2bpp 饱和计数 | 2bpp 时 ×2 平面 |
| 峰保持 / max-hold | 逐列 max 寄存器 | ~30 FF |
| 自动测量框（Vpp/频率/占空比） | 程序化矩形 + 文本 | 复用区域译码 |
| 每格时基/电压读数 | 程序化 + 文本 | 复用 |
| **频谱（FFT）** | 256 点 radix-2 → 逐列幅度 → **同样是 X 单调的图，走技巧 2** | 见下 |
| 条形频谱 | 逐列竖条（列高比较） | 1 比较器/列 |
| 光标线（双游标 + ΔT/ΔV 读数） | 2 比较器 + 文本 | ~20 LUT |

**FFT 在这个器件上的具体账**（如果你要做频谱）：
- 256 点 radix-2，全流水 R2SDF：8 级，每级 1 个复数乘法。
  3 乘法器复数乘法 = **3 DSP48/级 → 24 DSP48**（90 个里的 27%），
  加 256 深复数延时线 = 256×32 bit = 8,192 bit = **0.22 tile**。吞吐 1 采样/clk。
- 或单 DSP 迭代式：1024 个蝶形 × ~4 clk ≈ **4,096 clk/帧** —— 对 239,040 clk 的消隐预算来说
  **完全可以忽略**（可以每帧算很多次）。
- 参考：[FFT and Audio Visualizer on FPGA](https://zakriyaparacha.com/beyond-software/fpga-audio-spectrum.html)。

**结论**：抄 DSO 的 UI 惯例 + 用"X 单调的图 → 逐列存储，其余程序化，只有 X-Y 图用 1bpp 位平面"
这一条实现原则，就能把示波器/频谱仪级别的 UI 做得又便宜又好看。

---

## 6. DDR3 / MIG 现实核查

### 6.1 许可证
**MIG 7 Series 随 Vivado 安装包提供，对 Artix-7 不是单独售卖的 IP**，在免费的 WebPACK 器件支持范围内即可生成。
> **置信度：高，但本会话未能直接引用 AMD 原文。** AMD 的 MIG 产品页（各语言版本）连续三次 fetch 失败，
> UG586 PDF 也取不到（403 / 连接失败）。**最可靠的验证方式：在 Vivado IP Catalog 里直接生成一次
> MIG 7 Series，如果缺许可证会立刻报错**，30 秒就能确认。
> 另外注意：网上流传的 "Xilinx/AMD 不再提供免费 Linux 许可证" 讨论指的是旧 ISE/SDK 时代的
> 另一件事，**与 7 系列 MIG 无关**，不要混淆。

### 6.2 你这块板的具体事实（重要）
正点原子《达芬奇 FPGA 开发指南》第 31 页称 **XC7A35TFGG484-2 的 IO 支持 DDR3 的 800M 高速输入输出**，
而《达芬奇 MicroBlaze 开发指南》第 161 页在 MIG 里配置 DDR3 速率时**最高只能选 400M**。
原帖：<http://www.openedv.com/forum.php?mod=viewthread&tid=345296>

**这两个说法不矛盾**：400 MHz 是**时钟**，DDR 双沿 → 800 MT/s 是**数据率**。
所以这块板跑的是 **DDR3-800，正是 MIG 对这颗器件允许的上限**。
> **实际后果：你无法通过提高 MIG 时钟来买带宽。** 1,600 MB/s 理论 / ~0.9–1.1 GB/s 实测就是天花板。
> 对帧缓存（需 300–450 MB/s）够用，但别指望更快。

### 6.3 现实工作量与风险
- **最优情况（2–5 天）**：从正点原子自带的 DDR3/MIG 例程起步，**不动 MIG 的 .xci、不动板级 XDC、
  不改时钟频率和 IO 标准**，只在自己的用户逻辑里接 native UI。
  时间基本花在读/写 FSM 和跨时钟域上。
- **最坏情况（1–3 周）**：从零生成 MIG，包括 pin/bank 规划、DCI/VREF、
  必需的 **200 MHz IDELAYCTRL 参考时钟**、floorplan，以及开放式地排查校准失败。
- **具体坑**：
  - MIG 需要干净的 200 MHz IDELAYCTRL 参考时钟，**必须在校准前锁定**。
  - **CMT 预算**：只有 5 个（5 MMCM + 5 PLL）。像素时钟、系统时钟、MIG 自己的 MMCM、200 MHz 参考
    很容易吃掉 3–4 个。**先把时钟树规划完再决定要不要上 MIG。**
  - **校准失败是常见失败模式**，同器件级别的实例：
    [Arty A7-35T DDR3 MIG Calibration Fails at Read Leveling (CAL1_RDLVL_ERR) – Vivado 2024.2](https://forum.digilent.com/topic/34297-arty-a7-35t-ddr3-mig-calibration-fails-at-read-leveling-cal1_rdlvl_err-%E2%80%93-vivado-20242/)
    （也是 Artix-7 35T + 16bit × MT41K128M16 DDR3 拓扑）。
    UG586 给出了用 ILA 触发 `dbg_rdlvl_err[1]` 的调试流程：
    <https://www.xilinx.com/support/documents/ip_documentation/mig_7series/v4_1/ug586_7Series_MIS.pdf>
  - **帧缓存有硬实时截止时间**：扫描输出绝不能欠载。需要一个按"最坏仲裁延迟（刷新 + 写竞争者）"
    留足余量的预读行 FIFO。经验值 **≥4–8 个行缓冲的余量** = 4–8 × 0.67 = **3–5 tile BRAM**。
    → **DDR3 方案同样消耗 BRAM，只是把成本从"图像大小"换成了"延迟吸收"。**
  - **板级风险低**（前提）：只要正点原子自己的 DDR3 例程在你板上校准通过，
    说明 PCB 走线/length matching 已验证；此后不改 MIG 配置/引脚/IO 标准就没有新的板级风险。

### 6.4 更简单的替代方案
1. **接受 BRAM 上限 —— 推荐。**
   上面的预算证明完整 UI 只占 24–37/50 tile。这不是妥协：
   同样的架构在 Amiga/街机时代用远更少的内存就跑起来了。
2. **把 DDR3 用作"样本存储"而不是帧缓存 —— 如果要上 MIG，这才是正确用法。**
   存 8–16 M 个 ADC 采样（8–16 MB），显示仍从 BRAM 走。
   **没有实时截止时间**，能容忍刷新停顿，只需要一个突发写 + 一个突发读，
   换来长采集/缩放这个真实功能增益。**风险远低于帧缓存，而 MIG 的 bring-up 成本两者相同**
   （反正只付一次）。
3. **QSPI Flash —— 不建议用。**
   - 只读，**装不下任何逐帧变化的东西**，根本不可能是帧缓存。
   - 带宽：QSPI x4 @ 50 MHz = 200 Mbit/s = **25 MB/s 理论，实际 10–20 MB/s**，
     且命令/dummy cycle 开销导致**单次访问延迟高**（几十个时钟）。
   - 7 系列上从 fabric 接管 QSPI 引脚需要 `STARTUPE2` 原语（`USRCCLKO`/`USRDON`/`USRDATA`），
     并小心不要破坏配置；AXI Quad SPI 的 PG153 明确描述了 SCK 接 STARTUPEn 的做法：
     <https://japan.xilinx.com/content/dam/xilinx/support/documents/ip_documentation/axi_quad_spi/v3_2/pg153-axi-quad-spi.pdf>
   - **结论**：只有当你需要几百 KB 级资产时才值得。
     而 500 个汉字字库 + 图标集 + 几张背景图 ≈ **100–200 KB ≈ 2–4 个 RAMB36**。
     **所以跳过它。**

---

## 7. 像素时钟 / 带宽可行性核算

### 7.1 每像素预算
- 像素率 **36.86 Mpixel/s**；像素时钟 51.2 MHz → **19.53 ns/有效像素**。
- 有效像素只占 72%，但**扫描输出不能停顿**，所以必须按 **1 pixel/clk** 设计，
  把 28% 的消隐当**额外**算力而不是可挪用预算。
- 因此必须是**固定延迟的寄存流水线**，4–8 级 LUT6。
- Artix-7 -2 一级 LUT6+FF ≈ 0.35–0.5 ns 逻辑 + 布线 → 6–10 级都能轻松闭合，
  功能上这条流水线能跑到 150–250 MHz。（**不需要超频**。）

### 7.2 BRAM 端口带宽
- **错误做法**：每像素 1 次 BRAM 访问 → 需 36.86 M 访问/s，单端口 51.2 MHz 只有 51.2 M 访问/s，
  **占用率 72%，一步都不能错**。这是设计陷阱。
- **正确做法**：**每个平面独占一个 BRAM（端口），按 32bit 字预取，每 32 像素读 1 次。**
  36.86 / 32 = **1.15 M 访问/s/平面 = 端口占用率 2.3%**。
  8 个平面也只有 18% 的总访问量，而且分摊在 8 个独立端口上。
  **→ BRAM 带宽根本不是问题。**
- 唯一例外是光栅化写侧：每帧几千次访问，可忽略。

### 7.3 每像素逻辑资源
- 每像素组合工作量 ≈ **10–25 LUT 当量**：活跃区域译码 10–15 + 文本 4–6 + 平面查表 1–2 + 优先级/调色 4–8。
- 注意这是**并行硬件**，不是"每像素耗时"。真正跟"每像素"绑定的是：
  ① 每平面每 32 像素 1 次 BRAM 读；② 沿流水线摊开的 ~25 LUT 组合深度；
  ③ 每级流水寄存器 40–56 bit（24b 颜色 + 平面位 + valid）→ **总计 300–450 FF**。

### 7.4 必须多周期 / 必须推迟的工作
- **任意折线/多边形光栅化（Bresenham）** → 做进位平面，用消隐期或 BRAM 第二端口。
- **字符查表**：单元读和字形读必须预取（1 次/8 像素、1 次/文本行），
  地址计算 `char*16+row` 的乘法**绝不能出现在像素路径的组合逻辑里**。
- **二进制 → BCD → ASCII**（数值读数）：每帧在消隐期做一次写进单元缓冲即可。
  双 dabble 转换器 ~32 级；串行版 32+ clk；按位查表除法 ~5 clk/位。**在 239,040 clk 面前全是零。**
- **FFT / 表针三角函数 / CORDIC** → 消隐期或独立慢时钟域。

### 7.5 结论
> **一次全屏程序化遍历在 51.2 MHz、1 pixel/clk 下，在这颗器件上完全可行。**
> 像素流水线预计消耗 **1,500–4,000 LUT**（器件的 7–19%）和 **1–3 个 BRAM tile**，
> 其余全部留给测量/绘图逻辑。**不需要 DDR3 帧缓存，也不需要给流水线超频。**

---

## 8. 推荐的落地模块划分与资源预算

```
pixel_clk_gen      MMCM 50 MHz → 51.2 MHz（你已有，照抄正点原子 RGB LCD 例程的 MMCM 配置）
scanout_timing     1024x600 @ 59.99 Hz，H 1344 / V 635（你已有）
copper             635 × 32bit 逐行参数表（1 BRAM tile，1 次读/行）+ 稀疏变化点优化
region_decode      24 个矩形比较器 → region_id + 优先级（≈ 410 LUT）
text_engine        cell_ram(1 tile) + font_rom(1~2 tile) + 移位寄存器（≈ 120 LUT）
plot_env           2ch × 1024 列 (ymin,ymax)×12bit 包络 RAM（1.4 tile）+ 4 比较器（≈ 60 LUT）
plot_logic         1024 列 × 6bit 状态 RAM（0.5 tile）+ 6 行带比较器（≈ 54 LUT）
plot_xy            512×512×1bpp 位平面（7.1 tile，双端口）+ Bresenham 写状态机
compositor         平面优先级 mux → 调色板 → RGB888 → 流水寄存（≈ 150 LUT + 300 FF）
acq                2ch ADC 解串 + 触发 + 环形缓冲写；6ch 逻辑采集（≈ 200 LUT）
numfmt             bin→BCD→ASCII，消隐期写 cell_ram（≈ 250 LUT）
touch              GT911 I²C master + 矩形命中测试（≈ 300 LUT）
page_fsm           当前页寄存器，由 copper 表和触摸驱动
```

| 资源 | 预算 | 占 XC7A35T |
|---|---|---|
| LUT | **约 2,150**（UI 引擎）+ 你的测量逻辑 | 约 10% |
| FF | 约 1,000 | 约 2.4% |
| DSP48 | 0（UI）／ 0–8（圆形表盘）／ 24–32（若加 256 点 FFT） | 0–36% |
| RAMB36 | **24（精简）/ 37（豪华）** | 48% / 74% |
| CMT | 1（像素时钟）；若上 MIG 再 +2~3 | 20% / 80% |

**留出 ≥13 个 RAMB36 余量给未来功能**（更多页、更多通道、更长采集深度）。

---

## 9. 不确定项与需要你自己验证的点（诚实清单）

1. **1344×635 消隐参数是反推的**，不是查到的原厂值。请以你的 `scanout_timing.v` 为准，但 51.2 MHz/59–60 Hz 完全自洽。
2. **MIG 的 LUT/FF 具体数字是量级估计**。本会话中 UG586 PDF 与 AMD 产品页全部 fetch 失败
   （403 / 连接失败 / 429），无法引用表格行。请以 Vivado 生成核后的 utilization report 为准。
3. **MIG 许可证**：高置信度认为 7 系列 MIG 免费且随 Vivado 提供，但未能直接引用 AMD 原文。
   最快验证 = 在 IP Catalog 里生成一次。
4. **MIT 6.111 / Cornell / GMU 的 PDF 大多取不回来**（403 / 连接失败）。
   正文中引用的具体句子（如 klinke 报告里关于 "area unfilled" 与高频/非连续信号的那段）
   来自搜索引擎返回的**原文摘要**，可以信任；但更细的设计细节我无法核实。
5. **Project F 各 README/源码**同理：raw.githubusercontent 取回失败，
   仓库结构描述来自搜索结果的路径命中 + 我对该仓库的了解。
6. **各处 LUT 估算**（比较器 ~3 LUT、区域译码 ~410 LUT 等）是工程经验估算，
   不是综合结果。请在实现后用 `report_utilization` 校准。

---

## 10. 一句话结论

**用 24–37 个 RAMB36（共 50 个）做"程序化背景 + Copper 逐行参数表 + 8×16 点阵文本 +
逐列 min/max 包络（时域）+ 逐列 6bit 状态（数字时序）+ 512×512×1bpp 位平面（仅 X-Y 图）"
的混合架构，就能在 XC7A35T 上实现你描述的完整监控 UI；
不需要 DDR3 帧缓存，不需要 MIG，不需要帧缓存，1 pixel/clk 流水线在 51.2 MHz 下轻松闭合。
DDR3/MIG 如果要用，正确用途是长采集样本存储，而不是显示。**
