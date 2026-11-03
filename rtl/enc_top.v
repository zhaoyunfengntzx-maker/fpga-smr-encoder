//=============================================================================
//  enc_top.v —— 正余弦细分编码器 顶层
//  目标器件：Xilinx Artix-7 XC7A35TFGG484-2（正点原子 达芬奇-lite）
//  工具：Vivado / Vitis 2026.1（本机实跑；早期注释写的 2020.2+ 是上机前的假设）
//-----------------------------------------------------------------------------
//  系统概述
//    用一片通用 FPGA 实现 iC-Haus iC-TW28（10bit 正余弦细分器）的全部功能，
//    并扩展多协议输出接口：
//      AD9238 双通道 12bit 同步采样 -> 抽取 -> 六参数误差校正(含数字 AGC)
//      -> 16bit 全流水 CORDIC atan2 -> PI 环路滤波 -> 粗精融合/多周期计数
//      -> ABZ / UVW / SPI 三种输出
//
//  时钟方案（v1：单时钟域，零 IP、零 CDC）
//    clk = 板载 50MHz（V4），作为全系统唯一时钟
//    ad_clk = clk 经 ODDR 转发给 AD9238 的 CH1_CLK/CH2_CLK
//      v9 及以前：D1=0/D2=1（反相 180°）⇒ 数据在下一个 clk 上升沿捕获，建立余量约 3ns
//      v10 起  ：D1=1/D2=0（同相）    ⇒ 捕获裕量约 13ns（2026-10-12 相位判别实验，见 §1.57）
//    ADC 数据在 clk 上升沿捕获（见 constr/enc_top.xdc）
//
//  延迟预算（@50MHz）：140(ADC内部7拍) + 60(捕获3) + 70(抽取) + 60(校正3)
//                     + 380(CORDIC 19 拍, NITER=17) + 60(PI 3) + 60(ABZ 3) ≈ 830 ns
//    对比 iC-TW28 手册给出的 1.5 µs（轻滤波）/ 1.9 µs（重滤波），快约 1.8 倍。
//    若接受 1.19 LSB 的 CORDIC 误差，可把 NITER 降到 16 -> 总延迟约 810 ns。
//
//  系统概述
//    · 所有子模块的接口以 rtl/SPEC_interface_contract.md 为唯一基准
//    · 角度一律用"周期归一化"16bit：0..65535 对应 0..360°（电角度/一个 sin-cos 周期）
//    · 本工程用任意波形发生器替代 SMR 传感头做定量标定与测试；
//      输入接口对 SMR / TMR / AMR / 光电 / 旋变 等任何正交信号源均兼容
//
//  资源估计：约 5500 LUT(26%) / 10 DSP(20%) / 少量 BRAM
//=============================================================================
`timescale 1ns / 1ps

// ★ RTL 版本号（SPI 只读 0x05F2/0x05F3）——解决"板上跑的到底是哪一版"的问题：
//   v5 及更早的位流读该地址返回 0，v6 恢复 16'h0006，v7（2026-10-11）= 16'h0007，
//   v8（2026-10-11，已上板）= 16'h0008，
//   v9（2026-10-11，工作树）= 16'h0009（Z 脉宽按手册改为 (z_width+1) 个边沿步，
//   见下面 RTL_BUILD_ID 声明处）。
//   v10/v11（2026-10-12）= 16'h000A / 16'h000B（两路 ODDR 由反相改同相 + 配套
//   XDC 输入延迟修正，见 docs/DEV_STATUS.md §1.57）。
//   v12（2026-10-12，工作树）= 16'h000C（**UART 遥测帧布局 v2**：off8..11 由
//   amp_sq 改为 io_state / 0xA2 标记 / io_flags / 保留 ⇒ 上位机可实时看 ABZ/UVW
//   逻辑电平；帧长仍 18 字节，见 rtl/uart_scope.v 顶部「帧布局 v2」）。
//   以后每次改 RTL 都要改这里（模块内的 localparam RTL_BUILD_ID，见下面的声明处）。

module enc_top #(
    // ---- 角度与位置字长 ----
    parameter integer AW        = 16,     // 电角度位宽（每周期 2^AW）
    parameter integer FRAC      = 8,      // 环路滤波的扩展小数位
    // ---- 抽取率（log2）----
    parameter integer LOG2DEC   = 2,      // 4 倍过采样抽取
    // ---- 虚拟索引（Z）周期：每 2^POLE_BITS 个输入周期产生一个 Z ----
    //      默认 6 -> 每 64 个输入周期一个 Z，对应 64 极对磁环转一圈
    //      （真实系统中该信号应来自 ZERO 差分输入或霍尔/磁阻索引通道）
    //      ENC_EI58：EI58C9.25-2048 正余弦编码器—?2048 周期/—?
    //      -> POLE_BITS=11，每—?—?—?虚拟 Z
    parameter integer POLE_BITS = 11,
    // ---- UART 遥测 ----
    parameter integer BAUD_DIV   = 25,    // 50MHz / 2Mbaud
    parameter integer SAMPLE_DIV = 5000,  // 50MHz / 5000 = 10kHz 帧率
    // ---- AB 限频换算用的时钟周期（ns） ----
    parameter integer CLK_PERIOD_NS = 20, // 50 MHz
    // ---- 角度与位置字长 ----
    //      发布配置 20：50 MHz 下 2^20 拍 ≈ 21 ms（真实器件上电稳定时间）
    //      ★ 仿真专用：顶层集成测试台若把该参数改小（如 4），POR 时间从 ~21 ms
    //        降到几十个时钟；否则跑到复位释放需要 100 万拍，顶层功能无法验证。
    //        该参数只改"POR 计数深度"，不改变复位释放后的任何逻辑，综合时按
    //        发布配置取 20 即可。
    parameter integer POR_BITS  = 20
)(
    input  wire        sys_clk,           // 50 MHz，引脚 V4
    input  wire        key_n,             // 按键（低有效）：按一下 = 一键标定

    // ---- AD9238 接口（达芬奇-lite J6 扩展口，28 根 IO）----
    //  ★ 载板上 CH1_CLK(ad_clk) 与 CH2_CLK(ad_clk2) 是**两根独立网络**
    //    （`AD1CLK`=J6-26+U1-63 CLK_A，`AD2CLK`=J6-9+U1-18 CLK_B，中间无缓冲器、
    //    无板上晶振），因此必须用两个 FPGA 输出分别驱动，只接一根会让 B 通道
    //    完全没有时钟。两路 ODDR 参数完全相同 ⇒ 同相位、同抖动。
    output wire        ad_clk,            // 采样时钟 A → 载板 J6-26 / AD1CLK
    output wire        ad_clk2,           // 采样时钟 B → 载板 J6-9  / AD2CLK
    input  wire [11:0] ad_ch1_d,          // CH1 = sin（偏移二进制）
    input  wire [11:0] ad_ch2_d,          // CH2 = cos（偏移二进制）
    input  wire        ad_ch1_otr,
    input  wire        ad_ch2_otr,

    // ---- ABZ / UVW 输出 ----
    output wire        a_out,
    output wire        b_out,
    output wire        z_out,
    output wire        u_out,
    output wire        v_out,
    output wire        w_out,

    // ---- v74：原三根从站引脚（MA/SL/SLO）已释放，J5-11/12/13 不再占用 ----
    //   屏幕"累计转数"早已走内部多圈位置（pos_acc），不依赖外部从站链路。

    // ---- 配置 SPI 从站 ----
    input  wire        spi_sck,
    input  wire        spi_ss_n,
    input  wire        spi_mosi,
    output wire        spi_miso,

    // ---- 角度与位置字长 ----
    output wire [3:0]  led,
    output wire        uart_tx,
    output wire        irq_n,

    // ---- 千兆以太网（B2）：YT8531C，RGMII + MDIO ----
    //  —? MDIO/MDC 暂不使用：PHY 默—?—配—?（自协商 + 内部 RX 延时）已够用—?
    //    省掉—?—? 2.5 MHz —? MDIO 状—?—机（参考—?—点原子例程同样不用）—??
    output wire        phy_rst_n,         // V18
    output wire [3:0]  eth_txd,           // U17/U18/P14/R14
    output wire        eth_txc,           // AA18
    output wire        eth_tx_ctl,        // AB18
    input  wire [3:0]  eth_rxd,           // AA19/AB20/V17/W17
    input  wire        eth_rxc,           // Y18
    input  wire        eth_rx_ctl,        // V19

    // ---- UART→SPI 桥的接收脚（板载 USB 串口 CH340E 的 TXD → FPGA）----
    //  ★ 这一行**故意不带尾逗号**：它后面的 DISP_TAP 端口是可选的（见下方 ifdef），
    //    逗号必须也跟着一起进条件块。否则不定义宏时端口表会以 `uart_rx,` 结尾，
    //    而 `, )` 在 Verilog-2001 里是语法错误。
    input  wire        uart_rx

    // ---- 显示屏 UI 只读抽头（实验专用，见下方 `ifdef 说明）----------------
    //  ★ 这条端口**只存在于实验构建里**：整段用 `ifdef ENC_DISP_TAP 包住，
    //    生产构建（synth_check.tcl / 上板位流）不定义该宏，端口根本不存在，
    //    因此 enc_top 的端口清单、constr/enc_top.xdc、pinout_verify 的 [E] 项
    //    与 v12 位流行为**完全不变**。
    //  ★ 为什么必须这样做：不加守卫的话，375 bit 的未约束端口会立刻触发
    //    UCIO-1 并被打到随机引脚上，同时 tools/pinout_verify.py 的
    //    "enc_top 全部端口都有 PACKAGE_PIN" 自查会红 —— 一个实验探针
    //    不—?—有能力损—?—已签核的生产构建—??
    //  ★ `ENC_DISP_TAP` **永远不许**出现在生产构建脚本里（tools/synth_disp.tcl
    //    是唯一合法使用者）。定义它的构建只能用来量时序/资源，不能出交付位流。
    //  ★ 位序即契约（`disp_tap` 总长 **376** bit，字段定义见
    //    rtl/SPEC_interface_contract.md §2.2）：
    //      [15:0]   angle     电角度，0..65535 = 0..360°
    //      [31:16]  s_cor     校正后 sin（有符号）
    //      [47:32]  c_cor     校正后 cos（有符号）
    //      [79:48]  pos_full  全周期位置（32 bit）
    //      [87:80]  io_state  {limiter_active,dir,w,v,u,z,b,a}
    //      [95:88]  io_flags  {amp_bad,cor_sat,uwven,abzen,uvw_warn,z_win,lag_fat,lag_warn}
    //      [103:96] stat_byte  TW28 兼容状态字
    //      [113:104] cfg_inter 倍频率
    //      [116:114] cfg_div   分频率
    //      [121:117] cfg_pairs 极对数
    //      [122]     cfg_abzen
    //      [123]     cfg_uwven
    //      [124]     calib_busy
    //      [125]     calib_done
    //      [126]     link_crc_err
    //      [127]     otr_lat
    //      [128]     amp_low | amp_high
    //      [129]     lag_limit | lag_warn
    //      [130]     limiter_active
    //      [131]     z_window
    //      [132]     uvw_freq_warn
    //      [133]     1'b0（保留位）
    //    ---- 以下为 v14 追加（P6 设置页要显示**寄存器当前值**，其中 6 个在 v13
    //         的抽头里没有，只能扩总线）。[133:0] 一位没动，新字段一律追加在
    //         [133] 以上 —— 这正是把 [133] 留成保留位的用途。
    //         右边全部是 reg_file.v 的既有 `cfg_*` 输出（都是 reg 直出，不是
    //         组合中间量），代价只是每根 net 多 1 个负载（屏侧的输入寄存器）。
    //      [138:134] cfg_hyst_ab   AB 迟滞（0x0103[4:0]）
    //      [146:139] cfg_ablimit   AB 限频上限（0x0106，0..255）
    //      [150:147] cfg_zwidth    Z 脉宽（0x0108[3:0]）
    //      [162:151] cfg_zphase    Z 相位（0x0109/0x010A，单位 360/4096）
    //      [178:163] cfg_uvwph     UVW 相位（0x010B，单位 2^16/周期）
    //      [182:179] cfg_pol       {uvwpol,zpol,bpol,apol}（0x010C，r_output 的 bit4/2/1/0）
    //    ---- 以下为 v15 追加（P7 标定页要显示**标定六参数当前值**与实测幅值）。
    //         这些量在 reg_file.v 里早就是既有输出/输入，所以本版**不需要新增
    //         寄存器、也不需要改 reg_file.v** —— 只是把已有的线接到抽头上，
    //         [182:0] 一位没动。右边全部是已在寄存器里的既有信号（reg 直出，
    //         不是组合中间量），符合第 13.5 节的只读快照规矩。
    //      [198:183] cfg_ofs_s     正弦偏置 Q1.15 有符号（0x0510/11）
    //      [214:199] cfg_ofs_c     余弦偏置 Q1.15 有符号（0x0512/13）
    //      [230:215] cfg_gain_s    正弦增益 Q1.15 无符号（0x0514/15，32768 = 1.0）
    //      [246:231] cfg_gain_c    余弦增益 Q1.15 无符号（0x0516/17）
    //      [262:247] cfg_phase_k   正交误差系数 Q1.15 有符号（0x0518/19）
    //      [278:263] cfg_shift     {12'b0, cfg_shift_c, cfg_shift_s}—?0x051A[3:0]—?
    //      [310:279] stat_amp_sq   实测 s²+c² Q2.30（0x0530..0x0533，只读）
    //    ---- 以下为 v21 追加（P7 要把实测幅值显示成**百分比**，就需要"百分比是
    //         相对谁"的基准 —— 编码器的幅值判据就是 0x0520/0x0524 这两个门限，
    //         取它—?当基准才不会出现"屏上百分比与编码器告警判—?不是—?—?口径"—?
    //         两个都是 reg_file.v 的 `cfg_*` 寄存器直出（不是组合中间量），
    //         [310:0] 一位没动，新字段追加在最高位 —— 与 v14/v15 同一套追加规矩。
    //      [342:311] cfg_amp_low_sq   幅值下限平方 Q2.30（0x0520..0x0523，默认 (0.60)²·2³⁰）
    //      [374:343] cfg_amp_high_sq  幅值上限平方 Q2.30（0x0524..0x0527，默认 (1.20)²·2³⁰）
    //    ---- 以下为 v22 追加（C3：屏上的"纯链路静默"空态）----
    //         该空态原由链路心跳驱动；v74 链路模块删除后，[375] 保留为**恒 0**
    //         的保留位（位图不重排，见下方位序契约），屏侧空态改由幅值/状态位
    //         承担。[374:0] 一位没动。
    //      [375]     link_lost  保留位，恒 0（原为链路静默）

`ifdef ENC_DISP_TAP
    ,
    output wire [375:0] disp_tap
`endif
);

    localparam integer ZW = AW + FRAC;                  // 扩展位置位宽
    localparam integer CYCLE_BITS = 16;                 // 多周期计数位宽
    // 帧位宽—?—由 POLE_BITS 派生：默—? 6 -> 22/10（与 v13 完全—?致）—?
    // ENC_EI58 —? 11 -> 27/5。原先硬编码 22/10—?2048 p/r 会把单圈字截—? 1/32 —?—?
    // v63：由 POLE_BITS 派生，不再硬编码。EI58/转台 2048 周期/转
    //       -> 单圈 = 11 bit 周期计数 + 16 bit 电角度 = 27，多圈 = 16-11 = 5。
    //       老配置 POLE_BITS=6 时自动回到 22/10，与 v62 位流一致。
    localparam integer ST_BITS_L = POLE_BITS + AW;          // 单圈位数（27，保留）
    localparam integer MT_BITS_L = CYCLE_BITS - POLE_BITS;  // 多圈位数（5，保留）
    // ★ RTL 版本号（SPI 只读 0x05F2/0x05F3）：v5 及以前读回 0，v6 = 0x0006，v7 = 0x0007，
    //   v8 = 0x0008，v9 = 0x0009，v10 = 0x000A—?
    //   每次改 RTL（尤其是改了标定/角度路径）都必须递增，否则上板后无法区分版本。
    //   v7（2026-10-11）内容：① 环路增益复位值改纯 P（见 rtl/reg_file.v 的 r_filt_k）；
    //   ② 0x0500/0x0501 的 ST/MT 位宽复位值订正为 22/10（与 ST_BITS_L/MT_BITS_L 一致）。
    //   v8（2026-10-11）内容：
    //   ① 本文件的 loop_filter 例化加 .GATE_STATE(1)：环路状态只在 in_valid（12.5 MHz）拍
    //      更新，修掉"状态每 clk 迭代而 in_valid 只有 12.5 MHz ⇒ 每样本增益 ×4"（§1.39/§1.40、
    //      §1.42 速率假设审计第 9/10 条）；
    //   ② 配套把环路增益复位值改为 kp=2/ki=3（见 rtl/reg_file.v 的 r_filt_k）：门控后增益
    //      恢复"每样本"语义，档位按全链路 A/B 回放重调（sim/tb_loop_abz_chain.v 的 B 链 kp2/ki3：
    //      AB 跳变 126 = 理想计数、|d| 最大 11 LSB、0 次方向反转）；
    //   ③ 另含 v7 位流不含的两项：lag 阈值按 (b) 重标定为 45°/180°（§3 item 18）、
    //      ABZ 过速双向钳位 + r_ovl 过速计数（§3 item 16）。
    //   v9（2026-10-11）内容：
    //   ① Z 脉宽按 TW28 手册改为 (z_width + 1) 个原始边沿步（rtl/abz_gen.v：新增
    //      Z_PULSE_W=5、r_z_left/z_pulse_n 加宽、z_pulse_n = z_width + 1）——
    //      v8 及以前是 z_width 步（默认短 20%，z_width=0 时无 Z 而手册 1 步），
    //      由仿真 C5（2042 拍 ≈ 4×512）与板上二值实验（0x0108=0x4000 ⇒ 无脉冲）双证，
    //      见 docs/DEV_STATUS.md §1.47。
    //   v10（2026-10-12）内容：
    //   ① **ADC 采样时钟相位判别实验**：两路 ODDR 由 D1=0/D2=1 改为 D1=1/D2=0
    //      （ad_clk 上升沿与 clk 上升沿同相 ⇒ 捕获裕量 4..8ns → 14..18ns）。
    //      背景：v9 相位下 D 分支毛刺经逐位归因为"单拍、只错 D11-D8、只在两通道
    //      高位组同拍翻转（256 格点）时发生"（§1.56 ⑦ / §1.57）⇒ 用本版判别
    //      "根因在 ADC→FPGA 捕获接口" 还是 "根因在 ADC 内部"。
    //   ② 除相位外不改任何逻辑/参数 ⇒ 本版与 v9 的行为差异只可能来自采样相位。
    localparam [15:0] RTL_BUILD_ID = 16'h0015;   // v70：位置累加修复 + 2048 PPR

    //=========================================================================
    // 1. 时钟与复位（单时钟域，不使用 MMCM / 不使用任何 IP）
    //=========================================================================
    // sys_clk 经 BUFG 作为全系统唯一时钟（显式例化 BUFG，避免推断歧义）
    wire clk_i;
    BUFG u_bufg_clk (.I(sys_clk), .O(clk_i));

    // 说明：Xilinx 的 FDRE 上电时 INIT=0，因此 por_cnt 从上电起自由计数，
    //       计到 2^20 时（50MHz 下约 21ms）释放复位。这是一个自启动的 POR。
    //       该—?—数器本—?不—?—位，否则无法自—?动—??
    //
    // ★ 仿真必备：上面的"FDRE 上电 INIT=0"是**器件特性**，xsim 默认不建模它，
    //   于是 por_cnt 保持 X、rst_n 恒为 X、全芯片所有寄存器都是 X（顶层集成
    //   测试台 tb_enc_top 实测 status 字 otr/amp_ok/cor_sat/irq_n 全为 x）。
    //   下面的初值 20'd0 在综合与仿真中都表示"上电初值 0"，既保留自启动语义，
    //   又让仿真与实际器件一致。写综合时等价于 FDRE 的 INIT=0，不改变硬件行为。
    reg [POR_BITS-1:0] por_cnt = {POR_BITS{1'b0}};
    wire       rst_n = por_cnt[POR_BITS-1];

    always @(posedge clk_i) begin
        if (!por_cnt[POR_BITS-1]) begin
            por_cnt <= por_cnt + 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // ADC 采样时钟：clk 的副本，经 ODDR 转发到引脚
    //   v9 及以前：D1=0/D2=1 -> 在 clk 下降沿变高 -> ad_clk 上升沿比 clk 上升沿晚 10ns
    //     ⇒ ADC 数据（ad_clk 上升沿后 tPD=2..6ns）在下一个 clk 上升沿被捕获，
    //       捕获沿只比数据有效沿晚 4..8ns。首板实测在该相位下出现"单拍、只错 D11-D8"
    //       的坏码（逐位归因见 docs/DEV_STATUS.md §1.57）。
    //   ★ v10（2026-10-12 相位判别实验）：改 D1=1/D2=0 -> ad_clk 上升沿与 clk 上升沿同相
    //     ⇒ ADC 在 t=0 采样、t+2..6ns 出数据，我们仍在 t=+20ns 的 clk 上升沿捕获，
    //       捕获裕量从 4..8ns 提到 14..18ns（+10ns）。
    //     ★ 判别意义：改相位后坏码率剧变 ⇒ 根因在 ADC→FPGA 捕获接口（本相位即可修）；
    //       坏码率不变 ⇒ 根因在 ADC 内部（管线/地弹），相位不是控制量。
    //
    // ★ 两路各用一个 ODDR（而不是一根输出驱动两个引脚）：
    //   载板的 AD1CLK / AD2CLK 是两根独立网络，同一根 FPGA 输出经两个 OBUF
    //   也可以，但显式两路 ODDR 的相位关系由同一个 clk_i 确定，更直观、
    //   且两个钟的 skew 由布线决定（同一 bank，约百 ps 量级）。
    //-------------------------------------------------------------------------
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_ad_clk_oddr (
        .Q  (ad_clk),
        .C  (clk_i),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_ad_clk2_oddr (
        .Q  (ad_clk2),
        .C  (clk_i),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );

    //-------------------------------------------------------------------------
    // 按键去抖 + 一键标定触发（对标 iC-TW28 的 xCALIB 引脚）
    //-------------------------------------------------------------------------
    wire key_sync;
    cdc_sync2 #(.WIDTH(1)) u_key_sync (
        .clk     (clk_i),
        .rst_n   (1'b1),
        .d_async (key_n),
        .q_sync  (key_sync)
    );

    reg [15:0] db_cnt;
    reg        key_db;
    always @(posedge clk_i) begin
        if (!rst_n) begin
            db_cnt <= 16'd0;
            key_db <= 1'b1;                 // 复位期间视为"未按下"
        end
        else if (key_sync != key_db) begin
            if (db_cnt == 16'hFFFF) begin   // 稳定 1.3ms 才认账
                key_db <= key_sync;
                db_cnt <= 16'd0;
            end
            else begin
                db_cnt <= db_cnt + 1'b1;
            end
        end
        else begin
            db_cnt <= 16'd0;
        end
    end

    reg key_db_d;
    always @(posedge clk_i) begin
        if (!rst_n) key_db_d <= 1'b1;
        else        key_db_d <= key_db;
    end
    wire key_fall = key_db_d & ~key_db;     // 按下瞬间的 1 拍脉冲

    //=========================================================================
    // 2. ADC 采集 -> 提升到 Q1.15 -> 抽取
    //=========================================================================
    wire signed [11:0] s_raw, c_raw;
    wire               otr_lat, adc_valid;
    // ADC sticky OTR 的清位脉冲：来自寄存器写口（0x0405 bit0，W1C）。
    // ★ 2026-10-10 上板实测修复：原先这里硬接 1'b0，OTR 一旦锁存就永久保持
    //   （led[0] 常亮、irq_n 常低），降幅度/按 KEY0 都无效，只能重配置器件。
    wire               clr_otr_adc;

    ad9238_capture #(
        .DW (12)
    ) u_capture (
        .clk_cap   (clk_i),
        .rst_n     (rst_n),
        .ch1_d     (ad_ch1_d),
        .ch2_d     (ad_ch2_d),
        .ch1_otr   (ad_ch1_otr),
        .ch2_otr   (ad_ch2_otr),
        .en        (1'b1),
        .clr_otr   (clr_otr_adc),
        .s_raw     (s_raw),
        .c_raw     (c_raw),
        .otr       (otr_lat),
        .adc_valid (adc_valid)
    );

    // 12bit 补码 -> Q1.15（左移 4 位；范围 -2048..2047 -> -32768..32752，不会溢出）
    wire signed [15:0] s_ext = {{4{s_raw[11]}}, s_raw};
    wire signed [15:0] c_ext = {{4{c_raw[11]}}, c_raw};
    wire signed [15:0] s_q15 = s_ext <<< 4;
    wire signed [15:0] c_q15 = c_ext <<< 4;

    wire signed [15:0] s_dec, c_dec;
    wire               dec_valid;

    decim_avg #(
        .DW      (16),
        .LOG2DEC (LOG2DEC)
    ) u_dec_s (
        .clk        (clk_i),
        .rst_n      (rst_n),
        .din        (s_q15),
        .din_valid  (adc_valid),
        .dout       (s_dec),
        .dout_valid (dec_valid)
    );

    decim_avg #(
        .DW      (16),
        .LOG2DEC (LOG2DEC)
    ) u_dec_c (
        .clk        (clk_i),
        .rst_n      (rst_n),
        .din        (c_q15),
        .din_valid  (adc_valid),
        .dout       (c_dec),
        .dout_valid ()                      // 两路共用 s 路的 dec_valid（同参数同相位）
    );

    //=========================================================================
    // 3. —?参数—?—?校—?—（系数来自寄存器组或标定状态机—?
    //=========================================================================
    wire signed [15:0] cfg_ofs_s, cfg_ofs_c, cfg_gain_s, cfg_gain_c, cfg_phase_k;
    wire        [1:0]  cfg_shift_s, cfg_shift_c;
    wire signed [15:0] res_ofs_s, res_ofs_c, res_gain_s, res_gain_c, res_phase_k;
    wire        [1:0]  res_shift_s, res_shift_c;
    wire               calib_we, calib_busy, calib_done, calib_trunc, calib_start_cfg;
    wire [2:0]         calib_retry;                 // ★ 窗口非整周期的重试次数（0x0502[7:5]）
    wire               calib_bad;                   // ★ 重试用尽仍非整周期（0x0502[4]）
    // ★ v6 诊断快照（最近一次关门的窗口统计；SPI 只读 0x050A..0x050D）
    wire        [17:0] calib_dbg_int_min, calib_dbg_int_max, calib_dbg_nsamp_cls;
    wire        [15:0] calib_dbg_wcnt_cls;
    // ★ v6 诊断：周期脉冲累计数（在下方脉冲发生器处计数，SPI 只读 0x0540/0x0541）。
    //   必须在此声明（reg_file 例化更早，否则会被当成隐式 wire）。
    reg         [15:0] cyc_pulse_cnt;
    // ★ v73（2026-11-02 上板调试）：Z 脉冲上升沿计数器。
    //    只用于"Z 到底有没有出、频率对不对"的量化判据（读 0x054A..0x054D），
    //    不参与任何功能逻辑；32 位，满 2^32 自然回绕。
    //    必须在此声明（reg_file 例化更早，否则会被当成隐式 wire，ModelSim 报 vlog-2388）。
    reg             z_out_d;
    reg         [31:0] z_pulse_cnt;
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            z_out_d     <= 1'b0;
            z_pulse_cnt <= 32'd0;
        end else begin
            z_out_d <= z_out;
            if (z_out & ~z_out_d)
                z_pulse_cnt <= z_pulse_cnt + 32'd1;
        end
    end
    wire        [15:0] calib_addr;
    wire        [7:0]  calib_wdata;
    wire        [3:0]  calib_state_dbg;

    // sc_correct 用的系数就是 reg_file 里那 6 组寄存器（use_* = cfg_* = r_*）。
    // ★ 2026-10-10 更正（P0-3 期间由 sim/tb_enc_top.v TEST F 实测）：标定结果是经
    //   calib_we/calib_addr/calib_wdata **写回同一批寄存器**（rtl/reg_file.v:273-288、
    //   :490-496 的 cfg_* = r_*），因此主机读回 0x0510..0x051A **看到的就是生效值**
    //   （与 calib_ctrl 的 res_* 逐位相同，已由 TEST F 的 F6a..F6g 断言）。
    //   旧注释说"寄存器 read-back 仍显示 SPI 写入值"是过时描述（那是 res_* 未接回的旧版本）。
    //   ★ 2026-10-10 修复第六个真问题（docs/DEV_STATUS.md §1.18）：此前 calib_ctrl 累加的
    //     是 sc_correct 的**输出** s_cor/c_cor，所以第二次一键标定看到的是"已被第一次标定
    //     校正过"的信号，解出来的系数会往回走（实测 GAIN_S 30325→32241 朝单位增益 32768
    //     回归、PHASE_K 15→−54、OFS_S 15→−31）⇒ 一键标定不可重复执行。
    //     现在标定状态机改为累加**校正前**的 s_dec/c_dec（in_valid 用同路的 dec_valid），
    //     —?"标定永远测量传感器原始信号，而不—?它自己的校—?—结—?"—?
    //       · 首次标定（默认单位系数）与修复前等价 —— sc_correct 此刻是恒等映射；
    //       · —?二—?—标定测量同—?—?原—?—信—? —? 解出与—??—?次一致的系数（幂等）—?
    //         已由 sim/tb_enc_top.v TEST F 的 F11a..F11f 断言（含容差判据）。
    //       · 额—?—好处：主机若写入了错—??系数，一—?标定仍然收敛到—?—确的绝对参数，
    //         而不—?"相—?—于错—??系数"收敛—?
    // ★ v9（S4）偏置慢跟踪：bias_track 观测的是**校正后**的 s_cor/c_cor，
    //   输出的是"残余偏置"，所以叠加在寄存器偏置上（cfg_ofs + bias）构成闭环：
    //   偏置漂移 → 残余非零 → EMA 学到 → 抵消。16 位饱和防溢出。
    wire signed [15:0] bias_s, bias_c;
    wire               cfg_bias_en;      // ★ v9.1：0x0122 bit1，默认 0（偏置跟踪关闭）
    wire               bias_valid, bias_big;
    wire               lock_track;            // = (lock_state == TRACK)，在 lock_sm 之后赋值
    wire signed [16:0] ofs_s_sum = {cfg_ofs_s[15], cfg_ofs_s} + {bias_s[15], bias_s};
    wire signed [16:0] ofs_c_sum = {cfg_ofs_c[15], cfg_ofs_c} + {bias_c[15], bias_c};

    wire signed [15:0] use_ofs_s   = (ofs_s_sum > 17'sd32767)  ? 16'sd32767  :
                                     (ofs_s_sum < -17'sd32768) ? -16'sd32768 : ofs_s_sum[15:0];
    wire signed [15:0] use_ofs_c   = (ofs_c_sum > 17'sd32767)  ? 16'sd32767  :
                                     (ofs_c_sum < -17'sd32768) ? -16'sd32768 : ofs_c_sum[15:0];
    wire        [15:0] use_gain_s  = cfg_gain_s;
    wire        [15:0] use_gain_c  = cfg_gain_c;
    wire signed [15:0] use_phase_k = cfg_phase_k;
    wire        [1:0]  use_shift_s = cfg_shift_s;
    wire        [1:0]  use_shift_c = cfg_shift_c;

    wire signed [15:0] s_cor, c_cor;
    wire               cor_valid, cor_sat;

    sc_correct #(
        .DW (16)
    ) u_correct (
        .clk       (clk_i),
        .rst_n     (rst_n),
        .s_in      (s_dec),
        .c_in      (c_dec),
        .in_valid  (dec_valid),
        .ofs_s     (use_ofs_s),
        .ofs_c     (use_ofs_c),
        .gain_s    (use_gain_s),
        .gain_c    (use_gain_c),
        .shift_s   (use_shift_s),
        .shift_c   (use_shift_c),
        .phase_k   (use_phase_k),
        .s_out     (s_cor),
        .c_out     (c_cor),
        .out_valid (cor_valid),
        .sat_flag  (cor_sat)
    );

    //=========================================================================
    // 3b. ★ v9（S4）偏置慢跟踪
    //     只在环路锁定（TRACK）时跟踪：上电瞬态、掉锁瞬间都不许把偏置学进去。
    //     restart 接 calib_we（一键标定的写回脉冲）⇒ 每次重新标定都把窗口清零重学。
    //   ★ v9.1：en 再与 cfg_bias_en（0x0122 bit1，复位值 0）相与 ⇒ **默认关闭**。
    //     第一版 EMA 是反馈环、实测把环路带崩（见 rtl/bias_track.v 头注释），
    //     改成"分块积分"后仍保持默认关闭：上板首版必须与 v64 行为完全一致，
    //     主机显式置位并核对 0x0138..0x013C 后才启用。
    //=========================================================================
    bias_track #(
        .LOG2N (15)                          // 窗口 = 2^15 样本 = 2.62 ms @12.5 MHz
    ) u_bias (
        .clk       (clk_i),
        .rst_n     (rst_n),
        .in_valid  (cor_valid),
        .s_in      (s_cor),
        .c_in      (c_cor),
        .en        (cfg_bias_en && lock_track),
        .restart   (calib_we),
        .bias_s    (bias_s),
        .bias_c    (bias_c),
        .bias_valid(bias_valid),
        .bias_big  (bias_big)
    );

    //=========================================================================
    // 4. 幅值监视（s²+c²）
    //=========================================================================
    wire        [31:0] cfg_amp_low_sq, cfg_amp_high_sq;
    // ★ v9（S2）延迟前馈配置（来自 reg_file 0x0120..0x0122）
    wire        [15:0] cfg_tau_q8;
    wire               cfg_ff_en;
    // ★ v9（S5）全周补偿表配置与写口（来自 reg_file 0x0141..0x0145）
    wire               cfg_lut_en;
    wire               cfg_lut_probe;
    wire               lut_wr_en;
    wire        [11:0] lut_wr_addr;
    wire        [15:0] lut_wr_data;
    wire        [31:0] amp_sq;
    wire               amp_ok, amp_low, amp_high, amp_valid;

    amp_monitor #(
        .DW (16)
    ) u_amp (
        .clk         (clk_i),
        .rst_n       (rst_n),
        .s_n         (s_cor),
        .c_n         (c_cor),
        .in_valid    (cor_valid),
        .amp_low_sq  (cfg_amp_low_sq),
        .amp_high_sq (cfg_amp_high_sq),
        .amp_sq      (amp_sq),
        .amp_ok      (amp_ok),
        .amp_low     (amp_low),
        .amp_high    (amp_high),
        .out_valid   (amp_valid)
    );

    //=========================================================================
    // 5. 16bit 全流水 CORDIC atan2
    //=========================================================================
    wire [AW-1:0]   angle_raw;
    wire [17:0]     cordic_mag;
    wire            cordic_valid;

    cordic_atan2 #(
        .AW    (AW),
        .IW    (16),
        .NITER (17)                         // 16 级误差 1.19 LSB 超标；17 级 0.9375 LSB，Latency 19 拍
    ) u_cordic (
        .clk       (clk_i),
        .rst_n     (rst_n),
        .x_in      (c_cor),                 // cos 分量
        .y_in      (s_cor),                 // sin 分量
        .in_valid  (cor_valid),
        .angle     (angle_raw),
        .mag       (cordic_mag),
        .out_valid (cordic_valid)
    );

    //=========================================================================
    // 5b. 角度毛刺保持（2026-10-11 v5 新增）
    //=========================================================================
    //  背景（证据见 docs/DEV_STATUS.md §1.30/§1.31 与 sim/tb_enc_top.v 的 F13/F14）：
    //    v4 位流板上 20/20 轮标定全部正确，但 16/20 轮 `0x0502[7] win_bad`=1 且
    //    retry 用尽(3)。仿真 F13 用"单拍把 ADC 输入取反"**精确复现了同一签名**
    //    （retry_cnt=3、win_bad=1、int_min=25 / int_max=256），并证明 6 组标定系数
    //    与干净输入**逐位相同** ⇒ 板上报警来自"角度的单拍 gross 错值（≥22.5°）把
    //    滞回状—?—机多翻—?—? —? 多出—?—?周期脉冲"；因其—?—称（翻两—?—）且有界，—?阶矩
    //    不受影响—?
    //    但同一个错值会**直接进 PI 环路滤波器**（下面 :414 `.ang_in`）⇒ 位置输出
    //    可能被踢一下（用户早先"UVW/ABZ 波形乱乱的"反馈的一个嫌疑）；也会踢标定
    //    滞回的过零参考—??
    //  做法：与上一拍**有效**角度之差超过 ±ANG_GLITCH_MAX 时，本拍输出保持上一拍值
    //        （"hold last good"），最多保持一拍；纯组合前向路径、**不引入流水延迟**
    //        （滞回与环路滤波器看到的仍是与 cordic_valid 同拍的样本）。
    //  ★★ 2026-10-11 v6：阈值由 45°(8192) **收紧到 5.6°(1024)** —— 依据是板上实测：
    //    v5（45° 阈值）烧录后 20 轮标定的 retry/win_bad 与 v4 **完全没有改善**
    //    （v4b retry {3:16,2:2,0:2} → v5 {3:18,2:1,1:1}，win_bad 都在 17~18/20），
    //    说明真实扰动**达不到 45°**。量级上也说得通：单拍 ADC 错值若只错一个通道
    //    （半量程），atan2 最多偏 ~26°，足以翻 11.25° 的滞回、不足以触发 45° 的保持；
    //    F13 当初注入的是"两通道同时取反 = 180°"这一最猛情形 ⇒ "仿真通过"并不代表
    //    真实情形被挡住（这是判据设计的漏项，见 docs/DEV_STATUS.md §1.31/§1.32）。
    //  为什么 5.6° 仍然安全：1 kHz 输入抽取后单拍相位步进只有 0.029°（余量 190×）；
    //    角度噪声实测 ~0.1~0.5° rms ⇒ 1024 LSB 在 11σ 以上。阈值**故意取在滞回带
    //    CAL_HYS=2048 以下**：只要某个单拍跳变足以翻动滞回，它必然先被这里挡住。
    //    将来真实编码器跑到 ~20 kHz 电频率（≈0.58°/拍）仍安全；再高就调大此参数
    //    ——?? 它是参数，不—?魔数—?
    //  为什么不会破—?"整周期窗—?"：—?—常序列达不到阈值—?—相位完全不变；即使偶发保持
    //        一拍，也只把**那一拍**的脉冲检测推迟 ≤1 拍，而间隔判据的容差是
    //        ±1/12500，1.25 倍判据需要 ±1/4 周期的偏差 ⇒ 不可能被这 1 拍触发。
    //  ★ 与 :855-919 那段"已被否决的 MSB 去抖"的区别：那次用的是**随周期估计变化**
    //    的 lim 拍去抖，导致相邻脉冲间隔 = 2H ± Δlim ≠ 整周期（仿真实测 nsamp
    //    16367 ≠ 16384=64×256，幂等标定被破坏）。本设计阈值固定、且只在**错值本身**
    //    上动作，不改变—?—常脉冲的相—? —? 间隔严格不变—?
    localparam signed [AW-1:0] ANG_GLITCH_MAX = 16'sd1024;   // 5.6°（v6：原 45°）
    reg  [AW-1:0]        ang_prev;
    reg                  ang_seen;
    reg                  ang_held;      // 上一拍已经"保持"过 ⇒ 本拍必须接受原始值
    wire signed [AW-1:0] ang_delta  = $signed(angle_raw) - $signed(ang_prev);
    wire                 ang_glitch = ang_seen && !ang_held &&
                                      ((ang_delta >  ANG_GLITCH_MAX) ||
                                       (ang_delta < -ANG_GLITCH_MAX));
    wire [AW-1:0]        angle_filt = ang_glitch ? ang_prev : angle_raw;

    // ★ 为什么必须限制"最多保持一拍"（第一条实现漏掉了这一点，被 TEST B 抓住）：
    //   若允许连续保持，则一旦发生**真实的相位跳变**（例如上电/停机后相位阶跃，
    //   或仿真里 TEST B 把 ph 清零），ang_prev 会被冻结，而输入又在缓慢前进 ⇒
    //   差值长期 >45° ⇒ 滤波器**长期冻结角度**（实测：TEST B 里冻结约 3 万拍，
    //   环路输入被卡住，dut.angle 与参考相差最大 32768 LSB＝180°、32732 个采样
    //   超差 ⇒ B7-fwd-angle-tracks-phase 失败）。
    //   真实毛刺是"单个被采错的 ADC 转换"（经 4 拍抽取后就是 1 个坏样本），
    //   —?—?"—?挡一拍—?—随后无条件接受原—?——??"既—?—用又不会卡死：单拍毛刺—?挡掉—?
    //   真实阶跃—?延后—?拍就通过—?
    always @(posedge clk_i) begin
        if (!rst_n) begin
            ang_prev <= {AW{1'b0}};
            ang_seen <= 1'b0;
            ang_held <= 1'b0;
        end else if (cordic_valid) begin
            ang_seen <= 1'b1;
            ang_held <= ang_glitch;     // 本拍保持过 ⇒ 下一拍不再保持
            ang_prev <= angle_filt;     // 正常推进；被判为毛刺则保持上一拍值
        end
    end

    //=========================================================================
    // 5c. 角度毛刺诊断计数器（2026-10-11 v6 新增；SPI 只读）
    //=========================================================================
    //  目的：把"板上到底有没有毛刺、多大、多密"变成**可读数字**，不必依赖 ILA
    //        （1024 点 @50 MHz ⇒ 20.5 µs 窗口，随机撞到 ~750/s 毛刺的概率约
    //        0.5%/次捕获 ⇒ 实际抓不住）。
    //  用法：UART 读 0x0505..0x050E（毛刺分档 + 保持动作次数）与 0x0540（周期脉冲
    //        累计），隔一段时间再读一次；用**两次之差** ÷ 同期脉冲计数差（0x0540）
    //        ＝ **每个输入周期发生多少次毛刺**。这个比值与真实时间无关 ⇒ 不怕 UART
    //        慢、不怕丢帧。（工具：python tools\diag_counters.py --port COM6）
    //  分档（本文件角度域 65536 LSB = 360°；每个计数 16 位 = 低/高字节两个地址）：
    //        0x0505/06 > 1024 LSB (5.6°)    ← 与 5b 节保持阈值同档（真正被挡住的）
    //        0x0507/08 > 2048 LSB (11.25°)  ← 滞回带宽度（≥此值就能翻滞回 ⇒ v5 的漏网区）
    //        0x0509/0A > 4096 LSB (22.5°)
    //        0x050B/0C > 8192 LSB (45°)     ← v5 用的阈值（作对照）
    //        0x050D/0E：5b 节"保持"实际动作次数；与 0x0505 计数之差 = **连续**第 2 拍
    //                  及以后的毛刺（`ang_held` 只挡第一拍，这些会漏进 angle_filt ⇒
    //                  交给 4c 的 CONF_N 确认 + 窗口 1.25 倍判据兜底）
    //        0x05F2/53：rtl_build_id（v6 = 6 ⇒ 非 0 即本版）
    wire [AW-1:0] ang_abs_delta = ang_delta[AW-1] ? (~ang_delta[AW-1:0] + 16'd1)
                                                  : ang_delta[AW-1:0];
    reg  [15:0]   gl_cnt_1024, gl_cnt_2048, gl_cnt_4096, gl_cnt_8192, gl_hold_cnt;

    always @(posedge clk_i) begin
        if (!rst_n) begin
            gl_cnt_1024 <= 16'd0; gl_cnt_2048 <= 16'd0;
            gl_cnt_4096 <= 16'd0; gl_cnt_8192 <= 16'd0;
            gl_hold_cnt <= 16'd0;
        end else if (cordic_valid) begin
            if (ang_abs_delta > 16'd8192) gl_cnt_8192 <= gl_cnt_8192 + 16'd1;
            if (ang_abs_delta > 16'd4096) gl_cnt_4096 <= gl_cnt_4096 + 16'd1;
            if (ang_abs_delta > 16'd2048) gl_cnt_2048 <= gl_cnt_2048 + 16'd1;
            if (ang_abs_delta > 16'd1024) gl_cnt_1024 <= gl_cnt_1024 + 16'd1;
            if (ang_glitch)               gl_hold_cnt <= gl_hold_cnt + 16'd1;
        end
    end

    //=========================================================================
    // 6. PI 环路滤波
    //=========================================================================
    wire        [3:0]  cfg_kp;
    wire        [1:0]  cfg_ki;
    wire signed [ZW-1:0] pos_ext;
    wire               lag_limit, filt_valid;
    // ★ v9（S2）：环路积分器输出 = 每抽样点的位置增量（ω·T_sample），供延迟前馈与速度遥测
    wire signed [ZW-1:0] omega_pos;

    loop_filter #(
        .AW        (AW),
        .FRAC      (FRAC),
        // ★ v8（2026-10-11）：门控环路状态 ⇒ 只在 in_valid（cordic_valid = 12.5 MHz）拍更新。
        //   不门控时状态每个 clk（50 MHz）迭代，而样本只有 12.5 MHz ⇒ 每样本增益被放大 4 倍，
        //   ki=3 会使环路欠阻尼、把 CORDIC 噪声放大 ~5 倍（根因链见 §1.39/§1.40：
        //   板上 AB 边沿膨胀 2.7×、单拍角度抖动 ±5…8 LSB）。配套 kp/ki 复位值已重调为
        //   kp=2/ki=3（rtl/reg_file.v 的 r_filt_k），依据 sim/tb_loop_abz_chain.v 的 A/B 回放。
        //   ⚠ 模块默认值仍是 GATE_STATE=0（保持"每 clk 更新"的逐位契约，tb_loop_filter 与
        //   model/loop_filter_model.py 依赖它）——生产配置由本处显式指定。
        .GATE_STATE(1)
    ) u_filter (
        .clk       (clk_i),
        .rst_n     (rst_n),
        .ang_in    (angle_filt),
        .in_valid  (cordic_valid),
        .kp        (cfg_kp),
        .ki        (cfg_ki),
        .freeze    (calib_busy),
        .pos_out   (pos_ext),
        .lag_limit (lag_limit),
        .out_valid (filt_valid),
        .speed_out (omega_pos)
    );

    // 扩展位置 -> 周期内角度（取低 (AW+FRAC) 位的高 AW 位）
    wire [AW-1:0] angle = pos_ext[ZW-1:FRAC];

    //=========================================================================
    // 7. 虚拟索引（Z）门控窗
    //    真实系统中该信号来自 ZERO 差分输入或霍尔/磁阻索引通道；
    //    本工程用"每 2^POLE_BITS 个输入周期一个 Z"模拟 64 极对磁环转一圈。
    //    这样 Z 与多周期计数自洽，可完整演示 Z 门控、Z 相位与 Z 宽度。
    //=========================================================================
    wire signed [CYCLE_BITS-1:0] cycle_cnt;
    wire signed [CYCLE_BITS+AW-1:0] pos_full;
    wire               dir, wrap_pos, wrap_neg, pole_valid;
    wire signed [CYCLE_BITS-1:0] preset_val = {CYCLE_BITS{1'b0}};
    wire               z_window;

    pole_counter #(
        .AW (AW),
        .CW (CYCLE_BITS)
    ) u_pole (
        .clk          (clk_i),
        .rst_n        (rst_n),
        .angle        (angle),
        .in_valid     (filt_valid),
        .z_window     (z_window),
        .clr_on_z     (1'b0),             // ★ v71：Z 窗已与绝对角度过零对齐，不再用 Z 清零
                                          //   cycle_cnt（清零会让 mech_angle 跳变、UVW 误报频率越限，
                                          //   也破坏多圈计数）；v70 板上实际也是“从未清零”的行为
        .preset       (preset_val),
        .preset_en    (1'b0),
        .glitch_guard (4'd2),              // 跨零后屏蔽 2 拍，抑制 Z 附近的角度抖动误计数
        .cycle_cnt    (cycle_cnt),
        .pos_full     (pos_full),
        .dir          (dir),
        .wrap_pos     (wrap_pos),
        .wrap_neg     (wrap_neg),
        .out_valid    (pole_valid)
    );

    // 每 2^POLE_BITS 个电周期（= 1 圈）开一次 Z 门控窗。
    //
    // ★ v71（2026-11-02 审计修复）：旧实现 `cycle_cnt[POLE_BITS-1:0]==0` 的两个致命问题
    //   1) 窗宽 1 拍，且 pole_counter 的回绕比 angle 真正过零晚约 2 拍；abz_gen 的
    //      跨零沿寄存又在窗外清零 ⇒ z_load 永不成立，Z 一次都不出；
    //   2) pole_counter 的 phase_acc 是**从复位时刻开始累加**的展开相位，它的回绕点
    //      对应"复位时的绝对角度"而不是 0°。实测 tb_enc_top 里窗口出现在 angle=62466
    //      （≈343°）而不是 0°，与 ABZ 的 z_phase 跨零完全错位 ⇒ 即便加宽窗口也取不到
    //      跨零沿（回调挂起寿命 ttl 一直是 0）。
    //
    //   现在改为**直接用绝对角度过零**产生圈事件：ang_wrap_f/b 是 angle 从 >7/8 圈跳到
    //   <1/8 圈（或反向）的那一拍，恰好就是 z_phase=0 的跨零点；再用一个自由运行的
    //   rev_cnt 数电周期，低 POLE_BITS 位为 0 时为圈边界。事件式判断不受 clr_on_z 影响，
    //   天然保证"每圈恰好一次"，且与 ABZ/K 的 Z 相位对齐。
    localparam integer Z_WIN_CLKS = 6;                       // 窗宽（clk），> 2 拍读数延迟
    localparam [AW-1:0] ZW_TOP = (1 << AW) - (1 << (AW-3));  // 7/8 圈（如 57344）
    localparam [AW-1:0] ZW_LOW = (1 << (AW-3));              // 1/8 圈（如 8192）

    reg [AW-1:0] z_ang_prev;
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n)              z_ang_prev <= {AW{1'b0}};
        else if (filt_valid)     z_ang_prev <= angle;
    end

    wire ang_wrap_f = filt_valid & (z_ang_prev >= ZW_TOP) & (angle <= ZW_LOW);
    wire ang_wrap_b = filt_valid & (z_ang_prev <= ZW_LOW) & (angle >= ZW_TOP);

    // 自由运行的"电周期"计数（不在 Z 处清零，避免自我重触发）
    reg signed [CYCLE_BITS-1:0] rev_cnt;
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n)          rev_cnt <= {CYCLE_BITS{1'b0}};
        else if (ang_wrap_f) rev_cnt <= rev_cnt + 1'b1;
        else if (ang_wrap_b) rev_cnt <= rev_cnt - 1'b1;
    end

    wire z_idx_evt = (ang_wrap_f | ang_wrap_b) &&
                     (rev_cnt[POLE_BITS-1:0] == {POLE_BITS{1'b0}});

    reg [3:0] z_win_left;
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n)                    z_win_left <= 4'd0;
        else if (z_idx_evt)            z_win_left <= Z_WIN_CLKS[3:0];
        else if (z_win_left != 4'd0)   z_win_left <= z_win_left - 4'd1;
    end
    assign z_window = z_idx_evt | (z_win_left != 4'd0);

    //-------------------------------------------------------------------------
    // ★ 2026-10-28 修复：UVW 的输入必须是「机械角」，不是「正弦周期内角度」。
    //   旧接法 u_uvw.angle = angle（一个正弦周期内的角度），而 uvw_gen 内部
    //   eang = angle*pairs ⇒ 电周期/转 = PPR × pairs。2048 PPR、pairs=4 时
    //   = 8192 个电周期/转，而真实电机只有 P 个（P = 极对数）⇒ 差 2048 倍，
    //   波形形状对、频率与相位全错。这正是 UVW 上电默认关闭（0x0109 复位
    //   值 0x40）的根本原因，见 docs/20_EI58C9_encoder_integration.md §7.5。
    //
    //   正确做法：把「整转计数」与「周期内角度高位」拼成 16 bit 机械角，
    //   每转 2^16 格；uvw_gen 保持 AW=16，pairs 直接填真实极对数 P ⇒
    //   电周期/转 = P。分辨率 = 360/65536 = 0.0055°（电角度），换向表足够。
    //
    //   约束：MECH_SH = 16 - POLE_BITS 必须满足 1 <= MECH_SH <= AW。
    //         POLE_BITS=11（2048 PPR）→ MECH_SH=5，取 angle[15:11]。
    //         POLE_BITS=6（64 周期仿真）→ MECH_SH=10，取 angle[15:6]。
    //-------------------------------------------------------------------------
    localparam integer MECH_SH = 16 - POLE_BITS;
    // ★ 2026-10-28 修复（回归 D11/D14 暴露）：不要用 {cycle_cnt, angle} 现拼！
    //   cycle_cnt 是寄存器、angle 是当拍组合值，两者在正弦周期回绕的那一拍会
    //   **错开一拍**（cycle_cnt 晚一拍才加上去）⇒ 机械角瞬间倒退 65536/PPR，
    //   使 UVW 出现 1 clk 宽的假扇区跳变（tb 实测 min_dwell=1 clk、扇区跳变
    //   38 次而正确值应 24 次，并触发 uvw_freq_warn）。pos_full 是 pole_counter
    //   里与 cycle_cnt **同一拍原子更新**的 {cycle_cnt, angle}（见 pole_counter.v
    //   第 44/140 行），直接切它的高 16 位就没有这个错拍。
    wire [15:0] mech_angle = pos_full[POLE_BITS + AW - 1 : POLE_BITS];

    //=========================================================================
    // 7b. 速度前馈延迟补偿（v9 / S2，rtl/lag_ff.v）
    //-------------------------------------------------------------------------
    //   PI 环路对恒速输入的稳态误差为 0，但它跟踪的是「延迟 T 之后」的测量值，
    //   所以上报位置恒滞后 ω·T = 360° × f_el × T。2048 PPR、3000 rpm
    //   （f_el = 102.4 kHz）、T = 0.72 µs 时 ≈ 26.5° 电角度 ≈ 46″ 机械 ——
    //   比 ±1″ 的目标大 46 倍，是高速段精度的第一杀手，必须补偿。
    //
    //   数据源 omega_pos = loop_filter 的积分器（= 每抽样点位置增量），
    //   已经过环路平滑，不需要再做微分。
    //   ★ v9.1 修正（2026-10-28 实测）：**ABZ 不能吃修正后的角度**。
    //     把 angle_rep 接到 abz_gen 后，tb_enc_top 的 A 相边沿从 2048 涨到 4611
    //     ——原因有两个，都是硬伤：
    //       ① 环路积分器（速度）本身有 ±1 LSB 的极限环抖动，乘以 tau(9) 放大成
    //          ±9 LSB16 的位置抖动，而 ABZ 的一个边沿间隔只有 32 LSB16 ⇒ 阈值附近
    //          反复穿越，凭空多出边沿；
    //       ② ABZ 是增量接口，驱动器只关心"边的相对关系"，固定延迟 ω·T 不累积、
    //          不影响计数结果——为它引入抖动是纯亏。
    //     所以 ABZ 继续用未修正的 angle；遥测（pos_rep）才用修正值。
    //     UVW 同样用未修正的 mech_angle（换向扇区只要 60° 级粗位置，且必须单调）。
    //   ★ 修正量加在 32 位 {周期计数, 角度} 上，进位/借位自动处理 ⇒ 上报位置
    //     全程连续，不会出现"角度先跳、计数后跟"的毛刺。
    //=========================================================================
    wire signed [ZW-1:0] ff_corr_pos;
    wire signed [CYCLE_BITS+AW-1:0] ff_corr_ext =
        {{(CYCLE_BITS+AW-ZW){ff_corr_pos[ZW-1]}}, ff_corr_pos};

    //=========================================================================
    // 7c. 全周角度误差补偿表（v9 / S5，rtl/angle_lut.v）
    //-------------------------------------------------------------------------
    //   刻度误差、安装偏心（1 次谐波）、码盘跳动都是机械角的确定性函数，
    //   单点标定消不掉。表是 4096×16（0.0879°/点），索引取机械角高 12 位。
    //   ★ 没有外部基准时 cfg_lut_en=0，本表完全旁路（输出 0），既有功能不受影响。
    //   ★ 表内容上电未定义，启用前必须由主机整表写入。
    //=========================================================================
    wire [11:0] lut_idx = pos_full[POLE_BITS+AW-1 : POLE_BITS+4];
    wire [15:0] lut_q;
    // 回读校验：0x0145 bit1=1 时读口改由表地址寄存器驱动，主机可逐点核对
    wire [11:0] lut_idx_eff = cfg_lut_probe ? lut_wr_addr : lut_idx;
    wire [15:0] lut_corr = cfg_lut_en ? lut_q : 16'd0;
    wire signed [CYCLE_BITS+AW-1:0] lut_corr_ext =
        {{(CYCLE_BITS+AW-16){lut_corr[15]}}, lut_corr};

    angle_lut u_lut (
        .clk     (clk_i),
        .rst_n   (rst_n),
        .rd_idx  (lut_idx_eff),
        .rd_q    (lut_q),
        .wr_en   (lut_wr_en),
        .wr_addr (lut_wr_addr),
        .wr_data (lut_wr_data)
    );

    wire signed [CYCLE_BITS+AW-1:0] pos_rep   = pos_full + ff_corr_ext + lut_corr_ext;
    wire [AW-1:0]                   angle_rep = pos_rep[AW-1:0];
    wire signed [CYCLE_BITS-1:0]    cycle_rep = pos_rep[CYCLE_BITS+AW-1:AW];

    lag_ff #(
        .AW   (AW),
        .FRAC (FRAC)
    ) u_lag_ff (
        .clk        (clk_i),
        .rst_n      (rst_n),
        .speed_pos  (omega_pos),
        .tau_q8     (cfg_tau_q8),
        .en         (cfg_ff_en),
        .corr_out   (ff_corr_pos),
        .corr_valid ()
    );

    // 仿真自检：补偿量方向必须与速度方向一致（正转 ⇒ 修正量为正）
    // synthesis translate_off
    // ★ 2026-11-02 审计修复：lag_ff 的延迟是 3 拍（见 rtl/lag_ff.v:34 "Latency = 3 clk"），
    //   原实现拿"当前" omega_pos 去比"3 拍前的那次采样产生的" ff_corr_pos，
    //   在速度过零附近必然报假 ERROR（实测 tb_dump_start / tb_v68 / tb_lowsig 都刷过
    //   "(2 / -9)"、"(427308 / -4194304)" 这类假告警，但 TB 仍然 PASS）。
    //   现在把 omega_pos 对齐到 3 拍之后再比，并且忽略 corr 恰为 0 的样点。
    reg signed [ZW-1:0] omega_chk1, omega_chk2, omega_chk3;
    always @(posedge clk_i) begin
        omega_chk1 <= omega_pos;
        omega_chk2 <= omega_chk1;
        omega_chk3 <= omega_chk2;
    end
    //   ★ 2026-11-02 第二修（显示冒烟 TB 暴露）：对齐 3 拍之后，启动/过零瞬态里 corr 仍可能反号
    //     （50 Hz 合成信号实测刷过 "(20 / -405)"、"(333 / -3798)"）。这个判据只对"稳态且两个量
    //     都够大"成立，所以再加两道门：① 两侧幅值都 > 1024 LSB；② 失配必须连续 64 拍才报。
    wire signed [ZW-1:0] ff_corr_neg = -$signed(ff_corr_pos);
    wire ff_bad_now = rst_n && cfg_ff_en &&
                      (omega_chk3[ZW-1] === 1'b0) && (omega_chk3 > 16'sd1024) &&
                      (ff_corr_pos[ZW-1] === 1'b1) && (ff_corr_neg > 16'sd1024);

    reg [7:0] ff_sign_bad_cnt;
    always @(posedge clk_i) begin
        if (!ff_bad_now) ff_sign_bad_cnt <= 8'd0;
        else if (ff_sign_bad_cnt != 8'hFF) ff_sign_bad_cnt <= ff_sign_bad_cnt + 8'd1;
    end

    always @(posedge clk_i)
        if (ff_sign_bad_cnt == 8'd63)
            $display("[enc_top] ERROR: 速度为正但延迟修正量为负且持续 64 拍 (%0d / %0d)",
                     $signed(omega_chk3), $signed(ff_corr_pos));
    // synthesis translate_on

    // 机械角的一致性检查探针（综合会被优化掉，仅仿真可读）
    // synthesis translate_off
    always @(posedge clk_i) if (rst_n && filt_valid && MECH_SH < 1)
        $display("[enc_top] ERROR: MECH_SH=%0d 非法，检查 POLE_BITS", MECH_SH);
    // synthesis translate_on

    //=========================================================================
    // 8. ABZ / UVW 输出
    //=========================================================================
    wire [9:0]  cfg_inter;
    wire [2:0]  cfg_div;

    // 倍—??/分—?—配—?来自挂—?—线上的配置寄存—?，扇出很大（ABZ 每个边沿比较都—?—用）—??
    // 打一拍再送进 abz_gen：切换—?——?—时延后 20 ns，—?? 10 ms 级的人机操作无感—?
    // 却能—?"配置—? mux —? 边沿比较 —? 溢出锁存 CE"这条 20.3 ns 的组合链切断—?
    // （v11 单板时序 WNS +0.821，加入以—?网后布线拥—?—，这条—?径滑—? —?0.638。）
    wire [7:0]  cfg_ablimit;
    wire [4:0]  cfg_hyst_ab, cfg_hyst_uvw, cfg_pairs;
    wire [11:0] cfg_zphase;
    wire [3:0]  cfg_zwidth;
    wire [15:0] cfg_uvwph;
    wire        cfg_apol, cfg_bpol, cfg_zpol, cfg_abzdir;
    wire        cfg_uvwpol, cfg_uvwdir, cfg_abzen, cfg_uwven;

    wire        limiter_active, abz_valid, lag_warn, lag_fatal;
    wire signed [31:0] edge_cnt;

    abz_gen #(
        .AW            (AW),
        .CLK_PERIOD_NS (CLK_PERIOD_NS)
    ) u_abz (
        .clk            (clk_i),
        .rst_n          (rst_n),
        .angle          (angle),           // ★ v9.1 起改回**未修正**角度（见上方注释）
        .in_valid       (filt_valid),
        .inter          (cfg_inter),
        .div            (cfg_div),
        .hyst           (cfg_hyst_ab),
        .ablimit        (cfg_ablimit),
        .apol           (cfg_apol),
        .bpol           (cfg_bpol),
        .zpol           (cfg_zpol),
        .abzdir         (cfg_abzdir),
        .abzen          (cfg_abzen),
        .z_window       (z_window),
        .z_phase        (cfg_zphase),
        .z_width        (cfg_zwidth),
        .a_out          (a_out),
        .b_out          (b_out),
        .z_out          (z_out),
        .edge_cnt       (edge_cnt),
        .limiter_active (limiter_active),
        .lag_warn       (lag_warn),
        .lag_fatal      (lag_fatal),
        .out_valid      (abz_valid)
    );

    //=========================================================================
    // 8b. 锁定状态机 + 连续故障计数（v9 / S3，rtl/lock_sm.v）
    //-------------------------------------------------------------------------
    //   把"上电未建立跟踪 / 瞬间毛刺 / 真的丢信号"三件事分开，并给出
    //   "连续坏了多少拍"，让故障从"一个粘滞位"变成可观测、可验收的指标。
    //   bad = 幅值越限 | 环路滞后>45° | 校正饱和；good = 幅值正常且未失锁未饱和。
    //   注意：这里**不冻结**位置输出 —— 伺服链路宁可带着 flag 继续跑，也不要
    //   在掉锁瞬间把位置钉住（那会让驱动器看到"速度突变"）。
    //=========================================================================
    wire [1:0]  lock_state;
    wire        lock_lost_evt, lock_acq_evt;
    wire [15:0] lock_lost_cnt, lock_bad_run;

    lock_sm #(
        .GOOD_N  (12500),     // 1 ms @ 12.5 MHz
        .BAD_N   (2500),      // 0.2 ms
        .RECOV_N (12500)
    ) u_lock (
        .clk       (clk_i),
        .rst_n     (rst_n),
        .in_valid  (cordic_valid),
        .amp_ok    (amp_ok),
        .amp_low   (amp_low),
        .amp_high  (amp_high),
        .lag_fatal (lag_limit | lag_fatal),
        .cor_sat   (cor_sat),
        .state     (lock_state),
        .lost_evt  (lock_lost_evt),
        .acq_evt   (lock_acq_evt),
        .lost_cnt  (lock_lost_cnt),
        .bad_run   (lock_bad_run)
    );

    // ★ v9（S4）偏置跟踪只在 TRACK 状态工作（此处才拿到 lock_state）
    assign lock_track = (lock_state == 2'd1);

    // UVW 基波频率告警门限 = round(2 * f_clk / 8.33 MHz)
    //   50 MHz (CLK_PERIOD_NS=20) -> 12 拍；100 MHz (10) -> 24 拍
    localparam integer UVW_MIN_HALF = (2 * (1000 / CLK_PERIOD_NS) * 1000000) / 8330000;

    wire uvw_freq_warn, uvw_valid;
    wire [5:0] pole_pairs_eff;

    uvw_gen #(
        .AW                 (AW),
        .UVW_MIN_HALF_CYCLE (UVW_MIN_HALF)
    ) u_uvw (
        .clk           (clk_i),
        .rst_n         (rst_n),
        .angle         (mech_angle),        // ★ 机械角（每转 2^16），不是周期内角度
        .in_valid      (filt_valid),
        .pairs         (cfg_pairs),         // ★ 语义 = 真实极对数 P（0 表示 32）
        .uvwpol        (cfg_uvwpol),
        .uvwdir        (cfg_uvwdir),
        .uwven         (cfg_uwven),
        .uvwph         (cfg_uvwph),
        .uvw_hyst      (cfg_hyst_uvw),      // ★ 0x0104 UVW.hyst（角度 LSB，0 = 用编译期默认档）
        .u_out         (u_out),
        .v_out         (v_out),
        .w_out         (w_out),
        .uvw_freq_warn (uvw_freq_warn),
        .pole_pairs_eff(pole_pairs_eff),
        .out_valid     (uvw_valid)
    );

    //=========================================================================
    // 9. 保留位与标定窗口参数
    //    cfg_st_bits / cfg_mt_bits 是原从站帧位宽的只读回读量，v74 起恒 0；
    //    抽头位与寄存器地址保留（不重排）。原帧位宽定义（保留量，不再驱动逻辑）：
    //    单圈 = {cycle_cnt[POLE_BITS-1:0], angle} 共 ST_BITS_L 位
    //    多圈 = cycle_cnt[15:POLE_BITS]            共 MT_BITS_L 位
    //=========================================================================
    wire        [7:0]  cfg_st_bits, cfg_mt_bits;
    // ★ 2026-10-10：标定窗口周期数（SPI 0x0503/0x0504 = CALIB_N，复位默认 64）
    //   → calib_ctrl.win_cycles。此前该寄存器"仅存储"、calib_ctrl 硬编码 16'd64，
    //   低频（1 kHz）时一个周期 12500 个样本、64 周期需 800000 ≫ MAX_SAMP(65536)，
    //   窗口必然在半周期处被截断（见 rtl/calib_ctrl.v 的"整周期收尾"注释）。
    wire        [15:0] cfg_calib_n;
    // ★ 2026-10-10：包模式写**一次事务写两个字节**（rtl/spi_slave.v:244-251：bit7:0 写
    //   addr、bit15:8 写 addr+1）⇒ 主机按 16 位写 0x0502（"启动标定"= 0x0001）时，高字节
    //   0x00 会落到 0x0503 = CALIB_N 低字节 ⇒ 窗口周期数被清成 0。CALIB_N 的复位默认是
    //   64，所以 0 只可能来自这种"被波及"，不含合法意图 ⇒ 这里把 0 当"用默认 64"。
    //   证据：sim/tb_enc_top.v:914 `spi_wr16(11'h502, 16'h0001)` 后再无任何 CALIB_N 写入，
    //   实测窗口 nsamp=256 / wcnt=1（= 1 个输入周期 = win_n=1），TEST F4d/F4f/F11g 因此失败。
    //   主机正确用法：先写 0x0503=低字节、0x0504=高字节（默认 0/0x40 = 64），再触发 0x0502。
    wire        [15:0] cfg_calib_n_use;
    assign cfg_calib_n_use = (cfg_calib_n == 16'd0) ? 16'd64 : cfg_calib_n;

    // v74：原从站模块已删除。
    //   原先这里例化从站模块，把帧数据（单圈/多圈）送给主站，并把 crc_err/bit_err/
    //   frame_short/sl_rx/link_lost 送进 reg_file 与抽头。删除后：
    //     · 0x0500/0x0501（帧位宽）、0x053A bit[5:4]（frame_active/crc_err_seen）、
    //       0x053B/0x053C（帧内已发位数）全部恒 0（地址保留，不再有意义）；
    //     · 抽头位 [375]/[126] 等仍占位，恒 0（保持位图向后兼容，不重排索引）；
    //     · 屏幕"累计转数"只用内部 pos_full（见 disp/val_format.v 的 pa_rev），
    //       所以卡 4 不再因"没接外接主机"而进空态。
    //   ★ 为什么保留位图而不是删位：抽头索引被 disp/enc_disp_tap.v 与
    //     uart_scope 帧共用，重排会连带改显示与遥测格式，收益不抵风险。

    //=========================================================================
    // 10. 状态字（TW28 兼容 bit 定义）
    //     bit0 oflow / bit1 falarm / bit2 laglim / bit3 inclim
    //     bit4 lagfatl / bit5 scamp / bit6 adapt / bit7 res
    //=========================================================================
    wire [7:0] stat_byte = {
        1'b0,                                            // bit7 res
        1'b0,                                            // bit6 adapt
        (amp_low | amp_high),                            // bit5 scamp
        lag_fatal,                                       // bit4 lagfatl
        (limiter_active | uvw_freq_warn),                // bit3 inclim
        (lag_limit | lag_warn),                          // bit2 laglim（滤波器滞后 或 AB 限频滞后）
        1'b0,                                            // bit1 falarm
        (cor_sat | otr_lat)                              // bit0 oflow
    };

    //=========================================================================
    // 11. SPI 从站 + 寄存器组
    //=========================================================================
    // 注意：地址必须是 16bit！寄存器组里 0x5xxx 段的标定结果/状态量
    //       （calib 系数、amp_sq、cycle_cnt、pos_full、DEVICE_ID）都超出 8bit 地址，
    //       若写成 .AW(8) 会整段不可访问。
    //
    // ★ 协议模式必须选包模式（USE_TW28_PACKET=1）：
    //   简单 2 字节模式的地址只有 7 位（见 rtl/spi_slave.v:208
    //   `addr <= {9'd0, sr_next[6:0]}`），只能访问 0x00..0x7F。而
    //   docs/01_technical_solution.md 第 7 节定义的整张寄存器映射表
    //   （INTER0 0x101 / INTER1 0x102 / AB 0x103 / UVW 0x104 / ABLIMIT 0x106 /
    //   ZERO0 0x107 / ZERO1 0x108 / OUTPUT 0x109 / ZPHASE 0x10A / UVWPH 0x10B /
    //   FILT_K 0x302 / 标定结果 0x5000..）全部落在 0x100 以上 ——
    //   用简单模式时这些寄存器在顶层**一个都写不进去**，输出侧配置恒为复位默认值
    //   （abzen=1、uwven=0、zwidth=0、div=1），ABZ 的 Z 永不产生、UVW 恒为 000。
    //   顶层集成测试台 tb_enc_top 实测过这个症状（illegal_codes=245760、
    //   Z_pulses=0）。因此顶层固定用 TW28 风格 32 位包模式；简单模式仍保留在
    //   rtl/spi_slave.v 里供单独测试（sim/tb_spi_slave.v 两种模式都覆盖）。
    wire [15:0] spi_addr;
    wire [7:0]  spi_wdata, spi_rdata;
    wire        spi_we;

    //=========================================================================
    //  UART→SPI 桥（rtl/uart_spi_bridge.v）
    //    板载 USB 串口收 4 字节 → 在 FPGA 内部当 SPI 主机，驱动下面这个真正的
    //    u_spi 从站 → 应答 6 字节从 uart_tx 发回。这样"没有 SPI 主机"也能读写
    //    任意寄存器，且顺带把 spi_slave 的真实通路测到。
    //    仲裁：桥发帧期间（br_ss_n 低）u_spi 的三根输入由桥驱动，其余时间仍由
    //    外部引脚驱动 —— 外部 SPI 主机与 UART 桥二选一，互不干扰。
    //    TX 复用：桥用 scope_idle/scope_hold 与遥测握手，只在帧间切发送权，
    //    所以线上不会出现半个字节（详见 rtl/uart_spi_bridge.v 头部注释）。
    //=========================================================================
    wire        br_sck, br_ss_n, br_mosi;
    wire        br_tx_hold;
    wire        br_scope_hold;              // 桥 → 遥测：别启动新帧
    wire        scope_tx_w;                 // 遥测的 tx（不再直连端口）
    wire        scope_idle_w;               // 遥测：行空闲

    // ---- 抓包（B1）：0x0700 段寄存器—? + 捕获引擎 + UART dump ----
    wire        cap_ext_we;
    wire [15:0] cap_ext_addr;
    wire [7:0]  cap_ext_wdata;
    wire [7:0]  cap_ext_rdata;
    wire        cap_arm, cap_abort, cap_dump_start, cap_dump_abort;
    wire [1:0]  cap_dec_log2;
    wire [15:0] cap_len_cfg, cap_pre_cfg, cap_trig_level_cfg;
    wire [1:0]  cap_trig_mode_cfg;
    wire        cap_src_sel;
    wire [15:0] cap_start_w, cap_len_eff_w, cap_trig_idx_w;
    wire [31:0] cap_sample_cnt;
    wire        cap_st_armed, cap_st_done, cap_st_trig, cap_st_busy, cap_st_ovf;
    wire        cap_rd_en;                  // —? capture 的—?—使能（dump/UDP 复用—?
    wire [15:0] cap_rd_addr;                // —? capture 的—?—地—?（dump/UDP 复用—?
    wire [31:0] cap_rd_data;

    // ---- 连续流（二期—?----
    wire        stream_en_w, stream_run_w;
    wire [2:0]  stream_dec_w;
    wire [15:0] st_rd_addr_w, st_lag_w;
    wire        st_rd_en_w;
    wire [31:0] st_rd_data_w, stream_pkts_w, stream_drop_w;
    wire [15:0] cap_wr_ptr_w;
    wire [31:0] cap_strm_cnt_w;
    wire        cap_st_stream_w;
    reg         stream_en_q;
    wire        stream_arm_w   = stream_en_w & ~stream_en_q;
    wire        stream_abort_w = ~stream_en_w & stream_en_q;
    wire        dump_rd_en;
    wire [15:0] dump_rd_addr;
    wire        dump_tx_w, dump_busy_w, dump_done_w;
    wire [15:0] dump_blocks_done;
    reg         dump_start_g;
    wire        spi_miso_w;                 // u_spi.sso（同时喂桥与引脚）
    // ---- 以太网（B2—?----
    wire        eth_udp_rd_en, eth_udp_rd_busy;
    wire [15:0] eth_udp_rd_addr;
    wire        eth_udp_start, eth_udp_abort;
    wire [31:0] eth_cfg_mac, eth_cfg_ip, eth_cfg_host_ip;
    wire [15:0] eth_cfg_port, eth_cfg_ctrl;
    wire [15:0] eth_tx_pkt_w, eth_tx_drop_w, eth_rx_pkt_w;
    wire [15:0] eth_udp_pkts_w, eth_udp_drop_w;
    wire        eth_arp_seen, eth_icmp_seen, eth_host_known;
    wire        eth_udp_busy, eth_udp_done;
    wire [4:0]  eth_idelay_val_w;
    wire        eth_idelay_ld_w, eth_idelay_rdy_w;
    wire [15:0] eth_rx_clk_cnt_w, eth_rx_dv_cnt_w, eth_rx_byte_cnt_w, eth_rx_err_cnt_w;
    wire        eth_rx_swap_w;
    wire [31:0] eth_rx_dbg_w;
    wire [15:0] eth_tx_dbg_frm_w, eth_tx_dbg_len_w, eth_tx_dbg_port_w;
    wire [15:0] eth_tx_dbg_mac0_w, eth_tx_dbg_mac1_w, eth_tx_dbg_ck_w;
    wire [15:0] eth_tx_dbg_dip0_w, eth_tx_dbg_dip1_w;
    wire        u_spi_sck  = br_ss_n ? spi_sck  : br_sck;
    wire        u_spi_ss_n = br_ss_n ? spi_ss_n : 1'b0;
    wire        u_spi_mosi = br_ss_n ? spi_mosi : br_mosi;

    uart_spi_bridge #(
        .BAUD_DIV (BAUD_DIV),
        .SPI_HALF (8),
        .GAP      (16),
        .TO_DIV   (100_000),
        .GAP_MIN  (13 * BAUD_DIV)
    ) u_bridge (
        .clk         (clk_i),
        .rst_n       (rst_n),
        .rx          (uart_rx),
        .tx          (uart_tx),
        .scope_tx    (scope_tx_w),
        .scope_idle  (scope_idle_w),
        .dump_tx     (dump_tx_w),
        .dump_busy   (dump_busy_w),
        .scope_hold  (br_scope_hold),
        .tx_hold     (br_tx_hold),
        .ext_busy    (~spi_ss_n),
        .spi_sck     (br_sck),
        .spi_ss_n    (br_ss_n),
        .spi_mosi    (br_mosi),
        .spi_miso    (spi_miso_w)
    );

    assign spi_miso = spi_miso_w;

    spi_slave #(
        .AW              (16),
        .DW              (8),
        .USE_TW28_PACKET (1)
    ) u_spi (
        .clk   (clk_i),
        .rst_n (rst_n),
        .sck   (u_spi_sck),
        .ssi   (u_spi_mosi),
        .ss_n  (u_spi_ss_n),
        .sso   (spi_miso_w),
        .addr  (spi_addr),
        .wdata (spi_wdata),
        .we    (spi_we),
        .rdata (spi_rdata)
    );

    // v74：原帧位宽寄存器已删除，reg_file 不再需要 ST_BITS_R / MT_BITS_R
    // 这两个只读量已无意义（原由 reg_file 驱动），抽头位仍占位（恒 0）
    assign cfg_st_bits = 8'd0;
    assign cfg_mt_bits = 8'd0;
    reg_file #(
        .AW (16),
        .DW (8)
    ) u_regs (
        .clk              (clk_i),
        .rst_n            (rst_n),
        .addr             (spi_addr),
        .wdata            (spi_wdata),
        .we               (spi_we),
        .rdata            (spi_rdata),
        .calib_we         (calib_we),
        .calib_addr       (calib_addr),
        .calib_wdata      (calib_wdata),
        .calib_busy       (calib_busy),
        .calib_done       (calib_done),
        .calib_trunc      (calib_trunc),
        .calib_retry      (calib_retry),
        .calib_bad        (calib_bad),
        .cfg_inter        (cfg_inter),
        .cfg_div          (cfg_div),
        .cfg_ablimit      (cfg_ablimit),
        .cfg_hyst_ab      (cfg_hyst_ab),
        .cfg_hyst_uvw     (cfg_hyst_uvw),
        .cfg_pairs        (cfg_pairs),
        .cfg_zphase       (cfg_zphase),
        .cfg_zwidth       (cfg_zwidth),
        .cfg_uvwph        (cfg_uvwph),
        .cfg_kp           (cfg_kp),
        .cfg_ki           (cfg_ki),
        .cfg_apol         (cfg_apol),
        .cfg_bpol         (cfg_bpol),
        .cfg_zpol         (cfg_zpol),
        .cfg_abzdir       (cfg_abzdir),
        .cfg_uvwpol       (cfg_uvwpol),
        .cfg_uvwdir       (cfg_uvwdir),
        .cfg_abzen        (cfg_abzen),
        .cfg_uwven        (cfg_uwven),
        .cfg_ofs_s        (cfg_ofs_s),
        .cfg_ofs_c        (cfg_ofs_c),
        .cfg_gain_s       (cfg_gain_s),
        .cfg_gain_c       (cfg_gain_c),
        .cfg_phase_k      (cfg_phase_k),
        .cfg_shift_s      (cfg_shift_s),
        .cfg_shift_c      (cfg_shift_c),
        .cfg_amp_low_sq   (cfg_amp_low_sq),
        .cfg_amp_high_sq  (cfg_amp_high_sq),
        .cfg_h2_k         (),   // ★ 有意空连接：二次谐波系数为预留寄存器（见文件末"未接线项"说明）
        .cfg_calib_n      (cfg_calib_n),
        // ★ v9（S2）延迟前馈
        .cfg_tau_q8       (cfg_tau_q8),
        .cfg_ff_en        (cfg_ff_en),
        .cfg_bias_en      (cfg_bias_en),
        .ff_speed         (omega_pos),
        .ff_corr          (ff_corr_pos),
        // ★ v9（S5）全周补偿表
        .cfg_lut_en       (cfg_lut_en),
        .lut_wr_en        (lut_wr_en),
        .lut_wr_addr      (lut_wr_addr),
        .lut_wr_data      (lut_wr_data),
        .cfg_lut_probe    (cfg_lut_probe),
        .lut_rd_q         (lut_q),
        // ★ v9（S3）锁定状态机
        .lock_state       (lock_state),
        .lock_lost_evt    (lock_lost_evt),
        .lock_acq_evt     (lock_acq_evt),
        .lock_lost_cnt    (lock_lost_cnt),
        .lock_bad_run     (lock_bad_run),
        // ★ v9（S4）偏置慢跟踪回显
        .bias_s           (bias_s),
        .bias_c           (bias_c),
        .bias_valid       (bias_valid),
        .bias_big         (bias_big),
        .calib_start      (calib_start_cfg),
        .clr_otr          (clr_otr_adc),
        .stat_amp_sq      (amp_sq),
        .stat_lag_limit   (lag_limit),
        .stat_amp_low     (amp_low),
        .stat_amp_high    (amp_high),
        .stat_otr         (otr_lat),
        .stat_cycle_cnt   (cycle_cnt),
        .stat_pos_full    (pos_rep[31:0]),
        .stat_inclim      (limiter_active | uvw_freq_warn),
        .stat_z_cnt       (z_pulse_cnt),   // v73：Z 上升沿计数
        // ★ v6 诊断输入（角度毛刺 / 周期脉冲 / 标定窗口快照 / RTL 版本号）
        .gl_cnt_1024      (gl_cnt_1024),
        .gl_cnt_2048      (gl_cnt_2048),
        .gl_cnt_4096      (gl_cnt_4096),
        .gl_cnt_8192      (gl_cnt_8192),
        .gl_hold_cnt      (gl_hold_cnt),
        .cyc_pulse_cnt    (cyc_pulse_cnt),
        .dbg_int_min      (calib_dbg_int_min),
        .dbg_int_max      (calib_dbg_int_max),
        .dbg_nsamp_cls    (calib_dbg_nsamp_cls),
        .dbg_wcnt_cls     (calib_dbg_wcnt_cls),
        .rtl_build_id     (RTL_BUILD_ID),
        // ---- 0x0700 抓包寄存器—?—（rtl/cap_regs.v—?----
        .ext_we           (cap_ext_we),
        .ext_addr         (cap_ext_addr),
        .ext_wdata        (cap_ext_wdata),
        .ext_rdata        (cap_ext_rdata)
    );

    //=========================================================================
    // 12. 标定状态机（闭式解：一阶/二阶矩 -> 六参数 + 数字 AGC 移位）
    //=========================================================================
    //-------------------------------------------------------------------------
    // 标定窗口的"输入周期"脉冲（2026-10-10 修复，证据见 docs/DEV_STATUS.md §1.17）
    //-------------------------------------------------------------------------
    //  问题：原先 calib_ctrl 的 cycle_pulse 直接接 u_pole 的 wrap_pos|wrap_neg，
    //        而 loop_filter 在标定期间被 freeze=calib_busy 冻结（本文件 :395）
    //        ⇒ pos_out 恒定 ⇒ pole_counter 永不跨周期边界 ⇒ wcnt 恒为 0，
    //        win_cycles=64 这条路径永远走不到；窗口只能靠 calib_ctrl 的
    //        MAX_SAMP=65536 样本保护上限截断收尾，truncated 恒为 1。
    //        实测（sim/tb_enc_top.v TEST F 首次运行）：nsamp=65536 / wcnt=0 /
    //        truncated=1 / 耗时 64942 拍。
    //  修复：改用**未经冻结**的 CORDIC 原始角度 angle_raw 的整圈折返来计数。
    //        angle_raw 每个输入电周期恰好折返一次，与环路能否跟上、位置是否
    //        被冻结都无关；MAX_SAMP 保护上限保留（输入不转时仍能收尾，并如实
    //        置 truncated=1）。
    // ★ 2026-10-10：标定窗口周期数改为**主机可配**（SPI 0x0503/0x0504 = CALIB_N，
    //   复位默认 64）。此前该寄存器"仅存储"，calib_ctrl 的 win_cycles 硬编码 16'd64
    //   ⇒ 低频（1 kHz）时一个周期就有 12500 个样本，64 周期需要 800000 ≫ MAX_SAMP，
    //   窗口必然被截断（见 calib_ctrl.v 的"整周期收尾"注释）。
    //   注：cfg_calib_n 的声明在文件上方（reg_file 例化之前），此处只做说明。
    // ★★ 2026-10-10：过零抖动抑制（本版新增；根因分析见 docs/DEV_STATUS.md §1.28）
    //   现象（SPI 重复一键标定，写 0x0502=0x0001，CALIB_N=2/4/8 各 4 轮）：
    //     OFS_S 多数轮次稳定在 0x0037/0x0038(=55/56，与遥测反推真值一致)，但约
    //     1/4 的轮次跳到 ±1800…2300（0x0766/0x076A/0xF6FE/0xF6FF/0xF90C），且
    //     异常值成对出现；OFS_C 全程 0x015E…0x0161（稳），GAIN/PHASE_K 只漂 ~1%。
    //   根因：本段原来直接对 angle_raw 的 MSB 翻转计数、**没有消抖**。θ≈0/π 处
    //     s≈0，atan2 对 s 噪声最灵敏（实测角度噪声 ~0.1~0.2° rms），MSB 会在边界
    //     来回抖动。每多一次抖动翻转，calib_cyc_tgl 的奇偶性就反转一次 ⇒ 周期
    //     脉冲相对"θ=0 折返"错开半个周期 ⇒ 标定窗口变成**奇数个半周期**（不是
    //     整数个输入周期）⇒ 一阶矩 O_s 错 ±2A/(nπ)：n=7(3.5 周期) = 2*25920/(7π)
    //     = 2357（实测 2305/2306），n=9(4.5 周期) = 1833（实测 1894/1898/1899）。
    //     同一窗口下 cos 的一阶矩恒为 0 ⇒ OFS_C 完全不受影响 —— 这正是本现象的
    //     指纹，也解释了为什么只有 s 通道的偏置会错。
    //   ★★ 曾尝试的修法（**已放弃，勿重复走这条路**）：给翻转检测加"先稳定再接受"
    //     的去抖（新 MSB 须连续保持 lim 拍才算一次翻转）。物理上它能挡住抖动，但
    //     它把脉冲相对真实周期边界**延迟 lim 拍**，而 lim 会随信号周期估计变化 ⇒
    //     相邻脉冲间隔 = 2H ± Δlim ≠ 整周期 ⇒ 标定窗口的样本数不再是整周期
    //     （仿真实测 nsamp 16367 ≠ 16384=64×256），幂等标定的可重复性被破坏
    //     （F4f/F11 回归失败：两次一键标定 OFS_S −12 vs +7、PHASE_K −33 vs 0）。
    //     而且 lim 取大时会死锁（进 TEST F 前输入长时间不动 ⇒ 间隔估计饱和 ⇒
    //     lim=262143 拍 > 半周期 128 拍 ⇒ 一次脉冲都不产生，标定挂到 ARM_TMO）。
    //   ★★ —?终采用的—?法：脉冲—?测保持原样（零延迟—?—间隔严格等于整周期），—?
    //     抖动交给 calib_ctrl 的"窗口内周期间隔 max/min 检查 + 作废重试"（阈值
    //     1.25 倍，恰好抓住半周期错位造成的 3H vs 2H 间隔）——它对**窗口内**任何
    //     抖动都是确定可检的，且不动脉冲时序。详见 docs/DEV_STATUS.md §1.29。
    // ★★★ 2026-10-10（第二轮修：板上实测驱动）——过零参考改为**带滞回的角度过零**
    //   板上实测（`tools/calib_repeat.py --n 20`，跑的是含"1.25 倍间隔判据 + 作废
    //   重试"的 v3 位流）：**retry 用尽(3) 且 win_bad=1 出现在 17/20 轮**、仍有
    //   **6/20 轮 OFS_S 错** ⇒ 说明 ①"窗口不是整数个周期"这件事是真的（间隔检测
    //   用简单模式时这些寄存器在顶层**一个都写不进去**，输出侧配置恒为复位默认值
    //   —?—?又落进同—?—?抖动窗，—?后照样把有偏的结果留下—??
    //   坏值的**量级**把机理钉死了。设 A≈32304（= 2019 LSB × 16，10 Vpp 输入），
    //   窗口含 m+1/2 个周期时 sin 的一阶矩 = 2A/(π(2m+1)) = 20566/(2m+1)：
    //     m=4 ⇒ 2285（实测 2305 / 2360 / 2281）
    //     m=5 ⇒ 1870（实测 1778 / 1839 / 1894 / 1899）
    //   ⇒ 窗口正好是 **4.5 / 5.5 个输入周期**（半周期污染一阶矩），而 cos 的一阶矩
    //   恒为 0 ⇒ OFS_C 永远不受影响（实测 ±3 稳）。这与"MSB 抖动多翻奇数拍 ⇒ 脉冲
    //   奇偶性反—? —? 脉冲相位错开半个周期"完全—?致—??
    //   ⇒ 根治办法：θ 过零必须**带滞回**。状态机只在"已确认 s>0 半圈（θ>+CAL_HYS）"
    //     与"已确认 s<0 半圈（θ<-CAL_HYS）"之间切换，只有被接受的穿越才算一次半圈。
    //     θ 噪声实测只有 ~0.1~0.5° rms，而 CAL_HYS = 2048 = 11.25° 是 20σ 以上余量
    //     —? 抖动再翻不动状—?—，脉冲奇偶性不—?能—??抖动改写—?
    //   ★ 为什么这不违反"脉冲时序不能动"（§1.29 的教训）：滞回给事件加的是一个
    //     **恒定角度**延迟；每两个相邻脉冲（A→B→A）跨越的仍然是整整一圈 ⇒ 脉冲间隔
    //     严格等于一个输入周期，标定窗口仍是整数个周期（仿真 nsamp=16384 不变）。
    //     即使输入有谐波失真把两个半圈的延时不对称，二者之和仍—?整周—? —? 无偏—?
    localparam signed [AW-1:0] CAL_HYS = 16'sd2048;   // 11.25°（幅度无关：只看角度）
    localparam [3:0]           CONF_N  = 4'd3;        // ★ v6：确认拍数（有效样本数）
    reg          side_raw;          // 带滞回的"原始"半圈判定（第一级，未确认）
    reg          calib_s_side;      // 1 = 已**确认**在 s>0 半圈（滞后 side_raw）
    reg  [3:0]   conf_cnt;
    reg          calib_cyc_tgl;
    reg          calib_cyc_pulse_r;
    // ★ v5：过零参考改用**毛刺保持后**的角度（`angle_filt`，见本文件 5b 节）。
    //   单拍 gross 错值已被挡在滞回之前，正常序列的相位完全不变。
    wire signed [AW-1:0] calib_ang_s = angle_filt;

    // —?—?级：带滞回的半圈判定（v4 起）
    always @(posedge clk_i) begin
        if (!rst_n) begin
            side_raw <= 1'b0;
        end else if (cordic_valid) begin
            if (!side_raw && (calib_ang_s >  CAL_HYS)) side_raw <= 1'b1;
            else if (side_raw && (calib_ang_s < -CAL_HYS)) side_raw <= 1'b0;
        end
    end

    // 第二级：★ v6 新增 CONF_N 拍确认 —— "连续 CONF_N+1 个有效样本都停在新侧"才算
    //   —?次真实过零—?—为—?么需要：—?—?级只—?"当前这一拍的角度"，只要某—?拍的角度—?
    //   采错到对侧（幅度 >11.25° 就够），它就会立刻多翻一对 ⇒ 多出一个周期脉冲 ⇒
    //   间隔被判为"非整周期"（板上 retry=3/win_bad=1 的签名）。用**角度幅度**做阈值
    //   挡不住"恰好落在 11.25°~45° 之间的错值"；用**时间上的连续性**可以挡住**任意
    //   幅度**的单拍错值——真实相位是连续的，不可能连续 3 个样本跳到对侧再跳回来。
    //   ★ 为什么这不违反"脉冲时序不能动"（§1.29 的教训）：滞回给事件加的是一个
    //   CONF_N+1 个样本（**恒定**延迟，不随周期估计变化）⇒ 相邻脉冲间隔仍严格等于
    //   —?—?输入周期，标定窗口仍—?整数—?周期—?
    always @(posedge clk_i) begin
        if (!rst_n) begin
            calib_s_side      <= 1'b0;
            conf_cnt          <= 4'd0;
            calib_cyc_tgl     <= 1'b0;
            calib_cyc_pulse_r <= 1'b0;
        end else begin
            calib_cyc_pulse_r <= 1'b0;
            if (cordic_valid) begin
                if (side_raw == calib_s_side) begin
                    conf_cnt <= 4'd0;               // 与已确认侧一致 ⇒ 无需确认
                end else if (conf_cnt >= CONF_N) begin
                    calib_s_side  <= side_raw;      // 连续多拍都在新侧 ⇒ 采纳
                    conf_cnt      <= 4'd0;
                    calib_cyc_tgl <= ~calib_cyc_tgl;
                    if (calib_cyc_tgl) calib_cyc_pulse_r <= 1'b1;
                end else begin
                    conf_cnt <= conf_cnt + 4'd1;
                end
            end
        end
    end
    wire calib_cycle_pulse = calib_cyc_pulse_r;

    // 周期脉冲计数（v6 诊断：0x0509）——与 5c 节的毛刺计数配成"每周期多少次"的比值
    //   （reg 声明在文件上方第 12 节之前，理由见那里的注释）
    always @(posedge clk_i) begin
        if (!rst_n) cyc_pulse_cnt <= 16'd0;
        else if (calib_cycle_pulse) cyc_pulse_cnt <= cyc_pulse_cnt + 16'd1;
    end

    calib_ctrl #(
        .REF_Q15 (26214)                        // 0.80 * 32768
    ) u_calib (
        .clk         (clk_i),
        .rst_n       (rst_n),
        .start       (key_fall | calib_start_cfg),
        .win_cycles  (cfg_calib_n_use),         // 标定窗口：0 视为默认 64 个输入周期（SPI 0x0503/04 可改）
        .busy        (calib_busy),
        .done        (calib_done),
        .truncated   (calib_trunc),
        .retry_cnt   (calib_retry),
        .win_bad     (calib_bad),
        // ★ v6 诊断快照（reg_file 只读口 0x050A-0x050D）
        .dbg_int_min   (calib_dbg_int_min),
        .dbg_int_max   (calib_dbg_int_max),
        .dbg_nsamp_cls (calib_dbg_nsamp_cls),
        .dbg_wcnt_cls  (calib_dbg_wcnt_cls),
        // ★ 标定累加的是**校正前**的原始 s/c（2026-10-10 修 §1.18：幂等标定）。
        //   不能用 s_cor/c_cor —— 那会让第二次标定测量"自己上一次的校正结果"。
        .s_n         (s_dec),
        .c_n         (c_dec),
        .in_valid    (dec_valid),
        // ★ 输入周期脉冲来自 angle_raw（未被 freeze），不能再用 u_pole 的 wrap_*
        .cycle_pulse (calib_cycle_pulse),
        .res_ofs_s   (res_ofs_s),
        .res_ofs_c   (res_ofs_c),
        .res_gain_s  (res_gain_s),
        .res_gain_c  (res_gain_c),
        .res_phase_k (res_phase_k),
        .res_shift_s (res_shift_s),
        .res_shift_c (res_shift_c),
        .calib_we    (calib_we),
        .calib_addr  (calib_addr),
        .calib_wdata (calib_wdata),
        .state_dbg   (calib_state_dbg)
    );

    // 说明：本版本把标定结果通过 calib_we/calib_addr/calib_wdata 写回寄存器组，
    //       即"标定出的系数就是后续 SPI 读回的系数"，因此 use_* 直接取 cfg_*。
    //       若希望标定结果立即生效—?—不依赖寄存器写入时序，—?把上面的
    //       use_ofs_s/use_gain_s/... 改成 "calib_done ? res_* : cfg_*"。

    //=========================================================================
    // 13. UART 遥测（上位机实时波形 / 李萨如图 / ABZ-UVW 逻辑波形）
    //     tx 与 tx_idle/hold 参与上面第 12.5 节的 TX 仲裁：桥发应答时遥测暂停
    //     启动新帧（en 恒 1，暂停只发生在帧边界）。
    //     ★ 帧布局 v2（v12 起）：amp_sq 不再上线（= s²+c²，上位机可无损重算），
    //       腾出的 off8..11 改为 ABZ/UVW 电平快照 + 帧标记，帧长不变。
    //       位序（与 rtl/uart_scope.v 顶部注释、tools/uart_scope.py 严格对应）：
    //         io_state = {limiter_active, dir, w_out, v_out, u_out, z_out, b_out, a_out}
    //         io_flags = {amp_bad, cor_sat, uwven, abzen, uvw_freq_warn,
    //                     z_window, lag_fatal, lag_warn}
    //=========================================================================
    uart_scope #(
        .BAUD_DIV   (BAUD_DIV),
        .SAMPLE_DIV (SAMPLE_DIV)
    ) u_scope (
        .clk      (clk_i),
        .rst_n    (rst_n),
        .en       (1'b1),
        .hold     (br_scope_hold),
        .angle    (angle),
        .s_n      (s_cor),
        .c_n      (c_cor),
        .io_state ({limiter_active, dir, w_out, v_out, u_out, z_out, b_out, a_out}),
        .io_flags ({amp_low | amp_high, cor_sat, cfg_uwven, cfg_abzen,
                    uvw_freq_warn, z_window, lag_fatal, lag_warn}),
        .pos_full (pos_full[31:0]),
        .stat     (stat_byte),
        .tx       (scope_tx_w),
        .tx_idle  (scope_idle_w),
        .frame_cnt()
    );

    //=========================================================================
    // 13.6 抓包通道（B1）：0x0700 寄存器组 —? 捕获引擎 —? UART dump
    //   数据源：默—?—原—? s_q15/c_q15—?50 MSPS），—?选校正后 s_cor/c_cor—?12.5 MSPS）—??
    //   dump —?动—?? scope_idle_w / !br_scope_hold / !dump_busy_w 三重门控—?
    //   保证不截—?正在发的遥测帧或桥的应答；scope_dump 内部还有 5 ms 延时
    //   （—?—盖"—? DUMP_CTRL —? 6 B 应答"），两—??合起来消—? TX 竞争—?
    //=========================================================================
    wire signed [15:0] cap_s = cap_src_sel ? s_cor : s_q15;
    wire signed [15:0] cap_c = cap_src_sel ? c_cor : c_q15;
    wire               cap_valid = cap_src_sel ? cor_valid : 1'b1;

    //  dump —?动是单拍脉冲，—?—写 0x072E 的那—?拍桥正忙（br_scope_hold 高）—?
    //  —?组合门控会把这一拍吃掉—?——?—求永久丢失（上板实测：0x0730 —? 0）—??
    //  这里锁存—? pending，等读口真空闲再发一—?单拍 start—?
    wire eth_udp_start_g = eth_udp_start && !stream_en_w && !dump_busy_w;

    reg dump_req;
    always @(posedge clk_i) begin
        if (!rst_n) begin
            dump_req     <= 1'b0;
            dump_start_g <= 1'b0;
        end else begin
            dump_start_g <= 1'b0;
            if (cap_dump_abort)          dump_req <= 1'b0;
            else if (cap_dump_start)     dump_req <= 1'b1;
            else if (dump_req && scope_idle_w && !br_scope_hold && !dump_busy_w
                     && !stream_en_w && !eth_udp_rd_busy) begin
                dump_req     <= 1'b0;
                dump_start_g <= 1'b1;
            end
        end
    end

    cap_regs u_capregs (
        .clk         (clk_i),
        .rst_n       (rst_n),
        .addr        (cap_ext_addr),
        .we          (cap_ext_we),
        .wdata       (cap_ext_wdata),
        .rdata       (cap_ext_rdata),
        .arm         (cap_arm),
        .abort       (cap_abort),
        .dec_log2    (cap_dec_log2),
        .cap_len     (cap_len_cfg),
        .trig_mode   (cap_trig_mode_cfg),
        .trig_level  (cap_trig_level_cfg),
        .pre_len     (cap_pre_cfg),
        .src_sel     (cap_src_sel),
        .cap_start   (cap_start_w),
        .cap_len_eff (cap_len_eff_w),
        .trig_idx    (cap_trig_idx_w),
        .sample_cnt  (cap_sample_cnt),
        .st_armed    (cap_st_armed),
        .st_done     (cap_st_done),
        .st_trig     (cap_st_trig),
        .st_busy     (cap_st_busy),
        .st_ovf      (cap_st_ovf),
        .dump_start  (cap_dump_start),
        .eth_idelay_val (eth_idelay_val_w),
        .eth_idelay_ld  (eth_idelay_ld_w),
        .eth_idelay_rdy (eth_idelay_rdy_w),
        .eth_rx_clk_cnt (eth_rx_clk_cnt_w),
        .eth_rx_dv_cnt  (eth_rx_dv_cnt_w),
        .eth_rx_byte_cnt(eth_rx_byte_cnt_w),
        .eth_rx_err_cnt (eth_rx_err_cnt_w),
        .eth_rx_swap    (eth_rx_swap_w),
        .eth_rx_dbg     (eth_rx_dbg_w),
        .eth_tx_dbg_frm  (eth_tx_dbg_frm_w),
        .eth_tx_dbg_len  (eth_tx_dbg_len_w),
        .eth_tx_dbg_port (eth_tx_dbg_port_w),
        .eth_tx_dbg_mac0 (eth_tx_dbg_mac0_w),
        .eth_tx_dbg_mac1 (eth_tx_dbg_mac1_w),
        .eth_tx_dbg_ck   (eth_tx_dbg_ck_w),
        .eth_tx_dbg_dip0 (eth_tx_dbg_dip0_w),
        .eth_tx_dbg_dip1 (eth_tx_dbg_dip1_w),
        .dump_abort  (cap_dump_abort),
        .dump_busy   (dump_busy_w),
        .dump_done   (dump_done_w),
        .blocks_done (dump_blocks_done),
    // ---- 角度与位置字长 ----
        .eth_mac     (eth_cfg_mac),
        .eth_ip      (eth_cfg_ip),
        .eth_host_ip (eth_cfg_host_ip),
        .eth_port    (eth_cfg_port),
        .eth_ctrl_o  (eth_cfg_ctrl),
        .udp_start   (eth_udp_start),
        .udp_abort   (eth_udp_abort),
        .eth_tx_pkt  (eth_tx_pkt_w),
        .eth_tx_drop (eth_tx_drop_w),
        .eth_rx_pkt  (eth_rx_pkt_w),
        .eth_arp_ok  (eth_arp_seen),
        .eth_icmp_ok (eth_icmp_seen),
        .eth_host_known (eth_host_known),
        .udp_busy    (eth_udp_busy),
        .udp_done    (eth_udp_done),
        .udp_pkts    (eth_udp_pkts_w),
        .udp_drop    (eth_udp_drop_w),
        .stream_en   (stream_en_w),
        .stream_dec  (stream_dec_w),
        .stream_run  (stream_run_w),
        .stream_ovf  (1'b0),
        .stream_pkts (stream_pkts_w),
        .stream_drop (stream_drop_w),
        .stream_lag  (st_lag_w)
    );

    scope_capture #(
        .DEPTH (28672)              // 28 —? RAMB36（三 bank，非 2 的幂—?
    ) u_cap (
        .clk         (clk_i),
        .rst_n       (rst_n),
        .arm         (cap_arm | stream_arm_w),
        .abort       (cap_abort | stream_abort_w),
        .dec_log2    (cap_dec_log2),
        .cap_len     (cap_len_cfg),
        .trig_mode   (cap_trig_mode_cfg),
        .trig_level  (cap_trig_level_cfg),
        .pre_len     (cap_pre_cfg),
        .stream      (stream_en_w),
        .stream_dec  (stream_dec_w),
        .s_in        (cap_s),
        .c_in        (cap_c),
        .in_valid    (cap_valid),
        .rd_addr     (cap_rd_addr),
        .rd_en       (cap_rd_en),
        .rd_data     (cap_rd_data),
        .cap_start   (cap_start_w),
        .cap_len_eff (cap_len_eff_w),
        .trig_idx    (cap_trig_idx_w),
        .sample_cnt  (cap_sample_cnt),
        .st_armed    (cap_st_armed),
        .st_done     (cap_st_done),
        .st_trig     (cap_st_trig),
        .st_busy     (cap_st_busy),
        .st_ovf      (cap_st_ovf),
        .wr_ptr      (cap_wr_ptr_w),
        .strm_cnt    (cap_strm_cnt_w),
        .st_stream   (cap_st_stream_w)
    );

    scope_dump #(
        .DEPTH       (28672),
        .BAUD_DIV    (BAUD_DIV),
        .START_DELAY (250000),      // 5 ms @50 MHz
        .PTS         (64)
    ) u_dump (
        .clk         (clk_i),
        .rst_n       (rst_n),
        .start       (dump_start_g),
        .abort       (cap_dump_abort),
        .line_idle   (scope_idle_w && !br_tx_hold),
        .cap_start   (cap_start_w),
        .cap_len     (cap_len_eff_w),
        .rd_addr     (dump_rd_addr),
        .rd_en       (dump_rd_en),
        .rd_data     (cap_rd_data),
        .tx          (dump_tx_w),
        .busy        (dump_busy_w),
        .done        (dump_done_w),
        .blocks_done (dump_blocks_done)
    );

    //=========================================================================
    // 13.7 以太网—?—道（B2）：千兆 RGMII + ARP/ICMP + UDP 抓包推—??
    //   —? B1 的串—? dump 共用 capture 的—?—口：udp_rd_busy 时—?—口—? UDP—?
    //   否则归串—? dump。两者不会同时启—?（上位机侧互斥）—?
    //=========================================================================
    //  连续流开—?时—?—口—? stream_tx（它必须—?直—?—，不能—?打断）；
    //  否则 udp_rd_busy 时归 UDP 抓包，再否则归串—? dump—?
    assign cap_rd_addr = stream_en_w    ? st_rd_addr_w :
                         eth_udp_rd_busy ? eth_udp_rd_addr : dump_rd_addr;
    assign cap_rd_en   = stream_en_w    ? st_rd_en_w :
                         eth_udp_rd_busy ? eth_udp_rd_en   : dump_rd_en;

    eth_top #(.DEPTH(28672)) u_eth (
        .clk          (clk_i),
        .rst_n        (rst_n),
        .phy_rst_n    (phy_rst_n),
        .rgmii_txd    (eth_txd),
        .rgmii_txc    (eth_txc),
        .rgmii_tx_ctl (eth_tx_ctl),
        .rgmii_rxd    (eth_rxd),
        .rgmii_rxc    (eth_rxc),
        .rgmii_rx_ctl (eth_rx_ctl),
        .cfg_ip       (eth_cfg_ip),
        .cfg_host_ip  (eth_cfg_host_ip),
        .cfg_mac_low  (eth_cfg_mac),
        .cfg_port     (eth_cfg_port),
        .dec_log2     (cap_dec_log2),
        .udp_start    (eth_udp_start_g),
        .udp_abort    (eth_udp_abort),
        .cap_start    (cap_start_w),
        .cap_len      (cap_len_eff_w),
        .udp_rd_addr  (eth_udp_rd_addr),
        .udp_rd_en    (eth_udp_rd_en),
        .udp_rd_data  (cap_rd_data),
        .udp_rd_busy  (eth_udp_rd_busy),
        .tx_pkt       (eth_tx_pkt_w),
        .tx_drop      (eth_tx_drop_w),
        .rx_pkt       (eth_rx_pkt_w),
        .arp_seen     (eth_arp_seen),
        .icmp_seen    (eth_icmp_seen),
        .host_known   (eth_host_known),
        .udp_busy     (eth_udp_busy),
        .udp_done     (eth_udp_done),
        .udp_pkts     (eth_udp_pkts_w),
        .udp_drop     (eth_udp_drop_w),
        .wr_ptr       (cap_wr_ptr_w),
        .st_rd_addr   (st_rd_addr_w),
        .st_rd_en     (st_rd_en_w),
        .st_rd_data   (cap_rd_data),
        .stream_en    (stream_en_w),
        .stream_dec   (stream_dec_w),
        .stream_run   (stream_run_w),
        .stream_pkts  (stream_pkts_w),
        .stream_drop  (stream_drop_w),
        .stream_lag   (st_lag_w),
        .rx_clk_cnt   (eth_rx_clk_cnt_w),
        .rx_dv_cnt    (eth_rx_dv_cnt_w),
        .rx_byte_cnt  (eth_rx_byte_cnt_w),
        .rx_err_cnt   (eth_rx_err_cnt_w),
        .idelay_val   (eth_idelay_val_w),
        .idelay_ld    (eth_idelay_ld_w),
        .idelay_rdy   (eth_idelay_rdy_w),
        .rx_swap      (eth_rx_swap_w),
        .rx_dbg       (eth_rx_dbg_w),
        .tx_dbg_frm   (eth_tx_dbg_frm_w),
        .tx_dbg_len   (eth_tx_dbg_len_w),
        .tx_dbg_port  (eth_tx_dbg_port_w),
        .tx_dbg_mac0  (eth_tx_dbg_mac0_w),
        .tx_dbg_mac1  (eth_tx_dbg_mac1_w),
        .tx_dbg_ck    (eth_tx_dbg_ck_w),
        .tx_dbg_dip0  (eth_tx_dbg_dip0_w),
        .tx_dbg_dip1  (eth_tx_dbg_dip1_w)
    );

    // 连续流使能打—?拍，用来产生 arm / abort 脉冲
    always @(posedge clk_i) begin
        if (!rst_n) stream_en_q <= 1'b0;
        else        stream_en_q <= stream_en_w;
    end

    //=========================================================================
    // 13.5 显示屏 UI 只读抽头（实验专用，`ifdef ENC_DISP_TAP 门控）
    //      ★ 本赋值是**纯观测**：右侧全部是已在寄存器里的既有信号，
    //        本赋值不给任何既有组合链增加负载（disp_tap 的每位各驱动 1 个负载，
    //        —?屏幕模块的输入寄存器）—??
    //      ★ 绝不要把 r_ablimit / gap_num 一类的组合中间量放进来：
    //        那条链已经是全设计最紧路径（18.615 ns，见 impl_timing.rpt:209）。
    //      ★ 整块（含端口）一起被 `ifdef 包住：不定义 ENC_DISP_TAP 时
    //        enc_top 里既无该端口也无该赋值，生产构建与 v12 完全一致。
    //=========================================================================

`ifdef ENC_DISP_TAP
    assign disp_tap = {
        1'b0,                                   // [375]   v74：原链路静默位，恒 0
        cfg_amp_high_sq,                        // [374:343] v21 幅值上限平方（Q2.30，0x0524）
        cfg_amp_low_sq,                         // [342:311] v21 幅值下限平方（Q2.30，0x0520）
        amp_sq,                                 // [310:279] v15 实测 s²+c²（Q2.30，0x0530..33）
        {12'b0, cfg_shift_c, cfg_shift_s},      // [278:263] v15 标定粗调移位（0x051A）
        cfg_phase_k,                            // [262:247] v15 正交误差系数（0x0518/19）
        cfg_gain_c,                             // [246:231] v15 余弦增益（0x0516/17）
        cfg_gain_s,                             // [230:215] v15 正弦增益（0x0514/15）
        cfg_ofs_c,                              // [214:199] v15 余弦偏置（0x0512/13）
        cfg_ofs_s,                              // [198:183] v15 正弦偏置（0x0510/11）
        {cfg_uvwpol, cfg_zpol, cfg_bpol, cfg_apol},   // [182:179] v14 极性 4 位
        cfg_uvwph,                              // [178:163] v14 UVW 相位
        cfg_zphase,                             // [162:151] v14 Z 相位
        cfg_zwidth,                             // [150:147] v14 Z 脉宽
        cfg_ablimit,                            // [146:139] v14 AB 限频上限
        cfg_hyst_ab,                            // [138:134] v14 AB 迟滞
        1'b0,                                   // [133]   保留
        uvw_freq_warn,                          // [132]
        z_window,                               // [131]
        limiter_active,                         // [130]
        (lag_limit | lag_warn),                 // [129]
        (amp_low | amp_high),                   // [128]
        otr_lat,                                // [127]
        1'b0,                                   // [126]  v74：保留位，恒 0
        calib_done,                             // [125]
        calib_busy,                             // [124]
        cfg_uwven,                              // [123]
        cfg_abzen,                              // [122]
        cfg_pairs,                              // [121:117]
        cfg_div,                                // [116:114]
        cfg_inter,                              // [113:104]
        stat_byte,                              // [103:96]
        {amp_low | amp_high, cor_sat, cfg_uwven, cfg_abzen,
         uvw_freq_warn, z_window, lag_fatal, lag_warn},   // [95:88] io_flags
        {limiter_active, dir, w_out, v_out, u_out, z_out, b_out, a_out}, // [87:80]
        pos_full[31:0],                         // [79:48]
        c_cor,                                  // [47:32]
        s_cor,                                  // [31:16]
        angle                                   // [15:0]
    };
`endif

    //=========================================================================
    // 14. LED 与中断
    //=========================================================================
    assign led[0] = otr_lat;                              // AD 超量程
    assign led[1] = amp_low | amp_high;                   // 幅值越限（需要检查传感器/标定）
    assign led[2] = limiter_active;                       // AB 限频激活（细分倍率设太高）
    assign led[3] = calib_busy;                           // 正在标定

    assign irq_n = ~(otr_lat | amp_low | amp_high | lag_limit | lag_fatal);   // v74：去掉链路 CRC 项

    //=========================================================================
    // —?接线项与—?使用信号汇聚
    //-------------------------------------------------------------------------
    // —? 全—?——?—只有一处实例—??口空连接，且为有意为之：
    //     .cfg_h2_k ()   ← u_regs (reg_file)，见上方例化处
    //   cfg_h2_k 是二次谐波校正系数（SPI 0x051B/0x051C，复位 0），寄存器组
    //   已实现读写，但**算法侧尚未接入**：rtl/sc_correct.v 头注释第 3 条写明
    //   "h2_k 0x051B/1C（预留，未接入本模块）"。未来接入方式见
    //   rtl/calib_ctrl.v 头注释（估计 h2_k = 2*(S6+S7)/N，由 sc_correct 执行
    //   s -= (h2_k * s2_est) >>> 15）。这是**预留位，不是缺陷**：本版不做
    //   二次谐波补偿，对应 docs/02 的创新点 9（"未来工作"加分点）。
    //   因此 u_regs.cfg_h2_k **故意不连**，避免被综合当成未驱动而告警。
    //
    // ★ 原"已知未接线项 cfg_hyst_uvw"已于 2026-10 修复：uvw_gen 新增
    //   [4:0] uvw_hyst 输入端口并接到 cfg_hyst_uvw（寄存器 0x0104 UVW.hyst）。
    //   语义见 rtl/uvw_gen.v 头注释第 3 条：uvw_hyst != 0 时死区 = 该值
    //   （单位 = 角度 LSB，1 LSB = 360/65536 = 0.0054932° 电角度），
    //   uvw_hyst == 0 时回退到编译期默认 UVW_HYST_SHIFT（默认 6 → 1024 LSB）。
    //   ★★ 曾尝试的修法（**已放弃，勿重复走这条路**）：给翻转检测加"先稳定再接受"
    //
    // 以下汇聚—?为避免综合工具产生大量未连接告—?—，不影响—?—辑—?
    // 用 tools/scan_dangling.py 逐项核对过：列表 20 项**全部有真实功能读者**
    // （除汇聚外还有 1~19 个），没有任何悬空信号被塞进来充数。
    wire unused_ok = &{1'b0, cor_valid, amp_valid, abz_valid, uvw_valid, pole_valid,
                       cordic_mag[0], pole_pairs_eff[0], cfg_st_bits[0], cfg_mt_bits[0],
                       calib_state_dbg[0], dir, wrap_neg, amp_ok,
                       edge_cnt[0], pos_ext[0]};   // v74：原链路相关 5 项已随模块删除

endmodule
