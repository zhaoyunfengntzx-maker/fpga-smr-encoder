"""把网口连续流的 (s, c) 样点**现算**成遥测帧（纯逻辑：无 Qt、无 socket）。

设计约束（改这个文件前先读）
----------------------------
1. 连续流里只有两路 ADC 的 (s, c)，**没有**板上算好的角度、位置、ABZ/UVW 电平。
   所以这里算出来的角度是 `atan2(s, c)`（与板上 CORDIC 同源，但不是同一个数），
   ABZ/UVW/Z 是**按当前配置推导**的电平，不是测出来的 —— 界面必须标明这一点。
2. 全程 numpy 向量化：一次调用处理一批样点；逐点 Python 循环在 10 kHz × 多通道
   时会把收包线程拖死。
3. 角度解回绕不能逐点累加误差：用差分 `wrap180` 再累计，最后一次性量化成
   16 位角度 + 周期计数，与板上 `pos_full = (cycle_cnt << 16) | angle` 一致。
4. 本模块不猜"对时"：时间戳由调用方按帧率给，这里只管数值。

对外接口
--------
`frame_hz_step(fs, frame_hz=FRAME_HZ)`   → 抽取步长（取整，至少 1）
`class FrameSynth(pairs=4, inter=32, div=1, z_index_pairs=2048, z_width=4)`
    `reset()` / `make(s, c, dec=1)` → 帧 dict 列表
`selftest()` / `main(argv)`
"""

from __future__ import annotations

import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import abz as az                                               # noqa: E402

FRAME_HZ = 10000.0
# 静止死区：|f| 低于它就算静止（2048 周期/转时 30 Hz 电 ≈ 0.88 rpm）
STOP_HZ = 30.0          # 板上遥测帧率（连续流模式要"折成"这个帧率喂面板）
ANG_FULL = 65536.0
IO_A, IO_B, IO_Z, IO_U, IO_V, IO_W = 0, 1, 2, 3, 4, 5
_IO_POS = {"a": 0, "b": 1, "z": 2, "u": 3, "v": 4, "w": 5}


def frame_hz_step(fs, frame_hz=FRAME_HZ):
    """连续流采样率 → "每多少点取一帧"。取整且至少 1。"""
    fs = float(fs or 0.0)
    if fs <= 0:
        return 1
    return max(1, int(round(fs / float(frame_hz or FRAME_HZ))))


def _wrap180(deg):
    """把角度差折到 (-180, 180]。"""
    return (deg + 180.0) % 360.0 - 180.0


class FrameSynth:
    """连续流样点 → 遥测帧。有状态：跨批次解回绕、跨批次算 Z。"""

    def __init__(self, pairs=4, inter=32, div=1, z_index_pairs=2048, z_width=4):
        self.pairs = max(1, int(pairs or 4))
        self.inter = max(1, int(inter or 32))
        self.div = max(1, int(div or 1))
        self.z_index_pairs = max(1, int(z_index_pairs or 2048))
        self.z_width = max(0, int(z_width))
        self.reset()

    def reset(self):
        self._deg = None          # 上一次的电角度（度，0..360）
        self._acc = 0.0           # 累计角度（度，可正可负）——用于算周期数
        self.n_frames = 0
        self.dropped = 0

    # ------------------------------------------------------------------ 主入口
    def make(self, s, c, dec=1, phase_deg=None):
        """把一批 (s, c) 变成帧列表。

        s/c：int16 数组（同一时刻的两路 ADC）。dec：抽样步长（连续流抽取 log2
        已在板上做过，这里只做"再抽到 10 kHz"）。

        phase_deg：**绝对相位**（度，可超过 360，可负）。给了就用它，不再自己解
        回绕。网口模式必须给 —— 20 kHz 输入在 10 kHz 抽头上每帧转 2 个多周期，
        只用 `atan2` 的相邻差分解回绕只能得到混叠残差（821 Hz 那个 722.9 Hz）。
        相位由 `RawSpeed.angles_deg()` 在 12.5 MSPS 上解出来。
        """
        s = np.asarray(s)
        c = np.asarray(c)
        n = min(s.size, c.size)
        if n <= 0:
            return []
        dec = max(1, int(dec or 1))
        if dec > 1:
            s = s[::dec]
            c = c[::dec]
            n = s.size
        sf = s.astype(np.float64)
        cf = c.astype(np.float64)

        if phase_deg is not None:
            acc = np.asarray(phase_deg, dtype=float)[:n]
            if acc.size < n:                       # 长度不够就退化成自己解
                phase_deg = None
        if phase_deg is None:
            deg = np.degrees(np.arctan2(sf, cf)) % 360.0
            # ---- 解回绕：先算相邻差分（折到 ±180），再累计
            # 首帧没有"上一个角度"，就拿自己当上一个（差分 0），否则整批都成了 0
            prev = self._deg if self._deg is not None else float(deg[0])
            d = _wrap180(np.diff(np.concatenate(([prev], deg))))
            acc = self._acc + np.cumsum(d)
        else:
            deg = acc % 360.0

        ang16 = np.round(deg / 360.0 * ANG_FULL).astype(np.int64) & 0xFFFF
        cyc = np.floor(acc / 360.0).astype(np.int64) & 0xFFFF
        pos_full = ((cyc << 16) | ang16) & 0xFFFFFFFF

        # ---- 推导电平（不是测出来的：连续流里没有这些位）
        eang = (ang16 * self.pairs) & 0xFFFF
        sec = ((eang * 6) >> 16).astype(np.int64)          # 0…5
        sec = np.clip(sec, 0, 5)
        uvw = np.array([az.SECTOR_UVW[int(k)] for k in sec], dtype=np.int64) \
            if n else np.zeros(0, dtype=np.int64)

        jap = (ang16 * self.inter) & 0xFFFF                # 一个 AB 周期内的相位
        a_lv = (jap >= 32768).astype(np.int64)
        b_lv = (((jap + 16384) & 0xFFFF) >= 32768).astype(np.int64)
        zp = (cyc % self.z_index_pairs) < self.z_width
        z_lv = zp.astype(np.int64)

        s16 = np.clip(s, -32768, 32767).astype(np.int64)
        c16 = np.clip(c, -32768, 32767).astype(np.int64)

        out = []
        for i in range(n):
            st = int(uvw[i])
            io = ((int(a_lv[i]) << IO_A) | (int(b_lv[i]) << IO_B)
                  | (int(z_lv[i]) << IO_Z)
                  | (((st >> 2) & 1) << IO_U) | (((st >> 1) & 1) << IO_V)
                  | ((st & 1) << IO_W))
            ss = int(s16[i])
            cc = int(c16[i])
            out.append({
                "angle": int(ang16[i]),
                "angle_deg": float(deg[i]),
                "s": ss, "c": cc,
                "pos_full": int(pos_full[i]),
                "cycle_cnt": int(cyc[i]),
                "io_state": io,
                "io_flags": 0,
                "io_bits": {"a": int(a_lv[i]), "b": int(b_lv[i]),
                            "z": int(z_lv[i]),
                            "u": (st >> 2) & 1, "v": (st >> 1) & 1, "w": st & 1},
                "io_flag_bits": {},
                "stat": 0,
                "layout": 2,
                "net": True,                    # ★ 标记：这些帧不是串口来的
                # ★ 板子发的 amp_sq 就是 s²+c² 本身（真板实测：s=5535 / c=24949
                #   ⇒ sqrt(653e6)=25555，与界面显示的「幅值 r」一致），所以这里
                #   不能 >>15，否则实时预览的 r 会小 181 倍（实测显示 110）。
                "amp_sq": int(ss * ss + cc * cc),
            })

        self._deg = float(deg[-1])
        self._acc = float(acc[-1])
        self.n_frames += n
        return out


# ---------------------------------------------------------------------- 自检


def tap_phase(s, c, f_hz, tap_hz=FRAME_HZ):
    """给"每 1/tap_hz 抽一个点"的样点算**绝对相位**（度，可负、可超 360）。

    做法：先用每个点自己的 `atan2`（精确），再用粗测速率把"差了几个整圈"补上。
    这比"按平均速率线性外推"稳得多 —— 线性外推在 0.4 s 的窗口里只要速率差 1 Hz
    就会攒出几十度的相位误差，`fit_quadrature` 直接判成拟合失败。

    f_hz 只需要"大概对"（±40% 都行），它只负责选整圈数。
    """
    s = np.asarray(s)
    c = np.asarray(c)
    n = min(s.size, c.size)
    if n <= 0:
        return np.zeros(0)
    ang = np.degrees(np.arctan2(s[:n].astype(float), c[:n].astype(float)))
    if n == 1:
        return ang
    step = 360.0 * float(f_hz or 0.0) / float(tap_hz or FRAME_HZ)
    d = np.diff(ang)
    d = d + 360.0 * np.round((step - d) / 360.0)
    return ang[0] + np.concatenate(([0.0], np.cumsum(d)))


class RawSpeed:
    """从**连续流原始样点**直接测速（10 kHz 遥测对 >5 kHz 输入必然混叠，测不准）。

    为什么不能复用 SpeedEstimator：它读的是 `pos_full`，而 pos_full 来自板上
    10 kHz 的 angle。输入 20 kHz 时每帧转过 2 个多周期，angle 只剩混叠残差
    （20821 Hz 在 10 kHz 采样下显示成 821 Hz，实测界面 722.9 Hz 就是这个）。

    这里在 12.5 MSPS 上先按 `dec` 抽取（默认自动，抽到 ~400 kHz），再
    `atan2(s, c)` + 差分解回绕 → 累计相位。相邻抽取点差 = 2*pi*f/fs*dec，
    20 kHz / 12.5 MSPS / dec=64 ⇒ 0.13 rad，远小于 pi，不会绕错。

    `feed()` 返回的 dict 与 `encoder.SpeedEstimator.snapshot()` 同形，
    可以直接喂 `SpeedPanel.show_snapshot()`。
    """

    def __init__(self, pairs=2048, window_s=1.0, dec=0):
        self.pairs = max(1, int(pairs or 2048))
        self.window_s = max(0.05, float(window_s))
        # dec=0 ⇒ 自动：让"抽取后的采样率"落在 ~400 kHz。固定 64 在 fs=12.5 MSPS
        # 时没问题，但连续流 dec_log2=2 时 fs 只有 3.125 MSPS，64 倍抽完只剩 48.8 kHz
        # —— 21 kHz 输入到了奈奎斯特边上，相位步长 2.7 rad，稍一抖就绕错圈
        # （实测一次读成 2.9 Hz）。所以按 fs 现算。
        self.dec = max(0, int(dec))
        self._clk = time.monotonic
        self.reset()

    def reset(self):
        self.rate_hz = None        # 本块测得的速率（Hz，带符号）
        self._cyc = 0.0            # 累计周期数（带符号）
        self._last_cyc = 0.0
        self._t_last = None
        self._t_now = 0.0          # 我们自己累计的时间轴（秒）
        self._hist = []            # [(t, rate, elapsed)]
        self._n = 0

    def set_pairs(self, pairs):
        self.pairs = max(1, int(pairs or 2048))

    def angles_deg(self, n, tap_hz=FRAME_HZ):
        """粗相位斜坡（只在没有 `tap_phase` 时兜底；正常路径不用它）。"""
        n = int(n)
        if n <= 0:
            return np.zeros(0)
        if self.rate_hz is None:
            return np.zeros(n)
        dt = 1.0 / float(tap_hz or FRAME_HZ)
        k = np.arange(n, dtype=float) - (n - 1)
        return self._last_cyc * 360.0 + self.rate_hz * 360.0 * dt * k

    def feed(self, s, c, fs_hz, dt=None):
        """喂一块原始样点（同一时刻、等间隔），返回 snapshot dict（数据不足时 ok=False）。

        ★ 速率只在本块内部算（块内首尾相位差 ÷ 块内时长），不跨块累加相位：
          每 tick 拿到的 `snapshot()` 是**"最近 N 点"**，相邻两次会重叠，
          跨块累加会把重叠段算两遍（实测转速掉到 0.6 Hz）。圈数改用
          "速率 × 真实经过时间"积分，跟重叠无关。
        """
        fs = float(fs_hz or 0.0)
        n = min(len(s), len(c))
        if fs <= 0 or n < 256:
            return {"ok": False, "note": "样点不足（%d 点）" % n, "span": 0.0}
        step = self.dec or max(1, int(round(fs / 4.0e5)))
        step = max(1, min(step, max(1, n // 8)))
        ss = np.asarray(s[:n], dtype=float)[::step]
        cc = np.asarray(c[:n], dtype=float)[::step]
        if ss.size < 8:
            return {"ok": False, "note": "样点不足（%d 点）" % n, "span": 0.0}
        ang = np.arctan2(ss, cc)
        d = np.diff(ang)
        d = (d + np.pi) % (2.0 * np.pi) - np.pi       # 折到 ±pi
        d = d[np.isfinite(d)]
        if d.size < 4:
            return {"ok": False, "note": "样点不可用", "span": 0.0}
        # 稳健：用中位数当每步相位（噪声/个别跳变不影响）
        step_rad = float(np.median(d))
        spread = float(np.std(d))
        dt_block = step / fs
        # ★ 上板实测：网口丢包时缓冲里会出现"跨缺口"的相邻点，整块的相位差就成了
        #   一堆随机值（中位数 0、std 0.27），直接算会读出 0.6 Hz / 88 Hz 这种数。
        #   判据：相位差的离散度不能和步长本身一个量级。不可信的块整块丢掉，
        #   沿用上一次的速率（圈数照常积分）。
        reliable = (abs(step_rad) > 1e-6 and spread < 0.30 * abs(step_rad) + 0.01)
        # ★ 静止死区（上板实测）：轴不转时 s,c 只剩几 LSB 的噪声，angle 噪声 ~1e-4 rad，
        #   抽取后 dt 只有几微秒 ⇒ 噪声被放大成几十 Hz，界面显示 7~71 Hz 乱跳、
        #   圈数还会慢慢漂。2048 周期/转时 30 Hz 电 ≈ 0.88 rpm，低于它一律当静止。
        if reliable and abs(step_rad) < 2.0 * np.pi * dt_block * STOP_HZ:
            step_rad = 0.0
        if not reliable:
            if self.rate_hz is None:
                return {"ok": False, "note": "等信号（本块相位不连续）", "span": 0.0}
            step_rad = self.rate_hz * 2.0 * np.pi * dt_block
        rate = step_rad / (2.0 * np.pi * dt_block)     # 周期/秒 = Hz
        if reliable:
            self.rate_hz = rate

        now = self._clk()
        if self._t_last is None:
            self._t_last = now
        elapsed = dt if dt is not None else max(0.0, now - self._t_last)
        self._t_last = now
        if elapsed <= 0.0:
            elapsed = dt_block                # 同一瞬间被连调两次：按块长算，别丢圈数
        self._t_now += elapsed
        self._hist.append((self._t_now, rate, elapsed))
        while len(self._hist) > 2 and (self._t_now - self._hist[0][0]) > self.window_s:
            self._hist.pop(0)
        # 圈数：按"速率 × 经过时间"积（重叠块不会重复计）
        self._cyc += rate * elapsed
        self._last_cyc = self._cyc

        # 显示用速率：窗口内按时间加权平均（抖动小、又不慢）
        t_lo = self._hist[0][0]
        span = self._t_now - t_lo
        if span < 0.05:
            return {"ok": False, "note": "等数据（%.2f s）" % span, "span": span}
        w = sum(h[2] for h in self._hist[1:]) or 1e-9
        f_hz = sum(h[1] * h[2] for h in self._hist[1:]) / w
        rpm = 60.0 * f_hz / self.pairs
        return {
            "ok": True,
            "stopped": abs(f_hz) < STOP_HZ,
            "f_abs": abs(f_hz),
            "rpm_abs": abs(rpm),
            "turns": self._cyc / self.pairs,
            "cycles": self._cyc,
            "direction": "反转" if f_hz < 0 else "正转",
            "warn": "",
            "note": "网口原始样点直接测速（%.2f MSPS ×1/%d 抽取）" % (fs / 1e6, step),
            "span": span,
        }


def selftest():
    fails = []

    def ck(name, cond, detail=""):
        if not cond:
            fails.append("%s %s" % (name, detail))
            print("FAIL %s %s" % (name, detail))
        else:
            print("  ok  %s" % name)

    ck("步长：25 MSPS → 2500 点/帧", frame_hz_step(25e6) == 2500,
       str(frame_hz_step(25e6)))
    ck("步长：3.125 MSPS → 312（312.5 取偶）", frame_hz_step(3.125e6) == 312,
       str(frame_hz_step(3.125e6)))
    ck("步长：0 → 1（不炸）", frame_hz_step(0) == 1)

    # 1 kHz 正弦对，25 MSPS，抽到 10 kHz
    fs = 25e6
    f = 1000.0
    step = frame_hz_step(fs)
    n_raw = step * 400
    t = np.arange(n_raw) / fs
    s = (20000.0 * np.sin(2 * np.pi * f * t)).astype(np.int16)
    c = (20000.0 * np.cos(2 * np.pi * f * t)).astype(np.int16)
    syn = FrameSynth(pairs=4, inter=32)
    frames = syn.make(s, c, step)
    ck("帧数 = 400（10 kHz × 40 ms）", len(frames) == 400, str(len(frames)))
    if len(frames) == 400:
        dd = [fr["angle_deg"] for fr in frames]
        ck("角度首帧 ≈ 0°", abs(((dd[0] + 180) % 360) - 180) < 1.0, "%.2f" % dd[0])
        ck("每帧步长 ≈ 36°（1 kHz / 10 kHz）",
           abs(((dd[1] - dd[0] + 180) % 360 - 180) - 36.0) < 0.5,
           "%.2f" % ((dd[1] - dd[0] + 180) % 360 - 180))
        ck("pos_full 每帧 +6553.6 计数",
           abs((frames[1]["pos_full"] - frames[0]["pos_full"]) - 6553.6) < 2,
           str(frames[1]["pos_full"] - frames[0]["pos_full"]))
        # Z = "周期计数落在 0..z_width-1"：40 ms 转了 4 圈，所以只有前 4 个
        # 周期的帧才有 Z，之后必须全是 0。
        _nz = sum(fr["io_bits"]["z"] for fr in frames)
        _bad = sum(1 for fr in frames
                   if fr["io_bits"]["z"] and fr["cycle_cnt"] >= 4)
        ck("Z 只在每转开头（前 4 个周期内）", _bad == 0, "%d 帧错" % _bad)
        ck("Z 有出现（前 4 圈共 40 帧）", 30 <= _nz <= 45, str(_nz))

    # 慢一点再看电平质量：1 kHz × 10 kHz 采样时 A 每帧走 3.2 个周期，
    # 抽样本身就会让占空比失真 —— 这不是算法问题，所以用 100 Hz 检查
    f2 = 100.0
    n2 = step * 600
    t2 = np.arange(n2) / fs
    s2 = (20000.0 * np.sin(2 * np.pi * f2 * t2)).astype(np.int16)
    c2 = (20000.0 * np.cos(2 * np.pi * f2 * t2)).astype(np.int16)
    fr2 = FrameSynth(pairs=4, inter=32).make(s2, c2, step)
    ck("慢速：UVW 六个状态都出现过",
       len({(fr["io_bits"]["u"], fr["io_bits"]["v"], fr["io_bits"]["w"])
            for fr in fr2}) == 6,
       str(len({(fr["io_bits"]["u"], fr["io_bits"]["v"], fr["io_bits"]["w"])
                for fr in fr2})))
    _duty = float(np.mean([fr["io_bits"]["a"] for fr in fr2]))
    ck("慢速：A 路占空比 ≈ 50%", abs(_duty - 0.5) < 0.06, "%.3f" % _duty)
    _duty = float(np.mean([fr["io_bits"]["b"] for fr in fr2]))
    ck("慢速：B 路占空比 ≈ 50%", abs(_duty - 0.5) < 0.06, "%.3f" % _duty)

    # 反向旋转：角度应递减、周期计数递减
    syn2 = FrameSynth(pairs=4, inter=32)
    frames2 = syn2.make(s[::-1].copy(), c[::-1].copy(), step)
    # 反向时 pos_full 是 32 位无符号，(a-b) 会绕回；用有符号差判断方向
    _d = (frames2[1]["pos_full"] - frames2[0]["pos_full"] + (1 << 31)) \
        % (1 << 32) - (1 << 31)
    ck("反向：pos_full 每帧为负增量", _d < 0, str(_d))

    # 空输入
    ck("空输入返回空表", FrameSynth().make([], []) == [])

    # ---- RawSpeed：20.8 kHz 输入在 12.5 MSPS 上必须测准（10 kHz 遥测在这里只剩混叠）
    _fs = 12.5e6
    _t = np.arange(int(_fs * 0.02)) / _fs
    _ph = 2 * np.pi * 20820.0 * _t + 0.3
    rs = RawSpeed(pairs=2048)
    _r = {}
    for _ in range(8):                     # 喂 8 块 = 0.16 s，凑过 0.05 s 窗口
        _r = rs.feed(20000.0 * np.sin(_ph), 20000.0 * np.cos(_ph), _fs, dt=0.02)
    ck("RawSpeed 有结果", _r.get("ok") is True, str(_r.get("note")))
    if _r.get("ok"):
        ck("RawSpeed 频率 20.82 kHz", abs(_r["f_abs"] - 20820.0) < 60.0,
           "%.1f" % _r["f_abs"])
        ck("RawSpeed 转速 ≈ 610 rpm", abs(_r["rpm_abs"] - 60.0 * 20820.0 / 2048.0) < 2.0,
           "%.1f" % _r["rpm_abs"])
    rs2 = RawSpeed(pairs=2048)
    _r2 = {}
    for _ in range(8):
        _r2 = rs2.feed(20000.0 * np.sin(-_ph), 20000.0 * np.cos(-_ph), _fs, dt=0.02)
    if _r2.get("ok"):
        ck("RawSpeed 反转方向", _r2["direction"] == "反转", _r2["direction"])
        ck("RawSpeed 累计圈数为负", _r2["turns"] < 0, "%.3f" % _r2["turns"])

    # ---- tap_phase：21 kHz 在 10 kHz 抽头上，靠粗速率解整圈，拟合残差要小
    _n = 4096
    _t2 = np.arange(_n) / 10000.0
    _f2 = 21253.0
    _s2 = 22000.0 * np.sin(2 * np.pi * _f2 * _t2 + 0.4)
    _c2 = 22000.0 * np.cos(2 * np.pi * _f2 * _t2 + 0.4)
    _ph2 = tap_phase(_s2, _c2, _f2)
    _res = np.max(np.abs((_ph2 - _ph2[0]) - 360.0 * _f2 * _t2))
    ck("tap_phase 与真值差 < 1°", _res < 1.0, "%.3f" % _res)
    _ph3 = tap_phase(_s2, _c2, _f2 * 1.2)          # 粗速率差 20% 也要能解
    _res3 = np.max(np.abs((_ph3 - _ph3[0]) - 360.0 * _f2 * _t2))
    ck("tap_phase 粗速率差 20% 仍可解", _res3 < 1.0, "%.3f" % _res3)

    print("\n%d 项失败" % len(fails) if fails else "\n全部通过")
    return 0 if not fails else 1


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--selftest" in argv:
        return selftest()
    print("用法：python host/net_frames.py --selftest")
    return 2


if __name__ == "__main__":
    sys.exit(main())
