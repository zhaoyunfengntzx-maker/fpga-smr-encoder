#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/check_tb_coverage.py —— RTL 模块 ↔ 测试平台覆盖对照（离线，纯文本分析）

回答三个问题：
  1. 哪些 RTL 模块被某个 tb_*.v **直接实例化**？
  2. 哪些模块没有直接 TB，但被"有 TB 的父模块"**间接**例化（整机 TB 覆盖）？
  3. 哪些模块既没有直接 TB、也无法从任何有 TB 的顶层到达（真正的覆盖盲区）？

方法（保守、纯静态）：
  * 模块名 = 文件名去 .v（本仓库约定一个文件一个模块）。
  * 父→子 依赖：在父模块源码里出现 `子模块名 #(` 或 `子模块名 实例名 (`。
  * 直接覆盖：tb_*.v 里出现实例化语法。
  * 间接覆盖：从所有直接覆盖的模块出发，沿依赖图向下可达。
  * 孤儿 TB：既不是某个 RTL 模块的同名 TB、也没实例化任何已知模块。

用法：
    python tools/check_tb_coverage.py            # 摘要 + 盲区清单
    python tools/check_tb_coverage.py -v         # 每类都列明细
退出码：0 = 无盲区；1 = 存在盲区模块（便于 CI 把关）。
"""
from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 顶层/桩/厂商模型：自身不需要单独 TB（由整机 TB 覆盖或本就是仿真件）
EXEMPT = {
    "enc_top", "enc_top_disp", "enc_top_lowsig",
    "xilinx_prims_stub", "mig_ui_model",
}


def _read(rel: str) -> str:
    with open(os.path.join(ROOT, rel), "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def collect_sources() -> tuple[dict[str, str], dict[str, str]]:
    rtl: dict[str, str] = {}
    for sub in ("rtl", os.path.join("rtl", "eth"), "disp"):
        d = os.path.join(ROOT, sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith(".v") and not f.startswith("tb_"):
                rtl[os.path.join(sub, f)] = f[:-2]
    tbs: dict[str, str] = {}
    for dirpath, _dirs, files in os.walk(os.path.join(ROOT, "sim")):
        for f in sorted(files):
            if f.startswith("tb_") and f.endswith(".v"):
                p = os.path.relpath(os.path.join(dirpath, f), ROOT)
                tbs[p] = f[:-2]
    return rtl, tbs


def inst_pattern(mod: str) -> re.Pattern:
    # 形如 `mod #(` 或 `mod u_x (`
    return re.compile(r"\b%s\s*(?:#\s*\(|[A-Za-z_]\w*\s*\()" % re.escape(mod))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    rtl, tbs = collect_sources()
    mods = {p: m for p, m in rtl.items() if m not in EXEMPT}
    src = {p: _read(p) for p in rtl}

    # 1) 父 -> 子 依赖
    children: dict[str, set[str]] = {}
    for p, mod in rtl.items():
        kids = set()
        for q, other in rtl.items():
            if q == p:
                continue
            if inst_pattern(other).search(src[p]):
                kids.add(other)
        children[mod] = kids

    # 2) 直接覆盖（含豁免顶层：整机 TB 例化 enc_top/enc_top_disp 也算直接命中，
    #    这样才能沿依赖图向下推"间接覆盖"）
    direct: dict[str, list[str]] = {m: [] for m in rtl.values()}
    for tb, tbmod in tbs.items():
        body = _read(tb)
        for p, mod in rtl.items():
            if tbmod == mod:
                continue
            if inst_pattern(mod).search(body):
                direct[mod].append(tb)

    direct_set = {m for m in mods.values() if direct.get(m)}
    seed_set = {m for m, h in direct.items() if h}

    # 3) 间接覆盖：从"全部直接命中"（含豁免顶层）沿依赖向下
    reached = set(seed_set)
    frontier = list(seed_set)
    while frontier:
        cur = frontier.pop()
        for kid in children.get(cur, ()):
            if kid not in reached:
                reached.add(kid)
                frontier.append(kid)
    indirect_only = sorted(reached - direct_set)
    blind = sorted(m for m in mods.values() if m not in reached)

    orphans = []
    known = set(mods.values()) | EXEMPT
    for tb, tbmod in tbs.items():
        if tbmod in known:
            continue
        body = _read(tb)
        if not any(inst_pattern(m).search(body) for m in known):
            orphans.append(tb)

    print("RTL 模块 %d 个（豁免 %d）｜TB %d 个" % (len(mods), len(EXEMPT), len(tbs)))
    print("  直接有 TB        : %d" % len(direct_set))
    print("  仅间接覆盖(整机) : %d" % len(indirect_only))
    print("  覆盖盲区         : %d" % len(blind))
    print("  孤儿 TB          : %d" % len(orphans))

    if a.verbose:
        print("\n== 直接有 TB ==")
        for m in sorted(direct_set):
            print("  %-22s <- %s" % (m, ", ".join(os.path.basename(x) for x in direct[m])))
        print("\n== 仅间接覆盖（父模块有 TB） ==")
        for m in indirect_only:
            print("  %s" % m)
    if blind:
        print("\n== 覆盖盲区（既无直接 TB 也不在任何有 TB 的层次里） ==")
        for m in blind:
            print("  %s" % m)
    if orphans:
        print("\n== 孤儿 TB ==")
        for tb in orphans:
            print("  %s" % tb)

    return 0 if not blind else 1


if __name__ == "__main__":
    sys.exit(main())
