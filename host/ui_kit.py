"""界面小零件：卡片、字段行、电平灯、小标签。

只依赖 PySide6 与 theme，与串口/协议无关（离线也能 import）。
"""

from PySide6.QtCore import QEvent, QObject, Qt, Signal
from PySide6.QtGui import QFont, QFontMetrics
from PySide6.QtWidgets import (QFrame, QHBoxLayout, QLabel, QPushButton,
                               QSizePolicy, QToolButton, QVBoxLayout, QWidget)

import theme as th
import ui_font as uf

C = th.C

# R9②（批次 4）：挡位步进按钮（◀ ▶ / − +），点一下走一档，免得每次都要展开下拉框
STEP_BTN_WIDTH = 26

# R15：「微调档」标记角色 —— 组合框里那条临时档（data 仍是真实数值）靠它认出来。
#      默认 data 角色是 Qt.UserRole，所以这里必须往后挪一位，免得 findData() 撞上。
CUSTOM_FLAG_ROLE = Qt.UserRole + 1


def sync_span_combo(cmb, val, fmt):
    """把手动量程写回组合框；值不是档位值时补一条「（微调）」临时档，别"就近显示"。

    以前这里是"就近显示"：`Ctrl+滚轮` 微调到 49.152 ms，组合框却显示「满屏 50 ms」，
    与提示行的「量程：横轴 49.152 ms」对不上（用户 m11938 点名要改）。
    现在：值正好落在档位上就选档位并**删掉**临时档；是微调值就在「自动」后面插一条
    （已有就原地更新），文本由 `fmt % val` 给。返回选中的文本，便于自检断言。
    """
    idx = cmb.findData(val)
    if idx < 0 and isinstance(val, float):
        for i in range(cmb.count()):        # 浮点档位：容差内也算命中
            d = cmb.itemData(i)
            if isinstance(d, float) and abs(d - val) <= 1e-9 * max(1.0, abs(val)):
                idx = i
                break
    cidx = None
    for i in range(cmb.count()):
        if cmb.itemData(i, CUSTOM_FLAG_ROLE):
            cidx = i
            break
    if idx >= 0:
        if cidx is not None:
            cmb.removeItem(cidx)
            # ★ 临时档就插在「自动」后面 ⇒ 删掉它会让后面所有下标前移一位，
            #   必须重新定位，否则会选到隔壁档位
            idx = max(0, min(cmb.count() - 1, idx - (1 if cidx < idx else 0)))
        cmb.setCurrentIndex(idx)
        return cmb.currentText()
    text = fmt % val
    if cidx is None:
        cidx = 1                            # 紧跟「自动」那条
        cmb.insertItem(cidx, text, float(val))
    else:
        cmb.setItemText(cidx, text)
        cmb.setItemData(cidx, float(val))
    cmb.setItemData(cidx, True, CUSTOM_FLAG_ROLE)
    cmb.setCurrentIndex(cidx)
    return cmb.currentText()


def step_button(text, tip, width=STEP_BTN_WIDTH):
    """挡位步进小按钮（形状由 theme 里的 QToolButton#StepBtn 决定）。"""
    btn = QToolButton()
    btn.setObjectName("StepBtn")
    btn.setText(text)
    btn.setToolTip(tip)
    btn.setCursor(Qt.PointingHandCursor)
    btn.setAutoRaise(True)
    btn.setFocusPolicy(Qt.NoFocus)          # 抢焦点会吃掉方向键快捷键
    btn.setFixedWidth(width)
    return btn


# ------------------------------------------------------- 读数稳定化（R20，批次 5）
# 用户 m12144：「我输入 1 kHz 的正弦正交波形，显示的输入频率一直在 999/1000/1001 上下来回闪动」。
#
# 机理：板子每 100 µs 一帧（≈10 kHz），1 s 平滑窗内约 1000 个电周期 ⇒ 计数 ±1 个周期就是
# ±1 Hz = ±0.1%。也就是说**显示的末位比测量分辨率还细**，末位天然在跳，不是 bug。
#
# 做法（显示层，不动测量与估计算法）：
#   * 死区 deadband：新值偏离"当前显示值"没超过死区就**不改显示**（末位不跳）；
#     超过就更新 —— 所以真实变化照样立刻看得到，没有低通滤波那种滞后；
#   * 悬停显示**未处理的原始值**与不确定度（信息不丢）；
#   * 全局「原始值」开关（`set_raw_mode`）一开，所有读数直接显示原始值。
#
# ★ 不套稳定化的量：电角度、多周期位置、累计圈数、电周期数、各类累计计数（校验错帧数、
#   已写字节…）—— 它们"本来就该在走"，稳定化反而像卡住。
#
# 这张表就是《读数规范表》的代码版（docs/13 §5）：dec=显示小数位，dead=绝对死区，
# rel=相对死区（取较大者），rdec=悬停里原始值的小数位，note=不确定度说明。
READOUT_SPEC = {
    "freq_hz":     dict(dec=1, dead=2.0, rel=0.0,   unit=" Hz",     rdec=3,
                        name="输入频率", note="1 s 平滑窗、±1 Hz"),
    "rpm":         dict(dec=0, dead=5.0, rel=0.002, unit=" RPM",    rdec=1,
                        sep=True, name="机械转速", note="±0.1%"),
    "amp_r":       dict(dec=0, dead=40.0, rel=0.003, unit="",       rdec=0,
                        name="幅值 r", note="±0.3%"),
    "board_r":     dict(dec=0, dead=40.0, rel=0.003, unit="",       rdec=0,
                        name="板上 r", note="±0.3%"),
    "r_mean":      dict(dec=0, dead=40.0, rel=0.003, unit="",       rdec=0,
                        name="r 均值", note="±0.3%（波形卡字段只有 76 px，不加千分位）"),
    "roundness":   dict(dec=2, dead=0.05, rel=0.0,  unit=" %",      rdec=2,
                        name="圆度偏差", note="受分箱量化影响"),
    "fps":         dict(dec=0, dead=25.0, rel=0.003, unit=" 帧/秒", rdec=0,
                        sep=True, name="帧率", note="半秒统计窗"),
    "bps_k":       dict(dec=0, dead=5.0, rel=0.005, unit=" kB/s",   rdec=0,
                        name="数据率", note="半秒统计窗"),
    "crc_pct":     dict(dec=2, dead=0.02, rel=0.0,  unit="%",       rdec=3,
                        name="校验错比例", note="链路逐帧 XOR 口径"),
    "duty":        dict(dec=1, dead=0.25, rel=0.0,  unit="%",       rdec=2,
                        name="占空比", note="受分箱采样影响"),
    "ab_edge_mhz": dict(dec=2, dead=0.01, rel=0.005, unit=" MHz",   rdec=3,
                        name="AB 边沿率", note="4×inter/div×输入频率"),
    "ch_khz":      dict(dec=1, dead=0.3, rel=0.005, unit=" kHz",    rdec=2,
                        name="单通道频率", note="inter/div×输入频率"),
    "phase_ab":    dict(dec=1, dead=0.5, rel=0.0,   unit="°",       rdec=2,
                        name="A→B 相位差", note="受分箱采样影响"),
    "refresh_fps": dict(dec=1, dead=0.2, rel=0.0,   unit=" 次/秒",  rdec=2,
                        name="刷新率", note="本机性能"),
    "draw_ms":     dict(dec=1, dead=0.15, rel=0.0,  unit=" ms",     rdec=2,
                        name="画图耗时", note="本机性能"),
    "rec_lost":    dict(dec=2, dead=0.05, rel=0.0,  unit=" %",      rdec=3,
                        name="丢帧估计", note="校验错帧+重同步吞帧占比"),
    "rec_rate":    dict(dec=0, dead=30.0, rel=0.004, unit=" 帧/秒", rdec=0,
                        sep=True, name="写入速率", note="本机磁盘性能"),
    "st_pct":      dict(dec=2, dead=0.10, rel=0.0,  unit="%",       rdec=2,
                        name="状态占比", note="受分箱采样影响"),
}

_raw_mode = False
_STABLES = []          # 已创建的稳定器（切「原始值」时统一复位，让显示立刻换口径）


def raw_mode():
    """全局「原始值」模式：True = 所有读数直接显示未处理值（不套死区）。"""
    return _raw_mode


def set_raw_mode(on):
    """切「原始值」模式（状态条上的复选框调用）。

    切换时会把所有已创建的稳定器复位 ⇒ 下一次刷新直接按新口径显示，
    不会出现"切了模式但这个数还挂着旧口径的显示值"。
    """
    global _raw_mode
    _raw_mode = bool(on)
    reset_all_stable()
    return _raw_mode


def reset_all_stable():
    """复位所有已创建的稳定器（切模式/大刷新时用）。"""
    for st in list(_STABLES):
        try:
            st.reset()
        except Exception:
            pass


class Stable:
    """一个数值的显示层稳定器（死区 + 悬停看原始值）。

    用法：
        self.st_f = uk.Stable("freq_hz")
        ...
        uk.show(self.v_f, self.st_f, s["f_abs"])       # 更新 + 格式化 + 悬停
    """

    def __init__(self, key=None, dec=None, dead=None, rel=None, unit=None, name=None):
        spec = READOUT_SPEC.get(key or "", {})
        self.key = key
        self.dec = int(spec.get("dec", 1) if dec is None else dec)
        self.dead = float(spec.get("dead", 0.0) if dead is None else dead)
        self.rel = float(spec.get("rel", 0.0) if rel is None else rel)
        self.unit = spec.get("unit", "") if unit is None else unit
        self.name = spec.get("name", "") if name is None else name
        self.rdec = int(spec.get("rdec", self.dec + 2))
        self.sep = bool(spec.get("sep", False))
        self.note = spec.get("note", "")
        _STABLES.append(self)       # 登记：切「原始值」时统一复位
        self.reset()

    # ---------------------------------------------------------------- 状态
    def reset(self):
        """断开/重连时清空（下次来数就当第一次，直接跟上）。"""
        self._disp = None
        self._raw = None
        self._n = 0
        self._kept = 0          # 因死区被"按住"的次数（自检/排障用）
        self._moved = 0         # 真正更新显示值的次数

    def update(self, raw):
        """喂一个原始值，返回**该显示**的值（原始模式或首次 ⇒ 就是原始值）。"""
        try:
            v = float(raw)
        except (TypeError, ValueError):
            return self._disp
        if v != v:                                          # NaN
            return self._disp
        self._raw = v
        self._n += 1
        if self._disp is None:
            self._disp = v
            self._moved += 1
            return self.disp
        band = max(self.dead, abs(self.rel * self._disp))
        if abs(v - self._disp) > band:
            self._disp = v
            self._moved += 1
        else:
            self._kept += 1
        return self.disp

    @property
    def raw(self):
        return self._raw

    @property
    def disp(self):
        if _raw_mode or self._disp is None:
            return self._raw if self._raw is not None else self._disp
        return self._disp

    @property
    def stats(self):
        return dict(n=self._n, kept=self._kept, moved=self._moved)

    # ---------------------------------------------------------------- 格式化
    def value_text(self, value=None):
        v = self.disp if value is None else value
        if v is None:
            return "—"
        s = ("%%.%df" % self.dec) % v
        if self.sep and self.dec == 0:
            s = format(int(round(v)), ",")
        return s + self.unit

    def text(self, extra=""):
        return self.value_text() + (extra or "")

    def tip(self, extra=""):
        """悬停文本：说明这是稳定值 + 给出未处理的原始值与不确定度。"""
        lines = []
        if _raw_mode:
            lines.append("「原始值」模式：显示未处理值（可选菜单里关掉）")
        else:
            band = max(self.dead, abs(self.rel * (self._disp or 0.0)))
            lines.append("稳定显示：偏离超过 %.4g 才更新（避免末位闪烁）" % band)
        if self.name:
            lines.insert(0, self.name)
        if self._raw is not None:
            raw = ("%%.%df" % self.rdec) % self._raw
            if self.sep and self.rdec == 0:
                raw = format(int(round(self._raw)), ",")
            lines.append("原始值 %s%s" % (raw, self.unit))
        if self.note:
            lines.append("分辨力：%s" % self.note)
        if extra:
            lines.append(extra)
        return "\n".join(lines)


def show(lab, st, raw, extra="", fmt=None):
    """把稳定器的值写进标签（并挂上"悬停看原始值"的提示）。返回该显示值。"""
    v = st.update(raw)
    lab.setText(fmt % v if fmt else st.text())
    lab.setToolTip(st.tip(extra))
    return v


def stable_fields(panel, mapping):
    """给面板批量建稳定器：mapping = {属性名: 读数键}，存成 `panel.st_<名>`。

    省得每个面板重复写十几行 `self.st_x = uk.Stable("...")`，也保证"读数规范表"是
    唯一来源（自检直接查这张表）。
    """
    made = {}
    for attr, key in (mapping or {}).items():
        obj = Stable(key)
        setattr(panel, attr, obj)
        made[attr] = obj
    return made



def make_card(title, hint=None, hint_lines=2):
    """建一张卡片，返回 (卡片, 内容布局)。

    hint_lines：提示文字固定占几行（预留高度），免得文字长短变化时卡片忽高忽低。
    """
    card = QFrame()
    card.setObjectName("Card")
    lay = QVBoxLayout(card)
    lay.setContentsMargins(14, 10, 14, 12)
    lay.setSpacing(8)
    head = QLabel(title)
    head.setObjectName("CardTitle")
    lay.addWidget(head)
    if hint:
        lay.addWidget(hint_label(hint, lines=hint_lines))
    # 阶段 2（R17）取消了卡片级的「⛶ 放大」：分页之后一页只服务一件事，不再需要
    # 把单张卡片撑满窗口（用户 m12144 抱怨"信息多而乱"的解药是分页，不是放大）。
    return card, lay


def fix_lines(lab, lines=2):
    """把标签高度夹在 lines~lines+1 行之间（配合 setWordWrap）。

    为什么需要：提示/备注文字会随内容换行成 1~3 行，卡片高度跟着变，整行卡片和下方
    内容就会被顶得上下跳 —— 这是界面上最明显的“波动”。

    ★ 别再改回 setFixedHeight：字体的行高由 QSS（`#Hint` 12px）与系统字体共同决定，
    构造时量到的 fontMetrics 和真正渲染时可能差一两个像素，固定高度会把最后一行
    切掉一半（阶段 2 做六页排版时在「⑤ 转速与位置」上抓到）。留一行余量即可。
    """
    if lines:
        # 记住行数：字号自适应（阶段 5 B 批）后要按新字号重算高度。
        lab.setProperty("fixedLines", int(lines))
        _apply_fixed_lines(lab, lines)
    return lab


def _apply_fixed_lines(lab, lines):
    """把标签高度锁成"正好 lines 行"（min == max）。

    ★ 这里曾经是 lines ~ lines+1 的区间（怕切掉最后一行），结果高度能在两档之间
    跳：实测「⚠ 上位机接收比板子慢…」在 47↔48 px 之间跳 25 次，整张卡片 +1 px、
    整页内容 +1 px —— 就是用户说的"字多字少上下乱晃"（m02689）。
    宁可少一行也不能晃：装不下的提示会被裁，用 `tools/_watch_layout.py --audit`
    查哪条提示需要更多行，然后把它的 lines 调大。
    """
    ls = lab.fontMetrics().lineSpacing()
    slack = int(lab.property("fixedSlack") or 0)
    lab.setMinimumHeight(ls * int(lines) + 2)
    lab.setMaximumHeight(ls * (int(lines) + slack) + 2)


def allow_lines(lab, lo, hi):
    """允许这个标签在 lo~hi 行之间取高度（给**静态**说明文字用）。

    动态文字（每个 tick 都会变的读数/提示）必须 min == max，否则一行字多一个
    数字、整张卡片就 +1 px，整页跟着上下跳（m02689 实测 47↔48 px 跳 25 次）。
    静态文字只随窗口宽度换行，不会自己跳，所以可以留余量、不留空。
    """
    lab.setProperty("fixedSlack", max(0, int(hi) - int(lo)))
    return fix_lines(lab, lo)


def refresh_fixed_lines(root):
    """字号变了以后，把所有 `fix_lines()` 过的标签按新字号重算高度。

    ★ 不重算的后果：放大字号后提示文字要多占一行，而最小/最大高度还是按旧字号
    算的 ⇒ 最后一行被切掉（阶段 2 在「转速与位置」上出过同一类问题）。
    """
    n = 0
    try:
        for lab in root.findChildren(QLabel):
            try:
                lines = lab.property("fixedLines")
            except Exception:                                     # noqa: BLE001
                lines = None
            if lines:
                _apply_fixed_lines(lab, int(lines))
                n += 1
                continue
            # 字段名 / 读数：字号变了要按新字号重算锁死的高度，否则放大字号后
            # 高度还按旧字号算 ⇒ 汉字那一行被切掉半截。
            if lab.objectName() in ("FieldName", "BigValueSmall", "BigValue",
                                    "BigValueTiny", "Mono"):
                if lock_row_height(lab) > 0:
                    n += 1
    except Exception:                                             # noqa: BLE001
        pass
    return n


# 汉字由回落字体（雅黑）渲染，行高比 Inter 的等宽数字高 4~6 px。
# 一行读数在「已连接 / 2.08 % / 门限未读到」之间切换时，标签高度就会 27↔31 跳，
# 整张卡片跟着长高、下面所有卡片被顶得上下晃 —— 这就是用户说的"抖来抖去"。
# 解决办法：每行标签都按**含汉字**的行高锁死，内容怎么变高度都不变。
CJK_FAMILIES = ("Microsoft YaHei UI", "Microsoft YaHei", "SimHei")


def cjk_height(lab):
    """按标签当前字号，算出"含汉字"时需要的行高（含 2 px 余量）。"""
    try:
        lab.ensurePolished()
        fm = lab.fontMetrics()
        best = fm.height()
        base = QFont(lab.font())
        for fam in CJK_FAMILIES:
            base.setFamily(fam)
            best = max(best, QFontMetrics(base).height())
        return int(best) + 2
    except Exception:                                              # noqa: BLE001
        return 0


def lock_row_height(lab):
    """把单个标签的高度锁定（min == max），返回锁到的高度。"""
    h = cjk_height(lab)
    if h > 0:
        lab.setMinimumHeight(h)
        lab.setMaximumHeight(h)
    return h


def hint_label(text, lines=2):
    """灰色小字提示（自动换行，高度固定成 lines 行）。"""
    lab = QLabel(text)
    lab.setObjectName("Hint")
    lab.setWordWrap(True)
    return fix_lines(lab, lines)


def small_label(text, width=84):
    """字段名（灰色小字）。"""
    lab = QLabel(text)
    lab.setObjectName("FieldName")
    if width:
        lab.setMinimumWidth(width)
    lock_row_height(lab)        # 高度锁死：文案长短/中英切换都不许改高度
    return lab


class TipLabel(QLabel):
    """数值标签：文字被格子裁掉时，鼠标悬停能看到全文。

    配 `field()` 的水平 Ignored 策略用 —— 宽度由格子决定（不随文字变），所以
    "inter=32 div=1 极对数=4" 这种长值可能被裁；裁掉的东西必须还能读到，
    否则用户会以为没读到（m02689）。
    """

    def __init__(self, text="", parent=None):
        super().__init__(text, parent)
        self._full = text or ""
        self.setToolTip(self._full)

    def full_text(self):
        return self._full

    def setText(self, text):
        self._full = text or ""
        self.setToolTip(self._full)
        super().setText(self._full)


def field(parent_lay, name, value="-", value_obj="BigValueSmall", width=84,
          row=None, col=None, vmin=150, mono=True):
    """一行“名称 + 数值”，返回数值 QLabel（供刷新）。

    传了 row/col 就放进 QGridLayout 的格子里（QGridLayout.addLayout 必须给坐标）。

    vmin：数值标签的最小宽度 —— 各行的数值列左边界因此对齐，数字变长变短都不会
          把旁边的控件推来推去（这是“显示位置不稳”的主要来源之一）。
    mono：数值用等宽字体（theme 里 QLabel[mono="true"] 那条规则）；纯中文/混排的
          值传 mono=False，保持雅黑好看。
    """
    row_lay = QHBoxLayout()
    row_lay.setSpacing(6)
    row_lay.addWidget(small_label(name, width))
    v = TipLabel(value)
    v.setObjectName(value_obj)
    v.setProperty("mono", "true" if mono else "false")
    if mono:
        # 阶段 3：读数用 Inter 的 tabular figures（等宽数字），位数变化时整行不抖；
        # 中文字符由回落字体渲染（Inter 没有汉字）。
        uf.use_tabular(v)
    if vmin:
        v.setMinimumWidth(vmin)
    # ★ 关键（m02689）：水平方向 Ignored —— 布局不再把"文字宽度"当成这个标签的
    #   最小宽度。否则帧数从 2 变 15、转速从 210 变 1000，整列就宽 10 px，
    #   右邻列被推走；列宽一旦超过可视区，横向滚动条出现/消失又改可视区高度，
    #   整页跟着上下跳（实测 ABZ 卡 4 个读数 224↔234 连跳 35 次）。
    #   宽度改由所在格子决定（配合格子的 stretch），min width 仍保证列对齐。
    v.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
    v.setTextInteractionFlags(Qt.TextSelectableByMouse)
    lock_row_height(v)          # ★ 关键：数字 ↔ 汉字（"—"/"门限未读到"）不许改高度
    row_lay.addWidget(v, 1)
    if row is None or col is None:
        parent_lay.addLayout(row_lay)
    else:
        parent_lay.addLayout(row_lay, row, col)
    return v


def sgn(text):
    """把 ASCII 连字符换成 U+2212（减号）。

    ★ 这条是给图形/自绘控件用的：本机雅黑在 7 pt 下把 ASCII '-' 画成**空白**
      （advance 13 px 却一个暗像素都没有，见 tools/_smoke_capture_plot.py 的注释），
      于是"-20"看起来就是"20"，负半周刻度、负时刻全被读成正数。
      QLabel 里的文字走 Qt 排版不受影响，只有 QPainter.drawText 用得上。
    """
    return str(text).replace("-", "−")


def paint_chip(lab, val):
    """电平指示灯：1 = 淡蓝底白字，0 = 灰底灰字，None = 未连接。"""
    if val is None:
        bg, fg = C["chip_off"], C["muted"]
    elif val:
        bg, fg = C["primary"], "#FFFFFF"
    else:
        bg, fg = C["line"], C["muted"]
    lab.setStyleSheet("background:%s; color:%s; border-radius:6px;"
                      "padding:3px 6px; font-weight:600;" % (bg, fg))


# --------------------------------------------------------------- 示波器式导航
class ScopeNav(QObject):
    """把一张 matplotlib 画布变成“示波器旋钮”（界面优化批次 3）。

    - **Ctrl+滚轮**：以光标位置为中心缩放横轴（上滚放大、下滚缩小）；
    - **左键拖动**：平移（横轴；面板给了 `y_pan`/`set_y_pan` 时纵轴一起平移）；
    - **双击**：交回面板的 `reset_auto()`（恢复自动量程）。

    面板按下面的“鸭子协议”提供视图状态（不必继承任何东西）：
        nav_axes() -> ax             用哪张子图做像素↔数据换算
        x_span() / set_x_span(v)     当前横轴跨度（数据单位；面板负责夹取、记忆、切手动）
        x_center() / set_x_center(c) 当前横轴中心
        reset_auto()                 双击时调用
        y_pan() / set_y_pan(v)       可选：纵轴偏移（没有这两个方法就只平移横轴）

    ★ 为什么不用 matplotlib 自己的事件：滚轮要区分“有没有按 Ctrl”才能既滚页面又缩放图表，
      而 `host/main_window.py` 的全局滚轮过滤器是**先**看到事件的（白名单里放行 Ctrl+滚轮），
      所以这里用 Qt 事件过滤器，排在全局面板过滤器之后、图层之前。
    ★ 阶段 2：卡片独占（`⛶` 放大）退场后，裸滚轮**一律**留给“滚页面”，
      画布只在 Ctrl+滚轮时缩放横轴（唯一契约，没有例外）。
    """

    ZOOM_STEP = 0.8        # 一格滚轮缩放到 0.8×（上滚放大）
    TIP_NORMAL = "Ctrl+滚轮 缩放 · 左键拖动平移 · 双击恢复自动量程"

    def __init__(self, canvas, view, parent=None):
        super().__init__(parent)
        self.canvas = canvas
        self.view = view
        self._drag = None
        canvas.installEventFilter(self)
        canvas.setProperty("wheelZoom", True)      # 告诉主窗口：Ctrl+滚轮留给图表
        canvas.setToolTip(self.TIP_NORMAL)

    # ------------------------------------------------------------ 像素↔数据
    def _px_ratio(self, ax):
        """画布逻辑像素 → matplotlib 显示像素的比值（高 DPI 缩放下两者不同）。"""
        try:
            bb = ax.bbox
            w = float(self.canvas.width()) or 1.0
            return (float(bb.width) / w, float(bb.height) / max(1.0, float(self.canvas.height())))
        except Exception:                                          # noqa: BLE001
            return 1.0, 1.0

    def _axis_pos(self, ev):
        pos = ev.position()
        return float(pos.x()), float(pos.y())

    def _frac(self, ax, px, py):
        """光标在子图里的相对位置（0…1）。"""
        rx, ry = self._px_ratio(ax)
        bb = ax.bbox
        fx = (px * rx - float(bb.x0)) / max(1.0, float(bb.width))
        fy = (py * ry - float(bb.y0)) / max(1.0, float(bb.height))
        return min(1.0, max(0.0, fx)), min(1.0, max(0.0, fy))

    # ------------------------------------------------------------ 交互
    def eventFilter(self, obj, ev):                     # noqa: N802
        try:
            t = ev.type()
            if obj is not self.canvas:
                return False
            if t == QEvent.Wheel:
                if not (ev.modifiers() & Qt.ControlModifier):
                    return False            # 阶段 2：裸滚轮留给“滚当前页”
                self._zoom(ev)
                return True
            if t == QEvent.MouseButtonDblClick:
                if ev.button() == Qt.LeftButton:
                    self.view.reset_auto()
                    return True
                return False
            if t == QEvent.MouseButtonPress:
                if ev.button() == Qt.LeftButton:
                    self._drag = self._axis_pos(ev)
                return False
            if t == QEvent.MouseMove:
                if self._drag is not None and (ev.buttons() & Qt.LeftButton):
                    self._pan(ev)
                    return True
                return False
            if t == QEvent.MouseButtonRelease:
                self._drag = None
                return False
        except Exception:                               # noqa: BLE001
            # 交互出错只当没发生：绝不让异常冒进 Qt 事件循环（会把整条刷新链打断）
            self._drag = None
        return False

    def _zoom(self, ev):
        ax = self.view.nav_axes()
        if ax is None:
            return
        dy = ev.angleDelta().y() or ev.angleDelta().x()
        if not dy:
            return
        span = float(self.view.x_span())
        if not span or span <= 0:
            return
        px, py = self._axis_pos(ev)
        fx, _ = self._frac(ax, px, py)
        center = float(self.view.x_center())
        cursor = center - span / 2.0 + fx * span
        factor = self.ZOOM_STEP ** (dy / 120.0)
        self.view.set_x_span(span * factor)                    # 面板负责夹取
        span2 = float(self.view.x_span())
        # 让光标下的数据点保持不动：新的左边界 = 光标 - 同一相对位置 × 新跨度
        self.view.set_x_center(cursor - fx * span2 + span2 / 2.0)

    def _pan(self, ev):
        ax = self.view.nav_axes()
        if ax is None:
            return
        px, py = self._axis_pos(ev)
        dx = px - self._drag[0]
        dy = py - self._drag[1]
        self._drag = (px, py)
        span = float(self.view.x_span())
        w = max(1.0, float(self.canvas.width()))
        h = max(1.0, float(self.canvas.height()))
        # 像素位移换算成数据位移（横轴按 spans/宽度；纵轴按当前 ylim/高度）
        ddx = -dx * span / w
        self.view.set_x_center(float(self.view.x_center()) + ddx)
        set_y = getattr(self.view, "set_y_pan", None)
        if callable(set_y):
            y0, y1 = ax.get_ylim()
            ddy = dy * (y1 - y0) / h
            set_y(float(self.view.y_pan()) + ddy)


# ---------------------------------------------- 阶段 2（R17）：左侧窄侧栏 + 页标题
# 一次一页：左边一条窄栏（Apple「系统设置」式），右边只放当前这一页。
# `───` 那一行之后是低频的「诊断」页（设备自检 / 高级参数 / 通信日志）。
SIDEBAR_W = 176

PAGES = (("overview", "概览"),
         ("live", "实时"),
         ("enc", "编码器信号"),
         ("alarm", "告警"),
         ("record", "记录"),
         ("capture", "抓包"),
         (None, None),                      # 分隔线
         ("diag", "诊断"))


class Sidebar(QFrame):
    """窄侧栏导航。只有当前页高亮，别的什么都不放。"""

    page_changed = Signal(str)

    def __init__(self, title="host_app", subtitle="", parent=None):
        super().__init__(parent)
        self.setObjectName("Sidebar")
        self.setFixedWidth(SIDEBAR_W)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 18, 14, 12)
        lay.setSpacing(4)
        t = QLabel(title)
        t.setObjectName("AppTitle")
        lay.addWidget(t)
        self.lab_ver = QLabel(subtitle)
        self.lab_ver.setObjectName("AppSub")
        self.lab_ver.setWordWrap(True)
        lay.addWidget(self.lab_ver)
        lay.addSpacing(12)
        self._btns = {}
        self._keys = []
        for key, label in PAGES:
            if key is None:
                sep = QFrame()
                sep.setObjectName("NavSep")
                sep.setFixedHeight(1)
                lay.addSpacing(6)
                lay.addWidget(sep)
                lay.addSpacing(6)
                continue
            b = QPushButton(label)
            b.setObjectName("NavItem")
            b.setCheckable(True)
            b.setAutoExclusive(True)
            b.setCursor(Qt.PointingHandCursor)
            b.clicked.connect(lambda _c=False, k=key: self.page_changed.emit(k))
            lay.addWidget(b)
            self._btns[key] = b
            self._keys.append(key)
        lay.addStretch(1)
        if self._keys:
            self._btns[self._keys[0]].setChecked(True)

    def keys(self):
        return list(self._keys)

    def button(self, key):
        return self._btns.get(key)

    def set_page(self, key):
        """只把高亮挪过去（不发信号）：程序自己切页时用，免得绕回来重进一遍。"""
        b = self._btns.get(key)
        if b is not None and not b.isChecked():
            b.setChecked(True)


def page_header(title, subtitle=""):
    """每页顶部一行：这一页叫什么 + 一句话说明它回答什么问题。"""
    box = QWidget()
    box.setObjectName("PageHead")
    lay = QVBoxLayout(box)
    lay.setContentsMargins(2, 0, 2, 0)
    lay.setSpacing(1)
    t = QLabel(title)
    t.setObjectName("PageTitle")
    lay.addWidget(t)
    if subtitle:
        s = QLabel(subtitle)
        s.setObjectName("PageSub")
        lay.addWidget(s)
    return box

