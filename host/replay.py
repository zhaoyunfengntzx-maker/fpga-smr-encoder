"""记录回放：把 `.bin` 里的原始帧按 10 kHz 的节奏重新喂给界面。

为什么要有它
------------
现场出一次问题，最贵的一步是"复现"。录回来的 CSV 只能看数字，`.bin` 能**原样**
重建当时那串帧——但没人在界面上按播放键的话，和看文本没区别。这个模块就是播放器：
按 100 ms 一批（= 1000 帧）往外吐帧，界面用与在线完全相同的解析结果去画波形、
算正交质量、跑告警状态机，于是"昨天的现场"能在今天的屏幕上重放一遍。

设计约束（改这个文件前先读）
----------------------------
1. 解析**绝不自己写第二套**：一律走 `uart_scope.parse_stream`（与在线链路同一个
   函数），否则回放和在线会慢慢分叉，出了差异没人说得清是谁错。
2. 只顺序读、不整文件入内存：10 分钟记录 60 万帧，做成 dict 列表要几百 MB。
3. 坏帧**跳过但计数**（`crc_err`），不当作结束——现场录的东西允许有坏块。
4. 节奏由调用方定（`next_batch()` 一次给一批），模块自己不认识 QTimer。
"""

from __future__ import annotations

import os
import sys

import record_bin as rb


def _ensure_tools():
    """把 tools/ 加进 sys.path（uart_scope.py 是协议权威实现，不复制一份）。"""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = []
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        cands.append(os.path.join(os.path.dirname(os.path.abspath(sys.executable)),
                                  "tools"))
    cands += [os.path.join(os.path.dirname(here), "tools"),
              os.path.join(here, "tools")]
    for c in cands:
        if c and os.path.isdir(c):
            if c not in sys.path:
                sys.path.insert(0, c)
            return c
    return None


_ensure_tools()

try:                                    # 打包后 uart_scope 在 _internal 里
    import uart_scope as us
except Exception:                       # noqa: BLE001
    us = None


BATCH_FRAMES = 1000                     # 100 ms @ 10 kHz


def _raw_records(buf):
    """从一段字节里挑出合法帧，返回 [bytes]（与 parse_stream 的顺序一致）。"""
    out = []
    fb = rb.FRAME_BYTES
    for i in range(0, len(buf) - fb + 1, fb):
        rec = buf[i:i + fb]
        if rec[0] != 0xAA or rec[1] != 0x55:
            continue
        if us is not None:
            if us.frame_checksum(rec[2:17]) != rec[17]:
                continue
        out.append(rec)
    return out


def parse_bytes(buf):
    """原始字节 → (frames, stats)。frames 里带 `raw`，与在线链路的口径一致。"""
    if us is None:
        return [], {"frames": 0, "crc_err": 0, "reason": "uart_scope 不可用"}
    frames, stats = us.parse_stream(buf)
    raws = _raw_records(buf)
    for f, r in zip(frames, raws):
        f["raw"] = r
    return frames, stats


class Replayer(object):
    """顺序播放一个 `.bin`。线程内使用。"""

    def __init__(self, path, batch_frames=BATCH_FRAMES):
        self.path = os.path.abspath(path)
        self.batch_frames = max(1, int(batch_frames))
        self.info = rb.read_meta(self.path)
        self.n_total = self.info["n_frames"]
        self.n_played = 0
        self.n_lost = 0
        self.done = False
        self.error = None
        self._fh = open(self.path, "rb")
        self._fh.seek(rb.data_offset(self.path))
        self._leftover = b""

    # --------------------------------------------------------------- 播放
    def next_batch(self):
        """取下一批帧（list）。返回 [] 表示放完了。"""
        if self.done:
            return []
        buf = self._leftover
        self._leftover = b""
        want = self.batch_frames * rb.FRAME_BYTES - len(buf)
        try:
            chunk = self._fh.read(max(0, want))
        except Exception as exc:                                 # noqa: BLE001
            self.error = str(exc)
            self.done = True
            return []
        if not chunk and not buf:
            self.done = True
            return []
        buf += chunk
        frames, stats = parse_bytes(buf)
        n_rec = len(buf) // rb.FRAME_BYTES
        used = n_rec * rb.FRAME_BYTES
        self._leftover = buf[used:]
        self.n_played += len(frames)
        self.n_lost += max(0, n_rec - len(frames))
        if self.n_played >= self.n_total or (not chunk):
            self.done = True
        return frames

    def close(self):
        try:
            self._fh.close()
        except Exception:                                        # noqa: BLE001
            pass

    def stats(self):
        return {"path": self.path, "played": self.n_played, "total": self.n_total,
                "lost": self.n_lost, "done": self.done, "error": self.error,
                "sec": self.n_played / 10000.0,
                "meta": self.info.get("meta") or {}}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def load_all(path):
    """整份读进内存（只给自检/命令行小文件用，界面走 Replayer）。"""
    frames, stats = [], {}
    r = Replayer(path, batch_frames=100000)
    while True:
        b = r.next_batch()
        if not b:
            break
        frames.extend(b)
    stats = r.stats()
    r.close()
    return frames, stats


# --------------------------------------------------------------- 自检
def selftest():
    import shutil
    import tempfile

    ok_all = True
    n = [0]

    def ck(name, cond):
        nonlocal ok_all
        n[0] += 1
        print("  %-44s %s" % (name, "PASS" if cond else "FAIL"))
        ok_all = ok_all and cond

    if us is None:
        print("  uart_scope 不可用，跳过")
        return 1

    d = tempfile.mkdtemp(prefix="replay_")
    try:
        p = os.path.join(d, "r.bin")
        rec = rb.BinRecorder(p, fs_hz=10000, meta={"t": "selftest"})
        recs = []
        for i in range(3000):
            b = us.build_frame(angle=(i * 7) & 0xFFFF, s_n=(i % 1000) - 500,
                               c_n=1000 - (i % 800), io_state=(i & 3),
                               io_flags=(i & 0x81), pos_full=i, stat=(i & 1))
            recs.append(b)
        for i in range(0, 3000, 500):
            rec.write_raw(b"".join(recs[i:i + 500]))
        rec.close()

        r = Replayer(p, batch_frames=1000)
        ck("总帧数从文件头读出", r.n_total == 3000)
        got = []
        first = None
        while True:
            b = r.next_batch()
            if not b:
                break
            if first is None:
                first = len(b)
            got.extend(b)
        ck("每批 ≤1000 帧", first is not None and first <= 1000)
        ck("回放帧数 = 3000", len(got) == 3000)
        ck("事件里带 raw（18 B）", all(len(f.get("raw") or b"") == 18 for f in got))
        ck("字段解码正确", got[123]["angle"] == (123 * 7) & 0xFFFF
           and got[123]["s"] == (123 % 1000) - 500)
        ck("raw 与重放字节一致", got[0]["raw"] == recs[0] and got[2999]["raw"] == recs[2999])
        ck("结束标志", r.done)

        # 坏帧：把第 100 帧的校验改坏，应当少 1 帧并记账
        q = os.path.join(d, "bad.bin")
        shutil.copy(p, q)
        with open(q, "r+b") as f:
            f.seek(rb.data_offset(q) + 100 * 18 + 17)
            f.write(bytes([0x00]))
        r2 = Replayer(q, batch_frames=100000)
        frames2, _ = [], None
        while True:
            b = r2.next_batch()
            if not b:
                break
            frames2.extend(b)
        ck("坏帧被跳过（2999）", len(frames2) == 2999)
        ck("坏帧记进 lost", r2.n_lost == 1)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    print("自检%s（%d 项）" % ("通过 (PASS)" if ok_all else "失败", n[0]))
    return 0 if ok_all else 1


def main(argv=None):
    import json
    import sys
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--selftest" in argv:
        return selftest()
    if not argv:
        print(__doc__)
        return 2
    path = argv[0]
    r = Replayer(path)
    print(json.dumps(r.info, ensure_ascii=False, indent=2))
    n = 0
    while True:
        b = r.next_batch()
        if not b:
            break
        n += len(b)
    print("回放完成：%d/%d 帧，坏 %d" % (n, r.n_total, r.n_lost))
    r.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
