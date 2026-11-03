"""读标定相关寄存器，核对 P7 页面显示的六个参数"""
import sys, time
sys.path.insert(0, r"C:\Users\zhaoy\Desktop\FPGA")
from host import link as lk

REGS = [
    (0x0510, "OFS_S_LO"), (0x0511, "OFS_S_HI"),
    (0x0512, "OFS_C_LO"), (0x0513, "OFS_C_HI"),
    (0x0514, "GAIN_S_LO"), (0x0515, "GAIN_S_HI"),
    (0x0516, "GAIN_C_LO"), (0x0517, "GAIN_C_HI"),
    (0x0518, "PHASE_LO"), (0x0519, "PHASE_HI"),
    (0x051A, "SHIFT"),
    (0x0530, "AMP_SQ_LO"), (0x0531, "AMP_SQ_HI"),
    (0x0520, "AMP_LOW_LO"), (0x0521, "AMP_LOW_HI"),
    (0x0524, "AMP_HIGH_LO"), (0x0525, "AMP_HIGH_HI"),
    (0x054A, "ZCNT_0"), (0x054B, "ZCNT_1"), (0x054C, "ZCNT_2"), (0x054D, "ZCNT_3"),
]

port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
w = lk.SerialWorker(port, baud=lk.BAUD_DEFAULT)
w.start()
time.sleep(0.8)
print("connected=%s error=%s port=%s" % (getattr(w, "connected", "?"), getattr(w, "error", "?"), port))
vals = {}
for addr, name in REGS:
    d = w.read_reg(addr)
    v = d["value"] if d else None
    vals[addr] = v
    print("%-12s 0x%04X = %s" % (name, addr, ("0x%04X" % v) if v is not None else "None"))

def w16(lo, hi, signed=False):
    a, b = vals[lo], vals[hi]
    if a is None or b is None:
        return None
    v = ((b & 0xFF) << 8) | (a & 0xFF)
    if signed and v & 0x8000:
        v -= 0x10000
    return v

def w32(a0):
    parts = [vals.get(a0 + i) for i in range(4)]
    if any(p is None for p in parts):
        return None
    return sum(((p & 0xFF) << (8 * i)) for i, p in enumerate(parts))

ofs_s = w16(0x0510, 0x0511, signed=True)
ofs_c = w16(0x0512, 0x0513, signed=True)
gain_s = w16(0x0514, 0x0515)
gain_c = w16(0x0516, 0x0517)
amp_sq = w32(0x0530)
amp_low = w32(0x0520)
amp_high = w32(0x0524)
zcnt = w32(0x054A)
print()
print("OFS_S = %s   OFS_C = %s" % (ofs_s, ofs_c))
print("GAIN_S = %s (=%.4f)   GAIN_C = %s (=%.4f)" % (
    gain_s, (gain_s or 0) / 32768.0, gain_c, (gain_c or 0) / 32768.0))
print("PHASE = %s  SHIFT = %s" % (w16(0x0518, 0x0519, signed=True), vals.get(0x051A)))
if amp_sq:
    print("AMP_SQ = %d (Q2.30 -> %.4f FS^2, r=%.4f FS)" % (
        amp_sq, amp_sq / 2.0 ** 30, (amp_sq / 2.0 ** 30) ** 0.5))
if amp_low and amp_high:
    lo = amp_low >> 15
    hi = amp_high >> 15
    mid = (amp_sq >> 15) if amp_sq else 0
    pct = (mid - lo) * 1000.0 / (hi - lo) if hi > lo else 0
    print("amp_low>>15 = %d  amp_high>>15 = %d  (amp_sq>>15) = %d  -> pct = %.1f%%" % (lo, hi, mid, pct))
print("ZCNT = %s" % zcnt)
w.stop()
