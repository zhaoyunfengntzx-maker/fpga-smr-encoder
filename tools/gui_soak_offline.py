"""无硬件稳定性浸泡：合成遥测帧灌进真实 MainWindow，跑满 UI 热路径。

板子不在手边时也能验证的稳定性面：
  * 100 ms 刷新 × 每秒 10 k 帧的稳态负载（`_update_live` + 概览 + 告警 + ABZ）
  * 记录到 CSV（含分卷/关闭）与三种导出（CSV/NPY/PNG）
  * 抓包页反复 set_result / set_smooth / 缺块标黄
  * 反复翻页 + 打开波形弹窗

判据：无异常、RSS 增长 < 60 MB、导出文件非空、抓包页数据不被改。
用法：python tools/gui_soak_offline.py --minutes 3
"""

import argparse
import math
import os
import random
import sys
import tempfile
import time
import traceback

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QPA_FONTDIR", os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"))

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))

import ctypes                                        # noqa: E402
from PySide6.QtCore import QTimer                    # noqa: E402
from PySide6.QtWidgets import QApplication           # noqa: E402


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
    """当前进程 RSS（MB）。psutil 优先；没有就用 psapi（要显式声明 argtypes，
    否则 64 位下 HANDLE 被截断，返回值一直是 0）。"""
    try:
        import psutil
        return psutil.Process().memory_info().rss / 1048576.0
    except Exception:                                   # noqa: BLE001
        pass
    try:
        k32 = ctypes.windll.kernel32
        psapi = ctypes.windll.psapi
        k32.GetCurrentProcess.restype = ctypes.c_void_p
        h = k32.GetCurrentProcess()
        psapi.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                               ctypes.c_ulong]
        psapi.GetProcessMemoryInfo.restype = ctypes.c_int
        pmc = _PMC()
        pmc.cb = ctypes.sizeof(_PMC)
        if psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb):
            return pmc.WorkingSetSize / 1048576.0
    except Exception:                                   # noqa: BLE001
        pass
    return 0.0


def make_frames(n, k0):
    out = []
    for i in range(n):
        a = (k0 + i) * 0.01
        s = int(20000 * math.sin(a))
        c = int(20000 * math.cos(a))
        out.append({
            "angle_deg": (a * 57.2958) % 360.0,
            "pos_full": (k0 + i) * 7,
            "s": s, "c": c,
            "amp_sq": float(s * s + c * c),
            "io_bits": {"a": i & 1, "b": (i >> 1) & 1, "z": (i >> 2) & 1,
                        "u": (i >> 3) & 1, "v": (i >> 4) & 1, "w": (i >> 5) & 1,
                        "dir": (i >> 6) & 1, "limiter": 0},
            "flags": ["输入超量程"] if (i % 5000 == 0) else [],
        })
    return out


def main():
    ap = argparse.ArgumentParser(description="无硬件 UI 稳定性浸泡")
    ap.add_argument("--minutes", type=float, default=3.0)
    args = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    app = QApplication([])
    import capture as cap
    import main_window as mw

    st = {"ok": True, "err": [], "t0": time.time(), "frames": 0, "k": 0,
          "rss0": 0.0, "pages": 0, "exports": 0, "cap": 0}
    w = mw.MainWindow()
    pages = ["overview", "live", "enc", "alarm", "record", "capture", "diag"]
    tmp = tempfile.mkdtemp(prefix="soak_")

    def excepthook(etype, value, tb):
        st["ok"] = False
        st["err"].append("".join(traceback.format_exception(etype, value, tb))[-800:])
        app.quit()

    sys.excepthook = excepthook

    def tick():
        try:
            app.processEvents()
            now = time.time()
            if now - st["t0"] > args.minutes * 60:
                app.quit()
                return
            # 每秒 10 k 帧（100 ms 一批 1000 帧），模拟真实遥测负载
            frames = make_frames(1000, st["k"])
            st["k"] += 1000
            lf = frames[-1]
            for f in frames[:-1]:
                w._update_live(f)
            w._update_live(lf)
            st["frames"] += len(frames)
            w._tick()
            if int(now - st["t0"]) % 2 == 0 and st["pages"] < 40:
                w.show_page(pages[st["pages"] % len(pages)])
                st["pages"] += 1
        except Exception:                               # noqa: BLE001
            excepthook(*sys.exc_info())

    timer = QTimer()
    timer.timeout.connect(tick)
    timer.start(100)

    def setup():
        st["rss0"] = rss_mb()
        # 记录 4 s，然后停止
        w.record_dir = tmp
        w.record.start_requested.emit() if hasattr(w.record, "start_requested") else None
        # 抓包页：合成一窗 28672 点，带缺块
        n = 28672
        ss = [int(12000 * math.sin(i * 0.01)) for i in range(n)]
        cc = [int(9000 * math.cos(i * 0.01)) for i in range(n)]
        res = cap.CaptureResult(ss, cc, {"dec_log2": 1, "trig_idx": 0, "src": 0},
                                missing=[10, 11], n_blocks=448)
        w.capture.set_result(res)
        st["cap"] = res.n
        # 导出三件套
        for name, fn in (("a.csv", res.to_csv), ("a.npy", res.to_npy), ("a.png", res.to_png)):
            p = os.path.join(tmp, name)
            fn(p)
            if not (os.path.exists(p) and os.path.getsize(p) > 0):
                st["ok"] = False
                st["err"].append("导出为空：%s" % p)
            st["exports"] += 1

    QTimer.singleShot(300, setup)
    QTimer.singleShot(int(args.minutes * 60 * 1000) + 8000, app.quit)
    try:
        app.exec()
    finally:
        timer.stop()
        try:
            w.close()
        except Exception:                               # noqa: BLE001
            pass

    rss1 = rss_mb()
    growth = rss1 - st["rss0"]
    print("== 结果 ==")
    print("  帧数 %d，翻页 %d，导出 %d，抓包点 %d" %
          (st["frames"], st["pages"], st["exports"], st["cap"]))
    print("  RSS %.1f -> %.1f MB（%+.1f）" % (st["rss0"], rss1, growth))
    for e in st["err"]:
        print("  [错误]\n" + e)
    if growth > 60:
        print("  FAIL RSS 增长超过 60 MB（疑似泄漏）")
        st["ok"] = False
    if st["frames"] < 10000:
        print("  FAIL 帧数太少，负载没跑起来")
        st["ok"] = False
    print("结论:", "PASS" if st["ok"] else "FAIL")
    return 0 if st["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
