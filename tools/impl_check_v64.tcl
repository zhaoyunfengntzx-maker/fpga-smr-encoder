# -----------------------------------------------------------------------------
#  tools/impl_check_v64.tcl  —— v64 生产线（EI58 / 转台参数化变体）
#
#  与 tools/impl_check.tcl 的唯一区别：
#    1) 位流/报告输出到 _impl_v64/，不覆盖 v62 的任何产物
#    2) place/phys_opt/route 沿用 v62 的 Explore 策略（默认策略在 82% LUT 上
#       余量更小，v62 用 Explore 才拿到 WNS +0.471 / WHS +0.042）
#    拓扑不变：top = enc_top（不含显示 UI；显示实验构建见 _impl_v62.tcl）
#
#  v64 相对 v62 的 RTL 变化（全部是配置，不改数据通路）：
#    enc_top.v   : POLE_BITS 6 -> 11；ST_BITS_L/MT_BITS_L 由 POLE_BITS 派生
#                  （27/5）；RTL_BUILD_ID 0x000D -> 0x000E
#    reg_file.v  : ST_BITS_R/MT_BITS_R 参数化并由 enc_top 传入；inter 复位值 2
#
#  运行：
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_vivado.ps1 `
#        -Tcl tools/impl_check_v64.tcl -LogFile _impl_v64/vivado.log -Tail 60
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_impl_v64"
file mkdir $OUTDIR

# ---- 1. 读入 RTL ----
set src [glob -nocomplain "$ROOT/rtl/*.v"]
set src [concat $src [glob -nocomplain "$ROOT/rtl/eth/*.v"]]
puts "INFO: reading [llength $src] RTL files"
foreach f $src { read_verilog $f }

# ---- 2. 读入约束 ----
read_xdc "$ROOT/constr/enc_top.xdc"
if {[file exists "$ROOT/constr/enc_top_eth.xdc"]} {
    read_xdc "$ROOT/constr/enc_top_eth.xdc"
}

# ---- 3. 综合 ----
synth_design -top enc_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

# ---- 4. 实现流程 ----
# v64 首版用 v62 的 Explore 策略只拿到 WNS +0.029 / WHS +0.043（满足约束但余量薄，
# 0.06% 周期）。该设计对布局敏感（v62 脚本注释：同一 RTL 在 v59 通过、首版 v62
# 曾到 -0.913），故改为 ExtraTimingOpt 策略，目标是 WNS >= 0.2 ns 再交付。
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

# ---- 5. 报告 ----
report_utilization        -file "$OUTDIR/impl_util_v64.rpt"
report_timing_summary     -file "$OUTDIR/impl_timing_v64.rpt"
report_drc                -file "$OUTDIR/impl_drc_v64.rpt"
report_route_status       -file "$OUTDIR/impl_route_v64.rpt"
report_clock_interaction  -file "$OUTDIR/impl_clkint_v64.rpt"
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/impl_top_paths_v64.rpt"

# ---- 6. 位流 ----
write_bitstream -force "$OUTDIR/enc_top_v64.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_v64.bit"

puts "IMPL_CHECK_v64_DONE"
