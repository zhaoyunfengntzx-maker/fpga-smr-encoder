# 上位机界面重构需求（R16–R20）草案

> 状态：**阶段 1 / 2 / 3 / 4 全部已完成（均 2026-10-16）**，**阶段 5（用户现场反馈落地 A–D 批）也已完成** —— 见 §13。
> 阶段 1 记录见 §9、阶段 2 见 §10、阶段 3 见 §11、阶段 4 见 §12、阶段 5 见 §13；工作包与验收见 §4。
> 用户原始诉求见 §1；已拍板的决策见 §2。
> 关联文档：`docs/12_host_ui_requirements.md`（R1–R15 全部完成；本次重构记为 **R16 / R17 / R18 / R19**，阶段 5 记为 **R20**）、`docs/DEV_STATUS.md`（§1.76–§1.89）。
> 最终交付包（阶段 5 重打 = 第十一次，2026-10-16 22:21:30）：
> `host\dist_onedir\host_app\host_app.exe` **8,040,142 B**，SHA256
> `FB03757FBBF8B98EF3F186E0C68E2E2FDEA7D2D1A05372A988B4C898A94DC841`，439 文件 / 585,307,241 B。
> （阶段 4 的第十次是 `8,021,631 B @19:39:55` / `2CBEA58C…5782C7`，与第九次内容等价、仅 PE 时间戳不同 —— 见 §12.2。）
> （★ 包名已随 `6a995e9`「全仓文件名去中文」改成 ASCII，旧的中文包目录已删）。

---

## 1. 用户诉求原文与整理（m12144）

用户原话（逐字）：

> 现在上位机软件还有很大的提升空间。主要有一下弊病：
> 1、上手难度高，界面以及操作逻辑过于繁杂，不够清晰易懂。
> 2、有一些窗口可以合并在一起展示（比如：①连接，②设备信息，③通信统计，这些可以放在一起。以此类推，
> 别的界面排布也可以重新思考思考，优化优化）
> 3、在软件设计方面，可以全面学习参考苹果公司的系统/软件设计风格和思路、解决方案。不必按照我之前提出
> 的"软件的UI设计上我希望他以简约、直观为主，主题颜色可以以淡蓝色为主。"的要求，改变为"全面学习苹果
> 公司的设计"向大师之作学习。
> 4、信息在于"精"，不在于"多"。要让使用者一眼就明白显示的是什么信息/数据，这个数据怎么样，有什么结论。
> 而不是一个界面上有很多很多信息，很乱，也很难以理解。可以分界面合理安排。
> 5、比如我输入1kHz，6VPP的正弦正交波形，由于各种原因，上位机软件上显示的输入频率一直在999Hz，
> 1000Hz，1001Hz上下来回闪动，非常不便于观察。还有很多数据也是这种情况。要将数字稳定下来，便于观察。
> 我暂时就这些想法,你帮我整理一下我的需求,如果你有不确定的地方可以问我,我们先沟通项目需求,等我确认
> 之后,再做下一步执行。

整理为五条需求：

| 编号 | 需求 | 实质 |
| --- | --- | --- |
| **R16** | 降低上手难度：按使用流程/关注点分区，每屏只回答一个问题 | 信息架构重做（不是调样式） |
| **R17** | 该合并的卡片合并（①②③ 为一例），排布重新思考 | 卡片 → 页面；11 卡 → 6 页 |
| **R18** | 全面学习 Apple 系统/软件设计（用户已撤销"淡蓝简约"约束） | 视觉语言整体替换 |
| **R19** | 信息在于"精"：一眼看出"是什么 / 好不好 / 结论" | 读数结论化 + 三级层次 |
| **R20** | 数字要稳（1 kHz 例：999/1000/1001 跳动） | 显示层稳定化 |

### 1.1 R20 的机理（已核实，不是 bug）

* 板子每 `100 µs` 一帧 ⇒ 帧率 ≈ 10 kHz；1 kHz 输入时**每帧只走 0.1 个电周期**。
* 现用 **1 s 平滑窗** ⇒ 窗内约 1000 个电周期，**计数 ±1 个周期 = ±1 Hz = ±0.1%**。
* 因此 999/1000/1001 的跳动是"**显示的位数多于测量分辨率**"：末位天然在跳。
* 同理：转速 15153.9 RPM（±15）、幅值 r 均值（±数十 LSB）、帧率 9495（±100）、圆度偏差（受分箱量化）……
* ★ 注意例外：**电角度、多周期位置、累计圈数**这类"本来就该在走"的量不做稳定化，只规范位数。

---

## 2. 已拍板的决策（用户 m12146 答复）

| 项 | 决策 |
| --- | --- |
| 改造范围 | **全做**：架构分页合并 + 读数精炼稳定 + Apple 视觉 |
| 导航形态 | **左侧窄侧栏 + 一次一页**（Apple「系统设置」式） |
| 数字稳定 | **显示层稳定化 + 悬停查看原始值**（不改测量算法、不改响应速度） |
| 诊断类信息 | **收进隐藏的「诊断」页**，主界面只留一个入口 |
| 字体/图标 | **打包 Inter（SIL OFL 1.1，可再分发）** 保证跨机一致；单色线条图标 |
| 执行顺序 | **先读数精炼稳定 → 再架构分页 → 最后 Apple 视觉** |
| 必须保留 | ① `Ctrl+滚轮` 缩放、双击恢复自动、导出当前视图；② 离线自检与真机核对脚本**必须继续全绿** |
| 卡片 `⛶` 单卡放大 | **取消**（分页后每页空间足够，`⛶` 变多余） |
| 键盘快捷键 | **保留并重新分配**（缩放 `←/→/↑/↓`、`Shift` 微调、暂停、导出等；放大态专用键随 `⛶` 一并去掉） |
| 全局「原始值」开关 | **要**：顶栏/设置里一个开关，默认稳定，一键切回实时跳动 |
| 门限/迟滞/Z 脉宽/极性 | **全放「诊断」页**（告警页只保留"看状态 + 清锁存"） |
| 最小窗口尺寸 | **≥1600×900**：一屏一页不滚动；更小尺寸允许出现滚动条 |

---

## 3. 目标信息架构（6 页 + 顶栏）

```
┌───────────────────────────────────────────────────────────────┐
│ 顶栏： [端口 COM3 ▼] [连接/断开] [设备自检]   ●已连接  ●记录中  [导出] │
├──────────┬────────────────────────────────────────────────────┤
│ 概览      │                                                    │
│ 实时      │                  当 前 页 面 内 容                   │
│ 编码器信号 │                                                    │
│ 告警      │                                                    │
│ 记录      │                                                    │
│ ──────    │                                                    │
│ 诊断      │                                                    │
└──────────┴────────────────────────────────────────────────────┘
```

| 页面 | 并入的原卡片 | 这一页回答的问题 | 主要内容 |
| --- | --- | --- | --- |
| **概览** | （新）①②③ 的结论行 | "现在整体什么状态？" | 4–6 个结论行：设备/链路、输入频率、转速、幅值判定、告警摘要、记录状态；异常项可直接点击跳到对应页 |
| **实时** | ④ 实时预览 + ⑤ 转速位置 + ⑥ 倍频 + ⑧ 波形 | "信号现在怎么样？" | 大波形为主角（时域 + 李萨如，保留示波器式交互）；旁列 4 个稳定读数（输入频率/转速/幅值 r/电角度·位置）；倍频以一行 `×256` 显示、点击展开修改 |
| **编码器信号** | ⑨ ABZ/UVW + 六状态 + 一键使能 + 方波可看 | "ABZ/UVW 输出对不对？" | 双图 + 六状态表 + 「ABZ 使能 / UVW 使能」+「方波可看 / 还原」 |
| **告警** | ⑦ 告警与故障 + 锁存 + 清除 | "有没有问题？怎么清？" | 状态/锁存双列 + 「清除锁存（写 0x0405=0xFF）」+ 历史锁存说明 |
| **记录** | ⑩ 记录与导出 | "记录进行到哪、导出在哪？" | 记录开关 + 已写字节/行数/时长 + 文件列表 + 导出按钮 |
| **诊断**（侧栏分隔线以下，低频） | ⑪ 通信日志 + 高级参数（门限/迟滞/Z 脉宽/极性）+ 设备自检 + 寄存器读值 | "出问题了，深挖" | 通信日志（分级、清空）、高级参数、`0x0404`/`0x053A`/`STAT_AMP_SQ` 原始值 |

---

## 4. 工作包与验收

### W1 读数精炼与稳定（阶段 1，✅ 已完成，见 §9）
* 落地《读数规范表》（§5）：每个读数的**量名 / 数值 / 单位 / 判定 / 分辨率 / 稳定化规则**。
* 新增共享组件 `Stable`（`host/ui_kit.py`）：**死区（绝对 + 相对）**，末位不再跳；
  鼠标悬停显示未处理的原始值与分辨力说明（如 `原始值 1000.437 Hz`＋`分辨力：1 s 平滑窗、±1 Hz`）。
* 判定用状态色仍按真实值（不放宽告警）。
* 验收：真机 1 kHz 输入下，输入频率、转速、幅值 r 的显示值**不再跳动**；
  悬停可见原始值；另有"原始值"全局开关可切换回实时跳动。
* 实施结果：17 个读数全部接线；离线 `selftest_ui.py` **159/159 PASS**（156 + ⑨补7 的 3 项）；**未做** EMA 与趋势箭头
  （死区已足够，EMA 会让"真实缓慢变化"看起来迟滞；趋势箭头并入阶段 3 视觉再评估）。
* 影响：`host/panel_*.py` 所有读数格 + 新增小部件；离线自检新增用例。

### W2 信息架构与合并（阶段 2，✅ 已完成，见 §10）
* 左侧窄侧栏 + 6 页 + 顶栏工具条；11 张卡片按 §3 归并；页面切换不重排数据管线。
* 「高级参数」从折叠区改为**诊断页**的正式区块；`设备自检` 按钮移到顶栏。
* 验收：每页"一屏一事"；离线自检迁移并全绿；真机核对脚本全绿；文档同步。
* 实施结果：外壳 = 侧栏 176 px + 顶栏 + `QStackedWidget` 六页（每页各带 `QScrollArea`）；
  默认页「概览」（新文件 `host/page_overview.py`，六行结论 + 「查看 ›」跳页）；
  顶栏 = 端口/刷新/连接/设备自检/状态灯/「原始值」；⑨ 的高级参数整块摘到诊断页并由一张卡片托底；
  **`⛶` 单卡放大取消**（按钮、`Esc`、`PgUp/PgDn`、`Ctrl+←→` 一起退场，`Ctrl+1…6` 接管翻页）；
  离线 `selftest_ui.py` **151/151 PASS**、真机 `--real-port COM3 --seconds 6` **PASS**（§10.4/§10.5）。

### W3 Apple 视觉（阶段 3，✅ 已完成，见 §11）
* 打包 Inter（OFL 1.1）：`host/assets/` + spec 的 `datas` + `QFontDatabase.addApplicationFont`（失败回落 Segoe UI Variable / Segoe UI）。
* 重写 `host/theme.py` 设计令牌（§7）；去重边框/彩色大色块；统一圆角、留白、层级。
* 验收：逐页离线截图走查（1950×1080 级）+ 真机走查；色彩/字号/间距对照表逐项打勾。

**实施结果（2026-10-16）**：Inter 四个字重 + `OFL-1.1.txt` 落 `host/assets/fonts/`，新增 `host/ui_font.py`
（注册 + 回落 + `tnum`），两份 spec 补 `datas` 进 `_internal/assets/`；`theme.py` 令牌整体重写（`#F5F5F7` 底 /
`#FFFFFF` 卡 / 单一 `#0071E3` / 字号 22·17·13·12·11·28）；开关与复选框改自绘位图（`tools/make_ui_assets.py`）；
导出图与主题同源取色；逐页走查做了**离屏 1950×1080 + 最小 1600×900 + 真实平台 150% DPI**三档；
离线 `selftest_ui.py` **164/164 PASS**、真机 **PASS**（§11.7/§11.8）。**与 §7 的两处偏差**（页标题 22 而非 28、
正文 13/次要 12 而非 15/13）理由见 §11.3。

### W4 收尾（阶段 4，✅ 已完成，见 §12）
* `docs/16`（本文）定稿、`host/README.md` 自检清单与打包节、`docs/DEV_STATUS.md` 新增章节、`docs/12` 新增 R16–R20。
* 重打交付包 + PYZ 复核（UTF-8 解 `marshal.dumps(code_obj)`）+ 回填包号与 SHA256。

**实施结果（2026-10-16）**：`docs/12` 补 **R17（阶段 2 信息架构）/ R18（阶段 3 Apple 视觉）/ R19（阶段 4 文档与交付）**
三节（R16 已记阶段 1）；`docs/13_display_ui_requirements.md` §5 补「上位机色板已在阶段 3 重写」的前向注记
（屏侧色板**不同步**，换色需单开需求）；本文补 §12 并把状态行改为四阶段完成；`host/README.md` 交付段与进度表、
`docs/DEV_STATUS.md` §1.88 回填最终包号。交付包**第十次重打**（阶段 4 未改源码，内容与第九次等价）：
8,021,631 B / SHA256 `2CBEA58C…5782C7` / 439 文件 / 585,288,730 B / PYZ 682 模块；
两道门槛复跑 **离线 164/164 PASS、真机 PASS**（界面取 60907 = 记录器 60907 行）。详见 §12。

---

## 5. 《读数规范表》（草案，待你确认细节）

| 读数 | 当前问题 | 测量分辨率 | 建议显示 | 稳定化 |
| --- | --- | --- | --- | --- |
| 输入频率 | 999/1000/1001 跳 | ±1 Hz（1 s 窗） | `1000 Hz` + 悬停 `1000.3 Hz（±1）` | 死区 ±2 Hz + 慢 EMA |
| 机械转速 | 末位跳 | ±15 RPM | `15154 RPM` | 死区 ±0.2% |
| 输入频率（高精度档） | — | 独立路径 ±0.5 Hz | 悬停第二行给出 | 不显示在主数字 |
| 幅值 r | 均值末位跳 | ±数十 LSB | `25901` + 判定`正常` | 死区 ±0.5% |
| 幅值判定 | 已是结论 | — | `正常 / 偏低 / 偏高`（状态色） | 不适用 |
| 圆度偏差 | 受分箱量化跳 | 取决于分箱 | `3.4%`（1 位小数） | 死区 + 分箱提示 |
| 电角度 | 本该在转 | 16 位 | `64.8°`（1 位小数） | **不**稳定化 |
| 多周期位置/累计圈数 | 本该在走 | 计数 | 千分位分组 | 不适用 |
| 帧率 | ±100 跳 | ±1 帧/s | `9.5k 帧/秒` | 死区 ±50 |
| 误码/校验错 | 累计计数（单调） | 1 帧 | `548 帧（0.39%）` | 不适用（累计） |
| 丢帧估计 | 百分比 | 0.01% | `0.8%` | 死区 0.1% |

> 口径提醒（沿用现有 tooltip）：**校验错 0.39%** 是串口链路逐帧 XOR 口径，不是 CRC 校验；
> **丢帧估计 0.77%** = 校验错帧 + 重同步吞掉的帧占应到帧时隙的比例。

---

## 6. 待确认

> **全部已确认（m12146 + m12155 两轮答复）**：见 §2 决策表最后六行。
> 执行前只需用户一句"开始/按这个做"即可进入阶段 1。

---

## 7. Apple 视觉设计令牌（草案）

| 类别 | 取值 |
| --- | --- |
| 字体 | Inter（OFL 1.1，打包）+ 回落 `Segoe UI Variable` / `Segoe UI`；数字右对齐固定宽度 |
| 字号阶梯 | 28 / 22 / 17 / 15 / 13 / 11 px（页标题 / 区块标题 / 卡片标题 / 正文 / 次要 / 单位） |
| 页面底色 | `#F5F5F7` |
| 卡片底色 | `#FFFFFF`，圆角 10–12 px，无重边框（1 px `#E5E5EA` 或极浅阴影） |
| 正文/次要 | `#1D1D1F` / `#6E6E73` |
| 强调色 | 单一 `#0071E3`（按钮、选中、链接） |
| 状态色 | 正常 `#34C759` / 警告 `#FF9F0A` / 故障 `#FF3B30`（**只表状态**） |
| 间距 | 8 pt 网格；卡片内边距 16–20，卡片间 12–16 |
| 控件 | 主按钮实心圆角 8；次按钮浅底；二选一用分段控件（如「稳定 / 原始」「叠加 / 分离」）；开关用滑块 |
| 动效 | 仅页切换淡入与数值更新高亮；**不做数字滚动动画**（与 R20 的"稳"冲突） |
| 禁止 | 彩色大色块、重边框、全部大写英文标题、彩虹装饰色 |

> **实施偏差（2026-10-16 阶段 3 落地时定）**：①字号阶梯实际用 **28（大读数）/ 22（页标题）/ 17（卡片标题）/
> 13（正文）/ 12（次要）/ 11（单位）** —— §7 把 28 给页标题，落地时把 28 让给读数、页标题落 22；
> 正文/次要取 13/12 而非 15/13，因为 1600×900 最小窗口下 15 px 会让「实时」页出现纵向滚动。
> ②「二选一用分段控件」未做（叠加/分离仍是下拉框），归入阶段 4 之后再议；
> ③页切换淡入动效未做（避免与 R20 的"稳"和几何契约纠缠）。详见 §11.3。

---

## 8. 风险与影响

1. `host/selftest_ui.py` 现有 **159 项**断言大量绑定旧结构/文案 ⇒ 需按阶段迁移，但保留功能判据
   （真机取帧=落盘逐帧对齐、导出尺寸、记录/导出、告警判定、一键使能 `0x0109`、方波可看 `square_pair`、
   微调档显示、读数稳定化与「原始值」开关）。**每次改版后离线全绿、真机 `--real-port COM3 --seconds 6`
   PASS 是硬门槛。**（★ 阶段 2 已按此迁移：放大态用例退场、换成分页/侧栏用例，见 §10.4，现为 **151 项**。）
2. 冻结包字体：Inter 需随包分发（`datas`），并在 `app.py` 启动时 `addApplicationFont`；失败必须静默回落。
   注意用户机器 `%TEMP%` 写入受限（历史结论），字体文件放包内目录读取。
3. 离线截图契约（如 1166×2597）与放大态版面（4a/4b）会变，需要更新验收脚本与文档中的像素数字。
4. 打包与验收成本：每阶段结束各重打一次交付包（当前 426 文件 / 583,892,596 B，构建约 90 s）。
5. 已决定**取消 `⛶` 单卡放大** ⇒ `R7-A/R8/R15` 里与"放大态版面/放大态滚轮"相关的自检与文案要同步退场
   （`ScopeNav.ZOOM_STEP`/`FINE_STEP`、`_plain_zoom`、`_sync_controls()` 的微调档显示**必须保留**，
   因为正常态也能 `Ctrl+滚轮` 微调）；`set_max_layout()` 系列代码可删，但先确认没有别处依赖。

---

## 9. 阶段 1 实施记录（2026-10-16，✅ 已完成）

### 9.1 先证伪"采集有问题"

* 板子 100 µs/帧（10 kHz），1 kHz 输入 ⇒ 每帧只走 0.1 个电周期；**1 s 平滑窗≈1000 个周期**
  ⇒ 计数 ±1 = **±1 Hz = ±0.1%**。
* 真机实测（`host/selftest_s2.py`）：`f_abs` 与 1 s 窗理论值差 **< 0.001 Hz**，噪声约 **0.004 Hz**。
* ⇒ 999/1000/1001 是"**显示的末位比测量分辨力还细**"，修在显示层，算法与协议不动；
  电角度、多周期位置、累计圈数/电周期这些"本来就该在走"的量**不做稳定化**。

### 9.2 落地的东西

* `host/ui_kit.py`：`READOUT_SPEC`（dec/dead/rel/unit/rdec/note/name/sep）+ `class Stable`
  （`update()` 返回该显示的值；`text()`/`tip()`；`_STABLES` 登记表 + `reset_all_stable()`）+
  `raw_mode()/set_raw_mode()` + `show(lab, st, raw, extra)` + `stable_fields()`。
* 例：`freq_hz` = 1 位小数、死区 2 Hz、悬停给 3 位原始值、note「1 s 平滑窗、±1 Hz」；
  `rpm` = 整数 + 千分位、死区 5 RPM/0.2%；波形卡 `amp_r/board_r/r_mean` 字段只有 76 px ⇒ **不加千分位**。
* 六个面板都加 `refresh_readouts()`，主窗口底部状态条加 **「原始值」复选框**（默认关，写
  `ui_prefs.json` 的 `display.raw`，切换即全局切口径并重画）。

### 9.3 验收集

* `python -m compileall -q host` exit 0。
* `QT_QPA_PLATFORM=offscreen python host\selftest_ui.py` ⇒ **通过 159 项、失败 0 项**
  （新增 ⑨补6 的 10 项 + ⑨补7 的 3 项；改前 144 通过 / 2 假失败）。
* 新增 ⑨补6 断言：±1 Hz 抖动按住、超死区即更新、转速相对死区 + 千分位、`tip()` 含原始值/分辨力、
  raw 模式直通、复选框初值与参数文件一致、勾选即重画。
* 新增 ⑨补7 断言（默认窗口与卡片⑧ 控制行，见 §9.5）：默认宽 ≥1600、默认宽度下卡片⑧ ≥ 控制栅格、
  小屏不做夹取。
* 真机核对（`--real-port COM3 --seconds 6`）：**PASS（2026-10-16）**。过程：板子先不枚举（串口数 0）
  → 重插后仍 0 字节 ⇒ 判定 FPGA 没在跑 → 用户说"帮我烧录" ⇒ 新写 `tools/program_enc.tcl`，
  先撞上 3121 端口的宿留 hw_server（cs_server 报 `Failed to extract VCRUNTIME140.dll: fopen: Permission denied`），
  提权杀掉那几个 PID 后烧 `_synth_work\enc_top.bit` 成功（`End of startup status: HIGH` / `PROGRAMMED_OK`）。
  真机全绿项（**2026-10-16 18:44 改完窗口默认值后复跑**）：一键使能 UVW（`0x0040 → 0x00C0 → 0x0040`）、
  六状态 `合法 24859 / 非法 0`、`0x0101/0x0102` 窗口自检读值与直读一致、`方波可看`（`256→1024` 箱 / `256→64` inter）
  与逐字节「还原」、取帧→落盘 `界面取 60934 帧 = 记录器写 60934 行（差 0）`、`文件行数 108738 = rows 108738`、
  链路解析 117650 帧、丢帧 894、关窗队列 1 → 0 条。
* 交付包：**第七次重打（2026-10-16 18:47:35）**`host\dist_onedir\host_app\host_app.exe`
  **8,012,765 B**、SHA256 `7CCFAB7EAE1D62A4B7C0A020BECB14DFD022DFD385E7971DD36549CA1C9BE63F`、
  426 文件 / 583,892,904 B（第六次是同日 18:35 的 8,012,457 B / `FE233A4E…C123` / 583,892,596 B，
  两者差的就是 §9.5 的默认窗口改动）；PYZ 复核（680 模块）确认
  `READOUT_SPEC`/`set_raw_mode`/`原始值`/`分辨力`/各面板稳定器字段名、以及 §9.5 的
  `DEFAULT_WINDOW_W`/`MIN_WINDOW_W`/整型 1600/`availableGeometry` 都在包内。
  （★ 包名已随 `6a995e9` 改成 ASCII，旧中文包目录已删。）

### 9.4 顺手修掉的两条**陈旧断言**（自检自己的问题，不是功能 bug）

* ⑰「导出当前视图」原断言文件名含中文**「当前视图」**，而自 `6a995e9`（2026-10-15「全仓文件名去中文」）
  起文件名是纯 ASCII `encoder_wave_view_*.png`（竞赛要求；`host/export_png.py:421-435` 有明文）
  ⇒ 这两条自那天起一直**假失败**（`export_png.py --selftest` 一直通过，可交叉验证）。
* 现改为断言 ASCII 名里的 `_view` 段，并在注释里写明来龙去脉。

### 9.5 顺手修掉的版面缺陷：默认窗口宽度下卡片⑧ 控制行被裁

* **发现方式**：给第六次交付包做冒烟（`host\dist_onedir\host_app\host_app.exe --smoke … --seconds 4`），
  看截图时发现卡片⑧ 最右按钮只显示"出当前视"、时基组合框显示"自动（"——**默认窗口宽度下被右缘裁掉**。
* **量化**：`host/panel_wave.py` 控制栅格（5 组横排）`sizeHint ≈ 665 px`，卡片响应式多列
  （⑦⑧ 共用一行 ⇒ 约半屏宽）：窗口 1180 ⇒ 控制区 645（差 20 px，正是被裁的量）、1440 ⇒ 801、
  1600 ⇒ 897、1920 ⇒ 1089。
* **修法**：`host/ui_prefs.py:21-24` 默认窗口 **1180×… → 1600×900**（与 R16 的"最小 1600×900"一致）；
  `host/main_window.py:315-328` 开窗按主屏可用区夹取，且**只在屏幕装得下最小窗口时才夹**
  （离屏平台报 800×800，否则会把自检窗口压变形）。响应式回流（窄卡片自动竖排）**归入 W2/阶段 2**。
* **自检自身的坑**：量版面必须**新开一个 `MainWindow`**——自检里反复 resize 过的 `w` 卡片列数已定格，
  量到的是陈旧值 607 px（误报）；且要 `QTest.qWait(60~80)` 等布局跑完，`processEvents()` 一次不够。

---

## 10. 阶段 2 实施记录（2026-10-16，✅ 已完成）

### 10.1 一句话结论

「卡片墙」换成了**左侧窄侧栏 + 顶栏 + 六页**：一页一件事、默认先给结论（概览）；`⛶` 单卡放大
连同它的专用键一起退场，`Ctrl+1…6` 接管翻页；⑨ 的「高级参数」整块搬进诊断页；
**离线 151/151 全绿 + 真机核对 PASS**，交付包按最终源码重打（见 §10.7）。

### 10.2 外壳怎么搭的（为什么这样搭）

* **布局**：`QHBoxLayout[ uk.Sidebar(176 px) + QVBoxLayout[ 顶栏 + QStackedWidget(六页) ] ]`，
  每页自带 `QScrollArea`（`self._scrolls` 键 = 页 key），窗口最小 1600×900 不变。
* **关键手法：控件原地创建、最后 `addWidget` 搬进页面**（Qt 自动改父）⇒ 六个面板文件几乎没动，
  只有 ⑨ 卡上的高级参数块需要"跨页搬家"（见 10.3）。
* **顶栏只放"工具与全局开关"**：端口下拉 / 刷新端口 / 连接 / 设备自检 / 状态灯 /「原始值」复选框。
  理由：连接不是"内容"，以前占一整张卡片；「原始值」是全局开关，放顶栏比塞进状态栏更符合
  `m12146` 的"原始值开关放顶栏或设置"。
* **默认页「概览」**：用户诉求是"一眼看现在正不正常"，所以先给结论再给细节。概览页
  （新文件 `host/page_overview.py`）六行 = 设备与链路 / 输入频率 / 机械转速 / 信号幅值 / 告警 / 记录，
  每行「当前结论 + 一句判读 + 查看 ›」；`ROWS` 是那张表的唯一真源（自检按它核对）。
  数据来源：`host/main_window.py::_refresh_overview()` 读 ② 设备卡、③ 链路卡、⑤ 转速卡、
  ⑧ 波形卡的稳定读数与 `AlarmPanel.summary()`；`_update_speed()`/`_reset_live()` 各调一次。
* **`self.scroll` 语义改成"当前页的滚动区"**：老自检里到处是 `w.scroll.verticalScrollBar()`，
  这样改把迁移量压到最小（只有日志那一段要先 `show_page("diag")`）。
* **方向键跟当前页走**：`_kbd_panel()` = 「编码器信号」页给 `self.abz`、其余页给 `self.wave`；
  `Ctrl+1…6` 在 `_setup_keys()` 里绑 `page_changed` 等价物（`PgUp/PgDn`、`Ctrl+←/→` 删除）。

### 10.3 「高级参数」搬家与告警摘要

* `host/panel_interp.py` 新增 `adv_page_requested = Signal()` 与 `take_adv_box()`：把 `box_adv`
  从 ⑥ 卡里摘出来交给诊断页，卡上按钮文案改「高级参数 ▸（在「诊断」页）」并在点击时**跳页**
  （`set_connected()` 若已 detached 就保留这套文案，不再试图展开）。
* `host/main_window.py::_page_diag()` 用 `uk.make_card("⑨ 高级参数（门限 / 迟滞 / 限频 / Z 脉宽 / 极性）")`
  把摘下来的块**托底包一层卡片**（`self.adv_card`）——否则它在诊断页上像"掉在地上的控件"（目视抓到）。
* `host/panel_alarm.py` 新增 `level(key)`（`ok/warn/fault/info`）与 `summary()`（挑最严重项），
  供概览页把 14 行告警压成一句话。★ `_state` 只在 `_refresh()` 里赋值 ⇒ 两个新方法都用
  `(getattr(self, "_state", None) or {}).get(...)`，**别写成 `self._state`**（自检第一次跑就
  `AttributeError: 'AlarmPanel' object has no attribute '_state'`）。

### 10.4 自检迁移（`host/selftest_ui.py`）与离线验收

* 改动点：⑨补7 量卡片⑧ 前补 `show_page("live")`；⑬ 开头 `show_page("live")`、日志滚轮段改
  `show_page("diag")` 后重取滚动条；**⑭ 整段从"卡片放大"换成"左侧侧栏与六页"**（六页签与
  `uk.PAGES` 一致、`pages.count()==6`、`_scrolls` 键一致、默认 `overview`、逐页切后
  `currentIndex/_page_key_now/scroll is _scrolls[key]/侧栏高亮`、`Ctrl+1…6` 在 `_kbd_keys` 且旧键已无、
  `Ctrl+4` 真跳告警页、11 张卡无一带 `CardMax`、概览六行键与 `ovp.ROWS` 一致且 ≥4 行有值、
  「查看 ›」真跳页、`diag.isAncestorOf(w.interp.box_adv)` 且可见、`adv_card` 存在且有卡标题、
  诊断页含 `w.log`/`w.card_device`/`w.card_link`、点 `btn_adv` 跳诊断页、`topbar.isAncestorOf(chk_raw)`）；
  ⑱ 删掉 4 条放大态专用项、换成普通态等价契约（裸滚轮滚页面且量程不变、`Ctrl+滚轮` 横轴 ×0.75~0.85）+ `F` 全屏；
  ⑲ 换成"版面只剩一种"3 项。
* 迁移中踩的坑（都已修）：①`AlarmPanel._state`（见 10.3）；②`_save_prefs()` 里残留
  `if self._max_card is not None: self._restore_card_max()` ⇒ 异常被 `except Exception` 吞掉、
  `up.save()` 从没执行 ⇒ ⑯ 参数记忆 4 项失败（`wave.x_span_ms=None window=None`）；③自检顶部
  漏 import `QPushButton`（`NameError`）；④测 `F` 全屏前焦点留在数字框 ⇒ `focusChanged` 把快捷键
  全让给输入框，要先 `w.wave.canvas.setFocus()`；⑤中文引号写进 Python 双引号字符串 ⇒ `SyntaxError`，
  文案改用「」。
* **结果**：`python -m compileall -q host` exit 0；离屏 `selftest_ui.py` ⇒ **通过 151 项、失败 0 项**
  （阶段 1 是 159：退场的是放大态用例，新增的是分页/侧栏用例）。

### 10.5 真机核对（`--real-port COM3 --seconds 6`，2026-10-16）

**PASS**（★ 终跑在**死代码清理之后**，即进包的这份源码）：一键使能 UVW 读-改-写
`0x0109 = 0x0040 → 0x00C0 → 0x0040`；六状态 合法 **20375** / 非法 0；
「方波可看」分箱 256→1024 / inter 256→64 且逐字节还原（`0x0101/0x0102 = 0x0000 0x0000` 原样）；
界面取帧 **60659** = 记录器 60659 行（差 0）；文件行数 **103857** = rows 103857；丢帧 **913**；关窗队列丢弃 0（CSV 16.4 MB）。
（清理前那一跑是 合法 20156 / 非法 1、60792 行、104154、丢帧 816 —— 两跑都 PASS，差异只是板子的自由运行节拍。）

### 10.6 逐页目视走查与两处修正

* 取证脚本（临时）`host/_shot_pages.py` 逐页 offscreen 截图（1600×900）⇒ 外壳成立、六页内容各归其位；
  告警页只留"看状态 + 清锁存"，留白多是**设计使然**（门限/迟滞等全在诊断页）。
* ★ 当时记的"离屏渲染是灰度近似 ⇒ 不能用离屏截图判配色"**已被阶段 3 证伪**（见 §11.6）：离屏平台其实
  保留颜色，那时看着灰是因为**当时那套令牌本身就是灰蓝的**。配色走查仍建议**离屏 + 真实平台各做一遍**。
* **修正 1（真缺陷）**：`host/ui_kit.py::fix_lines()` 原来 `setFixedHeight(fm.lineSpacing()*lines+2)`，
  在 1600 宽下把卡片⑤ 提示的末行「依据。」切掉一半 ⇒ 改 `setMinimumHeight(ls*lines+2)` +
  `setMaximumHeight(ls*(lines+1)+2)`，并加注释"别再改回 `setFixedHeight`"。
* **修正 2**：诊断页的高级参数块补一张托底卡片（见 10.3）。

### 10.7 交付包

* 正式交付 = 目录版 `host\dist_onedir\host_app\host_app.exe`；命令见 `host/README.md` 的
  "打成目录版"一节（`python -m PyInstaller --noconfirm --clean --workpath host\_exe_work_onedir
  --distpath host\dist_onedir host\host_onedir.spec`）。
* 本次重打（第八次，**两遍**）：`host_app.exe` **8,014,886 B @2026-10-16 19:10:22**、SHA256
  `C6E8F28081CE82CEDFDB05E142A2FD2DC93E4F785B6BFB2CBF0DC48ED9FA2562`、目录 426 文件 / 583,895,025 B
  （见 `host/README.md` 最新一节）；沙箱内 `--smoke` 烟测退出码 0。
  PYZ 复核（**681 模块**，比第七次多 `page_overview`）要查的新标志串：`Sidebar`/`PAGES`/`page_header`/`NavItem`/
  `PageTitle`/`OverviewPage`/`jump_requested`/`_refresh_overview`/`show_page`/`take_adv_box`/`adv_page_requested`/
  `adv_card`/`summary`/`adv_card`/整型 1600；
* ★ **为什么打了两遍**：第一遍打完做**反向核对**（查退场串还在不在包里），抓到六处"删了功能没删代码"的残留 ⇒
  删净后重打才有上面这个包。抓到的是：① `host/theme.py` 的 `QToolButton#CardMax` 三段 QSS；
  ② `host/ui_kit.py::ScopeNav.set_plain_wheel_zoom()` + `_plain_zoom`/`FINE_STEP`/`TIP_MAX` + `eventFilter` 裸滚轮缩放分支；
  ③ `host/ui_kit.py::field()` 的 `v._row_lay`；④ `host/panel_wave.py`/`host/panel_abz.py` 的 `_fill_ctrl(vertical)`
  竖排分支 + `_reflow_readouts()` + `READOUT_CELLS`；⑤ `host/main_window.py` 的 `_cycle_card_max`/`_card_canvases`/
  `_toggle_card_max` 空壳；⑥ 全屏提示里"Esc 只负责还原卡片放大"的过期文案。
  退场串反向清单（应全 PYZ 无命中）：`CardMax`/`install_maximize`/`MAX_BTN_ON`/`_enter_card_max`/`_restore_card_max`/
  `_setup_card_maximize`/`set_max_layout`/`SIDE_MAX_W`/`maxHide` ⇒ **九个全无命中**。
  清理后离线仍 **151/151**、真机仍 PASS。
* **方法论**：正向查"新东西进没进包"很容易全绿；**逆向查"删掉的东西还在不在"才抓得到死代码** ——
  模块级常量、QSS 段、没人调的方法在离线自检里都是绿的。

### 10.8 留给阶段 3 的东西

* 配色/字号/间距/圆角全部照 §7 令牌重写（`host/theme.py`），打包 Inter + 回落；
  侧栏/顶栏/页标题/概览六行是这次新增的界面元素，**它们的视觉是"朴素可用"而不是"Apple"**。
* 概览页留白较多（一屏六行）、告警页留白多 ⇒ 阶段 3 用版心/分组线/留白节奏处理，不改信息架构。
* 响应式回流（窄卡片自动竖排，§9.5 尾注）在本阶段只做到"每页一屏一事 + 页面级滚动"，
  再窄的窗口仍靠滚动条，**最小窗口 1600×900 不变**。

---

## 11. 阶段 3 实施记录（2026-10-16，✅ 已完成）

### 11.1 一句话结论

Apple 视觉落地：Inter（OFL 1.1）随包成为全局界面字体、`host/theme.py` 令牌按 §7 整体重写、开关/复选框改
自绘位图、读数改用 `tnum` 表格数字、导出图与主题同源取色。信息架构（阶段 2 的六页/侧栏/顶栏）**一个字节没动**；
离线 `selftest_ui.py` **164/164 PASS**、真机 **PASS**；第九次交付包 **8,021,631 B / 439 文件**。

### 11.2 字体：Inter 从哪来、怎么进包、怎么回落

* **本机没有 Inter**（`C:\Windows\Fonts` 只有 Segoe UI 经典版、全盘无 `Inter*.ttf/otf`），且
  `github.com`/`raw.githubusercontent.com`/`fonts.google.com`/`cdn.jsdelivr.net` 在本机**证书校验全失败**，
  只有 `pypi.org`/`registry.npmmirror.com`/`unpkg.com` 通 ⇒ 走 npm 包 `@expo-google-fonts/inter@0.4.2`
  （`license: MIT AND OFL-1.1`）取四个字重静态 TTF：
  `host/assets/fonts/Inter-{Regular,Medium,SemiBold,Bold}.ttf`（342,408 / 342,892 / 343,632 / 344,072 B）
  + `OFL-1.1.txt`（4,377 B）。
* 新增 `host/ui_font.py`：`apply()` 用 `QFontDatabase.addApplicationFont` 注册并 `QFont.setFamilies` +
  `setPixelSize(13)`，返回注册文件数（0 = 回落）；`is_loaded()`；`use_tabular()`/`apply_tabular()` 负责 `tnum`。
  回落链 `Inter → Segoe UI Variable → Segoe UI → Microsoft YaHei UI → Microsoft YaHei`（中文逐字回落，Inter 无 CJK）。
* `host/app.py` 建窗前 `uf.apply(app)` 并写启动日志；`host/main_window.py::__init__` 里再 `uf.apply()` +
  `apply_tabular(self)`。运行时只读**包内**文件（用户机器 `%TEMP%` 写不进去）。

### 11.3 令牌重写与两处偏差

* `host/theme.py` 202 → 约 300 行：`bg #F5F5F7` / `card #FFFFFF`（圆角 12 + 1 px `#E5E5EA` 细边）/
  单一强调 `#0071E3` / 文字 `#1D1D1F`·`#6E6E73` / 状态 `#34C759`·`#FF9F0A`·`#FF3B30`；字号阶梯
  **22 页标题 / 17 卡片标题 / 13 正文 / 12 次要 / 11 单位 / 28 大读数**；顶栏白底 + 细下边线、侧栏灰底 +
  右分隔、导航项圆角 8（选中蓝底白字）、主按钮实心圆角 8、危险操作描边、"查看 ›"用链接式 `Ghost`、
  输入控件圆角 8、细滚动条、日志白底圆角 10 + 等宽。文档/协议面板显示层**未改语义**（`level_color()` 等调用方零改动）。
* ★ **与 §7 的两处偏差**（文件头已注明）：① §7 把 28 给页标题，这里 **28 让给 `BigValue` 读数、页标题落 22**；
  ② 正文/次要取 **13/12** 而非 §7 的 15/13 —— 1600×900 最小窗口下 15 px 会让「实时」页出现纵向滚动。

### 11.4 位图开关与 tnum

* `tools/make_ui_assets.py`（新增，永久）：PIL 4× 超采样画 `chk_off/chk_on/sw_off/sw_on` 与 `@2x`
  （18×18 / 36×36、36×20 / 72×40）。★ 首版缩放时又乘了 factor ⇒ 打出 72×72 的错误 "@2x"，现在只除超采样倍数。
  QSS 用 `QCheckBox::indicator`（18×18）与 `QCheckBox[switch="true"]::indicator`（36×20）；
  使用者 = 顶栏「原始值」、⑧/⑨「暂停刷新」、⑩「连上就自动记录」。
* `tnum`：读数不再靠等宽字体。两个坑 —— ①概览页六行读数是**裸造 `QLabel`**，得单独补 `use_tabular()`；
  ②`panel_abz` 六状态表用 `setStyleSheet("color:…")` 上色时**会重置 `setFont()` 的 font feature** ⇒
  新增 `_set_val_color()`（先上色、后开 tnum）。修完 47/47 个 `mono="true"` 标签都是 Inter + tnum。
* 同源取色：`export_png.py` 删掉自抄色值表改 `import theme as th`；`panel_wave.py`/`export_png.py` 里写死的
  坐标区底色 `#FBFDFF` 改成 `C["card"]`。

### 11.5 走查：三档取证 + 真机抓到的缺陷

* 离屏 **1950×1080** 六页与六页内容、**最小 1600×900** 六页内容（均无需横向滚动）；
  **真实平台**（`windows` 插件，本机 **150% DPI** ⇒ 1600×900 逻辑抓成 **2400×1350**）六页整窗。
* ★ 真机走查抓到：可编辑下拉框文本溢出时**光标停在末尾**，显示成「OM3 — …」的假象 ⇒
  `refresh_ports()` 末尾 `_le.setCursorPosition(0)`，并把端口框最小宽度 `240 → 344`
  （够放「COM3 — USB-SERIAL CH340 (COM3) ★」，裁剪图复查确认完整）。
* 结论：六页在 1950×1080 与 1600×900 下都不裁字；侧栏 `#F5F5F7`、顶栏 `#FFFFFF` 与设计令牌一致。

### 11.6 ⑳ 节，以及"离屏能不能验配色"的更正

* 新增 `_find_color(pm, hexs, tol=2, step=3, box=None)` 与 **⑳ 节 13 项**：Inter 已注册、字体与 OFL 在包内、
  全局族以 Inter 打头且 13 px、47 个 mono 标签 Inter+tnum、令牌值、`ep.C is th.C`、四条位图、四个 `switch` 属性、
  **抓图读像素**验 `#F5F5F7`/`#FFFFFF`/`#0071E3`、字号 22/17/28、顶栏贴边。
* ★ 首轮四项失败的真根因：自检**从未给 `QApplication` 套样式表、也从未 `show()` 窗口**
  ⇒ 改为 `offline_main()`/`real_port_check()` 都先 `app.setStyleSheet(th.app_qss())`，⑳ 节自己 `w.show()` 后抓整窗。
* ★ **更正 §10.6**：离屏平台**保留颜色**（实测 bg `(245,245,247)`、card `(255,255,255)`、accent `(0,113,227)`）；
  当时看着灰是**令牌本身就灰**。§10.6 的"不能用离屏截图判配色"**作废**（该节已就地更正）。
* ⑯ 两项窗口尺寸断言从 1000×700 改成 1200×760（端口框加宽后排版下限抬到 ~1024）。

### 11.7 离线验收

* `python -m compileall -q host` exit 0。
* `python host\selftest_ui.py`（offscreen，带样式表）⇒ **通过 164 项、失败 0 项**、exit 0
  （151 → 164：新增 ⑳ 13 项；⑯ 两项只改尺寸参数），日志 `host\_ui_s3.txt`。

### 11.8 真机核对（`--real-port COM3 --seconds 6`）

* 一键使能 UVW `0x0109 = 0x0040 → 0x00C0 → 0x0040`（同字节其它位不变）；
  「方波可看 / 还原」分箱 `256 → 1024`、`inter 256 → 64`，`0x0101/0x0102` 原样复原；
  **界面取 60879 帧 = 记录器 60879 行（差 0）**、文件行数 100694 = rows 100694、链路解析 109877 帧、
  丢帧 780、关窗队列丢弃 0 ⇒ **PASS**（exit 0），日志 `host\_ui_s3_real.txt`。

### 11.9 交付包（第九次重打）

* `host\dist_onedir\host_app\host_app.exe` **8,021,631 B @2026-10-16 19:25:53**、SHA256
  `CDEAB910BB4617D893372E6AE3CE94F2BCB0E2B82DA5F8DE5AA8A7C0004C89C7`、**439 文件 / 585,288,730 B**
  （426 → 439 = 4 TTF + `OFL-1.1.txt` + 8 PNG）。
* 资源实测在包：`_internal/assets/fonts/`（4 TTF + OFL）、`_internal/assets/img/`（8 PNG）。
* PYZ 复核 **682 模块**（第八次 681，多 `ui_font`）：正向 `FONT_FILES`/`apply_tabular`/`use_tabular`/`tnum`/
  `addApplicationFont`/`FONT_FAMILIES`/`chk_on`/`sw_on`/`_tabular_labels`/`OverviewPage`/`Sidebar`/`show_page`/
  `take_adv_box`/`_set_val_color` 全命中（`theme` 的 `assets/img` 因是 `os.path.join` 拼的不是字面串 → 不算缺陷）；
  逆向九串（`CardMax`/`install_maximize`/`_setup_card_maximize`/`_enter_card_max`/`_restore_card_max`/
  `set_max_layout`/`SIDE_MAX_W`/`MAX_BTN_ON`/`maxHide`）仍**全无命中**。
* 包内烟测 `host_app.exe --smoke …` exit 0；运行日志写明「界面字体：Inter 已装载（4 个文件）」
  ⇒ **字体确实从包内装载**。

### 11.10 留给阶段 4

* 文档同步（`host/README.md` 已随本阶段更新、`docs/DEV_STATUS.md` §1.87、`docs/12`、`docs/13`）+ 交付包定稿与包号回填。
* 视觉上仍"朴素但不丑"的：概览页/告警页留白偏多；响应式回流（窄窗口自动竖排）未做，最小窗口 1600×900 不变。

---

## 12. 阶段 4 实施记录（2026-10-16，✅ 已完成）

### 12.1 一句话结论

四阶段收尾：需求文档补齐（`docs/12` 的 R17/R18/R19、`docs/13` §5 前向注记）、本文定稿、`host/README.md` 与
`docs/DEV_STATUS.md` 回填**最终交付包**；阶段 4 **没有改任何源码**，交付包用"源码冻结后重打"的第十次构建，
两道硬门槛复跑全绿（离线 **164/164**、真机 **PASS**）。

### 12.2 为什么"没改代码"也要重打一遍（以及为什么 SHA256 会变）

* 交付包的判据是"**由最终源码构建**"，不是"最后一次构建"。阶段 3 的第九次包（19:25:53）之后，
  源码只被 `docs/` 改动，但为了让"交付包号"与"四阶段完成"的文档同一天落定，仍重打了一遍（第十次，19:39:55）。
* ★ **两次构建的内容完全等价**：exe 都是 **8,021,631 B**、目录都是 **439 文件 / 585,288,730 B**、
  资源也是同一批 13 个文件；**只有 SHA256 变了**（`CDEAB910…4C89C7` → `2CBEA58C…5782C7`）——
  PE 头里的构建时间戳不同。所以"包号"必须绑定 **大小 + 文件数 + 时间戳 + 哈希**一起说，
  不能只拿哈希当"内容等价"的唯一判据。

### 12.3 最终交付包（第十次重打）

| 项 | 值 |
| --- | --- |
| 可执行文件 | `host\dist_onedir\host_app\host_app.exe` |
| 大小 / 时间 | **8,021,631 B** / **2026-10-16 19:39:55** |
| SHA256 | `2CBEA58C940C62E5BDB5F56469BD65A98805023B64B2BFB04D6FC2C6975782C7` |
| 目录 | **439 文件 / 585,288,730 B** |
| PYZ | **682 模块**（第八次 681，多 `ui_font`） |
| 包内资源 | `_internal/assets/fonts/`：4 个 `Inter-*.ttf` + `OFL-1.1.txt`；`_internal/assets/img/`：8 张 PNG（含 4 张 `@2x`） |
| 烟测 | `host_app.exe --smoke … --seconds 4` ⇒ exit 0、`截图成功：…1413x824`；运行日志：冻结 `True`、解包目录 `_internal`、**「界面字体：Inter 已装载（4 个文件）」**、已建窗 4.3 s |

PYZ 复核（正向）：`ui_font` 的 `FONT_FILES`/`apply_tabular`/`use_tabular`/`tnum`/`addApplicationFont`、
`theme` 的 `FONT_FAMILIES`/`IMG`/`app_qss`/`_bundle_dir`/`assets`、`main_window` 的 `_tabular_labels`/`show_page`/
`_refresh_overview`/`adv_card`、`page_overview` 的 `OverviewPage`/`jump_requested`/`ROWS`、`panel_interp` 的
`take_adv_box`/`adv_page_requested`、`panel_alarm` 的 `summary`/`level`、`panel_abz` 的 `_set_val_color`、
`ui_kit` 的 `Sidebar`/`page_header`/`SIDEBAR_W`、`ui_prefs` 的 `DEFAULT_WINDOW_W`/`MIN_WINDOW_W` **全部命中**，
`ui_prefs` 内含整型常量 1600。**反向**九串（`CardMax`/`install_maximize`/`_setup_card_maximize`/`_enter_card_max`/
`_restore_card_max`/`set_max_layout`/`SIDE_MAX_W`/`MAX_BTN_ON`/`maxHide`）**全无命中**。

### 12.4 阶段 4 的两道硬门槛（复跑）

* `python -m compileall -q host` exit 0；离屏 `python host\selftest_ui.py` ⇒ **通过 164 项、失败 0 项**（exit 0）。
* `python host\selftest_ui.py --real-port COM3 --seconds 6` ⇒ **真机核对 通过 (PASS)**（exit 0）：
  「方波可看 / 还原」分箱 256→1024、`inter` 256→64 且 `0x0101/0x0102` 原样复原；
  **界面取 60907 帧 = 记录器 60907 行（差 0）**、文件行数 112180 = rows 112180、链路解析 121749 帧、
  丢帧 944、关窗队列丢弃 0。

### 12.5 文档落点（阶段 4 改了什么）

| 文件 | 改动 |
| --- | --- |
| `docs/12_host_ui_requirements.md` | 新增 **R17**（阶段 2 信息架构：六条需求 + `fix_lines` 顺手修）、**R18**（阶段 3 视觉：五条需求 + "离屏能验色"更正）、**R19**（阶段 4 文档与交付）；R16 节末的"真机核对待补跑"改成已通过 |
| `docs/13_display_ui_requirements.md` | §5 补**前向注记**：上表色板是"上位机阶段 3 之前"的；屏侧**暂不同步** Apple 令牌，换色需单开需求（避免污染两条验证链） |
| `docs/16_host_ui_refactor_R16_R20.md`（本文） | 状态行改"四阶段全部完成 + 最终包号"；§4 的 W4 标 ✅ 并补实施结果；新增 §12 |
| `docs/DEV_STATUS.md` | 新增 **§1.88**（四阶段收尾：包、门槛复跑、文档落点） |
| `host/README.md` | 交付段（第九次 → **第十次**：大小/时间/SHA256/文件数/PYZ/资源/烟测）、进度表新增「重构·阶段 4」行 |
| `docs/ai-collaboration-log.md` | 新增记录 67（"重打同一源码，哈希为什么会变" + "窗口化 GUI 进程的退出码陷阱"） |

### 12.6 遗留与明确不做

* **不做**：响应式回流（窄窗口自动竖排）、卡片放大（`⛶`，阶段 2 已取消）、LCD 屏色板与字体跟随上位机（需单开需求）。
* **留白**：概览页与告警页留白偏多；`docs/*.pdf` 仍是 2026-10-15 的旧快照（本次只改 `.md`，未重新出版 PDF）。


## 13. 阶段 5 实施记录：现场反馈落地（2026-10-16，✅ 已完成）

> 来源：用户接上板子实际用了一轮后提的 14 条意见（**m15713**，附 7 张实机截图）；我先按代码定位整理成需求确认书（含 RTL 侦察、物理约束、A/B/C 三选一），用户回 **「C，按此执行」**（**m15804**）后开工。
> 分 **A（小改）/ B（字号自适应）/ C（波形）/ D（记录健壮性 + 方波判决）** 四批，每批都过两道硬门槛。需求表见 `docs/12_host_ui_requirements.md` 的 **R20**。

### 13.1 一句话

A 批把 6 类"看着别扭"的小毛病和 1 个真 bug（概览永远"型号未知"）修掉；B 批让整界面（含字号、侧栏宽、提示行高、matplotlib 字号）**随窗口等比自适应**并留手动覆盖；C 批给波形加**触发**（插值过零 ⇒ 相对静止）与**独立大窗口**；D 批把记录失败的根因变成"程序自己探测 + 自动改存 + 人话解释"，并把编码器页的"平均出来的阶梯"换成**实测 0/1 硬判决方波 + 相位对齐理论方波**双线。

### 13.2 A 批：小改（含 1 个真 bug）

* **R20-1 真 bug**：`main_window` 的 `"0x0C" in dev.upper()` —— `upper()` 把 `0x0c` 变成 `0X0C`，模式永远不匹配 ⇒ 概览永远走"型号未知"分支。新增 `dev_id_ok(text)`：先 `int(text, 16) == lk.EXPECT_DEVICE_ID`，退化到大小写无关的 `"0x0c" in text`。
* 卡片标题去掉 ①②③ 编号：`main_window` 5 处（通信日志 / 高级参数 / 设备信息 / 通信统计 / 实时数据预览）+ 6 个 panel 各 1 处；概览页删掉「现在怎么样」标题。
* 小数位：累计圈数 / 电周期数 → `%.1f`（圈数带"圈"），等效倍率 → `×%.0f（inter N ÷ div M）`；波形刷新读数去掉「（画图 0.7 ms）」（耗时移进 tooltip）。
* 编码器页默认分箱 `abz.BINS_DEFAULT = 1024`；删掉「采样不足：A/B 波形不可信，只看 Z 与读数」这条判定（原来会把标题改掉、把 A/B 两条线降透明度到 0.30）—— 改成卡片顶部的**可执行建议**。

### 13.3 B 批：字号随窗口自适应

* `theme.app_qss(scale=1.0)`：整段 QSS 保留为基准，非 1.0 时用一条正则 `(\d+(?:\.\d+)?)px` 统一缩放全部 **77 处** px（字号 / padding / 圆角 / min-width），最小改动、风险最低。
* `ui_font`：`auto_scale(w, h) = clamp(min(w/1600, h/900), 1.0, 1.6)`（1600×900 = 1.0，上限 1.6×）；`apply(app, px=…)` 同时改全局默认字号；`pt(base)` 给 matplotlib 用。
* `main_window._apply_scale(scale, force=False)`：0.02 阈值去抖，顺序 = 设缩放 → 重套样式表 → 重设应用字体 → 侧栏宽 `SIDEBAR_W*scale` → `uk.refresh_fixed_lines()` 重算 `fix_lines` 的高度 → 重开 tnum；`resizeEvent` 用 0ms 单发定时器延后调用（避免重入）；`Ctrl+=` / `Ctrl+-` / `Ctrl+0` 手动覆盖并存进 `ui_prefs`（0 = 自动）。
* ★ **这一步暴露的全局性缺陷**：样式表和字体是**应用级**的，而 `_apply_scale` 起初只修自己这个窗口 ⇒ 自检里"为量默认版面"新建的第二个 `MainWindow` 会重套样式表、把先建好的那个窗口里读数标签的 tnum 全部重置（实测 47 个里 46 个还在）。修法：`_apply_scale` 末尾遍历 `app.topLevelWidgets()` 里**所有** `MainWindow` 逐个刷新。**教训：全局副作用要全局收口。**

### 13.4 C 批：波形触发静止 + 独立大窗口

* `WaveBuffer` 扩出 `z` 列（`io_bits["z"]`），触发源四档：`s_n` 过零 / `c_n` 过零 / Z 索引升沿 / 自由。
* `_find_trigger()` 从最新往回找过零点，并对 `s/c` 做过零**线性插值**得到分数时刻 —— 这是"像真示波器一样站得住"的关键：只取最近样本的话 0.1 ms 栅格会让相位每次跳 ±半格 ≈ 36°。触发点钉在画幅 **25%**（右侧留 25% 画幅看后续），横轴改标注相对触发点、标题写明触发源。
* **独立大窗口**：`host/wave_popup.py` 的 `WavePopup(QDialog)` 内嵌**第二个 `WavePanel` 实例**（触发 / 时基 / 幅值 / 排布 / 恢复自动 / 暂停 / 导出全部复用，零重复代码），标题双击或控制行「独立窗口」按钮打开；`Esc` 关窗；图内双击仍归 `ScopeNav` 的"恢复自动"（doc16 决策要求保留）。弹窗里画布不再钉 250 px，随窗口长高。
* ★ 自检 ⑱ 的四条键盘用例一度全失败：探针证明**离屏平台一旦开过第二个 `MainWindow`，`app.activeWindow()` 会变成 None，于是所有 `WindowShortcut` 都不响应**（快捷键表本身 enabled=True）⇒ 测试侧补 `w.activateWindow(); w.raise_(); app.processEvents()` 即可。

### 13.5 D 批：记录目录健壮性 + 方波判决

* **记录（R20-14）**：用户报 `[Errno 13] Permission denied`，但他用 PowerShell 往同一目录写文件是**成功**的 ⇒ 说明不能只靠 `os.access()`（Windows「受控文件夹访问」是运行时拦截，不体现在 ACL 上）。`recorder.probe_writable()` 改成**真写一个探针文件**再删；不可写时 `fallback_dirs()` 自动改存并明确告知（原目录 / 原因 / 改存到哪）；`dir_hint()` 把 PermissionError 翻译成三条常见原因（受控文件夹访问要放行 `host_app.exe` / CSV 被 Excel 占用 / 目录只读）。记录卡片在选目录时就探测并预警，开始记录后显示**真正在写的文件**。
* **方波（R20-12，方案 C = 实测 + 理论）**：`abz.AbzAnalyzer` 新增按箱多数票的硬判决（`hi/n >= 0.5` → 1，空箱只跨 ≤ `SQ_GAP=12` 箱继续沿用，再长就断开 —— 没数据的地方不画线），并生成相位对齐的**理想方波**作参照（AB 的周期由 `sq_per_bins = bins*div/inter` 得出、B 滞后 90°；UVW 用 360° 周期、互差 120°）；面板新增读数「方波判决 %」「每周期箱数」，理论方波用虚线画在旁边。
* **真机实测（关键验证）**：板上原配置 `inter=256`（每周期只有 4 箱）时平均值有 21 档"阶梯"，程序正确提示"想看方波形状需要 2048 箱（超过上限 1024）⇒ 请把 inter 降到 ≤128"；点「方波可看」配成 `inter=64` / 1024 箱（每周期 16 箱）后，**只在已填到的箱上比，硬判决与理想方波一致 437/439 = 99.5%**，阶梯从 19 档直接掉到 **2 档**，判决可信度 0.998，A 相实测沿数 51 vs 同区域理想 54.9，U 相符 422/422。
* **物理约束（先算再承诺）**：一箱 = `inter/bins` 个 A/B 周期 ⇒ 每周期要 ≥8 箱才看得出方波 ⇒ **`bins ≥ 8×inter`，1024 箱要求 `inter ≤ 128`**；`inter=256` 时任何算法都画不出标准方波，程序只给可执行建议。等效采样还要靠角度遍历慢慢填箱（`inter=64`/1024 箱时 8 万帧约 41%），**箱覆盖率是独立读数**、判决线只在已填箱上可信。

### 13.6 门槛与交付包（第十一次重打）

* `python -m compileall -q host` exit 0；离屏自检 **222/222 PASS**（164 → 173 → 182 → 200 → 222）；真机 **PASS**：方波可看 1024 箱 / `inter` 64、**界面取 63,696 帧 = 记录器 63,696 行（差 0）**、文件行数 120,843 = rows、链路解析 129,676 帧、丢帧 1,011、关窗队列丢弃 0。
* 交付包（第十一次）：`host\dist_onedir\host_app\host_app.exe` **8,040,142 B @2026-10-16 22:21:30**、SHA256 `FB03757FBBF8B98EF3F186E0C68E2E2FDEA7D2D1A05372A988B4C898A94DC841`、**439 文件 / 585,307,241 B**；PYZ **683 模块**（+`wave_popup`），正向串全命中（`ui_font`/`theme`/`main_window`/`page_overview`/`panel_interp`/`panel_alarm`/`panel_abz`/`panel_wave`/`abz`/`recorder`/`ui_kit`/`wave_popup`/`ui_prefs`，共 60 个），反向 12 串（`CardMax`/`install_maximize`/`_setup_card_maximize`/`_enter_card_max`/`_restore_card_max`/`set_max_layout`/`SIDE_MAX_W`/`MAX_BTN_ON`/`maxHide`/`set_plain_wheel_zoom`/`_plain_zoom`/`MAX_BTN_WIDTH`）**全无命中**；包内烟测 exit 0、`截图成功：…1413x824`、运行日志「界面字体：**Inter 已装载（4 个文件）**」。

### 13.7 遗留与待确认

* 用户原话写的是「**输出**信号波形可以单独放大」，我按 ⑧「**输入**信号波形」实现（页面上只有这一个时域波形卡）；**⑨ 编码器等效采样图的同款弹窗已在收尾批补上**（见 §13.8）。
* 编码器页等效采样填箱慢（角度遍历靠跑数据），面板只报覆盖率、不做数据外推。
* 卡片标题里的 ①②③ 编号已全部删除 ⇒ 早期文档/README 里按编号点名的说法统一改成按标题点名（本轮已改）。

### 13.8 收尾批：记录页「真凶在工作区 ACL」+ ⑨ 独立大窗口（2026-10-16/17）

* **触发**：用户第二轮回传现场截图与 `诊断报告.txt`（**m17097**）：导出 PNG `存图失败：[Errno 13]`、记录自动改存到包旁边、点「打开文件夹」`[WinError 5]`；诊断报告里 `沙箱指纹 = 无 DSH_* 环境变量`、包内目录**写探针成功**，而 `文档`/`Desktop\host_app记录`/`~\host_app记录`/`AppData\Local\host_app记录` **全部** `建不了文件夹：[WinError 5]`。
* **产品侧加固（R20-15/-16/-17）**：①`panel_record._open_dir()` 改成四级兜底 `explorer /select,<文件>` → `os.startfile(文件)` → `explorer <目录>` → 剪贴板，并在按钮下方写明用的哪一级；②`main_window._on_export()` 先 `recorder.writable_dir_or_fallback(self.record.dir)`，改存要在数据说明里追加说明（`note` 随后会被快照信息覆盖，所以必须分开拼 `data_note`）；③`recorder` 新增 `diag_write`/`write_diagnosis`/`acl_report`/`cfa_state`/`token_flags`/`parent_process`/`env_warning`/`pick_dir`/`writable_dir_or_fallback`，记录页加非模态「写入诊断」按钮（只读文本框 + 复制全部），诊断报告新增**「进程身份」段**；`dir_hint()` 扩到四条原因（含"管理员能写、本程序不能写 ⇒ 目录权限/完整性级别在挡"）。
* **★ 根因（机制证据，一次定性）**：运行中的 `host_app.exe` PID 37920 父进程是 **`explorer.exe`**（真双击），但令牌 = **`integrity Low（S-1-16-4096）` + `has_restrictions=1` + `elevated=0`**；`icacls` 该 exe 自身就是 `Mandatory Label\Low Mandatory Level:(I)(NW)`；`host` 树 636 行 Low 标签 / 634 行 `S-1-4-…` ACE；**工作区根 `C:\Users\zhaoy\Desktop\FPGA` 自己带着低标签与沙箱 ACE**（`Desktop` 本身干净）⇒ PyInstaller 继承给了包目录与 exe ⇒ Explorer 按镜像标签把进程降权 ⇒ 只能写标签允许的位置。★ 早先"无 `DSH_*` ⇒ 普通双击、问题在系统防护"是**差点写进报告的错误推断**：环境变量只是启动器指纹，不是运行机制。
* **修复**：`icacls "C:\Users\zhaoy\Desktop\FPGA" /reset /T /C /Q` + `icacls <同路径> /setintegritylevel "(OI)(CI)M" /T /C /Q`（各 32,799 个对象、0 失败）⇒ 复核工作区根 / exe / `recorder.py` 全为 **Medium**、全树 Low 标签 0、沙箱 ACE 0。★ 注意 `icacls` 只改本机；交付物去降权要靠打包清单新增的那条复核（见下）。
* **⑨ 独立大窗口（用户确认要）**：新增 `host/abz_popup.py::AbzPopup(QDialog)`，内嵌第二个 `AbzPanel`（`canvas_h=None` 不钉高、`show_popup=False` 隐藏自身按钮），`Esc` 关窗；`panel_abz` 新增 `popup_requested` 信号、标题双击/控制行按钮两条入口、`__init__(bins, parent, canvas_h=240, show_popup=True)`、`mirror(other)`（同步输入频率与输出位/寄存器口径，**视图设置各窗口独立**）；`main_window` 新增 `_open_abz_popup()`/`_sync_abz_bins()`，`_tick` 里弹窗可见时 `mirror` + `feed`。★ 踩坑：`canvas_h=None` 时 `if canvas_h: …setFixedHeight` 若写在 `if HAS_MPL:` **外面**会落进 `else` 把 `self.canvas` 置 `None` ⇒ `AttributeError: 'NoneType' object has no attribute 'minimumHeight'`（已嵌回 `if HAS_MPL:` 内，`host/panel_abz.py:268-280`）。
* **门槛**：`python -m compileall -q host` exit 0；离线 **255/255 PASS**（222 → 235 → 239 → 255，新增 ㉖ 记录加固/取证 17 项、㉗ ⑨ 弹窗 16 项）。**真机门槛本轮未跑** —— 用户明确"先只重打包，板子暂时不接"，等接回后补 `python host\selftest_ui.py --real-port COM3 --seconds 6`。
* **交付包（第十三次重打）**：`host_app.exe` **8,059,995 B @2026-10-16 23:07:57**、SHA256 `32E928F659C54642F307CB9B99AF8A78470303ED4F4B9A989535F222B5C37A74`、目录 **439 文件 / 585,327,094 B**；PYZ **684 模块**（+`abz_popup`）；正向 **19 个模块名 + 33 个标志串全命中**（含 `AbzPopup`/`popup_requested`/`_open_abz_popup`/`_sync_abz_bins`、`token_flags`/`parent_process`/`env_warning`/`write_diagnosis`/`进程身份`），反向 12 串（`CardMax`/`install_maximize`/`_setup_card_maximize`/`_enter_card_max`/`_restore_card_max`/`set_max_layout`/`SIDE_MAX_W`/`MAX_BTN_ON`/`maxHide`/`set_plain_wheel_zoom`/`_plain_zoom`/`MAX_BTN_WIDTH`）**全无命中**；★ **`icacls <exe>` = `Medium Mandatory Level`、全树 Low 标签 0 / 沙箱 ACE 0**（构建于 ACL 修复之后，实测继承问题不再出现）；包内烟测 exit 0、`截图成功：…1413x824`（PNG 47,955 B）、运行日志「界面字体：**Inter 已装载（4 个文件）**」。
  ★ 因 `host\dist_onedir\host_app\host_app.exe` 当时正被用户运行的进程（PID 37920）占用，本轮先构建到 `host\dist_next\host_app\`，再在进程退出后整体替换 `host\dist_onedir\host_app\`（同一份产物，只换位置；替换后复跑包内烟测 exit 0、`icacls` 仍为 `Medium`、Low 标签 0 / 沙箱 ACE 0）。替换后删掉了烟测留下的 `ui_prefs.json` 与 `host_app_run.log`，交付目录回到出厂状态 **439 文件 / 585,327,094 B**。
* **PYZ 复核固化成工具**：新增 `tools/check_pyz.py`（`CArchiveReader` 取 `PYZ.pyz` → `ZlibArchiveReader` 列 `toc` → 各模块 `marshal.dumps` 拼接做字节搜索，中间产物写 `%TEMP%`，附带正向/逆向清单可加 `--forward-files`/`--backward-files`）；本包跑出 `PYZ 模块数 = 684`、正向 17 模块名 + 30 串全命中、逆向 12 串无命中、**PASS / exit 0**。
* **打包清单新增一条硬性复核**（记录 72 的教训）：打完包必须 `icacls host\dist_onedir\host_app\host_app.exe` 确认**没有** `Mandatory Label\Low Mandatory Level`、**没有** `S-1-4-…` ACE；出现就先修工作区再重打。已写进 `host/README.md` 的「打成目录版」命令块。

### 13.9 防复演：清单变门禁（2026-10-17）

* **触发**：用户问「怎么样才能不让问题重演？」。§13.8 的修法有两个弱点：`icacls` 只改**本机**；而"打包后人工复核"靠人记得 —— 这次翻车恰恰发生在"记得住"的假设上（我在受限令牌下打了包就交了）。
* **病根**：**用受限/低完整性令牌打包** ⇒ PyInstaller 把 `Mandatory Label\Low Mandatory Level` 写进产物 ⇒ 用户双击时 Explorer 按镜像标签降权 ⇒ 只能写标签允许的目录。
* **三道闸（新增两个脚本，把清单变成可执行判定）**：
  * ① 源头闸 `tools/build_host_onedir.ps1`：打包**前**读当前终端令牌（`whoami /groups`），出现 `Mandatory Label\Low` 或 `S-1-4-…` 就**拒绝打包**（要硬来必须 `-Force`）；先查 `host_app` 是否在运行（占用会让 PyInstaller 必失败）；打包后自动调门禁，最后打印"该把哪些数字抄进 README / DEV_STATUS / docs16"。
  * ② 产出门禁 `tools/check_package.ps1`：①终端令牌 ②exe / 交付目录 / 包内树（`icacls /T`）/ 工作区根四处的 Low 标签与沙箱指纹 ③文件数 + 总字节 + SHA256 ④包内 PYZ（调 `tools/check_pyz.py`）⑤包内烟测（跑完清掉 `_gate_smoke.png`/`ui_prefs.json`/`host_app_run.log`）；PASS → exit 0，FAIL → exit 1 并逐条列出。`-Fix` 只做 `/setintegritylevel "(OI)(CI)M"`，**不做 `icacls /reset /T`**（沙箱的 `S-1-4-…` 授权与 `Everyone deny` 是预期状态，见技能 `diagnose-windows-sandbox-acl` 口径）。
  * ③ 收尾闸 `tools/build_host_exe.ps1`（单文件备用产物）也补了同一道判定：打完立刻查 exe 的 Low 标签，命中就 `exit 1`。
* **门禁自己的两个坑（实测踩到并修掉，都写进注释）**：
  * `Start-Process -PassThru` 在 **Windows PowerShell 5.1** 上把成功退出读成**空串** ⇒ 门禁把 exit 0 判成 FAIL"烟测退出码"；改用 `System.Diagnostics.Process`（`WaitForExit` 后再读 `ExitCode`）。
  * 5.1 的管道按 OEM 码页解码 ⇒ PYZ 复核输出变 `PYZ ģ���� = 684`；修法：`[Console]::OutputEncoding = UTF8` + `PYTHONIOENCODING=utf-8`。★ 但**同一招用在交付 exe 上反而弄坏了输出**：GUI exe 往管道写的是 **ANSI 码页（本机 cp936）**，实测字节 `bd d8 cd bc b3 c9 b9 a6` = `截图成功`，按 UTF-8 硬解就成了 `��ͼ�ɹ���`。最终修法：烟测输出**按字节读回**（`Read-RawStream`）再"先 UTF-8 严解码、失败回退 ANSI 码页"（`Convert-RawText`）—— 教训是**别替别人的输出指定编码，先量它的字节**。
  * ★ 另：`.ps1` 被"重写式"编辑丢掉 BOM 后，5.1 会按 GBK 解码并报**指向正常行**的假语法错（实测 `Unexpected token '}'` 落在完全正确的 `} catch { }` 上）⇒ 改完跑 `python tools\fix_ps1_bom.py --fix`。
* **在第十三次包上的实测**：门禁 **PASS / exit 0** —— 439 文件 / 585,327,094 B、PYZ 684 模块、正向 17 模块名 + 30 串全命中、逆向 12 串 0 命中、包内烟测 exit 0 `截图成功：…1413x824`，跑完目录自动回到 439 文件。
* **文档同步**：`host/README.md`「打成目录版」命令块改成"一条命令交付 + 手动兜底 + 门禁说明 + BOM 提醒"，收尾批小节补"清单已变工具"；`docs/DEV_STATUS.md` **§1.91**；`docs/12_host_ui_requirements.md` **R20-18**。

### 13.10 全面自查批：功能实现程度 / 稳定性 / bug 与修法（2026-10-17）

* **触发**：用户要求"全面自查上位机软件，检查功能实现程度，稳定性，检查并修复可能存在的 bug"。
* **做法（四路只读审计 + 一名反方验证员 + 我的交叉核对）**：
  * 子代理 ①链路/协议 ②算法/面板 ③生命周期·记录·导出 ④需求追溯（`docs/12` R1–R20 → 代码）；
    一律只读、禁写工作区、每条给 `文件:行号`、分【确定】/【需验证】。
  * ★ **反方验证员**：任务是**证伪**其它子代理的指控（自己写探针实测）。它交了 12 条判定，并明确列出
    "报告说错了的条目" —— 这一步删掉 6 条假指控（含"解析器活锁""读线程静默死亡""先 stop 再 drain 丢尾帧"
    "告警判定被稳定值放宽"），省下 6 次无谓改动。
  * 我自己认领的两个角度：**`host` 寄存器语义/帧布局 ↔ RTL 交叉核对**（`host/regs.py` ↔ `rtl/reg_file.v:58-71`、
    `:559-570`；`tools/uart_scope.py` ↔ `rtl/uart_scope.v` 的 18 字节帧与"帧头也参与异或"）、
    **自检断言强度**（"255 项 PASS"到底在断言什么）——后者直接抓到"两个自检恒假失败"。
* **修掉 19 类真问题**（要点，完整清单见 `docs/DEV_STATUS.md` §1.92.3）：⑨ 独立窗口 `notice` 信号缺失
  （`AttributeError` 被 Qt 槽吞掉 ⇒ 五个信号一个都没接上、`mirror()` 从没调过）；相位差漏 `div`；
  改 `inter`/`div` 不清累积；方波阈值三套口径（同屏既绿又告警）；`link` 命令单槽竞态（假超时）；
  `reply_ok` 放过"6 字节全相同"假应答；`_pump` 短缓冲盲区；`_tick` 无异常保护（坏帧 ⇒ 每 100 ms 弹模态框）；
  `_update_live` 硬下标坏帧；`ui_prefs` 的 `ui.scale`/`wave.trig` **写了等于没写**；`_on_export`/`closeEvent`
  的善后不在 try 内；诊断框连点攒窗口；导图失败留半截 PNG；`encoder` 口径迟滞无出口；写串口失败不回流；
  Toolhelp32 句柄被截断；写探针毁同名文件；**三处高级参数提示文案停在 v8 语义**（"迟滞 0 = 默认档"、
  "Z 脉宽 0 = 不出 Z" ⇒ 会让用户按错信息改硬件，按 `rtl/abz_gen.v:120/:130/:519-520/:526` 更正）。
* **两个自检自己坏了**（长期没人发现）：`export_png.py` 的像素判据写死旧调色板（画图侧早已改用 `theme.C`）；
  `recorder.py` 的 [6] 还在断言"目录不可写 ⇒ 报 error"（D 批起已改成先探写再自动改存）。⇒ 新增
  **`tools/check_offline.ps1`** 离线总门禁（`compileall` + 七模块自检 + 界面级 277 项，失败 `exit 1`），
  与交付侧 `tools/check_package.ps1` 配对。**教训：清单挂在文档上不等于会跑。**
* **门槛（实跑）**：`compileall` exit 0；`encoder` 11 / `alarm` 25 / `regs` 2043 组往返 / `ui_prefs` 16 /
  `abz` 20 / `recorder` 14 / `export_png` 12 全 PASS；`selftest_ui.py` **277 项 / 0 失败**（255 → 277 =
  ㉘ 9 + ㉙ 10 + ⑭ 补 3）；`tools\check_offline.ps1` PASS / exit 0。
* **交付包已重打（第十四次，2026-10-17 08:13）**：**439 文件 / 585,334,685 B**、
  exe `8,067,586 B @2026-10-17 08:13:58`、SHA256
  `72825284A5812867D837156723492A482C1BCFBF2FD0BAC37C723C6B67A8ADB3`、`Medium` 标签。用本轮新增的
  `tools\build_host_onedir.ps1` 一条命令完成（源头闸读令牌 ⇒ PyInstaller 117 s ⇒ 自动跑 `tools\check_package.ps1`）：
  门禁 **PASS** —— 包内树 2406 行无 Low 标签 / 无 `S-1-4-` 指纹、PYZ 684 模块、正向 17 模块名 + 30 串全命中、
  逆向 12 串 0 命中、包内烟测 exit 0 `截图成功：…1413x824`、跑完目录仍是 439 文件。相对第十三次：
  exe `8,059,995 → 8,067,586 B`、目录 `585,327,094 → 585,334,685 B`（都 +7,591 B，源码 19 处修复进了包）。
* **需求追溯结果**：已实现 61 / 部分 5 / 未实现 0 / 已退场 4；**R20 十八项全部落地**；6 处 `docs/12`
  状态列过期（R6/R7-A/R8/R9②/R10/R11 仍写"✅ 已实现"，实际随阶段 2「⛶ 放大」退场）已逐条标注"⛔ 已退场"
  并附源码证据；真正"没做"的只有 R2/R3 游标测量（文档本来就写"可选、默认关"）。
* **文档同步**：`host/README.md`（自检 277 项与条数链 + 新增「全面自查批」小节 + 文件表 12 处 + 两条门禁
  + 打包命令块加 `tools\check_offline.ps1`）、`docs/DEV_STATUS.md` **§1.92**、本文 **§13.10**、
  `docs/ai-collaboration-log.md` 记录 73、`docs/12_host_ui_requirements.md` 状态列更正。



---

## 14. 显示链路 + 界面梳理批（2026-10-22 晚）

- **显示**：抓包页不再"每 12 点取 1 点"，改 `filters.envelope()` 每像素列 min/max（尖峰不再随机丢）；
  新增「显示」下拉（关/3/5/9/15 点，零相位）；缺块画琥珀色竖带 + 角标；实时页与 XY 同步平滑；
  导出 PNG 用同一套包络 + µs 横轴 + 中文字体；CSV 可写注释首行；数值永远是原始样点。
- **界面梳理（审计 25 条，改 18 条）**：版本号 v13、导出与连接解耦、删恒真表达式、底栏去重、
  状态栏页名反查、断开清丢帧、告警卡删重复按钮、按钮正文去寄存器地址、编码器 v_cfg 复位、
  记录页导出按钮更名、删重复端口提示。
- **bug 审计 22 条，修 12 条**（详见 `docs/DEV_STATUS.md`「上位机显示链路升级」§5）：
  流收包乱序丢包、断开不停流、端口全占仍写、0x070C 写失败被忽略、告警 reset、收包线程静默退出、
  绘图不 `p.end()`、`to_npy` 静默改存、`ui_prefs` 非原子写等。
- **新增自检**：`selftest_filter.py` 29 checks、`selftest_display.py` 10 checks；`selftest_ui.py` 仍 **277/0**。
- **交付包（第十六次）**：`host_app.exe` **8,126,262 B @2026-10-22 22:20:12**、SHA256
  `968B415C9C9EB193E31BDA7CD95344B217EA9E58E5D07B9C07EAEFDC407A4148`、目录 **440 文件 / 585,402,250 B**、
  `PYZ` 689 模块、烟测 exit 0；`tools/build_host_onedir.ps1` 一条命令完成（PyInstaller ⇒ 门禁 PASS）。

## 15. 全面复查批（2026-10-22 深夜，第十七次交付包）

- **动因**：用户要求「再全面复查一下，保证能正常稳定运行，不要有 bug」。板子 USB 已拔，
  所以把「不需要硬件也能证明」的部分做满，并把剩下的整理成下一轮候选。
- **审计**：两个只读子 agent 通读 `host/*.py`——「并发/资源」24 条、「异常/UI 状态机」21 条，
  都附 `file:line`、现象、修法，并各自列出「确认没问题的关键路径」（串口线程收尾、UDP catch、
  记录器开关、缓冲有界、Figure 复用、定时器、关窗顺序、无阻塞析构）。
- **修掉 25 条**（高危 7 / 中 13 / 低 5），核心是把「会卡 GUI、会泄漏、会静默死」的路径全部挪走：
  连续流启动与停止搬进任务线程、网络自检占 busy、UDP 改 `SO_EXCLUSIVEADDRUSE`、收包线程包异常、
  流启动失败收尾、tick 槽整体 try、日志跨线程改队列泵、退出排水分批、导出原子写、参数行锁、
  `--smoke` 走 `win.close()`、记录缓冲 64 KB。
- **新增验证**：`tools/gui_soak_offline.py`（无硬件浸泡，合成遥测 27.3 万帧 / 翻页 40 / 导出 3，
  RSS +9.1 MB 后趋平）、`tools/gui_soak.py`（真板浸泡，待接线）。
- **交付包（第十七次）**：`host_app.exe` **8,131,033 B @2026-10-22 23:45:28**、SHA256
  `9006C8CCBB1390C5B506ADFC8B2C3F845B7C826A66CD7CA1B4E7180FDC187D45`、目录 **440 文件 / 585,407,021 B**、
  `PYZ` 689 模块、包内烟测 exit 0、`check_package.ps1` PASS。
- **验证链**：`check_offline.ps1` PASS（compileall + 7 模块 + 界面 277 项）、
  `selftest_capture/display/udp/stream/filter` = 25/10/26/29/29 全 PASS、2 分钟无硬件浸泡 PASS。
- **已知未做**：单工作队列（任务线程去抖）、退出排水的异步化、上板浸泡与热插拔用例。

## 16. 收尾批（2026-10-23 凌晨，第十八次交付包）

- **任务线程**：`TaskRunner` 改「常驻线程 + 队列」，阻塞任务串行；`closeEvent` 里
  `task.shutdown(0.8)`；连点/换页不再堆线程（审计 #9 收口）。
- **异常钩子**：`app._hook` 永远写日志、弹窗 60 秒最多一次——定时器槽出错不再把界面淹掉。
- **验证**：10 分钟无硬件浸泡 1,331,000 帧 / 翻页 40 / 3 次导出，RSS +8.5 MB 持平；
  离线门禁 277 项；五个功能自检全 PASS。
- **交付包（第十八次）**：`host_app.exe` **8,132,580 B @2026-10-23 00:03:23**、SHA256
  `529F0854BA76CA7E3C2D3D06475CF9C7FEA9EC89439C67E6AA57C9CC5FCC6D25`、
  440 文件 / 585,408,568 B、`check_package.ps1` PASS。
- **上板清单**：`docs/24_board_acceptance_morning.md`（明早按表执行）。
