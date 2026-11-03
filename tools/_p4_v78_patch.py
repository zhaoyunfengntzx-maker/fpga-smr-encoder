# -*- coding: utf-8 -*-
"""v78 P4 scope: 把整数 dec 换成分数累加器（Bresenham）采样。一次性补丁脚本。"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

old2 = """    // =========================================================================
    // 2. 采样周期（点数固定 256，靠"每 N 个 clk 一点"填满窗口）
    //    上区：dec_u = round(A 周期 / 64)，钳 [1,63]
    //          256 点 × dec ≈ 4 个 A 周期；dec=1 即"每 clk 一点"（inter=32 的标称点）
    //    下区：dec_l = round(电周期 / 256)，钳 [1,63]
    //          256 点 × dec ≈ 1 个电周期
    //    两处都是"+ 半个除数再右移"的四舍五入，没有除法器。
    // =========================================================================
    wire [16:0] u_sum = {1'b0, aclk} + 17'd32;    // (A 周期 + 32)
    wire [10:0] u_div = u_sum[16:6];              // / 64
    wire [5:0]  dec_u = (|u_div[10:6]) ? 6'd63 : ((u_div[5:0] == 6'd0) ? 6'd1 : u_div[5:0]);

    wire [21:0] l_sum = {1'b0, eclk} + 22'd128;   // (电周期 + 128)
    wire [13:0] l_div = l_sum[21:8];              // / 256
    wire [5:0]  dec_l = (|l_div[13:6]) ? 6'd63 : ((l_div[5:0] == 6'd0) ? 6'd1 : l_div[5:0]);
"""

new2 = """    // =========================================================================
    // 2. 采样时刻：**分数累加器**（Bresenham 式），不是"每 N 个 clk 一点"
    //    为什么不用整数 dec：dec 只能是整数，A 周期 96 clk 时 dec 该是 1.5，
    //    取整成 2 会把"4 个 A 周期"拉成 5.33 个 —— 上区刻度写着 0/1A/2A/3A/4A，
    //    边沿会跑到刻度的 3/4 处，一眼就看出错。
    //    累加器做法：每个 clk 给 acc 加**窗口内的点数**（256），acc 越过窗口长度
    //    win 就采一点并减掉 win。稳态下采样间隔 = win/256，可以带小数
    //    （1.5 clk 一点靠 1,2,1,2… 平均出来），而窗口**严格**等于 win。
    //    代价：一个加法器 + 一个比较器（无除法器），精度 1 clk/点。
    //    上区 win = 4 × A 周期（两次 A 上升沿之间叫一个 A 周期），下区 win = 1 个电周期。
    //    ★ win 在触发拍**冻结**成 win_u/win_l：窗口中途变速不会改这一帧的时基。
    //    ★ 退化：win < 256（A 边沿 > 780 kHz，1 点/clk 都不够）时累加器恒溢出，
    //      变成"每 clk 一点"、窗口 256 clk —— 只是显示多于 4 个 A 周期，不会死锁。
    // =========================================================================
    wire [18:0] acc_u_n = acc_u + 19'd256;        // 19 位：win_u ≤ 4*65535，再加 255
    wire [21:0] acc_l_n = acc_l + 22'd256;
"""

assert s.count(old2) == 1, "block2 not found"
s = s.replace(old2, new2)

# ---- §4 状态机：换成累加器采样 ----
old4 = """    reg        busy_u, busy_l;
    reg [7:0]  wp_u, wp_l;
    reg [5:0]  cu, cl;
    reg [5:0]  du, dl;
    reg        z_sticky;
"""
new4 = """    reg        busy_u, busy_l;
    reg [7:0]  wp_u, wp_l;
    reg [18:0] acc_u;                 // 上区采样相位累加器
    reg [21:0] acc_l;                 // 下区采样相位累加器
    reg [17:0] win_u;                 // 上区窗口长度（clk）= 4 × A 周期
    reg [21:0] win_l;                 // 下区窗口长度（clk）= 1 × 电周期
    reg        z_sticky;
"""
assert s.count(old4) == 1, "block4 decl not found"
s = s.replace(old4, new4)

old5 = """            busy_u <= 1'b0; busy_l <= 1'b0;
            wp_u   <= 8'd0;  wp_l  <= 8'd0;
            cu     <= 6'd0;  cl    <= 6'd0;
            du     <= 6'd1;  dl    <= 6'd1;
            z_sticky <= 1'b0;"""
new5 = """            busy_u <= 1'b0; busy_l <= 1'b0;
            wp_u   <= 8'd0;  wp_l  <= 8'd0;
            acc_u  <= 19'd0; acc_l <= 22'd0;
            win_u  <= 18'd256; win_l <= 22'd256;
            z_sticky <= 1'b0;"""
assert s.count(old5) == 1, "block5 reset not found"
s = s.replace(old5, new5)

old6 = """            // ---- 上区窗口 ----
            if (trig) begin
                busy_u <= 1'b1;
                wp_u   <= 8'd0;
                du     <= dec_u;
                cu     <= dec_u - 6'd1;            // 触发这一拍就采第 0 点
            end else if (busy_u) begin
                if (cu >= du - 6'd1) begin
                    up_mem[wp_u] <= i_q[1:0];
                    cu <= 6'd0;
                    if (wp_u == NDEP - 1) busy_u <= 1'b0;
                    else                  wp_u   <= wp_u + 8'd1;
                end else begin
                    cu <= cu + 6'd1;
                end
            end

            // ---- 下区窗口（顺带钉 Z 的窄脉冲：窗口内任何一次上升沿都记进
            //      当前样本的第 5 位，写进 lo_mem 后清零）----
            if (trig) begin
                busy_l <= 1'b1;
                wp_l   <= 8'd0;
                dl     <= dec_l;
                cl     <= dec_l - 6'd1;
                z_sticky <= 1'b0;
            end else if (busy_l) begin
                if (cl >= dl - 6'd1) begin
                    lo_mem[wp_l] <= {z_sticky | z_rise, i_q[5:2]};
                    cl <= 6'd0;
                    z_sticky <= 1'b0;
                    if (wp_l == NDEP - 1) busy_l <= 1'b0;
                    else                  wp_l   <= wp_l + 8'd1;
                end else begin
                    cl <= cl + 6'd1;
                    z_sticky <= z_sticky | z_rise;
                end
            end
"""
new6 = """            // ---- 上区窗口：第 0 点在触发拍，之后 acc 越过 win_u 就采一点 ----
            if (trig) begin
                up_mem[8'd0] <= i_q[1:0];          // 触发这一拍就是第 0 点
                busy_u <= 1'b1;
                wp_u   <= 8'd1;
                acc_u  <= 19'd0;
                win_u  <= {aclk, 2'b00};           // 4 × A 周期，冻结
            end else if (busy_u) begin
                if (acc_u_n >= {1'b0, win_u}) begin
                    up_mem[wp_u] <= i_q[1:0];
                    acc_u <= acc_u_n - {1'b0, win_u};
                    if (wp_u == NDEP - 1) busy_u <= 1'b0;
                    else                  wp_u   <= wp_u + 8'd1;
                end else begin
                    acc_u <= acc_u_n;
                end
            end

            // ---- 下区窗口（顺带钉 Z 的窄脉冲：窗口内任何一次上升沿都记进
            //      当前样本的第 5 位，写进 lo_mem 后清零）----
            if (trig) begin
                lo_mem[8'd0] <= {z_sticky | z_rise, i_q[5:2]};
                busy_l <= 1'b1;
                wp_l   <= 8'd1;
                acc_l  <= 22'd0;
                win_l  <= {1'b0, eclk};            // 1 × 电周期，冻结
                z_sticky <= 1'b0;
            end else if (busy_l) begin
                if (acc_l_n >= win_l) begin
                    lo_mem[wp_l] <= {z_sticky | z_rise, i_q[5:2]};
                    acc_l <= acc_l_n - win_l;
                    z_sticky <= 1'b0;
                    if (wp_l == NDEP - 1) busy_l <= 1'b0;
                    else                  wp_l   <= wp_l + 8'd1;
                end else begin
                    acc_l <= acc_l_n;
                    z_sticky <= z_sticky | z_rise;
                end
            end
"""
assert s.count(old6) == 1, "block6 fsm not found"
s = s.replace(old6, new6)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("p4_scope.v patched, %d bytes" % len(s))
