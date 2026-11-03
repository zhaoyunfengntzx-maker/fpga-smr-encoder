r"""输入信号、幅值与告警的纯逻辑（无 Qt、无串口，可离线自检）。

★ 文件名为什么叫 `alarm.py`（原来叫 `signal.py`，2026-10-13 改）：
  模块名叫 `signal` 会**遮蔽标准库 `signal`** —— 源码模式下靠 `app.py` 把 `host/`
  插到 `sys.path[0]` 才碰巧对；而打包成 exe 后 PyInstaller 的 PYZ 里同名模块只能有
  一份，**标准库赢**，于是 exe 启动就崩：
  `panel_alarm.py:66 AttributeError: module 'signal' has no attribute 'ALARM_ROWS'`
  （实测：`host\_exe_work\host_exe\PYZ-00.pyz` 里的 `signal` 是标准库，含
  `valid_signals`、不含 `ALARM_ROWS`）。改名为 `alarm` 后源码与 exe 都不再有这个碰撞。

用途：需求 M4（s_n/c_n 时域波形、李萨如圆、幅值/OTR）与 M7（告警中文+颜色）。

板上口径（依据 RTL / 文档，不是猜的）：
  * `amp_sq = s_n^2 + c_n^2`，Q2.30 无符号；s_n/c_n 是 Q1.15 有符号
    （rtl/amp_monitor.v:5、:107 每拍随乘积寄存器更新、:30 饱和不回绕）
  * 幅值门限 `0x0520-23 AMP_LOW_SQ` 复位值 `0x170A3D71` = (0.60)^2 * 2^30、
    `0x0524-27 AMP_HIGH_SQ` 复位值 `0x5C28F5C3` = (1.20)^2 * 2^30
    （rtl/reg_file.v:315-316；写译码 :399-406、读译码 :510-521 都是小端逐字节）
  * 实测值 `0x0530-33 STAT_AMP_SQ`（rtl/enc_top.v:946 接 amp_monitor 的 amp_sq）
  * 遥测帧的 io_state / io_flags / stat 位义：tools/uart_scope.py:97-102
  * `0x0404 STAT_VAL` / `0x0405 STAT_LATCH`（W1C，写 1 清）位义：
    bit0 oflow(otr) / bit2 laglim / bit3 inclim / bit4 lagfatl / bit5 scamp
    （rtl/enc_top.v:748-757 的 stat_byte；写 0x0405 的 bit0 同时发 1 拍 clr_otr 清 ADC sticky）
  * `0x053A STAT_FLAGS`：bit0 laglim / bit1 amplo / bit2 amphi / bit3 otr /
    bit4 caldone / bit5 calbusy / bit6 crcerr / bit7 biss frame_active
    （rtl/reg_file.v:510-512 附近的读译码与 docs/01_technical_solution.md:635）

★ 读应答的字节约定（实测 + 已验证）：16 位响应 = {寄存器[addr+1], 寄存器[addr]}
  ⇒ 读 `0x0404` 一次就能同时拿到 STAT_VAL（低字节）与 STAT_LATCH（高字节）；
     读 `0x053A` 一次拿到 STAT_FLAGS（低字节）与 `0x053B`（高字节）。
"""

from __future__ import annotations

import math

# ---------------------------------------------------------------- 常量与换算

FS = 32768.0                # Q1.15 的 1.0（满量程）
CLIP_LEVEL = 32760          # |s| 或 |c| 到这儿就算顶到轨（真实满码 32767）

REG_STAT_VAL = 0x0404       # 读它可同时得到 0x0405（高字节）
REG_STAT_LATCH = 0x0405
REG_STAT_FLAGS = 0x053A     # 读它可同时得到 0x053B（高字节）
REG_AMP_LOW_SQ = 0x0520     # 32 位小端：0x0520/0x0521 与 0x0522/0x0523
REG_AMP_HIGH_SQ = 0x0524
REG_STAT_AMP_SQ = 0x0530
# 写 0x0405 = 0x00FF：把所有锁存位清掉（bit0 还发 clr_otr 脉冲）
# ★ 为什么不用更窄的掩码（例如只写实际会被锁存的 b0/b2/b3/b5 = 0x2D）：
#   rtl/reg_file.v:412-413 是**整字节 W1C**，对永不置位的 b1/b4/b6/b7 写 1 无副作用；
#   反过来，若将来 RTL 把 b4（lagfatl，现在 rtl/reg_file.v:248-249 恒接 0）接出来，
#   窄掩码就清不掉它了 ⇒ 写全 1 更稳。审计提出过收窄，这里**决定不收窄**。
LATCH_CLEAR_VALUE = 0x00FF

# 0x0405 / 0x0404 的位（0x0404 = 实时，0x0405 = 锁存）
VAL_BITS = ((0, "oflow", "输出溢出（cor_sat | ADC 过载锁存）"),
            (2, "laglim", "滞后限频已激活"),
            (3, "inclim", "AB 限频 或 UVW 基波超限"),
            (4, "lagfatl", "相位滞后致命（≥180°）"),
            (5, "scamp", "幅值越限（amp_low | amp_high）"))

# 0x053A STAT_FLAGS 的位
FLAG_BITS = ((0, "laglim", "滞后限频"),
             (1, "amplo", "幅值偏低"),
             (2, "amphi", "幅值偏高"),
             (3, "otr", "ADC 过载锁存（sticky）"),
             (4, "caldone", "标定完成"),
             (5, "calbusy", "标定进行中"),
             (6, "crcerr", "BiSS CRC 错误"),
             (7, "biss_active", "BiSS 帧进行中"))


def amp_sq_of(s: int, c: int) -> int:
    """上位机自己算 amp_sq：与板上 amp_monitor 逐位相同（s²+c² 不会饱和）。"""
    return (int(s) * int(s) + int(c) * int(c)) & 0xFFFFFFFF


def r_of_amp_sq(v: int) -> float:
    """Q2.30 的 amp_sq → 幅值 r（Q1.15 单位，32768 = 1.0）。"""
    return math.sqrt(float(v))


def amp_limits(amp_low_sq: int, amp_high_sq: int):
    """门限平方 → (r 下限, r 上限)，单位同 amp_sq_of 的 r。"""
    return (math.sqrt(float(int(amp_low_sq))) if amp_low_sq else None,
            math.sqrt(float(int(amp_high_sq))) if amp_high_sq else None)


def amp_verdict(r: float, r_low, r_high):
    """按板上门限判定幅值，返回 (level, 中文)。"""
    if r_low is None or r_high is None:
        return ("info", "门限未读到")
    if r < r_low:
        return ("fault", "偏低（低于下限）")
    if r > r_high:
        return ("fault", "偏高（高于上限）")
    return ("ok", "正常")


# ------------------------------------------------------------ 波形缓冲区

class WaveBuffer:
    """最近若干帧的 s_n / c_n / 电角度环形缓冲 + 幅值统计。

    默认 1500 帧 = 150 ms（板上 10 kHz 一帧）。整段重算统计很便宜（1500 次
    浮点运算），换来的是"统计与画出来的波形严格同一批数据"。
    """

    def __init__(self, capacity: int = 1500):
        self.capacity = max(16, int(capacity))
        self.reset()

    def reset(self):
        self.n = 0
        self.s = []
        self.c = []
        self.ang = []
        self.z = []                 # ★ 阶段 5（C 批）：Z 索引电平（0/1），给波形触发源用
        self.t = []                 # 帧计数时间（秒，板上 10 kHz 一帧）；画图时减去 t[-1] 才是相对最新一帧
        self.seq0 = None
        self.seq = 0

    def feed(self, frames):
        """吃进若干帧（list of frame dict，来自 tools/uart_scope.parse_stream）。"""
        cap = self.capacity
        for f in frames:
            s = f.get("s")
            c = f.get("c")
            if s is None or c is None:
                continue
            ang = f.get("angle_deg")
            if ang is None:
                ang = f.get("angle", 0) * 360.0 / 65536.0
            self.s.append(int(s))
            self.c.append(int(c))
            self.ang.append(float(ang))
            # Z 索引电平：reporter 帧里是 io_bits["z"]（recorder.py 造的帧与链路解析层同键名）
            self.z.append(1 if (f.get("io_bits") or {}).get("z") else 0)
            self.t.append(self.seq / 10000.0)      # 板上 10 kHz 一帧
            self.seq += 1
            self.n += 1
        if len(self.s) > cap:                       # 保新弃旧
            cut = len(self.s) - cap
            for arr in (self.s, self.c, self.ang, self.z, self.t):
                del arr[:cut]

    def snapshot(self):
        """返回绘图与读数所需的全部量（无数据时 n = 0）。"""
        n = len(self.s)
        out = {"n": n, "s": list(self.s), "c": list(self.c),
               "ang": list(self.ang), "z": list(self.z), "t": list(self.t),
               "r_mean": None, "r_rms": None, "r_min": None, "r_max": None,
               "roundness": None, "clip": 0, "amp_sq": None, "r": None,
               "span_s": (self.t[-1] - self.t[0]) if n > 1 else 0.0}
        if not n:
            return out
        r_min = None
        r_max = None
        tot = 0.0
        tot2 = 0.0
        clip = 0
        for i in range(n):
            s = self.s[i]
            c = self.c[i]
            if abs(s) >= CLIP_LEVEL or abs(c) >= CLIP_LEVEL:
                clip += 1
            # 半径可以超过 1.0（两路都接近满码时），用 32 位截断与板上一致
            r = math.sqrt(float(amp_sq_of(s, c)))
            tot += r
            tot2 += r * r
            r_min = r if r_min is None or r < r_min else r_min
            r_max = r if r_max is None or r > r_max else r_max
        last_s, last_c = self.s[-1], self.c[-1]
        out["amp_sq"] = amp_sq_of(last_s, last_c)
        out["r"] = math.sqrt(float(out["amp_sq"]))
        out["r_mean"] = tot / n
        out["r_rms"] = math.sqrt(tot2 / n)
        out["r_min"] = r_min
        out["r_max"] = r_max
        out["roundness"] = ((r_max - r_min) / out["r_mean"] * 100.0) if out["r_mean"] else None
        out["clip"] = clip
        return out


# ---------------------------------------------------------------- 告警表

# 界面按这个固定顺序显示（状态随数据刷新，行不跳动）
ALARM_ROWS = (
    ("amp", "幅值越限", "r=√(s²+c²) 超出 0x0520-27 门限（amp_low|amp_high）"),
    ("cor_sat", "校正饱和", "修正系数饱和（cor_sat）"),
    ("lag_fatal", "相位滞后致命", "≥180°，可能丢步（lag_fatal）"),
    ("lag_warn", "相位滞后警告", "≥45°（lag_warn）"),
    ("uvw_warn", "UVW 频率超限", "基波 > 8.33 MHz 警告（uvw_freq_warn）"),
    ("limiter", "AB 限频激活", "边沿率被 ABLIMIT 限制，属预期现象"),
    ("oflow", "输出溢出位", "stat bit0 = cor_sat | ADC 过载锁存"),
    ("otr", "ADC 过载锁存", "0x053A bit3；写 0x0405 可清（sticky）"),
    ("laglim", "滞后限频锁存", "0x0405 bit2 / 0x053A bit0"),
    ("inclim", "限频锁存", "0x0405 bit3"),
    ("cal", "标定状态", "0x053A bit4 caldone / bit5 calbusy"),
    ("crcerr", "BiSS CRC 错", "0x053A bit6（没接 BiSS 主机时应为 0）"),
    ("z_window", "Z 索引窗口", "正常现象：当前在 Z 脉冲窗口内"),
    ("outputs", "输出使能", "abzen / uwven（非告警，仅状态）"),
)


def _blank_state():
    return {k: ("idle", "—") for k, _n, _h in ALARM_ROWS}


def evaluate(frames, status=None, r=None, r_low=None, r_high=None):
    """把「最新一帧」与「寄存器状态」翻成告警行状态。

    frames: 最近收到的帧（用最后一帧的 io_flags/stat/io_state）
    status: 读寄存器任务返回的 dict，键为 latch0405/val0404/flags053a（可为 None）
    返回 {row_key: (level, 中文详情)}
    """
    st = _blank_state()
    f = frames[-1] if frames else None

    if f is not None:
        ib = f.get("io_bits") or {}
        fb = f.get("io_flag_bits") or {}
        stat = int(f.get("stat") or 0)

        def bit(name):
            v = fb.get(name)
            if v is None:
                idx = {"lag_warn": 0, "lag_fatal": 1, "z_window": 2, "uvw_freq_warn": 3,
                       "abzen": 4, "uwven": 5, "cor_sat": 6, "amp_bad": 7}[name]
                v = (int(f.get("io_flags") or 0) >> idx) & 1
            return int(v)

        # ★ r 可能没算出来（缓冲区空/只读到状态）：这时不能去格式化 r（%r 会
        #   TypeError 打进 Qt 槽），退回不带数值的说法。
        _r_ok = (r is not None) and (r_low is not None) and (r_high is not None)
        st["amp"] = (("fault", "r=%.0f 越限" % r) if bit("amp_bad")
                     else ("ok", "r=%.0f 正常" % r)) if _r_ok else \
            (("fault", "置位") if bit("amp_bad") else ("ok", "正常"))
        st["cor_sat"] = ("fault", "置位") if bit("cor_sat") else ("ok", "正常")
        st["lag_fatal"] = ("fault", "置位") if bit("lag_fatal") else ("ok", "正常")
        st["lag_warn"] = ("warn", "置位") if bit("lag_warn") else ("ok", "正常")
        st["uvw_warn"] = ("warn", "置位") if bit("uvw_freq_warn") else ("ok", "正常")
        st["limiter"] = ("warn", "限频中") if int(ib.get("limiter") or 0) else ("ok", "未限频")
        st["oflow"] = ("warn", "置位") if (stat >> 0) & 1 else ("ok", "正常")
        st["z_window"] = ("info", "窗口内") if bit("z_window") else ("idle", "窗口外")
        abz = bit("abzen")
        uwv = bit("uwven")
        st["outputs"] = ("info", "ABZ+UVW 开" if (abz and uwv)
                         else ("只 ABZ" if abz else ("只 UVW" if uwv else "都关")))

    if status:
        latch = int(status.get("latch0405") or 0)
        val = int(status.get("val0404") or 0)
        flags = int(status.get("flags053a") or 0)

        def lb(b):
            return "已锁存" if (latch >> b) & 1 else "已清"

        # 状态 chip 宽度固定，文字必须短：位号用 bN 写法，完整来源放 tooltip
        st["otr"] = (("warn", lb(0) + " b0") if (latch >> 0) & 1 or (flags >> 3) & 1
                     else ("ok", "无"))
        st["laglim"] = (("warn", lb(2) + " b2") if (latch >> 2) & 1
                        else (("info", "0x053A b0 置位") if (flags >> 0) & 1 else ("ok", "无")))
        st["inclim"] = (("warn", lb(3)) if (latch >> 3) & 1 or (val >> 3) & 1 else ("ok", "无"))
        # ★ b4(lagfatl) 在 rtl/reg_file.v:248-249 里被硬接 0（只读 STAT_VAL 的
        #   b1/b4/b6/b7 恒 0，见 rtl/reg_file.v:79-80 的地址表），所以这一行在
        #   v12 上永远不会触发；真正的 lagfatal 只看遥测 io_flags bit1（上面
        #   `bit("lag_fatal")`）。保留此行是为了将来 RTL 把 b4 接出来时不用改主机。
        st["lag_fatal"] = (("fault", "已锁存 b4") if (latch >> 4) & 1 else st["lag_fatal"])
        # ★ b5(scamp) 是锁存器里唯一没有被翻译的位：rtl/reg_file.v:248-249 的
        #   stat_val_now bit5 = (stat_amp_low | stat_amp_high)，rtl/reg_file.v:298
        #   的 r_stat_ie 复位值 8'h38 也把它算进中断使能。实时门限告警优先；
        #   只有"历史锁存、当前已恢复"时才显示成"已锁存 b5" —— 否则真机会在
        #   STAT_LATCH=0x24 时显示"幅值越限 正常"，用户看到摘要行的 0x0405=0x24
        #   却查不到这个位是哪来的（2026-10-14 真机 S3 实测到）。
        if (flags >> 1) & 1 or (flags >> 2) & 1:
            st["amp"] = ("fault", "门限：偏低" if (flags >> 1) & 1 else "门限：偏高")
        elif (latch >> 5) & 1:
            st["amp"] = ("warn", "已锁存 b5")
        st["cal"] = (("info", "标定中") if (flags >> 5) & 1 else
                     (("ok", "标定完成") if (flags >> 4) & 1 else ("idle", "未标定")))
        st["crcerr"] = (("fault", "CRC 错误") if (flags >> 6) & 1 else ("ok", "正常"))
    return st


def status_summary(status, r_host=None):
    """给界面用的一段幅值/OTR 摘要文字。"""
    if not status:
        return "锁存状态未读到（点“读状态”）"
    r_low, r_high = amp_limits(status.get("amp_low_sq") or 0, status.get("amp_high_sq") or 0)
    parts = []
    if r_low is not None and r_high is not None:
        parts.append("门限 r %.0f…%.0f" % (r_low, r_high))
    sq = status.get("stat_amp_sq")
    if sq:
        parts.append("板上 STAT_AMP_SQ=%.0f（r=%.0f）" % (sq, r_of_amp_sq(int(sq))))
    if r_host is not None:
        parts.append("上位机 r=%.0f" % r_host)
    latch = int(status.get("latch0405") or 0)
    flags = int(status.get("flags053a") or 0)
    parts.append("0x0405=0x%02X 0x053A=0x%02X" % (latch, flags))
    return "；".join(parts)


# ---------------------------------------------------------------- 离线自检

def selftest():
    """离线自检：不用板子，只验算数学与告警翻译。"""
    ok = 0
    fail = []

    def check(name, cond, info=""):
        nonlocal ok
        if cond:
            ok += 1
            print("  [OK] %s %s" % (name, info))
        else:
            fail.append(name)
            print("  [!!] %s %s" % (name, info))

    print("alarm.py 离线自检")

    # 1. amp_sq 与幅值换算：r=16384（0.5 FS）⇒ amp_sq = 2*16384² = 2^29
    check("amp_sq_of 与 RTL 同式", amp_sq_of(16384, 0) == 2 ** 28,
          "amp_sq=%d" % amp_sq_of(16384, 0))
    check("r 往返", abs(r_of_amp_sq(amp_sq_of(16384, 0)) - 16384.0) < 1e-6)

    # 2. 门限换算：复位值 → 0.60 / 1.20 满量程
    r_low, r_high = amp_limits(0x170A3D71, 0x5C28F5C3)
    check("门限下限 0.60 FS", abs(r_low / FS - 0.60) < 1e-3, "r_low=%.1f" % r_low)
    check("门限上限 1.20 FS", abs(r_high / FS - 1.20) < 1e-3, "r_high=%.1f" % r_high)

    # 3. 判定三态
    check("判定 偏低", amp_verdict(0.3 * FS, r_low, r_high)[0] == "fault")
    check("判定 正常", amp_verdict(0.8 * FS, r_low, r_high)[1] == "正常")
    check("判定 偏高", amp_verdict(1.3 * FS, r_low, r_high)[0] == "fault")

    # 4. 波形缓冲：造 1000 帧半径 16384 的圆
    wb = WaveBuffer(capacity=500)
    frames = []
    for i in range(1000):
        a = 2.0 * math.pi * i / 200.0
        frames.append({"s": int(round(16384 * math.sin(a))),
                       "c": int(round(16384 * math.cos(a))),
                       "angle": (i * 655) & 0xFFFF,
                       "io_flags": 0, "io_state": 0, "stat": 0,
                       "io_bits": {}, "io_flag_bits": {}})
    wb.feed(frames)
    snap = wb.snapshot()
    check("环形缓冲保新弃旧", snap["n"] == 500, "n=%d" % snap["n"])
    check("半径均值 ≈16384", abs(snap["r_mean"] - 16384) < 60, "r_mean=%.1f" % snap["r_mean"])
    check("圆度偏差很小", snap["roundness"] < 2.0, "roundness=%.3f%%" % snap["roundness"])
    check("无削顶", snap["clip"] == 0)

    # 5. 削顶检测：塞一个满码样本
    wb.feed([{"s": 32767, "c": 0, "angle": 0, "io_flags": 0, "io_state": 0, "stat": 0,
              "io_bits": {}, "io_flag_bits": {}}])
    check("削顶计数", wb.snapshot()["clip"] == 1)

    # 6. 帧位义翻译：io_flags bit7 amp_bad + bit0 lag_warn，stat bit0 oflow
    f = dict(frames[-1])
    f["io_flags"] = (1 << 7) | (1 << 0)
    f["io_flag_bits"] = {"amp_bad": 1, "lag_warn": 1}
    f["stat"] = 0x01
    st = evaluate([f], None, r=20000.0, r_low=r_low, r_high=r_high)
    check("amp_bad → 故障", st["amp"][0] == "fault", st["amp"][1])
    check("lag_warn → 警告", st["lag_warn"][0] == "warn")
    check("stat bit0 → 输出溢出", st["oflow"][0] == "warn")
    check("未读状态时 otr 为 idle", st["otr"][0] == "idle")

    # 7. 寄存器位义翻译：0x0405=0x0001（otr 锁存）、0x053A=0x0008（otr）+0x0042（amplo+crcerr）
    st = evaluate([f], {"latch0405": 0x01, "val0404": 0x0001, "flags053a": 0x08,
                        "amp_low_sq": 0x170A3D71, "amp_high_sq": 0x5C28F5C3,
                        "stat_amp_sq": amp_sq_of(20000, 0)}, r=20000.0)
    check("锁存 otr → 警告", st["otr"][0] == "warn", st["otr"][1])
    st = evaluate([f], {"latch0405": 0x00, "val0404": 0x0000, "flags053a": 0x42})
    check("amplo+crcerr", st["amp"][0] == "fault" and st["crcerr"][0] == "fault",
          "%s / %s" % (st["amp"][1], st["crcerr"][1]))
    check("清位后 otr 正常", st["otr"][0] == "ok")
    # ★ 2026-10-14 真机复查新增：b5(scamp) 锁存位必须能翻译出来。真机 S3 实测
    #   STAT_LATCH=0x24（b2 laglim + b5 scamp）、0x053A=0x00，此前界面显示
    #   "幅值越限 正常"，只有摘要行 0x0405=0x24 能看出矛盾。
    st = evaluate([f], {"latch0405": 0x24, "val0404": 0x0000, "flags053a": 0x00},
                  r=25900.0, r_low=r_low, r_high=r_high)
    check("锁存 b5(scamp) → 警告", st["amp"][0] == "warn", st["amp"][1])
    check("锁存 b2(laglim) 同帧仍翻译", st["laglim"][0] == "warn", st["laglim"][1])
    st = evaluate([f], {"latch0405": 0x24, "val0404": 0x0000, "flags053a": 0x02},
                  r=1000.0, r_low=r_low, r_high=r_high)
    check("实时门限优先于锁存 b5", st["amp"][0] == "fault" and "偏低" in st["amp"][1],
          st["amp"][1])

    # 8. 摘要文字
    txt = status_summary({"latch0405": 0x25, "flags053a": 0x18, "amp_low_sq": 0x170A3D71,
                          "amp_high_sq": 0x5C28F5C3, "stat_amp_sq": amp_sq_of(26325, 0)},
                         r_host=26325.0)
    check("摘要含门限与寄存器值", "门限" in txt and "0x0405=0x25" in txt, txt)

    # 9. r 没算出来时不能崩：原来 "r=%.0f" % None 会 TypeError 打进 Qt 槽
    st = evaluate([f], None, r=None, r_low=r_low, r_high=r_high)
    check("r=None + 有门限不崩", st["amp"][1] in ("置位", "正常"), st["amp"][1])
    st = evaluate([f], None, r=None, r_low=None, r_high=None)
    check("r=None + 无门限不崩", st["amp"][1] in ("置位", "正常"), st["amp"][1])

    print("alarm.py 自检：%d 项通过%s" % (ok, "" if not fail else "，失败 %s" % fail))
    return 0 if not fail else 1


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="输入信号/幅值/告警逻辑自检")
    ap.add_argument("--selftest", action="store_true", help="跑离线自检")
    args = ap.parse_args(argv)
    if args.selftest or not args.selftest:
        return selftest()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
