r"""打包版"现场诊断"小工具（S6 附）：回答"双击了，什么都没发生"。

为什么单独做一个小 exe
---------------------
单文件包（`host\dist\host_app.exe`）与目录版（`host\dist_onedir\…`）的
**唯一区别**就是"启动时要把 200 MB 解到 `%TEMP%\_MEIxxxxxx`"。所以出问题的
层次只有三种：① 解包本身被挡（权限/杀软/磁盘/TEMP 环境）；② 解出来的东西
被杀软扣下或加载失败；③ 起得太慢，人以为"打不开"。

这个小工具**只用标准库**（不 import Qt/numpy/matplotlib），构建只要几秒、
产物几 MB —— 于是：
* 它自己就是一个"最小单文件包"：双击它能出黑窗 = 单文件解包这条路在你机器上是通的；
* 它会把现场信息（冻结路径、各目录可写性、磁盘、TEMP、Mark of the Web、
  邻居 exe 的大小/时间）打印出来并写一份 `diag_report.txt`；
* 它会**替你启动一次真正的** `host_app.exe --diag` 并等它退出，把退出码
  和那份 `host_app_run.log` 的尾巴一并打出来 —— 于是"到底哪一步断的"
  可以一次问清，不必来回猜。

用法
----
    :: 源码模式（开发机自查）
    python host\diag.py
    python host\diag.py --no-run         不启动邻居 exe，只做本地检查
    python host\diag.py --app X.exe      指定要试跑的 exe

    :: 打包版（给用户）
    host\dist\host_app_diag.exe       双击即可；结束前按回车关窗
"""

import argparse
import ctypes
import ctypes.wintypes as wt
import glob
import os
import platform
import shutil
import subprocess
import sys
import time

# 邻居 exe 的默认名字（打包产物就在同一个 dist 目录里）
APP_NAME = "host_app.exe"
APP_MB = 208.3                    # 单文件包该有的大小（偏小 = 没复制完整）
LOG_NAME = "host_app_run.log"
REPORT_NAME = "diag_report.txt"


def fix_streams():
    """保证"打印中文绝不因编码崩掉"。

    ★ 实测踩到的坑（2026-10-13）：日志文件是别的工具以 **UTF-8 带 BOM** 写出来的，
      用 `encoding="utf-8"` 读进来会把 `\\ufeff` 留在第一行；在 GBK 控制台/管道里
      `print()` 它直接 `UnicodeEncodeError: 'gbk' codec can't encode character
      '\\ufeff'` ⇒ 整个诊断工具崩掉、连 `diag_report.txt` 都写不出来。修法两处：
      ① 本函数把标准输出重设为 UTF-8 + `errors="replace"`（真控制台上 Python 用
         `_WindowsConsoleIO`，本来就是 UTF-8，中文照样正常；被重定向到管道时也能
         正确输出 UTF-8 而不是本地码页）；
      ② 读日志用 `utf-8-sig`（见 `read_tail`）。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:                                        # noqa: BLE001
            pass


def read_tail(path, n=40):
    """读文本文件尾部 n 行。`utf-8-sig` 会吃掉 BOM；失败抛异常给调用方判种类。"""
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        return f.readlines()[-n:]


def home_dir():
    """exe 所在目录（冻结）/ 本文件目录（源码）。与 host/ui_prefs.py::_home_dir 同规则。"""
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def write_probe(d):
    """在目录 d 里真写一个文件再删掉 —— 只问"能不能写"，不猜。"""
    if not d:
        return "没有这个环境变量"
    # ★ 2026-10-17 全面自查修：①名字带 pid，避免把别人的同名文件清零（旧名是固定的
    #   host_app_write_test.tmp，`open(p,"w")` 会先截断）②失败路径也要清理，别留半截文件。
    p = os.path.join(d, "host_app_write_test_%d.tmp" % os.getpid())
    try:
        with open(p, "w", encoding="utf-8") as f:
            f.write("ok")
        return "可以写"
    except Exception as exc:                                     # noqa: BLE001
        return "失败：%s" % exc
    finally:
        try:
            os.remove(p)
        except OSError:
            pass


def dir_probe(d):
    r"""在目录 d 里**建一个子目录**再删掉。

    单文件包卡的第一道关就是这个（引导器要在 `%TEMP%` 下 `CreateDirectoryW` 出
    `_MEIxxxxxx`）。★ 失败原话就是软件里那句 `Could not create temporary directory!`。
    """
    if not d:
        return "没有这个环境变量"
    p = os.path.join(d, "_MEI_建目录测试")
    try:
        os.mkdir(p)
        os.rmdir(p)
        return "可以建子目录"
    except Exception as exc:                                     # noqa: BLE001
        return "失败：%s" % exc


def zone_id(path):
    """Mark of the Web（从网上下载/网盘同步来的文件会带）——SmartScreen 会因此拦人。"""
    try:
        with open(path + ":Zone.Identifier", "r", encoding="utf-8", errors="replace") as f:
            return "有（%s）" % f.read().replace("\n", " ").strip()
    except FileNotFoundError:
        return "无"
    except Exception as exc:                                     # noqa: BLE001
        return "读不到（%s）" % exc


def exe_ok(path, expect_mb=None):
    """能不能读、开头是不是 MZ、大小对不对：判断"文件被扣/被锁/被截断"。

    `expect_mb` 给定期望体积（MB）时会顺带报一句"偏小 ⇒ 多半是复制/下载不全"，
    这是"双击没反应"里最容易被忽略的一种（截断的 exe 连引导器都进不去）。
    """
    try:
        with open(path, "rb") as f:
            head = f.read(2)
        size = os.path.getsize(path) / 2 ** 20
        out = "可读，头 2 字节 = %r，大小 %.1f MB" % (head, size)
        if head != b"MZ":
            out += "   ★ 不是可执行文件（被截断/被改动）"
        elif expect_mb and size < expect_mb * 0.9:
            out += "   ★ 比正常小（该有约 %.1f MB）—— 多半没复制完整" % expect_mb
        return out
    except Exception as exc:                                     # noqa: BLE001
        return "读不了：%s" % exc


def mei_report(limit=6):
    r"""扫 `%TEMP%\_MEI*`：单文件包每次启动都会在那儿解包。

    ★ 判读关键：**目录在、里面 0 个文件** = 解包被挡住的签名（沙箱受限令牌就是这个
    现场，见 `docs/DEV_STATUS.md` §1.77；杀软/权限拒绝也是同一副样子）。
    目录在、文件数正常 = 解包没问题（残留目录是退出没清干净的，无害）。
    """
    tmp = os.environ.get("TEMP") or os.environ.get("TMP") or ""
    dirs = sorted(glob.glob(os.path.join(tmp, "_MEI*")))
    if not dirs:
        return ["%s\\_MEI*：一个都没有（要么从没启动过，要么解包目录已被清理）" % tmp]
    out = []
    for d in dirs[-limit:]:
        try:
            n = 0
            size = 0
            for root, _dirs, files in os.walk(d):
                for fn in files:
                    n += 1
                    try:
                        size += os.path.getsize(os.path.join(root, fn))
                    except OSError:
                        pass
            flag = "   ★ 空目录 = 这里被挡住过（权限/杀软）" if n == 0 else ""
            out.append("%s：%d 个文件 / %.1f MB%s" % (os.path.basename(d), n,
                                                   size / 2 ** 20, flag))
        except Exception as exc:                                 # noqa: BLE001
            out.append("%s：读不到（%s）" % (os.path.basename(d), exc))
    if len(dirs) > limit:
        out.append("（共 %d 个 `_MEI*`，只列最新 %d 个）" % (len(dirs), limit))
    return out


def _run_quiet(cmd, timeout=20):
    """跑一个系统命令并取回文本（`CREATE_NO_WINDOW`，不弹黑窗）。"""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return (p.stdout or b"").decode("utf-8", "replace")
    except Exception as exc:                                     # noqa: BLE001
        return "（%s 失败：%s）" % (cmd[0], exc)


def restricted_sid_count():
    """令牌里"受限 SID"的个数：>0 = write-restricted（沙箱）令牌。失败给 None。

    ★ 只用 `GetTokenInformation` 读那个 DWORD 计数，**不做 SID 指针运算**
      （早先一版按 `TOKEN_GROUPS` 结构手撕 SID 数组，prototype 没写全 ⇒ 进程
      直接 0xC0000005 崩掉。诊断工具自己崩是最不能接受的失败方式。）
    """
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    adv = ctypes.WinDLL("advapi32", use_last_error=True)
    k32.GetCurrentProcess.restype = wt.HANDLE
    adv.OpenProcessToken.argtypes = [wt.HANDLE, wt.DWORD, ctypes.POINTER(wt.HANDLE)]
    adv.OpenProcessToken.restype = wt.BOOL
    adv.GetTokenInformation.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                        wt.DWORD, ctypes.POINTER(wt.DWORD)]
    adv.GetTokenInformation.restype = wt.BOOL
    k32.CloseHandle.argtypes = [wt.HANDLE]
    k32.CloseHandle.restype = wt.BOOL
    tok = wt.HANDLE()
    if not adv.OpenProcessToken(k32.GetCurrentProcess(), 0x0008, ctypes.byref(tok)):
        return None
    try:
        buf = ctypes.create_string_buffer(1 << 16)
        need = wt.DWORD()
        if not adv.GetTokenInformation(tok, 11, ctypes.cast(buf, ctypes.c_void_p),
                                       len(buf), ctypes.byref(need)):
            return None
        return ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint32)).contents.value
    finally:
        k32.CloseHandle(tok)


def token_info():
    r"""本进程令牌长什么样 —— 回答"这程序到底是谁启动的"。

    ★ 为什么必须查这个（2026-10-13 现场）：用户报告里 `%TEMP%` 写文件
      `[Errno 13] Permission denied`，可那个目录的 ACL 明明给了该用户 FullControl
      （我这边核对过 `Get-Acl`，三条 ACE：SYSTEM / Administrators / 用户 FullControl）。
      唯一能让"有 FullControl 却写不进去"成立的情况是**令牌被限制**
      （write-restricted / 带能力 SID 的沙箱令牌）—— DSH 之类的沙箱启动子进程
      就是这种身份：只许写工作区，连 `%TEMP%` 都不许。
      单文件包要先往 `%TEMP%` 解包 ⇒ 这种身份下必然报
      `Could not create temporary directory!`；目录版不需要 `%TEMP%` ⇒ 能开。
    """
    user = _run_quiet(["whoami", "/user"]).split()
    sid = next((w for w in user if w.startswith("S-1-")), "?")
    groups = _run_quiet(["whoami", "/groups"])
    caps = sorted({ln.split()[-1] for ln in groups.splitlines() if "S-1-4-" in ln})
    integ = sorted({ln.split()[-1] for ln in groups.splitlines() if "S-1-16-" in ln})
    n = restricted_sid_count()
    out = ["账户：%s   用户 SID：%s" % (os.environ.get("USERNAME") or "?", sid),
           "令牌完整性：%s" % (", ".join(integ) if integ else "?"),
           "受限 SID 数：%s%s" % ("读不到" if n is None else n,
                               "（★ >0 = 令牌被限制：只能访问被显式允许的路径）"
                               if n else ""),
           "能力 SID（S-1-4-…，沙箱标志）：%s" % (", ".join(caps) if caps else "无")]
    if caps or n:
        out.append("判断：★ **受限令牌** —— 本程序不是你自己双击起来的，"
                   "是被沙箱（DSH）启动的；这种身份连 %TEMP% 都写不了 ⇒ "
                   "单文件包必报 Could not create temporary directory!")
    else:
        out.append("判断：普通用户令牌（未受限）—— 双击/从开始菜单开 cmd 启动就是这样")
    return out


class _PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD),
                ("th32ProcessID", wt.DWORD), ("th32DefaultHeapID", ctypes.c_void_p),
                ("th32ModuleID", wt.DWORD), ("cntThreads", wt.DWORD),
                ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", ctypes.c_long),
                ("dwFlags", wt.DWORD), ("szExeFile", wt.WCHAR * 260)]


def parent_chain(pid=None, depth=5):
    r"""往上数 5 层"谁启动了我"（Toolhelp32 快照，纯 Win32、不需要管理员）。"""
    pid = pid or os.getpid()
    k32 = ctypes.windll.kernel32
    TH32CS_SNAPPROCESS = 0x00000002
    # ★ 2026-10-17 全面自查修：不声明 restype 时 ctypes 把句柄当 c_int 截断，
    #   `snap == HANDLE(-1).value`（2^64−1）永远不成立 ⇒ 失败检测不到，还会把
    #   INVALID_HANDLE_VALUE 当有效句柄传给 Process32FirstW（退化成空进程表）。
    k32.CreateToolhelp32Snapshot.restype = wt.HANDLE
    k32.CreateToolhelp32Snapshot.argtypes = [wt.DWORD, wt.DWORD]
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    # ★ ctypes.wintypes **没有** INVALID_HANDLE_VALUE（写 wt.INVALID_HANDLE_VALUE 会 AttributeError），
    #   而 c_void_p 返回值按有符号/无符号两种表示都出现过 ⇒ 两种都判。
    if not snap or snap in (-1, ctypes.c_void_p(-1).value):
        return ["读不到进程表（%s）" % ctypes.WinError()]
    k32.Process32FirstW.argtypes = [wt.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
    k32.Process32FirstW.restype = wt.BOOL
    k32.Process32NextW.argtypes = [wt.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
    k32.Process32NextW.restype = wt.BOOL
    table = {}
    try:
        e = _PROCESSENTRY32W()
        e.dwSize = ctypes.sizeof(e)
        ok = k32.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            table[e.th32ProcessID] = (e.szExeFile, e.th32ParentProcessID)
            ok = k32.Process32NextW(snap, ctypes.byref(e))
    finally:
        k32.CloseHandle(snap)
    chain = []
    seen = set()
    for _ in range(depth):
        if not pid or pid in seen or pid not in table:
            break
        seen.add(pid)
        name, ppid = table[pid]
        chain.append("%s(%d)" % (name, pid))
        pid = ppid
    return [" ← ".join(chain) if chain else "读不到"]


def collect(app_path, local_only):
    base = home_dir()
    frozen = getattr(sys, "frozen", False)
    lines = ["===== host_app 现场诊断 %s =====" % time.strftime("%Y-%m-%d %H:%M:%S"),
             "诊断工具：%s" % sys.executable,
             "冻结：%s   解包目录：%s" % (frozen, getattr(sys, "_MEIPASS", "-")),
             "工作目录：%s" % os.getcwd(),
             "Python：%s" % sys.version.replace("\n", " "),
             "系统：%s" % platform.platform(),
             "TEMP：%s" % (os.environ.get("TEMP") or "-"),
             "TMP：%s" % (os.environ.get("TMP") or "-"),
             "LOCALAPPDATA：%s" % (os.environ.get("LOCALAPPDATA") or "-"),
             "", "--- 运行身份（谁启动的？能不能写 %TEMP%？）---"]
    try:
        lines += token_info()
        lines.append("启动链：%s" % parent_chain()[0])
    except Exception as exc:                                     # noqa: BLE001
        lines.append("查令牌失败：%s: %s" % (type(exc).__name__, exc))
    lines += ["", "--- 目录可写性（解包/参数文件/记录都要写盘）---"]
    for name, d in (("exe 目录", base), ("TEMP", os.environ.get("TEMP") or ""),
                    ("TMP", os.environ.get("TMP") or ""), ("工作目录", os.getcwd())):
        lines.append("%-8s %-16s %s" % (name, d or "-", write_probe(d)))
    for name, d in (("TEMP", os.environ.get("TEMP") or ""),
                    ("exe 目录", base)):
        lines.append("%-8s %-16s %s" % (name + " 建目录", d or "-", dir_probe(d)))
    for name, d in (("exe 目录", base), ("TEMP", os.environ.get("TEMP") or "")):
        try:
            u = shutil.disk_usage(d or base)
            lines.append("%s 磁盘：可用 %.1f GB / 共 %.1f GB" % (name, u.free / 2 ** 30,
                                                              u.total / 2 ** 30))
        except Exception as exc:                                 # noqa: BLE001
            lines.append("%s 磁盘：读不到（%s）" % (name, exc))

    lines += ["", "--- exe 目录里的程序 ---"]
    found = []
    for pat in sorted(glob.glob(os.path.join(base, "*.exe"))):
        found.append(pat)
        is_app = os.path.basename(pat).lower() == APP_NAME.lower()
        lines.append("%s\n    %s" % (os.path.basename(pat),
                                     exe_ok(pat, APP_MB if is_app else None)))
        if is_app:
            lines.append("    Mark of the Web：%s" % zone_id(pat))
    if not found:
        lines.append("（这个目录里没有 exe）")

    lines += ["", "--- %TEMP% 里的解包目录（单文件包每次启动都在这儿解包）---"]
    lines += ["  " + x for x in mei_report()]

    app = app_path or os.path.join(base, APP_NAME)
    if local_only:
        lines += ["", "（--no-run：按要求没有启动 %s）" % app]
        return lines, app, None
    if not os.path.exists(app):
        lines += ["", "★ 找不到 %s —— 请把本诊断程序和它放在同一个目录里再跑一次。" % app]
        return lines, app, None

    # 让真正的程序自己跑一遍 `--diag`：这一步能回答"Python 到底起来了没有"。
    lines += ["", "--- 试跑 %s --diag（最多等 180 s）---" % os.path.basename(app)]
    t0 = time.time()
    try:
        p = subprocess.run([app, "--diag"], timeout=180,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        rc = p.returncode
        out = (p.stdout or b"").decode("utf-8", "replace").strip()
        dt = time.time() - t0
        lines.append("退出码 %s，耗时 %.1f s" % (rc, dt))
        if rc == 0:
            lines.append("=> 程序**能**走到 Python 里并正常退出（解包与依赖加载都通了）")
        else:
            lines.append("=> 程序在 Python 起来之前就退了（或内部报错）—— "
                         "看下面它自己的日志")
        if out:
            lines.append("它打印的内容：\n%s" % out)
    except subprocess.TimeoutExpired:
        lines.append("★ 等了 180 s 还没退出：要么解包慢到不合理，要么被安全软件挡住，"
                     "要么弹了对话框在等人点确定（去任务栏看看有没有窗口）。")
    except Exception as exc:                                     # noqa: BLE001
        lines.append("★ 启动失败：%s: %s" % (type(exc).__name__, exc))

    # 日志落在**被查程序**旁边（`app.py::LOG_PATH`）；也兼容"诊断助手被单独放在别处"
    cands = [os.path.join(os.path.dirname(os.path.abspath(app)), LOG_NAME),
             os.path.join(base, LOG_NAME)]
    logp = cands[0]
    lines += ["", "--- %s （尾部 40 行）---" % LOG_NAME]
    tail = None
    for cand in cands:
        try:
            tail = read_tail(cand)
            logp = cand
            break
        except FileNotFoundError:
            continue
        except Exception as exc:                                 # noqa: BLE001
            lines.append("读不到 %s：%s" % (cand, exc))
    if tail is None:
        lines.append("两个位置都没有这个文件（%s、%s）——"
                     "说明程序**一次都没跑到写日志那一步**"
                     "（问题在解包/加载层，不在程序逻辑里）" % (cands[0], cands[1]))
    else:
        lines.extend(x.rstrip("\n") for x in tail)
    return lines, app, logp


def main(argv=None):
    ap = argparse.ArgumentParser(description="host_app 现场诊断")
    ap.add_argument("--app", default=None, help="要试跑的 exe（默认同目录的 %s）" % APP_NAME)
    ap.add_argument("--no-run", action="store_true", help="只做本地检查，不启动那个 exe")
    ap.add_argument("--no-pause", action="store_true", help="结束后不等回车（自动化用）")
    args = ap.parse_args(argv)

    fix_streams()                       # ★ 先保证打印中文不会把工具本身弄崩

    lines, app, logp = collect(args.app, args.no_run)
    text = "\n".join(lines)
    print(text)

    report = os.path.join(home_dir(), REPORT_NAME)
    try:
        with open(report, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print("\n诊断报告已写入：%s" % report)
    except Exception as exc:                                     # noqa: BLE001
        print("\n（诊断报告写不出去：%s —— 这本身就是个线索）" % exc)

    if getattr(sys, "frozen", False) and not args.no_pause:
        try:
            input("\n按回车关窗…")
        except Exception:                                        # noqa: BLE001
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
