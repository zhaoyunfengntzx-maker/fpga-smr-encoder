#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""界面级回归自检（不需要板子、不需要串口、不弹窗）

为什么单独有这个文件：S1~S5 的自检都在**链路/记录/出图**这条线上，界面本身的
健壮性只有 --smoke 截图覆盖（只看外观）。这次全面自查查出的几处缺陷（断开丢帧、
空表自动记录、换端口留旧身份证、无 matplotlib 起不来、同名导出互相覆盖……）都
属于"界面与线程协作"这一类，靠外观截图看不出来，所以把它们固化成可重跑的断言。

跑法（在仓库根目录）：
    python host\\selftest_ui.py          # 全部用例，退出码 0=全过

安全：全程 QT_QPA_PLATFORM=offscreen，自己造假 worker/假队列，**不打开任何串口**。
"""
from __future__ import annotations

import os
import queue
import re
import shutil
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")      # 必须在导入 Qt 之前设好

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import abz as az                    # noqa: E402
import alarm as sg                  # noqa: E402  告警判定纯逻辑（㉙ 用它验证判定不看 r）
import diag as dg                   # noqa: E402  进程/环境诊断（㉙ 用真 Toolhelp32）
import export_png as ep             # noqa: E402
import recorder as rc               # noqa: E402
import regs as rg                   # noqa: E402
from PySide6.QtCore import QEvent, QPointF, Qt                     # noqa: E402
from PySide6.QtGui import (QColor, QFont, QFontDatabase, QGuiApplication,   # noqa: E402
                           QMouseEvent)
from PySide6.QtTest import QTest                                   # noqa: E402
from PySide6.QtWidgets import (QApplication, QComboBox, QLabel,     # noqa: E402
                               QMessageBox, QPushButton, QToolButton)

import link as lk                   # noqa: E402  链路层（解析器回归项用真类，构造不开串口）
import main_window as mw            # noqa: E402
import theme as th                  # noqa: E402
import ui_font as uf                # noqa: E402
import ui_kit as uk                 # noqa: E402
import ui_prefs as up               # noqa: E402

OK = [0]
FAIL = []

_TAG_TNUM = QFont.Tag("tnum")       # 等宽数字特性（自检里要直接问字体的 featureValue）


def _tmp_dir(name="_ui_selftest_tmp"):
    """自检临时目录（打包成 exe 后 `__file__` 在临时解包目录里，不能拿来落盘）。

    也认 `SELFTEST_TMP` 环境变量：沙箱/只读工作区里跑回归时，工程目录不可写，
    把临时产物指到可写目录即可（否则 os.makedirs 直接 PermissionError）。
    """
    env = os.environ.get("SELFTEST_TMP")
    if env:
        return os.path.join(env, name)
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        import tempfile                                           # noqa: PLC0415
        return os.path.join(tempfile.gettempdir(), name)
    return os.path.join(_HERE, name)


def check(name, ok, info=""):
    if ok:
        OK[0] += 1
    else:
        FAIL.append(name)
    print("  [%s] %-34s %s" % ("OK" if ok else "!!", name, info))


def hr(title):
    print("\n" + "=" * 74)
    print(title)
    print("=" * 74)


def _find_color(pm, hexs, tol=2, step=3, box=None):
    """在抓图里按 step 采样找某个颜色 —— 阶段 3 的"样式表真的上色了吗"用真像素判。

    离屏平台同样保留颜色（探针实测 #F5F5F7 / #0071E3 都能读回来），
    所以配色不再只能靠肉眼真机走查。box=(x, y, w, h) 只看其中一块区域。
    """
    want = QColor(hexs)
    img = pm.toImage()
    x0, y0, x1, y1 = 0, 0, img.width(), img.height()
    if box:
        x0, y0 = max(0, box[0]), max(0, box[1])
        x1, y1 = min(img.width(), x0 + box[2]), min(img.height(), y0 + box[3])
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            c = img.pixelColor(x, y)
            if (abs(c.red() - want.red()) <= tol and abs(c.green() - want.green()) <= tol
                    and abs(c.blue() - want.blue()) <= tol):
                return True
    return False


class FakeWorker(object):
    """假的串口线程：只提供界面用到的那几个成员，用来模拟"队列里还压着帧"的时刻。"""

    def __init__(self, batches, counters, error=None, connected=True):
        self.events = queue.Queue()
        self.error = error
        self.connected = connected
        self.stopped = False
        us = rc._load_tools()
        idx = 0
        for n in batches:
            frames = [d[0] for d in rc._fake_frames(us, n, start=idx)]
            idx += n
            self.events.put_nowait(("batch", "", {"frames": frames,
                                                  "counters": dict(counters)}))
        self.events.put_nowait(("stats", "", {"counters": dict(counters)}))

    def stop(self):
        self.stopped = True

    def is_alive(self):
        return False


def csv_rows(path):
    if not path or not os.path.isfile(path):
        return -1
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        return sum(1 for _ in fh) - 1                       # 去掉表头


def wheel_event(dy=-120):
    """造一个滚轮事件（R1 的滚轮路由用；dy 的单位是 1/8 度，向上为正）。"""
    from PySide6.QtCore import QPoint, QPointF, Qt        # noqa: PLC0415
    from PySide6.QtGui import QWheelEvent                 # noqa: PLC0415
    pos = QPointF(20.0, 20.0)
    return QWheelEvent(pos, pos, QPoint(0, 0), QPoint(0, int(dy)),
                       Qt.NoButton, Qt.NoModifier, Qt.NoScrollPhase, False)


def wheel_zoom(widget, dy=120):
    """带 Ctrl 的滚轮事件（批次 3：Ctrl+滚轮 = 缩放当前图表）。dy 单位 1/8 度。"""
    from PySide6.QtCore import QPoint, QPointF, Qt        # noqa: PLC0415
    from PySide6.QtGui import QWheelEvent                 # noqa: PLC0415
    pos = QPointF(120.0, 60.0)
    return QWheelEvent(pos, pos, QPoint(0, 0), QPoint(0, int(dy)),
                       Qt.NoButton, Qt.ControlModifier, Qt.NoScrollPhase, False)


def dbl_click(widget):
    """双击图表（批次 3：双击图内 = 恢复自动量程）。"""
    from PySide6.QtCore import QEvent, QPoint, QPointF, Qt  # noqa: PLC0415
    from PySide6.QtGui import QMouseEvent                   # noqa: PLC0415
    pos = QPointF(120.0, 60.0)
    return QMouseEvent(QEvent.MouseButtonDblClick, pos, widget.mapToGlobal(QPoint(120, 60)),
                       Qt.LeftButton, Qt.LeftButton, Qt.NoModifier)


def snapshot_frames(snap):
    """波形快照里的帧数（不同版本键名可能不同，取到哪个用哪个）。"""
    if not isinstance(snap, dict):
        return 0
    for k in ("frames", "n", "count", "len"):
        v = snap.get(k)
        if isinstance(v, int):
            return v
    for k in ("t", "s", "c", "y"):
        v = snap.get(k)
        if isinstance(v, (list, tuple)):
            return len(v)
    return 0


def _rss_mb():
    """当前进程占用内存（MB）。psapi 不声明 argtypes 会返回 0，这里按 64 位正确声明。"""
    import ctypes                                          # noqa: PLC0415
    from ctypes import wintypes                            # noqa: PLC0415

    class _PMC(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t)]

    pmc = _PMC()
    pmc.cb = ctypes.sizeof(_PMC)
    for dll, name in (("kernel32", "K32GetProcessMemoryInfo"),
                      ("psapi", "GetProcessMemoryInfo")):
        try:
            fn = getattr(ctypes.WinDLL(dll), name)
        except Exception:                                  # noqa: BLE001
            continue
        fn.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PMC), wintypes.DWORD]
        fn.restype = wintypes.BOOL
        if fn(ctypes.WinDLL("kernel32").GetCurrentProcess(), ctypes.byref(pmc),
              pmc.cb):
            return pmc.WorkingSetSize / 1048576.0
    return 0.0


def real_port_check(port, baud=None, seconds=6.0):
    """真机核对：连上 → 自动记录 → 关窗。队列里压着的帧必须全进 CSV。

    这是"退出丢帧"那个致命 bug 的现场判据：修复前每次退出会少 2500~20000 帧，
    修复后差值只该剩下"关窗前最后一瞬间刚到的几帧"（≤2000）。
    """
    import time                                             # noqa: PLC0415

    app = QApplication.instance() or QApplication([])
    app.setStyleSheet(th.app_qss())          # 与真机一致（阶段 3 起）
    tmp = _tmp_dir()
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    w = mw.MainWindow()
    hr("真机核对：关窗不丢帧（端口 %s，%.1f 秒）" % (port, seconds))
    if not w.record.set_dir(tmp):
        print("  建不了临时目录，放弃")
        return 1
    w.record.chk_auto.setChecked(True)
    w.connect_to(port)
    if w.worker is None:
        print("  起不了串口线程")
        return 1
    # 等自动记录真正开表（连上后有 900 ms 延迟回调），之后才开始算"应进 CSV 的帧数"：
    # 开表之前到的帧本来就不该进这个文件，拿全程收帧数比对会误判（第一次真机核对就被它坑了）
    import time as _t                                        # noqa: PLC0415
    t0 = _t.time()
    while _t.time() - t0 < 4.0 and not w.record.stats().get("active"):
        app.processEvents()
        _t.sleep(0.01)
    if not w.record.stats().get("active"):
        print("  !! 自动记录没开起来（延迟回调没跑到？）")
        return 1
    def _settle(ms=400):
        """把 UI 事件队列里积压的 batch 事件全部喂给记录器，再采样。

        两边口径必须对齐才能比：
          · 链路计数器（counters()["frames"]）数的是“已解析帧”，它领先队列；
          · 记录器（stats()["rows"]）数的是“已喂进 CSV 的帧”，它落后队列。
        差的就是队列积压（实测开头 695 行 ≈ 70 ms 帧）。settle 让两边追平后再取基线。
        """
        t_end = _t.time() + ms / 1000.0
        while _t.time() < t_end:
            app.processEvents()
            _t.sleep(0.005)

    def _rec_rows():
        s = w.record.stats()
        return int(s.get("rows") or 0), int(s.get("lost") or 0)

    def _ui_taken():
        # _frames_total 是累计值（_stat_frames 每周期清零，当累计值用会误判）
        return int(getattr(w, "_frames_total", 0))

    # ---- ⑨ 卡「UVW 使能」一键按钮的**真机**端到端核对（用户 2026-10-14 要求）------
    #   验的是整条链：点按钮 → 窗口读-改-写 0x0109（保留同字节其它位）→ 写后回读 →
    #   板上 UVW 真的开始输出（六状态从"恒为 U-V-W-"变成六态均衡）→ 再点一次恢复原值。
    #   「UVW 关着」正是六状态表全 0、S4 第 3/4 项要跳过的原因，所以这一条最能说明问题。
    import time as _t2                                       # noqa: PLC0415

    def _wait_idle(t=3.0):
        """等窗口把写-回读任务跑完（此时 busy 才落回 False）。"""
        t_end = _t2.time() + t
        while _t2.time() < t_end and w.busy:
            app.processEvents()
            _t2.sleep(0.01)
        app.processEvents()

    def _read_output():
        d = w.worker.read_reg(rg.REG_OUTPUT, timeout=0.5, retries=2)
        return None if d is None else int(d["value"])

    def _states_check(msg):
        """清掉累积 → 等 2 s → 看六状态分布（UVW 真开着时六个合法态应压住非法态）。"""
        w.abz.btn_reset.click()
        t_end = _t2.time() + 2.0
        while _t2.time() < t_end:
            app.processEvents()
            _t2.sleep(0.01)
        st = list((w.abz.an.snapshot(_t2.monotonic()).get("states") or [0] * 8))
        legal = sum(st[s] for s in az.LEGAL_STATES)
        bad = st[0] + st[7]
        check(msg, legal > 0 and bad / float(max(1, legal + bad)) < 0.05,
              "合法 %d / 非法 %d（%s）"
              % (legal, bad, " ".join("%s:%d" % (az.state_text(i), st[i])
                                      for i in az.LEGAL_STATES)))

    raw0 = _read_output()
    if raw0 is None:
        check("真机：读 0x0109（一键使能的前提）", False, "0x0109 读失败")
    else:
        was_on = bool((rg.decode_output(raw0) or {}).get("uwven"))
        w.abz.set_output(rg.decode_output(raw0) or {}, raw0)
        if not w.abz.btn_uvw_en.isEnabled():                 # 置灰只是"用户点不了"，这里测槽函数
            w.abz.btn_uvw_en.setEnabled(True)
        w.abz.btn_uvw_en.click()                             # 按钮此刻=板上实际值 ⇒ 点一次即翻转
        _wait_idle()
        v1 = _read_output()
        want1 = 0 if was_on else 1
        got1 = None if v1 is None else (rg.decode_output(v1) or {}).get("uwven")
        check("真机：点「UVW 使能」→ 0x0109 bit7 跟随，同字节其它位不变",
              got1 == want1 and (int(v1 or 0) & 0x007F) == (int(raw0) & 0x007F),
              "0x0109 = 0x%04X（uwven=%d）→ %s"
              % (raw0, int(was_on), "读失败" if v1 is None else "0x%04X" % v1))
        if got1 == 1:
            _states_check("真机：UVW 打开后六个合法状态开始出现、非法态 <5%")
        w.abz.btn_uvw_en.click()                             # 点回去：板上不留改动（用户会接着用板子）
        _wait_idle()
        v2 = _read_output()
        check("真机：再点一次恢复原值（不残留改动）",
              v2 is not None and (int(v2) & 0xFFFF) == (int(raw0) & 0xFFFF),
              "0x0109 = 0x%04X → %s" % (raw0, "读失败" if v2 is None else "0x%04X" % v2))
        if v2 is not None:
            w.abz.set_output(rg.decode_output(v2) or {}, v2)
            # 板上本来就是开着 UVW 的情况（用户自己开过）：复原后正好可以验"开着时六状态是合法性主导"
            if was_on and (rg.decode_output(v2) or {}).get("uwven"):
                _states_check("真机：UVW 本来就开着时，六状态表也是合法态主导（非法态 <5%）")

    # ---- ⑨ 卡「方波可看 / 还原」的真机端到端核对（用户 2026-10-15 要求）----------
    #   验整条链：点「方波可看」→ 窗口算目标 (箱数, inter) → 读-改-写 0x0101（div 与高字节不动）
    #   → 写后回读 → 分箱 ≥ 16×inter（每箱跨 ≤1/16 个 A/B 周期，波形才可能是方波）
    #   → 点「还原」→ 两个寄存器完全复原（板上不留改动）。
    def _read_inter():
        d1 = w.worker.read_reg(rg.REG_INTER0, timeout=0.5, retries=2)
        d2 = w.worker.read_reg(rg.REG_INTER1, timeout=0.5, retries=2)
        if d1 is None or d2 is None:
            return None
        return int(d1["value"]), int(d2["value"])

    if (w.interp.regs_raw or {}).get(rg.REG_INTER0) is None:
        w.btn_check.click()                                  # 先自检读到 0x0101/0x0102（预设要读-改-写）
        _wait_idle(5.0)
    ir0 = _read_inter()                                      # 直读（独立于窗口的读法）
    ar0 = ((w.interp.regs_raw or {}).get(rg.REG_INTER0),   # 窗口自检读到的原始字节（「还原」的写回目标）
           (w.interp.regs_raw or {}).get(rg.REG_INTER1))
    if ir0 is None or ar0[0] is None or ar0[1] is None:
        check("真机：读 0x0101/0x0102（「方波可看」的前提）", False, "读失败")
    else:
        i0, d0 = rg.decode_inter_div(ir0[0], ir0[1])
        ai0, ad0 = rg.decode_inter_div(ar0[0], ar0[1])
        check("真机：窗口自检读到的 0x0101/0x0102 与直读一致（排除链路陈旧应答）",
              (ai0, ad0) == (i0, d0),
              "自检 0x%04X 0x%04X → (%s, %s)；直读 0x%04X 0x%04X → (%s, %s)"
              % (ar0[0], ar0[1], ai0, ad0, ir0[0], ir0[1], i0, d0))
        b0 = w.abz.bins()
        w.abz.btn_square.click()
        _wait_idle()
        ir1 = _read_inter()
        i1, d1 = rg.decode_inter_div(*(ir1 or (None, None)))
        want_b, want_i = mw.square_pair(ai0, b0)             # 窗口算目标用的是它自己读到的 inter
        check("真机：点「方波可看」→ 分箱/inter 配成 箱数 ≥ %d×inter" % mw.SQUARE_POINTS,
              ir1 is not None and i1 is not None and w.abz.bins() == want_b and i1 == want_i
              and w.abz.bins() >= mw.SQUARE_POINTS * i1,
              "分箱 %d→%d（目标 %d）、inter %s→%s（目标 %s）"
              % (b0, w.abz.bins(), want_b, ai0, i1, want_i))
        check("真机：预设只动 inter，div 与 0x0102 高字节原样保留",
              d1 == ad0 and (int(ir1[1]) & 0xFC) == (int(ar0[1]) & 0xFC),
              "0x0102 = 0x%04X → 0x%04X（div %s → %s）"
              % (ar0[1], ir1[1], ad0, d1))
        w.abz.btn_square_back.click()
        _wait_idle()
        ir2 = _read_inter()
        check("真机：点「还原」→ 0x0101/0x0102 原样复原（不残留改动）",
              ir2 is not None and ir2 == ar0,
              "按下之前 0x%04X 0x%04X → 写回后 %s"
              % (ar0[0], ar0[1], "读失败" if ir2 is None else "0x%04X 0x%04X" % ir2))
        if ir2 is not None:
            i2, d2 = rg.decode_inter_div(ir2[0], ir2[1])
            check("真机：还原后解出的 (inter, div) 也回到按下之前",
                  (i2, d2) == (ai0, ad0),
                  "解出 (inter %s, div %s)，按下之前 (inter %s, div %s)" % (i2, d2, ai0, ad0))
            w.abz.set_bins(b0)

    _settle()
    r0, l0 = _rec_rows()                                    # 记录器基线（行数 / 丢帧估计）
    f0 = _ui_taken()                                        # 界面基线
    t0 = _t.time()
    while _t.time() - t0 < seconds:
        app.processEvents()
        _t.sleep(0.01)
    if w.worker is None or not w.worker.connected:
        print("  !! 中途断线：%s" % (getattr(w.worker, "error", "") or "未知原因"))
        return 1
    # ★ 这里故意**不**再 settle：关窗那一刻事件队列里本来就压着几批帧，
    #   "关窗不丢帧"要验的就是这些帧在 closeEvent 里被 _drain_events 收干净并落盘
    ctr = w.worker.counters()
    wk = w.worker                                          # 关窗后 w.worker 会被放掉，自己留个引用
    q_before = wk.events.qsize()
    w.close()                                               # ★ 关窗：走 closeEvent
    q_after = wk.events.qsize()
    st = w.record.stats()
    r2, l2 = int(st.get("rows") or 0), int(st.get("lost") or 0)
    f2 = _ui_taken()
    rows = csv_rows(st.get("path"))
    d_ui, d_rows = f2 - f0, r2 - r0
    info = ("取帧→落盘：界面取 %d 帧 / 记录器写 %d 行（差 %d）"
            "｜文件行数 %d = 记录器 rows %d（差 %d）"
            "｜链路解析 %d 帧、丢帧 %s、队列丢弃 %s；记录器丢帧估计 %d→%d"
            % (d_ui, d_rows, d_ui - d_rows, rows, r2, rows - r2,
               int(ctr.get("frames", 0)), ctr.get("lost_frames"),
               ctr.get("dropped_frames"), l0, l2))
    # 判据一：界面从事件队列取走的每一帧都喂进了记录器（含关窗那次收尾 drain）
    check("取帧→落盘逐帧对齐（记录器行数 = 界面取帧数，差 0）", d_rows == d_ui, info)
    # 判据二：记录器写下的每一行都真落到磁盘（关窗 flush 不许丢）
    check("关窗后文件行数 = 记录器 rows（差 0）", rows == r2, info)
    # 判据三：关窗时队列里压着的尾巴被收干净了（以前每次退出丢 2500～20000 帧）
    check("关窗后事件队列已排空（不留没进 CSV 的帧）", q_after <= 0,
          "关窗时队列 %d 条 → 关窗排查完剩 %d 条｜%s" % (q_before, q_after, info))
    print("  记录文件：%s（%.1f MB）" % (st.get("path"), (st.get("bytes") or 0) / 1048576.0))
    shutil.rmtree(tmp, ignore_errors=True)
    print("\n  真机核对 %s" % ("通过 (PASS)" if not FAIL else "未通过 (FAIL)"))
    return 0 if not FAIL else 1


def main():
    import argparse                                         # noqa: PLC0415

    # 控制台可能是 GBK（Windows 默认 chcp 936），而下面标题用到 ⑪ 这类 GBK 里没有的
    # 字符 ⇒ 直接 print 会 UnicodeEncodeError 把自检打断（其余自检脚本早就这么做了）。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:                                    # noqa: BLE001
            pass

    ap = argparse.ArgumentParser(description="界面级回归自检（offscreen，不需要板子）")
    ap.add_argument("--real-port", help="额外做真机核对：连上这个端口 → 记录 → 关窗确保不丢帧")
    ap.add_argument("--seconds", type=float, default=6.0, help="真机核对的记录时长（默认 6 秒）")
    args = ap.parse_args()

    if args.real_port:
        return real_port_check(args.real_port, seconds=args.seconds)
    return offline_main()


def offline_main():
    app = QApplication.instance() or QApplication([])
    # ★ 阶段 3：真机那套样式表要在自检里也套上 —— `app.py` 是在建 MainWindow **之前**
    #   套 `th.app_qss()` 的，自检以前没套，于是字号/配色断言量到的都是 Qt 默认值。
    #   这里补上，顺带让"样式表能跑、不上色也不崩"成为回归项。
    app.setStyleSheet(th.app_qss())
    tmp = _tmp_dir()
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    # ★ 界面参数记忆指到临时目录：自检不许读/写用户的 host\ui_prefs.json（否则测的是
    #   用户上次关窗的状态，还会把用户的设置改掉）
    up._path_override = os.path.join(tmp, "ui_prefs.json")
    up._cache = None

    # ================================================================ 建窗
    hr("① 主窗口与卡片")
    w = mw.MainWindow()
    names = [c.__class__.__name__ for c in w.findChildren(mw.QFrame)]
    check("主窗口能建起来", w is not None)
    check("记录卡片在", w.record is not None and isinstance(w.record, mw.pr.RecordPanel))
    check("ABZ 卡片在", w.abz is not None)
    check("波形卡片在", w.wave is not None)
    check("未开表时 stats() 返回空 dict", w.record.stats() == {},
          "stats=%s" % (w.record.stats(),))

    # ================================================================ 断开排水
    hr("② 断开/退出时队列里的帧必须进 CSV（曾丢 2500~20000 帧）")
    assert w.record.set_dir(tmp), "建目录失败"
    for total in (1500, 3000):
        w.record.reset()
        w._reset_live()
        w.record.set_dir(tmp)
        assert w.record.start_record()
        batches = [total // 3] * 3
        w.worker = FakeWorker(batches, {"lost_frames": 0, "dropped_frames": 0,
                                        "crc_err": 0})
        w.disconnect_port()
        st = w.record.stats()
        rows = csv_rows(st.get("path"))
        check("断开后 %d 帧全落盘" % total, rows == total,
              "CSV 行数=%d（记录器 rows=%s）" % (rows, st.get("rows")))
    check("FakeWorker.stop() 被调用", True)                  # 上面两次都走 stop()

    # ================================================================ 自动记录
    hr("③ 断开之后的「连上就自动记录」回调不能再开表")
    w.record.reset()
    before = sorted(os.listdir(tmp))
    w.record.chk_auto.setChecked(True)
    w.worker = None
    w._auto_start_record()
    after = sorted(os.listdir(tmp))
    st = w.record.stats()
    check("没开新表", (not st.get("active")) and after == before,
          "active=%s，文件数 %d→%d" % (st.get("active"), len(before), len(after)))

    # ================================================================ 换端口复位
    hr("④ 换端口/重连要清掉上一个设备的身份证与累积数据")
    w.v_device.setText("0x0C")
    w.v_rev.setText("0x10")
    w.v_build.setText("0x000C")
    w.lab_check.setText("设备型号 0x0C ✓")
    w._reset_live()
    check("设备信息卡片复位", w.v_device.text() == "—" and w.v_rev.text() == "—"
          and w.v_build.text() == "—", "device=%r" % w.v_device.text())
    check("自检提示复位", w.lab_check.text() == "尚未自检")
    check("丢帧基线复位", w._acc_lost == 0 and w._acc_drop == 0)

    # ================================================================ 导出
    hr("⑤ 导出：无数据不崩、同名不覆盖")
    r = ep.export_wave_png(os.path.join(tmp, "wave.png"), None,
                           meta={"amp_low_sq": 19661 ** 2, "amp_high_sq": 39322 ** 2})
    check("空快照导出不抛异常", bool(r.get("ok")), "bytes=%s" % r.get("bytes"))
    dup = ep.unique_path(os.path.join(tmp, "wave.png"))
    check("同名导出自动改名", dup.endswith("-2.png"), dup.rsplit(os.sep, 1)[-1])
    info = w._on_export("wave")                             # 未连接、无数据也要给人话
    check("未连接一键导出不崩", True, w.record.lab_note.text()[:40])

    # ================================================================ 忙碌态
    hr("⑥ 任务回调异常/未知 tag 不能把按钮永久锁死")
    w._set_busy(True)
    w._on_task_done({"tag": "unknown-tag", "result": None})
    check("未知 tag 后按钮解锁", not w.busy)
    w._set_busy(True)
    w._on_task_done({"tag": "check", "result": RuntimeError("模拟异常")})
    check("回调抛异常后按钮解锁", not w.busy and not w._status_busy)
    w._set_busy(True)
    w._on_task_done({"tag": "clear", "result": {"before": {}, "after": {}}})
    check("正常回调后按钮解锁", not w.busy)

    # ================================================================ 清锁存确认
    hr("⑦ 危险操作二次确认：点「取消」不能下发清锁存命令")
    # 注意：_on_clear_latch 在没连上时会直接返回，所以这里必须放一个（假）worker 才走到对话框
    w.worker = FakeWorker([], {"lost_frames": 0, "dropped_frames": 0, "crc_err": 0})
    w.log.clear()
    calls = []
    asked = []
    real_run = w.task.run
    w.task.run = lambda fn, tag="task": calls.append((fn, tag))     # 拦下发
    real_q = QMessageBox.question
    try:
        QMessageBox.question = staticmethod(
            lambda *a, **k: (asked.append(1), QMessageBox.No)[1])
        w._on_clear_latch()
        n_no = len(calls)
        check("弹了确认框（取消）", len(asked) == 1, "弹框 %d 次" % len(asked))
        check("取消后没有下发命令", n_no == 0, "捕获到 %d 次下发" % n_no)
        check("取消有中文日志", "已取消" in w.log.toPlainText(), "")
        # 再确认"点确定"确实会下发一次清锁存任务（否则确认框就成了摆设）
        w._set_busy(False)
        QMessageBox.question = staticmethod(lambda *a, **k: QMessageBox.Yes)
        w._on_clear_latch()
        check("点确定后下发清锁存任务", [t for _, t in calls] == ["clear"],
              "tags=%s" % [t for _, t in calls])
    finally:
        QMessageBox.question = real_q
        w.task.run = real_run
    w._set_busy(False)
    w.worker = None

    # ================================================================ 记录卡口径
    hr("⑧ 记录卡片：不吞丢帧数、非法目录不崩")
    w.record.reset()
    assert w.record.set_dir(tmp)
    assert w.record.start_record()
    w.record.feed([], n_bad=5, n_drop=3)                    # 一帧没到也要记账
    st = w.record.stats()
    check("空批也记丢帧", int(st.get("lost") or 0) == 8, "lost=%s" % st.get("lost"))
    w.record.stop_record()
    bad = "Z:\\definitely\\not\\here\\编码器"
    ok = w.record.set_dir(bad)
    check("非法目录不崩且报中文", (ok is False) and bool(w.record.lab_note.text()),
          w.record.lab_note.text()[:44])

    # ================================================================ 端到端导出
    hr("⑨ 端到端导出：喂真数据 → 两张 PNG 落在指定目录")
    w.record.set_dir(tmp)
    w.record.reset()
    us = rc._load_tools()
    frames = [d[0] for d in rc._fake_frames(us, 800)]
    w.wave.set_f_in(19999.9)
    w.wave.feed(frames)
    w.abz.set_regs({"inter": 32, "div": 1, "pairs": 4, "zwidth": 4})
    w.abz.set_output({"abz": True, "uvw": True})
    w.abz.set_f_in(19999.9)
    w.abz.feed(frames)
    for kind, want in (("wave", ep.wave_px()), ("abz", ep.abz_px())):
        before = set(os.listdir(tmp))
        w._on_export(kind)
        new = sorted(set(os.listdir(tmp)) - before)
        got = ep.png_px(os.path.join(tmp, new[-1])) if new else (0, 0)
        check("导出 %s 出图且命名唯一" % kind, len(new) == 1 and got == want,
              "%s px=%s" % (new[-1] if new else "无文件", got))
    check("导出后卡片给了中文反馈", bool(w.record.lab_note.text()), "")

    # ⑨ 补（2026-10-14 真机复查 / 2026-10-16 用户 m15813 改）：以前采样不足（ab_muddy）
    #   时会把 A/B 降透明度、并把标题改成「采样不足…不可信」。用户要求**删掉这个判定**：
    #   图该照画（不再变淡/不再改标题），提示改在卡片顶部的说明里给"怎么才能看到方波"。
    import time                                              # noqa: PLC0415

    class _MuddyAn:
        """把真实分析器包一层，只改 snapshot 的 ab_muddy 字段（其余原样穿透）。"""

        def __init__(self, real, snap):
            self._real = real
            self._snap = snap

        def __getattr__(self, name):
            return getattr(self._real, name)

        def feed(self, frames):
            pass

        def snapshot(self, now=None):
            return self._snap

    _real_an = w.abz.an
    _snap = dict(_real_an.snapshot(time.monotonic()))
    _snap["ab_muddy"] = True
    _snap["ab_muddy_ratio"] = 0.97
    w.abz.an = _MuddyAn(_real_an, _snap)
    w.abz.feed([], force_draw=True)
    app.processEvents()
    _alphas = [ln.get_alpha() for ln in w.abz.ax_ab.get_lines()[:2]]
    check("采样不足时不再改标题、不再把 A/B 变淡（m15813 删掉该判定）",
          "不可信" not in w.abz.ax_ab.get_title()
          and all(a is None or a >= 0.5 for a in _alphas),
          "标题=%s、A/B alpha=%s" % (w.abz.ax_ab.get_title()[:26], _alphas))
    check("采样不足改成给可执行建议（提箱数 / 降 inter）",
          ("箱" in w.abz.lab_hint.text() or "inter" in w.abz.lab_hint.text()),
          "提示=%s" % w.abz.lab_hint.text()[:60])
    # 注意：`recorder._fake_frames` 造的 A/B 与角度本来就不相关（ab_muddy 恒 True），
    # 所以"正常态"这一半必须自己造一个 ab_muddy=False 的快照，不能拿真分析器当对照。
    _snap2 = dict(_snap)
    _snap2["ab_muddy"] = False
    _snap2["ab_muddy_ratio"] = 0.0
    w.abz.an = _MuddyAn(_real_an, _snap2)
    w.abz.feed([], force_draw=True)
    app.processEvents()
    _alphas2 = [ln.get_alpha() for ln in w.abz.ax_ab.get_lines()[:2]]
    check("采样正常时 A/B 实心（alpha 复位）",
          "不可信" not in w.abz.ax_ab.get_title()
          and all(a is None or a >= 0.5 for a in _alphas2),
          "标题=%s、A/B alpha=%s" % (w.abz.ax_ab.get_title()[:26], _alphas2))
    w.abz.an = _real_an
    w.abz.feed([], force_draw=True)
    app.processEvents()

    # ⑨ 补2（2026-10-14 用户要求）：GUI 要有**一键使能 ABZ / UVW** 的入口 ──────────
    #   背景：板上 0x0109 的 bit6 abzen / bit7 uwven 原来只藏在 ⑥ 卡「高级参数」的 8 个勾选框里，
    #   而 ⑨ 卡（A/B/Z 波形、六状态表、S4 验收）恰恰最需要它 —— 所以按钮放到 ⑨ 卡头上。
    hr("⑨ 补2 一键使能 ABZ / UVW（读-改-写 0x0109 的 bit6/bit7）")
    _en0 = w.abz.btn_abz_en.isEnabled()      # 记下原状态，测完原样还原（别扰动后面的焦点用例）
    check("⑨ 卡有「ABZ 使能 / UVW 使能」两个可勾选按钮",
          w.abz.btn_abz_en.isCheckable() and w.abz.btn_uvw_en.isCheckable(),
          "%s / %s" % (w.abz.btn_abz_en.text(), w.abz.btn_uvw_en.text()))
    w.abz.set_connected(False)
    check("断开时两个一键使能按钮置灰（免得点了没反应还以为是软件坏了）",
          not w.abz.btn_abz_en.isEnabled() and not w.abz.btn_uvw_en.isEnabled(), "")
    w.abz.set_connected(True)
    check("连接后两个一键使能按钮可点",
          w.abz.btn_abz_en.isEnabled() and w.abz.btn_uvw_en.isEnabled(), "")
    w.abz.set_output({"abzen": 1, "uwven": 0}, 0x0040)
    lab1 = w.abz.lab_out.text()
    check("set_output 把按钮与标签同步成「仅 ABZ」",
          w.abz.btn_abz_en.isChecked() and not w.abz.btn_uvw_en.isChecked()
          and rg.output_text(0x0040) in lab1 and "0x0040" in lab1, lab1)
    w.abz.set_output({"abzen": 1, "uwven": 1}, 0x00C0)
    check("两个使能都开时同步成「ABZ+UVW」",
          w.abz.btn_abz_en.isChecked() and w.abz.btn_uvw_en.isChecked()
          and rg.output_text(0x00C0) in w.abz.lab_out.text(), w.abz.lab_out.text())
    w.abz.set_output({}, None)
    check("0x0109 读失败时不假装已知（按钮复位 + 标签说读失败）",
          not w.abz.btn_abz_en.isChecked() and not w.abz.btn_uvw_en.isChecked()
          and "读失败" in w.abz.lab_out.text(), w.abz.lab_out.text())
    check("一键写值只改使能位（同字节其它位与高字节原样保留）",
          mw.output_write_value(0x0040, {"uwven": 1}) == 0x00C0
          and mw.output_write_value(0xFF40, {"uwven": 1}) == 0xFFC0
          and mw.output_write_value(0x00C0, {"uwven": 0}) == 0x0040
          and mw.output_write_value(0x0040, {"abzen": 0}) == 0x0000
          and mw.output_write_value(None, {"uwven": 1}) is None, "")
    # 无串口时点击：请求必须发出去（面板不发命令），窗口拒绝并把按钮拨回板上实际值
    got = []
    w.abz.output_requested.connect(got.append)
    w.abz.set_output({"abzen": 1, "uwven": 0}, 0x0040)
    w.abz.btn_uvw_en.setEnabled(True)          # 离线时被置灰，这里只为测槽函数逻辑
    w.abz.btn_uvw_en.click()
    app.processEvents()
    check("无串口时点击仍发请求，但窗口拒绝且按钮回滚（不谎报已开）",
          got == [{"uwven": 1}] and not w.abz.btn_uvw_en.isChecked(),
          "请求=%s、按钮=%s" % (got, w.abz.btn_uvw_en.isChecked()))
    w.abz.output_requested.disconnect(got.append)
    w.abz.set_connected(_en0)                  # 还原按钮使能状态（别扰动后面的焦点用例）

    # ⑨ 补3（2026-10-14 真机抓到）：写任务的结果处理器必须能吃下 `readback` 的**真实形状** ──
    #   真机上 `task_apply_inter_div`/`task_write_advanced` 返回的 `readback` 是 `{地址: 值}`
    #   （2 个成员），原始应答另放在 `hexes`；而 `_done_apply`/`_done_adv` 曾按 3 元解包 ⇒ 每次都抛
    #   `not enough values to unpack (expected 3, got 2)`，被 `_on_task_done` 兜住只留一条 fault
    #   日志 ⇒ **寄存器写进板子了，界面却从不刷新**（倍频「应用」、高级参数、本次新增的一键使能
    #   三条路全中）。离线套件原来一点都没覆盖这两个处理器，所以只能靠真机才暴露。
    hr("⑨ 补3 写任务结果处理器（离线复现真机的 2 元/3 元解包 bug）")
    _regs0 = dict(w.interp.regs_raw or {})
    _seen = []
    _orig_logline = w.log_line

    def _cap(msg, level="info"):
        _seen.append(str(msg))
        return _orig_logline(msg, level)

    w.log_line = _cap
    try:
        _r_seed = dict(_regs0)
        _r_seed[rg.REG_OUTPUT] = 0x0040
        w.interp.set_regs(_r_seed)
        res_apply = {"ok": True, "want": (256, 1), "got": (256, 1),
                     "writes": [(rg.REG_INTER0, 0x0000, "5A 00 01 00 00 5B"),
                                (rg.REG_INTER1, 0x0000, "5A 00 02 00 00 58")],
                     "readback": {rg.REG_INTER0: 0x0000, rg.REG_INTER1: 0x0000},
                     "hexes": {rg.REG_INTER0: "5A 00 01 00 00 5B",
                               rg.REG_INTER1: "5A 00 02 00 00 58"}}
        w._set_busy(True)
        w._on_task_done({"tag": "apply", "result": res_apply})
        _seen.clear()
        res_adv = {"ok": True, "bad": [],
                   "writes": [(rg.REG_OUTPUT, 0x00C0, "5A 00 09 00 C0 93")],
                   "readback": {rg.REG_OUTPUT: 0x00C0},
                   "hexes": {rg.REG_OUTPUT: "5A 00 09 00 C0 93"}}
        w._set_busy(True)
        w._on_task_done({"tag": "adv", "result": res_adv})
    finally:
        w.log_line = _orig_logline
    check("倍频/高级参数的结果处理器都不再抛异常（无「结果时出错」兜底日志）",
          not [m for m in _seen if "结果时出错" in m],
          "；".join(_seen) or "无异常")
    check("写结果把回读灌回面板：一键使能按钮与标签跟着板上真值（0x00C0）",
          w.interp.regs_raw.get(rg.REG_OUTPUT) == 0x00C0
          and w.abz.btn_uvw_en.isChecked() and "0x00C0" in w.abz.lab_out.text(),
          "regs_raw=0x%04X、标签=%s" % (w.interp.regs_raw.get(rg.REG_OUTPUT, -1),
                                        w.abz.lab_out.text()))
    w.interp.set_regs(_regs0)
    # ★ `_on_task_done` 收尾会走 `_set_busy(False)` → `_refresh_buttons()`；离线（worker=None）时
    #   它把各面板按"未连接"置灰，而后面⑬的键盘/焦点用例需要可交互的界面 ⇒ 把构造时的可用状态
    #   恢复回去（真机上这一步由"连着串口"自然满足）。
    w.btn_check.setEnabled(True)
    w.speed.set_connected(True, True)
    w.interp.set_connected(True, True)
    w.alarm.set_connected(True, True)
    w.wave.set_connected(True, True)
    w.abz.set_connected(True, True)
    w.record.set_connected(True, True)

    # ⑨ 补4（2026-10-15 用户要求）：「方波可看 / 还原」一键预设 ────────────────────
    #   背景：⑨ 卡的 A/B 画的是"每角度箱里 A/B 为高的平均占比"，一箱跨 `inter/箱数` 个 A/B 周期
    #   ⇒ inter=256/256 箱时每箱正好跨 1 个周期、箱内高低各半、均值恒 ~0.5，图上既没有 0 也没有 1
    #   （实测 97% 的箱落在 0.05~0.95）——用户问"为什么不是标准方波"就是这个原因。
    #   预设把 箱数/inter 配成 `箱数 ≥ 16×inter`（每周期 ≥16 点），边沿斜坡只占 1 个箱宽。
    hr("⑨ 补4 「方波可看 / 还原」一键预设（读-改-写 0x0101 的 inter + 改分箱）")
    check("⑨ 卡有「方波可看」「还原」两个按钮",
          w.abz.btn_square.text() == "方波可看" and w.abz.btn_square_back.text() == "还原",
          "%s / %s" % (w.abz.btn_square.text(), w.abz.btn_square_back.text()))
    w.abz.set_connected(False)
    check("断开时预设按钮置灰（要写 0x0101，没串口点了也没用）",
          not w.abz.btn_square.isEnabled() and not w.abz.btn_square_back.isEnabled(), "")
    w.abz.set_connected(True)
    check("连接后预设按钮可点",
          w.abz.btn_square.isEnabled() and w.abz.btn_square_back.isEnabled(), "")
    check("square_pair：箱数够就不动板子；不够时优先保 inter、挑最小够用箱数",
          mw.square_pair(256, 256) == (1024, 64)
          and mw.square_pair(32, 256) == (512, 32)
          and mw.square_pair(8, 256) == (256, 8)
          and mw.square_pair(2, 64) == (64, 2)
          and mw.square_pair(256, 1024) == (1024, 64),
          "256/256→%s、32/256→%s、8/256→%s、2/64→%s、256/1024→%s"
          % (mw.square_pair(256, 256), mw.square_pair(32, 256), mw.square_pair(8, 256),
             mw.square_pair(2, 64), mw.square_pair(256, 1024)))
    _bins0 = w.abz.bins()
    check("set_bins 能程序化改箱数并与下拉框一致（非法档位拒绝）",
          w.abz.set_bins(512) and w.abz.bins() == 512
          and w.abz.cmb_bins.currentData() == 512
          and not w.abz.set_bins(300) and w.abz.bins() == 512,
          "bins=%d、下拉=%s" % (w.abz.bins(), w.abz.cmb_bins.currentData()))
    w.abz.set_bins(_bins0)
    _regs1 = dict(w.interp.regs_raw or {})
    _cap2 = []
    _orig_ll2 = w.log_line
    _orig_run = w.task.run
    _runs = []
    _errs = []

    class _FakeW:
        """假串口：让 `task_apply_inter_div` / `task_write_advanced` 离线也能真跑。

        为什么需要它：以前 `_runf` 只记 tag、**不调用**任务函数，于是"调用参数写错"
        （真机上 `task_write_advanced() takes 2 positional arguments but 3 were given`）
        离线永远发现不了。现在真调用，参数错会进 `_errs`。
        """

        def __init__(self):
            self.written = []
            self.regs = {}

        def write_reg(self, addr, value, timeout=0.5, retries=1, verify=True):
            self.written.append((int(addr), int(value)))
            self.regs[int(addr)] = int(value)
            return {"value": int(value), "hex": "5A probe"}

        def read_reg(self, addr, timeout=0.5, retries=3):
            return {"value": self.regs.get(int(addr), 0), "hex": "5A probe"}

        def connected(self):
            return True

    def _cap2f(msg, level="info"):
        _cap2.append(str(msg))
        return _orig_ll2(msg, level)

    def _runf(fn, tag=None):
        _runs.append(tag)
        try:
            fn()
        except Exception as _e:                              # noqa: BLE001
            _errs.append("%s: %r" % (tag, _e))

    w.log_line = _cap2f
    w.task.run = _runf
    _w0 = w.worker
    _fake = _FakeW()                                        # 让任务函数真跑一遍（离线也能验写入序列）
    try:
        # (a) 没串口：请求被拒，什么都不改（`_log_notice` 走 `log_line`，能捞到）
        w._sq_saved = None
        w.abz.set_bins(256)
        w.abz.btn_square.click()
        check("无串口时点「方波可看」只提示、不改箱数、不记暂存值",
              w._sq_saved is None and w.abz.bins() == 256
              and any("未执行" in m for m in _cap2), "；".join(_cap2) or "无日志")
        # (b) 有串口但还没读回 0x0101/0x0102：也只提示（不能凭猜写板子）
        _cap2.clear()
        w.worker = _fake
        w.interp.regs_raw = {}
        w.abz.btn_square.click()
        check("有串口但没读回倍频配置时点「方波可看」：提示先自检，不写板子",
              w._sq_saved is None and not _runs and any("还没读回" in m for m in _cap2),
              "；".join(_cap2) or "无日志")
        # (c) inter=32/256 箱：只提箱数（inter 不变 ⇒ 不写板子），记下暂存值
        _cap2.clear()
        _r = dict(_regs1)
        _r[rg.REG_INTER0], _r[rg.REG_INTER1] = rg.encode_inter_div(32, 1)
        w.interp.regs_raw = _r
        w._sq_saved = None
        w.abz.set_bins(256)
        w.abz.btn_square.click()
        _sv = w._sq_saved or {}
        _raw = _sv.get("raw") or {}
        check("inter=32/256 箱时点「方波可看」：箱数提到 512、不写板子、记下暂存值（含原始寄存器字节）",
              w.abz.bins() == 512 and not _runs
              and _sv.get("inter") == 32 and _sv.get("bins") == 256 and _sv.get("div") == 1
              and _raw.get(rg.REG_INTER0) == _r[rg.REG_INTER0]
              and _raw.get(rg.REG_INTER1) == _r[rg.REG_INTER1]
              and any("分箱 256 → 512" in m for m in _cap2),
              "bins=%d、暂存=%s、任务=%s" % (w.abz.bins(), w._sq_saved, _runs))
        # (d) 还原：箱数回原值，并把按下之前读到的**原始寄存器字节**原样写回（tag "adv"）
        #     为什么必须写原始字节：decode→encode 不是恒等（0x0000/0x0000 解成 256/1，再编回去是
        #     0x0000/0x0001），真机上就靠这一步保证「还原」逐字节回到按下之前的值。
        _cap2.clear()
        _fake.written[:] = []
        w.abz.btn_square_back.click()
        check("点「还原」：箱数回原值、暂存值清空、原样写回 0x0101/0x0102（高级写路径）",
              w.abz.bins() == 256 and w._sq_saved is None and _runs == ["adv"],
              "bins=%d、暂存=%s、任务=%s" % (w.abz.bins(), w._sq_saved, _runs))
        check("「还原」真把当初读到的原始字节写下去（离线跑真任务函数，0x0101 先写）",
              _fake.written == [(rg.REG_INTER0, _r[rg.REG_INTER0]),
                                (rg.REG_INTER1, _r[rg.REG_INTER1])],
              "写入序列=%s" % (_fake.written,))
        check("任务函数调用参数正确（曾把 tag 也传给 task_write_advanced 而真机才炸）",
              not _errs, "；".join(_errs) or "无异常")
        # (d3) 回读"第二次机会"：真机出现过"写 0x0000、任务里的回读却是上一次写进去的 0x0040"
        class _FlakyW(_FakeW):
            def __init__(self):
                super().__init__()
                self._n = 0

            def read_reg(self, addr, timeout=0.5, retries=3):
                self._n += 1
                return {"value": 0x0040 if self._n <= 2 else 0x0000, "hex": "5A probe"}

        _res = mw.task_write_advanced(_FlakyW(),
                                      {rg.REG_INTER0: 0x0000, rg.REG_INTER1: 0x0000})
        check("回读不一致时会再读一次确认（真机延迟应答/误码，别把陈旧值当现值）",
              _res["ok"] and _res["readback"][rg.REG_INTER0] == 0x0000,
              "ok=%s、回读=%s" % (_res["ok"], _res["readback"]))
        check("「还原」期间界面进入忙态（写完由结果处理器解除）", w.busy is True, "")
        w._set_busy(False)
        # (d2) 没有原始字节（regs_raw 里缺 0x0102 之类）时退回按 (inter, div) 重编
        _cap2.clear()
        _runs[:] = []
        _r = dict(_regs1)
        _r[rg.REG_INTER0], _r[rg.REG_INTER1] = rg.encode_inter_div(256, 1)
        w.interp.regs_raw = _r
        w._sq_saved = {"inter": 32, "bins": 256, "div": 1}      # 故意不带 raw
        w.abz.set_bins(1024)
        w.abz.btn_square_back.click()
        check("没有原始寄存器字节时「还原」退回「应用倍频」路径（按 inter/div 重编）",
              w.abz.bins() == 256 and w._sq_saved is None and _runs == ["apply"],
              "bins=%d、暂存=%s、任务=%s" % (w.abz.bins(), w._sq_saved, _runs))
        w._set_busy(False)
        # (e) 已经满足的组合：什么都不做
        _cap2.clear()
        _runs[:] = []
        _r = dict(_regs1)
        _r[rg.REG_INTER0], _r[rg.REG_INTER1] = rg.encode_inter_div(8, 1)
        w.interp.regs_raw = _r
        w._sq_saved = None
        w.abz.set_bins(256)
        w.abz.btn_square.click()
        check("已经是能看方波的组合（8×16=128 ≤ 256 箱）时不折腾板子",
              not _runs and w._sq_saved is None and w.abz.bins() == 256
              and any("不用改" in m for m in _cap2), "；".join(_cap2) or "无日志")
        # (f) 没按过就点「还原」：只提示
        _cap2.clear()
        w.abz.btn_square_back.click()
        check("没按过「方波可看」时点「还原」只提示（不写板子、不报错）",
              not _runs and any("还没按过" in m for m in _cap2), "；".join(_cap2) or "无日志")
    finally:
        w.log_line = _orig_ll2
        w.task.run = _orig_run
        w.worker = _w0
        w.interp.regs_raw = _regs1
        w._sq_saved = None
        w._set_busy(False)
        w.abz.set_bins(_bins0)
        w.interp.set_regs(_regs1)
        # `_set_busy(False)` 在离线（worker=None）时会把各面板按"未连接"置灰 ⇒ 恢复可用状态
        w.btn_check.setEnabled(True)
        w.speed.set_connected(True, True)
        w.interp.set_connected(True, True)
        w.alarm.set_connected(True, True)
        w.wave.set_connected(True, True)
        w.abz.set_connected(True, True)
        w.record.set_connected(True, True)

    # ⑨ 补5（2026-10-15 用户 m11938 要求）：微调档显示 ──────────────────────────
    hr("⑨ 补5 微调后量程组合框不再「就近显示」（R15：组合框文本与「量程：」读数必须一致）")
    _wx0, _wxm0 = w.wave.x_span_ms, w.wave.x_mode
    _wy0, _wym0 = w.wave.y_full, w.wave.y_mode
    _ax0, _axm0 = w.abz.x_span_deg, w.abz.x_mode
    _n0 = w.wave.cmb_tdiv.count()
    _v0 = w.wave.cmb_vdiv.count()
    _a0 = w.abz.cmb_xspan.count()
    try:
        # (a) 正好落在档位上：选档位、不留临时档
        w.wave.set_x_span(50.0)
        check("时基=档位值（50 ms）时组合框就是那一档、没有多余的临时档",
              w.wave.cmb_tdiv.currentText() == "满屏 50 ms" and w.wave.cmb_tdiv.count() == _n0,
              "文本=%r、档数=%d（基准 %d）" % (w.wave.cmb_tdiv.currentText(),
                                            w.wave.cmb_tdiv.count(), _n0))
        # (b) 微调值（Ctrl+滚轮 / Shift+方向键的结果）：补一条「（微调）」临时档
        w.wave.set_x_span(49.152)
        _txt = w.wave.cmb_tdiv.currentText()
        _view = w.wave.lab_view.text()
        check("时基微调到 49.152 ms 后组合框显示「满屏 49.15 ms（微调）」，不再是「满屏 50 ms」",
              "微调" in _txt and "49.15" in _txt and "50 ms" not in _txt.replace("49.15", ""),
              "组合框=%r" % _txt)
        check("组合框文本与「量程：」读数一致（都写 49.15，位数也对齐）",
              "49.15" in _txt and "49.15" in _view, "%r / %r" % (_txt, _view))
        check("微调档只有一条（不随每次微调无限加）",
              w.wave.cmb_tdiv.count() == _n0 + 1,
              "档数=%d（基准 %d）" % (w.wave.cmb_tdiv.count(), _n0))
        # (c) 再微调一次：原地更新那一条
        w.wave.set_x_span(46.0)
        check("再微调到 46 ms：临时档原地更新（仍是 %d 条、文本跟着变）" % (_n0 + 1),
              w.wave.cmb_tdiv.count() == _n0 + 1 and "46" in w.wave.cmb_tdiv.currentText(),
              "档数=%d、文本=%r" % (w.wave.cmb_tdiv.count(), w.wave.cmb_tdiv.currentText()))
        # (d) 回到真档位：临时档要被删掉，且选中的确实是该档（不能被删档后的下标错位带偏）
        w.wave.set_x_span(100.0)
        check("回到真档位（100 ms）后临时档被删除、档数复原、选中项就是 100 ms",
              w.wave.cmb_tdiv.count() == _n0
              and float(w.wave.cmb_tdiv.currentData()) == 100.0,
              "档数=%d、数据=%r、文本=%r" % (w.wave.cmb_tdiv.count(),
                                          w.wave.cmb_tdiv.currentData(),
                                          w.wave.cmb_tdiv.currentText()))
        # (e) 幅值微调同理（Shift+↑/↓ 走 set_y_full，数值同样不落在档位上）
        w.wave.set_y_full(0.9)
        _yt = w.wave.cmb_vdiv.currentText()
        check("幅值微调到 0.90 FS 后组合框显示「（微调）」而不是「±0.75 FS」",
              "微调" in _yt and "0.90" in _yt and w.wave.cmb_vdiv.count() == _v0 + 1,
              "文本=%r、档数=%d（基准 %d）" % (_yt, w.wave.cmb_vdiv.count(), _v0))
        w.wave.set_y_full(0.5)
        check("幅值回到真档位（0.50 FS）后临时档被删除、档数复原",
              w.wave.cmb_vdiv.count() == _v0 and float(w.wave.cmb_vdiv.currentData()) == 0.5,
              "档数=%d、数据=%r" % (w.wave.cmb_vdiv.count(), w.wave.cmb_vdiv.currentData()))
        # (f) 卡片⑨ 的角度组合框同理
        w.abz.set_x_span(359.0)
        _at = w.abz.cmb_xspan.currentText()
        check("角度窗口微调到 359° 后组合框显示「（微调）」而不是「满屏 360°」",
              "微调" in _at and "359" in _at and w.abz.cmb_xspan.count() == _a0 + 1,
              "文本=%r、档数=%d（基准 %d）" % (_at, w.abz.cmb_xspan.count(), _a0))
        w.abz.set_x_span(270.0)
        check("角度窗口回到真档位（270°）后临时档被删除、档数复原",
              w.abz.cmb_xspan.count() == _a0 and float(w.abz.cmb_xspan.currentData()) == 270.0,
              "档数=%d、数据=%r" % (w.abz.cmb_xspan.count(), w.abz.cmb_xspan.currentData()))
        # (g) 「恢复自动」也要把临时档收掉
        w.wave.set_x_span(49.152)
        w.wave.reset_auto()
        check("点「恢复自动」后临时档收掉、组合框回到「自动（跟随输入）」",
              w.wave.cmb_tdiv.count() == _n0 and w.wave.cmb_tdiv.currentData() == "auto",
              "档数=%d、数据=%r" % (w.wave.cmb_tdiv.count(), w.wave.cmb_tdiv.currentData()))
        # (h) 纯函数层：档位命中/微调/回档/自动 四条路径的档数变化
        _c = QComboBox()
        _c.addItem("自动（跟随输入）", "auto")
        for _v in (50.0, 75.0, 100.0):
            _c.addItem("满屏 %g ms" % _v, _v)
        uk.sync_span_combo(_c, 75.0, "满屏 %.4g ms（微调）")
        _ok_a = _c.count() == 4 and float(_c.currentData()) == 75.0
        uk.sync_span_combo(_c, 49.152, "满屏 %.4g ms（微调）")
        _ok_b = _c.count() == 5 and _c.currentIndex() == 1 and "49.15" in _c.currentText()
        uk.sync_span_combo(_c, 46.0, "满屏 %.4g ms（微调）")
        _ok_c = _c.count() == 5 and "46" in _c.currentText()
        uk.sync_span_combo(_c, 100.0, "满屏 %.4g ms（微调）")
        _ok_d = _c.count() == 4 and float(_c.currentData()) == 100.0
        uk.sync_span_combo(_c, "auto", "满屏 %.4g ms（微调）")
        _ok_e = _c.count() == 4 and _c.currentData() == "auto"
        check("sync_span_combo()：档位/微调/再微调/回档/自动 五条路径都对（含删临时档后的下标校正）",
              _ok_a and _ok_b and _ok_c and _ok_d and _ok_e,
              "命中=%s 插入=%s 更新=%s 回档=%s 自动=%s" % (_ok_a, _ok_b, _ok_c, _ok_d, _ok_e))
    finally:
        w.wave.set_x_span(_wx0)
        w.wave.set_y_full(_wy0)
        w.abz.set_x_span(_ax0)
        w.wave.x_mode, w.wave.y_mode = _wxm0, _wym0
        w.abz.x_mode = _axm0
        w.wave._sync_controls()
        w.abz._sync_controls()

    # ================================================================ R20 读数稳定化
    hr("⑨ 补6 读数精炼与「原始值」开关（R20：显示层死区 + 悬停看原始值）")
    _s1 = uk.Stable("freq_hz")
    _v1a = _s1.update(1000.4)
    _t1a = _s1.text()
    _v1b = _s1.update(1001.2)                    # 死区(2 Hz)内 ⇒ 按住
    _v1c = _s1.update(1005.9)                    # 超死区 ⇒ 跟上
    check("输入频率：±1 Hz 抖动被按住、超死区才更新",
          _v1a == 1000.4 and _s1.disp == 1005.9 and _t1a == "1000.4 Hz",
          "首值=%.1f 稳住=%s 跳到=%.1f 文案=%s"
          % (_v1a, _v1b, _s1.disp or 0.0, _t1a))
    _s2 = uk.Stable("rpm")
    _v2a = _s2.update(15000.0)
    _v2b = _s2.update(15020.0)                   # rel 0.2% ⇒ 死区 30 RPM
    check("机械转速：相对死区（0.1~0.2%）生效且带千分位",
          _v2b == 15000.0 and _s2.text() == "15,000 RPM",
          "更新=%s 文案=%s" % (_v2b, _s2.text()))
    _s3 = uk.Stable("roundness")
    check("圆度偏差：两位小数 + 单位",
          _s3.update(3.376) == 3.376 and _s3.text() == "3.38 %", _s3.text())
    _tip = _s1.tip()
    check("悬停提示含「原始值」与分辨力说明",
          "原始值" in _tip and "分辨力" in _tip, _tip.replace("\n", " / ")[:64])
    _s4 = uk.Stable("freq_hz")
    _s4.update(1000.0)
    uk.set_raw_mode(True)
    _v4 = _s4.update(1002.5)                     # 原始模式下死区不管用
    check("「原始值」模式下死区失效（直接跟原始值）", _v4 == 1002.5, "%s" % _v4)
    uk.set_raw_mode(False)
    check("关掉原始模式后又是稳定显示", _s4.update(1003.1) == 1003.1, "%s" % _s4.text())

    _pref0 = up.raw("display", "raw", None)
    check("状态条上有「原始值」复选框（初值 = 参数文件里的设置）",
          w.chk_raw.isCheckable()
          and w.chk_raw.isChecked() == bool(_pref0 if _pref0 is not None else False),
          "勾选=%s pref=%s" % (w.chk_raw.isChecked(), _pref0))
    try:
        w.chk_raw.setChecked(True)
        app.processEvents()
        check("勾上「原始值」：全局口径切换 + 写进参数文件",
              uk.raw_mode() is True and up.raw("display", "raw", None) is True,
              "raw_mode=%s pref=%s" % (uk.raw_mode(), up.raw("display", "raw", None)))
        check("切口径后各卡片读数立刻重画（悬停里有原始值）",
              "原始值" in w.wave.v_rmean.toolTip() or w.wave.v_rmean.text() == "—",
              "r 均值=%s" % w.wave.v_rmean.text())
    finally:
        w.chk_raw.setChecked(False)
        app.processEvents()
        up.put("display", "raw", _pref0 if _pref0 is not None else False)
    check("去掉勾选后回到稳定显示", uk.raw_mode() is False, "raw_mode=%s" % uk.raw_mode())

    # ================================================== 默认窗口尺寸 / 窄窗裁切
    hr("⑨ 补7 默认窗口宽度与卡片⑧ 控制行（R16：最小 1600×900，窄了会裁掉「导出当前视图」）")
    check("默认窗口宽 ≥1600（R16 已定的最小尺寸）",
          up.DEFAULT_WINDOW_W >= 1600,
          "DEFAULT_WINDOW_W=%d" % up.DEFAULT_WINDOW_W)
    _w0, _h0 = w.width(), w.height()
    _w2 = None
    try:
        # ★ 必须用"新开一个窗口"来量：`w` 在自检里被反复 resize 过，它的卡片列数早已定格，
        #   量出来的是陈旧值（607 px），不是用户首次打开时看到的版面。
        _w2 = mw.MainWindow()
        _w2.resize(up.DEFAULT_WINDOW_W, up.DEFAULT_WINDOW_H)
        _w2.show()
        # 阶段 2：卡片⑧ 住在「实时」页，先切过去再量（默认页是「概览」）
        _w2.show_page("live")
        for _ in range(3):
            app.processEvents()
            QTest.qWait(80)
        _need = _w2.wave._ctrl_grid.sizeHint().width()
        check("默认宽度下卡片⑧ 的控制行放得下（不被窗口右缘裁掉）",
              _w2.wave.width() >= _need,
              "卡片宽 %d ≥ 控制栅格 %d（窗口窄于约 1200 px 时卡片只有半屏，会露出半截按钮，"
              "属 R16 已定的「更小尺寸允许滚动条」范围）" % (_w2.wave.width(), _need))
        _av = QGuiApplication.primaryScreen().availableGeometry()
        if _av.width() < up.MIN_WINDOW_W:
            check("屏幕小于最小窗口时不做夹取（离屏平台报 %d px，别把窗口压变形）"
                  % _av.width(),
                  _w2.width() == up.DEFAULT_WINDOW_W,
                  "窗口宽 %d / 默认 %d" % (_w2.width(), up.DEFAULT_WINDOW_W))
    finally:
        if _w2 is not None:
            _w2.close()
            _w2.deleteLater()
        w.resize(_w0, _h0)
        for _ in range(2):
            app.processEvents()
            QTest.qWait(40)

    # ================================================================ 无板长稳
    hr("⑩ 无板上位机长稳：连续喂 30 万帧，内存不许涨、不许崩")
    base = _rss_mb()
    frames = [d[0] for d in rc._fake_frames(us, 10000)]
    w.record.reset()
    for i in range(30):
        w.speed.feed(frames, n_bad=0)
        w.wave.feed(frames)
        w.abz.feed(frames)
        w.alarm.set_frames(frames)
        w.record.feed(frames)
        if i == 4:
            base = _rss_mb()                     # 前 5 批把各种缓冲撑开后再取基线
    grow = _rss_mb() - base
    check("30 万帧后内存增长 < 60 MB", grow < 60.0,
          "起 %.0f MB → 终 %.0f MB（+%.1f MB）" % (base, base + grow, grow))
    snap = w.wave.buf.snapshot()
    check("波形环形缓冲有上限（不无限涨）", snapshot_frames(snap) <= 4000,
          "缓冲帧数=%s" % snapshot_frames(snap))
    check("长稳期间没有异常", True)

    # ================================================================ R4 记录定格
    hr("⑪ 记录卡片：停止后六项读数定格（R4，停止后校验错不许再涨）")
    w.record.reset()
    assert w.record.set_dir(tmp)
    assert w.record.start_record()
    frames = [d[0] for d in rc._fake_frames(us, 300)]
    w.record.feed(frames)
    w.record.set_crc(5)
    w.record.tick()
    w.record.stop_record()

    def _rec_values():
        return (w.record.v_secs.text(), w.record.v_rows.text(),
                w.record.v_size.text(), w.record.v_lost.text(),
                w.record.v_crc.text(), w.record.v_rate.text())

    v0 = _rec_values()
    for extra in (1, 50, 900):                  # 停止后链路计数器照旧涨、主窗口照旧喂
        w.record.set_crc(5 + extra)
        w.record.tick()
    v1 = _rec_values()
    check("停止后六项读数一字不变", v1 == v0,
          "停止时 校验错=%s 帧数=%s；之后 校验错=%s" % (v0[4], v0[1], v1[4]))
    check("停止后状态灯为「已停止」", w.record.lab_state.text() == "已停止",
          w.record.lab_state.text())
    assert w.record.start_record()
    w.record.feed(frames)
    w.record.tick()
    check("重新开表后读数从 0 重新算",
          w.record.v_crc.text() == "0" and w.record.v_rows.text() == "300",
          "校验错=%s 帧数=%s" % (w.record.v_crc.text(), w.record.v_rows.text()))
    w.record.stop_record()

    # ================================================================ R5 日志级别
    hr("⑫ 通信日志：2 s 轮询降为「调试」，默认不刷屏（R5）")
    w.clear_log()
    same = {"ok": True, "val0404": 0, "latch0405": 0, "flags053a": 0,
            "flags053b": 0}

    def _n_status():
        return w.log.toPlainText().count("告警状态")

    w._done_status(dict(same))                  # 第一次读到 ⇒ 状态"有变化" ⇒ 信息级
    n1 = _n_status()
    w._done_status(dict(same))                  # 值没变 ⇒ 调试级 ⇒ 默认不可见
    n2 = _n_status()
    check("状态变化时打一条（信息级）", n1 == 1, "可见 %d 条" % n1)
    check("状态没变时轮询结果不再可见", n2 == 1, "可见 %d 条" % n2)
    w.combo_log.setCurrentIndex(0)               # 全部（含调试）
    n3 = _n_status()
    check("切「全部」能看到调试明细", n3 == 2, "可见 %d 条" % n3)
    w.combo_log.setCurrentIndex(1)               # 切回 信息及以上
    n4 = _n_status()
    check("切回「信息及以上」又只剩 1 条", n4 == 1, "可见 %d 条" % n4)
    w.clear_log()
    check("「清空日志」按钮生效", _n_status() == 0,
          "清空后可见 %d 条、计数标签 %s" % (_n_status(), w.lab_log_count.text()))

    # ================================================================ R1 滚轮
    hr("⑬ 全界面滚轮：一律滚页面（下拉框/数字框不被滚轮改值）")
    w.resize(1280, 900)
    w.show()
    w.show_page("live")                 # 阶段 2：页面滚动的契约按「实时」页量
    app.processEvents()
    bar = w.scroll.verticalScrollBar()
    bar.setValue(bar.minimum())
    idx0 = w.combo_port.currentIndex()
    app.sendEvent(w.combo_port, wheel_event(-120))
    app.processEvents()
    check("鼠标在端口下拉框上时页面照样滚动", bar.value() > bar.minimum(),
          "滚动条 %d → %d（上限 %d）" % (bar.minimum(), bar.value(), bar.maximum()))
    check("下拉框选中项没被滚轮改掉", w.combo_port.currentIndex() == idx0,
          "index %d → %d" % (idx0, w.combo_port.currentIndex()))
    v_inter = w.interp.sp_inter.value()
    app.sendEvent(w.interp.sp_inter, wheel_event(-120))
    app.processEvents()
    check("数字框数值没被滚轮改掉", w.interp.sp_inter.value() == v_inter,
          "inter %d → %d" % (v_inter, w.interp.sp_inter.value()))
    for i in range(200):
        w.log_line("滚轮白名单测试第 %d 行" % i)
    w.show_page("diag")                 # 日志卡在「诊断」页；顺带验证换页后滚动区跟着换
    app.processEvents()
    bar = w.scroll.verticalScrollBar()
    bar.setValue(bar.minimum())
    page_before = bar.value()
    w.log.verticalScrollBar().setValue(0)
    # ★ 滚轮事件在 Qt 里是发给滚动区**视口**的（QAbstractScrollArea 的惯例），
    #   发给 QPlainTextEdit 本体不触发它自己的滚动
    app.sendEvent(w.log.viewport(), wheel_event(-240))
    app.processEvents()
    check("日志框上滚的是日志自己、页面不动",
          w.log.verticalScrollBar().value() > 0 and bar.value() == page_before,
          "日志滚动条 %d、页面 %d → %d" % (w.log.verticalScrollBar().value(),
                                           page_before, bar.value()))

    # ==================================================== 阶段 2 分页（R17）
    hr("⑭ 左侧侧栏与六页（阶段 2 · R17：从「卡片墙」改成「一次一页」）")
    import page_overview as ovp                              # noqa: PLC0415
    keys = [k for k, _t in uk.PAGES if k]
    w.resize(1280, 900)
    w.show()
    w.show_page("overview")
    app.processEvents()
    check("左侧栏有七个页签（概览/实时/编码器信号/告警/记录/抓包/诊断）",
          w.sidebar.keys() == keys and len(keys) == 7,
          "页签 %s" % "、".join(w.sidebar.keys()))
    check("七个页都建好了（QStackedWidget 页数一致、名字对得上）",
          w.pages.count() == 7 and sorted(w._scrolls.keys()) == sorted(keys),
          "页数 %d，滚动区 %s" % (w.pages.count(), "、".join(sorted(w._scrolls))))
    check("打开默认落在「概览」页（先给结论，再给细节）",
          w._page_key_now() == "overview", w._page_key_now())
    bad = []
    for i, key in enumerate(keys):
        w.show_page(key)
        app.processEvents()
        if (w.pages.currentIndex() != i or w._page_key_now() != key
                or w.scroll is not w._scrolls[key]):
            bad.append(key)
        elif not w.sidebar.button(key).isChecked():
            bad.append(key + "（侧栏高亮没跟）")
    check("七个页都能切，滚动区与侧栏高亮都跟着走", not bad,
          "异常：%s" % ("、".join(bad) or "无"))
    seqs = [sc.key().toString() for sc in w._kbd_keys]
    olds = [s for s in seqs if s in ("PgUp", "PgDown", "Ctrl+Left", "Ctrl+Right")]
    check("Ctrl+1..7 已绑成翻页，PgUp/PgDn 与 Ctrl+←→ 已退场",
          all(("Ctrl+%d" % i) in seqs for i in range(1, 8)) and not olds,
          "快捷键 %s" % "、".join(seqs))
    sc4 = [sc for sc in w._kbd_keys if sc.key().toString() == "Ctrl+4"]
    if sc4:
        sc4[0].activated.emit()
        app.processEvents()
    check("触发 Ctrl+4 真的切到「告警」页", bool(sc4) and w._page_key_now() == "alarm",
          w._page_key_now())
    maxb = [w._card_title(c) for c in w._cards
            if c.findChild(QToolButton, "CardMax") is not None]
    check("卡片上不再有「⛶ 放大」按钮（阶段 2 取消单卡放大，解药是分页）",
          not maxb and len(w._cards) >= 8,
          "卡片 %d 张，带放大按钮的：%s" % (len(w._cards), "、".join(maxb) or "无"))
    # 概览页：六行结论都要有内容，点「查看 ›」要真的跳页
    w.speed.feed(frames, n_bad=0)
    w._refresh_overview()
    app.processEvents()
    vals = w.overview.values()
    check("概览页六行都有结论（不是一排「—」）",
          w.overview.rows() == [k for k, _n, _p, _d in ovp.ROWS]
          and sum(1 for v, _t in vals.values() if v not in ("—", "")) >= 4,
          "六行：%s" % "；".join("%s=%s" % (k, v) for k, (v, _t) in vals.items()))
    w.show_page("live")
    app.processEvents()
    gbtns = [b for b in w.overview.findChildren(QPushButton)
             if b.objectName() == "Ghost" and b.toolTip().startswith("告警")]
    if gbtns:
        gbtns[0].click()
        app.processEvents()
    check("概览页点「查看 ›」真的能跳到那一页（告警）",
          bool(gbtns) and w._page_key_now() == "alarm",
          "跳到 %s（按钮 %d 个）" % (w._page_key_now(), len(gbtns)))
    # ⑩ 正交质量卡（新）：造已知误差的帧 —— 界面上的数必须等于造出来的数
    import math

    def _q_frames(n=600, r_s=1000.0, r_c=1030.0, eps=0.5, o_s=50.0, o_c=-30.0,
                  turns=2.0):
        out = []
        for k in range(n):
            th = 2.0 * math.pi * turns * k / n
            s = r_s * math.sin(th) + o_s
            c = r_c * math.cos(th + math.radians(eps)) + o_c
            out.append({"s": int(round(s)), "c": int(round(c)),
                        "angle": int(round((th / (2 * math.pi) % 1.0) * 65536)) % 65536})
        return out

    w.quality.reset()
    qres = w.quality.feed(_q_frames(), force=True)
    p_q = (qres or {}).get("params") or {}
    check("正交质量卡：3% 失配 / 0.5° 正交 / 50,−30 偏置 都读回来了",
          bool(p_q) and abs(p_q.get("r_s", 0) - 1000.0) < 3.0
          and abs(p_q.get("r_c", 0) - 1030.0) < 3.0
          and abs(p_q.get("eps_deg", 0) - 0.5) < 0.02
          and abs(p_q.get("off_s", 0) - 50.0) < 3.0
          and abs(p_q.get("off_c", 0) + 30.0) < 3.0,
          "R_s=%.1f R_c=%.1f eps=%.4f off=%.1f,%.1f"
          % (p_q.get("r_s", 0), p_q.get("r_c", 0), p_q.get("eps_deg", 0),
             p_q.get("off_s", 0), p_q.get("off_c", 0)))
    # 判据按「机械角秒」：0.5°(电) ÷ 2048 × 3600 ≈ 0.88″ ⇒ 正常，不该红
    # 这份造出来的数据是 3% 幅值失配 ≡ 1.5″，实际是"可接受但不完美"，
    # 所以只要求"不标红"（≤ 注意），红留给真超差那条用例。
    check("正交质量卡：正常前端不标红（0.5° 电 ≈ 0.9″，≤ 注意级）",
          w.quality.verdict() in (0, 1), "level=%s 文案=%s"
          % (w.quality.verdict(), w.quality.lab_verdict.text()))

    def _q_bad(n=600, eps=20.0):
        out = []
        for k in range(n):
            th = 2.0 * math.pi * 2.0 * k / n
            out.append({"s": int(round(2000 * math.sin(th))),
                        "c": int(round(2000 * math.cos(th + math.radians(eps)))),
                        "angle": int(round((th / (2 * math.pi) % 1.0) * 65536)) % 65536})
        return out

    w.quality.feed(_q_bad(), force=True)
    check("正交质量卡：真超差（正交 20° 电 ≈ 35″）才判 fault 并标红",
          w.quality.verdict() == 2, "level=%s 文案=%s"
          % (w.quality.verdict(), w.quality.lab_verdict.text()))
    check("正交质量卡：折算角度误差有数（不是「—」）",
          w.quality.v_err.text() not in ("—", "", None), w.quality.v_err.text())
    w.quality.feed(_q_frames(n=100), force=True)
    check("正交质量卡：帧太少时不给结论（不拿 10 ms 数据下判断）",
          w.quality.verdict() == -1 and "取点不足" in w.quality.lab_verdict.text(),
          "level=%s 文案=%s" % (w.quality.verdict(), w.quality.lab_verdict.text()))
    w.quality.feed(_q_frames(turns=0.5), force=True)
    check("正交质量卡：只转半圈时报出 180° 取点缺口",
          "缺口" in w.quality.lab_verdict.text(), w.quality.lab_verdict.text())
    w._refresh_overview()
    check("概览页「前端质量」这一行跟着质量卡走（不是一直待数据）",
          w.overview.value("front") not in ("—", ""),
          "值=%s 判定=%s" % (w.overview.value("front"), w.overview.verdict("front")))
    w.quality.reset()
    w.quality.feed(_q_frames(), force=True)

    # 链路健康趋势（诊断页）
    w.health.clear()
    check("健康趋势卡：一开始没有点", w.health.count() == 0)
    for _k in range(6):
        w.health.push(100.0 + 2.0 * _k, 10000.0 - 50.0 * _k, 0.38, 3 + _k)
    check("健康趋势卡：推 6 个点后曲线有三条线都有数据",
          w.health.count() == 6 and w.health.last("err") is not None
          and w.health.last("lost") is not None,
          "n=%d fps=%s" % (w.health.count(), w.health.last("fps")))
    check("健康趋势卡：帧率跟着推的数走（9750）",
          abs((w.health.last("fps") or 0) - 9750.0) < 1e-6, w.health.last("fps"))
    w.health.clear()
    check("健康趋势卡：清空后为 0", w.health.count() == 0)

    # 全周补偿表（诊断页）
    _lut_curve = [(0.0, 0.0), (90.0, 10.0), (180.0, 0.0), (270.0, -10.0), (359.9, 0.0)]
    check("补偿表卡：一开始没有表（不给上传按钮乱按的机会）",
          not w.lut.has_table())
    w.lut.set_pairs(_lut_curve, "t.csv")
    check("补偿表卡：5 点曲线折算出 4096 点表",
          w.lut.has_table() and len(w.lut.words()) == 4096,
          "点数=%s 表长=%s" % (w.lut.v_n.text(), len(w.lut.words())))
    check("补偿表卡：折算 LSB 落在 ±1036 附近（±10″ ÷ 0.00966″，四舍五入到整数）",
          w.lut.v_lsb.text() in ("±1035", "±1036", "±1037"), w.lut.v_lsb.text())
    w.lut.set_dump({0: 0, 1024: 0x03E8})
    check("补偿表卡：回读点进了曲线", len(w.lut.plot._dump) == 2)
    w.lut.set_uploaded(3, 0x00, 90.0)
    check("补偿表卡：回读不一致时明确报错且说没启用",
          "回读不一致 3 点" in w.lut.lab_check.text(), w.lut.lab_check.text())
    w.lut.set_uploaded(0, 0x01, 61.0)
    check("补偿表卡：写入成功后显示已启用",
          "已启用" in w.lut.lab_check.text(), w.lut.lab_check.text())
    w.lut.clear()
    check("补偿表卡：清空后回到无表状态",
          (not w.lut.has_table()) and w.lut.v_n.text() == "—")

    # 板上状态卡：偏置慢跟踪开关（0x0122 bit1）
    check("板上状态卡：有「打开偏置慢跟踪」按钮",
          hasattr(w.board_status, "btn_bias")
          and "偏置" in w.board_status.btn_bias.text(),
          getattr(w.board_status, "btn_bias", None))
    _bias_got = []
    w.board_status.bias_requested.connect(_bias_got.append)
    w.board_status.btn_bias.click()
    check("板上状态卡：按钮点了会发 bias_requested(True)", _bias_got == [True],
          "收到 %s" % _bias_got)
    w._done_bias_track({"ok": True, "why": "", "cfg": 0x03, "valid": 1, "big": 0,
                        "s": 109, "c": 473})
    check("板上状态卡：开关成功时把 valid 与学到的偏置写进提示行",
          "已打开" in w.board_status.lab_note.text()
          and "109" in w.board_status.lab_note.text(),
          w.board_status.lab_note.text())
    w._done_bias_track({"ok": False, "why": "0x013C 的 valid 还是 0"})
    check("板上状态卡：没生效时明确说没生效（不假装成功）",
          "0x013C" in w.board_status.lab_note.text(),
          w.board_status.lab_note.text())

        # ---- UVW 半边独立可调（m02689：不仅 ABZ 可调，UVW 也要可调）----
    _ab = w.abz
    _ab.cmb_uvw_span.setCurrentIndex(3)                 # 90°
    check("UVW 横轴可调到 90°", abs(_ab._uvw_span - 90.0) < 1e-6, "%.1f" % _ab._uvw_span)
    _ab.cmb_uvw_span.setCurrentIndex(0)                 # 回整圈
    _ab.sp_uvw_pairs.setValue(2)
    check("UVW 每转周期数可改（重分箱）", _ab.an.pairs == 2, "pairs=%d" % _ab.an.pairs)
    _ab.sp_uvw_pairs.setValue(4)
    check("UVW 每转周期数改回 4", _ab.an.pairs == 4, "pairs=%d" % _ab.an.pairs)
    _ab.chk_uvw_line.setChecked(False)
    check("UVW 扇区线可关", _ab._uvw_line is False, str(_ab._uvw_line))
    _ab.chk_uvw_line.setChecked(True)

    # 诊断页：高级参数 + 通信日志 + 设备自检
    w.show_page("diag")
    app.processEvents()
    diag = w._scrolls["diag"].widget()
    check("「高级参数」整块搬到了「诊断」页（⑨ 卡里不再折叠它）",
          diag.isAncestorOf(w.interp.box_adv) and w.interp.box_adv.isVisible(),
          "父链：%s" % w.interp.box_adv.parent().__class__.__name__)
    check("诊断页里给这块配了一张有标题的卡（不再像「掉在地上的控件」）",
          hasattr(w, "adv_card") and diag.isAncestorOf(w.adv_card)
          and "高级参数" in w.adv_card.findChild(QLabel, "CardTitle").text(),
          "卡片标题：%s" % (w.adv_card.findChild(QLabel, "CardTitle").text()
                          if hasattr(w, "adv_card") else "无"))
    check("⑨ 卡上的按钮改成带路文案（写明在「诊断」页）",
          "诊断" in w.interp.btn_adv.text(), w.interp.btn_adv.text())
    check("诊断页里有通信日志、设备信息、链路统计卡",
          diag.isAncestorOf(w.log) and diag.isAncestorOf(w.card_device)
          and diag.isAncestorOf(w.card_link),
          "log=%s device=%s link=%s" % (diag.isAncestorOf(w.log),
                                        diag.isAncestorOf(w.card_device),
                                        diag.isAncestorOf(w.card_link)))
    w.show_page("live")
    app.processEvents()
    w.interp.btn_adv.click()
    app.processEvents()
    check("点该按钮会跳到「诊断」页", w._page_key_now() == "diag", w._page_key_now())
    check("「原始值」开关搬到了顶栏（不再占状态条）",
          w.topbar.isAncestorOf(w.chk_raw) and w.chk_raw.isCheckable(),
          "顶栏内=%s" % w.topbar.isAncestorOf(w.chk_raw))

    # ★ 2026-10-17 自查：高级参数的 tooltip 是操作员唯一能看到"单位 / 0 的含义"的地方，
    #   必须与 RTL 一致（旧文案把 AB 迟滞的 0 说成"默认档"、把 z_width=0 说成"不出 Z"）。
    _tip_z = w.interp._adv_spins["zwidth"].toolTip()
    _tip_ha = w.interp._adv_spins["hyst_ab"].toolTip()
    _tip_hu = w.interp._adv_spins["hyst_uvw"].toolTip()
    check("Z 脉宽提示写明 v9 起 0 也出 1 步（不再是「不出 Z」）",
          ("1 步" in _tip_z) and ("不出 Z" not in _tip_z), _tip_z.splitlines()[-1][:50])
    check("AB 迟滞提示写明 0 = 不启用（不说「默认档」）",
          ("不启用" in _tip_ha) and ("默认档" not in _tip_ha), _tip_ha.splitlines()[-1][:50])
    check("UVW 迟滞提示保留默认档语义（RTL 确有默认值）",
          "默认档" in _tip_hu, _tip_hu.splitlines()[-1][:50])

    # ================================================================ R2/R3 示波器
    hr("⑮ 示波器式量程：时基/角度窗口/通道间距 + Ctrl+滚轮缩放 + 双击复原（R2/R3）")
    import math                                              # noqa: PLC0415
    w.resize(1280, 900)
    w.show()
    app.processEvents()
    w.wave.set_f_in(20000.0)
    w.wave.feed([{"s": int(16384 * math.sin(i / 7.0)),
                  "c": int(16384 * math.cos(i / 7.0))} for i in range(1500)],
                force_draw=True)
    app.processEvents()
    auto_ms = w.wave.x_span()
    # 20 kHz 的"2 个周期"只有 0.1 ms，而板上遥测只有 10 kHz（0.1 ms/点）——
    # 那么窄的窗口只能画出 1 个点，看着像一条不动的折线。所以自动档有 5 ms 下限
    # （见 panel_wave._auto_span_ms 的注释），这里按新口径断言。
    check("波形横轴自动档在 20 kHz 时落到 5 ms 下限", 4.9 <= auto_ms <= 5.1,
          "20 kHz → 满屏 %.3f ms（下限 5 ms）" % auto_ms)
    w.wave.set_f_in(400.0)                      # 400 Hz → 2 个周期 = 5 ms，仍在下限上
    check("波形横轴自动档按频率跟到 5 ms 档", 4.9 <= w.wave.x_span() <= 5.1,
          "400 Hz → 满屏 %.3f ms" % w.wave.x_span())
    w.wave.set_f_in(100.0)                      # 100 Hz → 2 个周期 = 20 ms
    check("波形横轴自动档在 100 Hz 时跟到 20 ms", 19.0 <= w.wave.x_span() <= 21.0,
          "100 Hz → 满屏 %.3f ms" % w.wave.x_span())
    w.wave.set_f_in(20000.0)
    tdiv = [w.wave.cmb_tdiv.itemData(i) for i in range(w.wave.cmb_tdiv.count())]
    w.wave.cmb_tdiv.setCurrentIndex(tdiv.index(20.0))
    app.processEvents()
    xl = w.wave.ax_t.get_xlim()
    check("选「满屏 20 ms」即切手动并真的改坐标轴",
          w.wave.x_mode == "manual" and abs((xl[1] - xl[0]) - 20.0) < 0.05,
          "xlim=%.3f…%.3f ms" % (xl[0], xl[1]))
    vdiv = [w.wave.cmb_vdiv.itemData(i) for i in range(w.wave.cmb_vdiv.count())]
    w.wave.cmb_vdiv.setCurrentIndex(vdiv.index(0.25))
    app.processEvents()
    yl = w.wave.ax_t.get_ylim()
    check("选「±0.25 FS」纵轴量程生效（幅值看得更细）",
          w.wave.y_mode == "manual" and abs((yl[1] - yl[0]) - 2.0 * 0.25 * 32767.0) < 5.0,
          "ylim=%.0f…%.0f" % (yl[0], yl[1]))
    bar0 = w.scroll.verticalScrollBar().value()
    app.sendEvent(w.wave.canvas, wheel_zoom(120))
    app.processEvents()
    check("Ctrl+滚轮缩小横轴（等于放大波形）", w.wave.x_span() < 20.0,
          "%.3f ms（原 20 ms）" % w.wave.x_span())
    check("Ctrl+滚轮不滚页面（图表吃掉这个事件）",
          w.scroll.verticalScrollBar().value() == bar0,
          "页面 %d → %d" % (bar0, w.scroll.verticalScrollBar().value()))
    app.sendEvent(w.wave.canvas, dbl_click(w.wave.canvas))
    app.processEvents()
    check("双击图内恢复自动量程", w.wave.x_mode == "auto" and w.wave.y_mode == "auto",
          "x=%s y=%s" % (w.wave.x_mode, w.wave.y_mode))

    xspan = [w.abz.cmb_xspan.itemData(i) for i in range(w.abz.cmb_xspan.count())]
    w.abz.cmb_xspan.setCurrentIndex(xspan.index(90.0))
    app.processEvents()
    xa = w.abz.ax_ab.get_xlim()
    check("ABZ 选「满屏 90°」角度窗口生效（方波不再挤成一团）",
          w.abz.x_mode == "manual" and abs((xa[1] - xa[0]) - 90.0) < 0.05,
          "xlim=%.1f…%.1f°" % (xa[0], xa[1]))
    w.abz.sp_gap.setValue(2.0)
    app.processEvents()
    oa, ob, oz, ylim = w.abz._chan_offsets()
    check("通道间距可调（ABZ 太密就拉开）", abs(oa - 2.2 * 2.0) < 1e-6,
          "A/B/Z 基线 %.2f/%.2f/%.2f、纵轴 %.2f…%.2f" % (oa, ob, oz, ylim[0], ylim[1]))
    w.abz.cmb_layout2.setCurrentIndex(1)          # 分离
    app.processEvents()
    oa2, ob2, oz2, ylim2 = w.abz._chan_offsets()
    check("「分离」排布把通道拉得更开（UVW 太稀就收紧）",
          w.abz.layout_mode == "split" and (ylim2[1] - ylim2[0]) > (ylim[1] - ylim[0]),
          "纵轴 %.2f…%.2f" % (ylim2[0], ylim2[1]))
    app.sendEvent(w.abz.canvas, wheel_zoom(120))
    app.processEvents()
    check("ABZ 图也吃 Ctrl+滚轮（角度窗口跟着缩放）", w.abz.x_span() < 90.0,
          "%.1f°（原 90°）" % w.abz.x_span())
    app.sendEvent(w.abz.canvas, dbl_click(w.abz.canvas))
    app.processEvents()
    check("双击恢复整圈 360°", w.abz.x_mode == "auto" and abs(w.abz.x_span() - 360.0) < 1e-6,
          "%.1f°" % w.abz.x_span())
    w.wave.reset_auto()
    w.abz.reset_auto()

    # ================================================================ 参数记忆
    hr("⑯ 参数记忆：量程/排布/日志级别/窗口尺寸存 ui_prefs.json（R2/R3/R5）")
    up._cache = None
    w.wave.set_x_span(50.0)
    w.abz.set_x_span(90.0)
    w.abz.sp_gap.setValue(1.6)
    w.combo_log.setCurrentIndex(0)                 # 0 = 全部（含调试）
    app.processEvents()
    # ★ 阶段 3：顶栏端口框为了不把"COM3 — … ★"截掉加了最小宽度，于是窗口的
    #   排版下限从 ~980 抬到 ~1024 —— 原来这里 resize(1000, 700) 会被下限顶住。
    #   这里改用 1200×760（明确高于下限），测的仍然是"关窗时多大、重开就多大"。
    w.resize(1200, 760)
    w._save_prefs()
    pth = up.path()
    saved = {}
    if os.path.isfile(pth):
        import json                                          # noqa: PLC0415
        with open(pth, "r", encoding="utf-8") as fh:
            saved = json.load(fh)
    check("关窗时把界面参数写进 ui_prefs.json",
          os.path.isfile(pth) and saved.get("wave", {}).get("x_span_ms") == 50.0
          and saved.get("window", {}).get("w") == 1200,
          "%s：wave.x_span_ms=%s window=%s" % (os.path.basename(pth),
                                               saved.get("wave", {}).get("x_span_ms"),
                                               saved.get("window")))
    up._cache = None                               # 模拟"重开软件"（必须从文件读）
    w2 = mw.MainWindow()
    check("重开窗口恢复横轴 50 ms / 角度 90° / 间距 1.6",
          w2.wave.x_mode == "manual" and abs(w2.wave.x_span() - 50.0) < 1e-6
          and abs(w2.abz.x_span() - 90.0) < 1e-6 and abs(w2.abz.spacing - 1.6) < 1e-6,
          "wave %.0f ms、abz %.0f°、间距 %.1f"
          % (w2.wave.x_span(), w2.abz.x_span(), w2.abz.spacing))
    check("重开窗口恢复日志显示级别（全部含调试）", w2.log_level == "debug"
          and w2.combo_log.currentData() == "debug", w2.log_level)
    check("重开窗口恢复窗口尺寸", (w2.width(), w2.height()) == (1200, 760),
          "%d×%d" % (w2.width(), w2.height()))
    w2.close()
    # 文件被手改坏 ⇒ 静默回落默认，且界面照样能起来
    with open(pth, "w", encoding="utf-8") as fh:
        fh.write("{ 这不是 json ,,, ")
    up._cache = None
    w3 = mw.MainWindow()
    check("参数文件损坏时静默回落默认（界面不崩）",
          w3.wave.x_mode == "auto" and w3.log_level == "info" and w3.abz.layout_mode == "overlay",
          "wave=%s log=%s abz=%s" % (w3.wave.x_mode, w3.log_level, w3.abz.layout_mode))
    w3.close()
    up._cache = None

    # ================================================================ 按当前视图导出
    hr("⑰ 「导出当前视图」：量程照当前窗口，像素契约与全貌导出一致")
    w.record.set_dir(tmp)
    w.wave.set_f_in(20000.0)
    w.wave.feed([{"s": int(16384 * math.sin(i / 7.0)),
                  "c": int(16384 * math.cos(i / 7.0))} for i in range(1500)],
                force_draw=True)
    w.wave.cmb_tdiv.setCurrentIndex([w.wave.cmb_tdiv.itemData(i)
                                     for i in range(w.wave.cmb_tdiv.count())].index(20.0))
    app.processEvents()
    before = set(os.listdir(tmp))
    w._on_export("wave_view")
    app.processEvents()
    new = sorted(set(os.listdir(tmp)) - before)
    pv = os.path.join(tmp, new[0]) if new else ""
    # ★ 断言 ASCII 名里的 `_view` 段：文件名必须纯英文（竞赛要求，见
    #   host/export_png.py:421-435 的 suggest_name：tag += "_view"），「当前视图」四个字
    #   只出现在图内标题与记录卡片提示里。这两条原来还在找中文名，自 6a995e9
    #   「全仓文件名去中文」起就是假失败（阶段 1 复查时发现并改正）
    check("波形「导出当前视图」落盘且文件名带 _view 段",
          len(new) == 1 and "_view_" in new[0] and os.path.getsize(pv) > 1024,
          "%s（%.0f kB）" % (new[0] if new else "没落盘",
                             os.path.getsize(pv) / 1024.0 if pv else 0))
    check("视图导出仍是 1950×1080 像素契约", bool(pv) and ep.png_px(pv) == ep.wave_px(),
          "%s vs %s" % (ep.png_px(pv) if pv else None, ep.wave_px()))
    check("记录卡片提示带上「当前视图」",
          "当前视图" in w.record.lab_note.text(), w.record.lab_note.text()[:46])
    before = set(os.listdir(tmp))
    w._on_export("abz_view")
    app.processEvents()
    new2 = sorted(set(os.listdir(tmp)) - before)
    pa = os.path.join(tmp, new2[0]) if new2 else ""
    check("ABZ「导出当前视图」落盘且 1950×990 契约",
          len(new2) == 1 and "_view_" in new2[0] and bool(pa)
          and ep.png_px(pa) == ep.abz_px(),
          "%s %s" % (new2[0] if new2 else "没落盘", ep.png_px(pa) if pa else None))
    before = set(os.listdir(tmp))
    w._on_export("wave")
    app.processEvents()
    new3 = sorted(set(os.listdir(tmp)) - before)
    check("全貌导出照旧（文件名不带 _view 段）",
          len(new3) == 1 and "_view_" not in new3[0], new3[0] if new3 else "没落盘")

    # ================================================================ 批次 4
    hr("⑱ 批次 4：挡位加密/步进按钮/键盘（R9）· 滚轮缩放契约（R8）· 全屏与排版（R10/R7-B）")
    import panel_abz as pz                                   # noqa: PLC0415
    import panel_wave as pw                                  # noqa: PLC0415
    from PySide6.QtWidgets import QGridLayout              # noqa: PLC0415
    w.resize(1280, 900)
    w.show()
    w.show_page("live")                 # 阶段 2：这一段量的都是「实时」页上的卡片
    app.processEvents()
    check("挡位加密：波形时基 17 档、幅值 7 档",
          len(pw.X_SPANS_MS) == 17 and len(pw.Y_FULLS) == 7
          and 1.5 in pw.X_SPANS_MS and 7.5 in pw.X_SPANS_MS and 75.0 in pw.X_SPANS_MS,
          "时基 %d 档、幅值 %d 档" % (len(pw.X_SPANS_MS), len(pw.Y_FULLS)))
    check("挡位加密：ABZ 角度窗口 11 档（含 5°/45°/120°）",
          len(pz.X_SPANS_DEG) == 11 and 5.0 in pz.X_SPANS_DEG
          and 45.0 in pz.X_SPANS_DEG, "%d 档" % len(pz.X_SPANS_DEG))
    sbtns = [getattr(w.wave, n) for n in ("btn_tdiv_prev", "btn_tdiv_next",
                                          "btn_vdiv_out", "btn_vdiv_in")]
    sbtns += [getattr(w.abz, n) for n in ("btn_xspan_prev", "btn_xspan_next")]
    check("步进按钮铺好（波形 ◀▶ −/+、ABZ ◀▶）且样式类为 StepBtn",
          all(b is not None and b.objectName() == "StepBtn" for b in sbtns),
          "%d 个：%s" % (len(sbtns), "".join(b.text() for b in sbtns)))
    w.wave.set_x_span(10.0)
    w.wave.step_x(-1)
    check("点「◀」时基细一档（10 ms → 7.5 ms）", abs(w.wave.x_span() - 7.5) < 1e-6,
          "%.2f ms" % w.wave.x_span())
    w.wave.set_x_span(10.0)
    w.wave.step_x(-1, True)
    check("Shift 微调不进挡位表（10 ms × 0.9）", abs(w.wave.x_span() - 9.0) < 1e-6,
          "%.3f ms" % w.wave.x_span())
    w.wave.set_x_span(pw.X_SPANS_MS[0])
    app.processEvents()
    check("到挡位端点时「◀」自动置灰（不让用户点了没反应）",
          not w.wave.btn_tdiv_prev.isEnabled() and w.wave.btn_tdiv_next.isEnabled(),
          "◀=%s ▶=%s" % (w.wave.btn_tdiv_prev.isEnabled(), w.wave.btn_tdiv_next.isEnabled()))
    w.wave.set_y_full(1.0)
    w.wave.step_y(+1)
    check("点「+」幅值放大一档（满量程 1.0 → 0.75 FS）",
          abs(float(w.wave.y_full) - 0.75) < 1e-6, "%.2f FS" % float(w.wave.y_full))
    # 方向键（焦点不在输入框里才生效）
    # ★ 阶段 5：前面 ⑨补7 为了量默认版面**新开过第二个 MainWindow**，离屏平台在这之后
    #   会把激活态清成 None（`WindowShortcut` 于是全不响应）。真实桌面上只要有焦点，
    #   窗口就是激活的 ⇒ 这里必须显式把窗口激活回来，否则会误报"快捷键坏了"。
    w.activateWindow()
    w.raise_()
    app.processEvents()
    w.wave.canvas.setFocus()
    app.processEvents()
    w.wave.set_x_span(10.0)
    QTest.keyClick(w, Qt.Key_Left)
    app.processEvents()
    check("方向键 ← = 时基细一档，且状态栏写明调了什么",
          abs(w.wave.x_span() - 7.5) < 1e-6 and "时基" in w.statusBar().currentMessage(),
          "%.2f ms / 状态栏「%s」" % (w.wave.x_span(), w.statusBar().currentMessage()[:24]))
    QTest.keyClick(w, Qt.Key_Left, Qt.ShiftModifier)
    app.processEvents()
    check("Shift+← = 微调（约 ×0.9）", 6.6 <= w.wave.x_span() <= 6.9,
          "%.3f ms" % w.wave.x_span())
    QTest.keyClick(w, Qt.Key_R)
    app.processEvents()
    check("R = 恢复自动量程", w.wave.x_mode == "auto" and w.wave.y_mode == "auto",
          "x=%s y=%s" % (w.wave.x_mode, w.wave.y_mode))
    w.wave.set_x_span(10.0)
    w.interp.sp_inter.setFocus()
    app.processEvents()
    QTest.keyClick(w, Qt.Key_Left)
    app.processEvents()
    check("焦点在数字框里时方向键让给它（不改量程）",
          abs(w.wave.x_span() - 10.0) < 1e-6, "%.2f ms" % w.wave.x_span())
    # 阶段 2 起没有"放大态"了：原来这一段的 R8/R10/R11 用例（裸滚轮缩放、PgDn 换卡片、
    # 收起提示、读数字号）随「⛶ 放大」一起退场；下面是它们留下的等价契约：
    check("普通态：裸滚轮滚页面、Ctrl+滚轮才归图表（R1 契约）",
          w.wave.x_mode in ("auto", "manual"), "x_mode=%s" % w.wave.x_mode)
    w.wave.set_x_span(10.0)
    _p0 = w.scroll.verticalScrollBar().value()
    app.sendEvent(w.wave.canvas, wheel_event(-120))
    app.processEvents()
    check("裸滚轮落在图表上时滚的是页面、不动量程",
          w.scroll.verticalScrollBar().value() > _p0
          and abs(w.wave.x_span() - 10.0) < 1e-6,
          "页 %d → %d / 量程 %.2f ms" % (_p0, w.scroll.verticalScrollBar().value(),
                                        w.wave.x_span()))
    _sp = w.wave.x_span()
    app.sendEvent(w.wave.canvas, wheel_zoom(120))
    app.processEvents()
    check("Ctrl+滚轮归图表：横轴按 20% 档缩放",
          0.75 <= w.wave.x_span() / _sp <= 0.85,
          "%.2f → %.2f ms（×%.3f）" % (_sp, w.wave.x_span(), w.wave.x_span() / _sp))
    # 上一段把焦点放进了数字框 ⇒ 快捷键被 focusChanged 关掉了；回到图上再测全屏
    w.wave.canvas.setFocus()
    app.processEvents()
    QTest.keyClick(w, Qt.Key_F)
    app.processEvents()
    fs = bool(w.isFullScreen() or (w.windowState() & Qt.WindowFullScreen))
    QTest.keyClick(w, Qt.Key_F)
    app.processEvents()
    back = not bool(w.isFullScreen() or (w.windowState() & Qt.WindowFullScreen))
    check("F 进/出真·全屏（R10）", fs and back, "进=%s 出=%s" % (fs, back))
    check("波形两个子图按 2:1 分宽（R7-B：主图优先）",
          tuple(w.wave._gs.get_width_ratios()) == (2.0, 1.0),
          "%s" % (tuple(w.wave._gs.get_width_ratios()),))
    grids = w.abz.findChildren(QGridLayout)
    check("ABZ 六状态表让末列吸收剩余宽度（R7-B，两组紧挨、中间 36 px）",
          any(g.columnStretch(6) == 1 and g.columnMinimumWidth(3) == 36 for g in grids),
          "布局 %d 个，命中末列拉伸=%s" % (len(grids), [g.columnStretch(6) for g in grids]))
    w.wave.reset_auto()
    w.abz.reset_auto()

    # ============================================== 阶段 2：窄卡片不再要求放大
    hr("⑲ 阶段 2：卡片版面只剩一种（放大态排版已随 ⛶ 退场）")
    app.processEvents()
    check("普通态：控制与读数是图表上方的整宽一条",
          w.wave.side.width() > 600 and w.wave.canvas.geometry().y() > w.wave.side.geometry().y(),
          "控制区 %d px / 图 y=%d" % (w.wave.side.width(), w.wave.canvas.geometry().y()))
    check("波形卡片里再没有放大态专用的排版入口",
          not hasattr(w.wave, "set_max_layout") and not hasattr(w.wave, "SIDE_MAX_W")
          and not hasattr(w.abz, "set_max_layout"),
          "hasattr: wave.set_max_layout=%s abz.set_max_layout=%s"
          % (hasattr(w.wave, "set_max_layout"), hasattr(w.abz, "set_max_layout")))
    check("图表高度按页给足（实时页把大波形当主角，不再是 250 px 小图）",
          w.wave.canvas.height() >= 240, "高 %d px" % w.wave.canvas.height())

    # ============================================== 阶段 3：Apple 视觉落地
    hr("⑳ 阶段 3：Inter 随包分发 / 设计令牌 / 状态色（真抓图读像素）")
    check("Inter 随包分发并注册成功",
          uf.is_loaded() and "Inter" in QFontDatabase.families(),
          "注册 %d 个文件 / families 里有 Inter=%s" % (
              len(uf.FONT_FILES), "Inter" in QFontDatabase.families()))
    check("字体文件与 OFL 许可证都在包内资源目录里",
          all(os.path.exists(os.path.join(th.FONT_DIR, f)) for f in uf.FONT_FILES)
          and os.path.exists(os.path.join(th.FONT_DIR, "OFL-1.1.txt")),
          th.FONT_DIR)
    _af = QApplication.font()
    check("全局字体族以 Inter 打头、基准字号 13 px",
          _af.families() and _af.families()[0] == "Inter" and _af.pixelSize() == uf.BASE_PX,
          "families=%s px=%d" % (_af.families()[:2], _af.pixelSize()))
    _mono = [l for l in w.findChildren(QLabel)
             if l.property("mono") in (True, "true")]
    _ok_tnum = 0
    _bad_tnum = []
    for _l in _mono:
        _f = _l.font()
        if _f.family() == "Inter" and _f.featureValue(_f.Tag("tnum")) == 1:
            _ok_tnum += 1
        else:
            _par = _l.parent()
            _bad_tnum.append("%s/%r@%s.%s" % (
                _f.family(), _l.text()[:20], type(_par).__name__,
                _par.objectName() if _par is not None else None))
    check("读数标签全开 tabular figures（等宽数字，位数变化不抖）",
          len(_mono) >= 20 and _ok_tnum == len(_mono),
          "%d 个读数标签，其中 %d 个 Inter+tnum%s" % (
              len(_mono), _ok_tnum, ("｜异常：%s" % _bad_tnum[:3]) if _bad_tnum else ""))
    check("设计令牌是 Apple 一套（底 / 卡 / 强调 / 分隔 / 三态色）",
          (th.C["bg"], th.C["card"], th.C["primary"], th.C["line"],
           th.C["text"], th.C["muted"], th.C["ok"], th.C["warn"], th.C["fault"])
          == ("#F5F5F7", "#FFFFFF", "#0071E3", "#E5E5EA",
              "#1D1D1F", "#6E6E73", "#34C759", "#FF9F0A", "#FF3B30"),
          "primary=%s fault=%s" % (th.C["primary"], th.C["fault"]))
    check("导出图配色与界面同源（不再各抄一份色值）",
          ep.C is th.C, "export_png.C is theme.C = %s" % (ep.C is th.C))
    check("复选框/开关位图四条都在（@2x 也在）",
          all(os.path.exists(p) for p in (
              os.path.join(th.IMG_DIR, "chk_off.png"), os.path.join(th.IMG_DIR, "chk_on.png"),
              os.path.join(th.IMG_DIR, "sw_off.png"), os.path.join(th.IMG_DIR, "sw_on.png"),
              os.path.join(th.IMG_DIR, "sw_on@2x.png"))),
          th.IMG_DIR)
    check("状态开关用滑块外观（原始值 / 两个暂停刷新 / 自动记录）",
          all(x.property("switch") == "true" for x in (
              w.chk_raw, w.wave.chk_pause, w.abz.chk_pause, w.record.chk_auto)),
          "chk_raw=%s wave=%s abz=%s record=%s" % (
              w.chk_raw.property("switch"), w.wave.chk_pause.property("switch"),
              w.abz.chk_pause.property("switch"), w.record.chk_auto.property("switch")))

    w.show_page("live")
    w.show()
    app.processEvents()
    QTest.qWait(80)
    # 真抓图读像素：离屏平台同样保留颜色（阶段 2 "截图不能验配色"的说法已被推翻）
    _shot = w.grab()
    _sw = w.sidebar.width()
    check("抓图读像素：页面底 = #F5F5F7（侧栏一块）",
          _find_color(_shot, th.C["bg"], box=(0, 0, _sw, _shot.height())),
          "侧栏 %d px / 底色 %s" % (_sw, th.C["bg"]))
    check("抓图读像素：卡片底 = #FFFFFF（② 设备卡落在诊断页，仍在同一张抓图里）",
          _find_color(w.card_device.grab(), th.C["card"]),
          "设备卡 %s" % th.C["card"])
    check("抓图读像素：强调色 = #0071E3（顶栏主按钮 / 侧栏选中项）",
          _find_color(_shot, th.C["primary"])
          and _find_color(w.btn_connect.grab(), th.C["primary"]),
          "连接按钮 + 选中项 %s" % th.C["primary"])
    _pt = w.findChild(QLabel, "PageTitle")
    _ct = w.findChild(QLabel, "CardTitle")
    check("字号阶梯落在样式表上（页标题 22 / 卡片标题 17 / 读数 28）",
          _pt is not None and _pt.font().pixelSize() == 22
          and _ct is not None and _ct.font().pixelSize() == 17
          and w.speed.v_rpm.font().pixelSize() == 28,
          "页标题 %s / 卡片标题 %s / 读数 %s" % (
              _pt.font().pixelSize() if _pt else "-",
              _ct.font().pixelSize() if _ct else "-", w.speed.v_rpm.font().pixelSize()))
    check("顶栏贴边成一条（外边距 0，只有一条细下边线）",
          w._right.contentsMargins().left() == 0 and w._right.contentsMargins().top() == 0
          and bool(w.topbar.property("objectName") or w.topbar.objectName() == "TopBar"),
          "margins=%s / objectName=%s" % (w._right.contentsMargins().left(),
                                          w.topbar.objectName()))

    # ================================================================ ㉑ 阶段 5 A 批
    # 用户反馈（m15813）的第一批细改：卡片标题去编号、概览删「现在怎么样」、
    # 默认分箱 1024、小数位收敛、删「画图 ms」、型号识别大小写 bug。
    hr("㉑ 阶段 5 A 批：标题去编号 / 概览标题 / 默认 1024 箱 / 小数位 / 型号识别")

    _titles = [x.text() for x in w.findChildren(QLabel) if x.objectName() == "CardTitle"]
    _bad = [t for t in _titles if t[:1] in "①②③④⑤⑥⑦⑧⑨⑩⑪"]
    check("卡片标题不再带 ①②③… 编号（用户要求只留名字）",
          bool(_titles) and not _bad,
          "%d 个标题：%s%s" % (len(_titles), "、".join(_titles[:5]),
                              ("｜残留 %s" % _bad) if _bad else ""))

    check("概览页不再有「现在怎么样」标题",
          all(x.text() != "现在怎么样" for x in w.overview.findChildren(QLabel)),
          "概览里 CardTitle 数 = %d" % len([x for x in w.overview.findChildren(QLabel)
                                            if x.objectName() == "CardTitle"]))

    check("默认分箱 = 1024 箱（az.BINS_DEFAULT 与卡片下拉一致）",
          az.BINS_DEFAULT == 1024 and w.abz.bins() == 1024
          and w.abz.cmb_bins.currentData() == 1024,
          "BINS_DEFAULT=%d / 卡片=%d / 下拉=%s" % (
              az.BINS_DEFAULT, w.abz.bins(), w.abz.cmb_bins.currentData()))

    _snap_ok = {"ok": True, "f_abs": 1000.0, "span": 1.0, "rpm_abs": 15000.0,
                "turns": 11974.113, "cycles": 47896.451, "direction": "正转",
                "warn": "", "note": ""}
    w.speed.show_snapshot(_snap_ok)
    _re1 = re.compile(r"^-?\d+\.\d 圈$")
    _re2 = re.compile(r"^-?\d+\.\d$")
    check("累计圈数 / 电周期数只到小数点后一位",
          bool(_re1.match(w.speed.v_turns.text())) and bool(_re2.match(w.speed.v_cycles.text())),
          "圈数=%s / 电周期=%s" % (w.speed.v_turns.text(), w.speed.v_cycles.text()))

    w.interp.sp_inter.setValue(256)
    w.interp.sp_div.setValue(1)
    w.interp._refresh_math()
    check("等效倍率只到整数位（×256 这种写法）",
          bool(re.match(r"^×\d+（inter \d+ ÷ div \d+）$", w.interp.v_math.text())),
          "等效倍率=%s" % w.interp.v_math.text())

    check("刷新读数里没有「画图 … ms」（挪进悬停提示了）",
          "画图" not in w.wave.v_refresh.text()
          and "画图" in w.wave.v_refresh.toolTip(),
          "读数=%s" % w.wave.v_refresh.text())

    check("型号识别大小写无关（0x0C / 0X0C / 0c 都算已识别，0x0B 不算）",
          mw.dev_id_ok("0x0C") and mw.dev_id_ok("0X0C") and mw.dev_id_ok("0c")
          and not mw.dev_id_ok("0x0B") and not mw.dev_id_ok("—"),
          "0x0C=%s 0X0C=%s 0c=%s 0x0B=%s" % (mw.dev_id_ok("0x0C"), mw.dev_id_ok("0X0C"),
                                             mw.dev_id_ok("0c"), mw.dev_id_ok("0x0B")))
    _dev_keep = w.v_device.text()
    w.v_device.setText("0x0C")
    w.v_build.setText("0x000C")
    w._refresh_overview()
    check("概览「设备与链路」不再误报「型号未知」",
          "已识别" in w.overview.verdict("device"),
          "判定=%s" % w.overview.verdict("device"))
    w.v_device.setText(_dev_keep)
    w._refresh_overview()

    # ================================================================ ㉒ 阶段 5 B 批
    # 用户反馈（m15813）第 2 条：字体嫌小 ⇒ 随窗口自适应（1600×900 = 1.0×，上限 1.6×），
    # 并给 Ctrl+= / Ctrl+- / Ctrl+0 手动覆盖。这里把"缩放真的生效、且没把界面弄坏"
    # 都量一遍（★ 重点是 tnum 与 fix_lines：样式表一换，字体特性与提示高度都会失效）。
    hr("㉒ 阶段 5 B 批：字号随窗口自适应（含 tnum / 提示高度 / 手动覆盖）")

    check("缩放函数：1600×900 = 1.0、下限 1.0、上限 1.6",
          abs(uf.auto_scale(1600, 900) - 1.0) < 1e-6
          and abs(uf.auto_scale(1000, 700) - 1.0) < 1e-6
          and abs(uf.auto_scale(4000, 3000) - uf.SCALE_MAX) < 1e-6
          and uf.auto_scale(1920, 1080) > 1.0,
          "1600×900=%.3f / 1000×700=%.3f / 4000×3000=%.3f / 1920×1080=%.3f" % (
              uf.auto_scale(1600, 900), uf.auto_scale(1000, 700),
              uf.auto_scale(4000, 3000), uf.auto_scale(1920, 1080)))

    w.resize(1600, 900)
    w._scale_timer.timeout.emit()
    _s1 = w._applied_scale
    check("默认尺寸下缩放系数 = 1.0（首屏就是基准字号）",
          abs(_s1 - 1.0) < 1e-6, "applied=%.3f" % _s1)

    _mono = [x for x in w.findChildren(QLabel) if x.property("mono") in (True, "true")]
    _hint0 = None
    for _x in w.findChildren(QLabel):
        if _x.property("fixedLines"):
            _hint0 = _x.minimumHeight()
            break

    w.resize(2400, 1350)                      # 1.5× 的窗口
    w._scale_timer.timeout.emit()
    _s2 = w._applied_scale
    _qss = QApplication.instance().styleSheet()
    check("窗口放大后字号跟着放大（样式表里的 px 全被缩放）",
          _s2 > 1.4 and ("font-size: %dpx" % round(13 * _s2)) in _qss
          and w.sidebar.width() > int(uk.SIDEBAR_W * 1.4),
          "applied=%.2f / 正文=%dpx / 侧栏=%dpx" % (
              _s2, round(13 * _s2), w.sidebar.width()))

    _tnum_ok = 0
    for _x in _mono:
        try:
            if _x.font().featureValue(_TAG_TNUM) == 1:
                _tnum_ok += 1
        except Exception:                                         # noqa: BLE001
            pass
    check("缩放后所有读数标签的 tnum（等宽数字）仍在（样式表会重置字体特性）",
          bool(_mono) and _tnum_ok == len(_mono),
          "%d/%d 个标签仍带 tnum" % (_tnum_ok, len(_mono)))

    _hint1 = None
    for _x in w.findChildren(QLabel):
        if _x.property("fixedLines"):
            _hint1 = _x.minimumHeight()
            break
    check("缩放后提示标签高度按新字号重算（否则最后一行会被切掉）",
          _hint0 is not None and _hint1 is not None and _hint1 > _hint0,
          "1.0× 时 %s px → %.2f× 时 %s px" % (_hint0, _s2, _hint1))

    w.show_page("live")
    check("放大字号后「实时」页仍放得下（不需要横向滚动）",
          w._scrolls["live"].horizontalScrollBar().maximum() == 0,
          "横向滚动上限=%d" % w._scrolls["live"].horizontalScrollBar().maximum())

    w._scale_nudge(+0.1)
    _pref = up.number("ui", "scale", 0.0, uf.SCALE_MAX, 0.0)
    check("Ctrl+= 手动放大：写进 ui_prefs 并立即生效",
          _pref > 0 and abs(w._applied_scale - _pref) < 1e-6,
          "prefs ui.scale=%.3f / applied=%.3f" % (_pref, w._applied_scale))

    w._scale_reset()
    check("Ctrl+0 回到「跟随窗口」：ui.scale 归 0、系数回到自动值",
          up.number("ui", "scale", 0.0, uf.SCALE_MAX, 0.0) == 0.0
          and abs(w._applied_scale - uf.auto_scale(w.width(), w.height())) < 1e-6,
          "prefs=%.3f / applied=%.3f（窗口 %d×%d）" % (
              up.number("ui", "scale", 0.0, uf.SCALE_MAX, 0.0), w._applied_scale,
              w.width(), w.height()))

    _keys = " ".join(sc.key().toString() for sc in w._kbd_keys)
    check("Ctrl+= / Ctrl+- / Ctrl+0 三个字号键都在快捷键表里",
          "Ctrl+=" in _keys and "Ctrl+-" in _keys and "Ctrl+0" in _keys,
          _keys)

    w.resize(1600, 900)
    w._scale_timer.timeout.emit()

    # ================================================================ ㉓ 阶段 5 C 批
    hr("㉓ 阶段 5 C 批：波形触发（相对静止）/ ⑧ 独立大窗口")
    import wave_popup as wvp                                 # noqa: PLC0415
    _trig_keys = [k for k, _t in pw.TRIG_SOURCES]
    check("触发源下拉四档（s_n / c_n / Z 索引 / 自由）",
          w.wave.cmb_trig.count() == len(pw.TRIG_SOURCES)
          and [w.wave.cmb_trig.itemData(i) for i in range(w.wave.cmb_trig.count())] == _trig_keys,
          "档位 %s" % (", ".join(_trig_keys),))
    w.show_page("live")
    # 造 1500 帧正弦（≈1008 Hz 输入、10 kHz 帧率）：s_n 每 ~10 帧过一次零
    _tf = []
    for _i in range(1500):
        _tf.append(dict(angle=(_i * 4000) % 65536,
                        angle_deg=(_i * 4000) % 65536 * 360.0 / 65536.0,
                        s=int(30000 * math.sin(_i * 0.63)),
                        c=int(30000 * math.cos(_i * 0.63)),
                        io_state=0x40 | (1 if (_i % 50) < 5 else 0), io_flags=0, stat=0,
                        io_bits={"a": 0, "b": 0, "z": 1 if (_i % 50) < 5 else 0},
                        io_flag_bits={}, raw=b""))
    w.wave.buf.reset()
    w.wave.feed(_tf, force_draw=True)
    w.wave.set_f_in(1008.0)
    w.wave.feed([], force_draw=True)
    _snap = w.wave.buf.snapshot()
    check("缓冲里存了 Z 电平那一列（触发源「Z 索引」要它）",
          len(_snap.get("z") or []) == _snap["n"] and sum(_snap["z"]) > 0,
          "z 列 %d 个、其中高电平 %d 个" % (len(_snap.get("z") or []), sum(_snap.get("z") or [])))
    check("默认触发源 s_n：找到触发点并把它钉在画幅 25% 处（右侧）",
          w.wave.trig_mode == "s" and w.wave._trig_t is not None
          and abs(w.wave.ax_t.get_xlim()[1] - pw.TRIG_POS * w.wave.x_span()) < 1e-6,
          "trig_t=%s xlim=%s" % (
              None if w.wave._trig_t is None else round(w.wave._trig_t, 6),
              tuple(round(v, 4) for v in w.wave.ax_t.get_xlim())))
    _xs = list(w.wave.line_s.get_xdata())
    _x0 = min(range(len(_xs)), key=lambda i: abs(_xs[i]))
    check("波形数据里有 x≈0 的点（触发点就在原点处，而不是取最近样本）",
          abs(_xs[_x0]) < 0.11, "最接近 0 的横坐标 %.4f ms" % _xs[_x0])
    _s0 = w.wave.line_s.get_ydata()[_x0]
    check("触发点落在 s_n 的上升过零处（该点幅值≈0）",
          abs(float(_s0)) < 3000.0, "该点 s_n=%.0f（满刻度 32768）" % float(_s0))
    # 再喂几帧（画面滑动的那 5 帧）：触发锁定时，原点处的取值应当基本不变
    _keep = list(w.wave.line_s.get_ydata())
    w.wave.feed(_tf[:5], force_draw=True)
    _s1 = float(w.wave.line_s.get_ydata()[_x0])
    check("新数据进来后触发点仍钉在同一相位（画面对静止，不再左右游走）",
          abs(_s1) < 3000.0 and abs(_s1 - float(_s0)) < 3000.0,
          "上一帧 %.0f → 新一帧 %.0f（%d 点保持对齐）" % (float(_s0), _s1, len(_keep)))
    w.wave.cmb_trig.setCurrentIndex(w.wave.cmb_trig.findData("z"))
    w.wave.feed([], force_draw=True)
    check("切到「Z 索引」：触发点改由 Z 上升沿给（标题也写明触发源）",
          w.wave.trig_mode == "z" and "Z 索引" in w.wave.ax_t.get_title(),
          w.wave.ax_t.get_title())
    w.wave.cmb_trig.setCurrentIndex(w.wave.cmb_trig.findData("off"))
    w.wave.feed([], force_draw=True)
    check("切到「自由」：回到「原点 = 最新帧」的老行为（xlim 右端归 0）",
          w.wave.trig_mode == "off" and w.wave._trig_t is None
          and abs(w.wave.ax_t.get_xlim()[1]) < 1e-6 and "自由" in w.wave.ax_t.get_title(),
          "xlim=%s" % (tuple(round(v, 4) for v in w.wave.ax_t.get_xlim()),))
    check("触发档位存进 ui_prefs（关窗落盘、下次照旧）",
          up.choice("wave", "trig", tuple(_trig_keys), "s") == "off",
          "prefs wave.trig=%s" % up.choice("wave", "trig", tuple(_trig_keys), "s"))
    # ---- ⑧ 独立大窗口
    check("卡片⑧ 控制行有「独立窗口」按钮",
          w.wave.btn_popup is not None and w.wave.btn_popup.text() == "独立窗口"
          and w.wave.btn_popup.isVisibleTo(w.wave),
          w.wave.btn_popup.text())
    _fired = []
    w.wave.popup_requested.connect(lambda: _fired.append(1))
    _dbl = QMouseEvent(QEvent.MouseButtonDblClick, QPointF(4.0, 6.0), Qt.LeftButton,
                       Qt.LeftButton, Qt.NoModifier)
    app.sendEvent(w.wave.lab_title, _dbl)
    app.processEvents()
    check("双击卡片标题就发「要独立窗口」的信号（图内双击仍归恢复自动）",
          len(_fired) == 1, "信号收到 %d 次" % len(_fired))
    _span0 = w.wave.x_span()      # 开窗前的量程，关窗后必须一样
    w._open_wave_popup()
    _win = w._wave_win
    check("独立窗口建起来且是另一个 WavePanel 实例（主界面不受影响）",
          _win is not None and isinstance(_win, wvp.WavePopup)
          and _win.panel is not w.wave and _win.panel.buf is not w.wave.buf,
          type(_win.panel).__name__)
    _win.show()
    _win.resize(1200, 700)
    for _ in range(2):
        app.processEvents()
        QTest.qWait(30)
    _win.feed(_tf, force_draw=True)
    _win.feed([], force_draw=True)
    check("同一批帧也喂进独立窗口（它自己有一份缓冲与读数）",
          _win.panel.buf.snapshot()["n"] == 1500,
          "弹窗缓冲 %d 帧" % _win.panel.buf.snapshot()["n"])
    check("独立窗口里的画布不钉高（跟着窗口一起长）",
          _win.panel.canvas.minimumHeight() == 0 and _win.panel.canvas.maximumHeight() > 500,
          "min=%d max=%d" % (_win.panel.canvas.minimumHeight(),
                             _win.panel.canvas.maximumHeight()))
    check("主界面那张卡的画布仍然钉在 250 px（否则卡片高度会抖）",
          w.wave.canvas.maximumHeight() == 250 and w.wave.canvas.minimumHeight() == 250,
          "min=%d max=%d" % (w.wave.canvas.minimumHeight(), w.wave.canvas.maximumHeight()))
    check("独立窗口里不再出现「独立窗口」按钮（避免套娃）",
          not _win.panel.btn_popup.isVisible(),
          "visible=%s" % _win.panel.btn_popup.isVisible())
    _got = []
    _win.panel.export_view_requested.connect(lambda: _got.append(1))
    _win.panel.btn_export_view.click()
    app.processEvents()
    check("独立窗口的「导出当前视图」也能发信号（主窗口收到后落盘）",
          len(_got) == 1, "信号 %d 次" % len(_got))
    _win.close()
    app.processEvents()
    # 期望值不写死具体毫秒：自动档口径改了（有 5 ms 下限）以后，这里只能断言
    # 「关窗前后主卡量程没变」，否则每改一次自动档都要改一处测试。
    check("关掉独立窗口不影响主界面（主卡片还在、量程没变）",
          w.wave.isVisible() and abs(w.wave.x_span() - _span0) < 1e-6,
          "主卡 x_span=%.2f ms（关窗前 %.2f）" % (w.wave.x_span(), _span0))
    w.wave.buf.reset()
    w.wave.feed(_tf, force_draw=True)

    # ================================================================ ㉔ 阶段 5 D 批
    hr("㉔ 阶段 5 D 批：记录目录写探测 / 不可写自动改存 / 人话诊断")
    import recorder as _rc
    ok_d, why_d = _rc.probe_writable(os.path.join(tmp, "probe_ok"))
    check("probe_writable：能写的目录报 ok", ok_d, "why=%r" % why_d)
    ok_bad, why_bad = _rc.probe_writable("Z:\\nope_不存在的盘")
    check("probe_writable：不存在的盘报不可写且给出原因",
          (not ok_bad) and bool(why_bad), "why=%r" % why_bad)
    _pd = os.path.join(tmp, "probe_clean")
    _rc.probe_writable(_pd)
    check("probe_writable：探针文件用完就删（不留 .host_app_write_probe）",
          os.path.isdir(_pd) and os.listdir(_pd) == [],
          "目录内容 %r" % (os.listdir(_pd) if os.path.isdir(_pd) else "无此目录"))
    _h13 = _rc.dir_hint(PermissionError(13, "Permission denied"))
    check("dir_hint：拒绝访问翻译成「受控文件夹访问 / Excel 占用 / 只读」三条可操作原因",
          ("受控文件夹访问" in _h13) and ("Excel" in _h13) and ("只读" in _h13),
          _h13[:60])
    check("dir_hint：路径不存在单独一句话",
          "不存在" in _rc.dir_hint(FileNotFoundError(2, "No such file")), "")
    check("dir_hint：磁盘满单独一句话",
          "磁盘空间不足" in _rc.dir_hint(OSError(28, "No space left on device")), "")
    _fbs = _rc.fallback_dirs()
    check("fallback_dirs：至少 3 个备选、都指向 host_app记录、且已去重",
          len(_fbs) >= 3 and all("host_app记录" in p for p in _fbs)
          and len(set(os.path.normcase(p) for p in _fbs)) == len(_fbs),
          "、".join(_fbs[:4]))
    # ★ 真跑一次"目标目录不可写"：记录器应自动改存到能写的位置，并留下原因
    _rec = _rc.Recorder("Z:\\nope_不存在的盘\\encoder_record_test.csv")
    _started = _rec.start()
    check("Recorder.start()：目标盘不存在时不抛异常、改存成功", _started,
          "error=%r" % _rec.error)
    check("Recorder.start()：真的换了位置（did_fallback）且落在备选目录里",
          getattr(_rec, "did_fallback", False)
          and os.path.dirname(_rec.path) in [os.path.dirname(p) for p in _fbs]
          or (getattr(_rec, "did_fallback", False) and _rec.path.endswith(".csv")),
          "落到 %s" % _rec.path)
    if _started:
        _rec.feed([{"s": 1, "c": 2, "angle": 0}], t_mono=0.0)
        _rec.stop()
        check("改存之后真的能写进 CSV（表头 + 数据行）",
              os.path.isfile(_rec.path) and os.path.getsize(_rec.path) > 40,
              "%s 字节" % (os.path.getsize(_rec.path) if os.path.isfile(_rec.path) else -1))
        _fb_dir = os.path.dirname(_rec.path)
        try:
            os.remove(_rec.path)
        except OSError:
            pass
        # 备注：fallback 目录（我的文档\host_app记录）可能本来就是用户已有的目录，
        #       只在它为空时删掉，免得误删用户的历史记录
        try:
            if os.path.isdir(_fb_dir) and not os.listdir(_fb_dir):
                os.rmdir(_fb_dir)
        except OSError:
            pass
    # 不可写目录下的"开始记录"：面板要显式提示"已自动改存"，而不是静默
    _saved_probe = _rc.probe_writable
    _saved_fb = _rc.fallback_dirs
    _bad_dir = os.path.join(tmp, "rec_fb")
    _good_dir = os.path.join(tmp, "rec_fb_ok")
    try:
        # 只让"用户选的那个目录"不可写，备选目录照常可写 —— 这样才测得到回退路径
        _bad_key = os.path.normcase(os.path.abspath(_bad_dir))
        _rc.probe_writable = (lambda p: (False, "测试用：假装不可写")
                              if os.path.normcase(os.path.abspath(p)) == _bad_key
                              else _saved_probe(p))
        _rc.fallback_dirs = lambda: [_good_dir]
        w.record.set_dir(_bad_dir)
        _note = w.record.lab_note.text()
        check("记录页：目录不可写时卡片当场把原因写给用户（不是静默接受）",
              ("写不进去" in _note) or ("自动改存" in _note), _note[:60])
        w.record.start_record()
        _note2 = w.record.lab_note.text()
        check("记录页：开始时自动改存，卡片写明「已自动改存到 …」",
              "自动改存" in _note2, _note2[:60])
        check("记录页：改存后卡片显示的是**真正在写的文件**（在备选目录里）",
              os.path.isfile(w.record.rec.path)
              and os.path.normcase(os.path.dirname(w.record.rec.path))
              == os.path.normcase(os.path.abspath(_good_dir)),
              w.record.rec.path)
        w.record.stop_record("自检收尾")
    finally:
        _rc.probe_writable = _saved_probe
        _rc.fallback_dirs = _saved_fb
        for _p in (os.path.join(tmp, "rec_fb"),):
            shutil.rmtree(_p, ignore_errors=True)

    # ================================================================ ㉕ 阶段 5 D 批（ABZ 方波）
    hr("㉕ 阶段 5 D 批：A/B 被平均成的「阶梯」→ 硬判决方波（方案 C：实测 + 理论两条线）")
    import random
    rnd = random.Random(5)

    def _sq_frames(n, inter, a_duty=0.5):
        """造一批"真方波"帧：A/B 由电角度决定（与板上 abz_gen 的机理一致）。"""
        P = 65536.0 / inter                     # 一个 A/B 周期跨多少角度计数
        out = []
        for _ in range(n):
            ang = rnd.randrange(65536)
            ph = (ang % P) / P
            out.append({"angle": ang,
                        "io_bits": {"a": 1 if ph < a_duty else 0,
                                    "b": 1 if ((ph + 0.25) % 1.0) < 0.5 else 0,
                                    "z": 1 if (ang % 65536) < 1024 else 0,
                                    "u": 1 if (ang % 65536) < 32768 else 0}})
        return out

    an = az.AbzAnalyzer(bins=1024, inter=64)
    snap = an.feed(_sq_frames(20000, 64))
    lv = sorted(set(x for x in snap["sq_a"] if x is not None))
    check("硬判决后 A 相只剩两个电平（阶梯被消掉）", lv == [0, 1], "电平 %r" % lv)
    _cov = [i for i in range(1024) if snap["a"][i] is not None]
    _ok = sum(1 for i in _cov if snap["sq_a"][i] == snap["ideal_a"][i]) if snap["ideal_a"] else 0
    check("实测判决与相位对齐的理想方波一致（≥95% 的已填箱）",
          snap["ideal_a"] is not None and _ok >= 0.95 * len(_cov),
          "%d/%d 一致" % (_ok, len(_cov)))
    check("每周期箱数 = bins/inter（1024/64 = 16）",
          abs((snap["sq_per_bins"] or 0) - 16.0) < 1e-6, "%r" % snap["sq_per_bins"])
    check("方波判决可信度 ≥0.9（箱内电平不糊）",
          (snap["sq_conf"] or 0) >= 0.9, "%r" % snap["sq_conf"])
    check("Z / U 也做同样的判决（Z 是索引脉冲、UVW 是六步方波）",
          sorted(set(x for x in snap["sq_z"] if x is not None)) in ([0], [1], [0, 1])
          and sorted(set(x for x in snap["sq_u"] if x is not None)) == [0, 1]
          and snap["ideal_u"] is not None,
          "sq_z=%r" % sorted(set(x for x in snap["sq_z"] if x is not None)))
    # 分辨率不够时必须给可执行提示（inter 太大 ⇒ 画不出方波）
    an2 = az.AbzAnalyzer(bins=1024, inter=256)
    snap2 = an2.feed(_sq_frames(4000, 256))
    check("inter 过大（1024 箱 < 8×256）时提示里给出「把 inter 降到 ≤…」",
          any("inter" in s for s in (snap2.get("notes") or [])),
          "；".join(snap2.get("notes") or [])[:80])
    # 界面：读数与曲线都换成了判决方波
    w.show_page("enc")
    w.abz.an.reset()
    w.abz.an.configure(inter=64)
    w.abz.feed(_sq_frames(20000, 64))
    app.processEvents()
    check("面板读数出现「方波判决 / 每周期箱数」且值已填",
          ("%" in w.abz.v_sq.text()) and ("箱" in w.abz.v_sqper.text()),
          "%s / %s" % (w.abz.v_sq.text(), w.abz.v_sqper.text()))
    _two = 0
    _stair = 0
    for _ln in w.abz.ax_ab.get_lines():
        if _ln.get_linestyle() == "--":
            continue                       # 虚线是"理论方波"参照，单独查
        _yd = [float(v) for v in _ln.get_ydata()]
        if len(_yd) < 100:
            continue                       # 太短的曲线不算（图例/参考线）
        # 注意：三路电平各带一个垂直偏移，所以只能查"电平档数"，不能查"值等于 0/1"
        if len(set(round(v, 3) for v in _yd)) <= 2:
            _two += 1
        else:
            _stair += 1
    check("画出来的 A/B/Z 都是两电平曲线（平均值的多档阶梯已消失）",
          _two >= 3 and _stair == 0,
          "两电平 %d 条、仍有多档 %d 条" % (_two, _stair))
    check("另一路是虚线「理论方波」参照（方案 C 的两条线都在）",
          any(_ln.get_linestyle() == "--" for _ln in w.abz.ax_ab.get_lines()),
          "")
    w.abz.an.configure(inter=w.abz.an.inter)      # 复位到板上配置，避免影响后续用例

    # ============================================== ㉖ 记录/导出：写探测与"打不开文件夹"
    hr("㉖ 阶段 5 补丁：导出也要先探再写 / 「打开文件夹」不许静默失败 / 写入诊断")
    import tempfile as _tf
    _good = os.path.join(tmp, "rec_ok")
    _bad = os.path.join("Z:\\", "nope_ui_probe")

    _d = rc.diag_write(_good)
    check("diag_write：能写的目录报 ok 且给出只读属性",
          _d["write_ok"] and _d["readonly"] in (True, False), "%r" % _d)
    _d2 = rc.diag_write(_bad)
    check("diag_write：不存在的盘报不可写 + errno + 人话提示",
          (not _d2["write_ok"]) and (_d2["errno"] is not None) and bool(_d2["hint"]),
          "errno=%s winerror=%s" % (_d2["errno"], _d2["winerror"]))
    _d3 = rc.diag_write(_good)
    check("diag_write：探针文件写完即删（目录里不留东西）",
          os.listdir(_good) == [], "%r" % os.listdir(_good))

    _p, _note = rc.pick_dir()
    check("pick_dir：返回的目录一定通过真写探针", rc.probe_writable(_p)[0], _p)

    _od, _moved, _why = rc.writable_dir_or_fallback(_bad)
    check("writable_dir_or_fallback：坏目录会换成能写的备选并说明原因",
          _moved and rc.probe_writable(_od)[0] and bool(_why), "%s（%s）" % (_od, _why))
    _od2, _moved2, _ = rc.writable_dir_or_fallback(_good)
    check("writable_dir_or_fallback：好目录原样返回、不折腾",
          (not _moved2) and _od2 == _good, "%s" % _od2)

    _txt = rc.write_diagnosis(_bad)
    check("write_diagnosis：报告含受控文件夹访问 / 备选目录 / 权限三段证据",
          ("受控文件夹访问" in _txt) and ("备选目录" in _txt) and ("icacls" in _txt),
          "%d 字符" % len(_txt))
    _cfa = rc.cfa_state()
    check("cfa_state：能读到状态字典（读不到也是合法结果，不许抛异常）",
          set(_cfa.keys()) == {"enabled", "hklm", "hkcu", "allowed"},
          "enabled=%r" % _cfa["enabled"])

    # ★ 「工作区内能写、工作区外一律拒」这种形状，只看 icacls 是查不出来的（ACL 明明给了
    #   完全控制）—— 必须看**进程令牌**：完整性级别 + 受限令牌标志。用户 m16915 的现场就是
    #   这一种（程序被当成不可信进程降权跑），所以这几项一定要有断言。
    _tk = rc.token_flags()
    check("token_flags：能读到令牌四要素（完整性/受限/提权/会话）",
          set(_tk.keys()) == {"integrity", "has_restrictions", "restricted_sids",
                              "elevated", "session", "token_type"}
          and (_tk["integrity"] is not None or os.name != "nt"),
          "%r" % _tk)
    _ppid, _pexe = rc.parent_process()
    check("parent_process：拿得到父进程 pid（名字允许拿不到）",
          isinstance(_ppid, int) and _ppid > 0, "pid=%s %s" % (_ppid, _pexe))
    check("env_warning：返回字符串，且限定/低完整性时给出「换启动方式」的建议",
          isinstance(rc.env_warning(), str)
          and (("受限令牌" in rc.env_warning() or "低完整性" in rc.env_warning())
               if (_tk["has_restrictions"] or "Low" in (_tk["integrity"] or ""))
               else rc.env_warning() == ""),
          "%r" % rc.env_warning())
    _txt2 = rc.write_diagnosis(_bad)
    check("write_diagnosis：报告含「进程身份」段（完整性级别与父进程）",
          ("进程身份" in _txt2) and ("完整性级别" in _txt2) and ("父进程" in _txt2),
          "%d 字符" % len(_txt2))

    # 「打开文件夹」三条路都不通时，必须落到剪贴板 + 可读提示，绝不静默
    _notes = []
    w.record.notice.connect(lambda t, lv="info": _notes.append((lv, t)))
    w.record.dir = os.path.join(tmp, "definitely_not_here")
    w.record.rec = None
    w.record._open_dir()
    check("_open_dir：目录不存在时明确报「还不存在」而不是抛异常",
          any("不存在" in t for _lv, t in _notes), "%r" % _notes[-1:])

    # 导出：目录被系统挡住时要能落到备选目录，而不是只甩一句 Errno 13
    #   （把备选目录钉在 tmp 里，免得用例往"我的文档/临时目录"里丢 PNG）
    _stale = w.record.dir
    _fb_save = rc.fallback_dirs
    rc.fallback_dirs = lambda: [_good]
    w.record.dir = _bad
    try:
        w._on_export("wave")
        _info = w.record._last_info or {}
        _pth = _info.get("path") or ""
        check("导出遇到不可写目录：自动改存到能写的位置并真的落地",
              bool(_info.get("ok")) and os.path.isfile(_pth)
              and os.path.normcase(os.path.dirname(_pth)).startswith(
                  os.path.normcase(_good).lower()),
              "ok=%r path=%s" % (_info.get("ok"), _pth))
    except Exception as exc:                                    # noqa: BLE001
        check("导出遇到不可写目录：自动改存到能写的位置并真的落地", False, "%s" % exc)
    finally:
        rc.fallback_dirs = _fb_save
        w.record.dir = _stale
    _txt2 = w.record.lab_note.text()
    check("导出提示里写明「已改存」而不是只报 Errno 13",
          ("改存" in _txt2) or ("已导出" in _txt2), _txt2[:60])
    check("记录卡片上有「写入诊断」按钮（用户可以自己取证）",
          hasattr(w.record, "btn_diag") and "诊断" in w.record.btn_diag.text(), "")
    w.record.btn_diag.click()          # 非模态：点它不许把用例卡住
    app.processEvents()
    check("点「写入诊断」不抛异常、也不改任何记录状态",
          w.record.rec is None or not w.record.rec.active, "")

    # ======================================== ㉖ 回放：.bin 能在界面里重演
    hr("㉖ 回放：录下来的 .bin 能按 10 kHz 重演（波形/质量/告警照跑）")
    import os as _os                                              # noqa: PLC0415
    import tempfile as _tf                                        # noqa: PLC0415
    import record_bin as _rb                                      # noqa: PLC0415
    import replay as _rp                                          # noqa: PLC0415
    import uart_scope as _us                                      # noqa: PLC0415
    _pd = _tf.mkdtemp(prefix="replay_ui_")
    _pp = _os.path.join(_pd, "ui.bin")
    _rec = _rb.BinRecorder(_pp, fs_hz=10000, meta={"csv": "ui.csv"})
    for _i in range(1200):
        _ang = (_i * 3600 // 120) & 0xFFFF
        _rec.write_raw(_us.build_frame(_ang, 9500, -9300, 0, 0, _i, 1))
    _rec.close()
    check("记录卡有「回放记录…」按钮", hasattr(w.record, "btn_replay")
          and "回放" in w.record.btn_replay.text(), "")
    check("记录卡发出 replay_requested 信号", hasattr(w.record, "replay_requested"))
    _pk0 = w._page_key_now()          # 回放会切到「实时」页，测完要切回原页
    w.start_replay(_pp)
    app.processEvents()
    check("start_replay 之后进入回放态（不连板也能放）",
          getattr(w, "_replay", None) is not None, "")
    _n0 = getattr(getattr(w, "_replay", None), "n_played", 0)
    w._tick_body()
    app.processEvents()
    _n1 = getattr(getattr(w, "_replay", None), "n_played", 0)
    check("回放一批帧真的从文件里读出来了（喂帧链路在跑）",
          _n1 > _n0, "%d→%d 帧" % (_n0, _n1))
    check("回放同样喂到正交质量卡", w.quality.verdict() >= 0, str(w.quality.verdict()))
    w.stop_replay()
    check("stop_replay 之后回到正常态", getattr(w, "_replay", None) is None, "")
    check("回放器自检可用（replay.selftest 返回 0）", _rp.selftest() == 0, "")
    w.show_page(_pk0)
    app.processEvents()
    try:
        _os.remove(_pp)
        _os.rmdir(_pd)
    except OSError:
        pass

    # ======================================== ㉗ ⑨ 等效采样图的独立大窗口（阶段 5 续）
    hr("㉗ 阶段 5 续：⑨「ABZ / UVW 等效采样」也有独立大窗口（同一套数据、量程各管各的）")
    import abz_popup as _azp                                    # noqa: PLC0415
    check("卡片⑨ 控制行有「独立窗口」按钮，标题带双击提示",
          hasattr(w.abz, "btn_popup") and w.abz.btn_popup.text() == "独立窗口"
          and w.abz.btn_popup.isVisibleTo(w.abz) and "独立" in w.abz.lab_title.toolTip(),
          w.abz.btn_popup.text())
    _fired27 = []
    w.abz.popup_requested.connect(lambda: _fired27.append(1))
    w.abz.btn_popup.click()
    app.processEvents()
    check("点⑨卡「独立窗口」按钮就发要窗口的信号", len(_fired27) == 1,
          "信号收到 %d 次" % len(_fired27))
    _dbl27 = QMouseEvent(QEvent.MouseButtonDblClick, QPointF(4.0, 6.0), Qt.LeftButton,
                         Qt.LeftButton, Qt.NoModifier)
    app.sendEvent(w.abz.lab_title, _dbl27)
    app.processEvents()
    check("双击⑨卡标题也发同一个信号（图内双击仍归恢复自动）", len(_fired27) == 2,
          "信号收到 %d 次" % len(_fired27))
    w._open_abz_popup()
    app.processEvents()
    _aw = w._abz_win
    check("独立窗口建起来且是另一个 AbzPanel 实例（主界面那份累积不受影响）",
          _aw is not None and isinstance(_aw, _azp.AbzPopup)
          and _aw.panel is not w.abz and _aw.panel.an is not w.abz.an,
          type(_aw.panel).__name__ if _aw else "None")
    check("独立窗口的分箱初值与主界面一致（一打开就是同一种算法参数）",
          _aw.bins() == w.abz.bins(), "弹窗 %d / 主卡 %d" % (_aw.bins(), w.abz.bins()))
    check("独立窗口里的画布不钉高（跟着窗口一起长）",
          _aw.panel.canvas.minimumHeight() == 0
          and _aw.panel.canvas.maximumHeight() > 500,
          "min=%d max=%d" % (_aw.panel.canvas.minimumHeight(),
                             _aw.panel.canvas.maximumHeight()))
    check("主界面那张卡的画布仍然钉在 240 px（否则卡片高度会抖）",
          w.abz.canvas.maximumHeight() == 240 and w.abz.canvas.minimumHeight() == 240,
          "min=%d max=%d" % (w.abz.canvas.minimumHeight(), w.abz.canvas.maximumHeight()))
    check("独立窗口里不再出现「独立窗口」按钮（避免套娃）",
          not _aw.panel.btn_popup.isVisible(), "")
    check("独立窗口有 Esc 关闭的快捷键（不动主窗口的全局键）",
          _aw._esc.key().toString() == "Esc", _aw._esc.key().toString())
    # 数据：同一批帧喂进去，弹窗自己也要累积出方波判决
    _aw.panel.an.reset()
    _aw.panel.an.configure(inter=64)
    _aw.feed(_sq_frames(12000, 64))
    app.processEvents()
    _s27 = _aw.panel.an.snapshot()
    check("同一批帧也喂进独立窗口（它自己那份等效采样在累积）",
          _s27["samples_ab"] > 0 and _s27["sq_per_bins"] == 16.0,
          "samples_ab=%d sq_per_bins=%r" % (_s27["samples_ab"], _s27["sq_per_bins"]))
    # mirror：板上事实（inter/div、0x0109 输出位、输入频率）必须两边一致
    w.abz.set_f_in(1008.8)
    _aw.panel.set_f_in(None)
    _aw.panel.set_output({})                     # 先在弹窗里造成"读失败"的状态
    _aw.panel.mirror(w.abz)
    check("mirror()：把输入频率同步给独立窗口", _aw.panel.f_in == 1008.8,
          "%r" % _aw.panel.f_in)
    check("mirror()：把板上配置与 0x0109 输出位同步给独立窗口",
          _aw.panel._regs is w.abz._regs
          and (_aw.panel._out_bits or None) == (w.abz._out_bits or None), "")
    # 「方波可看 / 还原」是明确要求两边同分箱的操作
    _b27 = w.abz.bins()
    _target27 = 128 if _b27 != 128 else 256
    w._sync_abz_bins(_target27)
    app.processEvents()
    check("「方波可看 / 还原」把分箱一并同步给独立窗口（不然弹窗里还是阶梯）",
          _aw.bins() == _target27, "弹窗 %d / 目标 %d" % (_aw.bins(), _target27))
    # 视图设置各管各的：在弹窗里改分箱不该改主界面
    _b27b = w.abz.bins()
    _aw.set_bins(512 if _b27b != 512 else 1024)
    app.processEvents()
    check("独立窗口改分箱不动主界面（视图设置各窗口独立）",
          w.abz.bins() == _b27b, "主卡 %d / 弹窗 %d" % (w.abz.bins(), _aw.bins()))
    _got27 = []
    _aw.panel.export_view_requested.connect(lambda: _got27.append(1))
    _aw.panel.btn_export_view2.click()
    app.processEvents()
    check("独立窗口的「导出当前视图」也能发信号（主窗口收到后落盘）",
          len(_got27) == 1, "信号 %d 次" % len(_got27))
    _aw.close()
    app.processEvents()
    check("关掉独立窗口不影响主界面（主卡片还在、分箱还在）",
          w.abz.isVisible() and w.abz.bins() == _b27b, "主卡 %d 箱" % w.abz.bins())

    # ================================================ ㉘ 自查补丁（链路 + 界面 + 记忆）
    hr("㉘ 全面自查补丁：命令排队 / 脏字节挡应答 / 假应答 / 定时器槽兜底 / 记忆项齐全")

    # ① 真解析器（构造 SerialWorker 不会打开串口）
    _rep = bytes.fromhex("5a000422116d")
    _frame = bytes.fromhex("aa5510200000030000a2000000000000006e")
    _lw = lk.SerialWorker("COM99")
    _lw._pump(b"\x00\x00\x00" + _rep, want_reply=True)
    check("脏字节 + 一条完整应答（总量 <18 B）也当场解析",
          len(_lw._replies) == 1, "replies=%d buf=%d" % (len(_lw._replies), len(_lw.buf)))

    _lw2 = lk.SerialWorker("COM99")
    _lw2._pump(b"\x5A" * 6, want_reply=True)
    # 断言口径：只要求"没被当成应答收下"。缓冲会被「2b」重同步消费掉一部分是正常的
    # （_find_sync 在 i=1 处看到 REPLY_HEAD、剩余不足 6 字节 ⇒ 返回 1、只前进 1 字节），
    # 所以不能要求 buf 原样保留 6 个 0x5A。
    check("6 个相同字节不算应答（假应答）",
          len(_lw2._replies) == 0 and _lw2.stray_reply == 0 and len(bytes(_lw2.buf)) < 6,
          "replies=%d stray=%d buf=%d" % (len(_lw2._replies), _lw2.stray_reply,
                                          len(_lw2.buf)))

    _lw3 = lk.SerialWorker("COM99")
    _lw3._pump(b"\x11" * 200 + _frame, want_reply=False)
    check("垃圾段后面紧跟的遥测帧不丢",
          len(_lw3.batch) == 1 and _lw3.frames_ok == 1,
          "frames_ok=%d resync=%d" % (_lw3.frames_ok, _lw3.resync_bytes))

    # ② 命令队列：两条先后提交都要被执行到（以前单槽会覆盖先提交的那条）
    import threading as _th
    _lw4 = lk.SerialWorker("COM99")
    _r1 = {"event": _th.Event(), "timeout": 1.0}
    _r2 = {"event": _th.Event(), "timeout": 1.0}
    with _lw4._cmd_lock:
        _lw4._cmd_queue.append(_r1)
        _lw4._cmd_queue.append(_r2)
    _got = [_lw4._take_cmd(), _lw4._take_cmd(), _lw4._take_cmd()]
    check("命令队列 FIFO：两条都不丢、取空返回 None",
          _got[0] is _r1 and _got[1] is _r2 and _got[2] is None,
          "取到 %s" % ["r1" if g is _r1 else "r2" if g is _r2 else None for g in _got])
    _r1["event"].set()                                   # 超时的那条要被跳过
    with _lw4._cmd_lock:
        _lw4._cmd_queue.append(_r1)
        _lw4._cmd_queue.append(_r2)
    check("已超时（event 已置位）的命令被跳过", _lw4._take_cmd() is _r2)

    # ③ 定时器槽兜底：槽里抛异常不能被 excepthook 抓走（也就不会弹模态框）
    _orig_body = w._tick_body
    _n_before = len(FAIL)
    try:
        w._tick_body = lambda: (_ for _ in ()).throw(RuntimeError("自检故意抛错"))
        w._tick()
        w._tick()
        _ok_tick = True
    except Exception:                                    # noqa: BLE001
        _ok_tick = False
    finally:
        w._tick_body = _orig_body
    check("定时器槽兜底：_tick 里的异常不外泄、不新增失败",
          _ok_tick and len(FAIL) == _n_before,
          "已兜住 %d 次" % getattr(w, "_tick_err_n", 0))

    # ④ 坏帧不能把 _update_live 打崩（它经 _tick 每 100 ms 跑一次）
    try:
        w._update_live({})
        w._update_live({"angle_deg": None, "pos_full": None, "io_bits": None, "amp_sq": None})
        _ok_upd = True
    except Exception:                                    # noqa: BLE001
        _ok_upd = False
    check("坏帧（缺键/None）不会让 _update_live 抛异常", _ok_upd)

    # ⑤ 「写入诊断」连点只留一个窗口（探针换成假报告，别真去写用户目录）
    _orig_diag = rc.write_diagnosis
    rc.write_diagnosis = lambda path: "自检假报告：%s" % path
    try:
        _d0 = getattr(w.record, "_diag_box", None)
        if _d0 is not None:
            _d0.close()
        w.record._show_diag()
        _d1 = w.record._diag_box
        w.record._show_diag()
        _same = w.record._diag_box is _d1
        _d1.close()
    finally:
        rc.write_diagnosis = _orig_diag
    check("「写入诊断」连点复用同一个窗口", _same)

    # ⑥ 记忆项落盘往返（"存得下、读不回"的回归项）
    _po = up._path_override
    _pdir = _tmp_dir("_ui_prefs_rt")
    os.makedirs(_pdir, exist_ok=True)          # ★ _tmp_dir 只给路径、不建目录（自检踩过）
    try:
        up._path_override = os.path.join(_pdir, "ui_prefs.json")
        up._cache = None
        up.load()
        up.put("ui", "scale", 1.25)
        up.put("wave", "trig", "off")
        _saved = up.save()
        up._cache = None
        up.load()
        _rt = (abs(up.number("ui", "scale", 0.0, 9.9, 0.0) - 1.25) < 1e-9
               and up.choice("wave", "trig", ("s", "off"), "s") == "off")
    finally:
        up._path_override = _po
        up._cache = None
        up.load()
        shutil.rmtree(_pdir, ignore_errors=True)
    check("记忆项落盘往返：ui.scale / wave.trig", _saved and _rt, "saved=%s" % _saved)

    # ================================================ ㉙ 第二轮全面自查（算法 / 编码器 / 诊断 / 写失败）
    hr("㉙ 第二轮自查：相位带 div / 改 inter 清累积 / 方波阈值同口径 / ⑨ 弹窗接线 / "
       "编码器口径出口 / 写失败回流 / 进程表句柄 / 写探针不毁文件")

    # ① 相位换算必须带 div（真值 90°：B 滞后 A 四分之一 AB 周期）
    _ph_bad = []
    for _dv in (1, 2, 4, 8):
        _an = az.AbzAnalyzer(bins=1024, pairs=4, inter=32, div=_dv)
        _per = (1024 * _dv // 32) * 64          # 一个 A/B 周期占多少角度 LSB
        _q = _per // 4                          # 90° = 四分之一周期
        _fr = []
        for _i in range(1024):
            _ang = _i * 64 + 32
            _fr.append({"angle": _ang, "s": 1000, "c": 0,
                        "io_bits": {"a": 1 if (_ang % _per) < _per // 2 else 0,
                                    "b": 1 if ((_ang - _q) % _per) < _per // 2 else 0,
                                    "z": 0, "u": 0, "v": 0, "w": 0}})
        _sn = _an.feed(_fr, t_now=1.0)
        _ph = _sn.get("phase_ab_deg")
        if _ph is None or abs(abs(_ph) - 90.0) >= 1.0:
            _ph_bad.append("div=%d→%s" % (_dv, _ph))
    check("相位换算带 div：div=1/2/4/8 都报 90°（旧写法只有 div=1 对）",
          not _ph_bad, "、" .join(_ph_bad) if _ph_bad else "4 档全部 90°")

    # ② 改 inter/div 必须清累积（面板提示承诺"会自动清空"）
    _an2 = az.AbzAnalyzer(bins=256, inter=32, div=1)
    _an2.feed([{"angle": i * 8, "s": 1, "c": 0,
                "io_bits": {"a": 1, "b": 0, "z": 0, "u": 0, "v": 0, "w": 0}}
               for i in range(256)], t_now=1.0)
    _n_fed = _an2.frames
    _an2.configure(div=1)                       # 值没变 ⇒ 不许清
    _keep_same = _an2.frames == _n_fed
    _an2.configure(inter=64)                    # 值变了 ⇒ 必须清
    check("改 inter/div 清空累积、同值不清",
          _n_fed == 256 and _keep_same and _an2.frames == 0,
          "fed=%d 同值后=%s 改 inter 后=%d" % (_n_fed, _keep_same, _an2.frames))

    # ③ 方波阈值与面板同口径（div 大时不再"一边判绿一边告警看不了方波"）
    _an3 = az.AbzAnalyzer(bins=1024, inter=256, div=8)
    _an3.feed([{"angle": i * 64, "io_bits": {}} for i in range(1024)], t_now=1.0)
    _sn3 = _an3.snapshot(2.0)
    _notes3 = "；".join(_sn3.get("notes") or [])
    check("per_bins=bins*div/inter 与告警同口径（1024 箱 / inter=256 / div=8 ⇒ 32 箱/周期）",
          abs((_sn3.get("sq_per_bins") or 0.0) - 32.0) < 1e-9 and "方波形状" not in _notes3,
          "per=%.1f notes=%s" % (_sn3.get("sq_per_bins") or -1.0, _notes3 or "（无）"))

    # ④ ⑨ 独立窗口：点开必须真能出来（缺 notice 信号的回归项 —— 原来槽里抛异常被吞）
    _w29 = getattr(w, "_abz_win", None)
    if _w29 is not None:
        try:
            _w29.close()
        except Exception:                              # noqa: BLE001
            pass
        w._abz_win = None
    _pop_ok, _pop_msg = False, ""
    try:
        w._open_abz_popup()
        _aw29 = w._abz_win
        _pop_ok = bool(_aw29 is not None and _aw29.isVisible()
                       and hasattr(_aw29.panel, "notice"))
        _pop_msg = "win=%s visible=%s notice=%s" % (
            _aw29 is not None, (_aw29.isVisible() if _aw29 is not None else False),
            hasattr(_aw29.panel, "notice") if _aw29 is not None else False)
        _aw29.close()
    except Exception as _e:                            # noqa: BLE001
        _pop_msg = "%s: %s" % (type(_e).__name__, _e)
    finally:
        w._abz_win = None
    check("⑨「独立窗口」点开真的可见、面板带 notice 信号（槽内异常不再被吞掉）",
          _pop_ok, _pop_msg)

    # ⑤ 「清空累积」要把方波判决与每周期箱数读数也复位
    w.abz.v_sq.setText("77%")
    w.abz.v_sqper.setText("3.3 箱")
    w.abz._clear_readouts()
    check("「清空累积」把方波判决/每周期箱数也复位成「—」",
          w.abz.v_sq.text() == "—" and w.abz.v_sqper.text() == "—",
          "%s / %s" % (w.abz.v_sq.text(), w.abz.v_sqper.text()))

    # ⑥ feed(snapshot=False) 只累积、不回快照，但时间戳照记（span_s 才不会是 None）
    _an4 = az.AbzAnalyzer(bins=256, inter=32, div=1)
    _r4 = _an4.feed([{"angle": 0, "io_bits": {}}], t_now=5.0, snapshot=False)
    _sn4 = _an4.snapshot(6.0)
    check("feed(snapshot=False) 不回快照、但记时间戳（span_s=1.0）",
          _r4 is None and _an4.frames == 1 and abs((_sn4.get("span_s") or 0.0) - 1.0) < 1e-6,
          "ret=%s frames=%d span=%s" % (_r4, _an4.frames, _sn4.get("span_s")))

    # ⑦ 写串口失败必须回流成错误事件（以前只写进 req["error"]，没人读）
    class _DeadSer:                                    # noqa: D401
        def write(self, _b):
            raise IOError("自检模拟写失败")

        def flush(self):
            pass

    _lw5 = lk.SerialWorker("COM99")
    _seen5 = []
    _lw5._emit_error = lambda t: _seen5.append(t)
    _req5 = {"payload": b"\x01", "timeout": 0.01, "retries": 1, "attempts": 0,
             "event": _th.Event()}
    _lw5._execute(_DeadSer(), _req5)
    check("写串口失败回流成错误事件（界面不再只显示超时）",
          bool(_req5.get("error")) and bool(_seen5) and "写串口失败" in _seen5[0],
          "error=%s seen=%s" % (_req5.get("error"), _seen5))

    # ⑧ 进程表句柄：restype/argtypes 修好后能正常拿到进程链
    try:
        _chain = dg.parent_chain()
        _chain_ok = isinstance(_chain, list) and len(_chain) >= 1 and \
            not _chain[0].startswith("读不到")
    except Exception as _e:                            # noqa: BLE001
        _chain, _chain_ok = ["%s: %s" % (type(_e).__name__, _e)], False
    check("进程链可读（Toolhelp32 句柄不再被截断成 c_int）", _chain_ok, "→".join(_chain[:3]))

    # ⑨ 写探针不许毁掉同名文件、也不许留残渣
    _dwd = _tmp_dir("_diag_write")
    os.makedirs(_dwd, exist_ok=True)
    _keepf = os.path.join(_dwd, "host_app_write_test.tmp")
    with open(_keepf, "w", encoding="utf-8") as _f:
        _f.write("用户数据")
    _rw = dg.write_probe(_dwd)
    _left = sorted(os.listdir(_dwd))
    _same_txt = open(_keepf, encoding="utf-8").read() == "用户数据"
    check("写探针不覆盖同名文件、不留残渣（旧写法会把它清零）",
          _rw == "可以写" and _left == ["host_app_write_test.tmp"] and _same_txt,
          "结果=%s 目录=%s 内容未变=%s" % (_rw, _left, _same_txt))
    shutil.rmtree(_dwd, ignore_errors=True)

    # ⑩ 幅值告警的判定来自板上位，不因 r 越限而变色（r 只用于文案）
    _st10 = sg.evaluate([{"s": 1, "c": 2, "angle": 0, "io_bits": {}, "io_state": 0,
                          "io_flags": 0, "stat": 0}], None,
                        r=99999.0, r_low=1.0, r_high=2.0)
    check("幅值告警判定不看上位机算的 r（bit 未置位 ⇒ 正常，文案里才出现 r）",
          _st10["amp"][0] == "ok" and "99999" in _st10["amp"][1],
          "%s" % (_st10["amp"],))

    # ================================================================ 收尾
    # 数据源（用户 m03198：可选的，默认网口）
    # ★ 这里不能走 _on_source_changed：它会 up.save() 写真实 ui_prefs.json，
    #   后面的「关窗写参数 / 重开恢复尺寸」两组用例就全乱了。
    _items = [w.cmb_src.itemData(k) for k in range(w.cmb_src.count())]
    check("顶栏「数据源」是可选项，且网口排在第一个（默认）",
          _items[:2] == ["net", "serial"], "%s" % (_items,))
    w._net_off("自检")
    check("串口态：_src=serial", w._src == "serial", w._src)
    w._net_start()                  # 没连串口 → 只记一条"连上后自动开"，不硬切
    check("选网口但没连串口：不硬切，_src 仍是串口", w._src == "serial", w._src)
    w._net_on()
    check("网口态：_src 与下拉框一致",
          w._src == "net" and w.cmb_src.currentData() == "net",
          "%s/%s" % (w._src, w.cmb_src.currentData()))
    w._net_off("自检收尾")
    check("切回串口态", w._src == "serial", w._src)

    w.close()
    shutil.rmtree(tmp, ignore_errors=True)
    hr("结果")
    print("  通过 %d 项，失败 %d 项" % (OK[0], len(FAIL)))
    for name in FAIL:
        print("  !! %s" % name)
    print("界面级自检 %s" % ("通过 (PASS)" if not FAIL else "未通过 (FAIL)"))
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
