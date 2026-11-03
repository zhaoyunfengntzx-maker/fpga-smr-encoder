#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tb_wiring.py —— 检查测试台是否真的把激励接到了 DUT 上（"空转测试台"体检）

【适用】任何 Verilog/SystemVerilog 测试台。解决的问题是：
        测试台跑完了、打印了 PASSED、退出码 0，但它**根本没有驱动 DUT 的输入**——
        于是"通过"只是"比较器比了两次相同的常数"。这类测试台在报告里与真测试不可区分。

【用法】
    # 1) 只知道测试台：能查出"端口没连"和"输入接成常量"
    python tb_wiring.py sim/tb_angle_lut.v

    # 2) 同时给 DUT 源码：能区分输入/输出方向，把"输入悬空"升级为 ERROR
    python tb_wiring.py sim/tb_angle_lut.v --dut rtl/angle_lut.v

    # 3) 批量查一整个 sim/ 目录（只看 DUT 实例，不仿真）
    python tb_wiring.py --scan sim --strict

    # 4) 严格模式：把"疑似没被赋值的信号"也当失败（默认只是 WARN）
    python tb_wiring.py sim/tb_x.v --dut rtl/x.v --strict

【退出码】0 = 没有 ERROR；1 = 至少一个 ERROR；2 = 解析不出 module 或 DUT 实例

【检查项】
  E1  DUT 的输入端口没在实例化里出现（少连）
  E2  DUT 的输入端口连到了常量（1'b0 / 0 / {N{1'b0}} 之类）——静态激励
  W1  输入端口连的信号在测试台里从未被赋值（疑似悬空，--strict 变 E）
  W2  DUT 输出端口悬空（`.rd_q()`）——允许，但确认是有意的
  W3  测试台没有 $finish（可能挂死）；或没有 timeout 保护
  W4  测试台没有可判读的结论行（"TEST PASSED"/"TEST FAILED"/"PASS"/"FAIL"）

【为什么要有这个脚本】
  本工程第一版 `tb_cordic_atan2.v` 的激励寄存器名改了、实例化没跟着改，
  仿真 20 分钟后打印 "TEST PASSED"，实际上 DUT 输入一直是 X。
  人工排查花了半天；这个脚本对同一处缺陷的定位时间是 1 秒（E1/E2 直接给行号）。
  记录见 docs/ai-collaboration-log.md 记录 1；方法论见 skill/testbench-blindspot.md §3.1。

【失效条件】
  1) 位置连接（`dut u1(a, b, c)`）不查——本脚本只认按名连接 `.port(sig)`；
  2) 端口由宏/参数化拼接生成时解析不到方向，只能降级为 WARN；
  3) 测试台用 force/release 或层次赋值驱动输入时，W1（从未赋值）会误报；
  4) 它只查"接线"，不查"激励是否覆盖"——覆盖问题看 skill/testbench-blindspot.md §2。
"""

from __future__ import annotations

import argparse
import os
import re
import sys

VERILOG_KEYWORDS = {
    "module", "endmodule", "input", "output", "inout", "wire", "reg", "logic",
    "assign", "always", "initial", "begin", "end", "if", "else", "for", "while",
    "case", "casex", "casez", "endcase", "function", "endfunction", "task",
    "endtask", "generate", "endgenerate", "genvar", "integer", "real", "time",
    "parameter", "localparam", "defparam", "specify", "endspecify", "primitive",
    "table", "endtable", "fork", "join", "repeat", "forever", "wait", "disable",
    "posedge", "negedge", "or", "and", "not", "buf", "supply0", "supply1",
}

CONST_RE = re.compile(
    r"^(\d*'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_?]+|\d+|'[01xXzZ]|\{[^{}]*\}|\d*'[sS]?[bB]\s*\{[^{}]*\})$"
)


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def strip_comments(text: str) -> str:
    """去掉注释但保留换行，保证行号不变。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def find_module_name(text: str) -> str | None:
    m = re.search(r"\bmodule\s+([A-Za-z_]\w*)", text)
    return m.group(1) if m else None


def match_paren(text: str, open_idx: int) -> int:
    """从 '(' 位置起找配对的 ')'，返回其下标（找不到返回 -1）。"""
    depth = 0
    for i in range(open_idx, len(text)):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1


def split_top(text: str, sep: str = ",") -> list[str]:
    parts, depth, cur = [], 0, []
    for c in text:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    parts.append("".join(cur))
    return parts


DECL_TAIL = re.compile(
    r"^(?:(?:wire|reg|logic|signed|unsigned|integer|bit|byte|int)\s+)?"
    r"(?:\[[^\]]*\]\s*)?[A-Za-z_]\w*$"
)


def parse_directions(dut_text: str) -> dict[str, str]:
    """返回 {端口名: input/output/inout}。

    统一按"用 ; ( ) 切开、再按 , 切段"的方式扫：
      ANSI 写法  `input wire [7:0] din,` 每段自带方向；
      非 ANSI    `module m(a,b); input a; output b;` 方向在体内。
    ★ 只认"声明形状"的段（类型? 位宽? 名字），否则 `begin dout <= din` 里的
      din 会被误判成端口——本工程第一版就是这个 bug，把端口表污染成
      .input()/.output() 两个假端口。
    """
    text = strip_comments(dut_text)
    dirs: dict[str, str] = {}
    cur: str | None = None
    for seg in re.split(r"[;()]", text):
        for part in seg.split(","):
            part = re.sub(r"\s+", " ", part).strip()
            if not part:
                continue
            dm = re.match(r"^(input|output|inout)\b\s*", part)
            if dm:
                cur = dm.group(1)
                part = part[dm.end():].strip()
            if cur is None:
                continue
            if not DECL_TAIL.match(part):
                cur = None          # 不是声明段：清掉方向，防止漏到下一个语句
                continue
            name = re.findall(r"[A-Za-z_]\w*", re.sub(r"\[[^\]]*\]", " ", part))[-1]
            dirs.setdefault(name, cur)
    return dirs


INSTANCE_RE = re.compile(
    r"\b(?P<mod>[A-Za-z_]\w*)\s*"
    r"(?:#\s*\((?P<params>[^;]*?)\)\s*)?"
    r"(?P<inst>[A-Za-z_]\w*)\s*"
    r"(?:\[[^\]]*\]\s*)?\("
)


def find_dut_instance(text: str, tb_module: str) -> tuple[str, str, str, int] | None:
    """找测试台里第一个"看起来像 DUT"的实例化（按名连接），
    返回 (模块名, 实例名, 实例端口文本, 起始行)。"""
    for m in INSTANCE_RE.finditer(text):
        mod = m.group("mod")
        if mod in VERILOG_KEYWORDS or mod == tb_module:
            continue
        open_paren = m.end() - 1
        close = match_paren(text, open_paren)
        if close < 0:
            continue
        inst_text = text[open_paren:close + 1]
        if "." not in inst_text:  # 位置连接：本工具不支持按名查
            continue
        line = text.count("\n", 0, m.start()) + 1
        return mod, m.group("inst"), inst_text, line
    return None


def parse_connections(inst_text: str) -> dict[str, tuple[str, int]]:
    """返回 {端口: (连接表达式, 相对行号)}；相对行号以实例文本第 1 行为 1。"""
    conns: dict[str, tuple[str, int]] = {}
    for m in re.finditer(r"\.\s*([A-Za-z_]\w*)\s*\(", inst_text):
        close = match_paren(inst_text, m.end() - 1)
        if close < 0:
            continue
        expr = inst_text[m.end():close].strip()
        line = inst_text.count("\n", 0, m.start()) + 1
        conns[m.group(1)] = (expr, line)
    return conns


def assigned_names(text: str, tb_module: str) -> set[str]:
    """测试台里所有"出现在赋值左边"的标识符 + for 循环变量。"""
    names: set[str] = set()
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*(?:\[[^\]\n]*\])?\s*(?:<=|=)(?!=)", text):
        names.add(m.group(1))
    for m in re.finditer(r"\bfor\s*\(\s*([A-Za-z_]\w*)\s*=", text):
        names.add(m.group(1))
    for m in re.finditer(r"\bassign\s+([A-Za-z_]\w*)", text):
        names.add(m.group(1))
    for m in re.finditer(r"\b(?:force|deassign)\s+([A-Za-z_]\w*)", text):
        names.add(m.group(1))
    return names


def check_one(tb_path: str, dut_path: str | None, strict: bool) -> tuple[int, list[str]]:
    """返回 (错误数, 报告行)。"""
    errors = 0
    lines: list[str] = []

    def emit(level: str, msg: str) -> None:
        nonlocal errors
        lines.append(f"  [{level}] {msg}")
        if level in ("ERROR", "E1", "E2"):
            errors += 1

    try:
        with open(tb_path, "r", encoding="utf-8-sig", errors="replace") as f:
            tb_raw = f.read()
    except OSError as e:
        return 2, [f"[ERROR] 读不了 {tb_path}: {e}"]

    tb = strip_comments(tb_raw)
    tb_module = find_module_name(tb)
    if not tb_module:
        return 2, [f"[ERROR] {tb_path} 里找不到 module 声明"]

    found = find_dut_instance(tb, tb_module)
    if not found:
        return 2, [f"[ERROR] {tb_path} 里找不到带 .port(…) 名字连接的实例化"
                   f"（位置连接不支持；本工具只查按名连接）"]
    dut_mod, _inst, inst_text, inst_line = found

    conns = parse_connections(inst_text)
    dirs: dict[str, str] = {}
    if dut_path:
        try:
            with open(dut_path, "r", encoding="utf-8-sig", errors="replace") as f:
                dirs = parse_directions(f.read())
        except OSError as e:
            lines.append(f"  [WARN] 读不了 DUT 源码 {dut_path}: {e}（只能按'未知方向'检查）")

    assigned = assigned_names(tb, tb_module)

    lines.insert(0, f"{tb_path}  (module {tb_module}, DUT = {dut_mod} @ 第 {inst_line} 行, "
                    f"连接 {len(conns)} 个端口)")

    # E1：少连端口
    for name, kind in sorted(dirs.items()):
        if name in conns:
            continue
        if kind == "output":
            emit("WARN", f"W2 输出端口 .{name}() 未连接（允许；确认是有意的）")
        else:
            emit("ERROR", f"E1 输入端口 .{name}() 没连（DUT 的这个输入是悬空的）")

    # E2 / W1：连接表达式本身
    for name, (expr, rel_line) in sorted(conns.items()):
        kind = dirs.get(name)
        abs_line = inst_line + rel_line - 1
        ref = f"第 {abs_line} 行的 .{name}({expr})"
        if expr == "":
            if kind == "output":
                emit("WARN", f"W2 {ref}：输出悬空")
            else:
                emit("ERROR" if dut_path else "WARN",
                     f"E1 {ref}：端口连了空括号")
            continue
        if CONST_RE.match(expr.replace(" ", "")):
            emit("ERROR" if kind in (None, "input") else "WARN",
                 f"E2 {ref}：连到常量，DUT 输入永远不变")
            continue
        base = re.match(r"^([A-Za-z_]\w*)", expr)
        if kind == "input" and base:
            sig = base.group(1)
            if sig not in assigned and sig not in ("$unsigned", "$signed"):
                msg = f"W1 {ref}：信号 {sig} 在测试台里没有被赋值过（疑似悬空激励）"
                if strict:
                    emit("ERROR", msg)
                else:
                    emit("WARN", msg)

    # W3 / W4：测试台自身有没有判据
    if "$finish" not in tb:
        emit("WARN", "W3 没有 $finish：仿真可能跑不完或依赖外部超时")
    if not re.search(r"#\s*\d+", tb):
        emit("WARN", "W3 没有 #<延时> 形式的超时保护")
    if not re.search(r"TEST\s+(PASSED|FAILED)|PASS|FAIL", tb, re.I):
        emit("WARN", "W4 没有任何可判读的结论行（TEST PASSED / FAILED）")

    verdict = "FAIL" if errors else "PASS"
    lines.append(f"  => {verdict}（{len(lines) - 1} 条发现，其中 ERROR {errors}）")
    return (1 if errors else 0), lines


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="测试台接线体检：激励是否真的接到了 DUT")
    ap.add_argument("tb", nargs="?", help="测试台 .v 文件")
    ap.add_argument("--dut", help="DUT 源码 .v（给了才能区分输入/输出方向）")
    ap.add_argument("--scan", help="扫描目录下所有 tb_*.v")
    ap.add_argument("--strict", action="store_true", help="把 W1（疑似悬空激励）升级为错误")
    args = ap.parse_args(argv)

    targets: list[tuple[str, str | None]] = []
    if args.scan:
        if not os.path.isdir(args.scan):
            print(f"[ERROR] 目录不存在: {args.scan}", file=sys.stderr)
            return 2
        for name in sorted(os.listdir(args.scan)):
            if name.lower().startswith("tb_") and name.endswith((".v", ".sv")):
                targets.append((os.path.join(args.scan, name), args.dut))
        if not targets:
            print(f"[ERROR] {args.scan} 下没有 tb_*.v", file=sys.stderr)
            return 2
    elif args.tb:
        targets.append((args.tb, args.dut))
    else:
        ap.print_help()
        return 2

    worst = 0
    for tb, dut in targets:
        rc, report = check_one(tb, dut, args.strict)
        print("\n".join(report))
        worst = max(worst, 2 if rc == 2 else rc)
    if len(targets) > 1:
        print(f"\n共 {len(targets)} 个测试台，最坏结果 {worst}")
    return worst


if __name__ == "__main__":
    sys.exit(main())
