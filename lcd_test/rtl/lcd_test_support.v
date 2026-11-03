// =============================================================================
//  lcd_test/rtl/lcd_test_support.v
//  屏幕+触控测试程序的辅助模块集合（自包含，不依赖现有编码器工程的任何文件）：
//    1) lcd_rst_sync       上电复位 + 按键复位（异步置位、同步释放）
//    2) key_debounce       按键消抖 + 边沿/长按输出（按下为低）
//    3) lcd_panel_id_read  三根 ID 引脚（R7/G7/B7）上电读取并锁存
//    4) i2c_io_wrap        IIC 开漏双向引脚（IOBUF + 输入同步打拍）
//    5) uart_tx_byte       UART 字节发送（可参数化波特率）
//
//  为什么单独放一个文件而不是各模块一个文件：这五个模块都只有几十行且只服务于
//  本测试程序，合并后审阅与 lint 都更省事；真正的功能模块（时序/画面/IIC/触控）
//  仍然各自独立成文件。
// =============================================================================
`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// 1) 上电/按键复位
//    上电计数约 2^19 拍（50MHz => 10.5ms）后才释放 rst_n，保证 LCD 内部复位完成；
//    按住按键（key_n=0）时也输出复位。
//    ★ cnt/cnt_done/rst_r 必须带初值：真实器件靠 GSR 上电清零，而仿真里没有 GSR，
//      若在声明时不赋初值，且 key_n 上电就是 1（没有 negedge 事件），这三个寄存器会
//      永远停在 X，整个 DUT 也会全 X（集成测试台就卡在这里）。
// -----------------------------------------------------------------------------
module lcd_rst_sync #(
    parameter [18:0] POR_CYCLES = 19'd524287
)(
    input  wire clk,
    input  wire key_n,        // 板载按键，按下为 0
    output wire rst_n
);
    reg [18:0] cnt      = 19'd0;
    reg        cnt_done = 1'b0;
    reg        rst_r    = 1'b0;

    assign rst_n = rst_r;

    always @(posedge clk or negedge key_n) begin
        if (!key_n) begin
            cnt      <= 19'd0;
            cnt_done <= 1'b0;
            rst_r    <= 1'b0;
        end
        else begin
            if (!cnt_done) begin
                if (cnt == POR_CYCLES) cnt_done <= 1'b1;
                else                   cnt <= cnt + 19'd1;
            end
            rst_r <= cnt_done;
        end
    end
endmodule

// -----------------------------------------------------------------------------
// 2) 按键消抖
//    50MHz 下 20bit 计数 => 约 21ms 稳定才认。输出 press（单周期，按下时 1 个脉冲）
//    供"切画面"用；按住 ~0.6s 再给 long_press（可用于一键全屏复位/回画面 0）。
// -----------------------------------------------------------------------------
module key_debounce #(
    parameter [19:0] DB_CYCLES   = 20'd1_048_575,   // ~21ms
    parameter [24:0] HOLD_CYCLES = 25'd30_000_000   // ~0.6s
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,        // 原始按键，按下为 0

    output reg  key_state,    // 消抖后的电平（按下为 0）
    output reg  press,        // 按下沿，单周期
    output reg  release_evt,  // 释放沿，单周期
    output reg  long_press    // 按住超过 HOLD_CYCLES，单周期
);
    reg [1:0]  sync;
    reg [19:0] db_cnt;
    reg        key_prev;
    reg [24:0] hold_cnt;
    reg        hold_fired;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync       <= 2'b11;
            db_cnt     <= 20'd0;
            key_state  <= 1'b1;
            key_prev   <= 1'b1;
            press      <= 1'b0;
            release_evt <= 1'b0;
            hold_cnt   <= 25'd0;
            hold_fired <= 1'b0;
            long_press <= 1'b0;
        end
        else begin
            sync <= {sync[0], key_n};

            press      <= 1'b0;
            release_evt <= 1'b0;
            long_press <= 1'b0;

            if (sync[1] != key_state) begin
                if (db_cnt == DB_CYCLES) begin
                    db_cnt    <= 20'd0;
                    key_state <= sync[1];
                    if (key_prev && !sync[1]) begin
                        press      <= 1'b1;
                        hold_cnt   <= 25'd0;
                        hold_fired <= 1'b0;
                    end
                    else if (!key_prev && sync[1]) begin
                        release_evt <= 1'b1;
                    end
                    key_prev <= sync[1];
                end
                else db_cnt <= db_cnt + 20'd1;
            end
            else db_cnt <= 20'd0;

            // 长按检测（消抖后的电平）
            if (!key_state) begin
                if (!hold_fired) begin
                    if (hold_cnt >= HOLD_CYCLES) begin
                        hold_fired <= 1'b1;
                        long_press <= 1'b1;
                    end
                    else hold_cnt <= hold_cnt + 25'd1;
                end
            end
            else begin
                hold_cnt   <= 25'd0;
                hold_fired <= 1'b0;
            end
        end
    end
endmodule

// -----------------------------------------------------------------------------
// 3) 屏 ID 读取
//    lcd_rgb 的 3 根线（低 8 位的 bit7 / 中 8 位 bit7 / 高 8 位 bit7）在模块上被
//    ID 电阻分压，只有在 FPGA 把 24 根数据线全部置高阻时才能读。因此上电后先让
//    数据线呈高阻把 ID 读进来并锁存，之后才切到"驱动像素"模式。
//
//    读窗口给 2^21 拍（50MHz => 42ms）：足够等 LCD 模块上电稳定、又远小于人眼
//    能感知"屏幕没反应"的时间。
//
//    ID 判据（《达芬奇-lite 之 FPGA 开发指南》13.4 节 rd_id 例程）：
//      {lcd_rgb[23], lcd_rgb[15], lcd_rgb[7]} = {M0, M1, M2}
//        3'b010 -> ATK-7016  1024x600  PCLK 50M
//        3'b001 -> ATK-7084   800x480  PCLK 25M
//        3'b100 -> ATK-4384   800x480  PCLK 25M
//        3'b101 -> ATK-1018  1280x800  PCLK 50M
//        3'b000 -> ATK-4342   480x272  PCLK 12.5M
// -----------------------------------------------------------------------------
module lcd_panel_id_read #(
    parameter [22:0] RD_CYCLES = 23'd2_097_151      // 2^21 拍 ≈ 42ms @50MHz
)(
    input  wire clk,
    input  wire rst_n,        // 上电复位（异步）
    input  wire lcd_r7,       // = lcd_rgb[7]
    input  wire lcd_g7,       // = lcd_rgb[15]
    input  wire lcd_b7,       // = lcd_rgb[23]
    output wire data_oe,      // 1 = FPGA 驱动 24 根数据线；0 = 全部高阻（读 ID）
    output wire lcd_rst_n,    // LCD/触摸 IC 复位（低有效，本模块内产生）
    output reg  [2:0] panel_id,
    output reg  id_valid      // 锁存完成
);
    reg [22:0] cnt;
    reg        reading;       // 采样窗口内
    reg        active;        // 已经离开复位、开始等屏稳定

    // LCD 复位：上电后 cnt 数到 RD_CYCLES 才释放，保证 ID 电阻分压在采样前已稳定。
    // 本模块同时兼作 LCD 的复位发生器，这样"采样窗口"与"复位窗口"天然对齐。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt      <= 23'd0;
            reading  <= 1'b0;
            active   <= 1'b0;
            panel_id <= 3'b010;        // 缺省按 7016（本工程的目标屏）
            id_valid <= 1'b0;
        end
        else begin
            if (!active) begin
                active  <= 1'b1;
                reading <= 1'b1;
                cnt     <= 23'd0;
            end
            else if (reading) begin
                if (cnt == RD_CYCLES) begin
                    reading  <= 1'b0;
                    panel_id <= {lcd_b7, lcd_g7, lcd_r7};   // {M0, M1, M2}
                    id_valid <= 1'b1;
                end
                else cnt <= cnt + 23'd1;
            end
        end
    end

    assign lcd_rst_n = active;
    assign data_oe   = ~reading;
endmodule

// -----------------------------------------------------------------------------
// 4) IIC 开漏双向引脚
//    板级 T_SCL/T_SDA 上各有上拉（接 LCD 模块侧），FPGA 只负责"拉低"或"释放"。
//    这里用 IOBUF 实现：oe=1 时把 O（恒 0）推到线上 = 拉低；oe=0 时高阻 = 释放，
//    由外部上拉拉高。I 是回读值，经两级同步后再给 IIC 逻辑用。
//    ★ IOBUF 的 T 是"三态使能、高有效"（T=1 => 高阻），与本模块 oe 的语义相反，
//      所以必须接 ~oe。曾经直接接 oe，仿真桩恰好也写反（互相抵消、全绿），
//      上板后"释放"变成"拉低"：SDA 恒低 => 所有地址都像被 ACK、读回全 0。
// -----------------------------------------------------------------------------
module i2c_io_wrap (
    input  wire clk,
    input  wire rst_n,
    input  wire scl_oe,       // 1 = 拉低 SCL
    input  wire sda_oe,       // 1 = 拉低 SDA
    output wire scl_o,        // 同步后的线上电平
    output wire sda_o,
    inout  wire scl_io,
    inout  wire sda_io
);
    wire scl_i, sda_i;
    wire scl_sync, sda_sync;

    // 高阻时靠外部上拉（LCD 模块侧有上拉电阻）。
    IOBUF #(.DRIVE(8), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW")) u_scl (
        .O  (scl_i),
        .IO (scl_io),
        .I  (1'b0),
        .T  (~scl_oe)
    );
    IOBUF #(.DRIVE(8), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW")) u_sda (
        .O  (sda_i),
        .IO (sda_io),
        .I  (1'b0),
        .T  (~sda_oe)
    );

    reg [1:0] scl_s, sda_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_s <= 2'b11;
            sda_s <= 2'b11;
        end
        else begin
            scl_s <= {scl_s[0], scl_i};
            sda_s <= {sda_s[0], sda_i};
        end
    end

    assign scl_o = scl_s[1];
    assign sda_o = sda_s[1];
endmodule

// -----------------------------------------------------------------------------
// 5) UART 字节发送
//    50MHz / 115200 = 434.03，取 434 => 实际 115207bps（误差 0.006%，可忽略）。
//    每字节 8N1。tx_busy 为高时忽略新的 start 请求。
// -----------------------------------------------------------------------------
module uart_tx_byte #(
    parameter [15:0] DIV = 16'd434
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,        // 单周期请求
    input  wire [7:0] data,
    output reg  tx,
    output reg  busy
);
    reg [15:0] div_cnt;
    reg [3:0]  bit_idx;       // 0 = start, 1..8 = data, 9 = stop
    reg [7:0]  shreg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx      <= 1'b1;
            busy    <= 1'b0;
            div_cnt <= 16'd0;
            bit_idx <= 4'd0;
            shreg   <= 8'h00;
        end
        else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                busy    <= 1'b1;
                shreg   <= data;
                bit_idx <= 4'd0;
                div_cnt <= 16'd0;
                tx      <= 1'b0;           // start bit
            end
        end
        else begin
            if (div_cnt == DIV - 16'd1) begin
                div_cnt <= 16'd0;
                if (bit_idx == 4'd9) begin
                    busy    <= 1'b0;
                    tx      <= 1'b1;
                    bit_idx <= 4'd0;
                end
                else begin
                    bit_idx <= bit_idx + 4'd1;
                    // ★ 时序：case(bit_idx) 决定的是**下一个**位周期的电平，
                    //   因为 bit_idx 与 tx 在同一个时钟沿更新。
                    //   bit_idx=0 的周期 = 起始位（由上面 !busy 分支直接给出），
                    //   所以周期 1..8 对应 shreg[0..7]，周期 9 才是停止位。
                    //   旧代码把 0..6 映到 shreg[0..6]、7/8 都映到 shreg[7]，
                    //   等于每字节多发一位重复的 MSB：MSB=0 的字节被 PC 侧判成
                    //   帧错（停止位为低），一帧 16 字节被截断/错位。
                    case (bit_idx)
                    4'd0: tx <= shreg[0];
                    4'd1: tx <= shreg[1];
                    4'd2: tx <= shreg[2];
                    4'd3: tx <= shreg[3];
                    4'd4: tx <= shreg[4];
                    4'd5: tx <= shreg[5];
                    4'd6: tx <= shreg[6];
                    4'd7: tx <= shreg[7];
                    default: tx <= 1'b1;      // bit_idx==8 → 下一周期是停止位
                    endcase
                end
            end
            else div_cnt <= div_cnt + 16'd1;
        end
    end
endmodule

// -----------------------------------------------------------------------------
// 6) 遥测帧发送
//    每秒（由 frame_tick 计到 59 帧 ≈ 1.007s 的门控脉冲触发）发一帧 16 字节，
//    格式见 docs/LCD_touch_test_readme.md：
//      0: 0xA5 帧头
//      1: 0x4C 'L' 设备类型（LCD 测试程序）
//      2: 版本 0x01
//      3: 屏 ID 命中位（bit0=4342 bit1=4384 bit2=7016 bit3=7084 bit4=1018，bit7=id_valid）
//      4: 当前画面号 0..9
//      5: 触摸 IC 类型（0=未知 1=GT911 2=FT5x06），bit7 = 本帧是否有触摸
//      6: 触摸点数 0..5
//      7: 点数冗余校验（与 6 相同，便于抓窄脉冲）
//      8: 第 1 点 X 高字节      9: X 低字节
//     10: 第 1 点 Y 高字节     11: Y 低字节
//     12-13: 每秒完成传输次数（大端）
//     14-15: 每秒错误次数（大端）
//    ★ 调试用：只关心"触控到底活没活"看第 5/6 字节；关心"分辨率识别对不对"看第 3
//      字节；关心 IIC 稳定性看 14/15 字节（正常应恒为 0）。
// -----------------------------------------------------------------------------
module uart_frame_sender (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        send,          // 单周期脉冲：发一帧
    input  wire [7:0]  b0, b1, b2, b3,
    input  wire [7:0]  b4, b5, b6, b7,
    input  wire [7:0]  b8, b9, b10, b11,
    input  wire [7:0]  b12, b13, b14, b15,
    output wire        tx,
    output reg         busy
);
    reg [3:0]  idx;
    reg        sending;
    reg        tx_start;
    reg [7:0]  tx_data;
    wire       tx_busy;
    reg [7:0]  cur;

    always @(*) begin
        case (idx)
        4'd0:  cur = b0;
        4'd1:  cur = b1;
        4'd2:  cur = b2;
        4'd3:  cur = b3;
        4'd4:  cur = b4;
        4'd5:  cur = b5;
        4'd6:  cur = b6;
        4'd7:  cur = b7;
        4'd8:  cur = b8;
        4'd9:  cur = b9;
        4'd10: cur = b10;
        4'd11: cur = b11;
        4'd12: cur = b12;
        4'd13: cur = b13;
        4'd14: cur = b14;
        default: cur = b15;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx      <= 4'd0;
            sending  <= 1'b0;
            tx_start <= 1'b0;
            tx_data  <= 8'h00;
            busy     <= 1'b0;
        end
        else begin
            tx_start <= 1'b0;

            if (!sending) begin
                busy <= 1'b0;
                if (send) begin
                    sending <= 1'b1;
                    idx     <= 4'd0;
                    busy    <= 1'b1;
                end
            end
            else begin
                busy <= 1'b1;
                if (!tx_busy && !tx_start) begin
                    tx_start <= 1'b1;
                    tx_data  <= cur;
                    if (idx == 4'd15) sending <= 1'b0;
                    else              idx     <= idx + 4'd1;
                end
            end
        end
    end

    uart_tx_byte u_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .start (tx_start),
        .data  (tx_data),
        .tx    (tx),
        .busy  (tx_busy)
    );
endmodule
