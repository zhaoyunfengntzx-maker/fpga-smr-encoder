#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_doc_numbers.py — 用现行实测数字刷新全仓文档

背景：uvw_gen 定稿（迟滞基准改用真实扇区边界）后重跑了两版实现，
      实测数字变了，需要同步进 README / docs / sim/README。

设计要点
--------
1. **两阶段替换**：先把每个"老值"换成唯一的占位符，再把占位符换成"新值"。
   这样避免链式污染（例如把 0.655 改成 0.544 之后，又被"0.544 -> 别的"再改一次）。
2. **显式表**：只替换下面 RULES 里列出的字符串，不做任何模糊匹配。
3. **逐文件报告**：打印每个文件、每条规则的命中次数，便于人工复核。
4. `--check` 只报告不改写。
5. **逐轮映射留档**：`ROUNDS` 记录每一轮"旧值 -> 新值"的映射（含 commit 与证据来源），
   `--audit` 用它扫描全仓，报告哪些旧值**仍作为"已作废/历史"引用被有意保留**、
   哪些是漏改。**ROUNDS 不参与任何自动改写**（原因见下方 ROUNDS 上方注释）。

产出的实测数字来自：
  RULES 那一轮（2026-10-09）：
    生产版 _synth_work/impl_timing.rpt / impl_util.rpt / impl_build.log / enc_top.bit
  ROUNDS 里的 2026-10-10-ila-1514 轮：
    ILA 版 _synth_work/impl_ila_{timing,util,drc}.rpt / ila_build.log /
    enc_top_ila.bit + enc_top_ila.ltx / ila_probe_list.txt

用法
----
  python tools/sync_doc_numbers.py --check              # 报告 RULES 还命中哪些（不改写）
  python tools/sync_doc_numbers.py                      # ★ 真的按 RULES 改写（一次性，慎用）
  python tools/sync_doc_numbers.py --audit              # 按 ROUNDS 审计全部轮次
  python tools/sync_doc_numbers.py --audit <轮次名> [文件...]  # 审某一轮，可只扫指定文件
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------------------
# (老字符串, 新字符串, 说明)
# ---------------------------------------------------------------------------
RULES: list[tuple[str, str, str]] = [
    # ---- 生产版 sys_clk WNS：+0.655 -> +0.544 ----
    ("+0.655", "+0.544", "生产版 sys_clk WNS"),
    ("0.655", "0.544", "生产版 sys_clk WNS(裸值)"),
    # ---- ILA 版 sys_clk WNS：+0.880 / +0.577 -> +0.698 ----
    ("+0.880", "+0.698", "ILA 版 sys_clk WNS"),
    ("+0.577", "+0.698", "ILA 版 sys_clk WNS(更早一版)"),
    ("0.880", "0.698", "ILA 版 sys_clk WNS(裸值)"),
    # ---- 生产版 WHS：+0.095 -> +0.079 ----
    ("+0.095", "+0.079", "生产版 sys_clk WHS"),
    # ---- bitstream 尺寸 ----
    ("748,828", "741,836", "生产版 bitstream 文件大小"),
    ("748,820", "741,828", "生产版 bitstream 压缩后净长"),
    ("1,420,844", "1,473,128", "ILA 版 bitstream 文件大小"),
    ("1,420,836", "1,473,120", "ILA 版 bitstream 压缩后净长"),
    ("1,468,456", "1,473,128", "ILA 版 bitstream(更早一版)"),
    # ---- bitstream 压缩位数 ----
    ("11,547,136", "11,603,072", "生产版省掉的位数"),
    ("11547136", "11603072", "生产版省掉的位数(无逗号)"),
    ("6,171,008", "5,752,736", "ILA 版省掉的位数"),
    ("6171008", "5752736", "ILA 版省掉的位数(无逗号)"),
    ("5,990,560", "5,934,624", "生产版压缩后位数"),
    ("11,366,688", "11,784,960", "ILA 版压缩后位数"),
    # ---- 生产版资源：5619 -> 5653 ----
    ("5619", "5653", "生产版 Slice LUTs"),
    ("27.01", "27.18", "生产版 LUT 百分比"),
    ("3458", "3475", "生产版 Slice Registers"),
    ("8.31", "8.35", "生产版 FF 百分比"),
    # ---- ILA 版资源：8435/8417 -> 8466 ----
    ("8435", "8466", "ILA 版 Slice LUTs"),
    ("8417", "8466", "ILA 版 Slice LUTs(更早一版)"),
    ("40.55", "40.70", "ILA 版 LUT 百分比"),
    ("40.47", "40.70", "ILA 版 LUT 百分比(更早一版)"),
    ("8144", "8161", "ILA 版 Slice Registers"),
    ("19.58", "19.62", "ILA 版 FF 百分比"),
    # ---- sys_clk 时序端点：9423 -> 9474 ----
    ("9423", "9474", "生产版 sys_clk 时序端点"),
    ("16853", "16906", "ILA 版 sys_clk 时序端点"),
]

# 顺序敏感的上下文：这些行是"新旧对照/历史演变"叙述，改动前必须确认
CONTEXT_MARKERS = ("新旧对照", "上一版", "修复前", "旧实现", "与上一版")

# ---------------------------------------------------------------------------
# 逐轮映射留档（ROUNDS）—— **只供审计，不参与任何自动改写**
#
# 为什么不把新轮次直接追加进 RULES：每一轮被替换掉的旧值，往往在文档里被**有意保留**
# 成"已作废/历史"引用（例如 08:56 那版 ILA 位流的尺寸、+0.527 的 WNS 被留作演变证据）。
# 若把这一轮的旧值塞进 RULES，下一次运行就会连这些历史叙述一起改掉。
# 所以：新轮次把映射记在这里（`--audit` 逐行报告残留，并判断该行是否带历史标记）；
# 只有当某个旧值在文档里确实**不存在任何历史保留用法**时，才考虑加进 RULES。
# ---------------------------------------------------------------------------
HISTORY_MARKERS = CONTEXT_MARKERS + (
    "已作废", "作废", "历史", "旧版", "旧数字", "仅历史", "备份",
    "取代", "早于", "更早", "从未",
    # 实测补的：下面这些词出现在"当时的测量/更早一版"叙述里，属有意保留
    "08:56", "08:55", "早先", "此前", "修后实测", "修复后", "那一版",
)

ROUNDS: dict[str, dict] = {
    "2026-10-10-ila-1514": {
        "title": "ILA 位流 08:56 -> 15:14 重建（探针位序修复 + 0x0405[0] OTR 软清位）",
        "commit": "3df4842",
        "evidence": (
            "_synth_work/impl_ila_timing.rpt（:144 Timing constraints are not met.）/"
            "impl_ila_util.rpt / impl_ila_drc.rpt / ila_build.log / "
            "enc_top_ila.bit(1,435,240 B @15:14:21) / enc_top_ila.ltx(67,006 B @15:14:12) / "
            "ila_probe_list.txt(34 条探针, 252 bit)"
        ),
        "note": (
            "08:56 那版用降序 net 列表构建 -> 每条多比特探针位序反转（板上 "
            "dbg_pole_pairs_eff 显示 8，而寄存器 0x0100 写的是 4）；15:14 版改用升序，"
            "并继承 12:08 生产版的诚实 ADC 输入约束，故 sys_clk 有 26 个负余量端点"
            "（全部是 ADC 输入端口），与生产版同源、签核仍以生产版为准。"
        ),
        # 本轮还改了这三个不在 DEFAULT_TARGETS 里的文件，审计时一并扫
        "extra_targets": [
            "docs/02_innovation_scoring.md",
            "docs/07_board_checklist.md",
            "docs/DEV_STATUS.md",
        ],
        "map": [
            # (旧值, 新值, 说明)
            ("1,423,056", "1,435,240", "ILA 版 bitstream 文件大小"),
            ("1,423,048", "1,435,232", "ILA 版 bitstream 压缩后净长"),
            ("6,153,312", "6,055,840", "ILA 版省掉的位数（带逗号）"),
            ("6153312", "6055840", "ILA 版省掉的位数（无逗号）"),
            ("11,384,384", "11,481,856", "ILA 版压缩后位数（带逗号）"),
            ("11384384", "11481856", "ILA 版压缩后位数（无逗号）"),
            ("+0.527", "−3.268", "ILA 版 sys_clk WNS"),
            ("18213", "17063", "ILA 版 sys_clk 时序端点"),
            ("+0.039", "+0.046", "ILA 版整体 WHS"),
            ("18197", "18198", "ILA 版整体 WHS 端点"),
            ("9094", "9095", "ILA 版整体 WPWS 端点"),
            ("8578", "8591", "ILA 版 Slice LUTs"),
            ("41.24", "41.30", "ILA 版 LUT 百分比"),
            ("40.75% LUT", "41.30% LUT", "ILA 版 LUT 百分比（口语写法）"),
            ("8216", "8217", "ILA 版 Slice Registers"),
            ("08:56:25", "15:14:21", "ILA 版 .bit 时间戳"),
            ("08:56:14", "15:14:12", "ILA 版 .ltx 时间戳"),
            ("08:56:11", "15:14:09", "ILA 版 impl_ila_*.rpt 时间戳"),
            ("08:55:09", "15:13:10", "ila_probe_list.txt 时间戳"),
            ("72 checks", "81 checks", "tb 回归检查条数"),
            ("39 → 63 → 72 checks", "39 → 63 → 72 → 81 checks", "tb_enc_top 检查数演变链"),
            ("08:37:24", "15:09:13", "最近一次回归的时间戳"),
            ("至今从未上板", "已于 2026-10-10 13:39 首次上板", "ILA 版上板状态（旧句已作废）"),
        ],
    },
    "2026-10-10-uart-bridge-1605": {
        "title": "生产版 08:40/12:08 -> 16:05、ILA 版 15:14 -> 16:12（新增 UART→SPI 桥）",
        "commit": "（见本轮 git 提交）",
        "evidence": (
            "_synth_work/impl_timing.rpt（:144 Timing constraints are not met.）/ "
            "impl_util.rpt / impl_drc.rpt / impl_ila_timing.rpt / impl_ila_util.rpt / "
            "impl_ila_drc.rpt / ila_build.log / enc_top.bit(804,780 B @16:05:29) / "
            "enc_top_ila.bit(1,445,812 B @16:12:01) / enc_top_ila.ltx(67,006 B @16:11:50) / "
            "ila_probe_list.txt(34 条探针, 252 bit) / sim/logs/SUMMARY.md(19/19 @16:03:11)"
        ),
        "note": (
            "本轮加 rtl/uart_rx.v + rtl/uart_spi_bridge.v（板载 CH340E 串口发 4 字节读写寄存器），"
            "新增 uart_rx 引脚 T20（端口 49 -> 50、pinout_verify 50/50），"
            "端点数 9631 -> 10582、WNS -3.271 -> -3.352（26 个负余量端点仍全是 ADC 输入端口，"
            "根因是 §1.19 的诚实 set_input_delay -max 24.000，不是回归）；"
            "08:40 那版 +0.923/0 失败构建在诚实约束之前，与现行版不可比；"
            "ILA 版同步重建到 16:12（含桥），15:14 版移入 _synth_work/signoff_pre_uart_bridge/；"
            "位流大小受压缩率影响极大（726,924 / 962,600 / 804,780 B），不能当回归判据。"
        ),
        "extra_targets": [
            "docs/02_innovation_scoring.md",
            "docs/07_board_checklist.md",
            "docs/DEV_STATUS.md",
            "rtl/SPEC_interface_contract.md",
        ],
        "map": [
            # (旧值, 新值, 说明)  —— 生产版
            ("962,600", "804,780", "生产版 bitstream 文件大小（08:40 -> 16:05）"),
            ("1,219,152", "804,780", "生产版 bitstream 文件大小（12:08 -> 16:05）"),
            ("08:40:17", "16:05:29", "生产版 .bit 时间戳"),
            ("12:08:30", "16:05:29", "生产版 .bit 时间戳（12:08 版）"),
            ("+0.923", "−3.352", "生产版整体 WNS（诚实约束前 -> 现行）"),
            ("−3.271", "−3.352", "生产版 sys_clk WNS（12:08 -> 16:05）"),
            ("9631", "10582", "生产版整体时序端点"),
            ("5763", "6010", "生产版 Slice LUTs"),
            ("27.68", "28.89", "生产版 LUT 百分比"),
            ("27.71", "28.89", "生产版 LUT 百分比（另一写法）"),
            ("3528", "3857", "生产版 Slice Registers"),
            ("8.48", "9.27", "生产版 FF 百分比"),
            ("49/49", "50/50", "端口约束数（新增 uart_rx = T20）"),
            ("18/18", "19/19", "回归通过台数（新增 tb_uart_spi_bridge）"),
            ("15:09:13", "16:03:11", "最近一次全量回归时间戳"),
            ("16:03:11", "16:21:05", "文档回写后的复核回归时间戳（同一套用例，19/19）"),
            ("14 个真实 RTL 缺陷", "15 个真实 RTL 缺陷", "缺陷计数（第 15 个 = 桥 TX 仲裁截断遥测）"),
            ("saved 9836960", "saved 11099520", "生产版 bitgen 省掉的位数"),
            ("7,700,736", "6,438,176", "生产版压缩后位数（带逗号）"),
            ("7700736", "6438176", "生产版压缩后位数（无逗号）"),
            ("962,592", "804,772", "生产版压缩后净长"),
            # ILA 版
            ("1,435,240", "1,445,812", "ILA 版 bitstream 文件大小"),
            ("1,435,232", "1,445,804", "ILA 版 bitstream 压缩后净长"),
            ("6055840", "5971264", "ILA 版省掉的位数（无逗号）"),
            ("11,481,856", "11,566,432", "ILA 版压缩后位数（带逗号）"),
            ("11481856", "11566432", "ILA 版压缩后位数（无逗号）"),
            ("−3.268", "−3.329", "ILA 版 sys_clk WNS"),
            ("17063", "18010", "ILA 版 sys_clk 时序端点"),
            ("18214", "19161", "ILA 版整体时序端点"),
            ("8612", "8939", "ILA 版 sys_clk WPWS 端点"),
            ("8591", "8822", "ILA 版 Slice LUTs"),
            ("41.30", "42.41", "ILA 版 LUT 百分比"),
            ("8217", "8544", "ILA 版 Slice Registers"),
            ("19.75", "20.54", "ILA 版 FF 百分比"),
            ("15:14:21", "16:12:01", "ILA 版 .bit 时间戳"),
            ("15:14:12", "16:11:50", "ILA 版 .ltx 时间戳"),
            ("15:14:09", "16:11:48", "ILA 版 impl_ila_*.rpt 时间戳"),
            ("15:13:10", "16:10:41", "ila_probe_list.txt 时间戳"),
        ],
    },
}

DEFAULT_TARGETS = [
    "README.md",
    "sim/README.md",
    "docs/00_roadmap_30d.md",
    "docs/01_technical_solution.md",
    "docs/04_wiring_checklist.md",
    "docs/05_vivado_sim_impl_report.md",
    "docs/06_board_test_guide.md",
]


def two_phase_replace(text: str) -> tuple[str, list[tuple[str, str, int]]]:
    """先用占位符吃掉老值，再把占位符换成新值，避免链式污染。"""
    hits: list[tuple[str, str, int]] = []
    for idx, (old, new, why) in enumerate(RULES):
        n = text.count(old)
        if not n:
            continue
        token = f"\x00SYNCNUM{idx}\x00"
        text = text.replace(old, token)
        hits.append((old, new, n))
        # 立刻把该 token 换成新值
        text = text.replace(token, new)
    return text, hits


def audit(round_name: str | None, targets: list[str]) -> int:
    """按 ROUNDS 里的逐轮映射审计：报告旧值残留，并区分"有意保留"与"漏改"。"""
    names = [round_name] if round_name else list(ROUNDS)
    if hasattr(sys.stdout, "reconfigure"):
        # Windows 控制台默认 GBK：脚本里若出现 GBK 不支持的字符（如 ⇒/✓），
        # print 会直接抛 UnicodeEncodeError 中断整轮审计。这里降级成替换字符。
        try:
            sys.stdout.reconfigure(errors="replace")
        except Exception:
            pass
    grand = 0
    todo = 0
    for name in names:
        info = ROUNDS.get(name)
        if info is None:
            print(f"[!! ] 未知轮次：{name}（可用：{', '.join(ROUNDS)}）")
            return 1
        # 轮次可以补一份 extra_targets（本轮改过但不属于 DEFAULT_TARGETS 的文件）
        scan = targets or list(dict.fromkeys(DEFAULT_TARGETS + info.get("extra_targets", [])))
        print(f"\n[audit] {name} — {info['title']}")
        print(f"        commit {info['commit']}")
        print(f"        证据：{info['evidence']}")
        if info.get("note"):
            print(f"        备注：{info['note']}")
        for rel in scan:
            p = ROOT / rel
            if not p.is_file():
                print(f"  [skip] {rel}  (not found)")
                continue
            with p.open("r", encoding="utf-8", newline="") as fh:
                for lineno, line in enumerate(fh, 1):
                    for old, new, why in info["map"]:
                        if old not in line:
                            continue
                        grand += 1
                        marks = [m for m in HISTORY_MARKERS if m in line]
                        if marks:
                            tag = "[历史-OK ]"
                            extra = "  历史标记=" + "/".join(marks)
                        else:
                            tag = "[!! 待确认]"
                            extra = ""
                            todo += 1
                        shown = line.strip()
                        if len(shown) > 110:
                            shown = shown[:107] + "..."
                        print(f"  {tag} {rel}:{lineno}  旧值 {old} -> {new}"
                              f"（{why}）{extra}")
                        print(f"             {shown}")
    print(f"\n[audit] 旧值残留合计 {grand} 处；其中 [!! 待确认] {todo} 处"
          f"（其余带历史标记，属有意保留）。")
    return 0


def main(argv: list[str]) -> int:
    args = list(argv[1:])
    check_only = "--check" in args
    positional = [a for a in args if not a.startswith("--")]
    if "--audit" in args:
        # 第一个位置参数若是已知轮次名，就把它当轮次名，其余当文件名
        if positional and positional[0] not in ROUNDS and "." not in positional[0]:
            print(f"[!! ] 未知轮次：{positional[0]}"
                  f"（可用：{', '.join(ROUNDS)}；若想指定文件请带扩展名）")
            return 1
        round_name = positional[0] if positional and positional[0] in ROUNDS else None
        files = positional[1:] if round_name else positional
        return audit(round_name, files)
    targets = positional or DEFAULT_TARGETS
    grand = 0
    for rel in targets:
        p = ROOT / rel
        if not p.is_file():
            print(f"[skip] {rel}  (not found)")
            continue
        # ★ newline="" ：不做换行转换。默认的 text 模式在 Windows 上会把 \n 写成
        #   \r\n，于是每行都"变了"，一个 4 行的改动会变成整文件 1500 行的 diff。
        #   .gitattributes 已经把 *.md 规定成 text eol=lf，工作树里也必须是纯 LF。
        with p.open("r", encoding="utf-8", newline="") as fh:
            orig = fh.read()
        new, hits = two_phase_replace(orig)
        if new == orig:
            print(f"[ -- ] {rel}: 无变化")
            continue
        n_all = sum(h[2] for h in hits)
        grand += n_all
        flag = "(check only)" if check_only else ""
        print(f"[ok  ] {rel}: {n_all} 处 {flag}")
        for old, newv, n in hits:
            print(f"         {old:>12} -> {newv:<12} x{n}")
        if not check_only:
            if "\r\n" in new:
                print(f"         !! 警告：结果里出现 CRLF，已强制转成 LF")
                new = new.replace("\r\n", "\n")
            with p.open("w", encoding="utf-8", newline="") as fh:
                fh.write(new)
    print(f"\n合计 {grand} 处")
    if check_only:
        print("(--check 模式：未写入任何文件)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
