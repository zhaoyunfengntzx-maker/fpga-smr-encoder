//=============================================================================
//  uart_scope.v —— 上位机遥测数据泵（UART 发送 + 定周期组帧）
//-----------------------------------------------------------------------------
//  功能
//    以固定周期把角度、校正后的 sin/cos、ABZ/UVW 逻辑电平快照、完整位置、
//    状态字节打成 18 字节定长帧，从 UART 连续发出，供 PC 端 Python 脚本实时画
//    「李萨如图 + 角度误差曲线 + 时间波形 + ABZ/UVW 逻辑波形」。
//
//  帧格式（共 18 字节，小端字段按大端序发送，便于 PC 端解析）
//    off  len  内容
//     0    1   0xAA   帧头 1
//     1    1   0x55   帧头 2
//     2    2   angle[15:0]      （16bit 电角度，0..65535 对应 0..360°）
//     4    2   s_n[15:0]        （校正后正弦，Q1.15，有符号）
//     6    2   c_n[15:0]        （校正后余弦，Q1.15，有符号）
//     8    1   io_state[7:0]    （ABZ/UVW 逻辑电平快照 + 方向 + 限频标志）
//     9    1   0xA2            （IO 帧标记 = FRAME_TAG_IO，见下面的「帧布局 v2」）
//    10    1   io_flags[7:0]    （告警 / 输出使能位）
//    11    1   0x00            （保留，恒 0；将来加位不再改帧长）
//    12    4   pos_full[31:0]   （多周期计数<<16 | 角度）
//    16    1   stat[7:0]        （统一状态位：oflow/falarm/laglim/...）
//    17    1   XOR 校验（对 off 2..16 逐字节异或，并含两个帧头常量）
//
//  ★ 帧布局 v2（2026-10-12 起，RTL_BUILD_ID = 0x000C / v12）
//    原 off8..11 是 amp_sq[31:0]（= s²+c²）。amp_sq 是送进来的 s_n/c_n 的
//    **确定函数**（s_cor/c_cor 先平方求和，见 rtl/amp_monitor.v），上位机可以
//    逐帧无损重算 ⇒ 把这 4 个字节挪作他用不丢任何信息。腾出的位置放
//    「ABZ/UVW 实时电平快照」，于是上位机能从串口流里直接看 ABZ/UVW 逻辑波形：
//    帧长仍是 18 字节 ⇒ 链路占用、帧率、UART→SPI 桥的 TX 仲裁全部不变。
//    旧版 off9 = amp_sq[23:16] ≤ 0x80（amp_sq < 2^31），**不可能**等于 0xA2，
//    因此 off9 的标记字节让上位机逐帧识别布局版本（还兼容"v11 旧位流"）：
//      io_state: bit0 a_out   bit1 b_out   bit2 z_out   bit3 u_out
//                bit4 v_out   bit5 w_out   bit6 dir     bit7 limiter_active
//      io_flags: bit0 lag_warn bit1 lag_fatal bit2 z_window bit3 uvw_freq_warn
//                bit4 cfg_abzen bit5 cfg_uwven bit6 cor_sat bit7 (amp_low|amp_high)
//    注意 io_state 只是**采样时刻的电平**（每帧一个点，10 kHz），不是连续
//    波形：要量 Z 脉宽/UVW 相位这类 ns 级细节仍应用示波器直接探排针。
//
//  吞吐量估算
//    BAUD = 2 Mbaud 时，18 字节 = 180 bit ≈ 90 µs，即最高约 11 kHz 帧率；
//    SAMPLE_DIV 默认 5000（50 MHz / 5000 = 10 kHz 采样率）→ 帧率 10 kHz，
//    对应 1 kHz 的输入信号每秒 10 个点。若要更密的波形，把 BAUD_DIV 调小
//    （提高波特率）或把 SAMPLE_DIV 调小（提高采样率）。
//
//  为什么不用 MicroBlaze
//    纯 RTL 数据泵只需约 150 个 LUT/FF，零 IP、零软件，30 天周期内风险最低。
//    MicroBlaze 版本作为加分项放在后面做（见 docs/02 创新点 8）。
//
//  Latency：无（连续工作）
//=============================================================================
`timescale 1ns / 1ps

//-----------------------------------------------------------------------------
//  uart_tx —— 极简 8N1 UART 发送器，1 字节 / 次，start 为单周期脉冲
//-----------------------------------------------------------------------------
module uart_tx #(
    parameter integer BAUD_DIV = 25      // = CLK_HZ / BAUD，50MHz/2Mbaud = 25
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_start,          // 单周期脉冲；busy=1 时请勿给
    output reg        tx,
    output reg        busy
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bidx;
    reg [7:0]  sh;

    always @(posedge clk) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            tx   <= 1'b1;
            busy <= 1'b0;
            cnt  <= 16'd0;
            bidx <= 3'd0;
            sh   <= 8'd0;
        end
        else begin
            case (st)
                S_IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    if (tx_start) begin
                        sh   <= tx_data;
                        st   <= S_START;
                        cnt  <= 16'd0;
                        busy <= 1'b1;
                        tx   <= 1'b0;         // 起始位
                    end
                end
                S_START: begin
                    tx <= 1'b0;
                    if (cnt == BAUD_DIV - 1) begin
                        cnt  <= 16'd0;
                        st   <= S_DATA;
                        bidx <= 3'd0;
                        tx   <= sh[0];        // 数据位 0（LSB 先发）
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_DATA: begin
                    if (cnt == BAUD_DIV - 1) begin
                        cnt <= 16'd0;
                        if (bidx == 3'd7) begin
                            st <= S_STOP;
                            tx <= 1'b1;       // 停止位
                        end
                        else begin
                            bidx <= bidx + 1'b1;
                            tx   <= sh[bidx + 1'b1];
                        end
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_STOP: begin
                    tx <= 1'b1;
                    if (cnt == BAUD_DIV - 1) begin
                        cnt  <= 16'd0;
                        st   <= S_IDLE;
                        busy <= 1'b0;
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule


//-----------------------------------------------------------------------------
//  uart_scope —— 定周期打帧的遥测数据泵
//-----------------------------------------------------------------------------
module uart_scope #(
    parameter integer BAUD_DIV   = 25,       // 50MHz / 2Mbaud
    parameter integer SAMPLE_DIV = 5000      // 50MHz / 5000 = 10kHz 采样率
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,                   // 0 = 停发
    input  wire        hold,                 // 1 = 本拍不要**启动新帧**
                                             //     （UART→SPI 桥要占用 TX 发应答）
    // ---- 遥测数据 ----
    input  wire [15:0] angle,
    input  wire signed [15:0] s_n,
    input  wire signed [15:0] c_n,
    input  wire [7:0]  io_state,              // {limiter_active,dir,w,v,u,z,b,a}
    input  wire [7:0]  io_flags,              // {amp_bad,cor_sat,uwven,abzen,uvw_fw,zwin,lagf,lagw}
    input  wire [31:0] pos_full,
    input  wire [7:0]  stat,
    // ---- 输出 ----
    output wire        tx,
    output wire        tx_idle,              // 行空闲：可以安全把发送权让给桥
    output reg  [15:0] frame_cnt             // 已发送帧数（调试用）
);

    //--------------------------------------------------------------------
    // 采样节拍
    //--------------------------------------------------------------------
    reg [31:0] div_cnt;
    reg        latch;
    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt <= 32'd0;
            latch   <= 1'b0;
        end
        else if (!en) begin
            div_cnt <= 32'd0;
            latch   <= 1'b0;
        end
        else if (div_cnt == SAMPLE_DIV - 1) begin
            div_cnt <= 32'd0;
            latch   <= 1'b1;
        end
        else begin
            div_cnt <= div_cnt + 1'b1;
            latch   <= 1'b0;
        end
    end

    //--------------------------------------------------------------------
    // 锁存遥测数据（保证一帧内数据一致）
    //--------------------------------------------------------------------
    //  ★ 帧布局 v2：off9 是 IO 帧标记常量（= FRAME_TAG_IO 0xA2），off11 保留恒 0。
    //    两者都参与 XOR 校验，所以校验和里也要把它们（以及 io_state/io_flags）
    //    异或进去 —— 少异或一个字节，上位机每一帧都会被判 crc_err。
    localparam [7:0] FRAME_TAG_IO = 8'hA2;   // 旧版此处 = amp_sq[23:16] ≤ 0x80，不会撞车
    localparam [7:0] FRAME_RESV   = 8'h00;

    reg [15:0] l_angle, l_s, l_c;
    reg [7:0]  l_io, l_flag;
    reg [31:0] l_pos;
    reg [7:0]  l_stat, l_chk;

    always @(posedge clk) begin
        if (latch) begin
            l_angle <= angle;
            l_s     <= s_n;
            l_c     <= c_n;
            l_io    <= io_state;
            l_flag  <= io_flags;
            l_pos   <= pos_full;
            l_stat  <= stat;
            l_chk   <= 8'hAA ^ 8'h55
                     ^ angle[15:8] ^ angle[7:0]
                     ^ s_n[15:8]   ^ s_n[7:0]
                     ^ c_n[15:8]   ^ c_n[7:0]
                     ^ io_state ^ FRAME_TAG_IO ^ io_flags ^ FRAME_RESV
                     ^ pos_full[31:24] ^ pos_full[23:16]
                     ^ pos_full[15:8]  ^ pos_full[7:0]
                     ^ stat;
        end
    end

    //--------------------------------------------------------------------
    // 组帧状态机：等采样节拍 -> 连续发 18 字节
    //   注意：tx_data_r 必须【寄存】后再与 tx_start 一起送给 uart_tx，
    //   否则在"请求发送"的那一拍 sel 已经自增，会发错字节。
    //--------------------------------------------------------------------
    localparam [7:0] FRAME_LAST = 8'd17;     // 0..17 共 18 字节

    reg [7:0]  sel;                          // 当前要发的字节序号
    reg [7:0]  tx_data_r;                    // 寄存后的待发字节
    reg        tx_start;
    reg        sending;
    reg        snd_go;                       // 发过 tx_start 后的强制间隔拍
    wire       tx_busy;

    // 按字节序号选择字节内容（纯组合，送入 tx_data_r）
    function [7:0] frame_byte;
        input [7:0] idx;
        begin
            case (idx)
                8'd0:    frame_byte = 8'hAA;
                8'd1:    frame_byte = 8'h55;
                8'd2:    frame_byte = l_angle[15:8];
                8'd3:    frame_byte = l_angle[7:0];
                8'd4:    frame_byte = l_s[15:8];
                8'd5:    frame_byte = l_s[7:0];
                8'd6:    frame_byte = l_c[15:8];
                8'd7:    frame_byte = l_c[7:0];
                8'd8:    frame_byte = l_io;
                8'd9:    frame_byte = FRAME_TAG_IO;
                8'd10:   frame_byte = l_flag;
                8'd11:   frame_byte = FRAME_RESV;
                8'd12:   frame_byte = l_pos[31:24];
                8'd13:   frame_byte = l_pos[23:16];
                8'd14:   frame_byte = l_pos[15:8];
                8'd15:   frame_byte = l_pos[7:0];
                8'd16:   frame_byte = l_stat;
                default: frame_byte = l_chk;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            sel       <= 8'd0;
            tx_data_r <= 8'd0;
            tx_start  <= 1'b0;
            sending   <= 1'b0;
            snd_go    <= 1'b0;
            frame_cnt <= 16'd0;
        end
        else if (!en) begin
            sel       <= 8'd0;
            tx_start  <= 1'b0;
            sending   <= 1'b0;
            snd_go    <= 1'b0;
        end
        else begin
            tx_start <= 1'b0;                // 默认拉低，只发单周期脉冲
            if (!sending) snd_go <= 1'b0;
            //  ★★ 组帧 FSM 必须"发一拍、等一拍"，不能只看 !tx_busy。
            //    uart_tx 的 busy 是在 stop 位开始的同一拍才拉低，而 tx_start
            //    是寄存输出：若在 busy 刚拉低那一拍就再发一个 tx_start，
            //    下一个周期 busy 仍为 0（uart_tx 要到再下一拍才置 busy），
            //    于是 FSM 会**连发两个 tx_start**。第一个被 uart_tx 接受，
            //    第二个把 tx_data_r（此时已换成下一字节）一起吞掉 ——
            //    实测每字节都丢掉一个字节，整帧只剩 AA 12 0F ... 这类
            //    "隔一个取一个"的序列，帧头后的字段全部错位、XOR 必然不符，
            //    上位机永远解析不出合法帧。
            //    加入 snd_go：发出 tx_start 的下一拍强制歇一拍。
            if (!sending) begin
                // hold=1 时**不启动新帧**（正在发的那一帧一定会发完，不做中途打断）。
                // 桥只在 tx_idle=1（帧间、uart_tx 空闲、线为高）时拉 hold/抢 TX，
                // 因此这里不会出现"半个字节"被截断的情况。
                if (latch && !hold) begin    // 与采样节拍对齐后启动一帧
                    sending <= 1'b1;
                    snd_go  <= 1'b1;
                    sel     <= 8'd0;
                end
            end
            else if (snd_go) begin           // 启动/上一个字节后的强制间隔拍
                snd_go <= 1'b0;
            end
            else if (!tx_busy) begin         // 字节发完，准备下一个
                tx_data_r <= frame_byte(sel);
                tx_start  <= 1'b1;
                snd_go    <= 1'b1;
                if (sel == FRAME_LAST) begin
                    sel       <= 8'd0;
                    sending   <= 1'b0;
                    frame_cnt <= frame_cnt + 1'b1;
                end
                else begin
                    sel <= sel + 1'b1;
                end
            end
        end
    end

    uart_tx #(
        .BAUD_DIV (BAUD_DIV)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data_r),
        .tx_start (tx_start),
        .tx       (tx),
        .busy     (tx_busy)
    );

    //--------------------------------------------------------------------
    // 行空闲指示（给 UART→SPI 桥做 TX 仲裁用）
    //   条件：没在组帧、uart_tx 不忙、没有待发脉冲/强制间隔拍。
    //   uart_tx 在空闲与 stop 位都把 tx 驱动为高，所以 tx_idle=1 时把发送权
    //   让出去，线上不会出现半个字节。
    //--------------------------------------------------------------------
    assign tx_idle = !sending && !tx_busy && !snd_go && !tx_start;

endmodule
