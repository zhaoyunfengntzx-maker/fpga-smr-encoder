#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_cn_glyphs.py -- 一次性工具：把 16x16 简体中文字模栅格化并冻结成 tools/cn_glyphs.py

为什么是"一次性 + 冻结"
-----------------------
运行期不能有字体依赖：屏上的字必须来自 ROM，而不是某个 .ttf。
所以本脚本只在**字符集变化时**手工跑一次，产物 tools/cn_glyphs.py 是
人眼可验的 ASCII art，进仓库、进 diff、可评审 —— 与 5x7 ASCII 字模
（tools/gen_font_rom.py 里的 _g(...) 块）保持同一套做法。

为什么需要它：16x16 汉字有 256 个像素、几十笔，手写点阵既慢又必然出错；
用 15px 黑体栅格化再冻结，笔画是字体设计师调过的，比手画准。

依赖：Windows + 黑体（C:\\Windows\\Fonts\\simhei.ttf）+ Pillow。
      只在改字表时需要重跑；CI/其它机器只需要 tools/cn_glyphs.py。

字号与阈值的选择依据（见 _disp_work/cn_thr.png 的对比图）
----------------------------------------------------------
  * 字号 15：16x16 格里左右各留 0.5~1 px 空隙，否则相邻汉字会连成一片；
            16 px 满格时字距为 0，整行中文会糊成一条。
  * 阈值 60：黑体 16px 反走样后取 60 得到的墨量 ≈ 44%，
            与 5x7 放大 2 倍（2 px 笔画）的 ASCII 字模视觉分量相当。
            阈值取 1 太肥（复杂字如"率/累"笔画并拢），取 180 太瘦（"频/障"断笔）。

输出：tools/cn_glyphs.py
  CHARS : 64 个汉字，**顺序即索引顺序**（在 ASCII 44 字之后顺延）
  ART   : {汉字: [16 行 x 16 列 的 '#'/'.' 字符串]}
"""

import os
import sys

# ---------------------------------------------------------------------------
# 字符表。顺序 = 索引顺序，改这里必须同步改 tools/gen_font_rom.py 的 CHARS。
# 覆盖 P1/P6/P8 三页所有中文标签用到的字，去重后 64 个（7 bit 索引够用）。
# ---------------------------------------------------------------------------
CN_ORDER = (
    # 导航栏 6 项（XY 用 ASCII，不占汉字）
    "总览波形时序状态设置"
    # P1 总览六卡
    "输入频率倍分边沿等效电气方向角度累计转数速"
    # P6 设置九项 + 危险区
    "极对迟滞限幅脉宽相位性清除锁存故障"
    # P8 触摸诊断九项 + 底栏
    "触摸诊点读次产品号无应答超中断平翻复"
    # P7 标定与误差可视化（标题 + 左框标题 + 图例 + 右框标题 + 底栏）
    #   ★ 参数名一律用 ASCII（OFS-S / GAIN-C / PHASE-K / SHIFT），
    #     这样这一页只需要下面 11 个字，不必为"增益/偏移"再造字模。
    "标定误差曲线前后参数值幅"
    # P2/P3/P4 三页（v17 补文字层；上板照片上这三页原来是完全无字的光板）
    #   P2 标题"输入波形" + 底栏"等效采样 100us"  -> 采样
    #   P3 标题"李萨如 XY"                        -> 李萨如
    #   P4 标题"逻辑时序" + 轴标"电角度"          -> 逻辑（电角度三字已在表内）
    #   ★ 预算：tools/gen_text_ram.py:48
    #     LAB_CODE_W = (len(CHARS)-1).bit_length()，当时 44 ASCII + 76 汉字 = 120 码
    #     是 7 bit，上限 128 码 ⇒ 那次加 7 个（合计 83 汉字、127 码），只留 1 码。
    "采样李萨如逻辑"
    # v23（㉓ 字库扩容）：规范 §5 的状态词 + §6.5「↩ 回到 ×8」的用语。
    #   ★ 7 bit 已满（127 码只剩 1），所以这一次**先把 lab 码宽升到 8 bit**
    #     （上限 256 码）再加字：44 ASCII + 2 符号（% × ÷）+ 91 汉字 = 137 码。
    #     升位宽牵连 tools/gen_font_rom.py 的 PLANES[lab].idx_w、
    #     disp/text_ram.v 与 disp/disp_engine.v 的 lab_ch_* 线宽（见那边注释）。
    "正常警示故障回到"
    # v32（㉙）：spec §5.2 第四重冗余「可关闭的 2 Hz 闪烁」的开关名。
    #   P6 标题带的主操作按钮（spec §4.2 的 [主操作按钮] 槽位，与 P1「标定」/
    #   P4「EXPAND」共用同一矩形与同一命中编号）在这页写成「闪烁」+ 一个几何
    #   复选框（实心 = 开、空心 = 关，不靠颜色）。**追加而不是插队**：CN_ORDER
    #   的顺序就是 lab 字符码顺序，插队会让屏上所有中文串位。
    "闪烁"
    # v35（㉛）：spec §4.4 把 P8 定义成「系统信息 / 自检」，页面标题与分区标签
    #   要用到下面这 12 个字。★ 仍然**只追加**：CN_ORDER 的顺序 = lab 字符码顺序。
    #   规范 §4.4 的 P8 五项：设备 ID / 固件版本 / 链路统计 / 资源占用 / 自检结果。
    #   其中「自检结果」四个字与「通过 / 失败」留到下一轮（判定输出一起做），
    #   这一轮先把标题、前四项的标签字模备齐。
    "系统信息设备固件版本资源占用"
    # v36（㉜）：spec §4.4 的 P8 五项里的最后一项「自检结果」。规范要求屏幕上
    #   给出结论，而结论文本只有「通过 / 失败」两种；「自检结果」四个字是那一行
    #   的静态标签（写在 P8 的 lab 第 36 格行，与底栏三个链路数值同一行）。
    #   ★ 仍然**只追加**：前 12 个字（v35）与它们的字符码一个都不动。
    "自检结果通过失败"
    # v38（㉞）：spec §7 的表（docs/13_display_ui_requirements.md:305）对 ABZ/UVW 时序图
    #   只给了一句要求：「时间轴画 A/B 会混叠，**必须按电角度 64/128 箱等效采样，
    #   并在图上注明**」。这句"在图上注明"的字面口径需要 按/重/建/箱 四个字 ——
    #   旧注记写的是「128点等效采样」，当时正是因为这四个字不在字库里（㉑ 那会儿
    #   7 bit 已满），只好用"点"顶替"箱"、把"按电角度"拆到轴标那一行去凑。
    #   ㉓ 把 lab 码宽升到 8 bit 之后门槛已经拆掉，所以这一轮把注记补成字面口径：
    #   「按电角度重建128箱等效采样」（14 格，写在 P4 的 lab 第 27 格行）。
    #   ★ 仍然**只追加**：前 112 个字（v35/v36）与它们的字符码一个都不动。
    "按重建箱"
    # v39（㉟）：spec §7 的数据来源表里，有两条"**屏上要写明口径**"的要求落在了 P1
    #   的两张卡上，而屏上从来没有这两句话：
    #     · docs/13_display_ui_requirements.md:300 —— 机械转速 RPM = 60×f_in/极对数，
    #       **标「估算值」**（因为 f_in 本身是 64 周期解回绕/计数器算出来的）；
    #     · docs/13_display_ui_requirements.md:302 —— 累计转数从「本次上电」起算，
    #       **不是掉电保存的绝对值，屏上要写明**。
    #   两句话需要 估/算/上/起 四个字（值/本/次/电 早在表内），所以这一轮补这四字：
    #   「估算值」写在 P1 转速卡的 RPM 单位下方，「本次上电起算」写在累计转数卡的
    #   标题下方（都在 lab 面的空行上，见 tools/gen_text_ram.py 的 P1_LAB）。
    #   ★ 仍然**只追加**：前 116 个字（v35/v36/v38）与它们的字符码一个都不动。
    "估算上起"
    # v40（㊱）：U-25.7 ② 挂账的那件事 —— P5 六状态表的**状态名**一直是 ASCII 的
    #   `U1 V0 W0` 这种写法，spec 的中文界面上应该写汉字。当年做不了是因为
    #   lab 码宽只有 7 bit（0..127）、字库 44 ASCII + 83 汉字 = 127 码已满，
    #   只剩 1 个空位；㉓ 把码宽升到 8 bit 之后这个门槛就没了（现在用到 170 码）。
    #   本轮把六行的状态名改成 **U/V/W 三位电平的汉字写法**：
    #       `U高 V低 W低` / `U低 V高 W低` / `U高 V高 W低` /
    #       `U低 V低 W高` / `U高 V低 W高` / `U低 V高 W高`
    #   （1 → 高、0 → 低；U/V/W 三个字母与空格仍是 ASCII，所以每行仍是 8 格，
    #     与 tools/gen_text_ram.py 的 P5_LAB 列位一一对应，列位不用动。）
    #   只需要 高/低 两个字，所以这一轮补这两字。
    #   ★ 仍然**只追加**：前 120 个字（v35/v36/v38/v39）与它们的字符码一个都不动。
    "高低"
    # v41（㊳）：U-40.8 ① 挂账的「项高 88」这一轮收口 —— P6 从 3 列 x 4 项（档距
    #   128 px）改成 3 列 x **5 项、档距 88 px**（5 x 88 = 440，内容区 y 64..503
    #   正好铺满，危险区 504..599 不动）。多出来的一行放 v15 就回读、但从来没上过
    #   屏的三个修正参数：
    #       增益S / 增益C   （cfg_gain_s / cfg_gain_c，无符号 Q1.15）
    #       相位修正        （cfg_phase_k，有符号 Q1.15）
    #   这三项要 增/益/修/正 四个字（相/位 早在表内），所以这一轮补这四个字：
    #   「增益S」「增益C」写在 P6 第五行第 1/2 列的标题格，「相位修正」写在第 3 列。
    #   ★ 仍然**只追加**：前 122 个字（v35/v36/v38/v39/v40）与它们的字符码一个都不动。
    "增益修正"
    # v42（㊴）：U-40.8 ② 挂账的 spec §4.6「恢复默认」这一轮收口 —— P6 危险区从
    #   一颗按钮（"清除锁存故障"）改成**对称两颗**（"清除锁存故障" | "恢复默认"），
    #   后者弹第二套确认对话框（spec 6.4 要求二次确认），确认后屏侧自己把 13 条
    #   4 字节写命令按固定顺序打进 enc_top.uart_rx（现有命令一条写两个连续寄存器，
    #   所以不需要改冻结契约 rtl/SPEC_interface_contract.md）。
    #   这条线要 恢/默/认 三个字（复 早在「复现」里），所以这一轮补这三个字：
    #   「恢复默认」写在危险区第二颗按钮的标签格（lab 行 34 格列 49）与
    #   恢复对话框的标题格（lab 行 14 格列 29）。
    #   ★ 仍然**只追加**：前 125 个字（v35/v36/v38/v39/v40/v41）与它们的字符码一个都不动。
    "恢默认"
    # v43（㊵）：㊴ 之后重读 spec docs/13 §4.4 的**入口**一列，发现两处标签当年因为
    #   缺字被写成了 ASCII 缩写（`tools/gen_text_ram.py` 里留着"这两个字都不在字库"
    #   的注释）：
    #       P2 入口 = 导航「波形」→ Tab「模拟」（当年写 SIM，3 格）
    #       P5 入口 = P4 表格「展开」（当年写 EXPAND，6 格）
    #   spec 的字面是 模拟 / 展开，所以这一轮补 模/拟/展/开 四个字把它们写回去：
    #       「模拟」写在 P2/P3 的页内 Tab 1（lab 行 7 格列 11，2 格居中于 x 196）；
    #       「展开」写在 P4 标题带的主操作按钮（lab 行 2 格列 45，与 P1「标定」同格列、
    #       同一个命中编号 HIT_TITLE_BTN）。
    #   ★ 仍然**只追加**：前 128 个字（…/v42）与它们的字符码一个都不动。
    "模拟展开"
)

SIZE = 15
THRESHOLD = 60
BOX = 16
FONT = r"C:\Windows\Fonts\simhei.ttf"

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "cn_glyphs.py")


def check_covers_layout(order):
    """版面里出现的每个汉字都必须有字模 —— 这是本脚本唯一能犯的错。

    版面文本住在 tools/gen_text_ram.py 里（那边有"字库之外一律拒绝"的检查），
    所以这里把那个模块的版面清单直接拿过来对：漏一个字，这里就当场拦下，
    而不是等到屏上出现方框才发现。
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location("gen_text_ram",
                                                  os.path.join(HERE, "gen_text_ram.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    used = set()
    for t in mod.all_texts():
        for ch in t:
            if "\u4e00" <= ch <= "\u9fff":
                used.add(ch)
    missing = sorted(used - set(order))
    if missing:
        raise SystemExit("layout uses %d CJK char(s) with no glyph: %s"
                         % (len(missing), "".join(missing)))
    print("layout CJK chars %d, all covered by %d glyphs" % (len(used), len(order)))


def build_art():
    from PIL import Image, ImageDraw, ImageFont

    if not os.path.exists(FONT):
        raise SystemExit("font not found: %s" % FONT)

    order = []
    for ch in CN_ORDER:
        if ch not in order:
            order.append(ch)
    check_covers_layout(order)

    font = ImageFont.truetype(FONT, SIZE)
    art = {}
    for ch in order:
        img = Image.new("L", (BOX, BOX), 0)
        ImageDraw.Draw(img).text((BOX // 2, BOX // 2), ch, fill=255, font=font, anchor="mm")
        px = img.load()
        rows = []
        for y in range(BOX):
            rows.append("".join("#" if px[x, y] >= THRESHOLD else "." for x in range(BOX)))
        if all("#" not in r for r in rows):
            raise SystemExit("glyph %r rendered empty; font/size mismatch?" % ch)
        art[ch] = rows
    return order, art


def coverage(art):
    tot = 0
    for rows in art.values():
        tot += sum(r.count("#") for r in rows)
    return tot / float(len(art) * BOX * BOX)


def main():
    order, art = build_art()
    assert len(order) == len(set(order)), "duplicate chars"

    L = []
    L.append("# -*- coding: utf-8 -*-")
    L.append('"""cn_glyphs.py -- 自动生成，请勿手改')
    L.append("")
    L.append("  生成器: tools/make_cn_glyphs.py")
    L.append("  字形源: %s @ %d px，阈值 %d，居中于 %dx%d 格" % (os.path.basename(FONT), SIZE, THRESHOLD, BOX, BOX))
    L.append("  字符数: %d（顺序 = 索引顺序，紧接 44 个 ASCII 字模之后）" % len(order))
    L.append("  墨量  : %.1f%%" % (coverage(art) * 100.0))
    L.append("")
    L.append("  为什么是 ASCII art 而不是十六进制：")
    L.append("    汉字笔画多，十六进制看不出来对不对；art 可以在 diff 里直接看。")
    L.append("    与 tools/gen_font_rom.py 里 5x7 的 _g(...) 块保持同一套人眼可验的做法。")
    L.append('"""')
    L.append("")
    L.append("# 顺序 = 索引。改这个顺序会让屏上所有中文串位，必须与 gen_font_rom.py 同步。")
    L.append("CHARS = %r" % ("".join(order),))
    L.append("")
    L.append("# {汉字: [16 行，每行 16 列，'#' = 落墨]}")
    L.append("ART = {")
    for ch in order:
        L.append("    %r: [" % (ch,))
        for r in art[ch]:
            L.append("        %r," % (r,))
        L.append("    ],")
    L.append("}")
    L.append("")

    txt = "\n".join(L)
    assert not txt.startswith("\ufeff"), "BOM must not be emitted"
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(txt)

    print("wrote %s" % OUT)
    print("  chars    : %d" % len(order))
    print("  coverage : %.1f%%" % (coverage(art) * 100.0))
    print("  order    : %s" % "".join(order))


if __name__ == "__main__":
    sys.exit(main())
