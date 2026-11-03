# -*- coding: utf-8 -*-
"""Nature-style system architecture figure.

Design rules distilled from the Nature figure guide
(https://research-figure-guide.nature.com/figures/preparing-figures-our-specifications/):
  - Arial/Helvetica, 5-7 pt, black text, no coloured text
  - accessible Wong palette, no red/green pairs
  - thin uniform strokes, no shadows, no gradients, no 3D
  - direct labels and keylines; panel letters 8 pt bold lowercase
  - vector PDF with editable text (pdf.fonttype 42)

Output: deliverables/figures/fig1_system_architecture.{png,pdf,svg}
Canvas: 183 mm double column x 112 mm.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyArrowPatch
from matplotlib.lines import Line2D
import numpy as np
import os

plt.rcParams.update({
    "font.family": "Arial",
    "font.size": 7,
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
    "svg.fonttype": "none",
    "axes.linewidth": 0.6,
})

# Wong colour-blind-safe palette
BLUE = "#0072B2"
GREEN = "#009E73"
ORANGE = "#E69F00"
SKY = "#56B4E9"
VERM = "#D55E00"
GREY = "#4D4D4D"
LGREY = "#8C8C8C"


def tint(hex_color, f):
    """Mix a colour with white; f=0 -> white, f=1 -> colour."""
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    r = int(255 - (255 - r) * f)
    g = int(255 - (255 - g) * f)
    b = int(255 - (255 - b) * f)
    return f"#{r:02x}{g:02x}{b:02x}"


MM = 1 / 25.4
W, H = 183, 112
fig = plt.figure(figsize=(W * MM, H * MM))
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, W)
ax.set_ylim(0, H)
ax.axis("off")


def box(x, y, w, h, text, sub=None, color=GREY, fill=0.10, lw=0.8, fs=7, bold=False, align="center"):
    ax.add_patch(Rectangle((x, y), w, h, facecolor=tint(color, fill),
                           edgecolor=color, linewidth=lw, zorder=2))
    tx = x + w / 2 if align == "center" else x + 1.6
    ha = "center" if align == "center" else "left"
    if sub:
        ax.text(tx, y + h * 0.62, text, ha=ha, va="center", fontsize=fs,
                fontweight="bold" if bold else "normal", color="black", zorder=3)
        ax.text(tx, y + h * 0.28, sub, ha=ha, va="center", fontsize=fs - 1.3,
                color=GREY, zorder=3)
    else:
        ax.text(tx, y + h / 2, text, ha=ha, va="center", fontsize=fs,
                fontweight="bold" if bold else "normal", color="black", zorder=3)


def arrow(x1, y1, x2, y2, color=GREY, lw=0.8, head=7):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                                 mutation_scale=head, linewidth=lw,
                                 color=color, shrinkA=0, shrinkB=0, zorder=4))


def line(x1, y1, x2, y2, color=GREY, lw=0.8, ls="-"):
    ax.add_line(Line2D([x1, x2], [y1, y2], color=color, linewidth=lw,
                       linestyle=ls, zorder=1))


# ------------------------------------------------------------------ panel a
ax.text(3, 109, "a", fontsize=8, fontweight="bold", va="top")
ax.text(8, 108.2, "Sensor front end", fontsize=6.8, fontweight="bold", color="black", va="top")

# tiny sin/cos inset
ax_in = fig.add_axes([8 * MM / (W * MM), 92 * MM / (H * MM), 40 * MM / (W * MM), 10 * MM / (H * MM)])
t = np.linspace(0, 2 * np.pi, 300)
ax_in.plot(t, np.sin(t), color=BLUE, lw=0.9)
ax_in.plot(t, np.cos(t), color=ORANGE, lw=0.9)
ax_in.set_xlim(0, 2 * np.pi)
ax_in.set_ylim(-1.35, 1.35)
ax_in.axis("off")

ax.text(48, 105.0, "2048 cycles/rev", fontsize=5.6, color=GREY, ha="right", va="top")

box(8, 79, 40, 9, "SMR bridge", "sin/cos · differential 0.5 Vpp", color=ORANGE, fill=0.12, bold=True)
box(8, 65, 40, 9, "Analog front end", "diff→single · gain/offset · anti-alias", color=ORANGE, fill=0.08)
box(8, 51, 40, 9, "AD9238", "2 × 12 bit · 65 MSPS · offset binary", color=ORANGE, fill=0.08, bold=True)
arrow(28, 79, 28, 74.4, color=GREY)
arrow(28, 65, 28, 60.4, color=GREY)
arrow(48, 55.5, 55.5, 55.5, color=GREY)

# mechanical inset (magnet ring / sensor PCB / air gap)
ax.add_patch(Rectangle((10, 41.5), 36, 2.6, facecolor=tint(GREEN, 0.28), edgecolor=GREEN, lw=0.8))
ax.text(28, 45.0, "SMR sensor PCB", fontsize=5.4, ha="center", va="bottom", color="black")
ax.add_patch(Rectangle((12, 32.5), 32, 4.6, facecolor=tint(ORANGE, 0.30), edgecolor=ORANGE, lw=0.8))
ax.text(28, 34.8, "magnet ring · 2048 cycles/rev", fontsize=5.0, ha="center", va="center", color="black")
ax.add_patch(Rectangle((14, 26.0), 28, 2.8, facecolor=tint(GREY, 0.08), edgecolor=GREY, lw=0.7))
ax.text(28, 27.4, "shaft", fontsize=5.0, ha="center", va="center", color=GREY)
ax.add_patch(FancyArrowPatch((40.5, 32.5), (40.5, 41.5), arrowstyle="<|-|>",
                             mutation_scale=5, lw=0.7, color=GREY))
ax.text(39.8, 38.6, "air gap", fontsize=5.0, color=GREY, va="center", ha="right")


# ------------------------------------------------------------------ panel b
ax.text(57, 109, "b", fontsize=8, fontweight="bold", va="top")
ax.text(62, 107.0, "FPGA — one 50 MHz clock domain", fontsize=6.8, fontweight="bold", va="top")
ax.text(62, 103.2, "no MMCM · no CDC · fixed 41.5-cycle latency", fontsize=5.8, color=GREY, va="top")

stages = [
    ("Capture", "3 cyc"),
    ("÷4", "decimate"),
    ("Calib.", "6 params"),
    ("CORDIC", "17 stages"),
    ("PI", "type-II"),
    ("Unwrap", "incr."),
]
x0, y0, bw, bh, gap = 58, 84, 10.2, 12.5, 1.9
for i, (name, sub) in enumerate(stages):
    x = x0 + i * (bw + gap)
    box(x, y0, bw, bh, name, sub, color=BLUE, fill=0.10 if i not in (2, 3) else 0.16,
        fs=6.6, bold=False)
    if i:
        arrow(x - gap + 0.1, y0 + bh / 2, x - 0.15, y0 + bh / 2, head=6, lw=0.7)

ax.text(x0, 80.2, "→ 16-bit angle + speed + status word", fontsize=5.6, color=GREY, va="bottom")

# timing bar
bx0, bx1, by = 58, 129.5, 72.5
total = 41.5
adc = 7.0
sx = bx0 + (bx1 - bx0) * adc / total
ax.add_patch(Rectangle((bx0, by), sx - bx0, 3.2, facecolor=tint(ORANGE, 0.55),
                       edgecolor=ORANGE, linewidth=0.7, zorder=2))
ax.add_patch(Rectangle((sx, by), bx1 - sx, 3.2, facecolor=tint(BLUE, 0.35),
                       edgecolor=BLUE, linewidth=0.7, zorder=2))
for c in (0, 7, 41.5):
    px = bx0 + (bx1 - bx0) * c / total
    line(px, by - 0.8, px, by + 4.0, color=GREY, lw=0.6)
ax.text(bx0, by - 2.2, "0", fontsize=5.4, color=GREY, ha="center", va="top")
ax.text(sx, by - 2.2, "7", fontsize=5.4, color=GREY, ha="center", va="top")
ax.text(bx1, by - 2.2, "41.5", fontsize=5.4, color=GREY, ha="center", va="top")
ax.text((bx0 + sx) / 2, by + 4.4, "ADC (est.)", fontsize=5.4, color="black", ha="center")
ax.text((sx + bx1) / 2, by + 4.4, "FPGA pipeline", fontsize=5.4, color=BLUE, ha="center")
ax.text(bx1, by + 6.2, "≈ 830 ns", fontsize=6.2, color="black", ha="right", va="bottom")

# register / calibration / UI row
box(58, 52, 34, 9.5, "Register file", "UART → SPI · 2 Mbaud", color=GREY, fill=0.06, fs=6.4)
box(94.5, 52, 34, 9.5, "Calibration", "6 closed-form coefficients", color=GREY, fill=0.06, fs=6.4)
box(58, 39, 34, 9.5, "TFT controller", "1024 × 600 · 5 pages", color=GREY, fill=0.06, fs=6.4)
box(94.5, 39, 34, 9.5, "ILA / probes", "on-board observability", color=GREY, fill=0.06, fs=6.4)
line(110.5, 52, 110.5, 60.6, color=LGREY, lw=0.6, ls=(0, (2, 1.5)))


# ------------------------------------------------------------------ panel c
ax.text(137.5, 109, "c", fontsize=8, fontweight="bold", va="top")
ax.text(142, 104.5, "Protocol outputs", fontsize=6.8, fontweight="bold", va="top")

outs = [
    ("ABZ", "1–1024× · 65,536 edges/rev"),
    ("UVW + Z", "six-step · 12.00 Hz"),
    ("1 GbE UDP", "28,672 pts/frame"),
    ("UART / SPI", "2 Mbaud register access"),
    ("TFT panel", "1024 × 600 · 5 pages"),
]
oy = 94
for name, sub in outs:
    box(141, oy, 37, 8.2, name, sub, color=GREEN, fill=0.10, fs=6.4)
    oy -= 9.8

# output bus trunk
trunk_x = 132.5
line(129.8, 90.2, trunk_x, 90.2, color=GREY)
line(trunk_x, 34.1, trunk_x, 90.2, color=GREY)
for name, _ in outs:
    cy = 94 + 4.1 - outs.index((name, _)) * 9.8
    arrow(trunk_x, cy, 140.8, cy, head=5.5, lw=0.7)

box(141, 30, 37, 8.2, "Host PC", "UDP capture · calibration · soak", color=SKY, fill=0.12, fs=6.4)
arrow(trunk_x, 34.1, 140.8, 34.1, head=5.5, lw=0.7)

# ------------------------------------------------------------------ bottom note




ax.set_ylim(24.0, 112)

# save
out_dir = os.path.join("deliverables", "figures")
os.makedirs(out_dir, exist_ok=True)
for ext in ("png", "pdf", "svg"):
    p = os.path.join(out_dir, f"fig1_system_architecture.{ext}")
    fig.savefig(p, dpi=600 if ext == "png" else None, facecolor="white",
                bbox_inches="tight", pad_inches=0.02)
    print("saved", p, os.path.getsize(p))
