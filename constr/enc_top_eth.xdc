# =============================================================================
#  enc_top_eth.xdc —— B2 千兆以太网（YT8531C，RGMII）约束
# -----------------------------------------------------------------------------
#  为什么单独一个文件：
#    constr/enc_top.xdc 是 GBK 存量文件（整份中文注释），用脚本整体改写风险高。
#    以太网这部分是纯新增，单独放一个 ASCII 文件，由 tools/synth_check.tcl 与
#    tools/impl_check.tcl 在 enc_top.xdc 之后追加读入。
#
#  引脚来源：正点原子《达芬奇-lite》原理图 / 引脚表（Bank 14，LVCMOS33）。
#    ADC 在 Bank 16，J6 扩展口与之不同 Bank，互不冲突。
#
#  ★ 本文件是"第一版可签核"的约束，不是最终签核值：
#    RGMII 的 TX/RX 延时最终要按 PCB 走线长度 + PHY 内部延时（YT8531C 默认
#    RGMII 内部延时模式）实测调整，见 docs/17 的 B2 验收项。
# =============================================================================

# ---- 1. 引脚 ---------------------------------------------------------------
#   ★ 每根引脚写成 PACKAGE_PIN + IOSTANDARD 的 -dict 形式（与 constr/enc_top.xdc
#     同一风格）。原因：v60 起 tools/gen_merged_xdc.py 把本文件当作第三个来源
#     合并进 constr/enc_top_disp.xdc，只有 -dict 形式才能被脚本识别，并参与
#     "球号冲突 / 顶层端口覆盖"自检。分开写会绕过自检，静默漏引脚。
set_property -dict {PACKAGE_PIN V18  IOSTANDARD LVCMOS33} [get_ports phy_rst_n]
set_property -dict {PACKAGE_PIN R14  IOSTANDARD LVCMOS33} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN P14  IOSTANDARD LVCMOS33} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN U18  IOSTANDARD LVCMOS33} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN U17  IOSTANDARD LVCMOS33} [get_ports {eth_txd[3]}]
set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVCMOS33} [get_ports eth_txc]
set_property -dict {PACKAGE_PIN AB18 IOSTANDARD LVCMOS33} [get_ports eth_tx_ctl]
set_property -dict {PACKAGE_PIN W17  IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN V17  IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[3]}]
set_property -dict {PACKAGE_PIN Y18  IOSTANDARD LVCMOS33} [get_ports eth_rxc]
set_property -dict {PACKAGE_PIN V19  IOSTANDARD LVCMOS33} [get_ports eth_rx_ctl]

# RGMII 是 125 MHz 边沿，必须是 FAST + 8 mA（板级 50 Ω 走线，参考正点原子例程）
set_property SLEW FAST [get_ports {eth_txd[*] eth_txc eth_tx_ctl}]
set_property DRIVE 8   [get_ports {eth_txd[*] eth_txc eth_tx_ctl}]
set_property SLEW SLOW [get_ports phy_rst_n]
set_property DRIVE 4   [get_ports phy_rst_n]

# ---- 2. 时钟 ---------------------------------------------------------------
# RX 时钟由 PHY 提供（1000BASE-X 时 125 MHz；自协商到 1000 Mbps 才成立）
create_clock -name eth_rxc_clk -period 8.000 [get_ports eth_rxc]

# TX 时钟：MMCM 的 125 MHz 输出，经 rgmii_if 里的 ODDR 前向输出到 eth_txc
create_generated_clock -name eth_txc_out \
    -source [get_pins u_eth/u_rgmii/u_oddr_clk/C] \
    -divide_by 1 \
    [get_ports eth_txc]

# ---- 3. 输入延时（RX）-----------------------------------------------------
# v61 起 RX 采样改成 BUFIO + IDELAYE2(VAR_LOAD)：IDDR 的采样时钟走 IO 时钟网，
# 不再借用 BUFG 的插入延迟，所以 input delay 必须按 PHY 的**真实**输出延时建模，
# 不能再用 4.5 ns 这种"被 BUFG 吃掉"的凑数值（BUFIO 下会直接 WNS -0.293）。
#
# YT8531C 默认开 RGMII 内部延时（等价 RGMII-ID），数据相对 RXC 边沿后移约 2 ns，
# 数据手册给的是 2.0 ns ±0.3；这里按 1.7..2.3 ns 建模。
# （1.5 会把 hold 卡到 -0.001 ns —— 刚好压在边沿上，没有任何余量。）
set_input_delay -clock eth_rxc_clk -max 2.300 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock eth_rxc_clk -min 1.700 [get_ports {eth_rxd[*] eth_rx_ctl}]

# ---- 4. 输出延时（TX）-----------------------------------------------------
# 时钟与数据同相前向输出（RGMII 规范允许 ±0.5 ns skew），这里先按 ±1.5 ns 预算。
set_output_delay -clock eth_txc_out -max 1.500 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock eth_txc_out -min 0.500 [get_ports {eth_txd[*] eth_tx_ctl}]

# ---- 5. 时钟域关系 ---------------------------------------------------------
# eth_rxc 来自外部 PHY，与板上 50 MHz 晶振无相位关系，必须声明异步。
# TX 侧（eth_txc_out）与 clk_125 都由 MMCM 从 sys_clk 派生，与 sys_clk 同步，
# 因此用 -include_generated_clocks 把它们一起归到 sys 组，不能放进异步组。
set_clock_groups -asynchronous \
    -group [get_clocks eth_rxc_clk] \
    -group [get_clocks -include_generated_clocks sys_clk]

# 50 MHz ↔ 125 MHz 之间的**全部**跨域路径都是按 CDC 设计的：
#   - 配置位（MAC/IP/端口/抽取）：两级触发器同步；
#   - 统计计数器（tx_pkt / udp_pkts 等）：格雷码 + 两级同步；
#   - start_tgl：三级同步。
# 它们虽然同源（MMCM 派生），但不能按同域时序分析，否则工具会把
# "同步器第一级"当成普通路径，报出 −6 ns 的假违例。用 datapath_only
# 把时钟偏斜/不确定度拿掉，只约束走线（3 ns 对两级同步绰绰有余）。
# 注意：XDC 里不支持 if 语句（会报 Designutils 20-1307），所以这里直接用
# 时钟名过滤；MMCM 输出在综合后的时钟名叫 clk_125_raw（BUFG 前的自动名）。
set_max_delay -datapath_only 3.000 -from [get_clocks sys_clk] -to [get_clocks -filter {NAME =~ *clk_125*}]
set_max_delay -datapath_only 3.000 -from [get_clocks -filter {NAME =~ *clk_125*}] -to [get_clocks sys_clk]

# ---- 6. 复位/静态信号 ------------------------------------------------------
# phy_rst_n 是 10 ms 级慢速电平，不参与任何时钟路径。
set_false_path -from [get_clocks sys_clk] -to [get_ports phy_rst_n]
