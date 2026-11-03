#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PYNQ host 侧的最小驱动骨架：寄存器读写 + DMA 回环 + 用 PL 周期计数测吞吐。

同一份代码有两种传输层：
  * `MockTransport`：不装 PYNQ、不接板卡也能跑通全流程（CI/答辩机器/写报告时）。
  * `PynqTransport`：真板子上用 `pynq.Overlay` + `pynq.allocate` + DMA。
判据只写一次，两种传输层共用——于是"逻辑对不对"和"硬件在不在"被解耦了。

【适用】
  任何"PL 算、PS 收"的 PYNQ 工程：先把 host 侧判据在 mock 上跑通，再上板。
  换题目只需换 `MockTransport` 里的设备模型与 `--map` 里的地址表。

【用法】
  python skill/pynq/pynq_overlay.py --mock                       # 无板卡跑全流程
  python skill/pynq/pynq_overlay.py --mock --json %TEMP%/r.json    # 机器可读结果
  python skill/pynq/pynq_overlay.py --selftest                    # 只跑内建自检
  python skill/pynq/pynq_overlay.py --overlay out/design_1.bit --map map.json   # 上板
  python skill/pynq/pynq_overlay.py --overlay ... --dma axi_dma_0 --count 4096

【输入格式与退出码】
  `--map`：`pynq_hwh.py --json` 的产物（含 ips[].instance / address[].base）。
  `--overlay`：`.bit`（PYNQ 要求同目录有同名 `.hwh`）。
  退出码：0 回环与寄存器都通过；1 有不一致；2 环境不满足（无 pynq / 文件缺失）。

【为什么要有这个脚本】
  上板调试最贵的错误是"读回全 0 却以为逻辑错了"。本队在这类事上踩过：
  记录 1（测试台空转）、记录 47（三条"看起来 PASS 其实没测到"的断言）、
  记录 58/59（判据读到上一帧/旧值）。搬到 PYNQ 上，等价的三件事是：
  ① 地址解码没通（读回 0）② DMA 没真搬（buffer 里是旧数据）
  ③ 用 `time.time()` 测吞吐（把 Python 开销算进硬件）。
  这个文件把三件事各做成一条判据，且都能在 mock 上先跑一遍。

【失效条件】
  1) mock 通过**不能**证明硬件通过：它只证明判据逻辑自洽。上板必须再跑一次。
  2) 传输层的设备模型是按本包 `MockTransport` 编的（CTRL/STATUS/SAMPLE/
     COUNT/CYCLES 五个寄存器）；你的 IP 寄存器表不同，要改 `MockDevice`。
  3) 中断模式没有覆盖（只做轮询）；用中断要另写 `wait()` 线程与超时判据。
  4) `--overlay` 路径需要目标机器装了 pynq（版本 2.7 或 3.x）；本包作者没有
     PYNQ 板卡，这条路径**未在本队硬件上实测**，只按官方 API 写。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------- 判据

def make_pattern(n: int, seed: int = 0x1234_5678) -> list[int]:
    """确定性激励：LCG，不依赖 random 的版本行为。"""
    out, x = [], seed & 0xFFFF_FFFF
    for _ in range(n):
        x = (1103515245 * x + 12345) & 0xFFFF_FFFF
        out.append(x)
    return out


def device_transform(words: list[int]) -> list[int]:
    """被测 IP 的约定行为：每 4 个数取反一次最低位——足够抓"顺序错/丢数/少搬"。"""
    return [w ^ 1 if i % 4 == 3 else w for i, w in enumerate(words)]


@dataclass
class LoopResult:
    ok: bool
    checks: list
    words: int = 0
    cycles: int | None = None
    throughput_mbps: float | None = None
    first_bad: int | None = None
    notes: list = field(default_factory=list)


# --------------------------------------------------------------------- 传输层（mock）

class MockDevice:
    """五个寄存器的假设备：与 templates/overlay_app.py 的寄存器表一致。"""

    REG_CTRL = 0x00
    REG_STATUS = 0x04
    REG_SAMPLE = 0x08
    REG_COUNT = 0x0C
    REG_CYCLES = 0x10

    def __init__(self, clk_mhz: float = 100.0):
        self.clk_mhz = clk_mhz
        self.regs = {self.REG_CTRL: 0, self.REG_STATUS: 0, self.REG_SAMPLE: 0,
                     self.REG_COUNT: 0, self.REG_CYCLES: 0}
        self.cycles = 0
        self.dma_words = 0
        self.decoded = True          # 关掉它可模拟"地址没解对"

    def read(self, off: int) -> int:
        self.cycles += 2
        if not self.decoded:
            return 0
        return self.regs.get(off & ~3, 0) & 0xFFFF_FFFF

    def write(self, off: int, value: int) -> None:
        self.cycles += 2
        if not self.decoded:
            return
        off &= ~3
        self.regs[off] = value & 0xFFFF_FFFF
        if off == self.REG_CTRL and (value & 1):
            self.regs[self.REG_STATUS] = 1          # 启动即完成（mock）
            self.regs[self.REG_CYCLES] = self.cycles

    def run_dma(self, words: list[int]) -> list[int]:
        self.cycles += len(words)                 # 1 word/clk 的简化模型
        self.dma_words += len(words)
        self.regs[self.REG_COUNT] = len(words)
        self.regs[self.REG_CYCLES] = self.cycles
        if not self.decoded:
            return [0] * len(words)                 # 典型故障：全是 0
        return device_transform(words)


class MockTransport:
    kind = "mock"

    def __init__(self, clk_mhz: float = 100.0, decoded: bool = True):
        self.dev = MockDevice(clk_mhz)
        self.dev.decoded = decoded

    def read(self, inst: str, off: int) -> int:
        return self.dev.read(off)

    def write(self, inst: str, off: int, value: int) -> None:
        self.dev.write(off, value)

    def dma_run(self, inst: str, words: list[int]) -> list[int]:
        return self.dev.run_dma(words)

    def cycles(self) -> int | None:
        return self.dev.cycles

    def clk_mhz(self) -> float:
        return self.dev.clk_mhz

    def close(self) -> None:
        pass


# ------------------------------------------------------------------ 传输层（真板卡）

class PynqTransport:                      # pragma: no cover - 需要板卡
    kind = "pynq"

    def __init__(self, overlay_path: Path, dma_name: str = "axi_dma_0",
                 dev_name: str = "gpio_regs", clk_mhz: float = 100.0):
        from pynq import Overlay, allocate           # 只有真机才 import
        self.overlay = Overlay(str(overlay_path))
        self.dev = getattr(self.overlay, dev_name)
        self.dma = getattr(self.overlay, dma_name, None)
        self.allocate = allocate
        self.clk = clk_mhz
        self._bufs = []

    def read(self, inst: str, off: int) -> int:
        return int(self.dev.read(off)) & 0xFFFF_FFFF

    def write(self, inst: str, off: int, value: int) -> None:
        self.dev.write(off, int(value) & 0xFFFF_FFFF)

    def dma_run(self, inst: str, words: list[int]) -> list[int]:
        import numpy as np
        if self.dma is None:
            raise SystemExit("[EXIT2] overlay 里没有 DMA：本脚本的 --dma 名字不对，"
                             "或者你的设计只有 MMIO")
        n = len(words)
        src = self.allocate(shape=(n,), dtype=np.uint32)
        dst = self.allocate(shape=(n,), dtype=np.uint32)
        try:
            src[:] = np.asarray(words, dtype=np.uint32)
            src.flush()                     # 不 flush，DMA 读到的是旧缓存
            self.dma.recvchannel.transfer(dst)
            self.dma.sendchannel.transfer(src)
            self.dma.recvchannel.wait()
            self.dma.sendchannel.wait()
            dst.invalidate()                # 不 invalidate，CPU 读到的是旧缓存
            return [int(x) for x in dst]
        finally:
            del src, dst

    def cycles(self) -> int | None:
        reg = getattr(self.dev, "register_map", None)
        if reg is not None and hasattr(reg, "CYCLES"):
            return int(reg.CYCLES)
        return None                          # 没有计数器就承认测不了，不用墙钟凑数

    def clk_mhz(self) -> float:
        return self.clk

    def close(self) -> None:
        pass


# --------------------------------------------------------------------------- 判据

CHECK_NAMES = ["寄存器读回", "设备就绪", "DMA 回环", "逐点比对", "计数一致"]


def run_loopcheck(tp, inst: str = "gpio_regs", count: int = 512) -> LoopResult:
    checks = []
    notes = []

    # 1) 读回 Walking ones：抓地址解码错误（读回 0 或别的 IP 的值）
    pat = [0x1, 0x2, 0x4, 0x8, 0x10, 0x8000_0000]
    bad = []
    for v in pat:
        tp.write(inst, MockDevice.REG_SAMPLE, v)
        got = tp.read(inst, MockDevice.REG_SAMPLE)
        if got != v:
            bad.append((v, got))
    checks.append({"name": CHECK_NAMES[0], "ok": not bad,
                   "detail": "SAMPLES 读回一致" if not bad else f"{bad[:3]}"})

    # 2) 启动位：写 1 后 STATUS 必须置位
    tp.write(inst, MockDevice.REG_CTRL, 1)
    st = tp.read(inst, MockDevice.REG_STATUS)
    checks.append({"name": CHECK_NAMES[1], "ok": bool(st & 1),
                   "detail": f"STATUS=0x{st:X}"})

    # 3) DMA 回环 + 4) 逐点比对
    words = make_pattern(count)
    got = tp.dma_run(inst, words)
    same_len = len(got) == len(words)
    checks.append({"name": CHECK_NAMES[2], "ok": same_len,
                   "detail": f"发出 {len(words)} 收 {len(got)}"})
    want = device_transform(words)
    first_bad = None
    for i, (a, b) in enumerate(zip(want, got)):
        if a != b:
            first_bad = i
            break
    checks.append({"name": CHECK_NAMES[3], "ok": first_bad is None,
                   "detail": "全等" if first_bad is None
                   else f"第 {first_bad} 个数：期望 0x{want[first_bad]:08X} "
                        f"实测 0x{got[first_bad]:08X}"})
    if same_len and len(set(got)) == 1 and got and got[0] == 0:
        notes.append("收全 0：先怀疑地址没解对或 DMA 没启动，而不是算法")

    # 5) 计数字段与出数点数一致
    cnt = tp.read(inst, MockDevice.REG_COUNT)
    checks.append({"name": CHECK_NAMES[4], "ok": cnt == len(words),
                   "detail": f"COUNT={cnt} 期望 {len(words)}"})

    cycles = tp.cycles()
    mbps = None
    if cycles:
        # 字节 * 时钟频率 / 周期 = MB/s（含单位换算：B/µs == MB/s）
        mbps = (len(words) * 4) * tp.clk_mhz() / cycles
    else:
        notes.append("没有 PL 周期计数器：吞吐不测（不用墙上时间凑数）")

    return LoopResult(ok=all(c["ok"] for c in checks), checks=checks, words=len(words),
                      cycles=cycles, throughput_mbps=mbps, first_bad=first_bad,
                      notes=notes)


# ---------------------------------------------------------------------------- main

def _selftest() -> int:
    """内建自检：好设备必须 PASS，三种坏设备必须 FAIL 且理由正确。"""
    cases = []
    good = run_loopcheck(MockTransport())
    cases.append(("正常设备", True, good))

    dead = run_loopcheck(MockTransport(decoded=False))
    cases.append(("地址没解对（读回全 0）", False, dead))

    tp = MockTransport()
    original = tp.dev.run_dma
    tp.dev.run_dma = lambda ws: original(ws)[1:] + [0]      # 丢一个数
    shifted = run_loopcheck(tp)
    cases.append(("DMA 少搬/错位", False, shifted))

    tp2 = MockTransport()
    orig_t = tp2.dev.run_dma
    tp2.dev.run_dma = lambda ws: [w ^ 2 for w in orig_t(ws)]  # 行为不对
    wrong = run_loopcheck(tp2)
    cases.append(("逻辑错（最低位翻转多一位）", False, wrong))

    bad = 0
    for name, expect, res in cases:
        ok = res.ok is expect
        bad += 0 if ok else 1
        print(f"  [{'OK' if ok else 'XX'}] {name}: ok={res.ok}（期望 {expect}）"
              + ("" if ok else f" ← {[c for c in res.checks if not c['ok']]}"))
    print(f"=> {'PASS' if bad == 0 else 'FAIL'} 自检 {len(cases) - bad}/{len(cases)}")
    return 0 if bad == 0 else 1


EMIT_TEMPLATE = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在你自己的 PYNQ 板子上跑这一步 —— 由 skill/pynq/pynq_overlay.py --emit-script 生成。

这份脚本是**骨架**：寄存器名字/偏移/位定义要按你自己的 IP 改（见下面的 TODO）。
它自带 5 条"必须同时为真"的判据，以及一张可以填上板记录的 CSV 表。

用法（板卡上的 Jupyter / ssh 都行）：
    python {script_name}                 # 跑一遍，打印 5 条判据
    python {script_name} --record        # 顺便把结果追加到 bringup_record.csv

生成参数：--dev {dev} --dma {dma} --clk-mhz {clk:g} --count {count} --bit-name {bit}
生成时间：{stamp}

为什么不是"打印 PASS 就算过"：
  记录 47/49 —— "下载成功""灯亮""没报错"这三条都不构成判据。
  下面每一条都要求一个**能被推翻的数**：读回值、长度、逐点比对、计数器。
"""
from __future__ import annotations

import argparse
import csv
import time
from pathlib import Path

BIT_NAME = {bit!r}
DEV = {dev!r}
DMA = {dma!r}
CLK_MHZ = {clk!r}
COUNT = {count!r}

# TODO: 按你的 IP 寄存器手册改这三行；偏移不要从 .hwh 里找（Vivado 默认不导出寄存器）
REG_CTRL = 0x00
REG_STATUS = 0x04
REG_COUNT = 0x0C

HERE = Path(__file__).resolve().parent
OVERLAY = HERE / BIT_NAME


def make_pattern(n, seed=0x12345678):
    out, x = [], seed
    for _ in range(n):
        x = (1103515245 * x + 12345) & 0xFFFF
        out.append(x)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--record", action="store_true")
    args = ap.parse_args()

    from pynq import Overlay, allocate          # 只在板卡上有

    ol = Overlay(str(OVERLAY))
    dev = ol.{dev}
    dma = ol.{dma}
    checks = []

    # 判据 1：寄存器读回（Walking-ones，读回必须与原值一致）
    walking = [0x1, 0x2, 0x4, 0x8, 0x10, 0x80000000]
    ok1 = all((dev.write(REG_CTRL, v), dev.read(REG_CTRL) & v == v)[1] for v in walking)
    checks.append(("寄存器 walking-ones 读回", ok1, "6 个位型"))

    # 判据 2：写 CTRL 之后 STATUS.bit0 必须置起（证明时钟/复位通）
    dev.write(REG_CTRL, 0x1)
    ok2 = bool(dev.read(REG_STATUS) & 0x1)
    checks.append(("STATUS.bit0 置起", ok2, f"读回 0x{{dev.read(REG_STATUS):08X}}"))

    # 判据 3：DMA 收发长度一致
    n = int(COUNT)
    words = make_pattern(n)
    buf_in = allocate(shape=(n,), dtype="u4")
    buf_out = allocate(shape=(n,), dtype="u4")
    for i, w in enumerate(words):
        buf_in[i] = w
    buf_in.flush()
    t0 = time.perf_counter()
    dma.recvchannel.transfer(buf_out)
    dma.sendchannel.transfer(buf_in)
    dma.sendchannel.wait()
    dma.recvchannel.wait()
    buf_out.invalidate()
    wall_ms = (time.perf_counter() - t0) * 1e3
    got = [int(buf_out[i]) for i in range(n)]
    ok3 = len(got) == n
    checks.append(("DMA 收发长度", ok3, f"发 {{n}} 收 {{len(got)}}"))

    # 判据 4：逐点比对（这里假定"硬件不改数据"；你的 DUT 有变换就改 expected）
    expected = words
    first_bad = next((i for i, (a, b) in enumerate(zip(expected, got)) if a != b), None)
    ok4 = first_bad is None
    checks.append(("逐点比对", ok4,
                   "全部一致" if ok4 else f"首个坏点 #{{first_bad}}: 期望 {{expected[first_bad]}} 实测 {{got[first_bad]}}"))

    # 判据 5：硬件计数器与点数一致（没有计数器就明确说"这条不适用"，别用墙钟凑）
    cnt = dev.read(REG_COUNT)
    ok5 = cnt == n
    checks.append(("硬件计数 == 点数", ok5, f"计数 {{cnt}} vs 点数 {{n}}"))

    for name, ok, detail in checks:
        print(f"  [{{'OK' if ok else 'XX'}}] {{name}}: {{detail}}")
    print(f"  [NOTE] 墙钟 {{wall_ms:.1f}} ms 不作判据（P-15：wall clock 会把 DMA 启动开销算进去）")
    passed = all(c[1] for c in checks)
    print(f"=> {{'PASS' if passed else 'FAIL'}}（{{sum(c[1] for c in checks)}}/{{len(checks)}} 条判据）")

    if args.record:
        path = Path("bringup_record.csv")
        new = not path.exists()
        with path.open("a", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            if new:
                w.writerow(["时间", "位流", "点数", "墙钟ms", "判据通过", "结论"])
            w.writerow([time.strftime("%Y-%m-%dT%H:%M:%S"), BIT_NAME, n,
                        f"{{wall_ms:.1f}}", f"{{sum(c[1] for c in checks)}}/{{len(checks)}}",
                        "PASS" if passed else "FAIL"])
        print(f"  记录已追加到 {{path.resolve()}}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
'''


def emit_script(path: Path, dev: str, dma: str, clk: float, count: int, bit: str) -> int:
    """把上面那份骨架写到 path；不连板卡、不需要 pynq 库。"""
    import datetime
    body = EMIT_TEMPLATE.format(
        script_name=path.name, dev=dev, dma=dma, clk=float(clk), count=int(count), bit=bit,
        stamp=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8", newline="\n")
    # 生成物必须能被解释器读进去：语法错在板卡上才发现最费时间
    try:
        compile(body, str(path), "exec")
    except SyntaxError as exc:
        print(f"[EXIT2] 生成的脚本有语法错（模板写坏了）：{exc}")
        return 2
    print(f"已生成 {path}（{len(body.splitlines())} 行）")
    print("  下一步：把 REG_CTRL/REG_STATUS/REG_COUNT 改成你自己 IP 的偏移，再拷到板卡上跑")
    print("  它自带 5 条判据；--record 会往 bringup_record.csv 追加一行，方便贴进报告")
    return 0


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass

    ap = argparse.ArgumentParser(description="PYNQ host 侧回环判据（可在无板卡上跑）")
    ap.add_argument("--mock", action="store_true", help="用假设备跑（默认行为）")
    ap.add_argument("--selftest", action="store_true", help="只跑内建自检")
    ap.add_argument("--overlay", type=Path, help="真板卡：.bit 路径（同目录需有 .hwh）")
    ap.add_argument("--map", type=Path, help="pynq_hwh.py --json 的产物（可选，仅用于打印地址）")
    ap.add_argument("--dma", default="axi_dma_0")
    ap.add_argument("--dev", default="gpio_regs")
    ap.add_argument("--clk-mhz", type=float, default=100.0)
    ap.add_argument("--count", type=int, default=512)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--emit-script", type=Path, metavar="OUT.py",
                    help="不连板卡，只生成一份“在你的板子上跑”的独立脚本（含 5 条判据与记录表）")
    ap.add_argument("--bit-name", default="design_1.bit",
                    help="--emit-script 时写进脚本的位流文件名（与 .hwh 同目录）")
    args = ap.parse_args(argv)

    if args.emit_script:
        return emit_script(args.emit_script, args.dev, args.dma, args.clk_mhz,
                           args.count, args.bit_name)

    if args.selftest:
        return _selftest()

    if args.overlay:
        if not args.overlay.is_file():
            print(f"[EXIT2] 找不到 {args.overlay}")
            return 2
        if not args.overlay.with_suffix(".hwh").is_file():
            print("[EXIT2] 同目录缺 .hwh：先跑 pynq_bundle.py 体检")
            return 2
        try:
            tp = PynqTransport(args.overlay, args.dma, args.dev, args.clk_mhz)
        except ImportError:
            print("[EXIT2] 这台机器上没有 pynq 模块；请用 --mock 或在板卡上跑")
            return 2
    else:
        tp = MockTransport(args.clk_mhz)

    t0 = time.perf_counter()
    res = run_loopcheck(tp, args.dev, args.count)
    wall = time.perf_counter() - t0

    print(f"传输层 = {tp.kind}")
    for c in res.checks:
        print(f"  [{'OK' if c['ok'] else 'XX'}] {c['name']}: {c['detail']}")
    for n in res.notes:
        print(f"  [NOTE] {n}")
    if res.cycles:
        print(f"  PL 周期 = {res.cycles} → 吞吐 {res.throughput_mbps:.1f} MB/s "
              f"（按 {tp.clk_mhz():g} MHz 换算）")
    if tp.kind == "mock":
        print(f"  （mock 的墙钟 {wall * 1e3:.1f} ms 不参与任何判据——它就是用来提醒你这事不能当指标）")
    tp.close()

    if args.json:
        args.json.write_text(json.dumps({
            "transport": tp.kind,
            "ok": res.ok,
            "checks": res.checks,
            "words": res.words,
            "cycles": res.cycles,
            "throughput_mbps": res.throughput_mbps,
            "notes": res.notes,
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"=> {'PASS' if res.ok else 'FAIL'}（{sum(c['ok'] for c in res.checks)}"
          f"/{len(res.checks)} 条判据）")
    return 0 if res.ok else 1


if __name__ == "__main__":
    sys.exit(main())
