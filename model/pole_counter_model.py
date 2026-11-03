#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pole_counter_model.py —— rtl/pole_counter.v 的**逐周期一致**模型
================================================================================
用途：本机没有 Verilog 仿真器，这个模型按 clk 逐拍复刻 rtl/pole_counter.v 的
      寄存器/组合逻辑语义，并跑一遍 sim/tb_pole_counter.v 里同样的场景，
      用来证明"RTL 逻辑"与"测试台期望值"是自洽的（两边同时错的可能性很低）。

被建模的 RTL 语义（一一对应）
    stage1 : ang_d1 <= angle;  vld_d1 <= in_valid;  z_d1 <= z_window;
             if (vld_d1) prev_ang <= ang_d1, have_prev <= 1     (|| 用旧值)
    组合   : guard_act = guard_cnt != 0
             z_rise    = z_window & ~z_d1
             wrap_p_raw = have_prev & (prev_ang >= TOP_TH) & (ang_d1 <= LOW_TH)
             wrap_n_raw = have_prev & (ang_d1 >= TOP_TH) & (prev_ang <= LOW_TH)
             wrap_p_ev  = vld_d1 & wrap_p_raw & ~guard_act
             wrap_n_ev  = vld_d1 & wrap_n_raw & ~guard_act
             z_clr_apply= vld_d1 & (z_clr_pend | (z_rise & clr_on_z))
             do_upd     = vld_d1 | preset_en
             cnt_nxt    = preset_en ? preset : (z_clr_apply ? 0 : cnt + wp - wn)
    stage2 : wrap_pos/wrap_neg/cycle_cnt/pos_full/dir/out_valid 全部同拍寄存

运行：<bundled python> model/pole_counter_model.py
"""
import sys

AW = 16
CW = 16
GUARDW = 4
TOP_TH = (1 << AW) - (1 << (AW - 3))      # 57344 = 315deg
LOW_TH = (1 << (AW - 3)) - 1              # 8191  = 44.995deg
LATENCY = 2


class PoleCounter(object):
    def __init__(self):
        self.ang_d1 = 0
        self.vld_d1 = 0
        self.prev_ang = 0
        self.have_prev = 0
        self.guard_cnt = 0
        self.z_d1 = 0
        self.z_clr_pend = 0
        self.cycle_cnt = 0
        self.pos_full = 0
        self.dir = 1
        self.wrap_pos = 0
        self.wrap_neg = 0
        self.out_valid = 0

    def step(self, angle, in_valid=1, z_window=0, clr_on_z=0,
             preset=0, preset_en=0, glitch_guard=0):
        """返回本拍(边沿之后)的输出，与 RTL 端口同名"""
        # ---- 组合逻辑（用边沿前的寄存器值） ----
        guard_act = (self.guard_cnt != 0)
        z_rise = 1 if (z_window and not self.z_d1) else 0
        wrap_p_raw = self.have_prev and (self.prev_ang >= TOP_TH) and (self.ang_d1 <= LOW_TH)
        wrap_n_raw = self.have_prev and (self.ang_d1 >= TOP_TH) and (self.prev_ang <= LOW_TH)
        wrap_p_ev = 1 if (self.vld_d1 and wrap_p_raw and not guard_act) else 0
        wrap_n_ev = 1 if (self.vld_d1 and wrap_n_raw and not guard_act) else 0
        wrap_any = wrap_p_ev or wrap_n_ev
        z_clr_req = 1 if (z_rise and clr_on_z) else 0
        z_clr_apply = 1 if (self.vld_d1 and (self.z_clr_pend or z_clr_req)) else 0
        do_upd = 1 if (self.vld_d1 or preset_en) else 0
        cnt_wrap = self.cycle_cnt + wrap_p_ev - wrap_n_ev
        if preset_en:
            cnt_nxt = preset
        elif z_clr_apply:
            cnt_nxt = 0
        else:
            cnt_nxt = cnt_wrap
        pos_nxt = ((cnt_nxt & 0xFFFF) << AW) | (self.ang_d1 & 0xFFFF)

        # ---- 边沿更新 ----
        old_vld, old_ang_d1 = self.vld_d1, self.ang_d1
        self.ang_d1 = angle & 0xFFFF
        self.vld_d1 = 1 if in_valid else 0
        self.z_d1 = 1 if z_window else 0
        if old_vld:
            self.prev_ang = old_ang_d1
            self.have_prev = 1
        if do_upd:
            self.cycle_cnt = cnt_nxt
            self.pos_full = pos_nxt
        self.wrap_pos = wrap_p_ev
        self.wrap_neg = wrap_n_ev
        if wrap_p_ev:
            self.dir = 1
        elif wrap_n_ev:
            self.dir = 0
        if z_clr_apply:
            self.z_clr_pend = 0
        elif z_clr_req:
            self.z_clr_pend = 1
        if wrap_any:
            self.guard_cnt = glitch_guard & ((1 << GUARDW) - 1)
        elif guard_act:
            self.guard_cnt -= 1
        self.out_valid = old_vld
        return (self.wrap_pos, self.wrap_neg, self.cycle_cnt,
                self.out_valid, self.pos_full, self.dir)


class Monitor(object):
    """对应 tb 里的 always @(posedge clk) if (out_valid) 统计"""

    def __init__(self):
        self.npos = 0
        self.nneg = 0

    def sample(self, dut):
        if dut.out_valid:
            if dut.wrap_pos:
                self.npos += 1
            if dut.wrap_neg:
                self.nneg += 1


def sweep(dut, mon, n, step, angle=0, in_valid=1, guard=0):
    for _ in range(n):
        angle = (angle + step) & 0xFFFF
        dut.step(angle, in_valid=in_valid, glitch_guard=guard)
        mon.sample(dut)
    for _ in range(8):
        dut.step(angle, in_valid=0, glitch_guard=guard)
        mon.sample(dut)
    return angle


def pair(dut, mon, a0, a1, guard=0):
    """对应 tb 的 pair 任务：推 a0,a0,a1 然后取脉冲"""
    for a in (a0, a0, a1):
        dut.step(a, in_valid=1, glitch_guard=guard)
        mon.sample(dut)
    dut.step(a1, in_valid=0, glitch_guard=guard)
    mon.sample(dut)
    return dut.wrap_pos, dut.wrap_neg


def burst(dut, mon, n, guard):
    """对应 tb 的 burst 任务：连续交替 350deg / 0.24deg"""
    for i in range(n):
        a = 63716 if (i % 2 == 0) else 44
        dut.step(a, in_valid=1, glitch_guard=guard)
        mon.sample(dut)
    dut.step(63716, in_valid=0, glitch_guard=guard)
    mon.sample(dut)
    for _ in range(20):
        dut.step(63716, in_valid=0, glitch_guard=guard)
        mon.sample(dut)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    ok = True
    print("pole_counter 逐周期模型：AW=%d CW=%d 窗口=[%d,%d)->[0,%d] Latency=%d"
          % (AW, CW, TOP_TH, 1 << AW, 1 << (AW - 3), LATENCY))

    # 1 复位
    d, m = PoleCounter(), Monitor()
    print("\n[1] 复位: cnt=%d dir=%d wp=%d wn=%d" % (d.cycle_cnt, d.dir, d.wrap_pos, d.wrap_neg))
    ok &= (d.cycle_cnt == 0 and d.dir == 1)

    # 2 正转 5 圈
    d, m = PoleCounter(), Monitor()
    sweep(d, m, 700, 512)
    print("[2] 正转 +512/拍 700 点: cnt=%d pos=%d neg=%d dir=%d  (期望 5/5/0/1)"
          % (d.cycle_cnt, m.npos, m.nneg, d.dir))
    ok &= (d.cycle_cnt == 5 and m.npos == 5 and m.nneg == 0 and d.dir == 1)

    # 3 反转 5 圈
    d, m = PoleCounter(), Monitor()
    sweep(d, m, 700, -512)
    print("[3] 反转 -512/拍 700 点: cnt=%d pos=%d neg=%d dir=%d  (期望 -5/0/5/0)"
          % (d.cycle_cnt, m.npos, m.nneg, d.dir))
    ok &= (d.cycle_cnt == -5 and m.nneg == 5 and m.npos == 0 and d.dir == 0)

    # 4 边界
    print("[4] 跨零窗口边界：")
    cases = [
        (57344, 0,     1, 0, "prev=315.000 cur=0.000"),
        (57343, 0,     0, 0, "prev=314.995 cur=0.000"),
        (65535, 8191,  1, 0, "prev=359.995 cur=44.995"),
        (65535, 8192,  0, 0, "prev=359.995 cur=45.000"),
        (0,     57344, 0, 1, "prev=0.000  cur=315.000"),
        (0,     57343, 0, 0, "prev=0.000  cur=314.995"),
    ]
    for a0, a1, ewp, ewn, name in cases:
        d, m = PoleCounter(), Monitor()
        wp, wn = pair(d, m, a0, a1)
        good = (wp == ewp and wn == ewn)
        ok &= good
        print("    %-28s -> wp=%d wn=%d  %s" % (name, wp, wn, "ok" if good else "FAIL"))

    # 5a 平衡抖动（9 个交替样点 = 8 次跨零 = 4 正 4 负）
    d, m = PoleCounter(), Monitor()
    burst(d, m, 9, 0)
    print("[5a] 平衡抖动 8 次跨零 guard=0: cnt=%d pos=%d neg=%d  (期望 0/4/4)"
          % (d.cycle_cnt, m.npos, m.nneg))
    ok &= (d.cycle_cnt == 0 and m.npos == 4 and m.nneg == 4)

    # 5b guard
    d, m = PoleCounter(), Monitor()
    burst(d, m, 9, 0)
    print("[5b] 快速抖动 8 次跨零 guard=0: cnt=%d 脉冲=%d  (期望 8 个脉冲)"
          % (d.cycle_cnt, m.npos + m.nneg))
    ok &= (m.npos + m.nneg == 8)
    d, m = PoleCounter(), Monitor()
    burst(d, m, 9, 8)
    print("     快速抖动 8 次跨零 guard=8: cnt=%d 脉冲=%d  (期望 1 个脉冲)"
          % (d.cycle_cnt, m.npos + m.nneg))
    ok &= (m.npos + m.nneg == 1)

    # 5c 扇区内抖动
    d, m = PoleCounter(), Monitor()
    for i in range(60):
        d.step(7300 if i % 2 == 0 else 7900, in_valid=1)
        m.sample(d)
    for _ in range(8):
        d.step(7900, in_valid=0)
        m.sample(d)
    print("[5c] 扇区内抖动(40.1deg<->43.4deg): cnt=%d 脉冲=%d" % (d.cycle_cnt, m.npos + m.nneg))
    ok &= (d.cycle_cnt == 0 and m.npos + m.nneg == 0)

    # 6 稀疏 valid（每 4 拍 1 个）
    d, m = PoleCounter(), Monitor()
    ang = 0
    for _ in range(700):
        ang = (ang + 512) & 0xFFFF
        d.step(ang, in_valid=1); m.sample(d)
        for _ in range(3):
            d.step(ang, in_valid=0); m.sample(d)
    for _ in range(8):
        d.step(ang, in_valid=0); m.sample(d)
    print("[6] in_valid 每 4 拍 1 个: cnt=%d pos=%d  (期望 5/5)" % (d.cycle_cnt, m.npos))
    ok &= (d.cycle_cnt == 5 and m.npos == 5)

    # 7 preset / Z 清零
    d, m = PoleCounter(), Monitor()
    d.step(0, in_valid=1, preset=1000, preset_en=1)
    d.step(0, in_valid=1, preset=1000, preset_en=0)
    print("[7a] preset_en: cnt=%d (期望 1000)" % d.cycle_cnt)
    ok &= (d.cycle_cnt == 1000)

    d, m = PoleCounter(), Monitor()
    sweep(d, m, 700, 512)
    before = d.cycle_cnt
    # 继续给有效样点，同时制造 Z 上升沿（RU 的 z_clr_apply 需要有效样点）
    zc = 0
    for i in range(10):
        zc = 1 if i in (2, 3) else 0
        d.step(40000, in_valid=1, z_window=zc, clr_on_z=1)
        m.sample(d)
    for _ in range(4):
        d.step(40000, in_valid=1, z_window=0, clr_on_z=1)
    print("[7b] Z 上升沿清零: %d -> %d (期望 5 -> 0)" % (before, d.cycle_cnt))
    ok &= (before == 5 and d.cycle_cnt == 0)

    # 8 pos_full
    d, m = PoleCounter(), Monitor()
    sweep(d, m, 300, 512)
    hi = (d.pos_full >> AW) & 0xFFFF
    if hi >= (1 << (CW - 1)):
        hi -= (1 << CW)
    print("[8] pos_full 高位=%d cycle_cnt=%d 低位角度=%d" % (hi, d.cycle_cnt, d.pos_full & 0xFFFF))
    ok &= (hi == d.cycle_cnt)

    print("\n  TEST %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
