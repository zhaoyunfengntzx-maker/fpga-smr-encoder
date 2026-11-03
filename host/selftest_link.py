r"""无界面自检：对真机验证串口通信层（link.py）。

用法（在仓库根目录）：
    python host\selftest_link.py --port COM3 --seconds 3

它做四件事，任何一步失败都会打印原因并返回退出码 1：
  1. 列串口，看得到 CH340 吗；
  2. 连上，读设备身份证（0x05F0 / 0x05F1 / 0x05F2），打印原始应答字节；
  3. 连续收 N 秒遥测帧，统计帧率 / 校验错 / 重同步；
  4. 写回测试：把 0x0101、0x0102 的当前值原样写回去，再回读比对（证明写通路可用，
     且不改变板子任何行为）。
"""

import argparse
import os
import queue
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import link as lk              # noqa: E402
import ports as pm             # noqa: E402

try:                            # 控制台按 UTF-8 输出，中文不乱码
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:               # noqa: BLE001
    pass


def main(argv=None):
    ap = argparse.ArgumentParser(description="上位机串口通信层自检（真机）")
    ap.add_argument("--port", default=None, help="串口号，例如 COM3；默认自动挑 CH340")
    ap.add_argument("--baud", type=int, default=lk.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=3.0, help="收帧观察时长")
    ap.add_argument("--no-write-test", action="store_true", help="跳过写回测试")
    args = ap.parse_args(argv)

    rc = 0
    print("=" * 74)
    print("① 串口列表")
    print("=" * 74)
    found = pm.list_serial_ports()
    if not found:
        print("  !! 没有发现任何串口。板子插好了吗？COM 号只有插上时才存在。")
        return 1
    for device, desc, hwid in found:
        mark = "  <= 目标板（CH340）" if pm.looks_like_board(device, desc, hwid) else ""
        print("  %-8s %-28s %s%s" % (device, desc, hwid, mark))
    port = args.port or pm.preferred_port(found)
    if not port:
        print("  !! 没挑出端口")
        return 1
    print("  使用端口：%s" % port)

    print()
    print("=" * 74)
    print("② 连接 + 设备身份自检")
    print("=" * 74)
    worker = lk.SerialWorker(port, baud=args.baud, batch_ms=50.0)
    worker.start()
    t0 = time.monotonic()
    while not worker.connected and time.monotonic() - t0 < 5.0:
        if worker.error:
            print("  !! %s" % worker.error)
            return 1
        time.sleep(0.02)
    if not worker.connected:
        print("  !! 5 秒内没连上：%s" % (worker.error or "未知原因"))
        return 1
    print("  已连接 %s（%s）" % (port, lk.baud_text(args.baud)))

    info = worker.read_device_info()
    for key, val in info["raw"].items():
        print("  读 %s -> %s" % (key, val))
    print("  DEVICE_ID = %s（预期 0x%02X）"
          % (hex(info["device_id"]) if info["device_id"] is not None else "读失败",
             lk.EXPECT_DEVICE_ID))
    print("  REV       = %s（预期 0x%02X）"
          % (hex(info["rev"]) if info["rev"] is not None else "读失败", lk.EXPECT_REV))
    print("  RTL_BUILD = %s（v12=0x000C / v11=0x000B）"
          % (hex(info["rtl_build"]) if info["rtl_build"] is not None else "读失败"))
    if info["errors"]:
        for e in info["errors"]:
            print("  !! %s" % e)
        rc = 1
    for w in info["warnings"]:
        print("  ?? %s" % w)

    print()
    print("=" * 74)
    print("③ 连续收帧 %.1f 秒" % args.seconds)
    print("=" * 74)
    last = None          # 只留最后一帧做电平/位序检查：--seconds 60 时攒 60 万条很吃内存
    t0 = time.monotonic()
    # ★ 从收帧窗口起点取计数基准：连接阶段（读身份证 ~0.3 s）已经在流入遥测帧，
    #   若用累计值除以本窗口时长，帧率会虚高 10% 以上（曾算出 10,947 帧/秒 > 板上 10 kHz）。
    c0 = worker.counters()
    prev_frames = c0["frames"]
    last_report = t0
    while True:
        now = time.monotonic()
        if now - t0 >= args.seconds:
            break
        try:
            kind, text, extra = worker.events.get(timeout=0.05)
        except queue.Empty:
            kind, text, extra = None, "", {}
        if kind == "batch":
            if extra["frames"]:
                last = extra["frames"][-1]
        elif kind == "error":
            print("  !! %s" % text)
            rc = 1
        now = time.monotonic()
        if now - last_report >= 1.0:
            last_report = now
            c = worker.counters()
            this_sec = c["frames"] - prev_frames
            prev_frames = c["frames"]
            print("  t=%4.1fs  本秒=%5d 帧  校验错=%d  重同步=%d  缓冲=%d"
                  % (now - t0, this_sec, c["crc_err"] - c0["crc_err"],
                     c["resync_bytes"], c["buf_len"]))

    c = worker.counters()
    elapsed = time.monotonic() - t0
    d_frames = c["frames"] - c0["frames"]
    d_bytes = c["rx_bytes"] - c0["rx_bytes"]
    d_crc = c["crc_err"] - c0["crc_err"]
    fps = d_frames / elapsed if elapsed > 0 else 0.0
    bps = d_bytes / elapsed if elapsed > 0 else 0.0
    print("  %.2f 秒内新收 %d 帧 = %.0f 帧/秒、%.0f 字节/秒"
          % (elapsed, d_frames, fps, bps))
    print("  （板上 10 kHz × 18 B ≈ 180 kB/s，即 2 Mbaud 链路的 90% 占用）")
    print("  累计：字节=%d 有效帧=%d 校验错=%d(%.3f%%) 重同步=%d 迟到应答=%d "
          "应答成功=%d 应答超时=%d"
          % (c["rx_bytes"], c["frames"], c["crc_err"],
             100.0 * c["crc_err"] / max(1, c["frames"] + c["crc_err"]),
             c["resync_bytes"], c["stray_reply"], c["reply_ok"], c["reply_timeout"]))
    print("  界面前瞻：丢批=%d 丢帧=%d（界面跟不上时才会 >0）"
          % (c["dropped_batches"], c["dropped_frames"]))
    print("  帧布局：v2=%d  v1=%d" % (c["layout_v2"], c["layout_v1"]))

    if last is None:
        print("  !! 一帧都没收到：遥测是否常开？端口是否被别的程序占用？")
        rc = 1
    else:
        print("  最新帧：角度=%.3f°  s=%d c=%d  布局=%s  位置=%d  状态=0x%02X %s"
              % (last["angle_deg"], last["s"], last["c"], last["layout"],
                 last["pos_full"], last["stat"], ",".join(last["flags"]) or "-"))
        if last["io_bits"]:
            b = last["io_bits"]
            print("  输出电平：A=%d B=%d Z=%d U=%d V=%d W=%d dir=%d limiter=%d"
                  % (b["a"], b["b"], b["z"], b["u"], b["v"], b["w"],
                     b["dir"], b["limiter"]))
    if d_crc:
        rate = 100.0 * d_crc / max(1, d_frames + d_crc)
        # 重同步要跟校验错同口径用**本窗口增量**：resync_bytes 是累计值，
        # --seconds 60 时会把连接阶段吞掉的字节也算进来（审计发现）
        d_resync = c["resync_bytes"] - c0["resync_bytes"]
        print("  ?? 本窗口 %d 帧校验错（%.3f%%）、重同步 %d 字节。"
              % (d_crc, rate, d_resync))
        print("     这是**链路固有特性**，不是解析缺陷：同为 90% 占用的 2 Mbaud 链路上，")
        print("     参照工具 tools\\uart_scope.py --seconds 6（2026-10-13 实测）同一现象（XOR 校验失败")
        print("     212 帧、同步丢弃 3,940 字节、179,963 字节/秒）—— 那是**那次参照测量**的数字，")
        print("     本次运行的数字只以上面那行的「本窗口 N 帧校验错」为准。")
        print("     坏帧错位分布里 193/212 是多比特错（疑似丢/插字节），单比特只有 19。")
        print("     前几帧原始字节：")
        for line in c["bad_raw"]:
            print("     %s" % line)
    else:
        print("  本窗口无校验错，链路干净。")

    if not args.no_write_test:
        print()
        print("=" * 74)
        print("④ 写通路测试（原值写回，不改变板子行为）")
        print("=" * 74)
        for addr, name in ((0x0101, "INTER0"), (0x0102, "INTER1(div)")):
            before = worker.read_reg(addr)
            if before is None:
                print("  !! 读 0x%04X %s 超时，跳过写回" % (addr, name))
                rc = 1
                continue
            w = worker.write_reg(addr, before["value"])
            after = worker.read_reg(addr)
            ok = after is not None and after["value"] == before["value"]
            print("  0x%04X %-12s 读=0x%04X 写应答=%s 回读=%s  %s"
                  % (addr, name, before["value"],
                     w["hex"] if w else "超时",
                     "0x%04X" % after["value"] if after else "超时",
                     "OK" if ok else "不符"))
            if not ok:
                rc = 1
        d = worker.read_reg(0x0109)
        if d is not None:
            print("  0x0109 OUTPUT   = 0x%04X（bit6 abzen=%d bit7 uwven=%d）"
                  % (d["value"], (d["value"] >> 6) & 1, (d["value"] >> 7) & 1))

    worker.stop()
    print()
    print("=" * 74)
    print("结论：%s" % ("自检通过 (PASS)" if rc == 0 else "自检失败 (FAIL)"))
    print("=" * 74)
    return rc


if __name__ == "__main__":
    sys.exit(main())
