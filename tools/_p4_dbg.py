# -*- coding: utf-8 -*-
import io
p = r"C:\Users\zhaoy\Desktop\FPGA\_p4_work\tb_p4_scope.v"
s = io.open(p, encoding="utf-8", newline="\n").read()
old = '''        $display("[trig] t=%0t aclk=%0d eclk=%0d win_u=%0d win_l=%0d", $time,
                 dut.aclk, dut.eclk, dut.win_u, dut.win_l);'''
new = '''        $display("[trig] t=%0t aclk=%0d eclk=%0d win_u=%0d win_l=%0d ecnt=%0d acnt=%0d ew=%b ang=%h",
                 $time, dut.aclk, dut.eclk, dut.win_u, dut.win_l,
                 dut.ecnt, dut.acnt, dut.e_wrap, dut.a_q);'''
assert s.count(old) == 1
io.open(p, "w", encoding="utf-8", newline="\n").write(s.replace(old, new))
print("ok")
