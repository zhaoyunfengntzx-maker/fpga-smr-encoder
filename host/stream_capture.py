# -*- coding: utf-8 -*-
"""连续流接收（二期）：把 FPGA 推上来的 UDP 连续流收进环形缓冲。

和一期"抓一段"的区别
--------------------
一期是**请求-响应**：配置 → arm → 等 done → 把 112 KB（28672 点 × 4 B）整窗读回来，数据是
一次性的、有边界的。二期是**连续**的：设备一开就按抽取比不停发，PC 端必须
边收边丢（只保留最近一段），所以：

* 缓冲是**环形**的，长度固定（默认 2^18 = 262144 点，@12.5 MSPS 约 21 s）；
* 每包带 64 bit **绝对序号**（首样点下标），丢包/丢样点都能从这里看出来；
* 界面只取 `snapshot()` 的最近 N 点画图，不参与"对账"。

包格式（与 rtl/eth/stream_tx.v 逐字节对应，单位：字节）
------------------------------------------------------
    0..1   魔数 0xE75A（小端）
    2      flags   bit1=1 表示连续流
    3      抽取 log2
    4..5   包序号（从 1 开始）
    6..9   首样点绝对序号（低 32 位）
    10..13 首样点绝对序号（高 32 位）
    14..15 保留
    16..    样点：每点 4 字节，ch1 int16 LE + ch2 int16 LE
"""

from __future__ import annotations

import collections
import socket
import struct
import threading
import time

import numpy as np

STREAM_MAGIC = 0xE75A
STREAM_MAGIC_BYTES = b"\xE7\x5A"   # 线上字节序：先 E7 再 5A
STREAM_HDR = 16
FLAG_STREAM = 0x02


class StreamError(Exception):
    """连续流收不到包 / 包格式不对时抛出。"""


def parse_packet(data):
    """解析一个连续流包。

    返回 ``(seq, first, dec, s, c)``：包序号、首样点绝对序号、抽取 log2，
    以及两个 int16 numpy 数组。格式不对返回 ``None``（不抛异常——UDP 上
    什么都可能收到，调用方按"跳过"处理即可）。
    """
    if len(data) < STREAM_HDR + 4:
        return None
    # ★ 魔数按字节比（RTL 先发 0xE7 再发 0x5A）；"<H" 解出来是 0x5AE7，
    #   与 STREAM_MAGIC 永远不等 —— 那样真机上一个包都收不到。
    if data[:2] != STREAM_MAGIC_BYTES:
        return None
    flags = data[2]
    dec = data[3]
    seq, lo, hi, _r14 = struct.unpack_from("<HIIH", data, 4)
    if not (flags & FLAG_STREAM):
        # 一期抓包包也会进这个端口（flags bit1=0），这里直接忽略
        return None
    n = (len(data) - STREAM_HDR) // 4
    if n <= 0:
        return None
    raw = np.frombuffer(data, dtype="<i2", count=2 * n, offset=STREAM_HDR)
    s = np.ascontiguousarray(raw[0::2])
    c = np.ascontiguousarray(raw[1::2])
    first = int(lo) | (int(hi) << 32)
    return int(seq), first, int(dec), s, c


class StreamReceiver:
    """后台线程收 UDP 连续流，环形缓冲保存最近 ``history`` 个样点。

    参数
    ----
    port      : 本机监听端口（与设备的 0x070C PORT 一致）
    bind_ip   : 绑定的本机地址，"" = 所有网卡
    history   : 环形缓冲长度（必须是 2 的幂，便于用 & 取模）
    bufsize   : socket 接收缓冲（临时调大可以吸收调度抖动）
    """

    def __init__(self, port=5000, bind_ip="", history=1 << 18,
                 bufsize=64 << 20, timeout_s=0.2, base_fs=50e6,
                 frame_hz=10000.0, frame_hist=30000):
        if history & (history - 1):
            raise ValueError("history 必须是 2 的幂")
        self.port = int(port)
        self.bind_ip = bind_ip or ""
        self.history = int(history)
        self.bufsize = int(bufsize)
        self.timeout_s = float(timeout_s)

        self._s = np.zeros(self.history, dtype=np.int16)
        self._c = np.zeros(self.history, dtype=np.int16)
        self._head = 0            # 已写入的绝对样点数
        # ★ 丢包时环形缓冲里会留下"空洞"，`snapshot()` 取最近 N 点可能横跨空洞，
        #   相位差就成了一堆随机值（实测转速读成 1~57 Hz）。这里记下**当前连续段**
        #   的起点，测速只用连续段内的样点。
        self._contig_from = None
        self._next_first = -1     # 下一包期望的首样点绝对序号
        self._lock = threading.Lock()
        self._sock = None
        self._thread = None
        self._stop = threading.Event()

        self.packets = 0          # 收到的包数
        self.lost = 0             # 绝对序号不连续丢掉的样点估计
        self.last_error = ""
        # ★ 审计遗留项：snapshot() 原来硬编码 dec=0 / t0_s=0，调用方若用它算时间轴
        #   就会得到"所有样点都在 t=0"。这里记下包头的 dec，并允许构造时指定基准
        #   采样率（raw 50 MHz / 校正通道 12.5 MHz），才能把绝对序号换算成秒。
        self.dec = 0
        self.base_fs = float(base_fs)
        # ---- 10 kHz 抽取抽头（用户要"全部走网口连续流"）------------------
        # 连续流是 12.5~50 MSPS，而上位机所有面板都是按 10 kHz 遥测帧写的。
        # 与其让界面每 tick 去抓一段原始样点（历史只有 262144 = 10.5 ms，
        # 根本盖不住 100 ms 的刷新周期），不如在收包线程里**顺手按步长抽**：
        # 每个包只做一次切片，代价可以忽略，拿到的却是"连续、无空洞"的
        # 10 kHz 序列。_tap_off 记住相位，跨包也严格等间隔。
        self.frame_hz = float(frame_hz)
        self._tap_step = 0            # 0 = 还没定（要等第一个包的 dec）
        self._tap_off = 0
        self._tap_s = collections.deque(maxlen=int(frame_hist))
        self._tap_c = collections.deque(maxlen=int(frame_hist))
        self._tap_head = 0            # 已抽出的帧数（单调）
        self._t_rate = time.monotonic()
        self._n_rate = 0
        self.rate_sps = 0.0

    # ---------------------------------------------------------------- 生命周期
    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        """打开 socket 并起收包线程。端口占用时抛 StreamError。"""
        if self.running:
            return
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, self.bufsize)
            except OSError:
                pass
            s.bind((self.bind_ip, self.port))
            s.settimeout(self.timeout_s)
            # ★ port=0 时由系统分配临时端口：把真实端口记下来，调用方先绑再告诉设备
            #   （审计 P1-10：原来的"先探测再绑"有 TOCTOU，中间被别人抢走就绑不上）
            self.port = int(s.getsockname()[1])
        except OSError as exc:
            s.close()
            raise StreamError("绑定 UDP %d 失败：%s" % (self.port, exc))
        self._sock = s
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop,
                                        name="udp-stream", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        t = self._thread
        if t is not None:
            t.join(timeout=1.0)
        self._thread = None
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    # ---------------------------------------------------------------- 收包
    def _loop(self):
        sock = self._sock
        while not self._stop.is_set():
            try:
                data, _addr = sock.recvfrom(4096)
            except socket.timeout:
                self._update_rate()
                continue
            except OSError as exc:
                self.last_error = "收包 socket 异常退出：%s" % exc
                break
            except Exception as exc:                    # noqa: BLE001
                # ★ 审计 B7：原来只捕 OSError，其它异常（如解析里的大小错）会让线程
                #   悄无声息地死掉，界面只弹一个空错误。任何异常都记下来再退出。
                self.last_error = "收包线程异常退出：%s: %s" % (type(exc).__name__, exc)
                break
            try:
                pkt = parse_packet(data)
                if pkt is not None:
                    self._store(*pkt)
            except Exception as exc:                    # noqa: BLE001
                # 单包解析异常不该杀死整条流：记一次、继续收（真出问题会连着记）
                self.last_error = "解析数据包出错：%s: %s" % (type(exc).__name__, exc)
                self.bad_packets = int(getattr(self, "bad_packets", 0)) + 1
            self._update_rate()

    def _store(self, seq, first, dec, s, c):
        n = s.size
        with self._lock:
            if self._next_first >= 0 and first != self._next_first:
                gap = first - self._next_first
                if gap > 0:
                    self.lost += int(gap)
                elif gap < 0:
                    # 乱序到达的旧包：环形缓冲里对应位置早被更新的样本覆盖，
                    # 再写进去就是"用旧数据盖新数据"，而且 _next_first 会被拖回去
                    # ⇒ 后面的新包全被算成大 gap、lost 虚高（审计发现）。
                    return
            if self._next_first >= 0 and first != self._next_first:
                # 有缺口：新的连续段从这一包开始
                self._contig_from = int(first)
            elif self._contig_from is None:
                self._contig_from = int(first)
            self._next_first = first + n
            self.dec = int(dec) if dec is not None else self.dec
            idx = (first + np.arange(n)) & (self.history - 1)
            self._s[idx] = s
            self._c[idx] = c
            self._head = max(self._head, first + n)
            if self._contig_from is None:
                self._contig_from = int(first)
            self.packets += 1
            self._n_rate += n
            self._tap(s, c)

    def _tap(self, s, c):
        """把这一包按"每 step 点取一点"抽进 10 kHz 抽头（调用方已持锁）。"""
        if self._tap_step <= 0:
            fs = fs_for_dec(self.base_fs, self.dec) if self.dec >= 0 else 0.0
            if fs <= 0:
                return
            self._tap_step = max(1, int(round(fs / max(1.0, self.frame_hz))))
        st = self._tap_step
        n = int(s.size)
        if n <= 0:
            return
        k0 = (-self._tap_off) % st
        if k0 < n:
            keep_s = s[k0::st]
            keep_c = c[k0::st]
            self._tap_s.extend(keep_s.tolist())
            self._tap_c.extend(keep_c.tolist())
            self._tap_head += int(keep_s.size)
        self._tap_off = (self._tap_off + n) % st

    def snapshot_frames(self, max_pts=2048):
        """取最近 ``max_pts`` 个**已抽到 10 kHz** 的样点（连续、无空洞）。

        返回 ``{"s","c","n","step","fs","head"}``；``head`` 是已抽帧数（单调）。
        """
        with self._lock:
            have = len(self._tap_s)
            n = int(min(max_pts, have))
            if n <= 0:
                return {"s": np.zeros(0, dtype=np.int16),
                        "c": np.zeros(0, dtype=np.int16),
                        "n": 0, "step": int(self._tap_step),
                        "fs": self.frame_hz, "head": int(self._tap_head)}
            ss = np.fromiter(list(self._tap_s)[-n:], dtype=np.int16, count=n)
            cc = np.fromiter(list(self._tap_c)[-n:], dtype=np.int16, count=n)
            return {"s": ss, "c": cc, "n": n, "step": int(self._tap_step),
                    "fs": self.frame_hz, "head": int(self._tap_head)}

    def _update_rate(self):
        now = time.monotonic()
        dt = now - self._t_rate
        if dt >= 0.5:
            self.rate_sps = self._n_rate / dt
            self._t_rate = now
            self._n_rate = 0

    # ---------------------------------------------------------------- 取数
    def snapshot(self, max_pts=8192):
        """取最近 ``max_pts`` 个样点（按时间顺序）。

        返回 dict：``s, c``（int16 数组）、``n``、``first``（首样点绝对序号）、
        ``head``（已收到的总样点数）、``dec``、``t0_s``（首样点相对开始的时间，
        秒；由绝对序号 / 采样率推算）。
        """
        with self._lock:
            head = self._head
            have = min(head, self.history)
            n = int(min(max_pts, have))
            if n <= 0:
                return {"s": np.zeros(0, dtype=np.int16),
                        "c": np.zeros(0, dtype=np.int16),
                        "n": 0, "first": 0, "head": 0, "dec": 0, "t0_s": 0.0}
            start = head - n
            idx = (start + np.arange(n)) & (self.history - 1)
            fs = fs_for_dec(self.base_fs, self.dec) if self.dec >= 0 else 0.0
            return {"s": self._s[idx].copy(), "c": self._c[idx].copy(),
                    "n": n, "first": int(start), "head": int(head),
                    "dec": int(self.dec),
                    "t0_s": (float(start) / fs) if fs > 0 else 0.0}

    def snapshot_contig(self, max_pts=8192):
        """取最近 ``max_pts`` 个**连续**样点（跨不过丢包缺口）。

        丢包率一高，`snapshot()` 给的窗口里就夹着空洞；相位/频率必须只用连续段，
        否则算出来的是噪声。连续段比要求短时，返回实际能给的（可能很少）。
        """
        with self._lock:
            head = self._head
            lo = self._contig_from
            if lo is None:
                lo = max(0, head - np.iinfo(np.int32).max)
            n = int(min(max_pts, head - lo))
            if n <= 0:
                return {"s": np.zeros(0, dtype=np.int16),
                        "c": np.zeros(0, dtype=np.int16),
                        "n": 0, "first": 0, "head": 0, "dec": 0, "t0_s": 0.0}
            start = head - n
            idx = (start + np.arange(n)) & (self.history - 1)
            fs = fs_for_dec(self.base_fs, self.dec) if self.dec >= 0 else 0.0
            return {"s": self._s[idx].copy(), "c": self._c[idx].copy(),
                    "n": n, "first": int(start), "head": int(head),
                    "dec": int(self.dec),
                    "t0_s": (float(start) / fs) if fs > 0 else 0.0}

    def clear(self):
        with self._lock:
            self._head = 0
            self._contig_from = None
            self._next_first = -1
            self.packets = 0
            self.lost = 0
            self._tap_s.clear()
            self._tap_c.clear()
            self._tap_head = 0
            self._tap_off = 0
            self._tap_step = 0


def fs_for_dec(base_fs, dec_log2):
    """抽取后的采样率。base_fs=50e6（raw）或 12.5e6（校正通道）。"""
    return float(base_fs) / (1 << int(dec_log2))
