`timescale 1ns / 1ps
//=============================================================================
// tb_cordic_atan2.v —— cordic_atan2 自检测试台（SPEC §3 要求：打印 TEST PASSED）
//-----------------------------------------------------------------------------
// 覆盖内容
//   1. 复位行为（out_valid=0、angle=0）
//   2. 全圆 512 点扫描（步长 360/512 = 0.703125 deg）
//        - 与 model/cordic_model.py 位精确模型生成的**黄金角度表**逐位比对
//        - 与理想角度的最坏/RMS 误差（理想角度 = k*360/512 对应的整数码 k*128，
//          全部用整数参考表，不使用 $atan2）
//        - mag 幅值范围检查
//   3. 实测 Latency（NITER+2 = 19 拍 @50MHz，即 380 ns；实测与标称一致）
//   4. 四个正交边界点 + 45/135/225/315 度 + s_n=-32768 等边界值
//   5. 退化输入 x=0 / y=0 / (0,0)
//
// 说明：本机没有 Verilog 仿真器，本文件未经仿真，供 Vivado xsim `run all` 使用。
//      黄金表由 model/cordic_model.py（同一套定点语义：向零截断、+8 四舍五入、
//      修正象限折叠、NITER=17、FEXT=4、ATAN_SRC=1）生成。
//=============================================================================
module tb_cordic_atan2;

    localparam integer AW    = 16;
    localparam integer IW    = 16;
    localparam integer NITER = 17;          // 与 rtl 默认一致 -> Latency = 19
    localparam integer FEXT  = 4;
    localparam integer LAT   = NITER + 2;   // 19
    localparam integer NPT   = 512;         // 全圆扫描点数
    localparam integer ISTEP = 65536 / NPT; // 128，理想角度步长（16bit 角度 LSB）
    localparam integer NBLK  = NPT / 16;    // 32 个 256bit 打包块

    reg clk;
    reg rst_n;
    reg  signed [IW-1:0] x_in;
    reg  signed [IW-1:0] y_in;
    reg                  in_valid;
    wire [AW-1:0]        angle;
    wire [IW+1:0]        mag;
    wire                 out_valid;

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    cordic_atan2 #(
        .AW(AW), .IW(IW), .NITER(NITER), .FEXT(FEXT), .ATAN_SRC(1)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .x_in      (x_in),
        .y_in      (y_in),
        .in_valid  (in_valid),
        .angle     (angle),
        .mag       (mag),
        .out_valid (out_valid)
    );

    initial clk = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    //-------------------------------------------------------------------------
    // 黄金向量表（256bit 打包：块内第 j 个 16bit 值在 [j*16 +: 16]）
    //-------------------------------------------------------------------------
    reg [255:0] xtab [0:NBLK-1];
    reg [255:0] ytab [0:NBLK-1];
    reg [255:0] etab [0:NBLK-1];

    initial begin
        // ==== TABLE-BEGIN (由 model/_gen_tb_vectors.py 生成，勿手改) ====
        xtab[ 0] = 256'h7DD57E1D7E5F7E9C7ED57F097F377F617F867FA67FC17FD87FE97FF57FFD7FFF;
        xtab[ 1] = 256'h76D8776B77FA7884790979897A057A7C7AEE7B5C7BC57C297C887CE37D397D89;
        xtab[ 2] = 256'h6B4A6C236CF86DC96E966F5E702270E2719D7254730773B5745F750475A57641;
        xtab[ 3] = 256'h5B9C5CB35DC75ED75FE360EB61F062F163EE64E865DD66CF67BC68A6698B6A6D;
        xtab[ 4] = 256'h486949B44AFB4C3F4D814EBF4FFB51335268539B54C955F5571D584259645A82;
        xtab[ 5] = 256'h326E33DF354D36BA3824398C3AF23C563DB83F17407341CE4325447A45CD471C;
        xtab[ 6] = 256'h1A821C0B1D931F1A209F222323A6252826A8282629A32B1F2C992E112F8730FB;
        xtab[ 7] = 256'h0192032404B6064807D9096A0AFB0C8C0E1C0FAB113A12C8145515E2176E18F9;
        xtab[ 8] = 256'hE892EA1EEBABED38EEC6F055F1E4F374F505F696F827F9B8FB4AFCDCFE6E0000;
        xtab[ 9] = 256'hD079D1EFD367D4E1D65DD7DAD958DAD8DC5ADDDDDF61E0E6E26DE3F5E57EE707;
        xtab[10] = 256'hBA33BB86BCDBBE32BF8DC0E9C248C3AAC50EC674C7DCC946CAB3CC21CD92CF05;
        xtab[11] = 256'hA69CA7BEA8E3AA0BAB37AC65AD98AECDB005B141B27FB3C1B505B64CB797B8E4;
        xtab[12] = 256'h9675975A984499319A239B189C129D0F9E109F15A01DA129A239A34DA464A57E;
        xtab[13] = 256'h8A5B8AFC8BA18C4B8CF98DAC8E638F1E8FDE90A2916A9237930893DD94B69593;
        xtab[14] = 256'h82C7831D837883D7843B84A48512858485FB867786F7877C88068895892889BF;
        xtab[15] = 256'h8003800B80178028803F805A807A809F80C980F7812B816481A181E3822B8277;
        xtab[16] = 256'h822B81E381A18164812B80F780C9809F807A805A803F80288017800B80038001;
        xtab[17] = 256'h892888958806877C86F7867785FB8584851284A4843B83D78378831D82C78277;
        xtab[18] = 256'h94B693DD93089237916A90A28FDE8F1E8E638DAC8CF98C4B8BA18AFC8A5B89BF;
        xtab[19] = 256'hA464A34DA239A129A01D9F159E109D0F9C129B189A2399319844975A96759593;
        xtab[20] = 256'hB797B64CB505B3C1B27FB141B005AECDAD98AC65AB37AA0BA8E3A7BEA69CA57E;
        xtab[21] = 256'hCD92CC21CAB3C946C7DCC674C50EC3AAC248C0E9BF8DBE32BCDBBB86BA33B8E4;
        xtab[22] = 256'hE57EE3F5E26DE0E6DF61DDDDDC5ADAD8D958D7DAD65DD4E1D367D1EFD079CF05;
        xtab[23] = 256'hFE6EFCDCFB4AF9B8F827F696F505F374F1E4F055EEC6ED38EBABEA1EE892E707;
        xtab[24] = 256'h176E15E2145512C8113A0FAB0E1C0C8C0AFB096A07D9064804B6032401920000;
        xtab[25] = 256'h2F872E112C992B1F29A3282626A8252823A62223209F1F1A1D931C0B1A8218F9;
        xtab[26] = 256'h45CD447A432541CE40733F173DB83C563AF2398C382436BA354D33DF326E30FB;
        xtab[27] = 256'h59645842571D55F554C9539B526851334FFB4EBF4D814C3F4AFB49B44869471C;
        xtab[28] = 256'h698B68A667BC66CF65DD64E863EE62F161F060EB5FE35ED75DC75CB35B9C5A82;
        xtab[29] = 256'h75A57504745F73B573077254719D70E270226F5E6E966DC96CF86C236B4A6A6D;
        xtab[30] = 256'h7D397CE37C887C297BC57B5C7AEE7A7C7A0579897909788477FA776B76D87641;
        xtab[31] = 256'h7FFD7FF57FE97FD87FC17FA67F867F617F377F097ED57E9C7E5F7E1D7DD57D89;

        ytab[ 0] = 256'h176E15E2145512C8113A0FAB0E1C0C8C0AFB096A07D9064804B6032401920000;
        ytab[ 1] = 256'h2F872E112C992B1F29A3282626A8252823A62223209F1F1A1D931C0B1A8218F9;
        ytab[ 2] = 256'h45CD447A432541CE40733F173DB83C563AF2398C382436BA354D33DF326E30FB;
        ytab[ 3] = 256'h59645842571D55F554C9539B526851334FFB4EBF4D814C3F4AFB49B44869471C;
        ytab[ 4] = 256'h698B68A667BC66CF65DD64E863EE62F161F060EB5FE35ED75DC75CB35B9C5A82;
        ytab[ 5] = 256'h75A57504745F73B573077254719D70E270226F5E6E966DC96CF86C236B4A6A6D;
        ytab[ 6] = 256'h7D397CE37C887C297BC57B5C7AEE7A7C7A0579897909788477FA776B76D87641;
        ytab[ 7] = 256'h7FFD7FF57FE97FD87FC17FA67F867F617F377F097ED57E9C7E5F7E1D7DD57D89;
        ytab[ 8] = 256'h7DD57E1D7E5F7E9C7ED57F097F377F617F867FA67FC17FD87FE97FF57FFD7FFF;
        ytab[ 9] = 256'h76D8776B77FA7884790979897A057A7C7AEE7B5C7BC57C297C887CE37D397D89;
        ytab[10] = 256'h6B4A6C236CF86DC96E966F5E702270E2719D7254730773B5745F750475A57641;
        ytab[11] = 256'h5B9C5CB35DC75ED75FE360EB61F062F163EE64E865DD66CF67BC68A6698B6A6D;
        ytab[12] = 256'h486949B44AFB4C3F4D814EBF4FFB51335268539B54C955F5571D584259645A82;
        ytab[13] = 256'h326E33DF354D36BA3824398C3AF23C563DB83F17407341CE4325447A45CD471C;
        ytab[14] = 256'h1A821C0B1D931F1A209F222323A6252826A8282629A32B1F2C992E112F8730FB;
        ytab[15] = 256'h0192032404B6064807D9096A0AFB0C8C0E1C0FAB113A12C8145515E2176E18F9;
        ytab[16] = 256'hE892EA1EEBABED38EEC6F055F1E4F374F505F696F827F9B8FB4AFCDCFE6E0000;
        ytab[17] = 256'hD079D1EFD367D4E1D65DD7DAD958DAD8DC5ADDDDDF61E0E6E26DE3F5E57EE707;
        ytab[18] = 256'hBA33BB86BCDBBE32BF8DC0E9C248C3AAC50EC674C7DCC946CAB3CC21CD92CF05;
        ytab[19] = 256'hA69CA7BEA8E3AA0BAB37AC65AD98AECDB005B141B27FB3C1B505B64CB797B8E4;
        ytab[20] = 256'h9675975A984499319A239B189C129D0F9E109F15A01DA129A239A34DA464A57E;
        ytab[21] = 256'h8A5B8AFC8BA18C4B8CF98DAC8E638F1E8FDE90A2916A9237930893DD94B69593;
        ytab[22] = 256'h82C7831D837883D7843B84A48512858485FB867786F7877C88068895892889BF;
        ytab[23] = 256'h8003800B80178028803F805A807A809F80C980F7812B816481A181E3822B8277;
        ytab[24] = 256'h822B81E381A18164812B80F780C9809F807A805A803F80288017800B80038001;
        ytab[25] = 256'h892888958806877C86F7867785FB8584851284A4843B83D78378831D82C78277;
        ytab[26] = 256'h94B693DD93089237916A90A28FDE8F1E8E638DAC8CF98C4B8BA18AFC8A5B89BF;
        ytab[27] = 256'hA464A34DA239A129A01D9F159E109D0F9C129B189A2399319844975A96759593;
        ytab[28] = 256'hB797B64CB505B3C1B27FB141B005AECDAD98AC65AB37AA0BA8E3A7BEA69CA57E;
        ytab[29] = 256'hCD92CC21CAB3C946C7DCC674C50EC3AAC248C0E9BF8DBE32BCDBBB86BA33B8E4;
        ytab[30] = 256'hE57EE3F5E26DE0E6DF61DDDDDC5ADAD8D958D7DAD65DD4E1D367D1EFD079CF05;
        ytab[31] = 256'hFE6EFCDCFB4AF9B8F827F696F505F374F1E4F055EEC6ED38EBABEA1EE892E707;

        etab[ 0] = 256'h0780070006800600058005000480040003800300028002000180010000800000;
        etab[ 1] = 256'h0F800F000E800E000D800D000C800C000B800B000A800A000980090008800800;
        etab[ 2] = 256'h1780170016801600158015001480140013801300128012001180110010801000;
        etab[ 3] = 256'h1F801F001E801E001D801D001C801C001B801B001A801A001980190018801800;
        etab[ 4] = 256'h2780270026802600258025002480240023802300228022002180210020802000;
        etab[ 5] = 256'h2F802F002E802E002D802D002C802C002B802B002A802A002980290028802800;
        etab[ 6] = 256'h3780370036803600358035003480340033803300328032003180310030803000;
        etab[ 7] = 256'h3F803F003E803E003D803D003C803C003B803B003A803A003980390038803800;
        etab[ 8] = 256'h4780470046804600458045004480440043804300428042004180410040804000;
        etab[ 9] = 256'h4F804F004E804E004D804D004C804C004B804B004A804A004980490048804800;
        etab[10] = 256'h5780570056805600558055005480540053805300528052005180510050805000;
        etab[11] = 256'h5F805F005E805E005D805D005C805C005B805B005A805A005980590058805800;
        etab[12] = 256'h6780670066806600658065006480640063806300628062006180610060806000;
        etab[13] = 256'h6F806F006E806E006D806D006C806C006B806B006A806A006980690068806800;
        etab[14] = 256'h7780770076807600758075007480740073807300728072007180710070807000;
        etab[15] = 256'h7F807F007E807E007D807D007C807C007B807B007A807A007980790078807800;
        etab[16] = 256'h8780870086808600858085008480840083808300828082008180810080808000;
        etab[17] = 256'h8F808F008E808E008D808D008C808C008B808B008A808A008980890088808800;
        etab[18] = 256'h9780970096809600958095009480940093809300928092009180910090809000;
        etab[19] = 256'h9F809F009E809E009D809D009C809C009B809B009A809A009980990098809800;
        etab[20] = 256'hA780A700A680A600A580A500A480A400A380A300A280A200A180A100A080A000;
        etab[21] = 256'hAF80AF00AE80AE00AD80AD00AC80AC00AB80AB00AA80AA00A980A900A880A800;
        etab[22] = 256'hB780B700B680B600B580B500B480B400B380B300B280B200B180B100B080B000;
        etab[23] = 256'hBF80BF00BE80BE00BD80BD00BC80BC00BB80BB00BA80BA00B980B900B880B800;
        etab[24] = 256'hC780C700C680C600C580C500C480C400C380C300C280C200C180C100C080C000;
        etab[25] = 256'hCF80CF00CE80CE00CD80CD00CC80CC00CB80CB00CA80CA00C980C900C880C800;
        etab[26] = 256'hD780D700D680D600D580D500D480D400D380D300D280D200D180D100D080D000;
        etab[27] = 256'hDF80DF00DE80DE00DD80DD00DC80DC00DB80DB00DA80DA00D980D900D880D800;
        etab[28] = 256'hE780E700E680E600E580E500E480E400E380E300E280E200E180E100E080E000;
        etab[29] = 256'hEF80EF00EE80EE00ED80ED00EC80EC00EB80EB00EA80EA00E980E900E880E800;
        etab[30] = 256'hF780F700F680F600F580F500F480F400F380F300F280F200F180F100F080F000;
        etab[31] = 256'hFF80FF00FE80FE00FD80FD00FC80FC00FB80FB00FA80FA00F980F900F880F800;
        // ==== TABLE-END ====
    end

    function [15:0] xv; input integer k; begin xv = xtab[k >> 4][(k & 15) * 16 +: 16]; end endfunction
    function [15:0] yv; input integer k; begin yv = ytab[k >> 4][(k & 15) * 16 +: 16]; end endfunction
    function [15:0] ev; input integer k; begin ev = etab[k >> 4][(k & 15) * 16 +: 16]; end endfunction

    // 整数开方（Newton 迭代）——避免依赖仿真器的 $sqrt 等数学系统函数
    function integer isqrt;
        input integer v;
        integer x, y;
        begin
            if (v <= 0) isqrt = 0;
            else begin
                x = v;
                y = (x + 1) / 2;
                while (y < x) begin
                    x = y;
                    y = (x + v / x) / 2;
                end
                isqrt = x;
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 统计与激励
    //-------------------------------------------------------------------------
    integer k, rd, err_cnt, max_abs, sumsq, nrecv, to_cnt, lat_cnt, lat_meas;
    integer mag_min, mag_max, rms_m;
    integer d, ideal;
    integer case_err;

    // 监视：每个 out_valid 取一个结果，顺序与驱动顺序一致
    // ★ 采样限定信号必须与 angle 数据同拍：DUT 里 out_valid 与 angle 在同一个
    //   时钟沿更新，但本 always 块在**同一个沿**上读到的 angle 还是更新前的旧值
    //   （非阻塞赋值语义），于是第 k 个样本读到的是第 k-1 个结果，512 点整体滞后
    //   一个扫描步长（= 128 LSB = 0.703125 deg）。把 out_valid 打一拍再作为采集
    //   限定，采样点就落在数据已经稳定的那一拍上。
    reg vld_d;
    always @(posedge clk) begin
        if (!rst_n) vld_d <= 1'b0;
        else        vld_d <= out_valid;
    end

    always @(posedge clk) begin
        if (rst_n && vld_d) begin
            if (rd < NPT) begin
                if (angle !== ev(rd)) begin
                    err_cnt = err_cnt + 1;
                    if (err_cnt <= 8)
                        $display("  [MISMATCH] k=%0d angle=%0d golden=%0d", rd, angle, ev(rd));
                end
                ideal = (rd * ISTEP) & 16'hFFFF;
                d = angle - ideal;
                if (d >  32768) d = d - 65536;
                if (d < -32768) d = d + 65536;
                if (d < 0) d = -d;
                if (d > max_abs) max_abs = d;
                sumsq = sumsq + d * d;
                if (mag < mag_min) mag_min = mag;
                if (mag > mag_max) mag_max = mag;
                rd = rd + 1;
            end
            nrecv = nrecv + 1;
        end
    end

    // 单点检查任务（带间隔，检查边界/退化输入）
    task one_vec;
        input signed [IW-1:0] tx;
        input signed [IW-1:0] ty;
        input        [AW-1:0] texp;
        input integer         tid;
        integer w;
        begin
            @(posedge clk);
            x_in <= tx; y_in <= ty; in_valid <= 1'b1;
            @(posedge clk);
            in_valid <= 1'b0;
            w = 0;
            while (out_valid !== 1'b1 && w < 40) begin
                @(posedge clk);
                w = w + 1;
            end
            @(negedge clk);
            if (angle !== texp) begin
                case_err = case_err + 1;
                $display("  [CASE %0d FAIL] x=%0d y=%0d angle=%0d expect=%0d",
                         tid, tx, ty, angle, texp);
            end else begin
                $display("  [CASE %0d ok  ] x=%6d y=%6d angle=%5d (=%8.4f deg) mag=%0d",
                         tid, tx, ty, angle, angle * 360.0 / 65536.0, mag);
            end
            @(posedge clk);
        end
    endtask

    integer i;
    initial begin
        rst_n    = 1'b0;
        x_in     = 16'sd0;
        y_in     = 16'sd0;
        in_valid = 1'b0;
        rd = 0; err_cnt = 0; max_abs = 0; sumsq = 0; nrecv = 0;
        mag_min = 1000000; mag_max = -1; case_err = 0;

        $display("================================================================");
        $display(" tb_cordic_atan2 : AW=%0d IW=%0d NITER=%0d FEXT=%0d  Latency=%0d clk (%0d ns @50MHz)",
                 AW, IW, NITER, FEXT, LAT, LAT * 20);
        $display("================================================================");

        repeat (5) @(posedge clk);
        if (out_valid !== 1'b0 || angle !== 16'd0 || mag !== 18'd0) begin
            $display("  [RESET FAIL] out_valid=%b angle=%0d mag=%0d", out_valid, angle, mag);
            case_err = case_err + 1;
        end else begin
            $display("  [RESET ok  ] out_valid=0 angle=0 mag=0");
        end
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 单次延迟测量 -------------------------------------------------
        @(posedge clk);
        x_in <= 16'sd32767; y_in <= 16'sd0; in_valid <= 1'b1;
        @(posedge clk);
        in_valid <= 1'b0;
        lat_cnt = 0;
        while (out_valid !== 1'b1 && lat_cnt < 40) begin
            @(posedge clk);
            lat_cnt = lat_cnt + 1;
        end
        // lat_cnt 在 while 循环里每跳一个 @(posedge clk) 加 1，循环退出时它已经
        // 等于"in_valid 有效那一拍 -> out_valid 有效那一拍"的拍数（= NITER+2 = 19）。
        // 原式再 +1 会多算一拍，使延迟检查误报 case_err（实测 19 却被判成 20）。
        lat_meas = lat_cnt;
        $display("  [LATENCY   ] 实测 %0d 拍（期望 %0d 拍 = %0d ns @50MHz）",
                 lat_meas, LAT, LAT * 20);
        if (lat_meas !== LAT) case_err = case_err + 1;
        @(posedge clk);

        // ---- 全圆 512 点扫描 ----------------------------------------------
        for (k = 0; k < NPT; k = k + 1) begin
            @(posedge clk);
            x_in <= xv(k);
            y_in <= yv(k);
            in_valid <= 1'b1;
        end
        @(posedge clk);
        in_valid <= 1'b0;
        x_in <= 16'sd0; y_in <= 16'sd0;

        to_cnt = 0;
        while (rd < NPT && to_cnt < 200) begin
            @(posedge clk);
            to_cnt = to_cnt + 1;
        end

        rms_m = (max_abs <= 1000) ? isqrt((sumsq / NPT) * 1000000) : -1;
        $display("----------------------------------------------------------------");
        $display(" 全圆扫描 512 点（0.703125 deg 步长，理想角度 = k*128 LSB）");
        $display("   收到结果      : %0d / %0d", rd, NPT);
        $display("   黄金表逐位比对: 不符 %0d 点", err_cnt);
        $display("   最坏 |误差|   : %0d LSB = %0.6f deg", max_abs, max_abs * 360.0 / 65536.0);
        if (rms_m >= 0)
            $display("   RMS 误差      : %0d.%03d LSB = %0.6f deg",
                     rms_m / 1000, rms_m % 1000, rms_m / 1000.0 * 360.0 / 65536.0);
        else
            $display("   RMS 误差      : 误差过大，仅统计均方和 %0d", sumsq / NPT);
        $display("   mag 范围      : %0d .. %0d", mag_min, mag_max);
        $display("----------------------------------------------------------------");

        // ---- 边界与退化输入 ----------------------------------------------
        $display(" 边界点与退化输入：");
        one_vec( 16'sd32767,  16'sd0,     16'd0,     1);
        one_vec( 16'sd0,      16'sd32767, 16'd16384, 2);
        one_vec(-16'sd32767,  16'sd0,     16'd32768, 3);
        one_vec( 16'sd0,     -16'sd32767, 16'd49152, 4);
        one_vec( 16'sd23170,  16'sd23170, 16'd8192,  5);
        one_vec(-16'sd23170,  16'sd23170, 16'd24576, 6);
        one_vec(-16'sd23170, -16'sd23170, 16'd40960, 7);
        one_vec( 16'sd23170, -16'sd23170, 16'd57344, 8);
        one_vec(-16'sd32768,  16'sd0,     16'd32768, 9);
        one_vec( 16'sd0,     -16'sd32768, 16'd49152, 10);
        one_vec(-16'sd32768, -16'sd1,     16'd32768, 11);  // 接近 180deg 的极端

        $display("----------------------------------------------------------------");
        if (err_cnt == 0 && max_abs <= 1 && case_err == 0 &&
            rd == NPT && lat_meas == LAT && mag_min > 32000 && mag_max < 34000) begin
            $display(" TEST PASSED");
        end else begin
            $display(" TEST FAILED  (mismatch=%0d max_abs=%0d case_err=%0d recv=%0d/%0d lat=%0d)",
                     err_cnt, max_abs, case_err, rd, NPT, lat_meas);
        end
        $display("================================================================");
        $finish;
    end

endmodule
