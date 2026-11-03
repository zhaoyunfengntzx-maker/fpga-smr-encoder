#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cordic_model.py —— rtl/cordic_atan2.v 的**逐位一致（bit-accurate）**定点模型
================================================================================
被建模对象
    rtl/cordic_atan2.v   （SPEC_interface_contract.md §1.5，全流水向量模式 CORDIC）
        AW = 16, IW = 16, ZW = AW + 4 = 20
        NITER = 17（契约默认 16，见下"设计取舍"）
        IXW = IW + 3 + FEXT = 23（x/y 内部位宽，FEXT = 4 位附加小数）
        Latency = 1（象限折叠） + NITER + 1（输出寄存） = NITER + 2 = 19 拍

模型与 RTL 的一致性要点（逐条对应 RTL 里的写法）
    1. 象限折叠：使折叠后的 x0 **恒 >= 0**，把矢量压进 ±90°
           Q1/Q4 (x>=0)      : x0 =  x, y0 =  y, base =   0
           Q2   (x<0, y>=0)  : x0 =  y, y0 = -x, base = +90deg (2^ZW/4)
           Q3   (x<0, y< 0)  : x0 = -y, y0 =  x, base = -90deg
       ★ SPEC §1.5 原文写的是 Q2: x0=-y,y0=+x / Q3: x0=+y,y0=-x，即把 Q2/Q3 的
         折叠矢量整体取反（差 180°），于是 x0<0：而向量模式的折叠判据
         `d=~y[MSB]` 只在 x>0 时才是"朝 y=0 收敛"的正确方向，x0<0 时矢量被推向
         反方向、最终收敛到 +x 轴而不是 -x 轴，输出**整体偏 180°**（第 6 节有
         实测对照：100°/135°/170° 三点偏差 -110°/-145°/-180°）。因此本项目与
         model/golden_model.py::cordic_atan2 一致，把 Q2/Q3 的 x0/y0 各自取反，
         保证 x0>=0，base 仍按 SPEC 取 ±90°。
    2. 迭代：d = (y >= 0) ? 1 : 0
           x[i+1] = d ? (x + (y >>> i)) : (x - (y >>> i))
           y[i+1] = d ? (y - (x >>> i)) : (y + (x >>> i))
           z[i+1] = d ? (z + ATAN[i])   : (z - ATAN[i])
       所有 `>>> i` 都是**向零截断**：sh(v,i) = sign(v)*(|v|>>i)。
       （Verilog 的 `>>>` 对负数是 floor：-3>>>1 = -2，向零截断应为 -1。）
    3. 内部位宽：x/y = IXW = IW+3+FEXT = 23 bit 有符号，z = ZW = 20 bit 有符号。
       本模型对每级寄存器做二补数回绕（wrap），并统计是否真的发生回绕。
    4. 输出 angle = (z + 2^(ZW-AW-1)) >>> (ZW-AW) 取低 AW 位 = (z+8)>>>4 & 0xFFFF，
       即四舍五入（round-half-up）。SPEC 原文是直接 `>> 4`（截断），实测会带来
       固定 -0.5 LSB 偏置，见第 8 节。
    5. mag = sat18( (|x[NITER]| >> FEXT) * MAG_COEF >>> 17 ),
       MAG_COEF = 79604 = round(2^17/1.6467602)，即 1/1.6468 增益补偿。

设计取舍（用本脚本第 5.5 节的扫描数据说话，1/16 LSB 细网格全圆 1048576 点）
    NITER=16 + SPEC 印出的表        : max 1.3125 LSB   ← 不达标
    NITER=16 + 契约定义式取整表      : max 1.1875 LSB   ← 不达标
    NITER=17 + SPEC 印出的表        : max 1.1875 LSB   ← 不达标
    NITER=17 + 契约定义式取整表      : max 0.9375 LSB   ← **采用**
    原因：16 级时误差下限 = 输出四舍五入 0.5 + 残余旋转 atan(2^-15) 0.318
          + 输入矢量 16bit 量化 0.16 = 0.978 LSB，再叠加 20bit ATAN 常量的
          取整误差（非均匀、±0.15 LSB）就必然超过 1 LSB；17 级把残余旋转减半
          （atan(2^-16)=0.159），才把峰值压到 1 LSB 以下。
    SPEC 表第 2/4/8 项（40881/10416/651）与 SPEC 自己给出的定义式
    ATAN[i]=round(atan(2^-i)*2^ZW/(2*PI)) 不符（应为 40884/10417/652），
    三项合计带来 0.31 LSB 的系统偏置；RTL 里用 parameter ATAN_SRC 选择。

运行（本机唯一可执行的验证手段，无仿真器）
    <bundled python> model/cordic_model.py
"""
import math
import sys

import numpy as np

# ==============================================================================
# 0. 全局定点参数（必须与 rtl/cordic_atan2.v 完全一致）
# ==============================================================================
AW        = 16                       # 输出角度位宽，2^AW = 一个 sin/cos 周期
IW        = 16                       # 输入位宽（Q1.15 有符号）
NITER     = 17                       # CORDIC 迭代级数（契约默认 16，见文件头）
ZW        = AW + 4                   # 20，内部角度累加器位宽
FEXT      = 4                        # x/y 附加内部小数位（只加内部位宽）
IXW       = IW + 3 + FEXT            # 23，内部 x/y 位宽（有符号）
SHIFT_OUT = ZW - AW                  # 4
HALF_OUT  = 1 << (SHIFT_OUT - 1)     # 8，输出四舍五入用的半 LSB
ANG_FULL  = 1 << AW                  # 65536
ANG_LSB_DEG = 360.0 / ANG_FULL       # 0.005493164062500 deg
MAG_COEF  = 79604                    # round(1/1.6467602 * 2^17)  Q0.17
MAG_SHIFT = 17
MAG_W     = IW + 2                   # 18，mag 端口位宽
LATENCY   = 1 + NITER + 1            # 19
AMP_FULL  = (1 << (IW - 1)) - 1      # 32767，Q1.15 满幅

# SPEC §1.5 表格里**印出来的** 20bit 标度 ATAN 常量（逐字复制）
ATAN_TABLE_SPEC = [131072, 77376, 40881, 20753, 10416, 5213, 2607, 1304,
                   651, 326, 163, 81, 41, 20, 10, 5]
# SPEC §1.5 同时给出的**定义式** round(atan(2^-i)*2^ZW/(2*PI)) 的取值（NITER 项）
ATAN_TABLE_ROUND = [int(round(math.atan(2.0 ** -i) / (2.0 * math.pi) * (1 << ZW)))
                    for i in range(NITER)]
# RTL 里对应 parameter ATAN_SRC：0 = SPEC 印出的数字，1 = 契约定义式取整值
ATAN_SRC = "round"
ATAN_TABLE = ATAN_TABLE_ROUND if ATAN_SRC == "round" else ATAN_TABLE_SPEC


def atan_tab_of(niter, src):
    """按 (级数, 表来源) 生成 ATAN 常量表；i>=16 的项按契约定义式外推"""
    if src == "spec":
        t = list(ATAN_TABLE_SPEC)
        while len(t) < niter:
            i = len(t)
            t.append(int(round(math.atan(2.0 ** -i) / (2.0 * math.pi) * (1 << ZW))))
        return t[:niter]
    return [int(round(math.atan(2.0 ** -i) / (2.0 * math.pi) * (1 << ZW)))
            for i in range(niter)]


# ==============================================================================
# 1. 基本定点算子
# ==============================================================================
def trunc_shift(v, n):
    """向零截断的算术右移，等价于 RTL 里的
       y_sh = y[MSB] ? -((~y + 1'b1) >>> n) : (y >>> n)"""
    if v >= 0:
        return v >> n
    return -((-v) >> n)


def wrap(v, bits):
    """模拟 Verilog 中 bits 位寄存器的回绕（有符号二补数）"""
    m = (1 << bits) - 1
    v &= m
    if v >= (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def sat_signed(v, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return lo if v < lo else (hi if v > hi else v)


def ang_diff(a, b):
    """两个 16bit 角度的最小有符号差（LSB，整数）"""
    d = (a - b) & (ANG_FULL - 1)
    if d > (ANG_FULL >> 1):
        d -= ANG_FULL
    return d


def ang_err_cont(a, deg):
    """输出角度(整数码) 相对**连续理想角度** deg 的误差（LSB，浮点）"""
    d = a - (deg % 360.0) / 360.0 * ANG_FULL
    d -= ANG_FULL * round(d / ANG_FULL)
    return d


def angle_of(x, y):
    """整数矢量 (x,y) 的精确角度（16bit 归一化，四舍五入）。仅作参考基准"""
    a = math.atan2(y, x) / (2.0 * math.pi) * ANG_FULL
    return int(round(a)) & (ANG_FULL - 1)


# ==============================================================================
# 2. 核心：逐位一致的 CORDIC
# ==============================================================================
def cordic_atan2(x_in, y_in, fold="fixed", register=True, sat_mag=True,
                 f_ext=None, niter=None, atan=None):
    """
    输入 : x_in = cos 分量 (int16 Q1.15), y_in = sin 分量 (int16 Q1.15)
    输出 : (angle16, mag, debug)
    fold = "fixed" : 与 rtl/cordic_atan2.v 一致（x0 >= 0，正确）
    fold = "spec"  : SPEC §1.5 原文直译（x0 <= 0），仅用于对照（第 6 节）
    """
    if f_ext is None:
        f_ext = FEXT
    if niter is None:
        niter = NITER
    if atan is None:
        atan = ATAN_TABLE
    dbg = {"max_abs_x": 0, "max_abs_y": 0, "max_abs_z": 0, "z_wrap": 0}
    x_in = int(x_in)
    y_in = int(y_in)
    negx, negy = x_in < 0, y_in < 0

    # ---- 象限折叠（同时左移 f_ext 位，只增加内部小数精度） -------------------
    if fold == "fixed":
        if not negx:
            x0, y0, base = x_in, y_in, 0
        elif not negy:
            x0, y0, base = y_in, -x_in, (1 << (ZW - 2))
        else:
            x0, y0, base = -y_in, x_in, -(1 << (ZW - 2))
    elif fold == "spec":
        if not negx:
            x0, y0, base = x_in, y_in, 0
        elif not negy:
            x0, y0, base = -y_in, x_in, (1 << (ZW - 2))
        else:
            x0, y0, base = y_in, -x_in, -(1 << (ZW - 2))
    else:
        raise ValueError("fold 只能是 'fixed' 或 'spec'")

    x, y, z = x0 << f_ext, y0 << f_ext, base
    ixw = IW + 3 + f_ext

    # ---- NITER 级迭代（每级 1 拍） ------------------------------------------
    for i in range(niter):
        ys = trunc_shift(y, i)
        xs = trunc_shift(x, i)
        d = 1 if y >= 0 else 0
        if d:
            x_n, y_n, z_n = x + ys, y - xs, z + atan[i]
        else:
            x_n, y_n, z_n = x - ys, y + xs, z - atan[i]
        if register:
            x_n = wrap(x_n, ixw)
            y_n = wrap(y_n, ixw)
            z_w = wrap(z_n, ZW)
            if z_w != z_n:
                dbg["z_wrap"] += 1
            z_n = z_w
        x, y, z = x_n, y_n, z_n
        dbg["max_abs_x"] = max(dbg["max_abs_x"], abs(x))
        dbg["max_abs_y"] = max(dbg["max_abs_y"], abs(y))
        dbg["max_abs_z"] = max(dbg["max_abs_z"], abs(z))

    # ---- 输出（1 拍寄存） ---------------------------------------------------
    angle = ((z + HALF_OUT) >> SHIFT_OUT) & (ANG_FULL - 1)
    mag = ((abs(x) >> f_ext) * MAG_COEF) >> MAG_SHIFT
    if sat_mag and mag > (1 << MAG_W) - 1:
        mag = (1 << MAG_W) - 1
    dbg["z_pre_round"] = z
    return angle, mag, dbg


# ==============================================================================
# 3. 测试矢量与扫描
# ==============================================================================
def vector_at(deg, amp=AMP_FULL):
    """由理想角度生成 Q1.15 整数测试矢量"""
    r = math.radians(deg % 360.0)
    return int(round(amp * math.cos(r))), int(round(amp * math.sin(r)))


def sweep(angles_deg, amp=AMP_FULL, f_ext=None, niter=None, atan=None):
    """
    三种参考基准（单位 LSB，1 LSB = 360/2^16 = 0.0054932 deg）：
      err_cont : 输出码 - **连续理想角度**（保留小数）。芯片真实角度误差，
                 含 输入矢量 16bit 量化 + CORDIC 算法误差 + 输出 ±0.5LSB 量化。
      err_vec  : 输出码 - 量化后输入矢量 (x_q,y_q) 的精确角度。去掉输入量化。
      err_nom  : 输出码 - 16bit 整数化名义角 round(theta/360*2^16)。整数参考表
                 口径，参考角自身带 ±0.5 LSB 量化，数值虚高，仅用于 tb 交叉核对。
    """
    ec, en, ev, mg, mr = [], [], [], [], []
    dbg_max = {"max_abs_x": 0, "max_abs_y": 0, "max_abs_z": 0, "z_wrap": 0}
    for deg in angles_deg:
        xi, yi = vector_at(deg, amp)
        a, m, d = cordic_atan2(xi, yi, f_ext=f_ext, niter=niter, atan=atan)
        dth = (deg % 360.0) / 360.0 * ANG_FULL
        ec.append(ang_err_cont(a, deg))
        en.append(ang_diff(a, int(round(dth)) & (ANG_FULL - 1)))
        ev.append(ang_diff(a, angle_of(xi, yi)))
        mg.append(m)
        mr.append(math.hypot(xi, yi))
        for k in dbg_max:
            dbg_max[k] = max(dbg_max[k], d[k])
    return {"err_cont": np.array(ec), "err_nom": np.array(en, dtype=np.int64),
            "err_vec": np.array(ev, dtype=np.int64),
            "mag": np.array(mg, dtype=np.int64),
            "mag_ref": np.array(mr), "dbg": dbg_max}


def scan_max(angles_deg, f_ext=None, niter=None, atan=None):
    """只求 max|e_cont| / RMS，用于设计取舍扫描"""
    mx, rms, where = 0.0, 0.0, 0.0
    for deg in angles_deg:
        xi, yi = vector_at(deg)
        a, _, _ = cordic_atan2(xi, yi, f_ext=f_ext, niter=niter, atan=atan)
        e = abs(ang_err_cont(a, deg))
        if e > mx:
            mx, where = e, deg
        rms += e * e
    return mx, where, math.sqrt(rms / len(angles_deg))


def stat(arr, name, angles=None):
    a = np.abs(np.asarray(arr, dtype=np.float64))
    i = int(np.argmax(a))
    rms = float(np.sqrt(np.mean(np.asarray(arr, dtype=np.float64) ** 2)))
    loc = ("  @ %.5f deg" % (angles[i] % 360.0)) if angles is not None else ""
    print("  %-32s max|e| = %7.4f LSB = %.6f deg%s" % (name, a[i], a[i] * ANG_LSB_DEG, loc))
    print("  %-32s RMS    = %7.4f LSB = %.6f deg   mean = %+7.4f LSB"
          % ("", rms, rms * ANG_LSB_DEG, float(np.mean(np.asarray(arr, dtype=np.float64)))))
    return float(a[i]), rms


def section(t):
    print("")
    print("=" * 78)
    print(t)
    print("=" * 78)


# ==============================================================================
# 4. 主流程
# ==============================================================================
def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    print("cordic_atan2 位精确模型 (Python/numpy)")
    print("  AW=%d IW=%d NITER=%d(契约默认16) ZW=%d FEXT=%d IXW=%d ATAN_SRC=%s"
          % (AW, IW, NITER, ZW, FEXT, IXW, ATAN_SRC))
    print("  Latency = %d clk；1 LSB = 360/2^%d = %.7f deg" % (LATENCY, AW, ANG_LSB_DEG))
    ok_all = True

    # ---- 0. ATAN 常量表自检 -------------------------------------------------
    section("0. ATAN 常量表自检（SPEC 表 vs SPEC 定义式 round(atan(2^-i)*2^20/2pi)）")
    print("   i    SPEC表   定义式值   精确值(浮点)  SPEC-精确  定义式-精确   atan(2^-i)[deg]")
    sum_spec = sum_round = 0.0
    for i in range(16):
        exact = math.atan(2.0 ** -i) / (2.0 * math.pi) * (1 << ZW)
        sum_spec += ATAN_TABLE_SPEC[i] - exact
        sum_round += ATAN_TABLE_ROUND[i] - exact
        mark = "  <== SPEC 表与定义式不符" if ATAN_TABLE_SPEC[i] != ATAN_TABLE_ROUND[i] else ""
        print("  %2d %8d %8d %12.4f %+10.4f %+11.4f   %.7f%s"
              % (i, ATAN_TABLE_SPEC[i], ATAN_TABLE_ROUND[i], exact,
                 ATAN_TABLE_SPEC[i] - exact, ATAN_TABLE_ROUND[i] - exact,
                 math.degrees(math.atan(2.0 ** -i)), mark))
    for i in range(16, NITER):
        exact = math.atan(2.0 ** -i) / (2.0 * math.pi) * (1 << ZW)
        print("  %2d %8s %8d %12.4f %10s %+11.4f   %.7f  (SPEC 表只到 i=15，按定义式外推)"
              % (i, "-", ATAN_TABLE_ROUND[i], exact, "-", ATAN_TABLE_ROUND[i] - exact,
                 math.degrees(math.atan(2.0 ** -i))))
    print("  取整误差之和：SPEC 表 %+.3f LSB20 = %+.4f LSB16；定义式表 %+.3f LSB20 = %+.4f LSB16"
          % (sum_spec, sum_spec / 16, sum_round, sum_round / 16))
    print("  残余旋转角 atan(2^-%d) = %.7f deg = %.4f LSB16"
          % (NITER, math.degrees(math.atan(2.0 ** -NITER)),
             math.degrees(math.atan(2.0 ** -NITER)) / ANG_LSB_DEG))

    # ---- 1. 全圆 4096 点 -----------------------------------------------------
    section("1. 全圆扫描 4096 点（步长 0.087890625 deg，A = %d）" % AMP_FULL)
    n = 4096
    angs = [k * (360.0 / n) for k in range(n)]
    r = sweep(angs)
    print("  [A] 对**连续理想角度**（芯片真实角度误差，含输出 ±0.5LSB 量化）")
    m_cont, rms_cont = stat(r["err_cont"], "err_cont vs ideal angle", angs)
    print("  [B] 对**量化后输入矢量**的精确角度（纯 CORDIC + 输出量化）")
    m_vec, _ = stat(r["err_vec"], "err_vec  vs exact vector angle", angs)
    print("  [C] 对 16bit 整数化名义角度（tb 整数参考表口径，参考角自身带")
    print("      ±0.5LSB 量化，数值虚高，只用于 tb 交叉核对）")
    m_nom, _ = stat(r["err_nom"], "err_nom  vs rounded nominal", angs)
    print("")
    print("  内部位宽占用: max|x|=%d max|y|=%d (IXW=%d 位有符号上限 %d)"
          % (r["dbg"]["max_abs_x"], r["dbg"]["max_abs_y"], IXW, (1 << (IXW - 1)) - 1))
    print("                max|z|=%d (ZW=%d 位有符号上限 %d)，z 回绕次数=%d"
          % (r["dbg"]["max_abs_z"], ZW, (1 << (ZW - 1)) - 1, r["dbg"]["z_wrap"]))
    aa = np.abs(r["err_cont"])
    print("  |err| 直方图(基准A)：", end="")
    for lo, hi in ((0.0, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 1.0)):
        print(" [%.2f,%.2f)=%d" % (lo, hi, int(np.sum((aa >= lo) & (aa < hi)))), end="")
    print(" [>=1.0)=%d" % int(np.sum(aa >= 1.0)))
    if m_cont > 1.0 or m_vec > 1.0:
        ok_all = False

    # ---- 2. 八个边界附近密集扫描 --------------------------------------------
    section("2. 0/45/90/…/315 度边界密集扫描（每个边界 ±0.25deg，2001 点）")
    worst_b = 0.0
    for b in (0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0):
        aa_deg = [b + (-0.25 + 0.5 * k / 2000.0) for k in range(2001)]
        rb = sweep(aa_deg)
        e = float(np.abs(rb["err_cont"]).max())
        worst_b = max(worst_b, e)
        print("  boundary %6.1f deg : max|e_cont| = %7.4f LSB = %.6f deg   "
              "(max|e_vec| = %d LSB, max|e_nom| = %d LSB)"
              % (b, e, e * ANG_LSB_DEG, np.abs(rb["err_vec"]).max(),
                 np.abs(rb["err_nom"]).max()))
    if worst_b > 1.0:
        ok_all = False

    # ---- 3. 强化最坏点搜索：全圆 16 样本/LSB --------------------------------
    section("3. 强化最坏点搜索（全圆 16 样本/LSB = %d 点，A = %d）"
            % (ANG_FULL * 16, AMP_FULL))
    sub = 16
    npts = ANG_FULL * sub
    heavy_angs = [k * (360.0 / npts) for k in range(npts)]
    t0 = 0.0
    import time
    t0 = time.time()
    hmx, hwhere, hrms = scan_max(heavy_angs)
    print("  全圆 %d 点（步长 %.8f deg = 1/%d LSB）：max|e_cont| = %.4f LSB = %.6f deg @ %.5f deg"
          % (npts, 360.0 / npts, sub, hmx, hmx * ANG_LSB_DEG, hwhere % 360.0))
    print("  RMS = %.4f LSB = %.6f deg   （扫描耗时 %.1f s）"
          % (hrms, hrms * ANG_LSB_DEG, time.time() - t0))
    if hmx > 1.0:
        ok_all = False

    # ---- 4. 精确象限边界与退化输入 ------------------------------------------
    section("4. 精确象限边界 / 退化输入")
    cases = [
        ("   0 deg (x=+A, y=0)   ", AMP_FULL, 0),
        ("  90 deg (x=0 , y=+A)  ", 0, AMP_FULL),
        (" 180 deg (x=-A  , y=0) ", -AMP_FULL, 0),
        (" 270 deg (x=0 , y=-A)  ", 0, -AMP_FULL),
        ("  45 deg (x=y=+23170)  ", 23170, 23170),
        (" 135 deg (x=-,y=+)     ", -23170, 23170),
        (" 225 deg (x=-,y=-)     ", -23170, -23170),
        (" 315 deg (x=+,y=-)     ", 23170, -23170),
        (" x=-32768, y=0         ", -32768, 0),
        (" x=0  , y=-32768       ", 0, -32768),
        (" x=0  , y=0  (undefined)", 0, 0),
        (" x=+1 , y=0            ", 1, 0),
        (" x=-1 , y=0            ", -1, 0),
        (" x=0  , y=+1           ", 0, 1),
        (" x=+1 , y=+1           ", 1, 1),
    ]
    for name, xi, yi in cases:
        a, m, _ = cordic_atan2(xi, yi)
        ref = angle_of(xi, yi)
        e = ang_diff(a, ref)
        print("  %s -> angle=%5d (%8.4f deg)  ref=%5d  err=%+5d LSB (%+.5f deg)  mag=%5d"
              % (name, a, a * ANG_LSB_DEG, ref, e, e * ANG_LSB_DEG, m))
    print("  注：|输入| < ~2^(IW-8) 时输入矢量本身只有几个 LSB，角度已无意义；")
    print("      x=y=0 是数学上的奇点（角度未定义），输出无意义但不影响其它点。")

    # ---- 5. mag 幅值统计 ----------------------------------------------------
    section("5. mag 幅值统计（全圆 4096 点，A = %d）" % AMP_FULL)
    mg = r["mag"].astype(np.float64)
    mref = r["mag_ref"]
    rel = (mg - mref) / mref
    print("  mag  min = %d  max = %d  mean = %.2f   (输入幅值 A = %d)"
          % (mg.min(), mg.max(), mg.mean(), AMP_FULL))
    print("  mag 相对矢量真实模长: min = %+.5f%%  max = %+.5f%%  RMS = %.5f%%"
          % (rel.min() * 100, rel.max() * 100, float(np.sqrt(np.mean(rel ** 2))) * 100))
    print("  最小二乘增益 = %.7f  (理想 1.0，偏差 %+.4f%%)"
          % (float(np.sum(mg * mref) / np.sum(mref * mref)),
             (float(np.sum(mg * mref) / np.sum(mref * mref)) - 1.0) * 100))
    print("  MAG_COEF/2^17 = %.8f，1/1.6467602 = %.8f，系数量化误差 %+.3e（满幅 %+.3f LSB）"
          % (MAG_COEF / 2 ** MAG_SHIFT, 1 / 1.6467602,
             MAG_COEF / 2 ** MAG_SHIFT - 1 / 1.6467602,
             (MAG_COEF / 2 ** MAG_SHIFT - 1 / 1.6467602) * AMP_FULL))

    # ---- 5.5 设计取舍扫描 ---------------------------------------------------
    section("5.5 设计取舍扫描（NITER / FEXT / ATAN 表来源，全圆 4 样本/LSB = 262144 点）")
    sub2 = 4
    angs2 = [k * (360.0 / (ANG_FULL * sub2)) for k in range(ANG_FULL * sub2)]
    print("   NITER  FEXT  ATAN表    max|e_cont|      max|e|[deg]     RMS[LSB]")
    for nt in (16, 17, 18):
        for fe in (0, 2, 4, 6):
            for src in ("spec", "round"):
                mx, wh, rr = scan_max(angs2, f_ext=fe, niter=nt, atan=atan_tab_of(nt, src))
                tag = "  <== 采用" if (nt == NITER and fe == FEXT and src == ATAN_SRC) else ""
                print("   %2d     %2d    %-5s   %8.4f LSB   %10.6f    %8.4f%s"
                      % (nt, fe, src, mx, mx * ANG_LSB_DEG, rr, tag))
    print("")
    print("  结论：NITER=16 时无论 FEXT 与表来源如何，最坏误差都 >1 LSB——")
    print("        16 级的误差下限 = 输出四舍五入 0.5 + 残余 atan(2^-15)=0.318")
    print("        + 输入 16bit 量化 0.16 = 0.978 LSB，再叠加 20bit ATAN 常量取整")
    print("        误差(非均匀, ±0.15LSB) 就必然越界；NITER=17 把残余减半后达标。")
    print("        FEXT>=3 后收益饱和（剩余误差与内部小数位无关）。")

    # ---- 6. SPEC 原文折叠公式对照 -------------------------------------------
    section("6. 对照：SPEC §1.5 原文折叠公式（x0<=0）与修正折叠公式（x0>=0）")
    print("    理想角度    SPEC原文输出         修正后输出          参考码")
    for deg in (30.0, 60.0, 100.0, 135.0, 170.0, 190.0, 225.0, 260.0, 300.0, 350.0):
        xi, yi = vector_at(deg)
        a_spec, _, _ = cordic_atan2(xi, yi, fold="spec")
        a_fix, _, _ = cordic_atan2(xi, yi, fold="fixed")
        ref = angle_of(xi, yi)
        es, ef = ang_diff(a_spec, ref), ang_diff(a_fix, ref)
        print("   %6.1f   %6d (%9.4f)   %6d (%9.4f)   %6d   偏差 %+6d LSB / 修正 %+3d LSB"
              % (deg, a_spec, a_spec * ANG_LSB_DEG, a_fix, a_fix * ANG_LSB_DEG, ref, es, ef))
    print("  结论：x<0 的两个象限里 SPEC 原文公式的折叠矢量 x0<=0，向量模式 CORDIC")
    print("        收敛到 +x 轴而非 -x 轴，输出整体偏 180deg（100..260deg 实测偏差")
    print("        -110..+180deg）。本项目采用修正折叠，与 golden_model.py 一致。")

    # ---- 7. 结论 ------------------------------------------------------------
    section("7. 结论")
    print("  基准A 全圆 4096 点    max|e| = %.4f LSB = %.6f deg   RMS = %.4f LSB"
          % (m_cont, m_cont * ANG_LSB_DEG, rms_cont))
    print("  基准A 细网格 1/16LSB  max|e| = %.4f LSB = %.6f deg   RMS = %.4f LSB"
          % (hmx, hmx * ANG_LSB_DEG, hrms))
    print("  基准B 纯 CORDIC       max|e| = %.4f LSB = %.6f deg" % (m_vec, m_vec * ANG_LSB_DEG))
    print("  基准C 整数参考表口径   max|e| = %d LSB（含参考角自身 ±0.5LSB 量化，虚高）" % m_nom)
    print("  八个边界密集扫描      max|e| = %.4f LSB" % worst_b)
    print("  目标 max|e| <= 1 LSB (= %.7f deg)" % ANG_LSB_DEG)
    print("  实测 max|e| = %.4f LSB = %.6f deg  ==>  %s"
          % (max(m_cont, hmx, worst_b), max(m_cont, hmx, worst_b) * ANG_LSB_DEG,
             "PASS" if ok_all else "FAIL"))
    print("  裕量 %.4f LSB (%.2f%%)" % (1.0 - max(m_cont, hmx, worst_b),
                                       (1.0 - max(m_cont, hmx, worst_b)) * 100.0))
    print("")
    print("  误差预算（LSB16，全部为实测/解析值）：")
    print("    输出 16bit 四舍五入量化      <= 0.5000  （AW=16 的固有下限）")
    print("    CORDIC 残余旋转 atan(2^-%d)   %.4f" % (NITER, math.degrees(math.atan(2.0 ** -NITER)) / ANG_LSB_DEG))
    print("    输入矢量 16bit 量化          <= %.4f" % (0.5 / AMP_FULL / (2 * math.pi) * ANG_FULL))
    print("    ATAN 常量 20bit 取整         %+.4f（定义式表，准零偏置）" % (sum_round / 16))
    print("    x/y 向零截断残余             < 0.03（FEXT=%d 后已压到可忽略）" % FEXT)
    print("")
    print("  z 寄存器回绕说明：z 的最大绝对值可达 180deg = 2^19，与 20bit 有符号")
    print("  上限 524287 只差几个 LSB。即使回绕，因为回绕量恰好是 2^ZW = 16*2^AW，")
    print("  输出 (z+8)>>>4 与不回国绕只差 16*2^AW>>4 = 2^AW，被 &(2^AW-1) 掩掉，")
    print("  所以**回绕对输出角度无害**（第 1 节已统计回绕次数）。")
    print("")
    print("  TEST %s" % ("PASSED" if ok_all else "FAILED"))
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
