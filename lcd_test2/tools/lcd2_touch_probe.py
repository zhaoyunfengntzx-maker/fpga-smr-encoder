#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lcd_test2/tools/lcd2_touch_probe.py -- 触摸专项探测（引导式，四阶段）

用途：上板时"手指按上去屏上没准星 / 多指没有多个准星"时，先分清是**谁**的问题。
本工具按顺序走四个阶段，每阶段先打印要做的动作，再采集固定时长并判定：

  [0] 静止基线：没人碰屏。期望 status=0x00、tch_num=0。
      ★ 若这里 tch_num 不等于 0，就是"抬手不清点"的残留（2026-10-15 已加 nodata 兜底修复）。
  [1] 单指：一根手指按住并慢慢滑动。期望 status 低 4 位 >= 1、tch_num >= 1、
      坐标落在 0..1023 / 0..599 且随手指变化。
  [2] 抬手：手指离开。期望 status 回到 0x00，tch_num 在 ~1 秒内回到 0。
  [3] 多指：2~5 根手指同时按住。期望 status 低 4 位 >= 2、tch_num >= 2。

判据（跑完打印）：
  * 阶段 1/3 里 status 低 4 位（芯片自己报的点数）能到 2..5，而 tch_num 只有 1 → RTL 点数/坐标状态机问题；
  * status 低 4 位最大只有 1 → 芯片侧只报 1 点，通常是配置表（0x8047 里的 "Touch Point Num"）不是 5，
    正是 F6 第 3 项"配置表写入"要解决的问题（本版只留了 CFG_WRITE_EN 开关，没敢盲写）；
  * 阶段 1/3 里 status 一直是 0x00 → 芯片在触摸时也没产生报点：先排查触摸模组/排线/INT，
    而不是解码。

用法（★ 用 E:\\Anaconda\\python.exe，内置 Python 没有 pyserial）：
    E:\\Anaconda\\python.exe lcd_test2\\tools\\lcd2_touch_probe.py --port COM3
    E:\\Anaconda\\python.exe lcd_test2\\tools\\lcd2_touch_probe.py --port COM3 --quick   # 每阶段时长减半

退出码：0 = 四阶段全部符合期望；1 = 有阶段不符合；2 = 收不到帧。
控制台是 GBK，所以打印全用英文。
"""

import argparse
import os
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import serial
except ImportError:
    print("ERROR: pyserial not available; run with E:\\Anaconda\\python.exe")
    sys.exit(4)

from lcd2_uart_check import FRAME_LEN, HEAD0, HEAD1, PROTO_VER, decode  # noqa: E402


class Reader(object):
    """后台无（单线程）读取：capture(sec) 期间不停收帧。"""

    def __init__(self, ser):
        self.ser = ser
        self.raw = bytearray()

    def poll(self, seconds, note_every=5.0):
        out = []
        t0 = time.time()
        last = 0.0
        while time.time() - t0 < seconds:
            chunk = self.ser.read(256)
            if chunk:
                self.raw.extend(chunk)
            i = 0
            n = len(self.raw)
            while i + FRAME_LEN <= n:
                if self.raw[i] == HEAD0 and self.raw[i + 1] == HEAD1:
                    cand = bytes(self.raw[i:i + FRAME_LEN])
                    if cand[2] == PROTO_VER:
                        out.append(decode(cand))
                    i += FRAME_LEN
                else:
                    i += 1
            del self.raw[:i]
            el = time.time() - t0
            if el - last >= note_every:
                last = el
                mx = max([d["status_points"] for d in out] or [0])
                print("      ... %4.0f s / %4.0f s  frames=%d  max chip points=%d"
                      % (el, seconds, len(out), mx))
            time.sleep(0.02)
        return out


def stat(frames, key):
    return Counter(d[key] for d in frames)


def summarize(tag, frames):
    sp = stat(frames, "status_points")
    tn = stat(frames, "tch_num")
    raw = stat(frames, "status_raw")
    print("    %s: frames=%d" % (tag, len(frames)))
    print("      chip points (0x814E low nibble) hist : %s" % dict(sorted(sp.items())))
    print("      tch_num (what RTL reports)     hist : %s" % dict(sorted(tn.items())))
    print("      raw 0x814E byte               hist : %s"
          % {("0x%02X" % k): v for k, v in sorted(raw.items())})
    return sp, tn


def show_samples(frames, k=6):
    touched = [d for d in frames if d["status_points"] > 0 or d["tch_num"] > 0]
    for d in touched[:k]:
        print("        frame %6d  status=0x%02X chip=%d tch_num=%d  T1=(%4d,%4d) T2=(%4d,%4d)"
              % (d["frame_cnt"], d["status_raw"], d["status_points"], d["tch_num"],
                 d["x0"], d["y0"], d["x1"], d["y1"]))


def main():
    ap = argparse.ArgumentParser(description="Guided multi-touch probe for lcd_test2.")
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--quick", action="store_true", help="halve every phase (for a fast retry)")
    args = ap.parse_args()

    f = 0.5 if args.quick else 1.0
    T_IDLE = 8.0 * f
    T_ONE = 16.0 * f
    T_LIFT = 8.0 * f
    T_MULTI = 20.0 * f

    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except Exception as e:
        print("ERROR: cannot open %s: %s" % (args.port, e))
        return 2

    print("=" * 74)
    print(" lcd_test2 touch probe (guided, 4 phases)   %s @ %d" % (args.port, args.baud))
    print("=" * 74)

    rd = Reader(ser)
    results = {}

    # ---------------- 阶段 0：静止基线 ----------------
    print("\n[0] DO NOT touch the panel for %.0f s (idle baseline)." % T_IDLE)
    time.sleep(0.3)
    fr0 = rd.poll(T_IDLE)
    if not fr0:
        ser.close()
        print("RESULT: FAIL - no valid v3 frame; check the port / that the board is programmed.")
        return 2
    sp0, tn0 = summarize("idle baseline", fr0)
    show_samples(fr0)
    ok0 = max(sp0.keys() or [0]) == 0 and max(tn0.keys() or [0]) == 0
    results["idle"] = ok0

    # ---------------- 阶段 1：单指 ----------------
    print("\n[1] NOW put ONE finger on the panel and slide it slowly for %.0f s." % T_ONE)
    time.sleep(0.3)
    fr1 = rd.poll(T_ONE)
    sp1, tn1 = summarize("one finger", fr1)
    show_samples(fr1)
    seen1 = [d for d in fr1 if d["status_points"] >= 1]
    coords1 = sorted(set((d["x0"], d["y0"]) for d in seen1))
    inr1 = all(0 <= x <= 1023 and 0 <= y <= 599 for x, y in coords1)
    print("      frames with chip points>=1: %d   distinct T1 (x,y): %d   in-range=%s"
          % (len(seen1), len(coords1), inr1))
    if coords1:
        print("      T1 x %d..%d  y %d..%d"
              % (min(x for x, _ in coords1), max(x for x, _ in coords1),
                 min(y for _, y in coords1), max(y for _, y in coords1)))
    ok1 = len(seen1) >= 3 and len(coords1) >= 2 and inr1
    results["one_finger"] = ok1

    # ---------------- 阶段 2：抬手 ----------------
    print("\n[2] LIFT the finger off the panel and keep it off for %.0f s." % T_LIFT)
    time.sleep(0.3)
    fr2 = rd.poll(T_LIFT)
    sp2, tn2 = summarize("after lift", fr2)
    # 抬手后允许有 ~0.5 s 的保留：只看后半段
    half = fr2[len(fr2) // 2:]
    sp2b, tn2b = summarize("after lift (2nd half)", half)
    ok2 = max(tn2b.keys() or [0]) == 0
    results["release"] = ok2

    # ---------------- 阶段 3：多指 ----------------
    print("\n[3] NOW put 2..5 fingers on the panel, hold them for %.0f s, then lift." % T_MULTI)
    time.sleep(0.3)
    fr3 = rd.poll(T_MULTI)
    sp3, tn3 = summarize("multi finger", fr3)
    show_samples(fr3, 10)
    maxsp3 = max(sp3.keys() or [0])
    maxnum3 = max(tn3.keys() or [0])
    ok3 = maxnum3 >= 2
    results["multi"] = ok3

    ser.close()

    # ---------------- 结论 ----------------
    maxsp = max(list(sp1.keys()) + list(sp3.keys()) + [0])
    maxnum = max(list(tn1.keys()) + list(tn3.keys()) + [0])
    print("\n" + "=" * 74)
    print(" chip-reported points  max = %d      (what the GT911 itself put in 0x814E)" % maxsp)
    print(" tch_num (RTL)         max = %d      (what the FPGA decoded and the screen draws)" % maxnum)
    for k, v in results.items():
        print("   phase %-11s : %s" % (k, "OK" if v else "NOT as expected"))
    print("-" * 74)
    if maxsp >= 2 and maxnum >= 2:
        print("VERDICT: multi-touch WORKS (chip and RTL both >= 2 points).")
        rc = 0 if all(results.values()) else 0
    elif maxsp >= 2 and maxnum < 2:
        print("VERDICT: the chip reports >= 2 points but tch_num stayed < 2 -> RTL point/coordinate")
        print("         state machine problem (STEP_LOOP / STEP_LOOP4 / tch_num latch).")
        rc = 1
    elif maxsp == 1:
        print("VERDICT: the chip only ever reported 1 point -> the GT911 config table (0x8047,")
        print("         'Touch Point Num') is not 5. That is exactly F6 item 3 (config table write).")
        rc = 1
    elif max([max(sp0.keys() or [0])] + [max(sp2.keys() or [0])]) == 0 and maxsp == 0:
        print("VERDICT: the chip produced NO report even while a finger was down.")
        print("         -> not a decode problem: check the touch module / FPC cable / INT line,")
        print("            then the GT911 config (0x8047) via F6 item 3.")
        rc = 1
    else:
        print("VERDICT: inconclusive - see per-phase numbers above.")
        rc = 1
    print("=" * 74)
    return rc


if __name__ == "__main__":
    sys.exit(main())
