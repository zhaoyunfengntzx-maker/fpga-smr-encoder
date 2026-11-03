"""离线分析引擎：正交信号质量估计 / 频谱 / 覆盖度 / 基础统计。

设计约束（改这个文件前先读）：

1. **纯计算**：只依赖 numpy（交付包只有 numpy + matplotlib，不能引 scipy）。
   不 import Qt、不 import serial、不碰文件 —— 这样它能在没有板子、没有界面的
   机器上被自检覆盖，也才能在 ``--selftest`` 与门禁里跑。
2. **不猜基准**：``fit_quadrature`` 只回答"这组 s/c 有多圆、增益差多少、正交差多少"，
   不回答"绝对角度准不准"（那需要外部基准，见 docs/39 §7）。
3. **角度来源必须声明**：``theta_deg`` 传板上 ``angle`` 时，残差**不是独立指标**
   （板上 angle 本身就是 s/c 经 CORDIC 算出来的，二者相关）；传空时走
   Heydemann 迭代自估，才是不依赖板端角度的独立估计。
4. **符号约定**（与遥测帧一致，s = sin 支路、c = cos 支路）：

       s = R_s·sin(θ) + o_s
       c = R_c·cos(θ + ε) + o_c

   ``eps_deg`` 为正表示 c 比理想正交**超前** ε。理想情况 R_s = R_c、ε = 0、o = 0。
   Lissajous 上是标准椭圆：``axis_ratio`` = 长轴/短轴，``tilt_deg`` = 长轴方向。

四种误差对角度的影响量级（便于判断要不要管）：增益失配 r 引起 ±(r-1)·180/π/2 度量级
的 2θ 纹波；ε 引起 ±ε/2 的 2θ 纹波；偏置引起 1θ 纹波。三者叠加就是"角度误差随
位置正弦起伏"的典型形态 —— 也是全周补偿表存在的原因。
"""

from __future__ import annotations

import numpy as np

#: 覆盖度默认分箱数（全电周期）。与 host/abz.py 的 1024 箱不同：这里看的是
#: "标定取点够不够"，128 箱 × 每箱 3 点 = 384 点就能给出可用的全周误差曲线。
COVERAGE_BINS = 128
COVERAGE_MIN = 3

#: 谐波表默认阶数。
HARMONIC_MAX = 8


# ---------------------------------------------------------------------------
# 基础
# ---------------------------------------------------------------------------
def _as_float(x):
    return np.asarray(x, dtype=np.float64).ravel()


def _wrap_deg(a):
    return np.mod(np.asarray(a, dtype=np.float64), 360.0)


def basic_stats(x):
    """波形统计。全部返回 Python float，便于直接上屏/写 CSV。"""
    a = _as_float(x)
    n = int(a.size)
    if n == 0:
        return {"n": 0, "mean": 0.0, "rms": 0.0, "vpp": 0.0,
                "min": 0.0, "max": 0.0, "std": 0.0, "crest": 0.0}
    mean = float(a.mean())
    rms = float(np.sqrt(np.mean(a * a)))
    return {
        "n": n,
        "mean": mean,
        "rms": rms,
        "vpp": float(a.max() - a.min()),
        "min": float(a.min()),
        "max": float(a.max()),
        "std": float(a.std(ddof=0)),
        "crest": float(a.max() / rms) if rms > 0 else 0.0,
    }


def wrap_error_deg(err_deg):
    """把角度误差折到 ±180°，返回 (峰峰值, 均值, RMS, 最大值, 最小值)。"""
    e = _wrap_deg(err_deg)
    e = np.where(e > 180.0, e - 360.0, e)
    if e.size == 0:
        return {"n": 0, "p2p": 0.0, "mean": 0.0, "rms": 0.0, "max": 0.0, "min": 0.0}
    return {
        "n": int(e.size),
        "p2p": float(e.max() - e.min()),
        "mean": float(e.mean()),
        "rms": float(np.sqrt(np.mean(e * e))),
        "max": float(e.max()),
        "min": float(e.min()),
    }


# ---------------------------------------------------------------------------
# 圆 / 椭圆拟合
# ---------------------------------------------------------------------------
def fit_circle(s, c):
    """代数圆拟合（Kåsa）：``s² + c² = 2a·s + 2b·c + k``。

    只用来给迭代一个稳的**初值**（数据中心、半径）。覆盖率不均时算术平均会
    偏，圆拟合不会 —— 这是它能当初值的原因。
    """
    s = _as_float(s)
    c = _as_float(c)
    n = min(s.size, c.size)
    out = {"ok": False, "o_s": 0.0, "o_c": 0.0, "r": 0.0, "n": int(n)}
    if n < 8:
        return out
    s, c = s[:n], c[:n]
    A = np.column_stack((2.0 * s, 2.0 * c, np.ones(n)))
    b = s * s + c * c
    try:
        sol, *_ = np.linalg.lstsq(A, b, rcond=None)
    except np.linalg.LinAlgError:
        return out
    o_s, o_c, k = float(sol[0]), float(sol[1]), float(sol[2])
    r2 = k + o_s * o_s + o_c * o_c
    if not np.isfinite(r2) or r2 <= 0:
        return out
    out.update({"ok": True, "o_s": o_s, "o_c": o_c, "r": float(np.sqrt(r2))})
    return out


def fit_ellipse(s, c):
    """二阶矩椭圆拟合 → 椭圆几何参数（不依赖角度参考）。

    返回 ``center`` / ``axis_major`` / ``axis_minor`` / ``axis_ratio`` /
    ``tilt_deg`` / ``res_rms`` / ``ok``。

    用法是**交叉校验**：``fit_quadrature`` 给出 (R_s, R_c, ε)，这里给出可直读的
    轴比与倾角。两者在小误差下互为验证 —— 单靠一套公式算出来的数不敢信。

    为什么用二阶矩而不是二次曲线 SVD：均匀采样下本模型的二阶矩就是
    ``½·T·Tᵀ``（T 为 (sinθ,cosθ)→(s,c) 的线性映射），其特征向量**精确**是椭圆
    主轴、半轴 = ``sqrt(2λ)``。六参数二次曲线拟合在近圆数据上会退化到双曲线分支，
    还得处理符号与条件数，没有必要。
    代价：θ 覆盖不均时二阶矩会被权重带偏，所以中心先用圆拟合定，再算中心化矩。
    """
    s = _as_float(s)
    c = _as_float(c)
    n = int(min(s.size, c.size))
    out = {"ok": False, "n": n, "center": (0.0, 0.0),
           "axis_major": 0.0, "axis_minor": 0.0, "axis_ratio": 0.0,
           "tilt_deg": 0.0, "res_rms": 0.0}
    if n < 16:
        return out
    s, c = s[:n], c[:n]
    ci = fit_circle(s, c)
    if ci["ok"]:
        o_s, o_c = ci["o_s"], ci["o_c"]
    else:
        o_s, o_c = float(np.mean(s)), float(np.mean(c))
    u = s - o_s
    v = c - o_c
    M = np.array([[float(np.mean(u * u)), float(np.mean(u * v))],
                  [float(np.mean(u * v)), float(np.mean(v * v))]])
    try:
        evals, evecs = np.linalg.eigh(2.0 * M)      # 2M = T·Tᵀ
    except np.linalg.LinAlgError:
        return out
    if np.any(evals <= 0):
        return out
    semi = np.sqrt(evals)                            # 升序：短轴在前
    major, minor = float(semi[1]), float(semi[0])
    vec = evecs[:, 1]
    tilt = float(np.degrees(np.arctan2(vec[1], vec[0])))
    if tilt <= -90.0:
        tilt += 180.0
    elif tilt > 90.0:
        tilt -= 180.0
    # 残差：旋转到主轴、按半轴归一化后的径向偏差 ρ−1
    th = np.radians(tilt)
    xr = (u * np.cos(th) + v * np.sin(th)) / major
    yr = (-u * np.sin(th) + v * np.cos(th)) / minor
    rho = np.hypot(xr, yr)
    out.update({
        "ok": True,
        "center": (float(o_s), float(o_c)),
        "axis_major": major,
        "axis_minor": minor,
        "axis_ratio": float(major / minor) if minor > 0 else 0.0,
        "tilt_deg": tilt,
        "res_rms": float(np.sqrt(np.mean((rho - 1.0) ** 2))),
    })
    return out


# ---------------------------------------------------------------------------
# 正交四参数回归（Heydemann 迭代）
# ---------------------------------------------------------------------------
def _theta_from_params(s, c, o_s, o_c, r_s, r_c, eps_rad):
    """由参数反解 θ：u = sinθ、v = cos(θ+ε)，故 cosθ = (v + u·sinε)/cosε。"""
    u = (s - o_s) / r_s if r_s else np.zeros_like(s)
    v = (c - o_c) / r_c if r_c else np.zeros_like(c)
    return np.arctan2(u, (v + u * np.sin(eps_rad)) / np.cos(eps_rad))


def _regress(s, c, th):
    """在给定 θ 下做两组三项最小二乘（sin, cos, 常数）。"""
    A = np.column_stack((np.sin(th), np.cos(th), np.ones(th.size)))
    coef_s, *_ = np.linalg.lstsq(A, s, rcond=None)
    coef_c, *_ = np.linalg.lstsq(A, c, rcond=None)
    return coef_s, coef_c


def fit_quadrature(s, c, theta_deg=None, iters=48, n_max=20000):
    """估计 R_s / R_c / 正交误差 ε / 两路偏置 / 残差。

    两种模式：

    * ``theta_deg`` 给定时（板端 angle 或已知参考）：直接按该 θ 回归，残差反映
      "在板端看来 s/c 有多不理想"，但**与板端角度相关，不能当绝对精度**。
    * ``theta_deg=None``：先用圆拟合定中心，再交替「由参数反解 θ → 重新回归」，
      即 Heydemann 迭代。这是**不依赖板端角度**的独立估计。

    ★ 迭代收敛是**线性**的（每轮误差约减半），所以默认 48 轮而不是"4 轮足够"：
    实测 6 轮时 ε 还差 1.6%（0.492° vs 0.500°）、R_c 差 0.24 LSB，必须跑到
    < 1e-9 才会停在真值上。样点超过 ``n_max`` 时等间隔抽稀（参数估计只看分布，
    与点数无关），26 万点也能在几十毫秒内出结果。
    """
    s = _as_float(s)
    c = _as_float(c)
    n_all = int(min(s.size, c.size))
    n_iter = max(1, int(iters))
    out = {"ok": False, "n": n_all, "r_s": 0.0, "r_c": 0.0, "gain_ratio": 1.0,
           "gain_dB": 0.0, "eps_deg": 0.0, "off_s": 0.0, "off_c": 0.0,
           "res_rms": 0.0, "res_rms_rel": 0.0, "snr_db": 0.0, "iters": 0}
    if n_all < 16:
        return out
    s, c = s[:n_all], c[:n_all]
    if not (np.all(np.isfinite(s)) and np.all(np.isfinite(c))):
        return out
    n = n_all
    if n > int(n_max):
        step = int(np.ceil(n / float(n_max)))
        idx = np.arange(0, n, step)[:int(n_max)]
        s, c = s[idx], c[idx]
        if theta_deg is not None:
            theta_deg = _as_float(theta_deg)[:n_all][idx]
        n = int(s.size)

    if theta_deg is not None:
        th = np.radians(_as_float(theta_deg)[:n])
        coef_s, coef_c = _regress(s, c, th)
        o_s, o_c = float(coef_s[2]), float(coef_c[2])
        r_s = float(np.hypot(coef_s[0], coef_s[1]))
        r_c = float(np.hypot(coef_c[0], coef_c[1]))
        phi_s = float(np.arctan2(coef_s[1], coef_s[0]))     # s = R_s·sin(θ+φ_s)
        phi_c = float(np.arctan2(coef_c[0], coef_c[1]))      # c = R_c·cos(θ−φ_c)
        eps = -(phi_s + phi_c)                              # 相对 90° 的偏差
        iters = 0
    else:
        ci = fit_circle(s, c)
        o_s = ci["o_s"] if ci["ok"] else float(np.mean(s))
        o_c = ci["o_c"] if ci["ok"] else float(np.mean(c))
        r_s = ci["r"] if ci["ok"] and ci["r"] > 0 else float(np.std(s)) * np.sqrt(2.0)
        r_c = r_s
        eps = 0.0
        iters = 0
        for it in range(n_iter):
            th = _theta_from_params(s, c, o_s, o_c, r_s, r_c, eps)
            coef_s, coef_c = _regress(s, c, th)
            new_o_s, new_o_c = float(coef_s[2]), float(coef_c[2])
            new_r_s = float(np.hypot(coef_s[0], coef_s[1]))
            new_r_c = float(np.hypot(coef_c[0], coef_c[1]))
            phi_s = float(np.arctan2(coef_s[1], coef_s[0]))
            phi_c = float(np.arctan2(coef_c[0], coef_c[1]))
            new_eps = -(phi_s + phi_c)
            d = (abs(new_r_s - r_s) + abs(new_r_c - r_c)
                 + abs(new_eps - eps) * max(r_s, 1e-12))
            o_s, o_c, r_s, r_c, eps = new_o_s, new_o_c, new_r_s, new_r_c, new_eps
            iters = it + 1
            if d < 1e-9 * max(r_s, 1.0):
                break

    # 残差：用最终参数重建理想 θ，再看两路还差多少
    th = _theta_from_params(s, c, o_s, o_c, r_s or 1.0, r_c or 1.0, eps)
    e_s = (s - o_s) - r_s * np.sin(th)
    e_c = (c - o_c) - r_c * np.cos(th + eps)
    res_rms = float(np.sqrt(np.mean(e_s * e_s + e_c * e_c)))
    amp = 0.5 * (abs(r_s) + abs(r_c))
    res_rel = res_rms / amp if amp > 0 else 0.0
    snr = -20.0 * np.log10(res_rel) if res_rel > 1e-12 else 300.0

    ratio = (r_s / r_c) if r_c else 1.0
    out.update({
        "ok": True,
        "r_s": float(r_s), "r_c": float(r_c),
        "gain_ratio": float(ratio),
        "gain_dB": float(20.0 * np.log10(abs(ratio))) if ratio > 0 else 0.0,
        "eps_deg": float(np.degrees(eps)),
        "off_s": float(o_s), "off_c": float(o_c),
        "res_rms": res_rms, "res_rms_rel": float(res_rel),
        "snr_db": float(snr), "iters": int(iters),
    })
    return out


def front_end_error(p):
    """把 fit_quadrature 的结果折成"角度误差幅值"（度）——判断前端够不够好。

    三个误差源各自的角度误差幅值（一阶展开，小误差下成立）：

    * 增益失配 g = R_s/R_c − 1  ⇒  δθ ≈ g/2
    * 正交误差 ε                 ⇒  δθ ≈ ε/2
    * 偏置 (o_s, o_c)            ⇒  δθ ≈ hypot(o_s, o_c) / R

    三者按平方和合成（各自误差是 θ 的不同次谐波，峰不重合）。返回的是**幅值**，
    不是 RMS —— 现场问"差多少度"问的是峰。

    ★ 这只是一阶估计：它不看残差，也不看板端补偿。残差大说明还有别的误差源
    （谐波、噪声、采样抖动），那时 total_deg 只是"已知三项贡献"。
    """
    out = {"ok": False, "gain_deg": 0.0, "orth_deg": 0.0, "off_deg": 0.0,
           "total_deg": 0.0}
    if not p or not p.get("ok"):
        return out
    r_s = abs(float(p.get("r_s") or 0.0))
    r_c = abs(float(p.get("r_c") or 0.0))
    amp = 0.5 * (r_s + r_c)
    if amp <= 0.0:
        return out
    ratio = (r_s / r_c) if r_c else 1.0
    gain_deg = float(np.degrees(abs(ratio - 1.0) / 2.0))
    orth_deg = abs(float(p.get("eps_deg") or 0.0)) / 2.0
    off = float(np.hypot(float(p.get("off_s") or 0.0), float(p.get("off_c") or 0.0)))
    off_deg = float(np.degrees(off / amp))
    total = float(np.sqrt(gain_deg ** 2 + orth_deg ** 2 + off_deg ** 2))
    out.update({"ok": True, "gain_deg": gain_deg, "orth_deg": orth_deg,
                "off_deg": off_deg, "total_deg": total})
    return out


# ---------------------------------------------------------------------------
# 频谱
# ---------------------------------------------------------------------------
def _hann(n):
    return np.hanning(n) if n > 2 else np.ones(max(n, 1))


def _dft_amp(xw, wsum, fs, f0):
    """在任意频率 f0 上直接算单边幅度（Goertzel 式）。

    为什么不用"取附近最几格的最大值"：Hann 窗下非整周期信号有扇贝损失
    （半格偏移可达 −1.42 dB，即 −15%），而且每个谐波的偏移不同，
    **幅值比会被系统性带偏**（实测 10% 的谐波读成 10.8%）。直接在该频率上做
    DFT 求和则没有这个问题，代价是 O(n)/次，谐波表也就十来次。
    """
    n = xw.size
    if f0 <= 0 or f0 >= fs / 2.0:
        return 0.0
    idx = np.arange(n)
    ph = np.exp(-2j * np.pi * (f0 / fs) * idx)
    return float(2.0 * abs(np.sum(xw * ph)) / max(wsum, 1e-12))


def _refine_peak(xw, wsum, fs, f0, span):
    """黄金分割搜索细化峰位（峰值附近单峰，20 次评估足够）。"""
    gr = (np.sqrt(5.0) - 1.0) / 2.0
    lo, hi = max(f0 - span, 1e-9), min(f0 + span, fs / 2.0 * 0.999)
    if hi <= lo:
        return f0
    c = hi - gr * (hi - lo)
    d = lo + gr * (hi - lo)
    fc = _dft_amp(xw, wsum, fs, c)
    fd = _dft_amp(xw, wsum, fs, d)
    for _ in range(24):
        if fc > fd:
            hi, d, fd = d, c, fc
            c = hi - gr * (hi - lo)
            fc = _dft_amp(xw, wsum, fs, c)
        else:
            lo, c, fc = c, d, fd
            d = lo + gr * (hi - lo)
            fd = _dft_amp(xw, wsum, fs, d)
        if hi - lo < 1e-9 * max(hi, 1.0):
            break
    return 0.5 * (lo + hi)


def spectrum(x, fs, n_harm=HARMONIC_MAX, fund_hz=None, n_max=65536):
    """单边幅度谱 + 谐波表 + THD。

    ``fs`` 为样点率（连续流 12.5 MSPS / 抽取后自算）。基波与各次谐波的幅度都在
    **插值后的真实频率**上用直接 DFT 求，避开扇贝损失，所以 1×:3× 的比值是可信的
    （这一点对"谐波失真有多大"的判断很关键）。样点数超过 ``n_max`` 时取最后
    ``n_max`` 点，避免在 26 万点上做几十次 O(n) 求和把界面卡住。
    """
    a = _as_float(x)
    n_all = int(a.size)
    fs = float(fs)
    out = {"ok": False, "n": n_all, "fs": fs, "nyquist": fs / 2.0,
           "freq_hz": np.zeros(0), "mag": np.zeros(0),
           "fund_hz": 0.0, "harmonics": [], "thd_pct": 0.0, "used": 0}
    if n_all < 32 or fs <= 0:
        return out
    if n_all > int(n_max):
        a = a[-int(n_max):]
    n = int(a.size)
    w = _hann(n)
    wsum = float(w.sum())
    xw = (a - a.mean()) * w
    spec = np.fft.rfft(xw)
    mag = np.abs(spec) * (2.0 / max(wsum, 1e-12))
    freq = np.fft.rfftfreq(n, d=1.0 / fs)
    if mag.size > 2:
        mag[:2] = 0.0                      # 去直流与趋势残留
    bin_hz = fs / n
    if fund_hz is None:
        k = int(np.argmax(mag))
        fund = _refine_peak(xw, wsum, fs, float(freq[k]), 1.5 * bin_hz)
    else:
        fund = float(fund_hz)
    out.update({"ok": True, "freq_hz": freq, "mag": mag,
                "fund_hz": fund, "used": n})
    a1 = _dft_amp(xw, wsum, fs, fund)
    rows = []
    for h in range(1, max(1, int(n_harm)) + 1):
        fh = fund * h
        if fh >= fs / 2.0:
            break
        ah = _dft_amp(xw, wsum, fs, fh)
        rows.append({"h": h, "freq_hz": float(fh), "amp": ah,
                     "rel_pct": float(100.0 * ah / a1) if a1 > 0 else 0.0})
    thd = 0.0
    if a1 > 0:
        acc = sum(r["amp"] ** 2 for r in rows[1:])
        thd = float(np.sqrt(acc) / a1 * 100.0)
    out["harmonics"] = rows
    out["thd_pct"] = thd
    return out


def estimate_rate(freq_hz, pairs):
    """电频率 → 机械转速（rpm）。``pairs`` 为极对数（默认 4）。"""
    try:
        f = float(freq_hz)
        p = int(pairs)
    except (TypeError, ValueError):
        return 0.0
    if p <= 0 or f <= 0:
        return 0.0
    return 60.0 * f / p


# ---------------------------------------------------------------------------
# 覆盖度（标定取点够不够）
# ---------------------------------------------------------------------------
def coverage(theta_deg, bins=COVERAGE_BINS, min_count=COVERAGE_MIN):
    """按电角度分箱统计取点密度。

    标定要拟合"全周误差曲线"，前提是**每个箱都有点**。常见的坑是数据都在一两个
    位置（停机点）而用户以为转了整圈 —— 所以这里返回空箱、最大连续空箱的角宽，
    而不是只给一个百分比。
    """
    th = _wrap_deg(theta_deg)
    bins = max(2, int(bins))
    min_count = max(1, int(min_count))
    out = {"bins": bins, "n": int(th.size), "counts": np.zeros(bins, dtype=np.int64),
           "empty_bins": bins, "low_bins": bins, "coverage_pct": 0.0,
           "min_count": 0, "max_count": 0, "gap_deg": 360.0, "ok": False}
    if th.size == 0:
        return out
    counts, edges = np.histogram(th, bins=bins, range=(0.0, 360.0))
    counts = counts.astype(np.int64)
    filled = int(np.count_nonzero(counts))
    # 最大连续空箱（环形：跨越 0°/360° 的缺口要合并）
    empty = (counts == 0).astype(np.int8)
    best = 0
    if empty.all():
        best = bins
    elif empty.any():
        doubled = np.concatenate((empty, empty))
        run = 0
        for k in range(2 * bins):
            run = run + 1 if doubled[k] else 0
            best = max(best, min(run, bins))
    out.update({
        "counts": counts,
        "empty_bins": int(bins - filled),
        "low_bins": int(np.count_nonzero(counts < min_count)),
        "coverage_pct": float(100.0 * filled / bins),
        "min_count": int(counts.min()),
        "max_count": int(counts.max()),
        "gap_deg": float(360.0 * best / bins),
        "ok": bool(best == 0 and np.all(counts >= min_count)),
    })
    return out


# ---------------------------------------------------------------------------
# 自检（离线）：python host\analysis.py --selftest
# ---------------------------------------------------------------------------
def _synth(theta, r_s=1000.0, r_c=1000.0, eps_deg=0.0, o_s=0.0, o_c=0.0, noise=0.0):
    eps = np.radians(eps_deg)
    s = r_s * np.sin(theta) + o_s
    c = r_c * np.cos(theta + eps) + o_c
    if noise > 0:
        rng = np.random.default_rng(12345)
        s = s + rng.normal(0.0, noise, s.size)
        c = c + rng.normal(0.0, noise, c.size)
    return s, c


def selftest():
    ok = True

    def check(name, got, want, tol=0.0):
        nonlocal ok
        if tol:
            good = (abs(float(got) - float(want)) <= tol)
            shown = "got=%.6g want=%.6g tol=%.3g" % (got, want, tol)
        else:
            good = got == want
            shown = "got=%r want=%r" % (got, want)
        ok &= good
        print("%-52s %s" % (name, "PASS" if good else "FAIL  " + shown))

    th = np.linspace(0.0, 2 * np.pi * 3, 3000, endpoint=False)

    # ---- 理想：四个参数必须原样回来 ----
    s, c = _synth(th, 1000.0, 1000.0, 0.0, 0.0, 0.0)
    r = fit_quadrature(s, c)
    check("理想  R_s = 1000", r["r_s"], 1000.0, 1e-6)
    check("理想  R_c = 1000", r["r_c"], 1000.0, 1e-6)
    check("理想  eps = 0", r["eps_deg"], 0.0, 1e-6)
    check("理想  残差 ≈ 0", r["res_rms"], 0.0, 1e-6)

    # ---- 增益失配 3% + 正交 0.5° + 偏置 50/−30 ----
    s, c = _synth(th, 1000.0, 1030.0, 0.5, 50.0, -30.0)
    r = fit_quadrature(s, c)
    check("失配  R_s = 1000", r["r_s"], 1000.0, 0.05)
    check("失配  R_c = 1030", r["r_c"], 1030.0, 0.05)
    check("失配  eps = +0.5°", r["eps_deg"], 0.5, 0.002)
    check("失配  off_s = 50", r["off_s"], 50.0, 0.05)
    check("失配  off_c = −30", r["off_c"], -30.0, 0.05)
    check("失配  gain_ratio ≈ 1.03", r["gain_ratio"], 1000.0 / 1030.0, 1e-4)

    # ---- 负 ε 与单侧增益 ----
    s, c = _synth(th, 2000.0, 1900.0, -0.8)
    r = fit_quadrature(s, c)
    check("负 eps  eps = −0.8°", r["eps_deg"], -0.8, 0.002)
    check("负 eps  R_c = 1900", r["r_c"], 1900.0, 0.05)

    # ---- 有噪声：估计量不能崩，残差应≈噪声幅度（径向偏差，不是 √2·σ）----
    s, c = _synth(th, 1000.0, 1000.0, 0.0, 0.0, 0.0, noise=1.0)
    r = fit_quadrature(s, c)
    check("噪声 1LSB  eps < 0.02°", abs(r["eps_deg"]) < 0.02, True)
    check("噪声 1LSB  残差 ~1 LSB", r["res_rms"], 1.0, 0.15)
    s, c = _synth(th, 1000.0, 1000.0, 0.0, 0.0, 0.0, noise=2.0)
    r2 = fit_quadrature(s, c)
    check("噪声 2LSB  残差 ≈ 2×1LSB（线性）", r2["res_rms"] / r["res_rms"], 2.0, 0.15)

    # ---- 覆盖率不均时用圆拟合定中心，不能偏 ----
    th2 = np.linspace(0.0, np.pi, 900, endpoint=False)      # 只转半圈
    s, c = _synth(th2, 1000.0, 1000.0, 0.0, 400.0, -250.0)
    r = fit_quadrature(s, c)
    check("半圈覆盖 off_s = 400", r["off_s"], 400.0, 2.0)
    check("半圈覆盖 off_c = −250", r["off_c"], -250.0, 2.0)

    # ---- 给定参考角度（模拟板端 angle）----
    s, c = _synth(th, 1000.0, 1020.0, 0.3, 10.0, 20.0)
    r = fit_quadrature(s, c, theta_deg=np.degrees(th))
    check("带 θ  R_c = 1020", r["r_c"], 1020.0, 1e-3)
    check("带 θ  eps = +0.3°", r["eps_deg"], 0.3, 1e-4)
    check("带 θ  iters = 0", r["iters"], 0)

    # ---- 前端误差折算：界面靠它把"3% 失配"翻译成"多少度" ----
    s, c = _synth(th, 1000.0, 1030.0, 0.5, 50.0, -30.0)
    fe = front_end_error(fit_quadrature(s, c))
    check("折算  增益 3% → 0.8344°", fe["gain_deg"], 0.83440, 1e-4)
    check("折算  正交 0.5° → 0.25°", fe["orth_deg"], 0.25, 1e-6)
    check("折算  偏置 58.3/1015 → 3.2916°", fe["off_deg"], 3.29162, 2e-3)
    check("折算  合成 3.4052°", fe["total_deg"], 3.40520, 1e-3)
    check("折算  无结果时 ok=False",
          front_end_error({"ok": False})["ok"], False)

    # ---- 椭圆拟合：θ 无关的交叉校验 ----
    s, c = _synth(th, 1000.0, 1030.0, 0.0)
    e = fit_ellipse(s, c)
    check("椭圆  轴比 = 1.03", e["axis_ratio"], 1.03, 2e-3)
    check("椭圆  中心在原点", max(abs(e["center"][0]), abs(e["center"][1])), 0.0, 1e-6)
    check("椭圆  长轴 = 1030", e["axis_major"], 1030.0, 1.0)
    s, c = _synth(th, 1000.0, 1000.0, 0.5)
    e = fit_ellipse(s, c)
    # 等增益时椭圆轴恒在 ±45°，正交误差只体现在轴比 sqrt((1+sinε)/(1−sinε))
    _r = np.radians(0.5)
    check("椭圆  ε=0.5° 轴比 = √((1+s)/(1−s))", e["axis_ratio"],
          float(np.sqrt((1 + np.sin(_r)) / (1 - np.sin(_r)))), 2e-3)
    check("椭圆  ε=0.5° 长轴倾角 ≈ −45°", e["tilt_deg"], -45.0, 1.0)
    s, c = _synth(th, 1000.0, 1000.0, 0.0, 30.0, 40.0)
    e = fit_ellipse(s, c)
    check("椭圆  含偏置时中心 = (30,40)",
          (round(e["center"][0], 3), round(e["center"][1], 3)), (30.0, 40.0))

    # ---- 频谱：50 kHz 基波 + 3 次谐波 10% ----
    fs = 2.0e6
    n = 4096
    t = np.arange(n) / fs
    f0 = 50000.0
    x = np.sin(2 * np.pi * f0 * t) + 0.1 * np.sin(2 * np.pi * 3 * f0 * t)
    sp = spectrum(x, fs, n_harm=5)
    check("频谱  基波 ≈ 50 kHz", sp["fund_hz"], 50000.0, 5.0)
    h1 = sp["harmonics"][0]["rel_pct"]
    h3 = sp["harmonics"][2]["rel_pct"]
    check("频谱  1× = 100%", h1, 100.0, 0.2)
    check("频谱  3× = 10%（无扇贝损失）", h3, 10.0, 0.05)
    check("频谱  THD ≈ 10%", sp["thd_pct"], 10.0, 0.1)
    check("频谱  样点不足返 ok=False", spectrum(np.zeros(8), fs)["ok"], False)

    # ---- 转速换算 ----
    check("转速  50 kHz / 4 对极 = 750000 rpm", estimate_rate(50000.0, 4), 750000.0)
    check("转速  25 Hz / 4 对极 = 375 rpm", estimate_rate(25.0, 4), 375.0)
    check("转速  0 频 = 0", estimate_rate(0.0, 4), 0.0)

    # ---- 覆盖度 ----
    cv = coverage(np.linspace(0.0, 360.0, 4000, endpoint=False))
    check("覆盖  整圈 128 箱全填满", cv["empty_bins"], 0)
    check("覆盖  整圈 ok = True", cv["ok"], True)
    cv = coverage(np.linspace(0.0, 180.0, 3000, endpoint=False))
    check("覆盖  半圈覆盖率 ≈ 50%", round(cv["coverage_pct"], 0), 50.0)
    check("覆盖  半圈最大空箱 ≈ 180°", cv["gap_deg"], 180.0, 3.0)
    cv = coverage(np.full(100, 12.3))
    check("覆盖  单点 = 1 箱（gap ≈ 357°）", cv["gap_deg"] > 350.0, True)
    # 跨 0° 的缺口必须合并成一个
    ang = np.concatenate((np.linspace(10.0, 20.0, 50), np.linspace(340.0, 350.0, 50)))
    cv = coverage(ang, bins=72)
    check("覆盖  跨 0° 缺口合并 ≈ 320°", cv["gap_deg"], 320.0, 6.0)

    # ---- 统计 ----
    st = basic_stats(np.array([-1.0, 0.0, 1.0, 0.0]))
    check("统计  vpp = 2", st["vpp"], 2.0)
    check("统计  rms = 0.7071", st["rms"], np.sqrt(0.5), 1e-9)
    check("统计  空输入不崩", basic_stats([])["n"], 0)

    # ---- 角度误差折返 ----
    we = wrap_error_deg(np.array([350.0, 10.0, 180.0, -190.0]))
    check("折返  350°→−10°", we["max"], 180.0)
    check("折返  p2p = 190", we["p2p"], 190.0, 1e-9)
    check("折返  rms > 0", we["rms"] > 0, True)

    print("自检%s" % ("通过 (PASS)" if ok else "失败 (FAIL)"))
    return 0 if ok else 1


def main(argv=None):
    import sys
    argv = sys.argv[1:] if argv is None else argv
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:                                    # noqa: BLE001
        pass
    if "--selftest" in argv or not argv:
        return selftest()
    print("用法：python host\\analysis.py --selftest")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
