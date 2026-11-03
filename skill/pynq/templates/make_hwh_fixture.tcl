# 重新生成 skill/pynq/examples/ 里的 .hwh 夹具
#
# 背景：本机 Vivado 2026.1 只装了 Artix/Kintex 器件族（BASIC license），
# create_project -part xc7z020clg400-1 会报 "Specified part could not be found"，
# 所以造不出 PS7 设计；但 PYNQ 解析的 handoff 格式与器件无关，于是在 Artix-7 上
# 搭一个"两个 AXI-Lite 从口"的 BD，导出结构同源的 .hwh。
#
# 用法（本仓库实测通过）：
#   vivado -mode batch -source skill/pynq/templates/make_hwh_fixture.tcl -tclargs <输出目录> [part]
#   默认 part 为 xc7a35tfgg484-2，输出目录默认 %TEMP%/pynq_hwh_fixture
#
# 产物：<输出目录>/pynq_a7.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh
#   把它复制成 examples/real_bd/design_1.hwh，再按 examples/README.md 的说明
#   往 MODULES 里补 <MEMRANGES>（属性口径见该 README）。
#
# 失效条件：
#   - 换 Vivado 大版本后 BD 的 IP 版本号会变（vlnv 里的 :2.0 / :4.1 / :8.4 要跟着改）；
#   - 没有 hw_handoff 目标（老版本叫 export_hardware）时要改成对应命令；
#   - 只导出 handoff，不跑实现，所以产物里没有位流，也不能当 overlay 用。

set part xc7a35tfgg484-2
set outdir ""
if {[llength $argv] >= 1} { set outdir [lindex $argv 0] }
if {[llength $argv] >= 2} { set part [lindex $argv 1] }
if {$outdir eq ""} {
    set outdir [file join $::env(TEMP) pynq_hwh_fixture]
}

puts "PART:   $part"
puts "OUTDIR: $outdir"

create_project -force pynq_a7 $outdir -part $part
set_property target_language Verilog [current_project]

create_bd_design "design_1"

# --- 从口 1：AXI GPIO（最典型的"一个寄存器块"） ---
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio_regs
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {0} \
                         CONFIG.C_IS_DUAL {0}] [get_bd_cells gpio_regs]
make_bd_intf_pins_external -name S_AXI_GPIO [get_bd_intf_pins gpio_regs/S_AXI]

create_bd_port -dir I -type clk -freq_hz 100000000 aclk
connect_bd_net [get_bd_pins gpio_regs/s_axi_aclk] [get_bd_ports aclk]
create_bd_port -dir I -type rst arstn
connect_bd_net [get_bd_pins gpio_regs/s_axi_aresetn] [get_bd_ports arstn]

# --- 从口 2：AXI BRAM Controller + BRAM（典型的"带地址范围"的从口） ---
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 bram
set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} \
                         CONFIG.Write_Width_A {32} CONFIG.Read_Width_A {32} \
                         CONFIG.Write_Depth_A {1024}] [get_bd_cells bram]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 bram_ctrl
set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.DATA_WIDTH {32}] [get_bd_cells bram_ctrl]
make_bd_intf_pins_external -name S_AXI_BRAM [get_bd_intf_pins bram_ctrl/S_AXI]
connect_bd_intf_net [get_bd_intf_pins bram_ctrl/BRAM_PORTA] [get_bd_intf_pins bram/BRAM_PORTA]
connect_bd_net [get_bd_pins bram_ctrl/s_axi_aclk] [get_bd_ports aclk]
connect_bd_net [get_bd_pins bram_ctrl/s_axi_aresetn] [get_bd_ports arstn]

# 注意：把接口引出用 make_bd_intf_pins_external -name，
# 不要对 create_bd_intf_port 的结果再 set_property name（会报
# "No interface ports matched" + "'set_property' expects at least one object"）。

regenerate_bd_layout
save_bd_design

# 只导出 handoff（PYNQ 只读这个文件）
generate_target {hw_handoff} [get_files design_1.bd]

set hwhs [get_files -quiet *.hwh]
foreach f $hwhs { puts "HWH: $f ([file size $f] bytes)" }
puts "DONE_PYNQ_FIXTURE"
