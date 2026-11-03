# -*- coding: utf-8 -*-
"""从实现报告里取 P8 的三个资源百分比，与 RTL 常量对齐。

P8 页上「LUT % / BRAM % / DSP %」三个数来自 disp/touch_view.v 的三个
localparam（RES_LUT_PCT / RES_BRAM_PCT / RES_DSP_PCT）。它们参与综合，所以
只能是"交付位流的快照"：报告变了而常量没变，屏上就会说假话（历史上 LUT 一项
少报过 2.5 个点）。

本工具做两件事：
  1. 默认 **只校验**：把 impl_util.rpt 的取整值与 RTL 常量比对，不一致就退出码 1，
     并把"改了就要重出位流"这件事打出来；
  2. 加 `--write` 时**改写**三个常量（仍会打印 diff 摘要），改完必须重跑实现。

用法：
    python tools/gen_res_pct.py
    python tools/gen_res_pct.py --write
    python tools/gen_res_pct.py --report _disp_work/impl_util.rpt --rtl disp/touch_view.v
"""

import argparse
import io
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 报告里的行标签 -> RTL 常量名
LABELS = [
    ("Slice LUTs", "RES_LUT_PCT"),
    ("Block RAM Tile", "RES_BRAM_PCT"),
    ("DSPs", "RES_DSP_PCT"),
]


def read_text(path):
    """读文本；兼容 PowerShell 重定向写出的 UTF-16LE。"""
    raw = io.open(path, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    if b"\x00" in raw[:400]:
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8", errors="replace")


def util_rows(text):
    """把 util 报告解析成 {标签: (用量字符串, 百分比字符串)}。"""
    out = {}
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 6:
            continue
        label = cells[0]
        if label in out:
            continue
        used, pct = cells[1], cells[5]
        if re.fullmatch(r"\d+(\.\d+)?", pct or ""):
            out[label] = (used, pct)
    return out


def rtl_consts(text):
    """取 RTL 里三个常量的当前整数值。"""
    out = {}
    for _, name in LABELS:
        m = re.search(r"localparam\s*\[31:0\]\s*%s\s*=\s*32'd(\d+)\s*;" % name, text)
        out[name] = int(m.group(1)) if m else None
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", default=os.path.join(ROOT, "_disp_work", "impl_util.rpt"))
    ap.add_argument("--rtl", default=os.path.join(ROOT, "disp", "touch_view.v"))
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args()

    if not os.path.exists(a.report):
        print("[FAIL] 报告不存在: %s" % a.report)
        print("       先跑 tools/impl_disp.tcl 出一次位流，报告才有意义。")
        return 1

    rows = util_rows(read_text(a.report))
    rtl = read_text(a.rtl)
    cur = rtl_consts(rtl)

    print("================ P8 资源百分比对账 ================")
    print("报告: %s" % os.path.relpath(a.report, ROOT))
    print("RTL : %s" % os.path.relpath(a.rtl, ROOT))
    print("")
    print(" %-16s %-10s %-8s %-6s %s" % ("行标签", "用量", "报告%", "取整", "RTL 现值"))
    bad = []
    want = {}
    for label, name in LABELS:
        if label not in rows:
            print("[FAIL] 报告里找不到行: %s" % label)
            return 1
        used, pct = rows[label]
        r = int(math.floor(float(pct) + 0.5))
        want[name] = r
        flag = "" if cur[name] == r else "  <== 不一致"
        if cur[name] != r:
            bad.append((name, cur[name], r))
        print(" %-16s %-10s %-8s %-6d %s%s" % (label, used, pct, r, cur[name], flag))
    print("")

    if not bad:
        print("[OK] 三个常量与报告一致（%d / %d / %d）"
              % (want["RES_LUT_PCT"], want["RES_BRAM_PCT"], want["RES_DSP_PCT"]))
        return 0

    if not a.write:
        for name, old, new in bad:
            print("      %s: %d -> %d" % (name, old, new))
        print("[RED] 屏上会报旧值。改法：python tools/gen_res_pct.py --write "
              "然后**重出位流**（这三个常量参与综合）。")
        return 1

    for name, old, new in bad:
        pat = re.compile(r"(localparam\s*\[31:0\]\s*%s\s*=\s*32'd)\d+" % name)
        rtl, n = pat.subn(lambda m: m.group(1) + str(new), rtl)
        if n != 1:
            print("[FAIL] 改写 %s 命中 %d 次（期望 1）" % (name, n))
            return 1
        print("[WRITE] %s: %d -> %d" % (name, old, new))
    io.open(a.rtl, "w", encoding="utf-8", newline="\n").write(rtl)
    print("[OK] 已写入。★ 这三个常量参与综合 ⇒ 必须重跑 tools/impl_disp.tcl 并重新归档位流与报告。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
