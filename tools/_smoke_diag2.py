"""诊断页两张新卡的冒烟：全周补偿表 + 链路健康趋势，出图。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_diag2.py
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtWidgets import QApplication

import main_window as mw


def curve(n=72):
    out = []
    for k in range(n):
        deg = 359.9 * k / (n - 1)
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
    ok, _lines = win.lut.set_pairs(curve(), "demo_error_72pt.csv")
    win.lut.set_dump({0: 0, 512: 260, 1024: 0, 2048: -260})
    # 造一条"前 90 s 正常、之后帧率掉、校验错抬起来"的趋势
    base = 100.0
    for k in range(90):
        t = base + 2.0 * k
        fps = 10000.0 - (0.0 if k < 60 else 9.0 * (k - 60))
        err = 0.38 if k < 60 else 0.38 + 0.02 * (k - 60)
        win.health.push(t, fps, err, 5 + (0 if k < 60 else k - 60))
    win.health.show()
    app.processEvents()
    # 滚到「链路健康趋势」这张卡的开头，让两张新卡都在视野里
    from PySide6.QtCore import QPoint
    inner = win.scroll.widget()
    y = win.health.mapTo(inner, QPoint(0, 0)).y()
    sb = win.scroll.verticalScrollBar()
    sb.setValue(max(0, min(sb.maximum(), y - 90)))
    app.processEvents()
    out = argv[1] if len(argv) > 1 else os.path.join(
        os.environ.get("TEMP", "."), "diag2_page.png")
    win.grab().save(out)
    print("[lut] ok=%s 点数=%s 折算=%s" % (ok, win.lut.v_n.text(), win.lut.v_lsb.text()))
    print("[health] n=%d fps=%s err=%s" % (win.health.count(),
                                           win.health.last("fps"), win.health.last("err")))
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main(sys.argv)
