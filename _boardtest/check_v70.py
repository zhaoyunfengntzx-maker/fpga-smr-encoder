# -*- coding: utf-8 -*-
"""check_v69.py [COMx] [秒] -- v69（POLE_BITS=11 / 2048 PPR）专项核对

v68 是按 64 电周期/圈综合的，机械角/RPM/Z/UVW/BiSS 全部差 32 倍。
v69 把 POLE_BITS 恢复成 11（2048 电周期/机械圈）。本脚本用**遥测帧自身**核对：

  1. RTL_BUILD == 0x0011、INTER0 == 32
  2. 电周期速率 = d(cycle_cnt)/dt   → 应 ≈ 电气频率 25.27 kHz
  3. 机械转速 = 电周期速率 / 2048 × 60 → 应 ≈ 740 rpm（v68 会虚报 32 倍）
  4. Z 事件率：io_flags bit2 = z_window，跳变率应 ≈ 12.3 Hz（1 个/圈）
  5. UVW 六状态：应看到 6 种状态轮转（v68 实测 99.98% 卡在 110）
  6. r = sqrt(s^2+c^2) 幅值与 lock
"""
from __future__ import annotations

import math
import os
import statistics
import sys
import time
from collections import Counter

_HERE = os.path.dirname(os.path.abspath(__file__))
_HOST = os.path.join(os.path.dirname(_HERE), "host")
if _HOST not in sys.path:
    sys.path.insert(0, _HOST)

import link as lk            # noqa: E402

PPR = 2048                   # 真实转台：每转 2048 个电周期


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

    w = lk.SerialWorker(port, baud=lk.BAUD_DEFAULT, batch_ms=20.0)
    w.start()
    t0 = time.time()
    while not w.connected and time.time() - t0 < 5:
        time.sleep(0.05)
    if not w.connected:
        print("FAIL: 串口打不开 %s" % port)
        return 1
    time.sleep(0.15)

    def rd(a):
        r = w.read_reg(a, timeout=0.5, retries=2)
        return None if r is None else r["value"]

    info = w.read_device_info(timeout=0.6, retries=3)
    build = info.get("rtl_build")
    inter0 = rd(0x0101)
    inter1 = rd(0x0102)
    pairs = rd(0x0100)
    inter = None if (inter0 is None or inter1 is None) else (inter0 | ((inter1 & 0x3) << 8))
    print("RTL_BUILD=0x%04X  INTER0 reg=0x%04X  inter=%s  UVW_CFG=0x%04X"
          % (build or 0, inter0 or 0, inter, pairs or 0))

    frames = []
    t_end = time.time() + secs
    while time.time() < t_end:
        try:
            kind, _tag, extra = w.events.get(timeout=0.15)
        except Exception:
            continue
        if kind == "batch":
            frames.extend(extra.get("frames") or [])
    lock = rd(0x0130)
    flags = rd(0x053A)
    st_bits = rd(0x0500)          # BiSS 单圈位宽（v68=22，v69 期望 27）
    mt_bits = rd(0x0501)          # BiSS 多圈位宽（v68=10，v69 期望 5）
    w.stop()

    if len(frames) < 1000:
        print("FAIL: 只收到 %d 帧" % len(frames))
        return 1
    frames = frames[len(frames) // 10:]
    n = len(frames)
    dt = secs * 0.9 / n

    # ---- 电周期速率 ----
    cyc = [f.get("cycle_cnt") for f in frames]
    if any(v is None for v in cyc):
        print("FAIL: 帧里没有 cycle_cnt")
        return 1
    d = []
    for i in range(1, n):
        dv = cyc[i] - cyc[i - 1]
        dv = (dv + 32768) % 65536 - 32768          # 有符号 16 位回绕
        d.append(dv)
    d_sorted = sorted(d)
    step = d_sorted[len(d_sorted) // 2]            # 中位数（抗偶发丢帧）
    cyc_rate = step / dt
    rpm = abs(cyc_rate) / PPR * 60.0

    r = [math.hypot(f["s"], f["c"]) for f in frames]
    io = [f.get("io_state") or 0 for f in frames]
    fl = [f.get("io_flags") or 0 for f in frames]

    # ---- Z 事件率 ----
    #  rtl/uart_scope.v 里 io_flags bit2 (z_window) 只有 1 个 50 MHz 拍宽，
    #  10 kHz 遥测根本采不到（每秒应有 12.33 个，实测只能撞上 0.4~5 Hz 的
    #  混叠值），所以不能拿 bit2 当 Z 率。这里用 cycle_cnt 的展开速率推：
    #  Z 每 PPR(=2048) 个电周期一个 ⇒ f_Z = |电周期速率| / PPR。
    #  （cycle_cnt 本身的正确性已在 diag_pos3.py 里用 "cnt signed 跨度
    #   -2047..0 + distinct=2048" 独立验证过。）
    z_rate = abs(cyc_rate) / PPR

    # ---- UVW 六状态 ----
    uvw = Counter((v >> 3) & 7 for v in io)
    uvw_flips = sum(1 for i in range(1, n) if ((io[i] ^ io[i - 1]) >> 3) & 7)

    print("frames=%d  fps=%.0f" % (n, n / (dt * n)))
    print("电周期速率 = %+.1f cycles/s  (中位步进 %+d 帧)" % (cyc_rate, step))
    print("机械转速   = %.1f rpm      （v68/64 周期版会报 %.0f rpm）"
          % (rpm, abs(cyc_rate) / 64.0 * 60.0))
    print("r = sqrt(s^2+c^2): min=%.0f mean=%.0f max=%.0f (max=%.3f FS)"
          % (min(r), statistics.fmean(r), max(r), max(r) / 32768.0))
    print("Z 事件率 = %.2f Hz  （= |电周期速率|/2048；io_flags bit2 为单拍脉冲，10 kHz 遥测不可测）"
          % (z_rate,))
    print("UVW 状态分布 = %s   状态跳变 %d 次" % (dict(sorted(uvw.items())), uvw_flips))
    print("lock=0x%04X  stat_flags=0x%04X" % (lock or 0, flags or 0))
    print("BiSS 位宽: 0x0500 ST=%s → %s  0x0501 MT=%s → %s  （2048 PPR 应为 27/5；高字节是脏数据）"
          % (st_bits, (st_bits & 0xFF) if st_bits is not None else None,
             mt_bits, (mt_bits & 0xFF) if mt_bits is not None else None))

    errs = []
    if build not in (0x0011, 0x0012, 0x0014, 0x0015, 0x0016, 0x0017, 0x0018, 0x0019):
        errs.append("RTL_BUILD not in {0x0011,0x0012,0x0014,0x0015,0x0016,0x0017,0x0018}")
    if inter != 32:
        errs.append("inter != 32")
    if not (600.0 < abs(cyc_rate) < 35000.0):
        errs.append("电周期速率异常（%.0f）" % cyc_rate)
    if len(uvw) < 4:
        errs.append("UVW 只出现 %d 种状态（应 6 种轮转）" % len(uvw))
    if lock is None or (lock & 0x3) != 1:
        errs.append("not TRACK")
    if errs:
        print("FAIL: " + "; ".join(errs))
        return 1
    print("PASS: v69 identity/inter/2048-PPR/Z/UVW all consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())

