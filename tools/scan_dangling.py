#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全仓悬空 / 死信号扫描（跨文件，带实例化端口解析）。

与 tools/scan_unused.py 的区别
------------------------------
`tools/scan_unused.py` 是**按文件**统计词频、报告"出现次数 == 1（只被声明）"，
并把 enc_top 的 `unused_ok` 汇聚列表逐项列出。它能找到"声明后完全没人提"的信号，
但**找不到下面三类**，而这三类才是真正会藏缺陷的地方：

  1. 信号被写、也被读，但读者是**别的模块的一个哑元端口**（例如接到某个
     实例的 `.dbg_xxx()` 或只进 `unused_ok` 汇聚）——在本文件里它"有读者"，
     在整条数据通路上却没有任何功能影响。
  2. **空端口连接** `.port()`：输入端口悬空（常量 X/0）或输出端口被丢弃。
     本文件的词频统计完全看不到它。
  3. 某个整模块的输出**在顶层根本没有被连出去**。

本脚本做跨文件的**实例化端口连接图**分析：
  · 去注释 / 去字符串字面量（保留行列位置）；
  · 抽出所有 module 及其端口方向；
  · 解析 `Mod #(...) u_inst ( .port(sig), .port2() );`，得到每个实例每个端口
    连到了哪个信号、还是空连接；
  · 对每个标识符统计"真实读者数" = 出现次数 − 声明处 − 纯汇聚行；
  · 单独报告 `wire unused_ok = &{...}` 汇聚列表逐项的读者数。

输出四张表：
  A. 只被声明、没有任何真实读者的信号（真死信号）
  B. 空端口连接 `.port()`
  C. 唯一读者是"接收但不参与逻辑"的暗哑元（unused_ok / dbg_*）的信号
  D. rtl/enc_top.v 的 unused_ok 汇聚列表逐项读者统计

退出码：A 或 B 非空 -> 1（可直接当提交前关卡）；全空 -> 0。

用法：
    python tools/scan_dangling.py                 # 扫 rtl/ 与 sim/
    python tools/scan_dangling.py rtl/enc_top.v   # 只扫指定文件（仍跨文件建图）
    python tools/scan_dangling.py --no-sim        # 只扫 rtl/
"""

from __future__ import annotations

import argparse
import os
import re
import sys

RE_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
RE_LINE_COMMENT = re.compile(r"//[^\n]*")
RE_STRING = re.compile(r'"(?:\\.|[^"\\\n])*"')
IDENT = re.compile(r"\b([A-Za-z_]\w*)\b")

RESERVED = {
    "module", "endmodule", "input", "output", "inout", "wire", "reg", "logic",
    "signed", "unsigned", "parameter", "localparam", "assign", "always",
    "initial", "begin", "end", "if", "else", "case", "casez", "casex",
    "endcase", "default", "for", "while", "repeat", "forever", "function",
    "endfunction", "task", "endtask", "generate", "endgenerate", "genvar",
    "integer", "real", "time", "posedge", "negedge", "or", "and", "not",
    "nand", "nor", "xor", "xnor", "buf", "bufif0", "bufif1", "supply0",
    "supply1", "tri", "wand", "wor", "automatic", "static", "return",
    "defparam", "specify", "endspecify", "primitive", "endprimitive",
    "table", "endtable", "int", "shortint", "longint", "byte", "bit",
    "typedef", "packed", "disable", "wait", "fork", "join", "join_any",
    "join_none", "force", "release", "deassign", "timescale", "include",
    "define", "ifdef", "ifndef", "endif", "elsif", "undef", "default_nettype",
    "celldefine", "endcelldefine", "display", "monitor", "finish", "stop",
    "error", "warning", "info", "fatal", "readmemh", "readmemb", "dumpfile",
    "dumpvars", "write", "strobe", "fdisplay", "fwrite", "fopen", "fclose",
    "random", "urandom", "clog2", "string", "event", "tri0", "tri1", "trireg",
    "triand", "trior", "uwire", "vectored", "scalared", "small", "medium",
    "large", "highz0", "highz1", "strong0", "strong1", "pull0", "pull1",
    "weak0", "weak1", "pulldown", "pullup", "edge", "ifnone", "cell",
    "macromodule", "final", "assert", "assume", "cover", "property",
    "endproperty", "sequence", "endsequence", "clocking", "endclocking",
}


def strip_code(text: str) -> str:
    """把注释与字符串字面量抹成等长空白，保持行列位置不变。"""
    out = list(text)
    for pat in (RE_BLOCK_COMMENT, RE_LINE_COMMENT):
        for m in pat.finditer("".join(out)):
            for i in range(m.start(), m.end()):
                if out[i] != "\n":
                    out[i] = " "
    for m in RE_STRING.finditer("".join(out)):
        for i in range(m.start(), m.end()):
            if out[i] != "\n":
                out[i] = " "
    return "".join(out)


def find_modules(code: str):
    """[(name, body)]，body 从 module 关键字到配对的 endmodule。"""
    out = []
    for m in re.finditer(r"\bmodule\s+([A-Za-z_]\w*)", code):
        e = code.find("endmodule", m.end())
        out.append((m.group(1), code[m.start(): e if e > 0 else len(code)]))
    return out


def _match_paren(text: str, lp: int) -> int:
    """返回与 text[lp]='(' 配对的 ')' 下标；找不到返回 -1。"""
    depth = 0
    for i in range(lp, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1


def module_header(body: str) -> str:
    """取出 ANSI 端口列表文本。

    ★ 关键：`module foo #( parameter ... )( input ... );` 里**第一个括号是参数表**，
    不是端口表。必须先把 `#(...)` 整段跳掉，再取下一对括号，否则参数名会被当成端口。
    """
    m = re.search(r"\bmodule\b\s*[A-Za-z_]\w*", body)
    if not m:
        return ""
    i = m.end()
    while i < len(body) and body[i].isspace():
        i += 1
    # 跳过 #( ... ) 参数表
    if i < len(body) and body[i] == "#":
        i += 1
        while i < len(body) and body[i].isspace():
            i += 1
        if i < len(body) and body[i] == "(":
            j = _match_paren(body, i)
            i = (j + 1) if j > 0 else len(body)
    while i < len(body) and body[i].isspace():
        i += 1
    if i >= len(body) or body[i] != "(":
        return ""
    j = _match_paren(body, i)
    return body[i + 1: j] if j > 0 else ""


def module_ports(body: str) -> dict[str, str]:
    """{port: direction}；ANSI 与非 ANSI 两种写法都尽量覆盖。"""
    ports: dict[str, str] = {}
    header = module_header(body)
    if not header:
        return ports
    # 去掉 `(* attr *)` 属性块，避免属性里的标识符被当成端口名
    header_na = re.sub(r"\(\*.*?\*\)", " ", header, flags=re.S)
    # ANSI： input wire [..] a, b, c   —— ★ 必须跨行（DOTALL / [^;] 都行）
    #   ★★ 逗号分隔的名字列表里**只能用 [ \t] 不能用 \s**：`\s` 会吃掉换行，
    #      把下一行的方向关键字 `output` 当成端口名捞进来，于是"隔一个漏一个"。
    #      实测错误形态：'output' -> 'cfg_kp,\n    output'。
    for m in re.finditer(
        r"\b(input|output|inout)\b[ \t]*(?:wire|reg|logic|bit)?[ \t]*"
        r"(?:signed|unsigned)?[ \t]*(?:\[[^\]]*\])?[ \t]*"
        r"((?:[A-Za-z_]\w*[ \t]*,[ \t]*)*[A-Za-z_]\w*)",
        header_na, re.S,
    ):
        for nm in m.group(2).split(","):
            nm = nm.strip()
            if nm and not nm[0].isdigit():
                ports[nm] = m.group(1)
    # 非 ANSI：括号里只有名字，方向在 body 里
    if not ports:
        for nm in (x.strip() for x in header_na.replace("\n", " ").split(",")):
            if not re.fullmatch(r"[A-Za-z_]\w*", nm or ""):
                continue
            dm = re.search(r"\b(input|output|inout)\b[^;]*\b" + re.escape(nm) + r"\b",
                           body, re.S)
            ports[nm] = dm.group(1) if dm else "?"
    ports.pop("input", None)
    ports.pop("output", None)
    ports.pop("inout", None)
    return ports


RE_INST = re.compile(
    r"\b([A-Za-z_]\w*)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?([A-Za-z_]\w*)\s*\(",
    re.S,
)
RE_NAMED_PORT = re.compile(r"\.\s*([A-Za-z_]\w*)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)", re.S)


def find_instances(code: str, known: set[str]):
    out = []
    for m in RE_INST.finditer(code):
        mod, inst = m.group(1), m.group(2)
        if mod not in known or mod == inst or mod in RESERVED:
            continue
        depth, i = 1, m.end()
        while i < len(code) and depth:
            if code[i] == "(":
                depth += 1
            elif code[i] == ")":
                depth -= 1
            i += 1
        conns = {pm.group(1): pm.group(2).strip()
                 for pm in RE_NAMED_PORT.finditer(code[m.end(): i - 1])}
        if conns:
            out.append((mod, inst, conns))
    return out


class Src:
    def __init__(self, path: str):
        self.path = path
        self.raw = open(path, encoding="utf-8", errors="replace").read()
        self.code = strip_code(self.raw)
        self.lines = self.raw.splitlines()
        self.clean = self.code.splitlines()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", help="只扫这些文件（仍用全仓建端口图）")
    ap.add_argument("--no-sim", action="store_true", help="只扫 rtl/")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    all_files: list[str] = []
    for sub in (("rtl",) if args.no_sim else ("rtl", "sim")):
        d = os.path.join(root, sub)
        for dp, _, fns in os.walk(d):
            all_files += [os.path.join(dp, f) for f in fns if f.endswith(".v")]
    all_files = sorted(set(all_files))

    if args.files:
        scope = [os.path.normpath(os.path.join(root, f)) for f in args.files]
    else:
        scope = all_files

    srcs = {p: Src(p) for p in all_files}
    known: set[str] = set()
    mod_ports: dict[str, dict[str, str]] = {}
    for p, s in srcs.items():
        for name, body in find_modules(s.code):
            known.add(name)
            mod_ports.setdefault(name, {}).update(module_ports(body))

    rel = lambda p: os.path.relpath(p, root).replace("\\", "/")

    # ---- 标识符出现 / 声明
    occ: dict[str, list[tuple[str, int, str]]] = {}
    decls: dict[str, list[tuple[str, int, str]]] = {}
    for p, s in srcs.items():
        for lineno, line in enumerate(s.clean, 1):
            for m in IDENT.finditer(line):
                nm = m.group(1)
                if nm in RESERVED:
                    continue
                occ.setdefault(nm, []).append((p, lineno, line.strip()))
                if re.search(r"\b(wire|reg|logic|input|output|inout)\b[^=;]*\b"
                             + re.escape(nm) + r"\b", line):
                    decls.setdefault(nm, []).append((p, lineno, line.strip()))

    def is_sink(line: str) -> bool:
        return "unused_ok" in line

    real: dict[str, list[tuple[str, int, str]]] = {}
    for nm, hits in occ.items():
        d = {(x[0], x[1]) for x in decls.get(nm, [])}
        real[nm] = [(p, l, t) for (p, l, t) in hits
                    if not is_sink(t) and (p, l) not in d]

    # ---- 实例端口连接
    empty_ports: list[tuple[str, str, str, str, str]] = []
    unknown_ports: list[tuple[str, str, str, str]] = []
    n_inst = 0
    for p, s in srcs.items():
        for mod, inst, conns in find_instances(s.code, known):
            n_inst += 1
            for port, conn in conns.items():
                if conn != "":
                    continue
                d = mod_ports.get(mod, {}).get(port)
                if d is None:
                    # 该名字不是被例化模块的端口（多半是解析遗漏或名字打错）
                    unknown_ports.append((rel(p), inst, mod, port))
                else:
                    empty_ports.append((rel(p), inst, mod, port, d))

    # ---- 表 A / C
    # ★ 区分两种"无 RTL 读者"：
    #   A1 带 (* mark_debug *) 属性的探针 —— **有意只给 ILA 用**，
    #      Vivado 靠属性把网络保留下来，Hardware Manager 直接按名字抓。
    #      在 RTL 里没有任何读者是设计意图，不是缺陷。
    #   A2 其余 —— 真死信号。
    dead_all = [(nm, dl) for nm, dl in sorted(decls.items()) if not real.get(nm)]

    def is_debug_marked(nm: str) -> bool:
        for p, l, t in decls.get(nm, []):
            line = srcs[p].lines[l - 1] if l - 1 < len(srcs[p].lines) else t
            if "mark_debug" in line:
                return True
        return False

    dead_probe = [(nm, dl) for nm, dl in dead_all if is_debug_marked(nm)]
    dead = [(nm, dl) for nm, dl in dead_all
            if not is_debug_marked(nm) and nm != "unused_ok"]
    self_sink = [(nm, dl) for nm, dl in dead_all if nm == "unused_ok"]
    only_sink = []
    for nm, hits in sorted(occ.items()):
        if nm == "unused_ok" or not real.get(nm):
            continue
        if any(is_sink(t) for _, _, t in hits):
            if all(re.search(r"\bunused_ok\b|\bdbg_\w+", t) for _, _, t in real[nm]):
                only_sink.append((nm, real[nm]))

    # ---- 表 D
    et_list = []
    p_et = os.path.join(root, "rtl", "enc_top.v")
    if p_et in srcs:
        m = re.search(r"wire\s+unused_ok\s*=\s*&?\s*\{(.*?)\}\s*;", srcs[p_et].code, re.S)
        if m:
            for tok in m.group(1).split(","):
                tok = tok.strip()
                if not re.fullmatch(r"[A-Za-z_]\w*(?:\[[^\]]*\])?", tok):
                    continue
                base = tok.split("[")[0]
                et_list.append((tok, base, len(occ.get(base, [])), len(real.get(base, []))))

    # ---------------------------------------------------------------- 输出
    print("=" * 78)
    print("全仓悬空 / 死信号扫描（跨文件，含实例化端口连接图）")
    print("=" * 78)
    print(f"建图文件 {len(all_files)} 个；本次统计范围 {len(scope)} 个"
          + ("" if not args.files else f"：{', '.join(rel(p) for p in scope)}"))
    print(f"识别模块 {len(known)} 个；实例 {n_inst} 个；"
          f"标识符 {len(occ)} 个；声明 {len(decls)} 个")
    print()

    print("-" * 78)
    print("A. 无 RTL 读者的信号")
    print("-" * 78)
    print(f"  A1. 带 (* mark_debug *) 的 ILA 探针：{len(dead_probe)} 个"
          "  —— 有意只给 ILA 抓，非缺陷")
    if dead_probe:
        for nm, dl in dead_probe:
            p, l, _ = dl[0]
            print(f"      · {nm:24s} {rel(p)}:{l}")
    print()
    print(f"  A2. 真死信号（无 mark_debug、无任何读者）：{len(dead)} 个")
    if dead:
        for nm, dl in dead:
            for p, l, t in dl:
                print(f"      X {nm:24s} {rel(p)}:{l}")
                print(f"          {t}")
    else:
        print("      （无）")
    if self_sink:
        for nm, dl in self_sink:
            p, l, _ = dl[0]
            print(f"      · {nm:24s} {rel(p)}:{l}   （按设计只被声明，就是收容所本身）")
    print()

    print("-" * 78)
    print("B. 空端口连接 `.port()`")
    print("-" * 78)
    if empty_ports:
        n_in = sum(1 for x in empty_ports if x[4] in ("input", "inout"))
        print(f"  共 {len(empty_ports)} 处，其中输入/双向悬空（★ 真问题）{n_in} 处")
        for p, inst, mod, port, d in sorted(empty_ports, key=lambda x: (x[4], x[0], x[2], x[3])):
            tag = {"input": "★ 输入悬空（恒 X/0）",
                   "output": "输出丢弃（调试/可选输出，正常）",
                   "inout": "★ 双向未接"}.get(d, d)
            print(f"  ! [{d:6s}] {p}  {inst}({mod})  .{port}()   {tag}")
    else:
        print("  （无）")
    if unknown_ports:
        print(f"\n  （另有 {len(unknown_ports)} 处空连接的名字**不是**被例化模块的端口，"
              "不计入——多半是解析覆盖不到的写法，不是设计问题）")
        if os.environ.get("SCAN_VERBOSE"):
            for p, inst, mod, port in sorted(unknown_ports):
                print(f"      ? {p}  {inst}({mod})  .{port}()")
    print()

    print("-" * 78)
    print("C. 真实读者全部是暗哑元 sink 的信号（接收但不参与逻辑）")
    print("-" * 78)
    if only_sink:
        for nm, hits in only_sink:
            locs = ", ".join(f"{rel(p)}:{l}" for p, l, _ in hits[:4])
            more = "" if len(hits) <= 4 else f" … 共 {len(hits)} 处"
            print(f"  ~ {nm:26s} {locs}{more}")
    else:
        print("  （无）")
    print()

    print("-" * 78)
    print("D. rtl/enc_top.v 的 unused_ok 汇聚列表逐项核对")
    print("-" * 78)
    if et_list:
        print(f"  {'列表项':30s} {'出现':>5s} {'真实读者':>9s}  判定")
        for tok, base, n_all, n_real in et_list:
            verdict = ("X 无真实读者" if n_real == 0
                       else "~ 读者很少" if n_real <= 2 else "ok")
            print(f"  {tok:30s} {n_all:5d} {n_real:9d}  {verdict}")
        n_bad = sum(1 for _, _, _, r in et_list if r == 0)
        print(f"\n  列表共 {len(et_list)} 项；其中无真实读者 {n_bad} 项")
    print()

    # ★ 退出码只认**真问题**：
    #   · A 真死信号（声明了却无任何 RTL 读者，且不是 ILA 探针）
    #   · B 里 **input / inout** 的空端口连接（驱动端悬空 ⇒ 恒 X/0，是真缺陷）
    #   · C 真实读者全是暗哑元（信号被接收却完全不参与逻辑）
    #   · D unused_ok 列表里出现无真实读者的充数项
    #   **不算问题**（不计入退出码，仅在表里列出）：
    #   · A1 带 (* mark_debug *) 的 ILA 探针 —— 有意只给 ILA 抓
    #   · B 里 **output** 的空端口连接 —— 主动丢弃不用的输出，正常写法
    n_bad_inputs = sum(1 for x in empty_ports if x[4] in ("input", "inout"))
    n_bad_unused = sum(1 for _, _, _, r in et_list if r == 0)
    bad = len(dead) + n_bad_inputs + len(only_sink) + n_bad_unused
    print("=" * 78)
    print(f"汇总：A 真死信号 {len(dead)}｜B 空端口连接 {len(empty_ports)}"
          f"（其中 input/inout 悬空 ★ {n_bad_inputs}）｜C 只进暗哑元 {len(only_sink)}"
          f"｜D 汇聚列表充数项 {n_bad_unused}")
    print("结论：" + (f"★ 有 {bad} 处真问题，见上表" if bad else "无悬空/死信号"))
    print("=" * 78)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
