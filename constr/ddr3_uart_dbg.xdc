#=============================================================================
# ddr3_uart_dbg.xdc —— 仅 bring-up 顶层 ddr3_top_mem 使用的串口调试脚
#   uart_tx → 板载 CH340E（USB 串口）的 FPGA 发送脚，115200 8N1
#   与 constr/enc_top.xdc 中 uart_tx 的引脚一致
#=============================================================================
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVCMOS33} [get_ports uart_tx]
