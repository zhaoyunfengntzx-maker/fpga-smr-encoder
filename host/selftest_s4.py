#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""S4 验收自检：ABZ / UVW 等效采样与六状态数据表（无界面）

做四件事：
  ① 离线跑 abz.py 自检（按 RTL 语义造帧，不需要板子）
  ② 连真板，读回 0x0100/0x0101/0x0102/0x0108/0x0109，按**板上实际配置**配分析器
  ③ 收 N 秒遥测帧做等效采样，检查 A/B 正交、六状态均衡、Z 稀疏脉冲、箱覆盖率
  ④ 与独立口径对照：帧里 io_flags 的 z_window 位、io_bits 的六路电平占空比

只读，不写板子（S4 只是"看清楚"ABZ/UVW，不需要改配置）。
用法：
    python host\\selftest_s4.py --port COM3 --seconds 8
"""
from __future__ import annotations

import argparse
import os
import queue
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import abz as az              # noqa: E402
import encoder as enc         # noqa: E402
import link as lk             # noqa: E402
import ports as pm            # noqa: E402
import regs as rg             # noqa: E402

FAIL = []
OK_N = [0]
SKIP = []      # 因“采样简并”等工况不可测而跳过的项（明示，不算失败）


def check(name, ok, info=""):
    if ok:
        OK_N[0] += 1
    else:
        FAIL.append(name)
    print("  [%s] %-34s %s" % ("OK" if ok else "!!", name, info))


def hr(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def _lost_of(c):
    """丢帧数：link.counters() 的新字段；老版本退回 crc_err。"""
    if not c:
        return 0
    if "lost_frames" in c:
        return int(c["lost_frames"])
    return int(c.get("crc_err", 0))


def read_cfg(worker):
    """读回本卡需要的配置寄存器（读应答高字节属于 addr+1，见 README 事实 4）。"""
    addrs = [rg.REG_PAIRS, rg.REG_INTER0, rg.REG_INTER1, rg.REG_ZERO1, rg.REG_OUTPUT]
    raw = {}
    for a in addrs:
        d = worker.read_reg(a, timeout=0.5, retries=3)
        raw[a] = d["value"] if d else None
        print("  读 0x%04X -> %s = %s" % (a, (d or {}).get("hex", "读失败"),
                                        "----" if d is None else "0x%04X" % d["value"]))
    return raw


def main(argv=None):
    ap = argparse.ArgumentParser(description="S4 验收自检（ABZ/UVW 等效采样与六状态）")
    ap.add_argument("--port", default=None, help="串口号，例如 COM3（默认自动挑）")
    ap.add_argument("--baud", type=int, default=lk.BAUD_DEFAULT)
    ap.add_argument("--seconds", type=float, default=8.0, help="收帧时长（默认 8 s）")
    ap.add_argument("--max-seconds", type=float, default=0.0,
                    help="填箱不够时自动延长的上限（秒；0 = 自动取 max(4×--seconds, 40)）")
    ap.add_argument("--bins", type=int, default=256, help="等效采样分箱数（默认 256）")
    args = ap.parse_args(argv)

    hr("① 离线自检：abz.py（按 RTL 语义造帧）")
    if az.selftest() != 0:
        FAIL.append("abz 离线自检")

    hr("② 列端口、连接、读回板上配置")
    ports = pm.list_serial_ports()
    for dev, desc, _hw in ports:
        print("  %-8s %s" % (dev, desc))
    port = args.port or pm.preferred_port(ports)
    if not port:
        print("  !! 没找到可用串口")
        return 1
    print("  使用 %s @ %d baud" % (port, args.baud))
    worker = lk.SerialWorker(port, baud=args.baud)
    worker.start()
    try:
        t0w = time.monotonic()
        while not worker.connected and time.monotonic() - t0w < 5.0:
            if worker.error:
                print("  !! %s" % worker.error)
                return 1
            time.sleep(0.02)
        if not worker.connected:
            print("  !! 5 秒内没连上：%s" % (worker.error or "未知原因"))
            return 1
        print("  已连接 %s（%s）" % (port, lk.baud_text(args.baud)))

        info = worker.read_device_info(timeout=0.6, retries=3)
        print("  设备：%s  REV=%s  RTL_BUILD=%s"
              % tuple(("----" if info.get(k) is None else "0x%04X" % info[k])
                      for k in ("device_id", "rev", "rtl_build")))
        if info.get("rtl_build") != lk.EXPECT_RTL_V12:
            print("  !! 固件不是 v12（0x000C）：帧里没有 io_state/io_flags，S4 做不了")
            return 1
        print("  ✓ 固件 v12（帧布局 v2，ABZ/UVW 电平在 io_state 里）")

        raw = read_cfg(worker)
        if raw.get(rg.REG_INTER0) is None or raw.get(rg.REG_INTER1) is None:
            print("  !! 关键寄存器读失败，无法判读 inter/div")
            return 1
        inter, div = rg.decode_inter_div(raw[rg.REG_INTER0], raw[rg.REG_INTER1])
        pairs, pairs_raw = rg.decode_pairs(raw.get(rg.REG_PAIRS) or 0)
        zwidth = rg.adv_field_value("zwidth", raw)
        out_bits = rg.decode_output(raw.get(rg.REG_OUTPUT) or 0)
        print("  板上配置：inter=%d div=%d（等效倍率 ×%.3f）极对数=%d（0x0100=0x%04X）"
              " zwidth=%s" % (inter, div, rg.equiv_mult(inter, div), pairs, pairs_raw, zwidth))
        print("  输出使能：%s" % rg.output_text(raw.get(rg.REG_OUTPUT) or 0))
        if not out_bits.get("abzen"):
            print("  !! 板上 ABZ 输出没使能（0x0109 bit6 = 0），A/B/Z 会恒为 0")
            FAIL.append("ABZ 未使能")

        hr("③ 收帧 + 等效采样（%g s 起，%d 箱；填不够自动延长）" % (args.seconds, args.bins))
        an = az.AbzAnalyzer(bins=args.bins, pairs=pairs, inter=inter, div=div,
                            z_width=int(zwidth or 0))
        an.set_output(out_bits)
        est = enc.SpeedEstimator(pairs=pairs)
        c0 = worker.counters()
        t0 = time.time()
        last_t = t0
        # ★ 等效采样的填箱速度取决于“输入频率 vs 帧率”的可通约性：输入频率若≈帧率的
        #   简单分数倍（实测信号源 1 008.6 Hz ≈ 10 000/10），帧就反复落在同一批相位上，
        #   8 s 只填 44%（113/256）——这不是软件缺陷，是等效采样本身要慢慢扫相位。
        #   所以这里自动延长采样，直到 AB 箱填到 75% 或到达上限（默认 max(4×--seconds, 40 s)）。
        #   真机对照：同一工况 --seconds 25 时 AB/UVW 都是 256/256。
        cover_target = int(0.75 * args.bins)
        cap = args.max_seconds if args.max_seconds > 0 else max(args.seconds * 4.0, 40.0)
        next_probe = t0 + args.seconds
        extended = False
        n_zwin = 0           # 独立口径：帧里 z_window 标志置位次数
        n_z_no_win = 0       # 不变式：z=1 但 z_window 没置位的帧（必须为 0）
        n_dir = 0            # 独立口径：dir 位为 1 的次数
        n_lim = 0            # limiter 位
        n_fr = 0
        lost_prev = _lost_of(c0)     # ★ 必须记住上一批的累计丢帧，否则每批都加一遍累计值
        while True:
            now = time.time()
            if now >= next_probe:
                cov = an.snapshot(now)["cover_ab"]
                if cov >= cover_target or now - t0 >= cap:
                    break
                if not extended:
                    extended = True
                    print("  -- AB 箱已填 %d/%d（输入 %.1f Hz 与帧率 %.0f Hz 可通约时填得慢），"
                          "自动延长采样到 %.0f s"
                          % (cov, args.bins, est.snapshot(now).get("f_abs") or 0.0,
                             az.FRAME_HZ, cap))
                next_probe = now + 2.0
            try:
                kind, _text, extra = worker.events.get(timeout=0.05)
            except queue.Empty:
                continue
            if kind != "batch":
                continue
            frs = extra.get("frames") or []
            if not frs:
                continue
            last_t = time.time()
            cnt = extra.get("counters") or worker.counters()
            lost_now = _lost_of(cnt)
            bad = max(0, lost_now - lost_prev)
            lost_prev = lost_now
            an.feed(frs, t_now=last_t, n_bad=bad)
            est.feed(frs, t_now=last_t, n_bad=bad)
            for f in frs:
                n_fr += 1
                ib = f.get("io_bits") or {}
                win = bool((f.get("io_flag_bits") or {}).get("z_window")) or \
                    bool(int(f.get("io_flags") or 0) & 0x04)
                if win:
                    n_zwin += 1
                if ib.get("z") and not win:
                    n_z_no_win += 1
                if ib.get("dir"):
                    n_dir += 1
                if ib.get("limiter"):
                    n_lim += 1
        c1 = worker.counters()
        dt = max(1e-6, last_t - t0)
        n = c1.get("frames", 0) - c0.get("frames", 0)
        print("  收到 %s 帧 / %.3f s = %s 帧/秒" % (n, dt, int(n / dt)))
        if n_fr == 0:
            print("  !! 一帧都没收到")
            return 1

        snap = an.snapshot(last_t)
        sp = est.snapshot(last_t)
        f_in = sp.get("f_abs")
        an.set_f_in(f_in)
        snap = an.snapshot(last_t)      # 重取一次，带上按 f_in 折算的 Z 期望
        th = an.theory(f_in)

        hr("④ 等效采样结果")
        print("  输入频率 %.3f Hz（粗+精口径）；帧数时钟 %.3f、墙上时间 %.3f、只看角度 %.3f"
              % (f_in or 0.0, sp.get("f_clock") or 0.0, sp.get("f_wall") or 0.0,
                 sp.get("f_ang") or 0.0))
        for note in (sp.get("note") or "").split("；"):
            if note:
                print("  频率提示：%s" % note)
        print("  样本：AB 箱 %d 帧 / UVW 箱 %d 帧；覆盖率 AB %d/%d、UVW %d/%d"
              % (snap["samples_ab"], snap["samples_uvw"], snap["cover_ab"], snap["bins"],
                 snap["cover_uvw"], snap["bins"]))
        print("  占空比：A %.1f%%  B %.1f%%  Z %.4f%%（Z 命中 %d 帧）"
              % (snap["duty_a"] * 100, snap["duty_b"] * 100, snap["duty_z"] * 100, snap["z_hits"]))
        print("  A→B 相位差：%s（偏 %s；AB 一个周期 %.3f°，一步 %.3f°）"
              % ("%.1f°" % snap["phase_ab_deg"] if snap["phase_ab_deg"] is not None else "未测出",
                 "%.1f°" % snap["phase_ab_err"] if snap["phase_ab_err"] is not None else "-",
                 snap["ab_period_deg"], snap["edge_step_deg"]))
        print("  Z 脉宽 %.3f°（= (z_width+1)/4/inter 圈）" % snap["z_width_deg"])
        print("  UVW 六状态表：")
        tot = sum(snap["states"])
        for s in az.LEGAL_STATES:
            c = snap["states"][s]
            print("    %-8s %7d 帧  %6.2f%%" % (az.state_text(s), c,
                                                (c / float(tot) * 100.0) if tot else 0.0))
        if snap["illegal"]:
            bad_states = [(az.state_text(s), snap["states"][s]) for s in range(8)
                          if s not in az.LEGAL_STATES and snap["states"][s]]
            print("    非法态：%s（共 %d 帧）"
                  % (", ".join("%s×%d" % (t, c) for t, c in bad_states), snap["illegal"]))
        else:
            print("    非法态：无 ✓")
        if th:
            print("  理论对照：AB 边沿率 %.0f/秒、AB 周期 %.1f Hz、Z %.1f Hz、UVW %.0f Hz（%d 步/圈）"
                  % (th["ab_edge_rate"], th["ab_period_hz"], th["z_rate"], th["uvw_rate"],
                     th["uvw_sector_hz"]))
        zr = (snap["duty_z"] / snap["duty_z_theory"]) if snap["duty_z_theory"] else 0.0
        print("  Z 占空比对照：实测 %.5f、帧观测期望 %.5f（%.2f 倍）、时间口径 %.5f"
              % (snap["duty_z"], snap["duty_z_theory"], zr, snap["duty_z_theory_time"]))
        print("  独立口径：帧里 z_window 标志 %d 次（%.5f）、dir=1 %d/%d、limiter=1 %d/%d"
              % (n_zwin, n_zwin / float(n_fr), n_dir, n_fr, n_lim, n_fr))
        for note in snap.get("notes") or []:
            print("  提示：%s" % note)

        hr("⑤ 判定")
        # 采样简并：输入 ≈ 帧率整数倍时，帧落在输入周期内的相位几乎不动，A/B 边沿被折叠
        # 到同一条相位轨迹上 ⇒ 相位差**不可测**（同一份板上状态在非简并工况实测 −90.0°）。
        # 这种情况明说"跳过"，不计失败：否则用户换个信号源频率就会看到与代码无关的 FAIL。
        ratio = (abs(f_in) / az.FRAME_HZ) if f_in else 0.0
        degenerate = bool(f_in) and abs(ratio - round(ratio)) < 0.02
        # 等效采样的箱覆盖率随采样时长增长：8 s / 20 kHz 输入时整圈 256 箱能填 80% 以上，
        # 长跑会继续升高；这里只要求“大部分填上”（tools/demo_abz_uvw.py 的判据是 ≥50%）
        check("AB 等效采样箱填满 ≥75%", snap["cover_ab"] >= 0.75 * snap["bins"],
              "%d/%d = %.1f%%" % (snap["cover_ab"], snap["bins"], snap["cover_ab_pct"]))
        check("UVW 等效采样箱填满 ≥75%", snap["cover_uvw"] >= 0.75 * snap["bins"],
              "%d/%d = %.1f%%" % (snap["cover_uvw"], snap["bins"], snap["cover_uvw_pct"]))
        check("A 占空比 30…70%", 0.30 <= snap["duty_a"] <= 0.70, "%.1f%%" % (snap["duty_a"] * 100))
        check("B 占空比 30…70%", 0.30 <= snap["duty_b"] <= 0.70, "%.1f%%" % (snap["duty_b"] * 100))
        if snap.get("ab_muddy"):
            SKIP.append("A→B 相位差 = ±90°（AB 电平与角度不相关，不可测）")
            print("  -- A/B 电平与角度箱不相关 ⇒ 等效采样重建不出方波，相位差不可测，本项跳过；")
            for _nt in (snap.get("notes") or []):
                if "A/B 电平与角度箱不相关" in _nt:
                    print("     %s" % _nt)
            print("     （成因与可行做法就上面那句，由 host/abz.py 统一给出，避免两处说法不一致）")
        elif degenerate:
            SKIP.append("A→B 相位差 = ±90°（采样简并，不可测）")
            print("  -- 采样简并：输入 %.3f Hz ≈ 帧率 ×%.3f（整数倍）⇒ A/B 边沿被采样折叠，"
                  "相位差不可测（实测 %s），本项跳过；"
                  % (f_in, ratio, "%.1f°" % snap["phase_ab_deg"]
                     if snap["phase_ab_deg"] is not None else "未测出"))
            print("     要看相位差请把信号源调到帧率的非整数倍（例如 19,999.9 Hz / 1 kHz）")
        else:
            check("A→B 相位差 = ±90°±25°",
                  snap["phase_ab_err"] is not None and snap["phase_ab_err"] <= 25.0,
                  "%s" % ("%.1f°" % snap["phase_ab_deg"] if snap["phase_ab_deg"] is not None else "未测出"))
        if out_bits.get("uwven"):
            check("无非法 UVW 状态（允许重同步残帧 ≤0.05%）",
                  snap["illegal"] <= max(1, 0.0005 * snap["samples_ab"]),
                  "非法 %d 帧" % snap["illegal"])
            n_legal = len([s for s in az.LEGAL_STATES if snap["states"][s] > 0])
            check("六个合法状态都出现", n_legal == 6, "%d/6 种" % n_legal)
            worst = max(abs(snap["state_share"][s] - snap["state_expected_pct"])
                        for s in az.LEGAL_STATES)
            check("六状态占比均衡（±10%）", worst < 10.0, "最大偏差 %.2f%%" % worst)
        else:
            # ★ 2026-10-14 真机复查修：UVW 关着时 U/V/W 恒 0（U-V-W- 不属于六个合法态）,
            #   非法态计数与六状态覆盖本就不成立。此前只 gate 了"占比均衡"，另两项
            #   无条件执行 ⇒ 每次 UVW 未使能跑 S4 都误报 FAIL（实测 165,094 帧"非法态"）。
            SKIP.append("无非法 UVW 状态 / 六个合法状态都出现（UVW 未使能，不适用）")
            print("  -- 板上 UVW 未使能（0x0109 bit7 = 0），U/V/W 恒 0 ⇒ 非法态与六状态覆盖"
                  "本就不成立，跳过这三项判定")
        # ★ 2026-10-17 自查修：Z 的开关是 `abzen`（rtl/abz_gen.v:526
        #   `z_in_win = z_window & abzen`），**不是** zwidth。v9 起
        #   （rtl/abz_gen.v:520）zwidth = 0 也有 1 个边沿步的 Z 脉冲，旧写法
        #   `zwidth > 0` 会在用户把 Z 脉宽设成 0 时静默跳过全部 Z 判定。
        if out_bits.get("abzen"):
            # 注意：Z **允许**出现在 z_window 之外 —— rtl/abz_gen.v:677-686（v8 设计）把
            # “装载”留给窗口门控，而“脉冲推进 + 4096 clk 超时兜底”在窗外继续（否则集成
            # 路径的 z_window 提前 2 clk 关闭会把脉冲截成 40 ns）。所以只查“稀疏”不查包含。
            check("Z 脉冲稀疏（占空比 <5%）", (snap["duty_z"] or 0.0) < 0.05,
                  "%.4f%%（其中 %d 帧在 z_window 之外，属设计允许）"
                  % ((snap["duty_z"] or 0.0) * 100.0, n_z_no_win))
            check("Z 窗口标志位有出现", n_zwin > 0, "z_window 置位 %d 帧" % n_zwin)
            if degenerate:
                print("  -- 采样简并：输入 %.3f Hz ≈ 帧率 ×%.3f（整数倍），帧落在输入周期内的"
                      "相位几乎不动" % (f_in, ratio))
                print("     而 Z 只占 5/128 圈、每 64 圈一次 ⇒ 本窗口抓到 %d 帧 Z 属正常；"
                      "要观测 Z 请把输入频率调到帧率的非整数倍（例如 200~500 Hz）或长跑"
                      % snap["z_hits"])
            # ★ Z 的“逐帧抓取”只作提示、不作失败判定：Z 脉宽常态只有几个 idx_exec 拍
            #   （≈1 µs）而帧周期 100 µs，RTL 的 Z_TIMEOUT=4096 clk（≈82 µs）超时兜底
            #   又会把某些工况的脉宽拉长 ⇒ 同一工况逐帧命中数实测 0 / 107 / 197 都出现过
            #   （DEV_STATUS §1.64 记过 0/16/121/123）。Z 的“存在性”由「Z 窗口标志有出现」
            #   +「Z 脉冲稀疏」+ 离线 abz.py 自检负责，逐帧命中数只用来对照。
            exp_hits = (snap["duty_z_theory_time"] or 0.0) * n_fr
            print("  · Z 逐帧抓取：命中 %d / %d 帧（时间口径期望 %.1f 帧）—— 只作提示，不判失败"
                  % (snap["z_hits"], n_fr, exp_hits))
            pulse_theory = (f_in or 0.0) / float(az.Z_INDEX_PAIRS) * max(0.0, dt)
            print("  Z 抓取率：%d 命中 / %d 个窗口帧 = %.1f%%（理论上 %.0f 个 Z 脉冲）"
                  % (snap["z_hits"], n_zwin,
                     100.0 * snap["z_hits"] / max(1, n_zwin), pulse_theory))
        else:
            print("  -- 板上 ABZ 未使能（0x0109 bit6 = 0），A/B/Z 恒 0 ⇒ 跳过 Z 判定")
        check("方向位稳定（少数派 ≤0.1%）",
              min(n_dir, n_fr - n_dir) <= max(3, 0.001 * n_fr),
              "dir=1 %d/%d" % (n_dir, n_fr))
        check("限幅器未激活", n_lim == 0, "limiter=1 %d 帧" % n_lim)

        hr("结果")
        extra = ""
        if SKIP:
            extra = "；另有 %d 项因采样简并跳过（%s）" % (len(SKIP), "、".join(SKIP))
        if FAIL:
            print("  S4 验收自检 未通过（FAIL），共 %d 项不满足：" % len(FAIL))
            for name in FAIL:
                print("    ! %s" % name)
            if SKIP:
                print("    （%s）" % extra.lstrip("；"))
            return 1
        print("  ✓ 全部 %d 项通过（S4 验收自检 通过 PASS）%s" % (OK_N[0], extra))
        return 0
    finally:
        worker.stop()


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    sys.exit(main())
