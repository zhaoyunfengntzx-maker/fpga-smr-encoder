#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/board_eth_check.py —— v60 以太网抓包的上板一键验收。

跑法（板子已烧 _impl_v60/enc_top_disp.bit，网线直连/同交换机，串口接着）：

    python tools/board_eth_check.py --port COM3
    python tools/board_eth_check.py --port COM3 --src 1 --dec 1 --out cap.npy

做的事（每步打 PASS/FAIL，最后给 SUMMARY）：

  1. ping 192.168.1.10          —— 板子的 ARP/ICMP 应答（eth_reply）
  2. arp -a 查 MAC 02:00:00:00:00:01
  3. 串口读 0x0000 ID / 0x0700 CTRL —— 确认串口链路活着、v60 位流在跑
  4. 读 0x0732 CAP_LEN_EFF      —— 应为 28672（或请求值按 64 点对齐后的值）
  5. UDP 抓一窗                  —— 82 包 / 28672 点 / missing=0
  6. 落盘 .npy 并打摘要

退出码：0 = 全过；1 = 有 FAIL；2 = 环境问题（没串口/没网线）。
"""
import argparse
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))

import capture  # noqa: E402
import udp_capture  # noqa: E402
from link import SerialWorker  # noqa: E402

# 与 host/regs.py、host/diag.py 同一口径：控制台按 UTF-8 输出，避免 cp936 下中文乱码。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:                               # noqa: BLE001  (Python < 3.7)
    pass

BOARD_IP = "192.168.1.10"
BOARD_MAC = "02:00:00:00:00:01"
DEPTH = 28672

_fails = []


def step(name, ok, detail=""):
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", name, ("  — " + detail) if detail else ""))
    if not ok:
        _fails.append(name)
    return ok


def sh(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=20, shell=isinstance(cmd, str))
        out = p.stdout.decode("gbk", "replace") if isinstance(p.stdout, bytes) else p.stdout
        return p.returncode, out
    except Exception as e:                      # noqa: BLE001
        return 1, str(e)


def check_ping(ip):
    rc, out = sh(["ping", "-n", "4", "-w", "1000", ip])
    ok = rc == 0 and (("TTL=" in out) or ("ttl=" in out))
    loss = ""
    m = re.search(r"(\d+)%", out)
    if m:
        loss = "loss=%s%%" % m.group(1)
    if not ok:
        loss = ("no reply; " + loss).strip("; ")
    return step("ping %s" % ip, ok, loss)


def check_arp(ip, mac):
    rc, out = sh(["arp", "-a", ip])
    hit = mac.replace(":", "-").lower() in out.lower() or mac.lower() in out.lower()
    if not hit:
        # 有的系统 arp -a 需要先有流量；ping 已发过，再查全表
        rc, out = sh(["arp", "-a"])
        hit = mac.replace(":", "-").lower() in out.lower() or mac.lower() in out.lower()
    return step("arp MAC == %s" % mac, hit, "" if hit else "表里没有这条（PHY 没起来 / 没插网线 / IP 不符）")


def rd(worker, reg):
    """读 16 位寄存器；读不到返回 None（link.read_reg 超时会返回 None）。"""
    d = worker.read_reg(reg)
    if not d:
        return None
    return int(d.get("value", 0)) & 0xFFFFFFFF


def main(argv=None):
    ap = argparse.ArgumentParser(description="v60 以太网抓包上板验收")
    ap.add_argument("--port", required=True, help="串口，例如 COM3")
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--ip", default=BOARD_IP)
    ap.add_argument("--udp-port", type=int, default=5000)
    ap.add_argument("--src", type=int, default=0, choices=[0, 1])
    ap.add_argument("--dec", type=int, default=1, choices=[0, 1, 2, 3],
                    help="抽取 log2：0=50M, 1=25M(默认), 2=12.5M, 3=6.25M")
    ap.add_argument("--length", type=int, default=DEPTH)
    ap.add_argument("--trig", type=int, default=0)
    ap.add_argument("--level", type=int, default=0)
    ap.add_argument("--out", default="", help="结果 .npy 路径（可选）")
    ap.add_argument("--skip-net", action="store_true", help="跳过 ping/arp（只想测串口+UDP）")
    args = ap.parse_args(argv)

    if not args.skip_net:
        print("== 1/2 网络层（ARP/ICMP，走 eth_reply，不需要上位机参与）==")
        ping_ok = check_ping(args.ip)
        arp_ok = check_arp(args.ip, BOARD_MAC)
        if not (ping_ok or arp_ok):
            print("板子没应答：先确认 (a) 烧的是 _impl_v60 位流 (b) 网口灯 (c) PC 有 192.168.1.x 地址")
    else:
        print("== 1/2 网络层：已跳过 ==")

    print("== 3 串口链路 ==")
    worker = SerialWorker(args.port, baud=args.baud)
    worker.start()
    try:
        t_end = time.time() + 5.0
        while time.time() < t_end and not worker.connected and not worker.error:
            time.sleep(0.05)
        if not worker.connected:
            print("FAIL 串口没就绪：%s（%s）" % (args.port, worker.error or "超时"))
            return 2
        dev_id = rd(worker, 0x0000)
        step("串口 0x0000 器件 ID 可读", dev_id is not None,
             "0x%04X" % (dev_id or 0))
        ctrl = rd(worker, 0x0700)
        step("0x0700 抓包控制可读", ctrl is not None,
             "0x%04X" % (ctrl or 0))
        if dev_id is None or ctrl is None:
            print("串口能开但寄存器读不到：查波特率（2 Mbaud）、TX/RX 是否交叉、板子是否在跑")
            return 1

        print("== 4 抓包参数 ==")
        ok, err = worker.capture_configure(src=args.src, dec_log2=args.dec,
                                           length=args.length, trig=args.trig,
                                           level=args.level, pre=1024)
        if not ok:
            print("FAIL capture_configure: %s" % err)
            return 1
        leng_eff = rd(worker, 0x0732)
        step("CAP_LEN_EFF == %d" % args.length, leng_eff == args.length,
             "读回 %s" % ("None" if leng_eff is None else str(leng_eff)))
        if leng_eff is None:
            print("0x0732 读不到，后面的整窗校验改用请求值 %d" % args.length)
            leng_eff = args.length

        print("== 5 UDP 抓一窗 ==")
        udp = udp_capture.UdpCapture(port=args.udp_port)
        udp.open()
        try:
            t0 = time.time()
            res = udp.capture_once(worker, src=args.src, dec_log2=args.dec,
                                   length=args.length, trig=args.trig,
                                   level=args.level)
            dt = time.time() - t0
        finally:
            udp.close()
        print("  %s" % res.summary())
        print("  耗时 %.2f s，块数 %d，缺失 %d" % (dt, res.n_blocks, len(res.missing or [])))
        step("收到整窗 %d 点" % leng_eff, res.n == leng_eff, "n=%d" % res.n)
        step("无缺块", not res.missing, "missing=%s" % (res.missing,))

        print("== 6 结果 ==")
        print("  峰值 %s" % (res.peak_to_peak(0),))
        if args.out:
            out = os.path.abspath(args.out)
            res.to_npy(out)
            print("  已写 %s (%d B)" % (out, os.path.getsize(out)))
    finally:
        try:
            worker.stop()
        except Exception:                       # noqa: BLE001
            pass

    print("\nSUMMARY: %s" % ("ALL PASS" if not _fails else "FAIL -> " + ", ".join(_fails)))
    return 0 if not _fails else 1


if __name__ == "__main__":
    sys.exit(main())
