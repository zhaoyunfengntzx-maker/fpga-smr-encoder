# 技能包速查卡（一页）

> 打印出来贴在显示器边上的那种。全部命令都在**仓库根目录**执行；只有 Python 标准库依赖。

## 1. 三条命令

```bat
python skill/scripts/run_all_checks.py          :: 两套自检 + 四项门禁，一条命令给总判决
python skill/pynq/pynq_selftest.py              :: PYNQ 子包（不需要板卡、不需要 pynq 库、不需要 Vivado）
python skill/scripts/check_impl_reports.py --dir <你的实现报告目录>
```

## 2. 退出码语义（所有脚本统一）

| 码 | 含义 | 你该做什么 |
|---|---|---|
| `0` | 判据全部通过 | 继续 |
| `1` | 有判据不通过 | 看表格里标 `FAIL` 的那几行，`--json` 里有 `evidence.file/line` |
| `2` | **工具无法判断**（缺文件、读不出结论句、不是 Vivado 报告） | 修输入，**不要当成通过**——`2` 不是 `0` 的亲戚 |

## 3. 什么时候用哪个

| 场景 | 脚本 |
|---|---|
| 实现完了，想知道"过没过" | `check_impl_reports.py --dir <dir>`（WNS/WHS/失败端点/资源/DRC/check_timing） |
| 黄金模型 vs 仿真输出逐点比 | `check_vectors.py golden.csv got.csv --tol 1`（`--hist` 看误差分布） |
| 交付目录有没有被别人动过 | `check_manifest.py --dir <dir> --file SHA256SUMS.txt --verify` |
| 仿真"全绿"但我在怀疑测试台 | `tb_wiring.py tb_xxx.v --dut <dut.v>`（找空转台：输入没接、接常量、信号没赋值） |
| 换了板子/位流，地址表还对不上 | `pynq_bundle.py <交付目录>` + `pynq_hwh.py design_1.hwh --md` |
| 上板前想要一张判据清单 | `pynq_overlay.py --emit-script bringup.py` |

## 4. 五个最常踩的坑（详见 `pitfalls.md` / `pitfalls_index.md`）

| 编号 | 一句话 | 一眼识别 |
|---|---|---|
| P-01 | 测试台全绿，但 DUT 输入根本没接上 | 断言只看"跑了几次"，不看逐点值 |
| P-02 | `>>` 对负数向下取整，系统性少 1 LSB | 误差恒为 −1 且只出现在负半轴 |
| P-07 | `set_input_delay` 方向写反，虚假时序通过 | 余量漂亮得不像话，实测数据不稳 |
| P-17 | 文档里的数字与生成物不同步 | 同一个数字在两个文件里不一样 |
| PYNQ-02 | 位流换了、`.hwh` 没换 | 下载成功、读回全 0 |

## 5. 三条原则

1. **"没有失败样例"= 没验证**：每个判据都要有一条"必须失败"的负对照（`skill_selftest.py` 里有 10 条）。
2. **墙上时间不是判据**：用整数周期数 + 余数，不用"总时间 ÷ 帧数"。
3. **数字必须能追**：每个数字背后是 `文件:行号`、报告结论句或哈希——追不到就降级成"未验证"。

## 6. 失效条件

本卡只是索引：具体适用范围、用法、失效条件、提炼过程在每一项自己的文件里（`README.md` §2/§3 有列）。
命令按 Windows + PowerShell 写；Linux/macOS 把 `.bat` 换成 `.sh`，其余是纯 Python。
