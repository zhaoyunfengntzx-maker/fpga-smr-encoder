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

【规模】单遍流式：内存只与 --top 和误差分箱数有关，与点数无关。
        实测 2^20 点全周扫描（1,048,576 行 × 2 文件，16 bit 角度码，注入 7 个 +5 错点）：
          新版 2.9 s / 峰值工作集 15.3 MB（含解释器本身约 14 MB）；
          同一组文件、同一判据，旧版"全读进 list 再排序"是 5.0 s / 550.1 MB。
          加 --hist --top 16 --json 后 3.2 s / 15.3 MB —— 内存不随点数涨。
        解析本身不是瓶颈（1M 行 re.split+float 约 1.1 s，加正则校验会翻到 1.9 s，
        所以这里用 float() 抛异常来判断表头，不用正则）。

【为什么要有这个脚本】
  "我看了一眼波形，差不多" 是本工程最常见的误判来源（见 skill/testbench-blindspot.md）。
  逐点比对时人眼只能看几十个点，而一个 12 bit 相位的象限折叠错误只在
  180° 附近表现成"跳变 1 个 LSB"，肉眼永远看不出；脚本能给出 max/RMS 与点号。
  本工程用同一口径把 6 参数标定后的 20.9839° 压到 0.0165°（1273×），
  靠的就是"每个点都算误差"而不是"抽几个点看看"。

【失效条件】
  1) 两边有乱序/丢点：必须先做"第 k 个输出 ↔ 第 k 个输入"的对齐，否则误差没有意义；
  2) 参考值本身带系统偏置：逐点比对会一致地通过，偏置看不出来——要另加均值/无偏置判据；
  3) 浮点且允许相对误差：本脚本按绝对差算，--tol 需自己换算成同一量纲；
  4) 流式统计只保留"每个误差分箱的计数"与"最坏 N 点"：
     要看全部分布请用 --hist，要逐点清单请自己导出——脚本不再把全部点存在内存里。
"""

from __future__ import annotations

import argparse
import heapq
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


def iter_rows(path: str):
    """逐行产出解析好的数值行；表头/注释/空行直接跳过。

    生成器而不是 list：100 万行的时候差别是"能不能跑"。
    解析用 float() + 异常判断，而不是先跑正则：正则每条边都要匹配 2 个字段，
    100 万行时比重排这些小堆操作还贵（实测见文件头的【规模】）。
    """
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = [p for p in re.split(r"[,\s]+", s) if p]
            if not parts:
                continue
            try:
                yield [float(p) for p in parts]
            except ValueError:
                continue  # 表头 / 注释


def pick(row: list[float], col: int) -> float:
    return row[col] if col >= 0 else row[len(row) + col]


class Stats:
    """单遍流式统计。

    旧版把所有点存成 list 再排序求最坏值：2^20 点（本工程黄金模型的扫描规模）
    光 list 就要几十 MB，还要再排一次序。这里改成"边读边算"：
    计数/平方和/最大值是 O(1)，最坏 N 点用大小为 N 的小顶堆，分箱是字典。
    """

    __slots__ = ("tol", "top", "hist", "n", "bad", "sum_sq", "max_err",
                 "bins", "worst_bad", "worst_all")

    def __init__(self, tol: float, top: int, hist: bool) -> None:
        self.tol = tol
        self.top = max(1, top)
        self.hist = hist
        self.n = 0
        self.bad = 0
        self.sum_sq = 0.0
        self.max_err = 0.0
        self.bins: dict[str, int] = {}
        self.worst_bad: list = []
        self.worst_all: list = []

    def feed(self, pid, gv: float, sv: float) -> None:
        e = sv - gv
        ae = abs(e)
        self.n += 1
        self.sum_sq += e * e
        if ae > self.max_err:
            self.max_err = ae
        item = None
        # 只有"比堆里最差的那个还差"才入堆：100 万点里通常只有几十点要进堆，
        # 每点都 heappush 会让流式版反而比"全读进 list 再排序"慢一倍（实测过）。
        if self.tol + 1e-12 < ae:
            self.bad += 1
            if len(self.worst_bad) < self.top or ae > self.worst_bad[0][0]:
                item = (ae, self.n, pid, gv, sv, e)
                heapq.heappush(self.worst_bad, item)
                if len(self.worst_bad) > self.top:
                    heapq.heappop(self.worst_bad)
        if len(self.worst_all) < self.top or ae > self.worst_all[0][0]:
            if item is None:
                item = (ae, self.n, pid, gv, sv, e)
            heapq.heappush(self.worst_all, item)
            if len(self.worst_all) > self.top:
                heapq.heappop(self.worst_all)
        if self.hist:
            unit = self.tol if self.tol > 0 else 1.0
            k = int(ae / unit)
            label = f"{k}L" if k < 4 else ">=4L"
            self.bins[label] = self.bins.get(label, 0) + 1

    def ordered(self, only_bad: bool):
        """按误差从大到小返回 (点号, 参考, 实测, 误差)。"""
        src = self.worst_bad if only_bad else self.worst_all
        return [t[2:] for t in sorted(src, key=lambda t: (-t[0], t[1]))]

    def rms(self) -> float:
        return math.sqrt(self.sum_sq / self.n) if self.n else 0.0


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
    ap.add_argument("--top", type=int, default=5,
                    help="打印最坏的 N 个点（默认 5；内存占用与 N 成正比，与点数无关）")
    ap.add_argument("--hist", action="store_true", help="打印误差分布直方图")
    ap.add_argument("--json", help="把结果写成 JSON")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    try:
        it_g = iter_rows(args.golden)
        it_s = iter_rows(args.got)
        g0 = next(it_g, None)
        s0 = next(it_s, None)
    except OSError as e:
        print(f"[ERROR] 读文件失败: {e}", file=sys.stderr)
        return 2

    for name, row, col in ((args.golden, g0, args.col_ref),
                           (args.got, s0, args.col_got)):
        if row is None:
            print(f"[ERROR] {name} 里没有任何数据行", file=sys.stderr)
            return 2
        width = len(row)
        if col != -1 and not (1 <= col <= width):
            print(f"[ERROR] {name} 只有 {width} 列，--col 指定了 {col}", file=sys.stderr)
            return 2
        if col == -1 and width < 1:
            print(f"[ERROR] {name} 没有数值列", file=sys.stderr)
            return 2

    ci_ref = args.col_ref - 1 if args.col_ref > 0 else -1
    ci_got = args.col_got - 1 if args.col_got > 0 else -1

    acc = Stats(tol=args.tol, top=args.top, hist=args.hist)
    g, s, k = g0, s0, 0
    while g is not None and s is not None:
        gv, sv = pick(g, ci_ref), pick(s, ci_got)
        # 行内第 1 列若看起来像点号（两边都有且相等），就把它当点号
        pid: float = k
        if len(g) >= 2 and len(s) >= 2 and g[0] == s[0]:
            pid = int(g[0]) if float(g[0]).is_integer() else g[0]
        acc.feed(pid, gv, sv)
        k += 1
        g = next(it_g, None)
        s = next(it_s, None)

    # 两边行数不等：把剩下的数清楚报出来，绝不静默截断
    extra_g = 0 if g is None else 1 + sum(1 for _ in it_g)
    extra_s = 0 if s is None else 1 + sum(1 for _ in it_s)
    if extra_g or extra_s:
        print(f"[WARN] 行数不等：参考 {acc.n + extra_g} 行，实测 {acc.n + extra_s} 行，"
              f"只比前 {acc.n} 行", file=sys.stderr)

    n = acc.n
    max_err = acc.max_err
    rms = acc.rms()
    passed = acc.bad == 0
    status = "PASS" if passed else "FAIL"
    # 有超差点就只展示超差点；全部通过时才展示"最坏的 N 个"供参考
    worst = acc.ordered(only_bad=not passed)

    if not args.quiet:
        print(f"参考: {args.golden}")
        print(f"实测: {args.got}")
        print(f"点数: {n}   容差: {args.tol:g}   max|err| = {max_err:g}   RMS = {rms:.6g}")
        if not passed:
            print(f"超差点数: {acc.bad} / {n}  ({100.0 * acc.bad / n:.2f}%)")
            print("\n最坏的点：")
            print(f"{rpad('点号', 10)}  {rpad('参考', 12)}  {rpad('实测', 12)}  {rpad('误差', 12)}")
            for pid, gv, sv, e in worst:
                print(f"{rpad(str(pid), 10)}  {rpad(f'{gv:g}', 12)}  "
                      f"{rpad(f'{sv:g}', 12)}  {rpad(f'{e:g}', 12)}")

    if args.hist:
        print("\n误差分布（单位：容差倍数；容差为 0 时按 1 LSB 分箱）：")
        for label in ("0L", "1L", "2L", "3L", ">=4L"):
            if label in acc.bins:
                cnt = acc.bins[label]
                bar = "#" * min(60, cnt * 60 // max(1, n))
                print(f"  {label:>4} : {cnt:>7}  {bar}")

    if args.quiet and not passed:
        for pid, gv, sv, e in worst:
            print(f"[FAIL] 点 {pid:g}: 参考 {gv:g} 实测 {sv:g} 误差 {e:g}", file=sys.stderr)

    if args.json:
        payload = {
            "status": status,
            "n": n,
            "tolerance": args.tol,
            "max_abs_err": max_err,
            "rms_err": rms,
            "bad_count": acc.bad,
            "worst": [
                {"index": pid, "golden": gv, "got": sv, "err": e}
                for pid, gv, sv, e in worst
            ],
        }
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        if not args.quiet:
            print(f"JSON: {args.json}")

    # -q 也要留一行判决：只剩退出码时，日志里看不出"红在哪、差多少"（P-16）。
    print(f"\n{status}: {n - acc.bad}/{n} 点在容差内（max|err|={max_err:g}，RMS={rms:g}）")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
