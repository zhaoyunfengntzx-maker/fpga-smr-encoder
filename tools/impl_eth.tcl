# -----------------------------------------------------------------------------
#  tools/impl_eth.tcl —— B2 以太网版本的完整实现验证（综合→布局→布线→时序→bit）
#
#  与 tools/impl_check.tcl 的区别：把 rtl/eth/*.v 一起读进来，输出目录放到
#  $TEMP（工作区被只读挂载/沙箱限制时也能跑），最后写 bitstream。
#
#  运行（必须先把 HOME/APPDATA/TEMP 指到可写目录，否则 Vivado 报
#  "Failed to create directory to save app.xml at 'C'"）：
#    vivado -mode batch -nolog -nojournal -source tools/impl_eth.tcl
#
#  结果：$env:TEMP\_impl_eth\{impl_util.rpt, impl_timing.rpt, impl_drc.rpt,
#        impl_route.rpt, impl_clkint.rpt, enc_top.bit}
# -----------------------------------------------------------------------------
set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "[file join $::env(TEMP) _impl_eth]"
file mkdir $OUTDIR
puts "INFO: OUTDIR=$OUTDIR"

set src [glob -nocomplain "$ROOT/rtl/*.v"]
set src [concat $src [glob -nocomplain "$ROOT/rtl/eth/*.v"]]
puts "INFO: reading [llength $src] RTL files"
foreach f $src { read_verilog $f }

read_xdc "$ROOT/constr/enc_top.xdc"
if {[file exists "$ROOT/constr/enc_top_eth.xdc"]} {
    read_xdc "$ROOT/constr/enc_top_eth.xdc"
}

synth_design -top enc_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

opt_design
place_design
route_design

report_utilization    -file "$OUTDIR/impl_util.rpt"
report_timing_summary -file "$OUTDIR/impl_timing.rpt"
report_drc            -file "$OUTDIR/impl_drc.rpt"
report_route_status   -file "$OUTDIR/impl_route.rpt"
report_clock_interaction -file "$OUTDIR/impl_clkint.rpt"

write_bitstream -force "$OUTDIR/enc_top.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top.bit"
puts "IMPL_ETH_DONE"
