# =============================================================================
# impl_ddr3direct.tcl —— MIG 最小闭环自检顶层（不经 ddr3_ring）
#
# 顶层 rtl/ddr3/ddr3_top_direct.v：写 8 个地址 → 冲刷 → 逐个读回 → 串口打全表。
# 位流写工作区根 ddr3_top_direct.bit。
#
# 跑法：
#   pwsh> $env:Path='D:\Vivado\2026.1\Vivado\bin;'+$env:Path
#         vivado -mode batch -nolog -nojournal -source tools/impl_ddr3direct.tcl
# =============================================================================
set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set OUTDIR [file join $::env(TEMP) "_impl_ddr3direct"]
file mkdir $OUTDIR

puts "INFO: ROOT=$ROOT"

read_verilog [file join $ROOT rtl ddr3 ddr3_top_direct.v]
read_verilog [file join $ROOT rtl ddr3 uart_tx_8n1.v]

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
    if {[string match "*_sim.v" $f]} { continue }
    read_verilog $f
}

set mig_xdc [file join $ROOT ip mig_7series_0 mig_7series_0 user_design constraints mig_7series_0.xdc]
if {![file exists $mig_xdc]} {
    puts "ERROR: MIG pin xdc not found: $mig_xdc"
    exit 1
}
read_xdc $mig_xdc
puts "INFO: read MIG pins xdc"

read_xdc [file join $ROOT constr ddr3_top.xdc]

set uartxdc [file join $ROOT constr ddr3_uart_dbg.xdc]
if {[file exists $uartxdc]} {
    read_xdc $uartxdc
    puts "INFO: applied uart_tx pin"
}

set io135 [file join $ROOT constr ddr3_io_135.xdc]
if {[file exists $io135]} {
    read_xdc $io135
    puts "INFO: applied SSTL135 override"
}

synth_design -top ddr3_top_direct -part xc7a35tfgg484-2
write_checkpoint -force [file join $OUTDIR post_synth.dcp]
report_utilization -file [file join $OUTDIR synth_util.rpt]

opt_design
place_design
route_design

report_timing_summary -file [file join $OUTDIR impl_timing.rpt] -delay_type min_max
report_utilization   -file [file join $OUTDIR impl_util.rpt]
report_drc           -file [file join $OUTDIR impl_drc.rpt]
write_checkpoint -force [file join $OUTDIR post_route.dcp]

write_bitstream -force [file join $ROOT ddr3_top_direct.bit]
puts "DDR3DIRECT_IMPL_DONE"
