#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""arc_fit_free.py —— 对 ILA 原始码窗口做**自由频率**正弦圆拟合（5 参数非线性）。

为什么需要它（2026-10-12 发现）：
  · ILA 窗口只有 1024 拍 @50MHz = 20.48us，而 20 kHz 输入周期 50us
    ⇒ 窗口只覆盖 **约 147 度** 圆弧（`arc_fit.py` 自己算的 span_deg 就写着）。
  · 弧段短 ⇒ 「圆心 O」与「半径 A」在圆拟合里强相关；`arc_fit.py` 的两套口径
    （用已知 f_in 的线性正弦拟合 / Kasa 代数圆拟合）在同一个窗口上给出
    O 相差 15~25 LSB、A 相差 15~25 LSB，无法判断哪个可信。
  · 若把频率也当未知量一起拟合，残差能降下来（2D RMS 从 ~8 LSB 降到 ~2.5 LSB），
    说明之前的分歧主要来自**假设的 f_in 不准**，而不是模型不对。

模型（与 `arc_fit.py` 同一套）：x[n] = O + B·exp(j·σ·ω·n·dt)，dt = 20 ns，σ = ±1。
未知：Os, Oc, Bs, Bi, ω（5 个）。用 `scipy.optimize.least_squares` 求解，
残差取 (Re, Im) 两部分。

用法：
    E:\\Anaconda\\python.exe tools\\arc_fit_free.py _synth_work\\ila_cap_g12_raw.csv [--f0 20000]
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glitch_chain as gc  # noqa: E402

DT = 20e-9


def _model(p, n, sgn):
    Os, Oc, Bs, Bi, w = p
    ph = sgn * w * n * DT
    B = Bs + 1j * Bi
    return (Os + 1j * Oc) + B * np.exp(1j * ph)


def _lin_init(x, n, sgn, w0):
    E = np.exp(1j * sgn * w0 * n * DT)
    M = np.column_stack([np.ones_like(E), E])
    coef, *_ = np.linalg.lstsq(M, x, rcond=None)
    return [coef[0].real, coef[0].imag, coef[1].real, coef[1].imag, w0]


def _solve(x, n, sgn, p0):
    from scipy.optimize import least_squares

    def resid(p):
        r = _model(p, n, sgn) - x
        return np.concatenate([r.real, r.imag])

    return least_squares(resid, p0, method="lm", max_nfev=20000)


def fit_free(path, f0=20000.0):
    """返回自由频率拟合结果。

    ★ 带**抗差**三轮重拟合：抓毛刺的窗口里那一拍残差极大（可达 2000+ LSB），
    不做剔除会把 ω 与 O/A 一起带偏（实测 glitch 窗口未加抗差时二维 RMS 高达 72 LSB）。
    """
    _df, D, _tag, viol, _rstd, _rev = gc.load(path)
    if viol != 0:
        raise SystemExit("%s: 位序自检失败（stat_byte bit7 违例 %d 处）" % (path, viol))
    s = D["dbg_s_raw"].astype(float)
    c = D["dbg_c_raw"].astype(float)
    x = s + 1j * c
    n = np.arange(len(s), dtype=float)

    best = None
    for sgn in (+1, -1):
        for w0 in (2 * np.pi * f0, 2 * np.pi * f0 * 0.9, 2 * np.pi * f0 * 1.1):
            try:
                sol = _solve(x, n, sgn, _lin_init(x, n, sgn, w0))
            except Exception:  # noqa: BLE001
                continue
            for _ in range(3):                     # 抗差：剔掉大残差后重拟合
                r = _model(sol.x, n, sgn) - x
                m = np.abs(r) <= max(20.0, 5.0 * float(np.sqrt(np.mean(np.abs(r) ** 2))))
                if m.sum() < 32 or bool(m.all()):
                    break
                try:
                    sol = _solve(x[m], n[m], sgn, sol.x)
                except Exception:  # noqa: BLE001
                    break
            r = _model(sol.x, n, sgn) - x
            rms_all = float(np.sqrt(np.mean(np.abs(r) ** 2)))
            m2 = np.abs(r) <= max(20.0, 5.0 * rms_all)
            rms_in = float(np.sqrt(np.mean(np.abs(r[m2]) ** 2))) if m2.any() else rms_all
            A = float(abs(sol.x[2] + 1j * sol.x[3]))
            O = complex(sol.x[0], sol.x[1])
            rms_rad = float(np.sqrt(np.mean((np.abs(x - O) - A) ** 2)))
            if best is None or rms_in < best["rms_in"]:
                best = dict(path=path, n=len(s), sgn=sgn, Os=sol.x[0], Oc=sol.x[1],
                            A=A, f=abs(sol.x[4]) / (2 * np.pi), rms2d=rms_all,
                            rms_in=rms_in, rms_rad=rms_rad, f0=f0, x=x,
                            pred=_model(sol.x, n, sgn),
                            span_deg=float(np.degrees(abs(sol.x[4]) * (len(s) - 1) * DT)))
    return best


def main():
    args = sys.argv[1:]
    f0 = 20000.0
    if "--f0" in args:
        i = args.index("--f0")
        f0 = float(args[i + 1])
        del args[i:i + 2]
    for p in args:
        R = fit_free(p, f0)
        print("\n=== %s  (%d 拍, 弧长 %.1f deg)" % (R["path"], R["n"], R["span_deg"]))
        print("  [自由频率拟合 符号%+d] O = (%+.1f, %+.1f) LSB, A = %.1f LSB,"
              " f = %.4f kHz (初值 %.3f)"
              % (R["sgn"], R["Os"], R["Oc"], R["A"], R["f"] / 1e3, R["f0"] / 1e3))
        print("  残差: 二维 RMS = %.2f LSB   半径方向 RMS = %.2f LSB" % (R["rms2d"], R["rms_rad"]))
        print("  max|s| = %.1f   max|c| = %.1f" % (abs(R["Os"]) + R["A"], abs(R["Oc"]) + R["A"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
