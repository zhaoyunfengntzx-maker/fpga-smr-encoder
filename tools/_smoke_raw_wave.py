"""检查「真波形」的画法本身对不对：用合成正弦 (2727 Hz @ 12.5 MSPS) 直接喂
`WavePanel.feed_raw()`，看画出来是干净正弦还是实心色带。

用法：$env:QT_QPA_PLATFORM="offscreen"; python -X utf8 tools\\_smoke_raw_wave.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import numpy as np  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

import panel_wave as pw  # noqa: E402


def main():
    app = QApplication(sys.argv[:1])
    fs = 12.5e6
    f = 2727.0
    n = 62500
    t = np.arange(n) / fs
    s = (25000.0 * np.sin(2 * np.pi * f * t)).astype(np.float64)
    c = (25000.0 * np.cos(2 * np.pi * f * t)).astype(np.float64)

    pan = pw.WavePanel(capacitiy=1500) if False else pw.WavePanel(capacity=1500)
    pan.resize(1200, 520)
    pan.show()
    pan.feed_raw(s, c, fs)
    app.processEvents()

    line = getattr(pan, "line_s", None)
    print("[set_data n]", 0 if line is None else len(line.get_xdata()))
    if line is not None:
        xs = np.asarray(line.get_xdata(), dtype=float)
        ys = np.asarray(line.get_ydata(), dtype=float)
        print("[x span] %.4f .. %.4f ms" % (xs.min(), xs.max()))
        print("[y span] %.0f .. %.0f" % (ys.min(), ys.max()))
        # 干净正弦：相邻点斜率平滑，且 y 的极值出现次数 ≈ 周期数
        print("[n pts on screen]", len(xs))
    out = os.path.join(os.environ.get("TEMP", "."), "raw_wave_check.png")
    pan.grab().save(out)
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main()
