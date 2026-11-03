# -*- coding: utf-8 -*-
"""v73 RTL 变体生成器：v72 的显示修复 + v73 的 Z 计数探针。

来源：仓库 rtl/（当前 BUILD_ID = 16'h0015，v70 基线，已含 v71 的 Z 修复）
本变体只改 1 处：RTL_BUILD_ID 16'h0015 -> 16'h0017。
其余（Z 上升沿计数器 z_pulse_cnt / reg_file 0x054A..0x054D）已在仓库 rtl 里，
随复制一起进变体；生成后逐条自检，任何一条不满足直接报错退出。
"""
import io, os, re, shutil, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC  = os.path.join(ROOT, "rtl")
OUT  = os.path.join(ROOT, "_synth_work_v73", "rtl_v73")
BUILD_OLD = "16'h0015"
BUILD_NEW = "16'h0017"

def cp_tree():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    n_top = n_eth = 0
    for fn in sorted(os.listdir(SRC)):
        if fn.endswith(".v"):
            shutil.copy2(os.path.join(SRC, fn), os.path.join(OUT, fn))
            n_top += 1
    eth_src = os.path.join(SRC, "eth")
    eth_out = os.path.join(OUT, "eth")
    os.makedirs(eth_out, exist_ok=True)
    for fn in sorted(os.listdir(eth_src)):
        if fn.endswith(".v"):
            shutil.copy2(os.path.join(eth_src, fn), os.path.join(eth_out, fn))
            n_eth += 1
    return n_top, n_eth

def sub_once(path, old, new, what):
    s = io.open(path, encoding="utf-8").read()
    n = s.count(old)
    if n != 1:
        sys.exit("ERROR: %s in %s count=%d (expect 1)" % (what, os.path.basename(path), n))
    io.open(path, "w", encoding="utf-8", newline="\n").write(s.replace(old, new))

def main():
    n_top, n_eth = cp_tree()
    top = os.path.join(OUT, "enc_top.v")
    reg = os.path.join(OUT, "reg_file.v")
    abz = os.path.join(OUT, "abz_gen.v")

    sub_once(top, "localparam [15:0] RTL_BUILD_ID = %s;" % BUILD_OLD,
             "localparam [15:0] RTL_BUILD_ID = %s;   // v73：Z 计数探针" % BUILD_NEW,
             "RTL_BUILD_ID")

    checks = [
        (top, "parameter integer POLE_BITS = 11"),
        (top, "wire ang_wrap_f = filt_valid"),
        (top, "clr_on_z     (1'b0)"),
        (top, "z_pulse_cnt"),
        (top, ".stat_z_cnt       (z_pulse_cnt)"),
        (reg, "input  wire [31:0]   stat_z_cnt"),
        (reg, "16'h054A: rdata = stat_z_cnt[7:0]"),
        (reg, "r_inter0     <= 8'd32;"),
        (abz, "z_pend_ok"),
        (abz, "z_rev"),
        (os.path.join(OUT, "pole_counter.v"), "phase_acc"),
    ]
    bad = 0
    for path, tok in checks:
        s = io.open(path, encoding="utf-8").read()
        ok = tok in s
        if not ok:
            bad += 1
        print(("  OK   " if ok else "  MISS ") + os.path.basename(path) + " :: " + tok)
    s_top = io.open(top, encoding="utf-8").read()
    if "POLE_BITS = 6" in s_top:
        print("  MISS enc_top.v :: must NOT contain 'POLE_BITS = 6'")
        bad += 1
    if BUILD_NEW not in s_top:
        print("  MISS enc_top.v :: BUILD", BUILD_NEW)
        bad += 1
    if bad:
        sys.exit("ERROR: %d self-check(s) failed" % bad)

    info = os.path.join(ROOT, "_synth_work_v73", "VARIANT_INFO.txt")
    io.open(info, "w", encoding="utf-8", newline="\n").write(
        "v73 = v71 RTL (position acc + Z index fix) + Z pulse counter probe\n"
        "build id : %s\n"
        "source   : rtl/ (git %s)\n"
        "generated: %s\n"
        "diff vs rtl/: RTL_BUILD_ID only\n"
        "probe    : z_pulse_cnt (32-bit, rising edges of z_out) -> 0x054A..0x054D\n"
        % (BUILD_NEW, os.popen("git -C %s rev-parse --short HEAD" % ROOT).read().strip(),
           time.strftime("%Y-%m-%dT%H:%M:%S"))
    )
    print("OK: %d top-level + %d eth -> %s" % (n_top, n_eth, OUT))

main()
