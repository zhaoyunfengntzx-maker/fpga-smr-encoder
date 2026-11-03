# 变更日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

本项目在 v1.0.0 之前没有打 tag，历史版本以构建号（`RTL_BUILD_ID`）区分。
完整基线数据（位流哈希、时序、资源、上板状态）见
[docs/BASELINES.md](docs/BASELINES.md)。

## [Unreleased]

技能包从"7 篇描述性长文"补齐为"长文 + 可直接复用的可执行资产"，对应指南 §3.3.5.2
的四类形态。全部资产自带夹具，`python skill/scripts/skill_selftest.py` 一条命令自证。

### Added

- `skill/scripts/`：5 个仅依赖 Python 标准库的校验脚本，退出码 0 通过 / 1 判据失败 /
  2 无法判断。
  - `check_impl_reports.py`：解析 Vivado 实现报告（WNS/WHS/失败端点/资源/DRC/
    `check_timing`）→ 机器判决 + JSON；
  - `check_vectors.py`：黄金模型与仿真输出逐点比对（最大误差/RMS/容差直方图/最坏点）；
  - `check_manifest.py`：SHA-256 清单写入与校验，防"改了文件没重打包"；
  - `tb_wiring.py`：测试台接线体检，抓"激励没接上却打印 PASSED"的空转测试台；
  - `skill_selftest.py`：上述四个脚本的 14 项自检（含 4 条负对照）。
- `skill/templates/`：7 个可直接复制的模板——测试台骨架 `tb_skeleton.v`（含超时保护、
  `stim.txt` 激励、逐点比对）、配对 DUT `dut_passthrough.v`、定点黄金模型骨架
  `fixedpoint_model.py`、源同步约束骨架 `xdc_source_sync.xdc`、非工程模式构建脚本
  `run_vivado.tcl`、报告骨架 `REPORT_OUTLINE.md`、复现清单 `REPRO_CHECKLIST.md`。
- `skill/prompts/`：5 篇提示词工作流（算法→数据通路、报告→瓶颈、测试台证伪、
  子代理只读审计、五段式纠错回合）。
- `skill/pitfalls.md`：18 条结构化踩坑清单（触发条件 / 现象 / 排查命令 / 根因 /
  修法 / 回归验证 / 失效 / 来源记录号）。
- `skill/examples/`：与脚本配套的夹具（v74 真实数值的通过/失败报告回放、
  16 点角度向量、SHA-256 样例、好/坏测试台）。

### Changed

- `skill/README.md` 重写为 9 节索引：陌生队伍三步上手、脚本/模板/提示词表、
  症状索引、方法长文、自检方法、换题目/换板卡/换 PYNQ 的逐项移植指引、来源追溯。
- 根 `README.md`、`docs/README.md`、`docs/COMPLIANCE.md` 的技能包描述同步为
  "7 篇方法长文 + 18 项可执行资产"。
- 18 项资产逐项补"失效条件"（脚本 docstring 的 `【失效条件】`、模板头部注释、
  pitfalls 每条 `**失效**` 行、README 两张表的表尾列）——只说"能用在什么场景"
  而不说"什么时候不管用"，等于把别人往坑里带。

### Fixed

- `skill/` 与 `skill/prompts/` 里若干 `src: 记录 N` 引用是凭印象写的，与
  `docs/ai-collaboration-log.md` 的实际记录标题对不上，已逐条核到 86 条记录标题
  或 `deliverables/design_report.md` 的章节锚点；不可核验的改为文件锚点。

## [1.0.0] — 2026-11-03

首个公开开源版本。参赛提交口径：**v74 生产位流**（签核 + 上板验收）；
演示口径：**v85 显示位流**（构建签核 + 已下载，未逐页目视）。

### Added

- 公开版 README：系统架构、关键指标、目录对照、快速开始、证据链、诚实边界。
- `docs/REPRODUCE.md`：从零复现（环境、仿真、构建、烧写、验收判据、FAQ）。
- `docs/BASELINES.md`：v62–v85 基线总表（位流哈希、WNS、LUT/BRAM、上板状态）。
- `docs/README.md`：51 份开发文档的主题索引与状态标注。
- `docs/release_notes_v1.0.0.md`：相对 v74 的增量说明（v75–v85 UI/上位机）。
- `deliverables/data/v85/`：v85 显示位流 + 时序/资源/DRC/布线报告 + 烧写日志
  + 构建脚本 + `VARIANT_INFO.txt` + 说明。
- `host/requirements.txt`：固定上位机依赖范围（PySide6 6.9 / pyserial 3.5 /
  numpy 2.x / matplotlib 3.10 / Pillow 12）。
- `CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`、`SECURITY.md`、`CITATION.cff`、
  `CHANGELOG.md`、`.github/`（Issue/PR 模板、CI）。
- 根 README 中的赛题 3.3.5.4 目录对照表。

### Changed

- 根 README 从"内部开发状态板"改写为面向外部读者的项目主页；历史基线表移入
  `docs/BASELINES.md`，README 只保留当前结论。
- v74 显示位流状态改为"已被 v85 取代"，不再作为最新 UI 口径。
- `tools/impl_check_v74.tcl`、`tools/impl_check_disp_v74.tcl`：仓库根目录由
  `[info script]` 自动推导，不再硬编码作者机器的绝对路径。
- `tools/program_bit.tcl`：支持 `-tclargs <bit>`，相对路径按仓库根解析。
- 证据哈希清单扩展到 299 条（新增 v85 的 16 条）。

### Fixed

- 文档中 v74 显示位流大小/哈希与 `deliverables/data/` 不一致的旧数字
  （`1,713,025 B` / `ECB31F6E…` → 以 `1,700,821 B` / `72FF4D13…` 为准，并标注已被 v85 取代）。
- `docs/42_host_change_log.md` 记录的上位机缺陷（详见该文件 §18–20）：
  - `host/tasks.py:task_set_ablimit()` 把 int 当下标写寄存器导致崩溃；
  - `host/regs.py:adv_field_writes()` 空字典误报"有未写字段"；
  - `_net_tick_body()` 漏调 `_update_live(frames[-1])`，实时页不刷新；
  - `host/net_frames.py:FrameSynth` 对 `amp_sq` 重复移位（s²+c² 已是平方）；
  - 以太网建链超时 6 s → 15 s，`STOP_HZ` 固定 30 Hz。
- 显示 RPM 除零（v72）与 Z 索引不出（v71）等历史缺陷见
  [docs/36_v72_v73_board_debug.md](docs/36_v72_v73_board_debug.md)、
  [docs/35_v71_release_report.md](docs/35_v71_release_report.md)。

### Known issues

- v85 显示位流**未逐页目视验收**；BRAM 48/50（96%），没有整页/帧缓冲余量。
- 纯 RTL 方案，无 PS/PYNQ，不申报"通用 PYNQ Skill"加分。
- 上位机以 Windows 为主（`winreg` 等），其他平台需适配。
- 仓库含约 233 MB 证据归档，克隆较慢；可用 `--depth 1`。
- 绝对精度受传感头、磁钢偏心、转台机械误差限制；标定假设 1 机械圈 = 1 标定周期
  （64 周期/圈或 2048 周期/圈的变体需对应改 `CALIB_N`）。

## 历史版本（未打 tag）

| 构建号 | 版本 | 要点 |
|---|---|---|
| `0x000B` | v62 | 首个"编码器 + 5 页 UI + 千兆网"同板演示；屏/网/编码器全部上板 |
| `0x000E` | v66 | 双通道、位置计数中间版 |
| `0x000F` | v67 | 小信号 200–300 mVpp、64 周期/转适配（仿真 35 checks） |
| `0x0010` | v68 | 400 mVpp 单端正交 + 显示版 |
| `0x0015` | v70 | 修 `cycle_cnt` 无符号扩展与 UVW 反向环绕；2048 PPR 首次转台上板 |
| `0x0016` | v71 | Z 索引改为绝对角度过零 + 双向跨零 + `clr_on_z=0`；仿真 36/36 |
| `0x0017` | v73 | 显示 RPM 除零修复（20 位除数）+ Z 上升沿计数探针；Flash 冷启动 |
| `0x0018` | v74 | v71 + 探针，生产/显示双位流；**当前签核基线** |
| `0x0018` | v85 | v74 RTL + UI v75–v85；**最新显示构建**（未目视） |

> 构建号相同不代表位流相同：v74 与 v85 都用 `0x0018`，区别在 `disp/` 与
> 综合 define。识别位流请以 SHA-256 为准，不要只看构建号。
