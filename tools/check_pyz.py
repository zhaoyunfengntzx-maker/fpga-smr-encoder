# -*- coding: utf-8 -*-
r"""包内 PYZ 复核：模块数 + 正向标志串命中 + 逆向退场串无命中。

用法：
    python tools\check_pyz.py host\dist_onedir\host_app\host_app.exe
    python tools\check_pyz.py <exe> --forward-files host\_fwd.txt --backward-files host\_bwd.txt

原理：`CArchiveReader` 读出 exe 里的 `PYZ.pyz` → `ZlibArchiveReader` 列出 `toc` → 把每个模块的
`marshal.dumps(code)` 串起来做字节搜索（字符串常量在 marshal 结果里是明文，所以能直接搜）。
中间产物写在 `%TEMP%` 下。
"""
import argparse
import marshal
import os
import sys
import tempfile

from PyInstaller.archive.readers import CArchiveReader, ZlibArchiveReader

FORWARD_MODULES = [
    "abz_popup", "wave_popup", "panel_abz", "panel_record", "panel_wave",
    "main_window", "recorder", "export_png", "theme", "ui_font", "ui_kit",
    "link", "ports", "abz", "alarm", "encoder", "regs",
]
FORWARD_STRINGS = [
    # ⑨ 独立窗口
    "abz_popup", "AbzPopup", "popup_requested", "canvas_h", "show_popup",
    "_open_abz_popup", "_sync_abz_bins", "ABZ / UVW 等效采样 · 独立窗口",
    # 记录页加固 / 取证
    "token_flags", "parent_process", "env_warning", "write_diagnosis",
    "acl_report", "cfa_state", "diag_write", "writable_dir_or_fallback",
    "pick_dir", "_probe_once", "is_admin", "_show_diag", "进程身份",
    # 更早几批仍须在
    "WavePopup", "_open_wave_popup", "TRIG_SOURCES", "_find_trigger",
    "SQ_GAP", "sq_per_bins", "app_qss", "auto_scale", "refresh_fixed_lines",
]
BACKWARD_STRINGS = [
    "CardMax", "install_maximize", "_setup_card_maximize", "_enter_card_max",
    "_restore_card_max", "set_max_layout", "SIDE_MAX_W", "MAX_BTN_ON",
    "maxHide", "set_plain_wheel_zoom", "_plain_zoom", "MAX_BTN_WIDTH",
]


def _lines(path):
    if not path:
        return []
    with open(path, "r", encoding="utf-8") as fh:
        return [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]


def load_pyz(exe, tmpdir):
    """把 exe 里的 PYZ.pyz 落到临时文件，返回 (模块名列表, marshal 字节)。"""
    car = CArchiveReader(exe)
    pyz_names = [n for n in car.toc if n.endswith(".pyz")]
    if not pyz_names:
        raise SystemExit("exe 里没找到 PYZ 成员")
    pyz_path = os.path.join(tmpdir, "pkg_review.pyz")
    with open(pyz_path, "wb") as fh:
        fh.write(car.extract(pyz_names[0]))
    z = ZlibArchiveReader(pyz_path)
    mods = sorted(z.toc)
    dump = bytearray()
    for name in mods:
        try:
            dump += marshal.dumps(z.extract(name))
        except Exception as exc:  # 个别模块读不出不影响整体结论，但要报出来
            print("  [warn] 提取失败", name, repr(exc))
    return mods, bytes(dump)


def main(argv=None):
    ap = argparse.ArgumentParser(description="包内 PYZ 复核")
    ap.add_argument("exe", help="打包产物里的 host_app.exe")
    ap.add_argument("--forward-files", help="每行一个必出现字符串（追加到内置清单）")
    ap.add_argument("--backward-files", help="每行一个不得出现字符串（追加到内置清单）")
    args = ap.parse_args(argv)

    with tempfile.TemporaryDirectory(prefix="pyz_review_") as tmpdir:
        mods, dump = load_pyz(args.exe, tmpdir)
        print("PYZ 模块数 =", len(mods), "| marshal 字节 =", len(dump))
        print("CArchive 入口脚本 =",
              [n for n in CArchiveReader(args.exe).toc if n == "app"] or "（未找到 app）")

        fwd_mod = FORWARD_MODULES + _lines(args.forward_files)
        fwd_str = FORWARD_STRINGS + _lines(args.forward_files)
        bwd_str = BACKWARD_STRINGS + _lines(args.backward_files)

        miss_mod = [m for m in fwd_mod if m not in mods]
        print("-- 正向模块 --  期望", len(fwd_mod), "| 缺", len(miss_mod), miss_mod)
        miss_str = [s for s in fwd_str if s.encode("utf-8") not in dump]
        print("-- 正向字符串 -- 期望", len(fwd_str), "| 缺", len(miss_str), miss_str)
        bad = [s for s in bwd_str if s.encode("utf-8") in dump]
        print("-- 逆向字符串（应为空）-- 检查", len(bwd_str), "| 命中", len(bad), bad)

        ok = not miss_mod and not miss_str and not bad
        print("结论：", "PASS" if ok else "FAIL")
        return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
