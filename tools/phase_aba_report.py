#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""phase_aba_report.py -- 解析 _synth_work/phase_aba.txt（v9 -> v10 -> v9 相位实验），
给出每个相位的**毛刺率**、f_in（16 位回绕解算）以及"v10 相对 v9"的泊松检验。

用法：python tools/phase_aba_report.py [--log _synth_work/phase_aba.txt]
"""
import argparse
import re
import sys

TAG_RE = re.compile(r"\[(A1-v9|B-v10|A2-v9)\]\s+counter window\s+(\d+)\s+s")
TAG_RE2 = re.compile(r"=====\s+(A1_v9|B_v10|A2_v9)\s+begin(?:\s+bit=(\S+)\s+expect\s+(\S+))?")
SECS_RE = re.compile(r"采样间隔实测\s+([0-9.]+)\s+s")
ROW_RE = re.compile(r"^(0x05[0-9A-Fa-f]{2})\s+\S+\s+([0-9]+)\s+([0-9]+)")
BUILD_RE = re.compile(r"RTL_BUILD_ID\(0x05F2\)\s*=\s*(\d+)")
BUILD_RE2 = re.compile(r"0x05F2\s*->.*=\s*0x([0-9A-Fa-f]{4})")
TAGMAP = {"A1_v9": "A1-v9", "B_v10": "B-v10", "A2_v9": "A2-v9"}
WRAP = 65536


def read_lines(path):
    """容忍 UTF-16/UTF-8 混写：带 NUL 的行按 UTF-16LE 解，否则按 UTF-8。"""
    with open(path, "rb") as fh:
        raw = fh.read()
    out = []
    for ln in raw.split(b"\n"):
        if b"\x00" in ln:
            try:
                s = ln.decode("utf-16-le", errors="ignore").replace("\x00", "")
            except Exception:
                s = ln.decode("utf-8", errors="ignore")
        else:
            s = ln.decode("utf-8", errors="ignore")
        out.append(s)
    return out


def fin_from_cyc(delta, secs, target=20000.0):
    best, best_err = None, None
    for n in range(0, 4096):
        f = (n * WRAP + delta) / secs
        err = abs(f - target)
        if best_err is None or err < best_err:
            best, best_err = f, err
    return best


def parse(path):
    blocks = []
    cur = None
    for ln in read_lines(path):
        m = TAG_RE.search(ln)
        if not m:
            m2 = TAG_RE2.search(ln)
            if m2:
                if cur:
                    blocks.append(cur)
                cur = {"tag": TAGMAP[m2.group(1)], "req_secs": 0, "rows": {}, "secs": None,
                       "build": None, "expect": m2.group(3)}
                continue
        if m:
            if cur:
                blocks.append(cur)
            cur = {"tag": m.group(1), "req_secs": int(m.group(2)), "rows": {}, "secs": None,
                   "build": None, "expect": None}
            continue
        if cur is None:
            continue
        m = SECS_RE.search(ln)
        if m:
            cur["secs"] = float(m.group(1))
            continue
        m = ROW_RE.match(ln.strip())
        if m:
            cur["rows"].setdefault(m.group(1).upper(), (int(m.group(2)), int(m.group(3))))
            continue
        m = BUILD_RE.search(ln)
        if not m:
            m = BUILD_RE2.search(ln)
        if m:
            cur["build"] = int(m.group(1), 16) if len(m.group(1)) == 4 else int(m.group(1))
    if cur:
        blocks.append(cur)
    return blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="_synth_work/phase_aba.txt")
    args = ap.parse_args()
    blocks = parse(args.log)
    if not blocks:
        print("no counter windows found in %s" % args.log)
        return 1

    print("=" * 100)
    print(" v9 -> v10 -> v9 相位实验（D 分支坏码率）")
    print("=" * 100)
    hdr = ("phase", "build", "secs", "d_1024", "rate/s", "d_2048", "d_4096", "d_8192", "d_hold", "d_cyc", "f_in/Hz")
    print("%-8s %5s %7s %8s %9s %8s %8s %8s %8s %9s %9s" % hdr)
    summ = {}
    for b in blocks:
        r = b["rows"]
        secs = b["secs"] or float(b["req_secs"]) or 600.0
        def d(a):
            a = a.upper()          # rows 的键统一是大写（见 parse 里的 .upper()）
            if a not in r:
                return 0
            return (r[a][1] - r[a][0]) & 0xFFFF
        d1024, d2048, d4096, d8192, dhold = (d("0x0505"), d("0x0507"), d("0x0509"),
                                             d("0x050B"), d("0x050D"))
        dcyc = d("0x0540")
        f = fin_from_cyc(dcyc, secs)
        print("%-8s %5s %7.1f %8d %9.4f %8d %8d %8d %8d %9d %9.1f"
              % (b["tag"], b["build"], secs, d1024, d1024 / secs, d2048, d4096, d8192, dhold, dcyc, f))
        summ.setdefault(b["tag"], []).append((d1024, secs))

    v9 = [x for tag in ("A1-v9", "A2-v9") for x in summ.get(tag, [])]
    v10 = summ.get("B-v10", [])
    if v9 and v10:
        n9 = sum(e for e, _ in v9)
        t9 = sum(s for _, s in v9)
        n10 = sum(e for e, _ in v10)
        t10 = sum(s for _, s in v10)
        r9 = n9 / t9
        lam = r9 * t10
        # P(K <= n10 | Poisson(lam))——v10 事件数不高于观测值的概率（越小越支持"相位有效"）
        p = 0.0
        term = 0.0
        k = 0
        while k <= n10:
            term = (lam ** k) * 2.718281828459045 ** (-lam)
            for i in range(1, k + 1):
                term /= i
            p += term
            k += 1
        print("-" * 100)
        print("v9  合计: %d 事件 / %.0f s = %.4f 次/s" % (n9, t9, r9))
        print("v10 合计: %d 事件 / %.0f s = %.4f 次/s" % (n10, t10, n10 / t10 if t10 else float("nan")))
        print("检验：若 v10 与 v9 同率，则 v10 窗内期望 %.2f 个事件；实测 %d 个 => P(K<=%d) = %.2e"
              % (lam, n10, n10, p))
        print("  p < 0.01 ⇒ 相位改变有效（根因在 ADC→FPGA 捕获接口）；p 大 ⇒ 相位不是控制量（根因在 ADC 内部）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
