"""逐个标签地找"字多字少"导致的版面变化。

做法：一次只改一个可见 QLabel 的文字（短 → 长），记录它自己、它的父控件、
以及整页滚动内容的高度变化。谁变高，谁就是晃的源头。

背景（m02689）：上一轮锁了行高（27↔31 px）仍然晃 ⇒ 说明第二类是**换行**
（QLabel 默认不 wrap，但 QGridLayout 里的 label 被压窄后、或 hint_label 的
wordWrap 打开时，行数会变）或**列宽抽动**（一行里的长文本把相邻列挤窄）。

用法：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_find_wrap.py [页面key] [最多打印条数]
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtWidgets import QApplication, QLabel

import main_window as mw

SHORT = "1"
LONG = "很长很长的说明文字" * 14


def geo(w):
    g = w.geometry()
    return (g.x(), g.y(), g.width(), g.height())


def chain(w, depth=3):
    """自身 + 上溯 3 层父控件的几何，用于发现"标签没变、卡片变了"。"""
    out = []
    p = w
    for _ in range(depth):
        if p is None:
            break
        out.append((p.objectName() or p.__class__.__name__, geo(p)))
        p = p.parentWidget()
    return out


def main(argv):
    app = QApplication(sys.argv[:1])
    page = argv[1] if len(argv) > 1 else "enc"
    limit = int(argv[2]) if len(argv) > 2 else 14
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page(page)
    app.processEvents()

    labels = [w for w in win.findChildren(QLabel) if w.isVisible()]
    print("页面 %s ｜ 可见 QLabel %d 个 ｜ 窗口 %dx%d"
          % (page, len(labels), win.width(), win.height()))
    hits = []
    for lab in labels:
        old = lab.text()
        if not old.strip():
            continue
        lab.setText(old)
        app.processEvents()
        base = chain(lab)
        lab.setText(SHORT)
        app.processEvents()
        a = chain(lab)
        lab.setText(LONG)
        app.processEvents()
        b = chain(lab)
        lab.setText(old)
        app.processEvents()
        if a != b:
            hits.append((lab, old, a, b))

    print("  文字长短会改变几何的标签：%d 个" % len(hits))
    for lab, old, a, b in hits[:limit]:
        print("   · %s  wrap=%s  text=%r" % (lab.objectName() or "-", lab.wordWrap(),
                                             old[:24]))
        for (n1, g1), (n2, g2) in zip(a, b):
            if g1 != g2:
                print("       %-20s (%d,%d %dx%d) → (%d,%d %dx%d)"
                      % (n1, g1[0], g1[1], g1[2], g1[3], g2[0], g2[1], g2[2], g2[3]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
