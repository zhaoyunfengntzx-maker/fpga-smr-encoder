#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""glitch_figure.py -- 用 ILA 抓包 CSV 出「D 分支坏样本」逐位证据图（报告素材 P2-3）。

输入：`write_hw_ila_data -csv` 导出的 CSV（第 1 行列名、第 2 行 radix、其后数据；HEX 列不带 0x 前缀）。
输出：三面板 PNG（默认 `deliverables/figures/ila_glitch.png`）：
  ① s_raw / c_raw（12 位二补码）—— 标出坏拍与坏码；
  ② s_dec（原始码×16 抽值）与 angle_raw —— 扰动如何进入角度通道；
  ③ dbg_ang_glitch 标志 —— 从坏拍到"检测-保持"触发的流水线延迟。

用法：
  python tools/glitch_figure.py --csv _synth_work/ila_cap_v9_glitch1.csv \
      --out deliverables/figures/ila_glitch.png --title "D 分支坏样本（8 位帧）"
"""
import argparse
import os
import sys

import numpy as np

COLS = {
    "s_raw": "dbg_s_raw[11:0]",
    "c_raw": "dbg_c_raw[11:0]",
    "s_dec": "dbg_s_dec[15:0]",
    "angle_raw": "dbg_angle_raw[15:0]",
    "glitch": "dbg_ang_glitch",
    "stat": "dbg_stat_byte[7:0]",
}


def load_csv(path):
    """返回 dict[str, np.ndarray(int64)]，键为列名。"""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = [ln.rstrip("\n").rstrip("\r") for ln in fh]
    head_i = None
    for i, ln in enumerate(raw):
        if ln.startswith("Sample in Buffer"):
            head_i = i
            break
    if head_i is None:
        raise SystemExit("找不到列名行（以 'Sample in Buffer' 开头）: %s" % path)
    names = raw[head_i].split(",")
    rows = []
    for ln in raw[head_i + 2:]:
        if not ln.strip():
            continue
        parts = ln.split(",")
        if len(parts) != len(names):
            continue
        rows.append(parts)
    out = {}
    for j, nm in enumerate(names):
        vals = []
        for r in rows:
            v = r[j].strip()
            try:
                vals.append(int(v, 16) if not v.lower().startswith("-") else int(v, 10))
            except ValueError:
                vals.append(int(v, 10))
        out[nm] = np.array(vals, dtype=np.int64)
    return out


def s12(v):
    """12 位二补码 -> 有符号。"""
    v = np.asarray(v, dtype=np.int64) & 0x0FFF
    return np.where(v >= 0x800, v - 0x1000, v)


def s16(v):
    """16 位二补码 -> 有符号（s_dec / angle_raw 都是 signed [15:0]）。"""
    v = np.asarray(v, dtype=np.int64) & 0xFFFF
    return np.where(v >= 0x8000, v - 0x10000, v)


def find_event(s):
    """最大局部跳变的下标（|s[i] - (s[i-1]+s[i+1])/2| 最大）。"""
    if len(s) < 3:
        return 0
    mid = (s[:-2] + s[2:]) / 2.0
    dev = np.abs(s[1:-1] - mid)
    return int(np.argmax(dev)) + 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="_synth_work/ila_cap_v9_glitch1.csv")
    ap.add_argument("--out", default="deliverables/figures/ila_glitch.png")
    ap.add_argument("--half", type=int, default=40, help="事件两侧展示的拍数")
    ap.add_argument("--title", default="")
    args = ap.parse_args()

    d = load_csv(args.csv)
    need = [COLS[k] for k in ("s_raw", "c_raw", "glitch")]
    for nm in need:
        if nm not in d:
            raise SystemExit("CSV 里没有列 %s（可用列见文件第 1 行）" % nm)
    s = s12(d[COLS["s_raw"]])
    c = s12(d[COLS["c_raw"]])
    i0 = find_event(s)
    lo = max(0, i0 - args.half)
    hi = min(len(s), i0 + args.half + 1)
    x = np.arange(lo, hi) - i0

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import rcParams
    rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(3, 1, figsize=(10.5, 7.6), sharex=True,
                             gridspec_kw={"height_ratios": [2.4, 1.6, 1.0]})
    ttl = args.title or os.path.basename(args.csv)
    fig.suptitle("%s\n事件拍 idx=%d：s_raw = %d (0x%03X)  ←  邻拍真值 ≈ %d"
                 % (ttl, i0, s[i0], s[i0] & 0xFFF,
                    int(round((s[i0 - 1] + s[i0 + 1]) / 2.0)) if 0 < i0 < len(s) - 1 else s[i0]),
                 fontsize=11)

    ax = axes[0]
    ax.plot(x, s[lo:hi], "-o", ms=3, lw=1.2, color="#1f77b4", label="s_raw（12 位二补码）")
    ax.plot(x, c[lo:hi], "-s", ms=2.6, lw=1.0, color="#ff7f0e", alpha=.85, label="c_raw（对照，干净）")
    ax.axvline(0, color="crimson", lw=1.0, ls="--")
    ax.annotate("坏码 0x%03X (%d)" % (s[i0] & 0xFFF, s[i0]), xy=(0, s[i0]),
                xytext=(6, 0), textcoords="offset points", color="crimson", fontsize=10)
    ax.set_ylabel("原始码（LSB）")
    ax.grid(alpha=.3)
    ax.legend(loc="lower left", fontsize=8)

    ax = axes[1]
    if COLS["s_dec"] in d:
        ax.plot(x, s16(d[COLS["s_dec"]][lo:hi]) / 16.0, "-o", ms=2.6, lw=1.0,
                color="#2ca02c", label="s_dec / 16（抽值后，仍在原始码域）")
    if COLS["angle_raw"] in d:
        ax.plot(x, s16(d[COLS["angle_raw"]][lo:hi]) / 16.0, "-", lw=1.1,
                color="#9467bd", alpha=.9, label="angle_raw / 16")
    ax.axvline(0, color="crimson", lw=1.0, ls="--")
    ax.set_ylabel("LSB（已除 16）")
    ax.grid(alpha=.3)
    ax.legend(loc="lower left", fontsize=8)

    ax = axes[2]
    ax.step(x, d[COLS["glitch"]][lo:hi], where="mid", color="crimson", lw=1.3)
    ax.set_ylim(-0.2, 1.4)
    ax.set_ylabel("ang_glitch")
    ax.set_xlabel("采样拍（相对坏拍）")
    ax.grid(alpha=.3)

    fig.tight_layout(rect=(0, 0, 1, 0.94))
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    fig.savefig(args.out, dpi=150)
    print("saved %s  (event idx=%d, s_raw=0x%03X=%d)" % (args.out, i0, s[i0] & 0xFFF, s[i0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
