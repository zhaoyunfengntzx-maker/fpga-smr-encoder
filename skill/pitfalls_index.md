# 踩坑症状索引（生成物，不要手改）

由 `python tools/gen_pitfall_index.py` 从两份清单生成：
`skill/pitfalls.md`（RTL 那套，18 条）与 `skill/pynq/pitfalls_pynq.md`（PYNQ 那套，14 条）。
改清单后跑一次生成，或跑 `--check` 看有没有漂移（`skill/scripts/run_all_checks.py` 已包含）。

用法：先按『你看到的症状』在这一页找到编号，再跳回清单读完整条目（触发/排查/根因/修法/回归/失效都在那边）。

## RTL / 仿真 / 约束 / 协作 / 测量（18 条）

| 编号 | 症状 | 先跑这条 |
|---|---|---|
| [P-01](pitfalls.md#p-01) | `TEST PASSED (n checks)`，n 与激励点数不符或恰好等于 1 | `python skill\scripts\tb_wiring.py sim\tb_xxx.v --dut rtl\xxx.v --strict` |
| [P-02](pitfalls.md#p-02) | 误差 RMS 从 0.32 涨到 0.60 LSB | `grep -n ">>" rtl/*.v` |
| [P-03](pitfalls.md#p-03) | 随机抽 100 点完全正常，全周 2^20 点扫描才暴露 | `check_vectors.py --tol 0` |
| [P-04](pitfalls.md#p-04) | 0–180° 正常，180–360° 的增量方向反了 | （没有单条命令；修法里是 `$signed(a - b)`） |
| [P-05](pitfalls.md#p-05) | 扇区边界处角度错误 | （没有单条命令；修法里是 `case`） |
| [P-06](pitfalls.md#p-06) | `dbg_adc_valid` 恒 1，实际 ADC 数据只有部分拍有效 | （没有单条命令；修法里是 `ILA`） |
| [P-07](pitfalls.md#p-07) | WNS 负很多 | `report_check_timing` |
| [P-08](pitfalls.md#p-08) | WNS 好看、资源变多，上板却跑不动 | `report_clocks` |
| [P-09](pitfalls.md#p-09) | WNS 正，但偶发数据错 | `report_cdc` |
| [P-10](pitfalls.md#p-10) | v85 的 LUT 86.96% 与早期报告矛盾 | `python tools/check_build_freshness.py` |
| [P-11](pitfalls.md#p-11) | git diff 全文件乱码 | `git diff --stat` |
| [P-12](pitfalls.md#p-12) | Vivado 卡在 "Connecting to hw_server" | `tasklist \| findstr hw_server` |
| [P-13](pitfalls.md#p-13) | 基线被改 | `git status` |
| [P-14](pitfalls.md#p-14) | 评审按文档找脚本，发现只有 .md | `python skill/scripts/skill_selftest.py` |
| [P-15](pitfalls.md#p-15) | 同一固件两次测出 719 / 740 rpm，差 3%，无法判断是否真优化 | `time.time()` |
| [P-16](pitfalls.md#p-16) | DUT 把输入直通也能通过 | （清单里没给命令——读『根因』那行） |
| [P-17](pitfalls.md#p-17) | 正文写 LUT 52.53%，表格写 52.5%，图为 53% | `grep` |
| [P-18](pitfalls.md#p-18) | 交作品时才发现资源超 10%、在别人机器上综合不过 | `skill/templates/REPRO_CHECKLIST.md` |

## PYNQ（.hwh / Overlay / DMA / 板卡）（14 条）

| 编号 | 症状 | 先跑这条 |
|---|---|---|
| [PYNQ-01](pynq/pitfalls_pynq.md#pynq-01) | `Overlay('design_1.bit')` 不报错，`ol.ip_dict` 里只有… | `python skill/pynq/pynq_bundle.py <交付目录>` |
| [PYNQ-02](pynq/pitfalls_pynq.md#pynq-02) | 寄存器读出来是"看起来合理的数字"，但地址错位——比如状态位读到了计数寄存器 的低位，于是你… | `python skill/pynq/pynq_bundle.py <目录>` |
| [PYNQ-03](pynq/pitfalls_pynq.md#pynq-03) | `ol.read(0x00)` 一直是 `0`，写进去也读不回来 | `python skill/pynq/pynq_overlay.py --overlay app.bit --map app.hwh --dev myip` |
| [PYNQ-04](pynq/pitfalls_pynq.md#pynq-04) | `REG-001` 提示"hwh 不含寄存器列表" | `python skill/pynq/pynq_hwh.py x.hwh` |
| [PYNQ-05](pynq/pitfalls_pynq.md#pynq-05) | 第一次跑对，第二次跑错 | （没有单条命令；修法里是 `buffer.flush()`） |
| [PYNQ-06](pynq/pitfalls_pynq.md#pynq-06) | 只搬了 1/4 的数据，`wait()` 正常返回，判据"长度一致"却失败 | `DMA 收 256 期望 1024` |
| [PYNQ-07](pynq/pitfalls_pynq.md#pynq-07) | 同一设计两次测出来差 30%，评审一问就说不清 | `time.time()` |
| [PYNQ-08](pynq/pitfalls_pynq.md#pynq-08) | 判据在配置 A 上过、配置 B 上全红，而 RTL 是对的（只是延迟不同） | （没有单条命令；修法里是 `skill/templates/tb_skeleton.v`） |
| [PYNQ-09](pynq/pitfalls_pynq.md#pynq-09) | `RuntimeError: Failed to load bitstream` / `De… | `cat /sys/class/fpga_manager/fpga0/state` |
| [PYNQ-10](pynq/pitfalls_pynq.md#pynq-10) | 周期计数换算出的吞吐、转速、延时全都成比例地错 | `python skill/pynq/pynq_hwh.py x.hwh` |
| [PYNQ-11](pynq/pitfalls_pynq.md#pynq-11) | `Overlay` 报 device family 不匹配 | `ol.device` |
| [PYNQ-12](pynq/pitfalls_pynq.md#pynq-12) | 功能 bug 留到联调 | `pynq_overlay.py` |
| [PYNQ-13](pynq/pitfalls_pynq.md#pynq-13) | 地址对得上、判据也过，但你测的不是你以为的那版逻辑 | `pynq_bundle.py` |
| [PYNQ-14](pynq/pitfalls_pynq.md#pynq-14) | 调了半天发现跑的是旧模块（`.pyc` 缓存或 kernel 里的旧对象） | `import myip; print(myip.__file__)` |

共 32 条。编号 `P-xx` 见 `skill/pitfalls.md`，`PYNQ-xx` 见 `skill/pynq/pitfalls_pynq.md`。
