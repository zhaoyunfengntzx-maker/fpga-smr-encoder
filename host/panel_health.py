"""链路健康趋势：把「现在帧率多少」变成「过去几分钟有没有抖过」。

设计约束（改这个文件前先读）：
1. **只存降采样后的点**。`push()` 每 2 s 一次（跟着 `_update_comm_stats` 走），
   6 分钟窗口 = 180 点 × 3 条曲线，内存和重绘都可以忽略。千万别在这里存原始帧。
2. **纵轴自己按数据缩放，但保留一个"满格"参考**：帧率一直 10 k 时曲线是条平线，
   看上去像没数据 —— 所以每行左边永远画标尺（上界 = max(数据, 参考值)），
   并标出当前值。
3. 这里不算任何统计量，只画传进来的数。算错了没法定位是"算的地方"还是"画的地方"。
"""

from __future__ import annotations

import math
import sys
from collections import deque

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QPainter, QPen, QPolygonF
from PySide6.QtWidgets import (QFrame, QLabel, QSizePolicy, QVBoxLayout,
                               QWidget)

import theme as th
import ui_kit as uk

C = th.C

WINDOW_S = 360.0            # 窗口：6 分钟
MAX_POINTS = 400            # 兜底上限（每秒推一次也够 6 分钟）
ROW_H = 46                  # 每行高度


class TrendPlot(QWidget):
    """多行迷你趋势图：一行一条曲线，x 轴共享时间窗。"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(3 * ROW_H + 12)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self._rows = []          # [{name, unit, color, pts: deque[(t,v)], ref}]

    # ------------------------------------------------------------ 数据
    def add_row(self, name, unit, color, ref=0.0):
        self._rows.append({"name": name, "unit": unit, "color": color,
                           "pts": deque(maxlen=MAX_POINTS), "ref": float(ref)})
        return len(self._rows) - 1

    def clear(self):
        for r in self._rows:
            r["pts"].clear()
        self.update()

    def push(self, idx, t, value):
        if not (0 <= idx < len(self._rows)):
            return
        try:
            v = float(value)
        except (TypeError, ValueError):
            return
        if not math.isfinite(v):
            return
        self._rows[idx]["pts"].append((float(t), v))
        self.update()

    def last(self, idx):
        r = self._rows[idx] if 0 <= idx < len(self._rows) else None
        return r["pts"][-1][1] if r and r["pts"] else None

    def count(self, idx):
        r = self._rows[idx] if 0 <= idx < len(self._rows) else None
        return len(r["pts"]) if r else 0

    # ------------------------------------------------------------ 绘制
    def paintEvent(self, _ev):                                   # noqa: N802
        p = QPainter(self)
        try:
            self._paint(p)
        finally:
            p.end()

    def _paint(self, p):
        r = self.rect()
        p.fillRect(r, QColor(C["card"]))
        p.setFont(QFont(self.font().family(), 7))
        n = len(self._rows)
        if n == 0:
            return
        box_l = 74
        h = (r.height() - 4) / n
        t_end = 0.0
        t_first = None
        for row in self._rows:
            if row["pts"]:
                t_end = max(t_end, row["pts"][-1][0])
                t0 = row["pts"][0][0]
                t_first = t0 if t_first is None else min(t_first, t0)
        # 数据不足一个窗口时先按"已有点"铺满，否则开机头几分钟左边全空、
        # 看着像没在跑；铺满时角落里的「窗口」字样会显示实际跨度。
        span_label = WINDOW_S
        if t_first is not None and (t_end - t_first) < WINDOW_S:
            span_label = max(30.0, t_end - t_first)
        for i, row in enumerate(self._rows):
            top = 2 + h * i
            box = QRectF(box_l, top + 3, r.width() - box_l - 12, h - 12)
            # 标尺
            vals = [v for _t, v in row["pts"]]
            hi = max(vals + [row["ref"]]) if vals else row["ref"]
            lo = min(vals + [0.0]) if vals else 0.0
            if hi - lo < 1e-9:
                hi = lo + 1.0
            hi += (hi - lo) * 0.15
            p.setPen(QPen(QColor(C["line"]), 1, Qt.DotLine))
            p.drawLine(QPointF(box.left(), box.bottom()), QPointF(box.right(), box.bottom()))
            p.drawLine(QPointF(box.left(), box.top()), QPointF(box.left(), box.bottom()))
            # 名称 + 当前值
            cur = vals[-1] if vals else None
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(QRectF(0, box.top() - 2, box_l - 6, 12),
                       Qt.AlignRight | Qt.AlignVCenter, row["name"])
            p.setPen(QPen(QColor(row["color"])))
            txt = "—" if cur is None else uk.sgn("%.4g%s" % (cur, row["unit"]))
            p.drawText(QRectF(0, box.top() + 10, box_l - 6, 12),
                       Qt.AlignRight | Qt.AlignVCenter, txt)
            # 曲线
            if len(row["pts"]) >= 2:
                t0 = t_end - span_label
                span = max(1e-6, t_end - t0)
                poly = QPolygonF()
                for t, v in row["pts"]:
                    if t < t0:
                        continue
                    x = box.left() + box.width() * (t - t0) / span
                    y = box.bottom() - box.height() * (v - lo) / (hi - lo)
                    poly.append(QPointF(x, y))
                p.setPen(QPen(QColor(row["color"]), 1.2))
                p.drawPolyline(poly)
        # 右下角时间范围
        p.setPen(QPen(QColor(C["muted"])))
        p.drawText(QRectF(r.width() - 150, r.height() - 12, 142, 11),
                   Qt.AlignRight | Qt.AlignVCenter,
                   "窗口 %.1f 分钟" % (span_label / 60.0))


class HealthPanel(QFrame):
    """诊断页的「链路健康趋势」卡片。"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 12)
        lay.setSpacing(6)
        ttl = QLabel("链路健康趋势")
        ttl.setObjectName("CardTitle")
        lay.addWidget(ttl)
        lay.addWidget(uk.hint_label(
            "每 2 s 采一个点，看最近 6 分钟：帧率掉、校验错冒头、丢帧变多。"
            "0.38% 的逐帧校验错是这条 2 Mbaud 链路的固有水平（见 README），"
            "突然抬到 1% 以上才是线/接头/供电的问题。", lines=3))
        self.plot = TrendPlot()
        self.i_fps = self.plot.add_row("帧率", "", C["primary"], ref=10000.0)
        self.i_err = self.plot.add_row("校验错", "%", C["warn"], ref=0.5)
        self.i_lost = self.plot.add_row("丢帧", "", C["fault"], ref=0.0)
        lay.addWidget(self.plot, 1)

    # ------------------------------------------------------------ 接口
    def push(self, now, fps, err_pct, lost_total):
        self.plot.push(self.i_fps, now, fps)
        self.plot.push(self.i_err, now, err_pct)
        self.plot.push(self.i_lost, now, lost_total)

    def clear(self):
        self.plot.clear()

    def last(self, which="fps"):
        return {"fps": self.plot.last(self.i_fps),
                "err": self.plot.last(self.i_err),
                "lost": self.plot.last(self.i_lost)}[which]

    def count(self):
        return self.plot.count(self.i_fps)


# ---------------------------------------------------------------- 自检
def selftest():
    n = 0
    bad = []

    def ck(name, cond, extra=""):
        nonlocal n
        n += 1
        if not cond:
            bad.append("%s %s" % (name, extra))

    from PySide6.QtWidgets import QApplication
    app = QApplication.instance()
    if app is None:
        _app = QApplication(sys.argv[:1])          # noqa: F841
    p = HealthPanel()
    ck("初始无点", p.count() == 0 and p.last("fps") is None)
    p.push(100.0, 10000.0, 0.38, 5)
    ck("推一个点", p.count() == 1 and abs(p.last("fps") - 10000.0) < 1e-9)
    for k in range(1, 10):
        p.push(100.0 + 2.0 * k, 10000.0 - 100.0 * k, 0.38 + 0.01 * k, 5 + k)
    ck("推十个点", p.count() == 10)
    ck("最后帧率", abs(p.last("fps") - 9100.0) < 1e-9, p.last("fps"))
    ck("最后校验错", abs(p.last("err") - 0.47) < 1e-9, p.last("err"))
    ck("最后丢帧", abs(p.last("lost") - 14.0) < 1e-9, p.last("lost"))
    p.push(200.0, float("nan"), 0.1, 1)
    ck("NaN 不进曲线", p.count() == 10)
    p.push(200.0, "abc", 0.1, 1)
    ck("非数字不进曲线", p.count() == 10)
    p.push(999, 1, 1, 1)                            # 越界索引不能炸
    p.clear()
    ck("清空", p.count() == 0)
    # 溢出保护：推得比 MAX_POINTS 多也不会无限涨
    for k in range(MAX_POINTS + 50):
        p.push(float(k), 1.0, 0.0, 0.0)
    ck("点数封顶", p.count() == MAX_POINTS, p.count())
    p.grab()                                        # 绘制路径不能抛
    ck("能画出图", True)
    if bad:
        print("FAIL %d/%d" % (len(bad), n))
        for b in bad:
            print("  - " + b)
        return 1
    print("panel_health selftest: PASS (%d 项)" % n)
    return 0


def main(argv=None):
    argv = list(sys.argv if argv is None else argv)
    from PySide6.QtWidgets import QApplication
    app = QApplication.instance() or QApplication(argv[:1])
    if "--selftest" in argv:
        return selftest()
    w = HealthPanel()
    w.resize(720, 320)
    w.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
