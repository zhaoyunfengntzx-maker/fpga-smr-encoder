> 来源：本文件原为 `_merge_work/共存可行性评估.md`（2026-10-19 的屏+以太网共存预算评估），2026-10-23 归档进 docs/；文中提到的 `merge_impl_*.rpt` 原始报告仍在本地 `_merge_work/`（未入库）。

# 屏幕 UI + 千兆以太网 能不能同时跑？—— 上板资源实测评估

- 日期：2026-10-19
- 器件：**XC7A35TFGG484-2**（Artix-7 35T：20,800 LUT / 41,600 FF / 50 BRAM Tile / 90 DSP / 250 IOB / 5 MMCM / 32 BUFG）
- 板卡：正点原子 达芬奇-lite，`sys_clk` = V4 = 50 MHz 单时钟域
- 方法：不碰生产 RTL，在 `_merge_work/` 里把两条线**真的合起来**跑完整综合→实现→布线→DRC→出位流，用工具数据回答，而不是估算
- 证据文件：`_merge_work/merge_synth_util.rpt`、`_merge_work/merge_impl_util.rpt`、`_merge_work/merge_impl_util_hier.rpt`、`_merge_work/merge_impl_timing.rpt`、`_merge_work/merge_impl_top_paths.rpt`、`_merge_work/merge_impl_drc.rpt`、`_merge_work/as_is_place2.log`、`_merge_work/enc_top_ui_eth.bit`

---

## 一、结论（先说答案）

| 问题 | 答案 |
|---|---|
| 屏幕和以太网能同时存在吗？ | **能。** 引脚、Bank、时钟、数据通路四层都没有冲突，合并后 DRC 0 error、时序全过、位流已出。 |
| 板子资源够不够？ | **够，但要看抓包深度。** 抓包 **32768 点**（现状）= 放不下（BRAM 需要 101 个站点、只有 100 个）；抓包降到 **16384 点** = 放得下且时序收敛（LUT 86.4% / BRAM 77.0%）。 |
| 差多少？ | 真实缺口 **4.5 个 BRAM Tile**（需求 54.5 / 可用 50）；合成器降级 8 个 RAMB18 后**仍** 101%（50.5/50），placer 报 `DRC UTLZ-1`（需 101 个站点、只有 100 个）。其它资源（FF 29%、DSP 24%、IOB 43%）都很宽松，LUT 是第二位瓶颈。 |

**一句话**：显示 UI 与以太网在架构上是「加法」而不是「抢资源」，两者唯一的硬冲突是**块 RAM 总量**；把抓包缓冲从 32768 减半到 16384，整套就能装进 35T，而且时序还留 0.2 ns。

---

## 二、三层证据

### 2.1 引脚 / Bank：零冲突（工具实证，不是查表推断）

`constr/enc_top_disp.xdc` 共 91 个 PACKAGE_PIN，构成：

| 组 | 引脚数 | Bank | 电平 |
|---|---|---|---|
| LCD RGB888 | 24 | Bank 34 | LVCMOS33 |
| LCD 控制（pclk/hs/vs/de/bl/rst） | 6 | Bank 34 | LVCMOS33 |
| 触摸（scl/sda/rst_n/int） | 4 | Bank 34 | LVCMOS33 |
| `disp_test[7:0]` | 8 | Bank 15 | LVCMOS33 |
| `key1_n` + `ui_btn` | 2 | Bank 15 | LVCMOS33 |
| ADC（AD9238 双 12 bit @50 MSPS） | 28 | Bank 16 | LVCMOS33 |
| 编码器 ABZ / SPI | 10 | Bank 15 | LVCMOS33 |
| 系统（sys_clk/led[0..3]/uart/irq_n/key_n） | 9 | Bank 34 | LVCMOS33 |
| **小计** | **91** | | |
| 以太网 RGMII（TXD/TXC/TX_CTL/RXD/RXC/RX_CTL/PHY_RST） | 13 | Bank 14 | LVCMOS33 |
| 合并总计 | **104** | | |

（DDR3 未合并，仅核对：48 脚全在 Bank 35、SSTL135。）

- `constr/enc_top_disp.xdc`（91 个 PACKAGE_PIN）与 `constr/enc_top_eth.xdc`（13 个）**集合零重复**（程序化比对 `duplicates = []`），两份 XDC 也无重复的 `create_clock`。
- 交叉验证：合并后 **Bonded IOB = 104 = 91 + 13**，一个不多一个不少 ⇒ 没有引脚复用、没有被迫共享站点。
- 屏幕与 DDR3 分属 Bank 34（3.3 V）与 Bank 35（1.35 V），VCCO 不打架——之前担心的「屏幕抢 DDR3 的 Bank」不成立。

### 2.2 时钟：三个域同时满足，125 MHz 根本不是瓶颈

| 时钟域 | 频率 | WNS | WHS | 端点 |
|---|---|---|---|---|
| `sys_clk`（编码器 + 显示像素时钟 `lcd_pclk = sys_clk`） | 50 MHz | **+0.209 ns** | +0.019 ns | 24,588 |
| `clk_125_raw`（RGMII 发送侧） | 125 MHz | +0.423 ns | +0.102 ns | 5,147 |
| `eth_rxc_clk`（RGMII 接收侧） | 125 MHz | +0.502 ns | +0.109 ns | 357 |
| `adc_clk` / `adc_clk2` | 50 MHz | +6.965 ns | +0.965 ns | 2 |

- 合并后 **MMCM 1 / 5，BUFG 4 / 32**：显示不需要独立像素时钟（`disp/enc_top_disp.v:277` `assign lcd_pclk = sys_clk;`），所以没有额外的 MMCM/BUFG 开销。
- 全设计最差路径是 `u_enc/cfg_inter_q_reg[1]/C` → `u_enc/u_abz/r_ovl_reg[6]/CE`（20 ns 约束，slack 0.209）。**这条链是编码器自己的 ABZ 输出路径，与显示、与 125 MHz 都无关**——和纯以太网版（+0.101，同一族路径 `cfg_inter_q[3] → r_ovl[1]/CE`）是同一个瓶颈，说明加显示没有恶化时序。

### 2.3 资源：两个真实构建的对比

| 指标 | ① 原样合并（抓包 32768） | ② 抓包 16384（推荐） | 器件容量 |
|---|---|---|---|
| Slice LUT | 19,286 (**92.72%**) | **17,968 (86.38%)** | 20,800 |
| ├ LUT as Logic | 18,541 (89.14%) | 17,931 (86.21%) | — |
| └ LUT as Memory (LUTRAM) | 745 (7.76%) | 37 (0.39%) | 9,600 |
| Slice FF | 12,397 (29.80%) | 12,231 (29.40%) | 41,600 |
| **Block RAM Tile** | **50.5 (101%) ✗** | **38.5 (77.00%)** | 50 |
| ├ RAMB36/FIFO | 50 (100%) | 34 (68.00%) | 50 |
| └ RAMB18 | 1 | 9 | 100 |
| DSP48E1 | 22 (24.44%) | 22 (24.44%) | 90 |
| Bonded IOB | 107 (42.80%) | 107 (42.80%) | 250 |
| MMCM / BUFGCTRL | 1 / 5 | 1 / 4 | 5 / 32 |
| 时序 | **无法布线** | WNS +0.209 / WHS +0.019，0 failing | — |
| DRC | `[DRC UTLZ-1]` 失败 | 0 Errors | — |
| 位流 | 无 | `enc_top_ui_eth.bit` = 1,682,875 B | — |

① 的失败是**硬失败**，工具原话（`_merge_work/as_is_place2.log`）：

```
ERROR: [DRC UTLZ-1] Resource utilization: RAMB18 and RAMB36/FIFO over-utilized in Top Level Design
  (This design requires 101 of such cell types but only 100 compatible sites are available in the target device.)
ERROR: [Vivado_Tcl 4-23] Error(s) found during DRC. Placer not run.
place_design failed
```

而且 ① 比「差 1 个 tile」更糟：合成器在 BRAM 用满后，把 9 个 RAMB18 里的 8 个**降级成了分布式 RAM**（LUTRAM 33 → 745），代价是 LUT 直接顶到 92.7%，BRAM 却仍是 101%——两头不落好。

---

## 三、资源从哪来（可对账）

合并后层次明细（`_merge_work/merge_impl_util_hier.rpt`，Routed）：

| 模块 | LUT | RAMB36 | RAMB18 | DSP |
|---|---|---|---|---|
| `u_disp`（显示引擎） | 5,741 | 17 | 7 | 6 |
| `u_enc`（编码器顶层） | 10,214 | 17 | 2 | 16 |
| ├ `u_eth`（eth_top） | 2,609 | 1 | 2 | 0 |
| ├ `u_cap`（scope_capture，16384×32b） | 168 | **16** | 0 | 0 |
| ├ `u_cordic` | 2,317 | 0 | 0 | 0 |
| └ `u_calib` | 1,722 | 0 | 0 | 9 |
| 顶层胶水 | 63 | 0 | 0 | 0 |
| **合计** | **17,968** | **34** | **9** | **22** |

**BRAM 账**：显示 20.5 + 抓包 16 + 以太网其它 2 = **38.5 / 50**，余 11.5 tiles。
**可加性验证**：编码器 6,298 + 以太网增量 3,566 + 显示增量 8,195 = 18,059 LUT，与实测 17,968 只差 91 LUT（0.5%）⇒ 合并是近乎线性的面积叠加，没有隐藏的重复开销。

**反过来算 32768 深度**：显示 20.5 + 以太网 34（其中 32 是抓包）= **54.5 tiles，可用 50，缺 4.5**。合成器不会老实报 109%，而是先把 8 个 RAMB18 降级成分布式 RAM 硬挤进 50 个 RAMB36，于是报出 50.5 tiles —— 但 placer 一验 DRC 就是 101 > 100，直接拒绝布线。所以「只差 1 个 tile」是**降级之后仍差 1 个**，真实缺口是 4.5 个 tile。

---

## 四、为什么「同时跑」在功能上不打架（源码级依据）

1. **显示不读抓包 RAM。** 显示侧通过 `disp_tap`（376 bit）取数，而 `disp_tap` 是 `rtl/enc_top.v:1536-1576` 的**纯观测赋值**——每一位都直接取自已寄存的实时信号（angle / s_cor / c_cor / pos_full / io_state / io_flags / 配置字），每位只驱动 1 个负载（源码头注释 `rtl/enc_top.v:1527-1530` 明确要求如此，且警告不许放组合中间量）。显示引擎 `disp/disp_engine.v:72-80` 接收的是这些**分开的实时抽头**（`tap_angle`/`tap_s_n`/`tap_c_n`/`tap_pos_full`/`tap_io_state`/`tap_io_flags`/`tap_stat`/`tap_cfg_inter`/`tap_cfg_div`），自己在 `u_disp` 内部建波形/XY/文本缓存（17 RAMB36 + 7 RAMB18）。
2. **抓包 RAM 的读口由以太网独占。** `rtl/scope_capture.v` 只有**一个**读口（`rd_addr`/`rd_en`/`rd_data`，L60-62），在 `rtl/enc_top.v:1469-1472` 被三路按优先级复选：`stream_en → 连续流` > `eth_udp_rd_busy → UDP dump` > `dump_rd_addr`。显示完全不参与这个复选。
3. ⇒ 两条通路**不共享任何存储、不共享读口、不共享仲裁**，唯一共享的是编码器流水线本身（tap 每位 1 个负载）和器件引脚。

因此「屏幕 + 以太网」在架构上是正交的加法；代价只有面积。**推论**：一旦面积装得下，功能上同时刷新 UI 与传数据不存在资源性阻碍（真正的并发正确性仍需上板验证，见第六节）。

---

## 五、若要保留 32768 抓包（评估过，不推荐）

| 方案 | 结果 | 评价 |
|---|---|---|
| 挤 1 个 tile：字库从 3.99 tiles 砍到 ASCII-only（~1.2） | 可腾 ~2.8 tiles，能进 50 | ✗ UI 丢中文；且 ① 的 LUT 已 92.7%，余量几乎为零 |
| 砍显示其它小 RAM（`p7_ram`/`text_ram` 等） | 需逐个砍，收益零碎 | ✗ 改动面大、收益小 |
| **DDR3 做长记录（模式 C）** | **不可能**：MIG 在 `ddr3_top_mem` 里连同测试逻辑占 **6,739 LUT / 5,358 FF**，加到 17,968 上 = 24.7k / 20.8k = **119%** | ✗ 35T 装不下；要长记录只能换 50T/100T，或彻底放弃显示 |
| 抓包降到 16384（本方案） | LUT 86.4%、BRAM 77.0%、时序过、位流已出 | ✓ 唯一被实测验证的路径 |

16384 的代价是观察窗口：@25 MSPS（抽取 2）= **655 µs**；@12.5 MSPS（抽取 4）= **1.31 ms**（与原来 32768 的窗口相同）。
传输侧：16384 × 4 B = 64 KB ≈ 524 kbit，@700 Mbps 约 **0.75 ms**、@950 Mbps 约 **0.55 ms**——与 655 µs 的采集时间同量级，相当于「采满一屏、正好传完」，做准连续流是够用的。

---

## 六、必须提醒的风险与没做的事

1. **hold 余量很薄**：`sys_clk` WHS 只有 **+0.019 ns**（纯以太网版 +0.058，纯显示版更宽）。虽然 signoff 通过，但这是全设计最脆的一项。建议：上位板前再跑 1~2 个 place seed 取最差值，或接受「这一版对温度/电压最敏感」的事实。
2. **LUT 只剩 2,832（13.6%）**。同一位流里再塞 ILA（约 1~2 k LUT）会直接到 96%+，不建议；要调试请用**单独的调试位流**（`ENC_TOP_ILA`）。
3. **本次只验证了「能实现」**：资源、引脚、时钟、时序、DRC、位流都已实证；**没有**做功能仿真，也**没有**上板。屏幕刷新与网口 dump 并发时的实际行为（尤其二者都依赖 50 MHz 域时的采样一致性）需要上板确认。
4. **生产集成别用实验顶层**：`_merge_work/enc_top_ui_eth.v` 是从 `disp/enc_top_disp.v` 复制+改名的临时件。正式做法是把 eth 端口/例化加进 `rtl/enc_top_disp.v`（或给 eth 加 `ifdef ENC_ETH` 宏），并让 `tools/impl_disp.tcl` 的源列表包含 `rtl/eth/*.v`。
5. **顺手修掉一个既存坑**：当前源码下 `rtl/enc_top.v` 无条件例化 `eth_top`，导致 `tools/impl_disp.tcl`（不读 `rtl/eth/*.v`）**已经编不过**——`_disp_work/impl_disp.log:187` 报 `[Synth 8-439] module 'eth_top' not found`。`_disp_work/impl_util.rpt` 里那份 20.5 BRAM 的报告是这次改动之前的历史产物，无法由当前源码复现。合并时一定要把这两条线并到一个构建脚本里。

---

## 七、建议的落地顺序

1. `rtl/enc_top.v` 里把 `scope_capture` / `stream_tx` 的 `DEPTH` 参数化（默认 16384），由顶层传参，别改两个常量。
2. `rtl/enc_top_disp.v` 正式增加 eth 端口 + `eth_top` 例化（推荐 `ifdef ENC_ETH` 门控，保持纯显示构建可用）。
3. `tools/impl_disp.tcl` 源列表加 `rtl/eth/*.v`，并把 `enc_top_eth.xdc` 一起读。
4. 出位流后上板：先 `ping 192.168.1.10` / `arp -a`（MAC `02:00:00:00:00:01`）验证网口，再触摸翻页验证 UI 与采集互不影响。
5. 若上板发现 hold 边际问题：优先给 `cfg_inter` 进 ABZ 前打一拍（`rtl/enc_top.v` 侧，1 周期延迟对配置可接受），而不是靠换 seed 赌。
