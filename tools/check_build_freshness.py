#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/check_build_freshness.py —— 检查位流是否比它应该覆盖的 RTL 新。

用法：
    python tools/check_build_freshness.py _impl_v70/enc_top_v70.bit
    python tools/check_build_freshness.py --disp _impl_disp_v70/enc_top_disp_v70.bit
    python tools/check_build_freshness.py --all-v70

背景：tools/final_verify.ps1 的位流新鲜度检查写死的是 v66/v67 时代的目录，
        换版本后会一直报 STALE；本脚本按"给定位流 vs 当前源码 mtime"判断，
        不依赖任何版本目录约定。

退出码：0 = 全部新鲜；1 = 有 STALE 或缺文件。
"""
from __future__ import annotations

import argparse
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def newest(pattern: str) -> tuple[float, str]:
    best = (0.0, "")
    for p in ROOT.glob(pattern):
        if not p.is_file():
            continue
        m = p.stat().st_mtime
        if m > best[0]:
            best = (m, str(p.relative_to(ROOT)))
    return best


def fmt(ts: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


def _strip_build_id(text: str) -> str:
    """去掉 RTL_BUILD_ID 那一行（构建源里这是唯一允许的差异）。"""
    return "\n".join(l for l in text.splitlines() if "RTL_BUILD_ID" not in l)


def snapshot_dir(bit: pathlib.Path) -> pathlib.Path | None:
    """从位流路径推出它对应的 RTL 快照目录（_impl_vNN → _synth_work_vNN/rtl_vNN）。"""
    name = bit.name
    ver = ""
    for tok in bit.parts:
        if tok.startswith("_impl_v"):
            ver = tok[len("_impl_v"):]
        elif tok.startswith("_impl_disp_v"):
            ver = tok[len("_impl_disp_v"):]
    if not ver:
        m = name.replace(".bit", "").split("_v")
        ver = m[-1] if len(m) > 1 else ""
    if not ver:
        return None
    d = ROOT / ("_synth_work_v" + ver) / ("rtl_v" + ver)
    return d if d.is_dir() else None


def content_matches_snapshot(snap: pathlib.Path) -> tuple[bool, str]:
    """把仓库 rtl/ 与构建快照逐文件比对（忽略 RTL_BUILD_ID 行）。"""
    diffs = []
    files = sorted(list((ROOT / "rtl").glob("*.v")) + list((ROOT / "rtl" / "eth").glob("*.v")))
    for src in files:
        rel = src.relative_to(ROOT)
        ref = snap / rel.relative_to("rtl")
        if not ref.is_file():
            diffs.append("%s 缺失" % rel.as_posix())
            continue
        if _strip_build_id(src.read_text(encoding="utf-8")) != \
           _strip_build_id(ref.read_text(encoding="utf-8")):
            diffs.append(rel.as_posix())
    return (not diffs), ("；".join(diffs[:4]) + ("…" if len(diffs) > 4 else ""))


def check(bit: pathlib.Path, with_disp: bool) -> bool:
    if not bit.is_file():
        print("[FAIL] 缺位流：%s" % bit)
        return False
    src, src_name = newest("rtl/*.v")
    eth, eth_name = newest("rtl/eth/*.v")
    if eth > src:
        src, src_name = eth, eth_name
    if with_disp:
        d, dname = newest("disp/*.v")
        if d > src:
            src, src_name = d, dname
    m = bit.stat().st_mtime
    ok = m >= src
    snap = snapshot_dir(bit)
    note = ""
    if not ok and snap is not None:
        same, detail = content_matches_snapshot(snap)
        if same:
            ok = True
            note = "\n        内容与构建快照一致（只差 RTL_BUILD_ID），mtime 变新不代表失效"
        else:
            note = "\n        与构建快照不同：%s" % detail
    print("[%s] %s  %s（%d B）\n        最新源码 %s  %s%s"
          % ("OK  " if ok else "FAIL", bit.relative_to(ROOT),
             fmt(m), bit.stat().st_size, fmt(src), src_name, note))
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("bit", nargs="*", help="生产位流路径")
    ap.add_argument("--disp", nargs="*", default=[], help="显示位流路径（同时比较 disp/*.v）")
    ap.add_argument("--all-v70", action="store_true", help="等价于 --disp 两个 v70 位流")
    ap.add_argument("--all-v71", action="store_true", help="等价于 --disp 两个 v71 位流")
    ap.add_argument("--all-v73", action="store_true", help="等价于 --disp 两个 v73 位流")
    a = ap.parse_args()

    prod = list(a.bit)
    disp = list(a.disp)
    if a.all_v73:
        prod.append("_impl_v73/enc_top_v73.bit")
        disp.append("_impl_disp_v73/enc_top_disp_v73.bit")
    if a.all_v70:
        prod.append("_impl_v70/enc_top_v70.bit")
        disp.append("_impl_disp_v70/enc_top_disp_v70.bit")
    if a.all_v71:
        prod.append("_impl_v71/enc_top_v71.bit")
        disp.append("_impl_disp_v71/enc_top_disp_v71.bit")
    if not prod and not disp:
        ap.print_help()
        return 1

    ok = True
    for b in prod:
        ok &= check(ROOT / b, with_disp=False)
    for b in disp:
        ok &= check(ROOT / b, with_disp=True)
    print("\n%s" % ("全部新鲜" if ok else "存在 STALE 位流（请重新构建）"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
