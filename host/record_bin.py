"""二进制遥测记录：把 18 字节原始帧**原样**落盘，比 CSV 小 6 倍、快 10 倍。

为什么要第二个记录格式
----------------------
CSV 那条路是给 Excel 用的：每帧一行、24 列、带中文表头，10 kHz 下 **40 MB/分钟**
——录 10 分钟就是 400 MB，而且写盘时每帧要格式化 24 个字段，GIL 一占，
收包线程就掉帧。二进制这条路是给"事后分析"用的：只写帧本身（18 B/帧 = 10.8 MB/分），
回放时能还原出与现场**逐字节一致**的帧流，CSV/PNG/频谱都可以由它再生成。

文件格式（全小端，定长头 + 元数据 + 定长帧 + 尾）
------------------------------------------------
    0   8s  magic      b"FPGABIN1"
    8   H   version    1
    10  H   frame      18          （帧字节数，写成常量是为了以后能换帧长）
    12  I   flags      1 = 每帧带原始字节
    16  Q   t0_ms      开始时刻（Unix 毫秒，墙钟）
    24  I   fs_hz      10000
    28  I   meta_len   JSON 元数据字节数
    32  I   n_frames   关闭时回填
    36  I   crc32      帧区 CRC32（关闭时回填）
    40  I   reserved   0
    44  ...  保留到 64 字节
    64  meta JSON（utf-8）
    ... 帧区：n_frames × 18 B，**与串口线上字节完全一致**
    末 12 B: b"ENDC" + I crc32 + I n_frames（用于发现"录到一半断电"）

设计约束（改这个文件前先读）
----------------------------
1. 这个模块**不认识帧结构**，只搬字节。解析永远是 `tools/uart_scope.parse_stream`
   的事——一份解析器，避免两套口径慢慢漂移。
2. 写盘失败绝不能让界面崩：`write*` 内部 try/except，第一次失败记进 `self.last_error`
   并进入"只读状态"，之后的调用直接返回 0。
3. 帧必须按顺序写，但**允许一次写多帧**（`write_raw` 收 bytes），这样 link 线程可以
   自己攒批，不必每帧调一次 Python。
4. `n_frames`/`crc32` 是关闭时回填的；没正常关闭的文件靠尾部 `ENDC` 判断完整性，
   `read_frames()` 遇到缺尾会抛 `Truncated`——宁可报错，也不要静默给出半份数据。
"""

from __future__ import annotations

import json
import os
import struct
import time
import zlib

MAGIC = b"FPGABIN1"
VERSION = 1
FRAME_BYTES = 18
_HDR = struct.Struct("<8sHHIQIIIII")          # 44 字节
_HDR_PAD = 64 - _HDR.size
_TAIL = struct.Struct("<4sII")
TAIL_MAGIC = b"ENDC"


class Truncated(Exception):
    """文件没有正常关闭（缺尾标记），或帧区长度不是帧长的整数倍。"""


def _now_ms():
    return int(time.time() * 1000)


class BinRecorder(object):
    """顺序写 18 字节原始帧。线程内使用（不做锁，一行程一实例）。"""

    def __init__(self, path, fs_hz=10000, meta=None):
        self.path = os.path.abspath(path)
        self.fs_hz = int(fs_hz)
        self.meta = dict(meta or {})
        self.n_frames = 0
        self.n_bytes = 0
        self.last_error = None
        self._crc = 0
        self._fh = None
        self._meta_len = 0
        self._t0 = _now_ms()
        self._open()

    # ------------------------------------------------------------- 内部
    def _open(self):
        mb = json.dumps(self.meta, ensure_ascii=False).encode("utf-8")
        self._meta_len = len(mb)
        # 先写占位头（n_frames/crc 关闭时回填）
        head = _HDR.pack(MAGIC, VERSION, FRAME_BYTES, 1, self._t0,
                         self.fs_hz, self._meta_len, 0, 0, 0)
        head += b"\0" * _HDR_PAD
        self._fh = open(self.path, "wb")
        self._fh.write(head)
        self._fh.write(mb)

    def _fail(self, exc):
        if self.last_error is None:
            self.last_error = "%s: %s" % (type(exc).__name__, exc)
        try:
            self._fh.close()
        except Exception:                                        # noqa: BLE001
            pass
        self._fh = None

    # ------------------------------------------------------------- 写
    def write_raw(self, chunk):
        """写一段原始帧字节（长度必须是 18 的整数倍）。返回写入帧数。"""
        if self._fh is None:
            return 0
        if not chunk:
            return 0
        n = len(chunk)
        if n % FRAME_BYTES:
            # 半个帧绝不写进去：宁可丢这一次，也不要让整个文件错位。
            # ★ 这只拒掉本次数据，**不关文件**——错对齐的是调用方，不是磁盘；
            #   把它当成致命错会让整个记录文件作废（自检最初就是这么炸的）。
            if self.last_error is None:
                self.last_error = "帧字节数 %d 不是 %d 的整数倍（本次数据被丢弃）" \
                                  % (n, FRAME_BYTES)
            return 0
        try:
            self._fh.write(chunk)
        except Exception as exc:                                 # noqa: BLE001
            self._fail(exc)
            return 0
        self._crc = zlib.crc32(chunk, self._crc)
        k = n // FRAME_BYTES
        self.n_frames += k
        self.n_bytes += n
        return k

    def write_frames(self, frames):
        """写一批帧 dict（用其中的 'raw' 字段；缺 raw 的帧跳过）。"""
        buf = bytearray()
        for f in frames or ():
            raw = f.get("raw") if isinstance(f, dict) else None
            if raw and len(raw) == FRAME_BYTES:
                buf.extend(raw)
        return self.write_raw(bytes(buf))

    # ------------------------------------------------------------- 收尾
    def close(self):
        """回填头里的帧数与 CRC，再写尾。可重复调用。"""
        if self._fh is None:
            return False
        try:
            self._fh.write(_TAIL.pack(TAIL_MAGIC, self._crc & 0xFFFFFFFF,
                                      self.n_frames & 0xFFFFFFFF))
            self._fh.seek(0)
            head = _HDR.pack(MAGIC, VERSION, FRAME_BYTES, 1, self._t0,
                             self.fs_hz, self._meta_len,
                             self.n_frames & 0xFFFFFFFF,
                             self._crc & 0xFFFFFFFF, 0)
            self._fh.write(head)
            self._fh.close()
        except Exception as exc:                                 # noqa: BLE001
            self._fail(exc)
            return False
        self._fh = None
        return True

    def stats(self, t_mono=None):
        return {"path": self.path, "n": self.n_frames, "bytes": self.n_bytes,
                "sec": self.n_frames / float(self.fs_hz or 1),
                "error": self.last_error, "open": self._fh is not None}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


# ----------------------------------------------------------------- 读
def data_offset(path):
    """帧区起始偏移 = 64 + meta_len（回放器要知道从哪开始读）。"""
    with open(path, "rb") as f:
        head = f.read(64)
        if len(head) < 64:
            raise Truncated("文件头不完整")
        (_magic, _ver, _fb, _fl, _t0, _fs, meta_len, _n, _c, _r) = \
            _HDR.unpack(head[:_HDR.size])
    return 64 + meta_len


def read_meta(path):
    """只读文件头与元数据，不搬帧区（回放器先看这个）。"""
    with open(path, "rb") as f:
        head = f.read(64)
        if len(head) < 64:
            raise Truncated("文件头不完整")
        (magic, ver, frame, flags, t0, fs, meta_len,
         n_frames, crc, _res) = _HDR.unpack(head[:_HDR.size])
        if magic != MAGIC:
            raise ValueError("不是本程序的二进制记录（magic=%r）" % magic)
        if ver != VERSION:
            raise ValueError("版本 %d 不认识（本程序只认 %d）" % (ver, VERSION))
        mb = f.read(meta_len)
    meta = {}
    if mb:
        try:
            meta = json.loads(mb.decode("utf-8"))
        except Exception:                                        # noqa: BLE001
            meta = {}
    return {"version": ver, "frame_bytes": frame, "flags": flags,
            "t0_ms": t0, "fs_hz": fs, "n_frames": n_frames,
            "crc32": crc, "meta": meta, "size": os.path.getsize(path)}


def read_frames(path, offset=0, limit=None):
    """按顺序产出原始帧 bytes。默认校验尾部与 CRC。"""
    with open(path, "rb") as f:
        head = f.read(64)
        if len(head) < 64:
            raise Truncated("文件头不完整")
        _magic, _ver, fb, _flags, _t0, _fs, meta_len, _n_hdr, crc, _r = \
            _HDR.unpack(head[:_HDR.size])
        f.seek(64 + meta_len)
        data_at = 64 + meta_len
        size = os.path.getsize(path)
        body = size - data_at - _TAIL.size
        if body < 0 or body % fb:
            raise Truncated("帧区 %d 字节不是 %d 的整数倍（文件被截断？）"
                            % (body, fb))
        n = body // fb
        if offset:
            f.seek(data_at + offset * fb)
        left = n - offset if limit is None else min(limit, n - offset)
        read = 0
        # ★ 一次读的字节数必须是帧长的整数倍，否则 chunk 尾上会剩半个帧、
        #   下一块又从错位的地方读（自检最初就是这么少数了 62 帧）。
        step = 8192 * fb
        while read < left:
            chunk = f.read(min(step, (left - read) * fb))
            if not chunk:
                break
            for i in range(0, len(chunk) - fb + 1, fb):
                yield chunk[i:i + fb]
                read += 1
        if offset == 0 and limit is None:
            f.seek(data_at + body)
            tail = f.read(_TAIL.size)
            if len(tail) < _TAIL.size or tail[:4] != TAIL_MAGIC:
                raise Truncated("缺尾部标记：这次记录没有正常结束（可能断电/强退）")
            _m, tcrc, tn = _TAIL.unpack(tail)
            if tn != n:
                raise Truncated("尾标记记 %d 帧、实际 %d 帧" % (tn, n))
            if tcrc != (crc & 0xFFFFFFFF):
                raise Truncated("帧区 CRC 不符（文件被改过或写盘出错）")


def to_csv(path, out_path=None, raw_hex=True):
    """把二进制记录转成 CSV（列与 recorder.py 的 CSV 保持一致的前两列）。"""
    out_path = out_path or (os.path.splitext(path)[0] + "_from_bin.csv")
    n = 0
    with open(out_path, "w", encoding="utf-8-sig", newline="") as f:
        f.write("序号,原始18字节\r\n" if raw_hex else "序号\r\n")
        for i, fr in enumerate(read_frames(path)):
            f.write("%d,%s\r\n" % (i, fr.hex() if raw_hex else ""))
            n += 1
    return out_path, n


# --------------------------------------------------------------- 自检
def selftest():
    import shutil
    import tempfile

    def mk(i):
        # 造一条合法帧形状的 18 字节（内容不重要，这个模块只搬字节）
        return bytes([0xAA, 0x55]) + i.to_bytes(4, "little") + bytes(12)

    ok_all = True
    n_ok = [0]

    def ck(name, cond):
        nonlocal ok_all
        n_ok[0] += 1
        if cond:
            print("  %-46s PASS" % name)
        else:
            ok_all = False
            print("  %-46s FAIL" % name)

    d = tempfile.mkdtemp(prefix="recbin_")
    try:
        p = os.path.join(d, "a.bin")
        rec = BinRecorder(p, fs_hz=10000, meta={"port": "COM3", "baud": 2000000})
        frames = [{"raw": mk(i), "s": i} for i in range(5000)]
        rec.write_frames(frames[:3000])
        rec.write_raw(b"".join(mk(i) for i in range(3000, 5000)))
        k = rec.write_raw(mk(1)[:17])                 # 半个帧必须被拒
        rec.close()
        ck("帧数 = 5000", rec.n_frames == 5000)
        ck("半帧被拒绝", k == 0 and rec.last_error is not None)
        info = read_meta(p)
        ck("头里回填的帧数", info["n_frames"] == 5000)
        ck("元数据往返", info["meta"].get("port") == "COM3")
        meta_len = len(json.dumps({"port": "COM3", "baud": 2000000},
                                  ensure_ascii=False).encode("utf-8"))
        ck("文件长度 = 64+meta+18n+12",
           info["size"] == 64 + meta_len + 18 * 5000 + 12)
        got = list(read_frames(p))
        ck("回读帧数", len(got) == 5000)
        ck("逐字节一致", all(got[i] == mk(i) for i in range(5000)))
        ck("按偏移读", list(read_frames(p, offset=4990, limit=10))[0] == mk(4990))
        csv, n = to_csv(p, os.path.join(d, "a.csv"))
        ck("转 CSV 行数", n == 5000)

        # 截断：砍掉尾部 20 字节
        q = os.path.join(d, "b.bin")
        shutil.copy(p, q)
        with open(q, "r+b") as f:
            f.truncate(os.path.getsize(q) - 20)
        try:
            list(read_frames(q))
            ck("截断文件应当报错", False)
        except Truncated:
            ck("截断文件应当报错", True)
        except Exception as exc:                             # noqa: BLE001
            ck("截断文件应当报错（%s）" % type(exc).__name__, False)

        # 写入速度：50 万帧 = 50 s 遥测
        r = os.path.join(d, "c.bin")
        big = [{"raw": mk(i % 65536)} for i in range(1000)]
        r2 = BinRecorder(r)
        t0 = time.perf_counter()
        for _ in range(500):
            r2.write_frames(big)
        r2.close()
        dt = time.perf_counter() - t0
        mb = r2.n_bytes / 1e6
        ck("50 万帧写盘 < 2 s（实 %.2f s，%.0f MB/s）" % (dt, mb / max(dt, 1e-9)),
           dt < 2.0)
        ck("50 万帧 = 9.0 MB", abs(mb - 9.0) < 0.1)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    print("自检%s（%d 项）" % ("通过 (PASS)" if ok_all else "失败", n_ok[0]))
    return 0 if ok_all else 1


def main(argv=None):
    import sys
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--selftest" in argv:
        return selftest()
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "info" and len(argv) > 1:
        info = read_meta(argv[1])
        print(json.dumps(info, ensure_ascii=False, indent=2))
        return 0
    if cmd == "csv" and len(argv) > 1:
        out, n = to_csv(argv[1], argv[2] if len(argv) > 2 else None)
        print("%s（%d 帧）" % (out, n))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
