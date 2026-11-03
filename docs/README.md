# 文档索引

本目录记录项目从选型、方案、调试到签核的全过程。**结论以最新版本为准**：
签核基线是 v74，最新显示构建是 v85，完整版本演进见
[BASELINES.md](BASELINES.md)；从零复现见 [REPRODUCE.md](REPRODUCE.md)。

阅读顺序建议：先看根目录 [README](../README.md) 了解系统与指标，再看
`deliverables/design_report.pdf`（提交版报告），需要追证据时回到本索引。
提交前逐项对照指南请直接看 [COMPLIANCE.md](COMPLIANCE.md)（§3.3.5 每一条 → 仓库文件）。

## 1. 需求、方案与创新点

| 文档 | 内容 | 状态 |
|---|---|---|
| [01_technical_solution.md](01_technical_solution.md) | 总体技术方案：传感头 → ADC → 标定 → CORDIC → 环路 → 接口 | 现行 |
| [02_innovation_scoring.md](02_innovation_scoring.md) | 创新点论证与竞赛评分策略（对应 30 分项） | 现行 |
| [00_roadmap_30d.md](00_roadmap_30d.md) | 30 天冲刺路线图（历史计划，保留作过程记录） | 历史 |
| [14_dual_channel_feasibility.md](14_dual_channel_feasibility.md) | UART / 千兆以太网双通道可行性（含带宽测算） | 现行 |
| [25_merge_feasibility.md](25_merge_feasibility.md) | 屏 UI + 千兆网能否同时跑：上板资源实测 | 历史（v62 决策依据） |
| [26_resource_budget_v62.md](26_resource_budget_v62.md) | v62 资源预算与优化菜单 | 历史 |

## 2. 算法与模型

| 文档 | 内容 |
|---|---|
| [03_golden_model_results.md](03_golden_model_results.md) | 定点黄金模型实测：六参数标定前后误差、CORDIC 位宽扫描（20.9839° → 0.0165° 的出处） |
| [TW28_digest.md](TW28_digest.md) | iC-TW28 手册结构化摘要：原芯片的算法边界与接口定义（本项目的对标基线） |
| [20_EI58C9_encoder_integration.md](20_EI58C9_encoder_integration.md) | EI58C9 正余弦编码器接入：信号电平、周期数、接线与标定注意 |
| [29_lowsig_sensor_v67.md](29_lowsig_sensor_v67.md) | v67 小信号适配（200–300 mVpp / 64 周期每转）的增益与噪声分析 |

模型代码在 [`../model/`](../model/)；RTL 与模型的逐位对齐方法见
[`../sim/README.md`](../sim/README.md)。

## 3. 硬件、板卡与仪器

| 文档 | 内容 |
|---|---|
| [04_wiring_checklist.md](04_wiring_checklist.md) | 上电前接线核对（电源、地、ADC、屏、网口） |
| [ATK_board_digest.md](ATK_board_digest.md) | 正点原子达芬奇-lite + XC7A35T 资源、时钟、引脚、电源结构化摘要 |
| [AD9238_module_digest.md](AD9238_module_digest.md) | 华升 EDA AD9238 双通道 ADC 模块：接口、时序、量程 |
| [RGB_LCD_wiring_check.md](RGB_LCD_wiring_check.md) | 7 寸 RGB-LCD ↔ J7 接线逐脚核对 |
| [09_scope_measure_log.md](09_scope_measure_log.md) | 示波器实测记录：tPD、Z 脉宽、温度/批次 |
| [DPO2024B_user_guide.md](DPO2024B_user_guide.md) / [DPO2024B_quick_ref.md](DPO2024B_quick_ref.md) | 泰克 DPO2024B 使用指南与工位速查卡 |
| [LCD_test_program_readme.md](LCD_test_program_readme.md) / [LCD_test_program_requirements.md](LCD_test_program_requirements.md) / [LCD_touch_test_readme.md](LCD_touch_test_readme.md) | 屏与触摸的独立测试程序（bring-up 阶段） |

## 4. 仿真与实现签核

| 文档 | 内容 |
|---|---|
| [05_vivado_sim_impl_report.md](05_vivado_sim_impl_report.md) | Vivado 仿真与实现验证报告（v62 时代，方法与脚本仍适用） |
| [34_audit_report.md](34_audit_report.md) | 全量代码审计（2026-11-02）：接口、位宽、复位、时序风险清单 |
| [37_display_smoke_coverage.md](37_display_smoke_coverage.md) | 显示子系统冒烟仿真覆盖（审计 B2 闭环） |

当前签核数字不在这两份文档里，而在
[`../deliverables/data/v74/README.md`](../deliverables/data/v74/README.md)（生产位流）与
[`../deliverables/data/v85/README.md`](../deliverables/data/v85/README.md)（显示位流）。

## 5. 显示 UI（屏上 5 页）

| 文档 | 内容 |
|---|---|
| [13_display_ui_requirements.md](13_display_ui_requirements.md) | 屏 UI 需求规格（页面、布局、刷新率、触摸） |
| [21_screen_ui_v2_requirements.md](21_screen_ui_v2_requirements.md) | 屏 UI v2 需求与编排 |
| [22_screen_ui_v60.md](22_screen_ui_v60.md) | v60 上板问题修复与七项优化 |
| [15_display_touch_bringup.md](15_display_touch_bringup.md) | v58 五页 UI + 触摸/导航回归测试单（247 KB，含逐项记录） |
| [38_display_ui_improvement_plan.md](38_display_ui_improvement_plan.md) | 后续优化方案（部分已执行到 v85，未执行项保留） |

## 6. 以太网与连续流

| 文档 | 内容 |
|---|---|
| [17_ethernet_capture_plan.md](17_ethernet_capture_plan.md) | 以太网高速波形链路（原始 ADC 上传）方案 |
| [18_streaming_ddr_plan.md](18_streaming_ddr_plan.md) | 连续流与 DDR3 深存储二期方案 |
| [19_mig_gui_steps.md](19_mig_gui_steps.md) | Vivado GUI 生成 DDR3 MIG 的 5 分钟操作 |
| [22_ethernet_host_guide.md](22_ethernet_host_guide.md) | 上位机以太网通道使用指南（IP、端口、抓窗、连续流） |
| [40_host_ethernet_plan.md](40_host_ethernet_plan.md) | 加以太网能解决什么、不能解决什么（边界） |

## 7. 上位机（host/）

| 文档 | 内容 |
|---|---|
| [10_host_requirements.md](10_host_requirements.md) | 上位机需求 v1.0（已冻结） |
| [11_host_selfcheck_s1_s5.md](11_host_selfcheck_s1_s5.md) | S1–S5 全面自查报告 |
| [12_host_ui_requirements.md](12_host_ui_requirements.md) | 界面交互批次需求 |
| [16_host_ui_refactor_R16_R20.md](16_host_ui_refactor_R16_R20.md) | 界面重构 R16–R20 |
| [23_host_display_filter_feasibility.md](23_host_display_filter_feasibility.md) | 显示滤波可行性（为什么最终没加） |
| [39_host_improvement_plan.md](39_host_improvement_plan.md) | 上位机提升方案（部分已执行） |
| [41_host_refactor_plan.md](41_host_refactor_plan.md) | 直连 + 千兆 + 可动代码的大改方案 |
| [42_host_change_log.md](42_host_change_log.md) | **本轮改造清单**：做了什么、怎么验、还差什么（含 2026-11-03 上板数据） |

## 8. 版本发布与上板实测（按时间）

| 文档 | 版本 / 日期 |
|---|---|
| [30_flash_program_guide.md](30_flash_program_guide.md) | QSPI Flash 固化步骤 |
| [30_v68_400mvpp_display.md](30_v68_400mvpp_display.md) | v68：400 mVpp 单端正交 + 显示版 |
| [32_board_test_report_2026-11-01.md](32_board_test_report_2026-11-01.md) | v68 生产位流上板测试（11-01） |
| [33_v70_release_report.md](33_v70_release_report.md) | v70：位置计数与 UVW 修复 |
| [35_v71_release_report.md](35_v71_release_report.md) | v71：Z 索引脉冲修复 |
| [36_v72_v73_board_debug.md](36_v72_v73_board_debug.md) | v72/v73 上板调试 |
| [24_board_acceptance_morning.md](24_board_acceptance_morning.md) / [28_board_bringup_checklist.md](28_board_bringup_checklist.md) / [06_board_test_guide.md](06_board_test_guide.md) / [07_board_checklist.md](07_board_checklist.md) | 上板验收清单与逐步指南（通用） |

v74 之后（v75–v85 的 UI/上位机改动）没有单独的 release report，汇总在
[release_notes_v1.0.0.md](release_notes_v1.0.0.md) 与
[`../CHANGELOG.md`](../CHANGELOG.md)。

## 9. 过程记录（大模型协作与开发日志）

| 文档 | 内容 |
|---|---|
| [ai-collaboration-log.md](ai-collaboration-log.md) | **大模型协作记录**（279 KB）：提示词、模型回答、自我纠错轨迹、工作流设计，报告 §"大模型协作"的直接来源 |
| [DEV_STATUS.md](DEV_STATUS.md) | **开发状态日志**（1.55 MB，16k 行）：每一次构建、每一处改动的原始记录；任何结论都可在此追溯 |
| [SKILL 提炼](../skill/README.md) | 7 项技能包的适用范围、用法、失效条件与提炼过程 |

## 10. 发布与仓库治理

| 文档 | 内容 |
|---|---|
| [REPRODUCE.md](REPRODUCE.md) | 从零复现：环境、依赖、构建、烧写、验收判据 |
| [COMPLIANCE.md](COMPLIANCE.md) | 指南 §3.3.5 逐条对照：工程包 / 技能包 / 报告 / 命名 / 权重 / 缺口 |
| [BASELINES.md](BASELINES.md) | v62–v85 基线总表：位流哈希、资源、时序、上板状态 |
| [release_notes_v1.0.0.md](release_notes_v1.0.0.md) | v1.0.0 发布说明（相对 v74 的增量） |
| [../CHANGELOG.md](../CHANGELOG.md) | 变更日志 |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | 贡献指南（构建、测试、接口契约） |
| [../deliverables/evidence_index.md](../deliverables/evidence_index.md) | 报告数字 → 证据文件索引 |

---

### 文档维护约定

- 新增文档用 `NN_topic.md` 编号（NN 为两位数），编号不复用；`README.md` 与
  `REPRODUCE.md`、`BASELINES.md` 不带编号。
- 文档里的每个关键数字必须能指向 `deliverables/data/` 下的报告、日志或哈希。
- 状态字段只用三种：**现行**（与当前代码一致）、**历史**（决策记录，不再更新）、
  **草案**（未执行）。不要把历史计划写成现行结论。
