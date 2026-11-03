"""全周角度补偿表（S5）的界面：导入误差曲线 → 折算成 4096 点表 → 写进板上 → 回读校验。

设计约束（改这个文件前先读）：
1. **不在这个文件里打开串口**。所有硬件动作都通过 `upload_requested` /
   `zeros_requested` / `dump_requested` 三个信号交给主窗口的任务线程，这里只做
   换算、画图、显示结果。理由：`link.SerialWorker` 是单主人模型，界面线程自己
   开一个 worker 会和主窗口抢同一个 COM 口（lut_tool.py 的 CLI 模式之所以能单独
   开，是因为它当成独立进程跑）。
2. 换算只有一条路：`regs.lut_words_from_pairs()`（arcsec → 16 位有符号 LSB，
   1 LSB = 3600*360/(2048*2^16) ≈ 0.00966 角秒）。界面上显示的「峰峰折算 LSB」
   必须和真正写进板子的值是同一个数，否则调完看不出效果还找不到原因。
3. CSV 的解析与体检复用 `lut_tool.parse_csv()` / `lut_tool.check_pairs()`，
   不要在这里另写一套（两份解析器迟早会分叉）。
"""

from __future__ import annotations

import math
import os
import sys

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPen, QPolygonF
from PySide6.QtWidgets import (QCheckBox, QFileDialog, QFrame, QHBoxLayout,
                               QLabel, QPushButton, QSizePolicy, QVBoxLayout,
                               QWidget)
from PySide6.QtCore import QPointF, QRectF

import lut_tool as lt
import regs as rg
import theme as th
import ui_kit as uk

C = th.C

LUT_N = rg.LUT_N
K_ARCSEC = 3600.0 * 360.0 / (2048.0 * (1 << 16))     # 1 LSB ≈ 0.00966″
DUMP_STEP_DEFAULT = 8                                # 读表抽样步长（4096/8 = 512 点）
WARN_JUMP = 200.0                                    # 相邻点跳变告警阈值（角秒）


# ---------------------------------------------------------------- 纯逻辑
def to_signed(v):
    """16 位无符号 → 有符号 LSB。"""
    v = int(v) & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def words_arcsec(words):
    """表值（LSB）→ 角秒，供画图用。"""
    return [to_signed(w) * K_ARCSEC for w in words]


def summarize(pairs, words):
    """给界面用的一行汇总；`pairs` 可以只算 CSV，`words` 为 None 时不折 LSB。"""
    errs = [float(p[1]) for p in pairs]
    out = {"n": len(pairs), "lo": min(errs), "hi": max(errs),
           "pp": max(errs) - min(errs), "rms": 0.0, "lsb": None,
           "deg_lo": pairs[0][0], "deg_hi": pairs[-1][0]}
    out["rms"] = math.sqrt(sum(e * e for e in errs) / len(errs))
    if words:
        w = [to_signed(x) for x in words]
        out["lsb"] = max(abs(x) for x in w)
        out["words_pp"] = max(w) - min(w)
    return out


def table_curve(words, points=360):
    """4096 点表 → 画图用的 (deg, arcsec) 折线，按机械角等分取 points 个样本。"""
    n = len(words)
    if n == 0:
        return [], []
    xs, ys = [], []
    for k in range(points):
        deg = 360.0 * k / points
        idx = int(round(deg / 360.0 * n)) % n
        xs.append(deg)
        ys.append(to_signed(words[idx]) * K_ARCSEC)
    return xs, ys


# ---------------------------------------------------------------- 曲线
class LutPlot(QWidget):
    """误差曲线：细线=量出来的点，粗线=折算后真正写进板的表。"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(210)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self._pairs = []
        self._words = []
        self._dump = {}          # 从板上读回来的 {索引: LSB}

    def clear(self):
        self._pairs, self._words, self._dump = [], [], {}
        self.update()

    def set_pairs(self, pairs, words):
        self._pairs = [(float(a), float(b)) for a, b in pairs]
        self._words = list(words or [])
        self.update()

    def set_dump(self, pts):
        self._dump = dict(pts or {})
        self.update()

    # -------------------------------------------------------------- 绘制
    def _rng(self):
        ys = [b for _a, b in self._pairs]
        if self._words:
            ys += words_arcsec(self._words)[::16]
        if self._dump:
            ys += [to_signed(v) * K_ARCSEC for v in self._dump.values()]
        if not ys:
            return -1.0, 1.0
        lo, hi = min(ys), max(ys)
        pad = max(0.5, (hi - lo) * 0.15)
        return lo - pad, hi + pad

    def paintEvent(self, _ev):                                   # noqa: N802
        p = QPainter(self)
        try:
            self._paint(p)
        finally:
            p.end()

    def _paint(self, p):
        r = self.rect()
        p.fillRect(r, QColor(C["card"]))
        box = r.adjusted(64, 12, -14, -26)
        p.setFont(QFont(self.font().family(), 7))
        if not self._pairs:
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(r, Qt.AlignCenter,
                       "还没有误差曲线：点「导入 CSV…」选一份（角度 deg, 误差 arcsec）")
            return
        lo, hi = self._rng()
        if hi - lo < 1e-9:
            hi = lo + 1.0
        span = hi - lo

        def X(deg):
            return box.left() + box.width() * (deg / 360.0)

        def Y(v):
            return box.top() + box.height() * (hi - v) / span

        # 网格与刻度
        p.setPen(QPen(QColor(C["line"]), 1, Qt.DotLine))
        for v in range(0, 361, 45):
            p.drawLine(QPointF(X(v), box.top()), QPointF(X(v), box.bottom()))
        p.setPen(QPen(QColor(C["muted"])))
        for v in range(0, 361, 90):
            p.drawText(QRectF(X(v) - 22, box.bottom() + 4, 44, 14),
                       Qt.AlignHCenter | Qt.AlignVCenter, "%d°" % v)
        steps = 4
        for k in range(steps + 1):
            v = lo + span * k / steps
            y = Y(v)
            p.setPen(QPen(QColor(C["line"]), 1, Qt.DotLine))
            p.drawLine(QPointF(box.left(), y), QPointF(box.right(), y))
            p.setPen(QPen(QColor(C["muted"])))
            p.drawText(QRectF(0, y - 7, box.left() - 6, 14),
                       Qt.AlignRight | Qt.AlignVCenter, uk.sgn("%+.1f″" % v))

        # 零线
        p.setPen(QPen(QColor(C["ok"]).darker(120), 1, Qt.DashLine))
        p.drawLine(QPointF(box.left(), Y(0.0)), QPointF(box.right(), Y(0.0)))

        # 折算后的表：画得比实测线粗，让实测点"躺在"表线上（两者差得多就是插值有问题）
        if self._words:
            xs, ys = table_curve(self._words, 360)
            poly = QPolygonF([QPointF(X(x), Y(y)) for x, y in zip(xs, ys)])
            p.setPen(QPen(QColor(C["primary"]).lighter(125), 4.0))
            p.drawPolyline(poly)

        # 量出来的点（细线 + 圆点）
        poly = QPolygonF([QPointF(X(a), Y(b)) for a, b in self._pairs])
        p.setPen(QPen(QColor(C["warn"]), 1.0))
        p.drawPolyline(poly)
        if len(self._pairs) <= 400:
            p.setBrush(QColor(C["warn"]))
            for a, b in self._pairs:
                p.drawEllipse(QPointF(X(a), Y(b)), 1.8, 1.8)
            p.setBrush(Qt.NoBrush)

        # 板上读回来的点（抽样）
        if self._dump:
            p.setPen(QPen(QColor(C["ok"]), 0.0))
            p.setBrush(QColor(C["ok"]))
            for idx, val in self._dump.items():
                x = 360.0 * idx / LUT_N
                p.drawRect(QRectF(X(x) - 1.0, Y(to_signed(val) * K_ARCSEC) - 1.0,
                                  2.0, 2.0))
            p.setBrush(Qt.NoBrush)

        # 图例
        p.setPen(QPen(QColor(C["muted"])))
        p.drawText(QRectF(box.left() + 6, box.top() + 1, 320, 13),
                   Qt.AlignLeft | Qt.AlignVCenter,
                   "粗线 折算表 ｜ 细线 CSV 实测 ｜ 绿点 板上回读")


# ---------------------------------------------------------------- 面板
class LutPanel(QFrame):
    """全周补偿表卡片。硬件动作全部抛给主窗口。"""

    upload_requested = Signal(list, bool, bool)      # words, verify, enable
    zeros_requested = Signal()
    dump_requested = Signal(int)                     # 抽样步长
    notice = Signal(str, str)                        # 文案, 级别

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self._pairs = []
        self._words = []
        self._busy = False

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 12)
        lay.setSpacing(6)
        ttl = QLabel("全周角度补偿表")
        ttl.setObjectName("CardTitle")
        lay.addWidget(ttl)
        lay.addWidget(uk.hint_label(
            "板端按机械角查表补角度（4096 点，一点 0.0879°，量程 ±0.088°）。"
            "这里做的事：读误差曲线 → 折算成表 → 写进板上 → 抽样回读确认。"
            "表覆盖不到 360° 时，359..360 段是常量外推，界面会先告警。", lines=3))

        # 第一行按钮
        row = QHBoxLayout()
        row.setSpacing(6)
        self.btn_import = QPushButton("导入 CSV…")
        self.btn_import.setToolTip("两列纯文本：机械角(deg) 误差(arcsec)；逗号/空格/制表符都行")
        self.btn_dump = QPushButton("读板上表")
        self.btn_dump.setToolTip("每 %d 点抽一个回读（≈512 次事务），用来确认表真的写进去了"
                                 % DUMP_STEP_DEFAULT)
        self.btn_zero = QPushButton("清零")
        self.btn_zero.setToolTip("整表写 0 并关表：回到出厂（不补偿）状态")
        self.btn_up = QPushButton("上传到板")
        self.btn_up.setObjectName("Primary")
        for b in (self.btn_import, self.btn_dump, self.btn_zero, self.btn_up):
            row.addWidget(b)
        row.addStretch(1)
        lay.addLayout(row)

        # 第二行选项
        opt = QHBoxLayout()
        opt.setSpacing(10)
        self.chk_verify = QCheckBox("写后逐点回读")
        self.chk_verify.setToolTip("4096 点全查一遍，约多花一倍时间；第一次上新表建议开")
        self.chk_enable = QCheckBox("上传后启用")
        self.chk_enable.setChecked(True)
        self.chk_enable.setToolTip("写 0x0145 bit0=1；不勾只写表不启用")
        opt.addWidget(self.chk_verify)
        opt.addWidget(self.chk_enable)
        opt.addStretch(1)
        lay.addLayout(opt)

        # 读数
        grid = QHBoxLayout()
        grid.setSpacing(14)
        self.v_file = uk.field(grid, "曲线", value="—", width=150)
        self.v_file.setStyleSheet("font-size:11px;")     # 文件名不该用大号数字字体
        self.v_n = uk.field(grid, "点数", value="—", width=60)
        self.v_pp = uk.field(grid, "峰峰", value="—", width=90)
        self.v_rms = uk.field(grid, "RMS", value="—", width=90)
        self.v_lsb = uk.field(grid, "折算 LSB", value="—", width=80)
        grid.addStretch(1)
        lay.addLayout(grid)

        self.plot = LutPlot()
        lay.addWidget(self.plot, 1)

        self.lab_check = QLabel("—")
        self.lab_check.setWordWrap(True)
        self.lab_check.setObjectName("Hint")
        lay.addWidget(self.lab_check)

        self.btn_import.clicked.connect(self._on_import)
        self.btn_dump.clicked.connect(self._on_dump)
        self.btn_zero.clicked.connect(self._on_zero)
        self.btn_up.clicked.connect(self._on_upload)

    # ------------------------------------------------------------ 状态
    def busy(self):
        return self._busy

    def set_busy(self, on, text=""):
        self._busy = bool(on)
        for b in (self.btn_import, self.btn_dump, self.btn_zero, self.btn_up):
            b.setEnabled(not on)
        if text:
            self.lab_check.setText(text)

    def has_table(self):
        return bool(self._words)

    def words(self):
        return list(self._words)

    def pairs(self):
        return list(self._pairs)

    def clear(self):
        self._pairs, self._words = [], []
        for w in (self.v_file, self.v_n, self.v_pp, self.v_rms, self.v_lsb):
            w.setText("—")
        self.lab_check.setText("—")
        self.plot.clear()

    def set_pairs(self, pairs, source="CSV"):
        """吃进 (deg, arcsec) 对：体检 → 折算 → 画图。返回 (ok, 报告行)。"""
        self._pairs = list(pairs)
        ok, lines = lt.check_pairs(pairs)
        try:
            words = rg.lut_words_from_pairs(pairs)
        except Exception as exc:                     # noqa: BLE001
            words = []
            lines = lines + ["✗ 折算失败：%s" % exc]
            ok = False
        self._words = words
        s = summarize(pairs, words)
        self.v_file.setText(os.path.basename(str(source))[:18])
        self.v_n.setText("%d" % s["n"])
        self.v_pp.setText("%s″" % uk.sgn("%.1f" % s["pp"]))
        self.v_rms.setText("%s″" % uk.sgn("%.2f" % s["rms"]))
        self.v_lsb.setText("±%d" % (s["lsb"] or 0) if words else "—")
        txt = " ｜ ".join(ln for ln in lines if ln.strip())
        bad = [ln for ln in lines if ln.startswith("⚠") or ln.startswith("✗")]
        if bad:
            txt = txt + "\n" + " ｜ ".join(bad)
        self.lab_check.setText(txt)
        self.plot.set_pairs(pairs, words)
        return ok, lines

    def set_dump(self, pts):
        self.plot.set_dump(pts)
        n = len(pts or {})
        if n:
            txt = self.lab_check.text()
            self.lab_check.setText("%s\n板上回读 %d 点（每 %d 点取一个）"
                                   % (txt, n, DUMP_STEP_DEFAULT))

    def set_uploaded(self, bad, ctrl, seconds):
        on = bool((ctrl or 0) & 0x01)
        if bad:
            self.lab_check.setText("✗ 回读不一致 %d 点 —— 表内容不可信，已保持关闭" % bad)
            self.notice.emit("补偿表：回读不一致 %d 点，未启用" % bad, "fault")
            return
        self.lab_check.setText("✓ 已写入 4096 点（%.1f s），0x0145 = 0x%02X（%s）"
                               % (seconds, ctrl or 0, "已启用" if on else "旁路中"))
        self.notice.emit("补偿表：写入完成 %.1f s，%s"
                         % (seconds, "已启用" if on else "未启用"), "ok")

    def set_error(self, text):
        self.lab_check.setText("✗ %s" % text)
        self.set_busy(False)

    # ------------------------------------------------------------ 交互
    def _on_import(self):
        if self._busy:
            return
        path, _flt = QFileDialog.getOpenFileName(
            self, "选误差曲线 CSV", "", "CSV / 文本 (*.csv *.txt);;所有文件 (*)")
        if not path:
            return
        try:
            pairs = lt.parse_csv(path)
        except Exception as exc:                     # noqa: BLE001
            self.notice.emit("补偿表：CSV 读不了 —— %s" % exc, "fault")
            self.lab_check.setText("✗ %s" % exc)
            return
        ok, _lines = self.set_pairs(pairs, path)
        self.notice.emit("补偿表：读入 %d 点%s"
                         % (len(pairs), "" if ok else "（有告警，见卡片）"),
                         "ok" if ok else "warn")

    def _on_upload(self):
        if self._busy or not self._words:
            self.notice.emit("补偿表：先导入一份误差曲线", "warn")
            return
        self.set_busy(True, "正在写入 4096 点…（约 1 分钟）")
        self.upload_requested.emit(self.words(), self.chk_verify.isChecked(),
                                   self.chk_enable.isChecked())

    def _on_zero(self):
        if self._busy:
            return
        self.set_busy(True, "正在清零…")
        self.zeros_requested.emit()

    def _on_dump(self):
        if self._busy:
            return
        self.set_busy(True, "正在回读…（约 15 s）")
        self.dump_requested.emit(DUMP_STEP_DEFAULT)


# ---------------------------------------------------------------- 自检
def selftest():
    n = 0
    bad = []

    def ck(name, cond, extra=""):
        nonlocal n
        n += 1
        if not cond:
            bad.append("%s %s" % (name, extra))

    ck("1 LSB", abs(K_ARCSEC - 0.0096559524536) < 1e-12, K_ARCSEC)
    ck("to_signed(0xFFFF)", to_signed(0xFFFF) == -1)
    ck("to_signed(0x8000)", to_signed(0x8000) == -32768)
    ck("to_signed(10)", to_signed(10) == 10)

    # 一条正弦误差曲线：5 点，插值到 4096 点后峰峰应该对得上
    pairs = [(0.0, 0.0), (90.0, 10.0), (180.0, 0.0), (270.0, -10.0), (359.9, 0.0)]
    words = rg.lut_words_from_pairs(pairs)
    ck("表长", len(words) == LUT_N, len(words))
    s = summarize(pairs, words)
    ck("峰峰", abs(s["pp"] - 20.0) < 1e-9)
    ck("LSB 量级", 1030 <= (s["lsb"] or 0) <= 1042, s["lsb"])
    ck("words_pp", 1900 <= s.get("words_pp", 0) <= 2100, s.get("words_pp"))
    # 折算回角秒应还原到 ±10″ 附近
    back = words_arcsec(words)
    ck("回折算", abs(max(back) - 10.0) < 0.2, max(back))
    xs, ys = table_curve(words, 72)
    ck("曲线点数", len(xs) == 72 and len(ys) == 72)
    ck("曲线首点", abs(xs[0]) < 1e-9)
    ck("90° 处为正", max(ys) > 5.0, max(ys))
    ok, lines = lt.check_pairs([(10.0, 0.0), (90.0, 10.0),
                                  (200.0, 0.0), (300.0, -10.0)])
    ck("体检覆盖不足会报", any("覆盖不足" in ln for ln in lines))
    ck("体检返回 ok=False", ok is False)
    ok2, _l2 = lt.check_pairs([(0.0, 1.0), (120.0, 2.0), (240.0, 1.5), (359.5, 1.0)])
    ck("覆盖全了 ok", ok2 is True)
    p = LutPanel()
    ck("默认无表", not p.has_table())
    p.set_pairs(pairs, "x.csv")
    ck("导入后有表", p.has_table() and len(p.words()) == LUT_N)
    ck("导入后点数显示", p.v_n.text() == "5", p.v_n.text())
    p.set_dump({0: 0, 1024: 0x03E8})
    ck("回读点进图", len(p.plot._dump) == 2)
    p.set_uploaded(0, 0x01, 61.0)
    ck("上传成功文案", "已启用" in p.lab_check.text(), p.lab_check.text())
    p.set_uploaded(3, 0x00, 90.0)
    ck("回读不符文案", "回读不一致 3 点" in p.lab_check.text())
    p.clear()
    ck("清空", not p.has_table() and p.v_n.text() == "—")
    if bad:
        print("FAIL %d/%d" % (len(bad), n))
        for b in bad:
            print("  - " + b)
        return 1
    print("panel_lut selftest: PASS (%d 项)" % n)
    return 0


def main(argv=None):
    argv = list(sys.argv if argv is None else argv)
    if "--selftest" in argv:
        from PySide6.QtWidgets import QApplication
        app = QApplication.instance() or QApplication(argv[:1])   # noqa: F841
        return selftest()
    from PySide6.QtWidgets import QApplication
    app = QApplication.instance() or QApplication(argv[:1])       # noqa: F841
    w = LutPanel()
    w.resize(760, 420)
    w.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
