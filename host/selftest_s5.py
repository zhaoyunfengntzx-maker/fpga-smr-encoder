#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""S5 验收自检：CSV 记录 + 一键导出 PNG（无界面，可选 30 分钟长稳）

做五件事：
  ① 离线跑 recorder.py / export_png.py 的自检（不插板子也能验一半）
  ② 直接连板子记录 N 秒：走 link.SerialWorker → recorder.Recorder，与界面同一条路
  ③ 回读 CSV：行数 ≈ 帧率×时长、24 列齐全、原始 18 字节帧能独立解回、
     墙上时间合理（不是 1970）、相对时刻单调递增
  ④ 出两张 PNG（波形 + ABZ/UVW）并检查像素尺寸与文件大小
  ⑤ --soak-minutes 时每 30 s 采样内存/帧率，判"连续运行不崩、不卡、文件能打开"

为什么用无界面的方式跑长稳：长稳要盯的是"链路 + 记录 + 出图"这三条不会因为
界面空闲就休息的路径；界面本身的健壮性另有 --smoke 截图与 S1~S4 的自检覆盖。
这样跑 30 分钟不用占着屏幕，也能在 CI/无人值守下复现。

用法（在仓库根目录）：
    python host\\selftest_s5.py --port COM3 --seconds 12
    python host\\selftest_s5.py --port COM3 --soak-minutes 30
    python host\\selftest_s5.py --verify-dir host\\_s5_soak    # 只离线核对已有记录文件
"""
from __future__ import annotations

import argparse
import ctypes
import glob
import os
import queue
import re
import shutil
import statistics
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import abz as az              # noqa: E402
import encoder as enc         # noqa: E402
import export_png as ep       # noqa: E402
import link as lk             # noqa: E402
import ports as pm            # noqa: E402
import recorder as rc         # noqa: E402
import regs as rg             # noqa: E402
import alarm as sg           # noqa: E402

# 组帧/解帧工具在东边的 tools/ 里（只读复用，不改它）
_TOOLS = os.path.join(os.path.dirname(_HERE), "tools")
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
try:
    import uart_scope as us                                   # noqa: E402
except Exception:                                             # noqa: BLE001
    us = None

FAIL = []
OK_N = [0]
OUT_DIR_DEFAULT = os.path.join(_HERE, "_s5_out")


def check(name, ok, info=""):
    if ok:
        OK_N[0] += 1
    else:
        FAIL.append(name)
    print("  [%s] %-32s %s" % ("OK" if ok else "!!", name, info))


def hr(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def _lost_of(c):
    """丢帧数：link.counters() 的新字段；老版本退回 crc_err。"""
    if not c:
        return 0
    if "lost_frames" in c:
        return int(c["lost_frames"])
    return int(c.get("crc_err", 0))


def parse_one(raw):
    """把一条 18 字节原始帧解回字典（复用 tools/uart_scope.py，只读不改）。"""
    if us is None:
        return None
    try:
        frames, _stats = us.parse_stream(bytes(raw))
    except Exception:                                            # noqa: BLE001
        return None
    return frames[0] if frames else None


def rss_mb():
    """当前进程的物理内存占用（MB）。拿不到就返回 None（不参与判定）。

    必须显式声明 argtypes/restype：不声明时 ctypes 会把 64 位进程句柄按 C int
    截断，GetProcessMemoryInfo 直接返回 0 ⇒ 长稳的内存判据会被静默跳过（踩过）。
    """
    try:
        from ctypes import wintypes

        class _PMC(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                        ("PeakWorkingSetSize", ctypes.c_size_t),
                        ("WorkingSetSize", ctypes.c_size_t),
                        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                        ("PagefileUsage", ctypes.c_size_t),
                        ("PeakPagefileUsage", ctypes.c_size_t)]

        for dll, fn in (("kernel32", "K32GetProcessMemoryInfo"),
                        ("psapi", "GetProcessMemoryInfo")):
            try:
                lib = ctypes.WinDLL(dll)
                func = getattr(lib, fn)
            except Exception:                                    # noqa: BLE001
                continue
            func.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PMC), wintypes.DWORD]
            func.restype = wintypes.BOOL
            pmc = _PMC()
            pmc.cb = ctypes.sizeof(_PMC)
            if func(ctypes.windll.kernel32.GetCurrentProcess(),      # type: ignore[attr-defined]
                    ctypes.byref(pmc), pmc.cb):
                return pmc.WorkingSetSize / 1048576.0
    except Exception:                                            # noqa: BLE001
        pass
    return None


def read_cfg(worker):
    """读回本卡配置（读应答高字节属于 addr+1，见 README 事实 4）。"""
    addrs = [rg.REG_PAIRS, rg.REG_INTER0, rg.REG_INTER1, rg.REG_OUTPUT]
    raw = {}
    for a in addrs:
        d = worker.read_reg(a, timeout=0.5, retries=3)
        raw[a] = d["value"] if d else None
        print("  读 0x%04X -> %s" % (a, (d or {}).get("hex", "读失败")))
    return raw


def record_run(worker, path, seconds, pairs=1, progress=None):
    """收 N 秒帧并写进 CSV。返回 (recorder, stats, 观测)。

    观测 = {"fps": [...], "rss": [...], "t": [...], "buf": …, "abz": …, "est": …}，
    长稳判据与出图都用它。
    与界面的区别只有一处：这里把帧直接喂给记录器，不经 Qt 队列。
    """
    rec = rc.Recorder(path, notice=lambda t, lv: print("    · %s" % t))
    if not rec.start():
        return rec, None, None
    buf = sg.WaveBuffer(1500)
    an = az.AbzAnalyzer(bins=256, pairs=pairs)
    est = enc.SpeedEstimator(pairs=pairs)
    f_in_hint = None

    t0 = time.monotonic()
    lost_prev = _lost_of(worker.counters())
    frames_total = 0
    seen = 0.0
    fps_hist, rss_hist, t_hist = [], [], []
    t_mark = t0
    mark_frames = 0
    t_next_report = t0 + (progress or 30.0)

    while True:
        now = time.monotonic()
        elapsed = now - t0
        got = []
        bad = 0
        for _ in range(400):
            try:
                kind, text, extra = worker.events.get_nowait()
            except queue.Empty:
                break
            if kind == "batch":
                got.extend(extra["frames"])
            elif kind == "error":
                print("    !! 链路错误：%s" % text)
            elif kind == "closed":
                print("    !! 连接被关闭：%s" % text)
        if got:
            lost_now = _lost_of(worker.counters())
            bad = max(0, lost_now - lost_prev)
            lost_prev = lost_now
            rec.feed(got, n_bad=bad)
            buf.feed(got)
            an.feed(got)
            est.feed(got, n_bad=bad)
            frames_total += len(got)
            if worker.error and not worker.connected:
                print("    !! 串口掉了：%s" % worker.error)
                break
        # 每秒采一次帧率，长稳时顺便采内存
        if now - t_mark >= 1.0:
            fps = (frames_total - mark_frames) / (now - t_mark)
            fps_hist.append(fps)
            t_hist.append(elapsed)
            r = rss_mb()
            if r is not None:
                rss_hist.append(r)
            t_mark, mark_frames = now, frames_total
            seen = fps
        if now >= t_next_report:
            t_next_report = now + (progress or 30.0)
            st = rec.stats(now)
            extra = ""
            r = rss_hist[-1] if rss_hist else None
            if r is not None:
                extra = "，内存 %.0f MB" % r
            cnow = worker.counters()
            if cnow.get("dropped_batches"):
                extra += "，丢批 %d/%d 帧" % (cnow["dropped_batches"],
                                              cnow.get("dropped_frames", 0))
            print("    %6.1f s / %s 帧 / %s / 丢帧 %s%s"
                  % (elapsed, format(st["rows"], ","), rc.size_text(st["bytes"]),
                     ("%.2f%%" % st["lost_pct"]) if st["rows"] else "—", extra))
        if elapsed >= seconds:
            break
        time.sleep(0.02)

    # 记录一结束就先把链路计数拍下来、把串口线程停掉：这个循环是唯一的消费者，
    # 循环一停还让串口线程继续灌，事件队列（300 批）满了就会记"丢批"，
    # 那是收尾动作造成的，不是记录丢帧（30 分钟长稳上真踩过：345 批 / 17 万帧）。
    c_stop = worker.counters()
    alive = bool(worker.connected)
    st = rec.stop()
    try:
        worker.stop()
    except Exception:                                            # noqa: BLE001
        pass
    obs = {"fps": fps_hist, "rss": rss_hist, "t": t_hist, "seen_fps": seen,
           "frames_total": frames_total, "buf": buf, "abz": an, "est": est,
           "counters_stop": c_stop, "alive": alive}
    return rec, st, obs


def _parts_of(first_path):
    """按分卷规则列出现存的所有分卷（第 1 卷就是 first_path 本身）。"""
    out = [first_path]
    i = 2
    while i <= 999:
        p = rc._part_path(first_path, i)
        if not os.path.isfile(p):
            break
        out.append(p)
        i += 1
    return out


def _first_part(dirpath):
    """从目录里挑出第 1 卷（文件名不带 `_partNNN` 的那个；都没有就取编号最小的）。"""
    csvs = sorted(glob.glob(os.path.join(dirpath, "*.csv")))
    if not csvs:
        return None
    plain = [p for p in csvs if not re.search(r"_part\d+$", os.path.splitext(p)[0])]
    return (plain or csvs)[0]


def verify_csv(path, st=None, seconds=None):
    """回读 CSV 逐项检查（自动覆盖所有分卷），返回 (ok, notes)。

    流式读：30 分钟长稳会写出上千万行，不能把整份文件读进内存（那会把被监测的
    进程自身的内存曲线弄花，也可能直接吃光内存）。
    分卷必须逐卷读：长稳 30 分钟写出 18 卷，只查第 1 卷会把“行数少了 17 倍”
    误报成失败（真踩过一次）。没有 st（离线核对已有文件）时，行数改与“时间跨度 × 10 kHz”自洽比对。
    """
    import csv as _csv

    ok = True
    notes = []
    parts = _parts_of(path)
    n = 0
    ncols = 0
    head0 = None
    first = mid = last = None
    prev_rel = None
    back = 0
    badcols = 0
    rel0 = None
    for pi, p in enumerate(parts):
        with open(p, encoding="utf-8-sig", newline="") as fh:
            rd = _csv.reader(fh)
            try:
                head = next(rd)
            except StopIteration:
                ok = False
                notes.append("第 %d 卷是空的：%s" % (pi + 1, os.path.basename(p)))
                continue
            if head != rc.CSV_COLUMNS:
                ok = False
                notes.append("第 %d 卷表头不对：%s" % (pi + 1, head))
            if head0 is None:
                head0 = head
            rows_here = 0
            for row in rd:
                rows_here += 1
                n += 1
                if len(row) != len(head):
                    badcols += 1
                if first is None:
                    first = row
                    rel0 = float(row[2])
                rel = float(row[2])
                if prev_rel is not None and rel < prev_rel - 1e-9:
                    back += 1
                prev_rel = rel
                if pi == len(parts) // 2 and rows_here == 1:
                    mid = row
                last = row
            if not rows_here:
                ok = False
                notes.append("第 %d 卷只有表头：%s" % (pi + 1, os.path.basename(p)))
    if head0 is None:
        return False, ["CSV 是空的"]
    if not n:
        return False, ["CSV 没有数据行"]
    ncols = len(head0)
    notes.append("%d 个分卷、共 %s 行、列 %d" % (len(parts), format(n, ","), ncols))
    if badcols:
        ok = False
        notes.append("有 %d 行列数不符（应 %d 列）" % (badcols, ncols))
    span = float(last[2]) - rel0
    # ① 行数：优先与记录器自己的统计对齐（±2000 是起停零头），否则与时间跨度自洽
    if st and st.get("rows"):
        if abs(n - int(st["rows"])) > 2000:
            ok = False
            notes.append("行数与记录器统计不符：%s vs %s"
                         % (format(n, ","), format(int(st["rows"]), ",")))
    elif st and st.get("fps") and seconds:
        want = st["fps"] * seconds
        if not (0.97 * want <= n <= 1.03 * want + 2000):
            ok = False
            notes.append("行数偏差过大：%s，期望 ≈ %s" % (format(n, ","), format(int(want), ",")))
    else:
        want = rc.FRAME_HZ * span
        if not (0.97 * want <= n <= 1.03 * want + 2000):
            ok = False
            notes.append("行数与时间跨度不自洽：%s 行 vs %.0f 行（%.2f s × 10 kHz）"
                         % (format(n, ","), want, span))
    # ② 相对时刻单调递增（含跨卷）、首尾跨度
    if back:
        ok = False
        notes.append("相对时刻有 %d 处倒流" % back)
    notes.append("跨度 %.2f s（首帧 %.4f s）" % (span, rel0))
    # ③ 墙上时间合理（单调时钟直接格式化会写出 1970-01-02，真踩过）
    t_first, t_last = first[1], last[1]
    if not (t_first.startswith("20") and t_last.startswith("20")):
        ok = False
        notes.append("墙上时间不像 21 世纪：%s" % t_first)
    notes.append("%s → %s" % (t_first, t_last))
    # ④ 原始 18 字节帧能独立解回，且与解析列一致（抽首卷首行、中间卷首行、末卷末行）
    mism = 0
    if us is None:
        notes.append("找不到 tools/uart_scope.py，跳过原始帧解回")
    else:
        for r in (first, mid, last):
            if r is None:
                continue
            raw = bytes.fromhex(r[3])
            if len(raw) != 18:
                mism += 1
                continue
            f = parse_one(raw)
            if f is None or int(f["angle"]) != int(r[4]) or int(f["s"]) != int(r[6]):
                mism += 1
        if mism:
            ok = False
        notes.append("抽 3 行原始帧解回%s" % ("一致" if not mism else "有 %d 处不一致" % mism))
    return ok, notes


def verify_png(path, want_px):
    ok = os.path.isfile(path)
    size = os.path.getsize(path) if ok else 0
    px = (0, 0)
    try:
        from PIL import Image
        with Image.open(path) as im:
            px = im.size
    except Exception:                                            # noqa: BLE001
        px = (0, 0)
    good = ok and size > 40000 and px == want_px
    return good, "%s（%s，%d×%d）" % (os.path.basename(path), rc.size_text(size),
                                     px[0], px[1])


def _collect(port, baud, seconds):
    """连上收 N 秒遥测帧，返回 (帧数, 错误文本)。用来模拟"拔线→插回"。"""
    w = lk.SerialWorker(port, baud=baud)
    w.start()
    t0 = time.monotonic()
    while not w.connected and time.monotonic() - t0 < 5.0:
        if w.error:
            w.stop()
            return 0, w.error
        time.sleep(0.02)
    if not w.connected:
        w.stop()
        return 0, (w.error or "5 秒内没连上")
    n0 = w.counters().get("frames", 0)
    t1 = time.monotonic()
    while time.monotonic() - t1 < seconds:
        time.sleep(0.05)
    n = w.counters().get("frames", 0)
    err = w.error
    w.stop()
    return n - n0, err


def reconnect_check(port, baud, seconds=2.0):
    """⑦/⑧ 断开→重连：关端口再重开同一端口（等价于拔线插回的上位机侧路径）。"""
    hr("⑦ 断开再连（关端口 → 重开同一端口，模拟拔线→插回）")
    n1, e1 = _collect(port, baud, seconds)
    check("第一次连接能收帧", e1 is None and n1 > 5000.0,
          "%s 帧%s" % (format(int(n1), ","), "" if e1 is None else "，异常：%s" % e1))
    if n1 <= 5000.0:
        # ★ 实测踩过：本机另有一个进程（另一个自检、界面版上位机、或 --soak-minutes 长稳）
        #   正占着同一个口。串口只能有一个主人，这时"能打开但收不到帧"是最常见的表象，
        #   报错必须点出来，否则会误判成"重连功能坏了"。
        print("    ⚠ 没收到帧：先确认没有别的程序占着 %s（另一个自检脚本 / 界面版上位机 /"
              % port)
        print("      `selftest_s5.py --soak-minutes` 长稳 / tools\\ 下的串口工具）。串口只能有一个主人。")
    print("    等待 1 秒，模拟「拔线」空窗…")
    time.sleep(1.0)
    n2, e2 = _collect(port, baud, seconds)
    check("插回后重新连上还能收帧", e2 is None and n2 > 5000.0,
          "%s 帧%s" % (format(int(n2), ","), "" if e2 is None else "，异常：%s" % e2))
    if n2 <= 5000.0:
        print("    ⚠ 同上：确认端口没被别的进程占用（详见上一段提示）。")
    print("    两次都是正常关端口，异常拔线的报错路径由 link.py 的异常兜底 + S1 自检覆盖")


def main(argv=None):
    ap = argparse.ArgumentParser(description="S5 验收自检（CSV 记录 + PNG 导出）")
    ap.add_argument("--port", default=None, help="串口号，例如 COM3（默认自动挑）")
    ap.add_argument("--baud", type=int, default=lk.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=12.0, help="记录时长（默认 12 s）")
    ap.add_argument("--soak-minutes", type=float, default=0.0,
                    help="长稳分钟数（>0 时覆盖 --seconds，默认 30 分钟验收用）")
    ap.add_argument("--dir", default=OUT_DIR_DEFAULT, help="临时输出目录")
    ap.add_argument("--verify-dir", default=None, metavar="目录",
                    help="只离线核对这个目录里已有的记录文件（不连板子、不重新记录）")
    ap.add_argument("--reconnect", action="store_true",
                    help="只做断开→重连检查（模拟拔线插回，不跑记录）")
    ap.add_argument("--keep", action="store_true", help="保留上次的输出目录")
    args = ap.parse_args(argv)

    if args.verify_dir:
        hr("④ 回读 CSV 逐项核对（离线：%s）" % args.verify_dir)
        first = _first_part(os.path.abspath(args.verify_dir))
        if not first:
            print("  !! 目录里没有 CSV 文件")
            return 1
        ok_csv, notes = verify_csv(first, None, None)
        for t in notes:
            print("    · %s" % t)
        check("CSV 行数/列/时间/原始帧", ok_csv, os.path.basename(first))
        hr("结果")
        print("  通过 %d 项，失败 %d 项" % (OK_N[0], len(FAIL)))
        if FAIL:
            for t in FAIL:
                print("    !! %s" % t)
            print("自检未通过 (FAIL)")
            return 1
        print("自检通过 (PASS)")
        return 0

    if args.reconnect:
        ports = pm.list_serial_ports()
        port = args.port or pm.preferred_port(ports)
        if not port:
            print("  !! 没找到可用串口")
            return 1
        print("  使用 %s @ %d baud" % (port, args.baud))
        reconnect_check(port, args.baud)
        hr("结果")
        print("  通过 %d 项，失败 %d 项" % (OK_N[0], len(FAIL)))
        if FAIL:
            for t in FAIL:
                print("    !! %s" % t)
            print("自检未通过 (FAIL)")
            return 1
        print("自检通过 (PASS)")
        return 0

    seconds = args.soak_minutes * 60.0 if args.soak_minutes > 0 else args.seconds
    soak = args.soak_minutes > 0
    out_dir = os.path.abspath(args.dir)

    hr("① 离线自检：recorder.py / export_png.py（不插板子）")
    if rc.selftest() != 0:
        FAIL.append("recorder 离线自检")
    if ep.selftest() != 0:
        FAIL.append("export_png 离线自检")

    hr("② 连板子、读配置")
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
        print("  设备：%s  REV=%s  RTL_BUILD=%s"
              % tuple(("----" if info.get(k) is None else "0x%04X" % info[k])
                      for k in ("device_id", "rev", "rtl_build")))
        raw = read_cfg(worker)
        inter, div = rg.decode_inter_div(raw.get(rg.REG_INTER0) or 0,
                                         raw.get(rg.REG_INTER1) or 0)
        pairs, _praw = rg.decode_pairs(raw.get(rg.REG_PAIRS) or 0)
        print("  板上配置：inter=%d div=%d 极对数=%d" % (inter, div, pairs))
        if info.get("rtl_build") != lk.EXPECT_RTL_V12:
            print("  ! 固件不是 v12（0x000C）：帧布局 v1，记录照样能用但没有 A/B/Z 列")
        check("固件布局 v2", info.get("rtl_build") == lk.EXPECT_RTL_V12,
              "0x%04X" % (info.get("rtl_build") or 0))

        # ---------------- ③ 记录 ----------------
        hr("③ 记录 %s" % ("%.1f 分钟（长稳）" % args.soak_minutes if soak
                        else "%g 秒" % seconds))
        if os.path.isdir(out_dir) and not args.keep:
            shutil.rmtree(out_dir, ignore_errors=True)
        os.makedirs(out_dir, exist_ok=True)
        # 盘空间预检（★ 自查踩过：长稳 22 分钟就写了 2.03 GB，事先没估过）
        # 10 kHz、18 列，实测约 150 B/行 ≈ 1.5 MB/s；这里按 2 MB/s 保守估并留 20% 余量。
        free = shutil.disk_usage(out_dir).free
        need = seconds * 2.0e6
        print("  可用空间 %.2f GB，本用例预计写约 %.2f GB" % (free / 1e9, need / 1e9))
        if free < need * 1.2:
            print("  !! 空间不足：%s 所在盘只剩 %.2f GB，本次预计要写 %.2f GB"
                  % (out_dir, free / 1e9, need / 1e9))
            print("     （10 kHz 记录约 1.5 MB/s ⇒ 长稳 30 分钟 ≈ 2.7 GB；请换到更空的盘或缩短时长）")
            check("磁盘空间够本次记录", False, "剩 %.2f GB / 需 %.2f GB" % (free / 1e9, need / 1e9))
            return 1
        check("磁盘空间够本次记录", True, "剩 %.2f GB / 需 %.2f GB" % (free / 1e9, need / 1e9))
        path = os.path.join(out_dir, rc.default_name())
        print("  写入 %s" % path)
        t_rec0 = time.monotonic()
        rec, st, obs = record_run(worker, path, seconds, pairs=pairs,
                                  progress=(30.0 if soak else 5.0))
        t_rec = time.monotonic() - t_rec0
        if not st:
            print("  !! 记录没起来：%s" % rec.error)
            return 1
        print("  " + rc.stats_text(st))

        # ---------------- ④ CSV 回读 ----------------
        hr("④ 回读 CSV 逐项核对")
        ok_csv, notes = verify_csv(path, st, t_rec)
        for n in notes:
            print("    · %s" % n)
        check("CSV 行数/列/时间/原始帧", ok_csv, "%s 行" % format(st["rows"], ","))
        check("行数 ≈ 帧率×时长", abs(st["rows"] - st["fps"] * t_rec) < 0.03 * max(
            1.0, st["fps"] * t_rec) + 2000,
              "%s 行 vs %.0f" % (format(st["rows"], ","), st["fps"] * t_rec))
        check("写入速率够用", st["fps"] > 8000.0, "%.0f 帧/秒" % st["fps"])
        check("丢帧率有界", st["lost_pct"] < 5.0, "%.2f%%" % st["lost_pct"])

        # ---------------- ⑤ 导出 PNG ----------------
        hr("⑤ 导出 PNG（波形 + ABZ/UVW）")
        snap = obs["buf"].snapshot()
        asnap = obs["abz"].snapshot()
        est = obs["est"]
        f_in = est.snapshot().get("f_abs") or 0.0
        print("  输入频率 %.3f Hz（记录期间实测，出图的理论值用它）" % f_in)
        meta = {"line1": ["端口 %s　设备 0x%02X　固件 0x%02X（S5 自检）"
                          % (port, info.get("device_id") or 0, info.get("rev") or 0),
                          "记录 %s　共 %s 帧" % (rc.size_text(st["bytes"]),
                                            format(st["rows"], ","))]}
        tw = time.time()
        info_w = ep.export_wave_png(os.path.join(out_dir, ep.suggest_name("wave", tw)),
                                    snap, meta=meta)
        info_a = ep.export_abz_png(os.path.join(out_dir, ep.suggest_name("abz", tw)),
                                   asnap, meta=meta,
                                   theory=obs["abz"].theory(f_in))
        okw, txtw = verify_png(os.path.join(out_dir, os.path.basename(info_w["path"])),
                               ep.wave_px())
        oka, txta = verify_png(os.path.join(out_dir, os.path.basename(info_a["path"])),
                               ep.abz_px())
        check("波形 PNG", bool(info_w.get("ok")) and okw, txtw)
        check("ABZ/UVW PNG", bool(info_a.get("ok")) and oka, txta)
        check("图里有波形数据", bool(snap.get("n")) and snap["r_mean"] is not None,
              "n=%d、r 均值 %.0f" % (snap.get("n") or 0, snap.get("r_mean") or 0))

        # ---------------- ⑥ 长稳判据 ----------------
        if soak:
            hr("⑥ 长稳判据（%.1f 分钟）" % args.soak_minutes)
            fps = obs["fps"][1:]
            rss = obs["rss"]
            if fps:
                med = statistics.median(fps)
                lo, hi = min(fps), max(fps)
                print("    帧率 中位 %.0f、最低 %.0f、最高 %.0f 帧/秒" % (med, lo, hi))
                check("帧率没掉底", lo > 0.70 * med, "最低/中位 = %.2f" % (lo / max(1.0, med)))
                check("帧率不上冲", hi < 1.30 * med, "最高/中位 = %.2f" % (hi / max(1.0, med)))
            if rss:
                print("    内存 起 %.0f MB、终 %.0f MB、峰 %.0f MB"
                      % (rss[0], rss[-1], max(rss)))
                check("内存不涨", rss[-1] - rss[0] < 60.0,
                      "增长 %.1f MB" % (rss[-1] - rss[0]))
            # 丢批/丢帧要看**记录结束那一刻**的计数：记录一停，这个脚本就不再消费事件队列，
            # 而串口线程还在往里灌（队列满就丢批）。那之后的丢批与"记录有没有丢帧"无关，
            # 拿最终计数判会把自检自己的收尾动作算成缺陷（30 分钟长稳上真踩过：345 批）。
            c = obs.get("counters_stop") or worker.counters()
            check("链路没死", bool(obs.get("alive", worker.connected)) and c.get("frames", 0) > 0,
                  "已收 %s 帧" % format(c.get("frames", 0), ","))
            check("批次没丢", c.get("dropped_batches", 0) == 0,
                  "丢批 %d、丢帧 %d" % (c.get("dropped_batches", 0),
                                     c.get("dropped_frames", 0)))
            check("记录文件可打开", ok_csv, os.path.basename(path))
    finally:
        try:
            worker.stop()
        except Exception:                                        # noqa: BLE001
            pass

    hr("结果")
    print("  通过 %d 项，失败 %d 项" % (OK_N[0], len(FAIL)))
    if FAIL:
        for n in FAIL:
            print("    !! %s" % n)
        print("自检未通过 (FAIL)")
        return 1
    print("输出目录：%s" % out_dir)
    print("自检通过 (PASS)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
