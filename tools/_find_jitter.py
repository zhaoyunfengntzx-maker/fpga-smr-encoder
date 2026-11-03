"""找出界面里「会自己变尺寸」的控件——界面上抖来抖去的根源。

做法：把主窗口搭起来，喂两组差异很大的数据（一组小转速/短文案，一组大转速/长文案），
中间 processEvents，然后比较每个控件的 geometry。谁变了尺寸，谁就是抖动源。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_find_jitter.py [页面key]
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import numpy as np
from PySide6.QtWidgets import QApplication, QLabel, QWidget

import main_window as mw


def make_frames(n, amp, off, turns, seed=3):
    rng = np.random.default_rng(seed)
    th = np.linspace(0.0, 2.0 * np.pi * turns, n, endpoint=False)
    s = amp * np.sin(th) + off + rng.normal(0, 1.5, n)
    c = amp * np.cos(th + np.radians(0.4)) + off + rng.normal(0, 1.5, n)
    return [{"s": int(round(s[k])), "c": int(round(c[k])),
             "angle": int(round((th[k] / (2 * np.pi) % 1.0) * 65536.0)) % 65536,
             "io_bits": {"z": 0}} for k in range(n)]


def geo_map(win):
    out = {}
    for w in win.findChildren(QWidget):
        if not w.isVisible():
            continue
        key = (w.metaObject().className(), w.objectName(),
               (w.text()[:18] if isinstance(w, QLabel) else ""), id(w))
        g = w.geometry()
        out[key] = (g.x(), g.y(), g.width(), g.height())
    return out


def diff(a, b):
    rows = []
    for k in a:
        if k in b and a[k] != b[k]:
            rows.append((k[0], k[1], k[2], a[k], b[k]))
    return rows


def main(argv):
    page = argv[1] if len(argv) > 1 else "live"
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page(page)
    app.processEvents()

    # A：小值、短文案
    fa = make_frames(1500, 900.0, 3.0, 2.2)
    win.speed.feed(fa, t_now=1000.0)
    win.wave.feed(fa, force_draw=True)
    win.quality.feed(fa, force=True)
    app.processEvents()
    a = geo_map(win)

    # B：大值、长文案
    fb = make_frames(1500, 26000.0, 180.0, 3.7, seed=9)
    win.speed.feed(fb, t_now=1001.0)
    win.wave.feed(fb, force_draw=True)
    win.quality.feed(fb, force=True)
    if hasattr(win, "board_status"):
        win.board_status.set_raw({0x0130: 1, 0x0131: 0x05, 0x0138: 0xFFF6, 0x0139: 0xFF,
                                  0x013A: 10, 0x013B: 0, 0x013C: 1})
    app.processEvents()
    b = geo_map(win)

    rows = diff(a, b)
    print("页面 %s ｜ 可见控件 %d ｜ 尺寸/位置变化的控件 %d 个" % (page, len(a), len(rows)))
    for cls, name, text, ga, gb in rows[:40]:
        print("  %-14s %-10s %-20s  %sx%s@%s,%s  →  %sx%s@%s,%s"
              % (cls, name or "-", text or "-", ga[2], ga[3], ga[0], ga[1],
                 gb[2], gb[3], gb[0], gb[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
