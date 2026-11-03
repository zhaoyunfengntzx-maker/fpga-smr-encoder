"""实时页冒烟：把主窗口搭起来、切到「实时」、喂一批合成帧，出图看版面。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_live_page.py [输出.png]

为什么单独有这个脚本：`app.py --smoke` 只截「概览」页，看不出波形卡与
正交质量卡在同一屏里的排版（这两张卡是后加的，最容易挤）。
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import numpy as np
from PySide6.QtWidgets import QApplication

import main_window as mw


def make_frames(n=1500, r_s=9000.0, r_c=9270.0, eps_deg=0.6, o_s=120.0,
                o_c=-90.0, noise=12.0, turns=3.3, seed=11, f_hz=None):
    """造 n 帧合成遥测。

    f_hz=None：按 turns 扫过若干个电周期（点云铺满整圈，给波形/质量卡用）。
    f_hz 给了：按真实采样率走（每帧 f_hz/10000 个电周期，pos_full 同步累加），
                这样转速估计器能算出正确的 f_in 与 rpm。
    """
    rng = np.random.default_rng(seed)
    if f_hz:
        th = 2.0 * np.pi * f_hz * np.arange(n) / 10000.0
    else:
        th = np.linspace(0.0, 2.0 * np.pi * turns, n, endpoint=False)
    s = r_s * np.sin(th) + o_s + rng.normal(0.0, noise, n)
    c = r_c * np.cos(th + np.radians(eps_deg)) + o_c + rng.normal(0.0, noise, n)
    out = []
    for k in range(n):
        ang = int(round((th[k] / (2.0 * np.pi) % 1.0) * 65536.0)) % 65536
        cyc = int(th[k] / (2.0 * np.pi)) & 0xFFFF
        out.append({"s": int(round(s[k])), "c": int(round(c[k])),
                    "angle": ang, "pos_full": (cyc << 16) | ang,
                    "io_flags": 0, "stat": 1,
                    "io_bits": {"z": 1 if k % 640 < 25 else 0}})
    return out


def main(argv):
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page("live")
    frames = make_frames()
    # 转速估计要 1 s 平滑窗，而且必须按 10 kHz 的节拍分批喂（t_now 是秒），
    # 像真机那样一次 1000 帧 —— 一次性塞进去估算器会判数据不足。
    big = make_frames(n=12000, f_hz=7196.0)
    for k in range(0, len(big), 1000):
        win.speed.feed(big[k:k + 1000], t_now=1000.0 + k / 10000.0)
    win.wave.feed(frames, force_draw=True)
    win.quality.feed(frames, force=True)
    app.processEvents()
    out = argv[1] if len(argv) > 1 else os.path.join(
        os.environ.get("TEMP", "."), "live_quality.png")
    win.grab().save(out)
    print("[verdict]", win.quality.lab_verdict.text())
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main(sys.argv)
