# deliverables/ —— 竞赛提交物目录

> 本目录是 **2026 年第九届全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道（AMD 赛道 · 自主选题）**
> 的提交物工作区。**提交截止：2026-11-04 18:00**。
>
> ★ **本目录下的所有数字必须能追溯到仓库实测产物**。溯源表见
> [`evidence_index.md`](evidence_index.md)；权威进度入口仍是
> [`../docs/DEV_STATUS.md`](../docs/DEV_STATUS.md)（**唯一权威的"当前进度"入口**，本目录不另立口径）。

**当前基线（2026-11-02 重新签核，文档与海报统一到这一版）**：

- **生产位流 = v74 生产版**（编码器本体，无 UI、无网，面向 2048 p/r 转台）：
  `_impl_v74/enc_top_v74.bit`，**1,512,664 B**，SHA256 `E46349073DE53B7602A8C2A33E68832BE4B4E6A995E753A64E8D88A68CDA2680`，`BUILD 0x0018`；
  WNS **+0.409 ns** / WHS +0.025 / **0 失败端点（24,625）**；LUT **10,926 = 52.53%**、FF 8,697、BRAM **32/50**、DSP 17、DRC 0 Error（45 checks 全 Warning）。
  板上：**719–740 rpm（稳态窗口 719–731 rpm）**、Z ≈12 Hz、UVW 六态均衡、以太网 ping + UDP 抓窗通过。
- **显示位流 = v74 显示版**（2026-11-02 23:00:37 重建，含 v75–v82 界面改动）：
  `_impl_disp_v74/enc_top_disp_v74.bit`，**1,700,821 B**，SHA256 `72FF4D13F45B0D02CBAA6B1B3D355AAA92745FF069AE9C13AE0586216249C395`；
  WNS **+0.422** / 0 失败（34,499）、WHS +0.024；LUT **17,604 = 84.63%**、FF 11,946、BRAM **48/50**、DSP 22、IOB 104；DRC 108 checks 全 Warning。
  状态：**构建签核，未目视验收**（板卡 USB 未枚举，`_flash2_work/prog_v82.log` 记录 `ERROR: [Labtoolstcl 44-199] No matching targets found`）——文档中一律照此标注，不得写成"已上板"。
- **参赛演示基线 = v62**（编码器 + 5 页触摸 UI + 千兆网，1,694,505 B，2026-10-23 上板）；视频素材若来自 v62，字幕必须标"v62 演示位流"。
- v74 = v71 RTL + Z 脉冲计数探针，`tools/make_v74_rtl.py` 从 `rtl/` 派生，**与 `rtl/` 仅差 `RTL_BUILD_ID`（0x0015 → 0x0018）一行**；`_synth_work_v74/VARIANT_INFO.txt` 逐行自检。

---

## 1. 目录结构

```
deliverables/
├── README.md                    ← 本文件：提交物清单 + 状态 + 写作规范
├── design_report.docx/pdf       ★ 技术文档（按《报告模版》：作品名称/摘要/五部分 + 附录 A/B/C）——21 页
├── design_report_full.pdf       ← 详细工程版 60 页（md2pdf 导出，答辩技术底稿）
├── design_report.md                 详细工程版源文件
├── technical_doc.docx/pdf       ★ 另一版技术文档（同一模板骨架，15 页，面向"精简可读"）
├── topic_proposal.md/.pdf           资格审查用 2 页选题说明
├── evidence_index.md            ★ 每个数字 → 仓库里的可复核产物（报告引用的唯一数字源）
├── photo_shot_list.md               视频分镜 + 上板取证素材清单（待拍项逐条打勾）
├── board_day_checklist.md           上板日执行单（屏验收/屏网并存/拔网断电/Z 游标/延迟/拍摄/记录表）
├── qa_prep.md                       答辩问答准备（10 问 + 标准答法 + 缺口交代口径）
├── data/                        证据归档 **294 个文件 / 149,157,322 B**，`SHA256SUMS.txt` **299 条**（280 条覆盖本目录 + 19 条覆盖 `../figures/`），**已实测 299/299 全部校验通过**
│   ├── bitstreams/ 27 · ila/ 21 · timing/ 23 · logs/ 17 · v62/ 13 · v66/ 20 · v67/ 12 · v68/ 25 · v70/ 24 · **v74/ 24**
│   └── v74/    ★ 本轮新增：v74 生产 + v74 显示的位流、时序/利用率/DRC/IO/路径报告、构建日志、VARIANT_INFO
├── figures/                     报告插图（框图/标定/残差/ILA/格点/机械/屏照，31 张 PNG，每图另有 pdf/svg）
├── poster/                      ★ 海报三版（全部匿名、全部 v74 数字）：
│                                 `poster_amd_official.pptx/.pdf/.png`（AMD 官方模板，33.87×19.05 cm）
│                                 `poster_A4_EN.pptx/.pdf/.png`（A4 竖版 210×297 mm，提交用）
│                                 `poster_amd_A4.pptx/.pdf/.png`（A4 横版 297×210 mm，备选）
├── video_script.md/.pdf         演示视频脚本（3:00 / 29 镜 / 旁白 + 分镜 + 特效 + 拍摄表），待实拍
├── submission/                  ★ 提交系统用成品包（清单 / 简介与关键词 / 技术文档 / 海报 / 源码 zip / 实物照片）
│   └── photos/                   ★ 2026-11-03 实拍：全貌图 1 张 + 开发板角度 3 张（均 ≤10 MB，含屏上读数说明）
└── video/                       视频工作区：`assets/` 3 段 CG（41.5 拍 / 系统框图 / 片尾）+ `subs/` 22 条 SRT
```

## 2. 提交物清单与状态（对照官网表单）

| # | 官网字段 | 本目录对应文件 | 状态 |
|---|---|---|---|
| 1 | 作品名称 | 基于FPGA的细分编码器 | 🟢 全文统一，无别名 |
| 2 | 演示视频（MP4/AVC/≤3 min/≤300 MB） | `video_script.md/.pdf` + `video/assets/` 3 段 CG；成片在 `video/` | 🔴 **未成片**：本机无采集设备，需真实转台 + 触摸屏 + 上位机同框实拍 |
| 3 | 技术文档（PDF/≤50 MB/按模板） | `design_report.pdf`（21 页 / 1.25 MB）+ `technical_doc.pdf`（15 页 / 0.91 MB），二选一提交，建议用 `design_report.pdf` | 🟢 完成（零身份信息，见 §5） |
| 4 | 全部代码（RAR/≤200 MB） | `submission/source_code.zip`（ZIP 等价物）+ `make_rar.bat` | 🟡 **本机无 WinRAR/Rar.exe**，只能产出 ZIP；须在装有 WinRAR 的机器上执行 `make_rar.bat` 转 RAR |
| 5 | 参赛作品承诺及使用授权书（PDF） | — | 🔴 **待签署**：从大赛系统下载模板，签字/盖章后扫描为 PDF |
| 6 | 作品海报（选填，PDF/PPT/≤50 MB） | `poster/poster_A4_EN.pdf`（A4 竖版）、`poster/poster_amd_A4.pdf`（A4 横版）、`poster/poster_amd_official.pdf`（官方模板 16:9） | 🟢 三版均已重建为 v74 口径、零身份信息 |
| 7 | GitHub 链接 | [https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder](https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder)（`main` @ `12c59ab`，tag `v1.0.0`） | 🟢 **已推送开源**（MIT，工作树干净） |
| 8 | 作品全貌图（JPG/PNG ≤10 MB ×1） | `submission/photos/01_overview_full.jpg`（8064×6048 / 6.89 MB） | 🟢 **已拍摄（2026-11-03 20:02）**：转台夹具 + 传感头 + 模拟板 + AD9238/FPGA + 7 寸屏 + 示波器 + 上位机同框 |
| 9 | 开发板重要角度高清照片（≤4 张） | `submission/photos/`：`02_board_adc_frontend.jpg`（ADC 模拟前端）、`03_board_front.jpg`（FPGA 板正面）、`04_board_screen.jpg`（屏与触摸，P1 实时读数） | 🟡 **已拍 3/4 类**；磁环气隙特写仍缺（四张名额已用满，补拍需替换，见 `submission/photos/README.md`） |
| 10 | 作品简介 | `submission/intro_and_keywords.md`（v74 口径，可直接粘贴） | 🟢 完成 |
| 11 | 是否参加其他赛事/往届获奖 | 建议口径见 submission/form_answers.md §4 | 🔴 **待你按实勾选** |
| 12 | 是否为老师科研项目/实验室作品 | 建议口径见 submission/form_answers.md §5 | 🔴 **待你按实勾选**（本项目为自主选题） |
| 13 | 三个创新关键词 | 闭式自校准 / 多协议高速输出适配 / FPGA 正余弦高精度细分 | 🟢 完成（2026-11-03 定稿） |
| — | （附加）证据归档 | `data/`：294 个文件、149,157,322 B、`SHA256SUMS.txt` 299 条 | 🟢 可复核：`cd deliverables/data` 后按 `SHA256SUMS.txt` 逐条校验，**实测 299/299 通过**（含 19 条 `../figures/`） |

## 3. 写作三条硬规则（`../docs/02` §3 的要求，本目录强制执行）

1. **每个结论后面跟一个数字**。
   ✗「校正效果好」 → ✓「复合畸变下电角度误差从 20.9839° 降至 0.0165°，改善 1273 倍」。
2. **`[仿真]` / `[实测]` / `[手册]` / `[设计值]` 必须显式标注**，混标是重灾区。
   - `[仿真]` = Vivado xsim 主回归（`sim/` **36 台** + `disp/` 顶层 **18 台** = **54 台**，`disp/legacy/` 另有 9 台历史台不计入）；`_boardtest/` 定向台（`tb_acc2`/`tb_uvw`/`tb_uvw_rev`/`tb_dbg6`，本机用 ModelSim）；Python 定点模型
   - `[实测]` = **板级**读数（ILA / UART / 示波器 / 逻辑分析仪 / 以太网抓包）
   - `[手册]` = iC-TW28 / AD9238 / 正点原子开发指南原文
   - `[设计值]` = 预算或推导值，**尚未实测**（**延迟 ≈830 ns 属此类**）
3. **图和表要能独立看懂**（图题写全，含工况与单位）。

## 4. 基线口径（写报告/海报前必读）

| 口径 | 内容 |
|---|---|
| **★ 签核位流 = v74 生产（2026-11-02）** | `_impl_v74/enc_top_v74.bit` **1,512,664 B**、SHA256 `E4634907…DA2680`、`BUILD 0x0018`；内容 = 编码器本体（无 UI、无网），面向 2048 p/r 转台。WNS **+0.409** / TNS 0.000 / **0 失败 / 24,625 端点**；WHS +0.025；LUT **10,926 = 52.53%**、FF 8,697 = 20.91%、BRAM **32/50**、DSP 17、Bonded IOB 60；DRC 0 Error（45 checks 全 Warning）。**板上**：719–740 rpm（稳态 719–731）、Z ≈12 Hz、UVW 六态均衡、ping + UDP 通过。**时序签核以这一版为准。** |
| ★ v74 显示位流（构建签核，**未目视验收**） | `_impl_disp_v74/enc_top_disp_v74.bit` **1,700,821 B**、SHA256 `72FF4D13…49C395`；WNS **+0.422** / 0 失败 / 34,499 端点；LUT 17,604 = **84.63%**、FF 11,946 = 28.72%、BRAM **48/50**、DSP 22、IOB 104；DRC 108 checks 全 Warning。含 v75–v82 界面改动（P2 三档时基、P4 双窗口、P1 面板压暗、P7 零线 + GAIN、P4 scope 等）。 |
| 参赛演示基线 = v62（2026-10-23） | `data/v62/enc_top_v62.bit` **1,694,505 B**、SHA256 `EC0B383B6BC2068D0CDEC2F70B6DD58F2EDFF714B8A345B65912E43B96BE47EB`；编码器 + 5 页触摸 UI + 千兆网。WNS **+0.471** / WHS +0.042 / 0 失败 / 33,255 端点；LUT **17,059 = 82.01%**、FF 11,193、BRAM **46/50**、DSP 18、IOB 107。**这是"一块板完成采集—运算—显示—上传"的演示口径。** |
| 编码器单机基线 = v12（2026-10-13） | `data/bitstreams/enc_top_v12_prod.bit` **1,042,208 B**、SHA256 `D93DEBF9…`，读回 `0x05F2` = `0x000C`；LUT 6,298 = 30.28% / WNS **+0.959** / 11,275 端点。用于说明「编码器本身只占 30%，其余资源是屏与网」。 |
| 屏基线 = v59 / v60 | v59：五页 UI 单独位流 14,263 LUT = 68.57%、BRAM 48.5、WNS +0.586、1,732,625 B；v60：加网后 16,518 LUT = 79.41%、WNS +0.203、1,676,717 B。 |
| 调试位流 = v12 ILA 版 | `data/bitstreams/enc_top_v12_ila.bit` **1,428,064 B**、SHA256 `5CC779EE…` + `enc_top_ila.ltx`（36 条命名探针 / 269 bit）。★ **v62 起无 ILA 版本**：BRAM 见底，任何调试必须单独出 ILA 位流（见报告 §7 R12）。 |
| 历史版本 | v6–v11 生产/ILA 位流与 en 系列时序报告在 `data/bitstreams/`、`data/timing/`，`data/README.md` 有逐条说明。 |

> ⚠️ `../docs/02_innovation_scoring.md` 里的 6010 LUT / 8822 LUT / WNS −3.352 / 1,445,812 B / 34 探针
> 是 **v6 时代快照**，引用前必须按 [`evidence_index.md`](evidence_index.md) 换成现行值。

## 5. 匿名性（提交前必须保持）

- **禁止出现**：学校名、学院名、校徽、指导教师姓名、团队姓名、学号、邮箱、省市等身份信息。作品名称统一为 **基于FPGA的细分编码器**。
- 已处理：`poster/poster_amd_official_named.*`（含校名的旧版）与生成脚本 `tools/make_named_poster.py` **已删除**；`poster/build_amd_template.py` 改用 `is_sample_identity()` 按"位置 + 形态"删除模板示例作者/单位，脚本里不再出现任何具体校名或人名。
- 检查脚本：`E:\Anaconda\python.exe .tmp\verify_docs.py` 对两个 docx + 两个 pdf 做 LEAK/STALE/WANT 三表核查；海报用同一套词表抽 pptx 文本复查。唯一允许的"大学"来自赛事全称"全国大学生嵌入式芯片与系统设计竞赛"。

## 6. 导出 PDF / PNG（本机没有 LibreOffice）

```powershell
# 1) docx -> pdf（Word 晚绑定；本机 Word 类型库损坏，只能用 VBS）
cscript //nologo tools\docx2pdf.vbs "C:\Users\zhaoy\Desktop\FPGA\deliverables\design_report.docx"  "C:\Users\zhaoy\Desktop\FPGA\deliverables\design_report.pdf"
cscript //nologo tools\docx2pdf.vbs "C:\Users\zhaoy\Desktop\FPGA\deliverables\technical_doc.docx" "C:\Users\zhaoy\Desktop\FPGA\deliverables\technical_doc.pdf"

# 2) pptx -> pdf + 首屏 PNG（PowerPoint 晚绑定）
cscript //nologo tools\pptx2pdf.vbs "C:\Users\zhaoy\Desktop\FPGA\deliverables\poster\poster_amd_official.pptx" "C:\Users\zhaoy\Desktop\FPGA\deliverables\poster\poster_amd_official.pdf" "C:\Users\zhaoy\Desktop\FPGA\.tmp\poster_png" 3200

# 3) 详细工程版（60 页，无头 Edge 打印）
& E:\Anaconda\python.exe tools\md2pdf.py deliverables\design_report.md
```

当前页数与体积：`design_report.pdf` **21 页 / 1,254,450 B**；`technical_doc.pdf` **15 页 / 954,851 B**；`design_report_full.pdf` **60 页 / 4,954,432 B**。
（2026-11-03 重建：报告新增技能包可执行资产段落与通用 PYNQ 子包段落，并修正正文里残留的 Markdown 反引号，故页数由 23 → 21。）
