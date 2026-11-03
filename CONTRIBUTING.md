# 贡献指南

感谢你愿意改进这个项目。它是一次把细分信号链整体做进 FPGA 的完整实践，
代码、文档、证据三者互相引用，所以**改代码请同时改证据**。

## 1. 开始之前

- 先读根 [README](README.md) 的架构与目录对照，再看
  [rtl/SPEC_interface_contract.md](rtl/SPEC_interface_contract.md)——接口契约是
  改 RTL 的入口，任何端口/寄存器变化必须先改契约再改代码。
- 复现环境见 [docs/REPRODUCE.md](docs/REPRODUCE.md)。
- 参与即表示同意 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 2. 可以贡献什么

| 类型 | 例子 | 需要附带的验证 |
|---|---|---|
| Bug 修复 | 位宽、复位、跨时钟域、上位机解析 | 复现步骤 + 修复前后日志 |
| 新平台适配 | 其他 Artix-7 板、其他 ADC | 约束文件 + 上板读数 |
| 算法改进 | 标定、CORDIC、滤波、跟踪环 | 定点模型对比 + 仿真 |
| 文档/复现 | 步骤不清、命令失效、链接错误 | 实际执行记录 |
| 技能包 | 新的提示词工作流、校验脚本、踩坑清单 | 按 `skill/README.md` 模板写全 6 节 |

**不接受**：把 `rtl/` 改成依赖 Xilinx IP 的黑盒而不提供仿真模型；把 `ENC_DISP_TAP`
带进生产构建；在提交物里加入学校/姓名/学号等身份信息。

## 3. 开发流程

```powershell
git checkout -b fix/short-topic
# 改代码 / 文档
powershell -File tools\check_offline.ps1          # 上位机与语法门槛
powershell -File tools\run_sim.ps1 -Only tb_xxx   # 相关仿真
# RTL 改动还要跑：tools\run_sim.ps1 全量 + 至少一次综合
git commit -m "fix(abz): ..."                     # 见 §5
```

### 3.1 RTL 约定

- Verilog-2001 子集，`always @(posedge clk)` 单时钟域；新增跨时钟域必须双触发器
  同步并在契约里写明。
- 可综合代码里**禁止** `initial`、`#delay`、`$display`（仿真专用代码放 `sim/`）。
- 所有寄存器地址、位宽、默认值以 `rtl/SPEC_interface_contract.md` 为准；
  改地址必须同步 `host/regs.py` 与文档。
- 位流构建号 `RTL_BUILD_ID` 在 `rtl/enc_top.v`，发布构建必须递增。
- 仿真必须能逐位对齐 `model/` 的定点黄金模型；不允许"看起来差不多"。

### 3.2 上位机约定

- Python 3.11+，不引入重量级新依赖；新依赖写进 `host/requirements.txt` 并说明原因。
- 串口/网络解析必须能处理截断帧与坏 CRC，不允许裸 `struct.unpack` 越界。
- UI 线程不做阻塞 I/O；新增面板要有 offscreen 自检。
- 中文注释/文案用 UTF-8；源码文件本身不要出现非 ASCII 文件名。

### 3.3 文档约定

- 文件名 ASCII，`docs/NN_topic.md` 编号不复用；中文只出现在正文。
- 每个关键数字必须能指向 `deliverables/data/` 下的报告/日志/哈希。
- 状态只用"现行 / 历史 / 草案"，不要把计划写成结论。
- 新增/修改文档后跑 `python tools\check_links.py`（相对链接必须可达）。

## 4. 提交前检查（PR 模板同款）

- [ ] `tools\check_offline.ps1` 退出码 0
- [ ] 相关仿真 PASS；RTL 改动跑了全量 `run_sim.ps1`
- [ ] 若改了 RTL：综合通过，WNS ≥ 0，DRC 0 Error，并在 PR 里贴报告路径
- [ ] 若改了寄存器/协议：`SPEC_interface_contract.md`、`host/regs.py`、文档三处同步
- [ ] 若改了位流：更新 `docs/BASELINES.md` 与 `deliverables/data/`（含 SHA-256）
- [ ] 没有提交 `_impl_*/`、`_sim_work/`、`__pycache__`、位流或大 CSV（除非是证据归档）
- [ ] 提交信息符合 §5；PR 描述写清"为什么"

## 5. 提交信息

用 Conventional Commits 前缀，正文中文或英文均可：

```
feat(disp): P7 增加相对误差曲线
fix(host): 网口预览漏刷新最后一帧
docs(reproduce): 补充 Flash 冷启动判据
test(sim): 新增 tb_z_cnt 覆盖 5 ms 重触发
build(v85): 归档显示位流与时序报告
```

一行不超过 72 字符；正文说明**根因**与**验证方式**，不要只写"修复 bug"。

## 6. 证据与隐私

- 提交物必须保持竞赛匿名：不含学校、院系、校徽、指导教师、团队名、姓名、学号、
  邮箱。`tools/check_names.py` 会扫描常见泄露词。
- 不要提交第三方手册 PDF、厂商工程模板、许可不明的图片/字体。需要引用时写摘要
  （见 `docs/ATK_board_digest.md`、`docs/AD9238_module_digest.md`）。
- 发现仓库里误入了敏感信息，请按 [SECURITY.md](SECURITY.md) 私下报告，不要开公开 issue。

## 7. 评审与合并

- 至少一位维护者 review；RTL 改动需要第二人复跑仿真或综合。
- 合并方式：squash merge，保持 `main` 线性。
- 发布：更新 `CHANGELOG.md` → 打 tag `vX.Y.Z` → 在 Release 里附位流 SHA-256
  与签核报告。
