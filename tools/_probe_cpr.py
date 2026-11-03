"""量出「每转几个正弦周期」——不猜、不查表，用 Z 脉冲直接数。

原理：Z 每转一个脉冲，所以
    每转周期数 = f_in（信号频率，Hz） / f_Z（Z 脉冲频率，Hz）
分母只要 2~3 个 Z 就够，分子可以取得很长，因此哪怕转速很低也能算得准。

顺带把 device info（0x05F0…0x05F3）读出来，看和 docs/20 §12 的自动识别表对不对得上。
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))
sys.path.insert(0, HERE)

import numpy as np
import serial

import link as lk
import uart_scope as us

CAP_S = 8.0


def capture(port, seconds=CAP_S):
    ser = serial.Serial(port, 2000000, timeout=0.05)
    buf = b""
    frames = []
    t0 = time.monotonic()
    try:
        while time.monotonic() - t0 < seconds:
            buf += ser.read(16384)
            got, _ = us.parse_stream(buf)
            if got:
                frames.extend(got)
                buf = buf[-64:]
    finally:
        ser.close()
    return frames, time.monotonic() - t0


def main(argv):
    port = argv[1] if len(argv) > 1 else "COM4"
    frames, dt = capture(port)
    n = len(frames)
    if n < 1000:
        raise SystemExit("帧太少（%d），板子没在流？" % n)

    ang = np.array([f["angle_deg"] for f in frames], dtype=float)
    d = np.diff(ang)
    d = (d + 180.0) % 360.0 - 180.0            # 每样点角度增量（电角度）
    step = float(np.mean(d))
    f_in = abs(step) / 360.0 * (n / dt)        # Hz：每转 360° 一个正弦周期
    print("采集 %.2f s ｜ %d 帧 ｜ 平均每样点 %+.4f° ｜ 电频率 %.4f Hz" % (dt, n, step, f_in))

    z = np.array([1 if f.get("io_bits", {}).get("z") else 0 for f in frames], dtype=int)
    edges = int(np.sum((z[1:] == 1) & (z[:-1] == 0)))
    f_z = edges / dt
    print("Z 上升沿 %d 个 ｜ f_Z %.4f Hz ｜ Z 占空比 %.1f%%"
          % (edges, f_z, 100.0 * z.mean()))

    if f_z > 0:
        cpr = f_in / f_z
        print("每转周期数 = f_in / f_Z = %.1f" % cpr)
        for cand in (64, 1024, 2048, 4096):
            print("   候选 %5d → RPM %8.3f ｜ 误差 %+.2f%%"
                  % (cand, 60.0 * f_in / cand, 100.0 * (cpr / cand - 1.0)))
    else:
        print("没有 Z 边沿：转得太慢或 Z 没接，先转快一点再测")

    w = lk.SerialWorker(port)
    w.start()
    time.sleep(0.9)
    try:
        info = {a: w.read_reg8(a, timeout=0.6, retries=2)
                for a in (0x05F0, 0x05F1, 0x05F2, 0x05F3)}
        pairs = w.read_reg8(0x0100, timeout=0.6, retries=2)
        out = w.read_reg8(0x0101, timeout=0.6, retries=2)
    finally:
        w.stop()
    print("device 0x05F0=%s 0x05F1=%s 0x05F2=%s 0x05F3=%s ｜ 0x0100(极对数)=%s 0x0101=%s"
          % (info[0x05F0], info[0x05F1], info[0x05F2], info[0x05F3], pairs, out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
