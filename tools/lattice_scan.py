#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""256 格点共振预测（D 分支毛刺成因用）

假设（见 docs/DEV_STATUS.md §1.54/§1.55）：
  坏样本事件发生在 **两个通道的引脚码同时落在 0x100(=256) 整数倍边界** 的瞬间，
  因为此时两条 12bit 数据总线各有低 8 位同时翻转（联合 SSN 最大）。
  引脚码 = 有符号码 + 2048，而 2048 = 8*256 ⇒ "引脚码是 256 的倍数" ⟺ "有符号码是 256 的倍数"。
  于是判据化成几何问题：轨迹圆（圆心 O、半径 A，都是"有符号码域"）
  是否**擦过**某个 256 格点 (s,c) = 256*(a,b)：
      共振质量 = | |O - L| - A |      越小越容易触发

用法：
  # ① 验证模式：用板侧已拟合的 (O, A) 反查最近格点，并和实测事件点/相位对照
  python tools/lattice_scan.py --table

  # ② 预测模式：给定圆心 O，扫半径 A，打印最近格点、距离、相位（给幅度阶梯实验定标）
  python tools/lattice_scan.py --o 3,20 --a 1580,1700,2

注意：圆心 O 由 149° 的短弧拟合得来，与 A 强相关（两套拟合 A 差 ~1.5% = ~25 LSB），
      所以"距离"的绝对不确定度与它本身的量级相当 ⇒ 本工具给的是**趋势与相位**，
      不能当成硬阈值。
"""
import sys
import math
import argparse

STEP = 256
AB_LIM = 12  # 格点搜索范围 |a|,|b| <= 12  => |s|,|c| <= 3072


def nearest_lattice(Os, Oc, A, step=STEP, ab_lim=AB_LIM):
    """返回 (距离, 格点s, 格点c, 观测相位deg)。

    观测相位沿用 tools/glitch_chain.py 的口径：atan2(s, c)（绝对坐标，非圆心相对）。
    """
    best = None
    for a in range(-ab_lim, ab_lim + 1):
        for b in range(-ab_lim, ab_lim + 1):
            Ls, Lc = a * step, b * step
            d = math.hypot(Ls - Os, Lc - Oc)
            err = abs(d - A)          # 圆到该格点的最近距离
            if best is None or err < best[0]:
                best = (err, Ls, Lc, math.degrees(math.atan2(Ls, Lc)), d)
    return best


def fmt_pt(Os, Oc, A, tag):
    err, Ls, Lc, ph, d = nearest_lattice(Os, Oc, A)
    print("  %-26s O=(%+7.1f,%+7.1f) A=%7.1f  ->  最近格点 (%+6d,%+6d) = 256*(%+d,%+d)"
          % (tag, Os, Oc, A, Ls, Lc, Ls // STEP, Lc // STEP))
    print("  %-26s 圆到格点距离 = %6.1f LSB   观测相位 atan2(s,c) = %+7.1f°   圆心距离 %7.1f"
          % ("", err, ph, d))
    return err, Ls, Lc, ph


def mode_table():
    """板侧四个幅度窗（Kasa / 正弦 两套拟合）与实测事件对照。"""
    wins = [
        # label,           Kasa(O_s,O_c,A),        sine(O_s,O_c,A),       实测事件(有符号点, 率)
        ("7.6 Vpp amp76",   (10.0, 29.2, 1534.3),  (15.3, 27.2, 1530.1),  None,                "0 次/s"),
        ("8.0 Vpp dbgstate", (-8.7, 21.5, 1609.8), (-13.0, 20.0, 1606.5), (-1536.0, 512.0),    "1.7 次/s"),
        ("8.0 Vpp ctrl",    (2.7, 12.3, 1620.9),   (6.2, 7.0, 1625.6),    None,                "2.4 次/s"),
        ("8.2 Vpp amp82",   (-0.8, 41.1, 1669.6),  (13.9, 11.5, 1645.0),  (-1024.0, -1280.0),  "13.65 次/s"),
    ]
    print("=" * 100)
    print("验证模式：板侧 (O,A) 拟合 -> 最近 256 格点 / 距离 / 相位， 与实测事件对照")
    print("=" * 100)
    for label, kasa, sine, obs, rate in wins:
        print("[%s]  实测率 %s" % (label, rate))
        if obs:
            print("    实测事件点（有符号码） = (%+d, %+d) = 256*(%+d,%+d)，观测相位 %+.1f°"
                  % (obs[0], obs[1], obs[0] / STEP, obs[1] / STEP, math.degrees(math.atan2(obs[0], obs[1]))))
        for tag, fit in (("Kasa", kasa), ("正弦", sine)):
            fmt_pt(fit[0], fit[1], fit[2], tag)
        print("")


def mode_scan(args):
    Os, Oc = args.o
    a0, a1, st = args.a
    print("=" * 100)
    print("预测模式：O = (%+.1f, %+.1f)，扫 A = %.1f … %.1f 步 %.1f（256 格点共振）" % (Os, Oc, a0, a1, st))
    print("=" * 100)
    print("  %8s  %20s  %10s  %10s  %10s" % ("A", "最近格点 (s,c)", "距离 LSB", "相位°", "圆心距离"))
    A = a0
    while A <= a1 + 1e-9:
        err, Ls, Lc, ph, d = nearest_lattice(Os, Oc, A)
        print("  %8.1f  (%+6d,%+6d)      %10.1f  %+10.1f  %10.1f" % (A, Ls, Lc, err, ph, d))
        A += st


def main():
    ap = argparse.ArgumentParser(description="256 格点共振预测（D 分支毛刺）")
    ap.add_argument("--table", action="store_true", help="验证模式：板侧拟合 vs 实测事件")
    ap.add_argument("--o", type=lambda s: tuple(float(x) for x in s.split(",")), help="圆心 O_s,O_c")
    ap.add_argument("--a", type=lambda s: tuple(float(x) for x in s.split(",")), help="A0,A1,STEP")
    args = ap.parse_args()
    if args.table:
        mode_table()
    elif args.o and args.a:
        mode_scan(args)
    else:
        ap.print_help()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
