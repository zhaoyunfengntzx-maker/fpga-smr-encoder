"""给两个 spec 加「裁 MKL 冗余变体」的过滤器。

为什么：目录版 585 MB 里有 ~405 MB 是 MKL 的 20 多个 DLL，而本程序对 numpy 的
用法只有数组运算 / arctan2 / rfft / polyfit —— 一个 BLAS 调用都没有，却被迫
背着 mkl_core + 全套代码路径变体。

安全边界：
  * 保留 `mkl_rt`（派发器）、`mkl_core`、`mkl_intel_thread`（线程层）、
    `mkl_avx2` + `mkl_vml_avx2`（现代 CPU 主路径）、`mkl_def` + `mkl_vml_def`
    （不带 AVX2 的老机器兜底）。
  * 丢掉 avx512 / mc3（这两条路径在本机 i9-14900HX 上根本不会被选中）、
    tbb/sequential 线程层、scalapack / blacs / cdft（稀疏与分布式，本程序不用）。
  * 万一某台机器派发失败，最坏是 numpy 报 "cannot load mkl"，**不会静默算错**；
    `host_app.exe --diag` 与包内烟测都覆盖了 numpy/analysis 的实际调用。

用法：python -X utf8 tools/_slim_spec.py
"""

import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

BLOCK = '''
# ---- 裁掉 MKL 里本程序用不到的代码路径变体（见 tools/_slim_spec.py 的说明）----
# 585 MB 里有 ~405 MB 是 MKL；只保留 rt/core/intel_thread + avx2 + def 两条路径。
import re as _re

_MKL_DROP = _re.compile(
    r"^mkl_(avx512|mc3|tbb_thread|sequential|scalapack\\w*|blacs\\w*|cdft\\w*)"
    r"(\\.[0-9]+)?\\.dll$|^mkl_vml_(avx512|mc3)\\.2\\.dll$", _re.I)


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
'''

for spec in ("host_onedir.spec", "host_exe.spec"):
    p = os.path.join(ROOT, "host", spec)
    t = io.open(p, encoding="utf-8").read()
    if "_MKL_DROP" in t:
        print("[skip]", spec, "已经裁过")
        continue
    anchor = "pyz = PYZ(a.pure)"
    assert t.count(anchor) == 1, spec
    t = t.replace(anchor, BLOCK.strip("\n") + "\n\n" + anchor)
    io.open(p, "w", encoding="utf-8", newline="").write(t)
    print("[ok]", spec)
