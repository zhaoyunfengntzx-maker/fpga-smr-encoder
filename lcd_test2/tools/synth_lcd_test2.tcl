# -----------------------------------------------------------------------------
#  lcd_test2/tools/synth_lcd_test2.tcl —— 第二版 LCD 测试程序的综合验证脚本
#
#  运行：
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#        -Tcl lcd_test2\tools\synth_lcd_test2.tcl -LogFile _lcd_work\synth_lcd2.log -Tail 60
#
#  验证内容：
#    1) lcd_test2/rtl/*.v 能否被真实综合器接受（screen_pattern / key_ctrl / uart26 都是新增）
#    2) lcd_test2_top 能否精化通过、lcd_test2.xdc 的 34 个引脚是否存在/冲突
#    3) 资源占用与 WNS/TNS
#    4) ★ 24 根 lcd_rgb 里只有 3 根（读屏 ID 的 R7/G7/B7）需要双向；加上开漏 IIC 的
#       touch_scl/touch_sda，共 5 个 IOBUF —— 这是本设计的核心硬件前提：
#       读屏 ID 时它们必须是高阻，否则读不到 ID 还可能和屏模块的电阻打架。
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set RTL    "$ROOT/lcd_test2/rtl"
set OUTDIR "$ROOT/_lcd_work/synth_lcd2"
file mkdir $OUTDIR

set src [glob -nocomplain "$RTL/*.v"]
puts "INFO: reading [llength $src] lcd_test2 RTL files"
foreach f $src { read_verilog $f }

read_xdc "$ROOT/lcd_test2/constr/lcd_test2.xdc"

synth_design -top lcd_test2_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

report_utilization    -file "$OUTDIR/util.rpt"
report_timing_summary  -file "$OUTDIR/timing.rpt"
report_drc             -file "$OUTDIR/drc.rpt"
report_clock_networks  -file "$OUTDIR/clocks.rpt"
report_io              -file "$OUTDIR/io.rpt"

set iobufs [get_cells -hier -filter {REF_NAME =~ IOBUF*}]
puts "IOBUF_CHECK: [llength $iobufs] 个 IOBUF（期望 6：lcd_rgb[7]/[15]/[23] + touch_scl/touch_sda + touch_int）"
foreach c $iobufs { puts "  IOBUF: $c" }

set io_ports [get_ports -filter {DIRECTION == INOUT}]
puts "INOUT_PORTS: [llength $io_ports] 个双向端口：$io_ports"

puts "SYNTH_LCD2_DONE"
