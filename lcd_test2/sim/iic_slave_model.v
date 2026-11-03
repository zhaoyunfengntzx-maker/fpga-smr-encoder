// =============================================================================
//  行为级 IIC 从机模型（仿真专用，不可综合）
//  ----------------------------------------------------------------------------
//  * SCL 上升沿：采样主机发来的数据位
//  * SCL 下降沿：更新从机要驱动的位（数据位 / ACK）
//  * 只监听主机侧的 scl_o / sda_o 判断 START / STOP，**不能**把从机自己的
//    驱动算进去 —— 否则从机自己发出的 ACK 会被误判成 START。
//  * sda_drv = 1 表示把 SDA 拉低（开漏），0 表示释放（高阻）。
//
//  支持的寄存器表：
//    GT911  （地址 0x5D，16bit 大端指针）0x814E status / 0x814F..0x8158 点数据
//    FT5206 （地址 0x38，8bit 指针）   0x02 status / 0x03..0x06 点数据
// =============================================================================
module iic_slave_model #(
    parameter [6:0]  SLV_ADDR  = 7'h5D,
    parameter        PRESENT   = 1,
    parameter [7:0]  GT_STATUS = 8'h02,
    parameter [7:0]  FT_STATUS = 8'h00,
    parameter [7:0]  FT_XH = 8'h00,
    parameter [7:0]  FT_XL = 8'h00,
    parameter [7:0]  FT_YH = 8'h00,
    parameter [7:0]  FT_YL = 8'h00
)(
    input  wire scl_o,
    inout  wire scl_io,
    input  wire sda_o,
    inout  wire sda_io,
    input  wire scl_oe,     // ★ 主机侧驱动（1 = 把 SCL 拉低）
    input  wire sda_oe      // ★ 主机侧驱动（1 = 把 SDA 拉低），用它判 START/STOP
);
    localparam S_IDLE = 3'd0, S_BYTE = 3'd1, S_TXDATA = 3'd2;

    reg [2:0]  st      = S_IDLE;
    reg [3:0]  bit     = 4'd0;      // 0..7 数据位；8 = 已收 8 位待应答；9 = 应答位结束
    reg [7:0]  shreg   = 8'h00;
    reg [15:0] regptr  = 16'h0000;
    reg        rw      = 1'b1;
    reg [3:0]  bytecnt = 4'd0;
    reg [7:0]  txval   = 8'h00;
    reg        sda_drv = 1'b0;
    reg        ack_seen = 1'b0;     // 主机对上一字节的应答（上升沿采样）

    assign sda_io = sda_drv ? 1'b0 : 1'bz;

    // ------------------------------------------------------------ 寄存器表
    // ★ GT911 权威寄存器布局（**每点 8 字节**，依据 GT911 Programming Guide /
    //   Linux goodix.c 的 GOODIX_CONTACT_SIZE=8 / Slint gt911 crate 的 TOUCHPOINT_ENTRY_LEN=8）：
    //     0x814E status（bit7 = 坐标就绪，低 4 位 = 点数）
    //     点 k（k=0..4）：0x814F+8k = track id，+1/+2 = X（小端），+3/+4 = Y（小端），
    //                     +5/+6 = 面积，+7 = 保留
    //   点 0: 0x814F..0x8156  点 1: 0x8157..0x815E  点 2: 0x815F..0x8166
    //   点 3: 0x8167..0x816E  点 4: 0x816F..0x8176
    // ★ 旧模型按"每点 5 字节"摆数据，等于把 RTL 的错误假设**一起验证**了：
    //   仿真一直 PASS，上板多点才全错。现在模型与真片一致，TB 才挡得住这类错。
    // 主机从 0x814E 起读 15 字（30 字节 = 状态字 + 点 0..3，点 3 的 yh=0x816B），
    // 再从 0x8170 读 2 字取点 4 的 X/Y。
    // 期望：点0(600,256) 点1(900,400) 点2(100,500) 点3(700,200) 点4(950,550)
    function [7:0] regval;
        input [15:0] a;
        begin
            case (a)
            // 产品 ID 区（0x8140 起 4 字节 = '9' '1' '1' + 版本），
            // 主机开机后读一次，用来区分"真器件在应答"与"总线被拉死读到全 0"。
            16'h8140: regval = 8'h39;                                    // '9'
            16'h8141: regval = 8'h31;                                    // '1'
            16'h8142: regval = 8'h31;                                    // '1'
            16'h8143: regval = 8'h00;
            // 固件版本 + X/Y 输出上限（0x8144 起 6 字节）。真片 7 寸 1024x600
            // 模块这里应读到 X=1024、Y=600；读到 0 说明配置没加载。
            16'h8144: regval = 8'h01;                                    // 固件版本低
            16'h8145: regval = 8'h00;                                    // 固件版本高
            16'h8146: regval = 8'h00;                                    // X 上限低 (1024=0x400)
            16'h8147: regval = 8'h04;                                    // X 上限高
            16'h8148: regval = 8'h58;                                    // Y 上限低 (600=0x258)
            16'h8149: regval = 8'h02;                                    // Y 上限高
            16'h814E: regval = GT_STATUS;
            // ---- 点 0 (600,256) ----
            16'h814F: regval = (GT_STATUS[3:0] >= 4'd1) ? 8'h01 : 8'h00;  // track id
            16'h8150: regval = (GT_STATUS[3:0] >= 4'd1) ? 8'h58 : 8'h00;  // X 低 (600=0x258)
            16'h8151: regval = (GT_STATUS[3:0] >= 4'd1) ? 8'h02 : 8'h00;  // X 高
            16'h8152: regval = (GT_STATUS[3:0] >= 4'd1) ? 8'h00 : 8'h00;  // Y 低 (256=0x100)
            16'h8153: regval = (GT_STATUS[3:0] >= 4'd1) ? 8'h01 : 8'h00;  // Y 高
            16'h8154: regval = (GT_STATUS[3:0] >= 4'd1) ? 8'h20 : 8'h00;  // 面积 低
            16'h8155: regval = 8'h00;                                     // 面积 高
            16'h8156: regval = 8'h00;                                     // 保留
            // ---- 点 1 (900,400) ----
            16'h8157: regval = (GT_STATUS[3:0] >= 4'd2) ? 8'h02 : 8'h00;  // track id
            16'h8158: regval = (GT_STATUS[3:0] >= 4'd2) ? 8'h84 : 8'h00;  // X 低 (900=0x384)
            16'h8159: regval = (GT_STATUS[3:0] >= 4'd2) ? 8'h03 : 8'h00;  // X 高
            16'h815A: regval = (GT_STATUS[3:0] >= 4'd2) ? 8'h90 : 8'h00;  // Y 低 (400=0x190)
            16'h815B: regval = (GT_STATUS[3:0] >= 4'd2) ? 8'h01 : 8'h00;  // Y 高
            16'h815C: regval = (GT_STATUS[3:0] >= 4'd2) ? 8'h20 : 8'h00;
            16'h815D: regval = 8'h00;
            16'h815E: regval = 8'h00;
            // ---- 点 2 (100,500) ----
            16'h815F: regval = (GT_STATUS[3:0] >= 4'd3) ? 8'h03 : 8'h00;  // track id
            16'h8160: regval = (GT_STATUS[3:0] >= 4'd3) ? 8'h64 : 8'h00;  // X 低 (100=0x064)
            16'h8161: regval = (GT_STATUS[3:0] >= 4'd3) ? 8'h00 : 8'h00;  // X 高
            16'h8162: regval = (GT_STATUS[3:0] >= 4'd3) ? 8'hF4 : 8'h00;  // Y 低 (500=0x1F4)
            16'h8163: regval = (GT_STATUS[3:0] >= 4'd3) ? 8'h01 : 8'h00;  // Y 高
            16'h8164: regval = (GT_STATUS[3:0] >= 4'd3) ? 8'h20 : 8'h00;
            16'h8165: regval = 8'h00;
            16'h8166: regval = 8'h00;
            // ---- 点 3 (700,200) ----
            16'h8167: regval = (GT_STATUS[3:0] >= 4'd4) ? 8'h04 : 8'h00;  // track id
            16'h8168: regval = (GT_STATUS[3:0] >= 4'd4) ? 8'hBC : 8'h00;  // X 低 (700=0x2BC)
            16'h8169: regval = (GT_STATUS[3:0] >= 4'd4) ? 8'h02 : 8'h00;  // X 高
            16'h816A: regval = (GT_STATUS[3:0] >= 4'd4) ? 8'hC8 : 8'h00;  // Y 低 (200=0x0C8)
            16'h816B: regval = (GT_STATUS[3:0] >= 4'd4) ? 8'h00 : 8'h00;  // Y 高
            16'h816C: regval = (GT_STATUS[3:0] >= 4'd4) ? 8'h20 : 8'h00;
            16'h816D: regval = 8'h00;
            16'h816E: regval = 8'h00;
            // ---- 点 4 (950,550)：由 STEP_LOOP4 从 0x8170 单读 ----
            16'h816F: regval = (GT_STATUS[3:0] >= 4'd5) ? 8'h05 : 8'h00;  // track id
            16'h8170: regval = (GT_STATUS[3:0] >= 4'd5) ? 8'hB6 : 8'h00;  // X 低 (950=0x3B6)
            16'h8171: regval = (GT_STATUS[3:0] >= 4'd5) ? 8'h03 : 8'h00;  // X 高
            16'h8172: regval = (GT_STATUS[3:0] >= 4'd5) ? 8'h26 : 8'h00;  // Y 低 (550=0x226)
            16'h8173: regval = (GT_STATUS[3:0] >= 4'd5) ? 8'h02 : 8'h00;  // Y 高
            16'h8174: regval = (GT_STATUS[3:0] >= 4'd5) ? 8'h20 : 8'h00;
            16'h8175: regval = 8'h00;
            16'h8176: regval = 8'h00;
            16'h0002: regval = FT_STATUS;
            16'h0003: regval = FT_XH;
            16'h0004: regval = FT_XL;
            16'h0005: regval = FT_YH;
            16'h0006: regval = FT_YL;
            default:  regval = 8'h00;
            endcase
        end
    endfunction

    // ---------------------------------------------------------- START / STOP
    // START：SCL 高时 SDA 下降沿；STOP：SCL 高时 SDA 上升沿。
    // ★ 必须用**主机侧的原始驱动** sda_oe / scl_oe 判定，不能用总线电平 sda_o：
    //   i2c_io_wrap 的 sda_o 是两级同步后的「总线实际电平」，把从机自己的驱动也算进去了，
    //   于是从机在读字节里释放 SDA（上升沿）会被自己误判成 STOP，整条读传输中途夭折。
    //   约定：oe = 1 表示把该线拉低。
    //   START = SCL 高时主机把 SDA 拉低；STOP = SCL 高时主机释放 SDA。
    reg sda_oe_d = 1'b0;
    always @(sda_oe) begin
        sda_oe_d <= sda_oe;
        if (scl_oe === 1'b0) begin
            if (sda_oe_d === 1'b0 && sda_oe === 1'b1) begin
                st      <= S_BYTE;
                bit     <= 4'd0;
                bytecnt <= 4'd0;
                sda_drv <= 1'b0;
            end
            else if (sda_oe_d === 1'b1 && sda_oe === 1'b0) begin
                st      <= S_IDLE;
                sda_drv <= 1'b0;
            end
        end
    end

    // ------------------------------------------------- SCL 上升沿：采数据位
    always @(posedge scl_o) begin
        if (PRESENT) begin
            if (st == S_BYTE && bit < 4'd8) begin
                shreg <= {shreg[6:0], sda_io};
                bit   <= bit + 4'd1;
            end
            // ★ 主机应答位必须在**上升沿**采样：主机在 SCL 高电平中点给出 ACK，
            //   到下降沿时可能已经释放（回到高电平），在下降沿采样会误判成 NACK。
            else if (st == S_TXDATA && bit == 4'd8) ack_seen <= ~sda_io;
        end
    end

    // ------------------------------------------------- SCL 下降沿：应答/移位
    always @(negedge scl_o) begin
        if (PRESENT) begin
            case (st)
            S_BYTE: begin
                if (bit == 4'd8) begin
                    // 8 位收完：本下降沿给出 ACK，并保持到应答位结束
                    if (bytecnt == 4'd0)
                        sda_drv <= (shreg[7:1] == SLV_ADDR) ? 1'b1 : 1'b0;
                    else
                        sda_drv <= 1'b1;               // 数据字节一律 ACK
                    bit <= 4'd9;
                end
                else if (bit == 4'd9) begin
                    // 应答位结束：释放 SDA，进入下一字节 / 读数据
                    sda_drv <= 1'b0;
                    bit     <= 4'd0;
                    if (bytecnt == 4'd0) begin
                        bytecnt <= 4'd1;
                        if (shreg[7:1] != SLV_ADDR) st <= S_IDLE;
                        else begin
                            rw <= shreg[0];
                            if (shreg[0]) begin        // 读：送第 1 个数据字节
                                txval   <= regval(regptr);
                                sda_drv <= ~regval(regptr)[7];
                                st      <= S_TXDATA;
                            end
                            else st <= S_BYTE;         // 写：继续收
                        end
                    end
                    else begin
                        bytecnt <= bytecnt + 4'd1;
                        if (rw == 1'b0) begin
                            // FT5206 是单字节寄存器地址；GT911 是 16bit 大端
                            if (SLV_ADDR == 7'h38)
                                regptr <= {8'h00, shreg};
                            else if (bytecnt == 4'd1)
                                regptr <= {shreg, regptr[7:0]};
                            else
                                regptr <= {regptr[15:8], shreg};
                        end
                    end
                end
            end
            S_TXDATA: begin
                if (bit < 4'd7) begin
                    case (bit)
                    4'd0: sda_drv <= ~txval[6];
                    4'd1: sda_drv <= ~txval[5];
                    4'd2: sda_drv <= ~txval[4];
                    4'd3: sda_drv <= ~txval[3];
                    4'd4: sda_drv <= ~txval[2];
                    4'd5: sda_drv <= ~txval[1];
                    4'd6: sda_drv <= ~txval[0];
                    default: ;
                    endcase
                    bit <= bit + 4'd1;
                end
                else if (bit == 4'd7) begin
                    sda_drv <= 1'b0;                   // 8 位发完：释放等主机 ACK
                    bit     <= 4'd8;
                end
                else begin                             // bit == 8：主机 ACK 位结束
                    if (ack_seen) begin                // 主机 ACK：送下一字节
                        regptr  <= regptr + 16'd1;
                        txval   <= regval(regptr + 16'd1);
                        sda_drv <= ~regval(regptr + 16'd1)[7];
                        bit     <= 4'd0;
                    end
                    else sda_drv <= 1'b0;              // 主机 NACK：结束
                end
            end
            default: ;
            endcase
        end
    end

endmodule
