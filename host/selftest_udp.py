# -*- coding: utf-8 -*-
"""host/selftest_udp.py —— 以太网抓包通道（host/udp_capture.py）的自检

为什么单独测：
    UDP 通道的失败模式全是"静默"的 —— 包丢了不报错、包乱序不报错、
    收到别的程序的包也可能被当成样点。所以必须用真实 socket 在
    回环上发一遍，逐个断言：归位、缺包标记、魔数校验、超时报错。

跑法（不需要板子、不需要网线）：
    python host/selftest_udp.py
"""

import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import capture as cap          # noqa: E402
import udp_capture as ucap     # noqa: E402

CHECKS = [0]
ERRORS = [0]


def chk(cond, name):
    CHECKS[0] += 1
    if not cond:
        ERRORS[0] += 1
        print("  [FAIL] %s" % name)


def chk_eq(got, exp, name):
    CHECKS[0] += 1
    if got != exp:
        ERRORS[0] += 1
        print("  [FAIL] %s: got %r exp %r" % (name, got, exp))


def make_pkt(seq, first, samples, dec=1, last=False):
    """按 rtl/eth/scope_udp.v 的格式造一个包。"""
    # ★ 线上是"先 E7 再 5A"（rtl/eth/scope_udp.v 逐字节发），
    #   不能用 pack("<H", 0xE75A) —— 那样发出来是 5A E7，真机全丢。
    hdr = (b"\xE7\x5A"
           + struct.pack("<BBHI", 1 if last else 0, dec, seq, first)
           + b"\x00" * 6)
    body = b"".join(struct.pack("<hh", s, c) for s, c in samples)
    return hdr + body


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def send_packets(port, pkts, delay=0.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for p in pkts:
        if delay:
            time.sleep(delay)
        s.sendto(p, ("127.0.0.1", port))
    s.close()


class FakeWorker(object):
    """假串口：配置寄存器一律成功；写 0x0736 时让另一个线程开始推 UDP。"""

    def __init__(self, port, packets, length):
        self.port = port
        self.packets = packets
        self.length = length
        self.written = []

    def capture_configure(self, src, dec_log2, length, trig, level, pre):
        chk_eq(length, self.length, "configure length")
        return True, ""

    def capture_wait_done(self, timeout, poll_s=0.005):
        # 与真 SerialWorker 的返回类型一致：状态 dict（不是 True）
        return {"done": True, "armed": False, "trig": True, "busy": False,
                "ovf": False}

    def capture_status(self):
        return {"done": True, "armed": False, "trig": True, "busy": False,
                "ovf": False}

    def read_reg(self, addr, *a, **kw):
        table = {0x0726: 100, 0x0732: self.length, 0x0728: 12345}
        return {"value": table.get(addr, 0), "lo": 0, "hi": 0, "raw": b""}

    def write_reg(self, addr, value, verify=True, **kw):
        self.written.append((addr, value))
        if addr == 0x0736 and (value & 1):
            t = threading.Thread(target=send_packets,
                                 args=(self.port, self.packets, 0.001))
            t.daemon = True
            t.start()
        return True


def main():
    print("[A] parse_packet：格式与校验")
    s = [(1, -2), (3, -4)]
    pkt = make_pkt(7, 40, s, dec=2, last=True)
    seq, first, dec, last, ss, cc = ucap.UdpCapture.parse_packet(pkt)
    chk_eq(seq, 7, "seq")
    chk_eq(first, 40, "first")
    chk_eq(dec, 2, "dec")
    chk_eq(last, True, "last")
    chk_eq(ss, [1, 3], "s samples")
    chk_eq(cc, [-2, -4], "c samples")

    try:
        ucap.UdpCapture.parse_packet(struct.pack("<HBBHI", 0x1234, 0, 0, 0, 0)
                                     + b"\x00" * 10)
        chk(False, "bad magic should raise")
    except ucap.UdpCaptureError:
        chk(True, "bad magic raises")

    try:
        ucap.UdpCapture.parse_packet(b"\x5A\xE7\x00")
        chk(False, "short packet should raise")
    except ucap.UdpCaptureError:
        chk(True, "short packet raises")

    print("[B] receive：按 seq 归位")
    port = free_port()
    pkts = [make_pkt(i, i * 8, [(i * 8 + k, 100 + i * 8 + k) for k in range(8)])
            for i in range(3)]
    uc = ucap.UdpCapture(port=port, bind_ip="127.0.0.1", timeout_s=2.0)
    uc.open()
    send_packets(port, pkts)
    res = uc.receive(expect_pts=24)
    chk_eq(len(res["s"]), 24, "24 samples")
    chk_eq(res["s"][:3], [0, 1, 2], "order s")
    chk_eq(res["c"][:3], [100, 101, 102], "order c")
    chk_eq(res["missing"], [], "no missing")
    uc.close()

    print("[C] receive：丢一个包要标出来")
    port = free_port()
    uc = ucap.UdpCapture(port=port, bind_ip="127.0.0.1", timeout_s=2.0)
    uc.open()
    uc.timeout_s = 0.6
    send_packets(port, [pkts[0], pkts[2]])
    res = uc.receive(expect_pts=24)
    chk_eq(res["missing"], [1], "missing seq 1")
    chk_eq(len(res["s"]), 24, "gap filled with 8 zeros")
    chk_eq(res["s"][8:16], [0] * 8, "gap is zeros")
    uc.close()

    print("[D] receive：一个包都收不到要报错")
    port = free_port()
    uc = ucap.UdpCapture(port=port, bind_ip="127.0.0.1", timeout_s=0.3)
    try:
        uc.receive(expect_pts=8)
        chk(False, "no packet should raise")
    except ucap.UdpCaptureError as e:
        chk("没收到" in str(e), "no packet raises with hint")
    uc.close()

    print("[E] capture_once：端到端（假串口 + 回环 UDP）")
    length = 24
    port = free_port()
    pkts = [make_pkt(i, i * 8, [(i * 8 + k, 500 + i * 8 + k) for k in range(8)],
                     dec=1, last=(i == 2)) for i in range(3)]
    wk = FakeWorker(port, pkts, length)
    uc = ucap.UdpCapture(port=port, bind_ip="127.0.0.1", timeout_s=2.0)
    res = uc.capture_once(wk, src=0, dec_log2=1, length=length, trig=0,
                          level=0, pre=0)
    uc.close()
    chk(isinstance(res, cap.CaptureResult), "returns CaptureResult")
    chk_eq(res.n, 24, "result n")
    chk_eq(res.s[0], 0, "first sample")
    chk_eq(res.c[0], 500, "first c")
    chk_eq(res.meta.get("transport"), "udp", "meta transport")
    chk_eq(res.meta.get("trig_idx"), 100, "meta trig_idx")
    chk_eq(res.meta.get("sample_cnt"), 12345, "meta sample_cnt")
    chk_eq(res.fs, 25e6, "fs from dec=1")
    chk((0x0736, 1) in wk.written, "UDP_CTRL start written")

    print("")
    if ERRORS[0] == 0:
        print(" TEST PASSED (%d checks)" % CHECKS[0])
        return 0
    print(" TEST FAILED (%d errors / %d checks)" % (ERRORS[0], CHECKS[0]))
    return 1


if __name__ == "__main__":
    sys.exit(main())
