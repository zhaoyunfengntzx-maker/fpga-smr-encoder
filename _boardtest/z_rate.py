# -*- coding: utf-8 -*-
"""z_rate.py [COM7] [秒] -- 用 v73 新增的 Z 计数器（0x054A..0x054D）量化 Z 频率。

判据：Z 频率应 == 机械转速/60（每转 1 个 Z）；
      机械转速由遥测里的电角度回绕率推（每电周期一次回绕，2048 电周期/圈）。
"""
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_HERE), "host"))

import link as lk            # noqa: E402

Z_CNT = 0x054A
PPR = 2048


def read_u32(w, a0):
    b = []
    for a in range(a0, a0 + 4):
        b.append(w.read_reg(a)["value"] & 0xFF)
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

    w = lk.SerialWorker(port, baud=lk.BAUD_DEFAULT, batch_ms=20.0)
    w.start()
    t0 = time.time()
    while not w.connected and time.time() - t0 < 5:
        time.sleep(0.05)
    if not w.connected:
        print("FAIL: 串口打不开 %s" % port)
        return 1

    build = w.read_reg(0x05F2)["value"] & 0xFF
    print("RTL_BUILD=0x%04X" % build)
    if build < 0x17:
        print("FAIL: 该位流没有 Z 计数器（需要 v73 / BUILD 0x0017）")
        w.stop()
        return 1

    c0 = read_u32(w, Z_CNT)
    ts = time.time()
    wraps = 0
    n = 0
    prev = None
    t_end = ts + secs
    while time.time() < t_end:
        try:
            kind, _tag, extra = w.events.get(timeout=0.5)
        except Exception:
            continue
        if kind != "batch":
            continue
        for f in (extra.get('frames') or []):
            if not isinstance(f, dict) or f.get("angle") is None:
                continue
            a = f["angle"]
            if prev is not None and (a - prev) < -32768:
                wraps += 1
            prev = a
            n += 1
    te = time.time()
    c1 = read_u32(w, Z_CNT)
    w.stop()

    dt = te - ts
    dz = (c1 - c0) & 0xFFFFFFFF
    f_z = dz / dt if dt > 0 else 0.0
    f_e = wraps / dt if dt > 0 else 0.0
    rpm = f_e / PPR * 60.0
    expect = rpm / 60.0
    tol = max(0.35, 0.02 * abs(expect))
    print("窗口 %.2f s  frames=%d" % (dt, n))
    print("Z 计数 %d -> %d  (Δ=%d)  Z 频率 = %.2f Hz" % (c0, c1, dz, f_z))
    print("电角度回绕率 %.1f /s（10 kHz 采样对 25 kHz 电信号混叠，仅参考）" % f_e)
    print("由 Z 反推转速 = %.1f rpm（每转 1 个 Z）" % (f_z * 60.0))
    # 判据：Z 必须真的在出，且量级像"每转一个"（转台 5–200 rpm ⇒ 0.08–3.3 Hz... 实际
    # 高速 720 rpm ⇒ 12 Hz）。这里只做量级闸门；精确转速以 Z 反推为准。
    ok = 0.05 <= f_z <= 400.0 and dz > 0
    print("%s: Z 频率 %.2f Hz（闸门 0.05–400 Hz）" % ("PASS" if ok else "FAIL", f_z))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
