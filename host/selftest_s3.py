"""S3 验收自检（无界面）：输入波形 / 幅值 / 告警（需求 M4 + M7）。

跑法：
    python host\\selftest_s3.py --port COM3 --seconds 3
    python host\\selftest_s3.py --port COM3 --seconds 3 --clear         # 额外实测清锁存
    python host\\selftest_s3.py --port COM3 --seconds 3 --force-fault   # 造一个真告警再清掉

判据：
  ① 离线：alarm.py 的手机逻辑全过（幅值换算、门限、削顶、告警翻译）
  ② 在线：连上、读出 v12 身份证、遥测帧布局 v2 占比 >= 99%（实时告警位只在 v2 帧里）
  ③ 幅值：上位机从帧算的 r（窗口均值）与板上 0x0530-33 STAT_AMP_SQ 一致（±15%）
  ④ 门限：0x0520-23 / 0x0524-27 读回并换算成 r 门限，应在 0.60/1.20 满量程附近
  ⑤ 告警：实时位（io_flags/stat/io_state）+ 锁存位（0x0404/0x053A）都能翻成中文
  ⑥ 仅 --clear：写 0x0405 = 0x00FF 后回读
  ⑦ 仅 --force-fault：把 ABLIMIT 设大造成真限频告警，再写 0x0405 清掉并恢复原值

★ 这里读寄存器用的是“两次 16 位读拼 32 位小端”，且每次读的**高字节来自 addr+1**
  （实测约定，见 host/README.md 的“五个必须知道的事实”）。
"""

from __future__ import annotations

import argparse
import os
import queue
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import link as lk                                    # noqa: E402
import ports as pm                                   # noqa: E402
import regs as rg                                    # noqa: E402
import alarm as sg                                  # noqa: E402


def hr(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def read_u32_le(worker, base):
    """0x…base 与 base+2 两次读拼 32 位小端（低位在前）。"""
    lo = worker.read_reg(base, timeout=0.4, retries=2)
    hi = worker.read_reg(base + 2, timeout=0.4, retries=2)
    if lo is None or hi is None:
        return None, ""
    v = ((lo["lo"] | (lo["hi"] << 8)) | ((hi["lo"] | (hi["hi"] << 8)) << 16)) & 0xFFFFFFFF
    return v, "%s + %s" % (lo["hex"], hi["hex"])


def main(argv=None):
    ap = argparse.ArgumentParser(description="S3 验收自检（输入波形/幅值/告警）")
    ap.add_argument("--port", default=None, help="串口号，例如 COM3（默认自动挑）")
    ap.add_argument("--baud", type=int, default=lk.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=3.0, help="收帧时长（默认 3 s）")
    ap.add_argument("--clear", action="store_true", help="额外实测清锁存 0x0405=0x00FF")
    ap.add_argument("--force-fault", action="store_true",
                    help="制造一个真告警（ABLIMIT 限频）再清掉，验证清锁存按钮通路")
    args = ap.parse_args(argv)
    rc = 0

    hr("① 离线自检：alarm.py（幅值/门限/削顶/告警翻译）")
    if sg.selftest() != 0:
        rc = 1

    hr("② 列端口并连接")
    ports = pm.list_serial_ports()
    for dev, desc, _hw in ports:
        print("  %-8s %s" % (dev, desc))
    port = args.port or pm.preferred_port(ports)
    if not port:
        print("  !! 没找到可用串口")
        return 1
    print("  使用 %s @ %d baud" % (port, args.baud))
    worker = lk.SerialWorker(port, baud=args.baud)
    worker.start()
    try:
        # 等串口线程真正打开端口（不等的话第一批寄存器命令会全部超时）
        t0w = time.monotonic()
        while not worker.connected and time.monotonic() - t0w < 5.0:
            if worker.error:
                print("  !! %s" % worker.error)
                return 1
            time.sleep(0.02)
        if not worker.connected:
            print("  !! 5 秒内没连上：%s" % (worker.error or "未知原因"))
            return 1
        print("  已连接 %s（%s）" % (port, lk.baud_text(args.baud)))

        info = worker.read_device_info(timeout=0.6, retries=3)
        for k in ("device_id", "rev", "rtl_build"):
            v = info.get(k)
            print("  %-10s %s" % (k, "读失败" if v is None else "0x%04X" % v))
        print("  原始应答：%s" % info.get("raw"))
        if info.get("rtl_build") == lk.EXPECT_RTL_V12:
            print("  ✓ 固件 v12（遥测帧布局 v2，帧里有 io_state/io_flags）")
        else:
            print("  !! 固件不是 v12（0x000C），帧里没有电平/告警位，S3 的实时位不可用")
            rc = 1

        hr("③ 收帧 + 独立算幅值（%g s）" % args.seconds)
        buf = sg.WaveBuffer(capacity=100000)
        c0 = worker.counters()
        t0 = time.time()
        last_t = t0
        last_frame = None
        deadline = t0 + args.seconds
        while time.time() < deadline:
            try:
                kind, _text, extra = worker.events.get(timeout=0.05)
            except queue.Empty:
                continue
            if kind == "batch":
                frs = extra.get("frames") or []
                if frs:
                    buf.feed(frs)
                    last_frame = frs[-1]
                    last_t = time.time()
        c1 = worker.counters()
        dt = max(1e-6, last_t - t0)
        n = c1.get("frames", 0) - c0.get("frames", 0)
        v2 = c1.get("layout_v2", 0) - c0.get("layout_v2", 0)
        v1 = c1.get("layout_v1", 0) - c0.get("layout_v1", 0)
        print("  收到 %s 帧 / %.3f s = %s 帧/秒" % (n, dt, int(n / dt)))
        print("  帧布局：v2 %s，v1 %s ⇒ v2 占比 %.3f%%" % (v2, v1, 100.0 * v2 / max(1, v2 + v1)))
        if v2 + v1 == 0:
            print("  !! 一帧都没收到")
            return 1
        if 100.0 * v2 / (v2 + v1) < 99.0:
            print("  !! v2 占比偏低（实时告警位会缺）")
            rc = 1
        s = buf.snapshot()
        if not s["n"]:
            print("  !! 缓冲区里没有样本")
            return 1
        print("  样本 %d 帧（%.0f ms）：r 均值 %.1f，最小 %.1f，最大 %.1f，圆度偏差 %.3f%%，削顶 %d"
              % (s["n"], s["span_s"] * 1000.0, s["r_mean"], s["r_min"], s["r_max"],
                 s["roundness"], s["clip"]))

        hr("④ 读幅值门限与板上实测幅值")
        amp_low, hx1 = read_u32_le(worker, sg.REG_AMP_LOW_SQ)
        amp_high, hx2 = read_u32_le(worker, sg.REG_AMP_HIGH_SQ)
        amp_sq, hx3 = read_u32_le(worker, sg.REG_STAT_AMP_SQ)
        print("  0x0520-23 AMP_LOW_SQ  = %s  (%s)"
              % ("读失败" if amp_low is None else "0x%08X" % amp_low, hx1))
        print("  0x0524-27 AMP_HIGH_SQ = %s  (%s)"
              % ("读失败" if amp_high is None else "0x%08X" % amp_high, hx2))
        print("  0x0530-33 STAT_AMP_SQ = %s  (%s)"
              % ("读失败" if amp_sq is None else "0x%08X" % amp_sq, hx3))
        r_low = r_high = None
        if amp_low and amp_high:
            r_low, r_high = sg.amp_limits(amp_low, amp_high)
            print("  ⇒ r 门限 %.1f … %.1f（满量程 %.0f ⇒ %.3f … %.3f FS）"
                  % (r_low, r_high, sg.FS, r_low / sg.FS, r_high / sg.FS))
            if abs(r_low / sg.FS - 0.60) > 0.05 or abs(r_high / sg.FS - 1.20) > 0.05:
                print("  !! 门限不在 0.60/1.20 FS 附近（复位值 0x170A3D71 / 0x5C28F5C3）")
                rc = 1
            else:
                print("  ✓ 门限与复位值一致（0.60 / 1.20 满量程）")
        if amp_sq:
            r_board = sg.r_of_amp_sq(amp_sq)
            err = abs(r_board - s["r_mean"]) / max(1.0, r_board) * 100.0
            print("  板上 r = %.1f，上位机窗口均值 r = %.1f ⇒ 偏差 %.2f%%"
                  % (r_board, s["r_mean"], err))
            if err <= 15.0:
                print("  ✓ 两条独立路径一致（≤15%；板上是单片快照，窗口均值本就不同拍）")
            else:
                print("  !! 幅值不一致（>15%），检查标定/输入")
                rc = 1
            level, text = sg.amp_verdict(s["r_mean"], r_low, r_high)
            print("  上位机判定：%s（%s）" % (text, level))

        hr("⑤ 告警翻译（实时位 + 锁存位）")
        d = worker.read_reg(sg.REG_STAT_VAL, timeout=0.4, retries=2)
        f = worker.read_reg(sg.REG_STAT_FLAGS, timeout=0.4, retries=2)
        status = None
        if d is None or f is None:
            print("  !! 读 0x0404/0x053A 失败")
            rc = 1
        else:
            status = {"hexes": "%s，%s" % (d["hex"], f["hex"]),
                      "val0404": d["lo"], "latch0405": d["hi"],
                      "flags053a": f["lo"], "flags053b": f["hi"],
                      "amp_low_sq": amp_low or 0, "amp_high_sq": amp_high or 0,
                      "stat_amp_sq": amp_sq or 0, "ok": True}
            print("  读 0x0404 -> %s  ⇒ STAT_VAL=0x%02X  STAT_LATCH=0x%02X"
                  % (d["hex"], d["lo"], d["hi"]))
            print("  读 0x053A -> %s  ⇒ STAT_FLAGS=0x%02X  0x053B=0x%02X"
                  % (f["hex"], f["lo"], f["hi"]))
            for idx, name, cn in sg.VAL_BITS:
                if (d["lo"] >> idx) & 1:
                    print("    STAT_VAL  bit%d %-8s %s" % (idx, name, cn))
            for idx, name, cn in sg.FLAG_BITS:
                if (f["lo"] >> idx) & 1:
                    print("    STAT_FLAGS bit%d %-11s %s" % (idx, name, cn))
            frames_last = [last_frame] if last_frame else [
                {"s": s["s"][-1], "c": s["c"][-1], "io_flags": 0, "stat": 0,
                 "io_bits": {}, "io_flag_bits": {}}]
            state = sg.evaluate(frames_last, status, r=s["r_mean"], r_low=r_low, r_high=r_high)
            for key, name, _detail in sg.ALARM_ROWS:
                lv, txt = state[key]
                print("    %-13s %-11s %s" % (name, txt, lv))
            print("  摘要：%s" % sg.status_summary(status, r_host=s["r_mean"]))
            print("  ✓ 全部告警行都能翻成中文（无异常）")

        hr("⑥ 清锁存实测" + ("（--clear）" if args.clear else "（跳过：加 --clear 才写板）"))
        if args.clear:
            before = status or {}
            w = worker.write_reg(sg.REG_STAT_LATCH, sg.LATCH_CLEAR_VALUE, timeout=0.5, retries=1)
            print("  写 0x0405 = 0x%02X ⇒ 应答 %s"
                  % (sg.LATCH_CLEAR_VALUE, "无" if w is None else w["hex"]))
            time.sleep(0.05)
            d2 = worker.read_reg(sg.REG_STAT_VAL, timeout=0.4, retries=2)
            if d2 is None:
                print("  !! 清位后回读失败")
                rc = 1
            else:
                latch_before = before.get("latch0405") or 0
                print("  回读 0x0404 -> %s ⇒ STAT_LATCH=0x%02X（清位前 0x%02X）"
                      % (d2["hex"], d2["hi"], latch_before))
                if latch_before == 0 and d2["hi"] == 0:
                    print("  ✓ 本来就无锁存位，写命令被正常接受")
                elif d2["hi"] == 0:
                    print("  ✓ 锁存位已清（0x%02X → 0x00）" % latch_before)
                elif (d2["hi"] & latch_before) == 0:
                    print("  ✓ 旧的锁存位已清，新亮起的是新事件")
                else:
                    print("  ⚠ 清位后仍有位亮着（0x%02X），输入若压在满量程上属已知现象"
                          "（docs/07 第 1.9 条）" % d2["hi"])
        else:
            print("  未写板")

        hr("⑦ 制造一个真告警再清掉（--force-fault）" if args.force_fault
           else "⑦ 制造一个真告警再清掉（跳过：加 --force-fault 才写板）")
        if args.force_fault:
            # 用 ABLIMIT 造“限频”：板上 AB 所需边沿率 = 4×inter/div×f_in（本机 ≈ 2.5 MHz），
            # ablimit 设成 200 ⇒ 最小边沿间隔 20 ns×201 ≈ 4.02 µs ≈ 249 kHz，必然限频
            # ⇒ lag_limit / lag_warn 置位 ⇒ 0x0405 的 laglim 锁存位亮。测完恢复原值。
            old = worker.read_reg(rg.REG_ABLIMIT, timeout=0.5, retries=2)
            old_val = old["lo"] if old else 0
            print("  ABLIMIT(0x0106) 原值 = 0x%02X（%s）"
                  % (old_val, "读失败" if old is None else old["hex"]))
            if old is None:
                print("  !! 读不到 ABLIMIT，跳过本步（避免恢复不回去）")
            else:
                wr = worker.write_reg(rg.REG_ABLIMIT, 200, timeout=0.5, retries=1)
                print("  写 ABLIMIT = 200（0x%04X）⇒ 应答 %s"
                      % (200, "无" if wr is None else wr["hex"]))
                time.sleep(0.35)
                d3 = worker.read_reg(sg.REG_STAT_VAL, timeout=0.5, retries=2)
                f3 = worker.read_reg(sg.REG_STAT_FLAGS, timeout=0.5, retries=2)
                faulted = 0
                if d3 is None or f3 is None:
                    print("  !! 限频后回读状态失败")
                    rc = 1
                else:
                    faulted = d3["hi"]
                    print("  限频中：0x0404 -> %s ⇒ STAT_VAL=0x%02X STAT_LATCH=0x%02X"
                          % (d3["hex"], d3["lo"], d3["hi"]))
                    print("          0x053A -> %s ⇒ STAT_FLAGS=0x%02X" % (f3["hex"], f3["lo"]))
                    for idx, name, cn in sg.FLAG_BITS:
                        if (f3["lo"] >> idx) & 1:
                            print("            bit%d %-11s %s" % (idx, name, cn))
                    for idx, name, cn in sg.VAL_BITS:
                        if (d3["lo"] >> idx) & 1:
                            print("            STAT_VAL bit%d %-8s %s" % (idx, name, cn))
                    if faulted:
                        print("  ✓ 告警真的亮了并锁住（0x0405 = 0x%02X）" % faulted)
                    else:
                        print("  ?? 没造出锁存位（可能 ABZ 输出关着，或限频值还不够大）")

                # 撤掉故障源，再清锁存。RTL 语义（rtl/reg_file.v:411-416）：
                # 写 0x0405 是 W1C 清位，但**不写它的每一拍都会用实时状态重新锁存**
                # ⇒ 故障没消失时清不掉（清完立刻复亮），故障消失后清才留得住。
                rb = worker.write_reg(rg.REG_ABLIMIT, old_val, timeout=0.5, retries=1)
                chk = worker.read_reg(rg.REG_ABLIMIT, timeout=0.5, retries=2)
                print("  先撤掉故障源：恢复 ABLIMIT = 0x%02X ⇒ 应答 %s、回读 %s"
                      % (old_val, "无" if rb is None else rb["hex"],
                         "读失败" if chk is None else "0x%02X" % chk["lo"]))
                if chk is None or chk["lo"] != old_val:
                    print("  !! ABLIMIT 没恢复成功，请手工写回 0x%02X" % old_val)
                    rc = 1
                time.sleep(0.4)
                d4 = worker.read_reg(sg.REG_STAT_VAL, timeout=0.5, retries=2)
                if d4 is not None:
                    print("  故障源消失后：STAT_VAL(实时)=0x%02X、STAT_LATCH(锁存)=0x%02X"
                          % (d4["lo"], d4["hi"]))
                    if d4["lo"] == 0 and d4["hi"]:
                        print("  ✓ 这正是“锁存”的意义：实时故障没了，历史故障仍留着提醒（要手动清）")

                clr = worker.write_reg(sg.REG_STAT_LATCH, sg.LATCH_CLEAR_VALUE,
                                       timeout=0.5, retries=1)
                print("  写 0x0405 = 0x%02X ⇒ 应答 %s"
                      % (sg.LATCH_CLEAR_VALUE, "无" if clr is None else clr["hex"]))
                time.sleep(0.05)
                d5 = worker.read_reg(sg.REG_STAT_VAL, timeout=0.5, retries=2)
                print("  清位后回读 0x0404 -> %s ⇒ STAT_LATCH=0x%02X"
                      % ("读失败" if d5 is None else d5["hex"], 0 if d5 is None else d5["hi"]))
                if d5 is not None:
                    if faulted and d5["hi"] == 0:
                        print("  ✓ 清锁存生效（0x%02X → 0x00）—— 界面上的「清除锁存告警」"
                              "按钮走的就是这条写" % faulted)
                    elif faulted and (d5["hi"] & faulted) == 0:
                        print("  ✓ 旧的锁存位已清，亮着的是新发生的事件")
                    elif faulted:
                        print("  ⚠ 清完还有位亮着（0x%02X）；若故障源仍在，会立刻重新锁上" % d5["hi"])
                    else:
                        print("  ✓ 写通路正常（本来没有锁存位可清）")
                f5 = worker.read_reg(sg.REG_STAT_FLAGS, timeout=0.5, retries=2)
                if f5 is not None:
                    print("  收尾：0x053A = 0x%02X（应回到 0x00）" % f5["lo"])
        else:
            print("  未写板")

        hr("结论")
        print("  S3 验收自检 %s" % ("通过 (PASS)" if rc == 0 else "失败 (FAIL)"))
        return rc
    finally:
        worker.stop()


if __name__ == "__main__":
    raise SystemExit(main())
