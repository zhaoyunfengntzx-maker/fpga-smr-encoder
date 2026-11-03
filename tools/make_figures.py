# -*- coding: utf-8 -*-
"""Redraw all report figures in the shared Nature-journal style.

Usage:
    python tools/make_figures.py            # all
    python tools/make_figures.py mech calib
"""
import os
import sys

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

import figstyle as S
from glitch_figure import COLS, load_csv, s12, s16, find_event

FIGDIR = os.path.join(ROOT, "deliverables", "figures")


def mech():
    S.apply()
    f = S.fig(89, 43)
    ax = f.add_axes([0.02, 0.02, 0.96, 0.96])
    ax.set_xlim(0, 90)
    ax.set_ylim(0, 43)
    ax.axis("off")

    def box(x, y, w, h, fc, ec, lw=0.7):
        ax.add_patch(Rectangle((x, y), w, h, facecolor=fc, edgecolor=ec, lw=lw, zorder=2))

    box(2, 2.0, 86, 6.0, "#EDF1F5", "#9AA9BC")
    ax.text(45, 5.0, "stator (non-magnetic)", ha="center", va="center", fontsize=5.6, color=S.GREY)

    for x in (18, 64):
        box(x, 8.0, 8, 8.0, "#DCE3EC", "#9AA9BC")
        ax.text(x + 4, 12.0, "bearing", ha="center", va="center", fontsize=5.2, color=S.INK)

    box(10, 16.0, 70, 6.0, "#C9D2DE", "#9AA9BC")
    ax.text(13, 19.0, "shaft", ha="left", va="center", fontsize=5.8, color=S.INK)

    box(36, 22.0, 18, 8.0, "#EDF1F5", "#9AA9BC")
    ax.text(45, 26.0, "hub", ha="center", va="center", fontsize=5.4, color=S.GREY)

    box(34, 30.0, 22, 4.6, "#F6E3C7", "#C98612", lw=0.8)
    ax.text(45, 32.7, "magnet ring", ha="center", va="center", fontsize=5.2, color=S.INK)
    ax.text(45, 31.1, "2048 cycles/rev", ha="center", va="center", fontsize=5.2, color=S.INK)

    box(26, 38.2, 38, 3.0, "#D9EFE6", "#1E6B52", lw=0.8)
    ax.text(45, 41.5, "SMR sensor PCB", ha="center", va="bottom", fontsize=5.8, color=S.INK)
    ax.text(45, 39.7, "SMR", ha="center", va="center", fontsize=5.0, color="#1E6B52")

    ax.plot([59.4, 59.4], [34.9, 37.9], color=S.INK, lw=0.6)
    ax.plot([59.0, 59.4, 59.8], [37.2, 37.9, 37.2], color=S.INK, lw=0.6)
    ax.plot([59.0, 59.4, 59.8], [35.6, 34.9, 35.6], color=S.INK, lw=0.6)
    ax.text(60.4, 36.4, "air gap", ha="left", va="center", fontsize=5.2, color=S.INK)

    return S.save(f, os.path.join(FIGDIR, "fig_mech"))


def calib():
    S.apply()
    before = pd.read_csv(os.path.join(ROOT, "deliverables", "data", "lissajous_before_distortion.csv"),
                         encoding="utf-8-sig")
    after = pd.read_csv(os.path.join(ROOT, "deliverables", "data", "lissajous_after_distortion.csv"),
                        encoding="utf-8-sig")

    def radius(d):
        r = np.hypot(d["s"].values, d["c"].values)
        return 100.0 * r.std() / r.mean(), r

    cv_b, r_b = radius(before)
    cv_a, r_a = radius(after)

    f = S.fig(140, 48)
    gs = f.add_gridspec(1, 3, width_ratios=[1, 1, 1.2], wspace=0.34,
                        left=0.06, right=0.985, bottom=0.16, top=0.90)

    for k, (d, title, color, letter, cvv) in enumerate([
            (before, "Before calibration", S.EDIT["ochre"], "a", cv_b),
            (after, "After calibration", S.EDIT["teal"], "b", cv_a)]):
        ax = f.add_subplot(gs[0, k])
        ax.plot(d["s"].values, d["c"].values, "-", lw=0.30, color=color, alpha=0.9,
                rasterized=True)
        ax.set_aspect("equal", adjustable="box")
        ax.set_xlabel("s (LSB)")
        if k == 0:
            ax.set_ylabel("c (LSB)")
        ax.set_title(title, pad=4, loc="left")
        ax.set_xticks([-30000, 0, 30000])
        ax.set_yticks([-30000, 0, 30000])
        S.panel(ax, letter)

    ax = f.add_subplot(gs[0, 2])
    bins = np.linspace(15000, 35000, 121)
    ax.hist(r_b, bins=bins, density=True, histtype="step", lw=0.9, color=S.EDIT["ochre"])
    ax.hist(r_a, bins=bins, density=True, histtype="step", lw=0.9, color=S.EDIT["teal"])
    ax.set_xlabel("radius (LSB)")
    ax.set_ylabel("density")
    ax.set_title("Radius distribution", pad=4, loc="left")
    ax.set_xlim(15000, 35000)
    ax.set_ylim(bottom=0)
    ax.text(17800, 0.00040, "before", fontsize=6.2, color=S.INK)
    ax.annotate("after", xy=(26200, 0.0040), xytext=(28600, 0.0033),
                fontsize=6.2, color=S.INK,
                arrowprops=dict(arrowstyle="-", lw=0.6, color=S.GREY))
    S.panel(ax, "c")
    return S.save(f, os.path.join(FIGDIR, "fig_calibration"))


def residual():
    S.apply()
    d = pd.read_csv(os.path.join(ROOT, "_boardtest", "angle_vs_sc.csv"), encoding="utf-8-sig")
    th = d["theta_deg"].values % 360.0
    err = d["err_deg"].values
    z = np.exp(1j * np.radians(err))
    mean = np.degrees(np.arctan2(z.imag.mean(), z.real.mean()))
    res = (err - mean + 180.0) % 360.0 - 180.0

    nb = 16
    idx = np.floor(th / 360.0 * nb).astype(int) % nb
    bin_ang = (np.arange(nb) + 0.5) * 360.0 / nb
    bin_val = np.array([res[idx == i].mean() for i in range(nb)])
    amp = bin_val - bin_val.mean()
    spec = np.abs(np.fft.rfft(amp)) / len(amp) * 2

    f = S.fig(140, 48)
    gs = f.add_gridspec(1, 2, width_ratios=[1.55, 1], wspace=0.28,
                        left=0.07, right=0.985, bottom=0.17, top=0.90)

    ax = f.add_subplot(gs[0, 0])
    ax.axhspan(-0.13, 0.13, color=S.FAINT, zorder=0, lw=0)
    ax.axhline(0, color=S.LIGHT, lw=0.6, zorder=1)
    ax.plot(bin_ang, bin_val, "o", ms=2.6, color=S.EDIT["teal"], mfc="white", mew=0.8, zorder=3)
    A = [np.ones_like(bin_ang)]
    for k in range(1, 5):
        A.append(np.cos(np.radians(bin_ang * k)))
        A.append(np.sin(np.radians(bin_ang * k)))
    A = np.vstack(A).T
    coef, *_ = np.linalg.lstsq(A, bin_val, rcond=None)
    th_fit = np.linspace(0, 360, 721)
    fit = np.full_like(th_fit, coef[0])
    for k in range(1, 5):
        fit += coef[2 * k - 1] * np.cos(np.radians(th_fit * k))
        fit += coef[2 * k] * np.sin(np.radians(th_fit * k))
    ax.plot(th_fit, fit, "-", lw=0.9, color=S.EDIT["ochre"], zorder=2)
    ax.set_xlim(0, 360)
    ax.set_xticks([0, 90, 180, 270, 360])
    ax.set_ylim(-0.20, 0.20)
    ax.set_xlabel("electrical angle (deg)")
    ax.set_ylabel("bin-mean residual (deg)")
    ax.set_title("Angle residual, 16 bins  (−0.125…+0.119°) + harmonic fit", pad=4, loc="left")
    S.panel(ax, "a")

    ax = f.add_subplot(gs[0, 1])
    ks = np.arange(1, 6)
    cols = [S.EDIT["teal"]] * 5
    cols[3] = S.EDIT["ochre"]
    ax.bar(ks, spec[1:6], width=0.62, color=cols, edgecolor="none")
    for k, v in zip(ks, spec[1:6]):
        ax.text(k, v + 0.003, "%.3f" % v, ha="center", va="bottom", fontsize=6.0)
    ax.set_xticks(ks)
    ax.set_xlabel("harmonic order")
    ax.set_ylabel("amplitude (deg)")
    ax.set_ylim(0, 0.115)
    ax.set_title("Harmonic decomposition", pad=4, loc="left")
    S.panel(ax, "b")
    return S.save(f, os.path.join(FIGDIR, "fig_residual"))


def glitch_time():
    S.apply()
    p = os.path.join(ROOT, "deliverables", "data", "ila", "ila_cap_v9_glitch1.csv")
    d = load_csv(p)
    s = s12(d[COLS["s_raw"]])
    c = s12(d[COLS["c_raw"]])
    i0 = find_event(s)
    half = 40
    lo, hi = max(0, i0 - half), min(len(s), i0 + half + 1)
    x = np.arange(lo, hi) - i0
    truth = int(round((s[i0 - 1] + s[i0 + 1]) / 2.0))

    f = S.fig(140, 83)
    gs = f.add_gridspec(3, 1, height_ratios=[2.2, 1.5, 1.0], hspace=0.16,
                        left=0.085, right=0.985, bottom=0.09, top=0.93)

    ax = f.add_subplot(gs[0, 0])
    ax.plot(x, c[lo:hi], "-", lw=0.7, color=S.LIGHT, zorder=1)
    ax.plot(x, s[lo:hi], "-o", ms=1.6, lw=0.8, color=S.EDIT["teal"], zorder=2)
    ax.axvline(0, color=S.GREY, lw=0.6, ls=(0, (3, 2)), zorder=0)
    ax.axhline(truth, color=S.GREY, lw=0.6, ls=(0, (3, 2)), zorder=0)
    ax.annotate("stuck code 0x300 (+768)", xy=(0, s[i0]), xytext=(8, 5),
                textcoords="offset points", fontsize=6.2, color=S.INK)
    ax.text(-38, truth + 90, "true ≈ %d" % truth, fontsize=6.0, color=S.INK)
    ax.text(-38, 430, "c_raw", fontsize=5.8, color=S.GREY, va="bottom")
    ax.set_ylabel("raw code (LSB)")
    ax.set_xlim(-half, half)
    ax.set_xticklabels([])
    S.panel(ax, "a")

    ax = f.add_subplot(gs[1, 0])
    ax.plot(x, s16(d[COLS["angle_raw"]][lo:hi]) / 16.0, "-", lw=0.9, color=S.EDIT["teal"])
    ax.plot(x, s16(d[COLS["s_dec"]][lo:hi]) / 16.0, "-o", ms=1.5, lw=0.8, color=S.EDIT["teal"])
    ax.axvline(0, color=S.GREY, lw=0.6, ls=(0, (3, 2)), zorder=0)
    ax.text(38, s16(d[COLS["angle_raw"]][hi - 1]) / 16.0 + 30, "angle_raw / 16",
            fontsize=5.8, color=S.EDIT["teal"], ha="right", va="bottom")
    ax.text(-38, s16(d[COLS["s_dec"]][lo]) / 16.0 - 90, "s_dec / 16",
            fontsize=5.8, color=S.EDIT["teal"], va="top")
    ax.set_ylabel("code / 16 (LSB)")
    ax.set_xlim(-half, half)
    ax.set_xticklabels([])
    S.panel(ax, "b")

    ax = f.add_subplot(gs[2, 0])
    gl = d[COLS["glitch"]][lo:hi]
    ax.step(x, gl, where="mid", lw=1.0, color=S.INK)
    ax.set_ylim(-0.15, 1.35)
    ax.set_yticks([0, 1])
    idx_on = np.where(gl != 0)[0]
    if len(idx_on):
        t_on = x[idx_on[0]]
        ax.annotate("detected +%d cycles" % t_on, xy=(t_on, 1.0), xytext=(-8, 10),
                    textcoords="offset points", ha="right", fontsize=6.0,
                    arrowprops=dict(arrowstyle="->", lw=0.6, color=S.GREY))
    ax.set_ylabel("event flag")
    ax.set_xlabel("sample (relative to event)")
    ax.set_xlim(-half, half)
    S.panel(ax, "c")
    return S.save(f, os.path.join(FIGDIR, "fig_glitch_time"))


def _lattice_panel(ax, path, title, letter):
    d = load_csv(path)
    s = s12(d[COLS["s_raw"]])
    c = s12(d[COLS["c_raw"]])
    i0 = find_event(s)
    half = 100
    lo, hi = max(0, i0 - half), min(len(s), i0 + half + 1)
    xs, ys = s[lo:hi], c[lo:hi]
    j = i0 - lo
    keep = np.arange(len(xs)) != j
    x0, y0 = xs[keep].mean(), ys[keep].mean()
    span = 0.60 * max(float(np.ptp(xs[keep])), float(np.ptp(ys[keep])))

    gx0 = int(np.floor((x0 - span) / 256.0)) * 256
    gx1 = int(np.ceil((x0 + span) / 256.0)) * 256
    gy0 = int(np.floor((y0 - span) / 256.0)) * 256
    gy1 = int(np.ceil((y0 + span) / 256.0)) * 256
    for g in range(gx0, gx1 + 1, 256):
        ax.axvline(g, color=S.FAINT, lw=0.6, zorder=0)
    for g in range(gy0, gy1 + 1, 256):
        ax.axhline(g, color=S.FAINT, lw=0.6, zorder=0)

    xs_f = xs.astype(float).copy()
    ys_f = ys.astype(float).copy()
    xs_f[j] = np.nan
    ys_f[j] = np.nan
    ax.plot(xs_f, ys_f, "-", lw=0.9, color=S.EDIT["teal"], zorder=2)

    truth = int(round((s[i0 - 1] + s[i0 + 1]) / 2.0))
    ax.plot([truth], [c[i0]], "o", ms=4.2, mfc="white", mec=S.EDIT["brick"],
            mew=1.0, zorder=5)
    ax.annotate("corrupted sample\ns_raw = 0x%03X" % (s[i0] & 0xFFF),
                xy=(truth, c[i0]), xycoords="data", xytext=(0.03, 0.18),
                textcoords="axes fraction", fontsize=6.0, ha="left", va="top",
                arrowprops=dict(arrowstyle="->", lw=0.6, color=S.EDIT["brick"],
                                shrinkB=4))
    ax.set_aspect("equal", adjustable="box")
    ax.set_xlim(x0 - span, x0 + span)
    ax.set_ylim(y0 - span, y0 + span)
    ax.set_xlabel("s_raw (LSB)")
    ax.set_ylabel("c_raw (LSB)")
    ax.set_title(title, pad=4, loc="left")
    S.panel(ax, letter)


def lattice():
    S.apply()
    f = S.fig(140, 66)
    gs = f.add_gridspec(1, 2, wspace=0.28, left=0.065, right=0.985,
                        bottom=0.14, top=0.90)
    ax = f.add_subplot(gs[0, 0])
    _lattice_panel(ax, os.path.join(ROOT, "deliverables", "data", "ila", "ila_cap_v9_glitch1.csv"),
                   "Cluster A · truth (−1536, +518)", "a")
    ax = f.add_subplot(gs[0, 1])
    _lattice_panel(ax, os.path.join(ROOT, "deliverables", "data", "ila", "ila_cap_v9_g82_1.csv"),
                   "Cluster B · truth (−1024, −1280)", "b")
    return S.save(f, os.path.join(FIGDIR, "fig_lattice"))


def compare():
    S.apply()
    p9 = os.path.join(ROOT, "deliverables", "data", "ila", "ila_cmp_v9_glitch.csv")
    p11 = os.path.join(ROOT, "deliverables", "data", "ila", "ila_cmp_v11_clean.csv")
    d9 = load_csv(p9)
    d11 = load_csv(p11)
    i9 = find_event(s12(d9[COLS["s_raw"]]))
    i11 = find_event(s12(d11[COLS["s_raw"]]))
    half = 40

    f = S.fig(140, 81)
    gs = f.add_gridspec(3, 2, height_ratios=[2.0, 1.5, 1.0], hspace=0.16, wspace=0.18,
                        left=0.08, right=0.985, bottom=0.09, top=0.90)

    for col, (d, i0, tag) in enumerate([(d9, i9, "v9 · corrupted"), (d11, i11, "v11 · clean")]):
        s = s12(d[COLS["s_raw"]])
        c = s12(d[COLS["c_raw"]])
        lo, hi = max(0, i0 - half), min(len(s), i0 + half + 1)
        x = np.arange(lo, hi) - i0

        ax = f.add_subplot(gs[0, col])
        ax.plot(x, c[lo:hi], "-", lw=0.7, color=S.LIGHT)
        ax.plot(x, s[lo:hi], "-o", ms=1.4, lw=0.8, color=S.EDIT["teal"])
        ax.axvline(0, color=S.GREY, lw=0.6, ls=(0, (3, 2)))
        ax.set_xlim(-half, half)
        ax.set_ylabel("raw code (LSB)" if col == 0 else "")
        ax.set_title(tag, pad=3, loc="left")
        ax.set_xticklabels([])
        S.panel(ax, "a" if col == 0 else "b")
        if col == 0:
            ax.annotate("stuck 0x300", xy=(0, s[i0]), xytext=(6, 4),
                        textcoords="offset points", fontsize=6.0)

        ax = f.add_subplot(gs[1, col])
        ax.plot(x, s16(d[COLS["angle_raw"]][lo:hi]) / 16.0, "-", lw=0.9,
                color=S.EDIT["teal"])
        ax.axvline(0, color=S.GREY, lw=0.6, ls=(0, (3, 2)))
        ax.set_ylabel("angle_raw / 16" if col == 0 else "")
        ax.set_xlim(-half, half)
        ax.set_xticklabels([])


        ax = f.add_subplot(gs[2, col])
        ax.step(x, d[COLS["glitch"]][lo:hi], where="mid", lw=0.9, color=S.INK)
        ax.set_ylim(-0.15, 1.35)
        ax.set_yticks([0, 1])
        ax.set_xlim(-half, half)
        ax.set_xlabel("sample (relative to event)")
        ax.set_ylabel("event flag" if col == 0 else "")

    return S.save(f, os.path.join(FIGDIR, "fig_compare"))


ALL = {
    "mech": mech,
    "calib": calib,
    "residual": residual,
    "glitch": glitch_time,
    "lattice": lattice,
    "compare": compare,
}


def main(argv):
    names = argv[1:] or list(ALL)
    for n in names:
        print("saving", n, "->", ALL[n]())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
