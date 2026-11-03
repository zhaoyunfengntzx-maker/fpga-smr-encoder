# -----------------------------------------------------------------------------
#  lcd_test2/tools/sim_lcd_test2.tcl —— 第二版（lcd_test2）全部自检测试台
#
#  运行（推荐用封装脚本，它会设好 PATH / HOME / GOLD 许可）：
#     powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#         -Tcl lcd_test2\tools\sim_lcd_test2.tcl -LogFile _lcd_work\sim_lcd2.log -Tail 400
#     抓结果：
#         Select-String -Path _lcd_work\sim_lcd2.log -Pattern 'TEST PASSED|TEST FAILED'
#
#  测试台：
#     1)  tb_lcd_timing      时序发生器（含"场计数不被像素使能门控"的回归）
#     2)  tb_uart_frame      UART 一帧 16 字节（旧协议 v2）8N1 帧级校验
#     3)  tb_uart_frame26    UART 一帧 26 字节（新协议 v3）逐字节 + 字段解包校验
#     4)  tb_key_ctrl        F4 按键：消抖 / 短按切模式 / 长按切暂停 / 抖动弹跳
#     5)  tb_screen_pattern  F1 色轮播 + F2 网格坐标 + F3 准星与抬手保留
#     6)  tb_touch_i2c       IIC 触摸（GT911 假从机、FT5206 假从机各跑一遍）
#     7)  tb_lcd2_top        集成：屏 ID -> 时序 -> 触摸 -> 按键 -> 画面 -> UART
#     8)  tb_i2c_watchdog    IIC 看门狗：相位被拖住 -> S_RECOVER -> done（timeout=1）
#                            并验证恢复后可复用、常规 NACK 路径不被误伤
#
#  注意 1：★ 必须用 exec 调 xvlog/xelab/xsim。Vivado 的 Tcl 解释器本身没有这些
#          命令，不写 exec 会退化成"发给 OS shell"，然后报
#          invalid command name "xvlog"。
#  注意 2：★ 必须把子进程的 stdout 重定向进文件再回读。exec 只把输出收进 Tcl
#          的返回值，不会转发到 Vivado 的 console/log。
#  注意 3：本机没有预编译的 xsim 库，所以必须把 IOBUF 等原语的桩模型一起编译
#          （lcd_test2/sim/iobuf_stub.v、sim/xilinx_prims_stub.v 在工作区根目录）。
#  注意 4：时间缩放做在测试台源码里（tb_lcd2_top.v 的 TEST_SPEEDUP），
#          这里不传 -generic_top（传了会报 ERROR: [XSIM 43-3281]）。
#  注意 5：★ 每次跑之前必须清空工作库，否则 xvlog 会卡在启动阶段（实测 20 分钟无输出）。
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set RTL    "$ROOT/lcd_test2/rtl"
set SIM    "$ROOT/lcd_test2/sim"
set PRIMS  "$ROOT/sim/xilinx_prims_stub.v"
set WORK   "$ROOT/_lcd_work/xsim_lcd2"
set env(PATH) "D:/Vivado/2026.1/Vivado/bin;$env(PATH)"
if {[file exists $WORK]} { file delete -force $WORK }
file mkdir $WORK
cd $WORK

proc banner {t} {
    puts "=============================================================="
    puts " $t"
    puts "=============================================================="
}

# 跑一个测试台：xvlog -> xelab -> xsim -R，并把 xsim 的 stdout 回读进本日志
proc run_one {name impl sources {defs {}} {snap {}}} {
    global WORK
    if {$snap eq ""} { set snap "sim_$impl" } else { set snap "sim_$snap" }
    banner "RUN: $name"
    puts "  >> xvlog [llength $sources] files (defs: $defs)"
    if {[llength $defs] == 0} {
        exec xvlog {*}$sources
    } else {
        exec xvlog -d [lindex $defs 0] {*}$sources
    }
    puts "  >> xelab $impl -s $snap"
    exec xelab $impl -s $snap -timescale 1ns/1ps -debug typical
    set runlog "$WORK/${snap}_run.log"
    puts "  >> xsim (stdout -> [file tail $runlog])"
    set code 0
    try {
        exec xsim $snap -R > $runlog
    } on error {msg} {
        set code 1
        puts "  !! xsim returned an error: $msg"
    }
    if {[file exists $runlog]} { puts [read [open $runlog r]] }
    return $code
}

set fail 0

# ============================================================ 1) 时序发生器台
if {[run_one "tb_lcd_timing" "tb_lcd_timing" \
        [list "$SIM/tb_lcd_timing.v" "$RTL/lcd_timing_gen.v"]] != 0} { set fail 1 }

# ============================================================ 2) UART 16 字节台（旧协议）
if {[run_one "tb_uart_frame" "tb_uart_frame" \
        [list "$SIM/tb_uart_frame.v" "$RTL/lcd_test_support.v" \
              "$SIM/iobuf_stub.v" $PRIMS]] != 0} { set fail 1 }

# ============================================================ 3) UART 26 字节台（新协议 v3）
if {[run_one "tb_uart_frame26" "tb_uart_frame26" \
        [list "$SIM/tb_uart_frame26.v" "$RTL/lcd_test_support.v" \
              "$SIM/iobuf_stub.v" $PRIMS]] != 0} { set fail 1 }

# ============================================================ 4) 按键台（F4）
if {[run_one "tb_key_ctrl" "tb_key_ctrl" \
        [list "$SIM/tb_key_ctrl.v" "$RTL/key_ctrl.v"]] != 0} { set fail 1 }

# ============================================================ 5) 画面台（F1/F2/F3）
if {[run_one "tb_screen_pattern" "tb_screen_pattern" \
        [list "$SIM/tb_screen_pattern.v" "$RTL/screen_pattern.v"]] != 0} { set fail 1 }

# ============================================================ 6) IIC 触摸台
set TOUCH_SRC [list "$SIM/tb_touch_i2c.v" "$SIM/iic_slave_model.v" "$SIM/iobuf_stub.v" \
                    "$RTL/lcd_test_support.v" "$RTL/i2c_master_seq.v" \
                    "$RTL/touch_i2c_ctrl.v"]

# 6a) GT911 从机（屏上装的是 GT911/GT1151 时走这条）
if {[run_one "tb_touch_i2c (GT911 假从机)" "tb_touch_i2c" $TOUCH_SRC] != 0} { set fail 1 }

# 6b) FT5206 从机（同一份 RTL，只换假从机型号；探测链 GT->FT 的回归）
if {[run_one "tb_touch_i2c (FT5206 假从机)" "tb_touch_i2c" $TOUCH_SRC \
        [list "SLAVE_FT5206"] "FT5206"] != 0} { set fail 1 }

# ============================================================ 7) 集成台
if {[run_one "tb_lcd2_top (集成)" "tb_lcd2_top" \
        [list "$SIM/tb_lcd2_top.v" "$SIM/iic_slave_model.v" "$SIM/iobuf_stub.v" \
              $PRIMS \
              "$RTL/lcd_test_support.v" "$RTL/i2c_master_seq.v" \
              "$RTL/touch_i2c_ctrl.v" "$RTL/lcd_timing_gen.v" \
              "$RTL/key_ctrl.v" "$RTL/screen_pattern.v" \
              "$RTL/lcd_test2_top.v"]] != 0} { set fail 1 }

# ============================================================ 8) IIC 看门狗台
#   上板出现过"一碰就永久停摆"（主机相位被拖住 + 旧看门狗是死代码）。
#   本台用一个把 BUSY_LIMIT 调得很小的实例强制触发看门狗，验证 S_RECOVER
#   恢复路径能给出 done、且恢复后还能继续发第二次请求；另一个正常实例验证
#   常规路径（无应答 -> NACK 结束）不会被误判成超时。
if {[run_one "tb_i2c_watchdog" "tb_i2c_watchdog" \
        [list "$SIM/tb_i2c_watchdog.v" "$RTL/i2c_master_seq.v"]] != 0} { set fail 1 }

if {$fail} { puts "SIM_LCD2_DONE (with errors)" } else { puts "SIM_LCD2_DONE" }
