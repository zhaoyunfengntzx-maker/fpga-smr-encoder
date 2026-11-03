# 42 上位机本轮改造清单（做了什么 / 怎么验 / 还差什么）

> 2026-11-02。对应需求：m00148「直连、千兆口、上位机可以大改」+ m00268「把所有能做的全部完成」。
> 方案背景见 `docs/41_host_refactor_plan.md` 与 `docs/40_host_ethernet_plan.md`。
> **本轮只动上位机（host/、tools/），一行 RTL 没碰**，因此不需要重新出位流，也不改板子行为。

---

## 0 一句话

以前这套软件能**看**（波形、转速、ABZ），这一轮把它补成能**判断**：
"前端到底差多少度""板子现在锁没锁住""这段采样的谐波有多大""为什么现场录不回来"——
四个问题现在都有数字回答，而且全部能在**离线自检**里复现，不依赖板子在手边。

---

## 1 落地清单（按价值排序）

| # | 能力 | 文件 | 证据 |
|---|---|---|---|
| 1 | **正交质量卡**：从遥测点云回归出两路幅值、正交误差、偏置，折算成角度误差 | `host/analysis.py`(+`front_end_error`) `host/panel_quality.py`(新) `host/page_overview.py` | 1500 帧合成数据读出 `R_s=1000.02 R_c=1030.00 ε=0.5012° off=(49.9,−30.0)`，折角 **3.40″**；见 `img/42_live_quality.png` |
| 2 | **抓包页频谱视图**：对数轴 0…−100 dB、THD、标出各次谐波 | `host/panel_capture.py` | 20 kHz + 1.2% 三次谐波 → 读数 `20.000 kHz / THD 1.20% / H3 1.20% / 分辨率 872 Hz`；见 `img/42_capture_spectrum.png` |
| 3 | **抓包页双游标**：Δt / 1Δt / Δs / Δc / 相位角 | `host/panel_capture.py` | `Δt 344.0 µs / f 2.91 kHz / Δs −2951 / Δc −6514 / ∠ −114.37°`；见 `img/42_capture_cursor.png` |
| 4 | **板上运行状态表**：前馈延迟/速度/修正、锁定状态机、累计掉锁、连续坏样本、板上偏置、补偿表开关、迟滞/限频/Z 脉宽/相位（29 个只读地址） | `host/regs.py`(+`decode_status`/`status_rows`) `host/panel_status.py`(新) | 诊断页 18 行读数，读不到一律「—」；见 `img/42_diag_status.png` |
| 5 | **可见性门控 + 流窗口放大**：看不见的页面不再喂 matplotlib；连续流快照 1024→4096 点 | `host/main_window.py`(`_tick` / `_on_stream_tick_body`) | 离线自检 290 项通过；丢包率待板上复测（见 §4） |
| 6 | **结构化日志**：标准库 `logging` + 轮转（512 KB×4 卷），带毫秒/级别/线程名 | `host/app.py` | 日志首行 `19:03:45.858 INFO  [MainThread] host: 诊断：…` |
| 7 | **负数渲染修复**：7 pt 下 ASCII `-` 没有暗像素（量得出字宽、画不出笔画），全站改用 U+2212 | `host/ui_kit.py`(`sgn`) `host/panel_capture.py` | 频谱刻度 −20/−40…、时域负半周刻度、负相位角均正常 |
| 8 | **二进制记录 + 回放**：`.bin` 每帧只存原始 18 B（10.8 MB/分，CSV 的 1/4），带 CRC 与结束标记；记录卡「回放记录…」按 10 kHz 把当时的帧重喂界面，波形/正交质量/告警照跑 | `host/record_bin.py`(新) `host/replay.py`(新) `host/panel_record.py` `host/main_window.py`(`start_replay`/`_replay_tick`) | 50 万帧写盘 0.05 s（176 MB/s）；回放 3000 帧逐字节一致；`python -X utf8 host\replay.py --selftest` 9 项 PASS；见 `img/42_replay.png` |
| 9 | **打包瘦身**：①裁掉用不到的 MKL 路径（AVX-512 / TBB / ScaLAPACK）；②换 PyPI 官方 wheel（OpenBLAS 版 numpy，MKL 222 MB → 19.5 MB）。**585.3 MB → 178.9 MB（−69%）** | `tools/_slim_spec.py`(新) `host/host_onedir.spec` `host/host_exe.spec` `host/requirements-build.txt`(新) | `check_package.ps1` 实测 178,855,280 B / 1068 文件，包内真起窗截图 + 烟测 exit 0，SHA256 `9589C898…C16C777`；OpenBLAS 下 `analysis/record_bin/replay/regs/encoder` 自检全 PASS |
| 10 | **全周补偿表 GUI**：导入误差曲线 CSV → 体检（覆盖/跳变/量程）→ 折算 4096 点表 → 写入 / 抽样回读 / 清零 / 启用；曲线同屏叠「实测点 + 折算表 + 板上回读」 | `host/panel_lut.py`(新) `host/lut_tool.py`(+起点检查) `host/main_window.py`(`task_lut_upload`/`task_lut_dump`) | 72 点误差曲线 → 峰峰 17.2″ / RMS 5.19″ / 折算 ±1102 LSB；22 项自检；见 `img/42_diag_lut_health.png` |
| 11 | **链路健康趋势**：每 2 s 采一点，6 分钟窗口画帧率 / 校验错 / 丢帧三条曲线 | `host/panel_health.py`(新) `host/main_window.py`(`_update_comm_stats`) | 11 项自检；造一段「帧率掉、校验错抬头」的数据出图正常；见 `img/42_diag_lut_health.png` |

### 1.1 新增自检

| 模块 | 自检项 | 命令 |
|---|---|---|
| `analysis.py` | 52 项 | `python -X utf8 host\analysis.py --selftest` |
| `regs.py` | 68 项（新增 18 项状态镜像） | `python -X utf8 host\regs.py --selftest` |
| `record_bin.py` | 12 项（新） | `python -X utf8 host\record_bin.py --selftest` |
| `replay.py` | 9 项（新） | `python -X utf8 host\replay.py --selftest` |
| `panel_lut.py` | 22 项（新，全周补偿表） | `python -X utf8 host\panel_lut.py --selftest` |
| `panel_health.py` | 11 项（新，链路趋势） | `python -X utf8 host\panel_health.py --selftest` |
| `selftest_ui.py` | 301 项（质量卡 6 + 回放 7 + 补偿表 7 + 趋势 4） | `$env:QT_QPA_PLATFORM="offscreen"; python -X utf8 host\selftest_ui.py` |

整仓门禁：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_offline.ps1 -Quiet` → **PASS**（compileall + 10 个模块自检 + 界面级 290 项）。

---

## 2 为什么是这几件事（判断依据）

1. **看得到，量不出**——波形画得再漂亮，也没人能从屏幕上读出"正交误差 0.5°＝3.4″"。
   而遥测帧里 `s/c/angle` 本来就在，缺的只是回归：`s = R_s·sinθ + o_s`、
   `c = R_c·cos(θ+ε) + o_c`，四次迭代就把 `R_s/R_c/ε/o_s/o_c` 拟合出来，**零带宽、零 RTL**。
2. **板上跑着，界面没有**——`0x0120…0x0145` 这一段（前馈、锁定状态机、偏置慢跟踪、
   补偿表）板子早就算好了，界面一个都没显示。现场"角度偶尔跳"时，唯一能区分
   "掉锁""坏样本超限""偏置跳变"的证据就在这几个字节里。现在一张表全读出来。
3. **现场问题带不回来**——以前出问题只能打电话描述。现在：日志有了级别/线程/毫秒，
   频谱能存图，质量卡有数字，诊断页有一屏截图就能说清。
4. **卡顿的真正原因是 matplotlib**——实时页一次重绘 30~80 ms 抢 GIL，收包线程被饿死
   （注释里记着实测丢 39% 包）。抓包页本来就是 QPainter，按像素列取包络，
   4096 点进 1000 列只走一遍 numpy。所以"看不见就别喂"和"窗口放大"是同一个改动。

---

## 3 怎么验（不需要板子）

```powershell
# 1) 整仓门禁
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_offline.ps1 -Quiet

# 2) 四个页面的目视走查（off-screen 出图，不弹窗）
$env:QT_QPA_PLATFORM="offscreen"; $env:QT_QPA_FONTDIR="C:\Windows\Fonts"
python -X utf8 tools\_smoke_live_page.py      # 实时页 + 正交质量卡
python -X utf8 tools\_smoke_diag_page.py      # 诊断页 + 板上状态表
python -X utf8 tools\_smoke_capture_plot.py   # 抓包页：频谱 + 游标两张图
python -X utf8 tools\_smoke_quality_panel.py  # 质量卡单独出图 + 断言读数
```

四个脚本都会把图存到 `%TEMP%`，并在 stdout 打 `SMOKE OK`。

## 4 需要板上复验的两件事

1. **丢包率**：连续流页开着、实时页切走，观察 `lab_sum` 里的"丢 N 点"。
   验收线：`丢点/收点 < 0.1%`（原来 1024 点/300 ms 时是千分级，理论上只会更好，
   因为 CPU 占用降了；但 4096 点快照本身多拷 24 KB，需实测）。
2. **状态表读数**：点诊断页「读一次」，确认 29 个地址里至少 18 个有值
   （`0x0124…0x0129` 与 `0x013D…0x0140` 是保留/未实现区，读到 0 属正常）。
   若整列"——"，说明该固件版本没有这几段地址，功能自动降级、不影响其它页面。

## 4.5 第 12 项：主窗口拆分（`main_window.py` 3019 → 1123 行（−63%））

以前所有东西都挤在 `MainWindow` 一个类里（2776 行、60+ 方法），改一处要在 2000 行里
找上下文。这一轮按"**职责边界**"把它拆成 8 个文件，**行为一行没改**（每步都跑
`host\selftest_ui.py` 的 301 项，全绿才继续）。

| 文件 | 行数 | 管什么 | 不做什么 |
|---|---|---|---|
| `host/main_window.py` | 1123 | 装配：建控件、布局、页面切换、快捷键、滚轮路由、窗口状态 | 不写协议、不跑任务、不画图 |
| `host/cmds_mixin.py` | 912 | 一次点击 → 参数校验 → 挑任务 → `TaskRunner` → 回填面板；抓包/连续流控制 | 不直接碰串口（全在 tasks.py） |
| `host/live_mixin.py` | 376 | 把收到的帧变成读数：tick、回放、链路看门狗、概览汇总 | 不写队列、不建控件 |
| `host/logview.py` | 99 | 日志分级/过滤/着色/工作线程投递 | 不碰采集 |
| `host/tasks.py` | 261 | 纯 I/O 任务函数（读寄存器、写表、读状态…） | 不 import Qt |
| `host/linkctl.py` | 199 | 链路存活判定、重连目标挑选、断开前排空事件 | 不碰界面 |
| `host/taskrunner.py` | 139 | 串行任务队列（一条线程，异常也当结果送回） | 不知道任务是干什么的 |
| `host/ui_consts.py` | 28 | `TAG_TEXT` / `STREAM_POINTS` / `cfg_from_regs`（两边都要用的） | 不 import Qt 控件 |

`MainWindow` 现在是 `class MainWindow(LogMixin, LiveMixin, CmdsMixin, QMainWindow)`，
MRO 决定方法归属，所以 `selftest_ui.py` 里 `w.log_line` / `w._on_check` / `mw.dev_id_ok`
这些调用**一个字都不用改**。

**拆分顺手抓到两个真 bug**（都是"只在特定分支炸"的那类）：

1. `host/panel_capture.py` 的 `save()` 用了 `os.replace` / `os.path.exists`，**却没
   `import os`** ⇒ 抓包页点「导出 CSV / 导出 PNG」必崩 `NameError`。已补。
2. `cmds_mixin.py` 搬过去以后 `_on_square_preset()` 里 `SQUARE_POINTS` 没有来源
   （它原来靠"在同一个模块里"可见）⇒ 「方波可看」在"已经是能看方波的组合"那个
   分支上会崩。已补 import。

第 2 个能被发现，靠的是新加的静态检查：`tools/check_names.py` 用标准库 `symtable`
扫出"引用了但既没定义也没导入的全局名"，已进离线门槛（②.5 步，0 处才继续）。
这类问题运行时只在某条分支炸，自检走不到，`compileall` 也查不出来。

**怎么验**

```powershell
python -X utf8 tools\check_names.py          # 0 处可疑引用
python -X utf8 host\selftest_ui.py           # 301 项全绿
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_offline.ps1   # 整仓门槛
```

**没拆的部分（诚实记录）**：`_build_ui` + 7 个 `_page_*` + `_card_*` 仍在
`main_window.py` 里（约 600 行）。它们是纯控件装配，搬出去只会把 `self.xxx = ...`
改成 `win.xxx = ...`，收益小、回归面大；真要再拆，建议先给每页做一个 `PageBuilder`
接口，再逐页迁。

## 5 本轮没做（下一批）

| 项 | 为什么没做 | 前置 |
|---|---|---|
| 真波形页（用连续流 262144 点画时域+频谱） | 需要 UDP 流在板子上先跑起来才有意义 | 板子在线 |
| 打包再瘦到 ≤100 MB | 已做 585→179；再往下要①去掉 matplotlib（实时页波形改 QPainter）≈−45 MB，或②裁 Qt 的 Quick/Qml/Pdf + `opengl32sw.dll` ≈−44 MB（后者是无显卡驱动时的软件 OpenGL 兜底，删了虚拟机/远程桌面会白屏） | 单独一轮 |
| ~~主窗口拆分~~ | **已做**，见 4.5：3019 → 1123 行，拆出 7 个模块 | — |

## 6 回滚

所有改动都是**加文件 + 局部 patch**，没有删逻辑：
`git checkout -- host/main_window.py host/panel_capture.py host/panel_record.py host/app.py host/regs.py host/ui_kit.py host/page_overview.py host/selftest_ui.py host/host_onedir.spec host/host_exe.spec tools/check_offline.ps1`
再删掉 `host/panel_quality.py`、`host/panel_status.py`、`host/record_bin.py`、`host/replay.py`、`host/analysis.py`、`host/panel_lut.py`、`host/panel_health.py`、`host/tasks.py`、`host/linkctl.py`、`host/taskrunner.py`、`host/logview.py`、`host/cmds_mixin.py`、`host/live_mixin.py`、`host/ui_consts.py`、`tools/_smoke_*.py`、`tools/_patch_*.py`、`tools/_slim_spec.py` 即回到本轮之前。
`tools/_patch_*.py` 是本轮打补丁用的脚本，可留作"这些改动长什么样"的说明书。

## 5. 更正：转速口径（2026-11-02，用户报「转速不对」）

**症状**：连接后机械转速显示十万 rpm 量级，与电机实际转速完全不符。

**根因**：两件事被混成一件。

1. 界面「极对数」实际是**每转正弦周期数**。本机 EI58C9 是 2048，但输入框
   `setRange(1, 32)` 限死到 32，2048 根本填不进去（`host/panel_speed.py:55`）。
2. `_done_read_all` 把板上 `0x0100`（**电机极对数 P**，复位值 4，只给 UVW 生成用）
   直接 `speed.set_pairs()` ⇒ 每次连接都把口径改回 4。60×7196/4 = **107,942 rpm**。

**改法**（按 `docs/20_EI58C9_encoder_integration.md` §12）：

| 文件 | 改动 |
|---|---|
| `host/encoder.py` | `CYCLES_EI58=2048` / `CYCLES_LEGACY=64`，`DEFAULT_PAIRS = 2048`，`Z_INDEX_PAIRS` 同步；docstring 写明「不是电机极对数」 |
| `host/panel_speed.py` | 输入框 `setRange(1, 16384)`；tooltip 与卡片说明写清三种填法的倍数差 |
| `host/cmds_mixin.py` | `_done_read_all` 不再 `set_pairs(pairs)`，只记日志 |
| `host/live_mixin.py` | 概览行「极对数」→「每转 N 周期」 |

**验证**（用 30 s 实测 .bin 回灌 `SpeedEstimator`）：

```
f_in = 7196.125 Hz ｜ 每转 2048 周期 → 210.82 rpm（反转）｜ 累计 −105.786 圈 ｜ 丢帧 0%
同数据填 4  → 107,942 rpm      （就是改之前界面上的读数）
同数据填 64 → 6,746.4 rpm
```

**顺带纠正**：我先前给的 29.86 rpm / 22.1 rpm 是拿 16 位 `angle` 算的，而 `angle`
在 10 kHz 采样下对 7 kHz 输入必然混叠（`docs/DEV_STATUS.md:3032` 同一结论），
所以那两个数作废；正确口径是 `pos_full` 解回绕（`host/encoder.py` 主口径）。

门禁：离线门槛 PASS（compileall + 14 模块 + 名字检查 + 界面 305 项）。

---

## 6. 界面稳定性：不再"抖来抖去"（m02449）

用户原话：「软件界面不要抖来抖去」。**先用工具把"抖"变成可测的量**，再改。

### 6.1 定位方法（新工具，可复现）

`tools/_find_jitter.py`：搭起主窗口 → 切到某个页面 → 喂两组差异极大的数据
（A：幅值 900 / 偏置 3 / 2.2 圈；B：幅值 26000 / 偏置 180 / 3.7 圈）→ 前后对比
每个可见控件的 `geometry()`，打印尺寸或位置变了的控件。

    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\_find_jitter.py live

`tools/_find_flicker.py`：数"数字本身跳了几次"——喂 60 批 × 100 帧（= 界面 60 次刷新），
记录每个数值标签的文本变化次数，≥3 次列为"抖"。

### 6.2 根因（数据说话）

第一次跑 `_find_jitter.py live`：**22 个控件变尺寸**。根因不是数值，是**行高**：

* 数字用 Inter（等宽数字），汉字由回落字体（微软雅黑）渲染，两者行高差 **4~6 px**；
* 一行读数在「2.08 %」（纯数字）与「门限未读到」（汉字）之间切换时，
  该行标签高度 **27 ↔ 31 px**；
* 于是整张卡片高度跟着变（`WavePanel 1377x520 → 1377x512`），
  下面所有卡片被顶得上下跳 —— 这就是肉眼看到的"抖"。

第二个独立原因：**自动横轴的档位在边界上翻**。`_auto_span_ms()` 按 1-2-5 档量化，
输入频率在档位边界（例如 2 ms ↔ 5 ms 之间）天然波动时，档位每帧都换，
整幅波形跟着缩放。

### 6.3 修法

| 位置 | 改法 |
| --- | --- |
| `host/ui_kit.py` | 新增 `CJK_FAMILIES`、`cjk_height(lab)`、`lock_row_height(lab)`：按"当前字体行高与同字号雅黑行高取大 + 2"**锁死**标签的最小/最大高度；`small_label()` 与 `field()` 直接调用；`refresh_fixed_lines()` 扩展成对 `FieldName/BigValueSmall/BigValue/BigValueTiny/Mono` 全部重锁（字号缩放后重新计算） |
| `host/panel_wave.py` | ① `v_amp`、`v_refresh` 给 `vmin=176`（这两格会出现「门限未读到」「10.0 次/秒」，150 px 不够，列宽会抽）；② `_auto_span_ms()` 加**迟滞** `_span_hyst`：当前档在 `need ∈ [cur/2.5, cur*1.25]` 内不动，越界才换档（迟滞带必须**宽于**选档区间 `cur/2 … cur`，两条带重叠才真不翻）；③ 自动档加 **5 ms 下限**——10 kHz 遥测下 0.5 ms 窗口只有 5 个点，画出来是一条几乎不动的折线，比窗口偏大更难看 |
| `host/panel_status.py` | 值列 `setMinimumWidth(168)`、说明列 `setMinimumWidth(400)`、名称与值都 `lock_row_height()`（值在「—」22 px ↔「曾锁定 当前锁定」160 px 之间切） |

### 6.4 验证

| 检查 | 结果 |
| --- | --- |
| `_find_jitter.py` 七个页面 | **全部 0 个控件变尺寸**（overview 63 / live 150 / enc 97 / alarm 67 / record 62 / capture 69 / diag 183 个可见控件） |
| `_find_flicker.py live`（转速漂移 ±0.02%） | 只剩 2 个标签在变：电角度、累计圈数 —— 这两个**本来就该变**（转速 211 rpm 时 0.6 s 转 2.1 圈） |
| 自动档迟滞 | f 在 980~1025 Hz 抖动时档位序列恒为 2.0 ms（改前会在 2 ↔ 5 ms 之间反复跳） |
| 离线门槛 | **PASS**（compileall + 14 模块 + 名字检查 + 界面 **307** 项，新增 4 项：20 kHz 落 5 ms 下限、400 Hz 跟 5 ms、100 Hz 跟 20 ms、关独立窗口后主卡量程不变） |

截图：`docs/img/44_live_stable.png`。

### 6.5 顺带修的文案

「极对数」→「每转周期数」（同一处口径混淆，见第 5 节）：卡片标签、说明正文、tooltip
三处统一，说明正文改成"这个「每转周期数」就是每转正弦周期数：本机 EI58C9 是 2048…"。

## 7. 抖动第二轮：真因是"宽度"，不是"行高"（m02689）

第一轮（§6）修的是**行高**在数字/汉字之间跳，那是真问题，但不是全部 —— 用户复测
仍看到上下乱晃。第二轮换了个测法：**每 100 ms 拍一次所有可见控件的几何**，看谁在动。

### 7.1 找到的真因

```
    · BigValueSmall   '观测 2 帧…'  224 → 234，变了 35 次
```

`QLabel` 不换行时，`minimumSizeHint()` **等于文字宽度**。于是：

1. 读数从「观测 2 帧」变「观测 15 帧」→ 该标签最小宽度 +10 px；
2. `QGridLayout` 的整列跟着 +10 px → 右邻列被推走（横向抽动）；
3. 列宽一旦超过可视区，**横向滚动条出现/消失**又改可视区高度 → 整页上下跳。

再叠加第一轮的 `fix_lines()` 留了 `lines ~ lines+1` 的余量：实测一条 `Hint` 在
**47↔48 px** 之间跳 25 次，整张卡片 +1 px、整页内容 +1 px。

### 7.2 修法

| 位置 | 改动 |
| --- | --- |
| `host/ui_kit.py` `field()` | 数值标签 `setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)`：宽度只由格子决定，不再跟着文字走；`vmin` 保留，列左边界仍对齐 |
| `host/ui_kit.py` `_apply_fixed_lines()` | 高度锁成**正好 N 行**（`min == max`），不再是 `N ~ N+1` |
| `host/ui_kit.py` 新增 `allow_lines()` | 给**静态**说明文字留余量（它只随窗口宽度换行，不会自己跳）；动态提示仍必须锁死 |
| `host/ui_kit.py` 新增 `TipLabel` | 文字被格子裁掉时，悬停能看到全文（否则用户以为没读数） |
| `host/panel_abz.py` | 两列读数各给最小宽（380 / 430）并让右列吃富余宽度；`Z 脉冲` 独占一整行（原来挤在半张卡里，尾巴被裁） |

### 7.3 验证

```
工具：tools/_watch_layout.py  （每 tick 拍几何，报告"变了几次"）
      1280 宽 / 1600 宽 × 七页，各 25~30 tick
结果：14 组组合全部 "几何变过的控件：0 个"
工具：tools/_audit_hints.py   （查锁成 N 行的提示有没有装不下）
结果：窗口宽 1280 ｜ 装不下的提示：0 条
门禁：离线门槛 PASS（compileall + 14 模块 + 名字检查 + 界面 311 项）
```

## 8. UVW 半边也可调（m02689）

「编码器信号」页原来只有 ABZ 那半边能调（横轴 / 排布 / 间距），UVW 那幅图完全
跟着 ABZ 的窗口走。现在 UVW 有自己的三样控件（在控制条第二行 `UVW` 之后）：

| 控件 | 作用 | 说明 |
| --- | --- | --- |
| 横轴下拉 | 整圈 360° / 180° / 120° / 90° / 60° / 30° | 与 ABZ 的横轴**各自独立**；60°/30° 放大看一个扇区内部的边沿 |
| 每转周期数 | 1…256（默认 4） | UVW 电角度 = 角度 × pairs（板上 `0x0100` 极对数）；改了会清空累积并重新分箱 |
| 扇区线 | 开关 | 60°/120°/180°/240°/300° 分隔线，只画落在窗口里的 |

标题会跟着显示「每转 N 周期；窗口 X°」，界面上新增 4 项自检
（横轴、pairs 双向、扇区线），界面级自检从 307 项涨到 **311 项**。

### 8.1 UVW 为什么"乱"，以及改成扇区块（m02917）

用户截图里 UVW 那幅图是一堆细碎尖刺。**不是信号乱，是采样密度撑不起折线**：

- 输入 156.25 Hz、帧率 10 kHz ⇒ 每个输入周期 64 帧；
- UVW 电角度 = 输入角 × 每转周期数（4）⇒ 一个 UVW 周期只有 **16 帧**；
- 而箱数是 1024（每箱 0.35°）⇒ 360° 里只有 **16 个箱有数**（截图里的 `16/1024`）。

用 `steps-post` 把这 16 个零星箱连成 1024 箱的折线，必然锯齿。改法：

- **每个 60° 扇区取多数票 → 画一段粗块**（`linewidth 3.4`、两端各留 0.6° 间隙）；
  不管窗口多宽，永远只有 6 段，整齐可读；
- 理论虚线（`ideal_u/v/w`）照旧叠着做对照；
- 量程行补一个诚实的密度指标：`UVW 覆盖 N/1024 箱`，少于 64 箱时注明「相位锁死，属正常」——
  免得用户以为界面坏了。

ABZ 那幅图不受影响（它的样点密度高得多，方波本来就画得出来）。

---

## 9. 全部走网口连续流：一个「数据源」按钮（m02995）

> 原话：「走以太网连续流 ，上位机全部可以走以太网连续流，保留一个切换按钮就好」

### 9.1 为什么不是一个简单的开关

串口遥测是**板子算好的 10 kHz 帧**（角度、`pos_full`、ABZ/UVW 电平、`io_flags`、
`stat` 全在里面）。连续流里只有**两路 ADC 的 (s, c)** —— 角度、位置、电平、
状态位一个都没有。所以"全部走网口"不是换个数据通道，而是要在上位机把这一整套
现算出来：

| 量 | 网口模式怎么来 | 与串口模式的关系 |
|---|---|---|
| 电角度 | `atan2(s, c)`（上位机现算） | 与板上 CORDIC 同源，但不是同一个数（量化差 ≤ 1 LSB） |
| `pos_full` / 累计圈数 | 差分折 ±180° 累加，再量化成 `(周期数 << 16) | 角度` | 与板上同一个定义，因此转速口径 2048 周期/转照旧 |
| A/B/Z/UVW 电平 | 按板上 `inter`/`pairs`/`Z` 配置**推导** | **不是测出来的**，界面上必须写明 |
| `io_flags` / `stat` / 告警位 | 没有，置 0 | 网口模式下「幅值/滞后」类告警不生效，正交质量卡照常（它只用 s/c） |

### 9.2 关键设计：在收包线程里做 10 kHz 抽头

连续流是 12.5~50 MSPS，而面板全是按 10 kHz 帧写的。天真做法是每 tick 抓一段原始
样点 —— 但环形历史只有 262144 点（25 MSPS 下 10.5 ms），**盖不住 100 ms 的刷新
周期**，跨 tick 就会跳样点。

所以改成在 `StreamReceiver._store()` 里顺手抽：每个包进来按"每 step 点取一点"
切片（`step = fs / 10000`，25 MSPS 时 2500），用 `_tap_off` 记住相位，跨包严格
等间隔。得到的是**连续、无空洞**的 10 kHz 序列，`snapshot_frames(n)` 直接取。

代价：每包一次切片（350 点 → 0~1 个样点），可以忽略。

### 9.3 改了哪些文件

| 文件 | 改动 |
|---|---|
| `host/net_frames.py`（新，约 270 行） | `FrameSynth`：(s,c) → 帧 dict（`angle/angle_deg/pos_full/cycle_cnt/io_state/io_bits/stat`…）；`frame_hz_step()`；13 项自检 |
| `host/stream_capture.py` | `StreamReceiver` 加 `frame_hz`/`frame_hist`、`_tap()`、`snapshot_frames()`，`clear()` 一并清抽头 |
| `host/live_mixin.py` | `_on_source_toggle/_net_on/_net_off/_net_tick_body`；`_tick_body` 顶部按数据源分流 |
| `host/main_window.py` | 顶栏加 checkable 按钮「数据源：串口 / 网口流」 |
| `host/cmds_mixin.py` | 开流成功后，如果按钮在等（`_net_want`）就自动切到网口 |
| `tools/check_offline.ps1` | `$Modules` 加 `net_frames`（现 **15 个**） |
| `host/selftest_ui.py` | 加 4 项切换检查（现 **315 项**） |

### 9.4 行为约定

- 切到网口**不断开串口**：自检、倍频、补偿表、板上状态都还要走串口。
- 没连串口时按按钮会被**弹回去**并提示「开流要写 0x070C/0x0720」——开流需要串口。
- 网口模式下 3 s 没收到包：记一条 warn，并把按钮切回串口（不弹框）。
- `setChecked` 必须 `blockSignals`，否则 `_net_on → toggled → _on_source_toggle →
  _net_off` 会自弹（自检抓到的真 bug）。

### 9.5 验证

- `host/net_frames.py --selftest` → 13 项 PASS（步长、36°/帧、`pos_full` 步长 6553.6、
  UVW 六状态、A/B 占空比、Z 只在每转开头、反向为负增量、空输入）。
- `tools/_smoke_net_mode.py`（新）：本机起 `StreamReceiver` 灌 6000 个真尺寸包
  （350 点/包）→ 切网口 → 抽头 `step=5000`、420 帧进面板、波形缓冲 1500 帧、
  `f_in = 1000.0 Hz`（真值 1000）→ **SMOKE OK**。
- 离线门槛：**PASS（compileall + 15 模块 + 名字检查 + 界面 315 项）**。

### 9.6 还不知道的

- 真板子上网口连续流的最大可持续速率、丢包率与 `f_in` 抖动，都要接到板子后实测。
- 网口模式下「告警」页的滞后/幅值类告警不生效（那几位只存在于串口帧里）。

---

## 10. 数据源改成"可选 + 默认网口"（m03198）

> 原话：「数据源最好可以选择，默认可以选择网口进行传输，这样是不是效果更好？」

是的，而且更省事：**默认选网口**，串口连上就自动开流；网口起不来再自动退回串口，
用户不需要先决定用哪条链路。

### 10.1 改了什么

| 位置 | 变化 |
|---|---|
| 顶栏 | 可勾选按钮 → **下拉框**（「网口连续流」/「串口遥测」，网口排第一 = 默认） |
| `ui_prefs.py` | `DEFAULTS` 加 `"data": {"src": "net"}` —— 选择记到 `ui_prefs.json`，下次启动保持 |
| `live_mixin.py` | `_on_source_changed`（写偏好 + 切换）、`_net_start`（按需开流）、`_net_give_up`（6 s 超时退回串口）、`_maybe_auto_net`（连上串口后自动开） |
| `live_mixin.py` | `_net_on` 记 `_net_had_worker`：**在线时**串口断了才退回串口；离线冒烟不算 |

### 10.2 三条行为约定

1. **默认网口**：连上串口 1.5 s 后自动开连续流，起来就切过去。
2. **6 s 起不来就诚实退回串口**：日志写「网口连续流 6 s 没起来：先退回串口遥测」，
   下拉框同步跳回「串口遥测」——不让界面挂着"网口"却没有数据。
3. **选择会被记住**：`ui_prefs.json` 的 `data.src`，下次启动照上次来。

### 10.3 踩到的两个真坑

- **下拉框把窗口最小宽度顶到 1228 px** ⇒ 界面自检里「关窗记住 1200×760」直接失败。
  修法：去掉「数据源」文字标签、下拉框最小宽度 132 → 118，最小宽度回到 **1150**。
- **`ui_prefs` 有"未登记键"自检**：`up.raw("data","src")` 一旦用了但没进 `DEFAULTS`，
  `_merge()` 只遍历默认键 ⇒ 存得下、读不回（每次启动都回落）。已登记，自检 15 → 16 项。

### 10.4 验证

- 界面自检 **316 项 PASS**（新增 5 项：下拉框两项且网口在前、选串口回串口态、
  没连串口时不硬切、网口态与下拉框一致、切回收尾）。
- `ui_prefs` 自检 **16 项 PASS**。
- `tools/_smoke_net_mode.py`：抽头 `step=5000`、420 帧、波形缓冲 1500 帧、
  `f_in = 1000.0 Hz` → **SMOKE OK**。
- 离线门槛 **PASS（compileall + 15 模块 + 名字检查 + 界面 316 项）**。

---

## 11. 网口连续流可靠性：两个真因（m03305 上板测试）

> 原话：「现在进行上板测试，请测试网口连续流的可靠性，我刚才感觉总是启动不起来网口连续流」

先复现、再定位、修完复测。复测结果：**首次开流 + 重启 3 次，4/4 成功，62,500 pkt/s 稳定**。

### 11.1 复现与分层

写了两个探针（`tools/_probe_stream.py` / `_probe_stream2.py`），每次尝试都同时读板端
`TX_PKT(0x0712)` 和本机收包数，用这两个数的组合把故障分层：

| 现象 | 含义 |
|---|---|
| TX 在涨、本机 0 包 | 板子发了，PC 没接住（绑定 / 目的 IP / 防火墙） |
| TX 不涨、本机 0 包 | 板子根本没发（配置 / 板端 FSM） |

### 11.2 真因一：`_net_start()` 调用了一个不存在的方法（直接原因）

`host/live_mixin.py` 里写的是 `self._on_stream_go()`，而真正的开流入口是
`cmds_mixin._toggle_stream(p)`。异常被外面 `except Exception` 吞掉，于是：

```
选「网口连续流」→ 日志一闪「正在开网口连续流…」→ 6 s 后 _net_give_up()
→ 下拉框自己跳回「串口遥测」→ 一个包都没有
```

**为什么自检没抓到**：`tools/check_names.py` 用 `symtable` 查的是"全局名有没有定义"，
`self.foo()` 是属性访问，静态查不出来；而界面自检没走真开流路径。已改成
`self._toggle_stream(dict(self._stream_params or {}))`。

### 11.3 真因二：板端 `host_known=0` 时"照发但不通"（隐性原因）

实测：`0x0710 bit2(host_known)=0` 时，板子 `TX_PKT` 照常累加（+1500/3 s），
但主机**一个包都收不到**——它不知道目的 MAC。此时只要从 PC 发一个 IP 包
（ping 即可）让它学到主机 MAC，`status` 立刻变 `0x0007`，随后 4 s 收 25 万包。

修法三处：

1. `_warm_arp()` 明确 `-S 192.168.1.100`（本机 WLAN 也在 192.168.1.0/24，
   不指定源地址可能从 Wi-Fi 发出去，板子学到的是无线网卡 MAC）；
2. `_stream_open_device()`：开流**前**强制确认 `host_known=1`（最多 4 次 ping），
   开流**后** 0.6 s 验一次"真的收到包"，收不到就补 warm + 重开，两次都不行才报错
   （错误文案直接点名"板端还没记住主机 MAC"）；
3. `_net_tick_body()`：运行中 3 s 没有新包就自动补一次 warm 并写日志，
   不再让界面"挂着网口、静默无数据"。

### 11.4 环境事实（会反复咬人）

- **UDP 5000/5001/5002 被 `lkcitdl`(PID 7960) 等进程占着**（装过 Vivado 的机器，
  许可证服务常驻）⇒ 首次 bind 必然失败，程序回落到系统临时端口（实测 5003），
  然后把真实端口写进 `0x070C`。这条链路是好的，但**默认端口一定要能自动退**。
- PC 是**双网卡同网段**：以太网 192.168.1.100/24（metric 25）+ WLAN 192.168.1.104/24
  （metric 35）。路由表有线优先、ARP 在以太网侧解析到 `00-00-02-00-00-01`，
  但任何"不指定源地址"的发包都可能走 Wi-Fi ⇒ 所有 warm-up 都必须 `-S` 绑源。

### 11.5 复测

`tools/check_stream_reliability.py COM4 3`：

```
板端 0x0710 = 0x0007（bit2 host_known）
  首次开流   host_known=1  收 250308 包  (62577 pkt/s)
  重启 1     host_known=1  收 250480 包  (62620 pkt/s)
  重启 2     host_known=1  收 249761 包  (62440 pkt/s)
  重启 3     host_known=1  收 249190 包  (62298 pkt/s)
结论：4 轮里失败 0 轮
```

主程序端到端（`tools/_e2e_stream2.py`，真窗口 + 真板子）：源切到网口后
`_stream.packets` 2 s 内 +58,975，正交质量卡拿到 4096 帧（410 ms），
波形缓冲 1500 帧；随后 3 次重启全部 `源=net`。

---

## 12. 输入信号波形：网口模式下改画"真波形"（m03464）

> 原话：「输入信号波形还是很糟糕，能不能通过网口连续流进行优化？」

能，而且这正是该用连续流的地方。

### 12.1 为什么"糟"

那幅图的数据源是 **10 kHz 遥测帧**。1228 Hz 的输入在 10 kHz 下只有 **8.1 个点/周期**，
采样点连直线画出来必然是折线状（再看李萨如却是干净的圆——说明每个 (s,c) 点都对，
只是"点太少、时间轴太粗"，不是信号坏了）。

### 12.2 改法

| 位置 | 变化 |
|---|---|
| `panel_wave.py` | 新增 `feed_raw(s, c, fs)` / `_redraw_raw()`：吃连续流**原始样点**，按像素列取 min/max 包络抽稀，时间轴用真实采样率；李萨如用同一块样点 |
| `panel_wave.py` | `feed(frames)` 一旦有帧就清掉 `_raw`——串口模式 / 回放自动退回帧模式，不用另加开关 |
| `live_mixin._net_tick_body` | 波形卡可见时 `wave.feed_raw(snapshot(65536))`，**不再**把 10 kHz 帧喂给波形卡（两种数据混一张图会互相打架） |

读数（r 均值 / 范围 / 圆度 / 判定）仍在同一块原始样点上算，所以和波形一致。

### 12.3 效果

`tools/_smoke_raw_wave.py`（1228 Hz、12.5 MSPS、10 ms 窗）：标题变成
「真波形 125000 点（10.000 ms @ 12.500 MSPS，连续流原始样点）」，
画出来是**平滑正弦**，不再是折线。窗口仍是 10 ms 档（可调），
按像素列包络后 matplotlib 只画约 1200 个点对，重绘开销比原来 1500 点还低。

代价：网口模式下波形卡每 100 ms 多取一次 65536 点快照（约 0.3 MB 拷贝），
在 62.5k pkt/s 的收包线程旁可忽略；帧流照旧喂转速 / 正交质量 / ABZ。

> 注：本次只改了波形卡。串口模式（或没网口时）仍用 10 kHz 帧，8 点/周期
> 的折线是物理上限，不是 bug。

### 12.4 上线即踩的坑（m03568「连上之后实时页彻底不动」）

第一次发布真波形时写成 `r.fs_for_dec(r.base_fs, raw["dec"])` ——
**`fs_for_dec` 是 `stream_capture` 的模块级函数，不是 `StreamReceiver` 的方法**，
于是每个 tick 都抛 `AttributeError`。而这段代码位于 `_net_tick_body()` 的最前面，
异常一抛，后面的转速 / 波形 / 正交质量 / 告警全部不再执行 ⇒ 整页冻结
（界面标题栏还显示"已连接"，状态栏只有一行 `AttributeError`）。

两处修：

1. 改成 `float(r.base_fs) / float(1 << int(raw.get("dec") or 0))`（不依赖别的模块）；
2. **给波形取点单独包一层 try**：波形是装饰性的，它出错只许记一条日志（5 s 限频），
   绝不许把同一 tick 里的读数更新一起带走。

教训：**`check_names.py` 只能查全局名，查不到 `obj.attr` 这类属性访问**；
凡是"新写的、位于 tick 主路径最前面"的代码，要么放在最后，要么包 try。

## 13. 修「连接 → 断开 → 再连接后，网口连续流起不来」（m03633）

### 13.1 三个真问题

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 1 | host/cmds_mixin.py _toggle_stream() | 用 if self._stream is not None 判断正在跑。断开时 _stream 常是残留（接收线程已死/上一条开流半途失败），于是点「网口」执行停流并 
eturn，表现为再也开不起来 | 只有 getattr(r, running, False) 才算在跑；残留先 _stop_stream() 再开 |
| 2 | host/live_mixin.py _net_tick_body() | 没流时直接 _set_src_combo(serial)，偏好被改掉，_maybe_auto_net 不再动作 | 偏好仍网口 + 串口在线 + _net_retry_n < 3 时每 3 s 自动重开并记日志；3 次失败才切回串口 |
| 3 | host/main_window.py disconnect_port() | 断开时没清网口状态，重连后 _src 还停在 
et、_stream 却是空的 | 补 _net_off(串口已断开) + _net_want=False + _net_retry_n=0 |

### 13.2 离线回归（不需要板子）

	ools/_test_reconnect.py 用假 worker / 假 stream 摆出三种残留态，7 条断言全过：

`
PASS 死流时点网口走开流      PASS 没流时自动重开一次
PASS 死流残留被清掉          PASS 三次失败后切回串口
PASS 活流时点网口走停流      PASS 断开后 _src 回串口
PASS 断开后 _net_want/_retry 归零
`

### 13.3 门禁

`
离线门槛 PASS（compileall + 15 个模块自检 + 名字检查 57 文件 0 处可疑 + 界面级 316 项）
`

### 13.4 上板实测（2026-11-03 07:0x，COM4 / 192.168.1.10）

```
python -X utf8 tools\check_stream_reliability.py COM4 4
  首次开流  host_known=1  收 251467 包 (62867 pkt/s)
  重启 1    host_known=1  收 249587 包 (62397 pkt/s)
  重启 2    host_known=1  收 250563 包 (62641 pkt/s)
  重启 3    host_known=1  收 250497 包 (62624 pkt/s)
  重启 4    host_known=1  收 250484 包 (62621 pkt/s)     ⇒ 5/5 成功

python -X utf8 tools\_e2e_reconnect.py COM4            ⇒ 两轮 20/20 断言全过
  第1轮/第2轮：数据源切到网口、包数在涨、波形卡拿到样点、正交质量卡拟合过、转速卡有频率
  断开后：worker 归零、数据源回串口、连续流停掉
```

## 14. 真波形"一条实心色带"的根因：横轴跟错了频率（m03464）

### 14.1 现象与判据

上板截图里「输入信号波形」是一整片实心色带。**先证伪"画法有问题"**：用合成正弦
（2727 Hz @ 12.5 MSPS）直接喂 `feed_raw()`，画出来是干净正弦 ⇒ 绘制没问题。
再用 `tools/_probe_raw_order.py` 拿真样点：65536 点的相邻角度增量**中位数 0.019239 rad、
±0.5 外 0 个点** ⇒ 样点时间顺序完全正常，**真实信号约 38 kHz**，而转速卡（10 kHz 帧口径）
报 2.8 kHz。

5 ms 窗口里塞 190 个周期，1100 px 摊下去每周期不到 6 px ⇒ 本色带就是"挤"出来的。

### 14.2 修法

自动横轴原来一律用 `self.f_in`（转速卡）。改成**原始样点模式用自己的估频**：

| 位置 | 改动 |
|---|---|
| `host/panel_wave.py` `feed_raw()` | 过均值零点计数估频 → `self._raw_hz`；切换模式时清 `_span_hyst` |
| `host/panel_wave.py` `_auto_span_ms()` | `raw` 时用 `_raw_hz`，上限放到 50 ms，下限 0.05 ms（12.5 MSPS 下仍有 625 点） |
| 新增 `_nice_span()` | 1-2-5 取整，让原始样点能落到 0.05/0.1/0.2 ms（固定档位表最小只有 0.5 ms） |
| `host/panel_wave.py` `feed()` | 回到帧模式时清 `_raw_hz` / 迟滞 |

实测横轴（合成信号，自动档）：

```
f=  200 Hz → 10.0 ms      f= 2727 Hz → 1.0 ms
f= 7200 Hz → 0.5 ms       f=38000 Hz → 0.1 ms
```

真板截图 `docs/img/44_raw_wave_ok.png`：1250 点 / 0.100 ms @ 12.5 MSPS，3.7 个干净正弦周期。

### 14.3 顺带发现（待决策，未改）

同一时刻：原始样点估频 ≈ **38 kHz**，而 10 kHz 遥测帧算出的输入频率只有 **1.5~2.8 kHz**，
转速卡还提示"方向位与位置走向不一致"。10 kHz 帧率对 38 kHz 输入本就不满足采样定理，
**这个速度下"转速/圈数"读数不可信**，只有网口原始样点那条链是准的。要不要在
`_update_speed()` 里对 `|f| > 3000 Hz` 直接标注"超出遥测带宽，读数已混叠"，等你定。

## 15. 概览页「前端质量」不要动不动就红（m03858）

### 15.1 原因：判据用的是电角度，不是机械角度

现场截图里「前端质量 0.567 °」整行标红。但 0.567° 是**电角度**，这台编码器每转
2048 个正弦周期 ⇒ 折成机械角只有 **1.0″**。原来的阈值（正交 0.20° 电、残差 2.0%）
按电角度定，等于把 0.4″ 的真实误差判成超差。

### 15.2 改法：一律折成机械角秒再判

| 项 | 旧阈值 | 新阈值 |
|---|---|---|
| 两路增益 | 0.05 / 0.20 dB | 1″ / 5″ |
| 正交误差 | 0.05 / 0.20 °(电) | 1″ / 5″ |
| 偏置合成 | 60 / 300 LSB | 1.5″ / 8″ |
| 残差 | 0.6 / 2.0 % | 2 % / 5 %（比例，不折角度） |
| 合计 | 无 | 2″ / 10″ |

`panel_quality.set_pairs(pairs)` 由 `live_mixin` 每 tick 传当前「每转周期数」进来，
`k_arc = 3600 / pairs`。读数单位也从 `°` 改成 `″`，否则概览页会出现「5.986 °」这种
既不像电角度、又不像机械角度的数。

判定文案示例（真板实测）：

```
前端正常（合计 1.00″，n=5541，554 ms）
两路幅值失配 -0.26 dB（1.5″）；偏置合成 58 LSB（5.8″）；合计 6.0″   ← 注意级（黄）
正交误差 17.6″（20.00° 电）；合计 17.6″                            ← 超差（红）
```

### 15.3 验证

- 界面级自检 **317 项 PASS**（原来"超差判 fault"那条拆成两条：正常前端"不标红"、
  正交 20° 电"才判 fault"，免得以后改阈值又假红）。
- `tools/_smoke_quality_panel.py` 三种造出来的数据（正常 / 半圈 / 少帧）判定符合预期。

## 16. 网口模式下概览页"卡住不动" + 一键关掉 AB 限频（m04184）

### 16.1 症状与真因

用户："首页经常卡住不动，转速变化时上位机里基本没有任何改变。"

不是偶发，是**必然**：

| 事实 | 位置 |
|---|---|
| `_refresh_overview()` 只在 `_update_speed()` 末尾调用 | `host/live_mixin.py:585` |
| `_update_speed()` 只在**串口**路径的 `_tick_body` 里调 | `host/live_mixin.py` 串口分支 |
| 网口模式的 `_tick_body` 在判断数据源后**提前 return** | `host/live_mixin.py:155-157` |

⇒ 选了「网口连续流」之后，实时页一直在动、概览页的数字却永远停在上一次串口时的值。
换转速当然不动。

### 16.2 修法

新增 `_net_ui_tail(now)`（`host/live_mixin.py`），在网口路径的**三个出口**都调：

- 每 tick 刷概览（很便宜，就是读几个控件）；
- 0.5 s 刷一次帧率 / 数据率 / 丢点 / 记录卡片 / 状态栏，口径用**网口**：
  `帧数增量/时间` 与 `UDP 数据报数 × 350 × 4 B`，文案显式写「网口 %.0f 帧/秒」，
  不假借串口的 `rx_bytes`（那是 0，会显示成 0 kB/s，反而更误导）；
- 异常一律吞掉（界面刷新不许打死收数线程）。

### 16.3 一键关掉 AB 限频

用户："不要限频锁存了……太容易锁存了，解除锁存非常麻烦。"

板端（`rtl/abz_gen.v:411`）：`gap = 20 ns × (0x0106+1) × div`，
即上限 `1 / (20ns × (值+1) × div)`。当前 inter=32 / div=1 / f_in≈20.8 kHz 时
AB 边沿率 `4×32×20821 ≈ 2.66 MHz`，而 `0x0106=64` 只允许 770 kHz ⇒ 每一拍都被压掉，
`0x0404 bit3`(inclim) 常亮、`0x0405 bit3` 清了立刻又锁。

- `host/tasks.py` 新增 `task_set_ablimit(worker, value=0)`：读 0x0106 → 用
  `regs.adv_field_writes("ablimit", value, raw)` 做**读-改-写**（不清同字节其它位）
  → `task_write_advanced` 写+回读确认。
- `host/panel_interp.py` 新增 `limit_fix_requested = Signal(int)` 与按钮
  **「关掉 AB 限频」**（写 0 ⇒ 上限 50 MHz，边沿率再高也不被压）。
- `host/cmds_mixin.py` 新增 `_on_fix_ablimit()` / `_done_ablimit()` 与 `"ablimit"` 分发、
  `finally` 里恢复按钮；`host/main_window.py` 连信号。
- 提示行仍保留建议值（"把 AB 限频改成 ≤17"），想保留保护的用户可以手改。

### 16.4 验证

```
离线门槛 PASS（compileall + 15 模块自检 + 名字检查 0 处 + 界面级 317 项）
tools/_smoke_net_mode.py  SMOKE OK（假流 f_in=1000.1 Hz，真波形拿到原始样点）
包内烟测 PASS（exit 0，截图 49.6 kB，Inter 4 个文件，建窗 1.3 s）
host_app.exe 7,926,832 B @2026-11-03 07:48:12
SHA256 28DF787DB9294BD495D3D25C34D99141592698FD14BDCC5D3ED5682481AB110C
目录 1068 文件 / 178,950,568 B
```

### 16.5 经验

- 一个函数被"两个人"需要（串口/网口）时，**把它挂在某一条路径的尾巴上**就是埋雷；
  这次的表现不是崩溃，而是"页面不动"，最难查。新加的收尾逻辑要么两边都调，要么放进
  `_tick` 的统一出口。
- 界面数字用哪路计数，要在文案里写明（"网口 62 帧/秒"而不是笼统的"帧率"），
  否则用户没法判断这个数是串口还是网口的。

## 17. 删掉 AB 限频（m04317「直接完全删掉限频」）

用户原话：「直接完全删掉限频」。上一版只做了"一键关掉"按钮，这次是**彻底删掉**：
软件里不再有限频提示、不再有按钮，且每次「应用倍频」和每次连上板子都会自动把
`0x0106` 写成 0。

### 17.1 改了什么

| 文件 | 改动 |
|---|---|
| `host/panel_interp.py` | 删掉 `lab_lim` 提示行、`btn_lim` 按钮、`limit_fix_requested` 信号、`_refresh_lim()` 方法 |
| `host/tasks.py` | 新增 `task_set_ablimit(worker, value=0)`（读-改-写，保留同字节其它位）；`task_apply_inter_div()` 末尾顺手写 0，结果放在返回值的 `no_limit` 里 |
| `host/cmds_mixin.py` | 删掉 `_on_fix_ablimit` / `_done_ablimit` / `"ablimit"` 分发；新增 `_done_nolimit` 与"连上后静默写 0"（`_done_check` 末尾），tag = `nolimit` |
| `host/main_window.py` | 不再连 `limit_fix_requested` |

### 17.2 板端语义

`rtl/abz_gen.v:411`：`gap = 20 ns × (0x0106+1) × div`，边沿间隔小于 gap 的被压掉，
并置 `0x0404 bit3`(limiter_active) / `0x0405 bit3`(粘滞)。写 `0x0106 = 0` 后
`gap = 20 ns` ⇒ 上限 50 MHz，实际边沿率（当前 ~2.7 MHz）永远碰不到，
`inclim` 的粘滞位也就不会再被点起来。

### 17.3 验证

```
离线门槛 PASS（compileall + 15 模块自检 + 名字检查 0 处 + 界面级 317 项）
包内烟测 PASS（exit 0，Inter 4 个文件）
host_app.exe 7,925,415 B @2026-11-03 10:25:40
SHA256 B646745E6306833C439E41ED4FE1D8DA617547F3122E3C48D9625D908A2440CE
目录 1068 文件 / 178,949,161 B
```

### 17.4 代价（写清楚，免得以后有人以为这是 bug）

限频器本来是"保护 AB 输出边沿别挤太近"的。删掉之后，如果把 `inter` 拉得很高
（例如 256）而输入又是 20 kHz 以上，AB 边沿间隔会小到 20 ns 量级 —— 板内逻辑
（50 MHz 时钟下 20 ns = 1 拍）能出，但外部接收端未必采得准。需要时把 inter 降下来，
这才是正确的做法；不要再靠限频器去"截断"。

## 18. 上板复测：网口 5/5、重连 20/20、限频确认关闭（2026-11-03 下午）

### 18.1 测了什么

| 项目 | 命令 | 结果 |
|---|---|---|
| 网口连续流连开 5 次 | `python -X utf8 tools\check_stream_reliability.py COM4 4` | 5/5 成功；首次 250,434 包（62,608 pkt/s），第 5 轮降到 39.6k pkt/s 但未断 |
| 连接→网口→断开→再连接 | `python -X utf8 tools\_e2e_reconnect.py COM4` | 两轮各 10 条断言，**20/20 全过** |
| 限频是否真关 | `0x0106` 连读 5 次 + 清锁存后盯 `0x0404` 2.3 s | `0x0106` 恒 `0x00`；清后 `0x0404` 恒 `0x0800`，**bit3(inclim)=0 不再置起** |
| 遥测链路 | `python -X utf8 tools\_probe_live.py --port COM4 --seconds 6` | 63,558 帧 / 6.4 s ≈ 9,900 帧/秒；校验错 268（0.42%）；丢帧 552；layout v2 |

前端（同一批 63,558 帧）：`R_s 26174.66 / R_c 26357.64`、增益 −0.061 dB、正交 +0.6003°、
偏置 +180.6 / +415.4、残差 483.5 LSB ⇒ 折机械角约 **1.9″**（探针脚本仍按电角度打印 3785.92″，
界面已经是角秒口径）。

### 18.2 这轮抓到的两个真 bug（都已修）

1. `host/tasks.py:task_set_ablimit()` 里 `d = worker.read_reg8(...)` 之后写 `d["value"]`。
   `read_reg8()` 返回的是**整数低字节**，不是 dict ⇒ 每次连上都会
   `TypeError: 'int' object is not subscriptable`。改正为 `cur = int(...)`。
   这条只在**真板**上暴露：离线自检里没有 worker，走的是 `None` 分支。
2. 现值已经是目标值时 `regs.adv_field_writes()` 返回空 dict，原逻辑据此报
   「读不到 0x0106 的现值」⇒ 每次连上刷一条假告警。改成先比 `adv_field_value()`，
   相同就直接返回 `{"ok": True, "writes": {}, "why": "已经是 0，无需改动"}`。

### 18.3 顺带确认的板端语义

- `0x0405` 的 bit3 清不掉（写 0x00FF 后仍读 `0x0008`），但 `0x0404` 的实时位已经是 0
  ⇒ 限频器确实没在截断边沿；`0x0405` 那一位在本板上更像"电平"而不是粘滞位。
- UDP 5000/5001/5002 仍被 Vivado 的 `lkcitdl` 占着，程序绑 5003 并把 5003 写进 `0x070C`。

## 19. 网口模式「实时数据预览」不刷新（用户 m04465）

**现象**：切到「网口连续流」后，实时页顶部的「实时数据预览」卡（电角度 / 多周期位置 /
正余弦 s,c / 幅值 r / A B Z U V W 灯 / 方向·限幅 / 状态位）**一个数都不动**，
永远停在切网口之前的最后一帧。

**根因**：`_update_live()` 只有串口路径的 `_tick_body()`（`host/live_mixin.py:265`）
在调；网口路径的 `_net_tick_body()` 当初只接了转速/波形/质量/告警/记录，漏了这张卡。
—— 和 §16「首页卡住不动」是同一类错误：**把刷新挂在某一条路径的尾巴上**。

**修法**：`_net_tick_body()` 在 `self.last_frame = frames[-1]` 之后调
`self._update_live(frames[-1])`，整段包 `try/except` 并 5 s 限频记日志
（卡片是装饰性的，不许连累读数）。

**顺带修的第二个 bug**：`net_frames.FrameSynth` 里 `"amp_sq": (s*s + c*c) >> 15`。
真板发的 `amp_sq` 就是 `s²+c²` 本身（实测 s=5535 / c=24949 ⇒ `sqrt(653e6)=25555`
正好等于界面显示的幅值），所以合成帧也**不能右移 15**，否则「幅值 r」会小 181 倍
（改动前实测显示 110，真值 20000）。

**验证**：`python -X utf8 tools\_smoke_net_mode.py`（本机回环灌 6000 个 350 点包）
新增两条断言 —— 电角度必须变化、位置与 s,c 必须非空：

```
[live] — -> 323.999 ° ｜ 位置 2,745,958 ｜ s/c -11756 / 16180 ｜ r 19999
SMOKE OK
```

`net_frames.py --selftest` 全通过；离线门槛 PASS（15 模块 + 名字检查 + 317 项）。

## 20. 上板复测（网口预览 / 重连 / 可靠性）2026-11-03 下午

| 项目 | 脚本 | 结果 |
|---|---|---|
| 实时数据预览是否刷新 | `python -X utf8 tools\_e2e_live_card.py COM4` | 3 s 采 13 次：电角度/位置/s,c/r **各变 12 次**；幅值 25,891（合理区间内） |
| 连接→网口→断开→再连接 | `python -X utf8 tools\_e2e_reconnect.py COM4`（连跑 3 次） | **3×2 轮 = 60/60 条断言全过** |
| 网口可靠性 | `python -X utf8 tools\check_stream_reliability.py COM4 3` | 首次 + 重启 3 次 = **4/4**，62.3k~63.4k pkt/s，`host_known` 恒 1 |

### 20.1 这轮抓到的真 bug：6 s 超时抢在开流完成之前

`_net_start()` 原来挂 `QTimer.singleShot(6000, self._net_give_up)`，而开流流程里
`_stream_open_device()` 会先 `_host_known(tries=4)` 用 ping 唤醒 ARP（每次最多 1 s），
开流后再验 0.6 s 收包 —— 真板上一次完整开流可以到 5~6 s。**6 s 的定时器会在
`_done_stream` 回调之前把下拉框退回串口**，表现就是"点网口、日志一闪、又跳回串口"，
正是用户反复说的「总是启动不起来」。e2e 第一轮就是栽在这里（第 2 轮侥幸过了）。

修法：超时 6 s → **15 s**；`_net_give_up()` 加**代次号**（`self._net_gen`）防止上一轮的
定时器误伤本轮；且 `self.busy` 为真时（任务还在跑）再等 5 s 而不是直接放弃。

### 20.2 顺带加的静止死区

轴不转时 s,c 只剩几 LSB 噪声，抽取后 `dt` 只有几微秒，噪声被放大成几十 Hz，
界面显示 7~71 Hz 乱跳、圈数还会慢慢漂。`net_frames.STOP_HZ = 30.0`（2048 周期/转时
≈0.88 rpm），块速率低于它直接置 0，快照里多一个 `stopped` 字段。

## 21. 残差常数项 vs 转速：判定"延时"还是"偏置"（工具已就绪）

**问题**：处理链残差（板上角度字 − 同帧 `arctan2(s,c)`）是个不随角度变的常数
（36 个 10° 箱里 0.74~0.81°，σ 0.02°），但它有两种来源，修法完全不同：

| 假设 | 特征 | 修法 |
|---|---|---|
| 固定延时 τ | 残差 = 360·f·τ，随转速线性涨 | 角度补偿 `+360·f·τ`（f 取实时转速），纯上位机 |
| 固定偏置 | 残差与转速无关 | 减一个常数，纯上位机（或写板端系数） |

**Z 相帮不上**：残差是"同帧两路数据的差"，零点在相减时就消掉了。Z 真正有用的地方
是给 4096 点补偿表做机械角对齐，不是这一项。

**新工具 `tools/_residual_vs_speed.py`**（自检 14 项全过）：

```
:: 每个转速跑一次（30 s，不用停位/基准/反向）
python -X utf8 tools\_residual_vs_speed.py COM4 30 低速
python -X utf8 tools\_residual_vs_speed.py COM4 30 中速
python -X utf8 tools\_residual_vs_speed.py COM4 30 高速
:: 出对比表 + 判定
python -X utf8 tools\_residual_vs_speed.py --compare
```

每次输出：电频率、转速、残差均值（° 与 ″）、分箱常数项与 σ、τ 估计，并存
`%TEMP%\rvs_<tag>.json`。`--compare` 按转速排序，用"每点散布"（不是 R²——几次
测得几乎一样时 R² 会爆）分别拟合两个模型，给出判定与 τ。

**两个必须注意的采样陷阱（写进脚本注释与自检）**：

1. **电频率不能从 angle 求差分**：20 kHz 输入在 10 kHz 采样下只剩混叠残差。
   用 `pos_full`（32 位位置计数器）解回绕求平均，计数器不吃混叠。
2. **挑转速避开整千**：电频率正好 20000 Hz 时每帧转 720°、折回 0°，36 个箱只剩
   1 个有数（能算 τ，但"残差与角度无关"没被验证）。19500 Hz 只有 20 个箱
   （step 342°，与 360 的 gcd 是 18）。想铺满 36 箱取 19700 这类非整数倍。
   输出里的 `bins_used` 就是实际用到几个箱。

转速要拉开 2~4 倍；只差 1.x 倍时脚本会直接说"判不了"，不硬给结论。
