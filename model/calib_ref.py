#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
calib_ref.py —— calib_ctrl.v / sc_correct.v 的**独立参考模型**（不 import calib_rtl_model）

为什么另写一份
--------------
model/calib_rtl_model.py 是"照着 RTL 抄一遍"的位精确模型，用来做**浮点黄金模型
对照**；如果拿它当 RTL 测试台的期望值，那就是"用 RTL 验证 RTL"。
本文件的算法来自**规格**（rtl/calib_ctrl.v 头注释顶部的闭式解 + 信号模型），
用 numpy 直接按浮点公式推导，再按 RTL 的定点/截断/饱和规则量化，
给出 tb_calib_ctrl 逐样本比对的期望值。

用途
----
1) `python tools/gen_calib_vectors.py` 调用本文件，生成
   <workdir>/stim_*.txt（输入样本 + 期望输出 + 期望参数 + 期望写回字节）。
2) 直接运行本文件（`python model/calib_ref.py`）会打印自检摘要：
   与 model/golden_model.py::calibrate() 的**浮点黄金解**逐项对比，
   确认"规格 -> 参考模型"这一步本身没有算错。
"""

import math
import os
import sys

import numpy as np

Q_ONE = 1 << 15           # 32768 = 1.0
REF_Q15 = 26214           # 0.80 * 32768
M48 = (1 << 48) - 1
M32 = (1 << 32) - 1


# ============================================================================
# 1) 定点算术原语（按 RTL 的位宽/截断语义，但不复用 RTL 的代码结构）
# ============================================================================
def div_u48(num, den):
    """48 位 / 32 位 无符号整数除法，取模 2^48（商溢出回绕）。den==0 -> 全 1 饱和。

    注意：这里**不做截断到 48 位以外的饱和**，只用 & M48 模拟 48 位商寄存器
    的回绕 —— 但所有调用点的商都远小于 2^48，回绕不会触发。
    """
    if den == 0:
        return M48
    return (int(num) & M48) // int(den)          # 纯整数除法 = 恢复余数法的结果


def div_trunc(num, den):
    """普通向零截断整数除法（用于 RTL 里直接写 / 的地方，例如 tg = NUM/a_s）。"""
    if den == 0:
        return M48
    q = abs(int(num)) // abs(int(den))
    return -q if (num < 0) != (den < 0) else q


def isqrt_u32(x):
    """32 位无符号 -> 16 位无符号 floor(sqrt(x))（逐位试根法的数学结果）。"""
    return math.isqrt(int(x) & M32) & 0xFFFF


def asr(v, n):
    """算术右移（对负数向下取整）。n 为负时左移。"""
    if n >= 0:
        return int(v) >> n
    return int(v) << (-n)


def s16(v):
    v = int(v) & 0xFFFF
    return v - (1 << 16) if v & 0x8000 else v


def sat16(v):
    v = int(v)
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)


# ============================================================================
# 2) 输入信号模型（规格：s = A_s*sin(th)+O_s ; c = A_c*cos(th+dphi)+O_c）
# ============================================================================
def make_q15(cycles, per_cycle, amp=22000, ofs_s=0, ofs_c=0,
             gain_s=1.0, gain_c=1.0, dphi_deg=0.0):
    """生成 (s_q15, c_q15) 整数序列，长度 = cycles*per_cycle。

    量化到 Q1.15 整数（round 后 clip 到 16 位有符号范围），返回 python int 列表。
    """
    n = int(cycles) * int(per_cycle)
    th = np.arange(n, dtype=float) * (2.0 * math.pi / float(per_cycle))
    dphi = math.radians(dphi_deg)
    s = amp * gain_s * np.sin(th) + ofs_s
    c = amp * gain_c * np.cos(th + dphi) + ofs_c
    s_q = np.clip(np.round(s), -32768, 32767).astype(np.int64)
    c_q = np.clip(np.round(c), -32768, 32767).astype(np.int64)
    return [int(v) for v in s_q], [int(v) for v in c_q]


# ============================================================================
# 3) 闭式标定（规格公式 + RTL 的定点规则）
# ============================================================================
def coarse_shift(tg):
    """规格（= rtl/calib_ctrl.v:117-119 = model/golden_model.py::_coarse_shift）：
    选最小的 sh 使 tg/2^sh <= 1.999，即 tg <= 65503<<sh。tg 是 Q1.15 定点。"""
    if tg <= 65503:
        return 0
    if tg <= 131006:
        return 1
    if tg <= 262012:
        return 2
    return 3


def coarse_shift_one(tg):
    """对照臂："细调增益 <= 1.0" 判据，选最小的 sh 使 tg/2^sh <= 1.0。

    ★ 注意量纲：tg 是 Q1.15 定点（32768 == 1.0），所以阈值必须是 32768 而不是
      1.0。旧版本这里写 `if tg / float(1 << sh) <= 1.0`，把 Q15 整数（≈39000）
      直接和 1.0 比 ⇒ 永远为假、恒返回 sh=3，那个"1.0 臂"名不符实。
      同样的量纲 bug 也存在于已删除的 tools/calib_shift_study.py:37-45。
    2026-10-10 P1 定案：把两条判据放进同一条整数路径实测，8 个工况的最终角度
    误差**完全相同**（见 tools/calib_shift_judge.py / model/calib_shift_judge_report.txt），
    故 RTL 采用 <=1.999；本函数只作为对照臂保留。
    """
    for sh in range(4):
        if (tg >> sh) <= 32768:
            return sh
    return 3


def calibrate(s_q, c_q, ref_q15=REF_Q15, shift_rule='1.999'):
    """按规格闭式解算 6 参数，返回与 RTL 同格式的整数结果。

    中间量全部走浮点（这是"独立参考"的关键：RTL 用串行定点除法/开方，
    参考模型用浮点，两者只有在 RTL 写错时才会分叉）。
    """
    s = np.asarray(s_q, dtype=float)
    c = np.asarray(c_q, dtype=float)
    N = len(s)
    assert N > 0

    o_s_f = s.mean()
    o_c_f = c.mean()
    # RTL: 向零截断 + 饱和到 +-32767
    o_s = int(math.trunc(o_s_f))
    o_c = int(math.trunc(o_c_f))
    o_s = max(-32767, min(32767, o_s))
    o_c = max(-32767, min(32767, o_c))

    s1 = s - o_s_f
    c1 = c - o_c_f
    ms2 = (s1 * s1).mean()
    mc2 = (c1 * c1).mean()
    sd = (s1 * c1).mean()

    a_s_f = math.sqrt(max(2.0, 2.0 * ms2))
    a_c_f = math.sqrt(max(2.0, 2.0 * mc2))
    # RTL: 逐位试根 -> floor(sqrt)，0 则取 1
    a_s = isqrt_u32(int(round(2.0 * ms2))) or 1
    a_c = isqrt_u32(int(round(2.0 * mc2))) or 1

    sin_dp_f = max(-0.5, min(0.5, -2.0 * sd / (a_s_f * a_c_f)))
    # sin_dp 定点：RTL 用 (|sd|<<16)/(A_s*A_c) 截断后限幅 16384
    sd_abs = abs(int(round(sd)))
    sin_dp = min(16384, div_u48(sd_abs << 16, (a_s * a_c) & M32))
    cos_dp_f = math.sqrt(max(1e-6, 1.0 - sin_dp_f * sin_dp_f))
    cos_dp = isqrt_u32((1 << 30) - sin_dp * sin_dp) or 1

    # phase_k = 32768*2*sd/A_s^2 = (|sd|<<16)/A_s^2，带符号，限幅 32767
    phase_k_mag = min(32767, div_u48(sd_abs << 16, (a_s * a_s) & M32))
    phase_k = -phase_k_mag if sd < 0 else phase_k_mag

    # 增益：RTL 是 tg = NUM/a_s（NUM 已含 32768 或 2^30 的定点因子），
    # 所以 tg 就是"总增益的 Q1.15 定点值"，与 golden_model 的
    # tg = ref/a_s（浮点乘数）只差一个 Q_ONE 因子，判据阈值才是同一个量纲。
    tg_s = min(1048575, div_trunc(32768 * ref_q15, a_s))
    tg_c = min(1048575, div_trunc((1 << 30) * ref_q15, (a_c * cos_dp) & M32))

    rule = coarse_shift if shift_rule == '1.999' else coarse_shift_one
    sh_s = rule(tg_s)
    sh_c = rule(tg_c)
    gain_s = min(65535, tg_s >> sh_s)
    gain_c = min(65535, tg_c >> sh_c)

    return dict(ofs_s=o_s, ofs_c=o_c, gain_s=gain_s, gain_c=gain_c,
                phase_k=phase_k, shift_s=sh_s, shift_c=sh_c,
                a_s=a_s, a_c=a_c, sin_dp=sin_dp, cos_dp=cos_dp,
                N=N, sd=sd, tg_s=tg_s, tg_c=tg_c,
                o_s_f=o_s_f, o_c_f=o_c_f, a_s_f=a_s_f, a_c_f=a_c_f)


# ============================================================================
# 4) sc_correct 参考（规格：3 级流水，与 rtl/sc_correct.v 同式）
# ============================================================================
def sc_correct_one(s, c, ofs_s, ofs_c, gain_s, gain_c, phase_k, shift_s, shift_c):
    s1 = s - ofs_s
    c1 = c - ofs_c
    c2 = c1 - asr(s1 * phase_k, 15)
    s2 = asr(s1 * gain_s, 15 - shift_s)
    c3 = asr(c2 * gain_c, 15 - shift_c)
    return sat16(s2), sat16(c3)


# ============================================================================
# 5) 自检：与 golden_model.py 的浮点黄金解对比
# ============================================================================
def _selftest():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import golden_model as gm

    cases = [
        ("A 理想", dict(amp=22000)),
        ("B 偏置", dict(amp=22000, ofs_s=4000, ofs_c=-3500)),
        ("C 幅值失衡 1.25x", dict(amp=22000, gain_s=1.25)),
        ("D 正交误差 5deg", dict(amp=22000, dphi_deg=5.0)),
        ("E 三类叠加", dict(amp=22000, ofs_s=4000, ofs_c=-3500, gain_s=1.25, dphi_deg=5.0)),
        ("F 小信号", dict(amp=6000, ofs_s=800, ofs_c=-800, gain_s=1.25, dphi_deg=-5.0)),
    ]
    print("=" * 92)
    print(" calib_ref 自检：本参考模型(规格+定点规则) vs golden_model 浮点黄金解")
    print("=" * 92)
    print("%-16s %28s %28s" % ("工况", "本模型 (ofs_s,ofs_c,gain_s,gain_c,ph_k,sh)", "黄金解"))
    print("-" * 92)
    worst = 0
    for nm, kw in cases:
        s_q, c_q = make_q15(4, 64, **kw)
        p = calibrate(s_q, c_q)
        g = gm.calibrate(np.array(s_q), np.array(c_q))
        print("%-16s %28s %28s" % (
            nm,
            "(%d,%d,%d,%d,%d,%d/%d)" % (p['ofs_s'], p['ofs_c'], p['gain_s'],
                                        p['gain_c'], p['phase_k'],
                                        p['shift_s'], p['shift_c']),
            "(%d,%d,%d,%d,%d,%d/%d)" % (g['ofs_s'], g['ofs_c'], g['gain_s'],
                                        g['gain_c'], g['phase_k'],
                                        g['shift_s'], g['shift_c'])))
        d = max(abs(p['ofs_s'] - g['ofs_s']), abs(p['ofs_c'] - g['ofs_c']),
                abs(p['gain_s'] - g['gain_s']), abs(p['gain_c'] - g['gain_c']),
                abs(p['phase_k'] - g['phase_k']))
        worst = max(worst, d)
    print("-" * 92)
    print("  最大参数偏差 = %d LSB（reported 参数的比较见下表）" % worst)

    # 有效总增益 = (gain/2^15) * 2^sh —— sh 差一档时这个乘积必须仍然相等
    print()
    print("  [有效总增益校验] (gain/32768)*2^sh 在两种判据下必须一致（相对差 <0.1pct 视为一致）")
    bad = 0
    for nm, kw in cases:
        s_q, c_q = make_q15(4, 64, **kw)
        p1 = calibrate(s_q, c_q, shift_rule='1.999')
        p2 = calibrate(s_q, c_q, shift_rule='1.0')
        g1 = [(p1['gain_s'] / Q_ONE) * (1 << p1['shift_s']),
              (p1['gain_c'] / Q_ONE) * (1 << p1['shift_c'])]
        g2 = [(p2['gain_s'] / Q_ONE) * (1 << p2['shift_s']),
              (p2['gain_c'] / Q_ONE) * (1 << p2['shift_c'])]
        rel = max(abs(g1[0] / g2[0] - 1.0), abs(g1[1] / g2[1] - 1.0)) * 100.0
        if rel > 0.1:
            bad += 1
        print("    %-16s RTL gain=(%8.5f,%8.5f) 黄金 gain=(%8.5f,%8.5f)  相对差=%.5f%%"
              % (nm, g1[0], g1[1], g2[0], g2[1], rel))
    print("    -> %s" % ("全部一致（1.999 与 1.0 只改变粗调档位，不改变有效总增益）"
                         if bad == 0 else "有 %d 项不一致，需排查" % bad))

    # 1.999 vs 1.0 两种粗调判据在同样输入下的差异
    print()
    print("  [粗调判据差异] RTL/golden 用 tg/2^sh <= 1.999，对照臂用 tg/2^sh <= 1.0")
    print("    2026-10-10 P1 定案：两条判据的最终角度误差实测完全相同（8 个工况逐项一致），")
    print("    唯一差别是细调增益量化步长 2^sh/32768 —— 见 tools/calib_shift_judge.py。")
    for nm, kw in cases:
        s_q, c_q = make_q15(4, 64, **kw)
        p1 = calibrate(s_q, c_q, shift_rule='1.999')
        p2 = calibrate(s_q, c_q, shift_rule='1.0')
        mark = "" if (p1['shift_s'] == p2['shift_s'] and p1['shift_c'] == p2['shift_c']) else "  <== 档位不同"
        # 细调增益量化步长 = 2^sh/32768：sh 越大，(tg>>sh) 相对 tg 的截断越大
        st_s = (1 << p1['shift_s']) / float(Q_ONE)
        st_c = (1 << p1['shift_c']) / float(Q_ONE)
        print("    %-16s RTL sh=%d/%d gain=%5d/%5d 量化步长=%.5f/%.5f | 对照 sh=%d/%d%s"
              % (nm, p1['shift_s'], p1['shift_c'], p1['gain_s'], p1['gain_c'],
                 st_s, st_c, p2['shift_s'], p2['shift_c'], mark))


if __name__ == "__main__":
    _selftest()
