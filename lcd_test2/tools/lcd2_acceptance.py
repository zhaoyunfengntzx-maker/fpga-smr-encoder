#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""lcd2_acceptance.py -- free-pace on-board acceptance for lcd_test2.

Why this exists next to lcd2_board_check.py: that one walks you through steps
with a hard time window per step, so a key press that lands a few seconds late
is recorded as a FAIL even though the hardware is fine.  This tool only
RECORDS for N seconds and afterwards reports which acceptance signatures were
seen.  You do the whole sequence at your own pace -- nothing depends on a
prompt-to-press handshake.

Usage:
  E:\\Anaconda\\python.exe lcd_test2\\tools\\lcd2_acceptance.py --port COM3 --seconds 180

While it records, do each of these ONCE (any order, any pace):
  1) short press the key   -> grid (F2);  short press again -> solid (F1)
  2) one finger on the panel, slide it slowly for ~6 s
  3) lift the finger off
  4) 2..5 fingers held on the panel for a few seconds
  5) long press the key (>1 s) -> freeze;  long press again -> resume

Output: a PASS/FAIL table on stdout plus _lcd_work/board_acceptance_result.md
Exit code: 0 = every automated item passed, 3 = at least one FAIL,
           2 = no valid telemetry frame at all.
"""

import argparse
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import lcd2_uart_check as U
except ImportError as exc:                                   # pragma: no cover
    sys.stderr.write("ERROR: cannot import lcd2_uart_check (%s)\n" % exc)
    raise

try:
    import serial
except ImportError:                                          # pragma: no cover
    serial = None

EXPECT_PANEL = 'ATK-7016 7"   1024x600'
ROOT = os.path.dirname(os.path.dirname(HERE))


def read_raw(port, baud, seconds):
    """Collect raw bytes for `seconds`; returns (raw, bad_frames)."""
    if serial is None:
        raise RuntimeError("pyserial not available; run with E:\\Anaconda\\python.exe")
    ser = serial.Serial(port, baud, timeout=0.2)
    raw = bytearray()
    t0 = time.time()
    while time.time() - t0 < seconds:
        chunk = ser.read(256)
        if chunk:
            raw.extend(chunk)
    ser.close()
    return raw


def split_frames(raw):
    """Resync on A5 4C and cut 26-byte v3 frames.  Returns (frames, bad)."""
    out, bad = [], 0
    i, n = 0, len(raw)
    while i + U.FRAME_LEN <= n:
        if raw[i] == U.HEAD0 and raw[i + 1] == U.HEAD1:
            cand = bytes(raw[i:i + U.FRAME_LEN])
            if cand[2] == U.PROTO_VER:
                out.append(cand)
            else:
                bad += 1
            i += U.FRAME_LEN
        else:
            i += 1
    return out, bad


def mode_transitions(decoded):
    """List of (index, mode) whenever the screen mode changes."""
    seq = []
    for i, d in enumerate(decoded):
        if not seq or seq[-1][1] != d["mode"]:
            seq.append((i, d["mode"]))
    return seq


def paused_transitions(decoded):
    seq = []
    for i, d in enumerate(decoded):
        if not seq or seq[-1][1] != d["paused"]:
            seq.append((i, d["paused"]))
    return seq


def released_after_touch(decoded, gap=3):
    """True if some touch episode is followed by >= gap consecutive idle frames."""
    for i, d in enumerate(decoded):
        if d["tch_num"] >= 1:
            run = 0
            for e in decoded[i + 1:]:
                if e["tch_num"] == 0:
                    run += 1
                    if run >= gap:
                        return True
                else:
                    break
    return False


def stall_free(decoded, min_reads=60, run_len=3):
    """True if there is no run of `run_len` consecutive frames with reads_ps==0.

    Covers the old failure mode: after a touch the poll loop stopped entirely,
    so reads_ps stayed 0 (and err_ps stayed 0) for ever.
    """
    run = 0
    for d in decoded:
        if d["reads_ps"] == 0:
            run += 1
            if run >= run_len:
                return False
        else:
            run = 0
    return True


def main():
    ap = argparse.ArgumentParser(description="Free-pace on-board acceptance for lcd_test2.")
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=180.0,
                    help="record window in seconds (default 180)")
    ap.add_argument("--expect-panel", default=EXPECT_PANEL)
    args = ap.parse_args()

    print("=" * 74)
    print(" lcd_test2 free-pace acceptance   %s @ %d   %.0f s"
          % (args.port, args.baud, args.seconds))
    print("=" * 74)
    print(" Do each of these ONCE while it records (any order / any pace):")
    print("   1) short press the key -> grid (F2);  short press again -> solid (F1)")
    print("   2) ONE finger on the panel, slide slowly ~6 s")
    print("   3) lift the finger off")
    print("   4) 2..5 fingers held on the panel for a few seconds")
    print("   5) LONG press the key (>1 s) to freeze; long press again to resume")
    print("-" * 74)
    print(" recording ... (no prompt will come; just do them)")

    t0 = time.time()
    try:
        raw = read_raw(args.port, args.baud, args.seconds)
    except Exception as exc:
        print("ERROR: cannot read %s: %s" % (args.port, exc))
        print("       (port busy? close vofa / serial assistant / host GUI first)")
        return 2
    frames, bad = split_frames(raw)
    print(" bytes=%d  frames=%d  bad_frames=%d  elapsed=%.1f s"
          % (len(raw), len(frames), bad, time.time() - t0))
    if not frames:
        print("RESULT: FAIL - no valid v3 frame (check TX wiring / baud / bitstream)")
        return 2

    decoded = [U.decode(f) for f in frames]
    n = len(decoded)
    reads = [d["reads_ps"] for d in decoded]
    errs = [d["err_ps"] for d in decoded]
    points = [d["tch_num"] for d in decoded]
    colors = [d["color_idx"] for d in decoded]
    coords = sorted(set((d["x0"], d["y0"]) for d in decoded if d["tch_num"] >= 1))
    in_range = all(0 <= x <= 1023 and 0 <= y <= 599 for x, y in coords)
    n_single = sum(1 for p in points if p == 1)
    n_touch = sum(1 for p in points if p >= 1)
    n_idle = sum(1 for p in points if p == 0)
    maxpts = max(points)
    mseq = mode_transitions(decoded)
    pseq = paused_transitions(decoded)

    results = []

    def rec(item, expect, measured, ok):
        results.append((item, expect, measured, "PASS" if ok else "FAIL"))
        print("  --> [%s] %-38s %s" % ("PASS" if ok else "FAIL", item, measured))

    print("-" * 74)
    print(" mode timeline    : %s" % [(i, m) for i, m in mseq][:12])
    print(" paused timeline  : %s" % [(i, p) for i, p in pseq][:12])
    print(" color_idx seq    : %s" % colors[:24])
    print(" touch frames     : %d (single=%d, multi=%d, idle=%d)  max points=%d"
          % (n_touch, n_single, n_touch - n_single, n_idle, maxpts))
    print(" distinct (x0,y0) : %d  in-range=%s" % (len(coords), in_range))
    print(" tstate histogram : %s" % _hist([d["tstate"] for d in decoded]))
    print(" m_state histogram: %s" % _hist([d["m_state"] for d in decoded]))
    print("-" * 74)

    rec("frame integrity", "bad_frames == 0 and >= %.0f frames" % (args.seconds - 4),
        "%d frames, %d bad" % (n, bad), bad == 0 and n >= args.seconds - 4)
    panels = set(d["panel"] for d in decoded)
    rec("panel id", args.expect_panel, str(sorted(panels)), panels == {args.expect_panel})
    med = int(statistics.median(reads)) if reads else 0
    rec("F6 poll rate (median)", ">= 60 reads/s and 0 errors",
        "median %d, min %d, max %d, max err %d" % (med, min(reads), max(reads), max(errs)),
        med >= 60 and max(errs) == 0)
    rec("F1 color rotation", ">= 4 distinct color_idx",
        "%d distinct %s" % (len(set(colors)), sorted(set(colors))), len(set(colors)) >= 4)
    n_modes = len(mseq) - 1
    rec("F4 short press toggles mode", ">= 2 mode changes in window",
        "%d changes: %s" % (n_modes, [m for _, m in mseq][:6]), n_modes >= 2)
    rec("F3 single finger seen", ">= 4 idle-to-touch frames with exactly 1 point",
        "%d frames with 1 point" % n_single, n_single >= 4)
    rec("F3 coordinates follow finger", ">= 3 distinct (x,y), all inside 1024x600",
        "%d distinct, in-range=%s" % (len(coords), in_range), len(coords) >= 3 and in_range)
    rec("F3 multi point", ">= 1 frame with >= 2 points",
        "max points seen %d" % maxpts, maxpts >= 2)
    rec("F3 release returns to 0", "touch episode followed by >= 3 idle frames",
        "release pattern found = %s" % released_after_touch(decoded),
        released_after_touch(decoded))
    npz = len(pseq) - 1
    rec("F4 long press freeze/resume", ">= 1 paused=1 and >= 1 paused=0 transition",
        "%d transitions, timeline %s" % (npz, [p for _, p in pseq][:6]),
        any(p == 1 for _, p in pseq) and any(p == 0 for _, p in pseq))
    rec("no touch stall", "no 3 consecutive frames with reads_ps == 0",
        "min reads/s %d, tail reads/s %d" % (min(reads), reads[-1]),
        stall_free(decoded))

    nfail = sum(1 for r in results if r[3] == "FAIL")
    print("=" * 74)
    print(" ACCEPTANCE VERDICT: %s   (%d items, %d FAIL)"
          % ("PASS" if nfail == 0 else "FAIL", len(results), nfail))
    print("=" * 74)

    out = os.path.join(ROOT, "_lcd_work", "board_acceptance_result.md")
    try:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            fh.write("# lcd_test2 自由节奏上板验收结果\n\n")
            fh.write("采集时间：%s　端口：%s　窗口：%.0f s\n\n"
                     % (time.strftime("%Y-%m-%d %H:%M:%S"), args.port, args.seconds))
            fh.write("| 项 | 判据 | 实测 | 结果 |\n|---|---|---|---|\n")
            for item, expect, measured, verdict in results:
                fh.write("| %s | %s | %s | **%s** |\n" % (item, expect, measured, verdict))
            fh.write("\n模式时间线（帧序号, mode）：`%s`\n\n" % mseq[:12])
            fh.write("暂停时间线（帧序号, paused）：`%s`\n\n" % pseq[:12])
            fh.write("tstate 直方图：`%s`\n\n" % _hist([d["tstate"] for d in decoded]))
            fh.write("m_state 直方图：`%s`\n" % _hist([d["m_state"] for d in decoded]))
        print(" markdown written to %s" % out)
    except Exception as exc:                                # pragma: no cover
        print(" (note: could not write %s: %s)" % (out, exc))

    return 0 if nfail == 0 else 3


def _hist(values):
    h = {}
    for v in values:
        h[v] = h.get(v, 0) + 1
    return dict(sorted(h.items()))


if __name__ == "__main__":
    sys.exit(main())
