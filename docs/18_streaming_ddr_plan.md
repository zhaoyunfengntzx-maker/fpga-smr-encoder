# 18 · 二期：连续流与深存储（DDR3）方案

> 状态：2026-10-19 起草。本文是二期（连续采样 / 长时间记录）的方案与实施记录。
> 一期（单次抓包 1.15 ms + 串口回读 / UDP 回读）见 [`docs/17_ethernet_capture_plan.md`](17_ethernet_capture_plan.md)。

## 0. 一句话结论

- **连续流（不落 DDR3）现在就能做**：抽取 2 后 12.5 MSPS × 4 B = 400 Mbps，
  千兆链路占用约 42%，可以无限时长连续推流，主机滚动显示。已实现（见 §3）。
- **DDR3 深存储（秒级）需要 MIG**：48 根引脚已经拿到并生成
  [`constr/ddr3_pins.xdc`](../constr/ddr3_pins.xdc)（§4.1）；但 MIG 4.2 的 DDR3 参数在
  Vivado 2026.1 里**不通过 Tcl 暴露**（实测只看到 193 个属性、除 `INSERT_VIP` 外没有
  `CONFIG.C0.DDR3_*`），所以还差**一次性 GUI 配置**导出 `.xci`（§4.2 列了逐项设置）。

## 1. 为什么不能"双通道 50 MSPS 直接连续上网"

千兆以太网 UDP 的可用载荷约 950 Mbps（扣除前导码/IFG/以太网+IP+UDP 头后）。

| 场景 | 样点率 | 载荷 | 占千兆 |
|---|---|---|---|
| 双通道，抽取 1（50 MSPS） | 50 MSa/s × 4 B | **200 MB/s = 1600 Mbps** | **160%**（不可行） |
| 双通道，抽取 2 | 25 MSa/s × 4 B | 100 MB/s = 800 Mbps | 84%（太紧） |
| 双通道，抽取 4 | 12.5 MSa/s × 4 B | 50 MB/s = **400 Mbps** | **42%**（推荐） |
| 双通道，抽取 8 | 6.25 MSa/s × 4 B | 25 MB/s = 200 Mbps | 21% |
| 单通道，抽取 1 | 50 MSa/s × 2 B | 100 MB/s = 800 Mbps | 84%（太紧） |

结论：**连续流的可用区间是"抽取 ≥ 2"**；想要 50 MSPS 不间断，只能先落 DDR3 再回放（§4），
因为 DDR3 的 12.8 Gbps 远大于千兆，瓶颈在网口而不在存储。

## 2. 连续流的数据通路

```
ADC 50 MSPS ──► scope_capture（环形，28672 点，自由写）
                        │ wr_ptr
                        ▼
                 stream_tx（50 MHz 侧追赶读 + 异步 FIFO）
                        │ 125 MHz 侧组包
                        ▼
                 eth_tx_mac ──► PHY ──► PC
```

与原 `scope_udp` 的区别：

- `scope_udp` 是"一次抓包 → 等抓完 → 一次性推 N 个包 → 结束"；
- `stream_tx` 是"写指针一直走，读指针追，永远不停"，包序号与绝对样点序号连续递增，
  主机靠**序号跳变**判断丢包/溢出，而不是靠"缺哪一块"。

### 2.1 包格式（与一期完全相同，只多一个标志位）

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0-1 | 2 | 魔数 `E7 5A` |
| 2 | 1 | flags：bit0 = 末包，**bit1 = 连续流** |
| 3 | 1 | 抽取 log2（0..4） |
| 4-5 | 2 | 包序号（LE，16 bit 回绕） |
| 6-9 | 4 | 首样点序号 **低 32 bit**（LE） |
| 10-13 | 4 | 首样点序号 **高 32 bit**（LE）—— 连续流时有效，一期恒 0 |
| 14-15 | 2 | 保留（0） |
| 16.. | 4×N | 样点：`s` int16 LE + `c` int16 LE |

- 连续流固定 **N = 350**（1500 B MTU）。
- 首样点序号是 **64 bit 绝对样点计数**（@12.5 MSPS 回绕周期约 4.7 万年，实际不担心）。
- 主机按 `first` 把样点放到环形缓冲的正确位置；`first` 跳变即丢样点，计入 `dropped`。

### 2.2 寄存器（0x0740 段，16 bit 对齐）

| 地址 | 名称 | 说明 |
|---|---|---|
| 0x0740 | STREAM_CTRL | bit0 使能（写 1 开始、写 0 停流并让读指针追上写指针） |
| 0x0742 | STREAM_DEC | 连续流的抽取 log2（1..4），默认 2（=×4） |
| 0x0744 | STREAM_STATUS | bit0 运行中 / bit1 读指针落后溢出（发生过丢样点）/ bit2 使能 |
| 0x0746/48 | STREAM_PKTS | 32 bit 发包计数（LE） |
| 0x074A/4C | STREAM_DROP | 32 bit 丢弃样点数（LE，读侧落后半缓冲时整段丢弃） |
| 0x074E | STREAM_LAG | 读指针落后写指针的点数（诊断用） |

> 注：实现里 `STREAM_CTRL` 只有 bit0；计数器在开流时由 `scope_capture` 的 arm 自动清零，
> 不需要单独的"清计数器"位（原表里的 bit1 已去掉，避免文档与 RTL 对不上）。

## 3. 实施记录

| 日期 | 内容 | 验证 |
|---|---|---|
| 2026-10-19 | `rtl/eth/stream_tx.v`：追赶读 + 异步 FIFO + 连续组包；`cap_regs` 加 0x0740 段；`eth_top` 挂第三路 TX（优先级最低） | `tb_stream_tx` **199 checks PASS** |
| 2026-10-19 | `host/stream_capture.py`：后台线程收包 + numpy 环形缓冲 + `snapshot()`；抓包页「网口连续流」通道 | `selftest_stream.py` **29 checks PASS** + 界面冒烟 |
| 2026-10-19 | `host/link.py`：`stream_status/stream_start/stream_stop`（0x0740 段读写） | 随界面冒烟 |
| 待办 | 上板验证连续流的长期稳定性（≥ 10 min）与丢包率 | 见 §5 |

### 3.1 实现（2026-10-19）

- 综合 + 实现：**WNS +0.101 ns / WHS +0.028 ns，TNS/THS 均为 0，0 failing endpoints**；
  LUT 9864 / 20800 = **47.42%**、FF 7583 = 18.23%、Block RAM Tile **34/50 = 68%**、DSP 16、IOB 63。
- 位流：`deliverables/data/bitstreams/enc_top_b3_stream_2026-10-19.bit`（1,453,984 B），
  DRC 0 错误。
- 报告：`deliverables/data/timing/impl_{timing,util,drc}_b3_stream_2026-10-19.rpt`。
- 时序收敛过程中修的两处：`stream_dec` 直跨 50→125 域（WNS −0.957，加两级同步后 +0.101）；
  `scope_capture` 新端口在测试台悬空导致 `dec_sel` 变 X（测试台补接常量）。

> 那次构建 BRAM **34/50**，只剩 **16** 个 RAMB36 余量（留给 DDR3 的 AXI 缓冲 / 屏 / ILA）。
> v60 合并版把抓包深度定在 **28,672 点（28 片）**：屏 16.5 + 以太网 2 + 抓包 28 = **46.5/50**，
> 再往上加深度会先撞 BRAM 而不是逻辑。

## 4. DDR3 深存储（引脚已解决，MIG 配置仍需一次 GUI 操作）

### 4.1 引脚：已解决（2026-10-19）

`_v11_verify/达芬奇Lite开发板IO引脚分配表.xlsx` 里就有全部 DDR3 引脚，共 **48 根**
（含 `ddr3_reset_n`）。已用 `_gen_ddr3_xdc.py` 生成 **[`constr/ddr3_pins.xdc`](../constr/ddr3_pins.xdc)**，
并与《开发指南》第十七章的表格逐脚核对（`ddr3_dq[0]=C2`、`ddr3_addr[0]=M5` 等一致）。

| 组 | 数量 | 例 |
|---|---|---|
| `ddr3_addr[0..13]` | 14 | M5, J4, K4 … |
| `ddr3_ba[0..2]` | 3 | P2, P1, M6 |
| `ddr3_dq[0..15]` | 16 | C2, G1, A1 … |
| `ddr3_dqs_p/n[0..1]` | 4 | E1/D1, K2/J2 |
| `ddr3_dm[0..1]` | 2 | D2, G2 |
| 控制/时钟 | 9 | `ras_n` P6、`cas_n` N5、`we_n` L4、`ck_p/n` P5/P4、`cke` N3、`cs_n` L6、`odt` R1、`reset_n` F4 |

IOSTANDARD 全部 `SSTL135`（BANK35 供电 1.35 V），DQ/DQS 另加 `IN_TERM UNTUNED_SPLIT_40`。

### 4.2 MIG 配置：**Tcl 走不通，需要一次 GUI**

实测（`tools/mig_probe*.tcl`，Vivado 2026.1 / MIG 4.2）：

- `list_property [get_ips mig]` 只有 **193 个属性，除 `INSERT_VIP` 外没有任何 `CONFIG.C0.DDR3_*`**；
  `report_property -all` 也一样。
- 直接 `set_property CONFIG.C0.DDR3_TimePeriod ...` 能过，但 `CKE`/`ChipSelect`/`CASLatency` 报
  `Vivado 12-4371 Cannot find parameter` ⇒ 参数表只在你**在 GUI 里选过 Memory Type 之后**才展开。
- 结论：MIG 的 DDR3 配置存在 GUI 生成的工程文件里，纯脚本建不出来。
  **不要**再花时间试参数名（已试 4 轮，见 `tools/mig_build.tcl` 的注释）。

**需要你做的一次性操作（约 5 分钟）**：Vivado 里 `IP Catalog → Memory & Storage Elements →
Memory Interface Generators → MIG 7 Series`，按下面填，然后 `Generate`，把生成的
`mig_7series_0.xci`（以及整个 `mig_7series_0` 目录）拷到工程 `ip/` 下告诉我：

| 页面 | 设置 |
|---|---|
| Memory Selection | DDR3 SDRAM |
| Memory Part | `MT41K128M16XX-125`（书里就用它代 NT5CC128M16JR-EK） |
| Data Width | 16 |
| Data Mask | ✓（DM 脚在用） |
| Number of Bank Machines | 4 |
| Ordering | Normal |
| DDR3 时钟 | 400 MHz（周期 2500 ps） |
| PHY 比例 | 4:1 |
| Input Clock | 200 MHz（周期 5000 ps），Source = Single-Ended |
| System Clock | No Buffer（由外部 MMCM 提供） |
| Pin Selection | **Fixed**，按 `constr/ddr3_pins.xdc` 逐脚填（或 Import 该 xdc） |
| XADC / Internal Vref | 都不勾（BANK35 有 1.35 V 供电，不走 XADC） |

### 4.3 已落地：DDR3 上板自检（2026-10-19）

拿到 MIG（用户在 GUI 里生成，产物已拷进 `ip/mig_7series_0/`）后先做了一次**独立顶层自检**，
而不是直接接抓包——DDR3 任何一环不对（MIG 参数、引脚、BANK 电压、200 MHz 时钟、PCB 走线）
都表现为"读出来是乱的"，先跑最小闭环才能分清是 MIG 还是自己的读写引擎。

| 文件 | 作用 |
|---|---|
| `rtl/ddr3/ddr3_top.v` | 自检顶层：MMCM 50→200 MHz、MIG 例化、写 1024×128 bit 再读回比对 |
| `constr/ddr3_top.xdc` | 只管 `sys_clk`（V4）、`led[1:0]`（AB21/AB22）、CFGBVS/CONFIG_VOLTAGE |
| `tools/impl_ddr3.tcl` | 综合 + 实现脚本（读 `ip/mig_7series_0/**/user_design/rtl/*.v` + MIG 自带 pin xdc） |

**实现结果**：`0 errors / 0 critical warnings`，**WNS +0.994 ns / WHS +0.060 ns，0 failing endpoints**；
LUT 4,606（22.14%）、FF 3,874（9.31%）、BRAM 0、DSP 0。位流
`deliverables/data/bitstreams/ddr3_top_bringup_2026-10-19.bit`（2,192,211 B）。

**上板判读（两块 LED，2026-10-19 改到 sys_clk 域）**：

| LED | 含义 |
|---|---|
| `led[0]` 1 Hz 闪 | 心跳：只依赖 50 MHz 时钟，与 MMCM/MIG 无关——不闪就是位流/引脚/配置的问题 |
| `led[1]` 常亮 | MIG 校准完成 **且** 1024 个字全部读回一致 |
| `led[1]` 2 Hz 闪 | 有错（错字数在内部 `err_cnt`） |
| `led[1]` 不亮 | 还没校准完（此时 `led[0]` 应该在闪） |

> 为什么把心跳搬到 sys_clk 域：第一版 `led` 全在 ui_clk 域，MIG 没校准就没时钟，
> 两个灯全灭——和"板子没配置"完全无法区分。现在 `led[0]` 只依赖 50 MHz，
> 一上电就必须闪，把"位流有没有跑起来"和"DDR3 好不好"彻底分开了。

**上板实测（2026-10-19）**：烧 `ddr3_top_bringup3_sstl135` 后 `led[0]` 1 Hz 闪、
`led[1]` **常亮** ⇒ **MIG 校准通过，1024×128 bit 写入/读回全部正确，DDR3 硬件通路已验证**
（400 MHz DDR、4:1、128 bit UI、1.35 V SSTL135 全部生效）。

> 二分过程留档：纯 LED 位流（`led_blink_test`）→ 两灯交替闪（板子/时钟/引脚 OK）；
> `ddr3_top` 初版两灯全灭 → 定位为"心跳挂在 ui_clk 域"而不是 DDR3 坏；
> MMCM-only 位流（`blink_mmcm_bisect`）备用未用上。

**电平标准（已定，2026-10-19）**：万用表实测 BANK35 的 VCCO = **1.35 V**，确认手册没写错。
MIG 按 `MT41K128M16XX-125` 生成的是 `SSTL15`，对这块板是错的，因此加了覆盖文件
[`constr/ddr3_io_135.xdc`](../constr/ddr3_io_135.xdc)（单端 `SSTL135`、DQS/CK 差分 `DIFF_SSTL135`），
由 `tools/impl_ddr3.tcl` 在 MIG 的 pin xdc **之后**读入（后写的生效）。覆盖后实现：
**0 errors / DRC 0 errors / WNS +0.994 ns / WHS +0.057 ns**，位流
`deliverables/data/bitstreams/ddr3_top_bringup3_sstl135_2026-10-19.bit`。

> 坑记录：生成覆盖文件时用 `startswith('ddr3_ck')` 会把 `ddr3_cke` 也匹配成差分，报
> `DRC IOSTDTYPE-1`；要按 `ddr3_ck_` / `ddr3_dqs_` 匹配。另外读 MIG 的 RTL 时必须跳过
> `*_sim.v`，否则仿真模型会把真实模块定义覆盖掉（`Synth 8-9873`）。

### 4.4 已落地：`ddr3_ring` 环形存储引擎（2026-10-19，仿真通过）

`rtl/ddr3/ddr3_ring.v` 是真正要接进生产工程的存储引擎，把 MIG 的原生 UI 包成
"写环形缓冲 + 按绝对序号回读"两个简单接口：

| 端口组 | 方向 | 说明 |
|---|---|---|
| `wr_clk/wr_valid/wr_data/wr_ready` | 写侧 | 50 MHz 域，一个样点 32 bit；`wr_ready` 高表示收下了 |
| `wr_samples[31:0]` / `wr_wrapped` | 状态 | 累计写入点数；超过容量后置 `wrapped`（最早的被覆盖） |
| `ui_clk/ui_rst` | 时钟 | MIG 的 100 MHz UI 时钟域 |
| `rd_start/rd_base/rd_len` | 读侧请求 | 按**绝对序号**回读，`rd_base` 是样点序号不是字地址 |
| `rd_data/rd_valid/rd_done/rd_busy` | 读侧数据 | 每拍一个 32 bit 样点，`rd_done` 粘滞到下次 `rd_start` |

要点：

* **容量** `RING_AW=18` ⇒ 262144 个 128 bit 字 ⇒ **1,048,576 点 = 4 MB**；
  字内 4 点按 `base[1:0]` 对齐做 skip，非对齐起点也能读（`base=5` 用例已验）。
* **跨域**：写侧 32 bit 样点进 `async_fifo`（深度 256），ui_clk 域凑满 4 点再拼
  一个 `app_wdf_data`；FIFO 快满时 `wr_ready` 拉低反压，不丢点。
* **写命令与数据是两次独立握手**：必须先等 `app_en && app_rdy`（命令被接收），再拉
  `app_wdf_wren`。反过来（数据先到）MIG 会把数据和**上一条**命令配对，表现为
  "地址 17 收到第 18 个字、地址 18 永远没数据"——这是本次调试最花时间的一个坑。
* **读解包**：`app_rd_data` 是 128 bit/4 点，`app_rd_data_valid` 连续来；排空
  （`upend`，尾部不足 4 点）必须和"来新 word"分开处理，否则同拍撞 `uidx` 赋值会吞掉整字。

**仿真**：`sim/tb_ddr3_ring.v` 带行为级 `mig_ui_model`（随机反压、8~15 拍读延迟、
读响应 FIFO），结果 **215 checks / 0 errors / TEST PASSED**：

| 用例 | 内容 | 结果 |
|---|---|---|
| [A] 写 | 写 200 点，检查 `wr_samples=200`、`wrapped=0` | PASS |
| [B] 读 | `base=0, len=200` 回读，逐点比对 | PASS |
| [C] 非对齐 | `base=5, len=10` 回读，逐点比对 | PASS |
| [D] 小容量 | `RING_AW=4`（64 字 / 256 点）写不绕 | PASS |

跑法：`tools/run_sim.ps1 -Only tb_ddr3_ring`（`rtl/ddr3/ddr3_ring.v` 已加入回归源列表）。

### 4.5 已落地：1 M 点上板验证顶层（2026-10-19）

`rtl/ddr3/ddr3_top_mem.v` + `tools/impl_ddr3mem.tcl`：把 `ddr3_ring` 按生产用法接起来，
在真板子上跑"写 1,048,576 点 → 回读 → 逐点比对"。

* `RING_AW=18`、`NSAMP=1048576`、图样 `pat(i) = i ^ 32'h5A5A0000`（XOR 而非加法，
  错位一个字立刻在低位看出来）；
* 状态机 `S_IDLE → S_WR → S_FLSH(5000 拍) → S_RQ → S_RD → S_DONE`；
  `S_RQ` 把 `rd_start` 保持为电平直到 `rd_busy` 起来——写引擎可能还在排最后几条命令，
  单拍脉冲会被丢掉、整轮测试就卡死（带 2 千万拍超时兜底）；
* 写侧用**组合 valid**（`wr_valid = wr_idx < NSAMP`，`wr_data = pat(wr_idx)`，
  只有 `wr_valid && wr_ready` 才前进）。如果像测试台那样"看 ready 再打一拍 valid"，
  FIFO 反压的那一拍会丢样点：1 M 点灌不满、图样整体错位；
* `led[0]` 1 Hz 心跳（sys_clk 域）、`led[1]` 常亮=全部通过 / 2 Hz 闪=有错 / 不亮=在跑或没校准。

**实现结果（2026-10-19）**：0 errors、DRC 0 errors（5 条 MIG 内部 warning）、
**WNS +0.467 ns / WHS +0.050 ns、0 failing endpoints**；LUT 6,739（32.40%）、
FF 5,358（12.88%）、BRAM 0.5。位流
`deliverables/data/bitstreams/ddr3_top_mem_1M_2026-10-19.bit`（2,192,215 B）。

> 时序上踩的两个坑（都修掉了）：
> ① 解包原来用 `for` 循环累加 `npush`，4 次迭代互相依赖，综合出 20 级 CARRY4，
>    WNS **-1.136 ns**；改成先算 `push_n`（4 bit，注意 `4'd4 - uidx` 不能用 3 bit）
>    再并行写 4 个位置，顺带把 `uw >> {uidx,5'b0}` 做对齐。
> ② `oq_wr <= oq_wr + push_n[OQ_AW:0]`——`push_n` 只有 4 bit，取 `[4:0]` 高位是 X，
>    把整个读指针毒化成 X（现象：回读点数 0）。改成 `+ push_n`。
> ③ 50 MHz 域复位原来借 `clk200` 域的 `sys_rst_r`，Vivado 按跨域复位做 setup 分析，
>    WNS **-0.002 ns / 4 端点**；改成 sys_clk 域自己的 1024 拍 POR 计数器后 +0.467 ns。

### 4.7 上板排查记录：`init_calib_complete` 从未起来（2026-10-19 进行中）

**现象**：`ddr3_top_bringup3_sstl135` 与 `ddr3_top_mem_1M` 烧上去后 `led[0]` 正常心跳（50 MHz 与位流没问题），
但 `led[1]` 全灭。回查发现——**之前那次"`led[1]` 常亮"其实是 `blink_mmcm_bisect`（只有 MMCM，`led[1]`=`locked`）**，
DDR3 的 `init_calib_complete` 从头到尾一次都没起来过。所以 1 M 点测试是卡在"等校准"，不是读写引擎的问题
（`ddr3_ring` 的 215 项仿真与时序都通过）。

**已排除**：

| 检查 | 结论 |
|---|---|
| MIG 的 48 根引脚 vs 板卡引脚表 | 逐根一致，**0 处不同** |
| 元件型号 | `NT5CC128M16JR` = Nanya **DDR3L 1.35 V**、128M×16 = 256 MB，与实测 1.35 V、MIG 容量一致 |
| 50 / 200 MHz MMCM | `blink_mmcm_bisect` 的 `led[1]`=`locked` 常亮，MMCM 锁定正常 |

**主要疑点**：`ip/mig_7series_0/mig_7series_0/mig.prj` 里写着 `<MemoryVoltage>1.5V</MemoryVoltage>`，
即 **MIG 是按 1.5 V 器件生成的**（`SSTL15`、VREF 0.75 V、ODT/驱动按 1.5 V）。
`constr/ddr3_io_135.xdc` 只覆盖引脚 `IOSTANDARD`，MIG 内部 PHY 的电压相关参数没变。

**A/B 位流**：`ddr3_top_mem_1M_sstl15_2026-10-19.bit`（MIG 原生 SSTL15，WNS +0.602 / WHS +0.053）。
LED 编码（`ddr3_top_mem.v` 已改）：`led[0]`≈0.75 Hz 心跳；`led[1]` **6 Hz=没校准**、1.5 Hz=在跑、
常亮=全通过、0.37 Hz=有错。

**下一步**：① 若 SSTL15 版能校准 ⇒ 电平标准问题，保留 MIG 原生配置；② 若仍不能 ⇒ 在 MIG GUI 重新生成，
Memory Part 换成真正的 1.35 V DDR3L（如 `MT41K128M16JT-125`），确认总结页 **Memory Voltage = 1.35V**；
并用示波器点 **P5（`ddr3_ck_p`）** 看有没有 ~400 MHz。

### 4.7.1 根因（2026-10-20）：MIG 的 `sys_rst` 是**低有效**，被全程按在复位里

把三段关口分别编码到 `led[1]` 的频率上（`rtl/ddr3/ddr3_top_mem.v`）：

| `led[1]` | 含义 | 实测 |
|---|---|---|
| ≈6 Hz | 50→200 MHz MMCM 没锁 | |
| ≈3 Hz | MMCM 锁了，但 `sys_rst` 一直没释放 | |
| ≈1.5 Hz | 复位已放、`ui_clk` 在跑，未校准 | |
| 全灭 | 复位已放，但 `ui_clk` 不动（MIG 内部 PLL 没锁） | **← 上板就是这个** |
| 常亮 | 全通过 | |
| ≈0.37 Hz | 跑完但有错 | |

“全灭”这一档同时说明：MMCM 锁了（否则 6 Hz）、`por_cnt` 在 200 MHz 域里跑完了（否则 3 Hz）、
而 `ui_clk` 是死的。查生成的 RTL 发现：

- `ip/mig_7series_0/mig_7series_0/user_design/rtl/mig_7series_0_mig.v:1465` → `parameter RST_ACT_LOW = 1`；
- `.../rtl/clocking/mig_7series_v4_2_infrastructure.v:252` → `sys_rst_act_hi = RST_ACT_LOW ? ~sys_rst : sys_rst;`
- 同一个 `~sys_rst` 还接在 PLL/MMCM 的 `.RST` 上（infrastructure.v:329/452/556）。

也就是说 **MIG 顶层端口的 `sys_rst` 是低有效**（GUI 里 System Reset Polarity 选的是 ACTIVE LOW）。
我们一直按高有效驱动（上电 1 → 164 µs 后拉 0），等于**上电后立刻把 MIG 永久按进复位**：
内部 PLL 不锁 → `ui_clk` 不出 → `init_calib_complete` 永不置位。前面所有“引脚/电压/颗粒”方向的怀疑都不用再查了。

**修复**：`rtl/ddr3/ddr3_top_mem.v:153` 与 `rtl/ddr3/ddr3_top.v` 都改成 `.sys_rst (~sys_rst_r)`，
RTL 内部仍用高有效语义（`sys_rst_r`），只在接到 MIG 端口时取反。

### 4.7.2 复位修好之后：校准通过，但 1 M 点回读全错（2026-10-20 正在查）

修好 `sys_rst` 极性后重建（`ddr3_top_mem_1M_rstfix_2026-10-20.bit`，WNS +0.594 / WHS +0.054），
`led[1]` 从“全灭”变成 **≈0.37 Hz**，即**校准通过、测试跑完、但比对有错**。为了不再靠猜，
在 `rtl/ddr3/ddr3_top_mem.v` 里加了一个 115200 8N1 的串口（`rtl/ddr3/uart_tx_8n1.v`，
引脚 `uart_tx` = W21，见 `constr/ddr3_uart_dbg.xdc`），每 500 ms 无条件打印一行状态。

现场读数（COM6）：

```
ST=5 GOT=00100000 NEED=00100000 ERR=00100000 PEND=FFFFFFFF WL=00000000 AD=00040000
IDX=00000000 EXP=5A5A0000 GTD=00800800
```

已经确定的事实：

1. `GOT == NEED == 1 M` ⇒ 写 1 M、读 1 M、**全部回读完成**，读通道不丢拍；
2. `ERR == 1 M` ⇒ **每一个点都对不上**，不是个别位翻转；
3. 首个错点 `IDX=0`，`EXP=5A5A0000`（`pat(i) = i ^ 0x5A5A0000`），`GTD=00800800`；
4. `WL=0`、`AD=0x00040000` ⇒ 写指针停在起点、读地址计数到 262144（= 1 M / 4），符合预期；
5. `PEND` 是负的（32 位回绕），因为收尾阶段读数据比命令计数多跑了几个拍，属观测口径问题，不影响结论。

`GTD` 值 `0x00800800` 不像 `pat()` 的任何平移，更像颗粒里的**上电残留内容**（写没落地）。
所以怀疑方向从“读错位”转到“**写根本没写进去**”，下一步用两个独立实验分辨：

- `rtl/ddr3/ddr3_top_direct.v`：绕过 `ddr3_ring`，直接对 MIG 写 8 个地址、冲刷 20 µs、再逐个读回，
  串口打印 `WC/WD/RC/RV` 四个握手计数、`W0..W7` 写入值和 `T0..T3` 读回值。
  若 `T0..T7` 全是同一串残留值 ⇒ 写没落地（MIG 侧 `app_wdf` 或 DM 被屏蔽）；
  若 `T0..T7` 与 `W0..W7` 一致 ⇒ `ddr3_ring` 内部拼字/指针有 bug。
- 若确认写没落地，重点查 `ddr3_dm`（`dm[0]=D2`、`dm[1]=G2`）是否被错误屏蔽：
  数据掩码错了校准照样能过（校准只用 DQS/DQ 时序），但每个写都会被屏蔽，读回来就是残留值。

### 4.7.3 根因（2026-10-20）：`async_fifo` 的 `wr_en` 没有和 `wr_ready` 握手

`rtl/ddr3/ddr3_ring.v` 里 FIFO 的写法是：

```verilog
.wr_en  (wr_valid),              // ← 错：没有和 wr_ready 握手
```

而 `wr_ready` 是 `~fifo_almost_full`。上游（`ddr3_top_mem`）严格按握手走
（`if (wr_valid && wr_ready) wr_idx++`，`wr_data = pat(wr_idx)` 组合输出），
于是只要 FIFO 处于“快满”状态，就会出现**两边计数不一致**：

- FIFO 每拍都在把 `wr_valid` 那一路的**同一个值重复压进去**（上游因为没 ready 而不前进，数据保持不变）；
- 上游认为只写了 458 个点，FIFO 内部 `wr_ptr` 已经跑了几千个 → `almost_full` 永远不撤销，
  握手彻底卡死，同时采集侧还在不断把重复样点拼成 128 bit 字。

这正好解释上板读数里的两个怪现象：

1. `WC == WD == 1163321 ≈ 4.44 × 262144`：拼字速率被“假数据”抬高了约 4.4 倍；
2. 回读数据从第 252 点开始整段平移、GOT 有 1 M 但 ERR 有 1 M：写进去的就是重复/错位的样点。

**仿真复现**（`sim/tb_ddr3_full.v`，比例缩小版 `RING_AW=10`/8192 点，两圈绕回）：
修复前 `wr_idx` 在 458 处冻结、`u_wfifo.wr_ptr` 继续以 ~1 字/9 拍前进、
`fifo_almost_full` 恒 1，与上板现象完全一致。

**修复**：

```verilog
.wr_en  (wr_valid && wr_ready),  // 只有握手成功才真正入队
```

**同步修掉的三处“被 bug 掩盖”的问题**：

| 位置 | 问题 | 处理 |
|---|---|---|
| `sim/tb_ddr3_ring.v:236` | 上游用 `if (wr_ready)` 前进，数据晚一拍且可能丢点 | 改成标准 `valid && ready` 握手（valid/data 同时寄存） |
| `sim/tb_ddr3_full.v:213` | 回读期望用 `pat(idx)`，但环形缓冲区绕圈后槽里存的是**最后一次写入该槽**的样点 | 新增 `pat_slot(idx)`：`e = idx + floor((NSAMP-1-idx)/CAP)*CAP` |
| `sim/tb_ddr3_full.v` | 1 M 点全容量仿真要跑 ~9 小时 | 加 `` `ifdef FULLSIM ``：默认 `RING_AW=10`/8192 点（绕 2 圈，分钟级），需要时 `xvlog -d FULLSIM` 跑全容量 |

**修复后仿真结果**：

- `tb_ddr3_ring`：**271 checks / 0 errors / TEST PASSED**；
- `tb_ddr3_full`（8192 点、环形容量 4096 点、绕 2 圈）：`got=8192 err=0`，
  `wc=wd=2048`（正好 = 字数，1.00 次/字）、`rc=rv=2048`，**TEST PASSED**。

### 4.7.4 根因（2026-10-20）：`app_addr` 是**字节地址**，一次突发要 +16

握手修好之后，写侧行为正常了，但数据仍然全错，而且回读会在中途卡住。用
`rtl/ddr3/ddr3_top_direct.v`（绕开 `ddr3_ring`，直接对 MIG 写 8 个地址再读回）拿到
决定性证据：

```
A=0 EXP=A5A50000 GOT=A5A50700
A=1 EXP=A5A50100 GOT=0701A5A5
A=2 EXP=A5A50200 GOT=A5A50701
A=3 EXP=A5A50300 GOT=0700A5A5
A=4 EXP=A5A50400 GOT=A5A50702
A=5 EXP=A5A50500 GOT=0703A5A5
A=6 EXP=A5A50600 GOT=A5A50703
A=7 EXP=A5A50700 GOT=CF049184      ← 乱码
```

- 地址 0~6 读回来的全是**最后写进去的那个字**（地址 7 的内容）的四个 32 bit 切片；
- 偶地址是原值（`…0700/0701/0702/0703`），奇地址是**半字交换**后的同一个切片
  （`0701A5A5`、`0700A5A5`…）；
- 地址 7 直接读回乱码，说明这一拍起对齐/时序已经破了。

这正是“每个字只加 1 而不是加 16”的特征：8 次写全部落在**同一个 16 字节**内互相覆盖
（最后写的赢），8 次读则是在这 16 字节里**逐字节滑窗**取数（所以半字错位），
并且 `app_addr[3:0] != 0` 对 4:1 模式是非法对齐，读通路在几拍之后直接挂死。

**依据**：MIG 的 example design 里 `END_ADDRESS = 32'h00FF_FFFF`、`ADDR_WIDTH = 28`，
而 DDR3 容量正好 256 MB = 2²⁸ 字节 ⇒ **1 个 `app_addr` 单位 = 1 字节**；一个 128 bit
突发 = 16 字节 ⇒ 字指针左移 4 位。

**修复**（`rtl/ddr3/ddr3_ring.v`，写命令与读命令两处）：

```verilog
app_addr <= {{(28-RING_AW-4){1'b0}}, wptr, 4'b0000};   // 字节地址，一个突发 +16
app_addr <= {{(28-RING_AW-4){1'b0}}, addr_r[RING_AW-1:0], 4'b0000};
```

`rtl/ddr3/ddr3_top_direct.v` 同步改成 `{{(28-8){1'b0}}, idx, 4'b0000}`。

**仿真同步**：`sim/tb_ddr3_ring.v` 里的 `mig_ui_model` 原来把 `app_addr` 当字索引
（`mem[app_addr[AW-1:0]]`），现在按真实语义取字节地址的高位（`mem[app_addr[AW+3:4]]`），
否则仿真会“替真机掩盖 bug”。改后：

- `tb_ddr3_ring`：**271 checks / 0 errors / TEST PASSED**；
- `tb_ddr3_full`（8192 点、容量 4096、绕 2 圈）：`got=8192 err=0`，
  `wc=wd=2048`、`rc=rv=2048`，**TEST PASSED**。

### 4.7.5 根因（2026-10-21）：MIG 的 UI **不保证“读能看见刚发出的写”**

字节地址改对之后，直接测试版（`rtl/ddr3/ddr3_top_direct.v`，绕开 `ddr3_ring`，写 8 个
字后立即逐个读回）给出：

```
A=0 EXP=A5A50000 GOT=0000FFFF   ← 旧内容
A=1 EXP=A5A50100 GOT=1111BBBB   ← 旧内容
A=2 EXP=A5A50200 GOT=A5A50200   ✔
A=3 EXP=A5A50300 GOT=A5A50300   ✔
A=4 EXP=A5A50400 GOT=A5A50400   ✔
A=5 EXP=A5A50500 GOT=A5A50500   ✔
A=6 EXP=A5A50600 GOT=A5A50600   ✔
A=7 EXP=A5A50700 GOT=1D21D300   ← 数据还没回来就判了
```

中间 5 个地址全对，**这就是 MIG + DDR3 + 引脚 + IO 标准全部正常的铁证**。
前两个错、最后一个错，原因是**时序**而不是数据通路：

- `app_en` 只表示“命令被 MIG 的写缓冲收下了”，真正的 DRAM 突发还在队列里排队。
  紧接着发出的读命令会被 MIG 提前执行，于是读到的是**旧内容**（`0000FFFF`、
  `1111BBBB` 是上电后的随机/残留值，不是我们的 pattern）；
- 等前几个写突发真正落盘后（第 3 个读开始）就一切正常；
- 最后一个读错，是测试状态机在数据回来之前就结束取样。

**这同样解释了 1 M 点自检的 99 万错误**：写完 262144 个突发后只等了
5000 拍（50 µs，`rtl/ddr3/ddr3_top_mem.v` 的 `S_FLSH`），而排空这么多突发
@400 MHz、tCCD=4 拍需要 **≈1.3 ms**，两个数量级的差距。

**修复**：`S_FLSH` 的等待改成 400000 拍（100 MHz `ui_clk` 下 **4 ms**）。
生产路径（`docs/18` §4.8 接 `enc_top`）同理：写指针和读指针必须保持足够间距
（环形缓冲本身就是这么做的），只有在“写完立刻回读”的测试场景才需要显式等待。

### 4.8 接进生产工程（尚未做）

1. `sample_mem` 抽象层：写口 `wr_data/wr_en/wr_addr`、读口 `rd_data/rd_en/rd_addr`，
   两个实现——`bram_ring`（现有 28672 点）与 `ddr3_ring`（MIG 原生 UI，128 bit 拍）；
2. 写引擎：ADC（32 bit/样点）→ 异步 FIFO（50→100 MHz）→ 拼 4 样点/128 bit → `app_wdf`；
3. 读引擎：按绝对序号回读 → `stream_tx`（复用一期 16 B 应用头 + 64 bit 首样点序号）；
4. 深存储容量：256 MB / 4 B = 6400 万点 ≈ **2.56 s @25 MSPS**；千兆回放 256 MB ≈ 2.2 s；
5. 风险：MIG 的 `sys_clk_i` 200 MHz 与现有 125 MHz 以太网时钟、50 MHz 主时钟三域共存，
   时序收敛要单独看（自检版只有 MIG + MMCM，WNS +0.994 说明 DDR 侧本身不难）。

## 5. 上板验收（连续流）

1. 先 `ping 192.168.1.10` 通，再看 `tools/cap_dump.py --status`（或界面「诊断」页）里
   `STREAM_STATUS.bit2 = 1`（设备已使能）；
2. GUI「抓包」页把「通道」切到**网口连续流**，点「抓一次」→ 按钮变「停止连续流」，
   波形每 120 ms 滚动一次，状态行显示包速率与丢点数；
3. 正常运行 10 min：`STREAM_PKTS` 单调增、`STREAM_DROP` 不增长、状态行"丢 0 点"；
4. 拔掉网线 5 s 再插回：主机应在状态行看到丢点跳变（绝对序号缺口），
   而不是画出一条"看起来连续"的假波形；恢复后波形继续。
5. 收工时点「停止连续流」，确认 `STREAM_STATUS.bit0` 落 0、`0x0740` 读回 0。
