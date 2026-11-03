//=============================================================================
// disp/tb_p2_auto.v —— P2 时基 AUTO 选档 / 迟滞 / 停留 / 固定档 / 标签（v87 任务 A2）
//
// 覆盖（对应任务书 m00068 的四条要求）：
//   ① 扫频选档：1k/5k/7k/20k/40k/60k/120k Hz ⇒ 期望 0/0/1/1/1/2/2
//   ② 迟滞：在 53 kHz 上下 10% 来回扫，不许抖（47.7 kHz 保持 gear2，
//      58 kHz 才升；45 kHz 以下才降）；6.6/5.6 kHz 那一对同理
//   ③ 停留：换档后必须经过 33 个 f_valid 脉冲（33/64 s ≈ 0.52 s）才允许再换
//   ④ 无效频率（f_ok=0）保持当前档位
//   ⑤ 固定档：mode=1/2/3 立刻对应 gear0/1/2，mode=0 回到 AUTO
//   ⑥ 底栏标签：AUTO/固定 + 窗宽文本；窗宽数字与 944*div/50e6 一致
//      （gear0 2416.64 µs 显示 2.4MS、gear1 302.08 µs 显示 302US、
//        gear2 37.76 µs 显示 38US；MS 档的显示分辨率是 0.1 ms，容差 50 µs，
//        US 档分辨率 1 µs，容差 1 µs —— 见 p2_win_lab.v 的 cell_at）
//
// 单位约定：f_q10 = f_Hz * 1024（disp/enc_top_disp.v 的 freq_meter 就是这个口径）
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_p2_auto;

    reg clk = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz，与板上一致

    reg rst_n = 1'b0;

    reg  [1:0]         mode    = 2'd0;
    reg  signed [31:0] f_q10   = 32'sd0;
    reg                f_valid = 1'b0;
    reg                f_ok    = 1'b1;
    wire [1:0]         gear;

    p2_auto u_auto (
        .clk (clk), .rst_n (rst_n), .mode (mode),
        .f_q10 (f_q10), .f_valid (f_valid), .f_ok (f_ok), .gear (gear)
    );

    // ---------------- 底栏标签写入器（p2_win_lab） ----------------
    reg         start = 1'b0;
    wire        lwe;
    wire [11:0] laddr;
    wire [7:0]  ldata;
    wire        lbusy, ldone;

    reg [7:0] lab_mem [0:4095];
    always @(posedge clk) if (lwe) lab_mem[laddr] <= ldata;

    p2_win_lab u_lab (
        .clk (clk), .rst_n (rst_n), .start (start), .mode (mode), .gear (gear),
        .we (lwe), .waddr (laddr), .wdata (ldata), .busy (lbusy), .done (ldone)
    );

    integer errors = 0;

    // ---------------- 工具 ----------------
    task chk;
        input [255:0] what;
        input [31:0]  got;
        input [31:0]  want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("  ** FAIL %0s: got %0d want %0d (t=%0t)", what, got, want, $time);
            end else begin
                $display("  ok   %0s = %0d", what, got);
            end
        end
    endtask

    task set_f;
        input integer hz;
        begin
            f_q10 = hz * 1024;
        end
    endtask

    // 一个 f_valid 脉冲 = 频率计的一次更新（1/64 s）
    task pulses;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk); f_valid = 1'b1;
                @(negedge clk); f_valid = 1'b0;
            end
        end
    endtask

    // 字符码 -> ASCII（仅供 $display 出人看得懂的标签文本）
    function [7:0] to_ascii;
        input [7:0] c;
        begin
            if (c >= 8'd8 && c <= 8'd17)      to_ascii = 8'h30 + (c - 8'd8);
            else if (c == 8'd1)               to_ascii = ".";
            else if (c >= 8'd18 && c <= 8'd43) to_ascii = 8'h41 + (c - 8'd18);
            else if (c == 8'd147)             to_ascii = "#";   // 固
            else if (c == 8'd118)             to_ascii = "#";   // 定
            else                              to_ascii = " ";
        end
    endfunction

    reg [7:0] exp_cell [0:9];

    // 把 mode/gear 灌进标签器，等它写完 10 格，再逐格比对 + 印出文本
    task check_cells;
        input [1:0] md;
        input [1:0] g;
        integer k;
        reg [7:0] got;
        begin
            mode = md;
            @(posedge clk); #1;
            chk("label gear", gear, g);
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;
            wait (ldone);
            @(posedge clk); #1;
            $write("  label mode=%0d gear=%0d : \"", md, gear);
            for (k = 0; k < 10; k = k + 1) $write("%0s", to_ascii(lab_mem[36*64 + 6 + k]));
            $write("\"\n");
            for (k = 0; k < 10; k = k + 1) begin
                got = lab_mem[36*64 + 6 + k];
                if (got !== exp_cell[k]) begin
                    errors = errors + 1;
                    $display("  ** FAIL label mode=%0d cell col %0d: got %0d want %0d",
                             md, 6 + k, got, exp_cell[k]);
                end
            end
        end
    endtask

    // 窗宽理论值（µs×1000）：944*div/50e6 s = 18880*div µs×1000/1000
    integer win_us_x1000;
    task show_window;
        input [1:0] g;
        integer div;
        begin
            div = (g == 2'd0) ? 128 : (g == 2'd1) ? 16 : 2;
            win_us_x1000 = 18880 * div;      // 944*div*1000/50
            $display("  window(gear%0d) = %0d.%03d us  (944*%0d/50e6)",
                     g, win_us_x1000 / 1000, win_us_x1000 % 1000, div);
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("=== tb_p2_auto: AUTO / hysteresis / dwell / fixed / label ===");

        // ---- ① 复位默认 gear1 ----
        chk("reset gear", gear, 2'd1);

        // ---- ② 扫频选档 ----
        $display("-- sweep --");
        set_f(1000);   pulses(40); chk("f=1k   -> gear", gear, 2'd0);
        set_f(5000);   pulses(40); chk("f=5k   -> gear", gear, 2'd0);
        set_f(7000);   pulses(40); chk("f=7k   -> gear", gear, 2'd1);
        set_f(20000);  pulses(40); chk("f=20k  -> gear", gear, 2'd1);
        set_f(40000);  pulses(40); chk("f=40k  -> gear", gear, 2'd1);
        set_f(60000);  pulses(40); chk("f=60k  -> gear", gear, 2'd2);
        set_f(120000); pulses(40); chk("f=120k -> gear", gear, 2'd2);

        // ---- ③ 53 kHz ±10% 迟滞（gear2 不抖） ----
        $display("-- hysteresis 53k --");
        set_f(47700); pulses(60); chk("f=47.7k (53k-10%) keep gear", gear, 2'd2);
        set_f(44000); pulses(40); chk("f=44k   -> drop to gear",        gear, 2'd1);
        set_f(47700); pulses(60); chk("f=47.7k (<53k) keep gear",       gear, 2'd1);
        set_f(58000); pulses(40); chk("f=58k   -> rise to gear",        gear, 2'd2);

        // ---- ④ 6.6/5.6 kHz 迟滞 ----
        //  注意：从 gear2 出发时，5.8 kHz 远低于 45 kHz 的降档门限 ⇒ 先落到 gear1
        //  （这是 gear2→gear1 的迟滞下沿，测的不是 6.6k 那一对）；之后从 gear1
        //  回到 5.8 kHz 才是"6.6/5.6 kHz 迟滞里不抖"的用例。
        $display("-- hysteresis 6.6k --");
        set_f(5800);  pulses(60); chk("f=5.8k from gear2 -> gear",      gear, 2'd1);
        set_f(8000);  pulses(40); chk("f=8k   keep gear",               gear, 2'd1);
        set_f(5800);  pulses(60); chk("f=5.8k (>5.6k) keep gear",       gear, 2'd1);
        set_f(5000);  pulses(40); chk("f=5k   -> gear",                 gear, 2'd0);

        // ---- ⑤ 停留：换档后 33 个 f_valid 才允许再换 ----
        $display("-- dwell --");
        set_f(60000); pulses(40); chk("f=60k  -> gear",                 gear, 2'd2);
        set_f(44000); pulses(20); chk("20 pulses (<33) keep gear",      gear, 2'd2);
        pulses(20);               chk("+20 pulses -> gear",             gear, 2'd1);

        // ---- ⑥ 无效频率保持 ----
        $display("-- f_ok=0 hold --");
        f_ok = 1'b0;
        set_f(120000); pulses(60); chk("f_ok=0 f=120k keep gear",  gear, 2'd1);
        f_ok = 1'b1;
        set_f(120000); pulses(40); chk("f_ok=1 f=120k -> gear",    gear, 2'd2);

        // ---- ⑦ 固定档 ----
        $display("-- fixed mode --");
        mode = 2'd2; @(posedge clk); #1; chk("mode=2 -> gear", gear, 2'd1);
        mode = 2'd3; @(posedge clk); #1; chk("mode=3 -> gear", gear, 2'd2);
        mode = 2'd1; @(posedge clk); #1; chk("mode=1 -> gear", gear, 2'd0);
        mode = 2'd0; set_f(7000); pulses(40); chk("mode=0 f=7k -> gear", gear, 2'd1);

        // ---- ⑧ 标签文本 + 窗宽一致性 ----
        $display("-- label --");
        // AUTO gear0: "AUTO 2.4MS"
        set_f(1000); pulses(40);
        exp_cell[0]=8'd18; exp_cell[1]=8'd38; exp_cell[2]=8'd37; exp_cell[3]=8'd32;
        exp_cell[4]=8'd0;
        exp_cell[5]=8'd10; exp_cell[6]=8'd1; exp_cell[7]=8'd12; exp_cell[8]=8'd30; exp_cell[9]=8'd36;
        show_window(2'd0);
        check_cells(2'd0, 2'd0);
        // AUTO gear1: "AUTO 302US"
        set_f(20000); pulses(40);
        exp_cell[0]=8'd18; exp_cell[1]=8'd38; exp_cell[2]=8'd37; exp_cell[3]=8'd32;
        exp_cell[4]=8'd0;
        exp_cell[5]=8'd11; exp_cell[6]=8'd8; exp_cell[7]=8'd10; exp_cell[8]=8'd38; exp_cell[9]=8'd36;
        show_window(2'd1);
        check_cells(2'd0, 2'd1);
        // AUTO gear2: "AUTO 38US "
        set_f(120000); pulses(40);
        exp_cell[0]=8'd18; exp_cell[1]=8'd38; exp_cell[2]=8'd37; exp_cell[3]=8'd32;
        exp_cell[4]=8'd0;
        exp_cell[5]=8'd11; exp_cell[6]=8'd16; exp_cell[7]=8'd38; exp_cell[8]=8'd36; exp_cell[9]=8'd0;
        show_window(2'd2);
        check_cells(2'd0, 2'd2);
        // 固定 gear0: "固定 2.4MS"
        exp_cell[0]=8'd0; exp_cell[1]=8'd0; exp_cell[2]=8'd147; exp_cell[3]=8'd118;
        exp_cell[4]=8'd0;
        exp_cell[5]=8'd10; exp_cell[6]=8'd1; exp_cell[7]=8'd12; exp_cell[8]=8'd30; exp_cell[9]=8'd36;
        check_cells(2'd1, 2'd0);
        // 固定 gear1: "固定 302US"
        exp_cell[0]=8'd0; exp_cell[1]=8'd0; exp_cell[2]=8'd147; exp_cell[3]=8'd118;
        exp_cell[4]=8'd0;
        exp_cell[5]=8'd11; exp_cell[6]=8'd8; exp_cell[7]=8'd10; exp_cell[8]=8'd38; exp_cell[9]=8'd36;
        check_cells(2'd2, 2'd1);

        // ---- 汇总 ----
        $display("---------------------------------------------------------");
        if (errors == 0) $display("TEST PASSED: 0 errors (AUTO gear / hysteresis / dwell / label)");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule

`default_nettype wire
