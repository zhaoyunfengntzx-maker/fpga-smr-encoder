# deliverables/ —— 竞赛提交物目录

> 本目录是 **2026 年第九届全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道（AMD 赛道 · 自主选题）**
> 的提交物工作区。**提交截止：2026-11-04 18:00**。
>
> ★ **本目录下的所有数字必须能追溯到仓库实测产物**。溯源表见
> [`evidence_index.md`](evidence_index.md)；权威进度入口仍是
> [`../docs/DEV_STATUS.md`](../docs/DEV_STATUS.md)（**唯一权威的"当前进度"入口**，本目录不另立口径）。

**当前基线 = v90（2026-11-04 判据，文档统一到这一版）**：

- **生产位流 = v90**（编码器本体，无 UI、无网，面向 2048 p/r 转台）：
  `data/v90/enc_top_v90.bit`（构建输出目录 `_synth_work_v90`，另有 `_impl_v90` 同哈希副本），**1,504,220 B**，
  SHA256 `A89512A506F9DE366863AC0C6BE2F740E453B32C35C6864D0D256D9C8F827125`，`BUILD 0x0019`；
  WNS **+0.199 ns** / WHS +0.017 / **0 失败端点（24,691）**；LUT **10,978 = 52.78%**、FF 8,724、BRAM **32/50**、DSP 17、IOB 60、DRC 0 Error。
  板上：**Z 频率 7.62 / 7.65 Hz ⇒ 457–459 rpm（每转 1 个 Z）**、UVW 六态计数 `{5174,4761,4423,4776,4763,4786}`、`lock = 0x0301`、60 s **597,886 帧 / 9,964.8 fps** 不丢帧、以太网 ping 4/4 + UDP 抓窗 28,672 点 @50 MSPS。
- **显示位流 = v90 显示版**：`data/v90/enc_top_disp_v90.bit`（构建输出目录 `_synth_work_v90`，另有 `_impl_disp_v90` 同哈希副本），**1,688,245 B**，
  SHA256 `69FE313C45C3F36D39307CE0948C6D0AB191183397E2408E694588FC5F81BAD4`；WNS **+0.221** / 0 失败（33,365）、WHS +0.049；
  LUT **17,090 = 82.16%**、FF 11,601、BRAM **45.5/50 = 91%**、DSP 20、IOB 104。**已写 Flash、冷启动通过**；**P1/P2/P4/P6 四页逐页人工核对通过（2026-11-04，报告 §7 R13 已关闭）**。
- **v90 相对 v74 的 RTL 改动只有两处**：`rtl/abz_gen.v` 新增 `z_index_gen`（`Z_ARM_DIST = 1<<(AW-3)`，出 Z 撤防、离开 ≥1/8 圈重新布防，治停位 Z 喘振）；
  `rtl/uvw_gen.v` **保持 v74 板级验证版**（`e_uw`/K=4 去抖版回退，勿再合）。派生脚本 `tools/make_v90_rtl.py`，`_synth_work_v90/VARIANT_INFO.txt` 逐行自检。
- 构建命令：生产 `tools/impl_check_v90.tcl`、显示 `tools/impl_check_disp_v90.tcl`；判据唯一入口 [`../docs/39_acceptance_criteria_v90.md`](../docs/39_acceptance_criteria_v90.md)。
- **参赛演示基线（历史）= v62**：编码器 + 5 页触摸 UI + 千兆网，1,694,505 B，2026-10-23 上板。视频素材若来自 v62，字幕必须标"v62 演示位流"。

---

## 1. 目录结构

```
deliverables/
├── README.md                    ← 本文件：提交物清单 + 状态 + 写作规范
├── design_report.docx/pdf       ★ 技术文档（《报告模版》骨架 + 五部分 + 附录）——29 页
├── design_report.md                 详细工程版源文件（185,526 B）
├── design_report_full.pdf       ← 详细工程版 60 页（md2pdf 导出，答辩技术底稿）
├── technical_doc.docx/pdf       ★ 另一版技术文档（同模板骨架，17 页，精简可读）
├── topic_proposal.md/.pdf           资格审查用 2 页选题说明（v90 口径）
├── evidence_index.md            ★ 每个数字 → 仓库里的可复核产物（报告引用的唯一数字源）
├── photo_shot_list.md               视频分镜 + 上板取证素材清单（v90，待拍项逐条打勾）
├── board_day_checklist.md           上板日执行单（屏验收/屏网并存/拔网断电/Z 游标/延迟/拍摄/记录表）
├── qa_prep.md                       答辩问答准备（11 问 + 缺口交代口径，v90）
├── teacher_brief.md                 指导教师/评委 5 分钟速览（v90、中性表述）
├── shoot_plan_2026-11-03.md         拍摄排期（时间盒 + 每镜头验收判据）
├── video_script.md / _v2 / _v3      三版视频脚本（v3 为当前版）
├── video_shooting_plan.md           分镜与拍摄执行计划
├── data/                        证据归档 **320 个文件 / 155,302,585 B**，`SHA256SUMS.txt` **323 条**（含覆盖 `../figures/` 的条目）
│   ├── bitstreams/ 27 · ila/ 21 · logs/ 17 · timing/ 23
│   ├── v62/ 13 · v66/ 20 · v67/ 12 · v68/ 25 · v70/ 24 · v71/ 26 · v73/ 26 · v74/ 26 · v85/ 16
│   └── v90/    ★ 当前基线：两个位流 + prod_*/disp_* 时序·利用率·DRC·IO·路径报告 + 构建日志 + VARIANT_INFO + SHA256SUMS
├── figures/                     报告插图 69 个文件（38 PNG / 13 PDF / 13 SVG / 4 JPG）
├── poster/                      ★ 海报三版（全部匿名、全部 v90 口径）：
│                                 `poster_amd_official.pptx` / `.pdf` / `.png`（AMD 官方模板，33.87×19.05 cm）
│                                 `poster_A4_EN.pptx` / `.pdf` / `.png`（A4 竖版 210×297 mm，提交用）
│                                 `poster_amd_A4.pptx` / `.pdf` / `.png`（A4 横版 297×210 mm，备选）
├── video_script.pdf             脚本导出 PDF
├── project_intro.docx/pdf       作品简介导出件（提交系统备用）
├── submission/                  ★ 提交系统用成品包（清单 / 简介与关键词 / 技术文档 / 海报 / 源码 zip / 实物照片）
│   └── photos/                   2026-11-03 实拍：全貌图 1 张 + 开发板角度 3 张（均 ≤10 MB，含屏上读数说明）
└── video/                       视频工作区：`assets/` CG 片段与静帧 + `subs/` 3 条 SRT + `narration_v2.md` / `narration_v3.md`
```

## 2. 提交物清单与状态（对照官网表单）

| # | 官网字段 | 本目录对应文件 | 状态 |
|---|---|---|---|
| 1 | 作品名称 | 基于FPGA的细分编码器 | 🟢 全文统一，无别名 |
| 2 | 演示视频（MP4/AVC/≤3 min/≤300 MB） | `video_script_v3.md` + `video/assets/` CG + `video/subs/` SRT；成片在 `video/` | 🔴 **未成片**：需真实转台 + 触摸屏 + 上位机同框实拍 |
| 3 | 技术文档（PDF/≤50 MB/按模板） | `submission/design_report.pdf`（2,010,758 B）+ `submission/technical_doc.pdf`（988,465 B），二选一提交，建议用 design_report | ✅ 已按 v90 重导（2026-11-04，29 页）；零身份信息，见 §5 |
| 4 | 全部代码（RAR/≤200 MB） | `submission/source_code.zip`（**995 条目**，63.52 MB，含 `MANIFEST.sha256`）+ `make_rar.bat` | 🟡 **本机无 WinRAR/Rar.exe**，只能产出 ZIP；须在装有 WinRAR 的机器上执行 `make_rar.bat` 转 RAR |
| 5 | 参赛作品承诺及使用授权书（PDF） | `submission/authorization_letter.pdf`（1 页 / 662,110 B） | 🟢 **已签署（2026-11-03）**：全体队员签名齐全；实名件只提交大赛系统 |
| 6 | 作品海报（选填，PDF/PPT/≤50 MB） | `poster/poster_A4_EN.pdf`（104,803 B）、`poster/poster_amd_A4.pdf`（354,000 B）、`poster/poster_amd_official.pdf`（326,045 B） | 🟢 三版均已重建、零身份信息（海报图形未随 v90 重出，见遗留） |
| 7 | GitHub 链接 | [https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder](https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder)（`main`，MIT） | 🟢 **已推送开源** |
| 8 | 作品全貌图（JPG/PNG ≤10 MB ×1） | `submission/photos/01_overview_full.jpg`（7,222,120 B） | 🟢 **已拍摄（2026-11-03）**：转台夹具 + 传感头 + 模拟板 + AD9238/FPGA + 7 寸屏 + 示波器 + 上位机同框 |
| 9 | 开发板重要角度高清照片（≤4 张） | `submission/photos/`：`02_board_adc_frontend.jpg`、`03_board_front.jpg`、`04_board_screen.jpg` | 🟢 **已拍摄 3 张**（4 张上限内），见 `submission/photos/README.md` |
| 10 | 作品简介 | `submission/intro_and_keywords.md`（中性叙事 + 7 个关键词，v90） | 🟢 完成 |
| 11 | 是否参加其他赛事/往届获奖 | 建议口径见 `submission/form_answers.md` §4 | 🔴 **待按实勾选** |
| 12 | 是否为老师科研项目/实验室作品 | 建议口径见 `submission/form_answers.md` §5 | 🔴 **待按实勾选**（本项目为自主选题） |
| 13 | 三个创新关键词 | 闭式自校准 / 多协议高速输出适配 / FPGA 正余弦高精度细分 | 🟢 完成 |
| — | （附加）证据归档 | `data/`：320 个文件、155,302,585 B、`SHA256SUMS.txt` 323 条 | 🟢 可复核：`cd deliverables/data` 后逐条校验 |

## 3. 写作三条硬规则（`../docs/02_innovation_scoring.md` §3 的要求，本目录强制执行）

1. **每个结论后面跟一个数字**。
   ✗「校正效果好」 → ✓「复合畸变下电角度误差从 20.9839° 降至 0.0165°，改善 1273 倍」。
2. **`[仿真]` / `[实测]` / `[构建签核]` / `[设计值]` 必须显式标注**，混标是重灾区。
   - `[仿真]` = xsim 回归（`sim/` **37 台** + `disp/` **20 台** = **57 台全 PASS**）
   - `[实测]` = **板级**读数（UART / 屏摄 / 示波器 / 以太网抓包），判据见 `../docs/39_acceptance_criteria_v90.md`
   - `[构建签核]` = Vivado 报告（`data/v90/prod_*.rpt` / `disp_*.rpt`）
   - `[设计值]` = 预算或推导值，**尚未实测**（**延迟 ≈830 ns 属此类**）
3. **图和表要能独立看懂**（图题写全，含工况与单位）。

## 4. 基线口径（写报告/海报前必读）

| 口径 | 内容 |
|---|---|
| **★ 签核位流 = v90 生产（2026-11-04）** | `data/v90/enc_top_v90.bit` **1,504,220 B**、SHA256 `A89512A5…`、`BUILD 0x0019`；内容 = 编码器本体（无 UI、无网），面向 2048 p/r 转台。WNS **+0.199** / TNS 0.000 / **0 失败 / 24,691 端点**；WHS +0.017；LUT **10,978 = 52.78%**、FF 8,724 = 20.97%、BRAM **32/50**、DSP 17、IOB 60。**板上**：457–459 rpm（Z 7.62/7.65 Hz）、UVW 六态均衡、60 s 597,886 帧不丢、ping 4/4 + UDP 抓窗。**时序签核以这一版为准。** |
| ★ v90 显示位流 | `data/v90/enc_top_disp_v90.bit` **1,688,245 B**、SHA256 `69FE313C…`；WNS **+0.221** / 0 失败 / 33,365 端点；WHS +0.049；LUT **17,090 = 82.16%**、FF 11,601、BRAM **45.5/50 = 91%**、DSP 20、IOB 104。已写 Flash、冷启动通过；逐页目视记录未逐条留图。 |
| 历史：v74（2026-11-02） | 生产 1,512,664 B（v74 期位流）、显示 1,700,821 B；生产 LUT 10,926 = 52.5%（四位小数的原值仅见 `evidence_index.md` §8 沿革）、BRAM 32/50。v90 在其基础上只加 Z 索引发生器，另删 P7 标定整页与 P1 标定按钮。**引用时标"历史"。** |
| 历史：参赛演示基线 = v62（2026-10-23） | `data/v62/enc_top_v62.bit` 1,694,505 B；编码器 + 5 页触摸 UI + 千兆网；LUT 82.01%、BRAM 46/50。**这是"一块板完成采集—运算—显示—上传"的演示口径。** |
| 历史：编码器单机基线 = v12（2026-10-13） | `data/bitstreams/enc_top_v12_prod.bit` 1,042,208 B，LUT 6,298 = 30.28%；用来说明「编码器本身只占 30%，其余资源是屏与网」。 |
| 调试位流 = ILA 版 | `data/bitstreams/enc_top_v12_ila.bit` 1,428,064 B + `enc_top_ila.ltx`（36 条命名探针）。★ **v62 起无 ILA 版本**：BRAM 见底，任何调试必须单独出 ILA 位流（报告 §7 R12）。 |

> ⚠️ `../docs/02_innovation_scoring.md` 里的 6010 LUT / 8822 LUT / WNS −3.352 / 1,445,812 B / 34 探针
> 是 **v6 时代快照**，引用前必须按 [`evidence_index.md`](evidence_index.md) 换成现行值。

## 5. 匿名性（提交前必须保持）

- **禁止出现**：学校名、学院名、校徽、指导教师姓名、团队姓名、学号、邮箱、省市等身份信息。作品名称统一为 **基于FPGA的细分编码器**。
- **禁止出现**：具体厂商芯片型号；也禁止任何把本作品描述成某颗现成芯片的等价实现或固件移植的说法；对外材料只讲"用一片 FPGA 完成正余弦细分全信号链"。
- 已处理：`poster/poster_amd_official_named.*`（含校名的旧版）与生成脚本 `poster/build_poster.py` **已删除**；`poster/build_amd_template.py` 改用 `is_sample_identity()` 按"位置 + 形态"删除模板示例作者/单位。
- 检查脚本：`.tmp\verify_docs.py` 对 docx/pdf 做 LEAK/STALE/WANT 三表核查；海报用同一套词表抽 pptx 文本复查。唯一允许的"大学"来自赛事全称"全国大学生嵌入式芯片与系统设计竞赛"。

## 6. 导出 PDF / PNG（本机没有 LibreOffice）

```powershell
# 1) docx -> pdf（Word 晚绑定；本机 Word 类型库损坏，只能用 VBS）
cscript //nologo tools\docx2pdf.vbs "C:\Users\zhaoy\Desktop\FPGA\deliverables\design_report.docx"  "C:\Users\zhaoy\Desktop\FPGA\deliverables\design_report.pdf"
cscript //nologo tools\docx2pdf.vbs "C:\Users\zhaoy\Desktop\FPGA\deliverables\technical_doc.docx" "C:\Users\zhaoy\Desktop\FPGA\deliverables\technical_doc.pdf"

# 2) pptx -> pdf + 首屏 PNG（PowerPoint 晚绑定）
cscript //nologo tools\pptx2pdf.vbs "C:\Users\zhaoy\Desktop\FPGA\deliverables\poster\poster_amd_official.pptx" "C:\Users\zhaoy\Desktop\FPGA\deliverables\poster\poster_amd_official.pdf" "C:\Users\zhaoy\Desktop\FPGA\.tmp\poster_png" 3200

# 3) 详细工程版（61 页，无头 Edge 打印）
& E:\Anaconda\python.exe tools\md2pdf.py deliverables\design_report.md
```

当前体积（Test-Path 实测）：`design_report.pdf` 2,010,758 B（2.01 MB）；`technical_doc.pdf` 988,465 B；`design_report_full.pdf` 5,607,751 B；`submission/design_report.pdf` 2,010,758 B。

## 7. 本轮（v90）文档改写的遗留

1. `design_report.docx/pdf` 是按 v74 口径导出的，**正文已部分改写为 v90（`design_report.md`），PDF 未重导** —— 提交前需重跑 §6 的三条命令。
2. 海报三版图形未随 v90 重出（pdf/png 仍是上一版画面），只保证文字口径在 `README`/`evidence_index`/`qa_prep` 里正确。
3. `submission/source_code.zip` 与 `authorization_letter.pdf` 是二进制快照，本轮未重建；zip 内 `.md` 仍是打包时版本。
