# -*- coding: utf-8 -*-
"""Report figures, round 2: principle schematics for the template report.

Palette: ink #1b2a3a, accent #2f6f8f, light fill #e9eff5, grid #c9d4de.
All text is plain ASCII/CJK (no U+2212, no caret superscripts) so SimSun covers it.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
from matplotlib.ticker import NullLocator

OUT = Path("deliverables/figures")
OUT.mkdir(parents=True, exist_ok=True)

INK = "#1b2a3a"
ACC = "#2f6f8f"
FILL = "#e9eff5"
GRID = "#c9d4de"
RED = "#b4453f"

plt.rcParams.update({
    "font.family": "SimSun",
    "axes.unicode_minus": False,
    "font.size": 8.5,
    "axes.edgecolor": INK,
    "axes.labelcolor": INK,
    "text.color": INK,
    "xtick.color": INK,
    "ytick.color": INK,
    "savefig.dpi": 300,
    "figure.dpi": 120,
})


def save(fig, name):
    for ext in ("png", "pdf"):
        fig.savefig(OUT / ("%s.%s" % (name, ext)), bbox_inches="tight",
                    facecolor="white")
    plt.close(fig)
    print("wrote", name)


def box(ax, x, y, w, h, title, sub="", fs=8.2):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                                boxstyle="round,pad=0.008,rounding_size=0.015",
                                linewidth=0.9, edgecolor=ACC, facecolor=FILL))
    ax.text(x + w / 2, y + h * (0.63 if sub else 0.5), title, ha="center", va="center",
            fontsize=fs, fontweight="bold")
    if sub:
        ax.text(x + w / 2, y + h * 0.27, sub, ha="center", va="center",
                fontsize=fs - 1.0, color="#41566b")


def arrow(ax, p1, p2, color=ACC, lw=0.9, style="-|>", ls="-"):
    ax.add_patch(FancyArrowPatch(p1, p2, arrowstyle=style, mutation_scale=7,
                                 linewidth=lw, color=color, linestyle=ls))


# ---------------------------------------------------------------- 1 signal chain
def signal_chain():
    fig, ax = plt.subplots(figsize=(6.5, 2.0))
    ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")
    stages = [
        ("SMR 头", "0.5 Vpp/腿"),
        ("AD9238", "2 x 12 bit"),
        ("÷4 抽取", "12.5 MSPS"),
        ("六参数校正", "Q1.15 定点"),
        ("CORDIC", "17 级"),
        ("PI + 展开", "32 bit 位置"),
    ]
    w, h, gap, y = 0.118, 0.30, 0.042, 0.44
    x = 0.045
    for i, (title, sub) in enumerate(stages):
        box(ax, x, y, w, h, title, sub)
        if i:
            arrow(ax, (x - gap + 0.006, y + h / 2), (x - 0.004, y + h / 2))
        x += w + gap
    ax.text(0.5, 0.20,
            "输出：ABZ 2048 p/r · UVW 六步 · 1 GbE UDP · UART/SPI      全链路 41.5 拍 ≈ 830 ns",
            ha="center", fontsize=7.8, color="#41566b")
    ax.text(0.5, 0.87, "同一 50 MHz 时钟域，逐级位宽收敛，无 MMCM、无 CDC",
            ha="center", fontsize=8.0, color=INK)
    save(fig, "fig_chain_v2")


# --------------------------------------------------------------- 2 io topology
def io_topology():
    fig, ax = plt.subplots(figsize=(6.4, 2.9))
    ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")
    box(ax, 0.36, 0.34, 0.28, 0.30, "XC7A35TFGG484-2", "唯一计算单元 · 50 MHz", fs=8.4)
    chain = [("SMR 传感头", 0.74, "差分 0.5 Vpp"), ("模拟前端", 0.53, "单端 8 Vpp"),
             ("AD9238", 0.32, "12 bit x 2")]
    for name, y, note in chain:
        box(ax, 0.03, y, 0.21, 0.14, name, note, fs=7.8)
    arrow(ax, (0.135, 0.74), (0.135, 0.675))
    arrow(ax, (0.135, 0.53), (0.135, 0.465))
    arrow(ax, (0.245, 0.39), (0.355, 0.46))
    ax.text(0.02, 0.93, "模拟链路", fontsize=8, color=ACC, fontweight="bold")
    out = [("RGB 屏", 0.78, "RGB565 24 线"), ("触摸", 0.62, "I2C + 中断"),
           ("千兆 PHY", 0.46, "RGMII"), ("USB-UART", 0.30, "2 Mbaud"),
           ("ABZ / UVW", 0.14, "6 路输出")]
    for name, y, note in out:
        box(ax, 0.76, y, 0.21, 0.13, name, note, fs=7.8)
        arrow(ax, (0.645, 0.49), (0.755, y + 0.065))
    ax.text(0.75, 0.945, "外设与输出", fontsize=8, color=ACC, fontweight="bold")
    ax.text(0.50, 0.06, "时钟：50 MHz 有源晶振经 BUFG 分发；ODDR 转发同相时钟给 ADC",
            ha="center", fontsize=7.6, color="#41566b")
    save(fig, "fig_io_topology")


# --------------------------------------------------------------- 3 calib steps
def calibrate_stages():
    th = np.linspace(0, 2 * np.pi, 721)
    unit = np.stack([np.cos(th), np.sin(th)], 1)
    g = np.array([1.34, 0.82])
    shear = np.array([[1.0, 0.0], [-0.16, 1.0]])
    off = np.array([0.55, -0.38])
    raw = (unit * g) @ shear.T + off
    c1 = raw - off
    c2 = c1 / g
    c3 = c2 @ np.linalg.inv(shear).T
    c4 = c3 / np.linalg.norm(c3, axis=1, keepdims=True)

    fig, axes = plt.subplots(2, 3, figsize=(6.4, 3.1))
    data = [(raw, "(a) 原始输出", "偏置 + 增益 + 相位"),
            (c1, "(b) 去偏置", "一阶矩定中心"),
            (c2, "(c) 增益归一", "二阶矩定轴长"),
            (c3, "(d) 相位正交", "互相关定夹角"),
            (c4, "(e) 单位圆", "残余位移归零")]
    flat = [axes[0][0], axes[0][1], axes[0][2], axes[1][0], axes[1][1]]
    axes[1][2].axis("off")
    for ax, (pts, title, note) in zip(flat, data):
        ax.plot(np.cos(th), np.sin(th), "--", color=GRID, lw=0.8)
        ax.plot(pts[:, 0], pts[:, 1], color=ACC, lw=0.9)
        ax.set_xlim(-2.1, 2.1); ax.set_ylim(-2.1, 2.1)
        ax.set_aspect("equal"); ax.set_xticks([]); ax.set_yticks([])
        ax.set_title(title, fontsize=7.8, pad=2)
        for sp in ax.spines.values():
            sp.set_edgecolor("#e3e8ee")
            sp.set_linewidth(0.6)
        ax.text(0.5, -0.10, note, transform=ax.transAxes, ha="center",
                fontsize=6.8, color="#41566b")
    fig.subplots_adjust(wspace=0.10, hspace=0.35)
    save(fig, "fig_calib_steps")


# ------------------------------------------------------------- 4 cordic stage
def cordic_stage():
    fig = plt.figure(figsize=(6.6, 2.05))
    ax = fig.add_axes([0.0, 0.02, 0.56, 0.96])
    ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")
    box(ax, 0.02, 0.66, 0.22, 0.20, "x[i]", "12 bit", fs=7.8)
    box(ax, 0.02, 0.38, 0.22, 0.20, "y[i]", "12 bit", fs=7.8)
    box(ax, 0.02, 0.10, 0.22, 0.20, "z[i]", "20 bit", fs=7.8)
    box(ax, 0.34, 0.38, 0.26, 0.34, "± 与 >>i", "加法器 + 移位器", fs=7.6)
    box(ax, 0.68, 0.66, 0.22, 0.20, "x[i+1]", "", fs=7.8)
    box(ax, 0.68, 0.38, 0.22, 0.20, "y[i+1]", "", fs=7.8)
    box(ax, 0.68, 0.10, 0.22, 0.20, "z[i+1]", "", fs=7.8)
    arrow(ax, (0.245, 0.76), (0.335, 0.66))
    arrow(ax, (0.245, 0.48), (0.335, 0.52))
    arrow(ax, (0.245, 0.20), (0.335, 0.40))
    arrow(ax, (0.605, 0.64), (0.675, 0.74))
    arrow(ax, (0.605, 0.54), (0.675, 0.48))
    arrow(ax, (0.605, 0.44), (0.675, 0.22))
    ax.text(0.47, 0.86, "由 sign(z) 选择加减", ha="center", fontsize=7.2, color=ACC)

    bx = fig.add_axes([0.72, 0.17, 0.26, 0.71])
    it = np.arange(0, 18)
    step_deg = np.degrees(np.arctan(2.0 ** (-it)))
    bx.semilogy(it, step_deg, "o-", color=ACC, ms=2.8, lw=1.0)
    bx.axhline(360.0 / 65536, color=RED, lw=0.9, ls="--")
    bx.text(8.4, 12.5, "16 bit 角 1 LSB\n= 0.0055°", fontsize=6.4, color=RED, va="top")
    bx.set_xlabel("迭代级 i", fontsize=7.4)
    bx.set_ylabel("该级旋转角 (°)", fontsize=7.4, labelpad=13)
    bx.set_title("每级角度按 2 的幂收敛", fontsize=8.0, pad=3)
    bx.tick_params(labelsize=6.8)
    bx.yaxis.set_minor_locator(NullLocator())
    bx.grid(True, color=GRID, lw=0.5)
    for s in ("top", "right"):
        bx.spines[s].set_visible(False)
    save(fig, "fig_cordic_stage")


# ---------------------------------------------------------- 5 loop stability
def loop_stability():
    kp = np.linspace(0, 2.4, 400)
    fig, (a, b) = plt.subplots(1, 2, figsize=(6.5, 2.15))
    a.fill_between(kp, 0, np.maximum(4 - 2 * kp, 0), color=FILL, edgecolor="none")
    a.plot(kp, np.maximum(4 - 2 * kp, 0), color=ACC, lw=1.1)
    a.axhline(0, color=INK, lw=0.6)
    a.set_xlim(0, 2.4); a.set_ylim(0, 4.1)
    a.plot([1 / 256.0], [1 / 16.0], "x", color=RED, ms=6)
    a.annotate("照直觉加重滤波\nKp=1/256, Ki=1/16", xy=(0.06, 0.18), xytext=(0.20, 1.60),
               fontsize=6.6, color=RED,
               arrowprops=dict(arrowstyle="-|>", lw=0.7, color=RED))
    a.plot([0.5], [0.125], "o", color=ACC, ms=4)
    a.annotate("板上工作点\nKp=0.5, Ki=0.125", xy=(0.53, 0.16), xytext=(0.92, 0.95),
               fontsize=6.6, color=ACC,
               arrowprops=dict(arrowstyle="-|>", lw=0.7, color=ACC))
    a.set_xlabel("Kp", fontsize=7.4); a.set_ylabel("Ki", fontsize=7.4)
    a.set_title("(a) 稳定域：Kp 在 0-2，Ki 在 0 与 4-2Kp 之间", fontsize=7.6, pad=3)
    a.grid(True, color=GRID, lw=0.5)
    a.tick_params(labelsize=7)

    n = np.arange(0, 60)
    def step(kp_, ki_):
        p = 0.0; i = 0.0; out = []
        for _ in n:
            e = 1.0 - p
            i = max(min(i + ki_ * e, 0.25), -0.25)
            p = p + kp_ * e + i
            out.append(p)
        return np.array(out)
    b.plot(n, step(0.5, 0.125), color=ACC, lw=1.2, label="工作点：收敛")
    b.plot(n, step(2.05, 0.001), color=RED, lw=0.9, ls="--", label="重滤波档：指数发散")
    b.set_xlabel("拍", fontsize=7.4); b.set_ylabel("归一化位置", fontsize=7.4)
    b.set_title("(b) 阶跃响应（模型仿真，60 拍）", fontsize=7.6, pad=3)
    b.legend(fontsize=6.4, frameon=False, loc="lower right")
    b.grid(True, color=GRID, lw=0.5)
    b.tick_params(labelsize=7)
    for ax in (a, b):
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
    fig.tight_layout()
    save(fig, "fig_loop_stability")


# -------------------------------------------------------------- 6 abz timing
def abz_timing():
    fig, ax = plt.subplots(figsize=(6.5, 2.15))
    ax.set_xlim(-0.4, 12.4); ax.set_ylim(0, 6.4); ax.axis("off")
    t = np.arange(0, 13)
    a_lv = ((t // 2) % 2)
    b_lv = (((t + 1) // 2) % 2)
    for vals, y, name in ((b_lv, 4.0, "B"), (a_lv, 5.2, "A")):
        ax.plot(t, vals * 0.55 + y, color=ACC, lw=1.1, drawstyle="steps-post")
        ax.text(-0.55, y + 0.22, name, ha="right", va="center", fontsize=8.4,
                fontweight="bold")
    z = np.zeros(13); z[6:8] = 1
    ax.plot(t, z * 0.55 + 1.55, color=RED, lw=1.4, drawstyle="steps-post")
    ax.text(-0.55, 1.70, "Z", ha="right", va="center", fontsize=8.4, fontweight="bold")
    for k in range(12):
        ax.plot([k + 0.5, k + 0.5], [2.95, 3.15], color=GRID, lw=0.6)
        ax.text(k + 0.5, 2.72, str(k % 4), ha="center", fontsize=5.6, color="#41566b")
    ax.annotate("", xy=(0.5, 3.45), xytext=(4.5, 3.45),
                arrowprops=dict(arrowstyle="<|-|>", lw=0.7, color=INK))
    ax.text(2.5, 3.55, "一个电周期 = 4 个计数（4 倍频）", ha="center", fontsize=6.6)
    ax.annotate("", xy=(6.0, 1.15), xytext=(8.0, 1.15),
                arrowprops=dict(arrowstyle="<|-|>", lw=0.7, color=RED))
    ax.text(7.0, 0.62, "Z 宽 1.15-1.5 µs", ha="center", fontsize=6.8, color=RED)
    ax.text(-0.2, 6.15, "A/B 正交 4 倍频：每个边沿一个计数；Z 仅在角度门控窗内放行",
            fontsize=7.4, color="#41566b")
    ax.text(-0.2, 0.12, "门控窗 ±45°（2 的 AW-3 次方），出 Z 后撤防，离开 1/8 圈重新布防",
            fontsize=7.4, color="#41566b")
    save(fig, "fig_abz_timing")


# ----------------------------------------------------------- 7 uvw sectors
def uvw_sectors():
    fig, (a, b) = plt.subplots(1, 2, figsize=(6.5, 2.0),
                               gridspec_kw={"width_ratios": [1.6, 1]})
    t = np.linspace(0, 360, 721)
    for name, shift, y in (("U", 0, 2.7), ("V", 120, 1.7), ("W", 240, 0.7)):
        level = (np.sin(np.deg2rad(t - shift)) >= 0).astype(float)
        a.plot(t, level * 0.62 + y, color=ACC, lw=1.0, drawstyle="steps-post")
        a.text(-12, y + 0.28, name, ha="right", va="center", fontsize=8.0,
               fontweight="bold")
    for k in range(6):
        a.add_patch(plt.Rectangle((60 * k, -0.05), 60, 0.34,
                                  color=FILL if k % 2 == 0 else "white", zorder=0))
        a.text(60 * k + 30, 0.12, "扇区 %d" % ((5 - k) % 6), ha="center", fontsize=6.4,
               color=ACC)
    a.set_xlim(0, 360); a.set_ylim(-0.1, 3.5)
    a.set_xlabel("电角度 (°)", fontsize=7.4)
    a.set_yticks([]); a.set_xticks([0, 60, 120, 180, 240, 300, 360])
    a.tick_params(labelsize=7)
    a.set_title("(a) 六步换相：每 60° 一个状态", fontsize=7.8, pad=3)
    for s in ("top", "right", "left"):
        a.spines[s].set_visible(False)

    counts = np.array([5174, 4761, 4423, 4776, 4763, 4786])
    idx = np.arange(6)
    b.bar(idx, counts, color=ACC, width=0.6)
    b.axhline(counts.mean(), color=RED, lw=0.8, ls="--")
    b.text(4.6, counts.mean() + 90, "均值 %.0f" % counts.mean(), fontsize=6.4, color=RED)
    b.set_xticks(idx); b.set_xticklabels([str(i) for i in range(6)], fontsize=6.8)
    b.set_ylim(4200, 5400)
    b.set_xlabel("扇区", fontsize=7.2); b.set_ylabel("3 s 内计数", fontsize=7.2)
    b.tick_params(labelsize=6.8)
    b.set_title("(b) 板上六态计数，偏斜 <4%", fontsize=7.8, pad=3)
    for s in ("top", "right"):
        b.spines[s].set_visible(False)
    fig.tight_layout()
    save(fig, "fig_uvw_sectors")


# --------------------------------------------------------------- 8 ui map
def ui_map():
    fig, ax = plt.subplots(figsize=(6.4, 2.2))
    ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")
    pages = [("P1 总览", "四张卡片\n粗精角 / 速度", 0.015),
             ("P2 波形", "预触发缓冲\n三档时基 + AUTO", 0.265),
             ("P4 时序", "AB 4 周期\nUVW + Z 竖标", 0.515),
             ("P6 设置", "倍频 / 分频\n滤波 / 极性", 0.765)]
    for name, note, x in pages:
        box(ax, x, 0.34, 0.185, 0.36, name, note, fs=7.8)
        if x > 0.05:
            arrow(ax, (x - 0.060, 0.52), (x - 0.006, 0.52), lw=0.8)
    ax.text(0.46, 0.13, "KEY1 循环 P1 → P2 → P4 → P6 → P1", ha="center",
            fontsize=7.2, color="#41566b")
    ax.text(0.46, 0.86, "四页可导航（v90 删去 P7 标定页），每页两层下钻，零帧缓冲直写",
            ha="center", fontsize=7.6)
    save(fig, "fig_ui_map")


if __name__ == "__main__":
    signal_chain()
    io_topology()
    calibrate_stages()
    cordic_stage()
    loop_stability()
    abz_timing()
    uvw_sectors()
    ui_map()
