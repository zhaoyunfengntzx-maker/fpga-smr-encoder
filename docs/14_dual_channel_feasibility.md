# Dual-Channel Host Link Feasibility (UART / Gigabit Ethernet) — v2

> v2 修订说明：v1（`docs/13_双通道上位机可行性分析.md`，已删除）是在**没有读竞赛选题指南**的情况下写的。
> 这一次按用户要求，通读了 `【正点原子】达芬奇-lite之FPGA开发指南V1.0(1).pdf`（915 页）与
> `全国大学生嵌入式芯片与系统设计竞赛'2026_FPGA_track_proposal_guide_AMD.pdf`（28 页），
> 分析结论有 **4 处实质修订**，见 §2。
>
> 本文件按竞赛命名要求改为纯英文文件名（见 §5）：
> 竞赛指南要求「仓库内所有目录名与文件名须使用纯英文（小写字母、数字、下划线或连字符）」。
>
> 证据口径：`ATK_GUIDE.txt:行号` 指 `_tools/txt/ATK_GUIDE.txt`（该 PDF 的全文提取缓存，页码与 PDF 对应）；
> `COMP_GUIDE_2026.txt:行号` 指 `_tools/txt/COMP_GUIDE_2026.txt`（选题指南全文提取）。

---

## 0. 结论（v2）

> **队伍定位（已确认）**：报名 **初级组（自主选题赛道 3.3）**，器件 `xc7a35tfgg484-2` 在范围内；
> **作品提交截止 `2026-11-04 18:00`**（用户确认，指南未给日期）。
> **剩余工期：从 `2026-10-15` 起算仅 `20.8 天`（不足 3 周）** —— 全部排期按这个尺度，见 §7。

| 问题 | v2 判定 | 与 v1 相比 |
|---|---|---|
| 上位机做"串口/以太网二选一" | ✅ 可行，改动集中在 `host/` 新抽象层 | 不变 |
| 板上有千兆以太网硬件 | ✅ PHY = YT8531C，RGMII + MDIO，RJ45 = HR911131A（自带变压器） | 不变 |
| **现在能用以太网吗** | ❌ 现行位流里**一条以太网约束都没有**（75 条 `PACKAGE_PIN` 无任何 `eth_*`） | 不变 |
| **下位机以太网的真实工作量** | ✅ **比 v1 估计的乐观得多**：正点原子官方例程已给出可借用的 RGMII 层 + ARP/UDP 层，**且例程完全不用以太网 MAC IP、也不写 `set_input_delay`** ⇒ 不存在 v1 担心的"规则不许用 IP"风险 | ★ **修订 1（重大）** |
| 换以太网能否解决"波形帧率低" | ⚠️ 只能解决"传输"，**10 kSa/s 是 RTL 常数** | 不变 |
| 竞赛视角值不值得做 | ⚠️ **只有 20/100 的权重沾边**，且拿不到"创新性"那 30 分；另有 **3 项硬合规缺口**（见 §5） | ★ **修订 4（新增）** |
| PHY 的 25 MHz 参考时钟来源 | ✅ **实际上不需要 FPGA 提供**：FPGA↔PHY 的连接框图里唯一时钟线是 `ETH_TXC`，不存在"25 MHz 送 PHY"的引脚；TX 时钟还另有来源（见 §2 修订 1 第 4 条） | ★ 修订 2（已闭环） |
| 三条待确认项（FIFO IP / TX 时钟 / 引脚 Bank） | ✅ FIFO 确认是 IP；✅ **15 个以太网信号全在 Bank 14**（ADC 在 Bank 16，无冲突）；⚠️ TX 时钟推到唯一自洽解释、仍待读源码 | ★ 见 §5.5、§8 |

---

## 1. 竞赛指南带来的硬约束（新增）

### 1.1 赛道与资格

| 项 | 内容 | 证据 |
|---|---|---|
| 赛道 | **3.3 自主选题赛道（初级组）** | `COMP_GUIDE_2026.txt:746` |
| 初级组资格 | 大学**一至三年级**在读本科生 | `COMP_GUIDE_2026.txt:754` |
| 初级组器件范围 | 可使用 **AMD 7 Series FPGA**、Zynq-7000 SoC、UltraScale 或 UltraScale+ | `COMP_GUIDE_2026.txt:756-758` |
| 本工程器件 | **xc7a35tfgg484-2**（Artix-7）⇒ **在范围内** ✅ | `docs/LCD_touch_test_readme.md:281` |
| 考察侧重 | **逻辑设计、状态机、时序约束、接口协议等基本 FPGA 设计能力** | `COMP_GUIDE_2026.txt:759-762` |
| 队伍含更高学历队员则归高级组 | 高级组器件不限 | `COMP_GUIDE_2026.txt:771` |

### 1.2 评分权重（初级组 = 高级组同一套）

| 评测项 | 权重 | 证据 |
|---|---|---|
| **创新性与应用价值** | **30** | `COMP_GUIDE_2026.txt:881` |
| **性能与资源优化效果** | **20** | `COMP_GUIDE_2026.txt:882` |
| 功能正确性与设计完整性 | 20 | `COMP_GUIDE_2026.txt:883` |
| **大模型协作与技能包** | **15** | `COMP_GUIDE_2026.txt:884` |
| 文档质量与可复现性 | 15 | `COMP_GUIDE_2026.txt:885` |
| 合计 | 100 | `COMP_GUIDE_2026.txt:886` |

⇒ **以太网/双通道能加分的格子只有"性能与资源优化效果（20）"的一部分**（提供"与基线的对比"、
"持续吞吐率"这类可测量数据）。它**动不了**权重最高的"创新性与应用价值（30）"——
那一项属于"用 SMR 磁阻传感器 + FPGA 做高精度细分磁编码器、对标 专用细分 ASIC"这个选题本身。
（v1 没有这条口径，所以低估了机会成本。）

### 1.3 竞赛明确鼓励的东西（用于校准优先级）

- 优化目标里明写「**在目标器件上取得可测量的性能表现，并给出与基线的对比**」「**合理使用片上资源，避免以显著的资源代价换取有限的性能收益**」「保证工程可由他人从零复现」——`COMP_GUIDE_2026.txt:821-825`。
- 提交物要求「**综合与实现报告，含资源占用、时钟频率与关键性能指标**」——`COMP_GUIDE_2026.txt:836`。
- **大模型协作记录**是必交的：「须提交体现大模型协作过程的交互记录，含提示词、模型回答与自我纠错轨迹」——`COMP_GUIDE_2026.txt:807-808`；报告里还要有「大模型协作记录：提示词、模型回答、自我纠错轨迹、智能体工作流设计（如有）」——`COMP_GUIDE_2026.txt:857`。
- **技能包（Skill）**是必交的：「须将协作过程中沉淀的可复用经验提炼为技能包（Skill），随作品一并提交」——`COMP_GUIDE_2026.txt:809`；`skill/` 目录要用 README 写清「适用范围、使用方法与失效条件」，评价标准是「一支陌生队伍拿到该目录，能否直接用在自己的题目上」——`COMP_GUIDE_2026.txt:839-849`。
- **工具版本**：Vivado / Vitis **2026.1（推荐）**或 2025.2 —— `COMP_GUIDE_2026.txt:805`。本工程实测就是 **Vivado 2026.1**（`README.md:93`、`sim/README.md:8`）⇒ **完全吻合，零风险**。
  ⚠️ 但 `rtl/SPEC_interface_contract.md:6` 写的仍是「开发工具：Vivado 2020.2 及以上」，属文档漂移，应改。
- **开源要求**：「所有提交作品**强烈要求**在 GitHub 或 Gitee 上开源，采用允许再分发的开源协议，推荐 MIT 或 Apache-2.0」——`COMP_GUIDE_2026.txt:818-820`。
- **决赛形式**：进入决赛的自主选题队伍要按 AMD 的 PPT 模板做**一页英文 PPT 海报**，A4 彩打带到现场——`COMP_GUIDE_2026.txt:962-965`。
- 赛程：「本赛道**不单独设定赛程**」，一切以大赛官方公布为准（`http://www.fpgachina.cn/`）——`COMP_GUIDE_2026.txt:891-893`。**竞赛指南里没有任何"预选赛日期/实测截止日期"**。

### 1.4 "以太网"在竞赛里的真实位置（重要）

- 在**自主选题赛道**（本队所在赛道），以太网**既不是必须项、也不是加分项**，只是"应用方向不限"下的一个实现选择——`COMP_GUIDE_2026.txt:748-750`、`COMP_GUIDE_2026.txt:778-783`。
- 在**具身智能赛道**（3.2），以太网的地位高得多：FPGA/Zynq 侧必须承担的功能里明列「**10G Ethernet 高速数据传输**」——`COMP_GUIDE_2026.txt:434`；核心必报指标里包含「**AI PC 与 FPGA/Zynq 通信性能**：按通信方式报告**单向延迟或 RTT**，并选择**有效吞吐率、丢包率、错误率、重传率或指令超时率**」——`COMP_GUIDE_2026.txt:551-556`；场景专项指标里还要求「**FPGA 数据处理：输入到输出的处理延迟、像素率、帧率、持续吞吐率，以及目标时钟、时序收敛状态和最差负裕量（WNS）**」——`COMP_GUIDE_2026.txt:561-562`。
  ⚠️ 但具身智能赛道**硬性要求上位机是 AMD Ryzen AI PC**（`COMP_GUIDE_2026.txt:483`、`509`）、FPGA 侧**不能只当串口/USB/GPIO 转接板**（`COMP_GUIDE_2026.txt:511`），且要完成真实物理任务闭环（`COMP_GUIDE_2026.txt:399`）。对本工程（磁编码器测量）**不适用**。
- 初级组**推荐** PYNQ 框架（PS 侧 Python + PL 侧 Overlay），并且「**通用 PYNQ Skill 单独加分**」（换题目、换板卡仍可用）——`COMP_GUIDE_2026.txt:784-799`、`850-851`。
  ⚠️ 本工程是**纯 FPGA（Artix-7，无 PS）**⇒ 拿不到这个 PYNQ 加分项，这是选型时就要认下的取舍（不是错误，因为初级组器件范围明确允许 7 Series FPGA）。

---

### 1.5 官方例程的实测口径（用于对比"它到底做到了什么"）

- **例程本身没有任何吞吐数字**：第 21/22 章全篇无 Mbps / MB/s / 丢包率；全篇唯一速率数字在第 20 章自协商结果「开发板和电脑自协商的通信速率为 1Gbps（1000Mbps）」（`ATK_GUIDE.txt:24122`）。
- 例程任务只是**协议层回环**：「完成以太网 UDP 数据的环回」（`ATK_GUIDE.txt:26674`），且需要**按 KEY0 触发 ARP** 才能通信（`ATK_GUIDE.txt:26374`）。
- 相关常数：接收时钟 125 MHz（`ATK_GUIDE.txt:25193`、`28771`）；`eth_mdc` 为 6.25 MHz（`23498`）；目的 IP 默认 `192.168.1.102`（`26315-26317`）。
- ⇒ **"能通"和"持续吞吐率是多少"是两件事**：竞赛要的是后者（`COMP_GUIDE_2026.txt:551-556`），例程给不了。这反而是本工程可以做出差异的地方——把 RTT / 持续吞吐率 / 丢包率真正测出来。

---

## 2. 相对 v1 的四处修订

### ★ 修订 1：下位机以太网比我 v1 说的乐观得多，而且**不涉及 IP 核授权风险**

v1 我给的第一条待确认是「竞赛规则是否允许用厂商 IP 核 MAC」。
读完成指南：**这个风险不存在**，因为正点原子官方例程本身就是**纯 RTL 手写 RGMII 层 + 手写 ARP/UDP**：

- 顶层例化结构（`ATK_GUIDE.txt:26141-26171`）：
  - `clk_wiz_0 u_clk_wiz_0(.clk_out1(clk_200m), .clk_in1(eth_rxc))` —— **以 PHY 的 `eth_rxc` 作为 MMCM 输入**，输出 200 MHz；
  - `gmii_to_rgmii #(.IDELAY_VALUE(IDELAY_VALUE)) u_gmii_to_rgmii(...)` —— 自己写的 GMII↔RGMII 转换模块，端口 `idelay_clk / gmii_rx_clk / gmii_rx_dv / gmii_rxd / gmii_tx_clk / gmii_tx_en / gmii_txd / rgmii_rxc / rgmii_rx_ctl / rgmii_rxd / rgmii_txc / rgmii_tx_ctl / rgmii_txd`；
  - `arp #(.BOARD_MAC(...), .BOARD_IP(...), .DES_MAC(...), .DES_IP(...)) u_arp(...)` —— **参数化的 MAC/IP 是写在 RTL 里的**（`ATK_GUIDE.txt:26181-26189`）。
- `gmii_to_rgmii` 内部调用的原语（`ATK_GUIDE.txt:24810` 明确写「主要是通过调用 **BUFG、BUFIO、IDDR、IDELAYCTRL 和 IDELAY2** 原语，实现了 RGMII…」）：
  - `IDELAYCTRL IDELAYCTRL_inst(.REFCLK(idelay_clk), ...)` —— 参考时钟 **200 MHz**（`ATK_GUIDE.txt:24899-24901`）；
  - `IDELAYE2 #(.REFCLK_FREQUENCY(200.0) ...)` —— 200 MHz 下**一个 tap = 78 ps**（`ATK_GUIDE.txt:24644`、`24677`、`24907-24910`）；
  - 说明：**A7 系列没有 ODELAYE2 原语**（`ATK_GUIDE.txt:24664`）——XC7A35T 正是 A7，所以发送方向只能靠 ODDR + 时序约束，不能靠 ODELAY 精调。
- 速率：1000 Mbps 时 `eth_txc`/`eth_rxc` 都是 **125 MHz**，DDR 双沿传 8 bit；100 Mbps 时 25 MHz 单沿（`ATK_GUIDE.txt:24406-24411`、`24423-24429`）。
- **MDIO 完全不用**：「由于 PHY 芯片的内部寄存器在默认配置下也可以正常工作，因此**本次实验没有对 MDIO 接口进行读写操作**，只用到了以太网的 RGMII 接口信号和复位信号」（`ATK_GUIDE.txt:24421-24422`）⇒ `eth_mdc`/`eth_mdio` 可以先不接（省 2 个引脚和一堆 MDIO 时序）。
- **PHY 复位直接借用系统复位**：`assign eth_rst_n = sys_rst_n;`（`ATK_GUIDE.txt:26139`）——注意这与 v1 说的"V18 必须处理"一致，但成本只是 1 行 assign。
- 板级环境要求很低：网线接开发板网口、另一端接电脑网口**或路由器**；下载后 PHY 与电脑网卡**自协商**，Windows 会先显示"未识别的网络"；然后**手动把电脑网卡 IP 改成代码里的目的 IP**（`ATK_GUIDE.txt:26278-26288`、`26305-26314`）⇒ **不需要 DHCP、不需要路由器**。

**对 v1 结论的修正**：下位机以太网从"1–5 周 + IP 授权不确定"降到「**复用官方 RGMII 层 + 自己写 UDP 收发**，估计 3–5 天可通」。
⚠️ 但要注意两条**仍然成立**的代价：
1. 引入了 **125 MHz 域 + 200 MHz 域 + MMCM**，打破本工程"全系统单时钟域、零 MMCM、零 IP"的现状（`docs/01_technical_solution.md:93`），需要新增 CDC；
2. 官方例程**一个 IO 时序约束都不写**：全文 `set_input_delay` / `set_output_delay` **0 命中**，XDC 里只有 `PACKAGE_PIN` + `IOSTANDARD` + `CONFIG_VOLTAGE` + `CFGBVS`，加上唯一一条时钟约束 `create_clock -period 8.000 -name eth_rxc [get_ports eth_rxc]`（`ATK_GUIDE.txt:26249`）。
   ⇒ 接收方向**完全靠 IDELAYE2 的 tap 扫描硬吃建立/保持时间**，而且默认 `IDELAY_VALUE = 0` 即**零延时**（`ATK_GUIDE.txt:24861`、顶层注释 `28767`：「输入数据IO延时,此处为0,即不延时(如果为n,表示延时n*78ps)」）。
   这意味着"照抄能跑"但"没有时序论证"——放到一个已经把 ADC 输入预算诚实建模（`-max 14.000/-min 9.500`）的工程里，要额外花时间把它讲清楚。
3. **例程里没有任何"MAC IP 核"，但用了一个 MMCM IP**：全文只例化 `clk_wiz_0`（Clocking Wizard），用途仅仅是给 `IDELAYCTRL` 提供 200 MHz 参考时钟（`ATK_GUIDE.txt:26141`、`24764`）；Tri Mode / AXI Ethernet / 1G-2.5G / Ethernet MAC 等**全部 0 命中**。MAC 层是纯 RTL 软逻辑（`ATK_GUIDE.txt:1506`「来使用 FPGA 的逻辑资源，以此实现以太网 MAC层软逻辑」），顶层例化六个模块：`clk_wiz_0`、`gmii_to_rgmii`、`arp`（内含 `arp_rx`/`arp_tx`，`25160`）、`udp`、异步 `fifo`、以太网控制（`ATK_GUIDE.txt:26816-26817`），另有 `crc32_d8`。
   ⚠️ ✅（原 5.x 未决项，已解决）：**那个异步 FIFO 确实是 FIFO Generator IP**，实例名 `async_fifo_2048x8b`（`ATK_GUIDE.txt:28112-28129`，端口 `rst/wr_clk/rd_clk/din/wr_en/rd_en/dout/full/empty` 与 IP 生成的 `.veo` 模板端口名逐字一致）。第 11 章还专门用 `fifo_generator_0` 教这个 IP（`ATK_GUIDE.txt:9122`、`9474`）。
   ⇒ 所以"零厂商 IP"应改写成：**1 个 Clocking Wizard（MMCM）+ 1 个 FIFO Generator**，**没有**任何以太网 MAC IP。这两个都是 Vivado 自带、无需额外授权的 IP，**不构成竞赛规则风险**。
   ❗附带发现：该 FIFO 的 `wr_clk` 与 `rd_clk` **都接 `gmii_rx_clk`**（`28114-28115`）⇒ 名字叫"异步"、实际当同步 FIFO 用，且收发共用同一个 125 MHz 域。
5. **发送时钟不是 MMCM 输出，而是从接收时钟 BUFG 出来的**：`assign rgmii_txc = gmii_tx_clk;`（`ATK_GUIDE.txt:25055`），ODDR 的 `C` 也接 `gmii_tx_clk`（`25064`）；
   - 顶层虽有 `wire clk_125m` 声明（`26131`），但 `clk_wiz_0` **只连了 `clk_out1(clk_200m)`**（`26141-26149`），没有 125 MHz 输出 ⇒ 排除"MMCM 出 125 M"；
   - `gmii_to_rgmii` 内部：`rgmii_rx` 子模块框图把 **BUFG 的输出画成 `gmii_clk`**（`ATK_GUIDE.txt:24819-24824`，与 `assign gmii_rx_clk = rgmii_rxc_bufg;`@`24874` 对应），而 `rgmii_tx` 子模块在模块框图上**接收 `gmii_tx_clk`**（`24798-24803`）；
   - ⇒ **唯一成立的解释：`gmii_tx_clk` 就是这个 125 MHz BUFG 输出（由 `eth_rxc` 缓冲而来）**。注意印出来的 `rgmii_rx` 模块端口表（`24847-24858`）只列了 `gmii_rx_clk`/`gmii_rx_dv`/`gmii_rxd`，是**书籍节选不完整**，不是设计里真的没接。
   - 这个结论能一次解释四个现象：① 顶层 `clk_125m` 悬空（本来就没用）；② `rgmii_txd` 没有 ODELAY（A7 无 ODELAYE2，且 TX 与 RX 同源、相位关系由 ODDR 的 `SAME_EDGE` 决定）；③ 附录 XDC 只有 `create_clock eth_rxc` 一条时钟（TX 时钟不是新时钟，是它的 BUFG 副本）；④ MMCM 只出 200 MHz（只服务 IDELAYCTRL）。
   - ⚠️ 但仍**保留为待办**：这是"由文档反推的唯一自洽解释"，不是读到源码。开工第一步仍是打开例程的 `gmii_to_rgmii.v` 确认那一行 `assign gmii_tx_clk = ...`。
6. **接收侧 BUFG 和 BUFIO 都用，且都直接来自 `rgmii_rxc`**：`assign gmii_rx_clk = rgmii_rxc_bufg;`（`24874`），`BUFG` 与 `BUFIO` 的 `.I()` 都接 `rgmii_rxc`（`24878-24886`），`BUFIO` 输出只作 `IDDR` 的 `C`（`24944`）；`IDELAYE2` 参数为 `IDELAY_TYPE("FIXED")`、`REFCLK_FREQUENCY(200.0)`（`24908-24910`），并带 `(* IODELAY_GROUP = "rgmii_rx_delay" *)` 属性（`24898`、`24954`）。
6. ❗ **正文与代码互相矛盾（要在报告里点明）**：正文说「系统时钟经过 PLL时钟模块后，输出 200Mhz的时钟，用于 IDELAYCTRL 原语的参考时钟」（`ATK_GUIDE.txt:24764`，**没说输入是什么**）；而代码里 `clk_wiz_0` 的输入是 **`eth_rxc`（125 MHz 的 RGMII 接收时钟）**，不是板上 50 MHz 系统时钟（`ATK_GUIDE.txt:26141-26149`、`28005-28012`、`26809`）。照抄时务必按**代码**来（以 `eth_rxc` 为源），否则 200 MHz 参考频率不对，IDELAYCTRL 会失锁。

### ★ 修订 2：PHY 的 25 MHz 时钟（v1 把它列为"必须确认的前提"，现降级）

- 全文搜索开发指南：**没有**任何"板载独立 25 MHz 晶振供 PHY"或"由 FPGA 输出 25 MHz 给 PHY"的表述（`ATK_GUIDE.txt` 中"有源晶振"只出现在摄像头模块的 24 MHz，`ATK_GUIDE.txt:29416`）。
- 但**反证很有力**：引脚表里以太网只有 12 个信号（`ATK_GUIDE.txt:1179-1194`），**没有任何一路是"25 MHz 输出给 PHY"**；而 RGMII 的 `ETH_TXC` 是 **MAC 侧提供**（`ATK_GUIDE.txt:24411`），在例程里由 `gmii_to_rgmii` 内部产生。
- ⇒ 结论：**PHY 的参考时钟几乎必然由板上（PHY 侧）的 25 MHz 晶体提供**，FPGA 不需要给。
- ❓ 仍待确认（不阻塞）：PHY 那侧的 25 MHz 晶振是"PHY 自带振荡器电路"还是"外部晶振"——若将来要上 1000 Mbps 自协商出问题，第一个要查的就是这里（用示波器量 PHY 附近的 25 MHz）。

### ★ 修订 3：`eth_rxc` 可以直接进 MMCM（对时序收敛是好消息）

官方例程把 `eth_rxc` 直接接到 `clk_wiz_0.clk_in1`（`ATK_GUIDE.txt:26148`），而**以太网 XDC 里没有 `CLOCK_DEDICATED_ROUTE FALSE`**——对比同一份开发指南在摄像头章节**必须**给 `cam_pclk_1`/`cam_pclk_2` 加这条属性（`ATK_GUIDE.txt:31363`、`31382`）才能把非专用时钟引脚的时钟接进 BUFG。
⇒ 说明 **`eth_rxc`(Y18) 是时钟专用（clock-capable）引脚**，不需要绕过专用布线资源，这消除了 v1 担心的"又一个 `CLOCK_DEDICATED_ROUTE` 坑"。

### ★ 修订 4（新增）：真正卡住交付的不是技术，而是**合规与评分结构**

读完指南后，最强的三条结论都跟"能不能上以太网"无关，而是：

1. **权重结构**：以太网最多落在 20 分的"性能与资源优化效果"里；创新性 30 分与它无关（§1.2）。
2. **文件名合规**：竞赛硬性要求纯英文文件名，本仓库有 **52 个非 ASCII 文件名**（§5.1），其中包含**核心交付物**——`deliverables/design_report.md`、`deliverables/topic_proposal.md`、`docs/00..13`、`rtl/SPEC_interface_contract.md`。这是"复现性"的直接扣分点。
3. **两项必交物缺失**：`skill/`（15 分权重里的一半）与"大模型协作记录"（§5.2、§5.3）。

---

## 3. 上位机侧：为什么可行且便宜（v1 结论保持）

现在数据通路是：

```
[FPGA] --18 字节遥测帧--> [串口] --> link.SerialWorker(后台线程) --> queue --> QTimer(100 ms) --> 各卡片
                                  ^ 唯一契约 = "有序字节流 + 帧头 AA55 / 应答头 5A"
```

关键事实（`host/link.py:1-16`、`host/link.py:67-84`）：

- 上层**从不接触串口对象**，只从队列拿"批量帧"；
- 帧解析是纯字节流解析（`us.parse_stream`），与物理层无关；
- 寄存器读写是"发 4 字节命令 → 等 6 字节应答"（`host/link.py:156` 的 `SerialWorker(port, baud, ...)` 是唯一的物理层入口）；
- 板载 CH340E 固定 **2 Mbaud / 8N1**（`host/link.py:67`）⇒ 单帧 90.68 µs、链路占用 90.7%。

⇒ 抽一层 transport 即可（唯一新增文件 `host/transport.py`）：

```python
class Transport:                       # 契约：open/close/read_batch()/write()；read_batch 可阻塞
    def open(self): ...
    def close(self): ...
    def read_batch(self, timeout): ...  # -> bytes（有序）
    def write(self, data): ...

class SerialTransport(Transport):       # 现 link.py 的 pyserial 读法原样搬进来
class UdpTransport(Transport):          # SOCK_DGRAM + 序号/重排序/丢包统计 + 命令重传
```

改动清单：`host/transport.py`（新增）、`host/link.py:156`（`SerialWorker.__init__` 换 transport 参数）、
`host/main_window.py:1016`（连接条加"串口/以太网"下拉 + IP/端口）、`host/ports.py`（加网口候选/default IP）。
**协议层零改动**：帧格式与命令格式在两种链路上保持完全一致，
`tools/uart_scope.py` / `tools/uart_spi.py` 的 `--selftest` 继续当协议守卫。

**上位机侧唯一新挑战是 UDP 不保序、会丢包**：需要数据报加**序号+时间戳**，
丢包/乱序在界面上明确统计（现有 `crc_err` / `resync_bytes` / `lost_frames` 统计面板直接复用），
**寄存器写命令必须带重传**（`0x0502` 这类写操作不能重发，所以重传要区分读/写，见 `host/link.py:12-13` 的既有约定）。

---

## 4. 带宽账（v1 结论保持，数字复核）

| 数据内容 | 带宽 | 串口 2 Mbaud（可用 180 kB/s） | 千兆 UDP（约 118 MB/s） |
|---|---|---|---|
| 现 18 字节帧 @10 kHz | 180 kB/s | ✅ 正好（占用 90.7%） | ✅ 余量 655× |
| **原始 ADC 12 bit × 25 MSa/s** | **37.5 MB/s** | ❌ 差 **208×** | ✅ 占用约 32% |
| 批量 ABZ/UVW 电平 @几十 kHz | 几百 kB/s | ⚠️ 挤不下 | ✅ 轻松 |

根因（与 v1 相同）：10 kSa/s 是 RTL 常数，不是链路限制——

```
rtl/uart_scope.v:151   parameter integer SAMPLE_DIV = 5000   // 50MHz/5000 = 10kHz 采样率
rtl/enc_top.v:59       parameter integer SAMPLE_DIV = 5000,  // 50MHz/5000 = 10kHz 帧率
```

⇒ 以太网真正的价值是"**把抽取前的原始样点直接送上来**"（时间分辨 100 µs → **40 ns**、
无需分箱、无需触发、无需 BRAM），而**不是**把现在这条 10 kHz 流搬上以太网。

---

## 5. 竞赛合规缺口清单（新增，按优先级排序）

### 5.1 文件名非英文（52 处，其中核心交付物约 30 处）

> ✅ **状态：本节的清单是"改名前"的现场快照（2026-10-15 之前），下文这些名字**已经全部改掉**——
> 42 个文件改成纯 ASCII 名、约 830 处交叉引用同步、`git ls-files` 的非 ASCII 判据已为空。
> 本节**故意保留旧名不改成新名**：它记录的是"当时到底有哪些名字踩线、怎么分类、怎么排序"，
> 把旧名换成新名会让这张表自相矛盾（"待改"栏里写着已经改好的名字）。
> 现行名对照见 `docs/DEV_STATUS.md` §3.A 第 9 条。
> 另外本节写"52 处"，是全盘扫描的原始命中数（含构建缓存）；实际改的是**仓库内**的 42 个。

竞赛原文：「仓库内所有目录名与文件名须使用纯英文（小写字母、数字、下划线或连字符），
**不得出现中文、空格或特殊字符**，以保证跨平台复现与脚本自动化。中文只出现在文件的正文内容中。」
——`COMP_GUIDE_2026.txt:861-862`（具身智能赛道 3.2.5 与自主选题赛道 3.3.5.4 **同一段要求**，见 `COMP_GUIDE_2026.txt:860-866`）。

实测（排除 `_tools` / `_synth_work` / `_v11_verify` / `dist*` / `build` / `.git` 等构建缓存目录，
共 15,330 个文件）：**52 个文件名含非 ASCII 字符**。完整清单见 `_tools/tmp/nonascii_names.txt`。重点项目：

| 类别 | 例子 | 处置建议 |
|---|---|---|
| **核心交付物** | `deliverables\design_report.md` + `.pdf`、`deliverables\topic_proposal.md` + `.pdf`、`deliverables\evidence_index.md`、`deliverables\photo_shot_list.md` | **必改**：改英文名 + 改所有交叉引用 |
| **文档主体** | `docs\00_roadmap_30d.md` … `docs\13_双通道上位机可行性分析.md`（含各自的 `.pdf`）、`docs\DPO2024B_user_guide.md`、`docs\LCD_touch_test_readme.md`、`docs\RGB_LCD_wiring_check.md` | **必改**（README 里的引用也要同步） |
| RTL 契约 | `rtl\SPEC_interface_contract.md` | **必改**（被多处引用） |
| 上位机运行时产物 | `host\_exe_work_onedir\host_onedir\host_app.exe` / `.pkg`、`host\_b4b_5波形放大.png`、`host\_s5_soak\encoder_abz_uvw_*.png` | 改（或移出提交包） |
| **第三方原始资料** | `【正点原子】达芬奇-lite之FPGA开发指南V1.0(1).pdf`、`HSTAD9238_module_manual.pdf`、`AD9238_carrier_schematic.pdf`、`全国大学生嵌入式芯片与系统设计竞赛'2026_FPGA_track_proposal_guide_AMD.pdf`、`DLC35_io_occupancy.xlsx`、`AD9238_carrier_pin_map.xls`、`信号发生器AFG-2225\*.pdf`、`prompt_host_ui_requirements.docx`、`prompt_display_requirements.docx` | **建议移出提交仓库**（换机器复现不需要它们），或改名 |
| 其它 | `_pdf_out\00_roadmap_30d.html`、`_pdf_out\03_golden_model_results.html`、`docs\DPO2024B_quick_ref.md` | 改或移出 |

⚠️ 附带项：`信号发生器AFG-2225\快速操作指南（中文）.pdf` 等文件名里还有**全角括号**，也属"特殊字符"。

### 5.2 缺 `skill/` 目录（15 分权重的技能包部分）

> ✅ **状态：已补齐（2026-10-15）。** 仓库根目录现有 **`skill/`**（`skill/README.md` + 6 份条目，
> 共 7 项），每份都按竞赛要求写了「适用范围 / 使用方法 / **失效条件** / 提炼过程 / 已验证效果」。
> 下面这张"素材清单"保留原样——它是当时选材的依据。

- 竞赛要求：`skill/` 目录 + `README.md` 说明「适用范围、使用方法与失效条件」，
  评价标准是「一支陌生队伍拿到该目录，能否直接用在自己的题目上」——`COMP_GUIDE_2026.txt:839-849`。
- 建议目录结构也列为必含项：`├── skill/ │ └── README.md`——`COMP_GUIDE_2026.txt:874-875`。
- 实测：**仓库内不存在 `skill/` 目录**（`glob **/skill/**` 无结果）。
- ✅ 好消息：本工程**天然有 3–4 个高复用度的 Skill 素材**，几乎不用额外开发成本：
  1. **黄金参考比对 + 资源/时序数据自动采集**（`tools/` 下已有的 lint 全量、`sim/logs` 汇总、`impl_util.rpt`/`impl_timing.rpt` 解析）——竞赛原文点名这是初级组推荐的 Skill 类型之一：「黄金参考比对、性能与资源数据自动采集并生成报告的工具」——`COMP_GUIDE_2026.txt:797`；
  2. **从接口契约自动生成主机侧调用代码或测试骨架**（`rtl/SPEC_interface_contract.md` → `tools/uart_spi.py` 已有雏形）——同上 `COMP_GUIDE_2026.txt:796`；
  3. **ADC 源同步接口的诚实约束推导**（"`set_input_delay` 该怎么算"的踩坑清单）：本工程有真实的 −3.352 ns → +0.959 ns 全过程记录，这是别人最想要的一类踩坑清单——`COMP_GUIDE_2026.txt:847`；
  4. **Vivado xsim 无预编译 unisims 库的应对**（`sim/README.md:64`）。
  ⚠️ 但这些都是**跨题目可用的通用 Skill**，不含 PYNQ（拿不到 PYNQ 额外加分）——因为本工程是纯 FPGA。

### 5.3 缺"大模型协作记录"

> ✅ **状态：已成文（2026-10-15，2026-10-15 追加第 11 条）。** `docs/ai-collaboration-log.md`（§1 协作方式 / §2 **11 条带
> `docs/DEV_STATUS.md` 行号锚点的自我纠错轨迹** / §3 三层智能体工作流 / §4 尚未完成的协作线 / §5 结论），
> 并按官方要求把摘要表与"技能包 7 项 + 提炼过程"接进 `deliverables/design_report.md` **§9**。
> ★ 第 11 条（`记录 11`）本身就是一次合规事故的自我纠错：**宣称"厂商手册已移出仓库"，
> 实际只是 `git mv` + 加了 `.gitignore` 规则，而 `.gitignore` 对已被跟踪的文件无效** ⇒
> 已 `git rm -r --cached _refs/vendor` 纠正，**并已用 `git filter-branch` 重写全部 103 个提交，
> 把 6 个厂商文件从历史里清除**（`git rev-list --objects main` 相关 grep 为空输出、
> 新基线 `8f194eb`、`.git` 135→70 MB），处置与验证数字见 `NOTICE` §1.1。

- 竞赛要求：提交**交互记录，含提示词、模型回答与自我纠错轨迹**——`COMP_GUIDE_2026.txt:807-808`；
  报告里要有专门章节——`COMP_GUIDE_2026.txt:857`；技能包要写「提炼过程：从哪些失败或观察中总结」——`COMP_GUIDE_2026.txt:858`。
- 实测：`docs/` 下没有任何专门的协作记录文件（`02_innovation_scoring.md` 是评分策略，不是协作记录）。
- ⇒ 这 15 分（大模型协作与技能包）目前**几乎裸奔**，而补齐它只需要**整理已经发生过的事情**（本仓库的开发过程本来就是人机协作完成的），
  **投入产出比远高于**再花一周去做以太网。← 这是 v2 最重要的判断。

### 5.4 文档漂移（会被评委当场问倒的两处）

> ✅ **状态：两处均已更正（2026-10-15）。** ① `rtl/SPEC_interface_contract.md:6` 与
> `rtl/enc_top.v:4`、`constr/enc_top.xdc:4` 的 "Vivado 2020.2+" 统一改为 **2026.1（本机实跑）**；
> ② `docs/00_roadmap_30d.md:75`、`:254` 与 `docs/01_technical_solution.md:731` 的
> "降到 25 MHz"回退项已就地标注**已作废**（附实测 `tPD_meas` 与 WNS 依据）。
> 下面两条保留原文，作为"当时为什么算漂移"的记录。

1. `rtl/SPEC_interface_contract.md:6` 写「开发工具：Vivado **2020.2** 及以上」，而本机与竞赛推荐都是 **2026.1**（`COMP_GUIDE_2026.txt:805`）⇒ 改成 2026.1。
2. `docs/00_roadmap_30d.md:75`、`:254` 与 `docs/01_technical_solution.md:730-731` 仍保留
   「**降采样率到 25 MHz**」作为 ADC 出问题时的回退动作，而 v11/v12 实测结论是
   **50 MHz + 同相捕获 + `set_input_delay -max 14.000/-min 9.500` 已收敛**（`tPD_meas` 3–4 ns，余量 +12.3 ns）
   ⇒ 这三处应标注为"历史回退项，已确认不需要执行"，否则报告内部自相矛盾（竞赛明确要求"设计过程中的判断依据写进报告"——`COMP_GUIDE_2026.txt:825`）。

### 5.5 引脚与 Bank 归属（2026 补充：三条待确认项的取证结果）

**证据来源**：`DLC35_io_occupancy.xlsx`（提取缓存 `_pin_work_xlsx.txt`，其中第 58–71 行是"以太网"区块）
＋ `_synth_work\pkgpins.csv`（XC7A35TFGG484 的 pin→bank 全表，485 行）。

**以太网 15 个信号全部落在 Bank 14**（`pkgpins.csv`：`Y18→14`、`V18→14`、`V19→14`、`W17→14`、`V17→14`、`AB20→14`、`AA19→14`、`AA18→14`、`AB18→14`、`U17→14`、`U18→14`、`P14→14`、`R14→14`、`R18→14`、`T18→14`）：

| 信号 | 引脚 | Bank | 方向（指南用语） |
|---|---|---|---|
| `eth_rxc` | Y18 | **14** | 输入，接收时钟（125 MHz） |
| `eth_rx_ctl` | V19 | **14** | 输入，接收数据有效标志 |
| `eth_rxd[0..3]` | W17 / V17 / AB20 / AA19 | **14** | 输入 |
| `eth_txc` | AA18 | **14** | 输出，发送时钟 |
| `eth_tx_ctl` | AB18 | **14** | 输出 |
| `eth_txd[0..3]` | R14 / P14 / U18 / U17 | **14** | 输出 |
| `eth_rst_n`(PHY 复位) | V18 | **14** | 输出，低有效 |
| `eth_mdc` / `eth_mdio` | R18 / T18 | **14** | MDIO 管理（例程**不使用**） |

**本工程各接口的 Bank 归属（关键，说明"为什么没有 IODELAY 冲突"）**：

| 接口 | Bank | 引脚 |
|---|---|---|
| 系统时钟 `sys_clk` / `sys_rst_n` | **34** | V4 / U7 |
| **ADC**（`ad_clk`/`ad_clk2`/`ad_ch1_d[*]`/`ad_ch2_d[*]`/`*_otr`） | **16** | B18 / F16 / F18…A20 / E17…B15 / E19 / B16 |
| ABZ / UVW / 增量输出（`a_out`…`w_out`）、SPI、状态灯 | **12** | H20…M22 / L20,J22,H22,J20 / K21,K22 |
| **以太网 + UART + IIC + LED + SD + 直流 GPIO** | **14** | 见上表 / T20,W21 / W22,AA20 / AB21,AB22,J21,K21 |

⇒ **结论：以太网（Bank 14）与 ADC（Bank 16）不在同一个 IODELAY Bank**，所以：

1. **不存在**"以太网的 `IDELAYCTRL` 与 ADC 争同一 Bank 参考时钟/`IODELAY_GROUP`"的问题；
2. 但反过来有个**工程事实要写进报告**：全仓 RTL 与 XDC **搜不到任何 `IDELAY`/`IDELAYE2`/`IDELAYCTRL`/`ODELAY`**（`grep` 覆盖所有 `*.v/*.sv/*.xdc` 零命中）⇒ 现在这个设计**完全没用 IDELAY 资源**。以太网将是**第一个**使用 IDELAY 的模块，需要新增的只有：Bank 14 的 200 MHz 参考时钟（例程用 `clk_wiz_0(clk_in1=eth_rxc)` 产生）＋ 1 个 `IDELAYCTRL` ＋ `iodelay_group` 属性；**不需要碰 ADC 那一侧**。
3. 时钟域数量会从 1 个（50 MHz）变成 3 个（50 MHz 系统 / 125 MHz RGMII RX=TX / 200 MHz IDELAY 参考），CDC 是新增工作量里最需要写清楚的一块。
4. Bank 14 同时承载**当前量产的 UART 遥测**（`uart_tx`=W21、`uart_rx`=T20）⇒ 以太网与串口**可以同时在位**（互不占引脚），这正是"双通道上位机"在硬件层成立的前提。
5. ⚠️ 两个仍需板级/器件手册确认的点（不是文档能回答的）：Bank 14 的 **VCCO 是否为 3.3 V**（决定能否继续用 LVCMOS33）；Bank 14 是否与 DDR3 共享电源域/是否有其他限制（DDR3 在 Bank 34/35，见 `pkgpins.csv` 的 `M9→0`、`L10→0` 等）。

---

## 6. 复试：三条路对比（v2 修订工作量列）

| 方案 | 时间分辨 | 连续时长 | 实时 | 新增硬件/约束 | 工作量（v2） | 竞赛落点 |
|---|---|---|---|---|---|---|
| 现状 UART 2 Mbaud | 100 µs | 无限 | ✅ | 无 | 已完成 | 功能完整性（20） |
| 等效采样（已在用） | 按角度 1.4° | 无限（慢） | ✅ | 无 | 已完成 | 创新性（30）已包含 |
| **BRAM 深缓存** | **80 ns** | 0.65–11 ms | ❌ 采完回放 | 无（BRAM **0/50** 全空，片内 1800 Kbit） | 小（约 1 周） | 性能与资源（20）+ 完整度（20） |
| **千兆以太网** | **40 ns** | 无限 | ✅ | **12 个引脚** + MMCM 200 MHz + IDELAYCTRL/IDELAYE2 | **中（3–5 天，若复用官方 RGMII 层）** ★v1 估计 1–5 周 | 性能与资源（20）＋"给出与基线的对比"正好对味 |
| DDR3（256 MB，12.8 Gbps） | 40 ns | **秒级** | 准实时 | MIG IP + 43 引脚 + 新时钟域 | 很大 | 同上 |

★ v2 的关键变化：**以太网的"性价比"从"不值"变成"可以考虑"**——
v1 判断"以太网要 1–5 周、还有 IP 授权风险"所以劝退；现在证据显示
官方例程（纯 RTL、无 IP 核、无 IO 约束、不用 MDIO、PHY 复位借系统复位）可复用，
**3–5 天能通**。但它依然**不解决 10 kSa/s 这个根问题**，而且**依然只落在 20 分那格**。

---

## 7. 排期（工期只有 20.8 天：2026-10-15 → 2026-11-04 18:00）

**总判据**：先做"命中权重高、且不做就直接扣分"的（协作记录 15 / 技能包 15 / 文件名合规 / 交付物完整性）；以太网是**可选**项，不排在交付物前面。

**D1–D2（文档，零风险，直接对着 15 分）**
1. 写大模型协作记录（提示词 → 模型回答 → 自我纠错轨迹）：材料已存在，只需归集。
2. 建 `skill/` + `skill/README.md`，放 3 项通用 Skill（黄金参考比对与数据采集脚本 / 契约→主机侧代码生成 / ADC 源同步约束推导踩坑清单）。
   ⇒ **注意**：指南要求技能包写"提炼过程：从哪些失败或观察中总结"（`COMP_GUIDE_2026.txt:858`），这跟第 1 项是同一批材料，一起做省时间。

**D3–D4（合规与一致性，也是零 RTL 风险）**
3. 文件名英文合规整改（§5.1）：先核心交付物 + `docs` 主体 + `rtl/SPEC_interface_contract.md`，并同步所有交叉引用。
4. 修文档漂移（§5.4）：`rtl/SPEC_interface_contract.md:6` 的 Vivado 版本；`docs/00`/`docs/01` 里已作废的"降到 25 MHz"回退项。

**D5–D9（交付物主体——权重最大，必须先保住）**
5. 设计报告定稿：把"资源占用 / 时钟频率 / 关键性能指标 / 与基线的对比"补齐（`COMP_GUIDE_2026.txt:821-825`、`836`）。
6. 可复现性验证：在干净目录按 README 走一遍从零复现（竞赛明确以"能否复现"评价）。
7. 录演示视频 / 拍素材（`deliverables/` 里的拍摄清单）。
8. 决赛海报那一页英文 PPT（若按指南要求提前准备，`COMP_GUIDE_2026.txt:962-965`）。

**D10–D16（可选加分项，二选一，别贪）**
9. **以太网**：抄官方 `clk_wiz`（`clk_in1=eth_rxc` → 200 MHz，只喂 IDELAYCTRL）+ `gmii_to_rgmii`，**先只做 UDP 回环**验证链路，再搬现有 10 kHz 帧；同时产出 RTT / 持续吞吐率 / 丢包率，对上"通信性能"口径（`COMP_GUIDE_2026.txt:551-556`）。**预留 7 天是含排错余量的**，若第 3 天还没回环通过就止损。
10. 或 **BRAM 深缓存**（纯 RTL 增量、不新增引脚、不动已收敛时序），拿"80 ns 时间分辨"这条性能对比。

**D17–D20（冻结与提交）**
11. **代码与文档冻结**，只修 bug；留出至少 2 天做"打包 + 在另一台机器上验证"。
12. 开源仓库（GitHub/Gitee + MIT/Apache-2.0）与提交物自查（`COMP_GUIDE_2026.txt:818-820`）。

**明确不做**：绕过抽取器的 25 MSa/s 原始样点上传（P3），DDR3 路线。**也不做**：为了"波形帧率低"直接上以太网——那救不了 10 kSa/s，还挤掉交付物时间。

### 7.1 "两手都要抓"（串口 + 以太网并存）的量化判定

| 维度 | 判定 | 依据 |
|---|---|---|
| **引脚** | ✅ 不冲突 | UART `uart_tx`=W21 / `uart_rx`=T20 与 15 个 `eth_*` **同在 Bank 14 但互不占脚**（§5.5） |
| **BRAM** | ✅ 够 | 全片 1800 Kbit，现用 **0/50 Tile**；例程那级 ~几十 Kbit，2048×8b FIFO 只占半块 18Kb |
| **LUT / FF / DSP** | ✅ 够 | 余量 LUT 14502 / FF 37526 / DSP 74；手写 MAC（`crc32_d8`+`arp`+`udp`+`gmii_to_rgmii`）属小规模 |
| **时钟资源** | ✅ 够 | BUFGCTRL 用 1/32；新增 2 个 BUFG（`eth_rxc` 的 BUFG/BUFIO）+ 1 个 MMCM |
| **协议层复用** | ✅ 可复用 | 两条链路都挂同一个 `spi_slave` + `reg_file` + `uart_spi_bridge` 寄存器/命令语义（`rtl/uart_scope.v:149-169`、`rtl/spi_slave.v:60-74`、`rtl/uart_spi_bridge.v:74`） |
| 时钟域 | ⚠️ 新增 | 1 个（50 MHz）→ 3 个（50 MHz / 125 MHz RGMII / 200 MHz IDELAY 参考）；`rtl/cdc_sync2.v`、`cdc_pulse` 有现成单元可复用 |
| **时序收敛风险** | ❗**最大风险** | 见下 |
| **上位机** | ✅ 便宜 | `host/transport.py` 新抽象 + `host/link.py:156`、`host/main_window.py:1016`、`host/ports.py` 三处小改；协议零改动（§3） |
| 排期（20.8 天） | ⚠️ 紧 | 必须先有 UDP 回环再谈搬帧；**第 3 天不过就止损** |

**不能粉饰的一条风险**：以太网会把 125 MHz 域和 `IDELAYE2/IDELAYCTRL` 引入**同一个位流**。
现在记录的 +12.3 ns 余量是「50 MHz 单域、零 IDELAY」条件下的结果；加了 125/200 MHz 域后，
**整个设计的布局布线与余量必须重新测量、重新记录**——这本身也是竞赛要的素材（"时序收敛状态与最差负裕量 WNS"，`COMP_GUIDE_2026.txt:561-562`）。
这不是"加个模块"的代价，是"全片重收敛"的代价。

**20.8 天内的现实形态（推荐）**：

1. UART 保持**"保证链路"**地位（现场无以太网调试条件时仍能演示，且已是量产状态）；
2. 以太网只做**"高带宽补充链路"**：先 UDP 回环 → 再只搬波形帧，**命令仍走串口**（省掉 UDP 写命令的重传/幂等设计）；
3. 上位机用 `transport` 抽象把两者做成**同一接口的两个实现**，界面加"串口/以太网"下拉；
4. 下位机**只保留一份遥测帧生成器**（`rtl/uart_scope.v` 现成），不要为以太网复制第二份——否则两条链路数据不一致，报告里也讲不清。

**不推荐**：在 20.8 天里让两条链路都做到"功能对等 + 都有命令通道 + 都做丢包重传"。
那会同时吃掉 D5–D9 的交付物时间，而那块是**不做就直接扣**的 50 分。

---

## 8. 待确认清单（v2 更新）

| # | 问题 | v1 状态 | v2 状态 |
|---|---|---|---|
| 1 | 竞赛规则是否允许用厂商 IP 核 MAC？ | ❓ 决定 1 周 vs 5 周 | ✅ **不再是问题**：官方例程本身纯 RTL、不用以太网 IP |
| 2 | PHY 的 25 MHz 参考时钟来源？ | ❓ 前提问题 | ⚠️ 降级（有独立取证支持）：连接框图（`ATK_GUIDE.txt:1507-1518`）逐行列出的 FPGA↔YT8531 信号只有 ETH_TXC / ETH_TXD[3:0] / ETH_TXCTL / ETH_RXC / ETH_RXD[3:0] / ETH_RXCTL / ETH_MDC / ETH_MDIO，PHY 侧另列 MDI[3:0] / PHY_LED[2:0] ⇒ **FPGA→PHY 方向唯一时钟线是 ETH_TXC，不存在"25 MHz 送 PHY"的引脚**；开发指南全篇只提 50 MHz 晶振（`1338`），以太网章节的 "25M" 全是 RGMII 速率说明（`24407`、`24430`）。仅需上板前用示波器确认一次 |
| 3 | 测试 PC 有没有网口 / 直连还是过路由器？ | ❓ | ✅ 官方流程已覆盖：接电脑网口**或路由器**都行，手动设静态 IP 即可（`ATK_GUIDE.txt:26278`、`26305-26314`） |
| 4 | 帧格式要不要升 SPEC 版本？ | ❓ | ❓ 仍在（本工程约定：改代码前先改 `rtl/SPEC_interface_contract.md`） |
| 5 | 目标取舍：看清一段波形 vs 连续秒级不丢点？ | ❓ | ❓ 仍在（前者 BRAM，后者以太网/DDR3） |
| 6 | **本队报名赛道与学历分组是否已定？** | — | ✅ **已定：初级组（自主选题赛道 3.3）**。初级组器件范围为 AMD 7 Series FPGA / Zynq-7000 / UltraScale / UltraScale+（`COMP_GUIDE_2026.txt:756-758`），`xc7a35tfgg484-2` 在范围内 |
| 7 | **大赛官方的报名/提交/决赛时间节点？** | — | ✅ **已定：作品提交截止 `2026-11-04 18:00`**（用户 m00196 确认）。选题指南本身未给日期（只说"不单独设定赛程，以官方公布为准"），故以此为准。**`2026-10-15` 起剩余 20.8 天** |
| 8 | **例程里那个异步 `fifo` 模块是不是 FIFO Generator IP？** | — | ✅ **已解决：是**。实例名 `async_fifo_2048x8b`（`ATK_GUIDE.txt:28112-28129`），端口与 IP 的 `.veo` 模板逐字一致；第 11 章专门教这个 IP（`9122`、`9474`）。"零厂商 IP"改写为「**1 个 Clocking Wizard + 1 个 FIFO Generator，无任何以太网 MAC IP**」——两者都是 Vivado 自带、无需额外授权 |
| 9 | **`gmii_to_rgmii` 内部的 125 MHz TX 时钟是怎么产生的？** | — | ⚠️ **已推到唯一自洽解释（但未读源码）**：`gmii_tx_clk` = `rgmii_rxc` 经 BUFG 后的副本。依据：顶层 `clk_125m` 悬空（`26131`）、`clk_wiz_0` 只出 200 MHz（`26141-26149`）、`rgmii_rx` 框图把 BUFG 输出画成 `gmii_clk`（`24819-24824`）、`rgmii_tx` 框图接收 `gmii_tx_clk`（`24798-24803`）。**开工第一步仍要读例程 `gmii_to_rgmii.v` 确认那一行 assign** |
| 10 | **以太网引脚在哪个 Bank？** | — | ✅ **已解决：全部 15 个信号都在 Bank 14**（`pkgpins.csv`：Y18/V18/V19/W17/V17/AB20/AA19/AA18/AB18/U17/U18/P14/R14/R18/T18 全部 →14）。ADC 在 **Bank 16**、sys_clk/u7 与 DDR3 在 **Bank 34**、ABZ/SPI 在 **Bank 15** ⇒ **不存在与 ADC 争 IODELAY 参考时钟的问题**；且全仓 RTL/XDC **无任何 IDELAY/IDELAYCTRL/ODELAY**（grep 零命中）⇒ 以太网是**第一个**用 IDELAY 的模块。详见 §5.5 |
| 11 | **Bank 14 的 VCCO 是否为 3.3 V？** | — | ❓ **新增**：文档未载明，需查原理图/开发板实物（决定能否沿用 LVCMOS33） |
