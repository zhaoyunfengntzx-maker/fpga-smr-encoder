#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""board_rx_scan.py —— 扫 RGMII RX 的 IDELAY tap，找"能收到帧"的眼心。

为什么需要这个脚本
------------------
v60 首板 ping 不通的直接原因是 RX 采样路径（IDDR 原来接 BUFG、且没用 IDELAY）。
v61 改成 BUFIO + IDELAYE2(VAR_LOAD)，tap 由 0x0758 运行时写，所以不用为每一
档重新综合：本脚本逐档写 tap、从 PC 打一次 ping（板子会收到 ARP 请求），
再看板子的 RX 计数器有没有动。

判据
----
  0x0752 RX_DV_CNT   收到 RXDV 的帧数（累计）
  0x0716 RX_PKT      收下来的完整帧数（累计）
  0x0710 ETH_STATUS  [0] 收到过 ARP  [1] 回过 ICMP  [2] host_mac 已知
能稳定让 RX_DV_CNT 增长（且 ARP 位置 1）的 tap 就是可用档；取增长最多的一档写回。

用法
----
    python tools/board_rx_scan.py --port COM6
    python tools/board_rx_scan.py --port COM6 --taps 0-31 --pings 2
    python tools/board_rx_scan.py --port COM6 --tap 12        # 只写一档并报告

注意：跑之前 PC 网口要设成 192.168.1.100/24、网线接板子；板子跑 v61 位流。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from host.link import SerialWorker  # noqa: E402

REG_ETH_STATUS = 0x0710
REG_RX_PKT = 0x0716
REG_RX_CLK_CNT = 0x0750
REG_RX_DV_CNT = 0x0752
REG_RX_BYTE_CNT = 0x0754
REG_RX_ERR_CNT = 0x0756
REG_IDELAY_TAP = 0x0758
REG_RX_DBG = 0x075A          # 0x075A..0x075D = 每帧第 5..8 字节（应看到 55 55 D5 FF）


def _val(w, addr):
    """读一个 16 bit 寄存器；失败返回 None。"""
    r = w.read_reg(addr)
    if isinstance(r, dict):
        return int(r.get("value", 0)) & 0xFFFF
    return None


def _parse_taps(s):
    if "-" in s:
        a, b = s.split("-", 1)
        return list(range(int(a), int(b) + 1))
    return [int(x) for x in s.split(",") if x.strip()]


def _ping(host, count):
    try:
        subprocess.run(["ping", "-n", str(count), "-w", "300", host],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=count * 2 + 5)
    except Exception:
        pass


def _bcast(src_ip, n=8, size=200):
    """从指定源地址发广播 UDP。

    用广播而不是 ping：广播帧不需要 ARP，板子能不能收到只取决于 RX 采样对不对，
    这正是扫 tap 想单独观察的量。绑定源地址是为了强制从"有线"网口出去
    （WLAN 也是 192.168.1.x，不绑会走路由 metric 小的那条）。
    """
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            s.bind((src_ip, 0))
        except OSError:
            pass          # 绑不上就用默认路由凑合
        payload = b"\xA5" * size
        for _ in range(n):
            try:
                s.sendto(payload, ("192.168.1.255", 5000))
            except OSError:
                break
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser(description="扫 RGMII RX 的 IDELAY tap")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=0, help="默认用 link.BAUD_DEFAULT")
    ap.add_argument("--taps", default="0-31", help="如 0-31 / 0,8,16,24")
    ap.add_argument("--tap", type=int, default=None, help="只写这一档")
    ap.add_argument("--ping-host", default="192.168.1.10")
    ap.add_argument("--pings", type=int, default=2, help="每档 ping 几次")
    ap.add_argument("--stim", default="bcast", choices=["bcast", "ping", "both"],
                    help="刺激源：广播 UDP（默认，不需要 ARP）/ ping / 两者")
    ap.add_argument("--src-ip", default="192.168.1.100", help="广播绑定的源地址（有线网口）")
    ap.add_argument("--swap", action="store_true",
                    help="置 0x0758 bit6：交换 IDDR 两个半字节（前导码 0x55 看不出区别，"
                         "但 SFD 会从 5D 变回 D5）")
    ap.add_argument("--settle", type=float, default=0.15, help="写 tap 后等待秒数")
    args = ap.parse_args()

    w = SerialWorker(args.port) if not args.baud else SerialWorker(args.port, baud=args.baud)
    w.start()
    t0 = time.time()
    while not w.connected and time.time() - t0 < 3.0:
        time.sleep(0.05)
    if not w.connected:
        print(f"[FAIL] 打不开串口 {args.port}")
        return 2

    try:
        info = w.read_device_info() or {}
        print(f"串口 {args.port} 已连；BUILD={info.get('rtl_build', '?')}")
        clk0 = _val(w, REG_RX_CLK_CNT)
        print(f"RX_CLK_CNT = {clk0}")
        if clk0 is None:
            print("[WARN] 0x0750 读不到：确认烧的是 v61 位流（v60 及以前没有这组寄存器）")

        taps = [args.tap] if args.tap is not None else _parse_taps(args.taps)
        swap = 0x40 if args.swap else 0x00
        rows = []
        for tap in taps:
            # 读回是 {rdy, tap}，与写入值不相等，所以关掉寄存器回读校验
            ok = w.write_reg(REG_IDELAY_TAP, (tap & 0x1F) | swap, verify=False)
            time.sleep(args.settle)
            dv0 = _val(w, REG_RX_DV_CNT) or 0
            rp0 = _val(w, REG_RX_PKT) or 0
            if args.stim in ("bcast", "both"):
                _bcast(args.src_ip)
            if args.stim in ("ping", "both"):
                _ping(args.ping_host, args.pings)
            time.sleep(0.05)
            dv1 = _val(w, REG_RX_DV_CNT) or 0
            rp1 = _val(w, REG_RX_PKT) or 0
            st = _val(w, REG_ETH_STATUS) or 0
            ddv = (dv1 - dv0) & 0xFFFF
            drp = (rp1 - rp0) & 0xFFFF
            dbg = " ".join(f"{(_val(w, REG_RX_DBG + i) or 0):02X}" for i in range(4))
            rows.append((tap, ddv, drp, st != 0, ok is not None))
            print(f"  tap {tap:2d}: RXDV +{ddv:4d}  RX_PKT +{drp:3d}  "
                  f"ETH_STATUS=0x{st:04X}  DBG={dbg}  {'OK' if ddv or drp else '.'}")

        good = [r for r in rows if r[1] or r[2]]
        if not good:
            print("\n[FAIL] 所有 tap 都没收到帧。检查：网线/PC 网口 192.168.1.100、"
                  "板子 link（0x0710 的 ARP 位需要先收到 ARP）、PHY 复位。")
            return 1
        best = max(good, key=lambda r: (r[1], r[2]))[0]
        print(f"\n可用档: {[r[0] for r in good]}")
        print(f"[OK] 眼心 tap = {best}（已写回）")
        w.write_reg(REG_IDELAY_TAP, (best & 0x1F) | swap, verify=False)
        time.sleep(args.settle)
        print(f"回读 0x0758 = 0x{(w.read_reg(REG_IDELAY_TAP) or {}).get('value', 0):04X}")
        return 0
    finally:
        try:
            w.stop()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
