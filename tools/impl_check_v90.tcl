# -----------------------------------------------------------------------------
#  impl_check_v90.tcl -- v90 PRODUCTION build (2048 PPR turntable)
#
#  Source : _synth_work_v90/rtl_v90  (byte-identical copy of repo rtl/, made by
#           tools/make_v90_rtl.py; RTL_BUILD_ID = 0x0019)
#  Part   : xc7a35tfgg484-2
#  Output : _synth_work_v90/enc_top_v90.bit + prod_*.rpt
#
#  Flow identical to v66..v74 production so the numbers stay comparable:
#    synth_design -> opt -> place ExtraTimingOpt -> phys_opt AggressiveExplore
#    -> route Explore
#
#  Run:
#    vivado -mode batch -source tools/impl_check_v90.tcl -log build_v90.log
#
#  NOTE: keep this file ASCII-only (Vivado reads .tcl via the system code page).
# -----------------------------------------------------------------------------
set ROOT [file normalize [file join [file dirname [info script]] ".."]]
set OUTDIR "$ROOT/_synth_work_v90"
file mkdir $OUTDIR

set RTLDIR "$OUTDIR/rtl_v90"
set src_rtl [lsort [glob -nocomplain "$RTLDIR/*.v"]]
set src_eth [lsort [glob -nocomplain "$RTLDIR/eth/*.v"]]
set src $src_rtl
foreach f $src_eth { lappend src $f }

puts "INFO: ============ v90 PRODUCTION (2048 PPR turntable) ============"
puts "INFO: rtl files = [llength $src_rtl]"
puts "INFO: eth files = [llength $src_eth]"
puts "INFO: total     = [llength $src]"

foreach f $src { read_verilog $f }

read_xdc "$ROOT/constr/enc_top.xdc"
if {[file exists "$ROOT/constr/enc_top_eth.xdc"]} {
    read_xdc "$ROOT/constr/enc_top_eth.xdc"
}

synth_design -top enc_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

report_utilization        -file "$OUTDIR/prod_util.rpt"
report_timing_summary     -file "$OUTDIR/prod_timing.rpt"
report_drc                -file "$OUTDIR/prod_drc.rpt"
report_route_status       -file "$OUTDIR/prod_route.rpt"
report_clock_interaction  -file "$OUTDIR/prod_clkint.rpt"
report_io                 -file "$OUTDIR/prod_io.rpt"
check_timing -verbose     -file "$OUTDIR/prod_check_timing.rpt"
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/prod_top_paths.rpt"
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file "$OUTDIR/prod_hold_paths.rpt"

write_bitstream -force "$OUTDIR/enc_top_v90.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_v90.bit"

puts "IMPL_CHECK_V90_DONE"
exit
