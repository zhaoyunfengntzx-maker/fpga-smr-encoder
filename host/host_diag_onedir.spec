# -*- mode: python ; coding: utf-8 -*-
r"""PyInstaller 打包配置（S6 附）：诊断助手的**目录版**（零解包，最坏情况下也能跑）。

生成物
------
    host\dist_diag\host_app_diag\host_app_diag.exe

为什么诊断助手也要一个目录版
--------------------------
单文件包的唯一死穴是"启动时要解到 `%TEMP%\_MEIxxxxxx`"（沙箱受限令牌、
杀软/受控文件夹访问都会挡，现场就是 `%TEMP%` 里留下**0 文件**的 `_MEI*`）。
可偏偏"解包被挡"正是最需要诊断的故障 —— 此时那个 8 MB 的单文件诊断包
**自己也会解不开**，用户就什么报告都拿不到。目录版不解包，这条路始终通。

构建方式
--------
    python -m PyInstaller --noconfirm --clean ^
        --workpath host\_exe_work_diag_onedir ^
        --distpath host\dist_diag host\host_diag_onedir.spec

注意
----
* 排除清单与 `host/host_diag.spec`、`host/host_exe.spec` 同款。
* `host\dist_diag` 只在需要排查时用，`.gitignore` 已忽略。
"""

import os

SPEC_DIR = os.path.abspath(SPECPATH)                         # noqa: F821  = <repo>\host

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
    [],
    exclude_binaries=True,          # ★ 目录版：依赖不塞进 exe，直接放目录里
    name="host_app_diag",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,                   # ★ 关键：报错要看得见
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(                                              # noqa: F821
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="host_app_diag",
)
