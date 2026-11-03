# 从零复现指南

目标：让一支**没有见过本项目的队伍**，从一台干净的 Windows 机器开始，跑通
仿真、重建位流、烧到板上、并独立判断"做对了没有"。

预计耗时：只跑上位机与仿真 **1 小时**；完整重建 + 上板 **半天**。
所有命令都在仓库根目录执行。

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
# 编码器 36 台回归
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1

# 显示子系统 18 台回归
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim_disp.ps1
```

- 每个测试台在 `_sim_work/<tb>/` 独立编译，日志在 `sim/logs/`。
- 判定看 `TEST PASSED` / `TEST FAILED` 与退出码；`run_sim.ps1` 最后打印汇总表。
- 只跑一台：`-Only tb_abz_gen,tb_uvw_gen`；强制重编：`-Rebuild`。
- **预期**：编码器 36/36 PASS（v74 轮，2026-11-02）；显示 18 台历史全 PASS。
  若某台因本机 xsim 版本差异失败，先看 `sim/logs/<tb>.log` 的第一条 ERROR。

> xsim 需要可写的 `TEMP/TMP`。脚本已把临时目录钉在仓库内；若你手动调 `xelab`，
> 记得设置 `TEMP`、`TMP`，否则会报 `[XSIM 43-3409] Failed to compile generated C file`。

---

## 5. 重建位流（需要 Vivado）

### 5.1 生成 v74 变体 RTL（生产与显示构建都依赖它）

```powershell
python tools\make_v74_rtl.py
# 产出 _synth_work_v74/rtl_v74/（24 个顶层 + eth/8 个）
# 与仓库 rtl/ 的差异：RTL_BUILD_ID 0x0015 -> 0x0018（另含只读 Z 计数探针）
```

脚本会逐条自检 4 个替换点，任何一条不满足立即非零退出。

### 5.2 生产位流（编码器本体，无屏无网）

```powershell
vivado -mode batch -source tools\impl_check_v74.tcl
# 产出 _impl_v74/enc_top_v74.bit + 全部 .rpt
```

**预期签核值**（2026-11-02 基线，可作为对照）：

| 项 | 期望 |
|---|---|
| WNS / TNS | **+0.409 ns** / 0.000 |
| 失败端点 | **0** / 24,625 |
| LUT | **10,926 = 52.53%** |
| BRAM / DSP | 32/50、17 |
| DRC | **0 Error** |
| 位流大小 | 1,512,664 B |

### 5.3 显示位流（编码器 + 5 页 UI + 千兆网）

```powershell
vivado -mode batch -source tools\impl_check_disp_v74.tcl
# 产出 _impl_disp_v74/enc_top_disp_v74.bit
```

**预期**：WNS ≈ +0.175、LUT ≈ 86.96%、BRAM 48/50、DRC 0 Error（v85 口径）。
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
vivado -mode batch -source tools\program_bit.tcl -tclargs _impl_v74/enc_top_v74.bit
```

脚本会逐步打印 hw_server / target / device / program 的结果，失败点一目了然。
也可以直接用 Vivado Hardware Manager 的 GUI 流程。

### 6.2 QSPI Flash（掉电保留，适合演示）

按 [`docs/30_flash_program_guide.md`](../docs/30_flash_program_guide.md) 操作，
或 `tools/program_flash.tcl`（默认读 `_synth_work/enc_top.bit`，用环境变量
`FLASH_BIT` 指到你自己的位流）。**烧完必须断电再上电**，看到屏亮、串口有遥测，
才算 Flash 启动成功。

> `program_hw_devices` 会复位整个 FPGA：倍频/分频/环路增益/标定结果全部回默认值。
> 烧完先让上位机重写一遍配置，再做功能测试。

---

## 7. 上板验收

### 7.1 接线与上电

1. 断电接线：ADC 模块、屏排线、网线、USB 串口、JTAG；
2. 12 V 上电，确认板载电源灯；
3. 设备管理器确认串口（如 `COM7`）与下载器；
4. 烧 v74 生产位流（或 v85 显示位流）。

### 7.2 判据（逐项打勾）

| # | 检查 | 通过标准 | 命令 / 位置 |
|---|---|---|---|
| 1 | 器件识别 | IDCODE `0x0362D093`，PART `xc7a35t` | Vivado / `program_bit.tcl` 输出 |
| 2 | 构建号 | `RTL_BUILD_ID = 0x0018` | 上位机"设备自检"或读 `0x0000` |
| 3 | 串口遥测 | 帧率 ≈ 8.6 kHz，无 CRC 错 | `python -X utf8 host\app.py --port COMx` |
| 4 | 标定 | gain 落在 32000–35000，角度连续 | 上位机 P1 / 标定页 |
| 5 | 角度噪声 | RMS ≤ 0.72°（静止或匀速） | 上位机"质量"面板 |
| 6 | 转速 | 转台 719–740 rpm 时显示一致 | 屏 P1 / 上位机 |
| 7 | Z 索引 | 720 rpm 时 **12.00 Hz**（±0.1） | `0x054A..0x054D` 计数器 |
| 8 | UVW | 六态均衡、换相无跳变 | 屏 P2 / 示波器 |
| 9 | 以太网 | ping 通、UDP 抓窗 missing=0 | `python -X utf8 tools\board_eth_check.py --port COMx` |
| 10 | 长跑 | 60 s 内 `|err|>5°` 帧数为 0 | `tools\stream_longrun.py` |
| 11 | 屏（仅显示位流） | 5 页可切换、触摸命中、无花屏 | 人工逐页 |
| 12 | Flash 冷启动 | 断电重上电后自动运行 | 人工 |

> 第 11 项是 v85 **尚未完成**的验收；v74 生产位流不涉及屏。报告与 README 中
> 不要把"构建签核"写成"上板验收"。

### 7.3 参考读数（2026-11-02/03 实测）

```
v71 生产（0x0016）：ADC 8657 Hz / gain 33567,33316 / 角度 RMS 0.72° /
                    60 s 597,746 帧、|err|>5° 0 帧 / ping+capture PASS
v73 生产（0x0017）：Z 12.00 Hz -> 720.0 rpm（另一轮 11.91 Hz -> 714.7 rpm）
v73 显示：          Z 11.91 Hz、UVW 六态、lock=TRACK、J5-7 脉冲 ≈1.15 µs / 2.5 V
v74 生产（0x0018）：转台 719–740 rpm、Z ≈12 Hz、UVW 六态、以太网 PASS
v85 显示：          PROGRAMMED_OK（2026-11-03 16:50），屏未逐页目视
```

---

## 8. 常见问题

| 症状 | 原因 / 处理 |
|---|---|
| `No matching targets found` | 板子没上电 / USB 没插 / 下载器驱动没装；先关掉其它 Vivado，`netstat -ano \| findstr :3121` 看 hw_server 是否被占 |
| `[Labtools 27-2220] Unable to launch cs_server` | `%TEMP%` 不可写（沙箱/权限）；把 `TEMP/TMP` 指到仓库内可写目录 |
| `app.xml` 创建失败 | `HOME/USERPROFILE/APPDATA` 指向不可写位置；用 `tools/run_vivado.ps1` 或手动改环境变量 |
| 综合报 `ENC_DISP_TAP` 未定义 / 端口不存在 | 生产构建不要带 `ENC_DISP_TAP`；显示构建必须带 |
| 屏上 RPM 显示成 16 倍 / 496729.5 | 用了旧显示位流或缺 `ENC_V69_CPR2048`；用 v85 |
| 仿真 `[XSIM 43-3409]` | `TEMP/TMP` 不可写；用 `run_sim*.ps1`，别手调 xelab |
| 上位机连不上 | 串口被占用（关掉串口助手）；波特率默认 115200；看 `host\ports.py` |
| 以太网 ping 不通 | 网段不对（板 `192.168.1.10`）、防火墙、网线直连需固定 IP |
| 位流下载后无反应 | 下的是显示位流却按生产接线，或反之；核对 `_impl_*` 目录与文件名 |

---

## 9. 复现清单（可打印）

```
[ ] git clone / 解压，目录名全 ASCII
[ ] python -m pip install -r host\requirements.txt
[ ] tools\check_offline.ps1 退出码 0
[ ] tools\run_sim.ps1 36/36 PASS
[ ] tools\run_sim_disp.ps1 全 PASS
[ ] python tools\make_v74_rtl.py 成功（4 条自检）
[ ] impl_check_v74.tcl：WNS>0、0 失败、DRC 0 Error
[ ] impl_check_disp_v74.tcl：同上
[ ] program_bit.tcl 烧写成功，IDCODE 0x0362D093
[ ] 串口遥测 8.6 kHz，BUILD=0x0018
[ ] 转台 720 rpm，Z=12.00 Hz，UVW 六态
[ ] board_eth_check.py 退出码 0
[ ] （显示）5 页逐页目视 + 触摸
[ ] sha256sum -c deliverables\data\SHA256SUMS.txt
```

任何一项不过，先查 [`docs/DEV_STATUS.md`](DEV_STATUS.md) 里同一症状的历史记录，
再看 [`deliverables/evidence_index.md`](../deliverables/evidence_index.md) 对应的证据文件。
