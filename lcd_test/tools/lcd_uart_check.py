#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lcd_test/tools/lcd_uart_check.py -- 读取 LCD 测试程序的 UART 遥测（115200 8N1）。

协议（lcd_rgb_test_top.v 的 uart_frame_sender，每秒 1 帧、每帧 16 字节）：
    b0  = 0xA5  同步头
    b1  = 0x4C  'L'
    b2  = 0x02  协议版本（v1 的 b12..b15 是每秒 IIC 读次数/错误数，脚本按版本号解释）
    b3  = {id_valid, 2'b00, (id==101), (id==001), (id==010), (id==100), (id==000)}
    b4  = {1'b0, int_pin, sda_line, scl_line, pattern}
          [6]=触摸 INT 线电平 [5]=SDA 空闲电平 [4]=SCL 空闲电平 [3:0]=画面号
    b5  = {tch_valid, 5'd0, tch_type}      tch_type: 0=未锁定 1=GT911 2=FT5x06
    b6  = 0x814E 原始状态字节：bit7=坐标就绪、bit[3:0]=点数
    b7  = GT911 产品 ID 首字节（寄存器 0x8140，真片应读 0x39='9'；0x00 说明没读到）
    b8  = x0[15:8]      b9  = x0[7:0]
    b10 = y0[15:8]      b11 = y0[7:0]
    b12 = gt_xmax[15:8] b13 = gt_xmax[7:0]  GT911 寄存器 0x8146：芯片里配的 X 分辨率
    b14 = gt_ymax[15:8] b15 = gt_ymax[7:0]  寄存器 0x8148：Y 分辨率（7 寸屏应读 1024/600）

用法：
    python lcd_test/tools/lcd_uart_check.py --port COM3 --seconds 6
    python lcd_test/tools/lcd_uart_check.py --port COM3 --seconds 20 --quiet
退出码：0 = 收到的帧都合法；2 = 一帧都没收到；3 = 有帧但内容异常。
只用 pyserial，无其它依赖。
"""

import argparse
import sys
import time
from collections import Counter

try:
    import serial
except ImportError:
    print("ERROR: pyserial not available (pip install pyserial)")
    sys.exit(4)

PANEL = {
    0b000: "ATK-4342 4.3\" 480x272",
    0b100: "ATK-4384 4.3\" 800x480",
    0b010: "ATK-7016 7\"   1024x600",
    0b001: "ATK-7084 7\"   800x480",
    0b101: "ATK-1018 10.1\" 1280x800",
}
TCH_TYPE = {0: "none(probing?)", 1: "GT911", 2: "FT5x06"}


def decode(f):
    idb = f[3]
    ver = f[2]
    d = {
        "ver": ver,
        "id_valid": (idb >> 7) & 1,
        "panel": None,
        "raw_id_bits": idb,
        "pattern": f[4] & 0x0F,
        "int_pin": (f[4] >> 6) & 1,
        "sda_line": (f[4] >> 5) & 1,
        "scl_line": (f[4] >> 4) & 1,
        "tch_valid": (f[5] >> 7) & 1,
        "tch_type": f[5] & 0x03,
        "status_raw": f[6],
        "tch_num": f[6] & 0x07,
        "ready": (f[6] >> 7) & 1,
        "prod_id": f[7],
        "x0": (f[8] << 8) | f[9],
        "y0": (f[10] << 8) | f[11],
    }
    if ver >= 2:
        d["xmax"] = (f[12] << 8) | f[13]
        d["ymax"] = (f[14] << 8) | f[15]
    else:
        d["reads_ps"] = (f[12] << 8) | f[13]
        d["err_ps"] = (f[14] << 8) | f[15]
    for code, name in PANEL.items():
        if (idb >> (0 if code == 0b000 else {0b100: 1, 0b010: 2, 0b001: 3, 0b101: 4}[code])) & 1:
            d["panel"] = name
            break
    return d


def report(d, expect_panel=None):
    ok = True
    print("---- frame ----")
    print("  version        : %d %s" % (d["ver"], "" if d["ver"] in (1, 2) else "<-- unknown"))
    if d["ver"] not in (1, 2):
        ok = False
    print("  panel id valid : %d" % d["id_valid"])
    print("  panel id bits  : 0x%02X" % d["raw_id_bits"])
    print("  panel          : %s" % (d["panel"] or "UNKNOWN (bit0..bit4 all 0)"))
    if not d["id_valid"] or d["panel"] is None:
        ok = False
    if expect_panel and d["panel"] != expect_panel:
        print("                   <-- expect %s" % expect_panel)
        ok = False
    print("  pattern        : %d" % d["pattern"])
    print("  touch valid    : %d" % d["tch_valid"])
    print("  touch type     : %d (%s)" % (d["tch_type"], TCH_TYPE.get(d["tch_type"], "?")))
    print("  touch points   : %d" % d["tch_num"])
    print("  GT911 prod id  : 0x%02X %s" % (d["prod_id"],
          "(='9' 真片)" if d["prod_id"] == 0x39 else "(读不到 => 器件没应答/指针没生效)"))
    print("  0x814E status  : 0x%02X  (ready=%d, points=%d)" % (d["status_raw"], d["ready"], d["tch_num"]))
    print("  IIC 空闲电平   : sda=%d scl=%d %s" % (d["sda_line"], d["scl_line"],
          "" if (d["sda_line"] and d["scl_line"]) else "<-- 拉低说明总线被占/被拉死"))
    print("  触摸 INT 电平  : %d %s" % (d["int_pin"],
          "" if d["int_pin"] else "<-- 恒为 0：INT 被压住或模块没上拉，芯片无法报数据就绪"))
    print("  point0 x,y     : %d, %d" % (d["x0"], d["y0"]))
    if d["ver"] >= 2:
        print("  GT911 分辨率   : X=%d Y=%d %s" % (d["xmax"], d["ymax"],
              "" if (d["xmax"] and d["ymax"]) else "<-- 读到 0：芯片配置没加载/固件没跑"))
    else:
        print("  reads/sec      : %d" % d["reads_ps"])
        print("  errors/sec     : %d %s" % (d["err_ps"], "" if d["err_ps"] == 0 else "<-- NACK/timeout"))
        if d["err_ps"] != 0:
            ok = False
        if d["reads_ps"] == 0:
            print("                   <-- WARNING: no IIC read completed in that second")
            ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--expect-panel", default="ATK-7016 7\"   1024x600")
    ap.add_argument("--quiet", action="store_true", help="只打印汇总")
    args = ap.parse_args()

    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except Exception as e:
        print("ERROR: cannot open %s @ %d: %s" % (args.port, args.baud, e))
        print("       (串口被别的程序占着？vofa / 串口助手 / host GUI 都要先关)")
        return 2

    print("reading %s @ %d baud for %.1f s ..." % (args.port, args.baud, args.seconds))
    frames = []
    raw = bytearray()
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        chunk = ser.read(256)
        if chunk:
            raw.extend(chunk)
    ser.close()

    i = 0
    n = len(raw)
    while i + 16 <= n:
        if raw[i] == 0xA5 and raw[i + 1] == 0x4C:
            frames.append(bytes(raw[i:i + 16]))
            i += 16
        else:
            i += 1

    print("bytes=%d  frames=%d  (expect about %.0f)" % (n, len(frames), args.seconds))
    if not frames:
        print("RESULT: FAIL - no valid frame (check wiring TX=W21, baud 115200, bitstream loaded)")
        return 2

    if not args.quiet:
        for f in frames[:4]:
            report(decode(f), args.expect_panel)
        if len(frames) > 4:
            print("... (%d more frames)" % (len(frames) - 4))

    d = decode(frames[-1])
    print("==== last frame ====")
    ok = report(d, args.expect_panel)

    coords = Counter(((decode(f)["x0"], decode(f)["y0"]) for f in frames))
    print("==== distinct (x0,y0) over the window ====")
    for (x, y), c in coords.most_common(8):
        print("  (%4d,%4d) x%d" % (x, y, c))

    # 触摸汇总：没触摸时 tch_num=0、坐标=0 是正常的，所以单独统计，
    # 并给出"这一秒到底有没有读到触摸点"。
    dec = [decode(f) for f in frames]
    touched = [d for d in dec if d["tch_num"] > 0]
    print("==== touch summary ====")
    print("  frames with points>0 : %d / %d" % (len(touched), len(dec)))
    if touched:
        pts = Counter(((d["x0"], d["y0"]) for d in touched))
        for (x, y), c in pts.most_common(10):
            print("  point (x=%4d, y=%4d) x%d" % (x, y, c))
    else:
        print("  (整段窗口没有读到任何触摸点 —— 没碰屏时这是正常的)")

    print("RESULT: %s" % ("PASS" if ok else "FAIL - see <-- marks above"))
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main())
