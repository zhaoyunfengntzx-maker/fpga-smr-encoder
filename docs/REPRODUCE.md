# 从零复现指南

目标：让一支**没有见过本项目的队伍**，从一台干净的 Windows 机器开始，跑通
仿真、重建位流、烧到板上、并独立判断"做对了没有"。

预计耗时：只跑上位机与仿真 **1 小时**；完整重建 + 上板 **半天**。
所有命令都在仓库根目录执行。当前基线是 **v90（`RTL_BUILD_ID = 0x0019`，2026-11-04）**。

---

## 1. 你需要什么

### 1.1 硬件

| 件 | 型号 / 要求 | 说明 |
|---|---|---|
| FPGA 开发板 | 正点原子 **达芬奇-lite**，XC7A35TFGG484-2 | 50 MHz 系统时钟；工程按此引脚约束 |
| ADC 模块 | 华升 EDA **AD9238** 双通道 12-bit | 与 FPGA 同源时钟、源同步接口；转台 8 Vpp 时用 5:1 衰减 |
| 显示屏 | 7 寸 RGB-LCD，1024×600，电容触摸 | 接 `J7`；引脚见 `constr/enc_top_disp.xdc` |
| 传感头 | SMR 磁阻 sin/cos，差分输出 | 转台实测 8 Vpp、2048 电周期/圈 |
| 下载器 | 板载 JTAG 或 Digilent HS2 | 只影响烧写，不影响构建 |
| 其他 | 12 V 电源、网线、USB 串口、杜邦线 | 以太网默认 `192.168.1.10` |

没有转台也可以复现到"构建 + 仿真"：用信号发生器给两路正交 1 kHz 正弦即可做
开环检查；闭环转速/Z/UVW 需要真实旋转。

### 1.2 软件

| 软件 | 版本 | 用途 |
|---|---|---|
| Vivado | **2026.1**（2024.x+ 一般可用） | 仿真（xsim）、综合、实现、烧写 |
| Python | 3.11+（实测 3.13.9） | 上位机、构建辅助脚本、证据校验 |
| Git | 任意 | 取代码 |
| 串口驱动 | CP210x / CH340（按板子） | 上位机串口 |

Vivado 的 **WebPACK 免费 license 足够**构建 XC7A35T；只有 ILA 调试需要额外
license，本项目复现不需要 ILA。

> 仓库里的 `tools/run_vivado.ps1` 是原作者机器的信封脚本（Vivado 装在 `D:\Vivado`、
> 指定了本机 license 路径）。换机器时**直接调用 `vivado`**，或用你自己的信封脚本；
> 其余 Tcl 脚本已改为自动定位仓库根目录，不依赖绝对路径。

---

## 2. 取代码

```powershell
git clone <仓库地址> FPGA
cd FPGA
```

仓库含约 233 MB 证据（位流、报告、CSV）。只想要代码：

```powershell
git clone --depth 1 <仓库地址> FPGA
```

目录含义见根 [README](../README.md) §4；与赛题推荐目录的对照表也在那里。

---

## 3. 上位机（不需要板卡）

```powershell
python -m pip install -r host\requirements.txt
python -X utf8 host\app.py
```

验证安装（全部应 PASS，退出码 0）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_offline.ps1
```

它依次做：`compileall` → 8 个纯逻辑自检（encoder / alarm / regs / ui_prefs /
abz / recorder / export_png / analysis）→ 界面级 `selftest_ui.py`（offscreen）。
单项也可以手动跑：

```powershell
python -X utf8 host\regs.py --selftest
python -X utf8 host\analysis.py --selftest
$env:QT_QPA_PLATFORM="offscreen"; python -X utf8 host\selftest_ui.py
```

---

## 4. 仿真（不需要板卡）

```powershell
# 编码器 37 台回归
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1

# 显示子系统 20 台回归
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim_disp.ps1
```

- 每个测试台在 `_sim_work/<tb>/` 独立编译，日志在 `sim/logs/`。
- 判定看 `TEST PASSED` / `TEST FAILED` 与退出码；`run_sim.ps1` 最后打印汇总表，
  并把结论写进 `sim/logs/SUMMARY.md`（显示侧写 `disp/logs/SUMMARY.md`）。
- 只跑一台：`-Only tb_abz_gen,tb_uvw_gen`；强制重编：`-Rebuild`。
- **预期**：编码器 **37/37 PASS**（2026-11-04 00:49:22）；显示 **20/20 PASS**
  （2026-11-04 00:03:16）。若某台因本机 xsim 版本差异失败，先看
  `sim/logs/<tb>.log` 的第一条 ERROR。

> xsim 需要可写的 `TEMP/TMP`。脚本已把临时目录钉在仓库内；若你手动调 `xelab`，
> 记得设置 `TEMP`、`TMP`，否则会报 `[XSIM 43-3409] Failed to compile generated C file`。

---

## 5. 重建位流（需要 Vivado）

### 5.1 生成 v90 构建源

```powershell
python tools\make_v90_rtl.py
# 产出 _synth_work_v90/rtl_v90/（24 个顶层 + eth/8 个）
# 仓库 rtl/ 本身就是 v90 交付源（RTL_BUILD_ID = 0x0019），脚本只复制 + 逐条校验，
# 不再改写 BUILD_ID；校验项含 z_index_gen / Z_ARM_DIST / 0x054A / POLE_BITS=11 等。
```

脚本会逐条自检 v90 特征，任何一条不满足立即非零退出；产出与仓库源码**逐字节一致**。

### 5.2 生产位流（编码器本体，无屏无网）

```powershell
vivado -mode batch -source tools\impl_check_v90.tcl
# 产出 _synth_work_v90/enc_top_v90.bit + prod_*.rpt
```

**预期签核值**（v90 基线，可作为对照）：

| 项 | 期望 |
|---|---|
| WNS / TNS | **+0.199 ns** / 0.000 |
| 失败端点 | **0** / 24,691 |
| WHS | **+0.017 ns** / 0 失败 / 24,226 |
| LUT / FF | **10,978 = 52.78%** / 8,724 = 20.97% |
| BRAM / DSP / IOB | 32/50、17、60 |
| DRC | **0 Error** |
| 位流大小 | **1,504,220 B** |

### 5.3 显示位流（编码器 + 4 页 UI + 千兆网）

```powershell
vivado -mode batch -source tools\impl_check_disp_v90.tcl
# 产出 _synth_work_v90/enc_top_disp_v90.bit + disp_*.rpt
```

**预期**：WNS **+0.221** / 0 失败（33,365）、WHS +0.049、LUT **17,090 = 82.16%**、
BRAM **45.5/50 = 91%**、位流 **1,688,245 B**、DRC 0 Error。
显示构建必须带 `ENC_DISP_TAP` 与 `ENC_V69_CPR2048` 两个 define，脚本已写好；
**生产构建绝不能带 `ENC_DISP_TAP`**。

构建时间参考：生产 10–15 min，显示 15–25 min（i5 / 16 GB）。

### 5.4 只想快速验证工具链

```powershell
vivado -mode batch -source tools\synth_check.tcl    # 只综合，不实现
```

---

## 6. 烧写

### 6.1 JTAG（掉电丢失，适合调试）

```powershell
vivado -mode batch -source tools\program_bit.tcl -tclargs _synth_work_v90\enc_top_v90.bit
```

脚本会逐步打印 hw_server / target / device / program 的结果，失败点一目了然。
也可以直接用 Vivado Hardware Manager 的 GUI 流程。

### 6.2 QSPI Flash（掉电保留，适合演示）

按 [`docs/30_flash_program_guide.md`](../docs/30_flash_program_guide.md) 操作，
或 `tools/program_flash.tcl`（用环境变量 `FLASH_BIT` 指到你自己的位流；v90 交付
写的是显示位流 `enc_top_disp_v90.bit`）。**烧完必须断电再上电**，看到屏亮、
串口有遥测，才算 Flash 启动成功；v90 于 2026-11-04 已通过冷启动。

> `program_hw_devices` 会复位整个 FPGA：倍频/分频/环路增益/标定结果全部回默认值。
> 烧完先让上位机重写一遍配置，再做功能测试。

---

## 7. 上板验收

### 7.1 接线与上电

1. 断电接线：ADC 模块、屏排线、网线、USB 串口、JTAG；
2. 12 V 上电，确认板载电源灯；
3. 设备管理器确认串口（如 `COM7`）与下载器；
4. 烧 v90 生产位流（或 v90 显示位流）。

### 7.2 判据（逐项打勾）

| # | 检查 | 通过标准 | 命令 / 位置 |
|---|---|---|---|
| 1 | 器件识别 | IDCODE `0x0362D093`，PART `xc7a35t` | Vivado / `program_bit.tcl` 输出 |
| 2 | 构建号与配置 | `RTL_BUILD_ID = 0x0019`、`DEVICE_ID = 0x000C`、`REV = 0x0010`、`lock = 0x0301` | `check_v70.py COMx 3` |
| 3 | 串口遥测 | 帧率 ≈ 10.6 kHz，无 CRC 错 | `python -X utf8 host\app.py --port COMx` |
| 4 | 幅值 | `r` 峰 0.845–0.850 FS；`gain` 0.994 / 0.987 | `check_v70.py` |
| 5 | 标定 | gain 落在 32000–35000，角度连续 | 上位机 / `angle_vs_sc.py` |
| 6 | 角度一致性 | offset ≈1.76°、RMS ≤0.71°、max ≤2.88°、误差 >5° 占 0.03% | `angle_vs_sc.py COMx 3` |
| 7 | **机械转速（权威）** | 转台 **457–459 rpm**，即 Z **7.62–7.65 Hz**（每转 1 个 Z） | `z_rate.py COMx` |
| 8 | Z 唯一性 | 每转严格 **1 个 Z**，脉宽 1.15–1.5 µs | `z_rate.py` |
| 9 | UVW | 六态 `{5174,4761,4423,4776,4763,4786}`、换相无跳变 | `check_v70.py` 60 s 段 |
| 10 | 以太网 | ping 4/4、UDP 抓窗 `missing=0`、28,672 点 @50 MSPS | `tools\board_eth_check.py` |
| 11 | 长跑 | 60 s 内 597,886 帧 / 9,964.8 fps，`lock` 全程 TRACK | `soak_v68.py COMx 60` |
| 12 | 屏（仅显示位流） | **4 页可切换**（P1/P2/P4/P6）、触摸命中、无花屏；**无 P7 标定页** | 人工逐页（2026-11-04 通过） |
| 13 | 标定入口 | KEY0 长按或串口写 `0x0502=0x0001` 触发；完成后角度连续 | 人工 + `check_v70.py` |
| 14 | Flash 冷启动 | 断电重上电后自动运行 | 人工（v90 已通过） |

> 第 12 项的四页**逐页人工确认**已于 **2026-11-04 通过**（P1/P2/P4/P6，含裸指触摸与 KEY1 翻页），
> 记录见 `docs/39_acceptance_criteria_v90.md` §5 与 `deliverables/board_day_checklist.md` §1；
> 冷启动点亮亦通过。报告与 README 中不要把"构建签核"写成"上板验收"——现在这两件事都有据可查。

### 7.3 参考读数（2026-11-04 实测，v90）

```
v90 生产（0x0019）：10.6 kfps / r 峰 0.845–0.850 FS / lock=0x0301 /
                    Z 7.62,7.65 Hz -> 457–459 rpm（每转 1 个 Z）/
                    UVW 六态 523 次/3 s / angle_vs_sc offset 1.76°、RMS 0.71°、max 2.88° /
                    60 s 597,886 帧、9,964.8 fps / ping 4/4 + UDP 抓窗 28,672 点
v90 显示：          已写 Flash，FLASH_OK，冷启动点亮进入 P1；四页逐页人工核对通过（2026-11-04）
历史：v74（0x0018）719–740 rpm、Z ≈12 Hz；v70（0x0015）719–731 rpm
```

> 转速**不要**用 `check_v70.py` 里的电周期换算值：低转速下它会在 621 rpm 附近
> 给出混叠伪值。v90 的权威判据是 `z_rate.py` 的 Z 频率 × 60（每转 1 个 Z）。

---

## 8. 常见问题

| 症状 | 原因 / 处理 |
|---|---|
| `No matching targets found` | 板子没上电 / USB 没插 / 下载器驱动没装；先关掉其它 Vivado，`netstat -ano \| findstr :3121` 看 hw_server 是否被占 |
| `[Labtools 27-2220] Unable to launch cs_server` | `%TEMP%` 不可写（沙箱/权限）；把 `TEMP/TMP` 指到仓库内可写目录 |
| `app.xml` 创建失败 | `HOME/USERPROFILE/APPDATA` 指向不可写位置；用 `tools/run_vivado.ps1` 或手动改环境变量 |
| 综合报 `ENC_DISP_TAP` 未定义 / 端口不存在 | 生产构建不要带 `ENC_DISP_TAP`；显示构建必须带 |
| 屏上 RPM 显示成 16 倍 / 496729.5 | 用了旧显示位流或缺 `ENC_V69_CPR2048`；用 v90 显示位流 |
| 屏上找不到标定页 | v90 已删除 P7；标定走 KEY0 长按或写 `0x0502=0x0001` |
| 停转时 Z 频繁跳 | v90 之前的位流没有 Z 布防；换 `enc_top_v90.bit`（出 Z 撤防、离开 1/8 圈重布防） |
| 仿真 `[XSIM 43-3409]` | `TEMP/TMP` 不可写；用 `run_sim*.ps1`，别手调 xelab |
| 上位机连不上 | 串口被占用（关掉串口助手）；波特率默认 115200；看 `host\ports.py` |
| 以太网 ping 不通 | 网段不对（板 `192.168.1.10`）、防火墙、网线直连需固定 IP |
| 位流下载后无反应 | 下的是显示位流却按生产接线，或反之；核对 `_synth_work_v90` 下的文件名 |

---

## 9. 复现清单（可打印）

```
[ ] git clone / 解压，目录名全 ASCII
[ ] python -m pip install -r host\requirements.txt
[ ] tools\check_offline.ps1 退出码 0
[ ] tools\run_sim.ps1 37/37 PASS
[ ] tools\run_sim_disp.ps1 20/20 PASS
[ ] python tools\make_v90_rtl.py 成功（v90 特征逐条校验）
[ ] impl_check_v90.tcl：WNS +0.199、0 失败、DRC 0 Error、位流 1,504,220 B
[ ] impl_check_disp_v90.tcl：WNS +0.221、0 失败、DRC 0 Error、位流 1,688,245 B
[ ] program_bit.tcl 烧写成功，IDCODE 0x0362D093
[ ] 串口遥测 10.6 kHz，BUILD=0x0019
[ ] z_rate.py：Z 7.62–7.65 Hz（457–459 rpm），每转 1 个 Z
[ ] UVW 六态、angle_vs_sc RMS ≤0.71°、60 s 长稳不掉锁
[ ] board_eth_check.py 退出码 0
[x] （显示）4 页逐页目视 + 触摸 + Flash 冷启动（2026-11-04 通过）
[ ] sha256sum -c deliverables\data\SHA256SUMS.txt
```

任何一项不过，先查 [`docs/DEV_STATUS.md`](DEV_STATUS.md) 里同一症状的历史记录，
再看 [`deliverables/evidence_index.md`](../deliverables/evidence_index.md) 对应的证据文件，
以及 [`docs/39_acceptance_criteria_v90.md`](39_acceptance_criteria_v90.md) 的判据表。
