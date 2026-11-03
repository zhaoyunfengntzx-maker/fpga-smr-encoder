# disp/legacy —— v57 及以前的 8 页 UI 存档

这个目录里的文件**不参与当前工程**：`tools/run_sim_disp.py` 与
`tools/run_sim_v58.py` 的 glob 都是 `disp/*.v`（非递归），`tools/*.tcl`
的源文件列表同样非递归，所以放进来就等于从构建与回归里摘掉了。

留在这里而不是删掉的原因：它们是 v58 改版（8 页 → 5 页、导航 6×96 → 4×144、
字模改原生栅格化）的**对照物**。以后要回答"当初那页是怎么画的""旧契约台
验了些什么""为什么 xy_ram 占 4 块 RAMB36"，翻这里比翻 git 历史快。

## 模块（v58 起不再例化）

| 文件 | 原职责 | v58 处置 |
|---|---|---|
| `p2_badge.v` | P2 四个徽标数值（585 LUT + 3 DSP） | P2 徽标整块删除 |
| `p5_view.v` | P5 六状态表的次数/占比/条形图（851 LUT） | P5 页删除 |
| `xy_plot.v` | P3 李萨如的点位计算与写缓冲 | P3 页删除 |
| `xy_ram.v` | P3 位图 131072×1 bit（**4 块 RAMB36**） | P3 页删除 |
| `touch_view.v` | P8 触摸诊断九字段 | P8 页删除 |
| `band_view.v` | P8 底栏三个小数字 | P8 页删除 |
| `selftest_lab.v` | P8 自检结论 | P8 页删除 |

## 测试台（v57 契约，已被 v58 契约台取代）

| 文件 | 为什么退役 |
|---|---|
| `legacy_v57_tb_disp_engine.v` | 旧的整页像素契约台（3316 行，8 页版式），被 `disp/tb_disp_v58.v` 取代 |
| `tb_hit_test.v` | 旧触摸契约（6 项导航 96 px、状态栏 ⚙），被 `disp/tb_hit_test_v58.v` 取代 |
| `tb_p2_page.v` | 旧 P2 版式（Tab 栏、四徽标、`A SIN` 在 x=180），v58 删了 Tab 且波形上移 40 px |
| `tb_pipe_align.v` | 层级引用 `u_dut.u_xy_ram` / `u_dut.u_xy_plot`（已删实例），elaboration 会直接报错 |
| `tb_p3_page.v` / `tb_p5_page.v` | 对应页已删除 |
| `tb_p2_badge.v` / `tb_touch_view.v` / `tb_band_view.v` / `tb_selftest_lab.v` | 对应模块已删除 |

## 现在的契约台在哪

- `disp/tb_disp_v58.v`：5 页版式、4 档导航底色、R8（右下角蓝线）与 R9（导航「设置」）回归。
- `disp/tb_hit_test_v58.v`：27 个触摸边界点（含非法坐标、卡片缝、导航分界）。
- `disp/tb_font_rom.v`：字模结构（非空、两两不同、不越格、数字等高）。
- 一键回归：`python tools/run_sim_v58.py`（详情见 `docs/21_screen_ui_v2_requirements.md` §9）。
