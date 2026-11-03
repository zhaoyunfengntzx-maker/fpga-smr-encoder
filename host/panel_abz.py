"""ABZ / UVW 等效采样卡片（需求 M5）：六路电平 + 等效采样波形 + 六状态数据表。

★ 为什么必须"按电角度分箱"（写进界面提示，避免误读）：
  板子只给 10 kHz 快照。inter=32 时 AB 边沿率 = 4×32×20 kHz ≈ 2.56 MHz，
  比帧率高 256 倍 ⇒ 按时间轴画 A/B 只会看到一团噪声。把每帧的 (电角度, 电平)
  按角度分箱取均值，就是"等效采样"：箱内均值 = 该相位下的高电平比例，
  于是能重建出 A/B 的正交方波、Z 的窄脉冲门控、UVW 的六个扇区。

★ 两个"看起来不对、其实是正常"的现象：
  1. 输入频率 ≈ 帧率整数倍（本板 20 kHz ≈ 2×10 kHz）时，帧落在输入周期内的
     相位几乎不动 ⇒ Z（只占 5/128 圈、每 64 圈一次）短时间内可能一帧都抓不到。
  2. Z 允许出现在 z_window 标志之外：rtl/abz_gen.v:677-686 把"装载"留给窗口
     门控，而"脉冲推进 + 4096 clk 超时兜底"在窗外继续（否则集成路径的
     z_window 提前 2 clk 关闭会把脉冲截成 40 ns）。
"""

from __future__ import annotations

import time

from PySide6.QtCore import QEvent, Qt, Signal                # noqa: E402
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDoubleSpinBox,  # noqa: E402
                               QFrame, QGridLayout, QHBoxLayout, QLabel,
                               QPushButton, QSpinBox, QVBoxLayout, QWidget)

import abz as az                                             # noqa: E402
import regs as rg                                            # noqa: E402
import theme as th                                           # noqa: E402
import ui_font as uf                                         # noqa: E402
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

REDRAW_MIN_S = 0.20      # 等效采样变化慢，5 次/秒足够（省 CPU，界面不抖）
REDRAW_MAX_S = 0.60
LEGAL_ROWS = az.LEGAL_STATES          # (0b001, 0b011, 0b010, 0b110, 0b100, 0b101)

# ---- R3 示波器式量程（批次 3）：横轴 = 电角度窗口（自动 = 整圈 360°）
# ---- R9①（批次 4）：加进 5 / 20 / 45 / 60 / 120 / 270 —— 一个极对周期内也能细看
X_SPANS_DEG = (5.0, 10.0, 20.0, 30.0, 45.0, 60.0, 90.0, 120.0, 180.0, 270.0, 360.0)
FINE_STEP = 0.9                             # R9② 微调倍率（Shift+方向键，不进档位表）
FINE_GAP = 0.05                             # R9② 间距微调步长（Shift+↑/↓）
LAYOUTS = ("overlay", "split")
GAP_BASE = 1.1            # 通道基线间距基数（叠加模式）；分离模式乘 2
SPACING_RANGE = (0.6, 2.5)


class AbzPanel(QFrame):
    export_view_requested = Signal()      # 「导出当前视图」
    output_requested = Signal(dict)       # 一键使能 ABZ/UVW：{比特名: 0/1}（主窗口读-改-写 0x0109）
    square_requested = Signal()           # 「方波可看」：主窗口把 分箱/ inter 配成 箱数 ≥ 16×inter
    square_restore_requested = Signal()   # 「还原」：把 inter 与分箱改回预设之前的值
    popup_requested = Signal()            # 「独立窗口」（阶段 5 续；主窗口开大窗口）
    # ★ 2026-10-17 全面自查修：弹窗要用它把提示转发回主窗口（abz_popup.notice()），
    #   主窗口开⑨弹窗时也会 `p.notice.connect(self._log_notice)`。原来漏了这个信号，
    #   第一次点「独立窗口」就在 Qt 槽里抛 AttributeError（PySide6 只打到 stderr，
    #   界面看起来只是"窗口没出来"），而窗口对象已经建好 ⇒ 再点就走不到接线那一段。
    notice = Signal(str, str)             # (文本, 级别 ok/warn/fault/info) → 日志卡片

    def __init__(self, bins=az.BINS_DEFAULT, parent=None, canvas_h=240,
                 show_popup=True):
        super().__init__(parent)
        self.setObjectName("Card")
        self.an = az.AbzAnalyzer(bins=bins)
        self.paused = False
        self.f_in = None
        self._last_draw = 0.0
        self._draw_s = 0.0
        self._interval = REDRAW_MIN_S
        self._snap = None
        self._uvw_span = 360.0        # UVW 图自己的角度窗口（与 ABZ 的横轴无关）
        self._uvw_center = 180.0
        self._uvw_line = True         # 60° 扇区分隔线

        self._out_bits = None        # 板上 0x0109 的解码结果（None = 还没读回，一键使能会被拒）
        self._rows = {}
        # ---- R3 量程状态（默认从 ui_prefs.json 恢复）
        self.x_mode = up.choice("abz", "x_mode", ("auto", "manual"), "auto")
        self.x_span_deg = up.number("abz", "x_span_deg", min(X_SPANS_DEG), max(X_SPANS_DEG), 360.0)
        self.x_center_deg = up.number("abz", "center_deg", -360.0, 720.0, 180.0)
        self.layout_mode = up.choice("abz", "layout", LAYOUTS, "overlay")
        self.spacing = up.number("abz", "spacing", SPACING_RANGE[0], SPACING_RANGE[1], 1.1)
        self.y_off = 0.0
        self._nav = None

        # R7-A：顶层用 QGridLayout —— 普通态是「上控制条 + 图 + 状态表」，放大态把控制与读数
        #       整块挪到右列（图独占左侧，状态表留底部整宽）
        lay = QGridLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setHorizontalSpacing(10)
        lay.setVerticalSpacing(8)
        lay.setColumnStretch(0, 1)
        self._lay = lay
        self.lab_nompl = None

        head = QHBoxLayout()
        title = QLabel("ABZ / UVW 等效采样")
        title.setObjectName("CardTitle")
        title.setToolTip("双击这个标题可以弹出独立大窗口（阶段 5）")
        title.installEventFilter(self)      # 双击标题 → popup_requested
        self.lab_title = title
        head.addWidget(title)
        head.addStretch(1)
        head.addWidget(QLabel("分箱"))
        self.cmb_bins = QComboBox()
        for b in az.BINS_CHOICES:
            self.cmb_bins.addItem("%d 箱" % b, b)
        self.cmb_bins.setCurrentIndex(list(az.BINS_CHOICES).index(bins)
                                      if bins in az.BINS_CHOICES
                                      else list(az.BINS_CHOICES).index(az.BINS_DEFAULT))
        self.cmb_bins.setToolTip("按电角度分箱的箱数：箱越多越细，但需要更长的累积时间才能填满")
        self.cmb_bins.currentIndexChanged.connect(self._on_bins)
        head.addWidget(self.cmb_bins)
        self.btn_reset = QPushButton("清空累积")
        self.btn_reset.setToolTip("重新开始等效采样（改 inter/div 后会自动清空）")
        self.btn_reset.clicked.connect(self._on_reset)
        head.addWidget(self.btn_reset)
        self.chk_pause = QCheckBox("暂停刷新")
        self.chk_pause.setProperty("switch", "true")     # 阶段 3：状态开关用滑块外观
        self.chk_pause.setToolTip("冻结画面方便读数；数据仍在后台累积")
        self.chk_pause.toggled.connect(self._on_pause)
        head.addWidget(self.chk_pause)
        # ---- 「方波可看 / 还原」（用户 2026-10-15 要求）------------------------------
        #   方波形状的成因是"每箱跨几个 A/B 周期"：箱数 ≥ 16×inter 时每周期 ≥16 点，
        #   箱内电平一致 ⇒ 重建出来才是方波（详见 host/abz.py 的 muddy 判据）。
        #   面板只发信号，算目标值与写 0x0101 由主窗口做（要读-改-写、要回读、要能还原）。
        self.btn_square = QPushButton("方波可看")
        self.btn_square.setToolTip("一键配成能看方波的组合：箱数 ≥ 16×inter（每箱跨 ≤1/16 个 A/B 周期）。"
                                   "会读-改-写 0x0101 的 inter（div 与其它位不动），并把分箱提到够用的档；"
                                   "点「还原」回到原值")
        self.btn_square.clicked.connect(self.square_requested.emit)
        head.addWidget(self.btn_square)
        self.btn_square_back = QPushButton("还原")
        self.btn_square_back.setToolTip("把 inter 与分箱改回「方波可看」之前的值（没按过「方波可看」就什么都不做）")
        self.btn_square_back.clicked.connect(self.square_restore_requested.emit)
        head.addWidget(self.btn_square_back)
        # ---- 「独立窗口」（阶段 5 续，用户追加要求）--------------------------------
        #   等效采样图在卡片里被压扁：箱数与图幅放大后，才看得清方波判决线与
        #   理论方波（虚线）的相位关系 —— 这正是要"仔细观察"的地方。
        self.btn_popup = QPushButton("独立窗口")
        self.btn_popup.setToolTip("把这个图弹到独立大窗口里看（可自由缩放/移动，Esc 关闭）")
        self.btn_popup.clicked.connect(lambda: self.popup_requested.emit())
        self.btn_popup.setVisible(bool(show_popup))   # 独立窗口里自己不需要这个按钮
        head.addWidget(self.btn_popup)
        lay.addLayout(head, 0, 0, 1, 2)

        self.lab_hint = QLabel(
            "按电角度分箱做等效采样：箱内均值 = 该相位的高电平比例。插值 A/B 正交看相位差，"
            "Z 只占 5/128 圈、每 64 圈一次，输入≈帧率整数倍时短时间内可能抓不到（正常）。")
        self.lab_hint.setObjectName("Hint")
        self.lab_hint.setWordWrap(True)
        uk.fix_lines(self.lab_hint, 3)
        lay.addWidget(self.lab_hint, 1, 0, 1, 2)

        # ---- 一键使能 ABZ / UVW（用户 2026-10-14 要求）------------------------------
        #   板上 0x0109 的 bit6 abzen / bit7 uwven。以前只能钻进 ⑥ 卡的「高级参数」勾选，
        #   而 ⑨ 卡（看 A/B/Z 波形、六状态表、跑 S4 验收）恰恰最需要它 ⇒ 这里放显式按钮。
        #   面板只发"想要的目标位"，读-改-写与回读由主窗口统一做（不在这里直接发命令）。
        out_row = QHBoxLayout()
        out_row.setSpacing(6)
        out_row.addWidget(uk.small_label("输出使能", 56))
        self.btn_abz_en = QPushButton("ABZ 使能")
        self.btn_abz_en.setCheckable(True)
        self.btn_abz_en.setToolTip("一键写 0x0109 bit6 abzen=1：板上输出 A/B/Z。"
                                   "A/B/Z 恒 0、六路电平全 0 时先点这里")
        self.btn_abz_en.clicked.connect(lambda: self._on_out_click("abzen"))
        out_row.addWidget(self.btn_abz_en)
        self.btn_uvw_en = QPushButton("UVW 使能")
        self.btn_uvw_en.setCheckable(True)
        self.btn_uvw_en.setToolTip("一键写 0x0109 bit7 uwven=1：板上输出 U/V/W 六状态。"
                                   "UVW 关着时六状态表恒为 0、非法态恒真（S4 第 3/4 项会跳过）")
        self.btn_uvw_en.clicked.connect(lambda: self._on_out_click("uwven"))
        out_row.addWidget(self.btn_uvw_en)
        self.lab_out = QLabel("输出使能：等设备自检")
        self.lab_out.setObjectName("Hint")
        uk.fix_lines(self.lab_out, 1)
        out_row.addWidget(self.lab_out)
        out_row.addStretch(1)
        lay.addLayout(out_row, 2, 0, 1, 2)

        # ---- R3 示波器式量程控件（横轴角度窗口 / 通道排布与间距 / 导出当前视图）
        #      R7-A：控件登记成"组" —— 普通态横排一行，放大态每组一行竖排进右侧控制列
        grp_xspan = [uk.small_label("横轴", 32)]
        self.cmb_xspan = QComboBox()
        self.cmb_xspan.setToolTip("电角度窗口宽度。自动 = 整圈 360°；手动选一档即锁定"
                                  "（←/→ 逐档、Shift+←/→ 微调、放大态滚轮缩放、"
                                  "双击图内恢复自动）")
        self.cmb_xspan.addItem("自动（整圈 360°）", "auto")
        for v in X_SPANS_DEG:
            self.cmb_xspan.addItem("满屏 %g°" % v, v)
        self.cmb_xspan.currentIndexChanged.connect(self._on_xspan)
        self.btn_xspan_prev = uk.step_button("◀", "角度窗口上一档（更窄：一个扇区内看细节）\n快捷键 ←")
        self.btn_xspan_prev.clicked.connect(lambda: self.step_x(-1))
        self.btn_xspan_next = uk.step_button("▶", "角度窗口下一档（更宽：看更多扇区）\n快捷键 →")
        self.btn_xspan_next.clicked.connect(lambda: self.step_x(+1))
        grp_xspan += [self.btn_xspan_prev, self.cmb_xspan, self.btn_xspan_next]
        grp_layout = [uk.small_label("排布", 32)]
        self.cmb_layout2 = QComboBox()
        self.cmb_layout2.setToolTip("叠加：三路电平画在三条紧凑基线上；分离：基线拉开，便于分别读数")
        self.cmb_layout2.addItem("叠加", "overlay")
        self.cmb_layout2.addItem("分离", "split")
        self.cmb_layout2.currentIndexChanged.connect(self._on_layout)
        grp_layout.append(self.cmb_layout2)
        grp_gap = [uk.small_label("间距", 32)]
        self.sp_gap = QDoubleSpinBox()
        self.sp_gap.setRange(SPACING_RANGE[0], SPACING_RANGE[1])
        self.sp_gap.setSingleStep(0.1)
        self.sp_gap.setDecimals(2)              # R9②：微调步长 0.05，显示留两位
        self.sp_gap.setValue(self.spacing)
        self.sp_gap.setToolTip("通道基线间距倍数：方波太密就调大，太散就调小"
                               "（↑/↓ 每次 0.1、Shift+↑/↓ 每次 0.05）")
        self.sp_gap.valueChanged.connect(self._on_spacing)
        grp_gap.append(self.sp_gap)
        # ---- m02689：UVW 半边也要可调（原来 UVW 图完全跟着 ABZ 的窗口走、没法改）
        grp_uvw = [uk.small_label("UVW", 34)]
        self.cmb_uvw_span = QComboBox()
        self.cmb_uvw_span.setToolTip("UVW 图的角度窗口，与 ABZ 的横轴各自独立。"
                                     "整圈 360° 看六个扇区；60°/30° 放大看一个扇区内部的边沿")
        self.cmb_uvw_span.addItem("整圈 360°", 360.0)
        for v in (180.0, 120.0, 90.0, 60.0, 30.0):
            self.cmb_uvw_span.addItem("%g°" % v, v)
        self.cmb_uvw_span.currentIndexChanged.connect(self._on_uvw_span)
        grp_uvw.append(self.cmb_uvw_span)
        self.sp_uvw_pairs = QSpinBox()
        self.sp_uvw_pairs.setRange(1, 256)
        self.sp_uvw_pairs.setValue(4)
        self.sp_uvw_pairs.setToolTip("UVW 电角度 = 角度 × 每转周期数（板上 0x0100 的极对数，"
                                     "复位值 4）。改了会清空累积并按新值重新分箱")
        self.sp_uvw_pairs.valueChanged.connect(self._on_uvw_pairs)
        grp_uvw.append(self.sp_uvw_pairs)
        self.chk_uvw_line = QCheckBox("扇区线")
        self.chk_uvw_line.setChecked(True)
        self.chk_uvw_line.setToolTip("在 60°/120°/180°/240°/300° 画分隔线（只画落在窗口里的）")
        self.chk_uvw_line.toggled.connect(self._on_uvw_line)
        grp_uvw.append(self.chk_uvw_line)

        self.btn_auto2 = QPushButton("恢复自动")
        grp_auto = [self.btn_auto2]
        self.btn_auto2.setToolTip("横轴回到整圈 360°（等价于在图里双击）")
        self.btn_auto2.clicked.connect(self.reset_auto)
        self.btn_export_view2 = QPushButton("导出当前视图")
        self.btn_export_view2.setToolTip("按当前角度窗口/通道排布导出 PNG（像素契约与全貌导出一致）")
        self.btn_export_view2.clicked.connect(lambda: self.export_view_requested.emit())
        self._ctrl_groups = (grp_xspan, grp_layout, grp_gap, grp_uvw,
                             [self.btn_auto2], [self.btn_export_view2])
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

        self.lab_view2 = QLabel("量程：—")
        self.lab_view2.setObjectName("Hint")
        uk.fix_lines(self.lab_view2, 1)
        side_lay.addWidget(self.lab_view2)

        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(2)
        # R7-B：读数块不摊到卡片两头。★ m02689：富余宽度给**数值列**（col=1），
        #   不给空列 —— 空列拿 stretch 时数值列只能按"最长文字"定宽，
        #   文字一变长整列就抽、右邻列被推走（这正是"字多字少乱晃"的来源之一）。
        # 四列：名称 | 数值 | 名称 | 数值 —— 两列数值都要分到富余宽度，
        # 否则右边那列只剩 vmin（150 px），"1024/1024、1024/1024" 这种值会被裁。
        # 两列读数：col0 = 名称+数值，col1 = 名称+数值。数值标签是 Ignored 宽度
        # （见 ui_kit.field），宽度只由列决定 ⇒ 给足最小宽，长值才不会裁。
        grid.setColumnStretch(0, 0)
        grid.setColumnStretch(1, 1)
        grid.setColumnMinimumWidth(0, 380)
        grid.setColumnMinimumWidth(1, 430)
        self.v_cfg = uk.field(grid, "板上配置", "—", width=88, row=0, col=0,
                              mono=False, vmin=280)
        self.v_duty = uk.field(grid, "A / B 占空比", "—", width=88, row=0, col=1)
        self.v_phase = uk.field(grid, "A→B 相位差", "—", width=88, row=1, col=0)
        self.v_cover = uk.field(grid, "箱覆盖率", "—", width=88, row=1, col=1)
        self.v_edge = uk.field(grid, "AB 边沿率（理论）", "—", width=88, row=2, col=0)
        # ★ 阶段 5 D 批：方波判决的质量读数（用户 m15713 第 12 条）
        self.v_sq = uk.field(grid, "方波判决", "—", width=88, row=2, col=1)
        self.v_sqper = uk.field(grid, "每周期箱数", "—", width=88, row=3, col=0)
        # Z 脉冲那句最长（"观测 N 帧（x%）/ 理论 … Hz、宽 …°（…）"），独占一整行，
        # 否则只能塞进半个卡片、尾巴被裁（m02689 用户截图里就是断在"宽 14"）
        zrow = QHBoxLayout()
        zrow.setSpacing(6)
        grid.addLayout(zrow, 4, 0, 1, 2)
        self.v_z = uk.field(zrow, "Z 脉冲", "—", width=88, mono=False, vmin=200)
        # R20（批次 5）：占空比/相位差/边沿率随箱内采样抖动 ⇒ 显示层稳定化；
        #   箱覆盖率是"填了多少箱"的计数（在涨），不套
        self.st_duty_a = uk.Stable("duty")
        self.st_duty_b = uk.Stable("duty")
        self.st_phase = uk.Stable("phase_ab")
        self.st_perr = uk.Stable("phase_ab")
        self.st_edge = uk.Stable("ab_edge_mhz")
        self.st_pct = {s: uk.Stable("st_pct") for s in range(8)}
        side_lay.addLayout(grid)

        if HAS_MPL:
            self.fig = Figure(figsize=(9.4, 2.4), dpi=100)
            self.ax_ab = self.fig.add_subplot(1, 2, 1)
            self.ax_uvw = self.fig.add_subplot(1, 2, 2)
            self.canvas = FigureCanvas(self.fig)
            # ★ 独立大窗口传 canvas_h=None ⇒ 不钉高，画布跟着窗口一起长（那边没有高度闭环）
            if canvas_h:
                self.canvas.setFixedHeight(int(canvas_h))
            side_lay.addStretch(0)
            lay.addWidget(self.side, 3, 0, 1, 2)
            lay.addWidget(self.canvas, 4, 0, 1, 2)
            lay.setRowStretch(4, 1)
            self._init_axes()
        else:                                                    # pragma: no cover
            self.fig = self.canvas = None
            lab = QLabel("未安装 matplotlib，等效采样图无法显示（pip install matplotlib）")
            lab.setObjectName("Hint")
            self.lab_nompl = lab
            side_lay.addStretch(0)
            lay.addWidget(self.side, 3, 0, 1, 2)
            lay.addWidget(lab, 4, 0, 1, 2)
            lay.setRowStretch(4, 1)

        # ---- 六状态数据表 ----
        self.lab_states = QLabel("UVW 六状态数据表（合法状态应各占 1/6 ≈ 16.7%）")
        self.lab_states.setObjectName("FieldName")
        lay.addWidget(self.lab_states, 5, 0, 1, 2)
        tbl = QGridLayout()
        tbl.setHorizontalSpacing(10)
        tbl.setVerticalSpacing(1)
        # R7-B：两组（前 3 行 / 后 3 行）紧挨着，余量丢给最右边空列；两组之间留 36 px 间隔
        #        （原来 6 列平分宽度，两组被摊到卡片两头，中间空一大片）
        tbl.setColumnStretch(6, 1)
        tbl.setColumnMinimumWidth(3, 36)
        for i, s in enumerate(LEGAL_ROWS):
            row, col = i % 3, (i // 3) * 3
            name = QLabel(az.state_text(s))
            name.setObjectName("FieldName")
            name.setMinimumWidth(84)
            val = QLabel("—")
            val.setProperty("mono", "true")
            val.setMinimumWidth(96)
            bar = QFrame()
            bar.setFixedHeight(9)
            bar.setMinimumWidth(2)
            bar.setMaximumWidth(90)
            bar.setStyleSheet("background:%s; border-radius:4px;" % C["secondary"])
            tbl.addWidget(name, row, col)
            tbl.addWidget(val, row, col + 1)
            tbl.addWidget(bar, row, col + 2)
            self._rows[s] = (val, bar)
        lay.addLayout(tbl, 6, 0, 1, 2)
        self._sync_controls()

    # ---------------------------------------------------------------- 控件排布
    def eventFilter(self, obj, ev):
        """双击卡片标题 = 打开独立大窗口（图内双击仍归 ScopeNav 的「恢复自动」）。"""
        if obj is getattr(self, "lab_title", None) and ev.type() == QEvent.MouseButtonDblClick:
            self.popup_requested.emit()
            return True
        return super().eventFilter(obj, ev)

    def _fill_ctrl(self):
        """把登记好的控制组排进 `self._ctrl_grid`：一行放完（阶段 2 起没有第二种版面）。"""
        g = self._ctrl_grid
        while g.count():
            g.takeAt(0)
        for c in range(24):
            g.setColumnStretch(c, 0)
        c = 0
        for grp in self._ctrl_groups:
            for w in grp:
                g.addWidget(w, 0, c)
                c += 1
        g.setColumnStretch(c, 1)                 # 整行右侧留白

    # ---------------------------------------------------------------- 外部接口
    def _on_out_click(self, key):
        """点「ABZ / UVW 使能」：只把目标位报给主窗口，写与回读由主窗口统一做。

        ★ 按钮自己先被 Qt 拨到新状态（checkable 的默认行为）——若主窗口拒绝或回读不符，
          它会回调 `restore_output()` 把按钮拨回板上实际值，所以这里不做乐观处理。
        """
        btn = self.btn_abz_en if key == "abzen" else self.btn_uvw_en
        self.output_requested.emit({key: 1 if btn.isChecked() else 0})

    def _sync_out_buttons(self):
        """按已知的板上 0x0109 把两个按钮拨到位（blockSignals：这不算用户点击）。"""
        bits = self._out_bits or {}
        for key, btn in (("abzen", self.btn_abz_en), ("uwven", self.btn_uvw_en)):
            btn.blockSignals(True)
            btn.setChecked(bool(bits.get(key)))
            btn.blockSignals(False)

    def restore_output(self):
        """写被拒/回读不符时，把按钮拨回板上实际状态（避免"界面说已开、板上还关着"）。"""
        self._sync_out_buttons()

    def set_connected(self, conn, enabled=None):
        en = bool(conn if enabled is None else enabled)
        # 断开/忙碌时不许改箱、不许暂停：改箱会清空画布与计数，读数却还留着旧的（自相矛盾）
        self.cmb_bins.setEnabled(en)
        self.btn_reset.setEnabled(en)
        self.chk_pause.setEnabled(en)
        # 一键使能要往板子写寄存器，断开时禁用（免得点了没反应还以为是软件坏了）
        self.btn_abz_en.setEnabled(en)
        self.btn_uvw_en.setEnabled(en)
        # 「方波可看 / 还原」同样要写 0x0101，断开时禁用
        self.btn_square.setEnabled(en)
        self.btn_square_back.setEnabled(en)

    # ------------------------------------------------------------ 箱数（程序化）
    def bins(self):
        return int(self.an.bins)

    def set_bins(self, bins):
        """程序化改箱数（「方波可看」预设用）：同步下拉框，并让分析器按新箱数重新起算。

        与用户手点下拉框等价（走同一个 `configure` 路径）——箱数变了，累积/读数/表都要清，
        否则旧占比会挂在新箱数上。
        """
        try:
            bins = int(bins)
        except (TypeError, ValueError):
            return False
        if bins not in az.BINS_CHOICES:
            return False
        if int(self.an.bins) == bins:
            return True
        idx = list(az.BINS_CHOICES).index(bins)
        self.cmb_bins.blockSignals(True)
        self.cmb_bins.setCurrentIndex(idx)
        self.cmb_bins.blockSignals(False)
        self.an.configure(bins=bins)
        self._snap = None
        self._update_table(None)
        self._clear_readouts()
        if HAS_MPL:
            self._init_axes()
        return True

    def _clear_readouts(self):
        """把六个读数与提示复位（清空累积/改箱后用，别让旧读数配着新图）。"""
        # ★ 2026-10-17 全面自查修：v_sq/v_sqper 也要复位，否则「清空累积」后旧的
        #   方波判决百分比与"每周期箱数"会配着空图一直挂着（_update_readouts 在快照
        #   为 None 时直接 return，不会把它们刷成"—"）。
        for lab in (self.v_duty, self.v_phase, self.v_cover, self.v_edge, self.v_z,
                    self.v_sq, self.v_sqper):
            lab.setText("—")
            lab.setStyleSheet("")
            lab.setToolTip("")
        for st in (self.st_duty_a, self.st_duty_b, self.st_phase, self.st_perr,
                   self.st_edge):
            st.reset()
        for st in self.st_pct.values():
            st.reset()
        self.lab_hint.setText("等效采样已清空，等新数据填箱…")

    def reset(self):
        self.an.reset()
        self._snap = None
        self.f_in = None
        self._update_table(None)
        self._clear_readouts()
        if HAS_MPL:
            self._init_axes()

    def _cfg_text(self):
        return "inter=%d div=%d 极对数=%d" % (self.an.inter, self.an.div, self.an.pairs)

    def refresh_readouts(self):
        """R20：按当前显示口径重画读数与六状态表（切「原始值」时由主窗口调）。"""
        self._update_readouts(self._snap)
        self._update_table(self._snap)

    def set_regs(self, regs):
        """板上配置（host/task_read_all 的 result["regs"]）：inter/div/pairs/zwidth。"""
        self.an.set_regs(regs)
        self._regs = regs                     # 供 mirror() 转给独立大窗口
        # ★ 配置读不到时不要拿分析器的默认值(32/1/4)冒充板上配置 —— 那是"看起来像真的"的假读数
        self.v_cfg.setText(self._cfg_text() if regs else "读失败")
        if HAS_MPL:
            self._init_axes()

    def set_output(self, bits, raw=None):
        """0x0109 的八位：极性/方向/使能。`raw` 给定时标签直接用寄存器的中文解码。"""
        if not bits:
            # 读失败时不要瞎猜"仅 ABZ"（那是把未知当成已知）
            self._out_bits = None
            self.v_cfg.setText(self._cfg_text() + "｜输出配置 读失败")
            self.lab_out.setText("输出使能：0x0109 读失败（先「设备自检」重读，才能一键使能）")
            self._sync_out_buttons()
            return
        self._out_bits = dict(bits)
        self._raw_out = raw                   # 供 mirror() 转给独立大窗口
        self.an.set_output(bits)
        self._sync_out_buttons()
        short = "ABZ+UVW" if bits.get("uwven") else "仅 ABZ"
        self.v_cfg.setText("%s｜%s" % (self._cfg_text(), short))
        if raw is not None:
            self.lab_out.setText("输出使能：%s（0x0109 = 0x%04X）"
                                 % (rg.output_text(raw), int(raw) & 0xFFFF))
        else:
            self.lab_out.setText("输出使能：%s" % short)

    def set_f_in(self, f_in):
        self.f_in = f_in
        self.an.set_f_in(f_in)

    def mirror(self, other):
        """把「板上事实」从另一个面板同步过来（独立大窗口用，见 main_window._tick）。

        同步的只有板上配置（inter/div/…）、0x0109 输出位与输入频率 —— 这些是客观事实，
        两个窗口必须一致，否则弹窗里的周期换算会算错。
        **视图设置（分箱、横轴窗口、通道排布、间距）各窗口独立**：在大窗口里放大看细节时，
        不该顺手把主界面的量程也改掉。
        """
        regs = getattr(other, "_regs", None)
        if regs is not getattr(self, "_regs", object()):
            self.set_regs(regs)
        bits = getattr(other, "_out_bits", None)
        if (bits or None) != (getattr(self, "_out_bits", None) or None):
            self.set_output(bits or {}, getattr(other, "_raw_out", None))
        self.set_f_in(other.f_in)

    def feed(self, frames, force_draw=False):
        """吃进本 tick 的新帧（凑够间隔再重画，避免刷新过密把界面拖卡）。"""
        now = time.monotonic()
        if frames:
            # ★ 2026-10-17 全面自查修：①把 now 传给分析器（否则 t_first 恒 None ⇒
            #   span_s/fps_clock 恒 None，"AB 边沿率接近帧率"那条分因永不触发）
            #   ②snapshot=False：下面还会自己算一份快照，让 feed 再全量算一份是白烧
            #   （bins=1024 时约 3 ms/次 × 10 Hz × 两个窗口）
            self.an.feed(frames, t_now=now, snapshot=False)
        if self.paused and not force_draw:
            return
        if not force_draw and (now - self._last_draw) < self._interval:
            return
        t0 = time.monotonic()
        self._snap = self.an.snapshot(now)
        self._update_readouts(self._snap)
        self._update_table(self._snap)
        if HAS_MPL:
            self._redraw(self._snap)
        self._draw_s = time.monotonic() - t0
        self._last_draw = time.monotonic()
        # 自适应：宁可 2 次/秒也不让重画拖住界面
        self._interval = min(REDRAW_MAX_S, max(REDRAW_MIN_S, self._draw_s * 2.5))

    # ------------------------------------------------- R3 量程（示波器式导航）
    def nav_axes(self):
        return self.ax_ab if HAS_MPL else None

    def x_span(self):
        return float(self.x_span_deg if self.x_mode == "manual" else 360.0)

    def set_x_span(self, span):
        self.x_span_deg = min(max(float(span), min(X_SPANS_DEG)), max(X_SPANS_DEG))
        self.x_mode = "manual"
        up.put("abz", "x_mode", "manual")
        up.put("abz", "x_span_deg", self.x_span_deg)
        self._sync_controls()
        self._redraw(self._snap)

    # ---- R9②（批次 4）：按钮与键盘共用的逐档步进 / 微调入口
    def step_x(self, delta, fine=False):
        """角度窗口步进：delta<0 = 更窄（一个扇区内看细节），>0 = 更宽；fine=True 微调。"""
        if fine:
            self.set_x_span(self.x_span() * (FINE_STEP ** (-int(delta))))
            return
        seq = X_SPANS_DEG
        cur = self.x_span()
        idx = min(range(len(seq)), key=lambda i: abs(seq[i] - cur))
        idx = min(max(idx + int(delta), 0), len(seq) - 1)
        self.set_x_span(seq[idx])

    def step_y(self, delta, fine=False):
        """通道间距步进：delta>0 = 拉开（方波太密时用），<0 = 收紧；fine=True 每次 FINE_GAP。"""
        step = FINE_GAP if fine else 0.1
        self._on_spacing(float(self.spacing) + step * int(delta))

    def kbd_pause(self):
        """Space：暂停/继续。"""
        self.chk_pause.toggle()

    def kbd_export(self):
        """E：导出当前视图。"""
        self.export_view_requested.emit()

    def x_center(self):
        return float(self.x_center_deg if self.x_mode == "manual" else 180.0)

    def set_x_center(self, center):
        sp = self.x_span()
        lo, hi = sp / 2.0 - 5.0, 365.0 - sp / 2.0
        c = min(max(float(center), lo), hi) if lo <= hi else 180.0
        self.x_center_deg = c
        up.put("abz", "center_deg", c)
        self._redraw(self._snap)

    def y_pan(self):
        return self.y_off

    def set_y_pan(self, off):
        self.y_off = min(max(float(off), -3.0), 3.0)
        self._redraw(self._snap)

    def reset_auto(self):
        self.x_mode = "auto"
        self.x_center_deg = 180.0
        self.y_off = 0.0
        up.put("abz", "x_mode", "auto")
        self._sync_controls()
        self._redraw(self._snap)

    def scope_view(self):
        """给「按当前视图导出」用：当前角度窗口 + 通道排布/间距。"""
        if not HAS_MPL:
            return None
        oa, ob, oz, ylim = self._chan_offsets()
        return {"xlim": list(self.ax_ab.get_xlim()), "ylim": list(self.ax_ab.get_ylim()),
                "offsets": [oa, ob, oz], "text": self._view_text()}

    def _chan_offsets(self):
        """三路电平的基线偏移与纵轴范围（受排布/间距/拖动平移影响）。"""
        gap = GAP_BASE * self.spacing * (2.0 if self.layout_mode == "split" else 1.0)
        oa, ob, oz = 2.0 * gap, gap, 0.0
        top = 2.0 * gap + 1.2 + self.y_off
        return oa, ob, oz, (-0.3 + self.y_off, top)

    def _view_text(self):
        sp = self.x_span()
        tm = "自动（整圈）" if self.x_mode == "auto" else "手动"
        return ("横轴 %.4g°（%s，中心 %.0f°）· %s 间距 %.1f"
                % (sp, tm, self.x_center(), "分离" if self.layout_mode == "split" else "叠加",
                   self.spacing))

    def _sync_controls(self):
        want = "auto" if self.x_mode == "auto" else self.x_span_deg
        for cmb, val in ((self.cmb_xspan, want),):
            cmb.blockSignals(True)
            # R15：微调值（Ctrl+滚轮 / Shift+方向键）补一条「（微调）」临时档，
            #      不再"就近显示"成相邻档位（与「量程：」读数对不上，用户 m11938 点名要改）；
            #      位数与 `_view_text()` 的 %.4g° 对齐，两处数字一致。
            uk.sync_span_combo(cmb, val, "满屏 %.4g°（微调）")
            cmb.blockSignals(False)
        for cmb, val in ((self.cmb_layout2, self.layout_mode),):
            cmb.blockSignals(True)
            idx = cmb.findData(val)
            cmb.setCurrentIndex(max(0, idx))
            cmb.blockSignals(False)
        self.sp_gap.blockSignals(True)
        self.sp_gap.setValue(float(self.spacing))
        self.sp_gap.blockSignals(False)
        if HAS_MPL:
            self.lab_view2.setText("量程：" + self._view_text())
        seq = X_SPANS_DEG
        cur = self.x_span()
        i = min(range(len(seq)), key=lambda k: abs(seq[k] - cur))
        self.btn_xspan_prev.setEnabled(i > 0)
        self.btn_xspan_next.setEnabled(i < len(seq) - 1)

    def _on_xspan(self, _idx):
        val = self.cmb_xspan.currentData()
        if val == "auto":
            self.x_mode = "auto"
            self.x_center_deg = 180.0
            up.put("abz", "x_mode", "auto")
        else:
            self.x_mode = "manual"
            self.x_span_deg = float(val)
            up.put("abz", "x_mode", "manual")
            up.put("abz", "x_span_deg", float(val))
        self._sync_controls()
        self._redraw(self._snap)

    def _on_uvw_span(self, _idx):
        v = self.cmb_uvw_span.currentData()
        self._uvw_span = float(v or 360.0)
        if HAS_MPL:
            self._init_axes()
            if self._snap is not None:
                self._redraw(self._snap)

    def _on_uvw_pairs(self, value):
        self.an.configure(pairs=int(value))        # pairs 变了要清空累积
        self._snap = None
        self._update_table(None)
        self._clear_readouts()
        if HAS_MPL:
            self._init_axes()

    def _on_uvw_line(self, on):
        self._uvw_line = bool(on)
        if HAS_MPL:
            self._init_axes()
            if self._snap is not None:
                self._redraw(self._snap)

    def _on_layout(self, _idx):
        self.layout_mode = self.cmb_layout2.currentData() or "overlay"
        up.put("abz", "layout", self.layout_mode)
        self._sync_controls()
        self._redraw(self._snap)

    def _on_spacing(self, value):
        self.spacing = min(max(float(value), SPACING_RANGE[0]), SPACING_RANGE[1])
        up.put("abz", "spacing", self.spacing)
        self._sync_controls()
        self._redraw(self._snap)

    # ------------------------------------------------------- 给导出用的接口
    def analyzer_snapshot(self):
        """当前等效采样快照（没采到数据就是 None）——导出 ABZ/UVW 图要用。"""
        return self._snap

    def theory(self, f_in=None):
        """按输入频率算理论边沿率/周期；不给就用面板最近一次测得的频率。"""
        return self.an.theory(self.f_in if f_in is None else f_in)

    # ---------------------------------------------------------------- 事件
    def _on_pause(self, on):
        self.paused = bool(on)
        if not on:
            self.feed([], force_draw=True)

    def _on_reset(self):
        self.reset()

    def _on_bins(self, _idx):
        bins = self.cmb_bins.currentData()
        if bins:
            self.an.configure(bins=bins)          # 内部会把计数清零
            self._snap = None
            # 图和计数都清了，读数和状态表也得跟着清（否则旧占比挂着新箱数）
            self._update_table(None)
            self._clear_readouts()
            if HAS_MPL:
                self._init_axes()

    # ---------------------------------------------------------------- 绘图
    def _init_axes(self):
        oa, ob, oz, ylim = self._chan_offsets()
        sp = self.x_span()
        c = self.x_center()
        for ax, title, labs in ((self.ax_ab, "ABZ 等效采样（横轴 = 输入电角度，%d 箱；窗口 %.4g°）"
                                 % (self.an.bins, sp), ["Z", "B", "A"]),
                                (self.ax_uvw, "UVW 等效采样（横轴 = UVW 电角度，每转 %d 周期；窗口 %.4g°）"
                                 % (self.an.pairs, self._uvw_span), ["W", "V", "U"])):
            ax.clear()
            ax.set_title(title, fontsize=uf.pt(9), color=C["text"])
            ax.tick_params(labelsize=uf.pt(7), colors=C["muted"])
            for side in ("top", "right"):
                ax.spines[side].set_visible(False)
            for side in ("left", "bottom"):
                ax.spines[side].set_color(C["line"])
            ax.grid(True, color=C["line"], linewidth=0.6, alpha=0.9)
            ax.set_xlim(c - sp / 2.0, c + sp / 2.0)
            ax.set_ylim(ylim[0], ylim[1])
            ax.set_yticks([oz + 0.5, ob + 0.5, oa + 0.5])
            ax.set_yticklabels(labs)
            ax.set_xlabel("电角度 (°)", fontsize=uf.pt(7))
        # ---- UVW 用自己的一套窗口/刻度（m02689：可调）
        _us = max(5.0, float(self._uvw_span))
        _uc = float(self._uvw_center)
        self.ax_uvw.set_xlim(_uc - _us / 2.0, _uc + _us / 2.0)
        if _us >= 359.9:
            _tk = [0, 60, 120, 180, 240, 300, 360]
        else:
            _n = 6 if _us >= 120 else (4 if _us >= 60 else 3)
            _a = _uc - _us / 2.0
            _tk = [_a + _us * i / float(_n) for i in range(_n + 1)]
        self.ax_uvw.set_xticks(_tk)
        self.ax_uvw.set_xticklabels(["%g" % round(t, 1) for t in _tk])
        # 扇区分隔线：只画落在窗口里的那几条
        if self._uvw_line:
            for k in range(1, 6):
                if _uc - _us / 2.0 < k * 60.0 < _uc + _us / 2.0:
                    self.ax_uvw.axvline(k * 60.0, color=C["line"],
                                        linewidth=0.8, alpha=0.9)
        self.fig.tight_layout(pad=0.6)
        if self._nav is None:
            self._nav = uk.ScopeNav(self.canvas, self, self)
        self.canvas.draw_idle()

    def _step(self, ax, xs, ys, offset, color, label, width=1.6):
        """画一路电平：空箱跳过（不连线到 None），用 steps-post 画方波。"""
        px = [x for x, y in zip(xs, ys) if y is not None]
        py = [y + offset for y in ys if y is not None]
        if not px:
            return
        ax.plot(px, py, drawstyle="steps-post", color=color, linewidth=width, label=label)

    def _dash(self, ax, xs, ys, offset, color):
        """虚线画"理论方波"参照（不上图例，只做对照）。"""
        if not ys:
            return
        px = [x for x, y in zip(xs, ys) if y is not None]
        py = [y + offset for y in ys if y is not None]
        if not px:
            return
        ax.plot(px, py, drawstyle="steps-post", color=color, linewidth=0.9,
                linestyle="--", alpha=0.55)

    def _redraw(self, snap):
        if not HAS_MPL:
            return
        oa, ob, oz, _ylim = self._chan_offsets()
        self.ax_ab.clear()
        self.ax_uvw.clear()
        self._init_axes()
        if snap is None or not snap.get("samples_ab"):
            self.canvas.draw_idle()
            return
        bins = snap["bins"]
        xs = [(i + 0.5) * 360.0 / bins for i in range(bins)]
        # ★ 阶段 5（D 批，用户 m15713 第 12 条）：主曲线画**硬判决方波**。
        #   箱内平均值（snap["a"]/["b"]…）在"一箱跨多个 A/B 周期"时会落在一堆中间值上，
        #   连起来就是用户看到的"被平均成的阶梯"；方波本来只有两种电平，按多数票判 0/1
        #   之后阶梯就没了。虚线是相位对齐的理论方波（方案 C 的"理论"那一路）做对照。
        self._step(self.ax_ab, xs, snap.get("sq_a"), oa, C["primary"], "A")
        self._step(self.ax_ab, xs, snap.get("sq_b"), ob, C["warn"], "B")
        self._step(self.ax_ab, xs, snap.get("sq_z"), oz, C["ok"], "Z")
        self._dash(self.ax_ab, xs, snap.get("ideal_a"), oa, C["primary"])
        self._dash(self.ax_ab, xs, snap.get("ideal_b"), ob, C["warn"])
        # ---- UVW：按 60° 扇区块画（m02917 用户反馈"UVW 有点乱"）
        #   UVW 一个周期只有 16 帧左右（156 Hz × 4 周期 / 10 kHz），每扇区约 2.7 个样点；
        #   用 1024 箱的折线去连这些零星样点必然是锯齿。这里改成"每个扇区多数票 → 一段块"，
        #   永远只有 6 段，整齐可读；理论虚线（ideal_*）照旧叠着对照。
        for key, off, color, name in (("sq_u", oa, C["primary"], "U"),
                                      ("sq_v", ob, C["warn"], "V"),
                                      ("sq_w", oz, C["ok"], "W")):
            ys = snap.get(key)
            if not ys:
                continue
            for sec in range(6):
                lo = sec * 60.0
                hi = lo + 60.0
                vals = [y for x, y in zip(xs, ys) if y is not None and lo <= x < hi]
                if not vals:
                    continue
                lvl = 1.0 if (sum(vals) / float(len(vals))) >= 0.5 else 0.0
                self.ax_uvw.plot([lo + 0.6, hi - 0.6], [off + lvl, off + lvl],
                                 color=color, linewidth=3.4, solid_capstyle="butt",
                                 label=(name if sec == 0 else None))
        self._dash(self.ax_uvw, xs, snap.get("ideal_u"), oa, C["primary"])
        self._dash(self.ax_uvw, xs, snap.get("ideal_v"), ob, C["warn"])
        self._dash(self.ax_uvw, xs, snap.get("ideal_w"), oz, C["ok"])
        for ax in (self.ax_ab, self.ax_uvw):
            ax.legend(loc="upper right", fontsize=uf.pt(7), ncol=3, framealpha=0.9)
        # ★ 用户反馈（m15813）：删掉「采样不足：A/B 波形不可信，只看 Z 与读数」这个判定
        #   （不要再把 A/B 降透明度、也不要再改标题）。当箱数不足以还原方波时，
        #   改为在顶部提示里给可执行的建议（见 _update_readouts 的 lab_note）。
        _txt = "量程：" + self._view_text()
        # 覆盖箱数才是"密度"的诚实指标：相位锁死时每个箱只有一个采样相位，
        # 1024 箱里往往只有十几箱有数 —— 所以 UVW 用扇区块画，折线是画不出来的。
        _cov = int(snap.get("cover_uvw") or 0)
        if _cov:
            _txt += "｜UVW 覆盖 %d/%d 箱" % (_cov, int(snap.get("bins") or 0))
            if _cov < 64:
                _txt += "（相位锁死，属正常）"
        self.lab_view2.setText(_txt)
        self.canvas.draw_idle()

    # ---------------------------------------------------------------- 读数
    def _update_readouts(self, snap):
        if snap is None:
            return
        self.v_cfg.setText(self._cfg_text())
        if snap["duty_a"] is not None and snap["duty_b"] is not None:
            # R20：占空比稳定显示（悬停看原始值）
            self.st_duty_a.update(snap["duty_a"] * 100.0)
            self.st_duty_b.update(snap["duty_b"] * 100.0)
            self.v_duty.setText("%s / %s" % (self.st_duty_a.text(), self.st_duty_b.text()))
            self.v_duty.setToolTip(self.st_duty_a.tip("占空比应为 50%（受分箱采样影响）"))
        if snap["phase_ab_deg"] is not None:
            err = snap["phase_ab_err"] or 0.0
            self.st_phase.update(snap["phase_ab_deg"])
            self.st_perr.update(err)
            self.v_phase.setText("%s（偏 %s）" % (self.st_phase.text(), self.st_perr.text()))
            self.v_phase.setToolTip(self.st_phase.tip("正交编码器应接近 90°"))
            self.v_phase.setStyleSheet("color:%s;" % (C["ok"] if err <= 25 else C["warn"]))
        self.v_cover.setText("%d/%d、%d/%d" % (snap["cover_ab"], snap["bins"],
                                              snap["cover_uvw"], snap["bins"]))
        th_ = self.an.theory(self.f_in)
        if th_:
            self.st_edge.update(th_["ab_edge_rate"] / 1e6)
            self.v_edge.setText(self.st_edge.text())
            self.v_edge.setToolTip(self.st_edge.tip("4×inter/div×输入频率"))
        # 注意别在这儿算 duty_z/duty_z_theory：分析器一帧没进过时 duty_z 是 None，
        # 而 theory 恒为非零浮点，除下去会抛 TypeError 把整个刷新链打断（真踩过）
        txt = "观测 %d 帧（%.3f%%）" % (snap["z_hits"], (snap["duty_z"] or 0.0) * 100.0)
        if th_:
            txt += "／理论 %.1f Hz、宽 %.1f°" % (th_["z_rate"], snap["z_width_deg"])
            if snap.get("duty_z_locked"):
                # 锁相时"帧观测"折算模型失效（实测能差 25～34 倍），改给时间口径
                txt += "（相位锁定，时间占空比 %.4f%%）" % (
                    (snap.get("duty_z_theory_time") or 0.0) * 100.0)
        self.v_z.setText(txt)
        self.v_z.setStyleSheet("color:%s;" % (C["warn"] if snap["z_hits"] == 0 else C["text"]))
        # ★ 阶段 5 D 批：方波判决质量（样本够不够、判得准不准）
        conf = snap.get("sq_conf")
        if conf is None:
            self.v_sq.setText("—")
            self._set_val_color(self.v_sq, "")
        else:
            self.v_sq.setText("%.0f%%" % (conf * 100.0))
            self._set_val_color(self.v_sq, C["ok"] if conf >= 0.9 else C["warn"])
            self.v_sq.setToolTip("被填箱里电平贴近 0 或 1 的比例。低说明每箱跨多个 A/B 周期、"
                                 "平均值趋中 —— 此时判决出的方波只是噪声，请把 inter 调小。")
        per = snap.get("sq_per_bins")
        need = snap.get("sq_per_need") or 8
        if not per:
            self.v_sqper.setText("—")
            self._set_val_color(self.v_sqper, "")
        else:
            self.v_sqper.setText("%.1f 箱" % per)
            self._set_val_color(self.v_sqper, C["ok"] if per >= need else C["warn"])
            self.v_sqper.setToolTip("一个 A/B 周期平均占多少箱。≥%d 箱才画得出方波形状"
                                    "（inter 越大这个数越小）。" % need)
        notes = snap.get("notes") or []
        if notes:
            self.lab_hint.setText("；".join(notes))
        else:
            self.lab_hint.setText("等效采样已填满全部箱，可以读数了。")

    def _set_val_color(self, val, color):
        """给读数上色，并重新开 tnum。

        ★ 阶段 3 踩过的坑：`setStyleSheet()` 会让 Qt 重新 polish 这个控件，
        把之前 `setFont()` 上的 tabular figures 抹掉 —— 所以上色之后必须再开一次，
        否则这几行数字会在位数变化时左右抖（其它 mono 标签没这个问题是因为它们从不下色）。
        """
        val.setStyleSheet("color:%s;" % color)
        uf.use_tabular(val)

    def _update_table(self, snap):
        shares = snap["state_share"] if snap else [0.0] * 8
        counts = snap["states"] if snap else [0] * 8
        exp = 100.0 / 6.0
        for s, (val, bar) in self._rows.items():
            if not snap:
                val.setText("—")
                self._set_val_color(val, "")                 # 别把红/黄留在破折号上
                bar.setFixedWidth(2)
                self.st_pct[s].reset()
                continue
            sh = shares[s]
            # R20：六状态占比稳定显示（帧数本身是计数、直接写；判色也用稳定值，免得颜色闪）
            self.st_pct[s].update(sh)
            sh_disp = self.st_pct[s].disp if self.st_pct[s].disp is not None else sh
            val.setText("%7d 帧  %5.2f%%" % (counts[s], sh_disp))
            if abs(sh_disp - exp) <= 2.0:
                self._set_val_color(val, C["ok"])
            elif abs(sh - exp) <= 6.0:
                self._set_val_color(val, C["warn"])
            else:
                self._set_val_color(val, C["fault"])
            bar.setFixedWidth(max(2, min(90, int(sh / exp * 45.0))))
