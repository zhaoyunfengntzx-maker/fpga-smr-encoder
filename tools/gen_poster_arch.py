# -*- coding: utf-8 -*-
"""Poster architecture: single-panel Nature-style signal chain, legible at 9.9 cm."""
import os
import math
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Polygon, FancyArrowPatch
from matplotlib import font_manager as fm

FONT = r"C:\Windows\Fonts\arial.ttf"
if os.path.exists(FONT):
    fm.fontManager.addfont(FONT)
    plt.rcParams["font.family"] = "Arial"
plt.rcParams["pdf.fonttype"] = 42
plt.rcParams["axes.unicode_minus"] = False

INK = "#1A1A1A"
GREY = "#6B7280"
NAVY = "#0B2545"
BLUE = "#2B6CA3"
AMBER = "#B97C12"
GREEN = "#2E7D4F"

fig, ax = plt.subplots(figsize=(4.4, 1.78), dpi=600)
fig.subplots_adjust(0, 0, 1, 1)
ax.set_xlim(0, 100)
ax.set_ylim(0, 40)
ax.axis("off")


def rect(x, y, w, h, ec=GREY, lw=0.55, accent=None):
    ax.add_patch(Rectangle((x, y), w, h, facecolor="white", edgecolor=ec, linewidth=lw, zorder=2))
    if accent:
        ax.plot([x + 0.5, x + w - 0.5], [y + h - 0.35, y + h - 0.35],
                color=accent, lw=1.4, solid_capstyle="round", zorder=3)


def arrow(x1, y1, x2, y2):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>", mutation_scale=4.2,
                                 lw=0.6, color=INK, shrinkA=0.5, shrinkB=0.5, zorder=4))


def label(x, y, s, size=7.0, color=INK, ha="center", va="center", weight="normal"):
    ax.text(x, y, s, ha=ha, va=va, fontsize=size, color=color, fontweight=weight, zorder=5)


rect(1.2, 21.5, 11.6, 12.0, accent=GREEN)
xs = [2.6 + 8.8 * i / 30.0 for i in range(31)]
ys = [28.5 + 1.8 * math.sin(2 * math.pi * 2 * i / 30.0) for i in range(31)]
ax.plot(xs, ys, color=GREEN, lw=0.8, zorder=3)
label(7.0, 34.3, "SMR bridge", 6.6)
label(7.0, 19.2, "2048 cyc/rev", 5.6, GREY)

rect(15.2, 21.5, 11.6, 12.0, accent=GREEN)
ax.add_patch(Polygon([[17.8, 23.4], [24.2, 27.5], [17.8, 31.6]], closed=True,
                     facecolor="white", edgecolor=GREEN, lw=0.7, zorder=3))
label(21.0, 34.3, "Front end", 6.6)
label(21.0, 19.2, "0.5\u21928 Vpp", 5.6, GREY)

rect(29.2, 21.5, 11.6, 12.0, accent=GREEN)
for i, h in enumerate([0.8, 1.6, 2.4, 3.2, 4.0]):
    ax.plot([30.8 + i * 1.7, 30.8 + (i + 1) * 1.7], [24.0 + h, 24.0 + h],
            color=GREEN, lw=0.8, zorder=3)
    if i < 4:
        ax.plot([30.8 + (i + 1) * 1.7] * 2, [24.0 + h, 24.0 + h + 0.8],
                color=GREEN, lw=0.8, zorder=3)
label(35.0, 34.3, "AD9238", 6.6)
label(35.0, 19.2, "12 b, 65 MS/s", 5.6, GREY)

arrow(12.9, 27.5, 15.0, 27.5)
arrow(26.9, 27.5, 29.0, 27.5)
arrow(40.9, 27.5, 43.4, 27.5)

ax.add_patch(Rectangle((43.6, 11.5), 34.4, 25.5, facecolor="none",
                       edgecolor=NAVY, linewidth=0.8, zorder=1))
label(44.8, 35.2, "Artix-7  \u00b7  one 50 MHz clock", 6.8, NAVY, ha="left", weight="bold")


def stage(x, y, w, name, cyc, accent):
    rect(x, y, w, 7.0, ec="#9AA4B2", accent=accent)
    label(x + w / 2, y + 4.35, name, 6.4)
    label(x + w / 2, y + 2.15, cyc, 5.6, GREY)


stage(44.8, 25.8, 10.6, "Capture", "3 cyc", BLUE)
stage(56.4, 25.8, 10.6, "\u00f74 decim.", "2.5 cyc", BLUE)
stage(68.0, 25.8, 9.6, "Calibrate", "6 params", AMBER)
arrow(55.6, 29.3, 56.2, 29.3)
arrow(67.2, 29.3, 67.8, 29.3)

ax.plot([72.8, 72.8], [25.8, 22.0], color=INK, lw=0.6, zorder=3)
ax.plot([72.8, 50.1], [22.0, 22.0], color=INK, lw=0.6, zorder=3)
arrow(50.1, 22.0, 50.1, 19.6)

stage(44.8, 12.6, 10.6, "CORDIC", "17 st / 19", AMBER)
stage(56.4, 12.6, 10.6, "Type-II PI", "3 cyc", BLUE)
stage(68.0, 12.6, 9.6, "Unwrap", "1 cyc", BLUE)
arrow(55.6, 16.1, 56.2, 16.1)
arrow(67.2, 16.1, 67.8, 16.1)

outs = [("ABZ", "1\u20131024\u00d7", 31.5), ("UVW + Z", "six-step", 23.5),
        ("SPI slave", "32 b regs", 15.5), ("1 GbE UDP", "28,672 pts", 7.5)]
for name, sub, yy in outs:
    label(80.6, yy + 0.9, name, 6.4, INK, ha="left")
    label(80.6, yy - 1.3, sub, 5.4, GREY, ha="left")
    arrow(78.4, yy, 80.2, yy)
ax.plot([78.4, 78.4], [7.5, 31.5], color=INK, lw=0.6, zorder=3)

label(3.0, 3.2, "Synchronous dual-channel acquisition \u00b7 single 50 MHz clock \u00b7 41.5 cycles \u2248 830 ns (incl. ADC)",
      5.6, GREY, ha="left")

out = os.path.join("deliverables", "figures", "poster_arch.png")
plt.savefig(out, facecolor="white")
print("saved", out)
