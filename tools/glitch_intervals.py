#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""glitch_intervals.py —— 高频轮询毛刺计数器，测「毛刺事件的时间间隔分布」。

动机（D 分支成因判别实验之一）：
  毛刺率在 20 kHz（1.8 次/s）与 19.979 kHz（1.5 次/s）几乎不变，1 kHz 旧记录却是 6~8 次/s。
  「率由某个恢复时间决定」与「率由随机罕见巧合决定」两种情况的时间间隔分布完全不同：
    * 恢复/弛豫型  -> 间隔有下界、集中在某个特征时间附近，方差小；
    * 随机巧合型  -> 间隔近似指数分布（Poisson），方差 ≈ 均值^2，最短间隔可以远小于均值。
  本脚本以远高于毛刺率的速率（目标 >100 Hz）轮询 gl_cnt_1024 的 16 位值，
  用主机时间戳记下每次自增，输出间隔统计 + 直方图 + CSV。

用法:
  E:\\Anaconda\\python.exe tools\\glitch_intervals.py --port COM6 --seconds 60
  ... --addr 0x0505（默认；0x0507 = >11.25° 那档） --csv _synth_work\\glitch_iv.csv

注意:
  * 只读寄存器，不写任何配置；不重下位流。
  * 计数器是自由运行累加的（16 位回绕），本脚本按 16 位差值记账。
"""
import argparse
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uart_spi  # noqa: E402


def read_counter(link, addr, timeout=0.4, tries=2):
    """回读 addr 的 16 位窗口 -> (value, raw) 或 (None, None)。

    ★ 不用 Link.transact（它会在重发时打屏）—— 本脚本要跑几千次轮询，输出必须干净；
      超时阈值必须与 diag_counters.py 同档（0.4 s），0.15 s 这种"紧"阈值会假超时
      （实测：0.15 s + tries=1 时首次回读即失败，而 uart_spi.py CLI 的同一条读正常）。
    """
    for _ in range(max(1, int(tries))):
        rb = link._once(uart_spi.encode_cmd(addr, write=False), timeout)[0]
        if rb is not None:
            return (rb[3] << 8) | rb[4], rb
    return None, None


def read_counter_fast(ser, addr, timeout=0.2, tries=2, chunk=32):
    """同上，但自己收字节（uart_spi.Link._once 固定 ser.read(512)，而板上 10 kHz 遥测帧
    把 2 Mbaud 链路占掉九成，512 字节要等 ~2.8 ms ⇒ 轮询率被压到 ~70 Hz）。
    小 chunk 收到应答即返回 ⇒ 实测轮询率提高一个量级，用来分辨"毛刺簇"是几拍内的
    连续坏样本，还是几十毫秒内的多次独立事件。
    """
    payload = uart_spi.encode_cmd(addr, write=False)
    for _ in range(max(1, int(tries))):
        try:
            ser.reset_input_buffer()
        except Exception:  # noqa: BLE001
            pass
        ser.write(payload)
        ser.flush()
        buf = bytearray()
        scan = 0
        t0 = time.time()
        while time.time() - t0 < timeout:
            b = ser.read(chunk)
            if not b:
                continue
            buf += b
            r, scan = uart_spi.find_reply(buf, scan)
            if r is not None:
                return (r[3] << 8) | r[4], r
            if len(buf) > 4096:
                del buf[:len(buf) - 256]
                scan = 0
    return None, None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=uart_spi.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--addr", default="0x0505",
                    help="计数器地址（0x0505=gl_1024>5.6°, 0x0507=gl_2048>11.25°）")
    ap.add_argument("--csv", default=None)
    ap.add_argument("--timeout", type=float, default=0.4, help="单次回读等待应答的秒数")
    ap.add_argument("--tries", type=int, default=2)
    ap.add_argument("--fast", action="store_true",
                    help="小 chunk 自读（理论上更快，但 2026-10-11 实测反而更慢：18.8 Hz；"
                         "uart_spi.Link._once 的 read(512) 是 69~78 Hz ⇒ 默认仍是后者）")
    ap.add_argument("--chunk", type=int, default=32)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    addr = int(args.addr, 0)
    ser = uart_spi.open_port(args.port, args.baud, timeout=0.2)
    if ser is None:
        return 1
    link = uart_spi.Link(ser, args.baud, retries=1)

    def _rd():
        if not args.fast:
            return read_counter(link, addr, args.timeout, args.tries)
        return read_counter_fast(ser, addr, args.timeout, args.tries, args.chunk)

    v0, _ = _rd()
    if v0 is None:
        print("  !! 首次回读超时：检查 COM 口/位流是否含 UART-SPI 桥/是否有外部 SPI 主机占用")
        return 1
    print("  起点 0x%04X = %d，轮询 %.1f s（地址 0x%04X）" % (addr, v0, args.seconds, addr))

    t_start = time.perf_counter()
    last = v0
    events = []          # (t_rel, value, delta)
    n_poll = 0
    n_miss = 0
    t_prev = t_start
    while True:
        t = time.perf_counter()
        if t - t_start >= args.seconds:
            break
        val, _ = _rd()
        n_poll += 1
        if val is None:
            n_miss += 1
            continue
        if val != last:
            delta = (val - last) & 0xFFFF
            t_rel = t - t_start
            events.append((t_rel, val, delta))
            if not args.quiet:
                iv = "" if len(events) < 2 else "  间隔 %.3f s" % (t_rel - events[-2][0])
                print("  t=%8.3f s  cnt=%5d  Δ=%d%s" % (t_rel, val, delta, iv))
            last = val
        t_prev = t
    t_end = time.perf_counter()
    elapsed = t_end - t_start

    print()
    print("  轮询 %d 次 / %.2f s = %.1f Hz（超时/丢应答 %d 次）"
          % (n_poll, elapsed, n_poll / max(elapsed, 1e-9), n_miss))
    print("  毛刺事件 %d 次 / %.2f s = %.3f 次/s" % (len(events), elapsed, len(events) / max(elapsed, 1e-9)))
    if len(events) >= 2:
        ivs = [events[i][0] - events[i - 1][0] for i in range(1, len(events))]
        ivs_sorted = sorted(ivs)
        print("  间隔 (s): mean %.3f  median %.3f  min %.3f  max %.3f  std %.3f"
              % (statistics.mean(ivs), statistics.median(ivs), min(ivs), max(ivs),
                 statistics.pstdev(ivs)))
        cv = statistics.pstdev(ivs) / max(statistics.mean(ivs), 1e-9)
        print("  变异系数 CV = %.3f  （≈1.0 => 近似指数/随机；<<1 => 有特征恢复时间）" % cv)
        # 直方图，20 个 bin 覆盖 min..max
        lo, hi = min(ivs), max(ivs)
        nb = 20
        w = (hi - lo) / nb if hi > lo else 1.0
        hist = [0] * nb
        for v in ivs:
            k = min(nb - 1, int((v - lo) / w))
            hist[k] += 1
        print("  间隔直方图 (%.3f ~ %.3f s, bin=%.3f s):" % (lo, hi, w))
        for k, h in enumerate(hist):
            if h:
                print("    %6.3f-%6.3f : %s%d" % (lo + k * w, lo + (k + 1) * w, "#" * min(h, 60), h))
        missed = [e for e in events if e[2] != 1]
        if missed:
            print("  ⚠ 有 %d 次单次轮询跨了多个计数（Δ!=1）：%s"
                  % (len(missed), ", ".join("t=%.3f Δ=%d" % (e[0], e[2]) for e in missed[:10])))
        else:
            print("  所有事件都被单独捕获（Δ=1）=> 轮询率足以分辨每个事件")

    if args.csv:
        with open(args.csv, "w", encoding="utf-8", newline="") as f:
            f.write("t_rel_s,value,delta,interval_s\n")
            prev = None
            for t_rel, val, delta in events:
                iv = "" if prev is None else "%.6f" % (t_rel - prev)
                f.write("%.6f,%d,%d,%s\n" % (t_rel, val, delta, iv))
                prev = t_rel
        print("  已写入 CSV: %s (%d 行)" % (args.csv, len(events)))
    try:
        ser.close()
    except Exception:  # noqa: BLE001
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
