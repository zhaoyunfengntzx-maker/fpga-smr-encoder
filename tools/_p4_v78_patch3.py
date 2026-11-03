# -*- coding: utf-8 -*-
"""v78 P4 scope: 把 acc_*_n 两个 wire 移到寄存器声明之后（Verilog 必须先声明后用）。"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

old = """    wire [18:0] acc_u_n = acc_u + 19'd256;        // 19 位：win_u ≤ 4*65535，再加 255
    wire [21:0] acc_l_n = acc_l + 22'd256;

"""
assert s.count(old) == 1
s = s.replace(old, "")

old2 = """    reg        z_sticky;

    integer k;"""
new2 = """    reg        z_sticky;

    //   累加器的下一个值（寄存器声明之后才能引用）
    wire [18:0] acc_u_n = acc_u + 19'd256;        // 19 位：win_u ≤ 4*65535，再加 255
    wire [21:0] acc_l_n = acc_l + 22'd256;

    integer k;"""
assert s.count(old2) == 1
s = s.replace(old2, new2)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("moved acc_*_n, %d chars" % len(s))
