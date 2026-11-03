# clk_missing —— 从口没声明时钟的形状

**真实来源**：与 `../addr_map` 同一份真实导出。

**手改部分**：删掉 `bram_ctrl.S_AXI` 的 `CLK_DOMAIN` 与 `FREQ_HZ` 两个 PARAMETER。

**它证明什么**：`CLK-002` 会说"hwh 里没有 FREQ_HZ，无法核对时钟，只能靠
`ps.Clocks` 读回"——而不是默默按 100 MHz 假设算下去。真实工程里这常见于
手写 AXI 从设备或老版本导出。

**用法**：`pynq_hwh.py …/clk_missing/design_1.hwh --lenient` → EXIT 0 且仍打印这条警告。
