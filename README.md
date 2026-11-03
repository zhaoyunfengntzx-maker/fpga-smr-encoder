# 基于 SMR 磁阻传感器与 FPGA 的高精度细分磁编码器

**A software-defined, high-resolution magnetic encoder on a Xilinx Artix-7 FPGA.**

用一片 FPGA 完成正余弦细分所需的全部信号链：**12-bit 双通道同步采样 → 六参数闭式标定 →
16-bit 全流水 CORDIC → PI 跟踪环 → ABZ / UVW / SPI / UART**，并在同一颗器件上驱动
**7 英寸 1024×600 触摸屏**与**千兆以太网**。全部功能由可读、可仿真、可复现的 RTL 实现，
不依赖处理器系统（无 PS、无 PYNQ、无隐藏固件）。

`MIT License` · `Vivado 2026.1` · `XC7A35TFGG484-2` · `纯 RTL` · 中文文档

**仓库**：<https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder>（`main`）

> 2026 年第九届全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 ·
> AMD 赛道 · 自主选题（初级组）。仓库内不含学校、院系、指导教师、团队与个人信息。

---

## 1. 这是什么

磁编码器用 SMR 磁阻传感头读出转子位置：传感头输出两路正交的 `sin/cos` 电压，经调理后由
ADC 采样，FPGA 实时解算出**绝对电角度**，再输出编码器行业标准的 **ABZ / UVW / SPI / UART**
接口，并可在本机屏幕上直接看波形、改参数、查故障。

传统做法是用一颗**专用细分 ASIC** 完成"sin/cos → 角度 → 增量脉冲"。这类器件把分辨率、
补偿算法与寄存器语义都固化在硅片里：分辨率通常停在 10 bit 量级，标定是固定步长的黑盒流程，
接口与寄存器由厂商单方面定义。对教学、二次开发与国产化替代场景而言，它是一颗"只能接线、
不能修改"的器件。

本项目把这条链整体搬进通用 FPGA，做成一份**可演进的 RTL 设计**：

- **16 bit 电角度分辨率**（65,536 分之一电周期），是 10 bit 专用方案的 **64 倍**；
- **六参数闭式标定**（两路偏置、两路增益、正交相位、共模）把复合畸变下的电角度误差从
  **20.9839° 压到 0.0165°**（约 **1273 倍**，定点黄金模型 / 仿真口径）；
- **2048 p/r** 增量输出；v90 在真实转台上以 Z 频率判据实测 **457–459 rpm**，
  Z 严格 **1 个/转**，UVW 六态均衡；
- 同一块板集成 **4 页可导航的 1024×600 触摸界面**（P1 总览 / P2 输入波形 / P4 逻辑时序 /
  P6 设置）与**千兆以太网**（UDP 抓波 / 连续流）；
- 全部 RTL、定点模型、上位机、测试台、构建与签核脚本开源，每个数字都能追到产物。

## 2. 关键指标（每个数字都能追到产物）

| 指标 | 值 | 口径 / 证据 |
|---|---|---|
| 角度分辨率 | **16 bit / 电周期** | RTL 输出 `angle[15:0]`；[`deliverables/design_report.md`](deliverables/design_report.md) §3 |
| 标定后残余误差 | **0.0165°**（改善 1273×） | 六参数闭式标定，定点模型 + 仿真；报告 §3.1 / §6.2 |
| 增量输出 | **2048 p/r**（A 沿 4096/圈） | `ENC_V69_CPR2048`；报告 §3.5 / §11 |
| 转台实测转速 | **457–459 rpm**（Z = 7.62–7.65 Hz） | 2026-11-04 真实转台，[`deliverables/data/v90/README.md`](deliverables/data/v90/README.md) |
| 内部角度一致性 | offset **1.76°**、RMS **0.71°**、max **2.88°** | `angle_vs_sc.py`，同一转台 3 s；报告 §6.7 |
| 生产位流时序 | **WNS +0.199 ns / 0 失败端点（24,691）**，WHS +0.017 | [`deliverables/data/v90/prod_timing.rpt`](deliverables/data/v90/prod_timing.rpt) |
| 生产位流资源 | **LUT 10,978 = 52.78%**，BRAM 32/50，DSP 17，位流 1,504,220 B | [`deliverables/data/v90/prod_util.rpt`](deliverables/data/v90/prod_util.rpt) |
| 显示位流 | WNS **+0.221**、LUT **17,090 = 82.16%**、BRAM **45.5/50**、位流 1,688,245 B | [`deliverables/data/v90/disp_util.rpt`](deliverables/data/v90/disp_util.rpt) |
| 仿真回归 | `sim/` **37/37** + `disp/` **20/20**（2026-11-04） | [`sim/logs/SUMMARY.md`](sim/logs/SUMMARY.md)、[`disp/logs/SUMMARY.md`](disp/logs/SUMMARY.md) |
| 以太网 | ping 4/4、UDP 抓窗 28,672 点 @50 MSPS | v90 板级判据 D 类，[`docs/39_acceptance_criteria_v90.md`](docs/39_acceptance_criteria_v90.md) |

> 口径约定：`[实测]` = 板级读数；`[仿真]` = xsim / 定点模型；`[构建签核]` = Vivado 报告。
> README 与报告都不把"构建通过"写成"上板通过"。完整版本演进见
> [`docs/BASELINES.md`](docs/BASELINES.md)。

## 3. 系统架构

```
 SMR 传感头（sin / cos，差分）
        │
        ▼
 AD9238 双通道 12-bit ADC ── 与 FPGA 同源时钟、源同步接口
        │
        ▼
 ┌─────────────────────────── Xilinx Artix-7 XC7A35T ───────────────────────────┐
 │  ad9238_capture   双通道对齐、IDDR 采样、坏样本检测                          │
 │       │                                                                      │
 │  sc_correct       六参数闭式标定：ofs_s/ofs_c、gain_s/gain_c、phase_k、共模   │
 │       │                                                                      │
 │  cordic_atan2     16-bit 全流水 CORDIC（atan2），每拍出一个电角度             │
 │       │                                                                      │
 │  loop_filter      跟踪环 + 速度估计 + 粗精融合 + 多周期计数                   │
 │       │                                                                      │
 │  abz_gen          A/B/Z 增量输出（2048 p/r，边沿率受限）                      │
 │  uvw_gen          U/V/W 换相输出（60° 分区，六态均衡）                        │
 │  spi_slave / reg_file       寄存器访问（SPI 从站 + 低 bank 映射）            │
 │  uart_scope / uart_spi_bridge  遥测帧 + 无 SPI 主机时的寄存器读写            │
 │  scope_capture / eth/       28,672 点抓波 + 千兆 UDP 连续流                   │
 │  disp/            4 页可导航的 1024×600 触摸 UI（P1/P2/P4/P6）                │
 └──────────────────────────────────────────────────────────────────────────────┘
        │                                   │
        ▼                                   ▼
   ABZ / UVW / SPI / UART            千兆以太网（UDP）
        │                                   │
        └──────────────► 上位机 PySide6（波形 / 诊断 / 标定 / 回放）
```

**为什么必须是 FPGA**：50 MHz 单时钟域内要同时完成双通道 12-bit 采样、逐点六参数校正、
17 级流水 CORDIC、PI 环、ABZ/UVW 生成、示波器抓波、以太网打包与 LCD 扫描。任何一步换到
MCU 都会引入不可接受的抖动或延迟；而纯 RTL 也意味着没有隐藏固件、没有"库函数黑盒"，
每一条延迟都能在源码里数出来。

## 4. 仓库结构

```
FPGA/
├── README.md                 ← 本文件
├── rtl/                      ★ 编码器 RTL（24 个模块 + eth/ 8 + ddr3/ 7 个未并入交付位流）
│   ├── enc_top.v                 顶层：ADC → 标定 → CORDIC → 环路 → ABZ/UVW
│   ├── SPEC_interface_contract.md 接口契约（改代码前先改这里）
│   └── eth/                       MAC / ARP / ICMP / UDP / 连续流
├── disp/                     ★ 屏上 UI（34 个设计模块 + 20 台测试台）
├── sim/                      ★ 37 台编码器回归测试台 + 日志
├── model/                    定点黄金模型（8 个脚本，与 RTL 逐位对齐）
├── host/                     ★ PySide6 上位机（57 个 .py + 自检）
├── tools/                    构建 / 仿真 / 签核 / 分析脚本
├── constr/                   XDC 约束（屏、触摸、以太网、引脚）
├── docs/                     方案、复现、验收判据、开发日志
├── skill/                    ★ 可复用技能包（11 篇方法长文 + 21 项可执行资产 + 通用 PYNQ 子包）
├── deliverables/             ★ 设计报告、技术文档、证据索引、海报、提交包、data/ 证据归档
└── LICENSE / NOTICE           MIT + 第三方材料边界
```

### 与赛题 §3.3.5.4 推荐目录的对照

指南允许非推荐结构，但要求在 README 给出对照表。本仓库所有目录名、文件名均为纯 ASCII
（小写字母、数字、下划线、连字符），中文只出现在文件正文。

| 指南推荐 | 本仓库 | 内容 |
|---|---|---|
| `README.md` | `README.md` | 项目简介、构建与复现入口 |
| `src/` | `rtl/`、`disp/`、`model/`、`host/` | RTL、屏 UI、定点模型、上位机 |
| `sim/` | `sim/` | 37 台编码器回归 + 日志 |
| `build/` | `tools/`、`constr/` | 综合/实现/签核脚本与约束 |
| `board/` | `tools/board_*.py`、`host/`、`_boardtest/` | 上板联调、定位、长跑脚本 |
| `data/` | `deliverables/data/` | 位流、时序/资源报告、SHA-256 清单 |
| `skill/` | `skill/` | 11 篇方法长文 + 21 项可执行资产（6 校验脚本 / 8 模板 / 7 提示词）+ 18 条踩坑清单；独立子包 `skill/pynq/` 另按 §3.3.2 申报 |
| `report/` | `deliverables/` | 设计报告、技术文档、证据索引、海报 |

## 5. 快速开始

### 5.1 只跑上位机（不需要板卡）

```powershell
python -m pip install -r host/requirements.txt
python -X utf8 host\app.py                 # 启动界面
python -X utf8 host\app.py --port COM4     # 启动并自动连接串口
```

离线自检（推荐先跑，不依赖硬件）：

```powershell
python -X utf8 host\regs.py --selftest
python -X utf8 host\analysis.py --selftest
$env:QT_QPA_PLATFORM="offscreen"; python -X utf8 host\selftest_ui.py
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_offline.ps1 -Quiet
```

### 5.2 跑仿真（需要 Vivado xsim）

```powershell
# 37 台编码器回归（rtl/*.v）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1

# 显示子系统回归（rtl + disp，20 台）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim_disp.ps1
```

每个测试台在独立工作目录编译，日志写到 `sim/logs/` 与 `disp/logs/`，退出码 0 表示全绿；
汇总写入各自的 `SUMMARY.md`。

### 5.3 综合与实现（需要 Vivado 2026.1）

```powershell
# 生产位流（编码器本体，无屏无网）
vivado -mode batch -source tools\impl_check_v90.tcl
#   -> _synth_work_v90/enc_top_v90.bit（1,504,220 B，BUILD 0x0019）

# 显示位流（编码器 + UI + 以太网）
vivado -mode batch -source tools\impl_check_disp_v90.tcl
#   -> _synth_work_v90/enc_top_disp_v90.bit（1,688,245 B）
```

两个脚本都会自动跑 `report_timing_summary`、`report_utilization`、`report_drc`、
`report_route_status`，并把报告留在输出目录；签核口径见
[`tools/final_verify.ps1`](tools/final_verify.ps1) 与
[`docs/39_acceptance_criteria_v90.md`](docs/39_acceptance_criteria_v90.md)。

### 5.4 上板

1. 按 [`docs/30_flash_program_guide.md`](docs/30_flash_program_guide.md) 用 Vivado
   Hardware Manager 下载位流，或把 `.mcs` 固化到 Flash；
2. 串口连 `COMx`，跑 `python -X utf8 tools\board_eth_check.py --port COMx` 验 ping/UDP；
3. 按 [`deliverables/board_day_checklist.md`](deliverables/board_day_checklist.md)
   逐项记录屏、触摸、Z、UVW、长跑。

## 6. 验证与证据

- **仿真**：`sim/` **37/37 PASS**（2026-11-04 00:49）、`disp/` **20/20 PASS**
  （2026-11-04 00:03），逐台日志在同目录 `logs/`。
- **构建签核**：生产位流 WNS **+0.199**、TNS 0、0 失败端点、DRC 0 Error、布线 0 error；
  显示位流 WNS **+0.221**、WHS +0.049、DRC 0 Error。
- **上板实测**：v90 生产位流在 2048 p/r 转台上以 Z 频率测得 **457–459 rpm**，
  Z 严格 1 个/转、UVW 六态均衡、以太网 ping + UDP 抓窗通过；显示位流已固化 Flash 并通过冷启动。
- **证据链**：[`deliverables/evidence_index.md`](deliverables/evidence_index.md)
  把报告里的每个数字映射到具体文件/日志/哈希；
  [`deliverables/data/SHA256SUMS.txt`](deliverables/data/SHA256SUMS.txt) 收录 **323 条**，
  在 `deliverables/data/` 下执行 `sha256sum -c SHA256SUMS.txt` 可逐条复核。

## 7. 文档地图

| 文档 | 用途 |
|---|---|
| [`deliverables/design_report.pdf`](deliverables/design_report.pdf) | **主设计报告**（按竞赛模板，提交用） |
| [`deliverables/design_report_full.pdf`](deliverables/design_report_full.pdf) | 详细工程版（答辩技术底稿） |
| [`deliverables/technical_doc.pdf`](deliverables/technical_doc.pdf) | 精简技术文档 |
| [`deliverables/project_intro.pdf`](deliverables/project_intro.pdf) | 项目简介（报名 / 展示用） |
| [`deliverables/evidence_index.md`](deliverables/evidence_index.md) | 每个数字 → 可复核产物 |
| [`docs/README.md`](docs/README.md) | 文档总索引（按主题） |
| [`docs/REPRODUCE.md`](docs/REPRODUCE.md) | **从零复现**：环境、构建、上板、验收 |
| [`docs/39_acceptance_criteria_v90.md`](docs/39_acceptance_criteria_v90.md) | v90 验收判据（A–E 五类逐项） |
| [`docs/BASELINES.md`](docs/BASELINES.md) | v62–v90 全部基线、资源/时序/上板状态 |
| [`docs/COMPLIANCE.md`](docs/COMPLIANCE.md) | 指南 §3.3.5 逐条对照与缺口登记（提交前自检） |
| [`docs/DEV_STATUS.md`](docs/DEV_STATUS.md) | 16k 行开发日志（任何结论的来龙去脉） |
| [`docs/ai-collaboration-log.md`](docs/ai-collaboration-log.md) | 大模型协作记录（提示词、纠错轨迹） |
| [`skill/README.md`](skill/README.md) | 可复用技能包：11 篇方法长文 + 21 项可执行资产，附自检 |
| [`skill/pynq/README.md`](skill/pynq/README.md) | **通用 PYNQ 技能包**（申报 §3.3.2） |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更与 v1.0.0 发布说明 |

## 8. 当前状态与诚实边界

| 版本 | 状态 |
|---|---|
| **v90 生产位流** | ★ **当前交付基线**（2026-11-04）：`BUILD 0x0019`、1,504,220 B、WNS +0.199 / 0 失败、LUT 52.78%。新增 `z_index_gen` 修 Z 停位喘振，板上 Z 严格 1 个/转 |
| **v90 显示位流** | ★ **已上板 + 已固化 Flash + 冷启动通过**：1,688,245 B、WNS +0.221、LUT 82.16%、BRAM 45.5/50；验收判据见 [`docs/39_acceptance_criteria_v90.md`](docs/39_acceptance_criteria_v90.md) |
| v85 / v89 显示位流 | 显示 UI 迭代（P2 三档 / 中线、P7 整页删除、删标定按钮），作为 v90 显示位流的前身 |
| v74 生产位流 | 历史基线（2026-11-02）：`BUILD 0x0018`、WNS +0.409、LUT 52.53% |
| v62 | 参赛演示基线：编码器 + UI + 千兆网，2026-10-23 上板 |
| v70 / v71 / v73 | 转台适配与 Z 索引修复的历史里程碑，详见 [`docs/BASELINES.md`](docs/BASELINES.md) |

已知限制（完整清单见报告 §7）：

- v90 显示位流 BRAM 已 91%、LUT 82%，**没有余量再加整页/帧缓冲**；P7 标定页已整页删除，
  标定改走 KEY0 长按或串口写 `0x0502=0x0001`。
- 转速判据以 **Z 频率**为准；`check_v70` 的「机械转速」由 16 位 `cycle_cnt` 推得，
  在 >8 kHz 电频率下会混叠（详见判据文档 §7）。
- `tools/board_eth_check.py` 的 ARP MAC 常量与板子回包不符（实测 `00-00-02-00-00-01`），
  该项不计入 FAIL。
- 内部角度一致性（RMS 0.71°）是"角度链路 vs 原始 sin/cos 重算"的一致性，不是 ±0.5″
  级别的绝对精度；外部角度基准仍缺（报告 §7 R15）。
- 本项目本体是纯 RTL 方案（**无 PS / PYNQ**）；另交了一份**不绑定本题的通用 PYNQ 技能包**
  [`skill/pynq/`](skill/pynq/README.md)，按 §3.3.2 申报加分。它只做"文件级可核验"的部分
  （`.hwh` 解析、位流与地址表配对、判据负对照），**上板路径未在本队硬件实测**——
  本机 Vivado 只装了 Artix/Kintex 器件族，这一点在 `skill/pynq/README.md` §4 写明了。
- 上位机以 Windows 为主（使用 `winreg` 等），其他平台需自行适配。
- 仓库包含约 230 MB 证据归档（位流、报告、CSV），克隆较慢；只取代码时可浅克隆。

## 9. 从零复现

一份可照着执行的完整步骤（含 Vivado 安装、约束、烧写、验收判据）见
[`docs/REPRODUCE.md`](docs/REPRODUCE.md)。最短路径：

```powershell
git clone <this-repo> && cd FPGA
python -m pip install -r host/requirements.txt
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1
vivado -mode batch -source tools\impl_check_v90.tcl
# 烧写 _synth_work_v90/enc_top_v90.bit，按 docs/30 与 board_day_checklist.md 验收
```

## 10. 参与贡献

欢迎 issue / PR：报告可复现性问题请附 `docs/REPRODUCE.md` 的步骤编号与日志；
代码改动请先看 [`CONTRIBUTING.md`](CONTRIBUTING.md) 与
[`rtl/SPEC_interface_contract.md`](rtl/SPEC_interface_contract.md)。
安全相关问题见 [`SECURITY.md`](SECURITY.md)。

## 11. 许可与引用

- 代码与文档：**MIT**，见 [`LICENSE`](LICENSE)；
- 第三方材料（开发板资料、厂商手册、模板）的边界见 [`NOTICE`](NOTICE)；
- 引用本仓库请使用 [`CITATION.cff`](CITATION.cff)。

## 12. 竞赛与匿名声明

本项目参加 2026 年第九届全国大学生嵌入式芯片与系统设计竞赛（AMD 赛道 · 自主选题）。
按竞赛要求，仓库与全部提交物**不含**学校、院系、校徽、指导教师、团队姓名、学号、
邮箱等身份信息；作品名称统一为"基于FPGA的细分编码器"。仓库以 MIT 协议开源，
允许再分发与二次开发。
