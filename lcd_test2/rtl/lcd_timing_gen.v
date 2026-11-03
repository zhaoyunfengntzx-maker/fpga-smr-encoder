// -----------------------------------------------------------------------------
//  lcd_test/rtl/lcd_timing_gen.v
//  RGB TFT-LCD 时序发生器（DE 模式），默认参数即正点原子 ATK-7016（7 寸 1024x600）。
//
//  参数来源：《达芬奇-lite 之 FPGA 开发指南》表 13.1.3 / 表 13.4.2
//      1024x600 : PCLK 50MHz, H = 20 / 140 / 1024 / 160（行总 1344）
//                             V =  3 /  20 /  600 /  12（帧总  635）
//      帧时钟数 = 635 * 1344 = 853440，50MHz => 58.60Hz（指南称"接近 60Hz"）
//
//  为什么用 clk + pixel_en 而不是"分频时钟"：
//    其他几款屏（ATK-4342 12.5M / 4384 25M / 7084 25M）如果直接对 50MHz 分频
//    当时钟用，会产生"非全局网络的衍生时钟"，要额外 BUFG，且像素域与 50MHz 域
//    之间要做 CDC。改用 pixel_en 使能后，全部逻辑仍在 50MHz 单时钟域，只有
//    "什么时候推进一个像素"被门控 —— 时序收敛简单、无跨域。
//
//  ★ 关键实现约束：**垂直计数绝不能受 pixel_en 门控**。
//    早期版本把 hcnt/vcnt 一起放在 `else if (ce)` 里，看似自洽，但一旦 pixel_en
//    生效（例如给 25MHz 屏用 CE_DIV=2，pixel_en 在奇偶周期交替），"行推进"仍按
//    像素周期发生、而 vcnt 只在像素周期才动，场计数将被额外拖慢一倍（实测 60Hz
//    的屏会变成 30Hz）。正确做法：hcnt 受 pixel_en 门控（一行里的像素数由它决定），
//    vcnt 只受 "一行结束" 门控（行数由它决定），两者解耦。
//
//  本模块为"运行时可配置"版本：H_*/V_* 是输入端口而不是参数，因为上电读屏 ID 后
//  才知道接的是哪一款屏（7016 / 4384 / 1018 ...），顶层需要动态选择时序。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module lcd_timing_gen (
    input               clk_pix,      // 50MHz 系统时钟（不是分频后的像素时钟）
    input               rst_n,
    input               pixel_en,     // 像素时钟使能（每 pixel_en 个 clk_pix 推进一个像素）

    input      [11:0]   h_sync,
    input      [11:0]   h_back,
    input      [11:0]   h_disp,
    input      [11:0]   h_front,
    input      [11:0]   v_sync,
    input      [11:0]   v_back,
    input      [11:0]   v_disp,
    input      [11:0]   v_front,

    output reg          lcd_hs,       // 行同步，低有效
    output reg          lcd_vs,       // 场同步，低有效
    output reg          lcd_de,       // 数据使能
    output reg [11:0]   pix_x,        // 0..h_disp-1
    output reg [11:0]   pix_y,        // 0..v_disp-1
    output reg          frame_st,     // 每帧第一个有效像素处 1 个 clk_pix
    output reg          line_st       // 每行第一个有效像素处 1 个 clk_pix
);

    reg [11:0] hcnt;
    reg [11:0] vcnt;

    wire [12:0] h_sum = {1'b0, h_sync} + {1'b0, h_back};
    wire [12:0] v_sum = {1'b0, v_sync} + {1'b0, v_back};

    // 行内有效区间：h_sum .. h_sum + h_disp - 1
    wire h_act = (hcnt >= h_sum[11:0]) && (hcnt < h_sum[11:0] + h_disp);
    wire v_act = (vcnt >= v_sum[11:0]) && (vcnt < v_sum[11:0] + v_disp);

    wire h_last = (hcnt == ({1'b0, h_sync} + {1'b0, h_back} + {1'b0, h_disp} + {1'b0, h_front} - 13'd1));
    wire v_last = (vcnt == ({1'b0, v_sync} + {1'b0, v_back} + {1'b0, v_disp} + {1'b0, v_front} - 13'd1));

    // 行推进：受 pixel_en 门控；行首（hcnt==0 且正在推进）用于推 vcnt
    wire line_end = h_last && pixel_en;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            hcnt     <= 12'd0;
            vcnt     <= 12'd0;
        end
        else if (line_end) begin
            hcnt <= 12'd0;
            if (v_last) vcnt <= 12'd0;
            else        vcnt <= vcnt + 12'd1;
        end
        else if (pixel_en) begin
            hcnt <= hcnt + 12'd1;
        end
    end

    // 输出寄存器：与 hcnt/vcnt 同一拍推进，保证 pix_x/pix_y 与 lcd_de 严格对齐
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            lcd_hs   <= 1'b1;
            lcd_vs   <= 1'b1;
            lcd_de   <= 1'b0;
            pix_x    <= 12'd0;
            pix_y    <= 12'd0;
            frame_st <= 1'b0;
            line_st  <= 1'b0;
        end
        else if (pixel_en) begin
            frame_st <= 1'b0;
            line_st  <= 1'b0;

            lcd_hs <= ~(hcnt < h_sync);
            lcd_vs <= ~(vcnt < v_sync);

            lcd_de <= h_act && v_act;
            if (h_act && v_act) begin
                pix_x <= hcnt - h_sum[11:0];
                pix_y <= vcnt - v_sum[11:0];
                if (hcnt == h_sum[11:0]) line_st <= 1'b1;
                if ((hcnt == h_sum[11:0]) && (vcnt == v_sum[11:0])) frame_st <= 1'b1;
            end
            else begin
                pix_x <= 12'd0;
                pix_y <= 12'd0;
            end
        end
    end

endmodule
