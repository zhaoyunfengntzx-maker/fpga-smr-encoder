# -*- coding: utf-8 -*-
"""v78 P4 scope：触发还要等"电周期已量到"。
   A 触发只要求 ap_ok，但下区窗口长度是 eclk —— 上电第一个 A 沿之后 ep_ok 还是 0，
   第一帧的 win_l 会是 0（下区退化成每 clk 一点）。加 ep_ok 到 trig 上，第一帧就正确，
   代价只是上电后多等 ~2 个电周期（<80 µs）。
   trig_x（无 A 相时的退化触发）本身来自 e_wrap，天然有 ep_ok。"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

old = """    wire trig = ((trig_a & ap_ok) | (trig_x & ep_ok)) & cd_done;"""
new = """    //   下区窗口长度用 eclk ⇒ 任何触发都必须等 ep_ok；上区用 aclk ⇒ A 触发还要 ap_ok。
    wire trig = ((trig_a & ap_ok) | trig_x) & ep_ok & cd_done;"""
assert s.count(old) == 1
s = s.replace(old, new)
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("trig gated on ep_ok, %d chars" % len(s))
