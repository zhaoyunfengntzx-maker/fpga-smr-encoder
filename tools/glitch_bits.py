#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""glitch_bits.py —— 从 ILA 毛刺抓包里做**逐位归因**：这一拍到底错在哪几位、错的时候输入在哪。

做法：
  1) 用 `tools/arc_fit_free.py` 的自由频率正弦圆拟合当**参考轨迹**（五参数，二维残差 ~3 LSB）；
  2) 残差 = 实测 − 参考，挑出 |残差| > 阈值（默认 100 LSB）的拍；
  3) 对每个事件打印：
       · 参考（= 真值估计）s/c 与实测 s/c、Δs、Δc；
       · Δ 是否 ≈ ±2048（bit11 / 符号位）、±1024（bit10）、±4096（bit12，12 位没有）
         —— 用「10 位纹波进位」或「MSB 符号位翻转」这类机制去对照；
       · 出错时**受影响通道的真值大小** |pred|（判断是不是发生在过零/中刻度附近）；
       · 非受影响通道是否干净。

用途：把"毛刺"从"角度跳变"降级成"具体哪一位错了"，从而判断是 ADC 内部位翻转、
通道串扰，还是 RTL 取值错误。

用法：
    E:\\Anaconda\\python.exe tools\\glitch_bits.py _synth_work\\ila_cap_v9_glitch1.csv [...]
    E:\\Anaconda\\python.exe tools\\glitch_bits.py --thresh 300 _synth_work\\ila_cap_v9_g82_1.csv
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arc_fit_free as aff  # noqa: E402

# 12 位码里值得对照的位权
BITCAND = [4096, 2048, 1024, 512, 256, 128, 64, 32, 16, 8, 4, 2, 1]


def nearest_bit(dv):
    """返回 (位权, 残差)：把 Δ 归到最近的"位权"上。"""
    best = None
    for b in BITCAND:
        for sgn in (+1, -1):
            e = abs(dv - sgn * b)
            if best is None or e < best[1]:
                best = (b if sgn > 0 else -b, e)
    return best


def analyze(path, thresh=100.0, top=12, f0=20000.0):
    R = aff.fit_free(path, f0)
    pred = R["pred"]
    x = R["x"]
    ds = x.real - pred.real
    dc = x.imag - pred.imag
    mag = np.hypot(ds, dc)
    idx = np.where(mag > thresh)[0]
    # 相邻拍合并成"事件"
    events = []
    for i in idx:
        if events and i - events[-1][-1] <= 2:
            events[-1].append(i)
        else:
            events.append([i])
    return R, ds, dc, mag, events


def fmt_event(ev, ds, dc, pred):
    i = max(ev, key=lambda k: abs(ds[k]) + abs(dc[k]))
    dsv, dcv = ds[i], dc[i]
    bs, es = nearest_bit(dsv)
    bc, ec = nearest_bit(dcv)
    # 受影响的是哪个通道（谁偏离参考更大）
    chan = "s" if abs(dsv) >= abs(dcv) else "c"
    true_code = pred.real[i] if chan == "s" else pred.imag[i]
    other = abs(dcv) if chan == "s" else abs(dsv)
    return dict(i=i, n=len(ev), ds=dsv, dc=dcv, bs=bs, es=es, bc=bc, ec=ec,
                chan=chan, true_code=true_code, other=other,
                pred_s=pred.real[i], pred_c=pred.imag[i])


def main():
    args = sys.argv[1:]
    thresh = 100.0
    if "--thresh" in args:
        j = args.index("--thresh")
        thresh = float(args[j + 1])
        del args[j:j + 2]
    f0 = 20000.0
    if "--f0" in args:
        j = args.index("--f0")
        f0 = float(args[j + 1])
        del args[j:j + 2]
    if not args:
        raise SystemExit(__doc__)
    top = 12
    print("阈值 = %.0f LSB（残差 = 实测 − 自由频率圆拟合参考）" % thresh)
    for p in args:
        try:
            R, ds, dc, mag, events = analyze(p, thresh, f0=f0)
        except SystemExit as e:
            print("\n### %s  跳过：%s" % (p, e))
            continue
        print("\n" + "=" * 108)
        print("### %s" % p)
        print("  参考轨迹: A = %.1f LSB, O = (%+.1f,%+.1f), f = %.4f kHz,"
              " 二维残差 RMS = %.2f LSB, 弧长 %.1f deg"
              % (R["A"], R["Os"], R["Oc"], R["f"] / 1e3, R["rms2d"], R["span_deg"]))
        print("  残差 > %.0f LSB 的拍: %d 个（合并成 %d 个事件）"
              % (thresh, int((mag > thresh).sum()), len(events)))
        if not events:
            print("  —— 本窗没有事件（这个抓包要么没抓到毛刺，要么阈值太高）")
            continue
        print("  %-5s %-3s %9s %9s | %9s %9s | %-8s %-14s %-12s"
              % ("拍号", "拍数", "Δs", "Δc", "真值s", "真值c", "出错通道", "归到哪一位",
                 "该通道真值"))
        for ev in events[:top]:
            e = fmt_event(ev, ds, dc, R["pred"])
            print("  %-5d %-3d %+9.1f %+9.1f | %9.1f %9.1f | %-8s s:%+6d(±%.0f) %-12s"
                  % (e["i"], e["n"], e["ds"], e["dc"], e["pred_s"], e["pred_c"],
                     e["chan"], e["bs"], e["es"],
                     "%+.0f" % e["true_code"]))
        # 统计：事件通道的真值分布（检验"过零/中刻度"假设）
        rows = [fmt_event(ev, ds, dc, R["pred"]) for ev in events]
        big = [r for r in rows if abs(r["ds"]) > 1000 or abs(r["dc"]) > 1000]
        print("  —— |Δ| > 1000 LSB 的事件: %d 个" % len(big))
        if big:
            ms = [r["ds"] for r in big if r["chan"] == "s"]
            mc = [r["dc"] for r in big if r["chan"] == "c"]
            print("     Δs 集合: %s" % (", ".join("%+.0f" % v for v in ms[:10]) or "-"))
            print("     Δc 集合: %s" % (", ".join("%+.0f" % v for v in mc[:10]) or "-"))
            tc = [abs(r["true_code"]) for r in big]
            print("     出错通道真值 |code| : min %.0f  中位 %.0f  max %.0f"
                  % (min(tc), float(np.median(tc)), max(tc)))
            ptc = [abs(r["pred_s"]) if r["chan"] == "s" else abs(r["pred_c"]) for r in big]
            oth = [abs(r["dc"]) if r["chan"] == "s" else abs(r["ds"]) for r in big]
            print("     ★ 受影响通道 |真值| 中位 = %.0f LSB（中刻度=0 时说明是符号位/过零翻转）"
                  % float(np.median(ptc)))
            print("     ★ 未受影响通道 |Δ| 中位 = %.0f LSB（应≈0 才算单通道错误）"
                  % float(np.median(oth)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
