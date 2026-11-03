# 以太网高速波形链路方案（B 路线：原始 ADC 数据上传）

> 状态：方案稿 v1.1（2026-10-18）。三项决策已定（见 §0.1/§14）。**未改任何 RTL/固件/上位机代码**，本文只是实施依据。
> 前置调研见 `docs/14_dual_channel_feasibility.md`（硬件与例程可行性、Bank 归属、工期对比）。
> 本文回答的是："如果目标定为**把抽取前的原始 ADC 样点送上来**，具体怎么做、要多久、风险在哪。"

---

## 0. 结论先行

| 问题 | 结论 |
|---|---|
| 硬件够不够 | **够**。板上 YT8531C 千兆 PHY + RGMII 全部引脚在 Bank 14，当前设计一条都没用（`constr/enc_top.xdc` 无任何 `eth_*`）；ADC 在 Bank 16，互不冲突 |
| 双通道 50 MSPS 原始流能否连续传 | **不能**。2×12 bit×50 MSPS = **1.2 Gbps** > 千兆可用 ~950 Mbps。必须"缓冲后突发上传"或"降速/单通道" |
| 推荐做法 | **抓包-回放（scope capture）**：BRAM 环形缓冲存 28,672 个双通道样点（0.57 ms @50 MSPS），触发后经 UDP 突发上传，耗时 ~1.4 ms，零丢包 |
| 能提升多少 | 时间分辨率 100 µs → **20 ns（5000×）**；1 kHz 信号每周期 10 点 → **50,000 点**；波形从"等效采样"变成**真实采样** |
| 工作量 | 全功能 9–12 个工作日；最小可演示 5–6 天（见 §9） |
| 最大风险 | 新增 125 MHz / 200 MHz 时钟域后的**全片时序重收敛**（现 50 MHz 单域 WNS 仅 +0.821 ns） |

**一句话**：B 路线的正确形态不是"把 10 kHz 遥测帧搬上网"，而是"新增一条抓包通道，把 ADC 原始样点成段搬上来，串口遥测原样保留当兜底"。

### 0.1 已定决策（2026-10-18）

| 项 | 决定 |
|---|---|
| 抓包窗口 | **1.15 ms @ 25 MSPS（抽取 2）为默认**；抽取 1/4/8 可选（0.57 / 2.29 / 4.59 ms） |
| 传输方案 | **双通道并存**：现有串口上位机保留不动，新增以太网传输，两者互不干扰 |
| 网络拓扑 | **网线直连 PC 网口 + 固定 IP**（设备 192.168.1.10，PC 192.168.1.100），不做 DHCP/设备发现 |

### 0.2 关键认识：B1 不需要以太网也能交付

28,672 点 × 4 B = 112 KB（线上 448 块 × 264 B = 118,272 B），用**现有 2 Mbaud 串口 + 一条专用批量 dump 命令**回读约 0.66 s
（不是逐寄存器读——那样每次 10 B 开销只换 2 B 数据，会慢 5 倍）。
所以"50 MSPS 原始波形"这个核心价值可以先在**零新增引脚、零新时钟域、零时序风险**的前提下拿到；
以太网随后只是把同一块缓冲的读出从 0.9 s 提到 1.4 ms，并解锁连续流。详见 §9 的 B1/B2 拆分。

---

## 1. 先把物理上限算清（这决定架构）

### 1.1 数据源

| 项 | 值 | 依据 |
|---|---|---|
| ADC | AD9238 双通道 12 bit | `rtl/ad9238_capture.v:9-12` |
| 采样时钟 | 50 MHz（`ad_clk`/`ad_clk2` 由 ODDR 反相输出） | `rtl/ad9238_capture.v:21-29`、`rtl/enc_top.v:139-160` |
| 每拍数据 | CH1 12 bit + CH2 12 bit = 24 bit | `rtl/enc_top.v:88-91`（`ad_ch1_d`/`ad_ch2_d`） |
| 原始速率（双通道） | 50 MSPS × 24 bit = **1.2 Gbps** | — |
| 校正后信号 | `s_cor`/`c_cor` 各 16 bit | `rtl/enc_top.v:454` |
| 片上可用缓冲 | BRAM **0/50 Tile**，1800 Kbit = 225 KB | `deliverables/data/timing/impl_util_v11_2026-10-12.rpt` |

### 1.2 链路上限

| 项 | 值 |
|---|---|
| 千兆线速 | 1000 Mbps（RGMII 125 MHz DDR×4） |
| 1500 B MTU 下应用层上限 | 1472/1538 ≈ **957 Mbps**（含前导/IFG/FCS 开销） |
| 实际持续目标（留余量） | **≤ 700 Mbps**（约 73%），突发可到 ~950 Mbps |
| 9000 B 巨帧 | ~994 Mbps，但要求网卡/系统支持巨帧，不作为默认 |

### 1.3 结论：三种可行模式

| 模式 | 数据率 | 时长 | 适用 |
|---|---|---|---|
| **A 抓包回放**（推荐 MVP） | 突发 160 KB / 次 | 28,672 点 = **1.15 ms @25 MSPS（抽取 2，默认）**；抽取 1 时 0.57 ms @50 MSPS | 看真实波形、测谐波/相位/毛刺 |
| **B 连续流式**（二期） | 25 MSPS 双通道 12 bit 打包 = 600 Mbps | 无限 | 实时滚动显示、长时间录制 |
| **C 长记录**（三期，需 DDR3） | 突发 | 100 ms–秒级 | 低速信号的超长记录 |

> 模式 B 的 600 Mbps 在 Windows 上需要调大 socket 缓冲 + 零拷贝解析，仍有丢包风险；
> 模式 A 每次只传 113 个 UDP 包，**几乎不可能丢**，且丢了可以整段重抓——所以先做 A。

---

## 2. 目标形态（用户视角）

新增一个"**高速抓包**"Tab（与现有 10 kHz 实时波形并存）：

1. 选源：`原始 s/c`（ADC 去偏置后）或 `校正后 s/c`（`sc_correct` 输出）。
2. 选抽取：**默认 2**（25 MSPS / 1.15 ms 窗口）；可选 1 / 4 / 8（50 / 12.5 / 6.25 MSPS）。
3. 选触发：立即 / CH1 上升沿 / CH1 下降沿 / 过零（可设电平、预触发比例）。
4. 点"抓取" → 设备 arm → 等触发 → 抓 N 点 → UDP 回传 → 上位机画图。
5. 结果：时间轴 µs、双通道叠加、李萨如、误差曲线；可导出 CSV / NPY / PNG；可写进记录文件。
6. **双通道并存**：串口遥测与串口控制不中断（命令仍走串口，以太网只做数据通道）；上位机可在"串口 / 网口"之间切换抓包传输，两条链路互不干扰。

---

## 3. 总体架构

```
                     ┌──────────────── 50 MHz 域（现有，不动）────────────────┐
 AD9238 CH1/CH2 ─────►│ ad9238_capture ──► s_raw/c_raw ──► sc_correct ──► s_cor/c_cor
  (12b @50MSPS)       │        │                                │
                     │        └──────────┬─────────────────────┘
                     │               源选择 (raw / corr)
                     │                   ▼
                     │            decim_avg (÷1/2/4/8)  ← 复用 rtl/decim_avg.v
                     │                   ▼
                     │        scope_capture：触发 + 28,672×36b 环形 BRAM
                     │                   │  (写 50 MHz)
                     └───────────────────┼──────────────────────────────────┘
                                         ▼  xpm_fifo_async (50→125 MHz)
                     ┌──────────────── 125 MHz 域（新增）────────────────────┐
                     │  udp_tx：ARP/IPv4/UDP 头 + 样本流 → GMII 8b           │
                     │  eth_tx_mac：前导/FCS/IFG → ODDR → RGMII TXD/TX_CTL   │
                     │  eth_rx_mac：IDDR ← RGMII RXD/RX_CTL（只处理 ARP/ICMP）│
                     │  eth_cfg：0x0700 寄存器组 + PHY 状态                  │
                     └───────────────────┬──────────────────────────────────┘
                                         ▼
                              YT8531C (RGMII + MDIO) ──► RJ45 ──► PC
```

要点：

- **TX 走 125 MHz，RX 只处理 ARP/ICMP**（MVP 阶段不做 UDP 收命令），RX 数据量极小，CDC 简单。
- 抓包缓冲**只在 50 MHz 域写**，读侧经异步 FIFO 进 125 MHz，`enc_top` 现有 50 MHz 逻辑一行不改。
- 命令仍走串口（`uart_spi_bridge` → `reg_file`），**UDP 不承担控制**，避免重传/幂等设计，省 3–5 天。
- **B1 阶段数据也走串口**：`scope_reader` 收到 dump 命令后按 **64 点/块**（256 B 载荷 + 8 B 头/XOR）主动推流，160 KB ≈ 1.0 s；B2 接入后同一 reader 把数据源换成 UDP，`host` 侧接口不变。

---

## 4. RTL 模块划分与资源预算

新增目录 `rtl/eth/`：

| 模块 | 职责 | 估计 LUT/FF | 备注 |
|---|---|---|---|
| `rgmii_if.v` | IDDR/ODDR、IDELAY、三态 MDIO | 200/150 | 结构照抄正点原子例程，别自己发明 |
| `eth_rx_mac.v` | 前导/SFD、FCS 校验、帧长、广播/单播过滤 | 500/400 | 只分流 ARP/ICMP |
| `eth_arp.v` | 收 ARP 请求→回；发 ARP 请求→记对方 MAC | 250/150 | 一条表项即可 |
| `eth_icmp.v` | ping 应答（bring-up 用） | 150/100 | 可选，但强烈建议 |
| `udp_tx.v` | 组 ARP/IP/UDP 头、增量校验和、从 FIFO 取载荷 | 700/500 | 8 bit 数据通路 |
| `eth_tx_mac.v` | 前导、FCS(CRC32)、IFG、ODDR 输出 | 350/250 | — |
| `eth_cfg.v` | 0x0700 寄存器组、链路状态、计数器 | 250/300 | 与 `reg_file.v` 做地址转发 |
| `scope_capture.v` | 源选择、抽取、触发、环形写、读指针 | 350/300 | 40 × RAMB36（推断，不用 IP） |
| `scope_reader.v` | 按段读出（含回绕）、打包 32 bit/样点 | 150/150 | — |
| `prbs7.v` | 测试图案（链路验证） | 50/50 | 上线前必做 |

合计新增：**约 2.9k LUT / 2.3k FF / 42 BRAM / 1 MMCM**。

预算后整片：LUT ≈ 9.3k / 20.8k = **45%**；FF ≈ 6.4k / 41.6k = **15%**；BRAM **42/50 = 84%**（偏紧）；DSP 16/90 不变；IOB +15。

> BRAM 84% 是唯一"卡边"的资源。若 impl 报拥塞，可把抓包深度降到 28 Tile（28,672 点，1.15 ms），或样本改存 12+12 bit（能再省 1/4 的 BRAM）。

---

## 5. 时钟、时序与约束（最大风险区）

### 5.1 时钟方案

| 时钟 | 来源 | 频率 | 用途 |
|---|---|---|---|
| `clk_i` | 板载 50 MHz（V4） | 50 MHz | 现有全部逻辑 + ADC 捕获 + 抓包写 |
| `clk_125` | MMCM（50 MHz 输入，VCO 1000 MHz，M=20/D=8） | 125 MHz | GMII 发送/接收、UDP 组包 |
| `clk_200` | MMCM（50→200，M=16/D=4） | 200 MHz | `IDELAYCTRL` 参考（仅当用 IDELAY） |
| `eth_rxc` | PHY（Y18） | 125 MHz | RGMII 接收；BUFG 后作 RX 域 |

- **TX 时钟用自己的 MMCM，不借 `eth_rxc`**：链路未起时 `eth_rxc` 可能没有，调试期容易"全黑"。
- RX 域的 ARP/ICMP 处理完就握手回 125 MHz 域，不做跨域数据流。
- MMCM 由 50 MHz 驱动 ⇒ `clk_125`/`clk_200` 与 `clk_i` **同源**，但相位不同，跨域仍用异步 FIFO。

### 5.2 约束

```tcl
create_clock -period 8.000 -name eth_rxc [get_ports eth_rxc]
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]   ;# 已有
# MMCM 输出由 create_generated_clock 自动派生（Vivado 会生成）
set_input_delay  -clock eth_rxc -max 2.000 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay  -clock eth_rxc -min 1.000 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_output_delay -clock clk_125  -max 2.000 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock clk_125  -min 1.000 [get_ports {eth_txd[*] eth_tx_ctl}]
set_clock_groups -asynchronous -group [get_clocks eth_rxc] -group [get_clocks {clk_125 clk_200}]
```

（真实数值以正点原子例程 XDC 为准，直接抄；例程在同一块板上验证过。）

### 5.3 风险与回退

| 风险 | 触发条件 | 回退 |
|---|---|---|
| 125 MHz 收敛不了 | WNS < 0 且优化无效 | **降到 100 Mbps（25 MHz RGMII）**，带宽 95 Mbps，仍是串口的 50 倍，完全够抓包 |
| IDELAY/IDELAYCTRL 引入时序问题 | Bank 14 布线拥塞 | 先不用 IDELAY，靠 PHY 内部 RGMII 延时（默认配置即可通），例程已验证 |
| 50 MHz 原有路径被挤坏 | WNS 从 +0.821 变负 | 新逻辑全部加 `KEEP`/流水，抓包读侧独立时钟域；必要时把 `scope_capture` 寄存器化 |
| BRAM 84% 拥塞 | impl 报 `RAMB36` 布局失败 | 深度 40→32 Tile，或改 12 bit 存储 |

**红线**：任何阶段 `All user specified timing constraints are met` 不成立，就停在那一步修，不许带 bug 往下推。

---

## 6. 寄存器映射（bank 0x0700，**每个寄存器 16 bit 对齐、占 2 个字节地址**）

> 原稿按 8 bit/字段紧凑排布，实做时发现 `spi_slave` 的 32 位包格式一次 16 bit 写会在
> `addr` 与 `addr+1` 各产生一个 8 bit 写脉冲（`rtl/spi_slave.v` 的 `P_WR0/P_WR1`），
> 紧凑排布会让写高字节踩掉邻居。**下表是实做版（`rtl/cap_regs.v`），与 RTL 逐字一致。**

| 地址 | 名称 | 说明 | B1 状态 |
|---|---|---|---|
| 0x0700/01 | `MAC[15:0]` | MAC 低 16 位 | 占位 |
| 0x0702/03 | `MAC[31:16]` | MAC 高 16 位 | 占位 |
| 0x0704/05 | `IP[15:0]` | 本机 IP 低 16 位（默认 192.168.1.10） | 占位 |
| 0x0706/07 | `IP[31:16]` | 本机 IP 高 16 位 | 占位 |
| 0x0708/09 | `HOST_IP[15:0]` | 上位机 IP 低 16 位（默认 192.168.1.100） | 占位 |
| 0x070A/0B | `HOST_IP[31:16]` | 上位机 IP 高 16 位 | 占位 |
| 0x070C/0D | `PORT` | 数据口（默认 5000） | 占位 |
| 0x070E/0F | `CTRL` | bit0 使能 | 占位 |
| 0x0710/11 | `ETH_STATUS` | link/速率/ARP 等 | 读 0 |
| 0x0712/13 | `TX_PKT` | 已发 UDP 包数 | 读 0 |
| 0x0714/15 | `TX_DROP` | FIFO 溢出丢弃数 | 读 0 |
| 0x0716/17 | `RX_PKT` | 收到有效帧数 | 读 0 |
| 0x0718/19 | `CAP_SRC` | `[0]` 0=原始 50 MSPS / 1=校正 12.5 MSPS；`[2:1]` 抽取 log2（0..3） | **已实现** |
| 0x071A/1B | `CAP_LEN` | 窗口点数，默认 28,672（=1.15 ms @25 MSPS） | **已实现** |
| 0x071C/1D | `TRIG_CFG` | `[1:0]` 0=立即 1=上升沿 2=下降沿 | **已实现** |
| 0x071E/1F | `TRIG_LEVEL` | 有符号 16 bit 门限 | **已实现** |
| 0x0720/21 | `PRE` | 预触发点数，默认 1024 | **已实现** |
| 0x0722/23 | `CAP_CTRL` | `[0]` arm（W1）`[1]` abort | **已实现** |
| 0x0724/25 | `CAP_STATUS` | `[0]`done `[1]`armed `[2]`trig `[3]`busy `[4]`ovf | **已实现** |
| 0x0726/27 | `TRIG_IDX` | 触发点在窗口内的下标 | **已实现** |
| 0x0728/29 | `SAMP_LO` | 50 MHz 样点计数 `[15:0]` | **已实现** |
| 0x072A/2B | `SAMP_HI` | 样点计数 `[31:16]` | **已实现** |
| 0x072C/2D | `BUILD` | `0x000D` | **已实现** |
| 0x072E/2F | `DUMP_CTRL` | `[0]` start（W1）`[1]` abort | **已实现** |
| 0x0730/31 | `DUMP_STATUS` | `[0]`busy `[1]`done | **已实现** |
| 0x0732/33 | `CAP_LEN_EFF` | 被 `DEPTH` 截断后的实际窗口点数 | **已实现** |
| 0x0734/35 | `BLOCKS_DONE` | 已发块数（16 bit） | **已实现** |

**实现方式（与原稿的差异）**：`rtl/reg_file.v` 加了 `ext_we/ext_addr/ext_wdata/ext_rdata`
四根线，`addr[15:8]==0x07` 时整段转给 `rtl/cap_regs.v`；读 `default` 分支回填 `ext_rdata`。
改动约 15 行，0x00xx–0x06xx 全部行为不变。

**脉冲语义**：`arm/abort/dump_start/dump_abort` 写 1 触发一个 clk 脉冲，读回自然是 0。

---

## 7. 数据报文格式（UDP 载荷）

### 7.1 抓包上传包

```
偏移  长度  内容
0     2     魔数 0xE7 0x5A
2     1     版本/标志：bit0 首包, bit1 末包, bit2 有间隙(overflow), bit[7:4] 源(0 raw/1 corr)
3     1     抽取 log2
4     2     包序号（从 0 递增）
6     2     本包首样点序号（相对抓包起点）
8     4     50 MHz 样点计数值（该包首样点对应的 CAP_SAMPLE_CNT）
12    4     保留
16    ...   样本：每点 4 B = ch1 int16 LE + ch2 int16 LE
```

- 1500 B MTU：UDP 载荷 1472 B → 头部 16 B + **350 个样点**（1400 B）。
- 28,672 点 → 82 个包（81×350 + 322）；每包含首样点序号与包序号，上位机**按序号重组**，缺包直接报"缺第 k 段"并可重抓。
- 抓包结束时设备再发一个 0 样本的"末包"？不需要——`CAP_STATUS.done` 由串口轮询即可；末包标志位也保留。

### 7.2 连续流模式（二期）

同上头部，`flags` 用 bit0/bit1 表示"流开始/流结束"，样点为 12+12 bit 打包（3 B/点），
1500 B MTU → 485 点/包；靠"包序号 + 首样点序号"检测丢包，**不做重传**，丢包在图上标红。

---

## 8. 上位机改造（改动集中在 host/，协议层零改动）

### 8.1 抽象层

新增 `host/transport.py`：

```python
class Transport(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def transact(self, payload: bytes, timeout: float = 0.5, retries: int = 3) -> bytes: ...
    def read_reg(self, addr: int, timeout: float = 0.5) -> int: ...
    def write_reg(self, addr: int, value: int, verify: bool = True) -> None: ...
    def counters(self) -> dict: ...
```

- `SerialTransport`：薄包装现有 `host/link.py:161 SerialWorker`，**行为完全不变**。
- `UdpTransport`：串口仍负责 `transact`（控制），UDP 只负责抓包数据接收（`capture()` 方法）。
  这样 `main_window.py` 里所有 `link.read_reg/write_reg` 调用一行不用改。

### 8.2 抓包流程（`host/capture.py`）

```
write_reg(0x0710, src|decim)          # 源 + 抽取
write_reg(0x0711, n)                  # 点数
write_reg(0x0712, trig_cfg)           # 触发
write_reg(0x0713, level)
write_reg(0x0714, pre)
write_reg(0x0715, 1)                  # arm
轮询 0x0716 bit1 (done)，超时 2 s
读 0x0717/0x0718 取触发点
UDP 收包 → 按 seq/首样点重组 → numpy (N,2) int16
校验：连续、无重复、点数一致
```

> **B1（无以太网）**：流程同上，把最后一步换成"串口批量 dump"——写 0x071C bit0，设备按 64 点/块推流
> （`AA 55 A2 0x10 | seq | n | 4B×64 | XOR`），上位机 `SerialTransport.capture()` 收齐 640 块即完成，
> 对 UI 暴露的接口与 UDP 版完全一致（28,672 点 ≈ 0.66 s）。

- 接收端：`SO_RCVBUF` 设 8–16 MB；`recv_into` 到预分配 bytearray；`np.frombuffer` 零拷贝解析；
  每包只做一次切片，**绝不逐点 Python 循环**（28,672 点 × 4 B，纯 numpy 解析 <1 ms）。
- 绘图：全分辨率只在"抓包视图"里画（28,672 点是 pyqtgraph 的舒适区）；实时 10 kHz 视图仍抽稀到 ~1500 点。
- 导出：`.npy`（原始 int16）、CSV（时间 µs + 两通道）、PNG；记录文件增加 `capture_*.bin + .json` 边车（率、点数、触发、时间戳）。
- 连接条加"串口 / 网口"下拉 + IP 输入（`host/main_window.py` 连接区）；`host/ports.py` 加默认 IP 常量。

### 8.3 网络配置（用户体验的关键）

- 设备默认 IP `192.168.1.10/24`，上位机默认 `192.168.1.100/24`（或让用户填）。
- **MVP 不做 DHCP/设备发现**，只做"IP 输入框 + 连通性检测（ping）"；二期再加 UDP 广播发现。
- 防火墙：首次运行可能弹窗；文档里写清"允许专用网络"。控制仍走串口，即使网络没通也能改 IP。

**已实现的上位机入口（2026-10-18）**

| 入口 | 用法 | 说明 |
|---|---|---|
| GUI「抓包」页 | 「通道」下拉选 **串口回读 / 网口 UDP** | 串口连上即可；网口只是数据通道，配置寄存器仍走串口 |
| 命令行 | `python tools/cap_dump.py --udp --udp-bind 192.168.1.100` | 加 `--csv/--npy/--png` 直接存文件 |
| 库 | `udp_capture.UdpCapture(port=5000, bind_ip="192.168.1.100")` | `capture_once(worker, ...)` 返回同一个 `CaptureResult` |
| 离线自检 | `python host/selftest_udp.py` | 回环发假包，不需要板子/网线 |

丢包处理：UDP 无重传，缺的包**按 seq 归位后补 0**，并在 `CaptureResult.missing` 里记下块号；
GUI 摘要行会显示"缺 N 包"。要零丢包请用串口 dump（带 XOR 校验，但慢 300 倍）。

---

## 9. 分阶段实施计划（含 2026-11-04 截止日约束）

> 今天 2026-10-18，距交付 17 天。`docs/14` 已明确：以太网属于 D10–D16 的**可选加分项**，
> **D5–D9 的交付物（报告/复现/录屏）不做会直接扣分**。所以顺序必须是：先锁 D5–D9，再用剩余时间做 B。

**拆分原则：B1 不需要以太网也能交付（见 §0.2）。** 先拿到"50 MSPS 原始波形"这个核心价值，
再决定要不要花剩下的时间做 B2 的传输提速。

| 阶段 | 内容 | 工期 | 出口判据 | 状态（2026-10-18） |
|---|---|---|---|---|
| **B1-1** | `scope_capture`（BRAM + 触发 + 抽取）+ `scope_reader` + 0x0700 寄存器 + **串口批量 dump（0x071C，64 点/块推流）** | 2 天 | 串口 arm → 抓 28,672 点 → ≤1.0 s 回读完整，波形与示波器一致 | **已完成（仿真）**：`tb_scope_chain` 57 checks PASS；回归 `tb_reg_file`/`tb_spi_slave`/`tb_uart_spi_bridge`/`tb_enc_top` 全 PASS |
| **B1-2** | 上位机"抓包"视图（走串口传输）+ 导出 CSV/NPY/PNG | 1–2 天 | 点一下出图；与 10 kHz 实时视图并存；可写进记录文件 | **已完成**：`host/selftest_capture.py` 25 checks PASS；7 页界面接线 + StubWorker 全链路冒烟 PASS |
| **B2-1** | 抄例程：`rtl/eth/` 骨架 + XDC + MMCM + PHY 复位；UDP 回环 | 2 天 | PC ping 通；UDP 回环 RTT < 1 ms | 未开始 |
| **B2-2** | `udp_tx` + `eth_tx_mac` + PRBS 图案；测吞吐/丢包 | 2 天 | 60 s 连续发 600 Mbps，丢包 < 0.01% | 未开始 |
| **B2-3** | 抓包数据改走 UDP（`scope_reader` → 异步 FIFO → `udp_tx`），串口回读保留 | 2 天 | 单次上传 < 5 ms，113 包零丢失 | 未开始 |
| **B2-4** | 联调、长稳（1000 次抓取）、资源/时序归档、报告章节 | 1–2 天 | 1000 次 0 错；WNS ≥ 0；报告有表 | 未开始 |

**B1 实际实现与本表的差异（记录，避免下次照旧猜）**：

- `scope_reader` 没有单独成模块：读口直接做在 `scope_capture.v`（`rd_addr/rd_en/rd_data`，同步读 1 拍延迟），由 `scope_dump.v` 驱动 —— 少一个模块、少一层握手。
- 0x0700 段没有塞进 `reg_file.v` 的 case，而是独立成 `cap_regs.v`，由 `reg_file` 的 `ext_we/ext_addr/ext_wdata/ext_rdata` 端口转发（地址高字节 `0x07`）。理由：`reg_file.v` 已经 600 行，再加 40 个寄存器会淹没原来的时序控制逻辑。
- dump 块头是 **7 字节**（`AA 55 A2 10 | blk_lo blk_hi | n`），不是 6 字节；块尾 XOR 覆盖块头 + 全部载荷，共 8 + 4n 字节。
- 上位机端 `SerialWorker` 必须显式进"dump 模式"再解析，不能靠 `AA 55` 猜（遥测帧 byte2/3 是角度低/高字节，可能撞 `A2 10`）。

**排期建议**：

- 11-04 前只剩 **5–7 天**：只做 B1。交付"50 MSPS 原始波形"已是明确加分点，且不动时序、不碰网络，几乎零风险。
- 还有 **10 天以上**：B1 → B2-1 → B2-2 → B2-3，B2-4 与交付物并行。
- **止损线**：B2-1 第三天还不通，立刻停在 B1，把以太网写成"已验证可行性、未及集成"（`docs/14` 的证据链足以支撑这句话）。

**B1 的最小演示版（2 天）**：只做单通道、16k 点、立即触发、串口回读；
仍然给得出"20 ns 时间分辨率、每周期 5 万点"的对比数字，报告里足够。

---

## 10. 验收标准与测试方法

### 10.1 功能验收

**B1（串口 dump，已完成部分只列可离线验证的项）**

- [x] 抓包：双通道 × 28,672 点；抽取 1/2/4/8；触发（立即/上升沿/下降沿）与预触发窗口在仿真里逐点比对通过（`tb_scope_chain` 57 checks）。
- [x] 寄存器：0x0700 段默认值、写读、状态位在仿真里验证（`cap_regs` 用例 A）。
- [x] 块协议：`AA 55 A2 10|blk_lo blk_hi|n|n×4B|XOR`，上位机解析器对"分片到达 / 夹杂命令应答 / 尾部残帧"都能正确归位（`host/selftest_capture.py` 25 checks）。
- [x] 导出：CSV（`t_us,s,c`）、NPY（(N,2) int16）、PNG 三条路径可用。
- [ ] **上板**：28,672 点 ≤ 1.0 s 回读完成（理论 118,272 B ÷ 180 kB/s ≈ 0.66 s）；回读期间 10 kHz 遥测不丢帧。
- [ ] 与示波器交叉验证：同一路 1 kHz 正弦，幅值误差 < 1%，与 `s_cor` 数值一致。

**B2（以太网，未开始）**

- [ ] link up，1000 Mbps 全双工；`ping` 稳定（1000 包 0 丢）。
- [ ] 上传：单次 < 5 ms；113 包零丢失；故意丢一个包能被检测并重抓。
- [ ] 串口遥测在抓包期间不中断、不丢帧。
- [ ] **双通道一致性**：同一窗口分别走串口 dump 与 UDP，逐点一致。

### 10.2 性能与稳定性

- [ ] PRBS7 连续 60 s @600 Mbps：误码 0，丢包 < 0.01%。
- [ ] 1000 次连续抓包：0 失败、0 卡死、内存不增长。
- [ ] 30 min 连续流（二期）：无崩溃，`TX_DROP_CNT` 不增长。

### 10.3 数据归档（报告要用）

- `report_timing_summary`（WNS/WHS/TNS/THS，分时钟域）
- `report_utilization`（LUT/FF/BRAM/DSP/IOB）
- 吞吐/丢包/RTT 实测表，与 2 Mbaud 串口基线并列对比
- 同一信号的"10 kHz 串口波形"与"50 MSPS 抓包波形"对比图（这张图就是加分点）

---

## 11. 风险登记

| # | 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|---|
| 1 | 125 MHz 时序收不收敛 | 中 | 高 | 先抄例程结构；失败退 100 Mbps（25 MHz） |
| 2 | PHY 不 link / RGMII 延时不对 | 中 | 高 | 抄例程 XDC + IDELAY；先用 ping 验证，不上板就停 |
| 3 | BRAM 84% 拥塞 | 中 | 中 | 深度 40→32，或 12 bit 存储 |
| 4 | 上位机 UDP 突发丢包 | 低 | 中 | 抓包模式本身低负载；缺包重传/重抓 |
| 5 | 挤占交付物时间 | **高** | **高** | 严格按 §9 顺序；P0 第三天不通就止损，回到 UART 方案 |
| 6 | 网络配置让演示变复杂 | 中 | 中 | 固定 IP + 串口兜底；演示机预先配好 |

---

## 12. 明确不做（防止范围膨胀）

1. **不在 RTL 里做 TCP**（无重传需求，抓包模式天然幂等）。
2. **不做双通道 50 MSPS 连续流**（1.2 Gbps 物理上过不去）。
3. **不把 10 kHz 遥测帧搬进 UDP**——那条链路已经够用，搬过去只会制造"两条链路数据不一致"的解释成本。
4. **MVP 不做设备发现/DHCP**（二期）。
5. **11-04 前不做 DDR3/MIG**（秒级长记录留到赛后）。
6. 不改 `uart_scope` 帧格式；不动现有 50 MHz 逻辑的时序结构。

---

## 13. 文档变更清单（按本工程约定：先改 SPEC，再改代码）

| 文件 | 变更 |
|---|---|
| `rtl/SPEC_interface_contract.md` | 0.3 时钟域加 125/200 MHz 与 eth_rxc；1.14 起新增 `rgmii_if`/`eth_rx_mac`/`eth_arp`/`eth_icmp`/`udp_tx`/`eth_tx_mac`/`eth_cfg`/`scope_capture`/`scope_reader`/`prbs7` 的端口契约；2.1 顶层端口加 `eth_*`；变更记录 v1.2 |
| `docs/10_host_requirements.md` | §6 "网口不做"改为"v1.1：以太网抓包为可选通道（B 路线）"，明确不影响 v1 验收项 |
| `docs/14_dual_channel_feasibility.md` | 追加"已选定 B 路线"与本文链接 |
| `docs/DEV_STATUS.md` | 新增章节记录以太网开发过程（按现有格式） |
| `constr/enc_top.xdc` | 新增 eth 引脚 + 时钟 + IO 延时约束（或并入现有文件） |

---

## 14. 决策记录（2026-10-18 已定）

| 项 | 决定 | 影响 |
|---|---|---|
| 抓包窗口 | **1.15 ms @ 25 MSPS（抽取 2）** 为默认；可选抽取 1/4/8（0.57 / 2.29 / 4.59 ms） | BRAM 配置不变（28 × RAMB36），不用 DDR3 |
| 传输方案 | **双通道并存**：现有串口上位机保留，新增以太网传输，两者互不干扰 | 上位机加 `Transport` 抽象，`SerialTransport` 行为不变；B1 可先只做串口回读 |
| 网络拓扑 | **网线直连 PC 网口 + 固定 IP**（设备 192.168.1.10 / PC 192.168.1.100） | 不做 DHCP/设备发现；网络没通也能用串口改 IP |

**实施记录（追加）**

| 日期 | 事项 | 结果 |
|---|---|---|
| 2026-10-18 | B1 立项，方案文档 v1.0 | 用户选 B 路线、1.64 ms 窗口、双通道并存、固定 IP |
| 2026-10-18 | B1-1 RTL：`cap_regs.v` / `scope_capture.v` / `scope_dump.v` + `reg_file` 扩展总线 + `uart_spi_bridge` 第三路 TX | `tb_scope_chain` 57 checks PASS；四项回归全 PASS；固件 ID 0x000C→**0x000D** |
| 2026-10-18 | B1-2 上位机：`capture.py` / `panel_capture.py` / `link.py` dump 模式 / `tools/cap_dump.py` | `selftest_capture.py` 25 checks PASS；界面 7 页接线完成 |
| 2026-10-18 | **深度改 32768**（40960 会被 Vivado 向上取整到 65536 = 64 个 RAMB36，超限） | 窗口 1.31 ms @25 MSPS / 0.66 ms @50 MSPS；串口回读 0.75 s |
| 2026-10-18 | B2-1 RTL：`rtl/eth/` 七个模块 + `enc_top` 15 根以太网引脚 + XDC | `tb_eth_udp` 58 checks PASS；综合 LUT 47.8%、BRAM 66% |
| 2026-10-18 | B2-2 时序：CDC/长链逐条修（`pkt_first` 累加、格雷码计数器、配置位两级同步、S_PRE 打拍） | 综合 WNS −5.998 → **−1.12**；残余 RGMII I/O 与 `abz_gen` 一条 CE |
| 2026-10-18 | B2-3/B2-4 上位机：`udp_capture.py` / `selftest_udp.py` / 抓包页「通道」选择 | `selftest_udp.py` 26 checks PASS；串口与网口共用同一套 GUI |
| 2026-10-19 | B2 时序收敛（IP 校验和拆两拍、RX 输入延时改 `-min 3.6/-max 4.5`、`tx_drop` 跨域修正） | **WNS +0.167 / WHS +0.058，0 failing endpoints**；DRC 0 错误；位流 1.44 MB |
| 2026-10-19 | 全量 RTL 回归（23 个 tb，含 `tb_enc_top` 184 s、`tb_eth_udp`） | **PASS 23 / 23** |
| 2026-10-22 | **深度改 28672**（`scope_capture` 显式拆 16K+8K+4K 三 bank，28×RAMB36；32768 与屏+以太网共存需 50.5 片，超限） | 窗口 1.147 ms @25 MSPS / 0.573 ms @50 MSPS；串口回读 448 块 × 264 B = 118,272 B ≈ 0.66 s；UDP 82 包 |
| 2026-10-22 | **v60 合并顶层补出 eth 端口**（v59 及之前 `enc_top` 的 `eth_*` 全部悬空）+ XDC 生成器接入 `constr/enc_top_eth.xdc` 第三来源 | 107 球 0 冲突；`create_clock eth_rxc_clk`、RGMII 输入/输出延时、时钟组全部进 `constr/enc_top_disp.xdc` |
| 2026-10-22 | **上板首日（v60 首次烧板）**：串口 / 寄存器 / 采集通过（`0x071A=28672`、`0x0724=0x0505`、`0x0728=0x7000`）；发现并修复「写 `0x072E` 后 dump 不启动」——`dump_start` 单拍被 `scope_hold` 门控吞掉，`enc_top` 改为 `dump_req` 锁存后再发单拍，主机不再因写应答缺失直接判失败；重建 v60 | WNS +0.316 / WHS +0.038、LUT 16,381、位流 1,660,693 B，27 台回归全过；**以太网未验收**（PC 网口 LinkSpeed 0、RJ45 未接）：接好后跑 `tools/board_eth_check.py`，只验串口 dump 用 `tools/board_dump_test.py` |
| 2026-10-22 | 新增 `sim/tb_dump_start.v` 后仿真又抓出**第二个 dump 缺陷（死锁）**：`scope_dump.line_idle` 接的是 `scope_idle && !br_scope_hold`，而 `br_scope_hold = tx_hold \| dump_busy` —— dump 自己一 busy 就把 `line_idle` 拉死，`S_DLY` 永远等不到，表现为「启动后卡住、一块不发」 | 修法：`uart_spi_bridge` 新增 `tx_hold` 输出，`enc_top` 改 `line_idle = scope_idle_w && !br_tx_hold`；回归升到 **28/28 PASS** |
| 2026-10-22 | TB 升级为线上字节级后抓出**第三个 dump 缺陷（末字节被截断）**：`scope_dump` 的 `wire ack = req_pend && !sending` 在发送器刚装载 `sh` 那一拍就成立（`sending` 仍为 0），状态机提前收尾 → 块尾 XOR 字节刚开始发 `busy` 就落、UART 切回遥测。主机两处都校验块 XOR，真机上每帧 dump 最后一字节必错 | 修法：`ack` 改停止位结束判据（`sending && bit_idx==9 && baud_cnt==BAUD_DIV-1`）；`tb_dump_start` 升到 **18 checks**（块头/块号/点数/263 B XOR 全对齐线上字节）；第三次重建 v60：**WNS +0.228 / WHS +0.036、LUT 16,372、位流 1,640,209 B**，28/28 PASS |
| 2026-10-19 | 交付归档：位流 enc_top_b2_eth_2026-10-19.bit + 三份实现报告 | 1,439,208 B；impl_eth.tcl 已收进 tools/ |
| 待办 | 上板实测（B1 串口 dump + B2 网口）；用 IDELAY 抽头替换 RX 输入延时的经验值 | 见 §15 联调步骤 |

---

## 15. 上板联调步骤（B2，按这个顺序做）

前提：位流里 `RTL_BUILD_ID = 0x000D`，`0x072C` 读回也应是 `0x000D`。

> **先确认烧的是 v60 位流**：`_impl_v60/enc_top_disp.bit`（配 `_prog_v60.tcl`）。
> v59 及更早的合并位流（`_impl_v58/enc_top_disp.bit`）里 `disp/enc_top_disp.v`
> **没有 `eth_*` 端口**，`enc_top` 的以太网口全部悬空 —— 那种位流上 ping 永远不通，
> 跟 PHY  strap、网线、PC 防火墙都无关，别在那里浪费时间。
> 判断方法：`report_io` 应是 **107** 个端口（94 屏 + 13 eth）；v59 只有 94 个。

> **想一条命令跑完 15.1–15.3**：
> `python tools/board_eth_check.py --port COM3 --out cap_v60.npy`
> 它依次做 ping → `arp -a` 查 MAC → 串口读 `0x0000`/`0x0700` → 读 `0x0732` → UDP 抓一窗，
> 每步打 `PASS/FAIL`，最后给 `SUMMARY`；`--skip-net` 可只测串口+UDP。
> 失败时再按下面三小节逐项拆开查。

### 15.1 先确认"网络这一侧"通了

1. 网线**直连** PC 网口（不要经过路由器/交换机，先排除 DHCP 与中间设备）。
2. PC 网卡设静态 IP `192.168.1.100 / 255.255.255.0`，网关留空。
3. 上电后 `ping 192.168.1.10`：
   - 通 → `eth_rx_mac`、`eth_reply` 的 ARP/ICMP、`eth_tx_mac` 全链路都对；
   - 不通 → 先看 `0x0710`（`ETH_STATUS`）：`bit0` ARP 应答过、`bit1` ICMP 应答过、
     `bit2` 已学到主机 MAC。三个都是 0 说明一个包都没收到（PHY 没起来 / 链路不是千兆）。
4. `ping` 通之后，`arp -a` 里能看到 `192.168.1.10` 与板子的 MAC `02:00:00:00:00:01`。

### 15.2 再确认"抓包这一侧"通了（先用串口回读，排除网络变量）

```powershell
python tools/cap_dump.py --src raw --dec 1 --trig now --csv cap.csv
```

拿到 28672 点、`cap.csv` 第一行是 `t_us,s,c`，说明 `scope_capture` + `scope_dump` 都对。
**这一步不通就不要试以太网** —— 网络路径只是在同一份数据外面套了一层 UDP。

### 15.3 最后试以太网回读

```powershell
python tools/cap_dump.py --udp --udp-bind 192.168.1.100 --src raw --dec 1 --csv cap_udp.csv
```

预期：< 100 ms 返回（对比串口约 0.66 s），摘要行没有"缺 N 包"。
若报"没收到任何抓包 UDP 包"，按顺序查：
1. 防火墙是否放行 UDP 5000（专用网络）；
2. `--udp-bind` 是否填了 PC 那块网口的 IP；
3. `0x0738`（`UDP_STATUS`）读完 `done` 是否置位、`0x073A`（`UDP_PKTS`）是否 > 0
   —— 包发出去了但 PC 没收到，问题在 PC 侧（防火墙/绑定地址）。

### 15.4 已知会踩的两个坑

- **链路不是千兆**：`rgmii_if` 按 1000 Mbps 的 DDR 时序拆半字节。链路协商到 100 Mbps 时
  数据全是错的（但 ping 可能还能通，因为 RX 用的仍是 RXC）。用 `ethtool`（Linux）或网卡
  状态页确认"1.0 Gbps 全双工"。
- **RX 采样点（上板最大的不确定项）**：当前 `USE_IDELAY=0`，靠 PHY 内部延时；
  `constr/enc_top_eth.xdc` 里的 `-min 3.6 / -max 4.5` 是**经验值**，不是实测值
  （`eth_rx_mac` 也只做过行为级验证）。若 `0x0716` RX_PKT 在涨但 UDP 一个包都不来，
  按这个顺序试：
  1. 把 `eth_top` 例化改成 `USE_IDELAY(1)`（`eth_top.v` 的参数），`IDELAY_VAL` 从 8
     开始以 4 为步长扫 0..31，每改一次重新出位流；
  2. 同时改 `constr/enc_top_eth.xdc` 的 RX `-min/-max`（按 IDELAY_VAL×78 ps 折算），
     然后**必须重跑** `python tools/gen_merged_xdc.py` —— 合并顶层读的是生成出来的
     `constr/enc_top_disp.xdc`，直接改生成文件会在下次生成时被覆盖。

### 15.6 上板实录（2026-10-22 晚，v61）

上板第一天（v60）遇到"`RX_CLK_CNT` 在涨、`RX_DV` 也在涨，但完整帧恒 0"。按下面顺序查下来，
最后是**三个独立缺陷**叠在一起：

1. **RGMII 引脚顺序整体反了**（`constr/enc_top_eth.xdc`）。厂商口径见
   `docs/ATK_board_digest.md:333-342`：`eth_rxd[0..3] = W17/V17/AB20/AA19`、
   `eth_txd[0..3] = R14/P14/U18/U17`。反序的后果不是"完全收不到"，而是字节被重新
   拼位：前导码 0x55 读成 0xAA（位反转）、广播载荷 0xA5 读回 0x5A（半字节翻转），
   SFD 0xD5→0xAB 永不匹配，所以 `RX_PKT=0`、`RX_ERR=0`、`RX_DV` 照涨。
   判定手段：`0x075A/0x075C` 每帧第 5..8 字节快照 + 广播 0xA5 载荷回读。
2. **ICMP 应答 IP 校验和错**（`rtl/eth/eth_reply.v`）。`w_dst` 取成 `fbuf[30..33]`
   （请求的**目的**地址 = 本机），应取 `fbuf[26..29]`（请求的**源** = 主机）。
   校验和恒差 0x005A，PC 收到帧但全丢 —— 表现是 `TX_PKT` 在涨、`ping` 全超时。
   `sim/tb_icmp_reply.v` 逐字节复算 IP/ICMP 校验和才抓到。
3. **连续流 `MAX_PTS` 大于 FIFO 深度**（`rtl/eth/eth_top.v`）。FIFO `AW=8`（256），
   启动判据 `fifo_rd_level >= MAX_PTS+32 = 382`，永远不成立 → `pkts=0`、
   `drop` 疯涨、`lag` 卡住。改成 `MAX_PTS=200`（232 ≤ 256）。

RX 采样路径也顺手做实了：`rtl/eth/rgmii_if.v` 改成 **BUFIO 采样 + 5×IDELAYE2
（VAR_LOAD）+ IDELAYCTRL(REFCLK=200 MHz)**，抽头/就绪/调试字节都能从 0x0750 段读回，
不用为一个 tap 值重新出位流。

**接线与配置**（每次上板照抄）：

```powershell
# PC 网口设 192.168.1.100/24（板子固定 192.168.1.10、MAC 02:00:00:00:00:01）
netsh interface ip set address name="以太网" static 192.168.1.100 255.255.255.0
python tools\gen_merged_xdc.py          # 改过 constr/enc_top_eth.xdc 之后必须重跑
# 出位流：_impl_v61.tcl；烧写：_prog_v61.tcl（判成功只看 .bit/*.rpt 时间戳，
#   bitgen 之后脚本有时会挂在 get_timing_paths）
ping -S 192.168.1.100 192.168.1.10
python tools\board_dump_test.py --port COM6          # 串口 dump 448 块
python tools\cap_dump.py --udp --udp-port 5010 --len 28672 --npy cap.npy
```

**注意**：本机 UDP 5000 被 `lkcitdl`（Vivado 许可证服务）占用且不能杀，所以板子的
`0x070C`（目的端口）要改成 **5010**，主机监听也用 5010；复位后该寄存器回到 5000，
每次重新烧写都要重设。

### 15.7 连续流（B3）已通过：缺陷 #33 帧长 + #34 端口字节序

- 现象串：板端 `pkts` 稳增、网卡字节在涨，但主机 socket 一包收不到；同端口抓包路径 82/82 正常。
- **#33 帧长**：`stream_tx` 每点插入 1 拍 `S_NEXT`（`tx_valid=0`），`eth_tx_mac` 断流补 0
  到 2000 B 才收尾 ⇒ 网卡按 **1369 B/包**计数（`ping -l 32` 标定 74 B/包 = 帧长），
  IP 头却写 844。改成 `pbuf` 整包缓冲、`S_HDR` + `S_DATA` 连续发，帧内 `tx_valid` 不断；
  网卡回到 **858.0 B/包**，`tb_stream_tx` 加 `no_tx_gap_in_frame` 哨兵（260 checks）。
- **#34 端口字节序**：UDP 头 34/35 是**源**端口、36/37 是**目的**端口，`stream_tx` 写反，
  每个包都发到主机 5000（正好是 `lkcitdl`）。`pktmon` 抓包实证
  `192.168.1.10.47234 > 192.168.1.100.5000: UDP, length 816`；对调后主机正常收包。
- **30 s 长稳**：板端 1,875,512 包、`drop` 0、`lag` 0；主机收 1,874,985 包（99.97%）、
  有效 7.6 MSPS。命令：`python tools/stream_longrun.py --port 47234 --dur 30`（绑定 47234，设备 `0x070C` 同端口）。
- 排查工具：`pktmon filter add -p 47234` + `pktmon etl2txt`（需管理员），比在 RTL 里
  猜字段快得多；调试寄存器 0x0760–0x076E 仍在，可看每帧快照（帧长/IP 长/源端口/MAC/校验和/目的 IP）。

### 15.8 上位机切换与使用指南

抓包页的「通道」下拉现在直接对应三种数据通路，切换只改数据来源、参数与寄存器接口一致：

| 通道 | 数据路径 | 一次传输 | 耗时 |
|---|---|---|---|
| 串口回读（默认） | UART 2 Mbaud | 28672 点 / 448 块 | ≈0.66 s |
| 网口 UDP | 千兆 UDP，82 包 | 28672 点整窗 | ≈2 ms |
| 网口连续流 | 千兆 UDP，设备不停发 | 滚动最近 1024 点 | 实时 |

切换路径已做顺：端口自动选（5000 被 `lkcitdl` 占用就顺延）、开抓/开流前自动 ping 让板子学到
主机 MAC（`0x0710 bit2`）、网口抓包缺块自动重试一次；抓包页新增 **「网络自检」** 与
**「使用指南」** 两个按钮。

完整操作步骤、常见问题与命令行等价操作见 **`docs/22_ethernet_host_guide.md`**。

## 15.9 明日上板验收（一页清单）

完整的接线、烧写、四个通道、10 分钟长稳、GUI 浸泡与结果记录表见
**`docs/24_board_acceptance_morning.md`**。本文只留一句话：

> 烧 `_impl_v61/enc_top_disp.bit`（1,694,149 B @2026-10-22 21:08:15）→ 开第十八次交付包的
> `host_app.exe` → 自检 → 串口/UDP 各抓一枪 → 连续流 10 分钟 → `gui_soak.py` 一轮 → 填表。

