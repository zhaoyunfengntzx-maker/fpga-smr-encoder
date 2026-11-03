# -*- coding: utf-8 -*-
"""v78 patch14: 修正 lo_mem 位域的取位错误（TB 的像素域检查抓到的）。

lo_mem 布局：{ew, ev, eu, ez, zmark, w, v, u, z} = bit8..bit0
  ⇒ qlv（跳变）应该是 rl[8:5]（四个边沿位），zmark 是 rl[4]。
patch13 里写成了 `qlv = rl[7:4]`、`qz = rl[8]` ⇒
  ① qlv 把 {eu,ez,zmark,w} 当跳变（把 zmark 当 Z 跳变、漏掉 W 跳变）；
  ② qz 取的是 W 的边沿位 ⇒ Z 竖标在 W 跳变的样本上误亮
     （TB 实测 qz 在样本 1、63、64、65、129 亮，正确只有 63..65）。
"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

REPL = [
    (
        "    assign qlv = rl[7:4];\n"
        "    //   竖标 = \"窗口里真抓到 Z\"（rl[8]，边沿标记位）或 \"Z 的固定电角度在这里\"（z_r）\n"
        "    assign qz  = rl[8] | z_r;\n",
        "    assign qlv = rl[8:5];                   // 四个通道的跳变位\n"
        "    //   竖标 = \"窗口里真抓到 Z\"（rl[4]，zmark 位）或 \"Z 的固定电角度在这里\"（z_r）\n"
        "    assign qz  = rl[4] | z_r;\n",
    ),
]

for old, new in REPL:
    assert s.count(old) == 1, "old not unique (%d)" % s.count(old)
    s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("patch14 ok")
