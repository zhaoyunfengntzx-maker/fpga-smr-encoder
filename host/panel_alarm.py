"""告警与故障卡片（需求 M7）。

* 实时位来自遥测帧（10 kHz，每帧的 io_flags / stat / io_state）——刷新快，能看到瞬态
* 锁存位来自寄存器 `0x0404`（一次读同时拿到 0x0405 锁存字节）与 `0x053A`
  ——由主窗口每 2 s 轮询一次，并把原始字节打在界面上
* 「清除锁存告警」按钮写 `0x0405 = 0x00FF`（W1C：写 1 清对应位；写 bit0 还会同拍
  发 1 拍 `clr_otr` 脉冲清掉 ADC 内部的 sticky OTR）
  ★ 提醒：若输入还压在满量程上，清完几毫秒 `otr` 会再亮，这不是清位失败
    （见 docs/DEV_STATUS.md §1.21 与 docs/07_board_checklist.md:117 的实测记录）
"""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal                       # noqa: E402
from PySide6.QtWidgets import (QCheckBox, QFrame, QGridLayout,  # noqa: E402
                               QHBoxLayout, QLabel, QPushButton, QVBoxLayout)

import alarm as sg                                          # noqa: E402
import theme as th                                           # noqa: E402
import ui_kit as uk                                          # noqa: E402

C = th.C

# level → (底色, 字色)；浅底走 theme 的 *_soft 令牌（阶段 3 起不再硬编码色值）
_CHIP = {
    "fault": (C["fault"], "#FFFFFF"),
    "warn": (C["warn"], "#FFFFFF"),
    "ok": (C["ok_soft"], C["ok"]),
    "info": (C["info_soft"], C["primary"]),
    "idle": (C["chip_off"], C["muted"]),
}


class AlarmPanel(QFrame):
    """红=故障、橙=警告、蓝=提示、灰=无数据/正常待测。"""

    clear_requested = Signal()
    refresh_requested = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self.status = None                      # 最近一次寄存器读回的 dict
        self.frames_last = []
        self.chips = {}
        self.details = {}

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)

        title = QLabel("告警与故障")
        title.setObjectName("CardTitle")
        lay.addWidget(title)
        hint = QLabel("实时位取自遥测帧（10 kHz）；锁存位每 2 秒读 0x0404/0x053A。"
                      "红=故障　橙=警告　蓝=提示　灰=正常/待测")
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        uk.fix_lines(hint, 2)
        lay.addWidget(hint)

        grid = QGridLayout()
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(6)
        grid.setVerticalSpacing(3)
        n = len(sg.ALARM_ROWS)
        half = (n + 1) // 2
        for i, (key, name, detail) in enumerate(sg.ALARM_ROWS):
            col = 0 if i < half else 3
            r = i if i < half else i - half
            lab_name = QLabel(name)
            lab_name.setObjectName("FieldName")
            lab_name.setMinimumWidth(84)
            lab_name.setToolTip(detail)
            chip = QLabel("—")
            chip.setAlignment(Qt.AlignCenter)
            # 只给下限、不给定宽：像“0x053A b0 置位”这种长文案实测要 164 px，
            # 原来 setFixedWidth(108) 会把两端裁掉，看着像乱码（审计发现）
            chip.setMinimumWidth(108)
            chip.setMaximumWidth(230)
            chip.setStyleSheet("border-radius:4px; padding:1px 4px; color:%s; background:%s;"
                               % (C["muted"], C["chip_off"]))
            chip.setToolTip(detail)
            grid.addWidget(lab_name, r, col)
            grid.addWidget(chip, r, col + 1)
            self.chips[key] = chip
            self.details[key] = detail
        lay.addLayout(grid)

        # R20（批次 5）：「幅值越限」芯片文案里带实测 r，2 秒一次轮询会跳 ⇒ 显示层稳定化。
        #   alarm.py 保持纯逻辑，稳定器只在这层用（悬停看原始值）
        self.st_r = uk.Stable("amp_r")

        row = QHBoxLayout()
        row.setSpacing(8)
        self.btn_clear = QPushButton("清除锁存告警")
        self.btn_clear.setObjectName("Primary")
        self.btn_clear.setEnabled(False)
        self.btn_clear.setToolTip("写 0x0405 = 0x00FF（W1C：写 1 清对应位；同拍发 1 拍脉冲清 ADC 内部"
                                  " sticky OTR）。若输入仍在满量程上，清完几毫秒会再亮，属正常。")
        self.btn_clear.clicked.connect(self.clear_requested.emit)
        row.addWidget(self.btn_clear)
        row.addStretch(1)
        lay.addLayout(row)

        self.lab_raw = QLabel("锁存状态未读到")
        self.lab_raw.setObjectName("Hint")
        self.lab_raw.setWordWrap(True)
        uk.fix_lines(self.lab_raw, 3)
        lay.addWidget(self.lab_raw)
        lay.addStretch(1)

    # ---------------------------------------------------------------- 外部接口
    def set_connected(self, conn, enabled=None):
        en = bool(conn if enabled is None else enabled)
        self.btn_clear.setEnabled(en)

    def reset(self):
        self.status = None
        self._state = None                 # ★ 不清的话，概览/等级仍显示上次结论
        self.frames_last = []
        for chip in self.chips.values():
            self._paint(chip, "idle", "—")
        self.chips["amp"].setToolTip(self.details["amp"])
        self.st_r.reset()
        self.lab_raw.setText("锁存状态未读到")

    def set_status(self, status):
        """status: task_read_status() 的返回值（可为 None）。"""
        self.status = status
        self._refresh()
        if status:
            self.lab_raw.setText(sg.status_summary(status))

    def set_frames(self, frames):
        """喂最近收到的帧（只要最新一帧就能定实时位）。"""
        if frames:
            self.frames_last = frames

    def refresh_readouts(self):
        """R20：按当前显示口径重画芯片文案（切「原始值」时由主窗口调）。"""
        self._refresh()

    # ---------------------------------------------------------------- 内部
    def _paint(self, lab, level, text):
        bg, fg = _CHIP.get(level, _CHIP["idle"])
        lab.setText(text)
        lab.setStyleSheet("border-radius:4px; padding:1px 4px; color:%s; background:%s;"
                          % (fg, bg))

    def _refresh(self):
        st = self.status or {}
        r = None
        if self.frames_last:
            f = self.frames_last[-1]
            # R20：芯片里的 r 走稳定显示 —— ★ 2026-10-17 全面自查核实：
            #   r 只进 sg.evaluate() 的**文案**（host/alarm.py 的 `"r=%.0f 越限/正常"`），
            #   越限判据来自板上位（io_flags b1/b2/b7、锁存 b5），不经这个稳定器 ⇒
            #   稳定显示不会掩盖真越限（旧注释"判据仍用稳定值"措辞误导）。
            r = self.st_r.update(
                float(sg.amp_sq_of(f.get("s", 0), f.get("c", 0))) ** 0.5)
        else:
            self.st_r.reset()
        r_low = r_high = None
        if st.get("amp_low_sq") and st.get("amp_high_sq"):
            r_low, r_high = sg.amp_limits(st["amp_low_sq"], st["amp_high_sq"])
        state = sg.evaluate(self.frames_last, self.status or None,
                            r=r, r_low=r_low, r_high=r_high)
        self._state = state
        for key, chip in self.chips.items():
            level, text = state.get(key, ("idle", "—"))
            self._paint(chip, level, text)
        self.chips["amp"].setToolTip(
            self.details["amp"] + "\n" + self.st_r.tip("实时取自遥测帧，锁存位看 0x053A"))
        if st and st.get("hexes"):
            extra = st["hexes"]
            self.lab_raw.setText(sg.status_summary(st) + "｜" + extra)

    def level(self, key):
        """某一项的等级（给「概览」页配色用；没数据时是 idle）。"""
        return (getattr(self, "_state", None) or {}).get(key, ("idle", ""))[0]

    def summary(self):
        """给「概览」页用的一句话结论：挑最严重的那一项，没异常就说“全部正常”。"""
        names = {k: n for k, n, _d in getattr(sg, "ALARM_ROWS", ())}
        order = {"fault": 0, "warn": 1, "ok": 2, "info": 2}
        worst = None
        for key in self.chips:
            lv, txt = (getattr(self, "_state", None) or {}).get(key, ("idle", "—"))
            if lv in ("idle", None):
                continue
            if worst is None or order.get(lv, 3) < order.get(worst[0], 3):
                worst = (lv, txt, key)
        if worst is None:
            return ("idle", "待数据")
        lv, txt, key = worst
        if order.get(lv, 3) <= 1:                      # fault / warn 才需要点名
            return (lv, "%s：%s" % (names.get(key, key), txt))
        return ("ok", "全部正常")
