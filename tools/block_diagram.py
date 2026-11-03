#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""block_diagram.py -- 生成报告 §2.1 的系统框图（`deliverables/figures/block_diagram.png`）。

框图口径全部来自现行 RTL：单时钟域 50 MHz（`rtl/enc_top.v:135-137` 板载晶振 + BUFG，
设计内无 MMCM）、ADC 时钟由 ODDR 转发（`rtl/enc_top.v:158-190`）、
信号链 `ad9238_capture → decim_avg → sc_correct → cordic_atan2 → glitch guard → loop_filter → angle`
（`rtl/enc_top.v:456/:547`）、输出 `abz_gen` / `uvw_gen`。

用法：python tools/block_diagram.py [--out deliverables/figures/block_diagram.png]
"""
import argparse
import os
import sys

C_BG = "#f4f7fb"
C_ADC = "#fff2cc"
C_FPGA = "#eef3fa"
C_DSP = "#dce9f7"
C_OUT = "#e2f2e2"
C_PC = "#f0e6f6"
C_EDGE = "#3b4a5a"


def box(ax, x, y, w, h, text, fc, fs=9, ec=C_EDGE, lw=1.1, bold=False, radius=0.012):
    from matplotlib.patches import FancyBboxPatch
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=%g" % radius,
                                linewidth=lw, edgecolor=ec, facecolor=fc, zorder=2))
    ax.text(x + w / 2.0, y + h / 2.0, text, ha="center", va="center", fontsize=fs,
            zorder=3, weight="bold" if bold else "normal")


def arrow(ax, p1, p2, color="#2b5d8a", lw=1.3, style="-|>", rad=0.0, ls="-"):
    from matplotlib.patches import FancyArrowPatch
    ax.add_patch(FancyArrowPatch(p1, p2, arrowstyle=style, mutation_scale=11,
                                 linewidth=lw, color=color, zorder=1.5,
                                 connectionstyle="arc3,rad=%g" % rad, linestyle=ls))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="deliverables/figures/block_diagram.png")
    args = ap.parse_args()

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import rcParams
    rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    rcParams["axes.unicode_minus"] = False

    fig, ax = plt.subplots(figsize=(12.6, 7.0))
    ax.set_xlim(0, 1.0)
    ax.set_ylim(0, 1.0)
    ax.axis("off")
    fig.patch.set_facecolor("white")

    # ── 左侧：信号源与上位机 ──────────────────────────────────────────
    box(ax, 0.015, 0.62, 0.135, 0.20,
        "AFG-2225\n正弦 ×2 通道\n8 Vpp @ 20 kHz\n相移 90°", C_BG, fs=9, bold=True)
    box(ax, 0.015, 0.30, 0.135, 0.16, "上位机 PC\nUART/SPI 2 Mbaud\n遥测 + 寄存器",
        C_PC, fs=8.5)

    # ── 第二列：AD9238 模块 ───────────────────────────────────────────
    box(ax, 0.175, 0.60, 0.145, 0.24,
        "AD9238 模块（载板 J5/J6）\n12 bit × 2 通道\n65 MSPS，无 DCO\nOTR_A / OTR_B\n时钟 tPD = 2…6 ns",
        C_ADC, fs=8.5, bold=False)

    # ── 中间：FPGA ───────────────────────────────────────────────────
    box(ax, 0.345, 0.10, 0.475, 0.80, "", C_FPGA, fs=9, lw=1.6)
    ax.text(0.5825, 0.885, "Artix-7 XC7A35TFGG484-2 · 单时钟域 50 MHz（板载晶振 V4 + BUFG，无 MMCM）",
            ha="center", va="center", fontsize=9.5, weight="bold")
    ax.text(0.5825, 0.855, "ADC 时钟 = clk 经 ODDR 转发（v9：D1=0/D2=1；v10：D1=1/D2=0）",
            ha="center", va="center", fontsize=8, color="#555555")

    # 行 1（→）：捕获与校正
    y1 = 0.665
    box(ax, 0.365, y1, 0.135, 0.115, "ad9238_capture\n元稳 + 同步采样\n50 MHz 捕获", C_DSP, fs=8)
    box(ax, 0.512, y1, 0.135, 0.115, "decim_avg\nLOG2DEC=2\n（12.5 MHz 有效）", C_DSP, fs=8)
    box(ax, 0.659, y1, 0.145, 0.115, "sc_correct + amp_monitor\nOFS / GAIN / PHASE_K / SHIFT（六参数）\n幅值监视 √(s²+c²)", C_DSP, fs=7.4)

    # 行 2（←）：角度解算
    y2 = 0.455
    box(ax, 0.659, y2, 0.145, 0.115, "cordic_atan2\n17 级全流水\n19 拍延迟", C_DSP, fs=8)
    box(ax, 0.512, y2, 0.135, 0.115, "glitch guard\n检测-保持\n(1024 LSB 阈值)", C_DSP, fs=8)
    box(ax, 0.365, y2, 0.135, 0.115, "loop_filter\nⅡ 型 PI\n（带 GATE_STATE）", C_DSP, fs=8)

    # 行 3：输出级
    y3 = 0.235
    box(ax, 0.365, y3, 0.135, 0.115, "pole_counter\n极对数 / 电周期", C_DSP, fs=8)
    box(ax, 0.512, y3, 0.135, 0.115, "abz_gen\nA / B / Z\n细分 1…1024×", C_OUT, fs=8)
    box(ax, 0.659, y3, 0.145, 0.115, "uvw_gen\nU/V/W 换相", C_OUT, fs=7.8)

    # 行 3 下方：寄存器文件
    box(ax, 0.365, 0.125, 0.44, 0.075,
        "reg_file（UART→SPI 桥）：0x0302 FILT_K · 0x0101/02 INTER & div · 0x0108/09 z_width & abzen · 0x0510… 标定系数 · 0x0505… 毛刺计数器",
        C_PC, fs=7.6)

    # FPGA 内部箭头
    arrow(ax, (0.500, y1 + 0.0575), (0.512, y1 + 0.0575))
    arrow(ax, (0.647, y1 + 0.0575), (0.659, y1 + 0.0575))
    arrow(ax, (0.7315, y1), (0.7315, y2 + 0.115))            # 行1 → 行2
    arrow(ax, (0.659, y2 + 0.0575), (0.647, y2 + 0.0575))
    arrow(ax, (0.512, y2 + 0.0575), (0.500, y2 + 0.0575))
    arrow(ax, (0.4325, y2), (0.4325, y3 + 0.115))            # 行2 → 行3
    arrow(ax, (0.500, y3 + 0.0575), (0.512, y3 + 0.0575))
    arrow(ax, (0.647, y3 + 0.0575), (0.659, y3 + 0.0575))
    arrow(ax, (0.5825, 0.235), (0.5825, 0.200))              # 寄存器文件 → 输出级

    ax.text(0.47, 0.418, "angle = pos_ext[ZW-1:FRAC]（ABZ / UVW 两路共用）",
            ha="left", va="center", fontsize=7.5, color="#2b5d8a")
    ax.text(0.6605, 0.600, "校正后 16 bit", ha="left", va="center", fontsize=7.5, color="#2b5d8a")
    ax.text(0.6605, 0.418, "angle_raw", ha="left", va="center", fontsize=7.5, color="#2b5d8a")

    # ── 右侧：输出 ───────────────────────────────────────────────────
    box(ax, 0.845, 0.735, 0.14, 0.13, "ABZ 增量输出\n→ 伺服 / 驱动器", C_OUT, fs=8.5)
    box(ax, 0.845, 0.545, 0.14, 0.13, "UVW 换相信号\n→ 电机换相", C_OUT, fs=8.5)
    box(ax, 0.845, 0.155, 0.14, 0.13, "UART 遥测 / 寄存器\n→ 上位机", C_PC, fs=8.5)

    # 跨域箭头
    arrow(ax, (0.160, 0.72), (0.175, 0.72))                  # AFG → ADC
    arrow(ax, (0.320, 0.72), (0.345, 0.72), color="#b8860b", lw=1.6)   # ADC → FPGA
    ax.text(0.3325, 0.745, "12 bit ×2", ha="center", fontsize=7.2, color="#b8860b")
    arrow(ax, (0.320, 0.68), (0.345, 0.68), color="#b8860b", lw=1.6)
    ax.text(0.3325, 0.655, "OTR", ha="center", fontsize=7.2, color="#b8860b")
    arrow(ax, (0.160, 0.38), (0.365, 0.16), color="#7d5ba6", lw=1.2, rad=-0.25)  # PC → reg_file
    arrow(ax, (0.365, 0.1625), (0.160, 0.38), color="#7d5ba6", lw=1.2, rad=-0.25, ls="--")

    arrow(ax, (0.820, 0.79), (0.845, 0.80))
    arrow(ax, (0.820, 0.2925), (0.845, 0.61), rad=0.15)
    arrow(ax, (0.820, 0.2925), (0.845, 0.42), rad=0.15)
    arrow(ax, (0.820, 0.1625), (0.845, 0.22))

    ax.text(0.5, 0.045,
            "总延迟预算 ≈41.5 拍 ≈830 ns（含 ADC 内部 7 拍估计）· 分辨率 / 倍率 / 接口全部可重配置 · "
            "多轴共用同一 50 MHz 时钟 → 天然同步",
            ha="center", va="center", fontsize=8.6, color="#333333")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print("saved %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
