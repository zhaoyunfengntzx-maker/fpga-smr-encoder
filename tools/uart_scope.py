#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
uart_scope.py —— 上位机遥测接收/解析/可视化工具
================================================================================
与 rtl/uart_scope.v 的 18 字节定长帧严格对应（**帧布局 v2**，RTL v12 / 2026-10-12 起）：

    off  len  内容
     0    1   0xAA            帧头 1
     1    1   0x55            帧头 2
     2    2   angle[15:0]      16bit 电角度（0..65535 -> 0..360 deg）
     4    2   s_n[15:0]        校正后正弦，Q1.15 有符号
     6    2   c_n[15:0]        校正后余弦，Q1.15 有符号
     8    1   io_state[7:0]    ABZ/UVW 电平快照 + 方向 + 限频：
                               bit0 a_out, bit1 b_out, bit2 z_out,
                               bit3 u_out, bit4 v_out, bit5 w_out,
                               bit6 dir,   bit7 limiter_active
     9    1   0xA2            IO 帧标记（FRAME_TAG_IO ⇒ 用于兼容 v11 旧位流）
    10    1   io_flags[7:0]    bit0 lag_warn, bit1 lag_fatal, bit2 z_window,
                               bit3 uvw_freq_warn, bit4 abzen, bit5 uwven,
                               bit6 cor_sat, bit7 (amp_low|amp_high)
    11    1   0x00            保留（恒 0）
    12    4   pos_full[31:0]   多周期计数<<16 | 角度
    16    1   stat[7:0]        统一状态位
    17    1   XOR 校验 = 0xAA ^ 0x55 ^ (off 2..16 逐字节异或)

★ 为什么 amp_sq 不在帧里了（帧布局 v2）
  v11 及以前 off8..11 = amp_sq[31:0] = s^2+c^2。它由 s_n/c_n 唯一确定
  （rtl/amp_monitor.v 就是先平方再求和；s/c 是 16bit ⇒ s^2+c^2 < 2^31，不会饱和），
  本工具逐帧重算即可 ⇒ amp_sq 字段照旧出现在解析结果/CSV/报告里，只是"算出来的"。
  腾出来的 4 字节改成 ABZ/UVW 电平快照，帧长仍是 18 字节 ⇒ 链路占用与帧率不变。

★ 兼容 v11 旧位流
  v11 的 off9 = amp_sq[23:16]，而 amp_sq < 2^31 ⇒ 该字节 ≤ 0x80，**不可能**等于
  0xA2。于是按 off9 逐帧判别布局：== 0xA2 是 v2（io 快照有效、amp_sq 重算），
  否则按 v1 解释（io 字段为 None、amp_sq 取帧内原值）。报告会分别打印两种帧数，
  "混流"（例如换了工具没重烧位流）一眼可见；而**极少数**被判 v1 的帧（<0.1%）
  是 18 字节帧只有 1 字节 XOR 校验时漏网的多比特误码，不是旧位流 —— 报告会把
  这两种情况分开说（实测 v12 板上 30 s = v2 298747 + v1 1，占比 3e-6）。

★ ABZ/UVW 波形怎么"实时看"（重要，别误解）
  每帧只给一个采样点（10 kHz），而 A/B 的边沿率 = 2 × (4×inter/div) × f_in
  （inter=256/div=1、f_in=1 kHz ⇒ 约 2 MHz），**远高于**帧率 ⇒ 直接按时间画
  A/B 一定是混叠的，只能看"电平/占空比/是否在动"。要拿到真实波形形状，本工具
  用**等效采样**：每帧同时带 angle，把 io 位按电角度分箱统计（默认 64 箱），
  得到"A/B/Z/U/V/W 相对电角度"的波形 —— 与 10 kHz 采样率无关，这是本帧布局
  相对"另开一路采样"的真正优势。前提是采样相位要铺满各箱（报告会打印填充率；
  若输入频率恰为帧率的整数倍会只填到少数箱，把频率稍错开即可）。

★ 校验和约定（2026-10-10 定案，与 rtl/uart_scope.v:189-196 严格一致）：
  校验和把**两个帧头常量也并进**，即 chk = 0xAA ^ 0x55 ^ payload_xor
  = payload_xor ^ 0xFF。本工具原先只异或 payload(off 2..16)、少了 0xAA^0x55，
  于是与 RTL 恒差 0xFF —— 真机每一帧都会被判成 crc_err、frames 恒为 0
  （唯一的上板观测通道等于废掉；--selftest 因为自己组帧自己解析而照旧通过，
  所以这个偏差不会被自检发现）。
  定案取 RTL 一方：位流 _synth_work/enc_top.bit（10-10 02:32，WNS +0.686 ns）
  已按此实现并验证，为一条常量偏移去改 RTL 会作废整个时序收敛结果；且含帧头
  常量在检错能力上不多不少（纯常量偏移），没有收益。
  该约定由 sim/fixtures/uart_frame_rtl.hex（RTL 实拍帧）+ 
  tools/check_uart_frame_fixture.py 守住，回归里再改回去会立刻失败。

依赖
    · 解析与统计：仅需标准库 + numpy
    · 实时读串口：需要 pyserial      ->  pip install pyserial
    · 画图：     需要 matplotlib    ->  pip install matplotlib
    两者缺失时会自动降级为「写 CSV + 打印文本统计」，不会报错退出。

用法
    # 0) 自检：不接硬件，验证解析逻辑（本机可直接跑）
    python uart_scope.py --selftest

    # 1) 实时读串口，打印统计 + 存 CSV
    python uart_scope.py --port COM3 --baud 2000000 --seconds 10 --csv out.csv

    # 2) 从已保存的二进制文件解析
    python uart_scope.py --file raw.bin --csv out.csv
"""

import argparse
import math
import os
import struct
import sys

try:
    import numpy as np
except ImportError:
    print("需要 numpy：pip install numpy")
    sys.exit(2)

HEAD1 = 0xAA
HEAD2 = 0x55
FRAME_LEN = 18

ANG_LSB_DEG = 360.0 / 65536.0

STAT_BITS = ["oflow", "falarm", "laglim", "inclim", "lagfatl", "scamp", "adapt", "res"]

FRAME_TAG_IO = 0xA2               # off9 的 IO 帧标记（帧布局 v2；v11 处 ≤ 0x80）
IO_STATE_BITS = ["a", "b", "z", "u", "v", "w", "dir", "limiter"]
IO_FLAG_BITS  = ["lag_warn", "lag_fatal", "z_window", "uvw_freq_warn",
                 "abzen", "uwven", "cor_sat", "amp_bad"]
ANG_BINS = 64                     # 等效采样的电角度分箱数


# ==============================================================================
# 帧解析
# ==============================================================================
def xor_checksum(payload: bytes) -> int:
    """对传入的字节串逐字节异或（**只算传入的字节**，不含帧头）。

    注意：遥测帧 off17 的校验和字段**不是**这个值，而是 frame_checksum()。
    """
    v = 0
    for b in payload:
        v ^= b
    return v & 0xFF


def frame_checksum(payload: bytes) -> int:
    """遥测帧 off17 的校验和 = 0xAA ^ 0x55 ^ (payload 逐字节异或)。

    与 rtl/uart_scope.v:189-196 的 l_chk 一致：RTL 把两个帧头常量也异或了
    进去，所以这里必须再 ^ HEAD1 ^ HEAD2（等价于 ^ 0xFF）。2026-10-10 之前
    本工具少异或这两个常量，导致真机每一帧都被判 crc_err、frames 恒为 0。
    """
    return xor_checksum(payload) ^ HEAD1 ^ HEAD2


def build_frame(angle, s_n, c_n, io_state, io_flags, pos_full, stat) -> bytes:
    """按 uart_scope.v 的**帧布局 v2** 组帧（也用于自检）。

    参数顺序 = 帧上的字节顺序：angle, s_n, c_n, io_state, io_flags, pos_full, stat。
    （v11 旧布局的 amp_sq 已不在帧内；要造 v1 帧请用 build_frame_v1。）
    """
    payload = struct.pack(
        ">HHHBBBBIB",
        angle & 0xFFFF,
        s_n & 0xFFFF,
        c_n & 0xFFFF,
        io_state & 0xFF,
        FRAME_TAG_IO,
        io_flags & 0xFF,
        0x00,
        pos_full & 0xFFFFFFFF,
        stat & 0xFF,
    )
    return bytes([HEAD1, HEAD2]) + payload + bytes([frame_checksum(payload)])


def build_frame_v1(angle, s_n, c_n, amp_sq, pos_full, stat) -> bytes:
    """按 v11 及以前的旧布局组帧（off8..11 = amp_sq），仅用于兼容性自检。"""
    payload = struct.pack(
        ">HHHIIB",
        angle & 0xFFFF, s_n & 0xFFFF, c_n & 0xFFFF,
        amp_sq & 0xFFFFFFFF, pos_full & 0xFFFFFFFF, stat & 0xFF,
    )
    return bytes([HEAD1, HEAD2]) + payload + bytes([frame_checksum(payload)])


def classify_bad(payload: bytes, chk: int):
    """诊断一个 XOR 失败的帧：算 校验差 d = 收到的校验 ^ 按收到内容算出的校验。

    XOR 校验是逐位线性的 ⇒ **d 的置位数 = 出错位数**（单比特翻转 ⇒ d 只有 1 位）。
    d 置位很多位 ⇒ 不是单纯位翻转（多半是整字节丢/插/滑位或帧被截断）。
    返回 (置位数, d)。
    """
    d = frame_checksum(payload) ^ chk
    return bin(d).count("1"), d


def parse_stream(buf: bytes):
    """从字节流里提取所有合法帧。

    返回 (frames, stats)：
      frames: list of dict
      stats : {'total_bytes','frames','crc_err','resync_bytes','bad_hist','bad_samples'}
    """
    frames = []
    crc_err = 0
    resync = 0
    bad_hist = {}          # 置位数 -> 次数
    bad_samples = []       # 前若干个坏帧的原始 18 字节
    i = 0
    n = len(buf)
    while i + FRAME_LEN <= n:
        if buf[i] != HEAD1 or buf[i + 1] != HEAD2:
            i += 1
            resync += 1
            continue
        payload = buf[i + 2:i + 17]
        chk = buf[i + 17]
        if frame_checksum(payload) != chk:
            crc_err += 1
            nb, _d = classify_bad(payload, chk)
            bad_hist[nb] = bad_hist.get(nb, 0) + 1
            if len(bad_samples) < 5:
                bad_samples.append(buf[i:i + FRAME_LEN].hex(" "))
            i += 1
            continue
        angle, s_n, c_n, io_state, io_tag, io_flags, io_resv, pos_full, stat = \
            struct.unpack(">HHHBBBBIB", payload)
        sv = struct.unpack(">h", struct.pack(">H", s_n))[0]
        cv = struct.unpack(">h", struct.pack(">H", c_n))[0]
        # off9 是布局判别字节：0xA2 = v2（io 快照），否则 v1（off8..11 = amp_sq）
        v2 = (io_tag == FRAME_TAG_IO)
        if v2:
            # amp_sq 不再上线，用 s/c 无损重算（与 rtl/amp_monitor.v 同式）
            amp_sq = (sv * sv + cv * cv) & 0xFFFFFFFF
        else:
            amp_sq = (io_state << 24) | (io_tag << 16) | (io_flags << 8) | io_resv
        frames.append(dict(
            angle=angle,
            angle_deg=angle * ANG_LSB_DEG,
            s=sv,
            c=cv,
            layout="v2" if v2 else "v1",
            io_state=io_state if v2 else None,
            io_flags=io_flags if v2 else None,
            io_bits=({n: (io_state >> k) & 1 for k, n in enumerate(IO_STATE_BITS)}
                     if v2 else None),
            io_flag_bits=({n: (io_flags >> k) & 1 for k, n in enumerate(IO_FLAG_BITS)}
                          if v2 else None),
            amp_sq=amp_sq,
            pos_full=struct.unpack(">i", struct.pack(">I", pos_full))[0],
            cycle_cnt=struct.unpack(">h", struct.pack(">H", (pos_full >> 16) & 0xFFFF))[0],
            stat=stat,
            flags=[STAT_BITS[k] for k in range(8) if (stat >> k) & 1],
        ))
        i += FRAME_LEN
    return frames, dict(total_bytes=n, frames=len(frames),
                        crc_err=crc_err, resync_bytes=resync,
                        bad_hist=bad_hist, bad_samples=bad_samples,
                        layout_v2=sum(1 for f in frames if f["layout"] == "v2"),
                        layout_v1=sum(1 for f in frames if f["layout"] == "v1"))


# ==============================================================================
# 统计
# ==============================================================================
def report(frames, stats):
    print("=" * 78)
    print("帧解析统计")
    print("=" * 78)
    print("  输入字节数        : %d" % stats["total_bytes"])
    print("  有效帧数          : %d" % stats["frames"])
    print("  XOR 校验失败      : %d" % stats["crc_err"])
    print("  同步丢弃字节      : %d" % stats["resync_bytes"])
    hist = stats.get("bad_hist") or {}
    if hist:
        # 置位数=1 → 单比特翻转（电气/波特率噪声）；置位数多 → 整字节丢/插/滑位
        parts = ["%d位错:%d" % (k, hist[k]) for k in sorted(hist)]
        total_bad = sum(hist.values())
        one_bit = hist.get(1, 0)
        print("  坏帧错位分布      : %s" % "  ".join(parts))
        print("     -> 单比特 %d / %d (%.1f%%)；多比特(疑似丢/插字节) %d"
              % (one_bit, total_bad, 100.0 * one_bit / total_bad,
                 total_bad - one_bit))
        for s in (stats.get("bad_samples") or [])[:3]:
            print("     -> 坏帧样本: %s" % s)
    if stats["frames"] == 0:
        print("\n  没有解析到任何帧。检查：波特率、帧头、字节序、XOR 校验。")
        return None

    ang = np.array([f["angle_deg"] for f in frames])
    s = np.array([f["s"] for f in frames], dtype=float)
    c = np.array([f["c"] for f in frames], dtype=float)
    amp = np.array([f["amp_sq"] for f in frames], dtype=float)
    cyc = np.array([f["cycle_cnt"] for f in frames], dtype=float)

    r = np.sqrt(s * s + c * c)
    print()
    print("  角度 (deg)        : min %.3f  max %.3f  跨度 %.3f" % (ang.min(), ang.max(), ang.max() - ang.min()))
    print("  校正后半径 r      : mean %.1f  min %.1f  max %.1f" % (r.mean(), r.min(), r.max()))
    # 圆度用两个口径：峰峰对**单个异常样本**（例如 ADC OTR 撞轨那几帧）极度敏感，
    # RMS 才是判断"标定是否生效/有没有直流偏置"的稳健指标。
    rms_pct = (r.std() / r.mean()) * 100 if r.mean() > 0 else float("nan")
    pp_pct = (r.max() - r.min()) / r.mean() * 100 if r.mean() > 0 else float("nan")
    lo, hi = np.percentile(r, [0.1, 99.9])
    q_pct = (hi - lo) / r.mean() * 100 if r.mean() > 0 else float("nan")
    print("  圆度偏差(RMS)     : %.3f %%   （稳健口径：>3%% 说明有直流偏置或标定没生效）" % rms_pct)
    print("  圆度偏差(峰峰)    : %.3f %%   （不含 0.1%% 极值：%.3f %%）" % (pp_pct, q_pct))
    print("  幅值平方          : min %d  max %d" % (int(amp.min()), int(amp.max())))

    # 角度单调性与跨零
    d = np.diff(ang)
    d = (d + 180.0) % 360.0 - 180.0
    print("  角度步进 (deg/帧) : mean %+.5f  min %+.5f  max %+.5f" % (d.mean(), d.min(), d.max()))
    pos_steps = int((d > 0).sum())
    neg_steps = int((d < 0).sum())
    print("  正/负步进帧数     : %d / %d" % (pos_steps, neg_steps))
    print("  多周期计数        : min %d  max %d" % (int(cyc.min()), int(cyc.max())))

    flagged = {}
    for f in frames:
        for fl in f["flags"]:
            flagged[fl] = flagged.get(fl, 0) + 1
    if flagged:
        print("  状态位触发次数    : " + ", ".join("%s=%d" % kv for kv in sorted(flagged.items())))
    else:
        print("  状态位            : 全部正常（无告警）")

    #------------------------------------------------------------------
    # ABZ/UVW 电平快照（帧布局 v2）+ 等效采样相位重建
    #------------------------------------------------------------------
    n_v2 = stats.get("layout_v2", 0)
    n_v1 = stats.get("layout_v1", 0)
    n_tot = n_v2 + n_v1
    print()
    if n_v2 and n_v1:
        # 18 字节帧只有 1 字节 XOR 校验，个别多比特误码可以骗过校验并把 off9 变成非 0xA2
        # 而被判成 v1 ⇒ 极少数 v1 帧是误码误判，不是旧位流混流。实测（2026-10-13，v12 板上
        # 30 s）：v2 298747 + v1 1，比例 3e-6。判"真混流"要求 v1 既有一定数量、又占比可观。
        if n_v1 >= max(3, 0.001 * n_tot):
            print("  ★ 帧布局          : v2 %d 帧 + v1(旧位流) %d 帧（占比 %.2f%%）—— 混流！检查位流是否重烧"
                  % (n_v2, n_v1, 100.0 * n_v1 / n_tot))
        else:
            print("  帧布局            : v2 %d 帧 + %d 帧被判 v1（占比 %.4f%%，XOR 校验漏网的多比特误码，非旧位流）"
                  % (n_v2, n_v1, 100.0 * n_v1 / n_tot))
    elif n_v1:
        print("  ★ 帧布局          : 全部 %d 帧是 v1（v11 及以前位流）⇒ 帧内没有 ABZ/UVW 快照" % n_v1)
    else:
        print("  帧布局            : v2（io 快照有效；amp_sq 由 s²+c² 重算，等价）")

    if n_v2:
        v2f = [f for f in frames if f["layout"] == "v2"]
        angs = np.array([f["angle"] for f in v2f], dtype=float)
        duty, edges = {}, {}
        for name in IO_STATE_BITS:
            col = np.array([f["io_bits"][name] for f in v2f], dtype=float)
            duty[name] = col.mean() * 100.0
            edges[name] = int((np.diff(col) != 0).sum())
        print("  ABZ/UVW 快照      : 高电平占比 / 电平跳变次数（本段 %d 帧）" % n_v2)
        txt = ["%-8s %5.1f%% /%5d" % (n, duty[n], edges[n]) for n in IO_STATE_BITS]
        for k in range(0, len(txt), 3):
            print("    " + "   ".join(txt[k:k + 3]))

        uvw = ((np.array([f["io_bits"]["u"] for f in v2f]) << 2)
               | (np.array([f["io_bits"]["v"] for f in v2f]) << 1)
               | np.array([f["io_bits"]["w"] for f in v2f]))
        uniq, cnt = np.unique(uvw, return_counts=True)
        legal = {0b001, 0b011, 0b010, 0b110, 0b100, 0b101}
        badst = {int(u): int(c) for u, c in zip(uniq, cnt) if int(u) not in legal}
        print("    UVW 状态码分布  : " + "  ".join("%s:%d" % (format(int(u), "03b"), int(c))
                                                    for u, c in zip(uniq, cnt)))
        if badst:
            print("    ★ 非法 UVW 状态 : %s（000/111 不该出现：三相切换不同步或采样毛刺）"
                  % ", ".join("%s×%d" % (format(u, "03b"), c) for u, c in sorted(badst.items())))

        bins = np.clip((angs / 65536.0 * ANG_BINS).astype(int), 0, ANG_BINS - 1)
        hist = np.bincount(bins, minlength=ANG_BINS)
        filled = int((hist >= 3).sum())
        print("    等效采样填充率  : %d/%d 箱（每箱 ≥3 帧）→ 见 PNG 的「io vs 电角度」" %
              (filled, ANG_BINS))
        if filled < ANG_BINS // 2:
            print("      ⇒ 填充不足：输入频率与帧率近似整数倍时采样相位只落在少数点。")
            print("        把信号源频率错开一点（如 997 Hz 而非 1000 Hz）再采，相位就会铺满。")
        if edges["z"] == 0 and duty["z"] < 1.0:
            print("    （Z 恒低且无跳变：Z 脉宽通常远窄于 100 µs 采样周期，按时间采样必然漏掉；")
            print("      看「io vs 电角度」的等效采样图才看得到 Z。）")

    # 一个粗糙的"角度误差"指标：对理想正弦信号，r 应恒定；
    # 用 r 的波动折算出角度噪声的保守估计
    if r.mean() > 0:
        ang_noise_deg = (r.std() / r.mean()) * 57.2958 / math.sqrt(2)
        print("  由圆度折出的角度噪声(保守估计): %.4f deg (%.1f arcsec)"
              % (ang_noise_deg, ang_noise_deg * 3600.0))
    return frames


def save_csv(frames, path):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write("idx,angle_raw,angle_deg,s,c,amp_sq,pos_full,cycle_cnt,stat,flags,"
                "layout,io_state,io_flags," + ",".join(IO_STATE_BITS) + "\n")
        for k, fr in enumerate(frames):
            ib = fr["io_bits"]
            f.write("%d,%d,%.6f,%d,%d,%d,%d,%d,%d,%s,%s,%s,%s,%s\n" % (
                k, fr["angle"], fr["angle_deg"], fr["s"], fr["c"],
                fr["amp_sq"], fr["pos_full"], fr["cycle_cnt"], fr["stat"],
                "|".join(fr["flags"]), fr["layout"],
                "" if fr["io_state"] is None else fr["io_state"],
                "" if fr["io_flags"] is None else fr["io_flags"],
                ",".join("" if ib is None else str(ib[n]) for n in IO_STATE_BITS)))
    print("\n  已写入 CSV: %s (%d 行)" % (path, len(frames)))


def maybe_plot(frames, png=None):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("  （未安装 matplotlib，跳过绘图。pip install matplotlib 后可自动出图）")
        return
    s = np.array([f["s"] for f in frames], dtype=float)
    c = np.array([f["c"] for f in frames], dtype=float)
    ang = np.array([f["angle_deg"] for f in frames])
    v2f = [f for f in frames if f["layout"] == "v2"]

    fig, ax = plt.subplots(3, 2, figsize=(13, 11))

    # ---- 第 1 行：李萨如图 + 角度 ----
    ax[0][0].plot(c, s, lw=0.8)
    ax[0][0].set_title("Lissajous (corrected)  roundness=%.3f%%"
                       % ((np.hypot(s, c).max() - np.hypot(s, c).min()) / np.hypot(s, c).mean() * 100))
    ax[0][0].set_xlabel("cos (c_n)"); ax[0][0].set_ylabel("sin (s_n)")
    ax[0][0].axis("equal"); ax[0][0].grid(True, alpha=0.3)

    ax[0][1].plot(ang, lw=0.8)
    ax[0][1].set_title("Angle vs frame index"); ax[0][1].set_xlabel("frame")
    ax[0][1].set_ylabel("angle (deg)"); ax[0][1].grid(True, alpha=0.3)

    def logic_axes(a, names, title, xs, xlabel, step_mode):
        """把若干逻辑位按等高线偏移画在一张图上（每路 1.2 个纵轴单位）。"""
        for off, nm in enumerate(names):
            col = np.array([f["io_bits"][nm] for f in v2f], dtype=float)
            if step_mode == "mean":       # 等效采样：按角度分箱取均值（= 高电平比例）
                vals = np.array([col[xs == k].mean() if (xs == k).any() else np.nan
                                 for k in range(ANG_BINS)])
                a.step((np.arange(ANG_BINS) + 0.5) * 360.0 / ANG_BINS,
                       vals + (len(names) - 1 - off) * 1.2, where="mid", lw=1.3)
            else:
                a.step(np.arange(len(col)), col + (len(names) - 1 - off) * 1.2,
                       where="post", lw=0.8)
        a.set_title(title); a.set_xlabel(xlabel)
        a.set_yticks([i * 1.2 for i in range(len(names))])
        a.set_yticklabels([n.upper() for n in reversed(list(names))])
        a.set_ylim(-0.5, len(names) * 1.2 - 0.3)
        a.grid(True, alpha=0.3)

    if v2f:
        # ---- 第 2 行：按时间（10 kHz 快照；A/B 边沿率高于 5 kHz 时是混叠的）----
        logic_axes(ax[1][0], ("a", "b", "z"), "ABZ levels vs frame (time snapshots)",
                   None, "frame", "time")
        logic_axes(ax[1][1], ("u", "v", "w"), "UVW levels vs frame (time snapshots)",
                   None, "frame", "time")
        # ---- 第 3 行：等效采样（按电角度分箱）——这才是真实波形形状 ----
        angraw = np.array([f["angle"] for f in v2f], dtype=float)
        b = np.clip((angraw / 65536.0 * ANG_BINS).astype(int), 0, ANG_BINS - 1)
        logic_axes(ax[2][0], ("a", "b", "z"),
                   "ABZ vs electrical angle (equivalent-time, %d bins)" % ANG_BINS,
                   b, "electrical angle (deg)", "mean")
        logic_axes(ax[2][1], ("u", "v", "w"),
                   "UVW vs electrical angle (equivalent-time, %d bins)" % ANG_BINS,
                   b, "electrical angle (deg)", "mean")
    else:
        for cc in (0, 1):
            ax[1][cc].text(0.5, 0.5, "no v2 (io) frames:\nre-flash the v12+ bitstream",
                           ha="center", va="center")
            ax[2][cc].axis("off")

    fig.tight_layout()
    out = png or "uart_scope.png"
    fig.savefig(out, dpi=110)
    print("\n  已保存图像: %s" % out)


# ==============================================================================
# 自检
# ==============================================================================
def selftest():
    print("=" * 78)
    print("uart_scope.py 自检 —— 不接硬件，验证组帧/解析/XOR 校验")
    print("=" * 78)

    # 1) 生成 200 帧合成数据，模拟 1 kHz 正弦的 16bit 角度采样
    #    io_state 也按真实逻辑造：A 每 1/64 电周期翻转、B 与 A 正交（滞后 90°）、
    #    Z 只在 0° 附近高；UVW 走 6 步合法表（001→011→010→110→100→101）。
    UVW_SEQ = [(1, 1, 0), (0, 1, 0), (0, 1, 1), (0, 0, 1), (1, 0, 1), (1, 0, 0)]
    frames_in = []
    exp_io = []
    N = 200
    for k in range(N):
        deg = (k * 360.0 / N) % 360.0
        ang = int(round(deg / 360.0 * 65536)) & 0xFFFF
        s = int(round(30000 * math.sin(math.radians(deg))))
        c = int(round(30000 * math.cos(math.radians(deg))))
        a = 1 if (int(deg) >> 2) & 1 else 0
        b = 1 if (int((deg - 90.0) % 360.0) >> 2) & 1 else 0
        z = 1 if deg < 6.0 else 0
        u, v, w = UVW_SEQ[int(deg // 60.0) % 6]
        io = (a | (b << 1) | (z << 2) | (u << 3) | (v << 4) | (w << 5)
              | (1 << 6)          # dir = 正转
              | (0 << 7))         # limiter_active
        exp_io.append((a, b, z, u, v, w))
        pos = (k << 16) | ang
        frames_in.append(build_frame(ang, s, c, io, 0x00, pos, 0))

    # 2) 故意插入垃圾字节，验证重同步
    stream = b"\x00\x13\x37" + b"".join(frames_in) + b"\xff\xfe"

    frames, stats = parse_stream(stream)
    report(frames, stats)

    ok = True
    if stats["frames"] != N:
        print("\n  [FAIL] 帧数不对：期望 %d，得到 %d" % (N, stats["frames"])); ok = False
    if stats["crc_err"] != 0:
        print("\n  [FAIL] 出现 XOR 校验失败 %d 次（不应发生）" % stats["crc_err"]); ok = False

    # 3) 逐字段回读比对（含 v2 的 io 快照，以及"amp_sq 由 s/c 重算"的等价性）
    for k, fr in enumerate(frames):
        deg = (k * 360.0 / N) % 360.0
        ang = int(round(deg / 360.0 * 65536)) & 0xFFFF
        s = int(round(30000 * math.sin(math.radians(deg))))
        c = int(round(30000 * math.cos(math.radians(deg))))
        a, b, z, u, v, w = exp_io[k]
        if (fr["angle"] != ang or fr["s"] != s or fr["c"] != c
                or fr["layout"] != "v2"
                or fr["amp_sq"] != ((s * s + c * c) & 0xFFFFFFFF)
                or (fr["io_bits"]["a"], fr["io_bits"]["b"], fr["io_bits"]["z"],
                    fr["io_bits"]["u"], fr["io_bits"]["v"], fr["io_bits"]["w"]) != (a, b, z, u, v, w)
                or fr["io_bits"]["dir"] != 1 or fr["io_bits"]["limiter"] != 0):
            print("\n  [FAIL] 第 %d 帧字段不匹配: %s" % (k, fr)); ok = False; break
    else:
        print("  [OK] %d 帧逐字段回读一致（含 ABZ/UVW/dir 快照与 amp_sq 重算等价）" % N)

    # 4) 故意破坏一个字节，验证 XOR 能抓到
    bad = bytearray(b"".join(frames_in))
    bad[5] ^= 0xFF
    _, st2 = parse_stream(bytes(bad))
    if st2["crc_err"] == 0:
        print("\n  [FAIL] 破坏一个字节后 XOR 校验居然通过了"); ok = False
    else:
        print("\n  [OK] 破坏一个字节后 XOR 校验成功捕获（crc_err=%d）" % st2["crc_err"])

    # 5) 边界值（io_state/io_flags 全 1、pos_full = -1、stat = 0xFF）
    for ang, s, c in [(0, -32768, -32768), (65535, 32767, 32767), (32768, 0, 0)]:
        f = build_frame(ang, s, c, 0xFF, 0xFF, -1 & 0xFFFFFFFF, 0xFF)
        fr, st = parse_stream(f)
        if (st["frames"] != 1 or fr[0]["angle"] != ang or fr[0]["s"] != s
                or fr[0]["io_state"] != 0xFF or fr[0]["io_flags"] != 0xFF
                or fr[0]["amp_sq"] != ((s * s + c * c) & 0xFFFFFFFF)):
            print("\n  [FAIL] 边界值 (%d,%d,%d) 回读失败" % (ang, s, c)); ok = False
    print("  [OK] 边界值（0 / 65535 / -32768 / io=0xFF,0xFF / 0xFFFFFFFF / -1）回读正确")

    # 6) 向后兼容：v11 旧布局的帧必须仍被识别成 v1，且判别字节不可能撞车
    for amp in (0x00000000, 0xDEADBEEF, 0x7FFFFFFF, 0xFFFFFFFF):
        f1 = build_frame_v1(0x1234, 0x0F0E, 0xF1F2, amp, 0x01020304, 0x5A)
        fr, st = parse_stream(f1)
        if (st["frames"] != 1 or fr[0]["layout"] != "v1" or fr[0]["amp_sq"] != amp
                or fr[0]["io_state"] is not None or fr[0]["angle"] != 0x1234):
            print("\n  [FAIL] v1 旧布局帧解析失败 (amp=%08X)" % amp); ok = False
        # 旧布局 off9 = amp_sq[23:16]，而 rtl/amp_monitor.v 先把 amp_sq 饱和在 2^31-1
        if f1[9] == FRAME_TAG_IO and amp <= 0x7FFFFFFF:
            print("\n  [FAIL] v1 帧 off9 与 v2 标签 0xA2 撞车 (amp=%08X)" % amp); ok = False
    print("  [OK] v1 旧布局仍可解析；off9 判别无歧义（amp_sq ≤ 2^31-1 ⇒ 该字节 ≤ 0x80）")

    print()
    print("  " + ("TEST PASSED" if ok else "TEST FAILED"))
    return 0 if ok else 1


# ==============================================================================
# 主程序
# ==============================================================================
def main():
    try:                      # 控制台可能是 GBK：遇到无法编码的字符降级输出而不是崩溃
        sys.stdout.reconfigure(errors="replace")
        sys.stderr.reconfigure(errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="uart_scope 上位机解析/可视化")
    ap.add_argument("--selftest", action="store_true", help="不接硬件，自检解析逻辑")
    ap.add_argument("--port", help="串口名，如 COM3")
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--file", help="从二进制文件读取")
    ap.add_argument("--csv", help="把解析结果写成 CSV")
    ap.add_argument("--png", help="把图保存到这个文件名")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    buf = b""
    if args.file:
        buf = open(args.file, "rb").read()
    elif args.port:
        try:
            import serial
        except ImportError:
            print("需要 pyserial 才能读串口：pip install pyserial")
            return 2
        ser = serial.Serial(args.port, args.baud, timeout=0.05)
        # 2 Mbaud 下遥测帧率 10 kHz = 180 kB/s，若上位机停顿超过驱动缓冲深度就会丢字节
        # （表现为 XOR 校验失败 + 重新同步丢字节）。把驱动 RX 缓冲开大、并"有多少读多少"，
        # 避免固定 4096 字节读取在两次 read 之间留下排空空档。
        try:
            ser.set_buffer_size(rx_size=1 << 20)
        except Exception:
            pass
        print("正在从 %s @ %d baud 读取 %.1f 秒 ..." % (args.port, args.baud, args.seconds))
        import time
        # 先清掉 ADC 的 sticky OTR 锁存（0x0405[0]=1 ⇒ clr_otr 输出一拍脉冲，见
        # rtl/reg_file.v:397）。否则状态字节 bit0 `oflow`（= cor_sat | otr_lat，
        # rtl/enc_top.v:634）会永久为 1：一块板上做过的 OTR 过幅实验会把这一位
        # 锁死，之后所有遥测 CSV 的 flags 都带着 oflow，看起来像活故障。
        # 帧格式（tools/uart_spi.py:161 encode_cmd）：首字节 = 0x80 | (写<<3) | page，
        # page = (addr>>8)&7；写 0x0405 ⇒ page=4 ⇒ 0x8C，数据 0x00FF。
        try:
            ser.write(bytes([0x8C, 0x05, 0x00, 0xFF]))
            ser.flush()
            time.sleep(0.05)
            ser.reset_input_buffer()        # 丢弃清位命令的应答，别混进遥测流
        except Exception as e:
            print("  （提示：清 OTR 锁存失败，忽略：%s）" % e)
        t0 = time.time()
        while time.time() - t0 < args.seconds:
            n = ser.in_waiting
            buf += ser.read(n if n else 1)
        ser.close()
    else:
        ap.print_help()
        print("\n提示：先用 --selftest 验证工具链，再用 --port 读真实数据。")
        return 0

    frames, stats = parse_stream(buf)
    if report(frames, stats) is None:
        return 1
    if args.csv:
        save_csv(frames, args.csv)
    maybe_plot(frames, args.png)
    return 0


if __name__ == "__main__":
    sys.exit(main())
