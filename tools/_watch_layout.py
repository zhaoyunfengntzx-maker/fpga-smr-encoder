"""盯着真实刷新过程，抓"哪一帧、哪个控件"的几何变了。

与 `_find_jitter.py`（只比两批极端数据）的区别：这里跑 60 个 tick，每 tick 喂
100 帧**真实量级、会来回穿越阈值**的数据（幅值在门限上下摆动、转速小幅漂），
每 tick 拍一次所有可见控件的几何，最后报告"变过几次、在哪几个 tick 变的"。

用它来判断用户说的"字多字少上下晃"到底是：
  · 某个标签换行 → 自身高度变
  · 卡片被内容顶高 → 卡片高度变
  · 滚动区内容变高 → 竖滚动条出现/消失 → viewport 宽度变 → 文字重新折行

用法：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_watch_layout.py [页面key] [tick数]
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import math
import random

from PySide6.QtWidgets import QApplication, QWidget

import main_window as mw

TICKS = 60
PER_TICK = 100


def frames(n, t0, amp):
    out = []
    for k in range(n):
        t = t0 + k / 10000.0
        f = 7196.0 * (1.0 + 0.002 * math.sin(2.0 * math.pi * 0.4 * t))
        ph = 2.0 * math.pi * f * t
        s = amp * math.sin(ph) + 92.0 + random.gauss(0.0, 1.0)
        c = amp * math.cos(ph + math.radians(0.30)) + 205.0 + random.gauss(0.0, 1.0)
        ang = int(((ph / (2.0 * math.pi)) % 1.0) * 65536.0) % 65536
        io = 0
        if amp < 3000:                 # 低幅值 → amp_low 位，界面会翻文案
            io |= 0x80
        out.append({"s": int(s), "c": int(c), "angle": ang, "io_flags": io,
                    "stat": 1, "pos_full": (int(t * f) & 0xFFFF) << 16 | ang})
    return out


def geo(w):
    g = w.geometry()
    return (g.x(), g.y(), g.width(), g.height())


def main(argv):
    app = QApplication(sys.argv[:1])
    page = argv[1] if len(argv) > 1 else "enc"
    ticks = int(argv[2]) if len(argv) > 2 else TICKS
    wide = int(argv[3]) if len(argv) > 3 else 1600
    win = mw.MainWindow()
    win.resize(wide, 1000)
    win.show()
    win.show_page(page)
    app.processEvents()

    widgets = [w for w in win.findChildren(QWidget) if w.isVisible()]
    hist = {id(w): [] for w in widgets}
    byid = {id(w): w for w in widgets}
    t0 = 0.0
    for i in range(ticks):
        t0 += PER_TICK / 10000.0
        amp = 26000.0 if (i // 7) % 2 == 0 else 1200.0     # 每 7 tick 翻一次幅值档
        fr = frames(PER_TICK, t0, amp)
        win.abz.feed(fr)
        win.wave.feed(fr, force_draw=True)
        win.quality.feed(fr, force=True)
        win.speed.feed(fr)
        app.processEvents()
        for w in widgets:
            if w.isVisible():
                hist[id(w)].append((i, geo(w)))

    print("页面 %s ｜ %d 个 tick ｜ 控件 %d 个" % (page, ticks, len(widgets)))
    bad = 0
    for k, seq in hist.items():
        if len(seq) < 2:
            continue
        first = seq[0][1]
        ch = [(i, g) for i, g in seq if g != first]
        if ch:
            bad += 1
            w = byid[k]
            print("   · %-18s %r  %dx%d → %dx%d，变了 %d 次（首个 %d）"
                  % (w.objectName() or w.__class__.__name__,
                     (w.text()[:14] if hasattr(w, "text") else ""),
                     first[2], first[3], ch[0][1][2], ch[0][1][3], len(ch), ch[0][0]))
    print("  几何变过的控件：%d 个" % bad)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
