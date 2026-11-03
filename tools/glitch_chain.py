# -*- coding: utf-8 -*-
"""glitch_chain.py —— D 分支取证：angle_raw 毛刺的逐级链（v9 ILA 抓波）

用法:
    python tools/glitch_chain.py _synth_work/ila_cap_v9_glitch1.csv [more.csv ...]

目的：把 §1.45 / §1.37 ③ 在 v6 上做过的"逐级链"取证搬到 v9（Z 修复 + 环路门控版），
并对每个 `dbg_ang_glitch` 事件打印：
    1) 触发拍号与 glitch 脉冲宽度（v6 观测为 4 clk）
    2) 单点尖峰所在拍/通道（s_raw 或 c_raw）相对局部中值的偏差（LSB）与相对"每拍标称步长"的倍数
    3) 该尖峰经抽取平均后的 s_dec/c_dec 幅度（v6 观测 ≈ 4× 单点偏差）
    4) cor_sat / otr_lat 是否在尖峰附近置位
    5) stat_byte 的取值跳变（按位名解码；bit5 = scamp 是 ADC 幅度事件的代理）
    6) CORDIC 侧 cordic_mag 偏差、angle_raw 的单拍最大跳变（LSB 与度）
    7) 滤波后 angle 的过冲幅度与收回时间 —— 检验 v8/v9 的毛刺门控是否削弱了环路再注入
    （v6 对照 `_synth_work/ila_cap_stage2.csv` 同口径：angle 过冲 +1343 LSB = +7.38°，
     34 拍到峰、6 拍收回；同一工具在 v9 四版窗口上给出 −0.58…−0.92°）
    ★ 相位必须用**未被污染**的值算（坏路取邻域中值、好路取尖峰拍实测）：直接用
      atan2(s[best], c[best]) 会得到"固定码 vs 实测值"的常数，看着像相位锁定其实毫无意义。

★ 位序约定：与 tools/ila_report.py 完全一致（自动判定）：多比特列可能是位反的，
  判据 = `dbg_stat_byte[7]` 硬接 0（违例数最小）+ std(hypot(s_raw,c_raw)) 最小（正圆）。
★ 读法：第 2 行是 `Radix - ...` 说明行（skiprows=[1]），必须 dtype=str。
★ 单点尖峰判据用 ±16 拍滑动中值作基线：20 kHz 下正弦每拍只动 ~4 LSB，
  33 拍窗内中值基线残差上限约 ~65 LSB，而实测毛刺是 ~2300 LSB 量级，区分度充分。
"""
import sys
import numpy as np
import pandas as pd

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

BITNAME = {0: "oflow", 1: "falarm", 2: "laglim", 3: "inclim",
           4: "lagfatl", 5: "scamp", 6: "adapt", 7: "res"}


def load(P):
    df = pd.read_csv(P, skiprows=[1], dtype=str)
    W = {}
    for c in df.columns:
        if "[" in c:
            a, b = c[c.index("[") + 1: c.index("]")].split(":")
            W[c] = abs(int(b) - int(a)) + 1

    def bitrev(x, w):
        v = int(x, 16) & ((1 << w) - 1)
        r = 0
        for _ in range(w):
            r = (r << 1) | (v & 1)
            v >>= 1
        return r

    def sgn(v, w):
        v &= (1 << w) - 1
        return v - (1 << w) if v >> (w - 1) else v

    def build(rev):
        RAW, D = {}, {}
        for c in df.columns:
            if c in W:
                w = W[c]
                r = np.array([bitrev(v, w) if rev else int(v, 16) for v in df[c]], dtype=np.int64)
                RAW[c] = r
                D[c] = np.array([sgn(v, w) for v in r], dtype=np.int64)
            else:
                D[c] = np.array([int(v) for v in df[c]], dtype=np.int64)
                RAW[c] = D[c]
        return RAW, D

    def nm(c):
        return c.split("[")[0]

    def f(D, k):
        for c in df.columns:
            if nm(c) == k:
                return D[c]
        return None

    cand = {}
    for tag, rev in (("直读", False), ("位反", True)):
        RAW, D = build(rev)
        sb = f(D, "dbg_stat_byte")
        viol = int(np.count_nonzero((sb & 0x80) != 0)) if sb is not None else 0
        s, c_ = f(D, "dbg_s_raw"), f(D, "dbg_c_raw")
        rstd = float(np.hypot(s, c_).std()) if s is not None and c_ is not None else float("inf")
        cand[tag] = dict(rev=rev, viol=viol, rstd=rstd, D=D)
    tag, CH = min(cand.items(), key=lambda kv: (kv[1]["viol"], kv[1]["rstd"]))
    # 以"列基名"（去掉 [msb:lsb]）为键，便于按探针名取用
    D2 = {}
    for c in df.columns:
        D2[nm(c)] = CH["D"][c]
    return df, D2, tag, CH["viol"], CH["rstd"], CH["rev"]


def medfilt(x, half=16):
    n = len(x)
    out = np.zeros(n)
    for j in range(n):
        out[j] = np.median(x[max(0, j - half): min(n, j + half + 1)])
    return out


def report(P):
    df, D, tag, viol, rstd, rev = load(P)
    g = D.get("dbg_ang_glitch")
    if g is None:
        raise SystemExit("CSV 里没有 dbg_ang_glitch 探针：%s" % P)
    s, c_ = D["dbg_s_raw"], D["dbg_c_raw"]
    sdec = D.get("dbg_s_dec")
    cdec = D.get("dbg_c_dec")
    scor = D.get("dbg_s_cor")
    ccor = D.get("dbg_c_cor")
    st = D.get("dbg_stat_byte")
    csat = D.get("dbg_cor_sat")
    otr = D.get("dbg_otr_lat")
    cmag = D.get("dbg_cordic_mag")
    araw = D.get("dbg_angle_raw")
    ang = D.get("dbg_angle")
    corv = D.get("dbg_cordic_valid")
    n = len(g)

    g = np.asarray(g).astype(int)
    lead = [i for i in range(1, n) if g[i] == 1 and g[i - 1] == 0]
    if g[0] == 1:
        lead.insert(0, 0)

    print("=" * 78)
    print("CSV: %s" % P)
    print("  位序判定=%s (rev=%s)  stat_byte[7] 违例=%d  std(hypot(s,c))=%.2f  样本=%d"
          % (tag, rev, viol, rstd, n))
    if not lead:
        print("  ★ 本窗口内没有 dbg_ang_glitch 上升沿（0 个毛刺事件）")
        return dict(file=P, n=0, events=[])
    # 脉冲宽度
    widths = []
    for i in lead:
        k = i
        while k < n and g[k] == 1:
            k += 1
        widths.append(k - i)
    ms, mc = medfilt(s), medfilt(c_)
    ds, dc = s - ms, c_ - mc
    ad = np.abs(np.diff(s)) + np.abs(np.diff(c_))
    nom = float(np.median(ad[ad > 0])) if np.any(ad > 0) else 1.0
    print("  毛刺事件 %d 个（脉冲宽度 min/中位/max = %d/%d/%d 拍）；"
          "s/c 每拍标称步长中位 = %.1f LSB" % (len(lead), min(widths),
                                            int(np.median(widths)), max(widths), nom))
    events = []
    for e, i in enumerate(lead):
        lo = max(0, i - 40)
        hi = min(n - 1, i + 2)
        js = range(lo, hi + 1)
        best = max(js, key=lambda j: max(abs(ds[j]), abs(dc[j])))
        ch = "s_raw" if abs(ds[best]) >= abs(dc[best]) else "c_raw"
        dev = int(ds[best] if ch == "s_raw" else dc[best])
        # 抽取级（尖峰后 2~4 拍）
        dec_s = int(np.max(np.abs(np.diff(sdec[best:best + 6])))) if sdec is not None else 0
        dec_c = int(np.max(np.abs(np.diff(cdec[best:best + 6])))) if cdec is not None else 0
        sat = [j for j in range(max(0, best - 2), min(n, best + 12)) if csat is not None and csat[j]]
        ot = [j for j in range(max(0, best - 2), min(n, best + 12)) if otr is not None and otr[j]]
        # stat_byte 跳变
        sb = []
        for j in range(max(0, best - 2), min(n, best + 14)):
            if st is not None and (j == max(0, best - 2) or st[j] != st[j - 1]):
                sb.append((j, int(st[j])))
        # angle_raw 最大单拍跳变（尖峰后 40 拍）
        w = range(best, min(n - 1, best + 40))
        if araw is not None and len(list(w)) > 1:
            jj = max(w, key=lambda j: abs(int(araw[j + 1]) - int(araw[j])))
            jumpr = int(araw[jj + 1]) - int(araw[jj])
            cmdev = int(cmag[jj + 1] - np.median(cmag[max(0, jj - 40):jj + 40])) if cmag is not None else 0
        else:
            jj, jumpr, cmdev = -1, 0, 0
        # angle 过冲
        # angle 过冲：必须去掉"固有旋转"——20 kHz 下 angle 每拍就前进 ~26 LSB，
        # 直接做差会把正常旋转当成过冲。做法：用事件前 [best-44, best-4) 的线性趋势外推作基线。
        if ang is not None:
            L = min(n - best, 60)
            pre = ang[max(0, best - 44):max(1, best - 4)].astype(float)
            if len(pre) >= 8:
                k1, k0 = np.polyfit(np.arange(len(pre), dtype=float), pre, 1)
            else:
                k1, k0 = 0.0, float(np.median(pre))
            x0 = best - max(0, best - 44)          # pre[0] 对应的拍号
            xs = (np.arange(best, best + L) - (best - x0)).astype(float)
            off = ang[best:best + L].astype(float) - (k0 + k1 * xs)
            k = int(np.argmax(np.abs(off)))
            peak = float(off[k])
            rec = -1
            for q in range(k, len(off)):
                if abs(off[q]) < 0.1 * abs(peak):
                    rec = q - k
                    break
            ang_peak_lsb, ang_peak_deg, ang_rec, slope = peak, peak * 360.0 / 65536.0, rec, k1
        else:
            ang_peak_lsb = ang_peak_deg = ang_rec = slope = 0.0
        print("  --- 事件 %d：触发拍 %d（尖峰拍 %d，%s，偏差 %+d LSB = %+.2f× 标称步长）"
              % (e + 1, i, best, ch, dev, dev / nom if nom else 0.0))
        # ★ 相位：必须用**未被污染**的值算，否则是伪值！
        #   尖峰拍上被写坏的那一路要用邻域中值（medfilt）代替，另一路取尖峰拍的实测值。
        #   反例（曾踩过）：直接用 (s[best], c[best]) 会得到 atan2(固定码, 实测) 的常数，
        #   看似"相位锁定 +56°"，其实只是 atan2 两个数而已，与波形相位无关。
        s_true = float(ms[best]) if ch == "s_raw" else float(s[best])
        c_true = float(mc[best]) if ch == "c_raw" else float(c_[best])
        ph_true = float(np.degrees(np.arctan2(s_true, c_true)))
        amp_true = float(np.hypot(s_true, c_true))
        print("      尖峰绝对码（12bit 无符号）：s_raw=0x%03X (%d) / c_raw=0x%03X (%d)"
              % (int(s[best]) & 0xFFF, int(s[best]) & 0xFFF, int(c_[best]) & 0xFFF, int(c_[best])))
        print("      ★ 波形相位（用未被污染的值算：坏路取邻域中值 %.0f / 好路取实测）：atan2=%.1f°，瞬时半径 %.0f LSB"
              % (s_true if ch == "s_raw" else c_true, ph_true, amp_true))
        print("        （被污染码的组合相位 atan2(s[best],c[best])=%+.1f° 是伪值，不能用来判相位锁定）"
              % float(np.degrees(np.arctan2(s[best], c_[best]))))
        print("      抽取级 Δ(max) s_dec %d / c_dec %d LSB；cor_sat %s；otr_lat %s"
              % (dec_s, dec_c, ("拍 " + str(sat)) if sat else "未见",
                 ("拍 " + str(ot)) if ot else "未见"))
        print("      stat_byte: %s" % " ".join("拍%d=0x%02X[%s]" % (
            j, v, ",".join(BITNAME[b] for b in range(8) if v >> b & 1) or "-") for j, v in sb))
        print("      angle_raw 最大单拍跳变 %+d LSB = %+.2f°（拍 %d，cordic_mag 偏差 %+d）"
              % (jumpr, jumpr * 360.0 / 65536.0, jj, cmdev))
        print("      ★ angle(滤波后) 过冲 %+.0f LSB = %+.2f°，到峰 %d 拍，收回 %s 拍（已按事件前线性趋势外推扣除固有旋转，斜率 %+.1f LSB/拍；v6 对照 ila_cap_stage2.csv 同口径 = +1343 LSB / +7.38°）"
              % (ang_peak_lsb, ang_peak_deg, k, ("%d" % ang_rec) if ang_rec >= 0 else "未收回", slope))
        events.append(dict(frame=i, spike=best, ch=ch, dev=dev, jumpr=jumpr,
                           ang_peak_lsb=ang_peak_lsb, ang_peak_deg=ang_peak_deg))
    return dict(file=P, n=len(lead), events=events)


def main():
    files = sys.argv[1:] or ["_synth_work/ila_cap_v9_glitch1.csv"]
    allr = [report(P) for P in files]
    tot = sum(r["n"] for r in allr)
    print("=" * 78)
    print("合计毛刺事件 %d 个（%d 个窗口，每窗口 1024 拍 = 20.48 µs @50 MHz）"
          % (tot, len(allr)))
    print("⚠ 这些窗口是**以 dbg_ang_glitch 触发**抓来的 ⇒ 每窗口必然含触发事件，")
    print("  不能据此算毛刺率（率必须用 tools/diag_counters.py 的计数器读数）。")
    if tot:
        pk = np.array([abs(e["ang_peak_lsb"]) for r in allr for e in r["events"]], dtype=float)
        if len(pk):
            print("⇒ angle 过冲 |峰值| LSB: 中位 %.0f  最大 %.0f（v6 对照 ila_cap_stage2.csv = 1343）" % (
                np.median(pk), pk.max()))


if __name__ == "__main__":
    main()
