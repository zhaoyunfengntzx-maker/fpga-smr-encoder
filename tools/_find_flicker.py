"""数一遍：数据在"正常范围内小幅波动"时，界面上哪些数字还在跳。

背景（m02449「软件界面不要抖来抖去」）：几何抖动（卡片被顶得上下跳）已经修完，
用 tools\\_find_jitter.py 量出来 7 个页面都是 0 个控件变尺寸。剩下的是"数字本身在跳"，
这个脚本量化它：喂 60 批、每批 100 帧（每批 = 10 ms 数据，相当于界面一个 tick），
记录每次刷新后所有 FieldName/数值标签的文本，数"变过几次"。

判定口径：
  · 变 0~1 次  = 稳（首帧从「—」变成数值，算 1 次）
  · 变 ≥3 次   = 抖（在这个数据下不该跳）

用法：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_find_flicker.py [页面key]
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import math
import random

from PySide6.QtWidgets import QApplication, QLabel

import main_window as mw

BATCHES = 60
PER_BATCH = 100
FS_HZ = 7196.0          # 现场转速档（每转 2048 周期 → 210.8 rpm）


DRIFT = 0.0002          # 相对频率漂移（±），命令行第 2 个参数可改


def frames(n, t0):
    """造一段"真实但不完美"的遥测：幅值 ~26200、1 LSB 噪声、转速有小幅波动。"""
    out = []
    for k in range(n):
        t = t0 + k / 10000.0
        # 转速不是完完全全恒定：±0.35% 的慢漂
        f = FS_HZ * (1.0 + DRIFT * math.sin(2.0 * math.pi * 0.7 * t))
        ph = 2.0 * math.pi * f * t
        s = 26200.0 * math.sin(ph) + 92.0 + random.gauss(0.0, 1.0)
        c = 26300.0 * math.cos(ph + math.radians(0.30)) + 205.0 + random.gauss(0.0, 1.0)
        ang = int(((ph / (2.0 * math.pi)) % 1.0) * 65536.0) % 65536
        pos = (int(t * f) & 0xFFFF) << 16 | ang
        out.append({"s": int(s), "c": int(c), "angle": ang, "pos_full": pos,
                    "io_flags": 0, "stat": 1})
    return out


def texts(win):
    d = {}
    for lab in win.findChildren(QLabel):
        if not lab.isVisible():
            continue
        if lab.objectName() not in ("BigValueSmall", "BigValue", "BigValueTiny", "Mono"):
            continue
        t = lab.text().strip()
        if t:
            d[id(lab)] = t
    return d


def main(argv):
    global DRIFT
    if len(argv) > 2:
        DRIFT = float(argv[2])
    app = QApplication(sys.argv[:1])
    page = argv[1] if len(argv) > 1 else "live"
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page(page)
    app.processEvents()
    first = texts(win)
    hist = {k: [v] for k, v in first.items()}
    t0 = 0.0
    for i in range(BATCHES):
        t0 += PER_BATCH / 10000.0
        fr = frames(PER_BATCH, t0)
        win.wave.feed(fr, force_draw=True)
        win.quality.feed(fr, force=True)
        win.speed.feed(fr)
        app.processEvents()
        for k, v in texts(win).items():
            if k in hist:
                hist[k].append(v)
    rows = []
    for k, seq in hist.items():
        uniq = []
        for v in seq:
            if not uniq or uniq[-1] != v:
                uniq.append(v)
        rows.append((len(uniq) - 1, seq[0], uniq[-1], len(uniq)))
    rows.sort(reverse=True)
    print("页面 %s ｜ 数值标签 %d 个 ｜ 每批 %d 帧 × %d 批" % (page, len(rows), PER_BATCH, BATCHES))
    bad = 0
    for n, f0, f1, nu in rows:
        if n >= 3:
            bad += 1
            print("  抖 %2d 次：%r → %r（%d 种写法）" % (n, f0, f1, nu))
    print("  抖 ≥3 次的标签：%d 个" % bad)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
