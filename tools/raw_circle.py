#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""从遥测流反解「原始码圆」：不需要 ILA，也不需要 JTAG。

为什么需要它：
  · 遥测帧里的 s/c 是**校正后**（`rtl/enc_top.v:1135-1136` 接 `s_cor/c_cor`），
    而自动标定把校正后幅度归一化到 REF_Q15=26214（`rtl/calib_ctrl.v:67`）
    ⇒ 遥测半径**不能**当原始码幅度用。
  · ILA 的 `dbg_s_raw/dbg_c_raw` 能测原始码，但 1024 拍只有 20.48us ≈ 0.41 个电周期，
    **弧段太短**，圆心与半径在拟合里强相关（实测 O_c 在 ±15 LSB 内乱跳）。
  · 本工具用标定寄存器（0x0510..0x051A）把遥测的校正值**反算回原始码**：
        s1 = s_cor * 2^(15-shift_s) / gain_s          （得到 sc_correct 输入域 = 原始码×16）
        c2 = c_cor * 2^(15-shift_c) / gain_c
        c1 = c2 + s1 * phase_k / 2^15                 （反解正交校正）
        s_raw = (s1 + ofs_s) / 16 ;  c_raw = (c1 + ofs_c) / 16
    一秒钟的遥测就有约 1 万帧，而 20 kHz 输入对 ~9.95 kHz 帧率是 ~2:1 混叠
    ⇒ 混叠后的相位每帧只走 −3 度左右，1 秒就绕满约 87 圈 ⇒ **覆盖完整圆周**，
    圆心精度远好于 ILA 短窗。
  · 自检：反算出的 s_raw/c_raw 应当**接近整数**（原始码是 12 位整数 ADC 输出），
    小数残差大就说明标定寄存器读错或反解公式不对。⚠ 当标定系数是中性值
    （ofs=0/gain=0x8000/shift=0，见 0x0510..0x051A）时，这一步是恒等的，
    不能用来验证反解；此时应改用「已知原始码窗口」（ILA 抓的 dbg_s_raw）交叉核对。

用法：
    E:\\Anaconda\\python.exe tools\\raw_circle.py --seconds 2
    E:\\Anaconda\\python.exe tools\\raw_circle.py --repeat 30 --interval 5 --csv _synth_work\\raw_circle.csv
"""

import argparse
import io
import math
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import uart_scope as us        # noqa: E402
import uart_spi                # noqa: E402
import lattice_scan as ls      # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 标定系数寄存器（`rtl/sc_correct.v:27-29`）
REG_OFS_S, REG_OFS_C = 0x0510, 0x0512
REG_GAIN_S, REG_GAIN_C = 0x0514, 0x0516
REG_PHASE_K, REG_SHIFT = 0x0518, 0x051A

COLUMNS = ["ts", "seconds", "n_frames", "n_used",
           "ofs_s", "ofs_c", "gain_s", "gain_c", "phase_k", "shift_s", "shift_c",
           "A_raw", "Os_raw", "Oc_raw", "A_q15", "Os_q15", "Oc_q15",
           "dist", "lat_s", "lat_c", "lat_deg",
           "r_mean_raw", "r_std_raw", "raw_int_rms", "res_kasa_rms",
           "cov_min", "cov_empty", "f_ratio", "stat"]

# `rtl/enc_top.v:271-274`：s_q15 = {{4{s_raw[11]}}, s_raw} <<< 4 ⇒ sc_correct 的
# 输入/输出域是「原始 12 位码 × 16」，所以反解结果要 ÷16 才回到原始码域。
SCALE = 16.0


def s16(v):
    return v - 65536 if v >= 32768 else v


def read_calib(link, timeout=0.4):
    """读标定系数；返回 dict（任何一项读不到就报错退出）。"""
    got = {}
    for name, addr in (("ofs_s", REG_OFS_S), ("ofs_c", REG_OFS_C),
                       ("gain_s", REG_GAIN_S), ("gain_c", REG_GAIN_C),
                       ("phase_k", REG_PHASE_K), ("shift", REG_SHIFT)):
        v = None
        for _ in range(3):
            v, _raw = uart_spi._readback(link, addr, timeout)
            if v is not None:
                break
        if v is None:
            raise SystemExit("读 0x%04X (%s) 超时" % (addr, name))
        got[name] = v
    out = dict(ofs_s=s16(got["ofs_s"]), ofs_c=s16(got["ofs_c"]),
               gain_s=got["gain_s"], gain_c=got["gain_c"],
               phase_k=s16(got["phase_k"]),
               shift_s=got["shift"] & 0x3, shift_c=(got["shift"] >> 2) & 0x3)
    return out


def read_stream(ser, seconds):
    buf = bytearray()
    try:
        ser.reset_input_buffer()
    except Exception:  # noqa: BLE001
        pass
    t0 = time.time()
    while time.time() - t0 < seconds:
        n = ser.in_waiting
        buf += ser.read(n if n else 1)
    return bytes(buf)


def invert(s_cor, c_cor, cal):
    """把校正后的 s/c 反算回 sc_correct 的输入域（= 原始 12 位码 × 16，浮点）。"""
    s1 = s_cor * (1 << (15 - cal["shift_s"])) / float(cal["gain_s"])
    c2 = c_cor * (1 << (15 - cal["shift_c"])) / float(cal["gain_c"])
    c1 = c2 + s1 * cal["phase_k"] / 32768.0
    return s1 + cal["ofs_s"], c1 + cal["ofs_c"]


def kasa(s, c):
    X, Y = np.asarray(s, float), np.asarray(c, float)
    A1 = np.column_stack([2 * X, 2 * Y, np.ones_like(X)])
    b1 = X ** 2 + Y ** 2
    sol, *_ = np.linalg.lstsq(A1, b1, rcond=None)
    Os, Oc = sol[0], sol[1]
    A = math.sqrt(max(sol[2] + Os * Os + Oc * Oc, 0.0))
    res = np.abs(np.hypot(X - Os, Y - Oc) - A)
    return A, Os, Oc, float(np.sqrt(np.mean(res ** 2)))


def phases(s, c, Os, Oc):
    return np.degrees(np.arctan2(c - Oc, s - Os))


def coverage(s, c, Os, Oc, bins=36):
    """相角覆盖均匀度：返回 (最少格子的占比, 空格子数)。覆盖差 ⇒ 圆心不可信。"""
    ph = phases(s, c, Os, Oc)
    idx = np.floor((ph + 180.0) / (360.0 / bins)).astype(int) % bins
    cnt = np.bincount(idx, minlength=bins).astype(float)
    return float(cnt.min() / max(cnt.mean(), 1e-9)), int((cnt == 0).sum())


def split_fit(s, c, k):
    """把窗口切成 k 段分别拟合，用来分辨「段内平滑漂移」与「段间跳变」。"""
    n = len(s) // k
    out = []
    for i in range(k):
        sl = slice(i * n, (i + 1) * n)
        A, Os, Oc, rms = kasa(s[sl], c[sl])
        out.append((A, Os, Oc, rms, n))
    return out


def one_pass(ser, link, seconds, timeout=0.4, keep=3.0, split=0):
    cal = read_calib(link, timeout)
    buf = read_stream(ser, seconds)
    frames, stats = us.parse_stream(buf)
    if not frames:
        raise SystemExit("这一窗没解析到遥测帧（串口占着？波特率不对？）")
    sc = np.array([f["s"] for f in frames], float)
    cc = np.array([f["c"] for f in frames], float)
    s_q15, c_q15 = invert(sc, cc, cal)          # sc_correct 输出域 = 原始码 << 4
    s_raw, c_raw = s_q15 / SCALE, c_q15 / SCALE  # 回到 12 位原始码域
    # 自检：原始码应当是整数（标定走过之后，这一步同时验证反解公式）
    int_rms = float(np.sqrt(np.mean(((s_raw - np.round(s_raw)) ** 2 +
                                     (c_raw - np.round(c_raw)) ** 2) / 2.0)))
    # 两遍拟合：先粗拟合，剔掉残差大的点（OTR / 混叠边界样本）再拟合
    A, Os, Oc, rms = kasa(s_raw, c_raw)
    keep_mask = np.abs(np.hypot(s_raw - Os, c_raw - Oc) - A) < keep * max(rms, 0.5)
    if keep_mask.sum() >= 16 and keep_mask.sum() < len(s_raw):
        A, Os, Oc, rms = kasa(s_raw[keep_mask], c_raw[keep_mask])
    err, Ls, Lc, ph, d = ls.nearest_lattice(Os, Oc, A)
    cov_min, cov_empty = coverage(s_raw, c_raw, Os, Oc)
    splits = split_fit(s_raw, c_raw, split) if split > 1 else []
    r_inst = np.hypot(s_raw, c_raw)
    row = dict(ts=time.strftime("%H:%M:%S"), seconds="%.1f" % seconds,
               n_frames=len(frames), n_used=int(keep_mask.sum()),
               ofs_s=cal["ofs_s"], ofs_c=cal["ofs_c"],
               gain_s=cal["gain_s"], gain_c=cal["gain_c"],
               phase_k=cal["phase_k"], shift_s=cal["shift_s"],
               shift_c=cal["shift_c"],
               A_raw="%.2f" % A, Os_raw="%.2f" % Os, Oc_raw="%.2f" % Oc,
               A_q15="%.1f" % (A * SCALE), Os_q15="%.1f" % (Os * SCALE),
               Oc_q15="%.1f" % (Oc * SCALE),
               dist="%.2f" % err, lat_s=Ls, lat_c=Lc, lat_deg="%.1f" % ph,
               r_mean_raw="%.1f" % r_inst.mean(), r_std_raw="%.1f" % r_inst.std(),
               raw_int_rms="%.4f" % int_rms, res_kasa_rms="%.2f" % rms,
               cov_min="%.2f" % cov_min, cov_empty=cov_empty,
               f_ratio="%.3f" % (len(frames) / seconds / 20250.0),
               stat=int(frames[-1]["stat"]))
    return row, (A, Os, Oc, err, Ls, Lc, rms, int_rms, len(frames), splits)


def write_row(path, row):
    new = not os.path.exists(path)
    with io.open(path, "a", encoding="utf-8", newline="\n") as f:
        if new:
            f.write(",".join(COLUMNS) + "\n")
        f.write(",".join(str(row.get(k, "")) for k in COLUMNS) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description="遥测反解原始码圆 (A,O) 与 256 格点距离")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=uart_spi.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--timeout", type=float, default=0.4)
    ap.add_argument("--csv", default=None)
    ap.add_argument("--split", type=int, default=0,
                    help="把每个窗口切成 N 段分别拟合（分辨段内漂移 vs 段间跳变）")
    args = ap.parse_args(argv)

    ser = uart_spi.open_port(args.port, args.baud, timeout=0.2)
    link = uart_spi.Link(ser, args.baud)
    print("=" * 96)
    print(" 遥测反解原始码圆：%d 次 × %.1f s（端口 %s @ %d）"
          % (args.repeat, args.seconds, args.port, args.baud))
    print("=" * 96)
    print("%-8s %7s %7s %8s | %8s %14s %7s | %6s %6s %7s"
          % ("时刻", "帧数", "用点", "整数残差", "A_raw", "O_raw", "距离",
             "格点s", "格点c", "RMS"))
    print("-" * 96)
    try:
        for i in range(args.repeat):
            row, info = one_pass(ser, link, args.seconds, args.timeout, split=args.split)
            A, Os, Oc, err, Ls, Lc, rms, int_rms, nf, splits = info
            print("%-8s %7d %7s %8.4f | %8.2f (%+7.2f,%+7.2f) %7.2f | %6d %6d %7.2f"
                  "  cov=%.2f/空%d"
                  % (row["ts"], nf, row["n_used"], int_rms, A, Os, Oc, err, Ls, Lc, rms,
                     float(row["cov_min"]), int(row["cov_empty"])),
                  flush=True)
            if splits:
                for j, (a2, os2, oc2, rms2, n2) in enumerate(splits):
                    print("          段%d/%d n=%-5d A=%8.2f O=(%+7.2f,%+7.2f) RMS=%.2f"
                          % (j + 1, len(splits), n2, a2, os2, oc2, rms2), flush=True)
            if args.csv:
                write_row(args.csv, row)
            if i + 1 < args.repeat:
                time.sleep(args.interval)
    finally:
        try:
            ser.close()
        except Exception:  # noqa: BLE001
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
