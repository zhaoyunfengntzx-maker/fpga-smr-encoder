"""回归：连接 → 断开 → 再连接后，网口要能重新起来（用户 m03633）。

没有板子也能测：用假 worker / 假 stream 把三种"残留态"摆出来，看
`_toggle_stream()` 是去"停流"还是去"开流"，以及 `_net_tick_body()`
在没流时会不会自动重开。

用法：$env:QT_QPA_PLATFORM="offscreen"; python -X utf8 tools\\_test_reconnect.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import queue  # noqa: E402

from PySide6.QtWidgets import QApplication  # noqa: E402

import main_window as mw  # noqa: E402

FAILS = []


def ck(name, cond, extra=""):
    if cond:
        print("  PASS %s" % name)
    else:
        FAILS.append(name)
        print("  FAIL %s %s" % (name, extra))


class FakeTask:
    """记录 task.run 被要求干什么，不真起线程。"""

    def __init__(self):
        self.tags = []

    def run(self, fn, tag):
        self.tags.append(tag)
        return True

    def pending(self):
        return 0

    def is_running(self):
        return False

    def shutdown(self, timeout=1.0):
        pass


class FakeStream:
    def __init__(self, running):
        self.running = running
        self.packets = 0
        self.stopped = False

    def stop(self):
        self.stopped = True
        self.running = False


class FakeWorker:
    def __init__(self):
        self.events = queue.Queue()
        self.alive = True

    def is_alive(self):
        return self.alive

    def stop(self, join_timeout=1.5):
        self.alive = False


def main():
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.show()
    win.task = FakeTask()               # 不真跑任务线程
    win.worker = FakeWorker()
    win._stream_params = {"src": 0, "dec_log2": 2}

    # 1) 残留一个"线程已死"的 stream：点「网口」必须去开流，而不是去停流
    dead = FakeStream(running=False)
    win._stream = dead
    win._src = "serial"
    win._toggle_stream(dict(win._stream_params))
    ck("死流时点网口走开流", "stream" in win.task.tags, str(win.task.tags))
    ck("死流残留被清掉", win._stream is None, repr(win._stream))

    # 2) 真正在跑的流：点「网口」应该停流
    win.task.tags = []
    live = FakeStream(running=True)
    win._stream = live
    win._stream_timer.stop()
    win._toggle_stream(dict(win._stream_params))
    ck("活流时点网口走停流", live.stopped and "stream" not in win.task.tags,
       str(win.task.tags))

    # 3) 没流 + 串口在线 + 偏好网口：刷新分支要自动重开（最多 3 次）
    win._stream = None
    win._src = "net"
    win._net_retry_n = 0
    win._net_warn_t = 0.0
    win.busy = False            # 上一步的开流把 busy 置了；真机上由 _on_task_done 清
    win._set_busy(False)
    win._set_src_combo("net")
    win.task.tags = []
    win._net_tick_body()
    ck("没流时自动重开一次", win._net_retry_n == 1 and "stream" in win.task.tags,
       "retry=%s tags=%s" % (win._net_retry_n, win.task.tags))

    # 4) 三次都失败后回落到串口
    win._net_retry_n = 3
    win._net_warn_t = 0.0
    win.task.tags = []
    win._net_tick_body()
    ck("三次失败后切回串口", win._src == "serial" and win._net_want is False,
       "src=%s" % win._src)

    # 5) 断开串口要把网口状态清干净
    win._src = "net"
    win._net_want = True
    win._net_retry_n = 2
    win._stream = FakeStream(running=True)
    win.disconnect_port()
    ck("断开后 _src 回串口", win._src == "serial", "src=%s" % win._src)
    ck("断开后 _net_want/_retry 归零",
       win._net_want is False and win._net_retry_n == 0,
       "want=%s retry=%s" % (win._net_want, win._net_retry_n))

    win.close()
    print()
    if FAILS:
        print("FAIL %d 项：%s" % (len(FAILS), ", ".join(FAILS)))
        return 1
    print("SMOKE OK（5 组断言全过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
