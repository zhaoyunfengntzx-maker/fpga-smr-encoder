# deliverables/data — 报告引用的原始证据归档

## 1. 这个目录是什么

本目录是 `deliverables/design_report.md`（下称**报告**）与 `deliverables/evidence_index.md`（下称**索引**）所引用**原始证据**的归档副本。报告按文件名引用这些位流、Vivado 时序报告、ILA 抓包 CSV 与实验日志，但它们的工作副本原先只存在于 `_synth_work/`——该目录被 `.gitignore` 忽略，入库文件数为 0，评委拿到仓库看不到任何一份。因此提交包内附带这份经过筛选、逐文件 SHA256 校验的副本。

本目录共 **320 个文件 / 155,302,585 B（约 148.1 MB）**（2026-11-04 用 PowerShell `Get-ChildItem -Recurse -File` 实测，含各版本子目录的 `README.md` 与本 README、`SHA256SUMS.txt`、`.gitkeep`）：`v90/` **26**、`v85/` **16**、`v74/` **26**、`v73/` **26**、`v71/` **26**、`v70/` **24**、`v68/` **25**、`v67/` **12**、`v66/` **20**、`v62/` **13**、`bitstreams/` **27**、`timing/` **23**、`ila/` **21**、`logs/` **17**、根目录 **18**。

- **2026-11-04 新增 `v90/`（26 件）**：**当前交付基线**——① 修 Z 停位喘振（`z_index_gen`：出 Z 撤防、离开 ≥1/8 圈重布防），板上 Z 严格 **1 个/转**（7.62 Hz ↔ 457 rpm）；② 显示 UI 收敛（P2 中线预触发 + 三档/`AUTO` 时基、P7 标定页整页删除、P1 标定按钮删除）；③ `RTL_BUILD_ID=0x0019`，生产 `WNS +0.199` / 显示 `WNS +0.221`，回归 **37/37**；显示位流**已固化 QSPI Flash 并断电冷启动通过**。判据见 `docs/39_acceptance_criteria_v90.md`。SHA256 见 §2.0g。- **2026-11-02 新增 `v73/`（24 件）**：**上板调试版**——① 修掉显示子系统 RPM 除零（`disp/val_format.v` 除数 16→20 位，屏上 496729.5 → ≈775 rpm）；② 新增 Z 上升沿计数探针（只读 `0x054A..0x054D`），把 Z 从"看波形"变成"读数字"（实测 **12.00 Hz ↔ 720.0 rpm**，每转 1 个）。生产 + 显示两个位流都已在真实转台上跑通，显示位流已**固化进 QSPI Flash 并断电冷启动验证**。SHA256 见 §2.0f。
- **2026-11-02 新增 `v71/`（24 件）**：**Z 索引脉冲修复**（全量审计发现 B1：`cycle_cnt` 回绕点跟着复位瞬间的绝对角度 ⇒ Z 永不出）。生产 `WNS +0.277`、显示 `WNS +0.143`，仿真回归 **36/36**；**尚未上板**（板卡已断开）。SHA256 见 §2.0e。
- **2026-11-01 新增 `v70/`（22 件）**：转台 2048 PPR 的**验收版本**——修掉位置计数恒 0 与 UVW 反向卡死两个缺陷；生产位流已上板实测（当时按电周期折算约 720–731 转/分 / Z 12.00 Hz / UVW 六态 / 标定 / 以太网），显示位流仅构建签核。
- **2026-10-30 新增 `v68/`（23 件）**：400 mVpp 单端正交（64 周期/转、前端 4.16×）的**生产 + 显示两个位流**与签核件，SHA256 见 §2.0c。**v68 尚未上板**；其数字只到 `[构建签核]` + `[仿真]`。

- **2026-10-29 新增 `v67/`（10 件）**：小信号传感器适配版（200–300 mVpp、64 周期/转、前端 4.16×）的生产位流与签核件，SHA256 见 §2.0b。**v67 尚未上板**；其数字只到 `[构建签核]` + `[仿真]`。
- **2026-10-29 新增 `v66/`（20 件）**：转台适配版（v63–v66）的**两个**位流与其签核件，SHA256 见 §2.0a。**v66 尚未上板**，因此 v66 时代的报告实测数字仍以 `v62/` 为准；**v70 起真机实测见 §2.0d**。
- **2026-10-27 新增 `v62/`（13 件）**：交付位流的 `.bit` 与其全部签核件（timing / util / DRC / IO / check_timing / 三条路径报告 / clkint / route / impl.log / runner.log），SHA256 见 §2.0。此前的 v12 归档（2026-10-13）见 §2.1–§2.2。
- 2026-10-13 增补 **`telemetry_abz_uvw.csv`**（25,237,925 B 的 30 s 串口遥测原始帧，见 §2.5；配套图 `../figures/telemetry_abz_uvw.png`）。
- 同日增补 **李萨如 4 图 / 5 CSV**（`calib_repeat_summary.csv`、`lissajous_{before,after}[_distortion].csv`、`lissajous_summary.csv`，见 §2.4a）与 **频率阶梯 1 kHz–500 kHz 六点**（`freq_ladder_summary.csv` + `freq_robust_summary.csv` + `freq_*.csv` + `../figures/freq_*.png`，见 §2.6 / §2.6a）。
- `SHA256SUMS.txt` 现 **323 条**（304 个数据文件 + `../figures/` 的 19 张 PNG），**已覆盖 `v62/`、`v66/`、`v67/`、`v68/`、`v70/`、`v71/`、`v73/`、`v74/`、`v85/` 与 `v90/`**；2026-11-04 用 Python `hashlib` 逐条复核：**322/323 通过**，唯一不匹配是 `README.md` 自哈希（清单生成后本文件又改过，重算该行即可）；最终复核以 §5 的脚本输出为准。v74 的 `enc_top_v74.bit`（1,512,664 B）与 `enc_top_disp_v74.bit`（1,700,821 B）已收进 `v74/`，v85 显示位流（1,699,249 B）已收进 `v85/`。

## 2. 目录清单

**列含义**：文件 · 大小(B) · SHA256（前 12 位，完整值见 `SHA256SUMS.txt`）· 它能证明什么 · 报告/索引引用位置。
> ⚠ 2026-10-13 之后**增补/覆盖**的 9 个 v12 文件不在 `SHA256SUMS.txt` 内（该清单仍是 v11 切片），其后 12 位哈希以本表为准，完整值见 §2.1–§2.2 正文。

### 2.0 `v62/` — ★ 参赛演示位流与其签核件（2026-10-27 归档）

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `enc_top_v62.bit` | 1,694,505 | `EC0B383B…47EB` | **交付位流 v62**（2026-10-23 10:18:42），内容 = 编码器 + 5 页触摸 UI + 千兆网（B1 串口 dump + B2 UDP/连续流） | 报告 摘要、§4.2、§10.6.4；索引 §1 |
| `impl_timing.rpt` | 121,012 | `EFFF2B72…` | **签核时序**：`All user specified timing constraints are met.`；WNS **+0.471** / TNS 0.000 / 0 失败 / **33,255** 端点；WHS **+0.042** / 0 失败 / 32,790；WPWS +0.264 / 0 失败 / 11,697 | 报告 §4.2、§7 R1 |
| `impl_util.rpt` | 12,452 | `B6F34BDC…` | **签核资源**：LUT **17,059 / 20,800 = 82.01%**、FF 11,193 = 26.91%、BRAM **46 / 50 = 92.00%**（RAMB36E1 42 + RAMB18E1 8）、DSP 18 = 20.00%、IOB 107 = 42.80%、BUFGCTRL 5 = 15.63% | 报告 §4.2、§7 R13 |
| `impl_drc.rpt` | 55,411 | `27DEAAB2…` | **97 checks / 0 Errors**；Warning 分布 BUFC-1×1、CHECK-3×2、DPIP-1×14、DPOP-1×18、DPOP-2×18、RBOR-1×4、REQP-1839×20（RAMB36 异步控制）、REQP-1840×20（RAMB18） | 报告 §4.2 |
| `impl_check_timing.rpt` | 3,420 | `B56E4D7A…` | no_clock 0 / unconstrained 0 / loop 0；`no_input_delay` 已 false_path；`no_output_delay` 5 项 | 报告 §4.2 |
| `impl_top_paths.rpt` | 489,065 | `E6D42C04…` | 最差 setup 路径明细：`u_eth/s_hip2_reg[18]/C` → `u_udp/ipck_r_reg[12]/D`（`clk_125_raw` 8.000 ns，数据路径 7.370 ns = logic 4.250 / route 3.120，**19 逻辑级**，UDP IP 校验和累加器） | 报告 §4.2 |
| `impl_hold_paths.rpt` | 204,962 | `3C6C4D5A…` | 最差 hold 路径：`u_cordic/g_iter[10].z_p_reg[11][7]` → `g_iter[11].z_p_reg[12][8]`（`sys_clk`，**0.042 ns**，2 级 CARRY4+LUT2） | 报告 §4.2、§7 R13 |
| `impl_eth_rx_paths.rpt` | 47,865 | `3C92DA9B…` | RGMII RX 三条 125 MHz 域的路径余量（供 §7 RGMII 风险条目引用） | 报告 §10、§7 |
| `impl_io.rpt` | 148,322 | `32F5C122…` | 107 个 IOB 的实际分配（屏/触摸/以太网/编码器输出 50 针 + eth 13 针 + 其余） | 索引 §1 |
| `impl_clkint.rpt` / `impl_route.rpt` | 3,479 / 651 | `3C8CB8C6…` / `BAE47FF2…` | 时钟交互与布线摘要（无跨域缺失） | 索引 §1 |
| `impl.log` / `runner.log` | 469,312 / 4,630 | `9559FAAD…` / `4CC883BA…` | 完整实现日志与驱动日志（可复核 `Bitstream compression saved …` 算术与各阶段耗时） | 索引 §1 |

> ★ **引用规则**：报告与 README 里关于 v62 的每一个资源/时序数字，都必须能在本目录的对应 `.rpt` 里用文本搜到。找不到就说明那个数字是旧的（v12 及以前），要换成这里的值。

### 2.0a `v66/` — 转台适配版（v63–v66）**两个**位流与其签核件（2026-10-28 构建，**未上板**）

三件事先说清楚，否则这张表会被误读：

1. **两个位流不是冗余，是资源约束下的必然拆分。** v62 是单一位流（编码器 + 5 页触摸 UI + 千兆网），已到 LUT 82.01% / BRAM 46/50，装不下 v63–v66 的前馈、失锁状态机、偏置跟踪与 4096×16 误差表。v66 把两者拆开：**生产版**（无屏、无 B1/B2 网络）LUT 52.48% / BRAM 32/50，把省下的资源全给了新功能；**显示版**（`ENC_DISP_TAP`）保留屏与网络，LUT 83.82% / BRAM 48/50，只用于现场看波形与调试。两者的 RTL 差异仅由该宏决定。
2. **构建号 `RTL_BUILD_ID = 0x000E`**：上板读 `0x0000` 应为 `0x000E`；验收步骤见 `docs/28_board_bringup_checklist.md`。
3. **两者都未上板。** 下表数字全部来自 `report_timing_summary` / `report_utilization` / `report_drc` 与 `write_bitstream` 的日志，**不含任何上板实测**；报告 §11 的实测类数字一律回落到 `v62/` 与 `logs/`。

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `enc_top_v66.bit` | 1,524,668 | `322F1BE5EA49` | **转台生产位流 v66**（2026-10-28 11:07:30），无 UI、无 B1/B2 网络；含 v9 四新模块（前馈 `lag_ff`、失锁 `lock_sm`、偏置跟踪 `bias_track`、误差表 `angle_lut`）与 v63 以太网 P0 修复 | 报告 §11、§4.2 |
| `prod_timing.rpt` | 104,975 | `45058596B5D1` | **签核时序**：`All user specified timing constraints are met.`；WNS **+0.186** / TNS 0.000 / 0 失败 / **24,630** 端点；WHS **+0.043** / 0 失败 / 24,165；WPWS +0.264 / 0 失败 / 8,987 | 报告 §4.2、§11 |
| `prod_util.rpt` | 12,319 | `0FAB4AFA54D7` | **签核资源**：LUT **10,916 / 20,800 = 52.48%**（logic 10,736 + mem 180）、FF 8,705 = 20.93%、BRAM **32 / 50 = 64%**（RAMB36 31 + RAMB18 2）、DSP 17 = 18.89%、IOB 63 = 25.20%。**与 v62 的 82.01% / 46 块相比，这是拆分位流换来的余量** | 报告 §4.2、§11 |
| `prod_drc.rpt` | 24,356 | `697CE5175A31` | `DRC finished with 0 Errors`；Warning 集中在 DPIP/DPOP（DSP 未流水）与 RAMB 异步控制检查 | 报告 §11 |
| `prod_impl.log` | 270,666 | `F6C097924C3F` | 完整实现日志：`Bitgen Completed Successfully`、各阶段耗时与 `report_drc` 前置检查（`0 Errors`） | 索引 §1、§11 |
| `prod_clkint.rpt` / `prod_route.rpt` | 3,478 / 651 | `0FB7E30650B6` / `D2055CCD094F` | 时钟交互（eth_rxc 125 / sys 50 / adc 50 / clk_200_raw 200 / clkfb 50 MHz）与布线摘要 | 索引 §1 |
| `prod_top_paths.rpt` | 458,052 | `56C61D411ACF` | 最差 10 条 setup 路径明细（报告 §4.2 的余量归因依据） | 报告 §4.2 |
| `enc_top_disp_v66.bit` | 1,681,601 | `E3BC3ED8D62A` | **显示位流 v66**（2026-10-28 11:37:10），`ENC_DISP_TAP`：屏 5 页 + 千兆网 + 编码器；**仅用于调试与答辩演示**，BRAM 48/50 已到 96% | 报告 §11、§9 |
| `disp_timing.rpt` | 116,046 | `4C1FA2D334F8` | WNS **+0.229** / 0 失败 / **34,303**；WHS **+0.024** / 0 失败 / 33,838；WPWS +0.264 / 0 失败 / 12,043；约束全满足 | 报告 §4.2、§11 |
| `disp_util.rpt` | 12,457 | `8CDE02025585` | LUT **17,435 = 83.82%**、FF 11,535 = 27.73%、BRAM **48 / 50 = 96%**、DSP 19、IOB 107 | 报告 §4.2、§11 |
| `disp_drc.rpt` | 56,385 | `BB5EE1EB3978` | `0 Errors`；REQP-1840 ×20（RAMB18 异步控制，屏的 `p1_val_ram` 由带异步复位的 `pix_y` 驱动——已知但本轮未改） | 报告 §11 |
| `disp_impl.log` | 479,424 | `F6487ECFE6ED` | 显示版完整实现日志（含 `check_timing -verbose` 段） | 索引 §1 |
| `disp_check_timing.rpt` | 3,425 | `8432389BEC86` | no_clock 0 / unconstrained 0 / loop 0；`no_input_delay` 已 false_path、`no_output_delay` 见正文 | 报告 §4.2 |
| `disp_io.rpt` | 148,327 | `933CCEFE602C` | 107 个 IOB 的实际分配（屏/触摸/以太网/编码器输出） | 索引 §1 |
| `disp_hold_paths.rpt` | 204,179 | `9428D686BF0B` | 最差 hold 路径（WHS +0.024 的来源） | 报告 §4.2 |
| `disp_eth_rx_paths.rpt` | 47,679 | `0D4244EE3CDD` | RGMII RX 三条 125 MHz 域路径余量 | 报告 §10 |
| `disp_clkint.rpt` / `disp_route.rpt` | 3,484 / 651 | `CB59379823C9` / `E95B57AE4430` | 显示版时钟交互与布线摘要 | 索引 §1 |
| `disp_top_paths.rpt` | 561,365 | `7C6F3037E745` | 显示版最差 10 条 setup 路径明细 | 报告 §4.2 |

> ★ **引用规则（v66）**：报告 §11 里关于 v66 的每一个资源/时序数字，都必须能在本目录的 `prod_*` / `disp_*` 报告里用文本搜到；**任何"实测"字样只允许出现在引用了 `v62/` 或 `logs/` 的句子上**。
> ⚠ **archive 的两处不齐**（如实登记，不靠补跑掩盖）：① 生产版没有 `check_timing` / `hold_paths` / `io` 三份报告——`tools/impl_check_v66.tcl` 当时没跑这三条命令；**不重跑实现**，因为重跑会产出不同布线、进而改变位流与 SHA256，把这份归档作废。② 生产版 DRC 由 `write_bitstream` 前置检查给出（`0 Errors`），与 `prod_drc.rpt` 一致。

### 2.0b `v67/` — 小信号传感器适配版（200–300 mVpp，64 周期/转；**未上板**）

**一句话**：手搓传感器只有 200–300 mVpp，前端方案 B 放大 4.16× 后到 ADC 的 41.6%–62.5% FS；旧版默认增益 1.0
会把 200 mVpp 判成 `amp_low`，所以 v67 把默认增益预置为 1.5、`POLE_BITS` 改 6（64 周期/转）、ABZ `inter` 改 32。与 v66 的差异只有
4 处文本替换（`tools/make_lowsig_rtl.py`），`rtl/` 原文件与 v62/v66 位流均未动。

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `enc_top_lowsig.bit` | 1,504,428 | `80842AC24266` | **v67 生产位流**（2026-10-29 10:36:27），无屏、无网；BUILD_ID=`0x000F` | `docs/29` §5 |
| `prod_timing.rpt` | 106,861 | `EF91833F3621` | WNS **+0.282** / TNS 0.000 / **0 失败（24,630）**；WHS **+0.046** / 0 失败；WPWS +0.264；约束全满足 | `docs/29` §5 |
| `prod_util.rpt` | 12,325 | `40F2576C285D` | LUT **10,924 = 52.52%**、FF 8,705 = 20.93%、BRAM **32/50**、DSP 17、IOB 63 | `docs/29` §5 |
| `prod_drc.rpt` | 24,362 | `D3A77B90BABD` | **0 Errors / 0 Critical Warnings**；45 Warning（DPIP×12 / DPOP-1×16 / DPOP-2×17） | `docs/29` §5 |
| `prod_route.rpt` | 651 | `C7AAB4EEC672` | 18,584 条可布线网全布通、0 routing errors | `docs/29` §5 |
| `prod_clkint.rpt` | 3,484 | `5064D965D604` | 时钟交互（sys 50 / adc 50 / eth 125 / clk_200 200 MHz） | 索引 §1.2 |
| `prod_top_paths.rpt` | 474,821 | `CB56B5CE6D4B` | 最差 20 条 setup 路径明细 | `docs/29` §5 |
| `prod_impl.log` | 276,516 | `58A671E38356` | 完整构建日志；停在 `Bitgen Completed Successfully`（Vivado 收尾挂起，位流已落盘） | `docs/29` §5 |
| `sim_tb_lowsig.log` | 13,446 | `93D404C44352` | `tb_lowsig` **35 checks PASS**（200/250/300 mVpp、标定、A/B） | `docs/29` §6 |
| `VARIANT_INFO.txt` | 441 | `74AA78761C93` | 源 git `b7d7f79`、生成时间、25+8 文件、4 处补丁 | `docs/29` §4 |

> ★ **引用规则（v67）**：只允许写 `[构建签核]` + `[仿真]`；**不得**出现 `[实测]`。上板前按
> `docs/29_lowsig_sensor_v67.md` §7，先读 `0x0000 = 0x000F`、`0x0101 = 32`、`0x0130 = 1`。
> ⚠ 本版**没有显示位流**；需要屏上 UI 时另按 `ENC_DISP_TAP` 复制，不要拿 v66 的显示位流顶替。

### §2.0e v71（2026-11-02，Z 索引脉冲修复）

| 文件 | 大小(B) | SHA256 | 说明 |
|---|---|---|---|
| `v71/enc_top_v71.bit` | 1,514,668 | `456279CD…` | 生产位流（BUILD 0x0016，转台用，无 `ENC_DISP_TAP`） |
| `v71/enc_top_disp_v71.bit` | 1,657,221 | `776438A7…` | 显示位流（`ENC_DISP_TAP` + `ENC_V69_CPR2048`） |
| `v71/prod_timing.rpt` | 115,978 | — | **WNS +0.277 / TNS 0 / 0 失败（24,785）**、WHS +0.047、WPWS +0.264 |
| `v71/prod_util.rpt` | 12,363 | — | LUT **10,968 / 20,800 = 52.73%**、FF 8,756 = 21.05%、BRAM 32/50 |
| `v71/disp_timing.rpt` | 117,766 | — | **WNS +0.143 / 0 失败（34,383）**、WHS +0.019、WPWS +0.264 |
| `v71/disp_util.rpt` | 12,457 | — | LUT **17,393 = 83.62%**、FF 11,557 = 27.78%、BRAM **48/50 = 96%**、DSP 19、IOB 107 |
| `v71/disp_eth_rx_paths.rpt` | 47,872 | — | 以太网 RXC 路径 slack **+1.907 ns（MET）** |
| `v71/prod_impl.log` / `disp_impl.log` | 276,674 / 484,384 | — | Vivado 2026.1 构建日志（`Bitgen Completed Successfully`） |
| `v71/VARIANT_INFO.txt` | 476 | — | 变体生成信息（源 git、时间、补丁清单） |
| `v71/README.md` | — | — | 根因、修法、签核表、上板待办、复现命令 |

**口径**：v71 的数字只到 `[构建签核]` + `[仿真]`；**未上板**（板卡 2026-11-01 夜断开）。

### §2.0f v73（2026-11-02，上板调试版：显示 RPM 除零修复 + Z 计数探针）

| 文件 | 大小(B) | SHA256 | 说明 |
|---|---|---|---|
| `v73/enc_top_v73.bit` | 1,489,772 | `2E081D4E…` | 生产位流（BUILD **0x0017**，含 Z 计数探针 `0x054A..0x054D`） |
| `v73/enc_top_disp_v73.bit` | 1,662,197 | `0567A4E6…` | 显示位流（`ENC_DISP_TAP` + `ENC_V69_CPR2048`），**已固化进板载 QSPI Flash** |
| `v73/prod_timing.rpt` | 112,912 | — | **WNS +0.220 / TNS 0 / 0 失败（24,889）**、WHS +0.049、WPWS +0.264 |
| `v73/prod_util.rpt` | 12,363 | — | LUT **11,008 / 20,800 = 52.92%**、FF 8,791 = 21.13%、BRAM 32/50 |
| `v73/disp_timing.rpt` | 119,949 | — | **WNS +0.328 / 0 失败（34,499）**、WHS +0.049、WPWS +0.264 |
| `v73/disp_util.rpt` | 12,457 | — | LUT **17,483 / 20,800 = 84.05%**、BRAM **48/50 = 96%** |
| `v73/disp_eth_rx_paths.rpt` | 46,787 | — | 以太网 RXC 路径 slack **+1.907 ns（MET）** |
| `v73/prod_impl.log` / `disp_impl.log` | 276,928 / 484,048 | — | Vivado 2026.1 构建日志（`Bitgen Completed Successfully`） |
| `v73/VARIANT_INFO.txt` | 253 | — | 变体生成信息（源 git `2f4c147`、时间、差异说明） |
| `v73/README.md` | — | — | 与 v71 的差异、签核表、上板实测、复现命令、未验证项 |

**口径**：v73 = `[构建签核]` + `[上板实测]` + `[冷启动]`：

- v71 生产位流（0x0016）全项实测通过（ADC 8657 Hz / 标定 / 角度 RMS 0.72° / 60 s 长跑 597,746 帧且 `|err|>5°`=0 / 以太网 ping+capture PASS）；
- v72（仅显示 RPM 除数位宽修复）板上确认屏上 RPM 从 **496729.5** 变为 **≈770–780**（实测 775.6 rpm）；
- v73 生产位流 Z 计数 **12.00 Hz → 720.0 rpm**（示波器 J5-7 亦见 ≈1.15 µs / ≈2.5 V 窄脉冲）；
- **Flash 固化 + 断电重上电**：屏正常启动、`RTL_BUILD=0x0017`、Z 12.26 Hz、遥测 10.9 kfps。
- 仍未做：UVW 三相相位、Z 停位喘振、2 h 长跑（详见 `docs/36_v72_v73_board_debug.md` §8）。
Z 修复的仿真证据：`tb_enc_top` **106 checks / 0 error**（`FWD/REV: Z_pulses=1`、`Z_width_max=2569 clk ≈ 5 个 A 边沿步`），
全量回归 **36/36 PASS**。根因与修法见 [`docs/34_audit_report.md`](../../docs/34_audit_report.md) §3 A6。

### 2.0d `v70/` — **转台 2048 PPR 验收通过**（位置计数 + UVW 反向修复；2026-11-01）

v68/v69 在真实转台上暴露两个功能缺陷，v70 修掉后**生产位流已上板实测通过**：

1. **位置计数全死**（`cycle_cnt` 恒 0）：`pole_counter.v` 的步进量写成"两个无符号 16 位相位各自补码符号扩展再相减"，
   角度越过 32768 后差值变成 −65403 而不是 +133，累加器净增恒 ≈0 ⇒ 多圈/Z/UVW/屏上 RPM 全废。
   修法：先做模 2^16 无符号差、再对**差值**符号扩展（`diff_u` → `step_s`）。
2. **UVW 反向卡死**（82% 停在 110）：`off_bwd = BND[r_sec] − eang` 没处理 0←65535 的唯一环绕边界。
   修法：`r_sec==0 && eang_x > BND[5]` 时改用 `65536 − eang_x`（与前向对 BND[1] 的特判同构）。

| 文件 | 大小 (B) | SHA256 前 12 | 说明 |
|---|---|---|---|
| `enc_top_v70.bit` | 1,517,496 | `48EACC...` | **生产位流**（v70，首次真机闭环），BUILD_ID=`0x0015`，WNS +0.091 / WHS +0.065，LUT 52.67%，BRAM 32/50 |
| `enc_top_v74.bit`（仓库根 `_impl_v74/`） | 1,512,664 | `E46349...` | **v74 期生产位流（历史）**，构建号见 `v74/README.md`，WNS **+0.4 ns 档** / WHS +0.025，LUT **52.5%**，BRAM 32/50；2026-11-02 上板验收 |
| `enc_top_disp_v70.bit` | 1,708,301 | `1081DC...` | **显示位流**（`ENC_V69_CPR2048`），WNS +0.027 / WHS +0.057，LUT 83.73%，BRAM 48/50 |
| `prod_*` / `disp_*` | — | — | 8 + 9 份实现报告（时序/资源/DRC/布线/时钟交互/顶层路径） |
| `VARIANT_INFO.txt` | — | — | 变体生成说明（3 条生成器补丁 + 3 个源文件修复） |

**上板实测（生产位流，2026-11-01 22:41）**：电周期速率 −24,543 ~ −24,962 cycles/s ⇒ 约 **720–731 转/分**（旧口径，v90 起改用 Z 频率判据）
（真实转速 25.27 kHz / 2048 × 60 = 740 rpm，转台略慢）；**Z 12.00 Hz**（= 731/60）；**UVW 六态均匀**（跳变 293/s）；
`cnt` 覆盖 −2047…0 共 2048 个值；r 峰值 0.843–0.864 FS；标定 gain 33776/33568（目标 0.80 FS）；以太网 ping + 28,672 点 UDP 抓窗通过。
**显示位流只做了构建签核，尚未上板目视**（板子 22:5x 断开）。

详见 `docs/33_v70_release_report.md`。

### 2.0g `v74/`（签核基线）与 `v85/`（最新显示构建）

**v74 = 当前时序签核基线**（编码器本体，无 UI、无网，2048 p/r 转台）：

| 文件 | 大小 (B) | SHA256 前 12 | 说明 |
|---|---:|---|---|
| `v74/enc_top_v74.bit` | 1,512,664 | `E4634907…` | 生产位流，v74 期构建号，WNS **+0.4 ns 档** / 0 失败（24,625），LUT **52.5%**，BRAM 32/50；2026-11-02 上板验收（约 720–740 转/分、Z ≈12 Hz、UVW 六态均衡、ping + UDP） |
| `v74/enc_top_disp_v74.bit` | 1,700,821 | `72FF4D13…` | v74 显示位流（WNS +0.422 / LUT 84.63%），**未目视验收**；后被 v85 取代 |
| `v74/prod_*` / `disp_*` | — | — | 生产/显示两套 timing / util / drc / route / io / top_paths / impl.log 报告 |

**v85 = 最新显示构建**（编码器 RTL 同 v74，仅 `disp/` 更新到 v75–v85）：

| 文件 | 大小 (B) | SHA256 前 12 | 说明 |
|---|---:|---|---|
| `v85/enc_top_disp_v85.bit` | 1,699,249 | `03F12968…` | 显示位流，WNS **+0.175** / 0 失败（35,126），LUT **86.96%**，DSP 26，BRAM 48/50；**2026-11-03 16:50:56 已下载**，未逐页目视验收 |
| `v85/disp_*` | — | — | v85 的 timing / util / drc / route / check_timing / clkint / io / top_paths / hold_paths / eth_rx_paths 报告 |
| `v85/disp_impl.log` / `prog_v85.log` | 503,244 / 7,712 | — | 构建日志（15:45–15:50）与 JTAG 下载日志（`PROGRAMMED_OK`） |
| `v85/README.md` | — | — | 与 v74 显示版的差异、复现命令、未验证项（**逐页目视仍未做**） |

> 口径：v74 是**签核 + 上板**，v85 是**构建签核 + 已下载**。参赛提交与时序签核
> 一律引用 v74；v85 只用于说明 UI 的持续演进，不得写成"已上板验收"。

### 2.0c `v68/` — 400 mVpp 单端正交 + **显示版**（64 周期/转；**未上板**）

**一句话**：400 mVpp 单端 × 4.16 = 0.832 FS，默认数字增益回到 **1.0** 正好落在 `[0.60,1.20]` 窗内；
与 v66 的差异只有 3 处文本替换（`POLE_BITS=6`、`BUILD_ID=0x0010`、`INTER0=32`），`GAIN_S/C`
保持 32768。与 v67 的区别是：v67 默认 1.5、只有生产位流；v68 默认 1.0、**生产 + 显示两个位流**。

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `enc_top_v68.bit` | 1,511,380 | `921FA2DCA4CB` | **v68 生产位流**（2026-10-30 17:24:49），无屏、无网；BUILD_ID=`0x0010` | `docs/30` §4.1 |
| `enc_top_disp_v68.bit` | 1,701,921 | `86E6BAB44575` | **v68 显示位流**（17:46:33），编码器 + 7" LCD + 千兆网；顶层 `enc_top_disp`、带 `ENC_DISP_TAP` + `ENC_V68_CPR64`（RPM 按 64 周期/转换算） | `docs/30` §4.2 |
| `prod_timing.rpt` | 110,609 | `5F9EED6AD353` | 生产 WNS **+0.144** / TNS 0.000 / **0 失败（24,648）**；WHS **+0.049** / 0 失败（24,183）；WPWS +0.264；约束全满足 | `docs/30` §4.1 |
| `prod_util.rpt` | 12,319 | `9644E1C72BE1` | 生产 LUT **10,928 = 52.54%**、FF 8,714 = 20.95%、BRAM **32/50**、DSP 17、IOB 63 | `docs/30` §4.1 |
| `prod_drc.rpt` | 24,356 | `250A84991233` | 生产 **0 Errors / 0 Critical Warnings**；45 Warning（DPIP×12 / DPOP-1×16 / DPOP-2×17） | `docs/30` §4.1 |
| `prod_route.rpt` | 651 | `5A2DDFBD9AAF` | 生产 18,578 条可布线网全布通、0 routing errors | `docs/30` §4.1 |
| `prod_clkint.rpt` | 3,478 | `6378731FD7FD` | 生产时钟交互（sys 50 / adc 50 / eth 125 / clk_200 200 MHz） | 索引 §1.3 |
| `prod_top_paths.rpt` | 482,321 | `E6694C191944` | 生产最差 20 条 setup 路径明细 | `docs/30` §4.1 |
| `prod_io.rpt` | 148,321 | `8D5D113959AF` | 生产引脚分配/IO 标准 | `docs/30` §4.1 |
| `prod_check_timing.rpt` | 3,351 | `23E2F5855549` | 生产 0 no_clock / 0 unconstrained endpoint | `docs/30` §4.1 |
| `prod_impl.log` | 276,872 | `B0C36D8FD974` | 生产完整构建日志；停在 `Bitgen Completed Successfully`（Vivado 收尾挂起，位流已落盘） | `docs/30` §4.1 |
| `disp_timing.rpt` | 118,869 | `E47125AFCBB6` | 显示 WNS **+0.345** / TNS 0.000 / **0 失败（34,281）**；WHS **+0.047** / 0 失败（33,816）；WPWS +0.264 | `docs/30` §4.2 |
| `disp_util.rpt` | 12,457 | `D717D0CC3F2E` | 显示 LUT **17,414 = 83.72%**、FF 11,528 = 27.71%、BRAM **48/50 = 96%**、DSP 19、IOB 107 | `docs/30` §4.2 |
| `disp_drc.rpt` | 56,385 | `345B975FE07B` | 显示 99 checks，**0 Error / 0 Critical Warning**（BUFC/DPIP/DPOP/RBOR/REQP 等 Warning） | `docs/30` §4.2 |
| `disp_route.rpt` | 651 | `AC05EF269F98` | 显示 27,875 条可布线网全布通、0 routing errors | `docs/30` §4.2 |
| `disp_clkint.rpt` | 3,484 | `061EB5A689F0` | 显示时钟交互 | 索引 §1.3 |
| `disp_top_paths.rpt` | 549,663 | `D971B33753BE` | 显示最差 20 条 setup 路径明细 | `docs/30` §4.2 |
| `disp_io.rpt` | 148,327 | `25A57AC6D2C6` | 显示引脚（LCD/触摸/网口） | `docs/30` §4.2 |
| `disp_check_timing.rpt` | 3,425 | `3F7B613C582A` | 显示 0 no_clock / 0 unconstrained endpoint | `docs/30` §4.2 |
| `disp_eth_rx_paths.rpt` | 47,874 | `AFD47236645F` | `report_timing -group eth_rxc_clk` 最差 slack **MET 1.907 ns** | `docs/30` §4.2 |
| `disp_impl.log` | 483,074 | `66954EB73702` | 显示完整构建日志；同样停在 Bitgen | `docs/30` §4.2 |
| `sim_tb_v68.log` | 13,285 | `1F6211B998E2` | `tb_v68` **37 checks PASS**（400/450/350 mVpp、标定、1.5 A/B） | `docs/30` §5 |
| `VARIANT_INFO.txt` | 560 | `DE677B025909` | 源 git `086df12`、生成时间、25+8 文件、3 处补丁、两条构建命令 | `docs/30` §3 |

> ★ **引用规则（v68）**：只允许写 `[构建签核]` + `[仿真]`；**不得**出现 `[实测]`。上板前按
> `docs/30_v68_400mvpp_display.md` §6，先读 `0x0000 = 0x0010`、`0x0101 = 32`、`0x0130 = 1`、
> `0x0514/15 = 0x8000`。⚠ 生产与显示是**两个位流**：显示版必须带 `ENC_DISP_TAP` + `ENC_V68_CPR64`，生产版绝不能带；
> 显示版 BRAM 48/50（96%），不要再加帧缓冲/页。

### 2.1 `bitstreams/` — v12 现行位流 + v11 历史位流

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `enc_top_v12_prod.bit` | 1,042,208 | `D93DEBF92034` | **当前生产位流（v12）**，2026-10-12 23:59:27 生成（`RTL_BUILD_ID` = 0x000C、遥测帧布局 v2）；回读判据 `0x05F2` = **`0x000C`**（未换版则仍是 `0x000B`）；对应时序 WNS **+0.959** / TNS 0.000 / **0 个失败端点**（11,275 端点）、结论行 `All user specified timing constraints are met.`；★ 压缩算术可复核：`Bitstream compression saved 9200096 bits` ⇒ 17,537,696 − 9,200,096 = 8,337,600 bit = 1,042,200 B + 8 B 头 = 1,042,208 B | 报告 §6.5(2)、索引 §1（v12 现行） |
| `enc_top_v12_ila.bit` | 1,428,064 | `5CC779EE6D00` | v12 ILA 调试构建位流，2026-10-13 07:12:11 生成（`RTL_BUILD_ID` = 0x000C）；时序 `All user specified timing constraints are met.`（WNS +0.332 / 0 失败 / 20,165 端点）；资源 LUT 9234 = 44.39% / FF 8937 = 21.48% / BRAM 7.5 = 15.00%；压缩算术：saved 6,113,248 bits ⇒ 11,424,448 bit = 1,428,056 B + 8 = 1,428,064 B | 报告 §6.5、索引 §1（v12 ILA） |
| `enc_top_v12_ila.ltx` | 71,337 | `B32B1C44AAD7` | 上述 v12 ILA 位流的探针/触发配置文件（2026-10-13 07:12:00；36 条命名探针 / 269 bit，与 v11 相同） | 索引 §1（v12 ILA） |
| `enc_top_v11_prod.bit` | 1,086,600 | `FA1308647D77` | **v11 历史生产位流**（已归档、被 v12 取代），2026-10-12 21:15:37 生成；回读 `0x05F2` = `0x000B`（版本 11）；时序 WNS +0.821，0 个失败端点（11,310 端点） | 报告 §6.5(2)、索引 §1（v11 历史行） |
| `enc_top_v11_ila.bit` | 1,458,744 | `5E049FD3B3EA` | **v11 历史 ILA 调试构建位流**（已归档），2026-10-12 21:29:54 生成；时序同样 `All user specified timing constraints are met.`；**图 6-3（v9 vs v11 对比）所用的抓包位流** | 报告 图 6-3、索引 §1（v11 ILA 历史行） |
| `enc_top_v11_ila.ltx` | 71,337 | `B32B1C44AAD7` | 上述 v11 ILA 位流的探针/触发配置文件（与 v12 版的 `.ltx` 逐字节相同），抓包与 `capture_v11_summary.txt` 的构建记录对应 | 索引 §1（v11 ILA 历史行） |

> ⚠ **`.bit` / `.ltx` 为逐字节原样拷贝，未做行尾转换**，故其 SHA256 与 `_synth_work/` 源文件**完全相同**（例：`enc_top_v12_prod.bit` = `_synth_work/enc_top.bit` = `D93DEBF92034FF23…`，2026-10-12 23:59:27 / 1,042,208 B）。

### 2.2 `timing/` — Vivado 签核报告

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `impl_timing.rpt` | 62,302 | `EA3C5E753F49` | **当前签核（v12 生产，2026-10-12 23:59:16）**。结论行 `All user specified timing constraints are met.`；WNS **+0.959** / TNS 0.000 / 失败端点 **0** / 端点总数 **11,275**；WHS **+0.075**（0 失败 / 11,275）；WPWS **9.500**（0 失败 / 4,080）；最差路径 `u_regs/r_ablimit_reg[2]/C` → `u_abz/r_hold_reg[0]/R`（数据路径 18.615 ns：logic 7.797 / route 10.818，28 逻辑级）。副本对应 `_synth_work/impl_timing.rpt`（逐字节原样，**CRLF，未做行尾转换**） | 报告 §6.5、索引 §1（v12 签核） |
| `impl_util.rpt` | 11,236 | `6DD24971BD41` | **当前签核（v12 生产资源，23:59:14）**：Slice LUT **6298 / 20800 = 30.28%**、Slice Registers **4074 / 41600 = 9.79%**、Block RAM **0 / 50**、DSP **16 / 90 = 17.78%**、Bonded IOB **50 / 250 = 20.00%**、BUFGCTRL **1 / 32 = 3.13%** | 索引 §1（v12 资源） |
| `impl_ila_timing.rpt` | 115,190 | `30A9BEFE980A` | **当前签核（v12 ILA，2026-10-13 07:11:57）**，结论行同为 `All user specified timing constraints are met.`；WNS **+0.332** / TNS 0.000 / **0 个失败端点 / 20,165 端点**；WHS +0.050（0 失败 / 20,149）；WPWS 8.870（0 失败 / 9,858） | 索引 §1（v12 ILA） |
| `impl_ila_util.rpt` | 12,078 | `85DB1BB1952E` | **当前签核（v12 ILA 资源，07:11:57）**：Slice LUT **9234 = 44.39%** / Slice Registers **8937 = 21.48%** / Block RAM **7.5 = 15.00%** / DSP **17 = 18.89%** / Bonded IOB 50 / BUFGCTRL **2 = 6.25%** | 索引 §1（v12 ILA） |
| `impl_timing_v11_2026-10-12.rpt` | 60,404 | `F3B2BFB36C89` | **历史（v11 生产，2026-10-12 21:15:26）**，已被 v12 取代：结论行 `All user specified timing constraints are met.`；WNS **+0.821** / TNS 0.000 / 失败端点 **0** / 端点总数 11,310；WHS +0.058；时钟周期 10.000 ns；最差路径 `u_abz/idx_prod/P[15]` 3.076 / 9.887。归档时由原 `timing/impl_timing.rpt` 改名保留（**LF 转换版**，故与 `_synth_work` 源文件哈希不同，见 §5.1） | 索引 §1（v11 历史行） |
| `impl_util_v11_2026-10-12.rpt` | 11,236 | `874B261AEC29` | **历史（v11 生产资源）**：Slice LUT **6369 = 30.62%** / FF **4088 = 9.83%**（v12 相对 v11：LUT −71、FF −14） | 索引 §1（v11 历史行） |
| `impl_ila_timing_v11_2026-10-12.rpt` | 115,745 | `C25C9251077E` | **历史（v11 ILA，2026-10-12 21:29:41）**：结论行同为 `All user specified timing constraints are met.`（route 估计 WNS 0.565 / WHS 0.047） | 索引 §1（v11 ILA 历史行） |
| `impl_ila_util_v11_2026-10-12.rpt` | 12,078 | `F1DB194A41D6` | **历史（v11 ILA 资源）** | 索引 §1（v11 ILA 历史行） |
| `impl_timing_v9_2026-10-11.rpt` | 54,046 | `1D585D04397D` | **历史对照**：v9 生产时序（2026-10-11 19:11:20），WNS **−3.274** / TNS −84.267 / 失败端点 26 / 端点总数 11,298 | `photo_shot_list.md:40`（P0-1） |
| `impl_ila_timing_v9_2026-10-11.rpt` | 107,964 | `D314222D6A1C` | **历史对照**：v9 ILA 时序，WNS **−3.323** / TNS −84.833 / 失败端点 26 / 端点总数 20,198 | `photo_shot_list.md:41`（P0-2） |

> v9 两份报告的 TNS / 端点数与 P0-1、P0-2 所载数字有细微差异（WNS 完全一致），说明它们是同一 v9 版本的相邻两次运行；引用时请以 WNS 为准，详见 §5.2。
>
> ⚠ **改名而非删除**：2026-10-13 归档 v12 时，先把工作副本里的 v11 那一轮报告本目录内改名为 `*_v11_2026-10-12.rpt` 再覆盖（`impl_timing.rpt` 60,404 → 62,302 B；`impl_ila_timing.rpt` 115,745 → 115,190 B；两份 util 均为 11,236 / 12,078 B，大小不变但哈希改变）。v11 历史行**全部保留**，见 §5.1、§5.8。

### 2.3 `ila/` — 报告插图所依据的原始 ILA 抓包

所有 CSV 均为 **1024 采样 / 39 列 / 134,738 B**，第 1 行为信号名、第 2 行为 `Radix - UNSIGNED,...`。关键列（0 起始下标）：`6` = `dbg_ang_glitch`、`12` = `dbg_c_raw[11:0]`、`27` = `dbg_s_cor[15:0]`、`28` = `dbg_s_dec[15:0]`、**`29` = `dbg_s_raw[11:0]`**。

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `ila_cmp_v9_glitch.csv` | 134,738 | `CDB790DED117` | **D 支路缺陷的直接铁证**。热工作点下 v9 抓包：`dbg_ang_glitch` 命中 **1/1024**；原始码下标 **486** 处 `s_raw` 由 `0x9FF` 跳到 `0x300`，即**单采样 +2305 LSB**（有符号 12 位 −1537→+768），下一拍 487 恢复；同窗口 `c_raw` 全程干净（`0xdfb→0xe00→0xe03`，+5/+3）。全抓包中 \|Δ\| > 40 LSB 的跳变**仅此一对**。为**图 6-3 左列**数据源 | 报告 图 6-2、图 6-3；`capture_v11_summary.txt` 注记 `glitch=1, center idx=486, s_raw=0x300` |
| `ila_cmp_v11_clean.csv` | 134,738 | `C20B668857D4` | **修复对照**。同一热工作点 v11 抓包：`dbg_ang_glitch` **0/1024**；全窗口无超限原始码跳变。为**图 6-3 右列**数据源 | 报告 图 6-3 |
| `ila_cap_v9_glitch1.csv` | 134,738 | `4B7BB8EA0BFA` | v9 缺陷抓包（簇 1），图 6-1 / 6-2 的原始数据之一 | 报告 图 6-1、图 6-2 |
| `ila_cap_v9_g82_1.csv` | 134,738 | `93C8271B03F0` | v9 缺陷抓包（簇 2），图 6-1 / 6-2 的原始数据之一 | 报告 图 6-1、图 6-2 |
| `ila_cap_v9_glitch2..4.csv` | 134,738 | `7820095535DC` / `C29FEC120C85` / `AD49BA6E2E88` | 同上簇的重复抓包，用于确认缺陷可复现 | 报告 §6 佐证 |
| `ila_cap_v9_g197_1..4.csv` | 134,738 | `3DB81B4A726B` / `9DF3CAB64B70` / `EC6AB313234D` / `A75B71D45309` | 缺陷在不同圈数位置（197 圈）的抓包，证明与转角位置无关、是支路逻辑缺陷而非采样异常 | 报告 §6 佐证 |
| `ila_cap_v9_g82_2.csv` | 134,738 | `EDF4C9D0E220` | 簇 2 的重复抓包 | 报告 §6 佐证 |
| `ila_cap_v9_amp76.csv` / `_amp80_ctrl.csv` / `_amp82.csv` | 134,738 ×3 | `2394E7B56D7C` / `21FB226E849D` / `29A0E34B7CAE` | 不同激励幅度（76 / 80 对照 / 82）下的抓包，用于排除"仅高幅度才出现"的解释 | 报告 §6 佐证 |
| `ila_cap_v9_dbg_state.csv` / `_freqcheck.csv` | 134,738 ×2 | `840B4386F1A4` / `DE3C6A91F7EE` | 内部状态与频率自检抓包，用于排除时钟/频率异常 | 报告 §6 佐证 |
| `ila_cap_v9_z.csv` / `_z0.csv` | 134,738 ×2 | `59EE418C6E8C` / `F5CF2FEFB1D9` | Z 相窗口相关抓包，用于定位故障发生的相区 | 报告 §6 佐证 |
| `ila_hot_v9_a.csv` / `_b.csv` | 134,738 ×2 | `EED6F27D552C` / `E091F19FA531` | 热工作点下的两次独立 v9 抓包，证明缺陷在"热态"稳定复现 | 报告 §6 佐证 |

### 2.4 `logs/` — 实验记录

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `hot_ab.txt` | 2,756 | `4099A715ACD3` | **热态自动 A/B/A**（10-12 21:07:20 起）。A1 v9 = **907 事件/30 s** → B v10 = **0** → A2 v9 = **681**；OTR `0x0405` 依次为 `0x0021`(otr+amp) → `0x0000` → `0x0025`(otr+laglim+amp) | `deliverables/README.md:56`、`docs/DEV_STATUS.md:3146` |
| `hot_ab_run1.txt` | 2,767 | `9C941E000C07` | **反面样本**：更早一次同型实验（20:57–21:00）因用户仍在旋动幅度旋钮而受污染（监视窗口一度 252.20/s、243.40/s，A1 v9 计得 4,780 事件），故**不采用**，保留以说明筛选过程 | `docs/DEV_STATUS.md` 相关段 |
| `verify_v11.txt` | 1,557 | `A5F8851A8350` | **v11 首次上板验证**：下载前 v9 30 s 窗口 = **868 事件**，下载后 v11 = **0**；`0x05F2` RTL_BUILD_ID = **11**；OTR `0x0405` 由 `0x0025`(otr+laglim+amp) 变为 **`0x0024`(laglim+amp)——OTR 位被修复清除** | `索引:61`、`deliverables/README.md:56` |
| `bracket_v11.txt` | 2,548 | `E8D2787C4A1D` | **v11→v9→v11 夹逼实验**，三个 60 s 窗口 = **0 → 3,320 → 0** 事件。三次窗口内半径均值**单调上升** 25653.5 → 26078.0 → 26196.2（+2.1%），据此**排除"工况漂移导致 v9 不出错"的解释** | `索引:61`、`deliverables/README.md:56` |
| `capture_v11_summary.txt` | 4,357 | `02E25E8046DE` | **v11 ILA 对照抓包记录**：stage1 窗口 0 次毛刺；随后武装 `ang_glitch` 触发器限时 60 s，**始终未触发**（`fired=0 elapsed=60,114 ms`），即 v11 在同样条件下 60 s 内连一次缺陷都抓不到。另含位流 SHA256 与 `0x05F2`=`0x000B` 回读记录 | `索引:161` |
| `phase_aba_prod.txt` | 2,410 | `1D22A35A2D2C` | **每相 600 s 的 A/B/A 长时实验**（17:06:35–17:37:43）：A1 v9 = **3** 事件 → B v10 = **0** → A2 v9 = **7**；OTR 全程 `0x0024`。统计判据 Poisson P(K≤0 \| λ=5.0) = **6.74e-3** | 报告 §6、索引 §8 |
| `sweep3.csv` | 4,024 | `66792EABCF7C` | **固定刻度下 10 分钟无人值守速率日志**（120 行 / 步长 5 s / 覆盖约 595 s），热平台速率 **12–55.198 次/s**，证明"热工作点"是真实工况而非旋钮噪声。注：`21:08:29` 一行速率 11,601.797 属 v10 下载窗口内的计数器复位伪值，见 §5.4 | `deliverables/README.md:56`、`docs/DEV_STATUS.md:3140,3159` |
| `sweep2.csv` | 4,302 | `1C4DE9F92F0F` | 同类速率扫描的上一轮记录，与 `sweep3.csv` 互为对照 | `deliverables/README.md:56` |
| `temp_v9_amb.csv` | 284 | `445C54673CF9` | **温度实验·常温**：v9 常温基准 | `09_scope_measure_log.md:87-92`、`docs/DEV_STATUS.md:3251-3256` |
| `temp_v9_heat.csv` | 1,464 | `8935FBD514D4` | **温度实验·热态（v9）**：热态下 v9 由 **0 / 150 s 恶化到 14→50 事件/s**；`gl_2048/gl_1024` 比值由约 **3% 升至 30%** | 同上 |
| `temp_v9_cool.csv` | 1,517 | `C125EF265CE7` | **温度实验·回冷（v9）**：证明错误率随温度回落，把缺陷钉在热态 | 同上 |
| `temp_v9_hotb.csv` | 956 | `D8ABB9114DF7` | 热态重复测量（v9 第二次），确认非偶发 | 同上 |
| `temp_v11_heat.csv` | 973 | `F4D430EC9116` | **热态交叉对照（v11）**：同一热状态下 v11 = **0 / 120 s**，即温度不是 v11 的短板 | 同上 |
| `temp_v11_hotb.csv` | 786 | `047293DC9CA0` | 热态重复测量（v11 第二次） | 同上 |
| `ladder.csv` | 639 | `CFA10CAE24F3` | 阶梯设置记录（3 行：`now_unknown` / `verify` / `set_8p15`），是速率—刻度标定的依据 | 报告 §6 佐证 |
| `ila_build_v11_summary.txt` | 184 | `37A57B91EF0B` | v11 ILA 构建包装脚本记录：21:25:13 启动，并备份了 v10 ILA 位流 | `索引 §8` |
| `dl_phase_aba.log` | 8,078 | `A16FD7881727` | `phase_aba_prod` 实验的下载/运行原始日志 | `索引 §8` |

### 2.4a 李萨如素材 + 标定重复性（2026-10-13，P1-1 / P1-1b / P1-1c）

> ★ **命名语义**：`lissajous_capture.py` 按"抓图时刻屏上状态"命名 ⇒ `*_distortion` = **板上被注入了畸变**时抓的（`before` = 未标定、`after` = 一键标定后）；**无后缀**那组 = 恢复健康系数后抓的（两组都 0.101 %，只作健康基线）。
> ★ 注入配方（可用 `tools/calib_snapshot.py inject` 一条命令复现）：`--offset 3000 --offset-c -3000 --gain-mismatch 1.25 --quad-deg 3`（写 6 条失败 0 条）；测完**必须 restore**，否则板上留着被注入的系数。

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `../figures/lissajous_before_distortion.png` | 106,991 | `32F9398F31EF1C71…` | **注入畸变后、未标定**：圆度偏差 RMS **17.786 %**、半径峰峰 17,594.5–33,496.6（斜椭圆） | 视频第 3 段；报告 §5 |
| `../figures/lissajous_after_distortion.png` | 114,257 | `DEF7ECDB6F6DA190…` | **同一注入后、一键标定完**：RMS **0.101 %**、半径 mean 26,213.8（正圆）⇒ 改善 ≈ **176×** | 同上 |
| `../figures/lissajous_before.png` | 108,225 | `7B1288352A7008CD…` | 健康系数下的基线抓图（RMS 0.101 %），只作对照 | 报告 §5 |
| `../figures/lissajous_after.png` | 114,342 | `BB1C5A63980861D2…` | 同上（再标定一次，RMS 0.101 %） | 报告 §5 |
| `lissajous_before_distortion.csv` | 4,241,395 | `3398F4F1F74B0459…` | 上表第 1 行的**原始遥测帧** | 索引 §3A 前 |
| `lissajous_after_distortion.csv` | 4,153,320 | `F663B80EB5AA9FCE…` | 上表第 2 行的原始帧 | 同上 |
| `lissajous_before.csv` | 4,174,509 | `85B37517996CD246…` | 健康基线原始帧 | 同上 |
| `lissajous_after.csv` | 4,157,602 | `CE3AF847625CEBDE…` | 健康基线原始帧（再标定后） | 同上 |
| `lissajous_summary.csv` | 794 | `E5675DF3F14540F6…` | 四次采集的汇总（半径 / 圆度 / 状态位 / 帧数） | 索引 §4 |
| `calib_repeat_summary.csv` | 606 | `166048418AFDD049…` | **一键标定重复性 12/12 GOOD**：`ofs_s` 40–42（极差 2、σ 0.6）、`ofs_c` 357–364、`gain_s` 33,011–33,016、`gain_c` 33,307–33,312、`phase_k` 97–98、`shift` 0、`retry` 0、`win_bad` 0。★ 未解释项：`trunc` 12/12 为 1、第 9 轮 `stat` 高字节为 1（工具 verdict 仍 GOOD） | `docs/DEV_STATUS.md` §1.68 D |

### 2.5 `telemetry_abz_uvw.csv` — 串口遥测原始帧（v12 帧布局 v2，实机 30 s）

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `telemetry_abz_uvw.csv` | 25,237,925 | `1EEC84B077AE` | **"上位机实时看 ABZ/UVW"的原始证据（2026-10-13 实机）**。30 s / **298,749 帧**，每帧 20 列（`idx…stat, flags, layout, io_state, io_flags, a,b,z,u,v,w,dir,limiter`）。列 `layout` 全为 `v2`、`io_state` 即偏移 8 ⇒ 帧内电平有效；统计结果 **A 50.0% / B 49.9% / Z 0.1%**（跳变 1405 / 1340 / 488），**UVW 六种合法状态均衡**（`001:50853 010:49248 011:49188 100:49168 101:51021 110:49271`，无 `000`/`111`），**等效采样填充率 64/64 箱**、`dir` 恒 1、`limiter` 恒 0、状态位无告警。由 `tools/demo_abz_uvw.py --port COM3 --seconds 30 --archive` 一条命令采出（`--no-write` 时板载配置须自行先设 `inter`=32 / `uwven`=1） | `../figures/telemetry_abz_uvw.png`、报告 §4.4（UART 遥测行）、索引 §1（v12 现行）、`../photo_shot_list.md:66`（P2-7）、`docs/DEV_STATUS.md` §1.59 |

> 配套图 `../figures/telemetry_abz_uvw.png`（120,686 B，SHA256 `CF8D3B1985B0…`）是同一段数据的 3×2 图：第 1 行李萨如 + 角度、第 2 行 ABZ/UVW 按时间的电平阶梯（A/B 因边沿率 ≫ 10 kHz 帧率而混叠，属预期）、**第 3 行按电角度 64 箱的等效采样**（A/B 正交、UVW 六步、Z 一个窄脉冲）。

### 2.6 `freq_ladder_summary.csv` + `freq_*.csv` — 频率阶梯（P1-3，2026-10-13 起）

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `freq_ladder_summary.csv` | 782 | `CF9B3EFC43B2AAA0…` | **频率阶梯的原始采集汇总表**（各频点的半径/圆度/状态/帧数/CRC 错/滞后，由 `tools/freq_ladder.py` 追加）。2026-10-13 有两行：**1 kHz**（半径 mean 26,214.4 / min 26,092.5 / max 26,337.7、圆度 RMS 0.101 %、`OK(no-alarm)`、有效帧 149,363、`crc_err` 571）与 **10 kHz**（mean 26,222.6 / min 26,093.1 / max 32,357.1、圆度 RMS 0.125 %、状态 `inclim=1, laglim=1, res=1`、有效帧 149,416、`crc_err` 500）；`lag_deg` 两行都空（需 ILA）。★ **10 kHz 那行的 `radius_max` 与 `status` 是坏帧污染的原始口径**，见下方 `freq_robust_summary.csv` 与 §2.6a | §1.69 / §1.71；`deliverables/evidence_index.md` §3A |
| `freq_1k.csv` | 1,247,689 | `304E122B2B3CAA33…` | **1 kHz 原始遥测帧**（21 列）。⚠ **本文件是 15000 行摘录**（原采 15 s / 149,363 行 / 12,571,691 B）；摘录只为控制仓库体积。摘录内坏帧 0/15,000 | `../figures/freq_1k.png` |
| `freq_10k.csv` | 1,278,779 | `EC4B3A18204ECF0E…` | **10 kHz 原始遥测帧**（21 列）。⚠ **本文件是 15000 行摘录**（原采 15 s / 149,416 行 / 12,631,178 B，全量在 `_synth_work/freq_10k_full.csv`）；摘录内坏帧 0/15,000（全量里有 1 个坏帧，`idx`=41376） | `../figures/freq_10k.png` |
| `freq_50k.csv` | 1,328,942 | `67297FA185E50E58…` | **50 kHz 原始遥测帧**（21 列）。⚠ **本文件是 15000 行摘录**（原采 15 s / 149,356 行 / 13,474,462 B，全量在 `_synth_work/freq_50k_full.csv`）；摘录内坏帧 0/15,000。★ 该点 `stat` bit3 恒置位是 `uvw_freq_warn`（`limiter_active` 实测 0/149,356），**不是**输入过速 | §1.73；`deliverables/evidence_index.md` §3A |
| `../figures/freq_1k.png` | 111,819 | `1D2F0C47226724AD…` | 1 kHz 点的李萨如 + 角度/半径图 | 报告 §6.3（待定稿填入） |
| `freq_100k.csv` | 1,342,133 | `5246B9972ADD4B20…` | **100 kHz 原始遥测帧**（21 列）。⚠ **本文件是 15000 行摘录**（原采 15 s / 149,381 行 / 13,475,522 B，全量在 `_synth_work/freq_100k_full.csv`）；摘录内坏帧 0/15,000。板上 `0x0540` 短窗反测 **100,051.8 Hz**（0.08 s 窗三次 100,046.3 / 100,058.1 / 100,051.1——★ 1 s 长窗会因多次回绕给假值）。★ 该点 `stat` bit3 同样恒亮（`inclim`），语义同 50 kHz（`uvw_freq_warn`，机理见 §1.74） | §1.74；`deliverables/evidence_index.md` §3A |
| `../figures/freq_100k.png` | 130,930 | `E55CF5C6894E9150…` | 100 kHz 点的李萨如 + 角度/半径图 | 报告 §6.3（待定稿填入） |
| `freq_200k.csv` | 1,332,640 | `E9CA4DC61C886273…` | **200 kHz 原始遥测帧**（21 列）。⚠ **本文件是 15000 行摘录**（原采 15 s / 149,356 行 / 13,458,389 B，全量在 `_synth_work/freq_200k_full.csv`）；摘录内坏帧 0/15,000（全量里有 1 个）。板上 `0x0540` 短窗反测 **≈200,004 Hz**。★ **本点临时把 `0x0101` 从 `0x0020` 降到 `0x0010`（inter 32→16），跑完已复原并回读确认**，故 `inter` 与其余四点不同。★ 工具状态栏里那一长串 `adapt/lagfatl/laglim/oflow/scamp` **全部来自全量里的那 1 个坏帧**；逐帧统计后真实告警只有 `inclim` + 36 帧（0.024 %）`laglim`，`limiter_active` 0/149,356 | §1.75；`deliverables/evidence_index.md` §3A |
| `freq_500k.csv` | 1,338,373 | `E32F6C5111C06A5B…` | **500 kHz 原始遥测帧**（21 列）。⚠ **本文件是 15000 行摘录**（原采 15 s / 149,380 行 / 13,468,924 B，全量在 `_synth_work/freq_500k_full.csv`）；**摘录内坏帧 1 / 全量坏帧 4**（坏帧特征：`sqrt(amp_sq)` = 52,168.8、`hypot` 偏离中位 34–71 %）。板上 `0x0540` **0.018 s 短窗**反测五次 **500,273.2 / 500,826.2 / 501,145.5 / 501,415.2 / 501,173.9 Hz**（★ 500 kHz 下 `0x0540` 每 0.131 s 就回绕，**必须用 ~15–20 ms 窗**）。★ **本点临时把 `0x0101` 从 `0x0020` 降到 `0x0008`（inter 32→8），跑完已复原并回读确认**；★ 工具状态栏那一长串告警同样全来自 4 个坏帧，逐帧统计后真实告警仍只有 `inclim`（`uvw_freq_warn`），**没有 `laglim`/`lagfatl` 持续告警**，`limiter_active` 0/149,380 | §1.76-频率阶梯；`deliverables/evidence_index.md` §3A |
| `../figures/freq_200k.png` | 147,934 | `213AFF1BDC6BDDD7…` | 200 kHz 点的李萨如 + 角度/半径图 | 报告 §6.3（待定稿填入） |
| `../figures/freq_500k.png` | 169,566 | `FF0FC6C9E44DD864…` | 500 kHz 点的李萨如 + 角度/半径图 | 报告 §6.3（待定稿填入） |
| `../figures/freq_10k.png` | 112,673 | `6D4A036B6723ABCA…` | 10 kHz 点的李萨如 + 角度/半径图 | 报告 §6.3（待定稿填入） |
| `../figures/freq_50k.png` | 128,999 | `B131648B1D10FD38…` | 50 kHz 点的李萨如 + 角度/半径图 | 报告 §6.3（待定稿填入） |

### 2.6a `freq_robust_summary.csv` — 频率阶梯的**稳健口径**（推荐引用这一张）

| 文件 | 大小 | SHA256 | 证明什么 | 引用 |
|---|---:|---|---|---|
| `freq_robust_summary.csv` | 584 | `12AE1A3476360C36…` | 由新工具 `tools/robust_radius.py` 对归档摘录重算：`file / frames / median / p0.1% / p1% / p99% / p99.9% / min / max / bad_frames`。**1 kHz**：中位 **26,213.9**、min 26,093.9、max 26,321.1、坏帧 **0**（分位圆度 `(p99.9−p0.1)/中位` = **0.627 %**）；**10 kHz**：中位 **26,215.2**、min 26,141.2、max 26,282.4、坏帧 **0**（**0.430 %**）；**50 kHz**：中位 **26,210.0**、min 26,078.7、max 26,289.5、坏帧 **0**（**0.620 %**）；**100 kHz**：中位 **26,197.0**、min 26,083.2、max 26,284.5、坏帧 **0**（**0.573 %**）；**200 kHz**：中位 **26,201.3**、min 26,059.3、max 26,304.2、坏帧 **0**（**0.665 %**）；**500 kHz**：中位 **26,117.3**、min 25,994.9、max **52,168.8（就是那个坏帧）**、坏帧 **1**（**0.636 %**）。⚠ 标度 = **`半径 = sqrt(amp_sq)`**（与 `uart_scope.py` 的 `hypot(s,c)` 逐帧一致，中位偏差 0.0000 %）——旧文档写的 "Q2.30" 在这列上不成立。★ 圆度有两套口径：本表是**分位口径**（抗坏帧），`freq_ladder_summary` 是 `std/mean` 的 **RMS 口径**（0.101 % / 0.125 % / 0.116 % / 0.093 % / 0.143 % / **0.211 %**），两者不可直接比，引用时写明用的是哪一套。★ **六点前五点同量级、无趋势**（中位 26,197–26,215，漂移 < 0.1 %）；**500 kHz 中位低约 0.36 %、RMS 0.211 % 为六点最大** ⇒ 第一条可能的"频率越高越差"弱信号，但该点 `inter` = 8、且 `lag_deg` 六点全缺（需 ILA）⇒ **不能单独当结论**。该口径量的是"采集窗口内半径一致性"，**不能读成编码器精度趋势** | §1.71 / §1.73 / §1.74 / §1.75 / §1.76-频率阶梯；`deliverables/evidence_index.md` §3A |

> ⚠ **1 kHz 这一点是"AFG 恰好停在 1 kHz"时采的**，不是脚本改频后采的；**10 kHz / 50 kHz / 100 kHz / 200 kHz / 500 kHz 是用户手工改频**（脚本不读 AFG，只能由板上 `0x0540` **短窗**反测的 **9,990.8 / 49,988.3 / 100,051.8 / 200,004 / 500,658.8 Hz** 背书；★ 反测窗口必须远小于回绕周期 `65536/f_in` —— 100 kHz 是 0.655 s、200 kHz 是 0.328 s、**500 kHz 只有 0.131 s**）。**六点已于 2026-10-13 全部采完**；`0x0101` 在 200k/500k 两点临时降到 16/8 并**均已复原回 `0x0020`（回读确认）**。
> ⚠ **每个频点采完都要跑一次 `python tools\robust_radius.py deliverables\data\freq_<点>.csv`**，把 `bad_frames` 与中位/分位数记下来；只报 `freq_ladder.py` 的 `radius_max`/`status` 会被 1 个坏帧带偏（10 kHz 就是实例）。

## 3. 完整性校验

`SHA256SUMS.txt`（现 **323 条**，2026-11-04 复核）覆盖 **本目录 304 个数据文件 + `../figures/` 的 19 张 PNG**，格式 `<SHA256>␠␠<相对路径>`（相对 `deliverables/data/`），**按哈希升序排序**、哈希大写、CRLF 行尾。清单**不含自身**（会自我引用）与 `.gitkeep`，要核清单本身请现算：`Get-FileHash SHA256SUMS.txt -Algorithm SHA256`。
**`v62/` 13 件、`v66/` 20 件、`v67/` 12 件、`v68/` 25 件、`v70/` 24 件、`v71/` 26 件、`v73/` 26 件、`v74/` 26 件与 `v85/` 16 件均已进清单**（各版本目录内的 `README.md` 一并收录；`.rpt` / `.log` 等按原始字节入库，`.gitattributes` 已对 `deliverables/data/**` 设 `-text -diff`，故克隆后哈希不变）。
本清单已在仓库工作树内逐行实测：**299/299 通过**（2026-11-03 定稿前对全部条目重算，含本 README 自身与 `../figures/block_diagram.png`）。在本目录下执行：

```bash
sha256sum -c SHA256SUMS.txt        # Linux/macOS
```

> ★ **历史（2026-10-13）那轮的 CRLF 例外已不存在**：当时 v12 的 4 份 `.rpt` 是 CRLF 副本、写进清单会在克隆后被行尾归一化而校验失败，故有意不收；
> 2026-10-27 重算时改为在 `.gitattributes` 里给 `deliverables/data/**` 加 `-text -diff`：**证据文件一律按原始字节入库**，不管它是 LF 还是 CRLF（`v62/impl_timing.rpt`、`impl_hold_paths.rpt` 等本来就是 CRLF），也不受本机 `core.autocrlf=true` 影响。**因此可以全部收进清单，克隆后哈希不变。**
> `*.bit` / `*.ltx` / `*.pdf` 在 `.gitattributes` 里是 `binary`，逐字节入库，哈希天然稳定。

单目录复核（不用 `sha256sum` 时）：

```powershell
Get-ChildItem v62, v66, bitstreams, timing -File | ForEach-Object {
  "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Name }
```

Windows PowerShell 逐行比对：

```powershell
Get-Content SHA256SUMS.txt | ForEach-Object { $p = $_ -split '\s+', 2; $f = $p[1];
  if ((Get-FileHash $f -Algorithm SHA256).Hash -ne $p[0]) { "FAIL $f" } }
```

清单中的哈希对应**仓库内已提交的字节**，因此克隆后校验必然通过（见 §5.1）。

## 4. 复现方法

- **串口遥测（ABZ/UVW 演示）**：`python tools/demo_abz_uvw.py --port COM3 --seconds 30 --archive` 一条命令重建本目录 `telemetry_abz_uvw.csv` 与 `../figures/telemetry_abz_uvw.png`（含版本门禁 `0x05F2` = `0x000C`、寄存器自配、逐项判定与 `DEMO PASS/FAIL` 结论；`--selftest` 可离线验证判定逻辑）。
- **插图**：图 6-1 / 6-2 / 6-3 由 `tools/compare_glitch_figure.py` 与 `tools/glitch_figure.py` 读取本目录 `ila/` 下的 CSV 重新渲染（输出位于 `deliverables/figures/`，含 `ila_glitch.png`、`ila_glitch_g82.png`、`ila_glitch_v9_vs_v11.png`）。辅助脚本：`tools/glitch_bits.py`、`tools/glitch_chain.py`、`tools/glitch_intervals.py`。
- **时序数字**：报告中的 WNS/TNS/失败端点数取自本目录 `timing/` 下的 Vivado 报告，可 grep 结论行 `All user specified timing constraints are met.` 复核。
- **CSV 解析**：见 §2.3 的列下标约定；`s_raw` 是第 **29** 列（0 起始），注意其位宽为 12 位、需按**有符号**解读。

## 5. 归档说明与已知差异

**5.1 行尾统一（会影响哈希）。** `.gitattributes` 规定 `*.rpt` / `*.txt` 为 `text eol=lf`，而 `_synth_work/` 中的源文件是 CRLF。为使清单哈希与提交后的字节一致，**v11/v9 那一轮的归档**已把 `timing/*.rpt` 与 `logs/*.txt` 统一转换为 **LF**（共 11 个文件，例如 `impl_timing.rpt` 61,360 → 60,404 B、`hot_ab.txt` 2,795 → 2,756 B）。`.bit` / `.ltx` / `.csv` / `.log` 未被任何规则归一化，为**逐字节原样**拷贝，其哈希与源文件完全相同。
> ⚠ **2026-10-13 增补的 v12 报告没有再做 LF 转换**：`timing/impl_timing.rpt`（62,302 B）等 4 份是 `_synth_work/` 源文件的**逐字节 CRLF 副本**，故其哈希是 CRLF 口径（如 `EA3C5E753F49…`）；仓库提交时 git 会按 `text eol=lf` 归一化，**克隆后这些文件的字节与哈希将与本节所载不同**（v11/v9 的历史件则不受影响）。引用时请以 §2.2 表的“证明什么”列（WNS/端点数为准）而非哈希。

**5.2 v9 时序报告命名与数字差异。** 仓库内不存在 `*_timing_v9*.rpt`；v9 签核报告仅存于 `_synth_work/pre_v9/`，归档时命名为 `impl_timing_v9_2026-10-11.rpt`、`impl_ila_timing_v9_2026-10-11.rpt`（日期取自其生成时间）。根目录的 `_synth_work/impl_timing.rpt` 已被 **v11 与 v12 两次运行先后覆盖**（现为 v12，2026-10-12 23:59:16），故 P0-1 所引的 v9 版本无法逐字节复原；v11 那一轮的两份报告则改名为 `impl_timing_v11_2026-10-12.rpt` / `impl_ila_timing_v11_2026-10-12.rpt` 保留（另一轮重复报告的 v9 数字与 `photo_shot_list.md:40-41` 所载**WNS 完全一致**（−3.274 / −3.323），TNS 与端点总数有细微出入（−84.267 vs −84.283；11,298 vs 11,304），属同一版本的相邻两次运行，引用时请以 WNS 为准）。

**5.3 温度实验文件命名。** 不存在 `temp_v9_hot.csv` / `temp_v11_hot.csv`；实际文件名为 `temp_v9_heat.csv` / `temp_v11_heat.csv`，归档时**保留真实文件名**，因为 `deliverables/09_scope_measure_log.md:87-92` 与 `docs/DEV_STATUS.md:3251-3256` 正是按这个名字引用的。另外附带收录了规格清单未列出的 `temp_v9_cool.csv`，因为上述两处文档同样引用了它。

**5.4 `sweep3.csv` 的单个伪值行。** 该文件 `21:08:29` 一行速率 11,601.797 次/s 是 v10 下载窗口内计数器被复位的产物，不代表真实工况；`docs/DEV_STATUS.md:3159` 已记录此现象（"v10 期间计数器连续 ≥45 s 恒为复位值"）。热平台结论 12–55.198 次/s 不受该行影响。

**5.5 "无 >40 LSB 跳变"的口径。** v11 抓包 `ila_cmp_v11_clean.csv` 中，按**无符号**计算下标 90→91 存在 `0xFFD → 0x002`（−4091）的跳变；但 `s_raw` 为 12 位有符号量，该处实为 **−3 → +2 = +5 LSB** 的正常回绕。因此该结论须按有符号 12 位口径陈述，否则复核者会得出相反结论。

**5.6 未纳入的文件。** `_synth_work/` 下的综合/实现中间产物、`.dcp` 检查点、Vivado 日志与波形数据库未归档：它们体积过大且非报告引用对象。本目录只承载报告与索引**按名引用**的证据。

**5.7 `.gitkeep`。** 目录内另有占位文件 `.gitkeep`（历史遗留，非证据），故未列入 `SHA256SUMS.txt`。

**5.8 v12 归档时的改名与覆盖（v11 历史件保留）。** 2026-10-13 归档 v12 时，`timing/` 下 4 个被引用的报告**先改名后覆盖，不删除旧文件**：`impl_timing.rpt` → `impl_timing_v11_2026-10-12.rpt`（60,404 B / `F3B2BFB36C89`，v11 生产 @2026-10-12 21:15:26、WNS +0.821 / 11,310 端点）、`impl_util.rpt` → `impl_util_v11_2026-10-12.rpt`（11,236 B / `874B261AEC29`，LUT 6369 = 30.62% / FF 4088 = 9.83%）、`impl_ila_timing.rpt` → `impl_ila_timing_v11_2026-10-12.rpt`（115,745 B / `C25C9251077E`，v11 ILA @21:29:41）、`impl_ila_util.rpt` → `impl_ila_util_v11_2026-10-12.rpt`（12,078 B / `F1DB194A41D6`）；随后由 `_synth_work/` 的 v12 对应报告各自覆盖为**现名**（见 §2.2 前 4 行）。`bitstreams/` 侧的 v11 两位流（`enc_top_v11_prod.bit` 1,086,600 B、`enc_top_v11_ila.bit` 1,458,744 B）与 `.ltx` 从未被覆盖，原地保留为历史件，v12 位流以 `*_v12_*` 新名并列存放。

**5.9 v66 归档（2026-10-29）的取字节与改名口径。** 20 件全部从 `_impl_v66/`、`_impl_disp_v66/` **逐字节原样拷贝**——未做行尾转换、未重新压缩、未重新生成任何报告。因此两个位流的 SHA256 与 Vivado 当初写出的文件完全相同（`322F1BE5…0102` / `E3BC3ED8…7E8F`），**上板时请直接烧 `deliverables/data/v66/` 里的这两份**，或与 `_impl_*` 目录中的对应文件互校（应逐字节一致）。
- **改名为对齐前缀**：`vivado.log` → `prod_impl.log` / `disp_impl.log`，`impl_timing_v66.rpt` → `prod_timing.rpt`，`impl_timing.rpt`（显示构建）→ `disp_timing.rpt`，其余同构。`prod_` / `disp_` 前缀是本次新引入的约定（v62 目录沿用原名未动，以免破坏 2026-10-27 已发布的引用）。
- **未归档的中间产物**：`_impl_disp_v64/`（v64 显示构建，已被 v66 取代）与所有 `_impl_*/` 下的 `.dcp`、波形数据库留在工作树，由 `.gitignore` 的 `_impl_disp_v*/` 规则忽略；它们不是报告引用对象。
- **已知不齐**：生产构建缺 `check_timing` / `hold_paths` / `io` 三份报告（见 §2.0a 的 ⚠ 说明）。
