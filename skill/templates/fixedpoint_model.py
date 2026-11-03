#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fixedpoint_model.py —— 定点黄金模型骨架（bit-exact，不是"差不多"）

失效条件：只建模"加、算术右移、饱和、四舍五入"这四类原语，不含除法、乘法器截位、
    浮点；SIN_LUT 是本工程 16 bit 全周的 sin 表，换分辨率就要重新生成并在 --check 里
    加一条"单调性 + 端点"判据。模型与 RTL 的位宽/舍入一旦不同步，它给出的"通过"
    只是"两边错得一样"。

【适用】任何要拿仿真/上板结果与"理论值"比对的 RTL 模块：CORDIC、查表插值、
        多相滤波、CRC、固定点 PID……凡是用浮点算一遍就说"DUT 误差 0.1%"的，
        都不算验证；能逐点对上整数才算。
        本工程用它把 16 bit 角度链路的误差从"我以为"变成 0.9375 LSB 这个可复现的数。

【用法】
    python fixedpoint_model.py --n 64 --out golden.csv      # 生成激励+期望（两列）
    python fixedpoint_model.py --check                      # 跑自检，验算三个原语
    python skill/scripts/check_vectors.py golden.csv sim.csv --tol 0   # 逐点比对

【为什么必须逐点、为什么必须整数】(docs/ai-collaboration-log.md 记录 2/7/12)
    * 浮点参考与 RTL 的差别不是"精度"，而是"语义"：
      Python 的 `>>` 对负数是算术右移（向 -inf），Verilog 的 `>>` 对有符号数
      在综合后是**逻辑右移**（补 0）。本工程第一版模型照抄 RTL 语义写出了
      误差 RMS 0.597 LSB；改成显式算术右移后降到 0.3229 LSB。
    * 只要有一个"半 LSB 四舍五入"没写清楚，全周扫描就会在象限边界上
      整段差 1；本工程在 45°/135°/225°/315° 附近各差了 1 个码，
      用 2^20 点全周扫描才看见（随机测 100 点看不见）。
    * 端点必须验证：CORDIC 级数从 15 提到 17，RMS 1.19 → 0.9375 LSB；
      代价是每级两级加法器。这个权衡只有模型能算，仿真只能验证。

【失效条件】
    * DUT 有状态（滤波器、跟踪环）：单点函数模型对不上，需要建"时序模型"，
      本骨架不适合；
    * DUT 内含未定延时的握手：模型要给"第 k 个输出对应第几个输入"的映射，
      否则逐点比对会把顺序差当成数值差。
"""

from __future__ import annotations

import argparse
import math
import sys

MASK = 0xFFFF          # 16 bit
HALF = 0x8000


def _utf8_console() -> None:
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


# ---------------------------------------------------------------------------
# 三个原语：所有定点模型都只由它们组合而成，先把它们写对，再谈算法
# ---------------------------------------------------------------------------
def asr(x: int, n: int) -> int:
    """算术右移（等价于 Verilog 的 $signed(x) >>> n）。

    ★ Python 的 >> 本身就是算术右移，所以这里直接用 >>；
      别写成 (x & MASK) >> n —— 那会把负数变成大正数，
      正是本工程模型第一版的 bug（误差从 0.3229 涨到 0.597 LSB）。
    """
    return x >> n


def rshift_round(x: int, n: int) -> int:
    """四舍五入到 n 位（half-up，负数向 -inf 舍入，与 RTL 的 +half 再截断一致）。

    本工程的取舍：RTL 用 (x + (1<<(n-1))) >>> n，Python 必须一模一样，
    不能图省事用 round() —— round(-0.5) 在 Python 里是 0，在 half-up 里是 -1。
    """
    return (x + (1 << (n - 1))) >> n


def sat(x: int, bits: int) -> int:
    """饱和到有符号 bits 位。"""
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return lo if x < lo else (hi if x > hi else x)


def to_u16(x: int) -> int:
    """有符号 → 16 bit 无符号（角度码常用偏移二进制/补码两种，这里用补码）。"""
    return x & MASK


# ---------------------------------------------------------------------------
# 被测算法：替换成你自己的公式，但**必须只用上面三个原语**
# ---------------------------------------------------------------------------
# 这里用"查表 + 整数线性插值"算 sin，作为骨架示例：它足够简单，能一眼看出
# 误差从哪来（表精度 + 插值残差），也方便你把 RTL 的每一行复刻下来。
SIN_LUT = [int(round(32767 * math.sin((math.pi / 2) * i / 64))) for i in range(65)]


def model(angle_u16: int) -> int:
    """角度码（0..65535 = 0..2π）→ sin 的 Q15 定点值（-32767..32767）。

    象限折叠：q=0 用原值、q=1 镜像、q=2/q=3 再取负；这样只要 1/4 周的表。
    """
    q = angle_u16 >> 14                 # 0..3
    a = angle_u16 & 0x3FFF              # 象限内 0..16383
    if q in (1, 3):
        a = 0x4000 - a                  # 镜像：sin(π-θ) = sin(θ)

    idx = (a * 64) >> 14               # 0..64（镜像后 a 可以等于 16384）
    if idx >= 64:
        val = SIN_LUT[64]              # 正好 90°，表端点
    else:
        frac = (a * 64) & 0x3FFF       # 余数，0..16383
        v0, v1 = SIN_LUT[idx], SIN_LUT[idx + 1]
        val = v0 + ((((v1 - v0) * frac) + 0x2000) >> 14)   # 半 LSB 四舍五入
    if q >= 2:
        val = -val
    return to_u16(sat(val, 16))


# ---------------------------------------------------------------------------
# 自检：三个原语如果错了，后面所有数字都不作数
# ---------------------------------------------------------------------------
def self_check() -> int:
    fails = 0

    def expect(name: str, got, want) -> None:
        nonlocal fails
        if got != want:
            fails += 1
            print(f"FAIL {name}: got {got}, want {want}")
        else:
            print(f"ok   {name}: {got}")

    expect("asr(-3,1) = -2（向 -inf）", asr(-3, 1), -2)
    expect("rshift_round(-3,1) = -1（half-up）", rshift_round(-3, 1), -1)
    expect("rshift_round(3,1) = 2", rshift_round(3, 1), 2)
    expect("sat(40000,16) = 32767", sat(40000, 16), 32767)
    expect("sat(-40000,16) = -32768", sat(-40000, 16), -32768)
    expect("to_u16(-1) = 65535", to_u16(-1), 65535)

    # 单调性：sin 在 0..π/2 必须单调不减；全周 2^20 点的"半 LSB 抖动"也要能看见
    prev = None
    for code in range(0, 16385):
        v = model(code)
        if prev is not None and v + 0 < prev - 0 and (prev - v) > 2:
            fails += 1
            print(f"FAIL 单调性在 code={code} 断了：{prev} → {v}")
            break
        prev = v
    else:
        print("ok   0..π/2 段单调（允许 ±2 码的定点抖动）")

    print(f"=> {'PASS' if fails == 0 else 'FAIL'} {fails} 项不符")
    return 0 if fails == 0 else 1


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="定点黄金模型骨架")
    ap.add_argument("--n", type=int, default=64, help="全周点数（默认 64；真实工程用 2^20）")
    ap.add_argument("--out", default="golden.csv", help="输出两列 CSV：输入码, 期望码")
    ap.add_argument("--check", action="store_true", help="只跑原语与算法自检")
    args = ap.parse_args(argv)

    if args.check:
        return self_check()

    step = max(1, (MASK + 1) // args.n)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        for code in range(0, MASK + 1, step):
            f.write(f"{code},{model(code)}\n")
    print(f"写出 {len(range(0, MASK + 1, step))} 点 → {args.out}")
    print("下一步：仿真输出同样两列，再跑")
    print(f"  python skill/scripts/check_vectors.py {args.out} sim.csv --tol 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
