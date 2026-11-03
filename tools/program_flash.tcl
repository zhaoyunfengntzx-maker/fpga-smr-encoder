# -----------------------------------------------------------------------------
#  tools/program_flash.tcl —— 把位流“固化”进板载 QSPI Flash（掉电不丢）
#
#  与 tools/program_enc.tcl 的区别：
#    program_enc.tcl    → program_hw_devices    只写 FPGA 的 SRAM 配置，掉电即丢
#    本脚本             → program_hw_cfgmem     写板载 N25Q128（128 Mbit / 16 MB）
#                         上电后 FPGA 自己从 Flash 读位流，不需要再开 Vivado
#
#  运行（仓库根目录，先接好 JTAG、给板子上电）：
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#        -Tcl tools\program_flash.tcl -LogFile _flash_work\program_flash.log -Tail 60
#
#  可选环境变量：
#    FLASH_BIT  要固化的位流（默认 _synth_work\enc_top.bit）
#    FLASH_MCS  中间 mcs 文件名（默认 _flash_work\<位流同名>.mcs）
#
#  ★ 这会覆盖 Flash 里现有的启动镜像（当前板上是 v9 生产版）。确认要换再跑。
#  ★ 烧写过程中绝不能断电；烧完必须“断电再上电”才算验证（Vivado 里直接
#    program_hw_devices 仍会临时覆盖，不能说明 Flash 启动成功）。
#  ★ 板子启动模式必须是 Master SPI/QSPI（达芬奇-lite 出厂默认如此；若板上有
#    BOOT 拨码/跳线被拨到 JTAG，则上电不会从 Flash 启动）。
#
#  2026-10-30 实测通过（xc7a35t + Digilent HS2 + Vivado 2026.1）：
#    - 必须先把"间接烧写位流"spi_xc7a35t_pullnone.bit 装进 FPGA（见第 3.5 步），
#      否则 program_hw_cfgmem 必然报 [Labtools 27-3347] Failure to set flash
#      parameters（100 ms 内失败）。这是本仓库唯一必需的特殊处理。
#    - 该位流来自 <Vivado>/data/xicom/cfgmem/bitfile/，若目录不存在需要先把
#      同目录的 bitfile.zip 解压出来（普通用户对 Vivado 安装目录无写权限，
#      要提权解压）。
#    - 实测 v67 lowsig：擦写+校验 38 s，之后 boot_hw_device 回读
#      REGISTER.CONFIG_STATUS = 01000000000100000111100111111100（DONE=1）。
# -----------------------------------------------------------------------------

set ROOT "C:/Users/zhaoy/Desktop/FPGA"
set BIT  "$ROOT/_synth_work/enc_top.bit"
if {[info exists ::env(FLASH_BIT)] && $::env(FLASH_BIT) ne ""} {
    set BIT $::env(FLASH_BIT)
}
set MCS "$ROOT/_flash_work/[file rootname [file tail $BIT]].mcs"
if {[info exists ::env(FLASH_MCS)] && $::env(FLASH_MCS) ne ""} {
    set MCS $::env(FLASH_MCS)
}
# ★ 路径必须用正斜杠：write_cfgmem 内部会对 -file/-loadbit 的路径再做一次
#   Tcl 转义解析，Windows 反斜杠路径里 "C:\Users\..." 的 \U 会被当成非法转义，
#   报出完全莫名的 "write_cfgmem: unknown escape sequence"（2026-10-30 实测踩坑）。
set BIT [string map {\\ /} $BIT]
set MCS [string map {\\ /} $MCS]
file mkdir [file dirname $MCS]

# 达芬奇-lite 板载 Flash = Micron N25Q128（128 Mbit = 16 MB）。
# Vivado 器件库里对应 mt25ql128-spi-x1_x2_x4（N25Q128 的后续型号，同容量同协议）；
# 老库里也可能叫 n25q128-3.3v-spi-x1_x2_x4。按顺序找第一个存在的。
set CFGMEM_CANDIDATES {
    mt25ql128-spi-x1_x2_x4
    n25q128-3.3v-spi-x1_x2_x4
}

proc p {s} { puts "FLASHPROG $s" }
proc die {s} { puts "FLASHPROG FATAL: $s"; puts "FLASHPROG DONE"; return -code error $s }

p "BEGIN"

if {![file exists $BIT]} { die "位流不存在：$BIT" }
p "  bit = $BIT ([file size $BIT] bytes, mtime [clock format [file mtime $BIT] -format {%Y-%m-%d %H:%M:%S}])"

# ---- 1) bit → mcs -----------------------------------------------------------
# -size 16      : 16 MB（128 Mbit）
# -interface    : 必须和位流里的 BITSTREAM.CONFIG.SPI_BUSWIDTH 一致！
#                 当前 _synth_work/enc_top.bit 的 SPI_BUSWIDTH 是默认值 1，
#                 所以这里用 SPIx1；若用 SPIx4，Vivado 会直接报
#                 [Writecfgmem 68-20] SPI_BUSWIDTH property is set to "1" ...
#                 想上 x4：先在 XDC 里加 set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4
#                 并重新综合/实现出 bit，再设 FLASH_IF=SPIx4。
# -disablebitswap : 按正点原子教程的写法，避免位交换
set IFACE "SPIx1"
if {[info exists ::env(FLASH_IF)] && $::env(FLASH_IF) ne ""} {
    set IFACE $::env(FLASH_IF)
}
p "  生成 mcs（interface=$IFACE）…"
if {[catch {
    write_cfgmem -format mcs -size 16 -interface $IFACE \
        -loadbit "up 0x00000000 $BIT" \
        -checksum -force -disablebitswap -file $MCS
} e]} {
    die "write_cfgmem: $e"
}
if {![file exists $MCS]} { die "mcs 没生成：$MCS" }
p "  mcs = $MCS ([file size $MCS] bytes)"

# ---- 2) 连接 JTAG -----------------------------------------------------------
if {[catch {open_hw_manager} e]} { die "open_hw_manager: $e" }
if {[catch {connect_hw_server} e]} {
    die "connect_hw_server: $e（Hardware Manager GUI 是否还开着？3121 是否被旧 hw_server 占着？）"
}
set tgt [lindex [get_hw_targets] 0]
if {$tgt eq ""} { die "没有 hw_target（JTAG 线/驱动/USB cable/板子供电 检查）" }
if {[catch {open_hw_target $tgt} e]} { die "open_hw_target: $e" }
p "  target=$tgt"

set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { die "target 里没有器件" }
current_hw_device $dev
p "  device=$dev PART=[get_property PART $dev] IDCODE=[get_property IDCODE $dev]"

# ---- 3) 挂上 Flash 器件 -----------------------------------------------------
set cfgpart ""
foreach cand $CFGMEM_CANDIDATES {
    if {![catch {set hits [get_cfgmem_parts $cand]} e] && [llength $hits] > 0} {
        set cfgpart [lindex $hits 0]
        break
    }
}
if {$cfgpart eq ""} {
    die "Vivado 里找不到 N25Q128/MT25QL128 的 cfgmem 型号；请在 GUI 里 Filter 后手动选 mt25ql128-spi-x1_x2_x4"
}
p "  cfgmem part = $cfgpart"
if {[catch {create_hw_cfgmem -hw_device [current_hw_device] $cfgpart} e]} {
    die "create_hw_cfgmem: $e"
}
set cfg [current_hw_cfgmem]
if {$cfg eq ""} { die "current_hw_cfgmem 为空" }

# ---- 3.5) 先把“间接烧写位流”装进 FPGA（2026-10-30 实测的必需步骤）----------
# 现象：直接 program_hw_cfgmem 会在 ~100 ms 内报
#   ERROR: [Labtools 27-3347] Flash Programming Unsuccessful: Failure to set
#   flash parameters.
# 原因：7 系列写 SPI Flash 要靠一段"间接烧写位流"（spi_xc7a35t_pullnone.bit）
#   在 FPGA 里实现 JTAG→SPI 桥；Vivado 2026.1 在此环境不会自动装它，于是
#   "设置 flash 参数"这一步拿不到 SPI 核（hw_server 日志里是
#   `Command: XicomFlash override` → `Invalid context`）。
# 解法：建好 cfgmem 后，Vivado 会把该位流路径算进 hw_device 的
#   PROGRAM.HW_CFGMEM_BITFILE；先 program_hw_devices 把它烧进 SRAM，
#   再 program_hw_cfgmem 就能正常擦写校验（实测 38 s 通过）。
set ibit ""
catch {set ibit [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]}
if {$ibit eq ""} {
    die "PROGRAM.HW_CFGMEM_BITFILE 为空：Vivado 没给间接烧写位流，检查安装目录 data/xicom/cfgmem/bitfile 是否已解压"
}
if {![file exists $ibit]} { die "间接烧写位流不存在：$ibit（bitfile.zip 未解压？）" }
p "  预加载间接烧写位流 $ibit"
if {[catch {
    set_property PROGRAM.FILE $ibit $dev
    program_hw_devices $dev
} e]} {
    die "预加载间接烧写位流失败: $e"
}
p "  间接烧写位流已就位（SRAM 里现在是 SPI 桥，烧完会自动从 Flash 重载）"

# ---- 4) 擦除 + 烧写 + 校验 --------------------------------------------------
# BLANK_CHECK=0 省一次全片空检查；ERASE=1 先擦；CFG_PROGRAM=1 写配置；
# VERIFY=1 回读校验（强烈建议保留）；CHECKSUM=0 不在最后再算一遍校验和。
set_property PROGRAM.BLANK_CHECK   0 $cfg
set_property PROGRAM.ERASE         1 $cfg
set_property PROGRAM.CFG_PROGRAM   1 $cfg
set_property PROGRAM.VERIFY        1 $cfg
set_property PROGRAM.CHECKSUM      0 $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
set_property PROGRAM.FILES         [list $MCS] $cfg
set_property PROGRAM.PRM_FILE      {} $cfg
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfg

p "  擦除/烧写/校验中（约几十秒，切勿断电）…"
if {[catch {program_hw_cfgmem -hw_cfgmem $cfg} e]} {
    die "program_hw_cfgmem: $e"
}

# ---- 5) 收尾 ----------------------------------------------------------------
catch {refresh_hw_device $dev}
# boot_hw_device 让器件立刻从 Flash 重新加载，省一次断电；不是所有版本都有，
# 失败不算错，断电重上电才是最终验证。
if {[catch {boot_hw_device $dev} e]} {
    p "  boot_hw_device 不可用（$e），请手动断电再上电"
} else {
    p "  已触发从 Flash 重新加载"
}
p "  验证：断电 → 重新上电 → DONE 灯亮、串口有帧（不需要开 Vivado）"
p "  若上电不启动：查 BOOT 模式拨码是否在 QSPI/Master SPI，再重新烧一次"
p "FLASH_OK"
p "DONE"
