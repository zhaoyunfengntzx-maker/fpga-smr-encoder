# 提交成品包（2026-11-04 v90 口径核对；PDF 仍为 v74 期导出）

作品名称：**基于FPGA的细分编码器**

| 文件 | 对应官网项 | 说明 |
|---|---|---|
| `design_report.pdf` | **技术文档（必交，建议提交这份）** | **26 页 / 1.67 MB**；严格按《报告模版》：作品名称 / 摘要 / 五部分 + 附录 A/B/C；v90 口径（2026-11-04 重导）；附录 B 已含技能包四类可执行资产 |
| `technical_doc.pdf` | 技术文档（另一版，16 页） | 16 页 / 0.97 MB；同一模板骨架的精简版，二选一 |
| `poster_a4.pdf` | 作品海报（选填，匿名提交版） | A4 竖版 210×297 mm / 0.10 MB；`poster/poster_A4_EN.pptx` 可重跑 |
| `poster_amd_a4.pdf` | 作品海报（A4 横版备选） | 297×210 mm / 0.34 MB；AMD 版式，匿名 |
| `poster_amd_official.pdf` | 作品海报（AMD 官方模板版） | 16:9 / 0.31 MB；`poster/build_amd_template.py` 可重跑 |
| `source_code.zip` | 全部代码（必交，≤200 MB） | **63.33 MB / 943 条目**（942 个内容文件 + `MANIFEST.sha256`，另有 57 个目录项）；含 RTL（含 `rtl/eth`、`rtl/ddr3`）、约束、仿真与逐台日志、`model/` 黄金模型、上位机、技能包（7 篇长文 + 19 项可执行资产 + 通用 PYNQ 子包）、设计报告与技术文档 PDF、海报、实物照片（`submission/photos/` 4 张 + 报告用缩放图）、v90 两个交付位流与全部 `.rpt`、证据索引与 SHA256 清单；根目录 `MANIFEST.sha256` 942 行，逐文件校验 942/942；`tools/verify_source_package.py` 一键复核（唯一未解析的 20 条链接指向文档化的 `.bit/.csv` 体积排除项） |
| `intro_and_keywords.md` | 作品简介 / 关键词 | **v90 口径已重写（2026-11-04）**：中性叙事、无厂商芯片型号、7 个关键词，可直接粘贴到提交系统 |
| `photos/` | 作品全貌图（第 6 项）+ 开发板重要角度照片（第 7 项） | 2026-11-03 20:02 实拍 4 张，`01_overview_full` / `02_board_adc_frontend` / `03_board_front` / `04_board_screen`，均 ≤10 MB；逐张说明与屏上读数见 `photos/README.md` |
| `authorization_letter.pdf` | 参赛作品承诺及使用授权书（必交） | **1 页 / 662,110 B**；2026-11-03 打印后全体队员签名、扫描（2416×3612 px / RGB / A4 / ≈292 dpi）；实名件，只交大赛系统，不进仓库匿名材料 |
| `submission_checklist.md` | 全项对照 | 逐项状态、RAR 转换命令、GitHub 发布命令、视频拍摄要点 |

## 还差什么（都是必须由人完成的项）

1. **演示视频**：需实拍（转台 + 板卡 + 屏 + 上位机同框），本环境无采集设备、也无任何实拍素材；现行脚本见 `../video_script_v3.md`（v90 口径），执行清单见 `../photo_shot_list.md`。
2. **RAR**：RAR 是专有格式，本机无 `Rar.exe`（已确认 PATH 与 `C:\Program Files*` 均无），只能给等价 ZIP；请在装有 WinRAR 的机器上执行 `make_rar.bat`。
3. **实物照片已齐**：全貌图与 3 张角度照归档在 `photos/`，第 6 项与第 7 项（正面 / ADC 模拟前端 / 屏与触摸）均已满足，不再另拍。
4. **第 9 项声明**（其他赛事、往届获奖、是否教师科研/实验室项目）：需本人按实勾选。

> 已结项：授权书 `authorization_letter.pdf`（2026-11-03 全体队员签名扫描）、GitHub 仓库已上线（见 `submission_checklist.md` §4）。

## 复现文档与海报（本机没有 LibreOffice）

```bat
:: 1) docx（Word 晚绑定导出 PDF；本机 Word 类型库损坏，只能用 VBS）
python tools\build_report_doc.py
cscript //nologo tools\docx2pdf.vbs "%CD%\deliverables\design_report.docx" "%CD%\deliverables\design_report.pdf"

python tools\build_tech_doc.py
cscript //nologo tools\docx2pdf.vbs "%CD%\deliverables\technical_doc.docx" "%CD%\deliverables\technical_doc.pdf"

:: 2) 海报（python-pptx 在捆绑 Python 里；导出用 PowerPoint 晚绑定）
"C:\Users\zhaoy\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" deliverables\poster\build_poster.py
cscript //nologo tools\pptx2pdf.vbs "%CD%\deliverables\poster\poster_A4_EN.pptx" "%CD%\deliverables\poster\poster_A4_EN.pdf" "%CD%\.tmp\png_a4_en" 2480

:: 3) 源码包
python tools\make_source_package.py
```
