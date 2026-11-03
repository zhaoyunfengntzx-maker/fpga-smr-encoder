#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""管理 sim/logs/ 下的孤儿日志（源测试台已不存在的 .log）。

背景：.log 是 run_sim.ps1 生成的产物、被 .gitignore 忽略，所以"删掉测试台"不会
连带把它的日志删掉。孤儿日志里如果有 TEST FAILED，会被后来的人（包括我自己）
误读成"当前有失败"。本脚本：
  1) 列出孤儿日志（sim/logs/*.log 中不存在同名 sim/tb_*.v 的）；
  2) 把 tb_calib_bnd.log（已删除测试台，记录的是 DEV_STATUS §1.9 那个
     off-by-one 缺陷修复**之前**的失败现场，属历史 A/B 证据）改名归档为
     _ORPHAN_tb_calib_bnd_pre-fix.log 并加来源说明头。
不改动任何有对应测试台的日志。
"""
import glob
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim")
LOGDIR = os.path.join(SIM, "logs")

tbs = {os.path.basename(p)[:-2] for p in glob.glob(os.path.join(SIM, "tb_*.v"))}
logs = sorted(glob.glob(os.path.join(LOGDIR, "*.log")))
# 以 "_" 开头的日志是**有意归档**的（如 _ORPHAN_*、_run_console*），不算未处理的孤儿。
orphans = [p for p in logs
           if os.path.basename(p)[:-4] not in tbs
           and not os.path.basename(p).startswith("_")]
archived = [p for p in logs
            if os.path.basename(p)[:-4] not in tbs
            and os.path.basename(p).startswith("_")]

print("测试台 %d 台 / 日志 %d 份" % (len(tbs), len(logs)))
print("孤儿日志（无同名 sim/tb_*.v，且未归档）：")
for p in orphans:
    print("   %s  (%d B)" % (os.path.basename(p), os.path.getsize(p)))
if not orphans:
    print("   （无）")
if archived:
    print("已归档（名字以 _ 开头，不计为孤儿）：")
    for p in archived:
        print("   %s  (%d B)" % (os.path.basename(p), os.path.getsize(p)))

SRC = os.path.join(LOGDIR, "tb_calib_bnd.log")
if os.path.isfile(SRC):
    DST = os.path.join(LOGDIR, "_ORPHAN_tb_calib_bnd_pre-fix.log")
    body = open(SRC, encoding="utf-8-sig").read()
    header = (
        "###### 归档说明（不是当前回归产物，勿当作现在的失败） ######\n"
        "# 这是一份**孤儿日志**：产生它的测试台 sim/tb_calib_bnd.v 已经从仓库中\n"
        "# 删除（其覆盖面由 sim/tb_calib_min.v 承接，后者 PASS 54 checks，见\n"
        "# docs/DEV_STATUS.md 第 1 节表格）。\n"
        "# 它记录的是 docs/DEV_STATUS.md §1.9 那个真缺陷（rtl/calib_ctrl.v 标定窗口\n"
        "# off-by-one，win_cycles=1 时窗口退化为 0）**修复之前**的失败现场：\n"
        "#   TEST FAILED (5 error(s) / 38 checks) —— T3a/T3b cycle_pulse 与 win_cycles、\n"
        "#   phase_k == 0、gain_s == gain_c、ACCUM..DONE 全部失败。\n"
        "# 保留它只作历史 A/B 证据（修复前失败 -> 修复后 PASS）。\n"
        "# 它不由 tools/run_sim.ps1 生成或读取（脚本只发现 sim/tb_*.v）。\n"
        "##############################################################\n"
    )
    with open(DST, "w", encoding="utf-8", newline="\n") as f:
        f.write(header + body)
    os.remove(SRC)
    print("已归档：%s -> %s" % (os.path.basename(SRC), os.path.basename(DST)))
