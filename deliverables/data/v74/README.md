# v74 — 生产位流上板验收 + 显示位流构建签核（2026-11-02）

> **状态**：生产位流 `[构建签核]` + `[上板验收]`；显示位流 `[构建签核]`，**未目视验收**（板卡 USB 未枚举）。
> 构建号 `RTL_BUILD_ID = 0x0018`。
> **硬件前提**：转台真实输出 8 Vpp 正交 sin/cos、**PPR = 2048**；AD9238 模块 5:1 衰减（10 Vpp 满量程）。
>
> 本目录共 **24 件 / 6,218,923 B**（不含本 README 与 `SHA256SUMS.txt`）。

## 1. 与 v71/v73 的关系（为什么构建号是 0x0018）

`_synth_work_v74/VARIANT_INFO.txt`（本目录已归档）：

```
v74 = v71 RTL (position acc + Z index fix) + Z pulse counter probe
build id : 16'h0018
source   : rtl/ (git 2f4c147)
generated: 2026-11-02T13:29:18
diff vs rtl/: RTL_BUILD_ID only
probe    : z_pulse_cnt (32-bit, rising edges of z_out) -> 0x054A..0x054D
```

即：**v74 与仓库 `rtl/` 的差异只有 `RTL_BUILD_ID` 一处**（`rtl/enc_top.v:239` 为 `16'h0015`，v74 由 `tools/make_v74_rtl.py` 派生为 `16'h0018`），另加一个只读的 Z 脉冲计数探针（寄存器 `0x054A..0x054D`），不改变任何控制路径。因此 v70/v71 轮在转台上取得的实测结论**可直接平移到 v74**。

## 2. 生产位流（无屏，面向 2048 p/r 转台）

| 项 | 结果 |
|---|---|
| 位流 | **1,512,664 B** @2026-11-02 13:33；SHA256 `E46349073DE53B7602A8C2A33E68832BE4B4E6A995E753A64E8D88A68CDA2680` |
| 时序 | **WNS +0.409 / TNS 0.000 / 0 失败 / 24,625 端点**；WHS **+0.025** / 0 失败 / 24,160；WPWS +0.264 / 0 失败 |
| 资源 | LUT **10,926 = 52.53%**（LUT as Logic 10,746 + LUT as Mem 180）、FF **8,697 = 20.91%**、BRAM **32/50 = 64.00%**、DSP **17**、Bonded IOB **60** |
| DRC | 45 checks（DPIP-1 ×12、DPOP-1 ×16、DPOP-2 ×17），**0 Error / 0 Critical Warning** |
| 布线 | 可布线网全部布通、**0 routing errors** |

构建日志：`prod_impl.log`（`_flash2_work/build_v74.log`）。**上板验收**（2026-11-02，转台 719–740 rpm、Z ≈12 Hz、UVW 六态均衡、以太网 ping + UDP 抓窗通过）见 `../../docs/DEV_STATUS.md` 与 `../v70/README.md` §3。

## 3. 显示位流（编码器 + 7" LCD + 千兆网）

综合带 `-verilog_define {ENC_DISP_TAP ENC_V69_CPR2048}`（**生产构建绝不能带 `ENC_DISP_TAP`**）。本目录的显示签核件为 **2026-11-02 23:00:37 重建版**（`build_disp_v74b.log`），覆盖了 13:4x 的更早一版。

| 项 | 结果 |
|---|---|
| 位流 | **1,700,821 B** @2026-11-02 23:00:50；SHA256 `72FF4D13F45B0D02CBAA6B1B3D355AAA92745FF069AE9C13AE0586216249C395` |
| 时序 | **WNS +0.422 / TNS 0.000 / 0 失败 / 34,499 端点**；WHS **+0.024** / 0 失败 / 34,034；WPWS +0.264 / 0 失败 |
| 资源 | LUT **17,604 = 84.63%**、FF **11,946 = 28.72%**、BRAM **48/50 = 96.00%**、DSP **22**、IOB **104** |
| DRC | 108 checks（BUFC-1 ×1、CHECK-3 ×2、DPIP-1 ×18、DPOP-1 ×21、DPOP-2 ×22、RBOR-1 ×4、REQP-1839 ×20、REQP-1840 ×20），**0 Error / 0 Critical Warning** |

> ⚠ **未目视验收的证据**：2026-11-02 23:09 的烧录尝试在 `_flash2_work/prog_v82.log` 里连续 8 次报
> `ERROR: [Labtoolstcl 44-199] No matching targets found on connected servers: localhost`，随后
> `V82UI FATAL: target still locked after retries` —— 板卡 USB 未接、串口未枚举，**屏上效果没有人工确认过**。
> 因此 v74 显示位流只算"构建签核"，参赛演示仍以已上板验收的 v62 为口径。

## 4. 复现

```powershell
# 生产位流
& E:\Anaconda\python.exe tools\make_v74_rtl.py            # 派生 _synth_work_v74/rtl/（仅改 RTL_BUILD_ID）
vivado -mode batch -source tools\impl_check_v74.tcl        # 产出 _impl_v74/*.rpt + enc_top_v74.bit
# 显示位流
vivado -mode batch -source tools\impl_check_disp_v74.tcl   # 产出 _impl_disp_v74/*
# 校验
cd deliverables\data; sha256sum -c SHA256SUMS.txt          # 259 条 + 本目录 24 条 = 283 条应全 OK
```
