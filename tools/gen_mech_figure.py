# -*- coding: utf-8 -*-
"""Mechanical assembly schematic (large-type version for the technical document)."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyBboxPatch
from matplotlib import font_manager as fm
import os

FONT = r"C:\Windows\Fonts\msyh.ttc"
fm.fontManager.addfont(FONT)
plt.rcParams["font.family"] = fm.FontProperties(fname=FONT).get_name()
plt.rcParams["axes.unicode_minus"] = False

NAVY = "#0B2545"
AMBER = "#C98612"
STEEL = "#DCE3EC"
STEEL_D = "#9AA9BC"
PCB = "#1E6B52"
GREY = "#5B6778"

fig, ax = plt.subplots(figsize=(7.2, 3.35), dpi=300)
ax.set_xlim(0, 100)
ax.set_ylim(0, 46)
ax.axis("off")

# base
ax.add_patch(FancyBboxPatch((4, 4), 92, 7.5, boxstyle="round,pad=0.2,rounding_size=0.8",
                            facecolor=STEEL, edgecolor=STEEL_D, lw=1.4))
ax.text(50, 7.7, "定子 / 非磁性底座", ha="center", va="center", fontsize=12.5, color=GREY)

# shaft
ax.add_patch(Rectangle((8, 21), 84, 6.5, facecolor="#C9D2DE", edgecolor=STEEL_D, lw=1.4))
ax.add_patch(Rectangle((8, 21), 84, 1.6, facecolor="#EFF3F8", edgecolor="none"))
ax.text(13, 24.3, "转台主轴", ha="left", va="center", fontsize=13, color=NAVY)

# bearings
for x in (16, 74):
    ax.add_patch(Rectangle((x, 12.5), 9, 8.5, facecolor="#B9C4D2", edgecolor=STEEL_D, lw=1.2))
ax.text(20.5, 16.7, "轴承", ha="center", va="center", fontsize=11, color=GREY)
ax.text(78.5, 16.7, "轴承", ha="center", va="center", fontsize=11, color=GREY)

# hub + ring
ax.add_patch(Rectangle((39, 27.5), 22, 9.5, facecolor="#E8EDF4", edgecolor=STEEL_D, lw=1.4))
ax.text(50, 32.2, "轴套 / 同轴定心", ha="center", va="center", fontsize=11.5, color=GREY)
ax.add_patch(Rectangle((41, 37), 18, 4.2, facecolor=AMBER, edgecolor="#8A5A08", lw=1.4))
ax.text(50, 39.1, "磁环  2048 周期", ha="center", va="center", fontsize=10.8, color="white", fontweight="bold")

# sensor PCB
ax.add_patch(Rectangle((32, 43.3), 36, 2.6, facecolor=PCB, edgecolor="#0E3D2F", lw=1.4))
ax.add_patch(Rectangle((45.5, 43.3), 9, 2.6, facecolor="#123B2E", edgecolor="#7FD1B0", lw=1.8))
ax.text(50, 47.4, "SMR 传感头（PCB）", ha="center", va="center", fontsize=12.5, color=NAVY, fontweight="bold")
ax.text(50, 44.6, "SMR", ha="center", va="center", fontsize=9.5, color="#9FE6C8")

# air gap
ax.annotate("", xy=(61.5, 43.2), xytext=(61.5, 41.3),
            arrowprops=dict(arrowstyle="<->", color=AMBER, lw=2.2))
ax.text(65.5, 40.4, "气隙\n（垫片设定）", ha="left", va="center", fontsize=11, color=AMBER)

plt.tight_layout(pad=0.1)
out = os.path.join("deliverables", "figures", "mech_assembly.png")
plt.savefig(out, bbox_inches="tight", facecolor="white")
print("saved", out)
