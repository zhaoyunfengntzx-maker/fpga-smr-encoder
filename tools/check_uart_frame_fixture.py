#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_uart_frame_fixture.py —— UART 遥测帧"校验和约定"回归守卫
========================================================================

守的是什么
    rtl/uart_scope.v:219-224 的 l_chk **把两个帧头常量也异或进去**：
        chk = 0xAA ^ 0x55 ^ payload_xor   ( = payload_xor ^ 0xFF )
    而 tools/uart_scope.py 在 2026-10-10 之前只异或 payload(offset 2..16)，
    两边恒差 0xFF ⇒ **真机每一帧都会被上位机判成 crc_err、frames 恒为 0**，
    唯一的上板观测通道等于废掉；而 `--selftest` 因为自己组帧自己解析，
    照旧 PASS，发现不了这个偏差。
    定案（2026-10-10）：保留 RTL 约定，改主机端与文档（位流已按此实现并验证，
    为一条常量偏移改 RTL 会作废整个时序收敛结果）。

    帧布局 v2（RTL v12，2026-10-12 起）：
        off8..11 由 amp_sq[31:0] 改为 io_state / 0xA2 / io_flags / 0x00。
        0xA2 是布局判别字节：旧布局 off9 = amp_sq[23:16]，而 rtl/amp_monitor.v
        把 amp_sq 饱和在 2^31-1 ⇒ 该字节 ≤ 0x80，**不可能**撞到 0xA2。
        守卫里 F11* 钉住 v2 的字段/位序，F17 钉住"旧布局仍解析成 v1"。

怎么守
    用 sim/fixtures/uart_frame_rtl.hex —— 从 sim/tb_uart_scope.v 在 DUT 输出线
    上实拍下来的 18 字节（不是本工具自己组出来的）—— 做三件事：
      1) 用 tools/uart_scope.py 的 parse_stream 解析它，必须恰好 1 帧、0 校验错；
      2) 字段值必须与测试台激励常量逐一相等；
      3) 反事实检查：把末字节换回"纯 payload XOR"，解析必须 **失败**（0 帧 +
         crc_err>0）——这证明旧约定在真机上确实是坏的，而不是可有可无的风格差异。

用法
    python tools/check_uart_frame_fixture.py
    退出码 0 = 全部通过，1 = 有失败项。
"""

import argparse
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FIXTURE = os.path.join(ROOT, "sim", "fixtures", "uart_frame_rtl.hex")

# 与 sim/tb_uart_scope.v 的 [C] 段激励常量严格对应（改了测试台就要同步这里）
EXP_ANGLE = 0x1234
EXP_S = 0x0F0E
EXP_C = 0xF1F2
EXP_IO = 0x6D          # 帧布局 v2：off8 io_state（t_io）
EXP_TAG = 0xA2         # 帧布局 v2：off9 常量标记
EXP_FLAG = 0xA6        # 帧布局 v2：off10 io_flags（t_flag）
EXP_RESV = 0x00        # 帧布局 v2：off11 保留
EXP_POS = 0x01020304
EXP_STAT = 0x5A
# io_state 的位序（与 rtl/enc_top.v 的电平拼接顺序一致）
EXP_IO_BITS = ["a", "b", "z", "u", "v", "w", "dir", "limiter"]


def s16(v):
    """把 16bit 无符号数解释成有符号（parse_stream 回读的 s/c 是有符号）。"""
    return v - 0x10000 if v & 0x8000 else v


def load_uart_scope():
    """按路径加载 tools/uart_scope.py（它不在包里，只能按文件加载）。"""
    path = os.path.join(ROOT, "tools", "uart_scope.py")
    spec = importlib.util.spec_from_file_location("uart_scope_tool", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_fixture(path):
    """读十六进制 fixture，忽略 '#' 注释行与空行。返回 (bytes, 有效行号列表)。"""
    data = []
    for ln, raw in enumerate(open(path, "r", encoding="utf-8").read().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        for tok in line.split():
            data.append(int(tok, 16))
            if not 0 <= data[-1] <= 0xFF:
                raise ValueError("第 %d 行有超出 1 字节的十六进制数: %s" % (ln, tok))
    return bytes(bytearray(data)), None


def main():
    ap = argparse.ArgumentParser(description="UART 遥测帧校验和约定守卫")
    ap.add_argument("--fixture", default=DEFAULT_FIXTURE, help="实拍帧文件")
    args = ap.parse_args()

    checks = 0
    fails = []

    def ck(cond, name):
        nonlocal checks
        checks += 1
        if not cond:
            fails.append(name)
            print("  [FAIL] %s" % name)

    print("=" * 72)
    print(" UART 帧校验和约定守卫")
    print("=" * 72)
    print(" fixture : %s" % args.fixture)

    if not os.path.isfile(args.fixture):
        print("  [FAIL] fixture 不存在")
        print("\n TEST FAILED")
        return 1

    fr, _ = read_fixture(args.fixture)
    us = load_uart_scope()

    print(" 帧字节  : %s" % " ".join("%02x" % b for b in fr))
    payload = fr[2:17]
    pl_xor = us.xor_checksum(payload)
    want = us.frame_checksum(payload)
    print(" payload XOR(=off2..16) = 0x%02X ；含帧头常量应为 0x%02X ；实拍末字节 = 0x%02X"
          % (pl_xor, want, fr[17]))

    # ---- 1) 帧的静态形态
    ck(len(fr) == 18, "F1-帧长 18 字节（实际 %d）" % len(fr))
    ck(fr[0] == 0xAA and fr[1] == 0x55, "F2-帧头 0xAA 0x55")

    # ---- 2) 校验和约定本身（两条互相独立的断言）
    ck(fr[17] == want, "F3-实拍末字节 == 0xAA^0x55^payload XOR（RTL 约定）")
    ck(fr[17] != pl_xor, "F4-实拍末字节 != 纯 payload XOR（钉死 0xFF 偏移）")
    ck(us.frame_checksum(payload) == (pl_xor ^ 0xAA ^ 0x55),
       "F5-frame_checksum() 恒等于 payload_xor ^ 0xFF")

    # ---- 3) 工具能真解析出这一帧（这才是"上板时看得见数据"的判据）
    frames, stats = us.parse_stream(fr)
    ck(stats["frames"] == 1, "F6-parse_stream 解出 1 帧（实际 %d）" % stats["frames"])
    ck(stats["crc_err"] == 0, "F7-parse_stream 校验错为 0（实际 %d）" % stats["crc_err"])
    if frames:
        f0 = frames[0]
        ck(f0["angle"] == EXP_ANGLE, "F8-angle == 0x%04X" % EXP_ANGLE)
        ck(f0["s"] == s16(EXP_S), "F9-s == %d" % s16(EXP_S))
        ck(f0["c"] == s16(EXP_C), "F10-c == %d" % s16(EXP_C))
        # ---- 帧布局 v2 的 off8..11（v12 起取代 amp_sq[31:0]）
        ck(f0["layout"] == "v2", "F11-帧被识别为布局 v2")
        ck(f0["io_state"] == EXP_IO, "F11b-io_state == 0x%02X" % EXP_IO)
        ck(fr[8] == EXP_IO, "F11c-off8 原始字节 == io_state")
        ck(fr[9] == EXP_TAG, "F11d-off9 IO 帧标记 == 0x%02X" % EXP_TAG)
        ck(fr[10] == EXP_FLAG, "F11e-off10 原始字节 == io_flags")
        ck(fr[11] == EXP_RESV, "F11f-off11 保留字节 == 0x00")
        ck(f0["io_flags"] == EXP_FLAG, "F11g-io_flags == 0x%02X" % EXP_FLAG)
        ck([f0["io_bits"][n] for n in EXP_IO_BITS] ==
           [(EXP_IO >> k) & 1 for k in range(8)],
           "F11h-io_state 位序 bit0=a_out .. bit7=limiter_active")
        # amp_sq 不再上线，必须由 s/c 无损重算（与 rtl/amp_monitor.v 同式）
        ck(f0["amp_sq"] == ((s16(EXP_S) ** 2 + s16(EXP_C) ** 2) & 0xFFFFFFFF),
           "F11i-amp_sq 由 s²+c² 重算（不再在帧内）")
        ck(f0["pos_full"] == EXP_POS, "F12-pos_full == 0x%08X" % EXP_POS)
        ck(f0["stat"] == EXP_STAT, "F13-stat == 0x%02X" % EXP_STAT)
    else:
        ck(False, "F8..F13-字段值（无帧可查）")

    # ---- 4) 工具组帧必须逐字节复现实拍帧（工具 <-> RTL 字节级一致）
    rebuilt = us.build_frame(EXP_ANGLE, EXP_S, EXP_C, EXP_IO, EXP_FLAG, EXP_POS, EXP_STAT)
    ck(rebuilt == fr, "F14-build_frame 逐字节等于实拍帧（工具与 RTL 一致）")

    # ---- 5) 反事实：换回"只异或 payload"的旧约定，必须解析失败
    bad = bytearray(fr)
    bad[17] = pl_xor
    _, st2 = us.parse_stream(bytes(bad))
    ck(st2["frames"] == 0, "F15-旧约定(纯 payload XOR)下解出 0 帧（实际 %d）" % st2["frames"])
    ck(st2["crc_err"] > 0, "F16-旧约定下 crc_err > 0（实际 %d）" % st2["crc_err"])

    # ---- 6) 旧布局（v11 及以前）的帧必须仍被识别成 v1，且判别字节不会误判
    for amp in (0x00000000, 0x7FFFFFFF, 0xDEADBEEF):
        f1 = us.build_frame_v1(EXP_ANGLE, EXP_S, EXP_C, amp, EXP_POS, EXP_STAT)
        got, st1 = us.parse_stream(f1)
        ck(len(got) == 1 and got[0]["layout"] == "v1" and got[0]["amp_sq"] == amp
           and got[0]["io_state"] is None and st1["crc_err"] == 0,
           "F17-旧布局帧 (amp_sq=0x%08X) 仍解析为 v1" % amp)
        ck(f1[9] != EXP_TAG,
           "F18-旧布局 off9=0x%02X != 0xA2（amp_sq ≤ 2^31-1 ⇒ ≤ 0x80，判别无歧义）" % f1[9])

    print()
    if fails:
        print(" 失败项: %s" % ", ".join(fails))
        print(" TEST FAILED  (%d checks, %d failed)" % (checks, len(fails)))
        return 1
    print(" TEST PASSED  (%d checks)" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
