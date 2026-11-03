"""网口连续流可靠性复测：起 1 次 + 重启 3 次，逐次记录包率与主机 MAC 状态。

用法：python -X utf8 tools\\check_stream_reliability.py [COM4] [轮数]
"""

import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import link as lk
import stream_capture as sc

HOST_IP = "192.168.1.100"
BOARD_IP = "192.168.1.10"


def rd(w, addr):
    r = w.read_reg(addr, timeout=0.3, retries=1)
    return -1 if r is None else (r.get("value") or 0) & 0xFFFF


def ping_board():
    try:
        r = subprocess.run(["ping", "-n", "1", "-w", "600", "-S", HOST_IP, BOARD_IP],
                           capture_output=True, timeout=3.0)
        return r.returncode == 0
    except Exception:                                   # noqa: BLE001
        return False


def recv_for(sock, seconds):
    n = 0
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        if sc.parse_packet(data) is not None:
            n += 1
    return n


def open_sock():
    for port in range(5003, 5040):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
        s.settimeout(0.2)
        try:
            s.bind((HOST_IP, port))
            return s, port
        except OSError:
            s.close()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
    s.settimeout(0.2)
    s.bind((HOST_IP, 0))
    return s, s.getsockname()[1]


def one_round(w, sock, tag, seconds=4.0):
    """开流 → 收 seconds 秒 → 关流。返回 (包数, 起始是否 host_known)。"""
    known = bool(rd(w, lk.REG_ETH_STATUS) & 0x4)
    w.stream_start(2)
    if not known:                       # 模仿旧版：没有 warm 就会一包不收
        time.sleep(0.4)
    n = recv_for(sock, seconds)
    w.stream_stop()
    print("  %-14s host_known=%d  收 %6d 包  (%.0f pkt/s)"
          % (tag, 1 if known else 0, n, n / seconds))
    return n


def main(argv):
    port_name = argv[1] if len(argv) > 1 else "COM4"
    rounds = int(argv[2]) if len(argv) > 2 else 3
    sock, port = open_sock()
    print("UDP 绑定 %s:%d" % (HOST_IP, port))

    w = lk.SerialWorker(port_name, lk.BAUD_DEFAULT)
    w.start()
    t0 = time.monotonic()
    while not w.connected and time.monotonic() - t0 < 3.0:
        time.sleep(0.05)
    if not w.connected:
        print("串口打不开（软件是不是开着？）")
        return 2

    w.write_reg(lk.REG_ETH_PORT, port, verify=True)
    print("板端 0x0710 = 0x%04x（bit2 host_known）" % (rd(w, lk.REG_ETH_STATUS) & 0xFFFF))

    bad = 0
    n = one_round(w, sock, "首次开流")
    bad += 1 if n == 0 else 0
    for k in range(rounds):
        time.sleep(0.6)
        n = one_round(w, sock, "重启 %d" % (k + 1))
        bad += 1 if n == 0 else 0

    print("结论：%d 轮里失败 %d 轮" % (1 + rounds, bad))
    w.stop()
    sock.close()
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
