# =============================================================================
# impl_blink_mmcm.tcl —— 二分定位位流：MMCM 有、MIG 没有
# 产物：$TEMP/_impl_blink_mmcm/blink_mmcm.bit
# =============================================================================
set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set OUTDIR [file join $::env(TEMP) "_impl_blink_mmcm"]
file mkdir $OUTDIR

read_verilog [file join $ROOT rtl ddr3 blink_mmcm.v]
read_xdc     [file join $ROOT constr ddr3_top.xdc]

synth_design -top blink_mmcm -part xc7a35tfgg484-2
opt_design
place_design
route_design

report_timing_summary -file [file join $OUTDIR timing.rpt]
write_bitstream -force [file join $OUTDIR blink_mmcm.bit]

puts "BLINK_MMCM_DONE"
