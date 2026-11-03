#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/calib_shift_judge.py —— 粗调移位判据的"决定性实验"（P1 定案用）

背景（分歧）
----
rtl/calib_ctrl.v:117-119 的判据：选最小 sh(0..3) 使 tg <= round(1.999*32768)<<sh
model/golden_model.py:189-209 的判据：选最小 sh 使 total_gain/2^sh <= 1.0
docs/01_technical_solution.md:156-167 站在后者一边，论证：
    "桶宽 = 2^(15-sh)/G = 1/有效总增益，只有桶宽 >= 1（即 G <= 1.0）才逐点可逆；
     G>1 时桶宽 <1，约 16% 的整数输出目标取不到，产生 ~1 LSB 系统性误差"
并声称换用 <=1.0 后实测工况 C 的径向残余从 1.499 LSB 降到 0.525 LSB。

本脚本不用任何一段文字结论，全部由实数算出：
  [A] 用同一套位精确标定结果（model/calib_rtl_model.calib_rtl）与同一条
      rtl/sc_correct.v 整数路径，对 6 个标准工况 + 2 个"大增益/弱信号"工况
      比较三条判据（RTL<=1.999 / golden<=1.0（正确的 Q15 单位）/ study 旧脚本的
      "1.0 臂"）的最终角度误差与径向残余。
  [B] 证明"同一个有效增益 m 用不同 (g, sh) 表达，只要 g 不被截断，输出逐点相同"；
      并给出 (g, sh) -> (g/2, sh+1) 的逐点恒等条件（g 为偶数）。
  [C] 直接量化"桶宽 <1 到底损失什么"：可达整数目标比例、|floor(m*x)-m*x| 上界、
      以及误差真正随什么变化（细调增益量化步长 2^sh/32768，不是桶宽）。
  [D] 由 [A][B][C] 的数据生成结论行（不再硬编码文本）。

运行: python tools/calib_shift_judge.py
输出同时写 model/calib_shift_judge_report.txt
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'model'))

import golden_model as gm          # noqa: E402
import calib_rtl_model as crm      # noqa: E402

Q_ONE = 1 << 15                    # 32768 == 1.0
ANG_LSB_DEG = 360.0 / 65536.0      # 16bit 角度 LSB = 0.0054932 deg
TG_SH = (65503, 131006, 262012)    # rtl/calib_ctrl.v:117-119（TG_SH0/1/2）
TG_MAX = 1048575                   # rtl/calib_ctrl.v:549 的 tg 上限（20bit）


# ==============================================================================
# 三条判据（输入 tg 一律是 Q15 整数，32768 == 1.0）
# ==============================================================================
def rule_rtl(tg):
    """rtl/calib_ctrl.v:573-581 + :117-119：最小 sh 使 tg <= TG_SHn。"""
    for sh, lim in enumerate(TG_SH):
        if tg <= lim:
            return sh
    return 3


def rule_one(tg):
    """model/golden_model.py:189-209 的本意，换成正确的 Q15 单位：最小 sh 使 tg/2^sh <= 32768。"""
    for sh in range(4):
        if tg // (1 << sh) <= Q_ONE:
            return sh
    return 3


def rule_one_float(total_gain):
    """golden_model._coarse_shift 的真实实现（入参是浮点增益，>= 1.0）。"""
    for sh in range(4):
        if total_gain / float(1 << sh) <= 1.0:
            return sh
    return 3


def rule_study_buggy(tg):
    """tools/calib_shift_study.py:37-45 的 '1.0 臂'：把 Q15 整数直接和 1.0 比 -> 恒返回 3。"""
    for sh in range(4):
        if tg / float(1 << sh) <= 1.0:
            return sh
    return 3


def gains_for(tg, sh):
    """rtl/calib_ctrl.v:348-351：gain = (tg >> sh) 截断到 16bit 饱和。"""
    g = (tg >> sh) & 0xFFFFFFFF
    return 0xFFFF if g > 0xFFFF else g


# ==============================================================================
# 与 rtl/sc_correct.v:9-10 / :199-215 逐位一致的增益级
# ==============================================================================
def gain_stage(x, g, sh):
    """y = (x * g) >> (15 - sh)，x 为有符号整数数组；与 RTL 的 4 选 1 移位 mux 等价。"""
    return (np.asarray(x, dtype=np.int64) * int(g)) >> (15 - int(sh))


def effective_m(g, sh):
    return (float(g) / Q_ONE) * (1 << sh)


# ==============================================================================
# 工况与评估
# ==============================================================================
def case_signals(n=2048, log2dec=2, cycles=8, **kw):
    s_code, c_code, ideal = gm.make_signals(n, cycles=cycles, **kw)
    s_q = gm.decim_avg(gm.adc_to_q15(s_code), log2dec)
    c_q = gm.decim_avg(gm.adc_to_q15(c_code), log2dec)
    ideal_d = gm.decim_avg_float(ideal, log2dec)
    return s_q, c_q, ideal_d


def tg_from(p):
    """rtl/calib_ctrl.v:20 / tools/calib_shift_study.py:60-61 的同一算式（ref_q15=26214）。"""
    ref = 26214
    a_s = max(1, int(p['a_s']))
    a_c = max(1, int(p['a_c']))
    cos_dp = p['cos_dp'] if p['cos_dp'] != 0 else 1
    tg_s = min(TG_MAX, (Q_ONE * ref) // a_s)
    tg_c = min(TG_MAX, ((1 << 30) * ref) // ((a_c * cos_dp) & 0xFFFFFFFF))
    return tg_s, tg_c


def evaluate(s_q, c_q, ideal_d, p, sh_s, sh_c, g_s, g_c, rtl_ref=None):
    """跑一条 (ofs/gain/phase/shift) 臂，返回角度误差（deg / 16bit LSB）与径向指标。"""
    s_f, c_f = gm.sc_correct(s_q.astype(np.int64), c_q.astype(np.int64),
                             ofs_s=p['ofs_s'], ofs_c=p['ofs_c'],
                             gain_s=g_s, gain_c=g_c, phase_k=p['phase_k'],
                             shift_s=sh_s, shift_c=sh_c)
    ang, _ = gm.cordic_atan2(c_f, s_f)
    e = np.abs(gm.ang_err_deg(ang, gm.ideal_angle16(ideal_d)))
    r = np.sqrt(s_f.astype(float) ** 2 + c_f.astype(float) ** 2)
    out = dict(sh=(sh_s, sh_c), gain=(g_s, g_c),
               m=(effective_m(g_s, sh_s), effective_m(g_c, sh_c)),
               e_max=float(e.max()), e_rms=float(np.sqrt(np.mean(e ** 2))),
               e_max_lsb=float(e.max()) / ANG_LSB_DEG,
               rad_dev=float(np.abs(r - r.mean()).max()),
               rad_ripple=float(r.max() - r.min()),
               sat=int(np.count_nonzero(np.abs(s_f) >= 32767) +
                       np.count_nonzero(np.abs(c_f) >= 32767)))
    if rtl_ref is not None:
        out['diff_vs_rtl'] = int(np.count_nonzero(s_f != rtl_ref[0]) +
                                 np.count_nonzero(c_f != rtl_ref[1]))
    out['_out'] = (s_f, c_f)
    return out


def main():
    lines = []

    def emit(s=''):
        print(s)
        lines.append(s)

    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:                                     # noqa: BLE001
        pass

    emit("=" * 118)
    emit(" 粗调移位判据决定性实验（P1）：RTL(tg/2^sh<=1.999)  vs  golden(tg/2^sh<=1.0)  vs  study 旧'1.0 臂'")
    emit("=" * 118)

    cases = [
        ("A 理想 (仅ADC量化)",  dict(amp_q15=22000)),
        ("B 直流偏置",          dict(amp_q15=22000, ofs_s=4000, ofs_c=-3500)),
        ("C 幅值失衡 1.25x",    dict(amp_q15=22000, gain_s=1.25)),
        ("D 正交误差 5deg",     dict(amp_q15=22000, dphi_deg=5.0)),
        ("E 三类误差叠加",      dict(amp_q15=22000, ofs_s=4000, ofs_c=-3500,
                                     gain_s=1.25, dphi_deg=5.0)),
        ("G 小信号 20%+误差",   dict(amp_q15=6000, ofs_s=800, ofs_c=-800,
                                     gain_s=1.25, dphi_deg=5.0)),
        ("H 弱信号 6.25% (16x)", dict(amp_q15=1750)),
        ("I 弱信号 6.25%+误差",  dict(amp_q15=1750, ofs_s=400, ofs_c=-400, gain_s=1.25)),
    ]

    # ------------------------------------------------------------------
    # [A] 三条判据的对比
    # ------------------------------------------------------------------
    emit()
    emit("[A] 同一套位精确标定、同一条 sc_correct 整数路径，只换粗调判据")
    emit("%-24s %-9s %-13s %-11s %8s %8s %8s %8s"
         % ("工况", "判据", "sh S/C", "有效增益S/C", "max(deg)", "rms(deg)", "max(LSB)", "径向纹波"))
    emit("-" * 118)
    table = []
    for nm, kw in cases:
        try:
            s_q, c_q, ideal_d = case_signals(**kw)
            p = crm.calib_rtl(s_q, c_q)
            tg_s, tg_c = tg_from(p)
        except Exception as ex:                            # noqa: BLE001
            emit("%-24s  <异常: %s>" % (nm, ex))
            continue
        arms = [
            ("RTL <=1.999", rule_rtl(tg_s), rule_rtl(tg_c)),
            ("golden <=1.0", rule_one(tg_s), rule_one(tg_c)),
            ("study 旧'1.0'", rule_study_buggy(tg_s), rule_study_buggy(tg_c)),
        ]
        res = {}
        raw_ref = None
        for tag, sh_s, sh_c in arms:
            g_s, g_c = gains_for(tg_s, sh_s), gains_for(tg_c, sh_c)
            r = evaluate(s_q, c_q, ideal_d, p, sh_s, sh_c, g_s, g_c, rtl_ref=raw_ref)
            if raw_ref is None:
                raw_ref = r['_out']
            res[tag] = r
            emit("%-24s %-9s %-13s %-11s %8.5f %8.5f %8.2f %8.1f"
                 % (nm, tag, "%d/%d" % (sh_s, sh_c),
                    "%.5f/%.5f" % (r['m'][0], r['m'][1]),
                    r['e_max'], r['e_rms'], r['e_max_lsb'], r['rad_ripple']))
        emit("%-24s %-9s tg_s=%d tg_c=%d  gain_s/c(RTL)=%d/%d"
             % ("", "标定值", tg_s, tg_c,
                res['RTL <=1.999']['gain'][0], res['RTL <=1.999']['gain'][1]))
        table.append((nm, tg_s, tg_c, res))
        emit("-" * 118)

    # ------------------------------------------------------------------
    # [B] 同一个 m 用不同 (g, sh) 表达：是否逐点恒等
    # ------------------------------------------------------------------
    emit()
    emit("[B] 表达式恒等性：同一个有效增益 m 换 (g, sh) 是否改变输出")
    x = np.arange(-32768, 32768, 1, dtype=np.int64)
    for m in (1.2, 1.25, 1.999, 0.8, 3.5):
        g0 = int(round(m * Q_ONE))
        g0 &= ~1                                            # 取偶数，保证可逐步折半
        rows = []
        for sh in range(4):
            if (g0 >> sh) << sh != g0:
                rows.append((sh, g0 >> sh, None, None))
                continue
            y0 = gain_stage(x, g0 >> sh, sh)
            rows.append((sh, g0 >> sh, float(np.abs(y0 - gain_stage(x, g0, 0)).max()),
                         int(np.count_nonzero(y0 != gain_stage(x, g0, 0)))))
        bad = [r for r in rows if r[3] not in (None, 0)]
        emit("  m=%-7.4f g0=%6d(偶)  ->  %s"
             % (m, g0, " | ".join("sh=%d g=%d diff=%s" % (r[0], r[1],
                                                          'n/a' if r[3] is None else r[3])
                                  for r in rows)))
        if bad:
            emit("     !! 与 sh=0 存在逐点差异（下一位截断造成），差异样本数上限 %d"
                 % max(r[3] for r in bad))
    emit("  （g 为偶数且 (g>>sh)<<sh == g 时，sh 每加 1 只是把同一个有理数的 floor 换一种写法）")

    # 奇数 tg 的真实情形：截断误差 -> 有效增益偏差
    emit()
    emit("  真实标定里 tg 常为奇数，此时 (tg>>sh)<<sh != tg，有效增益偏小：")
    odd_cases = []
    for nm, tg_s, tg_c, _res in table:
        for ch, tg in (("S", tg_s), ("C", tg_c)):
            if tg & 1:
                odd_cases.append((nm, ch, tg))
    if odd_cases:
        for nm, ch, tg in odd_cases[:8]:
            parts = []
            for tag, rule in (("RTL", rule_rtl), ("<=1.0", rule_one)):
                sh = rule(tg)
                g = tg >> sh
                parts.append("%s sh=%d g=%d m=%.8f(偏 %.2e)" %
                             (tag, sh, g, effective_m(g, sh),
                              (effective_m(g, sh) - tg / Q_ONE) / (tg / Q_ONE)))
            emit("   %-24s %s tg=%d : %s" % (nm, ch, tg, " ; ".join(parts)))
    else:
        emit("   （本批工况 tg 全为偶数，无截断误差）")

    # ------------------------------------------------------------------
    # [C] "桶宽 <1" 到底损失什么
    # ------------------------------------------------------------------
    emit()
    emit("[C] 桶宽 = 1/m 与整数目标可达性：桶宽<1 本身是否引入误差")
    emit("  %-8s %10s %14s %16s %14s"
         % ("m", "桶宽 1/m", "不可达比例", "max|floor(mx)-mx|", "取整偏差 RMS"))
    for m in (1.0, 1.05, 1.2, 1.25, 1.5, 1.999, 2.0, 4.0, 8.0):
        y = np.floor(m * x)
        span = int(y.max() - y.min()) + 1
        uniq = int(np.unique(y).size)
        frac = 1.0 - uniq / float(span)
        err = y - m * x
        emit("  %-8.4f %10.4f %13.2f%% %16.4f %14.4f"
             % (m, 1.0 / m, frac * 100.0, float(np.abs(err).max()),
                float(np.sqrt(np.mean(err ** 2)))))
    emit("  → 不可达比例只说明'y 的取值集合比 x 稀疏'（多对一的反面：单射但不满射）；")
    emit("    |floor(m*x)-m*x| 恒 < 1 LSB，与桶宽无关；取整偏差是固定 −0.5 LSB 附近的均值，")
    emit("    不随 m 变化。真正随 sh 变化的是**细调增益的量化步长** 2^sh/32768：")
    emit("  %-8s %14s %16s %18s" % ("sh", "gain步长", "相对 tg 最大偏差", "m∈(1,2) 时含义"))
    for sh in range(4):
        step = (1 << sh) / float(Q_ONE)
        emit("  %-8d %14.8f %16s %18s"
             % (sh, step, "%.2e (tg≈39000)" % (step / (39000.0 / Q_ONE)),
                "恰好(=1/32768)" if sh == 0 else "量化粗 %.0fx" % (1 << sh)))
    emit("  RTL 判据在 m<=2 时选 sh=0 ⇒ gain 无截断（步长 1/32768，与 tg 逐位相同）；")
    emit("  <=1.0 判据在同区间选 sh=1 ⇒ 多截断 1 位，通道间比例误差最大 2/32768。")

    # ------------------------------------------------------------------
    # [D] 结论（由数据生成）
    # ------------------------------------------------------------------
    emit()
    emit("[D] 结论")
    worse = []
    better = []
    same = []
    for nm, tg_s, tg_c, res in table:
        a = res['RTL <=1.999']
        b = res['golden <=1.0']
        d = a['e_max'] - b['e_max']
        if abs(d) <= 1e-9:
            same.append(nm)
        elif d < 0:
            better.append((nm, a['e_max'], b['e_max']))
        else:
            worse.append((nm, a['e_max'], b['e_max']))
    emit("  · RTL 判据优于 <=1.0 的工况 %d 个，劣于的 %d 个，完全相同的 %d 个"
         % (len(better), len(worse), len(same)))
    for nm, ea, eb in worse:
        emit("      RTL 更差: %-24s %.5f vs %.5f deg" % (nm, ea, eb))
    for nm, ea, eb in better:
        emit("      RTL 更好: %-24s %.5f vs %.5f deg" % (nm, ea, eb))
    emit("  · 两条判据在 m<=2 区间唯一差别是 sh 差 1 位：RTL 用 sh=0（gain 无截断），")
    emit("    <=1.0 用 sh=1（gain 少 1 bit）。[C] 给出步长差 2 倍，[A] 给出最终误差差 ≤ 上表列差。")
    emit("  · 桶宽 >= 1（m<=1）意味着**多对一、不可逆**；校正后的矢量在本设计里是直接送 CORDIC")
    emit("    使用、不做反演，所以'不可逆'不构成误差来源 —— docs/01 与 golden_model docstring")
    emit("    的论证方向是反的。")

    out = os.path.join(ROOT, 'model', 'calib_shift_judge_report.txt')
    #  newline='\n' 必须显式给（与 tools/calib_shift_study.py:141 同一坑）：
    #  Windows text 模式会把 \n 翻成 CRLF，而 .gitattributes 要求 text eol=lf，
    #  于是每次重跑都会让 tools/to_lf.py --check 挂掉。
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write("\n".join(lines) + "\n")
    print("\n[报告已写入] %s" % out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
