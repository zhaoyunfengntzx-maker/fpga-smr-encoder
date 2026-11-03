# -----------------------------------------------------------------------------
#  tools/synth_disp.tcl  —— 「编码器 + 显示引擎」合并综合（xc7a35tfgg484-2）
#
#  目的：回答 Q7′ 的那个问题 —— 在**单时钟域、50 MHz、1 拍 1 像素**的前提下，
#        把显示引擎挂到编码器旁边，时序还有多少余量？资源还剩多少？
#
#  与 tools/synth_check.tcl 的关系：
#    synth_check.tcl 只综合 rtl/ 下的编码器本体（top = enc_top，约束 enc_top.xdc）。
#    本脚本综合 disp/ 下的合并顶层（top = enc_top_disp，约束 enc_top_disp.xdc），
#    源文件 = rtl/*.v 全部 + disp/*.v 全部。两者互不影响。
#
#  运行：
#    vivado -mode batch -nolog -nojournal -source tools/synth_disp.tcl
#
#  产出（全部落在 $OUTDIR = _disp_work/）：
#    util.rpt        资源占用 —— 与基线 _synth_work/util.rpt 对比 BRAM/LUT/FF/DSP
#    timing.rpt      时序汇总 —— 关键是 WNS / WHS，以及失败端点清单
#    drc.rpt         设计规则
#    clocks.rpt      时钟网络（应当只有一根 sys_clk，证明零 MMCM/零 CDC）
#    top_paths.rpt   最差 20 条建立路径 —— 用来判断新增的瓶颈落在哪个模块
#
#  注意：本脚本只做综合（synth_design），不做 place & route / bitstream。
#        综合出的 WNS 是"乐观值"，上板前必须再跑一次实现（impl）。
#        判断复杂度上限用综合值是够的（基线综合 +2.475 vs 实现 +0.959，
#        综合约乐观 1.5 ns —— 这个差值本身就是参考量）。
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_disp_work"
file mkdir $OUTDIR

# ---- 0. 源文件清单 ----
set src_rtl  [lsort [glob -nocomplain "$ROOT/rtl/*.v"]]
#  disp/tb_*.v are testbenches, not design sources -- skip them.
set src_disp {}
foreach f [lsort [glob -nocomplain "$ROOT/disp/*.v"]] {
    if {[string match "tb_*" [file tail $f]]} { continue }
    lappend src_disp $f
}

# disp/lcd_timing_gen.v 是 lcd_test2/rtl/lcd_timing_gen.v 的副本；两者只能进一个，
# 这里只进 disp/ 那份（合并顶层按 disp/ 路径例化）。若将来去掉这份副本，
# 需把 lcd_test2/rtl/lcd_timing_gen.v 加进 src_disp。
set src $src_rtl
foreach f $src_disp { lappend src $f }

puts "INFO: ============ MERGED SYNTHESIS (enc_top_disp) ============"
puts "INFO: rtl  files = [llength $src_rtl]"
puts "INFO: disp files = [llength $src_disp]"
foreach f $src_disp { puts "INFO:   disp <- [file tail $f]" }
puts "INFO: total = [llength $src] files"

# ---- 1. 读入 RTL ----
foreach f $src { read_verilog $f }

# ---- 2. 读入约束 ----
read_xdc "$ROOT/constr/enc_top_disp.xdc"

# ---- 3. 精化 + 综合 ----
#  -flatten_hierarchy rebuilt：与基线 synth_check.tcl 保持同一口径，
#  否则资源/时序数字不可比。
#
#  ★ -verilog_define ENC_DISP_TAP 是本脚本**独有**的一步，绝不能抄到生产脚本里：
#    rtl/enc_top.v 里的 disp_tap[133:0] 只读抽头端口被 `ifdef ENC_DISP_TAP 门控，
#    不定义这个宏时 enc_top 根本没有该端口，disp/enc_top_disp.v 的
#    .disp_tap(...) 例化会直接报
#      [Synth 8-448] named port connection 'disp_tap' does not exist for
#      instance 'u_enc' of module 'enc_top'
#    反之，tools/synth_check.tcl、tools/ila_debug.tcl 与出交付位流的实现脚本
#    都不定义它 —— 那些构建里抽头连端口都不存在，与 v12 完全一致。
#    用法与 tools/ila_debug.tcl:87-88 的 ENC_TOP_ILA 完全同源（宏在 synth_design
#    阶段给，不在 read_verilog 阶段给）。
synth_design -top enc_top_disp -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt \
             -verilog_define ENC_DISP_TAP

# ---- 4. 报告 ----
report_utilization    -file "$OUTDIR/util.rpt"
report_timing_summary -file "$OUTDIR/timing.rpt"
report_drc            -file "$OUTDIR/drc.rpt"
report_clock_networks -file "$OUTDIR/clocks.rpt"

# ---- 5. 最差路径明细（建立 + 保持）----
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file "$OUTDIR/top_paths.rpt"
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file "$OUTDIR/hold_paths.rpt"

# ---- 6. 把结果直接打屏，便于在日志里一眼看到 ----
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "INFO: ============ RESULT ============"
puts "INFO: WNS = $wns ns"
puts "INFO: WHS = $whs ns"
puts "INFO: reports in $OUTDIR"
puts "SYNTH_DISP_DONE"
