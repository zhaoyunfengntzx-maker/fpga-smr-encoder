# -*- coding: utf-8 -*-
"""host/udp_capture.py —— 以太网（B2）抓包的回读通道

设计目标
--------
把 `scope_capture` 抓到的 28672 点，从板子的以太网口以 UDP 包流送上来。
和串口回读（`host/capture.py` 的 DUMP 通道）相比：

    -------------- --------------- ---------------
                   串口 dump        以太网 UDP
    -------------- --------------- ---------------
    带宽           2 Mbaud           1000 Mbps
    112 KB 耗时    ~0.6 s           ~2 ms    丢包           不会（带 XOR）    会（UDP 无重传）
    依赖           只要串口          网线 + IP 配好
    -------------- --------------- ---------------

包格式（见 rtl/eth/scope_udp.v）
--------------------------------
每个 UDP 载荷 = 16 字节应用头 + N x 4 字节样点（N <= 350）：

    偏移 0..1  魔数 0xE75A（线上字节序：E7 5A）
    2          flags：bit0 = 本窗最后一个包
    3          dec_log2
    4..5       seq（小端）
    6..9       first：本包首个样点在窗内的下标（小端 32 bit）
    10..15     保留（0）

样点：ch1 int16 小端 + ch2 int16 小端。

为什么不用"按到达顺序拼"：
    以太网可能乱序/丢包，必须按 seq 归位；缺包的位置留 0 并在结果里
    记下来（CaptureResult.missing），而不是悄悄错位。
"""

import socket
import struct
import time

import capture as cap

UDP_MAGIC = 0xE75A
UDP_MAGIC_BYTES = b"\xE7\x5A"   # 线上字节序：先 E7 再 5A（rtl/eth/scope_udp.v:314-315）
UDP_HDR = 16
SAMPLE_BYTES = 4
MAX_PTS = 350              # 与 rtl/eth/scope_udp.v 的 MAX_PTS 一致


class UdpCaptureError(RuntimeError):
    """以太网抓包失败（端口占用 / 超时 / 一个包都没收到）。"""


class UdpCapture(object):
    """在 PC 侧监听 UDP，把板子推上来的包拼成一次抓包结果。

    参数
    ----
    port      : 本机监听端口，必须等于 FPGA 里配的 HOST_PORT（默认 5000）
    bind_ip   : 监听地址，直连时填 PC 的固定 IP（192.168.1.100）更稳；
                填 "" 表示监听全部网卡
    timeout_s : 单次抓包的总超时
    """

    def __init__(self, port=5000, bind_ip="", timeout_s=5.0):
        self.port = int(port)
        self.bind_ip = bind_ip or ""
        self.timeout_s = float(timeout_s)
        self._sock = None
        self.packets = 0
        self.dropped = 0
        self.last_error = ""

    # ---------------------------------------------------------------- socket
    def open(self):
        if self._sock is not None:
            return
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # ★ 审计 2 #12：Windows 的 SO_REUSEADDR 允许多个进程绑同一端口（谁收到看运气），
        #   "先探测空闲、关掉、再绑"本身也有 TOCTOU 窗口。这里改独占绑定：被占就直接报错，
        #   不会出现"抓包正常但偶发收不到/混进别人的包、重启才好"的怪现象。
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            except OSError:                       # 老系统/受限环境退回共享绑定
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        else:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # 收包缓冲开大：28672 点约 82 个包，突发到达时别丢在内核里
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        except OSError:
            pass
        try:
            s.bind((self.bind_ip, self.port))
        except OSError as e:
            s.close()
            raise UdpCaptureError(
                "绑定 %s:%d 失败（%s）。端口被别的程序占用，或该 IP 不在本机。"
                % (self.bind_ip or "0.0.0.0", self.port, e))
        s.settimeout(0.2)
        self._sock = s

    def close(self):
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    # ------------------------------------------------------------- 解析工具
    @staticmethod
    def parse_packet(data):
        """返回 (seq, first, dec_log2, is_last, s_list, c_list)。

        长度/魔数不对时抛 UdpCaptureError —— 宁可直接报错，也不要把
        别的杂包当成样点画出来。
        """
        if len(data) < UDP_HDR + SAMPLE_BYTES:
            raise UdpCaptureError("UDP 包太短（%d 字节）" % len(data))
        # ★ 魔数按字节比，不能用 "<H" 解成 0x5AE7 再和 0xE75A 比：
        #   那样每个真机包都会被当成杂包丢掉，而自测用 "<H" 造包又永远绿。
        if data[:2] != UDP_MAGIC_BYTES:
            raise UdpCaptureError("UDP 包魔数不对（%s）" % data[:2].hex().upper())
        flags, dec, seq, first = struct.unpack_from("<BBHI", data, 2)
        body = len(data) - UDP_HDR
        if body % SAMPLE_BYTES:
            raise UdpCaptureError("载荷长度不是 4 的倍数（%d）" % body)
        n = body // SAMPLE_BYTES
        s = [0] * n
        c = [0] * n
        for i in range(n):
            off = UDP_HDR + i * SAMPLE_BYTES
            s[i], c[i] = struct.unpack_from("<hh", data, off)
        return seq, first, dec & 0x03, bool(flags & 0x01), s, c

    # ------------------------------------------------------------- 收一次包
    def receive(self, expect_pts, progress=None):
        """收够 expect_pts 个样点（或收到 flags 末包）就返回。

        返回 dict：seqs/missing/dec_log2/elapsed_s/s/c/is_last。
        """
        self.open()
        sock = self._sock
        if sock is None:                              # 并发 close 的窗口期
            raise UdpCaptureError("socket 已被关闭（可能刚断开过）")
        got = {}                      # seq -> (first, s, c)
        dec_log2 = None
        is_last = False
        t_last = None                 # 首次见到"末包"位的时刻
        total = 0
        t0 = time.time()
        self.packets = 0
        self.dropped = 0
        while True:
            if time.time() - t0 > self.timeout_s:
                break
            # 末包位已到：再等 0.3 s 收可能的乱序包就收工，不再干等满 5 s。
            # （末包丢失时仍走上面的总超时，不会把缺包当完整。）
            if is_last and t_last is not None and time.time() - t_last > 0.3:
                break
            try:
                data, _addr = sock.recvfrom(2048)
            except (socket.timeout, TimeoutError):
                if got and is_last:
                    break
                continue
            except OSError as e:
                self.last_error = str(e)
                break
            except AttributeError:           # close() 把 _sock 置 None 的竞态
                self.last_error = "socket 已关闭"
                break
            try:
                seq, first, dec, last, s, c = self.parse_packet(data)
            except UdpCaptureError as e:
                self.last_error = str(e)
                self.dropped += 1
                continue
            self.packets += 1
            dec_log2 = dec
            if seq not in got:
                got[seq] = (first, s, c)
                total += len(s)
            if last:
                is_last = True
                if t_last is None:
                    t_last = time.time()
            if progress is not None and self.packets % 8 == 0:
                progress(min(0.99, total / float(max(1, expect_pts))))
            if total >= expect_pts:
                break

        elapsed = time.time() - t0
        if not got:
            # 复查 P12：以前把所有"收到但解析失败"的原因都吞成"检查网线"，
            # 端口写错/协议不匹配时用户永远查不到真正原因。
            hint = ""
            if self.dropped:
                hint = ("\n已收到 %d 个 UDP 包，但全部解析失败（最近一次：%s）。"
                        % (self.dropped, self.last_error or "原因未知"))
            raise UdpCaptureError(
                "没收到可用的抓包 UDP 包（%.1f s 内）。%s\n检查：网线是否直连、"
                "PC 是否设成 192.168.1.100、防火墙是否放行 UDP %d、"
                "板上 MAC/IP/HOST_IP/端口（0x070C）是否配好。"
                % (self.timeout_s, hint, self.port))

        # ★ 按 first（绝对样点下标）归位，不按 seq 拼接：丢一个中间包时，
        #   若用"最长的那个包"去补洞，缺包后的所有样点会整体错位（波形看着正常、
        #   其实是平移过的）。改成先开一个 expect_pts 长的数组，每包写到
        #   s_all[first:first+n]，没写到的位置留 0，seq 只用来报缺包。
        n_total = max(0, int(expect_pts))
        max_pkts = max(1, (n_total + MAX_PTS - 1) // MAX_PTS)
        # seq 是 16 位线上值：坏包能把 max(got)+1 顶到 65536。用 max_pkts 的
        # 4 倍做上限 —— 正常窗口是 max_pkts，留 4 倍给"包比 MAX_PTS 短"的
        # 情况（单测里就是 8 点/包），又不至于被一个坏 seq 撑爆 missing 列表。
        n_pkts = min(max(got) + 1, max(1, max_pkts) * 4)
        missing = [i for i in range(n_pkts) if i not in got]

        s_all = [0] * n_total
        c_all = [0] * n_total
        covered = 0
        dropped_range = 0
        for seq_i, (first_i, s_i, c_i) in got.items():
            f = int(first_i)
            n_i = len(s_i)
            if f < 0 or f >= n_total:
                dropped_range += 1
                continue
            n_i = min(n_i, n_total - f)
            s_all[f:f + n_i] = s_i[:n_i]
            c_all[f:f + n_i] = c_i[:n_i]
            covered += n_i
        if covered < n_total and not missing and is_last:
            # 末包短是正常的（28672 = 81×350 + 322）；覆盖不足又没有缺包，
            # 说明 first 序列有洞——把它记进 last_error，别静默当完整窗。
            self.last_error = ("样点覆盖不足：期望 %d，按 first 只填了 %d"
                               % (n_total, covered))

        self.covered = int(covered)
        self.short = bool(covered < n_total)
        return {
            "covered": int(covered),
            "short": bool(covered < n_total),
            "seqs": got,
            "missing": missing,
            "dec_log2": dec_log2 if dec_log2 is not None else 0,
            "elapsed_s": elapsed,
            "s": s_all,
            "c": c_all,
            "is_last": is_last,
            "dropped_range": dropped_range,
        }

    # ------------------------------------------------------- 完整抓包流程
    def capture_once(self, worker, src=0, dec_log2=1, length=cap.CAP_DEPTH,
                     trig=0, level=0, pre=1024, arm_timeout=6.0,
                     progress=None):
        """配置 -> arm -> 等 done -> UDP 收包 -> CaptureResult。

        参数含义与 `capture.capture_once` 完全一致，方便 GUI 里一键切换。
        worker 必须是已连接的 `SerialWorker`（配置寄存器仍走串口，
        数据走网口 —— 两条通道互不干扰，这正是"双方案"的含义）。
        """
        # 0) 连续流若还开着，先让板子停发。
        #    板上 stream_en（0x0740 bit0）会门掉 UDP 抓包起点（rtl/enc_top.v 的
        #    eth_udp_start_g），流开着时 arm 能成、done 永不来，表现为"等抓包超时"。
        try:
            d = worker.read_reg(0x0740)
            if d is not None and (int(d.get("value", 0)) & 1):
                worker.write_reg(0x0740, 0, verify=False)
                time.sleep(0.05)
        except Exception:                       # noqa: BLE001 —— 诊断用，不能拦主流程
            pass

        # 1) 配置 + arm（复用串口的寄存器读写）
        ok, err = worker.capture_configure(src, dec_log2, length, trig, level, pre)
        if not ok:
            raise UdpCaptureError("配置抓包参数失败：%s" % err)

        # 2) 等 arm 完成（边沿触发时要等足够久）
        if trig != 0:
            arm_timeout = max(arm_timeout, 30.0)
        # ★ capture_wait_done 超时返回的是"最后一个状态 dict"（真值），不是 None；
        #   旧代码写 `if not worker.capture_wait_done(...)` 永远进不了错误分支，
        #   触发没来也会接着读旧数据、写 0x0736、把上一窗当本次结果返回。
        st = worker.capture_wait_done(arm_timeout, poll_s=0.005)
        # 真 SerialWorker 返回 dict，单测里的假 worker 可能返回 bool —— 两种都认
        done = st.get("done") if isinstance(st, dict) else bool(st)
        if st is None or not done:
            raise UdpCaptureError(
                "等抓包完成超时（status=%s）。触发条件没满足，或 CAP_LEN 太大。"
                % (st,))

        # 3) 取元信息（和串口路径同一套，保证两边结果可比）
        meta = {"src": src, "dec_log2": dec_log2, "length": length,
                "trig": trig, "level": level, "pre": pre,
                "transport": "udp",
                "host": "%s:%d" % (self.bind_ip or "0.0.0.0", self.port)}
        for name, reg in (("trig_idx", 0x0726), ("len_eff", 0x0732)):
            try:
                d = worker.read_reg(reg)
                meta[name] = int(d.get("value", 0)) & 0xFFFFFFFF
            except Exception:
                meta[name] = 0
        try:
            d = worker.read_reg(0x0728)
            meta["sample_cnt"] = int(d.get("value", 0)) & 0xFFFFFFFF
        except Exception:
            meta["sample_cnt"] = 0

        # 4) 先 bind 再让板子开推（UDP_CTRL.bit0）
        #    ★ 顺序很重要：板子收到 0x0736 立刻开推，82 包 ≈ 2 ms 就发完；
        #      而一次寄存器写要过 2 Mbaud 串口 + USB-serial（CH340 延迟定时器
        #      常见 16 ms），等 receive() 里才 bind 的话，开头的包全落在 socket
        #      建好之前（Windows 还会回 ICMP 端口不可达）。
        #    期望点数取 0x0732 CAP_LEN_EFF（已被 RTL 按 DEPTH 截断），不要写死
        #    cap.CAP_DEPTH：短窗抓包时若按全深等，会白等满 socket 超时。
        expect = int(meta.get("len_eff") or 0)
        if expect <= 0:
            expect = int(length)
        expect = min(expect, int(cap.CAP_DEPTH))
        opened_here = self._sock is None
        self.open()
        try:
            t0 = time.time()
            worker.write_reg(0x0736, 0x0001, verify=False)
            res = self.receive(expect_pts=expect, progress=progress)
        finally:
            if opened_here:
                self.close()
        meta["elapsed_s"] = time.time() - t0
        meta["dec_log2"] = res["dec_log2"] or dec_log2
        return cap.CaptureResult(res["s"], res["c"], meta,
                                 missing=res["missing"],
                                 n_blocks=len(res["seqs"]))
