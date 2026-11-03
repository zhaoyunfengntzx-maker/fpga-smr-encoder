#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PYNQ 技能包的自我验收：13 个用例，跑在 skill/pynq/ 自带的夹具上。

【适用】
  改了这个目录里的任何东西之后——改脚本、换夹具、调判据——先跑它。
  它检查的是"判据还认得出好与坏"，不是"你的板子能跑"。

【用法】
  python skill/pynq/pynq_selftest.py            # 跑全部，打印 13 行结论
  python skill/pynq/pynq_selftest.py -v         # 失败时附上脚本原始输出
  python skill/pynq/pynq_selftest.py --list     # 只列用例，不执行

【输入格式与退出码】
  退出码：0 13/13 符合预期；1 有用例不符；2 夹具或脚本缺失（环境问题，不是判据问题）。

【为什么要有这个脚本】
  记录 73：全面自查要交给"专门来证伪的人"——门禁自己坏了最难发现。
  记录 70：判据静默少跑，比没有判据更危险。所以这里每个用例都**同时**断言
  "该过的过"和"该红的红"，并且 4 条负对照写死在用例表里。

【失效条件】
  1) 它证明的是"样例上的判决正确"，不证明你的 overlay 正确。
  2) 若你改了夹具而没改期望值，它会红——那时先想清楚是夹具该改还是判据该改。
  3) 需要可写的临时目录（%TEMP%）；只读环境下 1 个用例会退化成 SKIP。
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
EX = HERE / "examples"


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def _cp_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def prep_stale(tmp: Path) -> list:
    """让 .hwh 比 .bit 旧：判据 BUNDLE-004 才有输入。"""
    d = tmp / "stale_bundle"
    _cp_tree(EX / "bundle", d)
    hwh = d / "design_1.hwh"
    old = hwh.stat().st_mtime - 3600
    os.utime(hwh, (old, old))
    return [str(d)]


def prep_json(tmp: Path) -> list:
    return [str(tmp / "map.json")]


def cases():
    hwh = ["skill/pynq/pynq_hwh.py"]
    bundle = ["skill/pynq/pynq_bundle.py"]
    overlay = ["skill/pynq/pynq_overlay.py"]
    ex = "skill/pynq/examples"
    return [
        dict(name="地址表：正常 hwh 应 PASS", script=hwh,
             args=[f"{ex}/addr_map/design_1.hwh", "-q"], rc=0, must=["PASS"]),
        dict(name="地址表：重叠地址必须 FAIL", script=hwh,
             args=[f"{ex}/addr_bad/design_1.hwh", "-q"], rc=1, must=["地址重叠"]),
        dict(name="地址表：没分配地址必须 FAIL", script=hwh,
             args=[f"{ex}/real_bd/design_1.hwh", "-q"], rc=1, must=["没有任何 MEMRANGE"]),
        dict(name="地址表：--json 落盘且含 IP 清单", script=hwh,
             args=[f"{ex}/addr_map/design_1.hwh", "--json"], rc=0, must=["PASS"],
             prep=lambda tmp: [str(tmp / "map.json")], json_file="map.json"),
        dict(name="地址表：--md 生成地址表文档", script=hwh,
             args=[f"{ex}/addr_map/design_1.hwh", "--md"], rc=0, must=["PASS"],
             prep=lambda tmp: [str(tmp / "map.md")], md_file="map.md"),
        dict(name="地址表：两版对比要报地址变化", script=hwh,
             args=[f"{ex}/addr_map/design_1.hwh", "--diff", f"{ex}/addr_bad/design_1.hwh", "-q"],
             rc=0, must=["地址变化"]),
        dict(name="地址表：文件不存在应 EXIT 2", script=hwh,
             args=[f"{ex}/nope.hwh"], rc=2, must=["找不到"]),
        dict(name="交付目录：位流与地址表配对应 PASS", script=bundle,
             args=[f"{ex}/bundle", "-q"], rc=0, must=["配对"]),
        dict(name="交付目录：缺 .hwh 必须 FAIL", script=bundle,
             args=[f"{ex}/bundle_nohwh", "-q"], rc=1, must=["没有同名 .hwh"]),
        dict(name="交付目录：.hwh 比 .bit 旧要报警", script=bundle,
             args=[], rc=1, must=["旧"], prep=prep_stale),
        dict(name="交付目录：与旧版对比要报地址变化", script=bundle,
             args=[f"{ex}/bundle", "--diff", f"{ex}/addr_bad/design_1.hwh", "-q"],
             rc=0, must=["地址变了"]),
        dict(name="回环：内建自检 4/4（含 3 条负对照）", script=overlay,
             args=["--selftest"], rc=0, must=["自检 4/4"]),
        dict(name="回环：mock 上 5 条判据全过", script=overlay,
             args=["--mock", "--count", "256"], rc=0, must=["PASS（5/5"]),
    ]


def run_case(c: dict, tmp: Path, verbose: bool) -> tuple[bool, str]:
    """args 是固定参数；prep(tmp) 返回**追加到末尾**的路径参数（如输出文件名）。"""
    args = list(c["args"])
    if c.get("prep"):
        args += c["prep"](tmp)
    cmd = [sys.executable] + c["script"] + args
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=env)
    out = (proc.stdout or "") + (proc.stderr or "")
    ok = proc.returncode == c["rc"] and all(m in out for m in c.get("must", []))
    why = f"rc={proc.returncode}（期望 {c['rc']}）"
    if proc.returncode == c["rc"]:
        missing = [m for m in c.get("must", []) if m not in out]
        if missing:
            why = f"输出缺少 {missing}"

    if ok and c.get("json_file"):
        p = tmp / c["json_file"]
        if not p.is_file():
            ok, why = False, f"没有生成 {p}"
        else:
            import json
            data = json.loads(p.read_text(encoding="utf-8"))
            if not data.get("ips"):
                ok, why = False, "JSON 里 ips 为空"
            elif "design_1" not in p.read_text(encoding="utf-8"):
                ok, why = False, "JSON 里没有设计名"
    if ok and c.get("md_file"):
        p = tmp / c["md_file"]
        if not p.is_file() or "地址表" not in p.read_text(encoding="utf-8"):
            ok, why = False, "md 没生成或没有标题"

    if verbose and not ok:
        print(out)
    return ok, why


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="PYNQ 技能包自检")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args(argv)

    if not (HERE / "pynq_hwh.py").is_file() or not EX.is_dir():
        print("[EXIT2] 找不到 pynq_hwh.py 或 examples/：请从仓库根运行 "
              "`python skill/pynq/pynq_selftest.py`")
        return 2

    items = cases()
    if args.list:
        for i, c in enumerate(items, 1):
            print(f"{i:2d}. {c['name']}（期望 rc={c['rc']}）")
        return 0

    print(f"PYNQ 技能包自检：{len(items)} 个用例")
    tmp = Path(tempfile.mkdtemp(prefix="pynq_selftest_"))
    bad = 0
    try:
        for i, c in enumerate(items, 1):
            ok, why = run_case(c, tmp, args.verbose)
            bad += 0 if ok else 1
            print(f"  [{i:2d}/{len(items)}] {'OK' if ok else 'XX'} {c['name']}"
                  + ("" if ok else f"  ← {why}"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n结果：{len(items) - bad}/{len(items)} 用例符合预期")
    if bad:
        print("=> 有判据不再按预期工作：先看是哪一条被改了（夹具或期望值）")
        return 1
    print("=> 三个工具在自带夹具上都给出预期判决（该过的过、该红的红）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
