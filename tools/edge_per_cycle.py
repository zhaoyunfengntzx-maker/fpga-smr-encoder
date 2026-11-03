"""计算 ILA 窗口里的实测 AB 边沿数/电周期，用于核对 RTL 的 2*inter/div 期望值。

用法: python _synth_work/edge_per_cycle.py _synth_work/ila_cap_v8*.csv
列名取自 ILA 导出的 CSV 头两行（第 1 行名字、第 2 行 Radix）。
"""
import csv
import glob
import os
import sys

paths = sys.argv[1:] or sorted(glob.glob(r"_synth_work/ila_cap_v8*.csv"))
for p in sorted(paths):
    with open(p, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.reader(f)
        hdr = next(r)
        next(r)
        rows = [row for row in r if len(row) >= 31]

    def idx(name):
        return hdr.index(name)

    ie = idx("dbg_edge_cnt[31:0]")
    ip = idx("dbg_pos_full[31:0]")
    ia = idx("dbg_angle[15:0]")
    iv = idx("dbg_dec_valid")
    e = [int(x[ie], 16) for x in rows]
    pf = [int(x[ip], 16) for x in rows]
    ang = [int(x[ia], 16) for x in rows]
    d_edge = e[-1] - e[0]
    span = pf[-1] - pf[0]
    cyc = span / 65536.0
    nz = sum(1 for x in rows if int(x[iv], 16) == 1)
    # 直读 step: 逐个非零递增判定（含反向）
    print(
        "%-26s d_edge=%4d pos_span=%8d cyc=%6.3f ang_span=%6d edges/cyc=%8.2f dec_valid=%d"
        % (os.path.basename(p), d_edge, span, cyc, ang[-1] - ang[0], (d_edge / cyc if cyc else float("nan")), nz)
    )
