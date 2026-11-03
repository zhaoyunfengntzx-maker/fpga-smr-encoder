# -----------------------------------------------------------------------------
#  tools/ila_debug.tcl  —— 生成「带 ILA 的调试版 bitstream」
#
#  与 tools/impl_check.tcl 的区别
#    impl_check.tcl   -> 生产版：无 ILA，产出 _synth_work/enc_top.bit
#    ila_debug.tcl    -> 调试版：插入 ILA，产出 _synth_work/enc_top_ila.bit + .ltx
#  两者从同一套 rtl/*.v 与同一份 constr/enc_top.xdc 出发，所以「调试版能跑通」
#  就等价于「生产版能跑通」，反过来也一样。
#
#  探针从哪来
#    rtl/enc_top.v 里用 `ifdef ENC_TOP_ILA 包住的 (* mark_debug = "true" *)
#    信号。生产版不定义宏，一个探针都没有，LUT/时序数字不受影响。
#
#  运行（★ 本机必须先把 HOME/USERPROFILE/APPDATA 指到工作区，否则 Vivado 会
#       在 %APPDATA% 写 app.xml 失败：ERROR: [Common 17-1219]；
#       还必须设 XILINXD_LICENSE_FILE，否则 create_debug_core 报 12-29205 BASIC）
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#        -Tcl tools\ila_debug.tcl -LogFile _synth_work/ila_build.log
#    （run_vivado.ps1 会一次做好：PATH / HOME / USERPROFILE / APPDATA / 许可证）
#
#  ★ 已踩过并修掉的坑（都在这里，别再犯）
#    (1) 不能用 read_verilog -define：非工程模式报
#        ERROR: [Common 17-69] Command failed: '-define' is only supported when
#         is_compile_unit_mode is enabled on the source fileset
#        ⇒ 宏只在 synth_design -verilog_define 里给。
#
#    (2) get_debug_ports **只枚举已经存在的 debug core 的端口**。在
#        create_debug_core 之前调它只打印
#        WARNING: [Vivado 12-750] There are no ChipScope debug cores in this design.
#        并返回空表 ⇒ 正确顺序：opt_design → create_debug_core → 逐个
#        create_debug_port → get_debug_ports → connect_debug_port。
#
#    (3) 2026.1 的 ila core 把这批配置项挂在 **core** 上，不在 debug_port 上：
#          core  支持 ALL_PROBE_SAME_MU / ALL_PROBE_SAME_MU_CNT / CLASS /
#                C_ADV_TRIGGER / C_DATA_DEPTH / C_EN_STRG_QUAL /
#                C_INPUT_PIPE_STAGES / C_TRIGIN_EN / C_TRIGOUT_EN / NAME / UUID
#          port  只支持 CLASS / NAME / PORT_WIDTH
#        （用 list_property 实测 dump；旧写法把 C_DATA_DEPTH 设到
#          [get_debug_ports u_ila/probe0] 会报
#          ERROR: [Vivado 12-4442] Invalid property name C_DATA_DEPTH.）
#
#    (4) ★★ 把全部 252 个探针位拼成**一条** probe0 总线会导致 place_design 挂死。
#        实测：两个 vivado 进程跑满 1 小时只消耗 79.9 s / 18.7 s CPU（≈ 零负载），
#        _synth_work 下再无任何新文件产出。原因：252 根互不相关的网被要求全部
#        汇聚到**同一个** ILA 实例的同一组输入端，布线资源在那一小块区域彻底堵塞，
#        placer 陷入病态搜索。
#        ⇒ 修法：拆成**多条命名探针**（每条 ≤ PROBE_MAX_BITS 位），每个探针是
#          独立的 debug_port，可以甩到 ILA 实例周围不同的位置。
#
#    (5) 不要手动调 implement_debug_core。help 原文：debug core 的实现
#        "is automatic when you launch an implementation run using launch_runs,
#         or during design optimization using opt_design"。
#        本脚本的 opt_design 在 create_debug_core **之前**跑过，若此时已有黑盒，
#        place_design 会报
#          ERROR: [Vivado_Tcl 4-547] Found one or more debug core instances in the
#                 design that needs to be (re)generated. dbg_hub / u_ila
#                 Run opt_design or implement_debug_core prior to launching place_design.
#        ⇒ 正确做法是在 create_debug_core + connect 之后再跑一次 opt_design，
#          让工具自己把 debug core 展开（比手动 implement_debug_core 稳）。
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set OUTDIR "$ROOT/_synth_work"
set ILADIR "$OUTDIR/ila"
file mkdir $OUTDIR
file mkdir $ILADIR

# 每条命名探针的最大位宽。32 位是 ILA 探针的常见粒度，实测比单条 252 位稳得多。
set PROBE_MAX_BITS 32

# 每个探针位的分组名（写进 ila_probe_list.txt，作为 .ltx 之外的文字索引）
set probe_map [list]

# 按顺序打印每一步，便于从日志定位卡点
proc step {n msg} { puts "\[ILA_STEP $n\] $msg" ; flush stdout }

# ---------------------------------------------------------------------------
step 1 "read RTL"
set src [glob -nocomplain "$ROOT/rtl/*.v"]
puts "INFO: reading [llength $src] RTL files"
foreach f $src { read_verilog $f }

step 2 "read XDC"
read_xdc "$ROOT/constr/enc_top.xdc"

step 3 "synth_design (with -verilog_define ENC_TOP_ILA)"
synth_design -top enc_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt \
             -verilog_define ENC_TOP_ILA

# ---------------------------------------------------------------------------
# 4. 收集 mark_debug 网并归组成命名探针
#    opt_design 之前先收集：此时每条 (* mark_debug *) 网还是完整的多位网，
#    get_nets 能直接返回 "dbg_s_raw[11:0]" 这样的名字；flatten 之后会被拆成
#    单 bit 的 dbg_s_raw[11]、dbg_s_raw[10]…，归组反而更麻烦。
#    （两种时机都能拿到 252 条，但这里用综合后、opt 前的整网，名字最干净。）
# ---------------------------------------------------------------------------
step 4 "collect MARK_DEBUG nets"
set allnets [get_nets -hier -quiet -filter {MARK_DEBUG == 1}]
puts "ILA: nets with MARK_DEBUG = [llength $allnets]"

# 建立「探针条目」列表：每条 = {显示名 位宽 {网名...}}
# 一个多位的 mark_debug 网通常直接就是一个条目；若它被拆成单 bit 网，
# 就按 <基名>[idx] 归组后拼回去。
set bases [dict create]
set order [list]
foreach n $allnets {
    if {[regexp {^(.*)\[(\d+)\]$} $n -> base idx]} {
        if {![dict exists $bases $base]} { dict set bases $base [dict create]; lappend order $base }
        dict set bases $base $idx $n
    } else {
        if {![dict exists $bases $n]} { dict set bases $n [dict create]; lappend order $n }
        dict set bases $n -1 $n
    }
}
puts "ILA: distinct probe bases = [llength $order]"

set probes [list]     ;# 每项: [list 名字 位宽 nets列表]
set total 0
foreach base [lsort $order] {
    set m [dict get $bases $base]
    if {[dict exists $m -1]} {
        lappend probes [list $base 1 [list [dict get $m -1]]]
        incr total 1
        continue
    }
    # ★ 位序（实测 2026-10-10，勿改回）：
    #   connect_debug_port 传入「单 bit 网名列表」时，列表里的**第一个** net
    #   会被接成端口的**最低有效位**（探针 bit0）。所以 ns 必须按 LSB→MSB
    #   排列；排成 MSB→LSB 会让整条探针的值位序反转
    #   （症状：dbg_pole_pairs_eff 在波形窗里显示 8，而寄存器配置值是 4；
    #     CSV 导出同错，必须逐列 bitrev 才能读）。
    set idxs [lsort -integer -decreasing [dict keys $m]]
    set hi [lindex $idxs 0]
    set lo [lindex $idxs end]
    set w [expr {$hi - $lo + 1}]
    set ns [list]
    foreach i [lsort -integer -increasing [dict keys $m]] { lappend ns [dict get $m $i] }
    if {[llength $idxs] != $w} {
        puts "ILA_WARN: $base 位不连续（$idxs），按实际位逐位连接，宽度按 [llength $idxs] 算"
        set w [llength $idxs]
    }
    lappend probes [list "${base}\[${hi}:${lo}\]" $w $ns]
    incr total $w
}

puts "ILA: [llength $probes] probe signals, total width = $total"
if {[llength $probes] == 0} {
    puts "ILA_ERROR: 没有任何 MARK_DEBUG 网；检查 rtl/enc_top.v 的"
    puts "           \`ifdef ENC_TOP_ILA 段与 synth_design -verilog_define"
    exit 1
}

# ---------------------------------------------------------------------------
# 5. 把过宽的探针切成 <= PROBE_MAX_BITS 的片，形成最终的 debug_port 列表
#    nets 是 LSB..MSB 顺序（见第 4 步的位序坑）；切片时低位片先出，
#    保证每片内部仍是 LSB..MSB，片名后缀 = 该片最低位的索引。
# ---------------------------------------------------------------------------
set ports   [list]    ;# 每项: [list 端口显示名 位宽 nets列表]
foreach p $probes {
    lassign $p nm w ns
    set off 0
    set base [string map {\[ _ \] _ : _} $nm]
    while {$off < $w} {
        set take [expr {$w - $off}]
        if {$take > $PROBE_MAX_BITS} { set take $PROBE_MAX_BITS }
        # nets 是 LSB..MSB；第 off 段对应 bits[off .. off+take-1]
        set slice [lrange $ns $off [expr {$off + $take - 1}]]
        set pnm $base
        if {$w > $PROBE_MAX_BITS} { append pnm "_$off" }
        lappend ports [list $pnm $take $slice]
        incr off $take
    }
}
puts "ILA: split into [llength $ports] debug ports (max $PROBE_MAX_BITS bits each)"
foreach p $ports { lassign $p pnm w ns ; puts "   port $pnm : $w bits" }

# ---------------------------------------------------------------------------
# 6. 建 ILA core
#    ★ create_debug_core 需要 Vivado 的 Debug 特性（GOLD 及以上）。
#      只装 BASIC 许可时直接报
#        ERROR: [Vivado 12-29205] 'create_debug_core' tcl command is not supported.
#               Your current selected license is BASIC.
#      实测本机 D:\Vivado 下同时存在两个许可文件：
#        · D:\Vivado\Xilinx.lic         —— 只有 Vivado_Basic_Package（BASIC）
#        · D:\Vivado\Xlnx_2026_1.lic    —— Vivado_Tier=GOLD + INCREMENT ChipscopePro
#      Vivado 默认没设 XILINXD_LICENSE_FILE，按搜索路径优先命中 BASIC 那个。
#      **必须显式指定** $env:XILINXD_LICENSE_FILE（见 tools/run_vivado.ps1）。
# ---------------------------------------------------------------------------
step 5 "create_debug_core u_ila ila"
if {[catch {create_debug_core u_ila ila} err]} {
    puts "============================================================"
    puts "ILA_LICENSE_BLOCKED"
    puts "  探针已全部就绪（[llength $ports] 条端口 / 共 $total bit），但当前 Vivado"
    puts "  许可证不包含 Debug 特性，create_debug_core 被拒绝："
    puts "  $err"
    puts ""
    puts "  ⇒ 最常见原因：XILINXD_LICENSE_FILE 没设，Vivado 命中了 D:\\Vivado\\Xilinx.lic（BASIC）。"
    puts "     修法：`\$env:XILINXD_LICENSE_FILE = 'D:\\Vivado\\Xlnx_2026_1.lic'`"
    puts "  ⇒ 本次无法产出 enc_top_ila.bit。生产版 enc_top.bit 不受影响。"
    puts "============================================================"
    return
}

# 时钟端口
set_property port_width 1 [get_debug_ports u_ila/clk]

# ---------------------------------------------------------------------------
# 7. 逐条建立命名探针端口
#    create_debug_port u_ila probe 会自动分配下一个可用名（probe0、probe1…）。
#    再 set_property port_width，最后 connect_debug_port。
# ---------------------------------------------------------------------------
step 6 "create + connect [llength $ports] probe ports"
set pi 0
foreach p $ports {
    lassign $p pnm w ns
    # ★★ 坑 6（实测踩到）：`create_debug_core u_ila ila` 会**自动预建一个 probe0**
    #    （位宽 1、未连接）。如果这里无脑 create_debug_port 逐条新建，就会得到
    #    probe0(自动的空口) + probe0(新建) + probe1 … 编号整体错位，
    #    最终多出一个从未连接的 probe34，opt_design 直接报：
    #      ERROR: [Chipscope 16-213] The debug port 'u_ila/probe34' has
    #             1 unconnected channels (bits). This will cause errors during
    #             implementation.
    #    ⇒ 修法：每建一条之前先看 u_ila/probe$pi 是否已经存在且**尚未连接任何网**；
    #      是就直接复用那个空端口，否则才 create_debug_port。
    #      判据用 get_nets -quiet [get_debug_ports ...]，未连接时返回空。
    set port [get_debug_ports -quiet "u_ila/probe$pi"]
    set needNew 1
    if {$port ne ""} {
        if {[llength [get_nets -quiet [get_debug_ports "u_ila/probe$pi"]]] == 0} {
            set needNew 0
            puts "ILA: reusing pre-created empty u_ila/probe$pi for $pnm ($w bits)"
        }
    }
    if {$needNew} {
        create_debug_port u_ila probe
        set port [get_debug_ports "u_ila/probe$pi"]
    }
    if {$port eq ""} {
        puts "ILA_ERROR: 无法取得第 $pi 条探针端口 u_ila/probe$pi"
        exit 1
    }
    set_property port_width $w $port
    connect_debug_port $port $ns
    lappend probe_map [list "u_ila/probe$pi" $pnm $w]
    incr pi
}
puts "ILA: connected $pi named probe ports, total $total bits"

# ---------------------------------------------------------------------------
# 8. core 级配置（★ 挂在 core 上，不挂在 port 上 —— 见文件头坑 3）
#    DATA_DEPTH 1024：50 MHz 采样 → 20.5 us 窗口；1 kHz 信号约 20 个点，
#    足够看清边沿/相位，只吃 3 个 36Kb BRAM（全片 50 个）。
# ---------------------------------------------------------------------------
set_property C_DATA_DEPTH         1024  [get_debug_cores u_ila]
set_property C_INPUT_PIPE_STAGES  1     [get_debug_cores u_ila]
set_property C_TRIGIN_EN          false [get_debug_cores u_ila]
set_property C_TRIGOUT_EN         false [get_debug_cores u_ila]
set_property C_EN_STRG_QUAL       false [get_debug_cores u_ila]
set_property ALL_PROBE_SAME_MU    true  [get_debug_cores u_ila]

# 时钟：取 BUFG 输出。opt_design 之前 clk_i 这个名字一定存在。
set clknet [get_nets -quiet clk_i]
if {$clknet eq ""} {
    puts "ILA_WARN: 找不到网 clk_i，退回 sys_clk"
    set clknet [get_nets -quiet sys_clk]
}
connect_debug_port u_ila/clk $clknet
puts "ILA: clock connected to $clknet"

# ---------------------------------------------------------------------------
# 9. ★ 再跑一次 opt_design，让工具自己展开 debug core（替代手动
#    implement_debug_core，见文件头坑 5）
# ---------------------------------------------------------------------------
step 7 "opt_design (lets the tool implement the debug cores)"
opt_design

# 探针清单落盘（.ltx 之外的文字索引，便于按名字找位偏移）
# ★★ 表头必须是 **ASCII**（这里踩过两次坑，务必不要再改回中文）：
#   ① Tcl 的 `open w` 默认按**系统 ANSI 代码页**（中文 Windows = cp936）编码写入
#      ⇒ 加 `fconfigure -encoding utf-8` 能解决"写出 GBK 字节"的问题；
#   ② 但 **Vivado 也是按系统代码页读取 .tcl 脚本本身**的，脚本里的中文字面量在
#      解析阶段就已经被错解成"乱码字符"，再用 utf-8 写出去 = **双重编码乱码**
#      （实测 2026-10-10：文件头两行是 `鎺㈤拡绔¯鍙ｆ暟 = 34`，而 34 条探针行本身是
#      纯 ASCII、完全正确）。⇒ 结论：**这类落盘索引一律写英文/ASCII**。
set fh [open "$OUTDIR/ila_probe_list.txt" w]
fconfigure $fh -encoding utf-8
puts $fh "probe_ports = [llength $probe_map], total_bits = $total"
puts $fh "fields: port | signal | width"
foreach m $probe_map { puts $fh [join $m " | "] }
close $fh
puts "ILA_PROBE_LIST $OUTDIR/ila_probe_list.txt"

# ---------------------------------------------------------------------------
step 8 "place_design"
place_design
step 9 "route_design"
route_design

# ---- 10. 报告 ----
step 10 "reports + bitstream"
report_timing_summary -file "$OUTDIR/impl_ila_timing.rpt"
report_utilization    -file "$OUTDIR/impl_ila_util.rpt"
report_drc            -file "$OUTDIR/impl_ila_drc.rpt"

write_debug_probes -force "$OUTDIR/enc_top_ila.ltx"
write_bitstream    -force "$OUTDIR/enc_top_ila.bit"
puts "ILA_BITSTREAM_WRITTEN $OUTDIR/enc_top_ila.bit"
puts "ILA_PROBES_WRITTEN    $OUTDIR/enc_top_ila.ltx"
puts "ILA_CHECK_DONE"
