"""诊断页「板上运行状态」卡片：把 v9 那几段只读寄存器读成一张表。

为什么加这张卡：`host/regs.py` 里有前馈延迟/前馈速度/前馈修正、锁定状态机、
累计掉锁、连续坏样本、板上自己跟踪的偏置、全周补偿表开关……**全都是只读、
全都算好了、全都没上过屏**。现场一旦出现"角度偶尔跳"，这些量恰恰是唯一能
说明"是掉锁了还是偏置跳了"的证据，而以前只能靠连仿真器。

设计约束（改这个文件前先读）：
1. 这个卡**不碰串口**：只发 `read_requested`，由主窗口派给后台任务线程去读，
   读完 `set_raw()` 回来。界面线程里做 29 次事务（≈15 ms）会卡一个 tick。
2. 读失败就是"—"，不拿 0 顶（0x0130 = 0 恰好是合法的 INIT，顶上去就是骗人）。
3. 行定义、解码、文案全在 `regs.status_rows()` 里（有 --selftest），这里只摆控件。
"""

from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (QCheckBox, QFrame, QGridLayout, QHBoxLayout,
                               QLabel, QPushButton, QVBoxLayout)

import regs
import theme as th
import ui_kit as uk

C = th.C


class StatusPanel(QFrame):
    """板上运行状态（只读镜像）。"""

    read_requested = Signal()
    #  写类动作单独发信号：面板自己不开串口，一切走主窗口的任务线程
    bias_requested = Signal(bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self._rows = {}

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 12)
        lay.setSpacing(8)

        head = QLabel("板上运行状态")
        head.setObjectName("CardTitle")
        lay.addWidget(head)
        lay.addWidget(uk.hint_label(
            "前馈 / 锁定状态机 / 偏置慢跟踪 / 全周补偿表这几段地址以前在界面上一个都没有，"
            "它们决定了「转得好不好」，却只能靠猜。这里读一遍 ≈29 次事务（15 ms），"
            "不影响 10 kHz 遥测。读不到的行显示「—」，不会拿 0 冒充。", lines=3))

        row = QHBoxLayout()
        row.setSpacing(8)
        self.btn_read = QPushButton("读一次")
        self.btn_read.setToolTip("读 0x0103…0x0145 共 %d 个只读/半只读地址" % len(regs.STATUS_ADDRS))
        self.btn_read.clicked.connect(self.read_requested.emit)
        row.addWidget(self.btn_read)
        self.cb_auto = QCheckBox("每 2 s 自动读")
        self.cb_auto.setToolTip("跟着状态轮询一起读；只在诊断页可见时生效")
        row.addWidget(self.cb_auto)
        self.btn_bias = QPushButton("打开偏置慢跟踪")
        self.btn_bias.setToolTip(
            "写 0x0122 bit1（复位值 0，所以厂家默认是关的）。关着的时候直流偏置"
            "留在信号里：实测 +91/+205 LSB ⇒ 折算 0.86″，前端合计 0.92″；"
            "打开后板上自动减掉，实测 0.34″。掉电复位后要再点一次。")
        self.btn_bias.clicked.connect(lambda: self.bias_requested.emit(True))
        row.addWidget(self.btn_bias)
        row.addStretch(1)
        lay.addLayout(row)

        grid = QGridLayout()
        grid.setHorizontalSpacing(12)
        grid.setVerticalSpacing(5)
        for r, (name, value, note) in enumerate(regs.status_rows({})):
            lab_n = QLabel(name)
            lab_n.setObjectName("FieldName")
            lab_n.setMinimumWidth(84)
            uk.lock_row_height(lab_n)
            lab_v = QLabel(value)
            lab_v.setObjectName("BigValueSmall")
            lab_v.setProperty("mono", "true")
            # ★ 值列必须预留宽度并按「含汉字的行高」锁死：这一列会在
            #   「—」（22 px）和「曾锁定 当前锁定」（160 px）之间来回切，
            #   不预留的话每次「读一次」整张表都横向抽一次，说明列跟着跳。
            lab_v.setMinimumWidth(168)
            uk.lock_row_height(lab_v)
            lab_h = QLabel(note)
            lab_h.setObjectName("Hint")
            lab_h.setMinimumWidth(400)
            grid.addWidget(lab_n, r, 0)
            grid.addWidget(lab_v, r, 1)
            grid.addWidget(lab_h, r, 2)
            self._rows[name] = lab_v
        grid.setColumnStretch(2, 1)
        lay.addLayout(grid)

        self.lab_note = uk.hint_label("还没有读过（点「读一次」）", lines=1)
        lay.addWidget(self.lab_note)
        lay.addStretch(1)

    # ------------------------------------------------------------- 外部接口
    def auto(self):
        return bool(self.cb_auto.isChecked())

    def set_reading(self, busy):
        self.btn_read.setEnabled(not busy)
        self.btn_read.setText("读取中…" if busy else "读一次")
        self.btn_bias.setEnabled(not busy)

    def set_bias_done(self, ok, text):
        """偏置开关的结果。成功不弹框，直接写进提示行（这行本来就是给结论的）。"""
        self.lab_note.setText(text)
        self.lab_note.setStyleSheet("color:%s;" % (C["ok"] if ok else C["fault"]))

    def set_raw(self, raw):
        """raw = {寄存器地址: 字节值}，来自主窗口的后台读取任务。"""
        raw = raw or {}
        ok = 0
        for name, value, _note in regs.status_rows(raw):
            lab = self._rows.get(name)
            if lab is None:
                continue
            lab.setText(value)
            if value != "—":
                ok += 1
        n = len(regs.STATUS_ADDRS)
        if ok == 0:
            self.lab_note.setText("一个都没读到（链路忙或板子没应答）")
            self.lab_note.setStyleSheet("color:%s;" % C["fault"])
            return
        lv = "ok" if ok >= n - 1 else ("warn" if ok * 2 >= n else "fault")
        self.lab_note.setText("读了 %d/%d 个地址（前馈、锁定、偏置、补偿表都在这张表里）"
                              % (ok, n))
        self.lab_note.setStyleSheet("color:%s;" % C[lv])

    def set_error(self, text):
        self.lab_note.setText(str(text))
        self.lab_note.setStyleSheet("color:%s;" % C["fault"])

    def clear(self):
        for lab in self._rows.values():
            lab.setText("—")
        self.lab_note.setText("还没有读过（点「读一次」）")
        self.lab_note.setStyleSheet("")
        self.set_reading(False)
