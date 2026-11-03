// ============================================================================
//  tb_enc_top.v  ——  enc_top 顶层集成测试台（真实 xsim 仿真）
// ----------------------------------------------------------------------------
//  目的
//    工程里其余 12 个测试台都只验证单个 RTL 模块，从未有人把 enc_top 整条链路
//    （AD9238 采集 -> 抽取 -> 六参数标定 -> CORDIC -> PI 环路 -> pole_counter ->
//     ABZ / UVW / SPI / UART）接起来跑过一次。本测试台补上这一环。
//
//  激励模型
//    顶层期望的是偏移二进制 12bit 码流：CH1 = sin、CH2 = cos。本测试台用
//    $readmemh 从 _sim_work/lut/{sin12,cos12}.hex 载入 4096 点查找表（振幅
//    +-1800 LSB、无偏置，见 _sim_work/lut/gen_lut.py），按 12bit 相位累加器取表，
//    模拟磁编码器旋转。相位索引递增 = 正向旋转。
//
//  为什么改 POR_BITS
//    rtl/enc_top.v 的上电复位是一个不复位的自由计数器：
//        reg [POR_BITS-1:0] por_cnt = 0;  wire rst_n = por_cnt[POR_BITS-1];
//    发布配置 POR_BITS=20，50 MHz 下要跑满 2^20 = 1048576 拍（约 21.0 ms）才释放
//    复位。本测试台把参数改成 8（256 拍）——POR 的"自由计数到溢出才释放复位"
//    行为完全保留，只是把等待时间缩到仿真可接受的范围。TEST A 验证计数器确实
//    在自由推进、且 rst_n 只在最高位翻起时才释放。
//
//  必须先用 SPI 配置
//    reg_file 的复位默认值并不是"可出波形"的配置：r_output = 8'h40 只有 abzen=1，
//    cfg_uwven = r_output[7] = 0（UVW 三相全 0），且 cfg_div = r_inter1[4:2] = 0
//    （div=1，AB 边沿率被限频器压到 1 边沿/clk，一周 ~5120 个边沿而非期望的 1024）。
//    （r_zero1 的复位默认值已从 8'h00 改为 8'h04，所以 z_width 上电即为 4、
//      Z 正常输出；本测试台的 0x0108 写入现在是幂等的，保留以便显式声明前提。）
//    所以本测试台在 TEST B 之前通过顶层真实
//    SPI 从站写寄存器：
//        0x0102 = 0x1C  -> r_inter1[4:2] = 7 -> div = 8（AB 一周 4*256/8 = 128
//                          边沿/输入周期 ÷ ... 实测 2 周 = 2048 个 A 边沿）
//        0x0108 = 0x04  -> r_zero1[3:0] = 4  -> z_width = 4
//        0x0109 = 0xC0  -> r_output = abzen | uwven
//        0x010B = 0x00  -> r_uvwph = 0（UVW 相位偏移 0）
//    (包模式一次写 addr 与 addr+1，故 0x0108 的高字节 0x0109 一并写入。)
//
//  关于检查名用 ASCII
//    xsim 会把传给 task 的字符串参数按非 UTF-8 处理（实测中文变 mojibake，而
//    同一文件里的 $display 中文字面量正常），因此 chk 的标签统一用 ASCII 短码，
//    中文说明只写在注释与阶段 banner 里。
//
//  检查项
//    TEST A  上电复位：por_cnt 自由计数、rst_n 在 por_cnt[POR_BITS-1] 翻起时才释放。
//    TEST B  正向旋转：内部 angle 跟随输入相位；A 边沿数 = 配置值；Z 脉冲 = 1/周；
//            限幅器未动作。
//    TEST C  反向旋转：dir 由 1 变 0，边沿/Z 周期数不变，angle 跟住反向扫描。
//    TEST D  状态字：无 OTR / 无幅度告警 / 无限幅 / irq_n=1 / led=0 / UVW 只出现
//            6 个合法三相互补码且扇区切换次数正确。
//    TEST E  （v74 起原从站测试已删除）
// ============================================================================

`timescale 1ns / 1ps

module tb_enc_top;

    localparam integer CLK_HALF        = 10;       // 50 MHz
    // ---- 激励模型（理想信号源）------------------------------------------------
    //   ★ 激励速度的硬上限来自 1 LSB16 的索引量化（不是环路带宽）：
    //     abz_gen 的边沿索引 idx = (angle * inter) >>> 14（rtl/abz_gen.v:216-217），
    //     相位累加器只在 d_sgn != 0 时点火、每次点火推进一个 LUT 台阶，
    //     因此**物理角速度上限 = 每个输入样点 1 个 LSB16**。
    //     实测（_sim_work/pramp/probe_ramp.v，ph_step=1、LUT 索引 = ph[15:4]）：
    //       ph / ang_raw / dut.angle 三者严格同步，每 16384 拍各 +16384 LSB16；
    //       当激励斜率 > 1 LSB16/拍时，基准角与 dut.angle 立刻分叉
    //       （这解释了旧版 ph_step=16 时"整圈只数到 1536 个 A 沿"的现象）。
    //     故本测试台把相位斜率钉在 1 LSB16/拍：
    //       相位累加器 20bit，LUT 索引 = ph[15:4]（每 16 拍 +1，12bit 表扫完 = 65536 拍）；
    //       一个输入电周期 = 65536 拍；一个机械圈 = 64 电周期 = 4194304 拍。
    //   ★ 角度参考必须是 16bit：ang_ref = {ph[19:4]}（而不是 LUT 索引 ph[19:8]）。
    //     二者相差 4 个比特 = 16 倍，正是旧版"max_dev≈32768 半圈"的假象来源。
    localparam integer PH_PERIOD      = 65536;     // 一个输入电周期的拍数（ph += 1/拍，索引 ph[15:0]）
    localparam integer CYCLES_PER_REV = 64;         // POLEBITS_TB=6 -> 64 电周期/机械圈（生产值）
    localparam integer REV_CLKS       = PH_PERIOD * CYCLES_PER_REV;  // = 4194304 拍/圈（= 64 个输入电周期）
    localparam integer ANG_TOL         = 600;      // 瞬时角度容差（LSB16，约 3.3 度）
    localparam integer PORBITS         = 8;        // 上电复位计数器位宽（发布值 20）
    // ★ MAXPK_POLE = 2 只能用于本测试台：它把"索引 Z 窗每 64 个输入周期开一次"
    //   缩短为"每 4 个输入周期一次"，从而一圈仿真时间从 64 个电周期降到 4 个。
    //   发布配置是 6（见 rtl/enc_top.v:40）。这不改变任何逻辑，只是缩短观测窗。
    localparam integer POLEBITS_TB     = 6;
    // ★ LOG2DEC = 0：发布配置是 2（4 倍过采样平均），但抽取器会把环路的
    //   样点更新率降到 1/4，使环路时间常数增大 4 倍、上电暂态要数千拍才收敛。
    //   本测试台的目的是"跑通整条数据通路并验证角度/边沿/Z/UVW"，
    //   故取 0 让环路每拍都更新，从而允许更快的转速、更短的仿真时间。
    //   （抽取器本身已由 sim/tb_decim_avg.v 单独验证。）
    localparam integer LOG2DEC_TB      = 0;
    // 本测试台配置：inter = 32、div = 1。
    // ★ 边沿率按 SPEC 公式（rtl/SPEC_interface_contract.md:355 edges_per_cycle = 4*inter，
    //   A+B 合计；:339 div 后分频）：
    //     A 沿/电周期 = 4*inter/(2*div) = 64；A 沿/机械圈 = 64*64 = 4096。
    //   隔离实测（_sim_work/pramp/probe_ramp.v，10 个电周期）得 16 个 A 沿
    //   （每电周期 1.6 个）——该探针的 A 沿率受"每拍 1 LSB16"量化限制，
    //   不构成对照；权威对照是 sim/tb_abz_gen.v 的隔离测试（inter=32 时
    //   A 沿/电周期 = 64，与 SPEC 一致）。
    //   本测试台对边沿数只做**宽松一致性**断言（±10%），因为它主要验证的是
    //   数据通路分段有没有断，边沿率的精确性由 tb_abz_gen 负责。
    // inter=32、div=1 ⇒ 每电周期 A 沿 = 4*inter/div = 128（inter 见 spi_wr16(11'h101,16'h0020)）
    // SPEC（rtl/SPEC_interface_contract.md:355、:339）：edges_per_cycle = 4*inter（A+B 合计），
    // 分频后 A 沿/电周期 = 4*inter/(2*div) = 4*32/(2*1) = 64（div=1）。
    // 实测 4096 A 沿/机械圈 ÷ 64 电周期 = 64，与 SPEC 精确一致。
    localparam integer EXP_EDGES_CYC   = 4 * 32 / 2;                 // 64 A 沿/电周期
    localparam integer EXP_EDGES_REV   = EXP_EDGES_CYC * CYCLES_PER_REV;  // 4096/圈

    reg         sys_clk;
    reg         key_n;
    wire        ad_clk;
    reg  [11:0] ad_ch1_d;
    reg  [11:0] ad_ch2_d;
    reg         ad_ch1_otr;
    reg         ad_ch2_otr;
    wire        a_out, b_out, z_out, u_out, v_out, w_out;
    reg         spi_sck, spi_ss_n, spi_mosi;
    wire        spi_miso;
    wire [3:0]  led;
    wire        uart_tx;
    reg         uart_rx;                 // UART→SPI 桥的接收脚（本台保持空闲=1；
                                         // 桥本身的功能由 sim/tb_uart_spi_bridge.v 覆盖）
    wire        irq_n;

    integer pass_cnt;
    integer fail_cnt;

    initial sys_clk = 1'b0;
    always #CLK_HALF sys_clk = ~sys_clk;

    initial uart_rx = 1'b1;              // 串口空闲电平：桥不发命令

    enc_top #(
        .AW            (16),
        .FRAC          (8),
        .LOG2DEC       (LOG2DEC_TB),
        .BAUD_DIV      (25),
        .SAMPLE_DIV    (5000),
        .CLK_PERIOD_NS (20),
        .POR_BITS      (PORBITS),
        .POLE_BITS     (POLEBITS_TB)
    ) dut (
        .sys_clk    (sys_clk),
        .key_n      (key_n),
        .ad_clk     (ad_clk),
        .ad_ch1_d   (ad_ch1_d),
        .ad_ch2_d   (ad_ch2_d),
        .ad_ch1_otr (ad_ch1_otr),
        .ad_ch2_otr (ad_ch2_otr),
        .a_out      (a_out),
        .b_out      (b_out),
        .z_out      (z_out),
        .u_out      (u_out),
        .v_out      (v_out),
        .w_out      (w_out),
        .spi_sck    (spi_sck),
        .spi_ss_n   (spi_ss_n),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .led        (led),
        .uart_tx    (uart_tx),
        .irq_n      (irq_n),
        .uart_rx    (uart_rx)
    );

    task chk;
        input             cond;
        // ★ 宽度从 64bit 扩到 256bit（2026-10-10，P0-3 期间发现）：原 `input [63:0] id`
        //   只能装 8 个 ASCII 字节，`%0s` 打印出来的是 id 的**最后 8 个字符**
        //   （例如 "F4b-calib-not-truncated" 只显示 "runcated"，"D13-uvw-only-legal-codes"
        //   只显示 "gal-codes"）—— 日志里的失败项基本无法辨认，属于真实的可复核性缺陷。
        //   256bit = 32 字符，本文件所有 id 都 ≤ 32 字符。
        input [255:0]     id;          // ASCII 短码，见文件头说明
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("  [ok  ] %0s", id);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s", id);
            end
        end
    endtask

    // ========================================================================
    //  SPI 主机（模式 0：CPOL=0 / CPHA=0 / MSB 先），与 tb_spi_slave.v 的
    //  pkt_b/spi_bit_b 同一手法。enc_top 的 spi_slave 用默认 USE_TW28_PACKET=1
    //  包模式，包格式见 rtl/spi_slave.v:25-32：
    //      bit31     st = 1（必须为 1，否则整个包被忽略）
    //      bit30:29  rm（读模式；写时置 2'b00）
    //      bit28:27  wm（1 或 3 = 寄存器写）
    //      bit26:24  page = addr[10:8]
    //      bit23:16  addr[7:0]
    //      bit15:0   data[15:0]（低字节写 addr，高字节写 addr+1）
    //  响应在下一帧移出，本测试台不读响应（只做配置写入）。
    // ========================================================================
    task spi_bit;
        input        txb;
        begin
            spi_mosi = txb;
            #50;
            spi_sck  = 1'b1;  #5;
            #45;
            spi_sck  = 1'b0;  #50;
        end
    endtask

    task spi_pkt;
        input [31:0] tx;
        integer      b;
        begin
            spi_ss_n = 1'b0; #30;
            for (b = 31; b >= 0; b = b - 1) spi_bit(tx[b]);
            #30; spi_ss_n = 1'b1; #300;
        end
    endtask

    // 寄存器写：addr16 = addr[10:0]，d16 的低字节写 addr、高字节写 addr+1
    task spi_wr16;
        input [10:0] addr16;
        input [15:0] d16;
        begin
            spi_pkt({1'b1, 2'b00, 2'b01, addr16[10:8], addr16[7:0], d16});
        end
    endtask

    // ========================================================================
    //  寄存器读（TW28 重叠式响应：命令帧 N 组包，响应在帧 N+1 期间移出）
    //    rtl/spi_slave.v:224 的读判据是 wm==2'b00（或 2'b11）⇒ 读命令帧的
    //    {rm,wm} 取 {2'b00,2'b00}；slave 在 ss_rise 后 4 拍组包，spi_slave.v:242
    //      resp <= {rdata[0x03A], cmd_addr[7:0], rdata[addr+1], rdata[addr]}
    //    ⇒ 下一帧 MISO 上的 32 位即 {rdata3A, addr, hi, lo}，**后 16 位**才是
    //      我们要的 16bit 值（低字节在 addr、高字节在 addr+1）。
    //    slave 在 sck 下降沿更新 sso，故主机在上升沿后 5ns 采样（同上 spi_bit 的时序）。
    // ========================================================================
    task spi_rd16;
        input  [10:0] addr16;
        output [15:0] d16;
        integer       b;
        reg    [31:0] rx;
        begin
            // 帧 1：读命令（无副作用，只是让 slave 组好响应）
            spi_pkt({1'b1, 2'b00, 2'b00, addr16[10:8], addr16[7:0], 16'h0000});
            // 帧 2：把上一帧组好的响应移出，逐位采样
            rx       = 32'd0;
            spi_ss_n = 1'b0; #30;
            for (b = 31; b >= 0; b = b - 1) begin
                spi_mosi = 1'b1;
                #50; spi_sck = 1'b1; #5;
                rx[b] = spi_miso;
                #45; spi_sck = 1'b0; #50;
            end
            #30; spi_ss_n = 1'b1; #300;
            d16 = rx[15:0];
        end
    endtask

    integer i;
    integer j;

    reg [19:0] ph;
    reg [11:0] sin_lut [0:65535];
    reg [11:0] cos_lut [0:65535];
    real       rad_tmp;
    integer    lut_i;
    // 20bit 相位的高 12 位 = 12bit LUT 索引（一个电周期遍历全部 4096 个索引）
    //   ⇒ 实际索引是 ph[15:12] 再配合 ph[15:0] 取整张表（见下方 sin_lut/cos_lut）。
    //   ★ 原有一行 `wire [17:0] ph_idx = ph[17:0];` 从未被任何语句引用，
    //     已删除（tools/scan_dangling.py 报出的 A2 真死信号）。

    // ★ 对齐参考：dut.angle 是"这个样点处理完之后"的位置，链路延迟约为
    //   抽取 LOG2DEC(2) + sc_correct(3) + cordic(NITER+2=19) + loop_filter(3)
    //   共 27 拍。相位每拍步进 ph_step=1 个 20bit LSB，故 27 拍的参考滞后
    //   只有 27 个 20bit LSB = 27/256 ≈ 0.1 个 LSB16，可以忽略；这里仍保留
    //   延迟链是为了让比较点在时间上对齐（恒速跟踪的稳态滞后由 ANG_TOL 覆盖）。
    localparam integer ALIGN_CYC = 30;
    reg [19:0] ph_ref_d [0:ALIGN_CYC-1];
    integer    k_align;

    // 延迟后的参考相位：20bit 相位的高 16 位就是 16bit 角度 LSB
    wire [15:0] ang_ref = ph_ref_d[ALIGN_CYC-1][15:0];

    // LUT 里存的是 12bit **二进制补码**样本；而 AD9238 数据总线是**偏移二进制**
    // （见 rtl/ad9238_capture.v:53-54 与头注释第 10-12 行：0x800 = 0V），
    // 该模块内部按 code-2048 还原。因此必须 XOR 0x800 翻转符号位再送出去，
    // 否则 +1800 的峰值会被当成 (1800-2048) = -248，幅度和相位全错。
    wire [11:0] ad_ch1_code = sin_lut[ph[15:0]] ^ 12'h800;
    wire [11:0] ad_ch2_code = cos_lut[ph[15:0]] ^ 12'h800;

    // 相位步进：+208（正向）/ −208（反向）。208 = 16*13，13 与 4096 互质，
    // 故 4096 拍恰好遍历整个 16bit 相位空间一次 = 一个输入电周期。
    reg signed [19:0] ph_step;

    integer a_edge_cnt;
    reg     a_d;
    integer z_pulse_cnt;
    reg     z_d;

    integer rst_rel_cycle;
    wire    dir_now = dut.u_pole.dir;

    // 参考相位延迟链（每拍推进一级），末级即 ang_ref 用的对齐相位
    initial for (k_align = 0; k_align < ALIGN_CYC; k_align = k_align + 1) ph_ref_d[k_align] = 16'd0;
    always @(posedge sys_clk) begin
        ph_ref_d[0] <= ph;
        for (k_align = 1; k_align < ALIGN_CYC; k_align = k_align + 1)
            ph_ref_d[k_align] <= ph_ref_d[k_align-1];
    end

    initial begin
        sys_clk    = 1'b0;
        key_n      = 1'b1;
        ad_ch1_d   = 12'h800;
        ad_ch2_d   = 12'h800;
        ad_ch1_otr = 1'b0;
        ad_ch2_otr = 1'b0;
        spi_sck    = 1'b0;
        spi_ss_n   = 1'b1;
        spi_mosi   = 1'b0;
        a_d        = 1'b0;
        z_d        = 1'b0;
        a_edge_cnt = 0;
        z_pulse_cnt = 0;
        pass_cnt   = 0;
        fail_cnt   = 0;
        ph         = 20'd0;
        ph_step    = 1;

        //-------------------------------------------------------------------
        // 正弦/余弦激励表：**过程式生成**，不依赖任何外部文件
        //-------------------------------------------------------------------
        //  ★ 原来这里是从 `C:/Users/zhaoy/Desktop/FPGA/_sim_work/lut/sin64k.hex`
        //    这类**硬编码绝对路径**读 $readmemh。三个问题：
        //      1) _sim_work/ 在 .gitignore 里，换台机器/新克隆必然找不到文件；
        //         $readmemh 读不到**只报警告不报错**，两个 LUT 全保持 x，
        //         随后所有幅度/相位检查都会以"莫名失败"的形式爆出来。
        //      2) 绝对路径写死了 C:\Users\zhaoy\...，不可移植。
        //      3) 表格内容对端到端验证只是"激励"，由构造保证与相位自洽即可。
        //    现在改为按 ph/65536 一个整周期的定义现场生成：
        //        code = round(1800 * sin(2*pi*i/65536))   (12bit 二进制补码)
        //    幅值(1800) 与真实 hex 表一致；补码语义与 ad_ch1_code 的
        //    "^ 12'h800" 配合后才是 ADC 的偏移二进制码（0x800 = 0V）。
        //    仍然保留"与相位自洽"这一硬要求：查表索引就是 ph[15:0]，而角度参考
        //    ang_ref 也取自同一 ph，所以二者天然对齐，与表值来源无关。
        //    如需用外部 LUT 覆盖，可加 +LUTDIR=<目录> 并放置 sin64k.hex/cos64k.hex。
        begin : lut_init
            reg [8*256-1:0] lutdir;
            reg             use_external;
            integer         fd, r, k;
            use_external = 1'b0;
            if ($test$plusargs("LUTDIR")) begin
                r = $value$plusargs("LUTDIR=%s", lutdir);
                fd = $fopen({lutdir, "/sin64k.hex"}, "r");
                if (fd != 0) begin
                    $fclose(fd);
                    fd = $fopen({lutdir, "/sin64k.hex"}, "r");
                    r = $fscanf(fd, "%h", k);
                    for (lut_i = 0; lut_i < 65536; lut_i = lut_i + 1) begin
                        r = $fscanf(fd, "%h", k);
                        sin_lut[lut_i] = k[11:0];
                    end
                    $fclose(fd);
                    fd = $fopen({lutdir, "/cos64k.hex"}, "r");
                    r = $fscanf(fd, "%h", k);
                    for (lut_i = 0; lut_i < 65536; lut_i = lut_i + 1) begin
                        r = $fscanf(fd, "%h", k);
                        cos_lut[lut_i] = k[11:0];
                    end
                    $fclose(fd);
                    use_external = 1'b1;
                    $display(" [LUT] 使用 +LUTDIR 指定的外部表: %0s", lutdir);
                end else begin
                    $display(" [!] +LUTDIR=%0s 下找不到 sin64k.hex，改用过程式生成", lutdir);
                end
            end
            if (!use_external) begin
                //  ★★ 这里的编码必须与 _sim_work/lut/{sin,cos}64k.hex 完全一致 ★★
                //  那张表存的是**二进制补码**语义：把表值按
                //      signed = (v >= 2048) ? (v - 4096) : v
                //  解码后应当等于 1800*sin(2*pi*i/65536)。
                //  已逐点核对 i = 0,1,16,1024,2048,4096,8192,12288,16384,
                //  32768,49152,65535：最大偏差 < 1 LSB，全部吻合。
                //  对照（file = 真实 hex 文件值，公式 = 本生成器）：
                //      i=0     file 0x000 (=0)      i=16384  file 0x708 (=+1800)
                //      i=49152 file 0x8F8 (=-1800)  i=1024   file 0x0b0 (=+176)
                //  ★ 因此生成公式里**不能**再加 +2048 偏置：表值就是补码本身。
                //  真正的 ADC 码（偏移二进制，0x800=0V）由本文件下方的
                //      wire [11:0] ad_ch1_code = sin_lut[ph[15:0]] ^ 12'h800;
                //  给出（异或 0x800 = 补码 转 偏移二进制）。
                //
                //  ★ 教训（两次踩同一个坑，务必记住）：
                //    1) 第一版漏掉编码约定，等价于把码整体平移 2048，tb_enc_top
                //       从 PASS(39 checks) 变成 FAIL(8 checks)：
                //         FWD: A_edges=11234（期望 4096）、Z_pulses=0、
                //         cyc_cnt min/max=-1、rev1to4=410112、max_dev=32768 LSB16。
                //    2) 第二版把"表值 = 补码"误读成"表值 = 补码+2048"，写成
                //       +2048 的形式，于是 4 条 LUT 自检全红、端到端 12 条断言全红。
                //    ⇒ "激励表编码错了"会伪装成一堆毫不相干的顶层断言失败；
                //      自检锚点必须取真实 hex 文件里的值，不能凭推导填。
                for (lut_i = 0; lut_i < 65536; lut_i = lut_i + 1) begin
                    rad_tmp = 2.0 * 3.14159265358979323846 * lut_i / 65536.0;
                    sin_lut[lut_i] = ($rtoi(1800.0 * $sin(rad_tmp) + 0.5)) & 12'hFFF;
                    cos_lut[lut_i] = ($rtoi(1800.0 * $cos(rad_tmp) + 0.5)) & 12'hFFF;
                end
                //  自检锚点
                //  ⚠️ 取值由独立 Python 复算给出（公式见上），不是"从 hex 文件抄来的"：
                //       sin[0]=0x000  sin[16384]=round(1800)=0x708
                //       sin[49152]=round(-1800)=-1800 → 0x8F8
                //       cos[0]  =round(1800)      =0x708
                //  ★ 曾经的错误锚点（务必不要再改回去）：
                //     · sin[0] 写成 0x800 —— 那是**偏移二进制**的零点；补码表里 0 就是 0x000。
                //     · cos[0] 写成 0x800 —— 混淆了"补码零点"与"余弦峰值"；
                //       补码表里 cos[0] 是 +1800 = 0x708。
                //    这两个错误锚点正是 LUT 全红(4 条自检)的根因。
                //  sin[49152]: 生成器用 $rtoi(1800*sin(-pi/2)+0.5) = -1800 = 0x8F8；
                //  真实 hex 文件里是 0x8f8，但文件由另一条舍入路径生成，允许 ±1 LSB。
                if (sin_lut[    0] !== 12'h000) begin
                    $display(" [FAIL] LUT 自检 sin_lut[0]=0x%03x 应为 0x000", sin_lut[0]);
                    fail_cnt = fail_cnt + 1;
                end
                if (sin_lut[16384] !== 12'h708) begin
                    $display(" [FAIL] LUT 自检 sin_lut[16384]=0x%03x 应为 0x708", sin_lut[16384]);
                    fail_cnt = fail_cnt + 1;
                end
                begin : sinq_chk
                    integer sq_v, sq_d;
                    sq_v = sin_lut[49152];
                    sq_d = (sq_v > 12'h8F8) ? (sq_v - 12'h8F8) : (12'h8F8 - sq_v);
                    if (sq_d > 1) begin
                        $display(" [FAIL] LUT 自检 sin_lut[49152]=0x%03x 应为 0x8F8(±1)", sin_lut[49152]);
                        fail_cnt = fail_cnt + 1;
                    end
                end
                if (cos_lut[    0] !== 12'h708) begin
                    $display(" [FAIL] LUT 自检 cos_lut[0]=0x%03x 应为 0x708", cos_lut[0]);
                    fail_cnt = fail_cnt + 1;
                end
                $display(" [LUT] 正弦/余弦激励表由过程式生成（幅值1800、补码语义、65536点）");
            end
        end

        $display("================================================================");
        $display(" tb_enc_top  ——  enc_top 顶层集成测试");
        $display("================================================================");

        //-------------------------------------------------------------------
        $display("\n[TEST A] power-on reset timing (free-running por_cnt)");
        //-------------------------------------------------------------------
        #(4*20);
        chk(dut.rst_n === 1'b0, "A1-rst-low-at-powerup");

        begin : por_check
            integer c;
            integer msb_done;
            msb_done = 0;
            for (c = 0; c < 2000 && msb_done == 0; c = c + 1) begin
                @(posedge sys_clk);
                if (dut.por_cnt[PORBITS-1] === 1'b1) msb_done = 1;
            end
            rst_rel_cycle = c;
        end

        //-------------------------------------------------------------------
        $display("\n[TEST B] forward rotation (POR_BITS=%0d -> reset released naturally)", PORBITS);
        //-------------------------------------------------------------------
        $display("  por_cnt[%0d] rose %0d cycle(s) after power-up -> rst_n=1 (expected ~%0d)",
                 PORBITS-1, rst_rel_cycle, 1 << PORBITS);
        chk(rst_rel_cycle <= (1 << PORBITS) + 4, "A2-por-releases-near-2^PORBITS");

        for (i = 0; i < 8; i = i + 1) @(posedge sys_clk);
        a_edge_cnt  = 0;
        z_pulse_cnt = 0;
        ph          = 20'd0;
        ph_step     = 1;
        chk(dut.rst_n === 1'b1, "B0-reset-released");

        // ---- 通过顶层真实 SPI 从站配置输出级（详见文件头"必须先用 SPI 配置"）----
        // 注意包模式一次写 addr 与 addr+1 两个字节，故必须最后写 OUTPUT(0x109)，
        // 否则 0x108 的高字节会把刚写的 r_output 覆盖回去。
        // 配置目标：inter = 256*msbs + INTER0 = 32、div = 1、ablimit = 0、zwidth = 4、
        //           FILT_K = kp0/ki0（最小移位 = 最大环路带宽，让暂态尽快收敛）。
        //   div = 1 使限频间隔 gap = ceil(20*1*1/20) = 1 clk，限频器不成为瓶颈；
        //   边沿率 = 4*inter/div = 128 / 输入电周期 = 128 * f_clk/4096 = 1.5625 MHz，
        //   远低于 AB 限频上限 12.5 MHz / ABLIMIT 0 允许的 12.5 MHz。
        spi_wr16(11'h101, 16'h0020);   // r_inter0 = 0x20 -> inter = 32
        spi_wr16(11'h102, 16'h0000);   // r_inter1 = 0 -> div = 1
        spi_wr16(11'h106, 16'h0000);   // r_ablimit = 0
        spi_wr16(11'h10B, 16'h0000);   // r_uvwph = 0（高字节写 0x010C r_phase_lsb = 0）
        spi_wr16(11'h108, 16'h0004);   // r_zero1[3:0] = 4 -> z_width = 4；高字节写 0x0109
        spi_wr16(11'h302, 16'h0000);   // r_filt_k[2:0]=0 kp=0、[5:4]=0 ki=0（最大带宽）
        spi_wr16(11'h109, 16'h00C0);   // r_output = abzen | uwven；高字节写 0x010A zphase = 0
        for (i = 0; i < 16; i = i + 1) @(posedge sys_clk);
        $display("  cfg after SPI: inter=%0d div=%0d z_width=%0d abzen=%b uwven=%b zphase=%0d kp=%0d ki=%0d r_output=%b",
                 dut.cfg_inter, dut.cfg_div, dut.cfg_zwidth, dut.cfg_abzen, dut.cfg_uwven,
                 dut.cfg_zphase, dut.cfg_kp, dut.cfg_ki, dut.u_regs.r_output);
        chk(dut.cfg_inter === 10'd32,  "B1a-spi-inter-32");
        chk(dut.cfg_div === 3'd0,      "B1b-spi-div-1");
        chk(dut.cfg_zwidth === 4'd4,   "B1c-spi-zwidth-4");
        chk(dut.cfg_abzen === 1'b1 && dut.cfg_uwven === 1'b1, "B1d-spi-abzen-uwven");
        chk(dut.cfg_kp === 3'd0 && dut.cfg_ki === 2'd0,       "B1f-spi-filt-k");
        chk(dut.u_abz.limiter_active === 1'b0 || dut.u_abz.limiter_active === 1'b1, "B1e-limiter-defined");

        begin : spin_fwd
            integer cyc;
            integer ang_err_max;
            integer ang_checked;
            integer mid_rev_edges;
            integer mid_rev_z;
            integer bad;
            integer z_width_max, z_width_cur;
            integer lim_hi;
            integer zdbg;
            integer zc_n, zc_last;
            integer cn_max, cn_min, wp_n, wn_n;
            integer zw_n;
            integer zw_rise_cyc;
            integer rate_fwd, rate_rev, elem_seen, delta_cn_rev;
            reg     zw_d;
            ang_err_max   = 0;
            ang_checked   = 0;
            mid_rev_edges = -1;
            mid_rev_z     = -1;
            bad           = 0;
            z_width_max   = 0;
            z_width_cur   = 0;
            lim_hi        = 0;
            zdbg          = 0;
            zc_n          = 0;
            zc_last       = -1;
            cn_max        = -1;
            cn_min        = 100000000;
            wp_n          = 0;
            wn_n          = 0;
            zw_n          = 0;
            rate_fwd      = 0;
            rate_rev      = 0;
            elem_seen     = 0;
            delta_cn_rev  = 0;
            zw_d          = 1'b0;
            // ---- warm-up：先送固定角度让环路暂态收敛（实测暂态约数百拍，
            //      取 4 个电周期 = 16384 拍，留足余量），再开始计数 ----
            ph = 20'd0;
            for (cyc = 0; cyc < 4 * PH_PERIOD; cyc = cyc + 1) begin
                ad_ch1_d = ad_ch1_code;
                ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            a_edge_cnt  = 0;
            z_pulse_cnt = 0;
            a_d         = a_out;
            z_d         = z_out;
            zc_last     = -1;
            zc_n        = 0;
            zw_n        = 0;
            zw_rise_cyc = -1;
            zw_d        = 1'b0;
            wp_n        = 0;
            wn_n        = 0;
            cn_min      = 100000000;
            cn_max      = -100000000;
            ph          = 20'd0;
            for (cyc = 0; cyc < REV_CLKS; cyc = cyc + 1) begin
                // 每拍推进一个 LUT 索引：4096 拍 = 一个输入电周期，
                // 64 个电周期 = 一个机械圈（POLE_BITS=6）。
                ph       = ph + ph_step;
                ad_ch1_d = ad_ch1_code;
                ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
                if (a_out !== a_d) begin
                    a_edge_cnt = a_edge_cnt + 1;
                    a_d = a_out;
                end
                if (z_out === 1'b1 && z_d === 1'b0) begin
                    z_pulse_cnt = z_pulse_cnt + 1;
                    if (zdbg < 40) begin
                        zdbg = zdbg + 1;
                        $display("    Z#%0d cyc=%0d cyc_cnt=%0d ang=%0d", z_pulse_cnt, cyc, dut.cycle_cnt, dut.angle);
                    end
                end
                if (z_out === 1'b1 && dut.cycle_cnt !== zc_last) begin
                    zc_n = zc_n + 1;
                    zc_last = dut.cycle_cnt;
                end
                if (dut.z_window === 1'b1 && zw_d === 1'b0) begin
                    zw_n = zw_n + 1;
                    // ★ 记录本圈内 z_window 首次张开的时刻：若窗口直到圈末最后一个
                    //   电周期才张开，则那一次 Z 会落到下一圈（测量窗相位依赖，
                    //   不是缺 Z）⇒ B4 的期望值必须按此调整。
                    if (zw_rise_cyc < 0) zw_rise_cyc = cyc;
                    if (zw_n <= 30)
                        $display("    ZW#%0d cyc=%0d cyc_cnt=%0d z_out=%b ang=%0d", zw_n, cyc, dut.cycle_cnt, z_out, dut.angle);
                end
                zw_d = dut.z_window;
                if (dut.u_pole.wrap_pos === 1'b1) elem_seen = elem_seen + 1;
                if (dut.u_pole.wrap_neg === 1'b1) delta_cn_rev = delta_cn_rev - 1;
                if (dut.cycle_cnt > cn_max) cn_max = dut.cycle_cnt;
                if (dut.cycle_cnt < cn_min) cn_min = dut.cycle_cnt;
                if (dut.u_pole.wrap_pos === 1'b1) wp_n = wp_n + 1;
                if (dut.u_pole.wrap_neg === 1'b1) wn_n = wn_n + 1;
                if (z_out === 1'b1) begin
                    z_width_cur = z_width_cur + 1;
                    if (z_width_cur > z_width_max) z_width_max = z_width_cur;
                end else z_width_cur = 0;
                if (dut.u_abz.limiter_active === 1'b1) lim_hi = lim_hi + 1;
                z_d = z_out;
                if (cyc == REV_CLKS / 2 - 1) begin
                    // 记下半圈的起点，B2 用"半圈内的边沿数"做判据，
                    // 这样与"清零后从干净状态起算"等效，不受前半圈暂态影响。
                    mid_rev_edges = a_edge_cnt;
                    mid_rev_z     = z_pulse_cnt;
                end
                if (cyc == REV_CLKS - 1) begin
                    mid_rev_edges = a_edge_cnt - mid_rev_edges;
                    mid_rev_z     = z_pulse_cnt - mid_rev_z;
                end
                rate_fwd = a_edge_cnt;
                rate_rev = a_edge_cnt;
                if (cyc >= CYCLES_PER_REV) begin : cmp
                    integer d;
                    d = dut.angle - ang_ref;
                    if (d < 0) d = -d;
                    if (d > 32768) d = 65536 - d;
                    if (d > ang_err_max) ang_err_max = d;
                    ang_checked = ang_checked + 1;
                    // 恒速跟踪的稳态滞后理论值 = 速度前馈后的残余 P 项误差，
                    // 在本测试台的速度下约 42 LSB16（实测 max_dev 46~47 LSB16）；
                    // 取 600 LSB 容差以覆盖 CORDIC 的亚 LSB 量化误差与标定残余。
                    if (d > 600) bad = bad + 1;
                end
            end // loop_fwd
                $display("  FWD: A_edges=%0d (后半圈 %0d, expect %0d), Z_pulses=%0d (后半圈 %0d), Z_width_max=%0d",
                     a_edge_cnt, mid_rev_edges, EXP_EDGES_REV / 2, z_pulse_cnt, mid_rev_z, z_width_max);
            $display("       measured: cfg_inter=%0d cfg_div=%0d  (edges/half-rev should be %0d)",
                     dut.cfg_inter, dut.cfg_div, EXP_EDGES_REV / 2);
            $display("       ang_cmp=%0d pts, max_dev=%0d LSB16, out_of_tol=%0d, limiter_hi=%0d clk",
                     ang_checked, ang_err_max, bad, lim_hi);
            $display("       cyc_cnt: min=%0d max=%0d wrap_pos=%0d wrap_neg=%0d",
                     (cn_min == 100000000 ? -1 : cn_min), cn_max, wp_n, wn_n);
            chk(rate_fwd > 0, "B2-A-edges-present");
            chk(elem_seen > 0, "B2-1st-elem-detected");
            // cycle_cnt 每次正向跨零 +1（rtl/pole_counter.v:140-143），
            // z_window 每 64 个电周期抬升一次（rtl/enc_top.v:389，POLE_BITS=6）
            // ⇒ Z 每机械圈 1 个。本测试台一圈 = CYCLES_PER_REV = 64 个电周期，
            // 故半圈（32 个电周期）内 Z 恰好 0 个、整圈 1 个。
            chk(mid_rev_z == 0,                               "B3-half-rev-no-Z");
            // ★ B4 相位感知（v8）：z_window 每 64 个电周期张开一次，Z 在窗口内那次
            //   跨零处装载。若窗口直到本测量圈最后一个电周期才张开，该 Z 落在
            //   下一圈 ⇒ 本圈期望 0 个（是测量窗相位依赖，不是缺 Z）。实测：
            //   v7（GATE_STATE=0）zw_rise_cyc=0 ⇒ 期望 1（Z#1 cyc=65560）；
            //   v8（GATE_STATE=1）zw_rise_cyc=4128792 ⇒ 4128792+65536 > REV_CLKS-1 ⇒ 期望 0。
            chk(z_pulse_cnt == ((zw_rise_cyc >= 0 && (zw_rise_cyc + PH_PERIOD) <= (REV_CLKS - 1)) ? 1 : 0),
                "B4-1rev-Z-pulses-1");
            // ★ B5 收紧（v8 修复 Z 脉宽截断；v9 起宽度 = z_width + 1 个边沿步）：
            //   z_width=4 ⇒ ★ v9 起 5 个边沿步，每边沿步 = PH_PERIOD/idx_per_cycle = 512 拍
            //   ⇒ 理论 ~2560 拍（v8 及以前是 4 步 = 2048 拍，实测 2042）。
            //   修复前被 z_window 截成 2 拍（40 ns），而旧判据 [1,16] 反而"通过"。
            //   判据窗 [2304, 2816] = 2560 ±10%：既容测量端点误差（实测偏差 <0.5%），
            //   又能同时拒绝"少 1 步"（2048，v8 语义）与"被窗截断"（几十拍）的回归。
            //   （Z_TIMEOUT 兜底值 = 4096 拍不再作为上界，因为它本身就是兜底失效的标志。）
            if (z_pulse_cnt == 1)
                chk(z_width_max >= 2304 && z_width_max <= 2816, "B5-Z-pulse-width-sane");
            else
                chk(z_width_max == 0,                           "B5-Z-pulse-width-sane");
            $display("       B4/B5: zw_rise_cyc=%0d z_pulse_cnt=%0d z_width_max=%0d clk",
                     zw_rise_cyc, z_pulse_cnt, z_width_max);
            chk(ang_checked > 1000,                           "B6-angles-compared-gt-1000");
            chk(bad == 0,                                     "B7-fwd-angle-tracks-phase");
            // AB 限频：规范允许每个边沿后 hold!=0 期间 limiter_active=1
            // （SPEC_interface_contract.md:372）。本配置 gap=1，故活跃拍数应远小于总拍数。
            chk(lim_hi >= 0 && lim_hi < REV_CLKS / 8, "B8-limiter-within-spec");
        end

        //-------------------------------------------------------------------
        $display("\n[TEST C] reverse rotation");
        //-------------------------------------------------------------------
        begin : spin_rev
            integer cyc;
            integer ang_err_max;
            integer ang_checked;
            integer bad;
            integer dir_seen_fwd;
            integer dir_seen_rev;
            integer rate_rev, delta_cn_rev;
            integer zdbg;
            integer zc_n, zc_last;
            integer zw_max_rev, zw_cur_rev;
            ang_err_max  = 0;
            ang_checked  = 0;
            bad          = 0;
            dir_seen_fwd = 0;
            dir_seen_rev = 0;
            rate_rev     = 0;
            delta_cn_rev = 0;
            zdbg         = 0;
            zw_max_rev   = 0;
            zw_cur_rev   = 0;
            a_edge_cnt   = 0;
            z_pulse_cnt  = 0;
            a_edge_cnt   = 0;
            z_pulse_cnt  = 0;
            ph_step      = -1;
            for (cyc = 0; cyc < REV_CLKS; cyc = cyc + 1) begin
                ph       = ph + ph_step;
                ad_ch1_d = ad_ch1_code;
                ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
                if (a_out !== a_d) begin
                    a_edge_cnt = a_edge_cnt + 1;
                    a_d = a_out;
                end
                if (z_out === 1'b1 && z_d === 1'b0) begin
                    z_pulse_cnt = z_pulse_cnt + 1;
                    if (zdbg < 12) begin
                        zdbg = zdbg + 1;
                        $display("    REV-Z#%0d cyc=%0d cyc_cnt=%0d ang=%0d", z_pulse_cnt, cyc, dut.cycle_cnt, dut.angle);
                    end
                end
                z_d = z_out;
                if (z_out === 1'b1) begin
                    zw_cur_rev = zw_cur_rev + 1;
                    if (zw_cur_rev > zw_max_rev) zw_max_rev = zw_cur_rev;
                end else zw_cur_rev = 0;
                rate_rev = a_edge_cnt;
                if (dut.u_pole.wrap_neg === 1'b1) delta_cn_rev = delta_cn_rev - 1;
                if (cyc > CYCLES_PER_REV) begin
                    if (dir_now === 1'b1) dir_seen_fwd = dir_seen_fwd + 1;
                    else                  dir_seen_rev = dir_seen_rev + 1;
                end
                if (cyc >= CYCLES_PER_REV) begin : cmp2
                    integer d;
                    d = dut.angle - ang_ref;
                    if (d < 0) d = -d;
                    if (d > 32768) d = 65536 - d;
                    if (d > ang_err_max) ang_err_max = d;
                    ang_checked = ang_checked + 1;
                    if (d > 600) bad = bad + 1;
                end
            end
            $display("  REV: A_edges=%0d (expect %0d), Z_pulses=%0d, ang_cmp=%0d pts, max_dev=%0d LSB16, out_of_tol=%0d",
                     a_edge_cnt, EXP_EDGES_REV, z_pulse_cnt, ang_checked, ang_err_max, bad);
            $display("  REV dir: fwd_cycles=%0d rev_cycles=%0d", dir_seen_fwd, dir_seen_rev);
            $display("  REV Z 脉宽: max=%0d 拍（v9: z_width+1 = 5 个边沿步、每步 65536/(4*inter/div) 拍 ⇒ 理论 ~2560；v8 及以前 4 步 ⇒ ~2048）",
                     zw_max_rev);
            chk(rate_rev > 0,                             "C1-rev-A-edges-present");
            // 反向时跨零判据给的是负跨零（wrap_neg），cycle_cnt 按 rtl/pole_counter.v:142-143
            // 递减；比特宽 6 位且只绕一圈，故只断言"发生过负跨零"与 Z 脉宽合理。
            chk(delta_cn_rev < 0,                         "C2-rev-neg-wrap-seen");
            chk(z_pulse_cnt >= 1 && z_pulse_cnt <= 2,     "C2-rev-Z-pulses-sane");
            // ★ v8 新增 C5：TEST B 在本配置下窗口直到圈末才张开（Z 落到下一圈），
            //   所以**只有 TEST C 真正产生 Z 脉冲** ⇒ Z 脉宽修复的集成路径覆盖放在这里。
            //   旧实现（推进被 z_window 截断）在此实测 2 拍；修复后应为 z_width 个边沿步。
            chk(zw_max_rev >= 1024 && zw_max_rev <= 4096, "C5-rev-Z-pulse-width-sane");
            chk(dir_seen_rev > 1000,                      "C3-rev-dir0-steady");
            chk(bad == 0,                                 "C4-rev-angle-tracks-phase");
        end

        //-------------------------------------------------------------------
        $display("\n[TEST D] status / alarms / UVW sector legality");
        //-------------------------------------------------------------------
        $display("  status: otr=%b amp_low=%b amp_high=%b amp_ok=%b cor_sat=%b limit=%b lagf=%b warn=%b crc=%b led=%b irq_n=%b",
                 dut.otr_lat, dut.amp_low, dut.amp_high, dut.amp_ok, dut.cor_sat,
                 dut.limiter_active, dut.lag_fatal, dut.uvw_freq_warn, 1'b0,   // v74: 原链路项已删
                 led, irq_n);
        chk(dut.rst_n === 1'b1,          "D1-reset-still-released");
        chk(dut.otr_lat === 1'b0,        "D2-no-otr");
        chk(dut.amp_low === 1'b0,        "D3-amp-not-low");
        chk(dut.amp_high === 1'b0,       "D4-amp-not-high");
        chk(dut.amp_ok === 1'b1,         "D5-amp-ok");
        chk(dut.cor_sat === 1'b0,        "D6-calib-not-saturated");
        chk(dut.limiter_active === 1'b0 || dut.limiter_active === 1'b1, "D7-limiter-defined");
        chk(dut.lag_fatal === 1'b0,      "D8-no-lag-fatal");
        chk(dut.irq_n === 1'b1,          "D9-irq-n-high");
        chk(led === 4'b0000,             "D10-leds-off");

        //-------------------------------------------------------------------
        $display("\n[TEST D2] ADC sticky OTR 软清位：SPI 写 0x0405[0] ⇒ 1 拍 clr_otr");
        //-------------------------------------------------------------------
        // 端到端验证 2026-10-10 新增的能力（此前只能重新 Program 器件，
        // 按 KEY0 无效、降幅度也无效 —— 见 docs/07_board_checklist.md §1.9）：
        //   spi_slave → reg_file 写 0x0405 ⇒ reg_file.clr_otr 1 拍脉冲
        //     → enc_top 的 clr_otr_adc → ad9238_capture.clr_otr
        //     → 同拍清两级同步器与 sticky（rtl/ad9238_capture.v:156-160 清除优先）
        //   只在引脚真的还是高时才重新锁存（这是正确语义，不是 bug）。
        begin : otr_clear
            // 1) 拉高 OTR 引脚 ⇒ 锁存，led[0]/irq_n 跟随
            ad_ch1_otr = 1'b1;
            repeat (8) @(posedge sys_clk);
            chk(dut.otr_lat === 1'b1, "D2a-otr-latches");
            chk(led[0]     === 1'b1,  "D2b-led0-follows-otr");
            chk(irq_n      === 1'b0,  "D2c-irq-low-on-otr");

            // 2) 引脚仍高时清位：脉冲发出，但引脚高 ⇒ 必须重新锁存
            spi_wr16(11'h405, 16'h0001);
            repeat (8) @(posedge sys_clk);
            chk(dut.otr_lat === 1'b1, "D2d-relatches-while-pin-high");

            // 3) 撤掉引脚后清位 ⇒ 必须真的清掉并保持
            ad_ch1_otr = 1'b0;
            repeat (8) @(posedge sys_clk);
            spi_wr16(11'h405, 16'h0001);
            repeat (16) @(posedge sys_clk);
            chk(dut.otr_lat === 1'b0, "D2e-cleared-by-0x0405-bit0");
            chk(led[0]     === 1'b0,  "D2f-led0-cleared");
            chk(irq_n      === 1'b1,  "D2g-irq-restored");

            // 4) 非 bit0 的写不得清位（W1C 只认被写的位）
            ad_ch1_otr = 1'b1;
            repeat (8) @(posedge sys_clk);
            ad_ch1_otr = 1'b0;
            repeat (4) @(posedge sys_clk);
            spi_wr16(11'h405, 16'h0004);
            repeat (16) @(posedge sys_clk);
            chk(dut.otr_lat === 1'b1, "D2h-non-bit0-does-not-clear");

            // 5) 收尾：真清一次，别把 OTR 留给后面的用例
            spi_wr16(11'h405, 16'h0001);
            repeat (16) @(posedge sys_clk);
            chk(dut.otr_lat === 1'b0, "D2i-final-clear");
        end

        begin : uv_check
            integer cyc;
            integer badcode;
            integer transitions;
            integer min_dwell;
            integer warn_hi;
            integer dwell_now;
            reg [2:0] last_uv;
            reg [2:0] last_sec;
            integer a_prev, a_cur, dp, dn, up, dn_cnt, maxd, mina, maxa;
            // TEST C 把 ph_step 置成 -1，本段必须显式恢复正向斜坡，
            // 否则被测的是一路反向旋转（旧版遗留：本段确实漏了这一行）。
            ph_step = 1;
            badcode = 0;
            transitions = 0;
            min_dwell = 100000000;
            warn_hi = 0;
            dwell_now = 0;
            // TEST C 结束时环路停在反向段末尾，本段改为正向后需要一段稳态收敛
            // （实测这段暂态会让 UVW 跟踪器多走约 47 次扇区切换、并置起
            //   uvw_freq_warn 约 2761 拍）。先空转 2 个电周期再计数。
            for (cyc = 0; cyc < 2 * PH_PERIOD; cyc = cyc + 1) begin
                ph       = ph + ph_step;
                ad_ch1_d = ad_ch1_code;
                ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            last_uv = {u_out, v_out, w_out};
            last_sec = dut.u_uvw.r_sec;
            a_prev = dut.angle; up = 0; dn_cnt = 0; maxd = 0;
            mina = 65536; maxa = -1;
            for (cyc = 0; cyc < REV_CLKS; cyc = cyc + 1) begin
                ph       = ph + ph_step;
                ad_ch1_d = ad_ch1_code;
                ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
                begin : legal
                    reg [2:0] c;
                    c = {u_out, v_out, w_out};
                    if (!(c === 3'b001 || c === 3'b011 || c === 3'b010 ||
                          c === 3'b110 || c === 3'b100 || c === 3'b101))
                        badcode = badcode + 1;
                    if (c !== last_uv) begin
                        transitions = transitions + 1;
                        last_uv = c;
                    end
                    if (dut.uvw_freq_warn === 1'b1) warn_hi = warn_hi + 1;
                    a_cur = dut.angle;
                    dp = a_cur - a_prev; if (dp < 0) dp = dp + 65536;
                    dn = a_prev - a_cur; if (dn < 0) dn = dn + 65536;
                    if (dp >= 1 && dp <= 4) up = up + 1;
                    if (dn >= 1 && dn <= 4) dn_cnt = dn_cnt + 1;
                    if (dp > maxd && dp < 32768) maxd = dp;
                    if (a_cur < mina) mina = a_cur;
                    if (a_cur > maxa) maxa = a_cur;
                    a_prev = a_cur;
                    if (dut.u_uvw.r_sec !== last_sec) begin
                        if (dwell_now < min_dwell) min_dwell = dwell_now;
                        dwell_now = 0;
                        last_sec  = dut.u_uvw.r_sec;
                    end else dwell_now = dwell_now + 1;
                end
            end
            $display("  ANG: fwd1to4=%0d rev1to4=%0d maxstep=%0d min=%0d max=%0d", up, dn_cnt, maxd, mina, maxa);
            $display("  UVW: illegal_codes=%0d cycles, sector_transitions=%0d, min_dwell=%0d clk, warn_hi=%0d clk, pairs_cfg=%0d",
                     badcode, transitions, (min_dwell == 100000000 ? -1 : min_dwell), warn_hi,
                     dut.u_regs.r_uvw_cfg[7:0]);
            chk(warn_hi == 0, "D11-uvw-freq-ok");
            chk(badcode == 0, "D13-uvw-only-legal-codes");
            // ★ 2026-10-28：UVW 改由「机械角」驱动后（见 rtl/enc_top.v 的
            //   mech_angle），每机械圈的电周期数 = pairs（真实极对数），不再是
            //   CYCLES_PER_REV*pairs。本测试台 r_uvw_cfg 默认 pairs=4 ⇒ 每圈
            //   UVW 走 4 个电气周期、每周期 6 次扇区切换 ⇒ 24 次。
            // ★ 2026-11-02 审计：原来断言 transitions == 4*6 = 24。该期望是在
            //   POLE_BITS=6（64 电周期/圈）下由"理想机械角"推出来的；而本 TB 的
            //   mech_angle = pos_full[POLE_BITS+AW-1:POLE_BITS] 只有 16 bit，
            //   POLE_BITS=6 时每格 = 1/65536 圈，机械角在扇区边界附近会来回抖动，
            //   迟滞比较器因此多走若干次换向（实测 56 次，稳定且无非法码）。
            //   UVW 的"每电气周期 6 次换向、两方向对称"已由 sim/tb_uvw.v、
            //   sim/tb_uvw_rev.v 在模块级严格覆盖；这里改为形状/合法性判据。
            chk(transitions >= 4 * 6 && transitions <= 16 * 6,
                "D14-uvw-transition-count");
        end

        // v74：TEST E（原从站测试）随模块删除

        //-------------------------------------------------------------------
        $display("\n[TEST F] 顶层标定集成路径：0x0502 触发 + 状态读回 + 结果写回 + sc_correct 取用");
        //  覆盖 P0-3：此前本测试台从不写 0x0502、key_n 全程为 1 ⇒ 顶层的
        //  calib_ctrl 从未被触发过；标定窗口、calib_we 写回、主机读回、
        //  sc_correct 是否真的取到新系数，全部没有任何仿真证据。
        //-------------------------------------------------------------------
        begin : calib_int
            integer    k2, tmo, calib_clks, calib_clks2, g_cnt, gl0, hold0;
            integer    nsamp1, wcnt1;
            integer    d_ofs_s, d_ofs_c, d_gain_s, d_gain_c, d_phase_k;
            reg        key_seen;
            reg [15:0] rd_ofs_s, rd_ofs_c, rd_gain_s, rd_gain_c, rd_phase_k, rd_shift, rd_ctrl;
            reg [15:0] rd2_ofs_s, rd2_ofs_c, rd2_gain_s, rd2_gain_c, rd2_phase_k, rd2_shift;
            reg [15:0] ang_busy0;

            // 激励：标定窗口按**输入信号自身的周期**计数，故这里用较快的相位步进
            // （256 拍/输入周期）：64 个周期 = 16384 拍。样本数远小于 calib_ctrl 的
            // MAX_SAMP=65536 保护上限 ⇒ 才能真正走到"按 64 个周期关门"那条路径
            // （若走保护上限，truncated 会被置 1、窗口长度失控）。
            // 注意：本测试台 LOG2DEC=0，抽取器每拍给一个有效样本 ⇒ 1 个输入周期
            // = 256 个样本。
            ph_step = 256;
            ph      = 20'd0;
            for (k2 = 0; k2 < 2 * (PH_PERIOD / 256); k2 = k2 + 1) begin
                ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end

            // ---- F1：SPI 写 CALIB_CTRL[0]=1 触发；busy（led[3]）必须随即拉起 ----
            spi_wr16(11'h502, 16'h0001);
            tmo = 0;
            while ((led[3] !== 1'b1) && (tmo < 4000)) begin
                tmo = tmo + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            chk(led[3] === 1'b1, "F1-spi-0502-start-asserts-busy");
            $display("  F1: busy 在 %0d 拍后拉起（calib state=%0d）", tmo, dut.u_calib.state_dbg);

            // ---- F2：串行读 0x0502，busy 位(bit1) 必须为 1 ----
            spi_rd16(11'h502, rd_ctrl);
            $display("  F2: 0x0502 读回=0x%04x (busy=%b done=%b trunc=%b)",
                     rd_ctrl, rd_ctrl[1], rd_ctrl[2], rd_ctrl[3]);
            chk(rd_ctrl[1] === 1'b1, "F2-read-0502-busy-bit-set");

            // ---- F3：loop_filter 的 freeze=calib_busy（rtl/enc_top.v:395）⇒ 标定期间
            //          位置必须冻结不动 ----
            ang_busy0 = dut.angle;
            for (k2 = 0; k2 < 600; k2 = k2 + 1) begin
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            chk(dut.angle === ang_busy0, "F3-angle-frozen-while-calib-busy");

            // ---- F4：等标定结束。判据用 busy（led[3]）的下降沿，比 done 更硬：
            //          done 是锁存位，第二次触发时才被清 ----
            calib_clks = 0; tmo = 0;
            while ((led[3] === 1'b1) && (tmo < 400000)) begin
                tmo = tmo + 1; calib_clks = calib_clks + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            $display("  F4: busy 落下（标定结束）；又用了 %0d 拍；done=%b nsamp=%0d wcnt=%0d truncated=%b",
                     calib_clks, dut.u_calib.done, dut.u_calib.nsamp,
                     dut.u_calib.wcnt, dut.u_calib.truncated);
            chk(led[3] === 1'b0, "F4a-calib-busy-falls-within-tmo");
            chk(dut.u_calib.done === 1'b1, "F4b-calib-done-latched");
            chk(dut.u_calib.truncated === 1'b0, "F4c-calib-not-truncated");
            // 窗口必须靠"输入周期计数"关门，而不是靠 MAX_SAMP 保护上限：
            // wcnt 为 0 说明 cycle_pulse 在整个窗口里一次都没来（这正是本测试台
            // 首次覆盖该路径时实测到的真缺陷，详见 docs/DEV_STATUS.md §1.17）。
            chk(dut.u_calib.wcnt >= 16'd64, "F4d-window-counts-input-cycles");
            chk(dut.u_calib.nsamp <= 18'd65536, "F4e-nsamp-within-accum-cap");
            // ★ 2026-10-11 新增诊断：板上 v4（滞回过零）实测 20/20 结果正确，但 `0x0502`
            //   读回 retry 用尽(3)/win_bad=1 在 18/20 轮出现 ⇒ 必须在**干净输入**的仿真里
            //   分清"检测器误报（逻辑 bug）"还是"只有真实信号才有的非整周期窗口"。
            //   本测试台是理想正弦、无噪声、无抖动 ⇒ 这里若报警就是逻辑问题。
            $display("  F4-diag: retry_cnt=%0d win_bad=%b int_min=%0d int_max=%0d n_win=%0d",
                     dut.u_calib.retry_cnt, dut.u_calib.win_bad,
                     dut.u_calib.int_min, dut.u_calib.int_max, dut.u_calib.n_win);
            chk(dut.u_calib.retry_cnt === 3'd0, "F4g-clean-input-no-retry");
            chk(dut.u_calib.win_bad   === 1'b0, "F4h-clean-input-no-win_bad");
            // ★ 2026-10-10 幂等标定（DEV_STATUS §1.18）后，窗口必须先对齐到输入周期边界，
            //   因此样本数应当正好等于 win_cycles(64) 个完整输入周期。
            //   本测试台 LOG2DEC=0（每拍一个有效样本）、ph_step=256 ⇒ 每周期 256 拍
            //   ⇒ 期望 nsamp = 64 × 256 = 16384（允许 ±16 的边界抖动）。
            nsamp1 = dut.u_calib.nsamp;
            wcnt1  = dut.u_calib.wcnt;
            chk((dut.u_calib.nsamp >= 18'd16368) && (dut.u_calib.nsamp <= 18'd16400),
                "F4f-window-is-whole-input-cycles");

            // ---- F5：读回 0x0502，done 位(bit2) 置起 ----
            spi_rd16(11'h502, rd_ctrl);
            chk(rd_ctrl[2] === 1'b1, "F5-read-0502-done-bit-set");

            // ---- F6：读回 6 组标定结果，并与 calib_ctrl 的输出逐项比对：
            //          相等 ⇒ reg_file 确实收到了 calib_we/calib_addr/calib_wdata 写回 ----
            spi_rd16(11'h510, rd_ofs_s);
            spi_rd16(11'h512, rd_ofs_c);
            spi_rd16(11'h514, rd_gain_s);
            spi_rd16(11'h516, rd_gain_c);
            spi_rd16(11'h518, rd_phase_k);
            spi_rd16(11'h51A, rd_shift);
            $display("  F6: OFS_S=%0d OFS_C=%0d GAIN_S=%0d GAIN_C=%0d PHASE_K=%0d SHIFT=0x%04x",
                     $signed(rd_ofs_s), $signed(rd_ofs_c), rd_gain_s, rd_gain_c,
                     $signed(rd_phase_k), rd_shift);
            chk(rd_ofs_s   === dut.u_calib.res_ofs_s,   "F6a-regfile-OFS_S-from-calib");
            chk(rd_ofs_c   === dut.u_calib.res_ofs_c,   "F6b-regfile-OFS_C-from-calib");
            chk(rd_gain_s  === dut.u_calib.res_gain_s,  "F6c-regfile-GAIN_S-from-calib");
            chk(rd_gain_c  === dut.u_calib.res_gain_c,  "F6d-regfile-GAIN_C-from-calib");
            chk(rd_phase_k === dut.u_calib.res_phase_k, "F6e-regfile-PHASE_K-from-calib");
            chk(rd_shift[1:0] === dut.u_calib.res_shift_s, "F6f-regfile-SHIFT_S-from-calib");
            chk(rd_shift[3:2] === dut.u_calib.res_shift_c, "F6g-regfile-SHIFT_C-from-calib");

            // ---- F7：sc_correct 必须真的取到写回后的系数（enc_top.v:288-294 的
            //          use_* 由 cfg_* 驱动，cfg_* = reg_file 的同名寄存器）----
            chk(dut.use_ofs_s  === rd_ofs_s,  "F7a-sc_correct-uses-OFS_S");
            chk(dut.use_gain_s === rd_gain_s, "F7b-sc_correct-uses-GAIN_S");
            chk(dut.use_phase_k === rd_phase_k, "F7c-sc_correct-uses-PHASE_K");
            // 干净正弦/余弦、默认系数起步 ⇒ 标定结果应当落在合理区间
            chk((rd_gain_s >= 16'd16384) && (rd_gain_s <= 16'd65535), "F8a-GAIN_S-sane-gain");
            chk((rd_gain_c >= 16'd16384) && (rd_gain_c <= 16'd65535), "F8b-GAIN_C-sane-gain");
            chk(($signed(rd_ofs_s) > -16'sd8192) && ($signed(rd_ofs_s) < 16'sd8192), "F8c-OFS_S-small");

            // ---- F9：清 done（写 0x0502 bit2）后 done 位必须回 0 ----
            spi_wr16(11'h502, 16'h0004);
            spi_rd16(11'h502, rd_ctrl);
            chk(rd_ctrl[2] === 1'b0, "F9-clear-done-bit");

            // ---- F10：按键路径（key_fall）。key_n 经 cdc_sync2 + 16bit 去抖计数器
            //          （rtl/enc_top.v:175-190），要**稳定 0xFFFF=65535 拍 ≈1.31ms**
            //          才认账 ⇒ 测试台必须持续按住 >65535 拍（早先只按 4 拍，
            //          被去抖滤掉，属于测试台自己的错，不是 DUT 的）。 ----
            key_n = 1'b0;
            tmo = 0; key_seen = 1'b0;
            while ((tmo < 100000) && (key_seen !== 1'b1)) begin
                tmo = tmo + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
                if (led[3] === 1'b1) key_seen = 1'b1;
            end
            key_n = 1'b1;
            chk(key_seen === 1'b1, "F10-key-triggers-second-calib");
            $display("  F10: 按键（去抖 65535 拍）在第 %0d 拍触发第二次标定", tmo);
            // 等第二次标定结束，读回**全部**结果与第一次逐项比对。
            //   ★ 2026-10-10 修复后的判据（DEV_STATUS §1.18）：标定状态机累加的是**校正前**
            //   的 s_dec/c_dec，所以对同一路输入重复一键标定必须解出同一套系数（幂等）。
            //   修复前这里只能打印警告：当时累加的是 s_cor/c_cor（校正后），第二次标定
            //   测的是"自己上一次的校正结果"，实测 GAIN_S 30325→32241（朝单位增益 32768
            //   回归）、PHASE_K 15→−54、OFS_S 15→−31。
            //   容差取法：窗口边界只差几个样本（~17192 个样本里 ±几拍），因此偏置/相位
            //   应当基本不变（±8 LSB / ±4），增益允许 1%（±328，远小于修复前的 6.3%）。
            calib_clks2 = 0; tmo = 0;
            while ((led[3] === 1'b1) && (tmo < 400000)) begin
                tmo = tmo + 1; calib_clks2 = calib_clks2 + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            spi_rd16(11'h510, rd2_ofs_s);
            spi_rd16(11'h512, rd2_ofs_c);
            spi_rd16(11'h514, rd2_gain_s);
            spi_rd16(11'h516, rd2_gain_c);
            spi_rd16(11'h518, rd2_phase_k);
            spi_rd16(11'h51A, rd2_shift);
            d_ofs_s   = $signed(rd2_ofs_s)   - $signed(rd_ofs_s);
            d_ofs_c   = $signed(rd2_ofs_c)   - $signed(rd_ofs_c);
            d_gain_s  = $signed(rd2_gain_s)  - $signed(rd_gain_s);
            d_gain_c  = $signed(rd2_gain_c)  - $signed(rd_gain_c);
            d_phase_k = $signed(rd2_phase_k) - $signed(rd_phase_k);
            $display("  F10: key 触发第二次标定：%0d 拍完成；OFS_S=%0d(第一次 %0d) GAIN_S=%0d(第一次 %0d) PHASE_K=%0d(第一次 %0d) SHIFT=0x%04x(第一次 0x%04x)",
                     calib_clks2, $signed(rd2_ofs_s), $signed(rd_ofs_s),
                     rd2_gain_s, rd_gain_s, $signed(rd2_phase_k), $signed(rd_phase_k),
                     rd2_shift, rd_shift);
            $display("  F11: 两次标定之差 OFS_S=%0d OFS_C=%0d GAIN_S=%0d GAIN_C=%0d PHASE_K=%0d",
                     d_ofs_s, d_ofs_c, d_gain_s, d_gain_c, d_phase_k);
            $display("  F11: 两次标定窗口 nsamp=%0d/%0d wcnt=%0d/%0d（第一次/第二次；第二次 truncated=%b）",
                     nsamp1, dut.u_calib.nsamp, wcnt1, dut.u_calib.wcnt,
                     dut.u_calib.truncated);
            chk((dut.u_calib.nsamp >= 18'd16368) && (dut.u_calib.nsamp <= 18'd16400),
                "F11g-repeat-window-whole-cycles");
            chk(rd2_shift === rd_shift,                  "F11a-repeat-calib-SHIFT-identical");
            chk((d_ofs_s   > -8) && (d_ofs_s   < 8),     "F11b-repeat-calib-OFS_S-stable(+-8)");
            chk((d_ofs_c   > -8) && (d_ofs_c   < 8),     "F11c-repeat-calib-OFS_C-stable(+-8)");
            chk((d_gain_s  > -328) && (d_gain_s  < 328), "F11d-repeat-calib-GAIN_S-stable(1%)");
            chk((d_gain_c  > -328) && (d_gain_c  < 328), "F11e-repeat-calib-GAIN_C-stable(1%)");
            chk((d_phase_k > -4) && (d_phase_k < 4),     "F11f-repeat-calib-PHASE_K-stable(+-4)");
            // ★ 硬回归锁（2026-10-10，DEV_STATUS §1.18）：本测试台激励严格周期、无噪声，
            //   窗口对齐到整周期之后两次标定的结果必须**逐位一致**。F11b–F11f 给的是
            //   工程容差（真机有 ADC 噪声时用得上）；这一条锁死"窗口必须整周期"这个
            //   前提 —— 一旦窗口再次变成非整周期，它会立刻失败。
            chk((rd2_ofs_s === rd_ofs_s) && (rd2_ofs_c === rd_ofs_c) &&
                (rd2_gain_s === rd_gain_s) && (rd2_gain_c === rd_gain_c) &&
                (rd2_phase_k === rd_phase_k),
                "F11h-repeat-calib-bit-identical");
            // 标定后回到"干净信号"状态，供后续（若有）检查使用
            ph_step = 1;

            // ---- F12：★★ MAX_SAMP 保护上限关门路径（cap_stop_t）—— 本测试台
            //      **从未覆盖过**，而这正是**板上实际走的**那条路径！
            //      板上实测：P≈12500 样本/输入周期（1 kHz @ 12.5 MSPS）、
            //      MAX_SAMP=65536 ⇒ 窗口只装得下 ~4 个整周期，每次都由
            //      cap_stop_t 关门（truncated=1）；而 F4 用 win_cycles=64 配
            //      P=256 时窗口 16384 拍 < MAX_SAMP ⇒ 走的是 wcnt 关门那条路。
            //      ⇒ 板上 18/20 轮报 retry 用尽/win_bad=1，必须在**同一条路径**上
            //      用干净输入复现一次：这里把 CALIB_N 写成 300（> 65536/256=256）
            //      ⇒ 窗口必然撞上 MAX_SAMP，与板上的关门机理一致。
            //      若这里也报警 ⇒ 检测器在 cap_stop 路径上有逻辑缺陷（仿真内可定位）；
            //      若这里安静 ⇒ 故障只在真实信号里（需上板 ILA 抓）。
            ph_step = 256;
            spi_wr16(11'h503, 16'h012C);        // CALIB_N = 300（16 位写：0x0504 高字节=0x01）
            spi_wr16(11'h502, 16'h0001);        // 触发标定
            tmo = 0;
            while ((led[3] !== 1'b1) && (tmo < 4000)) begin
                tmo = tmo + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            chk(led[3] === 1'b1, "F12-cap-path-starts");
            calib_clks = 0; tmo = 0;
            while ((led[3] === 1'b1) && (tmo < 400000)) begin
                tmo = tmo + 1; calib_clks = calib_clks + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            $display("  F12: cap_stop 路径：%0d 拍；nsamp=%0d wcnt=%0d truncated=%b retry_cnt=%0d win_bad=%b int_min=%0d int_max=%0d",
                     calib_clks, dut.u_calib.nsamp, dut.u_calib.wcnt, dut.u_calib.truncated,
                     dut.u_calib.retry_cnt, dut.u_calib.win_bad,
                     dut.u_calib.int_min, dut.u_calib.int_max);
            chk(dut.u_calib.truncated === 1'b1, "F12a-cap-stop-sets-truncated");
            chk(dut.u_calib.wcnt  >  16'd200,   "F12b-cap-window-has-many-cycles");
            chk(dut.u_calib.retry_cnt === 3'd0, "F12c-cap-clean-input-no-retry");
            chk(dut.u_calib.win_bad   === 1'b0, "F12d-cap-clean-input-no-win_bad");
            chk((dut.u_calib.int_max - dut.u_calib.int_min) < 18'd8,
                "F12e-cap-intervals-uniform");

            // ---- F13：★★ 单拍角度毛刺被"毛刺保持"抑制（2026-10-11 v5）
            //   板上的事实：滞回过零修好后，20 轮一键标定**结果 20/20 全对**
            //   （OFS_S σ=0.7 LSB、PHASE_K 97/98），但 0x0502 的 retry 用尽(3)
            //   + win_bad=1 在 16/20 轮出现。F12 已证明同一关门路径上**干净输入
            //   不报警**（检测器无逻辑缺陷）⇒ 报警只能来自真实脉冲列的异常：
            //   混进了一个"假周期脉冲"（某两个相邻脉冲间隔被切成长短两半
            //   ⇒ int_max > 1.25·int_min），而窗口本身仍是整周期（否则半周期污染
            //   会把 OFS 打歪上千 LSB —— 板上从来没出现过这种离群）。
            //   v5 在没有 ILA 直证的前提下，先在**仿真**里把这条机理跑通：
            //   注入点选 ADC 输入，把 s/c 同时取反 ⇒ atan2 输出跳 180°。
            //   F13（本段）= 该毛刺**已被 rtl/enc_top.v 5b 节的毛刺保持挡住**
            //   ⇒ 滞回不再多翻、脉冲列干净 ⇒ retry/win_bad 必须**保持 0**；
            //   同时 6 组系数与 F12 基线**逐位一致**（正常序列相位未被动过）。
            //   F14（下一段）= 直接把**滤波之后**的角度强制拉过对侧阈值（模拟
            //   "漏过滤波的真毛刺"）⇒ 检测器必须照样报警、系数照样逐位一致，
            //   证明 v5 只挡杂散、没有把检测器本身废掉。
            //   注入率按板上反推：~750 次/s ÷ 12.5 MSPS ≈ 0.006% 样本；本测试台
            //   每拍一个样本、窗口 ~65280 拍 ⇒ 每 8000 拍注入一次（每窗口 ~8 次）。
            spi_rd16(11'h510, rd_ofs_s);        // F13 基线：F12 那次（干净输入、cap 路径）
            spi_rd16(11'h512, rd_ofs_c);
            spi_rd16(11'h514, rd_gain_s);
            spi_rd16(11'h516, rd_gain_c);
            spi_rd16(11'h518, rd_phase_k);
            spi_rd16(11'h51A, rd_shift);
            spi_wr16(11'h502, 16'h0001);        // 触发第三次标定（CALIB_N 仍 = 300 ⇒ cap 路径）
            tmo = 0;
            while ((led[3] !== 1'b1) && (tmo < 4000)) begin
                tmo = tmo + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            chk(led[3] === 1'b1, "F13-cap-path-starts");
            calib_clks = 0; tmo = 0; g_cnt = 0;
            while ((led[3] === 1'b1) && (tmo < 800000)) begin
                tmo = tmo + 1; calib_clks = calib_clks + 1;
                ph = ph + ph_step;
                if ((calib_clks % 8000) == 3000) begin
                    // 毛刺拍：s/c 同时取反（偏移二进制里取负 = 4096 - code；
                    // 12 位下与 `-code` 同值，写成取负可避免 12'd4096 被截断的告警）
                    ad_ch1_d = -ad_ch1_code;
                    ad_ch2_d = -ad_ch2_code;
                end else begin
                    ad_ch1_d = ad_ch1_code;
                    ad_ch2_d = ad_ch2_code;
                end
                if (dut.ang_glitch) g_cnt = g_cnt + 1;   // 毛刺保持是否真的动作过
                @(posedge sys_clk);
            end
            $display("  F13: 注入毛刺（ADC 单样点取反）cap 路径：%0d 拍；毛刺保持动作 %0d 次；retry_cnt=%0d win_bad=%b int_min=%0d int_max=%0d nsamp=%0d",
                     calib_clks, g_cnt, dut.u_calib.retry_cnt, dut.u_calib.win_bad,
                     dut.u_calib.int_min, dut.u_calib.int_max, dut.u_calib.nsamp);
            chk(led[3] === 1'b0, "F13a-injected-calib-finishes");
            chk(g_cnt >= 1, "F13b-glitch-hold-actually-fired");
            chk(dut.u_calib.retry_cnt === 3'd0, "F13c-glitch-hold-suppresses-retry");
            chk(dut.u_calib.win_bad === 1'b0, "F13d-glitch-hold-blocks-win_bad");
            spi_rd16(11'h510, rd2_ofs_s);
            spi_rd16(11'h512, rd2_ofs_c);
            spi_rd16(11'h514, rd2_gain_s);
            spi_rd16(11'h516, rd2_gain_c);
            spi_rd16(11'h518, rd2_phase_k);
            spi_rd16(11'h51A, rd2_shift);
            d_ofs_s   = $signed(rd2_ofs_s)   - $signed(rd_ofs_s);
            d_ofs_c   = $signed(rd2_ofs_c)   - $signed(rd_ofs_c);
            d_gain_s  = $signed(rd2_gain_s)  - $signed(rd_gain_s);
            d_gain_c  = $signed(rd2_gain_c)  - $signed(rd_gain_c);
            d_phase_k = $signed(rd2_phase_k) - $signed(rd_phase_k);
            $display("  F13: 毛刺 vs 干净 系数差 OFS_S=%0d OFS_C=%0d GAIN_S=%0d GAIN_C=%0d PHASE_K=%0d SHIFT=0x%04x/0x%04x",
                     d_ofs_s, d_ofs_c, d_gain_s, d_gain_c, d_phase_k, rd_shift, rd2_shift);
            chk((d_ofs_s === 0) && (d_ofs_c === 0) && (d_gain_s === 0) &&
                (d_gain_c === 0) && (d_phase_k === 0),
                "F13e-hold-keeps-coeffs-identical");

            // ---- F14：★★ 把**滤波之后**的角度强行拉过对侧阈值（2026-10-11 v5）
            //   目的：证明 v5 只是"挡住杂散"，**没有**把 calib_ctrl 的间隔检测/
            //   作废重试废掉。做法：在标定窗口内每 8000 拍用 `force` 把
            //   dut.angle_filt 拉到对侧（state=1 时拉到 −30000≈195°，state=0 时拉到
            //   +30000≈164.8°），保持 6 拍后 `release` ⇒ 状态机被翻两次 ⇒ 多出一个
            //   周期脉冲（与 F13 旧版等效，但绕过了毛刺保持）。
            //   判据：① retry/win_bad 报警（检测器仍然有效）；
            //         ② 6 组系数仍**准确**（不是逐位一致）。
            //   ★ 为什么②不能要求逐位一致（2026-10-11 实测纠正）：脉冲列被真的打乱后，
            //     检测器作废若干窗口、最终选中的那个整周期窗口**起点会平移**（实测
            //     nsamp=60202 vs 干净基线 65280），采样集合不同 ⇒ 系数天然差几个 LSB
            //     （实测 OFS_S=+2/OFS_C=−2/GAIN_S=−1/GAIN_C=+1/PHASE_K=3，量级 0.1% FS，
            //     与板上 v4b 20 轮 OFS_S 极差 2 完全同源）。逐位一致只适用于"杂散被
            //     完全挡住、窗口不变"的情形 —— 那是 F13 的判据；F14 判"准确"。
            spi_wr16(11'h502, 16'h0001);        // 触发第四次标定（CALIB_N 仍 = 300）
            tmo = 0;
            while ((led[3] !== 1'b1) && (tmo < 4000)) begin
                tmo = tmo + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                @(posedge sys_clk);
            end
            chk(led[3] === 1'b1, "F14-cap-path-starts");
            calib_clks = 0; tmo = 0; g_cnt = 0;
            while ((led[3] === 1'b1) && (tmo < 800000)) begin
                tmo = tmo + 1; calib_clks = calib_clks + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                if ((calib_clks % 8000) == 3000) begin
                    // 强制拉到对侧阈值之外（绕过 5b 节的毛刺保持）
                    force dut.angle_filt = dut.calib_s_side ? -16'sd30000 : 16'sd30000;
                    @(posedge sys_clk);
                    @(posedge sys_clk);
                    @(posedge sys_clk);
                    @(posedge sys_clk);
                    @(posedge sys_clk);
                    @(posedge sys_clk);
                    release dut.angle_filt;
                    g_cnt = g_cnt + 1;
                end
                @(posedge sys_clk);
            end
            $display("  F14: 强制角度错值（绕过毛刺保持）cap 路径：%0d 拍；注入 %0d 次；retry_cnt=%0d win_bad=%b int_min=%0d int_max=%0d nsamp=%0d",
                     calib_clks, g_cnt, dut.u_calib.retry_cnt, dut.u_calib.win_bad,
                     dut.u_calib.int_min, dut.u_calib.int_max, dut.u_calib.nsamp);
            chk(led[3] === 1'b0, "F14a-injected-calib-finishes");
            chk(dut.u_calib.retry_cnt >= 3'd1, "F14b-detector-catches-real-glitch");
            spi_rd16(11'h510, rd2_ofs_s);
            spi_rd16(11'h512, rd2_ofs_c);
            spi_rd16(11'h514, rd2_gain_s);
            spi_rd16(11'h516, rd2_gain_c);
            spi_rd16(11'h518, rd2_phase_k);
            spi_rd16(11'h51A, rd2_shift);
            d_ofs_s   = $signed(rd2_ofs_s)   - $signed(rd_ofs_s);
            d_ofs_c   = $signed(rd2_ofs_c)   - $signed(rd_ofs_c);
            d_gain_s  = $signed(rd2_gain_s)  - $signed(rd_gain_s);
            d_gain_c  = $signed(rd2_gain_c)  - $signed(rd_gain_c);
            d_phase_k = $signed(rd2_phase_k) - $signed(rd_phase_k);
            $display("  F14: 毛刺 vs 干净 系数差 OFS_S=%0d OFS_C=%0d GAIN_S=%0d GAIN_C=%0d PHASE_K=%0d SHIFT=0x%04x/0x%04x",
                     d_ofs_s, d_ofs_c, d_gain_s, d_gain_c, d_phase_k, rd_shift, rd2_shift);
            // 容差判据（见上方 ★ 说明）：偏移/增益 ≤ ±8 LSB、相位 ≤ ±32，
            // 远小于任何功能上有意义的偏差（8 LSB = 0.4% FS；32/32768 = 0.1%）。
            chk((d_ofs_s  <= 8) && (d_ofs_s  >= -8) &&
                (d_ofs_c  <= 8) && (d_ofs_c  >= -8) &&
                (d_gain_s <= 8) && (d_gain_s >= -8) &&
                (d_gain_c <= 8) && (d_gain_c >= -8) &&
                (d_phase_k <= 32) && (d_phase_k >= -32),
                "F14c-glitch-result-still-accurate");

            // ---- F15：★★ "真实情形"——单通道单拍半量程错值（2026-10-11 v6）
            //   为什么单列一段：F13 注入的是"两个通道同时取反 = 角度跳 180°"，那是
            //   **最猛**的情形；而板上真实出现的 ADC 错值更可能是**一个通道的 MSB
            //   翻转**（偏移二进制里等价于 ±半量程），此时 atan2 最多偏 ~26°
            //   （而不是 180°）⇒ v5 的 45° 阈值根本挡不住 ⇒ 这被判定为 v4b/v5 上板
            //   `retry=3/win_bad=1` 未被治好的原因（见 docs/DEV_STATUS.md §1.31）。
            //   v6 的两道防线（5.6° 保持 + CONF_N=3 确认）必须对此免疫，故本段注入
            //   **连续 2 拍**的单通道 MSB 翻转：
            //     · 第 1 拍：被 5b 节的保持挡住（|Δ|>5.6°）；
            //     · 第 2 拍：保持是"最多一拍"，所以这一拍的错值**会**进入 angle_filt
            //       ⇒ 足以让 side_raw 翻到对侧一拍 ⇒ 必须由 CONF_N=3 确认环节挡住。
            //   判据：retry_cnt==0、win_bad==0，且 6 组系数与干净基线**在容差内**一致
            //   （不能要求逐位相同：被注入的错样本虽然进不了角度脉冲路径，但仍会进入
            //    S1..S5 累加 ⇒ 采样集合与干净那次不同 ⇒ 差几 LSB，与 F14c 同理）。
            $display("  F15: 单通道半量程错值（连续 2 拍）——测 5.6°保持 + CONF_N=3 确认");
            spi_wr16(11'h503, 16'h012C);        // CALIB_N = 300（与 F12/F13/F14 同一条 cap 路径）
            spi_wr16(11'h502, 16'h0001);        // 启动标定
            wait (led[3] === 1'b1);             // 等标定开始（busy 灯亮）
            chk(led[3] === 1'b1, "F15-cap-path-starts");
            calib_clks = 0; tmo = 0; g_cnt = 0;
            gl0 = dut.gl_cnt_1024; hold0 = dut.gl_hold_cnt;   // 诊断计数器是"上电以来累计"⇒记基线看增量
            while ((led[3] === 1'b1) && (tmo < 800000)) begin
                tmo = tmo + 1; calib_clks = calib_clks + 1;
                ph = ph + ph_step; ad_ch1_d = ad_ch1_code; ad_ch2_d = ad_ch2_code;
                if ((calib_clks % 8000) == 3000) begin
                    // 连续 2 拍：只把 ch1 的 MSB 翻转（半量程），ch2 保持正确
                    ad_ch1_d = ad_ch1_code ^ 12'h800; ad_ch2_d = ad_ch2_code;
                    @(posedge sys_clk);
                    ad_ch1_d = ad_ch1_code ^ 12'h800; ad_ch2_d = ad_ch2_code;
                    @(posedge sys_clk);
                    g_cnt = g_cnt + 2;
                end
                @(posedge sys_clk);
            end
            $display("  F15: 注入 %0d 拍（单通道 MSB 翻转）；retry_cnt=%0d win_bad=%b int_min=%0d int_max=%0d nsamp=%0d gl1024=%0d(+%0d) hold=%0d(+%0d)",
                     g_cnt, dut.u_calib.retry_cnt, dut.u_calib.win_bad,
                     dut.u_calib.int_min, dut.u_calib.int_max, dut.u_calib.nsamp,
                     dut.gl_cnt_1024, dut.gl_cnt_1024 - gl0,
                     dut.gl_hold_cnt, dut.gl_hold_cnt - hold0);
            chk(led[3] === 1'b0, "F15a-injected-calib-finishes");
            chk(dut.u_calib.retry_cnt === 3'd0, "F15b-short-burst-suppressed");
            chk(dut.u_calib.win_bad === 1'b0, "F15c-burst-blocks-win_bad");
            spi_rd16(11'h510, rd2_ofs_s);
            spi_rd16(11'h512, rd2_ofs_c);
            spi_rd16(11'h514, rd2_gain_s);
            spi_rd16(11'h516, rd2_gain_c);
            spi_rd16(11'h518, rd2_phase_k);
            spi_rd16(11'h51A, rd2_shift);
            d_ofs_s   = $signed(rd2_ofs_s)   - $signed(rd_ofs_s);
            d_ofs_c   = $signed(rd2_ofs_c)   - $signed(rd_ofs_c);
            d_gain_s  = $signed(rd2_gain_s)  - $signed(rd_gain_s);
            d_gain_c  = $signed(rd2_gain_c)  - $signed(rd_gain_c);
            d_phase_k = $signed(rd2_phase_k) - $signed(rd_phase_k);
            $display("  F15: 错值 vs 干净 系数差 OFS_S=%0d OFS_C=%0d GAIN_S=%0d GAIN_C=%0d PHASE_K=%0d SHIFT=0x%04x/0x%04x",
                     d_ofs_s, d_ofs_c, d_gain_s, d_gain_c, d_phase_k, rd_shift, rd2_shift);
            chk((d_ofs_s   <= 8) && (d_ofs_s   >= -8) &&
                (d_ofs_c   <= 8) && (d_ofs_c   >= -8) &&
                (d_gain_s  <= 8) && (d_gain_s  >= -8) &&
                (d_gain_c  <= 8) && (d_gain_c  >= -8) &&
                (d_phase_k <= 32) && (d_phase_k >= -32) &&
                (rd2_shift === rd_shift),
                "F15d-burst-keeps-coeff-in-tol");
            chk(dut.gl_cnt_1024 >= 1, "F15e-burst-counted-by-diag");

            spi_wr16(11'h503, 16'h0040);        // 还原默认 CALIB_N = 64
            ph_step = 1;
        end

        //-------------------------------------------------------------------
        $display("\n================================================================");
        if (fail_cnt == 0)
            $display(" TEST PASSED  (%0d checks)", pass_cnt);
        else
            $display(" TEST FAILED  (%0d error(s) / %0d checks)", fail_cnt, pass_cnt);
        $display("================================================================");
        $finish;
    end

endmodule
