# -*- coding: utf-8 -*-
"""Nature-journal figure style shared by all project figures.

Specs distilled from Nature's figure guidelines:
  * Arial / Helvetica, body 5-7 pt, panel letters 8 pt bold lowercase
  * black text only; colour used for data, never for words
  * no grid lines, shadows, gradients, patterns or 3-D effects
  * thin (0.6-0.8 pt) strokes, small solid arrow heads
  * double-column width 183 mm, single column 89 mm
  * vector PDF with pdf.fonttype = 42 (editable text)
"""
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import rcParams

# Okabe-Ito / Wong colour-blind-safe palette
WONG = {
    "black": "#000000",
    "orange": "#E69F00",
    "sky": "#56B4E9",
    "green": "#009E73",
    "yellow": "#F0E442",
    "blue": "#0072B2",
    "vermillion": "#D55E00",
    "purple": "#CC79A7",
}
INK = "#1A1A1A"
EDIT = {
    "navy": "#1B2A41",
    "teal": "#2A6F6B",
    "teal_l": "#D8E8E3",
    "ochre": "#B08018",
    "ochre_l": "#F1E3BF",
    "brick": "#96473B",
    "slate": "#3E4C59",
    "grey": "#8B939C",
    "cream": "#FAF7EF",
}
GREY = "#6E6E6E"
LIGHT = "#D9D9D9"
FAINT = "#EDEDED"

MM = 1.0 / 25.4


def apply():
    rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["Arial", "Helvetica", "DejaVu Sans"],
        "font.size": 7,
        "axes.labelsize": 7,
        "axes.titlesize": 7.2,
        "xtick.labelsize": 6.5,
        "ytick.labelsize": 6.5,
        "axes.linewidth": 0.6,
        "axes.edgecolor": INK,
        "xtick.major.width": 0.6,
        "ytick.major.width": 0.6,
        "xtick.major.size": 2.6,
        "ytick.major.size": 2.6,
        "xtick.direction": "out",
        "ytick.direction": "out",
        "axes.spines.top": False,
        "axes.spines.right": False,
        "legend.frameon": False,
        "legend.fontsize": 6.2,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
        "svg.fonttype": "none",
        "axes.unicode_minus": False,
        "figure.facecolor": "white",
        "savefig.facecolor": "white",
    })


def fig(w_mm, h_mm):
    return plt.figure(figsize=(w_mm * MM, h_mm * MM))


def panel(ax, letter, x=-0.10, y=1.03):
    ax.text(x, y, letter, transform=ax.transAxes, ha="right", va="bottom",
            fontsize=8, fontweight="bold", color=INK)


def label_line(ax, x, y, text, color=INK, ha="left", va="center", dx=1.5, **kw):
    """Place a label right next to a line end (data coordinates)."""
    ax.annotate(text, xy=(x, y), xytext=(dx, 0), textcoords="offset points",
                color=color, ha=ha, va=va, fontsize=6.2, **kw)


def save(fig_obj, stem, dpi=600):
    os.makedirs(os.path.dirname(stem) or ".", exist_ok=True)
    for ext in ("pdf", "png", "svg"):
        fig_obj.savefig(stem + "." + ext, dpi=dpi, bbox_inches="tight",
                        pad_inches=0.02, facecolor="white")
    return stem
