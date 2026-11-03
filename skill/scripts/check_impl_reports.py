#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_impl_reports.py —— 把 Vivado 实现报告里的数字变成"通过/不通过"判决

【适用】任何 Vivado 工程，只要手上有一次完整实现后的四份文本报告：
        *_timing_summary*.rpt / *.rpt（含 Design Timing Summary）、
        *_utilization*.rpt、*_drc.rpt、*_check_timing.rpt。
        典型来源：report_utilization -file ... / report_timing_summary -file ... /
                  report_drc -file ... / check_timing -verbose -file ...

【用法】
    # 1) 最常见：指一个目录，按文件名自动找四份报告
    python check_impl_reports.py --dir _synth_work

    # 2) 文件名不规范时逐个指定
    python check_impl_reports.py --timing t.rpt --util u.rpt --drc d.rpt --check-timing c.rpt

    # 3) 加一条自己的判据：LUT 不得超过 70%，WNS 至少 +0.2 ns
    python check_impl_reports.py --dir _synth_work --min-wns 0.2 --max-util "Slice LUTs=70"

    # 4) 给 CI / 测试台用：输出机器可读 JSON
    python check_impl_reports.py --dir _synth_work --json impl_verdict.json -q

【退出码】0 = 所有判据通过；1 = 有判据不通过；2 = 报告缺失或解析不出
        （★ 2 和 1 必须分开：2 表示"工具没看见"，不能当成"设计通过"也不能当成"设计失败"）

【为什么要有这个脚本】
  人工看报告时，最危险的不是漏看，而是"看错一行"：把 TNS 当 WNS、把 Slice LUTs 的
  Used 列看成 Available 列、把 "Timing constraints are not met." 看成 met。
  本工程 v70 复盘里就出现过"引用了一个旧目录里的旧数字"（见 skill/pitfalls.md 第 17 条）。
  凡是能被脚本判的结论，就不该由人眼判。

【已知局限】只认 Vivado 11.x 风格的文本报告；表格列顺序变化或 CSV（.rpx）不支持。
               遇到解析失败一律退出码 2，不会"猜"。

【失效条件】
  1) 报告不是 Vivado 打的：列顺序被改过、导出成 HTML/CSV、或是别的脚本拼出来的"报告"；
  2) 资源口径不同：用的是 report_design_analysis 的层级资源、或 -cell 过滤后的子集；
  3) 判据阈值是抄来的、没和器件手册/板卡核对——此时它会**稳定地**给出错误判决，
     比没有脚本更危险（因为它看起来有权威）。阈值必须写清出处。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# ---------------------------------------------------------------- 通用工具


def read_text(path: str) -> str:
    """按 UTF-8 读，失败退 GBK（Vivado 在中文 Windows 上可能写 GBK）。"""
    with open(path, "rb") as f:
        raw = f.read()
    for enc in ("utf-8-sig", "gbk", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1", "replace")


def find_by_patterns(directory: str, patterns: list[str],
                     exclude: tuple[str, ...] = ()) -> str | None:
    """在目录里按正则找最新修改的那个文件（exclude 里的子串命中则跳过）。"""
    best, best_mtime = None, -1.0
    for name in os.listdir(directory):
        low = name.lower()
        if not low.endswith(".rpt"):
            continue
        if any(x in low for x in exclude):
            continue
        if any(re.search(p, low) for p in patterns):
            p = os.path.join(directory, name)
            m = os.path.getmtime(p)
            if m > best_mtime:
                best, best_mtime = p, m
    return best


# ---------------------------------------------------------------- 四类报告解析

TIMING_SENTENCE_OK = "all user specified timing constraints are met"
TIMING_SENTENCE_BAD = "timing constraints are not met"


def parse_timing(path: str) -> dict:
    """取 Design Timing Summary 的第一行数值 + 那句结论。"""
    text = read_text(path)
    lines = text.splitlines()
    out = {
        "file": path,
        "wns": None, "tns": None,
        "tns_failing": None, "tns_total": None,
        "whs": None, "ths": None,
        "met": None, "met_evidence": None,
        "line": None,
    }
    for i, line in enumerate(lines):
        if "Design Timing Summary" not in line:
            continue
        for j in range(i + 1, min(i + 12, len(lines))):
            s = lines[j].strip()
            if not s or not re.match(r"^-?\d", s):
                continue
            nums = re.findall(r"-?\d+\.\d+|-?\d+", s)
            if len(nums) >= 8:
                out["wns"] = float(nums[0])
                out["tns"] = float(nums[1])
                out["tns_failing"] = int(float(nums[2]))
                out["tns_total"] = int(float(nums[3]))
                out["whs"] = float(nums[4])
                out["ths"] = float(nums[5])
                out["line"] = j + 1
                break
        break

    for i, line in enumerate(lines):
        low = line.strip().lower().rstrip(".")
        if low.endswith(TIMING_SENTENCE_OK):
            out["met"], out["met_evidence"] = True, {"file": os.path.basename(path), "line": i + 1}
            break
        if low.endswith(TIMING_SENTENCE_BAD):
            out["met"], out["met_evidence"] = False, {"file": os.path.basename(path), "line": i + 1}
            break
    return out


UTIL_ALIASES = {
    "lut": ("Slice LUTs", "CLB LUTs"),
    "ff": ("Slice Registers", "CLB Registers"),
    "bram": ("Block RAM Tile", "RAMB36/FIFO*"),
    "dsp": ("DSPs", "DSP48E1", "DSP48E2"),
    "iob": ("Bonded IOB",),
    "bufg": ("BUFGCTRL",),
}


def parse_util(path: str) -> dict:
    """解析 utilization 报告里的 6 类资源行：Used / Available / Util%。"""
    text = read_text(path)
    rows: dict[str, dict] = {}
    pat = re.compile(
        r"^\|\s*([A-Za-z][A-Za-z0-9 _/\.\*]*?)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|"
    )
    found: list[dict] = []
    for i, line in enumerate(text.splitlines()):
        m = pat.match(line.strip())
        if not m:
            continue
        found.append({
            "name": m.group(1).strip(),
            "used": int(m.group(2)),
            "available": int(m.group(5)),
            "util_pct": float(m.group(6)),
            "line": i + 1,
            "file": path,
        })

    # 先按主名精确匹配（"Slice LUTs" 优先于 "Slice LUTs as Memory"、"RAMB36/FIFO*"
    # 不要抢走 "Block RAM Tile"），没匹配到的再用别名兜底
    for key, aliases in UTIL_ALIASES.items():
        for row in found:
            if row["name"] == aliases[0]:
                rows[key] = row
                break
    for key, aliases in UTIL_ALIASES.items():
        if key in rows:
            continue
        for row in found:
            if row["name"] in aliases:
                rows[key] = row
                break
    return {"file": path, "rows": rows}


DRC_ROW = re.compile(
    r"^\|\s*([A-Za-z]+-\d+)\s*\|\s*(Error|Critical Warning|Warning|Advisory)\s*\|\s*([^|]*?)\s*\|\s*(\d+)\s*\|"
)


def parse_drc(path: str) -> dict:
    text = read_text(path)
    by_sev: dict[str, int] = {}
    rules: list[dict] = []
    checks_found = None
    for i, line in enumerate(text.splitlines()):
        s = line.strip()
        m = re.match(r"^Checks found:\s*(\d+)", s)
        if m:
            checks_found = int(m.group(1))
        m = DRC_ROW.match(s)
        if m:
            sev = m.group(2)
            by_sev[sev] = by_sev.get(sev, 0) + int(m.group(4))
            rules.append({
                "rule": m.group(1), "severity": sev,
                "description": m.group(3), "checks": int(m.group(4)),
                "file": path, "line": i + 1,
            })
    return {
        "file": path,
        "errors": by_sev.get("Error", 0),
        "critical_warnings": by_sev.get("Critical Warning", 0),
        "warnings": by_sev.get("Warning", 0),
        "checks_found": checks_found,
        "rules": rules,
    }


def parse_check_timing(path: str) -> dict:
    """解析 check_timing 的 TOC：每类检查各有几处。"""
    text = read_text(path)
    counts: dict[str, int] = {}
    for i, line in enumerate(text.splitlines()):
        m = re.match(r"^\d+\.\s+checking\s+(\w+)\s+\((\d+)\)", line.strip())
        if m and m.group(1) not in counts:
            counts[m.group(1)] = int(m.group(2))
    return {"file": path, "counts": counts}


# ---------------------------------------------------------------- 判据框架


class Check:
    def __init__(self, name: str, op: str, value, limit, evidence: dict, note: str = ""):
        self.name = name
        self.op = op
        self.value = value
        self.limit = limit
        self.evidence = evidence
        self.note = note
        self.ok = self._judge()

    def _judge(self) -> bool:
        if self.value is None:
            return False
        try:
            if self.op == ">=":
                return self.value >= self.limit
            if self.op == "<=":
                return self.value <= self.limit
            if self.op == "==":
                return self.value == self.limit
        except TypeError:
            return False
        return False

    def as_dict(self) -> dict:
        return {
            "name": self.name, "op": self.op, "value": self.value,
            "limit": self.limit, "ok": self.ok, "note": self.note,
            "evidence": self.evidence,
        }


def ev(file: str | None, line: int | None) -> dict:
    return {"file": os.path.basename(file) if file else None, "line": line}


def _utf8_console() -> None:
    """管道重定向时统一按 UTF-8 输出（中文 Windows 默认写 GBK，CI 会乱码）。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def _w(s: str) -> int:
    """显示宽度：CJK 字符占 2 列，否则中文表头对不齐。"""
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s: str, width: int, right: bool = False) -> str:
    pad_n = max(0, width - _w(s))
    return (" " * pad_n + s) if right else (s + " " * pad_n)


# ---------------------------------------------------------------- 主流程


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(
        description="Vivado 实现报告的机器判决（时序 / 资源 / DRC / 约束完整性）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--dir", help="报告所在目录（自动按文件名找四份报告）")
    ap.add_argument("--timing"), ap.add_argument("--util")
    ap.add_argument("--drc"), ap.add_argument("--check-timing", dest="check_timing")
    ap.add_argument("--min-wns", type=float, default=0.0, help="WNS 下限 ns（默认 0.0）")
    ap.add_argument("--min-whs", type=float, default=0.0, help="WHS 下限 ns（默认 0.0）")
    ap.add_argument("--max-failing", type=int, default=0, help="允许的失败端点总数（默认 0）")
    ap.add_argument("--max-util", action="append", default=[],
                    metavar="RES=PCT", help="资源利用率上限，可重复，如 'Slice LUTs=80'")
    ap.add_argument("--max-drc-errors", type=int, default=0)
    ap.add_argument("--warn-no-input-delay", type=int, default=10,
                    help="no_input_delay 超过此数只发警告（默认 10，不判失败）")
    ap.add_argument("--json", help="把判决写成 JSON")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    timing = util = drc = ckt = None
    if args.dir:
        d = args.dir
        if not os.path.isdir(d):
            print(f"[ERROR] 目录不存在: {d}", file=sys.stderr)
            return 2
        args.timing = args.timing or find_by_patterns(
            d, [r"timing.*\.rpt$", r".*timing.*\.rpt$"], exclude=("check_timing",))
        args.util = args.util or find_by_patterns(d, [r"util.*\.rpt$"])
        args.drc = args.drc or find_by_patterns(d, [r"drc.*\.rpt$"])
        args.check_timing = args.check_timing or find_by_patterns(d, [r"check_timing.*\.rpt$"])

    missing = []
    if not args.timing:
        missing.append("timing")
    if not args.util:
        missing.append("util")
    if missing:
        print(f"[ERROR] 缺少报告: {', '.join(missing)}（用 --dir 或逐个 --timing/--util 指定）",
              file=sys.stderr)
        return 2

    timing = parse_timing(args.timing)
    util = parse_util(args.util)
    if args.drc:
        drc = parse_drc(args.drc)
    if args.check_timing:
        ckt = parse_check_timing(args.check_timing)

    checks: list[Check] = []
    warnings: list[str] = []

    # 时序
    if timing["wns"] is None:
        print(f"[ERROR] 在 {args.timing} 里找不到 Design Timing Summary 数值行", file=sys.stderr)
        return 2
    checks.append(Check("WNS(ns)", ">=", timing["wns"], args.min_wns,
                        ev(timing["file"], timing["line"])))
    checks.append(Check("TNS failing endpoints", "<=", timing["tns_failing"], args.max_failing,
                        ev(timing["file"], timing["line"])))
    checks.append(Check("WHS(ns)", ">=", timing["whs"], args.min_whs,
                        ev(timing["file"], timing["line"])))
    if timing["met"] is None:
        print(f"[ERROR] {args.timing} 里既没有 met 也没有 not met 的结论句；"
              f"这份报告可能不完整（Vivado 只有在 route 完成后才写这句）", file=sys.stderr)
        return 2
    checks.append(Check("timing constraints met", "==", 1 if timing["met"] else 0, 1,
                        timing["met_evidence"] or ev(timing["file"], None)))

    # 资源
    wanted = {"Slice LUTs": "lut", "Slice Registers": "ff", "Block RAM Tile": "bram",
              "DSPs": "dsp"}
    limits: dict[str, float] = {}
    # 允许 --max-util 里写报告中的名字，也允许写 LUT/FF/BRAM/DSP 简称
    short_alias = {"LUT": "Slice LUTs", "FF": "Slice Registers",
                   "BRAM": "Block RAM Tile", "DSP": "DSPs"}
    for spec in args.max_util:
        if "=" not in spec:
            print(f"[ERROR] --max-util 需要 RES=PCT 形式: {spec}", file=sys.stderr)
            return 2
        k, v = spec.split("=", 1)
        k = short_alias.get(k.strip().upper(), k.strip())
        limits[k] = float(v)
    for key, label in wanted.items():
        row = util["rows"].get(wanted[key])
        if not row:
            warnings.append(f"utilization 报告里没找到 {key} 行")
            continue
        limit = limits.get(key, 90.0)
        checks.append(Check(f"{label} util%", "<=", row["util_pct"], limit,
                            ev(row["file"], row["line"]),
                            note=f"used {row['used']}/{row['available']}"))
    for extra_name, limit in limits.items():
        if extra_name in wanted:
            continue
        hit = [r for r in util["rows"].values() if r["name"] == extra_name]
        if not hit:
            warnings.append(f"utilization 报告里没找到你要求的 {extra_name} 行")
            continue
        r = hit[0]
        checks.append(Check(f"{extra_name} util%", "<=", r["util_pct"], limit,
                            ev(r["file"], r["line"]),
                            note=f"used {r['used']}/{r['available']}"))

    # DRC
    if drc is not None:
        checks.append(Check("DRC errors", "<=", drc["errors"], args.max_drc_errors,
                            ev(drc["file"], None)))
        if drc["critical_warnings"]:
            warnings.append(f"DRC 有 {drc['critical_warnings']} 条 Critical Warning")

    # 约束完整性（不是失败判据，但缺口要先看见）
    if ckt is not None:
        nid = ckt["counts"].get("no_input_delay", 0)
        nod = ckt["counts"].get("no_output_delay", 0)
        noc = ckt["counts"].get("no_clock", 0)
        if noc:
            checks.append(Check("no_clock endpoints", "==", noc, 0, ev(ckt["file"], None),
                                note="有寄存器没有时钟：实现结果不可信"))
        if nid > args.warn_no_input_delay:
            warnings.append(f"no_input_delay = {nid}（> {args.warn_no_input_delay}）："
                            f"多半是异步输入没加 set_false_path；见 skill/adc-source-sync-constraints.md")
        if nod:
            warnings.append(f"no_output_delay = {nod}：输出没有 set_output_delay，"
                            f"下游建立/保持关系未建模")

    passed = all(c.ok for c in checks)
    status = "PASS" if passed else "FAIL"

    if not args.quiet:
        print(f"报告目录: {args.dir or os.path.dirname(args.timing)}")
        print(pad("判据", 26) + pad("实测", 10, right=True) + "  "
              + pad("要求", 12) + pad("结果", 6) + "证据")
        print("-" * 78)
        for c in checks:
            e = c.evidence
            print(pad(c.name, 26) + pad(str(c.value), 10, right=True) + "  "
                  + pad(f"{c.op} {c.limit}", 12) + pad("ok" if c.ok else "FAIL", 6)
                  + f"{e['file']}:{e['line'] or '-'}"
                  + (f"  [{c.note}]" if c.note else ""))
        print("-" * 78)
    for w in warnings:
        print(f"[WARN] {w}")
    if not args.quiet:
        print(f"\n{status}: {sum(c.ok for c in checks)}/{len(checks)} 判据通过")

    if args.json:
        payload = {
            "status": status,
            "checks": [c.as_dict() for c in checks],
            "warnings": warnings,
            "timing": timing,
            "resources": util["rows"],
            "drc": drc,
            "check_timing": ckt,
        }
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        if not args.quiet:
            print(f"JSON: {args.json}")

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
