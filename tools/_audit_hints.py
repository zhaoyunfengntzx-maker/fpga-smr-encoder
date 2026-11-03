"""审计：锁成 N 行的提示有没有装不下（被裁掉的文字）。

配合 `ui_kit._apply_fixed_lines` 的"min == max"锁死使用（m02689）。
跑完看输出：谁 `需要 > 现有高度`，就去它的构造处把 lines 调大。
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtWidgets import QApplication, QLabel

import main_window as mw

PAGES = ("overview", "live", "enc", "alarm", "record", "capture", "diag")


def main(argv):
    wide = int(argv[1]) if len(argv) > 1 else 1280
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(wide, 1000)
    win.show()
    bad = 0
    for page in PAGES:
        win.show_page(page)
        app.processEvents()
        for lab in win.findChildren(QLabel):
            if not lab.isVisible():
                continue
            if lab.property("fixedLines") is None:
                continue
            need = lab.heightForWidth(lab.width())
            if need > lab.height() + 1:
                bad += 1
                print("   装不下：%s 页 · lines=%s 高 %d 需要 %d · %r"
                      % (page, lab.property("fixedLines"), lab.height(), need,
                         lab.text()[:44]))
    print("窗口宽 %d ｜ 装不下的提示：%d 条" % (wide, bad))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
