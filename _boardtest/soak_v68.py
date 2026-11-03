# -*- coding: utf-8 -*-
"""soak_v68.py [COMx] [秒数] -- 长时间跑遥测，流式统计，不攒帧。

输出：
  * 帧率、r 的 min/mean/max（流式）
  * lock_state 分布、stat_flags(0x053A) 采样分布
  * io_state 里 ABZ/UVW 各电平占比与跳变次数
  * 每 10 s 一段的 r 均值与 |angle-atan2(s,c)| 的中位偏差（看有没有漂移）
  * 与 atan2 的误差：仅在 r 高于 0.5 FS 的帧上统计，避免幅度跌落帧污染
"""
from __future__ import annotations

import math
import os
import sys
import time
from collections import Counter

_HERE = os.path.dirname(os.path.abspath(__file__))
_HOST = os.path.join(os.path.dirname(_HERE), "host")
if _HOST not in sys.path:
    sys.path.insert(0, _HOST)

import link as lk            # noqa: E402
import regs as rg            # noqa: E402


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    w = lk.SerialWorker(port, baud=lk.BAUD_DEFAULT, batch_ms=20.0)
    w.start()
    t0 = time.time()
    while not w.connected and time.time() - t0 < 5:
        time.sleep(0.05)
    if not w.connected:
        print("FAIL: 串口打不开 %s" % port)
        return 1
    time.sleep(0.2)
    try:
        w.write_reg(0x0405, 0x00FF, verify=False)
    except Exception:
        pass

    n = 0
    v1_n = 0
    r_min, r_max, r_sum = 1e9, 0, 0.0
    io_prev = None
    io_flips = Counter()
    io_level = Counter()
    uvw_state = Counter()
    flags_seen = Counter()
    err_abs = 0.0
    err_n = 0
    big = 0
    seg_r = []
    seg_err = []
    seg_t = time.time()
    t_end = time.time() + secs

    while time.time() < t_end:
        try:
            kind, _tag, extra = w.events.get(timeout=0.15)
        except Exception:
            continue
        if kind != "batch":
            continue
        for f in extra.get("frames") or []:
            n += 1
            s, c = f["s"], f["c"]
            r = math.hypot(s, c)
            r_sum += r
            r_min = min(r_min, r)
            r_max = max(r_max, r)
            seg_r.append(r)
            io = f.get("io_state")
            if io is None:
                v1_n += 1
                continue
            uvw_state[(io >> 3) & 7] += 1
            for bit, name in ((0, "a"), (1, "b"), (2, "z"), (3, "u"), (4, "v"), (5, "w")):
                if (io >> bit) & 1:
                    io_level[name] += 1
            if io_prev is not None:
                for bit, name in ((0, "a"), (1, "b"), (2, "z"), (3, "u"), (4, "v"), (5, "w")):
                    if ((io ^ io_prev) >> bit) & 1:
                        io_flips[name] += 1
            io_prev = io
            if n % 5 == 0:
                th = math.degrees(math.atan2(s, c)) % 360.0
                d = (f["angle_deg"] - th + 180.0) % 360.0 - 180.0
                d = (d + 180.0) % 360.0 - 180.0
                if r > 16000:
                    err_abs += abs(d)
                    err_n += 1
                    seg_err.append(abs(d))
                    if abs(d) > 5.0:
                        big += 1
        if time.time() - seg_t >= 10.0 and seg_r:
            print("  [%4.0fs] frames=%d  r_mean=%.0f  |err|mean=%.3f"
                  % (secs - (t_end - time.time()), n, sum(seg_r) / len(seg_r),
                     (sum(seg_err) / len(seg_err)) if seg_err else 0.0))
            seg_r, seg_err = [], []
            seg_t = time.time()

    lock = w.read_reg(0x0130, timeout=0.5, retries=2)
    flags = w.read_reg(0x053A, timeout=0.5, retries=2)
    w.stop()

    print("")
    print("frames=%d (v1/无io帧=%d)  elapsed=%.1fs  fps=%.1f" % (n, v1_n, secs, n / secs))
    print("r: min=%.0f mean=%.0f max=%.0f (max=%.4f FS)" % (r_min, r_sum / max(n, 1), r_max, r_max / 32768.0))
    print("lock now=%s  stat_flags now=%s"
          % ("None" if lock is None else "0x%04X" % lock["value"],
             "None" if flags is None else "0x%04X" % flags["value"]))
    print("UVW state counts (u,v,w):", dict(sorted(uvw_state.items())))
    print("level high %%:", {k: round(100.0 * io_level[k] / n, 2) for k in "abzuvw"})
    print("flips over %d frames: %s" % (n, dict(io_flips)))
    print("angle vs atan2 (r>0.5FS, every 5th frame): mean |err|=%.3f deg  n=%d  |err|>5deg=%d"
          % (err_abs / max(err_n, 1), err_n, big))
    return 0


if __name__ == "__main__":
    sys.exit(main())
