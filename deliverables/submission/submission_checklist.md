# 提交清单与状态（2026-11-04 v90 口径核对，仓库提交 12c59ab / tag v1.0.0）

> 作品名称统一为 **基于FPGA的细分编码器**。本清单只使用该名称，不含学校、指导教师、团队等信息。
>
> **提交前先读《作品提交总纲》（32 页，本地执行件，不随代码包分发）**：它把赛道规则、13 个报送格子的逐项规范、匿名审计、评分证据矩阵、口径红线、缺口台账与倒排时间线合成一份可逐条打勾的执行文件。本清单只记"状态"，总纲才回答"怎么做、做到什么程度算过"。

## 一、必交项

| # | 项目 | 状态 | 文件 / 说明 |
|---|---|---|---|
| 1 | 演示视频（MP4 / AVC(H264) / ≤3 min / ≤300 MB） | **素材已实拍，待剪辑成片** | 实拍 `../../视频素材/`（16 段 / 10.05 GB / 4K，2026-11-04 凌晨）；脚本 `../video_script_v3.md`（9 镜 3:00、旁白 666 字 177.5 s、字幕 50 条 `../video/subs/narration_v3.srt`）；CG 素材 `../video/assets/` 7 段 2.4 MB；导出后须过 `tools/check_video.py`（H.264 / AAC / ≤180 s / ≤300 MiB） |
| 2 | 技术文档（PDF / ≤50 MB / 按模板） | ✅ 完成（2026-11-04 按 v90 重导并经元数据清洗） | 主用 `design_report.pdf`（25 页 / 1,840,449 B）；备选 `technical_doc.pdf`（17 页 / 1,267,067 B，同骨架精简版）。两份 PDF 均按 v90 重导、全部身份元数据已清空（`dc:creator` / `author` / XMP），复检 `0 carry identity metadata` |
| 3 | 全部代码（RAR / ≤200 MB） | ⚠ 包已就绪，待转 RAR | `source_code.zip`（**63,337,377 B / 60.40 MB / 984 条目**：983 个内容文件 + `MANIFEST.sha256`，另有 57 个目录项；含 `design_report.docx/pdf`、`technical_doc.pdf`、三版海报、`fig_*` 与 `photo_*`、`submission/photos/` 4 张实物照片、全部 RTL（含 `rtl/eth`、`rtl/ddr3`）与 `model/` 黄金模型、`sim/logs` 与 `disp/logs` 逐台日志、`data/**/*.rpt` 全部综合/实现/时序报告、v90 两个交付位流、`skill/`（7 篇长文 + 19 项可执行资产 + 通用 PYNQ 子包 + 夹具）、`data/*/README.md` 与 `SHA256SUMS.txt`；**2026-11-04 流式重打**，`MANIFEST.sha256` 983 行、zip 内逐条校验 983/983，`tools/verify_source_package.py` 8 项自检全 PASS）；本机未安装 WinRAR，已附 `make_rar.bat` |
| 4 | 参赛作品承诺及使用授权书（PDF） | ✅ **已签署并归档（2026-11-03）** | `authorization_letter.pdf`（1 页 / 662,110 B / A4 595×842 pt / 扫描 2416×3612 px·RGB ≈292 dpi）；全体队员签名齐全，落款 2026-11-03；队伍编号与姓名以报名系统为准（实名件只交大赛系统，不进仓库匿名材料）。SHA-256 `6E6038F9D88FA747FBB718570DCC7FED19AAAEA05FCA55AD6E769071EA3D6004` |
| 5 | GitHub 链接 | ✅ 已开源 | [https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder](https://github.com/zhaoyunfengntzx-maker/fpga-smr-encoder)（MIT，`main` 默认分支，tag `v1.0.0`） |
| 6 | 作品全貌图（JPG/PNG ≤10 MB ×1） | ✅ **已拍摄（2026-11-03 20:02）** | `photos/01_overview_full.jpg`（8064×6048 / 6.89 MB）：转台夹具 + 传感头 + 模拟板 + AD9238/FPGA + 7 寸屏 + 示波器 + 上位机同框 |
| 7 | 开发板重要角度照片（JPG/PNG ≤10 MB，≤4 张） | ✅ **已拍摄（2026-11-03 20:02，3 张）** | `photos/02_board_adc_frontend.jpg`（ADC 模拟前端）、`photos/03_board_front.jpg`（FPGA 板正面丝印）、`photos/04_board_screen.jpg`（屏与触摸，P1 总览实时读数）；三类角度齐备且在 4 张上限内，逐张说明见 `photos/README.md` |
| 8 | 作品简介 | ✅ 完成（v90 口径，2026-11-04 重写） | `intro_and_keywords.md`（中性叙事 + 7 个关键词，可直接粘贴） |
| 9 | 是否参加其他赛事 / 往届获奖 / 是否教师科研或实验室作品 | **待确认** | 需你按实际情况勾选，不能代填；建议口径与逐项可复制文本见 `form_answers.md` §4/§5 |
| 10 | 三个创新关键词 | ✅ 完成 | 闭式自校准 / 多协议高速输出适配 / FPGA 正余弦高精度细分 |


> 报名系统每一项的可复制文本（作品名称、简介、关键词、两项声明、附件对照）见 `form_answers.md`。

## 二、选填项

| 项目 | 状态 | 文件 |
|---|---|---|
| 作品海报（PDF/PPT ≤50 MB） | ✅ 完成（三版，均匿名；**v74 期导出，未按 v90 重出**） | 提交用 A4 竖版 `poster_a4.pdf`（0.10 MB）；A4 横版 `poster_amd_a4.pdf`（0.34 MB）；AMD 官方模板版 `poster_amd_official.pdf`（0.31 MB）。生成脚本 `../poster/build_poster.py`、`build_poster_amd.py`、`build_amd_template.py` |

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
- 仓库含 `LICENSE`（MIT）、`README.md`、`skill/`、`docs/ai-collaboration-log.md`、`deliverables/` 文档与 320 个证据文件（155,302,585 B，`SHA256SUMS.txt` 323 条，实测 322/323 通过（唯一不匹配是 `data/README.md` 自哈希，清单生成后又改过））。
- 复现入口：`README.md` §快速开始、`docs/REPRODUCE.md`、`docs/COMPLIANCE.md`。

> 推送提示：作者所在网络对大文件 HTTPS 上行返回 403（约 1–2 MB 以上即失败），最终改用 SSH-over-443 推送：
> `ssh://git@ssh.github.com:443/<账号>/<仓库名>.git`。如你 Fork 后推送遇到 `RPC failed; HTTP 403`，可直接改用该地址。

## 五、视频拍摄建议（3 分钟内）

完整脚本见 `../video_script_v3.md`（现行 v90 稿；`video_script.md` / `_v2` 为历史稿）：§1 三幕结构、§2 旁白逐句时间码、§3 29 个镜头卡片（画面/机位/光/声音/字幕/后期/素材状态）、§4 特效清单、§5 拍摄执行、§6 后期与导出、§7 素材缺口。拍摄顺序与时长按脚本执行即可；以下只留五条骨架：

1. 0:00–0:35 问题：微距灰尘/油膜 + 不完美正弦 + “黑盒”；
2. 0:35–1:20 方案：板卡上电、框图生长、椭圆变圆、41.5 拍动画、五路同源；
3. 1:20–2:42 证明：转台启动、屏读数、示波器 ABZ/UVW、抓包、60 s 长跑、两个死锁与修复；
4. 2:42–3:00 收束：转速慢下来、角度锁定、片名；
5. 屏幕素材来自 v90 显示位流，字幕标版本读回 `0x0019`；延迟只念"设计预算 830 ns"，外部基准未验证，不得在片中暗示已实测。

## 六、已核对的合规项

- 技术文档、海报正文均无学校/学院/指导教师/团队字样；仅有赛事名中的“全国大学生”。
- 授权书 `authorization_letter.pdf` 是大赛要求的**实名文件**（队伍编号 + 队员姓名/签名），只提交给大赛系统，不进入技术文档、海报、仓库等匿名材料，因此与“零身份信息”要求不冲突。
- 文档中保留“正点原子达芬奇-lite”“HSEDA AD9238”等器件/开发板型号，属技术描述，不是身份信息。
- 海报页脚已删除 Team/School/Advisor 占位，改为赛道、器件与时钟域说明。
- 仓库目录名与文件名均为纯 ASCII（小写字母、数字、下划线），技能包位于 `skill/`；`README.md` 已附“推荐结构 → 实际目录”对照表。

## 七、指南 3.3.5 三件套对应

| 指南要求 | 本仓库对应 | 状态 |
|---|---|---|
| 工程包：源码、仿真/验证结果、综合与实现报告、上板工程与实测对比、可复现构建脚本 | `source_code.zip`（rtl（含 eth/ddr3）/model/sim/constr/tools/host/_boardtest/docs/skill/deliverables，`MANIFEST.sha256` 983 行）+ 根 `README.md` 目录对照 + 附录 C；`tools/make_source_package.py` 重打、`tools/verify_source_package.py` 自检 | ✅ |
| 技能包：`skill/`，每项写适用范围 / 使用方法 / 失效条件 | `skill/README.md`（9 节索引）+ 7 篇方法长文（六节模板）+ 19 项可执行资产：6 个校验脚本 / 7 个模板 / 5 篇提示词工作流 / 18 条踩坑清单（索引由脚本生成），全部带夹具与失败来源 | ✅ |
| 设计报告：选题背景与创新点、原理与框图、软硬件划分与接口、优化前后对比、大模型协作、技能包提炼、复现说明 | `design_report.pdf`（模板版 25 页 / 1,840,449 B）含选题背景、3.3 优化对比、附录 A/B/C（附录 B 含可执行资产与自检证据）；详细版 `design_report_full.pdf` 60 页 | ✅ |
