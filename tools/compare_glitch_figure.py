#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""compare_glitch_figure.py -- v9（坏样本现场）vs v11（同一热点、干净）双列对比波形图。

左列：v9 ILA 抓包（触发挂 dbg_ang_glitch，命中后回看 DEPTH/2 拍），居中在**坏拍**上；
右列：v11 ILA 抓包（触发挂 dbg_adc_valid，立即触发），居中在**触发拍**上。
三行分别是：① s_raw / c_raw（12 位二补码）；② s_dec/16 与 angle_raw/16；③ dbg_ang_glitch 标志。

用法：
  python tools/compare_glitch_figure.py \
      --v9  _synth_work/ila_cmp_v9_glitch.csv \
      --v11 _synth_work/ila_cmp_v11_clean.csv \
      --out deliverables/figures/ila_glitch_v9_vs_v11.png
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glitch_figure import COLS, load_csv, s12, s16, find_event  # noqa: E402

EXTRA = {
    "trig": "TRIGGER",
    "otr": "dbg_otr_lat",
    "ang_delta": "dbg_ang_delta[15:0]",
    "cycle": "dbg_cycle_cnt[15:0]",
}


def col(d, name, default=None):
    return d[name] if name in d else default


def stat_line(path, d, center, tag):
    """返回两行说明文字：件信息 + 该窗毛刺统计。"""
    s = s12(d[COLS["s_raw"]])
    gl = d[COLS["glitch"]]
    n_gl = int(np.sum(gl != 0))
    otr = col(d, EXTRA["otr"])
    otr_txt = ("OTR 粘滞 = 无" if otr is None or int(np.max(otr)) == 0
               else "OTR 粘滞 = 0x%02X" % int(np.max(otr)))
    if 0 < center < len(s) - 1:
        truth = (s[center - 1] + s[center + 1]) / 2.0
        jump = int(s[center] - round(truth))
    else:
        jump = 0
    return ["%s：%s" % (tag, os.path.basename(path)),
            "窗内 dbg_ang_glitch 命中 %d 拍；坏拍跳变 %+d LSB；%s" % (n_gl, jump, otr_txt)]


def draw(axes, d, center, half, title, note):
    s = s12(d[COLS["s_raw"]])
    c = s12(d[COLS["c_raw"]])
    lo = max(0, center - half)
    hi = min(len(s), center + half + 1)
    x = np.arange(lo, hi) - center

    ax = axes[0]
    ax.plot(x, s[lo:hi], "-o", ms=3, lw=1.2, color="#1f77b4", label="s_raw（12 位二补码）")
    ax.plot(x, c[lo:hi], "-s", ms=2.6, lw=1.0, color="#ff7f0e", alpha=.85, label="c_raw（对照）")
    ax.axvline(0, color="crimson", lw=1.0, ls="--")
    ax.annotate("idx=%d\n0x%03X (%d)" % (center, s[center] & 0xFFF, s[center]),
                xy=(0, s[center]), xytext=(6, 0), textcoords="offset points",
                color="crimson", fontsize=9)
    ax.set_title(title, fontsize=10)
    ax.set_ylabel("原始码（LSB）")
    ax.grid(alpha=.3)
    ax.legend(loc="lower left", fontsize=7)

    ax = axes[1]
    if COLS["s_dec"] in d:
        ax.plot(x, s16(d[COLS["s_dec"]][lo:hi]) / 16.0, "-o", ms=2.6, lw=1.0,
                color="#2ca02c", label="s_dec / 16")
    if COLS["angle_raw"] in d:
        ax.plot(x, s16(d[COLS["angle_raw"]][lo:hi]) / 16.0, "-", lw=1.1,
                color="#9467bd", alpha=.9, label="angle_raw / 16")
    ax.axvline(0, color="crimson", lw=1.0, ls="--")
    ax.set_ylabel("LSB（已除 16）")
    ax.grid(alpha=.3)
    ax.legend(loc="lower left", fontsize=7)

    ax = axes[2]
    ax.step(x, d[COLS["glitch"]][lo:hi], where="mid", color="crimson", lw=1.3)
    ax.set_ylim(-0.2, 1.4)
    ax.set_ylabel("ang_glitch")
    ax.set_xlabel("采样拍（相对参考拍）")
    ax.grid(alpha=.3)
    ax.text(0.98, 0.72, note, transform=ax.transAxes, ha="right", va="top",
            fontsize=8, color="#333", bbox=dict(fc="#fffbe6", ec="#d6c98a", alpha=.9))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--v9", default="_synth_work/ila_cmp_v9_glitch.csv")
    ap.add_argument("--v11", default="_synth_work/ila_cmp_v11_clean.csv")
    ap.add_argument("--out", default="deliverables/figures/ila_glitch_v9_vs_v11.png")
    ap.add_argument("--half", type=int, default=40)
    ap.add_argument("--rate-v9", default="")
    ap.add_argument("--rate-v11", default="")
    ap.add_argument("--title", default="D 分支坏样本：v9（旧采样相位）vs v11（同相采样时钟，采纳版）")
    args = ap.parse_args()

    d9 = load_csv(args.v9)
    d11 = load_csv(args.v11)
    i9 = find_event(s12(d9[COLS["s_raw"]]))
    trig = col(d11, EXTRA["trig"])
    i11 = int(np.argmax(trig)) if trig is not None and int(np.max(trig)) > 0 else len(d11[COLS["glitch"]]) // 2

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import rcParams
    rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(3, 2, figsize=(13.6, 7.8),
                             gridspec_kw={"height_ratios": [2.4, 1.6, 1.0], "wspace": .17})
    fig.subplots_adjust(left=.05, right=.985, top=.90, bottom=.11)
    fig.suptitle(args.title, fontsize=12)

    n9 = int(np.sum(d9[COLS["glitch"]] != 0))
    n11 = int(np.sum(d11[COLS["glitch"]] != 0))
    note9 = "触发挂 dbg_ang_glitch\n命中 %d 拍%s" % (n9, ("\n" + args.rate_v9) if args.rate_v9 else "")
    note11 = "触发挂 dbg_ang_glitch\n本窗命中 %d 拍%s" % (n11, ("\n" + args.rate_v11) if args.rate_v11 else "")

    draw(axes[:, 0], d9, i9, args.half, "① v9（RTL_BUILD_ID = 0x0009）：坏样本现场", note9)
    draw(axes[:, 1], d11, i11, args.half, "② v11（RTL_BUILD_ID = 0x000B）：同一热点、同一档位", note11)

    cap = []
    cap += stat_line(args.v9, d9, i9, "左")
    cap += stat_line(args.v11, d11, i11, "右")
    fig.text(0.5, 0.005, "   ｜   ".join(cap), ha="center", va="bottom", fontsize=8.5)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    fig.savefig(args.out, dpi=150)
    print("saved %s" % args.out)
    print("v9  window: glitch=%d, center idx=%d, s_raw=0x%03X" % (n9, i9, s12(d9[COLS["s_raw"]])[i9] & 0xFFF))
    print("v11 window: glitch=%d, center idx=%d" % (n11, i11))
    return 0


if __name__ == "__main__":
    sys.exit(main())
