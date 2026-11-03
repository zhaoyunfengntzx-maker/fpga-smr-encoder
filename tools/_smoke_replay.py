"""回放冒烟：造一份 .bin → 主窗口回放 → 看波形/质量卡是否真的动起来。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_replay.py
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import math

import record_bin as rb
import uart_scope as us
from PySide6.QtWidgets import QApplication

import main_window as mw


def make_bin(path, n=3000, r_s=9000.0, r_c=9270.0, eps=0.6, turns=4.0,
             o_s=120.0, o_c=-90.0):
    rec = rb.BinRecorder(path, fs_hz=10000, meta={"csv": "selftest.csv"})
    for i in range(n):
        th = 2.0 * math.pi * turns * i / float(n)
        s = int(round(r_s * math.sin(th) + o_s))
        c = int(round(r_c * math.cos(th + math.radians(eps)) + o_c))
        ang = int(round((th / (2.0 * math.pi) % 1.0) * 65536.0)) & 0xFFFF
        rec.write_raw(us.build_frame(ang, s, c, 0, 0, i, 1))
    rec.close()
    return rec.stats()


def main():
    d = tempfile.mkdtemp(prefix="replaysmoke_")
    p = os.path.join(d, "demo.bin")
    st = make_bin(p)
    print("[bin] %d 帧 %.2f MB" % (st["n"], st["bytes"] / 1e6))

    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.start_replay(p)
    fed = 0
    for _ in range(4):
        win._tick_body()
        app.processEvents()
        fed += 1
    print("[verdict]", win.quality.lab_verdict.text())
    print("[wave] n=%d" % len(win.wave.buf.snapshot()["t"]))
    out = os.path.join(os.environ.get("TEMP", "."), "replay_page.png")
    win.grab().save(out)
    print("[png]", out)
    # 放完最后一批应当自动收尾
    for _ in range(40):
        win._tick_body()
    print("[done]", win._replay is None)
    print("SMOKE OK")


if __name__ == "__main__":
    main()
