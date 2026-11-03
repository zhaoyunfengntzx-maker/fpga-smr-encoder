# clk_multi —— 两个频率的形状

**真实来源**：与 `../addr_map` 同一份真实导出。

**手改部分**：`bram_ctrl.S_AXI` 的 `FREQ_HZ` 从 100 MHz 改成 150 MHz，只改这一个值。

**它证明什么**：`CLK-001` 能在 hwh 层面发现"设计里有多个频率"，提示 host 侧
`ps.Clocks` 的 FCLK 必须与实际一致——按周期换算的吞吐/延时全错就错在这里。

**用法**：`python skill/pynq/pynq_hwh.py skill/pynq/examples/clk_multi/design_1.hwh`
默认 EXIT 1（WARN 也算失败）；如果你只想让地址类问题拦住流程，加 `--lenient` 得 EXIT 0。
