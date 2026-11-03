#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
to_lf.py — 把工作树里的文本文件统一成纯 LF（不带 BOM）

为什么需要它
------------
`.gitattributes` 里 `*.md *.v *.sv *.py *.ps1 *.tcl *.xdc` 都声明成 `text eol=lf`，
意思是"仓库里存 LF，检出到工作树也是 LF"。但本工程的文件是在加 `.gitattributes`
**之前**用 Windows 工具写出来的（CRLF），后来被 Python 的默认 text 模式重写时又会
把 `\\n` 变成 `\\r\\n`。结果是：改 4 行会显示成整文件 1500 行的 diff，无法审查。

用法
----
    python tools/to_lf.py --check          # 只报告哪些文件带 CRLF / BOM
    python tools/to_lf.py                  # 就地转换（默认只动 git 跟踪的文本文件）
    python tools/to_lf.py <路径> [<路径>…]  # 只处理指定文件

安全措施
--------
- 只处理扩展名在白名单里的文件；vcd/wdb/bit/ltx/pdf/xls 等二进制一律不碰。
- 一般文本文件检测到 BOM 会报告并去掉（UTF-8 BOM 会让某些工具把首行当注解）。
- ★ **例外：`.ps1` 必须保留 UTF-8 BOM**。本仓库的 `tools/*.ps1` 含中文，
  Windows PowerShell 5.1 读无 BOM 的 UTF-8 脚本会按 ANSI 代码页解码，
  中文字符被拆开后可能吃掉字符串收尾引号，导致脚本解析失败
  （2026-10-09 真踩过：13 台回归全 `NO-VERDICT`）。所以 `.ps1` 只统一换行符，
  缺 BOM 时还会**补上**；`--check` 会把"缺 BOM 的 .ps1"报成问题。
- `--check` 不写盘；**发现任何问题（CRLF / BOM / .ps1 缺 BOM）都 exit 1**，
  可直接当提交前关卡用。
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TEXT_EXT = {
    ".md", ".v", ".sv", ".py", ".ps1", ".tcl", ".xdc", ".txt",
    ".gitignore", ".gitattributes", ".json", ".yml", ".yaml", ".csv",
}
# 无扩展名但确定是文本的文件
TEXT_NAMES = {".gitignore", ".gitattributes"}

BOM = b"\xef\xbb\xbf"


def is_text_candidate(p: Path) -> bool:
    return p.suffix.lower() in TEXT_EXT or p.name in TEXT_NAMES


def tracked_files() -> list[Path]:
    # ★ 必须显式指定 utf-8：git 输出的是 UTF-8（本仓库有中文文件名），
    #   而 Windows 上 Python 的 text=True 默认按 ANSI 代码页（cp936/GBK）解码，
    #   遇到中文路径会抛 UnicodeDecodeError。
    out = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8")
    return [ROOT / name for name in out.split("\0") if name.strip()]


def convert(p: Path, check_only: bool) -> tuple[bool, bool, bool, bool]:
    """返回 (有 CRLF, 有 BOM, 已写盘, .ps1 缺 BOM)

    第 4 项对 .ps1 是**问题**（缺 BOM 会让 PowerShell 5.1 按 ANSI 解码中文而解析失败），
    对其它文件恒为 False。
    """
    raw = p.read_bytes()
    has_crlf = b"\r\n" in raw
    has_bom = raw.startswith(BOM)

    # ★★ .ps1 必须保留 UTF-8 BOM —— 绝不能和别的文本文件一起"去 BOM"
    # ------------------------------------------------------------------
    # 本仓库的 tools/*.ps1 含中文注释与中文字符串。Windows PowerShell 5.1
    # (powershell.exe) 读取**无 BOM** 的 UTF-8 脚本时按系统 ANSI 代码页解码，
    # 中文字符被拆开后有字节会吃掉字符串的收尾引号，脚本直接解析失败：
    #     At tools\run_sim.ps1:170 char:1
    #     + }
    #     + ~
    #     Unexpected token '}' in expression or statement.
    # 2026-10-09 这个坑真的踩过一次：13 台回归全跑不起来（SUMMARY 全 NO-VERDICT）。
    # 因此对 .ps1：只统一换行符，BOM 原样保留；缺 BOM 时**补上**。
    if p.suffix.lower() == ".ps1":
        ps1_no_bom = not has_bom
        if check_only:
            return has_crlf, False, False, ps1_no_bom
        body = raw[len(BOM):] if has_bom else raw
        body = body.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        if has_crlf or ps1_no_bom:
            p.write_bytes(BOM + body)
            return has_crlf, False, True, ps1_no_bom
        return False, False, False, False

    if check_only or not (has_crlf or has_bom):
        return has_crlf, has_bom, False, False
    body = raw[len(BOM):] if has_bom else raw
    body = body.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    p.write_bytes(body)
    return has_crlf, has_bom, True, False


def main(argv: list[str]) -> int:
    check_only = "--check" in argv
    explicit = [a for a in argv[1:] if not a.startswith("--")]
    if explicit:
        files = [Path(a) if Path(a).is_absolute() else ROOT / a for a in explicit]
    else:
        files = [f for f in tracked_files() if f.is_file() and is_text_candidate(f)]

    n_crlf = n_bom = n_written = n_ps1_no_bom = 0
    for p in files:
        if not p.is_file():
            print(f"[skip] {p}  (not found)")
            continue
        has_crlf, has_bom, written, ps1_no_bom = convert(p, check_only)
        if not (has_crlf or has_bom or ps1_no_bom):
            continue
        n_crlf += has_crlf
        n_bom += has_bom
        n_written += written
        n_ps1_no_bom += ps1_no_bom
        rel = p.relative_to(ROOT)
        tags = []
        if has_crlf:
            tags.append("CRLF")
        if has_bom:
            tags.append("BOM")
        if ps1_no_bom:
            tags.append("★ .ps1 缺 BOM（必须补回）")
        action = "已转 LF" if written else "待转 LF"
        print(f"[{'+' if written else ' '}] {rel}  ({', '.join(tags)}) -> {action}")

    if n_ps1_no_bom and check_only:
        print(f"\n★★ 有 {n_ps1_no_bom} 个 .ps1 缺 UTF-8 BOM —— PowerShell 5.1 会把中文"
              f"按 ANSI 解码并可能导致解析失败，请运行 `python tools/to_lf.py` 补回。")
    print(
        f"\n带 CRLF 的文件 {n_crlf} 个，带 BOM 的 {n_bom} 个，"
        f"缺 BOM 的 .ps1 文件 {n_ps1_no_bom} 个，"
        f"{'（--check 只报告，未写盘）' if check_only else f'实际转换 {n_written} 个'}"
    )
    # ★ --check 是给 CI / 提交前用的关卡：只要发现**任何**问题就必须非零退出，
    #   否则它在脚本里"看起来过了"却什么也没拦住。
    #   （2026-10-09 真踩过：只判了 .ps1 缺 BOM，于是带 CRLF 的文件报出来却仍 exit 0。）
    return 1 if (check_only and (n_crlf or n_bom or n_ps1_no_bom)) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
