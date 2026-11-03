#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/amp_point.py —— 采一个"幅度点"（用于幅度阶梯实验，A 用实测口径，不看 AFG 显示值）。

一个点 = 夹住一个计数器窗口：
    uart_scope --seconds 1   -> A0（遥测"校正后半径 r" ÷16 = 原始码口径）、圆度偏差
    uart_spi  write 0x0405 0x0001  -> 清 OTR 粘滞
    diag_counters --seconds N      -> 0x0505/07/09/0B/0D/0540/053A 的 Δ
    uart_scope --seconds 1   -> A1
    uart_spi  read  0x0405         -> 窗口内是否发生过 OTR
结果追加到 CSV（默认 `_synth_work/ladder.csv`），并回显一行。

用法（用户每调一次 AFG 幅度，就跑一次；频率与接线不动）：
    $env:PYTHONIOENCODING='utf-8'
    E:\\Anaconda\\python.exe tools\\amp_point.py --label 8.5Vpp --seconds 40
    E:\\Anaconda\\python.exe tools\\amp_point.py --label 9.0Vpp --seconds 40
    ...
再汇总：`E:\\Anaconda\\python.exe tools\\amp_point.py --report`（按 A 排序打印 + 相关）

★ 纪律：测率期间用户不要碰 AFG/板/接线（§1.56 ⑤）。
"""

import argparse
import csv
import os
import re
import subprocess
import sys
import time

RADIUS_RE = re.compile(r"校正后半径\s*r\s*:\s*mean\s+([0-9.]+)")
ROUND_RE = re.compile(r"圆度偏差\(RMS\)\s*:\s*([0-9.]+)")
CNT_RE = re.compile(r"(0x05[0-9A-Fa-f]{2}).*?([0-9]+)\s+([0-9]+)\s+(-?[0-9]+)\s*$", re.M)
STAT_RE = re.compile(r"0x053A\s+\S+\s+([0-9]+)\s+([0-9]+)")
READ_RE = re.compile(r"0x0405\s+STAT_LATCH\(W1C\)\s*=\s*0x([0-9A-Fa-f]+)")
FIELDNAMES = ["ts", "label", "secs", "A0", "A1", "A_mean", "round_pct",
              "r1024", "r2048", "r4096", "r8192", "rhold",
              "d1024", "d2048", "d4096", "d8192", "dhold", "dcyc", "fin_hz",
              "stat053A", "otr0405", "csv_out"]


def run(args):
    """跑一个子进程，返回 (rc, stdout+stderr 文本)。"""
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    p = subprocess.run(args, capture_output=True, env=env)
    txt = (p.stdout or b"").decode("utf-8", "replace") + (p.stderr or b"").decode("utf-8", "replace")
    return p.returncode, txt


def fin_from_cyc(delta, secs):
    if not delta or delta <= 0:
        return None
    best = None
    for n in range(0, int(secs * 30000 / 65536) + 3):
        f = (n * 65536 + delta) / secs
        if best is None or abs(f - 20000.0) < abs(best - 20000.0):
            best = f
    return best


def one_point(py, port, baud, secs, label, csv_out=None):
    row = {k: "" for k in FIELDNAMES}
    row["ts"] = time.strftime("%m-%d %H:%M:%S")
    row["label"] = label
    row["secs"] = secs
    row["csv_out"] = csv_out or ""

    # csv_out：把 A0 那次遥测的逐帧 s/c 存下来，事后可用 tools/arc_fit.py 拟合
    # **残余圆心 O**（256 格点共振假设里 O 与 A 同等重要，而遥测报告只给半径）。
    scope_cmd = [py, "tools/uart_scope.py", "--port", port, "--baud", str(baud), "--seconds", "1"]
    if csv_out:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(csv_out)), exist_ok=True)
        except OSError:
            pass
        scope_cmd += ["--csv", csv_out]
    rc, txt = run(scope_cmd)
    m = RADIUS_RE.search(txt)
    row["A0"] = float(m.group(1)) / 16.0 if m else ""
    m = ROUND_RE.search(txt)
    row["round_pct"] = float(m.group(1)) if m else ""

    run([py, "tools/uart_spi.py", "--port", port, "write", "0x0405", "0x0001"])

    rc, txt = run([py, "tools/diag_counters.py", "--port", port, "--seconds", str(secs)])
    d = {}
    for mm in CNT_RE.finditer(txt):
        d[mm.group(1).lower()] = int(mm.group(4))
    m = STAT_RE.search(txt)
    row["stat053A"] = int(m.group(2)) if m else ""
    for name, key in (("d1024", "0x0505"), ("d2048", "0x0507"), ("d4096", "0x0509"),
                      ("d8192", "0x050b"), ("dhold", "0x050d"), ("dcyc", "0x0540")):
        row[name] = d.get(key, "")
    for name, key in (("r1024", "d1024"), ("r2048", "d2048"), ("r4096", "d4096"),
                      ("r8192", "d8192"), ("rhold", "dhold")):
        v = row[key]
        row[name] = (v / float(secs)) if v != "" else ""
    row["fin_hz"] = fin_from_cyc(row["dcyc"], secs) or ""

    rc, txt = run([py, "tools/uart_scope.py", "--port", port, "--baud", str(baud), "--seconds", "1"])
    m = RADIUS_RE.search(txt)
    row["A1"] = float(m.group(1)) / 16.0 if m else ""
    if row["A0"] != "" and row["A1"] != "":
        row["A_mean"] = (row["A0"] + row["A1"]) / 2.0

    rc, txt = run([py, "tools/uart_spi.py", "--port", port, "read", "0x0405"])
    m = READ_RE.search(txt)
    row["otr0405"] = ("0x%02X" % int(m.group(1), 16)) if m else ""
    return row


def report(path):
    if not os.path.exists(path):
        print("没有 %s" % path)
        return 1
    with open(path, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f)]
    if not rows:
        print("CSV 为空")
        return 0

    def fnum(r, k):
        try:
            return float(r[k])
        except (KeyError, ValueError):
            return None

    pts = [(fnum(r, "A_mean"), fnum(r, "r1024"), r) for r in rows]
    pts = [p for p in pts if p[0] is not None and p[1] is not None]
    print("== 幅度阶梯（按 A 升序；A = 遥测半径/16 原始码口径）==")
    print("标签        A      gl1024/s  gl2048/s  gl4096/s  圆度%   f_in(kHz)  otr")
    for a, rate, r in sorted(pts, key=lambda p: p[0]):
        print("{:<10} {:7.1f}  {:8.3f}  {:8.3f}  {:8.3f}  {:>5}  {:>8}  {}".format(
            r["label"], a, rate, fnum(r, "r2048") or 0.0, fnum(r, "r4096") or 0.0,
            r["round_pct"] or "", (fnum(r, "fin_hz") or 0) / 1000.0 or "", r["otr0405"]))
    if len(pts) >= 3:
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        n = len(xs)
        mx, my = sum(xs) / n, sum(ys) / n
        num = sum((xs[i] - mx) * (ys[i] - my) for i in range(n))
        dx = sum((xs[i] - mx) ** 2 for i in range(n)) ** 0.5
        dy = sum((ys[i] - my) ** 2 for i in range(n)) ** 0.5
        print("\n点数={}  A 跨度={:.1f}..{:.1f}  率跨度={:.3f}..{:.3f}/s  Pearson(A,率)={}".format(
            n, min(xs), max(xs), min(ys), max(ys), "%.3f" % (num / (dx * dy)) if dx and dy else "n/a"))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--seconds", type=int, default=40, help="计数器窗口秒数")
    ap.add_argument("--label", default="", help="本点标签，如 8.5Vpp")
    ap.add_argument("--csv", default="_synth_work/ladder.csv")
    ap.add_argument("--csv-dir", default="_synth_work/ab_pts",
                    help="每个点的逐帧遥测 CSV 存这里（事后 arc_fit 拟合残余圆心 O）")
    ap.add_argument("--report", action="store_true", help="只汇总已有 CSV")
    args = ap.parse_args()

    if args.report:
        return report(args.csv)

    py = sys.executable
    tag = re.sub(r"[^0-9A-Za-z_.-]", "_", args.label) or time.strftime("%H%M%S")
    csv_out = os.path.join(args.csv_dir, "%s_%s.csv" % (tag, time.strftime("%m%d_%H%M%S")))
    row = one_point(py, args.port, args.baud, args.seconds, args.label, csv_out=csv_out)
    new = not os.path.exists(args.csv)
    with open(args.csv, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDNAMES)
        if new:
            w.writeheader()
        w.writerow(row)
    print(" ".join("%s=%s" % (k, row[k]) for k in ("ts", "label", "A_mean", "r1024", "r2048",
                                                   "r4096", "dcyc", "fin_hz", "stat053A", "otr0405")))
    print("已追加到 %s" % args.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
