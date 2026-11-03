# -----------------------------------------------------------------------------
#  _boardtest/program_v68.tcl —— 只把 v68 生产位流下载到 FPGA SRAM（不动 Flash）
#  运行：
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
#      -Tcl _boardtest\program_v68.tcl -LogFile program_v68.log -Tail 80
# -----------------------------------------------------------------------------
set BIT "C:/Users/zhaoy/Desktop/FPGA/deliverables/data/v68/enc_top_v68.bit"

proc p {s} { puts "V68PROG $s" }
proc die {s} { puts "V68PROG FATAL: $s"; puts "V68PROG DONE"; error $s }

p "BEGIN"
if {![file exists $BIT]} { die "位流不存在：$BIT" }
p "  bit = $BIT ([file size $BIT] bytes, mtime [clock format [file mtime $BIT] -format {%Y-%m-%d %H:%M:%S}])"

if {[catch {open_hw_manager} e]} { die "open_hw_manager: $e" }
if {[catch {connect_hw_server -url localhost:3121} e]} { die "connect_hw_server: $e" }
catch { p "  server=[get_hw_servers]" }

set tgts [get_hw_targets]
p "  targets=$tgts"
if {[llength $tgts] == 0} { die "没有 hw_target（JTAG 线/驱动/USB cable/板子供电 检查）" }
set tgt [lindex $tgts 0]
if {[catch {current_hw_target $tgt} e]} { die "current_hw_target: $e" }
if {[catch {open_hw_target} e]} { p "  open_hw_target: $e（可能已打开，继续）" }
p "  target=$tgt"

set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { die "target 里没有器件" }
catch { p "  device=$dev PART=[get_property PART $dev] IDCODE=[get_property IDCODE $dev]" }

set_property PROGRAM.FILE $BIT $dev
if {[catch {program_hw_devices $dev} e]} { die "program_hw_devices: $e" }
p "  下载完成"

catch { refresh_hw_device -update_hw_probes false $dev }
set mismatch "<n/a>"
catch { set mismatch [get_property REGISTER.CONFIG_STATUS.BITSTREAM_MISMATCH $dev] }
p "  BITSTREAM_MISMATCH=$mismatch"
set done "<n/a>"
catch { set done [get_property REGISTER.CONFIG_STATUS.DONE $dev] }
p "  CONFIG_STATUS.DONE=$done"
p "PROGRAMMED_OK"
exit 0
