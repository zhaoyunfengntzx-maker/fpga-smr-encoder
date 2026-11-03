# -*- coding: utf-8 -*-
"""v90 构建源准备器（幂等）。

v90 起，仓库 `rtl/` 本身就是交付源码：`RTL_BUILD_ID = 16'h0019`，Z 索引布防/撤防
（`rtl/abz_gen.v` 的 `z_index_gen`）、Z 上升沿计数 `z_pulse_cnt`、
`reg_file` 的 `0x054A..0x054D` 都在仓库里。本脚本只做两件事：

1. 把 `rtl/` 与 `rtl/eth/` 复制到 `_synth_work_v90/rtl_v90/`（构建目录与仓库隔离）；
2. 逐条校验 v90 的关键实现确实存在、且 BUILD_ID 恰为 0x0019——任何一条不满足直接报错退出。

这样"位流 0x0019"与"仓库源码"之间不再有任何派生差异，复现时不需要改文件。
"""
import io, os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "rtl")
OUT = os.path.join(ROOT, "_synth_work_v90", "rtl_v90")
BUILD_ID = "16'h0019"


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


def main():
    n_top, n_eth = cp_tree()
    top = os.path.join(OUT, "enc_top.v")
    reg = os.path.join(OUT, "reg_file.v")
    abz = os.path.join(OUT, "abz_gen.v")
    uvw = os.path.join(OUT, "uvw_gen.v")

    checks = [
        # 构建号：全树恰好一处，且必须是 0x0019
        (top, "localparam [15:0] RTL_BUILD_ID = %s;" % BUILD_ID),
        # v90 的两处核心改动
        (top, "z_index_gen #("),
        (abz, "Z_ARM_DIST"),
        (abz, "wire signed [AW-1:0] z_arm_d = angle - z_arm_ang;"),
        (abz, "wire ang_wrap_f = in_valid & (z_ang_prev >= ZW_TOP)"),
        # v74 起保留的观测通路
        (top, "z_pulse_cnt"),
        (reg, "input  wire [31:0]   stat_z_cnt"),
        (reg, "16'h054A: rdata = stat_z_cnt[7:0]"),
        # 关键参数（防止误取旧快照）
        (top, "parameter integer POLE_BITS = 11"),
        (reg, "r_inter0     <= 8'd32;"),
        (abz, "z_pend_ok"),
        (abz, "z_rev"),
        (os.path.join(OUT, "pole_counter.v"), "phase_acc"),
        (uvw, "sec"),
    ]
    bad = [t for (p, t) in checks if t not in io.open(p, encoding="utf-8").read()]
    if bad:
        sys.exit("ERROR: token missing: %s" % bad)

    n_build = io.open(top, encoding="utf-8").read().count(BUILD_ID)
    if n_build != 1:
        sys.exit("ERROR: RTL_BUILD_ID = %s appears %d times (expect 1)" % (BUILD_ID, n_build))

    info = os.path.join(ROOT, "_synth_work_v90", "VARIANT_INFO.txt")
    io.open(info, "w", encoding="utf-8", newline="\n").write(
        "v90 build source\n"
        "source: rtl/ (repo, byte-identical; RTL_BUILD_ID = 0x0019)\n"
        "delta vs v74: Z index arm/re-arm (z_index_gen) in abz_gen.v;\n"
        "              uvw_gen.v kept at the v74 behaviour (no e_uw debounce);\n"
        "              display: P7 page removed, P1 calib button removed, P2 pretrigger/AUTO.\n"
        "files : %d top-level + %d eth\n" % (n_top, n_eth))
    print("OK: %d top-level + %d eth -> %s" % (n_top, n_eth, OUT))
    print("OK: RTL_BUILD_ID = %s (repo source, no patch)" % BUILD_ID)


if __name__ == "__main__":
    main()
