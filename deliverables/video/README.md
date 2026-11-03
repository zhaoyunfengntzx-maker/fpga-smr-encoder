# 演示视频工作区

> 拍摄执行表（2026-11-03 夜 → 11-04 上午，v85 位流口径）：[`../shoot_plan_2026-11-03.md`](../shoot_plan_2026-11-03.md)（含时间盒、机位、R7 真传感头三档脚本、降级预案）。

3 分钟正片的所有“非实拍”素材与工具都在这里。实拍清单见 [`../video_script.md`](../video_script.md) §3 的素材标记与 §9 检查表。

## 1. 已生成素材

| 文件 | 时长 | 用途 | 插入位置（脚本镜号） |
|---|---|---|---|
| `assets/pipeline_41_5.mp4` | 8 s | 41.5 拍 / 830 ns 周期标尺动画，含 ADC 7 拍估计与 6 级流水 | 镜头 12（1:02–1:08） |
| `assets/sys_grow.mp4` | 6 s | 系统框图从左到右“生长”揭示 | 镜头 10（0:47–0:55） |
| `assets/end_card.mp4` | 5 s | 片尾卡：作品名 + 一句话 | 镜头 28–29（2:52–3:00） |
| `assets/card_title.png` | — | 标题静帧（可作封面/开场 0.5 s） | 片头或封面 |
| `assets/card_end.png` | — | 片尾静帧 | 备用 |
| `subs/video_script.srt` | 3:00 | 22 条中文字幕，逐句对齐旁白时间码 | 字幕轨 |

均为 1920×1080 / 25 fps / H.264 / yuv420p，无音轨（作为上层素材，保留现场声与配乐）。

## 2. 重新生成

```bat
E:\Anaconda\python.exe tools\make_video_assets.py all
E:\Anaconda\python.exe tools\make_srt.py
```

依赖：Pillow、`imageio-ffmpeg`（自带 ffmpeg 二进制）。字体用系统 `msyh.ttc` / `times.ttf` / `consola.ttf`。

## 3. 剪辑轨建议（剪映 / DaVinci Resolve 通用）

- **V1 实拍**：转台、板卡、屏、示波器、手部特写。
- **V2 图形**：`sys_grow.mp4`、`pipeline_41_5.mp4`、`end_card.mp4`，混合模式用“正常”，无需抠像。
- **V3 字幕**：导入 `subs/video_script.srt`；字号 ≥ 54 px（1080p），白字 + 60% 黑底，底部安全区 120 px。
- **A1 旁白**：按 SRT 时间码贴；旁白前后各留 0.3 s 气口。
- **A2 现场声**：电机、示波器、键盘、继电器；整体 −18 LUFS 左右，旁白 −16 LUFS。
- **A3 音乐**：只做底，−26 LUFS 以下；死锁段可留 2 s 无音乐。

## 4. 导出与自检

导出：MP4 / H.264 / 1920×1080 / 25 fps / AAC 48 kHz / 总时长 ≤ 3:00 / ≤ 300 MB。

```bat
E:\Anaconda\python.exe tools\check_video.py path\to\demo.mp4
```

检查项：容器、H.264、AAC、时长、体积、分辨率、帧率。全部 OK 才上传。

## 5. 三条硬约束（不要在片子里违反）

1. 屏幕素材若来自 v62 演示位流，字幕必须标“v62 演示位流”。
2. v74/v75 显示位流未目视验收、外部 ±0.5″ 基准未测：不暗示已实测。
3. 全片不出现学校、学院、指导教师、团队姓名；片尾只留作品名与技术信息。
