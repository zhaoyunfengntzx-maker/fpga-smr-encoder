# -----------------------------------------------------------------------------
#  tools/program_enc.tcl —— 通过 JTAG 下载"编码器生产版"位流（v12）
#
#  运行（仓库根目录）：
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#        -Tcl tools\program_enc.tcl -LogFile _synth_work\program_enc.log -Tail 40
#
#  为什么必须经 tools\run_vivado.ps1 这层信封：它会设 PATH / HOME / USERPROFILE /
#  APPDATA，并把 TEMP / TMP / LOCALAPPDATA 钉在工作区内 —— hw_server / cs_server 是
#  PyInstaller 单文件程序，启动时要把 VCRUNTIME140.dll 解包到 %TEMP%，被沙箱拦住时
#  报的是极具误导性的
#      Unable to launch local cs_server executable.
#      Failed to extract VCRUNTIME140.dll: failed to open target file! fopen: Permission denied
#  看着像 JTAG 驱动问题（见 tools\run_vivado.ps1:81-94、DEV_STATUS.md:2052 / :2232）。
#
#  ★ 只写 FPGA 的易失配置，**不动 SPI flash**：断电重上电后板子仍回到 flash 里那份位流。
#  ★ program_hw_devices 会**复位整个 FPGA** ⇒ 倍频/分频/环路增益/迟滞/标定结果等配置寄存器
#    全部回到复位值（上电默认 inter=256 / div=1 / uwven=0）。下完如果要跑上位机功能测试，
#    先让上位机重写一遍配置（或先跑 host\selftest_link.py 看链路，再点「设备自检」）。
#  ★ 烧之前先看一眼端口有没有被别的 hw_server 占着：
#      netstat -ano | Select-String ':3121'
#    若 3121 已有人 LISTENING 且不是你这次要用的服务器，先弄清它是谁 ——
#    hw_server 会活过 Vivado 进程（常驻），下一次烧录会连上它、拿着旧器件列表报怪错。
# -----------------------------------------------------------------------------

set BIT "C:/Users/zhaoy/Desktop/FPGA/_synth_work/enc_top.bit"

proc p {s} { puts "ENCPROG $s" }
proc die {s} { puts "ENCPROG FATAL: $s"; puts "ENCPROG DONE"; return -code error $s }

p "BEGIN"

if {![file exists $BIT]} { die "位流不存在：$BIT" }
p "  bit = $BIT ([file size $BIT] bytes, mtime [clock format [file mtime $BIT] -format {%Y-%m-%d %H:%M:%S}])"

if {[catch {open_hw_manager} e]} { die "open_hw_manager: $e" }
if {[catch {connect_hw_server} e]} { die "connect_hw_server: $e（Hardware Manager GUI 是否还开着？3121 端口是否被旧 hw_server 占着？）" }
catch { p "  server=[get_hw_servers]" }

set tgt [lindex [get_hw_targets] 0]
if {$tgt eq ""} { die "没有 hw_target（JTAG 线/驱动/USB cable/板子供电 检查）" }
if {[catch {open_hw_target $tgt} e]} { die "open_hw_target: $e" }
p "  target=$tgt"

set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { die "target 里没有器件" }
catch { p "  device=$dev PART=[get_property PART $dev] IDCODE=[get_property IDCODE $dev]" }

set_property PROGRAM.FILE $BIT $dev
if {[catch {program_hw_devices $dev} e]} { die "program_hw_devices: $e" }
p "  下载完成"

catch { refresh_hw_device $dev }
# 这两个属性不是所有器件/版本都有，取不到不算失败（否则脚本会带着 exit 1 返回，
# 让人误以为下载失败）。
set mismatch "<n/a>"
catch { set mismatch [get_property REGISTER.CONFIG_STATUS.BITSTREAM_MISMATCH $dev] }
p "  BITSTREAM_MISMATCH=$mismatch"
set done "<n/a>"
catch { set done [get_property REGISTER.CONFIG_STATUS.DONE $dev] }
p "  CONFIG_STATUS.DONE=$done"

p "  检查清单（编码器 v12 生产版）：接上 2 Mbaud 串口后应能收帧"
p "    python host\\selftest_link.py --port COM3 --seconds 3   ⇒ 帧率 ≈ 10 kHz、0 校验错"
p "    python host\\selftest_s2.py   --port COM3 --seconds 6   ⇒ 身份证 0x05F0=0x0C / 0x05F1=0x10 / 0x05F2=0x000C"
p "PROGRAMMED_OK"
p "DONE"
