"""从 ILA CSV 的 dbg_a_out / dbg_b_out 逐拍电平重建 AB 正交序列，把边沿分成正向/反向。

用途：板上直接量"抖动群"（正反成对点火）——这是选 v8 默认（门控 + kp2/ki3）的
核心判据（sim/tb_loop_abz_chain.v 里 A-P0 = 482 跳变 / 816 次方向反转，
B-P1 = 126 跳变 / 0 次反转），但它此前**没有在板上量过**。

判定：正交序列按 Gray 环 (A,B) = 00 -> 01 -> 11 -> 10 -> 00 单步推进。
正向/反向由多数方向决定（本板输入是单向旋转），并报告两向计数与非法跳变数。
"""
import csv
import glob
import os
import sys

paths = sys.argv[1:] or sorted(glob.glob(r"_synth_work/ila_cap_v8*.csv"))
# Gray 环顺序（索引 = 状态码 a*2+b）
RING = [0b00, 0b01, 0b11, 0b10]
POS = {s: i for i, s in enumerate(RING)}

for p in sorted(paths):
    with open(p, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.reader(f)
        hdr = next(r)
        next(r)
        rows = [row for row in r if len(row) >= 31]
    ia, ib = hdr.index("dbg_a_out"), hdr.index("dbg_b_out")
    seq = [(int(x[ia], 16) & 1, int(x[ib], 16) & 1) for x in rows]
    fwd = rev = bad = 0
    for (a0, b0), (a1, b1) in zip(seq, seq[1:]):
        if (a0, b0) == (a1, b1):
            continue
        d = (POS[(a1 << 1) | b1] - POS[(a0 << 1) | b0]) % 4
        if d == 1:
            fwd += 1
        elif d == 3:
            rev += 1
        else:
            bad += 1
    # 单向旋转时"正向"应为多数；这里直接报原值，让读者按窗口方向解释
    print(
        "%-24s 总边沿=%3d  顺环=%3d  逆环=%3d  非法(跨2步)=%d  逆环占比=%.1f%%"
        % (os.path.basename(p), fwd + rev + bad, fwd, rev, bad, 100.0 * rev / max(1, fwd + rev + bad))
    )
