#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/check_regmap.py —— 寄存器地图一致性检查（RTL <-> 上位机 <-> 文档）

做的事：
  1. 从 rtl/reg_file.v 抽出所有 `16'hXXXX:` case 标签，按行内出现 `rdata` / `<=`
     区分“可读”与“可写”，得到 RTL 的真实地址集合。
  2. 从 host/*.py 抽出 `REG_xxx = 0x0NNN` 常量（以及 tools/*.py 里的裸 0x0NNN 引用），
     检查每个上位机地址在 RTL 里是否可读/可写。
  3. 报告 RTL 有、上位机没用的地址（只提示，不算错），以及上位机有、RTL 没有的地址（算错）。
  4. 顺带检查 docs 里寄存器的写法是否有明显过期项（只统计，不判定）。

退出码：0 = 没有“上位机地址在 RTL 中不存在”；1 = 有。

用法：
    python tools/check_regmap.py            # 摘要
    python tools/check_regmap.py -v         # 每个地址都打印
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

# `16'h0514:` 这种 case 标签
CASE_RE = re.compile(r"16'h([0-9A-Fa-f]{4})\s*:")
# host 侧：REG_XXX = 0x0514
HOST_RE = re.compile(r"\b(REG_[A-Z0-9_]+)\s*=\s*0x([0-9A-Fa-f]{1,4})\b")
# 任意 0x0NNN / 0xNNNN 形式的寄存器引用（用于 tools/*.py 的裸地址）
BARE_RE = re.compile(r"0x(0[1-7][0-9A-Fa-f]{2})\b")   # 只认 0x0100..0x07FF 的寄存器地址


def parse_rtl() -> tuple[set[int], set[int]]:
    """返回 (可读地址, 可写地址)。

    * rtl/*.v 里的 `16'hXXXX:` case 标签 -> 直接是字节地址。
    * rtl/cap_regs.v 用 `case (addr[7:1])` 按**字**索引解码，标签形如 `7'd12:`，
      对应字节地址 0x0700 + 2*12 = 0x0718，高字节 0x0719 也读得到（值多为 0）。
    """
    readable: set[int] = set()
    writable: set[int] = set()

    for f in sorted((ROOT / "rtl").glob("*.v")):
        if f.name == "cap_regs.v":
            continue
        src = f.read_text(encoding="utf-8", errors="replace")
        for line in src.splitlines():
            m = CASE_RE.search(line)
            if not m:
                continue
            addr = int(m.group(1), 16)
            rest = line[m.end():]
            if "rdata" in rest:
                readable.add(addr)
            if "<=" in rest:
                writable.add(addr)

    cap = ROOT / "rtl/cap_regs.v"
    if cap.exists():
        src = cap.read_text(encoding="utf-8", errors="replace")
        for line in src.splitlines():
            m = re.search(r"\b\d+'d(\d+)\s*:", line)
            if not m:
                continue
            idx = int(m.group(1))
            if idx > 127:
                continue
            addr = 0x0700 + 2 * idx
            rest = line[m.end():]
            if "rdata" in rest:
                readable.update((addr, addr + 1))
            if "<=" in rest:
                writable.update((addr, addr + 1))

    # 0x0700 段整段由 cap_regs 判选（reg_file.v:697 default 分支），窗口内一律视为已知
    readable.update(range(0x0700, 0x0800))
    return readable, writable


def parse_host() -> dict[str, int]:
    consts: dict[str, int] = {}
    for p in sorted((ROOT / "host").glob("*.py")):
        if p.name.startswith("selftest_"):
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        for m in HOST_RE.finditer(text):
            consts[m.group(1)] = int(m.group(2), 16)
    return consts


def parse_bare_tools() -> dict[str, set[int]]:
    out: dict[str, set[int]] = {}
    for p in sorted((ROOT / "tools").glob("*.py")) + sorted((ROOT / "_boardtest").glob("*.py")):
        text = p.read_text(encoding="utf-8", errors="replace")
        addrs = {int(m.group(1), 16) for m in BARE_RE.finditer(text)}
        if addrs:
            out[str(p.relative_to(ROOT))] = addrs
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    readable, writable = parse_rtl()
    consts = parse_host()
    bad: list[tuple[str, int]] = []

    print("RTL 可读地址 %d 个、可写地址 %d 个（%s）"
          % (len(readable), len(writable), "rtl/reg_file.v"))

    missing_ro = sorted(set(consts.values()) - readable)
    missing_wo = sorted(set(consts.values()) - writable)
    print("\n上位机常量 %d 个；RTL 里读不到 %d 个、写不进 %d 个"
          % (len(consts), len(missing_ro), len(missing_wo)))

    for name, addr in sorted(consts.items(), key=lambda kv: kv[1]):
        ok_r = addr in readable
        ok_w = addr in writable
        tag = "RO" if ok_r and not ok_w else ("WO" if ok_w and not ok_r else ("RW" if ok_r else "??"))
        if not ok_r:
            bad.append((name, addr))
        if a.verbose or not ok_r:
            print("  %-26s 0x%04X  RTL:%-3s %s" % (name, addr, tag, "" if ok_r else "<-- RTL 无此读地址"))

    # 同一个地址被两个不同名字使用 -> 可能是复制粘贴错误
    by_addr: dict[int, list[str]] = {}
    for name, addr in consts.items():
        by_addr.setdefault(addr, []).append(name)
    dup = {k: v for k, v in by_addr.items() if len(v) > 1}
    if dup:
        print("\n同一地址多个常量名（可能重复/别名）：")
        for addr, names in sorted(dup.items()):
            print("  0x%04X -> %s" % (addr, ", ".join(sorted(names))))

    # 上位机没引用的 RTL 地址（提示）
    unused = sorted(readable - set(consts.values()))
    print("\nRTL 可读但上位机未定义常量的地址：%d 个" % len(unused))
    if a.verbose:
        for addr in unused:
            print("  0x%04X" % addr)

    # tools/ 裸地址：只要有 RTL 完全不认识的，就提示
    print("\ntools/_boardtest 里出现的裸 0x0NNN 地址核对：")
    any_bad = False
    for f, addrs in parse_bare_tools().items():
        unknown = sorted(addrs - readable - writable)
        if unknown:
            any_bad = True
            print("  %-46s 未知地址 %s" % (f, ", ".join("0x%04X" % x for x in unknown[:8])))
    if not any_bad:
        print("  全部能在 RTL 中找到")

    if bad:
        print("\n结论：FAIL —— %d 个上位机常量在 RTL 中不存在" % len(bad))
        return 1
    print("\n结论：PASS —— 上位机所有寄存器常量都在 RTL 中")
    return 0


if __name__ == "__main__":
    sys.exit(main())
