# -*- coding: utf-8 -*-
"""v78 patch12: 写口改成"单一写端口 + 地址永远是线网/寄存器"。

Vivado 综合日志：
  WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is ignored,
  object 'up_mem[0]', is not inferred as ram due to incorrect usage [p4_scope.v:197]
⇒ 两片缓冲退化成触发器 + 256:1 读 mux，全设计 LUT 18963/20800 = 91.17%（超 85%）。
试验排除：① 单读地址（patch11）仍然报错；② 删掉 initial 块仍然报错。
⇒ 剩下的"非常规用法"就是**常量下标写** `up_mem[8'd0] <= ...`（触发拍写第 0 点）：
  Vivado 遇到常量下标就认为这是在访问某个具体寄存器、不是 RAM 端口。

修法：写口只留一句 `up_mem[wa_u] <= wd_u;`，地址 wa_u / 数据 wd_u 都是模块级线网
（触发拍由 trig 选到 0 号），端口 qu/qv/ql/qlv/qz 与行为完全不变。
"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

# --- 1) 加模块级写口线网（放在 acc_n 声明之后）---
old1 = (
    "    wire [18:0] acc_u_n = acc_u + 19'd256;        // 19 位：win_u ≤ 4*65535，再加 255\n"
    "    wire [21:0] acc_l_n = acc_l + 22'd256;\n"
)
new1 = (
    "    wire [18:0] acc_u_n = acc_u + 19'd256;        // 19 位：win_u ≤ 4*65535，再加 255\n"
    "    wire [21:0] acc_l_n = acc_l + 22'd256;\n"
    "\n"
    "    //   写口：**唯一一句写存储**（地址/数据都是线网）。\n"
    "    //   ★ 千万不能写成 up_mem[8'd0] <= ...（常量下标）：Vivado 会认为那是在访问\n"
    "    //     某个具体寄存器、不是 RAM 端口，于是放弃 LUTRAM 推断 —— 两片缓冲退化成\n"
    "    //     1792 个触发器 + 256:1 读 mux，全设计 LUT 从 82% 直接冲到 91%\n"
    "    //     （Synth 8-7186 \"not inferred as ram due to incorrect usage\"）。\n"
    "    wire [7:0] wa_u = trig ? 8'd0 : wp_u;\n"
    "    wire       we_u = trig | (busy_u & (acc_u_n >= {1'b0, win_u}));\n"
    "    wire [3:0] wd_u = trig ? {2'b00, i_q[1:0]}\n"
    "                           : {i_q[1:0] ^ upl, i_q[1:0]};\n"
    "    wire [7:0] wa_l = trig ? 8'd0 : wp_l;\n"
    "    wire       we_l = trig | (busy_l & (acc_l_n >= win_l));\n"
    "    wire [8:0] wd_l = trig ? {4'b0000, z_sticky | z_rise, i_q[5:2]}\n"
    "                           : {i_q[5:2] ^ lol, z_sticky | z_rise, i_q[5:2]};\n"
)

# --- 2) 上区窗口 ---
old2 = (
    "            // ---- 上区窗口：第 0 点在触发拍，之后 acc 越过 win_u 就采一点 ----\n"
    "            if (trig) begin\n"
    "                up_mem[8'd0] <= {2'b00, i_q[1:0]}; // 触发这一拍就是第 0 点（无跳变）\n"
    "                upl           <= i_q[1:0];\n"
    "                busy_u <= 1'b1;\n"
    "                wp_u   <= 8'd1;\n"
    "                acc_u  <= 19'd0;\n"
    "                //   4 × A 周期；A 缺席（aclk 已饱和到 0xFFFF）时兜底 1024 clk\n"
    "                //   = 20 µs，否则这一帧要拖 5.24 ms 才结束\n"
    "                win_u  <= a_absent ? 18'd1024 : {aclk, 2'b00};\n"
    "                ang_t  <= a_q;                     // Z 竖标的基准角\n"
    "            end else if (busy_u) begin\n"
    "                if (acc_u_n >= {1'b0, win_u}) begin\n"
    "                    up_mem[wp_u] <= {i_q[1:0] ^ upl, i_q[1:0]};\n"
    "                    upl   <= i_q[1:0];\n"
    "                    acc_u <= acc_u_n - {1'b0, win_u};\n"
    "                    if (wp_u == NDEP - 1) busy_u <= 1'b0;\n"
    "                    else                  wp_u   <= wp_u + 8'd1;\n"
    "                end else begin\n"
    "                    acc_u <= acc_u_n;\n"
    "                end\n"
    "            end\n"
)
new2 = (
    "            // ---- 上区窗口：第 0 点在触发拍，之后 acc 越过 win_u 就采一点 ----\n"
    "            if (we_u) begin\n"
    "                up_mem[wa_u] <= wd_u;              // 唯一的写存储语句\n"
    "                upl          <= i_q[1:0];\n"
    "                if (trig) begin\n"
    "                    busy_u <= 1'b1;\n"
    "                    wp_u   <= 8'd1;\n"
    "                    acc_u  <= 19'd0;\n"
    "                    //   4 × A 周期；A 缺席（aclk 已饱和到 0xFFFF）时兜底 1024 clk\n"
    "                    //   = 20 µs，否则这一帧要拖 5.24 ms 才结束\n"
    "                    win_u  <= a_absent ? 18'd1024 : {aclk, 2'b00};\n"
    "                    ang_t  <= a_q;                 // Z 竖标的基准角\n"
    "                end else begin\n"
    "                    acc_u <= acc_u_n - {1'b0, win_u};\n"
    "                    if (wp_u == NDEP - 1) busy_u <= 1'b0;\n"
    "                    else                  wp_u   <= wp_u + 8'd1;\n"
    "                end\n"
    "            end else if (busy_u) begin\n"
    "                acc_u <= acc_u_n;\n"
    "            end\n"
)

# --- 3) 下区窗口 ---
old3 = (
    "            // ---- 下区窗口（顺带钉 Z 的窄脉冲：窗口内任何一次上升沿都记进\n"
    "            //      当前样本的第 5 位，写进 lo_mem 后清零）----\n"
    "            if (trig) begin\n"
    "                lo_mem[8'd0] <= {4'b0000, z_sticky | z_rise, i_q[5:2]};\n"
    "                lol           <= i_q[5:2];\n"
    "                busy_l <= 1'b1;\n"
    "                wp_l   <= 8'd1;\n"
    "                acc_l  <= 22'd0;\n"
    "                win_l  <= {1'b0, eclk};            // 1 × 电周期，冻结\n"
    "                z_sticky <= 1'b0;\n"
    "            end else if (busy_l) begin\n"
    "                if (acc_l_n >= win_l) begin\n"
    "                    lo_mem[wp_l] <= {i_q[5:2] ^ lol, z_sticky | z_rise, i_q[5:2]};\n"
    "                    lol <= i_q[5:2];\n"
    "                    acc_l <= acc_l_n - win_l;\n"
    "                    z_sticky <= 1'b0;\n"
    "                    if (wp_l == NDEP - 1) busy_l <= 1'b0;\n"
    "                    else                  wp_l   <= wp_l + 8'd1;\n"
    "                end else begin\n"
    "                    acc_l <= acc_l_n;\n"
    "                    z_sticky <= z_sticky | z_rise;\n"
    "                end\n"
    "            end\n"
)
new3 = (
    "            // ---- 下区窗口（顺带钉 Z 的窄脉冲：窗口内任何一次上升沿都记进\n"
    "            //      当前样本的 zmark 位，写进 lo_mem 后清零）----\n"
    "            if (we_l) begin\n"
    "                lo_mem[wa_l] <= wd_l;              // 唯一的写存储语句\n"
    "                lol          <= i_q[5:2];\n"
    "                z_sticky     <= 1'b0;              // 已经写进这一点的 zmark\n"
    "                if (trig) begin\n"
    "                    busy_l <= 1'b1;\n"
    "                    wp_l   <= 8'd1;\n"
    "                    acc_l  <= 22'd0;\n"
    "                    win_l  <= {1'b0, eclk};        // 1 × 电周期，冻结\n"
    "                end else begin\n"
    "                    acc_l <= acc_l_n - win_l;\n"
    "                    if (wp_l == NDEP - 1) busy_l <= 1'b0;\n"
    "                    else                  wp_l   <= wp_l + 8'd1;\n"
    "                end\n"
    "            end else if (busy_l) begin\n"
    "                acc_l     <= acc_l_n;\n"
    "                z_sticky  <= z_sticky | z_rise;\n"
    "            end\n"
)

for old, new in ((old1, new1), (old2, new2), (old3, new3)):
    assert s.count(old) == 1, "old not unique (%d): %r" % (s.count(old), old[:70])
    s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("patch12 ok")
