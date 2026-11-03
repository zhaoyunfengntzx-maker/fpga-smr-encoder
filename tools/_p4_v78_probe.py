# -*- coding: utf-8 -*-
"""生成两个综合试验变体，用来定位 "not inferred as ram due to incorrect usage"。

  _p4_work/t_none.v —— 去掉 initial 块
  _p4_work/t_sim.v  —— initial 块只给仿真用（`ifndef SYNTHESIS 包起来）
"""
import io
import re

s = io.open(r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v", encoding="utf-8", newline="\n").read()

a = re.sub(r"    integer k;\n    initial begin\n(?:.*\n)*?    end\n\n", "", s, count=1)
assert a != s, "initial block not found"
assert "initial begin" not in a
io.open(r"C:\Users\zhaoy\Desktop\FPGA\_p4_work\t_none.v", "w", encoding="utf-8", newline="\n").write(a)

old = "    integer k;\n    initial begin"
new = "    integer k;\n`ifndef SYNTHESIS\n    initial begin"
assert s.count(old) == 1
b = s.replace(old, new)
tail_old = "            lo_mem[k] = 9'b000000000;\n        end\n    end\n"
tail_new = tail_old + "`endif\n"
assert b.count(tail_old) == 1
b = b.replace(tail_old, tail_new)
io.open(r"C:\Users\zhaoy\Desktop\FPGA\_p4_work\t_sim.v", "w", encoding="utf-8", newline="\n").write(b)
print("wrote _p4_work/t_none.v and _p4_work/t_sim.v")
