#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/make_v68_rtl.py —— 生成 v68「400 mVpp 单端正交 + 显示屏」专用 RTL 变体

背景
----
传感器输出改为 400 mVpp（单端、0 V 中心），AD9238 模块前端仍是方案 B：
R13 4.02k 短接、R15 1k 不焊（去 ÷5.02），AD8138 Rg 499Ω→120Ω（差分 4.16×）。
400 mVpp × 4.16 = 1.664 Vpp 差分 = 2 Vpp 满量程的 83.2%，对应 3408 个 ADC 码峰峰。

因此 v68 的默认数字增益必须回到 1.0：
  400 mVpp → 0.832 FS × 1.0 = 0.832 FS，落在默认幅值窗 [0.60, 1.20]；
  不削顶最大输入仍是 481 mVpp（0.832 × 481/400 ≈ 1.00 FS）。
若沿用 v67 的 1.5，400 mVpp 会到 1.248 FS，16bit 输出削顶并触发 amp_high。

v68 相对 v66 只改 3 处（增益保持 v66 的 32768 = 1.0）：
  1) enc_top.v : POLE_BITS 11 → 6      （64 电周期/机械圈）
  2) enc_top.v : RTL_BUILD_ID 0x000E → 0x0010
  3) reg_file.v: INTER0 2 → 32         （64 × 2×32 = 4096 A 沿/圈，2048 PPR）

本脚本不修改 rtl/ 下任何原文件，只把 rtl/*.v 与 rtl/eth/*.v 复制到
_synth_work_v68/rtl_v68/，在副本上做文本替换。显示版复用同一份副本，
外加 disp/*.v 与 constr/enc_top_disp.xdc。

用法
----
  python tools/make_v68_rtl.py
  （重复运行会先清空 _synth_work_v68/rtl_v68/ 再复制）
"""

import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "rtl"
DST_ROOT = ROOT / "_synth_work_v68"
DST = DST_ROOT / "rtl_v68"


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

    # ---- 1) enc_top.v ----
    p = DST / "enc_top.v"
    t = p.read_text(encoding="utf-8")

    t = sub_once(
        t,
        r"^(\s*)parameter integer POLE_BITS = 11,\s*$",
        r"\1parameter integer POLE_BITS = 6,   // v68：64 周期/转（400 mVpp 手搓传感器）",
        p.name, "POLE_BITS=11",
    )
    t = sub_once(
        t,
        r"^.*RTL_BUILD_ID\s*=\s*16'h000E;.*$",
        "    localparam [15:0] RTL_BUILD_ID = 16'h0010;   // v68：400 mVpp + 显示屏（增益保持 1.0）",
        p.name, "RTL_BUILD_ID=0x000E",
    )
    p.write_text(t, encoding="utf-8")

    # ---- 2) reg_file.v ----
    p = DST / "reg_file.v"
    t = p.read_text(encoding="utf-8")
    t = sub_once(
        t,
        r"^(\s*)r_inter0\s*<=\s*8'd2;.*$",
        r"\1r_inter0     <= 8'd32;          // v68：64 周期/转 × 2×32 = 4096 A 沿/圈（2048 PPR）",
        p.name, "r_inter0=2",
    )
    p.write_text(t, encoding="utf-8")

    # ---- 3) 自检 ----
    enc = (DST / "enc_top.v").read_text(encoding="utf-8")
    reg = (DST / "reg_file.v").read_text(encoding="utf-8")
    checks = [
        ("enc_top.v", "POLE_BITS = 11", False),
        ("enc_top.v", "POLE_BITS = 6", True),
        ("enc_top.v", "16'h000E", False),
        ("enc_top.v", "16'h0010", True),
        ("reg_file.v", "r_inter0     <= 8'd2;", False),
        ("reg_file.v", "r_inter0     <= 8'd32;", True),
        ("reg_file.v", "16'd49152", False),       # v68 不继承 v67 的 1.5
    ]
    for name, token, want in checks:
        text = enc if name == "enc_top.v" else reg
        got = token in text
        if got != want:
            die("%s: 自检失败，token %r 期望 %s 实际 %s" % (name, token, want, got))

    # 默认增益必须是 1.0：两处 r_gain_* 都是 32768
    gain_hits = len(re.findall(r"r_gain_[sc]\s*<=\s*16'd32768;", reg))
    if gain_hits != 2:
        die("reg_file.v: 期望 2 处 GAIN_S/GAIN_C=32768（1.0），实际 %d 处" % gain_hits)

    # ---- 4) 变体说明 ----
    info = DST_ROOT / "VARIANT_INFO.txt"
    info.write_text(
        "v68 400mVpp + display variant\n"
        "source git: %s\n"
        "generated: %s\n"
        "source RTL: %s (%d top-level + %d eth)\n"
        "patches:\n"
        "  enc_top.v  POLE_BITS 11 -> 6 (64 cycles/rev)\n"
        "  enc_top.v  RTL_BUILD_ID 0x000E -> 0x0010\n"
        "  reg_file.v INTER0 reset 2 -> 32 (64 cycles/rev x 2x32 = 4096 A edges/rev)\n"
        "  (GAIN_S/GAIN_C stays 32768 = 1.0: 400mVpp x 4.16 = 0.832 FS)\n"
        "build (production): tools/impl_check_v68.tcl -> _impl_v68/enc_top_v68.bit\n"
        "build (display)   : tools/impl_check_disp_v68.tcl -> _impl_disp_v68/enc_top_disp_v68.bit\n"
        % (git_head(), datetime.now().isoformat(timespec="seconds"),
           SRC, len(src_files), len(eth_files)),
        encoding="utf-8",
    )

    print("OK: %d top-level + %d eth files -> %s" % (len(src_files), len(eth_files), DST))
    print("    patches: POLE_BITS=6, RTL_BUILD_ID=0x0010, INTER0=32, GAIN_S/C=32768 (1.0)")
    print("    info: %s" % info)


if __name__ == "__main__":
    main()
