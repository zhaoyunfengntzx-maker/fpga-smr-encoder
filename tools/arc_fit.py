# -*- coding: utf-8 -*-
"""从 ILA 窗口（只覆盖 148 度相位）用**已知 f_in** 做线性最小二乘，恢复 sin/cos 圆的
圆心 O=(Os,Oc) 与半径 A（= 正弦幅度，LSB）。

模型: x[n] = s_raw[n] + j*c_raw[n] = O + B * exp(j*w*n*dt),  w = 2*pi*f_in, dt = 20 ns
未知: O(复数), B(复数) -> 线性最小二乘（基 {1, exp(j w n dt)}）。

用途: 判断"幅度降 5% 后 S 通道码还能不能到 |s| >= 1536.5"（max|s| = |Os| + A），
从而判断"毛刺归零"到底能否区分 (a) 512 格点联合共振 与 (b) 仅 S 通道跨边界。

用法: python tools/arc_fit.py <csv> [...] --f <f_in Hz>
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glitch_chain as gc  # noqa: E402


def fit(path, f_in=None):
    _df, D, tag, viol, rstd, rev = gc.load(path)
    if viol != 0:
        raise SystemExit(f"{path}: 位序自检失败（stat_byte bit7 违例 {viol} 处）")
    s = D["dbg_s_raw"].astype(float)
    c = D["dbg_c_raw"].astype(float)
    n = np.arange(len(s))
    dt = 20e-9
    if f_in is None:
        # 用 s 的希尔伯特近似不可靠；这里要求外部给 --f
        raise SystemExit("必须给 --f <f_in Hz>")
    w = 2 * np.pi * f_in
    x = s + 1j * c
    # 旋转方向未知（s/c 配对约定可能使相位递减）⇒ 两个符号都拟合，取残差小的
    best = None
    for sgn_w in (+1, -1):
        E = np.exp(1j * sgn_w * w * n * dt)
        M = np.column_stack([np.ones_like(E), E])
        coef, *_ = np.linalg.lstsq(M, x, rcond=None)
        res = x - M @ coef
        rms = float(np.sqrt(np.mean(np.abs(res) ** 2)))
        if best is None or rms < best[0]:
            best = (rms, coef, sgn_w)
    rms, coef, sgn_w = best
    O, B = coef[0], coef[1]
    E = np.exp(1j * sgn_w * w * n * dt)
    pred = np.ones_like(x) * O + B * E
    A = abs(B)
    Os, Oc = O.real, O.imag
    r_inst = np.abs(x)
    # Kasa 代数圆拟合（不依赖频率）做交叉校验
    X, Y = s, c
    A1 = np.column_stack([2 * X, 2 * Y, np.ones_like(X)])
    b1 = X ** 2 + Y ** 2
    sol, *_ = np.linalg.lstsq(A1, b1, rcond=None)
    Ok = complex(sol[0], sol[1])
    Ak = float(np.sqrt(sol[2] + abs(Ok) ** 2))
    res_k = np.abs(np.abs(x - Ok) - Ak)
    return dict(
        path=path, n=len(s), A=A, O=O, Os=Os, Oc=Oc, sgn=sgn_w,
        res_rms=rms, A_kasa=Ak, O_kasa=Ok, res_kasa_rms=float(np.sqrt(np.mean(res_k ** 2))),
        s_min=s.min(), s_max=s.max(), c_min=c.min(), c_max=c.max(),
        max_abs_s=float(np.max(np.abs(s))), max_abs_c=float(np.max(np.abs(c))),
        s_pred_min=float(pred.real.min()), s_pred_max=float(pred.real.max()),
        c_pred_min=float(pred.imag.min()), c_pred_max=float(pred.imag.max()),
        max_abs_s_pred=float(np.max(np.abs(pred.real))),
        max_abs_c_pred=float(np.max(np.abs(pred.imag))),
        r_mean=float(r_inst.mean()), r_std=float(r_inst.std()),
        span_deg=float(np.degrees(w * (len(s) - 1) * dt)),
    )


def main():
    args = sys.argv[1:]
    f_in = None
    if "--f" in args:
        i = args.index("--f")
        f_in = float(args[i + 1])
        del args[i:i + 2]
    for p in args:
        R = fit(p, f_in)
        print(f"\n=== {R['path']}  ({R['n']} 拍, 弧长 {R['span_deg']:.1f} deg, f_in={f_in/1e3:.3f} kHz)")
        print(f"  [正弦拟合 符号{R['sgn']:+d}] 圆心 O = ({R['Os']:+.1f}, {R['Oc']:+.1f}) LSB, 半径 A = {R['A']:.1f} LSB,"
              f" 残差 RMS = {R['res_rms']:.2f} LSB")
        print(f"  [Kasa 圆拟合]            圆心 O = ({R['O_kasa'].real:+.1f}, {R['O_kasa'].imag:+.1f}) LSB,"
              f" 半径 A = {R['A_kasa']:.1f} LSB, 残差 RMS = {R['res_kasa_rms']:.2f} LSB")
        print(f"  实测 |s| max = {R['max_abs_s']:.0f}, |c| max = {R['max_abs_c']:.0f}")
        print(f"  正弦拟合 max|s| = |Os|+A = {abs(R['Os'])+R['A']:.1f}   max|c| = |Oc|+A = {abs(R['Oc'])+R['A']:.1f}")
        print(f"  Kasa   max|s| = |Os|+A = {abs(R['O_kasa'].real)+R['A_kasa']:.1f}   max|c| = |Oc|+A = {abs(R['O_kasa'].imag)+R['A_kasa']:.1f}")
        print(f"  s_raw 范围 [{R['s_min']:.0f}, {R['s_max']:.0f}]  c_raw 范围 [{R['c_min']:.0f}, {R['c_max']:.0f}]")
        print(f"  |x| 均值 {R['r_mean']:.1f} +/- {R['r_std']:.1f}")
        ms = max(abs(R['Os']) + R['A'], abs(R['O_kasa'].real) + R['A_kasa'])
        print(f"  >>> S 通道码能否到 |s| >= 1536.5 ?  {'能' if ms >= 1536.5 else '不能'}"
              f"  (余量 {ms-1536.5:+.1f} LSB)")


if __name__ == "__main__":
    main()
