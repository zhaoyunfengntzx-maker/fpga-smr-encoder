"""上位机里那些"跑在临时线程里、只碰串口不碰界面"的任务函数。

设计约束（改这个文件前先读）：
1. **这里不许 import Qt，也不许碰任何 widget**。参数只有 `worker`（link.SerialWorker）
   和纯数据，返回值也是纯数据（dict / list / None）。界面怎么显示由 main_window 的
   `_done_xxx` 负责 —— 这条界线一破，自检就再也跑不起来（没有 QApplication 时导入即崩）。
2. **同一个 worker 只能有一个任务在跑**。串口是单主人模型，且寄存器事务是"发一帧等一帧"，
   两个任务交错会把应答配错对（旧版本就因此出现过"写生效却报失败"）。调度由
   TaskRunner + 界面忙态保证，这里不做锁。
3. 每个函数都把"读回来的原始值"原样带回（hex 串 / None），不做四舍五入或单位换算 ——
   换算放 regs.py，显示放界面。这里是"能复现台架"的唯一证据链。
"""

import time

import abz as az
import regs

# 方波可看预设的分箱基准（§⑨卡）：bins = SQUARE_POINTS × inter
SQUARE_POINTS = 16
import alarm as sg


def task_read_all(worker):
    """读设备身份证 + 倍频相关配置（11 个寄存器）。"""
    info = worker.read_device_info()
    raw, hexes = {}, {}
    for addr in regs.CFG_ADDRS:
        d = worker.read_reg(addr, timeout=0.4, retries=2)
        raw[addr] = None if d is None else d["value"]
        hexes[addr] = None if d is None else d["hex"]
    return {"info": info, "regs": raw, "hexes": hexes}


def task_apply_inter_div(worker, inter, div):
    """写 0x0101/0x0102 改 inter/div，再回读比对。

    ★ 桥（rtl/spi_slave.v:244-251）是"一次事务写 2 字节 + 地址自增"：
      低字节 → addr、高字节 → addr+1，不可关闭。所以 0x0101/0x0102 必须
      合成**一次 16 位写**（addr=0x0101, data={v102,v101}）。早先分两次写，
      第二次的高字节 0 会落到 0x0103（AB 迟滞）把它清 0 —— 每点一次
      "应用倍频"就重置一次 AB 迟滞，而回读只比 0x0101/0x0102 查不出来。
    """
    v101, v102 = regs.encode_inter_div(inter, div)
    writes = []
    pair = ((v102 & 0xFF) << 8) | (v101 & 0xFF)
    d = worker.write_reg(regs.REG_INTER0, pair, timeout=0.5, retries=1)
    writes.append((regs.REG_INTER0, pair, None if d is None else d["hex"]))
    time.sleep(0.06)
    time.sleep(0.1)
    rb, hexes = {}, {}
    for addr in (regs.REG_INTER0, regs.REG_INTER1):
        d = worker.read_reg(addr, timeout=0.4, retries=2)
        rb[addr] = None if d is None else d["value"]
        hexes[addr] = None if d is None else d["hex"]
    got = regs.decode_inter_div(rb[regs.REG_INTER0], rb[regs.REG_INTER1])
    if got != (inter, div):
        # 链路偶发误码（实测 ~0.35%）可能让某次回读是废值，再读一次确认：
        # 两次里有一次对上就算生效，两次都对不上才报失败。
        time.sleep(0.1)
        rb2 = {}
        for addr in (regs.REG_INTER0, regs.REG_INTER1):
            d2 = worker.read_reg(addr, timeout=0.4, retries=2)
            if d2 is not None:
                rb2[addr] = d2["value"]
                hexes[addr] = d2["hex"]
        got2 = regs.decode_inter_div(rb2.get(regs.REG_INTER0),
                                     rb2.get(regs.REG_INTER1))
        if got2 == (inter, div):
            got = got2
            rb.update(rb2)
    # ★ 用户的明确要求（m04317「直接完全删掉限频」）：限频器只会把该出的边沿压掉，
    #   压掉的边沿还会在 0x0404/0x0405 bit3 上锁存，清了立刻又亮。所以每次改倍频
    #   顺手把 AB 限频（0x0106）写成 0 —— 上限 1/(20ns×1) = 50 MHz，永不触发。
    #   失败不影响倍频本身的结果，只记在 no_limit 里。
    lim = None
    try:
        lim = task_set_ablimit(worker, 0)
    except Exception as exc:                     # noqa: BLE001
        lim = {"ok": False, "why": "%s: %s" % (type(exc).__name__, exc)}
    return {"ok": got == (inter, div), "want": (inter, div), "got": got,
            "writes": writes, "readback": rb, "hexes": hexes, "no_limit": lim}


def task_lut_upload(worker, words, verify, enable):
    """把整张补偿表写进板子：关表 → 每点 2 次事务 → 可选逐点回读 → 按需启用。"""
    t0 = time.monotonic()
    worker.write_reg(regs.REG_LUT_CTRL, 0x00, timeout=0.4, verify=False)
    for i, val in enumerate(words):
        for addr, v in regs.lut_entry_writes(i, val):
            worker.write_reg(addr, v, timeout=0.4, verify=False)
    bad = 0
    if verify:
        for i, val in enumerate(words):
            worker.write_reg(regs.REG_LUT_ADDR0, i, timeout=0.4, verify=False)
            worker.write_reg(regs.REG_LUT_CTRL, 0x02, timeout=0.4, verify=False)
            lo = worker.read_reg(regs.REG_LUT_READ0, timeout=0.4)
            hi = worker.read_reg(regs.REG_LUT_READ1, timeout=0.4)
            if not lo or not hi:
                bad += 1
                continue
            got = ((int(hi.get("value", 0)) & 0xFF) << 8) | (int(lo.get("value", 0)) & 0xFF)
            if got != (int(val) & 0xFFFF):
                bad += 1
        worker.write_reg(regs.REG_LUT_CTRL, 0x00, timeout=0.4, verify=False)
    if bad == 0:                      # 回读不一致就不启用，免得用一个半截的表
        worker.write_reg(regs.REG_LUT_CTRL, 0x01 if enable else 0x00,
                         timeout=0.4, verify=False)
    rb = worker.read_reg8(regs.REG_LUT_CTRL)
    return {"n": len(words), "bad": bad, "ctrl": int(rb or 0) & 0xFF,
            "t": time.monotonic() - t0}


def task_lut_dump(worker, step=8):
    """抽样回读整张表（写 ADDR0 → CTRL bit1=1 → 读 READ0/READ1），返回 {索引: LSB}。"""
    pts = {}
    ctrl0 = int(worker.read_reg8(regs.REG_LUT_CTRL) or 0) & 0x01
    worker.write_reg(regs.REG_LUT_CTRL, ctrl0 | 0x02, timeout=0.4, verify=False)
    for i in range(0, regs.LUT_N, max(1, int(step))):
        worker.write_reg(regs.REG_LUT_ADDR0, i, timeout=0.4, verify=False)
        worker.write_reg(regs.REG_LUT_CTRL, ctrl0 | 0x02, timeout=0.4, verify=False)
        lo = worker.read_reg(regs.REG_LUT_READ0, timeout=0.4)
        hi = worker.read_reg(regs.REG_LUT_READ1, timeout=0.4)
        if lo and hi:
            pts[i] = ((int(hi.get("value", 0)) & 0xFF) << 8) | (int(lo.get("value", 0)) & 0xFF)
    worker.write_reg(regs.REG_LUT_CTRL, ctrl0, timeout=0.4, verify=False)
    return {"pts": pts, "step": int(step), "ctrl": ctrl0}


def task_read_board_status(worker):
    """读 v9 那段只读镜像（前馈/锁定/偏置/补偿表），返回 {addr: byte}。

    逐个读、失败的地址**不塞进 raw**（界面上就是"—"）。29 个地址 ≈15 ms，
    远小于一次状态轮询（8 条读命令），对 10 kHz 遥测无感。
    """
    raw = {}
    for a in regs.STATUS_ADDRS:
        v = worker.read_reg8(a, timeout=0.3, retries=1)
        if v is not None:
            raw[a] = v
    return raw


def task_write_pairs(worker, pairs):
    """写 0x0100 极对数（给板上 UVW 用），再回读比对。

    ★ 桥是"一次事务写 2 字节 + 地址自增"（rtl/spi_slave.v:244-251）：
      直接写 0x0100 = 小数值时，高字节 0 会落到 0x0101（INTER 低字节），
      把 ABZ 倍频静默清零，而回读只查 0x0100 所以永远报成功。
      正确做法是读-改-写：先把 0x0100 的高字节原样读回来带上。
    """
    val = regs.encode_pairs(pairs)
    cur = worker.read_reg(regs.REG_PAIRS, timeout=0.4, retries=2)
    if cur is None:
        # 读不到邻居字节就不敢写，否则可能把 0x0101 破坏成 0
        return {"ok": False, "want": pairs, "got": None, "write": (val, None),
                "readback": None, "hex": None,
                "err": "回读 0x0100 失败，已放弃写入"}
    hi = int(cur["value"]) & 0xFF00
    wval = hi | (val & 0xFF)
    d = worker.write_reg(regs.REG_PAIRS, wval, timeout=0.5, retries=1)
    wh = None if d is None else d["hex"]
    time.sleep(0.1)
    rb = worker.read_reg(regs.REG_PAIRS, timeout=0.4, retries=2)
    raw = None if rb is None else rb["value"]
    got, _raw = regs.decode_pairs(raw)
    return {"ok": got == pairs, "want": pairs, "got": got, "write": (wval, wh),
            "readback": raw, "hex": None if rb is None else rb["hex"]}


def task_write_advanced(worker, writes):
    """逐条写高级参数（值已在界面侧做好读-改-写），再逐条回读。"""
    log = []
    for addr, val in sorted(writes.items()):
        d = worker.write_reg(addr, int(val), timeout=0.5, retries=1)
        log.append((addr, int(val), None if d is None else d["hex"]))
        time.sleep(0.06)
    time.sleep(0.1)
    rb, hexes = {}, {}
    for addr in sorted(writes.keys()):
        d = worker.read_reg(addr, timeout=0.4, retries=2)
        rb[addr] = None if d is None else d["value"]
        hexes[addr] = None if d is None else d["hex"]
    bad = [(a, int(v), rb.get(a)) for a, v in writes.items() if rb.get(a) != int(v)]
    if bad:
        # 再读一次确认（与 `task_apply_inter_div` 同一套路）：真机上出现过"写 0x0101=0x0000
        # 之后、任务里的回读拿到的却是上一次写进去的 0x0040"——延迟/陈旧的应答。两次里有一次
        # 对上就算生效，两次都对不上才报 bad（否则界面会把陈旧值当现值显示，还会污染"原值"暂存）。
        time.sleep(0.1)
        for addr in sorted(writes.keys()):
            d = worker.read_reg(addr, timeout=0.4, retries=2)
            if d is not None:
                rb[addr] = d["value"]
                hexes[addr] = d["hex"]
        bad = [(a, int(v), rb.get(a)) for a, v in writes.items() if rb.get(a) != int(v)]
    return {"ok": not bad, "writes": log, "readback": rb, "hexes": hexes, "bad": bad}


def output_write_value(cur, bits):
    """把「ABZ / UVW 使能」的目标位合进 0x0109 的当前值。

    `bits` 只带要改的位（如 {"uwven": 1}），其余位（apol/bpol/zpol/abzdir/uvwpol/uvwdir）
    与高字节一律原样保留 —— 高级参数里的读-改-写是同一个道理（见 `panel_interp.py:263`）。
    `cur` 为 None（还没读回板上现值）时返回 None：宁可不写，也不能按 0 覆盖同字节其它位。
    """
    if cur is None:
        return None
    base = regs.decode_output(cur)
    if not base:
        return None
    for k in ("abzen", "uwven"):
        if k in bits:
            base[k] = 1 if bits[k] else 0
    return (int(cur) & 0xFF00) | regs.encode_output(base)


def square_pair(inter, bins, points=SQUARE_POINTS, choices=None):
    """算「方波可看」的目标 (分箱, inter)：保证 **箱数 ≥ points×inter**。

    为什么是这个判据：⑨ 卡画的是"每个电角度箱里 A/B 的平均电平"（`host/abz.py`），
    一箱跨 `inter/箱数` 个 A/B 周期。跨满 1 个周期时箱内均值恒 ~0.5（真机实测 97% 的箱），
    重建出来既没有 0 也没有 1 ⇒ 看不到方波。取 points=16 时每箱跨 ≤1/16 个周期、
    每周期 ≥16 点，边沿斜坡只占 1 个箱宽，才像方波。

    选值顺序（尽量少动板子）：
      1. 已经满足 ⇒ 原样返回（不折腾板子）；
      2. 否则在"**尽量保留 inter**（＝尽量不改板上 AB 输出频率）"的前提下，
         挑能撑住这个 inter 的**最小箱数**（箱数少 ⇒ 累积填满得快）；
      3. inter 大到连最大箱数都撑不住 ⇒ 把 inter 降到 `最大箱数/points`。

    返回 `(bins, inter)`；inter 一定 ≤ 传入值（不会把倍率调高），箱数一定取 BINS_CHOICES 里的档。
    """
    try:
        it, bn = int(inter), int(bins)
    except (TypeError, ValueError):
        return bins, inter
    ch = tuple(choices or az.BINS_CHOICES)
    mx = max(ch)
    if it * points <= bn:
        return bn, it
    it2 = min(it, mx // points)
    for b in sorted(ch):
        if b >= it2 * points:
            return b, it2
    return mx, it2


def _hms(secs):
    """秒 → h:mm:ss；没有数就给破折号（状态栏用）。"""
    try:
        s = int(secs)
    except (TypeError, ValueError):
        return "—"
    if s < 0:
        return "—"
    return "%d:%02d:%02d" % (s // 3600, (s % 3600) // 60, s % 60)


def _u32_from_pair(d_lo, d_hi):
    """把两次 16 位读拼成 32 位小端值（每次读同时给出 {addr+1, addr} 两个字节）。"""
    def g(d):
        return (int(d["lo"]), int(d["hi"])) if d else (0, 0)
    l0, h0 = g(d_lo)
    l2, h2 = g(d_hi)
    return (l0 | (h0 << 8) | (l2 << 16) | (h2 << 24)) & 0xFFFFFFFF


def task_read_status(worker):
    """读告警/幅值状态寄存器（需求 M7）。

    ★ 读应答约定（实测）：16 位响应 = {寄存器[addr+1], 寄存器[addr]}
      ⇒ 读 `0x0404` 一次同时拿到 STAT_VAL（低字节）与 STAT_LATCH（高字节）；
         `0x0520/0x0522` 两次拼出 32 位小端 AMP_LOW_SQ，`0x0530/0x0532` 拼 STAT_AMP_SQ。
    """
    addrs = (sg.REG_STAT_VAL, sg.REG_STAT_FLAGS, sg.REG_AMP_LOW_SQ, sg.REG_AMP_LOW_SQ + 2,
             sg.REG_AMP_HIGH_SQ, sg.REG_AMP_HIGH_SQ + 2,
             sg.REG_STAT_AMP_SQ, sg.REG_STAT_AMP_SQ + 2)
    got, hexes = {}, []
    for a in addrs:
        d = worker.read_reg(a, timeout=0.4, retries=2)
        got[a] = d
        hexes.append("0x%04X=%s" % (a, "读失败" if d is None else d["hex"]))
    st = {"hexes": "，".join(hexes),
          "ok": all(got[a] is not None for a in addrs)}
    v = got[sg.REG_STAT_VAL]
    if v:
        st["val0404"], st["latch0405"] = v["lo"], v["hi"]
    f = got[sg.REG_STAT_FLAGS]
    if f:
        st["flags053a"], st["flags053b"] = f["lo"], f["hi"]
    st["amp_low_sq"] = _u32_from_pair(got[sg.REG_AMP_LOW_SQ], got[sg.REG_AMP_LOW_SQ + 2])
    st["amp_high_sq"] = _u32_from_pair(got[sg.REG_AMP_HIGH_SQ], got[sg.REG_AMP_HIGH_SQ + 2])
    st["stat_amp_sq"] = _u32_from_pair(got[sg.REG_STAT_AMP_SQ], got[sg.REG_STAT_AMP_SQ + 2])
    return st


def task_set_bias_track(worker, on=True):
    """打开/关闭板端偏置慢跟踪（0x0122 bit1）。

    ★ 为什么不像别的参数那样"写完回读比对"：这块板 0x0514/15 的读回不可信
    （读回 0，而真实增益是 32768，若真是 0 输出会全零）。所以配置位写下去之后
    用 **0x013C bit0（bias_valid）** 来判定 —— 那个位是 bias_track 自己在该窗口
    学完之后置的，比回读配置位可信得多。
    返回 {ok, cfg, valid, big, s, c}；ok=False 时 hints 里写清楚卡在哪一步。
    """
    cur = worker.read_reg8(regs.REG_FF_CFG, timeout=0.5, retries=2)
    if cur is None:
        return {"ok": False, "why": "读不到 0x0122（链路忙或板子没应答）"}
    want = (cur | 0x02) if on else (cur & ~0x02)
    worker.write_reg(regs.REG_FF_CFG, want, timeout=0.5, retries=2, verify=False)
    time.sleep(0.4)                      # bias 窗口 32768 样本 ≈2.6 ms，0.4 s 足够跑完
    st = worker.read_reg8(regs.REG_BIAS_ST, timeout=0.5, retries=2)
    bs = worker.read_reg8(regs.REG_BIAS_S0, timeout=0.5, retries=2)
    bh = worker.read_reg8(regs.REG_BIAS_S1, timeout=0.5, retries=2)
    bc = worker.read_reg8(regs.REG_BIAS_C0, timeout=0.5, retries=2)
    ch = worker.read_reg8(regs.REG_BIAS_C1, timeout=0.5, retries=2)
    cfg = worker.read_reg8(regs.REG_FF_CFG, timeout=0.5, retries=2)
    valid = None if st is None else (st & 0x01)
    big = None if st is None else ((st >> 1) & 0x01)
    got_s = None if bs is None or bh is None else regs.s16((bh << 8) | bs)
    got_c = None if bc is None or ch is None else regs.s16((ch << 8) | bc)
    if on:
        ok = (valid == 1)
        why = ("" if ok else
               "写了 0x0122 bit1 但 0x013C 的 valid 还是 0：可能这块位流的偏置跟踪没接进数据通路")
    else:
        # ★ 关掉不会让 valid 清零、也不会把已学到的偏置撤掉（bias_track.v 里 en=0 保留输出），
        #   所以这里只按配置位判成败 ——「关」只是停止继续跟踪，不是撤销。
        ok = (cfg is not None and (cfg & 0x02) == 0)
        why = ("" if ok else "写了关，但 0x0122 读回仍是 0x%02X" % (cfg or 0))
    return {"ok": ok, "why": why, "cfg": None if cfg is None else cfg & 0xFF,
            "valid": valid, "big": big, "s": got_s, "c": got_c}


def task_clear_latch(worker):
    """清锁存告警：写 0x0405 = 0x00FF（W1C；写 bit0 同拍发 clr_otr 脉冲），再回读确认。"""
    before = task_read_status(worker)
    w = worker.write_reg(sg.REG_STAT_LATCH, sg.LATCH_CLEAR_VALUE, timeout=0.5, retries=1)
    time.sleep(0.05)
    after = task_read_status(worker)
    return {"before": before, "after": after,
            "write_hex": None if w is None else w["hex"]}




def task_set_ablimit(worker, value=0):
    """把 AB 限频（0x0106）改成 ``value``（0 = 几乎不限频），其它位原样保留。

    ★ 为什么要这个：`rtl/abz_gen.v` 的限频器 `gap = 20ns × (值+1) × div`，
      inter=32 / div=1 / 输入 20.8 kHz 时 AB 边沿率 2.66 MHz，而 0x0106=64 只允许
      770 kHz ⇒ 每一拍都被压掉、`0x0405 bit3` 清了立刻又锁。用户的原话是
      "不要限频锁存了" ⇒ 把上限抬到够用（写 0 后上限 50 MHz），锁存就不再天天亮。
    返回 {"ok", "writes", "res"}：写-读-回读确认全在 task_write_advanced 里。
    """
    # ★ read_reg8 只返回**整数低字节**（不是 dict）：早先写成 d["value"] 会
    #   TypeError: 'int' object is not subscriptable —— 上板第一次跑就炸在这里。
    cur = worker.read_reg8(regs.REG_ABLIMIT) if hasattr(regs, "REG_ABLIMIT") else None
    raw = {}
    if cur is not None:
        raw[regs.REG_ABLIMIT] = int(cur)
    writes = regs.adv_field_writes("ablimit", int(value), raw)
    if not writes:
        # ★ 两种"空"要分开：读不到现值（真失败）vs 现值已经是目标值（不用写）。
        #   上板实测 0x0106 读回 0x00、目标也是 0 ⇒ 这里以前会报"读不到现值"，
        #   每次连上都刷一条假告警。现在按现值判定。
        if cur is not None and regs.adv_field_value("ablimit", raw) == int(value):
            return {"ok": True, "writes": {}, "res": None,
                    "why": "已经是 %d，无需改动" % int(value)}
        return {"ok": False, "why": "读不到 0x0106 的现值，没法做读-改-写",
                "writes": {}, "res": None}
    res = task_write_advanced(worker, writes)
    return {"ok": True, "writes": writes, "res": res}
