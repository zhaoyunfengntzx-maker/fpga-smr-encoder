#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lattice_figure.py -- 用真实 ILA 抓包画「D 分支事件落在 256 格点」图（报告素材 P2-3）。

每个面板 = 一次毛刺抓包的真实 (s_raw, c_raw) 轨迹（12 位二补码，原始码 LSB），
叠加 256 LSB 网格（两通道 10 位纹波进位链的上/下翻转边界），并标出坏拍：
  簇 A（`ila_cap_v9_glitch1..4.csv`、`ila_cap_v9_g197_1..4.csv`）：真值 ≈ (−1539, +518)，
        坏拍 s_raw 被整字替换为 0x300 (+768)；
  簇 B（`ila_cap_v9_g82_1/2.csv`）：真值 ≈ (−1022, −1280)，坏拍 s_raw = 0x400 (+1024)。

用法：
  python tools/lattice_figure.py \
      --csv-a _synth_work/ila_cap_v9_glitch1.csv \
      --csv-b _synth_work/ila_cap_v9_g82_1.csv \
      --out deliverables/figures/lattice_event.png --half 110
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glitch_figure import COLS, find_event, load_csv, s12  # noqa: E402

PANELS = [
    ("A 簇：真值 ≈ (−1539, +518) = (−6,+2)·256\n坏拍 s_raw → 0x300 (+768)", "csv_a"),
    ("B 簇：真值 ≈ (−1022, −1280) = (−4,−5)·256\n坏拍 s_raw → 0x400 (+1024)", "csv_b"),
]


def one_panel(ax, path, half, tag):
    d = load_csv(path)
    s = s12(d[COLS["s_raw"]])
    c = s12(d[COLS["c_raw"]])
    i0 = find_event(s)
    if half and half > 0:
        lo, hi = max(0, i0 - half), min(len(s), i0 + half + 1)
    else:
        lo, hi = 0, len(s)          # 默认画整窗（一份抓包 ≈ 0.41 个电周期）
    xs, ys = s[lo:hi], c[lo:hi]
    j = i0 - lo                       # 坏拍在本窗内的下标
    keep = np.arange(len(xs)) != j    # 排掉坏拍后再定视野/量程
    x0, y0 = xs[keep].mean(), ys[keep].mean()
    span = 0.56 * max(float(np.ptp(xs[keep])), float(np.ptp(ys[keep])))

    # 256 LSB 网格（两通道 256 边界）
    gx0 = int(np.floor((x0 - span) / 256.0)) * 256
    gx1 = int(np.ceil((x0 + span) / 256.0)) * 256
    gy0 = int(np.floor((y0 - span) / 256.0)) * 256
    gy1 = int(np.ceil((y0 + span) / 256.0)) * 256
    for g in range(gx0, gx1 + 1, 256):
        ax.axvline(g, color="#c8c8c8", lw=0.8, ls="-", zorder=0)
    for g in range(gy0, gy1 + 1, 256):
        ax.axhline(g, color="#c8c8c8", lw=0.8, ls="-", zorder=0)
    for gx in range(gx0, gx1 + 1, 256):
        for gy in range(gy0, gy1 + 1, 256):
            ax.plot([gx], [gy], marker="+", ms=5, color="#909090", zorder=1)

    # 坏拍样本本身要断开（它的 s_raw 被替换成 0x300/0x400，连线会横穿整幅图）
    truth = int(round((s[i0 - 1] + s[i0 + 1]) / 2.0)) if 0 < i0 < len(s) - 1 else s[i0]
    line_s = xs.astype(float).copy()
    line_c = ys.astype(float).copy()
    if 0 <= j < len(line_s):
        line_s[j] = np.nan
        line_c[j] = np.nan
    ax.plot(line_s, line_c, "-", lw=1.1, color="#1f77b4", zorder=3,
            label="真实轨迹 (s_raw, c_raw)")
    ax.plot(xs, ys, "o", ms=2.2, color="#1f77b4", alpha=.7, zorder=3)
    ax.plot([truth], [c[i0]], marker="*", ms=17, color="crimson", zorder=5,
            label="坏拍位置（真值 %d，实测 s_raw = 0x%03X = %d）" % (truth, s[i0] & 0xFFF, s[i0]))
    ax.annotate("坏拍：实测 s_raw = %d (0x%03X)\n（整字替换，低 8 位与真值一致；\n波形见 ila_glitch.png）"
                % (s[i0], s[i0] & 0xFFF),
                xy=(truth, c[i0]), xytext=(-120, -46), textcoords="offset points",
                color="crimson", fontsize=8.5,
                arrowprops=dict(arrowstyle="->", color="crimson", lw=1.0))
    ax.set_title("%s\n抓包 %s（idx=%d，真值 %d ← 相邻两拍均值）"
                 % (tag, os.path.basename(path), i0, truth), fontsize=9.5)
    ax.set_xlabel("s_raw（原始码 LSB，12 位二补码）")
    ax.set_ylabel("c_raw（原始码 LSB）")
    ax.set_aspect("equal", adjustable="box")
    ax.set_xlim(x0 - span, x0 + span)
    ax.set_ylim(y0 - span, y0 + span)
    ax.grid(False)
    ax.legend(loc="upper right", fontsize=8, framealpha=.9)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv-a", dest="csv_a", default="_synth_work/ila_cap_v9_glitch1.csv")
    ap.add_argument("--csv-b", dest="csv_b", default="_synth_work/ila_cap_v9_g82_1.csv")
    ap.add_argument("--out", default="deliverables/figures/lattice_event.png")
    ap.add_argument("--half", type=int, default=0,
                    help=">0 时只画坏拍前后 ±half 拍；0（默认）画整窗")
    args = ap.parse_args()

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import rcParams
    rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(1, 2, figsize=(12.4, 6.4))
    for ax, (tag, attr) in zip(axes, PANELS):
        one_panel(ax, getattr(args, attr), args.half, tag)
    fig.suptitle("D 分支坏样本的几何位置：两簇事件都落在 256 LSB 格点（s 与 c 的高位组同拍翻转）",
                 fontsize=11.5)
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    fig.savefig(args.out, dpi=150)
    print("saved %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
