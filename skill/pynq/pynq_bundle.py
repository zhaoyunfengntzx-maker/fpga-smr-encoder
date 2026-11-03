#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查一个 PYNQ overlay 交付目录：`.bit` 与 `.hwh` 是否配对、是否同一次构建。

【适用】
  每次"把位流交给 Python"之前。PYNQ 的 `Overlay('x.bit')` 会在同目录找 `x.hwh`；
  找不到照样能下载位流，但 Python 侧看不到任何 IP——于是 `overlay.gpio_regs`
  抛 AttributeError，或者你读到的地址是上一次构建的。换板卡时同一条规则：
  板卡变了，`.hwh` 必须跟着重新导出。

【用法】
  python skill/pynq/pynq_bundle.py examples/bundle/            # 体检目录
  python skill/pynq/pynq_bundle.py out/ --diff old/design_1.hwh # 换版本/换板卡对比
  python skill/pynq/pynq_bundle.py out/ --json out/bundle.json
  python skill/pynq/pynq_bundle.py out/ -q                      # 只在有问题时出声

【输入格式与退出码】
  输入：一个目录（含 `*.bit` + `*.hwh`，可选 `*.xsa`）或单个 `.bit` 路径。
  退出码：0 配对且一致；1 有 FAIL/WARN；2 路径不存在或给不出判断。

【为什么要有这个脚本】
  记录 85：位流被别人的工作树挡住，报告里写的和手里拿的不是同一版；
  记录 77：屏上数字有保质期，手抄的常量会过期。Pynq 侧这两件事合成一句话：
  **.bit 和 .hwh 不是同一次导出时，Python 拿到的地址表是假的**。
  这类错误不会报错，只会让你读到 0，然后在"是不是逻辑写错了"上浪费一天。

【失效条件】
  1) Kria/KV260 等 MPSoC 平台用 `.xclbin` 而不是 `.bit`，本脚本会跳过位流检查，
     只核对 `.hwh`；vitis 流程的 handoff 文件名约定也不同。
  2) 只做仿真、不上板的工程用不上它。
  3) 它检查"配对与一致性"，不检查位流内容是否实现了你在报告里写的功能——
     那要靠上板测试向量（见 templates/overlay_app.py）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pynq_hwh import parse_hwh, check, _utf8_console  # noqa: E402


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="PYNQ overlay 交付目录体检")
    ap.add_argument("target", type=Path)
    ap.add_argument("--diff", type=Path, help="旧版 .hwh，用于换版本/换板卡对比")
    ap.add_argument("--json", type=Path)
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    tgt: Path = args.target
    if not tgt.exists():
        print(f"[EXIT2] 找不到 {tgt}")
        return 2
    root = tgt if tgt.is_dir() else tgt.parent

    bits = sorted(root.glob("*.bit"))
    hwhs = sorted(root.glob("*.hwh"))
    xclbins = sorted(root.glob("*.xclbin"))
    xsas = sorted(root.glob("*.xsa"))

    findings: list[tuple[str, str, str]] = []

    if not hwhs:
        findings.append(("FAIL", "BUNDLE-001",
                         "目录里没有 .hwh：`Overlay('x.bit')` 会下载位流但解析不到任何 IP，"
                         "Python 侧只能用绝对地址裸读写"))
    if not bits and not xclbins:
        findings.append(("FAIL", "BUNDLE-002", "目录里既没有 .bit 也没有 .xclbin"))
    for b in bits:
        mate = b.with_suffix(".hwh")
        if not mate.exists():
            findings.append(("FAIL", "BUNDLE-003",
                             f"{b.name} 没有同名 .hwh（PYNQ 按文件名配对，"
                             f"找的是 {mate.name}）"))
        elif mate.stat().st_mtime < b.stat().st_mtime - 1:
            findings.append(("WARN", "BUNDLE-004",
                             f"{mate.name} 比 {b.name} 旧：位流是新导出的、地址表是旧的，"
                             "读到的基址可能已经变了"))
    for h in hwhs:
        if not h.with_suffix(".bit").exists() and not xclbins:
            findings.append(("WARN", "BUNDLE-005",
                             f"{h.name} 没有对应位流（只有地址表，没法上板）"))

    design = None
    for h in hwhs:
        design = parse_hwh(h)
        rows, hwh_findings, notes = check(design)
        findings.extend(hwh_findings)
        if not args.quiet:
            print(f"{h.name}: device={design.system.get('device','?')} "
                  f"arch={design.system.get('arch','?')} "
                  f"IP={len(design.ips)} 段地址={sum(len(ip.ranges) for ip in design.ips)}")
            if notes:
                print("  时钟：" + "；".join(notes))

    if xsas:
        findings.append(("NOTE", "BUNDLE-006",
                         f"目录里有 {len(xsas)} 个 .xsa：它是给 Vitis/裸机用的，"
                         "PYNQ 不读它；但两者必须同源，否则 PS 配置与 PL 位流可能不匹配"))

    sums = {}
    for f in bits + hwhs:
        d = sha256(f)
        sums[f.name] = d
        if not args.quiet:
            print(f"  {f.name}  {f.stat().st_size:>9} B  sha256={d[:16]}…")

    if args.diff and design is not None:
        old = parse_hwh(args.diff)
        new_ips = {ip.instance for ip in design.ips}
        old_ips = {ip.instance for ip in old.ips}
        added, removed = sorted(new_ips - old_ips), sorted(old_ips - new_ips)
        print(f"\n与 {args.diff.name} 对比：新增 {added or '—'}；移除 {removed or '—'}")
        new_addr = {r.instance: r.base for ip in design.ips for r in ip.ranges}
        old_addr = {r.instance: r.base for ip in old.ips for r in ip.ranges}
        for inst in sorted(set(new_addr) & set(old_addr)):
            if new_addr[inst] != old_addr[inst]:
                print(f"  地址变了 {inst}: 0x{old_addr[inst]:08X} → 0x{new_addr[inst]:08X}"
                      "（host 侧写死的地址要跟着改）")
        if added or removed:
            findings.append(("WARN", "BUNDLE-010",
                             "两版 IP 清单不同：换板卡/换版本后，host 脚本里的属性名要重新对一遍"))

    fails = [f for f in findings if f[0] == "FAIL"]
    warns = [f for f in findings if f[0] == "WARN"]
    for level, code, text in findings:
        if level != "NOTE" or not args.quiet:
            print(f"[{level}] {code}: {text}")

    if args.json:
        args.json.write_text(json.dumps({
            "dir": str(root),
            "bitstreams": [b.name for b in bits],
            "handoffs": [h.name for h in hwhs],
            "sha256": sums,
            "findings": [{"level": l, "code": c, "text": t} for l, c, t in findings],
            "status": "fail" if fails else ("warn" if warns else "pass"),
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if fails:
        print(f"\n=> FAIL（{len(fails)} 项会直接导致上板读不到数，{len(warns)} 条警告）")
        return 1
    print(f"\n=> PASS（位流与地址表配对，{len(warns)} 条警告）")
    return 1 if warns else 0


if __name__ == "__main__":
    sys.exit(main())
