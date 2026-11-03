"""「ABZ / UVW 等效采样」的独立大窗口（阶段 5 续，用户 m16915 追加要求）。

与 `wave_popup` 同一套路：**内嵌第二个 `panel_abz.AbzPanel` 实例**，分箱、横轴窗口、
通道排布、间距、方波可看/还原、清空累积、导出当前视图全部直接复用；主窗口把同一批帧
同时喂给它（见 `main_window._tick` 里的 `self._abz_win.feed`）。

独立成窗的意义：等效采样图本来是"卡片里被压扁的一条"，箱数/图幅放大后才看得清
方波判决线与理论方波的相位关系 —— 而这正是用户要"仔细观察"的地方。

Esc 只关这个窗口（`Qt.WidgetShortcut`），不碰主窗口的全局快捷键契约。
"""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import QDialog, QLabel, QVBoxLayout

import abz as az                                                  # noqa: E402
import panel_abz as pa                                           # noqa: E402


class AbzPopup(QDialog):
    def __init__(self, parent=None, bins=None):
        super().__init__(parent)
        self.setObjectName("AbzPopup")
        self.setWindowTitle("ABZ / UVW 等效采样 · 独立窗口")
        self.setModal(False)
        self.resize(1280, 620)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)
        tip = QLabel("独立窗口：与主界面同一批数据（同一套等效采样累积）；分箱、横轴窗口、"
                     "通道排布与主界面各自独立设置。Esc 关闭本窗口。")
        tip.setObjectName("Hint")
        tip.setWordWrap(True)
        lay.addWidget(tip)
        # canvas_h=None ⇒ 画布不钉高，跟着窗口一起长；show_popup=False ⇒ 这里不再放「独立窗口」按钮
        self.panel = pa.AbzPanel(bins=bins if bins in az.BINS_CHOICES else az.BINS_DEFAULT,
                                 parent=self, canvas_h=None, show_popup=False)
        lay.addWidget(self.panel, 1)
        self._esc = QShortcut(QKeySequence(Qt.Key_Escape), self)
        self._esc.setContext(Qt.WidgetShortcut)
        self._esc.activated.connect(self.close)

    # ---------------------------------------------------------------- 转发
    def feed(self, frames, force_draw=False):
        self.panel.feed(frames, force_draw=force_draw)

    def set_connected(self, conn, enabled=None):
        self.panel.set_connected(conn, enabled)

    def set_f_in(self, f_in):
        self.panel.set_f_in(f_in)

    def set_regs(self, cfg):
        self.panel.set_regs(cfg)

    def set_output(self, bits, raw=None):
        self.panel.set_output(bits, raw)

    def restore_output(self):
        self.panel.restore_output()

    def set_bins(self, bins):
        self.panel.set_bins(bins)

    def bins(self):
        return self.panel.bins()

    def notice(self, text, level="info"):
        """把主窗口的提示转发到弹窗卡片（面板自带 notice 信号，这里只在需要时用）。"""
        self.panel.notice.emit(text, level)
