"""抓包（B1）：把 0x072E 批量 dump 的字节块拼回两条通道的样点序列。

这一层不碰 Qt、也不开串口 —— 只做"协议 → 数组"的翻译，方便用
`tools/cap_dump.py` 在台架上单独验证（不启动界面也能抓波形）。

数据链路（详见 docs/17_ethernet_capture_plan.md）：

    上位机 write 0x0718..0x0720（源/长度/触发/电平/预触发）
      → write 0x0722 = 0x0001（arm）
      → 板子采满窗口，CAP_STATUS.done=1
      → write 0x072E = 0x0001（dump start）
      → 板子按 264 B/块推流：AA 55 A2 10 | blk_lo blk_hi | n | n×4B | XOR
      → 每点 4 B = s 低 / s 高 / c 低 / c 高（小端 int16，**补码**）

28672 点 = 448 块 × 64 点 = 448 × 264 B 线上 118,272 B（载荷 114,688 B），
    2 Mbaud 下约 0.6 s。
"""

from __future__ import annotations

import math
import struct
import time

DUMP_HEAD = b"\xAA\x55\xA2\x10"
PTS_PER_BLOCK = 64                      # 与 rtl/scope_dump.v 的 PTS 参数一致
BLOCK_BYTES = 8 + 4 * PTS_PER_BLOCK     # 264

# RTL 常量（与 rtl/enc_top.v / rtl/scope_capture.v 对齐）
FS_RAW = 50.0e6                         # src=0：ADC 原始 50 MSPS
FS_COR = 12.5e6                         # src=1：校正通道（decim_avg LOG2DEC=2）
CAP_DEPTH = 28672                       # 与 rtl/scope_capture.v 的 DEPTH 一致；**不是 2 的幂**


class CaptureError(RuntimeError):
    """抓包失败（超时 / 块校验错 / 固件不匹配）。"""


def fs_for(src, dec_log2):
    """返回该配置下的实际采样率（Hz）。"""
    base = FS_COR if src else FS_RAW
    return base / float(1 << (dec_log2 & 3))


def parse_block(blk):
    """校验并拆一块。返回 (blk_idx, n, s_list, c_list)；校验失败抛 CaptureError。"""
    if len(blk) < 8 or bytes(blk[:4]) != DUMP_HEAD:
        raise CaptureError("块头不是 AA 55 A2 10")
    n = blk[6]
    need = 8 + 4 * n
    if len(blk) != need:
        raise CaptureError("块长 %d 与 n=%d 不符" % (len(blk), n))
    x = 0
    for b in blk[:-1]:
        x ^= b
    if x != blk[-1]:
        raise CaptureError("块 %d XOR 校验失败" % (blk[4] | (blk[5] << 8)))
    idx = blk[4] | (blk[5] << 8)
    s = [0] * n
    c = [0] * n
    base = 7
    for i in range(n):
        o = base + 4 * i
        s[i] = struct.unpack_from("<h", blk, o)[0]
        c[i] = struct.unpack_from("<h", blk, o + 2)[0]
    return idx, n, s, c


def reassemble(blocks, expect_blocks=None):
    """把块列表拼成连续样点。

    返回 dict：
        s, c      : list[int]（补码原值，未换算成电压）
        started   : 第一块的下标（正常情况下是 0）
        missing   : 缺失块下标列表；缺的样点补 0 并在 missing 里报告
        n_blocks  : 收到的块数
    注意**按块下标归位**，不是按到达顺序：串口偶发丢字节时可能整块丢掉，
    按顺序拼会让后面的样点整体错位（波形"跳一下"却查不出来）。
    """
    if expect_blocks is None:
        expect_blocks = (max((b[4] | (b[5] << 8)) for b in blocks) + 1) if blocks else 0
    s_all = [0] * (expect_blocks * PTS_PER_BLOCK)
    c_all = [0] * (expect_blocks * PTS_PER_BLOCK)
    seen = [False] * expect_blocks
    started = None
    for blk in blocks:
        idx, n, s, c = parse_block(blk)
        if started is None:
            started = idx
        if idx >= expect_blocks:
            continue
        off = idx * PTS_PER_BLOCK
        s_all[off:off + n] = s
        c_all[off:off + n] = c
        seen[idx] = True
    missing = [i for i, ok in enumerate(seen) if not ok]
    return {
        "s": s_all,
        "c": c_all,
        "started": 0 if started is None else started,
        "missing": missing,
        "n_blocks": len(blocks),
    }


class CaptureResult(object):
    """一次抓包的全部产物（样点 + 元数据 + 派生量）。"""

    def __init__(self, s, c, meta, missing=None, n_blocks=0):
        self.s = list(s)
        self.c = list(c)
        self.meta = dict(meta or {})
        self.missing = list(missing or [])
        self.n_blocks = int(n_blocks)

    # ---------------------------------------------------------------- 派生
    @property
    def n(self):
        return len(self.s)

    @property
    def fs(self):
        return fs_for(self.meta.get("src", 0), self.meta.get("dec_log2", 0))

    @property
    def dt_s(self):
        return 1.0 / self.fs

    @property
    def duration_s(self):
        return self.n / self.fs

    @property
    def ok(self):
        return not self.missing

    def time_axis(self):
        """相对触发点的时间轴（秒）：触发点之前是负数。"""
        idx = int(self.meta.get("trig_idx", 0))
        dt = self.dt_s
        return [(i - idx) * dt for i in range(self.n)]

    def peak_to_peak(self, ch=0):
        arr = self.s if ch == 0 else self.c
        return (max(arr) - min(arr)) if arr else 0

    def summary(self):
        m = self.meta
        return ("%d 点 @ %.3f MSPS（%.3f ms）｜触发点 #%d｜抽取 ×%d｜缺块 %d"
                % (self.n, self.fs / 1e6, self.duration_s * 1e3,
                   int(m.get("trig_idx", 0)), 1 << int(m.get("dec_log2", 0)),
                   len(self.missing)))

    # ---------------------------------------------------------------- 导出
    def to_csv(self, path, with_time=True, note=None):
        """一列时间（µs）+ s + c。给 Excel / 示波器软件看。

        ``note`` 非空时写成首行 ``# 注释``（标准 CSV 注释约定，pandas 可用
        ``comment="#"`` 跳过），用来记「导出的文件没被显示滤波改过」。
        """
        fs = self.fs
        with open(path, "w", encoding="utf-8-sig", newline="") as fh:
            if note:
                fh.write("# %s\n" % str(note).replace("\n", " "))
            fh.write("t_us,s,c\n" if with_time else "s,c\n")
            for i in range(self.n):
                if with_time:
                    fh.write("%.3f,%d,%d\n" % (i * 1e6 / fs, self.s[i], self.c[i]))
                else:
                    fh.write("%d,%d\n" % (self.s[i], self.c[i]))

    def to_npy(self, path):
        """numpy 的 .npy（两列 int16，形状 (N,2)）。没有 numpy 时写成 CSV。

        返回**实际**写出的路径：没有 numpy 时会退化成 .csv，界面必须按返回值
        提示，否则文件里是 CSV、界面却说"已导出 NPY"（审计发现）。
        """
        try:
            import numpy as np
        except ImportError:
            alt = path if str(path).endswith(".csv") else str(path) + ".csv"
            self.to_csv(alt)
            return alt
        arr = np.empty((self.n, 2), dtype=np.int16)
        arr[:, 0] = self.s
        arr[:, 1] = self.c
        np.save(path, arr)
        return path

    def to_png(self, path, width=1600, height=520, title=None, note=None):
        """导出波形图（matplotlib）。

        用 min/max 包络画，而不是"每 N 点取 1 点"：后者会把尖峰随机丢掉，
        导出的图和界面看到的不是一回事。横轴是相对触发点的时间（µs）。
        """
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            import numpy as np

            import filters as fl

            # 中文标题/坐标轴必须显式给字体，否则 Windows 上的 DejaVu Sans 全是方框
            matplotlib.rcParams["font.sans-serif"] = [
                "Microsoft YaHei", "SimHei", "DejaVu Sans"]
            matplotlib.rcParams["axes.unicode_minus"] = False
        except ImportError:
            self.to_csv(str(path) + ".csv", note=note)
            return
        n = self.n
        cols = max(1, int(width * 1.2))
        trig = int(self.meta.get("trig_idx", 0))
        idx = np.arange(n)
        ts = (idx - trig) / self.fs * 1e6
        fig, ax = plt.subplots(figsize=(width / 100.0, height / 100.0), dpi=100)
        for arr, color, label in ((self.s, "#2E7DD1", "CH1"),
                                  (self.c, "#D9534F", "CH2")):
            x, lo, hi = fl.envelope(np.asarray(arr, dtype=float), cols)
            xi = x.astype(int)
            ax.fill_between(ts[xi], lo, hi, color=color, alpha=0.6,
                            linewidth=0, label=label)
        ax.set_xlabel("t / µs（相对触发点）")
        ax.set_ylabel("raw code (int16)")
        ax.grid(True, alpha=0.3)
        ax.legend(loc="upper right")
        head = title or self.summary()
        if note:
            head += " ｜ " + str(note)
        ax.set_title(head, fontsize=9)
        fig.tight_layout()
        fig.savefig(path)
        plt.close(fig)


def capture_once(worker, src=0, dec_log2=1, length=CAP_DEPTH, trig=0, level=0,
                 pre=1024, arm_timeout=6.0, dump_timeout=6.0, progress=None):
    """配置 → arm → 等 done → 串口回读整窗，返回 CaptureResult。

    ``worker`` 必须是已连接的 SerialWorker；``progress(text, frac)`` 可选。
    """
    t0 = time.monotonic()
    n_blocks = int(math.ceil(length / float(PTS_PER_BLOCK)))

    def _p(text, frac):
        if progress is not None:
            progress(text, frac)

    _p("写参数并 arm…", 0.02)
    ok, err = worker.capture_configure(src=src, dec_log2=dec_log2, length=length,
                                       trig=trig, level=level, pre=pre)
    if not ok:
        raise CaptureError(err)

    _p("等触发…", 0.10)
    st = worker.capture_wait_done(timeout=arm_timeout)
    if st is None:
        raise CaptureError("读 CAP_STATUS 超时")
    if not st["done"]:
        raise CaptureError("等不到 done（armed=%s busy=%s）：触发条件没有满足？"
                           % (st["armed"], st["busy"]))

    meta = {"src": int(src), "dec_log2": int(dec_log2), "cap_len": length,
            "trig_mode": int(trig), "trig_level": int(level), "pre": int(pre),
            "ovf": bool(st["ovf"]), "build": None, "trig_idx": 0,
            "sample_cnt": None, "len_eff": length}

    for name, reg, key in (("BUILD", 0x072C, "build"),
                           ("TRIG_IDX", 0x0726, "trig_idx"),
                           ("LEN_EFF", 0x0732, "len_eff")):
        d = worker.read_reg(reg)
        if d is not None:
            meta[key] = d["value"]

    lo = worker.read_reg(0x0728)
    hi = worker.read_reg(0x072A)
    if lo is not None and hi is not None:
        meta["sample_cnt"] = lo["value"] | (hi["value"] << 16)

    _p("批量 dump %d 块…" % n_blocks, 0.20)
    blocks = worker.capture_dump(n_blocks, timeout=dump_timeout)
    if blocks is None:
        raise CaptureError(worker.dump_last_error or "dump 失败")

    _p("拼装…", 0.92)
    data = reassemble(blocks, expect_blocks=n_blocks)
    res = CaptureResult(data["s"], data["c"], meta,
                        missing=data["missing"], n_blocks=data["n_blocks"])
    res.meta["elapsed_s"] = time.monotonic() - t0
    res.meta["bad_blocks"] = int(getattr(worker, "dump_bad_blocks", 0))
    _p("完成", 1.0)
    return res
