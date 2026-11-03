# -*- coding: utf-8 -*-
"""TB 修正：
   ① Z 改成**与电角度锁相**（ang[15:8]==0x40，宽 7.5 clk）—— 真机的 Z 本来就锁在
      机械相位上，锁相之后"窗内边沿标记"和"固定电角度竖标"才会落在同一列，
      像素域扫描也才能看出是一条连续的竖标。
   ② 180° 导通下每相每电周期只跳 2 次，原来的 5~6 期望是错的 ⇒ 改成 1..3，
      并加一条几何检查：U 的两个边沿相隔半个电周期 = 128 ±6 个样本。
   ③ Z 竖标像素宽度按 2 个样本算（≈6.7 px），允许 4..14 px。"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\_p4_work\tb_p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

old = """    reg  [9:0]  zcnt = 10'd0;
    reg         zpulse = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            ang <= 16'd0; zcnt <= 10'd0; zpulse <= 1'b0;
        end else begin
            ang <= ang + 16'd34;
            if (zcnt == 10'd999) begin zcnt <= 10'd0; zpulse <= 1'b1; end
            else begin
                zcnt <= zcnt + 10'd1;
                zpulse <= (zcnt >= 10'd995);
            end
        end
    end
"""
new = """    always @(posedge clk) begin
        if (!rst_n) ang <= 16'd0;
        else        ang <= ang + 16'd34;
    end
"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """        io6[2] <= zpulse;                                            // Z"""
new = """        io6[2] <= (ang[15:8] == 8'h40);                              // Z（与电角度锁相）"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """    integer i, n_ea, n_ev, n_ew, n_eu, n_ez, n_zpx, zpx_lo, zpx_hi;"""
new = """    integer i, n_ea, n_ev, n_ew, n_eu, n_ez, n_zpx, zpx_lo, zpx_hi;
    integer u_lo, u_hi;"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """            for (i = 1; i < NDEP; i = i + 1) begin
                if (snap_a[i][0] ^ snap_a[i-1][0]) n_ea = n_ea + 1;
                if (snap_l[i][1] ^ snap_l[i-1][1]) n_eu = n_eu + 1;   // lo[1]=U
                if (snap_l[i][2] ^ snap_l[i-1][2]) n_ev = n_ev + 1;   // lo[2]=V
                if (snap_l[i][3] ^ snap_l[i-1][3]) n_ew = n_ew + 1;   // lo[3]=W
            end"""
new = """            u_lo = -1; u_hi = -1;
            for (i = 1; i < NDEP; i = i + 1) begin
                if (snap_a[i][0] ^ snap_a[i-1][0]) n_ea = n_ea + 1;
                if (snap_l[i][1] ^ snap_l[i-1][1]) begin               // lo[1]=U
                    n_eu = n_eu + 1;
                    if (u_lo < 0) u_lo = i; else u_hi = i;
                end
                if (snap_l[i][2] ^ snap_l[i-1][2]) n_ev = n_ev + 1;   // lo[2]=V
                if (snap_l[i][3] ^ snap_l[i-1][3]) n_ew = n_ew + 1;   // lo[3]=W
            end"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """            if (n_eu < 4 || n_eu > 6) begin errors = errors + 1; $display("  ** FAIL: U 边沿 %0d", n_eu); end
            if (n_ev < 4 || n_ev > 6) begin errors = errors + 1; $display("  ** FAIL: V 边沿 %0d", n_ev); end
            if (n_ew < 4 || n_ew > 6) begin errors = errors + 1; $display("  ** FAIL: W 边沿 %0d", n_ew); end
            if (check_z && n_ez == 0) begin errors = errors + 1; $display("  ** FAIL: 窗口里没有 Z 标记"); end"""
new = """            // 180° 导通：每相每电周期 1 升 1 降 = 2 次；窗口边界可能吃掉一次 ⇒ 1..3
            if (n_eu < 1 || n_eu > 3) begin errors = errors + 1; $display("  ** FAIL: U 边沿 %0d", n_eu); end
            if (n_ev < 1 || n_ev > 3) begin errors = errors + 1; $display("  ** FAIL: V 边沿 %0d", n_ev); end
            if (n_ew < 1 || n_ew > 3) begin errors = errors + 1; $display("  ** FAIL: W 边沿 %0d", n_ew); end
            if (n_eu == 2) begin
                $display("[%0s] U 边沿位置 %0d / %0d，间隔 %0d 点（应 ≈128）", tag, u_lo, u_hi, u_hi - u_lo);
                if (u_hi - u_lo < 122 || u_hi - u_lo > 134) begin
                    errors = errors + 1; $display("  ** FAIL: U 两个边沿间隔 %0d 点，不是半个电周期", u_hi - u_lo);
                end
            end
            if (check_z && n_ez == 0) begin errors = errors + 1; $display("  ** FAIL: 窗口里没有 Z 标记"); end"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """            if (n_zpx < 3 || n_zpx > 16) begin
                errors = errors + 1;
                $display("  ** FAIL: Z 竖标宽度 %0d px 不在 3..16", n_zpx);
            end"""
new = """            if (n_zpx < 4 || n_zpx > 14) begin
                errors = errors + 1;
                $display("  ** FAIL: Z 竖标宽度 %0d px 不在 4..14", n_zpx);
            end
            if (zpx_hi - zpx_lo + 1 != n_zpx) begin
                errors = errors + 1;
                $display("  ** FAIL: Z 竖标不连续（%0d px 跨 %0d..%0d）", n_zpx, zpx_lo, zpx_hi);
            end"""
assert s.count(old) == 1
s = s.replace(old, new)

old = """        dump_and_check("帧1", 0);           // 帧1 时可能还没见过第一个 Z，Z 那项不查"""
new = """        dump_and_check("帧1", 1);           // Z 已锁相到电角度，帧1 也该有竖标"""
assert s.count(old) == 1
s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("tb updated, %d chars" % len(s))
