# 技能包 6：综合/实现报告与仿真日志的自动采集

## 1. 一句话 / 解决什么问题

**报告里的每一个数字都应该来自一次自动运行的输出，而不是从工具 GUI 里抄出来。**
本技能给出三个可直接搬走的脚本形态：① 仿真回归的自动判定与汇总；② 综合→实现→位流的一键流程
与报告落盘；③ **用现行实测数字刷新全仓文档**（解决"文档里的旧数字忘了改"这一类最丢分的缺陷）。

## 2. 适用范围

- 任何 Vivado（或 Quartus/其他）工程：你需要"资源占用 / 时钟频率 / WNS / 位流哈希"这类数字进报告。
- 任何有多个测试台的工程：你需要"21 个测试台分别 PASS/FAIL、耗时、日志路径"的一页汇总。
- 任何"同一个数字散落在 5 个文档里"的工程：你需要一次可审计的批量刷新。
- 不适用：只跑一次实验、不打算把数字写进任何文档的场合。

## 3. 使用方法

### 3.1 仿真回归：自动判定 + 自动汇总（`tools/run_sim.ps1` 形态）

要点（每一条都是踩出来的）：

1. **每个测试台在独立工作目录里编译+精化+仿真**（`_sim_work/<tb>/`），互不干扰，
   否则一个测试台的残留会让另一个报 `Could not open file ... for writing`。
2. **判定只认两个字符串**：`TEST PASSED` / `TEST FAILED (N errors)`，
   并额外区分三种非 PASS：`BUILD-ERR`（xvlog/xelab 失败）、`NO-VERDICT`（跑完了但没有结论行）。
   ★ `NO-VERDICT` 必须单独成一类——**"跑完但没结论"与"结论失败"是两回事**。
3. **退出码约定**：全部 PASS ⇒ `exit 0`；存在非 PASS ⇒ `exit 1`。让 CI/脚本能自动判。
4. **自动写汇总** `sim/logs/SUMMARY.md`，含时间戳、`PASS n / 共 m`、以及逐台表格
   （测试台 / 结果 / 错误数 / 耗时 / 日志链接）。本工程现行是 **PASS 21 / 21**（2026-10-12 23:52:26）。
5. **支持 `-Only tb_a,tb_b` 子集重跑**与 `-Rebuild`，否则一次全跑近 9 分钟
   （最慢的 `tb_enc_top` 单台 **488 s**）。
6. 原语仿真桩（本工程 `sim/xilinx_prims_stub.v`）只提供 `BUFG` / `ODDR` 的行为模型，
   **不进综合源集**；在 `sim/README.md` 里写清这一点，否则接手人会以为你在仿真假原语。

### 3.2 综合/实现/位流：一键流程与报告清单（`tools/impl_check.tcl` 形态）

```tcl
read_verilog   $ROOT/rtl/*.v
read_xdc       $ROOT/constr/enc_top.xdc
synth_design -top enc_top -part xc7a35tfgg484-2 -flatten_hierarchy rebuilt
opt_design ; place_design ; route_design
report_utilization       -file "$OUTDIR/impl_util.rpt"
report_timing_summary    -file "$OUTDIR/impl_timing.rpt"
report_drc               -file "$OUTDIR/impl_drc.rpt"
report_route_status      -file "$OUTDIR/impl_route.rpt"
report_clock_interaction -file "$OUTDIR/impl_clkint.rpt"
write_bitstream -force   "$OUTDIR/enc_top.bit"
puts "BITSTREAM_WRITTEN $OUTDIR/enc_top.bit"
```

容易忽略的三点：

- **必须跑到 `route_design` 之后时序报告才有内容**：综合阶段的 `report_timing_summary` 是空的，
  拿着综合报告说"时序收敛"是典型的假证据。
- **`write_bitstream` 是"引脚分配是否完整"的最终判据**：若仍有端口缺 `PACKAGE_PIN`，
  DRC 的 `UCIO-1` 会在这里把你拦下——**比读 DRC 报告更可靠**。
- **把位流大小与 SHA256 记下来**：本工程每一次采纳版都记了
  （生产版 **1,042,208 B @2026-10-12 23:59:27，SHA256 `D93DEBF9…7725`**；
  ILA 版 **1,428,064 B @2026-10-13 07:12:11，SHA256 `5CC779EE…EC52`**）。
  没有哈希，"我们测过的那一版"和"仓库里这一版"就可能不是同一个东西。

### 3.3 用现行实测数字刷新全仓文档（`tools/sync_doc_numbers.py` 形态）

这是本技能里**最值得抄**的一条。实现要点：

1. **显式规则表**：`RULES = [(旧字符串, 新字符串, 说明), ...]`，**不做任何模糊匹配**。
2. **两阶段替换**：先把每个旧值换成**唯一占位符**，再把占位符换成新值。
   ⇒ 避免**链式污染**（例如把 `0.655` 改成 `0.544` 之后，又被"`0.544` → 别的"再改一次）。
3. **逐文件报告命中次数**，便于人工复核。
4. `--check` **只报告不改写**（默认先跑这个）。
5. **`ROUNDS` 留档每一轮"旧值 → 新值"的映射（含 commit 与证据来源）**，
   `--audit` 用它扫描全仓，报告哪些旧值**仍作为"已作废/历史"被有意保留**、哪些是漏改。
   ★ `ROUNDS` **不参与自动改写**——否则"历史口径"会被静默抹掉，
   而"能指出上一版为什么错"恰好是评委想看的东西（见技能 4 §3.3）。

### 3.4 静态检查纳入同一条流水线

本工程把这几项与回归并列跑（都是纯静态、秒级）：

| 脚本 | 作用 |
|---|---|
| `tools/scan_dangling.py` | 找**真死信号**（被计算但从未被读的线）——它曾抓出"测试台在空转"（见技能 3） |
| `tools/scan_unused.py` | 找未被使用的信号/端口 |
| `tools/lint_all.ps1` | 全仓 lint |
| `tools/tidy_sim_logs.py` | 仿真日志归档清理 |
| `tools/pinplan_check.py` / `tools/pinout_verify.py` | 引脚方案自洽性校验（两者都报 `RESULT: PASS`） |

## 4. 失效条件

- 自动汇总**只解决"记录"，不解决"判定"**：如果测试台的断言本身是空的
  （本工程真发生过，见技能 3 §5），自动汇总会**忠实地把假 PASS 汇总进去**。
  因此"回归全绿"必须与技能 3 的三条检查配套使用。
- 一键流程脚本里的**绝对路径**（`D:\Vivado\2026.1\...`、`C:/Users/.../FPGA`）必须改成相对路径
  或环境变量，否则别人复现不了。本工程 `tools/run_sim.ps1` 已改为
  `$Root = Split-Path -Parent $PSScriptRoot`，可作为范例。
- **报告文件的路径会被 README/报告正文引用**，改名/移动报告目录等于改文档；
  建议 `_synth_work/` 目录名与文件名一次定死。
- `sync_doc_numbers.py` 的规则表是**手工维护**的：新数字出现而规则表没加 ⇒ 仍然漏改。
  它降低风险，不消除风险；`--audit` 是它的补偿手段。

## 5. 提炼过程（从哪些失败或观察中总结）

1. **`Could not open file ... for writing` 不是代码问题**：首轮回归报
   `ERROR: [XSIM 43-3356] Could not open file xsim.dir/tb_enc_top_sim/xsim.type for writing`，
   根因是**上一轮被中断的 xsim 进程仍挂着并占用该目录**（PID 29468 / 28132）；
   杀进程后单跑立即 PASS（497 s）。
   ⇒ 结论写进文档：「**看到 `Could not open file … for writing` 先查残留 xsim 进程，不要怀疑代码**」，
   并因此给每个测试台分配独立工作目录。
2. **"跑完但没结论"必须单独判定**：只认 `TEST PASSED`/`TEST FAILED` 会让
   xvlog 编译失败、xelab 精化失败、或仿真中途崩溃的用例都落到"没有结论"这一片灰色地带，
   于是有了 `BUILD-ERR` / `NO-VERDICT` 两个独立状态。
3. **文档里的旧数字是最容易被忽略的扣分点**：本工程实测过"同一个指标在 5 处文档里口径不一"，
   因此写了 `sync_doc_numbers.py`；并用 `--audit` 把**有意保留的历史口径**
   （例如"总输入延迟 19.5…24 ns 不是手册 tPD"的订正）与**漏改**区分开。
4. **沙箱/工具链会制造假失败**（三次真实记录）：
   ① `tools/ila_capture.tcl` 用 `[file size $CSV]` 检查，
   但 `write_hw_ila_data -csv` **会自己补 `.csv` 后缀** ⇒ 每次都在最后一步报错并以 **exit 1** 结束；
   ② `vivado` 在打印 `Bitgen Completed Successfully` 之后**不再退出**（17 分钟无新输出）
   ⇒ 按 `.bit` 与五份 `impl_*.rpt` 的**时间戳与哈希**确认写完后手工终止；
   ③ 受限沙箱下 `opt_design` 展开 debug core **挂死**（`rundef.js(122,5) Access denied`，
   两个 OOC run 的子进程 0% CPU 死等 11 分钟）⇒ ILA/生产位流构建一律用全权限跑，同脚本一次通过。
   ⇒ 通用教训：**"脚本 exit 1"不等于"构建失败"——先看产物时间戳与哈希**。

## 6. 已验证的效果（本工程实测）

| 项 | 数字 | 证据 |
|---|---|---|
| 仿真回归自动化 | **PASS 21 / 21**，错误数 0，退出码 0；每台有独立日志 | `sim/logs/SUMMARY.md` @2026-10-12 23:52:26 |
| 回归耗时结构 | 全量 ≈ 9 分钟，最大单台 `tb_enc_top` **488 s** | 同上 |
| 生产版资源/时序报告 | Slice LUT **6298/20800 = 30.28%**、FF **4074/41600 = 9.79%**、**Block RAM 0/50**、DSP 16/90、IOB 50；`sys_clk` WNS **+0.959 / TNS 0.000 / 0 失败（11,275 端点）** | `_synth_work/impl_util.rpt` / `impl_timing.rpt` @2026-10-12 23:59 |
| ILA 版资源/时序报告 | LUT **9234 = 44.39%**、FF 8937、**BRAM 7.5 = 15.00%**、WNS **+0.332 / 0 失败（20,165 端点）** | `_synth_work/impl_ila_util.rpt` / `impl_ila_timing.rpt` @2026-10-13 07:11 |
| 位流可追溯 | 生产版 1,042,208 B / `D93DEBF9…`；ILA 版 1,428,064 B / `5CC779EE…` | 同上 |
| 文档数字同步 | 一条命令 `python tools/sync_doc_numbers.py --audit` 列出各轮"旧值→新值"与漏改 | `tools/sync_doc_numbers.py` |

**可直接借用的动作清单**：
① 每个测试台独立工作目录 + `PASS/FAIL/BUILD-ERR/NO-VERDICT` 四态判定 + 退出码；
② 综合之外**必须跑到布线**才谈时序；位流哈希与大小入档；
③ 写一个 `--check` 默认只报告的数字同步脚本，**规则表显式、两阶段替换、历史映射留档**；
④ 把静态检查（死信号/未用信号/lint）与回归并列跑——它们抓的是断言抓不到的东西。
