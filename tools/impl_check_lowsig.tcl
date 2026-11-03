# -----------------------------------------------------------------------------
#  tools/impl_check_lowsig.tcl  —— v67 小信号传感器生产线
#
#  与 tools/impl_check_v66.tcl 的区别：
#    1) RTL 来自 _synth_work_lowsig/rtl_lowsig/（由 tools/make_lowsig_rtl.py
#       从 rtl/ 复制并只改 3 处：POLE_BITS=6、RTL_BUILD_ID=0x000F、
#       GAIN_S/GAIN_C 复位 49152）。rtl/ 原文件与 v62/v66 位流完全不碰。
#    2) 位流/报告输出到 _impl_lowsig/，不覆盖 _impl_v66/ 的任何产物。
#    3) 拓扑不变：top = enc_top（生产位流；显示 UI 版另行复制）。
#
#  设计意图（详见 docs/29_lowsig_sensor_v67.md）：
#    前端 4.16× 后 200–300 mVpp = 0.416–0.625 FS；默认数字增益 1.5 把它
#    抬到 0.624–0.937 FS，直接落进默认幅值窗 [0.60,1.20]，上电即锁定。
#    64 周期/转 ⇒ POLE_BITS=6、BiSS 22/10、Z 每 64 电周期一个。
#
#  运行：
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_vivado.ps1 `
#        -Tcl tools/impl_check_lowsig.tcl -LogFile _impl_lowsig/vivado.log -Tail 60
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set RTLDIR "$ROOT/_synth_work_lowsig/rtl_lowsig"
set OUTDIR "$ROOT/_impl_lowsig"
file mkdir $OUTDIR

# ---- 1. 读入变体 RTL ----
set src [glob -nocomplain "$RTLDIR/*.v"]
set src [concat $src [glob -nocomplain "$RTLDIR/eth/*.v"]]
if {[llength $src] == 0} {
    error "no RTL under $RTLDIR — 先运行 python tools/make_lowsig_rtl.py"
}
puts "INFO: reading [llength $src] RTL files from $RTLDIR"
foreach f $src { read_verilog $f }

# ---- 2. 读入约束（与 v62/v66 同一套引脚与时钟约束）----
read_xdc "$ROOT/constr/enc_top.xdc"
if {[file exists "$ROOT/constr/enc_top_eth.xdc"]} {
    read_xdc "$ROOT/constr/enc_top_eth.xdc"
}

# ---- 3. 综合 ----
synth_design -top enc_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

# ---- 4. 实现流程 ----
# 沿用 v66 的 ExtraTimingOpt / AggressiveExplore / Explore：
# v66 在 52.48% LUT 上拿到 WNS +0.186；v67 的 POLE_BITS=6 更小，
# 预期时序余量不差于 v66。若首版余量仍薄，再改策略。
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

# ---- 5. 报告 ----
report_utilization        -file "$OUTDIR/impl_util_lowsig.rpt"
report_timing_summary     -file "$OUTDIR/impl_timing_lowsig.rpt"
report_drc                -file "$OUTDIR/impl_drc_lowsig.rpt"
report_route_status       -file "$OUTDIR/impl_route_lowsig.rpt"
report_clock_interaction  -file "$OUTDIR/impl_clkint_lowsig.rpt"
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/impl_top_paths_lowsig.rpt"

# ---- 6. 位流 ----
write_bitstream -force "$OUTDIR/enc_top_lowsig.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_lowsig.bit"

puts "IMPL_CHECK_LOWSIG_DONE"
# batch 模式必须显式 exit：v66 的 Tcl 也这么收尾；少了它 Vivado 会把 Tcl
# 解释器留在交互态，父进程一直等，作业看起来"永远在跑"。
exit
