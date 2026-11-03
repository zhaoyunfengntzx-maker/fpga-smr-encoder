# v67 — 小信号传感器适配版（200–300 mVpp，64 周期/转）

> **状态**：`[构建签核]` + `[仿真]`；**未上板**。构建号 `RTL_BUILD_ID = 0x000F`。
> **硬件前提**：手搓正交 sin/cos 传感器，200–300 mVpp、0 V 中心、64 电周期/机械圈；AD9238 模块按
> 方案 B 改造（R13 短接 / R15 不焊 / AD8138 Rg 499→120 Ω，差分增益 4.16×）。
> **不适用**：v62/v66 的 ±5 V / EI58C9 前端；`rtl/` 原文件与 `v62/`、`v66/` 位流均未改动。

本目录共 **10 件 / 2,417,335 B**（不含本 README 与 `SHA256SUMS.txt`）。

## 1. 和 v66 的 4 处 RTL 差异

由 `tools/make_lowsig_rtl.py` 把 `rtl/*.v`（25 个）与 `rtl/eth/*.v`（8 个）复制到
`_synth_work_lowsig/rtl_lowsig/` 后只改 4 处（源文件不动）：

| # | 文件 | v66 | v67 | 原因 |
|---|---|---|---|---|
| 1 | `enc_top.v` | `POLE_BITS = 11` | `6` | 64 电周期/圈；机械角 `pos_full[21:6]` |
| 2 | `enc_top.v` | `RTL_BUILD_ID = 0x000E` | `0x000F` | 独立构建号 |
| 3 | `reg_file.v` | `GAIN_S/GAIN_C = 32768`（1.0） | `49152`（1.5） | 200–300 mVpp × 4.16 = 0.416–0.625 FS；×1.5 后 0.624–0.9375 FS，落在默认 [0.60,1.20] |
| 4 | `reg_file.v` | `INTER0 = 2` | `32` | 64 周期/转 × 2×32 = 4096 A 沿/圈（2048 PPR）；沿用 2 只有 256 |

保持 v66 默认：`AMP_LOW_SQ=(0.60)²·2^30`、`AMP_HIGH_SQ=(1.20)²·2^30`、标定 REF=0.8 FS、
`CALIB_N=64`（64 周期/转 = 1 圈）、`ARM_TMO=1 s`、`FILT_K=0x1A`、bias 默认关、UVW pairs=4、z_width=4。

## 2. 构建签核

| 项 | 结果 |
|---|---|
| 位流 | **1,504,428 B** @2026-10-29 10:36:27；SHA256 `80842AC24266393B122A954B664509807B9FF35CCFF1A6AA23A6091EB3DED2AB` |
| 时序 | **WNS +0.282** / TNS 0.000 / **0 失败 / 24,630 端点**；WHS **+0.046** / 0 失败 / 24,165；WPWS +0.264；`All user specified timing constraints are met.` |
| 资源 | LUT **10,924 = 52.52%**（logic 10,744 + mem 180）、FF **8,705 = 20.93%**、BRAM **32/50**、DSP **17/90**、IOB 63 |
| DRC | **0 Errors / 0 Critical Warnings**；45 Warning（DPIP-1×12、DPOP-1×16、DPOP-2×17，DSP 未流水建议） |
| 布线 | 18,584 条可布线网 **18,584 全布通、0 routing errors** |
| 位流算术 | saved 5,502,336 bits ⇒ 17,537,696 − 5,502,336 = 12,035,360 bit = 1,504,420 B + 8 B 头 = **1,504,428 B**；偏移 260 处 `AA 99 55 66` |

## 3. 仿真

`sim/tb_lowsig.v` 对变体 RTL 跑 5 组场景，**35 checks 全过**（15 s）：

| 场景 | 结果 |
|---|---|
| 200 mVpp / 默认 1.5 | `GAIN_S/C=49152`、`INTER0=32`、`amp_ok=1`、`cor_sat=0`、`TRACK`、`amp_sq≈0.39·2^30` |
| 300 mVpp | `TRACK`、不饱和、`amp_sq≈0.88·2^30` |
| 250 mVpp | `TRACK`、`amp_sq≈0.61·2^30` |
| 一键标定 | `calib_done=1`、`res_gain≈63076`（1.925）、shift=0、标定后 `amp_sq=687,355,610`（0.8 FS）、`TRACK` |
| 1.0 ↔ 标定值 A/B | 1.0 时 `amp_sq=185,493,776`、`amp_low=1`、非 TRACK；写回 63076 后 `TRACK` |

注：标定累加校正前信号，所以标定结果 63076 与默认 1.5 无关（0.8 / 0.416 = 1.923）。

## 4. 文件

| 文件 | 大小 | SHA256（前 16 位） | 证明什么 |
|---|---:|---|---|
| `enc_top_lowsig.bit` | 1,504,428 | `80842AC24266393B` | **v67 生产位流**（无屏、无网） |
| `prod_timing.rpt` | 106,861 | `EF91833F362160EB` | WNS +0.282 / WHS +0.046 / 0 失败 |
| `prod_util.rpt` | 12,325 | `40F2576C285DF6DC` | LUT 52.52% / BRAM 32/50 |
| `prod_drc.rpt` | 24,362 | `D3A77B90BABDC2A7` | 0 Errors / 45 Warning |
| `prod_route.rpt` | 651 | `C7AAB4EEC6721579` | 18,584/18,584 布通 |
| `prod_clkint.rpt` | 3,484 | `5064D965D604BBFF` | 时钟交互 |
| `prod_top_paths.rpt` | 474,821 | `CB56B5CE6D4B9AE8` | 最差 20 条 setup 路径 |
| `prod_impl.log` | 276,516 | `58A671E383569716` | 完整构建日志（停在 Bitgen Completed） |
| `sim_tb_lowsig.log` | 13,446 | `93D404C443528AB1` | 35 checks PASS |
| `VARIANT_INFO.txt` | 441 | `74AA78761C9354C5` | 源 git / 时间 / 4 处补丁 |

完整 SHA256 见 `SHA256SUMS.txt`；在 `deliverables/data/` 下执行 `sha256sum -c SHA256SUMS.txt` 应全部通过。

## 5. 必须知道的限制

- **未上板**：只有构建签核 + 仿真；先按 `docs/29_lowsig_sensor_v67.md` §7 走一遍。
- **构建脚本收尾**：Vivado 在位流落盘后不退出（v66 同款），已由外部终止；位流/报告哈希自洽。
  `tools/impl_check_lowsig.tcl` 末尾已有 `exit`，但本机 Vivado 2026.1 仍偶发不响应。
- **Z 宽度低速截短**：`Z_TIMEOUT=4096 clk`，电周期 <59.6 Hz（64 周期/转 ⇒ <约 0.93 转/秒）时 Z 脉宽
  被截短；驱动器只取 Z 边沿则无影响。
- **200 mVpp 是下限**：默认 1.5 仅比 `amp_low` 0.60 高 4%；低于约 195 mVpp 需把增益写到 1.55–1.6
  或下调 `AMP_LOW_SQ`。
- **只有生产位流**：没有做显示版；需要屏上 UI 时另按 `ENC_DISP_TAP` 复制。
