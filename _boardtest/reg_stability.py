"""Careful repeated register reads: detect flaky/misaligned replies."""
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))

import link as lk

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"

ADDRS = [0x0404, 0x0405, 0x053A, 0x0124, 0x0125, 0x0126, 0x0130, 0x05F2, 0x0514, 0x0515, 0x051A]


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
        print("clear 0x0405 =", w.write_reg(0x0405, 0x00FF, timeout=0.6, retries=1))
        for a in ADDRS:
            vals = []
            for _ in range(6):
                r = w.read_reg(a, timeout=0.3, retries=1)
                vals.append(None if r is None else r["value"])
                time.sleep(0.05)
            print("0x%04X: %s" % (a, " ".join("----" if v is None else "%04X" % v for v in vals)))

        # speed: low/high bytes, masked
        print("--- ff_speed sampled 10x ---")
        for _ in range(10):
            lo = w.read_reg(0x0124, timeout=0.3, retries=1)
            mid = w.read_reg(0x0125, timeout=0.3, retries=1)
            hi = w.read_reg(0x0126, timeout=0.3, retries=1)
            raw = ((lo["value"] & 0xFF) if lo else 0) | \
                  (((mid["value"] & 0xFF) if mid else 0) << 8) | \
                  (((hi["value"] & 0xFF) if hi else 0) << 16)
            sp = raw - (1 << 24) if raw & 0x800000 else raw
            print("raw=0x%06X sp=%8d  f_el=%10.1f Hz" % (raw, sp, sp * 10000.0 / 65536.0))
            time.sleep(0.1)
        return 0
    finally:
        w.stop()


if __name__ == "__main__":
    sys.exit(main())
