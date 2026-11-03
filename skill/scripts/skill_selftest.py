#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""skill_selftest.py —— 技能包自检：把 skill/ 里的校验脚本跑一遍，证明"它真的会判"

【适用】拿到这个 skill/ 目录的任何人在**动自己的工程之前**先跑这一个脚本：
        它只读 examples/ 下的夹具、只往系统临时目录写 JSON，不碰你的 RTL、不碰 git。
        目的很朴素：如果连技能包自带的"该通过"样例都不通过、或"该失败"样例竟然通过，
        那这套判据就不可信，后面用它下的任何结论都不成立。

【用法】
    python skill/scripts/skill_selftest.py            # 全部跑一遍
    python skill/scripts/skill_selftest.py -v         # 顺便把每个脚本的原始输出也打出来
    python skill/scripts/skill_selftest.py --list     # 只列用例

【退出码】0 = 所有用例符合预期；1 = 至少一个用例不符合预期；2 = 环境问题（找不到夹具/脚本）
        不会返回 2 之外的"无法判断"——每个用例的期望退出码是写死的。

【判据不是"退出码 0"，而是"退出码等于该用例应有的值"】
  通过样例期望 0，失败样例期望 1，缺输入期望 2。只检查 0 会漏掉
  "该报错时它没报错"这种最危险的失效——本工程在记录 1（空转测试台）上就吃过这个亏：
  测试台退出码 0、打印 PASSED，缺陷照样溜过去。

【为什么要有这个脚本】
  2026-11-03 之前，skill/ 下只有 7 篇 .md，没有一行可执行代码：文档说"要用逐点比对"，
  陌生队伍得自己从头写比对器，写完也不知道写对没有。补了脚本之后又出现新风险——
  脚本本身会退化（改一个正则把 E1 判据改没了，仍然"跑得很顺"）。
  这个自检就是给脚本自己配的"测试台"：反例样例必须继续失败。
  方法与 skill/testbench-blindspot.md 的"负对照"同源。

【失效条件】
  1) 改了 examples/ 夹具或改了脚本判据却没同步改期望值——它会红，但那是"你改了合同"，
     不是"脚本坏了"；期望值就是这套资产的规格书，改它要写理由；
  2) 环境没有可写的临时目录（用例 5 要写 JSON）；
  3) 它证明的是"判据在自带样例上成立"，**不证明**"判据对你的工程成立"——
     你的工程要自己准备一对"该过/该失败"的样例。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
EX = os.path.join(SKILL, "examples")


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def _tampered_manifest() -> list[str]:
    """把 manifest 样例复制到临时目录、改一个字节、再校验 → 必须报 FAIL。
    这是清单脚本的"负对照"：只验证"能通过"是不够的，还要证明"改过会失败"。"""
    src = os.path.join(EX, "manifest")
    dst = os.path.join(tempfile.gettempdir(), "skill_selftest_manifest")
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)
    with open(os.path.join(dst, "data", "table.csv"), "r", encoding="utf-8") as f:
        body = f.read()
    with open(os.path.join(dst, "data", "table.csv"), "w", encoding="utf-8", newline="\n") as f:
        f.write(body + "tamper,1\n")
    return ["--dir", dst, "--verify"]


def _copy_manifest(tag: str) -> str:
    """把 manifest 样例复制到独立临时目录（每个用例一份，互不干扰）。"""
    dst = os.path.join(tempfile.gettempdir(), f"skill_selftest_{tag}")
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(os.path.join(EX, "manifest"), dst)
    return dst


def _add_file(dst: str, name: str) -> None:
    with open(os.path.join(dst, name), "w", encoding="utf-8", newline="\n") as f:
        f.write("not in the manifest\n")


def _manifest_write() -> list[str]:
    """删掉清单里的一个文件、再加一个新文件，然后 --write：

    期望 0——写清单本来就该把"现状"记下来，包括新增与消失。
    """
    dst = _copy_manifest("write")
    os.remove(os.path.join(dst, "SHA256SUMS.txt"))
    _add_file(dst, "extra.bin")
    return ["--dir", dst, "--write"]


def _manifest_extra() -> list[str]:
    """清单没变、多了一个文件 → --strict 必须失败（"清单外"）。"""
    dst = _copy_manifest("extra")
    _add_file(dst, "extra.bin")
    return ["--dir", dst, "--verify", "--strict"]


def _manifest_extra_excluded() -> list[str]:
    """同一个多出来的文件，用 --exclude 放过 → 0（证明排除参数真的生效）。"""
    dst = _copy_manifest("excluded")
    _add_file(dst, "extra.bin")
    return ["--dir", dst, "--verify", "--strict", "--exclude", "extra.bin"]


def cases() -> list[dict]:
    """每个用例：名字 / 脚本 / 参数 / 期望退出码 / 输出里必须出现的片段（可选）。
    prep 存在时在运行时生成参数（用于需要临时目录的负对照）。"""
    impl = os.path.join(HERE, "check_impl_reports.py")
    vec = os.path.join(HERE, "check_vectors.py")
    man = os.path.join(HERE, "check_manifest.py")
    wire = os.path.join(HERE, "tb_wiring.py")
    tmp = tempfile.gettempdir()

    return [
        # ---- Vivado 实现报告判决 ----
        {"name": "实现报告·通过样例 → 0", "script": impl,
         "args": ["--dir", os.path.join(EX, "reports_pass")],
         "rc": 0, "must": "PASS"},
        {"name": "实现报告·失败样例 → 1", "script": impl,
         "args": ["--dir", os.path.join(EX, "reports_fail")],
         "rc": 1, "must": "FAIL"},
        {"name": "实现报告·目录不存在 → 2（不静默通过）", "script": impl,
         "args": ["--dir", os.path.join(EX, "no_such_dir")],
         "rc": 2, "must": ""},
        {"name": "实现报告·收紧资源上限后通过样例也失败 → 1", "script": impl,
         "args": ["--dir", os.path.join(EX, "reports_pass"), "--max-util", "Slice LUTs=50"],
         "rc": 1, "must": "FAIL"},
        {"name": "实现报告·JSON 可写出且含证据行号", "script": impl,
         "args": ["--dir", os.path.join(EX, "reports_pass"), "-q",
                  "--json", os.path.join(tmp, "skill_selftest_impl.json")],
         "rc": 0, "must": ""},

        # ---- 黄金 vs 仿真逐点比对 ----
        {"name": "逐点比对·一致样例 → 0", "script": vec,
         "args": [os.path.join(EX, "vectors", "golden.csv"),
                  os.path.join(EX, "vectors", "sim_ok.csv")],
         "rc": 0, "must": "PASS"},
        {"name": "逐点比对·差 5 LSB 样例 → 1", "script": vec,
         "args": [os.path.join(EX, "vectors", "golden.csv"),
                  os.path.join(EX, "vectors", "sim_bad.csv"), "--tol", "1"],
         "rc": 1, "must": "FAIL"},
        {"name": "逐点比对·容差放宽到 5 后同一对通过 → 0", "script": vec,
         "args": [os.path.join(EX, "vectors", "golden.csv"),
                  os.path.join(EX, "vectors", "sim_bad.csv"), "--tol", "5"],
         "rc": 0, "must": "PASS"},

        # ---- SHA256 清单 ----
        {"name": "清单·样例校验通过 → 0", "script": man,
         "args": ["--dir", os.path.join(EX, "manifest"), "--verify"],
         "rc": 0, "must": "PASS"},
        {"name": "清单·改动一个文件后必须失败 → 1（负对照）", "script": man,
         "prep": _tampered_manifest,
         "rc": 1, "must": "被改动"},

        # ---- 测试台接线体检 ----
        {"name": "接线体检·好测试台 → 0", "script": wire,
         "args": [os.path.join(EX, "wiring", "tb_good.v"),
                  "--dut", os.path.join(EX, "wiring", "dut_sample.v")],
         "rc": 0, "must": "PASS"},
        {"name": "接线体检·空转测试台 → 1", "script": wire,
         "args": [os.path.join(EX, "wiring", "tb_dangling.v"),
                  "--dut", os.path.join(EX, "wiring", "dut_sample.v")],
         "rc": 1, "must": "FAIL"},
        {"name": "接线体检·空转测试台必须报出 E2 常量激励", "script": wire,
         "args": [os.path.join(EX, "wiring", "tb_dangling.v"),
                  "--dut", os.path.join(EX, "wiring", "dut_sample.v")],
         "rc": 1, "must": "E2"},
        {"name": "接线体检·--scan 扫目录 → 1（含坏测试台）", "script": wire,
         "args": ["--scan", os.path.join(EX, "wiring"),
                  "--dut", os.path.join(EX, "wiring", "dut_sample.v")],
         "rc": 1, "must": "共 2 个测试台"},

        # ---- 补充：把 31 个参数里最容易被误用/误读的那些各钉一条 ----
        {"name": "实现报告·--min-wns 10 让通过样例失败（阈值真的生效）", "script": impl,
         "args": ["--dir", os.path.join(EX, "reports_pass"), "--min-wns", "10", "-q"],
         "rc": 1, "must": "FAIL"},
        {"name": "实现报告·放宽阈值后失败样例的通过数上升（10 项里 7 项过）", "script": impl,
         "args": ["--dir", os.path.join(EX, "reports_fail"), "--max-drc-errors", "5",
                  "--min-wns", "-1", "--max-failing", "99", "--max-util", "Slice LUTs=99",
                  "--max-util", "Block RAM Tile=99", "-q"],
         "rc": 1, "must": "7/10"},
        {"name": "实现报告·单独指定 --timing/--util 也能判", "script": impl,
         "args": ["--timing", os.path.join(EX, "reports_pass", "timing_pass.rpt"),
                  "--util", os.path.join(EX, "reports_pass", "util_pass.rpt"), "-q"],
         "rc": 0, "must": "PASS"},
        {"name": "逐点比对·--col-ref/--col-got 选列（第 1 列两边相同 → 通过）", "script": vec,
         "args": [os.path.join(EX, "vectors", "golden.csv"),
                  os.path.join(EX, "vectors", "sim_bad.csv"),
                  "--col-ref", "1", "--col-got", "1", "-q"],
         "rc": 0, "must": "PASS"},
        {"name": "逐点比对·--hist 分出误差倍数区间", "script": vec,
         "args": [os.path.join(EX, "vectors", "golden.csv"),
                  os.path.join(EX, "vectors", "sim_bad.csv"), "--tol", "5", "--hist", "-q"],
         "rc": 0, "must": "0L"},
        {"name": "清单·--write 生成清单后退出 0（负对照的反面）", "script": man,
         "prep": _manifest_write, "rc": 0, "must": ""},
        {"name": "清单·--strict 下清单外多一个文件必须失败", "script": man,
         "prep": _manifest_extra, "rc": 1, "must": "清单外"},
        {"name": "清单·--exclude 放过被排除的文件", "script": man,
         "prep": _manifest_extra_excluded, "rc": 0, "must": "PASS"},
        {"name": "接线体检·--strict 下好测试台仍然 0（不能为了严格就误报）", "script": wire,
         "args": [os.path.join(EX, "wiring", "tb_good.v"),
                  "--dut", os.path.join(EX, "wiring", "dut_sample.v"), "--strict"],
         "rc": 0, "must": "PASS"},
        {"name": "接线体检·不给 --dut 时仍查得出常量激励 E2（方向类不猜）", "script": wire,
         "args": [os.path.join(EX, "wiring", "tb_dangling.v"), "--strict"],
         "rc": 1, "must": "E2"},
    ]


def run_one(c: dict, verbose: bool) -> tuple[bool, str]:
    args = c["prep"]() if "prep" in c else c["args"]
    cmd = [sys.executable, c["script"]] + args
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"跑不起来：{e}"
    out = (p.stdout or "") + (p.stderr or "")
    if verbose:
        print("    $ " + " ".join(cmd))
        for line in out.rstrip().splitlines():
            print("    | " + line)

    problems = []
    if p.returncode != c["rc"]:
        problems.append(f"退出码 {p.returncode}，期望 {c['rc']}")
    if c["must"] and c["must"] not in out:
        problems.append(f"输出里没有 '{c['must']}'")
    return (not problems), "；".join(problems)


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="skill/ 自检：验证四个校验脚本仍然会判")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印每个用例的原始输出")
    ap.add_argument("--list", action="store_true", help="只列用例，不执行")
    args = ap.parse_args(argv)

    cs = cases()
    if args.list:
        for i, c in enumerate(cs, 1):
            print(f"{i:2d}. [{c['rc']}] {c['name']}")
        return 0

    missing = [c["script"] for c in cs if not os.path.isfile(c["script"])]
    if not os.path.isdir(EX) or missing:
        print(f"[ERROR] 夹具目录或脚本缺失：{EX}", file=sys.stderr)
        for m in sorted(set(missing)):
            print(f"        缺 {m}", file=sys.stderr)
        return 2

    print(f"skill 自检：{len(cs)} 个用例，夹具 {EX}")
    print("-" * 72)
    ok = 0
    bad: list[tuple[str, str]] = []
    for i, c in enumerate(cs, 1):
        passed, why = run_one(c, args.verbose)
        mark = "ok  " if passed else "FAIL"
        print(f"[{mark}] {i:2d}/{len(cs)}  {c['name']}")
        if passed:
            ok += 1
        else:
            print(f"        {why}")
            bad.append((c["name"], why))
    print("-" * 72)
    print(f"结果：{ok}/{len(cs)} 用例符合预期")
    if bad:
        print("不符合预期的用例：")
        for name, why in bad:
            print(f"  - {name}：{why}")
        print("=> 技能包自身的判据不可信，先修脚本再用它下结论。")
        return 1
    print("=> 四个校验脚本在自带样例上都给出预期判决（通过样例通过、失败样例失败）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
