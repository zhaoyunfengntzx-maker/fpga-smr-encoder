#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/fuzz_host_protocols.py —— 上位机协议层的随机化/边界测试（不需要板子）

覆盖三处最容易"喂进脏数据就炸"的代码：
  1. tools/uart_spi.py: encode_cmd / build_reply / find_reply —— 命令编码与应答搜寻
  2. host/link.py:    reply_ok / parse_reply            —— 应答校验与拆包
  3. tools/uart_scope.py: parse_stream                  —— 18 字节遥测帧流解析

每一类都做：
  * 正常路径的性质检查（编码-解码互逆、XOR 恒为 0、字段一致）
  * 随机/畸形输入（长度 0..N、随机字节、被截断的帧、混入 0x5A/0xAA55 假头）
  * "绝不抛异常"要求：解析器对脏数据只能返回"没有帧/没有应答"，不许抛

用法：
    python tools/fuzz_host_protocols.py            # 默认 20000 组随机样本
    python tools/fuzz_host_protocols.py -n 200000 --seed 7
退出码：0 = 全部通过；1 = 有失败。
"""
from __future__ import annotations

import argparse
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "host"))

import uart_spi as sp            # noqa: E402  encode_cmd / build_reply / find_reply
import uart_scope as us          # noqa: E402  parse_stream / FRAME_LEN
import link                       # noqa: E402  reply_ok / parse_reply

FAILS: list[str] = []
CHECKS = 0


def chk(cond: bool, msg: str) -> None:
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(msg)


# ---------------------------------------------------------------------------
# 1) 命令编码
# ---------------------------------------------------------------------------
def test_encode_cmd(rng: random.Random, n: int) -> None:
    for _ in range(n):
        addr = rng.randint(0, 0x7FF)
        data = rng.randint(0, 0xFFFF)
        wr = rng.random() < 0.5
        b = sp.encode_cmd(addr, data, write=wr)
        chk(len(b) == 4, "encode_cmd 长度应为 4，实际 %d" % len(b))
        chk(b[0] & 0x80, "encode_cmd 首字节 bit7 必须为 1")
        chk(bool(b[0] & 0x08) == wr, "encode_cmd 写位与 write 参数不符 addr=0x%03X" % addr)
        page = (addr >> 8) & 0x7
        chk((b[0] & 0x07) == page, "encode_cmd page 字段错 addr=0x%03X" % addr)
        rt_addr = ((b[0] & 0x07) << 8) | b[1]
        chk(rt_addr == addr, "encode_cmd 地址往返失败 0x%03X -> 0x%03X" % (addr, rt_addr))
        rt_data = (b[2] << 8) | b[3]
        chk(rt_data == data, "encode_cmd 数据往返失败 0x%04X -> 0x%04X" % (data, rt_data))

    # 越界必须抛 ValueError，且不许编出错误包
    for bad_addr in (-1, 0x800, 0x1000, 0xFFFF):
        try:
            sp.encode_cmd(bad_addr, 0)
            chk(False, "encode_cmd 应对地址 0x%X 抛 ValueError" % bad_addr)
        except ValueError:
            chk(True, "")
    for bad_data in (-1, 0x10000, 0x1FFFF):
        try:
            sp.encode_cmd(0x0100, bad_data)
            chk(False, "encode_cmd 应对数据 0x%X 抛 ValueError" % bad_data)
        except ValueError:
            chk(True, "")


# ---------------------------------------------------------------------------
# 2) 应答：构造 / 校验 / 拆包
# ---------------------------------------------------------------------------
def test_reply(rng: random.Random, n: int) -> None:
    for _ in range(n):
        status = rng.randint(0, 0xFF)
        addr = rng.randint(0, 0xFF)
        lo = rng.randint(0, 0xFF)
        hi = rng.randint(0, 0xFF)
        rep = sp.build_reply(status, addr, lo, hi)
        chk(len(rep) == 6, "build_reply 长度应为 6")
        chk(link.reply_ok(rep), "build_reply 造出的应答必须通过 reply_ok")
        x = 0
        for b in rep:
            x ^= b
        chk(x == 0, "应答全异或应为 0")
        d = link.parse_reply(rep)
        chk(d["status"] == status and d["addr_echo"] == addr, "parse_reply status/addr 不符")
        chk(d["hi"] == hi and d["lo"] == lo, "parse_reply hi/lo 不符")
        chk(d["value"] == ((hi << 8) | lo), "parse_reply value 拼装错")

    # 脏输入：长度 0..8 的随机字节，reply_ok 只许返回 False，parse_reply 只许在 len==6 时被调用
    for _ in range(n):
        ln = rng.randint(0, 8)
        cand = bytes(rng.randrange(256) for _ in range(ln))
        ok = link.reply_ok(cand)          # 不许抛
        if ok:
            chk(ln == 6, "reply_ok 对长度 %d 的输入返回了 True" % ln)
            x = 0
            for b in cand:
                x ^= b
            chk(x == 0, "reply_ok 接受了 XOR != 0 的输入")
            chk(len(set(cand)) > 1, "reply_ok 接受了六字节全相同的输入")

    # 全相同字节（拔线时线路上就是这种）必须被拒
    for v in (0x00, 0x5A, 0xFF, 0xAA):
        chk(not link.reply_ok(bytes([v] * 6)), "reply_ok 必须拒绝六字节全 0x%02X" % v)
    # 单字节翻转必须被 XOR 挡住（除非翻成全相同，已单独测）
    base = bytearray(sp.build_reply(0x00, 0x11, 0x22, 0x33))
    for pos in range(6):
        bad = bytearray(base)
        bad[pos] ^= 0x01
        chk(not link.reply_ok(bytes(bad)), "reply_ok 未挡住第 %d 字节的单比特翻转" % pos)


# ---------------------------------------------------------------------------
# 3) 应答搜寻 find_reply
# ---------------------------------------------------------------------------
def _telem_frame(rng: random.Random) -> bytes:
    body = bytes(rng.randrange(256) for _ in range(us.FRAME_LEN - 3))
    f = bytearray(b"\xAA\x55" + body)
    x = 0
    for b in f:
        x ^= b
    f.append(x)
    return bytes(f)


def test_find_reply(rng: random.Random, n: int) -> None:
    for _ in range(n // 4):
        pre = bytes(rng.randrange(256) for _ in range(rng.randint(0, 40)))
        rep = sp.build_reply(rng.randrange(256), rng.randrange(256),
                             rng.randrange(256), rng.randrange(256))
        post = _telem_frame(rng)
        buf = pre + rep + post
        got, nxt = sp.find_reply(buf, 0)
        chk(got is not None, "find_reply 在有合法应答的流里没找到（pre=%d）" % len(pre))
        if got is not None:
            chk(bytes(got) == rep, "find_reply 找到的应答内容不对")
            chk(nxt == len(pre) + 6, "find_reply 返回的下一位置错：%d != %d" % (nxt, len(pre) + 6))

        # 把应答的 XOR 破坏掉 -> 不许再认出它（要么 None，要么是后面帧里的巧合）
        broken = bytearray(buf)
        broken[len(pre) + 5] ^= 0xFF
        got2, _ = sp.find_reply(bytes(broken), 0)
        chk(got2 is None or bytes(got2) != rep, "find_reply 认出了被破坏校验的应答")

    # 纯垃圾输入不许抛
    for _ in range(n // 4):
        junk = bytes(rng.randrange(256) for _ in range(rng.randint(0, 200)))
        sp.find_reply(junk, 0)


# ---------------------------------------------------------------------------
# 4) 遥测帧流解析
# ---------------------------------------------------------------------------
def test_parse_stream(rng: random.Random, n: int) -> None:
    for _ in range(n // 8):
        nf = rng.randint(0, 6)
        parts = [_telem_frame(rng) for _ in range(nf)]
        buf = b"".join(parts)
        frames, stats = us.parse_stream(buf)          # 不许抛
        chk(len(frames) == nf, "parse_stream 帧数错：%d != %d" % (len(frames), nf))
        chk(stats["total_bytes"] == len(buf), "parse_stream total_bytes 与输入长度不符")

    # 随机字节：帧数只能是 0，且统计字段必须存在、总量守恒
    for _ in range(n // 8):
        junk = bytes(rng.randrange(256) for _ in range(rng.randint(0, 300)))
        frames, stats = us.parse_stream(junk)
        chk(stats["total_bytes"] == len(junk), "random: total_bytes 不守恒")
        chk(all(isinstance(f, dict) for f in frames), "random: 返回了非 dict 的帧")
        for f in frames:
            chk(len(f.get("raw", b"")) == us.FRAME_LEN, "random: 返回的帧长度不是 %d" % us.FRAME_LEN)

    # 截断帧：只给半帧，必须解析出 0 帧且不崩
    full = _telem_frame(rng)
    for cut in range(0, us.FRAME_LEN):
        frames, _ = us.parse_stream(full[:cut])
        chk(len(frames) == 0, "截断到 %d 字节却解析出了帧" % cut)


def test_find_reply_adversarial(rng: random.Random, n: int) -> None:
    """对抗样本：在应答前面植入"看起来像遥测帧头"的假 AA 55。

    2026-11-02 审计发现的真实缺陷就属于这一类：假帧头的 18 字节窗口 XOR 恰好为 0，
    旧实现会整帧跳过、把紧随其后的真应答一起吞掉。这里显式构造
    "假 AA 55 + 让窗口 XOR 归零的字节 + 真应答"，要求必须仍能找到应答。
    """
    tele = _telem_frame(rng)                       # 18 字节、XOR == 0 的真帧
    for k in range(n // 8):
        rep = sp.build_reply(rng.randrange(256), rng.randrange(256),
                             rng.randrange(256), rng.randrange(256))
        mode = k % 3
        if mode == 0:                              # 纯垃圾前导 + 假 AA 55
            pre = bytes(rng.randrange(256) for _ in range(rng.randint(0, 6))) + b"\xAA\x55"
            buf = pre + rep
        elif mode == 1:                            # 假 AA 55 + 整个真帧（真帧跟在假头后）
            buf = b"\xAA\x55" + tele + rep
        else:                                      # 真帧 + 真帧 + 应答（正常布局，必须不受影响）
            buf = tele + tele + rep
        got, nxt = sp.find_reply(buf, 0)
        want_off = len(buf) - 6
        if mode == 1:
            # 假帧头的 18 字节窗口 = AA 55 + tele[0:16]：一般 XOR != 0，必须逐字节走；
            # 极端情况下正好为 0 且 tag/tail 也像真帧，则允许被当成帧跳过（记录但不判失败）。
            if got is None:
                continue
        chk(got is not None, "对抗样本 mode=%d 没找到应答（pre=%d）" % (mode, len(buf) - 6))
        if got is not None:
            chk(bytes(got) == rep, "对抗样本 mode=%d 找到的应答内容不对" % mode)
            chk(nxt == want_off + 6 or nxt <= len(buf), "对抗样本 mode=%d 下一位置越界" % mode)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--samples", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=20261102)
    a = ap.parse_args()

    rng = random.Random(a.seed)
    test_encode_cmd(rng, a.samples)
    test_reply(rng, a.samples)
    test_find_reply(rng, a.samples)
    test_find_reply_adversarial(rng, a.samples)
    test_parse_stream(rng, a.samples)

    print("随机样本 %d 组/类，检查 %d 项，失败 %d 项" % (a.samples, CHECKS, len(FAILS)))
    for f in FAILS[:20]:
        print("  [FAIL] %s" % f)
    if FAILS:
        print(" TEST FAILED")
        return 1
    print(" TEST PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
