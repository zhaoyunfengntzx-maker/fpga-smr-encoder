"""复现「连接 → 断开 → 再连接之后网口起不来」。

逐步打印状态，定位是哪一步把后续启动挡住了：
    busy / _src / _stream / _net_want / 下拉框 / _net_retry_n
用法：python -X utf8 tools\\_diag_reconnect.py [COM4]
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtWidgets import QApplication

import main_window as mw


def pump(app, seconds, until=None):
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        app.processEvents()
        if until is not None and until():
            return True
        time.sleep(0.02)
    return False


def state(win, tag):
    w = getattr(win, "worker", None)
    r = getattr(win, "_stream", None)
    print("%-10s worker=%-5s busy=%-5s src=%-6s stream=%-5s pkt=%-7s want=%-5s net_want=%s combo=%s"
          % (tag, w is not None, win.busy, getattr(win, "_src", "?"),
             r is not None, getattr(r, "packets", 0) if r else "-",
             getattr(win, "_net_want", "-"), getattr(win, "_net_want", "-"),
             win.cmb_src.currentData()))


def main(argv):
    port = argv[1] if len(argv) > 1 else "COM4"
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.show()
    win.show_page("live")

    win.cmb_src.blockSignals(True)
    win.cmb_src.setCurrentIndex(0)      # 网口
    win.cmb_src.blockSignals(False)

    # 第一次连接
    win.connect_to(port)
    ok = pump(app, 8.0, lambda: win.worker is not None and win.worker.connected)
    state(win, "连上 1")
    pump(app, 14.0, lambda: getattr(win, "_stream", None) is not None
         and win._stream.packets > 500)
    state(win, "流起 1")

    # 断开
    win.disconnect_port()
    pump(app, 2.0)
    state(win, "断开后")

    # 再连接
    win.connect_to(port)
    ok = pump(app, 8.0, lambda: win.worker is not None and win.worker.connected)
    state(win, "连上 2")
    pump(app, 16.0, lambda: getattr(win, "_stream", None) is not None
         and win._stream.packets > 500)
    state(win, "流起 2")

    r = getattr(win, "_stream", None)
    print("[结果] 第二次流 %s 包数=%s"
          % ("起来了" if (r is not None and r.packets > 500) else "没起来",
             getattr(r, "packets", 0) if r else 0))
    win.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
