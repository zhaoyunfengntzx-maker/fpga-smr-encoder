# tools/ila_capture.tcl —— 一键：下载 ILA 位流 → 加载探针 → 触发 → 导出 CSV
#
# 用法（在仓库根目录、且已关闭 Vivado Hardware Manager GUI）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#       -Tcl tools\ila_capture.tcl -LogFile _synth_work\ila_capture.log -Tail 60
#
# 可用环境变量覆盖（都有默认值）：
#   ILA_MODE = stage1 | stage2 | capture | restore  （默认 stage2）
#              stage1：触发在 dbg_adc_valid 上 —— ADC 一直在跑，等于"立即触发"，
#                      用来先证明"下载 + 探针 + 上传 + 导出"整条链路是通的；
#              stage2：触发在 dbg_ang_glitch == 1 上 —— 抓真实毛刺现场（偶发，
#                      实测密度 0.00444 次/周期，需要 ADC 上有真实正弦输入）。
#              capture：**不重下位流**，只在已经烧好 ILA 版的器件上"武装→触发→导出"
#                      （触发同 stage1 = dbg_adc_valid 立即触发）。
#                      ★ 存在的理由：`program_hw_devices` 会**复位整个 FPGA** ⇒ 所有配置寄存器
#                        回到复位值。要做"改一个寄存器、抓一版波形"的 A/B 对比，就必须
#                        下位流只做一次，之后用本模式反复抓，否则改成什么都会被下位流抹掉。
#                      用法：先 `ILA_MODE=stage1` 下一次位流，再 `write 0x0302 …`，
#                        然后 `ILA_MODE=capture; ILA_CSV=...` 抓（别再下位流）。
#              restore：只下载 ILA_BIT 指定的位流、不碰探针，用来**把生产版 v6 位流放回板子**
#                      （ILA 测试会把生产位流替换掉）。用法：
#                        $env:ILA_MODE="restore"; $env:ILA_BIT="_synth_work/enc_top.bit"
#                      下载完用 tools\uart_spi.py read 0x05F2 应读到当前版本号（v6=6 / v7=7 / v8=8 / v9=9）。
#   ILA_BIT  = 位流路径（默认 _synth_work/enc_top_ila.bit，v6 定版 ILA 版 1,429,272 B @14:06:09）
#   ILA_LTX  = 探针路径（默认 _synth_work/enc_top_ila.ltx，36 端口 / 269 bit）
#   ILA_CSV  = 导出 CSV 路径（默认按 MODE 取名）
#   ILA_DEPTH= 采样深度（默认 1024，必须是 2 的幂且在该 ILA 允许范围内）
#   ILA_WAIT = 等触发的毫秒上限（默认 60000）
#   ILA_TRIG = ★ 直接指定触发探针名（子串匹配，覆盖 MODE 的默认选择）。用途：
#              例如 `ILA_TRIG=z_out` ⇒ 触发在 dbg_z_out == 1 上，窗口里就能直接数
#              Z 脉冲宽了多少个 clk（v9 的 (z_width+1) 个边沿步判据的量测手段）。
#              例：$env:ILA_TRIG="z_out"; $env:ILA_MODE="stage1"; $env:ILA_CSV="_synth_work/ila_cap_v9_z.csv"
#              ⇒ stage1 只是用来下位流的模式名，实际触发探针由 ILA_TRIG 决定。
#              触发位置固定在 DEPTH/2 ⇒ 脉冲前留 DEPTH/2 个样点，宽度可达 512 clk(深度 1024)。
#
# ★ 为什么 stage1/stage2 要分开：毛刺是偶发的，第一次上板就把触发挂在毛刺上，
#   一旦没等到就分不清是"没毛刺"还是"链路/位流/探针根本没对上"。stage1 先排除后者。

proc p {s} { puts "ILACAP $s" }
proc die {s} { puts "ILACAP FATAL: $s"; puts "ILACAP DONE"; return -code error $s }

set MODE   "stage2"
set BIT    "_synth_work/enc_top_ila.bit"
set LTX    "_synth_work/enc_top_ila.ltx"
set CSV    ""
set DEPTH  1024
set WAIT   60000
set TRIG   ""
foreach {envvar var} {ILA_MODE MODE ILA_BIT BIT ILA_LTX LTX ILA_CSV CSV ILA_DEPTH DEPTH ILA_WAIT WAIT ILA_TRIG TRIG} {
    if {[info exists ::env($envvar)] && $::env($envvar) ne ""} { set $var $::env($envvar) }
}
if {$CSV eq ""} { set CSV "_synth_work/ila_cap_${MODE}.csv" }

p "BEGIN mode=$MODE bit=$BIT ltx=$LTX csv=$CSV depth=$DEPTH wait=${WAIT}ms"

# ---- 0) 前置检查 ----
foreach f [list $BIT $LTX] {
    if {![file exists $f]} { die "找不到文件 $f" }
}
p "  bit=[file size $BIT] B  ltx=[file size $LTX] B"

# ---- 1) 连服务器 / 开 target / 取器件 ----
if {[catch {open_hw_manager} e]} { die "open_hw_manager: $e" }
if {[catch {connect_hw_server} e]} { die "connect_hw_server: $e（cable 是否被 Hardware Manager 占着？）" }
p "  server=[get_hw_servers]"
set tgt [lindex [get_hw_targets] 0]
if {$tgt eq ""} { die "没有 hw_target（JTAG 线/驱动/usb cable 检查）" }
if {[catch {open_hw_target $tgt} e]} { die "open_hw_target: $e" }
p "  target=$tgt"
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { die "target 里没有器件" }
catch { p "  device=$dev PART=[get_property PART $dev] IDCODE=[get_property IDCODE $dev]" }

# ---- 2) 下载位流 + 探针 ----
# ★ restore 模式：只烧位流、不加载探针（生产位流里根本没有 ILA）
if {$MODE eq "restore"} {
    if {[catch { set_property PROGRAM.FILE $BIT $dev ; program_hw_devices $dev } e]} { die "program_hw_devices(restore): $e" }
    p "  已下载位流（restore 模式，未加载探针）: $BIT"
    p "  ⇒ 板上现在是这个位流；用 tools\\uart_spi.py read 0x05F2 应读回 0x0009（v9；v6=6 / v7=7 / v8=8 / v9=9）"
    p "     v8 起还要核对 0x0302 = 0x001A（kp=2/ki=3 默认）、0x0500 = 22、0x0501 = 10"
    p "     v9 与 v8 的寄存器默认值相同，差别在 Z 脉宽 = (z_width+1) 个 AB 边沿步（DEV_STATUS §1.49）"
    p "DONE"
    return
}
# ★ 三个属性都要设：少了 FULL_PROBES.FILE 或下载后不 refresh，
#   get_hw_probes 会返回空表（WARNING: [Labtoolstcl 44-131] No matching hw_probes were found），
#   表现成"找不到触发探针"，其实位流已经下好了。
if {$MODE eq "capture"} {
    # ★ 不重下位流：板上必须已经是 ILA 版；这样配置寄存器（标定结果、环路增益、迟滞…）全部保住
    if {[catch {
        set_property PROBES.FILE      $LTX $dev
        set_property FULL_PROBES.FILE $LTX $dev
    } e]} { die "set PROBES.FILE(capture): $e" }
    p "  capture 模式：**不重下位流**（保持板上现有配置与寄存器值）"
} else {
    if {[catch {
        set_property PROGRAM.FILE     $BIT $dev
        set_property PROBES.FILE      $LTX $dev
        set_property FULL_PROBES.FILE $LTX $dev
        program_hw_devices $dev
    } e]} { die "program_hw_devices: $e" }
    p "  已下载位流"
}
if {[catch {refresh_hw_device $dev} e]} { p "  refresh 警告: $e" }

set ilas [get_hw_ilas -of_objects $dev]
if {[llength $ilas] == 0} { die "器件里没发现 ILA（这个位流里没插 ILA，或探针文件不匹配）" }
set ila [lindex $ilas 0]
p "  ila=$ila"

# ---- 3) 找触发探针 ----
set allprobes [get_hw_probes -of_objects $ila]
if {[llength $allprobes] == 0} { set allprobes [get_hw_probes] }
p "  探针数=[llength $allprobes]"
foreach pr $allprobes { if {[string match -nocase "*ang_glitch*" $pr] || [string match -nocase "*adc_valid*" $pr]} { p "    (关键探针) $pr" } }

set want "ang_glitch"
if {$MODE eq "stage1" || $MODE eq "capture"} { set want "adc_valid" }
# ★ ILA_TRIG 覆盖默认选择（例：z_out ⇒ 量 Z 脉宽）
if {$TRIG ne ""} { set want $TRIG; p "  ILA_TRIG 覆盖触发探针 ⇒ want=$want" }
set probe ""
foreach pr $allprobes {
    if {[string match -nocase "*$want*" $pr]} { set probe $pr; break }
}
if {$probe eq ""} {
    p "  可用探针（前 40 个）："
    set k 0
    foreach pr $allprobes { p "    $pr"; incr k; if {$k >= 40} break }
    die "找不到含 '$want' 的探针"
}
p "  trigger probe=$probe"

# ---- 4) 配置采样深度/触发 ----
catch { set_property CONTROL.CAPTURE_DEPTH $DEPTH $ila }
catch { p "  CAPTURE_DEPTH 设置为 [get_property CONTROL.CAPTURE_DEPTH $ila]" }
catch { set_property CONTROL.TRIGGER_POSITION [expr {$DEPTH/2}] $ila }
catch { set_property TRIGGER_COMPARE_VALUE eq1'b1 $probe }
catch { p "  TRIGGER_COMPARE_VALUE = [get_property TRIGGER_COMPARE_VALUE $probe]" }
catch { set_property CONTROL.TRIGGER_CONDITION "AND" $ila }
catch { set_property CONTROL.TRIGGER_MODE "BASIC_ONLY" $ila }

# ---- 5) 武装 + 等触发（带超时，避免脚本挂死） ----
# ★ 状态属性名踩坑（2026-10-11，两次都栽在这里）：
#   - `CONTROL.TRIGGER_STATUS` **不存在**（读出空串 ⇒ 轮询永不成立 ⇒ 干等到超时，数据其实早采到了）。
#   - 真正有用的是 **`STATUS.CORE_STATUS`**，取值实测为 IDLE / RUNNING / **FULL**（采满 ⇒ 数据可上传）。
#   - `STATUS.TRIGGER_STATUS` 在本 ILA 上读出也是空串，别依赖它；用 CORE_STATUS 判就够。
if {[catch {run_hw_ila $ila} e]} { die "run_hw_ila: $e" }
p "  已武装，等触发（上限 ${WAIT} ms）…"

# 5a) 先确认它真的armed/采集中，避免"刚 Armed 时 CORE_STATUS 还是 IDLE"被误判成已采满
set t1 [clock milliseconds]
set core ""
set st ""
while {1} {
    catch { set core [get_property STATUS.CORE_STATUS    $ila] }
    catch { set st   [get_property STATUS.TRIGGER_STATUS $ila] }
    if {[string match -nocase "*RUNNING*" $core] || [string match -nocase "*FULL*" $core] || [string match -nocase "*TRIGGERED*" $st]} break
    if {[clock milliseconds] - $t1 > 3000} { break }
    after 100
}
p "  武装后 CORE_STATUS=$core TRIGGER_STATUS=$st"

# 5b) 等触发 + 采满（FULL = 采样存储已满，数据可上传）
set t0 [clock milliseconds]
set fired 0
while {1} {
    catch { set st   [get_property STATUS.TRIGGER_STATUS $ila] }
    catch { set core [get_property STATUS.CORE_STATUS    $ila] }
    if {[string match -nocase "*TRIGGERED*" $st] || [string match -nocase "*IDLE*" $core] || [string match -nocase "*FULL*" $core]} { set fired 1; break }
    if {[clock milliseconds] - $t0 >= $WAIT} { break }
    after 200
}
p "  TRIGGER_STATUS=$st CORE_STATUS=$core fired=$fired elapsed=[expr {[clock milliseconds]-$t0}] ms"
if {!$fired} {
    catch { reset_hw_ila $ila }
    p "  ⇒ 没等到触发。stage2 说明这段时间里没有毛刺（ADC 上有真实正弦输入吗？）或触发条件没配上。"
    p "DONE"
    return
}

# ---- 6) 等采集填满 + 上传 + 导出 CSV ----
catch { wait_on_hw_ila $ila }
set data [upload_hw_ila_data $ila]
if {[catch { write_hw_ila_data -csv -force $CSV {*}$data } e]} {
    if {[catch { write_hw_ila_data -csv -force $CSV $data } e2]} { die "write_hw_ila_data: $e2" }
}
# ★ write_hw_ila_data -csv 会自己补 ".csv" 后缀：若调用者传的是不带后缀的名字，
#   实际文件是 ${CSV}.csv，直接 [file size $CSV] 会报 "no such file or directory"
#   并把整次抓波以 exit 1 结束（假失败，曾误导过 §1.45 之后的复测）。这里按实际存在的文件报。
set csvfile $CSV
if {![file exists $csvfile] && [file exists ${CSV}.csv]} { set csvfile ${CSV}.csv }
p "  CSV 已写出: $csvfile  ([file size $csvfile] B)"
catch { reset_hw_ila $ila }
p "DONE"
