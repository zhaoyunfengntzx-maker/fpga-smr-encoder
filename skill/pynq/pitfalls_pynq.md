# PYNQ 踩坑清单（14 条）

这份清单只讲 **PYNQ 侧**（.hwh / Overlay / DMA / PS-PL 边界）的坑，不重复
`../pitfalls.md` 里 RTL 与仿真那一组。两条清单配合用：RTL 的坑在仿真就能挡住，
这里的坑大多要到"第一次上板"或"换了板卡"才现形。

**证据等级**（照等级取用，别把预期当事实）：
- `[实测]`：在本仓库里用工具跑出来的结论（工具本身与本机 Vivado 都是真的）。
- `[文档]`：来自 AMD/PYNQ 官方文档或 IP 手册的确定性事实。
- `[待验]`：**从工具与文档推出的预期失败**，第一次上板时请按"排查"列逐条核对。

每条格式：触发 → 现象 → 排查 → 根因 → 修法 → 回归验证 → 失效 → 证据。

---

## A 组：地址与 .hwh

### PYNQ-01 交付目录里没有 .hwh

- **触发**：只拷了 `design_1.bit`（或 `app.bit`）到板子上。
- **现象**：`Overlay('design_1.bit')` 不报错，`ol.ip_dict` 里只有 PYNQ 自带的入口，
  你的 IP 一个都不在；于是有人在 Python 里写死 `mmio.write(0x41200000, ...)` 绕过去。
- **排查**：`python skill/pynq/pynq_bundle.py <交付目录>`（判据 BUNDLE-001 / BUNDLE-003）。
- **根因**：PYNQ 按**同名**找 `.hwh`（`app.bit` ↔ `app.hwh`），没有它就没有地址表。
- **修法**：Vivado 里 `generate_target {hw_handoff}` 后把 `.hwh` 与位流一起拷，文件名保持一致。
- **回归**：`pynq_bundle.py <目录>` 输出 `PASS（位流与地址表配对）`。
- **失效**：手写绝对地址、且只用一块固定板卡的场合，这条约束对你没有意义——但那已经
  不是"可复用 overlay"了。
- **证据**：`[实测]` 判据在 `examples/bundle_nohwh` 上返回 EXIT 1。

### PYNQ-02 位流换了、.hwh 忘了换

- **触发**：改完 RTL 重新实现，只把新 `.bit` 拷过去。
- **现象**：寄存器读出来是"看起来合理的数字"，但地址错位——比如状态位读到了计数寄存器
  的低位，于是你以为是逻辑 bug，实际是地址表旧了。
- **排查**：`python skill/pynq/pynq_bundle.py <目录>`（BUNDLE-004 比时间戳）；
  `python skill/pynq/pynq_hwh.py 新.hwh --diff 旧.hwh`（ADDR 变化）。
- **根因**：地址分配是综合/实现时的产物，不是 RTL 常量。
- **修法**：把 `.hwh` 与 `.bit` 当成**一对**产物，用脚本一起拷；交付时跑一次 `--diff`。
- **回归**：`--diff` 输出 `地址变化 …: 0x… → 0x…`；没有变化时它明确说"两版一致"。
- **失效**：静态地址（自己写死 `C_S_AXI_BASEADDR`）的设计不会变，这条自然不触发。
- **证据**：`[实测]` 两个夹具间的 `--diff` 输出。

### PYNQ-03 地址没解对，读回全 0

- **触发**：自写 AXI-Lite 从口，`AWREADY/WREADY` 常 1、`BVALID` 不回，或地址比较漏了高位。
- **现象**：`ol.read(0x00)` 一直是 `0`，写进去也读不回来；有人因此认为"寄存器没生效"，
  转头去查 PL 逻辑。
- **排查**：`python skill/pynq/pynq_overlay.py --overlay app.bit --map app.hwh --dev myip`，
  看 5 条判据里"Walking-ones 读回"是否失败；失败时工具会附一句
  "先怀疑地址没解对或 DMA 没启动"。
- **根因**：AXI-Lite 握手不合规时读通道返回的是默认 0（或被 interconnect 吞掉）。
- **修法**：按 AXI4-Lite 从口模板补 `AWREADY`/`WREADY`/`BVALID`/`ARVALID`/`RVALID` 的
  依赖关系；最少写一个只读 ID 寄存器（`0xDEADBEEF`）。**先让"能读回一个常量"这件事成立。**
- **回归**：`pynq_overlay.py --mock` 的 mock 有 `decoded=False` 模式专门复现这条；
  上板时用同一套 5 条判据。
- **失效**：用 `pynq.Overlay` 自带驱动的成熟 IP（如 AXI GPIO）不触发。
- **证据**：`[实测]`（mock 层）+ `[待验]`（真板卡）。

### PYNQ-04 .hwh 里没有寄存器偏移

- **触发**：想从 `.hwh` 直接读出"ctrl 在 0x00、status 在 0x04"。
- **现象**：`REG-001` 提示"hwh 不含寄存器列表"；硬猜偏移的结果是写到了别的寄存器。
- **排查**：`python skill/pynq/pynq_hwh.py x.hwh` 会直接给这条 NOTE。
- **根因**：Vivado 的 handoff 只导出**地址段**，寄存器表在 IP 的驱动/doc 里。
- **修法**：偏移以 IP 文档或 `pynq` 驱动为准；自己写的 IP 就在 README 里列表，别指望 hwh。
- **回归**：`pynq_hwh.py --md` 产出的地址表里只有基址与长度，偏移一栏写"查 IP 文档"。
- **失效**：用了带 PYNQ 驱动的 IP（`pynq.lib`），偏移由驱动提供。
- **证据**：`[实测]`（真实导出的 hwh 里确实没有 `REGISTERS` 节点）。

---

## B 组：DMA 与数据通路

### PYNQ-05 忘了 flush/invalidate，数据是旧的

- **触发**：`buffer = allocate(...)`，CPU 写完直接 `dma.sendchannel.transfer(buffer)`；
  或 `transfer` 后立刻读 `buffer` 而不 `invalidate()`。
- **现象**：第一次跑对，第二次跑错；或者 PL 侧收到的总是上一轮的数。
- **排查**：在同一轮里加一条"回环判据"——把 PL 收到的东西原样送回，主机侧逐点比对。
- **根因**：PS 侧 cacheable 缓冲与 PL 的 DMA 不共享 cache。
- **修法**：发送前 `buffer.flush()`，接收后 `buffer.invalidate()`；或明确用非 cacheable 的
  分配方式。**别用"多试几次就对了"掩盖它。**
- **回归**：`pynq_overlay.py` 的 DMA 判据同时比对"长度"和"每个点"，错位与陈旧都会红。
- **失效**：用 `pynq.allocate` 且在 `transfer` 前后按官方样例 flush/invalidate 的代码不触发。
- **证据**：`[文档]`（PYNQ DMA 样例的固定写法）+ `[待验]`。

### PYNQ-06 DMA 长度单位弄错（字节 vs 字数）

- **触发**：`transfer(buffer)` 的 `buffer` 是 `numpy` 数组，但寄存器里写的长度是"点数"，
  PL 侧换算成字节时少乘 4。
- **现象**：只搬了 1/4 的数据，`wait()` 正常返回，判据"长度一致"却失败。
- **排查**：工具会报 `DMA 收 256 期望 1024`（数量级差 4 就是这条）。
- **根因**：AXI-Stream 的 `TLAST` 之前有多少拍，与主机侧数组字节数不是一回事。
- **修法**：把"点数/字节数"写成一个常量并在两端引用同一处；工具里用 `count` 只表达点数。
- **回归**：`pynq_overlay.py --mock --count 256` 的 5 条判据全过。
- **失效**：只搬定长且两端都写死同一数字的场合，仍建议加一条长度判据。
- **证据**：`[实测]`（mock 上故意丢一个数会红）。

### PYNQ-07 用墙上时间算吞吐

- **触发**：`t0 = time.time()` … `t1` 相减，除以字节数当带宽。
- **现象**：同一设计两次测出来差 30%，评审一问就说不清。
- **排查**：看代码里有没有 `time.time()`/`perf_counter()` 参与任何**结论**。
- **根因**：主机侧调度、Jupyter kernel、DMA 中断延迟都不受你控制。
- **修法**：PL 里放一个周期计数器（`REG_CYCLES`），用"周期数 + 时钟频率"算；
  工具里的 `throughput_mbps` 就是这么来的，且 `clk_mhz` 必须与 `.hwh` 的 `FREQ_HZ` 一致。
- **回归**：`pynq_overlay.py --mock` 输出的吞吐来自周期数，mock 的"墙钟 0.4 ms"只用于提示。
- **失效**：没有周期计数器、且只做量级判断（差 10 倍以上）时，墙钟勉强可用——但要写明。
- **证据**：`[实测]`（软件里的墙钟不参与判据）。

### PYNQ-08 一进多出/多周期延迟，按"第 i 个进 = 第 i 个出"比对

- **触发**：PR（流水线）设计里输出延迟随配置变化。
- **现象**：判据在配置 A 上过、配置 B 上全红，而 RTL 是对的（只是延迟不同）。
- **排查**：看测试里有没有"事务号"或"期望缓冲"的配对逻辑。
- **根因**：延迟不确定的接口不能用位置配对。
- **修法**：让 PL 在输出里带序号（或带输入样本），主机侧按序号对齐；
  或固定延迟并在 RTL 里用参数声明，测试按该参数等待。
- **回归**：`skill/templates/tb_skeleton.v` 的"一拍进一拍出"假设失效条件里已写明这条，
  换成按序号配对即可。
- **失效**：严格 1:1、延迟固定的组合逻辑通路。
- **证据**：`[文档]` + 本工程记录 58/59（流水让判据读到上一帧）。

---

## C 组：板卡与运行时

### PYNQ-09 同一块板子上重复下载位流

- **触发**：Jupyter 里反复 `Overlay(...)`，或上一个 kernel 还持有 overlay。
- **现象**：`RuntimeError: Failed to load bitstream` / `Device or resource busy`；
  或者"看起来下载成功了但行为是旧逻辑"。
- **排查**：`cat /sys/class/fpga_manager/fpga0/state`（应为 `operating`）；
  换一个干净的 notebook / 重启 kernel 再试。
- **根因**：旧的 overlay 对象仍持有 bitstream，或 fpga manager 状态没收干净。
- **修法**：一个进程只下一次位流；需要重下时先 `del ol` 并 `gc.collect()`，仍不行就重启 kernel。
- **回归**：重新下载后先跑 `pynq_overlay.py` 的 Walking-ones 判据，再谈功能。
- **失效**：用 `pynq.Overlay(..., download=False)` 且确认板上已是目标位流时不触发。
- **证据**：`[文档]`。

### PYNQ-10 时钟频率对不上（hwh 的 FREQ_HZ 是"声明"不是"实测"）

- **触发**：PL 时钟由 PS 的 `FCLK_CLK0` 提供，但 BD 里没改 `FREQ_HZ`（默认 100 MHz），
  实际被 PYNQ/驱动设成别的值；或自定义时钟源没写进 hwh。
- **现象**：周期计数换算出的吞吐、转速、延时全都成比例地错。
- **排查**：`python skill/pynq/pynq_hwh.py x.hwh` 看时钟域表（`CLK-001` 多频域、`CLK-002` 无 FREQ_HZ）。
- **根因**：hwh 里的频率是设计时的参数，板级配置可以改。
- **修法**：把实际频率写进 Python 侧常量并与 hwh 交叉核对；工具 `--clk-mhz` 允许覆盖，
  但覆盖时要打印"用的是你给的频率，不是 hwh 的"。
- **回归**：`pynq_overlay.py --mock --clk-mhz 50` 的吞吐随之减半（可算得出）。
- **失效**：结论只涉及"对不对"不涉及"多快"的场合。
- **证据**：`[实测]`（hwh 解析）+ `[待验]`（板上真值）。

### PYNQ-11 换了板卡，旧 overlay 直接搬

- **触发**：从 PYNQ-Z1/Z2 换到 KV260、或从 Zynq-7000 换到 Zynq MPSoC。
- **现象**：`Overlay` 报 device family 不匹配；或能下载但 PS 端外设全变（`UART`/`GPIO` 编号不同）。
- **排查**：`ol.device`、`ol.ip_dict` 与你预期的 IP 列表对比；`.hwh` 里 `SYSTEMINFO/ARCH`
  会写出 `zynq` / `zynqmp`。
- **根因**：overlay 是"位流 + 地址表 + 板级元信息"的组合，跨器件族不通用。
- **修法**：换板就重新导出，不能用旧 hwh；PS 端外设走 `pynq.ps`/`pynq.lib`，不要写死 `/dev/`。
- **回归**：`pynq_hwh.py x.hwh` 第一行会打印 `device=… arch=…`。
- **失效**：只把 PL 当"加速器 + 一小段 AXI-Lite"的极小 overlay，迁移成本最低但仍需重导。
- **证据**：`[文档]`。

### PYNQ-12 只测了"能下载"，没测"能算对"

- **触发**：第一版 overlay 下载成功、LED 亮了，就宣布打通。
- **现象**：功能 bug 留到联调；更糟的是"读回全 0"被当成"还没配好"。
- **排查**：拿 `pynq_overlay.py` 的 5 条判据过一遍（寄存器、CTRL/STATUS、DMA 长度、逐点比对、计数一致）。
- **根因**：把"基础设施可用"当成"功能正确"。
- **修法**：把 5 条判据写成脚本，每次上板先跑；红了先修基础设施，别看功能。
- **回归**：`pynq_overlay.py --mock` 是同一套判据的离线版（mock 里 3 条负对照）。
- **失效**：纯 PS 侧软件项目，不涉及 PL。
- **证据**：`[实测]`（工具与负对照）+ 本工程记录 47（三条"看起来 PASS 其实没测到"）。

### PYNQ-13 PS 与 PL 各自持有一份"版本"

- **触发**：位流更新了，但板上的 `.hwh`/Python 脚本还是旧的；或反过来。
- **现象**：地址对得上、判据也过，但你测的不是你以为的那版逻辑。
- **排查**：`pynq_bundle.py` 打印每个文件的 sha256 前 16 位——把它写进实验记录。
- **根因**：位流、地址表、Python 驱动三者是三个文件，谁都可以单独更新。
- **修法**：交付/实验记录里同时记 `bit` 与 `hwh` 的 sha256；`--diff` 用于回归。
- **回归**：`check_manifest.py`（通用）+ `pynq_bundle.py`（配对）两道。
- **失效**：单文件交付且只跑一次的临时实验。
- **证据**：`[实测]`；同类坑见 `../pitfalls.md` P-10、P-14。

### PYNQ-14 在 Jupyter 里改了 `.py` 不生效

- **触发**：把驱动写在 `myip.py` 里，import 后改了文件再跑，行为没变。
- **现象**：调了半天发现跑的是旧模块（`.pyc` 缓存或 kernel 里的旧对象）。
- **排查**：`import myip; print(myip.__file__)`；必要时 `%reload_ext autoreload`。
- **根因**：kernel 常驻，`import` 只执行一次。
- **修法**：脚本式开发（`python app.py`）而不是 notebook 里改文件；
  或在 notebook 顶部开 `%autoreload 2`。
- **回归**：跑一次 `pynq_overlay.py --mock`（它每次都重新 import）验证代码路径。
- **失效**：纯 notebook 内联函数、不跨文件 import 的场合。
- **证据**：`[文档]` + 本工程记录 33（"版本开关靠猜"的同类问题）。

---

## 这份清单整体的失效条件

- 绑定 **PYNQ 3.x + Vivado 2026.1 导出的 .hwh 结构**；PYNQ 2.x 或 Vitis 的 `.xsa` 流程，
  A 组判据要换（`pynq_bundle.py` 的 BUNDLE-006 只是提示"有 .xsa"）。
- 绑定 **Zynq-7000 / Zynq MPSoC 的 PS-PL 模型**；纯 PL 的 Artix 板卡没有 Overlay 概念，
  B 组的 DMA/cache 条目改成"PCIe/以太网搬运"后思想仍成立。
- 14 条里没有一条是"本队上板实测"：A 组来自工具与真实 hwh，B/C 组来自文档与推理。
  第一次上板时请把"排查"列当检查表用，并把结果补回本文件——那才是它的完整形态。
