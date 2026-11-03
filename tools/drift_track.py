#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""漂移跟踪扫描：同一场里反复测「原始码圆心/半径」与「毛刺率」，检验 256 格点共振假设。

背景（为什么需要它）：
  遥测帧里的 s/c 是 **校正后**（`rtl/enc_top.v:1135-1136` 把 `s_cor/c_cor` 接进
  `u_art_scope`），而自动标定把校正后幅度**归一化到 REF_Q15 = 26214**
  （`rtl/calib_ctrl.v:67,119-123`）⇒ 遥测半径只能反映"相对标定时刻的变化"，
  不能当**原始码幅度**用（÷16 只是 26214/16=1638.4 这个归一化目标带来的巧合）。
  真正能测原始码 (A, O) 的路径只有 ILA 的 `dbg_s_raw/dbg_c_raw` 探针。

每轮做三件事：
  1) ILA 抓一窗（`ILA_TRIG=dec_valid` ⇒ 立即可得，不需要毛刺在场）
  2) `tools/arc_fit.py` 的 Kasa/正弦拟合 ⇒ 圆心 O、半径 A，并算「圆心圆到最近 256 格点的距离」
  3) 读诊断计数器 → `gl_1024/2048` 的次/秒（与实测 d_cyc 一起换算成次/输入周期）
最后把每轮一行追加进 CSV，供后续做「率 vs 格点距离」散点。

用法（需一次提权，因为要起 hw_server/cs_server）：
    E:\\Anaconda\\python.exe tools\\drift_track.py --iters 20 --secs 60
    E:\\Anaconda\\python.exe tools\\drift_track.py --report        # 只重算 CSV

前置条件：板上必须是**带 ILA 的位流**（`_synth_work/enc_top_ila.bit` 已烧回）。
本工具**不**改位流（`ILA_MODE=capture`），所以不会打断标定状态。
"""

import argparse
import io
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import arc_fit as af            # noqa: E402
import diag_counters as dc      # noqa: E402
import lattice_scan as ls       # noqa: E402
import uart_spi                 # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_CSV = os.path.join(ROOT, "_synth_work", "drift_track.csv")
CAP_LOG = os.path.join(ROOT, "_synth_work", "ila_drift.log")

# 遥测/拟合默认用 20 kHz：窗口只有 1024 拍(20.48us)、弧长约 147 度，
# 拟合对 f 的 1% 误差不敏感（b9 的四个历史窗口用了 19.877~20.266 kHz，A/O 一致）。
F_IN_DEFAULT = 20000.0

COLUMNS = [
    "ts", "iter", "secs",
    "A_kasa", "Os_kasa", "Oc_kasa", "dist_kasa", "lat_kasa",
    "A_sine", "Os_sine", "Oc_sine", "dist_sine", "lat_sine",
    "res_kasa", "r_mean", "f_in",
    "d_gl1024", "d_gl2048", "d_gl4096", "d_cyc", "rate1024", "rate2048",
    "stat", "csv",
]


def capture(idx, wait_ms=20000, timeout_s=240, depth=1024):
    """抓一窗原始码；返回 CSV 路径（失败返回 None）。

    depth 很关键：窗口越短（1024 拍 = 20.48us ≈ 0.41 个电周期），圆心 O 与半径 A
    在拟合里强相关（弧段太短），实测 O_c 会在 ±15 LSB 内乱跳；要用 O 算
    "圆到 256 格点的距离"就必须抓深一点（8192 拍 ≈ 3.3 个电周期，接近整圆）。
    """
    env = dict(os.environ)
    env["ILA_MODE"] = "capture"
    env["ILA_TRIG"] = "dec_valid"       # 每 4 拍 1 个 ⇒ 立即触发
    env["ILA_WAIT"] = str(wait_ms)
    env["ILA_DEPTH"] = str(depth)
    # ILA_CSV 用**相对 + 正斜杠**：Tcl 里反斜杠会被当转义，绝对路径不要去凑热闹。
    csvbase_rel = "_synth_work/ila_drift_%d" % idx
    env["ILA_CSV"] = csvbase_rel
    csvfile = os.path.join(ROOT, "_synth_work", "ila_drift_%d.csv" % idx)
    if os.path.exists(csvfile):
        os.remove(csvfile)
    # 注意：run_vivado.ps1 自己把相对路径拼到工程根上，传绝对路径会被拼两次。
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-File", os.path.join(HERE, "run_vivado.ps1"),
           "-Tcl", "tools/ila_capture.tcl",
           "-LogFile", "_synth_work/ila_drift.log", "-Tail", "4"]
    with io.open(os.path.join(ROOT, "_synth_work", "_drift_ps.log"), "w",
                 encoding="utf-8", errors="replace") as pslog:
        try:
            subprocess.run(cmd, stdout=pslog, stderr=subprocess.STDOUT,
                           timeout=timeout_s, cwd=ROOT, env=env)
        except subprocess.TimeoutExpired:
            return None
    return csvfile if os.path.exists(csvfile) else None


def fit_one(csvfile, f_in=F_IN_DEFAULT):
    """拟合一个 ILA 窗口；返回 dict（含两个拟合口径的格点距离）。"""
    r = af.fit(csvfile, f_in)
    out = {}
    for tag, A, O in (("kasa", r["A_kasa"], r["O_kasa"]),
                      ("sine", r["A"], r["O"])):
        err, Ls, Lc, ph, d = ls.nearest_lattice(O.real, O.imag, A)
        out["A_" + tag] = A
        out["Os_" + tag] = O.real
        out["Oc_" + tag] = O.imag
        out["dist_" + tag] = err
        # 用 "/" 而不是 ","：这一列要是带逗号，整张 CSV 的列都会错位（踩过）
        out["lat_" + tag] = "%d/%d" % (Ls, Lc)
    out["res_kasa"] = r["res_kasa_rms"]
    out["r_mean"] = r["r_mean"]
    return out


def read_pair(link, secs, timeout=0.4, tries=1):
    """读两次计数器并求差值。返回 (t0, t1, secs_measured, d)。

    两个坑（都是实测踩出来的）：
      1) 板子一直在推遥测（~9950 帧/s），**串口接收缓冲会满**。ILA 抓包要等十几秒，
         期间缓冲里堆积的字节会让后续读寄存器错位（实测读到过 gl2048 > gl1024 的
         不可能值）⇒ 每次读之前先 reset_input_buffer。
      2) `cyc_pulse_cnt` 是 16 位：20 kHz 下 3.28 s 回绕一次，`dc.metrics()` 里
         `(b-a)&0xFFFF` 只在 Δ<65536 时成立 ⇒ **不能**用它算密度；毛刺率直接用
         Δ毛刺 / 实测秒数，`cyc` 只用来估 f_in（带回绕数搜索）。
    """
    for attempt in range(tries):
        try:
            link.ser.reset_input_buffer()
        except Exception:  # noqa: BLE001
            pass
        t0 = dc.read_all(link, timeout)
        w0 = time.time()
        time.sleep(secs)
        w1 = time.time()
        try:
            link.ser.reset_input_buffer()
        except Exception:  # noqa: BLE001
            pass
        t1 = dc.read_all(link, timeout)
        d = {}
        for name in ("gl_1024_gt5.6deg", "gl_2048_gt11.25deg",
                     "gl_4096_gt22.5deg", "gl_8192_gt45deg", "cyc_pulse_cnt"):
            a, b = t0.get(name), t1.get(name)
            d[name] = None if (a is None or b is None) else (b - a) & 0xFFFF
        ok = all(d[n] is not None for n in d)
        if ok:
            # 单调性自检：>5.6° 的计数不可能少于 >11.25° 的
            ok = (d["gl_1024_gt5.6deg"] >= d["gl_2048_gt11.25deg"] >=
                  d["gl_4096_gt22.5deg"] >= d["gl_8192_gt45deg"])
        if ok:
            return t0, t1, w1 - w0, d
        print("   .. 计数器读数自检失败，重读 (%d/%d)" % (attempt + 1, tries),
              flush=True)
    return t0, t1, w1 - w0, d


def one_round(link, idx, secs, timeout=0.4, f_in=F_IN_DEFAULT):
    row = dict.fromkeys(COLUMNS, "")
    row["ts"] = time.strftime("%H:%M:%S")
    row["iter"] = idx
    row["secs"] = "%.1f" % secs
    # --- 1) ILA 原始码窗口 ---
    csvfile = capture(idx)
    if csvfile:
        try:
            row.update(fit_one(csvfile, f_in))
            row["csv"] = os.path.basename(csvfile)
        except SystemExit as e:      # 位序自检失败等
            row["csv"] = "FIT-FAIL:%s" % e
    else:
        row["csv"] = "CAP-FAIL"
    # --- 2) 计数器窗口 ---
    t0, t1, secs_m, d = read_pair(link, secs, timeout, tries=3)
    row["d_gl1024"] = d["gl_1024_gt5.6deg"]
    row["d_gl2048"] = d["gl_2048_gt11.25deg"]
    row["d_gl4096"] = d["gl_4096_gt22.5deg"]
    row["d_cyc"] = d["cyc_pulse_cnt"]
    if d["gl_1024_gt5.6deg"] is not None:
        row["rate1024"] = "%.4f" % (d["gl_1024_gt5.6deg"] / secs_m)
    if d["gl_2048_gt11.25deg"] is not None:
        row["rate2048"] = "%.4f" % (d["gl_2048_gt11.25deg"] / secs_m)
    row["stat"] = t1.get("status_bits")
    row["secs"] = "%.1f" % secs_m
    if d["cyc_pulse_cnt"] is not None:
        # cyc_pulse_cnt 是每电周期 1 拍 ⇒ 实测 f_in；16 位在 20 kHz 下 3.28 s 回绕，
        # 取最接近 20 kHz 的回绕数 n。
        best = None
        for n in range(0, 32):
            f = (d["cyc_pulse_cnt"] + n * 65536) / secs_m
            if best is None or abs(f - f_in) < abs(best - f_in):
                best = f
        row["f_in"] = "%.1f" % best
    return row


def write_rows(path, rows):
    new = not os.path.exists(path)
    with io.open(path, "a", encoding="utf-8", newline="\n") as f:
        if new:
            f.write(",".join(COLUMNS) + "\n")
        for r in rows:
            f.write(",".join(str(r.get(k, "")) for k in COLUMNS) + "\n")


def fmt_row(r):
    return ("[%s it%-3s] A_kasa=%7s O=(%7s,%7s) dist=%5s | A_sine=%7s dist=%5s"
            " | gl1024=%4s/s gl2048=%4s/s f_in=%8s stat=%s"
            % (r["ts"], r["iter"],
               _s(r.get("A_kasa"), "%7.1f"), _s(r.get("Os_kasa"), "%+7.1f"),
               _s(r.get("Oc_kasa"), "%+7.1f"), _s(r.get("dist_kasa"), "%5.1f"),
               _s(r.get("A_sine"), "%7.1f"), _s(r.get("dist_sine"), "%5.1f"),
               r.get("rate1024", "-"), r.get("rate2048", "-"),
               r.get("f_in", "-"), r.get("stat", "-")))


def _s(v, fmt):
    if v in (None, ""):
        return "-"
    try:
        return fmt % float(v)
    except (TypeError, ValueError):
        return str(v)


def report(path):
    import csv as _csv
    if not os.path.exists(path):
        print("没有 %s" % path)
        return 1
    rows = list(_csv.DictReader(io.open(path, encoding="utf-8")))
    print("=" * 100)
    print(" 漂移跟踪：率 vs 256 格点距离（%s，共 %d 轮）" % (path, len(rows)))
    print("=" * 100)
    print("%-8s %4s | %8s %14s %6s | %8s %6s | %8s %8s"
          % ("时刻", "轮", "A_kasa", "O_kasa", "距离", "A_sine", "距离",
             "1024/s", "2048/s"))
    print("-" * 100)
    for r in rows:
        print("%-8s %4s | %8s %14s %6s | %8s %6s | %8s %8s"
              % (r["ts"], r["iter"], _s(r.get("A_kasa"), "%8.1f"),
                 "(%s,%s)" % (_s(r.get("Os_kasa"), "%+6.1f"),
                              _s(r.get("Oc_kasa"), "%+6.1f")),
                 _s(r.get("dist_kasa"), "%6.1f"),
                 _s(r.get("A_sine"), "%8.1f"), _s(r.get("dist_sine"), "%6.1f"),
                 r.get("rate1024", "-"), r.get("rate2048", "-")))
    # 相关：率 vs 距离（两套拟合）
    for tag in ("kasa", "sine"):
        xs, ys = [], []
        for r in rows:
            try:
                xs.append(float(r["dist_" + tag]))
                ys.append(float(r["rate1024"]))
            except (KeyError, TypeError, ValueError):
                continue
        if len(xs) >= 4:
            n = len(xs)
            mx, my = sum(xs) / n, sum(ys) / n
            cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
            vx = sum((x - mx) ** 2 for x in xs) ** 0.5
            vy = sum((y - my) ** 2 for y in ys) ** 0.5
            pr = cov / (vx * vy) if vx and vy else float("nan")
            print(" 相关系数 Pearson(距离_%s, 率) = %+.3f   n=%d" % (tag, pr, n))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="漂移跟踪：原始码圆 vs 毛刺率")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=uart_spi.BAUD_DEFAULT)
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--secs", type=float, default=60.0, help="每轮计数器窗口长度")
    ap.add_argument("--timeout", type=float, default=0.4)
    ap.add_argument("--f-in", type=float, default=F_IN_DEFAULT)
    ap.add_argument("--csv", default=DEFAULT_CSV)
    ap.add_argument("--report", action="store_true", help="只重算已有 CSV")
    args = ap.parse_args(argv)

    if args.report:
        return report(args.csv)

    ser = uart_spi.open_port(args.port, args.baud, timeout=0.2)
    link = uart_spi.Link(ser, args.baud)
    print("=" * 100)
    print(" 漂移跟踪开始 %s：%d 轮 × (ILA 抓包 + %.0f s 计数器窗)"
          % (time.strftime("%m-%d %H:%M:%S"), args.iters, args.secs))
    print(" ★ 期间不要碰 AFG/板/接线；本工具只用 JTAG 抓包 + 串口读寄存器，不改位流。")
    print("=" * 100)
    rows = []
    try:
        for i in range(args.iters):
            r = one_round(link, i, args.secs, args.timeout, args.f_in)
            rows.append(r)
            write_rows(args.csv, [r])
            print(fmt_row(r), flush=True)
    finally:
        try:
            link.ser.close()
        except Exception:  # noqa: BLE001
            pass
    print("=" * 100)
    print(" 已写入 %s（%d 行）" % (args.csv, len(rows)))
    report(args.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
