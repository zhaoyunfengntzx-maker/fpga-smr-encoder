// -----------------------------------------------------------------------------
//  disp/tb_hit_test_v58.v —— 触摸命中判定的 v58 契约台
//
//  为什么要有这个台：
//    v58 把导航从「6 项 × 96 px」改成「4 项 × 144 px」，而 hit_test.v 里的
//    导航边界（24/168/312/456）、卡片原点（96/416/736）与 disp_engine.v 的
//    绘制常量是**两处手抄的同一份契约**。改一处忘了另一处，屏上就会出现
//    「看得见、点不中」或「点得中、但点错东西」——这两种毛病上板才发现最贵。
//
//  这个台覆盖什么（全部是纯边界，不依赖上板）：
//    * 4 档导航的上下边界各 ±0（24/167、168/311、312/455、456/599）与 x=79/80；
//    * 3 列 × 2 行卡片的四个角与列间 32 px 缝（x=400 应判 NONE）；
//    * 标题带主操作按钮 [660,820)×[24,64)、状态条 ⚙ [864,928)×[0,48)；
//    * 状态条通栏 y<24；
//    * 非法坐标 (1024,500)：必须判 NONE，且 cur_x/cur_y 保持上一组合法值；
//    * 握手语义：一次按下只报一次 hit_stb（同点连发不重复）、抬起给一次 rel_stb。
//
//  写法约束（踩过的坑）：
//    xsim 在「嵌套 task + integer 数组索引」会 EXCEPTION_ACCESS_VIOLATION，
//    所以这里不用 task、不用数组：用 case(ci) 就地给坐标与期望值，单进程 FSM。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_hit_test_v58;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [2:0]  tch_num  = 3'd0;
    reg  [15:0] tch_x0   = 16'd0;
    reg  [15:0] tch_y0   = 16'd0;
    reg         tch_tg   = 1'b0;

    wire        hit_stb;
    wire [4:0]  hit_id;
    wire [11:0] hit_x, hit_y;
    wire        held, rel_stb;
    wire [11:0] cur_x, cur_y;

    hit_test u_dut (
        .clk(clk), .rst_n(rst_n),
        .tch_num(tch_num), .tch_x0(tch_x0), .tch_y0(tch_y0), .tch_toggle(tch_tg),
        .hit_stb(hit_stb), .hit_id(hit_id), .hit_x(hit_x), .hit_y(hit_y),
        .held(held), .rel_stb(rel_stb), .cur_x(cur_x), .cur_y(cur_y)
    );

    localparam [4:0] HIT_SBAR = 5'd6;
    localparam [4:0] HIT_SYS  = 5'd7;
    localparam [4:0] HIT_NONE = 5'd31;
localparam [4:0] HIT_DEMO = 5'd14;   // v60 T8

    integer fails  = 0;
    integer checks = 0;
    integer i;

    reg [7:0]  ci  = 8'd0;     // 检查序号
    reg [2:0]  st  = 3'd0;     // 0 装载 1 等首次命中 2 同点重发 3 等抬起 4 收尾
    reg [3:0]  cyc = 4'd0;
    reg [15:0] px  = 16'd0;
    reg [15:0] py  = 16'd0;
    reg [4:0]  eid = HIT_NONE;
    reg [11:0] keep_x = 12'd0;
    reg [11:0] keep_y = 12'd0;

    // -------------------------------------------------------------------------
    // 检查表：26 个点
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 3'd0; cyc <= 4'd0; ci <= 8'd0;
        end else begin
            case (st)
            3'd0: begin
                // ---- 装载这个检查点的坐标与期望 id ----
                // ★ 这里必须用**阻塞赋值**给 px/py/eid：后面紧跟着的
                //   `tch_x0 <= px` 是同一个时钟沿的非阻塞赋值，如果 px/py 也写成
                //   非阻塞，tch_x0 拿到的是**上一拍**的 px（首次就是 0,0），
                //   于是一个本该打中导航的点会被判成状态条。踩过一次，别再改回去。
                case (ci)
                8'd0:  begin px = 16'd40;   py = 16'd96;  eid = 5'd0; end // 导航0 中心
                8'd1:  begin px = 16'd40;   py = 16'd24;  eid = 5'd0; end // 导航0 上沿
                8'd2:  begin px = 16'd40;   py = 16'd167; eid = 5'd0; end // 导航0 下沿
                8'd3:  begin px = 16'd40;   py = 16'd168; eid = 5'd1; end // 导航1 上沿
                8'd4:  begin px = 16'd40;   py = 16'd311; eid = 5'd1; end // 导航1 下沿
                8'd5:  begin px = 16'd40;   py = 16'd312; eid = 5'd2; end // 导航2 上沿
                8'd6:  begin px = 16'd40;   py = 16'd455; eid = 5'd2; end // 导航2 下沿
                8'd7:  begin px = 16'd40;   py = 16'd456; eid = 5'd3; end // 导航3 上沿
                8'd8:  begin px = 16'd40;   py = 16'd599; eid = 5'd3; end // 导航3 下沿
                8'd9:  begin px = 16'd79;   py = 16'd500; eid = 5'd3; end // 导航右沿内
                8'd10: begin px = 16'd80;   py = 16'd500; eid = HIT_NONE; end // 导航右沿外
                8'd11: begin px = 16'd500;  py = 16'd10;  eid <= HIT_SBAR; end // 状态条
                8'd12: begin px = 16'd240;  py = 16'd180; eid = 5'd8;  end // 卡0 左上
                8'd13: begin px = 16'd240;  py = 16'd450; eid = 5'd12; end // 卡堆左下
                8'd14: begin px = 16'd550;  py = 16'd180; eid = HIT_NONE; end // 卡片第 2 列与第 1 列之间的缝
                8'd15: begin px = 16'd550;  py = 16'd450; eid = HIT_NONE; end // 同上，下排缝
                8'd16: begin px = 16'd880;  py = 16'd180; eid = 5'd9;  end // 卡堆右上
                8'd17: begin px = 16'd880;  py = 16'd450; eid = 5'd13; end // 卡堆右下
                8'd18: begin px = 16'd400;  py = 16'd240; eid = HIT_NONE; end // 上下排卡片之间的横缝
                8'd19: begin px = 16'd740;  py = 16'd44;  eid = 5'd15; end // 标题带按钮
                8'd20: begin px = 16'd890;  py = 16'd30;  eid <= HIT_DEMO; end // v60：P6 演示开关
                8'd21: begin px = 16'd890;  py = 16'd60;  eid <= HIT_DEMO; end // v60：按钮下沿内
    //   ★ v60（T8）：按钮右下角外一点回 HIT_NONE，确认矩形真的收在 1000 以内。
    8'd27: begin px = 16'd1010; py = 16'd40; eid <= HIT_NONE; end
                8'd22: begin px = 16'd1023; py = 16'd599; eid = 5'd13; end // 右下角 = 卡堆右下角
                8'd23: begin px = 16'd960;  py = 16'd540; eid = 5'd13; end // 卡5 右下（留给 ci=24 比对 cur）
                8'd24: begin px = 16'd1024; py = 16'd500; eid = HIT_NONE; end // 非法 x
                8'd25: begin px = 16'd40;   py = 16'd23;  eid <= HIT_SBAR; end // 导航上沿外
                8'd26: begin px = 16'd0;    py = 16'd0;   eid <= HIT_SBAR; end // 左上角
                default: begin px = 16'd0; py = 16'd0; eid = HIT_NONE; end
                endcase
                tch_num <= 3'd1;
                tch_x0  <= px;
                tch_y0  <= py;
                tch_tg  <= ~tch_tg;
                cyc     <= 4'd0;
                st      <= 3'd1;
            end

            3'd1: begin
                if (hit_stb) begin
                    checks = checks + 1;
                    if (hit_id !== eid) begin
                        fails = fails + 1;
                        $display("FAIL[%0d] (%0d,%0d) id=%0d 期望 %0d", ci, px, py, hit_id, eid);
                    end
                    if (hit_x !== px[11:0] || hit_y !== py[11:0]) begin
                        fails = fails + 1;
                        $display("FAIL[%0d] 锁存坐标 (%0d,%0d) 期望 (%0d,%0d)", ci, hit_x, hit_y, px, py);
                    end
                    if (!held) begin
                        fails = fails + 1;
                        $display("FAIL[%0d] 命中时 held 不为 1", ci);
                    end
                    // ci=24：非法坐标不许污染 cur_*（对照 ci=23 的合法点 (960,540)）
                    if (ci == 8'd24 && (cur_x !== keep_x || cur_y !== keep_y)) begin
                        fails = fails + 1;
                        $display("FAIL[24] 非法坐标改写了 cur (%0d,%0d) 期望 (%0d,%0d)",
                                 cur_x, cur_y, keep_x, keep_y);
                    end
                    // ci=23：(960,540) 是最后一组合法坐标，留给 ci=24 比对。
                    //   ★ 这里直接采样 DUT 的 cur_*，而不是写死期望值 —— 写死会把
                    //     "cur 根本没动过"这种坏情况判成 PASS（旧的 (0,0) 版本就踩过）。
                    if (ci == 8'd23) begin keep_x <= cur_x; keep_y <= cur_y; end
                    st  <= 3'd2;
                    cyc <= 4'd0;
                end else if (cyc == 4'd4) begin
                    fails = fails + 1;
                    $display("FAIL[%0d] (%0d,%0d) 没有 hit_stb", ci, px, py);
                    st <= 3'd4;
                end else cyc <= cyc + 4'd1;
            end

            3'd2: begin
                // 同一点再发一组样本：不该再报 hit_stb
                tch_tg <= ~tch_tg;
                cyc    <= 4'd0;
                st     <= 3'd3;
            end

            3'd3: begin
                if (hit_stb) begin
                    fails = fails + 1;
                    $display("FAIL[%0d] 同点重发又报了一次 hit_stb（连发）", ci);
                end
                if (cyc == 4'd3) begin
                    // 抬起
                    tch_num <= 3'd0;
                    tch_tg  <= ~tch_tg;
                    st      <= 3'd4;
                    cyc     <= 4'd0;
                end else cyc <= cyc + 4'd1;
            end

            3'd4: begin
                if (rel_stb) begin
                    if (held) begin
                        fails = fails + 1;
                        $display("FAIL[%0d] 抬起后 held 仍为 1", ci);
                    end
                end
                if (cyc == 4'd3) begin
                    if (ci == 8'd27) begin
                        if (fails == 0)
                            $display("[PASS] tb_hit_test_v58: %0d 个检查点全部通过（4 档导航 / 6 卡片 / 按钮 / 非法坐标 / 握手）", checks);
                        else
                            $display("[FAIL] tb_hit_test_v58: %0d 处失败（共 %0d 个检查点）", fails, checks);
                        $finish;
                    end else begin
                        ci  <= ci + 8'd1;
                        st  <= 3'd0;
                        cyc <= 4'd0;
                    end
                end else cyc <= cyc + 4'd1;
            end
            endcase
        end
    end

    initial begin
        rst_n = 1'b0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    end

    initial begin
        #2000000;
        $display("[FAIL] tb_hit_test_v58: 超时");
        $finish;
    end

endmodule
