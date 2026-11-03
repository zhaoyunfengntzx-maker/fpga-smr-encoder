#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tools/check_anonymity.py —— 发布前的匿名性与路径卫生检查。

背景：比赛要求提交物不含学校、姓名、学号、指导教师等信息；仓库还要能被
别人 clone 后直接构建，因此正文里不应出现作者机器的绝对路径。

用法：
    python tools/check_anonymity.py                 # 全仓库扫描，只报告
    python tools/check_anonymity.py --strict-new    # 只扫新增的公开面，有命中即失败（CI 用）
    python tools/check_anonymity.py --fail          # 全仓库扫描，有命中即失败

检查项：
  1. 个人绝对路径：C:\\Users\\<name>、/home/<name>（构建脚本、日志、文档）
  2. 邮箱地址（排除 example.com、localhost、noreply）
  3. 身份词：学号、指导教师/指导老师、校徽、学校名（"全国大学生…"竞赛名除外）
  4. 非 ASCII 文件名（指南要求仓库路径全英文）

说明：历史开发日志（docs/DEV_STATUS.md、docs/ai-collaboration-log.md）保留
过程记录，默认只报告不阻断；--strict-new 只覆盖本次发布新增/改写的公开文件。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TEXT_EXT = {
    ".md", ".txt", ".py", ".tcl", ".ps1", ".v", ".sv", ".vh", ".c", ".h",
    ".cpp", ".json", ".yml", ".yaml", ".cff", ".csv", ".bat", ".sh", ".gitignore",
    ".gitattributes", ".cfg", ".ini", ".toml", ".rpt", ".log", ".xdc", ".do",
}

PATH_RE = re.compile(r"(?:[A-Za-z]:[\\/]Users[\\/][^\\/\s\"'<>]+|/home/[^/\s\"'<>]+)")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
IDENT_RE = re.compile(r"学号|指导教师|指导老师|校徽|学院|大学(?!生)")
EMAIL_ALLOW = ("example.com", "example.org", "localhost", "users.noreply.github.com",
               "your-org")

# 本次发布新增/改写的公开面
STRICT_FILES = [
    "README.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CODE_OF_CONDUCT.md",
    "CHANGELOG.md",
    "CITATION.cff",
    "docs/README.md",
    "docs/REPRODUCE.md",
    "docs/BASELINES.md",
    "docs/release_notes_v1.0.0.md",
    "host/requirements.txt",
    "tools/check_links.py",
    "tools/check_anonymity.py",
    ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/ISSUE_TEMPLATE/bug_report.yml",
    ".github/ISSUE_TEMPLATE/feature_request.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/workflows/ci.yml",
]


def tracked() -> list[str]:
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT
        )
        return [n for n in out.decode("utf-8", "replace").splitlines() if n]
    except Exception:
        found = []
        for base, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in dirs if d != ".git"]
            for f in files:
                found.append(os.path.relpath(os.path.join(base, f), ROOT))
        return found


def scan(rel: str) -> list[str]:
    hits = []
    ext = os.path.splitext(rel)[1].lower()
    if ext not in TEXT_EXT and os.path.basename(rel) not in (".gitignore", ".gitattributes"):
        return hits
    path = os.path.join(ROOT, rel)
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return hits
    for m in PATH_RE.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        hits.append(f"{rel}:{line}: 个人绝对路径 {m.group(0)}")
    for m in EMAIL_RE.finditer(text):
        addr = m.group(0)
        if any(a in addr for a in EMAIL_ALLOW):
            continue
        line = text.count("\n", 0, m.start()) + 1
        hits.append(f"{rel}:{line}: 邮箱 {addr}")
    for m in IDENT_RE.finditer(text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        line = text[line_start:text.find("\n", m.start()) if text.find("\n", m.start()) >= 0 else len(text)]
        # 说明性文字（"不含/匿名/禁止/脱敏/身份信息"）不是泄露，跳过
        if any(w in line for w in ("匿名", "不含", "禁止", "脱敏", "去除", "不得出现",
                                   "身份信息", "学校", "姓名", "私人信息")):
            continue
        lineno = text.count("\n", 0, m.start()) + 1
        hits.append(f"{rel}:{lineno}: 身份词 “{m.group(0)}”")
    return hits


def non_ascii_names(files: list[str]) -> list[str]:
    bad = []
    for f in files:
        if any(ord(ch) > 127 for ch in f):
            bad.append(f)
    return bad


def main() -> int:
    args = set(sys.argv[1:])
    strict = "--strict-new" in args
    fail = strict or "--fail" in args
    files = tracked()
    if strict:
        files = [f for f in files if f.replace("\\", "/") in STRICT_FILES]
        missing = [f for f in STRICT_FILES if f not in {x.replace("\\", "/") for x in files}]
        for m in missing:
            print(f"[anonymity] 注意：公开面文件不存在 {m}")
    hits: list[str] = []
    for f in files:
        if f.replace("\\", "/") == "tools/check_anonymity.py":
            continue  # 检查器自身的正则源码不算泄露
        hits.extend(scan(f))
    tracked_names = subprocess.check_output(["git", "ls-files"], cwd=ROOT).decode(
        "utf-8", "replace").splitlines()
    bad_names = non_ascii_names([f for f in tracked_names if f.strip()])
    for f in bad_names:
        hits.append(f"{f}: 非 ASCII 文件名（比赛要求全英文）")

    for h in hits:
        print(h)
    scope = f"严格公开面 {len(files)} 个文件" if strict else f"全仓库 {len(files)} 个文本文件"
    print(f"[anonymity] 扫描{scope}，命中 {len(hits)} 条")
    if strict and not hits:
        print("[anonymity] 通过")
    return 1 if (fail and hits) else 0


if __name__ == "__main__":
    sys.exit(main())
