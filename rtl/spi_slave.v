// ============================================================================
//  spi_slave.v  ——  配置用 SPI 从站 (模式 0 / CPOL=0 / CPHA=0 / MSB 先)
// ----------------------------------------------------------------------------
//  功能
//    · 异步 sck/ssi/ss_n 输入，全部在 clk_sys 域内两级同步 + 边沿检测实现，
//      不引入新时钟域（与契约 0.3 的异步输入处理方式一致）。
//    · ssi 在 sck 上升沿采样；sso 在 sck 下降沿更新（CPHA=0 的标准行为）。
//    · 两种协议由参数 USE_TW28_PACKET 选择：
//
//    (A) USE_TW28_PACKET = 0 —— 简单字节模式（默认，便于上位机调试）
//        一次传输 = 2 字节：byte0 = {rw, addr[6:0]}，byte1 = data[7:0]
//            rw = 1 -> 读（不产生写操作）；rw = 0 -> 写
//        输出 addr = {8'h00, 1'b0, byte0[6:0]}（16 位地址空间的 0x00..0x7F）
//        sso 时序：
//            byte0 期间 -> 返回**上一拍**读到的数据（契约 1.11 "读时返回上一拍
//                          读数据"）
//            byte1 期间 -> 返回**本拍地址**对应的数据（同一帧即可读回，便于调试）
//        注意：受 7 位地址限制，简单模式只能访问 0x00..0x7F；0x5xxx/0xE000
//        扩展寄存器请用 (B) 包模式。reg_file 在 0x7E/0x7F 放了 DEVICE_ID/REV
//        别名，使简单模式也能做器件识别。
//        写操作时 byte0 期间返回的是"写前值"。
//
//    (B) USE_TW28_PACKET = 1 —— TW28 风格 32 位命令/响应包
//        命令包(MSB 先)：
//            bit31    st  = 1（必须为 1，否则忽略该包）
//            bit30:29 rm  读模式（0=位置/状态 1=捕获 2=ADC 3=寄存器；本设计统一
//                         按"寄存器读"处理；位置请读 0x0536..0x0539）
//            bit28:27 wm  写模式（0=空写 1/3=寄存器写）
//            bit26:24 page 地址高 3 位 addr[10:8]（TW28 中为保留位，本设计用作
//                         扩展，使 0x5xx/0x6xx 可达）
//            bit23:16 addr[7:0] 寄存器地址（16 位地址 = {5'b0, page, addr[7:0]}）
//            bit15:0  data[15:0] 写数据（低字节写 addr，高字节写 addr+1）
//        响应包在**下一帧**移出（TW28 重叠式：命令 N 的响应在命令 N+1 期间返回）：
//            bit31:24 状态字节 = {page, 8'h3A} 的读值（扩展页 5 -> 0x053A stat_flags）
//            bit23:16 addr[7:0] 回显
//            bit15:8  寄存器 addr+1
//            bit7:0   寄存器 addr
//        写操作在 ss_n 上升沿后 2 拍内完成两次字节写（addr 与 addr+1）。
//
//  Latency / 最大 sck
//    sck 真实上升沿 -> we/addr 有效：≤ 3 个 clk_sys（两级同步 + 1 拍寄存器）。
//    可靠边沿检测要求每个 sck 周期 ≥ 4 个 clk_sys（25 ns @100 MHz），即
//    sck ≤ 12.5 MHz 为绝对上限；建议 ≤ 10 MHz（10 倍过采样，余量充足）。
//    TW28 数据手册允许 20 MHz，但本设计按契约 0.3 用 clk_sys 过采样实现，
//    故把上限明确写为 10 MHz（推荐）/ 12.5 MHz（极限）。
//
//  资源估计
//    FF ≈ 110（同步器 5、输入移位 32、输出移位 32、计数器、包序列器）
//    LUT ≈ 120；无 DSP/BRAM。
//
//  关键假设
//    1) 一次 SS 低电平期间恰好 16（简单模式）或 32（包模式）个 sck 上升沿。
//    2) ssi 在 sck 下降沿变化、上升沿稳定（标准 SPI 从机侧时序）。
//    3) 读数据 rdata 为**组合**输出（reg_file 地址译码），addr 稳定后同拍有效。
//    4) 参数 AW 默认 16（契约片段写 8）；reg_file 需要 16 位地址空间才能覆盖
//       0x0100/0x05xx/0xE000。若必须严格按契约的 AW=8，把 AW 改为 8 即可，
//       此时只有地址低 8 位可用（简单模式不受影响，包模式只能访问低 bank）。
// ============================================================================

module spi_slave #(
    parameter integer AW              = 16,  // 地址位宽(契约默认 8，见假设 4)
    parameter integer DW              = 8,   // 数据位宽
    parameter integer USE_TW28_PACKET = 0    // 0=简单 2 字节模式，1=32 位包模式
)(
    input  wire          clk,               // clk_sys 100 MHz
    input  wire          rst_n,             // 同步复位，低有效
    input  wire          sck,               // SPI 时钟（异步输入）
    input  wire          ssi,               // MOSI（异步输入）
    input  wire          ss_n,              // 片选，低有效（异步输入）
    output reg           sso,               // MISO
    output reg [AW-1:0]  addr,              // 寄存器地址
    output reg [DW-1:0]  wdata,             // 写数据
    output reg           we,                // 写使能（1 拍脉冲）
    input  wire [DW-1:0] rdata              // 读数据（组合）
);

    localparam integer PKT = (USE_TW28_PACKET != 0) ? 1 : 0;
    localparam [5:0]   NCLK_MAX = (PKT != 0) ? 6'd32 : 6'd16;   // 一帧 sck 上升沿数

    // ------------------------------------------------------------------
    // 1) 输入同步 + 边沿检测
    // ------------------------------------------------------------------
    reg sck_s1, sck_s2, sck_s3;
    reg ssn_s1, ssn_s2, ssn_s3;
    reg ssi_s1, ssi_s2;

    always @(posedge clk) begin
        if (!rst_n) begin
            sck_s1 <= 1'b0; sck_s2 <= 1'b0; sck_s3 <= 1'b0;   // sck 空闲低
            ssn_s1 <= 1'b1; ssn_s2 <= 1'b1; ssn_s3 <= 1'b1;   // ss_n 空闲高
            ssi_s1 <= 1'b0; ssi_s2 <= 1'b0;
        end else begin
            sck_s1 <= sck;   sck_s2 <= sck_s1;   sck_s3 <= sck_s2;
            ssn_s1 <= ss_n;  ssn_s2 <= ssn_s1;   ssn_s3 <= ssn_s2;
            ssi_s1 <= ssi;   ssi_s2 <= ssi_s1;
        end
    end

    wire sck_rise =  sck_s2 & ~sck_s3;     // sck 上升沿（采样沿）
    wire sck_fall = ~sck_s2 & sck_s3;      // sck 下降沿（更新 sso）
    // 注意：ssn_s3 是 ssn_s2 延迟 1 拍，故 "s & ~s3" 检出的是**上升**沿。
    // ss_n 低有效：下降沿 = 片选选中（本帧开始），上升沿 = 片选释放（本帧结束，
    // 命令生效）。原来的两式写反了，导致包模式在**帧开始时**（sr 已被清零）解析
    // 命令，sr[31] 恒为 0，所有命令被忽略。极性与 sck_rise/sck_fall 保持一致。
    wire ss_fall  = ~ssn_s2 & ssn_s3;      // 片选选中（ss_n 下降沿，帧开始）
    wire ss_rise  =  ssn_s2 & ~ssn_s3;     // 片选释放 -> 命令生效（帧结束）

    // ------------------------------------------------------------------
    // 2) 位计数 / 输入移位 / 输出移位
    // ------------------------------------------------------------------
    // 注意：Verilog 要求标识符"先声明后使用"，下面的 resp 在片选下降沿
    //       装载逻辑里被引用，因此必须在那个 always 块之前声明。
    reg [31:0] resp;         // 响应寄存器
    reg [2:0]  pst;          // 包序列器
    reg [15:0] cmd_addr;     // {page, addr[7:0]}
    reg [15:0] cmd_data;
    reg [7:0]  rd_lo, rd_hi;

    reg [5:0]  bit_cnt;      // 已收到的 sck 上升沿数
    reg [31:0] sr;           // 输入移位寄存器（MSB 先）
    reg [31:0] osr;          // 输出移位寄存器
    reg [7:0]  rd_hold;      // 上一帧读回的数据（简单模式 byte0 期间输出）
    reg [7:0]  bw_rw;        // 简单模式：byte0 的 bit7 = R/W#

    wire [31:0] sr_next = {sr[30:0], ssi_s2};   // 本次上升沿之后的移位值

    always @(posedge clk) begin
        if (!rst_n) begin
            bit_cnt <= 6'd0;
            sr      <= 32'd0;
            osr     <= 32'd0;
            rd_hold <= 8'h00;
            bw_rw   <= 8'h00;
            sso     <= 1'b0;
        end else begin
            // ---- 片选下降沿：开始一次传输 ----
            if (ss_fall) begin
                bit_cnt <= 6'd0;
                sr      <= 32'd0;
                if (PKT != 0) begin
                    osr <= resp;
                    sso <= resp[31];            // 上一帧组好的响应，MSB 先
                end else begin
                    osr <= {24'd0, rd_hold};
                    sso <= rd_hold[7];          // 上一拍读数据，MSB 先
                end
            end
            // ---- 采样沿：移入一位 ----
            if (sck_rise && (bit_cnt < NCLK_MAX)) begin
                sr      <= sr_next;
                bit_cnt <= bit_cnt + 6'd1;
            end
            // ---- 更新沿：准备下一位 / 装载本帧读数据 ----
            if (sck_fall) begin
                if (PKT != 0) begin
                    if ((bit_cnt >= 6'd1) && (bit_cnt <= 6'd31)) begin
                        sso <= osr[30];
                        osr <= {osr[30:0], 1'b0};
                    end
                end else begin
                    if (bit_cnt == 6'd8) begin
                        osr <= {24'd0, rdata};  // 地址字节结束，装载本帧读数据
                        sso <= rdata[7];
                    end else if (((bit_cnt >= 6'd1) && (bit_cnt <= 6'd7)) ||
                                 ((bit_cnt >= 6'd9) && (bit_cnt <= 6'd15))) begin
                        sso <= osr[6];
                        osr <= {osr[6:0], 1'b0};
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 3) 32 位包模式：命令解析 + 响应组装（命令 N 的响应在 N+1 帧移出）
    //    （resp / pst / cmd_addr / cmd_data / rd_lo / rd_hi 已在第 2 节前声明）
    // ------------------------------------------------------------------
    localparam [2:0] P_IDLE = 3'd0,
                     P_RD0  = 3'd1,
                     P_RD1  = 3'd2,
                     P_RD2  = 3'd3,
                     P_RD3  = 3'd4,
                     P_WR0  = 3'd5,
                     P_WR1  = 3'd6;

    // ------------------------------------------------------------------
    // 4) 地址 / 写数据 / 写使能（单一 always 块，避免多驱动）
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            addr     <= {AW{1'b0}};
            wdata    <= {DW{1'b0}};
            we       <= 1'b0;
            resp     <= 32'd0;
            pst      <= P_IDLE;
            cmd_addr <= 16'd0;
            cmd_data <= 16'd0;
            rd_lo    <= 8'h00;
            rd_hi    <= 8'h00;
        end else begin
            we <= 1'b0;                        // 写脉冲默认拉低

            if (PKT == 0) begin
                // ---------------- 简单字节模式 ----------------
                if (sck_rise && (bit_cnt == 6'd7)) begin
                    // 第 8 个上升沿：地址字节到齐（sr_next[7:0] = byte0）
                    bw_rw <= {7'd0, sr_next[7]};
                    addr  <= {9'd0, sr_next[6:0]};
                end
                if (sck_rise && (bit_cnt == 6'd15)) begin
                    // 第 16 个上升沿：数据字节到齐（sr_next[7:0] = byte1）
                    if (bw_rw[0] == 1'b0) begin
                        we    <= 1'b1;         // rw=0 -> 写
                        wdata <= sr_next[7:0];
                    end
                    rd_hold <= rdata;          // 供下一帧 byte0 期间输出
                end
            end else begin
                // ---------------- 32 位包模式 ----------------
                if (ss_rise) begin
                    if (sr[31] == 1'b1) begin          // st 必须为 1
                        cmd_addr <= {5'd0, sr[26:24], sr[23:16]};
                        cmd_data <= sr[15:0];
                        if ((sr[28:27] != 2'b00) && (sr[30:29] != 2'b11)) begin
                            pst <= P_WR0;              // 寄存器写
                        end else begin
                            pst <= P_RD0;              // 寄存器读（含 rm=0/1/2）
                        end
                    end
                end else begin
                    // 注意：必须用 else 与上面的 ss_rise 互斥，否则同一拍里
                    // case 的 default 会把刚写入的 pst 又覆盖回 P_IDLE。
                    case (pst)
                    P_RD0: begin addr  <= {5'd0, cmd_addr[10:0]};
                                 pst   <= P_RD1;                          end
                    P_RD1: begin rd_lo <= rdata;
                                 addr  <= {5'd0, cmd_addr[10:0]} + 16'd1;
                                 pst   <= P_RD2;                          end
                    P_RD2: begin rd_hi <= rdata;
                                 addr  <= {5'd0, cmd_addr[10:8], 8'h3A};
                                 pst   <= P_RD3;                          end
                    P_RD3: begin resp  <= {rdata, cmd_addr[7:0], rd_hi, rd_lo};
                                 pst   <= P_IDLE;                         end
                    P_WR0: begin addr  <= {5'd0, cmd_addr[10:0]};
                                 wdata <= cmd_data[7:0];
                                 we    <= 1'b1;
                                 pst   <= P_WR1;                          end
                    P_WR1: begin addr  <= {5'd0, cmd_addr[10:0]} + 16'd1;
                                 wdata <= cmd_data[15:8];
                                 we    <= 1'b1;
                                 pst   <= P_IDLE;                         end
                    default: pst <= P_IDLE;
                    endcase
                end
            end
        end
    end

endmodule
