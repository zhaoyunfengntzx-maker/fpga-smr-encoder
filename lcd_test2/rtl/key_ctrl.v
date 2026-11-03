//==========================================================================
// key_ctrl.v —— 板载按键（key_n，低有效）消抖 + 短按/长按判定（F4）
//   短按（< 1 s）：mode 取反 —— F1 标准色轮播 ↔ F2/F3 触摸点位与实时反馈
//   长按（≥ 1 s）：paused 取反 —— 冻结色轮播 / 冻结准星保留计数
// 上电默认 mode=0（F1），paused=0。
//==========================================================================
module key_ctrl #(
    parameter [19:0] DB_CYCLES   = 20'd500_000,      // 消抖 10 ms @50MHz
    parameter [26:0] LONG_CYCLES = 27'd50_000_000    // 长按阈值 1 s @50MHz
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,          // 低有效
    output reg  mode,           // 0 = F1 标准色；1 = F2/F3 点位与反馈
    output reg  paused,
    output reg  press,          // 短按脉冲（单周期）
    output reg  long_press,     // 长按脉冲（单周期）
    output reg  key_state       // 消抖后的按下状态（1 = 按下）
);

    // 输入两级同步
    reg [1:0] ksync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ksync <= 2'b11;
        else        ksync <= {ksync[0], key_n};
    end
    wire k = ksync[1];

    // 消抖：电平稳定 DB_CYCLES 拍才认可
    reg [19:0] db_cnt;
    reg        stable;          // 1 = 松开（key_n 为高）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            db_cnt <= 20'd0;
            stable <= 1'b1;
        end else if (k != stable) begin
            if (db_cnt == DB_CYCLES) begin
                stable <= k;
                db_cnt <= 20'd0;
            end else begin
                db_cnt <= db_cnt + 20'd1;
            end
        end else begin
            db_cnt <= 20'd0;
        end
    end

    wire pressed = ~stable;     // 消抖后的"按下"

    reg [26:0] hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode       <= 1'b0;
            paused     <= 1'b0;
            press      <= 1'b0;
            long_press <= 1'b0;
            key_state  <= 1'b0;
            hold       <= 27'd0;
        end else begin
            press      <= 1'b0;
            long_press <= 1'b0;
            key_state  <= pressed;

            if (pressed) begin
                if (hold < LONG_CYCLES) begin
                    hold <= hold + 27'd1;
                end else if (hold == LONG_CYCLES) begin
                    long_press <= 1'b1;         // 只发一次
                    paused     <= ~paused;
                    hold       <= hold + 27'd1; // 饱和，避免重复触发
                end
            end else begin
                if (hold != 27'd0 && hold < LONG_CYCLES) begin
                    press <= 1'b1;              // 没到长按阈值 = 短按
                    mode  <= ~mode;
                end
                hold <= 27'd0;
            end
        end
    end

endmodule
