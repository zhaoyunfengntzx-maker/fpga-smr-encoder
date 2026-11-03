# -----------------------------------------------------------------------------
#  lcd_test/tools/program_lcd_test.tcl —— 通过 JTAG 下载 LCD 测试位流
#
#  运行（仓库根目录，先关掉 Vivado Hardware Manager GUI）：
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#        -Tcl lcd_test\tools\program_lcd_test.tcl -LogFile _lcd_work\program.log -Tail 40
#
#  ★ 只写 FPGA 的易失配置，**不动 SPI flash**：断电重上电后板子仍回到 flash 里
#     原来那份位流（编码器生产版），不会把板子刷成 LCD 测试版。
#  ★ 下载前请确认 40P 排线已插好（FPC 下接式插反会把 +5V 灌进数据线）。
# -----------------------------------------------------------------------------

set BIT "C:/Users/zhaoy/Desktop/FPGA/_lcd_work/impl_lcd/lcd_test_top.bit"

proc p {s} { puts "LCDPROG $s" }
proc die {s} { puts "LCDPROG FATAL: $s"; puts "LCDPROG DONE"; return -code error $s }

p "BEGIN"

if {![file exists $BIT]} { die "位流不存在：$BIT（先跑 lcd_test/tools/impl_lcd_test.tcl）" }
p "  bit = $BIT ([file size $BIT] bytes)"

if {[catch {open_hw_manager} e]} { die "open_hw_manager: $e" }
if {[catch {connect_hw_server} e]} { die "connect_hw_server: $e（cable 是否被 Hardware Manager 占着？）" }
catch { p "  server=[get_hw_servers]" }

set tgt [lindex [get_hw_targets] 0]
if {$tgt eq ""} { die "没有 hw_target（JTAG 线/驱动/USB cable 检查）" }
if {[catch {open_hw_target $tgt} e]} { die "open_hw_target: $e" }
p "  target=$tgt"

set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { die "target 里没有器件" }
p "  device=$dev PART=[get_property PART $dev] IDCODE=[get_property IDCODE $dev]"

set_property PROGRAM.FILE $BIT $dev
if {[catch {program_hw_devices $dev} e]} { die "program_hw_devices: $e" }
p "  下载完成"
catch { refresh_hw_device $dev }
# 这个属性不是所有器件/版本都有，取不到不算失败（否则脚本会带着 exit 1 返回，
# 让人误以为下载失败）。
set mismatch "<n/a>"
catch { set mismatch [get_property REGISTER.CONFIG_STATUS.BITSTREAM_MISMATCH $dev] }
p "  BITSTREAM_MISMATCH=$mismatch"

p "PROGRAMMED_OK"
p "DONE"
