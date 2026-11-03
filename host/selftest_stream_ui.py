# -*- coding: utf-8 -*-
"""连续流界面链路的离线冒烟（不需要板子、不需要 socket）。

用一个假的接收器对象替换 `MainWindow._stream`，验证
「定时器 → snapshot → CaptureResult → 面板出图 + 状态行」这条链路。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("SELFTEST_TMP", os.path.join(
    os.environ.get("TEMP", "."), "ui_selftest"))

import numpy as np                                              # noqa: E402
from PySide6.QtWidgets import QApplication                      # noqa: E402

import main_window as mw                                        # noqa: E402

checks = 0
errors = 0


def chk(cond, name):
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print("  [FAIL] %s" % name)


class FakeRx(object):
    """假的 StreamReceiver：直接返回一段正弦样点。"""

    def __init__(self, n=4096):
        self.packets = 123
        self.lost = 0
        self.rate_sps = 12.5e6
        self._n = n
        # 2026-11-02: MainWindow._on_stream_tick_body 会先查 running / last_error，
        # 假接收器缺这两个属性时会在 tick 里抛 AttributeError（被 tick 的 try 吞掉，
        # 表现为 result() 恒为 None、自检以 AttributeError 崩掉而不是给出 FAIL）。
        self.running = True
        self.last_error = None

    def snapshot(self, max_pts=4096):
        n = min(self._n, max_pts)
        t = np.arange(n, dtype=np.float64)
        s = (20000 * np.sin(2 * np.pi * t / 500.0)).astype(np.int16)
        c = (15000 * np.cos(2 * np.pi * t / 500.0)).astype(np.int16)
        return {"s": s, "c": c, "n": n, "first": 0, "head": n, "dec": 2,
                "t0_s": 0.0}

    def stop(self):
        pass


def main():
    app = QApplication([])
    w = mw.MainWindow()
    w.show_page("capture")

    p = w.capture.params()
    chk(p["transport"] in ("serial", "udp", "stream"), "通道参数存在")

    w._stream = FakeRx()
    w._stream_p = {"src": 0, "dec_log2": 2}
    w._on_stream_tick()

    res = w.capture.result()
    chk(len(res.s) == 1024, "面板收到 1024 点（tick 只取最近 1024 点）")
    chk(abs(res.fs - 12.5e6) < 1.0, "采样率 = 12.5 MSPS")
    txt = w.capture.lab_sum.text()
    chk("123" in txt, "状态行显示包数", )
    chk("丢 0 点" in txt, "状态行显示丢点数")

    # 停止：不应抛异常，且按钮回到「抓一次」
    w.capture.set_streaming(True)
    chk(w.capture.btn_cap.text() == "停止连续流", "运行中文案")
    w._stream_timer.stop()
    w.capture.set_streaming(False)
    chk(w.capture.btn_cap.text() == "抓一次", "停止后文案")

    print("\n%d checks, %d errors" % (checks, errors))
    if errors == 0:
        print(" TEST PASSED")
        return 0
    print(" TEST FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
