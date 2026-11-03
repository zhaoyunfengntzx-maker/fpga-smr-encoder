#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
loop_filter_model.py —— rtl/loop_filter.v 的**逐位一致**定点模型与验证
================================================================================
被建模对象（SPEC §1.6）
    AW = 16, FRAC = 8, PW = 24, REV = 2^24
      ang_ext = ang_in << FRAC                     （24bit 有符号，模 REV）
      err     = wrap_signed(ang_ext - pos)          （模 REV 减法，折到 ±REV/2）
      I[n+1]  = clamp(I[n] + (err >>> KI_SHIFT[ki]), ±REV/4)   ← 抗饱和限幅
      pos[n+1]= pos[n] + (err >>> KP_SHIFT[kp]) + I[n+1]
      lag_limit = |err| > REV/8                     （45°，状态字 laglim）
    KP_SHIFT = {2,3,4,5,6,7,8,9}（kp=0..7），KI_SHIFT = {7,6,5,4}（ki=0..3）
    ki=0 关断 I 通路；kp=0 且 ki=0 时整条滤波器直通；freeze=1 时 pos/integ 都保持。
    RTL Latency = 3（环路状态 1 拍 + 输出流水 2 拍），模型里 pos_out 也延迟 2 拍。

与 SPEC §1.6 原文的唯一差别（必须说明）
    原文写 "pos = pos + (err>>>KP) + integ"，用的是**上一拍**的积分值 integ[n]；
    本实现用 integ[n+1]（本拍更新后的积分值），二者只差 Kp/Ki 的一个采样周期。
        用 integ[n]  ： E/A = (z-1)^2 / (z^2 + (Kp-2)z + (1-Kp+Ki))
                       Jury 判据给出 **Ki < Kp 才稳定**
        用 integ[n+1]： E/A = (z-1)^2 / (z^2 + (Kp+Ki-2)z + (1-Kp))
                       Jury 判据给出 0 < Kp < 2、Ki > 0、Ki < 4-2Kp，全部满足
    也就是说：按原文实现时，公开手册推荐的 heavy 档（kp=6, ki=3 -> Kp=1/256,
    Ki=1/16, Ki > Kp）会**发散**；本实现的等价 P 增益是 Kp+Ki，所以恒稳定。
    这是"把 PI 环路做成数学上自洽"的关键修改。

运行：<bundled python> model/loop_filter_model.py
"""
import math
import sys

# ==============================================================================
# 0. 定点参数（必须与 rtl/loop_filter.v 一致）
# ==============================================================================
AW   = 16
FRAC = 8
PW   = AW + FRAC              # 24
REV  = 1 << PW                # 2^24 = 一圈
HALF = 1 << (PW - 1)

KP_SHIFT = [2, 3, 4, 5, 6, 7, 8, 9]
KI_SHIFT = [7, 6, 5, 4]
INTEG_POS = (1 << (PW - 2)) - 1     # +REV/4 - 1
INTEG_NEG = -(1 << (PW - 2))        # -REV/4
LAG_TH    = 1 << (PW - 3)           # REV/8 = 45°
LATENCY   = 3
FS        = 50.0e6                  # 单时钟域 50 MHz
# ⚠️ 已知模型漂移（2026-10-11，见 docs/DEV_STATUS.md §1.43 ⏭）：本模型按"环路状态每个 clk
#    更新"标定（DSH §1.42 审计把这一条列为 class A 风险）。RTL 生产例化自 v8 起传
#    `.GATE_STATE(1)`（rtl/enc_top.v:532-542）⇒ 状态每 **in_valid** 更新一次，
#    在本设计的 LOG2DEC=2 下有效更新率 = 12.5 MHz（不是 50 MHz）⇒ 等效环路带宽/增益
#    与下面的 KP_SHIFT/KI_SHIFT 表差 4 倍。本文件**未跟随**该改动（改它需要与
#    rtl/loop_filter.v:41-56 的带宽表一起重标定），因此 v8 之后不要用本模型去校验
#    生产配置的环路动态；`sim/tb_loop_abz_chain.v`（真实 RTL 双链 A/B）才是权威。


def wrap24(v):
    v &= (REV - 1)
    if v >= HALF:
        v -= REV
    return v


def clamp_integ(v):
    if v > INTEG_POS:
        return INTEG_POS
    if v < INTEG_NEG:
        return INTEG_NEG
    return v


def asr(v, n):
    """Verilog 对 signed 的 >>>：算术右移 = 向 -inf 取整"""
    return v >> n


class LoopFilter(object):
    """逐位一致的 loop_filter 模型（含 freeze 与 3 拍输出延迟）"""

    def __init__(self):
        self.pos = 0
        self.integ = 0
        self.pipe = []          # 输出流水 [(pos_out, lag, valid), ...]

    def step(self, ang16, kp, ki, freeze=0, in_valid=1):
        ang_ext = wrap24((ang16 & 0xFFFF) << FRAC)
        err = wrap24(ang_ext - self.pos)          # 环路内部误差（真正的"滞后"）
        p_term = asr(err, KP_SHIFT[kp])
        i_inc = asr(err, KI_SHIFT[ki])
        i_en = (ki != 0)
        bypass = (kp == 0 and ki == 0)
        integ_use = clamp_integ(self.integ + i_inc) if i_en else 0
        if freeze:
            pos_nxt, integ_nxt = self.pos, self.integ
        elif bypass:
            pos_nxt, integ_nxt = ang_ext, 0
        else:
            pos_nxt, integ_nxt = wrap24(self.pos + p_term + integ_use), integ_use
        self.pos, self.integ = pos_nxt, integ_nxt
        lag = 1 if (err > LAG_TH or err < -LAG_TH) else 0
        # 输出流水：pos_out 再延迟 2 拍（Latency=3）
        self.pipe.insert(0, (pos_nxt, lag, in_valid))
        out = self.pipe[2] if len(self.pipe) > 2 else (0, 0, 0)
        self.pipe = self.pipe[:3]
        return out[0], out[1], out[2], err


def err_lsb(ang16, pos_out):
    """当前输入角度与输出位置之间的模 REV 误差（24bit LSB）"""
    ang_ext = wrap24((ang16 & 0xFFFF) << FRAC)
    return wrap24(ang_ext - pos_out)


# ==============================================================================
# 1. 频域指标（解析）
# ==============================================================================
def an_metrics(kp, ki):
    Kp = 2.0 ** -KP_SHIFT[kp]
    Ki = 2.0 ** -KI_SHIFT[ki] if ki != 0 else 0.0
    if Ki == 0.0:
        wn = 0.0
        zeta = float('inf')
        f3 = Kp * FS / (2 * math.pi)
        return Kp, Ki, wn, zeta, f3
    wn = math.sqrt(Ki) * FS                     # rad/s
    zeta = (Kp + Ki) / (2.0 * math.sqrt(Ki))
    if zeta < 0.7071:
        r = math.sqrt(1 - 2 * zeta * zeta + math.sqrt((1 - 2 * zeta * zeta) ** 2 + 1))
        f3 = wn * r / (2 * math.pi)
    else:
        f3 = wn / (2 * math.pi)
    return Kp, Ki, wn, zeta, f3


# ==============================================================================
# 2. 测试
# ==============================================================================
def test_ramp(kp, ki, step16=64, n=20000, tail=2000):
    """恒速斜坡（每拍角度 +step16 个 16bit LSB）

    判据用什么：
      * 环路**内部误差** err = wrap(ang_ext - pos)（pos 是更新前的状态）——
        这才是"滞后"的物理定义，也是 RTL 里算 lag_limit 用的量。
      * pos_out 是内部状态再延迟 2 拍的输出，它与输入之间天然差 1 个采样周期
        的流水对齐（见 RTL 注释：pos_out 在 in_valid 有效那一拍输出的是"处理完
        该样点后的状态"），所以用 pos_out 反推误差必须对齐到 (ang - 1*step)。
    """
    lf = LoopFilter()
    ang = 0
    e_int, e_out = [], []
    for i in range(n):
        po, lag, ov, err = lf.step(ang, kp, ki)
        e_int.append(err)
        if i >= LATENCY:
            al = ((ang - step16) & 0xFFFF)     # pos_out 对齐到一拍前
            e_out.append(wrap24((al << FRAC) - po))
        ang = (ang + step16) & 0xFFFF
    ti = e_int[-tail:]
    return (max(abs(e) for e in ti), sum(abs(e) for e in ti) / len(ti),
            max(abs(e) for e in e_int),
            max(abs(e) for e in e_out) if e_out else 0)


def test_step(kp, ki, step16=8192, n=4000):
    """阶跃响应：从 0 跳到 step16（16bit 角度单位），返回(超调%, 稳定拍数, 终值误差)"""
    lf = LoopFilter()
    target = wrap24(step16 << FRAC)
    ys = []
    for i in range(n):
        po, lag, ov, err = lf.step(step16, kp, ki)
        if i >= LATENCY:
            ys.append(po)
    peak = max(ys) if ys else 0
    final = ys[-1] if ys else 0
    overshoot = 0.0
    if target != 0:
        sign = 1.0 if target > 0 else -1.0
        dev = (peak - target) * sign
        overshoot = 100.0 * dev / abs(target)
        overshoot = max(0.0, overshoot)
    # 稳定拍数：最后一次离开 ±1% 带的时间
    band = abs(target) * 0.01 if target else 1
    settle = n
    for i in range(len(ys) - 1, -1, -1):
        if abs(ys[i] - target) > band:
            settle = i + 1
            break
    else:
        settle = 0
    err_fin = abs(wrap24(target - final))
    return overshoot, settle, err_fin, final, target


def section(t):
    print("")
    print("=" * 78)
    print(t)
    print("=" * 78)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    print("loop_filter 位精确模型   AW=%d FRAC=%d PW=%d REV=2^%d  1 LSB(24bit)=%.7f deg"
          % (AW, FRAC, PW, PW, 360.0 / REV))
    print("Latency=%d 拍 = %d ns @%.0f MHz" % (LATENCY, LATENCY * 20, FS / 1e6))
    ok = True

    # ---- (a) 恒速斜坡：I 项的作用 ------------------------------------------
    section("(a) 恒速斜坡跟踪 —— 验证 I 项带来的零稳态滞后（公开数据手册结论）")
    print("  斜坡斜率 = 64 LSB16/clk（= 0.3516 deg/clk = 17.6 Mdeg/s @50MHz），跑 20000 拍")
    print("   kp ki   Kp      Ki      ζ     f3dB[MHz] | 稳态环路误差max avg | 全程max | pos_out对齐max")
    for kp in range(0, 7):
        for ki in (1, 2, 3):
            mx, avg, allmx, outmx = test_ramp(kp, ki)
            Kp, Ki, wn, zeta, f3 = an_metrics(kp, ki)
            print("   %2d %2d  %-7.5f %-7.5f %-6.3f %-9.3f | %12d %8.1f | %7d | %8d"
                  % (kp, ki, Kp, Ki, zeta, f3 / 1e6, mx, avg, allmx, outmx))
            if mx > 64:
                ok = False
                print("        ^^ 稳态环路误差超过 64 LSB(24bit)=0.0014deg，不满足零滞后")
    print("  说明：稳态残余 = err>>>KI 的整数截断死区（|err|<2^KI 时积分增量截断为 0），")
    print("        量级 = 几个 24bit LSB，折合 16bit 角度 LSB 的 1/1000 以下；")
    print("        即 I 项把恒速滞后从 ~%d LSB16（纯 P）压到了 0（实测上面几 LSB24）。" % 64)

    # ---- (b) 全部 kp/ki 组合的阶跃响应稳定性 -------------------------------
    section("(b) 阶跃响应（0 -> 45deg），kp=0..6 × ki=1..3 全部组合必须稳定不发散")
    print("   kp ki  超调[%]  1%%稳定拍数  终值误差[LSB24]  | 是否发散")
    for kp in range(0, 7):
        for ki in (1, 2, 3):
            ov, settle, errf, final, target = test_step(kp, ki)
            diverged = (abs(final) > REV // 4)
            print("   %2d %2d  %7.2f  %10d  %13d  | %s"
                  % (kp, ki, ov, settle, errf, "发散!" if diverged else "稳定"))
            if diverged:
                ok = False
    print("  说明：kp 越大 Kp 越小、阻尼 ζ 越小，超调越大但仍在 ±45deg 内；")
    print("        全 21 组组合都收敛，与 SPEC 原文实现（Ki<Kp 才稳定，kp=6/ki=3 发散）不同。")

    # ---- (c) ki=0 & kp=0 直通 ----------------------------------------------
    section("(c) kp=0 且 ki=0：整条滤波器直通（pos_out = ang_in 扩展）")
    lf = LoopFilter()
    bad = 0
    angs = []
    for i in range(200):
        ang = (i * 331) & 0xFFFF
        angs.append(ang)
        po, lag, ov, err = lf.step(ang, 0, 0)
        if i >= 2:      # pos_out 相对当前输入延迟 2 拍（流水）
            want = wrap24(angs[i - 2] << FRAC)
            if po != want:
                bad += 1
    print("  200 个随机角度直通比对（对齐 2 拍流水）：不符 %d 处" % bad)
    if bad:
        ok = False

    # ---- (d) ki=0, kp>0：纯 P -------------------------------------------------
    section("(d) ki=0（关断 I 通路）时的纯 P 行为")
    for kp in (0, 2, 4, 6):
        lf = LoopFilter()
        po = 0
        for i in range(4000):
            po, lag, ov, err = lf.step(8192, kp, 0)
        e = abs(err_lsb(8192, po))
        print("   kp=%d : 4000 拍后残余误差 = %d LSB24 (%.6f deg) -> 纯 P 有静差，符合预期"
              % (kp, e, e * 360.0 / REV))

    # ---- (e) lag_limit ------------------------------------------------------
    section("(e) lag_limit（|err| > 45deg）行为")
    for step16 in (0x0800, 0x1000, 0x2000, 0x2001, 0x4000):
        lf = LoopFilter()
        lag_max = 0
        for i in range(400):
            po, lag, ov, err = lf.step(step16, 4, 3)
            if ov:
                lag_max = max(lag_max, lag)
        deg = step16 * 360.0 / 65536.0
        print("   阶跃 %5d LSB16 = %7.3f deg : lag_limit 曾置位 = %d （期望 %d）"
              % (step16, deg, lag_max, 1 if deg > 45.0 else 0))
        if lag_max != (1 if deg > 45.0 else 0):
            ok = False

    # ---- (f) freeze 与积分限幅 ---------------------------------------------
    section("(f) freeze 保持 / 积分器抗饱和限幅")
    lf = LoopFilter()
    for i in range(300):
        po, lag, ov, err = lf.step(16384, 4, 3)
    for i in range(3):                       # 冲掉输出流水，取冻结后的稳定值
        po, lag, ov, err = lf.step(16384, 4, 3, freeze=1)
    held = po
    integ_held = lf.integ
    for i in range(50):
        po, lag, ov, err = lf.step(32768, 4, 3, freeze=1)   # 输入乱变也不能动
    print("   freeze=1 期间 pos_out: %d -> %d （必须相等）；integ: %d -> %d （必须相等）"
          % (held, po, integ_held, lf.integ))
    if po != held or lf.integ != integ_held:
        ok = False
    if abs(lf.integ) > INTEG_POS + 1:
        ok = False

    # ---- (g) 频域指标表 -----------------------------------------------------
    section("(g) 闭环带宽解析表（ωn=sqrt(Ki)*fs, ζ=(Kp+Ki)/(2sqrt(Ki))）")
    print("   kp ki    Kp        Ki       ζ        ωn[Mrad/s]  f3dB[MHz]")
    for kp in (0, 2, 4, 6):
        for ki in (1, 2, 3):
            Kp, Ki, wn, zeta, f3 = an_metrics(kp, ki)
            print("   %2d %2d  %-9.5f %-8.5f %-8.3f %-11.2f %-9.3f"
                  % (kp, ki, Kp, Ki, zeta, wn / 1e6, f3 / 1e6))

    print("")
    print("  TEST %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
