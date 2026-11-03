#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/calib_repeat.py -- 一键标定重复性统计（判定 DEV_STATUS.md 1.28/1.29 的去抖修复）

为什么需要它
------------
2026-10-10 上板发现：KEY0 / 0x0502 触发的一键标定，`OFS_S`(0x0510) 有约 1/4 概率算错
+-1800..2300（根因 = enc_top 里 `angle_raw` 的 MSB 在过零点抖动，使标定窗口变成
**奇数个半周期**，见 docs/DEV_STATUS.md 1.28）。修复（1.29）后判据是：

  连续跑 N 次一键标定，`OFS_S` 必须**每次都**落在实测圆心附近（几十 LSB 以内），
  并且 `0x0502[6:4]`（重试次数）只应在窗口被判非整周期时非 0；
  `0x0502[7]`（win_bad）应当为 0（除非重试用尽）。
  （★ 位域权威口径见 rtl/reg_file.v:451；2026-10-10 曾错把重试写在 [7:5]、win_bad 写在
   bit4，v3 那次 20 轮统计的解码因此全错 —— 见 m04184–m04245。）

  修前失效率 ~25% => N=20 次全洁的概率若失效率不变只有 0.75^20 ~ 0.3%，
  所以 20 次全洁即可判"根治"。

用法
----
    python tools/calib_repeat.py --port COM5                 # 默认 20 次
    python tools/calib_repeat.py --port COM5 --n 30 --csv _synth_work/calib_rep.csv
    python tools/calib_repeat.py --port COM5 --calib-n 8     # 改窗口周期数（默认不动）
    python tools/calib_repeat.py --selftest                  # 离线自检（不接硬件）

说明
----
* 复用 tools/uart_spi.py 的链路实现（2 Mbaud + 自动重发 + 哨兵写入）。
* 每次标定前先写 `0x0503 = CALIB_N`（包模式写会连带把高字节落到 0x0504，正好是
  CALIB_N 的高字节）；然后写 `0x0502 = 0x0001` 启动（这会把 0x0503 写成 0x00，
  固件里 0 视为默认 64，属预期行为）。
* 轮询 `0x0502[1]`(busy) 直到落下，再读 `0x0502[2]`(done)。读回值的高字节是
  邻居寄存器 0x0503 的内容，所以打印时只看低字节的位域。
"""

import argparse
import io
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import uart_spi
except ImportError:                                # pragma: no cover
    print("找不到 tools/uart_spi.py（本脚本必须和它放在同一目录）")
    raise SystemExit(2)

try:
    sys.stdout.reconfigure(errors="replace")        # GBK 控制台不要炸
except Exception:                                   # noqa: BLE001
    pass

# 标定结果寄存器（16 位小端：addr 低字节 / addr+1 高字节）
CAL_REGS = [
    ("OFS_S",   0x0510),
    ("OFS_C",   0x0512),
    ("GAIN_S",  0x0514),
    ("GAIN_C",  0x0516),
    ("PHASE_K", 0x0518),
    ("SHIFT",   0x051A),
]

# 判定阈值：好值的量级是几十 LSB（实测 55/56、OFS_C ~350）
GOOD_OFS_S = 400
GOOD_OFS_C = 400


def s16(v):
    """16 位补码 -> 有符号整数。"""
    return v - 0x10000 if v & 0x8000 else v


def read16(link, addr, timeout):
    v, raw = uart_spi._readback(link, addr, timeout)
    return v, raw


def one_round(link, timeout, calib_n, poll_max_s):
    """跑一次一键标定，返回 dict（失败则结果字段为 None）。"""
    out = {"ok": False, "note": ""}
    if calib_n:
        # 0x0503 低字节 / 0x0504 高字节（包模式写会同时写 addr+1）
        rc = uart_spi.do_write(link, [(0x0503, calib_n & 0xFFFF)], timeout, verify=True)
        if rc != 0:
            out["note"] = "写 CALIB_N 失败"
            return out
    # 先清 done（bit2），否则上一轮的 done 会让"完成"判定提前命中
    ctrl0, _ = read16(link, 0x0502, timeout)
    if ctrl0 is not None and (ctrl0 & 0x0004):
        uart_spi.do_write(link, [(0x0502, 0x0004)], timeout, verify=False)
        if calib_n:                      # 清 done 的连带写会把 0x0503 写 0，补回
            uart_spi.do_write(link, [(0x0503, calib_n & 0xFFFF)], timeout, verify=True)
    # 启动（bit0 自清）
    rc = uart_spi.do_write(link, [(0x0502, 0x0001)], timeout, verify=False)
    if rc != 0:
        out["note"] = "启动写入超时"
        return out

    t0 = time.time()
    busy_seen = False
    ctrl = None
    while time.time() - t0 < poll_max_s:
        ctrl, _ = read16(link, 0x0502, timeout)
        if ctrl is None:
            time.sleep(0.02)
            continue
        busy = 1 if (ctrl & 0x0002) else 0
        done = 1 if (ctrl & 0x0004) else 0
        if busy:
            busy_seen = True
        elif busy_seen or done:
            break
        time.sleep(0.02)
    out["secs"] = time.time() - t0
    out["busy_seen"] = busy_seen
    if ctrl is None:
        out["note"] = "读 0x0502 超时"
        return out
    out["calib_n_seen"] = (ctrl >> 8) & 0xFF
    out["busy"] = 1 if (ctrl & 0x0002) else 0
    out["done"] = 1 if (ctrl & 0x0004) else 0
    out["trunc"] = 1 if (ctrl & 0x0008) else 0
    # ★ 位域权威口径 = rtl/reg_file.v:451（{8'b0, calib_bad, calib_retry, calib_trunc,
    #   done, busy, 1'b0}）⇒ bit7=win_bad、bit[6:4]=retry。2026-10-10 之前误写为
    #   bit4=win_bad / (ctrl>>5)&7=retry，导致 v3 那 20 轮统计解码全错（见 m04184–m04245）。
    out["win_bad"] = 1 if (ctrl & 0x0080) else 0
    out["retry"] = (ctrl >> 4) & 0x7

    for name, addr in CAL_REGS:
        v, _ = read16(link, addr, timeout)
        if v is None:
            out["note"] = "读 0x%04X 超时" % addr
            return out
        out[name] = v
    stat, _ = read16(link, 0x053A, timeout)
    out["stat"] = ((stat >> 8) & 0xFF) if stat is not None else None
    out["ok"] = True
    return out


def selftest():
    """离线自检：只验证解码与统计逻辑，不碰硬件。"""
    errs = 0

    def chk(cond, name):
        nonlocal errs
        if cond:
            print("  [ok]   %s" % name)
        else:
            errs += 1
            print("  [FAIL] %s" % name)

    chk(s16(0x0038) == 56, "s16(0x0038) == 56")
    chk(s16(0xF6FE) == -2306, "s16(0xF6FE) == -2306")
    chk(s16(0x0766) == 1894, "s16(0x0766) == 1894")
    # 位域解码：高位是 calib_n_seen（高字节 = 0x0503 CALIB_N 低字节）
    # ★ 权威口径 rtl/reg_file.v:451：{8'b0, calib_bad, calib_retry, calib_trunc,
    #   r_calib_done, calib_busy, 1'b0} ⇒ bit7=bad、bit[6:4]=retry、bit3=trunc、
    #   bit2=done、bit1=busy。自检里这几条必须与 calib_repeat.py 的实测解码一致，
    #   否则会把"解码错"掩盖成"自检通过"（2026-10-10 就是这样漏掉的）。
    ctrl = 0x400C            # 干净窗口：done=1, trunc=1, retry=0, bad=0
    chk((ctrl & 0x0004) != 0, "0x400C -> done=1")
    chk((ctrl & 0x0008) != 0, "0x400C -> truncated=1")
    chk(((ctrl >> 4) & 0x7) == 0, "0x400C -> retry=0")
    chk((ctrl & 0x0080) == 0, "0x400C -> win_bad=0")
    # ★ 板上实测值（v3 位流 20 轮里的 17 轮就是这么读回来的）：
    #   0x40BC = CALIB_N(0x40) + 低字节 0xBC = bad(bit7) + retry=3(bits6:4)
    #            + trunc(bit3) + done(bit2)，busy=0
    ctrl = 0x40BC
    chk(((ctrl >> 4) & 0x7) == 3, "0x40BC -> retry=3（重试用尽）")
    chk((ctrl & 0x0080) != 0, "0x40BC -> win_bad=1（用尽重试仍非整周期）")
    chk((ctrl & 0x0002) == 0, "0x40BC -> busy=0")
    chk((((ctrl >> 5) & 0x7) != ((ctrl >> 4) & 0x7)),
        "0x40BC -> 旧口径(>>5)=5 与新口径(>>4)=3 不同（这条能区分解码器）")
    ctrl = 0x002C            # 重试 2 次后成功：retry=2, bad=0, done=1, trunc=1
    chk(((ctrl >> 4) & 0x7) == 2, "0x002C -> retry=2（重试后成功）")
    chk((ctrl & 0x0080) == 0, "0x002C -> win_bad=0")
    ctrl = 0x400C
    chk(((ctrl >> 8) & 0xFF) == 0x40, "0x400C -> calib_n_seen=0x40 (=64)")
    # 判定逻辑
    vals = [56, 55, 58, 57]
    chk(sum(1 for v in vals if abs(s16(v)) <= GOOD_OFS_S) == 4, "4 个好值全判 good")
    vals = [0xF6FE, 0x0766]
    chk(sum(1 for v in vals if abs(s16(v)) <= GOOD_OFS_S) == 0, "2 个坏值全判 bad")
    print(" TEST PASSED" if errs == 0 else " TEST FAILED (%d)" % errs)
    return 0 if errs == 0 else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="一键标定重复性统计")
    ap.add_argument("--port", default="COM5")
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--n", type=int, default=20, help="标定轮数（默认 20）")
    ap.add_argument("--calib-n", type=int, default=0,
                    help="每轮先写 0x0503 = 这个值（0 = 不动）。"
                         "★包模式写 0x0502 启动会连带把 0x0503 写成 0，"
                         "固件把 0 视为默认 64 ⇒ 实际窗口周期数恒为 64")
    ap.add_argument("--timeout", type=float, default=0.4)
    ap.add_argument("--poll-max", type=float, default=20.0, help="单轮标定最长等待秒数")
    ap.add_argument("--csv", default="", help="把每轮结果写成 CSV")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    ser = uart_spi.open_port(args.port, args.baud, timeout=0.2)
    if ser is None:
        return 1
    link = uart_spi.Link(ser, args.baud, retries=4)

    # 先清掉 ADC 的 sticky OTR 锁存（0x0405[0]=1 ⇒ 顶层 clr_otr 输出一拍脉冲，
    # 见 rtl/reg_file.v:397）。不清的话状态字的 bit0 oflow（= cor_sat | otr_lat，
    # rtl/enc_top.v:634）会永久为 1 —— 板上做过的 OTR 过幅实验会把它锁死，
    # 之后每个遥测/状态读数都带 oflow，看起来像活故障。
    try:
        uart_spi.do_write(link, [(0x0405, 0x00FF)], 0.2, verify=False)
    except Exception as e:
        print("  （提示：清 OTR 锁存失败，忽略：%s）" % e)

    rows = []
    print("=" * 78)
    print(" 一键标定重复性统计：%d 轮，端口 %s @ %d" % (args.n, args.port, args.baud))
    if args.calib_n:
        print(" 每轮先写 0x0503 = %d (CALIB_N)" % args.calib_n)
    print(" 判据：OFS_S 每轮都应收敛在实测圆心附近（好值量级几十 LSB）")
    print("=" * 78)
    hdr = " %2s | %6s %6s | %6s %6s | %6s %6s | %3s %3s %3s %3s | %5s | %s"
    print(hdr % ("#", "OFS_S", "OFS_C", "GAIN_S", "GAIN_C", "PHASE_K", "SHIFT",
                 "retry", "trunc", "wbad", "done", "秒", "判定"))

    n_good = n_bad = 0
    for i in range(1, args.n + 1):
        r = one_round(link, args.timeout, args.calib_n, args.poll_max)
        if not r.get("ok"):
            print(" %2d | 失败：%s" % (i, r.get("note", "?")))
            rows.append({"i": i, "bad": "ERR", "note": r.get("note", "")})
            continue
        os_s = s16(r["OFS_S"])
        os_c = s16(r["OFS_C"])
        verdict = "GOOD"
        if abs(os_s) > GOOD_OFS_S or abs(os_c) > GOOD_OFS_C:
            verdict = "BAD(OFS)"
            n_bad += 1
        else:
            n_good += 1
        if r["win_bad"]:
            verdict += " win_bad=1"
        print(hdr % (i, os_s, os_c, r["GAIN_S"], r["GAIN_C"],
                     s16(r["PHASE_K"]), r["SHIFT"],
                     r["retry"], r["trunc"], r["win_bad"], r["done"],
                     "%.1f" % r.get("secs", 0.0), verdict))
        rows.append(dict(i=i, ofs_s=os_s, ofs_c=os_c,
                         gain_s=r["GAIN_S"], gain_c=r["GAIN_C"],
                         phase_k=s16(r["PHASE_K"]), shift=r["SHIFT"],
                         retry=r["retry"], trunc=r["trunc"], win_bad=r["win_bad"],
                         done=r["done"], secs=round(r.get("secs", 0.0), 2),
                         stat=r.get("stat"), bad=int(verdict.startswith("BAD"))))

    print("-" * 78)
    good_rows = [r for r in rows if "ofs_s" in r]
    if good_rows:
        ss = [r["ofs_s"] for r in good_rows]
        print(" OFS_S: 好 %d / 坏 %d（共 %d 轮）" % (n_good, n_bad, len(rows)))
        print(" OFS_S 统计: min=%d max=%d mean=%.1f 极差=%d 标准差=%.1f"
              % (min(ss), max(ss), statistics.mean(ss), max(ss) - min(ss),
                 statistics.pstdev(ss) if len(ss) > 1 else 0.0))
        print(" 重试次数分布: %s" % {k: sum(1 for r in good_rows if r["retry"] == k)
                                     for k in sorted(set(r["retry"] for r in good_rows))})
        print(" win_bad 次数: %d ; truncated 次数: %d"
              % (sum(r["win_bad"] for r in good_rows),
                 sum(r["trunc"] for r in good_rows)))
        if n_bad == 0:
            print(" 判定：全部 %d 轮 OFS_S 收敛 => 重标修复有效（修前失效率实测 37.5%%：3/8）" % len(good_rows))
        else:
            print(" 判定：仍有 %d 轮异常 => 修复不充分，请把异常轮次的 retry/win_bad 一并回传" % n_bad)
        # ★ 位流版本判据：本修复把"重试次数"放进 0x0502[6:4]、"非整周期用尽重试"放进 bit7。
        #   若 4 轮以上里 retry 恒为 0 且 win_bad 恒为 0，同时 OFS_S 仍有 ~25-40% 的坏轮，
        #   则板上跑的是**未修复的旧位流**（旧位流的 0x0502 没有这两个位域）。
        if good_rows and len(good_rows) >= 4 and all(r["retry"] == 0 for r in good_rows) \
                and all(r["win_bad"] == 0 for r in good_rows) and n_bad > 0:
            print(" ★ 提示：retry/win_bad 恒为 0 却仍有坏轮 => 板上很可能是**未修复的旧位流**"
                  "（修复版位流的 0x0502[6:4]=重试次数、bit7=win_bad），请先烧录新位流再复测。")

    # ------------------------------------------------------------------
    # ★ v6 诊断读回（0x05F2 RTL 版本号 + 0x0505.. 毛刺计数 + 0x0540.. 窗口快照）
    #   目的：把"到底有没有角度毛刺、多大、多密"变成数字（不必靠 ILA 撞 20.5 µs）。
    #   毛刺密度 = 毛刺计数 / 周期脉冲计数（与真实时间无关，不怕 UART 慢）。
    # ------------------------------------------------------------------
    print("-" * 78)
    try:
        bid, _ = read16(link, 0x05F2, args.timeout)
        bid &= 0xFFFF
        tag = "" if bid >= 6 else "   ← v5 或更早的位流（该地址读回 0）"
        print(" ★ RTL_BUILD_ID(0x05F2) = 0x%04X%s" % (bid, tag))
        if bid >= 6:
            def rd(a):
                v, _ = read16(link, a, args.timeout)
                return v & 0xFFFF
            g1, g2, g3, g4 = rd(0x0505), rd(0x0507), rd(0x0509), rd(0x050B)
            gh, pc = rd(0x050D), rd(0x0540)
            imin, imax = rd(0x0542), rd(0x0544)
            wc, nsc = rd(0x0546), rd(0x0548)
            print(" 角度毛刺计数（累计）：>5.6°=%d  >11.25°=%d  >22.5°=%d  >45°=%d  保持动作=%d"
                  % (g1, g2, g3, g4, gh))
            print(" 周期脉冲累计=%d；最近一次关门的窗口快照：int_min=%d int_max=%d wcnt=%d nsamp=%d"
                  % (pc, imin, imax, wc, nsc))
            if pc > 0:
                print(" 毛刺密度：每输入周期 >5.6° 发生 %.4f 次（%d/%d）；>11.25° %.4f 次"
                      % (g1 / float(pc), g1, pc, g2 / float(pc)))
            if imin > 0:
                print(" 最近窗口间隔比 int_max/int_min = %.4f（>1.25 即判定为非整周期并作废重来）"
                      % (imax / float(imin)))
            if (g2 == 0) and (g1 >= 0):
                print(" 判读：>11.25° 的毛刺计数为 0 ⇒ 当前激励下角度跳变不足以翻动标定滞回。")
    except Exception as e:  # noqa: BLE001
        print(" （v6 诊断读回失败，忽略：%s）" % e)

    if args.csv:
        with io.open(args.csv, "w", encoding="utf-8", newline="\n") as f:
            cols = ["i", "ofs_s", "ofs_c", "gain_s", "gain_c", "phase_k", "shift",
                    "retry", "trunc", "win_bad", "done", "secs", "stat", "bad", "note"]
            f.write(",".join(cols) + "\n")
            for r in rows:
                f.write(",".join(str(r.get(c, "")) for c in cols) + "\n")
        print(" 每轮明细已写入 %s" % args.csv)
    return 0 if n_bad == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
