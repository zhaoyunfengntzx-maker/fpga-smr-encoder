//=============================================================================
// tb_ring_lut.v -- 真圆环折叠表自检（㉕）
//
// 这张表把"像素到按钮中心的距离 / 角度"离线算好（tools/gen_ring_lut.py），RTL
// 只做「折叠坐标 -> {valid, k}」的查表。这一层要挡住的错误是：
//   [1] valid 位与几何不符（半径写错、折叠公式写反、环带被改成实心）
//   [2] k 不是角度的单调函数（象限内顺序反了 / 角度算错）
//   [3] 四象限装配后盖不满 64 个扇区（装配式与生成器的 assemble 不一致）
//   [4] 若干黄金表项被改动（两条中线 + 45 度对角线上的取样）
//   [5] 像素域与折叠域对不上（像素 -> 折叠坐标的映射写错：把 fold 写成别的东西
//       时，64x64 里落进带内的像素数就不再等于 表项按重数展开的总数）
//
// 判据只用整数：象限内角度的大小关系用 (2ju+1)*(2jv'+1) 交叉相乘比较，**不依赖
// atan2**（Verilog 没有它）；距离判据在四分之一像素单位上比平方（u4 = 4*ju+2 是
// 实心像素中心到中线的距离）。最后把整张 64x64 的扇区图打成字符画供人眼核对。
//=============================================================================
`timescale 1ns / 1ps

module tb_ring_lut;

    localparam integer NDEPTH = 1024;   // 32x32 折叠表
    localparam integer R_IN   = 26;     // 环带内径（px）
    localparam integer R_OUT  = 30;     // 环带外径（px）
    localparam integer N_SEC  = 64;     // 扇区数（= pnl_prog 的级数）
    localparam integer NBTN   = 64;     // 按钮边长

    reg         clk  = 1'b0;
    reg  [9:0]  addr = 10'd0;
    wire [4:0]  q;

    integer errors  = 0;
    integer n_valid = 0;
    integer n_empty = 0;
    integer n_px    = 0;
    integer n_exp   = 0;

    reg [4:0] tab [0:NDEPTH-1];
    integer   cov [0:N_SEC-1];       // 每个扇区里的像素数（'cover' 是 SV 关键字，避开）

    integer i, x, y, ju, jv, u4, v4, r2;
    integer lo2, hi2, la, sz, mult;
    integer jua, jva, jub, jvb, pa, pb, ka, kb;
    integer qd, s, xl, yl;
    integer n_ord, n_bad_ord, n_bad_geom;

    ring_lut u_dut (.clk(clk), .addr(addr), .q(q));

    always #5 clk = ~clk;

    // ---------------------------------------------------------------------
    // 折叠与象限装配：与 disp/disp_engine.v、tools/gen_ring_lut.py 同式
    // ---------------------------------------------------------------------
    function [4:0] fold(input [5:0] v);
        begin
            fold = v[5] ? v[4:0] : (v[4:0] ^ 5'h1F);
        end
    endfunction

    function [5:0] assemble(input [1:0] qq, input [3:0] kk);
        begin
            case (qq)
                2'd0:    assemble = {2'b0, kk};
                2'd1:    assemble = 6'd31 - {2'b0, kk};
                2'd2:    assemble = 6'd32 + {2'b0, kk};
                default: assemble = 6'd63 - {2'b0, kk};
            endcase
        end
    endfunction

    function [1:0] quadrant(input [5:0] xx, input [5:0] yy);
        begin
            quadrant = (xx > 6'd31 && yy <= 6'd31) ? 2'd0 :
                       (xx > 6'd31 && yy >  6'd31) ? 2'd1 :
                       (xx <= 6'd31 && yy > 6'd31) ? 2'd2 : 2'd3;
        end
    endfunction

    // 折叠是 2:1 的镜像映射：每个折叠坐标恰好对应 2 个按钮内下标
    function integer mult_of(input integer j);
        begin
            mult_of = 2;
        end
    endfunction

    // 带上采样点 (x,y) 的全局扇区号（不在带内返回 -1，表项说不在带内返回 -2）
    function integer sec_at(input [5:0] xx, input [5:0] yy);
        integer xu, yv, uu, vv, rr;
        begin
            xu = fold(xx);
            yv = fold(yy);
            uu = 4 * xu + 2;
            vv = 4 * yv + 2;
            rr = uu * uu + vv * vv;
            if (!(rr >= 16 * R_IN * R_IN && rr <= 16 * R_OUT * R_OUT)) sec_at = -1;
            else if (tab[yv * 32 + xu][4] !== 1'b1)                     sec_at = -2;
            else sec_at = assemble(quadrant(xx, yy), tab[yv * 32 + xu][3:0]);
        end
    endfunction

    task check_gold(input integer ju_g, input integer jv_g,
                    input        exp_v, input [3:0] exp_k,
                    input [255:0] tag);
        reg [4:0] got;
        begin
            got = tab[jv_g * 32 + ju_g];
            if (got[4] !== exp_v || (exp_v === 1'b1 && got[3:0] !== exp_k)) begin
                $display("[FAIL] 黄金表项 %0s: (ju=%0d,jv=%0d) 表={valid=%0d,k=%0d} 应为 {valid=%0d,k=%0d}",
                         tag, ju_g, jv_g, got[4], got[3:0], exp_v, exp_k);
                errors = errors + 1;
            end else begin
                $display("[ OK ] 黄金表项 %0s: (ju=%0d,jv=%0d) = {valid=%0d,k=%0d}",
                         tag, ju_g, jv_g, got[4], got[3:0]);
            end
        end
    endtask

    // 正方向判据：像素必须落在带内，且扇区号等于 target（允许 ±1 个扇区 ——
    // 扇区边界正好压在按钮中线上）
    task check_dir(input [5:0] xx, input [5:0] yy, input integer target,
                   input [255:0] tag);
        integer got, d1, d2;
        begin
            got = sec_at(xx, yy);
            d1  = (got + 1) % N_SEC;
            d2  = (got + N_SEC - 1) % N_SEC;
            if (got < 0)
                $display("[FAIL] %0s 像素 (%0d,%0d) 不在环带内（sec_at=%0d）", tag, xx, yy, got);
            else if (got !== target && d1 !== target && d2 !== target)
                $display("[FAIL] %0s 像素 (%0d,%0d) 扇区 %0d，应为 %0d（±1）", tag, xx, yy, got, target);
            else
                $display("[ OK ] %0s 像素 (%0d,%0d) 扇区 %0d（目标 %0d）", tag, xx, yy, got, target);
            if (got < 0 || (got !== target && d1 !== target && d2 !== target))
                errors = errors + 1;
        end
    endtask

    initial begin
        // ---- 读全表（1 拍寄存读：给地址 -> 等一个 posedge -> 采样）----
        for (i = 0; i < NDEPTH; i = i + 1) begin
            addr = i[9:0];
            @(posedge clk);
            #1;
            tab[i] = q;
            if (q[4]) n_valid = n_valid + 1;
        end
        $display("[info] 折叠表 %0d 项，带内 %0d 项（%0d%%）",
                 NDEPTH, n_valid, (n_valid * 100) / NDEPTH);

        // ---- [1] valid 位 == 环带几何 ----
        lo2 = 16 * R_IN * R_IN;         // (4*R_IN)^2，u4/v4 是四分之一像素单位
        hi2 = 16 * R_OUT * R_OUT;
        n_bad_geom = 0;
        for (jv = 0; jv < 32; jv = jv + 1) begin
            for (ju = 0; ju < 32; ju = ju + 1) begin
                u4 = 4 * ju + 2;
                v4 = 4 * jv + 2;
                r2 = u4 * u4 + v4 * v4;
                la = ((r2 >= lo2) && (r2 <= hi2)) ? 1 : 0;
                if (tab[jv * 32 + ju][4] !== la) begin
                    if (n_bad_geom < 5)
                        $display("[FAIL] valid 与几何不符: ju=%0d jv=%0d 表=%0d 应为=%0d (r2=%0d, 带=%0d..%0d)",
                                 ju, jv, tab[jv * 32 + ju][4], la, r2, lo2, hi2);
                    n_bad_geom = n_bad_geom + 1;
                    errors = errors + 1;
                end
                if (la == 1) n_exp = n_exp + mult_of(ju) * mult_of(jv);
            end
        end
        if (n_bad_geom === 0)
            $display("[ OK ] 1024 项 valid 位与环带几何（R_IN=%0d, R_OUT=%0d，四分之一像素整数比较）完全一致",
                     R_IN, R_OUT);
        else
            $display("[FAIL] valid 位与几何不符: %0d 项", n_bad_geom);

        // ---- [2] k 必须是角度的单调不减函数（同角必同 k）----
        //   象限内角度 = atan2(ju+0.5, jv+0.5)，比较 (2ju+1)/(2jv+1) 的交叉乘积。
        n_ord = 0; n_bad_ord = 0;
        for (jva = 0; jva < 32; jva = jva + 1) begin
            for (jua = 0; jua < 32; jua = jua + 1) begin
                if (tab[jva * 32 + jua][4] !== 1'b1) continue;
                ka = tab[jva * 32 + jua][3:0];
                for (jvb = 0; jvb < 32; jvb = jvb + 1) begin
                    for (jub = 0; jub < 32; jub = jub + 1) begin
                        if (tab[jvb * 32 + jub][4] !== 1'b1) continue;
                        kb = tab[jvb * 32 + jub][3:0];
                        pa = (2 * jua + 1) * (2 * jvb + 1);
                        pb = (2 * jub + 1) * (2 * jva + 1);
                        n_ord = n_ord + 1;
                        if (pa < pb && ka > kb) begin
                            if (n_bad_ord < 5)
                                $display("[FAIL] k 与角度反序: (ju=%0d,jv=%0d)->k=%0d 在 (ju=%0d,jv=%0d)->k=%0d 之前，却更大",
                                         jua, jva, ka, jub, jvb, kb);
                            n_bad_ord = n_bad_ord + 1;
                            errors = errors + 1;
                        end
                        if (pa == pb && ka != kb) begin
                            if (n_bad_ord < 5)
                                $display("[FAIL] 同角度不同 k: (ju=%0d,jv=%0d)->k=%0d vs (ju=%0d,jv=%0d)->k=%0d",
                                         jua, jva, ka, jub, jvb, kb);
                            n_bad_ord = n_bad_ord + 1;
                            errors = errors + 1;
                        end
                    end
                end
            end
        end
        if (n_bad_ord === 0)
            $display("[ OK ] k 是角度的单调不减函数（%0d 对比较，含同角必同 k）", n_ord);
        else
            $display("[FAIL] k 与角度不一致: %0d 对", n_bad_ord);

        // ---- [3] 四象限装配后必须盖满 64 个扇区 ----
        for (i = 0; i < N_SEC; i = i + 1) cov[i] = 0;
        for (jv = 0; jv < 32; jv = jv + 1) begin
            for (ju = 0; ju < 32; ju = ju + 1) begin
                if (tab[jv * 32 + ju][4] !== 1'b1) continue;
                for (qd = 0; qd < 4; qd = qd + 1) begin
                    s = assemble(qd[1:0], tab[jv * 32 + ju][3:0]);
                    cov[s] = cov[s] + 1;
                end
            end
        end
        n_empty = 0;
        for (i = 0; i < N_SEC; i = i + 1) begin
            if (cov[i] == 0) begin
                if (n_empty < 8) $display("[FAIL] 扇区 %0d 一个像素都没有", i);
                n_empty = n_empty + 1;
                errors = errors + 1;
            end
        end
        if (n_empty === 0) begin
            sz = cov[0];
            for (i = 1; i < N_SEC; i = i + 1)
                if (cov[i] < sz) sz = cov[i];
            $display("[ OK ] 64 个扇区全被覆盖（每扇区至少 %0d 个像素）", sz);
        end
        else
            $display("[FAIL] 空扇区 %0d 个", n_empty);

        // ---- [4] 黄金表项：两条中线 + 45 度对角线 + 带内/带外各一个 ----
        check_gold(26,  0, 1'b1, 4'd15, "3 点方向（中线右端）");
        check_gold( 0, 26, 1'b1, 4'd0,  "12 点方向（中线上端）");
        check_gold(20, 20, 1'b1, 4'd8,  "45 度对角线");
        check_gold( 0,  0, 1'b0, 4'd0,  "圆心附近（R=1.4，带内不到）");
        check_gold(16, 16, 1'b0, 4'd0,  "对角线内侧（R=11.7，带内不到）");
        check_gold(31, 31, 1'b0, 4'd0,  "按钮角落（R=43.1，带外）");

        // ---- [5] + 人眼核对：64x64 按钮上的扇区图 ----
        //   个位数字 = 全局扇区号，'.' = 不在带内。"12 点起顺时针、每步 +1"
        //   是这张图要一眼看出来的性质；同时数一遍带内像素数与表项重数展开对比。
        $display("");
        $display("---- 64x64 按钮扇区图（数字 = 扇区号的个位，'.' = 环外）----");
        for (y = 0; y < NBTN; y = y + 1) begin
            $write("  ");
            for (x = 0; x < NBTN; x = x + 1) begin
                xl = fold(x[5:0]);
                yl = fold(y[5:0]);
                if (tab[yl * 32 + xl][4] !== 1'b1) begin
                    $write(".");
                end else begin
                    s = assemble(quadrant(x[5:0], y[5:0]), tab[yl * 32 + xl][3:0]);
                    $write("%0d", s % 10);
                    n_px = n_px + 1;
                end
            end
            $write("\n");
        end
        if (n_px === n_exp)
            $display("[ OK ] 带内像素数 %0d == 4 x 带内表项数（%0d 项；折叠是 2:1 镜像，像素域与折叠域一致）",
                     n_px, n_valid);
        else begin
            $display("[FAIL] 带内像素数 %0d != 表项按重数展开的总数 %0d（fold / 象限映射与表不一致）",
                     n_px, n_exp);
            errors = errors + 1;
        end

        // 四个正方向必须是 0 / 16 / 32 / 48（像素中心在 (31.5,31.5)，所以每个
        //   方向取中线两侧各一个像素；两者差 1 个扇区是扇区边界压在中线上的正常现象）。
        check_dir(6'd32, 6'd2,  0,  "12 点 右");
        check_dir(6'd31, 6'd2,  0,  "12 点 左");
        check_dir(6'd61, 6'd32, 16, "3 点 下");
        check_dir(6'd61, 6'd31, 16, "3 点 上");
        check_dir(6'd32, 6'd61, 32, "6 点 右");
        check_dir(6'd31, 6'd61, 32, "6 点 左");
        check_dir(6'd2,  6'd32, 48, "9 点 下");
        check_dir(6'd2,  6'd31, 48, "9 点 上");

        if (errors === 0) $display("[ OK ] 全部结构判据通过");
        else              $display("[FAIL] 结构判据错误 = %0d", errors);

        $display("");
        if (errors === 0) $display("\nTEST PASSED: 0 errors");
        else              $display("\nTEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("\n[FAIL] TIMEOUT");
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
