# PYNQ 通用技能包

面向 **PYNQ 框架**（.hwh 地址表 / Overlay / PS-PL 边界 / DMA）的一组可执行工具与检查单。
**不与本队题目绑定**：它不关心你的 overlay 是编码器、滤波器还是图像流水线——
它只检查"地址表对不对、位流与地址表是不是一对、上板判据能不能失败"这三件通用的事。
换题目不用改，换板卡（Zynq-7000 ↔ MPSoC）只需重导 `.hwh`，见 §6。

---

## 0. 三分钟上手

```bash
# 1) 先自检：证明这套工具自己没坏
python skill/pynq/pynq_selftest.py                 # 期望 13/13

# 2) 体检一个交付目录（.bit + .hwh 是不是一对、地址表是否自洽）
python skill/pynq/pynq_bundle.py my_overlay/

# 3) 只想知道地址表长什么样
python skill/pynq/pynq_hwh.py my_overlay/app.hwh --md addr.md
```

三步都不需要板卡、不需要 PYNQ 库、不需要 Vivado——**只依赖 Python 标准库**。
这是刻意的设计：`.hwh` 是文本文件，PYNQ 的事实（地址、时钟、IP 清单）全在里面，
所以"上板前的体检"完全可以离线做，而且可进 CI。

---

## 1. 适用范围

**适用**：

- 用 Vivado 的 IP integrator（BD）搭 PS + PL，然后用 PYNQ 的 `Overlay()` 加载；
- 交付物是 `.bit` + `.hwh`（或 `.xsa`）的组合；
- 需要回答"这个 overlay 换个板子还能不能用""地址怎么变了""判据到底测没测到"。
- 想给 PE 或队友留一份"上板前必须先过"的检查，而不是口口相传。

**不适用**（别硬套）：

- 纯 PL 的 FPGA 板卡（Artix/Kintex，没有 PS、没有 Overlay 概念）——本项目就是这种，
  本目录对它是"换个题目也能用的主机侧工具"，不依赖 PS；
- Vitis/PetaLinux 的 `.xsa` 全流程（`pynq_bundle.py` 只会提示"有 .xsa"，不做 XSA 解析）；
- PYNQ 2.x 及更早（`.hwh` 结构与 `Overlay` 行为不同）。

---

## 2. 目录里有什么

| 文件 | 形态 | 作用 | 已验证效果 | 失效条件 |
|---|---|---|---|---|
| `pynq_hwh.py` | 校验脚本 | 解析 `.hwh`：IP 清单、从口地址表、时钟域；判据 `ADDR-000…010`/`CLK-001,002`/`REG-001`；`--diff/--json/--md` | 真实 BD 导出的 hwh（57,252 B）：无地址时 `ADDR-000 FAIL`；补入地址后 `PASS（3 IP / 2 段 / 0 警告）`；重叠地址 `ADDR-010 FAIL` | 非 Vivado 导出的 hwh、非 `EDKSYSTEM` 根节点、`.xsa`；寄存器偏移它给不了 |
| `pynq_bundle.py` | 校验脚本 | 交付目录体检：位流与地址表配对、时间戳、sha256、两版 IP 清单对比（`BUNDLE-001…010`） | `examples/bundle` → `PASS`；`examples/bundle_nohwh` → `BUNDLE-001`+`003` FAIL，EXIT 1 | 不看 `.xsa` 内部；不判断位流是否真的能下载；只查"文件级一致性" |
| `pynq_overlay.py` | 模板 + 校验脚本 | 主机侧驱动骨架：5 条上板判据（Walking-ones、CTRL/STATUS、DMA 长度、逐点比对、计数一致）；`--mock` 离线跑，`--overlay` 真板跑 | `--selftest` 4/4（3 条负对照）；`--mock --count 1024` → `PASS（5/5）` | 假定"寄存器 32 bit、DMA 一路收发、计数寄存器存在"；乱序/多通道要改判据；真机路径未在本队硬件实测 |
| `pynq_selftest.py` | 校验脚本 | 这套包的自我验收：13 用例，含 5 条"必须失败"的负对照 | `13/13 用例符合预期`，EXIT 0 | 改了夹具不改期望值会红；只证明样例成立，不证明你的 overlay 成立 |
| `pitfalls_pynq.md` | 踩坑清单 | 14 条：地址/.hwh（4）、DMA/数据通路（4）、板卡与运行时（6）；每条带证据等级 `[实测]/[文档]/[待验]` | 每条都对应一个工具判据或官方文档事实 | 绑定 PYNQ 3.x + Zynq 的 PS-PL 模型；B/C 组未上板实测 |
| `prompts/P6_hwh_to_register_map.md` | 提示词工作流 | 让模型**只依据** hwh 与 IP 手册产出地址表/寄存器表/访问代码，并强制标"不确定" | 在本仓库的 hwh 上跑过：地址表与 `pynq_hwh.py --md` 逐行一致 | 手册不公开时退化为"以 RTL 为准" |
| `prompts/P7_bringup_falsification.md` | 提示词工作流 | 上板前的证伪两轮法：先列"能让判据全过的最小改动"，再真的改一处看它红不红 | 结论已固化为 `--selftest` 里的 3 条负对照 | 依赖真实传感器等昂贵资源时只能做部分证伪 |
| `templates/make_hwh_fixture.tcl` | 案例模板 | 没有 Zynq 器件族时，也能导出一份结构同源的 `.hwh` 用来练手/做夹具（Artix-7 上两个 AXI-Lite 从口的 BD） | 本仓库 `examples/real_bd/design_1.hwh` 就是它导出的（Vivado 2026.1，57,252 B） | 换 Vivado 大版本 IP vlnv 会变；只导 handoff，不产生位流 |
| `examples/` | 夹具 | 真实 hwh（3 份变体）+ 位流配对样例；说明见 `examples/README.md` | `pynq_selftest.py` 全部用例都跑在它上面 | `.bit` 是 4 KB 占位文件，不是可用位流 |

---

## 3. 使用方法

### 3.1 上板前（不需要板卡）

```bash
python skill/pynq/pynq_bundle.py <交付目录>          # 位流/地址表是不是一对
python skill/pynq/pynq_hwh.py <app.hwh>              # IP、地址、时钟域
python skill/pynq/pynq_hwh.py new.hwh --diff old.hwh # 换版后地址有没有动
python skill/pynq/pynq_hwh.py <app.hwh> --json a.json --md a.md   # 进 CI / 进文档
```

判据怎么读：

- `[FAIL]` 开头的 → 上板一定出问题，先修；
- `[WARN]` → 可能出问题，看它的解释；
- `[NOTE]` → 事实提醒（如"hwh 不含寄存器表"），不是错误。

退出码：`0` 全过（NOTE 不影响）、`1` 有 FAIL/WARN、`2` 文件不存在或不是 `.hwh`。
**`2` 必须保留语义**：工具判断不了的时候不许假装通过。

### 3.2 第一次上板

```bash
python skill/pynq/pynq_overlay.py --overlay app.bit --map app.hwh --dev myip --count 4096
```

5 条判据按顺序：

1. **寄存器 Walking-ones**（0x1/0x2/0x4/0x8/0x10/0x80000000 写读回）→ 抓"地址没解对"；
2. **CTRL→STATUS**（写完控制位，状态位要跟着变）→ 抓"写通道通、读通道不通"；
3. **DMA 长度一致** → 抓"字节/点数混用"；
4. **逐点比对**（报第一个坏点与它的位置）→ 抓"逻辑错/错位/陈旧数据"；
5. **COUNT 与点数一致** → 抓"PL 侧少算或多算"。

读回全是 0 时，工具会补一句"先怀疑地址没解对或 DMA 没启动"——这是最常见的第一现场。

### 3.3 离线验证你自己的判据

```bash
python skill/pynq/pynq_overlay.py --selftest     # 4 个用例，含 3 条负对照
python skill/pynq/pynq_overlay.py --mock         # mock 上跑 5 条判据
```

`--mock` 里的 `MockDevice` 有 `decoded=False` 模式（读回全 0）、可注入"丢一个数"、
"错一位"——用来确认你的判据**真的会红**。

---

## 4. 已验证到什么程度

| 结论 | 证据 |
|---|---|
| `.hwh` 解析正确 | 用的是 Vivado 2026.1 在 `xc7a35tfgg484-2` 上**真实导出**的 handoff（`examples/real_bd/design_1.hwh`，57,252 B，3 个 IP），不是手写样例 |
| 地址类判据有效 | 同一份真实 hwh 补入两段地址后 PASS；把 `bram_ctrl` 挪到 `gpio_regs` 里立刻 `ADDR-010 FAIL` |
| 配对/时间戳判据有效 | `bundle` PASS、`bundle_nohwh` FAIL、把 hwh 时间戳改旧 → `BUNDLE-004` |
| 驱动判据有效（离线） | `--selftest 4/4`、`--mock PASS 5/5`；负对照分别命中"读回全 0""DMA 少一个数""错一位" |
| 驱动路径 | `PynqTransport` 走你板上的 `Overlay` 与 DMA；没装 PYNQ 库时给出明确报错而不是崩，`--mock` 可在任何机器上复现全部 5 条判据 |

每一行都附了可复现的证据（夹具 + 命令）：读这张表的方法不是"信结论"，而是把命令在
你自己的 overlay 上重跑一遍，看它是否还给出同样的判决。

---

## 5. 它与"本队题目"的解耦点

- 工具只读 `.hwh` 与文件时间戳，不知道你是磁编码器还是图像处理；
- `pynq_overlay.py` 的 5 条判据是**任何 AXI-Lite + AXI-Stream overlay 都该有**的，
  换成你自己的 IP 只改 `--dev` 名字与寄存器映射常量；
- 夹具里的 `.bit` 是占位文件——换题目时把它替换成你自己的位流，`pynq_selftest.py`
  里 `bundle` 相关用例的期望值不需要动（判据只看"配对"，不看内容）。

---

## 6. 换板卡

1. 新板上重新导出 `.hwh`（`generate_target {hw_handoff}`），与位流同名放在一个目录；
2. `python skill/pynq/pynq_bundle.py <新目录>` → 先过配对与时间戳；
3. `python skill/pynq/pynq_hwh.py <新.hwh>` → 看时钟域是不是仍是单频域，
   `FREQ_HZ` 是否与 PS 实际配置一致（`CLK-002` 会提示缺频率）；
4. 上板跑 `pynq_overlay.py`；**先过 5 条判据，再谈功能**；
5. 把新板的结果补进 `pitfalls_pynq.md` 的"证据等级"里（把 `[待验]` 改成 `[实测]`）。

---

## 7. 这套东西是从哪些失败里长出来的

- **地址表当寄存器表用**：早期想把 `.hwh` 读出"ctrl 在 0x00"，结果发现 Vivado 根本不导出
  寄存器表 → 有了 `REG-001` 的 NOTE 与 P6 提示词的第 2 步（必须引手册页）。
- **位流换了、hwh 没换**：症状是"读出的数字看着合理但全错位"，
  在通用工程里也极常见 → 有了 `BUNDLE-004`（时间戳）与 `BUNDLE-010`（`--diff`）。
- **判据永远为真**：本工程在 RTL 阶段吃过三次（三条"看起来 PASS"的断言、
  一条恒真断言、UVW 扇区截断仍全绿，见 `../pitfalls.md` P-05/P-06 与记录 47/49）
  → 上板判据全部配负对照，`--selftest` 4 个用例里 3 个是"必须失败"。
- **用墙上时间当指标**：同一设计两次差 30%（`../pitfalls.md` P-15）→ 吞吐只从
  周期计数器算，mock 的墙钟只用来提醒。
- **门禁自己坏了**：记录 73（全面自查要靠专门证伪的人）→ 才有 `pynq_selftest.py`
  这个"检查工具的工具"，13 个用例里有 5 个是必须失败的。

---

## 8. 已知边界

- 只解析 `EDKSYSTEM` 根的 `.hwh`；`.xsa`（Vitis）不解析，只提示存在；
- 只判断文件级一致性，不管位流在板上加载后寄存器行为如何（那属于上板判据，见 §3.2）；
- `pynq_overlay.py` 的寄存器模型固定为 5 个 32 bit 寄存器 + 一路 DMA；多通道/64 bit/
  中断驱动需要改判据（改的地方在文件头注释里标了）；
- 判据关键字（`ADDR-`/`CLK-`/`BUNDLE-`/`PYNQ-`）被脚本和文档同时引用，改名要两处一起改。
