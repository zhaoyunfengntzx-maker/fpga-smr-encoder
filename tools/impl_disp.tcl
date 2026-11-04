# -----------------------------------------------------------------------------
#  tools/impl_disp.tcl  -- merged (encoder + display engine) IMPLEMENTATION
#
#  Purpose: get the REAL post-route WNS/WHS for the merged design, and answer
#  whether the 12 failing endpoints seen in merged SYNTHESIS survive into a
#  routed design.
#
#  Flow is deliberately IDENTICAL to tools/impl_check.tcl (which produced the
#  encoder v12 sign-off, WNS +0.959 / 0 failing at 2026-10-12 23:59):
#      synth_design -> opt_design -> place_design -> route_design
#  No phys_opt_design, so the two runs stay comparable.
#
#  Run (always through the sandbox wrapper -- Vivado needs HOME/APPDATA pinned
#  or it dies with ERROR: [Common 17-1219] Failed to create directory to save
#  app.xml at 'C'):
#    powershell -File tools\run_vivado.ps1 -Tcl tools\impl_disp.tcl `
#        -LogFile _disp_work\impl_disp.log -Tail 60
#
#  Outputs land in _disp_work/ so the encoder sign-off reports stay untouched.
#
#  NOTE: keep this file ASCII-only. Vivado reads .tcl through the system code
#  page, so non-ASCII bytes here become garbage on a non-UTF8 console.
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_disp_work"
file mkdir $OUTDIR

# ---- 0. source list: rtl/*.v (encoder) + disp/*.v (display engine) ----
#  disp/tb_*.v are testbenches and must NOT be read as design sources; the
#  glob would otherwise sweep them in (they live in disp/ so that
#  tools/run_sim_disp.py owns them without disturbing the sim/ baseline).
set src_rtl  [lsort [glob -nocomplain "$ROOT/rtl/*.v"]]
#  rtl/eth/*.v is a subfolder, so the glob above misses it -- enc_top.v
#  instantiates eth_top from there and synth_design would fail with
#  "module 'eth_top' not found" without this line (tools/impl_check.tcl
#  has the same two-glob pattern).
set src_rtl  [concat $src_rtl [lsort [glob -nocomplain "$ROOT/rtl/eth/*.v"]]]
set src_disp {}
foreach f [lsort [glob -nocomplain "$ROOT/disp/*.v"]] {
    if {[string match "tb_*" [file tail $f]]} { continue }
    lappend src_disp $f
}
set src $src_rtl
foreach f $src_disp { lappend src $f }

puts "INFO: ============ MERGED IMPLEMENTATION (enc_top_disp) ============"
puts "INFO: rtl  files = [llength $src_rtl]"
puts "INFO: disp files = [llength $src_disp]"
foreach f $src_disp { puts "INFO:   disp <- [file tail $f]" }
puts "INFO: total = [llength $src] files"

# ---- 1. read RTL ----
foreach f $src { read_verilog $f }

# ---- 2. read merged constraints ----
read_xdc "$ROOT/constr/enc_top_disp.xdc"

# ---- 3. synthesize ----
#  -verilog_define ENC_DISP_TAP enables the read-only tap port in rtl/enc_top.v.
#  This macro must NEVER appear in a production build script (see the comments
#  in tools/synth_disp.tcl and rtl/enc_top.v around line 124).
synth_design -top enc_top_disp -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt \
             -verilog_define ENC_DISP_TAP

# ---- 4. implement ----
opt_design
place_design
route_design

# ---- 5. reports ----
report_utilization        -file "$OUTDIR/impl_util.rpt"
report_timing_summary     -file "$OUTDIR/impl_timing.rpt"
report_drc                -file "$OUTDIR/impl_drc.rpt"
report_route_status       -file "$OUTDIR/impl_route.rpt"
report_clock_interaction  -file "$OUTDIR/impl_clkint.rpt"

report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/impl_top_paths.rpt"
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file "$OUTDIR/impl_hold_paths.rpt"

# ---- 6. bitstream: final proof that every port has a PACKAGE_PIN ----
write_bitstream -force "$OUTDIR/enc_top_disp.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_disp.bit"

# ---- 7. print the headline numbers so the log alone is enough ----
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "INFO: ============ RESULT ============"
puts "INFO: WNS = $wns ns"
puts "INFO: WHS = $whs ns"
puts "IMPL_DISP_DONE"
