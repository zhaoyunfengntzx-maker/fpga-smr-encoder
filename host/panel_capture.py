"""抓包页（B1）：一次抓 28672 点原始 ADC 波形（默认 1.15 ms @25 MSPS）。

与「实时」「编码器信号」两页的区别，也是这一页存在的理由：

  实时页的波形来自 10 kHz 遥测帧（100 µs 一个点，18 B/帧），
  1 kHz 信号一个周期只有 10 个点，只能看"包络"；
  这一页走 0x072E 批量 dump，50 MSPS 采样、20 ns 一点
  （抽取 2 时 25 MSPS / 40 ns），一个 1 kHz 周期有 25 个点，
  而且窗口是**连续**的一段，不是抽样。

界面只负责收集参数 + 画图；真正的搬数在 `host/capture.py`（纯逻辑，可用
`tools/cap_dump.py` 在台架上单独验证）。抓包是阻塞的（约 1.5 s），
由主窗口丢进 TaskRunner 的临时线程里跑，界面不卡。
"""

from __future__ import annotations

import os

import numpy as np

from PySide6.QtCore import QLineF, QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPen, QPolygonF
from PySide6.QtWidgets import (QComboBox, QFileDialog, QFrame, QHBoxLayout,
                               QMessageBox,
                               QLabel, QPushButton, QSpinBox, QVBoxLayout,
                               QWidget)

import analysis as an
import capture as cap
import filters as fl
import theme as th
import ui_kit as uk

C = th.C

TRIG_ITEMS = (("立即", 0), ("CH1 上升沿", 1), ("CH1 下降沿", 2))
SRC_ITEMS = (("原始 50 MSPS", 0), ("校正 12.5 MSPS", 1))


def _sgn(text):
    """把 ASCII 减号换成 U+2212（见 ui_kit.sgn 的说明）。"""
    return uk.sgn(text)


def _nice(v):
    """刻度值取三位有效数字：11598 这种刻度读着费劲，显示成 11600。"""
    a = abs(float(v))
    if a >= 100:
        return int(round(float(v) / 10.0) * 10)
    if a >= 1:
        return int(round(float(v)))
    return round(float(v), 2)


def _missing_ranges(res):
    """把 res.missing（块/包下标）换算成样点区间，画黄色缺块带用。"""
    miss = sorted(int(i) for i in (getattr(res, "missing", None) or []))
    n = int(getattr(res, "n", 0) or 0)
    if not miss or n <= 0:
        return []
    if "elapsed_s" in (getattr(res, "meta", None) or {}):
        total = max(1, int(getattr(res, "n_blocks", 0) or 0) + len(miss))
        seg = max(1, int(round(n / float(total))))
    else:
        seg = int(getattr(cap, "PTS_PER_BLOCK", 64))
    return [(i * seg, min((i + 1) * seg, n)) for i in miss]


class CapturePlot(QWidget):
    """双通道静态波形：min/max 包络抽稀 + 可选显示平滑。

    为什么不再"每 N 点取 1 点"：1.15 ms 窗口有 28672 点，1100 px 宽只有
    1100 列，点采样会把每列 ~26 个点里的尖峰随机丢掉 —— 波形忽粗忽细、
    缩放还变形。包络每列画 [min, max]，不丢峰、也不改任何数值。
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(300)
        self.setObjectName("CapturePlot")
        self.setMouseTracking(True)
        self._s = np.zeros(0)
        self._c = np.zeros(0)
        self._fs = 25.0e6
        self._trig = 0
        self._smooth = 0
        self._missing = []
        # 视图：time = 时域包络 + 双游标；spec = 频谱（对数频率轴 / 相对基波 dB）
        self._mode = "time"
        self._spec = None            # {"spec": {s/c: (f, dB)}, "info": {s/c: dict}}
        self._spec_key = None
        self._cur = [None, None]     # 两条游标的横向比例 0..1（None = 未放）
        self._drag = None            # 正在拖第几条

    # ------------------------------------------------------------ 数据
    def set_result(self, res):
        self._s = np.asarray(res.s, dtype=np.float64)
        self._c = np.asarray(res.c, dtype=np.float64)
        self._fs = float(res.fs)
        self._trig = int(res.meta.get("trig_idx", 0))
        self._missing = _missing_ranges(res)
        # 换了一批数据：频谱缓存与游标都必须跟着失效（否则量的是上一枪的点）
        self._spec = None
        self._spec_key = None
        self._cur = [None, None]
        self._drag = None
        self.update()

    def set_missing(self, ranges):
        self._missing = list(ranges or [])
        self.update()

    def set_smooth(self, w):
        self._smooth = int(w or 0)
        self.update()

    def mode(self):
        return self._mode

    def set_mode(self, mode):
        """切时域 / 频谱。切之前不放游标，切回来时游标位置保留。"""
        self._mode = "spec" if mode == "spec" else "time"
        self._drag = None
        self.update()

    def clear_cursors(self):
        self._cur = [None, None]
        self._drag = None
        self.update()

    def clear(self):
        self._s = np.zeros(0)
        self._c = np.zeros(0)
        self._missing = []
        self._spec = None
        self._spec_key = None
        self._cur = [None, None]
        self.update()

    # ------------------------------------------------------------ 频谱
    def _spec_data(self):
        """算一次频谱并缓存（换数据 / 换结果才重算）。"""
        n = int(self._s.size)
        if n < 64:
            return None
        key = (id(self._s), id(self._c), self._fs)
        if self._spec_key == key and self._spec is not None:
            return self._spec
        spec, info = {}, {}
        for name, arr in (("s", self._s), ("c", self._c)):
            r = an.spectrum(arr, self._fs)
            if not r.get("ok"):
                return None
            mag = np.maximum(np.asarray(r["mag"], dtype=np.float64), 1e-12)
            spec[name] = (np.asarray(r["freq_hz"], dtype=np.float64),
                          20.0 * np.log10(mag / mag.max()))
            info[name] = r
        self._spec = {"spec": spec, "info": info}
        self._spec_key = key
        return self._spec

    def spec_info(self):
        """频谱读数（没算过就算一次）。面板上的文字用这个。"""
        d = self._spec_data()
        if not d:
            return None
        out = dict(d["info"]["s"])
        out["res_hz"] = self._fs / max(1, int(self._s.size))
        out["n"] = int(self._s.size)
        return out

    def _spec_cols(self, f, db, box, fmin, fmax, lo, hi):
        """把 (f, dB) 按像素列取峰值，返回 (xs, ys)。

        取 max 而不是取平均：频谱要看的是"这一列里最强的那个分量"，
        平均会把窄带谱线抹平（1 kHz 信号在 25 MSPS / 28672 点下主瓣只有几列宽）。
        """
        w = float(box.width())
        h = float(box.height())
        if f.size < 2 or w <= 1:
            return [], []
        m = (f >= fmin) & (f <= fmax)
        if not m.any():
            return [], []
        ff, dd = f[m], db[m]
        l0 = np.log10(max(fmin, 1e-9))
        l1 = np.log10(max(fmax, 1e-9))
        cols = max(2, int(w))
        idx = np.clip(((np.log10(np.maximum(ff, 1e-9)) - l0)
                       / max(1e-12, l1 - l0) * (cols - 1)).astype(np.int64),
                      0, cols - 1)
        peak = np.full(cols, -1e9)
        np.maximum.at(peak, idx, dd)
        got = peak > -1e8
        xs = [box.left() + w * (i / float(cols - 1)) for i in range(cols) if got[i]]
        ys = [box.bottom() - h * ((float(np.clip(peak[i], lo, hi)) - lo) / (hi - lo))
              for i in range(cols) if got[i]]
        return xs, ys

    def _paint_spec(self, p, box):
        lo, hi = -100.0, 6.0
        fs0 = QFont()
        fs0.setPointSize(7)
        p.setFont(fs0)
        p.setPen(QPen(QColor(C["line"]), 1))
        for i in range(6):
            db = 0 - 20 * i
            y = box.bottom() - box.height() * ((db - lo) / (hi - lo))
            p.drawLine(QPointF(box.left(), y), QPointF(box.right(), y))
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(2, int(y) - 7, max(24, box.left() - 8), 12,
                       Qt.AlignRight | Qt.AlignVCenter,
                       _sgn("%d dB" % db))
            p.setPen(QPen(QColor(C["line"]), 1))

        d = self._spec_data()
        if not d:
            p.setPen(QPen(QColor(C["muted"])))
            f = QFont()
            f.setPointSize(11)
            p.setFont(f)
            p.drawText(box, Qt.AlignCenter, "点数太少，算不了频谱（至少要 64 点）")
            return

        f = d["spec"]["s"][0]
        n = int(self._s.size)
        fmin = max(self._fs / max(2.0, float(n)), 1.0)
        fmax = self._fs / 2.0
        l0, l1 = np.log10(fmin), np.log10(fmax)

        # 对数频率轴：整十进位 + 每十倍里的 2/5 辅助线
        p.setPen(QPen(QColor(C["muted"])))
        decade = 10.0 ** np.arange(np.ceil(l0), np.floor(l1) + 1)
        for dv in decade:
            x = box.left() + box.width() * ((np.log10(dv) - l0) / (l1 - l0))
            p.setPen(QPen(QColor(C["line"]), 1))
            p.drawLine(QPointF(x, box.top()), QPointF(x, box.bottom()))
            lab = ("%d Hz" % dv) if dv < 1e3 else (
                ("%g kHz" % (dv / 1e3)) if dv < 1e6 else ("%g MHz" % (dv / 1e6)))
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(int(x) - 32, box.bottom() + 6, 64, 12,
                       Qt.AlignHCenter, lab)
        for mult in (2.0, 5.0):
            for dv in decade:
                fv = dv * mult
                if fv <= fmin or fv >= fmax:
                    continue
                x = box.left() + box.width() * ((np.log10(fv) - l0) / (l1 - l0))
                p.setPen(QPen(QColor(C["line"]), 1, Qt.DotLine))
                p.drawLine(QPointF(x, box.top()), QPointF(x, box.bottom()))

        # 两条曲线的频谱
        for name, color in (("s", C["primary"]), ("c", C["warn"])):
            ff, db = d["spec"][name]
            xs, ys = self._spec_cols(ff, db, box, fmin, fmax, lo, hi)
            if len(xs) < 2:
                continue
            poly = QPolygonF()
            for i in range(len(xs)):
                poly.append(QPointF(xs[i], ys[i]))
            p.setPen(QPen(QColor(color), 1.2))
            p.drawPolyline(poly)

        # 谐波竖线 + 相对幅度标注（只标 > 0.5% 的，免得糊成一片）
        info = d["info"]["s"]
        fund = float(info.get("fund_hz") or 0.0)
        rows = list(info.get("harmonics") or [])
        if fund > 0:
            for row in rows[1:]:
                k = int(row.get("h") or 0)
                fv = fund * k
                if k < 2 or fv <= fmin or fv >= fmax:
                    continue
                x = box.left() + box.width() * ((np.log10(fv) - l0) / (l1 - l0))
                p.setPen(QPen(QColor(C["ok"]), 1, Qt.DashLine))
                p.drawLine(QPointF(x, box.top()), QPointF(x, box.bottom()))
                pct = float(row.get("rel_pct") or 0.0)
                if pct >= 0.5:
                    p.setPen(QPen(QColor(C["ok"])))
                    p.drawText(int(x) + 2, box.top() + 16, 70, 12,
                               Qt.AlignLeft, "H%d %.2f%%" % (k, pct))

        p.setPen(QPen(QColor(C["muted"])))
        p.drawText(box.left() + 6, box.top() + 1, max(120, box.width() - 340), 12,
                   Qt.AlignLeft,
                   "CH1 基波 %.3f kHz ｜ THD %.2f%% ｜ 分辨率 %.0f Hz"
                   % (fund / 1e3, float(info.get("thd_pct") or 0.0),
                      self._fs / max(1, n)))
        p.setPen(QPen(QColor(C["primary"]), 2))
        p.drawLine(box.right() - 132, box.top() + 7, box.right() - 112, box.top() + 7)
        p.drawText(box.right() - 108, box.top() + 1, 46, 12, Qt.AlignLeft, "CH1 s")
        p.setPen(QPen(QColor(C["warn"]), 2))
        p.drawLine(box.right() - 62, box.top() + 7, box.right() - 42, box.top() + 7)
        p.drawText(box.right() - 38, box.top() + 1, 40, 12, Qt.AlignLeft, "CH2 c")

    # ------------------------------------------------------------ 绘制
    def paintEvent(self, _ev):                                   # noqa: N802
        p = QPainter(self)
        try:
            self._paint(p)
        finally:
            # 绘图里一旦抛异常，不 end() 会让 Qt 反复报警、后续重绘也乱
            p.end()

    def _paint(self, p):
        p.setRenderHint(QPainter.Antialiasing, True)
        r = self.rect()
        p.fillRect(r, QColor(C["card"]))
        # 频谱要写 "-100 dB"，7pt 下量出来 63 px，56 px 的左边距会把负号裁掉
        box = r.adjusted(78 if self._mode == "spec" else 56, 12, -16, -28)

        n = int(self._s.size)
        if n < 2:
            p.setPen(QPen(QColor(C["muted"])))
            f = QFont()
            f.setPointSize(11)
            p.setFont(f)
            p.drawText(box, Qt.AlignCenter, "还没有数据 —— 点「抓一次」")
            return

        if self._mode == "spec":
            self._paint_spec(p, box)
            return

        ymin = float(min(self._s.min(), self._c.min()))
        ymax = float(max(self._s.max(), self._c.max()))
        if ymax <= ymin:
            ymax = ymin + 1
        pad = max(1, int((ymax - ymin) * 0.08))
        ymin -= pad
        ymax += pad

        # 网格 + 纵轴刻度
        p.setPen(QPen(QColor(C["line"]), 1))
        for i in range(5):
            y = box.top() + box.height() * i / 4.0
            p.drawLine(QPointF(box.left(), y), QPointF(box.right(), y))
            val = ymax - (ymax - ymin) * i / 4.0
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(2, int(y) + 4, max(24, box.left() - 8), 12,
                       Qt.AlignRight | Qt.AlignVCenter,
                       _sgn("%g" % _nice(val)))
            p.setPen(QPen(QColor(C["line"]), 1))

        # 时间刻度：窗口 < 2 ms 用 µs（1.15 ms 的窗口用 ms 只剩两位有效数字）
        dur_s = (n - 1) / self._fs
        use_us = dur_s < 2e-3
        unit, scale, fmt = ("µs", 1e6, "%.1f") if use_us else ("ms", 1e3, "%.3f")
        p.setPen(QPen(QColor(C["muted"])))
        for i in range(5):
            x = box.left() + box.width() * i / 4.0
            t = dur_s * (i / 4.0 - (self._trig / float(n - 1)))
            p.drawLine(QPointF(x, box.bottom()), QPointF(x, box.bottom() + 4))
            p.drawText(int(x) - 30, box.bottom() + 6, 60, 12,
                       Qt.AlignHCenter, _sgn(fmt % (t * scale)))
        p.drawText(box.right() - 250, box.bottom() + 6, 200, 12, Qt.AlignRight,
                   "相对触发点 t / %s" % unit)
        # 缺块区间（补 0 的地方）标黄：滤波救不了，必须让人一眼看到
        for a, b in self._missing:
            x0 = box.left() + box.width() * (a / float(n - 1))
            x1 = box.left() + box.width() * (max(a, b - 1) / float(n - 1))
            p.fillRect(QRectF(x0, box.top(), max(1.0, x1 - x0), box.height()),
                       QColor(255, 176, 0, 46))

        # 触发点竖线
        tx = box.left() + box.width() * (self._trig / float(n - 1))
        p.setPen(QPen(QColor(C["ok"]), 1, Qt.DashLine))
        p.drawLine(QPointF(tx, box.top()), QPointF(tx, box.bottom()))

        # 曲线：按像素列取 min/max（包络），平滑可叠加
        cols = max(1, int(box.width()))
        self._draw_curve(p, box, self._s, ymin, ymax, cols, C["primary"])
        self._draw_curve(p, box, self._c, ymin, ymax, cols, C["warn"])

        # 右上角标注当前画法，避免"看到的不是原始数据"这种误解
        badge = "包络抽稀"
        if self._smooth > 1:
            badge += " ｜ 平滑 %d 点" % self._smooth
        if self._missing:
            badge += " ｜ 缺块 %d" % len(self._missing)
        p.setPen(QPen(QColor(C["muted"])))
        p.drawText(box.right() - 300, box.top() + 4, 296, 12,
                   Qt.AlignRight, badge)

        # 图例
        p.setPen(QPen(QColor(C["primary"]), 2))
        p.drawLine(box.left() + 6, box.top() + 10, box.left() + 26, box.top() + 10)
        p.drawText(box.left() + 30, box.top() + 14, "CH1")
        p.setPen(QPen(QColor(C["warn"]), 2))
        p.drawLine(box.left() + 70, box.top() + 10, box.left() + 90, box.top() + 10)
        p.drawText(box.left() + 94, box.top() + 14, "CH2")

        self._paint_cursors(p, box)

    # ------------------------------------------------------------ 游标测量
    def _idx_of(self, frac):
        n = int(self._s.size)
        if n < 1:
            return 0
        return int(round(float(frac) * (n - 1)))

    def _sample_at(self, i):
        n = int(self._s.size)
        i = max(0, min(n - 1, int(i)))
        return (i / self._fs, float(self._s[i]), float(self._c[i]))

    def cursor_readout(self):
        """两条游标之间的测量值（没放齐就返回 None）。

        返回 {t0,t1,dt_ms,s0,s1,c0,c1,ds,dc,d_deg,f_hz}：
          dt_ms  = 两点时间差；f_hz = 1/dt（给"两点跨一个周期"用的粗测频）；
          d_deg  = 两点在 s-c 平面上的夹角（量相位/正交误差的直观办法）。
        """
        if self._cur[0] is None or self._cur[1] is None:
            return None
        i0, i1 = self._idx_of(self._cur[0]), self._idx_of(self._cur[1])
        if i0 > i1:
            i0, i1 = i1, i0
        t0, s0, c0 = self._sample_at(i0)
        t1, s1, c1 = self._sample_at(i1)
        dt = t1 - t0
        ds, dc = s1 - s0, c1 - c0
        return {"t0": t0, "t1": t1, "dt_ms": dt * 1e3,
                "s0": s0, "s1": s1, "c0": c0, "c1": c1,
                "ds": ds, "dc": dc,
                "d_deg": float(np.degrees(np.arctan2(dc, ds))),
                "f_hz": (1.0 / dt) if dt > 0 else 0.0,
                "i0": i0, "i1": i1}

    def _paint_cursors(self, p, box):
        n = int(self._s.size)
        if n < 2:
            return
        w = float(box.width())
        if self._cur[0] is None:
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(box.left() + 6, box.top() + 22, 420, 12, Qt.AlignLeft,
                       "左键：放游标 A/B（可拖动）｜右键：清除游标")
            return
        for k, frac in enumerate(self._cur):
            if frac is None:
                continue
            x = box.left() + w * float(frac)
            col = C["ok"] if k == 0 else C["warn"]
            p.setPen(QPen(QColor(col), 1, Qt.DashLine))
            p.drawLine(QPointF(x, box.top()), QPointF(x, box.bottom()))
            p.drawText(int(x) + 2, box.top() - 10, 40, 12, Qt.AlignLeft,
                       "A" if k == 0 else "B")
        m = self.cursor_readout()
        if not m:
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(box.left() + 6, box.top() + 22, 420, 12, Qt.AlignLeft,
                       "再放一个游标就能量 Δt / ΔV / 相位角")
            return
        p.setPen(QPen(QColor(C["text"])))
        txt = _sgn("A→B ｜ Δt %.3f µs ｜ f %.2f kHz ｜ Δs %.0f ｜ Δc %.0f ｜ ∠ %.2f°"
                   % (m["dt_ms"] * 1e3, m["f_hz"] / 1e3, m["ds"], m["dc"],
                      m["d_deg"]))
        # 数字压在波形上看不清，先垫一层卡片底色
        p.fillRect(QRectF(box.left() + 2, box.top() + 20, 470, 15),
                   QColor(C["card"]))
        p.setPen(QPen(QColor(C["text"])))
        p.drawText(box.left() + 6, box.top() + 22, 620, 12, Qt.AlignLeft, txt)

    def mousePressEvent(self, ev):                              # noqa: N802
        if self._mode != "time" or self._s.size < 2:
            return super().mousePressEvent(ev)
        r = self.rect()
        box = r.adjusted(56, 12, -16, -28)
        if not box.contains(ev.position().toPoint()):
            return super().mousePressEvent(ev)
        if ev.button() == Qt.RightButton:
            self.clear_cursors()
            return
        frac = (ev.position().x() - box.left()) / max(1.0, float(box.width()))
        frac = max(0.0, min(1.0, frac))
        # 靠近哪条就拖哪条；都不近就按"先 A 后 B"补空位，占满后替换较远的那条
        best, best_d = None, 0.02
        for k in (0, 1):
            if self._cur[k] is None:
                continue
            d = abs(self._cur[k] - frac)
            if d < best_d:
                best, best_d = k, d
        if best is None:
            best = 0 if self._cur[0] is None else (1 if self._cur[1] is None else
                                                  (0 if abs(self._cur[0] - frac)
                                                   > abs(self._cur[1] - frac) else 1))
        self._cur[best] = frac
        self._drag = best
        self.update()

    def mouseMoveEvent(self, ev):                               # noqa: N802
        if self._drag is None:
            return super().mouseMoveEvent(ev)
        r = self.rect()
        box = r.adjusted(56, 12, -16, -28)
        frac = (ev.position().x() - box.left()) / max(1.0, float(box.width()))
        self._cur[self._drag] = max(0.0, min(1.0, frac))
        self.update()

    def mouseReleaseEvent(self, ev):                            # noqa: N802
        self._drag = None
        super().mouseReleaseEvent(ev)

    def _draw_curve(self, p, box, arr, ymin, ymax, cols, color):
        n = int(arr.size)
        if n < 2:
            return
        span = float(ymax - ymin) or 1.0
        w = float(box.width())
        xv, lo, hi = fl.downsample_for_display(arr, cols, self._smooth)
        k = int(xv.size)
        if k < 2:
            return
        xs = [box.left() + w * (float(v) / float(n - 1)) for v in xv]
        ylo = [box.bottom() - box.height() * ((float(v) - ymin) / span) for v in lo]
        yhi = [box.bottom() - box.height() * ((float(v) - ymin) / span) for v in hi]
        pen = QPen(QColor(color), 1.1)
        p.setPen(pen)
        if k * 2 < n:                       # 确实抽稀了才画竖线
            p.drawLines([QLineF(xs[i], ylo[i], xs[i], yhi[i]) for i in range(k)])
        poly = QPolygonF()
        for i in range(k):
            poly.append(QPointF(xs[i], (ylo[i] + yhi[i]) / 2.0))
        p.setPen(QPen(QColor(color), 1.2))
        p.drawPolyline(poly)


class CapturePanel(QFrame):
    """抓包页主体：参数 + 抓取 + 图 + 导出。"""

    capture_requested = Signal(dict)
    smooth_changed = Signal(int)
    net_check_requested = Signal()
    help_requested = Signal()
    export_requested = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self._res = None

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)

        head = QLabel("原始波形抓包")
        head.setObjectName("CardTitle")
        lay.addWidget(head)
        lay.addWidget(uk.hint_label(
            "这一页抓的是连续的 ADC 样点（板上 112 KB 缓冲，28672 点）。"
            "默认 25 MSPS × 1.15 ms：1 kHz 信号一个周期 25000 点，分辨率 100 µs → 40 ns。"
            "抓完从串口批量回读（约 0.66 s），不占用遥测链路以外的带宽；"
            "要更长的窗口就用抽取（×2/×4/×8）换时间。", lines=3))

        # 参数行 1：源 / 抽取 / 点数
        row1 = QHBoxLayout()
        row1.setSpacing(6)
        row1.addWidget(uk.small_label("源", 30))
        self.cb_src = QComboBox()
        for label, val in SRC_ITEMS:
            self.cb_src.addItem(label, val)
        self.cb_src.setToolTip("原始 = ADC 50 MSPS；校正 = 幅值/相位校正后的 12.5 MSPS 通道")
        self.cb_src.currentIndexChanged.connect(self._refresh_est)
        row1.addWidget(self.cb_src)
        row1.addSpacing(8)
        row1.addWidget(uk.small_label("抽取", 30))
        self.cb_dec = QComboBox()
        for d in (0, 1, 2, 3):
            self.cb_dec.addItem("×%d" % (1 << d), d)
        self.cb_dec.setCurrentIndex(1)
        self.cb_dec.setToolTip("抓包前的抽取：×1 = 50 MSPS（20 ns），×2 = 25 MSPS（40 ns）")
        self.cb_dec.currentIndexChanged.connect(self._refresh_est)
        row1.addWidget(self.cb_dec)
        row1.addSpacing(8)
        row1.addWidget(uk.small_label("点数", 34))
        self.sp_len = QSpinBox()
        self.sp_len.setRange(64, cap.CAP_DEPTH)
        self.sp_len.setSingleStep(64)
        self.sp_len.setValue(cap.CAP_DEPTH)
        self.sp_len.valueChanged.connect(self._refresh_est)
        row1.addWidget(self.sp_len)
        row1.addStretch(1)
        lay.addLayout(row1)

        # 参数行 2：触发 / 电平 / 预触发
        row2 = QHBoxLayout()
        row2.setSpacing(6)
        row2.addWidget(uk.small_label("触发", 30))
        self.cb_trig = QComboBox()
        for label, val in TRIG_ITEMS:
            self.cb_trig.addItem(label, val)
        row2.addWidget(self.cb_trig)
        row2.addSpacing(8)
        row2.addWidget(uk.small_label("电平", 34))
        self.sp_level = QSpinBox()
        self.sp_level.setRange(-32768, 32767)
        self.sp_level.setValue(0)
        self.sp_level.setToolTip("边沿触发门限（有符号码值，过零点 = 0）")
        row2.addWidget(self.sp_level)
        row2.addSpacing(8)
        row2.addWidget(uk.small_label("预触发", 44))
        self.sp_pre = QSpinBox()
        self.sp_pre.setRange(0, cap.CAP_DEPTH - 64)
        self.sp_pre.setSingleStep(64)
        self.sp_pre.setValue(1024)
        self.sp_pre.setToolTip("触发点之前保留多少点（默认 1024 = 40 µs）")
        row2.addWidget(self.sp_pre)
        row2.addSpacing(8)
        row2.addWidget(uk.small_label("通道", 34))
        self.cb_chan = QComboBox()
        self.cb_chan.addItem("串口回读", "serial")
        self.cb_chan.addItem("网口 UDP", "udp")
        self.cb_chan.addItem("网口连续流", "stream")
        self.cb_chan.setToolTip(
            "串口回读：不需要网线，448 块 × 264 B = 118 KB 约 0.66 s（默认）；\n"
            "网口 UDP：抓一段整窗，约 2 ms；端口由软件自动选并写进板子 0x070C；\n"
            "网口连续流：设备不停发，界面滚动显示最近 1024 点（需要千兆网线）\n"
            "三种方式都靠串口做配置，网口只传数据。")
        self.cb_chan.currentIndexChanged.connect(self._refresh_est)
        row2.addWidget(self.cb_chan)
        row2.addSpacing(8)
        row2.addWidget(uk.small_label("显示", 34))
        self.cb_smooth = QComboBox()
        for label, w in fl.SMOOTH_MODES:
            self.cb_smooth.addItem(label, w)
        self.cb_smooth.setToolTip(
            "只影响绘制，不改导出数据。\n"
            "关 = 原始样点；3/5/9/15 点 = 零相位平滑（保峰 Savitzky-Golay）。\n"
            "实时页与 XY 图同步生效。")
        self.cb_smooth.currentIndexChanged.connect(self._on_smooth)
        row2.addWidget(self.cb_smooth)
        row2.addSpacing(8)
        row2.addWidget(uk.small_label("视图", 34))
        self.cb_view = QComboBox()
        self.cb_view.addItem("时域", "time")
        self.cb_view.addItem("频谱", "spec")
        self.cb_view.setToolTip(
            "时域：包络抽稀 + 双游标（左键放/拖，右键清），量 Δt / ΔV / 相位角。\n"
            "频谱：Hann 窗、对数频率轴、dB 相对基波；绿虚线标各次谐波与相对幅度。")
        self.cb_view.currentIndexChanged.connect(self._on_view)
        row2.addWidget(self.cb_view)
        row2.addStretch(1)
        lay.addLayout(row2)

        # 网络状态行：通道切到网口后可点「网络自检」，显示链路/ARP/端口/ping
        row_net = QHBoxLayout()
        row_net.setSpacing(6)
        self.btn_net = QPushButton("网络自检")
        self.btn_net.setToolTip("读 0x0710 的 ARP/ICMP/主机 MAC 状态、0x070C 端口，并 ping 一次板子")
        self.btn_net.clicked.connect(self.net_check_requested.emit)
        row_net.addWidget(self.btn_net)
        self.lab_net = uk.hint_label("串口回读：不占用网络", lines=1)
        row_net.addWidget(self.lab_net, 1)
        self.btn_help = QPushButton("使用指南")
        self.btn_help.setToolTip("打开「以太网通道使用指南」：接线、切换、常见问题")
        self.btn_help.clicked.connect(self.help_requested.emit)
        row_net.addWidget(self.btn_help)
        lay.addLayout(row_net)

        # 按钮行
        row3 = QHBoxLayout()
        row3.setSpacing(8)
        self.btn_cap = QPushButton("抓一次")
        self.btn_cap.setObjectName("Primary")
        self.btn_cap.clicked.connect(self._on_capture)
        row3.addWidget(self.btn_cap)
        self.btn_csv = QPushButton("导出 CSV")
        self.btn_csv.clicked.connect(lambda: self.export_requested.emit("csv"))
        row3.addWidget(self.btn_csv)
        self.btn_npy = QPushButton("导出 NPY")
        self.btn_npy.clicked.connect(lambda: self.export_requested.emit("npy"))
        row3.addWidget(self.btn_npy)
        self.btn_png = QPushButton("导出 PNG")
        self.btn_png.clicked.connect(lambda: self.export_requested.emit("png"))
        row3.addWidget(self.btn_png)
        row3.addStretch(1)
        lay.addLayout(row3)

        self.lab_est = uk.hint_label("窗口 —", lines=1)
        lay.addWidget(self.lab_est)
        self.plot = CapturePlot()
        lay.addWidget(self.plot, 1)
        self.lab_spec = uk.hint_label("", lines=1)
        lay.addWidget(self.lab_spec)
        self.lab_sum = uk.hint_label("等待抓包…", lines=2)
        lay.addWidget(self.lab_sum)

        self.set_connected(False)
        self._refresh_est()

    # ------------------------------------------------------------ 显示滤波
    def smooth(self):
        return int(self.cb_smooth.currentData() or 0)

    def set_smooth(self, w):
        """设置显示平滑（0 = 关）。只影响绘制，不动 res.s/res.c。"""
        w = int(w or 0)
        for i in range(self.cb_smooth.count()):
            if int(self.cb_smooth.itemData(i) or 0) == w:
                self.cb_smooth.setCurrentIndex(i)
                break
        self.plot.set_smooth(w)

    def _on_smooth(self, _idx):
        w = self.smooth()
        self.plot.set_smooth(w)
        self.smooth_changed.emit(w)

    # ------------------------------------------------------------ 参数
    def _on_view(self, _idx=None):
        self.plot.set_mode(self.cb_view.currentData())
        self._update_spec_text()

    def _update_spec_text(self):
        """频谱读数行：时域视图给操作提示，频谱视图给基波/THD/各次谐波。"""
        if self.plot.mode() != "spec":
            self.lab_spec.setText("时域视图：左键放两个游标量 Δt / ΔV / 相位角；右键清除")
            return
        info = self.plot.spec_info()
        if not info:
            self.lab_spec.setText("频谱：还没有足够的数据（先抓一次）")
            return
        rel = [r for r in (info.get("harmonics") or [])
               if int(r.get("h") or 0) >= 2 and float(r.get("rel_pct") or 0.0) >= 0.01]
        parts = ["H%d %.2f%%" % (int(r["h"]), float(r["rel_pct"])) for r in rel]
        self.lab_spec.setText(
            "频谱：基波 %.3f kHz ｜ THD %.2f%% ｜ %s ｜ 分辨率 %.0f Hz ｜ %d 点"
            % (float(info.get("fund_hz") or 0.0) / 1e3,
               float(info.get("thd_pct") or 0.0),
               " ".join(parts) if parts else "无明显谐波",
               float(info.get("res_hz") or 0.0), int(info.get("n") or 0)))

    def params(self):
        # ★ 复查 P17/P8：回读是按 64 点一块拼的，点数必须向下取整到 64，
        #   否则请求 1000 点会拿回 1024 点、估算与结果对不上；预触发板端会
        #   静默截到 length-1，这里也一起夹住，免得摘要/CSV 元数据写错值。
        length = max(64, (int(self.sp_len.value()) // 64) * 64)
        pre = max(0, min(int(self.sp_pre.value()), length - 1))
        return {
            "src": self.cb_src.currentData(),
            "dec_log2": self.cb_dec.currentData(),
            "length": length,
            "trig": self.cb_trig.currentData(),
            "level": self.sp_level.value(),
            "pre": pre,
            "transport": self.cb_chan.currentData(),
        }

    def _refresh_est(self):
        p = self.params()
        chan = p.get("transport")
        if chan != getattr(self, "_last_chan", None):
            self._last_chan = chan
            if chan == "serial":
                self.lab_net.setText("串口回读：不占用网络")
            else:
                self.lab_net.setText("网口：点「网络自检」查看链路 / ARP / 端口")
        self.btn_net.setEnabled(bool(self._connected))
        fs = cap.fs_for(p["src"], p["dec_log2"])
        dur = p["length"] / fs
        if p.get("transport") == "stream":
            # 连续流不按"窗口"算，改成"每 300 ms 刷新一次，界面显示最近 1024 点"
            self.lab_est.setText(
                "连续流 ｜ %.3f MSPS（%.0f ns/点）｜ 界面滚动显示最近 1024 点"
                % (fs / 1e6, 1e9 / fs))
            return
        if p.get("transport") == "udp":
            read_s = 0.002          # 千兆 UDP，82 个包（ceil(28672/350)）
            tail = "回读约 2 ms（UDP）"
        else:
            read_s = p["length"] / 64 * 264 / 180000.0
            tail = "回读约 %.1f s（串口）" % read_s
        self.lab_est.setText(
            "窗口 %.3f ms ｜ %.3f MSPS（%.0f ns/点）｜ %s"
            % (dur * 1e3, fs / 1e6, 1e9 / fs, tail))

    def _on_capture(self):
        p = self.params()
        if p.get("transport") == "stream":
            # 连续流是"开/关"，具体由主窗口调度（它管 socket 和定时器）
            self.capture_requested.emit(p)
            return
        if p.get("transport") == "udp":
            self.lab_sum.setText("抓包中…（走网口 UDP，千兆约 2 ms 收完）")
        else:
            self.lab_sum.setText("抓包中…（arm → 等触发 → 串口回读，约 0.66 s）")
        self.capture_requested.emit(p)

    def set_streaming(self, on):
        """切换"连续流运行中"的按钮文案与状态。"""
        self._streaming = bool(on)
        self._sync_btn()
        if on:
            self.lab_sum.setText("连续流运行中…（再次点击按钮停止）")

    # ------------------------------------------------------------ 结果
    def result(self):
        return self._res

    def set_busy(self, busy):
        # ★ 复查 P4：按钮的"可用"与"文案"以前由 set_busy / set_connected /
        #   set_streaming 三个写者各自决定，抓包中调一次 set_connected 就把
        #   "抓包中…"的禁用状态悄悄解掉。现在统一由 _sync_btn() 合成。
        self._busy = bool(busy)
        self._sync_btn()
        # ★ 审计 2 #16：抓包进行中改抽取/点数，会让“正在进行的这一枪”与界面显示
        #   对不上。忙碌期间把参数行锁住，抓完自动解锁。
        for w in (self.cb_src, self.cb_dec, self.sp_len, self.cb_trig,
                  self.sp_level, self.sp_pre, self.cb_chan):
            w.setEnabled(not self._busy)

    def _sync_btn(self):
        streaming = getattr(self, "_streaming", False)
        busy = getattr(self, "_busy", False)
        self.btn_cap.setEnabled(self._connected and not busy)
        self.btn_cap.setText("抓包中…" if busy else ("停止连续流" if streaming else "抓一次"))

    def set_connected(self, ok):
        self._connected = bool(ok)
        self._sync_btn()
        # 导出不需要串口：抓完拔掉线也应该能存（与记录页一致）
        has_data = self._res is not None
        for b in (self.btn_csv, self.btn_npy, self.btn_png):
            b.setEnabled(has_data)
        self.btn_net.setEnabled(self._connected and not getattr(self, "_busy", False))
        if not self._connected:
            self.lab_sum.setText("未连接：先在上方连上串口")

    def set_result(self, res):
        self._res = res
        for b in (self.btn_csv, self.btn_npy, self.btn_png):
            b.setEnabled(True)
        self.plot.set_result(res)
        msg = res.summary()
        if res.meta.get("ovf"):
            msg += "｜⚠ 请求点数超过缓冲深度，已截断"
        if res.meta.get("short"):
            msg += "｜⚠ 只覆盖 %d/%d 点（其余补 0）" % (
                int(res.meta.get("covered", 0)), int(res.n))
        if getattr(res, "missing", None):
            msg += "｜⚠ 缺 %d 段（补 0，图上黄色区段）" % len(res.missing)
        msg += "｜耗时 %.2f s" % float(res.meta.get("elapsed_s", 0.0))
        self.lab_sum.setText(msg)
        self._update_spec_text()

    def set_error(self, text):
        self.lab_sum.setText("抓包失败：%s" % text)
        self.set_busy(False)

    def set_net_status(self, text):
        """更新网络状态行（自检结果 / 错误）。"""
        self.lab_net.setText(text)

    def set_stream_error(self, text):
        """连续流模式下的错误：只改状态文字。

        ★ 不能走 set_error：它会 set_busy(False)，把按钮从"停止连续流"变回
          "抓一次"并重新可点；这时流还占着 UDP 端口，再点一次会双绑抢包。
        """
        self.lab_sum.setText("连续流：%s" % text)

    def save(self, kind, parent=None):
        """导出当前抓包结果；没有数据时返回 None。"""
        if self._res is None:
            self.lab_sum.setText("还没有可导出的数据 —— 先抓一次")
            return None
        ext = {"csv": ".csv", "npy": ".npy", "png": ".png"}[kind]
        path, _f = QFileDialog.getSaveFileName(
            parent or self, "导出抓包数据", "capture" + ext,
            {"csv": "CSV (*.csv)", "npy": "NumPy (*.npy)", "png": "PNG (*.png)"}[kind])
        if not path:
            return None
        if not path.lower().endswith(ext):
            path += ext
        bits = []
        meta = self._res.meta or {}
        if meta.get("dec_log2") is not None:
            bits.append("抽取 ×%d" % (1 << int(meta.get("dec_log2") or 0)))
        if meta.get("trig") is not None:
            bits.append("触发 %s 电平 %s" % (meta.get("trig"), meta.get("level")))
        if meta.get("pre") is not None:
            bits.append("预触发 %s 点" % meta.get("pre"))
        if self.smooth() > 1:
            bits.append("显示平滑 %d 点（仅绘制，数据未改）" % self.smooth())
        note = "；".join(bits) or None
        # ★ 复查 P6：写"临时文件 + os.replace"，失败给人话。原来文件被 Excel 占着时
        #   PermissionError 直接穿出 Qt 槽（excepthook 弹 traceback），目标文件还被截成 0 字节。
        base, dot, ext2 = path.rpartition(".")
        tmp = (base + ".part." + ext2) if dot else (path + ".part")
        try:
            if kind == "csv":
                self._res.to_csv(tmp, note=note)
            elif kind == "npy":
                got = self._res.to_npy(tmp)
                if got and str(got).lower().endswith(".csv"):
                    # 没有 numpy 时退化成 CSV：这里必须说清楚，别让人以为存了 npy
                    QMessageBox.information(self, "已改存 CSV",
                                            "没有可用的 numpy，已改存为：\n%s" % got)
                    tmp, path = str(got), str(got)
            else:
                got = self._res.to_png(tmp, note=note)
                if got and str(got).lower().endswith(".csv"):
                    QMessageBox.information(self, "已改存 CSV",
                                            "没有可用的 matplotlib，已改存为：\n%s" % got)
                    tmp, path = str(got), str(got)
            if tmp != path:
                os.replace(tmp, path)
        except Exception as exc:                        # noqa: BLE001
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except Exception:                           # noqa: BLE001
                pass
            QMessageBox.warning(self, "导出失败",
                                "写文件失败：%s\n\n目标：%s\n"
                                "（多半是文件正被 Excel 等程序占用，或磁盘已满）"
                                % (exc, path))
            self.lab_sum.setText("导出失败：%s" % exc)
            return None
        self.lab_sum.setText("已导出：%s" % path)
        return path
