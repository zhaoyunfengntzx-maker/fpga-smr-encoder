"""抓包链路的离线自检（不需要板子、不需要串口）。

跑：`python host/selftest_capture.py`

覆盖三件最容易出错的事：
  1. 264 B 块的拼装 —— 块下标归位、缺块补 0、XOR/头/长度校验；
  2. 串口 dump 解析器（link.SerialWorker._pump_dump）—— 分片到达、
     夹杂命令应答、尾部残留字节要还给遥测解析器；
  3. 导出（CSV 列数/行数）与采样率换算。
"""

from __future__ import annotations

import os
import struct
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import capture as cap          # noqa: E402
import link as lk              # noqa: E402

_checks = 0
_errors = 0


def chk(cond, name):
    global _checks, _errors
    _checks += 1
    if not cond:
        _errors += 1
        print("  [FAIL] %s" % name)


def eq8(name, got, exp):
    global _checks, _errors
    _checks += 1
    if got != exp:
        _errors += 1
        print("  [FAIL] %s: got %r exp %r" % (name, got, exp))


def make_block(idx, s_vals, c_vals=None):
    """按 rtl/scope_dump.v 的格式造一块：头 7 B + 4 B/点 + XOR。"""
    n = len(s_vals)
    if c_vals is None:
        c_vals = [v + 1000 for v in s_vals]
    body = bytearray()
    body += cap.DUMP_HEAD
    body += bytes((idx & 0xFF, (idx >> 8) & 0xFF, n & 0xFF))
    for i in range(n):
        body += struct.pack("<hh", s_vals[i], c_vals[i])
    x = 0
    for b in body:
        x ^= b
    body.append(x)
    return bytes(body)


def test_blocks():
    print("\n[A] 块拼装 / 缺块 / 校验")
    blocks = [make_block(i, [i * 64 + k for k in range(64)]) for i in range(3)]
    data = cap.reassemble(blocks, expect_blocks=3)
    eq8("块数", data["n_blocks"], 3)
    eq8("缺块", data["missing"], [])
    eq8("第 0 点", data["s"][0], 0)
    eq8("第 127 点", data["s"][127], 127)
    eq8("第 191 点 c", data["c"][191], 191 + 1000)

    # 丢掉第 1 块：该段补 0 并报告
    data2 = cap.reassemble([blocks[0], blocks[2]], expect_blocks=3)
    eq8("缺块报告", data2["missing"], [1])
    eq8("缺块段补 0", data2["s"][64], 0)
    eq8("缺块后段仍归位", data2["s"][128], 128)

    # 校验失败
    bad = bytearray(blocks[0])
    bad[-1] ^= 0xFF
    try:
        cap.parse_block(bytes(bad))
        chk(False, "XOR 错应当抛异常")
    except cap.CaptureError:
        chk(True, "XOR 错抛异常")
    try:
        cap.parse_block(b"\xAA\x55\x00\x00" + blocks[0][4:])
        chk(False, "块头错应当抛异常")
    except cap.CaptureError:
        chk(True, "块头错抛异常")
    try:
        cap.parse_block(blocks[0][:-3])
        chk(False, "长度错应当抛异常")
    except cap.CaptureError:
        chk(True, "长度错抛异常")

    # 采样率换算
    eq8("50 MSPS", cap.fs_for(0, 0), 50.0e6)
    eq8("25 MSPS", cap.fs_for(0, 1), 25.0e6)
    eq8("校正 12.5/4", cap.fs_for(1, 2), 12.5e6 / 4)


def test_dump_parser():
    print("\n[B] 串口 dump 解析器（分片 / 夹杂应答 / 残留）")
    w = lk.SerialWorker("COM_TEST")          # 不 start()：只喂字节，不碰真串口
    blocks = [make_block(i, [i * 64 + k for k in range(64)]) for i in range(3)]

    # 应答（6 B，XOR=0）+ 三块，故意在块中间切开发送
    rep = bytes((0x5A, 0x00, 0x18, 0x00, 0x0D, 0x5A ^ 0x18 ^ 0x0D))
    stream = rep + b"".join(blocks) + b"\xAA\x55"      # 尾部 2 字节残帧
    with w._dump_lock:
        w._dump_mode = True
        w._dump_want = 3
        w._dump_blocks = []
        w._dump_buf = bytearray()
        w._dump_done.clear()

    # 简化：按不等长切片喂
    pos = 0
    sizes = (1, 5, 100, 200, 400, 800)
    i = 0
    leftover = rep + b"".join(blocks) + b"\xAA\x55"
    while pos < len(leftover):
        n = sizes[i % len(sizes)]
        w._pump_dump(leftover[pos:pos + n])
        pos += n
        i += 1
        if w._dump_done.is_set():
            break

    chk(w._dump_done.is_set(), "收到 3 块后应当结束 dump 模式")
    eq8("收到的块数", len(w._dump_blocks), 3)
    eq8("应答被收下", len(w._replies), 1)
    chk(not w._dump_mode, "结束后应退出 dump 模式")
    # 尾部 2 字节还给普通解析器
    chk(bytes(w.buf) == b"\xAA\x55", "残留字节要还给遥测解析器（实际 %r）" % bytes(w.buf))

    data = cap.reassemble(w._dump_blocks, expect_blocks=3)
    eq8("解析后第 100 点", data["s"][100], 100)


def test_export():
    print("\n[C] 导出")
    res = cap.CaptureResult(list(range(100)), [v + 5 for v in range(100)],
                            {"src": 0, "dec_log2": 1, "trig_idx": 10}, n_blocks=2)
    chk(abs(res.fs - 25.0e6) < 1.0, "fs 取自 dec_log2")
    chk(abs(res.duration_s - 100 / 25.0e6) < 1e-12, "窗口时长")
    t = res.time_axis()
    chk(abs(t[10]) < 1e-12 and t[0] < 0, "时间轴以触发点为 0")
    fp = os.path.join(tempfile.gettempdir(), "_selftest_capture.csv")
    res.to_csv(fp)
    with open(fp, "r", encoding="utf-8-sig") as fh:
        lines = fh.read().strip().split("\n")
    eq8("CSV 行数", len(lines), 101)
    chk(lines[0] == "t_us,s,c", "CSV 表头")
    os.remove(fp)


def main():
    test_blocks()
    test_dump_parser()
    test_export()
    print("\n%d checks, %d errors" % (_checks, _errors))
    if _errors == 0:
        print(" TEST PASSED")
        return 0
    print(" TEST FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
