# v70 — 2048 PPR 正确 + 位置计数/UVW 修复（生产 + 显示）

> **状态**：`[构建签核]` + `[生产位流已上板验收]`；**显示位流已构建但未上板目视**。
> 构建号 `RTL_BUILD_ID = 0x0015`。
> **硬件前提**：转台真实输出 8 Vpp 正交 sin/cos、**PPR = 2048**（每圈 2048 个电周期）；
> AD9238 模块 5:1 衰减（10 Vpp 满量程）。
>
> 本目录共 **21 件 / 5,573,947 B**（不含本 README 与 `SHA256SUMS.txt`）。

## 1. 为什么有 v70

v68（`POLE_BITS=6`）和 v69（`POLE_BITS=11`）上板后都出现同一批现象：
屏上角度在动、ABZ 正常，但 **RPM 恒 0、Z 不出现、UVW 不换相、多圈计数全 0**。
逐层 bisect（位流 + ModelSim）后定位到两个**独立的 RTL 缺陷**，与 `POLE_BITS` 无关：

| 缺陷 | 根因 | 修法 |
|---|---|---|
| `cycle_cnt` 恒 0 | `pole_counter.v` 把 0..65535 的**无符号相位**按补码符号扩展再相减，跨 32768 时差值算成 −65403；累加器每半圈被扣 65536 | 先做模 2^AW 无符号差 `diff_u`，再对**差值**符号扩展 |
| UVW 反向只有 3 扇区 | `uvw_gen.v` 的 `off_bwd` 缺"角度从 0 反向绕回 65535"这条环绕边界，0→5 跨界被永久吞掉 | 新增 `bwd_wide` 分支（`r_sec==0 && eang>BND[5] ⇒ off_bwd = 65536 − eang`） |

另有两处顺带修复：`dir_det` 改用 16 位最短有符号差；`move_fwd/move_bwd` 显式声明线网。
显示版的 `DISP_CPR` 新增 `ENC_V69_CPR2048`（2048），修掉 v68 显示版"RPM 显示成 16 倍"的偏差。

## 2. 构建签核

### 2.1 生产位流（无屏）

| 项 | 结果 |
|---|---|
| 位流 | **1,517,496 B** @2026-11-01 22:36:58；SHA256 `48EACCFEFBEBC99EB90AA92C14C1A4B6B9177BB2D688FD8B0B258CC5111A8E94` |
| 时序 | **WNS +0.091 / TNS 0.000 / 0 失败 / 24,680 端点**；WHS **+0.065** / 0 失败 / 24,215；WPWS +0.264 / 0 失败 / 9,004 |
| 资源 | LUT **10,955 = 52.67%**、FF **8,722 = 20.97%**、BRAM **32/50 = 64.00%**、DSP **17/90 = 18.89%**、IOB 63 |
| DRC | 45 checks（DPIP-1 ×12、DPOP-1 ×16、DPOP-2 ×17），**0 Error / 0 Critical Warning** |
| 布线 | 18,654 条可布线网全部布通、**0 routing errors**、48 条 no-load |

### 2.2 显示位流（编码器 + 7" LCD + 千兆网）

综合带 `-verilog_define {ENC_DISP_TAP ENC_V69_CPR2048}`（**生产构建绝不能带 `ENC_DISP_TAP`**）。

| 项 | 结果 |
|---|---|
| 位流 | **1,708,301 B** @2026-11-01 22:46:37；SHA256 `1081DCA7002B80A2C88CF82221D683DBE7A63757BDEF70D5E9AE3DE760563FBB` |
| 时序 | **WNS +0.027 / TNS 0.000 / 0 失败 / 34,321 端点**；WHS **+0.057** / 0 失败 / 33,856；WPWS +0.264 / 0 失败 / 12,052 |
| 资源 | LUT **17,415 = 83.73%**、FF **11,544 = 27.75%**、BRAM **48/50 = 96.00%**、DSP **19/90 = 21.11%**、IOB 107 |
| DRC | 99 checks（BUFC-1 ×1、CHECK-3 ×2、DPIP-1 ×15、DPOP-1 ×18、DPOP-2 ×19、RBOR-1 ×4、REQP-1839 ×20、REQP-1840 ×20），0 Error |
| 布线 | 27,912 条可布线网全部布通、0 routing errors |
| eth_rxc | `report_timing -group eth_rxc_clk` 最差 **slack MET 1.907 ns** |

> 显示版 WNS 只剩 +0.027 ns、BRAM 96% —— 这是三代里最紧的一版，后续加页/加缓冲前先看 `disp_util.rpt`。

## 3. 生产位流上板实测（2026-11-01 22:41 起）

| 项 | 结果 |
|---|---|
| 下载 | `V70D PROGRAMMED_OK`、`End of startup status: HIGH` |
| 身份 | `RTL_BUILD=0x0015`、`INTER0=32`、`UVW_CFG=0x2004`、`0x0500&0xFF=27`、`0x0501&0xFF=5` |
| 位置计数 | `rate −24,962 cycles/s`、`cnt −2047..0 distinct=2048`、**Z 12.00 Hz**、机械 **719–731 rpm** |
| UVW | 六态 `{1:5423, 2:4984, 3:4548, 4:4971, 5:5020, 6:4959}`，293 次换向/秒 |
| 幅值 | `r` mean 0.79–0.82 FS、max 0.864 FS（8 Vpp 未削顶） |
| 角度一致性 | 分箱 −0.13°..+0.13°；`h1=0.050 h2=0.026 h3=0.006 h4=0.093°`；常数偏移 2.84°（≈323 ns 流水线时差，v68 同样存在） |
| 一键标定 | `gain_s=33,776`、`gain_c=33,568`、`shift=0`、`flags=0x0010`、`amp_sq=53,514` |
| 以太网 | ping 5/5；UDP 28,672 点 @25 MSPS；**每次重配置后首次抓包缺 45 块，重抓 3/3 次 `missing=[]`** |
| 60 s 长跑 | 598,115 帧 / 9,968 fps、r 漂移 <0.02%、lock 一直 TRACK、UVW 六态均匀、`|err|>5°` 仅 150/119,623 |

完整数据、定位过程与复现命令见 [`docs/33_v70_release_report.md`](../../../docs/33_v70_release_report.md)。

## 4. 必须知道的限制

- **显示位流未上板**：只完成构建签核。屏上 RPM 应显示约 **720 rpm**（v68 显示版会显示 ~2.4 万）。
  上板第一件事是确认 RPM、长按 `key_n` 一键标定、`ui_btn` 翻页。
- **每次重配置后要重写 UDP 端口**：`0x070C` 复位回 5000，而本机 5000 被系统进程占用 ⇒ 需写 5010。
- **抓包冷启动丢块**：首次 40+ 块缺失（ARQ/学习期），重抓一次即可 `missing=[]`。
- **8 位寄存器读回的高字节是脏数据**：`0x0500` 会读成 1307，取值必须 `& 0xFF`。
- **`uvw_freq_warn` 间歇置位**（`io_flags` bit3，约 18% 帧）：UVW 输出正确，推测是扇区边界抖动触发
  `r_dwell < MINHALF`（`rtl/uvw_gen.v:537-538`），观感问题，待查。
- **ABZ 契约**：`inter=32` ⇒ 2048 × 32 = **65,536 A 沿/圈**；屏上 `ui_inter` 预置的 64 只是待写值，别在屏上改。
- **OTR**：`0x053A` bit3 会因 AD9238 模块 OTR 脚毛刺置位（已在 XDC 加下拉），数传无超量程证据，判为假告警。

## 5. 文件

| 文件 | 大小 | 证明什么 |
|---|---:|---|
| `enc_top_v70.bit` | 1,517,496 | **v70 生产位流**（无屏、无网） |
| `enc_top_disp_v70.bit` | 1,708,301 | **v70 显示位流**（LCD + 千兆网，CPR=2048） |
| `prod_timing.rpt` / `prod_util.rpt` / `prod_drc.rpt` / `prod_route.rpt` / `prod_clkint.rpt` / `prod_top_paths.rpt` / `prod_io.rpt` / `prod_check_timing.rpt` | — | 生产构建签核：WNS +0.091、LUT 52.67%、0 Error、18,654 网全布通 |
| `prod_impl.log` | — | 生产完整构建日志（`Bitgen Completed Successfully`） |
| `disp_timing.rpt` / `disp_util.rpt` / `disp_drc.rpt` / `disp_route.rpt` / `disp_clkint.rpt` / `disp_top_paths.rpt` / `disp_io.rpt` / `disp_check_timing.rpt` / `disp_eth_rx_paths.rpt` | — | 显示构建签核：WNS +0.027、BRAM 48/50、eth_rxc slack MET 1.907 |
| `disp_impl.log` | — | 显示完整构建日志 |
| `VARIANT_INFO.txt` | — | 源 git / 生成时间 / 补丁清单 / 构建命令 |

完整 SHA256 见 `SHA256SUMS.txt`。

## 6. 复现

```powershell
E:\Anaconda\python.exe tools\make_v70_rtl.py
powershell -File _flash2_work\run_vivado_hw.ps1 -Tcl tools\impl_check_v70.tcl `
    -LogFile build_v70.log -Tail 20
powershell -File _flash2_work\run_vivado_hw.ps1 -Tcl tools\impl_check_disp_v70.tcl `
    -LogFile build_disp_v70.log -Tail 20
```

仿真（ModelSim，秒级）：

```powershell
cd _boardtest\acc_sim
$env:PATH="D:\ModelSim\win64;"+$env:PATH
vlog -quiet ../../rtl/pole_counter.v ../tb_acc2.v ; vsim -c -quiet -do "run -all; quit -f" tb_acc2
vlog -quiet ../../rtl/uvw_gen.v ../tb_uvw.v ../tb_uvw_rev.v
vsim -c -quiet -do "run -all; quit -f" tb_uvw_rev
```
