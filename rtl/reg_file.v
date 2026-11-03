// ============================================================================
//  reg_file.v  ——  配置/状态寄存器组 (SPI 从站寄存器空间)
// ----------------------------------------------------------------------------
//  功能
//    · 复现 iC-TW28 寄存器地址（低 bank 0x0000..0x0FFF 中"便宜"的那些），
//      我们的扩展寄存器放在 0x5xxx 段（不与 TW28 冲突）。
//    · 输出各功能模块需要的**扁平化配置总线**（cfg_*）。
//    · 把顶层状态（幅值平方、多周期计数、完整位置、故障标志、链路状态）
//      映射成可经 SPI 读回的寄存器，供上位机绘图。
//    · 支持 calib_ctrl 的字节写口（优先级高于主机写口）。
//
//  地址位宽说明（重要解释）
//    契约 1.11 的端口片段写 `input wire [7:0] addr`，但同一节要求的地址表里
//    有 0x0100 / 0x0300 / 0xE000 等 16 位地址 —— 二者矛盾。本实现用
//    parameter AW = 16（默认）以覆盖全部地址；把 AW 设为 8 即回到契约字面写法。
//    >>> 集成注意：AW 必须 >= 12 才能访问 0x5xxx 扩展段（标定结果/状态/幅值/
//        pos_full/DEVICE_ID@0x5F0）。若顶层用 AW=8，则只有 0x00..0x7F 可达，
//        此时仅有 MAIN_CFG/LED_CFG/LED_START/TEST 以及器件识别别名
//        0x7E(DEVICE_ID)/0x7F(REV) 可用。spi_slave 必须使用同一个 AW。
//        当前 rtl/enc_top.v 里写的是 #(.AW(8))，建议改为 16（并把 spi_addr 加宽）。
//
//  读数据位宽
//    rdata 为 8 位（契约），16/32 位寄存器按**小端字节序**连续地址读出：
//    例如 cfg_amp_low_sq[31:0] 在 0x0520(低字节) .. 0x0523(高字节)。
//
//  扁平化输出说明
//    契约 1.11 片段写 `output reg [9:0] cfg_inter, cfg_zphase, ...`；这些信号
//    是存储寄存器的纯组合拼接，没有寄存器语义，故本实现用 output wire + assign，
//    避免误解与不必要的 FF。
//    cfg_zphase 取 12 位（契约片段误写 9:0；1.8 明确是 [11:0]）。
//    cfg_uvwph 单位 = 2^16/周期角度的 LSB：
//        UVWPS = 4*UVWPH[7:0] + PHASE_LSB[3:2]  (10 位, 单位 360/1024)
//        cfg_uvwph = UVWPS * 64 = {UVWPS, 6'b000000}
//    cfg_zphase 同理：ZPH = 4*ZPHASE[7:0] + PHASE_LSB[1:0]（单位 360/1024），
//        cfg_zphase = {ZPHASE[7:0], PHASE_LSB[1:0], 2'b00}（单位 360/4096）
//
//  cfg_st_bits / cfg_mt_bits 说明
//    这两个是原从站帧位宽的只读回读量（原为**综合期参数**，无法运行时改变）；
//    v74 起恒 0，地址与抽头位保留（位图不重排），不再参与任何判据。
//
//  DEVICE_ID / REV
//    DEVICE_ID = 8'h0C（与 iC-TW28 一致，便于上位机复用 GUI）。
//    REV = 8'h10（本设计自己的版本号 v1.0，故意**不**用 TW28 的 0x11/0x14，
//    以免上位机误判为真芯片）。别名：0x05F0/0x05F1、0xE000/0xE002、0x007E/0x007F。
//
//  ============================ 地址表 ==================================
//  | 地址      | 名称        | 位域/含义                          | 默认  | 说明 |
//  |-----------|-------------|------------------------------------|-------|------|
//  | 0x0000    | MAIN_CFG    | [1:0]input [2]noise [3]rs422       | 0x28  | 仅存储，本设计不改变模拟前端 |
//  |           |             | [4]irqpp [5]elinkoff               |       |      |
//  | 0x0001    | LED_CFG     | LED PWM 配置                       | 0x00  | 无 LED 硬件，仅存储 |
//  | 0x0002    | LED_START   | LED 起始亮度                       | 0x00  | 仅存储 |
//  | 0x000B    | TEST        | 测试寄存器                         | 0x00  | 仅存储 |
//  | 0x0010    | LED_PWM     | 读回 = LED_START                   | -     | 只读别名 |
//  | 0x007E    | DEVICE_ID_A | 器件 ID 别名（简单 SPI 模式用）     | 0x0C  | 只读 |
//  | 0x007F    | REV_A       | 版本别名                           | 0x10  | 只读 |
//  | 0x0100    | UVW_CFG     | [4:0]pairs 极对数(0=32)            | 0x04  | ->cfg_pairs |
//  | 0x0101    | INTER0      | INTER[7:0]                         | 0x00  | ->cfg_inter[7:0] |
//  | 0x0102    | INTER1      | [1:0]INTER[9:8] [4:2]div           | 0x00  | ->cfg_inter[9:8],cfg_div |
//  | 0x0103    | AB          | [4:0]hyst                          | 0x00  | ->cfg_hyst_ab |
//  | 0x0104    | UVW         | [4:0]hyst                          | 0x00  | ->cfg_hyst_uvw |
//  | 0x0105    | FALARM      | 输入频率告警等级                    | 0x00  | 仅存储 |
//  | 0x0106    | ABLIMIT     | AB 限频(0..255)                    | 0x00  | ->cfg_ablimit |
//  | 0x0107    | ZERO0       | [5:0]threshold [6]clr [7]mode      | 0x0A  | 仅存储 |
//  | 0x0108    | ZERO1       | [3:0]zwidth                        | 0x00  | ->cfg_zwidth |
//  | 0x0109    | OUTPUT      | [0]apol [1]bpol [2]zpol [3]abzdir  | 0x40  | ->cfg_*pol/abzen/uwven |
//  |           |             | [4]uvwpol [5]uvwdir [6]abzen [7]uwven|     |      |
//  | 0x010A    | ZPHASE      | ZPHASE[9:2]                        | 0x00  | ->cfg_zphase[11:4] |
//  | 0x010B    | UVWPH       | UVWPH[9:2]                         | 0x00  | ->cfg_uvwph[15:6] |
//  | 0x010C    | PHASE_LSB   | [1:0]z [3:2]uvw                    | 0x00  | ->相位低 2 位 |
//  | 0x0300    | FILT_CFG    | [2:0]kpmax [3]fb [4]auto           | 0x06  | 仅存储 |
//  | 0x0301    | FILT_LAG    | [4:0]threshold                     | 0x0C  | 仅存储 |
//  | 0x0302    | FILT_K      | [2:0]kp [4:3]ki                    | 0x1A  | ->cfg_kp/cfg_ki |
//  | 0x0400    | STAT_CFG    | [2:0]filter [3]long [4]enc [5]enz  | 0x34  | 仅存储 |
//  | 0x0401    | STAT_SEL    | 故障选择                           | 0x00  | 仅存储 |
//  | 0x0402    | STAT_IE     | 故障使能                           | 0x38  | 仅存储 |
//  | 0x0403    | STAT_HIZ    | 故障高阻                           | 0x00  | 仅存储 |
//  | 0x0404    | STAT_VAL    | [0]oflow [2]laglim [3]inclim       | -     | 只读，实时组合 |
//  |           |             | [5]scamp (b1/b4/b6/b7 恒 0)        |       |      |
//  | 0x0405    | STAT_LATCH  | 同上，锁存；写 1 清对应位           | 0x00  | 只读+W1C |
//  |           |             | ★写 bit0 还同时发出 1 拍 clr_otr 脉冲，|       |      |
//  |           |             |  清 ADC 内部 sticky OTR（见下方端口）； |       |      |
//  |           |             |  ★v1.1 同一个脉冲还清链路 CRC 粘滞位|      |      |
//  | 0x0406    | STAT_FATAL  | 致命故障                           | 0x00  | 只读(恒 0) |
//  | 0x0601-03 | EE_ADDR/DATA/STAT | EEPROM 访问                  | 0x00  | 无 EEPROM，恒 0 |
//  | 0x0500    | ST_BITS     | [5:0] 单圈位宽（保留）                | 0     | 只读恒 0 |
//  | 0x0501    | MT_BITS     | [5:0] 多圈位宽（保留）                | 0     | 只读恒 0 |
//  | 0x0502    | CALIB_CTRL  | 写:[0]start(自清) [2]清 done       | 0x00  | 读:[1]busy [2]done |
//  |           |             |                                    |       | [3]truncated |
//  |           |             |                                    |       | [7:5]标定重试次数 |
//  |           |             |                                    |       | [4]win_bad(窗口非整 |
//  |           |             |                                    |       |    周期，结果可能有偏)|
//  | 0x0503/04 | CALIB_N     | 标定窗口周期数(16 位小端)           | 64    | ★接 calib_ctrl.win_cycles |
//  |           |             |                                    |       | ★0 视为默认 64（见 enc_top.v） |
//  |           |             | ★陷阱：包模式写一次事务写 2 字节（spi_slave.v:244-251），|
//  |           |             |   所以按 16 位写 0x0502=0x0001 会把高字节 0x00 落到    |
//  |           |             |   0x0503（CALIB_N 低字节）。主机请先写 0x0503/0x0504   |
//  |           |             |   （默认 0x00/0x40 = 64），再触发 0x0502。            |
//  | 0x0510/11 | OFS_S       | 正弦偏置 Q1.15 有符号               | 0     | 标定结果，可主机改写 |
//  | 0x0512/13 | OFS_C       | 余弦偏置 Q1.15 有符号               | 0     | 同上 |
//  | 0x0514/15 | GAIN_S      | 正弦增益 Q1.15 无符号               | 32768 | 同上 |
//  | 0x0516/17 | GAIN_C      | 余弦增益 Q1.15 无符号               | 32768 | 同上 |
//  | 0x0518/19 | PHASE_K     | 正交误差系数 Q1.15 有符号           | 0     | 同上 |
//  | 0x051A    | SHIFT       | [1:0]shift_s [3:2]shift_c 粗调移位  | 0x00  | 同上 |
//  | 0x051B/1C | H2_K        | [15:0] 二次谐波系数（预留/未来）      | 0     | 仅供二级谐波校正 |
//  | 0x0520-23 | AMP_LOW_SQ  | 幅值下限平方 Q2.30 (32 位小端)      |0x170A3D71| ->cfg_amp_low_sq |
//  | 0x0524-27 | AMP_HIGH_SQ | 幅值上限平方 Q2.30                 |0x5C28F5C3| ->cfg_amp_high_sq |
//  | 0x0530-33 | STAT_AMP_SQ | 实测 s²+c² (Q2.30)                 | -     | 只读 |
//  | 0x0534/35 | STAT_CYCLE  | 多周期计数 (16 位小端)              | -     | 只读 |
//  | 0x0536-39 | STAT_POS    | 完整位置 {cycle,angle} (32 位小端)  | -     | 只读 |
//  | 0x053A    | STAT_FLAGS  | [0]laglim [1]amplo [2]amphi [3]otr | -     | 只读 |
//  |           |             | [4]caldone [5]calbusy [6]保留      |       |      |
//  |           |             | [7]保留位                          |       |      |
//  | 0x053B/3C | STAT_FRAME  | 帧内已发位数（保留，恒 0）                   | -     | 只读 |
//  | 0x05F0    | DEVICE_ID   | = 0x0C                             | 0x0C  | 只读 |
//  | 0x05F1    | REV         | = 0x10                             | 0x10  | 只读 |
//  | 0xE000    | DEVICE_ID   | = 0x0C（TW28 原地址）               | 0x0C  | 只读 |
//  | 0xE002    | REV0        | = 0x10                             | 0x10  | 只读 |
//  | 0xE003    | REV1        | = 0x00                             | 0x00  | 只读 |
//  ======================================================================
//
//  Latency
//    写：we 有效 -> 配置输出更新 1 拍（寄存器）+ 组合拼接。
//    读：addr -> rdata 纯组合（0 拍）。
//
//  资源估计 / 关键假设
//    FF ≈ 200（约 30 个 8 位寄存器 + 6 个 16 位 + 2 个 32 位）
//    LUT ≈ 350（2 个 16 位比较器树的大 case 译码）
//    假设 1) 无 EEPROM，上电默认值即本文件列出的值（TW28 的 EEPROM 语义不实现）
//         2) 0x0405 用"写 1 清位"（TW28 为写 0 清位）—— 因为整字节写入时
//            写 0 清位会一次抹掉全部锁存，故改为 W1C 并在此说明。
//         3) calib_we 与主机 we 同拍时 calib_we 优先（两者不会撞同一地址）。
//         4) 0x0405[0] 除了清 STAT_LATCH 的 otr 位，还输出 1 拍 clr_otr 脉冲，
//            送给 ad9238_capture 清它内部的 sticky OTR（该 sticky 与锁存位是
//            两个独立的锁存器：前者在 ADC 采集模块内部、用 otr_lat 探针看，
//            后者在寄存器组里、用 0x0405 读回看）。2026-10-10 上板实测发现
//            clr_otr 原本在顶层被硬接 1'b0，导致 OTR 一旦锁存就永久保持
//            （led[0] 常亮、irq_n 常低），只能重配置器件；现挂到 W1C 上。
// ============================================================================

module reg_file #(
    parameter integer AW        = 16,
    parameter integer DW        = 8,
    // v74：原帧位宽参数 ST_BITS_R / MT_BITS_R 一并移除
    parameter [7:0]   DEVICE_ID = 8'h0C,
    parameter [7:0]   REV       = 8'h10
)(
    input  wire          clk,
    input  wire          rst_n,
    // ---- 主机(SPI)访问 ----
    input  wire [AW-1:0] addr,
    input  wire [DW-1:0] wdata,
    input  wire          we,
    output reg  [DW-1:0] rdata,

    // ---- 0x0700 段扩展寄存器总线（交给 cap_regs，见 rtl/cap_regs.v）----
    //     reg_file 只负责"把 0x07xx 的读写转出去"，不关心抓包语义。
    output wire          ext_we,
    output wire [15:0]   ext_addr,
    output wire [7:0]    ext_wdata,
    input  wire [7:0]    ext_rdata,
    // ---- 标定写口（优先级高于主机写口）----
    input  wire          calib_we,
    input  wire [15:0]   calib_addr,
    input  wire [7:0]    calib_wdata,
    input  wire          calib_busy,
    input  wire          calib_done,
    input  wire          calib_trunc,
    input  wire [2:0]    calib_retry,     // ★ 因"窗口非整周期"丢弃重来的次数
    input  wire          calib_bad,       // ★ 重试用尽仍有非整周期窗口
    // ---- ★ v6 诊断输入（角度毛刺计数 / 周期脉冲计数 / 标定窗口快照）----
    //   只读段：0x0505..0x050E（毛刺与脉冲）、0x0540..0x0549（窗口快照）、0x05F2/0x05F3
    //   （RTL 版本号）。用途见 docs/DEV_STATUS.md §1.32。
    input  wire [15:0]   gl_cnt_1024,     // 相邻有效样本角度差 > 5.6°(1024) 的次数
    input  wire [15:0]   gl_cnt_2048,     // > 11.25°(2048)
    input  wire [15:0]   gl_cnt_4096,     // > 22.5°(4096)
    input  wire [15:0]   gl_cnt_8192,     // > 45°(8192)　← v5 用过的阈值，作对照
    input  wire [15:0]   gl_hold_cnt,     // 5b 节"毛刺保持"实际动作次数
    input  wire [15:0]   cyc_pulse_cnt,   // 周期脉冲累计数（与毛刺计数配比值）
    input  wire [17:0]   dbg_int_min,     // 最近关门窗口内最小周期间隔（样本数）
    input  wire [17:0]   dbg_int_max,     // 最近关门窗口内最大周期间隔
    input  wire [17:0]   dbg_nsamp_cls,   // 最近关门窗口的样本数
    input  wire [15:0]   dbg_wcnt_cls,    // 最近关门窗口完成的输入周期数
    input  wire [15:0]   rtl_build_id,    // ★ RTL 版本号（v6 = 16'h0006，v7 = 16'h0007，v8 = 16'h0008）
    // ---- 扁平化配置输出 ----
    output wire [9:0]        cfg_inter,
    output wire [2:0]        cfg_div,
    output wire [7:0]        cfg_ablimit,
    output wire [4:0]        cfg_hyst_ab,
    output wire [4:0]        cfg_hyst_uvw,
    output wire [4:0]        cfg_pairs,
    output wire [11:0]       cfg_zphase,
    output wire [3:0]        cfg_zwidth,
    output wire [15:0]       cfg_uvwph,
    output wire [3:0]        cfg_kp,
    output wire [1:0]        cfg_ki,
    output wire              cfg_apol,
    output wire              cfg_bpol,
    output wire              cfg_zpol,
    output wire              cfg_abzdir,
    output wire              cfg_uvwpol,
    output wire              cfg_uvwdir,
    output wire              cfg_abzen,
    output wire              cfg_uwven,
    output wire signed [15:0] cfg_ofs_s,
    output wire signed [15:0] cfg_ofs_c,
    output wire [15:0]       cfg_gain_s,
    output wire [15:0]       cfg_gain_c,
    output wire signed [15:0] cfg_phase_k,
    output wire [1:0]        cfg_shift_s,
    output wire [1:0]        cfg_shift_c,
    output wire [31:0]       cfg_amp_low_sq,
    output wire [31:0]       cfg_amp_high_sq,
    output wire [15:0]       cfg_h2_k,
    output wire [15:0]       cfg_calib_n,      // ★ 标定窗口周期数（0x0503/04），接到 calib_ctrl.win_cycles
    // ★ v9（S2）延迟前馈（rtl/lag_ff.v）
    output wire [15:0]       cfg_tau_q8,       // 0x0120/21：总延迟 T，单位=抽样点，Q8
    output wire              cfg_ff_en,        // 0x0122 bit0：1=补偿
    output wire              cfg_bias_en,      // 0x0122 bit1：1=偏置慢跟踪（复位值 0）
    input  wire signed [23:0] ff_speed,        // 只读：每抽样点位置增量（= 环路积分器）
    input  wire signed [23:0] ff_corr,         // 只读：当前延迟修正量（位置单位）
    // ★ v9（S5）全周补偿表（rtl/angle_lut.v）：主机整表写入
    output wire              cfg_lut_en,       // 0x0145 bit0：1=启用补偿表
    output wire              lut_wr_en,        // 写 0x0144（数据高字节）时产生 1 拍写使能
    output wire [11:0]       lut_wr_addr,      // 0x0141/0x0142：表地址
    output wire [15:0]       lut_wr_data,      // 0x0143/0x0144：表数据（16 位有符号）
    output wire              cfg_lut_probe,    // 0x0145 bit1：1=读口改由表地址驱动（回读校验）
    input  wire [15:0]       lut_rd_q,         // 表读口数据（只读回读：0x0146/0x0147）
    // ★ v9（S3）锁定状态机（rtl/lock_sm.v）
    input  wire [1:0]         lock_state,      // 0=INIT 1=TRACK 2=LOST
    input  wire               lock_lost_evt,   // 1 拍脉冲：进入 LOST
    input  wire               lock_acq_evt,    // 1 拍脉冲：进入 TRACK
    input  wire [15:0]        lock_lost_cnt,   // 累计掉锁次数
    input  wire [15:0]        lock_bad_run,    // 当前连续坏样本数
    // ★ v9（S4）偏置慢跟踪（rtl/bias_track.v）——只读回显
    input  wire signed [15:0] bias_s,          // 0x0138/0x0139：sin 偏置估计
    input  wire signed [15:0] bias_c,          // 0x013A/0x013B：cos 偏置估计
    input  wire               bias_valid,      // 0x013C bit0：EMA 已收敛
    input  wire               bias_big,        // 0x013C bit1：偏置超限
    output reg               calib_start,      // 1 拍脉冲（写 CALIB_CTRL[0]）
    output reg               clr_otr,          // 1 拍脉冲（写 STAT_LATCH[0]=1）→ 清 ADC sticky OTR
    // ---- 状态输入（供上位机读回绘图）----
    input  wire [31:0]   stat_amp_sq,
    input  wire          stat_lag_limit,
    input  wire          stat_amp_low,
    input  wire          stat_amp_high,
    input  wire          stat_otr,
    input  wire [15:0]   stat_cycle_cnt,
    input  wire [31:0]   stat_pos_full,
    input  wire          stat_inclim,
    input  wire [31:0]   stat_z_cnt       // v73：Z 上升沿计数（调试）
);

    // ==================================================================
    // 存储寄存器
    // ==================================================================
    reg [7:0]  r_main_cfg, r_led_cfg, r_led_start, r_test;
    reg [7:0]  r_uvw_cfg, r_inter0, r_inter1;
    reg [7:0]  r_ab_hyst, r_uvw_hyst, r_falarm, r_ablimit;
    reg [7:0]  r_zero0, r_zero1, r_output;
    reg [7:0]  r_zphase, r_uvwph, r_phase_lsb;
    reg [7:0]  r_filt_cfg, r_filt_lag, r_filt_k;
    reg [7:0]  r_stat_cfg, r_stat_sel, r_stat_ie, r_stat_hiz, r_stat_latch;

        reg [15:0] r_calib_n;
    reg signed [15:0] r_ofs_s, r_ofs_c, r_phase_k;
    reg [15:0] r_gain_s, r_gain_c;
    reg [1:0]  r_shift_s, r_shift_c;
    reg [15:0] r_h2_k;
    reg [31:0] r_amp_low_sq, r_amp_high_sq;
    reg [15:0] r_tau_q8;          // v9（S2）延迟前馈：总延迟 Q8 抽样点
    reg [7:0]  r_ff_cfg;          // v9（S2）[0]=en
    reg [7:0]  r_lock_sticky;     // v9（S3）[0]=曾锁定 [1]=曾掉锁（W1C）
    reg [11:0] r_lut_addr;        // v9（S5）补偿表地址
    reg [15:0] r_lut_data;        // v9（S5）补偿表数据
    reg [7:0]  r_lut_ctrl;        // v9（S5）[0]=en
    reg        r_lut_wr;          // v9（S5）1 拍写脉冲
    reg        r_calib_done;
    reg        calib_done_d;      // calib_done 边沿检测

    // 状态实时值（TW28 STAT_VAL 位序）
    wire [7:0] stat_val_now = {2'b00, (stat_amp_low | stat_amp_high), 1'b0,
                               stat_inclim, stat_lag_limit, 1'b0, stat_otr};

    // ==================================================================
    // 写逻辑
    // ------------------------------------------------------------------
    //  0x0700 段：整段转给 cap_regs（抓包）。这里只做地址判选，
    //  写脉冲原样转发，读数据在 rdata 的 default 分支里回填。
    // ------------------------------------------------------------------
    assign ext_we    = we && (addr[15:8] == 8'h07);
    assign ext_addr  = addr;
    assign ext_wdata = wdata;

    // ==================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            r_main_cfg   <= 8'h28;          // 双极性/RS422/elinkoff
            r_led_cfg    <= 8'h00;
            r_led_start  <= 8'h00;
            r_test       <= 8'h00;
            r_uvw_cfg    <= 8'h04;          // pairs = 4
            r_inter0     <= 8'd32;          // 2048 周期/转 × 2×32 = 131072 边沿/转
                                            //      注意 INTER=0 会被解释成 256
            r_inter1     <= 8'h00;          // div = 1
            r_ab_hyst    <= 8'h00;
            r_uvw_hyst   <= 8'h00;
            r_falarm     <= 8'h00;
            r_ablimit    <= 8'h00;
            r_zero0      <= 8'h0A;          // threshold = 10 (TW28 pin 默认)
            // Z 脉冲宽度默认 4（zwidth=4）⇒ ★ v9 起实际宽度 = z_width + 1 = 5 个边沿步
            //   （对齐 TW28 手册 `(zwidth+1)/div`，见 docs/DEV_STATUS.md §1.47）。
            // ⚠ 历史：v8 及以前 abz_gen 里是
            //   `assign z_pulse_n = (z_width == 4'd0) ? 4'd0 : z_width;`
            //   于是 zwidth=0 会把 Z 永久钉死为 0（上板时看不到 Z）。
            //   v9 改为 `z_pulse_n = z_width + 1` 后这一坑消失（0 ⇒ 1 步），
            //   但默认值仍保持 4（⇒ 5 步 ≈ 5/(1024·f_in)，1 kHz 下 4.88 µs）。
            r_zero1      <= 8'h04;
            r_output     <= 8'hC0;          // ★ 2026-10-28：abzen = 1, uwven = 1
                                            //   历史：v62 及以前为 8'h40（uwven=0），
                                            //   原因是 UVW 当时由"正弦周期内角度"驱动，
                                            //   电周期/转 = PPR×pairs，与真实极对数不符
                                            //   （见 docs/20 §7.5）。2026-10-28 改成
                                            //   enc_top 用机械角驱动 uvw_gen、pairs 填真实
                                            //   极对数后，UVW 语义已正确，可安全默认开启。
                                            //   ⚠ 前提：cfg_pairs（0x0100）必须等于电机
                                            //   真实极对数 P，否则换向相位错。默认 4 只适合
                                            //   4 极对电机；上位机/屏幕应先读出来再写。
                                            //   若驱动器不用 UVW 换向，可写 0x0109=0x40 关掉。
            r_zphase     <= 8'h00;
            r_uvwph      <= 8'h00;
            r_phase_lsb  <= 8'h00;
            r_filt_cfg   <= 8'h06;          // kpmax = 6
            r_filt_lag   <= 8'h0C;          // threshold = 12
            r_filt_k     <= 8'h1A;          // ★ v8：kp = 2, ki = 3（门控环路的配套档位）
                                            //   历史：v7 及以前为 8'h04（kp = 4, ki = 0 纯 P），
                                            //   那是为绕开"环路状态每 clk 迭代、in_valid 只有
                                            //   12.5 MHz ⇒ I 项每样本增益 ×4"（§1.39/§1.40）。
                                            //   v8 起 rtl/enc_top.v 的 loop_filter 例化传
                                            //   .GATE_STATE(1)，状态只在 in_valid 拍更新 ⇒ 增益
                                            //   恢复"每样本"语义，可用回带 I 项的档位（恒速下稳态
                                            //   滞后为 0）。档位依据 sim/tb_loop_abz_chain.v 的
                                            //   B 链（GATE_STATE=1）A/B 回放：kp2/ki3 ⇒ AB 跳变
                                            //   126 = 理想计数、|d| 最大 11 LSB、0 次方向反转
                                            //   （对照 v7 生产档 kp4/ki0 非门控：126、|d| 最大 7 LSB、
                                            //   0 次反转；而 kp4/ki3 非门控 = 482 跳变 / 816 次反转）。
                                            //   ⚠ 0x0302 写 16 位是**两字节事务**，主机若要改档必须
                                            //   按 §DEV_STATUS 的口径写低字节（0x1A）。
            r_stat_cfg   <= 8'h34;          // filter = 3, long = 1
            r_stat_sel   <= 8'h00;
            r_stat_ie    <= 8'h38;          // inclim | lagfatl | scamp
            r_stat_hiz   <= 8'h00;
            r_stat_latch <= 8'h00;
            r_calib_n    <= 16'd64;
            r_ofs_s      <= 16'sd0;
            r_ofs_c      <= 16'sd0;
            r_gain_s     <= 16'd32768;      // Q1.15 unity
            r_gain_c     <= 16'd32768;
            r_phase_k    <= 16'sd0;
            r_shift_s    <= 2'd0;
            r_shift_c    <= 2'd0;
            r_h2_k       <= 16'd0;
            r_amp_low_sq <= 32'h170A3D71;   // (0.60)² * 2^30
            r_amp_high_sq<= 32'h5C28F5C3;   // (1.20)² * 2^30
            // v9（S2）：延迟前馈默认打开。9 个抽样点 = 720 ns，覆盖实测 0.59~0.83 µs 的
            //   中位值；低速时可无视，高速时必须准（±0.1 抽样点 ≈ 1.4″ @3000 rpm）。
            //   现场微调：把转速稳定在一个值，读 0x0127..29（corr），
            //   或直接按 0x0120/21 写入实测延迟。
            r_tau_q8     <= 16'd2304;       // 9.0 抽样点 × 256
            r_ff_cfg     <= 8'h01;          // bit0 en=1
            r_lock_sticky<= 8'h00;
            r_lut_addr   <= 12'd0;          // v9（S5）
            r_lut_data   <= 16'd0;
            r_lut_ctrl   <= 8'h00;          // 默认不启用补偿表（无基准时旁路）
            r_lut_wr     <= 1'b0;
            r_calib_done <= 1'b0;
            calib_done_d <= 1'b0;
            calib_start  <= 1'b0;
            clr_otr      <= 1'b0;
        end else begin
            calib_start  <= 1'b0;           // 默认：标定启动脉冲为 0
            clr_otr      <= 1'b0;           // 默认：OTR 清位脉冲为 0
            calib_done_d <= calib_done;

            // ---------------- 标定写口（优先）----------------
            if (calib_we) begin
                case (calib_addr)
                16'h0510: r_ofs_s[7:0]   <= calib_wdata;
                16'h0511: r_ofs_s[15:8]  <= calib_wdata;
                16'h0512: r_ofs_c[7:0]   <= calib_wdata;
                16'h0513: r_ofs_c[15:8]  <= calib_wdata;
                16'h0514: r_gain_s[7:0]  <= calib_wdata;
                16'h0515: r_gain_s[15:8] <= calib_wdata;
                16'h0516: r_gain_c[7:0]  <= calib_wdata;
                16'h0517: r_gain_c[15:8] <= calib_wdata;
                16'h0518: r_phase_k[7:0] <= calib_wdata;
                16'h0519: r_phase_k[15:8]<= calib_wdata;
                16'h051A: begin
                              r_shift_s <= calib_wdata[1:0];
                              r_shift_c <= calib_wdata[3:2];
                          end
                default: ;
                endcase
            end

            // ---------------- 主机写口 ----------------
            if (we) begin
                case (addr)
                16'h0000: r_main_cfg  <= wdata;
                16'h0001: r_led_cfg   <= wdata;
                16'h0002: r_led_start <= wdata;
                16'h000B: r_test      <= wdata;
                16'h0100: r_uvw_cfg   <= wdata;
                16'h0101: r_inter0    <= wdata;
                16'h0102: r_inter1    <= wdata;
                16'h0103: r_ab_hyst   <= wdata;
                16'h0104: r_uvw_hyst  <= wdata;
                16'h0105: r_falarm    <= wdata;
                16'h0106: r_ablimit   <= wdata;
                16'h0107: r_zero0     <= wdata;
                16'h0108: r_zero1     <= wdata;
                16'h0109: r_output    <= wdata;
                16'h010A: r_zphase    <= wdata;
                16'h010B: r_uvwph     <= wdata;
                16'h010C: r_phase_lsb <= wdata;
                // ---- v9（S2）延迟前馈：TAU_Q8 / FF_CFG ----
                16'h0120: r_tau_q8[7:0]  <= wdata;
                16'h0121: r_tau_q8[15:8] <= wdata;
                16'h0122: r_ff_cfg       <= wdata;
                // ---- v9（S5）全周补偿表：地址 0x0141/42、数据 0x0143/44、控制 0x0145 ----
                //   写 0x0144（高字节）的那一拍由 r_lut_wr 产生 1 拍写脉冲，
                //   所以主机顺序固定：写低字节→写高字节→表内容已写入。
                16'h0141: r_lut_addr[7:0]  <= wdata;
                16'h0142: r_lut_addr[11:8] <= wdata[3:0];
                16'h0143: r_lut_data[7:0]  <= wdata;
                16'h0144: r_lut_data[15:8] <= wdata;
                16'h0145: r_lut_ctrl       <= wdata;
                16'h0300: r_filt_cfg  <= wdata;
                16'h0301: r_filt_lag  <= wdata;
                16'h0302: r_filt_k    <= wdata;
                16'h0400: r_stat_cfg  <= wdata;
                16'h0401: r_stat_sel  <= wdata;
                16'h0402: r_stat_ie   <= wdata;
                16'h0403: r_stat_hiz  <= wdata;
                // 0x0405 STAT_LATCH 的 W1C 在下方统一处理（见"状态锁存"）
                16'h0502: begin
                              if (wdata[0]) calib_start  <= 1'b1;   // 启动标定
                              if (wdata[2]) r_calib_done <= 1'b0;   // 清 done
                          end
                16'h0503: r_calib_n[7:0]   <= wdata;
                16'h0504: r_calib_n[15:8]  <= wdata;
                16'h0510: r_ofs_s[7:0]   <= wdata;
                16'h0511: r_ofs_s[15:8]  <= wdata;
                16'h0512: r_ofs_c[7:0]   <= wdata;
                16'h0513: r_ofs_c[15:8]  <= wdata;
                16'h0514: r_gain_s[7:0]  <= wdata;
                16'h0515: r_gain_s[15:8] <= wdata;
                16'h0516: r_gain_c[7:0]  <= wdata;
                16'h0517: r_gain_c[15:8] <= wdata;
                16'h0518: r_phase_k[7:0] <= wdata;
                16'h0519: r_phase_k[15:8]<= wdata;
                16'h051A: begin
                              r_shift_s <= wdata[1:0];
                              r_shift_c <= wdata[3:2];
                          end
                16'h051B: r_h2_k[7:0]    <= wdata;
                16'h051C: r_h2_k[15:8]   <= wdata;
                16'h0520: r_amp_low_sq[7:0]   <= wdata;
                16'h0521: r_amp_low_sq[15:8]  <= wdata;
                16'h0522: r_amp_low_sq[23:16] <= wdata;
                16'h0523: r_amp_low_sq[31:24] <= wdata;
                16'h0524: r_amp_high_sq[7:0]   <= wdata;
                16'h0525: r_amp_high_sq[15:8]  <= wdata;
                16'h0526: r_amp_high_sq[23:16] <= wdata;
                16'h0527: r_amp_high_sq[31:24] <= wdata;
                default: ;
                endcase
            end

            // ---------------- 状态锁存 ----------------
            if (we && (addr == 16'h0405)) begin
                r_stat_latch <= r_stat_latch & ~wdata;      // W1C
            end else begin
                r_stat_latch <= r_stat_latch | stat_val_now;
            end

            // ---------------- ADC sticky OTR 清位脉冲 ----------------
            //   写 0x0405 的 bit0（STAT_LATCH 里的 otr 位）时，同一拍发出 1 拍脉冲，
            //   清掉 ad9238_capture 内部的 sticky otr（rtl/ad9238_capture.v:156）。
            //   为什么必须放在这里：该模块的 clr_otr 在顶层原本被硬接 1'b0
            //   （rtl/enc_top.v:228），而上板实测（2026-10-10）OTR 一旦锁存就
            //   永久保持 —— led[0] 常亮、irq_n 常低，降幅度、按 KEY0 都无效，
            //   只能重新配置器件。挂上 W1C 后主机可随时清位。
            //   语义：若 OTR 引脚此刻仍为高，几拍后会重新锁存 —— 这正是我们
            //   想要的（能区分"瞬时过载"与"真的过载"）。
            //   时序：clk_cap 与 clk 同为 clk_i（单时钟域，rtl/enc_top.v:221），
            //   1 拍脉冲足够 —— ad9238_capture 在同一拍冲刷 OTR 同步流水线并清零。
            clr_otr <= we && (addr == 16'h0405) && wdata[0];

            // ---------------- v9（S5）补偿表写脉冲 ----------------
            //   ★ 必须是"写 0x0144 之后的那一拍"才把数据推给 BRAM，否则低字节
            //     还在路上就写进去了。这里用寄存器延迟一拍：0x0144 写入当拍
            //     r_lut_data[15:8] 更新，下一拍 r_lut_wr=1 时 BRAM 看到的是新数据。
            r_lut_wr <= we && (addr == 16'h0144);

            // ---------------- 标定完成置位（上升沿）----------------
            if (calib_done && !calib_done_d) r_calib_done <= 1'b1;

            // ---------------- v9（S3）锁定状态粘滞（W1C）----------------
            //   bit0 = 曾经进过 TRACK（上电自检"信号是否正常"）
            //   bit1 = 曾经掉锁（诊断用）
            //   bit2 = 保留
            if (lock_acq_evt)  r_lock_sticky[0] <= 1'b1;
            if (lock_lost_evt) r_lock_sticky[1] <= 1'b1;
            if (we && (addr == 16'h0131))
                r_lock_sticky <= r_lock_sticky & ~wdata;   // W1C，优先级最高
        end
    end

    // ==================================================================
    // 读译码（纯组合）
    // ==================================================================
    always @(*) begin
        rdata = 8'h00;
        case (addr)
        // ---- TW28 低 bank ----
        16'h0000: rdata = r_main_cfg;
        16'h0001: rdata = r_led_cfg;
        16'h0002: rdata = r_led_start;
        16'h000B: rdata = r_test;
        16'h0010: rdata = r_led_start;          // LED_PWM 别名
        16'h007E: rdata = DEVICE_ID;            // 简单模式别名
        16'h007F: rdata = REV;
        // ---- TW28 0x01xx ----
        16'h0100: rdata = r_uvw_cfg;
        16'h0101: rdata = r_inter0;
        16'h0102: rdata = r_inter1;
        16'h0103: rdata = r_ab_hyst;
        16'h0104: rdata = r_uvw_hyst;
        16'h0105: rdata = r_falarm;
        16'h0106: rdata = r_ablimit;
        16'h0107: rdata = r_zero0;
        16'h0108: rdata = r_zero1;
        16'h0109: rdata = r_output;
        16'h010A: rdata = r_zphase;
        16'h010B: rdata = r_uvwph;
        16'h010C: rdata = r_phase_lsb;
        // ---- v9（S2）延迟前馈 ----
        16'h0120: rdata = r_tau_q8[7:0];
        16'h0121: rdata = r_tau_q8[15:8];
        16'h0122: rdata = r_ff_cfg;
        16'h0123: rdata = {6'b0, cfg_ff_en, cfg_ff_en};   // 状态镜像：bit0=en（方便一键核对）
        16'h0124: rdata = ff_speed[7:0];
        16'h0125: rdata = ff_speed[15:8];
        16'h0126: rdata = ff_speed[23:16];
        16'h0127: rdata = ff_corr[7:0];
        16'h0128: rdata = ff_corr[15:8];
        16'h0129: rdata = ff_corr[23:16];
        // ---- v9（S5）全周补偿表 ----
        16'h0141: rdata = r_lut_addr[7:0];
        16'h0142: rdata = {4'b0, r_lut_addr[11:8]};
        16'h0143: rdata = r_lut_data[7:0];
        16'h0144: rdata = r_lut_data[15:8];
        16'h0145: rdata = r_lut_ctrl;
        16'h0146: rdata = lut_rd_q[7:0];    // 回读校验（需 0x0145 bit1=1 且地址已写）
        16'h0147: rdata = lut_rd_q[15:8];
        // ---- v9（S3）锁定状态机 ----
        //   0x0130：state（0=INIT 1=TRACK 2=LOST）
        //   0x0131：bit0=当前已锁定（实时） bit1=曾掉锁 bit2=曾锁定（W1C 清）
        16'h0130: rdata = {6'b0, lock_state};
        16'h0131: rdata = {5'b0, r_lock_sticky[2], r_lock_sticky[1],
                           r_lock_sticky[0], (lock_state == 2'd1)};
        16'h0132: rdata = lock_lost_cnt[7:0];
        16'h0133: rdata = lock_lost_cnt[15:8];
        16'h0134: rdata = lock_bad_run[7:0];
        16'h0135: rdata = lock_bad_run[15:8];
        //   0x0138..0x013C：偏置慢跟踪回显（bias_track 的收敛结果）
        16'h0138: rdata = bias_s[7:0];
        16'h0139: rdata = bias_s[15:8];
        16'h013A: rdata = bias_c[7:0];
        16'h013B: rdata = bias_c[15:8];
        16'h013C: rdata = {6'b0, bias_big, bias_valid};
        // ---- TW28 0x03xx ----
        16'h0300: rdata = r_filt_cfg;
        16'h0301: rdata = r_filt_lag;
        16'h0302: rdata = r_filt_k;
        // ---- TW28 0x04xx ----
        16'h0400: rdata = r_stat_cfg;
        16'h0401: rdata = r_stat_sel;
        16'h0402: rdata = r_stat_ie;
        16'h0403: rdata = r_stat_hiz;
        16'h0404: rdata = stat_val_now;
        16'h0405: rdata = r_stat_latch;
        16'h0406: rdata = 8'h00;                // STAT_FATAL
        // ---- EEPROM（未实现）----
        16'h0601: rdata = 8'h00;
        16'h0602: rdata = 8'h00;
        16'h0603: rdata = 8'h00;
        // ---- 扩展 0x05xx ----
                16'h0500, 16'h0501: rdata = 16'h0000;   // v74：原帧位宽，保留地址恒 0
        16'h0502: rdata = {8'b0, calib_bad, calib_retry, calib_trunc, r_calib_done, calib_busy, 1'b0};
        16'h0503: rdata = r_calib_n[7:0];
        16'h0504: rdata = r_calib_n[15:8];
        // ---- ★ v6 诊断段：角度毛刺计数（16 位小端对）----
        16'h0505: rdata = gl_cnt_1024[7:0];
        16'h0506: rdata = gl_cnt_1024[15:8];
        16'h0507: rdata = gl_cnt_2048[7:0];
        16'h0508: rdata = gl_cnt_2048[15:8];
        16'h0509: rdata = gl_cnt_4096[7:0];
        16'h050A: rdata = gl_cnt_4096[15:8];
        16'h050B: rdata = gl_cnt_8192[7:0];
        16'h050C: rdata = gl_cnt_8192[15:8];
        16'h050D: rdata = gl_hold_cnt[7:0];
        16'h050E: rdata = gl_hold_cnt[15:8];
        16'h0510: rdata = r_ofs_s[7:0];
        16'h0511: rdata = r_ofs_s[15:8];
        16'h0512: rdata = r_ofs_c[7:0];
        16'h0513: rdata = r_ofs_c[15:8];
        16'h0514: rdata = r_gain_s[7:0];
        16'h0515: rdata = r_gain_s[15:8];
        16'h0516: rdata = r_gain_c[7:0];
        16'h0517: rdata = r_gain_c[15:8];
        16'h0518: rdata = r_phase_k[7:0];
        16'h0519: rdata = r_phase_k[15:8];
        16'h051A: rdata = {4'b0000, r_shift_c, r_shift_s};
        16'h051B: rdata = r_h2_k[7:0];
        16'h051C: rdata = r_h2_k[15:8];
        16'h0520: rdata = r_amp_low_sq[7:0];
        16'h0521: rdata = r_amp_low_sq[15:8];
        16'h0522: rdata = r_amp_low_sq[23:16];
        16'h0523: rdata = r_amp_low_sq[31:24];
        16'h0524: rdata = r_amp_high_sq[7:0];
        16'h0525: rdata = r_amp_high_sq[15:8];
        16'h0526: rdata = r_amp_high_sq[23:16];
        16'h0527: rdata = r_amp_high_sq[31:24];
        16'h0530: rdata = stat_amp_sq[7:0];
        16'h0531: rdata = stat_amp_sq[15:8];
        16'h0532: rdata = stat_amp_sq[23:16];
        16'h0533: rdata = stat_amp_sq[31:24];
        16'h0534: rdata = stat_cycle_cnt[7:0];
        16'h0535: rdata = stat_cycle_cnt[15:8];
        16'h0536: rdata = stat_pos_full[7:0];
        16'h0537: rdata = stat_pos_full[15:8];
        16'h0538: rdata = stat_pos_full[23:16];
        16'h0539: rdata = stat_pos_full[31:24];
        16'h053A: rdata = {1'b0, 1'b0, calib_busy,      // v74：bit7/6 保留，恒 0
                           r_calib_done, stat_otr, stat_amp_high,
                           stat_amp_low, stat_lag_limit};
                16'h053B, 16'h053C: rdata = 16'h0000;   // v74：原帧内已发位数（保留，恒 0）
        // ---- ★ v6 诊断段：标定窗口快照 + 周期脉冲计数（16 位小端对）----
        16'h0540: rdata = cyc_pulse_cnt[7:0];
        16'h0541: rdata = cyc_pulse_cnt[15:8];
        16'h0542: rdata = dbg_int_min[7:0];
        16'h0543: rdata = dbg_int_min[15:8];
        16'h0544: rdata = dbg_int_max[7:0];
        16'h0545: rdata = dbg_int_max[15:8];
        16'h0546: rdata = dbg_wcnt_cls[7:0];
        16'h0547: rdata = dbg_wcnt_cls[15:8];
        16'h0548: rdata = dbg_nsamp_cls[7:0];
        16'h0549: rdata = dbg_nsamp_cls[15:8];
    16'h054A: rdata = stat_z_cnt[7:0];      // v73：Z 上升沿计数（32 位，调试用）
    16'h054B: rdata = stat_z_cnt[15:8];
    16'h054C: rdata = stat_z_cnt[23:16];
    16'h054D: rdata = stat_z_cnt[31:24];
        16'h05F0: rdata = DEVICE_ID;
        16'h05F1: rdata = REV;
        16'h05F2: rdata = rtl_build_id[7:0];    // ★ RTL 版本号（v5 及以前读 0，v6 = 6，v7 = 7，v8 = 8）
        16'h05F3: rdata = rtl_build_id[15:8];
        // ---- TW28 器件识别地址 ----
        16'hE000: rdata = DEVICE_ID;
        16'hE002: rdata = REV;                  // REV0
        16'hE003: rdata = 8'h00;                // REV1
        default:  rdata = (addr[15:8] == 8'h07) ? ext_rdata : 8'h00;
        endcase
    end

    // ==================================================================
    // 扁平化配置输出（纯组合拼接）
    // ==================================================================
    assign cfg_inter    = {r_inter1[1:0], r_inter0[7:0]};       // 10 位
    assign cfg_div      = r_inter1[4:2];
    assign cfg_ablimit  = r_ablimit;
    assign cfg_hyst_ab  = r_ab_hyst[4:0];
    assign cfg_hyst_uvw = r_uvw_hyst[4:0];
    assign cfg_pairs    = r_uvw_cfg[4:0];
    // ZPH = {ZPHASE[9:2], PHASE_LSB.z[1:0]}，单位 360/1024 -> 12 位 360/4096
    assign cfg_zphase   = {r_zphase[7:0], r_phase_lsb[1:0], 2'b00};
    assign cfg_zwidth   = r_zero1[3:0];
    // UVWPS = {UVWPH[9:2], PHASE_LSB.uvw[1:0]}，单位 360/1024
    // cfg_uvwph 单位 = 2^16/周期 -> 需 ×64，即 {UVWPS, 6'b0}
    assign cfg_uvwph    = {r_uvwph[7:0], r_phase_lsb[3:2], 6'b000000};
    assign cfg_kp       = {1'b0, r_filt_k[2:0]};
    assign cfg_ki       = r_filt_k[4:3];
    assign cfg_apol     = r_output[0];
    assign cfg_bpol     = r_output[1];
    assign cfg_zpol     = r_output[2];
    assign cfg_abzdir   = r_output[3];
    assign cfg_uvwpol   = r_output[4];
    assign cfg_uvwdir   = r_output[5];
    assign cfg_abzen    = r_output[6];
    assign cfg_uwven    = r_output[7];
    assign cfg_ofs_s    = r_ofs_s;
    assign cfg_ofs_c    = r_ofs_c;
    assign cfg_gain_s   = r_gain_s;
    assign cfg_gain_c   = r_gain_c;
    assign cfg_phase_k  = r_phase_k;
    assign cfg_shift_s  = r_shift_s;
    assign cfg_shift_c  = r_shift_c;
    assign cfg_amp_low_sq  = r_amp_low_sq;
    assign cfg_amp_high_sq = r_amp_high_sq;
    // v74：原帧位宽只读量恒 0（抽头仍占位，见 enc_top.v 的 unused_ok 说明）
    assign cfg_st_bits  = 8'd0;
    assign cfg_mt_bits  = 8'd0;
    assign cfg_h2_k     = r_h2_k;
    assign cfg_calib_n  = r_calib_n;
    assign cfg_tau_q8   = r_tau_q8;
    assign cfg_ff_en    = r_ff_cfg[0];
    assign cfg_bias_en  = r_ff_cfg[1];       // ★ v9.1：偏置慢跟踪开关，复位值 0
    // v9（S5）全周补偿表
    assign cfg_lut_en   = r_lut_ctrl[0];
    assign lut_wr_en    = r_lut_wr;
    assign lut_wr_addr  = r_lut_addr;
    assign lut_wr_data  = r_lut_data;
    assign cfg_lut_probe = r_lut_ctrl[1];

endmodule
