# -----------------------------------------------------------------------------
#  tools/synth_check.tcl  —— Vivado 综合验证脚本（针对 xc7a35tfgg484-2）
#
#  目的：用真实 Vivado 综合器验证
#    1) 全部 rtl/*.v 能否被综合器接受（语法 / 可综合子集 / 位宽陷阱）
#    2) enc_top 能否精化（elaboration）通过
#    3) constr/enc_top.xdc 的约束是否合法（引脚是否存在、IOSTANDARD 是否冲突、
#       时序约束能否建立）
#    4) 资源占用与 WNS/TNS 时序
#
#  运行：
#    $env:Path = 'D:\Vivado\2026.1\Vivado\bin;' + $env:Path
#    vivado -mode batch -nolog -nojournal -source tools/synth_check.tcl
#
#  注意：本机没有预编译的 xsim 库，本脚本只做综合（-rtl 到 opt_design），
#        不做 place & route / bitstream，因此不需要实现许可。
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

# ---- 3. 精化 + 综合 ----
synth_design -top enc_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt

# ---- 4. 报告 ----
report_utilization      -file "$OUTDIR/util.rpt"
report_timing_summary   -file "$OUTDIR/timing.rpt"
report_drc              -file "$OUTDIR/drc.rpt"
report_clock_networks  -file "$OUTDIR/clocks.rpt"

puts "SYNTH_CHECK_DONE"
