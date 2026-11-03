# v68 生产位流上板测试报告（2026-11-01 21:30–22:05）

> 对象：`deliverables/data/v68/enc_top_v68.bit`（生产位流，SHA256 `921FA2DC…4B1196`，1,511,380 B）
> 板卡：正点原子达芬奇-lite，XC7A35TFGG484-2；JTAG = Digilent HS2 `210512180081`
> 信号：转台真实输出 8 Vpp 正交 sin/cos，实测 **25.266 kHz**、有轻微波动
> 位置：SRAM 下载（未动 Flash），主机 = 本机 `192.168.1.100/24`，板卡 `192.168.1.10`

---

## 1. 结论一览

| # | 项目 | 结果 | 关键数据 |
|---|------|------|----------|
| 1 | JTAG / 位流下载 | ✅ PASS | `PROGRAMMED_OK`，`End of startup status: HIGH` |
| 2 | 串口链路（CH340 / 2 Mbaud / 18 B 帧） | ✅ PASS | 10,000 帧/s，180,224 B/s，坏帧 101/29,885 = 0.34% |
| 3 | 器件身份 | ✅ PASS | `DEVICE_ID=0x000C` `REV=0x0010` `RTL_BUILD=0x0010` |
| 4 | 配置寄存器 | ✅ PASS | `0x0100=0x2004`(pairs=4) `0x0101=0x0020`(inter=32) `0x0106=0x0A00` `0x0109=0x00C0` |
| 5 | 锁定状态 | ✅ PASS | `0x0130=0x0301`（TRACK）、`0x0131=0x0003`（曾锁定） |
| 6 | 幅值 / 输入电平 | ✅ PASS | r 均值 **0.786 FS**、峰值 0.845 FS（8 Vpp ÷ 10 Vpp 满量程 ≈ 0.8 FS，未削顶） |
| 7 | ADC 原始抓包（50 MSPS × 28,672 点） | ✅ PASS（有缺块） | f0 = 25.266 kHz、A = 0.762/0.767 FS、正交 −0.67°、幅值失配 0.75%、THD 5.1%/4.8% |
| 8 | 角度 vs atan2(s,c) 一致性 | ✅ PASS（有条件） | 常数偏移 2.94°（≈323 ns 流水线延迟）；残差 RMS 0.71°、MAD 0.48°；分箱系统误差 ≤0.13° |
| 9 | 一键标定（写 `0x0502`） | ✅ PASS | gain_s=32537、gain_c=32327（0.993 / 0.987）→ 幅度收到 0.80 FS，方向正确 |
| 10 | 以太网 ping / ICMP | ✅ PASS | 5/5 通，<1 ms，MAC `00:00:02:00:00:01` |
| 11 | 以太网上抓包（UDP 28672 点整窗） | ✅ PASS（冷启动一次缺块） | 3/3 次 `missing=[]`，0.26 s / 窗 |
| 12 | ABZ 等效采样 | ✅ PASS | A/B 高电平各 ~50%，每 100 µs 采样都在翻转 |
| 13 | **UVW 换相** | ❌ **FAIL** | 399,465 帧里 **399,391 帧（99.98%）停在 110**，40 s 只跳变 28 次 |
| 14 | 40 s 长跑 | ✅ PASS | 9,986.6 帧/s 不丢、r 均值漂移 < 0.03%、lock 一直 TRACK、无新告警 |
| 15 | 显示屏 / 触摸（显示位流） | ⚠️ 仅目视 | 屏亮、UI 有角度/RPM 在动（用户口述），本轮未做自动化 |
| 16 | Flash 固化 / 断电自启动 | ⛔ 未测 | 需断电重上电；且 10-30 那次烧写失败过，状态未知 |

---

## 2. 关键缺陷

### D1（致命）位流按 64 电周期/圈综合，真实转台是 2048 PPR — 差 32 倍

v68 构建用 `POLE_BITS=6`（`tools/make_v68_rtl.py` 把 `rtl/enc_top.v:58` 的 `11` 改成 `6`），
而转台 **PPR = 2048**（`POLE_BITS=11`）。实测电气频率 25.266 kHz：

| 量 | 按 64 周期/圈（当前位流） | 按 2048 PPR（真实） | 差 |
|---|---|---|---|
| 机械转速 | 23,687 rpm | **740.2 rpm** | 32× |
| 16 位机械角 `mech_angle` 回绕 | 395 Hz | 12.33 Hz | 32× |
| Z 脉冲 | 395 Hz（32 个/圈） | 12.33 Hz（1 个/圈） | 32× |
| UVW 基波（pairs=4） | 1,580 Hz | 49.4 Hz | 32× |
| ABZ 边沿/圈 | `inter=32` → 65,536 | 65,536 | ✅ 恰好正确 |

也就是说：**ABZ 增量输出是对的**（边沿数只取决于 inter 和真实 PPR），但机械角、RPM、Z、UVW 相位全部错 32 倍。
`rtl/enc_top.v:58` 源码本身就是 `POLE_BITS = 11`，是 v68 的构建脚本把它改小的，`tools/final_verify.ps1:75-77` 也断言源码必须是 11。

### D2 UVW 不换相（需定位）

40 s / 399,465 帧统计：`u=99.98% / v=100.0% / w=0.01%`，UVW 状态码 99.98% 是 `110`。
改 `uvwdir=1`（`0x0109` 写 0x00E0）后变成 `001`，改 `pairs=1`（`0x0100` 写 0x2001）后仍停在 `110`
⇒ **不是配置问题，是扇区状态机不推进**。`uvw_gen.v` 的 `uvw_freq_warn` 门限是 8.33 MHz，与 25 kHz 无关，
所以不是"频率超限保护"。`0x0104 uvw_hyst=0`（用编译期默认 5.625°）。
建议：用 ~1 kHz 的低频差分/单端正弦（AFG）单独喂，看 UVW 是否按 6 状态循环；若低频正常、高频卡死，
就是高速下 `in_valid`/边界判据的问题（`rtl/uvw_gen.v:539-589` 冷启动基准 + 迟滞比较）。

### D3 抓包 dump 冷启动丢块

- UART 回读：448 块缺 30 块（6.7%），CSV 里表现为整 64 点全零块。
- UDP 回读：第一次 82 块缺 44 块（连续 10..53）；**紧接着 3 次全部 `missing=[]`**。
⇒ 冷启动/首个窗口现象（主机侧 ARP 学习 / 缓冲未就绪），不是稳定缺陷；但**首次抓包不能直接用**，建议固件在 arm 后先丢弃首窗，或上位机自动重抓一次。

### D4 ARP 源 MAC 与文档不一致

实际 ARP 应答 MAC = `00:00:02:00:00:01`，`tools/board_eth_check.py:BOARD_MAC` 与 `host/regs.py` 注释都写 `02:00:00:00:00:01`。
`rtl/eth/eth_top.v:365` 是 `wire [47:0] my_mac = {16'h0200, s_mac2};`，配合 `0x0702=0x0200 / 0x0700=0x0001` 应得
`02:00:02:00:00:01`，实测却是 `00:00:02:00:00:01`。功能上不影响 ping/UDP（仍是合法单播 MAC），
但 `board_eth_check.py` 的 ARP 断言会一直 FAIL，建议核对 RTL 与文档口径。

### D5 `inclim` / `limiter_active` 常亮 + 已知假 OTR

`0x0404=0x0901`（低字节 `0x01`=oflow/OTR，高字节 `0x09`=锁存位 0 和 3）、`0x0405` 锁存含 bit3 (`inclim`)、
`0x053A=0x0018`（bit3 OTR + bit4 calib_done）。OTR 是 `constr/enc_top.xdc:120-132` 记录的**已知假信号**
（OTR 脚静低 + 60 mV 毛刺，已加 PULLDOWN）。`inclim` 与 `rtl/enc_top.v:1055` 的
`(limiter_active | uvw_freq_warn)` 一致，即 ABZ 限频器认为边沿太快 —— 在 2048 PPR × 25 kHz 真实工况下
A 相边沿率约 808 kedge/s，值得按真实 PPR 重算 `ablimit`（`0x0106`）后再看。

### D6 串口坏帧 0.34%，几乎全是多比特（疑似丢/插字节）

29,885 帧里 101 帧 XOR 失败，其中 96 帧是多比特错位（1 位错仅 5 帧）⇒ 更像"字节流被插/丢了一两个字节"，
不是随机位翻转。10 kHz × 18 B 在 2 Mbaud 下带宽占用 90%，建议正式演示时把遥测降到 5 kHz 或升到 3 Mbaud。

---

## 3. 测量细节

### 3.1 ADC 输入链（50 MSPS 原始抓包，`tools/cap_dump.py`）

```
28672 点 @ 50.000 MSPS（0.573 ms）｜触发 #0｜抽取 ×1｜缺块 30
CH1 峰峰值 50544，CH2 峰峰值 51232
```
剔除 30 个全零块后按 25,000–25,600 Hz 扫频做最小二乘：

- f0 = **25,266 Hz**（相位在 0.573 ms 内从 93.55° 漂到 85.90°，即真实频率略高且缓慢变化）
- CH1 A = 24,960（0.7617 FS）、DC = +217；CH2 A = 25,147（0.7674 FS）、DC = +475
- **幅值失配 0.747%**、**正交误差 −0.67°**、THD 5.1% / 4.8%（h2 4.26% / 1.55%）、拟合残差 2.8%

⇒ 8 Vpp 输入经 5:1 衰减后正好 ~0.76 FS，**没有削顶**，模拟前端链路正常。

### 3.2 角度一致性（每帧 angle 与同帧 s/c）

- 常数偏移 **2.94°**（25.266 kHz 下 = 323 ns 流水线延迟，s/c 快照与角度不同拍）
- 去掉常数后：RMS **0.71–0.85°**、MAD **0.48°**、90% 分位 1.16°
- 按 16 个角度分箱的系统误差 −0.127°…+0.132°，谐波 h1 0.052 / h2 0.032 / h3 0.015 / **h4 0.095°**
⇒ 无明显插值非线性（4 次谐波 0.1° 量级，与 1024 点 LUT 的粒度相符）；杂散主要来自快照时差与信号抖动。

### 3.3 一键标定

写 `0x0502=0x0001` 后 0.3 s：`gain_s 32768→32537`、`gain_c 32768→32327`、`shift=0`、`0x053A` bit4 calib_done。
按 `rtl/calib_ctrl.v:67 REF_Q15 = 26214`（0.80 FS）反推原始幅度 0.806 FS，方向与幅度都正确；
标定后角度分箱谐波 h1/h2/h3 降到 0.001/0.007/0.007°，h4 仍 0.084°。
**注意：标定结果不跨配置保持**（重新下载位流后回到 32768/1.0），演示流程里必须每次上电后标定一次。

### 3.4 以太网

- `0x0704/0x0706` = 192.168.1.10，`0x0708/0x070A` = 192.168.1.100，`0x070C` 默认 5000（本机 5000 被 `lkcitdl` 占用，测试时改成 5010）。
- 网卡「以太网」ifIndex 12（Realtek 1 Gbps）设 `192.168.1.100/24` + 主机路由 `192.168.1.10/32 if 12 metric 1` 后：ping 5/5、UDP 抓窗 3/3 无缺块。
- 未设 IP 前 `0x0710` 全 0、`0x0716 rx_pkt=81`、`tx_pkt=0`；设好后 ARP/ICMP 正常。

### 3.5 长跑（40 s，`_boardtest/soak_v68.py`）

```
frames=399465 (v1/无io帧=4)  elapsed=40.0s  fps=9986.6
r: min=24120 mean=25763 max=31095 (max=0.9489 FS)
lock=0x0301  stat_flags=0x0018
UVW state counts (u,v,w): {2:46, 3:399391, 4:6, 5:1, 6:17}
level high %: a 49.94 b 50.03 z 0.06 u 99.98 v 100.0 w 0.01
flips: a 199646 b 199598 z 468 u 28 v 6 w 14
angle vs atan2: mean |err|=2.978° (n=79892), |err|>5° 只有 157 帧
```

---

## 4. 建议的下一步（按优先级）

1. **重综合 v69：`POLE_BITS=11`（去掉 `make_v68_rtl.py` 的 64 周期改写）+ BUILD_ID 0x0011**，
   生产/显示两个位流都出，然后重跑本报告全部项目。否则 RPM/Z/UVW 在真实转台上都是错的。
2. **定位 UVW 不换相**：先用 1 kHz 低频源单独验证；若低频正常则查 `uvw_gen` 高速下的边界判据。
3. **Flash 固化 + 断电重上电**：先确认 10-30 那次失败后 Flash 里到底是什么（可能需要重新烧 mcs）。
4. 串口降速或提波特率，降低 0.34% 坏帧；抓包前自动丢弃首个窗口。

---

## 5. 复现命令

```powershell
# 下载生产位流
$env:BITFILE='C:/Users/zhaoy/Desktop/FPGA/deliverables/data/v68/enc_top_v68.bit'; $env:TAG='PROD'
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 -Tcl _boardtest\prog_retry.tcl -LogFile prog_prod.log -Tail 8

# 身份 + 寄存器
E:\Anaconda\python.exe _boardtest\check_v68.py COM4
# 50 MSPS 抓包
E:\Anaconda\python.exe tools\cap_dump.py --port COM4 --dec 0 --csv _boardtest\cap_raw_prod.csv
# 角度 vs atan2
E:\Anaconda\python.exe _boardtest\angle_vs_sc.py COM4 3
# 长跑
E:\Anaconda\python.exe _boardtest\soak_v68.py COM4 60
# 标定
E:\Anaconda\python.exe _boardtest\calib_v68.py COM4
# 以太网
E:\Anaconda\python.exe tools\board_eth_check.py --port COM4 --udp-port 5010
```

> 排障备忘：Vivado 被强杀/target 被占后，报 `Labtoolstcl 44-494 ... may be locked by another hw_server`
> 时**只有拔插 JTAG USB 线能救**；关 Vivado、重启 hw_server、杀 cs_server 都无效。

---

## 6. 后续（v69 / v70，2026-11-01 22:00 之后）

本节是 v68 测试完成后同一晚的追补，**详细记录见 [`docs/33_v70_release_report.md`](33_v70_release_report.md)**。

- **v69（`POLE_BITS=11`、BUILD 0x0011）**：位流 1,525,256 B，WNS +0.193、LUT 52.48%、BRAM 32/50。
  上板后 D1 的"32 倍"消失，但**位置计数仍恒 0**：
  `电周期速率 = +0.0 cycles/s`、`UVW {3: 28650}`、`Z 0.37 Hz`。
- **根因不是 PPR**：换回 v68 位流同样 `cycle_cnt distinct=1`。bisect 位流证明计数通路正常，
  再用 ModelSim 复现，定位到

  `pole_counter.v` 把 0..65535 的无符号相位按补码符号扩展再相减 —— 跨 32768 时差值算成 −65403，
  累加器每半圈被扣 65536 ⇒ `cycle_cnt` 永远 0；连带 `mech_angle` 恒 0、`z_window` 恒 1、UVW 卡死。
- **第二个缺陷**：`uvw_gen.v` 的 `off_bwd` 缺"角度从 0 反向绕回 65535"这条环绕边界，
  反向转时 0→5 的跨界被吞 ⇒ 只有 3 个扇区（前向仿真 49 次换向/6 态均匀，反向仅 7 次/82% 停 110）。
- **v70（BUILD 0x0015）**：两处都修好并上板验证 —— `Z 12.00 Hz`、`cnt −2047..0 distinct=2048`、
  `719–731 rpm`、UVW 六态均匀（293 次换向/秒）、60 s 长跑 598,115 帧无漂移。
  生产位流 1,517,496 B（WNS +0.091），显示位流 1,708,301 B（WNS +0.027）——
  **显示位流尚未上板目视**（下载时 JTAG 进入 44-494 假死，板卡随后被断开）。

对 §2 缺陷表的更新：**D1 ✅ 已修（v69 + v70）**、**D2 ✅ 已修（v70）**；
D3/D4/D5/D6 仍是已知现象，D7（Flash）仍未做；新增 D8（`cycle_cnt` 恒 0）、D9（显示版 CPR 16×，已修待目视）。

