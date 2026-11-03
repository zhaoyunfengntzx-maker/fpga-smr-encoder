#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/make_v71_rtl.py —— v71：Z 索引脉冲修复

相对源码 rtl/ 只改 1 处：
  1) enc_top.v : RTL_BUILD_ID 0x000E → 0x0016
其余修复（Z 取窗改为绝对角度过零 + abz_gen 跨零挂起/双向判据 + clr_on_z=0）
都在 rtl/ 源码里，v71 直接继承。POLE_BITS 保持 11，INTER0 保持 32。
"""
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "rtl"
DST_ROOT = ROOT / "_synth_work_v71"
DST = DST_ROOT / "rtl_v71"


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
    if "16'h0015" in t:
        t = sub_once(t, r"^.*RTL_BUILD_ID\s*=\s*16'h0015;.*$",
                     "    localparam [15:0] RTL_BUILD_ID = 16'h0016;   // v71: Z index pulse fix",
                     p.name, "RTL_BUILD_ID=0x0015")
    elif "16'h0016" not in t:
        die("%s: 找不到 RTL_BUILD_ID（既不是 0x0015 也不是 0x0016）" % p.name)
    p.write_text(t, encoding="utf-8")

    enc = (DST / "enc_top.v").read_text(encoding="utf-8")
    abz = (DST / "abz_gen.v").read_text(encoding="utf-8")
    pol = (DST / "pole_counter.v").read_text(encoding="utf-8")
    reg = (DST / "reg_file.v").read_text(encoding="utf-8")
    checks = [
        ("enc_top.v", "POLE_BITS = 11", True),
        ("enc_top.v", "POLE_BITS = 6", False),
        ("enc_top.v", "16'h0016", True),
        ("enc_top.v", "wire ang_wrap_f = filt_valid", True),
        ("enc_top.v", "clr_on_z     (1'b0)", True),
        ("abz_gen.v", "z_pend_ok", True),
        ("abz_gen.v", "z_rev", True),
        ("pole_counter.v", "phase_acc", True),
        ("reg_file.v", "r_inter0     <= 8'd32;", True),
    ]
    for name, token, want in checks:
        text = {"enc_top.v": enc, "abz_gen.v": abz, "pole_counter.v": pol, "reg_file.v": reg}[name]
        if (token in text) != want:
            die("%s: 自检失败，token %r 期望 %s" % (name, token, want))

    info = DST_ROOT / "VARIANT_INFO.txt"
    info.write_text(
        "v71: Z index pulse fix (absolute-angle rev window + crossing latch) + 2048 PPR\n"
        "source git: %s\n generated: %s\n source RTL: %s (%d + %d)\n"
        "patches:\n  enc_top.v RTL_BUILD_ID 0x000E -> 0x0016\n"
        "  inherited fixes: enc_top.v z_window from absolute angle wrap (7/8..1/8) + free-run rev_cnt;\n"
        "                   abz_gen.v persistent crossing latch (r_pend_ttl) + direction-aware edge;\n"
        "                   enc_top.v clr_on_z 1 -> 0\n"
        % (git_head(), datetime.now().isoformat(timespec="seconds"), SRC, len(src_files), len(eth_files)),
        encoding="utf-8")
    print("OK: %d top-level + %d eth -> %s" % (len(src_files), len(eth_files), DST))


if __name__ == "__main__":
    main()
