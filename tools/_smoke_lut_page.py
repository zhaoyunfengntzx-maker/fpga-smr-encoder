"""诊断页全周补偿表冒烟：造一条误差曲线、导进卡片、出图。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_lut_page.py
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtWidgets import QApplication

import main_window as mw


def curve(n=48):
    """两阶误差：6″ 的一次 + 4″ 的二次 + 1.5″ 的四次，最典型的光栅/转台误差形状。"""
    out = []
    for k in range(n):
        deg = 360.0 * k / n
        err = (6.0 * math.sin(math.radians(deg))
               + 4.0 * math.cos(math.radians(2 * deg))
               + 1.5 * math.sin(math.radians(4 * deg)))
        out.append((deg, err))
    return out


def main(argv):
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page("diag")
    ok, _lines = win.lut.set_pairs(curve(), "demo_error_48pt.csv")
    win.lut.set_dump({0: 0, 512: 260, 1024: 0, 2048: -260})
    app.processEvents()
    out = argv[1] if len(argv) > 1 else os.path.join(
        os.environ.get("TEMP", "."), "lut_page.png")
    win.grab().save(out)
    print("[check] ok=%s" % ok)
    print("[grid] 点数=%s 峰峰=%s RMS=%s 折算=%s"
          % (win.lut.v_n.text(), win.lut.v_pp.text(),
             win.lut.v_rms.text(), win.lut.v_lsb.text()))
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main(sys.argv)
