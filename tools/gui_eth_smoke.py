"""上位机以太网通道冒烟测试（offscreen 驱动真实 MainWindow）。

动机：以太网链路的失败模式（端口被占、host_mac=0、目的 MAC/端口写错）
都发生在「GUI → 串口配置 → 网口收包」这条组合路径上，单测覆盖不到。
这个脚本用 offscreen Qt 起一个真的 MainWindow，连真板跑一遍：
网络自检 → 网口 UDP 抓包 → 连续流开关，全部断言通过才 PASS。

用法：
    python tools/gui_eth_smoke.py --port COM6
    python tools/gui_eth_smoke.py --port COM6 --no-stream

注意：会真的配置板子（改 0x070C、触发一次抓包），跑完会 stop 连续流。
"""

import argparse
import os
import sys
import time

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))

from PySide6.QtCore import QTimer                      # noqa: E402
from PySide6.QtWidgets import QApplication             # noqa: E402


def main():
    ap = argparse.ArgumentParser(description="上位机以太网通道冒烟测试")
    ap.add_argument("--port", default="COM6", help="串口（默认 COM6）")
    ap.add_argument("--timeout", type=float, default=60.0, help="总超时秒")
    ap.add_argument("--stream-seconds", type=float, default=3.0,
                    help="连续流观察时长")
    ap.add_argument("--no-stream", action="store_true", help="跳过连续流")
    args = ap.parse_args()

    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    app = QApplication([])
    import main_window as mw                            # noqa: E402

    w = mw.MainWindow()
    w.connect_to(args.port)
    t0 = time.time()
    st = {"phase": 0, "t": 0.0, "ok": True, "notes": []}

    def fail(msg):
        st["ok"] = False
        st["notes"].append("FAIL " + msg)
        app.quit()

    def tick():
        app.processEvents()
        now = time.time()
        if now - t0 > args.timeout:
            fail("总超时，停在 phase %d" % st["phase"])
            return
        if w.worker is None or not w.worker.connected:
            return
        if st["phase"] == 0:
            w._net_check()
            st["phase"] = 1
            st["t"] = now
            return
        if st["phase"] == 1:
            txt = w.capture.lab_net.text()
            if txt.startswith("网口 ") and "ping" in txt:
                st["notes"].append("自检: " + txt)
                if "ARP ✓" not in txt:
                    st["notes"].append("WARN ARP 未置位（可能刚上电）")
                w.capture.set_connected(True)
                w._on_capture_requested({"src": 0, "dec_log2": 1, "length": 28672,
                                         "trig": 0, "level": 0, "pre": 1024,
                                         "transport": "udp"})
                st["phase"] = 2
                st["t"] = now
            elif now - st["t"] > 12:
                fail("网络自检没出结果：" + txt[:80])
            return
        if st["phase"] == 2:
            if w.capture.result() is not None:
                res = w.capture.result()
                st["notes"].append("UDP 抓包: %d 点, 缺块 %d" %
                                   (res.n, len(getattr(res, "missing", []) or [])))
                if res.n != 28672:
                    fail("UDP 抓包点数不对：%d" % res.n)
                    return
                if args.no_stream:
                    app.quit()
                    return
                w._on_capture_requested({"src": 0, "dec_log2": 2, "length": 28672,
                                         "trig": 0, "level": 0, "pre": 1024,
                                         "transport": "stream"})
                st["phase"] = 3
                st["t"] = now
            elif now - st["t"] > 20:
                fail("UDP 抓包超时：" + w.capture.lab_sum.text()[:80])
            return
        if st["phase"] == 3:
            if now - st["t"] > args.stream_seconds:
                if w._stream is None:
                    fail("连续流没起来")
                    return
                r = w._stream
                st["notes"].append("连续流: %d 包 / %.2f MSPS / 丢 %d 点" %
                                   (r.packets, r.rate_sps / 1e6, r.lost))
                if r.packets < 100:
                    fail("连续流收包太少：%d" % r.packets)
                    return
                w._on_capture_requested({"src": 0, "dec_log2": 2, "length": 28672,
                                         "trig": 0, "level": 0, "pre": 1024,
                                         "transport": "stream"})
                st["phase"] = 4
                st["t"] = now
            return
        if st["phase"] == 4 and now - st["t"] > 1.0:
            if w.capture.btn_cap.text() != "抓一次":
                fail("停止后按钮没复位：%s" % w.capture.btn_cap.text())
                return
            st["notes"].append("停止后按钮已复位")
            app.quit()

    timer = QTimer()
    timer.timeout.connect(tick)
    timer.start(150)
    QTimer.singleShot(int(args.timeout * 1000) + 5000, app.quit)
    app.exec()

    try:
        if w.worker is not None:
            w.worker.stop()
    except Exception:                                   # noqa: BLE001
        pass

    for n in st["notes"]:
        print("  " + n)
    print("结论:", "PASS" if st["ok"] else "FAIL")
    return 0 if st["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
