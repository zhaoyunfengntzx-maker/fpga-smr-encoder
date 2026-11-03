#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/make_lowsig_rtl.py —— 生成 v67「小信号传感器」专用 RTL 变体

背景
----
手搓传感器输出 200–300 mVpp 正交 sin/cos；AD9238 模块前端已按方案 B 改造：
  R13 4.02k 短接、R15 1k 不焊（去 ÷5.02），AD8138 Rg 499Ω→120Ω（差分 4.16×）。
因此 ADC 看到的差分幅度 = 200–300 mVpp × 4.16 = 0.83–1.25 Vpp
（2 Vpp 满量程的 41.6%–62.5%），而 v62/v66 默认数字增益 1.0 时
amp_monitor 判为 amp_low（门限 0.60 FS）⇒ lock_sm 进不了 TRACK。

本脚本不修改 rtl/ 下任何原文件，而是把 rtl/*.v 与 rtl/eth/*.v 复制到
_synth_work_lowsig/rtl_lowsig/，只在副本上做 4 处文本替换：

  1) enc_top.v : POLE_BITS 11 → 6
     64 周期/转（用户 2026-10-29 确认）；
     机械角取 pos_full[21:6]，Z 每 64 个电周期一个。
  2) enc_top.v : RTL_BUILD_ID 0x000E → 0x000F（独立构建号，主机可区分）
  3) reg_file.v: GAIN_S/GAIN_C 复位值 32768 → 49152（Q1.15 ×1.5）
  4) reg_file.v: INTER0 复位值 2 → 32
     64 周期/转 × 2×32 = 4096 个 A 沿/机械圈（2048 PPR），与
     sim/tb_enc_top.v 的 POLEBITS_TB=6 + 0x0101=0x0020 配置一致。
     若沿用 v66 的 2，A 沿/圈只有 256，ABZ 输出会粗 16 倍。

为什么默认增益取 1.5
--------------------
  200 mVpp → 0.416 FS ×1.5 = 0.624 FS
  300 mVpp → 0.625 FS ×1.5 = 0.937 FS
两者都落在默认幅值窗 [0.60, 1.20] 内，上电即可 amp_ok / 锁定；
随后一键标定把增益算到 REF/A（0.8 FS），不依赖上位机预置。
取 1.6 时 300 mVpp 到 1.0 FS，16bit 输出会顶到饱和；1.5 留 6% 余量。

用法
----
  python tools/make_lowsig_rtl.py
  （重复运行会先清空 _synth_work_lowsig/rtl_lowsig/ 再复制）
"""

import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "rtl"
DST_ROOT = ROOT / "_synth_work_lowsig"
DST = DST_ROOT / "rtl_lowsig"


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
        r"\1parameter integer POLE_BITS = 6,   // v67：64 周期/转（手搓小信号传感器，2026-10-29 确认）",
        p.name, "POLE_BITS=11",
    )
    t = sub_once(
        t,
        r"^.*RTL_BUILD_ID\s*=\s*16'h000E;.*$",
        "    localparam [15:0] RTL_BUILD_ID = 16'h000F;   // v67 小信号版：200–300 mVpp × 4.16 前端",
        p.name, "RTL_BUILD_ID=0x000E",
    )
    p.write_text(t, encoding="utf-8")

    # ---- 2) reg_file.v ----
    p = DST / "reg_file.v"
    t = p.read_text(encoding="utf-8")
    t = sub_once(
        t,
        r"^(\s*)r_gain_s\s*<=\s*16'd32768;.*$",
        r"\1r_gain_s     <= 16'd49152;      // v67：Q1.15 ×1.5（前端 4.16×，200–300 mVpp → 0.62–0.94 FS）",
        p.name, "r_gain_s=32768",
    )
    t = sub_once(
        t,
        r"^(\s*)r_gain_c\s*<=\s*16'd32768;.*$",
        r"\1r_gain_c     <= 16'd49152;      // v67：Q1.15 ×1.5",
        p.name, "r_gain_c=32768",
    )
    t = sub_once(
        t,
        r"^(\s*)r_inter0\s*<=\s*8'd2;.*$",
        r"\1r_inter0     <= 8'd32;          // v67：64 周期/转 × 2×32 = 4096 A 沿/圈（2048 PPR）",
        p.name, "r_inter0=2",
    )
    p.write_text(t, encoding="utf-8")

    # ---- 3) 自检：副本里不应再出现旧值 ----
    checks = [
        (DST / "enc_top.v", "POLE_BITS = 11", False),
        (DST / "enc_top.v", "POLE_BITS = 6", True),
        (DST / "enc_top.v", "16'h000E", False),
        (DST / "enc_top.v", "16'h000F", True),
        (DST / "reg_file.v", "16'd32768", False),
        (DST / "reg_file.v", "16'd49152", True),
        (DST / "reg_file.v", "r_inter0     <= 8'd2;", False),
        (DST / "reg_file.v", "r_inter0     <= 8'd32;", True),
    ]
    for path, token, want in checks:
        got = token in path.read_text(encoding="utf-8")
        if got != want:
            die("%s: 自检失败，token %r 期望 %s 实际 %s" % (path.name, token, want, got))

    # ---- 4) 变体说明 ----
    info = DST_ROOT / "VARIANT_INFO.txt"
    info.write_text(
        "v67 low-signal variant\n"
        "source git: %s\n"
        "generated: %s\n"
        "source RTL: %s (%d top-level + %d eth)\n"
        "patches:\n"
        "  enc_top.v  POLE_BITS 11 -> 6\n"
        "  enc_top.v  RTL_BUILD_ID 0x000E -> 0x000F\n"
        "  reg_file.v GAIN_S/GAIN_C reset 32768 -> 49152 (Q1.15 x1.5)\n"
        "  reg_file.v INTER0 reset 2 -> 32 (64 cycles/rev x 2x32 = 4096 A edges/rev)\n"
        "build: tools/impl_check_lowsig.tcl -> _impl_lowsig/enc_top_lowsig.bit\n"
        % (git_head(), datetime.now().isoformat(timespec="seconds"),
           SRC, len(src_files), len(eth_files)),
        encoding="utf-8",
    )

    print("OK: %d top-level + %d eth files -> %s" % (len(src_files), len(eth_files), DST))
    print("    patches: POLE_BITS=6, RTL_BUILD_ID=0x000F, GAIN_S/C=49152, INTER0=32")
    print("    info: %s" % info)


if __name__ == "__main__":
    main()
