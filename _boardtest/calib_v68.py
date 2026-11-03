"""v68 上板：跑一次一键标定，读回标定后的增益/幅值/OTR。"""
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))

import link as lk

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM9"


def u16(w, addr):
    r = w.read_reg(addr, timeout=0.5, retries=2)
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
        info = w.read_device_info(timeout=0.6, retries=3)
        print("build=0x%04X" % (info.get("rtl_build") or 0))

        # 清 OTR / 锁存
        w.write_reg(0x0405, 0x00FF, timeout=0.6, retries=1)
        print("before: gain_s=%s gain_c=%s shift=%s flags=0x%04X amp_sq=%s"
              % (u16(w, 0x0514), u16(w, 0x0516), u16(w, 0x051A),
                 u16(w, 0x053A) or 0, u16(w, 0x0530)))

        # 启动一键标定
        w.write_reg(0x0502, 0x0001, timeout=0.6, retries=1)
        print("calib start written")
        time.sleep(0.30)

        print("after:  gain_s=%s gain_c=%s shift=%s flags=0x%04X amp_sq=%s"
              % (u16(w, 0x0514), u16(w, 0x0516), u16(w, 0x051A),
                 u16(w, 0x053A) or 0, u16(w, 0x0530)))
        print("stat_val=0x%04X lock=0x%04X" % (u16(w, 0x0404) or 0, u16(w, 0x0130) or 0))
        gs = u16(w, 0x0514)
        gc = u16(w, 0x0516)
        if gs:
            print("gain_s/32768=%.3f -> raw A_s=%.3f FS" % (gs / 32768.0, 0.8 * 32768.0 / gs / 32768.0))
        if gc:
            print("gain_c/32768=%.3f -> raw A_c=%.3f FS" % (gc / 32768.0, 0.8 * 32768.0 / gc / 32768.0))
        return 0
    finally:
        w.stop()


if __name__ == "__main__":
    sys.exit(main())
