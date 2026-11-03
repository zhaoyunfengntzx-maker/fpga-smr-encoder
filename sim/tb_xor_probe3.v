//=============================================================================
//  tb_xor_probe3 —— UART 遥测帧 XOR 校验的表达式语义自检
//-----------------------------------------------------------------------------
//  为什么需要这个测试台
//  --------------------
//  sim/tb_uart_scope.v 的帧解析用"帧头 + XOR 自洽"双条件确认帧边界，其中
//  XOR 期望值的算法是：
//        xc = 8'hAA ^ 8'h55;
//        for (j = 2; j <= 16; j = j + 1) xc = xc ^ fr[j];
//        frame_ok = (fr[0]==8'hAA) && (fr[1]==8'h55) && (fr[17]==xc);
//
//  【2026-10-10 复盘，结论已更正】调试过程中曾记录"同一个（帧头+载荷）异或式
//  换写法会得到不同结果"，并据此怀疑 xsim 的 XOR 有 bug、把 (c) 判成"不可靠"。
//  这个结论是**错的**，本测试台自己通过的断言就否证了它：
//        (a) xc = 8'hAA;              for(...) xc = xc ^ fr[j];   -> 0x55
//        (b) xc = 8'hAA ^ 8'h55;      for(...) xc = xc ^ fr[j];   -> 0xA7  ✓ 本工程采用
//        (c) 直写 x ^ 8'hAA ^ 8'h55（中间结果再异或两个常量）    -> 0xA7  与 (b) 等价
//        T11a: (a) ^ 0x55 == (b)  —— 差异**恰好**是 (a) 少异或的那个帧头常量
//        T11c: (c) == (b)         —— (c) 并没有不可靠
//  当时被当成"正确值 0xFD"的那个数，来自一段**截断的累加**（只加到 fr[15]，
//  漏掉 fr[16]=0x5A）：
//        0x58 ^ 0x5A = 0x02 ; 0x02 ^ 0xAA ^ 0x55 = 0xFD     <- 错源在这里，见 T12
//  而那次 (c) 实测得到的 0xA7 恰恰是正确值（= 0x58 ^ 0xFF）。
//  ⇒ 不是仿真器 bug，是测试台自己的累加范围写错了。三种写法都可靠。
//
//  本测试台用"只有一个字节非零"的向量把 XOR 语义钉死——这类向量的期望值
//  不需要任何心算（结果必须精确等于那个字节），因此能干净地区分
//  "运算符/仿真器错了" 与 "我的表达式写错了"。T12 把上面那次误判也固化成判据。
//
//  真实载荷的参考值（Python 独立复算，见 sim/tb_uart_scope.v 注释）：
//        payload(2..16) XOR = 0x58
//        AA ^ 55 ^ payload   = 0xA7（= RTL rtl/uart_scope.v:189-196 实际发出的值）
//=============================================================================
`timescale 1ns/1ps
module tb_xor_probe3;

    reg [7:0] fr [0:17];
    reg [7:0] a;
    integer   i, j;
    integer   checks = 0, errors = 0;

    //  载荷 XOR，从 0 起（与 tb_uart_scope.v 的 payload 累加一致）
    function [7:0] pl;
        input dummy;
        reg [7:0] x;
        integer   k;
        begin
            x = 8'h00;
            for (k = 2; k <= 16; k = k + 1) x = x ^ fr[k];
            pl = x;
        end
    endfunction

    //  完整帧校验值：采用 (b) 写法 —— 帧头常量先并进累加器
    function [7:0] full_chk;
        input dummy;
        reg [7:0] x;
        integer   k;
        begin
            x = 8'hAA ^ 8'h55;
            for (k = 2; k <= 16; k = k + 1) x = x ^ fr[k];
            full_chk = x;
        end
    endfunction

    task clear_payload;
        integer k;
        begin
            for (k = 2; k <= 16; k = k + 1) fr[k] = 8'h00;
        end
    endtask

    task chk8;
        input [7:0]     got;
        input [7:0]     want;
        input [8*96-1:0] name;
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display(" [FAIL] %0s : got 0x%02x, want 0x%02x", name, got, want);
            end
        end
    endtask

    initial begin
        $display("================================================================");
        $display(" tb_xor_probe3 : UART 帧 XOR 语义自检");
        $display("================================================================");

        //  --- 单字节向量：结果必须精确 == 该字节（无需心算） ---
        clear_payload; fr[2]  = 8'h01; chk8(pl(1'b1), 8'h01, "T1-only fr[2]=0x01");
        clear_payload; fr[3]  = 8'h01; chk8(pl(1'b1), 8'h01, "T2-only fr[3]=0x01");
        clear_payload; fr[16] = 8'h80; chk8(pl(1'b1), 8'h80, "T3-only fr[16]=0x80");
        clear_payload; fr[5]  = 8'hFF; chk8(pl(1'b1), 8'hFF, "T4-only fr[5]=0xFF");
        clear_payload;                chk8(pl(1'b1), 8'h00, "T5-all zero payload");

        //  --- 两字节：0x01 ^ 0x01 = 0x00 ---
        clear_payload; fr[2]=8'h01; fr[3]=8'h01;
        chk8(pl(1'b1), 8'h00, "T6-fr[2]=fr[3]=0x01");

        //  --- 逐位递进：每次多异或一个 0x01，结果 01 00 01 交替 ---
        clear_payload;
        fr[2]=8'h01; chk8(pl(1'b1), 8'h01, "T7a-1 byte of 0x01");
        fr[3]=8'h01; chk8(pl(1'b1), 8'h00, "T7b-2 bytes of 0x01");
        fr[4]=8'h01; chk8(pl(1'b1), 8'h01, "T7c-3 bytes of 0x01");

        //  --- 只有 bit7 不同时，结果 bit7 必须为 1 ---
        clear_payload; fr[10]=8'h80; chk8(pl(1'b1), 8'h80, "T8-only fr[10]=0x80");

        //  --- 真实载荷：与 Python 独立复算的参考值比对 ---
        begin : payload_run
            reg [7:0] x;
            fr[2]=8'h12; fr[3]=8'h34; fr[4]=8'h0F; fr[5]=8'h0E;
            fr[6]=8'hF1; fr[7]=8'hF2; fr[8]=8'hDE; fr[9]=8'hAD;
            fr[10]=8'hBE; fr[11]=8'hEF; fr[12]=8'h01; fr[13]=8'h02;
            fr[14]=8'h03; fr[15]=8'h04; fr[16]=8'h5A;
            x = 8'h00;
            $display(" T9) real payload, running XOR after each byte:");
            for (j = 2; j <= 16; j = j + 1) begin
                x = x ^ fr[j];
                $display("       after fr[%0d]=0x%02x -> 0x%02x", j, fr[j], x);
            end
            $display(" T9) payload XOR = 0x%02x (want 0x58) ; full frame chk = 0x%02x (want 0xA7)",
                     x, full_chk(1'b1));
            chk8(x,            8'h58, "T9-payload XOR of real frame");
            chk8(full_chk(1'b1), 8'hA7, "T10-full frame XOR (header + payload)");
        end

        //  --- 把"三种写法"的差异钉死：本工程只允许 (b) ---
        begin : expr_semantics
            reg [7:0] w_a, w_b, w_c, w_trunc;
            //  (a) 少异或一个帧头常量
            w_a = 8'hAA;
            for (i = 2; i <= 16; i = i + 1) w_a = w_a ^ fr[i];
            //  (b) 正确写法
            w_b = 8'hAA ^ 8'h55;
            for (i = 2; i <= 16; i = i + 1) w_b = w_b ^ fr[i];
            //  (c) 中间结果再异或两个常量（与 (b) 数学等价，不是"不可靠写法"）
            w_c = 8'h00;
            for (i = 2; i <= 16; i = i + 1) w_c = w_c ^ fr[i];
            w_c = w_c ^ 8'hAA ^ 8'h55;

            $display(" T11) (a) only AA seeded   = 0x%02x", w_a);
            $display(" T11) (b) AA^55 seeded     = 0x%02x  <- 本工程采用", w_b);
            $display(" T11) (c) post-XOR consts  = 0x%02x", w_c);
            //  (b) 必须等于 (a) ^ 0x55：(a) 少异或的那个常量就是 0x55
            chk8(w_a ^ 8'h55, w_b, "T11a-(b) == (a) ^ 0x55  (差异恰好来自漏掉的帧头常量)");
            chk8(w_b, 8'hA7, "T11b-(b) is the correct full-frame XOR");
            chk8(w_c, w_b, "T11c-(c) agrees with (b) on this expression shape");

            //  --- T12：把 2026-10-10 之前那次误判固化成判据 -------------------
            //  当时把累加范围截断到 fr[15]（漏掉 fr[16]=0x5A），算得 0x02，
            //  再 ^0xAA^0x55 得 0xFD，并把 0xFD 当成了"正确值"，于是误判
            //  (c) 写法不可靠。这里把这三个数字全部钉死。
            w_trunc = 8'h00;
            for (i = 2; i <= 15; i = i + 1) w_trunc = w_trunc ^ fr[i];
            $display(" T12) truncated accum(2..15) = 0x%02x ; ^AA^55 = 0x%02x ; +fr[16] = 0x%02x",
                     w_trunc, w_trunc ^ 8'hAA ^ 8'h55, w_trunc ^ fr[16]);
            chk8(w_trunc, 8'h02, "T12a-trunc accum (miss fr[16]) == 0x02");
            chk8(w_trunc ^ 8'hAA ^ 8'h55, 8'hFD, "T12b-0xFD came from truncated accum");
            chk8(w_trunc ^ fr[16], pl(1'b1), "T12c-add fr[16] back -> payload XOR");
        end

        $display("================================================================");
        if (errors == 0) $display(" TEST PASSED (%0d checks)", checks);
        else             $display(" TEST FAILED (%0d errors / %0d checks)", errors, checks);
        $display("================================================================");
        $finish;
    end

endmodule
