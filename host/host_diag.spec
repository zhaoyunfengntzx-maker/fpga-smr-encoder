# -*- mode: python ; coding: utf-8 -*-
r"""PyInstaller 打包配置（S6 附）：把 `host/diag.py` 打成**小号控制台诊断包**。

生成物
------
    host\dist\host_app_diag.exe      几 MB、带黑窗、双击即用

为什么值得单独一个 spec
---------------------
`host\dist\host_app.exe` 是 GUI（`console=False`）单文件包：出问题时**没有
任何可见信息**，用户能说的只有"打不开"。而"打不开"的全部可能性都集中在一处 ——
单文件包启动时要先把 200 MB 解到 `%TEMP%\_MEIxxxxxx`（目录版不这么做，所以
目录版一直是好的，见 `docs/DEV_STATUS.md` §1.77）。这个诊断包：
1. **只用标准库**（不 import Qt/numpy/matplotlib），产物几 MB、构建几秒 ——
   它自己就是"最小的单个文件包"，能出黑窗就说明"解包"这条路在目标机上是通的；
2. `console=True`：引导器和 Python 的报错**直接打在屏幕上**，不再是一闪而过；
3. 它会去试跑同目录的 `host_app.exe --diag` 并读回那份运行日志，
   把"断在哪一层"一次问清（见 `host/diag.py` 文件头）。

构建方式
--------
    python -m PyInstaller --noconfirm --clean ^
        --workpath host\_exe_work_diag --distpath host\dist host\host_diag.spec

注意
----
* `SPECPATH` 已经是本 spec 所在目录（`host/`），派生路径时不要再套 dirname。
* 它是**给人跑的一次性排查工具**，不进交付物、不影响 `host_app.exe`。
* 排除清单与 `host/host_exe.spec` 保持同款（本工具其实都用不到）。
"""

import os

SPEC_DIR = os.path.abspath(SPECPATH)                         # noqa: F821  = <repo>\host

# ★ 2026-10-13 深夜新增：解包目录可用环境变量覆盖，默认 None = 老行为（用系统 TEMP）。
# 用户机器上 `%TEMP%` 对本程序不可写，而 exe 所在目录可写 ⇒ 需要"本地解包"版时：
#     $env:HOST_DIAG_RUNTIME_TMPDIR = "."     # 相对路径：解到工作目录（见 README 排查节）
RUNTIME_TMPDIR = os.environ.get("HOST_DIAG_RUNTIME_TMPDIR") or None
EXE_NAME = os.environ.get("HOST_DIAG_NAME") or "host_app_diag"

ENTRY = os.path.join(SPEC_DIR, "diag.py")

EXCLUDES = [
    "tkinter", "PyQt5", "PyQt6", "PySide2", "PySide6", "shiboken2", "shiboken6",
    "pandas", "scipy", "sklearn", "sympy", "numba", "sqlalchemy",
    "IPython", "jupyter", "notebook", "pytest", "sphinx", "docutils",
    "PIL", "matplotlib", "numpy", "serial",
]

a = Analysis(                                                # noqa: F821
    [ENTRY],
    pathex=[SPEC_DIR],
    binaries=[],
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=EXCLUDES,
    noarchive=False,
    optimize=0,
)

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
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=RUNTIME_TMPDIR,
    console=True,                   # ★ 关键：报错要看得见
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
