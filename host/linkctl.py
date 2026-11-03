"""链路的"判断"部分：有帧没帧、该不该重连、断线前把事件队列排空。

设计约束（改这个文件前先读）：
1. **不 import Qt、不 import link/面板**。这里只有时间戳与计数的计算，所以能
   在没有 QApplication、没有串口的机器上跑 `--selftest`（门禁就是这么用的）。
2. **状态由 `LinkWatchdog` 独占**：谁要"上报收到帧"就调 `note_rx()`，别再在
   主窗口里自己记 `_last_rx_t` —— 两份时间戳一定会漂，漂了就会出现"数据明明在
   来、状态栏却说链路无数据"。
3. 阈值语义固定（现场口径，别随手调）：
   · 静默 > `warn_s`（3 s）→ 只报一次"链路无数据"，来帧自动恢复；
   · 静默 > `bad_s`（15 s）→ 自动重连，每隔 `bad_s` 试一次，**最多 `max_retry` 次**；
   · 收到任何帧就把重试计数清零（板子自己缓过来时不必继续重连）。
"""

from __future__ import annotations

import time

LINK_QUIET_WARN_S = 3.0      # 多久没帧就报「链路无数据」（来帧自动恢复）
LINK_QUIET_BAD_S = 15.0      # 再久就自动重连
MAX_AUTO_RETRY = 3           # 每轮断线最多自动重连几次
MAX_EVENTS_JUMP = 20000      # 单次排空的事件上限（防御死循环，不是正常路径）
BATCH_FEED = 4000            # 排空时每批喂给记录器的帧数（GUI 线程别卡死）


class LinkWatchdog:
    """按"最后一次收到帧的时间"判定链路死活的看门狗。

    `feed(now)` 返回一个 dict，调用方按事件去动界面（本项目里是 main_window）：

        quiet        距上次收到帧多少秒
        warned       True = 这一轮刚跨过 warn_s，该报一次"链路无数据"
        recovered_s  非 None = 刚恢复，值是中断了多久（该报"恢复"）
        reconnect    True = 这一轮该发起自动重连
        retry_n      已用掉的自动重连次数（1..max_retry）
        exhausted    True = 次数用完了、还在静默（界面可以提示"只能手动重连"）
    """

    def __init__(self, warn_s=LINK_QUIET_WARN_S, bad_s=LINK_QUIET_BAD_S,
                 max_retry=MAX_AUTO_RETRY, retry_gap_s=None):
        self.warn_s = float(warn_s)
        self.bad_s = float(bad_s)
        self.max_retry = int(max_retry)
        self.retry_gap_s = float(bad_s if retry_gap_s is None else retry_gap_s)
        self.reset(None)

    # ---------------------------------------------------------------- 状态
    def reset(self, now):
        """连接建立/断开时调用：时间戳归零，重试计数与告警位一起清掉。"""
        self._last_rx = None if now is None else float(now)
        self.quiet_logged = False
        self.retry_n = 0
        self.last_retry_t = 0.0

    def note_rx(self, now):
        """收到一帧（或一次计数上报）就调这个 —— 顺带把重试计数清零。"""
        self._last_rx = float(now)
        self.retry_n = 0

    def quiet_s(self, now):
        if self._last_rx is None:
            return 0.0
        return max(0.0, float(now) - self._last_rx)

    # ---------------------------------------------------------------- 判定
    def feed(self, now):
        now = float(now)
        ev = {"quiet": 0.0, "warned": False, "recovered_s": None,
              "reconnect": False, "retry_n": self.retry_n, "exhausted": False}
        if self._last_rx is None:            # 还没收到过任何东西：先立个基线
            self._last_rx = now
            return ev

        quiet = max(0.0, now - self._last_rx)
        ev["quiet"] = quiet

        if quiet < self.warn_s:
            if self.quiet_logged:
                self.quiet_logged = False
                ev["recovered_s"] = quiet
            return ev

        if not self.quiet_logged:
            self.quiet_logged = True
            ev["warned"] = True

        if (quiet >= self.bad_s and self.retry_n < self.max_retry
                and (now - self.last_retry_t) > self.retry_gap_s):
            self.retry_n += 1
            self.last_retry_t = now
            ev["reconnect"] = True
            ev["retry_n"] = self.retry_n
        elif quiet >= self.bad_s and self.retry_n >= self.max_retry:
            ev["exhausted"] = True
        return ev


def pick_reconnect_port(port, ports, looks_like=None):
    """挑一个重连目标：原端口还在就还用原端口，否则优先"看着像板子"的那个。

    `ports` 是 `[(device, desc, hwid), ...]`。拔插 USB 转串口后 COM 号会变，
    所以不能死认原端口；但也不能乱挑一个（现场机器上常插着别的串口设备）。
    """
    names = [d for d, _s, _h in ports]
    if port and port in names:
        return port
    boards = []
    if looks_like is not None:
        boards = [d for d, s, h in ports if looks_like(d, s, h)]
    return (boards or names or [None])[0]


def drain_events(worker, max_events=MAX_EVENTS_JUMP):
    """把 worker 的事件队列取空（断开/退出前必须做，否则队列里的帧进不了 CSV）。

    只做"取"和"累加"，不改 worker 状态；返回 dict：
        taken / frames / counters / last_frame
    调用方拿着 `counters` 去算丢帧与坏帧增量（基线在调用方手里）。
    """
    res = {"taken": 0, "frames": [], "counters": None, "last_frame": None}
    if worker is None:
        return res
    while res["taken"] < int(max_events):
        try:
            kind, _text, extra = worker.events.get_nowait()
        except Exception:                     # queue.Empty 或 worker 已关闭
            break
        res["taken"] += 1
        if kind == "batch":
            frames = extra.get("frames") or []
            res["counters"] = extra.get("counters") or res["counters"]
            if frames:
                res["frames"].extend(frames)
                res["last_frame"] = frames[-1]
        elif kind == "stats":
            res["counters"] = extra.get("counters") or res["counters"]
    return res


def _selftest():
    n = [0]
    bad = [0]

    def ck(name, cond, extra=""):
        n[0] += 1
        if not cond:
            bad[0] += 1
            print("  FAIL %s %s" % (name, extra))

    # 1) 还没收到过帧：只立基线，不报警
    wd = LinkWatchdog()
    ev = wd.feed(100.0)
    ck("首次 feed 不报警", not ev["warned"] and not ev["reconnect"] and ev["quiet"] == 0.0)

    # 2) 3 s 内静默不报
    ev = wd.feed(102.0)
    ck("2 s 静默不报", not ev["warned"] and ev["quiet"] == 2.0)

    # 3) 跨过 warn_s 只报一次
    ev = wd.feed(104.0)
    ck("4 s 报一次无数据", ev["warned"])
    ev = wd.feed(105.0)
    ck("同一轮不重复报", not ev["warned"])

    # 4) 来帧即恢复，并带上静默时长
    wd.note_rx(106.0)
    ev = wd.feed(106.5)
    ck("来帧恢复", ev["recovered_s"] == 0.5, str(ev))

    # 5) 15 s 触发第一次重连，之后按 bad_s 节流
    wd = LinkWatchdog()
    wd.reset(0.0)
    ev = wd.feed(15.5)
    ck("15.5 s 重连一次", ev["reconnect"] and ev["retry_n"] == 1)
    ev = wd.feed(20.0)
    ck("5 s 后不重复重连", not ev["reconnect"])
    ev = wd.feed(31.0)
    ck("再过 15 s 第 2 次", ev["reconnect"] and ev["retry_n"] == 2)

    # 6) 最多 3 次，然后 exhausted
    ev = wd.feed(47.0)
    ck("第 3 次", ev["reconnect"] and ev["retry_n"] == 3)
    ev = wd.feed(70.0)
    ck("用完就 exhausted", (not ev["reconnect"]) and ev["exhausted"])

    # 7) 收到帧后重试计数清零（板子自己缓过来不再重连）
    wd.note_rx(71.0)
    ev = wd.feed(72.0)
    ck("恢复后计数清零", wd.retry_n == 0 and ev["recovered_s"] is not None)

    # 8) 选端口：原端口在就用原端口
    ports = [("COM3", "USB-SERIAL CH340", "USB VID:PID=1A86:7523"), ("COM7", "Bluetooth", "BTHENUM")]
    ck("原端口还在就沿用", pick_reconnect_port("COM3", ports) == "COM3")

    # 9) 原端口没了：优先像板子的那个
    ports2 = [("COM7", "Bluetooth", "BTHENUM"), ("COM9", "USB-SERIAL CH340", "USB VID:PID=1A86:7523")]
    ck("挑像板子的", pick_reconnect_port("COM3", ports2,
                                       lambda d, s, h: "CH340" in s) == "COM9")

    # 10) 一个都不像板子：退化成第一个可用
    ck("退化取第一个", pick_reconnect_port("COM3", [("COM9", "x", "y")]) == "COM9")

    # 11) 完全没有串口：None（界面据此报"USB 线被拔了"）
    ck("没有串口返回 None", pick_reconnect_port("COM3", []) is None)
    ck("None 端口也能挑", pick_reconnect_port(None, [("COM2", "a", "b")]) == "COM2")

    # 12) 排事件：batch 累帧、stats 只更新计数、空队列安全
    class _FakeWorker:
        def __init__(self, items):
            import queue
            self.events = queue.Queue()
            for it in items:
                self.events.put(it)

    fr = [{"s": 1}, {"s": 2}]
    wk = _FakeWorker([("batch", "", {"frames": fr, "counters": {"a": 1}}),
                      ("stats", "", {"counters": {"a": 2}}),
                      ("batch", "", {"frames": [], "counters": {"a": 3}})])
    r = drain_events(wk)
    ck("排空取到 3 条", r["taken"] == 3)
    ck("累到 2 帧", len(r["frames"]) == 2)
    ck("末帧正确", r["last_frame"] == {"s": 2})
    ck("计数取最后一条", r["counters"] == {"a": 3})
    ck("空 worker 安全", drain_events(None)["taken"] == 0)

    print("linkctl 自检：%d 项，失败 %d 项" % (n[0], bad[0]))
    return 0 if bad[0] == 0 else 1


if __name__ == "__main__":
    import sys
    raise SystemExit(_selftest())
