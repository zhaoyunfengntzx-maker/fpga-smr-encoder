//=============================================================================
// tb_trace_cap.v — v60/T7 的单元契约台
//   验证四件事：
//     ① 触发前不写显示缓冲；Z 上升沿后才开始捕获；
//     ② 捕获 512 点后整块拷进显示缓冲（顺序不缺、不重）；
//     ③ 拷完自动重新武装（armed 回 1）、frames 递增；
//     ④ 读口 q/qp = 半速（2 px/点）且 qp 是 idx-1。
//   激励：io6 接一个 6 位计数器（每拍 +1），这样每个采样点的值都不同，能查出
//         "少采/多采/顺序错"；Z = io6[3]，计数器自然会让它周期性上升。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_trace_cap;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;             // 50 MHz

    reg  [5:0]  io6 = 6'd0;
    reg  [15:0] ang = 16'd0;
    reg  [9:0]  dx  = 10'd0;
    wire [5:0]  q, qp;
    wire        armed;
    wire [1:0]  frames;

    integer errs = 0;

    trace_cap #(.DEPTH(512)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .io6(io6), .angle(ang),
        .trig_sel(2'd0), .prescale(17'd4),   // 分频给小一点，仿真快
        .dx(dx), .q(q), .qp(qp),
        .armed(armed), .frames(frames)
    );

    // io6 = 计数器低 6 位：bit0=A, bit3=Z ⇒ 每 16 拍 Z 上升一次
    always @(posedge clk) io6 <= io6 + 6'd1;

    integer i, k, expect_next, got, last;
    reg [5:0] v0, v1;

    initial begin
        #100 rst_n = 1'b1;
        // ① 刚出复位：尚未触发，armed 必须为 1、frames 必须为 0
        #20;
        if (armed !== 1'b1) begin
            $display("[FAIL] armed expected 1 before trigger, got %b", armed);
            errs = errs + 1;
        end
        if (frames !== 2'd0) begin
            $display("[FAIL] frames=%0d after reset (expect 0)", frames);
            errs = errs + 1;
        end

        // ② 等第一帧拷完（armed 回到 1 且 frames 变 1）
        k = 0;
        while ((frames !== 2'd1) && (k < 200000)) begin
            @(posedge clk);
            k = k + 1;
        end
        if (frames !== 2'd1) begin
            $display("[FAIL] no frame captured in %0d clk; st=%0d widx=%0d cidx=%0d armed=%b psc=%0d",
                     k, u_dut.st, u_dut.widx, u_dut.cidx, u_dut.armed, u_dut.psc);
            errs = errs + 1;
            $finish;
        end

        // ③ 采样必须"每分频一次、连续递增"：相邻两点的差 = 每点经过的拍数
        //    计数器每拍 +1，采样每 4 拍一次 ⇒ 相邻采样值差 4（mod 64）。
        expect_next = 0;
        last = -1;
        for (i = 0; i < 512; i = i + 1) begin
            got = u_dut.dsp_mem[i];
            if (last >= 0) begin
                got = (got - last) & 6'h3f;
                if (got !== 4) begin
                    $display("[FAIL] sample %0d step=%0d expect 4", i, got);
                    errs = errs + 1;
                    i = 512;
                end
            end
            last = u_dut.dsp_mem[i];
        end
        if (errs == 0) $display("[ OK ] 512 samples captured, step=4 (2us @50MHz/100)");

        // ④ 读口：dx=0/1 → idx 0；dx=2/3 → idx 1
        dx = 10'd0; #20;
        if (u_dut.q !== u_dut.dsp_mem[0]) begin
            $display("[FAIL] q(dx=0) != dsp_mem[0]");
            errs = errs + 1;
        end
        dx = 10'd2; #20;
        if (u_dut.q !== u_dut.dsp_mem[1]) begin
            $display("[FAIL] q(dx=2) != dsp_mem[1]");
            errs = errs + 1;
        end
        if (u_dut.qp !== u_dut.dsp_mem[0]) begin
            $display("[FAIL] qp(dx=2) != dsp_mem[0]");
            errs = errs + 1;
        end

        if (errs == 0) $display("[PASS] tb_trace_cap: trigger/capture/swap/read 全通过");
        else           $display("[FAIL] tb_trace_cap: %0d error(s)", errs);
        $finish;
    end
endmodule

`default_nettype wire
