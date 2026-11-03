"""顶栏「数据源」按钮截图（离屏）。

用法：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_src_btn.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtCore import QPoint
from PySide6.QtWidgets import QApplication

import main_window as mw


def main():
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1500, 220)
    win.show()
    app.processEvents()
    win._net_on()                       # 强制切到网口态看文案
    app.processEvents()
    bar = win.topbar
    img = win.grab(bar.geometry().adjusted(-4, -4, 4, 4))
    out = os.path.join(os.environ.get("TEMP", "."), "src_btn.png")
    img.save(out)
    print("[combo] %s" % win.cmb_src.currentText())
    print("[png] %s %dx%d" % (out, img.width(), img.height()))
    print("SMOKE OK")


if __name__ == "__main__":
    main()
