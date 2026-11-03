"""「输入信号波形」的独立大窗口（阶段 5 C 批，用户 m15713 第 9 条）。

设计取舍：**内嵌第二个 `panel_wave.WavePanel` 实例**，而不是另写一套画图代码 ——
触发源、时基/幅值档位、叠加/分离、恢复自动、暂停刷新、导出当前视图全部直接复用，
主窗口只要把同一批帧同时喂给它（见 `main_window._tick` 里的 `self._wave_win.feed`）。
图内的 Ctrl+滚轮缩放、左键拖动、双击恢复自动由 `ui_kit.ScopeNav` 提供，与主界面一致。

Esc 只关这个窗口（`Qt.WidgetShortcut`），不碰主窗口的全局快捷键契约。
"""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import QDialog, QLabel, QVBoxLayout

import panel_wave as pw                                          # noqa: E402


class WavePopup(QDialog):
    def __init__(self, parent=None, capacity=1500):
        super().__init__(parent)
        self.setObjectName("WavePopup")
        self.setWindowTitle("输入信号波形 · 独立窗口")
        self.setModal(False)
        self.resize(1280, 640)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)
        tip = QLabel("独立窗口：与主界面同一批数据；图内 Ctrl+滚轮缩放、左键拖动平移、"
                     "双击恢复自动。Esc 关闭本窗口。")
        tip.setObjectName("Hint")
        tip.setWordWrap(True)
        lay.addWidget(tip)
        # canvas_h=None ⇒ 画布不钉高，跟着窗口一起长；show_popup=False ⇒ 这里不再放「独立窗口」按钮
        self.panel = pw.WavePanel(capacity=capacity, parent=self,
                                  canvas_h=None, show_popup=False)
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

    def set_status(self, status):
        self.panel.set_status(status)
