"""上位机稳定性浸泡测试（offscreen 驱动真实 MainWindow，连真板）。

覆盖真实使用里最容易出问题的组合路径：
  * 重复抓包（每次都要复位 busy、清结果、重选端口、重写 0x070C）
  * 连续流反复开/停（每轮都要停线程、关 socket、让板子停发）
  * 断开/重连串口（线程与队列要收干净，不能越连越多）
  * 空闲时反复翻页（定时器/绘图不能越画越慢、内存不能一直涨）

全程记录 RSS，末了比较首尾；任何 Python 异常、总线忙卡死、按钮状态不对都判 FAIL。

用法：
    python tools/gui_soak.py --port COM6 --captures 20 --streams 6 --reconnects 3
"""

import argparse
import ctypes
import os
import sys
import time
import traceback

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QPA_FONTDIR", os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"))

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))

from PySide6.QtCore import QTimer                      # noqa: E402
from PySide6.QtWidgets import QApplication             # noqa: E402


class _PMC(ctypes.Structure):
    _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t)]


def rss_mb():
    # psutil 优先；没有就 psapi（必须声明 argtypes，64 位下 HANDLE 不声明会被截断成 32 位，
    # 调用悄悄失败返回 0 —— 2026-10-22 在 gui_soak_offline 上踩过一次）。
    try:
        import psutil  # noqa: PLC0415

        return psutil.Process().memory_info().rss / 1048576.0
    except Exception:                                   # noqa: BLE001
        pass
    try:
        pmc = _PMC()
        pmc.cb = ctypes.sizeof(_PMC)
        kernel32 = ctypes.windll.kernel32
        psapi = ctypes.windll.psapi
        kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        psapi.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                               ctypes.c_ulong]
        psapi.GetProcessMemoryInfo.restype = ctypes.c_int
        h = kernel32.GetCurrentProcess()
        ok = psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb)
        return pmc.WorkingSetSize / 1048576.0 if ok else 0.0
    except Exception:                                   # noqa: BLE001
        return 0.0


def main():
    ap = argparse.ArgumentParser(description="上位机稳定性浸泡测试")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--captures", type=int, default=20)
    ap.add_argument("--streams", type=int, default=6)
    ap.add_argument("--stream-seconds", type=float, default=2.5)
    ap.add_argument("--reconnects", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=600.0)
    args = ap.parse_args()

    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    app = QApplication([])
    import capture as cap_mod                          # noqa: E402
    import main_window as mw                           # noqa: E402

    st = {"phase": "init", "t0": time.time(), "t": 0.0, "ok": True,
          "notes": [], "errors": [], "rss0": 0.0, "cap": 0,
          "stream": 0, "reconn": 0, "pages": 0, "page_i": 0}
    w = mw.MainWindow()
    pages = ["overview", "live", "enc", "alarm", "record", "capture", "diag"]

    def note(msg):
        st["notes"].append(msg)

    def fail(msg):
        st["ok"] = False
        st["notes"].append("FAIL " + msg)
        app.quit()

    def exception_hook(etype, value, tb):
        st["ok"] = False
        st["errors"].append("".join(traceback.format_exception(etype, value, tb))[-900:])
        app.quit()

    sys.excepthook = exception_hook

    def start_capture():
        st["t"] = time.time()
        w.capture.set_smooth(0)
        w._on_capture_requested({"src": 0, "dec_log2": 1, "length": 28672,
                                 "trig": 0, "level": 0, "pre": 1024,
                                 "transport": "udp"})

    def next_phase():
        app.quit()

    def tick():
        try:
            app.processEvents()
            now = time.time()
            if now - st["t0"] > args.timeout:
                fail("总超时，停在 %s（rss %.1f MB）" % (st["phase"], rss_mb()))
                return
            if st["phase"] == "init":
                w.connect_to(args.port)
                st["phase"] = "connect"
                st["t"] = now
                return
            if st["phase"] == "connect":
                if w.worker is not None and w.worker.connected:
                    st["rss0"] = rss_mb()
                    note("连接成功，起始 RSS %.1f MB" % st["rss0"])
                    st["phase"] = "capture"
                    start_capture()
                elif now - st["t"] > 15:
                    fail("串口连接超时")
                return
            if st["phase"] == "capture":
                res = w.capture.result()
                if res is not None and not w.busy and w.capture.btn_cap.text() == "抓一次":
                    st["cap"] += 1
                    miss = len(getattr(res, "missing", []) or [])
                    if res.n != 28672:
                        fail("第 %d 次抓包点数 %d" % (st["cap"], res.n))
                        return
                    if st["cap"] % 5 == 0 or miss:
                        note("抓包 #%d: %d 点 缺块 %d RSS %.1f MB"
                             % (st["cap"], res.n, miss, rss_mb()))
                    if st["cap"] >= args.captures:
                        st["phase"] = "stream"
                        st["t"] = now
                        w._on_capture_requested({"src": 0, "dec_log2": 2,
                                                 "length": 28672, "trig": 0,
                                                 "level": 0, "pre": 1024,
                                                 "transport": "stream"})
                        return
                    start_capture()
                elif now - st["t"] > 25:
                    fail("第 %d 次抓包超时（busy=%s 摘要=%s）"
                         % (st["cap"] + 1, w.busy, w.capture.lab_sum.text()[:60]))
                return
            if st["phase"] == "stream":
                if w._stream is not None and now - st["t"] > args.stream_seconds:
                    r = w._stream
                    st["stream"] += 1
                    note("流 #%d: %d 包 %.1f MSPS 丢 %d RSS %.1f MB"
                         % (st["stream"], r.packets, r.rate_sps / 1e6, r.lost, rss_mb()))
                    if r.packets < 100:
                        fail("连续流包太少：%d" % r.packets)
                        return
                    w._on_capture_requested({"src": 0, "dec_log2": 2, "length": 28672,
                                             "trig": 0, "level": 0, "pre": 1024,
                                             "transport": "stream"})
                    st["phase"] = "stream_stop"
                    st["t"] = now
                elif now - st["t"] > 25:
                    fail("连续流没起来")
                return
            if st["phase"] == "stream_stop":
                if now - st["t"] > 0.8 and w.capture.btn_cap.text() == "抓一次":
                    if st["stream"] >= args.streams:
                        st["phase"] = "reconnect"
                        st["t"] = now
                        w.disconnect_port()
                        return
                    st["t"] = now
                    w._on_capture_requested({"src": 0, "dec_log2": 2, "length": 28672,
                                             "trig": 0, "level": 0, "pre": 1024,
                                             "transport": "stream"})
                    st["phase"] = "stream"
                elif now - st["t"] > 10:
                    fail("停止连续流后按钮没复位：%s" % w.capture.btn_cap.text())
                return
            if st["phase"] == "reconnect":
                if w.worker is None:
                    st["reconn"] += 1
                    if st["reconn"] > args.reconnects:
                        st["phase"] = "pages"
                        st["t"] = now
                        return
                    w.connect_to(args.port)
                    st["phase"] = "reconnect_wait"
                    st["t"] = now
                return
            if st["phase"] == "reconnect_wait":
                if w.worker is not None and w.worker.connected:
                    note("重连 #%d 成功 RSS %.1f MB" % (st["reconn"], rss_mb()))
                    w.disconnect_port()
                    st["t"] = now
                    # ★ 回 reconnect 相位：那里会 +1 并决定"再连一次"还是"进翻页"。
                    #   原来成功后留在 reconnect_wait，下一拍 worker 已是 None，
                    #   15 s 后必判「重连超时」——2026-10-23 上板浸泡就是这么误报的。
                    st["phase"] = "reconnect"
                elif now - st["t"] > 15:
                    fail("重连 #%d 超时" % st["reconn"])
                return
            if st["phase"] == "pages":
                if now - st["t"] > 0.05:
                    w.show_page(pages[st["page_i"] % len(pages)])
                    st["page_i"] += 1
                    st["pages"] += 1
                    st["t"] = now
                    if st["pages"] >= len(pages) * 4:
                        note("翻页 %d 次完成 RSS %.1f MB" % (st["pages"], rss_mb()))
                        next_phase()
                return
        except Exception:                               # noqa: BLE001
            exception_hook(*sys.exc_info())

    timer = QTimer()
    timer.timeout.connect(tick)
    timer.start(120)
    QTimer.singleShot(int(args.timeout * 1000) + 5000, app.quit)
    app.exec()
    timer.stop()

    try:
        if w._stream is not None:
            w._stop_stream()
    except Exception:                                   # noqa: BLE001
        pass
    try:
        if w.worker is not None:
            w.worker.stop()
    except Exception:                                   # noqa: BLE001
        pass

    rss1 = rss_mb()
    print("== 结果 ==")
    for n in st["notes"]:
        print("  " + n)
    for e in st["errors"]:
        print("  [异常]\n" + e)
    growth = rss1 - st["rss0"]
    print("  RSS: %.1f -> %.1f MB（%+.1f）" % (st["rss0"], rss1, growth))
    if growth > 80:
        st["ok"] = False
        print("  FAIL RSS 增长超过 80 MB（疑似泄漏）")
    print("结论:", "PASS" if st["ok"] else "FAIL")
    return 0 if st["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
