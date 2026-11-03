# =============================================================================
# mig_build.tcl —— 【已证伪的尝试，保留作记录】用 Tcl 生成 DDR3 MIG
#
# 结论（2026-10-19，Vivado 2026.1 / MIG 4.2）：
#   * `list_property` / `report_property -all` 只看得到 193 个属性，除 INSERT_VIP
#     之外**没有** `CONFIG.C0.DDR3_*`；
#   * 直接写 `CONFIG.C0.DDR3_TimePeriod` 能过，但 `DDR3_CKE` / `DDR3_ChipSelect` /
#     `DDR3_CASLatency` 都报 `Vivado 12-4371 Cannot find parameter`；
#   * 说明 MIG 的 DDR3 参数表要等 GUI 里选过 Memory Type 才展开 ⇒ **纯脚本建不出来**。
#
# 所以 DDR3 必须先做一次 GUI 配置并导出 .xci，步骤见 docs/18 §4.2。
# 这个脚本留在这里只是为了：以后换 Vivado 版本时，先跑一遍看参数是否暴露了。
# =============================================================================
set ROOT [file normalize [file join [file dirname [info script]] ..]]
set OUTDIR [file join $::env(TEMP) "_mig_build"]
file mkdir $OUTDIR

create_project -in_memory -part xc7a35tfgg484-2

create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 \
    -module_name mig_ddr3 -dir $OUTDIR

set cfg [list \
    CONFIG.C0.DDR3_TimePeriod            {400} \
    CONFIG.C0.DDR3_MemoryPart            {MT41K128M16XX-125} \
    CONFIG.C0.DDR3_DataWidth             {16} \
    CONFIG.C0.DDR3_DataMask              {1} \
    CONFIG.C0.DDR3_ChipSelect            {1} \
    CONFIG.C0.DDR3_CKE                   {1} \
    CONFIG.C0.DDR3_ODT                   {1} \
    CONFIG.C0.DDR3_tRFC                  {160} \
    CONFIG.C0.InputClk0_Period           {5000} \
    CONFIG.C0.SysClk0_Period             {5000} \
    CONFIG.C0.DDR3_PinSelection          {System} \
]

if {[catch {set_property -dict $cfg [get_ips mig_ddr3]} err]} {
    puts "MIG_SET_FAILED: $err"
    exit 2
}
puts "MIG_CONFIGURED"

if {[catch {generate_target {instantiation_template synthesis} [get_ips mig_ddr3]} err]} {
    puts "MIG_GENERATE_FAILED: $err"
    exit 3
}
puts "MIG_GENERATED"

# 看 MIG 自己生成的约束里有没有 LOC，决定要不要用自己的 ddr3_pins.xdc
set xdcs [glob -nocomplain -directory $OUTDIR "mig_ddr3/**/*.xdc"]
puts "MIG_XDC_COUNT: [llength $xdcs]"
foreach f $xdcs {
    set fd [open $f r]
    set txt [read $fd]
    close $fd
    set nlocs [regexp -all {PACKAGE_PIN} $txt]
    puts "  [file tail $f] PACKAGE_PIN x $nlocs"
}
puts "MIG_BUILD_DONE"
