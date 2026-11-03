# -----------------------------------------------------------------------------
#  lcd_test/tools/sim_lcd_test.tcl  —— LCD 测试程序三个自检测试台的仿真脚本
#
#  运行（推荐用封装脚本，它会设好 PATH / HOME / GOLD 许可）：
#     powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_vivado.ps1 `
#         -Tcl lcd_test\tools\sim_lcd_test.tcl -LogFile _lcd_work\sim_lcd.log -Tail 200
#     抓结果（每个测试台的 stdout 另存一份，便于单独 grep）：
#         Select-String -Path _lcd_work\sim_lcd.log -Pattern 'TEST PASSED|TEST FAILED'
#
#  测试台：
#     1) tb_lcd_timing   时序发生器（含"场计数不被像素使能门控"的回归）
#     1b) tb_uart_frame  UART 一帧 16 字节的 8N1 帧级校验（逐字节 + 停止位）
#     2) tb_touch_i2c    IIC 触摸路径（GT911 / FT5206 假从机各跑一遍）
#     3) tb_lcd_rgb_top  集成（屏 ID -> 时序 -> 触摸 -> 按键 -> UART）
#
#  注意 1：★ 必须用 exec 调 xvlog/xelab/xsim。Vivado 的 Tcl 解释器本身没有这些
#          命令，不写 exec 会退化成"发给 OS shell"，然后报
#          invalid command name "xvlog"。
#  注意 2：★ 必须把子进程的 stdout 重定向进文件再回读。exec 只把输出收进 Tcl
#          的返回值，不会转发到 Vivado 的 console/log —— 这就是第一轮仿真
#          "跑了但日志里看不到任何 TEST PASSED/FAILED" 的原因。
#          用 try/finally：即使被 exec 抛错（xsim 非 0 退出），照样回读日志。
#  注意 3：本机没有预编译的 xsim 库，所以必须把 IOBUF 等原语的桩模型一起编译
#          （lcd_test/sim/iobuf_stub.v、sim/xilinx_prims_stub.v）。
#  注意 4：时间缩放做在 tb_lcd_rgb_top.v 源码里（localparam TEST_SPEEDUP），
#          这里不再传 -generic_top（本测试台没有对应 parameter，传了会报
#          ERROR: [XSIM 43-3281] Parameter/Generic ... not found in design）。
# -----------------------------------------------------------------------------

set ROOT   "C:/Users/zhaoy/Desktop/FPGA"
set RTL    "$ROOT/lcd_test/rtl"
set SIM    "$ROOT/lcd_test/sim"
set WORK   "$ROOT/_lcd_work/xsim_lcd"
set env(PATH) "D:/Vivado/2026.1/Vivado/bin;$env(PATH)"
# 注意 5：★ 每次跑之前必须清空工作库。工作目录里已经有编译好的库时，xvlog 会
#         卡在启动阶段（实测：CPU 满载、xvlog.log 一直 0 字节、20 分钟无输出）。
#         删掉整个 $WORK 重建即可稳定复现（见 docs/LCD_touch_test_readme.md §12）。
if {[file exists $WORK]} { file delete -force $WORK }
file mkdir $WORK
cd $WORK

proc banner {t} {
    puts "=============================================================="
    puts " $t"
    puts "=============================================================="
}

# 跑一个测试台：xvlog -> xelab -> xsim -R，并把 xsim 的 stdout 回读进本日志
#   defs：可选的 xvlog `-d` 预定义（例如 {SLAVE_FT5206}）。注意 xvlog 只支持
#         `-d 名字`，不支持 `-d 名字=值`（会报 ERROR: [XSIM 43-4316] Can not find file）
#   impl_name：xelab 的 top 与 snapshot 名（用 -d 改从机类型时仍需与文件名同名的 top）
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

# ============================================================ 1b) UART 帧级台
#   ★ 这一条是 2026-10-14 上板实测之后补的：集成台只验证了「UART 有起始位输出」，
#     从没逐字节校验过一帧。上板才发现 115200 8N1 每字节被发成 11 位
#     （起始 + 8 数据 + 重复的 MSB + 停止）⇒ PC 侧帧被截断、字节错位。
#     本台用 8N1 接收模型逐位采样，把 16 字节全解出来比对。
if {[run_one "tb_uart_frame" "tb_uart_frame" \
        [list "$SIM/tb_uart_frame.v" "$RTL/lcd_test_support.v" \
              "$SIM/iobuf_stub.v" "$ROOT/sim/xilinx_prims_stub.v"]] != 0} { set fail 1 }

# ============================================================ 2) IIC 触摸台
set TOUCH_SRC [list "$SIM/tb_touch_i2c.v" "$SIM/iic_slave_model.v" "$SIM/iobuf_stub.v" \
                    "$RTL/lcd_test_support.v" "$RTL/i2c_master_seq.v" \
                    "$RTL/touch_i2c_ctrl.v"]

# 2a) GT911 从机（屏上装的是 GT911/GT1151 时走这条）
if {[run_one "tb_touch_i2c (GT911 假从机)" "tb_touch_i2c" $TOUCH_SRC] != 0} { set fail 1 }

# 2b) FT5206 从机（同一份 RTL，只换假从机型号；探测链 GT->FT 的回归）
#     ★ 这一趟能抓到"GT 探测失败后没有立刻排 FT 探测"这类只在 FT 屏上暴露的问题
if {[run_one "tb_touch_i2c (FT5206 假从机)" "tb_touch_i2c" $TOUCH_SRC \
        [list "SLAVE_FT5206"] "FT5206"] != 0} { set fail 1 }

# ============================================================ 3) 集成台
if {[run_one "tb_lcd_rgb_top (集成)" "tb_lcd_rgb_top" \
        [list "$SIM/tb_lcd_rgb_top.v" "$SIM/iic_slave_model.v" "$SIM/iobuf_stub.v" \
              "$ROOT/sim/xilinx_prims_stub.v" \
              "$RTL/lcd_test_support.v" "$RTL/i2c_master_seq.v" \
              "$RTL/touch_i2c_ctrl.v" "$RTL/lcd_timing_gen.v" \
              "$RTL/lcd_test_pattern.v" "$RTL/lcd_rgb_test_top.v"]] != 0} { set fail 1 }

if {$fail} { puts "SIM_LCD_TEST_DONE (with errors)" } else { puts "SIM_LCD_TEST_DONE" }
