#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/check_links.py —— 检查 Markdown 里的相对链接是否可达。

用法：
    python tools/check_links.py            # 检查仓库内全部 .md
    python tools/check_links.py README.md docs/README.md

规则：
  * 只看相对链接/图片；http(s)、mailto、纯锚点跳过；
  * 忽略代码块（``` 围栏）里的示例链接；
  * 去掉 `#anchor` 与 `?query`，做 URL 解码；
  * 目录链接只要求目录存在；
  * 任一目标不存在 → 非零退出，并打印 文件:行号: 目标。

为什么需要它：文档互相引用很多，改文件名最容易留下死链；CI 里跑一次，
比人工点几百个链接可靠。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
SKIP_PREFIX = ("http://", "https://", "mailto:", "tel:", "#", "data:")
SKIP_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf", ".docx", ".xlsx",
    ".pptx", ".zip", ".rar", ".7z", ".bit", ".bin", ".npy", ".csv", ".wdb",
}


def md_files(argv: list[str]) -> list[str]:
    if argv:
        return [os.path.abspath(a) for a in argv]
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "-co", "--exclude-standard", "*.md"],
            cwd=ROOT,
            stderr=subprocess.DEVNULL,  # 导出的 tarball 里没有 .git，别把 git 的抱怨当成本工具的结论
        )
        names = out.decode("utf-8", "replace").splitlines()
        return [os.path.join(ROOT, n) for n in names if n.strip()]
    except Exception:
        found = []
        for base, _dirs, files in os.walk(ROOT):
            if ".git" in base.split(os.sep):
                continue
            for f in files:
                if f.endswith(".md"):
                    found.append(os.path.join(base, f))
        return found


def clean_target(raw: str) -> str:
    t = raw.strip()
    if t.startswith("<") and ">" in t:
        t = t[1:t.index(">")]
    else:
        t = t.split()[0] if t.split() else t
    t = t.split("#", 1)[0].split("?", 1)[0]
    return unquote(t)


def check(path: str) -> list[tuple[int, str]]:
    bad = []
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return [(0, f"无法读取: {e}")]
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in LINK_RE.finditer(line):
            raw = m.group(1).strip()
            if not raw or raw.startswith(SKIP_PREFIX):
                continue
            target = clean_target(raw)
            if not target:
                continue
            if os.path.isabs(target) or re.match(r"^[A-Za-z]:[\\/]", target):
                bad.append((lineno, f"绝对路径链接: {target}"))
                continue
            target = target.replace("\\", "/")
            full = os.path.normpath(os.path.join(os.path.dirname(path), target))
            if not os.path.exists(full):
                bad.append((lineno, f"目标不存在: {target}"))
    return bad


def main() -> int:
    files = md_files(sys.argv[1:])
    total = 0
    fail = 0
    for f in files:
        total += 1
        for lineno, msg in check(f):
            fail += 1
            rel = os.path.relpath(f, ROOT)
            print(f"{rel}:{lineno}: {msg}")
    print(f"[links] 检查 {total} 个 Markdown，问题 {fail} 条")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
