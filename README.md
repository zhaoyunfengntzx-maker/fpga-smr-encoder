# 基于 SMR 磁阻传感器与 FPGA 的高精度细分磁编码器

**A software-defined, high-resolution magnetic encoder on a Xilinx Artix-7 FPGA.**
用一片 FPGA 软件化实现 iC-Haus **iC-TW28**（10-bit 正余弦细分器）的全部功能，
并用 **12-bit 双通道同步 ADC + 六参数闭式标定 + 16-bit 全流水 CORDIC + PI 跟踪环**
把分辨率与精度做得比原专用芯片更高。

`MIT License` · `Vivado 2026.1` · `XC7A35TFGG484-2` · `纯 RTL（无 PS / 无 PYNQ）` · 中文文档

> 2026 年第九届全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 ·
> AMD 赛道 · 自主选题（初级）。仓库内不含学校、院系、指导教师、团队与个人信息。

---

## 1. 这是什么

磁编码器用 SMR 磁阻传感头读出转子位置：传感头输出两路正交的 `sin/cos` 电压，
信号调理后由 ADC 采样，FPGA 实时算出**绝对电角度**，再输出编码器行业标准的
**ABZ / UVW / SPI / UART** 接口，并驱动一块 7 英寸触摸屏显示波形与诊断信息。

进口专用细分芯片（iC-TW28）把分辨率锁在 10 bit、算法是黑盒、接口固定。本项目把
这件事整体搬到通用 FPGA 上：

- **分辨率 16 bit**（65,536 分之一圈），比 TW28 的 10 bit 细 64 倍；
- **六参数闭式标定**（两路偏置、两路增益、正交相位、共模）把复合畸变下的
  电角度误差从 **20.9839° 压到 0.0165°**（约 **1273 倍**，定点黄金模型/仿真口径）；
- **2048 p/r** 增量输出，真实转台实测 **719–740 rpm**、Z 索引 ≈12 Hz、UVW 六态均衡；
- 同一块板集成 **5 页 1024×600 触摸 UI** 与 **千兆以太网**（UDP 抓波 / 连续流）；
- 全部 RTL、定点模型、上位机、测试台、构建与签核脚本开源，证据可逐字节复核。

## 2. 关键指标（每个数字都能追到产物）

| 指标 | 值 | 口径 / 证据 |
|---|---|---|
| 角度分辨率 | **16 bit / 圈** | RTL 输出 `angle[15:0]`；[`deliverables/design_report.md`](deliverables/design_report.md) §3 |
| 标定后残余误差 | **0.0165°**（改善 1273×） | 六参数闭式标定，定点模型 + 仿真；报告 §3.1 / §6.2 |
| 增量输出 | **2048 p/r**（A 沿 4096/圈） | v74 生产位流，`ENC_V69_CPR2048`；报告 §11 |
| 转台实测转速 | **719–740 rpm**（稳态 719–731） | 2026-11-02 真实转台，[`deliverables/data/v74/README.md`](deliverables/data/v74/README.md) |
| 生产位流时序 | **WNS +0.409 ns / 0 失败端点（24,625）** | [`deliverables/data/v74/README.md`](deliverables/data/v74/README.md) |
| 生产位流资源 | **LUT 10,926 = 52.53%**，BRAM 32/50，DSP 17 | 同上（XC7A35T：20,800 LUT / 50 BRAM / 90 DSP） |
| 显示位流资源 | LUT **18,088 = 86.96%**，BRAM **48/50**，DSP 26，WNS **+0.175**（v85） | [`deliverables/data/v85/README.md`](deliverables/data/v85/README.md) |
| 仿真回归 | `sim/` **36 台**（v74 轮 36/36）+ `disp/` **18 台** | [`sim/logs/`](sim/logs/)、[`sim/README.md`](sim/README.md) |
| 以太网 | ping 5/5、连续流 62–63k pkt/s、10 min 99.89% | v62/v74 上板记录，报告 §10.6 |

> 口径约定：`[实测]` = 板级读数；`[仿真]` = xsim / 定点模型；`[构建签核]` = Vivado
> 报告。报告与 README 不把"构建通过"写成"上板通过"。完整版本演进见
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
 │  adc_capture      双通道对齐、IDDR 采样、坏样本检测                          │
 │       │                                                                      │
 │  calib           六参数闭式标定：ofs_s/ofs_c、gain_s/gain_c、phase_k、共模   │
 │       │                                                                      │
 │  cordic16        16-bit 全流水 CORDIC（atan2），每拍出一个电角度             │
 │       │                                                                      │
 │  loop / PI       跟踪环 + 速度估计 + 粗精融合 + 多周期计数                   │
 │       │                                                                      │
 │  abz_gen         A/B/Z 增量输出（2048 p/r，边沿率受限）                      │
 │  uvw_gen         U/V/W 换相输出（60° 分区，六态均衡）                        │
 │  spi_slave / uart_scope   寄存器访问与遥测帧                                 │
 │  scope_capture / eth/     28,672 点抓波 + 千兆 UDP 连续流                    │
 │  disp/            5 页 1024×600 触摸 UI（P1 总览 … P7 标定）                 │
 └──────────────────────────────────────────────────────────────────────────────┘
        │                                   │
        ▼                                   ▼
   ABZ / UVW / SPI / UART            千兆以太网（UDP）
        │                                   │
        └──────────────► 上位机 PySide6（波形 / 诊断 / 标定 / 回放）
```

**为什么是 FPGA**：50 MHz 单时钟域内要同时完成 12-bit 双通道采样、逐点标定、
流水 CORDIC、PI 环、ABZ/UVW 生成、抓波与 UI 扫描；任何一步换到 MCU 都会引入
不可接受的抖动或延迟。纯 RTL 也意味着没有 PS、没有 PYNQ、没有隐藏固件。

## 4. 仓库结构

```
FPGA/
├── README.md                 ← 本文件
├── rtl/                      ★ 编码器 RTL（24 个顶层模块 + eth/ 8 + ddr3/ 7）
│   ├── enc_top.v                 顶层：ADC → 标定 → CORDIC → 环路 → ABZ/UVW
│   ├── SPEC_interface_contract.md 接口契约（改代码前先改这里）
│   └── eth/                       MAC / ARP / ICMP / UDP / 连续流
├── disp/                     ★ 屏上 UI（36 个设计模块 + 19 台测试台）
├── sim/                      ★ 36 台编码器回归测试台 + 日志
├── model/                    定点黄金模型（与 RTL 逐位对齐）
├── host/                     ★ PySide6 上位机（42 个 .py + 自检）
├── tools/                    构建 / 仿真 / 签核 / 分析脚本
├── constr/                   XDC 约束（屏、触摸、以太网、引脚）
├── docs/                     开发日志、方案、复现与发布文档
├── skill/                    ★ 可复用技能包（8 项，含 README）
├── deliverables/             ★ 设计报告、证据索引、海报、提交包、data/ 证据归档
└── LICENSE / NOTICE           MIT + 第三方材料边界
```

### 与赛题 3.3.5.4 推荐目录的对照

指南允许非推荐结构，但要求在 README 给出对照表。本仓库所有目录名、文件名均为
纯 ASCII（小写字母、数字、下划线、连字符），中文只出现在文件正文。

| 指南推荐 | 本仓库 | 内容 |
|---|---|---|
| `README.md` | `README.md` | 项目简介、构建与复现入口 |
| `src/` | `rtl/`、`disp/`、`model/`、`host/` | RTL、屏 UI、定点模型、上位机 |
| `sim/` | `sim/` | 36 台编码器回归 + 日志 |
| `build/` | `tools/`、`constr/` | 综合/实现/签核脚本与约束 |
| `board/` | `tools/board_*.py`、`host/`、`_boardtest/` | 上板联调、定位、长跑脚本 |
| `data/` | `deliverables/data/` | 位流、时序/资源报告、SHA-256 清单 |
| `skill/` | `skill/` | 8 项技能包 + 使用说明 |
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
# 36 台编码器回归（rtl/*.v）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1

# 显示子系统回归（rtl + disp）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim_disp.ps1
```

每个测试台在独立工作目录编译，日志写到 `sim/logs/`，退出码 0 表示全绿。

### 5.3 综合与实现（需要 Vivado 2026.1）

```powershell
# 生产位流（编码器本体，无屏无网）
vivado -mode batch -source tools\impl_check_v74.tcl
#   -> _impl_v74/enc_top_v74.bit（1,512,664 B，BUILD 0x0018）

# 显示位流（编码器 + UI + 以太网）
vivado -mode batch -source tools\impl_check_disp_v74.tcl
#   -> _impl_disp_v74/enc_top_disp_v74.bit
```

两个脚本都会自动跑 `report_timing_summary`、`report_utilization`、`report_drc`、
`report_route_status`，并把报告留在 `_impl_*` 目录；签核口径见
[`tools/final_verify.ps1`](tools/final_verify.ps1)。

### 5.4 上板

1. 按 [`docs/30_flash_program_guide.md`](docs/30_flash_program_guide.md) 用 Vivado
   Hardware Manager（或 `_prog_v62.tcl` 样例）下载位流；
2. 串口连 `COMx`，跑 `python -X utf8 tools\board_eth_check.py --port COMx` 验 ping/UDP；
3. 按 [`deliverables/board_day_checklist.md`](deliverables/board_day_checklist.md)
   逐项记录屏、触摸、Z、UVW、长跑。

## 6. 验证与证据

- **仿真**：v74 轮 `sim/` 36/36 PASS（2026-11-02，逐台日志在 `sim/logs/`）；
  显示侧 18 台历史回归 + `tb_disp_smoke`（2026-11-03 15:41 PASS）。
- **构建签核**：生产位流 WNS **+0.409**、TNS 0、0 失败端点、DRC **0 Error**、
  布线 0 error；显示位流 v85 WNS **+0.175**、DRC 0 Error。
- **上板实测**：v74 生产位流 719–740 rpm、Z ≈12 Hz、UVW 六态均衡、
  以太网 ping + UDP 抓窗通过（见 [`deliverables/data/v74/README.md`](deliverables/data/v74/README.md)）。
- **证据链**：[`deliverables/evidence_index.md`](deliverables/evidence_index.md)
  把报告里的每个数字映射到具体文件/日志/哈希；
  [`deliverables/data/SHA256SUMS.txt`](deliverables/data/SHA256SUMS.txt) 收录 299 条，
  在 `deliverables/data/` 下执行 `sha256sum -c SHA256SUMS.txt` 可逐条复核。

## 7. 文档地图

| 文档 | 用途 |
|---|---|
| [`deliverables/design_report.pdf`](deliverables/design_report.pdf) | **主设计报告**（23 页，按竞赛模板，提交用） |
| [`deliverables/design_report_full.pdf`](deliverables/design_report_full.pdf) | 详细工程版（59 页，答辩技术底稿） |
| [`deliverables/technical_doc.pdf`](deliverables/technical_doc.pdf) | 精简技术文档（15 页） |
| [`deliverables/evidence_index.md`](deliverables/evidence_index.md) | 每个数字 → 可复核产物 |
| [`docs/README.md`](docs/README.md) | 文档总索引（按主题） |
| [`docs/REPRODUCE.md`](docs/REPRODUCE.md) | **从零复现**：环境、构建、上板、验收 |
| [`docs/BASELINES.md`](docs/BASELINES.md) | v62–v85 全部基线、资源/时序/上板状态 |
| [`docs/COMPLIANCE.md`](docs/COMPLIANCE.md) | 指南 §3.3.5 逐条对照与缺口登记（提交前自检） |
| [`docs/DEV_STATUS.md`](docs/DEV_STATUS.md) | 16k 行开发日志（任何结论的来龙去脉） |
| [`docs/ai-collaboration-log.md`](docs/ai-collaboration-log.md) | 大模型协作记录（提示词、纠错轨迹） |
| [`skill/README.md`](skill/README.md) | 7 项可复用技能包：适用范围/用法/失效条件 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更与 v1.0.0 发布说明 |

## 8. 当前状态与诚实边界

| 版本 | 状态 |
|---|---|
| **v74 生产位流** | ★ **时序签核 + 真实转台上板验收**（2026-11-02）：`BUILD 0x0018`、1,512,664 B、WNS +0.409、LUT 52.53%。参赛提交与时序口径以它为准 |
| **v85 显示位流** | **构建签核 + 已下载**（2026-11-03 16:50）：`PROGRAMMED_OK`、WNS +0.175、LUT 86.96%、BRAM 48/50；**尚未逐页目视验收**，不得写成"已上板验收" |
| v62 | 参赛演示基线：编码器 + 5 页 UI + 千兆网，2026-10-23 上板 |
| v70 / v71 / v73 | 转台适配与 Z 索引修复的历史里程碑，详见 [`docs/BASELINES.md`](docs/BASELINES.md) |

已知限制（完整清单见报告 §7）：

- v85 UI 未做逐页目视验收；显示位流 BRAM 已 96%，**没有余量再加整页/帧缓冲**。
- 纯 RTL 方案，**无 PS / PYNQ**，因此不申报指南里的"通用 PYNQ Skill"加分。
- 上位机以 Windows 为主（使用 `winreg` 等），其他平台需自行适配。
- 仓库包含约 233 MB 证据归档（位流、报告、CSV），克隆较慢；只取代码时可浅克隆。

## 9. 从零复现

一份可照着执行的完整步骤（含 Vivado 安装、约束、烧写、验收判据）见
[`docs/REPRODUCE.md`](docs/REPRODUCE.md)。最短路径：

```powershell
git clone <this-repo> && cd FPGA
python -m pip install -r host/requirements.txt
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1
vivado -mode batch -source tools\impl_check_v74.tcl
# 烧写 _impl_v74/enc_top_v74.bit，按 docs/30 与 board_day_checklist.md 验收
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
