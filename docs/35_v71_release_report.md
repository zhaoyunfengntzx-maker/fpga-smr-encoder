# 35 v71 发布说明：Z 索引脉冲修复（2026-11-02）

> 一句话：全量代码审计发现 **Z 索引脉冲在当前 RTL 上根本不出**（v68–v70 都受影响），
> v71 用"绝对角度过零 + 自由圈计数 + 单向装载令牌"修好，仿真回归 36/36、两个位流已签核；
> **尚未上板**（板卡 2026-11-01 夜断开）。

- 上游文档：[`docs/34_audit_report.md`](34_audit_report.md)（缺陷清单与根因）、
  [`docs/33_v70_release_report.md`](33_v70_release_report.md)（v70 上板验收）、
  [`docs/DEV_STATUS.md`](DEV_STATUS.md) §20
- 证据归档：[`deliverables/data/v71/`](../deliverables/data/v71/)（24 件 + 逐文件 SHA256）
- 接板清单：[`deliverables/board_day_checklist.md`](../deliverables/board_day_checklist.md) §12

---

## 1. 为什么有 v71

v70 把转台的 2048 PPR 语义修对了（`cycle_cnt` 相位差符号扩展、UVW 反向 0→5 回绕），
上板实测 RPM/Z/UVW 全部符合预期。但**做全量审计时发现一个被 v70 掩盖的缺陷**：

- `sim/tb_enc_top.v` 的 `B4-1rev-Z-pulses-1` 一直是红灯：整整一圈 `z_out` 从未拉高。
- v68 时代"看起来有 Z"是假象：那时 `cycle_cnt` 卡 0 ⇒ `z_window ≡ 1` ⇒ Z 变成"每个电周期都出"，
  而不是每圈 1 个。v70 修好计数后，Z 反而彻底死了。

## 2. 根因（比"窗外清零"更深一层）

`rtl/pole_counter.v` 的 `phase_acc` 是**从复位时刻开始累加**的展开相位，它的回绕点对应**复位瞬间的
绝对角度**，而不是 0°。实测打印：

```
[ZW] evt=1 cnt=64 ang=62466      // evt=1 表示窗口张开，此刻绝对角度 ≈ 343°
[ZW] evt=0 cnt=0  ang=62466
```

而 ABZ 的 `z_phase = 0` 跨零在 **0°** ⇒ 窗与跨零沿永久错位；再叠加 `clr_on_z` 在 Z 时把 `phase_acc`
清 0，基准就永久偏到 343°。

**结论：不能用 `cycle_cnt` 低位回绕当"圈事件"，必须用绝对角度过零。**

## 3. 修法（三处，全部落在源码 `rtl/`）

### 3.1 `rtl/enc_top.v` — 取窗改为绝对角度过零

```verilog
reg [AW-1:0] z_ang_prev;                       // filt_valid 时跟随 angle
localparam [AW-1:0] ZW_TOP = (1 << AW) - (1 << (AW-3));   // 7/8 圈
localparam [AW-1:0] ZW_LOW = (1 << (AW-3));               // 1/8 圈
wire ang_wrap_f = filt_valid & (z_ang_prev >= ZW_TOP) & (angle <= ZW_LOW);
wire ang_wrap_b = filt_valid & (z_ang_prev <= ZW_LOW) & (angle >= ZW_TOP);

reg signed [CYCLE_BITS-1:0] rev_cnt;           // 自由圈计数，不在 Z 处清零
wire z_idx_evt = (ang_wrap_f | ang_wrap_b) && (rev_cnt[POLE_BITS-1:0] == {POLE_BITS{1'b0}});
localparam integer Z_WIN_CLKS = 6;             // 6 拍展宽
assign z_window = z_idx_evt | (z_win_left != 4'd0);
```

- 为什么用 7/8→1/8 的窗口而不是"过零判据"：角度噪声在 0°/360° 附近反复穿越，宽窗口 + 圈计数
  保证**每圈只认一次**。
- `rev_cnt` 不在 Z 处清零是关键：清零会让 `cycle_cnt[POLE_BITS-1:0]==0` 立刻又成立、窗口自我重触发
  （第一版修法就死在这里：一圈出 2 个 Z、`B3-half-rev-no-Z` 失败）。

### 3.2 `rtl/abz_gen.v` — 跨零挂起 + 方向相关边沿

```verilog
localparam integer Z_PEND_TTL = 8;
wire signed [AW-1:0] z_dang = angle - r_last_ang;
wire z_rev = z_dang[AW-1];
wire z_xing = z_rev ? (z_ph_hi & (~r_z_prev_hi)) : ((~z_ph_hi) & r_z_prev_hi);
wire z_pend_ok = (r_pend_ttl != 4'd0);
wire z_load = z_in_win & (z_xing | z_pend_ok) & (~r_z_active);
```

- `r_z_prev_hi` 改为**始终跟随** `z_ph_hi`（不再窗外清零）。
- 只认 hi→lo 会让**反向完全无 Z**（`C2/C5` 就是这条），所以按方向选边沿。
- `r_pend_ttl` 在跨零时装 8，把"跨零先到、窗口后到"的时序差兜住。

### 3.3 `rtl/enc_top.v` — `.clr_on_z(1'b1)` → `1'b0`

Z 时清零 `cycle_cnt` 会让 `mech_angle` 跳变、UVW 误报频率越限（`D11-uvw-freq-ok` FAIL），
也破坏多圈计数；v70 板上本来也从没清过（Z 从未出）。

## 4. 构建签核

| 指标 | 生产 `enc_top_v71.bit` | 显示 `enc_top_disp_v71.bit` |
|---|---|---|
| 大小 | **1,514,668 B** | **1,657,221 B** |
| SHA256 | `456279CD82778F9D0234784284C04402F6377C85993B9660AE599B918741DB28` | `776438A7E27D9B6918AD777E9110F969051D778AE9DC25786642F8762C88A025` |
| BUILD_ID | `0x0016` | 同左 |
| WNS / TNS / 失败端点 | **+0.277** / 0.000 / **0**（24,785） | **+0.143** / 0.000 / **0**（34,383） |
| WHS / WPWS | +0.047 / +0.264（0 失败） | +0.019 / +0.264（0 失败） |
| LUT | 10,968 / 20,800 = **52.73%** | 17,393 / 20,800 = **83.62%** |
| FF | 8,756 = 21.05% | 11,557 = 27.78% |
| BRAM | 32 / 50 = 64% | **48 / 50 = 96%** |
| DSP / IOB | — | 19 / 90 = 21.11%、107 / 250 = 42.80% |
| 以太网 RXC | — | slack **+1.907 ns（MET）** |
| DRC | 无 Error | 无 Error（REQP-1839/1840 各 20 Warning） |

构建命令（两个 Vivado 不能并发）：

```powershell
E:\Anaconda\python.exe tools\make_v71_rtl.py
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_v71.tcl -LogFile build_v71.log -Tail 30
powershell -NoProfile -ExecutionPolicy Bypass -File _flash2_work\run_vivado_hw.ps1 `
    -Tcl tools/impl_check_disp_v71.tcl -LogFile build_disp_v71.log -Tail 30
```

## 5. 仿真

- 全量回归 `tools/run_sim.ps1 -Rebuild`：**PASS 36 / 36**（`sim/logs/SUMMARY.md`）。
- `sim/tb_enc_top.v`：**106 checks / 0 error**（修前 106 / 1）。
  `FWD: Z_pulses=1, Z_width_max=2569 clk`（≈ 5 个 A 边沿步，A 边沿 = 512 clk）、`REV: Z_pulses=1`、
  `A_edges=4095/4097`（期望 4096）、`max_dev=10 LSB16`、`out_of_tol=0`。
- ModelSim 单模块秒级迭代：`_boardtest/acc_sim/zdbg/`（`vlog ../../../rtl/*.v ../../../sim/tb_enc_top.v`）。

## 6. 上板实测

**尚未进行。** 接板后按 [`board_day_checklist.md`](../deliverables/board_day_checklist.md) §12：
`check_v70.py`（白名单已加 0x0016）核对 `RTL_BUILD=0x0016`/Z 率 ≈ 12 Hz/UVW 六态，
示波器确认每圈 1 个 Z，显示位流目视 RPM ≈ 720，再跑标定/以太网/60 s 长跑。

## 7. 同轮审计的其它修复（不改变位流行为，除 `lag_ff`）

| 缺陷 | 文件 | 影响 |
|---|---|---|
| `find_reply` 被假 `AA 55` 骗过 | `tools/uart_spi.py` | 上位机读寄存器偶发"无应答"（fuzz 270,074 项通过） |
| 先截断后饱和 | `rtl/lag_ff.v` | 极端速度下修正量符号翻转（新增 `sim/tb_lag_ff_sat.v`） |
| 仿真自检 3 拍不对齐 | `rtl/enc_top.v`（`translate_off`） | 只产生假 ERROR，不影响位流 |
| 3 个陈旧 TB | `sim/tb_pole_counter|tb_reg_file|tb_lowsig` | 测试台配置漂移 |
| `FakeRx` 缺属性 | `host/selftest_stream_ui.py` | 自检自身崩 |

## 8. 仍未完成

1. **上板复测 v71**（Z/RPM/UVW/显示/标定/以太网/长跑）。
2. **B8 Z 的高速/停位行为未验证**（见 [`docs/34_audit_report.md`](34_audit_report.md) §4 B8）：
   仿真 Z 脉宽 `Z_width_max=2569 clk` 比 720 rpm 时的一个电周期（2048 clk）还长；停位抖动可能重复出 Z。
   试过"布防 + ≥90° 滞回"，`tb_enc_top` 仍全绿但新 TB 计数异常、无法定论 ⇒ **改动已回退，v71 RTL 保持签核原状**
   （`rtl/` 与 `_synth_work_v71/rtl_v71` 仅差 `RTL_BUILD_ID`）。接板按"低速 → 720 rpm → 停位"三档量 Z 之后再谈 v72。
3. **B2 显示子系统零仿真覆盖**：`enc_top_disp` 没有任何 TB，建议补 smoke TB（出帧 + DE/HS/VS + 触摸）。
4. **B3 回归配置指纹**：把 `POLE_BITS/INTER0/GAIN` 作为回归输入固化，避免再出现"TB 漂移"。
5. B4 `0x0700–0x07FF` 窗口默认读、B5 ARP MAC 口径、B6 未知地址、B7 UVW 换向抖动。
6. Flash 固化（烧 v71 `.mcs`，断电读回 BUILD `0x0016`）。
