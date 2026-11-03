# =============================================================================
# impl_ddr3mem_sstl15.tcl —— A/B 对照：用 MIG 原生的 SSTL15，不覆盖成 SSTL135
#
# 背景（2026-10-19 晚）：上板实测 MIG 的 init_calib_complete 从来没起来过
# （只有 MMCM-only 的 blink_mmcm 版 led[1] 亮）。头号怀疑是电平标准：
# BANK35 实测 1.35 V，而 MIG 按 1.5 V 器件生成的是 SSTL15；
# 我们之前用 constr/ddr3_io_135.xdc 覆盖成 SSTL135，VREF 目标也跟着从
# 0.75 V 变成 0.675 V —— 如果覆盖错了，DQ 采样点直接偏掉，校准必然失败。
#
# 这个脚本除了不读 ddr3_io_135.xdc，其余与 impl_ddr3mem.tcl 完全一致，
# 位流写到 ddr3_top_mem_sstl15.bit，方便和另一版做对照。
# =============================================================================
set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set OUTDIR [file join $::env(TEMP) "_impl_ddr3mem_sstl15"]
file mkdir $OUTDIR

puts "INFO: ROOT=$ROOT"
puts "INFO: variant = native SSTL15 (no ddr3_io_135 override)"

read_verilog [file join $ROOT rtl eth async_fifo.v]
read_verilog [file join $ROOT rtl ddr3 ddr3_ring.v]
read_verilog [file join $ROOT rtl ddr3 ddr3_top_mem.v]

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
    puts "ERROR: MIG rtl 文件不全"
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
puts "INFO: read MIG pins xdc (SSTL15)"

read_xdc [file join $ROOT constr ddr3_top.xdc]

# ★ 刻意不读 constr/ddr3_io_135.xdc

synth_design -top ddr3_top_mem -part xc7a35tfgg484-2
report_utilization -file [file join $OUTDIR synth_util.rpt]

opt_design
place_design
route_design

report_timing_summary -file [file join $OUTDIR impl_timing.rpt] -delay_type min_max
report_utilization   -file [file join $OUTDIR impl_util.rpt]
report_drc           -file [file join $OUTDIR impl_drc.rpt]

# 额外把关键报告拷到工作区根（沙箱只允许写这里，方便命令行直接读）
file copy -force [file join $OUTDIR impl_timing.rpt] [file join $ROOT ddr3_sstl15_timing.rpt]
file copy -force [file join $OUTDIR impl_util.rpt]   [file join $ROOT ddr3_sstl15_util.rpt]

write_bitstream -force [file join $ROOT ddr3_top_mem_sstl15.bit]
puts "DDR3MEM_SSTL15_DONE"
