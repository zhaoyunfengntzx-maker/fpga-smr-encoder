#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lcd_test2/tools/lcd2_board_check.py -- 上板"人机配合"验收助手（guided board check）

它把 docs/LCD_test_program_readme.md 第 9.1 节里"要看着屏动手"的那几步，变成一步步提示 +
自动采集遥测 + 自动判定。遥测能证明的（F1 轮播、F4 短按/长按、F6 轮询速率、F3 坐标是否跟手、
点数是否随手指数量变化、抬手后是否归零）它自己判定；只有遥测看不见的（准星在屏上画得对不对、
抬手保留 0.5 s 的观感）才需要你用眼睛确认，脚本会在最后单独列出来。

★ 本机要用 E:\\Anaconda\\python.exe 运行（内置 Python 没有 pyserial）：
    E:\\Anaconda\\python.exe lcd_test2\\tools\\lcd2_board_check.py --port COM3

退出码：0 = 所有自动判定项 PASS；2 = 收不到遥测；3 = 有自动判定项 FAIL。
结果同时写成 Markdown 表格到 _lcd_work/board_check_result.md，可直接贴进说明文档 9.1。
控制台是 GBK 代码页，所以所有打印都用英文。
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import serial
except ImportError:
    print("ERROR: pyserial not available to this Python interpreter")
    print("       Run with E:\\Anaconda\\python.exe (the only one with pyserial installed)")
    sys.exit(4)

from lcd2_uart_check import FRAME_LEN, HEAD0, HEAD1, PROTO_VER, decode  # noqa: E402

EXPECT_PANEL = 'ATK-7016 7"   1024x600'


def dot(msg):
    print("        ... %s" % msg)


class Reader(object):
    """串口 + 帧重组；所有等待都走 wait_for()，不会无限卡住。"""

    def __init__(self, port, baud):
        self.ser = serial.Serial(port, baud, timeout=0.2)
        self.raw = bytearray()
        self.frames = []          # 已解码帧（dict）
        self.bad = 0
        self.bytes = 0

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

    def pump(self):
        """读一次串口并把新攒够的帧解码追加到 self.frames。"""
        chunk = self.ser.read(256)
        if chunk:
            self.bytes += len(chunk)
            self.raw.extend(chunk)
        i = 0
        n = len(self.raw)
        while i + FRAME_LEN <= n:
            if self.raw[i] == HEAD0 and self.raw[i + 1] == HEAD1:
                cand = bytes(self.raw[i:i + FRAME_LEN])
                if cand[2] == PROTO_VER:
                    self.frames.append(decode(cand))
                else:
                    self.bad += 1
                i += FRAME_LEN
            else:
                i += 1
        del self.raw[:i]
        return len(self.frames)

    def wait_for(self, pred, timeout, desc, poll=0.05):
        """在 timeout 秒内一边收帧一边等 pred(frames) 变真；返回 (ok, 命中的帧)。"""
        t0 = time.time()
        last = 0
        while time.time() - t0 < timeout:
            self.pump()
            hit = pred(self.frames)
            if hit:
                return True, hit
            el = time.time() - t0
            if el - last >= 3.0:
                last = el
                print("        ... waiting (%.0fs left)" % max(0.0, timeout - el))
            time.sleep(poll)
        self.pump()
        return False, None


def main():
    ap = argparse.ArgumentParser(
        description="Guided on-board acceptance check for lcd_test2 "
                    "(drives the human through the 9.1 checklist and judges the telemetry).")
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--base-seconds", type=float, default=8.0, help="baseline window (default 8)")
    ap.add_argument("--step-timeout", type=float, default=45.0,
                    help="how long to wait for each human action (default 45 s)")
    args = ap.parse_args()

    try:
        rd = Reader(args.port, args.baud)
    except Exception as e:
        print("ERROR: cannot open %s @ %d: %s" % (args.port, args.baud, e))
        print("       (port busy? close vofa / serial assistant first)")
        return 2

    results = []      # (item, expected, measured, verdict)
    visual = []       # 遥测看不见、必须用眼睛看的项

    def rec(item, expect, measured, ok):
        verdict = "SKIP" if ok is None else ("PASS" if ok else "FAIL")
        results.append((item, expect, measured, verdict))
        print("  --> [%s] %s : %s" % (verdict, item, measured))
        return verdict == "PASS"

    print("=" * 72)
    print("lcd_test2 guided on-board check  (%s @ %d 8N1)" % (args.port, args.baud))
    print("Keep the board powered and the 40P cable plugged in.")
    print("=" * 72)

    # ---------- 0. 基线：F1 轮播 + 屏 ID + F6 轮询速率 ----------
    print("\n[0] baseline %.0f s -- do NOT touch the screen or the key" % args.base_seconds)
    t0 = time.time()
    while time.time() - t0 < args.base_seconds:
        rd.pump()
        time.sleep(0.05)
    base = list(rd.frames)
    n_base = len(base)
    rec("frame integrity", "no bad frame, >= %.0f frames" % (args.base_seconds - 2),
        "%d frames, %d bad" % (n_base, rd.bad), n_base >= args.base_seconds - 2 and rd.bad == 0)
    if n_base == 0:
        print("RESULT: FAIL - no valid v3 frame; check TX wiring / bitstream loaded")
        rd.close()
        return 2
    panels = set(d["panel"] for d in base)
    rec("panel id", EXPECT_PANEL, str(sorted(panels)),
        panels == {EXPECT_PANEL})
    reads = [d["reads_ps"] for d in base]
    errs = max(d["err_ps"] for d in base)
    rec("F6 poll rate (~10 ms -> about 100/s)", "60..140 reads/s, 0 errors",
        "reads/s %d..%d, max errors/s %d" % (min(reads), max(reads), errs),
        min(reads) >= 60 and max(reads) <= 140 and errs == 0)
    colors = []
    for d in base:
        if not colors or colors[-1] != d["color_idx"]:
            colors.append(d["color_idx"])
    rec("F1 color rotation", ">= 2 different color_idx in window",
        "color_idx sequence %s" % colors, len(set(colors)) >= 2)
    rec("idle touch state", "points == 0 when nobody touches",
        "points %s" % sorted(set(d["tch_num"] for d in base)),
        set(d["tch_num"] for d in base) == {0})
    mode0 = base[-1]["mode"]
    print("        (current mode = %d)" % mode0)

    # ---------- 1. F4 短按切模式 ----------
    print("\n[1] F4 SHORT press -- tap the key quickly (release at once), within %.0f s"
          % args.step_timeout)
    ok, hit = rd.wait_for(lambda fs: [d for d in fs[n_base:] if d["mode"] != mode0],
                          args.step_timeout, "mode change")
    m1 = hit[-1]["mode"] if hit else None
    rec("F4 short press toggles mode", "mode %d -> other" % mode0,
        "mode now %s" % m1, bool(hit))
    if ok:
        visual.append("F2 screen: 64px grid, 128px major grid, X/Y tick numbers, info panel at top-left")

    # ---------- 2. F4 再短按切回 ----------
    if ok:
        print("\n[2] F4 SHORT press again -- switch back to mode %d" % mode0)
        mark = len(rd.frames)
        ok2, hit2 = rd.wait_for(lambda fs: [d for d in fs[mark:] if d["mode"] == mode0],
                                args.step_timeout, "mode back")
        rec("F4 short press toggles back", "mode -> %d" % mode0,
            "mode now %s" % (hit2[-1]["mode"] if hit2 else None), bool(hit2))

    # ---------- 3. F3 单指滑动（跟手） ----------
    print("\n[3] F3 ONE finger -- short press the key once so the screen shows the GRID")
    print("    (mode 1), then put ONE finger on the panel and slide it slowly")
    print("    around for ~6 s, then lift.")
    if rd.frames and rd.frames[-1]["mode"] == mode0:
        mark = len(rd.frames)
        ok_m, hit_m = rd.wait_for(lambda fs: [d for d in fs[mark:] if d["mode"] != mode0],
                                  20.0, "mode 1")
        rec("F4/F2 switch to touch screen", "mode %d -> 1" % mode0,
            "mode now %s" % (hit_m[-1]["mode"] if hit_m else "?"), bool(ok_m))
    mark = len(rd.frames)
    ok3, hit3 = rd.wait_for(
        lambda fs: (len([d for d in fs[mark:] if d["tch_num"] >= 1]) >= 4),
        args.step_timeout, "one-finger touch")
    touch = [d for d in rd.frames[mark:] if d["tch_num"] >= 1]
    coords = sorted(set((d["x0"], d["y0"]) for d in touch))
    in_range = all(0 <= x <= 1023 and 0 <= y <= 599 for x, y in coords)
    rec("F3 touches are seen", ">= 4 frames with points >= 1",
        "%d frames, %d distinct (x,y)" % (len(touch), len(coords)), bool(ok3))
    if touch:
        print("        x range %d..%d   y range %d..%d   (panel is 1024x600)"
              % (min(x for x, _ in coords), max(x for x, _ in coords),
                 min(y for _, y in coords), max(y for _, y in coords)))
    rec("F3 coordinates follow the finger", ">= 3 distinct (x,y), inside 0..1023 / 0..599",
        "%d distinct, in-range=%s" % (len(coords), in_range), len(coords) >= 3 and in_range)
    if touch:
        visual.append("F3 screen: crosshair follows the finger; its number label (T1) moves with it")

    # ---------- 4. 抬手归零 ----------
    print("\n[4] lift the finger off the panel now")
    mark = len(rd.frames)
    ok4, hit4 = rd.wait_for(lambda fs: [d for d in fs[mark:] if d["tch_num"] == 0],
                            args.step_timeout, "points back to 0")
    rec("release -> points back to 0", "points == 0 after lifting",
        "points %s" % (hit4[-1]["tch_num"] if hit4 else "?"),
        bool(ok4) if touch else None)
    if touch:
        visual.append("F3 screen: crosshair stays about 0.5 s after lifting, then disappears")

    # ---------- 5. 多点 ----------
    print("\n[5] F3 MULTI touch -- put 2..5 fingers on the panel and hold them for ~6 s, then lift")
    mark = len(rd.frames)
    ok5, hit5 = rd.wait_for(
        lambda fs: ([d for d in fs[mark:] if d["tch_num"] >= 2] or None),
        args.step_timeout, "multi-point touch")
    maxpts = max([d["tch_num"] for d in rd.frames[mark:]] or [0])
    rec("F3 multi point", ">= 1 frame with >= 2 points", "max points seen %d" % maxpts, bool(ok5))
    if ok5:
        seen = maxpts
        if seen >= 2:
            visual.append("F3 screen: several coloured crosshairs at once (T1 white, T2 red, T3 green, T4 blue, T5 yellow)")
    mark = len(rd.frames)
    rd.wait_for(lambda fs: [d for d in fs[mark:] if d["tch_num"] == 0], 10.0, "lift")

    # ---------- 6. F4 长按暂停 / 恢复 ----------
    print("\n[6] F4 LONG press -- press and HOLD the key for more than 1 s, then release")
    mark = len(rd.frames)
    ok6, hit6 = rd.wait_for(lambda fs: [d for d in fs[mark:] if d["paused"] == 1],
                            args.step_timeout, "pause")
    rec("F4 long press pauses", "paused == 1", "paused %s" % (hit6[-1]["paused"] if hit6 else "?"), bool(ok6))
    if ok6:
        visual.append("F4 screen: the picture freezes while paused")
        print("\n[7] F4 LONG press again -- hold the key > 1 s to resume")
        mark = len(rd.frames)
        ok7, hit7 = rd.wait_for(lambda fs: [d for d in fs[mark:] if d["paused"] == 0],
                                args.step_timeout, "resume")
        rec("F4 long press resumes", "paused == 0", "paused %s" % (hit7[-1]["paused"] if hit7 else "?"), bool(ok7))

    # ---------- 汇总 ----------
    rd.close()
    nfail = sum(1 for r in results if r[3] == "FAIL")
    nskip = sum(1 for r in results if r[3] == "SKIP")
    print("\n" + "=" * 72)
    print("AUTOMATED VERDICT: %s  (%d items, %d FAIL, %d SKIP)"
          % ("PASS" if nfail == 0 else "FAIL", len(results), nfail, nskip))
    print("=" * 72)
    for item, expect, measured, verdict in results:
        print("  [%s] %-42s %s" % (verdict, item, measured))

    if visual:
        print("\nSTILL NEEDS YOUR EYES (telemetry cannot see the panel):")
        for v in visual:
            print("  - %s" % v)

    # 落一份 Markdown，可直接贴进说明文档 9.1
    out = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))), "_lcd_work", "board_check_result.md")
    try:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            fh.write("# lcd_test2 上板自动判定结果\n\n")
            fh.write("采集时间：%s　端口：%s\n\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), args.port))
            fh.write("| 项 | 判据 | 实测 | 结果 |\n|---|---|---|---|\n")
            for item, expect, measured, verdict in results:
                fh.write("| %s | %s | %s | **%s** |\n" % (item, expect, measured, verdict))
            if visual:
                fh.write("\n仍需人工目视确认：\n\n")
                for v in visual:
                    fh.write("- %s\n" % v)
        print("\nmarkdown written to %s" % out)
    except Exception as e:
        print("\n(note: could not write %s: %s)" % (out, e))

    return 0 if nfail == 0 else 3


if __name__ == "__main__":
    sys.exit(main())
