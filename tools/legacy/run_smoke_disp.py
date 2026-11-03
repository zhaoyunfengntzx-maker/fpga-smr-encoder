#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_smoke_disp.py -- 跑 disp/sim/smoke_p1.v，打印 P1 版面的 ASCII 缩略图

这不是断言式的测试（那个是 tools/run_sim_disp.py），而是"看一眼像不像"的冒烟：
它渲染一整帧 P1，把 lcd_rgb == C_TEXT 的像素采样成 '#'，其它为 '.'。
字形索引/移位寄存器/卡片几何一旦接错，这里会直接看出来。

沿用 tools/run_sim_disp.py 的两条环境纪律：
  * 调 xvlog/xelab/xsim 必须给 **.bat 的完整路径** 且 shell=True；
  * 必须把 TEMP/TMP 钉进工作区，否则 xsim 编译生成的 C 文件会写 %TEMP% 失败。
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIVADO_BIN = Path(r"D:\Vivado\2026.1\Vivado\bin")
WORK = ROOT / "_disp_work" / "smoke"
TMP = ROOT / "_disp_work" / "smoke_tmp"
PAGE = ("p8" if "--page8" in sys.argv
        else "p7" if "--page7" in sys.argv
        else "p6" if "--page6" in sys.argv else "p1")
LOG = ROOT / "_disp_work" / ("smoke_%s.log" % PAGE)

# 源文件清单**不写死**：写死的清单每加一个页面就要补一次，而漏补的症状是
# xelab 报一堆 "Module <xxx> not found"（看起来像模块丢了，其实只是没进
# 编译列表）。glob 与 tools/run_sim_disp.py:59-60 一致 —— "*.v" 非递归，
# 天然把 disp/sim/ 下的测试台排除在外。
SRC = sorted(p for p in (ROOT / "disp").glob("*.v") if not p.name.startswith("tb_"))
TB = ROOT / "disp" / "sim" / "smoke_p1.v"
TOP = "smoke_p1"


def run(cmd, cwd, env):
    exe = cmd[0]
    if exe in ("xvlog", "xelab", "xsim"):
        exe = str(VIVADO_BIN / (exe + ".bat"))
    full = subprocess.list2cmdline([exe] + list(cmd[1:]))
    p = subprocess.run(full, cwd=str(cwd), env=env, shell=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def main():
    if not (VIVADO_BIN / "xvlog.bat").exists():
        print("[!] 找不到 Vivado: %s" % (VIVADO_BIN / "xvlog.bat"))
        return 2
    WORK.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(VIVADO_BIN) + os.pathsep + env.get("PATH", "")
    env["TEMP"] = str(TMP)
    env["TMP"] = str(TMP)

    print(" smoke: %s -> %s" % (TB.name, WORK))
    defs = []
    if "--page8" in sys.argv:
        # 让冒烟件渲染 P8 触摸诊断页而不是 P1 总览（同一个测试台，靠宏选页）。
        defs = ["-d", "PAGE8"]
        print(" smoke: PAGE8 defined -> rendering the touch diagnostic page")
    elif "--page7" in sys.argv:
        # P7 标定与误差可视化：两条曲线 bank 在冒烟里只有"标定前"那一组有数据
        # （tap_calib_busy 恒 0），所以左框看到的是品红带子 + 绿色初始线。
        defs = ["-d", "PAGE7"]
        print(" smoke: PAGE7 defined -> rendering the calibration/error page")
    elif "--page6" in sys.argv:
        defs = ["-d", "PAGE6"]
        print(" smoke: PAGE6 defined -> rendering the settings page")
    rc, out = run(["xvlog", "--sv"] + defs + [str(f) for f in SRC] + [str(TB)], WORK, env)
    if rc != 0:
        print(out)
        print("[xvlog 分析失败] exit %d" % rc)
        return 1
    rc, out = run(["xelab", "-debug", "typical", TOP, "-s", TOP + "_sim"], WORK, env)
    if rc != 0:
        print(out)
        print("[xelab 精化失败] exit %d" % rc)
        return 1
    rc, out = run(["xsim", TOP + "_sim", "-runall"], WORK, env)
    LOG.write_text(out, encoding="utf-8", newline="\n")
    print(out)
    print("[xsim] exit %d ; 完整日志 %s" % (rc, LOG))
    if "SMOKE DONE" not in out:
        return 1
    # "像不像" 也可以被机器检查：把 WIN-B 的像素反解回字符，与 val_format
    # 写进 RAM 的字符串逐字符比对（见 tools/check_smoke_text.py 的说明）。
    # P6/P8 都不走这个断言：
    #   - P6 的数值层是静态预置（见 disp/disp_engine.v 里 p6_val_ram 的注释）；
    #   - P8 的数值层由 touch_view 写，而 touch_view 已有自己的逐字符测试台
    #     （disp/tb_touch_view.v），在仿真里直接比对 RAM 内容比反解像素更强。
    if PAGE != "p1":
        print("\n[skip] raster text check: %s uses its own formatter testbench" % PAGE.upper())
        return 0
    print("\n---------------- raster text check ----------------")
    rc2 = subprocess.run([sys.executable, str(ROOT / "tools" / "check_smoke_text.py")]).returncode
    return rc2


if __name__ == "__main__":
    sys.exit(main())
