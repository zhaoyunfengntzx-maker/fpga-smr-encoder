"""第二遍侦察：板上角度到底在不在走？（只读）

第一遍发现的异常：`0x0130` 报 LOST（掉锁），`0x013C` 报偏置无效，而 arctan2(s,c)
与板上角度字差了 ±4°（RMS 3.5°）。得先分清是「板子失锁」还是「我的比较口径错了」。
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))

import numpy as np

import analysis as an
import link as lk


def main(argv):
    port = argv[1] if len(argv) > 1 else "COM4"
    secs = float(argv[2]) if len(argv) > 2 else 8.0
    w = lk.SerialWorker(port)
    w.start()
    frames = []
    try:
        time.sleep(0.4)
        t0 = time.monotonic()
        while time.monotonic() - t0 < secs:
            try:
                kind, _t, extra = w.events.get(timeout=0.2)
            except Exception:                                    # noqa: BLE001
                continue
            if kind == "batch":
                frames.extend(extra.get("frames") or [])
    finally:
        w.stop()

    n = len(frames)
    print("帧数 %d（%.1f s）" % (n, secs))
    s = np.array([f.get("s") or 0 for f in frames], float)
    c = np.array([f.get("c") or 0 for f in frames], float)
    th = np.array([(f.get("angle_deg") if f.get("angle_deg") is not None
                    else (f.get("angle") or 0) * 360.0 / 65536.0) for f in frames], float)
    th_i = np.degrees(np.arctan2(s, c)) % 360.0

    def step(a):
        d = np.diff(a)
        return (d + 180.0) % 360.0 - 180.0

    db, di = step(th), step(th_i)
    print("板上角度 每样点步长：均值 %+.4f° ｜ 中位 %+.4f° ｜ rms %.4f°"
          % (db.mean(), np.median(db), np.sqrt((db ** 2).mean())))
    print("arctan2  每样点步长：均值 %+.4f° ｜ 中位 %+.4f° ｜ rms %.4f°"
          % (di.mean(), np.median(di), np.sqrt((di ** 2).mean())))
    print("  ⇒ arctan2 折算电角速度：%.1f °/s（%.2f Hz 电周期）"
          % (di.mean() * 10000.0, abs(di.mean()) * 10000.0 / 360.0))

    # 板子角度是不是"跳"的：连续两个步长符号相反且都很大
    big = np.abs(db) > 1.0
    print("板上角度 |步长|>1° 的比例：%.3f%%" % (100.0 * big.mean()))
    print("板上角度 直方图（步长 0.05° 分箱，前 5 个峰）：")
    h, e = np.histogram(db, bins=40, range=(-1.0, 1.0))
    for i in np.argsort(h)[-5:][::-1]:
        print("     %+6.3f° 附近 %d 个" % ((e[i] + e[i + 1]) / 2, h[i]))

    # 残差随角度：是平滑曲线还是随机？
    resid = (th_i - th + 180.0) % 360.0 - 180.0      # 单位：度
    bins = 36
    idx = np.minimum((th // (360.0 / bins)).astype(int), bins - 1)
    print("残差（arctan2 − 板上）按板上角度 10° 分箱：")
    for b in range(bins):
        m = idx == b
        if m.sum() < 50:
            continue
        r = resid[m]
        print("   %3d°..%3d°  n=%-5d 均值 %+7.2f°  标准差 %5.2f°"
              % (b * 10, b * 10 + 10, m.sum(), r.mean(), r.std()))

    print("前 12 帧原始对照（角度 / arctan2 / 差）：")
    for k in range(12):
        print("   %8.2f  %8.2f  %+7.2f   s=%6d c=%6d"
              % (th[k], th_i[k], resid[k], s[k], c[k]))

    # 信号本身
    amp = np.hypot(s, c)
    print("幅值 |s+ic|：均值 %.0f ｜ p1 %.0f ｜ p99 %.0f ｜ 满刻度 32768"
          % (amp.mean(), np.percentile(amp, 1), np.percentile(amp, 99)))
    fl = [f.get("io_flags") for f in frames if f.get("io_flags") is not None]
    if fl:
        fl = np.array(fl, int)
        print("io_flags：lag_warn %.2f%% ｜ lag_fatal %.2f%% ｜ cor_sat %.2f%% ｜ amp 越界 %.2f%%"
              % (100.0 * (fl & 1).mean(), 100.0 * ((fl >> 1) & 1).mean(),
                 100.0 * ((fl >> 6) & 1).mean(), 100.0 * ((fl >> 7) & 1).mean()))
    st = [f.get("stat") for f in frames if f.get("stat") is not None]
    if st:
        st = np.array(st, int)
        print("stat 取值分布：", {int(k): int(v) for k, v in
                                zip(*np.unique(st, return_counts=True))})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
