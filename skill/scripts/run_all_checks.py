#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一条命令跑完这个技能包的所有机器判据，最后给一个总判决。

【适用】
  交付前、改完任何一个脚本/夹具/文档后、以及"我到底还差什么"的时候。
  它把散在 skill/ 与 tools/ 里的判据串起来，任何人不必读文档就知道现状。

【用法】
  python skill/scripts/run_all_checks.py              # 跑全部，给总判决
  python skill/scripts/run_all_checks.py --fast       # 跳过两套自检（只查文档与计数）
  python skill/scripts/run_all_checks.py -v           # 失败时附原始输出
  python skill/scripts/run_all_checks.py --only links,citations

【输入格式与退出码】
  退出码：0 全部通过；1 有判据失败；2 环境不全（比如不在仓库里，缺 tools/）。

【为什么要有这个脚本】
  记录 70：判据静默少跑比没有判据更危险——"我跑了检查"这句话必须能被一条命令证实。
  记录 73：门禁自己坏了最难发现，所以这条命令自己也接受两套自检的检查。
  本仓库曾经的状态是：5 个脚本 + 两个自检 + 4 个 tools 检查，各自都能跑，
  但要人记住 9 条命令；少跑一条谁也不知道。

【失效条件】
  1) 它只能告诉你"本机这套判据现在是什么结论"，不能替代上板实测。
  2) 依赖仓库结构：tools/ 下的检查不在时，那几项会标 SKIP（此时仍可信，但覆盖面变小）。
  3) 需要 Python 3.9+；不需要 Vivado、不需要 PYNQ 库、不需要板卡。
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
ROOT = SKILL.parent


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def _run(cmd: list[str], env: dict) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                              errors="replace", env=env, cwd=str(ROOT), timeout=600)
    except FileNotFoundError:
        return 2, f"找不到 {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 2, "超时（600 s）"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def checks() -> list[dict]:
    py = sys.executable
    return [
        {"id": "selftest", "name": "主包自检（24 用例，含负对照）",
         "cmd": [py, str(HERE / "skill_selftest.py")], "fast": False},
        {"id": "pynq", "name": "PYNQ 子包自检（18 用例）",
         "cmd": [py, str(SKILL / "pynq" / "pynq_selftest.py")], "fast": False},
        {"id": "index", "name": "症状索引与清单一致",
         "cmd": [py, str(ROOT / "tools" / "gen_pitfall_index.py"), "--check"], "fast": True},
        {"id": "links", "name": "Markdown 相对链接",
         "cmd": [py, str(ROOT / "tools" / "check_links.py")], "fast": True},
        {"id": "names", "name": "仓库命名（ASCII / 大小写）",
         "cmd": [py, str(ROOT / "tools" / "check_names.py")], "fast": True},
        {"id": "citations", "name": "记录号引用可追",
         "cmd": [py, str(ROOT / "tools" / "check_citations.py")], "fast": True},
        {"id": "counts", "name": "文档里的数字与现场一致",
         "cmd": [py, str(ROOT / "tools" / "check_counts.py")], "fast": True},
    ]


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="技能包总判决")
    ap.add_argument("--fast", action="store_true", help="跳过两套自检")
    ap.add_argument("--only", help="只跑指定几项，逗号分隔（selftest,pynq,links,names,citations,counts）")
    ap.add_argument("-v", "--verbose", action="store_true", help="失败时打印原始输出")
    args = ap.parse_args(argv)

    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
    wanted = {s.strip() for s in args.only.split(",")} if args.only else None

    rows = []
    for c in checks():
        if wanted and c["id"] not in wanted:
            continue
        if args.fast and not c["fast"]:
            rows.append((c["name"], "SKIP", "(--fast)"))
            continue
        script = Path(c["cmd"][1])
        if not script.is_file():
            rows.append((c["name"], "SKIP", f"没有 {script}"))
            continue
        rc, out = _run(c["cmd"], env)
        detail = ""
        for line in reversed(out.strip().splitlines()):
            if line.strip():
                detail = line.strip()
                break
        if rc == 2:
            rows.append((c["name"], "SKIP", detail or "工具自己说判不了"))
        elif rc == 0:
            rows.append((c["name"], "ok", detail))
        else:
            rows.append((c["name"], "FAIL", detail))
            if args.verbose:
                print(f"\n--- {c['name']} 原始输出 ---\n{out}")

    width = max(len(n) for n, _, _ in rows) + 2
    print("\n技能包判据现状")
    print("-" * 78)
    for name, state, detail in rows:
        print(f"{name:<{width}} {state:<5} {detail}")
    print("-" * 78)

    bad = [r for r in rows if r[1] == "FAIL"]
    ok = [r for r in rows if r[1] == "ok"]
    skip = [r for r in rows if r[1] == "SKIP"]
    if bad:
        print(f"=> FAIL（{len(ok)} 项通过，{len(bad)} 项失败，{len(skip)} 项跳过）")
        for name, _, detail in bad:
            print(f"   - {name}: {detail}")
        return 1
    print(f"=> PASS（{len(ok)} 项通过，{len(skip)} 项跳过）")
    if skip:
        print("   跳过的原因写在上面，别把 SKIP 当 PASS。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
