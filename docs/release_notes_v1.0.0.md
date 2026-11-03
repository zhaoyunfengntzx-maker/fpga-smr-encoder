# v1.0.0 发布说明

日期：2026-11-03
基线：**v74 生产位流**（签核 + 上板验收）+ **v85 显示位流**（构建签核 + 已下载）
适用：2026 年第九届全国大学生嵌入式芯片与系统设计竞赛 · AMD 赛道 · 自主选题

---

## 1. 这个版本是什么

v1.0.0 是项目的**首个公开开源版本**。它不是一次 RTL 重写，而是把已经签核的
v74 基线、最新的 v85 显示构建、全部证据与文档，整理成一支陌生队伍可以复现、
可以复核、可以二次开发的仓库。

- **参赛/答辩**：用 v74 生产位流。时序 +0.409 ns、LUT 52.53%、0 失败端点、
  转台 719–740 rpm 验收。
- **演示屏 + 上位机**：用 v85 显示位流。UI 更新到 v85，但**没有逐页目视验收**，
  话术必须是"构建签核 + 已下载"。
- **代码**：`rtl/` 与 v74 的差异只有 `RTL_BUILD_ID` 与只读 Z 计数探针；
  `disp/` 是 v85 的最新 UI。

## 2. 相对 v74 的增量（v75 → v85）

### 2.1 屏上 UI（`disp/`）

| 版本 | 改动 | 目的 |
|---|---|---|
| v75–v78 | P4 抓波页触发与布局迭代；过零单次触发 | 抓到的波形可重复，不再"每次不一样" |
| v79 | P4 右上角"屏上自证"读数（`p4_dbg_lab.v`） | 不接上位机也能判断抓波是否有效 |
| v82 | 字段实际字符数上报（`disp_engine.v` + `val_format.v`）；锁存 2 s 自动老化 | 单位跟随数值长度；旧锁存不再常亮 |
| v83 | UVW 六态搬到"数值层"；P4 触发源改为 U 下降沿（电角度 180°） | 标签层写口仲裁简化；下区从 180° 起拍 |
| v84 | P4 窗口改为**确定性** `eclk*2048/pairs`；U 相交叉校验、窗口长度、无信号标志上屏 | 窗口不再依赖 U 边沿，偶发"几条平线"可解释 |
| v85 | P7 相对误差曲线（±2%，P-P / RMS）；删除 0%/100% 绝对幅值闸线；Z 计数 5 ms 重触发门控 | P7 从"看绝对值"改为"看相对误差"，更贴近标定质量 |

v85 的构建数据：1,699,249 B、WNS **+0.175**、LUT **18,088 = 86.96%**、
BRAM **48/50**、DSP 26、DRC 0 Error、布线 29,278/29,278。详见
[`deliverables/data/v85/README.md`](../deliverables/data/v85/README.md)。

### 2.2 上位机（`host/`）

- 网口模式：实时预览修复（`_update_live(frames[-1])`）、建链超时 6 s → 15 s、
  `STOP_HZ = 30.0` 静止死区；上板复测 ping 5/5、重连 20/20（后续 60/60）、
  连续流 4/4。
- 修 `task_set_ablimit()` 的 int/字典混用崩溃；修 `adv_field_writes()` 空字典误报。
- "AB 限频"按需求**整体删除**（`docs/42_host_change_log.md` §17 记录代价：
  高速时 A/B 边沿可能超出下游计数器带宽，这是有意取舍，不是 bug）。
- 新增 `host/requirements.txt`，固定依赖范围。

### 2.3 构建与文档

- v85 证据归档到 `deliverables/data/v85/`（位流、时序/资源/DRC/布线/IO 报告、
  实现与烧写日志、构建脚本、`VARIANT_INFO.txt`）。
- 根 README 重写为公开主页；新增 `docs/README.md`、`docs/BASELINES.md`、
  `docs/REPRODUCE.md`、`CHANGELOG.md`、`CONTRIBUTING.md` 等。
- 构建脚本去掉硬编码绝对路径（`impl_check_v74.tcl`、`impl_check_disp_v74.tcl`、
  `program_bit.tcl`）。

## 3. 兼容性

| 项 | 说明 |
|---|---|
| 硬件 | 正点原子达芬奇-lite（XC7A35TFGG484-2）+ AD9238 + 7" 1024×600 屏；与 v74 相同 |
| 传感头 | 8 Vpp 差分正交、2048 电周期/圈（`ENC_V69_CPR2048`）；其他周期数需改变体 |
| Vivado | 2026.1 验证；2024.x+ 预计可用，但时序数字会随版本变化 |
| 上位机 | Windows + Python 3.11+；PySide6 6.9 / pyserial 3.5 |
| 寄存器 | 0x0000 ID / 0x054A–0x054D Z 计数等与 v74 一致；无破坏性变更 |
| 位流 | v85 显示位流**不能**当生产位流用（带 `ENC_DISP_TAP`，资源 86.96%） |

## 4. 验证状态（必须如实转述）

| 项 | v74 生产 | v85 显示 |
|---|---|---|
| 时序签核 | ✅ WNS +0.409，0 失败 | ✅ WNS +0.175，0 失败 |
| DRC | ✅ 0 Error | ✅ 0 Error |
| 仿真 | ✅ 36/36（2026-11-02） | ✅ 18 台历史 + `tb_disp_smoke` PASS |
| 烧写 | ✅ 上板验收 | ✅ `PROGRAMMED_OK`（2026-11-03 16:50） |
| 转台功能 | ✅ 719–740 rpm、Z ≈12 Hz、UVW 六态 | ⚠️ 未在转台上复测 UI |
| 屏逐页目视 | —（无屏） | ❌ **未做** |
| 以太网 | ✅ ping + UDP 抓窗 | ⚠️ 未单独复测 |

## 5. 升级 / 使用建议

1. 已有 v74 环境的队伍：只替换显示位流即可得到新 UI；生产路径不变。
2. 重新构建前先跑 `python tools\make_v74_rtl.py`，否则 `_synth_work_v74/rtl_v74`
   不存在，两个 impl 脚本都会找不到源文件。
3. 不要混用位流：生产接法（无屏）烧 `enc_top_v74.bit`；带屏接法烧
   `enc_top_disp_v74.bit`（v85）。
4. 报告/答辩引用数字时，以 `docs/BASELINES.md` 与 `deliverables/data/*/README.md`
   为准，不要引用旧版 README 里的 `1,713,025 B`。

## 6. 已知问题

见 [`CHANGELOG.md`](../CHANGELOG.md#known-issues) 与设计报告 §7。最关键三条：

- v85 屏未逐页目视，BRAM 96% 无余量；
- 纯 RTL，无 PS/PYNQ；
- 仓库含约 233 MB 证据，克隆慢（可 `--depth 1`）。

## 7. 文件导航

| 你要找 | 去哪 |
|---|---|
| 项目主页 / 指标 | [`README.md`](../README.md) |
| 从零复现 | [`docs/REPRODUCE.md`](REPRODUCE.md) |
| 全部基线 | [`docs/BASELINES.md`](BASELINES.md) |
| 变更日志 | [`CHANGELOG.md`](../CHANGELOG.md) |
| 提交版报告 | [`deliverables/design_report.pdf`](../deliverables/design_report.pdf) |
| 证据索引 | [`deliverables/evidence_index.md`](../deliverables/evidence_index.md) |
| 技能包 | [`skill/README.md`](../skill/README.md) |
| 大模型协作 | [`docs/ai-collaboration-log.md`](ai-collaboration-log.md) |
