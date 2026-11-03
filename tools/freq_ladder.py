#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""频率阶梯自动采集（对应 deliverables/photo_shot_list.md  D.3）

操作者只需要改 AFG 频率并在提示处回车，其余自动完成：

  1. tools/uart_scope.py --seconds N --png <figures>/freq_<f>.png --csv <data>/freq_<f>.csv
     解析它的 stdout 得到：校正后半径 mean / 圆度 RMS / 状态位
  2. （可选 --with-diag）tools/diag_counters.py --seconds N，把尾部原文记进 note
  3. （可选 --ila）tools/run_vivado.ps1 -Tcl tools/ila_capture.tcl（ILA_MODE=stage1）
     再 tools/ila_report.py <csv> 提取 "恒定滞后 ... deg" —— 供报告 6.3 表用

汇总逐点追加到 <data>/freq_ladder_summary.csv（每点一行），同时打印一张表。

用法
----
  E:\\Anaconda\\python.exe tools\\freq_ladder.py --port COM6 ^
      --freqs 1k,10k,50k,100k,200k,500k --out deliverables\\data --figures deliverables\\figures

  带 ILA 滞后（需要放宽权限运行，因为要下位流）：
      ... --ila --ila-bit _synth_work/enc_top_ila.bit

纯解析自检（不接硬件，用于验证正则）：
  E:\\Anaconda\\python.exe tools\\freq_ladder.py --parse-only _synth_work\\selftest_out.txt
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = sys.executable

# ---- 从 uart_scope.py / ila_report.py 的 stdout 里抓数 ----
RE_RADIUS = re.compile(r"校正后半径\s*r\s*:\s*mean\s+([0-9.]+)\s+min\s+([0-9.]+)\s+max\s+([0-9.]+)")
RE_ROUND = re.compile(r"圆度偏差\(RMS\)\s*:\s*([0-9.]+)\s*%")
RE_STATUS_TRIG = re.compile(r"状态位触发次数\s*:\s*(.+)")
RE_STATUS_OK = re.compile(r"状态位\s*:\s*全部正常")
RE_LAG = re.compile(r"恒定滞后[\s\S]{0,400}?=\s*([+-]?[0-9.]+)\s*deg")
RE_FRAMES = re.compile(r"有效帧数\s*:\s*(\d+)")
RE_CRCERR = re.compile(r"XOR 校验失败\s*:\s*(\d+)")


def run(cmd: list[str], timeout: int = 900, env: dict | None = None) -> str:
    """跑子进程并把 stdout+stderr 一起按 UTF-8 解码。

    ★ 必须同时强制子进程用 UTF-8 输出（PYTHONIOENCODING/PYTHONUTF8）：
      Windows 下 Python 写管道时默认用 ANSI 代码页（GBK），父进程按 UTF-8 解会乱码。
    """
    print("    $ " + " ".join(cmd))
    child_env = dict(os.environ)
    child_env.setdefault("PYTHONIOENCODING", "utf-8")
    child_env.setdefault("PYTHONUTF8", "1")
    if env:
        child_env.update(env)
    try:
        p = subprocess.run(
            cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            encoding="utf-8", errors="replace", timeout=timeout, env=child_env,
        )
        return p.stdout or ""
    except subprocess.TimeoutExpired:
        return "[TIMEOUT] " + " ".join(cmd)
    except Exception as exc:  # noqa: BLE001
        return "[FAILED] %s: %s" % (" ".join(cmd), exc)


def parse_scope(text: str) -> dict:
    """从 uart_scope.py 的输出里取关键指标；取不到的字段留空字符串。"""
    out = {"radius_mean": "", "radius_min": "", "radius_max": "",
           "roundness_rms_pct": "", "status": "", "frames": "", "crc_err": ""}
    m = RE_RADIUS.search(text)
    if m:
        out["radius_mean"], out["radius_min"], out["radius_max"] = m.group(1), m.group(2), m.group(3)
    m = RE_ROUND.search(text)
    if m:
        out["roundness_rms_pct"] = m.group(1)
    m = RE_STATUS_TRIG.search(text)
    if m:
        out["status"] = m.group(1).strip()
    elif RE_STATUS_OK.search(text):
        out["status"] = "OK(no-alarm)"
    m = RE_FRAMES.search(text)
    if m:
        out["frames"] = m.group(1)
    m = RE_CRCERR.search(text)
    if m:
        out["crc_err"] = m.group(1)
    return out


def parse_lag(text: str) -> str:
    m = RE_LAG.search(text)
    return m.group(1) if m else ""


def tail_lines(text: str, n: int = 3) -> str:
    lines = [ln.strip() for ln in text.strip().splitlines() if ln.strip()]
    return " | ".join(lines[-n:])[:300]


def main() -> int:
    ap = argparse.ArgumentParser(description="频率阶梯自动采集（photo_shot_list D.3）")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--freqs", default="1k,10k,50k,100k,200k,500k",
                    help="逗号分隔的频率标签，用于文件名；顺序即采集顺序")
    ap.add_argument("--seconds", type=float, default=5.0, help="每个频点 uart_scope 采样秒数")
    ap.add_argument("--out", default=os.path.join("deliverables", "data"))
    ap.add_argument("--figures", default=os.path.join("deliverables", "figures"))
    ap.add_argument("--summary", default="", help="汇总 CSV 路径（默认 <out>/freq_ladder_summary.csv）")
    ap.add_argument("--with-diag", action="store_true", help="每点顺带跑 diag_counters.py")
    ap.add_argument("--ila", action="store_true", help="每点顺带抓一窗 ILA 并提取恒定滞后（需放宽权限）")
    ap.add_argument("--ila-bit", default="_synth_work/enc_top_ila.bit")
    ap.add_argument("--ila-mode", default="stage1", choices=["stage1", "stage2", "capture", "restore"])
    ap.add_argument("--no-wait", action="store_true", help="不等待回车（无人值守；需先设好频率）")
    ap.add_argument("--parse-only", default="", help="只解析一个已保存的 stdout 文件，不接硬件")
    args = ap.parse_args()

    if args.parse_only:
        with open(args.parse_only, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        info = parse_scope(text)
        print("解析 %s" % args.parse_only)
        for k, v in info.items():
            print("  %-18s = %s" % (k, v))
        print("  %-18s = %s" % ("lag_deg", parse_lag(text) or "(未出现)"))
        return 0

    out_dir = os.path.join(ROOT, args.out)
    fig_dir = os.path.join(ROOT, args.figures)
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(fig_dir, exist_ok=True)
    summary = args.summary or os.path.join(out_dir, "freq_ladder_summary.csv")
    if not os.path.isabs(summary):
        summary = os.path.join(ROOT, summary)

    freqs = [f.strip() for f in args.freqs.split(",") if f.strip()]
    fields = ["freq", "radius_mean", "radius_min", "radius_max", "roundness_rms_pct",
              "status", "frames", "crc_err", "lag_deg", "ts", "csv", "png", "note"]
    new_file = not os.path.exists(summary)
    rows = []

    for f in freqs:
        print("\n" + "=" * 72)
        print("频点 %s ：请把 AFG 频率设为 %s Hz（幅度保持 8.03 Vpp），然后回车" % (f, f))
        print("=" * 72)
        if not args.no_wait:
            try:
                input("  回车继续 > ")
            except EOFError:
                pass
        ts = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        csv_path = os.path.join(out_dir, "freq_%s.csv" % f)
        png_path = os.path.join(fig_dir, "freq_%s.png" % f)
        note_parts = []

        text = run([PY, os.path.join(HERE, "uart_scope.py"), "--port", args.port,
                    "--seconds", str(args.seconds), "--csv", csv_path, "--png", png_path])
        info = parse_scope(text)
        if not info["radius_mean"]:
            note_parts.append("SCOPE-NO-DATA: " + tail_lines(text, 2))

        if args.with_diag:
            dtext = run([PY, os.path.join(HERE, "diag_counters.py"), "--port", args.port,
                         "--seconds", str(max(args.seconds, 5.0))])
            note_parts.append("diag: " + tail_lines(dtext, 3))

        lag = ""
        if args.ila:
            ila_csv = os.path.join(ROOT, "_synth_work", "ila_freq_%s.csv" % f)
            ila_log = os.path.join(ROOT, "_synth_work", "ila_freq_%s.log" % f)
            env = dict(os.environ)
            env.update({
                "ILA_MODE": args.ila_mode,
                "ILA_BIT": args.ila_bit,
                "ILA_CSV": ila_csv,
                "ILA_WAIT": env.get("ILA_WAIT", "60000"),
            })
            itext = run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                         "-File", os.path.join(HERE, "run_vivado.ps1"),
                         "-Tcl", "tools\\ila_capture.tcl",
                         "-LogFile", os.path.relpath(ila_log, ROOT), "-Tail", "30"],
                        timeout=1800, env=env)
            if "ILACAP DONE" not in itext:
                note_parts.append("ILA-NO-DONE: " + tail_lines(itext, 2))
            rtext = run([PY, os.path.join(HERE, "ila_report.py"), ila_csv])
            lag = parse_lag(rtext)
            if not lag:
                note_parts.append("LAG-NOT-FOUND: " + tail_lines(rtext, 1))

        row = {"freq": f, **info, "lag_deg": lag, "ts": ts,
               "csv": os.path.relpath(csv_path, ROOT).replace("\\", "/"),
               "png": os.path.relpath(png_path, ROOT).replace("\\", "/"),
               "note": " ; ".join(note_parts)}
        rows.append(row)
        with open(summary, "a", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=fields)
            if new_file:
                w.writeheader()
                new_file = False
            w.writerow({k: row.get(k, "") for k in fields})
        print("  -> 半径 mean=%s rms=%s%% 状态=%s 滞后=%s"
              % (row["radius_mean"] or "?", row["roundness_rms_pct"] or "?", row["status"] or "?", lag or "-"))

    print("\n" + "=" * 72)
    print("汇总（已追加到 %s）" % os.path.relpath(summary, ROOT))
    print("%-6s %-12s %-10s %-28s %-10s" % ("freq", "radius", "rms%", "status", "lag_deg"))
    for r in rows:
        print("%-6s %-12s %-10s %-28s %-10s" % (r["freq"], r["radius_mean"], r["roundness_rms_pct"],
                                                r["status"][:28], r["lag_deg"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
