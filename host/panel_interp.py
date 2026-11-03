"""⑥ 倍频倍率卡片（需求 M2）：inter / div 可改 + 高级参数（迟滞/限频/相位/极性）。

要点（都来自 rtl/，别凭直觉改）
------------------------------
* inter（2…256，写 0 视为 256）和 div（1…8）**跨两个寄存器**：
  inter = {0x0102[1:0], 0x0101[7:0]}，div = 0x0102[4:2] + 1。
  所以“应用”要依次写 0x0101、0x0102，然后回读 0x0101/0x0102 比对。
* 等效倍率 = inter/div；AB 边沿率 = 4 × inter/div × 输入频率（A/B 合计跳变）。
* 高级区一律读-改-写：像 0x0108 板上实测是 0x4004，直接覆盖会毁掉别的位。
"""

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (QCheckBox, QFrame, QGridLayout, QHBoxLayout, QLabel,
                               QPushButton, QSpinBox, QVBoxLayout, QWidget)

import regs
import theme as th
import ui_kit as uk

C = th.C

PRESETS = (8, 16, 32, 64, 128, 256)


class InterpPanel(QFrame):
    """倍频倍率（M2）。"""

    apply_requested = Signal(object)          # {"inter":int, "div":int}
    advanced_requested = Signal(object)       # {地址: 写入值}（已做读-改-写）
    adv_blocked = Signal()                    # 没读回板上现值就想应用高级参数
    adv_page_requested = Signal()             # 阶段 2：高级参数已搬到「诊断」页

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self.regs_raw = {}
        self.f_in = None
        self._adv_spins = {}
        self._adv_checks = {}

        lay = QVBoxLayout(self)
        self._lay = lay
        lay.setContentsMargins(14, 10, 14, 12)
        lay.setSpacing(8)

        head = QLabel("倍频倍率")
        head.setObjectName("CardTitle")
        lay.addWidget(head)
        lay.addWidget(uk.hint_label(
            "inter 是细分倍数（2…256），div 是后分频（1…8）：等效倍率 = inter ÷ div。"
            "AB 每个输入周期出 4×inter 个边沿，div 再抽取 ⇒ 边沿率 = 4 × inter/div × 输入频率。",
            lines=3))

        # ---------- 常用倍率预设 ----------
        pre = QHBoxLayout()
        pre.setSpacing(6)
        pre.addWidget(uk.small_label("常用倍率", 84))
        for p in PRESETS:
            b = QPushButton("×%d" % p)
            b.setToolTip("设成 inter=%d、div=1" % p)
            b.clicked.connect(lambda _=False, v=p: self._set_preset(v))
            pre.addWidget(b)
        pre.addStretch(1)
        lay.addLayout(pre)

        # ---------- inter / div + 应用 ----------
        row = QHBoxLayout()
        row.setSpacing(6)
        row.addWidget(uk.small_label("inter 细分", 84))
        self.sp_inter = QSpinBox()
        self.sp_inter.setRange(regs.INTER_MIN, regs.INTER_MAX)
        self.sp_inter.setValue(64)
        self.sp_inter.setToolTip("2…256（写 0 板上按 256 处理）")
        self.sp_inter.valueChanged.connect(self._refresh_math)
        row.addWidget(self.sp_inter)
        row.addWidget(uk.small_label("div 后分频", 92))
        self.sp_div = QSpinBox()
        self.sp_div.setRange(regs.DIV_MIN, regs.DIV_MAX)
        self.sp_div.setValue(1)
        self.sp_div.valueChanged.connect(self._refresh_math)
        row.addWidget(self.sp_div)
        self.btn_apply = QPushButton("应用")
        self.btn_apply.setObjectName("Primary")
        self.btn_apply.clicked.connect(self._on_apply)
        row.addWidget(self.btn_apply)
        row.addStretch(1)
        lay.addLayout(row)

        self.v_math = uk.field(lay, "等效倍率", "—")
        self.v_edge = uk.field(lay, "AB 边沿率", "—", value_obj="BigValueSmall")
        self.v_board = uk.field(lay, "板上现值", "—", value_obj="Hint")
        # R20（批次 5）：边沿率/单通道频率随输入频率抖动 ⇒ 显示层稳定化
        self.st_edge = uk.Stable("ab_edge_mhz", name="AB 边沿率")
        self.st_ch = uk.Stable("ch_khz")

        # ---------- 高级参数（默认收起，保持界面简洁） ----------
        self.btn_adv = QPushButton("高级参数 ▾（迟滞 / 限频 / Z 脉宽 / 相位 / 极性）")
        # 阶段 3：摘到「诊断」页后它只是个"带路"入口，用 Ghost（链接式）而不是一整条按钮色块
        self.btn_adv.setObjectName("Ghost")
        self.btn_adv.clicked.connect(self._toggle_adv)
        lay.addWidget(self.btn_adv)

        self.box_adv = QWidget()
        adv = QVBoxLayout(self.box_adv)
        adv.setContentsMargins(0, 0, 0, 0)
        adv.setSpacing(6)
        adv.addWidget(uk.hint_label(
            "这些值都做“读-改-写”：只改指定位，寄存器里别的位（含仅存储位）保持不动。",
            lines=1))

        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(6)
        for i, spec in enumerate(regs.ADV_FIELDS):
            lab = uk.small_label(spec["label"], 84)
            sp = QSpinBox()
            sp.setRange(spec["lo"], spec["hi"])
            sp.setToolTip("%s\n0x%04X [位掩码 0x%04X]　%s"
                          % (spec["label"], spec["addr"], spec["mask"], spec["hint"]))
            sp.valueChanged.connect(self._refresh_phase_text)
            self._adv_spins[spec["key"]] = sp
            r, c = divmod(i, 2)
            grid.addWidget(lab, r, c * 2)
            grid.addWidget(sp, r, c * 2 + 1)
        adv.addLayout(grid)

        self.lab_phase = uk.hint_label("相位换算：—", lines=1)
        adv.addWidget(self.lab_phase)

        outrow = QHBoxLayout()
        outrow.setSpacing(10)
        for i, name in enumerate(regs.OUTPUT_BITS):
            chk = QCheckBox(regs.OUTPUT_LABELS[name])
            chk.setToolTip("0x0109 bit%d" % i)
            self._adv_checks[name] = chk
            outrow.addWidget(chk)
        outrow.addStretch(1)
        adv.addLayout(outrow)

        brow = QHBoxLayout()
        self.btn_adv_apply = QPushButton("应用高级参数")
        self.btn_adv_apply.clicked.connect(self._on_apply_adv)
        brow.addWidget(self.btn_adv_apply)
        self.lab_adv = uk.hint_label("高级区改动会逐条写入并回读确认。", lines=1)
        brow.addWidget(self.lab_adv, 1)
        adv.addLayout(brow)

        self.box_adv.setVisible(False)
        lay.addWidget(self.box_adv)
        lay.addStretch(1)
        self.set_connected(False)

    # ------------------------------------------------------------- 外部接口
    def inter_div(self):
        return self.sp_inter.value(), self.sp_div.value()

    def set_connected(self, conn, enabled=None):
        """conn = 串口是否连着（决定高级区要不要收起）；enabled = 现在能不能点。"""
        if enabled is None:
            enabled = conn
        for w in (self.btn_apply, self.btn_adv_apply, self.sp_inter, self.sp_div,
                  self.btn_adv):
            w.setEnabled(bool(enabled))
        for sp in self._adv_spins.values():
            sp.setEnabled(bool(enabled))
        for chk in self._adv_checks.values():
            chk.setEnabled(bool(enabled))
        if not conn:
            if getattr(self, "_adv_detached", False):
                # 阶段 2：高级参数整块在「诊断」页，按钮只负责带路，别改它的文案
                self.btn_adv.setText("高级参数 ▸（在「诊断」页）")
            else:
                self.box_adv.setVisible(False)
                self.btn_adv.setText("高级参数 ▾（迟滞 / 限频 / Z 脉宽 / 相位 / 极性）")
            self.v_edge.setText("—")
        self._refresh_adv_enabled()

    def update_f_in(self, f_in):
        """界面把估算出的输入频率喂进来，用于算 AB 边沿率。"""
        self.f_in = f_in
        self._refresh_math()

    def set_regs(self, raw):
        """读回配置后刷新界面（读回值可能含 None）。"""
        self.regs_raw = dict(raw or {})
        inter, div = regs.decode_inter_div(raw.get(regs.REG_INTER0),
                                           raw.get(regs.REG_INTER1))
        for sp, val in ((self.sp_inter, inter), (self.sp_div, div)):
            if val is not None:
                sp.blockSignals(True)
                sp.setValue(int(val))
                sp.blockSignals(False)
        if inter is None and div is None:
            self.v_board.setText("—（还没读回）")
        else:
            # 只留 inter/div：把两个 0x%04X 也印出来的话最长一行会把卡片撑到 577px
            # （主窗口给卡片的最小宽只有 540），门限那种细节放 tooltip 就好
            self.v_board.setText("inter=%s div=%s（已读回）" % (inter, div))
            self.v_board.setToolTip(
                "0x0101=0x%04X　0x0102=0x%04X"
                % (raw.get(regs.REG_INTER0) or 0, raw.get(regs.REG_INTER1) or 0))
        for spec in regs.ADV_FIELDS:
            val = regs.adv_field_value(spec["key"], self.regs_raw)
            if val is not None:
                sp = self._adv_spins[spec["key"]]
                sp.blockSignals(True)
                sp.setValue(int(val))
                sp.blockSignals(False)
        bits = regs.decode_output(raw.get(regs.REG_OUTPUT))
        if bits is not None:
            for name, chk in self._adv_checks.items():
                chk.setChecked(bool(bits[name]))
        self._refresh_math()
        self._refresh_phase_text()
        self._refresh_adv_enabled()

    def reset(self):
        """断开/重连时清掉上一次连接的寄存器快照与高档位读数。

        ★ 不清的话，重连后没读回就点"应用高级参数"，会拿旧连接的快照做读-改-写。
        """
        self.regs_raw = {}
        self.v_board.setText("—（还没读回）")
        self.v_board.setToolTip("")
        self._refresh_adv_enabled()

    def _has_board_values(self):
        """板上现值是否齐了（齐了才允许"应用高级参数"做读-改-写）。"""
        return all(self.regs_raw.get(a) is not None for a in regs.CFG_ADDRS)

    def _refresh_adv_enabled(self):
        """没读回配置就不能应用：否则"只改一位"会变成"整片写 0"。"""
        ok = self._has_board_values()
        if hasattr(self, "btn_adv_apply"):
            self.btn_adv_apply.setEnabled(ok and self.btn_apply.isEnabled())
            self.btn_adv_apply.setToolTip("" if ok else "请先点顶栏『设备自检』拿到板上现值，再改高级参数")

    # ------------------------------------------------------------- 交互
    def _set_preset(self, inter):
        if not self.btn_apply.isEnabled():
            return
        self.sp_inter.setValue(min(inter, regs.INTER_MAX))
        self.sp_div.setValue(1)

    def _on_apply(self):
        inter, div = self.inter_div()
        self.apply_requested.emit({"inter": inter, "div": div})

    def _on_apply_adv(self):
        # ★ 没读回板上现值就不许应用：adv_field_writes 拿 cur 当"板上现值"，读不到时
        #   cur or 0 会把"只改这一位"变成"整片写 0"（真踩过：7 条命令全写 0x0000，
        #   0x0108 的 z_width 由 4 变 0，Z 脉宽从 5 个边沿步缩到 1 个）
        if not self._has_board_values():
            self.adv_blocked.emit()
            return
        writes = {}
        cur_all = dict(self.regs_raw)
        for spec in regs.ADV_FIELDS:
            key = spec["key"]
            # 逐个字段用**累积后**的快照算：zphase 与 uvwph 的低 2 位同在 0x010C，
            # 用原始快照各算各的会让后算的覆盖先算的（Z 相位低 2 位丢失，真踩过）
            got = regs.adv_field_writes(key, self._adv_spins[key].value(), cur_all)
            if got is None:
                # 缺某个地址的现值（读失败）⇒ 不能猜 0 去覆盖，宁可整批不发
                self.adv_blocked.emit()
                return
            writes.update(got)
            cur_all.update(writes)
        bits = {name: chk.isChecked() for name, chk in self._adv_checks.items()}
        cur = self.regs_raw.get(regs.REG_OUTPUT)
        if cur is None:
            self.adv_blocked.emit()
            return
        new = (cur & 0xFF00) | regs.encode_output(bits)
        if cur != new:
            writes[regs.REG_OUTPUT] = new
        self.advanced_requested.emit(writes)

    def _toggle_adv(self):
        # 阶段 2（R17）：高级参数已整块搬到「诊断」页 ⇒ 这里的按钮变成"带路"
        if getattr(self, "_adv_detached", False):
            self.adv_page_requested.emit()
            return
        show = not self.box_adv.isVisible()
        self.box_adv.setVisible(show)
        self.btn_adv.setText("收起高级参数 ▴" if show else
                             "高级参数 ▾（迟滞 / 限频 / Z 脉宽 / 相位 / 极性）")

    def take_adv_box(self):
        """把「高级参数」那段摘下来交给别的页（阶段 2：搬到「诊断」页）。

        摘走之后本面板上的按钮不再是"展开/收起"，而是"去诊断页"。
        """
        lay = getattr(self, "_lay", None)
        if lay is not None:
            lay.removeWidget(self.box_adv)
        self._adv_detached = True
        self.box_adv.setVisible(True)
        self.btn_adv.setText("高级参数 ▸（在「诊断」页）")
        self.btn_adv.setToolTip("门限 / 迟滞 / Z 脉宽 / 极性都在「诊断」页，点这里跳过去")
        return self.box_adv

    # ------------------------------------------------------------- 换算显示
    def refresh_readouts(self):
        """R20：按当前显示口径重画换算读数（切「原始值」时由主窗口调）。"""
        self._refresh_math()

    def _refresh_math(self):
        inter, div = self.inter_div()
        m = regs.equiv_mult(inter, div)
        # ★ 用户反馈（m15813）：等效倍率只显示到整数位（如 ×256）
        self.v_math.setText("×%.0f（inter %d ÷ div %d）" % (m, inter, div) if m
                            else "—")
        er = regs.edge_rate(inter, div, self.f_in)
        if er is None:
            self.v_edge.setText("—（等输入频率有值）")
            self.v_edge.setToolTip("")
            self.st_edge.reset()
            self.st_ch.reset()
        else:
            # R20：两个数都走稳定显示（悬停看原始值）
            self.st_edge.update(er / 1e6)
            self.st_ch.update(er / 4.0 / 1000.0)
            self.v_edge.setText("%s /秒　单通道 %s"
                                % (format(int(round(er)), ","), self.st_ch.text()))
            self.v_edge.setToolTip("%s\n%s\n（/秒 是 4×inter/div×输入频率 的理论值，随输入频率变）"
                                   % (self.st_edge.tip(), self.st_ch.tip()))


    def _refresh_phase_text(self):
        z = self._adv_spins["zphase"].value()
        u = self._adv_spins["uvwph"].value()
        self.lab_phase.setText("相位换算：Z = %.1f°　UVW = %.1f°（单位 360/1024）"
                               % (regs.phase_deg(z), regs.phase_deg(u % 1024)))
