#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_citations.py —— 技能包里的"记录 N"引用必须真的能追到那一条记录

【为什么要这个脚本】
  2026-11-03 我抽查 `skill/` 发现自己写的 `src: 记录 2/7/12/...` 里有七处是凭印象
  填的号：号存在，但标题讲的是别的事（记录 2 是"工具真 bug 污染实验数据"，
  不是我写的 `>>>` 负数语义）。这正是 `skill/pitfalls.md` P-17 与 P-14 的组合：
  **看起来有出处，实际是把证据编号当装饰**。
  人工核了 86 条记录一次，但人工核过的东西不会自动保持正确——所以把它变成门禁。

【判据】
  ERROR  CITE-001  号在 `docs/ai-collaboration-log.md` 里不存在
  ERROR  CITE-002  号存在，但引用处（含行尾括注）没有出现标题里的任何实词
  WARN   CITE-003  引用处只有号、没有括注标题（能追，但读者要翻日志）
  WARN   CITE-004  同一文件里同一个号被引用超过 3 次（可能是在凑数）

  实词 = 标题里长度 ≥ 2 的连续汉字串或 ASCII 词，去掉高频虚词。
  判定 002 时把"引用所在行全文 + 前后各 1 行"一起看：写成
  `记录 42（另一个 hw_server 挡住烧录）` 或 `记录 42：烧录被另一个 hw_server 挡住`
  都能通过，写成 `记录 42` 却讲别的事会被抓出来（CITE-003 提醒补括注）。

【用法】
  python tools/check_citations.py                    # 扫 skill/**/*.md
  python tools/check_citations.py docs README.md     # 扫指定路径
  python tools/check_citations.py --list             # 打印 86 条记录的号与标题
  python tools/check_citations.py --strict           # WARN 也算失败

【退出码】0 = 无 ERROR（--strict 时无 WARN）；1 = 有不可追的引用；2 = 日志文件缺失

【失效条件】
  1) 它只证明"号与标题对得上"，不证明那句话的结论正确——结论要靠一手数据；
  2) 标题里若全是虚词（如"这件事"），实词集合为空，002 会退化成只查号；
  3) 换仓库时要改默认路径（docs/ai-collaboration-log.md 与 skill/）。
"""
from __future__ import annotations

import argparse
import collections
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / "docs" / "ai-collaboration-log.md"

# 标题分隔符有三种写法：全角冒号「：」、半角冒号/顿号/句点、以及全角空格 U+3000
# （日志里 73/77/85 条用的是全角空格；第一版把分隔符写进字符类，被 `\s*` 先吃掉，
#  这三条就被误判成"号不存在"。所以只认到数字，再 lstrip 掉分隔符。）
HEAD_RE = re.compile(r"^\s*(?:#{2,4}\s*|\*\*)\s*记录\s*(\d+)(?!\d)")
SEP = "：:、.　\t *"
CITE_RE = re.compile(r"记录\s*(\d+)")
STOP = set("""
的了是在和与也就都很这那一个上下来去把被对里没有会要可以为而是不之其或及等
""".strip())
ANNOT_RE = re.compile(r"记录\s*\d+\s*[（(]([^）)]{0,60})[）)]")


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def load_titles(path: Path) -> dict[int, str]:
    titles: dict[int, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = HEAD_RE.match(line)
        if not m:
            continue
        num = int(m.group(1))
        rest = line[m.end():].strip().lstrip(SEP).strip()
        titles[num] = rest
    return titles


KEEP_RE = re.compile(r"[0-9A-Za-z_]+|[\u4e00-\u9fff]+")


def norm(text: str) -> str:
    """去掉标点、空白与引号，只留汉字/字母/数字——这样"屏上的数字的保质期：…"
    和括注里手写的"屏上的数字的保质期"能对上（标点差异不该造成误报）。"""
    return "".join(KEEP_RE.findall(text))


def tokens(title: str) -> list[str]:
    """把标题切成可比较的 3-gram：ASCII 词整词，汉字串取长度 3 的滑窗。

    用 3-gram 而不是"整串实词"，是因为断词边界不可靠（"三条"看起来 PASS"其实没测到"…"
    里的引号会把一句话切成碎片），3 个字的重叠窗口足够区分"讲同一件事"与"讲别的事"。
    """
    out: list[str] = []
    for piece in KEEP_RE.findall(title):
        if piece.isascii():
            if len(piece) >= 3:
                out.append(piece.lower())
        elif len(piece) <= 3:
            out.append(piece)
        else:
            out.extend(piece[i:i + 3] for i in range(len(piece) - 2))
    return [t for t in dict.fromkeys(out)]


def scan_file(path: Path, titles: dict[int, str]):
    issues: list[tuple[str, str, Path, int, str]] = []
    counts: collections.Counter[int] = collections.Counter()
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for i, line in enumerate(lines):
        for m in CITE_RE.finditer(line):
            num = int(m.group(1))
            counts[num] += 1
            if num not in titles:
                issues.append(("ERROR", "CITE-001", path, i + 1,
                               f"记录 {num} 在日志里不存在"))
                continue
            window = norm("\n".join(lines[max(0, i - 1): i + 2])).lower()
            toks = tokens(titles[num])
            hit = [t for t in toks if t in window]
            ann = ANNOT_RE.search(line)
            if not hit and not ann:
                # 只有一个光号码、上下文里又找不到标题里的任何词 —— 这正是我
                # 2026-11-03 犯的那个错（"src: 记录 2"，而记录 2 讲的是别的事）。
                issues.append(("WARN", "CITE-002", path, i + 1,
                               f"记录 {num}（{titles[num][:24]}）既没括注、上下文也无线索"))
            elif not hit:
                # 有括注但措辞是改写 —— 机器判不了对错，交给人；提示级不算失败。
                issues.append(("INFO", "CITE-002", path, i + 1,
                               f"记录 {num}（{titles[num][:24]}）的括注是改写，请人工确认语义"))
            elif not ann:
                issues.append(("INFO", "CITE-003", path, i + 1,
                               f"记录 {num} 没有括注标题（建议写成 记录 {num}（{titles[num][:16]}））"))
    for num, cnt in counts.items():
        if cnt > 3:
            issues.append(("WARN", "CITE-004", path, 0,
                           f"记录 {num} 这个文件里引用了 {cnt} 次"))
    return issues


def iter_md(paths: list[str]):
    for p in paths:
        base = ROOT / p if not Path(p).is_absolute() else Path(p)
        if base.is_file() and base.suffix.lower() == ".md":
            yield base
            continue
        if base.is_dir():
            for f in sorted(base.rglob("*.md")):
                yield f


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="校验 记录 N 引用是否可追")
    ap.add_argument("paths", nargs="*", default=["skill"], help="要扫的目录或 md 文件（默认 skill）")
    ap.add_argument("--list", action="store_true", help="只打印日志里的记录号与标题")
    ap.add_argument("--strict", action="store_true", help="WARN 也算失败")
    args = ap.parse_args(argv)

    if not LOG.is_file():
        print(f"[EXIT2] 找不到记录日志: {LOG}", file=sys.stderr)
        return 2
    titles = load_titles(LOG)
    if not titles:
        print(f"[EXIT2] {LOG} 里没解析出任何 `记录 N：` 标题", file=sys.stderr)
        return 2

    if args.list:
        for num in sorted(titles):
            print(f"{num:3d}  {titles[num]}")
        print(f"\n共 {len(titles)} 条")
        return 0

    files = list(iter_md(args.paths))
    if not files:
        print(f"[EXIT2] {args.paths} 下没有 md 文件", file=sys.stderr)
        return 2

    issues: list[tuple[str, str, Path, int, str]] = []
    cited: set[int] = set()
    for f in files:
        for it in scan_file(f, titles):
            issues.append(it)
            if it[1] in ("CITE-001", "CITE-002", "CITE-003"):
                cited.add(int(re.search(r"记录 (\d+)", it[4]).group(1)))

    errors = [i for i in issues if i[0] == "ERROR"]
    warns = [i for i in issues if i[0] == "WARN"]
    infos = [i for i in issues if i[0] == "INFO"]
    order = {"ERROR": 0, "WARN": 1, "INFO": 2}
    for level, code, path, line, msg in sorted(issues, key=lambda t: (order[t[0]], t[1], str(t[2]), t[3])):
        rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
        loc = f"{rel}:{line}" if line else str(rel)
        print(f"[{level}] {code} {loc}  {msg}")

    print(f"\n扫描 {len(files)} 个 Markdown，日志 {len(titles)} 条记录，"
          f"引用到 {len(cited)} 条；ERROR {len(errors)}、WARN {len(warns)}、INFO {len(infos)}")
    if errors:
        print("=> FAIL：有引用追不到那一条记录")
        return 1
    if warns and args.strict:
        print("=> FAIL（--strict）：有引用的标题与上下文对不上，或同号被反复引用")
        return 1
    print("=> PASS：每个 记录 N 都能追到日志里的那一条")
    return 0


if __name__ == "__main__":
    sys.exit(main())
