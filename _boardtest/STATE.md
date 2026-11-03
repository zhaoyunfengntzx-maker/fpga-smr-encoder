# 板上实测状态（2026-11-01 23:20）——只记录本会话真实命令输出

> ⚠ 更正记录：本会话中途我曾把几条**没有真正跑过**的结论写进摘要（v69"build 完成 WNS+0.147 / check 740.2rpm /
> 显示位流已排队"）。那些不是真实测量结果，已作废；下文的数字都来自实际命令输出或产物文件。

## 1. 当前结论（一句话）

**v70（BUILD 0x0015）生产位流已上板验收通过**：位置计数、Z、2048 PPR、UVW 六态全部正确。
**v70 显示位流已构建但未上板**；板卡现已被用户断开（JTAG 44-494 假死时断开），Flash 未固化。

## 2. v70 构建产物

| 项目 | 生产 | 显示 |
|---|---|---|
| 位流 | `_impl_v70/enc_top_v70.bit` **1,517,496 B** @22:36:58 | `_impl_disp_v70/enc_top_disp_v70.bit` **1,708,301 B** @22:46:37 |
| SHA256 | `48EACCFEFBEBC99EB90AA92C14C1A4B6B9177BB2D688FD8B0B258CC5111A8E94` | `1081DCA7002B80A2C88CF82221D683DBE7A63757BDEF70D5E9AE3DE760563FBB` |
| 时序 | WNS **+0.091** / TNS 0 / 0 失败（24,680）；WHS +0.065 | WNS **+0.027** / TNS 0 / 0 失败（34,321）；WHS +0.057 |
| 资源 | LUT 10,955 (52.67%)、BRAM 32/50、DSP 17、IOB 63 | LUT 17,415 (83.73%)、BRAM 48/50、DSP 19、IOB 107 |
| 归档 | `deliverables/data/v70/`（21 件 + SHA256SUMS + README + VARIANT_INFO） | 同左 |

## 3. RTL 修复（v70，BUILD 0x0015）

1. `rtl/pole_counter.v`：`step_s` 先做模 2^16 无符号差 `diff_u`，再对差值符号扩展。
   旧的写法把 0..65535 的绝对相位各自补码扩展再相减 ⇒ 跨 32768 时差值 −65403（应 +133），
   累加器每半圈被扣 65536 ⇒ `cycle_cnt` 恒 0（v68/v69 都是）。仿真 `tb_acc2.v` 6 次跨界/3000 样 ✔
2. `rtl/uvw_gen.v`：`off_bwd` 增加 `r_sec==0 && eang>BND[5] → 65536−eang` 分支（`bwd_wide`），
   修反向 0→5 环绕边界被吞（旧代码反向 2 转只换向 7 次、82% 停 110）。仿真反向 50 次/六态均匀 ✔
3. `rtl/uvw_gen.v`：`dir_det` 改 16 位最短有符号差；`move_fwd/move_bwd` 显式声明。
4. `disp/enc_top_disp.v`：新增 `elsif ENC_V69_CPR2048 → DISP_CPR = 2048`（修 v68 屏上 RPM 16×）。

## 4. 上板实测（v70 生产位流，`V70D PROGRAMMED_OK` 22:41:20）

```
check_v70.py COM4 3:
  RTL_BUILD=0x0015  INTER0=32  UVW_CFG=0x2004
  电周期速率 = -24,543 cycles/s   机械转速 = 719.0 rpm
  r: min=24186 mean=26047 max=27634 (0.843 FS)
  UVW 状态分布 = {1:5970, 2:5538, 3:5031, 4:5539, 5:5507, 6:5548}   状态跳变 974
  lock=0x0301  stat_flags=0x0000
  0x0500&0xFF=27   0x0501&0xFF=5

diag_pos3.py COM4 3:
  frames=29905 fps=9968   rate=-24,962 cycles/s  ⇒ 731.3 rpm
  cnt signed min=-2047 max=0 distinct=2048      ← 每转 2048 个电周期
  rev(Z) = 12.00 Hz                             ← 每转 1 个 Z
  UVW states {1:5423, 2:4984, 3:4548, 4:4971, 5:5020, 6:4959}  transitions/s 293
  flags {56:5423, 48:24467, 52:15}              ← 56=0x38 含 uvw_freq_warn（间歇，待查）

soak_v68.py COM4 60:
  frames=598115  fps=9968.6
  r min=17020 mean=26766 max=28312 (0.864 FS)
  UVW 六态各 91k–108k；u/v/w flips 5848/5809/5852；z flips 30（单拍脉冲，遥测采不到）
  angle vs atan2: mean |err|=2.839°  n=119623  |err|>5°=150

angle_vs_sc.py COM4 3: 分箱 ±0.13°，h1=0.050 h2=0.026 h3=0.006 h4=0.093°
calib_v68.py COM4: gain_s=33,776 gain_c=33,568 shift=0 flags=0x0010 amp_sq=53,514
以太网: ping 5/5；UDP 28,672 点 @25 MSPS；首次缺 45 块，随后 3/3 missing=[]
```

## 5. 待办（下次接板第一件）

1. 下载 `enc_top_disp_v70.bit` → 屏上 RPM 应 ≈ **720 rpm**；长按 `key_n` 一键标定；`ui_btn` 翻页。
2. Flash 固化 + 断电自启（先备份；2026-10-30 有 erase 成功/program 失败的历史）。
3. BiSS-C 上示波器验证帧结构（目前只有 `0x0500/0x0501 = 27/5`）。
4. `uvw_freq_warn` 间歇置位（约 18% 帧）待查；`0x0405` bit3 `inclim` 与它同源。
5. 每次重配置后 `0x070C` 复位回 5000，需重写 5010。

## 6. 环境坑（都已复现过）

- JTAG `44-494 may be locked by another hw_server` ⇒ **只能拔插 JTAG USB 线**；杀 hw_server/cs_server 无效。
- Vivado 2026.1 必须先 `open_hw_manager`；写完位流不退出，用 `Stop-Process vivado`。
- PowerShell `Set-Content -Encoding UTF8` 会写 BOM ⇒ tcl/v 文件一律用 Python 生成。
- xsim 本机起不来（`Could not open file mapping object`）⇒ 用 `D:\ModelSim\win64\vsim.exe`。
- `run_vivado_hw.ps1 -LogFile` 只收裸文件名（内部 Join-Path 到 `_flash2_work`）。

## 7. 关键脚本

`_boardtest/prog_retry.tcl`（下载，env BITFILE/TAG）、`check_v70.py`（身份+计数+UVW+BiSS）、
`diag_pos3.py`（cnt/Z/UVW 精测）、`soak_v68.py`（长跑）、`angle_vs_sc.py`、`calib_v68.py`、
`raw_probe.py`、`hi_probe.py`、`_boardtest/acc_sim/`（ModelSim 工作目录：`tb_acc2.v`、`tb_uvw.v`、`tb_uvw_rev.v`）。

## 8. 离线自检（板子断开后）

- `tools/final_verify.ps1`：27 OK / 4 FAIL。4 个 FAIL 都是陈旧性告警（`sim/logs/SUMMARY.md` 与写死 v66 目录的
  `prod/disp bitstream` 比今天改的 RTL 旧）；xsim 本机起不来，回归摘要无法重跑，等价证据是 ModelSim 的
  `tb_acc2`（计数 6 次跨界）与 `tb_uvw`/`tb_uvw_rev`（前向 49 / 反向 50，均六态均匀）。
- `tools/check_build_freshness.py --all-v70`（本轮新增）：生产/显示两个 v70 位流都 **FRESH**。
- `deliverables/data/SHA256SUMS.txt`：**213 行全部校验通过**（含 v70 的 22 件）。
- 文档：`docs/33_v70_release_report.md`（新）、`docs/32…md` §6（追补）、`docs/DEV_STATUS.md` §17（新）、
  `README.md` 基线五、`deliverables/evidence_index.md` §1.4、`deliverables/data/v70/`（README + VARIANT_INFO + 22 件）。
- 顺手补的：`host/link.py` 新增 `read_reg8()`（8 位寄存器只取低字节，避开高字节脏读）；
  `deliverables/board_day_checklist.md` 顶部加"最新口径是 v70"提示、末尾新增 **§11 接板后只剩 3 件事**；
  `deliverables/data/README.md` 计数更新为 **193 件 / 127,182,689 B / SHA256SUMS 213 行**；
  仓库根目录的一次性补丁脚本已归到 `_boardtest/_scratch/`。

## 9. 全量代码审计（2026-11-02，详见 docs/34_audit_report.md）

- xsim 全量回归 **35 / 36 PASS**，唯一红灯 	b_enc_top 的 B4-1rev-Z-pulses-1。
- ★ 真缺陷 **B1：Z 索引脉冲不出**（v70 位流同样受影响）——enc_top.v:750 窗宽 1 拍 + bz_gen.v:717
  窗外清零 + pole_counter 回绕比 angle 晚 2 拍 ⇒ z_load 永不成立。修 Z 需重做取窗（v71），
  实验性修法已回退（会与 clr_on_z 自我触发）。
- 已修：	ools/uart_spi.py find_reply 假 AA55 吞应答；
tl/lag_ff.v 先截断后饱和；
  
tl/enc_top.v:848 仿真自检 3 拍不对齐；3 个陈旧 TB（pole_counter/reg_file/lowsig）。
- 工具：	ools/fuzz_host_protocols.py（270,074 项 0 失败）、	ools/check_regmap.py、
  	ools/check_tb_coverage.py（盲区 29，enc_top_disp 零 TB）、	ools/check_build_freshness.py。
- 仍待：Z 取窗重做（v71）、显示 smoke TB、TB 配置指纹、B4/B5/B6 口径项。

---

## 10. v71：Z 索引脉冲修复（2026-11-02）

### 10.1 结论

全量审计（`docs/34_audit_report.md`）发现 **B1：Z 索引脉冲在当前 RTL 上根本不出**。v71 修好：
仿真回归 **36/36 PASS**（`tb_enc_top` 106 checks / 0 error），生产位流已重建并签核；**板卡断开，未上板**。

### 10.2 根因（关键，别再踩）

`pole_counter` 的 `phase_acc` 是"从复位时刻开始累加"的展开相位，**其回绕点对应复位瞬间的绝对角度**
（实测 343°，打印 `evt=1 cnt=64 ang=62466`），而 ABZ 的 `z_phase=0` 跨零在 0° ⇒ 窗与跨零沿永久错位。
v68 之所以"看起来有 Z"，是因为 `cycle_cnt` 卡 0 ⇒ `z_window≡1`，Z 变成"每个电周期都出"。
**所以不能拿 `cycle_cnt` 低位回绕当 Z 圈事件，必须用绝对角度过零。**

### 10.3 三处修改（源码 `rtl/`）

1. `rtl/enc_top.v`：`z_window` 改为绝对角度过零 —— `z_ang_prev`（`filt_valid` 跟随 `angle`）、
   `ZW_TOP=(1<<AW)-(1<<(AW-3))`、`ZW_LOW=(1<<(AW-3))`、`ang_wrap_f/b`；自由计数 `rev_cnt`（不在 Z 清）做
   "每圈一次"仲裁 `z_idx_evt = (ang_wrap_f|ang_wrap_b) && (rev_cnt[POLE_BITS-1:0]==0)`；
   `Z_WIN_CLKS=6` 展宽。**注意 `ang_prev` 这个名字 `enc_top.v:611` 已占用**（`vlog-2388`），用 `z_ang_prev`。
2. `rtl/abz_gen.v`：`r_z_prev_hi` 始终跟随 `z_ph_hi`；`r_pend_ttl`(8) 跨零挂起令牌；
   `z_xing` 按方向选边沿（只认 hi→lo 会让反向完全无 Z）；`z_load = z_in_win & (z_xing|pend) & ~z_active`。
3. `rtl/enc_top.v`：`clr_on_z` **1 → 0**（清零会让 `mech_angle` 跳变、UVW 误报 `D11`，且破坏多圈计数）。

### 10.4 构建脚本

- `tools/make_v71_rtl.py`：复制 rtl → `_synth_work_v71/rtl_v71`，**只把 `RTL_BUILD_ID 0x0015 → 0x0016`**
  （源码基线是 v70 的 0x0015，不是 0x000E）；自检 9 条 token。
- `tools/impl_check_v71.tcl` → `_impl_v71/enc_top_v71.bit`（日志 `_flash2_work/build_v71.log`）。
- `tools/impl_check_disp_v71.tcl` → `_impl_disp_v71/enc_top_disp_v71.bit`
  （`-verilog_define {ENC_DISP_TAP ENC_V69_CPR2048}`，日志 `_flash2_work/build_disp_v71.log`）。

### 10.5 签核数字

- 生产：1,514,668 B；WNS **+0.277** / TNS 0 / 0 失败（24,785）、WHS +0.047、WPWS +0.264；
  LUT 10,968 (52.73%)、FF 8,756 (21.05%)、BRAM 32/50。
- 显示：1,657,221 B @09:35:39，SHA256 `776438A7…C88A025`；WNS +0.143 / TNS 0 / 0 失败（34,383）、
  WHS +0.019、WPWS +0.264；LUT 17,393 (83.62%)、FF 11,557 (27.78%)、BRAM 48/50 (96%)、DSP 19/90、IOB 107；
  DRC 无 Error（REQP-1839/1840 各 20 Warning）；`eth_rxc` slack MET 1.907 ns。

### 10.6 接板后要做的（按顺序）

1. 下 v71 生产位流 → `check_v70.py COM4 3`（**白名单要加 0x0016**）；看 `RTL_BUILD=0x0016`、
   电周期速率 ≈ −24.7k（反向转台）、Z 率 = |rate|/2048 ≈ 12 Hz、UVW 六态。
2. 示波器量 Z：每圈 1 个、宽度 ≈ 5 个 A 边沿（`Z_width_max=2569 clk`）。
3. 下 v71 显示位流 → 屏上 RPM ≈ 720（`DISP_CPR=2048`）。
4. 标定、以太网、60 s 长跑复测（脚本都在 `_boardtest/`）。

### 10.7 ⚠ 已知未验证项（2026-11-02 记录，勿在离线阶段"顺手改"）

试过给 Z 加"一次性布防"（出过 Z 后须离开 ≥90° 才重新布防，用 16 位模 2π 最短弧算角差）来防停位喘振：
`tb_enc_top` 仍 106 checks 全绿，但新写的两个高速 TB（`_boardtest/_scratch/tb_z_park.v`、`tb_z_fwd.v`，
`POLE_BITS=11`、`PH_STEP=32`）数到 **9 个 Z/圈**，探针 `zout_i=1 ract=1 zleft=4 win=1 load=0`（脉冲一直高）。
**无法判断是 `abz_gen` 高速缺陷还是 TB 激励不真实**（该 TB 的 `ph` 每拍跳变、未走 SPI 配置），
且 v71 位流已签核归档 ⇒ 改动**全部回退**，`rtl/enc_top.v` 已回到与 `_synth_work_v71/rtl_v71` 逐字节一致
（仅 `RTL_BUILD_ID` 不同），`final_verify.ps1` 仍能过。

旁证（接板必须量）：`tb_enc_top` 的 `Z_width_max=2569 clk`，而 720 rpm / 25 kHz 时一个电周期只有 2048 clk
⇒ **Z 脉宽比一个电周期还长**，高速下 `r_z_active` 可能跨到下一周期，"每圈一次"在高速端没有闭环验证。

接板验收顺序：低速每圈 1 个 → 720 rpm 仍每圈 1 个 → **停在索引位**看是否抖动。三项都过才谈 v72。
详见 `docs/34_audit_report.md` §4 B8。



---

## 12. v72 / v73（2026-11-02 上板当天）

### 12.1 当前板子状态

- **Flash 里是 v73 显示位流**（BUILD **0x0017**），断电冷启动已验证：屏正常、RPM≈720、Z 12.26 Hz。
- 串口 **COM7**（CH340，2 Mbaud）；遥测 10.9 kfps、`AA55` 帧正常。
- 转台：用户现场可拉到 ≈720 rpm，也可低速；**停位测试用户说"无法测试"**。

### 12.2 v71 实测结论（生产位流）

全项通过：身份 0x0016 / inter 32 / r max 0.853 FS / lock TRACK / 8673 Hz 基波 / 标定增益 1.024·1.017 /
角度 RMS 0.72° / 60 s 长跑 597,746 帧且 `|err|>5°`=0 / 以太网 ping+capture PASS。

### 12.3 两个新缺陷与修法

1. **显示 RPM 除零**（`disp/val_format.v`）：除数 16 位装不下 `2048×128=262144` ⇒ 截断成 0 ⇒ 屏显 496729.5。
   改为 20 位（`fixed_div #(.W(40), .DW(20))`）。TB `_boardtest/_scratch/tb_div20.v`。
2. **Z 无法测量**（不是缺陷，是观测手段缺失）：新增 `z_pulse_cnt` + `0x054A..0x054D` 只读寄存器。

### 12.4 环境坑（新增）

- 从 v71 构建 tcl 派生 v73 时，**`_synth_work_v71` 这个目录名也要替换**，否则 RTLDIR 指向不存在的路径，
  Vivado 报 `Unable to run synthesis. No HDL sources found in project`。
- `z_pulse_cnt` 必须声明在 `reg_file` 例化**之前**，否则隐式 wire 与 `reg` 重名（ModelSim `vlog-2388`）。
- 8 位寄存器读回高字节是脏数据，**一律 `& 0xFF`**（`0x0500` 会读成 1307）。
- LeCroy 判读：先看 `Prd/Freq` 读数再下结论；500 ns/格 看到 800 kHz 方波那是 **A/B**，不是 Z。

## 13. 显示子系统冒烟仿真（2026-11-02，审计 B2 闭环）

- 新增 `sim/tb_disp_smoke.v`：实例化 **`enc_top_disp`**，喂 25 kHz 合成正交 sin/cos，判据是
  `lcd_pclk` 在跳 + 帧周期 17.069 ms + 每帧 `lcd_de` = **614,400** 像素（1024x600）+ `lcd_rgb`
  全帧非零 + 全程无 X => `TEST PASSED`。
- 基础设施两处：`sim/xilinx_prims_stub.v` 补 `IOBUF/IBUF/OBUF/OBUFT`（`disp/i2c_io_wrap.v:30`
  用到，缺了 `xelab` 报 `Module <IOBUF> not found`）；`tools/run_sim.ps1` 在 `-Only tb_disp_smoke`
  时把 `disp/*.v`（排除 `tb_*`）加进源集。
- 结果：全量回归 **37/37 PASS**；覆盖盲区 **29 -> 5**（`font_rom`/`text_ram`/`i2c_master_seq`/
  `touch_ctrl`/`logic_scope`）；`final_verify.ps1` => ALL CHECKS PASSED（rtl 与 v73 构建源仍判一致）。
- 两个坑：
  1. `lcd_pclk` 在 v73 里是 `sys_clk` 直通（同相），在 `sys_clk` 的 posedge 去比"上一拍"只会数到
     **1 次** => 必须在 `always @(posedge lcd_pclk)` 里计数。
  2. `rtl/enc_top.v` 的 `translate_off` 方向自检哪怕对齐 3 拍，在 50 Hz 合成信号启动瞬态仍刷假
     ERROR（`(20 / -405)`）=> 改为"两侧幅值都 >1024 LSB 且连续 64 拍才报"。该段不进位流，
     v73 位流不受影响；`final_verify.ps1` 比对源码时已剔除 `translate_off..translate_on` 段。
