#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""tools/run_sim_v58.py -- v58 显示子系统的一键仿真回归（两个契约台）

为什么单独写一个脚本（而不是用 tools/run_sim_disp.py）：
  1) `disp/` 里的旧台（tb_disp_engine 那批）编码的是 8 页时代的契约，v58 删了三页
     之后它们必然失败；本脚本只跑 v58 的两个契约台：
        disp/tb_disp_v58.v     —— 5 页版面 / 4 档导航 / R8 蓝线 / R9 设置导航
        disp/tb_hit_test_v58.v —— 触摸命中边界（4 档导航 + 6 卡片 + 按钮 + 非法坐标）
  2) **xsim 的工作目录必须是仓库之外的临时目录**。在这台机器上实测：
     `xsim` 在 `C:\\Users\\zhaoy\\Desktop\\...` 下启动会直接
        Could not open file mapping object (2).
        Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)
     而在 `%LOCALAPPDATA%\\Temp\\...` 下同一份快照能正常跑完。看起来是
     Desktop 被某个文件系统过滤驱动（云同步/重定向类）插了一手，xsim 建共享内存
     段时被打断。所以这里把 WORK 钉在 %TEMP% 下，源码用绝对路径喂给 xvlog。
  3) TEMP/TMP 也钉进同一个工作目录，否则 xsim 生成的 C 代码可能写不进去。

用法：
    python tools/run_sim_v58.py            # 跑两个台，打印 PASS/FAIL，失败返回 1
    python tools/run_sim_v58.py --keep     # 保留工作目录（调试用）
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIVADO_BIN = Path(os.environ.get("XILINX_VIVADO", r"D:\Vivado\2026.1\Vivado")) / "bin"

# v58 存活页对应的设计源（不含任何 tb_* / legacy_*）
SRC_GLOBS = ["rtl/*.v", "rtl/eth/*.v", "disp/*.v"]


def collect_sources():
    files = []
    for g in SRC_GLOBS:
        for p in sorted(ROOT.glob(g)):
            if p.name.startswith("tb_") or p.name.startswith("legacy_"):
                continue
            files.append(str(p))
    return files


def run(cmd, cwd, env):
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True,
                       errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main():
    # 控制台是 GBK，而 xsim 的输出里混着 UTF-8/替换字符；不重设编码会在打印
    # 失败行的最后一步抛 UnicodeEncodeError（而不是报告仿真结果）。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="保留临时工作目录")
    args = ap.parse_args()

    xvlog, xelab, xsim = (VIVADO_BIN / n for n in ("xvlog.bat", "xelab.bat", "xsim.bat"))
    for exe in (xvlog, xelab, xsim):
        if not exe.exists():
            print("[!] 找不到 %s" % exe)
            return 2

    work = Path(tempfile.gettempdir()) / "disp_sim_v58"
    if work.exists():
        shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    env = dict(os.environ)
    env["TEMP"] = env["TMP"] = str(work)
    env["PATH"] = str(VIVADO_BIN) + os.pathsep + env.get("PATH", "")

    src = collect_sources()
    print(" disp/ 仿真回归: 3 个契约台 / %d 个源文件 / 工作目录 %s" % (len(src), work))

    rc, out = run([str(xvlog), "--sv"] + src, work, env)
    if rc != 0:
        print("[xvlog 失败] exit %d" % rc)
        print("\n".join(out.strip().splitlines()[-25:]))
        return 1
    print("  xvlog  OK")

    tbs = [("tb_disp_v58", "5 页版面 / 4 档导航 / R8 / R9"),
           ("tb_hit_test_v58", "触摸命中边界"),
           ("tb_trace_cap", "P4 触发式时域（v60/T7）")]
    failed = []
    for tb, desc in tbs:
        tb_file = ROOT / "disp" / (tb + ".v")
        if not tb_file.exists():
            print("  %-16s 跳过（源文件不存在）" % tb)
            continue
        rc, out = run([str(xvlog), "--sv", "--work", "work", str(tb_file)], work, env)
        if rc != 0:
            print("  %-16s xvlog 失败" % tb)
            print("\n".join(out.strip().splitlines()[-15:]))
            failed.append(tb)
            continue
        snap = tb + "_sim"
        rc, out = run([str(xelab), "-debug", "typical", tb, "-s", snap], work, env)
        if rc != 0:
            print("  %-16s xelab 失败" % tb)
            print("\n".join(out.strip().splitlines()[-15:]))
            failed.append(tb)
            continue
        rc, out = run([str(xsim), snap, "-runall"], work, env)
        m = re.search(r"^\[(PASS|FAIL)\] %s" % re.escape(tb), out, re.M)
        mark = "PASS" if (rc == 0 and m and m.group(1) == "PASS") else "FAIL"
        print("  %-16s %s   %s" % (tb, mark, desc))
        if mark == "FAIL":
            failed.append(tb)
            tail = [l for l in out.strip().splitlines() if "FAIL" in l or "ERROR" in l]
            for line in (tail or out.strip().splitlines())[-8:]:
                print("      " + line)

    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)

    if failed:
        print(" 结果: FAIL (%s)" % ", ".join(failed))
        return 1
    print(" 结果: PASS（两个契约台全部通过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
