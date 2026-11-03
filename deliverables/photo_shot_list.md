# photo_shot_list（视频分镜 + 上板取证）

> 用途：① 演示视频拍摄执行表；② 报告插图与"作品照片"的取证清单。
> 与 [`evidence_index.md`](evidence_index.md) §8「待补数据」一一对应：**本文件的 P0 项 = 索引 §8 的阻塞项**。
> 状态图例：🔴 未拍 / 🟡 部分有 / 🟢 已拿到（已归档进 `data/`、`figures/` 或 `video/`）

> **★ 口径（2026-11-04）：全部镜头以 v90 交付基线为准。**
> 生产位流 `deliverables/data/v90/enc_top_v90.bit`（**1,504,220 B**、SHA256 `A89512A5…827125`、读回 `RTL_BUILD_ID = 0x0019`、`DEVICE_ID = 0x000C`）；
> 显示位流 `deliverables/data/v90/enc_top_disp_v90.bit`（**1,688,245 B**、读回同为 `0x0019`），**已写 Flash、冷启动通过**。
> 拍摄用显示位流（要拍屏就必须烧它）；只拍串口/示波器镜头可用生产位流。
> 判据单页：[`../docs/39_acceptance_criteria_v90.md`](../docs/39_acceptance_criteria_v90.md)；拍摄时序以 [`shoot_plan_2026-11-03.md`](shoot_plan_2026-11-03.md) 为准。
> **每次换位流，画面里必须拍到版本读回**，否则后期分不清素材属于哪一版。

---

## A. 演示视频分镜表（总长 ≈ 8 分钟；v90 一条主线）

**拍摄前固定事项**（每次开拍前逐条打勾，避免重拍）：
- [ ] `J10`(VCCIO_B16) 与 `J9`(VCCIO_B15) **都拨到 3.3 V**
- [ ] AFG-2225：CH1/CH2 各 **8 Vpp**、相移 **90°**、1 kHz 起（只有频率阶梯段改频率），幅度/偏置档位与报告口径一致（**全文统一 8 Vpp**）
- [ ] 板上运行 **v90 位流**：拍屏/网/标定用 `enc_top_disp_v90.bit`，纯串口镜头用 `enc_top_v90.bit`；
      片头/读数画面里带上版本读回：`python tools\uart_spi.py read 0x05F2` → **`0x0019`**
- [ ] 屏幕录制：`tools/uart_scope.py` 波形 + 李萨如图窗口；**本机 7 寸屏四页**用相机拍（屏不能录屏，只能实拍）；分辨率 ≥1920×1080
- [ ] 音频：**不要现场收音**，全部后期配旁白（现场环境噪声无法修复）

| # | 段落 | 时长 | 画面 | 旁白要点（每句带一个数字） |
|---|---|---|---|---|
| 1 | **痛点** | 30 s | 光电编码器污染/失效的示意画面（素材或实拍）；黑底白字打出"专用细分芯片：分辨率固定 10 bit / 算法封闭 / 接口形态固定" | 光电编码器光路一旦被粉尘油污污染，细分误差立刻突增；而专用细分芯片把分辨率锁在 10 bit（0.3516°）、算法不可见不可改，串行口只有 SPI 一种 |
| 2 | **架构** | 60 s | 系统框图动画（报告 §2.1 那张）+ 实物板俯拍 + 手指点 AD9238 模块与 J5/J6 排针 | 一片 Artix-7 35T 独立完成整条链：50 MSPS 双通道同步采样 → 六参数闭式校正 → 17 级全流水 CORDIC → PI 跟踪 → ABZ/UVW 输出，**单时钟域 41.5 拍 ≈ 830 ns（设计值）** |
| 3 | ★ **校正前后对比** | **90 s** | 上位机李萨如图：**先放斜椭圆（校正前），写 `0x0502=0x0001` 一键标定，转为正圆（校正后）**；同屏叠误差曲线从 20.9839° 掉到 0.0165° | **全片最有冲击力的一段**：偏置 + 幅值失衡 + 3° 正交误差叠加，电角度误差 20.9839°；一次闭式标定降到 0.0165°，**改善 1273 倍**（仿真、黄金模型）；板上圆度 RMS 17.786% → 0.101%，**改善 ≈176 倍** |
| 4 | **ABZ + UVW** | 90 s | 示波器四通道：A/B 正交 + Z 脉宽（游标读 4.883 µs）+ UVW 六步换相；再切串口 `uvw_phase.py` 的六态计数 | AB 边沿精确 1.0× 理想、零反向点火；Z 由 **45° 布防窗的索引发生器**给出，**每转严格 1 个**；真实转台 457–459 rpm 下 UVW 六态计数 `{5174,4761,4423,4776,4763,4786}`，无 `000/111` |
| 4b | ★ **本机四页屏 + 千兆网** | **90 s** | 7 寸屏实拍：P1 总览 → KEY1 翻页 → P2 输入波形（预触发环形缓冲、中线、AUTO 时基）→ P4 逻辑时序 → P6 设置（改一个参数并回读确认）；切上位机：`host_app.exe` 点「以太网抓包」→ **28,672 点**原始波形到位 → 再放连续流统计 | 这块屏不是为了好看：不接电脑也能看输入波形、ABZ/UVW 时序和故障位，现场就能判"是传感器坏还是板子坏"；千兆网把 28,672 点原始波形一次搬进上位机（串口要 0.65 s）；**v90 实测 ping 4/4、UDP 抓窗 28,672 点 @50 MSPS** |
| 5 | **性能数据** | 60 s | 报告数据表全屏：精度/延迟/资源/回归；版本读回 `0x05F2=0x0019`、标定、**57 台测试台全绿**三张贴图 | 复合畸变 1273×；CORDIC 最坏 0.9375 LSB；板级内部一致性 offset 1.76° / RMS 0.71° / max 2.88°（**无外部基准，别当绝对精度念**）；生产位流 **10,978 LUT = 52.78% / 32 BRAM / WNS +0.199 / 1,504,220 B**；显示位流 **17,090 = 82.16% / BRAM 45.5/50 / WNS +0.221**；`sim/` 37 台 + `disp/` 20 台共 **57 台**全绿 |
| 5b | ★ **转台适配（v90）** | 60 s | 转台 + 传感头实拍：**先拍到读回 `0x05F2 = 0x0019`** → 转起来 → `z_rate.py` 读 **Z 7.62 / 7.65 Hz ⇒ 457–459 rpm** → 上位机角度连续、ABZ 边沿 **2048/转** → `angle_vs_sc.py` 打出 offset/RMS/max → 拔线演示 `0x0130` 变 LOST + `0x0132/33` 累加 | 换成 2048 周期/转的真转台：每腿对地 0.5 Vpp，经差分转单端放大到 8 Vpp；机械 1″ 只对应 0.57° 电角（103 LSB），瓶颈不在细分位数，而在**延迟、刻度偏心与漂移**；v90 把停位 Z 喘振用 45° 布防窗治掉，并保留三态锁定把"没锁 / 毛刺 / 真丢线"分开 |
| 6 | **应用** | 30 s | 伺服/机床/机器人关节场景图 + 硬件框图收尾 | 面向定制化与多轴同步的位置反馈：可换传感头、可按机械结构做误差补偿、一片 FPGA 多轴同步；下一步做二次谐波补偿，把 0.5% 谐波带来的 0.3571° 残余继续压下去 |

**剪辑硬规则**：
- 每出现一个数字，画面上就要有对应的**实物读数或截图**（不许纯字幕报数）；
- 标定过程**不能快进到只剩结果**——要能看到"斜椭圆 → 正圆"的转换瞬间；
- 结尾 5 s 留板卡与接线全景（评委用来看"确实是硬件做的"）。

---

## B. 待取证素材清单（按优先级，逐条勾）

### P0 —— 阻塞报告定稿

| # | 素材 | 取证方法 | 归档 | 状态 |
|---|---|---|---|---|
| P0-1 | **v90 生产位流 timing / utilization / DRC 三份报告数字** | 直接读 `deliverables/data/v90/prod_{timing,util,drc}.rpt`：WNS **+0.199** / TNS 0 / **0 失败端点** / 24,691 端点；LUT **10,978 = 52.78%** / FF 8,724 / BRAM 32/50 / DSP 17 / IOB 60 | 已归档 `data/v90/` | 🟢 |
| P0-2 | **v90 显示位流三份报告** | `data/v90/disp_{timing,util,drc}.rpt`：WNS **+0.221** / 0 失败 / 33,365 端点；LUT **17,090 = 82.16%** / BRAM 45.5/50 / DSP 20 | 已归档 `data/v90/` | 🟢 |
| P0-3 | **v90 冷启动** | 断电重上电，拍"上电即跑"（Flash 里是显示位流）；日志 `_flash2_work/prog_flash_v90.log` 的 `FLASHPROG FLASH_OK` 可同框 | `figures/v90_cold_boot.jpg` | 🟡 已验、未留图 |
| P0-4 | **Z 脉宽示波器带游标截图** | 探 `J5-7`（Z），1 kHz / `z_width=4` ⇒ 游标读 **4.883 µs**；再拍一张 `z_width=0` ⇒ 0.977 µs | `figures/` + 报告 §3.5 | 🔴 |
| P0-5 | **v90 转台镜头** | 烧 `enc_top_v90.bit` → 先拍版本读回 `0x05F2` = **0x0019** → 转台转起来 → 按 `board_day_checklist.md` 拍：`z_rate.py`（Z 7.62/7.65 Hz ⇒ 457–459 rpm）/ 标定 / `angle_vs_sc.py` / 拔线 LOST / 前馈量 `0x0124..26` | `figures/v90_*.png` + `video/` 第 5b 段 | 🔴 **待拍** |

### P1 —— 报告核心数据（评委最想看的三张图）

| # | 素材 | 取证方法 | 归档 | 状态 |
|---|---|---|---|---|
| P1-1 | **李萨如图（校正前斜椭圆 / 校正后正圆）** | `python tools\lissajous_capture.py --port COM3`（校前抓 → 写 `0x0502=0x0001` 一键标定 → 校后抓 → 汇总 `data/lissajous_summary.csv`）；可复现的斜椭圆：`calib_snapshot.py snapshot` 存系数 → `inject --offset 3000 --offset-c -3000 --gain-mismatch 1.25 --quad-deg 3` → 抓图 → `restore` | `figures/lissajous_before.png` / `_after.png`（健康基线，两组都 0.101%） | 🟢 |
| P1-1b | ★ **注入失真 → 一键标定 → 回正圆**（视频第 3 段用这组） | 同上 `--inject` 路径；板上实测：**17.786% → 0.101%，改善 ≈176×**（半径 mean 26,213.8，`OK(no-alarm)`；独立复测 17.795% → 0.102%） | `figures/lissajous_before_distortion.png` / `_after_distortion.png` + 两份 CSV | 🟢 |
| P1-1c | **一键标定重复性** | `python tools\calib_repeat.py --port COM3 --n 12 --csv deliverables\data\calib_repeat_summary.csv`（★ 默认端口 COM5，必须显式传 `--port`）；历史记录 **12/12 GOOD**、`retry`/`win_bad` 全 0（该轮次在旧位流上跑的，v90 未重跑） | `data/calib_repeat_summary.csv` | 🟡 旧轮次 |
| P1-2 | **误差曲线**（校正前后叠在同一张图） | 由黄金模型导出 + 板上 `angle` 残差叠加 | `figures/error_curve.png` | 🟡 |
| P1-3 | **动态频率-误差表** | 输入 1k / 10k / 50k / 100k / 200k / 500 kHz，逐点记 `angle` 残差；**延迟列仍空**（`lag_deg` 需 ILA 位流） | `data/freq_{...}.csv` + `freq_{...}.png` + `freq_robust_summary.csv` | 🟡 六点齐、缺延迟 |
| P1-4 | **延迟实测** | 示波器同屏：信号源正弦过零点 vs `a_out` 跳变沿 | `figures/latency_measure.png` | 🔴（`≈830 ns` 仅为设计值，报告 §7 R6 已如实登记） |
| P1-5 | ★ **`angle_vs_sc` 精度页** | `python _boardtest\angle_vs_sc.py COM6`，截 offset **1.76°** / RMS **0.71°** / max **2.88°** / \|err\|>5° **0.03%** 的终端输出；**画面里要打出"与指令角对比、无外部基准"** | `figures/v90_angle_vs_sc.png` | 🔴 **v90 必拍** |
| P1-6 | ★ **UVW 六态统计** | `python _boardtest\uvw_phase.py COM6`，截六态计数 `{5174,4761,4423,4776,4763,4786}` 与"无 `000/111`"判定 | `figures/v90_uvw_sixstate.png` + `data/v90_board/` | 🔴 **v90 必拍** |

### P2 —— 作品照片与加分素材

| # | 素材 | 取证方法 | 归档 | 状态 |
|---|---|---|---|---|
| P2-1 | **板卡整体照片**（含丝印、接线标号） | 顶视 + 45° 各一张，光线均匀 | `submission/photos/02_board_adc_frontend.jpg`、`03_board_front.jpg` | 🟢 |
| P2-2 | **接线详图**（AD9238 模块 ↔ J6、ABZ/UVW ↔ J5、串口） | 排针插位拍特写，图上标 J6-26/J6-9 等 | `figures/wiring.jpg` | 🔴 |
| P2-3 | **ILA 抓真毛刺的波形截图** | `tools/glitch_figure.py` 从抓包 CSV 出三面板图（单拍尖峰 / 抽值展宽 / `ang_glitch` 26 拍后置位）+ v9/v11 对照图 | `figures/ila_glitch*.png` | 🟢 |
| P2-4 | **`DEVICE_ID = 0x0C` 读回截图** | `python tools/uart_spi.py read 0x05F0` → `5A 01 F0 10 0C xx` | `figures/device_id.png` | 🔴 |
| P2-5 | **实现报告整页截图**（Sign-off 证据） | 打开 `data/v90/prod_timing.rpt` 的 Summary 段（**不要用旧版**），同框拍 `data/v90/prod_util.rpt` | `figures/timing_summary.png` | 🔴（v90 版） |
| P2-6 | **★ 真实传感头 / 磁环实测片段** | 接真实磁环（2048 周期/转），**手转**并拍 ABZ/UVW 随转动变化；v90 已用转台跑过闭环（457–459 rpm），本项只需补**画面** | `video/real_sensor.mp4` + `figures/` 静帧 | 🔴 只缺画面 |
| P2-7 | **串口直接看 ABZ/UVW 六路电平** | `python tools\demo_abz_uvw.py --port COM6 --seconds 30 --archive`（输出 `DEMO PASS`）或 `uart_scope.py --seconds 30 --csv io.csv --png figures/telemetry_abz_uvw.png`；PNG 第 3 行是按电角度的等效采样图 | `figures/telemetry_abz_uvw.png` + `data/telemetry_abz_uvw.csv` | 🟢（旧轮次，v90 建议重拍） |
| P2-8 | ★ **本机四页屏实拍（v90 显示位流）** | 逐页拍：P1 总览 / P2 输入波形 / P4 逻辑时序 / P6 设置，每页一张同框照（含手与触摸动作）；**P7 标定页已在 v88/v90 删除**，标定入口是 P1 标题带按钮（写 `0x0502=0x0001`）或 KEY0 长按；KEY1=Y9 翻页、J9/J10 都要 3.3 V、必须裸指 | `figures/screen_p{1,2,4,6}.jpg`、`figures/screen_touch.jpg` | 🔴 **v90 必拍** |
| P2-9 | ★ **千兆网端到端演示** | `host/dist_onedir/host_app/host_app.exe` → 以太网 → 抓包 **28,672 点** → ping 4/4；录屏 + 拍网口指示灯 | `video/clip_eth.mp4`、`figures/host_capture_ethernet.png` | 🔴 |

> ★ **P2-6 是答辩"送命题"的唯一解**（`../docs/02` §5.3）。
> 如果整支视频全是信号发生器，评委一定会问"**为什么用信号发生器而不是真实传感器**"。
> 报告 §5.2 已给出诚实答案（只有信号源才能注入**已知**的偏置/失衡/相位误差，这是定量标定的必要条件），
> **但必须配一段真实传感头的画面**，否则这段解释会被当成借口。

### P3 —— 收尾与风险项

| # | 素材 / 动作 | 说明 | 状态 |
|---|---|---|---|
| P3-1 | **示波器探 D11/D10 + s 通道输入** | D 分支坏样本"ADC 内部误码 vs 板级 SI"的直接判别（v10 相位实验已定案为捕获相位余量） | 🔴 已定案、可省 |
| P3-2 | **串口源端串阻** | 硬件侧 22–33 Ω，排线 ≤5 cm；XDC 只能约束+降驱动 | 🔴 |
| P3-3 | **2 h 长跑** | `_boardtest/soak_v68.py COM6 7200`（v90 未改遥测帧格式，沿用该脚本）；v90 已跑 60 s（597,886 帧 / 9,964.8 fps 不丢） | 🟡 60 s 已跑 |

---

## C. 开拍前的一致性检查（防止素材与报告数字打架）

- [ ] 报告全文的 AFG 幅度口径统一为 **8 Vpp**（若某次拍摄用了别的幅度，画面里必须写明，否则该素材作废）
- [ ] 视频里出现的每个数字都能在 [`evidence_index.md`](evidence_index.md) 找到同一行（v90 数字看 §1.7）
- [ ] **视频与报告不得出现 `docs/02` 那套 v6 快照数字**（6010 / 8822 LUT、WNS −3.352、1,445,812 B、34 探针）
- [ ] 板上位流版本（`0x05F2`）在画面里可读，且等于 **`0x0019`**，与报告 §4.2 声明的版本一致
- [ ] **画面里不出现任何厂商芯片型号**（作品介绍一律说"专用细分芯片"，不说牌子）
- [ ] 场景切换处不留"未完成"痕迹（终端报错、TODO、IDE 里未保存的标签）

---

## D. 「一次拍完」执行顺序（拍摄日，v90 版）

> **目标**：一次坐下（≈3 h）把 §A 视频分镜、§B 的 P0/P1/P2 取证项、以及示波器测量与频率表**一次拍完**。
> **排序原则**：先拍零依赖的静态素材 → 再一次接齐示波器探头（Phase 1）→ 做会改板上系数的标定 → 做要反复改 AFG 的频率阶梯 → 做要拆线的真实传感头 → 最后才换位流拍对照。
> 每步拍完立刻按"归档名"存盘，不要等收工再整理。

### D.0 固定设置（一次调好，全程不改）
- [ ] `J10`/`J9` → **3.3 V**（照片里要能看出拨码位置）
- [ ] AFG CH1/CH2 = **8 Vpp 正弦、相移 90°、1 kHz**（只有 Phase 2 改频率、Phase 3 拆线）
- [ ] 板载位流 = **v90 显示版**（`deliverables/data/v90/enc_top_disp_v90.bit`；读回 `0x05F2` = **0x0019**）—— 要纯串口镜头再换 `enc_top_v90.bit`
- [ ] 串口 **COM6**；`tools/uart_scope.py` 窗口 **1920×1080**（波形 + 李萨如）
- [ ] 相机：三脚架俯拍 + 补光；**关闭现场录音**（旁白一律后期）
- [ ] 每拍一个"数值镜头"，记下 AFG 档位 / `0x05F2` / 日期时间（后期核对用）

### D.1 Phase 0 —— 静态照片与屏幕截图（≈20 min，不碰 AFG）
| 步 | 拍什么 | 命令 / 操作 | 归档名 | 清单项 |
|---|---|---|---|---|
| 0-1 | 板卡顶视 + 45° | 三脚架俯拍、补光；画面含丝印与 J10/J9 拨码 | `figures/board_top.jpg`、`board_45.jpg` | P2-1 |
| 0-2 | 接线详图 | AD9238↔J6、A/B/Z↔J5、串口特写（后期标 `J6-26`/`J6-9` 等） | `figures/wiring.jpg` | P2-2 |
| 0-3 | `DEVICE_ID` 读回 | `tools\uart_spi.py read 0x05F0` → `5A 01 F0 10 0C xx` | `figures/device_id.png` | P2-4 |
| 0-4 | 时序签核页 | 打开 `deliverables/data/v90/prod_timing.rpt`，截 Summary 段（`All user specified timing constraints are met.` / WNS **+0.199** / 0 失败 / **24,691** 端点）；再截 `prod_util.rpt` 的 **10,978 = 52.78%** ★ **不要用旧版报告** | `figures/timing_summary.png` | P2-5 |
| 0-5 | 板载版本画面 | `tools\uart_spi.py read 0x05F2` → **0x0019**（读到别的值说明板上不是 v90，需重下） | `figures/build_id.png` | §C 检查项 |
| 0-6 | **屏四页实拍 + 触摸** | 逐页：P1→KEY1→P2→P4→P6；每页拍一张含屏与手（裸指）的同框照；P6 改一个参数并回读确认；**P7 标定页已删，标定走 P1 标题按钮或 KEY0 长按** | `figures/screen_p1.jpg` … `screen_p6.jpg`、`screen_touch.jpg` | P2-8 |
| 0-7 | **以太网演示录屏** | `host\dist_onedir\host_app\host_app.exe` → 以太网模式 → 抓包（28,672 点）→ ping 4/4；同时拍板卡网口指示灯 | `video/clip_eth.mp4` + `figures/host_capture_ethernet.png` | P2-9 |

### D.2 Phase 1 —— 示波器一次接齐（≈45 min，AFG 保持 1 kHz / 8 Vpp / 90°）
| 步 | 拍什么 | 接法与读法 | 归档名 |
|---|---|---|---|
| 1-1 | `ad_clk` 与 `ad_clk2` 同相 | CH1=`J6-26`、CH2=`J6-9`，10 ns/div | `figures/scope_adclk_phase.png` |
| 1-2 | `tPD` 带游标 | CH1=`J6-26`、CH2=`J6-38`（`CH1_D11`，**不要用 `D0`**），5 ns/div，两游标读 **3–4 ns** | `figures/scope_tpd_v11.png` |
| 1-3 | Z 脉宽 + 整周期 | CH1=`J5-7`：先 10 ms/div 拍整周期，再 1 µs/div 两游标拍 **4.883 µs** | `figures/scope_z_period.png`、`scope_z_width.png`（P0-4） |
| 1-4 | ABZ + UVW 六步 | A/B=`J5-5`/`J5-6`、Z=`J5-7`、UVW=`J5-8/9/10` | `video/clip_abz_uvw.mp4` + `figures/scope_abz_uvw.png` |
| 1-5 | 环路延迟（补 R6） | CH1 = AFG 正弦（分一路）、CH2=`J5-5`（`a_out`）：同屏读"过零点 → A 沿"，预算 ≈830 ns | `figures/latency_measure.png`（P1-4） |
| 1-6 | 李萨如（校前 / 校后） | ★ **一条命令**：`tools\lissajous_capture.py --port COM3`；手做也行：`uart_scope.py --png figures/lissajous_before.png` → 写 `0x0502=0x0001`（或 P1 按钮）→ `--png figures/lissajous_after.png`；**全程屏幕录制**（视频第 3 段，不许快进） | `figures/lissajous_before.png`/`_after.png` + `video/clip_calib.mp4`（P1-1） |
| 1-7 | ★★ **"注入失真 → 一键标定 → 回正圆"**（视频第 3 段用这个） | ① `calib_snapshot.py --port COM3 snapshot --save _synth_work\calib_before.json` ② `inject --offset 3000 --offset-c -3000 --gain-mismatch 1.25 --quad-deg 3` ③ `lissajous_capture.py --port COM3` ④ **必做** `restore --load _synth_work\calib_before.json`。实测 **17.786% → 0.101%，≈176×** | `figures/lissajous_before_distortion.png` / `_after_distortion.png`（P1-1b） |
| 1-8 | ★ **精度与六态读数** | `python _boardtest\angle_vs_sc.py COM6`（1.76/0.71/2.88）；`python _boardtest\uvw_phase.py COM6`（六态 `{5174,4761,4423,4776,4763,4786}`）；各截一张终端图 | `figures/v90_angle_vs_sc.png`、`v90_uvw_sixstate.png`（P1-5/P1-6） |

> ⚠ **1-6 的归档说明**：`lissajous_before.png` / `_after.png` 这一组是**恢复健康系数之后**抓的（只作健康基线）；`*_distortion` 那组才是**板上带着注入失真**抓的。**视频第 3 段用 `_distortion` 那组**。
> ⚠ **1-7 的坑（已修在工具里）**：`0x051A`（shift）**只有 4 位**，写 `0x00FF` 实际写进 `0x0F`；`uart_spi.do_write` 的哨兵路会在"目标值 == 当前值"时先写 `0x00FF` ⇒ 一次"把 shift 归零"的写会把 shift 顶成 3（增益 ×8），采到被污染的假读数。`tools/calib_snapshot.py` 现已裁剪 4 位、跳过"值相同"的写、并对增益倍数硬拒绝 `>1.999`。**每轮注入实验后务必 `restore`**。
> ⚠ **李萨如频率坑**：实时窗口要装下一整圈需要 `f_in ≥ 约 48.8 kHz`（`docs/07_board_checklist.md:122`）。1 kHz 下请用 `--png` 的**累积散点**判读，或临时把 AFG 升到 50 kHz 拍实时窗口（拍完改回 1 kHz）。
> ⚠ **标定必须在 Phase 2 之前**做 —— 标定会改板上系数。

### D.3 Phase 2 —— 频率阶梯表（≈45 min，只改 AFG 频率）
- 逐点：**1k → 10k → 50k → 100k → 200k → 500 kHz**，每点三步：
  1. 记 AFG 显示（频率/幅度）与时间；
  2. `uart_scope.py --port COM6 --seconds 5 --png figures/freq_<f>.png --csv data/freq_<f>.csv` ⇒ 记校正后半径 / 圆度 RMS / 状态位；★ **50 kHz 以上要先注意过速钳位**：实用约束 `inter*f_in/div ≤ 6.25 MHz`（`docs/08`），`0x0101` 的 `inter=256` 时 `f_in ≤ 24.4 kHz` ⇒ 拍 50k 及以上各点前先把 `0x0101` 改小（否则预期 `lag_warn`/`lag_fatal`，画面里要说明是刻意设置）。
  3. 抓一窗 ILA（`ILA_MODE=stage1`）⇒ `tools\ila_report.py _synth_work\ila_freq_<f>.csv` 读 **`★ 其中的恒定滞后 … deg`**。
- ⇒ 填报告 §6.3 表（P1-3）。
- ★ **第 2/3 步已自动化**（`tools/freq_ladder.py`）：

  ```powershell
  python tools/freq_ladder.py --port COM6 --with-diag --ila `
      --freqs 1k,10k,50k,100k,200k,500k --out deliverables\data --figures deliverables\figures
  ```

  离屏自检（不接硬件）：`python tools/freq_ladder.py --parse-only _synth_work\selftest_out.txt`。
  脚本**不读 AFG**，每点仍要**手记 AFG 显示（频率/幅度）与时刻**。

### D.4 Phase 3 —— 真实传感头（≈20 min，"送命题"，要拆线）
- 接真实磁环（2048 周期/转），**手转**（缓慢、尽量单向），连续拍 ≥20 s 的 ABZ/UVW 输出随转动变化。
- 转台能到位就改拍转台：`python _boardtest\z_rate.py COM6` 出 **Z 7.62/7.65 Hz ⇒ 457–459 rpm**，同框拍。
- 归档 `video/real_sensor.mp4` + `figures/real_sensor_01.jpg`…（P2-6，`docs/02` §5.3 的唯一解）
- 拍完把 AFG 接回去。

### D.5 Phase 4 —— 可选：旧版对照镜头（≈15 min，最后做）
- 如需"修复前"对照，下旧版位流拍 Z 喘振（停位连发多个 Z）与当时的不收敛页；**画面必须标注"旧版对照"**；拍完 **立即下回 v90**（读回 `0x0019`）。
- 若不想承担"画面里出现旧版"的解释成本，可**跳过本步**（报告已有 §1.7 与 `docs/39` 承担论证）。

### D.6 收工前一致性检查（= §C）
- [ ] LUT/资源只用 **v90**：生产 **10,978 = 52.78% / 32 BRAM / 17 DSP / WNS +0.199**；显示 **17,090 = 82.16% / BRAM 45.5/50 / WNS +0.221**
- [ ] 旁白里的"≈830 ns"要念成**设计值**（实测值由 1-5 步给出）
- [ ] `0x05F2` 镜头 = **0x0019**；`0x05F0` = `0C`
- [ ] 转速只念 **457–459 rpm**（来自 `z_rate.py` 的 Z 频率）；**串口"机械转速"栏的读数会因遥测混叠失真，画面里不要念它**
- [ ] 不得出现 v6 快照数字（6010/8822 LUT、WNS −3.352、1,445,812 B、34 探针）
- [ ] 视频里每个数字都能在 [`evidence_index.md`](evidence_index.md) 找到同一行
- [ ] 未拍项直接在本清单标 🔴 → 交片前再扫一遍 §B 的 P0 行
