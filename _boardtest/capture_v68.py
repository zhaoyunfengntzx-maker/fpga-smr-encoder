"""v68 上板动态检查：清 OTR，收 3 s 遥测，算幅值/角度/锁定。"""
import math
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))

import link as lk
import regs as rg
import alarm as sg

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM9"
SECONDS = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0


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
        if not w.connected:
            print("ERROR: serial not connected")
            return 1

        info = w.read_device_info(timeout=0.6, retries=3)
        print("build=0x%04X device=0x%04X rev=0x%04X"
              % (info.get("rtl_build") or 0, info.get("device_id") or 0, info.get("rev") or 0))

        # 清 OTR/锁存（W1C）
        r = w.write_reg(0x0405, 0x00FF, timeout=0.6, retries=1)
        print("clear 0x0405 ->", "timeout" if r is None else "0x%04X" % r["value"])

        frames = []
        t_end = time.monotonic() + SECONDS
        while time.monotonic() < t_end:
            try:
                kind, _text, extra = w.events.get(timeout=0.2)
                if kind == "batch":
                    frames.extend(extra.get("frames") or [])
            except Exception:
                pass

        lock = w.read_reg(rg.REG_LOCK_STATE, timeout=0.4, retries=2)
        flags = w.read_reg(sg.REG_STAT_FLAGS, timeout=0.4, retries=2)
        amp = w.read_reg(sg.REG_STAT_AMP_SQ, timeout=0.4, retries=2)
        amp2 = w.read_reg(sg.REG_STAT_AMP_SQ + 2, timeout=0.4, retries=2)

        if not frames:
            print("FAIL: no telemetry frames")
            return 1

        rs = [math.hypot(f["s"], f["c"]) for f in frames]
        angs = [f["angle_deg"] for f in frames]
        # 展开角度，估算转过多少度
        unwrapped = [angs[0]]
        for a in angs[1:]:
            d = a - unwrapped[-1]
            while d > 180:
                d -= 360
            while d < -180:
                d += 360
            unwrapped.append(unwrapped[-1] + d)
        span = unwrapped[-1] - unwrapped[0]

        print("frames=%d  angle: first=%.2f last=%.2f span=%.1f deg"
              % (len(frames), angs[0], angs[-1], span))
        print("r=sqrt(s^2+c^2): min=%.0f mean=%.0f max=%.0f  (FS=32768, max=%.3f FS)"
              % (min(rs), sum(rs) / len(rs), max(rs), max(rs) / 32768.0))
        print("s range %d..%d  c range %d..%d"
              % (min(f["s"] for f in frames), max(f["s"] for f in frames),
                 min(f["c"] for f in frames), max(f["c"] for f in frames)))
        print("lock=0x%04X  flags=0x%04X  amp_sq(0x0530/32)=%s/%s"
              % (lock["value"] if lock else -1, flags["value"] if flags else -1,
                 amp["value"] if amp else None, amp2["value"] if amp2 else None))

        errs = []
        #  0x0405 STAT_LATCH 位（rtl/reg_file.v:292）：
        #    bit0 = oflow/OTR（ADC 过幅）  ← 只有这一位是 OTR
        #    bit2 = lag_limit   bit3 = inclim（UVW 频率越限，与 uvw_freq_warn 同源）
        #  旧代码用 bit3 判 OTR 会误报（v68/v70 上 bit3 常置位，属已知的 uvw_freq_warn）。
        if (info.get("rtl_build") or 0) not in (0x0010, 0x0011, 0x0012, 0x0014, 0x0015):
            errs.append("build not in v68/v69/v70 白名单")
        if lock is None or (lock["value"] & 0x3) != 1:
            errs.append("not TRACK")
        if flags is None or (flags["value"] & 0x1):
            errs.append("OTR(oflow) still latched")
        if flags is None or (flags["value"] & 0x6):
            errs.append("amp_low/high set")
        if max(rs) < 0.55 * 32768 or max(rs) > 1.15 * 32768:
            errs.append("amplitude out of window: %.3f FS" % (max(rs) / 32768.0))

        if errs:
            print("FAIL:")
            for e in errs:
                print("  -", e)
            return 1
        if abs(span) < 10:
            print("PASS (static): amplitude/lock/OTR OK, but angle did not move — rotate sensor to test tracking")
        else:
            print("PASS (dynamic): amplitude/lock/OTR OK, angle moved %.1f deg" % span)
        return 0
    finally:
        w.stop()


if __name__ == "__main__":
    sys.exit(main())
