# -----------------------------------------------------------------------------
#  lcd_test2/tools/impl_lcd_test2.tcl —— 第二版 LCD 测试程序的实现 + 位流生成
#
#  运行：
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#        -Tcl lcd_test2\tools\impl_lcd_test2.tcl -LogFile _lcd_work\impl_lcd2.log -Tail 60
#
#  ★ 只在需要真正上板时跑。产物：_lcd_work/impl_lcd2/lcd_test2_top.bit
#  ★ 上板前务必确认：先插好 40P 排线再给板子上电（xdc 注释里有说明）。
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set RTL    "$ROOT/lcd_test2/rtl"
set OUTDIR "$ROOT/_lcd_work/impl_lcd2"
file mkdir $OUTDIR

set src [glob -nocomplain "$RTL/*.v"]
puts "INFO: reading [llength $src] lcd_test2 RTL files"
foreach f $src { read_verilog $f }

read_xdc "$ROOT/lcd_test2/constr/lcd_test2.xdc"

synth_design -top lcd_test2_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

opt_design
place_design
phys_opt_design
route_design

report_utilization     -file "$OUTDIR/util.rpt"
report_timing_summary  -file "$OUTDIR/timing.rpt"
report_drc             -file "$OUTDIR/drc.rpt"
report_io              -file "$OUTDIR/io.rpt"

write_bitstream -force "$OUTDIR/lcd_test2_top.bit"

puts "IMPL_LCD2_DONE"
puts "BITSTREAM: $OUTDIR/lcd_test2_top.bit"
