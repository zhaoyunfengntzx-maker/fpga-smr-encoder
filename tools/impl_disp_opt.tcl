# -----------------------------------------------------------------------------
#  tools/impl_disp_opt.tcl  -- merged implementation, TIMING-MARGIN variant
#
#  Why this file exists
#  --------------------
#  tools/impl_disp.tcl runs the deliberately plain, COMPARABLE flow
#        synth_design -> opt_design -> place_design -> route_design
#  with no directives and no phys_opt_design, so its numbers can be set beside
#  the encoder v12 sign-off run.
#
#  After the LCD red/blue ball swap (2026-10-15) moved the I/O placement, that
#  plain flow came back with WNS +0.147 / WHS +0.057 ns. Timing is MET, but
#  0.147 ns is only 0.7% of the 20 ns period, so this variant spends extra
#  runtime to buy the margin back.
#
#  It changes ONLY the implementation directives. Source list, constraints,
#  top, part and report set are identical, so the two bitstreams are
#  functionally interchangeable -- this one is just better placed.
#
#  Flow
#  ----
#        synth_design
#        opt_design
#        place_design    -directive ExtraTimingOpt
#        phys_opt_design -directive AggressiveExplore
#        route_design    -directive Explore
#        phys_opt_design -directive AggressiveExplore
#
#  Every output uses the *_opt suffix, so a margin run can never overwrite the
#  baseline reports in _disp_work/.
#
#  NOTE: keep this file ASCII-only. Vivado reads .tcl through the system code
#  page, so non-ASCII bytes here become garbage on a non-UTF8 console.
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_disp_work"
file mkdir $OUTDIR

# ---- 0. source list: rtl/*.v (encoder) + disp/*.v (display engine) ----
#  disp/tb_*.v are testbenches and must NOT be read as design sources.
set src_rtl  [lsort [glob -nocomplain "$ROOT/rtl/*.v"]]
set src_disp {}
foreach f [lsort [glob -nocomplain "$ROOT/disp/*.v"]] {
    if {[string match "tb_*" [file tail $f]]} { continue }
    lappend src_disp $f
}
set src $src_rtl
foreach f $src_disp { lappend src $f }

puts "INFO: ====== MERGED IMPLEMENTATION (enc_top_disp) -- MARGIN VARIANT ======"
puts "INFO: rtl  files = [llength $src_rtl]"
puts "INFO: disp files = [llength $src_disp]"
puts "INFO: total = [llength $src] files"

# ---- 1. read RTL ----
foreach f $src { read_verilog $f }

# ---- 2. read merged constraints ----
read_xdc "$ROOT/constr/enc_top_disp.xdc"

# ---- 3. synthesize (identical to the baseline) ----
synth_design -top enc_top_disp -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt \
             -verilog_define ENC_DISP_TAP

# ---- 4. implement, with margin-recovery directives ----
opt_design
place_design    -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design    -directive Explore
phys_opt_design -directive AggressiveExplore

# ---- 5. reports (the *_opt set, never the baseline names) ----
report_utilization        -file "$OUTDIR/opt_util.rpt"
report_timing_summary     -file "$OUTDIR/opt_timing.rpt"
report_drc                -file "$OUTDIR/opt_drc.rpt"
report_route_status       -file "$OUTDIR/opt_route.rpt"
report_clock_interaction  -file "$OUTDIR/opt_clkint.rpt"

report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/opt_top_paths.rpt"
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file "$OUTDIR/opt_hold_paths.rpt"

# ---- 6. bitstream ----
write_bitstream -force "$OUTDIR/enc_top_disp_opt.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_disp_opt.bit"

# ---- 7. headline numbers ----
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "INFO: ============ RESULT (MARGIN VARIANT) ============"
puts "INFO: WNS_OPT = $wns ns"
puts "INFO: WHS_OPT = $whs ns"
puts "IMPL_DISP_OPT_DONE"
