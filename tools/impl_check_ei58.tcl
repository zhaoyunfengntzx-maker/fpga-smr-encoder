# -----------------------------------------------------------------------------
#  tools/impl_check_ei58.tcl  —— EI58C9.25-2048 正余弦编码器变体实现脚本
#
#  与 tools/impl_check.tcl 的区别：
#    1) 读入 tools/make_ei58_rtl.py 预处理后的 RTL（ENC_EI58 分支已展开）
#       -> enc_top 的 POLE_BITS=11、ST/MT=27/5
#    2) 位流输出到 _synth_work_ei58/enc_top_ei58.bit，不覆盖 v13 的 enc_top.bit
#
#  运行（先在工程根目录生成变体 RTL）：
#    python tools/make_ei58_rtl.py
#    $env:Path = 'D:\Vivado\2026.1\Vivado\bin;' + $env:Path
#    vivado -mode batch -nolog -nojournal -source tools/impl_check_ei58.tcl
#
#  注意：本机沙箱禁止 Vivado 往 %APPDATA% 写 app.xml，运行前必须先把
#        HOME / USERPROFILE / APPDATA 指向工作区目录，否则报
#        ERROR: [Common 17-1219] Failed to create directory to save app.xml at 'C'
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_synth_work_ei58"
file mkdir $OUTDIR

# ---- 1. 读入 EI58 变体 RTL（由 tools/make_ei58_rtl.py 预处理）----
set VARDIR "$ROOT/_synth_work_ei58/rtl_ei58"
if {![file isdirectory $VARDIR]} {
    error "missing $VARDIR - run: python tools/make_ei58_rtl.py"
}
set src [glob -nocomplain "$VARDIR/*.v"]
set src [concat $src [glob -nocomplain "$ROOT/rtl/eth/*.v"]]
puts "INFO: reading [llength $src] preprocessed EI58 RTL files"
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
report_utilization        -file "$OUTDIR/impl_util_ei58.rpt"
report_timing_summary     -file "$OUTDIR/impl_timing_ei58.rpt"
report_drc                -file "$OUTDIR/impl_drc_ei58.rpt"
report_route_status       -file "$OUTDIR/impl_route_ei58.rpt"
report_clock_interaction  -file "$OUTDIR/impl_clkint_ei58.rpt"

# ---- 6. 生成位流（不覆盖 v13）----
write_bitstream -force "$OUTDIR/enc_top_ei58.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top_ei58.bit"

puts "IMPL_CHECK_EI58_DONE"
