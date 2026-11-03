# v70 发布说明：位置计数与 UVW 修复（2026-11-01）

> 对象：`deliverables/data/v70/enc_top_v70.bit`（生产，`RTL_BUILD_ID = 0x0015`）
> 　　　`deliverables/data/v70/enc_top_disp_v70.bit`（显示版，`ENC_DISP_TAP` + `ENC_V69_CPR2048`）
> 板卡：正点原子达芬奇-lite，XC7A35TFGG484-2；JTAG = Digilent HS2 `210512180081`
> 信号：转台真实输出 8 Vpp 正交 sin/cos，实测 **25.27 kHz**（每电周期约 495 个 12.5 MHz 样点）

---

## 0. 一句话结论

v68/v69 位流上板后暴露的两个"致命但现象完全不同"的缺陷，**根因都在 RTL，都在 v70 修好并在板上验证**：

| 缺陷 | 现象 | 根因（一句话） | v70 状态 |
|---|---|---|---|
| **cycle_cnt 恒 0** | 屏上角度在动、ABZ 正常，但 RPM 恒 0、Z 不出现、UVW 不换相 | `pole_counter` 把"绝对相位"当有符号数做符号扩展再相减，跨 32768 时差值算成 −65403 | ✅ 已修，板上 12.00 Hz Z / 2048 电周期/圈 |
| **UVW 反向只有 3 个扇区** | 反向转时 UVW 恒 `110`（v=0），只有 3 态轮转 | `off_bwd` 缺"角度从 0 反向绕回 65535"这条唯一环绕边界，0→5 的跨界被吞 | ✅ 已修，板上正反向都 6 态均匀 |

两个缺陷叠加时看起来像"PPR 配错 32 倍"（v68 的 `POLE_BITS=6`），实际 `POLE_BITS=11` 的 v69 一样死 —— 这也是本轮最重要的方法论教训：**先证伪"显然是配置问题"，再去改配置**。

---

## 1. 缺陷 1：`cycle_cnt` 恒 0

### 1.1 现象（v69，BUILD 0x0011）

`_boardtest/check_v69.py COM4 3`：

```
RTL_BUILD=0x0011  INTER0 reg=0x0020  inter=32  UVW_CFG=0x2004
frames=28651 fps=10611
电周期速率 = +0.0 cycles/s  机械转速 = 0.0 rpm
r: min=21988 mean=27446 max=28142 (0.859 FS)
Z 事件率 = 0.37 Hz
UVW 状态分布 = {0:1, 3:28650}
lock=0x0301  stat_flags=0x0000
FAIL
```

10 s / 101,718 帧里 `pos_full[31:16]`（= `cycle_cnt`）恒 0，`pos_full[15:0]`（=`ang_s0`）只在 57,745..58,645 缓漂。
ABZ 输出与角度本身都正常 ⇒ 问题只在"电周期计数"这一条支路。

### 1.2 定位路径（四步，每步都留下可复现证据）

1. **A/B 换回 v68 位流**（`deliverables/data/v68/enc_top_v68.bit`）：
   `cycle_cnt distinct 1 (min 0 max 0)`、`z_window duty 100.000%` ⇒ v68 同样死，排除 `POLE_BITS 6→11` 的责任。
2. **bisect 位流（BUILD 0x0013）**：把 `wrap_p_raw` 临时改成 `pair_valid`（即"每个有效样点都算一次跨界"），
   上板 `_boardtest/hi_probe.py` 读到 `hi distinct=2049  hi min=0 max=2048` ⇒ **计数通路（`vld_d1`/`pair_valid`/`cnt_inc`/Z 清零）完全正常**，
   问题被压到 `acc_pos` / `phase_acc` 这一层。
3. **ModelSim 复现**（`_boardtest/tb_acc.v` 系列，Vivado xsim 在本机起不来，见 §6）：
   0.73°/样、3000 样、理论 6 次跨界，仿真里 `cycle_cnt=0`、`wraps=+0/-0` ⇒ **纯 RTL 逻辑错，不是综合/时序**。
4. **打印唯一异常点**（`_boardtest/tb_dbg6.v`，只在 `step_s !== 133` 时打印）：

   ```
   BADSTEP i=246 s0=32851 s1=32718 step=-65403 acc=32585
   END cnt=0 acc=-12469 nbad=1
   ```

### 1.3 根因

`rtl/pole_counter.v` 旧代码：

```verilog
wire signed [AW+1:0] step_s = {{2{ang_s0[AW-1]}}, ang_s0} - {{2{ang_s1[AW-1]}}, ang_s1};
```

`ang_s0/ang_s1` 是 **0..65535 的无符号相位**，这里却各自按二进制补码做符号扩展再相减：
角度一越过 32768，符号位变成 1，差值就被算成 `-65403` 而不是 `+133`。
累加器每半圈被扣掉 65536，净累加恒 ≈0 ⇒ `cycle_cnt` 永远为 0。

原来的跨零判据（`STEP_MIN`/`spans_zero`/`step_big_*`，要求相邻样点跳变 ≥270°）是为**欠采样/混叠**输入设计的；
25.27 kHz 在 12.5 MHz 有效采样下每样点只有 **0.73°**，本来就永不触发 —— 两个错误互相掩盖，
v62 那种"手转 + 低电频率"的用法从没暴露过。

### 1.4 修法

```verilog
// 先做模 2^AW 的无符号差，再对"差值"做符号扩展
wire [AW-1:0] diff_u = ang_s0 - ang_s1;
wire signed [AW+1:0] step_s = {{2{diff_u[AW-1]}}, diff_u};
```

配合增量展开累加器（`phase_acc` / `acc_pos` / `acc_neg` / `acc_wrap`），跨 ±2π 时给出 `wrap_p/n` 一次脉冲。
**验证**（`_boardtest/tb_acc2.v`）：3000 样 ×133 LSB ⇒ `cycle_cnt=6`（理论 6.09）；再 3000 样 ⇒ `cycle_cnt=12`。

### 1.5 板上验证（v70，BUILD 0x0015）

见 §4：`Z 12.00 Hz`、`cycle_cnt` 跨度 `−2047..0`、`distinct=2048`、机械转速 719–731 rpm。

---

## 2. 缺陷 2：UVW 反向只有 3 个扇区

### 2.1 现象

位置计数修好之后（BUILD 0x0014）反向转台：

```
UVW states {1:5427, 4:19537, 5:4956}   transitions 145/s
```

3 个状态全是 `v=0`（`(u,v,w)=001/100/101`），换向 145/s ≈ 3×48 Hz ⇒ **只有 3 个扇区在轮转**。

### 2.2 仿真

`_boardtest/tb_uvw.v`（+32 LSB/拍、2 转、pairs=4）：`transitions=49`、6 态均匀 ⇒ **前向完全正确**。
`_boardtest/tb_uvw_rev.v`（−32 LSB/拍）：`REV transitions=7`、82% 停在 110 ⇒ **反向卡死，与板上一致**。

`tb_uvw_rev2.v` 逐点探针：

```
i=400 eang=3136 sec=0 ...          ← 反向走到第一圈末尾
i=500 eang=55872 sec=0 offb=-55872 ← 角度绕回 65535 侧，基准仍是 BND[0]=0
```

### 2.3 根因

`off_bwd = BND[r_sec] − eang` 在 `r_sec==0` 时基准是 0；角度退到负值后在 16 位里变成接近 65536 的大数，
`off_bwd` 恒为大负数，`bwd_le` 永不成立 ⇒ **0→5 这条唯一的环绕边界被永久吞掉**。
前向对 5→0 早已用 `fwd_wide` 特判，反向没有对称处理。

### 2.4 修法

```verilog
wire signed [AW:0] bwd_wide;
assign bwd_wide = (r_sec == 3'd0 && eang_x > 17'd54614)
                ? ($signed(17'd65536) - $signed({1'b0, eang_x}))
                : ($signed(bnd_bwd_nxt) - $signed({1'b0, eang_x}));
assign off_bwd = bwd_wide;
```

阈值 `54614 = BND[5]`，与前向用 `eang_x < 10923 = BND[1]` 完全同构。

**验证**：前向 `transitions=49` 不变；反向 `REV states 001=6120 010=6192 011=6120 100=6055 101=6246 110=6129`、
`transitions=50` ⇒ 两方向都 6 态均匀。

### 2.5 板上验证

`_boardtest/diag_pos3.py COM4 3`：`UVW states {1:5423, 2:4984, 3:4548, 4:4971, 5:5020, 6:4959}`、
`transitions/s 293`（≈ 6 × 48.9 Hz）；60 s 长跑六态各 9.1–10.8 万帧、u/v/w 每秒翻转 5,848/5,809/5,852 次。

---

## 3. 同一轮顺手修掉的三处

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 3.1 | `rtl/uvw_gen.v` `dir_det` | 用 `wrap_fwd` 启发式判方向（增量落在后半圈 + 当前角度低半圈 + 上一拍前向 ⇒ 判前向回绕），反向时可能误判 | 改 **16 位最短有符号差**：`d_ang_s = eang − r_ang_prev`，`>0` 前向、`<0` 反向、`=0` 保持 |
| 3.2 | `rtl/uvw_gen.v` `move_fwd/move_bwd` | 隐式 1 位线网（Vivado 容忍，ModelSim 报 `vlog-2730 Undefined variable`） | 显式 `wire move_fwd, move_bwd;` |
| 3.3 | `disp/enc_top_disp.v` | 显示版 `DISP_CPR` 只有 `64` 与 `0` 两档，2048 PPR 下屏上 RPM/转数会显示成 **16×** | 新增 `elsif ENC_V69_CPR2048 → DISP_CPR = 2048`（向后兼容 v62/v66/v68） |

---

## 4. 构建签核

### 4.1 生产位流（无屏）

| 项 | 结果 |
|---|---|
| 位流 | **1,517,496 B** @2026-11-01 22:36:58；SHA256 `48EACCFEFBEBC99EB90AA92C14C1A4B6B9177BB2D688FD8B0B258CC5111A8E94` |
| 时序 | **WNS +0.091 / TNS 0.000 / 0 失败（24,680 端点）**；WHS **+0.065** / 0 失败（24,215）；WPWS +0.264 / 0 失败（9,004） |
| 资源 | LUT **10,955 = 52.67%**、FF **8,722 = 20.97%**、BRAM **32/50 = 64.00%**、DSP **17/90 = 18.89%**、IOB 63 |
| DRC | 45 checks：DPIP-1 ×12、DPOP-1 ×16、DPOP-2 ×17（**0 Error / 0 Critical Warning**） |
| 布线 | 18,654 条可布线网全部布通、**0 routing errors**；48 条 no-load net |

### 4.2 显示位流（LCD + 千兆网）

| 项 | 结果 |
|---|---|
| 位流 | **1,708,301 B** @2026-11-01 22:46:37；SHA256 `1081DCA7002B80A2C88CF82221D683DBE7A63757BDEF70D5E9AE3DE760563FBB` |
| 时序 | **WNS +0.027 / TNS 0.000 / 0 失败（34,321 端点）**；WHS **+0.057** / 0 失败（33,856）；WPWS +0.264 / 0 失败（12,052） |
| 资源 | LUT **17,415 = 83.73%**、FF **11,544 = 27.75%**、BRAM **48/50 = 96.00%**、DSP **19/90 = 21.11%**、IOB 107 |
| DRC | 99 checks：BUFC-1 ×1、CHECK-3 ×2、DPIP-1 ×15、DPOP-1 ×18、DPOP-2 ×19、RBOR-1 ×4、REQP-1839 ×20、REQP-1840 ×20（0 Error / 0 Critical） |
| 布线 | 27,912 条可布线网全部布通、0 routing errors；97 条 no-load net |
| eth_rxc | `report_timing -group eth_rxc_clk` 最差 **slack MET 1.907 ns** |

> 显示版 WNS 只有 +0.027，是 v68/v69/v70 三代里最紧的一版（BRAM 96%）；改显示逻辑前先看 `disp_util.rpt`。

---

## 5. 上板实测（v70 生产位流，BUILD 0x0015）

下位流：`prog_retry.tcl` + `TAG='V70D'` ⇒ `V70D PROGRAMMED_OK`（22:41:20）。

### 5.1 身份 / 计数 / UVW

| 命令 | 结果 |
|---|---|
| `check_v70.py COM4 3` | `RTL_BUILD=0x0015`、`INTER0=32`、`UVW_CFG=0x2004`；电周期速率 **−24,543 cycles/s** ⇒ **719.0 rpm**；`r` min 24,186 / mean 26,047 / max 27,634（**0.843 FS**）；UVW 六态 `{1:5970, 2:5538, 3:5031, 4:5539, 5:5507, 6:5548}`；`lock=0x0301`、`stat_flags=0x0000` |
| `diag_pos3.py COM4 3` | 29,905 帧 / 9,968 fps；`rate −24,962 cycles/s ⇒ 731.3 rpm`；**`cnt` 跨度 −2047..0、distinct=2048**；**Z 12.00 Hz**（2048 PPR 下每转 1 个 Z） |

> 转台实际 719–731 rpm（≈ 24.5–25.0 k 电周期/s），与"标称 25.27 kHz ⇒ 740 rpm"的差是转台自身转速波动，不是计数误差。

### 5.2 精度 / 标定

| 项 | 结果 |
|---|---|
| `angle_vs_sc.py COM4 3` | 分箱系统误差 −0.13°..+0.13°；谐波 `h1=0.050 h2=0.026 h3=0.006 h4=0.093°`（与 v68 同量级，v70 的 `dir_det`/UVW 改动不影响角度链路） |
| `calib_v68.py COM4` | 标定前 `gain 32768/32768、shift=0、amp_sq=12,368`；写 `0x0502=1` 后 `gain_s=33,776`、`gain_c=33,568`、`shift=0`、`flags=0x0010`（calib_done）、`amp_sq=53,514`、`lock=0x0301` |

### 5.3 以太网

| 项 | 结果 |
|---|---|
| ping | 5/5 通、<1 ms |
| UDP 抓包 | 28,672 点 @25.000 MSPS（抽取 ×2）、峰值 52,048；**首次缺 45 块（10..54），随后 3/3 次 `missing=[]`** |
| 注意 | 每次重新配置 FPGA，`0x070C`（UDP 端口）会复位回 5000，主机的 5010 必须重写一次；本机 5000 被 `lkcitdl` 占用 |

### 5.4 60 s 长跑（`soak_v68.py COM4 60`）

```
frames=598115  elapsed=60.0s  fps=9968.6
r: min=17020 mean=26766 max=28312 (max=0.8640 FS)
lock 0x0301  stat_flags 0x0018
UVW {1:108152, 2:99442, 3:91536, 4:99437, 5:99420, 6:100126}
level% a 49.94 b 50.00 z 0.0 u 50.01 v 48.67 w 49.99
flips  a 298173 b 298922 u 5848 v 5809 w 5852 z 30
angle vs atan2: mean |err| 2.839°  n=119623  |err|>5° 150
```

- 10 kHz 帧率不丢、r 均值稳定（26,763–26,766，漂移 <0.02%）、`lock` 一直 TRACK；
- UVW 六态各占 15–18%，u/v/w 每秒翻转约 97 次（293 次换向/秒 ÷ 3）；
- 2.839° 的常数偏移是 s/c 快照与 `angle` 的流水线时差（≈323 ns），v68 同样存在，不是 v70 引入。

---

## 6. 环境备忘（本轮踩到的、会反复咬人的）

| 现象 | 真因 | 处理 |
|---|---|---|
| `ERROR: [Labtoolstcl 44-494] There is no active target available … may be locked by another hw_server` | 强关 Vivado / 强杀 hw_server 后 FTDI 句柄残留；系统里只剩一个 hw_server 也会报 | **拔插 JTAG USB 线**（关 Vivado、重启 hw_server、杀 cs_server 都无效）；管理员的 cs_server 普通权限杀不掉 |
| `ERROR: [Labtoolstcl 44-235] The labtools system is not initialized` | Vivado 2026.1 必须先 `open_hw_manager` 再 `connect_hw_server` | 所有 tcl 开头加 `open_hw_manager` |
| `invalid command name "?#"` / `(file "...tcl" line 1)` | PowerShell `Set-Content -Encoding UTF8` 写 BOM（`ef bb bf`） | 生成 .tcl/.v 一律用 Python：读 `utf-8-sig`、写 `utf-8` + `newline="\n"` |
| `xsim` 报 `Could not open file mapping object (2)` + `EXCEPTION_ACCESS_VIOLATION` | 本机 xsim 内核启动即崩（共享内存/沙箱），`xvlog/xelab` 正常 | 用 **ModelSim**：`D:\ModelSim\win64\vsim.exe`，秒级迭代 |
| `-LogFile _boardtest\xxx.log` 报 "Could not find a part of the path" | `run_vivado_hw.ps1` 的 `-LogFile` 是**裸文件名**（内部 Join-Path 到 `_flash2_work`） | 只传文件名 |
| 下载后串口 0 字节 | 恰好撞上 CH340 重新枚举 | 等 2–3 s 再测；`raw_probe.py` 先看 `AA55` |

### 6.1 离线自检（板子断开后做的）

| 检查 | 结果 |
|---|---|
| `tools/final_verify.ps1` | **27 项 OK / 4 项 FAIL**。4 项 FAIL 全是"陈旧性"告警：`sim/logs/SUMMARY.md`（2026-10-30）与写死 v66 目录的 `prod/disp bitstream`（2026-10-28）比今天改过的 RTL 旧。**xsim 在本机起不来**（`Could not open file mapping object`），回归摘要无法重跑；本轮用 ModelSim 的 `tb_acc2`/`tb_uvw`/`tb_uvw_rev` 作为等价证据。其余守卫（无仿真语句泄漏、生产脚本不含 `ENC_DISP_TAP`、`POLE_BITS = 11`、UDP 端口一致性、host 自检）全部 OK。 |
| `tools/check_build_freshness.py --all-v70`（新增） | **两条都 FRESH**：生产位流 22:36:58 / 显示位流 22:46:37 均晚于最新源码 `rtl/uvw_gen.v` 22:32:34。该脚本按"位流 mtime ≥ 源码 mtime"判断，不写死版本目录，替代 `final_verify.ps1` 里那两条 v66 时代的陈旧检查。 |
| `deliverables/data/SHA256SUMS.txt` | **213 行全部校验通过**（193 件证据 = 171 件历史 + **v70 的 22 件**，再加 19 张图与 README）。 |


---

## 7. 缺陷状态总表（对 `docs/32` 的更新）

| 编号 | 缺陷 | v68 报告状态 | 现在 |
|---|---|---|---|
| D1 | 位流按 64 电周期/圈综合（PPR 32×） | ❌ 致命 | ✅ **v69 起 `POLE_BITS=11` 修正**；但真正让位置复活的是 v70 的 `step_s` 修复 |
| D2 | UVW 不换相 | ❌ 致命 | ✅ **已修**（§2）：v68/v69 的 `cycle_cnt=0` 让 `mech_angle` 恒 0，v70 修好计数后又暴露 `off_bwd` 回绕缺陷，两处都已修 |
| D3 | UDP/串口抓包冷启动丢块 | ⚠ 现象 | ⏳ 仍在：每次重配置后首次抓包缺 40+ 块，重抓即 `missing=[]`；属 ARQ/学习期，需在 `docs/32` §6 说明 |
| D4 | ARP MAC 口径不符 | ⚠ 记录 | ⏳ 仍在：实测 `00:00:02:00:00:01`，`board_eth_check.py` 期望 `02:00:00:00:00:01`；不影响 ping/UDP |
| D5 | `inclim`/假 OTR sticky | ⚠ 已知 | ⏳ 仍在：`0x053A` bit3 = OTR（模块 OTR 脚毛刺，已在 XDC 加下拉）；`0x0405` bit3 `inclim` 与 `uvw_freq_warn` 同源（`enc_top.v:1286`），v70 后仍间歇出现（见 §8） |
| D6 | UART 0.34% 坏帧 | ⚠ 现象 | ⏳ 仍在（2 Mbaud 下多比特 XOR 错），不影响遥测统计 |
| D7 | Flash 未知 | ⛔ 未测 | ⛔ 仍未固化；本轮全部走 SRAM 下载 |
| **D8（新）** | `cycle_cnt` 恒 0 | — | ✅ 已修 |
| **D9（新）** | 显示版 CPR=64 ⇒ 屏上 RPM 16× | — | ✅ 已修（`ENC_V69_CPR2048`），**但显示位流尚未上板目视确认** |

---

## 8. 仍未完成 / 已知问题

1. **显示位流未上板验证**：`enc_top_disp_v70.bit` 已构建（WNS +0.027），但本轮下载时 JTAG 进入 44-494 假死，
   用户随后断开板卡。**下次上板第一件事**：下载显示位流，确认屏上 RPM ≈ 720（而不是 23,687 或 16 倍偏差）、
   长按 `key_n` 一键标定、`ui_btn` 翻页、触摸可用。
2. **Flash 固化未做**：仍在 SRAM 里跑。`docs/30_flash_program_guide.md` 的流程可用（先装 `spi_xc7a35t_pullnone.bit` 桥），
   但 2026-10-30 有过一次 erase 成功 / program 失败的历史，固化前建议先备份当前 Flash 内容。
3. **`uvw_freq_warn` 间歇置位**（`io_flags` bit3 = 0x38 形态出现约 18% 帧）：UVW 输出本身正确（293 换向/秒），
   推测是扇区边界抖动导致 `r_dwell < MINHALF` 偶发（`rtl/uvw_gen.v:537-538`），属观感问题，待后续用 ILA 或更细遥测确认。
4. **`0x0404/0x0405` 高位脏读**：8 位寄存器读回的高字节是脏数据，
   上位机取值必须 `& 0xFF`；`check_v70.py` 已做掩码，`host/link.py` 侧建议后续统一。
5. **ABZ 边沿契约**：`inter=32` ⇒ 2048 × 32 = 65,536 A 沿/圈；屏上 `ui_inter` 预置的 64 只是待写值，别在屏上改。

---

## 9. 复现

```powershell
# 生成 v70 变体 RTL（只读 rtl/，写到 _synth_work_v70/rtl_v70）
E:\Anaconda\python.exe tools\make_v70_rtl.py

# 生产位流
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_v70.tcl -LogFile build_v70.log -Tail 20

# 显示位流（必须串行，两个 Vivado 不能并发）
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_disp_v70.tcl -LogFile build_disp_v70.log -Tail 20

# 上板
$env:BITFILE='C:/Users/zhaoy/Desktop/FPGA/deliverables/data/v70/enc_top_v70.bit'; $env:TAG='V70'
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl _boardtest\prog_retry.tcl -LogFile prog_v70.log -Tail 10

# 验收
E:\Anaconda\python.exe _boardtest\check_v70.py COM4 3
E:\Anaconda\python.exe _boardtest\diag_pos3.py COM4 3
E:\Anaconda\python.exe _boardtest\soak_v68.py COM4 60
```

---

## 10. 文件与哈希

`deliverables/data/v70/`（21 件 + `SHA256SUMS.txt`），关键两件：

| 文件 | 大小 | SHA256 |
|---|---:|---|
| `enc_top_v70.bit` | 1,517,496 | `48EACCFEFBEBC99EB90AA92C14C1A4B6B9177BB2D688FD8B0B258CC5111A8E94` |
| `enc_top_disp_v70.bit` | 1,708,301 | `1081DCA7002B80A2C88CF82221D683DBE7A63757BDEF70D5E9AE3DE760563FBB` |

（v70 的 `VARIANT_INFO.txt` 里"patches"只列了 3 条：`RTL_BUILD_ID 0x000E→0x0015`、`INTER0 2→32`、
`pole_counter` 增量累加器；**UVW 的两处修复是直接改 `rtl/uvw_gen.v` 源文件**（v70 变体从源复制），
不体现在补丁列表里，以 `rtl/uvw_gen.v` 中的 `★ 2026-11-01` 注释与 `bwd_wide`/`d_ang_s` 为准。）
