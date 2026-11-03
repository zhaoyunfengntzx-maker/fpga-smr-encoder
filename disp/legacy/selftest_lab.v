//=============================================================================
// selftest_lab.v -- P8「自检结果」的结论文本（规范 §4.4 五项里的第 ⑤ 项）
//
// 职责：每帧把**运行期**的自检结论写进 P8 的 lab 平面第 36 格行的 36/37 格，
//       也就是底栏最右端「自检结果 <通过|失败>」那两个格子（标签「自检结果」
//       是 tools/gen_text_ram.py 的静态版面，本模块只写结论两个字）。
//
// 为什么结论要单独一个模块：结论是运行期才知道的（IIC 计数每帧都在变），
// 而静态版面在 disp/text_ram.v 的 initial 里一次成型、改不了 —— 与 P1 的
// undo_lab（面板「↩ 回到 ×N」）是同一个理由。
//
// ---------------------------------------------------------------------------
// 自检项（三项，全部是"显示侧到触摸 IC"这条链路能自己看到的事实）
//   ① IIC 读次数 != 0     链路在跑（0 = 一次都没读成功过 ⇒ 停摆）
//   ② 无应答次数 == 0     从机没有 NAK（NAK = 地址/寄存器对不上或接触不良）
//   ③ 超时次数 == 0       总线没被拉死
//   三项全真 ⇒ 「通过」，否则 ⇒ 「失败」。
//
// ★ 判据的每一个输入**都显示在同一页上**：第 15 格行的「IIC 读 / 无应答 /
//   超时」三个数值就是这三项的原始计数。规范 §5.2 的纪律是"颜色/单字绝不能
//   是唯一的状态编码"——这里更进一步：结论必须能被同一屏上的明细交叉验证，
//   所以不引入任何"只有结论、没有依据"的判据（例如 BiSS CRC 只有电平没有
//   计数，就不收进来，见 U-35.8 / U-36.8）。
//
// 反例口径（故意不算进自检）：
//   * `tch_status == 0`（0x814E 不刷新）是本板的历史现象，通信是好的，
//     不判失败（disp/disp_engine.v 的触摸状态灯把它画成蓝色信息态）。
//   * 触点数 == 0（当前没手指）不是故障。
//
// ---------------------------------------------------------------------------
// 写口：与 band_view 共用 p8_lab_ram（band_view 写底栏 11/18/27 列，本模块写
//   36/37 列，格子不重叠）。**we/waddr/wdata 都是组合输出**：㉗（记录 53）的
//   教训是"寄存输出会把'这一拍有没有被别的写者占住'提前一拍猜"，于是被仲裁
//   吃掉的那一笔写会静默消失、而 idx 照常推进。这里改成"在写 ∧ !hold"同一拍
//   成立，并且 hold 期间 idx 不推进，所以永远不会丢格子：
//       assign we = (st == S_WR) && !hold;
//
// 时序：start 是帧起始单拍（disp_engine 的 vf_start，与 band_view 同一个信号）。
//   两个格子两拍就写完，一帧 1024x600 像素，写窗口绰绰有余。
//
// 上电首帧之前屏上是静态版面的「失败」（fail-safe）：那时候一个 IIC 读都还
// 没发生，按上面的判据本来就该是"失败"，所以占位值与真实结论是一致的；
// 一旦 reads != 0，第一帧就会被改写成「通过」。
//=============================================================================
`default_nettype none

module selftest_lab (
    input  wire        clk,
    input  wire        rst_n,          // 异步复位、低有效
    input  wire        start,          // vf_start：帧起始单拍
    input  wire        hold,           // 同拍写口被 band_view 占住（bv_we）

    input  wire [23:0] reads,          // IIC 读次数（0 = 停摆）
    input  wire [23:0] nack,           // 无应答次数（!=0 ⇒ 失败）
    input  wire [23:0] timeout,        // 超时次数（!=0 ⇒ 失败）

    output wire        we,
    output wire [11:0] waddr,
    output wire [7:0]  wdata,
    output reg         busy,
    output reg         done
);

    // 结论两个字：「通过」= 通/过；「失败」= 失/败
    // 码 = tools/gen_font_rom.py 的 ASCII_CHARS 长度(51) + tools/cn_glyphs.py
    // 里 CN_ORDER 的下标（自=104 ⇒ 155，见 _disp_work/_codes36.txt 的探测输出）。
    localparam [7:0] CH_TONG = 8'd159;   // 通
    localparam [7:0] CH_GUO  = 8'd160;   // 过
    localparam [7:0] CH_SHI  = 8'd161;   // 失
    localparam [7:0] CH_BAI  = 8'd162;   // 败

    localparam [5:0] LAB_ROW = 6'd36;    // 底栏格行（gen_text_ram.py 的 P8_LAB）
    localparam [5:0] LAB_C0  = 6'd36;    // 结论第一格（标签「自检结果」在 31..34）
    localparam [1:0] LAB_N   = 2'd1;     // 写 2 格（k = 0..1）

    // ---------------------------------------------------------------------
    // 1. 三项判据
    // ---------------------------------------------------------------------
    wire ok_reads   = (reads   != 24'd0);
    wire ok_nack    = (nack    == 24'd0);
    wire ok_timeout = (timeout == 24'd0);
    wire st_pass    = ok_reads && ok_nack && ok_timeout;

    // ---------------------------------------------------------------------
    // 2. 每格写什么（结论两个字）
    // ---------------------------------------------------------------------
    wire [7:0] ch0 = st_pass ? CH_TONG : CH_SHI;
    wire [7:0] ch1 = st_pass ? CH_GUO  : CH_BAI;

    // ---------------------------------------------------------------------
    // 3. 写序列：帧起始开始，两拍写完（组合写口 + hold 仲裁）
    // ---------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_DONE = 2'd2;

    reg [1:0] st;
    reg [1:0] idx;

    assign we    = (st == S_WR) && !hold;
    assign waddr = {LAB_ROW, LAB_C0 + {4'd0, idx}};
    assign wdata = (idx == 2'd0) ? ch0 : ch1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            idx  <= 2'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                            st   <= S_WR;
                            idx  <= 2'd0;
                            busy <= 1'b1;
                        end
                S_WR: if (!hold) begin     // hold 期间既不写也不推进 ⇒ 不丢格子
                            if (idx == LAB_N) st <= S_DONE;
                            else              idx <= idx + 2'd1;
                        end
                default: begin             // S_DONE
                            st   <= S_IDLE;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
            endcase
        end
    end

endmodule

`default_nettype wire
