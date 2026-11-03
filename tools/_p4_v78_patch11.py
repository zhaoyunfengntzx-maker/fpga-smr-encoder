# -*- coding: utf-8 -*-
"""v78 patch11: p4_scope.v 的 LUTRAM 改成**单读口**，改回真 distributed RAM。

根因（Vivado 综合日志）：
  WARNING: [Synth 8-7186] Applying attribute ram_style = "distributed" is ignored,
  object 'up_mem[0]', is not inferred as ram due to incorrect usage [p4_scope.v:193]
⇒ 两片缓冲没被认成 RAM，退化成 256×2 + 256×5 个触发器 + 两套 256:1 读 mux，
   LUT 18963/20800 = 91.17%（超 85% 上限）、寄存器 +2108。
原因：读口对同一片 memory 用了**两个不同地址**（sidx 与 sidx_p）⇒ 需要双读口，
Vivado 的 simple-dual-port 模板不接受（v77 是每片只有一个读地址）。

修法：把"样本边界跳变"在**写的时候就算进 bit 里**（写的时候上一个样本就在
upl/lol 里存着），读口只留一个地址 sidx。端口 qu/qv/ql/qlv/qz 完全不变，
disp_engine 不用改。
  上区 up_mem 4 bit = {edge_b, edge_a, b, a}
  下区 lo_mem 9 bit = {edge_w, edge_v, edge_u, edge_z, zmark, w, v, u, z}
"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

REPL = []

# --- 1) memory 声明 + 上一个样本寄存器 ---
REPL.append((
    '    (* ram_style = "distributed" *) reg [1:0] up_mem [0:NDEP-1];   // {b,a}\n'
    '    (* ram_style = "distributed" *) reg [4:0] lo_mem [0:NDEP-1];   // {z标记,w,v,u,z}\n',
    '    //   ★ 每片只有**一个**读地址（sidx）：Vivado 的 simple-dual-port 模板要求\n'
    '    //     1 写 + 1 读，读两个不同地址会直接放弃 RAM 推断、退化成 256 个触发器\n'
    '    //     + 256:1 读 mux（实测 LUT 从 82% 冲到 91%）。所以"样本边界跳变"在**写**\n'
    '    //     的时候就算好存进 bit 里：写的时候上一个样本还在 upl/lol 里。\n'
    '    (* ram_style = "distributed" *) reg [3:0] up_mem [0:NDEP-1];   // {eb,ea,b,a}\n'
    '    (* ram_style = "distributed" *) reg [8:0] lo_mem [0:NDEP-1];   // {ew,ev,eu,ez,zmark,w,v,u,z}\n'
    '    reg [1:0] upl;                    // 上一个写进 up_mem 的 {b,a}\n'
    '    reg [3:0] lol;                    // 上一个写进 lo_mem 的 {w,v,u,z}\n',
))

# --- 2) initial ---
REPL.append((
    '            up_mem[k] = 2\'b00;\n'
    '            lo_mem[k] = 5\'b00000;\n',
    '            up_mem[k] = 4\'b0000;\n'
    '            lo_mem[k] = 9\'b000000000;\n',
))

# --- 3) 复位：新增 upl/lol ---
REPL.append((
    '            ang_t  <= 16\'d0;\n'
    '            z_sticky <= 1\'b0;\n',
    '            ang_t  <= 16\'d0;\n'
    '            z_sticky <= 1\'b0;\n'
    '            upl    <= 2\'d0;  lol <= 4\'d0;\n',
))

# --- 4) 上区写口：触发拍 ---
REPL.append((
    '            if (trig) begin\n'
    '                up_mem[8\'d0] <= i_q[1:0];          // 触发这一拍就是第 0 点\n',
    '            if (trig) begin\n'
    '                up_mem[8\'d0] <= {2\'b00, i_q[1:0]}; // 触发这一拍就是第 0 点（无跳变）\n'
    '                upl           <= i_q[1:0];\n',
))

# --- 5) 上区写口：正常采样拍 ---
REPL.append((
    '                if (acc_u_n >= {1\'b0, win_u}) begin\n'
    '                    up_mem[wp_u] <= i_q[1:0];\n'
    '                    acc_u <= acc_u_n - {1\'b0, win_u};\n',
    '                if (acc_u_n >= {1\'b0, win_u}) begin\n'
    '                    up_mem[wp_u] <= {i_q[1:0] ^ upl, i_q[1:0]};\n'
    '                    upl   <= i_q[1:0];\n'
    '                    acc_u <= acc_u_n - {1\'b0, win_u};\n',
))

# --- 6) 下区写口：触发拍 ---
REPL.append((
    '                lo_mem[8\'d0] <= {z_sticky | z_rise, i_q[5:2]};\n'
    '                busy_l <= 1\'b1;\n',
    '                lo_mem[8\'d0] <= {4\'b0000, z_sticky | z_rise, i_q[5:2]};\n'
    '                lol           <= i_q[5:2];\n'
    '                busy_l <= 1\'b1;\n',
))

# --- 7) 下区写口：正常采样拍 ---
REPL.append((
    '                if (acc_l_n >= win_l) begin\n'
    '                    lo_mem[wp_l] <= {z_sticky | z_rise, i_q[5:2]};\n'
    '                    acc_l <= acc_l_n - win_l;\n'
    '                    z_sticky <= 1\'b0;\n',
    '                if (acc_l_n >= win_l) begin\n'
    '                    lo_mem[wp_l] <= {i_q[5:2] ^ lol, z_sticky | z_rise, i_q[5:2]};\n'
    '                    lol <= i_q[5:2];\n'
    '                    acc_l <= acc_l_n - win_l;\n'
    '                    z_sticky <= 1\'b0;\n',
))

# --- 8) 读口：单地址 ---
REPL.append((
    '    wire [7:0]  sidx   = rp[17:10];\n'
    '    wire [7:0]  sidx_p = (sidx == 8\'d0) ? 8\'d0 : (sidx - 8\'d1);\n',
    '    wire [7:0]  sidx   = rp[17:10];\n',
))

REPL.append((
    '    reg [1:0] ru, rup;\n'
    '    reg [4:0] rl, rlp;\n'
    '    reg       z_r;\n'
    '\n'
    '    always @(posedge clk) begin\n'
    '        ru  <= up_mem[sidx];\n'
    '        rup <= up_mem[sidx_p];\n'
    '        rl  <= lo_mem[sidx];\n'
    '        rlp <= lo_mem[sidx_p];\n'
    '        z_r <= z_hit;\n'
    '    end\n'
    '\n'
    '    assign qu  = ru;\n'
    '    assign qv  = ru ^ rup;                  // 样本边界上的跳变 => 画竖线\n'
    '    assign ql  = rl[3:0];\n'
    '    assign qlv = rl[3:0] ^ rlp[3:0];\n'
    '    //   竖标 = "窗口里真抓到 Z"（rl/rlp[4]，边沿标记位）或 "Z 的固定电角度在这里"（z_r）\n'
    '    assign qz  = rl[4] | rlp[4] | z_r;\n',
    '    reg [3:0] ru;\n'
    '    reg [8:0] rl;\n'
    '    reg       z_r;\n'
    '\n'
    '    always @(posedge clk) begin\n'
    '        ru  <= up_mem[sidx];\n'
    '        rl  <= lo_mem[sidx];\n'
    '        z_r <= z_hit;\n'
    '    end\n'
    '\n'
    '    assign qu  = ru[1:0];\n'
    '    assign qv  = ru[3:2];                   // 样本边界上的跳变 => 画竖线（写时算好）\n'
    '    assign ql  = rl[3:0];\n'
    '    assign qlv = rl[7:4];\n'
    '    //   竖标 = "窗口里真抓到 Z"（rl[8]，边沿标记位）或 "Z 的固定电角度在这里"（z_r）\n'
    '    assign qz  = rl[8] | z_r;\n',
))

for old, new in REPL:
    assert s.count(old) == 1, "old not unique (%d): %r" % (s.count(old), old[:70])
    s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("patch11 ok")
