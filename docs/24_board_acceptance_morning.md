# 明日上板验收清单（以太网 + 屏幕 + 上位机）

> 目标：**一次插线、一条命令、一张表**把「屏 + 千兆以太网」这条线验完。
> 此前已完成：设计/仿真/实现（v61 位流）、串口抓包、串口 dump、ping/ARP、UDP 抓包、
> 连续流 30 s 长稳；**明早补的是**：第十八次交付包（`host_app.exe` 8,132,580 B @2026-10-23
> 00:03:23）在真机上的 GUI 全流程、连续流 10 分钟长稳、断线重连/热插拔、以及屏幕与以太网
> 同板并存的观感确认。

---

## 0. 接线与准备（5 分钟）

| 项 | 要求 |
|---|---|
| 板子供电 | 12 V，上电后屏幕先亮、约 10 ms 后 `phy_rst_n` 释放 |
| USB | 板载 CH340（COMx）+ Digilent JTAG（FTDI）都要插上 |
| 网线 | 板子 RJ45 ↔ PC 网口（直连亦可，RJ45 自适应） |
| PC 网口 | 固定 **192.168.1.100 / 24**，无网关；关掉 WLAN 或确保它不在 192.168.1.0/24 抢路由 |
| 防火墙 | 允许 `host_app.exe`（或 `E:\anaconda\python.exe`）入站 UDP |

确认命令：

```powershell
Get-NetAdapter | Where-Object Name -like "*以太网*" | Format-Table Name,Status,LinkSpeed
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -like "192.168.1.*"
[System.IO.Ports.SerialPort]::GetPortNames()
```

期望：`Status=Up`、`LinkSpeed=1 Gbps`、`192.168.1.100`、至少一个 `COMx`。

---

## 1. 烧写（1 分钟）

```powershell
# 位流：_impl_v61/enc_top_disp.bit（1,694,149 B @2026-10-22 21:08:15）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 -Tcl _prog_v61.tcl -LogFile _prog_v61.log -Tail 20
```

判成功：日志里有 `End of startup status: HIGH`，且没有 `No hardware targets`。
（`_prog_v61.tcl` 指向 v61；**别烧 v60**——v60 的 `stream_tx` 端口字节序是反的。）

---

## 2. 启动上位机（1 分钟）

```powershell
.\host\dist_onedir\host_app\host_app.exe
# 或者源码跑：python host\app.py
```

1. 顶栏选 `COMx` → **连接**；
2. 顶栏 **设备自检** → 期望一行：
   `网口 192.168.1.10 ｜ ARP ✓ ｜ ICMP ✓ ｜ 主机 MAC ✓ ｜ UDP 端口 <n> ｜ ping 通`
   - 若 ARP ✗：先 `arp -d 192.168.1.10` 再点一次（板子只认最后一次 ARP 学到的主机 MAC）；
   - 若显示 `UDP 端口 5000`：说明 5000 被 `lkcitdl`（Vivado 许可证服务，PID 随进程）占用，
     软件会自动 +1 选空闲端口，属正常。

---

## 3. 串口通道（B1，2 分钟）

抓包页 → 通道选「串口」→ 点数 28672、抽取 ×2、触发「立即」→ **抓一次**。

- 期望：`窗口 1.147 ms ｜ 25.000 MSPS（40 ns/点）｜ 回读约 0.66 s`；波形出图，
  角标显示「包络抽稀 ｜ 平滑 关 ｜ 缺块 0」；
- 记录页开一次「开始记录」→ 10 秒后停 → 行数在涨、CSV 可打开；
- 导出 CSV / NPY / PNG 各一次（PNG 用包络 + µs 轴 + 中文标题）。

---

## 4. 网口通道（B2，3 分钟）

通道选「**UDP**」→ **抓一次**。

- 期望：`回读约 2 ms`、缺块 0、波形与串口那枪形态一致（比较峰峰值与周期）；
- 日志应出现 `抓包完成`，若首次 `缺 44/82 块` 属已知现象（重烧后第一次），
  软件会自动重试一次并变干净；连续两次不干净再查。

命令行交叉验证（独立于 GUI）：

```powershell
python tools\cap_dump.py --udp --udp-port <端口> --len 28672
```

---

## 5. 连续流（10 分钟长稳，重点）

抓包页 → 通道「连续流」→ **开始连续流**（按钮变「停止连续流」）。

先跑 30 秒看观感，再跑 **10 分钟**：

```powershell
python tools\stream_longrun.py --port COMx --dur 600 --host-ip 192.168.1.100 --dev-ip 192.168.1.10
```

判据（脚本会打印并判定）：

| 指标 | 门槛 |
|---|---|
| 端到端包数比 | ≥ 95% |
| 板端 `drop`（0x074A/4C） | 不随时间单调增长 |
| `lag`（0x074E） | 稳定在个位数 |
| GUI 连续跑 10 分钟 | 不崩、不卡死、按钮能停、内存 RSS 涨幅 < 30 MB |

同时观察：波形随信号变化（旋转/拨动编码器），不是冻住的滚动窗。

---

## 6. GUI 浸泡与异常路径（5 分钟）

```powershell
# 真板：8 次抓包 + 3 轮流开关 + 2 次断连重连，翻页若干，采 RSS
python tools\gui_soak.py --port COMx --captures 8 --streams 3 --reconnects 2
```

另做三个手工动作：

1. 抓包进行中再点「网络自检」→ 应提示忙、不发起第二枪；
2. 连续流开着直接点窗口 X → 应先停流再退出（板端 `0x0740` 回 0，`Get-NetUDPEndpoint` 无残留）；
3. 抓包途中拔网线 → 应在 ~5 s 内报「收包超时/一个包都没收到」，按钮复位，可重试。

---

## 7. 屏幕与以太网并存（1 分钟）

- 屏幕 v59/v60 的页面正常翻页、触摸可用；
- 以太网跑流时屏幕不花屏、不卡顿（两者共用 50 MHz 域，BRAM 92%）；
- 断电重启一次，确认上电后 `ping` 能通（PHY 复位时序 + `mmcm_locked` 门控）。

---

## 8. 结果记录表（抄进 docs/DEV_STATUS.md）

| 项 | 命令/动作 | 结果 | 备注 |
|---|---|---|---|
| 烧写 | `_prog_v61.tcl` | | |
| 自检 | 设备自检 | | |
| 串口抓包 | 抓一次 | | |
| 串口 dump | `tools\board_dump_test.py --port COMx` | | 448 块 / 0.66 s |
| UDP 抓包 | 抓一次 / `cap_dump.py` | | 82 包 / 缺块 0 |
| 连续流 30 s | GUI | | 包数 / 丢点 |
| 连续流 10 min | `stream_longrun.py --dur 600` | | 比例 / drop / lag / RSS |
| GUI 浸泡 | `gui_soak.py` | | RSS 增长 |
| 断网/拔线 | 手工 | | 提示 / 复位 |
| 屏+网并存 | 目视 | | |

任何一项 FAIL，把 `host_app_run.log`、对应截图/CSV、以及 `_impl_v61` 的
`impl_timing.rpt` 一起留下——报告里按「现象 → 复现步骤 → 期望/实际」三段写。

---

## 9. 已知边界（不是缺陷，别当 bug 记）

- 连续流是**滚动最近 1024 点**，不是整窗；导出 PNG 只画当前窗；
- 连续流抽取 ≥ ×2；×1（50 MSPS）超千兆余量，软件会自动提到 ×4；
- 每次重烧后第一枪 UDP 可能缺 44/82 块（板子还在学 ARP），重试即净；
- PC 的 UDP 5000 常被 Vivado 许可证服务占用，软件自动换端口，属设计行为；
- 抓包导出永远是**原始样点**，界面平滑只影响绘制。

---

## 10. 2026-10-23 上午实测（v62）

> 位流换成 **v62**（`_impl_v62/enc_top_disp.bit`，1,694,505 B @10:18:42，WNS +0.471 /
> WHS +0.042）——v61 是误从 EI58 变体恢复的 `enc_top.v` 打的，`POLE_BITS=11`、构建号
> 0x0100；v62 改回 `POLE_BITS=6` / `RTL_BUILD_ID=0x000D` / 去掉 cfg 打拍后重建。

| 项 | 实测 | 判据 | 结论 |
|---|---|---|---|
| ping | 4/4，0% 丢包，TTL 64 | 全通 | PASS |
| 设备自检 | id 12 / build 13 / depth 28672 | build=13 | PASS |
| 串口抓包 | 28672 点 / 25 MSPS / 1.147 ms | n=28672 | PASS |
| 串口 dump | 448 块 / 0.65 s | 448 块 | PASS |
| UDP 抓包 | 首枪缺 45 → 第二枪缺 0 / 0.06 s | 缺块 0 | PASS |
| 连续流 30 s | 1,876,314 包 / 端到端 99.91% / 7.67 MSPS | ≥95% | PASS |
| 连续流 10 min | 37,501,126 包 / 端到端 99.89% / drop +24,926 / underflow 净回落 | ≥95%、drop 不单调涨 | PASS |
| GUI 浸泡 | 6 抓包 / 2 流 / 2 重连 / 28 翻页，RSS +16.0 MB 后持平 | 不崩、<+30 MB | PASS |
| 连续流 **30 min**（dec=3，6.25 MSPS） | 板端 56,251,240 包 / 端到端 **99.74%** / drop +23,129 样点（0.0002%） / lag=−1 | ≥95%、drop 不单调涨 | **PASS** |

长稳建议用 `python tools\stream_longrun.py --port 5003 --dec 3`（6.25 MSPS ≈344 Mbps）。
满速 12.5 MSPS ≈688 Mbps 会把 1 GbE 吃满，期间 ping/自检/网页都会受影响（实测中断过一次）。

**ping 只在停流时做**：停流 20/20；dec=3 时 17/20；满速约 1/3。验收顺序按本页 §2→§5，
所有 ping/自检都放在连续流测试之前或停流之后。

未做：拔网线/断电重启（需人工）、屏幕目视（需看板）。
