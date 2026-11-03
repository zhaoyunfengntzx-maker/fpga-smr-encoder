# v68 — 400 mVpp 单端正交 + 显示版（64 周期/转）

> **状态**：`[构建签核]` + `[仿真]`；**未上板**。构建号 `RTL_BUILD_ID = 0x0010`。
> **硬件前提**：正交 sin/cos 传感器，**400 mVpp 单端、0 V 中心、64 电周期/机械圈**；AD9238 模块按
> 方案 B 改造（R13 4.02 k 短接 / R15 1 k 不焊 / AD8138 `Rg` 499→120 Ω，差分增益 **4.16×**）。
> **不适用**：v62/v66 的 ±5 V / EI58C9 前端、v67 的 200–300 mVpp 档；`rtl/` 原文件与 v62/v66/v67
> 位流均未改动。
>
> 本目录共 **23 件 / 5,713,633 B**（不含本 README 与 `SHA256SUMS.txt`）。

## 1. 和 v66 的 3 处 RTL 差异

由 `tools/make_v68_rtl.py` 把 `rtl/*.v`（25 个）与 `rtl/eth/*.v`（8 个）复制到
`_synth_work_v68/rtl_v68/` 后只改 3 处（源文件不动）：

| # | 文件 | v66 | v68 | 原因 |
|---|---|---|---|---|
| 1 | `enc_top.v` | `POLE_BITS = 11` | `6` | 64 电周期/圈；机械角 `pos_full[21:6]` |
| 2 | `enc_top.v` | `RTL_BUILD_ID = 0x000E` | `0x0010` | 独立构建号（v67 用 0x000F） |
| 3 | `reg_file.v` | `INTER0 = 2` | `32` | 64 周期/转 × 2×32 = **4096 A 沿/圈**（2048 PPR） |

**GAIN_S / GAIN_C 保持 32768（1.0）**：400 mVpp × 4.16 = 0.832 FS，已经在默认幅值窗
`[0.60, 1.20]` 内；v67 的 1.5 会把 400 mVpp 推到 **1.248 FS**，16 bit 输出削顶。
保持 v66 默认：`AMP_LOW_SQ=(0.60)²·2^30`、`AMP_HIGH_SQ=(1.20)²·2^30`、标定 REF=0.8 FS、
`CALIB_N=64`（64 周期/转 = 1 圈）、`ARM_TMO=1 s`、`FILT_K=0x1A`、bias 默认关、
UVW pairs=4、z_width=4。

## 2. 构建签核

### 2.1 生产位流（无屏、无网）

| 项 | 结果 |
|---|---|
| 位流 | **1,511,380 B** @2026-10-30 17:24:49；SHA256 `921FA2DCA4CB12BF17CC0CB4B4E2EDF4E6F6F1F21430A59801DF3C00784B1196` |
| 时序 | **WNS +0.144** / TNS 0.000 / **0 失败 / 24,648 端点**；WHS **+0.049** / 0 失败 / 24,183；WPWS +0.264 / 0 失败 / 8,996；`All user specified timing constraints are met.` |
| 资源 | LUT **10,928 = 52.54%**、FF **8,714 = 20.95%**、BRAM **32/50 = 64%**、DSP **17/90 = 18.89%**、IOB 63 |
| DRC | **0 Errors / 0 Critical Warnings**；45 Warning（DPIP-1×12、DPOP-1×16、DPOP-2×17，DSP 未流水建议） |
| 布线 | 18,578 条可布线网 **全部布通、0 routing errors**；48 条 no-load net |
| 位流算术 | saved 5,446,720 bits ⇒ 17,537,696 − 5,446,720 = 12,090,976 bit = 1,511,372 B + 8 B 头 = **1,511,380 B**；偏移 **260** 处 `AA 99 55 66` |

### 2.2 显示位流（编码器 + 7" LCD + 千兆网）

顶层 `enc_top_disp`，综合带 `-verilog_define {ENC_DISP_TAP ENC_V68_CPR64}`（**生产构建绝不能带**）；
前者打开 `disp_tap` 端口，后者让屏上 RPM/累计转数按 64 电周期/转换算。RTL 为
`_synth_work_v68/rtl_v68/*.v` + `.../eth/*.v` + `disp/*.v`，约束 `constr/enc_top_disp.xdc`。

| 项 | 结果 |
|---|---|
| 位流 | **1,701,921 B** @2026-10-30 17:46:33；SHA256 `86E6BAB445759A74A4E96A2032E2CE658903F6CC7B827C7B414514829059D753` |
| 时序 | **WNS +0.345** / TNS 0.000 / **0 失败 / 34,281 端点**；WHS **+0.047** / 0 失败 / 33,816；WPWS +0.264 / 0 失败 / 12,036；`All user specified timing constraints are met.` |
| 资源 | LUT **17,414 = 83.72%**、FF **11,528 = 27.71%**、BRAM **48/50 = 96.00%**、DSP **19/90 = 21.11%**、IOB 107 |
| DRC | 99 checks，**0 Error / 0 Critical Warning**；Warning：BUFC-1×1、CHECK-3×2、DPIP-1×15、DPOP-1×18、DPOP-2×19、RBOR-1×4、REQP-1839×20、REQP-1840×20 |
| 布线 | 27,875 条可布线网 **全部布通、0 routing errors**；97 条 no-load net |
| eth_rxc | `report_timing -group eth_rxc_clk` 最差 **slack MET 1.907 ns** |
| 位流算术 | saved 3,922,432 bits ⇒ 17,537,696 − 3,922,432 = 13,615,264 bit = 1,701,908 B + 13 B 头 = **1,701,921 B**；偏移 **265** 处 `AA 99 55 66`（头比生产多 5 B，因 design 名 `enc_top_disp` 比 `enc_top` 长 5 字符） |

> ⚠ 两次构建的 Vivado 日志都停在 `Bitgen Completed Successfully`：Vivado 2026.1 在收尾阶段不退出
> （v66/v67 同款），位流与全部报告已落盘、哈希/长度自洽，作业由外部终止。**不要**把“作业还在跑”
> 当成“没构建完”，以位流时间戳/哈希和报告为准。

## 3. 仿真

`sim/tb_v68.v` 对变体 RTL 跑 5 组场景，**37 checks 全过**（14 s）：

| 场景 | 结果 |
|---|---|
| 400 mVpp / 默认 1.0 | `GAIN_S/C=32768`、`INTER0=32`、`amp_ok=1`、`cor_sat=0`、`TRACK`、`amp_sq=743,325,696`（0.692·2^30） |
| 450 mVpp | `TRACK`、不饱和、`amp_sq=940,771,584`（0.876·2^30） |
| 350 mVpp | `TRACK`、`amp_sq=569,108,736`（0.530·2^30） |
| 一键标定（400 mVpp） | `calib_done=1`、`res_gain=31,527`（0.962）、shift=0、标定后 `amp_sq=687,269,962`（0.640·2^30）、`TRACK` |
| 强拉 1.5 A/B | `amp_sq=1,121,434,660`、`amp_high` 出现过、`cor_sat=1`、非 TRACK；写回 31,527 后 `TRACK` |

注：标定累加校正前信号，所以 31,527 与默认 1.0 无关（0.8 / 0.832 = 0.9615）。
仿真里 24.4 kHz 电频率下仍会打印 `[enc_top] ERROR: 速度为正但延迟修正量为负`，是 `lag_ff`
3 拍延迟与速度估计在高速下的符号抖动，只影响上报位置、不影响 ABZ/UVW/锁定；目标 64–128 Hz
手转时 ω 小约 200–380 倍，上板按 `docs/30` §7 复核。

## 4. 文件

| 文件 | 大小 | SHA256（前 16 位） | 证明什么 |
|---|---:|---|---|
| `enc_top_v68.bit` | 1,511,380 | `921FA2DCA4CB12BF` | **v68 生产位流**（无屏、无网） |
| `enc_top_disp_v68.bit` | 1,701,921 | `86E6BAB445759A74` | **v68 显示位流**（LCD + 千兆网，CPR=64） |
| `prod_timing.rpt` | 110,609 | `5F9EED6AD3532DC3` | 生产 WNS +0.144 / WHS +0.049 / 0 失败 |
| `prod_util.rpt` | 12,319 | `9644E1C72BE103E6` | 生产 LUT 52.54% / BRAM 32/50 |
| `prod_drc.rpt` | 24,356 | `250A84991233C755` | 生产 0 Error / 45 Warning |
| `prod_route.rpt` | 651 | `5A2DDFBD9AAF3727` | 生产 18,578 网全布通 |
| `prod_clkint.rpt` | 3,478 | `6378731FD7FDD4B6` | 生产时钟交互 |
| `prod_top_paths.rpt` | 482,321 | `E6694C19194403DE` | 生产最差 20 条 setup 路径 |
| `prod_io.rpt` | 148,321 | `8D5D113959AFFDE0` | 生产引脚分配/IO 标准 |
| `prod_check_timing.rpt` | 3,351 | `23E2F585554996A4` | 0 no_clock / 0 unconstrained endpoint |
| `prod_impl.log` | 276,872 | `B0C36D8FD974FECD` | 生产完整构建日志 |
| `disp_timing.rpt` | 118,869 | `E47125AFCBB6BFF4` | 显示 WNS +0.345 / WHS +0.047 / 0 失败 |
| `disp_util.rpt` | 12,457 | `D717D0CC3F2E399E` | 显示 LUT 83.72% / BRAM 48/50 |
| `disp_drc.rpt` | 56,385 | `345B975FE07BBBFA` | 显示 99 checks / 0 Error |
| `disp_route.rpt` | 651 | `AC05EF269F98E2E5` | 显示 27,875 网全布通 |
| `disp_clkint.rpt` | 3,484 | `061EB5A689F01DC7` | 显示时钟交互 |
| `disp_top_paths.rpt` | 549,663 | `D971B33753BECB4A` | 显示最差 20 条 setup 路径 |
| `disp_io.rpt` | 148,327 | `25A57AC6D2C6377F` | 显示引脚（LCD/触摸/网口） |
| `disp_check_timing.rpt` | 3,425 | `3F7B613C582AB57A` | 显示 0 no_clock / 0 unconstrained |
| `disp_eth_rx_paths.rpt` | 47,874 | `AFD47236645FEC0D` | eth_rxc 组 slack MET 1.907 ns |
| `disp_impl.log` | 483,074 | `66954EB73702CF6C` | 显示完整构建日志 |
| `sim_tb_v68.log` | 13,285 | `1F6211B998E28A48` | 37 checks PASS |
| `VARIANT_INFO.txt` | 560 | `DE677B025909E994` | 源 git / 时间 / 3 处补丁 / 两条构建命令 |

完整 SHA256 见 `SHA256SUMS.txt`；在 `deliverables/data/` 下执行 `sha256sum -c SHA256SUMS.txt`
应全部通过。

## 5. 必须知道的限制

- **未上板**：只有构建签核 + 仿真；先按 `docs/30_v68_400mvpp_display.md` §7 走一遍。
- **400 mVpp 是标称点**：默认 1.0 时可用输入约 **288–481 mVpp**；481 mVpp 以上削顶。
  在 400 mVpp 一键标定后 gain≈0.962，可用范围约 **300–481 mVpp**（300 mVpp 正好压 `amp_low` 线）。
  传感器幅度会随间隙/位置变化时，**在 400 mVpp 附近标定**，不要用 481 mVpp 标定。
- **显示版 BRAM 96%**：48/50，后续任何加缓冲/加页都可能放不下；改显示逻辑前先看
  `disp_util.rpt`。生产版 32/50 仍有空间。
- **显示版必须带 `ENC_DISP_TAP` 和 `ENC_V68_CPR64`**：`tools/impl_check_disp_v68.tcl` 已带；
  手工综合若漏 `ENC_DISP_TAP` 会因 `disp_tap` 端口缺失而失败；漏 `ENC_V68_CPR64` 则屏上
  RPM/转数仍按 `pairs=4` 换算，显示为实际转速的约 **16 倍**。
- **UI 的 `inter` 预置 64 只是待写值**：屏上长按会走 `next_preset`（32→64→…），一旦写下去 ABZ
  会变成 8192 A 沿/圈。v68 的 ABZ 契约是 `inter=32`（4096 A 沿/圈），不要用屏改这一项。
- **Z 宽度低速截短**：`Z_TIMEOUT=4096 clk`，电周期 <59.6 Hz（64 周期/转 ⇒ <约 0.93 转/秒）时
  Z 脉宽被截短；驱动器只取 Z 边沿则无影响。
- **屏上 RPM/转数依赖 `ENC_V68_CPR64`**：v68 显示构建把它定义为 64，RPM/转数按 64 电周期/转换算；
  手工综合漏掉时退回 5bit `pairs`（默认 4），会显示为实际转速的 **16 倍**。角度/ABZ/UVW
  不受影响；精确转速用上位机或角度差分。
- **显示版顶层的 `key_n` 仍是全局复位 + 一键标定**；`key1_n`/`ui_btn` 是页切换，别把 `key_n`
  当普通页键长按。

## 6. 复现

```powershell
python tools/make_v68_rtl.py
powershell -File tools/run_sim.ps1 -Only tb_v68 -RtlDir _synth_work_v68\rtl_v68
powershell -File tools/run_vivado.ps1 -Tcl tools/impl_check_v68.tcl `
    -LogFile _impl_v68/vivado.log -Tail 40
powershell -File tools/run_vivado.ps1 -Tcl tools/impl_check_disp_v68.tcl `
    -LogFile _impl_disp_v68/vivado.log -Tail 40
```

生成器只读 `rtl/`、只写 `_synth_work_v68/`；v62/v66/v67 的源文件与位流不会被触碰。
