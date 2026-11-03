# -----------------------------------------------------------------------------
#  tools/util_hier.tcl  —— 按层次统计 v62 交付位流的资源占用（只综合，不实现）
#
#  为什么单独一个脚本：
#    出交付位流的 _impl_v62.tcl 用 -flatten_hierarchy rebuilt（综合与实现口径一致、
#    时序更好），综合后层次被压平，report_utilization 只有总数，看不到
#    "哪一块吃了多少 LUT / BRAM"。本脚本改用 -flatten_hierarchy none，保留层次，
#    并输出 -hierarchical 的资源报告，用来回答「资源被谁占了、优化该先动谁」。
#
#  口径说明：
#    - 与交付位流的差别只有 flatten_hierarchy（none vs rebuilt），LUT/BRAM 总数会有
#      1-3% 差异（跨模块边界优化被关掉），但**模块之间的相对占比**可信；
#      引用时务必带这句说明。
#    - 只跑到 synth_design，不做 opt/place/route，所以没有实现后的 WNS。
#
#  运行：
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 ^
#        -Tcl tools\util_hier.tcl -LogFile _hier_work\util_hier.log
#
#  产出：
#    _hier_work/util_hier.rpt        按层次的 LUT/FF/BRAM/DSP/LUTRAM 表
#    _hier_work/util_total.rpt       总数（与交付位流对比用）
#    _hier_work/timing_hier.rpt      综合后时序概要（仅参考）
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_hier_work"
file mkdir $OUTDIR

# ---- 源文件（与 _impl_v62.tcl 同口径：rtl/*.v + rtl/eth/*.v + disp/*.v，排除 tb_*）----
#  注意：rtl/enc_top.v 里例化 eth_top 而 eth_top 在 rtl/eth/ 下，漏收这一组会报
#  [Synth 8-439] module 'eth_top' not found（tools/impl_disp.tcl 的老 glob 就有这个坑）。
set src [lsort [glob -nocomplain "$ROOT/rtl/*.v"]]
foreach f [lsort [glob -nocomplain "$ROOT/rtl/eth/*.v"]] { lappend src $f }
foreach f [lsort [glob -nocomplain "$ROOT/disp/*.v"]] {
    if {[string match "tb_*" [file tail $f]]} { continue }
    lappend src $f
}

foreach f $src { read_verilog $f }
read_xdc "$ROOT/constr/enc_top_disp.xdc"

puts "INFO: ============ HIERARCHICAL UTILIZATION (enc_top_disp) ============"
puts "INFO: files = [llength $src]"

# ★ 关键：none —— 保留层次，才能按模块统计
synth_design -top enc_top_disp -part xc7a35tfgg484-2 \
             -flatten_hierarchy none -verilog_define ENC_DISP_TAP

report_utilization -file "$OUTDIR/util_total.rpt"
report_utilization -hierarchical -hierarchical_depth 4 \
                   -hierarchical_percentages -file "$OUTDIR/util_hier.rpt"
report_timing_summary -file "$OUTDIR/timing_hier.rpt"

puts "INFO: ============ RESULT ============"
puts "SYNTH_UTIL_HIER_DONE"
