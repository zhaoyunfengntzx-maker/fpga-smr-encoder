# -*- coding: utf-8 -*-
"""Clean, large-type system-architecture diagram for the technical document."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from matplotlib import font_manager as fm

FONT = r"C:\Windows\Fonts\msyh.ttc"
fm.fontManager.addfont(FONT)
plt.rcParams["font.family"] = fm.FontProperties(fname=FONT).get_name()
plt.rcParams["axes.unicode_minus"] = False

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


# ---------------- left chain ----------------
left = [
    ("SMR 传感头", "正交 sin/cos · 2048 周期/转", 66),
    ("模拟前端", "差分→单端 · 0.5→8 Vpp", 49),
    ("AD9238", "2×12 bit · 65 MSPS", 32),
]
for name, sub, y in left:
    ax.add_patch(FancyBboxPatch((2, y), 30, 11.5, boxstyle="round,pad=0.25,rounding_size=1.0",
                                facecolor=GREEN, edgecolor=EDGE, lw=1.1))
    ax.text(17, y + 7.6, name, ha="center", va="center", fontsize=10.5, color=NAVY, fontweight="bold")
    ax.text(17, y + 3.4, sub, ha="center", va="center", fontsize=8.2, color=GREY)
for y in (66, 49):
    arrow(17, y, 17, y - 5.3)

# ---------------- FPGA ----------------
ax.add_patch(FancyBboxPatch((35, 14), 83, 72, boxstyle="round,pad=0.35,rounding_size=1.6",
                            facecolor="#F7F9FC", edgecolor=NAVY, lw=1.7))
ax.text(76.5, 81.0, "XC7A35TFGG484-2 · 单时钟域 50 MHz · 无 MMCM", ha="center", va="center",
        fontsize=10.2, color=NAVY, fontweight="bold")

stages = [("捕获", "3 拍"), ("÷4 抽取", "2.5 拍"), ("校正", "6 参数"),
          ("CORDIC", "17 级"), ("PI", "Ⅱ 型"), ("展开", "增量")]
x0, w, gap, y, h = 38.5, 11.2, 1.35, 57.0, 16.0
for i, (name, sub) in enumerate(stages):
    x = x0 + i * (w + gap)
    fc = AMBER_BG if name in ("校正", "CORDIC") else BLUE
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.2,rounding_size=0.9",
                                facecolor=fc, edgecolor=EDGE, lw=1.0))
    ax.text(x + w / 2, y + 10.6, name, ha="center", va="center", fontsize=9.2,
            color=NAVY, fontweight="bold")
    ax.text(x + w / 2, y + 4.2, sub, ha="center", va="center", fontsize=8.0, color=GREY)
    if i < 5:
        arrow(x + w, y + h / 2, x + w + gap, y + h / 2, lw=1.2)

ax.text(76.5, 51.0, "端到端 41.5 拍 ≈ 830 ns（设计预算，含 ADC 7 拍估计）",
        ha="center", va="center", fontsize=9.4, color=AMBER, fontweight="bold")

ax.text(76.5, 31.0,
        "50 MHz 晶振 · BUFG · ODDR 转发 ADC　|　寄存器/标定 · 触摸 UI · ILA",
        ha="center", va="center", fontsize=8.4, color=GREY)

arrow(32, 37.7, 35, 37.7, lw=1.8)

# ---------------- outputs ----------------
outs = [("ABZ 增量", "1–1024×"), ("UVW + Z", "六步 · 12 Hz"),
        ("1 GbE UDP", "28,672 点/帧"), ("UART / SPI", "2 Mbaud"), ("触摸屏", "1024×600")]
oy = 75.0
for i, (name, sub) in enumerate(outs):
    y = oy - i * 11.6
    ax.add_patch(FancyBboxPatch((123, y - 4.4), 34, 8.8,
                                boxstyle="round,pad=0.2,rounding_size=0.9",
                                facecolor=GREEN, edgecolor=EDGE, lw=1.0))
    ax.text(140, y + 1.1, name, ha="center", va="center", fontsize=9.4, color=NAVY, fontweight="bold")
    ax.text(140, y - 2.3, sub, ha="center", va="center", fontsize=7.8, color=GREY)

# bus
ax.plot([118.2, 120.6], [65.5, 65.5], color=AMBER, lw=1.5)
ax.plot([120.6, 120.6], [10.0, 65.5], color=AMBER, lw=1.5)
for i in range(len(outs)):
    y = oy - i * 11.6
    ax.plot([120.6, 123.0], [y, y], color=AMBER, lw=1.2)
    arrow(122.4, y, 123.0, y, lw=1.0)

# host PC
ax.add_patch(FancyBboxPatch((123, 2.0), 34, 8.2, boxstyle="round,pad=0.2,rounding_size=0.9",
                            facecolor="#EFE9F5", edgecolor=EDGE, lw=1.0))
ax.text(140, 7.4, "上位机 PC", ha="center", va="center", fontsize=9.4, color=NAVY, fontweight="bold")
ax.text(140, 4.4, "抓包 · 标定 · 长跑", ha="center", va="center", fontsize=7.8, color=GREY)
ax.plot([120.6, 123.0], [6.1, 6.1], color=AMBER, lw=1.2)

plt.tight_layout(pad=0.1)
out = os.path.join("deliverables", "figures", "sys_arch.png")
plt.savefig(out, bbox_inches="tight", facecolor="white")
print("saved", out)
