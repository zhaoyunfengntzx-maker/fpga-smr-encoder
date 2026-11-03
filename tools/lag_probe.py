# -*- coding: utf-8 -*-
"""lag_probe.py —— 从既有 ILA CSV 量"环路系统滞后"（角度域，deg）

背景（为什么需要这个脚本）
  `_synth_work/ila_report.py` 的 [4] 段里有这么一行：
      err = np.unwrap(ang/65536*2*np.pi) - th
      err -= np.mean(err)          # ★ 均值被丢掉了
      print(RMS = std(err))
  被丢掉的**均值**正是环路的系统性滞后：
    - 纯 P 环路（ki=0）是一阶系统，对恒速输入（= 恒定角频率）存在**速度滞后**
      `lag = Δθ_每拍 / Kp`，其中 Δθ_每拍 = 360°·f_in/fs_update、Kp = 2^-(6-kp)…
      即滞后**正比于 f_in**、反比于 kp；
    - 含 I 项（ki≥1）是二阶（II 型）系统，恒速输入下**稳态滞后为 0**，只剩 3 拍
      流水线延迟（≈0.24 µs，折算成角度 ∝ f_in，但极小）。
  所以"lag vs f_in"是区分 0x0302 各档（纯 P vs 含 I）的**定量判据**，
  而线性残差 RMS（拟合时已吸收斜率与截距）对它完全不敏感 —— 这正是
  2026-10-11 五档 sweep 判定"区分不出档位"的原因。

单位约定
  `dbg_angle` / `dbg_angle_raw` 是 16 位无符号相位（65536 = 360°）；
  `dbg_s_raw` / `dbg_c_raw` 是 12 位二进制补码样本。
  lag_raw  = mean(unwrap(angle_raw) - unwrap(angle))   [deg]  >0 ⇒ 滤波后角度滞后
  lag_atan2= mean(unwrap(atan2(s,c))  - unwrap(angle))  [deg]  对模拟真值的滞后

用法
  python _synth_work/lag_probe.py                     # 跑内置清单
  python _synth_work/lag_probe.py <csv> [<csv> ...]    # 指定文件
"""
import sys
import os
import numpy as np
import pandas as pd

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

FS = 50e6

DEFAULT = [
    (r"_synth_work/ila_cap_v8s_1a.csv",  "1 kHz  0x1A v8默认(kp2/ki3,门控)"),
    (r"_synth_work/ila_cap_v8s_04.csv",  "1 kHz  0x04 纯P(kp4/ki0)"),
    (r"_synth_work/ila_cap_v8s_0c.csv",  "1 kHz  0x0C kp4/ki1"),
    (r"_synth_work/ila_cap_v8k10_1a.csv", "10 kHz 0x1A v8默认"),
    (r"_synth_work/ila_cap_v8k10_04.csv", "10 kHz 0x04 纯P"),
    (r"_synth_work/ila_cap_v8k10_0c.csv", "10 kHz 0x0C kp4/ki1"),
    (r"_synth_work/ila_cap_v8k10_1c.csv", "10 kHz 0x1C 门控kp4/ki3"),
    (r"_synth_work/ila_cap_v8k10_00.csv", "10 kHz 0x00 kp0/ki0=bypass"),
    (r"_synth_work/ila_cap_v8free.csv",  "1 kHz  v8 自由运行(复位默认 0x1A)"),
    (r"_synth_work/ila_cap_v7free.csv",  "1 kHz  v7 自由运行(复位默认纯P)"),
]


def bitrev(x, w):
    v = int(x, 16) & ((1 << w) - 1)
    r = 0
    for _ in range(w):
        r = (r << 1) | (v & 1)
        v >>= 1
    return r


def wrap180(x):
    """把角度差归一到 (-180, +180]。

    ★ 为什么必须做（2026-10-11 板上的真事）：下面 `phr` / `pha` 是**各自独立**
    解卷绕的，`np.unwrap` 保留第一拍的原始值、不加任何偏置 ⇒ 若抓波窗口第一拍
    恰好 `angle_raw − angle < −180°`（即 `angle` 跨过了 0°/360° 相位边界），
    两串的差就会整体显示成"真值 − 360°"：
        20 kHz 纯 P 真值 +36.884°（预测 36.93°）在 CSV `ila_cap_v9k20_i32_04.csv`
        里被报成 **−323.116°** —— 二者正好差 360°，是同一个物理量。
    滞后判据（纯 P 正比于 f_in、Ⅱ 型 ≈ 0）只在 ±180° 内有意义，故统一归一化后
    再打印/比较；同时保留原始均值，便于看它是"跨了边界"而不是"真变了号"。
    """
    return (x + 180.0) % 360.0 - 180.0


def sgn(v, w):
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


def load(path):
    """返回 (D, reverse, note)；D 以"列名前缀"为键"""
    df = pd.read_csv(path, skiprows=[1], dtype=str)
    W = {}
    for c in df.columns:
        if "[" in c:
            a, b = c[c.index("[") + 1: c.index("]")].split(":")
            W[c] = abs(int(b) - int(a)) + 1

    def build(rev):
        D = {}
        for c in df.columns:
            if c in W:
                w = W[c]
                r = np.array([bitrev(v, w) if rev else int(v, 16) for v in df[c]], dtype=np.int64)
                D[c.split("[")[0]] = np.array([sgn(v, w) for v in r], dtype=np.int64)
            else:
                D[c.split("[")[0]] = np.array([int(v) for v in df[c]], dtype=np.int64)
        return D

    best, note = None, ""
    for tag, rev in (("直读", False), ("位反", True)):
        D = build(rev)
        sb = D.get("dbg_stat_byte")
        viol = int(np.count_nonzero((sb & 0x80) != 0)) if sb is not None else 0
        rstd = float(np.hypot(D["dbg_s_raw"], D["dbg_c_raw"]).std())
        score = (viol, rstd)
        if best is None or score < best[0]:
            best, note = (score, D), tag
    return best[1], note


def probe(path, label):
    if not os.path.exists(path):
        print(f"  [跳过] {path} 不存在")
        return None
    D, note = load(path)
    N = len(D["dbg_s_raw"])
    T = np.arange(N) / FS

    th = np.unwrap(np.arctan2(D["dbg_s_raw"], D["dbg_c_raw"]))
    pha = np.unwrap(D["dbg_angle"] / 65536 * 2 * np.pi)
    phr = np.unwrap(D["dbg_angle_raw"] / 65536 * 2 * np.pi)

    f_th = abs(np.polyfit(T, th, 1)[0]) / (2 * np.pi)
    f_a = abs(np.polyfit(T, pha, 1)[0]) / (2 * np.pi)

    lag_raw = np.degrees(phr - pha)
    lag_at = np.degrees(th - pha)
    # 去掉一次线性趋势后的残余（确认滞后是"常数偏移"而不是"还在漂"）
    k1, b1 = np.polyfit(T, lag_raw, 1)
    lag_mean = wrap180(float(lag_raw.mean()))
    hint = ""
    if abs(lag_mean - lag_raw.mean()) > 1e-6:
        hint = (f"  ← 原始均值 {lag_raw.mean():+.3f}° 差 360°×整数 ⇒ 已按 mod 360 "
                f"归一到 ±180°（窗口首拍跨了 0° 相位边界，二者是同一物理量）")

    print(f"  {label:34s} f={f_a/1e3:8.3f} kHz (atan2 {f_th/1e3:8.3f})  位序={note}")
    print(f"      lag(angle_raw - angle) = {lag_mean:+8.3f} deg "
          f"(std {lag_raw.std():.3f}, 残余漂移 {k1*N/FS:+.3f} deg/窗){hint}")

    return dict(label=label, path=path, f=f_a, lag_raw=lag_mean, lag_std=lag_raw.std(),
                drift=k1 * N / FS, lag_at=lag_at.mean())


def main():
    args = sys.argv[1:]
    items = [(a, os.path.basename(a)) for a in args] if args else DEFAULT
    print("=" * 92)
    print("环路系统滞后探测（angle_raw vs angle；mean 未被扣掉才是滞后本身）")
    print("=" * 92)
    rows = []
    for p, lab in items:
        r = probe(p, lab)
        if r:
            rows.append(r)

    print("\n" + "=" * 92)
    print(f"{'档位':34s} {'f_in kHz':>9s} {'lag_raw deg':>12s} {'std':>7s} {'漂移 deg/窗':>11s}  预测(纯P)")
    for r in rows:
        # 纯 P 预测: 360*f_in/12.5e6 / Kp, Kp=2^-6 (kp=4)
        pred = 360 * r["f"] / 12.5e6 / (2 ** -6)
        print(f"{r['label']:34s} {r['f']/1e3:9.3f} {r['lag_raw']:+12.3f} {r['lag_std']:7.3f} "
              f"{r['drift']:+11.3f}  {pred:8.2f}")
    print("=" * 92)
    print("预测说明: 纯 P(kp=4 ⇒ Kp=1/64) 的恒速滞后 = (360*f_in/12.5e6)/Kp = 1.8432e-3 * f_in[Hz] deg")
    print("          ⇒ 1 kHz ≈ 1.84 deg、10 kHz ≈ 18.43 deg（12.5 MHz = v8 门控后的 filt_valid 更新率）")
    print("          含 I 项(ki≥1) 为 II 型系统 ⇒ 稳态速度滞后 0，只剩 ~3 拍流水线(0.24us => 0.09/0.86 deg)")
    print("          v7 及以前未门控(50 MHz 更新) ⇒ 同 kp 下滞后只有上式的 1/4（实测 v7 自由运行 +0.474 deg）")
    print("  ★ 上面 lag 已按 mod 360 归一到 (-180, +180]：`phr`/`pha` 各自独立解卷绕、"
          "首拍不带偏置，窗口首拍若跨 0° 相位边界会把真值显示成 '真值 − 360°'")
    print("    （实测：20 kHz 纯 P 真值 +36.884° 曾被报成 −323.116°，二者相差恰好 360°；"
          "判据只在 ±180° 内成立，故统一归一化）")


if __name__ == "__main__":
    main()
