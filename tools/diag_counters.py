#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""v6 诊断计数器读数器：两次采样求差 => 毛刺密度与窗口健康度（不依赖 ILA）。

用法：
    python tools\\diag_counters.py --port COM6 [--seconds 20] [--csv out.csv]

为什么用"求差"而不是直接读：`0x0505..0x050E`（角度毛刺计数）与 `0x0540`
（周期脉冲累计）都是**累计值**，与真实时间无关；两次读数的差值是这段时间里
实际发生的事件数，因此毛刺密度天然免疫 UART 慢和轮询抖动：

    毛刺密度（每输入周期发生次数） = Δ毛刺计数 / Δ周期脉冲计数

窗口快照 `0x0542..0x0549` 是**最近一次关门窗口**的值（不是累计），两次读数
之差没有意义，只把最后一次当结论看：

    int_max / int_min > 1.25  => 该窗口按 §1.29 判为非整周期并作废重来

寄存器映射出处：`rtl/reg_file.v` 的读映射（0x0505..0x050E / 0x0540..0x0549）。
"""

import argparse
import io
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uart_spi  # noqa: E402

BAUD_DEFAULT = uart_spi.BAUD_DEFAULT

# (地址, 名字, 是否累计型)
SNAPSHOT_REGS = [
    (0x05F2, "rtl_build_id", False),
    (0x0502, "calib_ctrl", False),
    (0x053A, "status_bits", False),
    (0x0505, "gl_1024_gt5.6deg", True),
    (0x0507, "gl_2048_gt11.25deg", True),
    (0x0509, "gl_4096_gt22.5deg", True),
    (0x050B, "gl_8192_gt45deg", True),
    (0x050D, "gl_hold_cnt", True),
    (0x0540, "cyc_pulse_cnt", True),
    (0x0542, "dbg_int_min", False),
    (0x0544, "dbg_int_max", False),
    (0x0546, "dbg_wcnt_cls", False),
    (0x0548, "dbg_nsamp_cls", False),
]

ACCUM = ["gl_1024_gt5.6deg", "gl_2048_gt11.25deg", "gl_4096_gt22.5deg",
         "gl_8192_gt45deg", "gl_hold_cnt", "cyc_pulse_cnt"]


def read_all(link, timeout, tries=3):
    """读一遍所有诊断寄存器；返回 {名字: 值 或 None}。"""
    out = {}
    for addr, name, _acc in SNAPSHOT_REGS:
        v = None
        for _ in range(tries):
            v, _raw = uart_spi._readback(link, addr, timeout)
            if v is not None:
                break
        out[name] = None if v is None else (v & 0xFFFF)
    return out


def fmt(v):
    return "----" if v is None else "%d" % v


def metrics(t0, t1, secs):
    """由两次读数算派生量。纯函数（无硬件）以便自检。"""
    m = {"secs": secs}

    def dv(name):
        a, b = t0.get(name), t1.get(name)
        if a is None or b is None:
            return None
        return (b - a) & 0xFFFF  # 16 位环绕，差值仍正确（差值远小于 65536）

    cyc = dv("cyc_pulse_cnt")
    m["d_cyc"] = cyc
    dens = {}
    for name in ACCUM:
        d = dv(name)
        m["d_" + name] = d
        if d is not None and cyc:
            dens[name] = d / float(cyc)
    m["density"] = dens
    if cyc is None or cyc == 0:
        m["per_sec"] = None
    else:
        m["per_sec"] = {k: v / secs for k, v in dens.items()} if secs > 0 else None
    imin, imax = t1.get("dbg_int_min"), t1.get("dbg_int_max")
    m["int_ratio"] = (imax / float(imin)) if (imin and imax) else None
    m["bid"] = t1.get("rtl_build_id")
    return m


def selftest():
    ok = True

    def chk(cond, name):
        nonlocal_ok = "PASS" if cond else "FAIL"
        print("  [%s] %s" % (nonlocal_ok, name))
        return cond

    t0 = {"gl_1024_gt5.6deg": 100, "gl_2048_gt11.25deg": 0, "gl_4096_gt22.5deg": 0,
          "gl_8192_gt45deg": 0, "gl_hold_cnt": 50, "cyc_pulse_cnt": 1000,
          "dbg_int_min": 400, "dbg_int_max": 500, "rtl_build_id": 7}
    t1 = dict(t0)
    t1.update({"gl_1024_gt5.6deg": 120, "gl_hold_cnt": 60, "cyc_pulse_cnt": 2000,
               "gl_2048_gt11.25deg": 0})
    m = metrics(t0, t1, 10.0)
    ok &= chk(m["d_cyc"] == 1000, "周期脉冲差值 = 1000")
    ok &= chk(m["d_gl_1024_gt5.6deg"] == 20, "毛刺差值 = 20")
    ok &= chk(abs(m["density"]["gl_1024_gt5.6deg"] - 0.02) < 1e-9, "密度 = 0.02 次/周期")
    ok &= chk(abs(m["per_sec"]["gl_1024_gt5.6deg"] - 0.002) < 1e-9, "每秒 = 0.002 次")
    ok &= chk(abs(m["int_ratio"] - 1.25) < 1e-9, "int_max/int_min = 1.25")
    ok &= chk(m["bid"] == 7, "build id 传递")
    # 16 位环绕：65530 -> 5 应得 11
    w0 = {"cyc_pulse_cnt": 65530, "gl_1024_gt5.6deg": 65530}
    w1 = {"cyc_pulse_cnt": 5, "gl_1024_gt5.6deg": 5}
    mw = metrics(w0, w1, 1.0)
    ok &= chk(mw["d_cyc"] == 11, "周期脉冲 16 位环绕差值 = 11")
    ok &= chk(abs(mw["density"]["gl_1024_gt5.6deg"] - 1.0) < 1e-9, "环绕后密度 = 1.0")
    # 除零保护
    mz = metrics({"cyc_pulse_cnt": 7}, {"cyc_pulse_cnt": 7}, 1.0)
    ok &= chk(mz["density"] == {} and mz["per_sec"] is None, "Δ周期脉冲 = 0 时不除零")
    # 缺读保护
    mn = metrics({"cyc_pulse_cnt": None}, {"cyc_pulse_cnt": 5}, 1.0)
    ok &= chk(mn["d_cyc"] is None, "寄存器缺读时返回 None")
    print("  自检 %s" % ("全部通过" if ok else "有失败"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="v6 诊断计数器两次求差读数")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=20.0, help="两次采样之间的间隔（秒）")
    ap.add_argument("--timeout", type=float, default=0.4)
    ap.add_argument("--csv", default=None, help="把两次原始读数写入 CSV")
    args = ap.parse_args(argv)

    ser = uart_spi.open_port(args.port, args.baud, timeout=0.2)
    link = uart_spi.Link(ser, args.baud)   # open_port 返回裸 Serial，收发要包成 Link
    try:
        print("=" * 78)
        print(" v6 诊断计数器：两次采样求差（端口 %s @ %d baud，间隔 %.1f s）"
              % (args.port, args.baud, args.seconds))
        print("=" * 78)
        t0 = read_all(link, args.timeout)
        if t0.get("rtl_build_id") is not None and t0["rtl_build_id"] < 6 and \
                t0["rtl_build_id"] == 0:
            print(" ★ 0x05F2 读回 0 => 板上是 v5 或更早的位流，本工具无诊断可读（请先烧 v6 或 v7）。")
        t_wall0 = time.time()
        time.sleep(args.seconds)
        t_wall1 = time.time()
        t1 = read_all(link, args.timeout)
        secs = t_wall1 - t_wall0

        print("%-20s %12s %12s %10s" % ("寄存器", "t0", "t1", "差值"))
        print("-" * 78)
        for addr, name, acc in SNAPSHOT_REGS:
            a, b = t0.get(name), t1.get(name)
            if acc:
                d = "----" if (a is None or b is None) else "%d" % ((b - a) & 0xFFFF)
            else:
                d = "(快照)"
            print("0x%04X %-12s %12s %12s %10s" % (addr, name, fmt(a), fmt(b), d))

        m = metrics(t0, t1, secs)
        print("-" * 78)
        print(" 采样间隔实测 %.1f s；Δ周期脉冲 = %s" % (secs, fmt(m["d_cyc"])))
        if m["density"]:
            print(" 毛刺密度（每输入周期发生次数，判定关键）：")
            for k in ACCUM:
                if k in m["density"]:
                    print("   %-20s %.5f 次/周期   （%.4f 次/秒）"
                          % (k, m["density"][k], m["per_sec"][k]))
            g1 = m["density"].get("gl_1024_gt5.6deg")
            g2 = m["density"].get("gl_2048_gt11.25deg")
            if g1 is not None and g2 is not None:
                if g1 == 0.0:
                    print(" 判读：连 >5.6° 的跳变都没有 => 当前激励下角度非常干净。")
                elif g2 == 0.0:
                    print(" 判读：>5.6° 有发生但 >11.25° 为 0 => 跳变幅度都在滞回之下（正是 v6 的防线区间）。")
                else:
                    print(" 判读：>11.25° 仍有发生 => 跳变足以翻动标定滞回，需看 >22.5°/>45° 分档。")
        else:
            print(" 毛刺密度：Δ周期脉冲 为 0 或缺读 => 无法换算（检查激励是否在转、串口是否正常）。")
        if m["int_ratio"] is not None:
            flag = "★ 超过 1.25 => 该窗口被判非整周期并作废重来" if m["int_ratio"] > 1.25 else "正常（<=1.25）"
            print(" 最近关门窗口：int_min=%s int_max=%s 比值=%.4f  %s"
                  % (fmt(t1.get("dbg_int_min")), fmt(t1.get("dbg_int_max")),
                     m["int_ratio"], flag))
            print("              wcnt=%s nsamp=%s（wcnt 应约等于 nsamp/int_mean，两者自洽说明窗口完整）"
                  % (fmt(t1.get("dbg_wcnt_cls")), fmt(t1.get("dbg_nsamp_cls"))))
        if all(t0.get(n) == t1.get(n) for n in
               ("dbg_int_min", "dbg_int_max", "dbg_wcnt_cls", "dbg_nsamp_cls")):
            print(" 注：窗口快照只在**标定关门时**更新，未标定时两次读数必然相同 ⇒ 不是寄存器卡死；")
            print("     要刷新它就先触发一次标定（写 0x0502 = 0x0001）。")
        if t1.get("rtl_build_id") is not None:
            print(" RTL_BUILD_ID(0x05F2) = %d%s"
                  % (t1["rtl_build_id"],
                     "   ← 早于 v6，诊断寄存器可能为 0" if t1["rtl_build_id"] < 6 else ""))

        if args.csv:
            with io.open(args.csv, "w", encoding="utf-8", newline="\n") as f:
                f.write("label,name,t0,t1,delta,accum\n")
                for addr, name, acc in SNAPSHOT_REGS:
                    a, b = t0.get(name), t1.get(name)
                    d = "" if (a is None or b is None or not acc) else str((b - a) & 0xFFFF)
                    f.write("0x%04X,%s,%s,%s,%s,%d\n"
                            % (addr, name, "" if a is None else a, "" if b is None else b,
                               d, 1 if acc else 0))
            print(" 两次原始读数已写入 %s" % args.csv)
        return 0
    finally:
        try:
            link.ser.close()  # Link 本身没有 close()，串口对象在 .ser 上
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
