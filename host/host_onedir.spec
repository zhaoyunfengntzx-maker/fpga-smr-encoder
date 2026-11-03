# -*- mode: python ; coding: utf-8 -*-
r"""PyInstaller 打包配置（S6 附）：把上位机打成**目录版（onedir）**。

生成物
------
    host\dist_onedir\host_app\host_app.exe     双击即用（同目录带一堆依赖）
    host\dist_onedir\host_app\_internal\…           依赖与资源

为什么还要一个目录版
------------------
1. **运行时零解包**：单文件 exe 每次启动都要把 200+ MB 解到
   `%TEMP%\_MEIxxxxxx` 再启动（首次 3~10 s），目录版直接就地加载。
   在**受限沙箱**里这点是决定性的：PyInstaller 引导器建 `_MEI*` 时用的是
   「只给当前用户 SID」的显式 DACL，而 DSH 沙箱令牌是**写受限令牌**
   （只认能力 SID `S-1-4-…`）⇒ 解包第一个文件就被拒（`Permission denied`、
   `_MEI*` 目录里 0 个文件）。目录版不建这个目录，因此沙箱里能跑，
   可以在沙箱内完成打包产物的端到端验证（截图 / 连板 / 记录导出）。
2. **交付备选**：杀软对单文件的解包行为更敏感；目录版启动快、便于增量替换
   某个 py 文件（拷进 `_internal` 即可，不用重打包）。
   需求文档 `docs/10_host_requirements.md` 要的"单文件、双击即用"仍由
   `host/host_exe.spec`（`host\dist\host_app.exe`）满足，这个目录版是并存产物。

构建方式
--------
    python -m PyInstaller --noconfirm --clean ^
        --workpath host\_exe_work_onedir --distpath host\dist_onedir host\host_onedir.spec

其余注意事项（`SPECPATH` 已是 spec 所在目录、必须带 `tools/`、matplotlib QtAgg、
排除用不到的包）与 `host_exe.spec` 完全一致 —— 那份文件头写得很细，改动时两边同步。
"""

import os

SPEC_DIR = os.path.abspath(SPECPATH)                         # noqa: F821  = <repo>\host
REPO_ROOT = os.path.dirname(SPEC_DIR)                        # = <repo>
TOOLS_DIR = os.path.join(REPO_ROOT, "tools")

ENTRY = os.path.join(SPEC_DIR, "app.py")

# 阶段 3：界面资源随包分发（Inter 字体 OFL 1.1 + 复选框/开关位图）
# ★ 必须在 datas 里给，不能靠"exe 旁边放一份"：这些是只读资源，
#   冻结后由 theme._bundle_dir() 从 sys._MEIPASS（目录版的 _internal）读。
ASSETS = os.path.join(SPEC_DIR, "assets")
FONT_DIR = os.path.join(ASSETS, "fonts")
IMG_DIR = os.path.join(ASSETS, "img")
DATAS = [
    (os.path.join(FONT_DIR, "Inter-*.ttf"), "assets/fonts"),
    (os.path.join(FONT_DIR, "OFL-1.1.txt"), "assets/fonts"),
    (os.path.join(IMG_DIR, "*.png"), "assets/img"),
    (os.path.join(REPO_ROOT, "docs", "22_ethernet_host_guide.md"), "docs"),
]

HIDDEN = [
    "uart_scope",
    "uart_spi",
    "matplotlib.backends.backend_qtagg",
    "serial.tools.list_ports",
]

EXCLUDES = [
    "tkinter", "PyQt5", "PyQt6", "PySide2", "shiboken2",
    "pandas", "scipy", "sklearn", "sympy", "numba", "sqlalchemy",
    "IPython", "jupyter", "notebook", "pytest", "sphinx", "docutils",
    "PIL.ImageTk",
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
    [],
    exclude_binaries=True,          # ★ 依赖不进 exe，交给下面的 COLLECT 铺成目录
    name="host_app",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
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
    name="host_app",
)
