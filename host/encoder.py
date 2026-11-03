"""输入频率 / 机械转速 / 方向 / 累计圈数 的估算（纯逻辑，不依赖 Qt 与串口）。

物理口径（依据 rtl/，别凭直觉改）
--------------------------------
* 遥测帧里 `pos_full[31:0]` 是 22 位单圈位置 `{cycle_cnt[5:0], angle[15:0]}`
  （rtl/enc_top.v:114 `ST_BITS_L = POLE_BITS + AW` = 6 + 16；:763
  `biss_st = {10'b0, cycle_cnt[POLE_BITS-1:0], angle}`）。
  一个输入信号周期 = 65536 LSB，pos_full 每 2^6 = 64 个输入周期回绕一次
  ⇒ 解回绕必须按**模 2^22**（不是 2^16），否则每 64 个周期就错一次。
* ★ 只拿 16 位 `angle` 求导会**混叠**：帧率 10 kHz ⇒ 输入超过 5 kHz 后角度看起来几乎
  静止（实测 20 kHz 输入时角度每帧只抖 ±6 LSB，看着像 0.1 Hz —— 这就是板上真实工况）。
  但它的**小数残差**（mod 1 个电周期）是准的，用来给整数部分精修。
* ★ 频率主口径 = 「整数电周期数 + 小数残差」合成：
      int_part = round(窗口内 pos_full 增量 ÷ 收到的帧数)   # 位置口径，抗丢帧
      frac     = 窗口内 16 位角度增量均值（mod 1 个电周期）  # 角度口径，丢帧不影响它
      f_in     = (int_part + frac) × 10000 Hz
  为什么不能只用"位置增量 ÷ 帧数时钟"：CH340 链路实测丢 ~0.7% 的帧（约 0.3% 被 XOR
  校验抓到、约 0.4% 被重同步吞掉），少算帧数就把频率抬高约 0.8%
  （实测 20 156 Hz，真值 20 000 Hz）。为什么不能只用角度：整数部分被混叠吃掉了。
  帧数时钟口径（含 n_bad 丢帧补偿）与墙上时间口径留作交叉校验：与合成值差超过 2%
  说明丢帧太多，退回去用帧数时钟口径并报警。
* 量程 ±32 个电周期/帧 ⇒ ±320 kHz。|小数残差| 接近 0.5 时（每帧约半个电周期）整数
  部分可能判错，会给出告警。
* 机械转速 RPM = 60 × f_in / 每转正弦周期数（界面那个"极对数"字段）。
  ★ 这个字段是**每转正弦周期数**，不是电机极对数 P —— 见 docs/20 §12。
    本机编码器 EI58C9.25-2048 是 **2048 周期/转**，所以填 2048；
    填 4（板上 0x0100 的复位值，那是给 uv w 生成用的电机极对数）
    或填 64（旧磁环 demo 的口径）都会差 512 倍 / 32 倍 —— 转速看起来"完全不对"。
  ★ 位置口径：pos_full = {cycle_cnt[15:0], angle[15:0]}，即 65536 计数/正弦周期。
    计数器在 2^16 个周期处回绕（本机 EI58 位流实测），因此解回绕按 22 位仍然安全：
    单帧最多 ±32 个周期（2^21 计数），远小于任何回绕周期。
* 累计圈数 = 累计电周期数 / 每转正弦周期数，从"本次连接"开始算（不是掉电保存的绝对值）。

用法
----
    est = SpeedEstimator(pairs=4)
    est.feed(帧列表, t_now)      # 界面每 100 ms 喂一批
    snap = est.snapshot()         # 或直接用 feed() 的返回值
"""

import collections
import math
import sys
import time

FRAME_HZ = 10000.0          # 板上遥测帧率（rtl/uart_scope.v SAMPLE_DIV=5000 @50 MHz）
FRAME_DT = 1.0 / FRAME_HZ   # 每帧固定 100 µs（板子时钟锁死，不随上位机抖动）
POS_BITS = 22               # pos_full = {cycle_cnt[5:0], angle[15:0]}
POS_MOD = 1 << POS_BITS
MAX_STEP = POS_MOD >> 1     # 单帧最大可信步长 = ±32 个电周期
MAX_HZ = (MAX_STEP / 65536.0) * FRAME_HZ     # = ±320 kHz 量程
# 每转正弦周期数（界面"极对数"字段的真实含义，docs/20 §12）
CYCLES_EI58 = 2048          # EI58C9.25-2048SC5N4：2048 周期/转（本机在用）
CYCLES_LEGACY = 64          # 旧磁环 demo / 板上 Z 索引口径（POLE_BITS=6）
DEFAULT_PAIRS = CYCLES_EI58  # ★ 默认按本机编码器；旧磁环改成 CYCLES_LEGACY
Z_INDEX_PAIRS = CYCLES_EI58  # 板上 Z 索引口径；EI58 位流是每 2048 个输入周期一个索引
PAIRS_CHOICES = (CYCLES_EI58, CYCLES_LEGACY, 4096, 1024)


def unwrap16(delta):
    """把 16 位无符号差值解成真正的最短走向差（-32768..32767）。"""
    if delta > 32767:
        delta -= 65536
    elif delta < -32768:
        delta += 65536
    return delta


def unwrap_pos(delta):
    """把 22 位单圈位置的差值解成最短走向差（-2^21..2^21-1，即 ±32 个电周期）。"""
    delta &= (POS_MOD - 1)
    if delta > MAX_STEP:
        delta -= POS_MOD
    return delta


def rpm_of(f_in, pairs):
    """机械转速（RPM）。f_in 为 None 或 pairs<=0 时返回 None。"""
    if f_in is None or not pairs or pairs <= 0:
        return None
    return 60.0 * float(f_in) / float(pairs)


def turns_of(cycles, pairs):
    """累计圈数（可为负）。"""
    if cycles is None or not pairs or pairs <= 0:
        return None
    return float(cycles) / float(pairs)


class SpeedEstimator:
    """从连续的遥测帧估算速度。feed() 每批调用一次，snapshot() 取结果。"""

    def __init__(self, pairs=DEFAULT_PAIRS, window_s=1.0, stale_s=1.0):
        self.pairs = int(pairs) if pairs else DEFAULT_PAIRS
        self.window_s = float(window_s)
        self.stale_s = float(stale_s)
        self.reset()

    # ------------------------------------------------------------- 状态
    def reset(self):
        """断开/重连时清零（累计圈数从 0 重新起算）。"""
        self._prev_pos = None       # 上一帧的 pos_full（22 位单圈位置，主口径）
        self._prev_angle = None     # 上一帧的 16 位 angle（只用来判断有没有混叠）
        self._cycles = 0.0          # pos_full 解回绕累计的电周期数（带符号）
        self._cycles_ang = 0.0      # 只由 angle 累计（高速时混叠，留给提示用）
        self._fast_frames = 0       # 单帧走过 ≥1 个电周期的帧数
        self._clock = 0             # 经过的帧时隙数（收到的帧 + 校验错的帧）＝板上时间基准
        self._hist = collections.deque()     # (t, cycles, cycles_ang, n, clock)
        self._t_last = None
        self._dir_bit = None
        self._n = 0
        self._gap = False
        self._use_clock = False        # 当前是否用"帧数时钟"口径（带迟滞）
        self._gap_t = 0.0              # 最近一次断流的时刻（用于自动清断流提示）

    def set_pairs(self, pairs):
        if pairs:
            self.pairs = int(pairs)

    # ------------------------------------------------------------- 喂数据
    def feed(self, frames, t_now=None, n_bad=0):
        """喂一批帧（按时间先后）。返回 snapshot（dict）。

        n_bad = 本批里校验失败被丢掉的帧数（worker 的 crc_err 增量）。板子每 100 µs
        出一帧，收到的帧 + 丢掉的帧 = 板上经过的时间 ⇒ 用它当计时基准比上位机墙上时间准。
        """
        t_now = time.monotonic() if t_now is None else float(t_now)
        if not frames:
            return self.snapshot(t_now)

        # 断流（拔线、界面卡顿）后重新起算，避免把大间隔算成超高转速
        if self._t_last is not None and (t_now - self._t_last) > self.stale_s:
            self.reset()
            self._gap = True
            self._gap_t = t_now

        for f in frames:
            p = f.get("pos_full")
            if p is not None:
                if self._prev_pos is not None:
                    step = unwrap_pos(p - self._prev_pos) / 65536.0
                    self._cycles += step
                    if abs(step) >= 1.0:
                        self._fast_frames += 1
                self._prev_pos = p
            a = f.get("angle")
            if a is not None:
                if self._prev_angle is not None:
                    self._cycles_ang += unwrap16(a - self._prev_angle) / 65536.0
                self._prev_angle = a
            self._n += 1

        # 方向位取"本批最后一帧里带了 io_bits 的"：v1 帧没有 io_bits，直接取 frames[-1]
        # 会让方向瞬间变 None（面板闪一下空白再恢复）
        for f in reversed(frames):
            b = f.get("io_bits")
            if isinstance(b, dict) and "dir" in b:
                self._dir_bit = b.get("dir")
                break
        self._clock += len(frames) + max(0, int(n_bad))
        self._hist.append((t_now, self._cycles, self._cycles_ang, self._n, self._clock))
        horizon = self.window_s * 2.0
        while len(self._hist) > 2 and (t_now - self._hist[0][0]) > horizon:
            self._hist.popleft()
        self._t_last = t_now
        return self.snapshot(t_now)

    # ------------------------------------------------------------- 结果
    def snapshot(self, t_now=None):
        t_now = time.monotonic() if t_now is None else float(t_now)
        s = {
            "pairs": self.pairs,
            "frames": self._n,
            "cycles": self._cycles,
            "turns": turns_of(self._cycles, self.pairs),
            "f_in": None,          # 主口径：整数电周期数（位置）+ 小数残差（角度）合成
            "f_abs": None,         # 绝对值（显示用）
            "f_fine": None,        # 与 f_in 同值，留作对照
            "f_clock": None,       # 帧数时钟口径（含 n_bad 丢帧补偿）
            "f_wall": None,        # 上位机墙上时间口径（USB 批量到达会抖，只作对照）
            "f_ang": None,         # 只看 16 位角度算的频率（>5 kHz 混叠，只有小数残差可信）
            "int_part": None,      # 每帧整数电周期数
            "frac": None,          # 每帧小数残差（−0.5…+0.5 个电周期）
            "loss_pct": None,      # 估算的链路丢帧率（%）＝1 − 收到帧/帧时隙
            "resid_pct": None,     # 取整残差（诊断用，不是丢帧率）
            "slots": None,         # 窗口内的帧时隙数（收到 + 丢掉的）
            "use_clock": False,    # 本窗口是否用了帧数时钟口径
            "rpm": None,
            "rpm_abs": None,
            "direction": None,
            "span": None,
            "ok": False,
            "note": "",
            "warn": "",
        }
        if self._prev_pos is None or len(self._hist) < 2:
            s["note"] = "等待数据…"
            return s

        t0, c0, a0, n0, k0 = self._oldest_in_window(t_now)
        dt_wall = t_now - t0
        dt_clock = max(1, self._clock - k0) * FRAME_DT     # 帧时隙（收到的帧 + n_bad）
        if dt_wall < 0.05 or dt_clock < 0.05:
            s["note"] = "采样窗口太短，稍等…"
            return s

        dcyc = self._cycles - c0                 # 窗口内位置增量（电周期）
        dn = max(1, self._n - n0)                # 窗口内收到的帧数
        mean_pos = dcyc / dn                     # 每帧平均电周期（丢帧会让它偏高 <1%）

        # --- 主口径：整数部分取位置口径（抗丢帧），小数残差取角度口径（丢帧不影响）---
        int_part = int(math.floor(mean_pos + 0.5))
        frac = (self._cycles_ang - a0) / dn      # 每帧小数残差，落在 −0.5…+0.5
        f_fine = (int_part + frac) * FRAME_HZ

        # --- 两个交叉校验口径 ---
        f_clock = dcyc / dt_clock                # 帧数时钟（含 n_bad 丢帧补偿）
        f_wall = dcyc / dt_wall                  # 上位机墙上时间
        f_ang = (self._cycles_ang - a0) / dt_clock   # 只看一个周期内的角度

        # 链路丢帧率 = 1 − 收到帧数 / 已经过的帧时隙数（时隙 = 收到的帧 + 校验错/重同步
        # 丢掉的帧）。★ 原来这里是 |mean_pos|/|int_part| − 1：那只是"取整残差"，跟收了多少
        # 帧毫无关系 —— 零丢帧的 14000 Hz 也会报"链路丢帧约 40%"，而真丢 35% 时只报 7.7%，
        # 转速面板还把它染成告警色（真踩过）。
        slots = max(1, self._clock - k0)
        loss = max(0.0, 1.0 - dn / float(slots))
        # 取整残差（只在诊断/告警判据里用，不再当丢帧率上报）
        resid = abs(mean_pos - int_part)

        # 口径选择：默认用「整数部分（位置口径）+ 小数残差（角度口径）」——它不依赖帧计数，
        # 上位机卡顿影响不到。但真丢帧超过 2% 时这个口径有系统性偏差（实测真丢 4% 时读数低
        # 1.8%），所以丢帧率超过 3%（退出阈值 1.5%，迟滞避免来回跳）时改用带 n_bad 补偿的
        # 帧数时钟口径。★ 帧数时钟口径必须先验有效（否则"没有 pos_full / 没收到帧"会用它
        # 把好读数覆盖成 0）。
        tol = max(1.0, 0.02 * abs(f_fine))
        clock_ok = ((self._clock - k0) > 0 and abs(dcyc) > 1e-9
                    and math.isfinite(f_clock) and f_clock > 0.0)
        if not clock_ok:
            self._use_clock = False
        elif self._use_clock:
            # ★ 2026-10-17 全面自查修：迟滞的"出口"以前只写在注释里、代码里没有
            #   ⇒ 一次丢帧事件后整场会话锁在帧数时钟口径（丢掉了 fine 口径不依赖
            #   接收抖动的优点）。这里补上出口分支。
            if loss < 0.015:
                self._use_clock = False
        elif loss > 0.03:
            self._use_clock = True
        fallback = bool(self._use_clock)
        f = f_clock if fallback else f_fine
        rpm = rpm_of(f, self.pairs)
        s.update(f_in=f, f_abs=abs(f), f_fine=f_fine, f_clock=f_clock, f_wall=f_wall,
                 f_ang=f_ang, int_part=int_part, frac=frac,
                 loss_pct=loss * 100.0, resid_pct=resid * 100.0, slots=slots,
                 rpm=rpm,
                 rpm_abs=abs(rpm) if rpm else 0.0,
                 use_clock=fallback,
                 # 平滑窗长度 = 这个窗口真实跨越的时间（原来 (dcyc/int_part)·FRAME_DT 只有
                 # 每帧步进接近整数时才等于真实窗长，14000 Hz 时会显示成 1.4 s）
                 span=dt_clock if fallback else dt_wall, ok=True)

        notes = []
        if (not fallback) and abs(f) >= 1000.0 and abs(f_ang) < 0.2 * abs(f):
            notes.append("单看 16 位角度只有 %.2f Hz（高速混叠），本值由「整数电周期数 + "
                         "角度残差」合成" % f_ang)
        if abs(mean_pos) >= 1.0:
            notes.append("每帧平均走 %.2f 个电周期" % mean_pos)
        if abs(loss) > 0.002:
            notes.append("链路丢帧约 %.2f%%（校验错 + 重同步吞掉的帧；真正静默丢帧要另算）"
                         % (loss * 100.0))
        if abs(f) > 1.0 and abs(f_wall - f) > max(1.0, 0.03 * abs(f)):
            notes.append("上位机计时口径差 %.1f Hz（USB 批量到达会抖，读数以「%s」口径为准）"
                         % (f_wall - f, "帧数时钟" if fallback else "整数+残差"))
        if self._gap:
            # 断流提示只在"窗口里还含着那段断流"时有意义：过了一个平滑窗就清掉，
            # 否则"中间断过数据"会永久挂在读数说明里
            if (t_now - self._gap_t) > self.window_s * 2.0:
                self._gap = False
            else:
                notes.append("中间断过数据，累计圈数已重新起算")
        s["note"] = "；".join(notes)

        warns = []
        if self._dir_bit is not None:
            s["direction"] = "正转" if self._dir_bit else "反转"
            if abs(f) > 0.5:
                going_up = f > 0
                same = (going_up and bool(self._dir_bit)) or \
                       ((not going_up) and not self._dir_bit)
                if not same:
                    warns.append("方向位与位置走向不一致（可能正在换向；也可能是已超过 "
                                 "±%.0f Hz 量程上限、位置口径混叠）" % MAX_HZ)
        if abs(f) > MAX_HZ * 0.85:
            # ★ 超过量程后位置口径会折返（340 kHz 会读成 −300 kHz、量值反而"在范围内"），
            #   所以把阈值放到 85% 并说明折返，别等越界才提示（审计发现）
            warns.append("接近 ±%.0f Hz 量程上限（再高会折返成反方向读数，量值看不出越界）"
                         % MAX_HZ)
        if abs(resid) > 0.40 and abs(mean_pos) >= 0.5:
            warns.append("每帧位置增量约 %.2f 个电周期（小数部分接近半个周期），"
                         "整数部分可能判错" % mean_pos)
        if abs(loss) > 0.25:
            warns.append("链路丢帧约 %.0f%%，整数电周期数可能判错，读数仅供参考"
                         % (loss * 100.0))
        if abs(f_fine - f_clock) > tol:
            if fallback:
                warns.append("两种口径差 %.0f Hz；本窗口链路丢帧约 %.1f%%，读数已改用"
                             "带丢帧补偿的帧数时钟口径" % (f_fine - f_clock, loss * 100.0))
            else:
                warns.append("帧数时钟口径差 %.1f Hz（丢帧记账或上位机卡顿所致，读数仍用"
                             "「整数+残差」口径）" % (f_fine - f_clock))
        if not warns and dt_wall > dt_clock * 1.05 + 0.02:
            warns.append("上位机接收比板子慢 %.0f%%（缓冲积压，读数以「整数+残差」口径为准）"
                         % ((dt_wall / dt_clock - 1.0) * 100.0))
        s["warn"] = "；".join(warns)
        return s

    def _oldest_in_window(self, t_now):
        """取窗口内最老的一个采样点；窗口内不足两个时就取最老的。

        返回 (t, cycles, cycles_ang, n, clock) 五元组。
        """
        for sample in self._hist:
            if (t_now - sample[0]) <= self.window_s:
                return sample
        return self._hist[0]


# ---------------------------------------------------------------------------
# 自检（离线）：python host\encoder.py --selftest
# ---------------------------------------------------------------------------
def synth(f_hz, n, dt=1e-4, start=0.0):
    """造 n 帧理想数据（按板上的真实口径）。

    pos_full 是 22 位单圈位置 `{cycle_cnt[5:0], angle[15:0]}`，每 64 个电周期回绕一次；
    dt 默认 1e-4（板子 10 kHz 帧率）。f_hz 为负 = 反转。
    """
    frames = []
    pos = float(start)
    for _ in range(n):
        pos += f_hz * dt
        a = int(round((pos % 1.0) * 65536.0)) & 0xFFFF
        cyc = int(pos // 1.0)                  # 累计电周期数（可负）
        c = cyc & 0x3F                         # 板上 cycle_cnt 只有 6 位
        pf = (c << 16) | a                     # 22 位单圈位置
        frames.append({"angle": a,
                       "pos_full": pf,
                       "cycle_cnt": c - 64 if c > 31 else c,
                       "io_bits": {"dir": 1 if f_hz >= 0 else 0}})
    return frames


def _feed_batches(est, frames, per_batch=1000, t0=1000.0, dt=1e-4):
    snap = None
    for i in range(0, len(frames), per_batch):
        k = i // per_batch + 1
        snap = est.feed(frames[i:i + per_batch], t_now=t0 + k * per_batch * dt)
    return snap


def selftest():
    ok = True
    FR = sys.stdout

    # 1) 正向 12.5 Hz：2.2 秒
    est = SpeedEstimator(pairs=4)
    snap = _feed_batches(est, synth(12.5, 22000))
    good = snap["ok"] and abs(snap["f_abs"] - 12.5) < 0.1 and \
        abs(snap["rpm_abs"] - 187.5) < 2.0 and \
        abs(snap["turns"] - 12.5 * 2.2 / 4.0) < 0.3 and snap["direction"] == "正转"
    ok &= good
    print("[1] 正向 12.5 Hz  f=%.4f Hz  rpm=%.2f  圈数=%.3f  方向=%s  %s"
          % (snap["f_abs"] or 0, snap["rpm_abs"] or 0, snap["turns"] or 0,
             snap["direction"], "PASS" if good else "FAIL"), file=FR)

    # 2) 反向 8 Hz
    est = SpeedEstimator(pairs=4)
    snap = _feed_batches(est, synth(-8.0, 22000))
    good = snap["ok"] and abs(snap["f_abs"] - 8.0) < 0.1 and \
        snap["direction"] == "反转" and snap["turns"] < 0
    ok &= good
    print("[2] 反向 8 Hz     f=%.4f Hz  方向=%s  圈数=%.3f  %s"
          % (snap["f_abs"] or 0, snap["direction"], snap["turns"] or 0,
             "PASS" if good else "FAIL"), file=FR)

    # 3) 每转周期数换算：同样的 12.5 Hz，填 64 应是 60*12.5/64 = 11.72 RPM
    est = SpeedEstimator(pairs=CYCLES_LEGACY)
    snap = _feed_batches(est, synth(12.5, 22000))
    good = abs(snap["rpm_abs"] - 60.0 * 12.5 / 64.0) < 0.2
    ok &= good
    print("[3] 每转 64 周期 rpm=%.2f（应 %.2f）  %s"
          % (snap["rpm_abs"] or 0, 60.0 * 12.5 / 64.0, "PASS" if good else "FAIL"), file=FR)

    # 4) 断流后重新起算：停 3 秒再续，频率必须按断流后的窗口算（不是除以 3 秒）
    est = SpeedEstimator(pairs=4)
    est.feed(synth(9.0, 2000), t_now=1000.0)
    est.feed(synth(9.0, 2000, start=1.8), t_now=1003.0)      # 停 3 秒 → 清历史
    snap = est.feed(synth(9.0, 2000, start=3.6), t_now=1003.2)
    good = "重新起算" in (snap["note"] or "") and \
        snap["f_abs"] is not None and abs(snap["f_abs"] - 9.0) < 0.5
    ok &= good
    print("[4] 断流重算    note=%s  f=%.3f Hz  %s"
          % (snap["note"], snap["f_abs"] or 0, "PASS" if good else "FAIL"), file=FR)

    # 5) ★板上真实工况：输入 20 kHz（每帧走 2 个电周期）。16 位角度在 10 kHz 采样下会混叠，
    #    必须靠 pos_full 才读得对 —— 这就是 S2 排查出来的那个坑。
    est = SpeedEstimator(pairs=4)
    snap = _feed_batches(est, synth(20000.0, 22000))
    good = snap["ok"] and abs(snap["f_abs"] - 20000.0) < 200.0 and \
        abs(snap["f_ang"]) < 100.0 and "混叠" in (snap["note"] or "")
    ok &= good
    print("[5] 20 kHz 输入   f=%.1f Hz（只看角度只有 %.2f Hz，已混叠）  %s"
          % (snap["f_abs"] or 0, snap["f_ang"] or 0, "PASS" if good else "FAIL"), file=FR)

    # 6) 接近 ±320 kHz 量程上限要报警
    est = SpeedEstimator(pairs=4)
    snap = _feed_batches(est, synth(310000.0, 22000))
    good = snap["ok"] and abs(snap["f_abs"] - 310000.0) < 5000.0 and bool(snap["warn"])
    ok &= good
    print("[6] 接近量程告警 f=%.0f Hz  warn=%s  %s"
          % (snap["f_abs"] or 0, snap["warn"], "PASS" if good else "FAIL"), file=FR)

    # 7) 上位机卡顿/丢帧：帧数还是 10 kHz，但墙上时间被拉长 ⇒ 两个口径打架要报警
    est = SpeedEstimator(pairs=4)
    frs = synth(5000.0, 11000)
    snap = None
    for i in range(0, 11000, 1000):
        snap = est.feed(frs[i:i + 1000], t_now=1000.0 + (i // 1000 + 1) * 0.2)
    good = bool(snap["warn"])
    ok &= good
    print("[7] 接收慢告警   f=%.0f Hz（墙上时间口径 %.0f Hz）  warn=%s  %s"
          % (snap["f_abs"] or 0, snap["f_wall"] or 0, snap["warn"],
             "PASS" if good else "FAIL"), file=FR)

    # 8) ★丢帧补偿：每收 1 帧就丢 1 帧（n_bad=1）。此时"粗+精"口径会把 4 个电周期/帧
    #    误当成 40 kHz，交叉校验发现对不上 ⇒ 退回帧数时钟口径，仍给出正确的 20 kHz。
    est = SpeedEstimator(pairs=4)
    full = synth(20000.0, 22000)
    kept = full[::2]                       # 只喂一半的帧
    snap = None
    for i in range(0, len(kept), 500):
        snap = est.feed(kept[i:i + 500], t_now=1000.0 + (i + 500) * 1e-4, n_bad=500)
    good = snap["ok"] and abs(snap["f_abs"] - 20000.0) < 400.0 and bool(snap["warn"])
    ok &= good
    print("[8] 丢帧补偿     f=%.0f Hz（粗+精口径 %s，已交叉校验退回）  warn=%s  %s"
          % (snap["f_abs"] or 0,
             ("%.0f Hz" % snap["f_fine"]) if snap["f_fine"] else "-",
             snap["warn"], "PASS" if good else "FAIL"), file=FR)

    # 9) ★零丢帧时不许报"链路丢帧"：真丢帧率必须是"1 − 收到帧/帧时隙"，不能拿取整残差
    #    冒充（老实现下 12345 Hz 会报"链路丢帧约 22.52%"、14000 Hz 报 40%，面板直接显示）。
    est = SpeedEstimator(pairs=4)
    bad = []
    for hz in (10000.0, 12345.0, 12999.0, 14000.0, 19999.9):
        e2 = SpeedEstimator(pairs=4)
        s2 = _feed_batches(e2, synth(hz, 12000))
        if (s2["loss_pct"] or 0.0) > 0.5 or "链路丢帧" in (s2["note"] or ""):
            bad.append("%.0f Hz→loss=%.2f%%" % (hz, s2["loss_pct"] or 0.0))
    good = not bad
    ok &= good
    print("[9] 零丢帧不报丢帧 %s  %s"
          % ("（全部干净）" if good else "误报：" + "、".join(bad),
             "PASS" if good else "FAIL"), file=FR)

    # 10) ★真丢帧率要报对：每收 1 帧丢 1 帧 ⇒ 链路丢帧率应 ≈50%（老实现只报取整残差）
    est = SpeedEstimator(pairs=4)
    full = synth(19999.9, 22000)
    snap = None
    for i in range(0, len(full[::2]), 500):
        snap = est.feed(full[::2][i:i + 500], t_now=1000.0 + (i + 500) * 2e-4, n_bad=500)
    lp = snap["loss_pct"] or 0.0
    good = 40.0 <= lp <= 60.0
    ok &= good
    print("[10] 丢帧率口径   loss=%.1f%%（应 ≈50%%）  %s"
          % (lp, "PASS" if good else "FAIL"), file=FR)

    # 11) ★口径迟滞必须有出口：丢帧压下去之后要回到 fine 口径（2026-10-17 全面自查）
    est = SpeedEstimator(pairs=4)
    full = synth(19999.9, 22000)
    half = full[::2]
    _sw = []
    for i in range(0, len(half), 500):
        _s = est.feed(half[i:i + 500], t_now=1000.0 + (i + 500) * 2e-4, n_bad=500)
    _sw.append(("丢帧 50%%", _s["use_clock"], _s["loss_pct"] or 0.0))
    for i in range(0, len(full), 500):
        _s = est.feed(full[i:i + 500], t_now=1002.2 + (i + 500) * 1e-4, n_bad=0)
    _sw.append(("恢复零丢帧", _s["use_clock"], _s["loss_pct"] or 0.0))
    good = _sw[0][1] is True and _sw[1][1] is False and _sw[1][2] < 1.5
    ok &= good
    print("[11] 口径迟滞出口 %s  %s"
          % ("、".join("%s→use_clock=%s loss=%.2f%%" % (a, b, c) for a, b, c in _sw),
             "PASS" if good else "FAIL"), file=FR)

    print("自检%s" % ("通过 (PASS)" if ok else "失败 (FAIL)"), file=FR)
    return 0 if ok else 1


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:                                    # noqa: BLE001
        pass
    if "--selftest" in argv or not argv:
        return selftest()
    print("用法：python host\\encoder.py --selftest")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
