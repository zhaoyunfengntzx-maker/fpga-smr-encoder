#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/bitstream_ab.py —— 位流 A/B/A 判别（§1.56 ⑦）：同幅度下换位流测毛刺率。

背景：10-11 晚的幅度序列（1.5 / 2.3–2.6 / 13.65 次/s）全在 **ILA 版**位流上测的；
      10-12 上午（**生产版**，flash 自举）只有 0.17–0.50 次/s。⇒ 必须判别"位流 vs 会话/温度"。

用法（每一次调用 = 换一份位流 + 采一个点，结果追加 `_synth_work/bitstream_ab.csv`）：
    $env:PYTHONIOENCODING='utf-8'
    E:\\Anaconda\\python.exe tools\\bitstream_ab.py --phase ila       --seconds 60
    E:\\Anaconda\\python.exe tools\\bitstream_ab.py --phase prod      --seconds 60
    E:\\Anaconda\\python.exe tools\\bitstream_ab.py --report

    # 只测量、不换位流（例：不动板上现有位流再采一点）
    E:\\Anaconda\\python.exe tools\\bitstream_ab.py --phase none --label prod-3 --seconds 60

★ 需要一次 sandbox 提权（Vivado 的 cs_server 要往 %TEMP% 解压 DLL）：
    pwsh ... 时带 sandbox_permissions=danger-full-access。
★ 位流文件与昨天完全一致（`enc_top_ila.bit` 1,432,868 B @10-11 21:24:56；
  `enc_top.bit` 1,226,648 B @10-11 20:43:01），所以这是**同 RTL、仅 ILA 插不插**的对照。
★ 幅度必须由用户保持不变（测率期间不要碰 AFG/板/接线，§1.56 ⑤）。
"""

import argparse
import csv
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import amp_point  # noqa: E402  （复用"一个点"的采集与 CSV 字段）

PHASE_BIT = {
    "prod": "_synth_work\\enc_top.bit",       # v9 生产版（flash 里那份的行为基准）
    "ila": "_synth_work\\enc_top_ila.bit",    # v9 + ILA（10-11 晚幅度序列用的那份）
    "none": None,
}


def download(bits, log):
    env = dict(os.environ, ILA_MODE="restore", ILA_BIT=bits, PYTHONIOENCODING="utf-8")
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-File", "tools\\run_vivado.ps1", "-Tcl", "tools\\ila_capture.tcl",
           "-LogFile", log, "-Tail", "24"]
    print("下载位流 %s ..." % bits)
    p = subprocess.run(cmd, env=env, capture_output=True)
    txt = (p.stdout or b"").decode("utf-8", "replace") + (p.stderr or b"").decode("utf-8", "replace")
    ok = "ILACAP DONE" in txt and "FATAL" not in txt
    print("  rc=%d  %s" % (p.returncode, "OK" if ok else "失败（见 %s）" % log))
    if not ok:
        print(txt[-2000:])
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", choices=["prod", "ila", "none"], required=False, default="none")
    ap.add_argument("--label", default="")
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--settle", type=float, default=8.0, help="换位流后等待标定/稳定的秒数")
    ap.add_argument("--csv", default="_synth_work/bitstream_ab.csv")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    if args.report:
        return amp_point.report(args.csv)

    label = args.label or args.phase
    if PHASE_BIT[args.phase]:
        log = "_synth_work\\ab_%s_%s.log" % (args.phase, time.strftime("%H%M%S"))
        if not download(PHASE_BIT[args.phase], log):
            return 1
        time.sleep(args.settle)

    csv_out = os.path.join("_synth_work", "ab_pts", "%s_%s.csv" % (label, time.strftime("%m%d_%H%M%S")))
    row = amp_point.one_point(sys.executable, args.port, args.baud, args.seconds, label, csv_out=csv_out)
    row["phase"] = args.phase
    new = not os.path.exists(args.csv)
    fields = ["phase"] + amp_point.FIELDNAMES
    with open(args.csv, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        if new:
            w.writeheader()
        w.writerow(row)
    print(" ".join("%s=%s" % (k, row.get(k, "")) for k in
                   ("ts", "phase", "A_mean", "r1024", "r2048", "r4096", "dcyc", "fin_hz", "otr0405")))
    print("已追加到 %s" % args.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
