# -*- coding: utf-8 -*-
"""Nature-style schematics for the design report."""
import os
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyArrowPatch, Ellipse, Circle
import figstyle as S

S.apply()
FIG = os.path.join("deliverables", "figures")


def arrow(ax, p, q, lw=0.6, style="-|>", ms=5):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle=style, mutation_scale=ms,
                                 lw=lw, color=S.INK, shrinkA=0, shrinkB=0))


def pipeline():
    fig = S.fig(140, 46)
    ax = fig.add_axes([0.16, 0.24, 0.80, 0.62])
    stages = [
        ("ADC (7)", 0.0, 7.0, S.EDIT["cream"], S.EDIT["grey"]),
        ("Capture", 7.0, 10.0, S.EDIT["teal_l"], S.EDIT["teal"]),
        ("\u00f74 decim.", 10.0, 12.5, S.EDIT["teal_l"], S.EDIT["teal"]),
        ("Calibrate", 12.5, 15.5, S.EDIT["ochre_l"], S.EDIT["ochre"]),
        ("Guard", 15.5, 18.5, S.EDIT["cream"], S.EDIT["grey"]),
        ("CORDIC", 18.5, 37.5, S.EDIT["ochre_l"], S.EDIT["ochre"]),
        ("Type-II PI", 37.5, 40.5, S.EDIT["teal_l"], S.EDIT["teal"]),
        ("Unwrap", 40.5, 41.5, S.EDIT["teal_l"], S.EDIT["teal"]),
    ]
    for i, (name, a, b, fc, ec) in enumerate(stages):
        y = i
        ax.add_patch(Rectangle((a, y - 0.30), b - a, 0.60, facecolor=fc,
                               edgecolor=ec, lw=0.6))
        if b - a >= 2.4:
            ax.text((a + b) / 2, y, "%g" % (b - a), ha="center", va="center", fontsize=6.2)
        else:
            ax.text(b + 0.35, y, "%g" % (b - a), ha="left", va="center", fontsize=6.2)
    ax.set_yticks(range(len(stages)))
    ax.set_yticklabels([s[0] for s in stages], fontsize=6.2)
    ax.set_ylim(-1.5, len(stages) + 0.3)
    ax.set_xlim(0, 44.2)
    ax.set_xticks([0, 7, 10, 15.5, 18.5, 37.5, 41.5])
    ax.set_xlabel("time (cycles at 50 MHz)", fontsize=6.5)
    ax.tick_params(axis="x", labelsize=6)
    ax.spines["left"].set_visible(False)
    ax.tick_params(axis="y", length=0)
    ax.annotate("sample", xy=(0, 0.36), xytext=(0.2, -1.15), ha="left", fontsize=6,
                arrowprops=dict(arrowstyle="-|>", lw=0.6, color=S.INK))
    ax.annotate("16-bit angle", xy=(41.5, 7.36), xytext=(36.8, 8.25), ha="left", fontsize=6,
                arrowprops=dict(arrowstyle="-|>", lw=0.6, color=S.INK))
    ax.text(20.75, -1.1, "41.5 cycles \u2248 830 ns", ha="center", fontsize=6.6)
    S.save(fig, os.path.join(FIG, "fig_pipeline"))
    plt.close(fig)


def calib_geometry():
    fig = S.fig(89, 50)
    ax = fig.add_axes([0.06, 0.12, 0.38, 0.80])
    t = np.linspace(0, 2 * np.pi, 400)
    a, b, phi = 1.22, 0.78, np.deg2rad(18)
    cx, cy = 0.16, -0.10
    x = cx + a * np.cos(t) * np.cos(phi) - b * np.sin(t) * np.sin(phi)
    y = cy + a * np.cos(t) * np.sin(phi) + b * np.sin(t) * np.cos(phi)
    ax.plot(x, y, color=S.EDIT["ochre"], lw=1.0)
    ax.plot(np.cos(t), np.sin(t), color=S.GREY, lw=0.6, ls=(0, (3, 2)))
    ax.annotate("", xy=(cx, cy), xytext=(-0.9, -0.95),
                arrowprops=dict(arrowstyle="-|>", lw=0.6, color=S.INK))
    ax.text(-0.92, -1.05, "offset", fontsize=5.8, ha="left")
    ax.plot([cx, cx + a * np.cos(phi)], [cy, cy + a * np.sin(phi)],
            color=S.INK, lw=0.5)
    ax.text(cx + 0.55, cy + 0.42, "gain", fontsize=5.8)
    ax.set_xlim(-1.5, 1.6)
    ax.set_ylim(-1.5, 1.5)
    ax.set_aspect("equal")
    ax.set_xticks([-1, 0, 1])
    ax.set_yticks([-1, 0, 1])
    ax.set_xlabel("cos", fontsize=6)
    ax.set_ylabel("sin", fontsize=6)
    S.panel(ax, "a", x=-0.22, y=1.02)

    ax = fig.add_axes([0.58, 0.12, 0.38, 0.80])
    ax.plot(np.cos(t), np.sin(t), color=S.EDIT["teal"], lw=1.0)
    ax.plot([0], [0], marker="+", ms=4, color=S.GREY, mew=0.6)
    ax.set_xlim(-1.5, 1.6)
    ax.set_ylim(-1.5, 1.5)
    ax.set_aspect("equal")
    ax.set_xticks([-1, 0, 1])
    ax.set_yticks([-1, 0, 1])
    ax.set_xlabel("cos", fontsize=6)
    S.panel(ax, "b", x=-0.22, y=1.02)

    fig.text(0.50, 0.50, "\u2192", fontsize=11, ha="center", va="center")
    fig.text(0.50, 0.40, "closed-form", fontsize=5.6, ha="center")
    fig.text(0.50, 0.34, "solve", fontsize=5.6, ha="center")
    S.save(fig, os.path.join(FIG, "fig_calib_geometry"))
    plt.close(fig)


def abz_uvw():
    fig = S.fig(140, 60)
    ax = fig.add_axes([0.09, 0.56, 0.88, 0.36])
    ang = np.linspace(0, 720, 3000)
    traces = [("U", (ang % 360 < 180)), ("V", ((ang - 120) % 360 < 180)),
              ("W", ((ang - 240) % 360 < 180))]
    for i, (name, hi) in enumerate(traces):
        y = 2 - i
        ax.plot(ang, y + 0.34 * hi.astype(float), color=S.INK, lw=0.8)
        ax.text(-14, y + 0.17, name, fontsize=6.2, ha="right", va="center")
    for k in range(6):
        ax.text(60 + 120 * k, -0.55, str(k + 1), ha="center", va="center",
                fontsize=5.2, color=S.GREY)
    ax.set_xlim(0, 720)
    ax.set_ylim(-0.75, 2.7)
    ax.set_yticks([])
    ax.set_xticks([0, 120, 240, 360, 480, 600, 720])
    ax.set_xlabel("electrical angle (deg)", fontsize=6.2)
    ax.tick_params(axis="x", labelsize=6)
    S.panel(ax, "a", x=-0.09, y=1.02)

    ax = fig.add_axes([0.09, 0.12, 0.88, 0.30])
    z = np.linspace(0, 45, 2000)
    per = 11.25
    A = ((z % per) < per / 2).astype(float)
    B = (((z - per / 4) % per) < per / 2).astype(float)
    Z = (z < 1.2).astype(float)
    for i, (name, sig) in enumerate([("Z", Z), ("A", A), ("B", B)]):
        y = 2 - i
        ax.plot(z, y + 0.34 * sig, color=S.INK, lw=0.8)
        ax.text(-2.2, y + 0.17, name, fontsize=6.2, ha="right", va="center")
    ax.set_xlim(0, 45)
    ax.set_ylim(-0.3, 2.7)
    ax.set_yticks([])
    ax.set_xticks([0, 11.25, 22.5, 33.75, 45])
    ax.set_xlabel("electrical angle (deg), zoom", fontsize=6.2)
    ax.tick_params(axis="x", labelsize=6)
    ax.annotate("90\u00b0 phase", xy=(per / 4, 0.17), xytext=(7.5, 1.55),
                fontsize=5.8, arrowprops=dict(arrowstyle="-|>", lw=0.5, color=S.GREY))
    S.panel(ax, "b", x=-0.09, y=1.04)
    S.save(fig, os.path.join(FIG, "fig_abz_uvw"))
    plt.close(fig)




def cordic():
    fig = S.fig(140, 52)
    ax = fig.add_axes([0.07, 0.15, 0.36, 0.76])
    th = np.deg2rad(55)
    ax.plot([0, np.cos(th)], [0, np.sin(th)], color=S.EDIT["teal"], lw=1.2)
    ax.plot([0, 1], [0, 0], color=S.GREY, lw=0.6, ls=(0, (3, 2)))
    ax.plot([np.cos(th), np.cos(th)], [0, np.sin(th)], color=S.GREY, lw=0.5, ls=":")
    ax.plot([0, np.cos(th)], [np.sin(th), np.sin(th)], color=S.GREY, lw=0.5, ls=":")
    ant = np.linspace(0, th, 120)
    ax.plot(0.35 * np.cos(ant), 0.35 * np.sin(ant), color=S.EDIT["ochre"], lw=0.8)
    ax.text(0.35, 0.08, "θ", fontsize=7, color=S.EDIT["ochre"])
    ax.text(0.62, 0.86, "(x0, y0)", fontsize=6.2)
    ax.text(0.72, 0.05, "x", fontsize=6.2)
    ax.set_xlim(-0.15, 1.15)
    ax.set_ylim(-0.15, 1.15)
    ax.set_aspect("equal")
    ax.set_xticks([0, 1])
    ax.set_yticks([0, 1])
    S.panel(ax, "a", x=-0.20, y=1.02)

    ax = fig.add_axes([0.56, 0.15, 0.40, 0.76])
    atans = np.arctan(2.0 ** (-np.arange(0, 20)))
    grid = np.deg2rad(np.linspace(0.5, 89.5, 180))
    errs = []
    for n in range(1, 20):
        m = 0.0
        for a0 in grid:
            z = a0
            acc = 0.0
            for i in range(n):
                d = 1.0 if z >= 0 else -1.0
                acc += d * atans[i]
                z -= d * atans[i]
            d_err = (acc - a0 + np.pi) % (2 * np.pi) - np.pi
            m = max(m, abs(d_err))
        errs.append(np.rad2deg(m))
    ax.semilogy(range(1, 20), errs, "o-", ms=2.4, lw=0.8, color=S.EDIT["teal"])
    ax.axhline(360 / 65536, color=S.EDIT["ochre"], lw=0.7, ls=(0, (3, 2)))
    ax.text(1.2, 360 / 65536 * 1.25, "1 LSB (16 bit)", fontsize=5.8, color=S.EDIT["ochre"])
    ax.set_xlabel("iteration (stage)", fontsize=6.4)
    ax.set_ylabel("max residual (deg), |θ| ≤ 90°", fontsize=6.2)
    ax.set_xlim(0, 20)
    ax.set_ylim(1e-4, 20)
    ax.tick_params(labelsize=6)
    S.panel(ax, "b", x=-0.18, y=1.02)
    S.save(fig, os.path.join(FIG, "fig_cordic"))
    plt.close(fig)


def verify():
    fig = S.fig(140, 34)
    ax = fig.add_axes([0.02, 0.06, 0.96, 0.82])
    ax.axis("off")
    steps = [
        ("Fixed-point\nmodel", "bit-exact\nvs RTL"),
        ("RTL", "24 modules\n+ 8 eth"),
        ("57 benches", "37/37 + 20/20"),
        ("Build sign-off", "WNS +0.199 ns\n24,691 endpoints"),
        ("Board", "five criteria\n597,886 frames"),
    ]
    n = len(steps)
    w, gap = 0.160, 0.040
    for i, (title, sub) in enumerate(steps):
        x = 0.02 + i * (w + gap)
        ax.add_patch(Rectangle((x, 0.42), w, 0.34, facecolor="white",
                               edgecolor=S.INK, lw=0.6, transform=ax.transAxes))
        ax.text(x + w / 2, 0.66, title, ha="center", va="center", fontsize=6.4,
                transform=ax.transAxes, fontweight="bold")
        ax.text(x + w / 2, 0.51, sub, ha="center", va="center", fontsize=5.6,
                color=S.GREY, transform=ax.transAxes)
        if i < n - 1:
            arrow(ax, (x + w + 0.006, 0.59), (x + w + gap - 0.006, 0.59), ms=4)
    ax.text(0.02, 0.18, "320 evidence files  \u00b7  323 SHA-256 lines  \u00b7  one-command sign-off",
            fontsize=6.2, color=S.GREY, transform=ax.transAxes)
    S.save(fig, os.path.join(FIG, "fig_verify_chain"))
    plt.close(fig)


if __name__ == "__main__":
    pipeline()
    calib_geometry()
    abz_uvw()
    cordic()
    verify()
    print("done")
