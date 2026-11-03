# evidence_index（报告引用的唯一数字源）

> **规则**：`design_report.md` 里出现的每一个数字，都必须能在这张表里找到一行；
> 每行必须给出**仓库内的可复核产物**（文件路径 + 关键字段或命令）。
> 数字与 `../docs/DEV_STATUS.md` 冲突时，**以 DEV_STATUS 为准**，并回来改这张表。
>
> 标注：`[实测]` 板级读数 / `[仿真]` xsim 或 Python 模型 / `[手册]` 数据手册 / `[设计值]` 预算
>
> **★ 当前基线 = v90（2026-11-04 判据）**：生产位流 `data/v90/enc_top_v90.bit` **1,504,220 B** /
> SHA256 `A89512A5…827125` / `BUILD 0x0019` / WNS **+0.199** / LUT **10,978 = 52.78%** / BRAM 32/50 / DSP 17；
> 显示位流 `data/v90/enc_top_disp_v90.bit` **1,688,245 B** / WNS **+0.221** / LUT **17,090 = 82.16%** / BRAM 45.5/50；
> 板级：Z 频率 **7.62 / 7.65 Hz ⇒ 457–459 rpm**（每转 1 个 Z）、UVW 六态 `{5174,4761,4423,4776,4763,4786}`、`lock 0x0301`、
> 60 s **597,886 帧 / 9,964.8 fps**、`angle_vs_sc` offset 1.76° / RMS 0.71° / max 2.88°、ping 4/4、UDP 抓窗 28,672 点。
> 全部数字见 **§1.7** 与 [`data/v90/`](data/v90/)；判据唯一入口 [`../docs/39_acceptance_criteria_v90.md`](../docs/39_acceptance_criteria_v90.md)。
>
> **版本口径**：本表历史上按**交付位流 v62**（编码器 + 5 页触摸 UI + 千兆网）重写过一次；
> v62 之前（v9…v61）的数字一律标"历史"，只用于说明演进，不再作为结论依据。
> **v90 之前的 v66/v67/v68/v70/v71/v73/v74 各节保留为演进证据**，引用时必须带版本号并标"历史"。
>
> **源码包口径（`deliverables/submission/source_code.zip`）**：包内包含全部 `.rpt`（综合 / 实现 / 时序 / 资源 / DRC）、
> 逐台测试日志与 SUMMARY、v90 两个交付位流、全部 RTL（含 `rtl/eth`、`rtl/ddr3`）、定点黄金模型 `model/` 与 `skill/` 技能包。
> **为控制体积（65 MB 量级），历史位流 `data/v6x…v7x/*.bit`（约 72 MB）与采集数据 `data/*.csv`（约 50 MB）不随源码包分发**；
> 因此本表中指向这些 `.bit` / `.csv` 的链接在源码包内不可点开——但每行数字对应的 `.rpt` 报告都在包内，可原地复核。

>
> **v66 增量（2026-10-29）**：新增"转台适配"基线（延迟前馈 / 锁定状态机 / 偏置分块积分 / 全周补偿表），
> 拆成生产与显示**两个位流**，**均未上板**。其数字见 §1.1 与 [`data/v66/`](data/v66/)，报告对应 **§11**；
> 口径只到 **`[构建签核]` + `[仿真]`** 两级，任何 `[实测]` 字样都不得出现在 v66 名下。
>
> **v67 增量（2026-10-29）**：新增"小信号传感器"基线（200–300 mVpp、64 周期/转、前端 4.16×），
> 只有生产位流，**未上板**；数字见 §1.2 与 [`data/v67/`](data/v67/)，对应 `docs/29_lowsig_sensor_v67.md`。
> 口径同样只到 **`[构建签核]` + `[仿真]`**。
>
> **v68 增量（2026-10-30）**：新增"400 mVpp 单端正交 + 显示版"基线（64 周期/转、前端 4.16×），
> 拆成生产与显示**两个位流**，**均未上板**；数字见 §1.3 与 [`data/v68/`](data/v68/)，
> 对应 `docs/30_v68_400mvpp_display.md`。口径只到 **`[构建签核]` + `[仿真]`**。
>
> **v70 增量（2026-11-01，历史）**：转台 **2048 PPR** 的真机基线，修掉 `pole_counter` 相位差符号扩展
> 与 `uvw_gen` 反向环绕两处死锁。**生产位流已上板验收**（Z 12.00 Hz、distinct=2048、UVW 六态 /
> 60 s 598,115 帧），显示位流仅 `[构建签核]`；数字见 §1.4 与 [`data/v70/`](data/v70/)，对应
> [`docs/33_v70_release_report.md`](../docs/33_v70_release_report.md) 与 [`docs/32_board_test_report_2026-11-01.md`](../docs/32_board_test_report_2026-11-01.md)。
> **时序/资源签核一律以 §1.7 的 v90 为准；v62 只作"编码器 + UI + 网"演示口径。**

---

## 0. 一键复现全部数字（评委可照抄执行）

```powershell
# —— 仿真回归：主回归应输出 PASS 37/37（v90 回归轮，2026-11-04）+ disp/ 20/20，共 57 台
powershell -File tools/run_sim.ps1

# —— 静态检查：合计 ERROR 0 / WARNING 0
powershell -File tools/lint_all.ps1 -Clean

# —— 引脚与布局：均须 RESULT: PASS
python tools/pinout_verify.py
python tools/pinplan_check.py

# —— 算法模型（第 ① 层验证，报告 §3 的全部 [仿真] 数字来源）
python model/golden_model.py            # → A–G 误差表（§3.1）
python model/cordic_model.py            # → CORDIC 最坏 0.9375 LSB（§3.2）
python model/abz_uvw_model.py           # → 6/6 PASS（§3.5）
python model/loop_filter_model.py       # → 21 组 kp/ki 稳定性（§3.3）
python model/calib_shift_judge.py       # → 粗调移位判据对照

# —— 交付位流签核（已归档，不需重跑综合；本表 §3 的数字全在这里）
#   deliverables/data/v62/impl_timing.rpt        WNS +0.471 / WHS +0.042 / 0 失败 / 33,255 端点
#   deliverables/data/v62/impl_util.rpt           LUT 17,059 = 82.01% / BRAM 46/50
#   deliverables/data/v62/impl_drc.rpt            97 checks / 0 Error
#   deliverables/data/v62/enc_top_v62.bit         1,694,505 B（SHA256 见 §1）
#   —— 转台版 v66（未上板，只有构建签核；见 §1.1）
#   deliverables/data/v66/prod_timing.rpt         WNS +0.186 / WHS +0.043 / 0 失败 / 24,630 端点
#   deliverables/data/v66/prod_util.rpt           LUT 10,916 = 52.48% / BRAM 32/50
#   deliverables/data/v66/disp_timing.rpt         WNS +0.229 / WHS +0.024 / 0 失败 / 34,303 端点
#   deliverables/data/v66/disp_util.rpt           LUT 17,435 = 83.82% / BRAM 48/50
#   deliverables/data/v66/enc_top_v66.bit         1,524,668 B（SHA256 见 §1.1）
#   —— v70（v74 前身；生产已上板，见 §1.4；显示仅构建签核）
#   deliverables/data/v70/enc_top_v70.bit         1,517,496 B，BUILD 0x0015（SHA256 见 §1.4）
#   deliverables/data/v70/prod_timing.rpt         WNS +0.091 / WHS +0.065 / 0 失败 / 24,680 端点
#   deliverables/data/v70/prod_util.rpt           LUT 10,955 = 52.67% / BRAM 32/50
#   deliverables/data/v70/disp_timing.rpt         WNS +0.027 / WHS +0.057 / 0 失败 / 34,321 端点
#   deliverables/data/v70/disp_util.rpt           LUT 17,415 = 83.73% / BRAM 48/50
#   —— ★ 当前基线 v90（生产 + 显示均已上板，见 §1.7）
#   deliverables/data/v90/prod_timing.rpt         WNS +0.199 / WHS +0.017 / 0 失败 / 24,691 端点
#   deliverables/data/v90/prod_util.rpt           LUT 10,978 = 52.78% / BRAM 32/50 / DSP 17
#   deliverables/data/v90/disp_timing.rpt         WNS +0.221 / WHS +0.049 / 0 失败 / 33,365 端点
#   deliverables/data/v90/disp_util.rpt           LUT 17,090 = 82.16% / BRAM 45.5/50 / DSP 20
#   deliverables/data/v90/enc_top_v90.bit         1,504,220 B，BUILD 0x0019（SHA256 见 §1.7）
#   deliverables/data/v90/enc_top_disp_v90.bit    1,688,245 B（SHA256 见 §1.7）
```

### 0.1 校验交付件完整性

```powershell
cd deliverables/data
Get-Content SHA256SUMS.txt | ForEach-Object {
  $h,$f = $_ -split '  ',2
  $a = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
  "{0}  {1}" -f $(if($a -eq $h.ToLower()){'OK'}else{'FAIL'}), $f
}
```

---

## 1. 交付件本体（v62，2026-10-23）

| 产物 | 路径 | 大小 / 关键值 | 用途 |
|---|---|---|---|
| **交付位流** | [`data/v62/enc_top_v62.bit`](data/v62/enc_top_v62.bit) | **1,694,505 B**，SHA256 `EC0B383B6BC2068D0CDEC2F70B6DD58F2EDFF714B8A345B65912E43B96BE47EB`，@2026-10-23 10:18:42 | 板上跑的就是这一版 |
| 时序签核 | [`data/v62/impl_timing.rpt`](data/v62/impl_timing.rpt) | WNS **+0.471** / TNS 0.000 / 0 失败（33,255）；WHS **+0.042** / 0 失败；WPWS +0.264 | §4.2、§8 |
| 利用率 | [`data/v62/impl_util.rpt`](data/v62/impl_util.rpt) | LUT **17,059 = 82.01%**、FF 11,193、BRAM **46/50 = 92%**、DSP 18、IOB 107 | §4.2、摘要 |
| DRC | [`data/v62/impl_drc.rpt`](data/v62/impl_drc.rpt) | **97 checks / 0 Error**（REQP-1839/1840 各 20 条为采集 RAM 异步控制 Warning） | §4.2 |
| 引脚分配 | [`data/v62/impl_io.rpt`](data/v62/impl_io.rpt) | 107 个 I/O（含 13 根 eth 与全部屏/触摸引脚） | §5、§9 |
| 约束检查 | [`data/v62/impl_check_timing.rpt`](data/v62/impl_check_timing.rpt) | no_clock 0 / unconstrained 0 / loop 0；10 个 no_input_delay 均带 false_path | §4.2 脚注 |
| 最差路径 | [`data/v62/impl_top_paths.rpt`](data/v62/impl_top_paths.rpt)、[`impl_hold_paths.rpt`](data/v62/impl_hold_paths.rpt) | setup：`u_udp/ipck_r_reg[12]`（`clk_125_raw` 7.370 ns / 19 级）；hold：`u_cordic/z_p_reg[12][8]`（0.042 ns） | §4.2、§10 |
| 构建日志 | [`data/v62/impl.log`](data/v62/impl.log)、[`runner.log`](data/v62/runner.log) | 469,312 B / 4,630 B | 复现构建过程 |

源码版本：`git rev-parse HEAD` = **`6ac757f`**（2026-10-23 11:46:40，"v62 屏 + 以太网合并"）。
位流与源码的对应关系用**构建号**校验：读 `0x05F2/0x05F3` 应得 `0x000D`（`RTL_BUILD_ID`）；`POLE_BITS=6`（2500 线）。

---

## 1.1 转台适配本体（v66，2026-10-28 构建；**均未上板**）

| 产物 | 路径 | 大小 / 关键值 | 用途 |
|---|---|---|---|
| **生产位流** | [`data/v66/enc_top_v66.bit`](data/v66/enc_top_v66.bit) | **1,524,668 B**，SHA256 `322F1BE5EA49D30F0C20A8EBC388B9C5437B89740E8F9091ED3E11FC164A0102`，@11:07:30 | 转台用：无屏、无网络 |
| **显示位流** | [`data/v66/enc_top_disp_v66.bit`](data/v66/enc_top_disp_v66.bit) | **1,681,601 B**，SHA256 `E3BC3ED8D62AB916B35E8B7A8B6758E239718BDA2CDF7AED3BE1BD0D74E77E8F`，@11:37:10 | 调试用：带 5 页 UI + 千兆网 |
| 生产时序 | [`data/v66/prod_timing.rpt`](data/v66/prod_timing.rpt) | WNS **+0.186** / TNS 0.000 / **0 失败（24,630 端点）**；WHS **+0.043** / 0 失败；WPWS +0.264 | §4.2、§11.11 |
| 生产利用率 | [`data/v66/prod_util.rpt`](data/v66/prod_util.rpt) | LUT **10,916 = 52.48%**、FF 8,705 = 20.93%、BRAM **32/50**、DSP 17、IOB 63 | §4.2、摘要 |
| 生产 DRC | [`data/v66/prod_drc.rpt`](data/v66/prod_drc.rpt) | **0 Error** | §4.2 |
| 显示时序 | [`data/v66/disp_timing.rpt`](data/v66/disp_timing.rpt) | WNS **+0.229** / **0 失败（34,303）**；WHS **+0.024** / 0 失败 | §4.2、§11.11 |
| 显示利用率 | [`data/v66/disp_util.rpt`](data/v66/disp_util.rpt) | LUT **17,435 = 83.82%**、FF 11,535 = 27.73%、BRAM **48/50 = 96%**、DSP 19、IOB 107 | §4.2、§7 R12 |
| 显示 DRC / 约束 / IO | [`disp_drc.rpt`](data/v66/disp_drc.rpt)、[`disp_check_timing.rpt`](data/v66/disp_check_timing.rpt)、[`disp_io.rpt`](data/v66/disp_io.rpt) | 0 Error；约束检查与 107 个 I/O 分配 | §4.2、§5 |
| 最差路径 | [`prod_top_paths.rpt`](data/v66/prod_top_paths.rpt)、[`disp_top_paths.rpt`](data/v66/disp_top_paths.rpt)、[`disp_hold_paths.rpt`](data/v66/disp_hold_paths.rpt) | 见 §11.12 #3（v65 的 −1.197 事故路径） | §11.12 |
| 构建日志 | [`prod_impl.log`](data/v66/prod_impl.log)、[`disp_impl.log`](data/v66/disp_impl.log) | 270,666 B / 479,424 B | 复现构建 |
| 仿真回归 | [`../sim/logs/`](../sim/logs/) | **33/33 PASS**（2026-10-28 11:09:32；新增 `tb_lag_ff`/`tb_lock_sm`/`tb_bias_track`/`tb_angle_lut`） | §11.11 |
| 上板闸门 | [`../tools/final_verify.ps1`](../tools/final_verify.ps1) | 8 类检查；2026-10-28 实跑 **ALL CHECKS PASSED**（退出码 0） | §4.2、§11.11 |

源码版本：tag **`v66-pre-board`**（feat 提交 `eda62da` + docs 提交 `14b70dc`）。
位流与源码的对应关系用**构建号**校验：读 `0x05F2/0x05F3` 应得 **`0x000E`**（`RTL_BUILD_ID`）；`POLE_BITS=11`（2048 周期/转）。

> ⚠ 归档口径（与 `data/README.md` §2.0a 一致）：**生产位流当初没有跑 `check_timing` / `hold_paths` / `io` 三份报告**，
> 为不改变位流与哈希**没有重跑实现**，缺件如实登记在 `data/README.md` §2.0a 与 §5.9。

## 1.2 小信号传感器本体（v67，2026-10-29 构建；**未上板**）

适用硬件：手搓正交 sin/cos，200–300 mVpp、0 V 中心、64 电周期/机械圈；AD9238 前端方案 B（R13 短接 / R15 不焊 /
AD8138 `Rg` 499→120 Ω，4.16×）。与 v66 只差 4 处：`POLE_BITS 11→6`、`RTL_BUILD_ID 0x000E→0x000F`、
`GAIN_S/C 1.0→1.5`、ABZ `INTER0 2→32`（A 沿 4096/圈、2048 PPR）。

| 产物 | 路径 | 大小 / 关键值 | 用途 |
|---|---|---|---|
| **生产位流** | [`data/v67/enc_top_lowsig.bit`](data/v67/enc_top_lowsig.bit) | **1,504,428 B**，SHA256 `80842AC24266393B122A954B664509807B9FF35CCFF1A6AA23A6091EB3DED2AB`，@2026-10-29 10:36:27 | 小信号传感器用：无屏、无网络 |
| 时序 | [`data/v67/prod_timing.rpt`](data/v67/prod_timing.rpt) | WNS **+0.282** / TNS 0.000 / **0 失败（24,630 端点）**；WHS **+0.046** / 0 失败（24,165）；WPWS +0.264 | `docs/29` §5 |
| 利用率 | [`data/v67/prod_util.rpt`](data/v67/prod_util.rpt) | LUT **10,924 = 52.52%**、FF 8,705 = 20.93%、BRAM **32/50**、DSP 17、IOB 63 | `docs/29` §5 |
| DRC / 布线 | [`data/v67/prod_drc.rpt`](data/v67/prod_drc.rpt)、[`prod_route.rpt`](data/v67/prod_route.rpt) | **0 Errors / 0 Critical Warnings**；45 Warning（DPIP×12 / DPOP-1×16 / DPOP-2×17）；18,584/18,584 布通 | `docs/29` §5 |
| 最差路径 / 时钟 | [`prod_top_paths.rpt`](data/v67/prod_top_paths.rpt)、[`prod_clkint.rpt`](data/v67/prod_clkint.rpt) | 20 条 setup 路径明细；时钟交互 | `docs/29` §5 |
| 构建日志 | [`data/v67/prod_impl.log`](data/v67/prod_impl.log) | 276,516 B；停在 `Bitgen Completed Successfully`（Vivado 收尾挂起） | 复现构建 |
| 仿真 | [`data/v67/sim_tb_lowsig.log`](data/v67/sim_tb_lowsig.log) | **35 checks PASS**（200/250/300 mVpp、默认 1.5、标定、1.0 A/B） | `docs/29` §6 |
| 变体说明 | [`data/v67/VARIANT_INFO.txt`](data/v67/VARIANT_INFO.txt) | 源 git `b7d7f79`、25+8 文件、4 处补丁 | `docs/29` §4 |

校验：读 `0x05F2/0x05F3` 应得 **`0x000F`**；`0x0101` 应得 **32**；`0x0514/15` 默认 **49152**。
**不得**把 v67 与 v66 的显示位流混用；v67 没有显示版。位流长度算术：saved 5,502,336 bits ⇒
17,537,696−5,502,336=12,035,360 bit=1,504,420 B+8 B 头=1,504,428 B；偏移 260 处 `AA 99 55 66`。

> ⚠ 口径：v67 只有 `[构建签核]` + `[仿真]`，**没有上板实测**。`docs/29` §7 的上板步骤走完之前，
> 任何 `[实测]` 字样都不得出现在 v67 名下。

## 1.3 400 mVpp 单端正交 + 显示版（v68，2026-10-30 构建；**均未上板**）

适用硬件：手搓正交 sin/cos，**400 mVpp 单端、0 V 中心、64 电周期/机械圈**；AD9238 前端方案 B
（R13 短接 / R15 不焊 / AD8138 `Rg` 499→120 Ω，4.16×）。与 v66 只差 3 处：`POLE_BITS 11→6`、
`RTL_BUILD_ID 0x000E→0x0010`、ABZ `INTER0 2→32`（A 沿 4096/圈、2048 PPR）；`GAIN_S/C` 保持 **1.0**。
400 mVpp → 0.832 FS，落在默认窗 `[0.60,1.20]`；默认窗下限约 288 mVpp，上限 481 mVpp。

| 产物 | 路径 | 大小 / 关键值 | 用途 |
|---|---|---|---|
| **生产位流** | [`data/v68/enc_top_v68.bit`](data/v68/enc_top_v68.bit) | **1,511,380 B**，SHA256 `921FA2DCA4CB12BF17CC0CB4B4E2EDF4E6F6F1F21430A59801DF3C00784B1196`，@2026-10-30 17:24:49 | 无屏、无网络；BUILD_ID=`0x0010` |
| **显示位流** | [`data/v68/enc_top_disp_v68.bit`](data/v68/enc_top_disp_v68.bit) | **1,701,921 B**，SHA256 `86E6BAB445759A74A4E96A2032E2CE658903F6CC7B827C7B414514829059D753`，@17:46:33 | 编码器 + 7" LCD + 千兆网；顶层 `enc_top_disp`，带 `ENC_DISP_TAP` + `ENC_V68_CPR64`（RPM 按 64 周期/转换算） |
| 生产时序 | [`data/v68/prod_timing.rpt`](data/v68/prod_timing.rpt) | WNS **+0.144** / TNS 0.000 / **0 失败（24,648）**；WHS **+0.049** / 0 失败（24,183）；WPWS +0.264 | `docs/30` §4.1 |
| 显示时序 | [`data/v68/disp_timing.rpt`](data/v68/disp_timing.rpt) | WNS **+0.345** / TNS 0.000 / **0 失败（34,281）**；WHS **+0.047** / 0 失败（33,816）；WPWS +0.264 | `docs/30` §4.2 |
| 生产资源 | [`data/v68/prod_util.rpt`](data/v68/prod_util.rpt) | LUT **10,928 = 52.54%**、FF 8,714 = 20.95%、BRAM **32/50**、DSP 17、IOB 63 | `docs/30` §4.1 |
| 显示资源 | [`data/v68/disp_util.rpt`](data/v68/disp_util.rpt) | LUT **17,414 = 83.72%**、FF 11,528 = 27.71%、BRAM **48/50（96%）**、DSP 19、IOB 107 | `docs/30` §4.2 |
| 生产 DRC / 布线 | [`prod_drc.rpt`](data/v68/prod_drc.rpt)、[`prod_route.rpt`](data/v68/prod_route.rpt) | **0 Errors / 0 Critical**；45 Warning；18,578/18,578 布通 | `docs/30` §4.1 |
| 显示 DRC / 布线 | [`disp_drc.rpt`](data/v68/disp_drc.rpt)、[`disp_route.rpt`](data/v68/disp_route.rpt) | **0 Errors / 0 Critical**；99 checks；27,875/27,875 布通 | `docs/30` §4.2 |
| 显示 eth 时序 | [`disp_eth_rx_paths.rpt`](data/v68/disp_eth_rx_paths.rpt) | `eth_rxc` 组最差 slack **MET 1.907 ns** | `docs/30` §4.2 |
| IO / 约束 | [`prod_io.rpt`](data/v68/prod_io.rpt)、[`disp_io.rpt`](data/v68/disp_io.rpt)、[`prod_check_timing.rpt`](data/v68/prod_check_timing.rpt)、[`disp_check_timing.rpt`](data/v68/disp_check_timing.rpt) | 引脚/IO 标准；两边均 0 no_clock / 0 unconstrained endpoint | `docs/30` §4 |
| 构建日志 | [`prod_impl.log`](data/v68/prod_impl.log)、[`disp_impl.log`](data/v68/disp_impl.log) | 276,872 / 483,074 B；均停在 `Bitgen Completed Successfully`（Vivado 收尾挂起） | 复现构建 |
| 仿真 | [`data/v68/sim_tb_v68.log`](data/v68/sim_tb_v68.log) | **37 checks PASS**（400/450/350 mVpp、默认 1.0、标定、1.5 A/B） | `docs/30` §5 |
| 变体说明 | [`data/v68/VARIANT_INFO.txt`](data/v68/VARIANT_INFO.txt) | 源 git `086df12`、25+8 文件、3 处补丁 | `docs/30` §3 |

校验：读 `0x05F2/0x05F3` 应得 **`0x0010`**；`0x0101` 应得 **32**；`0x0514/15` 默认 **0x8000**。
生产版与显示版只差 `ENC_DISP_TAP` + `ENC_V68_CPR64`，**不能混用**。位流长度算术：
生产 saved 5,446,720 bits ⇒ 17,537,696−5,446,720=12,090,976 bit=1,511,372 B+8 B 头=1,511,380 B，偏移 260 处 `AA 99 55 66`；
显示 saved 3,922,432 bits ⇒ 17,537,696−3,922,432=13,615,264 bit=1,701,908 B+13 B 头=1,701,921 B（design 名长 5 字符），偏移 265 处同 sync word。

> ⚠ 口径：v68 只有 `[构建签核]` + `[仿真]`，**没有上板实测**。`docs/30` §6 的上板步骤走完之前，
> 任何 `[实测]` 字样都不得出现在 v68 名下。显示版 BRAM 已 96%，不要再加帧缓冲/页。

## 1.4 转台 2048 PPR + 位置计数/UVW 修复（v70，2026-11-01；**生产位流已上板验收**）

适用硬件：转台真实输出 **8 Vpp** 正交 sin/cos、**PPR = 2048**；AD9238 5:1 衰减（10 Vpp 满量程）。
与 v69 的差别不在配置，而在**两处 RTL 缺陷的修复**（详见 [`docs/33`](../docs/33_v70_release_report.md)）：
`pole_counter.v` 的相位差符号扩展（`cycle_cnt` 恒 0）、`uvw_gen.v` 反向 0→5 环绕边界（UVW 只有 3 扇区）；
另加 `dir_det` 最短有符号差、显示版 `DISP_CPR = 2048`（`ENC_V69_CPR2048`）。

| 产物 | 路径 | 大小 / 关键值 | 用途 |
|---|---|---|---|
| **生产位流** | [`data/v70/enc_top_v70.bit`](data/v70/enc_top_v70.bit) | **1,517,496 B**，SHA256 `48EACCFEFBEBC99EB90AA92C14C1A4B6B9177BB2D688FD8B0B258CC5111A8E94`，@2026-11-01 22:36:58 | 无屏；BUILD_ID=`0x0015`；**已上板验收** |
| **显示位流** | [`data/v70/enc_top_disp_v70.bit`](data/v70/enc_top_disp_v70.bit) | **1,708,301 B**，SHA256 `1081DCA7002B80A2C88CF82221D683DBE7A63757BDEF70D5E9AE3DE760563FBB`，@22:46:37 | 编码器 + 7" LCD + 千兆网；`ENC_DISP_TAP` + `ENC_V69_CPR2048`；**未上板目视** |
| 生产时序 | [`data/v70/prod_timing.rpt`](data/v70/prod_timing.rpt) | WNS **+0.091** / TNS 0.000 / **0 失败（24,680）**；WHS **+0.065** / 0 失败（24,215）；WPWS +0.264 | `docs/33` §4.1 |
| 显示时序 | [`data/v70/disp_timing.rpt`](data/v70/disp_timing.rpt) | WNS **+0.027** / TNS 0.000 / **0 失败（34,321）**；WHS **+0.057** / 0 失败（33,856）；WPWS +0.264 | `docs/33` §4.2 |
| 生产资源 | [`data/v70/prod_util.rpt`](data/v70/prod_util.rpt) | LUT **10,955 = 52.67%**、FF 8,722 = 20.97%、BRAM **32/50**、DSP 17、IOB 63 | `docs/33` §4.1 |
| 显示资源 | [`data/v70/disp_util.rpt`](data/v70/disp_util.rpt) | LUT **17,415 = 83.73%**、FF 11,544 = 27.75%、BRAM **48/50（96%）**、DSP 19、IOB 107 | `docs/33` §4.2 |
| 生产 DRC / 布线 | [`prod_drc.rpt`](data/v70/prod_drc.rpt)、[`prod_route.rpt`](data/v70/prod_route.rpt) | **0 Errors / 0 Critical**；45 Warning；18,654/18,654 布通 | `docs/33` §4.1 |
| 显示 DRC / 布线 | [`disp_drc.rpt`](data/v70/disp_drc.rpt)、[`disp_route.rpt`](data/v70/disp_route.rpt) | **0 Errors / 0 Critical**；99 checks；27,912/27,912 布通 | `docs/33` §4.2 |
| 显示 eth 时序 | [`disp_eth_rx_paths.rpt`](data/v70/disp_eth_rx_paths.rpt) | `eth_rxc` 组最差 slack **MET 1.907 ns** | `docs/33` §4.2 |
| IO / 约束 | [`prod_io.rpt`](data/v70/prod_io.rpt)、[`disp_io.rpt`](data/v70/disp_io.rpt)、[`prod_check_timing.rpt`](data/v70/prod_check_timing.rpt)、[`disp_check_timing.rpt`](data/v70/disp_check_timing.rpt) | 引脚/IO 标准；两边 0 no_clock / 0 unconstrained | `docs/33` §4 |
| 构建日志 | [`prod_impl.log`](data/v70/prod_impl.log)、[`disp_impl.log`](data/v70/disp_impl.log) | 均到 `Bitgen Completed Successfully`（Vivado 2026.1 收尾不退出，外部终止） | 复现构建 |
| 变体说明 | [`data/v70/VARIANT_INFO.txt`](data/v70/VARIANT_INFO.txt) | 源 git `657836a`；3 条生成器补丁 + 3 个源文件修复 | `docs/33` §10 |

上板实测（生产位流，`V70D PROGRAMMED_OK` @22:41:20，`_boardtest/check_v70.py` / `diag_pos3.py` / `soak_v68.py`）：
`RTL_BUILD=0x0015`、`INTER0=32`、**Z 12.00 Hz**、`cnt −2047..0 distinct=2048`、
UVW 六态均匀（293 换向/秒）、`0x0500&0xFF=27`、`0x0501&0xFF=5`、标定 `33,776/33,568`、
ping 5/5 + UDP 28,672 点、60 s 长跑 598,115 帧（r 漂移 <0.02%）。

> ⚠ 口径：v70 的**生产位流**是 `[实测]`（板上跑过、数据见 `docs/32` §6 与 `docs/33` §5）；
> **显示位流**只有 `[构建签核]`，屏上 RPM/触摸尚未目视。Flash 固化仍未做。

---


| 数字 | 值 | 产物 / 命令 | 类别 |
|---|---|---|---|
| 角度分辨率 | 16 bit（0.0055°/LSB） | `0x0500` 读回 + `model/golden_model.py` | `[实测]`+`[仿真]` |
| 复合畸变抑制 | 20.9839° → 0.0165°（**1273×**） | `model/golden_model.py`（A–G 误差表） | `[仿真]` |
| CORDIC 最坏误差 | 0.9375 LSB = 0.005150° | `model/cordic_model.py` | `[仿真]` |
| 环路稳定性 | `kp=0…7 × ki=1…3` 共 21 组全稳定 | `model/loop_filter_model.py` | `[仿真]` |
| ABZ/UVW 逻辑 | 6/6 PASS | `model/abz_uvw_model.py` | `[仿真]` |
| 带宽约束 | `4 × inter × f_in ≤ 12.5 MHz`；板上 0.606×（丢 39.4%）判决演示 | `docs/DEV_STATUS.md` U-33 段 + §6.3 频段表 | `[实测]` |

---

## 1.5 Z 索引脉冲修复（v71，2026-11-02 构建；**未上板**）

**结论口径**：v71 = v70 + Z 修复。全量审计（[`docs/34_audit_report.md`](../docs/34_audit_report.md)）发现
**B1：Z 索引脉冲在当前 RTL 上根本不出**，v71 修好并重建两个位流；**板卡已断开，未上板**，
因此本节只有 **`[构建签核]` + `[仿真]`** 两级，**没有任何 `[实测]` 数字**。

| 项 | 生产 `enc_top_v71.bit` | 显示 `enc_top_disp_v71.bit` | 出处 |
|---|---|---|---|
| 大小 / SHA256 | **1,514,668 B** / `456279CD82778F9D0234784284C04402F6377C85993B9660AE599B918741DB28` | **1,657,221 B** / `776438A7E27D9B6918AD777E9110F969051D778AE9DC25786642F8762C88A025` | [`data/v71/SHA256SUMS.txt`](data/v71/SHA256SUMS.txt) |
| BUILD_ID | `0x0016` | 同左 | `_synth_work_v71/rtl_v71/enc_top.v` |
| WNS / TNS / 失败端点 | **+0.277 ns** / 0.000 / **0**（24,785） | **+0.143 ns** / 0.000 / **0**（34,383） | [`data/v71/prod_timing.rpt`](data/v71/prod_timing.rpt)、`disp_timing.rpt` |
| WHS / WPWS | +0.047（0 失败）/ +0.264 | +0.019（0 失败）/ +0.264 | 同上 |
| 资源 | LUT **10,968 / 20,800 = 52.73%**、FF 8,756 = 21.05%、BRAM 32/50 = 64% | LUT **17,393 = 83.62%**、FF 11,557 = 27.78%、BRAM **48/50 = 96%**、DSP 19、IOB 107 | `prod_util.rpt`、`disp_util.rpt` |
| 以太网 RXC 路径 | — | slack **+1.907 ns（MET）** | [`data/v71/disp_eth_rx_paths.rpt`](data/v71/disp_eth_rx_paths.rpt) |
| 仿真回归 | **36 / 36 PASS** | 同左 | `sim/logs/SUMMARY.md`（2026-11-02） |
| Z 专项 | `tb_enc_top` **106 checks / 0 error**：`FWD: Z_pulses=1, Z_width_max=2569 clk`、`REV: Z_pulses=1` | 同左 | `sim/tb_enc_top.v` 输出 / [`docs/34_audit_report.md`](../docs/34_audit_report.md) §3 A6 |

**缺陷与修法（三处，全部在源码 `rtl/`）**：

1. `rtl/enc_top.v`：`z_window` 由 `cycle_cnt[POLE_BITS-1:0]==0` 改为**绝对角度过零**判据
   （`z_ang_prev` + `ZW_TOP=7/8 圈`/`ZW_LOW=1/8 圈` ⇒ `ang_wrap_f/b`），
   用自由圈计数 `rev_cnt`（**不在 Z 处清零**）做"每圈一次"仲裁，再由 `Z_WIN_CLKS=6` 展宽。
2. `rtl/abz_gen.v`：`r_z_prev_hi` 始终跟随 `z_ph_hi`；新增跨零挂起令牌 `r_pend_ttl`(8)；
   `z_xing` 按方向选边沿（只认 hi→lo 会让反向完全无 Z）。
3. `rtl/enc_top.v`：`.clr_on_z(1'b1)` → **`1'b0`**（清零会让 `mech_angle` 跳变、UVW 误报频率越限，
   也破坏多圈计数）。

**根因一句话**：`pole_counter` 的 `phase_acc` 是"从复位时刻开始累加"的展开相位，**其回绕点对应复位
瞬间的绝对角度（实测 343°，打印 `evt=1 cnt=64 ang=62466`）**，与 ABZ 的 `z_phase=0` 跨零永久错位；
v68 之所以"看起来有 Z"，是因为那时 `cycle_cnt` 卡 0 ⇒ `z_window≡1`，Z 实际变成"每个电周期都出"。

**接板后要补的 `[实测]`**：`RTL_BUILD=0x0016`、电周期速率 ≈ ±24.7k、Z 率 ≈ 12 Hz、UVW 六态、
示波器 Z 每圈 1 个（宽度 ≈ 5 个 A 边沿）、屏上 RPM ≈ 720。

**2026-11-02 已补实测（见 §1.6）**：v71 生产位流上板全项通过（`RTL_BUILD=0x0016`、8673 Hz 基波、
标定、角度 RMS 0.72°、60 s 长跑 `|err|>5°`=0、以太网 ping+capture PASS）；Z 用 v73 的计数器量到 12.00 Hz → 720 rpm。

---

## 1.6 上板调试版 v72 / v73（2026-11-02；**生产 + 显示均已上板，显示已固化 Flash**）

**结论口径**：v73 = v71 + ① 显示 RPM 除零修复（`disp/val_format.v` 除数 16→20 位）② Z 上升沿计数探针
（只读 `0x054A..0x054D`）。这一节是**唯一同时具备 `[构建签核] + [上板实测] + [冷启动]` 的版本**。

| 项 | 结果 | 出处 |
|---|---|---|
| 生产位流 | `_impl_v73/enc_top_v73.bit` · 1,489,772 B · SHA `2E081D4E…9F31F4` · 11:37:09 | [`data/v73/`](data/v73/) |
| 显示位流 | `_impl_disp_v73/enc_top_disp_v73.bit` · 1,662,197 B · SHA `0567A4E6…6954C0` · 11:48:40 | 同上 |
| 时序 / 资源 | 生产 `WNS +0.220 / 0 失败(24,889)`、LUT 52.92%；显示 `WNS +0.328 / 0 失败(34,499)`、LUT 84.05%、BRAM 48/50 | `data/v73/prod_timing.rpt`、`disp_timing.rpt` |
| Z 计数（`0x054A..054D`） | **12.00 Hz → 720.0 rpm**、11.91 Hz → 714.7 rpm、12.26 Hz → 735.3 rpm ⇒ 每转 1 个 | `_boardtest/z_rate.py` 输出（§36 文档 §5） |
| Z 波形（示波器 J5-7/M21） | ≈**1.15 µs** 宽、≈**2.5 V** 窄脉冲、频率档 `<10 Hz`（即 12 Hz） | 用户现场截屏，记述于 [`docs/36`](../docs/36_v72_v73_board_debug.md) |
| 显示 RPM | v71 屏显 **496729.5** → v72/v73 屏显 **≈770–780**；同时刻 `diag_pos3` 实测 **775.6 rpm** | `docs/36` §3 |
| Flash + 冷启动 | `tools/program_flash.tcl` ⇒ `FLASHPROG FLASH_OK`；断电 3 s 上电：屏正常、`RTL_BUILD=0x0017`、Z 12.26 Hz、10.9 kfps | `docs/36` §6 |
| 回归 | 全量 xsim **36/36 PASS**（含 `tb_enc_top`、`tb_lag_ff_sat`、`tb_uvw_gen`）；`tb_enc_top` 106 checks（加计数器后仍 PASS） | `sim/logs/SUMMARY.md` |
| UVW 相序/间隔 | `_boardtest/uvw_phase.py`：六态均匀、无 `000/111`、占空比 0.501/0.487/0.499、间隔中位 **3210 µs**（理论 3243 µs）、相序 **922 forward / 0 backward** | `docs/36` §8.1 |

**未覆盖**（诚实边界）：Z 停位喘振（B8，**已在 v90 的 `z_index_gen` 修掉，见 §1.7**）、
2 h 长跑（`_boardtest/soak_v68.py COM7 7200` 进行中，结果回填到 `docs/36` §8）。

---

## 1.7 当前基线 v90（2026-11-04；**生产 + 显示均已上板，显示已固化 Flash**）

**结论口径**：v90 = v74 + `z_index_gen`（Z 索引发生器，治停位 Z 喘振）+ 界面收口（删 P7 标定整页与 P1 标定按钮，
标定走 KEY0 长按或串口写 `0x0502=0x0001`；P2 加预触发环形缓冲/中线/AUTO 时基）。**这是本表唯一的现行口径。**

| 项 | 生产位流 | 显示位流 |
|---|---|---|
| 文件 | [`data/v90/enc_top_v90.bit`](data/v90/enc_top_v90.bit) | [`data/v90/enc_top_disp_v90.bit`](data/v90/enc_top_disp_v90.bit) |
| 大小 | **1,504,220 B** | **1,688,245 B** |
| SHA256 | `A89512A506F9DE366863AC0C6BE2F740E453B32C35C6864D0D256D9C8F827125` | `69FE313C45C3F36D39307CE0948C6D0AB191183397E2408E694588FC5F81BAD4` |
| `RTL_BUILD_ID` | **0x0019** | **0x0019** |
| WNS / TNS / 失败端点 | **+0.199 ns / 0 / 0**（24,691 端点） | **+0.221 ns / 0 / 0**（33,365 端点） |
| WHS / WPWS | +0.017 / +0.264 | +0.049 / +0.264 |
| LUT / FF | **10,978 = 52.78%** / 8,724 = 20.97% | **17,090 = 82.16%** / 11,601 |
| BRAM / DSP / IOB | **32/50** / **17** / 60 | **45.5/50 = 91%** / 20 / 104 |
| 构建脚本 | `tools/impl_check_v90.tcl` | `tools/impl_check_disp_v90.tcl` |
| 报告产物 | `data/v90/prod_{timing,util,drc,io,clkint,check_timing,top_paths,hold_paths,route}.rpt` + `prod_impl.log` | `data/v90/disp_*`（同名 10 份） |

**板级实测（2026-11-04，判据 [`docs/39`](../docs/39_acceptance_criteria_v90.md)）**

| 判据 | 结果 | 产物 |
|---|---|---|
| 构建号 / 器件 / 版本 | `0x05F2 = 0x0019`、DEVICE_ID `0x000C`、REV `0x0010` | `_boardtest/check_v70.py`（末行 `PASS`） |
| 转速（权威） | Z 频率 **7.62 / 7.65 Hz ⇒ 457–459 rpm**（每转 1 个 Z） | `_boardtest/z_rate.py` |
| ⚠ 混叠伪值 | `check_v70.py` 的"机械转速"栏由 `cycle_cnt` 步进推出，10 kHz 遥测对 >10 kHz 电信号会混叠，**曾显示 621 rpm，不得引用** | `docs/39` §7 |
| UVW 六态 | `{5174, 4761, 4423, 4776, 4763, 4786}`，无 `000/111` | `_boardtest/uvw_phase.py`、`docs/39` §3 |
| 锁定 | `0x0130 = 0x0301`（TRACK） | `check_v70.py` |
| 幅值 | r 峰 **0.845–0.850 FS**、`stat_otr` 偶发不判 FAIL | `docs/39` §3 C1 |
| 帧率 | 10.6 kfps（短窗）；60 s 长跑 **597,886 帧 / 9,964.8 fps** 不丢 | `_boardtest/soak_v68.py`（60 s 长跑）、`docs/39` §4 |
| 角度内部一致性 | `angle_vs_sc`：offset **1.76°** / RMS **0.71°** / max **2.88°** / \|err\|>5° **0.03%**（**无外部基准**） | `_boardtest/angle_vs_sc.py`、`docs/39` §5 |
| 以太网 | ping **4/4**、UDP 抓窗 **28,672 点 @50 MSPS** | `tools/board_eth_check.py`、`host/panel_capture.py` |
| Flash + 冷启动 | 写的是显示位流，`FLASHPROG FLASH_OK`；断电重上电冷启动通过 | `_flash2_work/prog_flash_v90.log`、`docs/39` §6 |
| 仿真回归 | `sim/` **37/37 PASS**、`disp/` **20/20 PASS** | `sim/logs/SUMMARY.md`、`disp/logs/SUMMARY.md` |
| 证据完整性 | `data/SHA256SUMS.txt` **323 条** | §0.1 校验脚本 |

**RTL 相对 v74 的改动**（其余保持一致）：
1. `rtl/abz_gen.v` 新增 `z_index_gen`：`Z_ARM_DIST = 1<<(AW-3)`（45° 布防窗），出 Z 后撤防、离开 ≥1/8 圈重新布防；
   `rtl/enc_top.v` 内联 Z 段改为例化它 —— **停位不再吐多个 Z**。
2. `rtl/uvw_gen.v` **保持 v74 板级验证版**（`e_uw`/K=4 去抖版在板上冻结、已回退，不要再合）。

---

## 3. 报告 §4（RTL 与实现）

| 数字 | 值 | 产物 | 类别 |
|---|---|---|---|
| **v90 生产时序** | WNS **+0.199** / WHS +0.017 / TNS 0 / **0 失败**（24,691 端点） | [`data/v90/prod_timing.rpt`](data/v90/prod_timing.rpt) | `[构建签核]` |
| **v90 生产资源** | LUT **10,978 = 52.78%** / BRAM **32/50** / DSP 17 / FF 8,724 | [`data/v90/prod_util.rpt`](data/v90/prod_util.rpt) | `[构建签核]` |
| **v90 显示时序/资源** | WNS **+0.221** / 0 失败（33,365 端点）；LUT **17,090 = 82.16%** / BRAM 45.5/50 / DSP 20 | [`data/v90/disp_timing.rpt`](data/v90/disp_timing.rpt)、[`data/v90/disp_util.rpt`](data/v90/disp_util.rpt) | `[构建签核]` |
| 交付时序（历史 v62） | WNS +0.471 / WHS +0.042 / 0 失败 | `data/v62/impl_timing.rpt` | `[实测]` |
| 交付资源（历史 v62） | LUT 82.01% / BRAM 46/50 / FF 26.91% / DSP 18 / IOB 107 | `data/v62/impl_util.rpt` | `[实测]` |
| DRC | 0 Error / 97 Warning | `data/v62/impl_drc.rpt` | `[实测]` |
| 编码器单机（历史基线 v12） | 6,298 LUT = 30.28% / WNS +0.959 / 位流 1,042,208 B | [`data/timing/impl_timing.rpt`](data/timing/impl_timing.rpt) + [`data/timing/impl_util.rpt`](data/timing/impl_util.rpt) + [`data/bitstreams/enc_top_v12_prod.bit`](data/bitstreams/enc_top_v12_prod.bit) | `[实测]` |
| 纯屏版（历史 v59） | 14,263 LUT = 68.57% / BRAM 48.5 / WNS +0.586 / 1,732,625 B | `_impl_v58/impl_util.rpt`（工作副本，**未入 data/**） | `[实测]` |
| 测试台规模 | `sim/` **37 台** + `disp/` **20 台** = **57 台** | `sim/tb_*.v`、`disp/tb_*.v` | `[仿真]` |
| 回归结果 | **37/37 PASS**（v90 轮，2026-11-04）；disp 20/20。历史：v74 轮 36/36（2026-11-02）、v66 轮 33/33（2026-10-28 11:09:32，`tb_enc_top` 238 s）、v62 轮 29/29（2026-10-23 10:54:33，191 s） | [`sim/logs/`](../sim/logs/)（逐台 `*.log` 与 `SUMMARY.md` 由 `tools/run_sim.ps1` 本地生成，不入库；入库的是 `_run_console*.txt`） | `[仿真]` |
| 静态检查 | ERROR 0 / WARNING 0 | `tools/lint_all.ps1 -Clean` | `[仿真]` |

---

## 4. 报告 §5（硬件）

| 数字 | 值 | 产物 | 类别 |
|---|---|---|---|
| 器件 | XC7A35TFGG484-2（达芬奇-lite） | `constr/enc_top_disp.xdc` 器件行 | `[手册]` |
| ADC | HSEDA AD9238 双通道 12 bit / 50 MSPS | `docs/AD9238_module_digest.md` | `[手册]` |
| ADC 传播延迟 | `tPD_meas = 3–4 ns`（手册 2–6 ns） | `docs/DEV_STATUS.md` §9 示波器段 | `[实测]` |
| 引脚校验 | 107 个 I/O，0 冲突 | `python tools/pinout_verify.py`、`data/v62/impl_io.rpt` | `[实测]` |

---

## 5. 报告 §6（板级测量）

### 5.1 标定（§6.1–§6.2）

| 数字 | 值 | 产物 | 类别 |
|---|---|---|---|
| 一键标定重复性 | **20 轮 20/20**（`retry`/`win_bad` 全 0） | [`data/calib_repeat_summary.csv`](data/calib_repeat_summary.csv) | `[实测]` |
| AB 边沿膨胀 | 2.7× → 1.0×（已做成复位默认） | `docs/DEV_STATUS.md` U-20 段 | `[实测]` |
| 板级角度残差（历史 v7） | 0.009° RMS | v7 自由运行窗（旧口径，勿当现行指标） | `[实测]` |
| **板级角度内部一致性（v90）** | `angle_vs_sc`：offset **1.76°** / RMS **0.71°** / max **2.88°** / \|err\|>5° **0.03%**（**与指令角对比，无外部基准**） | `_boardtest/angle_vs_sc.py`、[`docs/39`](../docs/39_acceptance_criteria_v90.md) §5、[`data/v90/`](data/v90/) | `[实测]` |

### 5.2 频率扫描（§6.3，2026-10-13，`inter=32`）

| 输入频率 | 帧数 | 圆度 RMS | 半径均值 | CRC 错 | 产物 |
|---|---|---|---|---|---|
| 1 kHz | 149,363 | 0.101% | 26,214 | 571 | [`data/freq_1k.csv`](data/freq_1k.csv) |
| 10 kHz | 149,416 | 0.125% | 26,215 | 500 | [`data/freq_10k.csv`](data/freq_10k.csv) |
| 50 kHz | 149,356 | 0.116% | 26,210 | 562 | [`data/freq_50k.csv`](data/freq_50k.csv) |
| 100 kHz | 149,381 | 0.093% | 26,197 | 539 | [`data/freq_100k.csv`](data/freq_100k.csv) |
| 200 kHz | 149,356 | 0.143% | 26,201 | 589 | [`data/freq_200k.csv`](data/freq_200k.csv) |
| 500 kHz | 149,380 | 0.211% | 26,117 | 545 | [`data/freq_500k.csv`](data/freq_500k.csv) |

汇总：[`data/freq_ladder_summary.csv`](data/freq_ladder_summary.csv)（6 点 + `status` 位域）、
[`data/freq_robust_summary.csv`](data/freq_robust_summary.csv)（每点 15,000 帧的 median/min/max/`bad_frames`，
仅 500 kHz 有 1 个坏帧）。图：[`figures/freq_{1k,10k,50k,100k,200k,500k}.png`](figures/)。

**延迟**：`freq_ladder_summary.csv` 的 `lag_deg` 列为空 ⇒ **延迟未实测**，`≈830 ns` 是 §4.3 预算（`[设计值]`）。
这一项在报告里被显式标为待办（§7 R6），没有隐藏。

### 5.3 李萨如（§6.4）

| 指标 | 标定前 | 标定后 | 产物 |
|---|---|---|---|
| 圆度 RMS | **17.786%** | **0.101%**（≈176×） | [`data/lissajous_summary.csv`](data/lissajous_summary.csv) |
| 半径 min/max | 17,594.5 / 33,496.6 | 26,094.1 / 26,318.1 | 同上 |
| 注入参数 | `--offset 3000 --offset-c -3000 --gain-mismatch 1.25 --quad-deg 3` | — | 复测 17.795→0.102、17.852→0.146 |

波形：[`data/lissajous_{before,after}{,_distortion}.csv`](data/)（4 份，各约 4 MB）；
图：[`figures/lissajous_{before,after}{,_distortion}.png`](figures/)（4 张）。

### 5.4 通信与连续流（§6.6、§10.6.4）

| 数字 | 值 | 产物 | 类别 |
|---|---|---|---|
| 串口抓包 | 28,672 点 / 25.000 MSPS / 1.147 ms | [`data/logs/capture_v11_summary.txt`](data/logs/capture_v11_summary.txt) + `host/capture.py` | `[实测]` |
| 串口 dump | 448 块 / 0.65 s | 同上 | `[实测]` |
| UDP 抓包 | 82/82 包 / missing 0 / **0.06 s** | `host/panel_capture.py` + ILA 抓包 | `[实测]` |
| 连续流 10 min | 37,501,126 包 / **99.89%** | [`../docs/24_board_acceptance_morning.md`](../docs/24_board_acceptance_morning.md) §10 | `[实测]` |
| 连续流 30 min（dec=3） | 56,251,240 包 / **99.74%** / drop 0.0002% | 同上 | `[实测]` |
| ping | 4/4（停流时 20/20、dec=3 时 17/20） | `tools/board_eth_check.py` | `[实测]` |

---

## 6. 报告 §7（风险）对应的证据

| 风险 | 证据状态 |
|---|---|
| R1 ADC 输入约束 | `data/v62/impl_timing.rpt` + `impl_check_timing.rpt`（10 个 input_delay 均带 false_path） |
| R2 坏样本 | `data/ila/`（v9 逐拍抓包 21 份 + v11 对照 `data/ila/ila_cmp_v11_clean.csv`）+ `docs/DEV_STATUS.md` §9 |
| R5 Z 脉宽 | ILA 抓包有；示波器游标图**缺**（10-29 补） |
| R6 延迟 | **无**（见 §5.2 末） |
| R7 真实传感头 | 2048 周期/转磁环已在真机跑闭环（§1.7：457–459 rpm / 1 Z 每转 / 60 s 不丢帧）；**异型号与异极对数通用性无证据** |
| R12 资源见底 | v62：`data/v62/impl_util.rpt`（BRAM 46/50）；**v90：生产 10,978 LUT = 52.78% / 32 BRAM（余 18 块）、显示 17,090 = 82.16% / BRAM 45.5/50 = 91% / WNS +0.221** |
| R13 屏逐页目视 | **已通过（2026-11-04）**：P1/P2/P4/P6 逐页人工核对通过（P1 四卡数值/单位不重叠且 `Z计数` 递增；P2 三档 + `AUTO` 波形左右连续、标记在中线；P4 上半 A/B 各 4 周期、下半 U/V/W 60° 台阶 + Z 竖标；P6 参数与 `S0C0` 回读一致；裸指触摸与 KEY1 翻页正常，P7 页确认不存在）；P1 同框照 `submission/photos/04_board_screen.jpg`，其余页屏摄由队伍留存；记录见 `board_day_checklist.md` §1、`docs/39` §5 |
| R14 显示位流目视 | **v90 生产与显示位流均已上板**（2026-11-04）：显示位流已写 Flash、冷启动通过；`enc_top_disp_v90.bit`（1,688,245 B / WNS +0.221）；**P1/P2/P4/P6 逐页目视已通过（2026-11-04）**，checklist 见 `board_day_checklist.md` §1 |
| R15 无 ±0.5″ 基准 | `../host/lut_tool.py` 与 `0x0141..0x0147` 证明"表可写可回读"；**外部基准：无** ⇒ 默认 `0x0145=0` |
| R16 Z 输入未实现 | 只有内部虚拟 Z；**无真实 Z 引脚**（方案见 `../docs/27_turntable_requirements_feasibility.md` §14.2） |
| R17 以太网 | 4 条 P0 修复已在 RTL（`../rtl/eth/eth_top.v:537`、`../rtl/eth/rgmii_if.v:215` 等）；**v90 上板 ping 4/4 + UDP 抓窗 28,672 点通过**；**30 min 连续流未复验**（v62 期数据见 §5.4） |

---

## 7. 报告 §9（屏上 UI）与 §10（以太网）

| 数字 | 值 | 产物 | 类别 |
|---|---|---|---|
| UI 页数 | **4 页**：P1 总览 / P2 输入波形 / P4 逻辑时序 / P6 设置（v58 删 P3/P5/P8，**v88/v90 删 P7 标定整页**，P1 标题带「标定」按钮改为直接写 `0x0502=0x0001`） | `disp/disp_engine.v:61` 页常量、`disp/enc_top_disp.v:762` 翻页链 | `[仿真]` |
| 分辨率 | 1024×600，零帧缓冲（帧缓冲需 9.83 Mbit，片上 1.8 Mbit） | `disp/` + `../docs/13_display_ui_requirements.md` | `[设计]` |
| 版面预览 | `_preview/page_p{1,2,4,6}.png`（几何读 RTL 常量） | `tools/preview_pages.py` | `[仿真]` |
| 触摸命中 | 27 个边界点 PASS | `disp/tb_hit_test_v58.v` | `[仿真]` |
| 以太网 RTL | 8 模块 + `tb_eth_udp` 58 checks / `tb_icmp_reply` 48 / `tb_stream_tx` 260 | `sim/tb_*.v` | `[仿真]` |
| 合并 XDC | 107 球 0 冲突 | `tools/gen_merged_xdc.py` + `constr/enc_top_eth.xdc` | `[仿真]` |
| 上板验收 | ping/UDP/串口/连续流/GUI 浸泡 | `docs/24_board_acceptance_morning.md` §10 | `[实测]` |

### 7.1 报告 §11（转台适配 v63–v90，v90 为当前）

| 数字 / 结论 | 值 | 产物 | 类别 |
|---|---|---|---|
| 需求基线 | 2048 周期/转、每腿 0.5 Vpp、G=8→8 Vpp、1638 码、200 kHz（5859 rpm）、±1″ | [`../docs/27`](../docs/27_turntable_requirements_feasibility.md) §0.5/§12.1 + `../improvement_requirements.docx` | `[需求]` |
| 1″ 的量化 | 1″ 机械 = 0.568° 电角 = **≈103 LSB**（0.0097″/LSB） | 同上 §0.5 | `[设计值]` |
| 延迟造成的误差 | 3000 rpm、T=0.72 µs ⇒ **26.5° 电角 ≈ 46″** | `rtl/lag_ff.v` 头注释 + §11.3 | `[设计值]` |
| 前馈默认值 | `TAU_Q8=2304`（9 抽样点 = 720 ns）、`0x0122` bit0=1 | `rtl/reg_file.v`、`rtl/lag_ff.v` | `[设计值]` |
| 锁定门限 | 12,500 / 2,500 / 12,500 样本 | `rtl/lock_sm.v` | `[设计值]` |
| 偏置跟踪 | 窗口 32,768 样本（2.62 ms）、±8191 LSB、默认关 | `rtl/bias_track.v` | `[设计值]` |
| 全周表 | 4096×16、2 BRAM36、1 LSB=0.0097″、量程 ±0.088°、默认旁路 | `rtl/angle_lut.v` + `host/lut_tool.py` | `[设计值]` |
| 新增寄存器 | 0x0120–0x0147（16 组） | `rtl/reg_file.v` + `host/regs.py`（`--selftest` 51 项） | `[仿真]` |
| 四台新 tb | `tb_lag_ff` 7 项 / `tb_lock_sm` 8 组 / `tb_bias_track` 12 项 / `tb_angle_lut` 4,108 checks | `sim/tb_*.v` + `../sim/logs/SUMMARY.md`（33/33） | `[仿真]` |
| 全链路回归 | `tb_enc_top` 106 checks，max_dev **10 LSB16**，UVW 24 次跳变、`warn_hi=0` | `sim/logs/SUMMARY.md` | `[仿真]` |
| 两个位流 | 见 §1.1（构建签核） | `data/v66/` | `[构建签核]` |
| **v74 生产位流（历史）** | 1,512,664 B / LUT **52.5%** / BRAM 32/50 / WNS +0.4 ns 档（构建号见 §8，旧号不再引用） | `_impl_v74/` | `[实测]` |
| **v74 板级复验（历史）** | 转台 2048 ppr、Z ≈12 Hz 档、UVW 六态均衡、以太网 ping + UDP 抓窗通过（v70 期：Z 12.00 Hz / 60 s 598,115 帧） | `_boardtest/check_v70.py`、`diag_pos3.py`、`soak_v68.py` | `[实测]` |
| **v74 显示位流（历史）** | 1,700,821 B / WNS **+0.422** / LUT **17,604 = 84.63%** / BRAM 48/50 / DSP 22（已归档 `data/v74/`；未目视验收，后被 v85 取代） | [`data/v74/enc_top_disp_v74.bit`](data/v74/enc_top_disp_v74.bit) | `[构建签核]` |
| **v90 生产位流（当前）** | **1,504,220 B** / `BUILD 0x0019` / WNS **+0.199** / LUT **10,978 = 52.78%** / BRAM 32/50 / DSP 17 | [`data/v90/`](data/v90/)、§1.7 | `[实测]` |
| **v90 板级复验（当前）** | Z **7.62 / 7.65 Hz ⇒ 457–459 rpm**（每转 1 个 Z）、UVW 六态 `{5174,4761,4423,4776,4763,4786}`、`lock 0x0301`、60 s **597,886 帧 / 9,964.8 fps**、`angle_vs_sc` 1.76°/0.71°/2.88°、ping 4/4 + UDP 28,672 点 | `_boardtest/{z_rate,angle_vs_sc,check_v70}.py`、[`docs/39`](../docs/39_acceptance_criteria_v90.md) | `[实测]` |
| **v90 显示位流（当前）** | **1,688,245 B** / WNS **+0.221** / LUT **17,090 = 82.16%** / BRAM 45.5/50 / DSP 20；**已写 Flash、冷启动通过** | [`data/v90/enc_top_disp_v90.bit`](data/v90/enc_top_disp_v90.bit) | `[实测]`（`[构建签核]` + 上板冷启动） |
| **v70 两个死锁** | `step_s` 符号扩展（−65,403 而非 +133）、`off_bwd` 0→5 环绕；tb_acc2 3,000×133 ⇒ 6 圈、tb_uvw_rev 50 次六态 | `docs/33` §1–§2；`_boardtest/tb_acc2.v`、`_boardtest/tb_uvw_rev.v`；`pole_counter.v`、`uvw_gen.v` | `[仿真]` |
| **上板** | v62 生产 / 显示均上板（10-23）；v70 生产上板（11-01）；v74 生产上板（11-02）；**v90 生产 + 显示均上板（11-04），显示已固化 Flash**；v66、v67、v68 两版均未上板 | `docs/32`、`docs/33` §5、`docs/39` | — |

---

## 8. 版本沿革（历史，仅供"为什么是现在这样"）

| 版本 | 日期 | 关键数字 | 说明 |
|---|---|---|---|
| v6 | 10-08 | 6,010 LUT / WNS −3.352 | 早期；`docs/02_innovation_scoring.md` 里的数字属此版，**不要引** |
| v9 | 10-10 | LUT 30.58% / WNS −3.274（ADC 约束口径） | 首次把负余量归因到约束 |
| v11 | 10-12 | WNS **+0.821** / 11,310 端点 | 去 `-invert` + 改 14.000/9.500，首次全绿 |
| v12 | 10-12 | WNS **+0.959** / 6,298 LUT / 位流 1,042,208 B | 编码器单机生产基线 |
| v57 | 10-19 | LUT 16,564 / BRAM 49.5 / WNS −1.295 | 8 页 UI，人工确认可用 |
| v58/v59 | 10-22 | 5 页；14,263 LUT = 68.57% / WNS +0.586 | 页数收敛 |
| v60/v61 | 10-22 | 16,518 LUT / WNS +0.203；v61 +0.037 | 屏 + 网合并 |
| **v62** | **10-23** | **17,059 LUT = 82.01% / WNS +0.471 / 46 BRAM** | **交付位流（已上板验收）** |
| v63 | 10-27 | S1 参数化：`POLE_BITS` 6→11（2048 周期/转）、ABZ `inter=2`；以太网 4 条 P0 + 上位机 8 条 + UVW 错拍 | 上板前质量整治（§11.9） |
| v64 | 10-28 | 加 `lag_ff`/`lock_sm`/`bias_track`/`angle_lut` 四模块与 0x0120–0x0147；LUT 约 50.7%（v66 比它多 1.8 个点、2 块 BRAM，见 `docs/27` §16.11） | 转台四模块首版（偏置用 EMA、ABZ 吃 `angle_rep`——两个隐患在此埋下） |
| v65 | 10-28 | **WNS −1.197**（0 失败端点不成立），但 Vivado 照样产出 `.bit` | 事故版：`u_lut/mem_reg → pos_rep 32 位加法 → u_abz/r_ovl[*]/CE`（§11.12 #3） |
| **v66** | **10-28** | 生产 **52.48% LUT / 32 BRAM / WNS +0.186**；显示 **83.82% / 48 BRAM / WNS +0.229** | **转台适配基线（构建签核 + 仿真，未上板）** |
| v67 | 10-29 | 生产 10,924 LUT = 52.52% / WNS +0.282 / `BUILD 0x000F` | 小信号版（200–300 mVpp、64 周期/转）；未上板 |
| v68 | 10-30 | 生产 10,928 LUT = 52.54% / WNS +0.144 / `BUILD 0x0010`；显示 17,414 = 83.72% / WNS +0.345 | 400 mVpp 单端 + 显示版；未上板 |
| v69 | 11-01 | 10 s / 101,718 帧 `cycle_cnt` 恒 0、反向 UVW 全 v=0 | **两处死锁的现场**（`BUILD 0x0011`，未解决） |
| **v70** | **11-01** | 生产 **10,955 LUT = 52.67% / 32 BRAM / WNS +0.091 / `BUILD 0x0015`**；显示 17,415 = 83.73% / WNS +0.027 | v74 的前身：生产已上板验收，显示未上板 |
| **v74**（历史） | **11-02** | 生产 10,926 LUT = 52.5% / 32 BRAM / 余量 +0.4 ns 档；显示 17,125 = 82.3% / WNS +0.189 | v90 的前身：生产已上板复验，显示位流（含 v75 界面）未目视 |
| **v85 / v89**（历史） | 11-03 | 显示位流中间版：删 P7 标定整页、P2 预触发缓冲与 AUTO 时基；只到 `[构建签核]` | 界面收口的两个中间版，未单独上板记档 |
| **v90** | **11-04** | 生产 **10,978 LUT = 52.78% / 32 BRAM / 17 DSP / WNS +0.199 / `BUILD 0x0019` / 1,504,220 B**；显示 **17,090 = 82.16% / BRAM 45.5/50 / WNS +0.221 / 1,688,245 B** | **当前交付基线：生产 + 显示均已上板，显示已写 Flash 冷启动通过；Z 索引发生器治停位喘振** |

---

## 9. 覆盖边界（这张表**没有**的东西）

诚实登记，避免"表里没有 = 没做过"的误读，也避免"报告写了 = 有证据"的误读：

1. **延迟实测**（R6）没有数，只有预算（`≈830 ns` = 41.5 拍 @50 MHz，`[设计值]`）；
2. **真实传感头**只在一种规格上跑过闭环（2048 周期/转磁环，v90，457–459 rpm）；**异型号、异极对数、异气隙没有数据**，其余测量仍以信号源为主；
3. **示波器逐点比对**、**Z 脉宽游标图**（R5）没有；
4. **链路误码率**（PRBS7）没测；**1,000 次抓取连测**没做；
5. **屏上四页逐页目视**（R13）已通过（2026-11-04），记录见 `board_day_checklist.md` §1 与 `docs/39` §5；
6. **拔网线/断电重启**的自动恢复需人工在现场，没做（**但 Flash 冷启动已验**，灯亮即跑）；
7. v59/v60/v61 的位流与报告未全部入 `data/`（只归档了 v62 与 v12 及更早的实验件）——
   这一条是取舍：归档"交付件 + 关键历史"而不是全部 25 个位流，`data/README.md` 已说明；
8. **v66、v67、v68 三个版本的位流都没上板**：全部数字只到 `[构建签核]` + `[仿真]` 两级，`[实测]` 严禁；
   上板过的是 v62、v70、v74、**v90** 四版；
9. **v62 生产位流缺 `check_timing` / `hold_paths` / `io` 三份报告**（当初构建脚本没跑），
   为不改变位流与哈希**没有重跑**；**v90 两版 10 份报告齐全**，见 `data/v90/` 与 `data/README.md` §2.0a；
10. **没有 ±0.5″ 的外部角度基准**：`angle_vs_sc` 的 0.71° RMS 是**内部一致性**（与指令角对比），
    不是绝对精度；全周补偿表默认旁路，"表能装能读回"不等于"精度已证明"（§7 R15）；
11. **Z 是虚拟 Z**（`z_index_gen` 由机械角在 45° 布防窗内生成，每转 1 个），**外部 Z 输入引脚未实现**；
    无 MDIO（100 Mbps 对端不通）；`ping -l ≥86` 会因 128 B 答复缓冲区被截断；
12. **偏置慢跟踪默认关闭**（`0x0122` bit1=0），需上板确认收敛后再开；低速测速带宽、温漂、连续运行 2 h 三项仍为 TBD。
