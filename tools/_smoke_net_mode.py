"""网口连续流整链路冒烟（不出板子、不发真网络，只灌 UDP 包）。

做三件事：起一个 StreamReceiver → 伪造 25 MSPS 的 (s,c) 连续流包发到它自己
→ 切到网口模式，手动跑几次 `_net_tick_body()` → 断言面板真的吃到了帧。

用法：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_net_mode.py
"""

import os
import socket
import struct
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))

import numpy as np
from PySide6.QtWidgets import QApplication

import main_window as mw
import stream_capture as sc

MAGIC = b"\xe7\x5a"
FS = 50e6
DEC = 0


def packets(f_hz=1000.0, n_pkt=6000, per=350, amp=20000.0):
    """按绝对样点序号生成连续流包（相位连续，和真板子一致）。"""
    out = []
    seq = 0
    first = 0
    for _ in range(n_pkt):
        idx = np.arange(first, first + per, dtype=np.float64)
        th = 2.0 * np.pi * f_hz * idx / FS
        s = np.round(amp * np.sin(th)).astype("<i2")
        c = np.round(amp * np.cos(th)).astype("<i2")
        body = np.empty(2 * per, dtype="<i2")
        body[0::2] = s
        body[1::2] = c
        hdr = MAGIC + bytes([sc.FLAG_STREAM, DEC]) + struct.pack(
            "<HIIH", seq & 0xFFFF, first & 0xFFFFFFFF, (first >> 32) & 0xFFFFFFFF, 0)
        out.append(hdr + body.tobytes())
        seq += 1
        first += per
    return out


def main():
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1400, 900)
    win.show()                 # 不 show 的话子控件 isVisible()=False，可见性门会挡掉喂帧
    app.processEvents()
    win.show_page("live")
    app.processEvents()

    r = sc.StreamReceiver(port=0, base_fs=FS)
    r.start()
    port = r.port
    print("[recv] 监听 127.0.0.1:%d" % port)

    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    pkts = packets()
    # 一个真包是 350 点（16 + 350*4 = 1416 B）；发太大的包会撞
    # WinError 10040（数据报比接收缓冲大），那不是被测代码的问题。
    for p in pkts:
        tx.sendto(p, ("127.0.0.1", port))
    time.sleep(1.5)

    win._stream = r
    win._net_on()
    a0 = win.v_angle.text()
    for _ in range(30):
        app.processEvents()
        win._net_tick_body()
        time.sleep(0.02)

    snap = r.snapshot_frames(10)
    buf = win.wave.buf.snapshot()
    print("[tap] step=%d 已抽 %d 帧" % (snap["step"], snap["head"]))
    print("[wave] 波形缓冲 %d 帧" % int(buf.get("n") or 0))
    print("[speed] f_in = %s" % (win._f_in,))
    print("[state] 数据源 = %s ｜ 下拉框 = %s"
      % (win._src, win.cmb_src.currentText()))

    ok = True
    if snap["step"] <= 1:
        print("FAIL 抽取步长没算出来"); ok = False
    # ★ 网口模式下波形吃的是**原始样点**（feed_raw），不是 10 kHz 帧，
    #   所以判据是 wave._raw（三元组 (s, c, fs)），不是 buf。
    _raw = getattr(win.wave, "_raw", None)
    if _raw is None or len(_raw[0]) <= 0:
        print("FAIL 真波形没拿到原始样点"); ok = False
    if int(buf.get("n") or 0) <= 0:
        print("[note] 帧缓冲 0 帧（网口模式波形不喂帧，属正常）")
    if not win._f_in:
        print("FAIL 输入频率没估出来"); ok = False
    else:
        print("[f_in] 估计值 %.1f Hz（真值 1000，短样本只作方向参考）"
              % float(win._f_in))

    # 实时数据预览卡（电角度/位置/s,c/r）必须跟着网口刷新 —— 用户报过
    # “这一页完全不刷新”，根因就是网口路径没有调 _update_live()。
    a1 = win.v_angle.text()
    print("[live] %s -> %s ｜ 位置 %s ｜ s/c %s ｜ r %s"
          % (a0, a1, win.v_pos.text(), win.v_sc.text(), win.v_r.text()))
    if a0 == a1:
        print("FAIL 实时数据预览没刷新（电角度没变）")
        ok = False
    if win.v_pos.text() in ("", "—") or win.v_sc.text() in ("", "—"):
        print("FAIL 实时数据预览的位置/s,c 还是空的")
        ok = False

    r.stop()
    if ok:
        print("SMOKE OK")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
