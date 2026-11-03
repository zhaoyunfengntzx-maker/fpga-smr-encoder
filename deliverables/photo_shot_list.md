# photo_shot_list（视频分镜 + 上板取证）

> 用途：① 演示视频拍摄执行表；② 报告插图与"作品照片"的取证清单。
> 与 [`evidence_index.md`](evidence_index.md) §8「待补数据」一一对应：**本文件的 P0 项 = 索引 §8 的阻塞项**。
> 状态图例：🔴 未拍 / 🟡 部分有 / 🟢 已拿到（已归档进 `data/`、`figures/` 或 `video/`）

---

## A. 演示视频分镜表（总长 ≈ 8 分钟；v62 主线 + 一段 v66 转台）

**拍摄前固定事项**（每次开拍前逐条打勾，避免重拍）：
- [ ] `J10`(VCCIO_B16) 与 `J9`(VCCIO_B15) **都拨到 3.3 V**
- [ ] AFG-2225：CH1/CH2 各 **8 Vpp**、相移 **90°**、幅度/偏置档位与报告口径一致（**报告全文统一 8 Vpp**）
- [ ] 板上运行 **v62 交付位流** = `deliverables/data/v62/enc_top_v62.bit`（**1,694,505 B @2026-10-23 10:18:42**、SHA256 `EC0B383B6BC2068D0CDEC2F70B6DD58F2EDFF714B8A345B65912E43B96BE47EB`），**不是** ILA 版、不是 v12 单机版；片头/读数画面里带上版本读回画面：`python tools\uart_spi.py read 0x0000` → **`0x000D`**（`RTL_BUILD_ID`）。
      ★ **2026-10-29 起有两个位流，按镜头分**：屏/网/标定镜头继续用 v62（`0x000D`）；
      **转台镜头（第 6b 段）用 v66 生产位流** `deliverables/data/v66/enc_top_v66.bit`（1,524,668 B、读回 `0x0000` = **`0x000E`**、无屏无网）。
      拍摄当天按 `board_day_checklist.md` §0.0 决定烧哪个，**换位流必须在画面里拍到版本读回**，否则后期分不清素材属于哪一版。
      若拍摄需要"修复前"对照镜头，用 `_synth_work/enc_top_v11prod.bit`（或 v9 版），画面必须标注"旧版对照"，拍完立即下回 v62。
      历史口径（勿再引用为现行）：v12 单机生产版 1,042,208 B / `0x05F2` = `0x000C` / LUT 30.28% / WNS +0.959。
- [ ] 屏幕录制：`tools/uart_scope.py` 波形 + 李萨如图窗口；**本机 7 寸屏五页**用相机拍（屏不能录屏，只能实拍）；分辨率 ≥1920×1080
- [ ] 音频：**不要现场收音**，全部后期配旁白（现场环境噪声无法修复）

| # | 段落 | 时长 | 画面 | 旁白要点（每句带一个数字） |
|---|---|---|---|---|
| 1 | **痛点** | 30 s | 光电编码器污染/失效的示意画面（素材或实拍）；黑底白字打出"进口专用细分芯片：分辨率固定 10 bit / 算法封闭 / 接口形态固定" | 光电编码器光路一旦被粉尘油污污染就细分误差突增；换成进口专用芯片，分辨率被锁死在 10 bit（0.3516°），算法不可见不可改，而且 iC-TW28 的串行口只有 SPI 与 Encoder Link 两种 |
| 2 | **架构** | 60 s | 系统框图动画（报告 §2.1 那张）+ 实物板俯拍 + 手指点 AD9238 模块与 J5/J6 排针 | 一片 Artix-7 替代进口 SoC：50 MSPS 双通道同步采样 → 六参数校正 → 17 级全流水 CORDIC → PI 环路 → ABZ/UVW 输出，单时钟域总延迟约 830 ns（TW28 是 1.5 µs） |
| 3 | ★ **校正前后对比** | **90 s** | 上位机李萨如图：**先放斜椭圆（校正前），按一键标定，转为正圆（校正后）**；同屏叠误差曲线从 20.9839° 掉到 0.0165° | **这是全片最有冲击力的一段**：偏置 + 幅值失衡 + 5° 正交误差叠加，电角度误差 20.9839°；一次标定（一阶/二阶矩闭式解算），降到 0.0165°，**改善 1273 倍**；标定 20 轮 20/20 全部 GOOD |
| 4 | **ABZ + UVW** | 90 s | 示波器四通道：A/B 正交 + Z 脉宽（带游标读 4.883 µs）+ UVW 六步换相 | AB 边沿精确 1.0× 理想、零反向点火；Z 脉宽按手册做成 `(z_width+1)` 个边沿步；ABZ/UVW 与角度更新同源同拍，真实转台上 293 次换向/s、六态均匀 |
| 4b | ★ **本机 5 页屏 + 千兆网** | **90 s** | 7 寸屏实拍：P1 总览 → KEY1 翻页 → P2 输入波形 → P4 逻辑时序 → P6 设置（改一个参数并回读确认）→ P7 标定；切上位机：`host_app.exe` 里点「以太网抓包」→ 28,672 点原始波形 0.06 s 到位 → 再放连续流 10 分钟统计（99.89%） | 这块屏不是为了好看：编码器能自己显示输入波形、ABZ/UVW 时序和故障位，现场不接电脑也能判"是传感器坏还是板子坏"；千兆网把 28,672 点原始波形 **0.06 s** 搬进上位机（串口要 0.65 s），连续流 10 分钟端到端 **99.89%**、30 分钟 **99.74%**，丢包 0.0002% |
| 5 | **性能数据** | 60 s | 报告数据表全屏：精度/延迟/资源/回归；版本读回 `0x0000=0x000D`、标定 20/20、**54 台测试台全绿**三张贴图 | 复合畸变 1273×；CORDIC 最坏 0.9375 LSB；板级跟踪残差 0.009° RMS；稳态滞后 −0.006° @1 kHz；交付位流（含屏与网）占 **82.01% LUT / 46/50 BRAM**，WNS **+0.471**、WHS +0.042、0 失败端点；编码器本身只占 30.28%，其余给屏与网；`sim/` 36 台 + `disp/` 18 台共 **54 台**全绿 |
| 5b | ★ **转台适配（v66 生产位流）** | 60 s | 转台 + 传感器实拍：**先拍到读回 `0x0000 = 0x000E`** → 转起来（100 / 1000 / 3000 rpm）→ 上位机角度连续、ABZ 边沿 **2048/转** → 拔线演示 `0x0130` 变 2（LOST）+ `0x0132/33` 累加 → 前馈量 `0x0124..26` 随转速增大 | 换成 2048 周期/转的真实转台：每腿对地 0.5 Vpp，经差分转单端模块放大到 8 Vpp；机械 1″ 只对应 0.57° 电角（103 LSB），所以瓶颈不在细分位数，而在**延迟、刻度偏心与漂移**；这一版把 ω·T 的滞后用前馈补掉（3000 rpm 约 46″），并用三态锁定把"还没锁 / 毛刺 / 真丢线"分开 |
| 6 | **应用** | 30 s | 伺服/机床/机器人关节场景图 + 硬件框图收尾 + 联系方式 | 面向定制化与多轴同步的位置反馈：可换传感头、可按机械结构做误差补偿、一片 FPGA 多轴同步；下一步做二次谐波补偿，把 0.5% 谐波带来的 0.3571° 残余继续压下去 |

**剪辑硬规则**：
- 每出现一个数字，画面上就要有对应的**实物读数或截图**（不许纯字幕报数）；
- 标定过程**不能快进到只剩结果**——要能看到"斜椭圆 → 正圆"的转换瞬间；
- 结尾 5 s 留板卡与接线全景（评委用来看"确实是硬件做的"）。

---

## B. 待取证素材清单（按优先级，逐条勾）

### P0 —— 阻塞报告定稿（= 索引 §8 前 4 项）

| # | 素材 | 取证方法 | 归档 | 状态 |
|---|---|---|---|---|
| P0-1 | ~~v9 生产版 timing / utilization / DRC 三份报告数字~~ | **已完成**：从 `_synth_work/impl_timing.rpt`(20:42:50) / `impl_util.rpt`(20:42:48) / `impl_drc.rpt`(20:42:52) 抄出 WNS **−3.274** / TNS **−84.283** / 26 失败端点 / 11,304 端点、WHS +0.024、WPWS +9.500；LUT **6360 (30.58%)** / FF **4086 (9.82%)** / DSP 16 / BRAM 0 / IOB 50 / BUFGCTRL 1；DRC 43 checks、**0 error / 0 critical**；最差路径 `ad_ch2_d[6]`；并补 `adc_clk`/`adc_clk2` 各 **+6.965 ns / 0 失败** 的正面证据 ；★ **归档**：`data/timing/impl_timing_v9_2026-10-11.rpt`（同一 v9 相位的相邻轮次，WNS 完全一致 −3.274，TNS/端点总数略异）；本行所引 20:42:50 原件已被 2026-10-12 的 v11 重建覆盖，不可逐字节复原 | 已写入 `design_report.md` §4.2 + `evidence_index.md` §1 | 🟢 |
| P0-2 | ~~v9 ILA 版 timing/util/DRC~~ | **已完成**：`_synth_work/impl_ila_timing.rpt`(21:24:43) / `impl_ila_util.rpt` / `impl_ila_drc.rpt`(21:24:45) → WNS **−3.323** / TNS −84.533 / 26 失败端点 / 20,216 端点；LUT **9228 (44.37%)** / FF 8956 (21.53%) / DSP 17 / BRAM 7.5 (15%) / BUFGCTRL 2；DRC 62 checks **0 error / 0 critical**；并得到"负余量与探针无关"的对照证据 ；★ **归档**：`data/timing/impl_ila_timing_v9_2026-10-11.rpt`（WNS −3.323 一致，TNS/端点总数略异） | 已写入 `design_report.md` §4.2 + 索引 §1 | 🟢 |
| P0-3 | ~~`amp_low` 清零后的真实毛刺率~~ → **改为：v10 相位实验的率对照** | `0x053A` = 0 已确认（`amp_low` 项关闭）；新的定稿阻塞项是 D 分支成因判别：同幅度下 v9/v10 两个相位的 300 s 计数窗（`0x0505/07/09/0B`），率剧变 ⇒ 接口、不变 ⇒ ADC 内部。★ 口径：只用「Δ毛刺 / 实测秒数」，跨 3.28 s 的 `cyc_pulse_cnt` 有回绕 | 索引 §7 + `docs/DEV_STATUS.md` §1.57⑥⑧ | 🟢 **已判别并修复（2026-10-12）**：同热点 A1(v9) **907 个/30 s** → B(v10) **0** → A2(v9) **681 个/30 s**；换 v11 后同热点 **120 s 内 0 个**；v11→v9→v11 反向夹逼 = **0 → 3,320 个（55.3 次/s）→ 0**（幅度单调上升 ⇒ 排除漂移）⇒ 根因 = ADC 捕获相位余量；**v11 已采纳**（`0x05F2` = 0x000B，时序 WNS **+0.821** / 0 失败端点；**现行已升 v12**：生产位流 1,042,208 B @2026-10-12 23:59:27、`0x05F2` 应读回 `0x000C`、WNS **+0.959** / 0 失败端点 / 11,275 端点，见 `design_report.md` §4.2 与 P2-7；v11 已归档为 `_synth_work/enc_top_v11prod.bit`） |
| P0-4 | **Z 脉宽示波器带游标截图** | 探 `J5-7`（Z），1 kHz / `z_width=4` ⇒ 游标读 **4.883 µs**；再拍一张 `z_width=0` ⇒ 0.977 µs | `figures/` + 报告 §3.5 | 🔴 |

| P0-5 | **v66 转台镜头（上板通过后才能拍）** | 烧 `data/v66/enc_top_v66.bit`（无屏无网）→ 先拍版本读回 `0x0000` = **0x000E** → 按 `board_day_checklist.md` §9 拍：诊断（`0x0130`=TRACK）/ 标定 / 100-1000-3000 rpm / 拔线 LOST / 前馈量 `0x0124..26`；**没有过闸门就不拍**，报告里已如实标"未上板" | `figures/v66_*.png` + `video/` 第 5b 段 | 🔴 **待拍：v74 生产位流已上板验收（§7 R14 只剩显示位流）** |

### P1 —— 报告核心数据（评委最想看的三张图）

| # | 素材 | 取证方法 | 归档 | 状态 |
|---|---|---|---|---|
| P1-1 | **李萨如图（校正前斜椭圆 / 校正后正圆）** | ★ **已用一条命令自动拿到（2026-10-13）**：`python tools\lissajous_capture.py --port COM3`（校前抓 → 写 `0x0502=0x0001` 一键标定 → 校后抓 → 汇总 `data/lissajous_summary.csv`）；**并已把"斜椭圆"做成可复现**：`python tools\calib_snapshot.py --port COM3 snapshot --save _synth_work\calib_before.json` 存系数 → `inject --offset 3000 --offset-c -3000 --gain-mismatch 1.25 --quad-deg 3` 注入偏置/增益失配/正交误差 → `lissajous_capture.py` 拿"校前" → `restore --load …` 复原（健康系数 `ofs_s 41 / ofs_c 357 / gain_s 33014 / gain_c 33309 / phase_k 97 / shift 0` 已逐值复原、失败 0 条） | `figures/lissajous_before.png`（108,225 B，SHA256 `7B1288352A7008CD…`）/ `_after.png`（114,342 B，`BB1C5A63980861D2…`）—— ★ **这一组是恢复健康系数后抓的（两组都 0.101 %），只作健康基线**；用于 §6.4 与视频第 3 段请用下面 P1-1b 那组 | 🟢 **已拍通（图 + CSV 已归档）** |
| P1-1b | ★ **注入失真 → 一键标定 → 回正圆（比 P1-1 更适合录视频的"翻盘"镜头）** | 同上的 `--inject` 路径。**实测数字（COM3、v12、1 kHz / 8 Vpp，干净复测、三次一致）**：注入后圆度偏差 RMS **17.786 %**（半径峰峰 17,594.5–33,496.6、`oflow=4978, scamp=4975`）→ 一键标定后 **0.101 %**（`OK(no-alarm)`）＝ **改善 ≈176×**；校正后半径 mean **26,213.8**；收敛系数 `ofs_s 42 / ofs_c 359 / gain_s 33013 / gain_c 33310 / phase_k 97 / shift 0`（与注入前原值逐项同量级）；另一次独立复测 **17.795 % → 0.102 %**。★ **17.829 % 那个旧数已作废**（被 `0x051A` 哨兵写把 shift 顶成 3、增益 ×8 污染，见 P1-1c 行的工具 bug 说明） | `figures/lissajous_before_distortion.png`（106,991 B，`32F9398F31EF1C71…`）/ `_after_distortion.png`（114,257 B，`DEF7ECDB6F6DA190…`）+ 两份 CSV（`3398F4F1F74B0459…` / `F663B80EB5AA9FCE…`） | 🟢 **已拍通** |
| P1-1c | ★ **一键标定重复性（"标定能不能重来"的硬证据）** | `python tools\calib_repeat.py --port COM3 --n 12 --csv deliverables\data\calib_repeat_summary.csv`（逐轮读 `OFS_S/OFS_C/GAIN/PHASE_K/SHIFT/retry/trunc/win_bad`，判据 `OFS_S` 每轮都应收敛在实测圆心附近；★ 该工具**默认端口是 COM5**，必须显式传 `--port`）。实测 **12/12 全 GOOD**：`ofs_s` 40–42（极差 2、σ 0.6）、`ofs_c` 357–364、`gain_s` 33,011–33,016、`gain_c` 33,307–33,312、`phase_k` 97–98、`shift` 0、`retry` **0 次**、`win_bad` **0 次**。★ 未解释项如实记录：CSV 的 `trunc`（`0x0502` bit3）**12/12 轮都是 1**、`stat`（`0x053A` 高字节）第 9/12 轮为 1 —— 该语义下工具 verdict 仍为 GOOD，`trunc` 是粘滞位、本次未单独定案 | `data/calib_repeat_summary.csv`（606 B，`166048418AFDD049…`） | 🟢 **已跑（2026-10-13）** |
| P1-2 | **误差曲线**（校正前后叠在同一张图） | 由黄金模型导出 + 板上 `angle` 残差叠加 | `figures/error_curve.png` | 🟡（模型侧已有数字） |
| P1-3 | **动态频率-误差-延迟表** | 输入 1k / 10k / 50k / 100k / 200k / 500 kHz，逐点记 `angle` 残差与稳态滞后 | 填进 §6.3 | 🟡 **六点遥测已齐**（2026-10-13：`deliverables/data/freq_{1k,10k,50k,100k,200k,500k}.csv` + `freq_{...}.png` + `freq_robust_summary.csv`，见 `evidence_index.md` §3A）；**仅缺"延迟"列**——`lag_deg` 需 ILA 位流（沙箱内下不了），要单独找窗口下 `_synth_work/enc_top_ila.bit` 再跑 `freq_ladder.py --ila` |
| P1-4 | **延迟实测** | 示波器同屏：信号源正弦过零点 vs A 输出跳变沿 | `figures/latency_measure.png` + §6.3/§4.3 对比预算 830 ns | 🔴 |

### P2 —— 作品照片与加分素材

| # | 素材 | 取证方法 | 归档 | 状态 |
|---|---|---|---|---|
| P2-1 | **板卡整体照片**（含丝印、接线标号） | 顶视 + 45° 各一张，光线均匀 | `figures/board_top.jpg`、`board_45.jpg` | 🔴 |
| P2-2 | **接线详图**（AD9238 模块 ↔ J6、ABZ/UVW ↔ J5、串口） | 排针插位拍特写，图上标 J6-26/J6-9 等 | `figures/wiring.jpg` | 🔴 |
| P2-3 | **ILA 抓真毛刺的波形截图** | **已完成**：`tools/glitch_figure.py` 从抓包 CSV 出三面板图 —— ① s_raw 单拍尖峰（c 干净）② `s_dec` 抽值把坏拍展宽/稀释（(−1537×3+768)/4 = −960 ✓ 正好 4 点平均）③ `ang_glitch` 在坏拍后 **26 拍**才置 1（流水线延迟，2026-10-12 逐拍对齐复核；旧文写 27 拍是全局拟合值）；另出 **v9/v11 同热点逐拍对照图** `figures/ila_glitch_v9_vs_v11.png`（报告图 6-3） | `figures/ila_glitch.png`、`figures/ila_glitch_g82.png`（两簇各一张）、`figures/ila_glitch_v9_vs_v11.png` | 🟢 |
| P2-4 | **`DEVICE_ID = 0x0C` 读回截图** | `python tools/uart_spi.py read 0x05F0` → `5A 01 F0 10 0C B7` | `figures/device_id.png` | 🔴 |
| P2-5 | **综合/实现报告整页截图**（Sign-off 证据） | Vivado 里 `impl_timing.rpt` 的 Summary 段 | `figures/timing_summary.png` | 🔴 |
| P2-6 | **★ 真实传感头 / 磁环实测片段** | **必须做**：接一段真实 SMR/TMR 传感头或磁环（哪怕只用手转），拍 ABZ 输出随转动变化 | `video/real_sensor.mp4` + `figures/` 静帧 | 🔴 |
| P2-7 | **★ 串口直接看 ABZ/UVW 六路电平（v12 新能力，不用示波器/ILA）** | **★ 已在板跑通（2026-10-13 12:29 烧入 v12，读回 `0x05F2` = `0x000C`、遥测偏移 9 = `0xA2`）**：**一条命令**（推荐，自带版本门禁/寄存器自配/每秒滚动统计/逐项判定/归档）`python tools\demo_abz_uvw.py --port COM3 --seconds 30 --archive`（输出 `DEMO PASS`，9/9 项 ✅），等价的手工命令 `python tools\uart_scope.py --port COM3 --baud 2000000 --seconds 30 --csv io.csv --png figures/telemetry_abz_uvw.png`（端口号随插拔变，用 `tools\uart_spi.py ports` 查；重出位流用 `tools/rerun_impl.ps1`）—— PNG **第 3 行是按电角度的等效采样图**：实测 A/B 正交、UVW 六步 60° 台阶、Z 每电周期一次；报告段给出占空比/跳变数与告警位。**已实测数字（inter = 32、30 s、298,749 帧、DEMO PASS）**：A 50.0% / B 49.9% / Z 0.1%，UVW 六种合法状态均衡（`001:50853 010:49248 011:49188 100:49168 101:51021 110:49271`），**等效采样 64/64 箱**；`inter` = 256（上电默认）时 A/B 占空仍 50% 但 `lag_warn/lag_fatal` 常置 1（撞 12.5 MHz 边沿率上限，属已知现象，拍前先写 `0x0101` = `0x0020`） | `figures/telemetry_abz_uvw.png`（**30 s 抓帧图，120,686 B，SHA256 `CF8D3B1985B06703…`**）+ `data/telemetry_abz_uvw.csv`（**30 s 原始帧，25,237,925 B，SHA256 `1EEC84B077AE8EAA…`**），**答辩演示"上位机实时看波形"就靠这条**（见 `../docs/DEV_STATUS.md` §1.58/§1.59、`../docs/07` 2.7b、`tools/demo_abz_uvw.py`） | 🟢 **已拍通（图 + 30 s CSV 已归档）** |
| P2-8 | ★ **本机 5 页屏实拍（v62 交付位流）** | 屏上逐页拍：P1 总览 / P2 输入波形 / P4 逻辑时序 / P6 设置 / P7 标定，每页一张同框照（含手与触摸动作）；清单见 `../docs/15_display_touch_bringup.md` §0.1（KEY1=Y9 翻页、KEY0=W9 全局复位、J9/J10 都要 3.3 V、必须裸指） | `figures/screen_p{1,2,4,6,7}.jpg`、`figures/screen_touch.jpg` | 🔴 **10-29 拍** |
| P2-9 | ★ **千兆网端到端演示**（上位机抓包 + 连续流） | `host/dist_onedir/host_app/host_app.exe` → 以太网 → 抓包 28,672 点（0.06 s）→ 连续流 10 min 看统计（99.89%）；录屏 + 拍网口指示灯 | `video/clip_eth.mp4`、`figures/host_capture_ethernet.png` | 🔴 **10-29 拍** |

> ★ **P2-6 是答辩"送命题"的唯一解**（`../docs/02` §5.3）。
> 如果整支视频全是信号发生器，评委一定会问"**为什么用信号发生器而不是真实传感器**"。
> 报告 §5.2 已给出诚实答案（只有信号源才能注入**已知**的偏置/失衡/相位误差，这是定量标定的必要条件），
> **但必须配一段真实传感头的画面**，否则这段解释会被当成借口。

### P3 —— 收尾与风险项

| # | 素材 / 动作 | 说明 | 状态 |
|---|---|---|---|
| P3-1 | **示波器探 D11/D10 + s 通道输入** | D 分支坏样本"ADC 内部误码 vs 板级 SI"的**直接**判别手段（与 v10 相位实验互补）：触发条件已知 —— 事件只发生在 s 通道跨 `0x9FF→0xA00`（或 `0xBFF→0xC00`）且 c 通道同时跨 256 边界的那一拍 | 🔴 |
| P3-2 | ~~幅度阶梯率曲线~~ → **原始码口径的「时间–率」曲线** | 原计划依赖的"幅度轴"已作废（遥测半径是弧段量，见 §1.57①）：改为用 ILA 原始码测 A、并记录**同幅度的长时率曲线**（今天实测 11:37–11:41 ≈0.33–0.50 次/s → 12:05–12:10 ≈0–0.27 次/s，跨会话可差 ≈270×） | 🔴 |
| P3-3 | **相位实验（v10 → 已采纳为 v11）** | 两路 ODDR 反相 → 同相（`D1=1/D2=0`）；`RTL_BUILD_ID` **0x000A（v10）→ 0x000B（v11 = 同相 + 配套 XDC：去掉两处 `-invert`、`set_input_delay` 14.000/9.500）**；捕获裕量 4–8 ns → **14–18 ns**（实测 `tPD` = 3–4 ns ⇒ 建立余量 ≈ **+12.3 ns**） | 🟢 **已完成并采纳**：同热点 A1(v9) **907** 个/30 s → B(v10) **0** → A2(v9) **681** 个/30 s；v11 上板 **120 s 内 0**；v11→v9→v11 = **0 → 3,320 → 0**；时序首次收敛 **WNS +0.821 / 0 失败端点** |
| P3-4 | **源端串阻** | 硬件侧，22–33 Ω，排线 **≤5 cm**；XDC 只能约束+降驱动 | 🔴 |

---

## C. 开拍前的一致性检查（防止素材与报告数字打架）

- [ ] 报告全文的 AFG 幅度口径统一为 **8 Vpp**（若某次拍摄用了别的幅度，画面里必须写明，否则该素材作废）
- [ ] 视频里出现的每个数字都能在 [`evidence_index.md`](evidence_index.md) 找到同一行
- [ ] **视频与报告不得出现 `docs/02` 那套 v6 快照数字**（6010 / 8822 LUT、WNS −3.352、1,445,812 B、34 探针）
- [ ] 板上位流版本（`0x05F2`）在画面里可读，且与报告 §4.2 声明的版本一致
- [ ] 场景切换处不留"未完成"痕迹（终端报错、TODO、IDE 里未保存的标签）

---

## D. 「一次拍完」执行顺序（**2026-10-29 拍摄日**，v62 版）

> **目标**：一次坐下（≈3 h）把 §A 视频分镜、§B 的 P0/P1/P2 取证项、以及两份测量（B/D 示波器 + 频率表 + 环路延迟）**一次拍完**。
> **排序原则**：先拍零依赖的静态素材 → 再一次接齐示波器探头（Phase 1）→ 做会改板上系数的标定 → 做要反复改 AFG 的频率阶梯 → 做要拆线的真实传感头 → 最后才换位流拍"修复前"对照。
> 每步拍完立刻按"归档名"存盘，不要等收工再整理。

### D.0 固定设置（一次调好，全程不改）
- [ ] `J10`/`J9` → **3.3 V**（照片里要能看出拨码位置）
- [ ] AFG CH1/CH2 = **8 Vpp 正弦、相移 90°、1 kHz**（只有 Phase 2 改频率、Phase 3 拆线）
- [ ] 板载位流 = **v62 交付版**（`deliverables/data/v62/enc_top_v62.bit`；读回 `0x0000` = **0x000D**）—— 不是 ILA 版、不是 v12 单机版
- [ ] 串口 **COM6**；上位机用 `E:\Anaconda\python.exe`；`tools/uart_scope.py` 窗口 **1920×1080**（波形 + 李萨如）
- [ ] 相机：三脚架俯拍 + 补光；**关闭现场录音**（旁白一律后期）
- [ ] 每拍一个"数值镜头"，记下 AFG 档位 / `0x05F2` / 日期时间（后期核对用）

### D.1 Phase 0 —— 静态照片与屏幕截图（≈20 min，不碰 AFG）
| 步 | 拍什么 | 命令 / 操作 | 归档名 | 清单项 |
|---|---|---|---|---|
| 0-1 | 板卡顶视 + 45° | 三脚架俯拍、补光；画面含丝印与 J10/J9 拨码 | `figures/board_top.jpg`、`board_45.jpg` | P2-1 |
| 0-2 | 接线详图 | AD9238↔J6、A/B/Z↔J5、串口特写（后期标 `J6-26`/`J6-9` 等） | `figures/wiring.jpg` | P2-2 |
| 0-3 | `DEVICE_ID` 读回 | `E:\Anaconda\python.exe tools\uart_spi.py read 0x05F0` → `5A 01 F0 10 0C B7` | `figures/device_id.png` | P2-4 |
| 0-4 | 时序签核页 | 打开 **v62** 的 `deliverables/data/v62/impl_timing.rpt`（@2026-10-23 10:18），截 Summary 段（`All user specified timing constraints are met.` / WNS **+0.471** / 0 失败端点 / **33,255** 端点 / WHS +0.042）★ **不要用 v9/v12 那两份** | `figures/timing_summary.png` | P2-5 |
| 0-5 | 板载版本画面 | `tools\uart_spi.py read 0x0000` → **0x000D**（v62；读到 0x000C 说明板上还是 v12 单机版，需重下） | `figures/build_id.png` | §C 检查项 |
| 0-6 | **屏五页实拍 + 触摸** | 按 `docs/15_display_touch_bringup.md` §0.1 逐页：P1→KEY1→P2→P4→P6→P7；每页拍一张含屏与手（裸指）的同框照；P6 改一个参数并回读确认 | `figures/screen_p1.jpg` … `screen_p7.jpg`、`screen_touch.jpg` | P2-8 |
| 0-7 | **以太网演示录屏** | `host\dist_onedir\host_app\host_app.exe` → 以太网模式 → 抓包（28,672 点 / 0.06 s）→ 开连续流 10 min 看统计；同时拍板卡网口指示灯 | `video/clip_eth.mp4` + `figures/host_capture_ethernet.png`（已有，可重拍） | P2-9 |

### D.2 Phase 1 —— 示波器一次接齐（≈45 min，AFG 保持 1 kHz / 8 Vpp / 90°）
| 步 | 拍什么 | 接法与读法 | 归档名 |
|---|---|---|---|
| 1-1 | `ad_clk` 与 `ad_clk2` 同相 | CH1=`J6-26`、CH2=`J6-9`，10 ns/div（v11 已去掉两处 `-invert`） | `figures/scope_adclk_phase.png` |
| 1-2 | `tPD` 带游标 | CH1=`J6-26`、CH2=`J6-38`（`CH1_D11`，**不要用 `D0`**），5 ns/div，两游标读 **3–4 ns** | `figures/scope_tpd_v11.png` |
| 1-3 | Z 脉宽 + 整周期 | CH1=`J5-7`：先 10 ms/div 拍 **64 ms** 周期，再 1 µs/div 两游标拍 **4.883 µs** | `figures/scope_z_period.png`、`scope_z_width.png`（P0-4 ✅） |
| 1-4 | ABZ + UVW 六步 | A/B=`J5-5`/`J5-6`、Z=`J5-7`、UVW=`J5-8/9/10` | `video/clip_abz_uvw.mp4` + `figures/scope_abz_uvw.png` |
| 1-5 | 环路延迟（补 R6） | CH1 = AFG 正弦（分一路）、CH2=`J5-5`（`a_out`）：同屏读"过零点 → A 沿"，预算 ≈830 ns | `figures/latency_measure.png`（P1-4 ✅ → §6.3） |
| 1-6 | 李萨如（校前 / 校后） | ★ **一条命令**：`& E:\Anaconda\python.exe tools\lissajous_capture.py --port COM3`（校前抓图 → 写 `0x0502=0x0001` 触发一键标定 → 校后抓图 → 汇总 `data/lissajous_summary.csv`）；手做也行：`uart_scope.py --png figures/lissajous_before.png` → 按板上 `KEY0`/`W9` → `--png figures/lissajous_after.png`；**全程屏幕录制**（视频第 3 段，不许快进） | `figures/lissajous_before.png`/`_after.png` + `video/clip_calib.mp4`（P1-1 ✅ **图与 CSV 已归档 2026-10-13**） |
| 1-7 | ★★ **"注入失真 → 一键标定 → 回正圆"**（**建议视频第 3 段改拍这个**） | 三步全由串口完成，不用动 AFG 档位：① `python tools\calib_snapshot.py --port COM3 snapshot --save _synth_work\calib_before.json`（存原系数）② `python tools\calib_snapshot.py --port COM3 inject --offset 3000 --offset-c -3000 --gain-mismatch 1.25 --quad-deg 3` ③ `python tools\lissajous_capture.py --port COM3` ④ **必做**：`python tools\calib_snapshot.py --port COM3 restore --load _synth_work\calib_before.json`。**实测（2026-10-13 干净复测）圆度 RMS 17.786 % → 0.101 %，改善 ≈176×**（另一次独立复测 17.795 % → 0.102 %） | `figures/lissajous_before_distortion.png` / `_after_distortion.png`（P1-1b ✅ **图与 CSV 已归档 2026-10-13，SHA256 见 `evidence_index.md`**） |
| 1-8 | ★ **一键标定重复性**（视频第 5 段数字镜头） | `python tools\calib_repeat.py --port COM3 --n 12 --csv deliverables\data\calib_repeat_summary.csv`（★ **工具默认端口是 COM5，必须显式传 `--port`**）；实测 **12/12 GOOD**，`ofs_s` 40–42（极差 2、关 σ 0.6）、`retry` 0 次、`win_bad` 0 次 | `data/calib_repeat_summary.csv`（P1-1c ✅ 已归档） |

> ⚠ **1-6 的归档说明**：`lissajous_before.png` / `lissajous_after.png` 这一组是**恢复健康系数之后**抓的（两组都 0.101 %，只作健康基线用）；`*_distortion` 那组才是**板上带着注入失真**抓的（`before` = 未标定、`after` = 一键标定后）。**视频第 3 段用 `_distortion` 那组**。
> ⚠ **1-7 的坑（已修在工具里）**：`0x051A`（shift）**只有 4 位**，写 `0x00FF` 实际写进 `0x0F`；`uart_spi.do_write` 的哨兵路会在"目标值 == 当前值"时先写 `0x00FF` ⇒ 一次"把 shift 归零"的写会把 shift 顶成 3（增益 ×8），采到**被污染的假读数**（`17.829 %`，已作废）。`tools/calib_snapshot.py` 现已裁剪 4 位、跳过"值相同"的写、并对增益倍数硬拒绝 `>1.999`。**每轮注入实验后务必 `restore`**，否则板上带着注入系数。


> ⚠ **李萨如频率坑**：实时窗口要装下一整圈需要 `f_in ≥ 约 48.8 kHz`（`docs/07_board_checklist.md:122`）。1 kHz 下请用 `--png` 的**累积散点**判读，或临时把 AFG 升到 50 kHz 拍实时窗口（拍完改回 1 kHz）。
> ⚠ **标定必须在 Phase 2 之前**做 —— 标定会改板上系数。

### D.3 Phase 2 —— 频率阶梯表（≈45 min，只改 AFG 频率）
- 逐点：**1k → 10k → 50k → 100k → 200k → 500 kHz**，每点三步：
  1. 记 AFG 显示（频率/幅度）与时间；
  2. `uart_scope.py --port COM3 --seconds 5 --png figures/freq_<f>.png --csv data/freq_<f>.csv` ⇒ 记校正后半径 / 圆度 RMS / 状态位；★ **50 kHz 以上要先注意过速钳位**：实用约束 `inter*f_in/div ≤ 6.25 MHz`（`docs/08`），`0x0101` 的 `inter=256` 时 `f_in ≤ 24.4 kHz` ⇒ 拍 50k 及以上各点前先把 `0x0101` 改小（否则预期 `lag_warn`/`lag_fatal`，画面里要说明是刻意设置）。
  3. 抓一窗 ILA（`ILA_MODE=stage1`）⇒ `E:\Anaconda\python.exe tools\ila_report.py _synth_work\ila_freq_<f>.csv` 读 **`★ 其中的恒定滞后 … deg`**（`tools/ila_report.py:214`）。
- ⇒ 填报告 §6.3 表（P1-3 ✅）。
- ★ **第 2/3 步已自动化**（`tools/freq_ladder.py`，2026-10-12 新增；解析正则已用离屏样本 `_synth_work/selftest_out.txt` 与 `ila_report_sample.txt` 自测通过）：

  ```powershell
  # 需放宽文件权限运行（第 3 步要下 ILA 位流）
  & E:\Anaconda\python.exe tools\freq_ladder.py --port COM3 --with-diag --ila `
      --freqs 1k,10k,50k,100k,200k,500k --out deliverables\data --figures deliverables\figures
  ```

  每点提示改频率并回车，然后自动：① `uart_scope.py --seconds 5 --png figures\freq_<f>.png --csv data\freq_<f>.csv` 并解析**半径 / 圆度 RMS / 状态位**；② `diag_counters.py` 尾部原文写进 note；③ 抓一窗 ILA（`ILA_MODE=stage1`）→ `ila_report.py` 提取 **`★ 恒定滞后 … deg`**；④ 逐点追加 `data\freq_ladder_summary.csv` 并打印汇总表。
  离屏自检（不接硬件）：`& E:\Anaconda\python.exe tools\freq_ladder.py --parse-only _synth_work\selftest_out.txt`。
  脚本**不读 AFG**，每点仍要**手记 AFG 显示（频率/幅度）与时刻**。

### D.4 Phase 3 —— 真实传感头（≈20 min，"送命题"，要拆线）
- 接 SMR/TMR 传感头或磁环，**手转**（缓慢、尽量单向），连续拍 ≥20 s 的 ABZ 输出随转动变化。
- 归档 `video/real_sensor.mp4` + `figures/real_sensor_01.jpg`…（P2-6 ✅，`docs/02` §5.3 的唯一解）
- 拍完把 AFG 接回去。

### D.5 Phase 5 —— 可选：v9"修复前"对照镜头（≈15 min，最后做）
- 下 `_synth_work/enc_top_v9.bit`（读回 `0x05F2` = 9），拍热点毛刺 + 时序不收敛页；**画面必须标注"旧版 v9 对照"**；拍完 **立即下回 v12**（读回 0x000C）。
- 归档 `video/clip_v9_compare.mp4`、`figures/scope_glitch_v9.mp4`。
- 若不想承担"画面里出现旧版"的解释成本，可**跳过本步**（报告已有 ILA 对照图 6-3 承担这个论证）。

### D.7 收工前一致性检查（= §C）
- [ ] LUT/FF 用 **6,298 = 30.28% / 4,074 = 9.79%（v12）**，不得再用 30.36%/9.79%（v7 口径）；历史 v11 为 **6,369 = 30.62% / 4,088 = 9.83%**
- [ ] 旁白里的"≈830 ns"要念成**预算**（实测值由 1-5 步给出）
- [ ] `0x05F2` 镜头 = **0x000C**；`0x05F0` = `0C`
- [ ] 不得出现 v6 快照数字（6010/8822 LUT、WNS −3.352、1,445,812 B、34 探针）
- [ ] 视频里每个数字都能在 [`evidence_index.md`](evidence_index.md) 找到同一行
- [ ] 未拍项直接在本清单标 🔴 → 交片前再扫一遍 §B 的 P0 行
