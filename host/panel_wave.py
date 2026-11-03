"""输入信号波形卡片（需求 M4）：s_n/c_n 时域 + 李萨如圆 + 幅值/OTR。

★ 必须知道的两件事（写进界面提示，避免误读）：
  1. 板子只给 10 kHz 的**快照**，不是连续采样。输入频率超过 5 kHz（帧率一半）
     时，按帧时间轴画的 s/c 波形**必然混叠**（20 kHz 输入看起来像慢速摆动）。
     真正有意义的形状看李萨如圆：圆上的点只取决于 (s,c) 这一对，与相位无关。
  2. 输入频率恰好是帧率整数倍时，连续帧会落在圆上同一点，李萨如"缩成一点"——
     这不是坏了。输入 20084 Hz（≈2×帧率）时每帧相位漂 ~3°，1500 帧能扫 35 圈。
"""

from __future__ import annotations

import math
import time

from PySide6.QtCore import QEvent, Qt, Signal                  # noqa: E402
from PySide6.QtWidgets import (QCheckBox, QComboBox, QFrame,   # noqa: E402
                               QGridLayout, QHBoxLayout, QLabel,
                               QPushButton, QVBoxLayout, QWidget)

import alarm as sg                                          # noqa: E402
import numpy as np
import filters as fl
import theme as th
import ui_font as uf                                           # noqa: E402
import ui_kit as uk                                          # noqa: E402
import ui_prefs as up                                        # noqa: E402

C = th.C

try:                                                            # matplotlib 可选
    import matplotlib                                          # noqa: E402
    matplotlib.use("QtAgg")
    from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg as FigureCanvas
    from matplotlib.figure import Figure
    matplotlib.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False
    HAS_MPL = True
except Exception:                                               # pragma: no cover
    HAS_MPL = False

REDRAW_MIN_S = 0.10      # 最快 10 次/秒（需求：波形刷新 ≥10 次/秒不卡）
REDRAW_MAX_S = 0.50

# ---- R2 示波器式量程（批次 3）：横轴档位固定成 1-2-5 序列，免得轴标签一直跳
# ---- R9①（批次 4）：在 1-2-5 之间插进 1.5 / 3 / 7.5 / 15 / 75 / 150 —— 档位更细，仍是规整刻度
X_SPANS_MS = (0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 7.5, 10.0, 15.0, 20.0, 30.0,
              50.0, 75.0, 100.0, 150.0, 200.0, 300.0)
Y_FULLS = (1.0, 0.75, 0.5, 0.35, 0.25, 0.15, 0.1)   # 满量程倍数（±y_full×FS）
FINE_STEP = 0.9                             # R9② 微调倍率（Shift+方向键，不进档位表）
AUTO_CYCLES = 2.0                           # 自动时横轴显示约 2 个输入周期

def _nice_span(ms):
    """把"大约需要多少 ms"取成 1-2-5 的整齐值（0.05 / 0.1 / 0.2 / 0.5 / 1 …）。"""
    import math
    if ms <= 0:
        return 0.05
    e = math.floor(math.log10(ms))
    base = 10.0 ** e
    for m in (1.0, 2.0, 5.0, 10.0):
        if m * base >= ms - 1e-12:
            return m * base
    return 10.0 * base

RAW_MIN_SPAN_MS = 0.05      # 原始样点模式的下限：12.5 MSPS 下 0.05 ms 还有 625 点
LAYOUTS = ("overlay", "split")
LAYOUT_TEXT = {"overlay": "叠加", "split": "分离"}

# ---- 阶段 5（C 批，用户 m15713）：示波器式触发。原来是"窗口永远钉在最新帧"，
#      所以波形一直在向左滑；改成"窗口钉在触发点上"，画面就相对静止了。
#      TRIG_POS = 触发点**右侧**保留的画幅比例（0.25 ⇒ 右边 25% 看触发后、
#      左边 75% 看触发前）。
TRIG_POS = 0.25
TRIG_SOURCES = (("s", "s_n 过零（升）"),
                ("c", "c_n 过零（升）"),
                ("z", "Z 索引（升沿）"),
                ("off", "自由（跟随最新帧）"))
TRIG_TEXT = dict(TRIG_SOURCES)
TRIG_KEYS = tuple(k for k, _ in TRIG_SOURCES)


class WavePanel(QFrame):
    export_view_requested = Signal()      # 「导出当前视图」（主窗口收下后落盘）
    popup_requested = Signal()            # 「独立窗口」（阶段 5 C 批；主窗口开大窗口）

    def __init__(self, capacity=1500, parent=None, canvas_h=250, show_popup=True):
        super().__init__(parent)
        self.setObjectName("Card")
        self.buf = sg.WaveBuffer(capacity=capacity)
        # 网口连续流的"真波形"通路：raw 非空时优先画它（12.5 MSPS 的原始样点），
        # 10 kHz 帧流仍照旧进 buf 供读数用。
        self._raw = None            # (s_array, c_array, fs_hz)
        self._raw_us = 0.0          # 这一块覆盖多少微秒（画标题用）
        self._smooth = 0            # 显示平滑窗口点数（0 = 关），只影响绘制
        self.paused = False
        self.status = None
        self.f_in = None
        self._last_draw = 0.0

        self._span_hyst = None      # 自动横轴的迟滞记忆（防止档位每帧翻）
        self._draw_s = 0.0
        self._interval = REDRAW_MIN_S
        self._draws = 0
        # ---- R2 量程状态（默认从 ui_prefs.json 恢复；面板只改内存，主窗口关窗时落盘）
        self.x_mode = up.choice("wave", "x_mode", ("auto", "manual"), "auto")
        self.x_span_ms = up.number("wave", "x_span_ms", min(X_SPANS_MS), max(X_SPANS_MS), 300.0)
        self.y_mode = up.choice("wave", "y_mode", ("auto", "manual"), "auto")
        self.y_full = up.number("wave", "y_full", min(Y_FULLS), max(Y_FULLS), 1.0)
        self.layout_mode = up.choice("wave", "layout", LAYOUTS, "overlay")
        self.trig_mode = up.choice("wave", "trig", TRIG_KEYS, "s")
        self._trig_t = None        # 上一次接受的触发时刻（缓冲时间轴，秒）
        self.x_off_ms = 0.0        # 横轴右边界（0 = 最新帧）；拖动平移会改它
        self.y_off = 0.0           # 纵轴偏移（拖动平移会改它）
        self._nav = None           # ui_kit.ScopeNav（Ctrl+滚轮/拖动/双击，装在图建立之后）

        # 顶层用 QGridLayout：上控制条 + 下方图表（阶段 2 取消了"单卡放大"，
        # 所以只保留这一种版面；卡片放不下时靠分页解决，不再把卡片撑满窗口）
        lay = QGridLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setHorizontalSpacing(10)
        lay.setVerticalSpacing(8)
        lay.setColumnStretch(0, 1)
        self._lay = lay
        self.lab_nompl = None

        head = QHBoxLayout()
        title = QLabel("输入信号波形")
        title.setObjectName("CardTitle")
        title.setToolTip("双击这个标题可以弹出独立大窗口（阶段 5）")
        title.installEventFilter(self)      # 双击标题 → popup_requested
        self.lab_title = title
        head.addWidget(title)
        head.addStretch(1)
        self.chk_pause = QCheckBox("暂停刷新")
        self.chk_pause.setProperty("switch", "true")     # 阶段 3：状态开关用滑块外观
        self.chk_pause.setToolTip("冻结画面方便读数；数据仍在后台接收")
        self.chk_pause.toggled.connect(self._on_pause)
        head.addWidget(self.chk_pause)
        lay.addLayout(head, 0, 0, 1, 2)

        self.lab_hint = QLabel("取最近 %d 帧（%.0f ms）；输入频率超过 5 kHz 时时间轴波形会混叠，"
                               "请看李萨如圆。" % (capacity, capacity / 10.0))
        self.lab_hint.setObjectName("Hint")
        self.lab_hint.setWordWrap(True)
        uk.fix_lines(self.lab_hint, 3)
        lay.addWidget(self.lab_hint, 1, 0, 1, 2)

        # ---- R2 示波器式量程控件（时基 / 幅值 / 通道排布 / 导出当前视图）
        # ---- 控件登记成"组"，由 _fill_ctrl() 排进一行
        grp_tdiv = [uk.small_label("时基", 32)]
        self.cmb_tdiv = QComboBox()
        self.cmb_tdiv.setToolTip("横轴满屏时长（1 帧 = 0.1 ms，最细 0.5 ms ≈ 5 帧）。"
                                 "选「自动」时按输入频率显示约 2 个周期；"
                                 "手动选一档即锁定（←/→ 逐档、Shift+←/→ 微调、"
                                 "Ctrl+滚轮缩放、双击图内恢复自动）")
        self.cmb_tdiv.addItem("自动（跟随输入）", "auto")
        for v in X_SPANS_MS:
            self.cmb_tdiv.addItem("满屏 %g ms" % v, v)
        self.cmb_tdiv.currentIndexChanged.connect(self._on_tdiv)
        self.btn_tdiv_prev = uk.step_button("◀", "时基上一档（更细：满屏时间更短）\n快捷键 ←")
        self.btn_tdiv_prev.clicked.connect(lambda: self.step_x(-1))
        self.btn_tdiv_next = uk.step_button("▶", "时基下一档（更粗：满屏时间更长）\n快捷键 →")
        self.btn_tdiv_next.clicked.connect(lambda: self.step_x(+1))
        grp_tdiv += [self.btn_tdiv_prev, self.cmb_tdiv, self.btn_tdiv_next]
        grp_vdiv = [uk.small_label("幅值", 32)]
        self.cmb_vdiv = QComboBox()
        self.cmb_vdiv.setToolTip("纵轴满量程（Q1.15 满刻度 = 32768）。手动档即锁定"
                                 "（↑/↓ 逐档、Shift+↑/↓ 微调）")
        self.cmb_vdiv.addItem("自动", "auto")
        for v in Y_FULLS:
            self.cmb_vdiv.addItem("±%.2f FS" % v, v)
        self.cmb_vdiv.currentIndexChanged.connect(self._on_vdiv)
        self.btn_vdiv_out = uk.step_button("−", "幅值缩小一档（曲线变矮，容得下更大信号）\n快捷键 ↓")
        self.btn_vdiv_out.clicked.connect(lambda: self.step_y(-1))
        self.btn_vdiv_in = uk.step_button("+", "幅值放大一档（曲线变高，看细节）\n快捷键 ↑")
        self.btn_vdiv_in.clicked.connect(lambda: self.step_y(+1))
        grp_vdiv += [self.btn_vdiv_out, self.cmb_vdiv, self.btn_vdiv_in]
        grp_layout = [uk.small_label("排布", 32)]
        self.cmb_layout = QComboBox()
        self.cmb_layout.setToolTip("叠加：s_n/c_n 画在同一条基线上；分离：各占一条，便于分别读数")
        self.cmb_layout.addItem(LAYOUT_TEXT["overlay"], "overlay")
        self.cmb_layout.addItem(LAYOUT_TEXT["split"], "split")
        self.cmb_layout.currentIndexChanged.connect(self._on_layout)
        grp_layout.append(self.cmb_layout)
        # 阶段 5（C 批）：触发源下拉 —— 把窗口钉在触发点上，波形才"站得住"
        grp_trig = [uk.small_label("触发", 32)]
        self.cmb_trig = QComboBox()
        self.cmb_trig.setToolTip("把窗口钉在触发点上（真示波器的做法）⇒ 波形相对静止。\n"
                                 "过零点用线性插值定位，比「取最近那个样本点」准得多。\n"
                                 "选「自由」就回到「跟着最新帧滑动」的老行为。")
        for _k, _t in TRIG_SOURCES:
            self.cmb_trig.addItem(_t, _k)
        self.cmb_trig.currentIndexChanged.connect(self._on_trig)
        grp_trig.append(self.cmb_trig)
        self.btn_auto = QPushButton("恢复自动")
        self.btn_auto.setToolTip("横轴/纵轴都回到自动量程（等价于在图里双击）")
        self.btn_auto.clicked.connect(self.reset_auto)
        grp_auto = [self.btn_auto]
        self.btn_export_view = QPushButton("导出当前视图")
        self.btn_export_view.setToolTip("按当前横轴/纵轴量程导出 PNG（与全貌导出的像素契约相同）")
        self.btn_export_view.clicked.connect(lambda: self.export_view_requested.emit())
        self.btn_popup = QPushButton("独立窗口")
        self.btn_popup.setToolTip("把这块波形放进一个可以随意拉大的独立窗口（同一批数据、同一套控件）；"
                                  "双击卡片标题也能打开")
        self.btn_popup.clicked.connect(lambda: self.popup_requested.emit())
        self.btn_popup.setVisible(bool(show_popup))     # 独立窗口里自己不需要这个按钮
        grp_export = [self.btn_export_view, self.btn_popup]
        self._ctrl_groups = (grp_tdiv, grp_vdiv, grp_trig, grp_layout, grp_auto, grp_export)
        self._ctrl_grid = QGridLayout()
        self._ctrl_grid.setContentsMargins(0, 0, 0, 0)
        self._ctrl_grid.setHorizontalSpacing(6)
        self._ctrl_grid.setVerticalSpacing(6)
        self._fill_ctrl()

        # 控制与读数的整体容器（阶段 2 起只有一种版面：控制条铺在上方整宽）
        self.side = QWidget()
        side_lay = QVBoxLayout(self.side)
        side_lay.setContentsMargins(0, 0, 0, 0)
        side_lay.setSpacing(6)
        side_lay.addLayout(self._ctrl_grid)

        self.lab_view = QLabel("量程：—")
        self.lab_view.setObjectName("Hint")
        uk.fix_lines(self.lab_view, 1)
        side_lay.addWidget(self.lab_view)

        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(2)
        # R7-B：读数块定宽不拉伸 —— 多出来的宽度全给第 3 列，两列读数紧挨着（原来是摊满整行）
        grid.setColumnStretch(2, 1)
        self.v_rmean = uk.field(grid, "r 均值", "—", width=76, row=0, col=0)
        self.v_span = uk.field(grid, "r 范围", "—", width=76, row=0, col=1)
        self.v_round = uk.field(grid, "圆度偏差", "—", width=76, row=1, col=0)
        # vmin 给 176：这一格会显示「门限未读到」（汉字比数字宽），留窄了列宽会跳
        self.v_amp = uk.field(grid, "幅值判定", "—", width=76, row=1, col=1, vmin=176)
        self.v_board = uk.field(grid, "板上 r / 上位机 r", "—", width=76, row=2, col=0)
        self.v_refresh = uk.field(grid, "刷新", "—", width=76, row=2, col=1, vmin=176)
        side_lay.addLayout(grid)

        # R20（批次 5）：r 均值/范围/圆度、板上 r、刷新率与画图耗时都随噪声跳 ⇒ 显示层稳定化。
        #   注：v_amp 是"判定"文案（正常/越限），不是数字，不套。
        self.st_rmean = uk.Stable("r_mean")
        self.st_rmin = uk.Stable("r_mean")
        self.st_rmax = uk.Stable("r_mean")
        self.st_round = uk.Stable("roundness")
        self.st_board = uk.Stable("board_r")
        self.st_rfps = uk.Stable("refresh_fps")
        self.st_draw = uk.Stable("draw_ms")

        if HAS_MPL:
            self.fig = Figure(figsize=(9.4, 2.5), dpi=100)
            # R7-B：时域图 : 李萨如图 = 2 : 1（李萨如受"等比例正方形"约束，给它再宽也是空白；
            #        多出来的宽度给时域图，原来两图各半 ⇒ 中间白白一条 ~240 px 的缝）
            self._gs = self.fig.add_gridspec(1, 2, width_ratios=(2.0, 1.0))
            self.ax_t = self.fig.add_subplot(self._gs[0, 0])
            self.ax_l = self.fig.add_subplot(self._gs[0, 1])
            self.canvas = FigureCanvas(self.fig)
            # 固定高度：画布高度随卡片伸缩会反过来改变卡片高度，形成“抖动”闭环。
            # ★ 独立大窗口传 canvas_h=None ⇒ 不钉高，画布跟着窗口一起长（那边没有这个闭环）
            if canvas_h:
                self.canvas.setFixedHeight(int(canvas_h))
            side_lay.addStretch(0)
            lay.addWidget(self.side, 2, 0, 1, 2)
            lay.addWidget(self.canvas, 3, 0, 1, 2)
            lay.setRowStretch(3, 1)
            self._init_axes()
        else:                                                    # pragma: no cover
            self.fig = self.canvas = None
            lab = QLabel("未安装 matplotlib，波形图无法显示（pip install matplotlib）")
            lab.setObjectName("Hint")
            self.lab_nompl = lab
            side_lay.addStretch(0)
            lay.addWidget(self.side, 2, 0, 1, 2)
            lay.addWidget(lab, 3, 0, 1, 2)
            lay.setRowStretch(3, 1)
        self._sync_controls()      # 把从 ui_prefs.json 恢复的量程写回控件与提示行

    # ---------------------------------------------------------------- 控件排布
    def eventFilter(self, obj, ev):
        """双击卡片标题 → 请求独立大窗口（图内双击仍归 ScopeNav 的"恢复自动"）。"""
        if obj is getattr(self, "lab_title", None) and ev.type() == QEvent.MouseButtonDblClick:
            self.popup_requested.emit()
            return True
        return super().eventFilter(obj, ev)

    def _fill_ctrl(self):
        """把登记好的控制组排进 `self._ctrl_grid`：一行放完（阶段 2 起没有第二种版面）。"""
        g = self._ctrl_grid
        while g.count():
            g.takeAt(0)
        for c in range(12):
            g.setColumnStretch(c, 0)
        c = 0
        for grp in self._ctrl_groups:
            for w in grp:
                g.addWidget(w, 0, c)
                c += 1
        g.setColumnStretch(c, 1)                 # 整行右侧留白（原来是一个 addStretch(1)）

    # ---------------------------------------------------------------- 外部接口
    def set_connected(self, conn, enabled=None):
        en = bool(conn if enabled is None else enabled)
        # 未连接/忙碌时别让"暂停刷新"可用：暂停再取消在没数据时会把画面永远冻住
        # （force_draw 那一帧根本没东西可画），用户会以为已经恢复了刷新
        self.chk_pause.setEnabled(en)
        if not en:
            self.chk_pause.setChecked(False)

    def set_smooth(self, w):
        """设置显示平滑（0 = 关）。只影响绘制，不动缓冲里的原始帧。"""
        self._smooth = int(w or 0)
        self._redraw()

    def reset(self):
        self.buf.reset()
        self.status = None
        self.f_in = None
        self._draws = 0
        self._last_draw = 0.0
        self._draw_s = 0.0
        for lab in (self.v_rmean, self.v_span, self.v_round, self.v_amp,
                    self.v_board, self.v_refresh):
            lab.setText("—")
            lab.setToolTip("")
        for st in (self.st_rmean, self.st_rmin, self.st_rmax, self.st_round,
                   self.st_board, self.st_rfps, self.st_draw):
            st.reset()
        if HAS_MPL:
            self._redraw()

    def set_status(self, status):
        """寄存器读回（幅值门限、板上 STAT_AMP_SQ）。"""
        self.status = status
        self._update_readouts(self.buf.snapshot())
        self._update_hint()

    def refresh_readouts(self):
        """R20：按当前显示口径重画读数（切「原始值」时由主窗口调）。"""
        self._update_readouts(self.buf.snapshot())
        self._show_refresh()

    def set_f_in(self, f_in):
        self.f_in = f_in
        self._update_hint()

    # ------------------------------------------------- R2 量程（示波器式导航）
    def nav_axes(self):
        return self.ax_t if HAS_MPL else None

    def x_span(self):
        return self._cur_span_ms()

    def set_x_span(self, span):
        """夹取到档位区间后切手动（Ctrl+滚轮/拖动都会走到这里）。"""
        span = min(max(float(span), min(X_SPANS_MS)), min(max(X_SPANS_MS), self.buf.capacity / 10.0))
        self.x_span_ms = span
        self.x_mode = "manual"
        up.put("wave", "x_mode", "manual")
        up.put("wave", "x_span_ms", span)
        self._sync_controls()
        self._redraw()

    def set_y_full(self, full):
        """夹取到档位区间后切手动（R9② 幅值步进/微调都走这里）。"""
        full = min(max(float(full), min(Y_FULLS)), max(Y_FULLS))
        self.y_full = full
        self.y_mode = "manual"
        up.put("wave", "y_mode", "manual")
        up.put("wave", "y_full", full)
        self._sync_controls()
        self._redraw()

    # ---- R9②（批次 4）：按钮与键盘共用的逐档步进 / 微调入口
    def step_x(self, delta, fine=False):
        """时基步进：delta<0 = 更细（满屏时间更短），>0 = 更粗；fine=True 按 FINE_STEP 微调。

        微调不进档位表（`set_x_span` 只夹上下限），所以 0.9× 连点不会"吸"回档位。
        """
        if fine:
            self.set_x_span(self._cur_span_ms() * (FINE_STEP ** (-int(delta))))
            return
        seq = X_SPANS_MS
        cur = self._cur_span_ms()
        idx = min(range(len(seq)), key=lambda i: abs(seq[i] - cur))
        idx = min(max(idx + int(delta), 0), len(seq) - 1)
        self.set_x_span(seq[idx])

    def step_y(self, delta, fine=False):
        """幅值步进：delta>0 = 放大（曲线变高、FS 变小），<0 = 缩小；fine=True 微调。"""
        if fine:
            base = float(self.y_full) if self.y_mode == "manual" else 1.0
            self.set_y_full(base * (FINE_STEP ** int(delta)))
            return
        seq = Y_FULLS                       # 1.0 → 0.1：越往后 = 曲线越高 = 放大
        cur = float(self.y_full) if self.y_mode == "manual" else seq[0]
        idx = min(range(len(seq)), key=lambda i: abs(seq[i] - cur))
        idx = min(max(idx + int(delta), 0), len(seq) - 1)
        self.set_y_full(seq[idx])

    def kbd_pause(self):
        """Space：暂停/继续（主窗口的快捷键统一走这里，免得两处各写一份）。"""
        self.chk_pause.toggle()

    def kbd_export(self):
        """E：导出当前视图。"""
        self.export_view_requested.emit()

    def x_center(self):
        sp = self._cur_span_ms()
        return self.x_off_ms - sp / 2.0

    def set_x_center(self, center):
        sp = self._cur_span_ms()
        # 不许把窗口拖离数据区：右边界最多越过最新帧 sp/4，左边界最多再往左 sp/4
        cap = self.buf.capacity / 10.0
        right = float(center) + sp / 2.0
        right = min(right, sp / 4.0)
        right = max(right, -cap - sp / 4.0)
        self.x_off_ms = right
        self._redraw()

    def y_pan(self):
        return self.y_off

    def set_y_pan(self, off):
        self.y_off = min(max(float(off), -3.0 * sg.FS), 3.0 * sg.FS)
        self._redraw()

    def reset_auto(self):
        """恢复自动量程（双击图内 / 「恢复自动」按钮）。"""
        self.x_mode = "auto"
        self.y_mode = "auto"
        self.x_off_ms = 0.0
        self.y_off = 0.0
        up.put("wave", "x_mode", "auto")
        up.put("wave", "y_mode", "auto")
        self._sync_controls()
        self._redraw()

    def scope_view(self):
        """给「按当前视图导出」用的视图描述（导出 PNG 时照这个设量程）。"""
        return {"xlim": list(self.ax_t.get_xlim()), "ylim": list(self.ax_t.get_ylim()),
                "text": self._view_text()} if HAS_MPL else None

    def _cur_span_ms(self):
        if self.x_mode == "manual":
            return float(self.x_span_ms)
        return self._auto_span_ms()

    def _auto_span_ms(self):
        """自动横轴：按输入频率显示约 2 个周期。

        ★ 量化到 1-2-5 档还不够：档位边界上（例如 need 在 2 ms 与 5 ms 之间来回）
          输入频率的天然波动会让档位每帧都翻，整幅波形跟着缩放，看着就是"抖来抖去"。
          所以加迟滞：当前档位在 [span/2.2, span] 之内就不动，越界才换档。
        """
        cap = self.buf.capacity / 10.0
        raw = self._raw is not None and (self._raw_hz or 0.0) > 1.0
        if raw:
            cap = 50.0                       # 原始样点能给到 50 ms（够看低频）
        f = abs(self._raw_hz if raw else (self.f_in or 0.0))
        if f <= 1.0:
            return cap
        need = 1000.0 / f * AUTO_CYCLES
        cur = self._span_hyst
        # 迟滞带要**宽于**"选档区间"（cur/2 … cur），两条带重叠才真正不翻：
        # 用 cur/2.5 … cur*1.25，重叠区 2.0…2.5，输入频率抖 ±25% 也不会来回跳档。
        # 下限 5 ms：板上遥测 10 kHz，0.5 ms 窗口只有 5 个点，画出来是一条几乎不动
        # 的折线，跟着数据一闪一闪 —— 比"窗口偏大"难看得多。
        # 下限：帧模式 5 ms（10 kHz 只有 5 个点）；原始样点模式 0.05 ms（还有 625 点）
        need = max(RAW_MIN_SPAN_MS if raw else 5.0, need)
        if cur and (cur / 2.5) <= need <= (cur * 1.25):
            return min(cap, cur)
        if raw:
            # 原始样点模式不走固定档位表：38 kHz 需要 0.05 ms，而表里最小只有 0.5 ms
            v = _nice_span(need)
            self._span_hyst = v
            return min(cap, v)
        for v in X_SPANS_MS:
            if v >= need:
                self._span_hyst = v
                return min(cap, v)
        self._span_hyst = cap
        return cap

    def _view_text(self):
        sp = self._cur_span_ms()
        tm = "自动" if self.x_mode == "auto" else "手动"
        ym = "自动" if self.y_mode == "auto" else "手动"
        txt = "横轴 %.4g ms（%s）· 纵轴 %s ±%.2f FS" % (
            sp, tm, ym, (1.12 if self.y_mode == "auto" else float(self.y_full)))
        if self.trig_mode != "off":
            txt = "触发 %s · %s" % (TRIG_TEXT.get(self.trig_mode, self.trig_mode), txt)
        return txt

    def _y_lim(self):
        if self.y_mode == "manual":
            return sg.FS * float(self.y_full)
        return sg.FS * 1.12

    # ------------------------------------------------------- 控件同步 / 事件
    def _sync_controls(self):
        """把当前量程状态写回控件（blockSignals 免得再触发一次回调）。"""
        self.cmb_layout.blockSignals(True)
        idx = self.cmb_layout.findData(self.layout_mode)
        self.cmb_layout.setCurrentIndex(max(0, idx))
        self.cmb_layout.blockSignals(False)
        self.cmb_trig.blockSignals(True)
        self.cmb_trig.setCurrentIndex(max(0, self.cmb_trig.findData(self.trig_mode)))
        self.cmb_trig.blockSignals(False)
        # R15：手动量程若是"微调值"（Ctrl+滚轮 / Shift+方向键），组合框补一条「（微调）」
        #      临时档 —— 以前是"就近显示"，会出现组合框写「满屏 50 ms」而「量程：」写
        #      49.152 ms 的矛盾（用户 m11938 点名要改）。文本位数与 `_view_text()` 对齐
        #      （横轴 %.4g 、纵轴 %.2f），这样两处写的数字一模一样。
        for cmb, val, fmt in ((self.cmb_tdiv, "auto" if self.x_mode == "auto" else self.x_span_ms,
                               "满屏 %.4g ms（微调）"),
                              (self.cmb_vdiv, "auto" if self.y_mode == "auto" else self.y_full,
                               "±%.2f FS（微调）")):
            cmb.blockSignals(True)
            uk.sync_span_combo(cmb, val, fmt)
            cmb.blockSignals(False)
        if HAS_MPL:
            self.lab_view.setText("量程：" + self._view_text())
        self._sync_step_btns()

    def _sync_step_btns(self):
        """到档位两端就把对应按钮置灰（键盘微调仍可用）。"""
        seq = X_SPANS_MS
        cur = self._cur_span_ms()
        i = min(range(len(seq)), key=lambda k: abs(seq[k] - cur))
        self.btn_tdiv_prev.setEnabled(i > 0)
        self.btn_tdiv_next.setEnabled(i < len(seq) - 1)
        ys = Y_FULLS
        yc = float(self.y_full) if self.y_mode == "manual" else ys[0]
        j = min(range(len(ys)), key=lambda k: abs(ys[k] - yc))
        self.btn_vdiv_out.setEnabled(j > 0)
        self.btn_vdiv_in.setEnabled(j < len(ys) - 1)

    def _on_tdiv(self, _idx):
        val = self.cmb_tdiv.currentData()
        if val == "auto":
            self.x_mode = "auto"
            self.x_off_ms = 0.0
            up.put("wave", "x_mode", "auto")
        else:
            self.x_mode = "manual"
            self.x_span_ms = float(val)
            up.put("wave", "x_mode", "manual")
            up.put("wave", "x_span_ms", float(val))
        self._sync_controls()
        self._redraw()

    def _on_vdiv(self, _idx):
        val = self.cmb_vdiv.currentData()
        if val == "auto":
            self.y_mode = "auto"
            self.y_off = 0.0
            up.put("wave", "y_mode", "auto")
        else:
            self.y_mode = "manual"
            self.y_full = float(val)
            up.put("wave", "y_mode", "manual")
            up.put("wave", "y_full", float(val))
        self._sync_controls()
        self._redraw()

    def _on_layout(self, _idx):
        self.layout_mode = self.cmb_layout.currentData() or "overlay"
        up.put("wave", "layout", self.layout_mode)
        self._redraw()

    def _on_trig(self, _idx=None):
        key = self.cmb_trig.currentData()
        if key not in TRIG_KEYS:
            return
        if key != self.trig_mode:
            self.trig_mode = key
            self._trig_t = None      # 换触发源后重新找触发点
            up.put("wave", "trig", key)
        self._sync_controls()
        self._redraw()

    def feed(self, frames, force_draw=False):
        # ★ force_draw 必须能穿过空帧：取消"暂停刷新"就是靠 feed([], force_draw=True)
        #   触发重画的，早退会让画面永远停在冻结的那一帧
        if not frames and not force_draw:
            return
        if frames and self._raw is not None:
            self._raw = None        # 有帧流就退回帧模式（串口模式 / 回放）
            self._raw_hz = 0.0
            self._span_hyst = None  # 换回帧模式，横轴迟滞重算
        self.buf.feed(frames)
        now = time.monotonic()
        if self.paused and not force_draw:
            return
        if force_draw or (now - self._last_draw) >= self._interval:
            self._last_draw = now
            snap = self.buf.snapshot()
            self._update_readouts(snap)
            if HAS_MPL:
                t0 = time.perf_counter()
                self._redraw(snap)
                self._draw_s = time.perf_counter() - t0
                # 画得慢就把间隔放宽，保证界面不卡（宁可 6 次/秒，也不要卡住）
                self._interval = min(REDRAW_MAX_S, max(REDRAW_MIN_S, self._draw_s * 3.0))
                self._draws += 1
                self._show_refresh()

    # ------------------------------------------------------------ 真波形（网口）
    def feed_raw(self, s_arr, c_arr, fs_hz):
        """喂一段连续流原始样点（12.5 MSPS 那种），画真波形。

        10 kHz 帧流对 1~2 kHz 输入只有 8 个点/周期，怎么画都是折线；这里用
        原始样点 + 按像素列 min/max 包络，才是"信号本来的样子"。
        """
        n = min(len(s_arr), len(c_arr))
        if n < 16 or fs_hz <= 0:
            return
        if self._raw is None:
            self._span_hyst = None          # 从帧模式切过来，迟滞作废重算
        self._raw = (s_arr[-n:], c_arr[-n:], float(fs_hz))
        # 用原始样点自己估频率（过均值零点计数）。不能等转速卡：pos_full 口径
        # 与信号周期数是两回事，实测差了 13 倍，横轴会跟着错一个数量级。
        try:
            _x = np.asarray(s_arr[-n:], dtype=float)
            _x = _x - _x.mean()
            _zc = int(np.count_nonzero(np.diff(np.signbit(_x))))
            _dur = n / float(fs_hz)
            self._raw_hz = (_zc / 2.0 / _dur) if _dur > 0 else 0.0
        except Exception:                                     # noqa: BLE001
            self._raw_hz = 0.0
        now = time.monotonic()
        if self.paused:
            return
        if (now - self._last_draw) < self._interval:
            return
        self._last_draw = now
        if HAS_MPL:
            t0 = time.perf_counter()
            self._redraw_raw()
            self._draw_s = time.perf_counter() - t0
            self._interval = min(REDRAW_MAX_S, max(REDRAW_MIN_S, self._draw_s * 3.0))
            self._draws += 1
            self._show_refresh()

    def clear_raw(self):
        self._raw = None

    def _redraw_raw(self):
        """把 _raw 画到现有坐标轴上（包络抽稀 + 真实时间轴）。"""
        s_arr, c_arr, fs = self._raw
        n = len(s_arr)
        span_ms = self._cur_span_ms()
        want = int(span_ms * 1e-3 * fs)
        want = max(64, min(n, want))
        s_arr = s_arr[-want:]
        c_arr = c_arr[-want:]
        n = len(s_arr)
        self._raw_us = 1e6 * n / fs
        # 像素列 min/max 包络：每列两个点（谷、峰），拐点全保留
        cols = max(120, int(self.canvas.width()) if self.canvas is not None else 600)
        step = max(1, n // max(1, cols))
        if step > 1:
            m = (n // step) * step
            ss = s_arr[:m].reshape(-1, step)
            cc = c_arr[:m].reshape(-1, step)
            x = (np.arange(m // step) * step + step / 2.0) / fs * 1000.0
            x = x - (n - 1) / fs * 1000.0
            self.line_s.set_data(np.repeat(x, 2), np.stack([ss.min(1), ss.max(1)], 1).ravel())
            self.line_c.set_data(np.repeat(x, 2), np.stack([cc.min(1), cc.max(1)], 1).ravel())
        else:
            x = (np.arange(n) - (n - 1)) / fs * 1000.0
            self.line_s.set_data(x, s_arr)
            self.line_c.set_data(x, c_arr)
        y = float(self._y_lim())          # _y_lim 返回的是半幅，不是 (lo, hi)
        self.ax_t.set_xlim(-span_ms, 0.0)
        self.ax_t.set_ylim(-y, y)
        self.ax_t.set_title("真波形 %d 点（%.3f ms @ %.3f MSPS，连续流原始样点）"
                            % (n, self._raw_us / 1000.0, fs / 1e6),
                            fontsize=uf.pt(8), pad=4)
        # 李萨如用同一块样点
        self.line_l.set_data(c_arr, s_arr)
        r = np.hypot(s_arr, c_arr)
        self.ax_l.set_title("李萨如 c-s（%d 点原始样点）" % n, fontsize=uf.pt(8), pad=4)
        self.circle_l.set_data(np.append(np.cos(np.linspace(0, 2 * np.pi, 65)) * r.mean(),
                                         np.cos(0) * r.mean()),
                               np.append(np.sin(np.linspace(0, 2 * np.pi, 65)) * r.mean(),
                                         np.sin(0) * r.mean()))
        # 读数沿用同一个 snapshot 结构（_update_readouts 要 n/r_mean/... ）
        r_mean = float(r.mean())
        clip = bool(np.max(np.abs(s_arr)) > 32700 or np.max(np.abs(c_arr)) > 32700)
        self._update_readouts({"n": n, "r_mean": r_mean,
                               "r_min": float(r.min()), "r_max": float(r.max()),
                               "roundness": float(r.std() / r_mean) if r_mean else 0.0,
                               "clip": clip})
        self.canvas.draw_idle()

    # ---------------------------------------------------------------- 内部
    def _on_pause(self, on):
        self.paused = bool(on)
        if not on:
            self.feed([], force_draw=True)

    def _init_axes(self):
        for ax in (self.ax_t, self.ax_l):
            ax.grid(True, alpha=0.3)
            ax.tick_params(labelsize=uf.pt(7))
            ax.set_facecolor(C["card"])
        self.fig.subplots_adjust(left=0.075, right=0.985, top=0.88, bottom=0.16, wspace=0.22)
        self.line_s, = self.ax_t.plot([], [], lw=0.8, color=C["primary"], label="s_n")
        self.line_c, = self.ax_t.plot([], [], lw=0.8, color=C["warn"], label="c_n")
        leg = self.ax_t.legend(loc="upper right", fontsize=uf.pt(7), framealpha=0.85)
        leg.get_frame().set_linewidth(0)
        self.ax_t.set_xlabel("时间 (ms，0 = 最新帧；左负 = 更早)", fontsize=uf.pt(7))
        self.ax_t.set_ylabel("幅值 (Q1.15，满刻度 32768)", fontsize=uf.pt(7))
        self.line_l, = self.ax_l.plot([], [], lw=0.8, color=C["secondary"])
        self.circle_l, = self.ax_l.plot([], [], lw=0.7, ls="--", color=C["ok"])
        self.ax_l.set_xlabel("c_n (Q1.15)", fontsize=uf.pt(7))
        self.ax_l.set_ylabel("s_n (Q1.15)", fontsize=uf.pt(7))
        self.ax_l.set_aspect("equal", adjustable="box")
        # R2：Ctrl+滚轮缩放横轴 / 左键拖动平移 / 双击恢复自动（协议见 ui_kit.ScopeNav）
        if getattr(self, "_nav", None) is None:
            self._nav = uk.ScopeNav(self.canvas, self, self)

    # ------------------------------------------------------- 触发（阶段 5 C 批）
    def _find_trigger(self, snap, sp_ms):
        """从最新往回找最近一个触发点，返回缓冲时间轴上的时刻（秒）；找不到返回 None。

        过零点做**线性插值**：只取"最近那个样本点"的话，0.1 ms 的采样栅格会让每次
        重画的触发相位在 ±半个采样间隔之间跳（1008 Hz 输入 ≈ 36° 相移），画面看着
        还在抖；插值把触发点定到分数时刻上，波形才像真示波器那样"站着不动"。
        触发点右侧要留 TRIG_POS·span 的数据、左侧要留 (1−TRIG_POS)·span。
        """
        n = snap.get("n") or 0
        t = snap.get("t") or []
        mode = self.trig_mode
        if mode == "off" or n < 4 or sp_ms <= 0 or len(t) != n:
            return None
        span_s = float(sp_ms) / 1000.0
        t_lo = t[0] + (1.0 - TRIG_POS) * span_s
        t_hi = t[-1] - TRIG_POS * span_s
        if t_hi <= t_lo:
            return None
        vals = snap.get("z") if mode == "z" else snap.get(mode)
        if not vals or len(vals) != n:
            return None
        for i in range(n - 1, 0, -1):
            ti = t[i]
            if ti > t_hi:                  # 太靠右：右边留不出触发后窗口
                continue
            if ti < t_lo:                  # 再往左就越界了，停止
                break
            if mode == "z":                # Z 是 0/1 电平：直接判上升沿
                if vals[i] and not vals[i - 1]:
                    return ti
                continue
            a, b = vals[i - 1], vals[i]
            if a < 0 <= b:                 # s_n / c_n 的上升过零点
                d = b - a
                frac = (-a / d) if d else 0.0
                return t[i - 1] + (ti - t[i - 1]) * frac
        return None

    def _redraw(self, snap=None):
        snap = snap or self.buf.snapshot()
        n = snap["n"]
        sp = self._cur_span_ms()
        trig = self._find_trigger(snap, sp)
        self._trig_t = trig
        if n and trig is not None:
            # 触发模式：横轴原点搬到触发点（钉在 TRIG_POS 处）⇒ 画面相对静止
            x = [(v - trig) * 1000.0 for v in snap["t"]]
            x1 = TRIG_POS * sp
        elif n:
            x = [(v - snap["t"][-1]) * 1000.0 for v in snap["t"]]
            x1 = self.x_off_ms
        else:
            x = []
            x1 = self.x_off_ms
        ss, cc = snap["s"], snap["c"]
        if n and self._smooth > 1:
            # 只平滑"要画的那份"，触发检测与读数仍用原始数据
            ss = fl.smooth(ss, self._smooth)
            cc = fl.smooth(cc, self._smooth)
        if n:
            self.line_s.set_data(x, ss)
            self.line_c.set_data(x, cc)
            self.line_l.set_data(cc, ss)
            r = snap["r_mean"] or 0.0
            circ = [(r * math.cos(a / 64.0 * 6.2831853),
                     r * math.sin(a / 64.0 * 6.2831853)) for a in range(65)]
            self.circle_l.set_data([p[0] for p in circ], [p[1] for p in circ])
        else:
            for ln in (self.line_s, self.line_c, self.line_l, self.circle_l):
                ln.set_data([], [])
        # ---- R2 坐标轴量程：横轴 = 时基（自动跟随输入 / 手动档位），纵轴 = 幅值档位
        #      ★ 仍然"固定不跟数据自动缩放"（跟数据会抖），但量程由用户/输入频率决定
        self.ax_t.set_xlim(x1 - sp, x1)
        lim = self._y_lim()
        if self.layout_mode == "split":
            off = 0.55 * lim
            self.line_s.set_ydata([v + off for v in (ss if n else [])])
            self.line_c.set_ydata([v - off for v in (cc if n else [])])
            self.ax_t.set_ylim(-lim - off + self.y_off, lim + off + self.y_off)
            self.ax_t.set_title("时域快照 %d 帧（s_n 上移 %.2f FS、c_n 下移 %.2f FS）"
                                % (n, off / sg.FS, off / sg.FS), fontsize=uf.pt(8))
        else:
            self.ax_t.set_ylim(-lim + self.y_off, lim + self.y_off)
            self.ax_t.set_title(self._time_title(n, sp, trig), fontsize=uf.pt(8))
        # 阶段 5（C 批）：触发模式下横轴原点 = 触发点，轴标签得跟着改，免得误读
        self.ax_t.set_xlabel("时间 (ms，0 = 触发点；左负 = 触发前)" if trig is not None
                             else "时间 (ms，0 = 最新帧；左负 = 更早)", fontsize=uf.pt(7))
        self.ax_l.set_xlim(-sg.FS * 1.12, sg.FS * 1.12)
        self.ax_l.set_ylim(-sg.FS * 1.12, sg.FS * 1.12)
        if n:
            self.ax_l.set_title("李萨如 c–s（圆度偏差 %.2f%%）" % (snap["roundness"] or 0.0),
                                fontsize=uf.pt(8))
        else:
            self.ax_l.set_title("李萨如 c–s（等数据）", fontsize=uf.pt(8))
        if self.x_mode == "manual" or self.y_mode == "manual":
            note = self._view_text() + "｜手动（双击图内或点「恢复自动」）"
        else:
            note = self._view_text() + "｜自动"
        self.lab_view.setText("量程：" + note)
        self.canvas.draw_idle()

    def _time_title(self, n, sp, trig):
        """时域图标题：触发锁住时写明触发源与触发点位置，自由模式说明原点是最新帧。"""
        if trig is not None:
            return ("时域快照 %d 帧（触发 %s，触发点右侧留 %.0f%% 画幅，横轴 %.4g ms）"
                    % (n, TRIG_TEXT.get(self.trig_mode, self.trig_mode), TRIG_POS * 100.0, sp))
        if self.trig_mode == "off":
            return "时域快照 %d 帧（自由：0 = 最新帧，横轴 %.4g ms）" % (n, sp)
        return ("时域快照 %d 帧（%s：窗口内没找到触发点，先按最新帧画，横轴 %.4g ms）"
                % (n, TRIG_TEXT.get(self.trig_mode, self.trig_mode), sp))

    def _update_hint(self):
        msg = ("取最近 %d 帧（%.0f ms）。" % (self.buf.capacity, self.buf.capacity / 10.0))
        if self.f_in is not None and abs(self.f_in) > 5000.0:
            msg += ("★ 输入 ≈%.0f Hz > 帧率一半（5 kHz）⇒ 左侧时间轴波形已混叠，"
                    "只看右侧李萨如圆的半径/圆度。" % abs(self.f_in))
        elif self.f_in is not None:
            msg += "输入 ≈%.0f Hz。" % abs(self.f_in)
        else:
            msg += "输入频率未知（连上后自动估算）。"
        r_low, r_high = self._r_limits()
        if r_low is not None:
            msg += ("　幅值门限 r %.0f…%.0f（%.2f…%.2f 满量程，读自 0x0520/0x0524）。"
                    % (r_low, r_high, r_low / sg.FS, r_high / sg.FS))
        self.lab_hint.setText(msg)

    def _r_limits(self):
        """板上幅值门限（r 值）；没读到就返回 (None, None)。"""
        st = self.status or {}
        if st.get("amp_low_sq") and st.get("amp_high_sq"):
            return sg.amp_limits(st["amp_low_sq"], st["amp_high_sq"])
        return None, None

    def _show_refresh(self):
        fps = (1.0 / self._interval) if self._interval else 0.0
        # ★ 原来这里把"画一次图的耗时"当成"刷新间隔"写出来（显示 1 ms 却同时写 10 次/秒，
        # 自相矛盾）：前一个数该是刷新率，括号里的才是画图耗时
        # R20：两个数都走稳定显示（悬停看原始值）
        self.st_rfps.update(fps)
        self.st_draw.update(self._draw_s * 1000.0)
        # ★ 用户反馈（m15813）：只留刷新率，删掉「（画图 x ms）」（画图耗时挪进悬停提示）
        self.v_refresh.setText(self.st_rfps.text())
        self.v_refresh.setToolTip("%s\n%s\n刷新率低于 10 次/秒会标黄（本机性能）"
                                  % (self.st_rfps.tip(), self.st_draw.tip()))
        self.v_refresh.setStyleSheet("color:%s;" % (C["ok"] if fps >= 10.0 else C["warn"]))

    def _update_readouts(self, snap):
        if not snap or not snap["n"]:
            self.v_rmean.setText("—")
            self.v_span.setText("—")
            self.v_round.setText("—")
            self.v_amp.setText("—")
            self.v_board.setText("—")
            for lab in (self.v_rmean, self.v_span, self.v_round, self.v_board):
                lab.setToolTip("")
            for st in (self.st_rmean, self.st_rmin, self.st_rmax, self.st_round,
                       self.st_board):
                st.reset()
            return
        # R20：r 均值/范围/圆度/板上 r 走稳定显示（悬停看原始值）
        self.st_rmean.update(snap["r_mean"])
        self.st_rmin.update(snap["r_min"])
        self.st_rmax.update(snap["r_max"])
        self.st_round.update(snap["roundness"] or 0.0)
        self.v_rmean.setText(self.st_rmean.text())
        self.v_rmean.setToolTip(self.st_rmean.tip("1500 帧滑窗内 r 的均值"))
        self.v_span.setText("%s … %s" % (self.st_rmin.text(), self.st_rmax.text()))
        self.v_span.setToolTip(self.st_rmin.tip("滑窗内最小值与最大值（各自稳定显示）"))
        self.v_round.setText(self.st_round.text())
        self.v_round.setToolTip(self.st_round.tip("1 − r_min/r_max，看圆是否规整"))

        r_low, r_high = self._r_limits()
        level, text = sg.amp_verdict(snap["r_mean"], r_low, r_high)
        if snap["clip"]:
            level = "fault"
            text += "（削顶）"
        self.v_amp.setText(text)
        # 门限数字只进 tooltip/提示行：写进这个标签会把卡片撑宽，整行卡片跟着挪
        if r_low is not None:
            self.v_amp.setToolTip("幅值门限 r %.0f … %.0f（来自板上 0x0520/0x0524）"
                                  % (r_low, r_high))
        else:
            self.v_amp.setToolTip("门限未知（未读到 0x0520/0x0524）")
        self.v_amp.setStyleSheet("color:%s;" % th.level_color(level))

        sq = (self.status or {}).get("stat_amp_sq")
        if sq:
            self.st_board.update(sg.r_of_amp_sq(int(sq)))
            self.v_board.setText("%s / %s" % (self.st_board.text(), self.st_rmean.text()))
            self.v_board.setToolTip(self.st_board.tip("板上 0x0530 实测幅值平方开方")
                                    + "\n右边是上位机算的 r（滑窗均值，稳定显示）")
        else:
            self.st_board.reset()
            self.v_board.setText("— / %s" % self.st_rmean.text())
            self.v_board.setToolTip("板上 0x0530 没读到（跑一次「设备自检」）")
