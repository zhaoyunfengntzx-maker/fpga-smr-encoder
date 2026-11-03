"""Read loop integrator speed (ff_speed) and derive electrical freq / mech rpm.

ff_speed LSB = 1/65536 electrical cycle per 100 kHz sample (per docs/regs),
so f_el = ff_speed * 10000 / 65536 Hz (decimated rate = 10 kHz).
"""
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))

import link as lk

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
PPR = int(sys.argv[2]) if len(sys.argv) > 2 else 2048


def s24(v):
    return v - (1 << 24) if v & 0x800000 else v


def main():
    w = lk.SerialWorker(PORT, baud=lk.BAUD_DEFAULT)
    w.start()
    try:
        t0 = time.monotonic()
        while not w.connected and time.monotonic() - t0 < 5.0:
            if w.error:
                print("ERROR:", w.error)
                return 1
            time.sleep(0.02)
        for name, addr in (("BUILD", 0x05F2), ("LOCK", 0x0130),
                           ("STAT_VAL", 0x0404), ("STAT_LATCH", 0x0405)):
            r = w.read_reg(addr, timeout=0.4, retries=2)
            print("%-10s 0x%04X" % (name, r["value"] if r else 0xFFFF))

        vals = []
        for _ in range(8):
            b = []
            for a in (0x0124, 0x0125, 0x0126):
                r = w.read_reg(a, timeout=0.4, retries=2)
                b.append(r["value"] if r else 0)
            raw = b[0] | (b[1] << 8) | (b[2] << 16)
            sp = s24(raw)
            vals.append(sp)
            f_el = sp * 10000.0 / 65536.0
            rpm = f_el / PPR * 60.0
            print("ff_speed=0x%06X (%7d)  f_el=%9.1f Hz  rpm(PPR=%d)=%8.1f"
                  % (raw & 0xFFFFFF, sp, f_el, PPR, rpm))
            time.sleep(0.1)

        # aliased view: what the 64-cycle build would report
        if vals:
            f = abs(sum(vals) / len(vals)) * 10000.0 / 65536.0
            print("mean f_el=%.1f Hz -> real rpm=%.1f ; v68(64cpr) shows %.1f rpm"
                  % (f, f / PPR * 60.0, f / 64.0 * 60.0))
        return 0
    finally:
        w.stop()


if __name__ == "__main__":
    sys.exit(main())
