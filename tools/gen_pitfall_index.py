#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成/校验两份踩坑清单的「症状索引」。

【适用】`skill/pitfalls.md`（18 条，RTL/仿真/约束/协作/测量）与
        `skill/pynq/pitfalls_pynq.md`（14 条，.hwh/Overlay/DMA/板卡）改过之后。
【用法】
    python tools/gen_pitfall_index.py            # 重新生成 skill/pitfalls_index.md
    python tools/gen_pitfall_index.py --check    # 只校验生成物是否与清单一致（CI 用）
    python tools/gen_pitfall_index.py --check -v # 不一致时打印差异行
【退出码】0 一致/已生成；1 --check 发现漂移；2 找不到清单或解析不出条目

【为什么要有这个脚本】
`skill/README.md` §4 的症状索引是手抄的：改了清单正文忘了改索引，就变成
"索引指向一条已经改写的坑"。本仓库已经因为同类问题吃过两次教训——
记录 77（屏上数字的保质期：手抄常量与生成物脱钩）与记录 85（常量对、注释旧）。
把索引改成生成物之后，"清单改了索引没改"变成一条 `--check` 就能抓住的漂移。

【已知局限】
1) 只解析"`###` 小标题 + 粗体字段"这一种格式；换格式要同时改这里的 FIELD_RE。
2) 症状列取"现象"字段的第一句；现象写得含糊，索引也就含糊——这是清单本身的问题，
   不是脚本能修的（索引不给清单补内容）。
3) 不检查 `src` 里的记录号是否真实存在——那是 `tools/check_citations.py` 的活。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "skill" / "pitfalls_index.md"

SOURCES = [
    ("RTL / 仿真 / 约束 / 协作 / 测量", ROOT / "skill" / "pitfalls.md", "P-", "pitfalls.md"),
    ("PYNQ（.hwh / Overlay / DMA / 板卡）", ROOT / "skill" / "pynq" / "pitfalls_pynq.md", "PYNQ-",
     "pynq/pitfalls_pynq.md"),
]
HEAD_RE = re.compile(r"^###\s+((?:PYNQ-)?P(?:YNQ)?-\d+|PYNQ-\d+|P-\d+)\s+(.+?)\s*$")
# 两种写法都认：`**触发**：…` 与 `- **触发**：…`
FIELD_RE = re.compile(r"^\s*(?:-\s+)?\*\*(触发|现象|排查|根因|修法|验证|失效)\*\*\s*[：:]\s*(.*)$")
CODE_RE = re.compile(r"`([^`]+)`")


def parse(path: Path) -> list[dict]:
    """把一份清单切成 [{id, title, symptom, cmd, src}]。"""
    if not path.is_file():
        raise SystemExit(f"[EXIT2] 找不到 {path}")
    items: list[dict] = []
    cur: dict | None = None
    field: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        m = HEAD_RE.match(line)
        if m:
            if cur:
                items.append(cur)
            cur = {"id": m.group(1), "title": m.group(2).strip(), "fields": {}, "src": ""}
            field = None
            continue
        if cur is None:
            continue
        if line.startswith("**src**"):
            cur["src"] = line.split(":", 1)[-1].strip() if ":" in line else line
            field = None
            continue
        m = FIELD_RE.match(line)
        if m:
            field = m.group(1)
            cur["fields"][field] = m.group(2).strip()
            continue
        if field and line and not line.startswith("#"):
            # 字段的续行（排查里常是代码块或多行说明）
            cur["fields"][field] += " " + line.strip()
    if cur:
        items.append(cur)
    return items


def _first_sentence(text: str) -> str:
    text = re.sub(r"^```.*?```", "", text, flags=re.S).strip()
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return "（清单里没写现象——这条本身该补）"
    m = re.split(r"[。；]", text, maxsplit=1)
    out = m[0].strip()
    return out if len(out) <= 48 else out[:46] + "…"


def _first_command(text: str) -> str | None:
    """从"排查"字段里找第一条能照抄的命令；找不到返回 None。

    注意：解析时字段的续行是用空格拼起来的，所以代码块可能是
    "```bat python … ```" 这种被压平的形式——两种都要认。
    """
    m = re.search(r"```[a-zA-Z]*\s*(.+?)\s*```", text, flags=re.S)
    if m:
        for ln in m.group(1).splitlines():
            ln = ln.strip().strip("`").strip()
            if ln and not ln.startswith("#"):
                return ln
    m = CODE_RE.search(text)
    if m:
        cand = m.group(1).strip()
        if cand and not cand.startswith("```"):
            return cand
    return None


def build(index_source: list[tuple[str, list[dict], str]]) -> str:
    lines: list[str] = []
    lines.append("# 踩坑症状索引（生成物，不要手改）")
    lines.append("")
    lines.append("由 `python tools/gen_pitfall_index.py` 从两份清单生成：")
    lines.append("`skill/pitfalls.md`（RTL 那套，18 条）与 `skill/pynq/pitfalls_pynq.md`（PYNQ 那套，14 条）。")
    lines.append("改清单后跑一次生成，或跑 `--check` 看有没有漂移（`skill/scripts/run_all_checks.py` 已包含）。")
    lines.append("")
    lines.append("用法：先按『你看到的症状』在这一页找到编号，再跳回清单读完整条目"
                 "（触发/排查/根因/修法/回归/失效都在那边）。")
    lines.append("")
    total = 0
    for group, items, href in index_source:
        lines.append(f"## {group}（{len(items)} 条）")
        lines.append("")
        lines.append("| 编号 | 症状 | 先跑这条 |")
        lines.append("|---|---|---|")
        for it in items:
            sym = _first_sentence(it["fields"].get("现象", ""))
            probe = _first_command(it["fields"].get("排查", ""))
            if probe:
                cell = f"`{probe}`"
            else:
                alt = _first_command(it["fields"].get("修法", ""))
                cell = f"（没有单条命令；修法里是 `{alt}`）" if alt else "（清单里没给命令——读『根因』那行）"
            cell = cell.replace("|", "\\|")
            sym = sym.replace("|", "\\|")
            lines.append(f"| [{it['id']}]({href}#{it['id'].lower()}) | {sym} | {cell} |")
        lines.append("")
        total += len(items)
    lines.append(f"共 {total} 条。编号 `P-xx` 见 `skill/pitfalls.md`，`PYNQ-xx` 见 `skill/pynq/pitfalls_pynq.md`。")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass

    ap = argparse.ArgumentParser(description="生成/校验踩坑清单的症状索引")
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    parsed = []
    for group, path, prefix, href in SOURCES:
        items = [it for it in parse(path) if it["id"].startswith(prefix)]
        if not items:
            print(f"[EXIT2] {path} 里没解析出 {prefix}xx 条目（格式变了？）")
            return 2
        parsed.append((group, items, href))

    text = build(parsed)
    counts = "，".join(f"{g.split('（')[0]} {len(i)} 条" for g, i, _ in parsed)

    if args.check:
        if not OUT.is_file():
            print(f"[FAIL] {OUT} 不存在：跑一次 `python tools/gen_pitfall_index.py`")
            return 1
        old = OUT.read_text(encoding="utf-8")
        if old == text:
            print(f"=> PASS：索引与清单一致（{counts}）")
            return 0
        print("[FAIL] 索引与清单不一致——清单改了但没重新生成")
        if args.verbose:
            import difflib
            diff = list(difflib.unified_diff(old.splitlines(), text.splitlines(),
                                             "磁盘上的索引", "按清单重新生成", lineterm="", n=1))
            for ln in diff[:40]:
                print("  " + ln)
        print("  修法：`python tools/gen_pitfall_index.py`")
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"已写 {OUT}（{counts}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
