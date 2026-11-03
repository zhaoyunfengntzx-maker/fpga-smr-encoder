# -*- coding: utf-8 -*-
"""从 v74 的两个 impl_check tcl 派生 v90 版本（只做 ASCII 路径/名字替换）。

注意：必须用 utf-8-sig 读、utf-8 写（无 BOM），并且 `_synth_work_vNN` 目录名要一起替换，
否则会留下 `_synth_work_v74/rtl_v90` 这种不存在的路径，Vivado 报
`Unable to run synthesis. No HDL sources found in project`。
"""
import io, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PAIRS = [
    ("tools/impl_check_v74.tcl", "tools/impl_check_v90.tcl"),
    ("tools/impl_check_disp_v74.tcl", "tools/impl_check_disp_v90.tcl"),
]

# 顺序重要：先换长的、更具体的，再换短的
SUBS = [
    ("_impl_disp_v74", "_impl_disp_v90"),
    ("_impl_v74", "_impl_v90"),
    ("_synth_work_v74", "_synth_work_v90"),
    ("rtl_v74", "rtl_v90"),
    ("enc_top_disp_v74", "enc_top_disp_v90"),
    ("enc_top_v74", "enc_top_v90"),
    ("_v74", "_v90"),
]


def main():
    for src_rel, dst_rel in PAIRS:
        src = os.path.join(ROOT, src_rel)
        dst = os.path.join(ROOT, dst_rel)
        s = io.open(src, encoding="utf-8-sig").read()
        for a, b in SUBS:
            s = s.replace(a, b)
        io.open(dst, "w", encoding="utf-8", newline="\n").write(s)
        raw = io.open(dst, "rb").read()
        print("%-34s %6d B  first=%s" % (os.path.basename(dst), len(raw), raw[:4].hex()))
        assert not raw.startswith(b"\xef\xbb\xbf"), "BOM leaked into " + dst


if __name__ == "__main__":
    main()
