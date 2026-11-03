#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
uart_spi.py —— 用板载 USB 串口(UART) 读写 FPGA 内部寄存器（UART -> SPI 桥）

背景
    不需要任何额外硬件、也不需要外部 SPI 主机：`rtl/uart_spi_bridge.v` 在 FPGA
    内部当 SPI 主机去驱动既有的 `rtl/spi_slave.v`。所以只要把板载 USB 串口
    （CH340E；`uart_rxd` = T20 / `uart_txd` = W21）插上电脑，往串口发 4 个字节
    就等于发了一个完整的 32 位 SPI 包。

命令（4 字节，PC -> FPGA，MSB 先）
    bit31     st    必须为 1，否则整包被忽略
    bit30:29  rm    读模式，本工具一律 00
    bit28:27  wm    00 = 不写（读）；01 = 写（低字节写 addr，高字节写 addr+1）
    bit26:24  page  必须等于 addr[10:8]（只认 0..0x7FF 的地址）
    bit23:16  addr  addr[7:0]
    bit15:0   data  写数据（读时填 0）
  => 首字节 = 0x80 | (wm<<3) | page:
       读 page1 = 0x81   读 page5 = 0x85
       写 page1 = 0x89   写 page4 = 0x8C   写 page5 = 0x8D
  常用例子:
       read  0x05F0          -> 85 F0 00 00   （DEVICE_ID / REV）
       read  0x053A          -> 85 3A 00 00   （STAT_FLAGS）
       write 0x0109 0x00C0   -> 89 09 00 C0   （abzen=1 uwven=1 -> 开 UVW 输出）
       write 0x0405 0x0001   -> 8C 05 00 01   （清 ADC sticky OTR）
       write 0x0502 0x0001   -> 8D 02 00 01   （启动一键标定）
       write 0x0102 0x001C   -> 89 02 00 1C   （inter 分频 div=8）
       write 0x0108 0x0008   -> 89 08 00 08   （Z 脉宽 8 拍）
  ★ 0xE000 的 DEVICE_ID 别名**用不了**（page 只有 3 bit，地址只到 0x7FF），
    要读 0x05F0。

应答（6 字节，FPGA -> PC）
    0x5A | resp[31:24] | resp[23:16] | resp[15:8] | resp[7:0] | chk
    chk = 0x5A ^ 前 4 个字节（所以 0x5A^b1^b2^b3^b4^chk == 0，用来查错）
      resp[31:24] = 地址 {page,0x3A} 的读值（page5 即 0x053A STAT_FLAGS）
      resp[23:16] = 地址回显
      resp[15:8]  = reg[addr+1]
      resp[7:0]   = reg[addr]
  ★ 写命令的应答内容是"上一帧的"（TW28 重叠式，见 `rtl/spi_slave.v:220-251`），
    本身没有意义，只用来确认链路通 / 命令已被执行；只有读命令会自动连发两帧
    取回新值（这正是 4 字节命令能"读到东西"的原因）。

★ 两个必须遵守的约束（由桥的帧同步保护决定）
    1) 一条命令收到应答后再发下一条：桥一次只处理一条命令，且首字节前面要求
       线路空闲 >= 13 位（GAP_MIN），否则会被当成上一条命令的残尾丢弃。
    2) 遥测帧与应答共用一根 TX：本工具按内容分流 —— 见到 `AA 55` 就跳过 18
       字节遥测帧，见到 `5A` 且校验和为 0 才认应答。应答期间遥测会少发几帧，
       这是有意设计（切换只发生在线路空闲时，线上不会出现半个字节）。

用法
    python tools/uart_spi.py --selftest                  # 不接硬件，自检编解码
    python tools/uart_spi.py --port COM7 ports           # 列出串口
    python tools/uart_spi.py --port COM7 dump            # 读一批常用寄存器
    python tools/uart_spi.py --port COM7 read 0x05F0 0x053A
    python tools/uart_spi.py --port COM7 write 0x0405 0x0001
    python tools/uart_spi.py --port COM7 write 0x0109=0x00C0 0x0102=0x001C
    python tools/uart_spi.py --file cap.bin read 0x05F0  # 从抓包文件里找应答
    退出码: 0 成功 / 1 失败或超时 / 2 环境问题（缺 pyserial、没给串口等）
"""

import argparse
import os
import sys
import time

BAUD_DEFAULT = 2000000
REPLY_HEAD = 0x5A
TELEM_HEAD = (0xAA, 0x55)
TELEM_FRAME_LEN = 18

# ---------------------------------------------------------------- 寄存器名字表
REG_NAMES = {
    0x007E: "DEVICE_ID",
    0x0100: "UVW_CFG",
    0x0101: "INTER_L",
    0x0102: "INTER_H/div",
    0x0103: "HYST_L",
    0x0104: "HYST_H",
    0x0105: "FILT_CFG",
    0x0108: "ZERO1(zwidth)",
    0x0109: "OUTPUT",
    0x0400: "STAT_CFG",
    0x0402: "STAT_IE",
    0x0404: "STAT_VAL",
    0x0405: "STAT_LATCH(W1C)",
    0x0406: "RSVD",
    0x0500: "ST_BITS",
    0x0501: "MT_BITS",
    0x0502: "CALIB_CTRL",
    # ★ 标定结果块按 rtl/reg_file.v 的地址表：每项 16 位占两个地址（低字节在前）
    0x0510: "CAL_OFS_S",
    0x0511: "CAL_OFS_S_H",
    0x0512: "CAL_OFS_C",
    0x0513: "CAL_OFS_C_H",
    0x0514: "CAL_GAIN_S",
    0x0515: "CAL_GAIN_S_H",
    0x0516: "CAL_GAIN_C",
    0x0517: "CAL_GAIN_C_H",
    0x0518: "CAL_PHASE_K",
    0x0519: "CAL_PHASE_K_H",
    0x051A: "CAL_SHIFT",
    0x0520: "AMP_LOW_SQ_L",
    0x0522: "AMP_LOW_SQ_H",
    0x0524: "AMP_HIGH_SQ_L",
    0x0526: "AMP_HIGH_SQ_H",
    0x0530: "STAT_AMP_SQ_L",
    0x0532: "STAT_AMP_SQ_H",
    0x0534: "STAT_CYCLE_L",
    0x0535: "STAT_CYCLE_H",
    # pos_full = {cycle[31:16], angle[15:0]}（rtl/reg_file.v:470-473）
    0x0536: "STAT_POS_ANGLE",
    0x0537: "STAT_POS_ANGLE_H",
    0x0538: "STAT_POS_CYCLE",
    0x0539: "STAT_POS_CYCLE_H",
    0x053A: "STAT_FLAGS",
    0x053B: "STAT_FRAME_L",
    0x053C: "STAT_FRAME_H",
    0x05F0: "DEVICE_ID",
    0x05F1: "REV",
}

# 位域解码表: addr -> (低位宽列表, 只读?)
BITFIELDS = {
    0x0109: [("apol", 1), ("bpol", 1), ("zpol", 1), ("abzdir", 1),
             ("uvwpol", 1), ("uvwdir", 1), ("abzen", 1), ("uwven", 1)],
    # ★ 按 rtl/reg_file.v:222-224 的 stat_val_now：bit0 otr / bit2 laglim / bit3 inclim / bit5 amp
    0x0404: [("otr", 1), ("res", 1), ("laglim", 1), ("inclim", 1), ("res", 1), ("amp", 1)],
    0x0405: [("otr", 1), ("res", 1), ("laglim", 1), ("inclim", 1), ("res", 1), ("amp", 1)],
    # ★ 0x053A 是完整的 8 位状态字（bit4 caldone / bit5 calbusy / bit6 crcerr / bit7 frame）
    0x053A: [("laglim", 1), ("amplo", 1), ("amphi", 1), ("otr", 1),
             ("caldone", 1), ("calbusy", 1), ("crcerr", 1), ("frame_active", 1)],
    # ★ 0x0502 读：[1]busy [2]done [3]truncated [6:4]标定重试次数 [7]win_bad
    #   （★ 权威口径 = rtl/reg_file.v:451
    #      rdata = {8'b0, calib_bad, calib_retry, calib_trunc, r_calib_done, calib_busy, 1'b0}
    #      ⇒ bit7=bad、bit[6:4]=retry、bit3=trunc、bit2=done、bit1=busy、bit0=0。
    #      2026-10-10 曾错写成 [7:5]=retry/bit4=win_bad，导致 20 轮标定统计解码全错。）
    #   （★ 包模式读 16 位会把高字节 0x0503 = CALIB_N 低字节一起读出来，
    #     所以 0x0502 正常会看到 0x40BC 这类值：高字节来自 CALIB_N=64）
    0x0502: [("start", 1), ("busy", 1), ("done", 1), ("truncated", 1), ("retry_cnt", 3),
             ("win_bad", 1)],
}

DUMP_REGS = [0x05F0, 0x05F1, 0x007E, 0x0100, 0x0101, 0x0102, 0x0108, 0x0109,
             0x0400, 0x0404, 0x0405, 0x0500, 0x0501, 0x0502,
             0x0534, 0x0535, 0x0536, 0x0537, 0x053A]

# 常用写配置（dump 后可直接照抄）
HINTS = {
    0x0109: "0xC0 = abzen+uwven 开 ABZ 与 UVW；0x40 = 只开 ABZ（复位默认）",
    0x0405: "写 0x0001 清 ADC sticky OTR（led[0]/irq_n 恢复）",
    0x0502: "写 0x0001 启动一键标定（bit0 自清，bit2 done）。★包模式写一次事务写 2 字节"
            "（spi_slave.v:244-251）⇒ 16 位写 0x0502 会把高字节落到 0x0503 = CALIB_N 低字节，"
            "请先用 'write 0x0503 0x0000 0x0503 0x0040' 之类方式确认窗口（默认 0/0x40=64）",
    0x0503: "CALIB_N 低字节（标定窗口周期数，16 位小端 0x0503/0x0504）；0 视为默认 64",
    0x0102: "0x001C = inter 分频 div=8；inter=16 见 0x0101",
}


# ------------------------------------------------------------------ 协议编解码
def encode_cmd(addr, data=0, write=False):
    """把一个 32 位 SPI 包编成 4 字节（MSB 先）。"""
    if not (0 <= addr <= 0x7FF):
        raise ValueError("地址 0x%X 超出包协议范围 0..0x7FF（page 只有 3 bit）" % addr)
    if not (0 <= data <= 0xFFFF):
        raise ValueError("数据 0x%X 超出 16 bit" % data)
    page = (addr >> 8) & 0x7
    b0 = 0x80 | (0x08 if write else 0x00) | page
    # 字节 2 = 包 bit15:8、字节 3 = 包 bit7:0（MSB 先）；
    # 从站把 bit7:0 写 addr、bit15:8 写 addr+1（rtl/spi_slave.v:244-251）
    return bytes([b0, addr & 0xFF, (data >> 8) & 0xFF, data & 0xFF])


def reply_checksum(b):
    return 0x5A ^ b[1] ^ b[2] ^ b[3] ^ b[4]


def build_reply(status, addr, lo, hi):
    """造一个 6 字节应答（自检用）。"""
    b = [REPLY_HEAD, status & 0xFF, addr & 0xFF, hi & 0xFF, lo & 0xFF]
    b.append(reply_checksum(b))
    return bytes(b)


def find_reply(buf, start=0):
    """在字节流里找应答。返回 (6 字节应答, 下一个扫描位置) 或 (None, 位置)。

    分流规则：`AA 55` 开头 = 18 字节遥测帧，整帧跳过；`5A` 开头且
    0x5A^b1^b2^b3^b4^chk == 0 才是应答。遥测负载里偶尔出现 0x5A 也不会误判，
    因为校验和把误判概率压到 1/256 以下。

    ★ 2026-11-02 审计修复：原来只要看到 `AA 55` 就无条件跳过 18 字节，不验这 18 字节
      是不是真帧。若线路噪声/残留字节里恰好出现 `AA 55`（实测随机前导字节 12 字节里
      命中概率 ~1/65536，长时间读寄存器必然遇到），就会把紧随其后的真应答一起跳过，
      读寄存器表现为"偶发超时/无应答"。现在只有整帧 XOR == 0 才跳帧，否则按 1 字节前移。
    """
    i = start
    n = len(buf)
    while i < n:
        if buf[i] == TELEM_HEAD[0] and i + 1 < n and buf[i + 1] == TELEM_HEAD[1]:
            if i + TELEM_FRAME_LEN <= n:
                chk_sum = 0
                for b in buf[i:i + TELEM_FRAME_LEN]:
                    chk_sum ^= b
                # 真遥测帧的三条判据（2026-11-02 审计加固）：
                #   1) 18 字节 XOR == 0；
                #   2) off9（io_tag）== 0xA2（v2 布局）或 ≤ 0x80（v11 及更早旧布局）；
                #   3) 帧尾后面紧跟下一帧头 AA 55、或紧跟应答头 0x5A、或正好到流尾。
                # 三条全满足才整帧跳过；否则按 1 字节前移，避免"假 AA 55 吞掉真应答"
                # （实测：12 字节垃圾里出现 AA 55 且 18 字节窗口异或恰好为 0 时，
                #   原实现会把紧随其后的真应答一起跳过，读寄存器表现为偶发无应答）。
                tag = buf[i + 9]
                j = i + TELEM_FRAME_LEN
                tail_ok = (j >= n) or (buf[j] == TELEM_HEAD[0]) or (buf[j] == REPLY_HEAD)
                if chk_sum == 0 and (tag == 0xA2 or tag <= 0x80) and tail_ok:
                    i += TELEM_FRAME_LEN
                    continue
            i += 1                        # 假帧头：只前移 1 字节，别吞掉后面的应答
            continue
        if buf[i] == REPLY_HEAD and i + 6 <= n:
            cand = buf[i:i + 6]
            if (0x5A ^ cand[1] ^ cand[2] ^ cand[3] ^ cand[4] ^ cand[5]) == 0:
                return cand, i + 6
        i += 1
    return None, i


def describe(addr, lo, hi, status=None):
    """把一行读数渲染成可读文本。"""
    name = REG_NAMES.get(addr, "")
    val16 = ((hi & 0xFF) << 8) | (lo & 0xFF)
    line = "0x%04X %-16s = 0x%04X" % (addr, name, val16)
    if addr in (0x05F0,):
        line += "   [DEVICE_ID=0x%02X REV=0x%02X（两个 8 位寄存器）]" % (lo, hi)
    elif addr == 0x053A:
        line += "   [状态字节]"
    else:
        line += "   (byte0=0x%02X byte1=0x%02X)" % (lo, hi)
    bits = []
    if addr in BITFIELDS:
        pos = 0
        for bname, width in BITFIELDS[addr]:
            if (val16 >> pos) & ((1 << width) - 1):
                bits.append(bname)
            pos += width
        line += "   set: " + (" ".join(bits) if bits else "(none)")
    if status is not None:
        line += "   [status=0x%02X]" % status
    if addr in HINTS:
        line += "\n            提示: " + HINTS[addr]
    return line


# -------------------------------------------------------------------- 串口交互
def open_port(port, baud, timeout=0.2):
    try:
        import serial
    except ImportError:
        print("需要 pyserial 才能读串口：pip install pyserial")
        return None
    try:
        return serial.Serial(port, baud, timeout=timeout)
    except Exception as exc:                       # noqa: BLE001
        print("打开串口失败 %s @ %d: %s" % (port, baud, exc))
        return None


def list_ports():
    try:
        from serial.tools import list_ports as lp
    except ImportError:
        print("需要 pyserial 才能列串口：pip install pyserial")
        return 2
    ports = list(lp.comports())
    if not ports:
        print("没有发现串口。板载 USB 串口的 COM 号只在插上时存在；")
        print("若用板载供电的另一个 USB 口，需要把 USB 线插到 CH340E 那个口。")
        return 1
    for p in ports:
        print("  %-8s %s" % (p.device, p.description))
    return 0


class Link(object):
    """一次收发。hold 住串口对象，串口流里同时有 10 kHz 遥测帧。"""

    def __init__(self, ser, baud, retries=3):
        self.ser = ser
        self.baud = baud
        self.retries = max(1, int(retries))
        self.tail = b""            # 最后一次超时时收到的字节（诊断"没应答"还是"应答被截断"）

    def _once(self, payload, timeout):
        try:
            self.ser.reset_input_buffer()
        except Exception:                          # noqa: BLE001
            pass
        self.ser.write(payload)
        self.ser.flush()
        buf = bytearray()
        scan = 0
        t0 = time.time()
        while time.time() - t0 < timeout:
            chunk = self.ser.read(512)
            if not chunk:
                continue
            buf += chunk
            r, scan = find_reply(buf, scan)
            if r is not None:
                return r, bytes(buf)
            if len(buf) > 8192:
                del buf[:len(buf) - 256]
                scan = 0
        return None, bytes(buf)

    def transact(self, payload, timeout=0.4):
        """发一条命令等应答。2 Mbaud 下实测偶发丢字节 ⇒ 默认自动重发几次。"""
        last = b""
        for attempt in range(self.retries):
            r, buf = self._once(payload, timeout)
            if r is not None:
                self.tail = b""
                return r
            last = buf
            if attempt + 1 < self.retries:
                print("  ..  第 %d 次超时，重发 (%d/%d)"
                      % (attempt + 1, attempt + 1, self.retries))
                time.sleep(0.05)
        self.tail = last[-32:]
        return None

    def tail_hex(self):
        if not self.tail:
            return "(超时期间没收到任何字节)"
        return " ".join("%02X" % b for b in self.tail) + "  (尾部 %d 字节)" % len(self.tail)


def do_read(link, addrs, timeout):
    rc = 0
    for addr in addrs:
        payload = encode_cmd(addr, write=False)
        print("read  0x%04X  -> %s" % (addr, " ".join("%02X" % b for b in payload)))
        rep = link.transact(payload, timeout)
        if rep is None:
            print("  !! 超时：没收到应答（检查位流是否为含桥的新版、串口是否选对、"
                  "是否有外部 SPI 主机长时间占用）")
            print("     超时期间收到: %s" % link.tail_hex())
            rc = 1
            continue
        print("        <- %s" % " ".join("%02X" % b for b in rep))
        print("       " + describe(addr, rep[4], rep[3], rep[1]))
        time.sleep(0.01)
    return rc


def _readback(link, addr, timeout):
    """回读 addr 的 16 位窗口 {reg[addr+1], reg[addr]}；返回 (value, raw) 或 (None, None)。"""
    rb = link.transact(encode_cmd(addr, write=False), timeout)
    if rb is None:
        return None, None
    return (rb[3] << 8) | rb[4], rb


def do_write(link, pairs, timeout, verify=False):
    """写寄存器。

    --verify 采用"哨兵写入"协议，专治**误地址写**：2 Mbaud 链路上偶发丢字节会让
    一帧写落到错误的地址，而普通的"写后回读"在**回读值本来就等于写入值**时无法
    发现（例如往低字节已经是 0x00 的寄存器写 0x0000）。此时的失败模式是"写入
    好像成功、其实没生效，同时另一个寄存器被莫名写坏"。
    协议：① 先回读旧值；② 若旧值已等于目标值，先写一个哨兵（低字节取反），
    回读确认哨兵落地；③ 再写目标值并回读确认。任一环节不符即报错退出码 1。
    比较掩码：写入值 > 0xFF 时比 16 位，否则只比低字节（8 位寄存器的高字节是
    相邻寄存器的值，不是本次写入的内容）。
    """
    rc = 0
    for addr, data in pairs:
        mask = 0xFFFF if data > 0xFF else 0x00FF
        if verify:
            old, _ = _readback(link, addr, timeout)
            if old is None:
                print("  !! 写前回读超时，无法用哨兵协议确认地址通路")
                rc = 1
                time.sleep(0.01)
                continue
            if (old & mask) == (data & mask):
                sent = data ^ 0x00FF
                print("       旧值 0x%04X 已等于目标值，先写哨兵 0x%04X 验证地址通路"
                      % (old, sent))
                link.transact(encode_cmd(addr, sent, write=True), timeout)
                got, _ = _readback(link, addr, timeout)
                if got is None or (got & mask) != (sent & mask):
                    print("       !! 哨兵写入未生效（回读 %s），本帧可能被误地址或丢字节，"
                          "结果不可信" % ("超时" if got is None else "0x%04X" % got))
                    rc = 1
                    time.sleep(0.01)
                    continue
        payload = encode_cmd(addr, data, write=True)
        print("write 0x%04X = 0x%04X  -> %s"
              % (addr, data, " ".join("%02X" % b for b in payload)))
        rep = link.transact(payload, timeout)
        if rep is None:
            print("  !! 超时：没收到应答，不能确认写入")
            print("     超时期间收到: %s" % link.tail_hex())
            rc = 1
            continue
        print("        <- %s   (写应答的内容是上一帧的，无意义，只表示链路通)"
              % " ".join("%02X" % b for b in rep))
        if verify:
            got, _ = _readback(link, addr, timeout)
            if got is None:
                print("  !! 回读超时，无法确认写入是否生效")
                rc = 1
            else:
                ok = (got & mask) == (data & mask)
                print("       回读 0x%04X = 0x%04X  %s"
                      % (addr, got, "OK" if ok else
                         "!! 与写入值不符（W1C/自清位寄存器会如此，如 0x0405/0x0502）"))
                if not ok:
                    rc = 1
        time.sleep(0.01)
    return rc


def do_dump(link, timeout):
    return do_read(link, DUMP_REGS, timeout)


def parse_pairs(tokens):
    """接受 `0x0109 0xC0` 与 `0x0109=0xC0` 两种写法。"""
    flat = []
    for t in tokens:
        if "=" in t:
            flat.extend(t.split("=", 1))
        else:
            flat.append(t)
    if len(flat) % 2:
        raise SystemExit("write 需要成对的 地址 数据（或 地址=数据）")
    out = []
    for i in range(0, len(flat), 2):
        out.append((int(flat[i], 0), int(flat[i + 1], 0)))
    return out


# ------------------------------------------------------------------- 文件模式
def find_in_file(path, addr):
    with open(path, "rb") as fh:
        buf = fh.read()
    print("文件 %s（%d 字节）里找应答：" % (path, len(buf)))
    rep, scan = find_reply(buf)
    if rep is None:
        print("  !! 没找到带正确校验和的应答")
        return 1
    print("  <- %s（偏移 %d）" % (" ".join("%02X" % b for b in rep), scan - 6))
    print("  " + describe(addr, rep[4], rep[3], rep[1]))
    return 0


# ---------------------------------------------------------------------- 自检
def selftest():
    checks = 0
    fails = 0

    def chk(cond, name, extra=""):
        nonlocal checks, fails
        checks += 1
        if not cond:
            fails += 1
            print("  [FAIL] %s %s" % (name, extra))

    # --- 命令编码（首字节 = 0x80 | wm<<3 | page）---
    cases = [
        ((0x05F0, 0, False), "85 F0 00 00", "read 0x05F0"),
        ((0x053A, 0, False), "85 3A 00 00", "read 0x053A"),
        ((0x0108, 0, False), "81 08 00 00", "read 0x0108 (page1!)"),
        ((0x0109, 0x00C0, True), "89 09 00 C0", "write 0x0109"),
        ((0x0102, 0x001C, True), "89 02 00 1C", "write 0x0102"),
        ((0x0108, 0x0008, True), "89 08 00 08", "write 0x0108"),
        ((0x0405, 0x0001, True), "8C 05 00 01", "write 0x0405"),
        ((0x0502, 0x0001, True), "8D 02 00 01", "write 0x0502"),
    ]
    for (args, exp, name) in cases:
        got = " ".join("%02X" % b for b in encode_cmd(*args))
        chk(got == exp, "encode " + name, "got %s exp %s" % (got, exp))
    try:
        encode_cmd(0xE000, 0, False)
        chk(False, "encode 0xE000 应当报错")
    except ValueError:
        chk(True, "encode 0xE000 应当报错")

    # --- 应答构造与校验 ---
    rep = build_reply(0x01, 0xF0, 0x0C, 0x10)
    chk(rep == bytes.fromhex("5A01F0100CB7"), "build_reply 0x05F0",
        "got %s" % rep.hex())
    chk((0x5A ^ rep[1] ^ rep[2] ^ rep[3] ^ rep[4] ^ rep[5]) == 0, "checksum==0")

    # --- 流分流：遥测帧 + 混在负载里的假 0x5A + 真应答 ---
    tmfake = bytes([0xAA, 0x55, 0x5A, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x99])
    stream = tmfake + bytes([0x5A, 0x01, 0x08, 0x40, 0x08, 0x00]) + rep
    #                          ^ 校验和故意错，应被跳过
    got, scan = find_reply(stream)
    chk(got == rep, "find_reply 跳过遥测帧/坏校验和", "got %s" % (got.hex() if got else None))
    chk(scan == len(stream), "find_reply 扫描位置", "scan=%d len=%d" % (scan, len(stream)))

    # --- 只有遥测时不该找到应答 ---
    got, _ = find_reply(tmfake * 3)
    chk(got is None, "只有遥测时无应答")

    # --- 半包遥测（流从中途开始）仍能找到后面的应答 ---
    got, _ = find_reply(tmfake[7:] + rep)
    chk(got == rep, "半包遥测后仍能找到应答")

    # --- describe 不炸 ---
    for a in DUMP_REGS:
        describe(a, 0x00, 0x00, 0x34)

    print("")
    if fails == 0:
        print("  TEST PASSED (%d checks)" % checks)
        return 0
    print("  TEST FAILED (%d errors / %d checks)" % (fails, checks))
    return 1


# ---------------------------------------------------------------------- main
def main(argv=None):
    try:                      # 控制台可能是 GBK：遇到无法编码的字符降级输出而不是崩溃
        sys.stdout.reconfigure(errors="replace")
        sys.stderr.reconfigure(errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(
        description="用板载 USB 串口(UART->SPI 桥) 读写 FPGA 寄存器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="例子:\n"
               "  python tools/uart_spi.py --port COM7 read 0x05F0\n"
               "  python tools/uart_spi.py --port COM7 write 0x0405 0x0001\n"
               "  python tools/uart_spi.py --port COM7 dump\n")
    ap.add_argument("--selftest", action="store_true", help="不接硬件，自检编解码")
    ap.add_argument("--port", help="串口号，如 COM7（板载 CH340E）")
    ap.add_argument("--baud", type=int, default=BAUD_DEFAULT,
                    help="波特率，默认 %d（与桥/遥测一致）" % BAUD_DEFAULT)
    ap.add_argument("--timeout", type=float, default=0.5, help="单条命令等待应答的秒数")
    ap.add_argument("--retries", type=int, default=3,
                    help="超时自动重发次数，默认 3（2 Mbaud 下实测偶发丢字节）")
    ap.add_argument("--verify", action="store_true",
                    help="写之后回读比对（回读值 = (byte1<<8)|byte0，byte1=reg[addr+1]；"
                         "W1C/自清位寄存器如 0x0405/0x0502 会报不符）")
    ap.add_argument("--file", help="从抓包文件里找应答（离线核对）")
    sub = ap.add_subparsers(dest="cmd")
    p_read = sub.add_parser("read", help="读寄存器")
    p_read.add_argument("addr", nargs="+", help="地址，如 0x05F0 0x053A")
    p_write = sub.add_parser("write", help="写寄存器")
    p_write.add_argument("pairs", nargs="+", help="地址 数据 对，如 0x0109 0x00C0 或 0x0109=0xC0")
    sub.add_parser("dump", help="读一批常用寄存器")
    sub.add_parser("ports", help="列出串口")

    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if args.cmd == "ports":
        return list_ports()
    if args.cmd is None:
        ap.print_help()
        return 2

    if args.file:
        if args.cmd != "read":
            print("--file 只支持 read（离线找应答）")
            return 2
        return find_in_file(args.file, int(args.addr[0], 0))

    if not args.port:
        print("必须给 --port（或用 ports 子命令先列出来）")
        list_ports()
        return 2

    ser = open_port(args.port, args.baud)
    if ser is None:
        return 2
    link = Link(ser, args.baud, retries=args.retries)
    try:
        if args.cmd == "read":
            return do_read(link, [int(a, 0) for a in args.addr], args.timeout)
        if args.cmd == "write":
            return do_write(link, parse_pairs(args.pairs), args.timeout,
                            verify=args.verify)
        if args.cmd == "dump":
            return do_dump(link, args.timeout)
    finally:
        try:
            ser.close()
        except Exception:                          # noqa: BLE001
            pass
    return 2


if __name__ == "__main__":
    sys.exit(main())
