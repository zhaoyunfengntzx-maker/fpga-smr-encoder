# 夹具说明

- `real_bd/design_1.hwh`：Vivado 2026.1 从 Artix-7 的 IP integrator 设计**真实导出**的
  handoff 文件（本机 Vivado 未装 Zynq 器件族，所以设计里没有 PS7；标签结构、
  PARAMETERS/BUSINTERFACES 与 PYNQ 读的 .hwh 同源）。
- `addr_map/design_1.hwh`：在上面那份真实文件里补了 `<MEMRANGES>`，属性名取自 Vivado
  自己的 PS7 导出模板 `data/PS/7series/data/zynqconfig/code/sdkgen.xml`
  （BASEVALUE/HIGHVALUE/MEMTYPE/SIZE）。用途是让地址类判据有输入。
- `addr_bad/design_1.hwh`：同上去掉一处地址重叠的修正（bram_ctrl 落在 gpio_regs 里），
  用来验证判据真的会红。
- `bundle/`、`bundle_nohwh/`：`design_1.bit` / `app.bit` 是 4 KB 占位文件，**不是可用位流**，
  只用于演示"位流与地址表配对/时间戳"这两条判据。
- 所有 `.hwh` 里都没有寄存器偏移：Vivado 默认不把寄存器表写进 handoff，
  这也是 `pynq_hwh.py` 会提示"寄存器偏移要查 IP 文档"的原因。
