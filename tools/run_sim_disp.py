#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/run_sim_disp.py -- 显示屏本机 UI（disp/）专用 xsim 回归（Python 版）

为什么有 .py 版（还有一份 .ps1 双胞胎 tools/run_sim_disp.ps1）：

  1) **.ps1 在本项目的默认工作环境里跑不起来。** 2026-10-15 实测：
     DSH 沙箱下的 shell 是 Windows PowerShell 5.1 + ConstrainedLanguage，
     且执行策略禁止运行脚本 —— 于是
         & tools\\run_sim_disp.ps1   -> "在此系统上禁止运行脚本"
         powershell.exe -File ...    -> "无法使用 '.' 来对当前范围外的源文件
                                          进行点引用，因为当前范围在不同模式下定义"
     xvlog/xelab/xsim 本身可以正常调用，被挡住的只有 .ps1 这一层壳。
     所以本文件是**权威实现**，.ps1 只是给"非沙箱、习惯 PowerShell"的场合留的入口。

  2) disp/ 的测试台不能放进 sim/：tools/run_sim.ps1 只编译 rtl/*.v，
     而 disp/ 的测试台还要 disp/*.v。放错地方会让「编码器回归 PASS 21/21」
     的基线全部变成 BUILD-ERR。

  3) xsim 必须把 TEMP/TMP 钉进工作区，否则报
         ERROR: [XSIM 43-3409] Failed to compile generated C file
                               xsim.dir/<tb>/obj/xsim_1.c
     （2026-10-15 实测。与 tools/run_vivado.ps1 处理 HOME/APPDATA 同因：
       沙箱只允许写工作区，而 xsim 要往 %TEMP% 落 C 代码。）

源文件 = rtl/*.v + disp/*.v（去掉 tb_*）+ sim/xilinx_prims_stub.v
测试台 = disp/tb_*.v        每个测试台一个独立工作目录

用法:
    python tools\\run_sim_disp.py
    python tools\\run_sim_disp.py --only tb_freq_meter,tb_fixed_div
    python tools\\run_sim_disp.py --define ENC_DISP_TAP
    python tools\\run_sim_disp.py --rebuild

退出码: 0 = 全部 PASS；1 = 存在 FAIL 或编译/精化错误。
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

VIVADO_BIN = Path(r"D:\Vivado\2026.1\Vivado\bin")


# 只有仿真才需要的模型（放 disp/sim/ 而不是 disp/，否则会被 tools/synth_disp.tcl
# 和 tools/impl_disp.tcl 当成设计源读进去 —— 里面有 initial + 延时，是仿真件的标志）。
TB_EXTRA = {
    "tb_touch_ctrl": ["disp/sim/iic_slave_model.v", "disp/sim/iobuf_stub.v"],
    #   tb_enc_disp_panel 例化的是整片 disp/enc_top_disp.v，它内部有
    #   disp/i2c_io_wrap.v（三态 IOBUF）⇒ 也要那个 IOBUF 桩。
    #   不需要 iic_slave_model：本台子用 force 给命中层喂触点快照（见文件头）。
    "tb_enc_disp_panel": ["disp/sim/iobuf_stub.v"],
}


#  个别测试台必须带 Verilog 宏才能精化：tb_enc_disp_panel 例化的是整片
#  disp/enc_top_disp.v，它引用的 rtl/enc_top.v 的 **disp_tap 端口**被
#  `ifdef ENC_DISP_TAP 门控（见 rtl/enc_top.v:124 的注释：生产脚本不许加这个宏，
#  只有显示侧构建脚本 tools/synth_disp.tcl / tools/impl_disp.tcl 才加 ——
#  tools/impl_disp.tcl:59 就是 `-verilog_define ENC_DISP_TAP`）。
#  ★ 放在这里而不是要求用户每次手加 `--define`，是为了让"全量回归"这一条
#    命令（python tools/run_sim_disp.py）保持不变；命令行给的 --define 仍然
#    对所有台子生效，两者是叠加关系。
TB_DEFS = {
    "tb_enc_disp_panel": ["ENC_DISP_TAP"],
}


def collect(root: Path):
    rtl = sorted((root / "rtl").glob("*.v"))
    # rtl/eth/*.v 是 v58 之前就加进来的以太网侧（enc_top.v 例化 eth_top）。
    # 不带上它，tb_enc_disp_panel 这类例化整片 enc_top_disp 的台子会
    # "Module <eth_top> not found" 直接 BUILD-ERR —— 这是 2026-10-22 复查
    # 才暴露的回归脚本缺口，不是 RTL 缺陷。
    eth = sorted((root / "rtl" / "eth").glob("*.v"))
    disp = sorted(p for p in (root / "disp").glob("*.v") if not p.name.startswith("tb_"))
    stub = root / "sim" / "xilinx_prims_stub.v"
    src = [str(p) for p in rtl] + [str(p) for p in eth] + [str(p) for p in disp]
    if stub.exists():
        src.append(str(stub))
    return src


def run(cmd, cwd, env):
    """跑一条 Vivado 命令，返回 (returncode, 合并后的输出文本)。

    注意两点 Windows 特有的坑（2026-10-15 实测）：
      * 必须给出 **.bat 的完整路径**。Python 的 CreateProcess 不走 cmd 的
        PATHEXT 解析，只写 "xvlog" 会直接 FileNotFoundError [WinError 2]。
      * 必须用 shell=True 交给 cmd.exe：CreateProcess 不能直接执行 .bat。
        参数里没有空格/引号问题（路径都是工作区内无空格的 ASCII 路径）。
    """
    exe = cmd[0]
    if exe in ("xvlog", "xelab", "xsim"):
        exe = str(VIVADO_BIN / (exe + ".bat"))
    full = subprocess.list2cmdline([exe] + list(cmd[1:]))
    p = subprocess.run(full, cwd=str(cwd), env=env, shell=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode("utf-8", errors="replace")
    return p.returncode, out


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--only", default="", help="逗号分隔的测试台名（不含 .v）")
    ap.add_argument("--define", default="", help="逗号分隔的 verilog 宏定义")
    ap.add_argument("--rebuild", action="store_true", help="先清掉每个测试台的工作目录")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    work_root = root / "_disp_work" / "sim_disp"
    tmp_dir = root / "_disp_work" / "tmp"
    log_dir = root / "disp" / "logs"
    for d in (work_root, tmp_dir, log_dir):
        d.mkdir(parents=True, exist_ok=True)

    if not (VIVADO_BIN / "xvlog.bat").exists():
        print(f"[!] 找不到 Vivado: {VIVADO_BIN / 'xvlog.bat'}")
        return 2

    env = dict(os.environ)
    env["PATH"] = str(VIVADO_BIN) + os.pathsep + env.get("PATH", "")
    env["TEMP"] = str(tmp_dir)          # ★ 见文件头第 3 条
    env["TMP"] = str(tmp_dir)

    src = collect(root)
    if not src:
        print("[!] 没收集到源文件")
        return 2

    only = [s.strip() for s in args.only.split(",") if s.strip()]
    tbs = sorted(p for p in (root / "disp").glob("tb_*.v"))
    if only:
        tbs = [p for p in tbs if p.stem in only]
    if not tbs:
        print("[!] disp/ 下没有匹配的测试台")
        return 2

    defines = [s.strip() for s in args.define.split(",") if s.strip()]
    def_args = []
    for d in defines:
        def_args += ["-d", d]

    print("=" * 64)
    print(f" disp/ xsim 回归:  {len(tbs)} 个测试台 / {len(src)} 个源文件")
    print(f" 工作目录: {work_root}")
    print(f" TEMP    : {tmp_dir}")
    print("=" * 64)

    results = []
    for tb in tbs:
        tb_work = work_root / tb.stem
        log_path = log_dir / f"{tb.stem}.log"
        print(f"\n--- {tb.stem} ", end="", flush=True)
        t0 = time.time()
        if args.rebuild and tb_work.exists():
            shutil.rmtree(tb_work, ignore_errors=True)
        tb_work.mkdir(parents=True, exist_ok=True)

        lines, ok, stage = [], False, "xvlog"
        extra = [str(root / p) for p in TB_EXTRA.get(tb.stem, [])]
        tb_def_args = list(def_args)
        for d in TB_DEFS.get(tb.stem, []):
            tb_def_args += ["-d", d]
        rc, out = run(["xvlog", "--sv"] + tb_def_args + src + extra + [str(tb)], tb_work, env)
        lines += ["###### xvlog ######", out]
        if rc != 0:
            lines.append(f"xvlog FAILED (exit {rc})")
            print("[xvlog 分析失败]", end="")
        else:
            stage = "xelab"
            rc, out = run(["xelab", "-debug", "typical", tb.stem, "-s", f"{tb.stem}_sim"],
                          tb_work, env)
            lines += ["###### xelab ######", out]
            if rc != 0:
                lines.append(f"xelab FAILED (exit {rc})")
                print("[xelab 精化失败]", end="")
            else:
                stage = "xsim"
                rc, out = run(["xsim", f"{tb.stem}_sim", "-runall"], tb_work, env)
                lines += ["###### xsim ######", out]
                ok = True

        text = "\n".join(lines)
        # 带 BOM 写出：Windows PowerShell 5.1 读无 BOM 的 UTF-8 会按 ANSI(GBK) 解码，
        # 中文日志会乱码（与 tools/run_sim.ps1 的约定一致）。
        log_path.write_text(text, encoding="utf-8-sig")

        # v58 起新增的契约台用 "[PASS] <名字>: ..." / "[FAIL] <名字>: ..." 收尾
        # （见 tools/run_sim_v58.py 的判定），这里两种约定都认，否则老跑分板会把
        # 明明 PASS 的台子记成 NO-VERDICT。
        m58_pass = re.search(r"^\[PASS\]\s+%s\b" % re.escape(tb.stem), text, re.M)
        m58_fail = re.search(r"^\[FAIL\]\s+%s\b" % re.escape(tb.stem), text, re.M)
        passed = ("TEST PASSED" in text) or bool(m58_pass)
        failed = ("TEST FAILED" in text) or bool(m58_fail)
        if not ok:
            verdict = "BUILD-ERR"
        elif passed and not failed:
            verdict = "PASS"
        elif failed:
            verdict = "FAIL"
        else:
            verdict = "NO-VERDICT"

        m = re.search(r"TEST FAILED \((\d+) errors\)", text)
        if m:
            errs = m.group(1)
        elif passed:
            errs = "0"
        else:
            errs = "?"

        secs = int(time.time() - t0)
        print(f"{verdict}  stage={stage}  errors={errs}  {secs}s")
        results.append((tb.stem, verdict, errs, secs, str(log_path)))

    n_pass = sum(1 for r in results if r[1] == "PASS")
    n_bad = len(results) - n_pass
    print("\n" + "=" * 64)
    print(" disp/ 回归汇总")
    print("=" * 64)
    for name, verdict, errs, secs, _ in results:
        print(f" {name:<22} {verdict:<11} errors={errs:<4} {secs}s")
    print(f"\n PASS {n_pass} / 共 {len(results)} ；非 PASS {n_bad}")

    md = ["# disp/ xsim 回归汇总", "",
          f"- 时间: {time.strftime('%Y-%m-%d %H:%M:%S')}",
          f"- 结果: **PASS {n_pass} / {len(results)}**", "",
          "| 测试台 | 结果 | 错误数 | 耗时(s) | 日志 |", "|---|---|---|---|---|"]
    for name, verdict, errs, secs, _ in results:
        md.append(f"| `{name}` | {verdict} | {errs} | {secs} | [log](logs/{name}.log) |")
    (log_dir / "SUMMARY.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f" 汇总写入: {log_dir / 'SUMMARY.md'}")
    # ★ U-57：SUMMARY.md 是构建产物（每跑一次重写）；disp/logs/ 整目录早在 .gitignore 里，
    #   不再跟踪，所以跑完回归不用再手工 git checkout 还原。

    return 1 if n_bad else 0


if __name__ == "__main__":
    sys.exit(main())
