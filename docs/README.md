# 文档索引

**当前基线 v90（2026-11-04）。** 生产位流 `enc_top_v90.bit` 1,504,220 B / SHA256 `A89512A5…7125` /
WNS **+0.199 ns** / LUT **10,978 = 52.78%** / BRAM 32/50；显示位流 `enc_top_disp_v90.bit`
1,688,245 B / WNS **+0.221 ns** / LUT **17,090 = 82.16%** / BRAM 45.5/50；仿真 `sim/` **37/37**
+ `disp/` **20/20**；证据 `deliverables/data/SHA256SUMS.txt` **323 条**哈希。
验收判据只有一份：[`39_acceptance_criteria_v90.md`](39_acceptance_criteria_v90.md)。

本索引按 **当前（v90） / 历史 / 参考** 三组组织。三组对应三种文档状态：
"当前"随基线走（改数字必须同步）、"历史"不再更新（只作追溯）、"参考"是稳定的外部事实（硬件、协议、手册）。

## 一、当前（v90）—— 交付与判据

| 文档 | 用途 |
|---|---|
| [COMPLIANCE.md](COMPLIANCE.md) | 赛题 §3.3.5.1–§3.3.5.5 与 §3.3.3 的逐条对照（要求 → 对应文件 → 已完成 / 部分完成 / 不适用），评委抽查与提交前自检的第一入口。 |
| [39_acceptance_criteria_v90.md](39_acceptance_criteria_v90.md) | v90 唯一的验收判据：A 复用 / B 静态 / C 关键 / D 显示 / E 自动五类 + 免判项 + 已知问题边界，"通过"只按本文定义。 |
| [BASELINES.md](BASELINES.md) | v62→v90 全部位流的改动点、关键数字（大小 / SHA256 / WNS / LUT / BRAM）与状态（已上板 / 构建签核 / 历史）。 |
| [REPRODUCE.md](REPRODUCE.md) | 从零复现：环境、生产与显示两个位流的构建命令、回归、上板判据、哈希校验与 FAQ。 |
| [01_technical_solution.md](01_technical_solution.md) | 总体技术方案：信号链走向、六参数闭式标定 + CORDIC 算法、模块层次与接口约定。 |
| [02_innovation_scoring.md](02_innovation_scoring.md) | 创新点清单与赛题评分维度的对应论据（"为什么这算创新"的对比表）。 |
| [03_golden_model_results.md](03_golden_model_results.md) | 定点黄金模型的精度数字出处（20.9839° → 0.0165°，1273×），README 与报告引用的 `[仿真]` 口径都在这里。 |
| [05_vivado_sim_impl_report.md](05_vivado_sim_impl_report.md) | 仿真与实现的方法说明：每台测试台覆盖什么、综合实现报告怎么看，脚本口径至今适用。 |
| [43_keyword_audit.md](43_keyword_audit.md) | 三个关键词的口径边界、对外协议矩阵、风险问答，以及型号 / 厂商信息的清理记录。 |
| [04_wiring_checklist.md](04_wiring_checklist.md) | 板级接线核对表（AD9238 / LCD / 以太网 / 电源），上板前逐项打勾。 |
| [30_flash_program_guide.md](30_flash_program_guide.md) | 位流固化 Flash 的步骤与冷启动验证方法（v90 显示位流按此验证）。 |
| [ai-collaboration-log.md](ai-collaboration-log.md) | 与模型协作的完整原始记录（约 279 KB），报告 §13 与技能包每条"来源：记录 N"的追溯目标。 |

## 二、历史 —— 版本报告与过程记录

| 文档 | 用途 |
|---|---|
| [00_roadmap_30d.md](00_roadmap_30d.md) | 30 天排期与里程碑设置，回看"为什么先做 UI 再做编码器"。 |
| [14_dual_channel_feasibility.md](14_dual_channel_feasibility.md) | 双通道（编码器 + ADC 采集）并存的可行性论证，双通道架构的依据。 |
| [15_display_touch_bringup.md](15_display_touch_bringup.md) | 触摸屏点亮与坐标校准的调试记录。 |
| [17_ethernet_capture_plan.md](17_ethernet_capture_plan.md) | 以太网抓窗的早期方案（后被 40_host_ethernet_plan 取代）。 |
| [18_streaming_ddr_plan.md](18_streaming_ddr_plan.md) | DDR3 流式缓存规划，二期方向，未并入交付位流。 |
| [19_mig_gui_steps.md](19_mig_gui_steps.md) | MIG GUI 配置步骤记录（DDR3 二期用）。 |
| [12_host_ui_requirements.md](12_host_ui_requirements.md) | 上位机 UI 第一批交互需求（v6x 时代）。 |
| [16_host_ui_refactor_R16_R20.md](16_host_ui_refactor_R16_R20.md) | R16–R20 批次的上位机界面重构记录。 |
| [21_screen_ui_v2_requirements.md](21_screen_ui_v2_requirements.md) | 屏上 UI v2 需求，已被 13 与 v90 的 4 页布局取代。 |
| [22_screen_ui_v60.md](22_screen_ui_v60.md) | v60 屏 UI 实现说明，现行多页布局的来源。 |
| [23_host_display_filter_feasibility.md](23_host_display_filter_feasibility.md) | 上位机与屏端滤波的可行性评估，结论已并入 13。 |
| [25_merge_feasibility.md](25_merge_feasibility.md) | 编码器与 UI / 网表合并的可行性论证，v62 合并的依据。 |
| [26_resource_budget_v62.md](26_resource_budget_v62.md) | v62 资源预算表，第一次系统性估算 LUT / BRAM 余量。 |
| [27_turntable_requirements_feasibility.md](27_turntable_requirements_feasibility.md) | 转台指标与可行性（rpm、分辨率、接口要求的来历）。 |
| [28_board_bringup_checklist.md](28_board_bringup_checklist.md) | 板子上电 bring-up 清单（v62 之前）。 |
| [29_lowsig_sensor_v67.md](29_lowsig_sensor_v67.md) | v67 小信号专项（200–300 mVpp / 64 周期）的假设与结论。 |
| [30_v68_400mvpp_display.md](30_v68_400mvpp_display.md) | v68 单端 400 mVpp 与显示并存的方案记录。 |
| [32_board_test_report_2026-11-01.md](32_board_test_report_2026-11-01.md) | 2026-11-01 上板测试原始报告（首个正确轮次的数据来源）。 |
| [33_v70_release_report.md](33_v70_release_report.md) | v70 发布说明，首个真机正确的构建（`RTL_BUILD_ID=0x0015`）。 |
| [34_audit_report.md](34_audit_report.md) | 2026-11-02 提交前审计：问题清单与逐条闭环状态。 |
| [35_v71_release_report.md](35_v71_release_report.md) | v71 发布说明，Z 索引脉冲修复。 |
| [36_v72_v73_board_debug.md](36_v72_v73_board_debug.md) | v72 / v73 板级调试记录（RPM 除零修复、Z 计数探针）。 |
| [37_display_smoke_coverage.md](37_display_smoke_coverage.md) | 显示冒烟测试的覆盖矩阵，现由 `disp/` 20 台测试台执行。 |
| [38_display_ui_improvement_plan.md](38_display_ui_improvement_plan.md) | 显示 UI 改进计划，v90 删 P7、P2 加预触发环缓的前置文档。 |
| [39_host_improvement_plan.md](39_host_improvement_plan.md) | 上位机改进计划（与 39_acceptance_criteria_v90 仅编号相同，内容无关）。 |
| [40_host_ethernet_plan.md](40_host_ethernet_plan.md) | 上位机以太网抓窗计划，28,672 点 / 50 MSPS 方案的由来。 |
| [41_host_refactor_plan.md](41_host_refactor_plan.md) | 上位机重构计划，`REG_*` 单一来源的拆分依据。 |
| [42_host_change_log.md](42_host_change_log.md) | 上位机 2026-11-03 批次的逐项改动日志。 |
| [DEV_STATUS.md](DEV_STATUS.md) | 逐日过程台账（v12–v74 期间，16,000+ 行），"当时怎么想、怎么证"的原始流水。 |
| [release_notes_v1.0.0.md](release_notes_v1.0.0.md) | v1.0.0 发布说明（v74 口径），已被 v90 取代，仅作版本记录。 |

## 三、参考 —— 硬件 / 协议 / 需求原文

| 文档 | 用途 |
|---|---|
| [06_board_test_guide.md](06_board_test_guide.md) | 板级测试操作指南：串口、以太网、转台的操作顺序与判据。 |
| [07_board_checklist.md](07_board_checklist.md) | 交付日一页检查清单，与 `evidence_index.md` 配合使用。 |
| [24_board_acceptance_morning.md](24_board_acceptance_morning.md) | 交付日上午的验收流程与时间表。 |
| [22_ethernet_host_guide.md](22_ethernet_host_guide.md) | 千兆以太网与上位机的连接、抓窗、导出操作指南。 |
| [10_host_requirements.md](10_host_requirements.md) | 上位机功能需求原文：协议、界面、导出格式。 |
| [11_host_selfcheck_s1_s5.md](11_host_selfcheck_s1_s5.md) | 上位机 S1–S5 自检步骤。 |
| [13_display_ui_requirements.md](13_display_ui_requirements.md) | 屏上 UI 需求：页布局、按键行为、绘制规则的权威描述。 |
| [20_EI58C9_encoder_integration.md](20_EI58C9_encoder_integration.md) | 转台增量式正余弦编码器的电气与信号接入说明。 |
| [09_scope_measure_log.md](09_scope_measure_log.md) | 示波器实测记录：幅度、频率、相位差。 |
| [ATK_board_digest.md](ATK_board_digest.md) | 达芬奇-lite 板卡的资源与接口摘要（引脚、时钟、存储）。 |
| [AD9238_module_digest.md](AD9238_module_digest.md) | AD9238 采集模块的时序、引脚与模拟前端摘要。 |
| [RGB_LCD_wiring_check.md](RGB_LCD_wiring_check.md) | RGB LCD 接线与引脚核对表。 |
| [LCD_test_program_requirements.md](LCD_test_program_requirements.md) | 板卡自带屏测试程序的需求说明。 |
| [LCD_test_program_readme.md](LCD_test_program_readme.md) | 板卡自带屏测试程序的用法。 |
| [LCD_touch_test_readme.md](LCD_touch_test_readme.md) | 板卡自带触摸测试程序的用法。 |
| [DPO2024B_user_guide.md](DPO2024B_user_guide.md) | 示波器操作手册摘录（测量功能、触发、单次采集）。 |
| [DPO2024B_quick_ref.md](DPO2024B_quick_ref.md) | 示波器速查卡。 |

## 四、仓库内相邻入口

| 路径 | 用途 |
|---|---|
| [../README.md](../README.md) | 仓库总览：v90 口径、目录地图、关键数字、三步上手。 |
| [../deliverables/evidence_index.md](../deliverables/evidence_index.md) | 证据索引：每条结论 → 文件 → 哈希，评委抽查的主入口。 |
| [../deliverables/README.md](../deliverables/README.md) | 交付物目录说明（报告、海报、证据、提交材料的组织方式）。 |
| [../deliverables/data/v90/README.md](../deliverables/data/v90/README.md) | v90 证据目录的逐件说明（两个位流与五件套报告）。 |
| [../deliverables/data/SHA256SUMS.txt](../deliverables/data/SHA256SUMS.txt) | 323 条哈希清单，`sha256sum -c` 可逐条复核。 |
| [../deliverables/submission/submission_checklist.md](../deliverables/submission/submission_checklist.md) | 提交平台的逐项清单（字段、附件、命名）。 |
| [../deliverables/design_report.md](../deliverables/design_report.md) | 设计报告正文（§1–§13）。 |
| [../rtl/SPEC_interface_contract.md](../rtl/SPEC_interface_contract.md) | 模块间接口契约：端口、位宽、握手、时序假设。 |
| [../skill/README.md](../skill/README.md) | 技能包索引：7 篇方法长文 + 四类可执行资产 + 18 条踩坑。 |
| [../skill/pynq/README.md](../skill/pynq/README.md) | 通用 PYNQ 子包索引（与本题解耦，按 §3.3.2 申报加分）。 |
| [../sim/logs/SUMMARY.md](../sim/logs/SUMMARY.md) | `sim/` 37 台测试台的最近一次全量回归结果。 |
| [../disp/logs/SUMMARY.md](../disp/logs/SUMMARY.md) | `disp/` 20 台测试台的最近一次全量回归结果。 |
| [../CHANGELOG.md](../CHANGELOG.md) | 提交级变更记录。 |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | 贡献约定与检查脚本清单。 |
| [../SECURITY.md](../SECURITY.md) | 安全与敏感信息约定。 |
| [../CITATION.cff](../CITATION.cff) | 引用信息。 |
| [../LICENSE](../LICENSE) | MIT 许可证。 |
| [../NOTICE](../NOTICE) | 第三方组件与来源边界。 |

## 五、维护约定

1. **命名**：新文档用 `NN_topic.md`（两位序号 + 小写英文 / 数字 / 下划线），中文只出现在正文，不进路径。
2. **首段**：写清"用途 + 状态"，状态只用 **当前 / 历史 / 参考** 三种，与本文三组一一对应。
3. **数字**：只以 `deliverables/data/v90/` 的报告与 [BASELINES.md](BASELINES.md) 为准；改数字必须同时改
   [39_acceptance_criteria_v90.md](39_acceptance_criteria_v90.md)，否则判据与文档会打架。
4. **登记**：新增或删除文档必须同步本索引；`python tools/check_links.py` 必须 0 死链。
5. **去标识**：路径、文件名、正文都不得出现学校、指导教师、队名、学号、邮箱与具体厂商型号；
   提交前跑 `python tools/check_anonymity.py --strict-new`。
