# v72 / v73 上板调试报告（2026-11-02）

> 本文记录**接板当天的完整上板过程**：v71 生产位流全项实测 → 发现屏上 RPM 荒谬（496729.5）
> → 定位到显示子系统除数位宽溢出 → v72 修好并在板上确认 → 为搞清"Z 到底有没有出"加了一个
> Z 上升沿计数探针（v73）→ Z 量化通过（12.00 Hz / 720.0 rpm，每转 1 个）→ 冷启动固化到
> QSPI Flash 并断电重上电验证通过。
>
> 相关文档：`docs/35_v71_release_report.md`（Z 索引修复）、`docs/34_audit_report.md`（全量审计）、
> `docs/32_board_test_report_2026-11-01.md`（v68 首轮上板）、`deliverables/board_day_checklist.md`。

---

## 1. 结论

| 项目 | 结果 |
|---|---|
| v71 生产位流（BUILD 0x0016）功能 | **全项通过**：身份/寄存器/锁定/幅值/一键标定/角度一致性/60 s 长跑/以太网 |
| 屏幕 RPM（v71 显示位流） | **496729.5 rpm**，荒谬 → 定位为 `disp/val_format.v` 除数位宽溢出 |
| v72（修除数位宽） | 板上 **RPM ≈770–780**，与同时刻实测 775.6 rpm 一致 ✅ |
| Z 索引脉冲 | 板内计数 **12.00 Hz → 720.0 rpm**；示波器 J5-7 实测 **≈1.15 µs 宽、≈2.5 V** 的窄脉冲 ✅ |
| UVW | 六状态均匀轮转（各 ~13%，换向 ~294–310 次/s）✅ |
| Flash 固化 | `FLASH_OK`；**断电重上电后屏正常启动、BUILD=0x0017、Z=12.26 Hz** ✅ |

---

## 2. v71 生产位流上板实测（BUILD 0x0016）

串口 **COM7**（CH340 重新枚举后端口号从 COM4 变为 COM7，脚本一律显式传端口）。

```
check_v70.py COM7 3
  RTL_BUILD=0x0016  INTER0=0x0020  inter=32  UVW_CFG=0x2004
  frames=28664  fps=10616      r max=0.853 FS
  UVW 六态 {1:5113, 2:4826, 3:4326, 4:4818, 5:4757, 6:4824}
  lock=0x0301  stat_flags=0x0000
```

| 测试 | 命令 | 结果 |
|---|---|---|
| 身份/寄存器 | `_boardtest/check_v70.py COM7 3` | PASS（build 0x0016 / inter 32 / gain 1.0 / TRACK） |
| 原始 ADC | `tools/cap_dump.py --port COM7 --dec 1` + `_boardtest/freq_check.py` | f0 = 8657 / 8664.5 Hz，A=25228/25669，正交 −88.82°，失配 1.73% |
| 一键标定 | `_boardtest/calib_v68.py COM7` | gain_s 32768→33567、gain_c→33316、flags=0x0010（calib_done） |
| 角度一致性 | `_boardtest/angle_vs_sc.py COM7 3` | offset 0.980°、RMS 0.720°、max 3.016°、h1..h4 ≤0.027° |
| 60 s 长跑 | `_boardtest/soak_v68.py COM7 60` | 597,746 帧 / 9,962 fps，UVW 六态均衡，a/b = 50.05/49.98%，\|err\|>5° 共 **0** 帧 |
| 以太网 | `_boardtest/set_udp_port.py COM7 5010` + `tools/board_eth_check.py --udp-port 5010` | ping 4/4，抓窗 28,672 点 @25 MSPS，第二次 `missing=[]` PASS |

> **口径提醒**：`check_v70.py` 里的"电周期速率"用 16 位 `cycle_cnt` 中位步进，转台 >8.7 kHz 电频率时
> 会混叠（板上实测 25 kHz），**不可用作转速判据**；转速请看 `_boardtest/diag_pos3.py`（32 位
> `pos_full`）或 v73 起的 Z 计数器。

---

## 3. v72：显示 RPM 除以 0（真正的 bug）

### 3.1 现象
屏上转速字段显示 **496729.5**。转台实际 ~775 rpm。

### 3.2 根因（`disp/val_format.v`）
RPM 字段算的是

```
rpm_x10 = f_mag40 * 75 / (128 * cpr)          // cpr = 每圈电周期数
```

而除数原先只有 16 位：

```verilog
wire [15:0] div_den = (fld == 3'd2) ? (cpr_s << 7) : cpr_s;   // ← 2048*128 = 262144 截成 0
```

`CPR = 2048` 时 `2048 × 128 = 262144`，截断到 16 位就是 **0**；`disp/fixed_div.v` 在除数为 0 时
按注释"商自然饱和到全 1"给出最大值，于是屏上出现 496729.5。

v68 用 `CPR = 64`（`64 × 128 = 8192`）刚好不溢出，所以 2026-10-30 那次"看起来正常"。

### 3.3 修法
```verilog
wire [19:0] div_den = (fld == 3'd2) ? ({4'd0, cpr_s} << 7) : {4'd0, cpr_s};
reg  [19:0] div_den_r;
fixed_div #(.W(40), .DW(20)) u_div ( ... );
div_num_r <= rpm_num + {20'd0, div_den[19:1]};   // 四舍五入项同步加宽（累计转数字段同样处理）
```
`disp/fixed_div.v` 本身参数化（`W`/`DW`），不用改。

### 3.4 验证
- 新增 `_boardtest/_scratch/tb_div20.v`（ModelSim）：`rpm_x10@CPR2048 = 7324`（=732.4 rpm @25 kHz）、
  `revs@CPR2048 = 2`、`rpm_x10@CPR64 = 234375` ⇒ **TEST PASSED (div20)**。
- 板上：v72 显示位流下载后，屏上读数 **≈770–780 rpm**，与串口侧 775.6 rpm 一致。

---

## 4. v73：给 Z 加"计数探针"，把 Z 从"看波形"变成"读数字"

### 4.1 为什么要加
Z 是 FPGA **合成输出**（`z_out` → M21 / J5-7），每转一个、宽度只有几个 AB 边沿步。
用示波器在 20 ms/格 上根本看不到，且极易把 **A/B 的 800 kHz**（`f_elec × inter = 25 kHz × 32`）
误认成 Z（现场就发生了）。

### 4.2 实现（`rtl/enc_top.v` + `rtl/reg_file.v`）
```verilog
reg         z_out_d;
reg  [31:0] z_pulse_cnt;
always @(posedge clk_i or negedge rst_n) begin
    if (!rst_n) begin z_out_d <= 1'b0; z_pulse_cnt <= 32'd0; end
    else begin
        z_out_d <= z_out;
        if (z_out & ~z_out_d) z_pulse_cnt <= z_pulse_cnt + 32'd1;
    end
end
```
只读寄存器 **0x054A..0x054D**（`stat_z_cnt` 32 位）。不参与任何功能逻辑；LUT 只多 40 个
（52.73% → 52.92%）。

> ⚠ 声明位置必须在 `reg_file` 例化**之前**，否则 Verilog 会把它当隐式 wire，
> ModelSim 报 `vlog-2388 'z_pulse_cnt' already declared`（已踩）。

### 4.3 板上量化（`_boardtest/z_rate.py COM7 3`）
```
RTL_BUILD=0x0017
窗口 3.00 s  frames=30245
Z 计数 1162829 -> 1162865  (Δ=36)  Z 频率 = 12.00 Hz
由 Z 反推转速 = 720.0 rpm（每转 1 个 Z）
PASS
```
- 与用户转台读数 **720 rpm 完全一致**（12.00 × 60）。
- 另外两次：`11.91 Hz → 714.7 rpm`、`12.26 Hz → 735.3 rpm`（转台转速有漂移）。
- 示波器复测 J5-7：**≈1.15 µs 宽、≈2.5 V 的窄脉冲**，频率档显示 `<10 Hz`（自动量程下限），
  与计算值 `5 个 AB 边沿步 / (4·inter·f_elec) ≈ 1.5 µs` 相符。

---

## 5. 示波器判读纠错（值得写进排障手册）

| 看到的现象 | 判读 |
|---|---|
| 1.25 µs 周期方波 = **800 kHz**（1 V/div） | **A（或 B）输出**，`f_elec × inter = 25k × 32`；这是**对的** |
| 该方波边沿处 100 mV/div 的窄毛刺 | A 边沿串扰，不是 Z |
| J5-7 上 20 mV/div 一片噪声、偶发一根尖峰 | 探头档位/接触问题（20 mV/div 太小）；改 1 V/div 后即见干净脉冲 |
| Z 的 20 ms/格 一根直线 | **正常现象**：Z 只有 ~1.5 µs 宽、12 Hz，占空比 1.8e-5 |

---

## 6. Flash 固化（QSPI，掉电启动）

```
$env:FLASH_BIT='C:/Users/zhaoy/Desktop/FPGA/_impl_disp_v73/enc_top_disp_v73.bit'
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/program_flash.tcl -LogFile flash_v73.log -Tail 30
```
- `tools/program_flash.tcl` 自动完成：`write_cfgmem`（SPIx1、16 MB、checksum、disablebitswap）
  → 先烧 `spi_xc7a35t_pullnone.bit`（SPI 桥）→ `program_hw_cfgmem`（擦/写/校验）→ `boot_hw_device`。
- 结果：`FLASHPROG FLASH_OK`。
- **冷启动验证（用户执行）**：拔电源 3 s 再上电 ⇒ 屏正常启动、RPM ≈720；串口侧读回
  `RTL_BUILD=0x0017`、`Z 频率 12.26 Hz`、`frames 10.9 kfps`、UVW 六态 ⇒ **固化链路打通**。

---

## 7. 本轮踩过的坑（按代价排序）

1. **把 800 kHz 当成 Z** —— 浪费了一轮示波器排查。记住：`A/B 频率 = f_elec × inter`，
   2048 PPR 的 Z 是 `rpm/60` Hz。
2. **只读 8 位寄存器必须 `&0xFF`** —— `0x0500` 读回 1307（=0x051B，邻字节混入），`&0xFF` 得 27。
3. **PowerShell 内联 `-c` 传含引号/`$` 的 Python 代码必被解析坏** —— 一律写 `.py` 文件再执行。
4. **PowerShell `Set-Content -Encoding UTF8` 写 `.v/.tcl/.ps1` 会带 BOM/破坏中文** ——
   改文件用 `edit`/`write` 工具或 Python（`utf-8-sig` 读、`utf-8` 写）。
5. **`edit` 工具会把 `.ps1` 的 BOM 去掉**，PS 5.1 随后按 GBK 解码中文 ⇒ 语法错；
   `.ps1` 改完要用 Python 以 `utf-8-sig` 重写。
6. **生成新版本构建 tcl 时，路径替换要连 `_synth_work_vNN` 一起换** ——
   只换 `rtl_vNN` 会得到不存在的 `_synth_work_v71/rtl_v73`，Vivado 报
   `Unable to run synthesis. No HDL sources found in project`。
7. Verilog 里**信号声明必须早于例化端口列表中的使用**，否则隐式 wire 与后续 `reg` 重名。

---

## 8. 仍未完成（接板下一轮）

| 项 | 状态 |
|---|---|
| UVW 三相 120° 相位与 A/B 正交度（示波器） | **逻辑侧已量化通过**（见 §8.1）；示波器逐相波形仍可选 |
| Z 停位喘振（停在索引位 ±0.5° 微动） | 未测（审计报告 B8 仍挂） |
| ARP MAC 口径（实测 `00:00:02:00:00:01` vs 脚本期望 `02:00:00:00:00:01`） | 未定（审计报告 B5） |
| 显示子系统仿真覆盖（0 个 TB） | 未补（审计报告 B2） |
| 2 h 长跑 | **5 min 已完成**（`soak_v68.py COM7 300`，见 §8.2）；2 h 版本脚本已备好（`... 7200`），需现场保持转台转速 |

### 8.2 5 min 稳定性（`_boardtest/soak_v68.py COM7 300`）

```
frames=2979083 (v1/无io帧=13)  elapsed=300.0s  fps=9930.3
r: min=2026 mean=26076 max=42177 (max=1.2871 FS)
lock now=0x0301  stat_flags now=0x0008
UVW state counts: {1:538207, 2:494716, 3:457534, 4:495091, 5:496046, 6:497476}
level%%: a 50.04  b 50.01  z 0.0  u 50.08  v 48.66  w 49.97
flips: a 1489582  b 1489916  u 30601  v 30535  w 30603  z 128
angle vs atan2 (r>0.5FS, every 5th): mean|err|=2.996 deg  n=595814  |err|>5deg=1628 (0.27%)
```

- 297.9 万帧、9,930 fps 稳定，`lock` 全程 TRACK，无失锁；
- 每 10 s 的 `r_mean` 只在 26073–26081 之间漂（<0.03%），AB 占空比 50.04/50.01、UVW 六态均衡；
- `|err|>5°` 占 0.27%（对 3° 固定流水线时差而言，属偶发幅度跌落，与 v70/v71 结论一致）；
- `r max 1.287 FS` 是瞬时峰值（含噪声/机械抖动），不进判据。

### 8.1 UVW 相位（新脚本 `_boardtest/uvw_phase.py`，不用示波器）

只读遥测帧里的 `io_state`（v2 布局**偏移 8**；偏移 9 读到的是恒定值，我一开始就踩了这个坑），
逐样点恢复 (u,v,w) 再统计：

```
frames=29904  dur=3.00s  dt=100.3 us
state counts: {1: 4949, 2: 4987, 3: 4988, 4: 5403, 5: 4975, 6: 4602}
illegal(000/111) samples: 0
transitions=925  fps_of_transition=308.33 Hz
gap(us): min=100 med=3210 mean=3244 max=3812  | f_elec=51.39 Hz, 1/6 周期=3243 us
duty u=0.501 v=0.487 w=0.499
order: forward=922 backward=0 irregular=2
PASS: UVW six-state rotation, 120-degree spacing, fixed phase order
```

要点：六态均匀、无 `000/111`、每相占空比 ≈0.5、状态间隔中位数 **3210 µs** ≈ 理论 **3243 µs**
（电周期 19.46 ms 的 1/6，100 µs 采样分辨率下差 1%）、相序**严格单向**（922 forward / 0 backward）。
另外 A 相 800 kHz 已在示波器上确认（`f_elec × inter = 25 kHz × 32`），与 UVW 的 51.39 Hz × 4 对极一致。

---

## 9. 本版产物

| 文件 | 字节 | 时间 | SHA256 |
|---|---|---|---|
| `_impl_v73/enc_top_v73.bit` | 1,489,772 | 11:37:09 | `2E081D4E63B11C4BB951C56F5FAB3E02CDF8E96A282507E5C57F2C3D8C9F31F4` |
| `_impl_disp_v73/enc_top_disp_v73.bit` | 1,662,197 | 11:48:40 | `0567A4E649CEFB7663883188A6690778B66B5686D661FDE8B479587F6C6954C0` |
| `_impl_disp_v72/enc_top_disp_v72.bit`（仅 RPM 修复，未固化） | 1,651,333 | 11:17:12 | `55D670C89609531077A611FEBDED8B735B44046B01C6EEC46A584145BF2BC08A` |

时序/资源（v73 生产）：WNS **+0.220** / TNS 0 / 0 失败（24,889 端点），WHS +0.049，
LUT 11,008 (52.92%)，FF 8,791 (21.13%)。
时序/资源（v73 显示）：WNS **+0.328** / TNS 0 / 0 失败（34,499），WHS +0.049，WPWS +0.264。
