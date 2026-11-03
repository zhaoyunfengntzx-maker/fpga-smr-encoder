# -*- coding: utf-8 -*-
"""English system-architecture diagram, used by the AMD-template poster."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from matplotlib import font_manager as fm

FONT = r"C:\Windows\Fonts\arial.ttf"
fm.fontManager.addfont(FONT)
plt.rcParams["font.family"] = "Arial"

NAVY = "#0B2545"
AMBER = "#C98612"
BLUE = "#E8EEF7"
GREEN = "#E6F2EC"
AMBER_BG = "#FBF1DE"
GREY = "#5B6778"
EDGE = "#9AA9BC"

fig, ax = plt.subplots(figsize=(7.9, 4.35), dpi=300)
ax.set_xlim(0, 160)
ax.set_ylim(0, 90)
ax.axis("off")


def arrow(x1, y1, x2, y2, color=AMBER, lw=1.6):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                                 mutation_scale=10, color=color, lw=lw))


left = [
    ("SMR sensor head", "sin/cos · 2048 cycles/rev", 66),
    ("Analog front end", "diff→single · 0.5→8 Vpp", 49),
    ("AD9238", "2×12 bit · 65 MSPS", 32),
]
for name, sub, y in left:
    ax.add_patch(FancyBboxPatch((2, y), 30, 11.5, boxstyle="round,pad=0.25,rounding_size=1.0",
                                facecolor=GREEN, edgecolor=EDGE, lw=1.1))
    ax.text(17, y + 7.5, name, ha="center", va="center", fontsize=8.8, color=NAVY, fontweight="bold")
    ax.text(17, y + 3.4, sub, ha="center", va="center", fontsize=7.4, color=GREY)
for y in (66, 49):
    arrow(17, y, 17, y - 5.3)

ax.add_patch(FancyBboxPatch((35, 14), 83, 72, boxstyle="round,pad=0.35,rounding_size=1.6",
                            facecolor="#F7F9FC", edgecolor=NAVY, lw=1.7))
ax.text(76.5, 81.0, "XC7A35TFGG484-2 · single 50 MHz clock · no MMCM", ha="center", va="center",
        fontsize=9.2, color=NAVY, fontweight="bold")

stages = [("Capture", "3 cyc"), ("÷4 decim", "2.5 cyc"), ("Calibrate", "6 params"),
          ("CORDIC", "17 stages"), ("PI", "type-II"), ("Unwrap", "incremental")]
x0, w, gap, y, h = 38.5, 11.2, 1.35, 57.0, 16.0
for i, (name, sub) in enumerate(stages):
    x = x0 + i * (w + gap)
    fc = AMBER_BG if name in ("Calibrate", "CORDIC") else BLUE
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.2,rounding_size=0.9",
                                facecolor=fc, edgecolor=EDGE, lw=1.0))
    ax.text(x + w / 2, y + 10.6, name, ha="center", va="center", fontsize=8.0,
            color=NAVY, fontweight="bold")
    ax.text(x + w / 2, y + 4.2, sub, ha="center", va="center", fontsize=6.9, color=GREY)
    if i < 5:
        arrow(x + w, y + h / 2, x + w + gap, y + h / 2, lw=1.2)

ax.text(76.5, 51.0, "41.5 cycles ≈ 830 ns end to end (design budget, incl. 7-cycle ADC)",
        ha="center", va="center", fontsize=8.4, color=AMBER, fontweight="bold")

ax.text(76.5, 31.0,
        "50 MHz XO · BUFG · ODDR forwards ADC clock   |   registers / calib · touch UI · ILA",
        ha="center", va="center", fontsize=7.6, color=GREY)

arrow(32, 37.7, 35, 37.7, lw=1.8)

outs = [("ABZ pulses", "1–1024×"), ("UVW + Z", "six-step · 12 Hz"),
        ("1 GbE UDP", "28,672 pts/frame"), ("UART / SPI", "2 Mbaud"), ("TFT panel", "1024×600")]
oy = 75.0
for i, (name, sub) in enumerate(outs):
    y = oy - i * 11.6
    ax.add_patch(FancyBboxPatch((123, y - 4.4), 34, 8.8,
                                boxstyle="round,pad=0.2,rounding_size=0.9",
                                facecolor=GREEN, edgecolor=EDGE, lw=1.0))
    ax.text(140, y + 1.1, name, ha="center", va="center", fontsize=8.4, color=NAVY, fontweight="bold")
    ax.text(140, y - 2.3, sub, ha="center", va="center", fontsize=6.9, color=GREY)

ax.plot([118.2, 120.6], [65.5, 65.5], color=AMBER, lw=1.5)
ax.plot([120.6, 120.6], [10.0, 65.5], color=AMBER, lw=1.5)
for i in range(len(outs)):
    y = oy - i * 11.6
    ax.plot([120.6, 123.0], [y, y], color=AMBER, lw=1.2)
    arrow(122.4, y, 123.0, y, lw=1.0)

ax.add_patch(FancyBboxPatch((123, 2.0), 34, 8.2, boxstyle="round,pad=0.2,rounding_size=0.9",
                            facecolor="#EFE9F5", edgecolor=EDGE, lw=1.0))
ax.text(140, 7.4, "Host PC", ha="center", va="center", fontsize=8.4, color=NAVY, fontweight="bold")
ax.text(140, 4.4, "capture · calib · soak", ha="center", va="center", fontsize=6.9, color=GREY)
ax.plot([120.6, 123.0], [6.1, 6.1], color=AMBER, lw=1.2)

plt.tight_layout(pad=0.1)
out = os.path.join("deliverables", "figures", "sys_arch_en.png")
plt.savefig(out, bbox_inches="tight", facecolor="white")
print("saved", out)
