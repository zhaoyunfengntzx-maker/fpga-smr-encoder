#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/make_v69_rtl.py —— 生成 v69「真实转台 2048 PPR」专用 RTL 变体

背景
----
v68 为了配合 64 电周期/圈的手搓传感器，把 POLE_BITS 改成了 6、INTER0=32。
实际要驱动的信号源是**电机转台输出的正交 sin/cos，PPR = 2048**，
所以 POLE_BITS 必须回到源码默认的 11（2^11 = 2048 电周期/机械圈）。

v69 相对源码（rtl/）只改 2 处：
  1) enc_top.v : RTL_BUILD_ID 0x000E → 0x0011
  2) reg_file.v: INTER0 2 → 32        （2048 周期/转 × 2×32 = 131072 边沿/转 = 65536 A 沿/圈）

POLE_BITS 保持 11（2048 周期/转）；GAIN_S/GAIN_C 保持 32768（1.0）。
单圈/多圈位宽随之变成 ST=27 / MT=5（由 ST_BITS_L/MT_BITS_L 自动推导）。

本脚本不修改 rtl/ 下任何原文件，只把 rtl/*.v 与 rtl/eth/*.v 复制到
_synth_work_v69/rtl_v69/，在副本上做文本替换。

用法
----
  python tools/make_v69_rtl.py
"""

import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "rtl"
DST_ROOT = ROOT / "_synth_work_v69"
DST = DST_ROOT / "rtl_v69"


def die(msg: str) -> None:
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def sub_once(text: str, pattern: str, repl: str, filename: str, what: str) -> str:
    new, n = re.subn(pattern, repl, text, count=1, flags=re.MULTILINE)
    if n != 1:
        die("%s: 期望恰好 1 处 %s，实际 %d 处（pattern=%r）" % (filename, what, n, pattern))
    return new


def git_head() -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
    except Exception:
        return "unknown"


def main() -> None:
    if not SRC.is_dir():
        die("找不到 %s" % SRC)

    if DST.exists():
        shutil.rmtree(DST)
    (DST / "eth").mkdir(parents=True)

    src_files = sorted(SRC.glob("*.v"))
    eth_files = sorted((SRC / "eth").glob("*.v"))
    if not src_files:
        die("rtl/ 下没有 .v")
    for f in src_files:
        shutil.copy2(f, DST / f.name)
    for f in eth_files:
        shutil.copy2(f, DST / "eth" / f.name)

    # ---- 1) enc_top.v：只改 BUILD_ID，POLE_BITS 保持 11 ----
    p = DST / "enc_top.v"
    t = p.read_text(encoding="utf-8")
    t = sub_once(
        t,
        r"^.*RTL_BUILD_ID\s*=\s*16'h000E;.*$",
        "    localparam [15:0] RTL_BUILD_ID = 16'h0011;   // v69：真实转台 2048 PPR（POLE_BITS=11）",
        p.name, "RTL_BUILD_ID=0x000E",
    )
    p.write_text(t, encoding="utf-8")

    # ---- 2) reg_file.v：INTER0 = 32 ----
    p = DST / "reg_file.v"
    t = p.read_text(encoding="utf-8")
    t = sub_once(
        t,
        r"^(\s*)r_inter0\s*<=\s*8'd2;.*$",
        r"\1r_inter0     <= 8'd32;          // v69：2048 周期/转 × 2×32 = 131072 边沿/转（65536 A 沿/圈）",
        p.name, "r_inter0=2",
    )
    p.write_text(t, encoding="utf-8")

    # ---- 3) 自检 ----
    enc = (DST / "enc_top.v").read_text(encoding="utf-8")
    reg = (DST / "reg_file.v").read_text(encoding="utf-8")
    checks = [
        ("enc_top.v", "POLE_BITS = 11", True),      # 必须保持 11
        ("enc_top.v", "POLE_BITS = 6", False),
        ("enc_top.v", "16'h000E", False),
        ("enc_top.v", "16'h0011", True),
        ("reg_file.v", "r_inter0     <= 8'd2;", False),
        ("reg_file.v", "r_inter0     <= 8'd32;", True),
        ("reg_file.v", "16'd49152", False),          # 不继承 v67 的 1.5 增益
    ]
    for name, token, want in checks:
        text = enc if name == "enc_top.v" else reg
        got = token in text
        if got != want:
            die("%s: 自检失败，token %r 期望 %s 实际 %s" % (name, token, want, got))

    gain_hits = len(re.findall(r"r_gain_[sc]\s*<=\s*16'd32768;", reg))
    if gain_hits != 2:
        die("reg_file.v: 期望 2 处 GAIN_S/GAIN_C=32768（1.0），实际 %d 处" % gain_hits)

    # ST_BITS_L / MT_BITS_L 的推导必须给出 27 / 5
    m = re.search(r"ST_BITS_L\s*=\s*(\d+)", enc)
    if m and int(m.group(1)) != 27:
        die("enc_top.v: ST_BITS_L 期望 27（POLE_BITS=11, AW=16），实际 %s" % m.group(1))

    # ---- 4) 变体说明 ----
    info = DST_ROOT / "VARIANT_INFO.txt"
    info.write_text(
        "v69 2048 PPR (real turntable) variant\n"
        "source git: %s\n"
        "generated: %s\n"
        "source RTL: %s (%d top-level + %d eth)\n"
        "patches:\n"
        "  enc_top.v  RTL_BUILD_ID 0x000E -> 0x0011\n"
        "  reg_file.v INTER0 reset 2 -> 32\n"
        "  POLE_BITS stays 11 (2048 electrical cycles/rev), GAIN_S/C = 32768 (1.0)\n"
        "build (production): tools/impl_check_v69.tcl -> _impl_v69/enc_top_v69.bit\n"
        "build (display)   : tools/impl_check_disp_v69.tcl -> _impl_disp_v69/enc_top_disp_v69.bit\n"
        % (git_head(), datetime.now().isoformat(timespec="seconds"),
           SRC, len(src_files), len(eth_files)),
        encoding="utf-8",
    )

    print("OK: %d top-level + %d eth files -> %s" % (len(src_files), len(eth_files), DST))
    print("    patches: RTL_BUILD_ID=0x0011, INTER0=32, POLE_BITS=11 (2048 PPR), GAIN_S/C=32768")
    print("    info: %s" % info)


if __name__ == "__main__":
    main()
