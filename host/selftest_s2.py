r"""S2 无界面验收自检：倍频倍率读写 + 转速（输入频率）交叉验证。

用法（在仓库根目录）：
    python host\selftest_s2.py --port COM3 --seconds 5

做四件事，任何一步失败都打印原因并返回退出码 1：
  1. 列串口、连上、读设备身份证与 S2 用到的 11 个配置寄存器（原始应答逐条打印）；
  2. **独立测输入频率**：隔 N 秒读两次硬件位置计数器 0x0536-39（32 位小端）
     与多周期计数 0x0534/35，用 Δ/Δt 算出 f_in —— 这条路径只走寄存器，
     和遥测帧流完全无关，用来判断界面上的转速是真慢还是解析错；
  3. 同一时间窗内把遥测帧喂给 host/encoder.py 的 SpeedEstimator，对比三种口径：
     角度累加（界面用的）、cycle 交叉校验、寄存器直读；
  4. 倍频写通路：inter 64 → 256 → 2（含 256/0 边界）逐写逐回读，最后**恢复原值**。

它只改 0x0101/0x0102（倍频），且结束时把原值写回去。
"""

import argparse
import os
import queue
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import link as lk                       # noqa: E402
import ports as pm                      # noqa: E402
import regs as rg                       # noqa: E402
from encoder import (SpeedEstimator, Z_INDEX_PAIRS,      # noqa: E402
                     unwrap_pos, FRAME_HZ)

try:                                    # 控制台按 UTF-8 输出，中文不乱码
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:                       # noqa: BLE001
    pass

STAT_CYCLE_LO = 0x0534                  # 多周期计数，16 位小端（0x0534 低字节）
STAT_POS_LO = 0x0536                    # 完整位置 {cycle, angle}，32 位小端
ANG_LSB = 65536.0                       # 一帧 angle 的分度（= 一个电周期）


def _lost_of(c):
    """累计丢帧数（校验错 + 重同步吞掉的）。老版本没有 lost_frames 时退回 crc_err。"""
    if "lost_frames" in c:
        return int(c["lost_frames"])
    return int(c.get("crc_err", 0))


def read_byte(worker, addr):
    """读一个寄存器的低字节（失败返回 None）。"""
    rep = worker.read_reg(addr)
    return None if not rep else (rep["value"] & 0xFF)


def read_u16_le(worker, base):
    b0, b1 = read_byte(worker, base), read_byte(worker, base + 1)
    if b0 is None or b1 is None:
        return None
    val = b0 | (b1 << 8)
    return val - (1 << 16) if val >= (1 << 15) else val


def read_u32_le(worker, base):
    bs = [read_byte(worker, base + i) for i in range(4)]
    if any(b is None for b in bs):
        return None
    val = bs[0] | (bs[1] << 8) | (bs[2] << 16) | (bs[3] << 24)
    return val - (1 << 32) if val >= (1 << 31) else val


def read_cfg(worker, addrs):
    """读一批配置寄存器，返回 {地址: 值}（读失败的地址不出现）。"""
    out = {}
    for a in addrs:
        rep = worker.read_reg(a)
        if rep:
            out[a] = rep["value"]
            print("  读 0x%04X -> %s = 0x%04X" % (a, rep["hex"], rep["value"]))
        else:
            print("  读 0x%04X -> 读失败（超时）" % a)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="上位机 S2 验收自检（真机）")
    ap.add_argument("--port", default=None, help="串口号，例如 COM3；默认自动挑 CH340")
    ap.add_argument("--baud", type=int, default=lk.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=5.0, help="频率测量的时间窗")
    ap.add_argument("--no-write-test", action="store_true", help="跳过倍频写回测试")
    args = ap.parse_args(argv)

    rc = 0
    print("=" * 74)
    print("① 串口列表")
    print("=" * 74)
    found = pm.list_serial_ports()
    if not found:
        print("  !! 没有发现任何串口。板子插好了吗？")
        return 1
    for device, desc, hwid in found:
        mark = "  <= 目标板（CH340）" if pm.looks_like_board(device, desc, hwid) else ""
        print("  %-8s %-28s %s%s" % (device, desc, hwid, mark))
    port = args.port or pm.preferred_port(found)
    if not port:
        print("  !! 没挑出端口")
        return 1
    print("  使用端口：%s" % port)

    worker = lk.SerialWorker(port, baud=args.baud, batch_ms=50.0)
    worker.start()
    try:
        print()
        print("=" * 74)
        print("② 设备身份证 + S2 配置寄存器")
        print("=" * 74)
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
        print("  RTL_BUILD = %s（v12=0x000C / v11=0x000B）"
              % (hex(info["rtl_build"]) if info["rtl_build"] is not None else "读失败"))
        for e in info["errors"]:
            print("  !! %s" % e)
            rc = 1
        if info["device_id"] != lk.EXPECT_DEVICE_ID:
            print("  !! 设备型号不对，后面不用测了")
            return 1
        if info["rtl_build"] not in (lk.EXPECT_RTL_V12, lk.EXPECT_RTL_V11):
            print("  ?? 固件构建号不是已知的 v11/v12，寄存器布局可能有变")

        cfg = read_cfg(worker, rg.CFG_ADDRS)
        if not cfg.get(rg.REG_INTER0) and rg.REG_INTER0 not in cfg:
            print("  !! 0x0101 读失败，倍频寄存器读写无法验证")
            rc = 1
        inter0, inter1 = cfg.get(rg.REG_INTER0, 0), cfg.get(rg.REG_INTER1, 0)
        inter, div = rg.decode_inter_div(inter0, inter1)
        pairs, pairs_raw = rg.decode_pairs(cfg.get(rg.REG_PAIRS, 0))
        print("  ⇒ 板上倍频：inter=%d div=%d（等效倍率 ×%.3f，0x0101=0x%04X 0x0102=0x%04X）"
              % (inter, div, rg.equiv_mult(inter, div), inter0, inter1))
        print("  ⇒ 板上极对数：%d（0x0100=0x%04X 原始 %d；界面默认 4）"
              % (pairs if pairs is not None else -1,
                 cfg.get(rg.REG_PAIRS, 0),
                 pairs_raw if pairs_raw is not None else -1))
        print("  ⇒ 输出极性/使能：0x0109=0x%04X → %s"
              % (cfg.get(rg.REG_OUTPUT, 0), rg.output_text(cfg.get(rg.REG_OUTPUT, 0))))

        print()
        print("=" * 74)
        print("③ 输入频率交叉验证（%.1f 秒窗）" % args.seconds)
        print("=" * 74)
        print("  说明：输入频率这一项可信的观测只有帧里的 pos_full（22 位单圈位置）。")
        print("        16 位 angle 在 10 kHz 采样下超过 5 kHz 就混叠；0x0536-39 是四个独立")
        print("        寄存器命令，高速下计数器会回绕/撕裂，只能当参考。")
        # 丢掉连接/读寄存器阶段积压的帧：否则窗口里混进 t_first 之前的帧，
        # 「位置增量 ÷ 墙上时间」这条独立路径会被算高（实测能差 8%）
        for _ in range(2):
            while True:
                try:
                    worker.events.get_nowait()
                except queue.Empty:
                    break
            time.sleep(0.3)

        pos0 = read_u32_le(worker, STAT_POS_LO)
        cyc0 = read_u16_le(worker, STAT_CYCLE_LO)
        t_a = time.monotonic()
        print("  起点参考：0x0536-39 = %s，0x0534/35 = %s"
              % (pos0 if pos0 is None else "%d" % pos0,
                 cyc0 if cyc0 is None else "%d" % cyc0))

        est = SpeedEstimator(pairs=pairs)
        n_frames = 0
        c_err = _lost_of(worker.counters())             # 窗口起点的丢帧计数
        t_first = t_last = None
        raw_cycles = 0.0        # 独立路径①：自己解 pos_full 增量（不经过 SpeedEstimator）
        prev_pos = None
        c_start = None          # 估算器在窗口起点的累计电周期数
        deadline = t_a + args.seconds
        while True:
            now = time.monotonic()
            if now >= deadline:
                break
            try:
                kind, text, extra = worker.events.get(timeout=0.05)
            except queue.Empty:
                continue
            if kind == "batch":
                frs = extra.get("frames") or []
                cnt = extra.get("counters") or {}
                if frs:
                    n_frames += len(frs)
                    if t_first is None:
                        t_first = time.monotonic()
                    t_last = time.monotonic()
                    bad = max(0, _lost_of(cnt) - c_err)
                    c_err = _lost_of(cnt)
                    snap_now = est.feed(frs, t_now=t_last, n_bad=bad)
                    if c_start is None:
                        c_start = snap_now["cycles"]
                    for fr in frs:
                        p = fr.get("pos_full")
                        if p is None:
                            continue
                        if prev_pos is not None:
                            raw_cycles += unwrap_pos(p - prev_pos) / ANG_LSB
                        prev_pos = p
            elif kind == "error":
                print("  !! %s" % text)
                rc = 1

        pos1 = read_u32_le(worker, STAT_POS_LO)
        cyc1 = read_u16_le(worker, STAT_CYCLE_LO)
        t_b = time.monotonic()
        print("  终点参考：0x0536-39 = %s，0x0534/35 = %s"
              % (pos1 if pos1 is None else "%d" % pos1,
                 cyc1 if cyc1 is None else "%d" % cyc1))
        snap = est.snapshot(t_now=t_b)
        print("  共收 %d 帧，墙上时间 %.3f 秒（%.0f 帧/秒）"
              % (n_frames, t_b - t_a, n_frames / max(1e-6, t_b - t_a)))

        f = snap.get("f_in") or 0.0
        f_raw = None
        if t_first is not None and t_last is not None and t_last > t_first:
            dt_raw = t_last - t_first
            f_raw = raw_cycles / dt_raw
            print("  【独立路径①】自解 pos_full 增量 = %.3f 电周期 / %.3f 秒 "
                  "⇒ f_in = %.4f Hz" % (raw_cycles, dt_raw, f_raw))
        print("  【主口径·界面用】f_in = %.4f Hz"
              " ＝（整数 %s + 小数 %+.5f 个电周期/帧）× %.0f Hz"
              % (f, snap.get("int_part"), snap.get("frac") or 0.0, FRAME_HZ))
        print("         丢帧不影响该口径；平滑窗 %.2f 秒（帧时隙）"
              % (snap.get("span") or 0.0,))
        if snap.get("loss_pct"):
            print("  ※ 独立路径①是「位置增量 ÷ 上位机墙上时间」，链路丢帧会让它偏高约 %.2f%%，"
                  "只作量级参考" % snap["loss_pct"])
        print("  【帧数时钟口径】f_in = %.4f Hz（含丢帧补偿，作交叉校验）"
              % (snap.get("f_clock") or 0.0))
        print("  【墙上时间口径】f_in = %.4f Hz（上位机计时，USB 批量到达会抖，仅作对照）"
              % (snap.get("f_wall") or 0.0))
        print("  【只看 16 位角度】f_in = %.4f Hz（>5 kHz 会混叠，仅剩小数残差可信）"
              % (snap.get("f_ang") or 0.0))
        print("  【换算】机械转速 %.2f RPM（极对数 %d；板上 Z 口径 %d 会给 %.2f RPM）"
              % (snap.get("rpm") or 0.0, pairs, Z_INDEX_PAIRS,
                 60.0 * abs(f) / Z_INDEX_PAIRS))
        edge = rg.edge_rate(inter, div, f)
        print("  【旁证】当前 inter=%d div=%d ⇒ AB 边沿率 = 4×%d÷%d×%.0f = %.3f MHz"
              % (inter, div, inter, div, f, edge / 1e6))
        print("         （工程里早先实测该板 AB 满速约 2.559 MHz，可判断量级是否合理）")
        if snap.get("note"):
            print("  .. %s" % snap["note"])
        if snap.get("warn"):
            print("  ?? %s" % snap["warn"])

        if not snap.get("ok"):
            print("  !! 帧口径算不出频率：%s" % (snap.get("note") or "数据不足"))
            rc = 1
        else:
            # 判据：主口径（整数+小数合成）与帧数时钟口径（收到的帧 + 丢帧 = 帧时隙）应一致。
            # 两条路径的"标尺"来源不同（一条靠每帧电周期增量取整，一条靠数帧时隙），
            # 一致就说明读数站得住。墙上时间口径只作参考：上位机排队/批量到达会让它差几个百分点。
            f_clock = snap.get("f_clock") or 0.0
            diff = abs(f_clock - f)
            tol = max(1.0, 0.01 * abs(f))
            if diff <= tol:
                print("  ✓ 主口径与帧数时钟口径一致（%.4f vs %.4f Hz，差 %.4f，容差 %.4f）"
                      % (f, f_clock, diff, tol))
            else:
                print("  !! 两种口径不一致：主口径 %.4f Hz vs 帧数时钟 %.4f Hz"
                      "（差 %.4f > 容差 %.4f）" % (f, f_clock, diff, tol))
                rc = 1
            if f_raw is not None:
                print("  .. 墙上时间口径（不作判据，仅量级参考）：%.4f Hz，与主口径差 %.2f%%"
                      % (f_raw, 100.0 * (f_raw - f) / max(1e-9, abs(f))))
            if c_start is not None:
                d_est = snap["cycles"] - c_start
                print("  .. 估算器累计 %.3f 电周期 vs 独立解算 %.3f（差 %.4f）"
                      % (d_est, raw_cycles, d_est - raw_cycles))
            if abs(f) < 10.0:
                if pos0 is not None and pos1 is not None:
                    d_pos = pos1 - pos0
                    f_reg = (d_pos / ANG_LSB) / (t_b - t_a)
                    print("  【寄存器口径】Δ位置 = %d ⇒ f_in = %.4f Hz" % (d_pos, f_reg))
                    lt = max(0.2, 0.05 * abs(f))
                    if abs(f_reg - f) <= lt:
                        print("  ✓ 寄存器口径也一致（容差 %.3f）" % lt)
                    else:
                        print("  !! 寄存器口径不符：%.4f vs %.4f Hz" % (f_reg, f))
                        rc = 1
            else:
                print("  .. 输入 >10 Hz，寄存器口径按 2^22 回绕必然撕裂，不作判据")

        print()
        print("=" * 74)
        print("④ 倍频写通路测试（改 0x0101/0x0102，结束时恢复原值）")
        print("=" * 74)
        if args.no_write_test:
            print("  已用 --no-write-test 跳过")
        elif not cfg.get(rg.REG_INTER0) and rg.REG_INTER0 not in cfg:
            print("  !! 原值没读到，不敢写（避免把板子设成未知状态）")
            rc = 1
        else:
            for test_inter, test_div in ((64, 1), (256, 1), (2, 1)):
                v101, v102 = rg.encode_inter_div(test_inter, test_div)
                print("  -- 写 inter=%d div=%d（0x0101=0x%04X 0x0102=0x%04X）"
                      % (test_inter, test_div, v101, v102))
                ok = True
                for addr, val in ((rg.REG_INTER0, v101), (rg.REG_INTER1, v102)):
                    rep = worker.write_reg(addr, val)      # 写+回读一步到位
                    if rep is None:
                        print("     !! 写 0x%04X 没拿到应答" % addr)
                        ok = False
                    else:
                        print("     写 0x%04X = 0x%04X -> %s（同帧回读 0x%04X）"
                              % (addr, val, rep["hex"], rep["value"]))
                back0 = worker.read_reg(rg.REG_INTER0)
                back1 = worker.read_reg(rg.REG_INTER1)
                if back0 is None or back1 is None:
                    print("     !! 回读失败")
                    ok = False
                else:
                    b_inter, b_div = rg.decode_inter_div(back0["value"], back1["value"])
                    same = (b_inter == test_inter and b_div == test_div)
                    print("     回读 0x0101=0x%04X 0x0102=0x%04X ⇒ inter=%d div=%d %s"
                          % (back0["value"], back1["value"], b_inter, b_div,
                             "✓ 生效" if same else "!! 不一致"))
                    ok = ok and same
                if not ok:
                    rc = 1
                time.sleep(0.3)

            print("  -- 恢复原值 inter=%d div=%d" % (inter, div))
            for addr, val in ((rg.REG_INTER0, inter0), (rg.REG_INTER1, inter1)):
                rep = worker.write_reg(addr, val)
                print("     写 0x%04X = 0x%04X -> %s"
                      % (addr, val, rep["hex"] if rep else "没拿到应答"))
            back0 = worker.read_reg(rg.REG_INTER0)
            back1 = worker.read_reg(rg.REG_INTER1)
            if back0 and back1 and back0["value"] == inter0 and back1["value"] == inter1:
                print("     ✓ 已恢复 0x0101=0x%04X 0x0102=0x%04X" % (inter0, inter1))
            else:
                print("     !! 恢复失败，请手工核对 0x0101=0x%04X 0x0102=0x%04X"
                      % (inter0, inter1))
                rc = 1
    finally:
        worker.stop()

    print()
    print("=" * 74)
    print("S2 验收自检 %s" % ("通过 (PASS)" if rc == 0 else "未通过 (FAIL)"))
    print("=" * 74)
    return rc


if __name__ == "__main__":
    sys.exit(main())
