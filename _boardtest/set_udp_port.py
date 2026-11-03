# -*- coding: utf-8 -*-
"""设置板上 UDP 端口寄存器 0x070C 并回读。

用法： python _boardtest/set_udp_port.py COM7 5010
"""
import sys
import time

sys.path.insert(0, "host")
import link as lk  # noqa: E402

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
val = int(sys.argv[2]) if len(sys.argv) > 2 else 5010

w = lk.SerialWorker(port)
w.start()
time.sleep(0.4)
try:
    r = w.write_reg(0x070C, val)
    print("write 0x070C <- %d : %s" % (val, r))
    time.sleep(0.1)
    d = w.read_reg(0x070C)
    print("read  0x070C = %s" % (d,))
finally:
    try:
        w.stop()
    except Exception:
        pass
