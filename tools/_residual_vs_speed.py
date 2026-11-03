"""残差常数项 vs 转速：判定它是"固定延时"还是"固定偏置"。

要回答的问题
------------
处理链残差（**板子角度字 − 同帧 arctan2(s,c)**）是个不随角度变的常数，
但它有两种来源，修法完全不同：

  A. 固定延时 τ：残差 = 360 · f · τ   ⇒ 随转速线性涨
  B. 固定偏置：  残差 = 常数          ⇒ 与转速无关

判定方法：在**同一锁定状态**下采几个差别很大的转速，看常数项怎么变。

用法
----
每个转速跑一次（30 s，不用停位、不用基准、不用反向）：

    python -X utf8 tools\\_residual_vs_speed.py COM4 30 低速
    python -X utf8 tools\\_residual_vs_speed.py COM4 30 中速
    python -X utf8 tools\\_residual_vs_speed.py COM4 30 高速

然后出对比表：

    python -X utf8 tools\\_residual_vs_speed.py --compare

每次的结果存到 `%TEMP%\\rvs_<tag>.json`，--compare 会把它们按转速排序、
分别拟合"正比"和"常数"两个模型，给出结论。

关键点
------
* **电频率不吃混叠**：用 `pos_full`（板上 32 位位置计数器）解回绕后求平均，
  它是计数器不是相位，10 kHz 采样照样准。别用 angle 求差分——20 kHz 输入
  在 10 kHz 采样下只剩混叠残差。
* **残差本身也不吃混叠**：`atan2(s,c)` 是逐帧的瞬时相位，同一帧里和板上角度字
  对得上，混叠只影响"帧与帧之间的顺序"。
* 采样基时用帧数（每帧 100 µs）；丢帧会让转速偏低约 1%，对这个 4× 的判定
  没有影响，但如果两次转速很接近就要看输出的丢帧数。
* **挑转速避开整千**：电频率正好 20000 Hz 时每帧转 720°、折回 0°，36 个箱
  只剩 1 个有数（表里 bins_used 会写出来）；19500 只有 20 个箱。想验证
  "残差与角度无关"，取 19700 这类非整数倍，36 个箱才都铺得到。
  （箱数为 1 时 τ 仍然准，只是"平不平"没被验证。）
"""

import glob
import json
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))
sys.path.insert(0, HERE)

import numpy as np

import uart_scope as us

FRAME_HZ = 10000.0
CYC_FULL = 65536.0          # 一个电周期 = 65536 个角度 LSB
BIN_DEG = 10.0
BINS = int(360.0 / BIN_DEG)
OUT_DIR = os.environ.get("TEMP") or "."


# --------------------------------------------------------------------- 分析


def wrap180(x):
    """折到 (−180, 180]。"""
    x = np.asarray(x, dtype=float)
    return (x + 180.0) % 360.0 - 180.0


# 板上流水线延时：12.5 MSPS 下 4 个采样周期 = 0.32 µs。
# 2026-11-03 上板实测两档（227 rpm / 913 rpm）反算出的 τ 都是 0.32 µs，误差随转速
# 严格线性（频率比 4.015、残差比 4.019）⇒ 就是这段固定延时，不是刻度误差。
TAU_DEFAULT_S = 0.32e-6


def analyze(frames, pairs=2048, frame_hz=FRAME_HZ, tau_s=TAU_DEFAULT_S):
    """从一批帧算出：平均电频率、残差常数项、分箱统计、抖动。

    frames 里每帧要有：`angle_deg`（或 `angle`）、`s`、`c`、`pos_full`。
    返回 dict；数据不足时 `ok=False`。
    """
    n = len(frames)
    if n < 1000:
        return {"ok": False, "why": "帧太少（%d）" % n}

    deg = np.empty(n, dtype=float)
    ss = np.empty(n, dtype=float)
    cc = np.empty(n, dtype=float)
    pos = np.empty(n, dtype=np.int64)
    for i, f in enumerate(frames):
        a = f.get("angle_deg")
        if a is None:
            a = float(f.get("angle") or 0) * 360.0 / CYC_FULL
        deg[i] = float(a)
        ss[i] = float(f.get("s") or 0)
        cc[i] = float(f.get("c") or 0)
        pos[i] = int(f.get("pos_full") or 0)

    # ---- 电频率：位置计数器解回绕，不吃混叠 ----
    d = np.diff(pos)
    d = (d + (1 << 31)) % (1 << 32) - (1 << 31)      # 32 位回绕
    d = d[np.isfinite(d)]
    span = (n - 1) / float(frame_hz)                  # 秒（按帧数，丢帧会偏 1%）
    cyc = float(d.sum()) / CYC_FULL
    f_hz = cyc / span if span > 0 else 0.0

    # ---- 残差 ----
    ref = np.degrees(np.arctan2(ss, cc))              # 同帧瞬时相位
    err = wrap180(deg - ref)
    # 折到"最小绝对值"的等价角（±180 折返对常数项没影响，但要避开跳变）
    err_med = float(np.median(err))
    err = wrap180(err - err_med) + err_med

    mean = float(np.mean(err))
    rms = float(np.sqrt(np.mean(err * err)))
    p2p = float(np.ptp(err))

    # ---- 分箱（看它到底是不是常数） ----
    idx = np.floor((deg % 360.0) / BIN_DEG).astype(int) % BINS
    bins = np.full(BINS, np.nan)
    brms = np.full(BINS, np.nan)
    for b in range(BINS):
        m = idx == b
        if int(m.sum()) >= 20:
            bins[b] = float(np.mean(err[m]))
            brms[b] = float(np.sqrt(np.mean(err[m] ** 2)))
    good = bins[np.isfinite(bins)]
    const_lo = float(good.min()) if good.size else float("nan")
    const_hi = float(good.max()) if good.size else float("nan")
    # ★ 只有一个箱有数时也要给 0（std 对一个元素就是 0），别给 nan —— 但这意味着
    #   "平不平"其实没被验证：转速正好是 10 kHz 的整数倍时，10 kHz 帧永远落在
    #   同一个电角度上（20 kHz 输入 ⇒ 每帧 720° ⇒ 折回 0°），36 个箱只剩 1 个有数。
    const_sd = float(good.std()) if good.size else float("nan")

    k_arc = 3600.0 / max(1, int(pairs))                # 电角度 → 机械角秒

    # ---- 抖动来源：前端噪声能解释多少 ----
    amp = np.hypot(ss, cc)
    A = float(np.median(amp)) if amp.size else 0.0
    _den = np.column_stack([np.sin(np.radians(deg)), np.cos(np.radians(deg)),
                            np.ones_like(deg)])
    _res = []
    for _x in (ss, cc):
        _coef, *_ = np.linalg.lstsq(_den, _x, rcond=None)
        _res.append(_x - _den @ _coef)
    sigma_res = float(np.sqrt(np.mean(np.concatenate(_res) ** 2))) if A else 0.0
    noise_deg = float(np.degrees(sigma_res / A)) if A > 1e-9 else 0.0
    noise_arcsec = noise_deg * k_arc if "k_arc" in dir() else noise_deg * 3600.0 / max(1, pairs)

    # ---- 按固定延时 τ 补偿后应该只剩抖动 ----
    #   板上角度 = 采样时刻再往后 τ 的相位 ⇒ θ_corr = θ_meas + 360·f·τ
    err_c = wrap180(err + 360.0 * f_hz * tau_s)
    mean_c = float(np.mean(err_c))
    err_c = wrap180(err_c - mean_c)
    rms_c = float(np.sqrt(np.mean(err_c * err_c)))

    return {
        "ok": True,
        "n": n,
        "span_s": span,
        "f_hz": f_hz,
        "rpm": 60.0 * f_hz / max(1, int(pairs)),
        "err_mean_deg": mean,
        "err_rms_deg": rms,
        "err_p2p_deg": p2p,
        "const_lo": const_lo,
        "const_hi": const_hi,
        "const_sd": const_sd,
        "err_mean_arcsec": mean * k_arc,
        "jitter_arcsec": rms * k_arc,
        # 若残差全是延时：τ = err / (360 f)
        "tau_us": (abs(mean) / (360.0 * abs(f_hz)) * 1e6) if f_hz else float("nan"),
        "err_corr_mean_deg": mean_c,
        "err_corr_mean_arcsec": mean_c * k_arc,
        "err_corr_rms_deg": rms_c,
        "err_corr_rms_arcsec": rms_c * k_arc,
        "amp": A,
        "noise_lsb": sigma_res,
        "noise_arcsec": noise_arcsec,
        "tau_s": float(tau_s),
        "pairs": int(pairs),
        "bins_used": int(good.size),
        "bins": [None if not np.isfinite(v) else round(float(v), 4) for v in bins],
    }


def compare(rows):
    """把多次运行按转速排序，分别拟合"正比"与"常数"，给出判定。"""
    rows = [r for r in rows if r.get("ok")]
    if len(rows) < 2:
        return {"ok": False, "why": "至少要有两组数据才能比"}
    rows.sort(key=lambda r: r["f_hz"])
    f = np.array([r["f_hz"] for r in rows], dtype=float)
    e = np.array([r["err_mean_deg"] for r in rows], dtype=float)

    # 模型 A：e = k·f（过原点）
    k = float(np.dot(f, e) / np.dot(f, f)) if np.dot(f, f) else 0.0
    ea = k * f
    ss_res_a = float(np.sum((e - ea) ** 2))
    ss_tot = float(np.sum((e - e.mean()) ** 2))
    r2_a = 1.0 - ss_res_a / ss_tot if ss_tot > 1e-12 else 0.0

    # 模型 B：e = 常数
    eb = np.full_like(e, e.mean())
    ss_res_b = float(np.sum((e - eb) ** 2))
    r2_b = 1.0 - ss_res_b / ss_tot if ss_tot > 1e-12 else 0.0

    # 反转时 f 全是负数，必须按 |f| 判跨度；否则 f.min()<0 直接走 inf 分支，
    # 绕过下面 span<1.6 的"判不了"保护（实测打印出"转速跨度 inf×"还给结论）。
    _af = np.abs(f)
    span = float(_af.max() / _af.min()) if _af.min() > 0 else float("inf")
    # ★ 判定不能用 R²：几次测得几乎一样时 ss_tot ≈ 0，R² 会变成 −∞/0 之外的怪数。
    #   用"每点残差散布"直接判 —— 它天然有物理量纲（度）。
    rms_tot = math.sqrt(ss_tot / len(e)) if len(e) else 0.0
    rms_a = math.sqrt(ss_res_a / len(e)) if len(e) else 0.0
    rms_b = math.sqrt(ss_res_b / len(e)) if len(e) else 0.0
    VERDICT_NOISE = 0.02                       # 度：小于它就算"测不出来差异"
    if span < 1.6:
        verdict = ("几次转速没差开（只差 %.2f×）⇒ 判不了，请让转速至少差 2~4 倍"
                   % span)
    elif rms_tot < VERDICT_NOISE:
        verdict = "残差几乎不随转速变（散布 %.3f°）⇒ 固定偏置" % rms_tot
    elif rms_a < rms_b * 0.5:
        verdict = "随转速线性涨（散布 %.3f° → %.3f°）⇒ 固定延时，τ ≈ %.2f µs" % (
            rms_tot, rms_a, k / 360.0 * 1e6)
    elif rms_b < rms_a * 0.5:
        verdict = "与转速无关（散布 %.3f°）⇒ 固定偏置 %.2f° 电 = %.1f″" % (
            rms_tot, e.mean(),
            e.mean() * 3600.0 / max(1, rows[0].get("pairs", 2048)))
    else:
        verdict = ("两种模型都拟合不好（散布 %.3f°，A %.3f° / B %.3f°）"
                   "⇒ 先确认几次都在 TRACK、转速平稳" % (rms_tot, rms_a, rms_b))
    return {"ok": True, "rows": rows, "k_deg_per_hz": k, "tau_us": k / 360.0 * 1e6,
            "r2_prop": r2_a, "r2_const": r2_b, "speed_ratio": span,
            "ss_res_prop": ss_res_a, "ss_res_const": ss_res_b,
            "rms_tot": rms_tot, "rms_prop": rms_a, "rms_const": rms_b,
            "verdict": verdict}


# ------------------------------------------------------------------ 采集


def _port_help(port, exc):
    """串口打不开时说人话（板子没插 / 被 GUI 占着 / 端口号变了）。"""
    try:
        import ports as pm
        found = [d for d, _s, _h in pm.list_serial_ports()]
    except Exception:                           # noqa: BLE001
        found = []
    lines = ["打不开串口 %s：%s" % (port, exc),
             "系统里现在能看到的串口：%s" % ("、".join(found) if found else "（一个都没有）")]
    if found and port.upper() not in [d.upper() for d in found]:
        lines.append("板子可能换了端口号，试着用：%s" % found[0])
    lines.append("也可能是上位机（host_app）正占着串口 —— 先关掉它再跑。")
    return "\n".join(lines)


def capture(port, seconds, pairs=2048):
    import serial

    try:
        ser = serial.Serial(port, 2000000, timeout=0.05)
    except Exception as exc:                    # noqa: BLE001
        raise SystemExit(_port_help(port, exc))
    buf = b""
    frames = []
    t0 = time.monotonic()
    try:
        while time.monotonic() - t0 < seconds:
            buf += ser.read(16384)
            got, _stats = us.parse_stream(buf)
            if got:
                frames.extend(got)
                # ★ 只留尾巴：parse_stream 每次把整个 buf 都解析一遍，
                #   不截断就会把同一批帧反复追加（实测 8 s 采出 152 万帧）。
                #   18 字节一帧，留 64 字节足够护住跨读的半帧，剩下靠重同步。
                buf = buf[-64:]
    finally:
        ser.close()
    return frames


# ------------------------------------------------------------------ 自检


def selftest():
    fails = []

    def ck(name, cond, detail=""):
        if cond:
            print("  ok  %s" % name)
        else:
            fails.append("%s %s" % (name, detail))
            print("FAIL %s %s" % (name, detail))

    rng = np.random.default_rng(7)
    pairs = 2048

    def synth(f_hz, tau_us, n=3000, amp=26000.0, noise=1.0, err0=0.0):
        """造"带固定延时 τ"的帧：板上角度 = 真实相位 + 360·f·τ。"""
        k = np.arange(n, dtype=float)
        ph = 360.0 * f_hz * k / FRAME_HZ             # 度，真实相位
        s = amp * np.sin(np.radians(ph)) + rng.normal(0, noise, n)
        c = amp * np.cos(np.radians(ph)) + rng.normal(0, noise, n)
        ang = (ph + 360.0 * f_hz * tau_us * 1e-6 + err0) % 360.0
        cyc = np.floor((ph + 360.0 * f_hz * tau_us * 1e-6) / 360.0)
        out = []
        for i in range(n):
            out.append({
                "angle": int(round(ang[i] / 360.0 * CYC_FULL)) % 65536,
                "angle_deg": float(ang[i]),
                "s": int(round(s[i])), "c": int(round(c[i])),
                "pos_full": int((cyc[i] % 65536.0) * CYC_FULL
                                + round(ang[i] / 360.0 * CYC_FULL)) % (1 << 32),
            })
        return out

    r = analyze(synth(20000.0, 9.0))
    ck("电频率 20 kHz 被还原", abs(r["f_hz"] - 20000.0) < 60.0, "得 %.1f" % r["f_hz"])
    ck("转速 586 rpm", abs(r["rpm"] - 60.0 * 20000.0 / pairs) < 2.0, "得 %.1f" % r["rpm"])
    ck("τ 被还原（≈9 µs）", abs(r["tau_us"] - 9.0) < 1.0, "得 %.2f µs" % r["tau_us"])
    ck("20 kHz 时只剩 1 个箱（每帧 720° 折回 0°）", r["bins_used"] == 1,
       "得 %d" % r["bins_used"])

    # 19.5 kHz ⇒ 每帧 702°，折回 342°，与 360 的最大公约数是 18
    # ⇒ 只会落在 360/18 = 20 个箱上。想铺满 36 个箱得挑 19700 这种非整千转速。
    r15 = analyze(synth(19500.0, 9.0))
    ck("19.5 kHz 铺开足够多的箱（≥12）", r15["bins_used"] >= 12,
       "得 %d" % r15["bins_used"])
    ck("残差确实是常数（分箱 σ 小）", r15["const_sd"] < 0.05, "σ=%.3f" % r15["const_sd"])
    ck("19.5 kHz 的 τ 仍 ≈9 µs", abs(r15["tau_us"] - 9.0) < 1.0,
       "得 %.2f µs" % r15["tau_us"])

    r2 = analyze(synth(5000.0, 9.0))
    ck("5 kHz 时 τ 仍 ≈9 µs", abs(r2["tau_us"] - 9.0) < 1.5, "得 %.2f µs" % r2["tau_us"])

    # 固定偏置：给 0 延时、2° 偏置
    r3 = analyze(synth(20000.0, 0.0, err0=2.0))
    ck("固定偏置 2° 被还原", abs(r3["err_mean_deg"] - 2.0) < 0.05,
       "得 %.2f°" % r3["err_mean_deg"])

    # 两次不同转速：延时模型应该拟合得比常数好
    rows = [analyze(synth(f, 9.0)) for f in (5000.0, 10000.0, 20000.0)]
    c = compare(rows)
    ck("延时场景判定正确", "固定延时" in c["verdict"], c["verdict"])
    ck("延时模型散布远小于常数模型", c["rms_prop"] < c["rms_const"] * 0.5,
       "A %.3f / B %.3f" % (c["rms_prop"], c["rms_const"]))

    # 三次同转速同偏置：常数模型胜
    rows2 = [analyze(synth(f, 0.0, err0=-1.5)) for f in (6000.0, 12000.0, 19000.0)]
    c2 = compare(rows2)
    ck("偏置场景判定正确", "固定偏置" in c2["verdict"], c2["verdict"])

    # 转速没差开时要说"判不了"，不能硬给结论
    rows3 = [analyze(synth(f, 9.0)) for f in (10000.0, 10500.0)]
    c3 = compare(rows3)
    ck("转速没差开时明确说判不了", "判不了" in c3["verdict"], c3["verdict"])

    ck("帧太少时明确报错", analyze([])["ok"] is False)

    print()
    if fails:
        print("失败 %d 项" % len(fails))
        return 1
    print("全部通过")
    return 0


# --------------------------------------------------------------------- 入口


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if "--selftest" in argv:
        return selftest()
    if "--compare" in argv:
        files = sorted(glob.glob(os.path.join(OUT_DIR, "rvs_*.json")))
        if not files:
            print("没有找到 %s\\rvs_*.json —— 先用本脚本跑几次采样" % OUT_DIR)
            return 2
        rows = []
        for p in files:
            with open(p, "r", encoding="utf-8") as fh:
                d = json.load(fh)
            d["tag"] = os.path.basename(p)[4:-5]
            rows.append(d)
        c = compare(rows)
        if not c.get("ok"):
            print(c.get("why"))
            return 2
        print("%-10s %10s %8s %10s %10s %9s" %
              ("标签", "电频率Hz", "转速rpm", "残差°", "残差″", "τ估计µs"))
        for r in c["rows"]:
            print("%-10s %10.0f %8.1f %10.3f %10.1f %9.2f" %
                  (r.get("tag", "?"), r["f_hz"], r["rpm"], r["err_mean_deg"],
                   r["err_mean_arcsec"], r["tau_us"]))
        print()
        print("转速跨度 %.1f×" % c["speed_ratio"])
        print("实测散布 %.3f° ｜ 模型A(正比 τ=%.2f µs) 散布 %.3f° ｜ 模型B(常数) 散布 %.3f°"
              % (c["rms_tot"], c["tau_us"], c["rms_prop"], c["rms_const"]))
        print("判定：%s" % c["verdict"])
        return 0

    port = args[0] if args else "COM4"
    seconds = float(args[1]) if len(args) > 1 else 30.0
    tag = args[2] if len(args) > 2 else time.strftime("run%H%M%S")
    print("采 %s ｜ %.0f s ｜ 标签 %s" % (port, seconds, tag))
    frames = capture(port, seconds)
    print("收到 %d 帧（%.0f 帧/秒）" % (len(frames), len(frames) / max(1e-9, seconds)))
    if not (0.5 < len(frames) / max(1e-9, seconds) / FRAME_HZ < 1.5):
        print("⚠ 帧率不对（应该 ≈10000 帧/秒）—— 串口被别的程序抢了？还是板子没在发 10 kHz？")
    r = analyze(frames)
    if not r.get("ok"):
        print("FAIL %s" % r.get("why"))
        return 1
    print("电频率 %.1f Hz ｜ 转速 %.1f rpm ｜ 帧 %d ｜ 时长 %.1f s"
          % (r["f_hz"], r["rpm"], r["n"], r["span_s"]))
    print("残差   均值 %+.3f°（%.1f″）｜ rms %.3f°（%.1f″）｜ 峰峰 %.2f°"
          % (r["err_mean_deg"], r["err_mean_arcsec"],
             r["err_rms_deg"], r["jitter_arcsec"], r["err_p2p_deg"]))
    print("分 %d 箱：常数项 %.2f ~ %.2f°（σ %.3f°）⇒ %s"
          % (BINS, r["const_lo"], r["const_hi"], r["const_sd"],
             "确实是常数" if r["const_sd"] < 0.1 else "随角度变了，另找原因"))
    print("若全是延时：τ ≈ %.2f µs" % r["tau_us"])
    print("抖动拆解  前端噪声 %.0f LSB（幅值 %.0f）⇒ 角度抖动 %.2f″ ｜ 实测补偿后 rms %.2f″  ⇒ %s"
          % (r["noise_lsb"], r["amp"], r["noise_arcsec"],
             r["err_corr_rms_arcsec"],
             "就是前端噪声" if abs(r["err_corr_rms_arcsec"] - r["noise_arcsec"])
             < 0.4 * max(0.3, r["noise_arcsec"]) else "噪声之外还有别的"))
    print("按 τ=%.2f µs 补偿后：均值 %+.3f°（%.2f″）｜ rms %.3f°（%.2f″）"
          % (r["tau_s"] * 1e6, r["err_corr_mean_deg"], r["err_corr_mean_arcsec"],
             r["err_corr_rms_deg"], r["err_corr_rms_arcsec"]))
    out = os.path.join(OUT_DIR, "rvs_%s.json" % tag)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(r, fh, ensure_ascii=False, indent=1)
    print("已存 %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
