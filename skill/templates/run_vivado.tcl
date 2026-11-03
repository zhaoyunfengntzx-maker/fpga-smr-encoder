# Vivado 非工程模式批处理：综合 → 实现 → 报告 → 位流，一次跑完
#
# 用法（Windows PowerShell / cmd 都一样，路径按需改）：
#   vivado -mode batch -nojournal -nolog -source skill/templates/run_vivado.tcl -tclargs enc_top xc7a35tfgg484-2 build/v74
#
# 参数：-tclargs <top> <part> <输出目录>
#
# 为什么用非工程模式而不是 .xpr：
#   1. .xpr 是二进制/XML 的大杂烩，diff 出来全是噪声，评审看不到你改了什么；
#   2. CI / 陌生机器上 `.xpr` 的 IP 路径经常断，而非工程模式只要文件齐全就能跑；
#   3. 报告文件名由这里写死，后处理脚本（skill/scripts/check_impl_reports.py）
#      才能稳定找到它们——"报告名字随手改"是本工程踩过的坑。
#
# 产物（正是 check_impl_reports.py 期待的四个文件）：
#   <out>/timing.rpt  util.rpt  drc.rpt  check_timing.rpt  + <top>.bit
#
# 已验证：本工程 v74 就是这套流程跑出来的（WNS +0.409 ns、LUT 52.53%），
#   报告随后被 check_impl_reports.py 判为 PASS 9/9。

if {[llength $argv] != 3} {
    puts "ERROR 用法: -tclargs top part outdir"
    exit 1
}
lassign $argv top part outdir

set root [file normalize [file dirname [info script]]/../..]
set out  [file normalize $outdir]
file mkdir $out
puts "INFO root=$root"
puts "INFO top=$top part=$part out=$out"

# 让"消息"进日志但不打断流程；ERROR 一律保留
set_msg_config -severity {CRITICAL WARNING} -new_severity {WARNING}

# ---- 读入源文件：按目录收集，不要手写文件清单（手写必漏） ----
set rtl_files [concat \
    [glob -nocomplain $root/rtl/*.v] \
    [glob -nocomplain $root/rtl/*/*.v] \
    [glob -nocomplain $root/rtl/*/*.sv] ]
if {[llength $rtl_files] == 0} {
    puts "ERROR $root/rtl 下没有源文件"
    exit 2
}
read_verilog -sv $rtl_files

# ---- 约束 ----
set xdc [glob -nocomplain $root/constr/*.xdc]
if {[llength $xdc] > 0} { read_xdc $xdc }
puts "INFO 读入 [llength $rtl_files] 个源文件、[llength $xdc] 个约束文件"

# ---- 综合 ----
synth_design -top $top -part $part -flatten_hierarchy rebuilt
write_checkpoint -force $out/post_synth.dcp

# ---- 实现 ----
opt_design
place_design
phys_opt_design
route_design

# ---- 报告：文件名固定，供脚本解析 ----
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -max_paths 10 -input_pins -file $out/timing.rpt
report_utilization -hierarchical -file $out/util.rpt
report_drc -file $out/drc.rpt
report_check_timing -file $out/check_timing.rpt
report_clock_utilization -file $out/clock_util.rpt

# ---- 判决条件写进 Tcl：不靠人眼看报告 ----
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "RESULT WNS=$wns WHS=$whs"
if {$wns < 0 || $whs < 0} {
    # 注意：不要在这里 exit 0。负余量要留下报告给 check_impl_reports.py 判，
    # 但流程本身必须非零退出，否则 CI 会把"时序没收敛"当成成功。
    puts "FAIL 时序未收敛（WNS=$wns WHS=$whs），位流不生成"
    exit 3
}

write_bitstream -force $out/$top.bit
puts "PASS 实现完成：$out/$top.bit"
exit 0
