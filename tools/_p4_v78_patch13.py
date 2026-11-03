# -*- coding: utf-8 -*-
"""v78 patch13: 把两片 LUTRAM 的写操作挪到**没有异步复位**的 always 块里。

Vivado 给出的真正原因（patch12 之后日志变成可解释的 8-4767）：
  WARNING: [Synth 8-4767] Trying to implement RAM 'up_mem_reg' in registers.
  ... Reason is one or more of the following :
        1: RAM is sensitive to asynchronous reset signal. this RTL style is not supported.
⇒ 只要存储的写语句和 `negedge rst_n` 在同一个 always 块里，Vivado 就拒收 RAM 推断。
  （前面两轮试验把这个原因和"常量下标写""initial 块"分开了。）

修法：写数据/写地址/写使能本来就是 patch12 里的组合线网，直接把写操作单独放进
`always @(posedge clk)`（无异步复位）；状态机里只保留upl/lol/指针/累加器。
"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

# 1) 上区：主状态机里去掉写存储
old1 = (
    "            if (we_u) begin\n"
    "                up_mem[wa_u] <= wd_u;              // 唯一的写存储语句\n"
    "                upl          <= i_q[1:0];\n"
)
new1 = (
    "            if (we_u) begin\n"
    "                upl          <= i_q[1:0];\n"
)

# 2) 下区：主状态机里去掉写存储
old2 = (
    "            if (we_l) begin\n"
    "                lo_mem[wa_l] <= wd_l;              // 唯一的写存储语句\n"
    "                lol          <= i_q[5:2];\n"
)
new2 = (
    "            if (we_l) begin\n"
    "                lol          <= i_q[5:2];\n"
)

# 3) 加独立的写口 always 块（放在读口之前）
old3 = (
    "    // =========================================================================\n"
    "    // 5. 读口：dx -> 样本号 -> 异步读 -> 打一拍（与 cx=px2 两拍对齐）\n"
)
new3 = (
    "    // =========================================================================\n"
    "    // 4b. 存储写口：**单独一个 always 块，且没有异步复位**\n"
    "    //   ★ 这是 LUTRAM 能不能被推断出来的关键：Vivado 的规则是「写存储的进程里\n"
    "    //     出现 negedge rst_n 就拒收」（日志原文：RAM is sensitive to asynchronous\n"
    "    //     reset signal, this RTL style is not supported），即使写语句根本不在复位\n"
    "    //     分支里也一样。所以写地址/写数据/写使能都做成组合线网（见 §4 的 wa_u/wd_u/\n"
    "    //     we_u），写操作只在这里出现一次。\n"
    "    //   分布式 RAM 上电全 0（initial 只是为了仿真时不留 X）。\n"
    "    // =========================================================================\n"
    "    always @(posedge clk) begin\n"
    "        if (we_u) up_mem[wa_u] <= wd_u;\n"
    "        if (we_l) lo_mem[wa_l] <= wd_l;\n"
    "    end\n"
    "\n"
    "    // =========================================================================\n"
    "    // 5. 读口：dx -> 样本号 -> 异步读 -> 打一拍（与 cx=px2 两拍对齐）\n"
)

for old, new in ((old1, new1), (old2, new2), (old3, new3)):
    assert s.count(old) == 1, "old not unique (%d): %r" % (s.count(old), old[:70])
    s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("patch13 ok")
