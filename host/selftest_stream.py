# -*- coding: utf-8 -*-
"""连续流接收的离线自检（不需要硬件、不需要界面）。

跑法：``python host/selftest_stream.py``
"""

import os
import socket
import struct
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import stream_capture as sc                                     # noqa: E402

checks = 0
errors = 0


def chk(cond, name, extra=""):
    global checks, errors
    checks += 1
    if not cond:
        errors += 1
        print("  [FAIL] %s %s" % (name, extra))


def make_packet(seq, first, dec, s, c, flags=sc.FLAG_STREAM):
    """按 rtl/eth/stream_tx.v 的字节序造一个包。"""
    n = len(s)
    # ★ 同 selftest_udp：魔数按线上字节序（E7 5A）直接拼，其余字段小端
    hdr = (b"\xE7\x5A"
           + struct.pack("<BBHIIH", flags, dec, seq,
                         first & 0xFFFFFFFF,
                         (first >> 32) & 0xFFFFFFFF, 0))
    body = np.empty(2 * n, dtype="<i2")
    body[0::2] = s
    body[1::2] = c
    return hdr + body.tobytes()


def test_parse():
    print("\n[A] 解析")
    s = np.array([100, 101, 102], dtype=np.int16)
    c = np.array([1000, 1001, 1002], dtype=np.int16)
    pkt = make_packet(7, 1234, 2, s, c)
    seq, first, dec, ps, pc = sc.parse_packet(pkt)
    chk(seq == 7, "包序号")
    chk(first == 1234, "绝对序号")
    chk(dec == 2, "抽取")
    chk(list(ps) == [100, 101, 102], "ch1 样点")
    chk(list(pc) == [1000, 1001, 1002], "ch2 样点")

    chk(sc.parse_packet(b"") is None, "空包返回 None")
    chk(sc.parse_packet(b"\x00" * 40) is None, "坏魔数返回 None")
    # flags bit1=0（一期抓包包）必须被忽略，否则会把抓包当连续流
    chk(sc.parse_packet(make_packet(1, 0, 1, s, c, flags=0)) is None,
        "非连续流标志被忽略")

    big = make_packet(1, (1 << 40) + 5, 1, s, c)
    _seq, first2, _d, _s2, _c2 = sc.parse_packet(big)
    chk(first2 == (1 << 40) + 5, "64 bit 绝对序号")


def test_receiver():
    print("\n[B] 环形缓冲 / 丢包统计")
    r = sc.StreamReceiver(port=0, history=64, timeout_s=0.05)
    chk(not r.running, "未 start 时不 running")

    # 直接调用内部 _store，绕开 socket
    s = np.arange(10, dtype=np.int16)
    c = np.arange(10, dtype=np.int16) + 1000
    r._store(1, 0, 2, s, c)
    r._store(2, 10, 2, s + 10, c + 10)
    snap = r.snapshot(100)
    chk(snap["n"] == 20, "两个包共 20 点", snap["n"])
    chk(snap["first"] == 0, "首样点绝对序号")
    chk(list(snap["s"][:3]) == [0, 1, 2], "首包内容")
    chk(list(snap["s"][10:13]) == [10, 11, 12], "第二包衔接")
    chk(r.lost == 0, "连续时 lost=0")

    # 缺 5 个样点：first 从 20 跳到 25
    r._store(3, 25, 2, s, c)
    chk(r.lost == 5, "缺口计入 lost", r.lost)

    # 绕回：history=64，写 100 个点后只应保留最后 64 个
    r.clear()
    for i in range(0, 100, 10):
        r._store(1 + i // 10, i, 2, np.arange(10, dtype=np.int16) + i,
                 np.arange(10, dtype=np.int16) + 1000 + i)
    snap = r.snapshot(1000)
    chk(snap["n"] == 64, "环形缓冲只保留 history 点", snap["n"])
    chk(int(snap["s"][-1]) == 99, "最后一点是最新写入的")

    snap = r.snapshot(8)
    chk(snap["n"] == 8, "snapshot 限长")
    chk(int(snap["s"][0]) == 92, "限长取的是最新的尾巴", int(snap["s"][0]))

    r.stop()
    chk(True, "stop 不抛异常")


def test_socket():
    print("\n[C] 真 UDP socket 回环")
    r = sc.StreamReceiver(port=0, history=256, timeout_s=0.05)
    # port=0 让系统分配；但 start() 之后才知道端口
    r.port = 0
    r.start()
    port = r._sock.getsockname()[1]
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s = np.arange(32, dtype=np.int16)
    c = s + 500
    for i in range(4):
        tx.sendto(make_packet(i + 1, i * 32, 2, s + i * 32, c + i * 32),
                  ("127.0.0.1", port))
    t_end = time.monotonic() + 2.0
    while time.monotonic() < t_end and r.packets < 4:
        time.sleep(0.01)
    chk(r.packets == 4, "收到 4 个包", r.packets)
    snap = r.snapshot(200)
    chk(snap["n"] == 128, "128 点", snap["n"])
    chk(int(snap["s"][0]) == 0, "首点")
    chk(int(snap["s"][-1]) == 127, "末点")
    r.stop()
    tx.close()

    # 绑不上（地址不是本机）要报 StreamError 而不是静默失败
    r2 = sc.StreamReceiver(port=port, history=64, bind_ip="203.0.113.7")
    try:
        r2.start()
        chk(False, "不可用地址应报错")
        r2.stop()
    except sc.StreamError:
        chk(True, "绑定失败报 StreamError")


def test_misc():
    print("\n[D] 其它")
    chk(abs(sc.fs_for_dec(50e6, 2) - 12.5e6) < 1.0, "fs_for_dec(50M,2)")
    chk(abs(sc.fs_for_dec(50e6, 0) - 50e6) < 1.0, "fs_for_dec(50M,0)")
    try:
        sc.StreamReceiver(port=1, history=100)
        chk(False, "非 2 的幂应报错")
    except ValueError:
        chk(True, "非 2 的幂报 ValueError")


def main():
    test_parse()
    test_receiver()
    test_socket()
    test_misc()
    print("\n%d checks, %d errors" % (checks, errors))
    if errors == 0:
        print(" TEST PASSED")
        return 0
    print(" TEST FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
