# 22 — 屏幕 v60：上板问题修复与七项优化

> 状态：**待上板**（2026-10-23 凌晨）。位流由 `_impl_v59.tcl` 生成到 `_impl_v58/`，
> 数字见 §7。上一版 v59 的实施记录在 [`21_screen_ui_v2_requirements.md`](21_screen_ui_v2_requirements.md) §10。

## 1 这一版解决什么问题

用户 m03134 在 v59 上板后提了 7 条，加上随后两轮补充（m03202 / m03214 / m03236 /
m03239 / m03451），归成 9 个工作项：

| 编号 | 用户原话（缩写） | 判断 | 处置 |
|---|---|---|---|
| T1 | 总览右下角一直有蓝色横线 | **真 bug**：v49 的「卡 6 迷你电平条」是写死的 288×256 矩形，v59 卡片改成 448×152 后落进 ABZ 卡 | 整块删除（U/V/W 状态已由 `stat_chip` 圆点表达） |
| T2 | 设置页左侧导航「波形」没了 | **真 bug**：`DLG_ROW3 = 14` 与导航「波形」同格行，`dlg_cell0` 整行排除 | 改成只排除格列 ≥ 6 |
| T3 | A/B/Z 右边的圆显示不全 | **真 bug**：`font_raster._proc` 拿整格 30×64 算半径，`●` 墨迹 35 px > 30 px 格宽 | 程序化符号按**墨迹框**画，半径 `min(w,h)/2-2` |
| T4 | 各页数字粗细不统一 | **真 bug**：数字补齐逻辑把 `1` 从 17 px 拉到 25 px，笔画变粗 | 删掉横向拉伸（数字仍等宽：同字号、同格距） |
| R1 | 只接信号发生器时总览恒报「故障」 | **设计口径**：`sig_bad = 幅值丢失 \| 链路健康位` 一锅端 | 拆成 `bad_mask[5:0]` 按卡下发（见 §2） |
| T5 | 波形页能再优化显示 | 版面 | 64/32 px 栅格 + 左侧 32 px 幅值刻度条（+5/0/-5） |
| T6 | 标定页利用率低，要更大 | 版面 | 参数 6 项 → 4 项（OFS-S/OFS-C/GAIN-S/GAIN-C），框高 416 → 480 |
| T7 | 时序页方波一直在流动，要像示波器 | **时基错了**：原按电角度 128 箱重建，A/B 与电角度不锁相就必然流动 | 换成**触发式时域**采集（512 点 × 2 µs/点），可停在屏上 |
| T8 | 没有主机激励时屏上什么都看不出来 | 交互 | P6 加「DEMO」开关：六张卡切一组演示值（1500.00 Hz / 转速 / 角度缓慢旋转） |
| T9 | 每次烧录后要按一次 KEY0 触摸才生效 | **真 bug**：`touch_ctrl` 失败重试只重探 I2C，不重走 GT911 的 RST/INT 上电时序 | 顶层加复位序列发生器：上电压 200 ms，1 s 锁不上型号就自动重走一次 |

## 2 R1：故障源按卡拆开

上板反馈「只接信号发生器，六张卡全挂 ✕ 故障」。原因不是显示 bug，而是
`sig_bad = crc_err | amp_gone | link_lost` 被**全部**卡片共用。v60 改成 6 bit
`bad_mask`，逐卡口径见下表；`stat_chip` 与 `val_format` 都换成按位判。

| 卡 | 数据来源 | 判据 |
|---|---|---|
| 0 输入频率 | ADC A 通道 | `amp_gone` |
| 1 倍频分频 | 配置 + 输入引脚 | 永远可信 |
| 2 转速 | ADC 幅值 + 换向 | `amp_gone` |
| 3 角度 | CORDIC（ADC SIN/COS） | `amp_gone` |
| 4 累计转数 | 内部多圈位置 | `amp_gone` |
| 5 ABZ/UVW | 输入引脚 | 永远可信 |

顶栏那条竖带 / ▲ 也同时改成两档（`disp/disp_engine.v`）：

- **红（故障）** = `amp_gone` —— 数据真的不能用；
- **橙（警示）** = `q_stat[0] | q_stat[5..] | q_io_flags[5:4]`
  —— 某一路不太对，但读数还能看。

只接信号发生器时，页面只剩「累计转数」卡报故障、竖带是橙色，这是如实反映
「编码器没有激励」，不是误报。

原来 `sig_bad` 同时驱动 6 张卡的「✕ 故障」与空态横杠，而其中一项判据在没有主机激励时
恒置位 ⇒ 只接信号发生器时整屏报故障。

```
amp_bad_c = amp_gone;                                // ADC 幅值
enc_bad_c = 1'b0;                                   // 编码器链路
bad_mask  = {1'b0,       // 卡 5 ABZ/UVW   永远可信
             enc_bad_c,  // 卡 4 累计转数  看编码器链路
             amp_bad_c,  // 卡 3 角度      看 ADC（角度由 CORDIC 算）
             amp_bad_c,  // 卡 2 转速      看 ADC
             1'b0,       // 卡 1 倍频分频  永远可信
             amp_bad_c}; // 卡 0 输入频率  看 ADC
```

`val_format` 的端口从 `nodata` 变成 `nodata_mask[5:0]`，`stat_chip` 从 `sig_bad`
变成 `bad_mask[5:0]`；演示模式下 `bad_mask` 强制为 0。

## 3 T7：触发式时域（`disp/trace_cap.v`）

- 采样：`prescale = 100`（2 µs/点）× 512 点 ⇒ 单屏 1.024 ms，横轴 1 µs/px（100 px/格）。
- 触发：`trig_sel` 0 = Z↑、1 = A↑、3 = 自由（2 = 电角度模式**已按用户要求删掉**）。
- 双缓冲：`cap_mem`（采集中）→ 512 拍拷进 `dsp_mem`（显示中）⇒ 屏上画面**不撕裂、不流动**。
- 存储：两块 512×6 bit = 6,144 bit，**故意用 LUTRAM**（BRAM 已 97%）。
  ★ 两块数组必须显式写 `(* ram_style = "distributed" *)`，而且**读/写要拆成独立的
  `always` 块** —— 把 `cap_mem` 的写与 `dsp_mem[cidx] <= cap_mem[cidx]` 的拷贝放在
  同一个块里，Vivado 会放弃 RAM 推断、把 9,216 bit 全做成寄存器（v60 首轮实现
  LUT 20,548 / FF 17,459，见 §7.2）。
- 读口：`ridx = dx[9:1]`（2 px/点），`qp` = 上一点 ⇒ 箱边界仍由"本点 vs 上一点"判 1 px。
- 轴标签：`T-US` + `0/100/.../800`，注记 `TRIG Z 2US/PT 428PT`。**字库没有「间/发/共/↑/μ」**
  这几个字，所以轴文字全走 ASCII（`tools/gen_text_ram.py` 混排会直接报
  `char '间' ... is not in the font charset`）。

## 4 T8：演示模式

- 命中：`disp/hit_test.v` 新增 `DEMO_X0=840 / DEMO_X1=1000 / DEMO_Y0=24 / DEMO_Y1=64`、
  `HIT_DEMO = 5'd14`；优先级在标题按钮之后、状态条之前。
- 视觉：P6 标题带右侧「DEMO」按钮（840..999 / 28..59）+ 左侧 16×16 复选框，
  **实心 = 开 / 空心 = 关**（沿用「闪烁」按钮的"不靠颜色编码"纪律）。
- 数据：`disp_engine` 里 `dm_cnt` 每帧 +37，`demo_on` 时用
  `vfs_f_q10 / vfs_pos / vfs_angle / vfs_io / vfs_bad` 这组 mux 覆盖 `val_format`
  与 `stat_chip` 的输入；关时**一切照旧**。
- 只在 P6 上可切（`page == 3'd5`），不写寄存器、不过 SPI，上电默认关。

## 5 T9：触控上电与自恢复

上板症状：每次烧录后必须按一次 KEY0 触摸才生效。

根因链：`touch_rst_n = KEY0 复位`（`enc_top_disp.v` 的 `rst_sync`）→ GT911 地址在
RST 上升沿按 INT 电平锁存（低 = 0x5D）。上电瞬间如果 INT 还没稳定，地址会锁成 0x14，
而 `touch_ctrl` 的重试只重探 I2C（`probe_gt`/`probe_ft`），**不会再拉一次 RST**，
于是永远不恢复；按 KEY0 相当于把整条上电时序重来一遍。

修法（不改 `touch_ctrl.v`，它有自己的仿真回归）：顶层加 `t9_*` 序列发生器

1. 上电后先压住 RST **200 ms**（10,000,000 拍）再放；
2. 释放后 INT 保持低 50 ms（沿用原 `int_hold_cnt`）；
3. 若 1 s（50,000,000 拍）后 `tch_type` 仍为 `0`（从没锁上型号），自动再走一次
   「RST 低 20 ms + 释放后 INT 低 50 ms」；`t9_retries` 计数上 UART 遥测。

## 6 其它同批改动

- 顶栏竖带 / ▲ 改两档（红=`amp_gone|crc_err`，橙=`link_lost|cor_sat|幅值超窗`），见 §2 末尾。
- 字库：`tools/font_raster.py` 的 `_proc` 改成按墨迹框画符号；删掉数字横向补齐。
  `disp/font_rom.v` 重新生成（146,944 bit ≈ 3.99 RAMB36，与 v59 同量级）。
- 预览：`tools/preview_pages.py` 与 RTL 同步（P2 栅格/刻度、P6 对话框只抹格列 ≥ 6、
  P6 DEMO 按钮）；`tools/ui_geom.py` 继续只从 RTL 常量解析。
- 夹具：`tb_disp_v58` 删 `c6_draw` 断言、加「右下角不许有 C_ACC」与「P6 导航行 14 有墨」；
  `tb_hit_test_v58` 加 DEMO 三点；新增 `tb_trace_cap`（触发/采集/交换/读口）。

## 7 门禁（本版）

| 门 | 命令 | 结果 |
|---|---|---|
| 契约台 | `python tools\run_sim_v58.py` | `tb_disp_v58` / `tb_hit_test_v58` / `tb_trace_cap` **3/3 PASS** |
| 全量回归 | `python tools\run_sim_disp.py` | 见 §7.1 |
| Lint | `powershell -ExecutionPolicy Bypass -File tools\lint_all.ps1` | **ERROR 0 / WARNING 0** |
| 实现 | `vivado -source _impl_v59.tcl` | 见 §7.2 |

### 7.1 全量回归

`run_sim_disp.py` 覆盖 17 台（含三台 v58/v60 契约台）。本版改动会牵动
`tb_val_format` / `tb_stat_chip`（端口从 1 bit 变 6 bit）、`tb_enc_disp_panel`
（P1 卡片几何）、`tb_logic_scope`（模块已删）—— 这三台已同步，结果见提交说明。

### 7.2 实现（v60）

`vivado -source _impl_v59.tcl`（`enc_top_disp` 全流程：synth → opt → place → route → bitstream）：

| 指标 | v59 | v60 | 差 |
|---|---|---|---|
| Slice LUT | 14,267 (68.59%) | **17,046 (81.95%)** | +2,779 |
| 寄存器 FF | 8,673 (20.85%) | **11,206 (26.94%)** | +2,533 |
| Block RAM Tile | 48.5 (97%) | **46 (92%)** | −2.5 |
| DSP | 18 (20%) | 18 (20%) | 0 |
| WNS | +0.466 | **+0.108** | −0.358 |
| WHS | +0.050 | **+0.068** | +0.018 |
| 位流 | 1,637,941 B | **1,723,329 B** | +85 KB |

结论：

- 时序与 DRC 都过（WNS/WHS 正、`BITSTREAM_WRITTEN`、0 Errors），可以上板。
- LUT 涨的 2.9k 主要来自 **T7 触发式时域的 6,144 bit 分布式 RAM 与两路异步读**
  （`ridx` 与 `ridx-1` 各一套 LUTRAM 读出，外加 512 深度写口译码），其次才是
  T5 栅格比较器、T8 演示计数器与 T9 三段计数。BRAM 反而降 2.5 块，是因为
  `logic_scope` 的 128×6 存储退役。
- 第一轮 v60 实现曾因 `trace_cap` 两块数组写成同一 `always` 块而被综合成寄存器
  （LUT 20,548 / FF 17,459），加 `(* ram_style = "distributed" *)` 并把读/写拆成
  独立块后回到 17,046 / 11,206 —— 这条教训写进 §3。
- 若下一版需要把 LUT 压回去：`trace_cap` 的存储可换 **1 块 RAMB18**（当前 BRAM
  余量 4 块），代价是读口要加一级流水（2 px/点的节拍足够）。

**裕量恢复流程对照**（`_impl_opt60.tcl` = `tools/impl_disp_opt.tcl` + `rtl/eth/*.v`，
输出 `_impl_opt60/`）：同一份 RTL 走 `opt_design` + `place -directive ExtraTimingOpt`
+ `phys_opt AggressiveExplore` + `route -directive Explore` + 再一轮 `phys_opt`，
得 **WNS +0.163 / WHS +0.056 / LUT 17,095 / 位流 1,754,125 B**。相对基准流程只多
0.055 ns（本工程历史上同一份源码相邻两次就能差 0.3 ns，属布局噪声），因此
**交付位流仍用基准流程** `_impl_v58/enc_top_disp.bit`；`_impl_opt60/enc_top_disp_opt.bit`
留作对照，若明早上板遇到偶发不稳定可换它复测（功能等价）。

## 8 未做

1. **上板验证**（用户明早做）：见 `docs/15` §0.2 的 10 条可点清单。
2. T7 的「触发源选择」GUI：本轮固定 `trig_sel = Z↑`，用户 m03451 只要求"稳定"，
   切触发源属于下一轮交互设计。
3. I2C 总线 9 拍恢复：T9 已能靠重走上电时序救回来，总线级恢复留作后手。
4. 采集侧 BRAM（`u_cap` 16 块）仍未动 —— 那是 `rtl/` 的存储结构，本版只做显示侧。
