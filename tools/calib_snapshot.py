#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/calib_snapshot.py —— 标定系数寄存器的**快照 / 恢复 / 受控注入**（photo_shot_list P1-1 支撑工具）

背景（2026-10-13 实测）：
  `sc_correct.v` 的校正级**始终**使用 `cfg_*` 寄存器（`rtl/enc_top.v:366-371`
  `use_ofs_s = cfg_ofs_s` …），一键标定只是把解算结果写回这些寄存器
  （`rtl/reg_file.v:327-340` 的 calib 写口，地址同 0x0510…0x051A）。
  因此：**往 0x0510…0x051A 写值就能人为注入畸变**，标定后再读回即为真实解算结果。
  ⇒ 「斜椭圆 → 按键 → 正圆」的演示不需要动 AFG 的偏置/相位档位，全程可由串口复现。

三个用途：
  1. `snapshot` —— 读 12 个系数寄存器（0x0510…0x051A + 0x0502），存 JSON；
  2. `restore`  —— 从 JSON 写回（★ 每轮实验结束**必须**恢复，否则板上带的是一组
                  被注入的系数，后续所有素材/测量都作废）；
  3. `inject`   —— 按预设注入一组畸变，用于拍"校前斜椭圆"。

寄存器口径（`rtl/sc_correct.v:6-29`）：
  0x0510/11  ofs_s    signed 16  正弦去直流偏置（**LSB 单位**，直接减到 ADC 码上）
  0x0512/13  ofs_c    signed 16  余弦去直流偏置
  0x0514/15  gain_s   unsigned   正弦增益 Q1.15（1.0 = 32768）
  0x0516/17  gain_c   unsigned   余弦增益 Q1.15
  0x0518/19  phase_k  signed     正交误差系数 = sin(Δφ)，Q1.15
  0x051A     shift_s/shift_c 2 bit ×2  粗调移位：总增益 = (gain/2^15) << shift

用法：
  # 存快照（实验前）
  python tools\\calib_snapshot.py --port COM3 snapshot --save _synth_work\\calib_before.json
  # 注入畸变（偏置 ±800 LSB + 幅值失衡 1.25× + 正交 5°）
  python tools\\calib_snapshot.py --port COM3 inject --offset 800 --gain-mismatch 1.25 --quad-deg 5
  # 恢复
  python tools\\calib_snapshot.py --port COM3 restore --load _synth_work\\calib_before.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import uart_spi as sp  # noqa: E402

# (地址, 名称, 位宽, 是否有符号)  —— 顺序即打印顺序
COEFS = [
    (0x0502, "calib_ctrl", 16, False),
    (0x0510, "ofs_s", 16, True),
    (0x0511, "ofs_s_hi", 16, True),   # 冗余：确认高低字节口径
    (0x0512, "ofs_c", 16, True),
    (0x0513, "ofs_c_hi", 16, True),
    (0x0514, "gain_s", 16, False),
    (0x0515, "gain_s_hi", 16, False),
    (0x0516, "gain_c", 16, False),
    (0x0517, "gain_c_hi", 16, False),
    (0x0518, "phase_k", 16, True),
    (0x0519, "phase_k_hi", 16, True),
    (0x051A, "shift", 16, False),
    (0x051B, "h2_k", 16, True),
]

# 只保存/恢复"有意义"的 16 位寄存器（低字节地址）
KEEP = [0x0502, 0x0510, 0x0512, 0x0514, 0x0516, 0x0518, 0x051A, 0x051B]


def _s16(v: int) -> int:
    return v - 65536 if v >= 32768 else v


def open_link(port: str, baud: int, timeout: float):
    """`sp.open_port` 返回的裸 serial.Serial 没有 transact ⇒ 必须再套一层 sp.Link
    （与 uart_spi.main 的做法一致）。"""
    ser = sp.open_port(port, baud, timeout)
    if ser is None:
        return None
    return sp.Link(ser, baud)


def read_all(link, timeout: float, verbose: bool = True) -> dict:
    """读 KEEP 里的每个寄存器；失败（None）时报错退出，避免把 0 当成真值。"""
    out = {}
    for addr in KEEP:
        val, raw = sp._readback(link, addr, timeout)
        if val is None:
            raise SystemExit("!! 读 0x%04X 超时（检查串口/位流/是否被外部 SPI 主机占用）" % addr)
        out[addr] = val
        if verbose:
            name = dict((a, n) for a, n, _w, _s in COEFS).get(addr, "?")
            sgn = dict((a, s) for a, _n, _w, s in COEFS).get(addr, False)
            shown = _s16(val) if sgn else val
            print("  0x%04X %-11s = 0x%04X  %8d%s"
                  % (addr, name, val, shown, "  (signed)" if sgn else ""))
            if raw:
                print("        <- %s  [status=0x%02X]" % (" ".join("%02X" % b for b in raw), raw[1]))
        time.sleep(0.01)
    return out


def gain_reg(mult: float) -> int:
    """把倍数换算成 Q1.15（不引入 shift，因为倍数接近 1）。

    ★ **上界 1.999 不是随手取的**：`0x051A` 的 shift 是**粗调**（总增益 = (gain/2^15)·2^shift），
      本工具注入时一律把 shift 写 0 ⇒ gain 必须能单独表示总增益。`rtl/sc_correct.v:9,68-73`
      的定点路径要求 `gain/2^15 <= 1.999`（判据与理由见该文件注释与 `tools/calib_shift_judge.py`），
      超过就溢出饱和。所以这里硬性拒绝 > 1.999 的倍数，而不是让它静默饱和。
    """
    v = int(round(mult * 32768))
    if v > GAIN_REG_MAX:
        raise SystemExit("!! 增益倍数 %.4f 超出 Q1.15 的 %.3f 上限（gain=%d > %d）；"
                         "本工具把 shift 写 0，无法靠粗调移位补救"
                         % (mult, GAIN_MULT_MAX, v, GAIN_REG_MAX))
    if not (0 <= v <= 65535):
        raise SystemExit("!! 增益倍数 %.3f 超出 Q1.15 可表示范围" % mult)
    return v


def clip_addr_val(addr: int, val: int) -> int:
    """按寄存器**实际位宽**裁剪待写值。

    `0x051A` 只有 4 位（`rtl/reg_file.v:104` = `[1:0]shift_s [3:2]shift_c`，读回
    `rtl/reg_file.v:507` = `{4'b0000, r_shift_c, r_shift_s}`）⇒ 写 `0x00FF` 回读 `0x000F`、
    写 `0x00F3` 回读 `0x0006`。这是位宽截断，不是写失败；裁剪后再比才不会误报
    （★ 2026-10-13 那次"结果不可信"的采集就是被 `0x00FF` 哨兵写把 shift 顶成 3、增益 ×8）。
    """
    if addr == 0x051A:
        return val & 0x000F
    return val & 0xFFFF


def gain_reg_q(mult: float) -> int:
    """`gain_reg` 的纯计算部分（不含上限拒绝），供自检复用。"""
    return int(round(mult * 32768))


#: Q1.15 增益上界（`rtl/sc_correct.v:9,68-73`）：本工具把 shift 写 0，无法靠粗调移位补救
GAIN_MULT_MAX = 1.999
GAIN_REG_MAX = int(round(GAIN_MULT_MAX * 32768))


def phase_k_of(quad_deg: float) -> int:
    """正交误差角 → `phase_k`（Q1.15，负号见 `rtl/sc_correct.v`）：`-32768·sin(Δφ)`。"""
    if not quad_deg:
        return 0
    return int(round(-32768.0 * math.sin(math.radians(quad_deg))))


def selftest() -> int:
    """离线自检：只验纯逻辑（位宽裁剪 / Q1.15 换算 / 上限 / 注入算式），不碰硬件。"""
    errs = 0

    def chk(cond, name):
        nonlocal errs
        if cond:
            print("  [ok]   %s" % name)
        else:
            errs += 1
            print("  [!!]   %s" % name)

    # 1) 位宽裁剪：0x051A 只有 4 位，其余按 16 位
    chk(clip_addr_val(0x051A, 0x00FF) == 0x000F, "0x051A 写 0x00FF 裁成 0x000F（4 位）")
    chk(clip_addr_val(0x051A, 0x00F3) == 0x0003, "0x051A 写 0x00F3 裁成 0x0003（4 位）")
    chk(clip_addr_val(0x051A, 0x000F) == 0x000F, "0x051A 写 0x000F 原样保留")
    chk(clip_addr_val(0x0514, 0x1FFFF) == 0xFFFF, "0x0514 按 16 位裁剪")
    chk(clip_addr_val(0x0512, 0x8000) == 0x8000, "0x0512 负偏置的高位保留")

    # 2) Q1.15 换算（1.0 = 32768）
    chk(gain_reg_q(1.0) == 32768, "1.0 → 32768")
    chk(gain_reg_q(1.25) == 40960, "1.25 → 40960（实测注入用的倍数）")
    chk(gain_reg_q(0.8) == 26214, "1/1.25 → 26214")
    chk(gain_reg(1.0) == 32768 and gain_reg(1.25) == 40960, "gain_reg 与纯换算一致")
    chk(gain_reg(GAIN_MULT_MAX) == GAIN_REG_MAX == 65503,
        "上界倍数 %.3f → %d（恰好通过）" % (GAIN_MULT_MAX, GAIN_REG_MAX))

    # 3) 上界必须硬拒绝（rtl/sc_correct.v:9,68-73）
    for m in (2.0, 3.14, 10.0):
        try:
            gain_reg(m)
            chk(False, "倍数 %.2f 应被拒绝" % m)
        except SystemExit:
            chk(True, "倍数 %.2f 被拒绝（Q1.15 上界 %.3f）" % (m, GAIN_MULT_MAX))

    # 4) 注入算式：phase_k = -32768·sin(Δφ)，ofs_c 缺省取 ofs_s 的相反数
    chk(phase_k_of(0.0) == 0, "Δφ=0° ⇒ phase_k=0")
    chk(phase_k_of(3.0) == -1715, "Δφ=3° ⇒ phase_k=-1715")
    chk(phase_k_of(90.0) == -32768, "Δφ=90° ⇒ phase_k=-32768（饱和端）")
    chk(-3000 == -int(round(3000)), "ofs_c 缺省 = -ofs_s")

    print()
    if errs:
        print(" TEST FAILED（%d 项）" % errs)
        return 1
    print(" TEST PASSED")
    return 0


def write_pairs(link, pairs, timeout: float) -> int:
    """逐对写（低字节地址 + 16 位值），写后回读校验；返回失败条数。

    ★★ **两个踩过的坑，都在这里兜住**（2026-10-14 实测，代价是一次"结果不可信"的采集）：

    1. **`0x051A` 只有 4 位**（`rtl/reg_file.v:104` = `[1:0]shift_s [3:2]shift_c`，读回
       `rtl/reg_file.v:507` 为 `{4'b0000, r_shift_c, r_shift_s}`）。所以写 `0x00FF` 读回是
       `0x000F`、写 `0x00F3` 读回是 `0x0006` —— 这是**位宽截断，不是写失败**。但
       `uart_spi.do_write` 校验的是"回读 == 写入的全 16 位"，于是它把 `0x051A` 的写入
       一律报成 `!! 未通过回读校验`，**并且哨兵写 `0x00FF` 真的把 shift 置成了 3（×8 增益）**。
       ⇒ 这里对 `0x051A` 按 4 位裁剪后再比，避免"报了失败但其实改了寄存器"。
    2. **"写 0 到已经是 0 的寄存器"会触发哨兵路**（`do_write` 见旧值 == 目标就先写哨兵
       `0x00FF` 验证地址通路）⇒ 对 `0x051A` 就是上面的 ×8 事故。⇒ 本函数**跳过**"目标值与
       当前值相同"的写（调用方要的是最终状态，不是一定要发这一帧）。
    """
    bad = 0
    for addr, val in pairs:
        val = clip_addr_val(addr, val)   # 0x051A 只有 4 位，见 clip_addr_val 的 docstring
        cur, _raw = sp._readback(link, addr, timeout)
        if cur is not None and cur == val:
            print("  0x%04X 已是 0x%04X，跳过（避免触发哨兵写路）" % (addr, val))
            continue
        rc = sp.do_write(link, [(addr, val)], timeout, verify=True)
        if rc:
            got, _ = sp._readback(link, addr, timeout)
            if got == val:
                print("  0x%04X 写 0x%04X：校验器报失败但回读一致（位宽截断的假告警）" % (addr, val))
            else:
                bad += 1
                print("  !! 写 0x%04X = 0x%04X 未通过回读校验（回读 0x%04X）"
                      % (addr, val, -1 if got is None else got))
    return bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="标定系数寄存器 快照 / 恢复 / 注入")
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=sp.BAUD_DEFAULT)
    ap.add_argument("--timeout", type=float, default=0.2)
    ap.add_argument("--selftest", action="store_true", help="离线自检纯逻辑（不连板）")
    sub = ap.add_subparsers(dest="cmd")

    p_snap = sub.add_parser("snapshot", help="读系数并存 JSON")
    p_snap.add_argument("--save", default="")
    p_snap.add_argument("--csv", default="")

    p_res = sub.add_parser("restore", help="从 JSON 写回系数")
    p_res.add_argument("--load", required=True)

    p_inj = sub.add_parser("inject", help="注入一组畸变系数")
    p_inj.add_argument("--offset", type=float, default=0.0, help="正弦通道直流偏置（ADC LSB，正=叠加）")
    p_inj.add_argument("--offset-c", type=float, default=None, help="余弦通道偏置；缺省 = 与正弦相反（制造偏置）")
    p_inj.add_argument("--gain-mismatch", type=float, default=1.0, help="幅值失衡倍数 k：gain_s=k、gain_c=1/k")
    p_inj.add_argument("--quad-deg", type=float, default=0.0, help="正交误差角度：phase_k = -32768*sin(Δφ)")
    p_inj.add_argument("--load", default="", help="先恢复该快照，再叠加注入（推荐：保证起点一致）")
    p_inj.add_argument("--save", default="", help="注入前把原系数存到该 JSON")
    p_inj.add_argument("--verify", action="store_true", help="写后逐条回读打印")

    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.cmd:
        ap.print_help()
        return 2

    link = open_link(args.port, args.baud, args.timeout)
    if link is None:
        return 2
    try:
        if args.cmd == "snapshot":
            print("== 读标定系数（端口 %s）==" % args.port)
            coefs = read_all(link, args.timeout)
            if args.save:
                path = os.path.join(ROOT, args.save) if not os.path.isabs(args.save) else args.save
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump({"ts": time.strftime("%Y-%m-%d %H:%M:%S"),
                               "port": args.port, "coefs": coefs}, fh,
                              ensure_ascii=False, indent=2)
                print("  已存快照：%s" % os.path.relpath(path, ROOT))
            if args.csv:
                path = os.path.join(ROOT, args.csv) if not os.path.isabs(args.csv) else args.csv
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write("addr,name,hex,dec\n")
                    nm = dict((a, n) for a, n, _w, _s in COEFS)
                    for a, v in sorted(coefs.items()):
                        fh.write("0x%04X,%s,0x%04X,%d\n" % (a, nm.get(a, "?"), v, v))
                print("  已写 CSV：%s" % os.path.relpath(path, ROOT))
            return 0

        if args.cmd == "restore":
            path = os.path.join(ROOT, args.load) if not os.path.isabs(args.load) else args.load
            with open(path, encoding="utf-8") as fh:
                blob = json.load(fh)
            coefs = {int(k): int(v) for k, v in blob["coefs"].items()}
            print("== 恢复标定系数（快照 %s @%s）==" % (os.path.relpath(path, ROOT), blob.get("ts", "?")))
            bad = write_pairs(link, [(a, coefs[a]) for a in KEEP if a in coefs], args.timeout)
            print("  写入 %d 条，失败 %d 条" % (len([a for a in KEEP if a in coefs]), bad))
            read_all(link, args.timeout)
            return 1 if bad else 0

        if args.cmd == "inject":
            if args.load:
                path = os.path.join(ROOT, args.load) if not os.path.isabs(args.load) else args.load
                with open(path, encoding="utf-8") as fh:
                    blob = json.load(fh)
                base = {int(k): int(v) for k, v in blob["coefs"].items()}
                print("== 基线来自快照 %s ==" % os.path.relpath(path, ROOT))
            else:
                print("== 基线 = 板上当前系数 ==")
                base = read_all(link, args.timeout, verbose=False)
            if args.save:
                path = os.path.join(ROOT, args.save) if not os.path.isabs(args.save) else args.save
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump({"ts": time.strftime("%Y-%m-%d %H:%M:%S"),
                               "port": args.port, "coefs": base}, fh,
                              ensure_ascii=False, indent=2)
                print("  注入前快照：%s" % os.path.relpath(path, ROOT))

            k = float(args.gain_mismatch)
            off_s = int(round(args.offset))
            off_c = -off_s if args.offset_c is None else int(round(args.offset_c))
            quad = float(args.quad_deg)
            phase_k = phase_k_of(quad)
            pairs = [
                (0x0510, off_s & 0xFFFF),
                (0x0512, off_c & 0xFFFF),
                (0x0514, gain_reg(k)),
                (0x0516, gain_reg(1.0 / k)),
                (0x0518, phase_k & 0xFFFF),
                (0x051A, 0x0000),      # shift 归零，避免粗调移位把增益放大 2×/4×
            ]
            print("== 注入畸变 ==")
            print("  ofs_s = %+d LSB, ofs_c = %+d LSB" % (off_s, off_c))
            print("  gain_s = %.4f (Q1.15 %d), gain_c = %.4f (Q1.15 %d)"
                  % (k, gain_reg(k), 1.0 / k, gain_reg(1.0 / k)))
            print("  phase_k = %d （Δφ = %.2f°，Q1.15 = %.5f）" % (phase_k, quad, phase_k / 32768.0))
            bad = write_pairs(link, pairs, args.timeout)
            print("  写入 %d 条，失败 %d 条" % (len(pairs), bad))
            if args.verify:
                read_all(link, args.timeout)
            return 1 if bad else 0
    finally:
        ser = getattr(link, "ser", link)
        try:
            ser.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
