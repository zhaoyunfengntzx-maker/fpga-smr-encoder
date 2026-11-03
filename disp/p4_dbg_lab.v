//=============================================================================
// disp/p4_dbg_lab.v —— P4 页右上角的**屏上自证**读数（v79 新增，v84 改布局）
//-----------------------------------------------------------------------------
// 为什么需要这个模块（问题背景）：
//   P4「逻辑时序」页上板后整页空白、只剩六条平线，而仿真里逐点都对。这有两种
//   完全不同的原因，在屏幕上却是**同一个画面**：
//     ① 从来没触发过（p4_scope 的两片 LUTRAM 一个字节都没写过 ⇒ 上电全 0）；
//     ② 写了但读不出来（采样/读口的时序或抽头不对）。
//   串口读寄存器本来是最快的定位手段，但 `read_reg` 走的是 rtl/reg_file.v，
//   而本轮约定"不许动 rtl/"。所以改成**让屏幕自己说话**：把链路上每一环的
//   关键量打成十六进制写到 P4 页右上角，拍一张照片就能判断卡在哪一环。
//
// ★ v84 布局（本版重点：**窗口长度直接上屏**，一眼看出是 1.6 M 还是 1024）：
//   格行 4（y 64..79）： `WL=hhhhhh ECLK=hhhhhh WP=hh`        格列 35..61
//   格行 5（y 80..95）： `TRIG=hhhh EN=h S=h DA=h`            格列 41..63
//   另外 `NO CAPTURE`（格行 17、格列 26..35）静态烧在 p4_lab_ram 里，只有
//   "有数据且 eclk!=0" 时才擦掉（v84：无信号时**留着**它，不再无脑擦）。
//
// 每个字段的含义（全部十六进制 —— 省掉 BCD 转换，见下）：
//   WL  = 本帧窗口长度 win_l（clk，22 位）。pairs=4、eclk=0x0C37 时应为
//         0x17F000 = 1,601,024 clk（32.0 ms）。**1024 / 000400 这种小值就是病**。
//   ECLK= 实测传感器信号周期（两次角度过零之间的 clk 数）。**0 = 一个过零都没数到**
//         （角度不动 / 抽头坏了）。1 kHz 输入时应是 0x00C350 = 50000（@50 MHz）。
//   WP  = 下区写指针。0/1 = 没采过，0xFF = 采满 256 点（正常）。
//   TRIG= 已完成的采集帧数（p4_scope.frames）。**0 = 一次都没触发**。
//   EN  = 已数到的电角度过零个数（饱和 3；≥2 才让兜底看门狗接管）。
//   S   = {up_ok, scnt[2:0]} —— v84 的**交叉校验自证**（一个十六进制位）：
//         8 = up_ok=1 且 U 相一次都没抖过（健康）；F = up_ok 正常但 U 相在扇区
//         边界上抖过（正是 v83 里 uper 被打成"几个 clk"的机制）；0..7 = 
//         up_ok=0，也就是根本还没数够 2 个 U 上升沿。
//   DA  = 至少完成过一帧（= frames != 0）。
//
// 为什么用十六进制而不是十进制：
//   十进制要"除以 10"逐位取，五个数就是五套除法/双 dabble 转换器，本设计 LUT
//   只剩约 500 个（84.46%）。十六进制是**纯切片**；而且字库
//   tools/gen_text_ram.py 的 ASCII_CHARS = " .-+/:=^0123456789ABCDEF..." 里
//   '0'..'9' 的码正好是 8..17、'A'..'F' 是 18..23 ⇒ 十六进制码 = 半字节 + 8，
//   一个常量和加法就够，连查表都不用。
//
// 布局（格坐标，lab 平面 16 px/格；与 tools/gen_text_ram.py 的 P4_LAB 是
// **两处共同契约**，改一边必须改另一边）：
//   静态标签（WL= / ECLK= / WP= / TRIG= / EN= / S= / DA=）由 Python 生成器
//   直接烧进 p4_lab_ram，**不占 LUT**；本模块只写 21 个**数字格** + 10 个擦除格。
//   格列（从文件头的字符串逐字推出，错一格就会盖掉标签）：
//     WL 数字   38..43      ECLK 数字 50..55      WP 数字   60,61
//     TRIG 数字 46..49      EN 数字   54           S 数字    58
//     DA 数字   63
//
// 代价：21（+10）格 × 1 格/clk（p4_lab_ram 的写口本来悬空，见 disp_engine.v
//       的 u_p4_lab_ram），一帧只占用 31 个 clk，肉眼不可见。
//=============================================================================
`default_nettype none

module p4_dbg_lab (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,      // 帧启动脉冲（disp_engine 的 vf_start）
    input  wire        hold,       // 写口被别人占用的那一拍（本页单写者，接 0）

    input  wire [15:0] frames,     // p4_scope.frames
    input  wire [21:0] win,        // p4_scope.dbg_win   （v84）
    input  wire [20:0] eclk,       // p4_scope.dbg_eclk
    input  wire [7:0]  wp,         // p4_scope.dbg_wp
    input  wire [1:0]  enok,       // p4_scope.dbg_enok
    input  wire        upok,       // p4_scope.dbg_upok  （v84）
    input  wire [2:0]  scnt,       // p4_scope.dbg_scnt  （v84）
    input  wire        nocap,      // p4_scope.dbg_nocap （v84）

    output reg         we,
    output reg  [11:0] waddr,      // {格行[5:0], 格列[5:0]}（与 lab_raddr 同格式）
    output reg  [7:0]  wdata,      // 字库码（ASCII_CHARS 下标）
    output reg         busy,
    output reg         done
);

    // =========================================================================
    // 1. 待显示数据打包成 21 个半字节（顺序 = 显示顺序，第 0 格在最高 4 位）
    //    { WL(24), ECLK(24), WP(8), TRIG(16), EN(4), S(4), DA(4) } = 84 位
    //    WL/eclk 都补零到定宽 6 位，读起来是 17F000 / 000C37 这种格式，位数不跳。
    // =========================================================================
    wire [83:0] dv = { {2'b00, win},
                       {3'b000, eclk},
                       wp[7:0],
                       frames[15:0],
                       {2'b00, enok},
                       {2'b00, upok, scnt[2:0]},
                       {3'b000, (frames != 16'd0)} };

    // ★ v82 教训（别再犯）：idx 原来是 4 位，而"有数据"时要写 26 格 ⇒ 永远走不到
    //   nlast，状态机在 S_WR 里 15→0 无限打转；更隐蔽的是 `idx >= 4'd16` 会被
    //   截成 `idx >= 0` ⇒ **每个数字格都写成空格**。现在 idx 一律 5 位、
    //   常数一律写 5'dNN，格子总数 31 < 32 刚好放得下。
    reg  [4:0] idx;                // 0..20 = 数字格，21..30 = 擦除 NO CAPTURE
    //   擦除格不看数据，所以 sh 在 idx>20 时钳到 0：否则 80-4*21 会下溢成 124，
    //   变址部分选择越界（仿真出 X、综合多一堆比较）。
    wire [6:0] sh  = (idx <= 5'd20) ? (7'd80 - {idx, 2'b00}) : 7'd0;
    wire [3:0] nib = dv[sh +: 4];                // 只需要 4 位，32 位桶形移位会被裁掉

    // =========================================================================
    // 2. 本格的字库码：十六进制 = 半字节 + 8（见文件头，'0'=8、'A'=18）
    //    擦除格写 8'd0 = 空格。
    // =========================================================================
    wire [7:0] ch_d = (idx >= 5'd21) ? 8'd0 : ({4'd0, nib} + 8'd8);

    // =========================================================================
    // 3. 本格的格坐标（与文件头的布局表一一对应）
    // =========================================================================
    reg  [5:0] row, col;

    always @(*) begin
        row = 6'd4;
        col = 6'd38;
        if (idx <= 5'd5) begin                 // WL 6 位：格列 38..43
            row = 6'd4;
            col = 6'd38 + {1'b0, idx};
        end else if (idx <= 5'd11) begin       // ECLK 6 位：格列 50..55
            row = 6'd4;
            col = 6'd44 + {1'b0, idx};         // idx6 -> 50
        end else if (idx <= 5'd13) begin       // WP 2 位：格列 60,61
            row = 6'd4;
            col = 6'd48 + {1'b0, idx};         // idx12 -> 60
        end else if (idx <= 5'd17) begin       // TRIG 4 位：格列 46..49
            row = 6'd5;
            col = 6'd32 + {1'b0, idx};         // idx14 -> 46
        end else if (idx == 5'd18) begin       // EN：格列 54
            row = 6'd5;
            col = 6'd54;
        end else if (idx == 5'd19) begin       // S：格列 58
            row = 6'd5;
            col = 6'd58;
        end else if (idx == 5'd20) begin       // DA：格列 63
            row = 6'd5;
            col = 6'd63;
        end else begin                         // 擦除 NO CAPTURE：格行 17，列 26..35
            row = 6'd17;
            col = 6'd5 + {1'b0, idx};          // idx21 -> 26
        end
    end

    // =========================================================================
    // 4. 一格一个 clk 的写状态机（与 z_cnt_lab / p2_win_lab 同构）
    //    ★ hold 为高的那一拍不推进：p1_lab_ram 有六个写者靠这个机制互斥，
    //      本页只有一个写者，hold 接 0，但保留接口以免以后加写者时改结构。
    //    ★ v84：擦掉 NO CAPTURE 的条件收紧成 "有数据 **且** 有信号"（nocap=0）。
    //      无信号时把提示留在屏上，正好和 WL=000400 对得上。
    // =========================================================================
    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;
    reg [1:0] st;

    // 擦提示(31 格) / 只写数字(21 格)
    wire       erase = (frames != 16'd0) && !nocap;
    wire [5:0] nlast = erase ? 6'd30 : 6'd20;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            idx   <= 5'd0;
            we    <= 1'b0;
            waddr <= 12'd0;
            wdata <= 8'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            we   <= 1'b0;
            done <= 1'b0;
            case (st)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    st   <= S_WR;
                    idx  <= 5'd0;
                    busy <= 1'b1;
                end
            end
            S_WR: begin
                if (!hold) begin
                    we    <= 1'b1;
                    waddr <= {row, col};
                    wdata <= ch_d;
                    if ({1'b0, idx} >= nlast) begin
                        st   <= S_DONE;
                        busy <= 1'b0;
                    end else begin
                        idx <= idx + 5'd1;
                    end
                end
            end
            S_DONE: begin
                done <= 1'b1;
                st   <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
