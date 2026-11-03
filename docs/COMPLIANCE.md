# 提交物对照表（2026 选题指南 §3.3.5）

> 本文件把《全国大学生嵌入式芯片与系统设计竞赛'2026 FPGA 创新设计赛道选题指南（AMD）》
> §3.3「自主选题赛道」的每一条要求，映射到仓库里的具体文件，并如实标注缺口。
> 评委可按本表逐项抽查；队友可按本表做提交前自检。
>
> **当前交付基线：v90（2026-11-04）。** 本文所有"当前基线"数字都来自
> [`../deliverables/data/v90/`](../deliverables/data/v90/)：
>
> - **生产位流** `enc_top_v90.bit`：1,504,220 B，SHA256 `A89512A5…7125`，
>   WNS **+0.199 ns** / TNS 0 / 0 失败端点（24,691），LUT **10,978 = 52.78%**，BRAM 32/50；
> - **显示位流** `enc_top_disp_v90.bit`：1,688,245 B，SHA256 `69FE313C…BAD4`，
>   WNS **+0.221 ns** / 0 失败端点（33,365），LUT **17,090 = 82.16%**，BRAM 45.5/50；
> - **仿真**：`sim/` **37/37 PASS** + `disp/` **20/20 PASS**（2026-11-04）；
> - **证据**：`deliverables/data/SHA256SUMS.txt` **323 条**哈希。
>
> 判据只有一份：[`39_acceptance_criteria_v90.md`](39_acceptance_criteria_v90.md)。
> 历史基线（v74 生产、v85/v89 显示）只作血缘对照，见 §1 表末"历史行"与 [`BASELINES.md`](BASELINES.md)。
>
> 指南原文：§3.3.5 提交内容、§3.3.3 设计与优化要求、§六 其它（决赛海报）。
> 状态只有三种：**已完成** / **部分完成（写缺口）** / **不适用（写原因）**。

## 0. 一句话

作品是**纯 RTL 的 FPGA 细分磁编码器**（XC7A35T + AD9238），本体不是 PYNQ/Zynq 作品。
它把"sin/cos 模拟输入 → 电角度 → 增量/串行输出"这条通常固化在**同类专用细分 ASIC**里的
信号链，在通用 FPGA 上做成了可参数化、可仿真、可复现的 RTL（16 bit/电周期分辨率，
ABZ+Z / UVW / SPI / UART / 1 GbE 五路并行输出，同片 4 页屏 UI）。
另交了一份**与本题解耦的通用 PYNQ 技能包** `skill/pynq/`，按 §3.3.2 申报加分（见 §2 末行）。

## 1. §3.3.5.1 工程包

| 指南要求 | 本项目对应文件 / 章节 | 状态 |
|---|---|---|
| 完整工程文件与源码（RTL/HLS/PS） | `rtl/`（24 个模块 + `rtl/eth/` 8；`rtl/ddr3/` 7 个为二期，未并入交付位流）、`disp/`（34 个设计模块 + 20 台测试台）、`host/`（57 个 `.py`，PySide6 上位机）、`model/`（8 个定点模型脚本）、`constr/`（XDC） | 已完成 —— 纯 RTL + 主机侧 Python，无 HLS、无 PS、无隐藏固件 |
| 仿真或验证结果，说明功能正确性如何确认 | `sim/` **37/37 PASS**、`disp/` **20/20 PASS**（2026-11-04；汇总在 `sim/logs/SUMMARY.md`、`disp/logs/SUMMARY.md`）、[`05_vivado_sim_impl_report.md`](05_vivado_sim_impl_report.md)、[`37_display_smoke_coverage.md`](37_display_smoke_coverage.md)；一键 `tools/run_sim.ps1` / `tools/run_sim_disp.ps1` | 已完成 —— 每台测试台独立工作目录编译，日志留档，退出码即判据 |
| 综合与实现报告（资源、时钟、关键性能） | [`../deliverables/data/v90/`](../deliverables/data/v90/)（`prod_timing.rpt` / `prod_util.rpt` / `prod_drc.rpt` / `prod_route.rpt` 与 `disp_*` 同名五件套、`*_impl.log`）、[`BASELINES.md`](BASELINES.md)、`tools/impl_check_v90.tcl` / `tools/impl_check_disp_v90.tcl` | 已完成 —— 生产 WNS +0.199 / 0 失败端点（24,691）、LUT 10,978（52.78%）；显示 WNS +0.221 / LUT 17,090（82.16%）；DRC 0 Error |
| 上板工程、运行脚本、实测输出与参考结果比对 | `host/`、`_boardtest/`（`check_v70.py`、`z_rate.py`、`uvw_phase.py`、`angle_vs_sc.py`、`soak_v68.py`）、`tools/board_*.py`、[`../deliverables/data/v90/README.md`](../deliverables/data/v90/README.md)、[`39_acceptance_criteria_v90.md`](39_acceptance_criteria_v90.md)、`deliverables/design_report.md` §6/§11 | 已完成 —— v90 生产位流：Z 7.62–7.65 Hz ⇒ **457–459 rpm**、UVW 六态 `{5174,4761,4423,4776,4763,4786}`、ping 4/4、UDP 抓窗 28,672 点 @50 MSPS；显示位流已固化 Flash 并通过冷启动 |
| 可复现的构建脚本 | `tools/make_v90_rtl.py` → `tools/impl_check_v90.tcl`（生产）/ `tools/impl_check_disp_v90.tcl`（显示）；`tools/program_bit.tcl`、`tools/run_sim.ps1`、`tools/final_verify.ps1`；步骤见 [`REPRODUCE.md`](REPRODUCE.md) | 已完成 —— 仓库根由 `[info script]` 推导，不依赖作者机器路径 |

> **历史行（不是当前基线）**：v74 生产位流（1,512,664 B、WNS +0.409、LUT 52.53%，2026-11-02）
> 与 v85 显示位流（1,699,249 B、WNS +0.175、LUT 86.96%）已被 v90 取代，
> 只在 [`BASELINES.md`](BASELINES.md) 里作血缘证据保留。

## 2. §3.3.5.2 技能包

| 指南要求 | 本项目对应文件 / 章节 | 状态 |
|---|---|---|
| 置于 `skill/`，README 说明适用范围、使用方法、失效条件 | [`../skill/README.md`](../skill/README.md)（9 节索引）+ 7 篇方法长文 + 6 个校验脚本 + 7 个模板 + 5 篇提示词 + 18 条踩坑清单（`pitfalls.md`） | 已完成 —— 每项写明适用场景 / 使用方法 / 已验证效果 / 失效条件 / 来源记录号；18 条踩坑逐条带 `**失效**` 行 |
| 提示词工作流 / 案例模板 / 校验脚本 / 踩坑清单 | 校验脚本 `skill/scripts/*.py`（含自检 `skill_selftest.py`、总入口 `run_all_checks.py`）；模板 `skill/templates/*`（7 个）；提示词 `skill/prompts/P1`–`P5`；踩坑清单 `skill/pitfalls.md` + 症状索引 `skill/pitfalls_index.md` | 已完成 —— 四类都是可直接复制 / 运行的资产，不是描述性文字；脚本自带夹具与负对照 |
| 可复用性（陌生队伍能否直接用） | `skill/README.md` §0 三步上手 + §7 换题目 / 换板卡 / 换 PYNQ 逐项移植表；脚本仅依赖 Python 标准库 | 已完成 —— 不绑定作者机器路径与具体板卡；样例数值取自真实报告（含失败回放），改阈值即可用于他题 |
| 通用 PYNQ Skill 加分（§3.3.2） | [`../skill/pynq/`](../skill/pynq/README.md)：`pynq_hwh.py`（`.hwh` 地址表 / 时钟域解析，判据 `ADDR-00x/01x`、`CLK-00x`、`REG-001`）、`pynq_bundle.py`（位流↔地址表配对 / 时间戳 / 两版对比）、`pynq_overlay.py`（上板 5 条判据 + `--mock`）、`pynq_selftest.py`（18 用例，含 `--emit-script` 生成物编译检查）、`pitfalls_pynq.md`（14 条，标 `[实测]/[文档]/[待验]`）、`prompts/P6–P7`、`examples/` | 部分完成 —— **已申报**且与本题解耦（面向 PYNQ 框架，换题目 / 换板卡可用）；缺口：上板路径未在本机 PYNQ 硬件实测，判据为**文件级**（`.hwh` 解析、位流配对）+ 夹具回放，见 `skill/pynq/README.md` §4 |

## 3. §3.3.5.3 设计报告

主文件：`deliverables/design_report.md`（及 `design_report.docx` / `design_report.pdf`；
详细工程版 `design_report_full.pdf`，精简版 `technical_doc.pdf`）。

| 指南要求 | 报告位置 | 状态 |
|---|---|---|
| 选题背景与创新点：为什么、解决什么、前人做过什么 | §1 需求与痛点（含光电编码器失效机理、同类专用细分 ASIC 的能力边界）、§8 创新点 | 已完成 |
| 设计原理与功能框图 | §2 系统方案（图 `deliverables/figures/block_diagram.png`）、§3 算法 | 已完成 |
| 软硬件划分依据与接口设计 | §2.2 关键架构决策、§4.1 模块层次、`rtl/SPEC_interface_contract.md`、§11.10 寄存器表 | 已完成 |
| 优化过程，含优化前后性能/资源对比表 | §4.2 资源与时序、§6.4 校正前后对比、§11.9–§11.11 版本优化记录、[`BASELINES.md`](BASELINES.md) 总表 | 已完成 —— 当前一行：v90 生产 WNS +0.199 / LUT 52.78% / BRAM 32/50，显示 WNS +0.221 / LUT 82.16% / BRAM 45.5/50（对比 v74 的 +0.409 / 52.53%、v85 的 +0.175 / 86.96%） |
| 大模型协作记录（提示词、回答、纠错轨迹、智能体工作流） | §13.1–§13.3；原始记录 [`ai-collaboration-log.md`](ai-collaboration-log.md)（279 KB） | 已完成 |
| 技能包提炼过程（从哪些失败、如何验证、边界） | §13.4 + `skill/*.md` 第 5 节 | 已完成 |
| 复现说明（从零可执行） | 附录 C + 独立文件 [`REPRODUCE.md`](REPRODUCE.md) | 已完成 —— 后者更新、更完整（含验收判据与 FAQ） |

## 4. §3.3.5.4 目录与命名

| 要求 | 现状 | 状态 |
|---|---|---|
| 仓库内目录 / 文件名纯英文（小写、数字、`_`、`-`） | `git ls-files` 无非 ASCII 路径；`python tools/check_anonymity.py --strict-new` 检查 | 已完成 |
| 中文只出现在正文 | 所有 `.md` / 报告正文为中文，路径为英文 | 已完成 |
| 推荐结构或 README 目录对照 | 未采用 `src/sim/build/board/data/report` 平铺，改为按工程域组织；根 `README.md` 有 §3.3.5.4 对照表 | 已完成 —— 指南允许，README 已给出逐目录映射 |

## 5. §3.3.5.5 评测项（自评口径，不是官方打分）

| 评测项 | 权重 | 本项目对应证据 | 状态 |
|---|---|---|---|
| 创新性与应用价值 | 30 | 把同类专用细分 ASIC 的信号链整体搬进通用 FPGA：六参数闭式标定 + 16 bit 全流水 CORDIC + 在线 4 页 UI / 千兆以太网，全部为可改可验的 RTL；报告 §8 | 已完成 |
| 性能与资源优化效果 | 20 | 20.9839° → **0.0165°**（1273×，`[仿真]`）；生产位流 WNS **+0.199**、LUT **52.78%**、BRAM 32/50；显示位流 WNS **+0.221**、LUT **82.16%**、BRAM 45.5/50；版本对比见 [`BASELINES.md`](BASELINES.md) | 已完成 |
| 功能正确性与设计完整性 | 20 | `sim/` **37/37** + `disp/` **20/20**；v90 两个位流均有上板 / 冷启动记录；判据逐项见 [`39_acceptance_criteria_v90.md`](39_acceptance_criteria_v90.md)；证据索引 `deliverables/evidence_index.md` | 已完成 |
| 大模型协作与技能包 | 15 | [`ai-collaboration-log.md`](ai-collaboration-log.md)、报告 §13、`skill/`（7 篇方法长文 + 可执行资产四类 + 通用 `pynq/` 子包） | 已完成 |
| 文档质量与可复现性 | 15 | 根 `README.md`、[`README.md`](README.md) 索引、[`REPRODUCE.md`](REPRODUCE.md)、[`BASELINES.md`](BASELINES.md)、[`COMPLIANCE.md`](COMPLIANCE.md)、`tools/final_verify.ps1` 与 CI 检查脚本 | 已完成 |

## 6. §3.3.3 硬约束

| 约束 | 现状 | 状态 |
|---|---|---|
| 工具版本 Vivado/Vitis 2026.1（推荐）或 2025.2 | 全部签核构建使用 **Vivado v2026.1**（v90 两位流的 `deliverables/data/v90/prod_impl.log` / `disp_impl.log` 头即版本行） | 已完成 |
| 提交大模型协作交互记录 | [`ai-collaboration-log.md`](ai-collaboration-log.md) + 报告 §13 | 已完成 |
| 提炼技能包随作品提交 | `skill/`（7 篇方法长文 + 四类可执行资产）；另有通用 PYNQ 子包 `skill/pynq/` | 已完成 |
| 声明具体器件并完成板级验证 | XC7A35TFGG484-2（达芬奇-lite）+ AD9238；v90 生产位流有转台实测（Z 频率判据 457–459 rpm），显示位流有 Flash 冷启动记录 | 已完成 |
| 开源（MIT 或 Apache-2.0） | `LICENSE` = MIT；`NOTICE` 列第三方边界 | 已完成 |
| 决赛一页英文海报（A4 彩打、不含队伍信息） | `deliverables/poster/poster_A4_EN.pptx` / `.pdf` / `.png`（另含 AMD 模板版 `poster_amd_official.*`） | 已完成 |

## 7. 如实登记的缺口

1. **显示位流资源余量很小**：BRAM **45.5/50（91%）**、LUT **82.16%**。再加整页 / 帧缓冲前必须先降分辨率或复用缓冲；P7 标定页已整页删除，标定改走 KEY0 长按或串口写 `0x0502=0x0001`。
2. **精度口径是内部一致性，不是绝对精度**：板级 `angle_vs_sc.py` 给出 offset 1.76°、RMS 0.71°、max 2.88°（"角度链路 vs 原始 sin/cos 重算"），**没有 ±0.5″ 级外部角度基准**（报告 §7 R15）；0.0165° 是定点黄金模型 `[仿真]` 口径。
3. **延迟 ≈830 ns 是设计值**（41.5 拍 @50 MHz），无外部实测（报告 §7 R6）。
4. **真实 SMR 传感头未接入**：板级验证用转台增量式正余弦编码器 + 信号源（报告 §7 R7）。
5. **`inclim` 偶发置位**（`0x0405` bit3，并入 `uvw_freq_warn`）不判故障；`check_v70.py` 的「机械转速」在高电频段混叠（621 rpm 为伪值），转速唯一权威判据是 `z_rate.py` 的 Z 频率。
6. **ARP MAC 断言与板子回包不符**（实测 `00-00-02-00-00-01`），该项按判据文档 §7 不计入 FAIL；如要消除，改脚本常量即可。
7. **停位 Z 喘振**已由 v90 `z_index_gen` 修复并以"每转 1 个 Z"验证；长时间停位专项复测建议在现场补一次。
8. **仓库体积偏大**（约 230 MB）：主要来自 `deliverables/data/` 的原始证据与位流；根 `README.md` 已给浅克隆建议，纯代码读者可只取 `rtl/ disp/ host/ model/ tools/`。
9. **上位机为 Windows 优先**：串口 / 以太网脚本在 Linux 下需把 `COMx` 改为 `/dev/ttyUSBx`，未做跨平台 CI。

## 8. 提交前自检命令

```powershell
powershell -File tools\final_verify.ps1      # v90 一条命令签核：源码↔位流一致、回归、两位流 SHA/时序、文档存在性
python tools\check_links.py                  # 文档相对链接 0 死链
python tools\check_anonymity.py --strict-new # 公开面 0 命中
python tools\check_names.py                  # 静态未定义名 0
python tools\check_citations.py              # "记录 N" 都能追到协作日志标题
python tools\check_regmap.py                 # 上位机 REG_* 全部在 RTL 可读
python skill\scripts\run_all_checks.py       # 技能包 + 仓库门禁一条命令
python skill\scripts\skill_selftest.py       # 技能包自检（含负对照）
python skill\pynq\pynq_selftest.py           # PYNQ 子包自检（含负对照）
python _boardtest\check_v70.py COM4 3        # 板上静态判据（B 类），末行须 PASS
python _boardtest\z_rate.py COM4 6           # 转速唯一权威判据（C 类）
```

哈希复核：在 `deliverables\data\` 下执行 `sha256sum -c SHA256SUMS.txt`（Linux）或按该目录
`README.md` §3 的 PowerShell 循环；**323 条**应全部 OK。
