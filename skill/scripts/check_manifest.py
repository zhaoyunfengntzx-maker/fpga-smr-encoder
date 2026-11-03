#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_manifest.py —— 交付包哈希清单：生成 / 校验，回答"我交的和跑出结论的是同一份吗"

【适用】任何要交付或要复现的目录：源码包、综合报告目录、数据集、位流归档。
        评审最容易问的一句是"这版报告是不是这版代码跑出来的"——哈希清单是唯一硬证据。

【用法】
    # 1) 生成（默认写 <dir>/SHA256SUMS.txt，覆盖旧的）
    python check_manifest.py --dir _synth_work --write

    # 2) 校验（换机器 / 换人 / 过一段时间后都能查）
    python check_manifest.py --dir _synth_work --verify

    # 3) 清单外多出文件也算失败（严格模式，适合"提交前最后一查"）
    python check_manifest.py --dir deliverables --verify --strict

    # 4) 排除构建垃圾与备份，别让它们污染清单
    python check_manifest.py --dir . --write --exclude .git --exclude __pycache__ --exclude _bak

【格式】与 sha256sum 兼容的文本：`<64 位小写十六进制><空格><相对路径>`
        （也接受 `hash *path` 这种二进制模式写法，Windows 上 TortoiseGit 会这么写）。
        行序按路径字典序，保证同内容必定同清单字节 → 清单本身可进 git 且不会无故变化。

【退出码】0 = 全部一致；1 = 有缺失 / 被改动 / （严格模式下）有清单外文件；2 = 清单缺失或格式坏

【为什么要有这个脚本】
  本工程 v74 复盘时发现：报告里的数字与 `_synth_work` 里同名报告的版本对不上，
  原因是中途重跑过一次 impl，旧目录没删，报告被引用了旧的那份（见 pitfalls 第 17 条）。
  "文件名相同"不代表"内容相同"；只有哈希能证明。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys

CHUNK = 1 << 20
LINE = re.compile(r"^([0-9a-fA-F]{64})[ \t]+\*?(.+?)\s*$")


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def iter_files(root: str, excludes: list[str], manifest_name: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames
                             if not any(x in d for x in excludes))
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace("\\", "/")
            if rel == manifest_name or any(x in rel for x in excludes):
                continue
            yield rel, full


def do_write(args) -> int:
    root = os.path.abspath(args.dir)
    manifest_path = os.path.join(root, args.file)
    lines = []
    for rel, full in iter_files(root, args.exclude, args.file):
        lines.append(f"{sha256_of(full)}  {rel}")
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    print(f"写入 {manifest_path}：{len(lines)} 个文件")
    for line in lines[: args.show]:
        print(f"  {line}")
    if len(lines) > args.show:
        print(f"  …（其余 {len(lines) - args.show} 条略）")
    return 0


def do_verify(args) -> int:
    root = os.path.abspath(args.dir)
    manifest_path = os.path.join(root, args.file)
    if not os.path.isfile(manifest_path):
        print(f"[ERROR] 找不到清单 {manifest_path}（先跑 --write）", file=sys.stderr)
        return 2

    entries: dict[str, str] = {}
    bad_lines = 0
    with open(manifest_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            m = LINE.match(s)
            if not m:
                bad_lines += 1
                continue
            entries[m.group(2).replace("\\", "/")] = m.group(1).lower()

    if not entries:
        print(f"[ERROR] 清单里没有可解析的行（{manifest_path}）", file=sys.stderr)
        return 2

    ok, missing, mismatch = 0, [], []
    for rel, want in entries.items():
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            missing.append(rel)
            continue
        got = sha256_of(full)
        if got == want:
            ok += 1
        else:
            mismatch.append((rel, want, got))

    listed = set(entries)
    extra = [rel for rel, _ in iter_files(root, args.exclude, args.file)
             if rel not in listed]

    print(f"清单: {manifest_path}")
    print(f"条目: {len(entries)}  OK: {ok}  缺失: {len(missing)}  被改动: {len(mismatch)}  "
          f"清单外: {len(extra)}")
    for rel in missing[: args.show]:
        print(f"  [MISSING] {rel}")
    for rel, want, got in mismatch[: args.show]:
        print(f"  [CHANGED] {rel}\n            期望 {want[:16]}…  实际 {got[:16]}…")
    for rel in extra[: args.show]:
        print(f"  [EXTRA]   {rel}")
    if bad_lines:
        print(f"  [WARN] {bad_lines} 行格式不认识（已跳过）")

    failed = bool(missing or mismatch) or (args.strict and bool(extra))
    print("\nPASS: 清单与目录一致" if not failed else "\nFAIL: 目录内容与清单不一致")
    return 0 if not failed else 1


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="SHA256 清单：生成与校验")
    ap.add_argument("--dir", default=".", help="目标目录（默认当前目录）")
    ap.add_argument("--file", default="SHA256SUMS.txt", help="清单文件名")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true", help="生成清单")
    g.add_argument("--verify", action="store_true", help="校验清单")
    ap.add_argument("--exclude", action="append", default=[],
                    help="路径/目录名包含该子串就跳过（可重复）")
    ap.add_argument("--strict", action="store_true",
                    help="校验时把'清单外多出的文件'也算失败")
    ap.add_argument("--show", type=int, default=10, help="每类最多打印几条（默认 10）")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.dir):
        print(f"[ERROR] 目录不存在: {args.dir}", file=sys.stderr)
        return 2
    return do_write(args) if args.write else do_verify(args)


if __name__ == "__main__":
    sys.exit(main())
