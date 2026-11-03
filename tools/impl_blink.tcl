# =============================================================================
# impl_blink.tcl —— 最小 LED 心跳位流（只用来分清楚"位流有没有在跑"）
#
# 跑法：
#   vivado -mode batch -nolog -nojournal -source tools/impl_blink.tcl
# 产物：$TEMP/_impl_blink/led_blink.bit
# =============================================================================
set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set OUTDIR [file join $::env(TEMP) "_impl_blink"]
file mkdir $OUTDIR

read_verilog [file join $ROOT rtl ddr3 led_blink.v]
read_xdc     [file join $ROOT constr ddr3_top.xdc]

synth_design -top led_blink -part xc7a35tfgg484-2
opt_design
place_design
route_design

report_utilization -file [file join $OUTDIR util.rpt]
report_timing_summary -file [file join $OUTDIR timing.rpt]
write_bitstream -force [file join $OUTDIR led_blink.bit]

puts "BLINK_IMPL_DONE"
