# v73 交付证据包（2026-11-02 上板调试版）

> **这是什么**：在 v71（Z 索引修复）基础上，修掉"显示 RPM 除零"（v72）并加了一个
> **Z 上升沿计数探针**（v73）的两个位流 + 构建证据。
> **状态**：生产位流与显示位流都已在 **真实转台（2048 PPR，≈720 rpm）** 上跑通；
> 显示位流已 **固化进板载 QSPI Flash** 并做过 **断电冷启动** 验证。
> 详细过程与判读见 `docs/36_v72_v73_board_debug.md`。

## 与 v71 的差异

| # | 差异 | 影响面 | 证据 |
|---|---|---|---|
| 1 | `disp/val_format.v` 除数位宽 16→20 位（`div_den`、`fixed_div #(.DW(20))`） | 只在显示子系统；修屏上 RPM 显示 496729.5 的除零 | `_boardtest/_scratch/tb_div20.v`；板上读数 ≈770–780 rpm |
| 2 | `rtl/enc_top.v` 新增 `z_pulse_cnt`（Z 上升沿 32 位计数），`rtl/reg_file.v` 新增只读 `0x054A..0x054D` | 只读观测，不参与功能；LUT +40（52.73%→52.92%） | `_boardtest/z_rate.py`；Z = 12.00 Hz ↔ 720.0 rpm |

RTL 其余部分与 v71 相同（含 v71 的 Z 索引修复：绝对角度过零取窗 + 双向跨零 + `clr_on_z=0`）。

## 构建签核

| | 生产 `enc_top_v73.bit` | 显示 `enc_top_disp_v73.bit` |
|---|---|---|
| 字节 | 1,489,772 | 1,662,197 |
| 时间 | 2026-11-02 11:37:09 | 2026-11-02 11:48:40 |
| SHA256 | `2E081D4E…3D8C9F31F4` | `0567A4E6…F6C6954C0` |
| WNS / TNS / 失败端点 | **+0.220** / 0 / 0（24,889） | **+0.328** / 0 / 0（34,499） |
| WHS | +0.049 | +0.049 |
| LUT | 11,008 (52.92%) | 17,443 级（83.8%） |
| BRAM | 32/50 | 48/50 (96%) |
| 构建号 | `RTL_BUILD_ID = 16'h0017` | 同（显示 RTL 与生产同源） |

## 上板实测（2026-11-02，COM7）

```
v71 生产位流（0x0016）：check / ADC 8657 Hz / 标定 gain 33567/33316 / 角度 RMS 0.72° /
                          60 s 长跑 597,746 帧、|err|>5° 0 帧 / 以太网 ping+capture PASS
v72 显示位流：           屏上 RPM ≈770–780（对应实测 775.6 rpm）
v73 生产位流（0x0017）：  Z 计数 12.00 Hz → 720.0 rpm（另一轮 11.91 Hz → 714.7 rpm）
v73 显示位流：            Z 11.91 Hz、UVW 六态、lock=TRACK；示波器 J5-7 见 ≈1.15 µs / ≈2.5 V 脉冲
Flash 固化 + 断电重上电： 屏正常、RTL_BUILD=0x0017、Z 12.26 Hz、遥测 10.9 kfps
```

## 复现

```powershell
# 生产位流（无显示）
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_v73.tcl -LogFile build_v73.log -Tail 20

# 显示位流
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_disp_v73.tcl -LogFile build_disp_v73.log -Tail 20

# RTL 变体（BUILD_ID 0x0017）
E:\Anaconda\python.exe tools\make_v73_rtl.py

# 上板：下载 / 量 Z / 固化
$env:BITFILE='C:/Users/zhaoy/Desktop/FPGA/_impl_disp_v73/enc_top_disp_v73.bit'; $env:TAG='V73DISP'
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 -Tcl _boardtest\prog_retry.tcl -LogFile prog_v73disp.log -Tail 6
E:\Anaconda\python.exe _boardtest\z_rate.py COM7 3
$env:FLASH_BIT='C:/Users/zhaoy/Desktop/FPGA/_impl_disp_v73/enc_top_disp_v73.bit'
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 -Tcl tools\program_flash.tcl -LogFile flash_v73.log -Tail 30
```

## 限制与未验证项

1. **UVW 三相 120°**、**A/B 正交度**只用逻辑/频率侧验证（A = 800 kHz、六状态轮转）。
2. **Z 停位喘振**（停在索引位 ±0.5° 微动）未测 —— `docs/34_audit_report.md` B8 仍挂。
3. **ARP MAC 口径**未定（实测 `00:00:02:00:00:01`，脚本期望 `02:00:00:00:00:01`）—— B5。
4. 只做了 **60 s** 长跑，没做 2 h。
5. 显示子系统 **零仿真覆盖**（B2），只靠上板目视。
