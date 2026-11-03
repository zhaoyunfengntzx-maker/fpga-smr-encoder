#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
calib_rtl_model.py —— calib_ctrl.v **位精确**整数模型（含共用除法器/开方器）

目的
----
1) 逐位复现 rtl/calib_ctrl.v 的定点运算：
     · 48 位恢复余数除法器（9 次复用，见 RTL 的 S_OFFSET/S_AMP/S_PHASE/S_GAIN/S_DIV）
     · 32 位逐位试根开方器（3 次复用：A_s / A_c / cos_dp）
     · 闭式标定数据通路（与 model/golden_model.py::calibrate() 同式）
2) 与浮点黄金模型对比参数，并用 golden_model 的 CORDIC + sc_correct 计算
   标定前后的角度误差，复现头注释里的精度数字。
3) 本文件**不修改** golden_model.py，只 import 使用。

运行：
  python calib_rtl_model.py
"""

import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import golden_model as gm          # noqa: E402  (只读使用)

M48 = (1 << 48) - 1
M32 = (1 << 32) - 1


# ============================================================================
# 1) 与 RTL 逐位一致的算术单元
# ============================================================================
def div_u48(num, den):
    """rtl/calib_ctrl.v 的恢复余数除法器：48 位 / 32 位 -> 48 位商（截断）。"""
    if den == 0:
        return M48
    num &= M48
    rem = 0
    q = 0
    for i in range(47, -1, -1):
        rem = ((rem << 1) | ((num >> i) & 1)) & M48
        q = (q << 1) & M48
        if rem >= den:
            rem -= den
            q |= 1
    return q


def isqrt_u32(x):
    """rtl/calib_ctrl.v 的逐位试根开方器：32 位无符号 -> 16 位无符号。

    逐位(restoring digit-by-digit)：
        每步 rem' = 4*rem + 下 2 个输入位
        判据 rem' >= 4*root + 1  ->  d=1, rem = rem' - (4*root+1), root = 2*root+1
        否则                      ->  d=0, rem = rem',              root = 2*root
    RTL 中 root 在试根前恒 < 2^15，故 4*root+1 可只用 17 位表示。
    """
    x &= M32
    rem = 0
    root = 0
    out = 0
    for i in range(15, -1, -1):
        rem_new = (((rem & 0x3FFFF) << 2) | ((x >> (2 * i)) & 3)) & 0xFFFFF
        trial = (((root & 0x7FFF) << 2) | 1) & 0x1FFFF     # 4*root + 1
        if rem_new >= trial:
            rem = (rem_new - trial) & 0xFFFFF
            root = (((root & 0xFFFF) << 1) | 1) & 0x1FFFF  # 2*root + 1
            if i == 0:
                out = root & 0xFFFF
        else:
            rem = rem_new
            root = ((root & 0xFFFF) << 1) & 0x1FFFF        # 2*root
            if i == 0:
                out = root & 0xFFFF
    return out


def sd32(v):
    """32 位有符号解释"""
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def s16(v):
    v &= 0xFFFF
    return v - (1 << 16) if v & 0x8000 else v


# ============================================================================
# 2) calib_ctrl.v 的定点数据通路（逐状态对应 RTL）
# ============================================================================
def calib_rtl(s_n, c_n, ref_q15=26214, win=None):
    """输入 Q1.15 整数序列，返回与 RTL 完全相同的标定结果字典。

    win: 参与标定的样本数(默认全部)；模拟 win_cycles 个输入周期对应的样本窗口。
    """
    s_n = np.asarray(s_n, dtype=np.int64)
    c_n = np.asarray(c_n, dtype=np.int64)
    if win is not None:
        s_n = s_n[:win]
        c_n = c_n[:win]
    N = int(len(s_n))
    assert 0 < N <= 65536, "RTL 的 MAX_SAMPLES = 65536"

    # ---------------- S_ACCUM ----------------
    S1 = int(s_n.sum())
    S2 = int(c_n.sum())
    S3 = int((s_n * s_n).sum())
    S4 = int((c_n * c_n).sum())
    S5 = int((s_n * c_n).sum())

    # ---------------- S_OFFSET: O_s = S1/N, O_c = S2/N (向零截断 + 饱和) ----------
    def mean_signed(S):
        neg = S < 0
        mag = -S if neg else S
        q = div_u48(mag, N) & 0xFFFF
        if q > 32767:
            q = 32767
        return -q if neg else q

    o_s = mean_signed(S1)
    o_c = mean_signed(S2)

    # ---------------- S_AMP ----------------
    mean_sq_s = div_u48(S3, N) & M32
    mean_sq_c = div_u48(S4, N) & M32
    sd_mean_mag = div_u48(abs(S5), N) & M32
    sd_mean_neg = 1 if S5 < 0 else 0

    o_s_sq = (o_s * o_s) & M32
    o_c_sq = (o_c * o_c) & M32
    oc_prod = (o_s * o_c)                      # 有符号

    ms2_s = (mean_sq_s - o_s_sq) & M32 if mean_sq_s >= o_s_sq else 0
    ms2_c = (mean_sq_c - o_c_sq) & M32 if mean_sq_c >= o_c_sq else 0
    dbl_ms2_s = ((ms2_s & 0x7FFFFFFF) << 1) & M32
    dbl_ms2_c = ((ms2_c & 0x7FFFFFFF) << 1) & M32
    num_2ms_s = 2 if dbl_ms2_s < 2 else dbl_ms2_s
    num_2ms_c = 2 if dbl_ms2_c < 2 else dbl_ms2_c

    # 33 位有符号 sd = ±|S5/N| - O_s*O_c
    sd_wide = (-sd_mean_mag if sd_mean_neg else sd_mean_mag) - oc_prod
    if sd_wide > 2147483647:
        sd_wide = 2147483647
    elif sd_wide < -2147483648:
        sd_wide = -2147483648
    sd_w = sd32(sd_wide & M32)
    sd_neg = 1 if sd_w < 0 else 0
    sd_abs48 = (-sd_w) if sd_neg else sd_w
    sdp_num = (sd_abs48 << 16) & M48          # = 2*|sd|<<15 = |sd|<<16

    # ---------------- S_SQRT1 / S_SQRT2 ----------------
    a_s = isqrt_u32(num_2ms_s)
    if a_s == 0:
        a_s = 1
    a_c = isqrt_u32(num_2ms_c)
    if a_c == 0:
        a_c = 1

    # ---------------- S_PHASE ----------------
    a_sac = (a_s * a_c) & M32
    q = div_u48(sdp_num, a_sac) & 0xFFFF
    sin_dp_mag = 16384 if q > 16384 else q
    cos_dp_in = (0x40000000 - ((sin_dp_mag * sin_dp_mag) & M32)) & M32
    cos_dp = isqrt_u32(cos_dp_in)
    if cos_dp == 0:
        cos_dp = 1

    # ---------------- S_GAIN ----------------
    NUM_GAIN_S = (32768 * ref_q15) & M48                    # 30 bit
    NUM_GAIN_C = ((1 << 30) * ref_q15) & M48                # 45 bit
    a_ccos = (a_c * cos_dp) & M32
    tg_s = div_u48(NUM_GAIN_S, a_s) & M32
    if tg_s > 1048575:
        tg_s = 1048575
    tg_c = div_u48(NUM_GAIN_C, a_ccos) & M32
    if tg_c > 1048575:
        tg_c = 1048575

    # ---------------- S_DIV: phase_k ----------------
    a_ssq = (a_s * a_s) & M32
    q = div_u48(sdp_num, a_ssq) & 0xFFFF
    phase_k_mag = 32767 if q > 32767 else q
    phase_k = -phase_k_mag if sd_neg else phase_k_mag

    # ---------------- S_SHIFT: _coarse_shift + gain = tg >> sh ----------------
    def coarse_shift(tg):
        if tg <= 65503:
            return 0
        if tg <= 131006:
            return 1
        if tg <= 262012:
            return 2
        return 3

    sh_s = coarse_shift(tg_s)
    sh_c = coarse_shift(tg_c)
    gain_s = (tg_s >> sh_s) & 0xFFFF
    gain_c = (tg_c >> sh_c) & 0xFFFF

    return dict(ofs_s=o_s, ofs_c=o_c, gain_s=gain_s, gain_c=gain_c,
                phase_k=phase_k, shift_s=sh_s, shift_c=sh_c,
                a_s=a_s, a_c=a_c, sin_dp=sin_dp_mag, cos_dp=cos_dp,
                sd=sd_w, N=N, S1=S1, S2=S2, S3=S3, S4=S4, S5=S5)


# ============================================================================
# 3) 自检与对比
# ============================================================================
def test_units():
    print("=" * 78)
    print("单元自检：除法器 / 开方器 与 Python 参考实现对比")
    print("=" * 78)
    import random
    random.seed(7)
    bad_div = 0
    for _ in range(3000):
        num = random.getrandbits(48)
        den = random.getrandbits(random.choice([1, 8, 16, 24, 32])) + 1
        got = div_u48(num, den)
        exp = num // den
        if got != exp:
            bad_div += 1
            if bad_div < 4:
                print("  DIV MISMATCH", num, den, got, exp)
    print("  div_u48 : 3000 组随机 (48/32) 对比精确除法 -> %s"
          % ("PASS" if bad_div == 0 else "FAIL(%d)" % bad_div))

    bad_sq = 0
    worst = 0
    for _ in range(20000):
        x = random.getrandbits(32)
        got = isqrt_u32(x)
        exp = math.isqrt(x)
        if got != exp:
            bad_sq += 1
            if bad_sq < 4:
                print("  SQRT MISMATCH", hex(x), got, exp)
    for x in [0, 1, 2, 3, 4, (1 << 30), (1 << 30) - 1, M32, M32 - 1,
              (1 << 31), 805306368, (1 << 28)]:
        if isqrt_u32(x) != math.isqrt(x):
            bad_sq += 1
            print("  SQRT EDGE MISMATCH", hex(x), isqrt_u32(x), math.isqrt(x))
    print("  isqrt_u32: 20000 随机 + 边界 -> %s"
          % ("PASS" if bad_sq == 0 else "FAIL(%d)" % bad_sq))
    print("  sqrt(2^30) = %d (期望 32768), sqrt(2^30-2^28) = %d (期望 %d)"
          % (isqrt_u32(1 << 30), isqrt_u32((1 << 30) - (1 << 28)),
             math.isqrt((1 << 30) - (1 << 28))))


def run_case(name, n=8192, log2dec=2, **kw):
    """与 golden_model.run_case 相同的工况，但标定用 RTL 整数模型。"""
    s_code, c_code, ideal = gm.make_signals(n, **kw)
    s_q = gm.decim_avg(gm.adc_to_q15(s_code), log2dec)
    c_q = gm.decim_avg(gm.adc_to_q15(c_code), log2dec)
    ideal_d = gm.decim_avg_float(ideal, log2dec)

    # --- 未校正角度 ---
    ang_raw, _ = gm.cordic_atan2(c_q.astype(np.int64), s_q.astype(np.int64))
    e_raw = gm.ang_err_deg(ang_raw, gm.ideal_angle16(ideal_d))

    # --- RTL 整数标定 ---
    p_rtl = calib_rtl(s_q, c_q)
    p_flt = gm.calibrate(s_q.astype(np.int64), c_q.astype(np.int64))

    s_f, c_f = gm.sc_correct(s_q.astype(np.int64), c_q.astype(np.int64),
                             ofs_s=p_rtl['ofs_s'], ofs_c=p_rtl['ofs_c'],
                             gain_s=p_rtl['gain_s'], gain_c=p_rtl['gain_c'],
                             phase_k=p_rtl['phase_k'],
                             shift_s=p_rtl['shift_s'], shift_c=p_rtl['shift_c'])
    ang_cor, _ = gm.cordic_atan2(c_f, s_f)
    e_cor = gm.ang_err_deg(ang_cor, gm.ideal_angle16(ideal_d))

    return dict(name=name, p_rtl=p_rtl, p_flt=p_flt,
                e_raw_max=np.abs(e_raw).max(),
                e_raw_rms=float(np.sqrt(np.mean(e_raw ** 2))),
                e_cor_max=np.abs(e_cor).max(),
                e_cor_rms=float(np.sqrt(np.mean(e_cor ** 2))))


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

    test_units()

    print()
    print("=" * 78)
    print("闭式标定：RTL 整数模型 vs golden_model 浮点模型")
    print("参数含义: ofs_s/ofs_c 单位 Q1.15 LSB, gain_* Q1.15(32768=1.0),")
    print("          phase_k Q1.15(=32768*sin(dphi)), shift 为 2 的粗调次数")
    print("=" * 78)

    cases = [
        ("A 理想信号 (仅ADC量化)", dict(amp_q15=22000)),
        ("B 直流偏置 ±4000LSB", dict(amp_q15=22000, ofs_s=4000, ofs_c=-3500)),
        ("C 幅值失衡 1.25x", dict(amp_q15=22000, gain_s=1.25)),
        ("D 正交误差 5deg", dict(amp_q15=22000, dphi_deg=5.0)),
        ("E 三类误差叠加", dict(amp_q15=22000, ofs_s=4000, ofs_c=-3500,
                                gain_s=1.25, dphi_deg=5.0)),
        ("F E + 2次谐波0.5% + 1LSB 噪声", dict(amp_q15=22000, ofs_s=4000,
                                               ofs_c=-3500, gain_s=1.25,
                                               dphi_deg=5.0, h2=0.005,
                                               noise_lsb=1.0)),
        ("G 小信号 20% + 误差", dict(amp_q15=6000, ofs_s=800, ofs_c=-800,
                                     gain_s=1.25, dphi_deg=5.0, noise_lsb=1.0)),
    ]

    rows = []
    for nm, kw in cases:
        r = run_case(nm, **kw)
        rows.append(r)
        p = r['p_rtl']
        q = r['p_flt']
        print()
        print("-" * 78)
        print("%s   (N=%d 样本)" % (nm, p['N']))
        print("  RTL 整数: ofs_s=%6d ofs_c=%6d gain_s=%5d gain_c=%5d "
              "phase_k=%6d sh=%d/%d" % (p['ofs_s'], p['ofs_c'], p['gain_s'],
                                        p['gain_c'], p['phase_k'],
                                        p['shift_s'], p['shift_c']))
        print("  浮点黄金: ofs_s=%6d ofs_c=%6d gain_s=%5d gain_c=%5d "
              "phase_k=%6d sh=%d/%d" % (q['ofs_s'], q['ofs_c'], q['gain_s'],
                                        q['gain_c'], q['phase_k'],
                                        q['shift_s'], q['shift_c']))
        print("  Δ: ofs_s=%d ofs_c=%d gain_s=%d gain_c=%d phase_k=%d"
              % (p['ofs_s'] - q['ofs_s'], p['ofs_c'] - q['ofs_c'],
                 p['gain_s'] - q['gain_s'], p['gain_c'] - q['gain_c'],
                 p['phase_k'] - q['phase_k']))
        print("  角度误差: 校正前 max=%.4f° rms=%.4f° | 校正后 max=%.4f° "
              "rms=%.4f°" % (r['e_raw_max'], r['e_raw_rms'],
                             r['e_cor_max'], r['e_cor_rms']))
        if r['e_cor_max'] > 0:
            print("  改善倍数(max) = %.1fx" % (r['e_raw_max'] / r['e_cor_max']))

    # 组合工况 E 的改善倍数（与头注释数字对应）
    e_case = rows[4]
    print()
    print("=" * 78)
    print("组合工况 E（偏置 + 增益失衡 + 正交误差）:")
    print("  校正前 max = %.2f deg -> 校正后 max = %.3f deg, 改善 %.0fx"
          % (e_case['e_raw_max'], e_case['e_cor_max'],
             e_case['e_raw_max'] / e_case['e_cor_max']))
    print("  校正前 rms = %.2f deg -> 校正后 rms = %.3f deg, 改善 %.0fx"
          % (e_case['e_raw_rms'], e_case['e_cor_rms'],
             e_case['e_raw_rms'] / e_case['e_cor_rms']))
    print("  16 位角度量化底噪 = 360/65536 = %.4f deg (期望的误差下限)"
          % (360.0 / 65536.0))
    print("=" * 78)

    # 窗口长度影响（不做整周期时的泄漏）
    print()
    print("窗口长度敏感性（工况 E，N 个样本 = 完整周期的一部分时）:")
    for w in [512, 1024, 2048, 4096, 8192]:
        s_code, c_code, ideal = gm.make_signals(8192, amp_q15=22000,
                                                ofs_s=4000, ofs_c=-3500,
                                                gain_s=1.25, dphi_deg=5.0)
        s_q = gm.decim_avg(gm.adc_to_q15(s_code), 2)
        c_q = gm.decim_avg(gm.adc_to_q15(c_code), 2)
        p = calib_rtl(s_q, c_q, win=w)
        print("   N=%5d: ofs_s=%6d gain_s=%5d phase_k=%6d sh=%d/%d (a_s=%d)"
              % (w, p['ofs_s'], p['gain_s'], p['phase_k'], p['shift_s'],
                 p['shift_c'], p['a_s']))


if __name__ == "__main__":
    main()
