#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scan_unused.py — 全仓扫描"声明了但从未被读"的信号（悬空/死信号）

背景
----
`rtl/enc_top.v` 里有一个 `wire unused_ok = &{...}` 汇聚列表，把一批"不参与逻辑、只
为压掉综合告警"的信号收集起来。它是**症状的收容所，不是诊断**：真正需要回答的是
"哪些信号从来没有被任何逻辑读过？它们是设计缺口还是有意留白？"

本脚本给出证据，不做判断：
  1. 解析 rtl/*.v，抽出每个模块的端口名 + 内部信号声明；
  2. 统计每个名字在**该文件全文**里的出现次数（词边界匹配）；
  3. 出现次数 == 1 的（只有声明那一处）⇒ 被声明却完全没用过；
  4. 在 enc_top.v 里再单独标出 `unused_ok` 汇聚列表里的每个信号，以及它除
     `unused_ok` 之外是否还有别的读者。

用法
----
    python tools/scan_unused.py                # 全仓 rtl/*.v
    python tools/scan_unused.py rtl/enc_top.v  # 只看某文件
    python tools/scan_unused.py --verbose      # 连"只当过左值"的也列出来
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 声明：wire/reg/logic/input/output/inout + 可选 signed + 位宽 + 名字列表
DECL_RE = re.compile(
    r"""^\s*
        (?:wire|reg|logic|input|output|inout)\b
        (?:\s+(?:wire|reg|logic|signed|unsigned))*   # 允许 signed/reg 等限定词
        (?:\s*\[[^\]]*\])?                            # 可选位宽
        \s+
        (?P<names>[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)
        \s*(?:;|=|,|\))                               # 结束于 ; = , 或端口表里的 )
        """,
    re.VERBOSE,
)

# 端口表里的 input/output（形如 ".port(sig)" 或 "input wire [3:0] a,"）
PORT_NAME_RE = re.compile(r"\b(?:input|output|inout)\b[^;]*?([A-Za-z_]\w*)\s*(?=[,;\)])")

# Verilog 关键字 / 常见非信号词，避免误报
KEYWORDS = {
    "module", "endmodule", "begin", "end", "if", "else", "case", "endcase",
    "default", "assign", "always", "posedge", "negedge", "wire", "reg",
    "logic", "input", "output", "inout", "signed", "unsigned", "parameter",
    "localparam", "generate", "endgenerate", "for", "while", "integer",
    "initial", "task", "endtask", "function", "endfunction", "return",
    "casez", "casex", "and", "or", "not", "xor", "nand", "nor", "xnor",
    "buf", "bufif0", "bufif1", "pullup", "pulldown", "specify", "endspecify",
    "defparam", "genvar", "forever", "repeat", "wait", "disable", "fork",
    "join", "join_any", "join_none", "automatic", "static", "real", "time",
    "realtime", "event", "string", "supply0", "supply1", "tri", "triand",
    "trior", "tri0", "tri1", "trireg", "wand", "wor", "scalared", "vectored",
}


def strip_comments(text: str) -> str:
    """去掉 // 与 /* */ 注释，避免注释里的词被当成引用"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", " ", text)
    # 去掉字符串字面量里的内容（$display("...") 里的词会污染计数）
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    return text


def declared_names(src: str) -> dict[str, int]:
    """返回 {名字: 声明所在行号}（同一名字多次声明只留第一次）"""
    names: dict[str, int] = {}
    for lineno, line in enumerate(src.splitlines(), 1):
        if not re.match(r"\s*(?:wire|reg|logic|input|output|inout)\b", line):
            continue
        m = DECL_RE.match(line)
        if not m:
            continue
        for nm in m.group("names").split(","):
            nm = nm.strip()
            if nm and nm not in KEYWORDS and nm not in names:
                names[nm] = lineno
    return names


def count_uses(src: str, name: str) -> int:
    """词边界统计出现次数"""
    return len(re.findall(rf"\b{re.escape(name)}\b", src))


def parse_unused_ok(src: str) -> list[str]:
    """把 enc_top.v 的 wire unused_ok = &{...}; 列表拆成名字清单"""
    m = re.search(r"wire\s+unused_ok\s*=\s*&\{(.*?)\};", src, re.DOTALL)
    if not m:
        return []
    body = m.group(1)
    # 去掉位选 [0] 与 1'b0 这类常量
    out: list[str] = []
    for tok in body.split(","):
        tok = tok.strip()
        if not tok or re.match(r"^\d*'[bhdoxB HDOX]", tok):
            continue
        tok = re.sub(r"\[[^\]]*\]$", "", tok).strip()
        if re.fullmatch(r"[A-Za-z_]\w*", tok):
            out.append(tok)
    return out


def main(argv: list[str]) -> int:
    verbose = "--verbose" in argv
    explicit = [a for a in argv[1:] if not a.startswith("--")]
    files = (
        [Path(a) if Path(a).is_absolute() else ROOT / a for a in explicit]
        if explicit
        else sorted((ROOT / "rtl").glob("*.v"))
    )

    total_dead = 0
    for p in files:
        if not p.is_file():
            print(f"[skip] {p} (not found)")
            continue
        raw = p.read_text(encoding="utf-8", errors="replace")
        src = strip_comments(raw)
        decls = declared_names(src)
        if not decls:
            continue
        dead = []
        lvalue_only = []
        for nm, line in sorted(decls.items(), key=lambda kv: kv[1]):
            if nm in KEYWORDS:
                continue
            n = count_uses(src, nm)
            if n <= 1:
                dead.append((nm, line))
            elif verbose and n == 2:
                # 声明 + 只出现一次别的引用 —— 通常是只被赋值的中间量
                lvalue_only.append((nm, line, n))
        rel = p.relative_to(ROOT)
        if dead:
            print(f"\n### {rel}:  {len(dead)} 个信号被声明但从未被引用")
            for nm, line in dead:
                print(f"    L{line:<5} {nm}")
            total_dead += len(dead)
        if verbose and lvalue_only:
            print(f"### {rel}:  {len(lvalue_only)} 个信号只被引用 1 次（多半只当过左值）")
            for nm, line, n in lvalue_only:
                print(f"    L{line:<5} {nm}  (uses={n})")

        # 对 enc_top.v 额外做 unused_ok 汇聚列表逐项报告
        if p.name == "enc_top.v":
            lst = parse_unused_ok(src)
            if lst:
                print(f"\n### {rel}: `wire unused_ok` 汇聚列表共 {len(lst)} 项")
                print(f"{'信号':<26}{'总引用':>6}{'除汇聚外':>9}  判定")
                print("-" * 72)
                for nm in lst:
                    n = count_uses(src, nm)
                    others = n - 1  # 减去 unused_ok 那一处
                    if others <= 0:
                        verdict = "★ 完全悬空：没有任何逻辑读者"
                    elif others == 1:
                        verdict = "只有 1 个读者（多半只是声明/赋值）"
                    else:
                        verdict = f"{others} 个读者"
                    print(f"{nm:<26}{n:>6}{others:>9}  {verdict}")

    print(f"\n合计：{total_dead} 个「声明但从未引用」的信号")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
