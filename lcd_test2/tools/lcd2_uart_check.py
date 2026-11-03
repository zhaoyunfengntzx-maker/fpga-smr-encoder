#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lcd_test2/tools/lcd2_uart_check.py -- 读取 lcd_test2 「屏幕+触摸测试程序」的 UART 遥测
（115200 8N1，FPGA 每秒发一帧，每帧 26 字节定长）。

协议 v3 帧格式（26 字节定长，小端无关，全部是裸字节）：
     0  0xA5            帧头 1
     1  0x4C            帧头 2（'L'）
     2  0x03            协议版本（必须是 3）
     3  id_bits         屏 ID：[7]=id_valid，[6:5]=0，[4:0]=型号 one-hot
                          bit4=ATK-1018(1280x800)  bit3=ATK-7084(800x480)
                          bit2=ATK-7016(1024x600)  bit1=ATK-4384(800x480)
                          bit0=ATK-4342(480x272)
     4  mode            0 = F1 标准色轮播；1 = F2/F3 触摸点位与实时反馈
                          ★ 2026-10-15 起 byte4..6 的空位被用来上报触摸状态机：
                          byte4 = {tstate[2:0], step[3:0], mode}
                          byte5 = {6'd0, m_busy, paused}
                          byte6 = {3'd0, m_state[2:0], tch_type[1:0]}
                          （tstate = touch_i2c_ctrl 的 state，step = 它的 step，
                            m_state/m_busy = i2c_master_seq 的 state/busy。
                            这套位专为定位"触摸后读取停摆"加的，正常读数：
                            tstate=0(IDLE) step=8(POLL)，偶发 step=3(LOOP)/10(LOOP4)。）
     5  paused          1 = 长按暂停中
     6  tch_type        0 = 未识别；1 = GT911；2 = FT5206
     7  tch_valid       1 = 触摸芯片已锁定
     8  points          当前触摸点数 0..5
     9  status          触摸状态寄存器原始字节（GT911 是 0x814E：bit7=有数据，低 4 位=点数）
    10  color_idx       当前标准色序号 0..7（0 白 1 黑 2 红 3 绿 4 蓝 5 青 6 品红 7 黄）
    11  frame[23:16]    帧计数（24 位，大端：11 是高字节）
    12  frame[15:8]
    13  frame[7:0]
    14  x0_hi  15 x0_lo   第 1 点 X（16 位大端）
    16  y0_hi  17 y0_lo   第 1 点 Y
    18  x1_hi  19 x1_lo   第 2 点 X
    20  y1_hi  21 y1_lo   第 2 点 Y
    22  reads_ps_hi  23 reads_ps_lo  本秒内 IIC 轮询次数（16 位大端）
    24  err_ps_hi    25 err_ps_lo    本秒内 IIC 错误次数（16 位大端）

用法（★ 本机要用 E:\\Anaconda\\python.exe 运行 —— 只有它装了 pyserial，
内置的 Python 没有 pyserial，直接跑会以退出码 4 报错）：
    E:\\Anaconda\\python.exe lcd_test2/tools/lcd2_uart_check.py --port COM3 --seconds 8
    E:\\Anaconda\\python.exe lcd_test2/tools/lcd2_uart_check.py --port COM3 --seconds 20 --quiet

退出码：0 = PASS；2 = 一帧都没收到（或串口打不开）；3 = 收到帧但内容异常；
        4 = 没有 pyserial（请换 E:\\Anaconda\\python.exe）。
判定说明：触摸点数为 0 不算失败 —— 没人碰屏时本来就该是 0，只在汇总里写出来。
控制台是 GBK 代码页，所以所有打印都用英文，避免乱码。
只用 pyserial，无其它依赖。
"""

import argparse
import sys
import time
from collections import Counter

try:
    import serial
except ImportError:
    print("ERROR: pyserial not available to this Python interpreter")
    print("       This host's built-in Python has no pyserial.")
    print("       Run with E:\\Anaconda\\python.exe (the only one with pyserial installed):")
    print("         E:\\Anaconda\\python.exe lcd_test2\\tools\\lcd2_uart_check.py --port COM3")
    sys.exit(4)

FRAME_LEN = 26
HEAD0 = 0xA5
HEAD1 = 0x4C
PROTO_VER = 3

# bit4..bit0 one-hot -> 屏型号（空字符串 = 没有命中）
PANEL_BY_BIT = {
    4: "ATK-1018 10.1\" 1280x800",
    3: "ATK-7084 7\"   800x480",
    2: "ATK-7016 7\"   1024x600",
    1: "ATK-4384 4.3\" 800x480",
    0: "ATK-4342 4.3\" 480x272",
}
TCH_TYPE = {0: "none(probing?)", 1: "GT911", 2: "FT5206"}

# ★ 遥测里塞进来的触摸状态机字段名（见文件头 byte4..6 说明）
TSTATE = {0: "IDLE", 1: "REQ", 2: "WAIT", 3: "END", 4: "HOLD"}
TSTEP = {
    0: "GT_PB", 1: "FT_PB", 2: "FT_PB2", 3: "LOOP", 4: "FT_RD", 5: "CLR",
    6: "GT_ID", 7: "GT_INFO", 8: "POLL", 9: "CFG", 10: "LOOP4",
}
MSTATE = {
    0: "IDLE", 1: "START", 2: "SEND_ADDR", 3: "ACK_ADDR", 4: "SEND_TX",
    5: "ACK_TX", 6: "RX", 7: "ACK_RX", 8: "STOP", 9: "END", 10: "RECOVER",
}


def st_name(table, value):
    return table.get(value, "?%d" % value)


def panel_name(id_bits):
    """id_bits -> 型号字符串；id_valid=0 或没有 one-hot 命中时 -> None。"""
    if ((id_bits >> 7) & 1) == 0:
        return None
    for bit in (4, 3, 2, 1, 0):
        if (id_bits >> bit) & 1:
            return PANEL_BY_BIT[bit]
    return None


def decode(f):
    """26 字节裸帧 -> dict（不做合法性判断，判断在 report 里）。"""
    idb = f[3]
    return {
        "ver": f[2],
        "id_valid": (idb >> 7) & 1,
        "raw_id_bits": idb,
        "id_bits": idb & 0x1F,
        "panel": panel_name(idb),
        "mode": f[4] & 0x01,
        "step": (f[4] >> 1) & 0x0F,
        "tstate": (f[4] >> 5) & 0x07,
        "paused": f[5] & 0x01,
        "m_busy": (f[5] >> 1) & 0x01,
        "tch_type": f[6] & 0x03,
        "m_state": (f[6] >> 2) & 0x0F,
        "tch_valid": f[7] & 0x01,
        "tch_num": f[8],
        "status_raw": f[9],
        "status_ready": (f[9] >> 7) & 1,
        "status_points": f[9] & 0x0F,
        "color_idx": f[10],
        "frame_cnt": (f[11] << 16) | (f[12] << 8) | f[13],
        "x0": (f[14] << 8) | f[15],
        "y0": (f[16] << 8) | f[17],
        "x1": (f[18] << 8) | f[19],
        "y1": (f[20] << 8) | f[21],
        "reads_ps": (f[22] << 8) | f[23],
        "err_ps": (f[24] << 8) | f[25],
    }


def report(d, expect_panel=None):
    """打印一帧的可读文本，返回该帧是否 PASS（触摸点为 0 不算失败）。"""
    fails = []
    print("---- frame ----")
    print("  version        : %d %s" % (d["ver"], "" if d["ver"] == PROTO_VER else "<-- expect 3"))
    if d["ver"] != PROTO_VER:
        fails.append("version != 3")
    print("  panel id valid : %d %s" % (d["id_valid"], "" if d["id_valid"] else "<-- id_valid=0"))
    if not d["id_valid"]:
        fails.append("id_valid == 0")
    print("  panel id bits  : 0x%02X (one-hot 0x%02X)" % (d["raw_id_bits"], d["id_bits"]))
    print("  panel          : %s" % (d["panel"] if d["panel"] else "None"))
    if d["panel"] is None:
        fails.append("panel is None (no one-hot bit matched)")
    if expect_panel and d["panel"] != expect_panel:
        print("                   <-- expect %s" % expect_panel)
        fails.append("panel != expect-panel")
    print("  mode           : %d" % d["mode"])
    print("  paused         : %d%s" % (d["paused"], "  (long-press pause active)" if d["paused"] else ""))
    print("  touch type     : %d (%s)" % (d["tch_type"], TCH_TYPE.get(d["tch_type"], "?")))
    print("  touch valid    : %d" % d["tch_valid"])
    # ★ 诊断字段：卡死时看这一行 —— WAIT + m_state 停在某个发送/接收相位 =
    #   IIC 主机卡在相位里；IDLE + POLL 但 reads 掉了 = 别的问题。
    print("  touch fsm      : tstate=%s(%d) step=%s(%d)  iic: m_state=%s(%d) busy=%d"
          % (st_name(TSTATE, d["tstate"]), d["tstate"],
             st_name(TSTEP, d["step"]), d["step"],
             st_name(MSTATE, d["m_state"]), d["m_state"], d["m_busy"]))
    print("  touch points   : %d%s" % (d["tch_num"], "  (no finger on screen - not a failure)" if d["tch_num"] == 0 else ""))
    print("  status 0x814E  : 0x%02X (ready=%d, points=%d)" % (d["status_raw"], d["status_ready"], d["status_points"]))
    print("  color idx      : %d" % d["color_idx"])
    print("  frame cnt      : %d" % d["frame_cnt"])
    print("  point0 x,y     : %d, %d" % (d["x0"], d["y0"]))
    print("  point1 x,y     : %d, %d" % (d["x1"], d["y1"]))
    print("  reads per sec  : %d %s" % (d["reads_ps"], "" if d["reads_ps"] else "<-- no IIC read completed in that second"))
    if d["reads_ps"] == 0:
        fails.append("reads_ps == 0")
    print("  errors per sec : %d %s" % (d["err_ps"], "" if d["err_ps"] == 0 else "<-- IIC NACK/timeout"))
    if d["err_ps"] != 0:
        fails.append("err_ps != 0")
    if fails:
        print("  frame verdict  : FAIL - %s" % "; ".join(fails))
    return not fails


def summarize(decoded, expect_panel=None):
    """汇总整个窗口；返回 (ok, reason)。"""
    total = len(decoded)
    touched = [d for d in decoded if d["tch_num"] > 0]

    print("==== window summary ====")
    print("  frames               : %d" % total)
    print("  frames with points>0 : %d / %d" % (len(touched), total))
    if touched:
        print("  (screen was touched in %d of %d frames)" % (len(touched), total))
    else:
        print("  (no touch point at all in this window - EXPECTED when nobody")
        print("   touches the screen; touch points == 0 is NOT a failure)")

    coords = Counter(((d["x0"], d["y0"]) for d in decoded))
    print("  distinct (x0,y0)     : %d" % len(coords))
    for (x, y), c in coords.most_common(10):
        print("    (x0=%4d, y0=%4d) x%d" % (x, y, c))

    modes = sorted(set(d["mode"] for d in decoded))
    print("  modes seen           : %s (%d kind%s)" % (modes, len(modes), "" if len(modes) == 1 else "s"))
    paused_seen = [d["paused"] for d in decoded]
    if any(paused_seen):
        print("  paused seen          : YES (%d / %d frames)" % (sum(1 for p in paused_seen if p), total))
    else:
        print("  paused seen          : NO")
    tch_types = sorted(set(d["tch_type"] for d in decoded))
    print("  touch types seen     : %s" % tch_types)

    # ★ 触摸状态机分布：卡死时这里会齐刷刷一行（例如 tstate=WAIT + m_busy=1）。
    fsm = Counter((d["tstate"], d["step"], d["m_state"], d["m_busy"]) for d in decoded)
    print("  touch fsm states     :")
    for (ts, st, ms, bz), c in fsm.most_common(8):
        print("    tstate=%-5s step=%-7s m_state=%-9s busy=%d  x%d"
              % (st_name(TSTATE, ts), st_name(TSTEP, st), st_name(MSTATE, ms), bz, c))
    panels = Counter((d["panel"] if d["panel"] else "None") for d in decoded)
    print("  panels seen          : %s" % dict(panels))
    if expect_panel:
        print("  expect panel         : %s" % expect_panel)

    union = []
    for d in decoded:
        if d["ver"] != PROTO_VER:
            union.append("version != 3")
        if not d["id_valid"]:
            union.append("id_valid == 0")
        if d["panel"] is None:
            union.append("panel is None")
        if expect_panel and d["panel"] != expect_panel:
            union.append("panel != expect-panel")
        if d["err_ps"] != 0:
            union.append("err_ps != 0")
        if d["reads_ps"] == 0:
            union.append("reads_ps == 0")
    if union:
        counts = Counter(union)
        print("  failures seen        : %s" % dict(counts))
        return False, "; ".join("%s x%d" % (k, v) for k, v in counts.most_common())
    return True, ""


def main():
    ap = argparse.ArgumentParser(
        description="Read and decode the protocol v3 UART telemetry (26-byte frames) "
                    "of the lcd_test2 screen+touch test program.")
    ap.add_argument("--port", default="COM3", help="serial port (default: COM3)")
    ap.add_argument("--baud", type=int, default=115200, help="baud rate (default: 115200)")
    ap.add_argument("--seconds", type=float, default=8.0, help="read window in seconds (default: 8)")
    ap.add_argument("--quiet", action="store_true",
                    help="only print the last frame plus the summary/verdict")
    ap.add_argument("--expect-panel", default="ATK-7016 7\"   1024x600",
                    help="expected panel name string (default: ATK-7016 7\"   1024x600)")
    args = ap.parse_args()

    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except Exception as e:
        print("ERROR: cannot open %s @ %d: %s" % (args.port, args.baud, e))
        print("       (port busy? close vofa / serial assistant / host GUI first)")
        return 2

    print("reading %s @ %d 8N1 for %.1f s (protocol v3, 26-byte frames) ..."
          % (args.port, args.baud, args.seconds))
    raw = bytearray()
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        chunk = ser.read(256)
        if chunk:
            raw.extend(chunk)
    ser.close()

    # 按帧头 0xA5 0x4C 重新同步，攒够 26 字节算一帧
    frames = []
    bad_frames = 0
    i = 0
    n = len(raw)
    while i + FRAME_LEN <= n:
        if raw[i] == HEAD0 and raw[i + 1] == HEAD1:
            cand = bytes(raw[i:i + FRAME_LEN])
            if cand[2] == PROTO_VER:
                frames.append(cand)
            else:
                bad_frames += 1
            i += FRAME_LEN
        else:
            i += 1

    print("bytes=%d  frames=%d  bad_frames=%d  (expect about %.0f frames)"
          % (n, len(frames), bad_frames, args.seconds))
    if not frames:
        print("RESULT: FAIL - no valid v3 frame received")
        print("         check: TX wiring, baud 115200, bitstream loaded, frame header 0xA5 0x4C, version 3")
        return 2

    decoded = [decode(f) for f in frames]

    # --quiet：只打印最后一帧 + 汇总；否则先打印前 4 帧，再单独打印最后一帧作为定论依据
    # （帧数 <= 4 时最后一帧已经在上面打印过，不再重复）
    if args.quiet:
        print("==== last frame ====")
        report(decoded[-1], args.expect_panel)
    else:
        shown = min(4, len(decoded))
        for d in decoded[:shown]:
            report(d, args.expect_panel)
        if len(decoded) > shown:
            print("... (%d more frames not printed; --quiet prints only the last one)"
                  % (len(decoded) - shown))
            print("==== last frame ====")
            report(decoded[-1], args.expect_panel)

    ok, reason = summarize(decoded, args.expect_panel)

    if ok:
        print("RESULT: PASS")
    else:
        print("RESULT: FAIL - %s" % reason)
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main())
