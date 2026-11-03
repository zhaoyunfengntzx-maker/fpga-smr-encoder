"""串口枚举（需求 M1：自动 / 手动检索通信端口）。

只做一件事：把 pyserial 能看到的串口列成"给人看"的列表。
不打开端口、不发任何数据，可以在界面启动时随便调。
"""

import re

# 目标板板载 USB 串口（CH340E）的特征，用于自动选中
BOARD_VID_PID = "1A86:7523"
BOARD_DESC_HINTS = ("CH340", "CH341", "USB-SERIAL")


def list_serial_ports():
    """返回 [(设备名, 描述, hwid), ...]，按 COM 号数字顺序排。

    设备名形如 'COM3'；描述形如 'USB-SERIAL CH340'（可能是空串）。
    """
    try:
        from serial.tools import list_ports
    except ImportError:                      # 没有 pyserial 时不让界面崩
        return []

    out = []
    try:
        ports = list(list_ports.comports())
    except Exception:                        # noqa: BLE001 驱动异常时也不要崩
        return []
    for p in ports:
        out.append((p.device or "", p.description or "", p.hwid or ""))

    def sort_key(item):
        m = re.match(r"^COM(\d+)$", item[0], re.I)
        if m:
            return (0, int(m.group(1)), item[0])
        return (1, 0, item[0])

    return sorted(out, key=sort_key)


def format_port(device, desc):
    """列表里显示成 `COM3 — USB-SERIAL CH340`。"""
    if desc:
        return "%s — %s" % (device, desc)
    return device


def board_rank(device, desc, hwid=""):
    """这块端口"像不像目标板"：0 = 就是它，1 = 像（泛 USB-SERIAL），2 = 不像。

    ★ 为什么分三档：描述里带 "USB-SERIAL" 的适配器太多了（FTDI、其它 CDC 板），
      以前只要有这个词就算目标板，若它们排在前面就会把真正的 CH340 顶掉。
    """
    hw = ("%s" % (hwid or "")).upper()
    blob = ("%s %s %s" % (device or "", desc or "", hwid or "")).upper()
    if BOARD_VID_PID in hw or "CH340" in blob or "CH341" in blob:
        return 0
    if "USB-SERIAL" in blob or "USB SERIAL" in blob:
        return 1
    return 2


def looks_like_board(device, desc, hwid=""):
    """像不像我们要连的那块板（CH340E）？"""
    return board_rank(device, desc, hwid) < 2


def preferred_port(ports):
    """自动选中一个：先挑最像目标板的（CH340 > 泛 USB-SERIAL），都一样就取第一个。"""
    best = None
    for device, desc, hwid in ports:
        r = board_rank(device, desc, hwid)
        if best is None or r < best[0]:
            best = (r, device)
    return best[1] if best is not None else None
