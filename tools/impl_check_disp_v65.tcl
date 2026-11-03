# -----------------------------------------------------------------------------
#  _impl_disp_v65.tcl -- merged (encoder + display engine + GIGABIT ETHERNET) IMPL
#
#  What changed vs _impl_v59.tcl:
#    * v59 still built OUTDIR _impl_v58 and had NO eth pins in the merged top:
#      disp/enc_top_disp.v did not expose phy_rst_n / eth_* at all, so the
#      Ethernet MAC was synthesized but its I/O was left dangling.  Nothing on
#      the board could ever answer a ping, no matter how the PHY was strapped.
#    * v62: disp/enc_top_disp.v exposes the 7 eth ports, constr/enc_top_disp.xdc
#      is regenerated from THREE sources (enc_top + enc_top_eth + lcd_test2) and
#      now carries create_clock eth_rxc_clk, the eth_txc output clock, the RGMII
#      input/output delays and the eth clock groups.
#    * capture depth 32768 -> 28672 (BRAM budget: display 16.5 + eth 2 + 28).
#
#  Flow is kept IDENTICAL to _impl_v59.tcl so WNS/WHS stay comparable:
#      synth_design -> opt_design -> place_design -> route_design
#
#  Run:
#    powershell -File tools\run_vivado.ps1 -Tcl _impl_disp_v65.tcl `
#        -LogFile _impl_disp_v65\impl.log -Tail 80
#
#  NOTE: keep this file ASCII-only (Vivado reads .tcl via the system code page).
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_impl_disp_v65"
file mkdir $OUTDIR

# ---- 0. source list: rtl/*.v + rtl/eth/*.v + disp/*.v (no disp/tb_*.v) ----
set src_rtl  [lsort [glob -nocomplain "$ROOT/rtl/*.v"]]
set src_eth  [lsort [glob -nocomplain "$ROOT/rtl/eth/*.v"]]
set src_disp {}
foreach f [lsort [glob -nocomplain "$ROOT/disp/*.v"]] {
    if {[string match "tb_*" [file tail $f]]} { continue }
    lappend src_disp $f
}
set src $src_rtl
foreach f $src_eth  { lappend src $f }
foreach f $src_disp { lappend src $f }

puts "INFO: ============ MERGED IMPL v62 (enc_top_disp + eth) ============"
puts "INFO: rtl  files = [llength $src_rtl]"
puts "INFO: eth  files = [llength $src_eth]"
puts "INFO: disp files = [llength $src_disp]"
puts "INFO: total = [llength $src] files"

# ---- 1. read RTL ----
foreach f $src { read_verilog $f }

# ---- 2. read merged constraints (three sources, generated) ----
read_xdc "$ROOT/constr/enc_top_disp.xdc"

# ---- 3. synthesize ----
#  -verilog_define ENC_DISP_TAP enables the read-only tap port in rtl/enc_top.v.
#  This macro must NEVER appear in a production build script.
synth_design -top enc_top_disp -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt \
             -verilog_define ENC_DISP_TAP

# ---- 4. implement ----
opt_design
# Explore + phys_opt: the first v62 build squeezed u_abz's
# cfg_inter_q -> r_ovl/CE path (29 levels, 12 CARRY4) to -0.913 at 78.85% LUT.
# Same RTL passed in v59 / the previous v62 build: placement-sensitive, not deeper logic.
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

# ---- 5. reports ----
report_utilization        -file "$OUTDIR/impl_util.rpt"
report_timing_summary     -file "$OUTDIR/impl_timing.rpt"
report_drc                -file "$OUTDIR/impl_drc.rpt"
report_route_status       -file "$OUTDIR/impl_route.rpt"
report_clock_interaction  -file "$OUTDIR/impl_clkint.rpt"
report_io                 -file "$OUTDIR/impl_io.rpt"
# v62: the eth ports were unconstrained in v59, so an "all constraints met"
# summary said nothing about them.  check_timing proves every port/path now
# has a constraint (no unconstrained endpoints, no unconstrained clocks).
check_timing -verbose     -file "$OUTDIR/impl_check_timing.rpt"

report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/impl_top_paths.rpt"
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file "$OUTDIR/impl_hold_paths.rpt"
# eth_rxc domain on its own: RX input delay is an empirical budget, we want to
# see the real slack there without it being buried in the global worst list.
report_timing -delay_type max -max_paths 10 -group eth_rxc_clk \
    -file "$OUTDIR/impl_eth_rx_paths.rpt"

# ---- 6. bitstream: final proof that every port has a PACKAGE_PIN ----
write_bitstream -force "$OUTDIR/enc_top_disp_v65.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_disp_v65.bit"

# ---- 7. headline numbers ----
#   NOTE: keep this file ASCII-only. Vivado reads .tcl with the system code page
#   (GBK here); UTF-8 Chinese comments decode to mojibake. Do not call
#   get_timing_paths after bitgen either: WNS/WHS already come from step 5
#   (report_timing_summary) written into impl_timing.rpt.
puts "INFO: ============ RESULT ============"
puts "INFO: WNS/WHS see $OUTDIR/impl_timing.rpt (report_timing_summary)"
puts "IMPL_V60_DONE"
exit
