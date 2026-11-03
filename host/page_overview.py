"""概览页（阶段 2 · R17）：只放结论，不放数字墙。

用户的抱怨（m12144）是"一个界面上有很多很多信息，很乱" —— 这一页就是解药：
六行，每行一句结论；想知道为什么，点右边的「查看 ›」跳到那一页。
真实数据由主窗口在既有的刷新路径里 `set_row()` 推进来（本文件不碰串口，离线可测）。
"""

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (QFrame, QGridLayout, QHBoxLayout, QLabel,
                               QPushButton, QVBoxLayout)

import theme as th
import ui_font as uf

C = th.C

# 行定义：(键, 行名, 跳到哪一页, 悬停说明)
ROWS = (("device", "设备与链路", "diag", "型号 / 固件版本 / 帧率 / 校验错"),
        ("freq", "输入频率", "live", "1 s 平滑窗的分辨力约 ±1 Hz（1 kHz 输入时 0.1%）"),
        ("rpm", "机械转速", "live", "60 × 输入频率 ÷ 极对数"),
        ("amp", "信号幅值", "live", "r = √(s²+c²) 与门限比（0.60~1.20 满量程）"),
        ("front", "前端质量", "live",
         "s-c 点云回归出的幅值/正交/偏置折算成角度误差；取点不足时不给结论"),
        ("alarm", "告警", "alarm", "实时位 + 锁存位；有锁存到「告警」页清"),
        ("record", "记录", "record", "是否在记录 / 这次落盘多少帧"))


class OverviewPage(QFrame):
    """结论行 + 跳页按钮（行数由 ROWS 决定，不写死）。"""

    jump_requested = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 12, 14, 14)
        lay.setSpacing(8)
        # ★ 用户反馈（m15813）：删掉「现在怎么样」这个标题（下面还有一句说明，够了）。
        hint = QLabel("每行一句话结论；要看细节点右边的「查看 ›」，左侧栏会跟着切页。")
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        lay.addWidget(hint)

        grid = QGridLayout()
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(8)
        self._val = {}
        self._ver = {}
        self._pages = {}
        for r, (key, name, page, note) in enumerate(ROWS):
            lab = QLabel(name)
            lab.setObjectName("FieldName")
            val = QLabel("—")
            val.setObjectName("BigValueSmall")
            val.setProperty("mono", "true")
            # 阶段 3：读数标签用 Inter 的 tabular figures（与 ui_kit.field() 同一条规矩：
            # 谁造 mono 标签谁开 tnum；否则懒建的标签会漏掉）
            uf.use_tabular(val)
            ver = QLabel("待数据")
            ver.setObjectName("Hint")
            btn = QPushButton("查看 ›")
            btn.setObjectName("Ghost")
            btn.setToolTip("%s：%s" % (name, note))
            btn.clicked.connect(lambda _c=False, p=page: self.jump_requested.emit(p))
            grid.addWidget(lab, r, 0)
            grid.addWidget(val, r, 1)
            grid.addWidget(ver, r, 2)
            grid.addWidget(btn, r, 3)
            self._val[key] = val
            self._ver[key] = ver
            self._pages[key] = page
        grid.setColumnStretch(1, 1)
        grid.setColumnStretch(2, 2)
        lay.addLayout(grid)
        lay.addStretch(1)
        self._stale = True

    # ------------------------------------------------------------------ 接口
    def set_row(self, key, value=None, verdict=None, level="ok"):
        """更新一行。value = 主读数；verdict = 一句判定；level 决定判定颜色。"""
        if key not in self._val:
            return False
        if value is not None:
            self._val[key].setText(str(value))
        if verdict is not None:
            lab = self._ver[key]
            lab.setText(str(verdict))
            lab.setTextInteractionFlags(Qt.NoTextInteraction)
            lab.setStyleSheet("color:%s;" % C.get(level, C["muted"]))
        self._stale = False
        return True

    def clear(self):
        """回到"待数据"（断开/换端口时叫一次）。"""
        for key in self._val:
            self._val[key].setText("—")
            self._ver[key].setText("待数据")
            self._ver[key].setStyleSheet("color:%s;" % C["muted"])
        self._stale = True

    def value(self, key):
        return self._val[key].text() if key in self._val else ""

    def verdict(self, key):
        return self._ver[key].text() if key in self._ver else ""

    def values(self):
        return {k: (self._val[k].text(), self._ver[k].text()) for k in self._val}

    def rows(self):
        return [r[0] for r in ROWS]

    def page_of(self, key):
        return self._pages.get(key)
