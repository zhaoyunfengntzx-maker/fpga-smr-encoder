# -*- coding: utf-8 -*-
"""生成《2048 个刻度》项目介绍文档（DOCX），随后导出 PDF。

内容来源：老师讲解稿（用户提供的定稿文字）+ deliverables/figures 下的图。
运行： <bundled python> tools/build_intro_doc.py
"""
import os

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIG = os.path.join(ROOT, "deliverables", "figures")
OUT_DOCX = os.path.join(ROOT, "deliverables", "project_intro.docx")

INK = RGBColor(0x1A, 0x1A, 0x1A)
GREY = RGBColor(0x60, 0x60, 0x60)
ACCENT = RGBColor(0x9A, 0x5B, 0x1E)      # 琥珀色，与图表配色一致
HEI = "微软雅黑"
SONG = "宋体"
MONO = "Consolas"


# --------------------------------------------------------------------------- 基础工具
def _ea(run, name):
    """同时设置西文与中文（eastAsia）字体。"""
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), name)
    rfonts.set(qn("w:ascii"), name)
    rfonts.set(qn("w:hAnsi"), name)


def shade(cell, hex_color):
    el = OxmlElement("w:shd")
    el.set(qn("w:val"), "clear")
    el.set(qn("w:fill"), hex_color)
    cell._tc.get_or_add_tcPr().append(el)


def cell_borders(cell, color="C9C9C9", sz="6"):
    tcpr = cell._tc.get_or_add_tcPr()
    borders = OxmlElement("w:tcBorders")
    for edge in ("top", "left", "bottom", "right"):
        e = OxmlElement("w:" + edge)
        e.set(qn("w:val"), "single")
        e.set(qn("w:sz"), sz)
        e.set(qn("w:color"), color)
        borders.append(e)
    tcpr.append(borders)


def para(doc, text="", size=10.5, bold=False, color=INK, font=SONG,
         before=0, after=6, line=1.45, align=None, indent_cm=0.0):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    pf.line_spacing = line
    if indent_cm:
        pf.first_line_indent = Cm(indent_cm)
    if align is not None:
        p.alignment = align
    if text:
        r = p.add_run(text)
        _ea(r, font)
        r.font.size = Pt(size)
        r.bold = bold
        r.font.color.rgb = color
    return p


def rich(doc, parts, size=10.5, after=6, line=1.45, indent_cm=0.0):
    """parts = [(text, bold, color), ...]"""
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    pf = p.paragraph_format
    pf.space_after = Pt(after)
    pf.line_spacing = line
    if indent_cm:
        pf.first_line_indent = Cm(indent_cm)
    for text, bold, color in parts:
        r = p.add_run(text)
        _ea(r, SONG)
        r.font.size = Pt(size)
        r.bold = bold
        r.font.color.rgb = color
    return p


def h1(doc, num, text):
    num = {"一": "01", "二": "02", "三": "03", "四": "04",
           "五": "05", "六": "06", "七": "07", "八": "08",
           "九": "09"}.get(num, num)
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_before = Pt(18)
    pf.space_after = Pt(8)
    pf.keep_with_next = True
    r = p.add_run(num + "  ")
    _ea(r, HEI)
    r.font.size = Pt(11)
    r.bold = True
    r.font.color.rgb = ACCENT
    r2 = p.add_run(text)
    _ea(r2, HEI)
    r2.font.size = Pt(15)
    r2.bold = True
    r2.font.color.rgb = INK
    # 标题下的细线
    pbdr = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "8")
    bottom.set(qn("w:space"), "4")
    bottom.set(qn("w:color"), "D9C7A8")
    pbdr.append(bottom)
    p._p.get_or_add_pPr().append(pbdr)
    return p


def h2(doc, text):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_before = Pt(12)
    pf.space_after = Pt(4)
    pf.keep_with_next = True
    r = p.add_run(text)
    _ea(r, HEI)
    r.font.size = Pt(11.5)
    r.bold = True
    r.font.color.rgb = ACCENT
    return p


def picture(doc, name, caption, width_cm=15.6):
    path = os.path.join(FIG, name)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(8)
    p.paragraph_format.space_after = Pt(2)
    p.add_run().add_picture(path, width=Cm(width_cm))
    cap = doc.add_paragraph()
    cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
    cap.paragraph_format.space_after = Pt(12)
    r = cap.add_run(caption)
    _ea(r, SONG)
    r.font.size = Pt(8.5)
    r.font.color.rgb = GREY


def table(doc, rows, widths, header=True, size=9.5, align_first_left=True):
    t = doc.add_table(rows=len(rows), cols=len(widths))
    t.style = "Table Grid"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    for r_i, row in enumerate(rows):
        for c_i, val in enumerate(row):
            cell = t.cell(r_i, c_i)
            cell.width = Cm(widths[c_i])
            cell.text = ""
            p = cell.paragraphs[0]
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = 1.15
            if c_i > 0 and not align_first_left:
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            elif c_i > 0 and header and r_i > 0:
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            run = p.add_run(str(val))
            _ea(run, SONG)
            run.font.size = Pt(size)
            if header and r_i == 0:
                run.bold = True
                run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)
                shade(cell, "8A5A2B")
            elif r_i % 2 == 0:
                shade(cell, "F7F4EF")
    # 表后空隙
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return t


def callout(doc, title, body, fill="FBF3E4", border="D9A441"):
    t = doc.add_table(rows=1, cols=1)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    cell = t.cell(0, 0)
    cell.width = Cm(15.6)
    shade(cell, fill)
    cell_borders(cell, border, "10")
    p0 = cell.paragraphs[0]
    p0.paragraph_format.space_before = Pt(6)
    p0.paragraph_format.space_after = Pt(2)
    r = p0.add_run(title)
    _ea(r, HEI)
    r.font.size = Pt(10.5)
    r.bold = True
    r.font.color.rgb = RGBColor(0x8A, 0x4A, 0x10)
    p1 = cell.add_paragraph()
    p1.paragraph_format.space_after = Pt(6)
    p1.paragraph_format.line_spacing = 1.4
    r2 = p1.add_run(body)
    _ea(r2, SONG)
    r2.font.size = Pt(10)
    r2.font.color.rgb = RGBColor(0x3A, 0x2A, 0x18)
    doc.add_paragraph().paragraph_format.space_after = Pt(4)


def code_box(doc, lines):
    t = doc.add_table(rows=1, cols=1)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    cell = t.cell(0, 0)
    cell.width = Cm(15.6)
    shade(cell, "F4F5F7")
    cell_borders(cell, "D6DAE0", "8")
    first = True
    for ln in lines:
        p = cell.paragraphs[0] if first else cell.add_paragraph()
        first = False
        p.paragraph_format.space_before = Pt(3 if ln is lines[0] else 0)
        p.paragraph_format.space_after = Pt(3 if ln is lines[-1] else 0)
        p.paragraph_format.line_spacing = 1.25
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run(ln)
        _ea(r, MONO)
        r.font.size = Pt(9.5)
        r.font.color.rgb = RGBColor(0x24, 0x2A, 0x33)
    doc.add_paragraph().paragraph_format.space_after = Pt(4)


def add_page_number_footer(section):
    p = section.footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run()
    _ea(r, SONG)
    r.font.size = Pt(8.5)
    r.font.color.rgb = GREY
    fld = OxmlElement("w:fldSimple")
    fld.set(qn("w:instr"), "PAGE")
    p._p.append(fld)


# --------------------------------------------------------------------------- 文档
doc = Document()

sec = doc.sections[0]
sec.page_width = Cm(21.0)
sec.page_height = Cm(29.7)
sec.left_margin = Cm(2.7)
sec.right_margin = Cm(2.7)
sec.top_margin = Cm(2.4)
sec.bottom_margin = Cm(2.4)
add_page_number_footer(sec)

normal = doc.styles["Normal"]
normal.font.name = SONG
normal.font.size = Pt(10.5)
normal.element.rPr.rFonts.set(qn("w:eastAsia"), SONG)

# —— 封面区
p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(30)
p.paragraph_format.space_after = Pt(0)
r = p.add_run("2048 个刻度")
_ea(r, HEI)
r.font.size = Pt(30)
r.bold = True
r.font.color.rgb = INK

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(4)
p.paragraph_format.space_after = Pt(2)
r = p.add_run("把细分算法、接口与诊断收进一片 FPGA")
_ea(r, HEI)
r.font.size = Pt(15)
r.font.color.rgb = ACCENT

p = doc.add_paragraph()
p.paragraph_format.space_after = Pt(16)
r = p.add_run("项目介绍与技术原理说明   ·   2026 年 11 月   ·   AMD 赛道 自主选题")
_ea(r, SONG)
r.font.size = Pt(9.5)
r.font.color.rgb = GREY

# —— 一、一句话
h1(doc, "一", "一句话讲清这个项目")
rich(doc, [
    ("传感器转一圈，输出两路本应完美的正弦波，但实际是“歪”的；我用一片 FPGA 实时把它们算成精确角度，"
     "并把它做成一套分辨率和接口都不输同类专用细分 ASIC（公开资料典型值）的位置反馈方案。", False, INK),
], indent_cm=0.0)

# —— 二、要解决什么问题
h1(doc, "二", "要解决什么问题")
rich(doc, [
    ("电机、机器人关节、数控转台都需要知道自己“转了多少度”，这由编码器负责。光电编码器精度高，"
     "但依靠光路工作。现场有粉尘、油污或振动时，光路一旦受污染，就会出现细分误差突增甚至丢计数，"
     "这是产线上很典型的故障。", False, INK),
])
rich(doc, [
    ("磁阻（SMR）传感器没有光路，非接触、抗污染，更适合粉尘与油污现场；但它自身也有系统误差：", False, INK),
])
table(doc, [
    ["误差", "物理来源", "不校正时角度误差"],
    ["直流偏置", "电桥、放大器失调", "13.99°"],
    ["幅值失衡", "两路增益差 1.25×", "6.39°"],
    ["正交偏差", "不是正好差 90°（5°）", "5.00°"],
    ["三类叠加", "——", "20.98°"],
], widths=[3.0, 7.2, 5.0])
rich(doc, [
    ("20° 意味着“让它转 90°，它报 70°”。所以必须校正，而校正正是各类细分 ASIC 存在的理由。",
     False, INK),
])

# —— 三、项目做了什么
h1(doc, "三", "项目做了什么")
rich(doc, [
    ("用一片通用 FPGA（Artix-7 XC7A35T）把细分、校正与多协议输出整套流程实现在片内，而且更好。", False, INK),
])
rich(doc, [
    ("信号在片内走一条固定 ", False, INK),
    ("41.5 拍 ≈ 830 ns", True, ACCENT),
    (" 的流水线，全程单一 50 MHz 时钟域（不例化 MMCM、不做跨时钟域，这是延迟可预测、无亚稳态的根本）：",
     False, INK),
])
code_box(doc, [
    "ADC 同步采样 → 4 倍平均 → 六参数校正 → CORDIC 反正切 → PI 环路 → 多圈展开",
    "→ ABZ / UVW / SPI / 串口 / 屏幕 / 千兆网",
])
picture(doc, "sys_arch.png",
        "图 1  系统结构：左侧模拟前端与 ADC，中间单一 50 MHz 时钟域内的六级流水线，右侧六类输出")
table(doc, [
    ["指标", "本项目", "同类专用细分 ASIC（公开资料典型值）"],
    ["分辨率", "16 bit／65536 每周期（0.0055°）", "10 bit（0.3516°）"],
    ["校正参数", "6 个，闭式算出，寄存器可读写", "固件封闭，参数不可见"],
    ["接口", "ABZ＋UVW＋SPI＋UART＋千兆网＋屏幕", "SPI＋ABZ＋UVW"],
    ["延迟", "≈830 ns", "1.5 µs"],
    ["算法", "RTL 源码，可改可扩展", "不可改"],
], widths=[2.8, 7.6, 4.8])
picture(doc, "fig_pipeline.png",
        "图 2  端到端延迟预算：仅 CORDIC 一级就占 19 拍，是整条链路的大头", width_cm=16.0)

# —— 四、原理
h1(doc, "四", "技术原理：五步，每步都讲“为什么必须这么干”")

h2(doc, "① 同步采样")
rich(doc, [
    ("sin 和 cos 必须同一时刻采。差几十纳秒，在高速旋转时就等于引入随转速变化的相位误差。"
     "一片 AD9238 双通道共用采样保持，外部用两个 ODDR 以同相方式转发 50 MHz 时钟"
     "（早期反相驱动只剩 4 ns 余量，出过毛刺；改同相后余量回到 9.6 ns）。"
     "采完再做 4 点平均，等效分辨率由 12 位提高到约 13 位。", False, INK),
])
picture(doc, "fig_compare.png",
        "图 3  反相驱动（左）在采样点附近出现 0x300 卡死毛刺，角度塌陷 200 LSB；改同相驱动后（右）干净",
        width_cm=16.0)

h2(doc, "② 六参数校正 —— 核心算法：把“歪椭圆”掰回“正圆”")
rich(doc, [
    ("把 (sin, cos) 画在平面上，理想的点落在一个单位圆上，极角就是角度。真实情况是落在一个歪掉的椭圆上："
     "中心偏了、长短轴不等、轴还斜了。所以校正的本质是：找出 6 个数，把椭圆平移、缩放、剪切，变回圆。",
     False, INK),
])
rich(doc, [
    ("关键在于不用迭代搜索，一次统计就能完成——转一圈后取均值得到偏置，取方差得到幅值，取协方差得到正交偏差，"
     "都是闭式公式。好处是无偏、对噪声不敏感，而且不需要知道输入频率。", False, INK),
])
picture(doc, "fig_calibration.png",
        "图 4  左：校正前的歪椭圆；中：校正后的圆；右：半径分布从散开变成一根尖峰", width_cm=16.0)

h2(doc, "③ CORDIC —— FPGA 怎么算反正切")
rich(doc, [
    ("FPGA 不擅长除法、开方和三角函数。CORDIC 的思路很巧妙：把向量一次次往 x 轴上“掰”，"
     "每次只问“往哪边掰”，掰 17 次后向量基本躺在 x 轴上，把每次掰过的角度加起来就是答案。"
     "全程只用加法和移位（右移就是乘 2⁻ⁱ），不需要乘法器，也不需要查找表。", False, INK),
])

h2(doc, "④ PI 环路 —— 输出质量为何干净")
rich(doc, [
    ("CORDIC 输出会跟着 ADC 噪声抖，直接使用会让 ABZ 边沿抖动。加一个 Ⅱ 型 PI 环路让输出角度去“追”"
     "CORDIC 角度：P 项追得快，I 项消稳态误差，积分器输出天然就是角速度。", False, INK),
])
rich(doc, [
    ("这里有个真实的坑，也是最能证明“不是照搬”的地方：", False, INK),
    ("照搬公开资料推荐的 PI 参数会发散振荡。", True, ACCENT),
    ("用 Jury 稳定判据推导后发现，若积分使用“上一拍的旧值”，稳定条件要求 Ki < Kp，而公开资料那组参数恰好违反；"
     "改成“使用本拍更新后的积分值”后，21 组参数全部稳定。", False, INK),
])

h2(doc, "⑤ 多圈展开与输出")
rich(doc, [
    ("16 位只覆盖一个电周期。用跨零方向计数（不能用角度差分，零点抖动会多计或漏计，这是磁编码器最常见的故障），"
     "再加每转一个的 Z 脉冲对齐零点，然后按细分倍数生成 A/B 正交方波，按极对数生成 UVW 换相波。", False, INK),
])

# —— 五、为什么必须是 FPGA
h1(doc, "五", "为什么必须是 FPGA")
table(doc, [
    ["", "单片机", "FPGA"],
    ["数据率", "50 MSPS×2×12 bit = 1.2 Gbit/s，收不进来", "并行直接进"],
    ["时序", "中断、Cache、DMA 抖动", "每 20 ns 一拍，零抖动"],
    ["延迟", "几十 µs 且不确定", "830 ns 且固定 41.5 拍"],
], widths=[2.4, 7.4, 5.4])
rich(doc, [
    ("伺服环对延迟抖动极敏感，这一点上 FPGA 是必需品而不是加分项。", False, INK),
])

# —— 六、做出来的是什么
h1(doc, "六", "做出来的是什么")
rich(doc, [
    ("不只是算法跑通，而是一整台仪器：转台真机 457–459 rpm 运行、7 寸触摸屏 4 页界面、"
     "千兆网一次回传 28,672 点波形 0.06 秒、上位机在线标定、57 台 RTL 测试台全过、"
     "WNS +0.199 ns、DRC 0 错误。", False, INK),
])
rich(doc, [
    ("实测：板上圆度 17.786% → 0.101%（约 176 倍），板级角度一致性 offset 1.76°／RMS 0.71°／max 2.88°，"
     "仿真上限 1273 倍。", False, INK),
])
picture(doc, "fig_residual.png",
        "图 5  板上角度残差（16 bin，包络 −0.13…+0.13°）与谐波分解：4 次谐波 0.093° 占主导，"
        "剩余误差主要来自传感头与安装，而非校正算法", width_cm=16.0)

# —— 七、Q&A
h1(doc, "七", "老师最可能问的三句话，你怎么答")

h2(doc, "“精度到底多少？”")
rich(doc, [
    ("分三个口径回答：仿真 20.9839°→0.0165°（1273×）、板上圆度 17.786%→0.101%（176×）、"
     "板级角度一致性 offset 1.76°／RMS 0.71°／max 2.88°。"
     "并主动补一句：分辨率 16 bit ≠ 精度，精度最终受传感器与安装偏心限制。", False, INK),
])

h2(doc, "“为什么不直接用现成的专用 ASIC？”")
rich(doc, [
    ("同类专用细分 ASIC（公开资料典型值）锁死了三件事：分辨率通常 10 位、算法封闭、接口固定。"
     "我们要的是更高分辨率和自定义接口，所以用 FPGA 自己实现整条链路。", False, INK),
])

h2(doc, "“创新点在哪？”")
rich(doc, [
    ("不是“做了个编码器”，而是：把分辨率、算法与接口三处限制都握在自己手里；自带仪表与数据通道；"
     "拥有可复核的证据链（57 台回归、DRC 0、323 条 SHA256）；参数化可移植。", False, INK),
])

# —— 八、口径提醒
h1(doc, "八", "一个必须记住的区别")
callout(doc, "仿真口径 vs 板端口径",
        "“仿真 1273 倍”和“板上 176 倍”是两个口径：前者是模型在已知注入误差下的上限，"
        "后者包含真实噪声和安装误差。答辩时不能混着说——这是最容易被追问的地方。"
        "主动分开讲，比被问住强得多。")

h1(doc, "九", "附：关键数字速查")
table(doc, [
    ["指标", "数值", "口径"],
    ["分辨率", "16 bit／电周期（0.0055°）", "设计规格"],
    ["复合畸变（三类叠加）", "20.9839° → 0.0165°（1273×）", "定点模型，仿真"],
    ["板端李萨如圆度", "17.786% → 0.101%（176×）", "板上实测"],
    ["角度一致性", "offset 1.76°／RMS 0.71°／max 2.88°", "板上实测（内部一致性口径）"],
    ["端到端延迟", "41.5 拍 ≈ 830 ns", "设计预算（含 ADC 7 拍估计）"],
    ["资源占用（生产位流）", "LUT 52.78%／FF 20.97%／BRAM 32/50／DSP 17", "v90 实现结果"],
    ["时序", "WNS +0.199 ns，0 失败端点", "v90 实现结果"],
    ["验证", "57 台 RTL 测试台全过（sim 37 + disp 20），DRC 0 错误", "回归记录"],
    ["以太网回传", "28,672 点／帧，0.06 s", "板上实测"],
    ["真机转速", "457–459 rpm，Z 7.62–7.65 Hz（每转 1 个 Z）", "转台实测"],
], widths=[4.6, 6.4, 4.2])
rich(doc, [
    ("说明：本文件中的图表源文件位于 ", False, GREY),
    ("deliverables/figures/", False, GREY),
    ("，位流、证据与回归记录位于 ", False, GREY),
    ("deliverables/", False, GREY),
    ("。", False, GREY),
], size=8.5)

doc.save(OUT_DOCX)
print("saved:", OUT_DOCX)
