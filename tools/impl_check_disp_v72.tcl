# -----------------------------------------------------------------------------
#  impl_check_disp_v71.tcl -- v71 DISPLAY build (2048 PPR + 7" LCD + GbE)
#
#  top      : enc_top_disp
#  RTL      : _synth_work_v71/rtl_v71/*.v + .../eth/*.v + disp/*.v (no tb_*)
#  XDC      : constr/enc_top_disp.xdc
#  define   : ENC_DISP_TAP    (read-only disp_tap port in enc_top.v)
#             ENC_V69_CPR2048 (display RPM/revs use 2048 electrical cycles/rev)
#  Output : _impl_disp_v72/enc_top_disp_v72.bit
#
#  Run:
#    powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
#        -Tcl tools/impl_check_disp_v71.tcl -LogFile build_disp_v71.log -Tail 80
#
#  NOTE: keep this file ASCII-only (Vivado reads .tcl via the system code page).
# -----------------------------------------------------------------------------
set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_impl_disp_v72"
file mkdir $OUTDIR

set RTLDIR "$ROOT/_synth_work_v71/rtl_v71"
set src_rtl  [lsort [glob -nocomplain "$RTLDIR/*.v"]]
set src_eth  [lsort [glob -nocomplain "$RTLDIR/eth/*.v"]]
set src_disp {}
foreach f [lsort [glob -nocomplain "$ROOT/disp/*.v"]] {
    if {[string match "tb_*" [file tail $f]]} { continue }
    lappend src_disp $f
}
set src $src_rtl
foreach f $src_eth  { lappend src $f }
foreach f $src_disp { lappend src $f }

puts "INFO: ============ v71 DISPLAY (2048 PPR + LCD + eth) ============"
puts "INFO: rtl  files = [llength $src_rtl]"
puts "INFO: eth  files = [llength $src_eth]"
puts "INFO: disp files = [llength $src_disp]"
puts "INFO: total      = [llength $src]"

foreach f $src { read_verilog $f }

read_xdc "$ROOT/constr/enc_top_disp.xdc"

synth_design -top enc_top_disp -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt \
             -verilog_define {ENC_DISP_TAP ENC_V69_CPR2048}

opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

report_utilization        -file "$OUTDIR/impl_util.rpt"
report_timing_summary     -file "$OUTDIR/impl_timing.rpt"
report_drc                -file "$OUTDIR/impl_drc.rpt"
report_route_status       -file "$OUTDIR/impl_route.rpt"
report_clock_interaction  -file "$OUTDIR/impl_clkint.rpt"
report_io                 -file "$OUTDIR/impl_io.rpt"
check_timing -verbose     -file "$OUTDIR/impl_check_timing.rpt"
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/impl_top_paths.rpt"
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file "$OUTDIR/impl_hold_paths.rpt"
report_timing -delay_type max -max_paths 10 -group eth_rxc_clk \
    -file "$OUTDIR/impl_eth_rx_paths.rpt"

write_bitstream -force "$OUTDIR/enc_top_disp_v72.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_disp_v72.bit"

puts "IMPL_DISP_V69_DONE"
exit
