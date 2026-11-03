# =============================================================================
# ddr3_top.xdc —— DDR3 自检顶层的板级约束
#
# DDR3 的 48 根引脚由 MIG 自己生成的
#   ip/mig_7series_0/mig_7series_0/user_design/constraints/mig_7series_0.xdc
# 提供（tools/impl_ddr3.tcl 会 read_xdc 它），本文件只管：
#   * sys_clk（V4，50 MHz）
#   * led[1:0]（AB21 / AB22）
#   * MIG 的 200 MHz 输入时钟约束
# =============================================================================

# ---- 板级时钟 --------------------------------------------------------------
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

# ---- LED -------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33} [get_ports {led[1]}]

# ---- MIG 的 200 MHz 系统时钟由 MMCM 产生，约束由 MIG 自带的 xdc 负责 ------
# （mig_7series_0.xdc 里有 create_clock 与 set_false_path；这里不要再写一遍）

# ---- 配置电压 --------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
