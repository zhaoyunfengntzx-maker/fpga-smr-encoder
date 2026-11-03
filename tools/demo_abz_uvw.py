#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""demo_abz_uvw.py —— 一条命令跑完「上位机实时看 ABZ/UVW 波形」演示（素材清单 P2-7 口径）。

它把散在三个工具里的步骤串成一个可拍摄的流程，每一步都打印判据与结论：

  ① 版本门禁：读 `0x05F2`，必须是 `0x000C`（v12）。是 `0x000B` 说明板上还是 v11
     （帧里没有电平字段）—— 直接给烧写命令；是别的值/超时也各给对应提示。
  ② 寄存器配置：把 `inter` 设成 **32**（`0x0101` = `0x0020`，div = 1）并打开
     `abzen` + `uwven`（`0x0109` = `0x00C0`），然后**回读确认**。
     为什么必须降 `inter`：A/B 边沿率 = 4 × inter × f_in / div，`inter` = 256 时
     上电默认配置会撞 12.5 MHz 的 `filt_valid` 上限被静默钳位（`lag_warn` /
     `lag_fatal` 常置 1，见 `docs/DEV_STATUS.md` §1.33 ⑥）。`--no-write` 可跳过本步。
     ⚠ `0x0101` 这个 16 位窗口会连带写 `0x0102`（`rtl/spi_slave.v:244-251`），
     所以写 `0x0101` = `0x0020` 同时把 `div` 设成 0 ⇒ 实际 div = 1，语义一致。
  ③ 实时抓帧：默认 30 s，每秒打印一行滚动统计（帧数 / A·B 占空比 / 当前 UVW 码 /
     角度），这就是 "实时看波形" 的画面；同时全程记录原始字节。
  ④ 逐项判定：全量解析后检查 —— 帧布局 v2、A/B 都在动且占空比近 50%、
     UVW 只出现 6 种合法码（无 `000`/`111`）、等效采样分箱填充率、Z 是否被采到。
  ⑤ 落盘：CSV（每帧一行，含 `a b z u v w dir limiter` 列）+ 3×2 PNG（第 3 行是
     按电角度分箱的等效采样图 —— A/B 正交、UVW 六步、Z 一个窄脉冲）。
     加 `--archive` 会同时覆盖 `deliverables/figures/telemetry_abz_uvw.png` 与
     `deliverables/data/telemetry_abz_uvw.csv` 并打印 SHA256。

最后打印一行 `DEMO PASS` / `DEMO FAIL(n)`：拍视频时它就是终场字幕，
退出码 0/1 与之对应（`2` = 环境问题：缺 pyserial / 打不开串口 / 参数不对）。

用法（板子已在跑 v12 位流时）：
    python tools\\demo_abz_uvw.py --port COM3 --seconds 30 --archive
    python tools\\demo_abz_uvw.py --port COM3 --no-write        # 不改寄存器只抓帧
    python tools\\demo_abz_uvw.py --selftest                     # 不接硬件，验证判定逻辑

注意：端口号随插拔变（本机实测插上后是 COM3，历史文档写 COM6），
用 `python tools\\uart_spi.py ports` 或 `python tools\\demo_abz_uvw.py --ports` 查。
"""
import argparse
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import uart_scope as us          # noqa: E402  解析/报告/CSV/绘图
import uart_spi as sp            # noqa: E402  寄存器读写（encode_cmd / Link）

# ----------------------------------------------------------------------------
# 常量：与 rtl/uart_scope.v（帧布局 v2）、rtl/reg_file.v（寄存器语义）逐一对应
# ----------------------------------------------------------------------------
REG_VER_LO = 0x05F2        # RTL_BUILD_ID 低字节：v11 = 0x0B、v12 = 0x0C
REG_INTER0 = 0x0101        # INTER[7:0]（写它会连带写 0x0102 的 div 位）
REG_OUTPUT = 0x0109        # [6] abzen、[7] uwven
REG_OTRCLR = 0x0405        # 写 0x00FF 清 ADC 的 sticky OTR 锁存（否则 stat bit0 常亮）
WANT_INTER0 = 0x0020       # inter = 32、div = 1
WANT_OUTPUT = 0x00C0       # abzen | uwven
BUILD_V12 = 0x0C
BUILD_V11 = 0x0B
FRAME_TAG = us.FRAME_TAG_IO      # 0xA2
ANG_BINS = us.ANG_BINS           # 64
LEGAL_UVW = {0b001, 0b011, 0b010, 0b110, 0b100, 0b101}

# A/B 占空比的可接受窗口（正交且接近对称）
DUTY_LO, DUTY_HI = 30.0, 70.0
# 等效采样填充率下限（箱内 ≥3 帧才算填上）：低频慢扫时 30 s 能到 64/64
FILL_MIN = ANG_BINS // 2


# ============================================================================
# 判定
# ============================================================================
def analyze(frames, stats):
    """从解析结果里算出所有判定用的量（不打印，便于自检复用）。"""
    import numpy as np

    v2 = [f for f in frames if f["layout"] == "v2"]
    v1 = [f for f in frames if f["layout"] == "v1"]
    m = {"n_v2": len(v2), "n_v1": len(v1), "n": len(frames)}
    if not v2:
        return m

    duty, edges = {}, {}
    for name in us.IO_STATE_BITS:
        col = np.array([f["io_bits"][name] for f in v2], dtype=float)
        duty[name] = float(col.mean() * 100.0)
        edges[name] = int((np.diff(col) != 0).sum())
    m["duty"], m["edges"] = duty, edges

    uvw = ((np.array([f["io_bits"]["u"] for f in v2]) << 2)
           | (np.array([f["io_bits"]["v"] for f in v2]) << 1)
           | np.array([f["io_bits"]["w"] for f in v2]))
    uniq, cnt = np.unique(uvw, return_counts=True)
    m["uvw_hist"] = {int(u): int(c) for u, c in zip(uniq, cnt)}
    m["uvw_bad"] = {u: c for u, c in m["uvw_hist"].items() if u not in LEGAL_UVW}
    m["uvw_legal_n"] = len([u for u in m["uvw_hist"] if u in LEGAL_UVW])

    angs = np.array([f["angle"] for f in v2], dtype=float)
    bins = np.clip((angs / 65536.0 * ANG_BINS).astype(int), 0, ANG_BINS - 1)
    m["filled"] = int((np.bincount(bins, minlength=ANG_BINS) >= 3).sum())
    m["angle_span"] = float(angs.max() - angs.min()) * 360.0 / 65536.0
    return m


def verdict(m, require_uvw=True):
    """把 analyze 的量变成 (ok, 名称, 说明) 列表。"""
    out = []
    n, n_v2, n_v1 = m["n"], m["n_v2"], m["n_v1"]
    out.append((n_v2 > 0 and n_v1 <= max(3, 0.001 * n),
                "帧布局 v2", "v2 %d 帧 / v1 %d 帧（偏移 9 = 0x%02X）" % (n_v2, n_v1, FRAME_TAG)))
    if not n_v2:
        return out

    d, e = m["duty"], m["edges"]
    for nm in ("a", "b"):
        out.append((DUTY_LO <= d[nm] <= DUTY_HI and e[nm] > 0,
                    "%s 在动且占空比近 50%%" % nm.upper(),
                    "占空 %.1f%%，跳变 %d 次" % (d[nm], e[nm])))
    out.append((d["dir"] * 100.0 > 99.0 or d["dir"] * 100.0 < 1.0,
                "方向位稳定", "dir 高电平占比 %.1f%%" % d["dir"]))
    out.append((d["limiter"] < 1.0, "限幅器未激活",
                "limiter 高电平占比 %.1f%%" % d["limiter"]))

    if require_uvw:
        out.append((not m["uvw_bad"], "UVW 只有合法状态",
                    "出现 %d 种合法码%s" % (m["uvw_legal_n"],
                                          "；非法：" + ", ".join("%03d×%d" % (u, c)
                                                                for u, c in sorted(m["uvw_bad"].items()))
                                          if m["uvw_bad"] else "")))
        out.append((m["uvw_legal_n"] >= 5, "UVW 六步转起来了",
                    "覆盖 %d/6 种合法码" % m["uvw_legal_n"]))
    else:
        out.append((True, "UVW 未使能（uwven = 0）",
                    "报告里会出现 `000` 非法态，属预期：本次按 --no-write 只读不配"))
    out.append((m["filled"] >= FILL_MIN, "等效采样填充率",
                "%d/%d 箱（每箱 ≥3 帧）" % (m["filled"], ANG_BINS)))
    # Z 只作记录：Z 脉宽通常远窄于 100 µs 采样周期，按时间轴采不到属正常现象，
    # 等效采样图里才看得到 ⇒ 不作为失败项，免得演示现场出现假警报。
    out.append((True, "Z 采样情况（仅记录）",
                "跳变 %d 次、占空 %.2f%%（按时间轴看不到属正常）" % (e["z"], d["z"])))
    return out


# ============================================================================
# 实时扫描（只为画面；最终判定用 uart_scope.parse_stream 全量解析）
# ============================================================================
class LiveScan(object):
    """增量扫描 18 字节遥测帧，够实时打印，不重复实现解析器。"""

    def __init__(self):
        self.buf = bytearray()
        self.nframe = 0
        self.nbad = 0

    def feed(self, chunk):
        self.buf += chunk
        out, i, n = [], 0, len(self.buf)
        while i + 18 <= n:
            if self.buf[i] == 0xAA and self.buf[i + 1] == 0x55:
                fr = bytes(self.buf[i:i + 18])
                chk = 0xAA ^ 0x55
                for b in fr[2:17]:
                    chk ^= b
                if chk == fr[17]:
                    out.append(fr)
                    self.nframe += 1
                    i += 18
                    continue
                self.nbad += 1
            i += 1
        del self.buf[:i]
        if len(self.buf) > 64:              # 防止噪声把残留缓冲撑大
            del self.buf[:-1]
        return out


def live_line(frames_bytes):
    """把"这一秒"的帧变成一行滚动统计。返回 (文本, 本秒是否有效)。"""
    nb = len(frames_bytes)
    if nb == 0:
        return None, False
    a = [b[8] & 1 for b in frames_bytes]
    bb = [(b[8] >> 1) & 1 for b in frames_bytes]
    uvw = [(b[8] >> 3) & 7 for b in frames_bytes]
    ang = [((b[2] << 8) | b[3]) * 360.0 / 65536.0 for b in frames_bytes]
    e_a = sum(1 for k in range(1, nb) if a[k] != a[k - 1])
    e_b = sum(1 for k in range(1, nb) if bb[k] != bb[k - 1])
    return ("A %4.1f%% (%d 边沿)  B %4.1f%% (%d 边沿)  UVW=%03d  angle %5.1f°"
            % (100.0 * sum(a) / nb, e_a, 100.0 * sum(bb) / nb, e_b,
               uvw[-1], ang[-1])), True


# ============================================================================
# 串口 + 寄存器小工具
# ============================================================================
def rd(link, addr, timeout=0.4):
    v, _ = sp._readback(link, addr, timeout)
    return v


def wr(link, addr, val, timeout=0.4):
    """写 + 回读确认（低字节掩码，避免相邻寄存器干扰）。"""
    rep = link.transact(sp.encode_cmd(addr, val, write=True), timeout)
    if rep is None:
        return False, None
    got = rd(link, addr, timeout)
    mask = 0xFFFF if val > 0xFF else 0x00FF
    return (got is not None and (got & mask) == (val & mask)), got


def step(n, total, title):
    print()
    print("─" * 78)
    print("  [%d/%d] %s" % (n, total, title))
    print("─" * 78)


# ============================================================================
# 自检（不接硬件）
# ============================================================================
def _synth(n_elec=3, n_per=400, uwven=True, inter=32):
    """造一段合成遥测流：角度扫过整圈、A/B 按 inter=32 交替、UVW 走六步。"""
    frames = bytearray()
    uvw_seq = [(1, 1, 0), (0, 1, 0), (0, 1, 1), (0, 0, 1), (1, 0, 1), (1, 0, 0)]
    k = 0
    for _ in range(n_elec):
        for i in range(n_per):
            deg = 360.0 * i / n_per
            raw = int(deg / 360.0 * 65536) & 0xFFFF
            s = int(20000 * math.sin(math.radians(deg)))
            c = int(20000 * math.cos(math.radians(deg)))
            u, v, w = uvw_seq[min(5, int(deg // 60))] if uwven else (0, 0, 0)
            a = 1 if (int(deg * inter / 90.0) & 1) else 0      # 每 90/inter 度翻一次
            b = 1 if (int((deg - 90.0 / inter) * inter / 90.0) & 1) else 0
            z = 1 if deg < 3.0 else 0
            io = a | (b << 1) | (z << 2) | (u << 3) | (v << 4) | (w << 5) | (1 << 6)
            frames += us.build_frame(raw, s, c, io, 0x00, k, 0)
            k += 1
    return bytes(frames)


def selftest():
    print("=" * 78)
    print("  demo_abz_uvw --selftest（不接硬件，验证判定逻辑）")
    print("=" * 78)
    ok = True

    def run(name, buf, require_uvw, want_pass):
        nonlocal ok
        frames, stats = us.parse_stream(buf)
        m = analyze(frames, stats)
        res = verdict(m, require_uvw=require_uvw)
        passed = all(r[0] for r in res)
        print()
        print("  [%s] %s（期望 %s，实得 %s）"
              % ("OK" if passed == want_pass else "!!", name,
                 "PASS" if want_pass else "FAIL", "PASS" if passed else "FAIL"))
        for good, nm, det in res:
            if not good:
                print("       ❌ %s —— %s" % (nm, det))
        if passed != want_pass:
            ok = False
        return res

    # 1) 正常合成流：应 PASS
    run("合成流（v2、A/B 交替、UVW 六步）", _synth(), True, True)
    # 2) uwven 关：UVW 全 000 ⇒ 应 FAIL
    run("合成流（uwven 关，UVW 恒 000）", _synth(uwven=False), True, False)
    # 3) 纯 v1 旧位流：应 FAIL（帧布局不是 v2）
    v1 = bytearray()
    for k in range(500):
        v1 += us.build_frame_v1(k, 1000, 2000, 0xDEADBEEF, k, 0)
    run("v11 旧布局帧（无电平字段）", bytes(v1), True, False)
    # 4) 增量扫描器与全量解析的帧数一致
    buf = _synth(n_elec=1, n_per=600)
    ls = LiveScan()
    got = 0
    for i in range(0, len(buf), 37):        # 故意用非 18 倍数的块切
        got += len(ls.feed(buf[i:i + 37]))
    frames, _ = us.parse_stream(buf)
    same = (got == len(frames) == 600)
    print()
    print("  [%s] LiveScan 增量扫描 = 全量解析（%d vs %d 帧）"
          % ("OK" if same else "!!", got, len(frames)))
    ok = ok and same

    print()
    print("  " + ("TEST PASSED" if ok else "TEST FAILED"))
    return 0 if ok else 1


# ============================================================================
# 主程序
# ============================================================================
def main(argv=None):
    try:
        sys.stdout.reconfigure(errors="replace")
        sys.stderr.reconfigure(errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="一条命令演示：上位机实时看 ABZ/UVW（P2-7）")
    ap.add_argument("--selftest", action="store_true", help="不接硬件，自检判定逻辑")
    ap.add_argument("--ports", action="store_true", help="只列出串口后退出")
    ap.add_argument("--port", help="串口名，如 COM3")
    ap.add_argument("--baud", type=int, default=sp.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=30.0, help="抓帧时长，默认 30 s")
    ap.add_argument("--no-write", action="store_true",
                    help="只读不配寄存器（不写 0x0101 / 0x0109）")
    ap.add_argument("--outdir", default=os.path.join("_synth_work", "demo_abz_uvw"),
                    help="CSV/PNG 输出目录（默认 _synth_work\\demo_abz_uvw）")
    ap.add_argument("--archive", action="store_true",
                    help="另把图/CSV 覆盖到 deliverables/figures|data 并打印 SHA256")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if args.ports:
        return sp.list_ports()
    if not args.port:
        ap.print_help()
        print("\n提示：先用 --selftest 验证逻辑，再 --port COM3 接板跑。")
        return 2

    try:
        import serial
    except ImportError:
        print("需要 pyserial：pip install pyserial")
        return 2

    outdir = args.outdir if os.path.isabs(args.outdir) else os.path.join(
        os.path.dirname(HERE), args.outdir)
    os.makedirs(outdir, exist_ok=True)
    csv_path = os.path.join(outdir, "telemetry_abz_uvw.csv")
    png_path = os.path.join(outdir, "telemetry_abz_uvw.png")

    print("=" * 78)
    print("  上位机实时看 ABZ/UVW 波形  ——  v12 遥测帧布局 v2 演示（素材 P2-7）")
    print("  RTL_BUILD_ID 需为 v12（0x05F2 = 0x000C）；板流见 docs/DEV_STATUS.md §1.59")
    print("=" * 78)

    fails = []

    def chk(cond, name, detail):
        print("  %s %s —— %s" % ("✅" if cond else "❌", name, detail))
        if not cond:
            fails.append(name)
        return cond

    # ---------------- 开串口 ----------------
    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.05)
        try:
            ser.set_buffer_size(rx_size=1 << 20)   # 2 Mbaud = 180 kB/s，缓冲要够深
        except Exception:
            pass
    except Exception as e:
        print("  打不开串口 %s：%s" % (args.port, e))
        print("  用 `python tools\\uart_spi.py ports` 看可用端口。")
        return 2
    link = sp.Link(ser, args.baud, retries=3)

    total_steps = 5
    result = 1
    try:
        # ---------------- ① 版本门禁 ----------------
        step(1, total_steps, "版本门禁：读 0x05F2（RTL_BUILD_ID 低字节）")
        ver = rd(link, REG_VER_LO)
        if ver is None:
            chk(False, "链路通", "0x05F2 读回超时（检查端口/位流是否含 UART-SPI 桥/"
                                 "是否有外部 SPI 主机占用）")
            print("  超时期间收到: %s" % link.tail_hex())
            raise SystemExit(1)
        chk(True, "链路通", "0x05F2 = 0x%04X" % ver)
        if ver == BUILD_V12:
            chk(True, "板上是 v12", "遥测偏移 9 = 0x%02X（电平字段有效）" % FRAME_TAG)
        elif ver == BUILD_V11:
            chk(False, "板上是 v12",
                "读回 0x%04X = v11：帧里没有电平字段。先烧 v12 位流：\n"
                "       $env:ILA_MODE='restore'; $env:ILA_BIT='_synth_work\\enc_top.bit'\n"
                "       powershell -NoProfile -ExecutionPolicy Bypass -File "
                "tools\\run_vivado.ps1 -Tcl tools\\ila_capture.tcl "
                "-LogFile _synth_work\\dl_v12_restore.log -Tail 20" % ver)
            raise SystemExit(1)
        else:
            chk(False, "板上是 v12", "读回 0x%04X：既不是 v12(0x000C) 也不是 v11(0x000B)"
                                     " —— 确认烧的是哪个位流" % ver)
            raise SystemExit(1)

        # ---------------- ② 寄存器配置 ----------------
        step(2, total_steps, "寄存器配置：inter = 32（0x0101 = 0x0020）+ abzen|uwven（0x0109 = 0x00C0）")
        v_int, v_out = rd(link, REG_INTER0), rd(link, REG_OUTPUT)
        print("  当前：0x0101 = %s、0x0109 = %s"
              % ("超时" if v_int is None else "0x%04X" % v_int,
                 "超时" if v_out is None else "0x%04X" % v_out))
        if args.no_write:
            print("  --no-write：只读不写。若 0x0109[7]（uwven）为 0，UVW 会恒为 000，"
                  "判定里会当作预期情况。")
        else:
            if v_int is not None and (v_int & 0x00FF) == (WANT_INTER0 & 0x00FF):
                chk(True, "inter 已是 32", "0x0101 = 0x%04X" % v_int)
            else:
                okw, got = wr(link, REG_INTER0, WANT_INTER0)
                chk(okw, "写 0x0101 = 0x0020", "回读 0x0101 = %s（inter = 32、div = 1）"
                                              % ("超时" if got is None else "0x%04X" % got))
            if v_out is not None and (v_out & 0x00FF) == (WANT_OUTPUT & 0x00FF):
                chk(True, "0x0109 已是 0x00C0", "abzen + uwven 都开")
            else:
                okw, got = wr(link, REG_OUTPUT, WANT_OUTPUT)
                chk(okw, "写 0x0109 = 0x00C0", "回读 0x0109 = %s（abzen + uwven）"
                                              % ("超时" if got is None else "0x%04X" % got))
        uvw_on = True
        got_out = rd(link, REG_OUTPUT)
        if got_out is not None:
            uvw_on = bool(got_out & 0x0080)
            print("  uwven = %d（UVW 输出%s）" % (uvw_on, "开" if uvw_on else "关"))

        # ---------------- ③ 实时抓帧 ----------------
        step(3, total_steps, "实时抓帧 %.0f s（每秒一行滚动统计）" % args.seconds)
        try:                                    # 清 sticky OTR，避免 stat bit0 常亮
            ser.write(bytes([0x8C, 0x05, 0x00, 0xFF]))
            ser.flush()
            time.sleep(0.05)
            ser.reset_input_buffer()
        except Exception as e:
            print("  （清 OTR 锁存失败，忽略：%s）" % e)

        scan = LiveScan()
        raw = bytearray()
        per_sec = []
        t0 = time.time()
        next_tick = t0 + 1.0
        while time.time() - t0 < args.seconds:
            n = ser.in_waiting
            chunk = ser.read(n if n else 1)
            if chunk:
                raw += chunk
                per_sec.extend(scan.feed(chunk))
            if time.time() >= next_tick:
                line, ok_line = live_line(per_sec)
                el = time.time() - t0
                print("  [%5.1fs] 帧 %6d   %s"
                      % (el, scan.nframe,
                         line if ok_line else "（本秒没收到完整帧）"))
                per_sec = []
                next_tick += 1.0
        ser.close()
        print("  抓帧结束：%d 帧（扫描器还看到 %d 处校验失败/重同步）"
              % (scan.nframe, scan.nbad))

        # ---------------- ④ 全量解析 + 逐项判定 ----------------
        step(4, total_steps, "全量解析 + 逐项判定")
        frames, stats = us.parse_stream(bytes(raw))
        if not frames:
            chk(False, "收到遥测帧", "一个完整帧都没解析出来（链路/波特率/位流）")
            raise SystemExit(1)
        us.report(frames, stats)          # 完整人可读报告（占空比/UVW 分布/填充率）
        m = analyze(frames, stats)
        print()
        print("  —— 判定清单 ——")
        for good, nm, det in verdict(m, require_uvw=uvw_on):
            chk(good, nm, det)

        # ---------------- ⑤ 落盘 ----------------
        step(5, total_steps, "落盘：CSV + 3×2 PNG（第 3 行 = 按电角度的等效采样）")
        us.save_csv(frames, csv_path)
        us.maybe_plot(frames, png_path)
        print("  CSV : %s" % csv_path)
        print("  PNG : %s" % png_path)
        if args.archive:
            import hashlib
            import shutil
            root = os.path.dirname(HERE)
            dst = [(png_path, os.path.join(root, "deliverables", "figures",
                                           "telemetry_abz_uvw.png")),
                   (csv_path, os.path.join(root, "deliverables", "data",
                                           "telemetry_abz_uvw.csv"))]
            for src, d in dst:
                shutil.copyfile(src, d)
                h = hashlib.sha256(open(d, "rb").read()).hexdigest().upper()
                print("  归档 %s  (%d B, SHA256 %s…)"
                      % (os.path.relpath(d, root), os.path.getsize(d), h[:16]))

        result = 1 if fails else 0
    except SystemExit as e:
        result = int(e.code or 0)
    except KeyboardInterrupt:
        print("\n  被 Ctrl-C 中断。")
        result = 2

    print()
    print("=" * 78)
    if result == 0:
        print("  DEMO PASS —— 上位机已能实时看到 ABZ/UVW 六路电平（图见 %s）"
              % os.path.relpath(png_path))
    else:
        print("  DEMO FAIL(%d) —— 未通过项：%s"
              % (len(fails), "、".join(fails) if fails else "见上面 ❌"))
    print("=" * 78)
    return result


if __name__ == "__main__":
    sys.exit(main())
