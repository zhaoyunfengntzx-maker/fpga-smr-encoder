"""只读探针：板子在转的时候，一次把「前端误差 / 处理链残差 / 转速波动 / 寄存器地图」全测出来。

**这个脚本绝对不写任何寄存器**（电机在转，写错了就是撞机）。所有 `read_reg8` 都带
`retries=1, timeout=0.3`，读不到就记 None —— 和界面上的「板上运行状态」表同一套口径：
读不到就是读不到，不拿 0 冒充。

用法：
    python -X utf8 tools\\_probe_live.py            # 自动挑板子
    python -X utf8 tools\\_probe_live.py --port COM3 --seconds 8
"""

import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))

import numpy as np

import analysis as an
import link as lk
import regs


def pick_port():
    try:
        import ports as pm
        found = pm.list_serial_ports()
        for d, s, h in found:
            if pm.looks_like_board(d, s, h):
                return d, found
        if found:
            return found[0][0], found
    except Exception as exc:                                     # noqa: BLE001
        print("列端口失败：", exc)
    return None, []


def collect(w, seconds):
    frames = []
    counters = {}
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        try:
            kind, _text, extra = w.events.get(timeout=0.2)
        except Exception:                                        # noqa: BLE001
            continue
        if kind == "batch":
            frames.extend(extra.get("frames") or [])
            counters = extra.get("counters") or counters
        elif kind == "error":
            print("[链路错误]", _text)
        elif kind == "stats":
            counters = extra.get("counters") or counters
    return frames, counters


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--seconds", type=float, default=6.0)
    a = ap.parse_args(argv)

    port = a.port
    if not port:
        port, found = pick_port()
        for d, s, h in found:
            print("  端口 %-6s %s %s" % (d, s, h))
    if not port:
        print("[!!] 没找到串口")
        return 2
    print("== 打开 %s ==" % port)

    w = lk.SerialWorker(port)
    w.start()
    try:
        time.sleep(0.4)
        info = None
        try:
            info = w.read_device_info(timeout=0.6, retries=2)
        except Exception as exc:                                 # noqa: BLE001
            print("[设备信息] 读失败：", exc)
        print("== 设备信息 ==")
        print("  ", info)

        frames, counters = collect(w, a.seconds)
        print("== 收帧 ==")
        print("   帧数 %d ｜ 计数器 %s" % (len(frames), counters))
        if not frames:
            print("[!!] 没收到遥测帧（板子在转但没在发？）")
            return 3

        # ---------------------------------------------------------- 数据
        s = np.array([f.get("s") or 0 for f in frames], dtype=float)
        c = np.array([f.get("c") or 0 for f in frames], dtype=float)
        th = np.array([f.get("angle_deg") if f.get("angle_deg") is not None
                       else (f.get("angle") or 0) * 360.0 / 65536.0
                       for f in frames], dtype=float)
        io = [f.get("io_bits") or {} for f in frames]

        p = an.fit_quadrature(s, c)
        err = an.front_end_error(p)
        print("== 前端（李萨如点云回归）==")
        print("   R_s %.2f  R_c %.2f ｜ 增益差 %+.3f dB ｜ 正交误差 %+.4f°"
              % (p.get("r_s", 0), p.get("r_c", 0), p.get("gain_dB", 0),
                 p.get("eps_deg", 0)))
        print("   偏置 o_s %+.1f  o_c %+.1f ｜ 残差 %.2f LSB ｜ 迭代 %d 轮"
              % (p.get("off_s", 0), p.get("off_c", 0), p.get("res_rms", 0),
                 p.get("iters", 0)))
        print("   ⇒ 折算角度误差：增益 %.2f″ ｜ 正交 %.2f″ ｜ 偏置 %.2f″ ｜ 合计 %.2f″"
              % (err["gain_deg"] * 3600, err["orth_deg"] * 3600,
                 err["off_deg"] * 3600, err["total_deg"] * 3600))

        # -------------------------------------------------- 处理链残差
        os_, oc_ = p.get("off_s", 0.0), p.get("off_c", 0.0)
        th_ideal = np.degrees(np.arctan2(s - os_, c - oc_)) % 360.0
        d = an.wrap_error_deg(th_ideal - th)
        st = an.wrap_error_deg(th_ideal - th)
        print("== 处理链残差（arctan2(s,c) − 板上角度字）==")
        print("   n=%d ｜ 峰峰 %.2f″ ｜ RMS %.2f″ ｜ 最大 %.2f″ ｜ 均值 %+.2f″"
              % (st["n"], st["p2p"] * 3600, st["rms"] * 3600,
                 max(abs(st["max"]), abs(st["min"])) * 3600, st["mean"] * 3600))

        # ------------------------------------------------------ 转速波动
        dt = 1.0 / 10000.0
        w_el = np.diff(th) / dt                                # 电角度 °/s
        w_el = (w_el + 180.0) % 360.0 - 180.0                  # 折掉跨 0
        n_use = min(len(w_el), int(2.0 * 10000))
        seg = w_el[:n_use]
        if len(seg) > 100:
            mean = float(np.mean(seg))
            ripple = float(np.std(seg))
            print("== 转速（电角度域，%d 点）==" % len(seg))
            print("   平均 %.1f °/s ｜ 波动 rms %.3f °/s（%.2f%%）"
                  % (mean, ripple, 100.0 * ripple / abs(mean) if mean else 0.0))
            if len(seg) > 2048:
                x = seg - np.mean(seg)
                sp = np.abs(np.fft.rfft(x * np.hanning(len(x))))
                fr = np.fft.rfftfreq(len(x), dt)
                idx = np.argsort(sp)[-6:][::-1]
                peaks = ", ".join("%.1f Hz" % fr[i] for i in idx if fr[i] > 0)
                print("   主波动频率：", peaks)

        # -------------------------------------------------------- Z 闭合
        zidx = [i for i, b in enumerate(io) if b.get("z")]
        print("== Z ==")
        print("   帧里 z=1 的 %d 个（10 kHz 下每圈一次）" % len(zidx))

        # ------------------------------------------------------ 只读探测
        print("== 只读探测：0x0136…0x0140 ==")
        got = {}
        for addr in range(0x0136, 0x0141):
            try:
                v = w.read_reg8(addr, timeout=0.3, retries=1)
            except Exception:                                    # noqa: BLE001
                v = None
            got[addr] = v
            print("   0x%04X = %s" % (addr, "—" if v is None else "0x%02X" % v))

        print("== 只读探测：状态表 29 个地址 ==")
        raw = {}
        for addr in regs.STATUS_ADDRS:
            try:
                v = w.read_reg8(addr, timeout=0.3, retries=1)
            except Exception:                                    # noqa: BLE001
                v = None
            if v is not None:
                raw[addr] = v
        print("   读到 %d / %d" % (len(raw), len(regs.STATUS_ADDRS)))
        for name, val, note in regs.status_rows(raw):
            print("   %-10s %-14s %s" % (name, val, note))
        print("\n[OK] 全程只读，未写入任何寄存器")
        return 0
    finally:
        try:
            w.stop()
        except Exception:                                        # noqa: BLE001
            pass


if __name__ == "__main__":
    sys.exit(main())
