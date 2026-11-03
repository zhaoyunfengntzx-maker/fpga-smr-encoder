#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/avr_scan_report.py —— 解析 `_synth_work/avr_scan.txt`（A–率散点日志）并给出判读。

日志由后台扫描产生，每个 iter = 1 个 30 s 计数器窗口，窗口前后各夹一次 1 s 遥测：
    [HH:MM:SS iter N]
      校正后半径 r      : mean <A0>                      <- 窗口前（÷16 = 原始码口径）
    0x0505 gl_1024...  <old> <new> <delta>               <- 30 s 窗口内的 Δ
    ...
      校正后半径 r      : mean <A1>                      <- 窗口后
      0x0405 STAT_LATCH(W1C) = 0x....  ...               <- 窗口内是否发生过 OTR

输出：
  1) 逐窗表：iter / 时刻 / A0 / A1 / A 均值（原始码）/ gl_1024 率 / gl_2048 率 / gl_hold 率 /
             gl_4096 Δ / gl_8192 Δ / cyc Δ / f_in 估计 / OTR
  2) A 排序后的表（看"幅度是否单调决定率"）
  3) A 与率的 Spearman / Pearson 相关，以及"率=0 的窗"的 A 区间

用法：
  $env:PYTHONIOENCODING='utf-8'
  E:\\Anaconda\\python.exe tools\\avr_scan_report.py                     # 默认 _synth_work/avr_scan.txt
  E:\\Anaconda\\python.exe tools\\avr_scan_report.py --file <path> --secs 30
"""

import argparse
import re
import sys

ITER_RE = re.compile(r"\[(\d\d:\d\d:\d\d)\s+iter\s+(\d+)\]")
RADIUS_RE = re.compile(r"校正后半径\s*r\s*:\s*mean\s+([0-9.]+)")
ROUND_RE = re.compile(r"圆度偏差\(RMS\)\s*:\s*([0-9.]+)")
CNT_RE = re.compile(r"(0x05[0-9A-Fa-f]{2})\s+\S+\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9]+)")
STAT_RE = re.compile(r"0x053A\s+\S+\s+([0-9]+)\s+([0-9]+)")
OTR_RE = re.compile(r"0x0405\s+STAT_LATCH\(W1C\)\s*=\s*0x([0-9A-Fa-f]+)")
FCLK = 100e6


def parse(path):
    iters = []
    cur = None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = ITER_RE.search(line)
            if m:
                cur = {"t": m.group(1), "i": int(m.group(2)), "rad": [], "rnd": [],
                       "cnt": {}, "stat": None, "otr": None}
                iters.append(cur)
                continue
            if cur is None:
                continue
            m = CNT_RE.search(line)
            if m:
                cur["cnt"][m.group(1).lower()] = int(m.group(4))
                continue
            m = RADIUS_RE.search(line)
            if m:
                cur["rad"].append(float(m.group(1)))
                continue
            m = ROUND_RE.search(line)
            if m:
                cur["rnd"].append(float(m.group(1)))
                continue
            m = STAT_RE.search(line)
            if m:
                cur["stat"] = int(m.group(2))
                continue
            m = OTR_RE.search(line)
            if m:
                cur["otr"] = int(m.group(1), 16)
    return iters


def fin_from_cyc(delta, secs):
    """cyc_pulse_cnt 是 16 位、每电周期 +1 ⇒ 长窗要靠回绕数才能还原 f_in。
    取使 f 最接近 20 kHz 的那个回绕数 n（对 ~20 kHz 输入，n 唯一）。"""
    if delta is None or delta <= 0:
        return None
    cands = []
    for n in range(0, int(secs * 30000 / 65536) + 3):
        cands.append((n * 65536 + delta) / secs)
    # 选最接近 20 kHz 的候选（若都在 12–30 kHz 之外，仍返回最近的）
    return min(cands, key=lambda f: abs(f - 20000.0))


def spearman(xs, ys):
    def rank(v):
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1
            for k in range(i, j + 1):
                r[order[k]] = avg
            i = j + 1
        return r
    rx, ry = rank(xs), rank(ys)
    n = len(xs)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((rx[i] - mx) * (ry[i] - my) for i in range(n))
    dx = sum((rx[i] - mx) ** 2 for i in range(n)) ** 0.5
    dy = sum((ry[i] - my) ** 2 for i in range(n)) ** 0.5
    return num / (dx * dy) if dx and dy else float("nan")


def pearson(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    num = sum((xs[i] - mx) * (ys[i] - my) for i in range(n))
    dx = sum((xs[i] - mx) ** 2 for i in range(n)) ** 0.5
    dy = sum((ys[i] - my) ** 2 for i in range(n)) ** 0.5
    return num / (dx * dy) if dx and dy else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="_synth_work/avr_scan.txt")
    ap.add_argument("--secs", type=float, default=30.0, help="每个计数器窗口的秒数")
    args = ap.parse_args()

    iters = parse(args.file)
    rows = []
    for it in iters:
        rad = it["rad"]
        if len(rad) < 1:
            continue
        a0 = rad[0] / 16.0
        a1 = rad[1] / 16.0 if len(rad) > 1 else a0
        c = it["cnt"]
        d1024 = c.get("0x0505")
        rate = (d1024 / args.secs) if d1024 is not None else float("nan")
        rows.append({
            "t": it["t"], "i": it["i"], "a0": a0, "a1": a1, "a": (a0 + a1) / 2.0,
            "r1024": rate,
            "r2048": (c["0x0507"] / args.secs) if "0x0507" in c else float("nan"),
            "rhold": (c["0x050d"] / args.secs) if "0x050d" in c else float("nan"),
            "d4096": c.get("0x0509"), "d8192": c.get("0x050b"),
            "dcyc": c.get("0x0540"),
            "fin": fin_from_cyc(c.get("0x0540"), args.secs),
            "round": it["rnd"][0] if it["rnd"] else float("nan"),
            "stat": it["stat"], "otr": it["otr"],
        })

    if not rows:
        print("没有可用窗口（文件还没写出来？）")
        return 1

    print("== 逐窗（A 为原始码口径 = 遥测半径/16；率 = Δ/%.0f s）==" % args.secs)
    print("iter  时刻      A0     A1     A均值   圆度%   gl1024/s  gl2048/s  glhold/s  d4096 d8192  cycΔ/s  f_in(kHz)  0x053A otr")
    for r in rows:
        print("{:>3}  {}  {:6.1f} {:6.1f} {:7.1f}  {:5.2f}   {:8.3f}  {:8.3f}  {:8.3f}  {:>5} {:>5}  {:>6.0f}   {:8.2f}   {:>3}   0x{:02X}".format(
            r["i"], r["t"], r["a0"], r["a1"], r["a"],
            r["round"], r["r1024"], r["r2048"], r["rhold"],
            r["d4096"] if r["d4096"] is not None else -1,
            r["d8192"] if r["d8192"] is not None else -1,
            r["dcyc"] if r["dcyc"] is not None else -1,
            (r["fin"] / 1000.0) if r["fin"] else float("nan"),            r["stat"] if r["stat"] is not None else 0,
            r["otr"] if r["otr"] is not None else 0))

    # ---- A 排序表 ----
    print("\n== 按 A 升序（看幅度是否单调决定率）==")
    for r in sorted(rows, key=lambda x: x["a"]):
        print("A={:7.1f}  率={:7.3f}/s  gl2048/s={:7.3f}  圆度={:5.2f}%  iter={:>3}  {}".format(
            r["a"], r["r1024"], r["r2048"], r["round"], r["i"], r["t"]))

    # ---- 统计 ----
    xs = [r["a"] for r in rows]
    ys = [r["r1024"] for r in rows]
    nz = [r for r in rows if r["r1024"] > 0]
    print("\n== 统计 ==")
    print("窗数={}  非零率窗数={}  率范围={:.3f}..{:.3f}/s".format(
        len(rows), len(nz), min(ys), max(ys)))
    if len(rows) >= 3:
        print("Pearson(A,率)={:.3f}   Spearman(A,率)={:.3f}".format(pearson(xs, ys), spearman(xs, ys)))
    print("A 范围 = {:.1f} .. {:.1f}（跨度 {:.1f} LSB = {:.2f}%）".format(
        min(xs), max(xs), max(xs) - min(xs), 100.0 * (max(xs) - min(xs)) / (sum(xs) / len(xs))))
    if len(nz) and len(nz) < len(rows):
        zs = [r["a"] for r in rows if r["r1024"] == 0]
        print("零率窗的 A 区间: {} .. {}".format(min(zs), max(zs)))
    n_otr = sum(1 for r in rows if r["otr"])
    print("发生 OTR 的窗数 = {} / {}".format(n_otr, len(rows)))
    print("d4096/d8192 非零窗数 = {} / {}".format(
        sum(1 for r in rows if (r["d4096"] or 0) or (r["d8192"] or 0)), len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
