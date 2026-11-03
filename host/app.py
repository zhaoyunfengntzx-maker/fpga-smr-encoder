r"""上位机入口（S1 连接 + S2 转速与倍频 + S3 波形与告警 + S4 ABZ/UVW 等效采样
+ S5 CSV 记录与 PNG 导出）。

用法（在仓库根目录）：
    python host\app.py                     正常启动图形界面
    python host\app.py --port COM3         启动后自动连接 COM3
    python host\app.py --smoke smoke.png --port COM3 --seconds 3
                                           不常驻：建窗、可选自动连接、截图后退出
                                           （给自动化验证/看外观用）
    python host\app.py --smoke smoke.png --port COM3 --seconds 8 --height 1500
                                           顺便把窗口拉高，好把下面几张卡片一起截进去
    python host\app.py --smoke smoke.png --port COM3 --seconds 14 --record
                                           --record-dir 记录目录
                                           顺便开表记录：退出前会停表并打印
                                           「时长/帧数/体积/丢帧估计」与 CSV 路径
    python host\app.py --port COM3 --record --export
                                           连上就自动记录，并各导出一次波形/ABZ PNG
                                           （无人值守长稳用）

界面样式与配色集中在 host/theme.py，协议层在 host/link.py，本文件只负责装配。
"""

import argparse
import math
import os
import sys
import threading
import time
import traceback
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


# ---------------------------------------------------------------------------
# 启动诊断（为什么要有这一段）
# ---------------------------------------------------------------------------
# 打包成 exe 后 `console=False`，**没有黑窗**：一旦在"进到窗口之前"出问题
# （解包失败、缺 DLL、导入期异常），用户看到的就是"双击了，什么都没发生"，
# 而错误文本没有任何地方能落下来 —— m08093 用户反馈"单文件打不开、目录版能开"
# 时就是这个处境，只能靠猜。所以这里做三件事：
#   1. 每次启动往 exe 旁边的日志写一行"启动…/已启动界面"，用启动时间判断卡在哪；
#   2. 导入期异常 / 主循环异常 / Qt 槽里的未捕获异常统一写日志 + 弹窗（弹窗失败
#      就用 Win32 MessageBoxW 兜底，再失败才只留日志）；
#   3. `--diag`：只靠标准库把"冻结信息 + 各目录可写性 + 磁盘 + 关键 import"
#      打印并写进日志，不建窗口 —— 用户在真机上跑一次就能把现场交回来。
# 日志/诊断都只写 exe 旁边（源码模式写 host/ 下），路径规则与 host/ui_prefs.py 一致。


def _home_dir():
    """exe 所在目录（冻结）/ host 目录（源码）。与 host/ui_prefs.py::_home_dir 同规则。"""
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        return os.path.dirname(os.path.abspath(sys.executable))
    return _HERE


LOG_PATH = os.path.join(_home_dir(), "host_app_run.log")
_LOG_MAX = 512 * 1024                     # 单卷上限；保留 .1/.2/.3 共 4 卷 ≈ 2 MB
_LOG_BACKUPS = 3

# ★ 2026-11 起日志走标准库 logging（以前是手写 open/append）：
#   以前只有"启动/异常"两类文本，没有级别、没有线程名、没有毫秒，现场把 log 发回来
#   也没法按模块筛。现在统一到 root logger：
#       logging.getLogger("host.link")  /  "host.worker"  /  "host.ui" ……
#   格式里带毫秒和线程名——串口线程的错和界面线程的错终于分得开了。
#   仍保留 `_log(text)` 这个老入口（几十处调用点），只是转成 INFO 记录。


def _setup_logging():
    """配置 root logger：滚动的文件 handler + 控制台（有的话）。任何失败都吞掉。"""
    import logging
    from logging.handlers import RotatingFileHandler

    root = logging.getLogger()
    if root.handlers:                     # 重复调用（--smoke 里会再进来一次）
        return root
    root.setLevel(logging.DEBUG)
    fmt = logging.Formatter(
        "%(asctime)s.%(msecs)03d %(levelname)-5s [%(threadName)s] %(name)s: %(message)s",
        "%Y-%m-%d %H:%M:%S")
    try:
        fh = RotatingFileHandler(LOG_PATH, maxBytes=_LOG_MAX,
                                 backupCount=_LOG_BACKUPS, encoding="utf-8")
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(fmt)
        root.addHandler(fh)
    except Exception:                                            # noqa: BLE001
        pass
    try:
        sh = logging.StreamHandler()
        sh.setLevel(logging.INFO)
        sh.setFormatter(fmt)
        root.addHandler(sh)
    except Exception:                                            # noqa: BLE001
        pass
    root.info("日志已启用：%s（%d KB × %d 卷）", LOG_PATH,
              _LOG_MAX // 1024, _LOG_BACKUPS + 1)
    return root


def _log(line):
    """写一条运行日志。**任何失败都吞掉**：日志不能反过来把程序弄死。"""
    try:
        import logging
        _setup_logging()
        logging.getLogger("host").info("%s", line)
    except Exception:                                            # noqa: BLE001
        pass


def _say(text, err=False):
    """安全打印：窗口版打包后 stdout/stderr 可能不存在，编码也可能不配合（都吞掉）。

    ★ 2026-10-13 实测：把中文打到 GBK 管道/控制台时，
      `UnicodeEncodeError: 'gbk' codec can't encode character …` 会直接把工具弄崩。
      这里**不换编码**（真控制台上 Python 本来就按 UTF-8 走），只保证**绝不抛异常**。
    """
    try:
        stream = sys.stderr if err else sys.stdout
        if stream is None:
            return
        print(text, file=stream)
    except Exception:                                            # noqa: BLE001
        pass


def _env_text():
    return ("可执行文件：%s\n冻结：%s   解包目录：%s\n工作目录：%s\nTEMP：%s\n"
            "Python：%s" % (sys.executable, getattr(sys, "frozen", False),
                            getattr(sys, "_MEIPASS", "-"), os.getcwd(),
                            os.environ.get("TEMP") or os.environ.get("TMP") or "-",
                            sys.version.replace("\n", " ")))


def _alert(title, text):
    """报错弹窗：优先 Qt；连 Qt 都起不来就用 Win32 MessageBoxW。"""
    try:
        from PySide6.QtWidgets import QApplication, QMessageBox
        if QApplication.instance() is None:
            QApplication(sys.argv[:1])
        box = QMessageBox()
        box.setIcon(QMessageBox.Critical)
        box.setWindowTitle(title)
        box.setText(text)
        box.exec()
        return
    except Exception:                                            # noqa: BLE001
        pass
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, text, title, 0x10)
    except Exception:                                            # noqa: BLE001
        _say("%s：%s" % (title, text), err=True)


def _write_probe(d):
    """在目录 d 里真写一个文件再删掉，返回"可以写"/"失败：…"。"""
    if not d:
        return "没有这个环境变量"
    # ★ 2026-10-17 全面自查修：与 host/diag.py::write_probe 同一处隐患（固定文件名会
    #   截断别人的同名文件、失败路径不清理）—— 改成带 pid 的名字 + finally 清理。
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


def _try_import(mod):
    try:
        __import__(mod)
        m = sys.modules.get(mod)
        return "成功（%s）" % (getattr(m, "__version__", "无版本号") if m is not None else "?")
    except Exception as exc:                                     # noqa: BLE001
        return "失败：%s: %s" % (type(exc).__name__, exc)


def _diag_report():
    """`--diag`：不建窗口，把排查"打不开"要的信息收集起来（只用标准库）。"""
    import platform
    import shutil
    base = _home_dir()
    lines = ["===== host_app 诊断 %s =====" % time.strftime("%Y-%m-%d %H:%M:%S"),
             _env_text(), "exe 目录：%s" % base]
    for name, d in (("exe 目录", base), ("TEMP", os.environ.get("TEMP") or ""),
                    ("工作目录", os.getcwd())):
        lines.append("写测试 — %s（%s）：%s" % (name, d or "-", _write_probe(d)))
    try:
        u = shutil.disk_usage(base)
        lines.append("磁盘：可用 %.1f GB / 共 %.1f GB" % (u.free / 2 ** 30, u.total / 2 ** 30))
    except Exception as exc:                                     # noqa: BLE001
        lines.append("磁盘：读不到（%s）" % exc)
    lines.append("系统：%s" % platform.platform())
    # tools/ 平时由 host/link.py 延迟塞进 sys.path，这里照同样规则来一遍，
    # 不然源码模式会误报"import uart_scope 失败"（那是路径问题，不是包的问题）。
    for cand in ((os.path.join(base, "tools") if getattr(sys, "frozen", False) else None),
                 os.path.join(os.path.dirname(_HERE), "tools"),
                 os.path.join(_HERE, "tools")):
        if cand and os.path.isdir(cand) and cand not in sys.path:
            sys.path.insert(0, cand)
    for mod in ("PySide6", "PySide6.QtWidgets", "serial", "numpy", "matplotlib",
                "matplotlib.backends.backend_qtagg", "uart_scope", "uart_spi"):
        lines.append("import %s：%s" % (mod, _try_import(mod)))
    text = "\n".join(lines)
    _say(text)
    _log("诊断：\n" + text)
    return text


_HOOK_LAST = [0.0, 0]          # [上次弹窗时刻, 被压掉的次数]


def _hook(tp, val, tb):
    """Qt 槽里的未捕获异常也会走这里（否则只在 stderr 上一闪而过）。

    ★ 收尾批：原来每次异常都弹模态框——一个 300 ms 的定时器槽出错就会把界面
      淹没到不可用。现在**永远写日志**，弹窗 60 秒最多一次，其余只记次数。
    """
    _log("未捕获异常：\n%s" % "".join(traceback.format_exception(tp, val, tb)))
    now = time.time()
    if now - _HOOK_LAST[0] < 60.0:
        _HOOK_LAST[1] += 1
        return
    extra = ""
    if _HOOK_LAST[1]:
        extra = "\n（过去 60 秒还有 %d 次同类异常，已写入日志）" % _HOOK_LAST[1]
    _HOOK_LAST[0] = now
    _HOOK_LAST[1] = 0
    _alert("host_app 出错", "%s%s\n\n详情见：%s" % (val, extra, LOG_PATH))


def _thread_hook(args):
    """工作线程里的未捕获异常也会走这里（审计 B8）。

    ★ 打包成 exe 后没有控制台，`threading.excepthook` 未装时线程崩溃只会静默
      消失（现象：连续流/抓包"没数据但也没报错"）。改成和主线程一样写日志。
    """
    try:
        _log("线程未捕获异常（%s）：\n%s"
             % (getattr(args.thread, "name", "?"),
                "".join(traceback.format_exception(args.exc_type, args.exc_value,
                                                   args.exc_traceback))))
    except Exception:                                    # noqa: BLE001
        pass


sys.excepthook = _hook
try:
    threading.excepthook = _thread_hook
except Exception:                                        # noqa: BLE001  老 Python 没有
    pass

# `--diag` 要在**导入 Qt 之前**处理：Qt/依赖装不上时，这条命令恰恰是最有用的那条。
if "--diag" in sys.argv[1:]:
    _diag_report()
    raise SystemExit(0)

_START_AT = time.time()
_log("启动：%s | argv=%s" % (_env_text().replace("\n", "  "), sys.argv[1:]))

try:
    from PySide6.QtCore import QTimer                            # noqa: E402
    from PySide6.QtWidgets import QApplication                   # noqa: E402

    import recorder as rc                                        # noqa: E402
    import theme as th                                           # noqa: E402
    import ui_font as uf                                         # noqa: E402
    from main_window import MainWindow                           # noqa: E402
except BaseException as _imp_exc:                                # noqa: BLE001
    _log("启动失败（导入阶段）：\n%s" % traceback.format_exc())
    _alert("host_app 启动失败",
           "加载模块时出错：\n%s\n\n完整信息已写入：\n%s" % (_imp_exc, LOG_PATH))
    raise SystemExit(3)

# --smoke 的退出码：0 = 一切正常；1 = 截图/连接/导出任一出错（自动化验收要看得见失败）。
# 以前 _grab 里截图失败也照样 exit 0，脚本无法判断"这次跑没跑成功"。
_FAIL = []


def main(argv=None):
    ap = argparse.ArgumentParser(description="host_app（S5）")
    ap.add_argument("--port", default=None, help="启动后自动连接的端口，例如 COM3")
    ap.add_argument("--smoke", metavar="PNG", default=None,
                    help="不进入主循环：建窗、可选自动连接、截图后退出")
    ap.add_argument("--seconds", type=float, default=2.0, help="--smoke 模式下等待时长")
    ap.add_argument("--height", type=int, default=0,
                    help="把窗口高度改成这个值（截长图用，0 = 用默认）")
    ap.add_argument("--record-dir", default=None,
                    help="把记录保存目录改成这个路径（默认存到“我的文档\\host_app记录”）")
    ap.add_argument("--record", action="store_true",
                    help="连上后自动开始记录（无人值守长稳用；--smoke 退出前会停表并打印统计）")
    ap.add_argument("--export", action="store_true",
                    help="连上后自动各导出一次波形与 ABZ/UVW 的 PNG（配 --smoke 验证导出链路）")
    ap.add_argument("--diag", action="store_true",
                    help="不建窗口：把冻结信息/目录可写性/磁盘/关键 import 打印并写进日志"
                         "（排查「双击没反应」用；在解析参数之前就处理掉了）")
    args = ap.parse_args(argv)

    # 参数先校验：以前 `--seconds nan` 会在 QTimer 那行抛英文 ValueError/OverflowError
    if not math.isfinite(args.seconds) or not (0.0 < args.seconds <= 86400.0):
        print("--seconds 要给 0~86400 之间的秒数（收到 %r）" % args.seconds, file=sys.stderr)
        return 2
    if args.export and not args.port:
        print("--export 要配合 --port 用（没有串口就没数据可导）", file=sys.stderr)
        return 2

    app = QApplication(sys.argv[:1])
    app.setApplicationName("host_app")
    # 阶段 3：Inter 随包分发，先注册字体再套样式表（注册失败就静默回落系统字体）
    _fonts = uf.apply(app)
    _log("界面字体：Inter %s（%d 个文件）" % ("已装载" if _fonts else "未装载，回落系统字体",
                                              _fonts))
    app.setStyleSheet(th.app_qss())

    win = MainWindow()
    if args.height:
        win.resize(1180, int(args.height))
    if args.record_dir:
        if not win.record.set_dir(args.record_dir):
            print("--record-dir 不能用：%s" % (win.record.lab_note.text() or args.record_dir),
                  file=sys.stderr)
            return 2
    if args.record:
        win.record.chk_auto.setChecked(True)
    win.show()
    _log("已建窗显示（耗时 %.1f s）" % (time.time() - _START_AT))

    if args.port:
        QTimer.singleShot(300, lambda: win.connect_to(args.port))
    if args.export and args.port:
        QTimer.singleShot(1500, lambda: win._on_export("wave"))
        QTimer.singleShot(2500, lambda: win._on_export("abz"))

    if args.smoke:
        def _grab():
            path = os.path.abspath(args.smoke)
            # 窗口高度会被屏幕限制，套了滚动区就截不全 —— 直接抓滚动区里的内容控件，
            # 这样无论屏幕多小都能拿到"整页"效果（省略窗框，正好当预览图）。
            target = getattr(win, "scroll", None)
            target = target.widget() if target is not None else win
            try:
                ok = bool(target.grab().save(path))
            except Exception as exc:                            # noqa: BLE001
                ok = False
                print("截图失败：%s" % exc, file=sys.stderr)
            print("截图%s：%s（%dx%d）"
                  % ("成功" if ok else "失败", path, target.width(), target.height()))
            if not ok:
                _FAIL.append("截图失败")
            win.log_line("--smoke 模式：截图 %s" % path)
            # 记录统计一定要在这次运行结束前落纸：长稳/验收要看行数、体积、丢帧估计
            win.record.stop_record(why="--smoke 结束")
            st = win.record.stats() or {}
            if st.get("rows"):
                print(rc.stats_text(st))
            # 连不上串口时 stdout 也要有话说：自动化（以及人）才知道失败原因
            w = getattr(win, "worker", None)
            if args.port and (w is None or not w.connected):
                msg = (w.error if w is not None else None) or "串口没连上"
                print("连接失败：%s（%s）" % (msg, args.port), file=sys.stderr)
                _FAIL.append("连接失败")
            # ★ 审计 2 #24：以前 --smoke 直接 app.quit()，绕过 closeEvent，
            #   退出清理（停流/关记录/存 prefs）从来没被测到。走关窗路径才是真验收。
            win.close()
        # --export 的两次导出排在 1500/2500 ms，smoke 必须等它们跑完再退出，
        # 否则"--smoke --seconds 1 --export"会在导出前就 quit（以前静默什么都不导）
        wait_ms = max(500, int(args.seconds * 1000))
        if args.export:
            wait_ms = max(wait_ms, 3500)
        QTimer.singleShot(wait_ms, _grab)
        app.exec()
        if _FAIL:
            print("--smoke 有失败项：%s" % "、".join(_FAIL), file=sys.stderr)
            return 1
        return 0

    return app.exec()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as _exc:                                # noqa: BLE001
        _log("运行时异常：\n%s" % traceback.format_exc())
        _alert("host_app 出错",
               "%s\n\n完整信息已写入：\n%s" % (_exc, LOG_PATH))
        sys.exit(4)
