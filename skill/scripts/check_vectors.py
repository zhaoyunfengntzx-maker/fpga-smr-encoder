#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_vectors.py —— 仿真输出 vs 黄金模型：逐点比对，给最大误差与出错的点号

【适用】任何"有一份参考序列、有一份仿真/实测序列"的场合：
        定点算法（ATAN/CORDIC/滤波器）的逐点比对、控制器输出的逐拍比对、
        Python 黄金模型 ↔ Verilog 仿真导出的比对、上板采样 ↔ 模型复算的比对。

【用法】
    # 两个文件，都取"最后一列"当数值；都只有一列也认
    python check_vectors.py golden.csv sim.csv

    # 文件是多列（如 idx,angle_code,sin,cos）时，明确指定两边的取值列（1 基）
    python check_vectors.py golden.csv sim.csv --col-ref 2 --col-got 3

    # 允许 1 LSB 误差（整数 LSB 口径），并输出 JSON 给 CI
    python check_vectors.py golden.csv sim.csv --tol 1 --json result.json

    # 看误差分布：直方图 + 最坏的 10 个点
    python check_vectors.py golden.csv sim.csv --hist --top 10

【输入格式】CSV（逗号）或空白分隔的纯文本；空行与 # 开头行忽略；含非数字的行当表头跳过。
            两边行数不等时按较短的一边比，并在 stderr 报 WARN（绝不静默截断）。

【退出码】0 = 全部点在容差内；1 = 有点超差；2 = 文件读不了 / 没有数据 / 列号越界

【为什么要有这个脚本】
  "我看了一眼波形，差不多" 是本工程最常见的误判来源（见 skill/testbench-blindspot.md）。
  逐点比对时人眼只能看几十个点，而一个 12 bit 相位的象限折叠错误只在
  180° 附近表现成"跳变 1 个 LSB"，肉眼永远看不出；脚本能给出 max/RMS 与点号。
  本工程用同一口径把 6 参数标定后的 20.9839° 压到 0.0165°（1273×），
  靠的就是"每个点都算误差"而不是"抽几个点看看"。
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys

NUM = re.compile(r"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$")


def _utf8_console() -> None:
    """管道重定向时统一按 UTF-8 输出：否则中文 Windows 会写成 GBK，
    被 CI/日志工具按 UTF-8 解码后变成乱码（本工程踩过，见 pitfalls 第 21 条）。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def read_rows(path: str) -> list[list[float]]:
    rows: list[list[float]] = []
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = [p for p in re.split(r"[,\s]+", s) if p]
            if not parts or not all(NUM.match(p) for p in parts):
                continue  # 表头 / 注释
            rows.append([float(p) for p in parts])
    return rows


def pick(row: list[float], col: int) -> float:
    return row[col] if col >= 0 else row[len(row) + col]


def _w(s: str) -> int:
    """显示宽度：CJK 占 2 列，否则中文表头对不齐。"""
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def rpad(s: str, width: int) -> str:
    return " " * max(0, width - _w(s)) + s


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="逐点比对仿真输出与参考序列")
    ap.add_argument("golden", help="参考/黄金序列文件")
    ap.add_argument("got", help="实测/仿真序列文件")
    ap.add_argument("--col-ref", type=int, default=-1, help="参考文件取第几列，1 基；默认最后一列")
    ap.add_argument("--col-got", type=int, default=-1, help="实测文件取第几列，1 基；默认最后一列")
    ap.add_argument("--tol", type=float, default=0.0,
                    help="允许的最大绝对误差（默认 0，即要求逐位一致）")
    ap.add_argument("--top", type=int, default=5, help="打印最坏的 N 个点（默认 5）")
    ap.add_argument("--hist", action="store_true", help="打印误差分布直方图")
    ap.add_argument("--json", help="把结果写成 JSON")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    try:
        g_rows = read_rows(args.golden)
        s_rows = read_rows(args.got)
    except OSError as e:
        print(f"[ERROR] 读文件失败: {e}", file=sys.stderr)
        return 2

    for name, rows, col in ((args.golden, g_rows, args.col_ref),
                            (args.got, s_rows, args.col_got)):
        if not rows:
            print(f"[ERROR] {name} 里没有任何数据行", file=sys.stderr)
            return 2
        width = len(rows[0])
        if col != -1 and not (1 <= col <= width):
            print(f"[ERROR] {name} 只有 {width} 列，--col 指定了 {col}", file=sys.stderr)
            return 2
        if col == -1 and width < 1:
            print(f"[ERROR] {name} 没有数值列", file=sys.stderr)
            return 2

    ci_ref = args.col_ref - 1 if args.col_ref > 0 else -1
    ci_got = args.col_got - 1 if args.col_got > 0 else -1

    n = min(len(g_rows), len(s_rows))
    if len(g_rows) != len(s_rows):
        print(f"[WARN] 行数不等：参考 {len(g_rows)} 行，实测 {len(s_rows)} 行，只比前 {n} 行",
              file=sys.stderr)

    errs: list[tuple[float, float, float, float]] = []  # (点号, 参考, 实测, 误差)
    for k in range(n):
        gr, sr = g_rows[k], s_rows[k]
        gv, sv = pick(gr, ci_ref), pick(sr, ci_got)
        # 行内第 1 列若看起来像点号（两边都有且相等），就把它当点号
        pid: float = k
        if len(gr) >= 2 and len(sr) >= 2 and gr[0] == sr[0]:
            pid = int(gr[0]) if float(gr[0]).is_integer() else gr[0]
        errs.append((pid, gv, sv, sv - gv))

    abs_err = [abs(e[3]) for e in errs]
    max_err = max(abs_err)
    rms = math.sqrt(sum(e * e for e in abs_err) / len(abs_err))
    bad = [e for e in errs if abs(e[3]) > args.tol + 1e-12]
    # 有超差点就只展示超差点；全部通过时才展示"最坏的 N 个"供参考
    worst = sorted(bad, key=lambda t: -abs(t[3]))[: max(1, args.top)] if bad \
        else sorted(errs, key=lambda t: -abs(t[3]))[: max(1, args.top)]

    passed = not bad
    status = "PASS" if passed else "FAIL"

    if not args.quiet:
        print(f"参考: {args.golden}")
        print(f"实测: {args.got}")
        print(f"点数: {n}   容差: {args.tol:g}   max|err| = {max_err:g}   RMS = {rms:.6g}")
        if bad:
            print(f"超差点数: {len(bad)} / {n}  ({100.0 * len(bad) / n:.2f}%)")
            print("\n最坏的点：")
            print(f"{rpad('点号', 10)}  {rpad('参考', 12)}  {rpad('实测', 12)}  {rpad('误差', 12)}")
            for pid, gv, sv, e in worst:
                print(f"{rpad(str(pid), 10)}  {rpad(f'{gv:g}', 12)}  "
                      f"{rpad(f'{sv:g}', 12)}  {rpad(f'{e:g}', 12)}")
        if args.hist:
            print("\n误差分布（单位：容差倍数；容差为 0 时按 1 LSB 分箱）：")
            unit = args.tol if args.tol > 0 else 1.0
            bins: dict[str, int] = {}
            for e in abs_err:
                k = int(e / unit)
                label = f"{k}L" if k < 4 else ">=4L"
                bins[label] = bins.get(label, 0) + 1
            for label in ("0L", "1L", "2L", "3L", ">=4L"):
                if label in bins:
                    bar = "#" * min(60, bins[label] * 60 // max(1, n))
                    print(f"  {label:>4} : {bins[label]:>7}  {bar}")

    if args.quiet and bad:
        for pid, gv, sv, e in worst:
            print(f"[FAIL] 点 {pid:g}: 参考 {gv:g} 实测 {sv:g} 误差 {e:g}", file=sys.stderr)

    if args.json:
        payload = {
            "status": status,
            "n": n,
            "tolerance": args.tol,
            "max_abs_err": max_err,
            "rms_err": rms,
            "bad_count": len(bad),
            "worst": [
                {"index": pid, "golden": gv, "got": sv, "err": e}
                for pid, gv, sv, e in worst
            ],
        }
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        if not args.quiet:
            print(f"JSON: {args.json}")

    if not args.quiet:
        print(f"\n{status}: {n - len(bad)}/{n} 点在容差内")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
