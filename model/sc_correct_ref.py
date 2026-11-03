# -*- coding: utf-8 -*-
"""
sc_correct_ref.py —— rtl/sc_correct.v **单级数据通路**的位精确参考模型
================================================================================
定位说明（重要）：
  * 全链路权威模型是 `model/golden_model.py`（内部有 sc_correct / calibrate /
    cordic_atan2 / 实验工况）。本文件**不替代**它，也不会被它依赖。
  * 本文件只镜像 `rtl/sc_correct.v` 这一级的定点语义，用处有三：
      1. 给 RTL 做 bit 级比对（含"窄位宽版"，用来验证 RTL 每个中间位宽都够用）；
      2. 给 sim/tb_sc_correct.v 定判据/预期数字（测试台头注释里的那张表就是本文件算的）；
      3. 把"系数从哪来"的闭式解和"数据通路怎么算"放在一起，便于文档对照。

定点语义（与 RTL 逐位一致）：
    s1 = s_in - ofs_s
    c1 = c_in - ofs_c
    c2 = c1 - asr(s1 * phase_k, 15)                  # phase_k 是 signed Q1.15
    s2 = asr(s1 * gain_s, 15 - shift_s)              # gain 是 UNSIGNED Q1.15
    c3 = asr(c2 * gain_c, 15 - shift_c)
    s_out/c_out = sat16(...)
    asr = 算术右移 = floor（Verilog 对 signed 的 >>>），不是向零截断。
    总增益 = (gain/2^15) * 2^shift，范围 0.5x..16x（-6 dB..+24 dB）。

运行： <bundled python> model/sc_correct_ref.py
"""
import math
import os
import sys

import numpy as np

DW = 16
SH = 15
SAT_MIN, SAT_MAX = -(1 << (DW - 1)), (1 << (DW - 1)) - 1
Q_ONE = 1 << SH


# ==============================================================================
# 1. 数据通路
# ==============================================================================
def asr(v, n):
    """算术右移（向 -inf 取整）= Verilog 对 signed 的 >>>"""
    return np.floor_divide(np.asarray(v, dtype=np.int64), np.int64(1 << n))


def sat16(v):
    return np.clip(v, SAT_MIN, SAT_MAX).astype(np.int64)


def sc_correct(s_in, c_in, ofs_s, ofs_c, gain_s, gain_c, phase_k,
               shift_s=0, shift_c=0):
    """位精确模型（64 位中间量，等价于 RTL 的极值推导成立时的行为）。
    参数可以是标量也可以是 numpy 数组。"""
    s1 = np.asarray(s_in, dtype=np.int64) - np.asarray(ofs_s, dtype=np.int64)
    c1 = np.asarray(c_in, dtype=np.int64) - np.asarray(ofs_c, dtype=np.int64)
    c2 = c1 - asr(s1 * np.asarray(phase_k, dtype=np.int64), SH)
    g_s = np.asarray(gain_s, dtype=np.int64) & 0xFFFF      # 无符号 Q1.15 -> 零扩展
    g_c = np.asarray(gain_c, dtype=np.int64) & 0xFFFF
    s2 = asr(s1 * g_s, SH - np.asarray(shift_s, dtype=np.int64))
    c3 = asr(c2 * g_c, SH - np.asarray(shift_c, dtype=np.int64))
    return sat16(s2), sat16(c3)


# --- 窄位宽版：把 RTL 里每个寄存器的位宽都显式截断，用来证明位宽够用 -------------
DWP, DWM, DWC, DWS, DWM2, DWSH = 17, 33, 18, 34, 35, 24


def _trunc(v, w):
    m = np.int64((1 << w) - 1)
    x = np.asarray(v, dtype=np.int64) & m
    return np.where(x > (1 << (w - 1)) - 1, x - (1 << w), x).astype(np.int64)


def sc_correct_narrow(s_in, c_in, ofs_s, ofs_c, gain_s, gain_c, phase_k,
                      shift_s=0, shift_c=0):
    """按 RTL 的每个中间信号位宽截断的版本（1/2 级）"""
    s1 = _trunc(_trunc(s_in, DWP) - _trunc(ofs_s, DWP), DWP)
    c1 = _trunc(_trunc(c_in, DWP) - _trunc(ofs_c, DWP), DWP)
    ph = _trunc(asr(_trunc(s1 * _trunc(phase_k, DW), DWM), SH), DWC)
    c2 = _trunc(c1 - ph, DWC)
    return s1, c2


def sc_correct_narrow_full(s_in, c_in, ofs_s, ofs_c, gain_s, gain_c, phase_k,
                           shift_s=0, shift_c=0):
    s1, c2 = sc_correct_narrow(s_in, c_in, ofs_s, ofs_c, gain_s, gain_c, phase_k,
                               shift_s, shift_c)
    gp = _trunc(s1 * _trunc(gain_s, DWP), DWS)
    gq = _trunc(c2 * _trunc(gain_c, DWP), DWM2)
    s2 = np.where(shift_s == 0, asr(gp, 15), np.where(shift_s == 1, asr(gp, 14),
                  np.where(shift_s == 2, asr(gp, 13), asr(gp, 12))))
    c3 = np.where(shift_c == 0, asr(gq, 15), np.where(shift_c == 1, asr(gq, 14),
                  np.where(shift_c == 2, asr(gq, 13), asr(gq, 12))))
    s2 = _trunc(s2, DWSH)
    c3 = _trunc(c3, DWSH)
    so = np.where(s2 > SAT_MAX, SAT_MAX, np.where(s2 < SAT_MIN, SAT_MIN, _trunc(s2, DW)))
    co = np.where(c3 > SAT_MAX, SAT_MAX, np.where(c3 < SAT_MIN, SAT_MIN, _trunc(c3, DW)))
    sat = (s2 > SAT_MAX) | (s2 < SAT_MIN) | (c3 > SAT_MAX) | (c3 < SAT_MIN)
    return so.astype(np.int64), co.astype(np.int64), sat


# ==============================================================================
# 2. 闭式标定（与 model/golden_model.py::calibrate 同一套公式，供对照）
#    权威实现在 golden_model.py，本函数只是"和 RTL 放在一起的说明性副本"。
# ==============================================================================
def calibrate(s_n, c_n, ref_q15=None):
    """闭式解：把含误差椭圆映射回圆。

        s = A_s*sin(theta) + O_s
        c = A_c*cos(theta + dphi) + O_c
        O_s = mean(s), O_c = mean(c)
        A_s = sqrt(2*mean((s-O_s)^2)),  A_c = sqrt(2*mean((c-O_c)^2))
        sd  = mean((s-O_s)*(c-O_c)) = -A_s*A_c*sin(dphi)/2
        sin_dp = -2*sd/(A_s*A_c),  cos_dp = sqrt(1-sin_dp^2)
        phase_k(Q1.15) = 32768 * 2*sd/A_s^2
        total_gain_s = ref/A_s,  total_gain_c = ref/(A_c*cos_dp)
        shift = 满足 total_gain/2^shift <= 1.999 的最小 sh (0..3)
        gain(Q1.15) = 32768 * total_gain / 2^shift
    """
    if ref_q15 is None:
        ref_q15 = Q_ONE * 0.80                     # 归一化到 0.8 满幅，留 20% 余量
    s_n = np.asarray(s_n, dtype=float)
    c_n = np.asarray(c_n, dtype=float)
    o_s, o_c = s_n.mean(), c_n.mean()
    s1, c1 = s_n - o_s, c_n - o_c
    a_s = math.sqrt(max(2.0, 2.0 * float((s1 * s1).mean())))
    a_c = math.sqrt(max(2.0, 2.0 * float((c1 * c1).mean())))
    sd = float((s1 * c1).mean())
    sin_dp = float(np.clip(-2.0 * sd / (a_s * a_c), -0.5, 0.5))
    cos_dp = math.sqrt(max(1e-6, 1.0 - sin_dp * sin_dp))
    phase_k = 2.0 * sd / (a_s * a_s)
    tg_s, tg_c = ref_q15 / a_s, ref_q15 / (a_c * cos_dp)

    def _sh(g):
        for k in range(4):
            if g / float(1 << k) <= 1.999:
                return k
        return 3

    sh_s, sh_c = _sh(tg_s), _sh(tg_c)
    return dict(ofs_s=int(round(o_s)), ofs_c=int(round(o_c)),
                gain_s=int(round(np.clip(Q_ONE * tg_s / (1 << sh_s), 0, 65535))),
                gain_c=int(round(np.clip(Q_ONE * tg_c / (1 << sh_c), 0, 65535))),
                phase_k=int(round(np.clip(Q_ONE * phase_k, -32768, 32767))),
                shift_s=sh_s, shift_c=sh_c)


# ==============================================================================
# 3. 度量 + 自检 + 测试台预期数字
# ==============================================================================
def rnd_half_away(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x >= 0.0, np.floor(x + 0.5), np.ceil(x - 0.5)).astype(np.int64)


def quad_err_deg(s, c):
    s = np.asarray(s, float) - float(np.mean(s))
    c = np.asarray(c, float) - float(np.mean(c))
    den = math.sqrt(float((s * s).sum()) * float((c * c).sum()))
    if den <= 0.0:
        return 0.0
    return math.degrees(math.asin(max(-1.0, min(1.0, float((s * c).sum()) / den))))


def radial_max(s, c, r_ideal):
    r = np.sqrt(np.asarray(s, float) ** 2 + np.asarray(c, float) ** 2)
    return float(np.abs(r - r_ideal).max())


def tb_expected_numbers():
    """算出 sim/tb_sc_correct.v 头注释里那张"预期打印结果"表。"""
    A, N = 30000.0, 1024
    th = 2.0 * np.pi * np.arange(N) / float(N)
    S = rnd_half_away(A * np.sin(th))
    C = rnd_half_away(A * np.cos(th))
    K5 = int(round(math.sin(math.radians(5.0)) * Q_ONE))     # 2856
    G12 = int(round(1.2 * Q_ONE))                            # 39322

    cases = []
    cases.append(("(a) 无损伤        ", S, C, 0, 0, Q_ONE, Q_ONE, 0, 0, 0))
    cases.append(("(b) 偏置 +1000 LSB", S + 1000, C + 1000, 1000, 1000, Q_ONE, Q_ONE, 0, 0, 0))
    cases.append(("(c) 增益失配 1.2x ", S, rnd_half_away(C.astype(float) / 1.2),
                  0, 0, Q_ONE, G12, 0, 0, 0))
    cases.append(("(d) 正交误差 5deg ", S, C + asr(S * K5, SH),
                  0, 0, Q_ONE, Q_ONE, K5, 0, 0))

    rows = []
    for nm, si, ci, os_, oc_, gs, gc, pk, shs, shc in cases:
        so, co = sc_correct(si, ci, os_, oc_, gs, gc, pk, shs, shc)
        rows.append((nm, radial_max(si, ci, A), quad_err_deg(si, ci),
                     radial_max(so, co, A), quad_err_deg(so, co)))
    return rows


def main():
    ok = True
    rng = np.random.default_rng(12345)

    print("=" * 74)
    print(" sc_correct_ref : rtl/sc_correct.v 位精确参考模型自检")
    print("=" * 74)

    # ---- 1) 窄位宽 == 宽位宽（验证 RTL 中间位宽足够）----
    n = 200000
    si = rng.integers(-32768, 32768, n)
    ci = rng.integers(-32768, 32768, n)
    os_ = rng.integers(-32768, 32768, n)
    oc_ = rng.integers(-32768, 32768, n)
    gs = rng.integers(0, 65536, n)
    gc = rng.integers(0, 65536, n)
    pk = rng.integers(-32768, 32768, n)
    shs = rng.integers(0, 4, n)
    shc = rng.integers(0, 4, n)
    w1 = sc_correct(si, ci, os_, oc_, gs, gc, pk, shs, shc)
    w2 = sc_correct_narrow_full(si, ci, os_, oc_, gs, gc, pk, shs, shc)
    bad = int(np.sum(w1[0] != w2[0]) + np.sum(w1[1] != w2[1]))
    print(" [1] 窄位宽 RTL 模型 vs 64bit 模型: %d 点, 不一致 %d  -> %s"
          % (n, bad, "OK" if bad == 0 else "FAIL"))
    ok = ok and bad == 0

    # ---- 2) 与 golden_model.py 对照（若可导入）----
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import golden_model as gm
        m = 0
        for k in range(2000):
            r1 = gm.sc_correct(np.array([si[k]]), np.array([ci[k]]), int(os_[k]), int(oc_[k]),
                               int(gs[k]), int(gc[k]), int(pk[k]), int(shs[k]), int(shc[k]))
            r2 = sc_correct(np.array([si[k]]), np.array([ci[k]]), int(os_[k]), int(oc_[k]),
                            int(gs[k]), int(gc[k]), int(pk[k]), int(shs[k]), int(shc[k]))
            if int(r1[0][0]) != int(r2[0][0]) or int(r1[1][0]) != int(r2[1][0]):
                m += 1
        print(" [2] 与 golden_model.sc_correct 逐位对照: 2000 点, 不一致 %d -> %s"
              % (m, "OK" if m == 0 else "FAIL"))
        ok = ok and m == 0
    except Exception as e:
        print(" [2] 未能导入 golden_model.py (%s)" % e)

    # ---- 3) 饱和 ----
    so, co, sat = sc_correct_narrow_full(
        np.array([32767, 32767, -32768]), np.array([32767, -32768, -32768]),
        np.zeros(3, np.int64), np.zeros(3, np.int64),
        np.full(3, 65535), np.full(3, 65535), np.zeros(3, np.int64),
        np.full(3, 3), np.full(3, 3))
    sok = (so.tolist() == [32767, 32767, -32768]) and bool(sat.all())
    print(" [3] 16x 增益饱和: s_out=%s sat=%s -> %s"
          % (so.tolist(), sat.astype(int).tolist(), "OK" if sok else "FAIL"))
    ok = ok and sok

    # ---- 4) 测试台预期数字 ----
    print()
    print(" [4] sim/tb_sc_correct.v 的预期打印数字（R=30000, 1024 点/周期）")
    print("     %-18s %10s %10s | %10s %10s" %
          ("工况", "校正前径向", "校正前正交", "校正后径向", "校正后正交"))
    for nm, rb, qb, ra, qa in tb_expected_numbers():
        print("     %-18s %10.3f %10.4f | %10.3f %10.4f" % (nm, rb, qb, ra, qa))
    print()
    print(" 结论: %s" % ("全部自检通过" if ok else "存在失败项，需检查"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
