"""v68 上板只读检查：版本 / ABZ 配置 / 增益 / 锁定 / 幅值 / 告警。"""
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))

import link as lk
import regs as rg
import alarm as sg

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM9"


def w32(w, base):
    lo = w.read_reg(base, timeout=0.4, retries=2)
    hi = w.read_reg(base + 2, timeout=0.4, retries=2)
    if lo is None or hi is None:
        return None
    return (lo["value"] | (hi["value"] << 16)) & 0xFFFFFFFF


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
        build = info.get("rtl_build")
        print("PORT=%s  DEVICE_ID=0x%04X  REV=0x%04X  RTL_BUILD=0x%04X"
              % (PORT, info.get("device_id") or 0, info.get("rev") or 0, build or 0))

        inter0 = w.read_reg(rg.REG_INTER0, timeout=0.4, retries=2)
        inter1 = w.read_reg(rg.REG_INTER1, timeout=0.4, retries=2)
        pairs = w.read_reg(rg.REG_PAIRS, timeout=0.4, retries=2)
        out = w.read_reg(rg.REG_OUTPUT, timeout=0.4, retries=2)
        ablim = w.read_reg(rg.REG_ABLIMIT, timeout=0.4, retries=2)
        lock = w.read_reg(rg.REG_LOCK_STATE, timeout=0.4, retries=2)
        sticky = w.read_reg(rg.REG_LOCK_STICKY, timeout=0.4, retries=2)
        gain_lo = w.read_reg(0x0514, timeout=0.4, retries=2)
        gain_hi = w.read_reg(0x0515, timeout=0.4, retries=2)
        shift = w.read_reg(0x051A, timeout=0.4, retries=2)
        flags = w.read_reg(sg.REG_STAT_FLAGS, timeout=0.4, retries=2)
        statv = w.read_reg(sg.REG_STAT_VAL, timeout=0.4, retries=2)
        amp = w32(w, sg.REG_STAT_AMP_SQ)
        lo_th = w32(w, 0x0520)
        hi_th = w32(w, 0x0524)

        def hexv(r):
            return "None" if r is None else "0x%04X" % r["value"]

        print("0x0100 pairs     = %s" % hexv(pairs))
        print("0x0101 inter_lo  = %s" % hexv(inter0))
        print("0x0102 inter_hi  = %s" % hexv(inter1))
        print("0x0106 ablimit   = %s" % hexv(ablim))
        print("0x0109 output    = %s" % hexv(out))
        print("0x0130 lock      = %s" % hexv(lock))
        print("0x0131 sticky    = %s" % hexv(sticky))
        print("0x0514 gain_lo   = %s" % hexv(gain_lo))
        print("0x0515 gain_hi   = %s" % hexv(gain_hi))
        print("0x051A shift     = %s" % hexv(shift))
        print("0x0404 stat_val  = %s" % hexv(statv))
        print("0x053A stat_flags= %s" % hexv(flags))
        print("0x0530 amp_sq    = %s" % ("None" if amp is None else "%d (%.4f FS^2)" % (amp, amp / float(1 << 30))))
        print("0x0520 amp_low   = %s" % ("None" if lo_th is None else "%d (r=%.2f)" % (lo_th, (lo_th / float(1 << 30)) ** 0.5)))
        print("0x0524 amp_high  = %s" % ("None" if hi_th is None else "%d (r=%.2f)" % (hi_th, (hi_th / float(1 << 30)) ** 0.5)))

        # 读一帧实时数据，看 s/c/角度
        frames = []
        t1 = time.monotonic()
        while time.monotonic() - t1 < 0.5 and not frames:
            try:
                kind, _text, extra = w.events.get(timeout=0.2)
                if kind == "batch":
                    frames = extra.get("frames") or []
            except Exception:
                pass
        if frames:
            f = frames[-1]
            print("frame: angle=%.2f deg  s=%d c=%d  state=0x%02X"
                  % (f.get("angle_deg", 0), f.get("s", 0), f.get("c", 0), f.get("io_state", 0)))

        errors = []
        if build not in (0x0010, 0x0011):
            errors.append("RTL_BUILD not in {0x0010,0x0011} (got %s)" % ("None" if build is None else "0x%04X" % build))
        inter = None
        if inter0 and inter1:
            inter = inter0["value"] | ((inter1["value"] & 0x3) << 8)
        if inter != 32:
            errors.append("inter != 32 (got %s)" % inter)
        if gain_lo and gain_hi:
            g = gain_lo["value"] | (gain_hi["value"] << 8)
            if g != 32768:
                errors.append("gain != 32768 (got %d)" % g)
        if lock and (lock["value"] & 0x3) != 1:
            errors.append("lock != TRACK (got 0x%X)" % lock["value"])
        if flags and (flags["value"] & 0x6):
            errors.append("amp_low/high flags set (0x%X)" % flags["value"])

        if errors:
            print("FAIL:")
            for e in errors:
                print("  -", e)
            return 1
        print("PASS: v68 identity/inter/gain/lock/amp window all OK")
        return 0
    finally:
        w.stop()


if __name__ == "__main__":
    sys.exit(main())
