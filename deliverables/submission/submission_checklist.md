# 提交清单与状态（2026-11-03 19:20 定版，仓库提交 12c59ab / tag v1.0.0）

> 作品名称统一为 **基于FPGA的细分编码器**。本清单只使用该名称，不含学校、指导教师、团队等信息。

## 一、必交项

| # | 项目 | 状态 | 文件 / 说明 |
|---|---|---|---|
| 1 | 演示视频（MP4 / AVC(H264) / ≤3 min / ≤300 MB） | **脚本完成，待录制** | 脚本 `../video_script.md` / `.pdf`（3:00、29 镜、旁白逐句时间码、特效与拍摄表）；成片需真实转台 + 触摸屏 + 上位机同框，本机无采集设备、无实拍素材，无法代录 |
| 2 | 技术文档（PDF / ≤50 MB / 按模板） | ✅ 完成 | 主用 `design_report.pdf`（23 页 / 0.96 MB，严格按《报告模版》）；备选 `technical_doc.pdf`（15 页 / 0.91 MB，同骨架精简版）。两者均为 v74 口径、零身份信息 |
| 3 | 全部代码（RAR / ≤200 MB） | ⚠ 已整理，待转 RAR | `source_code.zip`（**29,609,202 B / 617 文件**，含 `design_report.docx/pdf`、`technical_doc.pdf`、三版海报、`fig_*`、`data/*/README.md` 与 `SHA256SUMS.txt`；`MANIFEST.sha256` 逐文件 617/617 校验通过）；本机未安装 WinRAR，已附 `make_rar.bat` |
| 4 | 参赛作品承诺及使用授权书（PDF） | **待签署** | 从大赛系统下载后签字/盖章扫描；程序无法代签 |
| 5 | GitHub 链接 | ✅ 已开源 | [https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder](https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder)（MIT，`main` 默认分支，tag `v1.0.0`） |
| 6 | 作品全貌图（JPG/PNG ≤10 MB ×1） | **待拍摄** | 需作品整体（转台 + 板卡 + 屏 + 传感器）；可用 `deliverables/figures/fig1_system_architecture.png` 作系统示意，但不能替代实物全貌 |
| 7 | 开发板重要角度照片（JPG/PNG ≤10 MB，≤4 张） | **待拍摄** | 建议：正面、ADC/模拟前端、屏与触摸、传感器与磁环气隙 |
| 8 | 作品简介 | ✅ 完成 | `intro_and_keywords.md`（v74 口径，可直接粘贴） |
| 9 | 是否参加其他赛事 / 往届获奖 / 是否教师科研或实验室作品 | **待确认** | 需你按实际情况勾选，不能代填；建议口径与逐项可复制文本见 `form_answers.md` §4/§5 |
| 10 | 三个创新关键词 | ✅ 完成 | 闭式自校准 / 多协议同源 / 高精度细分 |


> 报名系统每一项的可复制文本（作品名称、简介、关键词、两项声明、附件对照）见 `form_answers.md`。

## 二、选填项

| 项目 | 状态 | 文件 |
|---|---|---|
| 作品海报（PDF/PPT ≤50 MB） | ✅ 完成（三版，均匿名、均 v74 口径） | 提交用 A4 竖版 `poster_a4.pdf`（0.10 MB）；A4 横版 `poster_amd_a4.pdf`（0.34 MB）；AMD 官方模板版 `poster_amd_official.pdf`（0.31 MB）。生成脚本 `../poster/build_poster.py`、`build_poster_amd.py`、`build_amd_template.py` |

## 三、RAR 打包说明

本机没有 WinRAR（`Rar.exe`），且安装需要管理员权限，所以先给出等价 ZIP。请在装有 WinRAR 的机器上执行：

```bat
rem 双击本目录的 make_rar.bat 即可（自动查找 WinRAR 并生成 source_FPGA_encoder.rar）
```

或右键 `_pkg\FPGA_encoder_source` →「添加到压缩文件」→ 格式选 RAR5 → 压缩级别「最好」。压缩包根目录应直接是 `README.md`、`rtl/`、`sim/` 等，不要再套一层同名目录。

## 四、GitHub 发布说明

仓库已上线：**[https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder](https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder)**（Public，MIT）。

- `main` 是**单提交的公开历史**（`12c59ab`，tag `v1.0.0`），刻意不带旧提交，避免把厂商 PDF 与 166 MB 中间产物带进公开仓库；完整旧历史保留在本地 `history` 分支（tag `archive-pre-release`），未上传。
- 克隆：`git clone https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder.git`
- 仓库含 `LICENSE`（MIT）、`README.md`、`skill/`、`docs/ai-collaboration-log.md`、`deliverables/` 文档与 291 个证据文件（142 MB）。
- 复现入口：`README.md` §快速开始、`docs/REPRODUCE.md`、`docs/COMPLIANCE.md`。

> 推送提示：作者所在网络对大文件 HTTPS 上行返回 403（约 1–2 MB 以上即失败），最终改用 SSH-over-443 推送：
> `ssh://git@ssh.github.com:443/<账号>/<仓库名>.git`。如你 Fork 后推送遇到 `RPC failed; HTTP 403`，可直接改用该地址。

## 五、视频拍摄建议（3 分钟内）

完整脚本见 `../video_script.md`（PDF 12 页）：§1 三幕结构、§2 旁白逐句时间码、§3 29 个镜头卡片（画面/机位/光/声音/字幕/后期/素材状态）、§4 特效清单、§5 拍摄执行、§6 后期与导出、§7 素材缺口。拍摄顺序与时长按脚本执行即可；以下只留五条骨架：

1. 0:00–0:35 问题：微距灰尘/油膜 + 不完美正弦 + “黑盒”；
2. 0:35–1:20 方案：板卡上电、框图生长、椭圆变圆、41.5 拍动画、五路同源；
3. 1:20–2:42 证明：转台启动、屏读数、示波器 ABZ/UVW、抓包、60 s 长跑、两个死锁与修复；
4. 2:42–3:00 收束：转速慢下来、角度锁定、片名；
5. 屏幕素材若来自 v62 演示位流，字幕必须标“v62 演示位流”；v74/v75 显示位流、外部基准未验证，不得在片中暗示已实测。

## 六、已核对的合规项

- 技术文档、海报正文均无学校/学院/指导教师/团队字样；仅有赛事名中的“全国大学生”。
- 文档中保留“正点原子达芬奇-lite”“HSEDA AD9238”等器件/开发板型号，属技术描述，不是身份信息。
- 海报页脚已删除 Team/School/Advisor 占位，改为赛道、器件与时钟域说明。
- 仓库目录名与文件名均为纯 ASCII（小写字母、数字、下划线），技能包位于 `skill/`；`README.md` 已附“推荐结构 → 实际目录”对照表。

## 七、指南 3.3.5 三件套对应

| 指南要求 | 本仓库对应 | 状态 |
|---|---|---|
| 工程包：源码、仿真/验证结果、综合与实现报告、上板工程与实测对比、可复现构建脚本 | `source_code.zip`（rtl/sim/constr/tools/host/_boardtest/docs/skill/deliverables，`MANIFEST.sha256` 575 行）+ 根 `README.md` 目录对照 + 附录 C | ✅ |
| 技能包：`skill/`，每项写适用范围 / 使用方法 / 失效条件 | `skill/README.md` + 7 项技能（六节模板，含失败来源与失效边界） | ✅ |
| 设计报告：选题背景与创新点、原理与框图、软硬件划分与接口、优化前后对比、大模型协作、技能包提炼、复现说明 | `design_report.pdf`（模板版 23 页 / 0.96 MB）含选题背景、3.3 优化对比、附录 A/B/C；详细版 `design_report_full.pdf` 59 页 | ✅ |
