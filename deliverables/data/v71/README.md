# v71 证据归档（2026-11-02）

v71 = **v70 + Z 索引脉冲修复**。v70 已把 2048 PPR / 位置计数 / UVW 修好并上板验收；
v71 在全量代码审计（[`docs/34_audit_report.md`](../../../docs/34_audit_report.md)）中发现并修掉
**B1：Z 索引脉冲在当前 RTL 上根本不出**，重建生产与显示两个位流。

> **状态**：仿真全绿（36/36），位流已构建并签核；**尚未上板**（板卡 2026-11-01 夜已断开）。

## 1. 与 v70 的差异

| 项 | v70 | v71 |
|---|---|---|
| Z 索引取窗 | `cycle_cnt[POLE_BITS-1:0]==0`（1 拍宽，与绝对角度错位 ⇒ Z 永不出） | **绝对角度过零**（7/8 → 1/8 圈）+ 自由圈计数 `rev_cnt` 仲裁 + 6 拍展宽 |
| Z 装载 | `r_z_prev_hi` 窗外清零，`z_load` 只看 hi→lo | `r_z_prev_hi` 常跟随；跨零挂起令牌 `r_pend_ttl`(8)；按方向选边沿 |
| `clr_on_z` | `1'b1`（Z 时清 `cycle_cnt`） | **`1'b0`**（清零会让 `mech_angle` 跳变、UVW 误报频率越限，且破坏多圈计数） |
| BUILD_ID | 0x0015 | **0x0016** |
| 其余 | `POLE_BITS=11`、INTER0=32、GAIN=1.0（与 v70 相同） | 同左 |

根因（关键）：`pole_counter` 的 `phase_acc` 是"从复位时刻开始累加"的展开相位，
**它的回绕点对应复位瞬间的绝对角度（实测 343°）**，而 ABZ 的 `z_phase=0` 跨零在 0° ⇒ 窗与跨零沿永久错位。
v68 之所以"看起来有 Z"，是因为那时 `cycle_cnt` 卡 0 ⇒ `z_window≡1`，Z 实际变成"每个电周期都出"。

## 2. 构建签核

| 指标 | 生产 `enc_top_v71.bit` | 显示 `enc_top_disp_v71.bit` |
|---|---|---|
| 大小 | **1,514,668 B** | **1,657,221 B** |
| SHA256 | `456279CD82778F9D0234784284C04402F6377C85993B9660AE599B918741DB28` | `776438A7E27D9B6918AD777E9110F969051D778AE9DC25786642F8762C88A025` |
| WNS / TNS / 失败端点 | **+0.277 ns** / 0.000 / **0**（24,785） | **+0.143 ns** / 0.000 / **0**（34,383） |
| WHS / 失败端点 | +0.047 / 0（24,320） | +0.019 / 0（33,918） |
| WPWS | +0.264 / 0（9,038） | +0.264 / 0（12,065） |
| Slice LUTs | 10,968 / 20,800 = **52.73%** | 17,393 / 20,800 = **83.62%** |
| Slice Registers | 8,756 = 21.05% | 11,557 = 27.78% |
| Block RAM | 32 / 50 = 64% | **48 / 50 = 96%** |
| DSP | — | 19 / 90 = 21.11% |
| IOB | — | 107 / 250 = 42.80% |
| 以太网 RXC 路径 | — | slack **+1.907 ns（MET）** |
| DRC | 无 Error | 无 Error（REQP-1839/1840 各 20 条 Warning，与 v70 同类） |
| 构建日志 | `prod_impl.log`（`Bitgen Completed Successfully`） | `disp_impl.log`（同） |

> Vivado 2026.1 在写完位流后不退出、`puts` 也不刷出 `..._DONE` 行，故以
> `Bitgen Completed Successfully` + 位流时间戳/哈希为准，随后 `Stop-Process vivado` 收尾。

## 3. 仿真

- 全量回归 `tools/run_sim.ps1 -Rebuild`：**PASS 36 / 36**（汇总 `sim/logs/SUMMARY.md`）。
- `sim/tb_enc_top.v`：**106 checks / 0 error**（修前 106 checks / 1 error，`B4-1rev-Z-pulses-1` 红灯）。
  - `FWD: Z_pulses=1`、`Z_width_max=2569 clk`（≈ 5 个 A 边沿步，ABZ 边沿 = 512 clk）；
  - `REV: Z_pulses=1`（反向也有 Z，因为 `z_xing` 按方向选边沿）；
  - `A_edges=4095/4097`（期望 4096）、`ang_cmp` 4,194,240 点 `max_dev=10 LSB16`、`out_of_tol=0`。
- 单模块 ModelSim 秒级验证：`_boardtest/acc_sim/zdbg/`（`vlog ../../../rtl/*.v ../../../sim/tb_enc_top.v` +
  `vsim -c -do "run -all; quit -f"`）。

## 4. 上板实测

**尚未进行**（板卡已断开）。接板后按 [`deliverables/board_day_checklist.md`](../../board_day_checklist.md) §11 执行，
v71 专项：

1. 下生产位流 → `python _boardtest/check_v70.py COM4 3`（白名单已加 0x0016）：
   期望 `RTL_BUILD=0x0016`、`inter=32`、电周期速率 ≈ ±24.7k（转台 25.27 kHz / 2048 PPR）、
   `Z 率 = |rate|/2048 ≈ 12 Hz`、UVW 六态均匀、`r max ≈ 0.84 FS`、`lock=0x0301`。
2. 示波器量 Z（`z_index` 引脚/测试点）：**每圈 1 个**、宽度 ≈ 5 个 A 边沿；反向转也一样。
3. 下显示位流 → 屏上 RPM ≈ **720**（`DISP_CPR = 2048`）。
4. 一键标定（`_boardtest/calib_v68.py`）、以太网（`tools/board_eth_check.py --udp-port 5010`）、
   60 s 长跑（`_boardtest/soak_v68.py COM4 60`）。

## 5. 文件表

| 文件 | 说明 |
|---|---|
| `enc_top_v71.bit` | 生产位流（转台用，无 `ENC_DISP_TAP`） |
| `enc_top_disp_v71.bit` | 显示位流（`ENC_DISP_TAP` + `ENC_V69_CPR2048`） |
| `prod_impl.log` / `disp_impl.log` | Vivado 构建日志（`_flash2_work/build_v71.log`、`build_disp_v71.log`） |
| `prod_*.rpt` / `disp_*.rpt` | 时序、hold、DRC、IO、route、util、clkint、top_paths；显示另有 `disp_eth_rx_paths.rpt` |
| `VARIANT_INFO.txt` | 变体生成信息（源 git、生成时间、补丁清单） |
| `SHA256SUMS.txt` | 本目录 24 件证据的逐文件哈希 |

## 6. 复现

```powershell
# 1) 生成 v71 RTL 变体（只把 BUILD_ID 0x0015 -> 0x0016）
E:\Anaconda\python.exe tools\make_v71_rtl.py

# 2) 生产位流
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_v71.tcl -LogFile build_v71.log -Tail 30
#    产物 _impl_v71/enc_top_v71.bit

# 3) 显示位流（必须等生产构建的 vivado 完全退出，两个 Vivado 不能并发）
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_disp_v71.tcl -LogFile build_disp_v71.log -Tail 30
#    产物 _impl_disp_v71/enc_top_disp_v71.bit

# 4) 回归 + 新鲜度
$env:XILINXD_LICENSE_FILE='D:\Vivado\Xlnx_2026_1.lic'
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Rebuild
E:\Anaconda\python.exe tools\check_build_freshness.py --all-v71
```

## 7. 限制（如实）

1. **未上板**：Z/UVW/RPM 的板上行为仍是仿真结论；`z_width_max=2569 clk` 的实测脉宽待示波器确认。
2. **显示位流资源 96% BRAM / 83.6% LUT**：与 v70 相同量级，没有余量再塞功能；`WHS +0.019` 偏紧。
3. **Z 宽度依赖 6 拍展宽 + 5 拍挂起**：`glitch_guard`/滤波配置若大改，需要重新核对 `Z_width_max`。
4. `clean` 二次上电后 `clr_on_z=0` 意味着 `cycle_cnt` 多圈计数不再被索引清零 —— 多圈绝对位置需要
   主机侧以 Z 为基准做一次偏置，**单圈内角度不受影响**。
5. 审计报告里 B2（显示零仿真覆盖）、B3（TB 配置指纹）、B4–B7 仍未处理。
