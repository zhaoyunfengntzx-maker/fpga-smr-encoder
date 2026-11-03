"""显示滤波模块自检（不依赖 Qt、不依赖板子）。

跑法：python host/selftest_filter.py
判据见 docs/23_host_display_filter_feasibility.md §9。
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np                                   # noqa: E402

import filters as fl                                 # noqa: E402

N = 0
BAD = 0


def check(name, ok, extra=""):
    global N, BAD
    N += 1
    if not ok:
        BAD += 1
    print("  [%s] %s%s" % ("ok" if ok else "FAIL", name,
                           "" if not extra else "  " + extra))


def main():
    rng = np.random.default_rng(7)
    n = 28672

    print("== 恒等/长度 ==")
    x = (rng.normal(0, 100, n)).astype(np.int16)
    check("w=0 原样返回", np.array_equal(np.asarray(fl.smooth(x, 0)), x))
    for kind in fl.SMOOTH_KINDS:
        for w in (3, 5, 9, 15):
            y = fl.smooth(x, w, kind)
            check("长度守恒 %s w=%d" % (kind, w), y.size == n)

    print("== 不篡改输入 ==")
    x0 = x.copy()
    fl.smooth(x, 9, "savgol")
    fl.envelope(x, 1000)
    check("输入数组未被修改", np.array_equal(x, x0))

    print("== 数值性质 ==")
    const = np.full(n, 1234.0)
    for kind in fl.SMOOTH_KINDS:
        y = fl.smooth(const, 9, kind)
        check("%s 常数保持" % kind, np.allclose(y, 1234.0))

    ramp = np.arange(n, dtype=np.float64)
    y = fl.savgol_filter(ramp, 11, 3)
    check("savgol 保持线性（多项式不变）",
          np.allclose(y[6:-6], ramp[6:-6], atol=1e-6))

    spike = np.zeros(n)
    spike[n // 2] = 10000
    y = fl.median_filter(spike, 9)
    check("中值滤掉孤立毛刺", abs(y[n // 2]) < 1e-6)

    noise = rng.normal(0, 50, n)
    rms0 = float(np.sqrt(np.mean(noise ** 2)))
    rms1 = float(np.sqrt(np.mean((fl.smooth(noise, 9, "savgol") - noise.mean()) ** 2)))
    check("savgol w=9 降噪 ≥ 5 dB", 20 * np.log10(rms0 / max(rms1, 1e-12)) >= 5.0,
          "%.1f dB" % (20 * np.log10(rms0 / max(rms1, 1e-12))))

    print("== 包络 ==")
    xpos, ymin, ymax = fl.envelope(x, 500)
    check("包络列数 = 500", ymin.size == 500 and ymax.size == 500)
    check("包络 min ≤ max", np.all(ymin <= ymax))
    check("包络包含全局最大值", abs(ymax.max() - x.max()) < 1e-9)
    check("包络包含全局最小值", abs(ymin.min() - x.min()) < 1e-9)
    xp2, a2, b2 = fl.envelope(x[:100], 500)
    check("点数 < 列数时退化为逐点", a2.size == 100 and np.array_equal(a2, x[:100]))

    print("== 性能（28672 点，单次） ==")
    for label, fn in (("envelope", lambda: fl.envelope(x, 1200)),
                      ("savgol 9", lambda: fl.savgol_filter(x, 9)),
                      ("median 9", lambda: fl.median_filter(x, 9)),
                      ("fir 63", lambda: fl.fir_lowpass(x))):
        t0 = time.perf_counter()
        for _ in range(5):
            fn()
        ms = (time.perf_counter() - t0) / 5 * 1e3
        check("%s < 20 ms" % label, ms < 20.0, "%.2f ms" % ms)

    print()
    print("== %d checks, %d 失败 ==" % (N, BAD))
    print("TEST PASSED" if BAD == 0 else "TEST FAILED")
    return 0 if BAD == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
