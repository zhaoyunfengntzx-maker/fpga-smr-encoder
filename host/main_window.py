"""上位机主窗口（S1 连接/自检/统计 + S2 转速与倍频）。

界面结构（对应 docs/10_host_requirements.md 的三段式布局）
------------------------------------------------------
    顶部标题条
    ① 连接条    ：端口（自动列出 / 可手输）+ 刷新 + 连接/断开 + 状态灯
    ② 数据卡片区：设备信息 / 通信统计 / 实时数据预览
    ③ 转速与倍频：⑤ 转速与位置（M3）、⑥ 倍频倍率（M2，含高级参数折叠区）
    ④ 日志区    ：通信层说人话的记录，排障靠它

设计约束（来自协议事实，别改）
------------------------------
* 串口只能有一个主人 ⇒ 所有 I/O 都在 link.SerialWorker 线程里，界面只读事件队列。
* 界面用 QTimer 定时消费队列（默认 100 ms = 10 Hz），与串口速率解耦；
  万一界面卡了，旧批次会被丢掉并计数（丢批/丢帧），不会把内存撑爆。
* 阻塞调用（读身份证、写寄存器、回读）放到临时线程里，界面不假死；
  同一时刻只允许一个这样的任务（开工时把按钮全禁用）。
* 读寄存器是“连发两帧”才回一帧（应答滞后一帧的重叠语义），写只发一次 —— 都封装在 link.py。
"""

import os
import queue
import socket
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from PySide6.QtCore import QEvent, QObject, Qt, QThread, QTimer, QUrl, Signal         # noqa: E402
from PySide6.QtGui import QDesktopServices, QGuiApplication, QKeySequence, QShortcut       # noqa: E402
from PySide6.QtWidgets import (
    QDoubleSpinBox,QApplication, QAbstractSpinBox, QCheckBox, QComboBox,  # noqa: E402
                               QFrame, QHBoxLayout, QLabel, QLineEdit,
                               QMainWindow, QMessageBox, QPlainTextEdit,
                               QPushButton, QScrollArea, QSizePolicy,
                               QStackedWidget, QTextEdit, QToolButton,
                               QVBoxLayout, QWidget)

import export_png as ep                                           # noqa: E402
import link as lk                                                 # noqa: E402
import page_overview as ov                                        # noqa: E402
import panel_abz as pz                                            # noqa: E402
import panel_alarm as pa                                          # noqa: E402
import panel_capture as pc                                        # noqa: E402
import panel_interp as pi                                         # noqa: E402
import panel_quality as pq                                        # noqa: E402
import panel_status as pst                                       # noqa: E402
import panel_lut as plut                                          # noqa: E402
import panel_health as phl                                       # noqa: E402
import panel_record as pr                                         # noqa: E402
import panel_speed as ps                                          # noqa: E402
import panel_wave as pw                                           # noqa: E402
import ports as pm                                                # noqa: E402
import recorder as rc                                             # noqa: E402                                                       # noqa: E402
import theme as th                                                # noqa: E402
import ui_font as uf                                              # noqa: E402
import ui_kit as uk                                               # noqa: E402
import ui_prefs as up                                             # noqa: E402
import abz_popup as azp                                           # noqa: E402
import wave_popup as wvp                                          # noqa: E402

C = th.C
# ---- 链路存活看门狗（审计 B3/B4）-------------------------------------------
# link.py 的写超时只投一条 error 就 return，而原来只有 "open" 事件能把状态改回
# "已连接" ⇒ 一次误码就让状态栏永久停在"故障"（假死）。改成按"多久没收到帧"判定。
import linkctl as lc

LINK_QUIET_WARN_S = lc.LINK_QUIET_WARN_S   # 多久没帧就报"链路无数据"（来帧自动恢复）
LINK_QUIET_BAD_S = lc.LINK_QUIET_BAD_S     # 再久就自动重连（最多 3 次，收到帧就复位）
# ---- 滚轮（R1）：全界面滚轮一律滚页面，1/8 度 → 多少像素 ----
WHEEL_PX_PER_UNIT = 0.6

# 「方波可看」预设的目标：每个 A/B 周期至少铺多少个箱（每箱跨 ≤1/16 个周期）
# SQUARE_POINTS 搬到 tasks.py（square_pair 的默认参数），这里留个别名
# 给 selftest_ui 与界面文案用，避免两处各改一次。
from tasks import SQUARE_POINTS  # noqa: E402


# 读寄存器/写寄存器那些任务函数（纯 I/O，不碰界面）在 tasks.py
from tasks import (task_read_all, task_apply_inter_div, task_lut_upload, task_lut_dump, task_read_board_status, task_write_pairs, task_write_advanced, output_write_value, square_pair, _hms, _u32_from_pair, task_read_status, task_clear_latch)  # noqa: E402


# 阻塞任务队列搬到 host/taskrunner.py（串行一条线程，异常也当结果送回）
from taskrunner import TaskRunner  # noqa: E402
from ui_consts import TAG_TEXT, STREAM_POINTS, cfg_from_regs  # noqa: E402,F401
from cmds_mixin import CmdsMixin  # noqa: E402
from live_mixin import (LiveMixin, dev_id_ok, UI_PERIOD_MS,  # noqa: E402,F401
                        MAX_EVENTS_PER_TICK, STATUS_PERIOD_S)
from logview import (LogMixin, LOG_MAX_LINES, LOG_RANK, LOG_COLOR,  # noqa: E402,F401
                     LOG_FILTERS, LOG_FILTER_DEFAULT, _esc)


class MainWindow(LogMixin, LiveMixin, CmdsMixin, QMainWindow):

    def __init__(self):
        super().__init__()
        self.setWindowTitle("host_app · 信号采集与波形显示")
        # 窗口尺寸记忆（批次 3）：上次关窗时多大，这次就开多大（坏文件静默回落默认）
        # ★ 2026-10-16：再夹一次"屏幕可用区"——默认宽已提到 1600（R16 决策的最小尺寸），
        #   小屏笔记本上不该开出一个比屏幕还大的窗口。
        #   只在屏幕真的装得下最小窗口时才夹（离屏平台报 800×800 这种假数据，夹了反而失真）。
        _w, _h = up.window_size()
        try:
            _av = QGuiApplication.primaryScreen().availableGeometry()
            if _av.width() >= up.MIN_WINDOW_W:
                _w = min(int(_w), int(_av.width()))
            if _av.height() >= up.MIN_WINDOW_H:
                _h = min(int(_h), int(_av.height()))
        except Exception:                                   # pragma: no cover - 无屏幕信息
            pass
        self.resize(int(_w), int(_h))

        self.worker = None
        self.task = TaskRunner()
        self.task.done.connect(self._on_task_done)
        self.busy = False

        # ★ 审计 2 #11：工作线程（重试提示、ARP 告警）也会写日志，而 Qt 控件只能在
        #   GUI 线程碰。工作线程只往队列投递，界面线程 200 ms 泵一次统一落笔。
        self._logq = queue.Queue()
        self._logq_timer = QTimer(self)
        self._logq_timer.timeout.connect(self._pump_logq)
        self._logq_timer.start(200)

        # 实时统计（用增量算速率，别用累计值除总时长，否则连接阶段的帧会算进来）
        self.last_frame = None
        self.info = None
        self._stat_t = None
        self._stat_frames = 0
        # ★ 累计"界面已从链路事件队列取走的帧数"：_stat_frames 每个统计周期会被清零
        #   （用来算瞬时帧率），当累计值用会误判；真机核对"关窗不丢帧"要用这个不归零的
        self._frames_total = 0
        self._stat_bytes = 0
        self._link_exhaust_logged = False
        self._fps = 0.0
        self._bps = 0.0
        self._counters = None
        self._status_t = 0.0        # 上次读告警锁存状态的时间
        # 链路存活看门狗：状态全在 linkctl.LinkWatchdog 里（见 _watch_link）
        self._wd = lc.LinkWatchdog()
        self._status_busy = False
        self._status_sig = None     # 上次告警状态的"指纹"（只有变了才用信息级打一条）
        self._f_in = None           # 最近一次测得的输入频率（导出图与 ABZ 理论值要用）
        self._wave_win = None       # ⑧ 的独立大窗口（阶段 5 C 批；按需创建、关掉不销毁）
        self._abz_win = None        # ⑨ 的独立大窗口（阶段 5 续；同上）
        # 「方波可看」预设按下前的 {inter, bins}：供「还原」用；None = 没按过 / 已还原 / 已断开
        self._sq_saved = None
        # 丢帧/丢批的"已结账"基线：每笔计数增量只记一次（含断开时最后一次结账）
        self._acc_lost = 0
        self._acc_drop = 0
        # 日志（R5）：全量留在 _log_records 里，按显示级别过滤后渲染到 self.log
        # ★ 显示级别也记忆（批次 3）：上次关窗时选的级别，这次开窗照用
        self.log_level = up.choice("log", "level",
                                   tuple(v for _t, v in LOG_FILTERS), LOG_FILTER_DEFAULT)
        self._log_records = []

        self._build_ui()
        # 阶段 3：字体（Inter 幂等注册；自检/--smoke 不走 app.py，这里兜一次），
        # 然后把所有读数标签打开 tnum（等宽数字）——界面树上一次性收口，见 ui_font。
        uf.apply()
        self._tabular_labels = uf.apply_tabular(self)
        # 阶段 5（B 批）：字号随窗口自适应 —— 0 = 自动跟随窗口，>0 = 手动覆盖（Ctrl+=/-/0）
        self._scale_pref = float(up.number("ui", "scale", 0.0, uf.SCALE_MAX, 0.0))
        self._applied_scale = None
        self._scale_timer = QTimer(self)
        self._scale_timer.setSingleShot(True)
        self._scale_timer.setInterval(0)
        self._scale_timer.timeout.connect(self._on_scale_timer)
        self._apply_scale(self._target_scale(), force=True)
        self._install_wheel_router()        # R1：全界面滚轮 = 平滑滚动页面

        self.timer = QTimer(self)
        self.timer.setInterval(UI_PERIOD_MS)
        self.timer.timeout.connect(self._tick)
        self.timer.start()

        self.refresh_ports()

    # ------------------------------------------------------------- 建界面
    def _build_ui(self):
        root = QWidget()
        root.setObjectName("Shell")
        shell = QHBoxLayout(root)
        shell.setContentsMargins(0, 0, 0, 0)
        shell.setSpacing(0)

        # ---------- 阶段 2（R17）：左侧窄侧栏，一次一页 ----------
        self.sidebar = uk.Sidebar("host_app", "v13 · 以太网 + 抓包")
        self.sidebar.page_changed.connect(self._on_page_changed)
        shell.addWidget(self.sidebar)

        self._right = QVBoxLayout()
        # 阶段 3（Apple 视觉）：右列不留外边距 —— 顶栏要像 macOS 的工具条那样
        # 从左到右一条到底、只留一条细下边线；页面的内边距改由每页自己给（_make_pages）。
        self._right.setContentsMargins(0, 0, 0, 0)
        self._right.setSpacing(0)
        shell.addLayout(self._right, 1)
        # 下面照旧把卡片建出来，最后由 _make_pages() 分到六页里
        #（Qt 里 addWidget 到新布局 = 自动改父，所以创建代码不用动）
        outer = self._right
        self.lab_version = self.sidebar.lab_ver

        # ---------- 顶栏（端口 / 连接 / 设备自检 / 状态 / 原始值开关） ----------
        outer.addWidget(self._build_topbar())

        # ---------- ① 连接 → 已搬到顶栏，见 _build_topbar() ----------

        # ---------- ②③④ 数据卡片（②③ 归「诊断」页，④ 归「实时」页） ----------
        self.card_device = self._card_device()
        self.card_link = self._card_link()
        self.card_live = self._card_live()

        # ---------- ③ 转速与倍频（归「实时」页） ----------
        self.speed = ps.SpeedPanel()
        self.interp = pi.InterpPanel()
        self.speed.setMinimumWidth(400)
        self.interp.setMinimumWidth(540)
        self.speed.pairs_write_requested.connect(self._on_write_pairs)
        self.interp.apply_requested.connect(self._on_apply_inter_div)
        self.interp.advanced_requested.connect(self._on_apply_advanced)
        self.interp.adv_page_requested.connect(lambda: self.show_page("diag"))

        # ---------- ④⑥⑧ 告警（归「告警」页）+ 波形（归「实时」页） ----------
        self.alarm = pa.AlarmPanel()
        self.wave = pw.WavePanel()
        self.quality = pq.QualityPanel()
        self.quality.setMinimumWidth(420)
        self.board_status = pst.StatusPanel()
        self.health = phl.HealthPanel()
        self.lut = plut.LutPanel()
        self.lut.upload_requested.connect(self._on_lut_upload)
        self.lut.zeros_requested.connect(self._on_lut_zeros)
        self.lut.dump_requested.connect(self._on_lut_dump)
        self.lut.notice.connect(self.log_line)
        self._bstatus_busy = False
        self.board_status.read_requested.connect(self._on_read_board_status)
        self.board_status.bias_requested.connect(self._on_bias_track)
        self.alarm.setMinimumWidth(400)
        self.wave.setMinimumWidth(560)
        self.alarm.clear_requested.connect(self._on_clear_latch)
        self.alarm.refresh_requested.connect(self._on_read_status)

        # ---------- ⑤ ABZ / UVW 等效采样（归「编码器信号」页） ----------
        self.abz = pz.AbzPanel()
        self.abz.setMinimumWidth(560)

        # ---------- ⑩ 记录与导出（归「记录」页） ----------
        self.record = pr.RecordPanel()
        self.record.setMinimumWidth(560)
        self.record.export_requested.connect(self._on_export)
        self.record.notice.connect(self._log_notice)
        self.record.replay_requested.connect(self.start_replay)

        # ---------- ⑫ 原始波形抓包（归「抓包」页，v1.2 新增） ----------
        # 与「实时」页的区别：这一页抓的是连续 ADC 样点（板上 40 KB 缓冲），
        # 不是 10 kHz 遥测抽样；数据从 0x072E 批量 dump 回读（约 1.5 s）。
        self.capture = pc.CapturePanel()
        self.capture.setMinimumWidth(560)
        self.capture.capture_requested.connect(self._on_capture_requested)
        # 显示平滑：抓包页下拉是唯一入口，实时页跟着走（只影响绘制）
        self.capture.smooth_changed.connect(self.wave.set_smooth)
        try:
            self.capture.set_smooth(int(up.raw("capture", "smooth", 0) or 0))
        except Exception:                       # noqa: BLE001
            pass
        self.capture.net_check_requested.connect(self._net_check)
        self.capture.help_requested.connect(self._open_guide)
        self.capture.export_requested.connect(self._on_capture_export)
        # 二期连续流：接收器 + 刷新定时器（只在这一页用，跑的时候才创建线程）
        self._stream_params = None
        self._stream = None
        self._stream_p = {}
        self._stream_timer = QTimer(self)
        self._stream_timer.timeout.connect(self._on_stream_tick)
        # 批次 3：两张示波器图的「导出当前视图」按钮（按当前量程导出，像素契约不变）
        self.wave.export_view_requested.connect(lambda: self._on_export("wave_view"))
        self.abz.export_view_requested.connect(lambda: self._on_export("abz_view"))
        # 阶段 5（C 批）：⑧ 的「独立窗口」（按钮或双击卡片标题）——同一批数据、更大画布
        self.wave.popup_requested.connect(self._open_wave_popup)
        # 阶段 5（续）：⑨ 的「独立窗口」（同一套等效采样数据、更大画布）
        self.abz.popup_requested.connect(self._open_abz_popup)
        # ⑨ 卡的「ABZ 使能 / UVW 使能」一键按钮（写 0x0109 的 bit6/bit7，读-改-写）
        self.abz.output_requested.connect(self._on_set_output)
        # ⑨ 卡的「方波可看 / 还原」一键预设（读-改-写 0x0101 的 inter + 改分箱）
        self.abz.square_requested.connect(self._on_square_preset)
        self.abz.square_restore_requested.connect(self._on_square_restore)
        # 高级参数按钮被拦下（没读回板上现值就点应用）时，日志里给人话说清为什么
        self.interp.adv_blocked.connect(
            lambda: self._log_notice("高级参数：请先点顶栏『设备自检』把板上现值读上来再改"
                                     "（否则会按 0 覆盖同字节的其它位）", "warn"))

        # ---------- ⑪ 日志 ----------
        log_card, log_lay = uk.make_card(
            "通信日志", "每条命令的原始应答都会打在这里；排障先看这里。"
            "2 秒一次的告警轮询记为「调试」，默认不显示（想看就切「显示级别」）。",
            hint_lines=3)
        log_head = QHBoxLayout()
        log_head.setSpacing(8)
        log_head.addWidget(uk.small_label("显示级别", 76))
        self.combo_log = QComboBox()
        for label, key in LOG_FILTERS:
            self.combo_log.addItem(label, key)
        _keys = [k for _l, k in LOG_FILTERS]
        self.combo_log.setCurrentIndex(_keys.index(self.log_level)
                                       if self.log_level in _keys else _keys.index(LOG_FILTER_DEFAULT))
        self.combo_log.setToolTip("「全部（含调试）」里是每 2 秒一次的告警轮询明细；"
                                  "默认「信息及以上」，状态真有变化时仍会打一条")
        self.combo_log.currentIndexChanged.connect(self._on_log_filter)
        log_head.addWidget(self.combo_log)
        self.btn_log_clear = QPushButton("清空日志")
        self.btn_log_clear.setToolTip("清掉当前显示的全部日志（不影响记录与统计）")
        self.btn_log_clear.clicked.connect(self.clear_log)
        log_head.addWidget(self.btn_log_clear)
        log_head.addStretch(1)
        self.lab_log_count = QLabel("显示 0 / 共 0 行")
        self.lab_log_count.setObjectName("Hint")
        log_head.addWidget(self.lab_log_count)
        log_lay.addLayout(log_head)
        self.log = QPlainTextEdit()
        self.log.setObjectName("Log")
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(LOG_MAX_LINES)
        self.log.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        # 日志框是"滚轮白名单"：鼠标在它上面时滚它自己（滚大段原始应答很常用），
        # 不要被 R1 的"一律滚页面"抢走
        self.log.setProperty("wheelOwn", True)
        log_lay.addWidget(self.log)
        log_card.setMinimumHeight(206)
        self.log_card = log_card

        self.statusBar().showMessage("就绪")
        # 底部常驻状态条（需求 §界面要求：帧率 / 丢帧 / 校验错 / 已运行时长 常看得到）
        self._sb_lab = QLabel("已运行 —")
        self._sb_lab.setObjectName("AppSub")
        self.statusBar().addPermanentWidget(self._sb_lab)
        # R20 的全局「原始值」开关已搬到顶栏（阶段 2：顶栏放全局开关与状态）

        # 内容比一屏高，套一层滚动区（S3/S4 还要继续加卡片）
        self.setCentralWidget(root)
        self._make_pages()                   # 阶段 2（R17）：把卡片分到六页里

    # ---------------------------------- 阶段 2（R17）：顶栏 / 侧栏 / 六页
    def _build_topbar(self):
        """顶栏：端口 + 连接 + 设备自检 + 状态 + 全局「原始值」开关。

        阶段 2 把原来那张「① 连接」卡片收成一条：连接是"工具"，不是"内容"，
        不该占一整张卡；提示文字进 tooltip，界面留给数据。
        """
        bar = QFrame()
        bar.setObjectName("TopBar")
        self.topbar = bar                      # 自检/文档要能按名字找到这一条
        row = QHBoxLayout(bar)
        row.setContentsMargins(18, 10, 18, 10)
        row.setSpacing(8)

        self.combo_port = QComboBox()
        self.combo_port.setEditable(True)          # 可以手输，例如 COM9
        self.combo_port.setMinimumWidth(344)      # 阶段 3：留够"COM3 — USB-SERIAL CH340 (COM3) ★"
        self.combo_port.setToolTip("下拉框里的端口每插拔一次都可能变；看不到板子时点「刷新端口」。")
        row.addWidget(uk.small_label("端口", 36))
        row.addWidget(self.combo_port)
        self.btn_refresh = QPushButton("刷新端口")
        self.btn_refresh.clicked.connect(self.refresh_ports)
        row.addWidget(self.btn_refresh)
        self.btn_connect = QPushButton("连接")
        self.btn_connect.setObjectName("Primary")
        self.btn_connect.clicked.connect(self._on_connect)
        row.addWidget(self.btn_connect)
        self.btn_check = QPushButton("设备自检")
        self.btn_check.clicked.connect(self._on_check)
        self.btn_check.setEnabled(False)
        row.addWidget(self.btn_check)
        # 数据源（用户 m03198）：可选的，默认网口连续流；网口起不来会自动退回串口。
        # 串口始终连着 —— 自检/倍频/补偿表/板上状态都还要走它。
        self.cmb_src = QComboBox()
        self.cmb_src.addItem("网口连续流", "net")
        self.cmb_src.addItem("串口遥测", "serial")
        self.cmb_src.setMinimumWidth(118)      # 顶栏很挤：少 14 px 就是 1200 宽的余量
        self.cmb_src.setToolTip(
            "网口：连续流（12.5~50 MSPS 抽成 10 kHz 帧），角度由 s/c 现算，\n"
            "A/B/Z/UVW 电平和 Z 脉冲是按板上配置推导的，不是测出来的。\n"
            "串口：板上算好的 10 kHz 遥测帧（18 字节/帧，2 Mbaud 链路占 90%）。\n"
            "选网口时若连续流起不来，6 s 后自动退回串口并在日志里说明。")
        _src0 = str(up.raw("data", "src", "net") or "net")
        _i0 = self.cmb_src.findData(_src0)
        self.cmb_src.setCurrentIndex(_i0 if _i0 >= 0 else 0)
        self.cmb_src.currentIndexChanged.connect(self._on_source_changed)
        self._src = "serial"        # 真正在用的（连上串口后才可能变 net）
        row.addWidget(self.cmb_src)
        row.addStretch(1)
        self.lab_state = QLabel("未连接")
        self.lab_state.setObjectName("BigValueSmall")
        self.lab_state.setStyleSheet("color:%s;" % C["muted"])
        row.addWidget(self.lab_state)
        # R20：全局「原始值」开关（默认关 = 读数走显示层稳定化，悬停可看原始值）
        self.chk_raw = QCheckBox("原始值")
        # 阶段 3：状态型开关用"滑块"外观（样式表 QCheckBox[switch="true"]），
        # 语义型勾选（如"挂上就生效"）保持 macOS 圆角方框。
        self.chk_raw.setProperty("switch", "true")
        self.chk_raw.setToolTip(
            "勾上：所有读数直接显示未处理的原始值（末位会跳，便于核对）。\n"
            "不勾（默认）：读数按各自分辨率稳定显示，鼠标悬停能看到原始值与不确定度。\n"
            "电角度、多周期位置、累计圈数这类本来就在走的量不受影响。")
        self.chk_raw.setChecked(bool(up.raw("display", "raw", False)))
        self.chk_raw.toggled.connect(self._on_toggle_raw)
        row.addWidget(self.chk_raw)
        uk.set_raw_mode(self.chk_raw.isChecked())
        return bar

    def _make_pages(self):
        """把已经建好的卡片分到六页里（addWidget 到新布局 = 自动改父）。"""
        self.pages = QStackedWidget()
        self.pages.setObjectName("Pages")
        self._page_index = {}
        self._scrolls = {}
        builders = (
            ("overview", "概览", "一眼看结论：设备 / 链路 / 输入频率 / 转速 / 幅值 / 告警 / 记录",
             self._page_overview),
            ("live", "实时", "波形为主角：输入信号、转速位置、倍频倍率",
             self._page_live),
            ("enc", "编码器信号", "A/B/Z 与 UVW 的等效采样、输出使能、方波可看",
             self._page_enc),
            ("alarm", "告警", "现在是正常还是异常；有锁存就在这里清",
             self._page_alarm),
            ("record", "记录", "开始/停止记录与导出（一帧一行）",
             self._page_record),
            ("capture", "抓包", "抓一段连续的原始 ADC 波形（28672 点，0.57 ms @×1 ～ 4.6 ms @×8）",
             self._page_capture),
            ("diag", "诊断", "设备自检、高级参数、通信日志——排障时才来这一页",
             self._page_diag),
        )
        self._page_titles = {k: t for k, t, _s, _b in builders}
        for key, title, sub, build in builders:
            page = QWidget()
            lay = QVBoxLayout(page)
            # 阶段 3：页面自己给内边距（顶栏已改成"贴边的一条"，外边距收了）
            lay.setContentsMargins(18, 14, 18, 14)
            lay.setSpacing(12)
            lay.addWidget(uk.page_header(title, sub))
            body = build()
            if body is not None:
                lay.addWidget(body, 1)
            sc = QScrollArea()
            sc.setWidgetResizable(True)
            sc.setFrameShape(QFrame.NoFrame)
            # 竖滚动条常驻（免得出现/消失时整页横移一格）；横滚动条关掉
            sc.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
            sc.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
            sc.setWidget(page)
            self._scrolls[key] = sc
            self._page_index[key] = self.pages.addWidget(sc)
        self._right.addWidget(self.pages, 1)
        # 兼容：老代码/自检里的 `w.scroll` 指的是"当前页的滚动区"
        self.scroll = self._scrolls["live"]
        self._setup_shell()
        self.show_page("overview")

    def show_page(self, key):
        """切到某一页（侧栏高亮同步；信号只发给需要知道的人）。"""
        idx = self._page_index.get(key)
        if idx is None:
            return False
        self.pages.setCurrentIndex(idx)
        self.scroll = self._scrolls[key]
        self.scroll.verticalScrollBar().setValue(0)
        self.sidebar.set_page(key)
        self._page_key = key
        return True

    def _on_page_changed(self, key):
        self.show_page(key)
        self.statusBar().showMessage(
            "已切到「%s」页" % self._page_titles.get(key, key), 1500)

    def _page_key_now(self):
        return getattr(self, "_page_key", "overview")

    def _page_overview(self):
        """概览：只放结论行，不放原始数字墙（要看细节点进对应页）。"""
        self.overview = ov.OverviewPage()
        self.overview.jump_requested.connect(self.show_page)
        return self.overview

    def _page_live(self):
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        lay.addWidget(self.card_live)
        row = QHBoxLayout()
        row.setSpacing(12)
        row.addWidget(self.speed, 4)
        row.addWidget(self.interp, 6)
        lay.addLayout(row)
        lay.addWidget(self.wave, 1)
        lay.addWidget(self.quality)
        return box

    def _page_enc(self):
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        lay.addWidget(self.abz, 1)
        return box

    def _page_alarm(self):
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        lay.addWidget(self.alarm, 1)
        return box

    def _page_record(self):
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        lay.addWidget(self.record, 1)
        return box

    def _page_capture(self):
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        lay.addWidget(self.capture, 1)
        return box

    def _page_diag(self):
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)
        row = QHBoxLayout()
        row.setSpacing(12)
        row.addWidget(self.card_device, 1)
        row.addWidget(self.card_link, 1)
        lay.addLayout(row)
        # 门限 / 迟滞 / Z 脉宽 / 极性：低频配置，收进诊断页（告警页只留"看状态 + 清锁存"）
        adv = self.interp.take_adv_box()
        if adv is not None:
            # ★ 从 ⑨ 卡上摘下来的这一块，在诊断页里也得有张"卡"托着，否则它看起来像
            #   谁掉在地上的一堆控件（阶段 2 目视走查发现：没有标题、没有边框）
            adv_card, adv_lay = uk.make_card("高级参数（门限 / 迟滞 / 限频 / Z 脉宽 / 极性）")
            adv_lay.addWidget(adv)
            self.adv_card = adv_card
            lay.addWidget(adv_card)
        lay.addWidget(self.health)
        lay.addWidget(self.lut)
        lay.addWidget(self.board_status)
        lay.addWidget(self.log_card, 1)
        return box

    # ------------------------------------------- 卡片清单 + 快捷键
    def _setup_shell(self):
        """收集卡片清单（自检要按卡片点名），装好快捷键。

        阶段 2（R17）取消了卡片级「⛶ 放大」：一页只服务一件事，不再需要把
        单张卡片撑满窗口；随之退场的还有 Esc 还原、PgUp/PgDn 换卡片。
        """
        self._cards = []
        for _key, sc in self._scrolls.items():
            page = sc.widget()
            self._cards.extend(c for c in page.findChildren(QFrame)
                               if c.objectName() == "Card")
        self._full_saved = None              # R10：进全屏前的窗口状态
        self._setup_keys()                   # 方向键挡位、翻页、全屏

    # ------------------------- 键盘快捷键（R9②/R10；阶段 2 起兼任翻页）
    # ------------------------------------------------- 阶段 5（B 批）字号自适应
    def _target_scale(self):
        """目标缩放系数：手动覆盖优先，否则跟随窗口（1600×900 = 1.0×）。"""
        if self._scale_pref > 0:
            return uf.clamp_scale(self._scale_pref)
        return uf.auto_scale(self.width(), self.height())

    def _apply_scale(self, scale, force=False):
        """套用缩放：样式表 → 应用默认字号 → 侧栏宽度 → 提示标签高度 → tnum。

        ★ 顺序不能换：`setStyleSheet()` 会把控件字体特性（tnum）重置掉，样式表落定
          之后必须再扫一遍；`fix_lines()` 的高度是按字号量出来的，也要按新字号重算，
          否则提示文字多占一行就被切掉。
        """
        scale = uf.clamp_scale(scale)
        if not force and self._applied_scale is not None \
                and abs(scale - self._applied_scale) < 0.02:
            return
        self._applied_scale = scale
        uf.set_scale(scale)
        app = QApplication.instance()
        if app is not None:
            app.setStyleSheet(th.app_qss(scale))
        uf.apply(app, px=uf.BASE_PX * scale)
        try:
            self.sidebar.setFixedWidth(int(round(uk.SIDEBAR_W * scale)))
        except Exception:                                         # noqa: BLE001
            pass
        uk.refresh_fixed_lines(self)
        # ★ 样式表是"全局"的：任何一个窗口重套样式表，都会重置**所有**窗口里读数标签的
        #   字体特性 ⇒ tnum 的恢复也必须全局做。只修自己会让"先建好的那个窗口"悄悄丢掉
        #   等宽数字（自检里新开一个窗口量版面时正好踩到）。
        wins = [self]
        if app is not None:
            wins = [win for win in app.topLevelWidgets()
                    if isinstance(win, MainWindow)] or [self]
        self._tabular_labels = 0
        for win in wins:
            uk.refresh_fixed_lines(win)
            self._tabular_labels += uf.apply_tabular(win)

    def _on_scale_timer(self):
        self._apply_scale(self._target_scale())

    def _scale_nudge(self, delta):
        """Ctrl+= / Ctrl+- ：手动放大/缩小字号（覆盖自动跟随，记进 ui_prefs）。"""
        cur = self._applied_scale if self._applied_scale else self._target_scale()
        self._scale_pref = uf.clamp_scale(cur + delta)
        up.put("ui", "scale", round(self._scale_pref, 3))
        self._apply_scale(self._scale_pref, force=True)
        self.statusBar().showMessage(
            "界面字号 %.0f%%（Ctrl+0 回到跟随窗口）" % (self._scale_pref * 100), 2000)

    def _scale_reset(self):
        """Ctrl+0：回到"跟随窗口"（自动）。"""
        self._scale_pref = 0.0
        up.put("ui", "scale", 0)
        self._apply_scale(self._target_scale(), force=True)
        self.statusBar().showMessage(
            "界面字号跟随窗口（%.0f%%）" % ((self._applied_scale or 1.0) * 100), 2000)

    def resizeEvent(self, ev):
        """窗口尺寸变了 ⇒ 延迟重算字号（0ms 定时器合并连续 resize，避免每帧重套样式表）。"""
        super().resizeEvent(ev)
        if self._scale_pref <= 0 and getattr(self, "_scale_timer", None) is not None:
            self._scale_timer.start()

    def _setup_keys(self):
        """方向键 = 挡位步进（Shift 微调）；Ctrl+1..6 = 翻页；F/F11 = 全屏。

        ★ 只在"没有文本框/数字框拿到焦点"时生效（否则方向键得留给它们改值），
          所以用 `focusChanged` 动态开关，而不是在槽里"假装没看见"把按键吞掉。
        """
        K = QKeySequence
        self._kbd_keys = []
        bind = ((K(Qt.Key_Left), lambda: self._kbd_step_x(-1, False)),
                (K(Qt.Key_Right), lambda: self._kbd_step_x(+1, False)),
                (K("Shift+Left"), lambda: self._kbd_step_x(-1, True)),
                (K("Shift+Right"), lambda: self._kbd_step_x(+1, True)),
                (K(Qt.Key_Up), lambda: self._kbd_step_y(+1, False)),
                (K(Qt.Key_Down), lambda: self._kbd_step_y(-1, False)),
                (K("Shift+Up"), lambda: self._kbd_step_y(+1, True)),
                (K("Shift+Down"), lambda: self._kbd_step_y(-1, True)),
                (K("R"), self._kbd_reset),
                (K("Space"), self._kbd_pause),
                (K("E"), self._kbd_export),
                (K("F"), self._toggle_fullscreen),
                (K(Qt.Key_F11), self._toggle_fullscreen),
                # 阶段 5（B 批）：字号自适应的手动覆盖
                (K("Ctrl+="), lambda: self._scale_nudge(+0.1)),
                (K("Ctrl++"), lambda: self._scale_nudge(+0.1)),
                (K("Ctrl+-"), lambda: self._scale_nudge(-0.1)),
                (K("Ctrl+0"), self._scale_reset))
        # 阶段 2（R17）：卡片级「⛶ 放大」取消 ⇒ PgUp/PgDn 与 Ctrl+←/→ 换成翻页
        for i, key in enumerate(("overview", "live", "enc", "alarm", "record",
                                 "capture", "diag"), 1):
            bind = bind + ((K("Ctrl+%d" % i),
                            lambda k=key: self._on_page_changed(k)),)
        for key, slot in bind:
            sc = QShortcut(key, self)
            sc.setContext(Qt.WindowShortcut)
            sc.activated.connect(slot)
            self._kbd_keys.append(sc)
        app = QApplication.instance()
        if app is not None:
            app.focusChanged.connect(self._on_focus_changed)

    def _on_focus_changed(self, _old, now):
        """焦点在输入控件里时关掉方向键/空格快捷键，把按键让给它。"""
        busy = isinstance(now, (QLineEdit, QAbstractSpinBox, QPlainTextEdit, QTextEdit))
        for sc in self._kbd_keys:
            sc.setEnabled(not busy)

    def _kbd_panel(self):
        """快捷键作用的面板：跟着"当前页"走。

        阶段 2 起不再有卡片放大：编码器信号页用方向键调 ⑨ 的角度窗口/间距，
        其余页调 ⑧ 的时基/幅值（状态栏会写清调了什么，免得不知道键落到哪张卡上）。
        """
        return self.abz if self._page_key_now() == "enc" else self.wave

    def _kbd_note(self, panel, what):
        """方向键本来就无声：把"刚刚调成什么了"写到状态栏，否则用户会以为键坏了。"""
        view = panel.scope_view() or {}
        self.statusBar().showMessage("%s：%s" % (what, view.get("text", "")), 1500)

    def _kbd_step_x(self, delta, fine):
        p = self._kbd_panel()
        p.step_x(delta, fine)
        self._kbd_note(p, "角度窗口" if p is self.abz else "时基")

    def _kbd_step_y(self, delta, fine):
        p = self._kbd_panel()
        p.step_y(delta, fine)
        self._kbd_note(p, "通道间距" if p is self.abz else "幅值")

    def _kbd_reset(self):
        p = self._kbd_panel()
        p.reset_auto()
        self.statusBar().showMessage("已恢复自动量程", 1500)

    def _kbd_pause(self):
        self._kbd_panel().kbd_pause()

    def _kbd_export(self):
        self._kbd_panel().kbd_export()

    def _toggle_fullscreen(self):
        """R10：F / F11 = 真·全屏（进之前记住窗口状态，退出时原样回去）。"""
        if self.isFullScreen():
            self.showMaximized() if self._full_saved else self.showNormal()
            self._full_saved = None
            self.statusBar().showMessage("已退出全屏", 1500)
        else:
            self._full_saved = bool(self.isMaximized())
            self.showFullScreen()
            self.statusBar().showMessage("全屏中：再按 F 或 F11 退出", 3000)

    @staticmethod
    def _card_title(card):
        for lab in card.findChildren(QLabel):
            if lab.objectName() == "CardTitle":
                return lab.text()
        return "卡片"

    def _card_device(self):
        card, lay = uk.make_card("设备信息", "连上后自动读一次，也可以随时点“设备自检”重读。")
        card.setMinimumWidth(300)
        self.v_device = uk.field(lay, "设备型号", "—")
        self.v_rev = uk.field(lay, "版本 REV", "—")
        self.v_build = uk.field(lay, "固件构建", "—")
        self.lab_check = QLabel("尚未自检")
        self.lab_check.setObjectName("Hint")
        self.lab_check.setWordWrap(True)
        uk.fix_lines(self.lab_check, 2)
        lay.addWidget(self.lab_check)
        lay.addStretch(1)
        return card

    def _card_link(self):
        card, lay = uk.make_card(
            "通信统计", "板子遥测常开：10 kHz × 18 字节 ≈ 180 kB/s，占 2 Mbaud 链路的 90%。")
        card.setMinimumWidth(300)
        self.v_fps = uk.field(lay, "帧率", "0 帧/秒")
        self.v_bps = uk.field(lay, "数据率", "0 kB/s")
        self.v_crc = uk.field(lay, "校验错", "0")
        self.v_lost = uk.field(lay, "丢批/丢帧", "0 / 0")
        # R20（批次 5）：帧率/数据率/校验错比例是瞬时量，末位会跳 ⇒ 显示层稳定化
        self.st_fps = uk.Stable("fps")
        self.st_bps = uk.Stable("bps_k")
        self.st_crcp = uk.Stable("crc_pct")
        lay.addStretch(1)
        return card

    def _card_live(self):
        card, lay = uk.make_card("实时数据预览", "最新一帧的原始读数；波形见下方。")
        card.setMinimumWidth(400)
        self.v_angle = uk.field(lay, "电角度", "—")
        # 板上角度字比采样时刻晚 τ（实测 0.32 µs），按转速补回来。默认开：
        #   补偿前 6.3″、补偿后 0.01″（913 rpm，见 docs/42 §22）。
        row_tau = QHBoxLayout()
        row_tau.setSpacing(6)
        self.chk_tau = QCheckBox("延时补偿")
        self.chk_tau.setChecked(True)
        self.chk_tau.setProperty("switch", "true")
        self.chk_tau.setToolTip(
            "板上角度字比真正的采样时刻晚 τ ≈ 0.32 µs（12.5 MSPS 下 4 个采样周期）。\n"
            "补偿用 θ + 360·f·τ，只改显示，不改板、不改记录。\n"
            "关掉就是板上原始角度。")
        row_tau.addWidget(self.chk_tau)
        # τ 可调：不同位流/滤波配置下这个值会变，调的时候盯「补偿后电角度」。
        self.sp_tau = QDoubleSpinBox()
        self.sp_tau.setRange(0.0, 5.0)
        self.sp_tau.setDecimals(2)
        self.sp_tau.setSingleStep(0.02)
        self.sp_tau.setSuffix(" µs")
        self.sp_tau.setFixedWidth(88)
        try:
            _tau0 = float(up.raw("data", "tau_us", 0.32))
        except (TypeError, ValueError):
            _tau0 = 0.32
        self.sp_tau.setValue(_tau0)
        self.sp_tau.setToolTip(
            "板上角度字的流水线延时 τ。\n"
            "补偿公式 θ_corr = θ_meas + 360·f·τ。\n"
            "上板实测 0.32 µs（12.5 MSPS 下 4 个采样周期）；"
            "913 rpm 时残差从 6.3″ 降到 0.01″。")
        self.sp_tau.valueChanged.connect(self._on_tau)
        self._tau_us = _tau0
        row_tau.addWidget(self.sp_tau)
        row_tau.addStretch(1)
        lay.addLayout(row_tau)
        self.v_ang_fix = uk.field(lay, "补偿后电角度", "—")
        self.v_pos = uk.field(lay, "多周期位置", "—")
        self.v_sc = uk.field(lay, "正余弦 s/c", "—")
        self.v_r = uk.field(lay, "幅值 r", "—")
        # R20：幅值 r 走稳定显示（电角度/位置本身就在走，不套）
        self.st_r = uk.Stable("amp_r")

        chip_row = QHBoxLayout()
        chip_row.setSpacing(6)
        self.chips = {}
        for key, name in (("a", "A"), ("b", "B"), ("z", "Z"),
                          ("u", "U"), ("v", "V"), ("w", "W")):
            lab = QLabel("%s –" % name)
            lab.setAlignment(Qt.AlignCenter)
            lab.setMinimumWidth(46)
            uk.paint_chip(lab, None)
            self.chips[key] = lab
            chip_row.addWidget(lab)
        chip_row.addStretch(1)
        lay.addLayout(chip_row)

        self.v_dir = uk.field(lay, "方向 / 限幅", "—", mono=False)
        self.v_flags = uk.field(lay, "状态位 flags", "—", mono=False)
        # ★ 用户反馈：限频一旦锁存，解除很麻烦（要跑去「告警」页）。锁存位在
        #   0x0405（W1C，写 1 清），这里就地给一个按钮，点一下就清。
        row_fl = QHBoxLayout()
        row_fl.setSpacing(6)
        row_fl.addStretch(1)
        self.btn_clr_latch = QPushButton("清锁存")
        self.btn_clr_latch.setToolTip(
            "清 0x0405 的锁存位（W1C，写 1 清）。\n"
            "只清\"曾经发生过\"的记录，不会改变当前状态；\n"
            "如果 3 秒内又亮，说明条件还在（比如 AB 限频被压住），要改配置而不是反复清。")
        self.btn_clr_latch.clicked.connect(self._on_clear_latch)
        row_fl.addWidget(self.btn_clr_latch)
        lay.addLayout(row_fl)
        lay.addStretch(1)
        return card

    # --------------------------------------------------------------- 日志
    def _install_wheel_router(self):
        """在 QApplication 上装事件过滤器 ⇒ 鼠标停在哪都能用滚轮滚页面。

        为什么要在应用级拦：滚轮事件是发给"鼠标底下那个控件"的，卡片里的
        matplotlib 画布 / 下拉框 / 数字框会各自吃掉它（数字框还会被滚轮悄悄改值），
        所以主窗口的 QScrollArea 收不到。统一在应用级转成滚动区的像素滚动最干净。
        """
        app = QApplication.instance()
        if app is not None:
            app.installEventFilter(self)

    def eventFilter(self, obj, ev):                 # noqa: N802
        if ev.type() == QEvent.Wheel and self._wheel_is_ours(obj):
            try:
                return self._route_wheel(obj, ev)
            except Exception:                       # noqa: BLE001
                return False                        # 出错就退回 Qt 默认行为
        return super().eventFilter(obj, ev)

    def _wheel_is_ours(self, obj):
        """只管本窗口里的控件（下拉框弹出层是独立顶层窗口 ⇒ 交给 Qt 自己滚）。"""
        if not isinstance(obj, QWidget):
            return False
        return obj is self or self.isAncestorOf(obj)

    def _wheel_owner(self, obj):
        """该控件（或其祖先）是否要自己处理滚轮（白名单：日志框等）。"""
        w = obj if isinstance(obj, QWidget) else None
        while w is not None:
            if w.property("wheelOwn"):
                return True
            w = w.parentWidget()
        return False

    def _wheel_zoom_target(self, obj):
        """Ctrl+滚轮缩放的图表（批次 3 给图表设 `wheelZoom` 属性后接上）。"""
        w = obj if isinstance(obj, QWidget) else None
        while w is not None:
            if w.property("wheelZoom"):
                return w
            w = w.parentWidget()
        return None

    def _route_wheel(self, obj, ev):
        if self._wheel_owner(obj):
            return False                            # 白名单：让它自己滚
        target = self._wheel_zoom_target(obj)
        # 阶段 2 起没有"放大态"：普通页上只有 Ctrl+滚轮归图表，裸滚轮滚页面
        if target is not None and (ev.modifiers() & Qt.ControlModifier):
            return False
        dy = ev.angleDelta().y()
        px = dy * WHEEL_PX_PER_UNIT if dy else float(ev.pixelDelta().y())
        if not px:
            return False
        self._scroll_page(-px)
        return True                                 # 吃掉：数字框/下拉框不许改值

    def _scroll_page(self, px):
        """滚页面 px 个像素（返回实际滚动的像素数，自检要用）。"""
        bar = self.scroll.verticalScrollBar()
        before = bar.value()
        bar.setValue(int(round(before + float(px))))
        return bar.value() - before

    # ----------------------------------------------------------- 端口列表
    def refresh_ports(self):
        cur = self._current_port()
        found = pm.list_serial_ports()
        self.combo_port.clear()
        for device, desc, hwid in found:
            mark = " ★" if pm.looks_like_board(device, desc, hwid) else ""
            self.combo_port.addItem("%s%s" % (pm.format_port(device, desc), mark), device)
        if not found:
            self.combo_port.addItem("（没发现串口）", None)
        if cur:                                     # 尽量保住用户当前的选择
            idx = self.combo_port.findData(cur)
            if idx >= 0:
                self.combo_port.setCurrentIndex(idx)
            else:
                self.combo_port.setEditText(cur)
        # ★ 阶段 3（真机走查抓到）：可编辑下拉框在窄屏 / 高 DPI 下文本会溢出，
        #   而光标停在末尾 ⇒ 显示被"滚动"到尾巴上，"COM3 — …" 开头的 C 看不见了。
        #   端口名开头那几个字符才是人要看的东西，所以把光标拨回行首。
        _le = self.combo_port.lineEdit()
        if _le is not None:
            _le.setCursorPosition(0)
        self.log_line("刷新端口：%s"
                      % ("、".join(pm.format_port(d, s) for d, s, _ in found) or "无"))

    def _current_port(self):
        data = self.combo_port.currentData()
        if data:
            return data
        text = self.combo_port.currentText().strip()
        if not text or text.startswith("（"):
            return None
        return text.split()[0].split("—")[0].strip()

    # --------------------------------------------------------- 连接/断开
    def _on_connect(self):
        if self.worker is not None:
            self.disconnect_port()
        else:
            self.connect_to(self._current_port())

    def connect_to(self, port):
        if self.worker is not None or not port:
            if not port:
                self.log_line("!! 没选端口", "warn")
            return
        # ★ 换端口/重连前先把上一段的残留清掉（设备信息、卡片读数、累积数据）：
        # 否则新端口配着旧设备的身份证，导出图上的标注也会自相矛盾
        self._reset_live()
        self.worker = lk.SerialWorker(port, baud=lk.BAUD_DEFAULT, batch_ms=50.0)
        self.worker.start()
        self.btn_connect.setText("断开")
        self._set_state("连接中…", C["warn"])
        self._stat_t = None
        self._counters = None
        self._acc_lost = 0
        self._acc_drop = 0
        self.speed.reset()
        self.interp.update_f_in(None)
        self._refresh_buttons()

    def _auto_start_record(self):
        """"连上就自动开始记录"的延迟回调。

        ★ 900 ms 内可能已经断开（拔线、点断开、开窗即退）：那时再开表就会建出一个
        只有表头的空 CSV，还显示"记录中"。
        """
        if self.worker is None:
            return
        self.record.start_record()

    def _drain_events(self, w):
        """断开/退出前把事件队列排空 —— 队列里剩下的帧必须进 CSV。

        ★ 2 Mbaud 下链路每 50 ms 推一批（≈500 帧），而 _tick 是 100 ms 一轮、
        单轮上限 40 条：稳态下队列里恒定压着 1～2 批。断开时若直接 stop() 再丢
        worker，这些帧就永远进不了记录文件（实测每次退出丢 2500～20000 帧）。
        这里取到队列空为止，顺便把最后的 counters 收下来结账。
        """
        if w is None:
            return 0
        bad0 = self._acc_lost
        drop0 = self._acc_drop
        got = lc.drain_events(w)
        taken = got["taken"]
        new_frames = got["frames"]
        if new_frames:
            self._stat_frames += len(new_frames)
            self._frames_total += len(new_frames)
        if got["counters"] is not None:
            self._counters = got["counters"]
        if got["last_frame"] is not None:
            self.last_frame = got["last_frame"]
        n_bad = max(0, self._lost_frames() - bad0)
        n_drop = max(0, int((self._counters or {}).get("dropped_frames", 0)) - drop0)
        self._acc_lost = self._lost_frames()
        self._acc_drop = int((self._counters or {}).get("dropped_frames", 0))
        if new_frames or n_bad or n_drop:
            # ★ 审计 2 #8：一次退出可能排空上万帧，单次 feed 在 GUI 线程写 CSV 会冻结数秒。
            #   按 4000 帧一批喂，批间让事件循环喘口气（记数只在首/末批各带一次）。
            if not new_frames:
                self.record.feed([], n_bad=n_bad, n_drop=n_drop)
            else:
                for i in range(0, len(new_frames), lc.BATCH_FEED):
                    part = new_frames[i:i + lc.BATCH_FEED]
                    self.record.feed(part,
                                     n_bad=n_bad if i == 0 else 0,
                                     n_drop=n_drop if i + lc.BATCH_FEED >= len(new_frames) else 0)
        if new_frames:
            # 界面上也让它显示完整（断开后马上会被 _reset_live 清掉，这里只为不露半截）
            self.speed.feed(new_frames, n_bad=n_bad)
        return taken

    def disconnect_port(self):
        if self._stream is not None:
            # 断开串口后接收线程/socket/刷新定时器还会跑，界面一直显示"连续流运行中"
            self._stop_stream()
        # ★ 断开时把网口状态一并清干净，否则重连后 _src 还停在 net、_stream 却是空的，
        #   刷新分支会把下拉框踢回串口（"网口再也连不上"就是这么来的）。
        try:
            self._net_off("串口已断开")
        except Exception:                                     # noqa: BLE001
            pass
        self._net_want = False
        self._net_retry_n = 0
        w, self.worker = self.worker, None
        # 复查 P7：断开时清掉忙碌标志，否则迟到任务不返回，重连后整块界面一直是灰的
        self.busy = False
        self._status_busy = False
        if w is not None:
            # ★ 先停线程、再排空队列：线程停了队列就不再增长，排空一次就能收干净。
            #   反过来的顺序（先排空、再 stop）在"排空返回空 → stop 生效"之间线程还会
            #   推进来 1~2 批（≈1000 帧），那几批就永远留在队列里没人写（真机核对照过：
            #   关窗后队列 2 条 → 3 条）。stop() 内部会 join，返回后队列是静止的。
            w.stop()
            self._drain_events(w)
        self.btn_connect.setText("连接")
        self._set_state("未连接", C["muted"])
        self.last_frame = None
        self._reset_live()
        self.speed.reset()
        self.interp.update_f_in(None)
        self._refresh_buttons()
        self.log_line("已断开")

    def _set_state(self, text, color):
        self.lab_state.setText(text)
        self.lab_state.setStyleSheet("color:%s;" % color)

    def _refresh_buttons(self):
        """连通性 + 忙碌状态 → 决定哪些按钮可点。"""
        conn = self.worker is not None
        enabled = conn and not self.busy
        self.btn_check.setEnabled(enabled)
        self.speed.set_connected(conn, enabled)
        self.interp.set_connected(conn, enabled)
        self.alarm.set_connected(conn, enabled)
        self.wave.set_connected(conn, enabled)
        self.abz.set_connected(conn, enabled)
        self.record.set_connected(conn, enabled)
        self.capture.set_connected(conn)
        if self._wave_win is not None:          # ⑧ 独立窗口跟着一起禁用/启用
            self._wave_win.set_connected(conn, enabled)
        if self._abz_win is not None:           # ⑨ 独立窗口同理
            self._abz_win.set_connected(conn, enabled)

    def _open_wave_popup(self):
        """⑧ 的独立大窗口（阶段 5 C 批，用户 m15713 第 9 条）。

        复用第二个 `panel_wave.WavePanel`：触发源/时基/幅值/叠加分离/恢复自动/暂停/
        导出当前视图全部与主界面同源；弹窗关闭后实例留着（`_wave_win`），再打开时
        沿用上次的量程。
        """
        if self._wave_win is None:
            self._wave_win = wvp.WavePopup(self, capacity=self.wave.buf.capacity)
            self._wave_win.panel.export_view_requested.connect(
                lambda: self._on_export("wave_view", self._wave_win.panel))
            self._wave_win.panel.set_f_in(self._f_in)
            self._wave_win.panel.set_status(self.wave.status)
            self._wave_win.panel.set_connected(self.worker is not None,
                                               self.worker is not None and not self.busy)
        self._wave_win.show()
        self._wave_win.raise_()
        self._wave_win.activateWindow()
        self._log_notice("已打开「输入信号波形」独立窗口；关掉它不影响主界面。", "info")

    def _open_abz_popup(self):
        """⑨ 的独立大窗口（阶段 5 续，用户追加要求）。

        复用第二个 `panel_abz.AbzPanel`：分箱/横轴窗口/通道排布/间距/方波可看/还原/
        清空累积/导出当前视图全部与主界面同源。**板上事实**（inter/div、0x0109 输出位、
        输入频率）每帧由 `mirror()` 同步过来；**视图设置各窗口独立**，在大窗口里放大看
        细节不会改掉主界面的量程。
        """
        if self._abz_win is None:
            self._abz_win = azp.AbzPopup(self, bins=self.abz.bins())
            p = self._abz_win.panel
            p.export_view_requested.connect(lambda: self._on_export("abz_view", p))
            p.output_requested.connect(self._on_set_output)          # 弹窗里的「一键使能」照样读写板上
            p.square_requested.connect(self._on_square_preset)
            p.square_restore_requested.connect(self._on_square_restore)
            p.notice.connect(self._log_notice)
            p.mirror(self.abz)                                        # 先对齐板上事实
            p.set_connected(self.worker is not None,
                            self.worker is not None and not self.busy)
        self._abz_win.show()
        self._abz_win.raise_()
        self._abz_win.activateWindow()
        self._log_notice("已打开「ABZ / UVW 等效采样」独立窗口；关掉它不影响主界面。", "info")

    def _sync_abz_bins(self, bins):
        """「方波可看 / 还原」是**明确要求两个窗口都换成同一分箱**的操作（用户要看的正是方波）。

        与 `mirror()` 的分工：那边的视图设置各窗口独立，这里属于"用户一键配置"，
        主界面配好了、大窗口就该跟着配好，否则弹窗里还是阶梯，让人以为没生效。
        """
        if self._abz_win is not None:
            self._abz_win.set_bins(bins)

    def _set_busy(self, busy):
        self.busy = bool(busy)
        self._refresh_buttons()

    def _reset_live(self):
        for v in (self.v_angle, self.v_pos, self.v_sc, self.v_r, self.v_dir,
                  self.v_flags, self.v_fps, self.v_bps, self.v_crc):
            v.setText("—")
            v.setToolTip("")
        for st in (self.st_fps, self.st_bps, self.st_crcp, self.st_r):
            st.reset()
        for key, lab in self.chips.items():
            lab.setText("%s –" % key.upper())
            uk.paint_chip(lab, None)
        self.v_fps.setText("0 帧/秒")
        self.v_bps.setText("0 kB/s")
        self.v_crc.setText("0")
        self.v_lost.setText("0 / 0")
        self.alarm.reset()
        self.wave.reset()
        self.quality.reset()
        self.board_status.clear()
        self.abz.reset()
        self.interp.reset()
        self.record.reset()
        # ★ 设备信息卡片也要清：重连/换端口后还挂着上一个设备的身份证，
        # 界面与导出图顶部的标注就会自相矛盾（审计发现）
        for lab in (self.v_device, self.v_rev, self.v_build):
            lab.setText("—")
        self.lab_check.setText("尚未自检")
        self.info = None
        self._counters = None
        self._acc_lost = 0
        self._acc_drop = 0
        self._status_t = 0.0
        self._status_sig = None     # 重连后第一次读到的状态仍按「信息」打一条
        self._sq_saved = None       # 「方波可看」的暂存值随断开一起清（板子可能换了）
        self._sb_lab.setText("已运行 —")
        self._refresh_overview()    # 概览页也回到"待数据"

    # --------------------------------------------------------- R20 显示口径
    def _on_toggle_raw(self, on):
        """勾/去勾「原始值」：立刻按新口径重画读数（不用等下一次刷新）。"""
        uk.set_raw_mode(on)
        up.put("display", "raw", bool(on))
        self._refresh_readouts()
        self.log_line("读数显示：%s" % ("原始值（末位会跳，便于核对）" if on else
                                      "稳定显示（按分辨力取整，悬停看原始值）"))

    def _refresh_readouts(self):
        """按当前显示口径把六张卡片的读数各重画一遍（不碰数据通路）。"""
        if self.last_frame is not None:
            self._update_live(self.last_frame)
        for panel in (self.speed, self.alarm, self.interp, self.abz,
                      self.wave, self.record):
            panel.refresh_readouts()

    # ------------------------------------------------------------ 设备自检
    def _export_meta(self):
        """图顶部的说明文字：端口/设备/固件/频率/倍频/方向 —— 图离开界面也能自证。"""
        cfg = cfg_from_regs(getattr(self.interp, "regs_raw", {}) or {}) or {}
        bits = []
        port = self._current_port()
        if port:
            bits.append("端口 %s" % port)
        dev = (self.v_device.text() or "").strip()
        if dev and dev != "—":
            bits.append("设备 %s" % dev.strip("✓ "))
        rev = (self.v_rev.text() or "").strip()
        if rev and rev != "—":
            bits.append("固件 %s" % rev)
        f_in = self._f_in
        line1 = "　".join(bits) if bits else "未连接（离线查看最后一批数据）"
        line2 = []
        if f_in:
            line2.append("输入频率 %.1f Hz" % abs(f_in))
        if cfg.get("inter"):
            line2.append("倍频 inter=%d div=%d" % (cfg["inter"], cfg.get("div", 1)))
        if cfg.get("pairs"):
            line2.append("极对数=%d" % cfg["pairs"])
        if self.last_frame is not None:
            d = (self.last_frame.get("io_bits") or {}).get("dir")
            if d is not None:
                line2.append("方向 %s" % ("正转" if d else "反转"))
        meta = {"line1": [line1] + (["　".join(line2)] if line2 else [])}
        # 幅值门限：波形图上要标出"正常/偏低/偏高"的判定依据（来自板上 0x0520/0x0524）
        st = getattr(self.wave, "status", None) or {}
        if st.get("amp_low_sq") and st.get("amp_high_sq"):
            meta["amp_low_sq"] = st["amp_low_sq"]
            meta["amp_high_sq"] = st["amp_high_sq"]
        meta["导出时间"] = time.strftime("%Y-%m-%d %H:%M:%S")
        return meta

    def _on_export(self, kind, panel=None):
        """导出波形/等效采样 PNG（需求 M6）。数据取自各卡片当前的快照，一键成文件。

        kind 可以是 "wave"/"abz"（全貌，像素契约 1950×1080 / 1950×990 不变），
        也可以是 "wave_view"/"abz_view"（按卡片当前量程导出，批次 3）。
        panel 只在"⑧ 独立窗口"里用来指定导出哪个面板（阶段 5 C 批），默认主界面卡片。
        """
        meta = self._export_meta()
        note = ""
        name = ep.suggest_name(kind)
        # ★ 阶段 5 补丁（用户 m16915）：导出也要"先探再写"——记录目录被系统挡住时，
        #   老实现只会甩一句 Errno 13，图就没了。这里先换到能写的目录，并在提示里说明。
        # ★ try 从这里就开始（自查发现）：探目录 / 生成文件名同样可能抛异常。以前它们在
        #   try 之外，异常直接冒进 Qt 槽（模态框），而且 record.finish_export 不会执行
        #   ⇒ 记录卡永远停在上一次的"已导出…"，状态错乱。
        move_note = ""
        path = ""
        try:
            out_dir, moved, why = rc.writable_dir_or_fallback(self.record.dir)
            if moved:
                move_note = "（原目录写不进去，已改存）"
                self.log_line("导出目录 %s 不可写 ⇒ 本次改存到 %s" % (self.record.dir, out_dir),
                              "warn")
            # 同一秒连点两次导出时会撞名：加 -2/-3 后缀而不是悄悄覆盖前一张
            path = ep.unique_path(os.path.join(out_dir, name))
            is_abz = str(kind).startswith("abz")
            view = None
            if str(kind).endswith("_view"):
                pan = panel or (self.abz if is_abz else self.wave)
                view = pan.scope_view() if pan is not None else None
            if is_abz:
                snap = self.abz.analyzer_snapshot()
                theory = self.abz.theory(self._f_in or 0.0) if snap else None
                if snap and snap.get("frames"):
                    note = "已采 %s 帧" % format(snap["frames"], ",")
                info = ep.export_abz_png(path, snap, meta=meta, theory=theory, view=view)
            else:
                src = panel if panel is not None else self.wave
                snap = src.buf.snapshot()
                if snap and snap.get("n"):
                    note = "含 %d 帧、%.0f ms" % (snap["n"],
                                                float(snap.get("span_s") or 0) * 1000.0)
                info = ep.export_wave_png(path, snap, meta=meta, view=view)
        except Exception as exc:                                    # noqa: BLE001
            info = {"ok": False, "path": path or "", "bytes": 0, "px": (0, 0),
                    "error": "导出时出错：%s" % exc}
        self.record.finish_export(kind, info, data_note=note + move_note)

    # ------------------------------------------------------- 定时消费事件
    def closeEvent(self, event):                    # noqa: N802
        # ★ 关窗是"必达"动作（自查发现）：以前 disconnect_port 一旦抛异常，
        #   _save_prefs 与 super().closeEvent 都不执行 ⇒ 点 X 没反应、参数也丢。
        try:
            self.timer.stop()
        except Exception:                           # noqa: BLE001
            pass
        try:
            self.disconnect_port()
        except Exception as exc:                    # noqa: BLE001
            self.log_line("断开串口时出错（照样关窗）：%s" % exc, "warn")
        try:
            app = QApplication.instance()
            if app is not None:                     # 摘掉应用级滚轮过滤器（R1）
                app.removeEventFilter(self)
        except Exception:                           # noqa: BLE001
            pass
        try:
            self.task.shutdown(0.8)                 # 收尾批：单工作线程，别把它留给进程退出
        except Exception:                           # noqa: BLE001
            pass
        if self._stream is not None:
            # 程序退出后板子还在发流：会灌满链路，下一次 ping/UDP 抓包都失败
            try:
                self._stop_stream()
            except Exception:                       # noqa: BLE001
                pass
        self._save_prefs()                          # 内部自带 try/except，不会拦关窗
        super().closeEvent(event)

    def _save_prefs(self):
        """把界面参数落到 host/ui_prefs.json（批次 3）。失败只记日志，不拦关窗。"""
        try:
            # 阶段 2 起没有"单卡放大"状态了，关窗时直接按当前页几何存
            up.put("window", "w", int(self.width()))
            up.put("window", "h", int(self.height()))
            up.put("log", "level", self.log_level)
            up.put("capture", "smooth", int(self.capture.smooth()))
            up.save()
        except Exception as exc:                   # noqa: BLE001
            self.log_line("界面参数没能存下来：%s" % exc, "debug")
