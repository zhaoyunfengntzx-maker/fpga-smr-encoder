#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""输入健康度探针：把"输入幅度是否达标"与"角度毛刺率是否可信"分开读清楚。

为什么需要它（`docs/DEV_STATUS.md` §3 item 15 的收口前置条件）：
    18:44 那轮读数（`gl_cnt_1024` 10^4 量级/s）**是在 `0x053A` bit1 `amp_low` 置位的
    退化输入下测的** —— 小半径被 CORDIC 除出巨大角度噪声，所以那个数**不能**当真实
    毛刺率（8 Vpp 下 §1.37 实测是 0.00444 次/周期 ≈ 4.4 次/s，差 4 个数量级）。
    要收口，必须① 先把 `amp_low` 清掉，② 再用**已知间隔**重测 `gl_cnt_1024`。

本工具做三件事：
    1. 一次性读全"输入侧证据"：`0x053A` STAT_FLAGS、`0x0405` STAT_LATCH、
       `0x0404` STAT_LIVE、`0x0530/32` STAT_AMP_SQ、`0x0520/24` 标定阈值；
    2. 以**已知短间隔**连读毛刺计数与 `0x0540` 周期脉冲计数，同时打印毛刺**事件率**
       （`Δgl/秒`）与其**上界**（`Δgl/Δ间隔` 按 16 位回绕算出的最大可能值）——
       判据是 `Δgl_1024 < 65536`（未回绕）；回绕了说明率 ≥ 65536/间隔，仍可作下界；
    3. `--clear` 写 `0x0405 = 0x0001`（bit0 W1C + 1 拍 `clr_otr`）清粘滞位，然后**高频
       重读 `0x053A` + 测相邻两次读的**状态刷新率**，据此判定粘滞位是"复亮"还是
       "本就一直在位"。

寄存器口径（逐行读 RTL 确认，不要凭记忆）：
    `rtl/reg_file.v:528-530`  `0x053A` = {frame_active, crc_err_seen, calib_busy,
                                calib_done, otr, amp_high, amp_low, lag_limit}
    `rtl/reg_file.v:518-521`  `0x0530..0x0533` = `stat_amp_sq`（下界比较值）
    `rtl/reg_file.v:510-517`  `0x0520`/`0x0524` = 标定出的低/高幅度阈值平方
    `rtl/uart_spi_bridge.v:30-32` 读地址 A 返回 16 位窗口 {reg[A+1], reg[A]}（低字节在低地址）
    `rtl/reg_file.v:429`      `clr_otr <= we && (addr == 16'h0405) && wdata[0]`

用法：
    python tools\\input_health.py --port COM3                    # 只看现状 + 采样 20 次
    python tools\\input_health.py --port COM3 --n 20 --interval 0.15
    python tools\\input_health.py --port COM3 --clear             # 先清粘滞位再看复亮
    python tools\\input_health.py --port COM3 --csv _synth_work\\input_health.csv
    python tools\\input_health.py --selftest                     # 纯逻辑自检，不需要板子
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uart_spi  # noqa: E402

BAUD_DEFAULT = uart_spi.BAUD_DEFAULT

# 0x053A STAT_FLAGS 位名（rtl/reg_file.v:528-530，MSB 在左）
STAT_BITS = [
    (7, "frame_active"), (6, "crcerr"), (5, "calbusy"), (4, "caldone"),
    (3, "otr"), (2, "amphi"), (1, "amplo"), (0, "laglim"),
]
# 0x0405 STAT_LATCH 位名（锁存 + W1C；bit0 写 1 还发 1 拍 clr_otr）
LATCH_BITS = [
    (7, "res7"), (6, "res6"), (5, "scamp"), (4, "res4"),
    (3, "res3"), (2, "laglim"), (1, "res1"), (0, "otr"),
]
# ★ 2026-10-13 更正（重要）：io_flags **不是可回读寄存器**，它只存在于遥测帧里
#   （`rtl/uart_scope.v:16-36` 帧偏移 10；`rtl/enc_top.v:1164-1166` 组装）。
#   地址 0x0534 是 `stat_cycle_cnt[7:0]`（`rtl/reg_file.v:522-523`），是个跑动的
#   周期计数低字节 —— 曾被本工具误标成 io_flags，读出的锯齿被错读成"告警位"。
#   要看 io_flags / lag_warn / lag_fatal 请用 `tools/uart_scope.py --csv`（列 io_flags）。
IO_FLAGS_BITS = [
    (7, "amp_bad"), (6, "cor_sat"), (5, "cfg_uwven"), (4, "cfg_abzen"),
    (3, "uvw_freq_warn"), (2, "z_window"), (1, "lag_fatal"), (0, "lag_warn"),
]

# (地址, 名字, 是否累计型) —— 16 位小端对，读低地址取整词
ACCUM_REGS = [
    (0x0505, "gl_1024_gt5.6deg", True),
    (0x0507, "gl_2048_gt11.25deg", True),
    (0x0509, "gl_4096_gt22.5deg", True),
    (0x050B, "gl_8192_gt45deg", True),
    (0x050D, "gl_hold_cnt", True),
    (0x0540, "cyc_pulse_cnt", True),
]
SNAP_REGS = [
    (0x0530, "stat_amp_sq_lo16", False),
    (0x0532, "stat_amp_sq_hi16", False),
    (0x0520, "amp_low_sq_lo16", False),
    (0x0522, "amp_low_sq_hi16", False),
    (0x0524, "amp_high_sq_lo16", False),
    (0x0526, "amp_high_sq_hi16", False),
    (0x0502, "calib_ctrl", False),
    (0x05F2, "rtl_build_id", False),
]
RAW_REGS = [(0x053A, "stat_flags"), (0x0404, "stat_live"),
            (0x0405, "stat_latch"), (0x0534, "stat_cycle_cnt_lo")]

WORD_REGS = ACCUM_REGS + [(a, n, False) for a, n, _ in SNAP_REGS]


# --------------------------------------------------------------------------
# 纯函数（无硬件）
# --------------------------------------------------------------------------
def decode_bits(word, table):
    """把 16 位状态字解成 '名字' 列表（只列置位项）。"""
    return [name for bit, name in table if (word >> bit) & 1]


def wrap_delta(prev, cur, width=16):
    """16 位环绕差值（原样返回，未回绕时即真差值；调用方自行判大小）。"""
    return (cur - prev) & ((1 << width) - 1)


def rate_bounds(prev, cur, dt):
    """返回 (delta, per_sec_exact_ok, per_sec_lower_bound)。

    计数是 16 位**无饱和、回绕**的（`rtl/enc_top.v:506-522`）。所以：
      未回绕（delta 小）=> 差值即真值；
      回绕          => 真差值 = delta + k*65536，k>=1 => 只能给下界。
    判据取 delta < 32768（半程）视为未回绕，这是"已知短间隔"的工程口径。
    """
    d = wrap_delta(prev, cur)
    if d < 32768:
        return d, d / dt, d / dt
    return d, None, (d + 65536) / dt


def sq_to_amp_ratio(stat_amp_sq):
    """`stat_amp_sq` 是 (幅度比)^2 * 2^30（§1.23/§1.24 口径）。返回线性幅度比。"""
    return (float(stat_amp_sq) / float(1 << 30)) ** 0.5


def verdict_amplitude(status, stat_amp_sq, amp_low_sq, amp_high_sq):
    """按位 + 量化值给出输入幅度判读。返回 (健康?, 说明列表)。"""
    low = bool(status & (1 << 1))
    high = bool(status & (1 << 2))
    lines = []
    ratio = sq_to_amp_ratio(stat_amp_sq)
    lines.append(" stat_amp_sq = %d (0x%08X) => |sin/cos| 幅度比 ≈ %.4f（满量程 = 1.0）"
                 % (stat_amp_sq, stat_amp_sq, ratio))
    if amp_low_sq:
        lines.append(" 标定低阈 amp_low_sq = %d => 阈值幅度比 ≈ %.4f"
                     % (amp_low_sq, sq_to_amp_ratio(amp_low_sq)))
    if amp_high_sq:
        lines.append(" 标定高阈 amp_high_sq = %d => 阈值幅度比 ≈ %.4f"
                     % (amp_high_sq, sq_to_amp_ratio(amp_high_sq)))
    if low:
        lines.append(" ★ amp_low 置位 = 输入幅度低于下界 => 小半径会被 CORDIC 除出巨大"
                     "角度噪声 => **此时的毛刺计数不可当真实毛刺率**")
    if high:
        lines.append(" ★ amp_high 置位 = 输入过幅（可能削顶）")
    healthy = not (low or high)
    if healthy:
        lines.append(" ✅ 输入幅度在位（amp_low/amp_high 均未置位）=> 本轮毛刺计数可信")
    else:
        lines.append(" ⛔ 输入未达标：先把 AFG 调到 8 Vpp（0.8 满量程）再复测，"
                     "否则 item 15 无法收口")
    return healthy, lines


# --------------------------------------------------------------------------
# 硬件
# --------------------------------------------------------------------------
def read_words(link, regs, timeout, tries=3):
    out = {}
    for addr, name, _acc in regs:
        v = None
        for _ in range(tries):
            v, _raw = uart_spi._readback(link, addr, timeout)
            if v is not None:
                break
        out[name] = None if v is None else (v & 0xFFFF)
    return out


def read_raw(link, timeout, tries=2):
    out = {}
    for addr, name in RAW_REGS:
        v = None
        for _ in range(tries):
            v, _raw = uart_spi._readback(link, addr, timeout)
            if v is not None:
                break
        out[name] = None if v is None else (v & 0xFFFF)
    return out


def sample(link, timeout):
    """一次采样：计数器 + 原始状态 + 幅度，返回 (dict, 时间戳)。"""
    s = read_words(link, ACCUM_REGS, timeout)
    t = time.time()
    s.update({k: v for k, v in read_words(link, SNAP_REGS, timeout).items()})
    s.update(read_raw(link, timeout))
    return s, t


def reg_snapshot_text(s):
    """把一次采样的人类可读摘要（不含时间相关量）。"""
    lines = []
    st = s.get("stat_flags")
    ly = s.get("stat_live")
    la = s.get("stat_latch")
    io = s.get("io_flags")
    # ★ 只解低 8 位：读地址 A 返回的是 16 位窗口 {reg[A+1], reg[A]}，而 0x053A 的
    #   高字节来自 0x053B（stat_frame_cnt）—— 那是"帧内已发位数"在跑，不是状态位。
    #   直接拿整字解码会解出 bit8 这种不存在的位（实测读到 0x0190 = frame_cnt 1 + stat 0x90）。
    lines.append(" 0x053A STAT_FLAGS = %s（低字节）  set: %s"
                 % ("----" if st is None else "0x%02X" % (st & 0xFF),
                    ",".join(decode_bits(st & 0xFF, STAT_BITS)) or "无"))
    lines.append(" 0x0404 STAT_LIVE  = %s   set: %s"
                 % ("----" if ly is None else "0x%04X" % ly,
                    ",".join(decode_bits(ly, LATCH_BITS)) or "无"))
    lines.append(" 0x0405 STAT_LATCH = %s   set: %s"
                 % ("----" if la is None else "0x%04X" % la,
                    ",".join(decode_bits(la, LATCH_BITS)) or "无"))
    if io is not None:
        cyc = s.get("stat_cycle_cnt_lo") or 0
        lines.append(" 0x0534 周期计数低字节 = 0x%04X（跑动值，**不是**告警位；io_flags 只存在于遥测帧）"
                     % cyc)
    amp_sq = None
    if s.get("stat_amp_sq_lo16") is not None and s.get("stat_amp_sq_hi16") is not None:
        amp_sq = (s["stat_amp_sq_hi16"] << 16) | s["stat_amp_sq_lo16"]
    low_sq = high_sq = 0
    if s.get("amp_low_sq_lo16") is not None and s.get("amp_low_sq_hi16") is not None:
        low_sq = (s["amp_low_sq_hi16"] << 16) | s["amp_low_sq_lo16"]
    if s.get("amp_high_sq_lo16") is not None and s.get("amp_high_sq_hi16") is not None:
        high_sq = (s["amp_high_sq_hi16"] << 16) | s["amp_high_sq_lo16"]
    healthy = None
    if st is not None and amp_sq is not None:
        healthy, amp_lines = verdict_amplitude(st, amp_sq, low_sq, high_sq)
        lines.extend(amp_lines)
    if s.get("rtl_build_id") is not None:
        lines.append(" 0x05F2 RTL_BUILD_ID = %d  0x0502 calib_ctrl = %s"
                     % (s["rtl_build_id"],
                        "----" if s.get("calib_ctrl") is None else "0x%04X" % s["calib_ctrl"]))
    return lines, healthy


def clear_latches(link, timeout):
    """写 `0x0405 = 0x0001`：bit0 是 W1C，同时发 1 拍 `clr_otr`。返回 (ok, 前后读值)。"""
    before, _ = uart_spi._readback(link, 0x0405, timeout)
    # ★ 2026-10-13 修复：`uart_spi.do_write` 返回的是**退出码 int**（不是 (rc, msg) 元组），
    #   旧代码 `_rc, _msg = ...` 会抛 TypeError: cannot unpack non-iterable int object，
    #   导致 `--clear` 路径必崩（粘贴的 traceback 见 docs/DEV_STATUS.md 本轮记录）。
    _rc = uart_spi.do_write(link, [(0x0405, 0x0001)], timeout, verify=False)
    time.sleep(0.02)
    after, _ = uart_spi._readback(link, 0x0405, timeout)
    st_after, _ = uart_spi._readback(link, 0x053A, timeout)
    return (before, after, st_after)


def refresh_scan(link, timeout, n=8, gap=0.18):
    """高频重读 `0x053A`：数"读到不同字节"的次数 => 状态刷新率 + 复亮判定。

    为什么这么判：若相邻两次读的**字节完全相同**，那在这 gap 里没有观测到任何位变化
    （包括复亮）；若有变化且出现了目标位，就是复亮。gap 取 0.18 s 是为了让
    "1 s 内又置位"级别的复亮至少被采到几次。
    """
    samples = []
    t0 = time.time()
    for _ in range(n):
        v, _raw = uart_spi._readback(link, 0x053A, timeout)
        samples.append((time.time() - t0, None if v is None else (v & 0xFFFF)))
        time.sleep(gap)
    return samples


# --------------------------------------------------------------------------
# 自检
# --------------------------------------------------------------------------
def selftest():
    ok = True

    def chk(cond, name):
        nonlocal ok
        print("  [%s] %s" % ("PASS" if cond else "FAIL", name))
        ok = ok and bool(cond)

    chk(wrap_delta(0xFFFE, 2) == 4, "16 位环绕差值 0xFFFE→2 = 4")
    d, exact, lb = rate_bounds(7127, 29937, 0.5)
    chk(d == 22810 and exact is not None and abs(exact - 45620) < 1e-6,
        "未回绕：差值 22810 / 45620 次每秒")
    d2, exact2, lb2 = rate_bounds(0xFFF0, 0x0010, 0.5)
    chk(d2 == 32 and abs(exact2 - 64.0) < 1e-6,
        "小差值按未回绕处理（Δ=32 => 64 次/s）；真正的回绕只能靠 Δ≥半程才可判")
    d3, exact3, lb3 = rate_bounds(0x0000, 0xFFFF, 0.5)
    chk(d3 == 65535 and exact3 is None and abs(lb3 - 262142.0) < 1e-6,
        "Δ≥半程 => 判为回绕，只给下界 (delta+65536)/间隔")
    chk(decode_bits(0x000C, STAT_BITS) == ["otr", "amphi"],
        "0x053A=0x000C => otr + amphi")
    chk(decode_bits(0x0042, STAT_BITS) == ["crcerr", "amplo"],
        "0x053A=0x0042 => crcerr + amplo（§1.59 那轮退化输入的状态）")
    # 读地址 A 返回 16 位窗口 {reg[A+1], reg[A]}：0x053A 的高字节是 0x053B(stat_frame_cnt)。
    # 实测读到过 0x0190（= frame_cnt 1 + stat 0x90）⇒ 必须只解低字节，否则解出 bit8 这种不存在的位。
    chk(decode_bits(0x0190 & 0xFF, STAT_BITS) == ["frame_active", "caldone"],
        "0x053A 整字 0x0190（高字节 = 0x053B 帧内位数）只解低字节 => frame_active + caldone")
    chk(abs(sq_to_amp_ratio(0x1A30B9B2) - 0.6406) < 0.001,
        "stat_amp_sq 换算：0x1A30B9B2 => 0.6406（= 0.8×0.8008，Q1.15 口径，§1.23 同一组读数）")
    # 门限默认值来自 RTL 复位值，不是猜的：rtl/reg_file.v:315-316
    #   r_amp_low_sq <= 32'h170A3D71;  // (0.60)^2 * 2^30
    #   r_amp_high_sq<= 32'h5C28F5C3;  // (1.20)^2 * 2^30
    chk(abs(sq_to_amp_ratio(0x170A3D71) - 0.60) < 0.001, "复位默认低阈 = 0.60（rtl/reg_file.v:315）")
    chk(abs(sq_to_amp_ratio(0x5C28F5C3) - 1.20) < 0.001, "复位默认高阈 = 1.20（rtl/reg_file.v:316）")
    chk(0.60 < 0.6406 < 1.20, "0.6406 落在 [0.60, 1.20] 带内 => 该读数下 amplo/amphi 都不该置位")
    healthy, lines = verdict_amplitude(0x0040, 0x1A30B9B2, 0x170A3D71, 0x5C28F5C3)
    chk(healthy is True and any("输入幅度在位" in x for x in lines),
        "8 Vpp / 0.8 满量程口径（0x000C）判为健康")
    healthy2, _l2 = verdict_amplitude(0x0042, 0x1A30B9B2, 0, 0)
    chk(healthy2 is False, "带 amplo 的状态判为不健康")
    chk(decode_bits(0x0001, LATCH_BITS) == ["otr"] and
        decode_bits(0x0025, LATCH_BITS) == ["scamp", "laglim", "otr"],
        "0x0405 位名：0x0001=otr、0x0025=scamp+laglim+otr（§1.38 实测值）")
    # 位表必须覆盖整字节，且不重名
    for table, nm in ((STAT_BITS, "STAT"), (LATCH_BITS, "LATCH"), (IO_FLAGS_BITS, "io")):
        bits = sorted(b for b, _ in table)
        names = [n for _, n in table]
        chk(bits == list(range(8)), "%s 位表覆盖 bit0..7" % nm)
        chk(len(set(names)) == 8, "%s 位表 8 个名字互不相同" % nm)
    # 寄存器表地址唯一（避免"两个名字读同一地址"的复制粘贴错）
    addrs = [a for a, _n, _a2 in ACCUM_REGS] + [a for a, _n, _a2 in SNAP_REGS]
    chk(len(set(addrs)) == len(addrs), "寄存器表地址无重复")
    chk(0x0505 in addrs and 0x0540 in addrs and 0x053A in [a for a, _ in RAW_REGS],
        "关键地址 0x0505 / 0x0540 / 0x053A 都在表里")
    names = [n for _a, n, _x in ACCUM_REGS]
    chk(names[:4] == ["gl_1024_gt5.6deg", "gl_2048_gt11.25deg",
                      "gl_4096_gt22.5deg", "gl_8192_gt45deg"] and names[4] == "gl_hold_cnt",
        "毛刺计数器顺序与 §1.53 表一致（1024/2048/4096/8192/hold）")
    print("  自检 %s" % ("全部通过" if ok else "有失败"))
    return 0 if ok else 1


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="输入健康度探针（幅度/毛刺率/粘滞位复亮）")
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=BAUD_DEFAULT)
    ap.add_argument("--n", type=int, default=20, help="毛刺采样次数（默认 20）")
    ap.add_argument("--interval", type=float, default=0.15, help="采样间隔秒（默认 0.15）")
    ap.add_argument("--timeout", type=float, default=0.4)
    ap.add_argument("--clear", action="store_true", help="先写 0x0405=0x0001 清粘滞位")
    ap.add_argument("--refresh-n", type=int, default=8, help="清位后重读 0x053A 的次数")
    ap.add_argument("--csv", default=None)
    args = ap.parse_args(argv)

    ser = uart_spi.open_port(args.port, args.baud, timeout=0.2)
    link = uart_spi.Link(ser, args.baud)
    rows = []
    try:
        print("=" * 78)
        print(" 输入健康度探针（端口 %s @ %d baud）" % (args.port, args.baud))
        print("=" * 78)
        s0, _t = sample(link, args.timeout)
        lines, healthy = reg_snapshot_text(s0)
        print("[现状]")
        for ln in lines:
            print(ln)
        if s0.get("rtl_build_id") == 0:
            print(" ★ 0x05F2 读回 0 => 板上是 v5 或更早的位流，诊断寄存器无意义。")

        if args.clear:
            print("-" * 78)
            print("[清粘滞位] 写 0x0405 = 0x0001（bit0 W1C + 1 拍 clr_otr）")
            before, after, st_after = clear_latches(link, args.timeout)
            print(" 0x0405 清前 = %s  清后 = %s   （清后应为 0x0000 或仅剩未清的位）"
                  % ("----" if before is None else "0x%04X" % before,
                     "----" if after is None else "0x%04X" % after))
            print(" 0x053A 清后 = %s（低字节）   set: %s"
                  % ("----" if st_after is None else "0x%02X" % (st_after & 0xFF),
                     ",".join(decode_bits(st_after & 0xFF, STAT_BITS)) or "无"))
            gap = 0.18
            print("[复亮扫描] 每 %.2f s 重读 0x053A 共 %d 次（字节完全相同 = 该段无位变化）"
                  % (gap, args.refresh_n))
            scans = refresh_scan(link, args.timeout, n=args.refresh_n, gap=gap)
            prev = None
            flips = 0
            for dt, v in scans:
                tag = ""
                if prev is not None and v != prev:
                    flips += 1
                    tag = "  <== 与上次不同"
                print("  +%.2f s  0x053A = %s%s"
                      % (dt, "----" if v is None else "0x%04X" % v, tag))
                prev = v
            span = scans[-1][0] if scans else 0.0
            vals = [(v & 0xFF) for _d, v in scans if v is not None]
            print(" 变化 %d 次 / %.2f s，读到 %d 个不同状态字节 => 0x053A 刷新率约 ≥ %.1f 次/s"
                  % (flips, span, len(set(vals)), flips / span if span else 0.0))
            if vals:
                seen = [nm for b, nm in STAT_BITS if any((v >> b) & 1 for v in vals)]
                after_first = [nm for b, nm in STAT_BITS
                               if any((v >> b) & 1 for v in vals[1:])]
                print(" 扫描期间出现过的位: %s" % (",".join(seen) or "无"))
                print(" 首样本之后才出现的位: %s" % (",".join(after_first) or "无"))
                if any(nm in ("crcerr", "otr") for nm in after_first):
                    print(" ★ 清位后又复亮（crcerr/otr）=> 事件在持续产生，不是陈年锁存")
                else:
                    print(" ✅ 清位后扫描期间 crcerr/otr 未再出现")

        print("-" * 78)
        print("[毛刺率采样] %d 次 / 间隔 %.2f s（计数器 16 位无饱和回绕）"
              % (args.n, args.interval))
        print("%-6s %-10s %8s %8s %9s %9s" %
              ("样本", "间隔s", "gl1024", "cyc", "Δgl1024/s", "Δcyc/s"))
        prev = s0
        t_prev = time.time()
        gl_events = 0
        gl_secs = 0.0
        cyc_total = 0
        wrapped = 0
        for i in range(args.n):
            time.sleep(args.interval)
            cur, t_cur = sample(link, args.timeout)
            dt = t_cur - t_prev
            a = prev.get("gl_1024_gt5.6deg")
            b = cur.get("gl_1024_gt5.6deg")
            ca = prev.get("cyc_pulse_cnt")
            cb = cur.get("cyc_pulse_cnt")
            if None in (a, b, ca, cb) or dt <= 0:
                print("%-6d %-10.3f %8s %8s   （缺读，跳过）" % (i + 1, dt, a, b))
                prev, t_prev = cur, t_cur
                continue
            d, exact, lb = rate_bounds(a, b, dt)
            dcyc, cexact, clb = rate_bounds(ca, cb, dt)
            if exact is None:
                wrapped += 1
            else:
                gl_events += d
                gl_secs += dt
            cyc_total += dcyc
            print("%-6d %-10.3f %8d %8d %9s %9s"
                  % (i + 1, dt, b, cb,
                     "%.1f" % exact if exact is not None else "≥%.0f" % lb,
                     "%.1f" % cexact if cexact is not None else "≥%.0f" % clb))
            rows.append({"i": i + 1, "dt": dt, "gl1024": b, "cyc": cb,
                         "d_gl1024": d, "d_cyc": dcyc,
                         "gl_per_s": "" if exact is None else exact,
                         "gl_per_s_lower": lb, "wrapped": 1 if exact is None else 0})
            prev, t_prev = cur, t_cur

        print("-" * 78)
        if gl_secs > 0:
            print(" 未回绕样本合计：Δgl1024 = %d / %.3f s => **%.3f 次/s**"
                  % (gl_events, gl_secs, gl_events / gl_secs))
            if cyc_total:
                print(" 同段 Δ周期脉冲 = %d => 毛刺密度 %.5f 次/周期"
                      % (cyc_total, gl_events / float(cyc_total)))
                print(" （§1.37 在健康 8 Vpp 输入下的基准 = 0.00444 次/周期 ≈ 4.4 次/s）")
        else:
            print(" 所有样本都回绕了 => 只能给下界（率 ≥ 65536/间隔），请缩小 --interval")
        if wrapped:
            print(" ★ 回绕样本数 = %d/%d（回绕说明该间隔内事件数 ≥ 65536）" % (wrapped, args.n))
        fin = read_raw(link, args.timeout)
        lines, _h = reg_snapshot_text(fin)
        print("[采样后状态]")
        for ln in lines:
            print(ln)

        if args.csv:
            with io.open(args.csv, "w", encoding="utf-8", newline="\n") as f:
                w = csv.DictWriter(f, fieldnames=["i", "dt", "gl1024", "cyc", "d_gl1024",
                                                 "d_cyc", "gl_per_s", "gl_per_s_lower",
                                                 "wrapped"])
                w.writeheader()
                for r in rows:
                    w.writerow(r)
            print(" 采样明细已写入 %s" % args.csv)
        return 0
    finally:
        try:
            link.ser.close()
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
