#!/usr/bin/env python3
"""读串口打印的 DDR3 自检结果（115200 8N1）。

用法：
    python tools/ddr3_dbg_uart.py            # 默认 COM3
    python tools/ddr3_dbg_uart.py COM5

板子上跑 ddr3_top_mem（带 uart 调试输出的位流）后，会每秒循环打印：
    ERR=00000000 GOT=00100000 IDX=00000000 EXP=5A5A0000 GTD=00000000
  ERR = 比对错点数（0 = 全对）
  GOT = 实际回读到多少点（应为 00100000 = 1048576）
  IDX/EXP/GTD = 第一个错点的序号 / 期望值 / 实际值
"""
import sys
import time

import serial


def main() -> int:
    port = sys.argv[1] if len(sys.argv) > 1 else "COM3"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    try:
        ser = serial.Serial(port, 115200, timeout=1.0)
        # ★ DTR/RTS 必须显式拉低：这块板子的 CH340 DTR 会在打开端口时
        #   被驱动成有效电平，FPGA 侧被按住，串口一个字节都收不到
        #   （现象：端口能打开、读 10 s 全 0 字节）。
        ser.dtr = False
        ser.rts = False
    except Exception as exc:                     # noqa: BLE001
        print(f"打不开 {port}: {exc}")
        return 1
    print(f"监听 {port} @115200 ，Ctrl+C 停止")
    t0 = time.time()
    got = 0
    try:
        while True:
            if secs and time.time() - t0 > secs:
                break
            raw = ser.readline()
            if not raw:
                continue
            line = raw.decode("ascii", errors="replace").strip()
            if line:
                got += 1
                print(f"[{time.strftime('%H:%M:%S')}] {line}")
    except KeyboardInterrupt:
        pass
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
