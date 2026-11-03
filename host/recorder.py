r"""数据记录（需求 M6）：把遥测帧落成 CSV，并统计本次记录。

用法（在仓库根目录）：
    python host\recorder.py --selftest      # 离线自检（造帧→落盘→读回逐列比对）

设计要点（都在这一个文件里，界面只调用不实现）：
* **一行 = 一帧**：原始 18 字节帧（十六进制）+ 解析列 + 上位机时间戳，三样都写全，
  这样事后既不依赖上位机也能自己解帧，也不用担心解析口径改了就再也读不懂老文件。
* **时间戳按"帧时隙"回推**：板子遥测固定 10 kHz，上位机是每 50 ms 收一批。
  批内第 i 帧的时刻 = 本批到达时刻 − (批内剩余帧数) × 0.1 ms，批与批之间用真实到达
  时刻（这样链路卡了 3 秒，时间轴上就看得出 3 秒的台阶，不会凭空补出 3 万帧）。
* **自动分卷**：Excel 单表上限 1,048,576 行，10 kHz 下 1.7 分钟就写满，因此默认每卷
  100 万行、256 MB 封顶就换下一个文件（`…_part002.csv`），不让人拿到一个打不开的巨文件。
* **只依赖标准库**（Qt/串口都不碰）⇒ 可以离线自检、可以在无界面环境下跑长稳测试。

CSV 写法：`utf-8-sig`（带 BOM，Excel 直接双击不乱码）+ CRLF（Windows 记事本/Excel 友好）。
本文件落盘的数据文件不受仓库"源码必须 LF"的约束 —— 数据文件是给人用 Excel 打开的。
"""

import csv
import io
import os
import platform
import shutil
import sys
import tempfile
import time

# 板子遥测固定 10 kHz（rtl/uart_scope.v:132-133 SAMPLE_DIV = 5000，时钟 50 MHz）
FRAME_HZ = 10000.0
FRAME_DT = 1.0 / FRAME_HZ

ROWS_PER_PART_DEFAULT = 1000000          # Excel 单表上限 1,048,576 行，留点余量
MAX_MB_DEFAULT = 256.0

# 列名一律中文（需求 M6：给不懂电脑的使用者看）
CSV_COLUMNS = [
    "序号",              # 本次记录内的帧序号，从 1 开始、跨分卷连续
    "上位机时间",        # 2026-10-13 14:50:25.123（本机时钟）
    "相对时刻(s)",       # 相对"开始记录"的秒数，按帧时隙回推
    "原始帧(18B)",       # 36 个十六进制字符，含帧头 AA55 与校验字节
    "角度",              # 0…65535（一电周期 65536）
    "电角度(°)",
    "s_n", "c_n",        # 校正后 Q1.15 有符号
    "幅值平方",          # r² = s² + c²（与 rtl/amp_monitor.v 同式）
    "多周期位置",        # pos_full（22 位单圈位置，每 64 电周期回绕）
    "周期计数",          # pos_full[21:16]
    "状态字节",          # stat
    "状态位",            # stat 里置位的告警名，如 "oflow、adapt"
    "io_state",          # A B Z U V W dir limiter 打包字节（v2 布局才有）
    "io_flags",          # 告警位（v2 布局才有）
    "A", "B", "Z", "U", "V", "W",
    "方向",              # 正转 / 反转
    "限幅",              # 限幅中 / 正常
    "帧布局",            # v2 / v1（v1 没有电平列，对应格留空）
]

STATE_NAMES = ["正转", "反转"]


def _part_path(path, part):
    """第 part 卷的路径：part = 1 就是原路径，之后插 `_partNNN`。"""
    if part <= 1:
        return path
    root, ext = os.path.splitext(path)
    return "%s_part%03d%s" % (root, part, ext)


def _unique_path(path):
    """撞名就加 -2/-3…：默认文件名只到秒，同一秒重开会把上一段记录截断。"""
    if not os.path.exists(path):
        return path
    root, ext = os.path.splitext(path)
    for i in range(2, 1000):
        cand = "%s-%d%s" % (root, i, ext)
        if not os.path.exists(cand):
            return cand
    return "%s-%d%s" % (root, int(time.time()), ext)


def _stamp(t_wall):
    """本机时钟 → '2026-10-13 14:50:25.123'。"""
    lt = time.localtime(t_wall)
    return "%s.%03d" % (time.strftime("%Y-%m-%d %H:%M:%S", lt),
                        int((t_wall - int(t_wall)) * 1000.0) % 1000)


def default_dir():
    """默认保存位置：我的文档\\host_app记录（没有就退到桌面、再退到当前目录）。

    ★ 目录名刻意保持中文：它是**用户机器上的保存目录**，不是仓库里的文件，
      不受竞赛"仓库内目录名/文件名必须纯英文"的约束（那条只管提交进仓库的东西），
      中文目录对中文用户更友好。真正要纯英文的是 **CSV 文件本身**
      （`encoder_record_YYYYmmdd_HHMMSS.csv`），这样脚本与跨平台工具都能直接处理。
    """
    cands = []
    home = os.path.expanduser("~")
    # 中文 Windows 的"文档"目录真名可能是"文档"，用注册表无关的常见两种拼法
    for name in ("Documents", "文档"):
        cands.append(os.path.join(home, name))
    cands.append(os.path.expanduser("~/Desktop"))
    cands.append(os.getcwd())
    for c in cands:
        if os.path.isdir(c):
            return os.path.join(c, "host_app记录")
    return os.path.join(os.getcwd(), "host_app记录")


# ---- 阶段 5（D 批，用户 m15713 第 14 条）：记录目录的"能不能写"必须提前查清
#      —— `open()` 抛出来的只有 PermissionError(13)，看不出是"受控文件夹访问"
#      拦了、还是被 Excel 占着、还是目录只读。先用探针文件试一次，失败就说清楚
#      原因并自动换一个能写的位置，绝不让用户"点了没反应"。
PROBE_NAME = ".host_app_write_probe"


def probe_writable(path):
    """探测目录能不能写：建目录 + 真写一个探针文件再删掉。返回 (ok, 说明)。

    只用 `os.access()` 是不够的：Windows 上"受控文件夹访问"是运行时拦截，
    access() 照样报可写。必须真写一次。
    """
    if not path:
        return False, "路径是空的"
    try:
        if not os.path.isdir(path):
            os.makedirs(path)
    except Exception as exc:                                        # noqa: BLE001
        return False, "建不了文件夹：%s" % exc
    ok, why, _exc = _probe_once(path)
    return ok, why


def dir_hint(exc):
    """把 open()/建目录的异常翻译成"人话 + 下一步怎么做"。"""
    txt = "%s" % exc
    low = txt.lower()
    if isinstance(exc, PermissionError) or "permission denied" in low or "errno 13" in low:
        return ("拒绝访问 —— 常见四种原因："
                "①Windows「受控文件夹访问」（勒索软件防护）把本程序挡在桌面/文档之外，"
                "到「Windows 安全中心 → 病毒和威胁防护 → 勒索软件防护 → "
                "允许应用通过受控文件夹访问」里把 host_app.exe 加进去；"
                "②这个文件正被 Excel/记事本/看图工具打开（先关掉再试）；"
                "③目录只读或属于别的账户（右键 → 属性 → 安全，看当前用户有没有「写入」）；"
                "④在**管理员**窗口里试写成功、而本程序写不进去 ⇒ 说明是目录的权限/"
                "完整性级别在挡普通权限进程，换一个目录最快（点「写入诊断」可看细节）。")
    if isinstance(exc, FileNotFoundError) or "no such file" in low:
        return "路径不存在（盘符或目录被删了？换一个保存目录即可）。"
    if "space" in low or "disk full" in low:
        return "磁盘空间不足，清理后重试（或换到空间大的盘）。"
    return "换一个保存目录再试；若仍失败，把这条原文发给开发者。"


def fallback_dirs():
    """能写的备选保存目录（按优先级）：我的文档 → 桌面 → 本机 AppData → 临时目录。"""
    home = os.path.expanduser("~")
    cands = [os.path.join(home, "Documents", "host_app记录"),
             os.path.join(home, "文档", "host_app记录"),
             os.path.join(home, "Desktop", "host_app记录"),
             os.path.join(home, "host_app记录")]
    local = os.environ.get("LOCALAPPDATA")
    if local:
        cands.append(os.path.join(local, "host_app记录"))
    cands.append(os.path.join(tempfile.gettempdir(), "host_app记录"))
    seen, out = set(), []
    for c in cands:
        key = os.path.normcase(os.path.abspath(c))
        if key not in seen:
            seen.add(key)
            out.append(c)
    return out


# ---- 阶段 5 补丁（用户 m16915「打不开文件夹 / 记录不进去」）：
#      同一台机器上，**管理员** PowerShell 能往目标目录写字，而普通权限的本程序被
#      拒（Errno 13）—— 光看 ACL 看不出来，必须把"谁在写、写到哪一级被挡、受控文件夹
#      访问开没开"一次性摊开。下面这些函数只做只读探测，不产生任何副作用（探针文件
#      写完就删）。
def is_admin():
    """当前进程是不是以管理员身份跑（诊断报告里要写清楚，否则会误导排查方向）。"""
    try:
        import ctypes                                             # noqa: PLC0415
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:                                             # noqa: BLE001
        return None


def _errno_of(exc):
    """异常 → (errno, winerror, 类型名)；取不到就给 None。"""
    return (getattr(exc, "errno", None), getattr(exc, "winerror", None),
            type(exc).__name__)


def _probe_once(path):
    """写一个探针文件（不建目录），返回 (ok, 说明, exc)。"""
    probe = os.path.join(path, PROBE_NAME)
    try:
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("ok")
    except Exception as exc:                                      # noqa: BLE001
        return False, "%s" % exc, exc
    try:
        os.remove(probe)
    except Exception as exc:                                      # noqa: BLE001
        return False, "写进去了但删不掉：%s" % exc, exc
    return True, "", None


def diag_write(path):
    """对一个目录做一次真写诊断，返回结构化结果（给「写入诊断」按钮与自检用）。"""
    out = {"path": path, "exists": None, "mkdir": None, "mkdir_err": None,
           "write_ok": False, "write_err": None, "errno": None, "winerror": None,
           "exc_type": None, "readonly": None, "parent": None, "parent_ok": None,
           "parent_err": None, "hint": ""}
    if not path:
        out["hint"] = "路径是空的"
        return out
    out["exists"] = os.path.isdir(path)
    if not out["exists"]:
        try:
            os.makedirs(path)
        except Exception as exc:                                  # noqa: BLE001
            out["mkdir"] = False
            out["mkdir_err"] = "%s" % exc
            out["errno"], out["winerror"], out["exc_type"] = _errno_of(exc)
            out["hint"] = dir_hint(exc)
            return out
        out["mkdir"] = True
    try:
        import stat as _stat                                      # noqa: PLC0415
        out["readonly"] = bool(os.stat(path).st_mode & _stat.S_IWRITE) is False
    except Exception:                                             # noqa: BLE001
        pass
    ok, why, exc = _probe_once(path)
    out["write_ok"] = ok
    if not ok:
        out["write_err"] = why
        if exc is not None:
            out["errno"], out["winerror"], out["exc_type"] = _errno_of(exc)
        out["hint"] = dir_hint(exc) if exc is not None else why
    # 上级目录：定位"是这一级被挡，还是从某一级往下都写不了"
    par = os.path.dirname(os.path.abspath(path))
    if par and os.path.isdir(par) and os.path.normcase(par) != os.path.normcase(path):
        out["parent"] = par
        pok, pwhy, _pexc = _probe_once(par)
        out["parent_ok"] = pok
        out["parent_err"] = None if pok else pwhy
    return out


def cfa_state():
    """读 Windows「受控文件夹访问」的开关（读不到就 None）。"""
    out = {"enabled": None, "hklm": None, "hkcu": None, "allowed": None}
    try:
        import winreg                                             # noqa: PLC0415
    except Exception:                                             # noqa: BLE001
        return out
    sub = (r"SOFTWARE\Microsoft\Windows Defender\Windows Defender Exploit Guard"
           r"\Controlled Folder Access")
    for hive, name in ((winreg.HKEY_LOCAL_MACHINE, "hklm"),
                       (winreg.HKEY_CURRENT_USER, "hkcu")):
        try:
            with winreg.OpenKey(hive, sub) as k:
                out[name] = int(winreg.QueryValueEx(k, "EnableControlledFolderAccess")[0])
        except Exception:                                         # noqa: BLE001
            out[name] = None
    for val in (out["hkcu"], out["hklm"]):
        if val is not None:
            out["enabled"] = bool(val)
            break
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, sub + r"\AllowedApplications") as k:
            n = winreg.QueryInfoKey(k)[1]
            out["allowed"] = [str(winreg.EnumValue(k, i)[1]) for i in range(min(n, 40))]
    except Exception:                                             # noqa: BLE001
        out["allowed"] = None
    return out


def pick_dir(prefer=None):
    """启动时挑一个**真的能写**的默认目录。

    默认的"我的文档\\host_app记录"在开了受控文件夹访问的机器上写不进去；与其等到用户
    点了"开始记录"再悄悄改存，不如一上来就显示一个能写的目录（并且说清楚为什么换了）。
    返回 (目录, 说明)；说明为 "" 表示就是首选目录、无需解释。
    """
    first = prefer or default_dir()
    ok, _why = probe_writable(first)
    if ok:
        return first, ""
    for cand in fallback_dirs():
        if os.path.normcase(os.path.abspath(cand)) == os.path.normcase(os.path.abspath(first)):
            continue
        ok2, _why2 = probe_writable(cand)
        if ok2:
            return cand, ("默认目录 %s 写不进去（%s），已改到 %s"
                          % (first, _why, cand))
    return first, ""


def writable_dir_or_fallback(path):
    """导出/记录前的统一入口：返回 (可用目录, 是否换过, 说明)。

    换过的目录必定通过了真写探针；全都不可写时原样返回（让调用方去报错）。
    """
    if path and probe_writable(path)[0]:
        return path, False, ""
    why = ""
    if path:
        try:
            with open(os.path.join(path, PROBE_NAME), "w", encoding="utf-8") as fh:
                fh.write("ok")
            os.remove(os.path.join(path, PROBE_NAME))
        except Exception as exc:                                  # noqa: BLE001
            why = "%s" % exc
    for cand in fallback_dirs():
        if path and os.path.normcase(os.path.abspath(cand)) == os.path.normcase(os.path.abspath(path)):
            continue
        if probe_writable(cand)[0]:
            return cand, True, why
    return path, False, why


def acl_report(path, limit=28):
    """调 `icacls` 看目录的所有者与授权（失败就返回一句说明）。

    ★ 为什么值得单独跑一次外部命令：`Errno 13` 自己分不清"ACL 授权不足"、
    "完整性级别在挡"还是"杀软拦了一下"，而 `icacls` 的输出能把前两种直接摊开，
    这是排查效率最高的一条证据。
    """
    if os.name != "nt" or not path:
        return ["（非 Windows 或路径为空，跳过）"]
    try:
        import subprocess                                          # noqa: PLC0415
        out = subprocess.run(["icacls", path], capture_output=True, text=True,
                             timeout=6, errors="replace")
        lines = (out.stdout or out.stderr or "").splitlines()
        return [ln.rstrip() for ln in lines[:limit]] or ["（icacls 没有输出）"]
    except Exception as exc:                                        # noqa: BLE001
        return ["（跑不了 icacls：%s）" % exc]


_IL_TEXT = {0: "Untrusted", 4096: "Low", 8192: "Medium", 12288: "Medium+",
            16384: "High", 28672: "System"}


def token_flags():
    """用 ctypes 读本进程令牌：受限令牌？受限 SID 数？完整性级别？提权？会话？

    ★ 为什么非查不可：`Errno 13 / WinError 5` 分不清三种完全不同的根因 ——
    ①ACL 没授权；②杀软/受控文件夹访问拦了一下；③**本进程被降权或带受限令牌**
    （"工作区内能写、工作区外一律拒"就是第 ③ 种的典型形状，与文件权限无关）。
    前两种看 icacls/注册表，第三种只能从令牌本身看出来。
    """
    out = {"integrity": None, "has_restrictions": None, "restricted_sids": None,
           "elevated": None, "session": None, "token_type": None}
    if os.name != "nt":
        return out
    try:
        import ctypes                                             # noqa: PLC0415
        from ctypes import wintypes                               # noqa: PLC0415
        adv, k32 = ctypes.windll.advapi32, ctypes.windll.kernel32
        # ★ 必须显式声明 argtypes/restype：64 位下 HANDLE 与指针走默认 c_int 会截断，
        #   结果就是"每个查询都失败、全部读不到"（第一版就踩了这个坑）。
        adv.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                         ctypes.POINTER(wintypes.HANDLE)]
        adv.OpenProcessToken.restype = wintypes.BOOL
        adv.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                            ctypes.c_void_p, wintypes.DWORD,
                                            ctypes.POINTER(wintypes.DWORD)]
        adv.GetTokenInformation.restype = wintypes.BOOL
        adv.GetSidSubAuthorityCount.argtypes = [ctypes.c_void_p]
        adv.GetSidSubAuthorityCount.restype = ctypes.POINTER(ctypes.c_ubyte)
        adv.GetSidSubAuthority.argtypes = [ctypes.c_void_p, wintypes.DWORD]
        adv.GetSidSubAuthority.restype = ctypes.POINTER(wintypes.DWORD)
        token = wintypes.HANDLE()
        if not adv.OpenProcessToken(k32.GetCurrentProcess(), 0x0008,
                                    ctypes.byref(token)):
            return out
        need = wintypes.DWORD(0)

        def _dword(info_class):
            val = wintypes.DWORD(0)
            if adv.GetTokenInformation(token, info_class, ctypes.byref(val),
                                       ctypes.sizeof(val), ctypes.byref(need)):
                return val.value
            return None

        out["token_type"] = _dword(8)                             # 1=主令牌 2=模拟
        out["session"] = _dword(12)
        out["elevated"] = _dword(20)
        r = _dword(21)                                            # TokenHasRestrictions
        out["has_restrictions"] = None if r is None else bool(r)
        buf = ctypes.create_string_buffer(4096)                   # TokenRestrictedSids
        if adv.GetTokenInformation(token, 11, buf, ctypes.sizeof(buf),
                                   ctypes.byref(need)):
            out["restricted_sids"] = ctypes.cast(
                buf, ctypes.POINTER(wintypes.DWORD))[0]
        buf2 = ctypes.create_string_buffer(256)                   # TokenIntegrityLevel
        if adv.GetTokenInformation(token, 25, buf2, ctypes.sizeof(buf2),
                                   ctypes.byref(need)):
            sid = ctypes.cast(buf2, ctypes.POINTER(ctypes.c_void_p))[0]
            n = adv.GetSidSubAuthorityCount(sid)[0]
            rid = adv.GetSidSubAuthority(sid, n - 1)[0]
            out["integrity"] = "%s（S-1-16-%d）" % (_IL_TEXT.get(rid, "未知"), rid)
    except Exception:                                             # noqa: BLE001
        pass
    return out


def parent_process():
    """父进程的 (pid, 可执行文件路径/名字)；拿不到就给 (pid, "")。

    ★ 用途：确认"到底是双击启动的，还是被某个工具/IDE 拉起来的" ——
    双击的话父进程是 explorer.exe；被开发工具或沙箱拉起来时不是，
    而后者常常附带受限令牌（现象与"权限不足"一模一样）。
    """
    pid = None
    try:
        pid = os.getppid()
    except Exception:                                             # noqa: BLE001
        return None, ""
    if os.name != "nt" or not pid:
        return pid, ""
    try:
        import ctypes                                             # noqa: PLC0415
        from ctypes import wintypes                               # noqa: PLC0415
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, int(pid))              # LIMITED_INFORMATION
        if not h:
            return pid, ""
        size = wintypes.DWORD(1024)
        buf = ctypes.create_unicode_buffer(size.value)
        if k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return pid, buf.value
        return pid, ""
    except Exception:                                             # noqa: BLE001
        return pid, ""


def env_warning():
    """本进程是否跑在受限/低完整性环境里？是就给一句人话提示，否则给 ""。

    ★ 这是"记录不进去"最容易被误判成"软件坏了"的一种情形：进程被降权或带受限令牌时，
    工作目录能写、文档/桌面一律拒绝 —— 现象与"权限不足"一模一样，但换目录/放行杀软都没用，
    只有换个启动方式（从资源管理器双击）才好。所以界面上必须直说。
    """
    tk = token_flags()
    il = tk["integrity"] or ""
    low = ("Low" in il) or ("Untrusted" in il)
    if low:
        return ("当前程序跑在**低完整性**（沙箱）里（完整性级别 %s）："
                "只有程序自己能写的那几个目录可用；请从资源管理器双击 host_app.exe 运行，"
                "或直接把记录保存到下面这个目录。") % il
    if tk["has_restrictions"]:
        return ("当前程序带着**受限令牌**运行（完整性级别 %s）：部分目录会被系统拒绝，"
                "建议从资源管理器双击 host_app.exe 再试一次。" % (il or "未知"))
    return ""


def write_diagnosis(path):
    """生成一份可直接粘贴的"为什么写不进去"报告（纯文本）。"""
    lines = []
    lines.append("host_app 写入诊断")
    d = diag_write(path)
    lines.append("程序位置   : %s" % (getattr(sys, "executable", "") or sys.argv[0]))
    lines.append("当前目录   : %s" % os.getcwd())
    lines.append("用户       : %s%s" % (os.environ.get("USERNAME", "?"),
                                        "（管理员）" if is_admin() else
                                        ("（普通权限）" if is_admin() is False else "")))
    lines.append("Windows    : %s" % platform.platform())
    # ★ 沙箱指纹：如果这个程序是被带受限令牌的开发工具（DSH）拉起来的，它会继承
    #   DSH_* 环境变量，而且只能写工作目录 —— 现象和"权限不足"一模一样，但根因完全不同
    #   （双击 exe 运行就正常）。把这条证据写进报告，免得两边都往错误方向排查。
    dsh = sorted(k for k in os.environ if k.upper().startswith("DSH"))
    lines.append("沙箱指纹   : %s" % ("、".join(dsh) if dsh
                                      else "无 DSH_* 环境变量"))
    # ★ 环境变量只是"指纹"，不是证据（启动器可以不传）：真正能定性的是**令牌本身**。
    tk = token_flags()
    ppid, pexe = parent_process()
    lines.append("")
    lines.append("── 进程身份 ──")
    lines.append("进程号     : %s（父进程 %s，pid %s）"
                 % (os.getpid(), (os.path.basename(pexe) if pexe else "看不到"),
                    ppid))
    lines.append("完整性级别 : %s" % (tk["integrity"] or "读不到"))
    lines.append("受限令牌   : %s%s"
                 % ({True: "是", False: "否", None: "读不到"}[tk["has_restrictions"]],
                    "" if tk["restricted_sids"] is None
                    else "（受限 SID 数 %s）" % tk["restricted_sids"]))
    lines.append("令牌类型   : %s（提权：%s，会话 %s）"
                 % ({1: "主令牌", 2: "模拟令牌", None: "读不到"}[tk["token_type"]],
                    {True: "是", False: "否", None: "?"}[tk["elevated"]],
                    tk["session"]))
    lines.append("")
    lines.append("── 目标目录 ──")
    lines.append("路径       : %s" % path)
    lines.append("存在       : %s%s" % ("是" if d["exists"] else "否",
                                       "" if d["mkdir"] is None else
                                       ("（已自动建出来）" if d["mkdir"] else
                                        "（建不了：%s）" % d["mkdir_err"])))
    lines.append("只读属性   : %s" % ({True: "是", False: "否", None: "未知"}[d["readonly"]]))
    if d["write_ok"]:
        lines.append("写探针     : 成功（这个目录其实能写）")
    else:
        lines.append("写探针     : 失败 —— %s" % d["write_err"])
        lines.append("错误码     : errno=%s winerror=%s 类型=%s"
                     % (d["errno"], d["winerror"], d["exc_type"]))
    if d["parent"]:
        lines.append("上级目录   : %s —— %s" % (d["parent"],
                                            "能写" if d["parent_ok"]
                                            else "也写不了（%s）" % d["parent_err"]))
    lines.append("")
    lines.append("── 受控文件夹访问（勒索软件防护）──")
    cfa = cfa_state()
    state = {True: "已开启", False: "已关闭", None: "读不到（多半没权限，属正常）"}
    lines.append("总开关     : %s（HKLM=%s / HKCU=%s）"
                 % (state[cfa["enabled"]], cfa["hklm"], cfa["hkcu"]))
    if cfa["allowed"] is None:
        lines.append("放行名单   : 读不到（要用管理员 PowerShell 才能看）")
    else:
        hit = [a for a in cfa["allowed"] if "host_app" in a.lower()]
        lines.append("放行名单   : %d 条；%s"
                     % (len(cfa["allowed"]),
                        "host_app.exe 已在名单里" if hit else "名单里没有 host_app.exe"))
    lines.append("")
    lines.append("── 权限（icacls）──")
    for ln in acl_report(path):
        lines.append(ln)
    lines.append("")
    lines.append("── 备选目录能不能写 ──")
    for cand in fallback_dirs():
        ok, why = probe_writable(cand)
        lines.append("%-10s : %s" % ("可写" if ok else "不可写", cand if ok
                                     else "%s（%s）" % (cand, why)))
    lines.append("")
    lines.append("── 结论 ──")
    low_il = bool(tk["integrity"] and ("Low" in tk["integrity"]
                                       or "Untrusted" in tk["integrity"]))
    if low_il or tk["has_restrictions"]:
        lines.append("★ 本进程跑在**受限/低完整性**令牌下（完整性级别 %s，受限令牌 %s）"
                     "—— 这就是「工作区内能写、工作区外一律拒」的原因：不是文件权限问题。"
                     "请直接从资源管理器双击 %s 运行（别经 IDE、脚本宿主或某些启动器），"
                     "或改用上面「可写」的那几个目录。"
                     % (tk["integrity"], "是" if tk["has_restrictions"] else "否",
                        os.path.basename(getattr(sys, "executable", "host_app.exe"))))
    elif d["write_ok"]:
        lines.append("目标目录现在能写。若刚才失败过，多半是当时那个文件被占用"
                     "（Excel/看图工具还开着），或杀软拦了一下 —— 重试即可。")
    else:
        lines.append(d["hint"] or "换一个能写的目录（见上面「可写」那几行）。")
        if cfa["enabled"]:
            lines.append("★ 这台机器的「受控文件夹访问」是**开启**的，而名单里"
                         "没有 host_app.exe —— 这与现象吻合，建议按上面第 ① 条放行。")
        if is_admin():
            lines.append("★ 注意：本次是**管理员**权限跑的，能写不代表普通权限也能写。")
        elif pexe and "explorer" not in os.path.basename(pexe).lower() and not low_il:
            lines.append("★ 父进程是 %s（不是 explorer.exe）⇒ 本次不是双击启动，"
                         "而是被某个工具拉起来的；请双击再试一次，用两次结果对比。"
                         % os.path.basename(pexe))
    return "\n".join(lines)


def default_name(t_wall=None):
    return "encoder_record_%s.csv" % time.strftime("%Y%m%d_%H%M%S",
                                               time.localtime(t_wall or time.time()))


class Recorder(object):
    """把一帧帧遥测数据写进 CSV（可跨分卷），并维护本次记录的统计。

    界面用法：
        rec = Recorder(path, notice=self._on_record_notice)
        rec.start()
        ... rec.feed(frames, n_bad=k)   # 每次界面取到一批帧就喂进来
        rec.stop()
        rec.stats()                     # 时长/帧数/校验错/丢帧估计…

    出错（磁盘满、路径不可写）不抛异常：置 `error` 并停表，由界面提示 —— 绝不能让
    记录失败把整个界面带崩。
    """

    def __init__(self, path, max_rows=ROWS_PER_PART_DEFAULT,
                 max_mb=MAX_MB_DEFAULT, notice=None):
        self.path = os.path.abspath(path)
        # 上限做合法性钳位：max_rows=0/-1 会让"每帧一卷"（自检里真出过 5 帧 6 个文件），
        # max_mb<=0 视为不限体积（默认 256 MB）
        self.max_rows = max(1, int(max_rows))
        self.max_mb = max(0.0, float(max_mb))
        self.notice = notice                  # callable(text, level) 或 None

        self.active = False
        self.error = None
        self.t_start_mono = None
        self.t_start_wall = None
        self.t_last_mono = None

        self.rows = 0                          # 本次记录总行数（跨分卷）
        self.bytes = 0                         # 本次记录总字节（跨分卷）
        self.lost = 0                          # 累计"丢帧估计"（校验错 + 重同步 + 队列丢批）
        self.parts = 0
        self.files = []                        # 实际写出的文件路径

        self._fh = None
        self._wr = None
        self._part = 0
        self._part_rows = 0
        self._part_bytes = 0
        self._bytes_done = 0                   # 已封卷的字节数（用于累计体积）
        self._no_raw_noticed = False
        self.did_fallback = False              # 阶段 5：本次是否因目录不可写而换了位置


    # ------------------------------------------------------------------ 开/停
    def start(self, t_mono=None, t_wall=None):
        """开始记录：建目录、开文件、写表头。返回 True/False（False 见 self.error）。"""
        if self.active:
            return True
        self.error = None
        self.rows = self.bytes = self.lost = 0
        self.parts = 0
        self.files = []
        self._part = 0
        self._part_rows = 0
        self._part_bytes = 0
        # ★ 阶段 5（D 批，用户 m15713 第 14 条）：先探一次"这个目录到底能不能写"。
        #   不可写就自动换到能写的位置并把原因说清楚 —— 老实现只会在 open() 失败时
        #   甩一句 "[Errno 13] Permission denied"，用户根本不知道该改哪里。
        d = os.path.dirname(self.path)
        ok, why = probe_writable(d)
        if not ok:
            moved = None
            for cand in fallback_dirs():
                ok2, _ = probe_writable(cand)
                if ok2:
                    moved = cand
                    break
            if moved is None:
                self.error = ("打不开记录文件：%s（%s）%s"
                              % (self.path, why, dir_hint(why)))
                self._notify(self.error, "fault")
                return False
            old_dir = d
            self.path = os.path.join(moved, os.path.basename(self.path))
            self.did_fallback = True
            self._notify("保存目录 %s 不可写（%s）⇒ 本次记录自动改存到 %s"
                         % (old_dir, why, moved), "warn")
            self._notify(dir_hint(why), "warn")

        # ★ 默认文件名只精确到秒：同一秒内"停止→开始"会撞名，而 _open_part 是 "w" 打开，
        #   上一段记录会被静默截断（真踩过：100 行的文件变成 4 行）。这里自动改名。
        self.path = _unique_path(self.path)
        if not self._open_part(1):
            return False
        self.t_start_mono = float(t_mono if t_mono is not None else time.monotonic())
        self.t_start_wall = float(t_wall if t_wall is not None else time.time())
        self.t_last_mono = self.t_start_mono
        self.active = True
        self._notify("开始记录：%s" % self.files[-1], "ok")
        return True

    def _close_part(self):
        """关当前卷的句柄（flush 失败也要关，且先置空再关，避免半关状态）。"""
        fh = self._fh
        self._fh = self._wr = None
        if fh is None:
            return
        try:
            fh.flush()
        except Exception:                                           # noqa: BLE001
            pass
        try:
            fh.close()
        except Exception:                                           # noqa: BLE001
            pass

    def stop(self, t_mono=None):
        """停止记录并收尾（关文件）。返回本次统计。"""
        fh = self._fh
        self._fh = self._wr = None
        if fh is not None:
            try:
                fh.flush()
            except Exception as exc:                                # noqa: BLE001
                self.error = "关闭记录文件时出错：%s" % exc
            finally:
                # flush 抛错也必须 close，否则句柄留到 GC、错误信息还会被真因覆盖
                try:
                    fh.close()
                except Exception as exc:                            # noqa: BLE001
                    if not self.error:
                        self.error = "关闭记录文件时出错：%s" % exc
        was = self.active
        self.active = False
        if was:
            self.t_last_mono = float(t_mono if t_mono is not None
                                     else time.monotonic())
            self._notify("已停止记录：共 %s 帧 / %s 个文件 / %s"
                         % (format(self.rows, ","), self.parts,
                            _size_text(self.bytes)), "ok")
        return self.stats()

    def toggle(self):
        """界面"开始记录/停止记录"按钮：切换状态。

        返回 stop() 的统计（刚停表时）或 start() 的 True/False（刚开表时）——
        以前开表成功失败都返回 None，调用方没法判断到底开没开起来。
        """
        if self.active:
            return self.stop()
        return self.start()

    # -------------------------------------------------------------------- 写
    def feed(self, frames, n_bad=0, n_drop=0, t_mono=None):
        """写一批帧。frames = 帧 dict 列表（link.py 解析出来的，带 'raw' 更好）。

        n_bad  = 板上发出的、校验错/重同步吞掉所以到不了我这儿的帧数（算进"丢帧估计"）；
        n_drop = 链路事件队列满被丢掉的帧数（同上，也算丢失——记录文件里同样没有）。

        返回真正写下的行数。卷写满会在**写之前**换卷，所以每一卷都是干净的整块
        （不会出现"这一卷 150 万行、Excel 打不开"或"每卷都超出上限一点"）。
        """
        if not self.active or self._wr is None:
            return 0
        # 丢失计数先记上：这一批可能一帧都没到（批全被链路丢了），但"少了几帧"必须算数
        self.lost += max(0, int(n_bad or 0)) + max(0, int(n_drop or 0))
        if not frames:
            return 0
        now = float(t_mono if t_mono is not None else time.monotonic())
        n = len(frames)
        # 时间戳分两步定：
        # ① 本批最后一帧 = 本批到达时刻（板上 10 kHz 发帧，到达时刻就是最好的锚点）；
        # ② 本批这 n 帧铺在 [t_lo, t_end] 上——t_lo 按 0.1 ms/帧 回推，但**不许早于上一批
        #    的末帧**。界面每 100 ms 才把攒下来的一批交给记录器，一次 feed 常常含好几个
        #    50 ms 批；若一律用 "t_end - (n-1)×0.1ms" 回推，这批的头就会落到**上一批之前**，
        #    CSV 里就会出现时间倒流（真踩过：自检报"相对时刻不是单调递增"）。
        t_end = now
        if self.t_last_mono is not None:
            # 外部传进来的 t_mono 可能比上一批还早（时钟回拨/调用方用错时钟）：
            # 钳住并让步长为 0，宁可这一批时间戳相同，也不要写出负的、倒流的相对时刻
            t_end = max(t_end, self.t_last_mono)
        t_lo = t_end - n * FRAME_DT
        if self.t_last_mono is not None and t_lo < self.t_last_mono:
            t_lo = self.t_last_mono
        step = max(0.0, (t_end - t_lo) / n) if n else 0.0
        base = self.rows
        written = 0
        while written < n:
            # 先把"这一卷还装得下几行"算出来，装不下就换卷再写
            if self._full():
                self._rotate()
                if self._wr is None:                                # 换卷失败已自停
                    break
            room = self._room()
            take = frames[written:written + room]
            rows = []
            for j, f in enumerate(take):
                i = written + j
                t_i = t_lo + (i + 1) * step
                rel = t_i - self.t_start_mono
                # t_end 是单调时钟（可能等于开机秒数），墙上时间必须从 t_start_wall 换算，
                # 不能直接拿单调值去格式化（否则写出来是 1970-01-02）
                rows.append(self._row(f, base + i + 1, rel, self.t_start_wall + rel))
            try:
                self._wr.writerows(rows)
                self._part_rows += len(take)
                self.rows += len(take)
                written += len(take)
            except Exception as exc:                                # noqa: BLE001
                self.error = "写记录文件失败：%s（磁盘满或文件被占用？）" % exc
                self._notify(self.error, "fault")
                self.stop()
                break
            self._measure()
        self.t_last_mono = t_end
        return written

    def _full(self):
        """当前卷是否已经写满（行数主判据、体积兜底）。"""
        if self._part_rows >= self.max_rows:
            return True
        return self.max_mb > 0 and (self._part_bytes / 1048576.0) >= self.max_mb

    def _room(self):
        """当前卷还能再写几行：行数上限与体积上限都要满足（至少 1 行保证能推进）。"""
        room = max(1, self.max_rows - self._part_rows)
        if self.max_mb > 0:
            left = self.max_mb * 1048576.0 - self._part_bytes
            per = (self._part_bytes / self._part_rows) if self._part_rows else 120.0
            room = max(1, min(room, int(left / max(1.0, per))))     # 超出上限时给 1 行
        return room

    def _measure(self):
        """按文件实际大小刷新体积统计（拿不到就退化估计）。"""
        try:
            self._part_bytes = self._fh.tell() if hasattr(self._fh, "tell") \
                else self._part_bytes
        except Exception:                                           # noqa: BLE001
            pass
        self.bytes = self._bytes_done + self._part_bytes

    def _rotate(self):
        """当前卷写满 → 关掉再开下一卷（不中断记录）。"""
        self._measure()
        self._close_part()
        self._bytes_done = self.bytes
        self._part += 1
        self._part_rows = 0
        self._part_bytes = 0
        if not self._open_part(self._part):
            self.stop()
            return
        self._notify("记录已分卷：第 %d 卷 %s（Excel 单表放不下 100 万行以上）"
                     % (self._part, os.path.basename(self.files[-1])), "warn")

    def _open_part(self, part):
        path = _part_path(self.path, part)
        if part > 1:
            # 分卷名也去重：同一秒里重新开始 + 上一段恰好换过卷，否则会截断上一段的第 N 卷
            path = _unique_path(path)
        try:
            # ★ 审计 2 #21：原来 1 MB 缓冲，进程被杀/断电最多丢 1 MB 尾部（约几千帧）。
            #   降到 64 KB 并把丢弃窗口压小；正常 stop 仍会 flush + close。
            fh = open(path, "w", encoding="utf-8-sig", newline="", buffering=64 * 1024)
        except Exception as exc:                                    # noqa: BLE001
            self.error = ("打不开记录文件：%s（%s）%s"
                          % (path, exc, dir_hint(exc)))
            self._notify(self.error, "fault")
            return False
        wr = csv.writer(fh, lineterminator="\r\n")
        # 表头写/flush 也必须挡住异常：磁盘满时它抛出来的 OSError 会一路穿过
        # feed()/start() 打进 Qt 槽（界面弹英文堆栈），而且句柄还会泄漏
        try:
            wr.writerow(CSV_COLUMNS)
            fh.flush()
        except Exception as exc:                                    # noqa: BLE001
            self.error = "写记录文件失败：%s（磁盘满或文件被占用？）" % exc
            self._notify(self.error, "fault")
            try:
                fh.close()
            except Exception:                                       # noqa: BLE001
                pass
            self._fh = self._wr = None
            return False
        self._fh, self._wr = fh, wr
        self._part = part
        self._part_bytes = fh.tell() if hasattr(fh, "tell") else 0
        self.parts = part
        self.files.append(path)
        return True

    def _row(self, f, idx, rel, t_wall):
        b = f.get("io_bits") or {}
        raw = f.get("raw")
        if raw is None:
            if not self._no_raw_noticed:
                self._no_raw_noticed = True
                self._notify("这一版通信层没带原始帧，CSV 的『原始帧』列先留空"
                             "（其余列不受影响）", "warn")

        def bit(name):
            v = b.get(name)
            return "" if v is None else int(v)

        d = b.get("dir")
        lim = b.get("limiter")
        return [
            idx,
            _stamp(t_wall),
            "%.6f" % rel,
            raw.hex() if raw else "",
            f.get("angle", ""),
            "%.3f" % (f.get("angle_deg") or 0.0),
            f.get("s", ""),
            f.get("c", ""),
            f.get("amp_sq", ""),
            f.get("pos_full", ""),
            f.get("cycle_cnt", ""),
            f.get("stat", ""),
            "、".join(f.get("flags") or []),
            "" if f.get("io_state") is None else f.get("io_state"),
            "" if f.get("io_flags") is None else f.get("io_flags"),
            bit("a"), bit("b"), bit("z"), bit("u"), bit("v"), bit("w"),
            "" if d is None else STATE_NAMES[0 if d else 1],
            "" if lim is None else ("限幅中" if lim else "正常"),
            f.get("layout", ""),
        ]

    # ------------------------------------------------------------------ 统计
    def stats(self, t_mono=None):
        """本次记录统计（需求 M6：时长/帧数/校验错帧数/丢帧估计）。"""
        end = float(t_mono if t_mono is not None else time.monotonic())
        secs = 0.0
        if self.t_start_mono is not None:
            secs = max(0.0, (self.t_last_mono if not self.active else end)
                       - self.t_start_mono)
        fps = (self.rows / secs) if secs > 0.001 else 0.0
        # 丢帧估计 = 链路吞掉的帧数 ÷（写下来的帧数 + 吞掉的）⇒ 一个百分比，好理解
        tot = self.rows + self.lost
        return {
            "active": self.active,
            "path": self.path,
            "files": list(self.files),
            "parts": self.parts,
            "rows": self.rows,
            "bytes": self.bytes,
            "seconds": secs,
            "fps": fps,
            "lost": self.lost,
            "lost_pct": (100.0 * self.lost / tot) if tot else 0.0,
            "error": self.error,
        }

    def _notify(self, text, level="info"):
        if self.notice is not None:
            try:
                self.notice(text, level)
            except Exception:                                       # noqa: BLE001
                pass


def _size_text(nbytes):
    if nbytes >= 1024 ** 3:
        return "%.2f GB" % (nbytes / float(1024 ** 3))
    if nbytes >= 1024 ** 2:
        return "%.1f MB" % (nbytes / float(1024 ** 2))
    if nbytes >= 1024:
        return "%.1f kB" % (nbytes / 1024.0)
    return "%d B" % nbytes


# 给界面用的公开别名（面板不该去碰下划线开头的内部函数）
size_text = _size_text


def stats_text(st):
    """给界面/日志用的一行中文摘要。"""
    if not st or not st.get("rows"):
        return "还没有记录"
    return ("%s 秒 / %s 帧 / %s（%.0f 帧每秒）/ %d 个文件 / 丢帧估计 %.2f%%"
            % ("%.1f" % st["seconds"], format(st["rows"], ","),
               _size_text(st["bytes"]), st["fps"], st["parts"], st["lost_pct"]))


# ==============================================================================
# 离线自检
# ==============================================================================
def _load_tools():
    """借用 tools/uart_scope.py 的组帧函数造测试帧（只读，不改那个文件）。

    打包成 exe 时 `tools/` 在 exe 里面（spec 的 hiddenimports）或 exe 旁边，
    `__file__` 指向的临时解包目录里没有 `tools/` —— 所以先看 `sys.executable`
    所在的目录（与 link.py 的 `_ensure_tools_on_path` 同一套判据）。
    """
    exe = (os.path.dirname(os.path.abspath(sys.executable))
           if (getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS")) else None)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for tp in ((os.path.join(exe, "tools") if exe else None),
               os.path.join(root, "tools")):
        if tp and os.path.isdir(tp) and tp not in sys.path:
            sys.path.insert(0, tp)
    import uart_scope as us                                        # noqa: PLC0415
    return us


def _fake_frames(us, n, start=0, angle_step=1234, pairs=4):
    """造 n 个「解码后」帧 dict（与 link.py 交给界面的结构一致）+ 对应原始帧。"""
    out = []
    ang = 0
    for i in range(n):
        ang = (start + i * angle_step) & 0xFFFF
        io_state = ((i >> 0) & 1) | (((i >> 1) & 1) << 1) | (((i >> 2) & 1) << 2) | \
                   (((i >> 3) & 1) << 3) | (((i >> 4) & 1) << 4) | (((i >> 5) & 1) << 5) | \
                   (1 << 6) | (0 << 7)
        io_flags = (i % 4)
        pos_full = (start + i) * 2
        stat = 1 if (i % 100 == 0) else 0
        raw = us.build_frame(ang, 1000 + i % 300, -2000 - i % 300, io_state,
                             io_flags, pos_full & 0xFFFFFFFF, stat)
        sv = 1000 + i % 300
        cv = -2000 - i % 300
        out.append((dict(
            angle=ang, angle_deg=ang * (360.0 / 65536.0), s=sv, c=cv,
            layout="v2", io_state=io_state, io_flags=io_flags,
            io_bits={n: (io_state >> k) & 1
                     for k, n in enumerate(["a", "b", "z", "u", "v", "w",
                                            "dir", "limiter"])},
            io_flag_bits={}, amp_sq=(sv * sv + cv * cv) & 0xFFFFFFFF,
            pos_full=pos_full & 0xFFFFFFFF, cycle_cnt=(pos_full >> 16) & 0xFFFF,
            stat=stat, flags=(["oflow"] if stat & 1 else []),
            raw=raw), raw, io_state, io_flags))
    return out


def selftest(out=None):
    """离线自检：造帧 → 落盘 → 读回逐列比对 + 分卷 + 统计 + 异常 + 性能。返回 0/1。"""
    f = out or sys.stdout
    us = _load_tools()
    # 自检的临时目录放在本文件旁边：系统临时目录在受限环境里可能不可写
    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "_rec_selftest_tmp")
    # 目录必须**真的**是空的：上一轮若中途失败（比如换卷失败那个用例把句柄留着），
    # Windows 上 rmtree 删不掉被占用的文件，残下的 e.csv 会被这一轮读到，
    # 于是 "[10] 合并批单调" 去读上一轮的 1 行文件、报出"跨度 0.000 s"的假失败（真踩过）。
    try:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
    except Exception:                                           # noqa: BLE001
        for i in range(2, 100):                                 # 删不干净就换个新目录
            cand = "%s_%d" % (tmp, i)
            if not os.path.isdir(cand):
                tmp = cand
                break
    try:
        os.makedirs(tmp, exist_ok=True)
    except Exception as exc:                                    # noqa: BLE001
        print("建不了自检临时目录：%s（%s）" % (tmp, exc), file=f)
        return 1
    ok = True

    # 1) 基本落盘：表头/行数/中文列名/BOM
    path = os.path.join(tmp, "a.csv")
    rec = Recorder(path, max_rows=100000)
    good = rec.start() and rec.active
    if not good:
        print("    开始记录就失败了：%s" % rec.error, file=f)
    data = _fake_frames(us, 250)
    rec.feed([d[0] for d in data], n_bad=3)
    st = rec.stop()
    rows = _read_csv(path)
    good &= (len(rows) == 251 and rows[0] == CSV_COLUMNS and st["rows"] == 250)
    with open(path, "rb") as fh:
        head = fh.read(3)
    good &= (head == b"\xef\xbb\xbf")                       # Excel 需要的 BOM
    ok &= good
    print("[1] 落盘与表头      %d 行（含表头）、列 %d、BOM=%s  %s"
          % (len(rows), len(rows[0]), head == b"\xef\xbb\xbf",
             "PASS" if good else "FAIL"), file=f)

    # 2) 逐列比对：原始帧 / 角度 / s / c / 电平 / 方向 / 状态位
    bad = 0
    for i, (d, raw, io_state, io_flags) in enumerate(data[:250]):
        r = rows[i + 1]
        exp = [str(i + 1), None, None, raw.hex(), str(d["angle"]),
               "%.3f" % d["angle_deg"], str(d["s"]), str(d["c"]),
               str(d["amp_sq"]), str(d["pos_full"]), str(d["cycle_cnt"]),
               str(d["stat"]), "、".join(d["flags"]), str(io_state),
               str(io_flags)] + [str((io_state >> k) & 1) for k in range(6)] + \
              ["正转", "正常", "v2"]
        for k, e in enumerate(exp):
            if e is None:
                continue
            if r[k] != e:
                if bad < 3:
                    print("    第 %d 行第 %s 列：期望 %r 实得 %r"
                          % (i + 2, CSV_COLUMNS[k], e, r[k]), file=f)
                bad += 1
    good = (bad == 0) and _raw_roundtrip(us, rows[1][3])
    ok &= good
    print("[2] 逐列比对      %d 处不符；原始帧可独立解回=%s  %s"
          % (bad, _raw_roundtrip(us, rows[1][3]), "PASS" if good else "FAIL"),
          file=f)

    # 3) 分卷：每卷 100 行，写 250 帧 ⇒ 3 个文件、序号跨卷连续
    path3 = os.path.join(tmp, "b.csv")
    rec = Recorder(path3, max_rows=100)
    rec.start()
    for i in range(0, 250, 50):
        rec.feed([d[0] for d in _fake_frames(us, 50, start=i)][:50])
    st = rec.stop()
    parts = [p for p in st["files"]]
    seq = []
    for p in parts:
        rr = _read_csv(p)
        seq += [int(x[0]) for x in rr[1:]]
    good = (len(parts) == 3 and all(len(_read_csv(p)) <= 101 for p in parts)
            and seq == list(range(1, 251)))
    ok &= good
    print("[3] 自动分卷      %d 个文件（%s）、序号连续到 %s、每卷 ≤100 行  %s"
          % (len(parts), "、".join(os.path.basename(p) for p in parts),
             seq[-1] if seq else "-", "PASS" if good else "FAIL"), file=f)

    # 4) 统计：时长/帧数/丢帧估计
    st = rec.stats()
    good = (st["rows"] == 250 and st["lost"] == 0 and st["seconds"] > 0
            and st["fps"] > 0)
    # 丢帧估计 = lost/(rows+lost)
    rec2 = Recorder(os.path.join(tmp, "c.csv"))
    rec2.start()
    rec2.feed([d[0] for d in _fake_frames(us, 900)], n_bad=100)
    # 链路丢批的帧（队列满）也要算进"丢帧估计"：再补 50 帧的丢失、并且一帧都不写
    rec2.feed([], n_drop=50)
    st2 = rec2.stop()
    good &= (st2["rows"] == 900 and st2["lost"] == 150
             and abs(st2["lost_pct"] - 100.0 * 150 / 1050) < 0.01)
    ok &= good
    print("[4] 记录统计      %s（本次喂了 900 帧 + 100 个坏帧 + 50 帧队列丢弃）  %s"
          % (stats_text(st2), "PASS" if good else "FAIL"), file=f)

    # 5) 时间戳：同一批内严格递增 0.1 ms、跨批单调
    path5 = os.path.join(tmp, "d.csv")
    rec = Recorder(path5)
    rec.start(t_mono=1000.0, t_wall=1700000000.0)
    rec.feed([d[0] for d in _fake_frames(us, 10)], t_mono=1000.05)
    rec.feed([d[0] for d in _fake_frames(us, 10)], t_mono=1000.10)
    rec.stop(t_mono=1000.15)
    rr = _read_csv(path5)[1:]
    rel = [float(x[2]) for x in rr]
    wall = [x[1] for x in rr]
    diffs = [round(rel[i + 1] - rel[i], 6) for i in range(len(rel) - 1)]
    # 两批各 10 帧：批内末帧 = 批到达时刻 ⇒ 第 1 批 rel[9]=0.0500、第 2 批 rel[19]=0.1000
    # 墙上时间列必须落在 2020 年以后（单调时钟直接格式化会写出 1970-01-02，曾经真踩过）
    good = (abs(rel[0] - 0.0491) < 1e-6 and abs(rel[9] - 0.0500) < 1e-6
            and abs(rel[10] - 0.0991) < 1e-6 and abs(rel[19] - 0.1000) < 1e-6
            and all(abs(d - 0.0001) < 1e-9 for d in diffs if d < 0.01)
            and wall[0].startswith("2023-11-15 06:13:20")
            and wall[-1].startswith("2023-11-15 06:13:20"))
    ok &= good
    print("[5] 时间戳回推    批内步长 %.4f ms（严格 0.1 ms）；批边界 %.3f ms（真实到达间隔）；"
          "首帧 %.4f s、末帧 %.4f s；墙上时间 %s  %s"
          % (diffs[0] * 1000, diffs[9] * 1000, rel[0], rel[-1], wall[0],
             "PASS" if good else "FAIL"), file=f)

    # 6) 目录写不进去 → 不抛异常。★ 阶段 5 D 批起 `start()` 会**先探写、再把位置自动换到
    #    能写的地方**（`:625-647`）⇒ 有兜底时"不抛异常 + did_fallback + active + 换了位置"
    #    才是正确契约；旧断言只认 "error 非空"，自 D 批起恒假失败（这两个模块自检一直不在
    #    交付门槛里跑，所以没人发现）。
    #    兜底目录限定在自检临时目录内：真跑 `fallback_dirs()` 会往"我的文档"等用户目录里
    #    留一个 x.csv（自检不该有这种副作用）。
    bad_path = os.path.join(tmp, "no_such_dir\0zz", "x.csv") if os.name != "nt" \
        else "Z:\\no_such_drive_qa\\x.csv"
    _fb = fallback_dirs
    rec = Recorder(bad_path)
    started, thrown = False, None
    try:
        globals()["fallback_dirs"] = lambda: [tmp]
        started = rec.start()
    except Exception as exc:                                    # noqa: BLE001
        thrown = exc
        print("    竟然抛异常了：%s" % exc, file=f)
    finally:
        globals()["fallback_dirs"] = _fb
    if thrown is not None:
        good = False
    elif started:
        good = (rec.active is True and bool(rec.did_fallback)
                and os.path.dirname(rec.path) == tmp)
        rec.stop()
    else:
        good = (rec.active is False) and bool(rec.error)
    ok &= good
    print("[6] 不可写不崩    started=%s did_fallback=%s 改存到 %s error=%s  %s"
          % (started, getattr(rec, "did_fallback", "-"), os.path.dirname(rec.path),
             (rec.error or "")[:30], "PASS" if good else "FAIL"), file=f)

    # 6b) 兜底也用尽 ⇒ 才进 error 分支（不抛异常、不进记录态）
    rec2 = Recorder(bad_path)
    s2, thrown2 = False, None
    try:
        globals()["fallback_dirs"] = lambda: []
        s2 = rec2.start()
    except Exception as exc:                                    # noqa: BLE001
        thrown2 = exc
    finally:
        globals()["fallback_dirs"] = _fb
    good2 = (thrown2 is None) and (s2 is False) and (rec2.active is False) \
        and bool(rec2.error)
    ok &= good2
    print("[6b] 兜底用尽     started=%s active=%s error=%s  %s"
          % (s2, rec2.active, (rec2.error or "")[:30], "PASS" if good2 else "FAIL"), file=f)

    # 7) 停止后 feed 不再写（不会偷偷继续长）
    rec = Recorder(os.path.join(tmp, "e.csv"))
    rec.start()
    rec.feed([d[0] for d in _fake_frames(us, 10)])
    rec.stop()
    n_before = rec.rows
    rec.feed([d[0] for d in _fake_frames(us, 10)])
    good = (rec.rows == n_before == 10)
    ok &= good
    print("[7] 停止后不再写    行数 %d（喂进去 20 帧）  %s"
          % (rec.rows, "PASS" if good else "FAIL"), file=f)

    # 8) 性能基准：**同机自校准** —— 先量"这台机器纯做行格式化"的上限，再要求记录器
    #    （格式化 + 真落盘）不慢于它的 35%，并保留"实机 10 kHz 只要 1 万行/秒"的 2 倍硬底线。
    #    为什么不用固定的绝对门槛（历史上是 15 万行/秒）：记录器这条路是纯 CPU 的字符串
    #    格式化，机器一忙/一慢绝对门槛就报假警（实测同一份未改动的代码在本机 3.7–5.6 万行/秒
    #    波动，而纯格式化上限 5.4–9.3 万行/秒）；改成看**比值**后，机器快慢不影响判定，而
    #    "每行都 flush/fsync""每行多拼一个大字符串"这类真回归会把比值打到 0.1 以下，照样抓住。
    path8 = os.path.join(tmp, "f.csv")
    rec = Recorder(path8, max_rows=1000000, max_mb=10000.0)
    rec.start()
    batch = [d[0] for d in _fake_frames(us, 1000)]
    n_batch = 100
    t0 = time.perf_counter()
    for _ in range(n_batch):
        rec.feed(batch)
    dt = time.perf_counter() - t0
    rec.stop()
    rate = (1000 * n_batch) / dt
    t0 = time.perf_counter()
    for i, fr in enumerate(batch):                   # 同机上限：只格式化，不落盘
        rec._row(fr, 1, 0.001 * i, 1.0)               # noqa: SLF001
    fmt_rate = len(batch) / (time.perf_counter() - t0)
    ratio = rate / fmt_rate
    floor = 20000.0                                  # 实机只要 1 万行/秒 ⇒ 留 2 倍硬底线
    good = (ratio >= 0.35) and (rate > floor)
    ok &= good
    print("[8] 写入性能      %.0f 行/秒（%.0f MB/s；同机格式化上限 %.0f 行/秒 ⇒ 比值 %.2f，"
          "门槛 ≥0.35 且绝对 ≥%.0f）  %s"
          % (rate, (rec.bytes / 1048576.0) / dt, fmt_rate, ratio, floor,
             "PASS" if good else "FAIL"),
          file=f)

    # 9) 中文/逗号/引号字段能被 csv 正确读回（状态位列里有顿号，方向列有中文）
    rr = _read_csv(path8)
    good = (rr[0] == CSV_COLUMNS and len(rr[0]) == len(CSV_COLUMNS)
            and len(rr) == 100001)
    ok &= good
    print("[9] 读回一致性    %d 行 × %d 列  %s"
          % (len(rr), len(rr[0]), "PASS" if good else "FAIL"), file=f)

    # 10) 合并批的时间戳必须单调：界面每 100 ms 才交一次，一次 feed 里常含好几个
    #     50 ms 批；若一律按 "末帧 - (n-1)×0.1ms" 回推，本批头会落到上一批之前（时间倒流）
    path10 = os.path.join(tmp, "j.csv")     # 别和上面各用例重名：撞名会被 _unique_path 改名，
    rec = Recorder(path10)                  # 而"读回构造出来的路径"就读到了上一个用例的文件
    rec.start(t_mono=2000.0, t_wall=1700000000.0)
    one = [d[0] for d in _fake_frames(us, 1)]
    rec.feed(one * 500, t_mono=2000.10)          # 第一批：正常 50 ms 的量
    rec.feed(one * 500, t_mono=2000.12)          # 第二批：链路抖了一下才 2 ms 后到
    rec.feed(one * 300, t_mono=2000.50)          # 第三批：中间卡了 380 ms（应留台阶）
    rec.stop(t_mono=2000.60)
    rel10 = [float(x[2]) for x in _read_csv(rec.files[0])[1:]]
    back = [i for i in range(len(rel10) - 1) if rel10[i + 1] < rel10[i] - 1e-9]
    jump = max(rel10) - min(rel10)
    good = (not back) and abs(rel10[0] - 0.0501) < 2e-4 and rel10[-1] > 0.49
    ok &= good
    print("[10] 合并批单调    倒流 %d 处、跨度 %.3f s（含一次 380 ms 链路卡顿的台阶）；"
          "行数 %d、首 %s、末 %s  %s"
          % (len(back), jump, len(rel10), rel10[:1], rel10[-1:],
             "PASS" if good else "FAIL"), file=f)

    # 11) 同名文件必须自动改名：默认文件名只到秒，"停止→开始"同一秒会撞名，
    #     而打开方式是 "w" ⇒ 上一段记录被静默截断（自查真踩过：100 行变 4 行）
    path11 = os.path.join(tmp, "k.csv")     # 同上：独立文件名，避免被 _unique_path 改名
    rec = Recorder(path11)
    one = [d[0] for d in _fake_frames(us, 1)]
    rec.start(t_mono=3000.0, t_wall=1700000000.0)
    rec.feed(one * 100, t_mono=3000.05)
    st_a = rec.stop(t_mono=3000.06)
    rec2 = Recorder(path11)                      # 同一路径、同一秒，立刻再开
    rec2.start(t_mono=3000.10, t_wall=1700000000.0)
    rec2.feed(one * 20, t_mono=3000.15)
    st_b = rec2.stop(t_mono=3000.16)
    rows_a = len(_read_csv(st_a["files"][0])) - 1
    good = (st_b["files"][0] != st_a["files"][0] and rows_a == 100
            and len(_read_csv(st_b["files"][0])) - 1 == 20)
    ok &= good
    print("[11] 同名不覆盖    第一段 %d 行（应 100）、第二段存到 %s  %s"
          % (rows_a, os.path.basename(st_b["files"][0]), "PASS" if good else "FAIL"), file=f)

    # 12) 写盘失败（磁盘满/权限）必须自己收场：不抛异常、active=False、有中文 error、句柄关掉。
    #     真造磁盘满很难，直接换一个"写就报 ENOSPC"的假 writer（审计报告就是用这招复现的）。
    class _BoomWriter(object):
        def writerows(self, rows):
            raise OSError(28, "No space left on device")

        def writerow(self, row):
            raise OSError(28, "No space left on device")

    path12 = os.path.join(tmp, "g.csv")
    rec = Recorder(path12)
    rec.start(t_mono=4000.0, t_wall=1700000000.0)
    rec.feed(one * 2, t_mono=4000.05)
    before = rec.rows
    rec._wr = _BoomWriter()
    escaped = ""
    try:
        rec.feed(one * 2, t_mono=4000.10)
    except Exception as exc:                                # noqa: BLE001
        escaped = "%s: %s" % (type(exc).__name__, exc)
    good = ((not escaped) and (not rec.active) and bool(rec.error)
            and rec._fh is None and rec.rows == before)
    ok &= good
    print("[12] 写盘失败自收场 异常=%s、active=%s、rows=%d（应 %d）、error=%s、句柄=%s  %s"
          % (escaped or "无", rec.active, rec.rows, before, rec.error or "无", rec._fh,
             "PASS" if good else "FAIL"), file=f)

    # 13) 上限钳位与外部时钟回拨：max_rows<=0 不许"每帧一卷"、max_mb<=0 视为不限、
    #     外部 t_mono 比上一批还早时相对时刻不许为负或倒流
    rec = Recorder(os.path.join(tmp, "h.csv"), max_rows=0, max_mb=-1.0)
    clamped = (rec.max_rows == 1 and rec.max_mb == 0.0)
    rec.start(t_mono=5000.0, t_wall=1700000000.0)
    rec.feed(one * 3, t_mono=5000.05)
    rec.feed(one * 3, t_mono=4999.00)       # 时钟回拨：钳位后 step=0，不许写出负值
    rec.stop(t_mono=5001.0)
    rel13 = []
    for p in rec.files:                     # max_rows=1 ⇒ 每帧一卷，按卷序拼起来查
        rel13 += [float(x[2]) for x in _read_csv(p)[1:]]
    back = [i for i in range(len(rel13) - 1) if rel13[i + 1] < rel13[i] - 1e-9]
    good = clamped and (not back) and min(rel13) >= 0.0
    ok &= good
    print("[13] 上限/时钟钳位 max_rows=%d、max_mb=%.1f、倒流 %d 处、最小相对时刻 %.4f s  %s"
          % (rec.max_rows, rec.max_mb, len(back), min(rel13), "PASS" if good else "FAIL"), file=f)

    print("自检%s" % ("通过 (PASS)" if ok else "失败 (FAIL)"), file=f)
    shutil.rmtree(tmp, ignore_errors=True)
    return 0 if ok else 1


def _read_csv(path, limit=None):
    rows = []
    with io.open(path, "r", encoding="utf-8-sig", newline="") as fh:
        for r in csv.reader(fh):
            rows.append(r)
            if limit and len(rows) >= limit:
                break
    return rows


def _raw_roundtrip(us, hexstr):
    """把 CSV 里的原始帧 hex 独立解回一帧，证明"不看上位机也能解"。"""
    try:
        raw = bytes.fromhex(hexstr)
        frames, _st = us.parse_stream(raw)
        return bool(frames) and us.frame_checksum(raw[2:17]) == raw[17]
    except Exception:                                               # noqa: BLE001
        return False


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if "--selftest" in argv:
        return selftest()
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
