# -*- coding: utf-8 -*-
"""Combined calibration + residual figure (Nature multi-panel)."""
import os
import numpy as np
import pandas as pd
import figstyle as S

S.apply()
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FIG = os.path.join(ROOT, "deliverables", "figures")


def main():
    before = pd.read_csv(os.path.join(ROOT, "deliverables", "data", "lissajous_before_distortion.csv"),
                         encoding="utf-8-sig")
    after = pd.read_csv(os.path.join(ROOT, "deliverables", "data", "lissajous_after_distortion.csv"),
                        encoding="utf-8-sig")

    def radius(d):
        r = np.hypot(d["s"].values, d["c"].values)
        return 100.0 * r.std() / r.mean(), r

    cv_b, r_b = radius(before)
    cv_a, r_a = radius(after)

    f = S.fig(165, 98)
    gs = f.add_gridspec(2, 3, height_ratios=[1.0, 1.05], hspace=0.50, wspace=0.38,
                        left=0.055, right=0.985, bottom=0.08, top=0.93)

    for k, (d, title, color, letter, cvv) in enumerate([
            (before, "Before", S.EDIT["ochre"], "a", cv_b),
            (after, "After", S.EDIT["teal"], "b", cv_a)]):
        ax = f.add_subplot(gs[0, k])
        ax.plot(d["s"].values, d["c"].values, "-", lw=0.25, color=color, alpha=0.85,
                rasterized=True)
        ax.set_aspect("equal", adjustable="box")
        ax.set_xlabel("s (LSB)")
        if k == 0:
            ax.set_ylabel("c (LSB)")
        ax.set_title(title, pad=3, loc="left")
        ax.set_xticks([-30000, 0, 30000])
        ax.set_yticks([-30000, 0, 30000])
        ax.text(0.04, 0.04, "CV %.2f%%" % cvv, transform=ax.transAxes, fontsize=5.8,
                color=S.INK, va="bottom")
        S.panel(ax, letter, x=-0.18, y=1.04)

    ax = f.add_subplot(gs[0, 2])
    bins = np.linspace(15000, 35000, 121)
    ax.hist(r_b, bins=bins, density=True, histtype="step", lw=0.9, color=S.EDIT["ochre"])
    ax.hist(r_a, bins=bins, density=True, histtype="step", lw=0.9, color=S.EDIT["teal"])
    ax.set_xlabel("radius (LSB)")
    ax.set_ylabel("density")
    ax.set_title("Radius", pad=3, loc="left")
    ax.set_xlim(15000, 35000)
    ax.set_ylim(bottom=0)
    ax.text(17200, 0.00038, "before", fontsize=5.8, color=S.INK)
    ax.annotate("after", xy=(26300, 0.0042), xytext=(28700, 0.0034), fontsize=5.8,
                color=S.INK,
                arrowprops=dict(arrowstyle="-", lw=0.6, color=S.GREY))
    S.panel(ax, "c", x=-0.18, y=1.04)

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

    ax = f.add_subplot(gs[1, 0:2])
    ax.axhspan(-0.13, 0.13, color=S.FAINT, zorder=0, lw=0)
    ax.axhline(0, color=S.LIGHT, lw=0.6, zorder=1)
    ax.plot(bin_ang, bin_val, "o", ms=2.4, color=S.EDIT["teal"], mfc="white", mew=0.8, zorder=3)
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
    ax.set_title("Angle residual, 16 bins (\u22120.125\u2026+0.119\u00b0) + fit", pad=3, loc="left")
    S.panel(ax, "d", x=-0.10, y=1.04)

    ax = f.add_subplot(gs[1, 2])
    ks = np.arange(1, 6)
    cols = [S.EDIT["teal"]] * 5
    cols[3] = S.EDIT["ochre"]
    ax.bar(ks, spec[1:6], width=0.62, color=cols, edgecolor="none")
    for k, v in zip(ks, spec[1:6]):
        ax.text(k, v + 0.003, "%.3f" % v, ha="center", va="bottom", fontsize=5.8)
    ax.set_xticks(ks)
    ax.set_xlabel("harmonic order")
    ax.set_ylabel("amplitude (deg)")
    ax.set_ylim(0, 0.115)
    ax.set_title("Harmonics", pad=3, loc="left")
    S.panel(ax, "e", x=-0.18, y=1.04)

    S.save(f, os.path.join(FIG, "fig_calibration_summary"))


if __name__ == "__main__":
    main()
