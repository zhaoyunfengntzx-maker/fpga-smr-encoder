# -*- mode: python ; coding: utf-8 -*-
r"""PyInstaller 打包配置（S6）：把上位机打成**单文件 exe**，双击即用。

生成物
------
    host\dist\host_app.exe      单文件、目标机不需要装 Python

构建方式（不要直接敲 pyinstaller，走脚本，脚本会做环境自检）
----------------------------------------------------------
    pwsh -File tools\build_host_exe.ps1
    :: 或（Windows PowerShell 5.1）
    powershell -ExecutionPolicy Bypass -File tools\build_host_exe.ps1

为什么要这个 spec 文件，而不是一条 pyinstaller 命令
-------------------------------------------------
1. **SPECPATH 定位**：PyInstaller 注入的 `SPECPATH` 就是**本 spec 文件所在目录**
   （`host/`），所有路径都从这里派生，构建产物固定落在 `host/_exe_work/` 与
   `host/dist/`，**和当前工作目录无关**（在仓库根、在 host\、在别处跑，结果一样）。
   ⚠ `SPECPATH` 已经是目录，不要再套一层 `os.path.dirname`（套了会得到仓库根，
   报 `ERROR: script '...\FPGA\app.py' not found` —— 首次打包就踩过这个）。
2. **必须带上仓库的 `tools/`**：`host/link.py` 在**函数体内**延迟 import
   `tools/uart_scope.py` 与 `tools/uart_spi.py`（协议权威实现，故意不复制进 host/，
   避免与固件约定漂移）。PyInstaller 的静态分析看不到这种运行时 import，
   不写 hiddenimports 就会出现"源码能跑、exe 报 ModuleNotFoundError: uart_scope"。
3. **必须带上 matplotlib 的 QtAgg 后端**：`export_png.py` 在导入期执行
   `matplotlib.use("QtAgg")`，同样只能靠字符串分析，可能漏。
4. **精简体积**：显式排除用不到的 Qt 绑定与科学计算包。排除清单里的东西本项目
   一个都不用（排除不存在的模块不会报错，所以这份清单是安全的）。
5. **单文件（onefile）**：需求文档 docs/10 §3「交付形式」要求"单文件 .exe、
   双击即用、目标机不需装 Python"。代价是启动时要解包一次（首次约 3~10 s）；
   这是"一个文件"与"启动快"之间的取舍，交付按需求取前者。

注意
----
* 单文件模式下 `sys.executable` 才是 exe 真正的落点，`__file__` 指向临时解包目录
  （退出即删）。`host/link.py::_ensure_tools_on_path` 与
  `host/recorder.py::_load_tools` 都按这个事实找 `tools/`。
* `tools/uart_scope.py` 顶层 import numpy / matplotlib / serial，
  `tools/uart_spi.py` 顶层 import serial —— 都会被静态分析带进来，不必重复声明。
* 改任何 `host/*.py` 之后必须重新打包（exe 里是拷贝，不是链接）。
"""

import os

SPEC_DIR = os.path.abspath(SPECPATH)                         # noqa: F821  = <repo>\host
REPO_ROOT = os.path.dirname(SPEC_DIR)                        # = <repo>
TOOLS_DIR = os.path.join(REPO_ROOT, "tools")                 # 协议权威实现所在

# 界面入口。host/app.py 里有 `sys.path.insert(0, _HERE)`，打包后 host/ 下的模块
# 都在包内，静态分析会一起收进来，不需要额外 hiddenimports。
ENTRY = os.path.join(SPEC_DIR, "app.py")

# 阶段 3：界面资源随包分发（Inter 字体 OFL 1.1 + 复选框/开关位图）。
# 与 host_onedir.spec 保持一致；冻结后 theme._bundle_dir() 从 sys._MEIPASS 读。
ASSETS = os.path.join(SPEC_DIR, "assets")
FONT_DIR = os.path.join(ASSETS, "fonts")
IMG_DIR = os.path.join(ASSETS, "img")
DATAS = [
    (os.path.join(FONT_DIR, "Inter-*.ttf"), "assets/fonts"),
    (os.path.join(FONT_DIR, "OFL-1.1.txt"), "assets/fonts"),
    (os.path.join(IMG_DIR, "*.png"), "assets/img"),
    (os.path.join(REPO_ROOT, "docs", "22_ethernet_host_guide.md"), "docs"),
]

# ★ 解包目录与产物名的环境变量开关（2026-10-13 深夜新增，默认值 = 老行为，不受影响）：
#   用户机器上 `%TEMP%` 对本程序**不可写**（诊断报告 `TEMP … 失败：[Errno 13] Permission
#   denied`，而 `%TEMP%` 的 ACL 里该用户是"完全控制" ⇒ 另有拦截，见 README 排查节），
#   于是做出"把解包目录放到 exe 旁边"的变体：
#       $env:HOST_EXE_RUNTIME_TMPDIR = "."          # 相对路径 ⇒ 解到 exe 所在目录
#       $env:HOST_EXE_NAME = "host_app_本地解包"
#       python -m PyInstaller --noconfirm --clean --workpath host\_exe_work_local
#           --distpath host\dist_local host\host_exe.spec
#   该目录已被现场诊断证明"可以写"（`exe 目录 … 可以写` / `可以建子目录`）。
RUNTIME_TMPDIR = os.environ.get("HOST_EXE_RUNTIME_TMPDIR") or None
EXE_NAME = os.environ.get("HOST_EXE_NAME") or "host_app"

# 静态分析看不到的运行时 import（见文件头第 2、3 条）
HIDDEN = [
    "uart_scope",                          # tools/uart_scope.py 帧校验/解码/组帧
    "uart_spi",                            # tools/uart_spi.py 命令编码/应答校验
    "matplotlib.backends.backend_qtagg",   # matplotlib.use("QtAgg")
    "serial.tools.list_ports",             # 串口枚举（host/ports.py）
]

# 本项目一个都不用的包：排除掉能少几十 MB，也让杀软误报面更小
EXCLUDES = [
    "tkinter", "PyQt5", "PyQt6", "PySide2", "shiboken2",
    "pandas", "scipy", "sklearn", "sympy", "numba", "sqlalchemy",
    "IPython", "jupyter", "notebook", "pytest", "sphinx", "docutils",
    "PIL.ImageTk",                         # PIL 只用 Image，不用 Tk 桥
    "matplotlib.backends.backend_tkagg",
    "matplotlib.backends.backend_pdf",
    "matplotlib.backends.backend_svg",
    "matplotlib.backends.backend_ps",
    "matplotlib.backends.backend_webagg",
    "numpy.f2py", "numpy.testing", "numpy.distutils",
]

a = Analysis(                                                # noqa: F821
    [ENTRY],
    pathex=[SPEC_DIR, TOOLS_DIR, REPO_ROOT],
    binaries=[],
    datas=DATAS,
    hiddenimports=HIDDEN,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=EXCLUDES,
    noarchive=False,
    optimize=0,
)

# ---- 裁掉 MKL 里本程序用不到的代码路径变体（见 tools/_slim_spec.py 的说明）----
# 585 MB 里有 ~405 MB 是 MKL；只保留 rt/core/intel_thread + avx2 + def 两条路径。
import re as _re

_MKL_DROP = _re.compile(
    r"^mkl_(avx512|mc3|tbb_thread|sequential|scalapack\w*|blacs\w*|cdft\w*)"
    r"(\.[0-9]+)?\.dll$|^mkl_vml_(avx512|mc3)\.2\.dll$", _re.I)


def _slim(binaries):
    kept, dropped = [], []
    for b in binaries:
        name = os.path.basename(b[0])
        if _MKL_DROP.match(name):
            dropped.append(name)
        else:
            kept.append(b)
    if dropped:
        print("[slim] 裁掉 %d 个 MKL 变体 DLL" % len(dropped))
    return kept


a.binaries = _slim(a.binaries)                                    # noqa: F821

pyz = PYZ(a.pure)                                            # noqa: F821

exe = EXE(                                                   # noqa: F821
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name=EXE_NAME,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                      # 不用 UPX：压缩过的 exe 更容易被杀软误报
    upx_exclude=[],
    runtime_tmpdir=RUNTIME_TMPDIR,
    console=False,                  # GUI 程序：不弹黑窗
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
