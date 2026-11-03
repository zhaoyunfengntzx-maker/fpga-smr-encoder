"""把阻塞操作丢进一条工作线程，完成后带 tag 把结果送回界面线程。

设计约束（改这个文件前先读）：
1. **只有一条线程**。串口是单主人模型，阻塞任务本来就该串行跑；连点十次也只是排队，
   不会留下一堆线程抢串口（旧实现一个任务起一条 daemon 线程，关窗也不等不取消）。
2. **异常必须变成"结果"送回去**，不能让线程静默死掉：`fn` 抛什么，就 `emit`
   什么（包在 `{"tag":…, "result": exc}` 里），界面据此亮错误而不是永远等下去。
3. `shutdown()` 之后不再接新任务；在跑的那个最多等 `timeout` 秒（daemon 线程不强杀）。
"""

from __future__ import annotations

import queue
import threading

from PySide6.QtCore import QObject, Signal


class TaskRunner(QObject):
    """串行任务队列：`run(fn, tag)` 排队，`done` 信号把 (tag, result) 送回界面线程。"""

    done = Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._q = queue.Queue()
        self._thread = None
        self._stop = False
        self._lock = threading.Lock()

    def run(self, fn, tag="task"):
        if self._stop:                       # 关窗后界面还在发任务：直接丢弃
            return False
        self._q.put((fn, tag))
        self._ensure_thread()
        return True

    def pending(self):
        return self._q.qsize()

    def is_running(self):
        t = self._thread
        return t is not None and t.is_alive()

    def _ensure_thread(self):
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop = False
            self._thread = threading.Thread(target=self._loop, daemon=True,
                                            name="host-task")
            self._thread.start()

    def _loop(self):
        while not self._stop:
            try:
                fn, tag = self._q.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                result = fn()
            except Exception as exc:                     # noqa: BLE001
                result = exc
            if self._stop:
                break
            self.done.emit({"tag": tag, "result": result})

    def shutdown(self, timeout=1.0):
        """关窗用：不再接新任务，等在跑的那个最多 timeout 秒（daemon 线程不强杀）。"""
        self._stop = True
        t = self._thread
        if t is not None and t.is_alive():
            t.join(timeout)


def _selftest():
    import time
    from PySide6.QtCore import Qt

    n = [0]
    bad = [0]

    def ck(name, cond, extra=""):
        n[0] += 1
        if not cond:
            bad[0] += 1
            print("  FAIL %s %s" % (name, extra))

    got = []
    lock = threading.Lock()

    def on_done(payload):
        with lock:
            got.append(payload)

    # 自检里没有 QApplication 事件循环 ⇒ 必须用直连，否则排队连接不会触发
    t = TaskRunner()
    t.done.connect(on_done, Qt.ConnectionType.DirectConnection)

    order = []

    def job(name, val=None, exc=None):
        def _run():
            order.append(name)
            if exc is not None:
                raise exc
            return val
        return _run

    t.run(job("a", 1), "ta")
    t.run(job("b", 2), "tb")
    t.run(job("c", exc=ValueError("坏了")), "tc")
    t.run(job("d", 4), "td")

    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        with lock:
            if len(got) >= 4:
                break
        time.sleep(0.01)

    with lock:
        payloads = list(got)
    ck("四个任务都回来了", len(payloads) == 4, str(payloads))
    ck("严格按入队顺序执行", order == ["a", "b", "c", "d"], str(order))
    ck("tag 原样带回", [p["tag"] for p in payloads] == ["ta", "tb", "tc", "td"])
    ck("结果正确", payloads[0]["result"] == 1 and payloads[3]["result"] == 4)
    ck("异常变成结果", isinstance(payloads[2]["result"], ValueError))
    ck("异常不影响后续任务", payloads[3]["result"] == 4)

    # 队列空 → 线程继续待着，pending() 归零
    time.sleep(0.3)
    ck("队列已排空", t.pending() == 0)
    ck("线程仍在跑（等下一个任务）", t.is_running())

    # shutdown 之后不再接任务
    t.shutdown(timeout=1.0)
    ck("shutdown 后 is_running 为假", not t.is_running())
    ck("shutdown 后 run 被拒", t.run(job("e", 5), "te") is False)

    print("taskrunner 自检：%d 项，失败 %d 项" % (n[0], bad[0]))
    return 0 if bad[0] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(_selftest())
