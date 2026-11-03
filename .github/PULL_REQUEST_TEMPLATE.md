## 这个 PR 做了什么

<!-- 一句话说明；关联 issue 用 "Closes #123" -->

## 为什么

<!-- 根因 / 动机。RTL 改动请说明触发条件与影响面 -->

## 怎么验证的

- [ ] `tools\check_offline.ps1` 退出码 0
- [ ] `tools\run_sim.ps1`（或 `-Only` 相关测试台）PASS
- [ ] RTL 改动：综合通过，WNS ≥ 0、DRC 0 Error（贴报告路径）
- [ ] 寄存器/协议改动：`rtl/SPEC_interface_contract.md`、`host/regs.py`、文档三处同步
- [ ] 位流改动：更新 `docs/BASELINES.md` 与 `deliverables/data/`（SHA-256）
- [ ] 文档改动：`python tools\check_links.py` 通过

## 证据

<!-- 日志片段、报告文件名、截图、位流 SHA-256；没有就写"无" -->

## 检查

- [ ] 提交物不含学校/姓名/学号等身份信息
- [ ] 没有提交 `_impl_*/`、`_sim_work/`、`__pycache__`、大 CSV（证据归档除外）
- [ ] 提交信息符合 CONTRIBUTING §5
