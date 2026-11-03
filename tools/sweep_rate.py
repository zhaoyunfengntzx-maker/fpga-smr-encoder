#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sweep_rate.py -- 幅度扫描时连续记录毛刺率。

每 --step 秒读一次 0x0505/0x0507（仅串口，不碰 JTAG），每 --scope-every 次采样再做一次
1 s 遥测（拿"校正后半径"作为幅度的相对轴，注意它是弧段量，只能看相对变化）。

用法：
  python tools/sweep_rate.py --port COM6 --seconds 300 --step 5 --csv _synth_work/sweep_rate.csv
"""
import argparse
import csv
import os
import re
import subprocess
import sys
import time

PY = r"E:\Anaconda\python.exe"
TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
VAL_RE = re.compile(r"=\s*0x([0-9A-Fa-f]{4})")
RAD_RE = re.compile(r"校正后半径\s*r\s*:\s*mean\s+([0-9.]+)")


def read_reg(port, addr):
    r = subprocess.run([PY, os.path.join(TOOLS, "uart_spi.py"), "--port", port, "read", addr],
                       capture_output=True, text=True, cwd=ROOT,
                       encoding="utf-8", errors="replace",
                       env=dict(os.environ, PYTHONIOENCODING="utf-8"))
    m = VAL_RE.search(r.stdout or "")
    return int(m.group(1), 16) if m else None


def radius(port):
    r = subprocess.run([PY, os.path.join(TOOLS, "uart_scope.py"), "--port", port,
                        "--baud", "2000000", "--seconds", "1"],
                       capture_output=True, text=True, cwd=ROOT,
                       encoding="utf-8", errors="replace",
                       env=dict(os.environ, PYTHONIOENCODING="utf-8"))
    m = RAD_RE.search(r.stdout or "")
    return float(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--seconds", type=float, default=300.0)
    ap.add_argument("--step", type=float, default=5.0)
    ap.add_argument("--scope-every", type=int, default=6)
    ap.add_argument("--csv", default="_synth_work/sweep_rate.csv")
    args = ap.parse_args()

    out = os.path.join(ROOT, args.csv)
    new = not os.path.exists(out)
    fh = open(out, "a", newline="", encoding="utf-8")
    wr = csv.writer(fh)
    if new:
        wr.writerow(["ts", "elapsed_s", "gl1024", "gl2048", "d1024", "rate_per_s", "radius_raw", "note"])

    t0 = time.time()
    prev = None
    k = 0
    try:
        while time.time() - t0 < args.seconds:
            k += 1
            ts = time.strftime("%H:%M:%S")
            now = time.time()
            v = read_reg(args.port, "0x0505")
            w = read_reg(args.port, "0x0507")
            rad = radius(args.port) if (k % args.scope_every == 1) else ""
            dt = now - prev[0] if prev else None
            d = (v - prev[1]) & 0xFFFF if (prev and v is not None) else None
            rate = (d / dt) if (d is not None and dt) else None
            row = [ts, "%.1f" % (now - t0), v, w, d,
                   ("%.3f" % rate) if rate is not None else "", rad,
                   "" if prev else "start"]
            wr.writerow(row)
            fh.flush()
            print(" ".join(str(x) for x in row), flush=True)
            if v is not None:
                prev = (now, v)
            time.sleep(max(0.0, args.step - (time.time() - now)))
    finally:
        fh.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
