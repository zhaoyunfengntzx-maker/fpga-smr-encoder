# tools/legacy —— 已退役的工具（v58 起）

这里的脚本**不在任何构建/回归流程里**，保留只为回溯旧做法。构建与回归入口只有：

| 用途 | 现行入口 |
|---|---|
| 契约仿真（RTL） | `python tools/run_sim_v58.py` |
| 全量旧回归（含 enc_top_disp） | `python tools/run_sim_disp.py` |
| 版面预览（与 RTL 同源） | `python tools/preview_pages.py --out _preview` |
| 字模/文字层生成 | `python tools/gen_font_rom.py`、`python tools/gen_text_ram.py` |
| 综合 / 实现 | `tools/synth_disp.tcl`、`tools/impl_disp.tcl`、`tools/impl_check.tcl` |

## 退役清单

### `run_smoke_disp.py` + `check_smoke_text.py`

- 原职责：跑 `disp/sim/smoke_p1.v`（P1 版面的 1:1 光栅窗口），再用
  `check_smoke_text.py` 把窗口里的墨点**反解成字符**，逐字符比对 `val_format`
  写进 RAM 的字符串 —— 一条"格式化 → RAM → 字模 → 移位 → 光栅"的端到端检查。
- 退役原因：反解器假设 **5×7 基字模 ×6 放大（`CELL=32 / GPS=6 / GLYPH=5×7`）**，
  v58 把字模改成 Arial Narrow Bold 的 **30×48 原生栅格化**，这套采样假设整体失效
  （实测 `FAIL: cell 0 is not any known glyph`）。
- 替代：`disp/tb_disp_v58.v` 覆盖 P1 版面（标题墨量、导航「设置」、删页零白底），
  `disp/tb_font_rom.v` 覆盖字模结构（等高/等距/留白/墨高），
  `disp/sim/smoke_p1.v` 仍可单跑并打印 `VAL LAYER` 六个字段供人眼核对
  （`run_smoke_disp.py` 移走后，用 `xsim` 直接跑即可，不再需要反解）。

### `gen_res_pct.py`

- 原职责：把 `impl_util.rpt` 的 `Slice LUTs / Block RAM Tile / DSPs` 百分比写回
  `disp/touch_view.v` 的 `RES_LUT_PCT / RES_BRAM_PCT / RES_DSP_PCT` —— P8 上
  "资源占用"三张卡的数字来源。
- 退役原因：v58 删掉 P8（系统信息页）与 `disp/touch_view.v`，屏上不再显示资源百分比，
  脚本的默认 `--rtl disp/touch_view.v` 已不存在。
- 替代：资源数字以 `_impl_v58/impl_util.rpt`、`deliverables/design_report.md` §9.6、
  `docs/21_screen_ui_v2_requirements.md` §9.6 为准。
