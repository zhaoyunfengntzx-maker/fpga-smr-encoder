# =============================================================================
#  enc_top.xdc  —— 正余弦细分编码器  时序与引脚约束
#  目标器件: xc7a35tfgg484-2   (正点原子 达芬奇-lite)
#  Vivado / Vitis 2026.1（本机实跑；早期注释写的 2020.2+ 是上机前的假设）
# =============================================================================
#
#  ★★ 引脚已按权威来源实配（不再是草案）★★
#  数据来源（厂商官方 + 原理图几何提取，三方交叉验证）：
#    · AD9238_carrier_pin_map.xls  工作表 "XC7A35A100V2.0"
#      ★ 该表的列头原文是 "…XC7A35V2.0T扩展口J6/J7/J11对应管脚" ——
#        这三个口是 **XC7A35V2.0T 那块板**的扩展口，不是达芬奇-lite 的排针！
#        达芬奇-lite 上叫 J7 的是 RGB_TFTLCD，压根没有 J11 连接器。
#        但把三套映射按 bank 归类后可以确定对应关系：
#          vendor J6 列 = 38/38 全在 Bank 14（本板以太网/HDMI/IIC/TF/LED，未引出）
#          vendor J7 列 = 39/39 全在 Bank 16  ← 只有这一列落在真实排针上
#          vendor J11列 = 39/39 全在 Bank 34（RGB LCD + V4=sys_clk）
#        ⇒ vendor 的 "J7" 列对应达芬奇-lite 的 **J6** 排针（Header_2*26，Bank16）。
#    · AD9238_carrier_schematic.pdf + HSTAD9238_module_manual.pdf（网络与针号，两源互证）
#    · DLC35_io_occupancy.xlsx —— 本板 110 个已占用引脚
#    · 达芬奇-lite 原理图 sheet 13 的 J5/J6 符号几何 —— 针→球号（tools/pdf_text.py）
#
#  ★★ 最终接法（两根排针）★★
#    · AD9238 载板（40 针）插 **J6**（Bank 16，轨 VCCIO_B16），28 个信号见第 3 节。
#      28 个球全部是 Bank 16，且没有一个是本板 110 引脚占用表里的引脚。
#      ★ 注意：vendor 表里 "J7" 列的**针号**与本板 J6 排针不一致（0/28 对得上），
#        所以绝不能直接照抄 vendor 表的针号，必须用本节的球号（由几何量取）。
#    · ABZ/SPI/led[2:3]/irq_n 共 13 根走 **J5**（Bank 15，轨 VCCIO_B15），见第 4-8 节。
#      J6 被模块整块占用后只剩 6/7/8、19/20、25、40 七个"不用"位，
#      放不下 13 根线，且那几个位置的球号无法从原理图量出 ⇒ 改走 J5。
#      J5 的 48 个信号球经校验全部 Bank 15 且未被板载外设占用（_synth_work/j5.py）。
#
#  ★ 两路 ADC 时钟：载板上 AD1CLK 与 AD2CLK 是**两根独立网络**
#    （AD1CLK = J6-26 + U1-63 CLK_A；AD2CLK = J6-9 + U1-18 CLK_B），
#    无时钟缓冲器、无板上晶振。因此 rtl/enc_top.v 用两个 ODDR 输出
#    ad_clk (J6-26/B18) 与 ad_clk2 (J6-9/F16)，各自建生成时钟。
#
#  Bank 电压 ★ 两个都必须跳线到 3.3V ★
#    · Bank 16 的 VCCIO 网络是 VCCIO_B16，由三位跳线 **J10** 从可调 LDO U22
#      (SPX3819M5, VIN=+5V) 选择 3.3/2.5/1.8V —— 不是固定 3.3V，必须拨到 3.3V；
#    · Bank 15 的 VCCIO 网络是 VCCIO_B15，同样由跳线 **J9** 选择，也要拨到 3.3V。
#    · sys_clk / key_n 在 **Bank 34**（+3.3V 固定轨）；
#      led[0] / led[1] / uart_tx 在 **Bank 14**（+3.3V 固定轨）。
#    · Artix-7 的 IO Bank 全部是 HR，3.3V 合法。
#    以上 bank 划分由 Vivado 查询器件封装得到（_synth_work/pkgpins.csv）。
# =============================================================================

# -----------------------------------------------------------------------------
# 1. 主时钟与器件配置
# -----------------------------------------------------------------------------
# 板载 50 MHz 晶振 -> sys_clk，引脚 V4，LVCMOS33
set_property -dict {PACKAGE_PIN V4  IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk -waveform {0.000 10.000} [get_ports sys_clk]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# -----------------------------------------------------------------------------
# 2. 复位按键（低有效）
# -----------------------------------------------------------------------------
# enc_top 的复位输入端口名是 key_n（低有效），内部已做两级同步 + 去抖。
# ★ 端口名是 key_n，不是本文件早期版本注释里写的 rst_key_n（该端口在设计中不存在）。
# key_n 接到板上用户按键 KEY0（引脚 W9，低有效）——按一下触发一键标定。
# 注：USER KEY1（Y9）本设计未使用，保留不约束。
set_property -dict {PACKAGE_PIN W9 IOSTANDARD LVCMOS33} [get_ports key_n]
set_false_path -from [get_ports key_n]   ;# 异步复位按键，内部已做两级同步 + 去抖

# -----------------------------------------------------------------------------
# 3. AD9238 接口（达芬奇-lite **J6** 扩展口，28 个信号 —— 原理图几何定案）
#    · 载板 AD1CLK 与 AD2CLK 是**两根独立网络**，故用两个 ODDR 分别驱动：
#        ad_clk  -> 载板 J6-26 / AD1CLK
#        ad_clk2 -> 载板 J6-9  / AD2CLK
#    · AD9238 无 DCO；数据在 CLK 上升沿后 tPD = 2..6 ns 有效
#
#    模块针 -> 网络 -> 达芬奇 J6 针 -> FPGA 引脚（全部 Bank 16）
#      26  AD1CLK   J6-26  B18     9  AD2CLK   J6-9   F16
#      27  AD1D0    J6-27  F18    10  AD2D0    J6-10  E17
#      28  AD1D1    J6-28  E18    11  AD2D1    J6-11  C13
#      29  AD1D2    J6-29  C17    12  AD2D2    J6-12  B13
#      30  AD1D3    J6-30  D17    13  AD2D3    J6-13  E16
#      31  AD1D4    J6-31  A18    14  AD2D4    J6-14  D16
#      32  AD1D5    J6-32  A19    15  AD2D5    J6-15  A13
#      33  AD1D6    J6-33  C18    16  AD2D6    J6-16  A14
#      34  AD1D7    J6-34  C19    17  AD2D7    J6-17  D14
#      35  AD1D8    J6-35  F20    18  AD2D8    J6-18  D15
#      36  AD1D9    J6-36  F19    21  AD2D9    J6-21  C14
#      37  AD1D10   J6-37  B20    22  AD2D10   J6-22  C15
#      38  AD1D11   J6-38  A20    23  AD2D11   J6-23  B15
#      39  AD1_OTR  J6-39  E19    24  AD2_OTR  J6-24  B16
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports ad_clk]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports ad_clk2]

set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[0]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[1]}]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[2]}]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[3]}]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[4]}]
set_property -dict {PACKAGE_PIN A19 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[5]}]
set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[6]}]
set_property -dict {PACKAGE_PIN C19 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[7]}]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[8]}]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[9]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[10]}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports {ad_ch1_d[11]}]

set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[0]}]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[1]}]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[2]}]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[3]}]
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[4]}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[5]}]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[6]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[7]}]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[8]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[9]}]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[10]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports {ad_ch2_d[11]}]

set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports ad_ch1_otr]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports ad_ch2_otr]

# --- OTR 输入内部下拉（2026-10-10 修法 A）-------------------------------------
#   背景：模块的 OTR 引脚在示波器上是静低 + 约 60 mV 毛刺，但 FPGA 侧 otr_lat
#   仍会偶发置位并 sticky 锁存；ILA 抓到的置位瞬间（_synth_work/iladata4.csv
#   第 512 拍）原始采样 s_raw=0 / c_raw=1632 = 0.797 FS，全窗无撞轨、cor_sat=0
#   ⇒ 数据侧没有任何超量程证据 ⇒ 判为假 OTR，最可能是模块未把 OTR 真正引到
#   排线上、FPGA 这两根输入浮空，偶发被串扰拉过阈值。
#   · 模块真的在驱动 OTR 时，弱下拉无害（推挽输出直接覆盖 ~10~50k 下拉）；
#   · 模块没驱动/断线时，下拉把输入钉在 0，杜绝浮空假高。
#   若日后确认模块确实驱动 OTR 且需要长线抗扰，可改为 PULLUP 或外部上拉。
set_property PULLTYPE PULLDOWN [get_ports {ad_ch1_otr ad_ch2_otr}]

# --- AD9238 时序约束 ---------------------------------------------------------
# 【v1 极简时钟方案，强烈推荐先用这个把功能跑通】
#   · 不使用 MMCM / 不使用任何 IP：板载 50MHz 经 BUFG 作为全系统唯一时钟 clk50
#   · ad_clk 由 ODDR 转发到引脚。**v10 起为同相（D1=1/D2=0）**：
#         ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) u_ad_clk_oddr (
#             .Q(ad_clk), .C(clk50), .CE(1'b1), .D1(1'b1), .D2(1'b0),
#             .R(1'b0), .S(1'b0));
#     （D1=1/D2=0 -> ad_clk 上升沿与 clk50 上升沿同相；v9 及以前是 D1=0/D2=1 的反相方案，
#       它在 50 MHz 下只留约 4 ns 捕获窗口，已由 2026-10-12 的相位对照实验证伪，见 §1.57⑧）
#   · ADC 数据在 clk50 的【上升沿】捕获（模块内部就是 posedge，无需改代码）
#   · 整个设计只有一个时钟域，零 CDC 风险，零 IP 依赖
#
#   时序推导（★ 下面这段只算了"引脚到引脚"的延迟、**漏掉了两条时钟网络路径**，
#   所以结论偏乐观，已被 2026-10-10 的实测重写取代）：
#     ad_clk 上升沿在 clk50 上升沿后 10 ns；ADC 在该沿后 tPD=2..6 ns 输出数据，
#     加约 1 ns 走线 -> 数据在 clk50 上升沿后 13..17 ns 到达 FPGA 引脚；
#     下一个 clk50 上升沿在 20 ns 处捕获 -> 当时算出的"建立余量 = 20 - 17 = 3 ns"。
#   ★ 但那 13..17 ns 是相对 **ODDR/C 看到的那一拍**，而 ODDR/C 与 ADC 捕获寄存器
#     看到的时钟沿本身都滞后于 sys_clk 引脚沿（前者实测 3.762 ns、后者约 4.0–4.6 ns，
#     见 `_synth_work/impl_timing.rpt`），再加上 ad_clk 从 ODDR 到引脚的 3.016 ns，
#     真实余量远小于 3 ns ⇒ **完整推导与诚实约束值见下面"★★★ 2026-10-10 重写"**，
#     不要再只看这一段就下结论。
#   请按你实际的排线长度调整下面 set_input_delay 的 max 值（走线每 15 cm 约 1 ns）。
#
# ★★★ 2026-10-12 采纳 v10 相位（D1=1/D2=0）——本次改动**去掉了 `-invert`** ★★★
#   证据（热点工作点上的 v9/v10/v9 相位对照，同一 AFG 档位、全程无人触碰旋钮）：
#     A1(v9) 30 s = 907 个 gl_1024（30.2 次/s）→ B(v10) 30 s = **0** → A2(v9) 30 s = 681（22.7 次/s）；
#     独立 5 s 记录器（tools/sweep_rate.py）同时确认 v10 期间 45 s 内计数器恒为复位值。
#   机理：v10 把 ODDR 由"反相 180°"改成"同相"，ad_clk 引脚上升沿相对 sys_clk 前移 10 ns，
#   数据有效沿到捕获沿的窗口由约 4 ns 变成约 14 ns。因此下面的 set_input_delay 诚实值
#   也由 24.000/19.500 改为 **14.000/9.500**（推导：3.762 + 0 + 3.016 + tPD(2..6) + 排线 1 ns）。
#   详见 docs/DEV_STATUS.md §1.57⑧。
create_generated_clock -name adc_clk -source [get_pins u_ad_clk_oddr/C] \
    -divide_by 1 [get_ports ad_clk]

# ★ 第二路 ADC 时钟（载板 AD2CLK / J6-9）。载板的 AD1CLK 与 AD2CLK 是两根
#   独立网络，故必须各自约束；两个 ODDR 的输入同为 clk_i，参数完全一致。
create_generated_clock -name adc_clk2 -source [get_pins u_ad_clk2_oddr/C] \
    -divide_by 1 [get_ports ad_clk2]
#   （2026-10-12：同 adc_clk，随 v10 相位去掉 `-invert`；两路 ODDR 参数始终一致。）

set_output_delay -clock adc_clk  -max 3.000 [get_ports ad_clk]
set_output_delay -clock adc_clk  -min 1.000 [get_ports ad_clk]
set_output_delay -clock adc_clk2 -max 3.000 [get_ports ad_clk2]
set_output_delay -clock adc_clk2 -min 1.000 [get_ports ad_clk2]

# ★★ 关键修正一（实现阶段 route_design 实测发现，保留）★★
#   早期版本把这三条 set_input_delay 绑在 `-clock adc_clk` 上。但 adc_clk 是用
#   `-invert` 声明的**反相**生成时钟，于是工具认为 adc_clk 的上升沿落在
#   clk50 下降沿之后，跨时钟需求被算成只有 **10 ns**：
#       Requirement: 10.000ns (sys_clk rise@20.000ns - adc_clk rise@10.000ns)
#   而实际数据路径是 IBUF + 互连（实测 2.2 ns）再加上输入延迟 7 ns，必然不收敛：
#       第一次实现 WNS = -4.072 ns / TNS = -80.2 ns（26 条 adc_clk->sys_clk 路径全红）
#   ⇒ 输入延迟必须绑到**捕获时钟 sys_clk**。
#
# ★★★ 2026-10-10 重写（原文有一处**已被证伪**的推导，务必不要再改回去）★★★
#   原文（本轮之前）声称"ad_clk 上升沿与采样它的 clk50 上升沿在引脚上是**同一个
#   物理时刻**（ODDR 的 180° 相移恰好补偿了引脚到捕获寄存器的延迟）"，并据此取
#   max = 7.000 / min = -1.000。这句话有三处问题：
#     ① 与本文件第 130 行自己写的"ad_clk 上升沿比 clk50 上升沿晚 10 ns"直接矛盾；
#     ② 与真原语对照实验的结论相反（见 docs/DEV_STATUS.md §1.14 与 §3 第 8 条）；
#     ③ 它引用的"本文件第 86-91 行的推导"是**悬空引用**（那里是 ad_ch1_d 管脚区）。
#   从在盘报告 `_synth_work/impl_timing.rpt` 的 ad_clk 输出路径可以量出真相：
#       Source Clock Delay（sys_clk 引脚 → ODDR/C）        = 3.762 ns
#       半周期（ODDR D1=0/D2=1 在 C 的下降沿翻高）          = 10.000 ns
#       adc_clk 生成时钟到引脚的插入延迟（ODDR Tco + OBUF）= 3.016 ns
#       ⇒ ad_clk 引脚上升沿 ≈ 3.762 + 10.000 + 3.016 = 16.78 ns（相对 sys_clk 引脚沿）
#   再加 ADC 的 tPD = 2..6 ns（AD9238 手册）与排线 ≈ 1 ns（每 15 cm 约 1 ns）：
#       ⇒ 数据到达 FPGA 引脚的**有效时刻 ≈ 19.78 … 23.78 ns**
#   而捕获寄存器看到的时钟沿 ≈ 20 ns + 时钟网络（IBUF 1.431 + BUFG 0.081 + 互连
#   ≈1.4–1.7 ns）≈ 24.0–24.6 ns ⇒ **最坏情况（tPD=6 ns）建立余量约 −1.6 ns**，
#   典型情况（tPD≈3.5 ns）约 +1 ns。也就是说：50 MHz + 当前 ODDR 相位下，ADC 捕获
#   处在**边界**，并不是原注释说的"3 ns 余量"。
#   本轮据此把约束改成**诚实值**（把整条发射链都算进去，不再依赖那句被证伪的话）：
#       max = 3.762 + 10.000 + 3.016 + 6 + 1 = 23.78 → 24.000 ns
#       min = 3.762 + 10.000 + 3.016 + 2 + 1 = 19.78 → 19.500 ns
#   ⇒ 工具会（正确地）报出 ADC 输入路径的负余量。这**不是约束写坏了**，而是设计
#     **本来就没有 50 MHz 的建立余量保证**；处理顺序见下面"ADC 输入路径余量为负"清单。
#
#   OTR 与数据总线来自同一个 AD9238、走同一排线，故用与数据**相同**的约束值。
#   （早期版本 OTR 写 max 8.000，比数据多 1 ns，且无器件依据。）
#   ★ 2026-10-12（v10 相位生效后）本组数值由 24.000/19.500 改为 **14.000/9.500**：
#     发射沿由"晚 10 ns"变成"同相"，于是 3.762 + 0 + 3.016 + tPD(2..6) + 排线 1 ns
#     ⇒ max = 3.762 + 0 + 3.016 + 6 + 1 ≈ 13.78 → 14.000；min 同理 → 9.500。
#     旧的 24.000/19.500 是 v9（反相）相位下的诚实值，作为历史记录保留在上面。
set_input_delay -clock sys_clk -max 14.000 [get_ports {ad_ch1_d[*] ad_ch2_d[*]}]
set_input_delay -clock sys_clk -min 9.500 [get_ports {ad_ch1_d[*] ad_ch2_d[*]}]
set_input_delay -clock sys_clk -max 14.000 [get_ports {ad_ch1_otr ad_ch2_otr}]
set_input_delay -clock sys_clk -min 9.500 [get_ports {ad_ch1_otr ad_ch2_otr}]

# 【2026-10-10 12:08 生产版重跑实测（这就是诚实模型的代价）】
#   Design Timing Summary：WNS **−3.271 ns** / TNS −84.284 ns / **26 个 failing endpoints**
#   （= 24 根数据 + 2 根 OTR，正好全部输入）、WHS +0.041 ns / 0 失败、WPWS 9.500 / 0 失败；
#   报告结论行是 `Timing constraints are not met.`（第一次出现这个结论）。
#   最差路径 `ad_ch2_d[5] → u_capture/ch2_meta_reg[5]/D`：Requirement 20.000 ns、
#   Input Delay 24.000 ns、Data Path 0.822 ns（IBUF 0.479 + 走线 0.344）、
#   DCD 1.592 ns ⇒ required 21.552 ns vs arrival 24.822 ns。
#   ★ 解读（不要简化成"设计坏了"）：这 26 条**全部**是"ADC 数据相对 sys_clk 的建立关系"，
#     它们由外部往返延迟（ODDR 相移 + 排线 + AD9238 的 tPD）决定，**不是**内部逻辑不收敛；
#     内部寄存器到寄存器的最差路径仍是 18–19 ns 量级、余量为正（生产版最差内部路径见
#     docs/DEV_STATUS.md §2.3）。而且 `rtl/ad9238_capture.v` 对每一位都做了两级
#     `ASYNC_REG` 同步器（ch*_meta → ch*_sync），亚稳态本身是被处理过的。
#     真正的物理风险只有两个：① 采样可能整体晚半拍/一拍（常数延迟，无害）；
#     ② 若捕获沿正好落在数据跳变附近，12 位可能被"撕"成两个样本（有害，必须靠实测排除）。
#   ⇒ 因此**下一步不是改约束，而是按下面的顺序实测**；上板第一件事就是量 tPD_meas。
#   产物已另存 `_synth_work/signoff_adc_honest/`（`enc_top.bit` 1,219,152 B @12:08:30、
#   `impl_timing.rpt` 55,963 B）；采纳诚实约束前的最后一版全约束满足产物在
#   `_synth_work/signoff_0840/`（962,600 B @08:40:17），两者 RTL 相同、只差约束。

# ADC 输入路径余量为负时按以下顺序处理（**先测量、再改功能**，不要直接放宽约束）：
#   1) 上板第一件事：示波器双通道同时探 J6-26(ad_clk) 与 D0，量"ad_clk 上升沿 → D0 跳变"
#      的延迟 tPD_meas。tPD_meas ≤ 4 ns ⇒ 典型件有约 +1 ns 余量，可先继续跑通功能链路；
#      ≥ 5 ns、或 ILA 里 angle_raw 有毛刺 ⇒ 必须改相位，按第 2 条做。
#      ★ 2026-10-12 实测补充（v11 生产版）：CH2 应探 **CH1_D11(J6-38，符号位)** 而不是 D0 ——
#      D0 在满幅正弦下每秒跳变数百万次，5 ns/div（屏宽仅 50 ns）必然"糊成一片"，不是故障；
#      CH1_D11 只在过零点翻转（1 kHz 输入 ⇒ 20.18 kHz），触发挂 CH2 上升沿即可。
#      实测 tPD_meas = 3–4 ns（手册 2…6 ns 内）⇒ v11 建立余量 ≈ +12.3 ns，下面 1)~5) 不必执行。
#   2) 最省事的功能级修复：把 ADC 捕获寄存器改成 **clk_i 下降沿**捕获（同一个 BUFG 时钟、
#      只换边沿），有效建立窗口从 ~7.8 ns 变成 ~17.8 ns、保持余量 ~4 ns；代价是捕获域与
#      后续 posedge 域之间差半个周期，需要在捕获后做一级 posedge 重定时。
#      ★ 注意："晚一个周期再捕获"**没有用**——数据周期与捕获周期相同，相位关系不变。
#   3) 缩短排线（<=5 cm），必要时在 ad_clk 上串 22~33 欧姆端接电阻（见 docs/04 的接线清单）。
#   4) 降低 ADC 采样率（例如 clk_i 每 2 拍捕获一次、ad_clk 相应降为 25 MHz）：余量翻倍，
#      但要同步改 rtl/enc_top.v 的 ODDR/抽取逻辑与 docs 里的指标口径。
#      ★ 注意：**不能**靠"把 create_clock 的 -period 改成 40.000"来降速——sys_clk 是板载
#      50 MHz 晶振的输入时钟，它的周期是物理事实，不是可以随便改的约束（旧注释这里写错了）。
#   5) 万不得已时退回笼统写法（放弃时序分析，靠大余量兜底）：
#      set_false_path -from [get_ports {ad_ch1_d[*] ad_ch2_d[*] ad_ch1_otr ad_ch2_otr}]
#      —— 仅在实测确认波形干净时使用，并在 docs/DEV_STATUS.md 里记明"ADC 输入路径未做
#      时序分析"，不要让它悄悄消失在文档里。
#
# 【v2 可选升级：把 DSP 链搬到 100 MHz 以降低延迟】
#   用 MMCM 生成 clk_adc(50MHz,0°) / clk_cap(50MHz,180°) / clk_sys(100MHz)，
#   并在抽取器输出用一个 toggle 型脉冲同步器（rtl/cdc_sync2.v 里的 cdc_pulse）
#   把 valid 送到 100 MHz 域。抽取后样本稳定时间 = 4 × 20 ns = 80 ns，
#   在 100 MHz 域有 8 个周期，跨域采样完全安全。
#   收益：CORDIC 的 18 拍从 360 ns 降到 180 ns，总延迟从 ~810 ns 降到 ~630 ns。

# -----------------------------------------------------------------------------
# 4. ABZ / UVW 输出  —— 达芬奇-lite J5 扩展口（Header_2*26，Bank 15，VCCIO_B15）
#    ★ J6 排针被 AD9238 载板整块占用（模块 40 针占满 J6-1..40），
#      J6 上仅剩 6/7/8、19/20、25、40 这 7 个"不用"位，放不下 ABZ/SPI 共 10 根，
#      且那几针的球号无法从原理图几何中量出（子代理只量到 pins 2-5 与 9-40）。
#    · 因此第 4/5 节 + led[2:3] + irq_n 共 13 根全部走 J5。
#    · J5 的 48 个信号球经校验全部为 Bank 15 且未被板载外设占用（`_synth_work/j5.py`）。
#    · 与 J6 同属 3.3V 域，但 J5 的 VCCO 由跳线 J9 选择（VCCIO_B15），
#      必须与 J10（VCCIO_B16）一起拨到 3.3V，见 docs/04。
#    · 量产/加分：外接 AM26LV31(RS-422) 或 DS26LV31 差分驱动
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} [get_ports a_out]   ;# J5-5
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports b_out]   ;# J5-6
set_property -dict {PACKAGE_PIN M21 IOSTANDARD LVCMOS33} [get_ports z_out]   ;# J5-7
set_property -dict {PACKAGE_PIN L21 IOSTANDARD LVCMOS33} [get_ports u_out]   ;# J5-8
set_property -dict {PACKAGE_PIN N22 IOSTANDARD LVCMOS33} [get_ports v_out]   ;# J5-9
set_property -dict {PACKAGE_PIN M22 IOSTANDARD LVCMOS33} [get_ports w_out]   ;# J5-10

# -----------------------------------------------------------------------------
# 5. 配置 SPI（从站）—— J5-14..17
#    ★ 这四条也走 J5：J6 上放不下（见第 4 节说明）。
#    ★ 加了这一段之后 UCIO-1 归零，本设计可以生成 bitstream。
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports spi_sck]  ;# J5-14
set_property -dict {PACKAGE_PIN J22 IOSTANDARD LVCMOS33} [get_ports spi_ss_n] ;# J5-15
set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVCMOS33} [get_ports spi_mosi] ;# J5-16
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} [get_ports spi_miso] ;# J5-17

# -----------------------------------------------------------------------------
# 6. 异步输入（内部均有两级同步器 / 边沿检测，声明为 false_path）
#    这是"跨时钟域输入"的标准处理方式：不要在综合器里对同步器前级做时序分析。
# -----------------------------------------------------------------------------
# uart_rx（W21 对面的 T20，板载 CH340E 的 TXD → FPGA）在 2026-10-10 加入：
# 它是 UART→SPI 桥（rtl/uart_spi_bridge.v）的输入，内部经 rtl/uart_rx.v 的
# 两级同步器 + 起始位中点复采，属于典型异步输入，故并入下面这条 false_path。
# ★ 历史提醒：此前 uart_rx 端口在设计中不存在，本文件原注释说明"综合会报
#   WARNING: [Vivado 12-584] No ports matched 'uart_rx'"——该注释已随本次
#   加端口一并废止，现在 uart_rx 是真实端口，不能再从这条 false_path 里拿掉。
set_false_path -from [get_ports {spi_sck spi_ss_n spi_mosi uart_rx}]

# -----------------------------------------------------------------------------
# 7. 调试端口（可选）
# -----------------------------------------------------------------------------
# 板上只有两路用户 LED（led[0]=AB21、led[1]=AB22，均在 Bank14），
# 本设计用 led[0] 指示 OTR 溢出、led[1] 指示幅值告警。
# led[2] / led[3] 本板无对应 LED；为消除 UCIO-1（未约束端口会拦截 bitstream），
# 把它们引到 J5 上空闲的两根针，需要用示波器看状态时可直接探这两根针。
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J21  IOSTANDARD LVCMOS33} [get_ports {led[2]}] ;# J5-18
set_property -dict {PACKAGE_PIN K21  IOSTANDARD LVCMOS33} [get_ports {led[3]}] ;# J5-19

# -----------------------------------------------------------------------------
# 8. 调试串口与中断输出
#    uart_tx -> 板载 USB 串口（CH340E）的 FPGA 侧发送脚，可直接用板载 USB 口；
#    uart_rx -> 同一个 CH340E 的 FPGA 侧接收脚（T20），UART→SPI 桥用它收命令；
#    irq_n   -> J5-20（Bank15，低有效，驱动外部 MCU 中断）
#    注：docs/04 曾把板载串口写成 FT2232（那是 JTAG 那一路芯片），
#        串口这一路按 docs/ATK_board_digest.md:61 是 CH340E，故 uart_rx=T20。
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVCMOS33} [get_ports irq_n]    ;# J5-20

# =============================================================================
# 9. ★ 输出侧约束（2026-10-10 补齐 —— 此前只有 ad_clk/ad_clk2 有输出约束）
# -----------------------------------------------------------------------------
# 如实记录的问题：本设计 15 个输出里，此前只有 ad_clk/ad_clk2 有 set_output_delay
# （第 3 节），其余 **13 个** —— a/b/z/u/v/w_out、spi_miso、led[3:0]、
# uart_tx、irq_n —— 既没有 set_output_delay、也没有 DRIVE/SLEW（全仓 set_drive/
# set_slew 命中 0 处）。这属于"未做的事"，不是"已验证无害"。
#
# 【外部时序假设 —— 这里的 set_output_delay 是"预算"，不是某个器件手册的 tSU/tH】
#   本设计与外部器件之间**没有源同步随路时钟**：ABZ/UVW 的边沿本身就是信息；
#   SPI 的 SCK 是**输入**给本设计的，已在第 6 节声明 false_path、
#   由模块内部两级同步器/边沿检测处理。因此把"输出必须在发射沿后多久稳定"
#   写成一条可签核的预算。
#
#   ★ Vivado 对输出端口的语义（务必按这个算，别把 -max 当成"允许的延迟"）：
#       required_time = 下一个发射沿(20ns) − set_output_delay − uncertainty
#     即 **-max 越大、留给 FPGA 内部的时间越少**。所以：
#       -max 6.000 ⇒ 输出必须在发射沿后 20−6−0.035 ≈ 13.965 ns 内稳定
#       -min 0.500 ⇒ 输出在发射沿后至少要稳定 0.5 ns（对端保持口径）
#
#   【为什么是 6.000/0.500，而不是更漂亮的 12.000/1.000（如实记录迭代过程）】
#     第一版取 -max 12.000 / -min 1.000，重跑实现得到
#       WNS −3.736 ns、14 个 failing endpoints（全部在 sys_clk→sys_clk 组，报告
#       存档 _synth_work/impl_timing_p02_max12_FAIL.rpt）、WHS 仅 +0.044 ns。
#     最差路径 `u_amp/amp_low_reg/C -> led[1]`：数据路径 7.078 ns
#     （FDRE 0.379 + net 0.745 + LUT2 0.105 + net 1.798 + **Bank14 的 OBUF 4.051**），
#     加上输入时钟路径（IBUF 1.431 + BUFG 0.081 + net 1.422 + …= 4.623）后，
#     端口数据实际在发射沿后 **11.701 ns** 才稳定 ⇒ 12.000 的预算在数学上不可满足。
#     据此把预算改成"输出必须在发射沿后 ~14 ns 内稳定"（-max 6.000），
#     实测最差 11.701 ns ⇒ 余量 ≈ +2.26 ns；-min 从 1.000 收到 0.500，
#     因为输出与采样沿同源、内部 Th+偏移本身就在 0.5 ns 量级（旧值只剩 +0.044 ns，
#     跨轮次不稳定），而真正的保证价值在 -max 那一侧。
#   【第二轮迭代：按"输出类别"分开给预算，而不是一个数字拍平】
#     -max 6.000 对全部 14 个端口重跑后**全约束满足、0 failing**，但全局最差路径变成了
#     状态灯：`u_capture/otr_reg/C -> led[0]`（数据路径 9.092 ns，其中 OBUF+布线 4.667 ns，
#     因为 LED 引脚离 OTR 寄存器很远）⇒ WNS 只剩 **+0.097 ns**，看着就脆。
#     状态灯/2 Mbaud UART/中断脚**不是位置信息**，它们的取样时刻由对端决定、
#     并不需要 14 ns 的稳定性；而 ABZ/UVW 的边沿本身是位置信息，必须继续按 14 ns 签核。
#     ⇒ 拆成两类：位置类 `-max 6.000`（14 ns 内稳定），指示类 `-max 3.000`
#     （17 ns 内稳定，给状态灯那条长布线留出余量）。
#   ★ 上板用示波器/逻辑分析仪实测后可按实测收紧这两个数，并**重跑实现**再签核。
#   ★ 未约束输出不会报错、只会被工具忽略 —— 这就是它此前一直没被发现的原因。
#
# 位置类（ABZ/UVW 六路 + SPI MISO）：边沿即信息，按 14 ns 签核
set_output_delay -clock sys_clk -max 6.000 [get_ports {a_out b_out z_out u_out v_out w_out}]
set_output_delay -clock sys_clk -min 0.500 [get_ports {a_out b_out z_out u_out v_out w_out}]
set_output_delay -clock sys_clk -max 6.000 [get_ports {spi_miso}]
set_output_delay -clock sys_clk -min 0.500 [get_ports {spi_miso}]
# 指示类（状态灯 / UART / 中断）：对端自行取样，17 ns 内稳定即可
set_output_delay -clock sys_clk -max 3.000 [get_ports {led[*]}]
set_output_delay -clock sys_clk -min 0.500 [get_ports {led[*]}]
set_output_delay -clock sys_clk -max 3.000 [get_ports {uart_tx irq_n}]
set_output_delay -clock sys_clk -min 0.500 [get_ports {uart_tx irq_n}]

# 【驱动强度 / 压摆率】分三类，判据是"边沿时间本身是不是信息"：
#  · a/b/z/u/v/w_out + spi_miso：边沿时刻（ABZ 的位置信息、SPI 的
#    位沿）直接决定正确性，**ABZ 的边沿抖动就是位置误差** ⇒ 保持 SLEW FAST，
#    只把驱动从默认 12 mA 降到 8 mA（降低 di/dt 与 ≤30 cm 排线上的振铃，
#    不牺牲边沿时间）。
#    ★ 振铃的真正解法仍是**源端串阻 22~33 Ω**（docs/04:286、docs/06:20，硬件侧
#      动作）；把边沿故意放缓只是把振铃换成抖动，对位置精度更糟。
#  · led[3:0] / uart_tx / irq_n：纯电平或慢速（led 事件级、uart_tx 2 Mbaud 位宽
#    500 ns、irq_n 中断线）⇒ DRIVE 4 + SLEW SLOW，降噪声与功耗。
#  · ad_clk/ad_clk2 与 ADC 数据 ODDR **故意不动**：它们的边沿相位关系是
#    docs/05 里 ADC 捕获余量分析的输入；单独改其中一路的 DRIVE/SLEW 会改变
#    ad_clk 与数据 ODDR 的相对相位，必须配合实测重做那份分析（见第 3 节）。
set_property SLEW FAST [get_ports {a_out b_out z_out u_out v_out w_out spi_miso}]
set_property DRIVE 8   [get_ports {a_out b_out z_out u_out v_out w_out spi_miso}]
set_property SLEW SLOW [get_ports {led[*] uart_tx irq_n}]
set_property DRIVE 4   [get_ports {led[*] uart_tx irq_n}]

# =============================================================================
# 附：Vivado 使用建议
# -----------------------------------------------------------------------------
# 1) ILA 采样时钟必须与观测信号同频：
#      观测 ch1_d/ch2_d  -> ILA 时钟用 clk_cap (50MHz)
#      观测 angle/a_out  -> ILA 时钟用 clk_sys (100MHz)
# 2) 下载前把 Hardware Manager 的 JTAG 频率降到 <= 10 MHz，
#    否则 ILA 采样时钟较高时会出现"烧完就死"。
# 3) 先用 50MHz 单频方案（clk_sys = clk_cap）把功能跑通，
#    确认无误后再拆成 50/100MHz 双频，降低第一周的调试风险。
# 4) 综合前先跑 implementation 看 WNS/WHS，并把数字记进报告
#    （答辩时"时序收敛吗？WNS 多少？"是高频问题）。
# =============================================================================
