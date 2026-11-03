# -*- coding: utf-8 -*-
"""频率阶梯原始 CSV 的稳健统计：给半径的中位/分位数与"坏帧"统计，并可落盘 CSV。

## 为什么需要它

遥测链路有 ~0.38% 的 XOR 校验错（CH340 + Windows 驱动下丢字节），个别帧即使侥幸
过了 XOR 也可能内容已坏，会把 `max` 拉飞。`tools/freq_ladder.py` 汇总表里的
`radius_max` / `status` 就是被这种帧污染的（10 kHz 那一点，1 个坏帧同时把
`radius_max` 抬到 32,357 并把 `status` 写成 `inclim=1, laglim=1, res=1`）。
⇒ 归档口径必须同时给出"中位/分位数"和"坏帧数"，不能只留最大值。

## 标度（实测反推，逐行核过）

    sqrt(amp_sq) 就是半径，单位与 (s, c) 相同

实证：10 kHz 全量 149,416 帧的 `sqrt(amp_sq)` 中位 = 26,220.9，与 `uart_scope.py`
按 `hypot(s, c)` 报的"校正后半径 r mean = 26,222.6"吻合到 0.007%。⚠ 我先后误试过
两个标度并已排除：`/2**30` ⇒ 0.8（差 3 万倍）、`/1000` ⇒ 829（差 31.6 倍）。

用法：
    python tools/robust_radius.py <csv> [<csv> ...] [--csv out.csv]
"""
import argparse
import csv
import math
import os
import sys

DEV_TOL = 0.02          # 与中位偏差 >2% 视为坏帧
FIELDS = ["file", "frames", "median", "p0.1%", "p1%", "p99%", "p99.9%",
          "min", "max", "bad_frames", "dev_median_pct"]


def pct(sorted_xs, p):
    if not sorted_xs:
        return float("nan")
    k = max(0, min(len(sorted_xs) - 1, int(round((len(sorted_xs) - 1) * p))))
    return sorted_xs[k]


def _num(v):
    v = (v or "").strip()
    return int(v) if v.lstrip("-").isdigit() else None


def analyze(path):
    """逐帧读 `amp_sq`（半径²）与 `(s, c)`，返回稳健统计字典。"""
    radii, devs, missing, n = [], [], 0, 0
    for row in csv.DictReader(open(path, newline="", encoding="utf-8")):
        n += 1
        amp = _num(row.get("amp_sq"))
        if amp is None or amp < 0:
            missing += 1
            continue
        r_amp = math.sqrt(amp)
        s, c = _num(row.get("s")), _num(row.get("c"))
        if s is not None and c is not None and r_amp > 0:
            devs.append(abs(math.hypot(s, c) - r_amp) / r_amp)
        radii.append(r_amp)
    radii.sort()
    devs.sort()
    med = pct(radii, 0.5)
    bad = [r for r in radii if med and abs(r - med) / med > DEV_TOL]
    return dict(file=os.path.basename(path), frames=n, valid=len(radii), missing=missing,
                median=med, p001=pct(radii, 0.001), p01=pct(radii, 0.01),
                p99=pct(radii, 0.99), p999=pct(radii, 0.999),
                lo=radii[0] if radii else float("nan"),
                hi=radii[-1] if radii else float("nan"),
                bad=bad, dev_med=pct(devs, 0.5), dev_p99=pct(devs, 0.99),
                dev_max=devs[-1] if devs else float("nan"))


def main(argv):
    ap = argparse.ArgumentParser(description="频率阶梯 CSV 的稳健半径统计")
    ap.add_argument("csvs", nargs="*", help="要统计的 freq_*.csv")
    ap.add_argument("--csv", default="", help="把统计结果也写成 CSV（一行一个文件）")
    args = ap.parse_args(argv[1:])
    if not args.csvs:
        print(__doc__)
        return 2

    rows = []
    for path in args.csvs:
        s = analyze(path)
        rows.append(s)
        print("== %s" % path)
        print("   帧 %d（有效 %d / amp_sq 缺失 %d）" % (s["frames"], s["valid"], s["missing"]))
        print("   sqrt(amp_sq) 与 hypot(s,c) 相对偏差：中位 %.4f%% / p99 %.4f%% / max %.4f%%"
              % (s["dev_med"] * 100, s["dev_p99"] * 100, s["dev_max"] * 100))
        print("   半径 中位=%.1f  p0.1%%=%.1f  p1%%=%.1f  p99%%=%.1f  p99.9%%=%.1f  min=%.1f  max=%.1f"
              % (s["median"], s["p001"], s["p01"], s["p99"], s["p999"], s["lo"], s["hi"]))
        if s["bad"]:
            print("   ★ 坏帧（偏离中位 >2%%）%d 个：%s" % (len(s["bad"]), ["%.1f" % x for x in s["bad"][:6]]))
        else:
            print("   ✅ 无坏帧")
        # 圆度用"抗坏帧"的口径：p0.1–p99.9 峰峰 / 中位
        print("   圆度（分位口径 p0.1–p99.9 峰峰 / 中位）= %.3f %%"
              % ((s["p999"] - s["p001"]) / s["median"] * 100))

    if args.csv:
        abs_out = args.csv if os.path.isabs(args.csv) else os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), args.csv)
        with open(abs_out, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(FIELDS)
            for s in rows:
                w.writerow(["%s" % s["file"], s["frames"], "%.1f" % s["median"],
                            "%.1f" % s["p001"], "%.1f" % s["p01"],
                            "%.1f" % s["p99"], "%.1f" % s["p999"],
                            "%.1f" % s["lo"], "%.1f" % s["hi"],
                            len(s["bad"]), "%.4f" % (s["dev_med"] * 100)])
        print("\n已写出 %s" % abs_out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
