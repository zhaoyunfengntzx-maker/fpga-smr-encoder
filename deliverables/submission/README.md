# 提交成品包（2026-11-02 23:40 定版）

作品名称：**基于FPGA的细分编码器**

| 文件 | 对应官网项 | 说明 |
|---|---|---|
| `design_report.pdf` | **技术文档（必交，建议提交这份）** | **20 页 / 1.01 MB**；严格按《报告模版》：作品名称 / 摘要 / 五部分 + 附录 A/B/C；数字全部为 v74 口径 |
| `technical_doc.pdf` | 技术文档（另一版，15 页） | 15 页 / 0.91 MB；同一模板骨架的精简版，二选一 |
| `poster_a4.pdf` | 作品海报（选填，匿名提交版） | A4 竖版 210×297 mm / 0.10 MB；`poster/poster_A4_EN.pptx` 可重跑 |
| `poster_amd_a4.pdf` | 作品海报（A4 横版备选） | 297×210 mm / 0.34 MB；AMD 版式，匿名 |
| `poster_amd_official.pdf` | 作品海报（AMD 官方模板版） | 16:9 / 0.31 MB；`poster/build_amd_template.py` 可重跑 |
| `source_code.zip` | 全部代码（必交，≤200 MB） | **26.73 MB / 575 文件**；含 RTL、约束、仿真、上位机、技能包、设计报告与技术文档 PDF、海报、证据索引与 SHA256 清单；根目录有 `MANIFEST.sha256`（576 行，逐文件校验） |
| `intro_and_keywords.md` | 作品简介 / 三个关键词 | 可直接粘贴到提交系统 |
| `submission_checklist.md` | 全项对照 | 逐项状态、RAR 转换命令、GitHub 发布命令、视频拍摄要点 |

## 还差什么（都是必须由人完成的项）

1. **演示视频**：需实拍（转台 + 板卡 + 屏 + 上位机同框），本环境无采集设备、也无任何实拍素材；脚本见 `../video_script.md`。
2. **RAR**：RAR 是专有格式，本机无 `Rar.exe`（已确认 PATH 与 `C:\Program Files*` 均无），只能给等价 ZIP；请在装有 WinRAR 的机器上执行 `make_rar.bat`。
3. **授权书 PDF**：从大赛系统下载后签字/盖章扫描。
4. **GitHub 链接**：本地仓库已可推送，但还没有 remote。
5. **作品全貌图 / 开发板照片**：需实拍 1 + 最多 4 张。
6. **第 9 项声明**（其他赛事、往届获奖、是否教师科研/实验室项目）：需本人按实勾选。

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
