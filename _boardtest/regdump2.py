# -*- coding: utf-8 -*-
"""Dump the registers that decide whether ABZ/UVW outputs are enabled."""
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 8

REGS = [
    (0x0100, "UVW_CFG   [4:0]pairs"),
    (0x0101, "INTER0"),
    (0x0102, "INTER1"),
    (0x0106, "ABLIMIT"),
    (0x0109, "OUTPUT    b6=abzen b7=uwven"),
    (0x0130, "LOCK_STATE"),
    (0x0404, "STAT_VAL"),
    (0x0405, "STAT_LATCH"),
    (0x053A, "STAT_FLAGS"),
]


def xor_ok(b):
    x = 0
    for v in b:
        x ^= v
    return x == 0


def read_reg(s, addr):
    cmd = [0x5A, 0x01, addr & 0xFF, addr >> 8]
    x = 0
    for v in cmd:
        x ^= v
    cmd.append(x)
    s.reset_input_buffer()
    s.write(bytes(cmd))
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < 0.3:
        buf += s.read(64)
        for i in range(max(0, len(buf) - 6) + 1):
            f = buf[i:i + 6]
            if len(f) == 6 and f[0] == 0x5A and xor_ok(f):
                return ((f[4] << 8) | f[5]) & 0xFFFF
    return None


def main():
    s = serial.Serial(PORT, 2000000, timeout=0.05)
    time.sleep(0.2)
    for n in range(N):
        row = []
        for addr, name in REGS:
            v = read_reg(s, addr)
            row.append((addr, v))
        line = "  ".join(
            "%04X=%s" % (a, "----" if v is None else "%04X" % v) for a, v in row)
        print("[%2d] %s" % (n, line))
        time.sleep(0.25)
    s.close()


if __name__ == "__main__":
    main()
