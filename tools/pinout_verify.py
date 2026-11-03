#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pinout_verify.py —— 引脚方案终版校核（纯 stdlib，不依赖 pip / 不依赖 Vivado）

与 tools/pinplan_check.py 的分工
--------------------------------
· pinplan_check.py  —— 回答"**为什么**是这个插位"。
  它读厂商 .xls，比较 vendor 三套候选映射（J6/J7/J11 列）与板载占用表的
  冲突数，证明只有 vendor 的 J7 列（= Bank 16）落在本板真实排针上。
· 本脚本 —— 回答"**最终约束对不对**"。
  它对 constr/enc_top.xdc 做逐端口体检：球号存在性、bank 归属、重复分配、
  与板载外设冲突、未约束端口数。

数据来源（全部在工程根目录或本脚本内，可复现）
--------------------------------------------
1) _synth_work/pkgpins.csv —— Vivado 查器件封装得到的 484 个球的 bank 号
   （由 _synth_work/bankq4.tcl 生成：create_project -in_memory -> link_design
      -> get_package_pins ... get_property BANK）。
2) DLC35_io_occupancy.xlsx —— 本板 110 个已占用引脚（外设）。
3) constr/enc_top.xdc —— 待校核的约束文件。
4) 本脚本内嵌的两张针->球表（J6 / J5），来源：
   AD9238_carrier_schematic.pdf + 达芬奇-lite 原理图 sheet 13 的符号几何，
   由 tools/pdf_text.py --geom 量取；AD9238 侧另与 HSTAD9238_module_manual.pdf
   p9 §6 的针表互证。
   ★ 这两张表是"量出来的"，不是从厂商 .xls 抄的 —— 厂商 .xls 的 J7 列
     针号与本板 J6 排针 0/28 对得上，直接照抄会全错。

校核项
------
[A] Ball 存在性 —— XDC 里每个 PACKAGE_PIN 是否都在 FGG484 封装内
[B] Bank 归属 —— AD9238 组必须全在 Bank 16（J6）；其余扩展组必须全在 Bank 15（J5）
[C] 重复分配 —— 同一个球是否被分给多个端口 / 与板载专用端口撞车
[D] 板载外设冲突 —— 扩展口引脚是否命中了开发板自己的 110 引脚占用表
[E] 完整性 —— enc_top 的 49 个端口是否全部有 PACKAGE_PIN + IOSTANDARD
[F] 排针合法性 —— 每个球是否确实出现在 J6/J5 的针表里（防手误写错球号）

用法
----
    python tools/pinout_verify.py
    python tools/pinout_verify.py --xdc constr/enc_top.xdc

退出码：0 = RESULT: PASS；1 = RESULT: FAIL
"""
import argparse
import io
import os
import re
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PKGPINS = os.path.join(ROOT, "_synth_work", "pkgpins.csv")


def _find_input(names, subdirs=("", "_refs/vendor")):
    """按顺序找第一个存在的输入文件，返回绝对路径；都没有则返回 None。

    厂商原始文件（.xls/.xlsx/手册）**不随本仓库分发**：版权不属于本项目，且竞赛
    指南要求"仓库内所有目录名与文件名必须是纯英文"。故按"先 ASCII 名、再原名，
    先根目录、再 _refs/vendor/"查找；找不到时相关校核项标 SKIP 而不是报错退出。
    """
    for sub in subdirs:
        for n in names:
            p = os.path.join(ROOT, sub, n) if sub else os.path.join(ROOT, n)
            if os.path.exists(p):
                return p
    return None


# DLC35_io_occupancy.xlsx 是建议的 ASCII 名（与 00..13 的改名同批）
XLSX_IO = _find_input(["DLC35_io_occupancy.xlsx", "DLC35_io_occupancy.xlsx"])

# ---------------------------------------------------------------------------
# 内嵌针->球表（量取结果）
# ---------------------------------------------------------------------------
# 达芬奇-lite J6：Header_2*26，52 针，Bank 16，电源轨 VCCIO_B16（跳线 J10 选压）
#   1 = +5V（对载板的输入）、3 = VCCIO_B16、2/4/5 = GND
#   pins 6/7/8 未被量出（原理图几何未覆盖）—— 因此本工程不使用这三针
J6 = {
    9: "F16", 10: "E17", 11: "C13", 12: "B13", 13: "E16", 14: "D16",
    15: "A13", 16: "A14", 17: "D14", 18: "D15", 21: "C14", 22: "C15",
    23: "B15", 24: "B16", 26: "B18", 27: "F18", 28: "E18", 29: "C17",
    30: "D17", 31: "A18", 32: "A19", 33: "C18", 34: "C19", 35: "F20",
    36: "F19", 37: "B20", 38: "A20", 39: "E19",
}

# 达芬奇-lite J5：Header_2*26，52 针，Bank 15，电源轨 VCCIO_B15（跳线 J9 选压）
#   1 = +5V、3 = VCCIO_B15；5..52 全部是信号球
J5 = {
    5: "H20", 6: "G20", 7: "M21", 8: "L21", 9: "N22", 10: "M22",
    11: "N20", 12: "M20", 13: "L19", 14: "L20", 15: "J22", 16: "H22",
    17: "J20", 18: "J21", 19: "K21", 20: "K22", 21: "M15", 22: "M16",
    23: "L13", 24: "M13", 25: "K13", 26: "K14", 27: "J19", 28: "H19",
    29: "H14", 30: "J14", 31: "H17", 32: "H18", 33: "G13", 34: "H13",
    35: "G16", 36: "G15", 37: "K18", 38: "K19", 39: "N18", 40: "N19",
    41: "L18", 42: "M18", 43: "J17", 44: "K17", 45: "K16", 46: "L16",
    47: "L14", 48: "L15", 49: "H15", 50: "J15", 51: "G17", 52: "G18",
}
J6_BALL2PIN = {b: p for p, b in J6.items()}
J5_BALL2PIN = {b: p for p, b in J5.items()}

# 载板 J6 针 -> 网络名（HSTAD9238模块说明书 p9 §6 + AD9238V11 原理图 netlist，两源互证）
MODULE_NET = {
    1: "+5V", 2: "GND", 3: "不用", 4: "GND", 5: "GND",
    6: "不用", 7: "不用", 8: "不用",
    9: "CH2_CLK", 10: "CH2_D0", 11: "CH2_D1", 12: "CH2_D2", 13: "CH2_D3",
    14: "CH2_D4", 15: "CH2_D5", 16: "CH2_D6", 17: "CH2_D7", 18: "CH2_D8",
    19: "不用", 20: "不用",
    21: "CH2_D9", 22: "CH2_D10", 23: "CH2_D11", 24: "CH2_OTR", 25: "不用",
    26: "CH1_CLK", 27: "CH1_D0", 28: "CH1_D1", 29: "CH1_D2", 30: "CH1_D3",
    31: "CH1_D4", 32: "CH1_D5", 33: "CH1_D6", 34: "CH1_D7", 35: "CH1_D8",
    36: "CH1_D9", 37: "CH1_D10", 38: "CH1_D11", 39: "CH1_OTR", 40: "不用",
}

# 载板网络名 -> enc_top 端口（AD2CLK 有独立端口 ad_clk2，因为两根网络独立）
NET2PORT = {"CH1_CLK": "ad_clk", "CH2_CLK": "ad_clk2",
            "CH1_OTR": "ad_ch1_otr", "CH2_OTR": "ad_ch2_otr"}
for _i in range(12):
    NET2PORT["CH1_D%d" % _i] = "ad_ch1_d[%d]" % _i
    NET2PORT["CH2_D%d" % _i] = "ad_ch2_d[%d]" % _i

# 板载专用端口（这些引脚本板自带外设，bank 34 / 14）
ONBOARD = {
    "sys_clk": ("V4", "34", "板载 50MHz 晶振"),
    "key_n": ("W9", "34", "板载用户按键 KEY0（低有效）"),
    "led[0]": ("AB21", "14", "板载用户 LED0"),
    "led[1]": ("AB22", "14", "板载用户 LED1"),
    "uart_tx": ("W21", "14", "板载 USB 串口 TXD（CH340E）"),
    # UART→SPI 桥新增的接收脚：板载 USB 串口 RXD（CH340E，bank 14）。
    # ★ 之前 design 里没有 uart_rx，2026-10-10 加桥时新增；占用表里就是 uart_rxd。
    "uart_rx": ("T20", "14", "板载 USB 串口 RXD（CH340E）"),
}

BALL_RE = re.compile(r"^[A-Z]{1,2}\d{1,2}$")


def load_pkgpins(path):
    """_synth_work/pkgpins.csv -> {ball: bank}。"""
    out = {}
    if not os.path.exists(path):
        return out
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            p = [x.strip() for x in re.split(r"[,;\t]", ln) if x.strip()]
            if len(p) >= 2 and BALL_RE.match(p[0]):
                out[p[0]] = p[1]
    return out


def load_occupied(path):
    """DLC35_io_occupancy.xlsx（开发板 IO 引脚分配表）-> {ball: 描述}。"""
    out = {}
    if not path or not os.path.exists(path):
        return out
    try:
        import openpyxl
    except ImportError:
        return out
    wb = openpyxl.load_workbook(path, data_only=True)
    for ws in wb.worksheets:
        for row in ws.iter_rows(values_only=True):
            v = [str(c).strip() for c in row if c is not None]
            for i, x in enumerate(v):
                if BALL_RE.match(x) and i + 1 < len(v):
                    out.setdefault(x, " | ".join(v[:i + 2]))
    return out


def parse_xdc(path):
    r"""返回 [(ball, iostandard, port)]，逐行解析 PACKAGE_PIN 语句。

    ★ 坑 1：不能"按 set_property 切分文件再在每段里各找一次" ——
      某个 `PACKAGE_PIN` 行前面若还有 `set_input_delay … [get_ports {a[*] b[*]}]`
      之类的语句，它会被算进同一段，于是"第一处 [get_ports]"命中前面那条语句，
      引脚与端口就张冠李戴（实测 B16 被配给了 ad_ch1_otr 而不是 ad_ch2_otr）。
      所以必须**逐行**处理。
    ★ 坑 2：端口名外面套了一层花括号，且名字自身含方括号（总线位）。
      `\[get_ports\s+(.*?)\]` 非贪婪会在内层 `[0]` 处停住，把
      `{ad_ch1_d[0]}` 截成 `{ad_ch1_d[0`；改用贪婪又会吞掉后续内容。
      正确做法：先试 `\\{([^{}]*)\\}`（最外层花括号内可含方括号），
      失败再退回无花括号的裸名 `([^\\]\\s]+)`。
    ★ 坑 3：含 `[*]` 或空格分隔多端口的行是"批量约束"，
      它们不参与"每个端口各自一个球号"的校核（由调用方跳过）。
    """
    rows = []
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            if "PACKAGE_PIN" not in raw:
                continue
            line = raw.split(";#")[0]
            line = re.sub(r"(?<!\S)#.*$", "", line)      # 去掉行尾注释
            pin_m = re.search(r"PACKAGE_PIN\s+([A-Z]{1,2}\d{1,2})(?![A-Z0-9])", line)
            if not pin_m:
                continue
            std_m = re.search(r"IOSTANDARD\s+(\w+)", line)
            port_m = re.search(r"\[get_ports\s+\{([^{}]*)\}", line)
            if not port_m:
                port_m = re.search(r"\[get_ports\s+([^\]\s]+)\]", line)
            if not port_m:
                continue
            port = port_m.group(1)
            port = port.replace("{", " ").replace("}", " ")
            port = " ".join(port.split())
            if "*" in port or " " in port:
                continue                                  # 批量约束行，跳过
            rows.append((pin_m.group(1), std_m.group(1) if std_m else "?", port))
    return rows


def strip_inactive_ifdefs(txt, defines=()):
    """按"生产构建不定义任何宏"的口径，剔除未生效的条件编译区。

    为什么需要这一步：`rtl/enc_top.v` 里出现了**被 `ifdef 门控的端口声明**
    （`ENC_DISP_TAP` 门控的 `disp_tap[133:0]` 只读抽头，实验专用）。
    端口解析器若按原文正则扫描，会把这 134 位当成"生产端口"，于是报出
    134 项"未约束"，把 [E] 项判红 —— 而生产构建里这些位根本不存在。

    语义按 Verilog 最小值实现（只需支持本仓用到的 ifdef/ifndef/elsif/else/endif）：
      `ifdef X   -> 未定义 X 时整区失效（本函数默认 defines 为空 ⇒ 失效）
      `ifndef X  -> 未定义 X 时整区生效
      `elsif X   -> 同 ifdef
      `else      -> 翻转
      `endif     -> 结束
    嵌套用栈处理。
    """
    defs = set(defines)
    out = []
    # 栈元素: [当前是否输出, 本层是否已经取过某个分支]
    stack = []
    live = True
    for line in txt.splitlines():
        s = line.strip()
        m = re.match(r"`(ifdef|ifndef|elsif)\s+(\w+)", s)
        if m:
            kind, macro = m.group(1), m.group(2)
            if kind == "elsif":
                if not stack:
                    continue
                taken = stack[-1][1]
                ok = (macro in defs) and not taken
                stack[-1][0] = ok
                stack[-1][1] = taken or ok
            else:
                ok = (macro in defs) if kind == "ifdef" else (macro not in defs)
                stack.append([ok, ok])
            live = all(e[0] for e in stack)
            continue
        if re.match(r"`else\b", s):
            if stack:
                stack[-1][0] = not stack[-1][1]
                stack[-1][1] = True
            live = all(e[0] for e in stack)
            continue
        if re.match(r"`endif\b", s):
            if stack:
                stack.pop()
            live = all(e[0] for e in stack)
            continue
        if live:
            out.append(line)
    return "\n".join(out)


def parse_rtl_ports(path):
    """从 rtl/enc_top.v 的端口声明里抓出所有名字（含总线展开）。

    ★ 先剔掉未生效的条件编译区（见 strip_inactive_ifdefs）：本函数算的是
      "**生产构建**的端口清单"，实验专用端口（`ENC_DISP_TAP`）不算在内。
    """
    txt = io.open(path, encoding="utf-8", errors="replace").read()
    txt = strip_inactive_ifdefs(txt)
    head = txt.split(");", 1)[0]
    names = []
    # 去掉注释后按逗号切
    head = re.sub(r"//[^\n]*", "", head)
    head = re.sub(r"/\*.*?\*/", "", head, flags=re.S)
    for chunk in head.split(","):
        chunk = chunk.strip()
        if not chunk or chunk.startswith("module"):
            continue
        # input/output/inout [msb:lsb] [signed] name
        m = re.search(r"\b(input|output|inout)\b\s*"
                      r"(?:wire|reg|logic)?\s*"
                      r"(?:signed\s*)?"
                      r"(?:\[\s*[^\]]+\]\s*)?"
                      r"([A-Za-z_]\w*)", chunk)
        if not m:
            continue
        name = m.group(2)
        rng = re.search(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", chunk)
        if rng:
            a, b = int(rng.group(1)), int(rng.group(2))
            for i in range(min(a, b), max(a, b) + 1):
                names.append("%s[%d]" % (name, i))
        else:
            names.append(name)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xdc", default=os.path.join(ROOT, "constr", "enc_top.xdc"))
    ap.add_argument("--rtl", default=os.path.join(ROOT, "rtl", "enc_top.v"))
    args = ap.parse_args()

    pkg = load_pkgpins(PKGPINS)
    occ = load_occupied(XLSX_IO)
    rows = parse_xdc(args.xdc)
    print("=" * 74)
    print(" 引脚方案终版校核  (tools/pinout_verify.py)")
    print("=" * 74)
    print("  XDC            : %s" % os.path.relpath(args.xdc, ROOT))
    print("  封装 bank 数据 : %s  (%d 个球)" % (os.path.relpath(PKGPINS, ROOT), len(pkg)))
    if XLSX_IO:
        print("  板载占用表     : %s  (%d 个球)" % (os.path.relpath(XLSX_IO, ROOT), len(occ)))
    else:
        print("  板载占用表     : **未找到**（[D] 的占用冲突数将标 SKIP）")
    print("  XDC 约束端口   : %d 个" % len(rows))
    print()

    fails = []

    # --- [A] ball 存在性 ---------------------------------------------------
    print("[A] Ball 存在性（是否都在 xc7a35tfgg484 封装内）")
    bad = [r for r in rows if pkg and r[0] not in pkg]
    if bad:
        for b, _, p in bad:
            print("    !! %-6s (%s) 不在封装内" % (b, p))
        fails.append("A")
    else:
        print("    ✓ %d/%d 个球都存在于封装内" % (len(rows), len(rows)))
    print()

    # --- [B] bank 归属 ----------------------------------------------------
    print("[B] Bank 归属")
    j6_ports = {NET2PORT[n] for n in MODULE_NET.values() if n in NET2PORT}
    print("    AD9238 组（J6 / Bank 16）—— 期望 bank == 16")
    b16ok = b16bad = 0
    for ball, _, port in sorted(rows, key=lambda r: r[2]):
        if port not in j6_ports:
            continue
        bank = pkg.get(ball, "?")
        if bank == "16":
            b16ok += 1
        else:
            b16bad += 1
            print("      !! %-12s %-6s bank=%s" % (port, ball, bank))
    print("      ✓ %d 个在 Bank 16，%d 个不符" % (b16ok, b16bad))
    if b16bad:
        fails.append("B/J6")

    j5_ports = {p for _, _, p in rows} - j6_ports - set(ONBOARD)
    print("    J5 扩展组（ABZ/SPI/led[2:3]/irq_n）—— 期望 bank == 15")
    b15ok = b15bad = 0
    for ball, _, port in sorted(rows, key=lambda r: r[2]):
        if port not in j5_ports:
            continue
        bank = pkg.get(ball, "?")
        if bank == "15":
            b15ok += 1
        else:
            b15bad += 1
            print("      !! %-12s %-6s bank=%s" % (port, ball, bank))
    print("      ✓ %d 个在 Bank 15，%d 个不符" % (b15ok, b15bad))
    if b15bad:
        fails.append("B/J5")
    for port, (ball, bank, desc) in sorted(ONBOARD.items()):
        got = pkg.get(ball, "?")
        mark = "✓" if got == bank else "!!"
        print("    %s 板载 %-9s %-6s bank=%-3s (%s)" % (mark, port, ball, got, desc))
        if got != bank:
            fails.append("B/board:" + port)
    print()

    # --- [C] 重复分配 ------------------------------------------------------
    print("[C] 重复分配检查")
    seen = {}
    dup = 0
    for ball, _, port in rows:
        if ball in seen:
            print("    !! 球 %s 同时分给 %s 与 %s" % (ball, seen[ball], port))
            dup += 1
        seen[ball] = port
    if dup:
        fails.append("C")
    else:
        print("    ✓ 无重复（%d 个端口用了 %d 个不同球）" % (len(rows), len(seen)))
    print()

    # --- [D] 板载外设冲突 --------------------------------------------------
    print("[D] 与板载 110 引脚占用表的冲突")
    clash = []
    for ball, _, port in rows:
        if port in ONBOARD:
            continue                       # 板载专用端口本来就该命中占用表
        if ball in occ:
            clash.append((port, ball, occ[ball]))
    if clash:
        for port, ball, desc in clash:
            print("    !! %-12s %-6s 已被外设占用: %s" % (port, ball, desc))
        fails.append("D")
    elif not occ:
        print("    —— SKIP：无板载占用表，未做冲突判定（不是 PASS，也不是 FAIL）")
    else:
        print("    ✓ 扩展口引脚 0 个命中板载占用表（全部空闲）")
    print()

    # --- [E] 完整性 --------------------------------------------------------
    print("[E] 端口完整性（enc_top 的端口是否都有 PACKAGE_PIN + IOSTANDARD）")
    rtl_ports = parse_rtl_ports(args.rtl)
    constrained = {p for _, _, p in rows}
    missing = [p for p in rtl_ports if p not in constrained]
    print("    RTL 端口数 %d ；已约束 %d ；未约束 %d" % (len(rtl_ports), len(constrained), len(missing)))
    if missing:
        for p in missing:
            print("      !! 未约束: %s" % p)
        fails.append("E")
    else:
        print("    ✓ 全部端口都有引脚约束 —— 不会触发 UCIO-1")
    bad_std = [r for r in rows if r[1] != "LVCMOS33"]
    if bad_std:
        for ball, std, port in bad_std:
            print("    !! %-12s %s IOSTANDARD=%s（期望 LVCMOS33）" % (port, ball, std))
        fails.append("E/std")
    else:
        print("    ✓ 全部端口 IOSTANDARD = LVCMOS33（J6/J5 跳线到 3.3V 后成立）")
    print()

    # --- [F] 排针合法性 ----------------------------------------------------
    print("[F] 排针合法性（每个球是否真的在 J6/J5 的针表里）")
    offj6 = offj5 = 0
    for ball, _, port in rows:
        if port in ONBOARD:
            continue
        if port in j6_ports:
            if ball not in J6_BALL2PIN:
                print("    !! %-12s %s 不在 J6 针表里" % (port, ball))
                offj6 += 1
        elif port in j5_ports:
            if ball not in J5_BALL2PIN:
                print("    !! %-12s %s 不在 J5 针表里" % (port, ball))
                offj5 += 1
    print("      J6 越界 %d 个 ；J5 越界 %d 个" % (offj6, offj5))
    if offj6 or offj5:
        fails.append("F")
    else:
        print("    ✓ 全部扩展口球号都能在针表里定位（防手误写错球号）")
    print()

    # --- 载板 28 网络覆盖 --------------------------------------------------
    print("[G] 载板 28 个信号的全覆盖核对（模块说明书的针表 -> XDC）")
    covered = 0
    for pin in sorted(MODULE_NET):
        net = MODULE_NET[pin]
        if net not in NET2PORT:
            continue
        port = NET2PORT[net]
        ball = None
        for b, _, p in rows:
            if p == port:
                ball = b
                break
        expect = J6.get(pin)
        mark = "✓" if (expect and ball == expect) else "!!"
        if mark == "✓":
            covered += 1
        print("    %s J6-%-2d %-9s -> %-12s %-5s (期望 %s)"
              % (mark, pin, net, port, ball or "缺", expect or "?"))
    print("    %d/%d 逐个一致" % (covered, len([n for n in MODULE_NET.values() if n in NET2PORT])))
    if covered != len([n for n in MODULE_NET.values() if n in NET2PORT]):
        fails.append("G")
    print()

    verdict = "PASS" if not fails else "FAIL"
    print("=" * 74)
    if fails:
        print(" RESULT: FAIL  —— 未通过项: %s" % ", ".join(fails))
    else:
        print(" RESULT: PASS")
        print("  · %d 个端口全部有球号 + IOSTANDARD，可以生成 bitstream" % len(rows))
        print("  · AD9238 28 个信号全部落 Bank 16（J6），且与模块针表逐一致")
        print("  · ABZ/SPI/led[2:3]/irq_n 全部落 Bank 15（J5），板载占用表 %s"
              % ("0 冲突" if occ else "**未校核**（无表）"))
        print("  · ★ 上电前必须把 J10 (VCCIO_B16) 与 J9 (VCCIO_B15) 都拨到 3.3V")
    print("=" * 74)
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
