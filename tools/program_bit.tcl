# -----------------------------------------------------------------------------
# program_bit.tcl -- 烧写 .bit 到板上 FPGA（Vivado GUI / batch 均可）
#
# 用法（Vivado Tcl Console 里）：
#   source <repo>/tools/program_bit.tcl
#   或者指定文件：
#   set ::BIT_FILE <repo>/_impl_v74/enc_top_v74.bit
#   source <repo>/tools/program_bit.tcl
#
# 用法（batch，推荐）：
#   vivado -mode batch -source tools/program_bit.tcl -tclargs _impl_v74/enc_top_v74.bit
#
# 作用：跳过 GUI 里那串 "program_hw_devices failed due to earlier errors" 的
#       黑盒流程，逐步打印每一步的结果，哪一步失败一眼能看到。
# -----------------------------------------------------------------------------

set ::BIT_ROOT [file normalize [file join [file dirname [info script]] ".."]]
if {[llength $argv] > 0} {
    set ::BIT_FILE [lindex $argv 0]
    if {[string index $::BIT_FILE 0] ne "/" && [string index $::BIT_FILE 1] ne ":"} {
        set ::BIT_FILE [file join $::BIT_ROOT $::BIT_FILE]
    }
}
if {![info exists ::BIT_FILE]} {
    set ::BIT_FILE "C:/Users/zhaoy/Desktop/FPGA/ddr3_top_direct.bit"
}

proc _step {msg} { puts "==> $msg" }

_step "bit 文件: $::BIT_FILE"
if {![file exists $::BIT_FILE]} {
    error "找不到 bit 文件：$::BIT_FILE"
}
puts "    大小: [file size $::BIT_FILE] 字节  修改时间: [file mtime $::BIT_FILE]"

_step "打开 Hardware Manager"
if {[catch {open_hw_manager} e]} { puts "    已打开或失败: $e" }

_step "连接 hw_server (localhost:3121)"
if {[catch {connect_hw_server -url localhost:3121} e]} {
    puts "    连接失败: $e"
    puts "    -> 检查：USB 线是否插好、设备管理器里有没有 Digilent/Xilinx 驱动、"
    puts "       或者先把 Vivado 的 Hardware Manager 关掉重开。"
} else {
    puts "    OK"
}

_step "打开 hw_target"
if {[catch {
    set tgts [get_hw_targets]
    puts "    可用 target: $tgts"
    if {[llength $tgts] == 0} { error "没有检测到下载器/目标板" }
    current_hw_target [lindex $tgts 0]
    open_hw_target
} e]} {
    puts "    FAILED: $e"
}

_step "选择器件"
if {[catch {
    set dev [lindex [get_hw_devices] 0]
    puts "    器件: $dev"
    current_hw_device $dev
    refresh_hw_device -update_hw_probes false $dev
} e]} {
    puts "    FAILED: $e"
}

_step "烧写"
if {[catch {
    set_property PROGRAM.FILE $::BIT_FILE [current_hw_device]
    program_hw_devices [current_hw_device]
} e]} {
    puts "    FAILED: $e"
    puts "    -> 若是 'not empty / part mismatch'，先执行 reset_hw_devices 再重试。"
} else {
    puts "    OK -- 已烧写完成"
}

_step "完成"
