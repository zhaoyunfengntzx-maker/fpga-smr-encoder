# -*- coding: utf-8 -*-
"""lag_warn/lag_fatal 阈值实测探针（只读模型，不改任何 RTL/模型）

目的：核对实现阈值与标称"45° (warn) / 180° (fatal)"是否一致。
历史：2026-10-11 首次实测发现**旧实现差 4×**（实际在 180°/360° 才置位）。
      经定案按 (b) 重标定 ⇒ `rtl/abz_gen.v` 与 `model/abz_uvw_model.py` 同步改为
        lag_warn  : lag_mag*div >= (inter+1)>>1   （= inter/2 idx 步 = 45°）
        lag_fatal : lag_mag*div >= 2*inter        （= 2*inter idx 步 = 180°）
      本探针用来复测"重标定后 warn/fatal 是否真的落在 45°/180° 附近"。
      详见 docs/DEV_STATUS.md §1.33 ⑦ 与 §3 item 18；契约见
      rtl/SPEC_interface_contract.md 行为 4b。

做法：用 model/abz_uvw_model.py 的 AbzGen（与 RTL 逐拍等价、且是 lag 定义的
      契约来源），开一个大 ablimit 让限频器把边沿压住 ⇒ lag_mag 单调增长，
      同时独立算出"真实角度滞后" = (理想边沿索引 - 实际边沿索引)/(4*inter)*360，
      记录 warn/fatal 第一次置位时的真实滞后角。
      判据幅值 lag_mag = |slc_fwd - slc_bwd| + r_ovl（item 16 ②），两项都打印。

用法：python tools/lag_thr_probe.py [--inter 256] [--div 1] [--ablimit 255]
      注意：滞后必须**去卷绕**累加 —— 快速斜坡下一次 lag_mag 会对应多圈滞后，
      用 (cur_idx - div_idx) % n_step 会得到 0/6°/27° 这类无意义值（踩过的坑）。
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'model'))
from abz_uvw_model import AbzGen, LAG_WARN_DIV, LAG_FATAL_MUL   # noqa: E402


def probe(inter, div, ablimit, slope_lsb_per_tick, max_ticks=20000):
    n_step = 4 * inter          # 一个输入周期内的 AB 边沿步数（模型 :139 / SPEC 行为 1）
    deg_per_step = 360.0 / n_step
    m = AbzGen(clk_period_ns=20.0)
    m.inter, m.div, m.hyst, m.ablimit = inter, div, 0, ablimit
    m.z_width, m.z_phase, m.z_window = 1, 0, 0
    m.invalidate_cache()
    ang = 0
    first_warn = first_fatal = None
    lag = 0            # 去卷绕的真实滞后（idx 步）：指令增量累加 - 实际执行边沿
    prev_cmd = m.cur_idx
    prev_ec = m.edge_cnt
    for i in range(max_ticks):
        a, b, z, ec, lim, warn, fat, ov = m.run(ang)
        d = (m.cur_idx - prev_cmd) % n_step
        if d > n_step // 2:
            d = 0                       # 反向/卷绕保护（本场景单向）
        lag += d
        prev_cmd = m.cur_idx
        if ec != prev_ec:
            lag -= (ec - prev_ec)       # 实际每执行一个边沿，滞后就减 1 步
        prev_ec = ec
        lag_mag = abs(m.slc_fwd - m.slc_bwd) + m.ovl
        if warn and first_warn is None:
            first_warn = (i, lag_mag, m.ovl, lag, lag * deg_per_step)
        if fat and first_fatal is None:
            first_fatal = (i, lag_mag, m.ovl, lag, lag * deg_per_step)
        if first_fatal is not None:
            break
        ang = (ang + slope_lsb_per_tick) & 0xFFFF
    return first_warn, first_fatal


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--inter', type=int, default=256)
    ap.add_argument('--div', type=int, default=1)
    ap.add_argument('--ablimit', type=int, default=255)
    ap.add_argument('--slopes', type=int, nargs='+', default=[64, 256, 1024])
    args = ap.parse_args()

    n_step = 4 * args.inter
    deg_per_step = 360.0 / n_step
    print('inter=%d div=%d  n_step=4*inter=%d  (%.4f deg/edge step)'
          % (args.inter, args.div, n_step, deg_per_step))
    print('RTL/模型常数: LAG_WARN_DIV=%d -> 阈值 lag_mag*div >= (inter+1)>>1 = %d idx 步'
          % (LAG_WARN_DIV, (args.inter + 1) // 2))
    print('              LAG_FATAL_MUL=%d -> 阈值 lag_mag*div >= %d idx 步'
          % (LAG_FATAL_MUL, LAG_FATAL_MUL * args.inter))
    print('标称换算: warn 45° = %d idx 步, fatal 180° = %d idx 步（应与上式一致）'
          % (n_step // 8, n_step // 2))
    print('按 4*inter 步 = 360° 的几何，实现阈值 = %.1f° / %.1f°'
          % (((args.inter + 1) // 2) * deg_per_step,
             LAG_FATAL_MUL * args.inter * deg_per_step))
    print('-' * 78)

    for slope in args.slopes:
        w, f = probe(args.inter, args.div, args.ablimit, slope)
        print('角度斜率 %5d LSB/拍：' % slope)
        if w:
            print('   首次 lag_warn : tick=%5d  lag_mag=%4d (ovl=%4d)  真实滞后=%5d idx 步 = %7.1f°'
                  % (w[0], w[1], w[2], w[3], w[4]))
        if f:
            print('   首次 lag_fatal: tick=%5d  lag_mag=%4d (ovl=%4d)  真实滞后=%5d idx 步 = %7.1f°'
                  % (f[0], f[1], f[2], f[3], f[4]))


if __name__ == '__main__':
    main()
