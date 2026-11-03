"""日志显示子系统：分级、过滤、着色、工作线程投递。

设计约束（改这个文件前先读）：
1. **工作线程只能投递，不能碰控件**。`log_line()` 里先判 `QThread.currentThread() is
   not self.thread()`，不等就在 `self._logq` 里排队，界面线程 200 ms 泵一次
   （`_pump_logq`）。Qt 控件跨线程写会随机崩，这条不是风格问题。
2. **历史与显示分开**：`self._log_records` 是全量（封顶 `LOG_MAX_LINES`），
   切换"显示级别"只是重画（`_render_log`），不丢历史。
3. `log_line` 的返回值是时间戳（`HH:MM:SS`）。CSV/记录里的时间列用它，
   所以工作线程分支也要返回一个 -- 别改成 None。
4. 级别集合是固定的四档：fault > warn > ok/info > debug（见 `LOG_RANK`）。
   新增级别必须同时进 `LOG_RANK` 与 `LOG_COLOR`，否则会被当成 info。

依赖的宿主属性（由 MainWindow/Mixin 提供）：`_logq`、`_log_records`、`log`（QPlainTextEdit）、
`lab_log_count`、`combo_log`、`log_level`。
"""

from __future__ import annotations

import queue
import time

from PySide6.QtCore import QThread

LOG_MAX_LINES = 600      # 日志区最多留多少行（超了从头砍，避免长跑吃内存）

# ---- 日志级别（R5）：2 s 一次的告警轮询记成 debug，默认不显示，不再刷屏 ----
# 级别由重到轻：fault > warn > ok/info > debug；过滤 = "不低于所选级别才显示"
LOG_RANK = {"fault": 3, "warn": 2, "ok": 1, "info": 1, "debug": 0}
LOG_COLOR = {"debug": "#8E8E93", "ok": "#34C759", "warn": "#FF9F0A",
             "fault": "#FF3B30"}          # None（info）走默认前景色
# ★ 阶段 3：日志四级色跟着 Apple 令牌走（灰 / 绿 / 橙 / 红），与告警指示灯同一套语义。
LOG_FILTERS = (("全部（含调试）", "debug"), ("信息及以上", "info"),
               ("警告及以上", "warn"), ("只看故障", "fault"))
LOG_FILTER_DEFAULT = "info"

def _esc(text):
    """日志走 appendHtml 时要转义（否则文本里的 < > & 会被当成标签）。"""
    return (str(text).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))

class LogMixin(object):
    """把日志相关的状态机与显示逻辑从主窗口里摘出来。"""

    def log_line(self, text, level="info"):
        """写一条日志。level：fault / warn / ok / info / debug（越靠前越重）。

        ★ R5：显示级别可过滤（默认「信息及以上」）。2 秒一次的告警轮询用 debug 记，
        默认看不见，切到「全部」还能回看 —— 原来它每 2 秒刷一行，把有用的信息冲走了。
        全量记录留在 self._log_records 里，所以切换级别能把历史一起显示出来。
        """
        if QThread.currentThread() is not self.thread():
            # 工作线程：只投递，不碰控件（队列消费见 _pump_logq）
            self._logq.put((text, level))
            return time.strftime("%H:%M:%S")
        stamp = time.strftime("%H:%M:%S")
        lv = level if level in LOG_RANK else "info"
        self._log_records.append((stamp, text, lv))
        if len(self._log_records) > LOG_MAX_LINES:
            del self._log_records[:len(self._log_records) - LOG_MAX_LINES]
        if LOG_RANK[lv] >= LOG_RANK[self.log_level]:
            self._append_log(stamp, text, lv)
        self._refresh_log_count()
        if lv in ("warn", "fault", "ok"):
            self.statusBar().showMessage(text)
        return stamp

    def _pump_logq(self):
        """把工作线程投递的日志搬进界面（每 200 ms 一次，单轮上限 50 条）。"""
        for _ in range(50):
            try:
                text, level = self._logq.get_nowait()
            except queue.Empty:
                return
            self.log_line(text, level)

    def _append_log(self, stamp, text, level):
        """一行日志进显示区（按级别着色；越界字符已转义）。"""
        color = LOG_COLOR.get(level)
        if color:
            self.log.appendHtml('<span style="color:%s">%s  %s</span>'
                                % (color, stamp, _esc(text)))
        else:
            self.log.appendPlainText("%s  %s" % (stamp, text))

    def _refresh_log_count(self):
        """右下角"显示 N / 共 M 行"——过滤掉多少一眼可见。"""
        shown = sum(1 for _s, _t, lv in self._log_records
                    if LOG_RANK[lv] >= LOG_RANK[self.log_level])
        self.lab_log_count.setText("显示 %d / 共 %d 行" % (shown, len(self._log_records)))

    def _render_log(self):
        """按当前级别重画整个日志区（切换级别时把历史也一起显示/隐藏）。"""
        self.log.clear()
        thr = LOG_RANK[self.log_level]
        for stamp, text, lv in self._log_records:
            if LOG_RANK[lv] >= thr:
                self._append_log(stamp, text, lv)
        self._refresh_log_count()

    def _on_log_filter(self, _idx=0):
        key = self.combo_log.currentData()
        self.log_level = key if key in LOG_RANK else LOG_FILTER_DEFAULT
        self._render_log()

    def clear_log(self):
        """清空日志显示与历史（记录/统计不受影响）。"""
        self._log_records = []
        self.log.clear()
        self.log_line("日志已清空", "info")

    # --------------------------------------------------------- 滚轮路由（R1）

    def _log_notice(self, text, level="info"):
        """面板发来的提示（记录开始/停止、导出结果）统一写进日志卡片。"""
        self.log_line(text, level)
