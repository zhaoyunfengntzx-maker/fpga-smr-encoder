# ===========================================================================
# xdc_source_sync.xdc —— 约束骨架：主时钟 / 派生时钟 / 源同步输入 / 异步跨域
#
# 这不是能直接跑的约束（片脚号要按你的板卡改），而是"每一类信号该写哪一种约束"
# 的填空模板。骨架里每个 <...> 都要替换，每段注释写了"为什么这么写"以及
# "写错会怎样"——后者都是本工程真实踩过的坑（见 skill/adc-source-sync-constraints.md）。
#
# 失效条件：面向"源同步接口 + 单一时钟域"的设计。DDR 源同步要补 -clock_fall 的第二组
#   约束；有 PS/MMCM 时必须由工具生成主时钟，不要手写 create_clock 覆盖；
#   多器件共享时钟要显式 set_clock_groups，否则会被误判为异步而"时序全绿"。
#
# 判定标准只有一条：写完之后 `report_check_timing` 里 no_input_delay / no_output_delay
# 必须为 0；如果有豁免，豁免必须能在本文件里找到对应的一行 set_false_path，
# 不允许"心里知道它不用管"。本工程 v74 有 5 条 no_input_delay、2 条 no_output_delay，
# 全部由文件的 false_path 段落显式覆盖（见 check_timing.rpt），评审可逐条对账。
# ===========================================================================

# --------------------------------------------------------------------------
# 1. 主时钟：来自晶振/外部时钟芯片，只有这一处 create_clock
# --------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
# 周期必须用真实值（20 ns = 50 MHz）。随手写 10 ns 会让工具"更努力地"优化，
# 表面上 WNS 更好看，实际板子上跑不出来——报告与硬件脱钩，这是最隐蔽的造假。

# --------------------------------------------------------------------------
# 2. 复位：按键输入，异步，不参与时序分析
# --------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33} [get_ports key_n]
set_false_path -from [get_ports key_n]
# 只对"真异步"写 false_path。如果复位在内部做了同步器，就不要再 false 中途路径，
# 而应该 -from [get_ports key_n] 到第一级同步器为止。

# --------------------------------------------------------------------------
# 3. 外部器件给出的采样时钟：管脚进来 → ODDR 转成时钟
#    典型：ADC 的 DCO / 编码器的 CLK。这一类必须 create_clock + 源同步延迟
# --------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33} [get_ports ad_clk_in]
create_clock -period 16.667 -name ad_clk [get_ports ad_clk_in]
# 外部时钟的周期来自数据手册（60 MHz → 16.667 ns），不是你的分频比。

# --------------------------------------------------------------------------
# 4. 源同步输入：数据与时钟同源，用 set_input_delay 描述"数据相对时钟的窗口"
#    ★ 这一段是整个文件最容易写反的地方
# --------------------------------------------------------------------------
# 语义：set_input_delay 描述的是"数据在捕获时钟沿之前多久稳定 / 之后多久变化"。
#   -max：数据最晚到达（used by setup）  = tCO_max + 走线延时_max
#   -min：数据最早到达（used by hold）   = tCO_min + 走线延时_min
# 常见错误：把 -max 写成负数、或把范围写成 [-a, +a] 对称，等于宣布
# "数据可能在时钟沿之后才有效"，工具只能报负余量。这不是工具严格，是你的模型错了。
set ad_data [get_ports {ad_data[*]}]
set_input_delay -clock ad_clk -max 6.0  $ad_data
set_input_delay -clock ad_clk -min 2.0  $ad_data
# 本工程项目里这组数值是 tPD 2..6 ns（ADC 数据手册 + 走线），
# 由此得到的负余量是**诚实建模**的结果，不是 bug 也不是要藏起来的数字。

# 差分/双沿采样时，DDR 要分别写 -clock_fall 的两组延迟
# set_input_delay -clock ad_clk -clock_fall -max 6.0 $ad_data
# set_input_delay -clock ad_clk -clock_fall -min 2.0 $ad_data

# 采样时钟如果是内部 MMCM 生成的，用 generated clock 承接，不要凭空再 create_clock
# create_generated_clock -name ad_clk_s [get_pins u_mmcm/CLKOUT0] -source [get_ports ad_clk_in] -divide_by 1

# --------------------------------------------------------------------------
# 5. 输出到外部器件：同理，用 set_output_delay 描述对方需要的建立/保持窗口
# --------------------------------------------------------------------------
set led_out [get_ports {led[*]}]
set_output_delay -clock sys_clk -max 2.0 $led_out
set_output_delay -clock sys_clk -min 0.5 $led_out

# --------------------------------------------------------------------------
# 6. 真正的异步跨域：用 set_clock_groups，不要用一堆 set_false_path 打补丁
# --------------------------------------------------------------------------
set_async_clks [list sys_clk ad_clk]
set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks ad_clk]
# 用了 -asynchronous 之后，跨域路径就不再被分析；因此**必须**在 RTL 侧有
# 两级同步器（rtl/cdc_sync2.v 这类），并把它写进设计说明——
# 约束只能声明"我不分析"，它不能替你保证功能正确。

# --------------------------------------------------------------------------
# 7. 纯粹的测试/调试口：显式豁免，且每条都能对账
# --------------------------------------------------------------------------
set_false_path -from [get_ports {spi_mosi spi_sck spi_ss_n uart_rx}]
# 这些是慢速人工接口（< 1 MHz），分析它们只会淹没真问题。
# 但"豁免"这件事本身必须写下来：v74 的 check_timing 报告里 no_input_delay=5，
# 评审看到 5 会问，文件里这 5 个端口一目了然。
