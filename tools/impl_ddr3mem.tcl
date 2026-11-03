# =============================================================================
# impl_ddr3mem.tcl —— DDR3 深存储验证顶层（1 M 点写入 + 回读 + 逐点比对）
#
# 与 impl_ddr3.tcl 的区别：
#   * 顶层是 rtl/ddr3/ddr3_top_mem.v
#   * 多了 rtl/eth/async_fifo.v 与 rtl/ddr3/ddr3_ring.v
#   * 位流直接写到工作区根目录 ddr3_top_mem.bit（沙箱只允许写工作区根）
#
# 跑法：
#   pwsh> $env:Path='D:\Vivado\2026.1\Vivado\bin;'+$env:Path
#         vivado -mode batch -nolog -nojournal -source tools/impl_ddr3mem.tcl
# =============================================================================
set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set OUTDIR [file join $::env(TEMP) "_impl_ddr3mem"]
file mkdir $OUTDIR

puts "INFO: ROOT=$ROOT"

read_verilog [file join $ROOT rtl eth async_fifo.v]
read_verilog [file join $ROOT rtl ddr3 ddr3_ring.v]
read_verilog [file join $ROOT rtl ddr3 ddr3_top_mem.v]
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

synth_design -top ddr3_top_mem -part xc7a35tfgg484-2
write_checkpoint -force [file join $OUTDIR post_synth.dcp]
report_utilization -file [file join $OUTDIR synth_util.rpt]

opt_design
place_design
route_design

report_timing_summary -file [file join $OUTDIR impl_timing.rpt] -delay_type min_max
report_utilization   -file [file join $OUTDIR impl_util.rpt]
report_drc           -file [file join $OUTDIR impl_drc.rpt]
write_checkpoint -force [file join $OUTDIR post_route.dcp]

# 位流写工作区根（沙箱允许），再人工/脚本归档到 deliverables
write_bitstream -force [file join $ROOT ddr3_top_mem.bit]
puts "DDR3MEM_IMPL_DONE"
