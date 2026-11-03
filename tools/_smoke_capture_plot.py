"""抓包页冒烟：时域/频谱/游标三条路径都要能画出来、读数不为空。"""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, "host"))

import numpy as np

from PySide6.QtWidgets import QApplication

app = QApplication([])

import capture as cap
import panel_capture as pc

fs = 25.0e6
n = 28672
t = np.arange(n) / fs
s = 10000.0 * np.sin(2 * np.pi * 20000.0 * t) + 120.0 * np.sin(2 * np.pi * 60000.0 * t)
c = 10000.0 * np.cos(2 * np.pi * 20000.0 * t + 0.01)
res = cap.CaptureResult(s, c, {"trig_idx": 0, "src": 0, "dec_log2": 1,
                               "fs": fs, "elapsed_s": 0.1})

p = pc.CapturePanel()
p.resize(1100, 720)
p.show()
p.set_result(res)
app.processEvents()
print("[time]", p.lab_spec.text())

p.cb_view.setCurrentIndex(1)
app.processEvents()
print("[spec]", p.lab_spec.text())
print("[spec-plot] fund=%.1f thd=%.3f" % (
    p.plot.spec_info()["fund_hz"], p.plot.spec_info()["thd_pct"]))

p.cb_view.setCurrentIndex(0)
p.plot._cur = [0.30, 0.60]
m = p.plot.cursor_readout()
print("[cursor]", "dt_ms=%.4f f=%.1f ds=%.0f dc=%.0f d=%.2f" % (
    m["dt_ms"], m["f_hz"], m["ds"], m["dc"], m["d_deg"]))

out = os.path.join(os.environ.get("TEMP", "."), "cap_spec.png")
p.cb_view.setCurrentIndex(1)
app.processEvents()
p.grab().save(out)
print("[png-spec]", out, os.path.getsize(out))
p.cb_view.setCurrentIndex(0)
app.processEvents()
out2 = os.path.join(os.environ.get("TEMP", "."), "cap_time.png")
p.grab().save(out2)
print("[png-time]", out2, os.path.getsize(out2))
print("SMOKE OK")
