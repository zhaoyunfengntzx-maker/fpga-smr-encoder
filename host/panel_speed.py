"""⑤ 转速与位置卡片（需求 M3）：输入频率 / 机械转速 / 方向 / 累计圈数。

界面只做显示；估算逻辑在 encoder.SpeedEstimator 里（纯逻辑、可离线自检）。
极对数既是显示换算参数，也可以一键写到板上 0x0100（UVW 生成用）。
"""

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QPushButton, QSpinBox, QVBoxLayout

import encoder as enc
import theme as th
import ui_kit as uk

C = th.C


class SpeedPanel(QFrame):
    """转速与位置（M3）。"""

    pairs_write_requested = Signal(int)      # 用户要把极对数写到板上 0x0100

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self.est = enc.SpeedEstimator(pairs=enc.DEFAULT_PAIRS)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 12)
        lay.setSpacing(8)

        head = QLabel("转速与位置")
        head.setObjectName("CardTitle")
        lay.addWidget(head)
        # 静态说明文字：窄窗口会换更多行，用 allow_lines 留余量（动态提示才必须锁死）
        lay.addWidget(uk.allow_lines(uk.hint_label(
            "从遥测帧估算（板子每 100 µs 一帧、1 s 平滑窗）：机械转速 = 60 × 输入频率 ÷ 每转周期数。"
            "这个「每转周期数」就是每转正弦周期数：本机 EI58C9 是 2048，旧磁环 demo 是 64"
            "（填 4 差 512 倍、填 64 差 32 倍，见 docs/20 §12）。"
            "输入频率 =「整数电周期数（位置口径）+ 小数残差（角度口径）」合成，"
            "因此丢帧不影响读数。本版显示的是观察值，不作为计量依据。", lines=4), 4, 7))

        self.v_f = uk.field(lay, "输入频率", "—")
        self.v_rpm = uk.field(lay, "机械转速", "—", value_obj="BigValue", vmin=190)
        self.v_turns = uk.field(lay, "累计圈数", "—")
        self.v_cycles = uk.field(lay, "电周期数", "—")
        self.v_dir = uk.field(lay, "方向", "—", mono=False)

        # R20（批次 5）：输入频率/机械转速是"瞬时量"，末位会随测量噪声跳 ⇒ 走显示层稳定化；
        # 累计圈数/电周期数是单调计数，本来就该在走，不套（spec 表见 ui_kit.READOUT_SPEC）
        self.st_f = uk.Stable("freq_hz")
        self.st_rpm = uk.Stable("rpm")

        row = QHBoxLayout()
        row.setSpacing(6)
        # 标签写"每转周期数"而不是"极对数"：这是 2048 那个数，不是电机极对数 P。
        # 宽度 84 放得下 5 个汉字（7 pt 下约 70 px）。
        row.addWidget(uk.small_label("每转周期数", 84))
        self.sp_pairs = QSpinBox()
        # ★ 上限必须 ≥2048：这个框填的是"每转正弦周期数"，EI58C9 是 2048。
        #   以前限死 32，于是 EI58 只能填 4/32 ⇒ 转速差 512 倍，看着"完全不对"。
        self.sp_pairs.setRange(1, 16384)
        self.sp_pairs.setValue(enc.DEFAULT_PAIRS)
        self.sp_pairs.setToolTip(
            "每转正弦周期数（不是电机极对数 P）\n"
            "机械转速 = 60 × 输入频率 ÷ 这个数\n"
            "EI58C9.25-2048 = 2048（默认）｜旧磁环 demo = 64\n"
            "填 4（0x0100 的复位值，是给 UVW 生成用的电机极对数）会差 512 倍")
        self.sp_pairs.valueChanged.connect(self._on_pairs)
        row.addWidget(self.sp_pairs)
        self.btn_pairs = QPushButton("写到板上")
        self.btn_pairs.setToolTip(
            "把同一个数写进板上 0x0100（会回读确认）\n"
            "★ 0x0100 是**电机极对数 P**，只给板上 UVW 生成用；它和「每转正弦周期数」\n"
            "  是两回事（只有模拟 64 极对磁环时两者才都是 64）。EI58 编码器的 UVW 是关掉的，\n"
            "  所以本机一般不需要点这个按钮。")
        self.btn_pairs.clicked.connect(
            lambda: self.pairs_write_requested.emit(self.sp_pairs.value()))
        row.addWidget(self.btn_pairs)
        row.addStretch(1)
        lay.addLayout(row)

        self.lab_note = uk.hint_label("等待数据…", lines=3)
        lay.addWidget(self.lab_note)
        lay.addStretch(1)
        self.set_connected(False)

    # ------------------------------------------------------------- 外部接口
    def pairs(self):
        return self.sp_pairs.value()

    def set_pairs(self, value):
        """由读回值同步界面（不触发写板）。"""
        if value and self.sp_pairs.value() != int(value):
            self.sp_pairs.setValue(int(value))
        self.est.set_pairs(self.sp_pairs.value())

    def set_connected(self, conn, enabled=None):
        """conn = 串口是否连着；enabled = 现在能不能点（连上且不忙）。"""
        self.btn_pairs.setEnabled(bool(conn if enabled is None else enabled))

    def refresh_readouts(self):
        """R20：按当前显示口径把读数重画一遍（切「原始值」时由主窗口调）。"""
        return self.show_snapshot(self.est.snapshot())

    def reset(self):
        """断开/重连时清空。"""
        self.est.reset()
        for v in (self.v_f, self.v_rpm, self.v_turns, self.v_cycles, self.v_dir):
            v.setText("—")
            v.setToolTip("")
        for st in (self.st_f, self.st_rpm):
            st.reset()
        self.lab_note.setText("等待数据…")
        self.lab_note.setStyleSheet("")

    def feed(self, frames, t_now=None, n_bad=0):
        """喂一批帧，刷新显示，返回 snapshot。n_bad = 本批校验失败被丢的帧数。"""
        return self.show_snapshot(self.est.feed(frames, t_now, n_bad=n_bad))

    # ------------------------------------------------------------- 显示
    def _on_pairs(self, value):
        self.est.set_pairs(value)

    def show_snapshot(self, s):
        if not s["ok"]:
            # ★ 读数也要清掉：以前只改 note，断线/数据不足时还挂着上一次的转速与圈数，
            #   看着像"还在测"（审计发现）
            for lab in (self.v_f, self.v_rpm, self.v_turns, self.v_cycles, self.v_dir):
                lab.setText("—")
                lab.setToolTip("")
            for st in (self.st_f, self.st_rpm):
                st.reset()
            self.lab_note.setText(s["note"] or "等待数据…")
            self.lab_note.setStyleSheet("")
            return s
        # R20：输入频率与机械转速走稳定显示（悬停看原始值）；圈数/电周期数是单调量，直接显示
        uk.show(self.v_f, self.st_f, s["f_abs"], extra="平滑窗 %.2f s" % s["span"])
        uk.show(self.v_rpm, self.st_rpm, s["rpm_abs"],
                extra="每转 %d 周期" % self.est.pairs)
        # ★ 用户反馈（m15813）：累计圈数 / 电周期数只显示到小数点后一位（量够大，多的小数没用）
        self.v_turns.setText("%.1f 圈" % s["turns"])
        self.v_cycles.setText("%.1f" % s["cycles"])
        self.v_dir.setText(s["direction"] or "—")

        msgs = []
        if s["warn"]:
            msgs.append("⚠ " + s["warn"])
        if s["note"]:
            msgs.append(s["note"])
        msgs.append("平滑窗 %.2f s" % s["span"])
        self.lab_note.setText("　".join(msgs))
        self.lab_note.setStyleSheet(
            "color:%s;" % (C["warn"] if s["warn"] else C["muted"]))
        return s
