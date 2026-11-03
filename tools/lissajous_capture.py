#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""李萨如「校前 / 校后」一次拍完（对应 deliverables/photo_shot_list.md  D.2 第 1-6 项 / P1-1）

一条命令完成：校前抓图 →（可选）触发板上"一键标定" → 等几秒 → 校后抓图 → 汇总。

  E:\\Anaconda\\python.exe tools\\lissajous_capture.py --port COM6

产物：
  deliverables/figures/lissajous_before.png / _after.png
  deliverables/data/lissajous_before.csv   / _after.csv
  deliverables/data/lissajous_summary.csv  （半径 / 圆度 RMS / 状态位 前后对照）

⚠ 标定必须在「频率阶梯」(D.3) **之前**做——标定会改板上系数。
⚠ `uart_scope.py` 的实时窗口要装下一整圈需要 f_in ≥ 约 48.8 kHz；1 kHz 下请看 `--png`
   累积散点（或临时把 AFG 升到 50 kHz 拍完再改回 1 kHz）。
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from freq_ladder import parse_scope, run  # noqa: E402  （复用解析与 UTF-8 子进程封装）

PY = sys.executable


def capture(tag: str, port: str, seconds: float, fig_dir: str, data_dir: str) -> dict:
    png = os.path.join(fig_dir, "lissajous_%s.png" % tag)
    csvp = os.path.join(data_dir, "lissajous_%s.csv" % tag)
    text = run([PY, os.path.join(HERE, "uart_scope.py"), "--port", port,
                "--seconds", str(seconds), "--png", png, "--csv", csvp])
    info = parse_scope(text)
    if not info["radius_mean"]:
        info["status"] = info["status"] or "NO-DATA(检查 COM 口/板子是否上电)"
    info["png"] = os.path.relpath(png, ROOT).replace("\\", "/")
    info["csv"] = os.path.relpath(csvp, ROOT).replace("\\", "/")
    return info


def read_reg(port: str, addr: str) -> str:
    text = run([PY, os.path.join(HERE, "uart_spi.py"), "--port", port, "read", addr])
    for line in text.splitlines():
        if addr.lower() in line.lower() and "0x" in line:
            return line.strip()
    return text.strip().splitlines()[-1] if text.strip() else ""


def resolve_data_dir(raw: str) -> tuple:
    """把 --data 解析成「目录」。★ 2026-10-13 修复：--data 传成 .csv 文件名时，
    旧代码会静默 makedirs 出一个同名**目录**（summary 与逐点 CSV 全被塞进这个伪目录）。
    现在改为退回该路径的父目录并给出显式告警。"""
    p = os.path.join(ROOT, raw)
    looks_like_file = p.lower().endswith((".csv", ".json", ".txt"))
    if looks_like_file or (os.path.exists(p) and os.path.isfile(p)):
        parent = os.path.dirname(p)
        print("⚠ --data 收到的是文件路径而非目录：%s" % raw)
        print("  ⇒ 已自动改用其父目录 %s（逐点 CSV 与 lissajous_summary.csv 都写在这里）"
              % os.path.relpath(parent, ROOT))
        return parent
    return p


def main() -> int:
    ap = argparse.ArgumentParser(description="李萨如校前/校后自动采集（photo_shot_list D.2）")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--figures", default=os.path.join("deliverables", "figures"))
    ap.add_argument("--data", default=os.path.join("deliverables", "data"),
                    help="**目录**（不是文件名）：逐点 CSV 与 lissajous_summary.csv 都写在这里")
    ap.add_argument("--no-calib", action="store_true", help="只抓校前一张，不触发标定")
    ap.add_argument("--calib-reg", default="0x0502")
    ap.add_argument("--calib-value", default="0x0001")
    ap.add_argument("--settle", type=float, default=3.0, help="标定后等待秒数")
    args = ap.parse_args()

    fig_dir = os.path.join(ROOT, args.figures)
    data_dir = resolve_data_dir(args.data)
    os.makedirs(fig_dir, exist_ok=True)
    os.makedirs(data_dir, exist_ok=True)
    ts = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("== 李萨如采集开始 %s（端口 %s）==" % (ts, args.port))

    print("\n[1/3] 校前：抓 %.1f s ..." % args.seconds)
    before = capture("before", args.port, args.seconds, fig_dir, data_dir)
    print("      半径 mean=%s 圆度 RMS=%s%% 状态=%s"
          % (before["radius_mean"] or "?", before["roundness_rms_pct"] or "?", before["status"] or "?"))

    calib_note = "skipped(--no-calib)"
    after = {}
    if not args.no_calib:
        print("\n[2/3] 触发一键标定：write %s = %s（也可在板上按 KEY0/W9）" % (args.calib_reg, args.calib_value))
        wtext = run([PY, os.path.join(HERE, "uart_spi.py"), "--port", args.port,
                     "write", args.calib_reg, args.calib_value])
        calib_note = "write %s=%s" % (args.calib_reg, args.calib_value)
        if "FAIL" in wtext.upper() or "TIMEOUT" in wtext.upper():
            calib_note += " (可能未确认，按板上 KEY0 再补一次)"
        time.sleep(max(args.settle, 0.0))
        print("      回读 %s : %s" % (args.calib_reg, read_reg(args.port, args.calib_reg)))
        print("\n[3/3] 校后：抓 %.1f s ..." % args.seconds)
        after = capture("after", args.port, args.seconds, fig_dir, data_dir)
        print("      半径 mean=%s 圆度 RMS=%s%% 状态=%s"
              % (after["radius_mean"] or "?", after["roundness_rms_pct"] or "?", after["status"] or "?"))

    summary = os.path.join(data_dir, "lissajous_summary.csv")
    new_file = not os.path.exists(summary)
    fields = ["ts", "stage", "radius_mean", "radius_min", "radius_max", "roundness_rms_pct",
              "status", "frames", "crc_err", "png", "csv", "note"]
    with open(summary, "a", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        if new_file:
            w.writeheader()
        for stage, info in (("before", before), ("after", after)):
            if not info:
                continue
            w.writerow({"ts": ts, "stage": stage, "note": calib_note if stage == "after" else "",
                        **{k: info.get(k, "") for k in fields if k not in ("ts", "stage", "note")}})

    print("\n== 汇总已追加：%s ==" % os.path.relpath(summary, ROOT))
    if after:
        try:
            b, a = float(before["roundness_rms_pct"] or 0), float(after["roundness_rms_pct"] or 0)
            print("   圆度 RMS：%.3f%% → %.3f%%（越小越圆）" % (b, a))
        except ValueError:
            pass
    print("   图：%s / %s" % (before["png"], after["png"] if after else "(未拍)"))
    print("   ⚠ 视频第 3 段要求「全程屏幕录制、不许快进」——请在开始前按录制。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
