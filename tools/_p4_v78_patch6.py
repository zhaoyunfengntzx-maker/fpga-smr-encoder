# -*- coding: utf-8 -*-
"""v78 P4 scope：给 Z 加"电角度相位竖标"。
   问题：Z 每机械转才 1 个脉冲（25 Hz 时 40 ms 一次），而采集窗只有 1 个电周期
   （≈39 µs）—— 靠"窗口内正好碰上 Z"的概率约 0.1%，等于 Z 行永远空着。
   做法：一直记着最近一次 Z 上升沿时的**电角度** z_ang，触发时记下 a_q 当 ang_t，
   两者的差 (z_ang - ang_t) 就是 Z 在窗口里的位置（Z 的电角度是固定的，所以每帧
   都落在同一列 —— 这才是"稳定静态波形"该有的样子）。
   窗口内真碰上 Z 的老路径（z_sticky）保留，两者 OR 在一起画。"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

# ---- 1) §1 之后插入 z_ang ----
old = """    // =========================================================================
    // 2. 采样时刻：**分数累加器**（Bresenham 式），不是"每 N 个 clk 一点"
"""
new = """    // =========================================================================
    // 1b. Z 在**电角度**上的位置（给下区画竖标用）
    //   Z 是"每机械转 1 个"的窄脉冲：40 ms 一次，而采集窗只有 1 个电周期（≈39 µs），
    //   靠"窗口里正好碰上 Z"的概率 ≈ 0.1% —— Z 行会永远是空的。
    //   所以换个口径：一直记着**最近一次 Z 上升沿时的电角度** z_ang；Z 的电角度
    //   是固定的（机械相位 × pairs 折回 65536），所以 (z_ang - 触发角) 每帧都是
    //   同一个值，竖标稳定落在同一列。窗口内真碰上 Z 的 z_sticky 路径保留，两者 OR。
    reg [15:0] z_ang;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            z_ang <= 16'd0;
        else if (z_rise)       z_ang <= a_q;
    end

    // =========================================================================
    // 2. 采样时刻：**分数累加器**（Bresenham 式），不是"每 N 个 clk 一点"
"""
assert s.count(old) == 1
s = s.replace(old, new)

# ---- 2) 触发拍记 ang_t ----
old = """    reg [21:0] win_l;                 // 下区窗口长度（clk）= 1 × 电周期
    reg        z_sticky;"""
new = """    reg [21:0] win_l;                 // 下区窗口长度（clk）= 1 × 电周期
    reg [15:0] ang_t;                 // 触发时刻的电角度（Z 竖标的基准）
    reg        z_sticky;"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """                win_u  <= {aclk, 2'b00};           // 4 × A 周期，冻结"""
new = """                win_u  <= {aclk, 2'b00};           // 4 × A 周期，冻结
                ang_t  <= a_q;                     // Z 竖标的基准角"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """            win_u  <= 18'd256; win_l <= 22'd256;"""
new = """            win_u  <= 18'd256; win_l <= 22'd256;
            ang_t  <= 16'd0;"""
assert s.count(old) == 1
s = s.replace(old, new)

# ---- 3) 读口：Z 相位比较 ----
old = """    reg [1:0] ru, rup;
    reg [4:0] rl, rlp;

    always @(posedge clk) begin
        ru  <= up_mem[sidx];
        rup <= up_mem[sidx_p];
        rl  <= lo_mem[sidx];
        rlp <= lo_mem[sidx_p];
    end

    assign qu  = ru;
    assign qv  = ru ^ rup;                  // 样本边界上的跳变 => 画竖线
    assign ql  = rl[3:0];
    assign qlv = rl[3:0] ^ rlp[3:0];
    assign qz  = rl[4] | rlp[4];            // 本列或上一列有标记 => 竖标 6.7 px 宽"""
new = """    //   Z 的竖标位置：Z 相对触发点的电角度 / 256 = 第几个样本（窗口 256 点 = 1 个电周期）。
    //   z_pos 与 sidx 同宽，比较本身只有两个 8 位相等判断；z_pos-1 让竖标有
    //   2 个样本（6.7 px）宽，与水平轨的 2 px 粗线风格一致。
    wire [15:0] z_rel  = z_ang - ang_t;     // 只取模，环形差
    wire [7:0]  z_pos  = z_rel[15:8];
    wire        z_hit  = (sidx == z_pos) || (sidx == (z_pos - 8'd1));

    reg [1:0] ru, rup;
    reg [4:0] rl, rlp;
    reg       z_r;

    always @(posedge clk) begin
        ru  <= up_mem[sidx];
        rup <= up_mem[sidx_p];
        rl  <= lo_mem[sidx];
        rlp <= lo_mem[sidx_p];
        z_r <= z_hit;
    end

    assign qu  = ru;
    assign qv  = ru ^ rup;                  // 样本边界上的跳变 => 画竖线
    assign ql  = rl[3:0];
    assign qlv = rl[3:0] ^ rlp[3:0];
    //   竖标 = "窗口里真抓到 Z"（rl/rlp[4]，边沿标记位）或 "Z 的固定电角度在这里"（z_r）
    assign qz  = rl[4] | rlp[4] | z_r;"""
assert s.count(old) == 1
s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("z phase mark added, %d chars" % len(s))
