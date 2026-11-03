"""30 秒稳速记录 → 前端自校正报告（无外部基准）。

用法（PowerShell）：
    python -X utf8 tools\\_report_stable.py COM4 30

只读：全程不写任何寄存器。产出
    %TEMP%\\stable_report.png     点云 + 残差 + 分段漂移
    %TEMP%\\stable_<时间>.bin      原始 18 字节帧（可用「记录」页回放）

为什么这么设计（改之前先读）：
1. 没有外部基准时，"精度"无从谈起，能给的硬指标只有三个：
   ① 前端模型参数（等幅/正交/零偏是数学事实，与转速无关）；
   ② 分段重复性（同一套估计在多个时间段是否给同一答案）；
   ③ 处理链残差的常数项与抖动（板上角度字 vs 同帧 arctan2）。
2. 所有结论都按"机械角"出口径：电角度要除以每转信号周期数
   （本机 2048，由 cycle_cnt 与 Z 的关系定；没有 Z 时不折）。
3. 转速不在这里估——10 kHz 采样对 >5 kHz 的信号必然混叠，估了就是骗人。
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import numpy as np

import analysis as an
import ports as pm
import uart_scope as us

SEGMENTS = 10
BINS_DEG = 10.0
# 本机：每转 2048 个信号周期（由 1019 Hz @ 29.9 rpm 反推，见 docs/42 的实测记录）
CPR = 2048


def pick_port(want=None):
    if want:
        return want
    for d, s, h in pm.list_serial_ports():
        if pm.looks_like_board(d, s, h):
            return d
    for d, s, h in pm.list_serial_ports():
        return d
    raise SystemExit("没有可用串口")


def capture(port, seconds):
    import serial
    ser = serial.Serial(port, 2000000, timeout=0.05)
    buf = b""
    frames = []
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        buf += ser.read(16384)
        fs, _st = us.parse_stream(buf)
        if fs:
            frames.extend(fs)
            buf = buf[-64:]
    ser.close()
    return frames


def main(argv):
    port = pick_port(argv[1] if len(argv) > 1 else None)
    seconds = float(argv[2]) if len(argv) > 2 else 30.0
    print("端口 %s ｜ 采 %.0f s ｜ 只读" % (port, seconds))
    fr = capture(port, seconds)
    n = len(fr)
    t_s = n / 10000.0
    s = np.array([f["s"] for f in fr], float)
    c = np.array([f["c"] for f in fr], float)
    ang = np.array([f["angle_deg"] for f in fr], float)
    cc = np.array([f["cycle_cnt"] for f in fr], np.int64)
    amp = np.hypot(s, c)

    print("采集   %.2f s ｜ %d 帧 ｜ %.0f SPS ｜ 幅值 mean %.0f (p1 %.0f / p99 %.0f) 满刻度 32768"
          % (t_s, n, n / t_s, amp.mean(), np.percentile(amp, 1), np.percentile(amp, 99)))

    # ---- 整体拟合 ----
    p = an.fit_quadrature(s, c, theta_deg=ang)
    e = an.front_end_error(p)
    print("拟合   R_s %.2f  R_c %.2f ｜ 增益 %+.4f dB ｜ 正交 %+.4f° ｜ 偏置 %+.1f / %+.1f LSB ｜ 残差 %.1f LSB"
          % (p["r_s"], p["r_c"], p["gain_dB"], p["eps_deg"], p["off_s"], p["off_c"], p["res_rms"]))
    print("折算   gain %.2f″  ｜  orth %.2f″  ｜  off %.2f″  ｜  合计 %.2f″  （机械角，÷%d）"
          % (e["gain_deg"] / CPR * 3600, e["orth_deg"] / CPR * 3600,
             e["off_deg"] / CPR * 3600, e["total_deg"] / CPR * 3600, CPR))

    # ---- 取点覆盖 ----
    cov = an.coverage(ang)
    print("覆盖   %d 箱 ｜ 已覆盖 %d ｜ 空箱 %d ｜ 最大缺口 %.1f° ｜ 每箱最少 %d 点"
          % (cov["bins"], cov["bins"] - cov["empty_bins"], cov["empty_bins"],
             cov["gap_deg"], cov["min_count"]))

    # ---- 分段重复性 ----
    idx = np.linspace(0, n, SEGMENTS + 1).astype(int)
    eps_l, gain_l, off_l, tot_l = [], [], [], []
    for k in range(SEGMENTS):
        a, b = idx[k], idx[k + 1]
        if b - a < 1000:
            continue
        pk = an.fit_quadrature(s[a:b], c[a:b], theta_deg=ang[a:b])
        if not pk.get("ok"):
            continue
        ek = an.front_end_error(pk)
        eps_l.append(pk["eps_deg"] * 3600 / CPR)
        gain_l.append(pk["gain_dB"])
        off_l.append(np.hypot(pk["off_s"], pk["off_c"]))
        tot_l.append(ek["total_deg"] * 3600 / CPR)
    if len(tot_l) > 1:
        print("分段   %d 段 ｜ 正交 %.2f~%.2f″（σ %.3f″） ｜ 增益 σ %.4f dB ｜ 偏置 σ %.1f LSB ｜ 合计 σ %.3f″"
              % (len(tot_l), min(eps_l), max(eps_l), np.std(eps_l),
                 np.std(gain_l), np.std(off_l), np.std(tot_l)))

    # ---- 处理链残差 ----
    ref = np.degrees(np.arctan2(s, c))
    err = an.wrap_error_deg(ang - ref)
    bins = ((ref + 180.0) // BINS_DEG).astype(int)
    seg_mean, seg_sd = [], []
    for b in range(int(360 / BINS_DEG)):
        m = bins == b
        if m.sum() > 50:
            em = an.wrap_error_deg(err["_raw"] if "_raw" in err else (ang - ref)[m])
            seg_mean.append(em["mean"])
            seg_sd.append(em["rms"])
    err_w = ((ang - ref + 180.0) % 360.0) - 180.0      # 先折回 ±180，否则 350° 与 -10° 差成 360
    wild = int((np.abs(err_w) > 10.0).sum())
    print("残差   均值 %+.2f° ｜ rms %.2f° ｜ p2p %.2f°（电）｜ |e|>10° 的野点 %d 帧（%.3f%%）"
          % (err["mean"], err["rms"], err["p2p"], wild, 100.0 * wild / max(1, n)))
    if seg_mean:
        print("       分 %d 个 %.0f° 箱：常数项 %.2f~%.2f°（σ %.2f°）、箱内 rms %.2f~%.2f°"
              % (len(seg_mean), BINS_DEG, min(seg_mean), max(seg_mean),
                 float(np.std(seg_mean)), min(seg_sd), max(seg_sd)))
        print("       折机械：常数项 %.1f~%.1f″、抖动 %.2f~%.2f″"
              % (min(seg_mean) * 3600 / CPR, max(seg_mean) * 3600 / CPR,
                 min(seg_sd) * 3600 / CPR, max(seg_sd) * 3600 / CPR))

    # ---- 链路 ----
    fl = [f.get("io_flags") for f in fr]
    fl = np.array([x for x in fl if isinstance(x, int)], np.int64)
    if fl.size:
        print("标记   lag_warn %.2f%% ｜ lag_fatal %.2f%% ｜ cor_sat %.2f%% ｜ amp_bad %.2f%%"
              % ((fl & 1).astype(bool).mean() * 100, (fl & 2).astype(bool).mean() * 100,
                 (fl & 64).astype(bool).mean() * 100, (fl & 128).astype(bool).mean() * 100))
    print("周期   cycle_cnt %+d ｜ 折合 %+.0f Hz 电（>5 kHz 会混叠，仅供参考）"
          % (cc[-1] - cc[0], (cc[-1] - cc[0]) / t_s))

    # ---- 存 bin + 出图 ----
    try:
        import record_bin as rb
        stamp = time.strftime("%H%M%S")
        bp = os.path.join(os.environ.get("TEMP", "."), "stable_%s.bin" % stamp)
        recs = []
        for f in fr:
            raw = f.get("raw")
            if not raw:
                raw = us.build_frame(int(f.get("angle") or 0), int(f.get("s") or 0),
                                     int(f.get("c") or 0), int(f.get("io_state") or 0),
                                     int(f.get("io_flags") or 0),
                                     int(f.get("pos_full") or 0),
                                     int(f.get("stat") or 0))
            recs.append({"raw": raw})
        with rb.BinRecorder(bp, meta={"tool": "report_stable"}) as rec:
            rec.write_frames(recs)
        print("bin    %s（%.1f MB）" % (bp, os.path.getsize(bp) / 1e6))
    except Exception as exc:                                   # 记录失败不影响报告
        print("bin    未存：%s" % exc)

    png = os.path.join(os.environ.get("TEMP", "."), "stable_report.png")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
        plt.rcParams["axes.unicode_minus"] = False
        fig, ax = plt.subplots(1, 2, figsize=(11, 4.4), dpi=110)
        step = max(1, n // 40000)
        ax[0].plot(s[::step], c[::step], ",", color="#2b7de9", alpha=0.5)
        ax[0].set_title("s-c 点云（%d 点）  轴比 %.4f" % (len(s[::step]), p["r_c"] / p["r_s"]))
        ax[0].set_xlabel("s (LSB)")
        ax[0].set_ylabel("c (LSB)")
        ax[0].set_aspect("equal", adjustable="datalim")
        ax[0].grid(alpha=0.3)
        ax[1].plot(ang[::step], err_w[::step], ",", color="#e8582b", alpha=0.4)
        ax[1].set_title("板上角度 − arctan2(s,c)  均值 %+.2f°  rms %.2f°（电）" % (err["mean"], err["rms"]))
        ax[1].set_xlabel("电角度 (°)")
        ax[1].set_ylabel("差 (°, 电, 已折回 ±180)")
        ax[1].set_ylim(-3.0, 3.0)
        ax[1].grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(png)
        plt.close(fig)
        print("png    %s" % png)
    except Exception as exc:
        print("png    未出：%s" % exc)


if __name__ == "__main__":
    main(sys.argv)
