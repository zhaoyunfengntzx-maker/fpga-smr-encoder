# 仿真测试台使用说明（Vivado xsim）

> **为什么要做仿真**：参赛报告里"专业性"这一项，很大一部分来自"你怎么证明它是对的"。
> 三层验证体系（黄金模型 → RTL 仿真 → 实物实测）中，**RTL 仿真是唯一能在没有硬件时证明 RTL 正确的手段**，
> 而且答辩时"你仿真过吗？覆盖率多少？"是高频问题。
>
> **注意**：本工程开发机上原本没有安装任何仿真器，因此这些 testbench 曾经**从未运行过**。
> **现在已经在真实 Vivado 2026.1 xsim 下全部跑通**：
> **21 个测试台全部 `TEST PASSED`、编译零 ERROR**（最近一次干净串行复跑 `sim/logs/SUMMARY.md`
> **2026-10-12 23:52:26 = 21/21**；`tools/lint_all.ps1` 逐文件 `xvlog` **ERROR 0 / WARNING 0**），
> 其中顶层集成台 `tb_enc_top` **81 checks**，含 `[TEST D2]` OTR 软清位端到端用例 9 条；
> 新增台 `tb_uart_spi_bridge` **44 checks**（遥测/应答 TX 仲裁）；
> **`tb_uart_scope` 96 checks**（v12 遥测帧布局 v2：偏移 8/9/10/11 = `io_state`/`0xA2`/`io_flags`/`0x00`，
> 见 `../docs/DEV_STATUS.md` §1.58），综合 0 errors，
> 实现 **（2026-10-12 v12：已收敛）`All user specified timing constraints are met.`**（生产版 `_synth_work/impl_timing.rpt` @2026-10-12 23:59:16：`sys_clk` WNS = **+0.959 ns** / TNS = 0.000 / **0 个失败端点** / 11275 端点；WHS +0.075 / WPWS 9.500；ILA 版 @2026-10-13 07:11:57 同判据行，WNS +0.332 / 0 失败 / 20165 端点），
> **bitstream 已生成**（**（2026-10-12 v12）`_synth_work/enc_top.bit`，1,042,208 B @2026-10-12 23:59:27**，SHA256 `D93DEBF92034FF2329117CDE59EB83E0D95620306E7A944C6B0402E8C3AE7725`；**ILA 版** `_synth_work/enc_top_ila.bit` **1,428,064 B @2026-10-13 07:12:11**，SHA256 `5CC779EE6D00FFA60AD371F9A87F82A35E74C8B6E477F45323B475A299BAEC52`；**v11 历史（已归档 `_synth_work/enc_top_v11prod.bit` / `_synth_work/enc_top_ila_v11.bit`）**：生产 1,086,600 B @21:15:37、ILA 1,458,744 B @21:29:54）。
> **以下是 2026-10-10 v9 历史口径**：实现 `Timing constraints are not met.`（`sys_clk` WNS = **−3.352 ns** / TNS = −85.116 / **26 个失败端点
> 全是 ADC 输入端口**（根因 = 生成时钟 `-invert` 相位不匹配 + 当时的 `set_input_delay`，见 `docs/05` §12.4）/ 10582 端点；
> WHS = +0.033 ns），**50/50 引脚约束** + 布线后 DRC 零 error / 零 critical warning +
> 历史 bitstream（`_synth_work/enc_top.bit`，**804,780 B** @ 2026-10-10 16:05:29，`COMPRESS=TRUE`；未压缩 17,537,696 bit、`saved 11099520 bits` ⇒ 压缩后 6,438,176 bit）。
> **ILA 调试版（2026-10-13 v12 已重建，时序同判据全绿）**：`_synth_work/enc_top_ila.bit` **1,428,064 B** @2026-10-13 07:12:11（SHA256 `5CC779EE6D00FFA60AD371F9A87F82A35E74C8B6E477F45323B475A299BAEC52`）+ `enc_top_ila.ltx` **71,337 B** @07:12:00（36 条命名探针 / 269 bit）；**v11 历史为 1,458,744 B @2026-10-12 21:29:54（已归档 `_synth_work/enc_top_ila_v11.bit`）**；**历史（2026-10-10 16:12:01）**为 `enc_top_ila.bit` **1,445,812 B** + `enc_top_ila.ltx` **67,006 B** @16:11:50（含 UART→SPI 桥 + 探针位序修复 + `0x0405[0]` OTR 软清位），
> 那时 `Timing constraints are not met.`：`sys_clk` WNS **−3.329 ns / TNS −84.745 / 26 个失败端点（全是 ADC 输入端口）/ 18010 端点**（整体 19161 端点）、DRC 62 checks 全 `Related violations: <none>`（0 error / 0 critical，签核以生产版为准）。
> 完整结果、修复的缺陷与已知缺口见 **`docs/05_vivado_sim_impl_report.md`**；
> 各测试台的原始日志在 `sim/logs/*.log`。
>
> 一键回归：`powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_sim.ps1`
> （单模块 TB 只需编译被测模块 + 自己；`tb_enc_top` 必须编译全部 `rtl/*.v`
> 与 `sim/xilinx_prims_stub.v`，详见第 2 节。）

---

## 1. 在 Vivado 里跑单个模块的仿真

1. Vivado → **Add Sources → Add or create simulation sources** → 选中要测的 `sim/tb_xxx.v`
2. 同时确保对应的 `rtl/xxx.v` 已在 design sources 里
3. 左侧 Flow Navigator → **SIMULATION → Run Simulation → Run Behavioral Simulation**
4. 在 Tcl Console 里执行：
   ```tcl
   run all
   ```
5. 看 Console 输出的最后一行：
   - `TEST PASSED` → 通过
   - `TEST FAILED` → 失败，上面会有具体是哪一条检查没过

> `tb_*.v` 全部是**自检测试台**：不依赖人工看波形，直接打印 PASS/FAIL。
> 这是刻意的设计——为了让"跑没跑过"这件事没有歧义。

## 2. 在命令行里批量跑（推荐，便于回归）

在 Vivado 的 Tcl Console 或者 `xvlog/xelab/xsim` 环境里：

```tcl
# 以 tb_cordic_atan2 为例
xvlog -sv rtl/cordic_atan2.v sim/tb_cordic_atan2.v
xelab -debug typical tb_cordic_atan2 -s tb_cordic_sim
xsim tb_cordic_sim -runall
```

> **注意（实测总结）**：单个模块的测试台可以用上面两条命令只编译它自己 + 被测模块，
> 但**顶层集成测试台 `tb_enc_top` 必须编译全部 `rtl/*.v`**，否则 xelab 会报
> `[VRFC 10-2063] Module <cdc_sync2|ad9238_capture|...> not found`。
> **`tb_enc_top` 还必须额外编译 `sim/xilinx_prims_stub.v`**：`rtl/enc_top.v:94` 例化了
> `BUFG`、`rtl/enc_top.v:119` 例化了 `ODDR`，而本机没有预编译的 unisims 仿真库
> （Vivado 2026.1 未随装 `compile_simlib` Tcl 脚本），所以用该文件提供行为等价的
> 仿真桩。它只定义 `BUFG`/`ODDR`，不与其他模块重名；**综合时 Vivado 解析真实的
> unisims 原语，与本桩无关**（该文件在 `sim/` 下，不进综合源集）。

批量回归脚本（PowerShell，需要 Vivado 环境变量已设置）。

> ★ 下面这段只是**早期 12 台**的简写示例；**完整清单（现在 19 台）以 `tools/run_sim.ps1` 为准**，
> 直接跑 `powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_sim.ps1` 即可，
> 它会依次跑完全部测试台并把结果写进 `sim/logs/SUMMARY.md`（单台调试用 `-Only <tb>`，但**注意
> `-Only` 会把 `SUMMARY.md` 覆盖成单台汇总**，收尾要再跑一次全量恢复）。

```powershell
$pairs = @(
  @('rtl/ad9238_capture.v','sim/tb_ad9238_capture.v','tb_ad9238_capture'),
  @('rtl/decim_avg.v',      'sim/tb_decim_avg.v',      'tb_decim_avg'),
  @('rtl/sc_correct.v',     'sim/tb_sc_correct.v',     'tb_sc_correct'),
  @('rtl/amp_monitor.v',    'sim/tb_amp_monitor.v',    'tb_amp_monitor'),
  @('rtl/cordic_atan2.v',   'sim/tb_cordic_atan2.v',   'tb_cordic_atan2'),
  @('rtl/loop_filter.v',    'sim/tb_loop_filter.v',    'tb_loop_filter'),
  @('rtl/pole_counter.v',   'sim/tb_pole_counter.v',   'tb_pole_counter'),
  @('rtl/abz_gen.v',        'sim/tb_abz_gen.v',        'tb_abz_gen'),
  @('rtl/uvw_gen.v',        'sim/tb_uvw_gen.v',        'tb_uvw_gen'),
  @('rtl/biss_c_slave.v',   'sim/tb_biss_c_slave.v',   'tb_biss_c_slave'),
  @('rtl/spi_slave.v',      'sim/tb_spi_slave.v',      'tb_spi_slave'),
  @('rtl/reg_file.v',       'sim/tb_reg_file.v',       'tb_reg_file')
)
foreach ($p in $pairs) {
  Write-Host "=== $($p[2]) ===" -ForegroundColor Cyan
  xvlog $p[0] $p[1]
  xelab -debug typical $p[2] -s "$($p[2])_sim" | Out-Null
  xsim "$($p[2])_sim" -runall | Select-String -Pattern 'TEST (PASSED|FAILED)'
}
```

## 3. 测试台覆盖了什么（写报告时可以直接抄）

| 测试台 | 覆盖内容 |
|---|---|
| `tb_ad9238_capture.v` | 偏移二进制→补码转换、边界码（0x000/0x800/0xFFF）、OTR 锁存与清除、复位 |
| `tb_decim_avg.v` | 抽取正确性、算术右移的符号处理、饱和、valid 时序 |
| `tb_sc_correct.v` | 四类畸变（无畸变/偏置/幅值失衡/正交误差）下的校正效果；用径向误差与正交误差量化；含饱和路径 |
| `tb_amp_monitor.v` | 平方和、上下限比较、边界值 |
| `tb_cordic_atan2.v` | 全周角度扫描、四个象限边界、退化输入（x=0 或 y=0）；打印 max/RMS 误差 |
| `tb_loop_filter.v` | 匀速下零滞后、阶跃响应稳定性、ki=0&kp=0 时退化为直通、45° 滞后告警 |
| `tb_pole_counter.v` | 正/反向扫描、跨零辨向、Z 附近抖动序列**不得**产生误计数 |
| `tb_abz_gen.v` | 边沿数 = 4×inter、A/B 正交与 50% 占空、每周期恰好 1 个 Z、Z 宽度、后分频、限频、迟滞抗抖动 |
| `tb_uvw_gen.v` | 6 状态序列、等宽驻留、方向反转、相位偏移 |
| `tb_biss_c_slave.v` | **行为级 BiSS 主机模型**：产生 MA、按位采样 SLO、独立计算 CRC6，200+ 帧全通过 |
| `tb_spi_slave.v` | SPI 模式 0、地址+数据读写、32 位包 32bit 包 |
| `tb_reg_file.v` | 寄存器读写、`DEVICE_ID`=0x0C、配置位正确映射到扁平输出、`0x0405[0]` (W1C) OTR 软清位（TEST D2） |
| `tb_calib_min.v` | `rtl/calib_ctrl.v` **自包含最小自检**（激励全部内部算出，不依赖向量文件）：理想正交输入下 `ofs_s/ofs_c/phase_k` 应为 0、`gain_s == gain_c`；用来把"测试台有问题"与"RTL 有问题"分开（起因见 `tb_calib_ctrl.v` 的二维数组三维索引静默返回 0） |
| `tb_enc_top.v` | **顶层端到端**（编译全部 `rtl/*.v` + `sim/xilinx_prims_stub.v`）：262140 点扫一圈、角度线性残差、`pos_full` 阶梯、ABZ/Z/UVW 时序、SPI 读写、UART 帧、`0x0405` OTR 软清；**81 checks** |
| `tb_uart_scope.v` | 18 字节遥测帧结构、校验和、帧率分频；**v12 帧布局 v2**：偏移 8/9/10/11 = `io_state` / `0xA2` 布局标记 / `io_flags` / `0x00`（含"位序正确"与"旧布局 off9 = `amp_sq[23:16]` 恒 ≤ 0x80、不会与 `0xA2` 撞车"的定向检查） |
| `tb_uart_baud.v` | `uart_tx` 波特率分频与 `BAUD_DIV` 边界（4 组实例） |
| `tb_uart_period.v` | 遥测帧周期（`SAMPLE_DIV`）扫描（6 组实例） |
| `tb_uart_spi_bridge.v` | **UART→SPI 桥端到端**（真 `uart_scope`+`uart_spi_bridge`+`spi_slave`）：写命令生效、读命令两帧逻辑、坏首字节被丢、半包超时重同步、连发、±2% 波特率、`ext_busy` 互斥与 2 ms 放弃、遥测不丢帧；**44 checks** |
| `tb_xor_probe3.v` | UART 遥测帧 XOR 校验的**表达式语义**定向自检（用单调非零向量钉死三种写法的等价性，并固化"当初误判为仿真器 bug"的那次复盘） |

## 4. 常见仿真问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `xelab` 报找不到模块 | 少加了某个 `rtl/*.v` | 把被例化的模块和 testbench 一起编译 |
| 仿真一直跑不完 | testbench 里缺 `$finish` 或循环无出口 | 检查 `run all` 是否有超时；先 `run 100us` |
| 全是 X | 复位没释放 / 时钟没起振 | 看 testbench 的复位时序；确认 `rst_n` 有拉高 |
| `TEST FAILED` 但看不出哪一条 | 在 `$display` 里加上具体索引与期望/实际值 | 测试台里已经尽量打印了上下文 |
| 位宽/符号相关的诡异结果 | Verilog 的表达式位宽规则 | 所有中间信号显式声明 `signed`，乘法操作数用 `$signed()` 包起来 |

## 5. 与黄金模型对账（**最重要的一步**）

RTL 仿真通过之后，**必须**和 `model/golden_model.py` 对账：

1. 在 `golden_model.py` 里按 testbench 的激励条件生成一组输入（理想 sin/cos + 指定畸变）；
2. 把同一组输入喂进 RTL 仿真（可以用 `$readmemh` 从文件读激励）；
3. 比较两者的 16bit 角度输出：
   - **允许差异 ≤ 2 LSB**（CORDIC 的定点舍入差异）
   - 若差异 > 2 LSB，说明 RTL 与模型的定点语义不一致，**必须查清**（通常是移位方向、截断方式或位宽扩展的差别）
4. 把这张对照表和误差结论写进报告 —— 这是"模型与实现一致"的直接证据。

> 这一步做扎实了，答辩时"你怎么保证 RTL 和你论文里写的算法一致？"这个问题就变成了你的加分项。
