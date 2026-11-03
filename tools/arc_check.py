#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""看一窗遥测 CSV 的 (s,c) 到底覆盖了圆周的多少 —— 判断「用遥测测幅度/圆心」是否成立。

背景：`tools/uart_scope.py` 的「校正后半径 r」是**到原点的距离**。如果这一窗采到的
点只覆盖一段圆弧（不是整圈），那么
  · 圆心 O 与半径 A 在拟合里强相关 ⇒ A 的抖动主要是「弧段位置」在变，不是幅度在变；
  · mean r 也不是 A。
本工具就是把这个前提用数据检查一遍：
  · 360 相位分 36 格：有多少空格子、最少的格子占均值多少；
  · s/c 的 min/max 与占位网格（32×32）的占用率；
  · Kasa 拟合的 (A,O) 与 RMS、以及「点半径 r 的 std」。

用法：
    E:\\Anaconda\\python.exe tools\\arc_check.py _synth_work\\arc_check.csv
"""

import io
import math
import sys

import numpy as np


def load(path):
    with io.open(path, encoding="utf-8") as f:
        head = f.readline().strip().split(",")
    rows = np.genfromtxt(path, delimiter=",", names=True, dtype=None, encoding="utf-8")
    return head, rows


def kasa(s, c):
    X, Y = np.asarray(s, float), np.asarray(c, float)
    A1 = np.column_stack([2 * X, 2 * Y, np.ones_like(X)])
    b1 = X ** 2 + Y ** 2
    sol, *_ = np.linalg.lstsq(A1, b1, rcond=None)
    Os, Oc = sol[0], sol[1]
    A = math.sqrt(max(sol[2] + Os * Os + Oc * Oc, 0.0))
    res = np.abs(np.hypot(X - Os, Y - Oc) - A)
    return A, Os, Oc, float(np.sqrt(np.mean(res ** 2)))


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    path = argv[1]
    head, rows = load(path)
    s = np.asarray(rows["s"], float)
    c = np.asarray(rows["c"], float)
    n = len(s)
    A, Os, Oc, rms = kasa(s, c)
    ph = np.degrees(np.arctan2(c - Oc, s - Os))
    bins = 36
    idx = np.floor((ph + 180.0) / (360.0 / bins)).astype(int) % bins
    cnt = np.bincount(idx, minlength=bins).astype(float)
    r = np.hypot(s, c)
    print("文件        : %s" % path)
    print("列          : %s" % ",".join(head))
    print("样本数      : %d" % n)
    print("s 范围      : [%.0f, %.0f]  (跨度 %d)" % (s.min(), s.max(), s.max() - s.min()))
    print("c 范围      : [%.0f, %.0f]  (跨度 %d)" % (c.min(), c.max(), c.max() - c.min()))
    print("Kasa 拟合   : A = %.2f  O = (%+.2f, %+.2f)  RMS = %.2f" % (A, Os, Oc, rms))
    print("到原点 r    : mean %.1f  std %.1f  min %.1f  max %.1f"
          % (r.mean(), r.std(), r.min(), r.max()))
    print("相角覆盖    : 空格子 %d/%d，最少格子 = 均值的 %.2f 倍"
          % (int((cnt == 0).sum()), bins, cnt.min() / max(cnt.mean(), 1e-9)))
    print("相角直方图  : %s" % " ".join("%d" % v for v in cnt))
    # 占位网格：把 s/c 的包围盒切成 32x32，看有多少格被踩到
    for name, x, y in (("s-c", s, c),):
        gx = np.clip(((x - x.min()) / max(np.ptp(x), 1) * 32).astype(int), 0, 31)
        gy = np.clip(((y - y.min()) / max(np.ptp(y), 1) * 32).astype(int), 0, 31)
        occ = len(set(zip(gx.tolist(), gy.tolist())))
        print("占位网格%s: %d/1024 格（外接矩形内含点比例 %.1f%%）"
              % (name, occ, 100.0 * occ / 1024.0))
    # 结论提示
    if cnt.min() / max(cnt.mean(), 1e-9) < 0.2:
        print("⇒ **这一窗只覆盖了一段圆弧**：A / O 不可当幅度与圆心用（弧段位置会影响它们）。")
    else:
        print("⇒ 这一窗接近整圈：A / O 可用。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
