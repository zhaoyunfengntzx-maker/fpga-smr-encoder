# skill/ —— 可复用技能包

这个目录不是"文档收藏"，而是**能直接搬到你题目里的东西**：可运行的校验脚本、
可复制的工程/报告模板、可粘贴的提示词、按症状检索的踩坑清单。

- 全部脚本 **只依赖 Python 标准库**，Windows / Linux 都能跑，不需要 Vivado 许可；
- 全部样例都是**可执行夹具**（`skill/examples/`），"该通过的通过、该失败的失败"由
  `skill/scripts/skill_selftest.py` 一条命令证明；
- 每一项都写了**适用场景、使用方法、已验证的效果、失效条件**，以及它是从哪次失败里
  总结出来的。

> 唯一前提：你的题目里有"要验证的数字"。如果你的工作完全没有可测量的输出，
> 这个包的校验脚本部分帮不上忙，但提示词与清单部分仍然可用。

---

## 0. 陌生队伍三步上手（约 15 分钟）

```bash
# 第 1 步：先证明这套判据本身可信（不碰你的工程，只读 examples/）
python skill/scripts/skill_selftest.py
# 期望最后两行：结果：14/14 用例符合预期 / => 四个校验脚本在自带样例上都给出预期判决

# 第 2 步：挑一个模板复制进你的工程
cp skill/templates/tb_skeleton.v        sim/tb_my_top.v      # 测试台骨架
cp skill/templates/xdc_source_sync.xdc  constr/top.xdc       # 约束骨架
cp skill/templates/fixedpoint_model.py  model/golden.py      # 定点黄金模型骨架

# 第 3 步：把"判决"接到你的报告/CI 上（自己改判据阈值）
python skill/scripts/check_impl_reports.py --dir <你的实现产物目录>
```

三步都跑通后，再按下面第 1–5 节按需取用。

---

## 1. 校验脚本（`skill/scripts/`，可执行，退出码即判决）

| 脚本 | 解决什么问题 | 用法 | 已验证效果 | 失效条件 |
|---|---|---|---|---|
| `check_impl_reports.py` | 综合/实现报告→机器判决，替代"人眼看报告" | `python check_impl_reports.py --dir <含 timing/util/drc/check_timing.rpt 的目录>`；`--min-wns`、`--max-util LUT=60`、`--json` | 本工程 v74：`PASS 9/9`，读 WNS `+0.409`、LUT `52.53%`、BRAM `64.0%`；失败夹具 `FAIL 2/10`（WNS −0.123、failing 7、DRC 2 Error） | 报告不是 Vivado 默认格式（改过 `-file` 里的列）；或根本没有 `report_timing_summary`——此时返回 **2**，不猜 |
| `check_vectors.py` | 黄金模型 vs 仿真输出**逐点**比对 | `python check_vectors.py golden.csv sim.csv --tol 0 --hist` | 16 点夹具：一致 `PASS 16/16`；差 5 LSB 时 `FAIL 1/16`，指出点号、期望/实测/误差 | 两边点数不等、或输出有乱序/丢点（要先做"第 k 个输出↔第 k 个输入"的对齐） |
| `check_manifest.py` | 交付包 SHA256 清单，防"改了文件没重打包" | `python check_manifest.py --dir . --verify`；首次 `--write` | 样例 `PASS 2/2`；改动一个文件后 `FAIL`（被改动 1） | 文件在打包后被正常修改（那就该重新 `--write`）；符号链接未处理 |
| `tb_wiring.py` | 抓"空转测试台"：能跑、打印 PASSED，但激励没接上 | `python tb_wiring.py sim/tb_x.v --dut rtl/x.v --strict`；或 `--scan sim` | 本工程记录 1 的那类缺陷，定位从半天降到 1 秒；坏夹具报 E1/E2/W1 并给行号 | 只支持**按名连接**（`.port(sig)`）；位置连接不查 |
| `skill_selftest.py` | 给上面四个脚本配的"测试台" | `python skill/scripts/skill_selftest.py` | 14/14 用例符合预期（含 4 条负对照：该失败必须失败） | 你自己改了夹具却没改期望值 |

**为什么退出码要分 0/1/2**：`0` 通过、`1` 判据失败、`2` 工具**无法判断**。
第三种必须存在——否则"读不到报告"会被当成"通过"，这是本工程所有假成功的共同起点。

---

## 2. 案例模板（`skill/templates/`，复制即用）

| 模板 | 适用 | 里面已经处理好的坑 | 已验证 | 失效条件 |
|---|---|---|---|---|
| `tb_skeleton.v` | 任何流式/打拍类模块的自检测试台 | 超时保护、`$finish`、逐点比对、输出点数校验、`stim.txt` 激励文件、前 20 条错误打印 | 在 Vivado xsim 2026.1 实跑：内部斜坡 `TEST PASSED (64 checks)`；16 点文件 `TEST PASSED (16 checks)`；改错 1 个期望值 → `TEST FAILED (1 errors)` | 非流式接口（乱序/多周期延迟/一进多出）要改成按事务号配对，否则 FAIL 指错原因 |
| `dut_passthrough.v` | 配合上面的模板，让模板第一次就能跑出 PASSED | 打一拍 + valid 对齐 | 同上（同一快照） | 它只是流程探针，不是被测件；换真 DUT 后 valid 对齐要重写 |
| `fixedpoint_model.py` | 定点黄金模型骨架（Q 格式、饱和、四舍五入、全周扫描） | `asr/rshift_round/sat` 三原语、Python 与 Verilog 移位语义对齐、单调性自检 | `--check` 6 项原语断言 + 单调性扫描全过；`--n 8` 输出 sin 相位正确（0/23170/32767/23170/0/…） | 不含除法/乘法截位/浮点；换分辨率要重生成 LUT 并补端点判据 |
| `xdc_source_sync.xdc` | 主时钟/派生时钟/源同步输入输出/异步跨域 | `set_input_delay` 的 `-max/-min` 语义、`clock_fall`、`set_clock_groups` 与两级同步器的配合、豁免必须可对账 | 与 v74 约束同构：该版 5 条 `no_input_delay`、2 条 `no_output_delay` 全部在文件里显式豁免 | 有 PS/MMCM（主时钟必须由工具生成）、DDR 未补 `-clock_fall` 时不适用 |
| `run_vivado.tcl` | 非工程模式一次跑完 综合→实现→4 份报告→位流 | 固定报告文件名（供脚本解析）、时序不收敛时**非零退出且不写位流**、按目录收集源文件避免手写清单漏文件 | 本工程 v74 即由同一流程产出；报告随后被 `check_impl_reports.py` 判 PASS | 工程含 IP/Block Design 时不适用（非工程模式不认），要改用工程模式 |
| `REPORT_OUTLINE.md` | 设计报告骨架，每个数字标注出处 | "实测"填不出来就必须降级为"未验证"；定点化决策表；负对照表 | 本工程设计报告 §13 的结构来源 | 它的价值全在"每个数字能指到源"；数字填不出来时必须写"未验证" |
| `REPRO_CHECKLIST.md` | 陌生机器从零复现清单 | 环境版本、只跑仿真、从零综合、上板、常见断点、提交前自检 | 本工程靠它发现"必须提交的中间文件"与"位流/报告不同步" | 面向 Windows + Vivado + Python 3；换 OS 时钟/路径/编码几条要改写 |

---

## 3. 提示词工作流（`skill/prompts/`，可直接粘贴）

| 提示词 | 用在什么时候 | 关键约束（防 AI 糊弄的地方） | 已验证效果 | 失效条件 |
|---|---|---|---|---|
| `P1_algorithm_to_datapath.md` | 拿到算法，要定运算单元/位宽/流水 | 禁止"经验值"，每行必须回答"少 1 bit 哪个指标先坏" | 定下 CORDIC 17 级（RMS 0.9375 LSB）、查表 vs 迭代的取舍、标定 20.9839°→0.0165° | 纯软件/纯 HLS 的高层综合不适用（它问的是 RTL 位宽与流水） |
| `P2_report_to_bottleneck.md` | 时序不过或资源快满 | 只要"瓶颈+证据行号+改法+验证数字"，禁止"降频/换大器件"当首选 | v74 资源 52.53% LUT、v85 86.96% LUT 的瓶颈解释与改法 | 报告不是 Vivado 格式、或瓶颈在板级（供电/信号完整性）时，它只能给软件侧结论 |
| `P3_testbench_falsification.md` | 测试台已经"全绿"但你不放心 | 第二轮强迫它列"能让测试台错误通过"的改动，并真的注入 | 抓出空转测试台；累计 15 处 RTL + 9 处测试台缺陷 | DUT 行为本身不确定（含随机/外部激励）时"最小改动"不唯一，要改成"最小可复现配置" |
| `P4_subagent_audit.md` | 文件太多、要多人并行审计 | 只读、必须给 `文件:行号`、缺陷表上限 15 条、不确定放存疑表 | 23 文件/6 子代理/26 处真缺陷（3 条误报被复核驳回） | 子代理上下文装不下的大文件会被抽样，必须在任务里限行数并要求声明"读到第几行" |
| `P5_correction_turn.md` | 每次修完 bug | 五段格式，第 3 段必须是"数字或原文" | 本工程 86 条纠错记录，约 20 条提炼成 skill 条目 | 没有确定性判据（退出码/报告行/测试台结论）的任务，第③段会退化成"我觉得"——那就别用它 |

---

## 4. 踩坑清单（`skill/pitfalls.md`）

18 条，按阶段分组（仿真 / 约束时序 / 工程协作 / 测量报告），每条是
**触发条件 → 现象 → 排查命令 → 根因 → 修法 → 回归验证 → 失效 → 来源**。
直接从症状查：

| 你看到的现象 | 先看 |
|---|---|
| 仿真秒过、PASSED，但改 RTL 没反应 | P-01 |
| 负数段误差变大 | P-02 |
| 只有象限边界附近差 1 码 | P-03 |
| 180° 附近跳变/方向反 | P-04 |
| 角度只在一半区间对 | P-05 |
| WNS 好看但上板误码 | P-07 / P-08 / P-09 |
| 报告数字与截图/正文不一致 | P-10 / P-17 |
| 中文文件 diff 全乱 | P-11 |
| 下载卡死 | P-12 |
| 文档说"已提供"，实际没有 | P-14 |

---

## 5. 方法长文（原有 7 项，深挖用）

这些是"为什么"和"完整推导"，一页纸讲不完的问题在这里：

| 文件 | 一句话 | 何时读 |
|---|---|---|
| `golden-model-bit-exact.md` | 定点黄金模型怎么写才 bit-exact | 要建模型、或模型与 RTL 差 1 码 |
| `fixedpoint-width-safety.md` | 位宽/截断/符号扩展五类陷阱 | 加宽/截位、跨半量程出错 |
| `testbench-blindspot.md` | 测试台的三类盲区与负对照 | 测试台绿了但你不信 |
| `adc-source-sync-constraints.md` | 源同步接口约束的诚实建模 | ADC/编码器接口时序 |
| `deterministic-measurement.md` | 用计数而非墙上时间测性能 | 要做性能对比 |
| `vivado-report-autocollect.md` | 报告/日志自动采集与归档 | 报告数字要可对账 |
| `repo-reproducibility.md` | 单一入口、从零复现、答辩自检 | 交作业前 |

---

## 6. 证据与自检

```bash
python skill/scripts/skill_selftest.py -v     # 14 个用例，-v 打印每个脚本原始输出
python skill/pynq/pynq_selftest.py            # PYNQ 包：13 个用例（5 条负对照）
python skill/scripts/check_impl_reports.py --dir skill/examples/reports_pass --json /tmp/x.json
```

`skill/examples/` 下的夹具都不是编的：

- `examples/reports_pass|fail/` 的数值取自本工程 v74（`+0.409 ns`、`10926/20800`）
  与其失败回放（`−0.123 ns`、`7` 个失败端点）；
- `examples/vectors/` 是 16 bit 全周 16 点抽样，坏样例故意差 `−1` 与 `+5` LSB；
- `examples/wiring/` 复刻记录 1 的空转测试台（`din` 未赋值、`.en(1'b1)`、`.rst_n` 缺连接）。

**这个包自己也接受检验**：`skill_selftest.py` 里 4 条用例是"必须失败"的负对照。
只验证"该过的过了"是不够的——那正是我们踩过的坑（见 pitfalls P-16）。

---

## 7. 换题目/换板卡时的移植指引

| 资产 | 换题目 | 换板卡（同厂商） | 换到 PYNQ/Zynq |
|---|---|---|---|
| 四个校验脚本 | 直接用 | 直接用 | 直接用 |
| `tb_skeleton.v` | 改端口名、`W`、`TOL` | 不变 | 不改（PS 端不在 RTL 测试范围） |
| `fixedpoint_model.py` | 换 `model()`，保留三个原语 | 不变 | 不变 |
| `xdc_source_sync.xdc` | 改管脚号与频率 | 必改管脚/电平标准 | 需另加 PS 侧时钟与 AXI 约束 |
| `run_vivado.tcl` | 改 `-tclargs` 的 top/part | 改 part | 需改 block design 流程（本模板是非工程模式，不适用） |
| `pynq/`（整包） | 直接用（只读 `.hwh` 与文件时间戳） | 重导 `.hwh`，地址判据不变 | 就是为 Zynq 写的；换板步骤见 `pynq/README.md` §6 |
| 提示词 P1–P5 | 直接用 | 直接用 | P1 要加上"PS/PL 划分"的约束 |
| `pitfalls.md` | 直接用（配方言/工具差异） | 直接用 | 与 `pynq/pitfalls_pynq.md` 配合用 |

---

## 8. 通用 PYNQ 技能包（`skill/pynq/`，申报 3.3.2 加分）

`skill/pynq/` 是**独立于本队题目**的另一套东西：它面向 PYNQ 框架，换题目、换板卡都还能用。

| 资产 | 作用 | 已验证 |
|---|---|---|
| `pynq/pynq_hwh.py` | 解析 `.hwh`：IP 清单、从口地址表、时钟域；判据 `ADDR-00x/01x`、`CLK-00x`、`REG-001` | 真实 BD 导出 hwh（57,252 B）：无地址 → `ADDR-000 FAIL`；补地址 → `PASS 3 IP / 2 段`；重叠 → `ADDR-010 FAIL` |
| `pynq/pynq_bundle.py` | 交付目录体检：位流↔地址表配对、时间戳、sha256、两版 IP 清单对比 | `bundle` → `PASS`；`bundle_nohwh` → EXIT 1 |
| `pynq/pynq_overlay.py` | 上板 5 条判据（Walking-ones / CTRL-STATUS / DMA 长度 / 逐点比对 / 计数一致）+ `--mock` 离线版 | `--selftest 4/4`（3 条负对照）、`--mock PASS 5/5` |
| `pynq/pynq_selftest.py` | 这套包的自我验收，13 个用例 | `13/13 用例符合预期` |
| `pynq/pitfalls_pynq.md` | 14 条 PYNQ 专有坑，每条标 `[实测]/[文档]/[待验]` | 每条对应一个判据或文档事实 |
| `pynq/prompts/P6,P7` | hwh→寄存器映射；上板前证伪两轮法 | P6 的地址表与本包 `--md` 输出逐行一致 |
| `pynq/examples/` | 真实 hwh（3 份变体）+ 位流配对样例 | 全部用例都跑在它上面 |

**诚实边界（请照抄进你的报告）**：本队硬件是 Artix-7 XC7A35T（无 PS），本机 Vivado 也只装
Artix/Kintex 器件族，**没有任何一条上板实测**；`.hwh` 解析与文件级判据是真的，
真机路径 `PynqTransport` 只保证"没装 PYNQ 库时不崩、给出明确报错"。
上板部分是检查单，不是结论——这个区别写在 `skill/pynq/README.md` §4。

```bash
python skill/pynq/pynq_selftest.py     # 13/13
```

---

## 9. 每一项的来源（哪次失败/观察喂出来的）

| 项 | 来源 |
|---|---|
| `check_impl_reports.py` | 报告数字靠手抄、正文与图表不一致（`docs/ai-collaboration-log.md` 记录 77：屏上数字的保质期）；"时序没收敛但 CI 全绿" |
| `check_vectors.py` | 随机抽 100 点看不见半 LSB 边界差（`deliverables/design_report.md` §3.2）；"极差很小"的骗人断言（记录 47/49） |
| `check_manifest.py` | 交付包改了文件没重打包，评审看到的是旧位流 |
| `tb_wiring.py` | 空转测试台，20 分钟仿真 + 假 PASSED（记录 1） |
| `skill_selftest.py` | 只验证"该过的过"会漏掉"该失败的没失败"（记录 47/49 的同一逻辑） |
| `tb_skeleton.v` | 没 `$finish` 挂死、没超时保护静默 PASSED（记录 1；记录 47 的“看起来 PASS”） |
| `fixedpoint_model.py` | Python `>>` 与 Verilog `>>>` 语义错位、半 LSB 舍入（`deliverables/design_report.md` §3.2 表，RMS 0.597 → 0.3229 LSB） |
| `xdc_source_sync.xdc` | `set_input_delay` 写反导致负余量，被误当工具问题（记录 6） |
| `run_vivado.tcl` | 手写文件清单漏文件；报告改名导致后处理脚本找不到 |
| 提示词 P1–P5 | 86 条纠错记录（`docs/ai-collaboration-log.md`）里的通用部分 |
| `pitfalls.md` | 上述记录的"出现 ≥3 次"项升级为清单 |
| `pynq/pynq_hwh.py` | 想把 `.hwh` 当寄存器表用（Vivado 根本不导出寄存器表，`REG-001` 就是这么来的）；地址段没人核对 |
| `pynq/pynq_bundle.py` | "位流换了、hwh 没换"导致读出全错位（本工程在报告里记过同类：报告与位流不同步） |
| `pynq/pynq_overlay.py` | 判据永远为真（记录 47/49、`pitfalls.md` P-05/P-06）；用墙上时间当指标（P-15） |
| `pynq/pynq_selftest.py` | 记录 73：门禁自己坏了最难发现——要有专门检查"检查工具"的东西 |
| `pynq/pitfalls_pynq.md` | 造夹具时真实撞到的 Vivado 报错（无 Zynq 器件族、MicroBlaze 自动化失败、hwh 无 REGISTERS/无 MEMRANGES） |
