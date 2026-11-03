// -----------------------------------------------------------------------------
//  disp/enc_disp_tap.v —— 显示屏抽头例化（v13 新增）
//
//  为什么需要这一层：
//    屏 UI 需要编码器的内部量（angle / pos_full / s_cor / c_cor / stat / cfg_*）。
//    直接读子模块内部信号的做法（层次引用）在 Verilog-2001 综合里不可靠，
//    所以把 enc_top 已有的 `disp_tap` 只读总线引出并打包成屏侧端口。
//
//  ★ 本模块**没有任何逻辑**：右侧全是连线。它的存在只是为了让"编码器 → 屏"
//    的接口在一处集中声明，便于契约审计（`tools/scan_unused.py` 之类）。
//  ★ 一旦本模块里出现任何 `<=` 或组合运算，就说明有人在屏侧改了编码器的
//    观测口径 —— 那属于接口变更，必须同步改 rtl/SPEC_interface_contract.md 与
//    docs/13_display_ui_requirements.md。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module enc_disp_tap (
    input  wire [375:0] disp_tap,

    output wire [15:0]  angle,
    output wire [31:0]  pos_full,
    output wire [15:0]  s_n,
    output wire [15:0]  c_n,
    output wire [7:0]   io_state,
    output wire [7:0]   io_flags,
    output wire [7:0]   stat,
    output wire [9:0]   cfg_inter,
    output wire [2:0]   cfg_div,
    output wire [4:0]   cfg_pairs,
    // ---- v14 追加：P6 设置页 9 个字段要显示寄存器当前值，v13 的抽头里只有
    //      倍频/分频/极对数三个够用，其余六个从这里补（见 rtl/enc_top.v 位序契约）----
    output wire [4:0]   cfg_hyst_ab,
    output wire [7:0]   cfg_ablimit,
    output wire [3:0]   cfg_zwidth,
    output wire [11:0]  cfg_zphase,
    output wire [15:0]  cfg_uvwph,
    output wire [3:0]   cfg_pol,
    // ---- v15 追加：P7 标定页要显示**标定六参数当前值**与实测幅值 s²+c²。
    //      这些量在 rtl/reg_file.v 里早就是既有输出/输入，所以本版没有新增寄存器，
    //      也没有改 reg_file.v —— 只是把已有的线接到抽头上（见 rtl/enc_top.v 位序契约）----
    output wire signed [15:0] cfg_ofs_s,
    output wire signed [15:0] cfg_ofs_c,
    output wire        [15:0] cfg_gain_s,
    output wire        [15:0] cfg_gain_c,
    output wire signed [15:0] cfg_phase_k,
    output wire        [3:0]  cfg_shift,
    output wire        [31:0] stat_amp_sq,
    // ---- v21 追加：P7 幅值要显示成**百分比**，基准必须是编码器自己的幅值判据
    //      门限（0x0520/0x0524），否则屏上的百分比与编码器的告警口径不是一个东西。
    //      两个都是 rtl/reg_file.v 的寄存器直出（见 rtl/enc_top.v 位序契约）----
    output wire        [31:0] amp_low_sq,
    output wire        [31:0] amp_high_sq,
    output wire         cfg_abzen,
    output wire         cfg_uwven,
    output wire         calib_busy,
    output wire         calib_done,
    output wire         link_crc_err,
    output wire         otr_lat,
    output wire         amp_bad,
    output wire         lag_bad,
    output wire         limiter_active,
    output wire         z_window,
    output wire         uvw_freq_warn,
    // ---- v22 追加（C3）：链路心跳位 —— v74 起随从站模块删除而恒 0，
    //      端口与抽头位 [375] 保留（位图不重排），仅作历史接口占位。----
    output wire         link_lost
);

    assign angle          = disp_tap[15:0];
    assign s_n            = disp_tap[31:16];
    assign c_n            = disp_tap[47:32];
    assign pos_full       = disp_tap[79:48];
    assign io_state       = disp_tap[87:80];
    assign io_flags       = disp_tap[95:88];
    assign stat           = disp_tap[103:96];
    assign cfg_inter      = disp_tap[113:104];
    assign cfg_div        = disp_tap[116:114];
    assign cfg_pairs      = disp_tap[121:117];
    assign cfg_hyst_ab    = disp_tap[138:134];    // v14
    assign cfg_ablimit    = disp_tap[146:139];    // v14
    assign cfg_zwidth     = disp_tap[150:147];    // v14
    assign cfg_zphase     = disp_tap[162:151];    // v14
    assign cfg_uvwph      = disp_tap[178:163];    // v14
    assign cfg_pol        = disp_tap[182:179];    // v14 {uvwpol,zpol,bpol,apol}
    assign cfg_ofs_s      = disp_tap[198:183];    // v15 正弦偏置 Q1.15
    assign cfg_ofs_c      = disp_tap[214:199];    // v15 余弦偏置 Q1.15
    assign cfg_gain_s     = disp_tap[230:215];    // v15 正弦增益 Q1.15
    assign cfg_gain_c     = disp_tap[246:231];    // v15 余弦增益 Q1.15
    assign cfg_phase_k    = disp_tap[262:247];    // v15 正交误差系数 Q1.15
    assign cfg_shift      = disp_tap[266:263];    // v15 {shift_c[1:0], shift_s[1:0]}
    assign stat_amp_sq    = disp_tap[310:279];    // v15 实测 s²+c² Q2.30
    assign amp_low_sq     = disp_tap[342:311];    // v21 幅值下限平方 Q2.30（0x0520）
    assign amp_high_sq    = disp_tap[374:343];    // v21 幅值上限平方 Q2.30（0x0524）
    assign cfg_abzen      = disp_tap[122];
    assign cfg_uwven      = disp_tap[123];
    assign calib_busy     = disp_tap[124];
    assign calib_done     = disp_tap[125];
    assign link_crc_err   = 1'b0;            // v74：保留位（抽头位 [126] 保留但恒 0）
    assign otr_lat        = disp_tap[127];
    assign amp_bad        = disp_tap[128];
    assign lag_bad        = disp_tap[129];
    assign limiter_active = disp_tap[130];
    assign z_window       = disp_tap[131];
    assign uvw_freq_warn  = disp_tap[132];
    // disp_tap[133] 保留位，当前无消费者；[182:134] 是 v14 追加的 P6 设置回读字段；
    // [310:183] 是 v15 追加的 P7 标定参数与实测幅值；[374:311] 是 v21 追加的
    // 幅值上下限门限（0x0520/0x0524），只给 P7 的百分比当基准用
    assign link_lost      = 1'b0;            // v74：保留位（抽头位 [375] 保留但恒 0）

endmodule
