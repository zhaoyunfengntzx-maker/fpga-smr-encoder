# 变更日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

本项目在 v1.0.0 之前没有打 tag，历史版本以构建号（`RTL_BUILD_ID`）区分。
完整基线数据（位流哈希、时序、资源、上板状态）见
[docs/BASELINES.md](docs/BASELINES.md)。

## [Unreleased]

### 2026-11-04 · 报告改为直接在官方模板上填写

- `deliverables/template/design_report_template.docx` 收进仓库（赛题《报告模版》原件），
  `tools/build_report_doc.py` 以它为基底：保留模板的 A4 版心、1.25 in 左右边距、1.5 倍行距、
  自带页眉横幅与页脚页码，只把提示语替换为正文。
- 排版回落到模板的中性样式：宋体/Times 12 pt 正文、14 pt 加粗部分标题、黑色标题与
  细线表格（去掉此前的藏青/琥珀配色与自定义页眉）。
- 表格单元压到 9.5 pt、行距 1.1，表 1 与表 C-1 各自单页收口；图 5/图 6 实物与电路照片进正文。
- 产物：design_report.docx 6,791,149 B、design_report.pdf **26 页 / 1,530,854 B**，
  同步到 deliverables/submission/。

### 设计报告按官方《报告模版》重排（2026-11-04）

- **结构对齐模板**：`tools/build_report_doc.py` 重写为“作品名称 → 摘要 → 五部分”骨架，
  小标题与模板逐条一致（第一部分六节；2.1 / 2.2.1–2.2.3 / 2.3.1–2.3.2；3.1 / 3.2.1–3.2.3 /
  3.3 特性成果；4.1 可扩展之处 / 4.2 心得体会；第五部分参考文献 ≤20 条）。原自拟的
  “选题背景与创新点”改为第一部分引言，原附录 D「实物照片」删除（照片进正文 3.1/3.2.2）。
- **按模板扩写**：新增 2.3.1 数据流段落、2.3.2 表 3 改为「模块 | 关键输入 → 输出 | 实现要点/延迟」
  14 行、2.2.3 新增表 4「板级关键接口与信号线」8 行、3.2.3 上位机三段功能、附录 C 表 C-1
  「复现环境与目录对照」与四条复现常见问题；摘要 665 字、各节字数均在模板预算内。
- **图 12 与表 6/表 8 更新**：`tools/make_report_figures.py` 的验证链图从 v70 数字
  （51 台 / 33/33 / +0.091 / 598,115 帧）改成 v90（57 台 / 37/37+20/20 / +0.199 / 597,886 帧、
  320 件证据 / 323 条哈希）；表 6 的 LUT 列加宽不再断行，表 8 的“同类高阶方案”列纠正为
  16 bit（后分频）/ BiSS / 偏心补偿。
- **产物**（随后改为直接在模板文件上填写，页数与字节以本节上方条目为准）：`design_report.docx` 6,747,482 B、`design_report.pdf` 26 页 / 1,671,506 B，
  已同步 `deliverables/submission/design_report.pdf`；页数与字节数回填到 `deliverables/README.md`、
  `submission/README.md`、`form_answers.md`、`submission_checklist.md`。

### 交付基线升到 v90（2026-11-04）

- **全部文档统一到 v90 位流口径**：生产 `enc_top_v90.bit` **1,504,220 B** /
  SHA256 `A89512A5…F827125` / WNS **+0.199** / LUT **10,978（52.78%）** / BRAM 32-50；
  显示 `enc_top_disp_v90.bit` **1,688,245 B** / `69FE313C…F81BAD4` / WNS **+0.221** /
  LUT **17,090（82.16%）** / BRAM 45.5-50，已写 Flash 并通过冷启动。
- **仿真回归扩到 57 台**：`sim/` **37/37 PASS**（2026-11-04 00:49:22）、
  `disp/` **20/20 PASS**（00:03:16）；README / COMPLIANCE / REPRODUCE / BASELINES /
  docs 索引 / 设计报告全部同步。
- **构建链消除派生差异**：仓库 `rtl/` 直接就是 v90 源（`RTL_BUILD_ID = 16'h0019`），
  `tools/make_v90_rtl.py` 只复制 + 校验、不再复制后改一行；新增
  `tools/impl_check_v90.tcl` / `impl_check_disp_v90.tcl`，产出 `_synth_work_v90/`
  下的两个位流与完整报告。
- **验收判据单点化**：新增 [`docs/39_acceptance_criteria_v90.md`](docs/39_acceptance_criteria_v90.md)
  （A 复用 / B 静态 / C 关键 / D 动态 / E 交互五类，逐条带命令与证据）；转速权威判据改为
  `z_rate.py` 的 Z 频率（**7.62–7.65 Hz ⇒ 457–459 rpm**），并说明 `check_v70.py`
  的 621 rpm 是低转速混叠伪值。
- **v90 RTL 改动只有两处**：`rtl/abz_gen.v` 新增 `z_index_gen`（出 Z 撤防、离开
  ≥1/8 圈重新布防）治停位 Z 喘振；`rtl/uvw_gen.v` 保持 v74。屏上删除 P7 标定页
  （标定走 KEY0 长按或串口写 `0x0502 = 0x0001`），P2 加预触发环形缓冲 + 中线 +
  AUTO 时基，可导航页固定为 **4 页**（P1/P2/P4/P6）。
- **术语与材料清理**：全仓不再出现具体厂商芯片型号，统一表述为「同类专用细分 ASIC」；
  删除 `docs/` 下厂商手册的逐页数值摘录（原 `*_digest.md/.pdf`，已整篇移除）；`NOTICE`、
  设计报告、技术文档与 README 的参考资料、历史清理命令同步改写；`rtl/spi_slave.v`
  的包模式参数改名为 `USE_PKT_MODE`（纯标识符，行为不变）。
- **屏上四页逐页人工核对通过（2026-11-04）**：v90 显示位流写 Flash、冷启动进入 P1 后，
  P1/P2/P4/P6 逐页核对 —— P1 四卡数值/单位不重叠且 `Z计数` 递增；P2 三档 + `AUTO` 波形
  左右连续、标记在中线；P4 上半 A/B 各 4 周期、下半 U/V/W 60° 台阶 + Z 竖标；P6 参数与
  `S0C0` 回读一致；裸指触摸与 KEY1 翻页正常，P7 标定页确认不存在。`docs/39` 的 E 类判据
  据此收敛为全过，报告 §7 **R13 / R14 关闭**，`docs/43`、`REPRODUCE`、`board_day_checklist.md`
  与 v90 归档 README 同步回填；`design_report.pdf` 重导为 **25 页**，full PDF 60 页，
  `technical_doc.pdf` 17 页。
- **报告与文档重写**：`deliverables/design_report.md`（1732 行 / 60 页 full PDF）、
  `tools/build_report_doc.py`（docx 25 页）、`build_tech_doc.py`、`build_intro_doc.py`、
  `docs/01_technical_solution.md`、`docs/05_vivado_sim_impl_report.md`、
  `docs/REPRODUCE.md`、`docs/COMPLIANCE.md`、`docs/README.md`、`docs/BASELINES.md`
  全部改成 v90 口径；v62/v66/v70/v74/v85/v89 一律标为历史基线，只在演进/对照章节出现。

技能包从"7 篇描述性长文"补齐为"长文 + 可直接复用的可执行资产"，对应指南 §3.3.5.2
的四类形态。全部资产自带夹具，`python skill/scripts/skill_selftest.py` 一条命令自证。

### Added

- **实物照片入包与报告实拍图（2026-11-03 20:02 拍摄）**：新增 `deliverables/submission/photos/`
  四张实拍（全貌 1 张 + 开发板角度 3 张，均 ≤10 MB、已按 EXIF 转正并清除元数据），
  `tools/make_source_package.py` 增收 `deliverables/figures/*.jpg` 与 `deliverables/submission/photos/*`；
  `design_report.docx/pdf` 末尾新增附录 D「实物照片」（图 D-1–D-3），详细版 `design_report.md`
  增图 2-2 与附录 J。同时删除「磁环气隙特写」这一待拍项——第 7 项改按正面 / ADC 模拟前端 /
  屏与触摸三张交付，视频脚本镜头 16 改为中景（不再要求气隙微距）。
- **第三轮改进（A1–A3 + B4 + B5）**：技能包进 CI、技术文档补 §3.3.5、提交事实快照、
  一页速查表。动机是三条自查结论：`.github/workflows/ci.yml` 从来没跑过技能包门禁；
  `technical_doc.pdf` 里 `skill/` 出现 0 次；`skill/README.md` 把 18 个用例写成 13 个
  写了两周而没人发现。
  - `.github/workflows/ci.yml` 新增 `Skill package gates` 步骤，跑
    `python skill/scripts/run_all_checks.py`；
  - `docs/SUBMISSION_FACTS.json`：打包时的事实快照（zip 条目/体积、MANIFEST 行数、
    PDF 页数与字节、资产计数），`tools/check_counts.py` 在**没有 zip 的克隆**里改用它
    比对，因此 CI 上不再退化成 SKIP；
  - `tools/check_counts.py` 新增 `COUNT-FACTS`（快照 vs 现场）与 `COUNT-SKILLDOC`
    （`skill/README.md` 里不许出现 `13/13`/`14/14`，必须写 `24/24`/`18/18` 与现场
    资产数）；zip 体积改为 ±0.05 MB 容差并写明原因（文档在 zip 里，自指）；
  - `skill/CHEATSHEET.md`：一页纸（三条命令、退出码语义、五个最常踩的坑）；
  - `tools/build_tech_doc.py` 新增 §3.3.5「技能包与通用 PYNQ 子包」，
    `technical_doc.pdf` 15 → 16 页（967,938 B）。
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
- **证据补强与防漂移门禁**（2026-11-03 第二轮，四组改进里的 A/B/C）：
  - `skill/scripts/run_all_checks.py`：一条命令总判决（两套自检 + 链接/命名/记录号/
    计数四项仓库门禁），`--fast` 跳过自检，缺依赖记 `SKIP` 并提示"别把 SKIP 当 PASS"；
  - `skill/pynq/pynq_overlay.py --emit-script OUT.py`：生成一份可拷到板卡上跑的
    独立上板脚本（5 条判据 + `--record` 追加 `bringup_record.csv`），生成时立即
    `compile()` 自检，寄存器偏移处留 `TODO`；
  - `tools/check_citations.py`：把"记录 N 必须能追到日志标题"变成门禁
    （CITE-001 号不存在 / CITE-002 无线索 / CITE-003 无括注 / CITE-004 重复过多），
    用规范化 3-gram 比对，避免引号把标题切碎造成的假阳性；
  - `tools/check_counts.py`：核对文档口径与现场事实（zip 条目数、MANIFEST 行数、
    PDF 页数/字节数、资产计数、自检用例数），按文件名分段取数，避免把
    "≤200 MB 上限"当成包体积；
  - `tools/gen_pitfall_index.py` 生成 `skill/pitfalls_index.md`（两份清单 18 + 14 条
    按症状/首条命令编成索引），`--check` 抓"清单改了索引没改"的漂移。
- `skill/pynq/examples/` 增加三种 `.hwh` 形状夹具（`ps7/`、`clk_multi/`、`clk_missing/`），
  各带 `SHAPE.md` 说明"哪段真实、哪段手改"；`pynq_hwh.py` 新增 `CLK-003`（从口没声明
  时钟）与 `--lenient`（只让 FAIL 拦流程）。
- `skill/pynq/`：**通用 PYNQ 技能包**（按指南 §3.3.2 申报加分，不与本题绑定）。
  - `pynq_hwh.py`：解析 Vivado handoff `.hwh`（IP 清单 / 从口地址表 / 时钟域），判据
    `ADDR-000/001/002/003/004/005/010`、`CLK-001/002`、`REG-001`，支持 `--diff/--json/--md`；
  - `pynq_bundle.py`：交付目录体检（`.bit`↔`.hwh` 配对、时间戳、sha256、两版 IP 清单对比）；
  - `pynq_overlay.py`：上板 5 条判据 + `--mock` 离线版 + `--selftest` 4 项（3 条负对照）；
  - `pynq_selftest.py`：上述三个工具的 13 项自检（含 5 条负对照）；
  - `pitfalls_pynq.md`：14 条 PYNQ 专有坑，逐条标 `[实测]` / `[文档]` / `[待验]`；
  - `prompts/P6_hwh_to_register_map.md`、`prompts/P7_bringup_falsification.md`；
  - `examples/`：Vivado 2026.1 在 Artix-7 上真实导出的 `.hwh`（3 份变体）+ 位流配对样例。
    边界写在 `skill/pynq/README.md` §4，`pitfalls_pynq.md` 逐条标证据等级。

### Changed

- `skill/README.md` 重写为 9 节索引：陌生队伍三步上手、脚本/模板/提示词表、
  症状索引、方法长文、自检方法、换题目/换板卡/换 PYNQ 的逐项移植指引、来源追溯。
- 根 `README.md`、`docs/README.md`、`docs/COMPLIANCE.md` 的技能包描述同步为
  "7 篇方法长文 + 19 项可执行资产"。
- 18 项资产逐项补"失效条件"（脚本 docstring 的 `【失效条件】`、模板头部注释、
  pitfalls 每条 `**失效**` 行、README 两张表的表尾列）——只说"能用在什么场景"
  而不说"什么时候不管用"，等于把别人往坑里带。
- 自检扩容：`skill_selftest.py` 14 → **24 用例**（新增 10 条钉参数语义：`--min-wns`、
  `--max-util`、`--col-ref/--col-got`、`--hist`、`--write`、`--strict`、`--exclude`…），
  `pynq_selftest.py` 13 → **18 用例**（含 `--lenient`、`CLK-003`、`--emit-script` 生成物
  可编译）。`--with-tests` 的期望值也随之改成 24/24 与 18/18。
- `skill/templates/run_vivado.tcl` 的"已验证"改成模板自身的实跑证据（`dut_tiny` @50 MHz
  → 位流 + `PASS 9/9`；@100 MHz → `WNS=-1.220`、`EXIT 3`、不写位流），并把所有 `puts`
  改成 ASCII（Vivado 2026.1 的 `puts` 落盘中文会掉字节，判据关键字必须能 grep）。
- `check_vectors.py` 改为单遍流式统计（`iter_rows` 生成器 + `Stats`），百万点实测
  2.9 s / 峰值 15.3 MB（旧版全读进内存 5.0 s / 550 MB），输出格式逐字节不变。
- 口径随之更新：资产 18 → **19 项**（新增 `run_all_checks.py`），提交包
  **683 条目 / 30.05 MB**、`MANIFEST.sha256` **682 行**、`design_report.pdf`
  **21 页 / 1.25 MB**（1,251,771 B）。

### Fixed

- `skill/` 与 `skill/prompts/` 里若干 `src: 记录 N` 引用是凭印象写的，与
  `docs/ai-collaboration-log.md` 的实际记录标题对不上，已逐条核到 86 条记录标题
  或 `deliverables/design_report.md` 的章节锚点；不可核验的改为文件锚点。
- `skill/pynq/pynq_selftest.py` 原先用 `skill/pynq/...` 这类相对仓库根的路径，
  从 `skill/` 目录调用时 13 个用例全红（0/13，看起来像判据坏了，其实是路径假设
  坏了）。改为相对 `__file__` 解析后，从仓库根、从 `skill/pynq/`、从全新导出的
  HEAD 副本运行都是 13/13；这条与 `pitfalls.md` P-14 同类，已把教训写进用例表注释。
- `run_vivado.tcl` 里 `report_check_timing` **不是 Vivado 命令**（真跑才暴露：
  `invalid command name`），改为 `check_timing -verbose -file`；`report_utilization
  -hierarchical` 只出层次表、解析器读不到资源汇总行，改为 summary 写 `util.rpt`、
  另存 `util_hier.rpt`；`check_impl_reports.py --dir` 的报告发现逻辑会选中
  `clock_util.rpt`，改为 `^util` + 排除 `hier`/`clock`。
- `-q` 曾把 `PASS/FAIL: n/m` 判决行一起吞掉（退出码成了唯一输出），
  `check_impl_reports.py` 与 `check_vectors.py` 改为无条件打印判决行，
  `--hist` 直方图也不再受 `-q` 影响。

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
