# 正点原子 达芬奇-lite (ALIENTEK Da Vinci-lite) + XC7A35T — 结构化摘要

**来源文档**: `_tools/txt/ATK_GUIDE.txt`（由 `【正点原子】达芬奇-lite之FPGA开发指南V1.0(1).pdf` 提取，915 页）
**引用格式**: `guide: <章节标题>`。凡文档中查不到的内容一律写 `not found in document`，不做推测。
**重要提醒**: 该 PDF 的文本层**丢失了所有图片与表格图片**，因此"扩展口引脚分配"、"BANK 管脚原理图"、"扩展 IO 口原理图"等只以"图 xxx"形式出现、无文字表格。凡属此类，下文明确标注。

---

## 1. 主控 FPGA 与开发板名称

| 项目 | 内容 | 出处 |
|---|---|---|
| FPGA 完整型号（工厂/工业级） | **XC7A35TFGG484-I-2** 与 **XC7A100TFGG484-I-2**（两种型号可选） | `guide: 2.1 开发板 IO 分配`（"开发板的主控芯片有两种，分别为 XC7A35TFGG484-I-2 和 XC7A100TFGG484-I-2，他们的可用 IO 数量分别为 250 个和 285 个"） |
| Vivado 工程中使用的 Part | **`xc7a35tfgg484-2`** 与 **`xc7a100tfgg484-2`**（不带 "L" 的版本） | `guide: 4.3.8 新建工程`（"分别是'xc7a35tfgg484-2'与'xc7a100tfgg484-2'… 带有'L'的是低成本版本… 开发板所用的是不带'L'的版本"） |
| 系列 / 封装 / 速度等级 / 温度等级 | Artix-7 (a = Artix7) · 封装 **FGG484** (484 球) · 速度等级 **−2** · 温度等级 **I（工业级，−40°C ~ +125°C）** | `guide: 4.3.8 新建工程`（型号命名规则逐段解释：xc / 7 / a / 100t / fgg484 / −2 / i） |
| 逻辑资源 | **XC7A35T 的 BRAM 存储资源为 1800 Kbit**；XC7A35T 有 **250 个可用 IO**、**5 个 CMT**；XC7A100T 为 **285 个可用 IO**、101.44K LC、4.86Mb BRAM、6 个 CMT | `guide: 23.1 简介` · `guide: 24.1 简介`（"xc7a35t 的片内存储资源为 1800Kbit"）· `guide: 2.1 开发板 IO 分配` · `guide: 前言` |
| Bank 结构 (XC7A35T) | 6 个 Bank：Bank 0 + HR Bank **14/15/16/34/35** + GTP Quad 216；HR Bank 支持 1.2/1.35/1.5/1.8/2.5/3.3V 及 LVDS；XC7A35T 共 **5 个 CMT**（XC7A100T 为 6 个，且多 Bank13/Bank213） | `guide: 1.2.1 硬件资源说明` |
| 板级营销名称 | **达芬奇-lite**、**达芬奇-lite 开发板**、"正点原子 达芬奇-lite 开发板"、教程名《达芬奇-lite 之 FPGA 开发指南 V1.0》 | `guide: 封面 / 前言` |
| 板卡尺寸 | 80mm × 55mm | `guide: 前言 / 1.1 开发板资源初探` |
| 厂商 | 广州市星翼电子科技有限公司（ALIENTEK / 正点原子） | `guide: 版权页 (p2)` |

---

## 2. 板载时钟资源

| 时钟 | 频率 | 引脚 / IO 位置 | 单端 or 差分 | 是否可驱动 MMCM/PLL | 出处 |
|---|---|---|---|---|---|
| **系统时钟 (板载晶振)** | **50 MHz** | 引脚 **V4**（约束里标为 `sys_clk`，`create_clock -period 20.000`，IOSTANDARD LVCMOS33） | 文档自相矛盾但**倾向于差分**：PLL 配置时 Source 选 **"Differential clock capable pin"**，原文"本次实验的系统时钟就是由晶振产生并通过差分时钟引脚接入的"；FLASH 实验顶层端口为 `sys_clk_p` / `sys_clk_n` 并用 **IBUFDS** 转成 `sys_clk`。**N 端的具体引脚号：not found in document** | ✅ 是。PLL/MMCM 例程直接以它作 `clk_in1` | `guide: 1.2.1 硬件资源说明`（硬件框图标注"系统时钟 50MHz"）· `guide: 8.4.1 PLL IP核配置` · `guide: 第十八章 FLASH读写实验`（IBUFDS 代码）· `guide: 表 8.5.1 / 表 17.5.1` |
| DDR3 差分时钟 | DDR3 工作时钟 **400 MHz**（DDR 双沿 → 800 Mbps） | FPGA 输出 `ddr3_ck_p` = **P5**、`ddr3_ck_n` = **P4**（Bank 35，VCCO 1.35V） | 差分 | 由 MIG IP 核内部 MMCM 产生；MIG 的 `clk_ref_i` 参考时钟由 FPGA 内部 **200 MHz** 提供（实验里由 PLL 产生） | `guide: 表 2.1.1 管脚分配` · `guide: 17.4.3 MIG IP核`（"Clock Period…选择 2500ps，对应 400MHz… 本实验选 4:1"）· `guide: 24.4.1 整体模块设计`（`.clk_ref_i (clk_200m)`） |
| RGMII 接收时钟（来自 PHY YT8531） | 千兆时 125 MHz | `eth_rxc` = **Y18**（输入） | 单端（LVCMOS33 约束） | 由 PHY 提供，配合 BUFIO/BUFG 采集 | `guide: 表 2.1.1` · `guide: 第二十一章 以太网ARP测试实验`（BUFG/BUFIO/IDDR/IDELAY 讲解） |
| RGMII 发送时钟（送 PHY） | 125 MHz | `eth_txc` = **AA18**（输出） | 单端 | — | `guide: 表 2.1.1` |
| PLL 实验演示输出（接到 J6 扩展口） | 100 MHz / 100 MHz 相移 180° / 50 MHz / 25 MHz | **G21 / D22 / D21 / B22** —— guide 明说这些是"开发板 **J6** 扩展口对应的管脚" | 单端 LVCMOS33 | 由 clk_wiz (MMCM) 从 50 MHz 生成 | `guide: 表 8.5.1 IP核之PLL实验管脚分配` · `guide: 8.5 下载验证` |
| SD 卡 SPI 时钟 | 由 PLL 产生 50 MHz + 50 MHz/180°（`clk_ref` / `clk_ref_180deg`） | 输出到 `sd_clk` = **U22** | 单端 | — | `guide: 第十九章 SD卡读写测试实验` |
| 摄像头模块时钟 | **24 MHz，来自 ATK-Dual-OV5640 模块上的有源晶振**（非开发板）；OV5640 输出给 FPGA 的 PCLK 在 1024×768 场景为 **48 MHz**，但 XDC 按 `create_clock -period 40.000`（25 MHz）约束 | 模块自供；FPGA 侧收 `cam_pclk_1` = **C14** / `cam_pclk_2` = **F13** | 单端 | 否（走普通 IO，约束里加了 `CLOCK_DEDICATED_ROUTE FALSE`） | `guide: 24.1 简介` · `guide: 24.2 硬件设计` · `guide: 24.5 下载验证` XDC |
| 板载独立时钟发生器芯片 (Si5338/Si5351/CDCE 等) | **not found in document** | — | — | — | — |

**结论（对 24-bit 并行 ADC 的意义）**：板载只有一颗 **50 MHz 晶振**，**必须通过 MMCM/PLL 倍频**才能得到 65 MHz 采样时钟。XC7A35T 有 **5 个 CMT（每 CMT = 1 MMCM + 1 PLL）**，PLL 输入范围 19–800 MHz、输出 6.25–800 MHz，最多 6 路输出 —— 资源完全够用（`guide: 表 8.1.1 常用芯片的PLL IP核重要参数`）。50 MHz → 65 MHz 不是整数倍关系，需用 MMCM 的 M/D/O 分频比实现（VCO 需 ≥ 600 MHz），届时注意 Vivado 会给出实际频率偏差提示（guide 提到设置 33 MHz 时会出现类似警告）。

---

## 3. 存储器 (Memory)

| 器件 | 型号 / 容量 | 连接与引脚 | 出处 |
|---|---|---|---|
| **DDR3 SDRAM** | **NT5CC128M16JR-EK**（南亚 Nanya），1 片，**2 Gbit = 256 MB**，x16 位宽，速率可达 **800 Mbps**，最大带宽 800M×16 = **12.8 Gbps**。DDR3 工作时钟 400 MHz，双沿采样（400MHz×2×16bit=12.8Gbps） | 全部挂在 **Bank 35**，**VCCO = 1.35V**（`guide: 2.1.1`："BANK35 完全提供给 DDR3 使用，该 BANK 电压使用 1.35V"）。完整 43 根引脚见 `guide: 表 2.1.1 管脚分配`（`ddr3_dq[0..15]`、`ddr3_dqs_p/n[0..1]`、`ddr3_addr[0..13]`、`ddr3_ba[0..2]`、`ddr3_ras_n/cas_n/we_n`、`ddr3_reset_n`、`ddr3_cke`、`ddr3_cs_n`、`ddr3_dm[0..1]`、`ddr3_odt`、`ddr3_ck_p/n`） | `guide: 1.2.1 硬件资源说明` · `guide: 2.2.7 DDR3 SDRAM存储器` · `guide: 17.2 硬件设计` · `guide: 表 2.1.1` |
| **QSPI FLASH** | **N25Q128**（Micron 美光），**128 Mbit = 16 MB**，SPI 接口，用于存放 FPGA 配置数据（程序固化）及用户数据 | 数据/片选引脚：`spi_cs` = **T19**，`spi_mosi` = **P22**，`spi_miso` = **R22**（LVCMOS33）。**SPI 时钟未分配普通 IO**：FLASH 实验通过 **STARTUPE2** 原语把 `spi_clk` 引到专用配置时钟 **USRCCLKO**（即 CCLK） | `guide: 1.2.1` · `guide: 2.2.6 FLASH` · `guide: 表 18.5.1 FLASH读写实验管脚分配` · `guide: 18.4.5 顶层模块设计`（STARTUPE2 例化代码） |
| **EEPROM** | **AT24C64**（Atmel），**64 Kbit = 8 KB**，I²C 接口；A0~A2 全部接地（地址位=0） | `iic_scl` = **W22**，`iic_sda` = **AA20**（LVCMOS33） | `guide: 1.2.1` · `guide: 2.2.8 EEPROM` · `guide: 表 2.1.1` + `guide: 15.5 下载验证` |
| SDRAM（非 DDR） | **not found in document**（板上只有 DDR3，无 SDRAM 器件） | — | — |
| Micro SD / TF 卡 | 标准 Micro SD 卡座，可用 **SPI 或 SDIO** 方式驱动；"若采用 4 位 SDIO 方式驱动，理论上最大速度可以达到 24MB/S"。实际例程走 **SPI**（SD2.0，2GB–32GB 卡） | `sd_clk` = **U22**，`sd_cs` = **R19**，`sd_miso` = **T21**，`sd_mosi` = **V22**，`sd_cd`（插拔检测）= **P20** | `guide: 1.2.1` · `guide: 2.2.11 Micro SD卡接口` · `guide: 表 19.5.1 SD卡读写测试实验管脚分配` |

---

## 4. 用户接口与外设 (User interfaces)

| 外设 | 器件 / 规格 | 引脚（FPGA 侧信号名 = 引脚号） | 出处 |
|---|---|---|---|
| **用户 LED** | 2 个红色 **LED0 / LED1**，**IO 输出高电平点亮** | `led0` = **AB21**，`led1` = **AB22** | `guide: 1.2.1` · `guide: 2.2.4 LED` · `guide: 表 2.1.1` |
| **电源指示灯** | 蓝色 LED (PWR)，电源正常即亮（直接接电源，非 IO） | 无 IO | `guide: 2.2.14 电源指示灯` |
| **配置完成指示灯** | 接 FPGA 的 **DONE** 信号，配置完成后点亮 | 无用户 IO | `guide: 2.2.15 配置完成指示灯` |
| **按键** | 3 个机械按键：**RST_N（复位按键，常作系统复位）**、**KEY0**、**KEY1**；均**外接上拉**，未按下=高，按下=低 | `sys_rst_n` = **U7**，`key0` = **W9**，`key1` = **Y9** | `guide: 1.2.1` · `guide: 2.2.3 按键电路` · `guide: 表 2.1.1` |
| **USB 串口** | **CH340E**（南京沁恒）USB→UART，**USB Type-C 座**，同时是整板 **5V 供电口**；CH340 单独用 XC6206P332MR 供 3.3V（断电后电脑仍能识别 COM 号） | `uart_rxd` = **T20**（输入），`uart_txd` = **W21**（输出），LVCMOS33 | `guide: 1.2.1` · `guide: 2.2.10 USB 串口` · `guide: 第十二章 12.2 硬件设计` · `guide: 表 2.1.1` |
| **JTAG 下载口** | **FT232**（USB→JTAG），接口为 **USB Type-C** | FT232 接 FPGA 专用 JTAG 引脚（TDI/TDO/TCK/TMS），**无用户 IO 引脚号** | `guide: 1.2.1` · `guide: 2.2.2 JTAG接口` |
| **HDMI** | 1 路 **HDMI 输入/输出**接口（复用），最高 1080P；PHY/编码由 FPGA 逻辑实现（TMDS + OBUFDS）；IIC 侧 5V↔3.3V 用 MOS 管双向电平转换；有 OUT_EN 开关芯片切换输入/输出 | `hdmi_data_p[2]` = **N13**，`[1]` = **P15**，`[0]` = **N17**，`hdmi_clk_p` = **W19**（IO 标准 **TMDS_33**）；`hdmi_out_en` = **U20**，`hdmi_hpd` = **V20**，`hdmi_scl` = **R17**，`hdmi_sda` = **P16**（LVCMOS33） | `guide: 1.2.1` · `guide: 2.2.12 HDMI接口` · `guide: 1.1.1`（"1个HDMI输入/输出接口"，注意 `guide: 1.2.1/12` 处旧文写作"HDMI输出接口"）· `guide: 表 2.1.1` · `guide: 第十四章 HDMI彩条显示实验 / 14.5 下载验证` |
| **VGA** | 板上**没有 VGA 接口**（VGA 只在 LCD 时序讲解里作为对比被提到） | — | `guide: 13.1 RGB TFT-LCD简介`（提到 VGA 时序） |
| **以太网** | 1 路**千兆以太网**，PHY = **YT8531C**（`guide: 2.2.9` 写作 **YT8531**），支持 10/100/1000 Mbps，**RGMII** 接口 + **MDIO** 管理；RJ45 为自带网络变压器的插座 **HR911131A** | `phy_rst_n` = **V18**，`eth_mdio` = **T18**，`eth_mdc` = **R18**，`eth_txc` = **AA18**，`eth_txd[3:0]` = **U17/U18/P14/R14**，`eth_tx_ctl` = **AB18**，`eth_rxc` = **Y18**，`eth_rxd[3:0]` = **AA19/AB20/V17/W17**，`eth_rx_ctl` = **V19**（全部 LVCMOS33） | `guide: 1.2.1` · `guide: 2.2.9 以太网接口` · `guide: 表 2.1.1` · `guide: 21.x/22.x` XDC |
| **RGB LCD 接口** | 1 个标准 **RGB888 TFT-LCD** 接口，支持触摸（电阻/电容）；仅支持 RGB 屏，**不支持 MCU 屏**；兼容 ATK-4384 / ATK-7084 / ATK-7016 / ATK-1018 | 24 位数据 `lcd_rgb[23:0]`（列表见 `guide: 表 2.1.1`，如 `lcd_rgb[0]`=V5，`[23]`=AA6），`lcd_hs`=**AB2**，`lcd_vs`=**T1**，`lcd_de`=**W2**，`lcd_bl`=**Y2**，`lcd_pclk`=**U1**，`lcd_rst`=**R2**；触摸 `touch_scl`=**T4**，`touch_sda`=**U5**，`touch_int`=**T5**，`touch_rst_n`=**W4** | `guide: 2.2.5 RGB LCD模块接口` · `guide: 表 2.1.1` · `guide: 第十三章 RGB LCD彩条显示实验 / 13.5 下载验证` |
| **摄像头接口** | **无专用摄像头座**；用 **ATK-Dual-OV5640 双目摄像头模块插在 J6 扩展口**上，模块自带 **24 MHz** 有源晶振；OV5640 支持最高 2592×1944，输出给 FPGA 的像素时钟在 1024×768 场景下文档写 **48 MHz**（而 XDC 里 `create_clock -period 40.000` = 25 MHz，⚠️两处不一致） | 全部经 J6 扩展口，XDC 见 §7-D | `guide: 1.4 开发板可搭配的外设介绍`（外设二）· `guide: 24.1 简介` · `guide: 24.2 硬件设计` |
| **音频 Codec** | **not found in document**（板载资源清单、硬件资源框图、原理图详解章节均无音频 codec；文档只在讲 HDMI 协议时提到"音频数据"） | — | — |
| **电源 / PMIC** | 整板 5V 来自 USB Type-C；**EA3059** DC-DC 一次产生 **1.0V / 1.35V / 1.8V / 3.3V**（四路，靠 EN1~EN4 时序控制：1.0V→1.8V→1.35V&3.3V）；**SPX3819M5**（+3.3V/+2.5V/+1.8V，给 Bank15/Bank16 供电，由拨码开关选反馈电阻）；**XC6206P332MR**（+3.3V，串口电平转换芯片）；**RT9013-3.3**（+3.3V/500mA，HDMI 专用） | 电源拓扑见 `guide: 2.2.1 开发板电源` | `guide: 2.2.1 开发板电源` |
| **Bank 电压选择开关** | **J9 和 J10 两个 Bank 电压选择开关**（每个 3 位独立拨码），可分别为所在 Bank 提供 **1.8V / 2.5V / 3.3V**。⚠️"同一时刻，有且仅有一位拨码开关可以处于 ON 状态"。文档另一处把开关称作 **"B16 电压选择器"**（1 和 6 引脚通道拨到 ON → 输出 3.3V） | 物理器件 J9/J10 | `guide: 1.2.1 硬件资源说明`（第13条）· `guide: 2.2.1 开发板电源`（图 2.2.3 线性稳压器转换电路）· `guide: 8.5 下载验证` / `guide: 16.2 硬件设计`（"B16 电压选择器"） |
| **其它板载器件丝印** | 硬件框图列出：BANK 0/13/14/15/16/34/35、BANK 216、JTAG、FPGA Done、TF 卡接口、千兆以太网、J5/J6 扩展口、系统时钟 50MHz、功能按键、EEPROM、QSPI Flash、UART 串口、LED 灯、DDR3 SDRAM、RGB LCD 接口、HDMI 接口 | `guide: 图 1.2.1 达芬奇-lite FPGA开发板硬件资源框图` | 同左 |

---

## 5. 扩展排针 (Expansion headers) —— 本摘要最关键的一节

### 5.1 排针总体规格

| 项目 | 内容 | 出处 |
|---|---|---|
| 排针名称 | **J5** 与 **J6**（原文亦称"扩展口 / IO 扩展口 / 拓展 IO 口"） | `guide: 1.2.1`（第14条）、`guide: 2.2.13 扩展IO口`、`guide: 16.2 硬件设计` |
| 形式 / 间距 | 两组，均 **2×26 排针（2.54 mm）** | `guide: 1.2.1`、`guide: 2.2.13` |
| 总可用 IO 数 | **96 个 FPGA IO 引脚**（J5 + J6 合计） | `guide: 1.2.1`、`guide: 2.2.13` |
| 每组排针的非 IO 引脚 | 每组含 **1 个 5V 电源引脚 + 1 个 Bank 电源引脚 + 2 个 GND 引脚**（共 4 个非 IO）→ 每组 52 − 4 = **48 个 IO** | `guide: 1.2.1`（第1条、第14条）、`guide: 2.2.13` |
| 电源归属 | **J5 含 1 个 Bank15 电源和 5V 电源引脚；J6 含 1 个 Bank16 电源和 1 个 5V 电源引脚** | `guide: 1.1.1 开发板资源`（第14条）、`guide: 1.2.1`（第14条） |
| 背面丝印 | 排针引脚丝印印在**开发板背面**，丝印上直接标明"Bank 电压、5.5V 电压和 GND"（原文如此，疑为 5V 笔误），方便按丝印分配引脚 | `guide: 1.3 开发板丝印详解` · `guide: 图 1.3.2 开发板背面扩展口引脚丝印` |
| 支持的模块 | 正点原子的**高速 AD/DA 模块、双路 AD、双路 DA、交通灯、双目摄像头**等；也允许用户自接外设 | `guide: 2.2.13`、`guide: 16.2 硬件设计` |
| ⚠️ 电平标准要求 | "**在使用时需要注意 IO 电平标准要和扩展口的一致**"；AD/DA 与双目摄像头实验都要求**把 Bank16 电压选择开关设为 3.3V** | `guide: 16.2 硬件设计`、`guide: 24.5 下载验证` |

### 5.2 IO Bank 与 VCCO 电压

| 排针 | 所属 Bank | VCCO 可选值 | 如何设置 | 出处 |
|---|---|---|---|---|
| **J5** | **Bank 15** | **1.8V / 2.5V / 3.3V**（由 J9 或 J10 三位拨码开关选择；SPX3819M5 + 反馈电阻） | 拨码开关：1&6 通道 ON → 3.3V；其他通道分别对应 2.5V、1.8V。**同一时刻只允许一位 ON** | `guide: 1.2.1`（第13条）· `guide: 2.2.1 开发板电源` |
| **J6** | **Bank 16** | **1.8V / 2.5V / 3.3V** | 同上（拨码开关，文档里叫 "B16 电压选择器"）。AD/DA 与双目摄像头实验均要求设为 **3.3V** | `guide: 1.2.1` · `guide: 2.2.1` · `guide: 16.2` · `guide: 24.5` |
| 结论 | J6 上的 IO 全部按 **Bank16 = VCCO 3.3V → `LVCMOS33`** 使用；Bank15 可与 3.3V 电平互接（同为 HR Bank） | | | |

> `guide: 2.1.1 FPGA BANK原理图` 与 `guide: 图 2.2.20 扩展 IO口` 给出了 **BANK15 / BANK16 完整管脚原理图与扩展口原理图**，但**都是图片**，文本层没有表格 —— 因此 **J5/J6 的"针号 1..52 → FPGA 引脚名"完整对照表：not found in document（仅以图片形式存在）**。下文 5.3/5.4 给出从 XDC 约束中提取的**已知被使用/已验证可用**的引脚清单。

### 5.3 J5（Bank 15）已知引脚

- **not found in document** —— 整本指南**没有任何实验使用 J5**，因此 J5 的引脚名在文本中一个也没出现。需要翻 `开发板资料盘\赛灵思 A7\3_开发板原理图` 或看板背面丝印。

### 5.4 J6（Bank 16）已知引脚（由三处 XDC + 一处文字说明汇总，全部 `LVCMOS33`）

| FPGA 引脚 | 指南中的用途（出处） | 方向 |
|---|---|---|
| **G21** | PLL 实验：`clk_100m` 输出（`guide: 表 8.5.1`、`guide: 8.5 下载验证`） | 输出 |
| **D22** | PLL 实验：`clk_100m_180deg` 输出 | 输出 |
| **D21** | PLL 实验：`clk_50m` 输出 | 输出 |
| **B22** | PLL 实验：`clk_25m` 输出（文档配了示波器实测波形） | 输出 |
| **A14** | 高速 AD/DA 实验：`da_clk` / 双目摄像头：`cam_href_2` | 输出 |
| **B16, B15, C15, C14, A16, A15, D15, D14** | 高速 AD/DA 实验：`da_data[0..7]`（D14=bit7 … B16=bit0） | 输出 |
| **F13, F14, E13, E14, F16, E17, C13, B13** | 高速 AD/DA 实验：`ad_data[0..7]` | 输入 |
| **D16** | 高速 AD/DA 实验：表 16.5.1 标为 `ad_otr`，而 XDC 标为 `ad_clk`（⚠️**文档内自相矛盾**）；双目摄像头：`cam_rst_n_2` | 输入/输出 |
| **E16** | 高速 AD/DA 实验：表 16.5.1 标为 `ad_clk`，而 XDC 标为 `ad_otr`（⚠️同上矛盾）；双目摄像头：`cam_data_2[0]` | 输入/输出 |
| **A13** | 双目摄像头：`cam_sda_2` | 双向 |
| **C18** | 双目摄像头：`cam_scl_1` | 输出 |
| **A18** | 双目摄像头：`cam_sda_1` | 双向 |
| **C17, E18, F18, B18, B17** | 双目摄像头：`cam_data_1[0..4]` | 输入 |
| **C19** | 双目摄像头：`cam_vsync_1` | 输入 |
| **A19** | 双目摄像头：`cam_href_1` | 输入 |
| **D17** | 双目摄像头：`cam_rst_n_1` | 输出 |
| **A16** | 双目摄像头：`cam_pwdn_1` | 输出 |
| **A15** | 双目摄像头：`cam_pwdn_2` | 输出 |

（合计 34 个不同的 J6 引脚在指南中被实际使用并验证。`guide: 16.5 下载验证`、`guide: 表 16.5.1`、`guide: 24.5 下载验证` XDC、`guide: 表 8.5.1`）

### 5.5 哪些排针引脚"不自由"

- 指南**没有**列出"被板载外设占用、扩展口上不可用"的排针引脚清单 —— **not found in document**。
- 指南的通用注意事项是：*"当你想使用某个 IO 口用作其他用处的时候，请先看看开发板的原理图，确认一下该 IO 口是否有连接在开发板的某个外设上"*（`guide: 2.3 开发板使用注意事项`）。
- 从设计上推断（guide 的表述支持）：两组扩展口的 96 个 IO 是**独立引出的 FPGA IO**（J5 = Bank15，J6 = Bank16），而所有板载外设（DDR3→Bank35、HDMI、以太网、LCD、UART、SD、EEPROM、FLASH、按键、LED）都挂在**其它 Bank**；`guide: 1.2.1` 的硬件资源框图也是把 J5/J6 与各外设分别挂到不同 Bank。**但请务必以原理图为准**。
- ⚠️ **易混淆点**：`guide: 表 2.1.1 管脚分配` 里出现的 `ddr3_dq[13] inout **J5**` 与 `ddr3_addr[10] output **J6**` 是 **DDR3 在 Bank35 上的 BGA 球号（ball name）**，**不是**扩展排针 J5/J6。同样，`clk_100m` 等也可能是 IO 球号巧合。写 XDC 时不要把它们当排针。

---

## 6. 指南中的高速 AD/DA 示例（这是"已知可行的并行 ADC 接法"）

### 6.1 指南文档化的 AD/DA 模块型号

| 模块 | 芯片 | 速率 | 位宽 | 精度 | 指南中是否有专章 | 出处 |
|---|---|---|---|---|---|---|
| **ATK-HS-AD-DA（高速 AD/DA 模块）** | AD 侧 **3PA9280 / AD9280**（3PEAK / ADI，兼容）；DA 侧 **3PD9708 / AD9708** | AD **32 MSPS**；DA **125 MSPS** | 均 **8 bit** | — | ✅ **有专章：第十六章 高速AD/DA实验** | `guide: 1.4 外设五` · `guide: 16.1 高速AD/DA模块简介` |
| **ATK_DUAL_HS_AD（双路高速 AD 模块）** | not found in document（未给芯片型号） | **50 MSPS** | **10 bit** | ±0.9 LSB | ❌ 仅在 1.4 节介绍，**无专章、无接口表** | `guide: 1.4 外设三` |
| **ATK_DUAL_HS_DA（双路高速 DA 模块）** | not found in document | **125 MSPS** | **10 bit** | ±0.5 LSB | ❌ 仅在 1.4 节介绍，无专章 | `guide: 1.4 外设四` |
| AN108 / AN9238 / AD9226 类模块 | **not found in document** —— 正点原子指南**完全没有**提到 AN108/AN9238/AD9238/AD9226 | — | — | — | — | — |

> ⚠️ 注意：**正点原子指南里没有任何 AD9238 相关内容**。它文档化的并行 ADC 只有 **AD9280/3PA9280（8-bit, 32 MSPS）**，其接口与 AD9238 模块**不兼容**（见下表）。

### 6.2 ATK_HS_AD_DA 模块 40 针接口定义（表 16.2.1 原样复刻）

| 引脚号 | 引脚名 | 引脚说明 |
|---|---|---|
| 1 | VCC | 模块供电脚，5V |
| 2、4 | GND | 模块地脚 |
| 5~12 | AD_DATA | 模块输出的 8 位 ADC 数据 |
| 13 | AD_OTR | ADC 反馈信号，为高时表示超出量程 |
| 14 | AD_CLK | **需要外部提供的** ADC 驱动时钟 |
| 16 | DA_CLK | **需要外部提供的** DAC 驱动时钟 |
| 17~24 | DA_DATA | 模块接收的 8 位 DAC 数据 |

（`guide: 表 16.2.1 ATK-HS-AD-DA模块接口与功能描述`）
其余引脚号（3、15、25…40）：**not found in document**。

**接口结构总结**：单一 40 针（2×20）排母插到 **J6**；**ADC 没有 DCO 输出**——时钟由 **FPGA 提供**（`ad_clk`），数据是纯并行同步回读；有 **OTR** 输出；模拟侧为 SMA/测试孔，AD 输入经衰减电路 `VO = VI/5 + 1`（±5V → 0~2V），DA 输出经运放 + 滑动变阻器 RV1 调幅到 ±5V。

### 6.3 例程结构（第十六章）

| 项目 | 内容 | 出处 |
|---|---|---|
| 顶层模块名 | **`hs_ad_da`** | `guide: 16.4.6 顶层模块设计` |
| 子模块 | ① **PLL/时钟模块 `clk_wiz_0`**（输出 50 MHz、25 MHz、25 MHz 相移 120°）；② **ROM IP `rom_256x8b`**（BMG 单端口 ROM，8bit×256，用 COE 初始化正弦波）；③ **`da_wave_send`**（读 ROM + 产生 DA 数据与 DA 时钟）；④ 顶层例化的 **ILA `ila_0`** | `guide: 16.4.3 ROM IP核配置` · `guide: 16.4.4 PLL IP核配置` · `guide: 16.4.5 DA波形数据发送模块设计` · `guide: 16.4.6` |
| 时钟方案 | 输入 50 MHz 板载晶振 → Vivado **Clock Wizard（Primitive 选 MMCM）** → **50 MHz 给 DAC/ROM 读时钟**、**25 MHz 给 ADC 驱动时钟**、**25 MHz 相移 120° 给 ILA 采样时钟** | `guide: 16.4.4 PLL IP核配置`（"Primitive 选择使用 MMCM，输入时钟频率改为板载晶振的频率 50MHz"） |
| 实际采样率 | **ADC 驱动时钟仅 25 MHz**（远低于 AD9280 的 32 MSPS 上限） | `guide: 16.4.6`（`assign ad_clk = clk_25m;`） |
| 数据采集方式 | **极简寄存器/直连采集**：`ad_data[7:0]` 直接进顶层，只把它和 `ad_otr` 接到 ILA 观察；**不做源同步采样、不用 IDDR/ISERDES、不加输入打拍** | `guide: 16.4.6 顶层模块设计`（顶层端口即 `input [7:0] ad_data`、`input ad_otr`） |
| 关键设计要点（原文） | "为了避免数据沿带来的毛刺，在线逻辑分析仪采样时钟…要与 **ADC 驱动时钟的频率相同，相位相反（即相位偏移 180 度）**，但是实际测试发现不偏移 180 度的话…效果会更好…可以通过调整在线逻辑分析仪采样时钟的相位来消除毛刺"；DAC 侧相反："理论上 da_clk 是需要取反的，但在实际测试中发现，直接取反会造成波形存在大量毛刺，这里将取反取消" | `guide: 16.4.1 总体模块设计` |
| FIFO / BRAM 缓冲 | 本章**没有 FIFO 或 BRAM 缓冲**（只有 ROM 存波形）；BRAM 缓冲的范例在 **DDR3 读写测试**与 **双目 OV5640 + DDR3** 章节（用 MIG + FIFO 做位宽转换/乒乓） | `guide: 16.x`（无） · `guide: 17.4` · `guide: 24.4` |
| 测试波形生成 | **上位机 WaveToMem.exe** 生成正弦/方波/锯齿波/三角波的波形文件（位宽 8、深度 256），导出 **COE/MIF/DAT**，再用 BMG IP 生成 ROM；频率靠 `FREQ_ADJ` 参数调节（默认 5 → 输出约 **32.55 kHz**；`FREQ_ADJ=0` 时最高约 **195.3 kHz**） | `guide: 16.4.2 WaveToMem上位机的使用` · `guide: 16.4.5` |
| 软件延时/位数说明 | `da_wave_send` 端口：`clk`(50MHz)、`rst_n`、`rd_data[7:0]`、`rd_addr[7:0]`、`da_clk`、`da_data[7:0]` | `guide: 表 16.4.2` |
| ILA 使用注意 | ILA 采样时钟 25 MHz，而 JTAG 下载器默认时钟 15 MHz，不满足"ILA 采样时钟 ≥ JTAG 时钟 × 2.5"的要求 → **必须把下载器时钟降到至少 10 MHz**，否则采不到数据 | `guide: 16.5 下载验证` |

### 6.4 对"把 AD9238 接到这块板"的直接含义

- 正点原子官方演示过的并行 ADC 接法是：**FPGA 提供采样时钟 → 用普通 IO 直接并行回读数据 → 交给 ILA 观察**；没有源同步（无 DCO）、没有 IDDR。AD9238 模块**有** DCO（`CHx_CLK`），所以我们可以做得比官方例程更好：用 DCO 做源同步采样。
- 官方例程的 ADC 只有 8 位 + 1 根 OTR + 1 根 clk = **10 根线**；AD9238 双通道需要 **24 数据 + 2 DCO + 2 OTR = 28 根线**，必须**占用 J6 的 28 个 IO**（J6 只有 48 个 IO），**不可能再插官方 AD/DA 模块**。若还要 DA，需另找 J5。
- 8 位 ADC 的引脚分布（`ad_data[0..7]`：F13,F14,E13,E14,F16,E17,C13,B13；`ad_clk`：D16；`ad_otr`：E16；`da_*`：见 §5.4）说明 **J6 上有一大片连续、可用的 3.3V IO**，适合放 24 位并行总线。
- 用 65 MHz 时**必须注意**：官方例程只跑 25 MHz，且用 ILA 直接观察。65 MHz 的 24 位捕获需要用 MMCM 生成时钟、给 DCO 加 `create_clock`、并做 `set_input_delay` 约束（`set_input_delay` 在整本指南中**未出现** → not found in document）。

---

## 7. 指南中的 XDC 约束示例（原文复刻）

### A. 点亮 LED / 按键 / 流水灯 / 呼吸灯等基础实验
```tcl
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN W9 IOSTANDARD LVCMOS33} [get_ports {key[0]}]
set_property -dict {PACKAGE_PIN Y9 IOSTANDARD LVCMOS33} [get_ports {key[1]}]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
```
（`guide: 第五章 5.8.1 引脚约束`、`guide: 第六章`、`guide: 第七章`）

### B. PLL 实验（**唯一使用 J6 排针的基础实验**）
```tcl
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVCMOS33} [get_ports clk_100m]
set_property -dict {PACKAGE_PIN D22 IOSTANDARD LVCMOS33} [get_ports clk_100m_180deg]
set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS33} [get_ports clk_50m]
set_property -dict {PACKAGE_PIN B22 IOSTANDARD LVCMOS33} [get_ports clk_25m]
```
（`guide: 表 8.5.1` + `guide: 8.5 下载验证`。G21/D22/D21/B22 明确是 **J6** 上的脚）

### C. UART 串口实验
```tcl
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVCMOS33} [get_ports uart_txd]
```
（`guide: 12.5 下载验证`）

### D. 高速 AD/DA 实验（**J6 排针 + LVCMOS33**，本工程最相关的一条）
```tcl
set_property PACKAGE_PIN V4  [get_ports sys_clk]
set_property PACKAGE_PIN U7  [get_ports sys_rst_n]
set_property PACKAGE_PIN D14 [get_ports {da_data[7]}]
set_property PACKAGE_PIN D15 [get_ports {da_data[6]}]
set_property PACKAGE_PIN A15 [get_ports {da_data[5]}]
set_property PACKAGE_PIN A16 [get_ports {da_data[4]}]
set_property PACKAGE_PIN C14 [get_ports {da_data[3]}]
set_property PACKAGE_PIN C15 [get_ports {da_data[2]}]
set_property PACKAGE_PIN B15 [get_ports {da_data[1]}]
set_property PACKAGE_PIN B16 [get_ports {da_data[0]}]
set_property PACKAGE_PIN A14 [get_ports da_clk]
set_property PACKAGE_PIN F13 [get_ports {ad_data[0]}]
set_property PACKAGE_PIN F14 [get_ports {ad_data[1]}]
set_property PACKAGE_PIN E13 [get_ports {ad_data[2]}]
set_property PACKAGE_PIN E14 [get_ports {ad_data[3]}]
set_property PACKAGE_PIN F16 [get_ports {ad_data[4]}]
set_property PACKAGE_PIN E17 [get_ports {ad_data[5]}]
set_property PACKAGE_PIN C13 [get_ports {ad_data[6]}]
set_property PACKAGE_PIN B13 [get_ports {ad_data[7]}]
set_property PACKAGE_PIN D16 [get_ports ad_clk]
set_property PACKAGE_PIN E16 [get_ports ad_otr]

set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports da_clk]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports ad_clk]
set_property IOSTANDARD LVCMOS33 [get_ports ad_otr]
```
（`guide: 表 16.5.1 高速AD-DA转换实验管脚分配` + `guide: 16.5 下载验证`）
⚠️ **文档内部矛盾**：表 16.5.1 写 `ad_otr input D16` / `ad_clk output E16`，而紧随其后的 XDC 写 `D16 → ad_clk`、`E16 → ad_otr`。**以实测/原理图为准。**

### E. DDR3 读写测试（含配置位流属性，可直接借鉴）
```tcl
############## NET - IOSTANDARD ######################
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
#############SPI Configurate Setting##################
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
#############clock and reset Setting##################
create_clock -period 20 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_clk}]
set_property PACKAGE_PIN V4 [get_ports {sys_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst_n}]
set_property PACKAGE_PIN U7 [get_ports {sys_rst_n}]
#############led Setting##############################
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN AB21 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN AB22 [get_ports {led[1]}]
```
（`guide: 17.5 下载验证`。**注意：DDR3 的 43 根引脚由 MIG IP 核自动生成 XDC，指南未贴出**）

### F. FLASH 读写实验（专用 CCLK 走 STARTUPE2）
```tcl
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
create_clock -period 20 [get_ports sys_clk]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports spi_cs]
set_property -dict {PACKAGE_PIN P22 IOSTANDARD LVCMOS33} [get_ports spi_mosi]
set_property -dict {PACKAGE_PIN R22 IOSTANDARD LVCMOS33} [get_ports spi_miso]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports led]
```
（`guide: 表 18.5.1` + `guide: 18.5 下载验证`。`spi_clk` 未分配 IO，而是通过 **STARTUPE2** 的 `USRCCLKO` 引到配置专用时钟）

### G. Micro SD 卡（SPI 模式）
```tcl
create_clock -period 20 [get_ports sys_clk]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN T21 IOSTANDARD LVCMOS33} [get_ports sd_miso]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports sd_cs]
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports sd_mosi]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports sd_clk]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports led]
```
（`guide: 表 19.5.1 SD卡读写测试实验管脚分配` + `guide: 19.5 下载验证`）

### H. 以太网 MDIO / ARP / UDP（RGMII，全部 LVCMOS33）
```tcl
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports eth_rst_n]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports eth_mdc]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports eth_mdio]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports eth_rxc]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports eth_rx_ctl]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[3]}]
set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVCMOS33} [get_ports eth_txc]
set_property -dict {PACKAGE_PIN AB18 IOSTANDARD LVCMOS33} [get_ports eth_tx_ctl]
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {eth_txd[3]}]
```
（MDIO 部分来自 `guide: 第二十章 MDIO读写测试实验 / 20.5 下载验证`；rxd/rxc/txd 部分来自 `guide: 第二十一章 以太网ARP测试实验 / 21.5 下载验证`）

### I. HDMI 彩条显示（**IO 标准 TMDS_33**）
```tcl
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]
set_property -dict {PACKAGE_PIN N13 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[2]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports tmds_oen]
```
（`guide: 14.5 下载验证`；另外代码里 4 个 **OBUFDS** 显式带 `.IOSTANDARD("TMDS_33")`）

### J. 双目 OV5640 摄像头（**唯一带 `create_clock` + `IOB TRUE` + `CLOCK_DEDICATED_ROUTE FALSE` 的扩展口 XDC —— 最接近我们要写的 24-bit 并行采集约束**）
```tcl
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets sys_clk]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]

#HDMI接口
set_property -dict {PACKAGE_PIN N13 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[2]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD TMDS_33} [get_ports {tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports tmds_oen]

#DUAL CAMERA
#J6 扩展口
#摄像头1接口的时钟
create_clock -period 40.000 -name cmos_pclk [get_ports cam_pclk_1]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cam_pclk_1_IBUF]
set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33} [get_ports cam_scl_1]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports cam_sda_1]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[0]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[1]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[2]}]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[3]}]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[4]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[5]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[6]}]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_1[7]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports cam_pclk_1]
set_property -dict {PACKAGE_PIN C19 IOSTANDARD LVCMOS33} [get_ports cam_vsync_1]
set_property -dict {PACKAGE_PIN A19 IOSTANDARD LVCMOS33} [get_ports cam_href_1]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports cam_rst_n_1]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports cam_pwdn_1]

#摄像头2接口的时钟
create_clock -period 40.000 -name cmos_pclk [get_ports cam_pclk_2]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cam_pclk_2_IBUF]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports cam_scl_2]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports cam_sda_2]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[0]}]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[1]}]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[2]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[3]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[4]}]
set_property -dict {PACKAGE_PIN E14 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[5]}]
set_property -dict {PACKAGE_PIN E13 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[6]}]
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data_2[7]}]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports cam_pclk_2]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports cam_vsync_2]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports cam_href_2]
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS33} [get_ports cam_rst_n_2]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports cam_pwdn_2]
```
（`guide: 24.5 下载验证`，注释原文为 `#DUAL CAMERA` / `#J6 扩展口`）

### 附录：`guide: 表 2.1.1 管脚分配`（完整外设引脚表，原文复刻，仅列信号名/方向/引脚/说明）

| 信号名 | 方向 | 管脚 | 端口说明 |
|---|---|---|---|
| sys_clk | input | **V4** | 系统时钟 |
| sys_rst_n | input | **U7** | 系统复位，低有效 |
| key0 / key1 | input | **W9 / Y9** | 按键 0 / 按键 1 |
| led0 / led1 | output | **AB21 / AB22** | LED0 / LED1 |
| uart_rxd / uart_txd | input / output | **T20 / W21** | UART 的接收 / 发送 |
| phy_rst_n | output | **V18** | 以太网复位信号 |
| eth_mdio | inout | **T18** | PHY 管理接口双向数据 |
| eth_mdc | output | **R18** | PHY 管理接口时钟 |
| eth_txc | output | **AA18** | RGMII TX_CLK |
| eth_txd[0..3] | output | **R14 / P14 / U18 / U17** | RGMII TX_D0..D3 |
| eth_tx_ctl | output | **AB18** | RGMII TX_CTL |
| eth_rxc | input | **Y18** | RGMII RX_CLK |
| eth_rxd[0..3] | input | **W17 / V17 / AB20 / AA19** | RGMII RX_D0..D3 |
| eth_rx_ctl | input | **V19** | RGMII RX_CTL |
| sd_clk | output | **U22** | SD 卡时钟 |
| sd_cs | output | **R19** | SD 卡片选 |
| sd_miso | input | **T21** | SD 卡数据发送管脚（原文） |
| sd_mosi | output | **V22** | SD 卡数据接收管脚（原文） |
| sd_cd | input | **P20** | SD 卡插拔检测 |
| iic_scl / iic_sda | output / inout | **W22 / AA20** | EEPROM IIC 时钟 / 数据 |
| lcd_rgb[0..23] | inout | **V5, AB1, AA4, AA1, Y3, Y1, Y4, W1, W7, Y7, V7, AB5, Y6, AB3, AA3, U6, V9, AB8, V8, AB7, AA8, AB6, Y8, AA6** | RGB LCD 蓝/绿/红 各 8 位 |
| lcd_hs / lcd_vs / lcd_de / lcd_bl / lcd_pclk / lcd_rst | output | **AB2 / T1 / W2 / Y2 / U1 / R2** | 行同步 / 场同步 / 数据使能 / 背光 / 像素时钟 / 复位 |
| touch_scl / touch_sda / touch_int / touch_rst_n | output / inout / inout / output | **T4 / U5 / T5 / W4** | 触摸 IIC SCL / SDA / 中断 / 复位 |
| hdmi_data_p[2..0] | output | **N13 / P15 / N17** | TMDS 数据通道 2/1/0（正极） |
| hdmi_clk_p | output | **W19** | TMDS 时钟通道（正极） |
| hdmi_out_en / hdmi_hpd / hdmi_scl / hdmi_sda | output / input / output / inout | **U20 / V20 / R17 / P16** | HDMI 输入输出切换 / 热插拔 / IIC SCL / IIC SDA |
| spi_cs / spi_mosi / spi_miso | output / output / input | **T19 / P22 / R22** | FLASH 片选 / MOSI / MISO |
| ddr3_* | inout/output | **C2,G1,A1,F3,B2,F1,B1,E2,H3,G3,H2,H5,J1,J5,K1,H4**（dq[0..15]）等 | DDR3 数据/地址/控制（完整 43 项见原文；**此处的 `J5`/`J6` 是 BGA 球号**） |

---

## 8. FMC / 高引脚数连接器

- **FMC：not found in document**（指南全文未出现 FMC/FMC HPC 之类的字样）。
- 板上**最高引脚数**的可扩展连接器就是 **J5 + J6 两组 2×26 排针，合计 96 个 3.3V-capable FPGA IO**。
- 对 **24+ 位并行总线**的适用性：
  - 单组 J6 提供 **48 个 IO**，足够 **AD9238 双通道所需的 28 根线**（24 数据 + 2 DCO + 2 OTR）。
  - 已由官方例程验证 **J6 上至少 34 个脚可用**（见 §5.4）。
  - J6 是 **2.54 mm 排针**，不是高速连接器：官方反复提示扩展口模块要"**注意电源引脚方向**"，且 AD 类模块官方推荐**板对板**连接（`guide: 16.5 下载验证`）。65 MSPS × 2 通道 = 每通道 65 MHz 时钟 + 12 根数据（约 780 Mbps/通道），在 2.54mm 排针 + 3.3V LVCMOS 下属于**临界可用**，务必：短线、共地充分、同 Bank 布线。
  - **J5 的引脚名在指南中完全没出现**（无任何例程使用 J5），若要同时接 DA 或第二片 ADC，必须查原理图。

---

## 9. 明确的"文档里没有"清单 (not found in document)

- J5 / J6 的 **52 针完整"针号 → FPGA 引脚"对照表**（只有图片 `图 2.2.20 扩展 IO口`、`图 1.3.2 开发板背面扩展口引脚丝印`）
- **J5 上任一引脚的名称**
- 50 MHz 系统时钟的**差分 N 端引脚号**
- 板载**音频 codec / 音频接口**
- **VGA 接口**、**FMC 连接器**
- 除 SD 卡外的 **SDRAM** 器件
- AD9238 / AN9238 / AN108 / AD9226 相关任何内容
- `set_input_delay` / `set_output_delay` / `set_false_path` 等**外部接口时序约束示例**（全文只有 `create_clock`）
- 扩展口"哪些引脚被板载外设占用"的清单
- **ATK_DUAL_HS_AD / ATK_DUAL_HS_DA 的接口引脚表**（仅 1.4 节简单介绍，无专章）
