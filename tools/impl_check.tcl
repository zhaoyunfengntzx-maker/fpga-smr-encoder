# -----------------------------------------------------------------------------
#  tools/impl_check.tcl  —— Vivado 实现验证脚本（综合 -> 布局 -> 布线 -> 时序）
#
#  目的：在综合之外再验证
#    1) opt_design / place_design / route_design 能否收敛（布线拥塞、DRC）
#    2) 真实时序：WNS / TNS / WHS / THS（综合阶段 timing.rpt 是空的，
#       只有跑完 route_design 才有物理时序数据）
#    3) 布线后 DRC，确认能否生成 bitstream
#
#  运行：
#    $env:Path = 'D:\Vivado\2026.1\Vivado\bin;' + $env:Path
#    vivado -mode batch -nolog -nojournal -source tools/impl_check.tcl
#
#  注意：本机沙箱禁止 Vivado 往 %APPDATA% 写 app.xml，运行前必须先把
#        HOME / USERPROFILE / APPDATA 指向工作区目录，否则报
#        ERROR: [Common 17-1219] Failed to create directory to save app.xml at 'C'
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_synth_work"
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
opt_design
place_design
route_design

# ---- 5. 报告 ----
report_utilization        -file "$OUTDIR/impl_util.rpt"
report_timing_summary     -file "$OUTDIR/impl_timing.rpt"
report_drc                -file "$OUTDIR/impl_drc.rpt"
report_route_status       -file "$OUTDIR/impl_route.rpt"
report_clock_interaction  -file "$OUTDIR/impl_clkint.rpt"

# ---- 6. 生成 bitstream（这一步是"引脚分配是否完整"的最终判据）----
#   若仍有端口没有 PACKAGE_PIN，DRC 的 UCIO-1 会在这里拦下 write_bitstream。
write_bitstream -force "$OUTDIR/enc_top.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top.bit"

puts "IMPL_CHECK_DONE"
