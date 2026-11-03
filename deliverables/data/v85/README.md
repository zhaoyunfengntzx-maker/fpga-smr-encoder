# v85 显示位流证据（2026-11-03）

> 本目录归档 **v85 显示位流**（编码器 + 5 页触摸 UI + 千兆网）的位流、实现报告、
> 构建日志与下载日志。它**不是**时序签核基线；签核基线仍是
> [`../v74/`](../v74/) 的生产位流（`BUILD 0x0018`，WNS +0.409）。
>
> 归档口径：v85 只改显示侧（`disp/`），`rtl/` 未动；生产位流不受影响。

## 1. 一句话

v85 = v74 编码器 RTL + 最新一版屏上 UI（v75–v85 的界面与交互修正）。
2026-11-03 15:45–15:50 重建，**时序收敛（WNS +0.175 / 0 失败端点）**，
16:50:56 通过 JTAG 下载成功；**尚未做逐页目视验收**，因此文档里一律写
"构建签核 + 已下载"，不写"已上板验收"。

## 2. 位流

| 项 | 值 |
|---|---|
| 文件 | `enc_top_disp_v85.bit` |
| 大小 | **1,699,249 B** |
| 生成时间 | 2026-11-03 15:49:59 |
| SHA-256 | `03F12968BB743F9D5DA58FB5D79E3262D7E0B818743AFA6BF5480EA268B9E42E` |
| 顶层 / 器件 | `enc_top_disp` / `xc7a35tfgg484-2` |
| 构建号 | `RTL_BUILD_ID = 0x0018`（读 `0x05F2` 应为 `0x0018`） |
| 宏定义 | `ENC_DISP_TAP`、`ENC_V69_CPR2048`（生产位流不能带 `ENC_DISP_TAP`） |
| 工具 | Vivado v2026.1 (win64) Build 6511674 |

## 3. 时序与资源（`disp_timing.rpt` / `disp_util.rpt`）

| 指标 | 值 |
|---|---|
| WNS / TNS | **+0.175 ns / 0.000** |
| 失败端点 / 总端点 | **0 / 35,126** |
| WHS / THS | **+0.043 ns / 0.000**（0 失败） |
| LUT | **18,088 = 86.96%**（20,800） |
| FF | **12,154 = 29.22%**（41,600） |
| BRAM | **48 / 50 = 96.00%** |
| DSP | **26 = 28.89%**（90） |
| Bonded IOB | **104 = 41.60%**（250） |
| 布线 | 29,278 / 29,278 可布网全部布通，**0 routing error**（45,370 逻辑网） |
| DRC | 生成位流前 DRC **0 Error**（`disp_drc.rpt` 仍有 REQP-1839/1840 规则上限提示，均为 Warning 级） |

与 v74 显示位流（WNS +0.422 / LUT 17,604 / DSP 22）相比，v85 多用了
**484 LUT、4 DSP**，WNS 从 +0.422 降到 **+0.175**，仍在 50 MHz 下收敛。
主要增量来自 P4 双窗口单次触发采样器（v78 重写）与 P7 相对误差曲线（v85）。

## 4. 相对 v74 显示版改了什么（只列可核对的差异）

| 版本 | 改动 | 依据 |
|---|---|---|
| v75–v77 | P2 三档时基、P4 双窗口雏形、P1 面板压暗、P7 零线与 GAIN 显示 | 上板目视记录（`docs/DEV_STATUS.md`） |
| v78 | P4 改为**电角度过零单次触发 + 冻结**，替代按角度永久覆盖写；消除"零星短横线"与上下区相位乱跳 | `disp/p4_scope.v` 文件头 §根因 |
| v83 | P1 的 `U● V● W●` 从标签层（11×14）移到数值层（30×48），与 `A● B● Z●` 同字号 | `disp/uv_state.v` 文件头 |
| v85 | P7 改为**相对全帧均值的误差曲线**（±2% 满量程、P-P/RMS 同口径），先寄存再算行号，修掉 38 级组合路径 | `disp/p7_view.v` 文件头 |
| v85 | P1 `Z计数` 加 **5 ms 可重触发抑制窗**，避免停位抖动把 32 位计数打爆 | `disp/z_cnt_lab.v` 文件头 |

`disp/text_ram.v` 由 `tools/gen_text_ram.py` 重新生成；`disp/enc_top_disp.v`
未改端口。`rtl/` 与本次构建用的 `_synth_work_v74/rtl_v74/` 有 6 个文件仅注释
措辞不同（匿名化改写，综合语义一致），逐文件哈希见 §6。

## 5. 构建与下载（可复现）

```powershell
# 构建（Vivado 2026.1；输出名沿用 v74 目录，属历史命名）
vivado -mode batch -source tools/impl_check_disp_v74.tcl

# 产物
#   _impl_disp_v74/enc_top_disp_v74.bit   ← 与 v85 位流同源
#   _impl_disp_v74/impl_timing.rpt 等报告

# 下载（示例，实际端口以本机为准）
vivado -mode batch -source _flash2_work/prog_v85.tcl
```

> 构建脚本里 `RTLDIR = _synth_work_v74/rtl_v74`，`disp/` 取当前工作树
> （自动排除 `tb_*`）。要复现同一份位流，必须使用与本目录
> `VARIANT_INFO.txt` 一致的 RTL 变体与当前 `disp/`。

## 6. 文件清单

| 文件 | 内容 |
|---|---|
| `enc_top_disp_v85.bit` | v85 显示位流 |
| `disp_timing.rpt` | 实现后时序摘要（WNS/WHS/路径组） |
| `disp_util.rpt` | 资源利用率 |
| `disp_drc.rpt` | DRC 报告（0 Error） |
| `disp_route.rpt` | 布线统计（0 error） |
| `disp_check_timing.rpt` | `check_timing -verbose` |
| `disp_clkint.rpt` | 时钟交互 |
| `disp_io.rpt` | IO 分配 |
| `disp_top_paths.rpt` | 最差路径 |
| `disp_hold_paths.rpt` | 保持路径 |
| `disp_eth_rx_paths.rpt` | `eth_rxc` 相关路径 |
| `disp_impl.log` | 完整构建日志（2026-11-03 15:45–15:50） |
| `prog_v85.log` | JTAG 下载日志（16:50:56，`PROGRAMMED_OK`） |
| `impl_check_disp_v74.tcl` | 本次构建所用脚本副本 |
| `VARIANT_INFO.txt` | v74 RTL 变体说明（构建号 0x0018、与 `rtl/` 仅差构建号） |

## 7. 状态与边界（如实登记）

- ✅ 时序收敛、布线完整、DRC 0 Error、位流生成并下载成功（`PART=xc7a35t`，
  `IDCODE=00000011011000101101000010010011`）。
- ⚠️ **未做逐页目视验收**：下载后没有留下五页 UI 的屏摄与读数记录；
  文档与海报不得引用 v85 作为"已上板验收"证据。
- ⚠️ 显示位流 BRAM 已 96%、LUT 86.96%，**没有余量再加帧缓冲或整页**；
  后续若加功能，先减页或改用外部存储。
- ⚠️ 本目录不替代 v74 生产位流的签核地位：参赛提交、时序签核、量产口径
  一律以 [`../v74/`](../v74/) 为准。
