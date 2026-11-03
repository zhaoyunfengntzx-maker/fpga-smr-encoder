# -*- coding: utf-8 -*-
"""angle_vs_sc.py  [COMx] [秒] -- 用 10 kHz 遥测帧核对 FPGA 输出角度 vs atan2(s,c)

判据思路
--------
每帧同时携带 FPGA 的 16 位电角度 angle 和该帧的 s/c 分量。如果两者是同一时刻
的同一组数，那么 angle ≈ atan2(s,c)（差一个常数量化/流水线偏移）。
把每帧误差按 -180..180 归一后统计：
  * 均值（常数偏移）= 流水线延迟或象限约定
  * 标准差/RMS      = 细分噪声（核心指标）
  * 按角度分箱的均值 = 系统误差（2/4 次谐波、LUT 非线性）
"""
from __future__ import annotations

import math
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_HOST = os.path.join(os.path.dirname(_HERE), "host")
if _HOST not in sys.path:
    sys.path.insert(0, _HOST)

import link as lk            # noqa: E402
import regs as rg            # noqa: E402

REG_STAT_LATCH = 0x0405


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

    w = lk.SerialWorker(port, baud=lk.BAUD_DEFAULT, batch_ms=20.0)
    w.start()
    import time
    t0 = time.time()
    while not w.connected and time.time() - t0 < 5:
        time.sleep(0.05)
    if not w.connected:
        print("FAIL: 串口打不开 %s" % port)
        return 1
    time.sleep(0.2)
    try:
        w.write_reg(REG_STAT_LATCH, 0x0001, verify=False)
    except Exception:
        pass

    frames = []
    t_end = time.time() + secs
    while time.time() < t_end:
        try:
            kind, _tag, extra = w.events.get(timeout=0.1)
        except Exception:
            continue
        if kind == "batch":
            frames.extend(extra["frames"])
    w.stop()

    if len(frames) < 1000:
        print("FAIL: 只收到 %d 帧" % len(frames))
        return 1

    # 丢掉开头 10%（标定/重同步瞬态）
    frames = frames[len(frames) // 10:]
    ang = np.array([f["angle_deg"] for f in frames], dtype=float)
    s = np.array([f["s"] for f in frames], dtype=float)
    c = np.array([f["c"] for f in frames], dtype=float)
    r = np.hypot(s, c)

    theta = np.degrees(np.arctan2(s, c)) % 360.0      # atan2(s,c): 0 => c>0,s=0
    err = (ang - theta + 180.0) % 360.0 - 180.0

    # 用圆周均值抵消"整体旋转"，再看残差
    k = np.exp(1j * np.radians(err))
    mean_err = math.degrees(math.atan2(k.imag.mean(), k.real.mean()))
    resid = (err - mean_err + 180.0) % 360.0 - 180.0

    print("frames=%d  fps=%.1f" % (len(frames), len(frames) / secs))
    print("r=sqrt(s^2+c^2): min=%.0f mean=%.0f max=%.0f  (FS=32768, mean=%.4f FS)"
          % (r.min(), r.mean(), r.max(), r.mean() / 32768.0))
    print("angle vs atan2(s,c): mean offset=%.3f deg  RMS=%.3f deg  max|resid|=%.3f deg"
          % (mean_err, float(np.sqrt((resid ** 2).mean())), float(np.abs(resid).max())))
    print("  90%% 分位 |resid| = %.3f deg   (若 <0.2 deg = 16bit 量化极限附近)"
          % float(np.percentile(np.abs(resid), 90)))

    # 系统误差：按角度分 16 箱看均值，谐波含量
    bins = 16
    idx = np.floor((theta % 360.0) / (360.0 / bins)).astype(int) % bins
    vals = []
    for b in range(bins):
        m = idx == b
        if m.sum() > 20:
            vals.append((b * 360.0 / bins, float(resid[m].mean()), int(m.sum())))
    print("角度分箱残差(度)：")
    for a, v, n in vals:
        print("  %6.1f° : %+7.3f  (n=%d)" % (a, v, n))
    if len(vals) >= 8:
        amp = np.array([v for _a, v, _n in vals])
        spec = np.abs(np.fft.rfft(amp - amp.mean())) / len(amp) * 2
        print("分箱误差谐波幅值(度): h1=%.3f h2=%.3f h3=%.3f h4=%.3f"
              % (spec[1], spec[2], spec[3], spec[4]))

    # 存原始 CSV 供画图
    out = os.path.join(_HERE, "angle_vs_sc.csv")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("ang_deg,theta_deg,err_deg,s,c,r\n")
        for i in range(len(ang)):
            fh.write("%.3f,%.3f,%.4f,%.0f,%.0f,%.0f\n"
                     % (ang[i], theta[i], err[i], s[i], c[i], r[i]))
    print("CSV -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
