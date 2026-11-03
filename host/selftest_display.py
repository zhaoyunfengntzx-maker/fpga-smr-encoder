"""显示链路自检（P0/P1/P2）：包络抽稀、可选平滑、缺块标黄、参数持久化。

不连板子、不需要串口：造一段带尖峰和噪声的波形喂给抓包页，检查
  * 画出来的数据没被改（res.s/res.c 原样）；
  * 平滑只作用于绘制副本（实时页 _smooth 跟着走）；
  * 「显示」下拉的档位能存进 ui_prefs 再读回来；
  * 包络一定含每列极值（尖峰不会像点采样那样被丢掉）。

用法：python host\selftest_display.py
"""

import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QPA_FONTDIR", os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import numpy as np

FAIL = []


def check(name, ok, info=""):
    print("  [%s] %s%s" % ("OK" if ok else "FAIL", name, ("    " + info) if info else ""))
    if not ok:
        FAIL.append(name)


def main():
    from PySide6.QtWidgets import QApplication

    app = QApplication.instance() or QApplication([])

    import capture as cap
    import filters as fl
    import main_window as mw
    import ui_prefs as up

    print("=" * 74)
    print("① filters：包络 / 平滑")
    print("=" * 74)
    n = 28672
    rng = np.random.default_rng(7)
    s = 1500 * np.sin(np.arange(n) * 0.01) + rng.normal(0, 20, n)
    s[9000] += 12000.0                       # 单点尖峰：点采样会随机丢，包络必须留住
    env = fl.envelope(s, 1200)
    check("包络长度 = 列数", len(env[0]) == 1200, "cols=%d" % len(env[0]))
    check("包络含全局极大值（尖峰不被抽稀丢掉）", float(np.max(env[2])) >= float(np.max(s)) - 1e-9,
          "max_env=%.1f max=%.1f" % (np.max(env[2]), np.max(s)))
    check("包络含全局极小值", float(np.min(env[1])) <= float(np.min(s)) + 1e-9)
    sm = fl.smooth(s, 9)
    check("平滑不改变长度", len(sm) == n)
    check("平滑不修改输入数组", float(s[9000]) > 12000.0, "s[9000]=%.0f" % s[9000])

    print("=" * 74)
    print("② 抓包页：显示下拉 + 不改原始数据")
    print("=" * 74)
    w = mw.MainWindow()
    w.resize(1440, 900)
    w.show_page("capture")
    check("有「显示」下拉", w.capture.cb_smooth.count() == 5,
          "items=%d" % w.capture.cb_smooth.count())
    check("默认关闭（0 点）", w.capture.smooth() == 0)

    r = cap.CaptureResult([int(v) for v in s], [int(v) for v in s],
                          {"dec_log2": 1, "trig_idx": 0, "src": 0}, missing=[], n_blocks=448)
    w.capture.set_result(r)
    before = list(r.s[:50])
    w.capture.set_smooth(9)
    app.processEvents()
    check("设 9 点后下拉/实时页同步", w.capture.smooth() == 9 and w.wave._smooth == 9,
          "cap=%d wave=%d" % (w.capture.smooth(), w.wave._smooth))
    check("平滑不改原始数据", list(r.s[:50]) == before)
    w.capture.set_smooth(0)
    app.processEvents()

    print("=" * 74)
    print("③ 缺块标黄区间")
    print("=" * 74)
    r2 = cap.CaptureResult([0] * 640, [0] * 640,
                           {"dec_log2": 1, "trig_idx": 0, "src": 0}, missing=[3], n_blocks=9)
    w.capture.set_result(r2)
    import panel_capture as pc
    segs = pc._missing_ranges(r2)
    check("串口缺块换算成 64 点区间", segs == [(192, 256)], "segs=%r" % (segs,))
    r3 = cap.CaptureResult([0] * 2000, [0] * 2000,
                           {"dec_log2": 1, "trig_idx": 0, "src": 0},
                           missing=[2, 3], n_blocks=19)
    w.capture.set_result(r3)
    segs = pc._missing_ranges(r3)
    check("UDP 缺包按 n/total 换算", len(segs) == 2 and all(b > a for a, b in segs),
          "segs=%r" % (segs,))

    print("=" * 74)
    print("④ 参数持久化")
    print("=" * 74)
    w.capture.set_smooth(15)
    up.put("capture", "smooth", int(w.capture.smooth()))
    up.save()
    up.data()["capture"].pop("smooth", None)
    up.data()  # 触发重新读盘
    import importlib

    importlib.reload(up)
    check("ui_prefs 里存下了平滑档位", int(up.raw("capture", "smooth", 0)) == 15,
          "raw=%r" % (up.raw("capture", "smooth", 0),))
    up.put("capture", "smooth", 0)
    up.save()

    print()
    if FAIL:
        print("FAILED: %d 项 —— %s" % (len(FAIL), ", ".join(FAIL)))
        return 1
    print("display selftest: ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
