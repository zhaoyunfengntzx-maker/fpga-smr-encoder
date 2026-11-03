# -*- coding: utf-8 -*-
"""从 tools/cap_dump.py 导出的 CSV 估测 sin/cos 频率、幅值、正交度。

用法： python _boardtest/freq_check.py _boardtest/cap_v71.csv [fs]
CSV 约定：第 0 列时间、第 1 列 CH1(sin)、第 2 列 CH2(cos)。
缺块（全零 64 点）会被整块剔除，避免把零段当信号。
"""
import sys
import numpy as np

path = sys.argv[1] if len(sys.argv) > 1 else "_boardtest/cap_v71.csv"
fs = float(sys.argv[2]) if len(sys.argv) > 2 else 25e6

d = np.loadtxt(path, delimiter=",", skiprows=1)
x = d[:, 1].astype(float)
y = d[:, 2].astype(float)

B = 64
n = len(x) // B
ok = np.array([np.any(x[i * B:(i + 1) * B] != 0) for i in range(n)])
mask = np.repeat(ok, B)
xf, yf = x[mask], y[mask]
print("blocks %d, zero-blocks %d, kept samples %d" % (n, (~ok).sum(), len(xf)))


def f0_of(z):
    z = z - z.mean()
    w = np.hanning(len(z))
    Z = np.abs(np.fft.rfft(z * w))
    fr = np.fft.rfftfreq(len(z), 1.0 / fs)
    k = int(np.argmax(Z[1:])) + 1
    if 0 < k < len(Z) - 1:
        a, b, c = Z[k - 1], Z[k], Z[k + 1]
        den = (a - 2 * b + c)
        dk = 0.5 * (a - c) / den if den != 0 else 0.0
    else:
        dk = 0.0
    return (k + dk) * fs / len(z), Z, fr


f1, Z1, fr = f0_of(xf)
f2, _, _ = f0_of(yf)
print("f0: CH1 = %.1f Hz   CH2 = %.1f Hz   diff = %.1f Hz" % (f1, f2, f2 - f1))

# 在 f0 处拟合 A*cos + B*sin + C（逐通道），得到幅值/相位
def fit(z, f):
    t = np.arange(len(z)) / fs
    w = 2 * np.pi * f
    M = np.column_stack([np.cos(w * t), np.sin(w * t), np.ones(len(z))])
    coef, *_ = np.linalg.lstsq(M, z, rcond=None)
    a, b, c = coef
    amp = np.hypot(a, b)
    ph = np.degrees(np.arctan2(-b, a))
    resid = z - M @ coef
    return amp, ph, c, resid


f = 0.5 * (f1 + f2)
a1, p1, c1, r1 = fit(xf, f)
a2, p2, c2, r2 = fit(yf, f)
FS = 4096.0
print("CH1: A=%.1f (%.3f FS) dc=%.1f phase=%.2f deg rms_resid=%.1f%%"
      % (a1, a1 / FS, c1, p1, 100 * r1.std() / a1))
print("CH2: A=%.1f (%.3f FS) dc=%.1f phase=%.2f deg rms_resid=%.1f%%"
      % (a2, a2 / FS, c2, p2, 100 * r2.std() / a2))
print("amp mismatch = %.2f%%" % (100 * abs(a1 - a2) / ((a1 + a2) / 2)))
dp = (p2 - p1 + 180.0) % 360.0 - 180.0
print("quadrature error = %.2f deg (ideal -90, i.e. cos lags sin by 90)" % dp)
print("pp: CH1=%.0f CH2=%.0f" % (xf.max() - xf.min(), yf.max() - yf.min()))
