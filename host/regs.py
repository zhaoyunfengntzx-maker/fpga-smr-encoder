"""寄存器地址与位域（依据 rtl/reg_file.v，纯逻辑，不碰串口）。

为什么要有这个文件
------------------
倍频面板要读写 0x0100~0x010C 这些“一个寄存器塞了多个字段”的地址，
位拼接规则散在 RTL 里（rtl/reg_file.v:559-578），把它集中成纯函数：
* 界面只负责取值/显示；
* 编码解码可以离线单测（python host\\regs.py --selftest），不用真的插板子。

★ 两条铁律
----------
1. 只能改自己要改的位：寄存器里还存着别的字段（有些是“仅存储”位），
   必须读-改-写（merge_bits / merge_zphase / merge_uvwph），不能整字覆盖。
   板上实测 0x0108 = 0x4004 就是例子：zwidth 只占低 4 位。
2. inter/div 是**两个寄存器拼出来的**：inter = {0x0102[1:0], 0x0101[7:0]}（10 位，
   0 视为 256），div = 0x0102[4:2] + 1（1…8）。改它们要同时写两个地址。
"""

REG_PAIRS = 0x0100        # [4:0] 极对数（0 = 32）
REG_INTER0 = 0x0101       # [7:0] INTER[7:0]
REG_INTER1 = 0x0102       # [1:0] INTER[9:8]  [4:2] div-1
REG_AB_HYST = 0x0103      # [4:0] AB 迟滞（角度 LSB）
REG_UVW_HYST = 0x0104     # [4:0] UVW 迟滞
REG_ABLIMIT = 0x0106      # [7:0] AB 限频（0..255）
REG_ZERO1 = 0x0108        # [3:0] Z 脉宽
REG_OUTPUT = 0x0109       # 极性/方向/使能 8 位
REG_ZPHASE = 0x010A       # [9:2] Z 相位高 8 位
REG_UVWPH = 0x010B        # [9:2] UVW 相位高 8 位
REG_PHASE_LSB = 0x010C    # [1:0] z 低 2 位  [3:2] uvw 低 2 位

# ---- v9（S2）延迟前馈：TAU_Q8 / FF_CFG / 只读速度与修正量 -------------------
REG_TAU0 = 0x0120         # [7:0]  TAU_Q8 低字节
REG_TAU1 = 0x0121         # [15:8] TAU_Q8 高字节（单位 = 抽样点 × 256）
REG_FF_CFG = 0x0122       # bit0 = 前馈使能（复位 1）
REG_FF_STAT = 0x0123      # 只读镜像 {…, en, en}
REG_FF_SPEED0 = 0x0124    # 只读：每抽样点位置增量（= 环路积分器）24 位有符号
REG_FF_SPEED1 = 0x0125
REG_FF_SPEED2 = 0x0126
REG_FF_CORR0 = 0x0127     # 只读：当前延迟修正量（位置单位）24 位有符号
REG_FF_CORR1 = 0x0128
REG_FF_CORR2 = 0x0129

# ---- v9（S3）锁定状态机 -----------------------------------------------------
REG_LOCK_STATE = 0x0130   # [1:0] 0=INIT 1=TRACK 2=LOST
REG_LOCK_STICKY = 0x0131  # bit0=曾锁定 bit1=曾掉锁（W1C） bit2=当前已锁定
REG_LOST_CNT0 = 0x0132    # 累计掉锁次数
REG_LOST_CNT1 = 0x0133
REG_BAD_RUN0 = 0x0134     # 当前连续坏样本数
REG_BAD_RUN1 = 0x0135

# ---- v9（S4）偏置慢跟踪 -----------------------------------------------------
REG_BIAS_S0 = 0x0138      # 跟踪到的 sin 偏置（16 位有符号）
REG_BIAS_S1 = 0x0139
REG_BIAS_C0 = 0x013A      # 跟踪到的 cos 偏置
REG_BIAS_C1 = 0x013B
REG_BIAS_ST = 0x013C      # bit0=valid bit1=big

# ---- v9（S5）全周补偿表（4096×16）------------------------------------------
REG_LUT_ADDR0 = 0x0141    # 表地址低字节（高字节在 0x0142）
REG_LUT_ADDR1 = 0x0142    # [3:0] 表地址高 4 位
REG_LUT_DATA0 = 0x0143    # 表数据低字节（高字节在 0x0144，写入即触发写脉冲）
REG_LUT_DATA1 = 0x0144
REG_LUT_CTRL = 0x0145     # bit0 = 启用（复位 0 = 旁路） bit1 = 回读探针
REG_LUT_READ0 = 0x0146    # 只读：表回读低字节（0x0145 bit1=1 时跟随表地址）
REG_LUT_READ1 = 0x0147    # 只读：表回读高字节
LUT_N = 4096              # 表点数（0.0879°/点）

INTER_MIN, INTER_MAX = 2, 256     # rtl/abz_gen.v:118 注释“0 视为 256；2…256”
DIV_MIN, DIV_MAX = 1, 8           # rtl/abz_gen.v:119 注释“寄存器值 = div-1”
PAIRS_MIN, PAIRS_MAX = 1, 32      # 0 表示 32

OUTPUT_BITS = ("apol", "bpol", "zpol", "abzdir", "uvwpol", "uvwdir", "abzen", "uwven")
OUTPUT_LABELS = {
    "apol": "A 极性",
    "bpol": "B 极性",
    "zpol": "Z 极性",
    "abzdir": "AB 方向反向",
    "uvwpol": "UVW 极性",
    "uvwdir": "UVW 方向反向",
    "abzen": "ABZ 使能",
    "uwven": "UVW 使能",
}

# 倍频面板要读回来的地址（连接/自检时一次读齐）
CFG_ADDRS = (REG_PAIRS, REG_INTER0, REG_INTER1, REG_AB_HYST, REG_UVW_HYST,
             REG_ABLIMIT, REG_ZERO1, REG_OUTPUT, REG_ZPHASE, REG_UVWPH, REG_PHASE_LSB)


# ---------------------------------------------------------------------------
# 通用位域操作
# ---------------------------------------------------------------------------
def mask_shift(mask):
    """返回 mask 最低置位的位置（0 位掩码 → 0）。"""
    if not mask:
        return 0
    return (mask & -mask).bit_length() - 1


def get_bits(value, mask):
    """取出 mask 覆盖的位（右对齐）。"""
    if value is None:
        return None
    return (int(value) & mask) >> mask_shift(mask)


def merge_bits(cur, mask, value):
    """读-改-写：只改 mask 覆盖的位。"""
    shift = mask_shift(mask)
    return (int(cur) & ~mask & 0xFFFF) | ((int(value) << shift) & mask)


# ---------------------------------------------------------------------------
# v9：延迟前馈 / 偏置 / 全周补偿表
# ---------------------------------------------------------------------------
def s16(v):
    """16 位补码 → Python 有符号整数。"""
    v = int(v) & 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s24(lo, mid, hi):
    """三个字节（低/中/高）→ 24 位有符号整数。"""
    v = (int(lo) & 0xFF) | ((int(mid) & 0xFF) << 8) | ((int(hi) & 0xFF) << 16)
    return v - 0x1000000 if v & 0x800000 else v


def encode_tau(samples):
    """延迟（抽样点，可为小数）→ TAU_Q8 写入值（×256）。"""
    q = int(round(float(samples) * 256.0))
    if not (0 <= q <= 0xFFFF):
        raise ValueError("TAU_Q8 超出 0..255.996 抽样点：%r" % (samples,))
    return q


def decode_tau(q):
    """TAU_Q8 读回值 → 抽样点（浮点）。"""
    return int(q) / 256.0


def lut_entry_writes(addr, value):
    """一条补偿表记录的写序列 ⇒ [(寄存器地址, 写入的 16 位值), …]。

    ★ 桥一次事务写两个字节：低字节→addr、高字节→addr+1（rtl/spi_slave.v:244-251），
      所以写 0x0141 会同时把地址高 4 位写进 0x0142，写 0x0143 会同时触发 0x0144
      的写脉冲把整条记录推进 BRAM。**一条记录只需 2 次事务**，别拆成 4 次。
    """
    a = int(addr)
    if not (0 <= a < LUT_N):
        raise ValueError("表地址越界 0..%d：%r" % (LUT_N - 1, addr))
    return [(REG_LUT_ADDR0, a & 0xFFFF), (REG_LUT_DATA0, int(value) & 0xFFFF)]


def lut_words_from_pairs(pairs):
    """[(机械角 deg, 误差 arcsec), …] → 4096 点修正量（16 位有符号 LSB）。

    线性插值到 4096 个等分点；输入需已按角度升序且覆盖 0..360。
    修正量的 LSB 与 2^FRAC 细分一致（PPR=2048、AW=16 时 1 LSB ≈ 0.0097″），
    所以 arcsec → LSB 的换算是 arcsec / (3600 * 360 / (PPR * 2^AW))。
    """
    import bisect

    def _lsb_arcsec(ppr=2048, aw=16):
        return 3600.0 * 360.0 / (float(ppr) * (1 << aw))

    k = _lsb_arcsec()
    xs = [float(p[0]) for p in pairs]
    ys = [float(p[1]) / k for p in pairs]          # arcsec → LSB
    out = []
    for i in range(LUT_N):
        deg = 360.0 * i / LUT_N
        j = bisect.bisect_right(xs, deg)
        if j == 0:
            out.append(int(round(ys[0])))
        elif j >= len(xs):
            out.append(int(round(ys[-1])))
        else:
            x0, x1 = xs[j - 1], xs[j]
            t = 0.0 if x1 == x0 else (deg - x0) / (x1 - x0)
            out.append(int(round(ys[j - 1] + (ys[j] - ys[j - 1]) * t)))
    # 16 位有符号饱和：±0.088°（= ±316″）以外不可能靠这张表修
    return [max(-32768, min(32767, v)) for v in out]


# ---------------------------------------------------------------------------
# 倍频 inter / div
# ---------------------------------------------------------------------------
def decode_inter_div(v101, v102, default_inter=256):
    """(inter, div) ← 0x0101/0x0102 的读回值。0 按板上语义当成 256。"""
    if v101 is None or v102 is None:
        return None, None
    inter = ((int(v101) & 0xFF) | ((int(v102) & 0x03) << 8))
    if inter == 0:
        inter = default_inter
    div = ((int(v102) >> 2) & 0x07) + 1
    return inter, div


def encode_inter_div(inter, div):
    """(0x0101, 0x0102) 的写入值。"""
    inter = int(inter)
    div = int(div)
    if not INTER_MIN <= inter <= INTER_MAX:
        raise ValueError("inter 必须在 %d…%d 之间" % (INTER_MIN, INTER_MAX))
    if not DIV_MIN <= div <= DIV_MAX:
        raise ValueError("div 必须在 %d…%d 之间" % (DIV_MIN, DIV_MAX))
    v101 = inter & 0xFF
    v102 = ((inter >> 8) & 0x03) | ((div - 1) << 2)
    return v101, v102


def equiv_mult(inter, div):
    """等效倍率 = inter / div（每个输入周期输出多少个 A 脉冲）。"""
    if not inter or not div:
        return None
    return float(inter) / float(div)


def edge_rate(inter, div, f_in):
    """AB 输出边沿率（A+B 合计跳变数/秒）= 4 × inter/div × f_in。"""
    m = equiv_mult(inter, div)
    if m is None or f_in is None:
        return None
    return 4.0 * m * abs(float(f_in))


def channel_rate(inter, div, f_in):
    """单通道（A）脉冲频率 = inter/div × f_in。"""
    m = equiv_mult(inter, div)
    if m is None or f_in is None:
        return None
    return m * abs(float(f_in))


# ---------------------------------------------------------------------------
# 极对数
# ---------------------------------------------------------------------------
def decode_pairs(value):
    """返回 (有效极对数, 寄存器原始值)。0 表示 32。"""
    if value is None:
        return None, None
    raw = int(value) & 0x1F
    return (32 if raw == 0 else raw), raw


def encode_pairs(pairs):
    p = int(pairs)
    if not PAIRS_MIN <= p <= PAIRS_MAX:
        raise ValueError("极对数必须在 %d…%d 之间" % (PAIRS_MIN, PAIRS_MAX))
    return 0 if p == 32 else (p & 0x1F)


# ---------------------------------------------------------------------------
# 0x0109 极性/方向/使能
# ---------------------------------------------------------------------------
def decode_output(value):
    if value is None:
        return None
    return {name: (int(value) >> i) & 1 for i, name in enumerate(OUTPUT_BITS)}


def encode_output(bits):
    v = 0
    for i, name in enumerate(OUTPUT_BITS):
        if bits.get(name):
            v |= (1 << i)
    return v & 0xFF


def output_text(value):
    """把 8 位拼成一行中文（日志/提示用）。"""
    bits = decode_output(value)
    if bits is None:
        return "—"
    on = [OUTPUT_LABELS[n] for n in OUTPUT_BITS if bits[n]]
    return "、".join(on) if on else "全 0"


# ---------------------------------------------------------------------------
# 相位（两个寄存器拼一个 10 位值，单位 360/1024）
# ---------------------------------------------------------------------------
def decode_zphase(v010a, v010c):
    if v010a is None or v010c is None:
        return None
    return ((int(v010a) & 0xFF) << 2) | (int(v010c) & 0x03)


def merge_zphase(value, cur_010a, cur_010c):
    """返回 (新 0x010A, 新 0x010C)；低 2 位在 0x010C，必须读-改-写。"""
    v = int(value) & 0x3FF
    return (v >> 2) & 0xFF, (int(cur_010c) & ~0x03 & 0xFFFF) | (v & 0x03)


def decode_uvwph(v010b, v010c):
    if v010b is None or v010c is None:
        return None
    return ((int(v010b) & 0xFF) << 2) | ((int(v010c) >> 2) & 0x03)


def merge_uvwph(value, cur_010b, cur_010c):
    """返回 (新 0x010B, 新 0x010C)；低 2 位在 0x010C[3:2]。"""
    v = int(value) & 0x3FF
    return (v >> 2) & 0xFF, (int(cur_010c) & ~0x0C & 0xFFFF) | ((v & 0x03) << 2)


def phase_deg(value):
    """单位 360/1024 → 度。"""
    return None if value is None else float(value) * 360.0 / 1024.0


# ---------------------------------------------------------------------------
# 板上运行状态镜像：把 v9 那几段"只在文档里、从没上过屏"的地址读成一个可看的表
# ★ 这些地址以前在界面上一处都没有：前馈在不在工作、锁定状态机停在哪一档、
#   掉过几次锁、板上自己跟踪的偏置是多少、补偿表启用没启用 —— 全靠猜。
#   它们都**只读或半只读**，读一遍 ~29 次事务 ≈ 15 ms，对 10 kHz 遥测无感。
# ---------------------------------------------------------------------------
STATUS_ADDRS = (
    REG_AB_HYST, REG_UVW_HYST, REG_ABLIMIT, REG_ZERO1, REG_ZPHASE, REG_UVWPH,
    REG_PHASE_LSB, REG_TAU0, REG_TAU1, REG_FF_CFG, REG_FF_STAT,
    REG_FF_SPEED0, REG_FF_SPEED1, REG_FF_SPEED2,
    REG_FF_CORR0, REG_FF_CORR1, REG_FF_CORR2,
    REG_LOCK_STATE, REG_LOCK_STICKY, REG_LOST_CNT0, REG_LOST_CNT1,
    REG_BAD_RUN0, REG_BAD_RUN1, REG_BIAS_S0, REG_BIAS_S1, REG_BIAS_C0,
    REG_BIAS_C1, REG_BIAS_ST, REG_LUT_CTRL,
)

LOCK_STATE_TEXT = ("INIT", "TRACK", "LOST", "保留")


def _pick(raw, addr):
    v = raw.get(addr)
    return None if v is None else (int(v) & 0xFF)


def decode_status(raw):
    """{寄存器地址: 字节值} → 结构化状态（缺哪个键就填 None，**不编数**）。

    raw 里没读到的地址一律给 None：界面上显示"—"，而不是把 0 当成真值
    （0x0130=0 恰好是 INIT，把"没读到"显示成"INIT"就是在骗人）。
    """
    out = {
        "ab_hyst": None, "uvw_hyst": None, "ab_limit": None, "z_width": None,
        "z_phase": None, "uvw_phase": None, "z_phase_deg": None,
        "uvw_phase_deg": None,
        "tau_samples": None, "ff_en": None, "ff_stat_en": None,
        "ff_speed": None, "ff_corr": None,
        "lock_state": None, "lock_state_text": None, "lock_sticky": None,
        "lost_cnt": None, "bad_run": None,
        "bias_s": None, "bias_c": None, "bias_valid": None, "bias_big": None,
        "lut_enabled": None, "lut_probe": None,
    }
    v_ab, v_uvw, v_lim, v_z = (_pick(raw, REG_AB_HYST), _pick(raw, REG_UVW_HYST),
                               _pick(raw, REG_ABLIMIT), _pick(raw, REG_ZERO1))
    out.update({"ab_hyst": None if v_ab is None else v_ab & 0x1F,
                "uvw_hyst": None if v_uvw is None else v_uvw & 0x1F,
                "ab_limit": v_lim,
                "z_width": None if v_z is None else v_z & 0x0F})

    z_hi, u_hi, lsb = (_pick(raw, REG_ZPHASE), _pick(raw, REG_UVWPH),
                       _pick(raw, REG_PHASE_LSB))
    if z_hi is not None and lsb is not None:
        zp = ((z_hi & 0xFF) << 2) | (lsb & 0x03)
        out["z_phase"] = zp
        out["z_phase_deg"] = phase_deg(zp)
    if u_hi is not None and lsb is not None:
        up = ((u_hi & 0xFF) << 2) | ((lsb >> 2) & 0x03)
        out["uvw_phase"] = up
        out["uvw_phase_deg"] = phase_deg(up)

    t0, t1 = _pick(raw, REG_TAU0), _pick(raw, REG_TAU1)
    if t0 is not None and t1 is not None:
        out["tau_samples"] = decode_tau((t1 << 8) | t0)
    ff = _pick(raw, REG_FF_CFG)
    if ff is not None:
        out["ff_en"] = bool(ff & 0x01)
    ffs = _pick(raw, REG_FF_STAT)
    if ffs is not None:
        out["ff_stat_en"] = bool(ffs & 0x01)
    b0, b1, b2 = (_pick(raw, REG_FF_SPEED0), _pick(raw, REG_FF_SPEED1),
                  _pick(raw, REG_FF_SPEED2))
    if None not in (b0, b1, b2):
        out["ff_speed"] = s24(b0, b1, b2)
    c0, c1, c2 = (_pick(raw, REG_FF_CORR0), _pick(raw, REG_FF_CORR1),
                  _pick(raw, REG_FF_CORR2))
    if None not in (c0, c1, c2):
        out["ff_corr"] = s24(c0, c1, c2)

    lk = _pick(raw, REG_LOCK_STATE)
    if lk is not None:
        st = lk & 0x03
        out["lock_state"] = st
        out["lock_state_text"] = LOCK_STATE_TEXT[st]
    stk = _pick(raw, REG_LOCK_STICKY)
    if stk is not None:
        out["lock_sticky"] = stk & 0x07
        out["lock_ever"] = bool(stk & 0x01)
        out["lock_lost_ever"] = bool(stk & 0x02)
        out["lock_now"] = bool(stk & 0x04)
    l0, l1 = _pick(raw, REG_LOST_CNT0), _pick(raw, REG_LOST_CNT1)
    if l0 is not None and l1 is not None:
        out["lost_cnt"] = (l1 << 8) | l0
    d0, d1 = _pick(raw, REG_BAD_RUN0), _pick(raw, REG_BAD_RUN1)
    if d0 is not None and d1 is not None:
        out["bad_run"] = (d1 << 8) | d0

    s0, s1 = _pick(raw, REG_BIAS_S0), _pick(raw, REG_BIAS_S1)
    if s0 is not None and s1 is not None:
        out["bias_s"] = s16((s1 << 8) | s0)
    c_0, c_1 = _pick(raw, REG_BIAS_C0), _pick(raw, REG_BIAS_C1)
    if c_0 is not None and c_1 is not None:
        out["bias_c"] = s16((c_1 << 8) | c_0)
    bst = _pick(raw, REG_BIAS_ST)
    if bst is not None:
        out["bias_valid"] = bool(bst & 0x01)
        out["bias_big"] = bool(bst & 0x02)

    lc = _pick(raw, REG_LUT_CTRL)
    if lc is not None:
        out["lut_enabled"] = bool(lc & 0x01)
        out["lut_probe"] = bool(lc & 0x02)
    return out


def _fmt(v, spec="%s", none="—"):
    return none if v is None else (spec % v)


def status_rows(raw):
    """decode_status() → [(名称, 值文本, 说明), …]，给诊断页的表直接用。

    值文本里"没读到"统一是"—"：这一列出现"—"就说明那次读取没成功，
    比显示 0 安全得多（0 在 0x0130 上是合法的 INIT）。
    """
    d = decode_status(raw)
    rows = [
        ("锁定状态", _fmt(d["lock_state_text"]),
         "0x0130：INIT 未锁定 / TRACK 跟踪中 / LOST 掉锁"),
        ("锁定历史", "—" if d["lock_sticky"] is None else
         "%s%s%s" % ("曾锁定 " if d.get("lock_ever") else "",
                     "曾掉锁 " if d.get("lock_lost_ever") else "",
                     "当前锁定" if d.get("lock_now") else ""),
         "0x0131 粘滞位（掉锁位是 W1C，写 1 清除）"),
        ("累计掉锁", _fmt(d["lost_cnt"], "%d 次"),
         "0x0132/0x0133：上电以来掉锁次数"),
        ("连续坏样本", _fmt(d["bad_run"], "%d 个"),
         "0x0134/0x0135：当前连续坏样本数，到阈值就进 LOST"),
        ("前馈延迟", _fmt(d["tau_samples"], "%.3f 抽样点"),
         "0x0120/0x0121：TAU_Q8，单位 = 抽样点 × 256"),
        ("前馈使能", "—" if d["ff_en"] is None else ("开" if d["ff_en"] else "关"),
         "0x0122 bit0（复位值 1）；0x0123 是只读镜像"),
        ("前馈速度", _fmt(d["ff_speed"], "%d LSB/抽样点"),
         "0x0124-6：24 位有符号，等于环路积分器"),
        ("前馈修正", _fmt(d["ff_corr"], "%d 位置 LSB"),
         "0x0127-9：24 位有符号，当前延迟修正量"),
        ("偏置 S", _fmt(d["bias_s"], "%d LSB"), "0x0138/9：板上自己跟踪到的 sin 偏置"),
        ("偏置 C", _fmt(d["bias_c"], "%d LSB"), "0x013A/B：同上，cos 路"),
        ("偏置状态", "—" if d["bias_valid"] is None else
         "%s%s" % ("有效 " if d["bias_valid"] else "无效 ",
                   "偏大" if d["bias_big"] else "正常"),
         "0x013C：bit0 valid、bit1 big（偏置超过量程的 25%）"),
        ("补偿表", "—" if d["lut_enabled"] is None else
         ("启用" if d["lut_enabled"] else "旁路"),
         "0x0145 bit0（复位 0 = 旁路）；bit1 是回读探针"),
        ("AB 迟滞", _fmt(d["ab_hyst"], "%d 档"),
         "0x0103[4:0]：单位 360°/2048；0 = 不启用"),
        ("UVW 迟滞", _fmt(d["uvw_hyst"], "%d" if d["uvw_hyst"] is None else "%d LSB"),
         "0x0104[4:0]：单位角度 LSB；0 = 用默认档 1024"),
        ("AB 限频", _fmt(d["ab_limit"], "%d" if d["ab_limit"] is None else "%d"),
         "0x0106：最小边沿间隔 = 20 ns × (值+1) × div"),
        ("Z 脉宽", _fmt(d["z_width"], "%d 步"),
         "0x0108[3:0]：宽 = 值+1 个边沿步（0 也出 1 步）"),
        ("Z 相位", _fmt(d["z_phase_deg"], "%.2f°"),
         "0x010A + 0x010C[1:0]：单位 360/1024°"),
        ("UVW 相位", _fmt(d["uvw_phase_deg"], "%.2f°"),
         "0x010B + 0x010C[3:2]：单位 360/1024°"),
    ]
    return rows


# ---------------------------------------------------------------------------
# 高级参数面板的字段定义（界面照这个表自动建控件）
# ★ 2026-10-17 自查：hint 文案也是"接口"，必须跟 RTL 走。踩过两处：
#   · AB 迟滞单位是 360°/2048（rtl/abz_gen.v:120，= 32 角度 LSB），且 hyst=0 时
#     hyst_pass/trig_ok 直接放行 ⇒ 0 = 不启用迟滞（不是"用默认档"）；
#   · Z 脉宽 v9 起（rtl/abz_gen.v:130/:520/:694）宽 = z_width+1 个边沿步，**0 也出 1 步**，
#     不再是"0 = 不出 Z"（那是 v8 行为）。UVW 迟滞确有编译期默认档（rtl/uvw_gen.v:184）。
# ---------------------------------------------------------------------------
ADV_FIELDS = (
    {"key": "hyst_ab", "label": "AB 迟滞", "addr": REG_AB_HYST, "mask": 0x001F,
     "lo": 0, "hi": 31, "hint": "单位 360°/2048（= 32 角度 LSB）；0 = 不启用迟滞（与 UVW 不同）"},
    {"key": "hyst_uvw", "label": "UVW 迟滞", "addr": REG_UVW_HYST, "mask": 0x001F,
     "lo": 0, "hi": 31, "hint": "单位 = 角度 LSB；0 = 用默认档（1024 LSB）"},
    {"key": "ablimit", "label": "AB 限频", "addr": REG_ABLIMIT, "mask": 0x00FF,
     "lo": 0, "hi": 255, "hint": "最小边沿间隔 = 20 ns × (值+1) × div"},
    {"key": "zwidth", "label": "Z 脉宽", "addr": REG_ZERO1, "mask": 0x000F,
     "lo": 0, "hi": 15, "hint": "宽 = 值+1 个边沿步（0 也出 1 步，v9 起）；折合输出边沿 ≈ (值+1)/div"},
    {"key": "zphase", "label": "Z 相位", "addr": REG_ZPHASE, "mask": 0x03FF,
     "lo": 0, "hi": 1023, "hint": "单位 360/1024°（两个寄存器拼）"},
    {"key": "uvwph", "label": "UVW 相位", "addr": REG_UVWPH, "mask": 0x03FF,
     "lo": -512, "hi": 511, "hint": "单位 360/1024°，环绕一个电周期"},
)


def adv_field_value(key, regs_raw):
    """从读回的寄存器字典里取出某个高级字段当前值。"""
    raw = regs_raw or {}
    if key == "zphase":
        return decode_zphase(raw.get(REG_ZPHASE), raw.get(REG_PHASE_LSB))
    if key == "uvwph":
        v = decode_uvwph(raw.get(REG_UVWPH), raw.get(REG_PHASE_LSB))
        return None if v is None else (v - 1024 if v > 511 else v)
    for spec in ADV_FIELDS:
        if spec["key"] == key:
            return get_bits(raw.get(spec["addr"]), spec["mask"])
    return None


def adv_field_writes(key, value, regs_raw):
    """算出“要写哪些地址、写什么值”（只含真的变了的地址）。

    ★ 读不到该地址的现值时返回 None（=“缺板上现值，先去点『读回』”），不猜 0：
      以前 `cur or 0` 把基址当 0 做整字节覆盖，会清掉同一字节里其它字段的位 ——
      真机上 0x0108 的 bit14 是板上固定置位的（读到 0xC004），若读失败再改 zwidth，
      写出的 {0x0108: 0x0004} 会把 bit14 抹掉（审计发现，真踩过）。
    """
    raw = regs_raw or {}
    out = {}
    if key in ("zphase", "uvwph"):
        a_addr = REG_ZPHASE if key == "zphase" else REG_UVWPH
        a_cur = raw.get(a_addr)
        c_cur = raw.get(REG_PHASE_LSB)
        if a_cur is None or c_cur is None:
            return None
        if key == "zphase":
            a, c = merge_zphase(value, a_cur, c_cur)
        else:
            a, c = merge_uvwph(value, a_cur, c_cur)
        if a_cur != a:
            out[a_addr] = a
        if c_cur != c:
            out[REG_PHASE_LSB] = c
        return out
    for spec in ADV_FIELDS:
        if spec["key"] == key:
            cur = raw.get(spec["addr"])
            if cur is None:
                return None
            new = merge_bits(cur, spec["mask"], value)
            if cur != new:
                out[spec["addr"]] = new
            return out
    return out


# ---------------------------------------------------------------------------
# 自检（离线）：python host\regs.py --selftest
# ---------------------------------------------------------------------------
def selftest():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print("%-46s %s" % (name, "PASS" if good else
                            "FAIL  got=%r want=%r" % (got, want)))

    # 板上实测值：inter=32、div=1（demo_abz_uvw.py 写进去的）
    check("decode(0x0020, 0x0000) = (32, 1)", decode_inter_div(0x0020, 0x0000), (32, 1))
    # 0x0102=0x001C → div=8（tools/uart_spi.py:149-157 的 HINT）
    check("decode(0x0000, 0x001C) = (256, 8)",
          decode_inter_div(0x0000, 0x001C), (256, 8))
    check("decode(0x0000, 0x0000) = (256, 1)  # 0 视为 256",
          decode_inter_div(0x0000, 0x0000), (256, 1))
    # 读回失败（None）必须早退成 (None, None)，不能去 int(None) 崩
    check("decode(None, 0) = (None, None)", decode_inter_div(None, 0), (None, None))
    check("decode(None, None) = (None, None)", decode_inter_div(None, None), (None, None))
    check("encode(64, 1) = (0x0040, 0x0000)", encode_inter_div(64, 1), (0x40, 0x00))
    check("encode(256, 1) = (0x0000, 0x0001)", encode_inter_div(256, 1), (0x00, 0x01))
    check("encode(300, 8) 超范围应报错", _raises(encode_inter_div, 300, 8), True)
    check("encode(64, 9) 超范围应报错", _raises(encode_inter_div, 64, 9), True)

    # 往返：2…256 × 1…8 全部编解码一致
    bad = []
    for i in range(INTER_MIN, INTER_MAX + 1):
        for d in range(DIV_MIN, DIV_MAX + 1):
            a, b = encode_inter_div(i, d)
            if decode_inter_div(a, b) != (i, d):
                bad.append((i, d, a, b))
    check("2…256 × 1…8 全量往返一致（%d 组）" % (255 * 8), bad, [])

    check("equiv_mult(64,1) = 64", equiv_mult(64, 1), 64.0)
    check("edge_rate(64,1,1000) = 256000", edge_rate(64, 1, 1000.0), 256000.0)

    check("decode_pairs(0x04) = (4, 4)", decode_pairs(0x04), (4, 4))
    check("decode_pairs(0x00) = (32, 0)", decode_pairs(0x00), (32, 0))
    check("encode_pairs(32) = 0", encode_pairs(32), 0)
    check("encode_pairs(4) = 4", encode_pairs(4), 4)

    # 板上实测 0x0108 = 0x4004 ⇒ 只改低 4 位，高位必须原样保留
    check("merge_bits(0x4004, 0xF, 6) = 0x4006",
          merge_bits(0x4004, 0x000F, 6), 0x4006)
    check("get_bits(0x4004, 0xF) = 4", get_bits(0x4004, 0x000F), 4)

    # 板上实测 0x0109 = 0x00C0 ⇒ abzen + uwven
    check("decode_output(0x00C0) 中 abzen/uwven 为 1",
          (decode_output(0x00C0)["abzen"], decode_output(0x00C0)["uwven"]), (1, 1))
    check("encode_output 往返", encode_output(decode_output(0x00C0)), 0x00C0)
    check("encode_output({abzen:1}) = 0x40", encode_output({"abzen": 1}), 0x40)

    # 相位：0x010A/0x010C 拼 10 位
    check("decode_zphase(0x28, 0x0002) = 162",
          decode_zphase(0x28, 0x0002), (0x28 << 2) | 2)
    a, c = merge_zphase(162, 0x28, 0x0002)
    check("merge_zphase 原位写回不动其他位", (a, c), (0x28, 0x0002))
    a, c = merge_zphase(0, 0x28, 0x000E)     # uvw 低 2 位是 0b11，不能被抹掉
    check("merge_zphase 保留 0x010C[3:2]", (a, c), (0x00, 0x000C))
    a, c = merge_uvwph(0, 0x10, 0x0002)      # z 低 2 位是 0b10，不能被抹掉
    check("merge_uvwph 保留 0x010C[1:0]", (a, c), (0x00, 0x0002))
    check("phase_deg(256) = 90.0", phase_deg(256), 90.0)

    # 高级字段：算出写入值
    raw = {REG_AB_HYST: 0x0002, REG_ZERO1: 0x4004, REG_ZPHASE: 0x28,
           REG_UVWPH: 0x00, REG_PHASE_LSB: 0x0002, REG_ABLIMIT: 0x0000}
    check("adv hyst_ab 不变则不写", adv_field_writes("hyst_ab", 2, raw), {})
    check("adv hyst_ab 2→3 只写 0x0103",
          adv_field_writes("hyst_ab", 3, raw), {REG_AB_HYST: 0x0003})
    check("adv zwidth 4→6 保留 0x4000",
          adv_field_writes("zwidth", 6, raw), {REG_ZERO1: 0x4006})
    check("adv_field_value(zwidth) = 4", adv_field_value("zwidth", raw), 4)
    check("adv_field_value(zphase) = 162", adv_field_value("zphase", raw), 162)
    # ★ 缺板上现值时必须拒写（不能拿 0 当基址做整字节覆盖，那会清掉同字节其它位）
    check("adv 缺现值不猜 0（zwidth）", adv_field_writes("zwidth", 6, {}), None)
    check("adv 缺现值不猜 0（zphase）",
          adv_field_writes("zphase", 5, {REG_ZPHASE: 0x28}), None)
    check("adv 现值为 0 时正常计算（≠缺值）",
          adv_field_writes("hyst_ab", 3, {REG_AB_HYST: 0}), {REG_AB_HYST: 0x0003})

    # ★ 界面提示也得跟 RTL 走（自查发现旧文案停留在 v8 语义）：
    _hints = {s["key"]: s["hint"] for s in ADV_FIELDS}
    check("zwidth 提示写明 v9 起「0 也出 1 步」",
          ("v9" in _hints["zwidth"]) and ("1 步" in _hints["zwidth"])
          and ("不出 Z" not in _hints["zwidth"]), True)
    check("AB 迟滞提示写明 0 = 不启用（不再写「默认档」）",
          ("不启用" in _hints["hyst_ab"]) and ("默认档" not in _hints["hyst_ab"]),
          True)
    check("UVW 迟滞提示保留「默认档」（RTL 确有编译期默认）",
          "默认档" in _hints["hyst_uvw"], True)
    # regs.py 的 check(name, got, want) 是"值比对"式，没有信息列 ⇒ 提示原文单独打一行
    print("  提示原文：zwidth=%s" % _hints["zwidth"])
    print("            hyst_ab=%s" % _hints["hyst_ab"])
    print("            hyst_uvw=%s" % _hints["hyst_uvw"])

    # ---- v9：延迟前馈 / 偏置 / 全周补偿表 ----
    check("s16(0xFFFB) = -5", s16(0xFFFB), -5)
    check("s16(0x7FFF) = 32767", s16(0x7FFF), 32767)
    check("s24(0x24,0x12,0x00) = 0x1224", s24(0x24, 0x12, 0x00), 0x1224)
    check("s24(0xFF,0xFF,0xFF) = -1", s24(0xFF, 0xFF, 0xFF), -1)
    check("encode_tau(9.0) = 2304", encode_tau(9.0), 2304)
    check("decode_tau(2304) = 9.0", decode_tau(2304), 9.0)
    check("encode_tau 超范围抛 ValueError", _raises(encode_tau, 300.0), True)
    # ★ 一条表记录只需 2 次事务（桥一次写 2 字节，高字节自动落到 addr+1）
    check("lut_entry_writes(0x123, -5)",
          lut_entry_writes(0x123, -5),
          [(REG_LUT_ADDR0, 0x0123), (REG_LUT_DATA0, 0xFFFB)])
    check("lut_entry_writes 越界抛 ValueError", _raises(lut_entry_writes, 4096, 0), True)
    _w = lut_words_from_pairs([(0.0, 0.0), (180.0, 3600.0), (360.0, 7200.0)])
    check("lut_words_from_pairs 长度 = 4096", len(_w), 4096)
    check("lut_words_from_pairs 起点 = 0", _w[0], 0)
    check("lut_words_from_pairs 单调递增", _w[2048] > _w[0], True)

    # ---- 板上运行状态镜像（诊断页「读一次」的表就靠这个）----
    _raw = {
        REG_LOCK_STATE: 1,                  # TRACK
        REG_LOCK_STICKY: 0x05,              # 曾锁定 + 当前锁定
        REG_LOST_CNT0: 3, REG_LOST_CNT1: 0,
        REG_BAD_RUN0: 2, REG_BAD_RUN1: 0,
        REG_TAU0: 0x00, REG_TAU1: 0x09,     # 9.0 抽样点
        REG_FF_CFG: 0x01, REG_FF_STAT: 0x01,
        REG_FF_SPEED0: 0x24, REG_FF_SPEED1: 0x12, REG_FF_SPEED2: 0x00,
        REG_FF_CORR0: 0xFF, REG_FF_CORR1: 0xFF, REG_FF_CORR2: 0xFF,   # -1
        REG_BIAS_S0: 0xF6, REG_BIAS_S1: 0xFF,                          # -10
        REG_BIAS_C0: 0x0A, REG_BIAS_C1: 0x00,                          # +10
        REG_BIAS_ST: 0x01,
        REG_LUT_CTRL: 0x00,
        REG_AB_HYST: 0x03, REG_UVW_HYST: 0x1F, REG_ABLIMIT: 0x40,
        REG_ZERO1: 0x02, REG_ZPHASE: 0x40, REG_UVWPH: 0x00, REG_PHASE_LSB: 0x0A,
    }
    _d = decode_status(_raw)
    check("状态镜像 锁定 = TRACK", _d["lock_state_text"], "TRACK")
    check("状态镜像 曾锁定=1 当前锁定=1 曾掉锁=0",
          (_d["lock_ever"], _d["lock_now"], _d["lock_lost_ever"]), (True, True, False))
    check("状态镜像 掉锁次数 = 3", _d["lost_cnt"], 3)
    check("状态镜像 前馈延迟 = 9.0 抽样点", _d["tau_samples"], 9.0)
    check("状态镜像 前馈速度 = 0x1224", _d["ff_speed"], 0x1224)
    check("状态镜像 前馈修正 = -1", _d["ff_corr"], -1)
    check("状态镜像 偏置 S = -10", _d["bias_s"], -10)
    check("状态镜像 偏置 C = +10", _d["bias_c"], 10)
    check("状态镜像 偏置 bit0 = 有效", _d["bias_valid"], True)
    check("状态镜像 Z 相位 = 0x40<<2 | 2 = 258", _d["z_phase"], 258)
    check("状态镜像 UVW 相位 = 0<<2 | 2 = 2", _d["uvw_phase"], 2)
    check("状态镜像 AB 迟滞 = 3", _d["ab_hyst"], 3)
    check("状态镜像 Z 脉宽 = 2", _d["z_width"], 2)
    check("状态镜像 补偿表 = 旁路", _d["lut_enabled"], False)
    # 缺地址必须给 None（0x0130=0 是合法的 INIT，不能拿"没读到"冒充 INIT）
    _miss = decode_status({})
    check("状态镜像 空 raw 全 None（不把没读到当 INIT）", _miss["lock_state_text"], None)
    _rows = status_rows(_raw)
    check("状态表行数 = 18", len(_rows), 18)
    check("状态表没读到的行写「—」", status_rows({})[0][1], "—")
    check("状态表前馈延迟带单位", _rows[4][1], "9.000 抽样点")

    print("自检%s" % ("通过 (PASS)" if ok else "失败 (FAIL)"))
    return 0 if ok else 1


def _raises(fn, *a):
    try:
        fn(*a)
        return False
    except ValueError:
        return True


def main(argv=None):
    import sys
    argv = sys.argv[1:] if argv is None else argv
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:                                    # noqa: BLE001
        pass
    if "--selftest" in argv or not argv:
        return selftest()
    print("用法：python host\\regs.py --selftest")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
