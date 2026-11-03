# -----------------------------------------------------------------------------
#  lcd_test/tools/synth_lcd_test.tcl  —— LCD 测试程序的综合验证脚本
#
#  运行：
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#        -Tcl lcd_test\tools\synth_lcd_test.tcl -LogFile _lcd_work\synth_lcd.log -Tail 60
#
#  验证内容：
#    1) lcd_test/rtl/*.v 能否被真实综合器接受
#    2) lcd_test_top 能否精化通过、lcd_test.xdc 的 34 个引脚是否存在/冲突
#    3) 资源占用与 WNS/TNS
#    4) ★ 24 根 lcd_rgb 是否真的被推断成双向 IOBUF（这是本设计的核心硬件前提：
#       读屏 ID 时它们必须是高阻，否则读不到 ID 还可能和屏模块的电阻打架）
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set RTL    "$ROOT/lcd_test/rtl"
set OUTDIR "$ROOT/_lcd_work/synth_lcd"
file mkdir $OUTDIR

set src [glob -nocomplain "$RTL/*.v"]
puts "INFO: reading [llength $src] lcd_test RTL files"
foreach f $src { read_verilog $f }

read_xdc "$ROOT/lcd_test/constr/lcd_test.xdc"

synth_design -top lcd_rgb_test_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

report_utilization    -file "$OUTDIR/util.rpt"
report_timing_summary  -file "$OUTDIR/timing.rpt"
report_drc             -file "$OUTDIR/drc.rpt"
report_clock_networks  -file "$OUTDIR/clocks.rpt"
report_io              -file "$OUTDIR/io.rpt"

# 双向 IOBUF 检查：真正需要"能读回来"的只有 5 根 ——
#   lcd_rgb[7]/[15]/[23]（屏 ID 的 B7/G7/R7，读 ID 时必须当输入）
#   touch_scl / touch_sda（开漏 IIC）
# 其余 21 根 lcd_rgb 只输出，综合器会把它们做成 OBUFT（不带输入缓冲），这是对的、也更省。
set iobufs [get_cells -hier -filter {REF_NAME =~ IOBUF*}]
puts "IOBUF_CHECK: [llength $iobufs] 个 IOBUF（期望 5）"
foreach c $iobufs { puts "  IOBUF: $c" }

set io_ports [get_ports -filter {DIRECTION == INOUT}]
puts "INOUT_PORTS: [llength $io_ports] 个双向端口：$io_ports"

puts "SYNTH_LCD_TEST_DONE"
