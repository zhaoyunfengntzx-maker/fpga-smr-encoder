"""上位机串口通信层（S1）。

设计要点（对应 docs/10_host_requirements.md §4 的关键约束）
------------------------------------------------------
* 板子只有一条串口链路：10 kHz 遥测帧与寄存器读写应答**共用**它，下位机内部仲裁。
  ⇒ 必须"发一条命令 → 收到应答 → 再发下一条"，且**只能有一个东西碰这个串口**。
  本模块用一个后台线程独占串口，界面的所有操作都排队交给它做。
* 直接复用 tools/uart_scope.py（帧校验/解码）与 tools/uart_spi.py（命令编码/应答校验），
  不重写协议，避免和固件约定漂移。
* 串口流里只有两种东西：18 字节遥测帧（`AA 55` 开头）与 6 字节应答（`5A` 开头，XOR=0）。
  按这个事实做**无损分流**：等应答的时候，路过的遥测帧照样送进解析器，一帧都不丢。
* **读寄存器要"连发两帧"**（TW28 重叠响应 ⇒ 命令 N 的应答要到第 N+1 帧才移出），
  所以读操作超时后自动重发；**写操作默认只发一次**（0x0502 这类写两次会触发两次动作）。
* 2 Mbaud 下单帧 90.68 µs、链路占用 90.7%，所以读串口要勤、每次多读一点，
  交给队列缓冲，界面刷新频率与串口速率解耦。
"""

import os
import queue
import sys
import threading
import time

# ---------------------------------------------------------------------------
# 让 host/ 能 import 到仓库里已经验证过的协议代码（tools/uart_scope.py 等）
# ---------------------------------------------------------------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)


def _exe_dir():
    """打包成 exe 时"exe 自己所在的目录"，否则 None。

    PyInstaller 单文件模式：`__file__` 打在临时解包目录（`_MEIPASS`）里、
    退出即删；而用户实际双击的是 `host/dist/host_app.exe`
    ⇒ 想找"exe 旁边的东西"（比如 `tools/`）只能看 `sys.executable`。
    """
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        return os.path.dirname(os.path.abspath(sys.executable))
    return None


def _ensure_tools_on_path():
    """把 tools/ 加进 sys.path。

    两个场景都要能找得到（tools/uart_scope.py 与 tools/uart_spi.py 是协议权威实现，
    故意不复制一份到 host/ 里，避免和固件约定漂移）：
      * 源码运行：仓库根的 `tools/`（`host/` 的上一级）；
      * 打包成 exe：`tools/` 已被打进 exe（见 host/host_exe.spec 的 hiddenimports）
        或放在 exe 旁边，由 `sys.executable` 定位。
    """
    exe = _exe_dir()
    for cand in ((os.path.join(exe, "tools") if exe else None),
                 os.path.join(_ROOT, "tools"),
                 os.path.join(_HERE, "tools")):
        if cand and os.path.isdir(cand) and cand not in sys.path:
            sys.path.insert(0, cand)
            return cand
    return None


_ensure_tools_on_path()

import uart_scope as us          # noqa: E402  遥测帧：校验、解码、常量
import uart_spi as sp            # noqa: E402  寄存器：命令编码、应答格式

BAUD_DEFAULT = 2000000           # 板载 CH340E 固定 2 Mbaud / 8N1
REPLY_HEAD = sp.REPLY_HEAD       # 0x5A
TERMINATORS = None

# 设备的"身份证"寄存器（需求 M1 连接自检）
REG_DEVICE_ID = 0x05F0           # 低字节 DEVICE_ID，高字节 REV
REG_REV = 0x05F1
REG_RTL_BUILD = 0x05F2           # RTL_BUILD_ID（v12 = 0x000C）

EXPECT_DEVICE_ID = 0x0C          # 与 iC-TW28 同值
EXPECT_REV = 0x10
EXPECT_RTL_V13 = 0x000D          # v13：屏 + 以太网合并（抓包/UDP/连续流）
EXPECT_RTL_V12 = 0x000C
EXPECT_RTL_V11 = 0x000B

# ---------------------------------------------------------------------------
# 抓包（B1）：寄存器 + 0x072E 批量 dump 协议
# ---------------------------------------------------------------------------
# 地址表见 rtl/cap_regs.v 与 docs/17_ethernet_capture_plan.md §6。
# ★ 每个寄存器占 2 个字节地址（16 bit 对齐）：spi_slave 的一次 16 bit 写会在
#   addr 与 addr+1 各产生一个 8 bit 写脉冲，紧凑排布会踩邻居。
REG_CAP_SRC = 0x0718        # [0] 0=原始 50 MSPS / 1=校正 12.5 MSPS；[2:1] 抽取 log2
REG_CAP_LEN = 0x071A        # 窗口点数（<= CAP_DEPTH，默认 28672）
REG_CAP_TRIG = 0x071C       # [1:0] 0=立即 1=上升沿 2=下降沿
REG_CAP_LEVEL = 0x071E      # 有符号 16 bit 触发电平
REG_CAP_PRE = 0x0720        # 预触发点数
REG_CAP_CTRL = 0x0722       # [0] arm（W1）[1] abort
REG_CAP_STATUS = 0x0724     # [0]done [1]armed [2]trig [3]busy [4]ovf
REG_CAP_TRIG_IDX = 0x0726
REG_CAP_SAMP_LO = 0x0728
REG_CAP_SAMP_HI = 0x072A
REG_CAP_BUILD = 0x072C      # 0x000D
REG_CAP_DUMP_CTRL = 0x072E  # [0] start（W1）[1] abort
REG_CAP_DUMP_STATUS = 0x0730
REG_CAP_LEN_EFF = 0x0732
REG_CAP_BLOCKS = 0x0734

# ---- 以太网（B2）寄存器：0x0700 段 -------------------------------------------------
REG_ETH_MAC_LO = 0x0700     # [15:0] MAC bit15..0（整 48 bit = 0x0200_0000_0000 | 本值）
REG_ETH_MAC_HI = 0x0702     # [15:0] MAC bit31..16
REG_ETH_IP = 0x0704         # [15:0] 本机 IP bit15..0
REG_ETH_IP_HI = 0x0706      # [15:0] 本机 IP bit31..16
REG_ETH_HOST_IP = 0x0708
REG_ETH_HOST_IP_HI = 0x070A
REG_ETH_PORT = 0x070C       # 目的端口（默认 5000）
REG_ETH_STATUS = 0x0710     # [0]arp_ok [1]icmp_ok [2]host_known
REG_ETH_TX_PKT = 0x0712
REG_ETH_TX_DROP = 0x0714
REG_ETH_RX_PKT = 0x0716
REG_CAP_UDP_CTRL = 0x0736   # [0] start（W1）[1] abort
REG_CAP_UDP_STATUS = 0x0738 # [0] busy [1] done
REG_CAP_UDP_PKTS = 0x073A
REG_CAP_UDP_DROP = 0x073C
# ---- 二期：连续流（0x0740 段，每寄存器 16 位对齐）----
REG_CAP_STREAM_CTRL = 0x0740   # [0] enable
REG_CAP_STREAM_DEC = 0x0742    # 抽取 log2，1..4
REG_CAP_STREAM_STATUS = 0x0744 # [0] running [1] ovf [2] enabled
REG_CAP_STREAM_PKTS = 0x0746   # 32 位发包数（0x0746..0x0749）
REG_CAP_STREAM_DROP = 0x074A   # 32 位丢样点数（0x074A..0x074D）
REG_CAP_STREAM_LAG = 0x074E    # 16 位滞后样点数

CAP_DEPTH = 28672           # 与 rtl/scope_capture.v 的 DEPTH 参数一致（非 2 的幂，回绕靠显式比较）
DUMP_HEAD = b"\xAA\x55\xA2\x10"
DUMP_BLOCK_PTS = 64         # 与 rtl/scope_dump.v 的 PTS 参数一致
DUMP_BLOCK_BYTES = 8 + 4 * DUMP_BLOCK_PTS   # 头 7 + 载荷 256 + XOR 1 = 264

# 应答第 2 字节是地址回显（tools/uart_spi.py:178 build_reply 证实）。
# 打开它可以让"张冠李戴的延迟应答"被识别出来而不是当成有效数据；
# 万一个别固件版本不回显，界面上会明确报"应答地址不符"而不是悄悄用错值。
VERIFY_ADDR_ECHO = True


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
def reply_ok(cand):
    """6 字节应答校验：全部异或为 0（0x5A ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 == 0）。

    ★ 附加一条：**6 个字节全相同不算应答**（自查发现）。这种"应答"异或必然为 0，
    但它不可能是真的 —— 真应答 = [0x5A, status, addr, hi, lo, xor]，status 是 SPI
    状态字，不会是 0x5A。串口被拔掉/悬空时线上会持续给出同一个字节，不加这条就会把
    垃圾当成"写寄存器成功"，用户看到的值全是 0x5A5A 这种假值。
    """
    if len(cand) != 6:
        return False
    if cand[0] == cand[1] == cand[2] == cand[3] == cand[4] == cand[5]:
        return False
    x = 0
    for b in cand:
        x ^= b
    return x == 0


def parse_reply(rep):
    """把 6 字节应答拆成字段。value = (高字节 << 8) | 低字节。"""
    return {
        "raw": bytes(rep),
        "hex": " ".join("%02X" % b for b in rep),
        "status": rep[1],
        "addr_echo": rep[2],
        "hi": rep[3],
        "lo": rep[4],
        "value": (rep[3] << 8) | rep[4],
    }


def _decode_frame(raw):
    """18 字节原始帧 → dict（借用 uart_scope 的解码，保证与工具一致）。"""
    frames, _stats = us.parse_stream(raw)
    return frames[0] if frames else None


def baud_text(baud):
    return "%s baud / 8-N-1" % format(int(baud), ",")


def _open_error_text(exc):
    """把 pyserial/OSError 的英文异常翻成人话（需求：出错给人话，别甩英文堆栈）。

    认不出来的异常保留原文——排障时原始信息比"未知错误"有用得多。
    """
    s = str(exc)
    low = s.lower()
    # ★ 顺序很重要：pyserial 把"被占用"和"设备不存在"都包成 `SerialException: could not
    #   open port 'COM3': ...`，只能看内层的 errno。以前先匹配 "could not open port" ⇒
    #   端口被占用（PermissionError 13）也被报成"找不到这个串口（板子被拔了？）"，
    #   真踩过：前一个脚本刚退出、句柄还没释放，我按"板子被拔了"查了半天。
    if (isinstance(exc, PermissionError) or "permissionerror" in low or "errno 13" in low
            or "access is denied" in low or "拒绝访问" in s
            or "already open" in low or "in use" in low or "busy" in low):
        return "串口被别的程序占着（串口助手/另一个上位机/上一个脚本还没退出？关掉再试）"
    if (isinstance(exc, FileNotFoundError) or "filenotfounderror" in low or "errno 2" in low
            or "系统找不到指定的文件" in s):
        return "找不到这个串口（板子被拔了？换一个口试试）"
    if "could not open port" in low:
        return "打不开这个串口（被别的程序占用，或者板子被拔了？）"
    if "in use" in low or "busy" in low:
        return "串口正忙（可能已被占用）"
    if "incorrect function" in low or "not a valid" in low:
        return "这个口不是普通串口（蓝牙虚拟口/调试口？换 USB 那个）"
    return s


# ---------------------------------------------------------------------------
# 串口工作线程
# ---------------------------------------------------------------------------
class SerialWorker(threading.Thread):
    """独占串口的后台线程：一边收遥测、一边执行寄存器命令。"""

    def __init__(self, port, baud=BAUD_DEFAULT, batch_ms=50.0,
                 read_size=4096, read_timeout=0.02, queue_max=300):
        super().__init__(daemon=True, name="uart-worker")
        self.port = port
        self.baud = int(baud)
        # 注意单位：time.monotonic() 是秒，所以内部统一用秒比较
        self.batch_ms = float(batch_ms)
        self.batch_s = max(0.001, float(batch_ms) / 1000.0)
        self.read_size = int(read_size)
        self.read_timeout = float(read_timeout)

        self.events = queue.Queue(maxsize=int(queue_max))   # 给界面的事件
        self.connected = False
        self.error = None
        self._finished = threading.Event()

        self._stop = threading.Event()
        # ★ 命令队列（FIFO），不是一个"单槽"（自查发现）：提交命令的调用方不止一个
        #   （设备信息后台线程 + UI 定时器/按钮都会 read_reg/write_reg）。单槽时后提交的
        #   会覆盖先提交的 —— 先那条**从没上线**，调用方却干等到超时（假超时）。
        #   实际深度只有 0~2 条，用 list 足够。
        self._cmd_queue = []
        self._cmd_lock = threading.Lock()   # 界面侧串行化命令提交
        self.buf = bytearray()
        self.batch = []                     # 尚未交给界面的帧
        self._replies = []                  # 已收到的应答队列（一个读窗口可能来好几条）
        self._last_emit = time.monotonic()
        self._t_open = None

        # 诊断计数（只在工作线程里改，界面读快照）
        self.rx_bytes = 0
        self.frames_ok = 0
        self.crc_err = 0
        self.resync_bytes = 0
        self.stray_reply = 0
        self.reply_ok = 0
        self.reply_timeout = 0
        self.dropped_frames = 0
        self.dropped_batches = 0
        self.bad_raw = []
        self.layout_v2 = 0
        self.layout_v1 = 0

        # 抓包 dump 状态（B1）：dump 期间串口上的字节流是 264 B 块，不是遥测帧，
        # 所以必须显式切换解析器 —— 不能靠"看到 AA 55 就当遥测帧"猜，
        # 遥测帧的 byte2/3 是角度低/高字节，完全可能撞上 A2 10。
        self._dump_lock = threading.Lock()
        self._dump_mode = False
        self._dump_buf = bytearray()
        self._dump_want = 0
        self._dump_blocks = []          # bytes 列表（每块原始 264 B，含头与 XOR）
        self._dump_done = threading.Event()
        self.dump_bad_blocks = 0
        self.dump_resync = 0
        self.dump_last_error = ""

    # ---------------------------------------------------------------- 线程体
    def run(self):
        try:
            import serial
        except ImportError as exc:
            self._emit_error("没装 pyserial，无法使用串口：%s" % exc)
            self._finished.set()
            return
        ser = None
        # ★ 重试几次：前一个进程刚退出时句柄可能还没释放（Windows 上实测 1~2 s），
        #   而"串口被占用"和"板子被拔了"对用户是完全不同的动作，不该一撞就报错。
        open_err = None
        for i in range(3):
            try:
                ser = serial.Serial(self.port, self.baud,
                                    timeout=self.read_timeout, write_timeout=0.5)
                open_err = None
                break
            except Exception as exc:                              # noqa: BLE001
                open_err = exc
                if i < 2:
                    time.sleep(0.6)
        if ser is None:
            self._emit_error("打开串口 %s 失败：%s" % (self.port, _open_error_text(open_err)))
            # ★ 审计 B3：原来只发 error，界面靠"线程是否还活着"才回到可点状态；
            #   这里补一条 closed，让上层立刻复位（否则状态栏停在故障、按钮不回"连接"）。
            self._emit("closed", "串口 %s 没打开" % self.port)
            self._finished.set()
            return

        self.connected = True
        self._t_open = time.monotonic()
        try:
            # ★ 关键（照 tools/uart_scope.py:590 的实机经验）：
            # 2 Mbaud 下遥测 180 kB/s，驱动默认 RX 缓冲只有几 KB。若上位机停顿
            # 超过缓冲深度就会丢字节（表现为 XOR 校验失败 + 重新同步）。
            # 把驱动 RX 缓冲开到 1 MB，并"有多少读多少"，不要固定长度读。
            ser.set_buffer_size(rx_size=1 << 20)
        except Exception:                                         # noqa: BLE001
            pass
        try:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
        except Exception:                                         # noqa: BLE001
            pass
        self._emit("open", "已连接 %s（%s）" % (self.port, baud_text(self.baud)))

        try:
            self._loop(ser)
        except Exception as exc:                                  # noqa: BLE001
            self._emit_error("串口线程异常：%s: %s" % (type(exc).__name__, exc))
        finally:
            self.connected = False
            try:
                ser.close()
            except Exception:                                     # noqa: BLE001
                pass
            self._flush_batch(force=True)
            with self._cmd_lock:            # 线程结束：唤醒队列里所有还在等的调用方
                pending = list(self._cmd_queue)
                self._cmd_queue = []
            for req in pending:
                if not req["event"].is_set():
                    req["event"].set()
            self._emit("closed", "串口已关闭（%s）" % self.port)
            self._finished.set()

    def _loop(self, ser):
        while not self._stop.is_set():
            req = self._take_cmd()
            if req is not None:
                self._execute(ser, req)
                self._cmd_done(req)
                continue
            chunk = self._read_available(ser)
            if chunk:
                self._pump(chunk, want_reply=False)
            self._flush_batch(force=False)
        # 收尾：把最后一批帧交出去
        self._flush_batch(force=True)

    def _take_cmd(self):
        """原子地取走**最早**的那条待执行命令（FIFO）。

        以前是"单槽"：`req = self._cmd_req` 然后执行完无条件清槽 —— 执行期间调用方提交的
        新命令会把还没取走的旧命令**无声覆盖**（命令从没发出，调用方却干等到超时）。
        现在改成队列：先到先执行，谁也不会被谁的提交抹掉。
        """
        with self._cmd_lock:
            while self._cmd_queue:
                req = self._cmd_queue.pop(0)
                if not req["event"].is_set():   # 已经超时的那条：跳过，别白占一次串口往返
                    return req
            return None

    def _cmd_done(self, req):
        """命令执行完：唤醒调用方（队列里那条在 _take_cmd 取走时就已出队）。"""
        if not req["event"].is_set():
            req["event"].set()

    def _take_reply(self):
        """取走一条已收到的应答（没有就返回 None）。"""
        if self._replies:
            return self._replies.pop(0)
        return None

    def _read_available(self, ser):
        """把驱动缓冲里现有的字节一次读光（单次上限 `read_size`；没有就等一个 read_timeout）。

        ★ `read_size` 是**单次读取上限**（原来是没被用过的死参数）：积压大时多读几轮，
        避免一次申请过大的缓冲；10 kHz 遥测一帧 18 B、50 ms 一批 ≈ 9 kB，4096 要读 3 轮。
        """
        try:
            n = ser.in_waiting
        except Exception:                        # noqa: BLE001
            n = 0
        if n:
            n = min(int(n), max(1, int(self.read_size)))
        return ser.read(n if n else 1)

    def stop(self, join_timeout=1.5):
        self._stop.set()
        if self.is_alive():
            self.join(timeout=join_timeout)

    # ------------------------------------------------------------ 字节流分流
    @staticmethod
    def _find_sync(buf, head1, head2, limit=8192):
        """找一个可以重新同步的位置：遥测帧头 AA 55，或一个（可能还差几个字节的）应答头 5A。

        必须把应答头也算成同步点：重同步时只找 AA 55 会跳过夹在中间的 6 字节应答，
        导致"写命令拿不到应答"（截断的应答头 + 真应答同时躺在缓冲里时必现）。
        """
        n = min(len(buf), limit)
        i = 1
        while i < n:
            b = buf[i]
            if b == head1 and i + 1 < len(buf) and buf[i + 1] == head2:
                return i
            if b == REPLY_HEAD:
                if len(buf) - i < 6:
                    return i                     # 应答还没收全，停在原地等下一批
                if reply_ok(buf[i:i + 6]):
                    return i
            i += 1
        return -1

    def _skip_to_sync(self, buf, head1, head2):
        """丢掉 buf 里到下一个同步点为止的字节（并记账）。返回是否真的前进了。

        ★ 必须保证"至少前进 1 字节"：调用方在 while 里 continue，不前进就是死循环。
        缓冲上限兜底也放在这里（原来只在新同步分支里做）。
        """
        idx = self._find_sync(buf, head1, head2)
        if idx < 0:
            keep = 1
            if len(buf) <= keep:
                return False
            self.resync_bytes += len(buf) - keep
            del buf[:len(buf) - keep]
        else:
            self.resync_bytes += idx
            del buf[:idx]
        if len(buf) > 65536:                     # 兜底：缓冲别无限涨
            self.resync_bytes += len(buf) - 1024
            del buf[:len(buf) - 1024]
        return True

    def _pump(self, data, want_reply):
        """把新到的字节切分：18 字节遥测帧 → 解析；6 字节应答 → 收下。"""
        if self._dump_mode:
            self._pump_dump(data)
            return
        self.rx_bytes += len(data)
        self.buf += data
        buf = self.buf
        head1, head2 = us.HEAD1, us.HEAD2
        flen = us.FRAME_LEN

        while True:
            # 1) 完整且校验正确的应答
            if len(buf) >= 6 and buf[0] == REPLY_HEAD and reply_ok(buf[:6]):
                rep = bytes(buf[:6])
                del buf[:6]
                if want_reply:
                    # 一个读窗口里可能落进好几条应答（实测连发时就是这样），
                    # 只留最后一条会把前面的丢掉、命令永远等不齐 → 收进列表按序取
                    self._replies.append(rep)
                else:
                    self.stray_reply += 1        # 上一条命令迟到的应答，丢掉不误用
                continue
            # 2) 疑似应答开头但还没收全 ⇒ 等下一批字节
            if buf and buf[0] == REPLY_HEAD and len(buf) < 6:
                break
            # 2b) 缓冲还不足一帧、开头又不是帧头（脏字节挡着一条**已经收全**的应答）：
            #     立刻重同步。以前这里直接 break 等满 18 字节 —— 板子一停发遥测，
            #     那条应答就永远解析不出来，命令只能等到超时（自查发现）。
            if len(buf) >= 2 and len(buf) < flen and (buf[0] != head1 or buf[1] != head2):
                if self._skip_to_sync(buf, head1, head2):
                    continue
                break
            # 3) 帧还没收全 ⇒ 等
            if len(buf) < flen:
                break
            # 4) 帧头不对 ⇒ 重新同步（整段跳过，避免逐字节 del 的平方复杂度）
            if buf[0] != head1 or buf[1] != head2:
                self._skip_to_sync(buf, head1, head2)
                continue
            # 5) 一帧
            raw = bytes(buf[:flen])
            del buf[:flen]
            if us.frame_checksum(raw[2:17]) != raw[17]:
                self.crc_err += 1
                if len(self.bad_raw) < 5:
                    self.bad_raw.append(" ".join("%02X" % b for b in raw))
                continue
            f = _decode_frame(raw)
            if f is None:
                self.crc_err += 1
                continue
            self.frames_ok += 1
            if f["layout"] == "v2":
                self.layout_v2 += 1
            else:
                self.layout_v1 += 1
            # 原始 18 字节一起带上：S5 记录要把它原样写进 CSV（事后不靠上位机也能解帧）
            f["raw"] = raw
            self.batch.append(f)
            if len(self.batch) > 40000:          # 界面跟不上时保新弃旧
                self.dropped_frames += len(self.batch) - 20000
                del self.batch[:len(self.batch) - 20000]

    # ------------------------------------------------------------ 抓包 dump
    @staticmethod
    def _block_xor_ok(blk):
        """块尾 XOR：覆盖块头 7 B + 全部载荷，与 rtl/scope_dump.v 的 S_CHK 一致。"""
        x = 0
        for b in blk[:-1]:
            x ^= b
        return x == blk[-1]

    def _dump_finish(self, why=""):
        """结束 dump 模式，把没解析完的字节还给普通解析器（遥测要接着跑）。"""
        with self._dump_lock:
            leftover = bytes(self._dump_buf)
            self._dump_buf = bytearray()
            self._dump_mode = False
        if leftover:
            self.buf += leftover
        if why:
            self.dump_last_error = why
        self._dump_done.set()

    def _pump_dump(self, data):
        """dump 模式专用切分：264 B 块（可夹杂命令应答）；不解析遥测帧。"""
        self.rx_bytes += len(data)
        b = self._dump_buf
        b += data
        while True:
            if len(b) >= 6 and b[0] == REPLY_HEAD and reply_ok(b[:6]):
                self._replies.append(bytes(b[:6]))
                del b[:6]
                continue
            if len(b) >= 8 and bytes(b[:4]) == DUMP_HEAD:
                n = b[6]
                need = 8 + 4 * n
                if len(b) < need:
                    break
                blk = bytes(b[:need])
                if self._block_xor_ok(blk):
                    del b[:need]
                    self._dump_blocks.append(blk)
                    if len(self._dump_blocks) >= self._dump_want:
                        self._dump_finish()
                        return
                else:
                    self.dump_bad_blocks += 1
                    del b[:4]              # 头部校验失败：只丢 4 字节头，重新找
                continue
            if len(b) >= 8:
                i = b.find(DUMP_HEAD, 1)
                if i < 0:
                    # 没有块头：只留尾巴 3 字节（防止头被切断），其余记账丢掉
                    if len(b) > 3:
                        self.dump_resync += len(b) - 3
                        del b[:len(b) - 3]
                    break
                self.dump_resync += i
                del b[:i]
                continue
            break

    def capture_status(self):
        """读 CAP_STATUS（0x0724）并拆位；失败返回 None。"""
        d = self.read_reg(REG_CAP_STATUS, timeout=0.4, retries=2)
        if d is None:
            return None
        v = d["value"]
        return {"raw": v, "done": bool(v & 1), "armed": bool(v & 2),
                "trig": bool(v & 4), "busy": bool(v & 8), "ovf": bool(v & 0x10),
                "done_bit": bool(v & 1)}

    def capture_configure(self, src=0, dec_log2=1, length=CAP_DEPTH, trig=0,
                          level=0, pre=1024):
        """写抓包参数并 arm。返回 (ok, 出错寄存器名)。"""
        if not self.connected:
            return False, "串口未连接"
        length = max(1, min(int(length), CAP_DEPTH))
        pre = max(0, min(int(pre), length - 1))
        seq = ((REG_CAP_SRC, (int(src) & 1) | ((int(dec_log2) & 3) << 1)),
               (REG_CAP_LEN, length),
               (REG_CAP_TRIG, int(trig) & 3),
               (REG_CAP_LEVEL, int(level) & 0xFFFF),
               (REG_CAP_PRE, pre))
        for addr, val in seq:
            if self.write_reg(addr, val, verify=True) is None:
                return False, "写 0x%04X 超时" % addr
        if self.write_reg(REG_CAP_CTRL, 0x0001, verify=False) is None:
            return False, "写 0x0722（arm）超时"
        return True, ""

    def capture_wait_done(self, timeout=2.0, poll_s=0.02, want_trig=True):
        """轮询 CAP_STATUS 直到 done（或超时）。返回最后一次状态 dict 或 None。"""
        t_end = time.monotonic() + float(timeout)
        st = None
        while time.monotonic() < t_end:
            st = self.capture_status()
            if st is None:
                return None
            if st["done"]:
                return st
            if want_trig and not st["armed"] and not st["busy"]:
                # arm 位自己落了但 done 没来：多半是窗口/触发配置被拒
                time.sleep(poll_s)
            time.sleep(poll_s)
        return st

    def capture_dump(self, n_blocks, timeout=8.0):
        """启动 0x072E 批量 dump 并收齐 n_blocks 块。返回 blocks 列表（失败返回 None）。

        ★ 顺序很关键：必须**先**切到 dump 模式再写启动寄存器。设备在写脉冲后
          5 ms 才开始推流，所以那条命令的 6 字节应答仍能正常收下（在 dump 模式里
          也认得应答头），而 5 ms 之后到的块不会有一个字节被遥测解析器吃掉。
        """
        if not self.connected:
            self.dump_last_error = "串口未连接"
            return None
        n_blocks = int(n_blocks)
        if n_blocks <= 0:
            return []
        with self._dump_lock:
            self._dump_blocks = []
            self._dump_want = n_blocks
            self._dump_buf = bytearray()
            self.dump_bad_blocks = 0
            self.dump_resync = 0
            self.dump_last_error = ""
            self._dump_done.clear()
            self._dump_mode = True
        # ★ 不能因为"写 0x072E 没收到应答"就判失败：dump 一旦真正启动，UART 就归
        #   dump 独占（uart_spi_bridge 的 tx 切到 dump_tx），写命令的 6 字节应答
        #   可能被块流挤掉。实测就是这样：应答没来，但块照样在推。真正的判据是
        #   "收够块"，所以这里只记一笔，继续等 _dump_done。
        ack = self.write_reg(REG_CAP_DUMP_CTRL, 0x0001, verify=False,
                             timeout=0.5, retries=2)
        if ack is None:
            self.dump_last_error = ""       # 无应答≠失败，由下面的块计数裁决

        if not self._dump_done.wait(float(timeout)):
            got = len(self._dump_blocks)
            self._dump_finish("dump 超时：只收到 %d/%d 块" % (got, n_blocks))
            return None
        if self.dump_last_error:
            return None
        return list(self._dump_blocks)

    def capture_abort(self):
        """中止抓包 / dump（写 0x0722.bit1 与 0x072E.bit1），并退出 dump 模式。"""
        with self._dump_lock:
            if self._dump_mode:
                self._dump_mode = False
                self._dump_buf = bytearray()
                self._dump_done.set()
        try:
            self.write_reg(REG_CAP_DUMP_CTRL, 0x0002, verify=False, retries=1)
            self.write_reg(REG_CAP_CTRL, 0x0002, verify=False, retries=1)
        except Exception:                                         # noqa: BLE001
            pass

    # --------------------------------------------------------- 二期：连续流
    def stream_status(self):
        """读 0x0740~0x074E。返回 dict；任一寄存器读不到返回 None。

        ★ 顺序：先读控制/状态，再读 32 位计数器。计数器是自由运行的，
          两次读之间会变，所以"包数"和"丢样点"只在界面上做速率参考，
          不做逐包对账（对账靠 UDP 包头里的绝对序号）。
        """
        if not self.connected:
            return None
        c = self.read_reg(REG_CAP_STREAM_CTRL, timeout=0.4, retries=2)
        s = self.read_reg(REG_CAP_STREAM_STATUS, timeout=0.4, retries=2)
        if c is None or s is None:
            return None
        p_lo = self.read_reg(REG_CAP_STREAM_PKTS, timeout=0.4, retries=2)
        p_hi = self.read_reg(REG_CAP_STREAM_PKTS + 2, timeout=0.4, retries=2)
        d_lo = self.read_reg(REG_CAP_STREAM_DROP, timeout=0.4, retries=2)
        d_hi = self.read_reg(REG_CAP_STREAM_DROP + 2, timeout=0.4, retries=2)
        lag = self.read_reg(REG_CAP_STREAM_LAG, timeout=0.4, retries=2)
        if None in (p_lo, p_hi, d_lo, d_hi, lag):
            return None
        sv = s["value"]
        return {
            "enabled": bool(c["value"] & 1),
            "running": bool(sv & 1),
            "ovf": bool(sv & 2),
            "pkts": (p_lo["value"] & 0xFFFF) | ((p_hi["value"] & 0xFFFF) << 16),
            "drop": (d_lo["value"] & 0xFFFF) | ((d_hi["value"] & 0xFFFF) << 16),
            "lag": lag["value"] & 0xFFFF,
        }

    def stream_start(self, dec_log2=2):
        """开连续流：先写抽取比，再置 enable。返回 (ok, err)。"""
        if not self.connected:
            return False, "串口未连接"
        dec = max(1, min(int(dec_log2), 4))
        if self.write_reg(REG_CAP_STREAM_DEC, dec & 0x7, verify=True) is None:
            return False, "写 0x0742（抽取）超时"
        if self.write_reg(REG_CAP_STREAM_CTRL, 0x0001, verify=True) is None:
            return False, "写 0x0740（enable）超时"
        return True, ""

    def stream_stop(self):
        """关连续流（清 enable）。返回是否成功。"""
        if not self.connected:
            return False
        return self.write_reg(REG_CAP_STREAM_CTRL, 0x0000,
                              verify=False, retries=1) is not None

    # ------------------------------------------------------------ 命令执行
    def _execute(self, ser, req):
        """执行一条寄存器命令。读失败会自动重发；写走"写+读+读"三帧序列。"""
        if req.get("payloads"):
            self._execute_seq(ser, req)
            return
        payload = req["payload"]
        expect = req.get("expect_addr")
        for attempt in range(int(req["retries"])):
            if self._stop.is_set():
                break
            req["attempts"] = attempt + 1
            del self._replies[:]
            # 发命令前，先清掉缓冲区里"完整且已过期"的应答（上一条命令迟到的）
            self._drop_stale_replies()
            try:
                ser.write(payload)
                ser.flush()
            except Exception as exc:                              # noqa: BLE001
                # ★ 2026-10-17 全面自查修：以前只写进 req["error"]，全仓没有读它的
                #   地方 ⇒ 界面只显示"超时"，看不出是写失败（错误文本直接丢掉）。
                req["error"] = "写串口失败：%s" % exc
                self._emit_error(req["error"])
                return
            deadline = time.monotonic() + float(req["timeout"])
            while time.monotonic() < deadline and not self._stop.is_set():
                chunk = self._read_available(ser)
                if chunk:
                    self._pump(chunk, want_reply=True)
                got = self._collect(ser, req, expect, deadline)
                if got:
                    self.reply_ok += 1
                    req["reply"] = got[-1]
                    return
            self._flush_batch(force=False)
        self.reply_timeout += 1

    # 命令序列的时间参数：发完一帧留一点空隙，让这帧的应答来得及被读走
    SEQ_GAP_S = 0.006           # 帧间空隙（板子对每条命令立即回话，~0.3 ms）
    SEQ_TAIL_S = 0.05           # 序列收尾：最后一帧的应答可能稍慢

    def _collect(self, ser, req, expect, deadline, quiet=SEQ_GAP_S):
        """收应答：先掏已排队里的，再在 quiet 秒的安静窗口里等，返回列表（可为空）。"""
        out = []

        def _take():
            rep = self._take_reply()
            if rep is None:
                return False
            if expect is not None and VERIFY_ADDR_ECHO and rep[2] != (expect & 0xFF):
                # 地址不符 = 上一条命令的延迟应答，不能当成本次结果
                req.setdefault("mismatch", []).append(" ".join("%02X" % b for b in rep))
                return False
            out.append(rep)
            return True

        while _take():
            pass
        if out:
            return out
        end = min(time.monotonic() + float(quiet), deadline)
        while time.monotonic() < end and not self._stop.is_set():
            chunk = self._read_available(ser)
            if chunk:
                self._pump(chunk, want_reply=True)
            if _take():
                break
        return out

    def _execute_seq(self, ser, req):
        """按顺序连发多帧，把地址回显对得上的应答按到达顺序收下来。

        为什么要连发：这块板子（TW28 重叠语义）把"命令 N 的应答"放在第 N+1 帧才移出，
        所以只发一帧写命令是永远收不到自己应答的（现象：写明明生效，却报"写失败（超时）"）。
        写命令固定发 [写, 读, 读]，最后一帧的应答就是回读值。

        ★ 为什么改成"每发一帧收一轮"：板子对每条命令立即回一个应答，连发（帧间不留空隙）
          会把应答挤在一起丢掉（实测连发 4 帧只回 2 条），于是"收足 want 条才收工"的老判据
          永远不成立、循环只能睡满整个 timeout —— 界面每写一个寄存器卡 0.5 s 就是这么来的。
        """
        payloads = req["payloads"]
        expect = req.get("expect_addr")
        for attempt in range(int(req["retries"])):
            if self._stop.is_set():
                return
            req["attempts"] = attempt + 1
            del self._replies[:]
            self._drop_stale_replies()
            got = []
            deadline = time.monotonic() + float(req["timeout"])
            for i, pl in enumerate(payloads):
                if self._stop.is_set():
                    return
                try:
                    ser.write(pl)
                    ser.flush()
                except Exception as exc:                          # noqa: BLE001
                    req["error"] = "写串口失败：%s" % exc     # 同上：必须回流
                    self._emit_error(req["error"])
                    return
                last = (i + 1 == len(payloads))
                got += self._collect(ser, req, expect, deadline,
                                     quiet=self.SEQ_TAIL_S if last else self.SEQ_GAP_S)
                self._flush_batch(force=False)
            if got:
                self.reply_ok += 1
                req["replies"] = got
                req["reply"] = got[-1]       # 最后一帧的应答 = 写完之后回读到的值
                return
        self.reply_timeout += 1

    def _drop_stale_replies(self):
        buf = self.buf
        while len(buf) >= 6 and buf[0] == REPLY_HEAD and reply_ok(buf[:6]):
            del buf[:6]
            self.stray_reply += 1

    # ------------------------------------------------------------ 界面接口
    # 这几类事件丢了界面就回不到正确状态（"已连接"卡死 / 故障不提示），队列满时要挤掉老事件
    _CRITICAL_KINDS = ("open", "closed", "error")

    def _emit(self, kind, text, **extra):
        try:
            self.events.put_nowait((kind, text, extra))
        except queue.Full:
            if kind not in self._CRITICAL_KINDS:
                return
            # 队列被遥测批塞满（界面卡了一下）：丢掉最老的一条给关键事件腾地方，
            # 否则"线程已结束/串口出错"这类事件会被静默丢掉，界面一直停在"已连接"。
            try:
                old = self.events.get_nowait()
                if old and old[0] == "batch":
                    # 被挤掉的若是遥测批，那些帧就真没了 —— 必须记账，
                    # 否则"丢帧估计"会漏报（审计发现：挤掉不计数）
                    self.dropped_batches += 1
                    self.dropped_frames += len((old[2] or {}).get("frames") or ())
                self.events.put_nowait((kind, text, extra))
            except Exception:                                    # noqa: BLE001
                pass

    def _emit_error(self, text):
        self.error = text
        self._emit("error", text)

    def _flush_batch(self, force=False):
        now = time.monotonic()
        if not self.batch:
            if not force and (now - self._last_emit) < self.batch_s:
                return
            self._last_emit = now
            self._emit("stats", "", counters=self.counters())
            return
        if not force and (now - self._last_emit) < self.batch_s:
            return
        frames, self.batch = self.batch, []
        self._last_emit = now
        try:
            self.events.put_nowait(("batch", "", {"frames": frames,
                                                  "counters": self.counters()}))
        except queue.Full:
            self.dropped_batches += 1
            self.dropped_frames += len(frames)
            self._emit("stats", "", counters=self.counters())

    def counters(self):
        up = (time.monotonic() - self._t_open) if self._t_open else 0.0
        # 板上每帧 18 字节且固定 10 kHz ⇒ 被重同步吞掉的字节数除以 18 就是丢掉的帧数。
        # 频率/转速要按"帧时隙"计时，两类丢失都得算进去（详见 encoder.py 的说明）。
        lost = self.crc_err + self.resync_bytes // 18
        return {
            "uptime": up,
            "rx_bytes": self.rx_bytes,
            "frames": self.frames_ok,
            "crc_err": self.crc_err,
            "resync_bytes": self.resync_bytes,
            "lost_frames": lost,
            "stray_reply": self.stray_reply,
            "reply_ok": self.reply_ok,
            "reply_timeout": self.reply_timeout,
            "dropped_frames": self.dropped_frames,
            "dropped_batches": self.dropped_batches,
            "layout_v2": self.layout_v2,
            "layout_v1": self.layout_v1,
            "buf_len": len(self.buf),
            "bad_raw": list(self.bad_raw),
        }

    # ------------------------------------------------------ 寄存器读写（阻塞）
    def transact(self, payload, timeout=0.5, retries=3, expect_addr=None,
                 payloads=None):
        """提交一条命令（或一串命令）并等应答；返回 6 字节应答或 None（超时/串口已关）。

        payloads 不为空时按顺序连发这几帧（供"写 + 读 + 读"序列用），
        返回最后一个地址匹配的应答 —— 对写命令来说就是回读值。
        """
        if not self.connected or self._finished.is_set():
            return None
        req = {
            "payload": bytes(payload),
            "payloads": [bytes(p) for p in payloads] if payloads else None,
            "timeout": float(timeout),
            "retries": max(1, int(retries)),
            "expect_addr": expect_addr,
            "event": threading.Event(),
            "reply": None,
            "attempts": 0,
            "error": None,
        }
        with self._cmd_lock:
            if not self.connected:
                return None
            self._cmd_queue.append(req)
        budget = req["timeout"] * req["retries"] + 2.0
        # ★ wait 必须在锁外：以前在锁内等，别的线程调 read_reg/write_reg 会被这把锁
        #   挡住最多 budget（默认 3.5 s）；超时也只摘掉自己那条，别人的命令别动
        #   （队列形态下同样成立，用 deque/list 的 remove 精确摘自己）
        if not req["event"].wait(budget):
            with self._cmd_lock:
                try:
                    self._cmd_queue.remove(req)
                except ValueError:
                    pass
            return None
        with self._cmd_lock:
            try:
                self._cmd_queue.remove(req)
            except ValueError:
                pass
        if req["reply"] is None and req.get("mismatch"):
            self._emit("log", "应答地址不符（丢弃 %d 个延迟应答）: %s"
                       % (len(req["mismatch"]), req["mismatch"][-1]))
        return req["reply"]

    def read_reg(self, addr, timeout=0.5, retries=3):
        """读一个 16 位寄存器。返回 dict（含 value/hi/lo/raw）或 None。"""
        rep = self.transact(sp.encode_cmd(addr, write=False),
                            timeout=timeout, retries=retries, expect_addr=addr)
        if rep is None:
            return None
        d = parse_reply(rep)
        d["addr"] = addr & 0xFFFF
        return d

    def read_reg8(self, addr, timeout=0.5, retries=3):
        """读 8 位寄存器，只返回低字节。

        板子的 8 位寄存器（如 0x0500 ST_BITS、0x0501 MT_BITS）回读时**高字节是脏数据**
        （实测 0x0500 回 1307、0x0501 回 1029），所以 8 位寄存器一律用这个入口，
        不要直接用 read_reg()["value"]。16 位寄存器仍用 read_reg()。
        """
        d = self.read_reg(addr, timeout=timeout, retries=retries)
        if d is None:
            return None
        return d["lo"] & 0xFF

    def write_reg(self, addr, value, timeout=0.5, retries=1, verify=True):
        """写一个 16 位寄存器，并顺带回读（需求 M2：应用后自动回读比对）。

        ★ 必须连发三帧 [写, 读, 读]：板子（TW28 语义）把"命令 N 的应答"放在第 N+1 帧
          才移出，只发一帧写命令永远收不到自己的应答（现象：写明明生效却报"超时"）。
          中间那帧的应答是写的结果，最后一帧的应答是回读值。
        ★ 序列只发一遍、不重发：像 0x0502（启动标定）写两次会触发两次标定。

        返回：回读应答的 dict（含 value/hi/lo/raw/written），失败返回 None。
              注意 value 是"写完之后寄存器里的值"，不是写进去的值 ——
              W1C（如 0x0405）之类回读值与写入值本来就不同，比对交给调用方。
        """
        frames = [sp.encode_cmd(addr, value, write=True),
                  sp.encode_cmd(addr, write=False),
                  sp.encode_cmd(addr, write=False)]
        if verify:
            # 多补一帧读：链路偶发误码（实测 0.35%）可能让某个应答废掉，多一帧有余量
            frames.append(sp.encode_cmd(addr, write=False))
        rep = self.transact(frames[0], timeout=timeout, retries=retries,
                            expect_addr=addr, payloads=frames)
        if rep is None:
            return None
        d = parse_reply(rep)
        d["addr"] = addr & 0xFFFF
        d["written"] = value & 0xFFFF
        return d

    # --------------------------------------------------------------- 自检
    def read_device_info(self, timeout=0.5, retries=3):
        """读设备身份证：DEVICE_ID / REV / RTL_BUILD_ID（需求 M1 连接自检）。"""
        info = {"port": self.port, "baud": self.baud, "ok": False,
                "device_id": None, "rev": None, "rev2": None,
                "rtl_build": None, "raw": {}, "errors": []}

        d = self.read_reg(REG_DEVICE_ID, timeout=timeout, retries=retries)
        if d is None:
            info["errors"].append("读 0x%04X（设备型号）超时" % REG_DEVICE_ID)
        else:
            info["raw"]["0x%04X" % REG_DEVICE_ID] = d["hex"]
            info["device_id"] = d["lo"]       # 低字节 = DEVICE_ID
            info["rev"] = d["hi"]             # 高字节 = REV

        d = self.read_reg(REG_REV, timeout=timeout, retries=retries)
        if d is None:
            info["errors"].append("读 0x%04X（版本）超时" % REG_REV)
        else:
            info["raw"]["0x%04X" % REG_REV] = d["hex"]
            info["rev2"] = d["lo"]

        d = self.read_reg(REG_RTL_BUILD, timeout=timeout, retries=retries)
        if d is None:
            info["errors"].append("读 0x%04X（固件构建号）超时" % REG_RTL_BUILD)
        else:
            info["raw"]["0x%04X" % REG_RTL_BUILD] = d["hex"]
            info["rtl_build"] = d["value"]

        info["ok"] = not info["errors"]
        info["warnings"] = []
        if info["device_id"] is not None and info["device_id"] != EXPECT_DEVICE_ID:
            info["warnings"].append(
                "设备型号 0x%02X 与预期 0x%02X 不符" % (info["device_id"], EXPECT_DEVICE_ID))
        if info["rtl_build"] is not None and info["rtl_build"] not in (
                EXPECT_RTL_V11, EXPECT_RTL_V12, EXPECT_RTL_V13):
            info["warnings"].append("固件构建号 0x%04X 不在已知版本里" % info["rtl_build"])
        return info


# ---------------------------------------------------------------------------
# 便捷函数：列端口（给界面用）
# ---------------------------------------------------------------------------
def port_choices():
    import ports as ports_mod
    return ports_mod.list_serial_ports()
