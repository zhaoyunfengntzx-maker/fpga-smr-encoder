#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Vivado 导出的 .hwh（IP integrator handoff）读成一张可核对的地址表。

【适用】
  任何 PYNQ / Zynq 工程的 overlay 交付：.hwh 里有什么 IP、各自挂在哪个基址、
  跨了几个 4K 页、时钟谁跟谁同源——这些是 Python 侧 `Overlay` 拿到的全部事实。
  换题目、换板卡都不用改这个脚本：它只认文件里的内容，不认板名。

【用法】
  python skill/pynq/pynq_hwh.py examples/addr_map/design_1.hwh          # 人读表 + 判决
  python skill/pynq/pynq_hwh.py design_1.hwh --md map.md --json map.json # 生成文档/机器可读
  python skill/pynq/pynq_hwh.py design_1.hwh --diff other.hwh            # 换板卡时比两版
  python skill/pynq/pynq_hwh.py design_1.hwh -q                          # 只在失败时出声

【输入格式与退出码】
  输入：Vivado 的 `.hwh`（XML，根元素 EDKSYSTEM）。本脚本对嵌套层级容错，
  认 MODULE / PARAMETER / BUSINTERFACE / MEMRANGE / REGISTER 这些标签名，
  所以不同 Vivado 版本导出的文件都能读。
  输出：stdout 表格 + 判决（中文）；`--md/--json` 落盘。
  退出码：0 全部判据通过；1 有 FAIL 或 WARN；2 文件读不了 / 不像 .hwh（不猜）。

【为什么要有这个脚本】
  本队工程是纯 RTL，没有 PS，因此 PYNQ 侧的东西都是"外部经验"——但地址这
  一类事实是**文件里写死的**，可以脱离硬件核对：把 .hwh 摊开，两个 IP 是否
  撞地址、某个 IP 是否压根没分配基址（读它必然返回 0）、4K 页是否被跨开，
  这些错误在板子上表现为"读回全 0 / 总线挂死"，在文件里却是几行数字。
  本队踩过同构的坑：记录 85（位流被别人的工作树挡住，报告与位流不同步）
  与记录 77（屏上数字的保质期：手抄常量对不上生成物）。

【失效条件】
  1) 脚本报"0 个 MEMRANGE"不代表设计错——若你的 BD 里从设备本来就没
     assign 地址（本包 examples/real_bd/ 就是这种），Pynq 侧同样读不到，
     这时的 FAIL 是替你说出"你还没分配地址"。
  2) `.hwh` 只描述 PS 看到的门铃（地址/时钟/中断号），不含寄存器语义；
     想知道 GPIO_DATA 的偏移，要看 IP 文档或 `pynq` 的驱动代码。
  3) 对 Zynq UltraScale+ / Kria（.xclbin + .hwh 组合）本脚本仍能读地址表，
     但 `pynq_bundle.py` 的文件名约定那部分要按平台调整。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

PAGE = 0x1000


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def _w(s: str) -> int:
    return sum(2 if ord(c) > 0x2E80 else 1 for c in s)


def pad(s: str, n: int) -> str:
    return s + " " * max(0, n - _w(s))


def _hex(v: str | None) -> int | None:
    if v is None:
        return None
    v = v.strip()
    try:
        return int(v, 16) if v.lower().startswith("0x") else int(v, 0)
    except ValueError:
        return None


@dataclass
class MemRange:
    instance: str
    base: int
    high: int
    memtype: str = ""
    valid: bool = True

    @property
    def size(self) -> int:
        return self.high - self.base + 1


@dataclass
class Ip:
    instance: str
    fullname: str
    version: str
    iptype: str
    params: dict = field(default_factory=dict)
    clk_domains: dict = field(default_factory=dict)   # interface -> (freq_hz, domain)
    slaves: list = field(default_factory=list)        # AXI 从接口名（TYPE=SLAVE）
    registers: list = field(default_factory=list)     # [(name, offset, access)]
    ranges: list = field(default_factory=list)


@dataclass
class Design:
    path: Path
    system: dict
    ips: list
    warnings: list


def parse_hwh(path: Path) -> Design:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise SystemExit(f"[EXIT2] {path}: 不是合法 XML（{exc}）")
    if root.tag != "EDKSYSTEM":
        raise SystemExit(f"[EXIT2] {path}: 根元素是 {root.tag}，不像 Vivado 的 .hwh")

    system = {"name": path.stem}
    info = root.find("SYSTEMINFO")
    if info is not None:
        system.update({k.lower(): v for k, v in info.attrib.items()})

    ips: list[Ip] = []
    for mod in root.iter("MODULE"):
        inst = mod.get("INSTANCE") or mod.get("FULLNAME") or "?"
        ip = Ip(
            instance=inst,
            fullname=mod.get("FULLNAME", ""),
            version=mod.get("HWVERSION", ""),
            iptype=mod.get("IPTYPE", ""),
        )
        for p in mod.iter("PARAMETER"):
            name = p.get("NAME")
            if name:
                ip.params[name] = p.get("VALUE")
        for bus in mod.iter("BUSINTERFACE"):
            iface = bus.get("NAME") or bus.get("BUSNAME") or "?"
            if bus.get("TYPE", "").upper() == "SLAVE":
                ip.slaves.append(iface)
            sub = {p.get("NAME"): p.get("VALUE") for p in bus.iter("PARAMETER")}
            if "FREQ_HZ" in sub or "CLK_DOMAIN" in sub:
                try:
                    freq = float(sub.get("FREQ_HZ", 0) or 0) / 1e6
                except ValueError:
                    freq = 0.0
                ip.clk_domains[iface] = (freq, sub.get("CLK_DOMAIN", ""))
        for reg in mod.iter("REGISTER"):
            ip.registers.append(
                (reg.get("NAME", "?"), _hex(reg.get("OFFSET")), reg.get("ACCESS", ""))
            )
        for mr in mod.iter("MEMRANGE"):
            base = _hex(mr.get("BASEVALUE"))
            high = _hex(mr.get("HIGHVALUE"))
            size = _hex(mr.get("SIZE"))
            if base is None:
                continue
            if high is None:
                high = base + (size or 0) - 1
            ip.ranges.append(
                MemRange(
                    instance=mr.get("INSTANCE", inst),
                    base=base,
                    high=high,
                    memtype=mr.get("MEMTYPE", ""),
                    valid=(mr.get("IS_VALID", "TRUE").upper() != "FALSE"),
                )
            )
        ips.append(ip)
    return Design(path=path, system=system, ips=ips, warnings=[])


def check(design: Design) -> tuple[list, list, list]:
    """-> (rows, findings, notes)；finding = (level, code, text)"""
    findings: list[tuple[str, str, str]] = []
    rows = []
    all_ranges: list[MemRange] = []

    for ip in design.ips:
        base = "-"
        size = "-"
        if ip.ranges:
            r = ip.ranges[0]
            base = f"0x{r.base:08X}"
            size = str(r.size)
            all_ranges.extend([x for x in ip.ranges if x.valid])
        freq = ""
        for iface, (mhz, dom) in ip.clk_domains.items():
            freq = f"{mhz:g} MHz" if mhz else "-"
            break
        rows.append([ip.instance, f"{ip.fullname.split('/')[-1]} {ip.version}".strip(),
                     ip.iptype, base, size, freq])

    referenced = {r.instance for r in all_ranges}
    unassigned = [
        ip.instance for ip in design.ips
        if not ip.ranges and ip.slaves
        and ip.instance not in referenced
        and not ip.instance.startswith("ps7")
    ]
    if not all_ranges:
        findings.append(("FAIL", "ADDR-000",
                         "没有任何 MEMRANGE：这个设计没给从设备分配地址，"
                         "PYNQ 侧访问这些 IP 会读到 0 或直接总线超时"))
    elif unassigned:
        findings.append(("FAIL", "ADDR-001",
                         f"{len(unassigned)} 个外设没有地址：{', '.join(unassigned[:6])}"))

    for r in all_ranges:
        if r.base % 4:
            findings.append(("FAIL", "ADDR-002",
                             f"{r.instance} 基址 0x{r.base:08X} 不是 4 字节对齐"))
        if r.base % PAGE:
            findings.append(("WARN", "ADDR-003",
                             f"{r.instance} 基址 0x{r.base:08X} 不在 4K 边界上，"
                             "跨页访问在部分互联上会拆包失败"))
        if r.size and (r.size & (r.size - 1)):
            findings.append(("WARN", "ADDR-004",
                             f"{r.instance} 地址范围 {r.size} 字节不是 2 的幂"))
        if r.size > PAGE and r.base % PAGE == 0 and (r.size % PAGE) == 0:
            findings.append(("NOTE", "ADDR-005",
                             f"{r.instance} 占 {r.size // PAGE} 个 4K 页"
                             f"（0x{r.base:08X}–0x{r.high:08X}），"
                             "PYNQ 侧按字节偏移访问时注意不要越界"))

    ordered = sorted(all_ranges, key=lambda r: r.base)
    for a, b in zip(ordered, ordered[1:]):
        if b.base <= a.high and a.instance != b.instance:
            findings.append(("FAIL", "ADDR-010",
                             f"{a.instance}(0x{a.base:08X}–0x{a.high:08X}) 与 "
                             f"{b.instance}(0x{b.base:08X}–0x{b.high:08X}) 地址重叠"))

    clocks = {}
    for ip in design.ips:
        for iface, (mhz, dom) in ip.clk_domains.items():
            if mhz:
                clocks.setdefault(round(mhz, 3), set()).add(dom or "?")
    notes = []
    if clocks:
        for mhz in sorted(clocks):
            notes.append(f"{mhz:g} MHz  ← {len(clocks[mhz])} 个时钟域")
        if len(clocks) > 1:
            findings.append(("WARN", "CLK-001",
                             "设计里有多个频率：" f"{', '.join(f'{m:g} MHz' for m in sorted(clocks))}"
                             "；host 侧设置的 FCLK 必须与实际一致，否则按周期换算的"
                             "吞吐/延时全错"))
    else:
        findings.append(("WARN", "CLK-002",
                         "hwh 里没有 FREQ_HZ：无法核对时钟，只能靠 ps.Clocks 读回"))

    # 单个从口没声明时钟（其它口声明了）：这比"整个设计没有时钟"常见得多，
    # 手写 AXI 从设备、或老版本导出都容易缺这一段。
    silent = [ip.instance for ip in design.ips if ip.slaves and not ip.clk_domains]
    if silent and clocks:
        findings.append(("WARN", "CLK-003",
                         f"{len(silent)} 个从设备没声明时钟：{', '.join(silent[:6])}；"
                         "它的寄存器访问时序只能按最慢的那个域估，或去查 PS 侧 FCLK"))

    if not any(ip.registers for ip in design.ips):
        findings.append(("NOTE", "REG-001",
                         "hwh 不含寄存器列表（Vivado 默认如此）：寄存器偏移要查 IP 文档"
                         "或 pynq 驱动，别看这个文件"))
    return rows, findings, notes


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="读 .hwh：地址表 / 时钟 / 判据")
    ap.add_argument("hwh", type=Path)
    ap.add_argument("--diff", type=Path, help="另一版 .hwh，做换板卡/换版本对比")
    ap.add_argument("--json", type=Path)
    ap.add_argument("--md", type=Path)
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--lenient", action="store_true",
                    help="只让 FAIL 拦住流程（多时钟域、缺时钟声明这类 WARN 不判失败）；"
                         "脚本化“先跑起来”时用，做交付体检时不要用")
    args = ap.parse_args(argv)

    if not args.hwh.is_file():
        print(f"[EXIT2] 找不到 {args.hwh}")
        return 2
    design = parse_hwh(args.hwh)
    rows, findings, notes = check(design)

    if not args.quiet:
        cols = ["实例", "IP", "类型", "基址", "字节", "时钟"]
        widths = [max(_w(r[i]) for r in [cols] + rows) + 2 for i in range(len(cols))]
        print(f"{design.path.name}  device={design.system.get('device','?')}"
              f"{design.system.get('package','')}{design.system.get('speedgrade','')}"
              f"  arch={design.system.get('arch','?')}")
        print("  ".join(pad(c, w) for c, w in zip(cols, widths)))
        for r in rows:
            print("  ".join(pad(str(c), w) for c, w in zip(r, widths)))
        if notes:
            print("\n时钟：" + "；".join(notes))
        print()

    fails = [f for f in findings if f[0] == "FAIL"]
    warns = [f for f in findings if f[0] == "WARN"]
    for level, code, text in findings:
        if level != "NOTE" or not args.quiet:
            print(f"[{level}] {code}: {text}")

    if args.diff:
        other = parse_hwh(args.diff)
        mine = {ip.instance for ip in design.ips}
        theirs = {ip.instance for ip in other.ips}
        print(f"\n对比 {other.path.name}：")
        print(f"  只在 {design.path.name}: {sorted(mine - theirs) or '—'}")
        print(f"  只在 {other.path.name}: {sorted(theirs - mine) or '—'}")
        ma = {r.instance: r.base for ip in design.ips for r in ip.ranges}
        oa = {r.instance: r.base for ip in other.ips for r in ip.ranges}
        moved = [(k, ma[k], oa[k]) for k in sorted(set(ma) & set(oa)) if ma[k] != oa[k]]
        for inst, a, b in moved:
            print(f"  地址变化 {inst}: 0x{a:08X} → 0x{b:08X}")
        if not moved:
            print("  地址一致")

    if args.json:
        payload = {
            "file": str(design.path),
            "system": design.system,
            "ips": [
                {
                    "instance": ip.instance, "ip": ip.fullname, "version": ip.version,
                    "type": ip.iptype,
                    "address": [
                        {"base": r.base, "high": r.high, "size": r.size, "memtype": r.memtype}
                        for r in ip.ranges
                    ],
                    "clocks": {k: {"mhz": v[0], "domain": v[1]} for k, v in ip.clk_domains.items()},
                    "registers": [
                        {"name": n, "offset": o, "access": a} for n, o, a in ip.registers
                    ],
                }
                for ip in design.ips
            ],
            "findings": [{"level": l, "code": c, "text": t} for l, c, t in findings],
            "status": "fail" if fails else ("warn" if warns else "pass"),
        }
        args.json.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")

    if args.md:
        lines = [f"# {design.path.name} 地址表", "",
                 f"device: `{design.system.get('device','?')}`；"
                 f"arch: `{design.system.get('arch','?')}`", "",
                 "| 实例 | IP | 类型 | 基址 | 字节 | 时钟 |", "|---|---|---|---|---|---|"]
        for r in rows:
            lines.append("| " + " | ".join(str(c) for c in r) + " |")
        if findings:
            lines += ["", "## 判据", ""]
            lines += [f"- **{l}** `{c}` {t}" for l, c, t in findings]
        args.md.write_text("\n".join(lines) + "\n", encoding="utf-8")

    if fails:
        print(f"\n=> FAIL（{len(fails)} 项地址类问题，{len(warns)} 条警告）")
        return 1
    print(f"\n=> PASS（{len(design.ips)} 个 IP，{sum(len(ip.ranges) for ip in design.ips)} 段地址，"
          f"{len(warns)} 条警告）")
    if warns and args.lenient:
        print("[--lenient] 警告不判失败：这些是“要你去看一眼”的，不是“一定坏了”的")
        return 0
    return 1 if warns else 0


if __name__ == "__main__":
    sys.exit(main())
