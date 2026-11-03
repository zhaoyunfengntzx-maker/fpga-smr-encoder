"""ABZ / UVW 输出「等效采样」分析（纯逻辑：无 Qt、无串口）。

为什么不能按时间轴画 A/B
------------------------
板子每 100 µs 才发一帧遥测（`rtl/uart_scope.v:151 SAMPLE_DIV=5000 @50 MHz`，
正好 10 kHz），帧里给的是六路输出的**电平快照**。而 AB 边沿率 =
`4 × inter ÷ div × f_in`（本板 inter=32、f_in≈20 kHz ⇒ **2.56 MHz**），
比帧率高 256 倍 ⇒ 按时间轴画 A/B 只会看到混叠的噪声/直线，**永远看不到边沿**。
需求 M5 明确要求把这个限制如实标注出来，本模块与卡片⑨ 都照此写明。

能做的是「电角度分箱等效采样」
------------------------------
把每一帧当成一次**以输入电角度为横轴**的采样点：只要输入频率不是帧率的精确整数倍，
相位就会缓慢漂移，逐帧把 0…360° 填满，于是**按角度分箱取均值**就能重建波形：

* 每个箱的均值 = 该角度区间内高电平所占比例（0…1）；
* 全箱均值 = 占空比；
* A 与 B 的上升沿箱位置之差 = 四分之一 AB 周期（90°）；
* `U/V/W` 的六种组合每 60° 电角度轮换一次，分箱计数直接给出六状态数据表。

RTL 依据（本工程 v12 位流）
---------------------------
* `rtl/abz_gen.v:295-298` `edge_idx = (angle * inter) >>> (AW-2) ∈ [0, 4·inter-1]`
* `rtl/abz_gen.v:726-727` `a_out = r_div_idx[1] ^ apol`、
  `b_out = (r_div_idx[1] ^ r_div_idx[0]) ^ bpol`
  ⇒ A/B 各以 4 个边沿步为一个周期（＝ `360°/inter` 输入角度），B 相对 A 移 1 步 ＝ 90°
* `rtl/abz_gen.v:520` Z 脉宽 = `(z_width + 1)` 个边沿步（v9 起；`z_width` = `0x0108[3:0]`）
* `rtl/enc_top.v:643-644` `z_window = (cycle_cnt[5:0] == 0)` ⇒ **每 64 个输入周期一个 Z**
* `rtl/uvw_gen.v:156-161` `eang = (angle × pairs + uvwph·2^(AW-10)) mod 2^AW`
* `rtl/uvw_gen.v:174-177` `sec = (eang × 6) >> AW ∈ 0…5`（每扇区 60° 电角度）
* `rtl/uvw_gen.v:483-495` 扇区 → `{u,v,w}` = `110,010,011,001,101,100`，`uvwdir` 反转扇区序、
  `uvwpol` 三位取反
* `rtl/reg_file.v:559-560` `cfg_inter = {r_inter1[1:0], r_inter0[7:0]}`、`cfg_div = r_inter1[4:2]`
"""

import argparse
import math
import sys

# ---------------------------------------------------------------- 常量与工具

FRAME_HZ = 10000.0            # 板子名义帧率（SAMPLE_DIV=5000 @50 MHz）
AW = 16                       # 角度位宽（2^16 = 一个输入周期）
ANG_MOD = 1 << AW
# 每多少个输入周期出一个 Z 索引：旧磁环位流 POLE_BITS=6 → 64。
# ★ 本机 EI58 位流按 docs/20 §7 应是 POLE_BITS=11 → 每 2048 个周期一个索引，
#   但板上 Z 在 10 kHz 遥测里几乎抓不到（30 s 只有 2 个边沿），无法证实；
#   这一项只影响本页的「Z 速率/占空比预测」，不影响实测曲线，故先留 64。
#   真要改，自检里的期望值也要一起改。
Z_INDEX_PAIRS = 64
BINS_DEFAULT = 1024           # ★ 用户反馈（m15813）：默认分箱从 256 改成 1024
BINS_CHOICES = (64, 128, 256, 512, 1024)
SQ_PER_NEED = 8               # ★ 阶段 5 D 批：一个 A/B 周期至少占这么多箱才看得出方波形状
SQ_GAP = 12                   # ★ 阶段 5 D 批：判决线跨空档的最长距离（超过就断开）


def clean_bins(bins):
    """把分箱数收进 BINS_CHOICES：0/负数/越界都要被夹住。

    ★ 构造函数原来直接 `int(bins)`：bins=0 时 snapshot() 会在 cover/bins 上
    ZeroDivisionError，feed() 会在 n_ab[bi] 上 IndexError（GUI 下拉只给合法值，
    但库的调用方不一定）。
    """
    try:
        b = int(bins)
    except (TypeError, ValueError):
        return BINS_DEFAULT
    if b in BINS_CHOICES:
        return b
    return min(BINS_CHOICES, key=lambda x: abs(x - b))


_clean_bins = clean_bins


# rtl/uvw_gen.v:485-490：扇区 0…5 → {u,v,w}（uvwpol=0、uvwdir=0）
SECTOR_UVW = (0b110, 0b010, 0b011, 0b001, 0b101, 0b100)
LEGAL_STATES = tuple(sorted(SECTOR_UVW))
STATE_NAMES = {
    0b000: "U- V- W-", 0b001: "U- V- W+", 0b010: "U- V+ W-", 0b011: "U- V+ W+",
    0b100: "U+ V- W-", 0b101: "U+ V- W+", 0b110: "U+ V+ W-", 0b111: "U+ V+ W+",
}


def state_of(u, v, w):
    """三路电平 → 3 位状态码（bit2=U、bit1=V、bit0=W）。"""
    return ((int(u) & 1) << 2) | ((int(v) & 1) << 1) | (int(w) & 1)


def state_text(s):
    return STATE_NAMES.get(int(s) & 7, "?")


def z_width_deg(z_width, inter, div=1):
    """Z 脉宽（输入电角度）。

    ★ div 的方向：rtl/abz_gen.v:704 是"每个 idx_exec 递减 r_z_left"，而 idx_exec
    （rtl/abz_gen.v:422，fwd_go|bwd_go）按 rtl/abz_gen.v:41-42、:358 是"每 div 个原始
    边沿步点火一次" ⇒ 脉宽 = (z_width+1) 个 **idx_exec** 拍 = (z_width+1)·div 个原始边沿步，
    即 ∝ div。同一个文件 :72-78 的注释与 docs/01_technical_solution.md:596 写的是 ∝1/div，
    两边矛盾（真机 ILA 量一下才能定案，本板 div=1 时两说一致）。
    host 侧现在统一按 RTL 代码的 ∝div 建模，并与 synth_frames 的建模同源。
    """
    return ((int(z_width) + 1) * int(max(1, int(div))) * 360.0) / (4.0 * max(1, int(inter)))


def z_duty(z_width, inter, div=1, z_index_pairs=Z_INDEX_PAIRS):
    """Z 高电平的**时间**占空比 = (脉宽/输入周期) ÷ 每几个输入周期出一个 Z。"""
    frac = ((int(z_width) + 1) * int(max(1, int(div)))
            / (4.0 * max(1, int(inter))))
    if not z_index_pairs:
        return None
    return frac / float(z_index_pairs)


def frame_phase_locked(f_in, z_index_pairs=Z_INDEX_PAIRS):
    """帧采样相位是否被输入频率"锁死"（f_in 是 FRAME_HZ/z_index_pairs 的整数倍）。

    锁死时帧永远落在 Z 窗（或永远落在窗外），"帧观测占空比"这个折算模型失效：实测
    20000 Hz 时理论/实测差 25.6 倍、15000 Hz 差 34 倍（真踩过，见 docs 自查记录）。
    """
    if not f_in:
        return False
    k = abs(float(f_in)) * z_index_pairs / FRAME_HZ
    return abs(k - round(k)) < 0.02 * max(1.0, k)


def z_duty_frames(z_width, inter, f_in, div=1, z_index_pairs=Z_INDEX_PAIRS):
    """Z 高电平的**帧观测**占空比期望。

    帧是欠采样的：Z 脉冲只占 5/128 圈、每 64 圈才一次，而帧每 `f_in/帧率` 圈才发一次，
    因此“帧里看到 z=1 的比例” = 时间占空比 × (f_in / 帧率)。
    （本板 f_in≈20 kHz ⇒ ×2；实测 0.12% 而不是时间占空比的 0.061%。）

    ⚠ 只在采样相位**非相干**时成立（见 frame_phase_locked）：锁相时这个折算没有意义，
    此时返回时间占空比 × 相位漂移以外的结果会离谱，故调用方应改看 duty_z_theory_time。
    """
    t = z_duty(z_width, inter, div, z_index_pairs)
    if t is None or not f_in:
        return t
    return t * abs(float(f_in)) / FRAME_HZ


def ab_period_deg(inter, div=1):
    """一个 AB 正交周期对应的输入电角度（div 之后每个输出边沿步覆盖 div 个原始步）。"""
    return 360.0 * max(1, int(div)) / max(1, int(inter))


def edge_step_deg(inter, div=1):
    """相邻 AB 边沿之间的输入电角度（等效采样能分辨的最小角度）。"""
    return 360.0 * max(1, int(div)) / (4.0 * max(1, int(inter)))


# ---------------------------------------------------------------- 分析器


class AbzAnalyzer:
    """按输入电角度 / UVW 电角度分箱，累积六路电平的等效采样。"""

    def __init__(self, bins=BINS_DEFAULT, pairs=4, inter=32, div=1, z_width=4,
                 uvwpol=0, uvwdir=0, apol=0, bpol=0, zpol=0):
        self.bins = _clean_bins(bins)
        self.pairs = int(pairs) or 4
        self.inter = int(inter) or 32
        self.div = int(div) or 1
        self.z_width = int(z_width)
        self.uvwpol = int(uvwpol) & 1
        self.uvwdir = int(uvwdir) & 1
        self.apol = int(apol) & 1
        self.bpol = int(bpol) & 1
        self.zpol = int(zpol) & 1
        self.abzen = 1
        self.uwven = 1
        self.f_in = None          # 由界面喂进来，用于把“时间占空比”折算成“帧观测占空比”
        self.reset()

    # ------------------------------------------------------------ 配置
    def configure(self, **kw):
        """改配置；bins / pairs / inter / div 变了都要清空累积。

        ★ 2026-10-17 全面自查修：inter/div 决定"一个 A/B 周期占多少箱"
        （per_bins = bins*div/inter）。改了它，旧累积就与新口径混在一起
        （实测：同一份数据把 inter 从 32 改成 64，A→B 相位从 −90° 变成 −180°，
        还把 muddy/置信度拖坏）。面板的「清空累积」提示写的就是"改 inter/div 后
        会自动清空"，这里必须真的清。
        """
        dirty = False
        for k in ("bins", "pairs"):
            if k in kw and kw[k] is not None and int(kw[k]) != getattr(self, k):
                setattr(self, k, int(kw[k]))
                dirty = True
        for k in ("inter", "div"):
            if k in kw and kw[k] is not None:
                v = int(kw[k])
                # inter=0 在板上等价于 256（host/regs.decode_inter_div），但分析器里
                # 0 会让"每箱跨几个周期/相位换算"变成恒 0 —— 兜住下限（构造里也这么做）
                v = max(2, v) if k == "inter" else max(1, v)
                if v != getattr(self, k):
                    setattr(self, k, v)
                    dirty = True
        for k in ("z_width", "uvwpol", "uvwdir", "apol", "bpol", "zpol"):
            if k in kw and kw[k] is not None:
                setattr(self, k, int(kw[k]))
        if self.bins not in BINS_CHOICES:
            self.bins = min(BINS_CHOICES, key=lambda b: abs(b - self.bins))
            dirty = True
        if dirty:
            self.reset()

    def set_regs(self, regs):
        """从任务读回的寄存器字典里取本卡需要的配置（host/regs.decode_* 的产物）。"""
        if not regs:
            return
        kw = {}
        for key, name in (("inter", "inter"), ("div", "div"), ("pairs", "pairs"),
                          ("zwidth", "z_width")):
            if regs.get(key) is not None:
                kw[name] = regs[key]
        self.configure(**kw)

    def set_output(self, bits):
        """0x0109 的八位（host/regs.decode_output 的产物）。"""
        if not bits:
            return
        self.configure(apol=bits.get("apol", self.apol), bpol=bits.get("bpol", self.bpol),
                       zpol=bits.get("zpol", self.zpol), uvwpol=bits.get("uvwpol", self.uvwpol),
                       uvwdir=bits.get("uvwdir", self.uvwdir))
        self.abzen = int(bits.get("abzen", 1))
        self.uwven = int(bits.get("uwven", 0))

    def set_f_in(self, f_in):
        """输入电频率（Hz），只用于把稀疏脉冲的占空比期望折算成“帧观测口径”。"""
        try:
            self.f_in = abs(float(f_in)) if f_in is not None else None
        except (TypeError, ValueError):
            self.f_in = None

    # ------------------------------------------------------------ 累积
    def reset(self):
        n = self.bins
        self.n_ab = [0] * n
        self.hi_a = [0] * n
        self.hi_b = [0] * n
        self.hi_z = [0] * n
        self.n_uvw = [0] * n
        self.hi_u = [0] * n
        self.hi_v = [0] * n
        self.hi_w = [0] * n
        self.states = [0] * 8
        self.sectors = [0] * 6
        self.frames = 0
        self.clock = 0
        self.t_first = None
        self.t_last = None
        self.z_hits = 0
        self.z_edges = 0
        self._prev_z = None
        self.dir_true = 0
        self.dir_false = 0
        self.illegal = 0

    def feed(self, frames, t_now=None, n_bad=0, snapshot=True):
        """吃进若干帧（tools/uart_scope.parse_stream 的 frame dict）。

        snapshot=False 时只累积、不返回快照（面板自己按重画节奏算，省一次全量计算）；
        默认 True 保持"喂完就能拿到快照"的原语义。
        """
        if not frames:
            return self.snapshot(t_now) if snapshot else None
        bins = self.bins
        shift = ANG_MOD.bit_length() - 1          # 16
        pairs = self.pairs
        for f in frames:
            ang = int(f.get("angle") or 0) & 0xFFFF
            ib = f.get("io_bits") or {}
            st = int(f.get("io_state") or 0)

            def lvl(name, bit):
                v = ib.get(name)
                return int(v) & 1 if v is not None else ((st >> bit) & 1)

            a = lvl("a", 0)
            b = lvl("b", 1)
            z = lvl("z", 2)
            u = lvl("u", 3)
            v = lvl("v", 4)
            w = lvl("w", 5)

            bi = (ang * bins) >> shift
            self.n_ab[bi] += 1
            self.hi_a[bi] += a
            self.hi_b[bi] += b
            self.hi_z[bi] += z

            eang = (ang * pairs) & 0xFFFF
            ui = (eang * bins) >> shift
            self.n_uvw[ui] += 1
            self.hi_u[ui] += u
            self.hi_v[ui] += v
            self.hi_w[ui] += w

            s = state_of(u, v, w)
            self.states[s] += 1
            if s not in LEGAL_STATES:
                self.illegal += 1
            self.sectors[(eang * 6) >> shift] += 1

            if z:
                self.z_hits += 1
                if self._prev_z == 0:
                    self.z_edges += 1
            self._prev_z = z

            d = ib.get("dir")
            if d is None:
                d = (st >> 6) & 1
            if int(d) & 1:
                self.dir_true += 1
            else:
                self.dir_false += 1

            self.frames += 1
        self.clock += len(frames) + max(0, int(n_bad))
        if self.t_first is None:
            self.t_first = t_now
        self.t_last = t_now
        return self.snapshot(t_now) if snapshot else None

    # ------------------------------------------------------------ 汇总
    def _duty(self, hi, n):
        tot = sum(n)
        return (sum(hi) / float(tot)) if tot else None

    def _decide(self, hi, n, bins):
        """把"箱内平均电平"判成 0/1 方波（阶段 5 D 批：消掉被平均出来的阶梯）。

        阈值取 0.5（多数票）；空档只跨 SQ_GAP 个箱继续沿用，再长就断开（没数据的地方
        不画线）。返回的列表元素是 0/1 或 None。
        """
        out = []
        last = None
        gap = 0
        for i in range(bins):
            if n[i]:
                gap = 0
                last = 1 if (hi[i] / float(n[i])) >= 0.5 else 0
            else:
                gap += 1
                if gap > SQ_GAP:
                    last = None
            out.append(last)
        return out

    def _rising(self, hi, n, bins):
        """找上升沿所在箱（环形）：电平从 <0.5 穿到 >=0.5 的那个箱。返回箱号或 None。"""
        def m(i):
            return (hi[i] / float(n[i])) if n[i] else None
        vals = [m(i) for i in range(bins)]
        for i in range(bins):
            if vals[i] is None:
                continue
            j = (i - 1) % bins
            # ★ 上一箱没样本（None）时**不算**跳变：否则"整段没有 AB 跳变"的数据也会被
            #   判出上升沿，相位差被凭空造出来（真踩过：单帧 A=B=0 也报相位差 0.00°）
            if vals[j] is not None and vals[i] >= 0.5 > vals[j]:
                return i
        return None

    def snapshot(self, t_now=None):
        bins = self.bins
        n_ab, n_uvw = self.n_ab, self.n_uvw
        cover_ab = sum(1 for x in n_ab if x)
        cover_uvw = sum(1 for x in n_uvw if x)
        out = {
            "bins": bins, "pairs": self.pairs, "inter": self.inter, "div": self.div,
            "z_width": self.z_width, "frames": self.frames, "clock": self.clock,
            "cover_ab": cover_ab, "cover_uvw": cover_uvw,
            "cover_ab_pct": cover_ab * 100.0 / bins,
            "cover_uvw_pct": cover_uvw * 100.0 / bins,
            "samples_ab": sum(n_ab), "samples_uvw": sum(n_uvw),
            "a": [self.hi_a[i] / n_ab[i] if n_ab[i] else None for i in range(bins)],
            "b": [self.hi_b[i] / n_ab[i] if n_ab[i] else None for i in range(bins)],
            "z": [self.hi_z[i] / n_ab[i] if n_ab[i] else None for i in range(bins)],
            "u": [self.hi_u[i] / n_uvw[i] if n_uvw[i] else None for i in range(bins)],
            "v": [self.hi_v[i] / n_uvw[i] if n_uvw[i] else None for i in range(bins)],
            "w": [self.hi_w[i] / n_uvw[i] if n_uvw[i] else None for i in range(bins)],
            "duty_a": self._duty(self.hi_a, n_ab),
            "duty_b": self._duty(self.hi_b, n_ab),
            "duty_z": self._duty(self.hi_z, n_ab),
            "duty_z_theory": z_duty_frames(self.z_width, self.inter, self.f_in, self.div),
            "duty_z_theory_time": z_duty(self.z_width, self.inter, self.div),
            "z_hits": self.z_hits, "z_edges": self.z_edges,
            "states": list(self.states), "sectors": list(self.sectors),
            "illegal": self.illegal,
            "dir_true": self.dir_true, "dir_false": self.dir_false,
            "ab_period_deg": ab_period_deg(self.inter, self.div),
            "edge_step_deg": edge_step_deg(self.inter, self.div),
            "z_width_deg": z_width_deg(self.z_width, self.inter, self.div),
            "duty_z_locked": frame_phase_locked(self.f_in),
        }
        # 六状态占比
        tot = sum(self.states)
        out["state_share"] = [(self.states[s] / float(tot) * 100.0) if tot else 0.0
                              for s in range(8)]
        out["state_expected_pct"] = 100.0 / 6.0
        # A→B 相位差（单位：AB 周期角度，正 = B 滞后 A）
        #
        # ★ 先判"电平是否与角度箱相关"：输入频率过高时（AB 输出周期远小于帧周期，且与帧
        #   采样不同步），每箱的 A/B 平均值都趋近 0.50 —— 等效采样重建不出方波，上升沿
        #   位置纯属噪声。真机实测（信号源 99 999.5 Hz、inter=32 ⇒ AB 输出 3.2 MHz）：
        #   256/256 箱都是 A=B=0.50，`_rising()` 会"测出"一个 0.0° 的假相位差。
        #   同一份代码在 19 999.901 Hz 下实测 −90.0°，所以这不是相位算法的问题。
        muddy_a = sum(1 for i in range(bins)
                      if n_ab[i] and 0.05 < self.hi_a[i] / float(n_ab[i]) < 0.95)
        muddy_b = sum(1 for i in range(bins)
                      if n_ab[i] and 0.05 < self.hi_b[i] / float(n_ab[i]) < 0.95)
        cover_n = cover_ab or 1
        out["ab_muddy"] = (muddy_a + muddy_b) >= 1.0 * cover_n
        out["ab_muddy_ratio"] = (muddy_a + muddy_b) / float(2 * cover_n)
        if out["ab_muddy"]:
            out["rise_a_bin"] = out["rise_b_bin"] = None
        ra = None if out["ab_muddy"] else self._rising(self.hi_a, n_ab, bins)
        rb = None if out["ab_muddy"] else self._rising(self.hi_b, n_ab, bins)
        out["rise_a_bin"], out["rise_b_bin"] = ra, rb
        deg = None
        if ra is not None and rb is not None:
            d = rb - ra
            # ★ 2026-10-17 全面自查修：漏了 div。一个 A/B 周期占 `bins*div/inter` 箱
            #   （见下面 per_bins 与"周期换算"注释），所以 箱→角度 是
            #   d/per_bins*360 = d*inter/(bins*div)*360。旧写法 div>1 时读数错 div 倍
            #   并回绕（实测真值 90°：div=2 报 −180°、div=4/8 报 0°），面板还会把它
            #   判成 warn，误导用户去改本来正确的硬件。
            deg = d * self.inter / (float(bins) * max(1, self.div)) * 360.0
            while deg >= 180.0:
                deg -= 360.0
            while deg < -180.0:
                deg += 360.0
        out["phase_ab_deg"] = deg
        out["phase_ab_err"] = (abs(abs(deg) - 90.0) if deg is not None else None)

        # ---- 阶段 5（D 批，用户 m15713 第 12 条）：把"被平均成的阶梯"变成标准方波
        #
        # 每箱的 hi/n 是**箱内平均**，箱里既有高电平又有低电平时它就落在中间，于是画出来
        # 是一段段台阶 —— 用户看到的"阶梯"就是这么来的。方波本身只有两种电平，所以按
        # 多数票把每箱判成 0/1（≥0.5 记 1）就得到"实测方波"；空箱沿用上一箱的判决，保证
        # 线不断。再按**测得的上升沿相位 + 理论周期**生成一条理想方波作参照（方案 C 的
        # "理论"那一路）。周期换算：一箱 = inter/bins 个 AB 周期（见 phase_ab_deg 的推导），
        # 所以一个 AB 周期占 `bins*div/inter` 箱 —— 这个数 ≥ 8 才谈得上"看得出方波形状"。
        sq_a, sq_b = [], []
        last_a = last_b = None
        dec_a = dec_b = cov = 0
        gap = 0
        for i in range(bins):
            if n_ab[i]:
                cov += 1
                gap = 0
                pa = self.hi_a[i] / float(n_ab[i])
                pb = self.hi_b[i] / float(n_ab[i])
                last_a = 1 if pa >= 0.5 else 0
                last_b = 1 if pb >= 0.5 else 0
                # "说得准"的箱：平均电平靠近 0 或 1（0.8/0.2 是给噪声留的余量）
                if pa <= 0.2 or pa >= 0.8:
                    dec_a += 1
                if pb <= 0.2 or pb >= 0.8:
                    dec_b += 1
            else:
                # 没样本的箱：只跨很短的空档继续沿用上一箱判决（方波要连起来才看得出），
                # 空档太长就断开 —— 等效采样还没填到的地方本来就是"没有数据"，
                # 硬画一条线等于撒谎（用户看到的"填箱"进度读数就是这件事）
                gap += 1
                if gap > SQ_GAP:
                    last_a = last_b = None
            sq_a.append(last_a)
            sq_b.append(last_b)
        out["sq_a"], out["sq_b"] = sq_a, sq_b
        out["sq_conf_a"] = (dec_a / float(cov)) if cov else None
        out["sq_conf_b"] = (dec_b / float(cov)) if cov else None
        out["sq_conf"] = ((dec_a + dec_b) / float(2 * cov)) if cov else None
        # Z / U / V / W 也做同样的判决（Z 是索引脉冲、UVW 是六步方波，本来就只有两种电平）
        sq_z = self._decide(self.hi_z, n_ab, bins)
        sq_u = self._decide(self.hi_u, n_uvw, bins)
        sq_v = self._decide(self.hi_v, n_uvw, bins)
        sq_w = self._decide(self.hi_w, n_uvw, bins)
        out["sq_z"], out["sq_u"], out["sq_v"], out["sq_w"] = sq_z, sq_u, sq_v, sq_w
        per_bins = (bins * max(1, self.div) / float(self.inter)) if self.inter else None
        out["sq_per_bins"] = per_bins
        out["sq_per_need"] = SQ_PER_NEED         # 一个 AB 周期至少要占这么多箱
        ideal_a = ideal_b = None
        if per_bins and per_bins >= 2.0 and ra is not None:
            ta = float(ra)
            tb = float(rb) if rb is not None else ta + per_bins / 4.0   # B 滞后 A 90°
            ideal_a, ideal_b = [], []
            for i in range(bins):
                ideal_a.append(1 if ((i - ta) % per_bins) / per_bins < 0.5 else 0)
                ideal_b.append(1 if ((i - tb) % per_bins) / per_bins < 0.5 else 0)
        out["ideal_a"], out["ideal_b"] = ideal_a, ideal_b
        # UVW 的"理论"：一个电周期 = 整圈 360°，50% 占空、彼此错开 120°（六步换相）
        ru = self._rising(self.hi_u, n_uvw, bins)
        rv = self._rising(self.hi_v, n_uvw, bins)
        rw = self._rising(self.hi_w, n_uvw, bins)
        out["rise_u_bin"], out["rise_v_bin"], out["rise_w_bin"] = ru, rv, rw
        if ru is not None:
            off = bins / 3.0                    # 120° = 1/3 圈
            iu, iv, iw = [], [], []
            for i in range(bins):
                iu.append(1 if ((i - ru) % bins) < bins / 2 else 0)
                iv.append(1 if ((i - (rv if rv is not None else ru + off)) % bins)
                          < bins / 2 else 0)
                iw.append(1 if ((i - (rw if rw is not None else ru + 2 * off)) % bins)
                          < bins / 2 else 0)
            out["ideal_u"], out["ideal_v"], out["ideal_w"] = iu, iv, iw
        else:
            out["ideal_u"] = out["ideal_v"] = out["ideal_w"] = None
        # 时长与提示
        span = None
        if self.t_first is not None and t_now is not None:
            span = max(0.0, t_now - self.t_first)
        out["span_s"] = span
        out["fps_clock"] = (self.clock / span) if span else None
        notes = []
        if self.abzen == 0:
            notes.append("板上 ABZ 输出已关闭（0x0109 abzen=0），A/B/Z 恒为 0")
        if self.uwven == 0:
            notes.append("板上 UVW 输出已关闭（0x0109 uwven=0），U/V/W 恒为 0")
        # ★ 2026-10-17 全面自查修：判据统一到"一个 A/B 周期占多少箱"
        #   （per_bins = bins*div/inter，上面已算）。旧写法 `bins < 8*inter` 漏 div
        #   ⇒ div>1 时会一边判绿「够用」一边告警「看不了方波」（实测 bins=1024、
        #   inter=256、div=8：sq_per_bins=32 判绿，同时报"每箱跨 0.25 周期"）。
        if per_bins is not None and per_bins < SQ_PER_NEED:
            # "每周期 ≥ SQ_PER_NEED 点" ⇒ 箱数 ≥ SQ_PER_NEED*inter/div
            need = int(math.ceil(SQ_PER_NEED * self.inter / float(max(1, self.div))))
            room = BINS_CHOICES[-1]
            per_bin = (1.0 / per_bins) if per_bins else 0.0
            if need <= room:
                notes.append("当前 inter=%d ⇒ 每电周期 %d 个 A/B 周期，而只有 %d 箱"
                             "（每箱跨 %.2f 个周期）：等效波形会被平均成阶梯，"
                             "想要方波形状请把箱数提到 ≥%d"
                             % (self.inter, self.inter, self.bins, per_bin, need))
            else:
                notes.append("当前 inter=%d ⇒ 每电周期 %d 个 A/B 周期，而只有 %d 箱"
                             "（每箱跨 %.2f 个周期）：等效波形会被平均成阶梯；"
                             "想看方波形状需要 %d 箱，已超过本程序上限 %d 箱 "
                             "⇒ 请同时把 inter 降到 ≤%d"
                             % (self.inter, self.inter, self.bins, per_bin,
                                need, room, max(1, room // 8)))
        if cover_ab and cover_ab < bins:
            notes.append("等效采样正在填箱：输入电角度已覆盖 %.0f%%（%d/%d 箱）"
                         % (cover_ab * 100.0 / bins, cover_ab, bins))
        if out["ab_muddy"]:
            # ★ 2026-10-14 真机复查修：原文案一口咬定"输入频率太高…降到 20 kHz 以内"，
            #   但真机在 f_in=1.0 kHz 也是 muddy —— 最常见的成因其实是箱数不够
            #   （bins ≤ 2×4×inter ⇒ 每箱跨 ≥1 个 A/B 周期、每箱均值必然趋近 0.5）。
            #   非整数倍的"帧采样简并"由 frame_phase_locked() 单独提示，这里分因说清。
            # self.inter = 每输入电周期里的 A/B 完整周期数（见上面 deg = d*inter/bins*360）。
            # ★ 2026-10-14 自查：这里原来写 2.0*self.inter，把"每箱跨几个周期"虚报了一倍。
            per_cyc = float(self.inter)
            ab_hz = 4.0 * self.inter / max(1, self.div) * abs(self.f_in or 0.0)
            fps = out.get("fps_clock") or 0.0
            why = []
            if per_bins is not None and per_bins < SQ_PER_NEED:
                why.append("箱数不够（%d 箱、div=%d、每电周期 %d 个 A/B 周期 ⇒ 每箱跨 %.2f 个"
                           "周期（每周期只有 %.1f 点），每箱均值必然趋近 0.5）"
                           % (self.bins, max(1, self.div), per_cyc,
                              (1.0 / per_bins) if per_bins else 0.0, per_bins or 0.0))
            if ab_hz and fps and ab_hz > 0.3 * fps:
                why.append("AB 边沿率 ≈%.2f MHz 已接近/超过帧率（%.0f 帧/秒），"
                           "帧里的 AB 电平与角度遥测对不上" % (ab_hz / 1e6, fps))
            if not why:
                why.append("帧里的 AB 电平与角度遥测对不上（具体成因未判明）")
            adv = []
            if per_bins is not None and per_bins < SQ_PER_NEED:
                # ★ 2026-10-17 全面自查修：判据同样带上 div（per_bins = bins*div/inter）。
                #   per_bins ≥ SQ_PER_NEED ⇒ inter ≤ bins*div/SQ_PER_NEED
                adv.append("把 inter 降到 ≤%d（＝箱数×div/%d，每箱跨 ≤%.3f 个 A/B 周期、"
                           "每周期 ≥%d 点）"
                           % (max(1, self.bins * max(1, self.div) // SQ_PER_NEED),
                              SQ_PER_NEED, 1.0 / SQ_PER_NEED, SQ_PER_NEED))
                need_bins = int(math.ceil(SQ_PER_NEED * self.inter
                                          / float(max(1, self.div))))
                if need_bins <= BINS_CHOICES[-1]:
                    adv.append("或把分箱提到 ≥%d" % max(256, need_bins))
                else:
                    adv.append("（inter=%d 这档即使 %d 箱也只有 %.1f 点/周期，看不了方波形状）"
                               % (self.inter, BINS_CHOICES[-1],
                                  BINS_CHOICES[-1] * max(1, self.div) / float(per_cyc)))
            if not adv:
                adv.append("把输入频率降到 20 kHz 以内")
            notes.append("A/B 电平与角度箱不相关（被填箱里 %.0f%% 的 A/B 平均值在 0.05~0.95 之间，"
                         "正常方波应几乎全为 0/1）⇒ 等效采样重建不出方波，A→B 相位差不可测。"
                         "原因：%s。可行做法：%s。"
                         % (out["ab_muddy_ratio"] * 100.0, "；".join(why), "，".join(adv)))
        if frame_phase_locked(self.f_in):
            notes.append("输入频率 ≈ %.2f Hz（帧率/%d）的整数倍 ⇒ 帧采样相位与 Z 窗锁死，"
                         "「帧观测」理论占空比失真（看时间占空比 %.4f%%）"
                         % (FRAME_HZ / Z_INDEX_PAIRS, Z_INDEX_PAIRS,
                            (z_duty(self.z_width, self.inter, self.div) or 0.0) * 100.0))
        out["notes"] = notes
        return out

    def theory(self, f_in):
        """按板上实测输入频率给出的理论值（用于与观测对照）。"""
        try:
            f = abs(float(f_in))
        except (TypeError, ValueError):
            return {}
        if not f or not math.isfinite(f):
            return {}
        ab = 4.0 * self.inter / max(1, self.div) * f
        return {
            "f_in": f,
            "ab_edge_rate": ab,
            "ab_period_hz": f * self.inter / max(1, self.div),
            # ★ 2026-10-17 自查修：v9 起 Z 脉宽 = (z_width+1) 个边沿步
            #   （rtl/abz_gen.v:130/:520/:694）⇒ z_width = 0 **也有 Z**，
            #   不能拿 z_width 当"Z 是否开启"的开关（旧写法在 z_width=0 时报 0 Hz）。
            #   Z 的真实开关是 abzen（rtl/abz_gen.v:526 `z_in_win = z_window & abzen`）。
            "z_rate": f / float(Z_INDEX_PAIRS),
            "uvw_rate": f * self.pairs,
            "uvw_sector_hz": f * self.pairs * 6.0,
        }

    # ------------------------------------------------------------ 离线自检


def synth_frames(n, f_hz=19999.9, pairs=4, inter=32, div=1, z_width=4, start_cycles=0.0,
                 fine_bits=0):
    """按 RTL 语义造理想帧（供离线自检）。

    关键：板上 `cycle_cnt` 是**采样角度回绕计数**，实测每帧 +2（输入 ≈2× 帧率）且恒为偶数，
    Z 门控取它的低 6 位（`rtl/enc_top.v:643-644`）。这里照此建模：`cycle_cnt` 每帧加 2，
    而采样相位按真实频率缓慢漂移 —— 只有采样点漂进 Z 窗口（每 64 个周期开头 5/128 圈）时，
    帧里才会出现 `z=1`（板子实测占空比 ≈0.1%，理论 5/(128·64) = 0.061%）。

    ★ `fine_bits`（2026-10-14 新增）：A/B 电平在板子上是由**细分相位累加器**（`rtl/abz_gen.v`
    的 `idx_exec`）当场产生的，而帧里的 `angle` 字段只有 16 位遥测精度。`fine_bits=0` 时
    两者共用同一个 16 位角度（自洽 ⇒ A/B 与角度一一对应、**永远不 muddy**，也就测不到
    "采样不足"那条路径）；`fine_bits>0` 时 A/B 用高 `fine_bits` 位的相位算、`angle` 仍是
    截断后的 16 位 —— 这才与真实板子等价（同一个角度箱里 A/B 电平会不一致 ⇒ muddy）。
    """
    out = []
    phase = float(start_cycles) - math.floor(float(start_cycles))
    cyc_cnt = int(math.floor(float(start_cycles))) & 0xFFFF
    step = float(f_hz) / FRAME_HZ
    cyc_step = max(1, int(round(step)))        # 板上实测每帧 2 个电周期
    fb = max(0, int(fine_bits))
    for _ in range(int(n)):
        phase += step
        while phase >= 1.0:
            phase -= 1.0
        cyc_cnt = (cyc_cnt + cyc_step) & 0xFFFF
        ang = int(phase * ANG_MOD) & 0xFFFF
        if fb:
            fine = int(phase * (ANG_MOD << fb))
            idx = (fine * inter) >> (AW + fb - 2)
        else:
            idx = (ang * inter) >> (AW - 2)                # rtl/abz_gen.v:295-298
        a = (idx >> 1) & 1
        b = ((idx >> 1) ^ idx) & 1                         # rtl/abz_gen.v:726-727
        # Z 窗内的宽度：(z_width+1) 个 idx_exec 拍；div>1 时一拍 = div 个原始边沿步
        # （与 z_width_deg / z_duty 同源，见那两个函数的 ★ 说明）
        z_span = (z_width + 1) * max(1, int(div))
        z = 1 if ((cyc_cnt & (Z_INDEX_PAIRS - 1)) == 0 and idx < z_span) else 0
        eang = (ang * pairs) & 0xFFFF
        sec = (eang * 6) >> AW                             # rtl/uvw_gen.v:174-177
        st = SECTOR_UVW[sec]
        u, v, w = (st >> 2) & 1, (st >> 1) & 1, st & 1
        io_state = a | (b << 1) | (z << 2) | (u << 3) | (v << 4) | (w << 5) | (1 << 6)
        out.append({"angle": ang, "pos_full": 0, "io_state": io_state, "stat": 0,
                    "io_flags": 0x08, "io_flag_bits": {"abzen": 1, "uwven": 0},
                    "io_bits": {"a": a, "b": b, "z": z, "u": u, "v": v, "w": w,
                                "dir": 1, "limiter": 0}})
    return out


def selftest():
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

    print("abz.py 离线自检（按 RTL 语义造帧）")

    bins = 256
    inter = 32
    pairs = 4
    zw = 4
    f_in = 19999.9
    an = AbzAnalyzer(bins=bins, pairs=pairs, inter=inter, div=1, z_width=zw,
                     uvwpol=0, uvwdir=0, apol=0, bpol=0)
    an.set_output({"abzen": 1, "uwven": 1})
    an.set_f_in(f_in)
    fr = synth_frames(int(FRAME_HZ * 30), f_hz=f_in, pairs=pairs, inter=inter, z_width=zw)
    snap = an.feed(fr, t_now=30.0)
    snap = an.snapshot(30.0)

    check("样本数", snap["samples_ab"] == len(fr), "n=%d" % snap["samples_ab"])
    check("AB 箱覆盖率 100%", snap["cover_ab"] == bins,
          "cover=%d/%d" % (snap["cover_ab"], bins))
    check("UVW 箱覆盖率 100%", snap["cover_uvw"] == bins,
          "cover=%d/%d" % (snap["cover_uvw"], bins))
    check("A 占空比 ≈50%", abs(snap["duty_a"] - 0.5) < 0.02, "a=%.3f" % snap["duty_a"])
    check("B 占空比 ≈50%", abs(snap["duty_b"] - 0.5) < 0.02, "b=%.3f" % snap["duty_b"])
    check("A→B 相位差 ≈±90°", snap["phase_ab_err"] is not None and snap["phase_ab_err"] < 15.0,
          "phase=%.1f° 误差=%.1f°" % (snap["phase_ab_deg"] or 0.0, snap["phase_ab_err"] or -1))
    # Z 是稀疏统计（每 64 个输入周期一个 5/128 圈宽的脉冲），且帧是欠采样的 ⇒ 期望值用
    # z_duty_frames()（= 时间占空比 × f_in/帧率），实测与它同量级即算通过
    zr = (snap["duty_z"] / snap["duty_z_theory"]) if snap["duty_z_theory"] else 0.0
    check("Z 观测到且与帧观测期望相符（0.6…1.6 倍）",
          snap["z_hits"] >= 20 and 0.6 <= zr <= 1.6,
          "实测=%.5f 期望=%.5f（%.2f 倍，命中 %d 帧；时间口径 %.5f）"
          % (snap["duty_z"], snap["duty_z_theory"], zr, snap["z_hits"],
             snap["duty_z_theory_time"]))
    check("Z 脉宽 = (z_width+1)/4/inter 圈", abs(snap["z_width_deg"] - 5 * 360.0 / 128.0) < 1e-6,
          "%.3f°" % snap["z_width_deg"])
    check("只出现六个合法状态", snap["illegal"] == 0, "非法帧=%d" % snap["illegal"])
    legal_ok = all(snap["states"][s] > 0 for s in LEGAL_STATES)
    check("六个合法状态都出现", legal_ok,
          " ".join("%s:%d" % (state_text(s), snap["states"][s]) for s in LEGAL_STATES))
    worst = max(abs(snap["state_share"][s] - snap["state_expected_pct"]) for s in LEGAL_STATES)
    check("六状态占比均衡（±4%）", worst < 4.0, "最大偏差 %.2f%%" % worst)
    th = an.theory(f_in)
    check("AB 边沿率 = 4·inter/div·f_in", abs(th["ab_edge_rate"] - 4 * inter * f_in) < 1e-6,
          "%.0f 边沿/秒" % th["ab_edge_rate"])
    check("Z 频率 = f_in/64", abs(th["z_rate"] - f_in / 64.0) < 1e-9, "%.1f Hz" % th["z_rate"])
    # ★ v9 回归（2026-10-17 自查）：z_width = 0 ⇒ 仍有 1 个边沿步的 Z，理论 Z 频率照旧 f_in/64。
    #   旧版把 z_width 当 Z 开关：z_width = 0 时 z_rate 报 0、S4 直接跳过全部 Z 判定。
    th0 = AbzAnalyzer(bins=bins, pairs=pairs, inter=inter, z_width=0).theory(f_in)
    check("z_width=0 仍算 Z（v9：0 ⇒ 1 步）",
          z_width_deg(0, inter, 1) > 0 and z_duty(0, inter, 1) > 0
          and z_duty_frames(0, inter, f_in, 1) > 0
          and abs(th0["z_rate"] - f_in / 64.0) < 1e-9,
          "宽 %.3f°／时间占空比 %.5f／Z %.1f Hz"
          % (z_width_deg(0, inter, 1), z_duty(0, inter, 1), th0["z_rate"]))
    check("UVW 电频率 = pairs·f_in", abs(th["uvw_rate"] - pairs * f_in) < 1e-6,
          "%.0f Hz" % th["uvw_rate"])

    # 箱数太小 ⇒ 提示
    an2 = AbzAnalyzer(bins=64, pairs=pairs, inter=inter, z_width=zw)
    an2.set_output({"abzen": 1, "uwven": 1})
    an2.feed(fr[:2000], t_now=0.2)
    s2 = an2.snapshot(0.2)
    check("箱数不足时给提示", any("等效波形会被平均成阶梯" in x for x in s2.get("notes", [])),
          "notes=%d 条" % len(s2.get("notes", [])))

    # 采样不足（muddy）时的"分因 + 可行做法"：文案要与判据自洽（inter ≤ 箱数/8，不是 /4）。
    # ★ 必须用 `fine_bits>0` 造帧：A/B 在板子上由细分相位当场产生、`angle` 只是 16 位遥测，
    #   `fine_bits=0` 时两者自洽 ⇒ 永远不 muddy（这条路径以前根本测不到）。
    fr3 = synth_frames(int(FRAME_HZ * 2), f_hz=1000.7, pairs=pairs, inter=256, z_width=zw,
                       fine_bits=8)
    an3 = AbzAnalyzer(bins=64, pairs=pairs, inter=256, z_width=zw)
    an3.set_output({"abzen": 1, "uwven": 1})
    an3.set_f_in(1000.7)
    an3.feed(fr3, t_now=2.0)
    s3 = an3.snapshot(2.0)
    muddy_note = " ".join(x for x in s3.get("notes", []) if "相位差不可测" in x)
    check("采样不足时判为 muddy", s3.get("ab_muddy") is True,
          "ratio=%.3f" % (s3.get("ab_muddy_ratio") or -1))
    check("muddy 文案按'箱数不够'分因并给自洽做法",
          # ★ 2026-10-17 全面自查：判据带上 div 后文案是「箱数×div/8」（div=1 时数值不变），
          #   旧断言写的字面 "箱数/8" 已不成立 —— 断言语义（箱子数与 inter 的自洽关系）不变。
          "箱数不够" in muddy_note and "箱数×div/8" in muddy_note
          and ("≤%d" % (64 // 8)) in muddy_note,
          muddy_note[:60])
    check("muddy 文案不再一口咬定'输入频率太高'", "输入频率太高" not in muddy_note, "")
    # ★ 2026-10-14 自查：per_cyc 曾写成 2*inter ⇒ "每箱跨几个周期"虚报一倍（64 箱 / inter=256
    #   实际是每箱跨 4.00 个 A/B 周期，错版会印成 8.00）。
    check("muddy 文案的'每箱跨几个周期'不虚报",
          "每电周期 256 个 A/B 周期" in muddy_note and "每箱跨 4.00 个周期" in muddy_note
          and "每箱跨 8.00 个周期" not in muddy_note, "")

    print("abz.py 自检：%d 项通过%s" % (ok, "" if not fail else "，失败 %s" % fail))
    return 0 if not fail else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="ABZ/UVW 等效采样分析（离线）")
    ap.add_argument("--selftest", action="store_true", help="跑离线自检")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
