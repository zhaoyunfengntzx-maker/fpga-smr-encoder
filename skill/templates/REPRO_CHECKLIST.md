# 复现清单（陌生机器从零到 PASS）

> 失效条件：默认环境是 Windows + Vivado + Python 3；换 Linux/macOS 时
> 时钟、路径分隔符、编码相关的几条要改写。它验证的是"能不能从零跑到 PASS"，
> 不验证"结果是否正确"——后者靠测试台与报告判据。

> 用法：把本文件复制进你的仓库根目录，改名 `REPRO.md`，逐条 `<...>` 填掉。
> 适用对象是"拿到这个仓库、但没参与开发的人"。写下这份清单的人最常犯的错是
> 用自己机器上的隐含前提（已装的 IP、已配的环境变量、放在 D 盘的许可证）。
> 本工程因此专门让一个人用"干净用户 + 不装 IP"跑过一遍，才发现 `_synth_work`
> 里有一半是必须提交的中间文件（见 skill/repo-reproducibility.md §4）。

## 0. 环境（版本不写死 = 不可复现）

| 项 | 要求 | 检查命令 | 期望 |
|---|---|---|---|
| 操作系统 | `<Windows 11 / Ubuntu 22.04>` | `ver` | `<...>` |
| Vivado | `<2026.1>`（其他版本可能过不了时序） | `vivado -version` | `<...>` |
| Python | `>= 3.9`，仅标准库 | `python -V` | `<3.13.9>` |
| 器件许可 | `<xc7a35t 已授权>` | `vivado -mode batch -source <(echo "exit")` | 返回 0 |
| 磁盘 | `>= <5>` GB 空余（实现产物很大） | `df -h` | `<...>` |

## 1. 取代码

```bash
git clone <url> <repo> && cd <repo>
git log -1 --format='%H %s'      # 期望 <hash>，写进报告元信息
python skill/scripts/skill_selftest.py   # 期望 14/14 用例符合预期
```

- [ ] `skill_selftest.py` 通过（不通过就别往下走：判据本身坏了）
- [ ] `python skill/scripts/check_manifest.py --verify` 期望 `PASS`
- [ ] 文档链接无死链：`python tools/check_links.py`（没有就跳过）

## 2. 只跑仿真（10 分钟，不占 license 队列）

```bash
cd sim
vivado -mode batch -source ../skill/templates/run_sim.tcl    # 或你自己的仿真入口
grep -h "TEST PASSED\|TEST FAILED" logs/*.log
```

- [ ] 所有测试台 `TEST PASSED`；有 `FAILED` 的必须在报告里点名，不许隐藏
- [ ] `python skill/scripts/tb_wiring.py --scan sim --strict` → 0 ERROR
- [ ] 黄金逐点比对：`python skill/scripts/check_vectors.py model/golden.csv sim/out.csv --tol 0`

## 3. 从零综合 + 实现（30–60 分钟）

```bash
vivado -mode batch -nojournal -nolog \
  -source skill/templates/run_vivado.tcl \
  -tclargs <top> <part> build/repro
python skill/scripts/check_impl_reports.py --dir build/repro
```

- [ ] `check_impl_reports.py` 退出码 0、`PASS: 9/9`
- [ ] WNS/WHS 与报告里写的数字一致（差超过 0.05 ns 要解释：机器、种子、Vivado 小版本）
- [ ] 资源占用与报告一致（BRAM/DSP 通常是整数，LUT 允许 ±2%）
- [ ] `report_drc` 无 Error；有 Warning 的逐条说明

## 4. 位流与上板

- [ ] `build/repro/<top>.bit` 的 SHA256 与 `SHA256SUMS.txt` 一致
- [ ] 下载后：`<预期现象>`
- [ ] 断电重启 3 次仍正常（排除依赖调试器的假成功）
- [ ] 连续跑 `<2>` 小时无异常（温度、丢帧、误码）

## 5. 常见断点（照这个顺序查，别从"重装 Vivado"开始）

| 现象 | 先查什么 | 常见原因 |
|---|---|---|
| `synth_design` 报找不到模块 | `glob` 到的文件列表 | 源文件在子目录、大小写不一致（Linux） |
| 时序比报告差 0.3 ns | `report_clock_utilization`、是否换了器件速度等级 | 器件型号写错一位（`-1` vs `-2`） |
| 位流能下但没反应 | 时钟是否真的跑起来（量测/`ILA`） | 时钟约束写了但管脚没连，或 PLL 未锁定 |
| xsim 卡住不退出 | 有没有 `$finish`、有没有超时保护 | 测试台死等握手（本工程记录 1） |
| 中文乱码 | 编辑器/控制台编码 | PowerShell 默认 GBK 写 UTF-8 文件（记录 64） |

## 6. 提交前自检

- [ ] `git status` 干净；`SHA256SUMS.txt` 与包内文件一致
- [ ] 大文件（`.bit`/`.dcp`/波形）是否该进包：按竞赛要求，位流进、波形不进
- [ ] 报告里每个数字都能在本仓库找到出处（文件 + 行号）
- [ ] 匿名检查：`python tools/check_anonymity.py`（若竞赛要求匿名）
- [ ] 用一台**不是开发机**的机器跑第 1–3 节，全绿才算"可复现"
