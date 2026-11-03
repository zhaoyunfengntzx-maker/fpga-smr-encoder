# -*- coding: utf-8 -*-
"""Dump output-enable registers using the project's proven host/link.py."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))

import link as lk  # noqa: E402

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 6

REGS = [
    (0x0100, "UVW_CFG"),
    (0x0101, "INTER0"),
    (0x0102, "INTER1"),
    (0x0106, "ABLIMIT"),
    (0x0109, "OUTPUT"),
    (0x0130, "LOCK"),
    (0x0404, "STAT_VAL"),
    (0x0405, "STAT_LATCH"),
    (0x053A, "STAT_FLAGS"),
]


def main():
    w = lk.SerialWorker(PORT, baud=lk.BAUD_DEFAULT)
    w.start()
    time.sleep(0.8)
    for n in range(N):
        parts = []
        for addr, _name in REGS:
            d = w.read_reg(addr)
            v = d.get("value") if isinstance(d, dict) else d
            parts.append("%04X=%s" % (addr, "----" if v is None else "%04X" % (v & 0xFFFF)))
        print("[%2d] %s" % (n, "  ".join(parts)))
        time.sleep(0.3)
    w.stop()


if __name__ == "__main__":
    main()
