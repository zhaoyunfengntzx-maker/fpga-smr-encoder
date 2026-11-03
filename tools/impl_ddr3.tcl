# =============================================================================
# impl_ddr3.tcl —— DDR3 自检顶层的综合 + 实现
#
# 与 tools/impl_eth.tcl 的区别：
#   * 顶层是 rtl/ddr3/ddr3_top.v（不是 enc_top）
#   * 要 read_ip 读入 MIG（ip/mig_7series_0/mig_7series_0.xci）
#   * DDR3 引脚约束来自 MIG 自己生成的 xdc，不读 constr/ddr3_pins.xdc
#     （那份是给"不走 MIG 时"或核对用的；两套同时读会冲突）
#
# 跑法：
#   tools/run_vivado.ps1 -Tcl tools/impl_ddr3.tcl -LogFile ddr3_impl.log
# 或直接：
#   vivado -mode batch -nolog -nojournal -source tools/impl_ddr3.tcl
# =============================================================================
set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set OUTDIR [file join $::env(TEMP) "_impl_ddr3"]
file mkdir $OUTDIR

puts "INFO: ROOT=$ROOT"
puts "INFO: OUTDIR=$OUTDIR"

read_verilog [file join $ROOT rtl ddr3 ddr3_top.v]

# MIG IP：非工程模式下 read_ip 只是登记，不会把 RTL 加进来。
# 直接把生成出来的 user_design/rtl 全部读进来（约 60 个文件），
# 比 "read_checkpoint -cell" 更稳，也不依赖 OOC 综合产物。
set mig_rtl_root [file join $ROOT ip mig_7series_0 mig_7series_0 user_design rtl]
set mig_rtl [concat \
    [glob -nocomplain -directory $mig_rtl_root *.v] \
    [glob -nocomplain -directory [file join $mig_rtl_root clocking] *.v] \
    [glob -nocomplain -directory [file join $mig_rtl_root controller] *.v] \
    [glob -nocomplain -directory [file join $mig_rtl_root ecc] *.v] \
    [glob -nocomplain -directory [file join $mig_rtl_root ip_top] *.v] \
    [glob -nocomplain -directory [file join $mig_rtl_root phy] *.v] \
    [glob -nocomplain -directory [file join $mig_rtl_root ui] *.v] ]
puts "INFO: MIG rtl files = [llength $mig_rtl]"
if {[llength $mig_rtl] < 40} {
    puts "ERROR: MIG rtl 文件不全，检查 ip/mig_7series_0 是否拷全"
    exit 1
}
foreach f [lsort $mig_rtl] {
    # 排除仿真模型：*_sim.v 会把真实模块的名字覆盖掉
    if {[string match "*_sim.v" $f]} { continue }
    read_verilog $f
}
set mig_xdc [file join $ROOT ip mig_7series_0 mig_7series_0 user_design constraints mig_7series_0.xdc]
if {[file exists $mig_xdc]} {
    read_xdc $mig_xdc
    puts "INFO: read MIG pins xdc"
} else {
    puts "ERROR: MIG pin xdc not found: $mig_xdc"
    exit 1
}

read_xdc [file join $ROOT constr ddr3_top.xdc]

# 把 MIG 生成的 SSTL15 覆盖成 SSTL135：BANK35 实测 1.35 V（2026-10-19 用户万用表确认）。
# 必须排在 MIG 的 pin xdc 之后，后写的约束生效。
set io135 [file join $ROOT constr ddr3_io_135.xdc]
if {[file exists $io135]} {
    read_xdc $io135
    puts "INFO: applied SSTL135 override"
}

synth_design -top ddr3_top -part xc7a35tfgg484-2
write_checkpoint -force [file join $OUTDIR post_synth.dcp]
report_utilization -file [file join $OUTDIR synth_util.rpt]

opt_design
place_design
route_design

report_timing_summary -file [file join $OUTDIR impl_timing.rpt] -delay_type min_max
report_utilization   -file [file join $OUTDIR impl_util.rpt]
report_drc           -file [file join $OUTDIR impl_drc.rpt]
write_checkpoint -force [file join $OUTDIR post_route.dcp]
write_bitstream -force [file join $OUTDIR ddr3_top.bit]

puts "DDR3_IMPL_DONE"
