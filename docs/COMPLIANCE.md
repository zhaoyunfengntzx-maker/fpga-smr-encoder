# 提交物对照表（2026 选题指南 §3.3.5）

> 本文件把《全国大学生嵌入式芯片与系统设计竞赛'2026 FPGA 创新设计赛道选题指南（AMD）》
> §3.3「自主选题赛道」的每一条要求，映射到仓库里的具体文件，并如实标注缺口。
> 评委可按本表逐项抽查；队友可按本表做提交前自检。
>
> 指南原文：§3.3.5 提交内容、§3.3.3 设计与优化要求、§六 其它（决赛海报）。

## 0. 一句话

作品是**纯 RTL 的 FPGA 细分磁编码器**（XC7A35T + AD9238），本体不是 PYNQ/Zynq 作品；
另交了一份**与本题解耦的通用 PYNQ 技能包** `skill/pynq/`，按 §3.3.2 申报加分（见 §2 末行）。

## 1. §3.3.5.1 工程包

| 指南要求 | 仓库位置 | 状态 / 说明 |
|---|---|---|
| 完整工程文件与源码（RTL/HLS/PS） | `rtl/`（24 个顶层 + `rtl/eth/` 8 + `rtl/ddr3/` 7）、`disp/`（36 个显示/UI 模块）、`host/`（PySide6 上位机 42 个 .py）、`model/`（定点黄金模型）、`constr/`（XDC） | ✅ 纯 RTL + 主机侧 Python，无 HLS/PS |
| 仿真或验证结果，说明功能正确性如何确认 | `sim/`（36 个测试台）、`disp/tb_*.v`（19 个）、`sim/logs/`、`docs/05_vivado_sim_impl_report.md`、`docs/37_display_smoke_coverage.md` | ✅ v74 轮 36/36 PASS（2026-11-02）；显示 18/18；一键脚本 `tools/run_sim.ps1` / `tools/run_sim_disp.ps1` |
| 综合与实现报告（资源、时钟、关键性能） | `deliverables/data/v74/`（生产签核）、`deliverables/data/v85/`（最新显示构建）、`docs/BASELINES.md`、`docs/05_vivado_sim_impl_report.md` | ✅ WNS/WHS、LUT/FF/BRAM/DSP/IOB、DRC、路径报告齐全 |
| 上板工程、运行脚本、实测输出与参考结果比对 | `host/`（串口/以太网/UI）、`tools/board_*.py`、`deliverables/data/v74/prog_*.log`、`docs/32_board_test_report_2026-11-01.md`、`docs/33_v70_release_report.md`、`deliverables/design_report.md` §6/§11 | ✅ v62/v70/v74 生产位流有上板记录；v85 显示位流只到「构建签核 + 已下载」，见 §5 缺口 |
| 可复现的构建脚本 | `tools/make_v74_rtl.py`、`tools/impl_check_v74.tcl`、`tools/impl_check_disp_v74.tcl`、`tools/program_bit.tcl`、`tools/run_sim.ps1` | ✅ 仓库根由 `[info script]` 推导，不再依赖作者机器路径 |

## 2. §3.3.5.2 技能包

| 指南要求 | 仓库位置 | 状态 / 说明 |
|---|---|---|
| 置于 `skill/`，README 说明适用范围、使用方法、失效条件 | `skill/README.md`（9 节索引）+ 7 篇方法长文 + 6 个校验脚本 + 7 个模板 + 5 篇提示词 + 18 条踩坑清单 | ✅ 每项写明适用场景 / 使用方法 / 已验证效果 / 失效条件 / 来源记录号；19 项可执行资产的失效条件写在各自文件头或 README 表尾列，18 条踩坑清单逐条带 `**失效**` 行 |
| 提示词工作流 / 案例模板 / 校验脚本 / 踩坑清单 | 校验脚本 `skill/scripts/*.py`（含自检 `skill_selftest.py`）；案例模板 `skill/templates/*`；提示词工作流 `skill/prompts/P1`–`P5`；踩坑清单 `skill/pitfalls.md` | ✅ 四类均为可直接复制/运行的资产，不是描述性文字；脚本自带夹具，`skill_selftest.py` 24/24 通过（含 10 条负对照）；另有 `run_all_checks.py` 一条命令跑完两套自检与四项仓库门禁（当前 7/7） |
| 可复用性（陌生队伍能否直接用） | `skill/README.md` §0 三步上手 + §7 换题目/换板卡/换 PYNQ 逐项移植表；脚本仅依赖 Python 标准库 | ✅ 不绑定本队路径与板卡；样例数值取自 v74 真实报告（含失败回放），改阈值即可用于他题 |
| 通用 PYNQ Skill 加分（§3.3.2） | `skill/pynq/`：`pynq_hwh.py`（`.hwh` 地址表/时钟域解析，判据 `ADDR-00x/01x`、`CLK-00x`、`REG-001`）、`pynq_bundle.py`（位流↔地址表配对/时间戳/两版对比）、`pynq_overlay.py`（上板 5 条判据 + `--mock`）、`pynq_selftest.py`（18 用例，含 `--emit-script` 生成物编译检查）、`pitfalls_pynq.md`（14 条，标 `[实测]/[文档]/[待验]`）、`prompts/P6–P7`、`examples/`（真实 BD 导出的 hwh） | ✅ **申报**：面向 PYNQ 框架、不与本题绑定（换题目/换板卡可用，见 `skill/pynq/README.md` §6）。`pynq_selftest.py` 18/18（5 条负对照）；夹具与判据在 `pynq/README.md` §4 逐条附命令 |

## 3. §3.3.5.3 设计报告

主文件：`deliverables/design_report.md`（及 `design_report.docx` / `design_report_full.pdf`）。

| 指南要求 | 报告位置 | 状态 |
|---|---|---|
| 选题背景与创新点：为什么、解决什么、前人做过什么 | §1 需求与痛点（含光电编码器失效机理、iC-TW28 局限）、§8 创新点 | ✅ |
| 设计原理与功能框图 | §2 系统方案（图 `deliverables/figures/block_diagram.png`）、§3 算法 | ✅ |
| 软硬件划分依据与接口设计 | §2.2 关键架构决策、§4.1 模块层次、`rtl/SPEC_interface_contract.md`、§11.10 寄存器表 | ✅ |
| 优化过程，含优化前后性能/资源对比表 | §4.2 资源与时序、§6.4 校正前后对比、§11.9–§11.11 v63–v74 优化记录、`docs/BASELINES.md` | ✅ 版本间对比见 BASELINES 总表 |
| 大模型协作记录（提示词、回答、纠错轨迹、智能体工作流） | §13.1–§13.3；原始记录 `docs/ai-collaboration-log.md`（279 KB） | ✅ |
| 技能包提炼过程（从哪些失败、如何验证、边界） | §13.4 + `skill/*.md` 第 5 节 | ✅ |
| 复现说明（从零可执行） | 附录 D + 独立文件 `docs/REPRODUCE.md` | ✅ 后者更新、更完整（含验收判据与 FAQ） |

## 4. §3.3.5.4 目录与命名

| 要求 | 现状 | 状态 |
|---|---|---|
| 仓库内目录/文件名纯英文（小写、数字、`_`、`-`） | `git ls-files` 无非 ASCII 路径；`python tools/check_anonymity.py --strict-new` 检查 | ✅ |
| 中文只出现在正文 | 所有 `.md` / 报告正文为中文，路径为英文 | ✅ |
| 推荐结构或 README 目录对照 | 未采用 `src/sim/build/board/data/report` 平铺，改为按工程域组织；根 `README.md` 有 §3.3.5.4 对照表 | ✅ 指南允许，README 已给出映射 |

## 5. §3.3.5.5 评测项（自评口径，不是官方打分）

| 评测项 | 权重 | 本项目对应证据 |
|---|---|---|
| 创新性与应用价值 | 30 | 用 FPGA 软件化 iC-TW28 类专用细分 SoC；六参数闭式标定 + 16 bit 全流水 CORDIC + 在线 UI/以太网；报告 §8 |
| 性能与资源优化效果 | 20 | 20.9839° → 0.0165°（1273×）；2048 p/r、719–740 rpm；WNS +0.409、LUT 52.53%（生产）/ 86.96%（显示）；`docs/BASELINES.md` |
| 功能正确性与设计完整性 | 20 | 36/36 仿真、v74 生产位流上板、v85 显示位流构建签核+下载；`deliverables/evidence_index.md` |
| 大模型协作与技能包 | 15 | `docs/ai-collaboration-log.md`、报告 §13、`skill/`（7 篇长文 + 19 项可执行资产 + `pynq/` 通用子包） |
| 文档质量与可复现性 | 15 | 根 README、`docs/` 索引、`docs/REPRODUCE.md`、`docs/BASELINES.md`、CI 检查脚本 |

## 6. §3.3.3 硬约束

| 约束 | 现状 |
|---|---|
| 工具版本 Vivado/Vitis 2026.1（推荐）或 2025.2 | ✅ 全部签核构建使用 **Vivado v2026.1**（见 `deliverables/data/v85/disp_impl.log` 头、各 `prod_impl.log`） |
| 提交大模型协作交互记录 | ✅ `docs/ai-collaboration-log.md` + 报告 §13 |
| 提炼技能包随作品提交 | ✅ `skill/`（本体 7 篇长文 + 19 项资产；另有通用 PYNQ 子包 `skill/pynq/`） |
| 声明具体器件并完成板级验证 | ✅ XC7A35TFGG484-2（达芬奇-lite）+ AD9238；v74 生产位流有转台实测 |
| 开源（MIT 或 Apache-2.0） | ✅ `LICENSE` = MIT；`NOTICE` 列第三方边界 |
| 决赛一页英文海报（A4 彩打、不含队伍信息） | ✅ `deliverables/poster/poster_A4_EN.pptx` / `.pdf` / `.png`（另含 AMD 模板版 `poster_amd_official.*`） |

## 7. 如实登记的缺口

1. **v85 显示位流没有目视验收记录**：时序收敛（WNS +0.175）、已下载运行（`prog_v85.log` `PROGRAMMED_OK`），
   但没有「屏幕五页逐页确认」的签字记录。文档统一写「构建签核 + 已下载」，不写「已上板验收」。
2. **BRAM 48/50（96%）**：显示构建没有 BRAM 余量，再加画面元素需先降分辨率或复用缓冲。
3. **PYNQ 子包按文件级判据交付**：`skill/pynq/` 的 `.hwh` 解析、交付体检与上板判据都有夹具
   （Vivado 2026.1 在 Artix-7 上真实导出的 handoff），判据本身可失败也可回放，见
   `pynq/README.md` §4。
4. **仓库体积偏大**（约 230 MB）：主要来自 `deliverables/data/` 的原始证据与位流；`README.md` 已给
   `--depth 1` 建议，纯代码读者可只取 `rtl/ disp/ host/ model/ tools/`。
5. **上位机为 Windows 优先**：串口/以太网脚本在 Linux 下需改 `COMx` 为 `/dev/ttyUSBx`，未做跨平台 CI。

## 8. 提交前自检命令

```powershell
python skill\scripts\run_all_checks.py       # 技能包 + 仓库门禁一条命令（7 项，当前 7/7 PASS；
                                             #  全新克隆里 check_counts 会 SKIP——zip 不进 git，
                                             #  先跑 tools\make_source_package.py 再验）
python tools\check_links.py                  # 文档相对链接 0 死链
python tools\check_anonymity.py --strict-new # 公开面 0 命中
python tools\check_names.py                  # 静态未定义名 0
python tools\check_citations.py              # "记录 N" 都能追到协作日志标题（0 ERROR / 0 WARN）
python tools\check_counts.py                 # 文档口径 vs 现场事实（zip 684 条目 / 清单 683 行 / PDF 21 页）
python tools\gen_pitfall_index.py --check     # 症状索引与两份清单不脱钩
python host\regs.py --selftest               # 寄存器表自检
python host\analysis.py --selftest           # 分析链自检
python host\encoder.py --selftest            # 编码器模型自检
python skill\scripts\skill_selftest.py       # 技能包自检 24/24（含 10 条负对照）
python skill\pynq\pynq_selftest.py           # PYNQ 子包自检 18/18（含 5 条负对照）
python skill\pynq\pynq_overlay.py --emit-script out\bringup.py   # 生成可拷到板卡的上板脚本
```

哈希复核：`cd deliverables\data; sha256sum -c SHA256SUMS.txt`（Linux）或按该目录 README §3 的 PowerShell 循环。
