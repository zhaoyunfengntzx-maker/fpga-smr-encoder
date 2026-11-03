//=============================================================================
// 测试台 : tb_ad9238_capture
// 文件   : sim/tb_ad9238_capture.v
// 被测   : rtl/ad9238_capture.v
//
// 【测试内容】
//   1) 偏移二进制 -> 二进制补码转换：0x000 -> -2048，0x800 -> 0，0xFFF -> +2047，
//      0x801 -> +1，0x7FF -> -1，0x400 -> -1024，0xC00 -> +1024（两个通道都测）。
//   2) OTR sticky：任一通道 OTR 拉高一次 -> otr 置 1；输入撤销后必须保持；
//      clr_otr=1 才清除。两个通道分别测。
//   3) en 下降沿清 OTR（契约要求：rst_n 或 en 下降沿清除）。
//   4) 复位行为：rst_n=0 期间 s_raw/c_raw/otr/adc_valid 全为 0。
//   5) en=0 静默：s_raw/c_raw 强制为 0（adc_valid 仍为 1，因为 ADC 在连续采样）。
//   6) adc_valid 在非复位期间恒为 1；Latency = 3（等 3 拍后数据才更新）。
//
// 说明：本文件只做静态码字检查，因此不存在时序竞争问题；
//       激励一律在 clk_cap 负沿改变，检查也在负沿做（避开 NBA 竞争）。
//=============================================================================
`timescale 1ns / 1ps

module tb_ad9238_capture;

    localparam integer DW = 12;

    reg                  clk_cap;
    reg                  rst_n;
    reg  [DW-1:0]        ch1_d;
    reg  [DW-1:0]        ch2_d;
    reg                  ch1_otr;
    reg                  ch2_otr;
    reg                  en;
    reg                  clr_otr;
    wire signed [DW-1:0] s_raw;
    wire signed [DW-1:0] c_raw;
    wire                 otr;
    wire                 adc_valid;

    integer errors;

    ad9238_capture #(
        .DW (DW)
    ) dut (
        .clk_cap   (clk_cap),
        .rst_n     (rst_n),
        .ch1_d     (ch1_d),
        .ch2_d     (ch2_d),
        .ch1_otr   (ch1_otr),
        .ch2_otr   (ch2_otr),
        .en        (en),
        .clr_otr   (clr_otr),
        .s_raw     (s_raw),
        .c_raw     (c_raw),
        .otr       (otr),
        .adc_valid (adc_valid)
    );

    initial begin
        clk_cap = 1'b0;
        forever #10 clk_cap = ~clk_cap;      // 50 MHz（周期 20 ns）
    end

    //-------------------------------------------------------------------------
    // 工具任务
    //-------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n   = 1'b0;
            en      = 1'b0;
            clr_otr = 1'b0;
            ch1_otr = 1'b0;
            ch2_otr = 1'b0;
            ch1_d   = {DW{1'b0}};
            ch2_d   = {DW{1'b0}};
            repeat (4) @(posedge clk_cap);
            @(negedge clk_cap);
        end
    endtask

    task release_reset;
        begin
            @(negedge clk_cap);
            rst_n = 1'b1;
            en    = 1'b1;
        end
    endtask

    // 送一对码字，等 3 拍后检查 s_raw/c_raw
    task check_conv;
        input [DW-1:0]        c1;
        input [DW-1:0]        c2;
        input signed [DW-1:0] es;
        input signed [DW-1:0] ec;
        begin
            @(negedge clk_cap);
            ch1_d = c1;
            ch2_d = c2;
            repeat (4) @(posedge clk_cap);
            @(negedge clk_cap);
            if (s_raw !== es || c_raw !== ec) begin
                errors = errors + 1;
                $display("  [FAIL] ch1=0x%3h ch2=0x%3h -> s_raw=%0d c_raw=%0d，期望 %0d / %0d",
                         c1, c2, $signed(s_raw), $signed(c_raw), $signed(es), $signed(ec));
            end else begin
                $display("  [ok  ] ch1=0x%3h ch2=0x%3h -> s_raw=%5d c_raw=%5d",
                         c1, c2, $signed(s_raw), $signed(c_raw));
            end
            if (adc_valid !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] adc_valid=%b（非复位期间必须恒为 1）", adc_valid);
            end
        end
    endtask

    // 静态码字 + 静态 OTR/clear 的保持检查（用于 sticky / 静默测试）
    task hold_and_check;
        input integer  ncyc;             // 保持多少拍
        input          e_otr;
        input          e_valid;
        input signed [DW-1:0] es;
        input signed [DW-1:0] ec;
        input [8*64-1:0] tag;
        begin
            repeat (ncyc) @(posedge clk_cap);
            @(negedge clk_cap);
            if (otr !== e_otr || adc_valid !== e_valid ||
                s_raw !== es || c_raw !== ec) begin
                errors = errors + 1;
                $display("  [FAIL] %0s: otr=%b adc_valid=%b s_raw=%0d c_raw=%0d，期望 otr=%b valid=%b %0d/%0d",
                         tag, otr, adc_valid, $signed(s_raw), $signed(c_raw),
                         e_otr, e_valid, $signed(es), $signed(ec));
            end else begin
                $display("  [ok  ] %0s: otr=%b adc_valid=%b s_raw=%5d c_raw=%5d",
                         tag, otr, adc_valid, $signed(s_raw), $signed(c_raw));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        errors  = 0;
        rst_n   = 1'b0;
        en      = 1'b0;
        clr_otr = 1'b0;
        ch1_otr = 1'b0;
        ch2_otr = 1'b0;
        ch1_d   = {DW{1'b0}};
        ch2_d   = {DW{1'b0}};

        $display("================================================================");
        $display(" tb_ad9238_capture : ADC 捕获/去偏置/OTR 自检测试");
        $display("================================================================");

        // ---- 1) 复位行为 ----
        $display(" 【1】复位行为（rst_n=0 期间必须全 0）");
        do_reset;
        if (s_raw !== 12'sd0 || c_raw !== 12'sd0 || otr !== 1'b0 || adc_valid !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] 复位值不对: s_raw=%0d c_raw=%0d otr=%b adc_valid=%b",
                     $signed(s_raw), $signed(c_raw), otr, adc_valid);
        end else begin
            $display("  [ok  ] 复位后 s_raw=0 c_raw=0 otr=0 adc_valid=0");
        end

        // ---- 2) 偏移二进制 -> 补码 ----
        $display("");
        $display(" 【2】偏移二进制转换（0x800 对应 0 V）");
        release_reset;
        check_conv(12'h800, 12'h800, 12'sd0,    12'sd0);      // 0 V
        check_conv(12'h000, 12'h000, -12'sd2048, -12'sd2048); // -FS
        check_conv(12'hFFF, 12'hFFF, 12'sd2047, 12'sd2047);   // +FS
        check_conv(12'h801, 12'h7FF, 12'sd1,    -12'sd1);     // 两通道独立
        check_conv(12'h400, 12'hC00, -12'sd1024, 12'sd1024);
        check_conv(12'h7FF, 12'h801, -12'sd1,   12'sd1);

        // ---- 3) OTR sticky ----
        $display("");
        $display(" 【3】OTR sticky（置 1 保持，clr_otr 清除）");
        do_reset;
        release_reset;
        check_conv(12'h800, 12'h800, 12'sd0, 12'sd0);         // 正常数据
        @(negedge clk_cap);
        ch1_otr = 1'b1;                                        // CH1 超量程
        hold_and_check(6, 1'b1, 1'b1, 12'sd0, 12'sd0, "CH1 OTR 置位");
        @(negedge clk_cap);
        ch1_otr = 1'b0;                                        // 撤销输入
        hold_and_check(8, 1'b1, 1'b1, 12'sd0, 12'sd0, "撤销后仍保持(sticky)");
        @(negedge clk_cap);
        clr_otr = 1'b1;                                        // 写 1 清除
        hold_and_check(3, 1'b0, 1'b1, 12'sd0, 12'sd0, "clr_otr 清除");
        @(negedge clk_cap);
        clr_otr = 1'b0;
        hold_and_check(3, 1'b0, 1'b1, 12'sd0, 12'sd0, "清除后保持 0");

        // CH2 也要能置位
        @(negedge clk_cap);
        ch2_otr = 1'b1;
        hold_and_check(6, 1'b1, 1'b1, 12'sd0, 12'sd0, "CH2 OTR 置位");
        @(negedge clk_cap);
        ch2_otr = 1'b0;
        @(negedge clk_cap);
        clr_otr = 1'b1;
        hold_and_check(3, 1'b0, 1'b1, 12'sd0, 12'sd0, "CH2 清除");
        @(negedge clk_cap);
        clr_otr = 1'b0;

        // ---- 4) en 下降沿清 OTR ----
        $display("");
        $display(" 【4】en 下降沿清 OTR，且 en=0 时数据静默为 0");
        @(negedge clk_cap);
        ch1_otr = 1'b1;
        hold_and_check(6, 1'b1, 1'b1, 12'sd0, 12'sd0, "en=1 时 OTR 置位");
        @(negedge clk_cap);
        ch1_otr = 1'b0;
        en      = 1'b0;                                        // en 下降沿
        hold_and_check(4, 1'b0, 1'b1, 12'sd0, 12'sd0, "en 下降沿清 OTR + 数据 0");
        check_conv(12'hFFF, 12'h000, 12'sd0, 12'sd0);          // en=0：仍输出 0

        // ---- 5) en 恢复 ----
        $display("");
        $display(" 【5】en 恢复后数据通路正常");
        @(negedge clk_cap);
        en = 1'b1;
        check_conv(12'h800, 12'h800, 12'sd0, 12'sd0);
        check_conv(12'h000, 12'hFFF, -12'sd2048, 12'sd2047);
        check_conv(12'hFFF, 12'h000, 12'sd2047, -12'sd2048);

        $display("");
        $display("================================================================");
        if (errors == 0) $display(" TEST PASSED (0 errors)");
        else             $display(" TEST FAILED (%0d errors)", errors);
        $display("================================================================");
        $finish;
    end

endmodule
