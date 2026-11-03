# ============================================================================
# ddr3_pins.xdc —— 板载 DDR3（NT5CC128M16JR-EK，256 MB，x16，BANK35，1.35 V）
#
# 来源：`_v11_verify/达芬奇Lite开发板IO引脚分配表.xlsx`（与《达芬奇-lite 之 FPGA
#       开发指南》第十七章 / 表 2.1.1 的 DDR3 段一致，已逐脚核对）。
# 生成：`_gen_ddr3_xdc.py`（改板/改表后重跑，不要手改本文件）。
#
# 用法：MIG IP 用 "Fixed" 引脚选择时不认外部 LOC；本项目用 MIG 的 "System" 生成
#       后在 `tools/impl_check.tcl` 里用 `-used_in synthesis` 排除 MIG 自带的
#       pin xdc，改由本文件约束（见 docs/18 §4.3）。
# ============================================================================

# 地址线位0  M5
set_property -dict {PACKAGE_PIN M5 IOSTANDARD SSTL135} [get_ports {ddr3_addr[0]}]
# 地址线位1  J4
set_property -dict {PACKAGE_PIN J4 IOSTANDARD SSTL135} [get_ports {ddr3_addr[1]}]
# 地址线位2  K4
set_property -dict {PACKAGE_PIN K4 IOSTANDARD SSTL135} [get_ports {ddr3_addr[2]}]
# 地址线位3  N2
set_property -dict {PACKAGE_PIN N2 IOSTANDARD SSTL135} [get_ports {ddr3_addr[3]}]
# 地址线位4  N4
set_property -dict {PACKAGE_PIN N4 IOSTANDARD SSTL135} [get_ports {ddr3_addr[4]}]
# 地址线位5  L5
set_property -dict {PACKAGE_PIN L5 IOSTANDARD SSTL135} [get_ports {ddr3_addr[5]}]
# 地址线位6  K6
set_property -dict {PACKAGE_PIN K6 IOSTANDARD SSTL135} [get_ports {ddr3_addr[6]}]
# 地址线位7  L3
set_property -dict {PACKAGE_PIN L3 IOSTANDARD SSTL135} [get_ports {ddr3_addr[7]}]
# 地址线位8  L1
set_property -dict {PACKAGE_PIN L1 IOSTANDARD SSTL135} [get_ports {ddr3_addr[8]}]
# 地址线位9  M1
set_property -dict {PACKAGE_PIN M1 IOSTANDARD SSTL135} [get_ports {ddr3_addr[9]}]
# 地址线位10  J6
set_property -dict {PACKAGE_PIN J6 IOSTANDARD SSTL135} [get_ports {ddr3_addr[10]}]
# 地址线位11  M3
set_property -dict {PACKAGE_PIN M3 IOSTANDARD SSTL135} [get_ports {ddr3_addr[11]}]
# 地址线位12  M2
set_property -dict {PACKAGE_PIN M2 IOSTANDARD SSTL135} [get_ports {ddr3_addr[12]}]
# 地址线位13  K3
set_property -dict {PACKAGE_PIN K3 IOSTANDARD SSTL135} [get_ports {ddr3_addr[13]}]
# Bank地址位0  P2
set_property -dict {PACKAGE_PIN P2 IOSTANDARD SSTL135} [get_ports {ddr3_ba[0]}]
# Bank地址位1  P1
set_property -dict {PACKAGE_PIN P1 IOSTANDARD SSTL135} [get_ports {ddr3_ba[1]}]
# Bank地址位2  M6
set_property -dict {PACKAGE_PIN M6 IOSTANDARD SSTL135} [get_ports {ddr3_ba[2]}]
# 列地址选通  N5
set_property -dict {PACKAGE_PIN N5 IOSTANDARD SSTL135} [get_ports {ddr3_cas_n}]
# 行地址选通  P6
set_property -dict {PACKAGE_PIN P6 IOSTANDARD SSTL135} [get_ports {ddr3_ras_n}]
# 写使能  L4
set_property -dict {PACKAGE_PIN L4 IOSTANDARD SSTL135} [get_ports {ddr3_we_n}]
# 片选信号  L6
set_property -dict {PACKAGE_PIN L6 IOSTANDARD SSTL135} [get_ports {ddr3_cs_n[0]}]
# 时钟使能  N3
set_property -dict {PACKAGE_PIN N3 IOSTANDARD SSTL135} [get_ports {ddr3_cke[0]}]
# 片上终端电阻控制  R1
set_property -dict {PACKAGE_PIN R1 IOSTANDARD SSTL135} [get_ports {ddr3_odt[0]}]
# 差分时钟正端  P5
set_property -dict {PACKAGE_PIN P5 IOSTANDARD SSTL135} [get_ports {ddr3_ck_p[0]}]
# 差分时钟负端  P4
set_property -dict {PACKAGE_PIN P4 IOSTANDARD SSTL135} [get_ports {ddr3_ck_n[0]}]
# 数据线位0  C2
set_property -dict {PACKAGE_PIN C2 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[0]}]
# 数据线位1  G1
set_property -dict {PACKAGE_PIN G1 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[1]}]
# 数据线位2  A1
set_property -dict {PACKAGE_PIN A1 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[2]}]
# 数据线位3  F3
set_property -dict {PACKAGE_PIN F3 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[3]}]
# 数据线位4  B2
set_property -dict {PACKAGE_PIN B2 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[4]}]
# 数据线位5  F1
set_property -dict {PACKAGE_PIN F1 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[5]}]
# 数据线位6  B1
set_property -dict {PACKAGE_PIN B1 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[6]}]
# 数据线位7  E2
set_property -dict {PACKAGE_PIN E2 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[7]}]
# 数据线位8  H3
set_property -dict {PACKAGE_PIN H3 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[8]}]
# 数据线位9  G3
set_property -dict {PACKAGE_PIN G3 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[9]}]
# 数据线位10  H2
set_property -dict {PACKAGE_PIN H2 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[10]}]
# 数据线位11  H5
set_property -dict {PACKAGE_PIN H5 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[11]}]
# 数据线位12  J1
set_property -dict {PACKAGE_PIN J1 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[12]}]
# 数据线位13  J5
set_property -dict {PACKAGE_PIN J5 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[13]}]
# 数据线位14  K1
set_property -dict {PACKAGE_PIN K1 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[14]}]
# 数据线位15  H4
set_property -dict {PACKAGE_PIN H4 IOSTANDARD SSTL135_T} [get_ports {ddr3_dq[15]}]
# 数据掩码0  D2
set_property -dict {PACKAGE_PIN D2 IOSTANDARD SSTL135} [get_ports {ddr3_dm[0]}]
# 数据掩码1  G2
set_property -dict {PACKAGE_PIN G2 IOSTANDARD SSTL135} [get_ports {ddr3_dm[1]}]
# 数据选通正端0  E1
set_property -dict {PACKAGE_PIN E1 IOSTANDARD SSTL135} [get_ports {ddr3_dqs_p[0]}]
# 数据选通负端0  D1
set_property -dict {PACKAGE_PIN D1 IOSTANDARD SSTL135} [get_ports {ddr3_dqs_n[0]}]
# 数据选通正端1  K2
set_property -dict {PACKAGE_PIN K2 IOSTANDARD SSTL135} [get_ports {ddr3_dqs_p[1]}]
# 数据选通负端1  J2
set_property -dict {PACKAGE_PIN J2 IOSTANDARD SSTL135} [get_ports {ddr3_dqs_n[1]}]
# 低电平有效复位信号  F4
set_property -dict {PACKAGE_PIN F4 IOSTANDARD SSTL135} [get_ports {ddr3_reset_n}]

# DCI 终端：DDR3 的 DQ/DQS 用 IN_TERM=T40（板上是 40 Ω 对 VTT）
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[0]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[1]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[2]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[3]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[4]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[5]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[6]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[7]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[8]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[9]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[10]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[11]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[12]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[13]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[14]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dq[15]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dqs_p[0]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dqs_n[0]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dqs_p[1]}]
set_property IN_TERM {UNTUNED_SPLIT_40} [get_ports {ddr3_dqs_n[1]}]
