"""打开板端偏置慢跟踪（0x0122 bit1），并**用效果验证**写入是否生效。

为什么要单独写这个脚本、而不是直接 write_reg：
    这块板的读回语义不可信 —— `0x0514/15` 读回 0 而真实增益是 32768；
    反过来 `0x0122` 读回 1 也不能证明 bit1 没被打开。所以本脚本只认三件"效果"：
      ① 0x013C 的 bit0（bias_valid）有没有变 1；
      ② 0x0138/0x0139、0x013A/0x013B（学到的 bias_s/bias_c）有没有变成非零；
      ③ s/c 点云还健不健康（不是全零、没有削顶、角度覆盖仍然满圈）。

安全网：写完 1.5 s 内如果 s 全零或 |s|max > 32500（削顶）或角度不再满圈，
自动把 0x0122 写回旧值，并把抓到的情况打出来。

用法：
    python -X utf8 tools\\_enable_bias.py [COM4] [--off]
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))
sys.path.insert(0, HERE)

import numpy as np
import serial

import analysis as an
import link as lk
import ports as pm
import uart_scope as us

R_CFG = 0x0122          # bit0 前馈使能 / bit1 偏置慢跟踪使能（复位 0）
R_BIAS_S = 0x0138       # 0x0138/39 学到并正在用的 sin 偏置
R_BIAS_C = 0x013A       # 0x013A/B 同上，cos
R_BIAS_ST = 0x013C      # bit0 valid / bit1 big
CAP_S = 3.0


def pick_port(arg=None):
    if arg:
        return arg
    for d, desc, _h in pm.list_serial_ports():
        if pm.looks_like_board(d, desc, _h):
            return d
    raise SystemExit("没找到板子：指定端口，例如 `python -X utf8 tools\\_enable_bias.py COM4`")


def capture(port, seconds=CAP_S):
    ser = serial.Serial(port, 2000000, timeout=0.05)
    buf = b""
    frames = []
    t0 = time.monotonic()
    try:
        while time.monotonic() - t0 < seconds:
            buf += ser.read(16384)
            got, _st = us.parse_stream(buf)
            if got:
                frames.extend(got)
                buf = buf[-64:]
    finally:
        ser.close()
    return frames


def health(frames):
    s = np.array([f["s"] for f in frames], dtype=float)
    c = np.array([f["c"] for f in frames], dtype=float)
    a = np.array([f["angle_deg"] for f in frames], dtype=float)
    d = {}
    d["n"] = len(frames)
    d["s_zero"] = bool(np.all(s == 0))
    d["s_max"] = float(np.max(np.abs(s))) if len(s) else 0.0
    d["c_max"] = float(np.max(np.abs(c))) if len(c) else 0.0
    d["clip"] = bool(d["s_max"] > 32500 or d["c_max"] > 32500)
    d["span"] = float(np.max(a) - np.min(a)) if len(a) else 0.0
    if len(s) > 100 and not d["s_zero"]:
        p = an.fit_quadrature(s, c, theta_deg=a)
        e = an.front_end_error(p)
        d["ok"] = bool(p.get("ok"))
        d["p"] = p
        d["e"] = e
        d["off_s"] = float(p["off_s"])
        d["off_c"] = float(p["off_c"])
        d["total_arcsec"] = float(e["total_deg"]) / 2048.0 * 3600.0
    else:
        d["ok"] = False
    return d


def show(tag, d):
    if not d.get("ok"):
        print("%-6s 帧 %6d ｜ s 全零=%s ｜ 每点最高 %d ｜ 角度跨 %.1f° ｜ **拟合失败**"
              % (tag, d["n"], d["s_zero"], int(d["s_max"]), d["span"]))
        return
    print("%-6s 帧 %6d ｜ 偏置 %+7.1f / %+7.1f ｜ 合计 %.2f″ ｜ s 峰值 %d ｜ 角度跨 %.1f°"
          % (tag, d["n"], d["off_s"], d["off_c"], d["total_arcsec"],
             int(d["s_max"]), d["span"]))


def main(argv):
    off = "--off" in argv
    port = pick_port(next((a for a in argv[1:] if not a.startswith("-")), None))
    print("端口 %s ｜ 目标：%s 0x%04X bit1" % (port, "关掉" if off else "打开", R_CFG))

    w = lk.SerialWorker(port)
    w.start()
    time.sleep(0.9)
    try:
        old = w.read_reg8(R_CFG, timeout=0.6, retries=3)
        if old is None:
            raise SystemExit("读不到 0x0122 —— 板子没在应答（先看诊断页的通信统计）")
        want = (old & ~0x02) if off else (old | 0x02)
        print("0x0122 读回 0x%02X → 写 0x%02X" % (old, want))
    finally:
        w.stop()

    d0 = health(capture(port))
    show("改前", d0)

    w = lk.SerialWorker(port)
    w.start()
    time.sleep(0.9)
    try:
        w.write_reg(R_CFG, want, retries=2, verify=False)
        time.sleep(1.5)                        # bias 窗口 32768 样本 ≈2.6 ms，1.5 s 足够
    finally:
        w.stop()

    d1 = health(capture(port))
    show("改后", d1)

    w = lk.SerialWorker(port)
    w.start()
    time.sleep(0.9)
    try:
        st = w.read_reg8(R_BIAS_ST, timeout=0.6, retries=3)
        bs = w.read_reg8(R_BIAS_S, timeout=0.6, retries=3)
        bs_hi = w.read_reg8(R_BIAS_S + 1, timeout=0.6, retries=3)
        bc = w.read_reg8(R_BIAS_C, timeout=0.6, retries=3)
        bc_hi = w.read_reg8(R_BIAS_C + 1, timeout=0.6, retries=3)
        cfg_now = w.read_reg8(R_CFG, timeout=0.6, retries=3)
    finally:
        w.stop()

    def s16(lo, hi):
        if lo is None or hi is None:
            return None
        v = (lo & 0xFF) | ((hi & 0xFF) << 8)
        return v - 65536 if v & 0x8000 else v

    print("0x0122 读回 0x%s ｜ bias_s %s ｜ bias_c %s ｜ 0x013C bit0(valid) %s bit1(big) %s"
          % ("??" if cfg_now is None else "%02X" % cfg_now,
             s16(bs, bs_hi), s16(bc, bc_hi),
             "?" if st is None else (st & 0x01),
             "?" if st is None else ((st >> 1) & 0x01)))

    bad = d1["s_zero"] or d1["clip"] or d1["span"] < 300.0 or d1.get("total_arcsec", 1e9) > 5.0 * max(d0.get("total_arcsec", 1.0), 1e-9)
    if bad:
        print("！改后不健康（s 全零=%s 削顶=%s 角度跨 %.1f°）→ 自动回滚 0x0122=0x%02X"
              % (d1["s_zero"], d1["clip"], d1["span"], old))
        w = lk.SerialWorker(port)
        w.start()
        time.sleep(0.9)
        try:
            w.write_reg(R_CFG, old, retries=2, verify=False)
            time.sleep(1.0)
        finally:
            w.stop()
        show("回滚", health(capture(port)))
        return 1
    print("OK：改动被接受，s/c 健康。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
