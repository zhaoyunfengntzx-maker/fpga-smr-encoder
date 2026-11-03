# =============================================================================
#  lcd_test.xdc  —— 7 寸 RGB-LCD 屏 + 电容触摸基本性能测试程序的约束
#  目标器件: xc7a35tfgg484-2   (正点原子 达芬奇-lite)
#
#  ★ 本文件是"独立小工程"的约束，与 constr/enc_top.xdc 互不干涉。
#    两个顶层（enc_top / lcd_rgb_test_top）永远分开综合，不要同时读入两个 xdc。
#
#  引脚来源（三方交叉验证，详见 docs/RGB_LCD_wiring_check.md）：
#    · 《达芬奇-lite 之 FPGA 开发指南》表 2.1.1（LCD 与触摸信号 → 球号）
#    · 板级原理图 Davinci_Lite_1V0.pdf 第 13 页 J7(RGB_TFTLCD) 的矢量几何重建
#      —— 30 个 LCD_* 网络与指南表逐条一致，0 个不一致
#    · 开发板 IO 引脚分配表 .xlsx（独立第三方，同样一致）
#
#  Bank 电压：本节用到的引脚全部在 **Bank 34**（VCCIO 固定 +3.3V 轨），
#            不需要拨 J9/J10 跳线。sys_clk(V4)/key_n(W9) 也在 Bank 34。
#            uart_tx 在 Bank 14（同样固定 3.3V）。
#
#  ★ 数据线方向：lcd_rgb[23:0] 是**双向**引脚（同时挂屏 ID 分压电阻），
#    约束成 IOBUF 由 RTL 的三态赋值决定，xdc 里不需要也不应该加
#    set_property DIRECTION —— 综合器按 RTL 的 1'bz 赋值自动推断。
# =============================================================================

# -----------------------------------------------------------------------------
# 1. 时钟与配置
# -----------------------------------------------------------------------------
# 板载 50 MHz 晶振 -> sys_clk，引脚 V4，Bank 34
# 本例中它就是 LCD 的像素时钟（ATK-7016 要求 50MHz），所以不建 MMCM。
set_property -dict {PACKAGE_PIN V4  IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk -waveform {0.000 10.000} [get_ports sys_clk]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# -----------------------------------------------------------------------------
# 2. 按键（板载 KEY1，低有效，Bank 34）
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN W9  IOSTANDARD LVCMOS33} [get_ports key_n]

# -----------------------------------------------------------------------------
# 3. UART 遥测输出（Bank 14）
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVCMOS33} [get_ports uart_tx]

# -----------------------------------------------------------------------------
# 4. 到 J7（RGB_TFTLCD，40P 0.5mm FPC）的 LCD 接口 —— 全部 Bank 34
# -----------------------------------------------------------------------------
# 4.1 24 位 RGB888 数据线：高 8 位 = R，中 8 位 = G，低 8 位 = B
#     线序即 J7 针号：R0..R7 = 3,4,5,6,7,8,9,10；G0..G7 = 12..19；B0..B7 = 21..28
set_property -dict {PACKAGE_PIN V9   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[0]}]
set_property -dict {PACKAGE_PIN AB8  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[1]}]
set_property -dict {PACKAGE_PIN V8   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[2]}]
set_property -dict {PACKAGE_PIN AB7  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[3]}]
set_property -dict {PACKAGE_PIN AA8  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[4]}]
set_property -dict {PACKAGE_PIN AB6  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[5]}]
set_property -dict {PACKAGE_PIN Y8   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[6]}]
set_property -dict {PACKAGE_PIN AA6  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[7]}]
set_property -dict {PACKAGE_PIN W7   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[8]}]
set_property -dict {PACKAGE_PIN Y7   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[9]}]
set_property -dict {PACKAGE_PIN V7   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[10]}]
set_property -dict {PACKAGE_PIN AB5  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[11]}]
set_property -dict {PACKAGE_PIN Y6   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[12]}]
set_property -dict {PACKAGE_PIN AB3  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[13]}]
set_property -dict {PACKAGE_PIN AA3  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[14]}]
set_property -dict {PACKAGE_PIN U6   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[15]}]
set_property -dict {PACKAGE_PIN V5   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[16]}]
set_property -dict {PACKAGE_PIN AB1  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[17]}]
set_property -dict {PACKAGE_PIN AA4  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[18]}]
set_property -dict {PACKAGE_PIN AA1  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[19]}]
set_property -dict {PACKAGE_PIN Y3   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[20]}]
set_property -dict {PACKAGE_PIN Y1   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[21]}]
set_property -dict {PACKAGE_PIN Y4   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[22]}]
set_property -dict {PACKAGE_PIN W1   IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {lcd_rgb[23]}]

# 4.2 同步与时钟（DE 模式：HS/VS 低有效，DE 高=数据有效）
set_property -dict {PACKAGE_PIN U1  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports lcd_pclk]
set_property -dict {PACKAGE_PIN AB2 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports lcd_hs]
set_property -dict {PACKAGE_PIN T1  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports lcd_vs]
set_property -dict {PACKAGE_PIN W2  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports lcd_de]
# 背光：高电平点亮（Y2）
set_property -dict {PACKAGE_PIN Y2  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports lcd_bl]
# 屏复位：低有效（R2）
set_property -dict {PACKAGE_PIN R2  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports lcd_rst]

# -----------------------------------------------------------------------------
# 5. 电容触摸 IC 的 IIC 接口（Bank 34）
#    ★ 板级网络名沿用了电阻屏的 T_* 命名，但本屏是电容屏，实际走 IIC：
#      T_SCK/T4 -> SCL，T_PEN/U5 -> SDA，T_MOSI/W6 -> 不可用（指南表里没有），
#      touch_rst_n/W4 -> 触摸 IC 复位，touch_int/T5 -> 中断
#    ★ SCL/SDA 是开漏信号，RTL 用 IOBUF 实现；板上有上拉，xdc 不需要 PULLUP。
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN T4  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports touch_scl]
set_property -dict {PACKAGE_PIN U5  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports touch_sda]
set_property -dict {PACKAGE_PIN W4  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports touch_rst_n]
#      ★ touch_int 现在是 inout：复位期间 FPGA 把它拉低（GT911 在 RST 上升沿按
#        INT 电平锁存器件地址），把地址定死在 0x5D；之后释放成高阻，并靠
#        内部弱上拉把开漏的 INT 拉高，芯片才能用低脉冲报"有数据"。
set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLTYPE PULLUP} [get_ports touch_int]

# -----------------------------------------------------------------------------
# 6. 时序例外
# -----------------------------------------------------------------------------
# 6.1 LCD 输出：pclk 与数据同源同沿（RTL 里都是 sys_clk 的寄存器输出），
#     从 pclk 到数据的偏斜由布线决定。给出宽松的输出延时约束即可，
#     真正的采样在屏侧按 pclk 上升沿进行。
set_output_delay -clock sys_clk -max  5.000 [get_ports {lcd_rgb[*]}]
set_output_delay -clock sys_clk -min -1.000 [get_ports {lcd_rgb[*]}]
set_output_delay -clock sys_clk -max  5.000 [get_ports {lcd_hs lcd_vs lcd_de lcd_bl lcd_rst}]
set_output_delay -clock sys_clk -min -1.000 [get_ports {lcd_hs lcd_vs lcd_de lcd_bl lcd_rst}]

# 6.2 触摸中断：复位窗口内是 FPGA 输出（恒 0），之后是屏侧异步输入
set_input_delay -clock sys_clk -max 10.000 [get_ports touch_int]
set_input_delay -clock sys_clk -min  0.000 [get_ports touch_int]
set_output_delay -clock sys_clk -max  5.000 [get_ports touch_int]
set_output_delay -clock sys_clk -min -1.000 [get_ports touch_int]
set_false_path -from [get_ports touch_int]
set_false_path -to   [get_ports touch_int]

# 6.3 IIC 与按键都是"慢变/异步"信号，静态时序分析对它们没有意义
set_false_path -from [get_ports {key_n touch_sda}]
set_false_path -to   [get_ports {touch_scl touch_sda touch_rst_n lcd_rst}]
