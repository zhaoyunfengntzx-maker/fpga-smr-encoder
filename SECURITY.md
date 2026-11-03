# 安全策略

## 支持范围

| 版本 | 状态 |
|---|---|
| v1.0.x（当前） | 接收安全报告 |
| v0.x / 未打 tag 的历史位流（v62–v85） | 仅作证据归档，不再单独修复 |

## 报告方式

**请不要开公开 issue。** 用 GitHub 的
[Private vulnerability reporting](https://docs.github.com/zh/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
（仓库 → Security → Report a vulnerability），或直接邮件联系维护者
（见 `CITATION.cff` / 仓库主页）。

请在报告里给出：

- 受影响的文件/版本/位流哈希；
- 复现步骤（最小输入）；
- 影响判断（读到什么、能写什么、是否需要物理接触板卡）；
- 你希望的修复期限（默认 90 天协调披露）。

## 本项目关心的攻击面

这是一个**本地硬件工具**，不监听公网端口，但仍有三类风险：

1. **上位机解析不可信输入**：串口帧、UDP 包、`.npy/.bin` 回放文件都来自外部。
   已要求所有解析做长度/CRC 校验；发现越界、无限循环、内存放大都算安全问题。
2. **以太网**：板端实现 ARP/ICMP/UDP，不实现 TCP，不做远程配置；默认 IP
   `192.168.1.10`。若你把板子接到不可信网络，请自行隔离。
3. **供应链**：仓库不应包含可执行二进制、第三方手册、许可不明的素材；
   位流是构建产物，使用前请核对 `deliverables/data/SHA256SUMS.txt`。

## 不在范围内

- 需要物理拆机、改板、注入故障才能触发的现象；
- 单纯"精度不够/资源占用高"的性能问题（请开普通 issue）；
- 第三方开发板/ADC 模块本身的缺陷（请联系厂商）。

## 仓库卫生

- 不提交密钥、token、个人路径、学号/姓名等身份信息；
- 提交前跑 `python tools\check_names.py` 与 `python tools\check_links.py`；
- 误提交敏感信息时，维护者会用 `git filter-repo` 清理并强制更新 tag，
  同时在该版本的 Release 说明里记录。
