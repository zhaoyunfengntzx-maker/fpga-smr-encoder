"""⑩ 正交质量卡：用遥测帧估前端四参数（幅值/正交/偏置/残差）与取点覆盖。

为什么要有这张卡：板上做了偏置补偿、幅值均衡、正交校正，但**界面上从来没见过
这些量到底是多少**。于是现象出现时只能猜（"角度不对是不是前端不行？"）。
这张卡把 s-c 点云当成一次测量，直接给出 R_s/R_c/ε/偏置/残差，并按一阶公式折算
成"角度误差幅值"——这样"前端够不够好"变成一个有数可查的问题。

设计约束（改这个文件前先读）：
1. 数学全在 analysis.py（纯 numpy + --selftest）。这里只负责取帧、节流、显示，
   **不要在界面里写公式**：界面代码没法离线自检，写进去就没人测了。
2. θ 优先用**板上报的电角度**：已知 θ 时拟合退化成两次线性回归（iters=0，5 ms）；
   帧里没有角度才退回 Heydemann 迭代。混用会把"板端角度误差"和"前端误差"搅在一起。
3. 0.5 s 节流。1500 帧一次拟合约 5 ms，按 10 Hz 跑就是白烧 CPU（还抢 GIL）。
4. 覆盖度判据是"每个角箱都有点"（analysis.coverage 的 ok），不是"百分比好看"。
   停机不动时覆盖率可能 10%，那时拟合出来的参数**不能用来判断前端**。
"""

from __future__ import annotations

import time

import numpy as np
from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import QFrame, QLabel, QVBoxLayout, QWidget

import analysis as an
import theme as th
import ui_kit as uk

C = th.C

MIN_FRAMES = 240          # 少于 24 ms 的数据，拟合没意义（一圈都不到的常见情形）
PERIOD_S = 0.5            # 重算周期
# 判据阈值：都按"一个 16 位编码器的前端"取，超出就值得查线/查板
# ★ 判据一律用「机械角秒」（电角度 ÷ 每转周期数 × 3600）。
#   用户反馈：0.25°(电) 看着像大问题，其实只有 0.44″ —— 不该标红。
#   单项阈值：增益/正交 1″/5″，偏置 1.5″/8″；合计 2″/10″；残差是比例不折角度。
TH_GAIN_OK, TH_GAIN_WARN = 1.0, 5.0          # 角秒
TH_ORTH_OK, TH_ORTH_WARN = 1.0, 5.0          # 角秒
TH_OFF_OK, TH_OFF_WARN = 1.5, 8.0            # 角秒
TH_RES_OK, TH_RES_WARN = 2.0, 5.0            # %（相对幅值的残差）
TH_TOTAL_OK, TH_TOTAL_WARN = 2.0, 10.0       # 角秒（合计）

LEVEL_OK, LEVEL_WARN, LEVEL_FAULT = 0, 1, 2
_COLOR = {LEVEL_OK: C["ok"], LEVEL_WARN: C["warn"], LEVEL_FAULT: C["fault"]}


def _level(x, ok, warn):
    a = abs(float(x))
    if a <= ok:
        return LEVEL_OK
    return LEVEL_WARN if a <= warn else LEVEL_FAULT


class CoverageBar(QWidget):
    """128 个角箱的取点密度条（空箱画成故障色，一眼看出缺口在哪）。"""

    def __init__(self, bins=an.COVERAGE_BINS, parent=None):
        super().__init__(parent)
        self._counts = np.zeros(bins, dtype=np.int64)
        self.setMinimumHeight(34)
        self.setToolTip("每个像素列 = 360°/128 的一个角箱；柱高 = 该箱里的帧数。"
                        "空箱（或少于 3 个点）说明这个角度没取到数据。")

    def set_counts(self, counts):
        self._counts = np.asarray(counts, dtype=np.int64) if counts is not None \
            else np.zeros(an.COVERAGE_BINS, dtype=np.int64)
        self.update()

    def paintEvent(self, _ev):                                  # noqa: N802
        p = QPainter(self)
        try:
            r = self.rect()
            p.fillRect(r, QColor(C["card"]))
            n = int(self._counts.size) or 1
            top, bot = r.top() + 6, r.bottom() - 2
            lo, hi = float(self._counts.min()), float(self._counts.max())
            span = max(1.0, hi - lo) if hi > 0 else 1.0
            colw = max(1.0, r.width() / n)
            for i, v in enumerate(self._counts):
                v = int(v)
                x = r.left() + i * colw
                if v <= 0:
                    p.fillRect(QRectF(x, top, max(1.0, colw - 0.5), bot - top),
                               QColor(C["fault"]).darker(140))
                    continue
                h = (bot - top) * (0.12 + 0.88 * (v - lo) / span)
                color = QColor(C["fault"] if v < an.COVERAGE_MIN else C["ok"])
                p.fillRect(QRectF(x, bot - h, max(1.0, colw - 0.5), h), color)
            p.setPen(QPen(QColor(C["line"])))
            p.drawLine(r.left(), bot, r.right(), bot)
        finally:
            p.end()


class QualityPanel(QFrame):
    """正交质量卡片（概览页/实时页共用同一份数据）。"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self._last_t = 0.0
        self._last = {}

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 12)
        lay.setSpacing(8)

        head = QLabel("正交质量")
        head.setObjectName("CardTitle")
        lay.addWidget(head)
        lay.addWidget(uk.hint_label(
            "用最近一轮遥测帧当点云，回归出「两路幅值 / 正交误差 / 两路偏置 / 残差」，"
            "再按一阶公式折算成角度误差幅值。它反映的是**板端补偿之后**还剩多少误差，"
            "所以数字小说明补偿有效；数字大要么前端失配，要么板上校正没开。"
            "取点不足（转动范围不够一圈）时不给结论。", lines=4))

        self.v_r = uk.field(lay, "幅值 R_s / R_c", "—", vmin=200)
        self.v_gain = uk.field(lay, "增益差", "—")
        self.v_orth = uk.field(lay, "正交误差 ε", "—")
        self.v_off = uk.field(lay, "偏置 o_s / o_c", "—", vmin=200)
        self.v_res = uk.field(lay, "残差 RMS", "—")
        self.v_cov = uk.field(lay, "取点覆盖", "—")
        self.v_err = uk.field(lay, "折算角度误差", "—")

        self.bar = CoverageBar()
        lay.addWidget(self.bar)

        self.lab_verdict = uk.hint_label("等待数据…", lines=2)
        lay.addWidget(self.lab_verdict)
        lay.addStretch(1)

        self.st_gain = uk.Stable("", dec=2, dead=0.01, unit=" dB")
        self.st_orth = uk.Stable("", dec=3, dead=0.005, unit=" °")
        self.st_err = uk.Stable("", dec=2, dead=0.01, unit=" ″")   # 折算后是机械角秒

    # ------------------------------------------------------------- 外部接口
    def reset(self):
        """断开/重连时清空（不能留着上一台板子的结论）。"""
        self._last = {}
        self._last_t = 0.0
        for lab in (self.v_r, self.v_gain, self.v_orth, self.v_off, self.v_res,
                    self.v_cov, self.v_err):
            lab.setText("—")
            lab.setToolTip("")
        for st in (self.st_gain, self.st_orth, self.st_err):
            st.reset()
        self.bar.set_counts(None)
        self.lab_verdict.setText("等待数据…")
        self.lab_verdict.setStyleSheet("")

    def feed(self, frames, force=False):
        """喂一批帧；按 PERIOD_S 节流。返回最近一次的结果 dict（可能为空）。"""
        now = time.monotonic()
        if not force and (now - self._last_t) < PERIOD_S:
            return self._last
        self._last_t = now
        if not frames:
            return self._last

        ss, cc, aa = [], [], []
        for f in frames:
            s = f.get("s")
            c = f.get("c")
            if s is None or c is None:
                continue
            ang = f.get("angle_deg")
            if ang is None:
                ang = f.get("angle")
                ang = None if ang is None else float(ang) * 360.0 / 65536.0
            ss.append(int(s))
            cc.append(int(c))
            aa.append(np.nan if ang is None else float(ang))
        n = len(ss)
        if n < MIN_FRAMES:
            self.lab_verdict.setText("取点不足（%d 帧，至少 %d 帧 / %.0f ms）"
                                     % (n, MIN_FRAMES, MIN_FRAMES / 10.0))
            self.lab_verdict.setStyleSheet("color:%s;" % C["muted"])
            self._last = {"ok": False, "n": n, "note": "取点不足"}
            return self._last

        s = np.asarray(ss, dtype=float)
        c = np.asarray(cc, dtype=float)
        ang = np.asarray(aa, dtype=float) if not np.all(np.isnan(aa)) else None
        p = an.fit_quadrature(s, c, theta_deg=ang)
        if not p["ok"]:
            self.lab_verdict.setText("拟合失败（点数 %d）" % n)
            self.lab_verdict.setStyleSheet("color:%s;" % C["fault"])
            self._last = {"ok": False, "n": n, "note": "拟合失败"}
            return self._last
        fe = an.front_end_error(p)
        if ang is not None:
            q = an.coverage(ang)
        else:
            # 没有角度就自己反解一遍（只为算覆盖度，不参与拟合）
            th = np.degrees(np.unwrap(np.arctan2((s - p["off_s"]) / max(p["r_s"], 1e-9),
                                                 (c - p["off_c"]) / max(p["r_c"], 1e-9))))
            q = an.coverage(th)

        self.v_r.setText("%.0f / %.0f LSB" % (p["r_s"], p["r_c"]))
        self.v_r.setToolTip("s ≈ R_s·sinθ、c ≈ R_c·cosθ；满刻度 32768 ⇒ %.2f%% / %.2f%%"
                            % (100.0 * p["r_s"] / 32768.0, 100.0 * p["r_c"] / 32768.0))
        uk.show(self.v_gain, self.st_gain, p["gain_dB"],
                extra="比值 %.5f（差 1%% 约等于 0.29 dB）" % p["gain_ratio"])
        uk.show(self.v_orth, self.st_orth, p["eps_deg"],
                extra="正 = c 路超前 90°；切到角度误差约 %.3f°" % fe["orth_deg"])
        self.v_off.setText("%+.0f / %+.0f LSB" % (p["off_s"], p["off_c"]))
        self.v_off.setToolTip("满刻度 32768 ⇒ %.3f%% / %.3f%%"
                              % (100.0 * p["off_s"] / 32768.0,
                                 100.0 * p["off_c"] / 32768.0))
        self.v_res.setText("%.2f LSB（%.2f%%）"
                           % (p["res_rms"], 100.0 * p["res_rms_rel"]))
        self.v_res.setToolTip("拟合后两路还差多少（径向合成）。残差大 = 还有谐波/噪声/"
                              "采样抖动等一阶模型盖不住的误差源。SNR %.1f dB" % p["snr_db"])
        self.v_cov.setText("%.1f%%（%d 箱，缺口 %.1f°）"
                           % (q["coverage_pct"], q["bins"], q["gap_deg"]))
        self.v_cov.setToolTip("每 %.2f° 一个角箱；空箱 %d 个、少于 %d 点的 %d 个"
                              % (360.0 / q["bins"], q["empty_bins"],
                                 q["bins"] and an.COVERAGE_MIN, q["low_bins"]))
        # 电角度 → 机械角秒：除以每转正弦周期数再乘 3600
        k_arc = 3600.0 / max(1, int(getattr(self, "_pairs", 2048)))
        mech = {"gain": fe["gain_deg"] * k_arc, "orth": fe["orth_deg"] * k_arc,
                "off": fe["off_deg"] * k_arc, "total": fe["total_deg"] * k_arc}
        uk.show(self.v_err, self.st_err, mech["total"],
                extra="增益 %.2f″ ⊕ 正交 %.2f″ ⊕ 偏置 %.2f″（一阶、平方和；电 %.3f°）"
                      % (mech["gain"], mech["orth"], mech["off"], fe["total_deg"]))
        self.bar.set_counts(q["counts"])

        items = []
        if _level(mech["gain"], TH_GAIN_OK, TH_GAIN_WARN) >= LEVEL_WARN:
            lv = _level(mech["gain"], TH_GAIN_OK, TH_GAIN_WARN)
            items.append((lv, "两路幅值失配 %.2f dB（%.1f″）"
                          % (p["gain_dB"], mech["gain"])))
        if _level(mech["orth"], TH_ORTH_OK, TH_ORTH_WARN) >= LEVEL_WARN:
            lv = _level(mech["orth"], TH_ORTH_OK, TH_ORTH_WARN)
            items.append((lv, "正交误差 %.1f″（%.2f° 电）"
                          % (mech["orth"], p["eps_deg"])))
        off = float(np.hypot(p["off_s"], p["off_c"]))
        if _level(mech["off"], TH_OFF_OK, TH_OFF_WARN) >= LEVEL_WARN:
            lv = _level(mech["off"], TH_OFF_OK, TH_OFF_WARN)
            items.append((lv, "偏置合成 %.0f LSB（%.1f″）" % (off, mech["off"])))
        if _level(100.0 * p["res_rms_rel"], TH_RES_OK, TH_RES_WARN) >= LEVEL_WARN:
            lv = _level(100.0 * p["res_rms_rel"], TH_RES_OK, TH_RES_WARN)
            items.append((lv, "残差 %.2f%%" % (100.0 * p["res_rms_rel"])))
        if not q["ok"] and q["coverage_pct"] >= 99.0:
            items.append((LEVEL_WARN, "有角箱少于 %d 点" % an.COVERAGE_MIN))
        elif q["gap_deg"] > 0.0:
            items.append((LEVEL_WARN, "取点缺口 %.1f°" % q["gap_deg"]))

        lv_tot = _level(mech["total"], TH_TOTAL_OK, TH_TOTAL_WARN)
        if lv_tot >= LEVEL_WARN:
            items.append((lv_tot, "合计 %.1f″" % mech["total"]))

        if items:
            lv = max(i[0] for i in items)
            self.lab_verdict.setText("；".join(t for _l, t in items[:3])
                                     + "　（n=%d，%.0f ms）" % (n, n / 10.0))
        else:
            lv = LEVEL_OK
            self.lab_verdict.setText("前端正常　（合计 %.2f″，n=%d，%.0f ms）"
                                     % (mech["total"], n, n / 10.0))
        self.lab_verdict.setStyleSheet("color:%s;" % _COLOR[lv])

        self._last = {"ok": True, "n": n, "params": p, "coverage": q,
                      "error": fe, "level": int(lv)}
        return self._last

    def set_pairs(self, pairs):
        """每转正弦周期数（电角度 → 机械角度的除数）。界面按「每转周期数」填。"""
        try:
            v = int(pairs)
        except Exception:                                     # noqa: BLE001
            return
        if 1 <= v <= 65535:
            self._pairs = v

    def verdict(self):
        """最近一次的判定等级（0 正常 / 1 注意 / 2 超差；无数据为 -1）。"""
        return int(self._last.get("level", -1))
