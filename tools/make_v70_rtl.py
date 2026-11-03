#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/make_v70_rtl.py —— v70：修好位置累加（pole_counter 增量展开计数）

相对源码 rtl/ 只改 2 处：
  1) enc_top.v : RTL_BUILD_ID 0x000E → 0x0015
  2) reg_file.v: INTER0 复位值 2 → 32（2048 PPR × 2×32 = 131072 边沿/转）
POLE_BITS 保持 11；pole_counter.v 的修复在 rtl/ 源码里（v70 直接继承）。
"""
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "rtl"
DST_ROOT = ROOT / "_synth_work_v70"
DST = DST_ROOT / "rtl_v70"


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def sub_once(text, pattern, repl, filename, what):
    new, n = re.subn(pattern, repl, text, count=1, flags=re.MULTILINE)
    if n != 1:
        die("%s: 期望恰好 1 处 %s，实际 %d 处" % (filename, what, n))
    return new


def git_head():
    try:
        return subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                                       stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return "unknown"


def main():
    if DST.exists():
        shutil.rmtree(DST)
    (DST / "eth").mkdir(parents=True)
    src_files = sorted(SRC.glob("*.v"))
    eth_files = sorted((SRC / "eth").glob("*.v"))
    for f in src_files:
        shutil.copy2(f, DST / f.name)
    for f in eth_files:
        shutil.copy2(f, DST / "eth" / f.name)

    p = DST / "enc_top.v"
    t = p.read_text(encoding="utf-8")
    if "16'h000E" in t:
        t = sub_once(t, r"^.*RTL_BUILD_ID\s*=\s*16'h000E;.*$",
                     "    localparam [15:0] RTL_BUILD_ID = 16'h0015;   // v70：位置累加修复 + 2048 PPR",
                     p.name, "RTL_BUILD_ID=0x000E")
    elif "16'h0015" not in t:
        die("%s: 找不到 RTL_BUILD_ID（既不是 0x000E 也不是 0x0015）" % p.name)
    p.write_text(t, encoding="utf-8")

    p = DST / "reg_file.v"
    t = p.read_text(encoding="utf-8")
    if "8'd2;" in t and "r_inter0" in t:
        try:
            t = sub_once(t, r"^(\s*)r_inter0\s*<=\s*8'd2;.*$",
                         r"\1r_inter0     <= 8'd32;          // 2048 周期/转 × 2×32 = 131072 边沿/转",
                         p.name, "r_inter0=2")
        except SystemExit:
            pass  # 已经是 32（源码已回填 v70 默认值）时不算错
    p.write_text(t, encoding="utf-8")

    enc = (DST / "enc_top.v").read_text(encoding="utf-8")
    reg = (DST / "reg_file.v").read_text(encoding="utf-8")
    pol = (DST / "pole_counter.v").read_text(encoding="utf-8")
    checks = [
        ("enc_top.v", "POLE_BITS = 11", True),
        ("enc_top.v", "POLE_BITS = 6", False),
        ("enc_top.v", "16'h0015", True),
        ("reg_file.v", "r_inter0     <= 8'd32;", True),
        ("pole_counter.v", "phase_acc", True),
        ("pole_counter.v", "wire wrap_p_raw = acc_pos;", True),
    ]
    for name, token, want in checks:
        text = {"enc_top.v": enc, "reg_file.v": reg, "pole_counter.v": pol}[name]
        if (token in text) != want:
            die("%s: 自检失败，token %r 期望 %s" % (name, token, want))

    info = DST_ROOT / "VARIANT_INFO.txt"
    info.write_text(
        "v70: position-accumulator fix + 2048 PPR\n"
        "source git: %s\n generated: %s\n source RTL: %s (%d + %d)\n"
        "patches:\n  enc_top.v RTL_BUILD_ID 0x000E -> 0x0015\n  reg_file.v INTER0 2 -> 32\n"
        "  pole_counter.v: incremental unwrap counter (phase_acc) replaces >=270deg step test\n"
        % (git_head(), datetime.now().isoformat(timespec="seconds"), SRC, len(src_files), len(eth_files)),
        encoding="utf-8")
    print("OK: %d top-level + %d eth -> %s" % (len(src_files), len(eth_files), DST))


if __name__ == "__main__":
    main()
