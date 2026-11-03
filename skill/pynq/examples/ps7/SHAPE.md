# ps7 —— 设计里有 processing_system7 的形状

**真实来源**：这份 .hwh 的 `axi_gpio` / `axi_bram_ctrl` / `blk_mem_gen` 三个 MODULE、
两段 MEMRANGE、`SYSTEMINFO` 全部来自本仓库的真实导出（`examples/addr_map/design_1.hwh`，
由 Vivado 2026.1 在 xc7a35tfgg484-2 上 `generate_target {hw_handoff}` 得到）。

**手改部分**：`processing_system7` 这个 MODULE（含它自己的两段 MEMRANGE 0xE0000000/16 B、
0xE0001000/4 K）是**手工补的**——本机 Vivado 是 BASIC license 且没装 Zynq 器件族
（`create_project -part xc7z020clg400-1` 报 `Specified part could not be found`），
建不出真的 PS7 导出。属性名与取值口径照抄 Vivado 自己的 PS7 导出模板
`data/PS/7series/data/zynqconfig/code/sdkgen.xml`。

**它证明什么**：解析器遇到"PS 自己带地址"的常见形态时，不会把 PS7 误报成
"没分配地址的外设"（`ADDR-001` 对 `ps7*` 豁免），也不会把 PS 的 16 字节
寄存器窗口当成页对齐错误。

**它不证明什么**：不能证明 PYNQ 真机能加载这个设计。上板路径仍然是未实测。
