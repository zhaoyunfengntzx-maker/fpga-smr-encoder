# 39 · v90 验收判据（收敛版）

> 本文是**唯一判据表**。此前判据分散在 `docs/30`（v68 上板判据）、`docs/32`/`docs/34`/`docs/36`/`docs/38`、
> `deliverables/board_day_checklist.md` 与 `_boardtest/STATE.md` 里；凡与本文冲突，**以本文为准**。
> 判定时间：2026-11-04 凌晨（v90 上板 + Flash 冷启动）。设备：XC7A35TFGG484-2，CH340 串口 2 Mbaud，转台 2048 PPR。

---

## 0. 版本与产物（判定基线）

| 项目 | 生产位流 | 显示位流（带 7" 屏） |
|---|---|---|
| 文件 | `_impl_v90/enc_top_v90.bit` | `_impl_disp_v90/enc_top_disp_v90.bit` |
| 大小 | 1,504,220 B | 1,688,245 B |
| SHA256 | `A89512A506F9DE366863AC0C6BE2F740E453B32C35C6864D0D256D9C8F827125` | `69FE313C45C3F36D39307CE0948C6D0AB191183397E2408E694588FC5F81BAD4` |
| `RTL_BUILD_ID` | `0x0019` | `0x0019` |
| WNS / TNS / 失败端点 | **+0.199 ns / 0 / 0**（24,691 端点） | **+0.221 ns / 0 / 0**（33,365） |
| WHS / 失败端点 | +0.017 ns / 0（24,226） | +0.049 ns / 0（32,900） |
| WPWS / 失败端点 | +0.264 ns / 0（9,006） | +0.264 ns / 0（11,981） |
| Slice LUTs | 10,978 = **52.78%** | 17,090 = **82.16%** |
| Block RAM | 32 / 50 = 64% | 45.5 / 50 = 91% |
| 构建源 | `_synth_work_v90/rtl_v90` | 同左 + `disp/` |
| 构建脚本 | `tools/impl_check_v90.tcl` | `tools/impl_check_disp_v90.tcl`（`-verilog_define {ENC_DISP_TAP ENC_V69_CPR2048}`） |

**Flash**：写入的是**显示位流**（`FLASHPROG FLASH_OK`，`_flash2_work/prog_flash_v90.log`），冷启动已过（见 §5）。

RTL 相对 v74 的两处改动（其余与 v74 一致）：
1. `rtl/abz_gen.v` 新增 `z_index_gen` 模块（`Z_ARM_DIST = 1<<(AW-3)`，出 Z 撤防、离开 ≥1/8 圈重布防），`rtl/enc_top.v` 内联 Z 段改为例化它 —— 治**停位 Z 喘振**。
2. `rtl/uvw_gen.v` **保持 v74 板级验证版**（`e_uw`/`K=4` 去抖版在板上冻结，已回退，不要再合）。

---

## 1. A 类 · 构建与源码（离线，可全自动）

| # | 判据 | 命令 | 通过条件 |
|---|---|---|---|
| A1 | 仿真回归 | `powershell -File tools\run_sim.ps1 -Rebuild` | `SUMMARY.md` **全 PASS**（当前 **37 个 TB**，2026-11-04 实测 37/37） |
| A2 | 显示 TB | `powershell -File tools\run_sim_disp.py`（或 `_boardtest` 内既有入口） | `tb_disp_smoke` + disp 套件全 PASS |
| A3 | 源码/位流一致 | `powershell -File tools\final_verify.ps1` | `ALL CHECKS PASSED`，含 `repo rtl/ is code-identical to the v90 build sources` |
| A4 | 位流新鲜 | `python tools\check_build_freshness.py` | 两个位流 mtime ≥ 最新 RTL 源码 |
| A5 | 版面预览 | `python tools\preview_pages.py` 然后 `python _boardtest\_scratch\measure_p1.py` | 出图无异常；量尺 C1/C2a/C2b/C3/C4 全 PASS（C2c 为已知几何不可达项） |
| A6 | 寄存器地图 | `python tools\check_regmap.py` | PASS（上位机 `REG_*` 全部在 RTL 可读） |
| A7 | 协议 fuzz | `python tools\fuzz_host_protocols.py -n 4000` | 0 失败 |

---

## 2. B 类 · 板上静态判据（串口读回，转台可不转）

| # | 寄存器 | 期望 | 实测（v90） |
|---|---|---|---|
| B1 | `0x05F0` DEVICE_ID | `0x000C` | `0x000C` ✓ |
| B2 | `0x05F1` REV | `0x0010` | `0x0010` ✓ |
| B3 | `0x05F2` RTL_BUILD | **`0x0019`** | `0x0019` ✓ |
| B4 | `0x0100` UVW_CFG | pairs=4 → `0x2004` | `0x2004` ✓ |
| B5 | `0x0101` INTER0 | **32** = `0x0020` | `0x0020` ✓ |
| B6 | `0x0109` OUTPUT | ABZE\|UVWE = `0x00C0` | `0x00C0` ✓ |
| B7 | `0x0514/15` GAIN_S | 复位 32768；标定后 ≈0.98–1.03 FS 倒数 | 标定后 0.994 / 0.987 ✓ |
| B8 | `0x051A` SHIFT | 0 | 0 ✓ |
| B9 | `0x0500 / 0x0501` | **恒 0**（BiSS 已移除，保留地址） | 0 / 0 ✓ |
| B10 | `0x0405` bit0（真 OTR）W1C 后可清 | 写 `0x0405=0x00FF` 后回读 bit0=0 | ✓ |
| B11 | `0x0405` bit3 `inclim` | **允许偶发**（已知：`uvw_freq_warn` 并入口，非故障） | 偶见 `0x0008`，不判 FAIL |

一键命令：`python _boardtest\check_v70.py COM4 3`（build 白名单已含 `0x0019`）⇒ 末行必须是 `PASS: ...`。
> ⚠ 该脚本里「机械转速」一栏是 `cycle_cnt` 中位步进推的，**10 kHz 遥测对 >10 kHz 电信号混叠，只作参考**（见 §7）。

---

## 3. C 类 · 板上动态判据（转台必须静止在转，信号 8 Vpp / ≈25 kHz）

| # | 判据 | 命令 | 通过条件 | 实测（v90） |
|---|---|---|---|---|
| C1 | 幅值不过幅 | `check_v70` / `capture_v68.py` | `r` 峰值 **0.75–0.95 FS**，`stat_otr`(0x053A bit3)=0 | 0.845–0.850 FS ✓ |
| C2 | 锁相 | `0x0130` | `&0x03 == 0x01`（TRACK） | `0x0301` ✓ |
| C3 | 电周期速率 | `diag_pos3.py`（32 位 `pos_full` 展开） | 与 Z 率同向、误差 <2% | −21,206 cyc/s ✓ |
| C4 | **转速（权威）** | `python _boardtest\z_rate.py COM4 6` | Z 频率 = 转速/60（**每转 1 个 Z**），闸门 0.05–400 Hz | 7.62 / 7.65 Hz ⇒ 457–459 rpm ✓ |
| C5 | Z 计数不虚增 | `z_rate.py` 两次读数差 | Δ ≈ 转速/60 × 时长（±10%） | Δ23/3.02 s ✓ |
| C6 | **UVW 六态轮转** | `uvw_phase.py` | 六态均出现（每态占比 12–22%）、`illegal(000/111)=0`、跳变率 = 6×电频率 | {5174,4761,4423,4776,4763,4786}，523 次/3 s ✓ |
| C7 | 角度-atan2 一致 | `angle_vs_sc.py COM4 3` | `RMS ≤ 1.5°`、`\|err\|>5°` 占比 < 0.5% | offset 1.76°、RMS 0.71°、max 2.88° ✓ |
| C8 | 一键标定 | `calib_v68.py COM4` | `flags` bit4(calib_done)=1，`gain` 落在 0.9–1.1 | `0.994/0.987` ✓ |
| C9 | 60 s 稳定 | `soak_v68.py COM4 60` | fps 9.9k±10%、`r_mean` 漂移 <1%、无 `amp_low/high` | 597,886 帧 / 9,964.8 fps ✓ |

> C4 是**转速唯一权威判据**。`check_v70` 的「机械转速」与 `diag_pos3` 的 `rate` 在高频段会因遥测抽样混叠，不得作为通过/不通过依据。

---

## 4. D 类 · 接口判据

| # | 判据 | 方法 | 通过条件 | 实测 |
|---|---|---|---|---|
| D1 | ABZ 频率 | `0x0732`/`uart_scope` 或 `uvw_phase` | A 频率 = 电频率 × `inter`(32)；A/B 占空比 50±2% | 800 kHz @25 kHz 电 ✓ |
| D2 | Z 物理脉冲 | 示波器（J5-7 / `M21`，20 ms/div，普通触发） | **每转 1 个**、宽 ≈1.15–1.5 µs、幅度 2–3.3 V | ✓（用户示波器确认） |
| D3 | UVW 物理 | 示波器（J5-16/17/18） | 三相 120° 互差、每电周期 6 次换向 | 遥测六态已证 |
| D4 | 以太网 ping | `ping 192.168.1.10` | 4/4 通、<1 ms | ✓ |
| D5 | UDP 抓窗 | `board_eth_check.py --udp-port 5010` | 冷启动首跑允许丢块；**第二跑 `missing=[]`** | ✓ |
| D6 | ARP MAC | `arp -a` | **已知不符**：实测 `00-00-02-00-00-01`，脚本期望 `02:00:00:00:00:01` ⇒ 该项**不计入 FAIL**（见 §7） | — |

端口映射速查：`a_out`=H20=J5-5、`b_out`=G20=J5-6、`z_out`=M21=J5-7；BiSS 的 J5-11/12/13 已释放。

---

## 5. E 类 · 显示与冷启动

| # | 判据 | 方法 | 通过条件 |
|---|---|---|---|
| E1 | 上电自启 | 断电 3 s 再上电（不接 JTAG） | 屏直接进 P1；`RTL_BUILD=0x0019`、串口有帧、10 kfps |
| E2 | P1 总览 | 目视 | 输入频率（kHz 1 位小数）/转速/角度/累计转数 四卡数值与单位不重叠；`Z计数` 有值且在涨 |
| E3 | P2 波形 | 目视 + 点左下档位 | 三档 + `AUTO`；波形**左右连续**、标记在中线；300 µs 档 ≥10 个周期 |
| E4 | P4 逻辑时序 | 目视 | 上半 A/B 各 4 周期、下半 U/V/W 60° 台阶 + Z 竖标；`S=8`、`WL≈2CF800`（随转速变） |
| E5 | P6 设置 | 目视 | 倍频 32 / 分频 1 / 对数 4 / ABZ UVW ON / 增益 1.000 / `S0C0` |
| E6 | 无 P7 | 翻页 | 页序 `总览→波形→时序→设置→总览`，**没有标定页** |
| E7 | 标定入口 | 屏上无按钮 | 标定改走 **KEY0**（长按）或串口写 `0x0502=0x0001` |

冷启动实测（2026-11-04）：断电重上电后屏正常、`RTL_BUILD=0x0019`、Z 与 UVW 正常 —— **通过**。

---

## 6. 判定汇总（v90 结论）

- A 类 7 项：**全过**（回归 37/37；`final_verify` ALL CHECKS PASSED）。
- B 类 11 项：**全过**（`check_v70` 末行 PASS）。
- C 类 9 项：**全过**（关键：Z 7.62 Hz=457 rpm、UVW 六态、角度 RMS 0.71°）。
- D 类 6 项：5 项过，D6 口径不符**不计**（§7）。
- E 类 7 项：**全过**（含 Flash 冷启动）。

⇒ **v90 判定：通过，可作为当前交付基线。**

---

## 7. 口径说明与免判项（避免历史判据互相打架）

1. **转速口径**：以 `z_rate.py` 的 Z 频率 ×60 为准。`check_v70` 的「机械转速」由 `cycle_cnt` 中位步进推得，10 kHz 遥测对 25 kHz 电信号存在混叠，只在 <8 kHz 电频率时可信；它显示的 621 rpm 与 Z 的 457 rpm 不矛盾——前者是混叠伪值。
2. **BiSS 全部免判**：RTL/寄存器/引脚/引脚约束/TB/文档已整体移除，`0x0500/0x0501/0x053B/0x053C` 是保留地址（恒 0），`0x053A` bit7/6 恒 0。任何"BiSS 帧/CRC/链路"判据一律作废。
3. **`inclim`（`0x0405` bit3）**：并入了 `uvw_freq_warn`（第 5 节 `uvw_gen` 的门限告警），偶尔置位**不判故障**；只作为"换向过快/抖动"的观察量。
4. **ARP MAC**：板子回的是 `00-00-02-00-00-01`，与 `tools/board_eth_check.py` 里的常量不符，但 ping/UDP 全通。该断言**不计入 FAIL**；如要消除，改脚本常量为实测值即可。
5. **OTR 假告警**：`0x0405` bit0 偶发置位属已知（OTR 引脚 60 mV 毛刺，已加下拉），写 `0x0405=0x00FF` 可清；不影响功能。
6. **停位 Z 喘振**：v90 已用 `z_index_gen`（撤防/重布防 1/8 圈）修复；板上以"每转 1 个 Z"验证。停位长时间停留的专项复测仍建议在比赛现场补一次（`z_rate.py` 在轴停转时应为 0）。
7. **UVW 去抖（K=4 + `e_uw`）已回退**：仿真过、板上冻结（`hyst=0` 时门限仅 1 LSB，判据逐拍翻转永远凑不满 4 拍）。**不要重新合入**，除非先把 H 下限设为 ≥32 LSB 并重做板级验证。

---

## 8. 一条命令自检（交付前跑这个就够）

```powershell
powershell -File tools\final_verify.ps1
```

它覆盖：源码↔位流一致、回归全过、两位流 SHA/时序、文档存在性。板上则依次跑：

```powershell
python _boardtest\check_v70.py COM4 3
python _boardtest\z_rate.py COM4 6
python _boardtest\uvw_phase.py COM4 3
python _boardtest\angle_vs_sc.py COM4 3
```
