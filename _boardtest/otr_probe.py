"""清 OTR 后连续读 STAT_FLAGS，判断是常高、间歇还是清除有效。"""
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))

import link as lk

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM9"


def rd(w, addr):
    r = w.read_reg(addr, timeout=0.3, retries=1)
    return None if r is None else r["value"]


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
        print("before flags=0x%04X latch=0x%04X" % (rd(w, 0x053A), rd(w, 0x0405)))
        w.write_reg(0x0405, 0x0001, timeout=0.5, retries=1)
        vals = []
        for i in range(40):
            vals.append(rd(w, 0x053A))
            time.sleep(0.002)
        print("after clear, 40 reads @2ms:")
        print(" ".join("----" if v is None else "%04X" % v for v in vals))
        print("OTR set count:", sum(1 for v in vals if v is not None and (v & 0x8)))
        lo = rd(w, 0x0530)
        hi = rd(w, 0x0532)
        if lo is not None and hi is not None:
            amp = lo | (hi << 16)
            print("amp_sq=%d  (%.4f FS^2)" % (amp, amp / float(1 << 30)))
        print("gain_s=%s gain_c=%s shift=%s" % (rd(w, 0x0514), rd(w, 0x0516), rd(w, 0x051A)))
        return 0
    finally:
        w.stop()


if __name__ == "__main__":
    sys.exit(main())
