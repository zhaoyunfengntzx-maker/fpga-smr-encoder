"""编码器信号页冒烟：看 UVW 那半边的新控件排得下吗。

用法：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_abz.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import numpy as np
from PySide6.QtWidgets import QApplication

import main_window as mw


def make_frames(n=1500, f_hz=156.25, pairs=4.0, seed=5):
    rng = np.random.default_rng(seed)
    out = []
    for k in range(n):
        th = 2.0 * np.pi * f_hz * (k / 10000.0)
        a = (th % (2.0 * np.pi)) / (2.0 * np.pi)
        ang = int(round(a * 65536.0)) % 65536
        cyc = int(f_hz * (k / 10000.0)) & 0xFFFF
        s = int(round(26000 * np.sin(th) + rng.normal(0, 40)))
        c = int(round(26000 * np.cos(th) + rng.normal(0, 40)))
        # UVW 六状态：按 rtl/uvw_gen.v 的扇区映射（eang = 角度 × pairs）
        eang = (ang * int(pairs)) & 0xFFFF
        sec = (eang * 6) >> 16
        st = (0b110, 0b010, 0b011, 0b001, 0b101, 0b100)[sec]
        out.append({"angle": ang, "s": s, "c": c,
                    "pos_full": ((cyc << 16) | ang) & 0xFFFFFFFF,
                    "io_bits": {"a": int((th * 64 / (2 * np.pi)) % 2),
                                "b": int((th * 64 / (2 * np.pi) + 0.5) % 2),
                                "z": 0,
                                "u": (st >> 2) & 1, "v": (st >> 1) & 1, "w": st & 1}})
    return out


def main(argv):
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page("enc")
    frames = make_frames()
    win.abz.set_f_in(156.25)
    win.abz.feed(frames, force_draw=True)
    # 复现用户截图那组设置：ABZ 横轴 90°、UVW 横轴 60°
    win.abz.cmb_xspan.setCurrentIndex(0)  # 自动整圈
    win.abz.cmb_uvw_span.setCurrentIndex(0)  # 整圈 360°
    app.processEvents()
    out = os.path.join(os.environ.get("TEMP", "."), "abz_page.png")
    win.grab().save(out)
    print("[uvw span]", win.abz._uvw_span, "pairs", win.abz.an.pairs)
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main(sys.argv)
