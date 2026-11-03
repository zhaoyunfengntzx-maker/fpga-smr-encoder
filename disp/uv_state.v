// -----------------------------------------------------------------------------
//  disp/uv_state.v —— v52（㊾）A3：P1 卡 6 的次级信息「U V W」写口
//                     ★ v83（任务B）：落点从**标签层**改到**数值层**
//
//  为什么需要它：
//    spec §4.5（docs/13_display_ui_requirements.md:190）把卡 6 的次级信息写成
//    两样东西：**底部迷你 6 通道逻辑条**（U-50 已做，读 io_state 的 a/b/z/u/v/w）
//    与这一行 `U● V● W○` —— 后者是"三路 UVW 各自的电平"，一眼能看出换相表
//    走到了哪一相。它是**会变的**值，不能写进静态版面（tools/gen_text_ram.py 只能
//    铺首帧之前的占位），所以静态版面只放标题那一行的 `ABZ/UVW`，本模块每帧把
//    8 格写进数值层。
//
//  ★ v83 为什么从标签层（11x14）搬到数值层（30x48）：
//    用户的投诉是"卡 6 的两行字号不一致"：`A● B● Z○` 走数值面是大号 30x48，
//    上一行 `U● V● W○` 走标签面是小号 11x14。两行必须同字号，而标签面的字模
//    只有一种 11x14，唯一能让两行同字号又不重排版面的办法就是**把这一行也做成
//    大号**。几何算得过来：卡 6 = x576..1023 / y448..599，
//      · 标签行 28（y448..463）= 标题 `ABZ/UVW`；
//      · 数值行 10（y480..527）= `U● V● W○`（本模块写）；
//      · 数值行 11（y528..575）= `A● B● Z○`（val_format 的字段 5，v83 由行 10 下移）；
//      · 标签行 36（y576..591）= 「状态正常」。
//    两行 48 px 正好吃掉 y480..575，标题与底注各自贴边，一 px 都不叠。
//
//  写口仲裁（v83 起本模块写的是 **P1 数值层**，与 val_format 共用同一个写口）：
//    数值层每帧由 val_format 从字段 0 顺序写到字段 5；本模块在它**全部写完**
//    之后才开始（disp_engine 把 start 接成 vf_done，见下），并把 val_format 正在
//    写的那一拍（vf_we）当 hold —— 于是两者永不撞同一拍，地址也不相交
//    （本模块只写数值行 10 的格列 18..25）。
//    ★ 为什么 start 必须用 vf_done 而不是 vf_start：单位/长度是"本帧"的量，
//      若与 val_format 同时起跑，本模块拿到的 len 是**上一帧**的，数字变长时
//      就会压住单位（v82 上板"U V W 那行"本身没有 len，但同一套仲裁给
//      unit_lab 用，那里 2026-11 的 DEG 压字就是同一类跨帧时序问题）。
//
//  字形（**数值层**码表，6 bit）：
//    ● = 48（实心，高电平）、○ = 51（空心，低电平）
//    ★ 这里有两个容易踩的编号细节：
//      1) ○ 在 **数值层**是码 51、在 **标签层**是码 183（两个平面各自在自己的
//         字符表末尾追加，见 tools/gen_text_ram.py 的 `VAL_EXTRA` / `LAB_EXTRA`）。
//         v82 及以前本模块写标签层，所以用 183；v83 起改写数值层，必须改成 51。
//      2) 两个平面各有自己的 ROM（font_rom_lab / font_rom_val）与索引位宽，
//         RTL 里从不跨平面传码，所以"同字两号"不会互相感染。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module uv_state (
    input  wire        clk,
    input  wire        rst_n,        // 异步复位、低有效
    input  wire        start,        // 本帧数值字段全部写完（disp_engine 接 vf_done）
    input  wire [2:0]  uvw,          // io_state[5:3] = {w,v,u}
    input  wire        hold,         // 数值层写口被 val_format 占着 → 本拍不写、不推进

    output wire        we,
    output wire [8:0]  waddr,        // {格行[3:0], 格列[4:0]}（数值层 32x13 格网）
    output wire [5:0]  wdata,
    output reg         busy,         // 写序列进行中（探针）
    output reg         done          // 写序列结束单拍（探针）
);

    // 数值层格：32 px 宽、48 px 高。卡 6 的左沿 x576 = 格列 18；
    // 行 10 = y 480..527（标题行 28 下沿 463 与行 11 之间唯一的空行）。
    localparam [3:0] ROW    = 4'd10;
    localparam [4:0] COL    = 5'd18;   // 8 格 = 格列 18..25（x 576..831）
    localparam [2:0] N_CELL = 3'd7;    // 8 格（idx = 0..7）

    // 字符码（**数值层** 6 bit 码表：ASCII 在前，○ 追加在表尾 = 51）
    //   '0' = 8 ⇒ 'U' = 18 + 20 = 38、'V' = 39、'W' = 40
    //   ● = 48（v30 追加的状态字形，两个平面同码）
    //   ○ = 51（v52 追加，数值层码；标签层那个是 183）
    localparam [5:0] CH_U   = 6'd38;
    localparam [5:0] CH_V   = 6'd39;
    localparam [5:0] CH_W   = 6'd40;
    localparam [5:0] CH_HI  = 6'd48;   // ●
    localparam [5:0] CH_LO  = 6'd51;   // ○（数值层）
    localparam [5:0] CH_SP  = 6'd0;

    reg  [2:0] idx;

    reg [5:0] ch;
    always @* begin
        case (idx)
            3'd0:    ch = CH_U;
            3'd1:    ch = uvw[0] ? CH_HI : CH_LO;   // U
            3'd2:    ch = CH_SP;
            3'd3:    ch = CH_V;
            3'd4:    ch = uvw[1] ? CH_HI : CH_LO;   // V
            3'd5:    ch = CH_SP;
            3'd6:    ch = CH_W;
            default: ch = uvw[2] ? CH_HI : CH_LO;   // W
        endcase
    end

    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;
    reg [1:0] st;

    assign we    = (st == S_WR) && !hold;
    assign waddr = {ROW, COL + {2'd0, idx}};
    assign wdata = ch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            idx  <= 3'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                            st   <= S_WR;
                            idx  <= 3'd0;
                            busy <= 1'b1;
                        end
                S_WR: if (!hold) begin
                            if (idx == N_CELL) st <= S_DONE;
                            else               idx <= idx + 3'd1;
                        end
                default: begin                 // S_DONE
                            st   <= S_IDLE;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
            endcase
        end
    end

endmodule

`default_nettype wire
