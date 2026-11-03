# tools/ila_probe.tcl —— 【只读】探测：板上当前跑的位流里到底有没有 ILA 调试核
#
# 目的：板子掉电后从 SPI flash 自举，我们不知道 flash 里那份是生产版（无 ILA）还是 ILA 版。
#       寄存器分不出来（0x05F0/0x05F1 只给 DEVICE_ID=0x0C / REV=0x10，与版本无关）。
#       唯一判据 = JTAG 读回器件里存在的调试核。
#
# ★ 本脚本绝不下载位流、绝不武装触发、绝不写任何寄存器：
#     没有 set_property PROGRAM.FILE、没有 program_hw_devices、没有 run_hw_ila。
#     只做 open_hw_manager / connect_hw_server / open_hw_target / refresh_hw_device / get_hw_*。
#
# 用法（仓库根目录，且已关闭 Vivado Hardware Manager GUI）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#       -Tcl tools\ila_probe.tcl -LogFile _synth_work\ila_probe.log -Tail 40
#
# 判读：
#   "ILAPRB ilas = 1"（或更多） ⇒ 当前位流里**有** ILA ⇒ flash 里那份是 ILA 版
#   "ILAPRB ilas = 0"           ⇒ 当前位流里没有 ILA ⇒ flash 里那份是生产版
#                                  （前提：refresh_hw_device 没有报错，见同一行 logs）

proc p {s} { puts "ILAPRB $s" }
proc die {s} { puts "ILAPRB FATAL: $s"; puts "ILAPRB DONE"; return -code error $s }
proc cprop {obj prop} {
    if {[catch {get_property $prop $obj} v]} { return "<n/a>" }
    return $v
}

p "BEGIN (read-only probe; no bitstream download, no register write)"

# ---- 1) 连服务器 / 开 target / 取器件 ----
if {[catch {open_hw_manager} e]} { die "open_hw_manager: $e" }
if {[catch {connect_hw_server} e]} { die "connect_hw_server: $e (cable 被 Hardware Manager 占着?)" }
catch { p "  server=[get_hw_servers]" }
set tgt [lindex [get_hw_targets] 0]
if {$tgt eq ""} { die "没有 hw_target（JTAG 线/驱动/usb cable 检查）" }
if {[catch {open_hw_target $tgt} e]} { die "open_hw_target: $e" }
p "  target=$tgt"
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { die "target 里没有器件" }
catch { p "  device=$dev PART=[get_property PART $dev] IDCODE=[get_property IDCODE $dev]" }

# ---- 2) 只 refresh（读器件状态与调试核），不设 PROGRAM.FILE、不 program_hw_devices ----
set rerr ""
if {[catch {refresh_hw_device $dev} e]} { set rerr $e }
p "  refresh_err=[expr {$rerr eq "" ? {<none>} : $rerr}]"

# ---- 3) 枚举调试核 ----
set ilas [get_hw_ilas -of_objects $dev]
p "  ilas = [llength $ilas]"
foreach ila $ilas {
    p "    ila=$ila  core_rev=[cprop $ila CORE_REVISION]  probes=[llength [get_hw_probes -of_objects $ila]]"
}
set vios [get_hw_vios -of_objects $dev]
p "  vios = [llength $vios]"
foreach vio $vios { p "    vio=$vio" }

if {[llength $ilas] == 0} {
    p "  ⇒ 结论：当前位流里没有 ILA（若 refresh_err 为空，则 flash 里那份是【生产版】）"
} else {
    p "  ⇒ 结论：当前位流里有 ILA ⇒ flash 里那份是【ILA 版】"
}
p "DONE"
