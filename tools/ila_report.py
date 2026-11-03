# -*- coding: utf-8 -*-
"""ila_report.py —— 一页式 ILA 抓波体检报告（AD9238 磁编码器工程）

用法:
    python _synth_work/ila_report.py _synth_work/iladata3.csv

★★ 位序约定（本脚本自动判定，不要再手工猜）★★
本工程 ILA 导出的 CSV 里，多比特列的位序取决于生成位流时
`tools/ila_debug.tcl` 传给 `connect_debug_port` 的 net 列表方向：
  - 2026-10-10 08:56 及更早的位流：列表按 MSB->LSB 传
    => CSV 的每个多比特列都是**位序反转**的，必须先 bitrev 再解读；
  - 2026-10-10 15:14 起的位流（含 16:12 重建版）：列表已改为 LSB->MSB
    => CSV 位序**正确**，再做 bitrev 反而全错。
判定依据（决定性）: `dbg_stat_byte[7]` 在 `rtl/enc_top.v` 里硬接 1'b0，
  所以"正确解释"下 bit7 必须恒为 0；再加一条物理判据
  `std(hypot(s_raw, c_raw))` 越小越接近正圆。

CSV 读法注意：第 2 行是 `Radix - ...` 说明行（skiprows=[1]），
且必须 `dtype=str`——多比特列是 HEX，若让 pandas 推断类型，
形如 "80"/"08" 的值会被当成十进制，位反/直读都会错。
"""
import sys
import os
import numpy as np
import pandas as pd

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

P = sys.argv[1] if len(sys.argv) > 1 else r"_synth_work/iladata3.csv"

# ---------- 1. 读入 ----------
df = pd.read_csv(P, skiprows=[1], dtype=str)

WIDTH = {}
for c in df.columns:
    if "[" in c:
        a, b = c[c.index("[") + 1: c.index("]")].split(":")
        # 表头区间可能是升序 [0:15]（早期位流）或降序 [15:0]（15:14 起），取绝对值
        WIDTH[c] = abs(int(b) - int(a)) + 1


def bitrev(x, w):
    v = int(x, 16) if isinstance(x, str) else int(x)
    v &= (1 << w) - 1
    r = 0
    for _ in range(w):
        r = (r << 1) | (v & 1)
        v >>= 1
    return r


def sgn(v, w):
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


def build(reverse):
    """按给定方向解码所有多比特列；返回 (未取补码 RAW, 取补码 D)"""
    RAW, D = {}, {}
    for c in df.columns:
        if c in WIDTH:
            w = WIDTH[c]
            r = np.array([bitrev(v, w) if reverse else int(v, 16) for v in df[c]], dtype=np.int64)
            RAW[c] = r
            D[c] = np.array([sgn(v, w) for v in r], dtype=np.int64)
        else:
            D[c] = np.array([int(v) for v in df[c]], dtype=np.int64)
            RAW[c] = D[c]
    return RAW, D


def name(c):
    return c.split("[")[0]


def find(D, key):
    for c in df.columns:
        if name(c) == key:
            return D[c]
    return None


# ---------- 2. 自动判定位序 ----------
cand = {}
for tag, rev in (("msb-first(直读)", False), ("lsb-first(位反)", True)):
    RAW, D = build(rev)
    sb = find(D, "dbg_stat_byte")
    viol = int(np.count_nonzero((sb & 0x80) != 0)) if sb is not None else 0
    s, c_ = find(D, "dbg_s_raw"), find(D, "dbg_c_raw")
    rstd = float(np.hypot(s, c_).std()) if s is not None and c_ is not None else float("inf")
    cand[tag] = dict(rev=rev, viol=viol, rstd=rstd, RAW=RAW, D=D)

best = min(cand.items(), key=lambda kv: (kv[1]["viol"], kv[1]["rstd"]))
TAG, CH = best
REVERSE = CH["rev"]
RAW, D = CH["RAW"], CH["D"]

N = len(df)
FS = 50e6
T = np.arange(N) / FS


def col(*keys):
    for k in keys:
        v = find(D, k)
        if v is not None:
            return v
    raise KeyError(keys)


print("=" * 78)
print(f"文件      : {P}")
print(f"采样点    : {N}   窗口: {N/FS*1e6:.2f} us   采样率: {FS/1e6:.0f} MHz (clk_i)")
print("=" * 78)

print("\n[0] 位序判定（★先看这里）")
for tag, v in cand.items():
    mark = "  <== 采用" if tag == TAG else ""
    print(f"  {tag:18s}: stat_byte bit7 违例 {v['viol']:5d} 处, "
          f"hypot(s_raw,c_raw) std = {v['rstd']:9.2f}{mark}")
if REVERSE:
    print("  => 本 CSV 来自**旧位流**（08:56 及更早），已自动做位序反转。")
else:
    print("  => 本 CSV 位序**正确**（15:14 起的位流，含 16:12 重建版），未做反转。")

# ---------- 3. 基本计数 ----------
print("\n[1] 时基与握手")
adv = col("dbg_adc_valid")
print(f"  dbg_adc_valid : 恒 {int(adv[0])}  (取值集合 {sorted(set(adv.tolist()))[:4]})"
      f"   <- RTL 里非复位期间恒 1，**不能当触发条件**")
for k, want in (("dbg_dec_valid", "每 4 拍 1 个 (LOG2DEC=2)"),
                ("dbg_cor_valid", "每 4 拍 1 个"),
                ("dbg_cordic_valid", "每 4 拍 1 个")):
    v = find(D, k)
    if v is None:
        continue
    n1 = int(np.count_nonzero(v))
    print(f"  {k:16s}: {n1} 个有效脉冲 / {N} 点 = 1/{N/max(n1,1):.2f}   ({want})")
trg = col("TRIGGER")
pos = np.where(trg == 1)[0]
print(f"  TRIGGER       : " + (f"第 {pos.tolist()} 拍（窗口 {N} 点）" if len(pos) else "**没有触发标记**"))

# ---------- 4. 模拟前端 ----------
s, c_ = col("dbg_s_raw"), col("dbg_c_raw")
r12 = np.hypot(s, c_)
th = np.unwrap(np.arctan2(s, c_))
slope = np.polyfit(T, th, 1)[0]
f_in = abs(slope) / (2 * np.pi)

print("\n[2] 模拟前端（12bit 二进制补码：0V->000h, -5V->800h, +5V->7FFh）")
print(f"  f_in          = {f_in/1e3:.3f} kHz")
print(f"  半径 r        = {r12.mean():.1f} +/- {r12.std():.1f}  (min {r12.min():.1f} max {r12.max():.1f})")
print(f"  等效幅度      = {r12.mean()/2048*5*2:.3f} Vpp")
print(f"  s 范围 [{s.min()},{s.max()}]   c 范围 [{c_.min()},{c_.max()}]"
      f"   (削顶会贴死 +/-2048)")
ups = np.where((s[:-1] < 0) & (s[1:] >= 0))[0]
upc = np.where((c_[:-1] < 0) & (c_[1:] >= 0))[0]
if len(ups) >= 2 and len(upc) >= 2:
    Ts = ups[1] - ups[0]
    d = (upc[0] - ups[0]) % Ts
    if d > Ts / 2:
        d -= Ts
    print(f"  正交性        : s 上升过零 {ups[:4].tolist()} / c {upc[:4].tolist()}  "
          f"周期 {Ts} 拍 => 相差 {d/Ts*360:.1f} deg (目标 +/-90)")
else:
    print(f"  正交性        : 跳过（窗口内上升过零不足：s {len(ups)} 个 / c {len(upc)} 个）")
    print(f"                  —— 输入周期远长于 1024 拍(20.48us)窗口时属正常；低频抓包请改判"
          f"同一时刻的 s/c 瞬时值与半径 r")

# ---------- 5. 抽取 + CORDIC ----------
s16, c16 = col("dbg_s_dec"), col("dbg_c_dec")
r16 = np.hypot(s16, c16)
mag = col("dbg_cordic_mag")
ang, angr = col("dbg_angle"), col("dbg_angle_raw")
print("\n[3] 抽取链与 CORDIC")
print(f"  r16 (s_dec/c_dec) = {r16.mean():.1f} +/- {r16.std():.1f}   r16/r12 = {r16.mean()/max(r12.mean(),1e-9):.2f}")
print(f"  cordic_mag        = {mag.mean():.1f} +/- {mag.std():.1f}   (Q 格式放大，基本恒定=信号正常)")


def linear_res(series, nm):
    """把 16bit 角度当无符号相位做线性拟合，返回 (斜率拍/圈, RMS 残差deg, 最大偏差deg, 偏差拍号)"""
    ph = np.unwrap(series / 65536 * 2 * np.pi)
    k, b = np.polyfit(T, ph, 1)
    res = np.degrees(ph - (k * T + b))
    i = int(np.argmax(np.abs(res)))
    print(f"  {nm:10s}: {abs(k)/(2*np.pi)/1e3:.3f} kHz, 线性残差 RMS {np.degrees(np.std(ph-(k*T+b))):.3f} deg, "
          f"最大偏差 {res[i]:+.3f} deg @第 {i} 拍")
    return ph, res


print("\n[4] 角度链线性度")
phr, resr = linear_res(angr, "angle_raw")
pha, resa = linear_res(ang, "angle")
err = np.unwrap(ang / 65536 * 2 * np.pi) - th
# ★★ 2026-10-11：这里的均值必须单独打印出来再扣！
#    那个均值就是环路的"稳态速度滞后"（纯 P 环路 ∝ f_in/kp，含 I 项 ≈ 0）。
#    以前只打印扣掉均值后的残差 RMS，导致 §1.46 的 sweep 得出"纯 P 最优"的假象
#    （见 docs/DEV_STATUS.md §1.48）。完整分析见 tools/lag_probe.py。
lag_deg = np.degrees(np.mean(err))
# ★ 2026-10-11（20 kHz 实测踩到）：`ang` 与 `th` 各自独立解卷绕、首拍不带偏置 ⇒
#   窗口首拍若跨 0°/360° 相位边界，真值会被显示成"真值 ± 360°"
#   （实测 20 kHz 纯 P：真值 −36.9° 曾显示成 +319.233°，与 tools/lag_probe.py 同因）。
#   滞后判据只在 ±180° 内成立 ⇒ 统一归一到 (-180, +180]，并在发生回绕时如实标注。
lag_deg_wrapped = (lag_deg + 180.0) % 360.0 - 180.0
_wrap_note = ""
if abs(lag_deg_wrapped - lag_deg) > 1e-6:
    _wrap_note = f" ← 原始均值 {lag_deg:+.3f}° 相差 360°×整数，已按 mod 360 归一（同 tools/lag_probe.py）"
lag_deg = lag_deg_wrapped
err = err - np.mean(err)
print(f"  angle(环路后) 与 atan2(s,c) 的残差 RMS = {np.degrees(np.std(err)):.3f} deg")
print(f"  ★ 其中的**恒定滞后**（均值，本行 = mean(angle − atan2)）= {lag_deg:+.3f} deg  <-- 环路速度滞后，别丢！"
      f"（纯 P 预测 {-1.8432e-3*f_in:+.2f} deg 即滞后，含 I 项应 ≈0；符号相反的量见 tools/lag_probe.py）{_wrap_note}")

# ---------- 6. ★ angle_raw 毛刺专项 ----------
print("\n[5] ★ angle_raw 毛刺专项")
dv = find(D, "dbg_dec_valid")
nom = 65536 * f_in / FS              # 每采样拍标称步进（LSB）
print(f"  标称步进      = {nom:.1f} LSB/拍  (65536 x f_in / 50MHz)")
d1 = np.diff(angr.astype(np.float64))
d1s = d1.copy()
d1s[d1 < -32768] += 65536            # 回绕
d1s[d1 > 32768] -= 65536
zero = int(np.count_nonzero(d1s == 0))
print(f"  逐拍步进      : 0 值 {zero} 个 ({zero/(N-1)*100:.1f}%, 抽取保持), "
      f"非零步进 min {d1s[d1s!=0].min():.0f} / 中位 {np.median(d1s[d1s!=0]):.0f} / max {d1s[d1s!=0].max():.0f}")
back = np.where(d1s < 0)[0]
nz = d1s[d1s != 0]
med_nz = np.median(nz) if len(nz) else 0.0
odd1 = np.where((d1s != 0) & (np.abs(d1s - med_nz) > 0.15 * max(med_nz, 1)))[0]
print(f"  倒退步        : {len(back)} 处" + (f" -> 拍号 {back[:12].tolist()}, 幅度 {d1s[back][:12].tolist()}" if len(back) else ""))
print(f"  非零步进即 dec_valid 更新点({len(nz)} 个), 中位 {med_nz:.0f} ≈ 4x 标称 {4*nom:.0f};"
      f" 偏离中位 >15% 的 {len(odd1)} 处" + (f" -> 拍号 {odd1[:12].tolist()}, 幅度 {d1s[odd1][:12].tolist()}" if len(odd1) else "  ⇒ 无毛刺"))
if dv is not None:
    ui = np.where(dv == 1)[0]
    if len(ui) > 2:
        ua = angr[ui].astype(np.float64)
        du = np.diff(ua)
        du[du < -32768] += 65536
        du[du > 32768] -= 65536
        med = np.median(du)
        odd = np.where(np.abs(du - med) > 0.25 * abs(med))[0]
        print(f"  只看 dec_valid 更新点({len(ui)} 个): 步进中位 {med:.0f} LSB, "
              f"偏离 >25% 的 {len(odd)} 处" + (f" -> 拍号 {ui[odd][:12].tolist()}, 步进 {du[odd][:12].tolist()}" if len(odd) else "  ⇒ 无毛刺"))
res_deg = resr                            # linear_res 已返回「度」
print(f"  残差(相对理想斜坡): RMS {np.std(res_deg):.3f} deg, "
      f"|max| {np.abs(res_deg).max():.3f} deg @第 {int(np.argmax(np.abs(res_deg)))} 拍")

# ---------- 6b. ★ Z 通道脉宽专项（v9 判据：宽度 = (z_width+1) 个 AB 边沿步）----------
#  为什么单独一节：Z 脉宽是**时间量**，不是角度量。板上判据 = (z_width+1)/(4*inter/div)/f_in
#  ⇒ 用 f_in（本报告 [2] 节自己量出来的）就能把"拍数"折算成"边沿步数"，不必依赖示波器。
#  inter/div 不在探针里（只在寄存器 0x0101/0x0102），所以支持用环境变量喂进来：
#    ILA_INTER=256  ILA_DIV=1  ILA_ZWIDTH=4  （默认 256 / 1 / 不判）
zo = find(D, "dbg_z_out")
zw = find(D, "dbg_z_window")
if zo is not None:
    print("\n[5b] ★ Z 通道脉宽专项（v9 判据：宽度 = (z_width+1) 个 AB 边沿步）")
    z = zo.astype(np.int64)
    d = np.diff(np.concatenate(([0], z, [0])))
    st_i = np.where(d == 1)[0]
    en_i = np.where(d == -1)[0]
    wid = (en_i[:len(st_i)] - st_i[:len(st_i)]) if len(st_i) else np.array([], dtype=np.int64)
    print(f"  z_out    : 高电平 {int(z.sum())} / {N} 拍, 脉冲 {len(st_i)} 个"
          + (f", 起始拍 {st_i[:8].tolist()}" if len(st_i) else ""))
    if zw is not None:
        print(f"  z_window : 高电平 {int(zw.sum())} / {N} 拍 ({zw.sum()/N*100:.1f}%)")
    if len(wid):
        inter = int(os.environ.get("ILA_INTER", "256") or 256)
        div = int(os.environ.get("ILA_DIV", "1") or 1)
        edges_per_rev = 4 * inter / div
        steps = wid / FS * edges_per_rev * f_in      # 每个脉冲跨了几个 AB 边沿步
        print(f"  脉宽(拍)  : min {wid.min()} / 中位 {int(np.median(wid))} / max {wid.max()}")
        print(f"  脉宽(时间): 中位 {np.median(wid)/FS*1e6:.3f} us  "
              f"(= {np.median(wid)/FS*1e6*1e3:.1f} ns/步 x {np.median(steps):.2f} 步)")
        print(f"  折算边沿步: min {steps.min():.2f} / 中位 {np.median(steps):.2f} / max {steps.max():.2f} 步"
              f"   ← ⚠ **窗口平均 f_in 口径，仅作旁证**（与下面「边沿计步」可差 ±5%）"
              f"   (取 inter={inter} div={div} ⇒ {edges_per_rev:.0f} 边沿/电周期, f_in={f_in/1e3:.3f} kHz)")
        print(f"  理论判据  : 宽 = (z_width+1) / ({edges_per_rev:.0f} x f_in)"
              f" = {(int(os.environ.get('ILA_ZWIDTH', '4') or 4)+1)/edges_per_rev/f_in*1e6:.3f} us"
              f"  @0x0108 z_width={int(os.environ.get('ILA_ZWIDTH', '4') or 4)}"
              f"  [1 步 = {1/edges_per_rev/f_in*1e6:.3f} us = {FS/edges_per_rev/f_in:.1f} 拍]")
        # ------------------------------------------------------------------
        # ★★ 首选判据：直接数**实测 A/B 边沿**，看 Z 高电平跨了几个边沿步。
        #   为什么必须有这一条：上面那行「折算边沿步」用的是**整个窗口的平均 f_in**，
        #   而边沿步长应当按 Z 脉冲**附近**的真实边沿间隔算。2026-10-11 v9 实测：
        #   窗口平均口径给出 4.80 步（看着像"少了 0.2 步"），而按实测边沿数正好 **5 步**
        #   —— 两者差 5% 全部来自窗口平均频率与脉冲附近瞬时边沿率的偏差。
        #   ⇒ 板上判据一律以「边沿计步」为准；f_in 折算只作旁证。
        #   口径：起点落在边沿上、终点落在边沿上时，[start,end) 内的 A/B 边沿数 = 步数。
        # ------------------------------------------------------------------
        ao = find(D, "dbg_a_out")
        bo = find(D, "dbg_b_out")
        if ao is not None and bo is not None:
            aa = ao.astype(np.int64)
            bb = bo.astype(np.int64)
            ed = np.where((np.diff(aa) != 0) | (np.diff(bb) != 0))[0] + 1
            if len(ed) > 1:
                ivs = np.diff(ed)
                print(f"  A/B 边沿 : 窗内 {len(ed)} 个, 间隔 min {int(ivs.min())} / 中位 {int(np.median(ivs))} / max {int(ivs.max())} 拍"
                      f"   (平均口径 1 步 = {FS/edges_per_rev/f_in:.1f} 拍)")
            for k in range(min(len(st_i), len(en_i))):
                s, e = int(st_i[k]), int(en_i[k])
                n_in = int(np.count_nonzero((ed >= s) & (ed < e)))
                on_s = bool(np.any(ed == s))
                on_e = bool(np.any(ed == e))
                print(f"  ★ 边沿计步(首选判据): 脉冲[{k}] [{s},{e}) 宽 {e-s} 拍, "
                      f"起点在边沿上={'是' if on_s else '否'} 终点在边沿上={'是' if on_e else '否'}"
                      f" ⇒ [start,end) 内边沿 {n_in} 个 ⇒ **{n_in} 个边沿步**"
                      + ("  ✅ 与 v9 的 z_width+1 一致" if n_in == int(os.environ.get('ILA_ZWIDTH', '4') or 4) + 1
                         else f"  (v9 期望 {int(os.environ.get('ILA_ZWIDTH', '4') or 4)+1} / v8 语义 {int(os.environ.get('ILA_ZWIDTH', '4') or 4)})"))
                if not (on_s and on_e):
                    print(f"     ⚠ 起点/终点未正好落在 A/B 边沿上（采样相位差 ≤1 拍）⇒ 边沿计步可能差 ±1 步，"
                          f"请结合脉宽(拍)={e-s} 与附近边沿间隔 {int(np.median(ivs)) if len(ed) > 1 else 0} 拍交叉核对")
        if len(st_i) and len(en_i) and en_i[0] < st_i[0]:
            print("  ⚠ 窗口第一个脉冲在触发点之前就已开始（起始拍不在窗口内）⇒ 脉宽会被低估，请加大 ILA_DEPTH 或改触发位置")
    else:
        print("  ⇒ 窗口内没有 Z 脉冲（z_out 恒低）。触发探针若选在 z_out 上不该出现这种情况；"
              "若触发在 adc_valid 上，请改用 ILA_TRIG=z_out 重新抓。")

# ---------- 7. 状态与输出 ----------
print("\n[6] 状态位与输出")
pp = col("dbg_pole_pairs_eff")
st = col("dbg_stat_byte")
cc = col("dbg_cycle_cnt")
print(f"  pole_pairs_eff = {int(pp[0])}    (配置 0x0100=0x04)")
print(f"  stat_byte      = 0x{int(st[0]):02X} (取值集合 {[hex(int(v)) for v in sorted(set(st.tolist()))]})")
print(f"  cycle_cnt      = 取值集合 {sorted(set(cc.tolist()))[:10]}")
print(f"  pos_full[0]    = 0x{int(col('dbg_pos_full')[0]) & 0xffffffff:08X}"
      f" -> 高16位 {int(col('dbg_pos_full')[0]) >> 16}, 低16位 {int(col('dbg_pos_full')[0]) & 0xffff}")
for k in ("dbg_otr_lat", "dbg_cor_sat", "dbg_lag_warn", "dbg_lag_fatal", "dbg_limiter_active",
          "dbg_uvw_freq_warn", "dbg_u_out", "dbg_v_out", "dbg_w_out", "dbg_dir"):
    v = find(D, k)
    if v is None:
        continue
    u = sorted(set(v.tolist()))
    print(f"  {k:20s} = {u if len(u) <= 4 else str(u[:4]) + '...'}  (1 的个数 {int(np.count_nonzero(v))})")
for k in ("dbg_wrap_pos", "dbg_wrap_neg", "dbg_z_out", "dbg_z_window", "dbg_a_out", "dbg_b_out"):
    v = find(D, k)
    if v is None:
        continue
    ch = int(np.count_nonzero(np.diff(v) != 0))
    print(f"  {k:20s} : 1 的个数 {int(np.count_nonzero(v)):5d}, 翻转 {ch:4d} 次")

# ---------- 8. 逐条探针表 ----------
print("\n[7] 逐条探针读数表（位宽/范围/翻转）")
print(f"  {'探针':26s} {'宽':>3s} {'min':>12s} {'max':>12s} {'翻转':>6s}  判定")
for c in df.columns:
    if c in ("Sample in Buffer", "Sample in Window", "TRIGGER"):
        continue
    n = name(c)
    if c in WIDTH:
        w = WIDTH[c]
        r = RAW[c]
        lo, hi = int(r.min()), int(r.max())
        ch = int(np.count_nonzero(np.diff(r) != 0))
        if w == 1:
            verdict = "OK(常值 %d)" % lo if lo == hi else "OK"
        elif lo == hi:
            verdict = "!! 全窗常数 = 0x%X" % lo
        else:
            verdict = "OK"
        print(f"  {c:26s} {w:3d} {lo:12d} {hi:12d} {ch:6d}  {verdict}")
    else:
        v = D[c]
        ch = int(np.count_nonzero(np.diff(v) != 0))
        print(f"  {c:26s} {1:3d} {int(v.min()):12d} {int(v.max()):12d} {ch:6d}  "
              f"{'OK' if int(v.min()) != int(v.max()) else 'OK(常值)'}")
print("=" * 78)
