# -*- coding: utf-8 -*-
"""Build deliverables/technical_doc.docx from the official template.

Follows tech_doc_template.docx: A4, 3.17 cm side margins, 1.5 line spacing,
Song/Times 12 pt body, 14 pt part headings, five parts, <=20 references.
No school / advisor / team identity anywhere.
"""
import os
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.section import WD_SECTION
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

NAVY = RGBColor(0x0B, 0x25, 0x45)
AMBER = RGBColor(0xC9, 0x86, 0x12)
GREY = RGBColor(0x5B, 0x67, 0x78)
LIGHT = RGBColor(0x8A, 0x94, 0xA6)

SONG = "宋体"
HEI = "黑体"
TNR = "Times New Roman"

BODY_PT = 12
CAP_PT = 10.5
TEXT_W = 21.0 - 3.17 * 2  # 14.66 cm


def set_run(run, size=BODY_PT, bold=False, color=None, east=SONG, ascii_font=TNR,
            italic=False):
    run.font.name = ascii_font
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.italic = italic
    if color is not None:
        run.font.color.rgb = color
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.find(qn("w:rFonts"))
    if rFonts is None:
        rFonts = OxmlElement("w:rFonts")
        rPr.append(rFonts)
    rFonts.set(qn("w:ascii"), ascii_font)
    rFonts.set(qn("w:hAnsi"), ascii_font)
    rFonts.set(qn("w:eastAsia"), east)
    rFonts.set(qn("w:cs"), ascii_font)


def fmt_par(p, align=WD_ALIGN_PARAGRAPH.JUSTIFY, indent_chars=2.0, size=BODY_PT,
            before=0, after=0, line=1.5, keep=False):
    pf = p.paragraph_format
    pf.alignment = align
    pf.line_spacing = line
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    if indent_chars:
        pf.first_line_indent = Pt(size * indent_chars)
    pf.keep_with_next = keep
    pf.widow_control = True


def body(text, indent=True, after=0, bold=False, size=BODY_PT, align=WD_ALIGN_PARAGRAPH.JUSTIFY):
    p = doc.add_paragraph()
    fmt_par(p, align=align, indent_chars=2.0 if indent else 0, size=size, after=after)
    r = p.add_run(text)
    set_run(r, size=size, bold=bold)
    return p


def part_heading(text):
    p = doc.add_paragraph(style="Heading 1")
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=14, before=16, after=6, keep=True)
    r = p.add_run(text)
    set_run(r, size=14, bold=True, color=NAVY, east=HEI)
    # bottom rule
    pPr = p._element.get_or_add_pPr()
    pbdr = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "8")
    bottom.set(qn("w:space"), "3")
    bottom.set(qn("w:color"), "C98612")
    pbdr.append(bottom)
    pPr.append(pbdr)
    return p


def h2(text, num=None):
    p = doc.add_paragraph(style="Heading 2")
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=12, before=10, after=4, keep=True)
    r = p.add_run((num + " " if num else "") + text)
    set_run(r, size=12, bold=True, color=NAVY, east=HEI)
    return p


def h3(text):
    p = doc.add_paragraph(style="Heading 3")
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=12, before=6, after=2, keep=True)
    r = p.add_run(text)
    set_run(r, size=12, bold=True, color=RGBColor(0x1F, 0x3A, 0x5F), east=HEI)
    return p


def bullet(text):
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.JUSTIFY, indent_chars=0, size=12, after=0)
    p.paragraph_format.left_indent = Cm(0.74)
    p.paragraph_format.first_line_indent = Cm(-0.37)
    r = p.add_run("•\u00a0" + text)
    set_run(r, size=12)
    return p


def caption(text, before=2, after=8):
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=CAP_PT, before=before, after=after)
    r = p.add_run(text)
    set_run(r, size=CAP_PT, color=GREY, east=SONG)
    return p


def picture(path, width_cm, cap):
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, before=6, after=0, keep=True)
    p.add_run().add_picture(path, width=Cm(width_cm))
    caption(cap)


def two_pictures(path_a, path_b, width_cm, cap):
    t = doc.add_table(rows=1, cols=2)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    tblPr = t._tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        el = OxmlElement("w:" + edge)
        el.set(qn("w:val"), "none")
        el.set(qn("w:sz"), "0")
        el.set(qn("w:space"), "0")
        borders.append(el)
    tblPr.append(borders)
    for i, path in enumerate((path_a, path_b)):
        c = t.rows[0].cells[i]
        c.width = Cm(7.3)
        p = c.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(4)
        p.paragraph_format.space_after = Pt(2)
        p.add_run().add_picture(path, width=Cm(width_cm))
    caption(cap)


def shade(cell, hex_color):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), hex_color)
    tcPr.append(shd)


def cell_margins(table, top=60, bottom=60, left=90, right=90):
    tblPr = table._tbl.tblPr
    mar = OxmlElement("w:tblCellMar")
    for name, val in (("top", top), ("left", left), ("bottom", bottom), ("right", right)):
        el = OxmlElement("w:" + name)
        el.set(qn("w:w"), str(val))
        el.set(qn("w:type"), "dxa")
        mar.append(el)
    tblPr.append(mar)


def table_borders(table, color="C9D2DE"):
    tblPr = table._tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        el = OxmlElement("w:" + edge)
        el.set(qn("w:val"), "single")
        el.set(qn("w:sz"), "4")
        el.set(qn("w:space"), "0")
        el.set(qn("w:color"), color)
        borders.append(el)
    tblPr.append(borders)


def repeat_header(row):
    trPr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:tblHeader")
    el.set(qn("w:val"), "true")
    trPr.append(el)


def make_table(headers, rows, widths, cap=None, align_center=True, header_fill="0B2545"):
    if cap:
        p = doc.add_paragraph()
        fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=CAP_PT, before=8, after=2, keep=True)
        r = p.add_run(cap)
        set_run(r, size=CAP_PT, color=GREY)
    t = doc.add_table(rows=1, cols=len(headers))
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    table_borders(t)
    cell_margins(t)
    tblPr = t._tbl.tblPr
    layout = OxmlElement("w:tblLayout")
    layout.set(qn("w:type"), "fixed")
    tblPr.append(layout)
    tblW = OxmlElement("w:tblW")
    tblW.set(qn("w:w"), str(int(sum(widths) * 567)))
    tblW.set(qn("w:type"), "dxa")
    tblPr.append(tblW)
    for i, wid in enumerate(widths):
        t.columns[i].width = Cm(wid)
    hdr = t.rows[0]
    repeat_header(hdr)
    for i, h in enumerate(headers):
        c = hdr.cells[i]
        c.width = Cm(widths[i])
        shade(c, header_fill)
        p = c.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(2)
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.line_spacing = 1.15
        r = p.add_run(h)
        set_run(r, size=10, bold=True, color=RGBColor(0xFF, 0xFF, 0xFF), east=HEI)
    for ridx, row in enumerate(rows):
        cells = t.add_row().cells
        for i, val in enumerate(row):
            c = cells[i]
            c.width = Cm(widths[i])
            if ridx % 2 == 1:
                shade(c, "F2F5F9")
            p = c.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if (align_center and i > 0) else WD_ALIGN_PARAGRAPH.LEFT
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = 1.15
            r = p.add_run(str(val))
            set_run(r, size=10, bold=False, east=SONG)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)
    return t


def add_field(par, instr):
    r = par.add_run()
    fld = OxmlElement("w:fldChar")
    fld.set(qn("w:fldCharType"), "begin")
    r._r.append(fld)
    r2 = par.add_run()
    it = OxmlElement("w:instrText")
    it.set(qn("xml:space"), "preserve")
    it.text = instr
    r2._r.append(it)
    r3 = par.add_run()
    sep = OxmlElement("w:fldChar")
    sep.set(qn("w:fldCharType"), "separate")
    r3._r.append(sep)
    r4 = par.add_run("1")
    set_run(r4, size=9, color=GREY)
    r5 = par.add_run()
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    r5._r.append(end)


def par_bottom_rule(p, color="C9D2DE", sz="6"):
    pPr = p._element.get_or_add_pPr()
    pbdr = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), sz)
    bottom.set(qn("w:space"), "2")
    bottom.set(qn("w:color"), color)
    pbdr.append(bottom)
    pPr.append(pbdr)


# ----------------------------------------------------------------------
doc = Document()

# base style
normal = doc.styles["Normal"]
normal.font.name = TNR
normal.font.size = Pt(BODY_PT)
normal.element.rPr.rFonts.set(qn("w:eastAsia"), SONG)

sec = doc.sections[0]
sec.page_width = Cm(21.0)
sec.page_height = Cm(29.7)
sec.left_margin = Cm(3.17)
sec.right_margin = Cm(3.17)
sec.top_margin = Cm(2.54)
sec.bottom_margin = Cm(2.54)
sec.header_distance = Cm(1.4)
sec.footer_distance = Cm(1.4)
sec.different_first_page_header_footer = True

# header
hp = sec.header.paragraphs[0]
hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
hr = hp.add_run("基于FPGA的细分编码器 · 技术文档")
set_run(hr, size=9, color=LIGHT, east=SONG)
par_bottom_rule(hp)
# footer with page x of y
fp = sec.footer.paragraphs[0]
fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = fp.add_run("第 ")
set_run(r, size=9, color=GREY)
add_field(fp, "PAGE")
r = fp.add_run(" 页 / 共 ")
set_run(r, size=9, color=GREY)
add_field(fp, "NUMPAGES")
r = fp.add_run(" 页")
set_run(r, size=9, color=GREY)

# ---------------- title block ----------------
p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=10.5, before=6, after=2)
r = p.add_run("2026 年第九届全国大学生嵌入式芯片与系统设计竞赛")
set_run(r, size=10.5, color=GREY)

p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=10.5, after=16)
r = p.add_run("FPGA 创新设计赛道 · AMD 赛道 · 自主选题（初级组）")
set_run(r, size=10.5, color=GREY)

p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=24, before=8, after=4, line=1.1)
r = p.add_run("基于FPGA的细分编码器")
set_run(r, size=24, bold=True, color=NAVY, east=HEI)

p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=13, after=4, line=1.2)
r = p.add_run("基于 SMR 磁阻传感与单芯片 16 位细分的多协议磁编码器")
set_run(r, size=13, color=RGBColor(0x33, 0x44, 0x5C), east=SONG)

p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=10, after=14)
r = p.add_run("技术文档 · 2026-11-02")
set_run(r, size=10, color=AMBER)

rule = doc.add_paragraph()
fmt_par(rule, indent_chars=0, after=10)
par_bottom_rule(rule, color="0B2545", sz="12")

# ---------------- 摘要 ----------------
h2("摘要")
body("本作品面向伺服驱动、机床转台与机器人关节对高分辨、抗污染位置反馈的需求，设计了一款基于 SMR 磁阻传感器与 FPGA 的高精度细分磁编码器。系统以 XC7A35TFGG484-2 为唯一计算单元，在 50 MHz 单时钟域内完成双通道 12 bit、65 MSPS 同步采样、÷4 抽取、六参数闭式误差校正、17 级全流水 CORDIC 相位解算、Ⅱ 型 PI 跟踪与增量展开，输出 16 位角度（16 bit/电周期，0.0055° 电角每 LSB）以及 ABZ、UVW+Z、UDP、UART/SPI 多协议接口，并集成 1024×600 触摸屏诊断界面。全链路延迟 41.5 拍、约 830 ns（设计预算）。六参数校正由一阶/二阶矩一次解算，无需查找表，也不依赖上位机迭代；正反向 UVW 采用对称宽基分支，消除 0/5 扇区回绕吞并；多圈计数以无符号差分零扩展累加，消除跨半量程符号扩展死锁。v74 生产位流在真实 2048 周期/转转台上完成闭环：719–731 rpm、Z 12.00 Hz、单圈 2048 个电周期无丢拍、UVW 六态均匀、60 s UART 遥测连续上传 598,115 帧。资源 10,926 LUT（52.53%）、8,697 FF、32/50 BRAM、17 DSP，WNS +0.409 ns、0 失败端点（24,625 个）。作品以“建模—位精确仿真—构建签核—真机判据”的证据链交付，配套 54 个仿真台、294 件可追溯证据（149,157,322 B / 299 条 SHA-256）与一条命令签核。")
p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=10.5, before=6, after=8)
r = p.add_run("关键词：")
set_run(r, size=10.5, bold=True, color=NAVY, east=HEI)
r = p.add_run("磁编码器；SMR 磁阻传感；CORDIC；FPGA")
set_run(r, size=10.5, color=RGBColor(0x33, 0x44, 0x5C))

# ---------------- 第一部分 ----------------
part_heading("第一部分  作品概述")

h2("功能与特性")
body("作品在一块 FPGA 上同时完成传感采集、误差校正、角度解算、多协议输出与人机诊断，上电即独立工作，不依赖上位机。主要功能包括：（1）双通道 12 bit、65 MSPS 同步采集 SMR 正交信号，片内 ÷4 抽取与数字滤波；（2）偏置、增益、正交相位与残余位移六参数闭式校正，支持上电自标定与一键标定；（3）17 级全流水 CORDIC 解算 16 位绝对角，Ⅱ 型 PI 跟踪抑制抖动，增量展开保证跨 0/2π 连续；（4）ABZ 增量（2–256× 可配）、UVW 六步换相与虚拟 Z、1 GbE UDP 数据流、UART/SPI 寄存器接口；（5）1024×600 触摸屏五页诊断界面，实时显示波形、角度、速度、UVW 扇区与信号质量；（6）在线可重构细分倍数、滤波系数、标定参数与零位，配置掉电前可回读核验。")

h2("应用领域")
body("凡需要“高分辨、抗污染、可诊断”角度反馈的场合均适用：伺服电机换相与闭环——UVW、ABZ 两路同片并行输出，省去多芯片拼接；数控机床主轴与精密转台——16 位角、亚微秒延迟，适合高刚性速度环；机器人关节与协作臂——磁阻对油污、粉尘、振动不敏感；汽车电机与转向——宽温、抗 EMI；风电变桨、电梯门机、纺织机械等低速大扭矩场景。对进口细分芯片的替代价值在于：算法与接口在同一片 FPGA 内可演进，多轴可共用时钟因而天然同步，校准过程与寄存器地图完全可见、可审计。")

h2("主要技术特点")
body("（1）单时钟域：全系统 50 MHz、无 MMCM、无 CDC，延迟确定 41.5 拍；（2）闭式标定：用一阶/二阶矩直接解椭圆→圆映射，一次解算，不用查找表，不做上位机迭代；（3）全流水 CORDIC：17 级、1 角/拍，吞吐与采样率同频；（4）抗回绕：多圈计数用无符号差分零扩展，UVW 正反向各有一条宽基分支，0/5 扇区对称；（5）可诊断：位流内自带触摸 UI、1 GbE 抓包与 ILA，现场不接电脑也能看内部波形；（6）可复现：54 个仿真台、294 件证据、299 条 SHA-256 清单与一条命令签核，任何数字都能追到文件与哈希。")

h2("主要性能指标")
make_table(
    ["指标", "数值", "条件 / 说明"],
    [
        ["角度分辨率", "16 bit/电周期（0.0055° 电角/LSB）", "全周 65,536 码"],
        ["输入信号", "2048 周期/转正交 sin/cos，25.27 kHz", "SMR 传感头，0.5 Vpp/腿放大到 8 Vpp"],
        ["采样", "2×12 bit @65 MSPS，50 MHz 同步采样", "÷4 平均后 12.5 MSPS 有效样本"],
        ["实测转速", "719–731 rpm", "真实转台，2026-11-01（与 v74 同一 RTL）"],
        ["Z 索引", "12.00 Hz，每转 1 个", "内部虚拟 Z，脉宽 4 个边沿步"],
        ["角度延迟", "41.5 拍 ≈830 ns", "50 MHz，含 ADC 7 拍估计（设计预算）"],
        ["ABZ 输出", "2–256× 可配；32× 时 65,536 边沿/转", "A/B 正交，Z 门控"],
        ["UVW 输出", "六步换相，293 次/s", "720 rpm、4 极对"],
        ["以太网", "28,672 点/帧 @25 MSPS，9,968 fps", "1 GbE UDP，60 s 连续 598,115 帧"],
        ["逻辑资源", "10,926 LUT（52.53%）、8,697 FF（20.91%）、32 BRAM、17 DSP", "v74 生产位流（无 UI、无网）"],
        ["时序", "WNS +0.409 ns / WHS +0.025 ns / 0 失败", "24,625 个端点，DRC 0 Error"],
        ["位流", "1,512,664 B，SHA-256 E4634907…DA2680", "BUILD 0x0018，2026-11-02 上板验收"],
    ],
    [2.8, 5.6, 6.2],
    cap="表 1  主要性能指标（实测项取自 2026-11-01 转台上板轮次；构建项为 v74 签核值）",
)

h2("主要创新点")
bullet("六参数闭式校正：一阶/二阶矩一次解算椭圆→圆映射，替代查找表与迭代搜索，标定结果可回读审计。")
bullet("41.5 拍确定性延迟：单时钟域、无 MMCM，速度环无需在线辨识延迟。")
bullet("无符号相位差零扩展 + 正反向对称 UVW：根除跨半量程符号扩展与 0/5 扇区回绕两类静默死锁。")
bullet("单 FPGA 内同时集成 ABZ、UVW、1 GbE 与触摸诊断 UI，一块板完成采集—运算—显示—上传。")
bullet("以“真机五判据”而非“仿真全绿”作为签核标准：Z 频率、计数跨度、转速、UVW 六态、长跑丢帧逐条量化。")

h2("设计流程")
body("需求分解 → 算法建模（Python 定点黄金模型）→ RTL 实现 → 位精确仿真（54 台，含跨半量程、反向、坏样本定向台）→ 综合与实现签核（WNS/WHS/DRC/资源）→ 上板联调（信号源、转台、UDP、触摸屏）→ 缺陷定位（A/B 位流 bisect、探针位流、ModelSim 定向复现）→ 回归与证据归档。每一步的输入、输出与判据都落到文件与 SHA-256，形成可重跑的证据链；换一台机器，按文档命令即可复现同一组数字。")

# ---------------- 第二部分 ----------------
part_heading("第二部分  系统组成及功能说明")

h2("整体介绍", "2.1")
body("系统由 SMR 传感头、模拟前端、AD9238 双通道 ADC、FPGA 与输出接口五部分组成（图 1）。传感头输出两路正交 sin/cos，经差分转单端与增益调整送入 AD9238；FPGA 用 ODDR 把 50 MHz 时钟转发给 ADC，数据在同一时钟域内捕获，因此不存在异步 FIFO 与跨时钟握手。采集样本依次经过 ÷4 抽取、六参数校正、17 级 CORDIC、检测-保持与 Ⅱ 型 PI，得到 32 位 {多圈计数, 16 位角}；该角度同时送往 ABZ、UVW 两路输出与 UDP/UI 遥测。全链路只有一级时钟域、一条数据通路，任一环节的延迟都可由 RTL 头注释与流水表核对。")
picture(os.path.join("deliverables", "figures", "fig1_system_architecture.png"), 16.4,
        "图 1  系统框图。（a）传感前端；（b）单时钟域 FPGA 流水线与 41.5 拍延迟预算；（c）多协议输出。图内数字取自 v74 生产位流与真机记录。")

body("需要特别说明的是时钟方案：整片设计不例化 MMCM/PLL，ADC 时钟由 ODDR 从 50 MHz 系统时钟转发，D1/D2 相位在 v10 相位判别实验中确定为同相，使 ADC 数据在 2–6 ns 内有效、捕获裕量 14–18 ns。这样做的代价是采样率上限受 50 MHz 限制，收益是零 CDC、零 IP 依赖、延迟完全确定——对编码器这类“低带宽、强实时”对象，确定性比峰值频率更重要。")

h2("硬件系统介绍", "2.2")
h3("2.2.1 硬件整体介绍")
body("硬件以正点原子达芬奇-lite 开发板（XC7A35TFGG484-2）为核心，外接 HSEDA AD9238 双通道 12 bit、65 MSPS 模块与 7 英寸 1024×600 RGB 触摸屏；板上千兆 PHY 提供 UDP 通道，USB-UART 提供 2 Mbaud 寄存器通道。主要器件与接口如表 2。")
make_table(
    ["部件", "型号 / 规格", "作用"],
    [
        ["FPGA", "XC7A35TFGG484-2（20,800 LUT）", "采集、校正、解算、协议与 UI 的唯一计算单元"],
        ["ADC 模块", "AD9238BSTZ-65，双 12 bit，65 MSPS", "正交 sin/cos 同步采样，偏移二进制输出"],
        ["系统时钟", "50 MHz 有源晶振 → BUFG", "全芯片唯一时钟，ODDR 转发给 ADC"],
        ["显示", "7 in 1024×600 RGB565 + 电容触摸", "五页诊断界面，无帧缓冲直写"],
        ["网络", "千兆 PHY + RJ45", "UDP 抓包与连续流，28,672 点/帧"],
        ["串口", "USB-UART，2 Mbaud", "寄存器读写、标定、日志"],
        ["调试", "JTAG", "ILA、位流下载与探针实验"],
    ],
    [3.2, 6.6, 4.8],
    cap="表 2  主要硬件组成",
)
body("模拟前端把传感头每腿约 0.5 Vpp 的差分信号转换为单端 8 Vpp，偏置到 AD9238 的中间码（offset binary 的 2048），并做 RC 抗混叠与 ESD 保护。差分转单端级采用低噪声运放、独立模拟地与星形接地点，避免数字回流穿过小信号地。传感头与磁环之间加接地屏蔽片，抑制电机 PWM 共模干扰。")

h3("2.2.2 机械设计介绍")
body("机械部分的核心是“磁环—传感头”的同轴度与气隙稳定性（图 2）。磁环通过轴套与转台主轴刚性连接，端面跳动由轴套止口保证；传感头固定在非磁性支架上，径向气隙由非磁性垫片设定，装配后不再调整；传感头与磁环之间插入接地屏蔽片，线缆用扎带做应力释放，防止转台振动把力传到焊点。装配顺序为：先装轴套与磁环并测端面跳动，再装传感头支架与垫片，最后接屏蔽片与线缆。")
picture(os.path.join("deliverables", "figures", "fig_mech.png"), 13.6,
        "图 2  磁环—传感头机械装配示意（非比例图；实物照片见随作品提交的全貌图与开发板照片）")
body("由于磁环是 2048 周期/转的细磁极环，安装偏心会直接转化为一次谐波误差，因此同轴度优先于气隙绝对大小：气隙在传感头线性区内即可，偏心必须压到最小。装配完成后用示波器看正交波形的幅值平衡与相位差，作为机械安装是否合格的快速判据。")

h3("2.2.3 电路各模块介绍")
body("（1）ADC 接口：24 位并行总线（两通道各 12 位）+ 转发时钟 + OTR。数据在 FPGA 内先过两级同步器消元稳，再减 2048 转补码；输入约束按数据手册 tPD=2–6 ns 诚实建模（约束取 ≤4 ns），因此综合报告中的输入端口负余量是设计选择，不是虚假违例。")
body("（2）模拟前端：差分转单端、增益、偏置、抗混叠四级。增益把 0.5 Vpp/腿放大到 8 Vpp 差分满量程，偏置网络把零差分映射到中间码；RC 截止频率高于信号带宽 5 倍以上，避免引入额外相移。")
body("（3）时钟与复位：单一 50 MHz 经 BUFG 分发；复位为低有效异步复位、同步释放，保证各模块在同一拍退出复位。")
body("（4）显示、网络与串口：RGB565 直写屏，无帧缓冲；UDP 协议栈用 RTL 实现（ARP/ICMP/UDP），抓包 28,672 点/帧；UART 经寄存器桥访问全部配置与观测量。")
body("（5）电源与接地：模拟 3.3 V 与数字 3.3 V 分开、单点汇合；ADC 时钟走线包地，数据总线串 22 Ω 匹配，减少过冲与串扰。")

h2("软件系统介绍", "2.3")
h3("2.3.1 软件整体介绍")
body("软件分为三层：RTL 层（25 个顶层模块 + 8 个以太网模块）、板级诊断层（触摸 UI 五页）、上位机层（Python 工具集）。RTL 层按“采集—校正—解算—跟踪—输出”五段流水组织，所有模块共享 50 MHz 时钟与 valid 握手；寄存器文件把 UART/SPI 访问映射为统一地址空间，配置与观测量同表，换版本只需核对 BUILD_ID。上位机层提供 link.py（寄存器读写）、check_v70.py（五判据一键检查）、diag_pos3.py（位置/转速长跑）、soak_v68.py（60 s 丢帧统计）、calib_v68.py（标定）、angle_vs_sc.py（角度一致性分箱），全部脚本可重跑。")
body("RTL 与文档之间用 BUILD_ID 绑定：v74 生产位流的 BUILD_ID 为 0x0018，由 tools/make_v74_rtl.py 从仓库 rtl/（0x0015）派生，与综合源仅差 RTL_BUILD_ID 一行；任何“源码与位流不是同一版”的情况都会被签核脚本拦下。")

h3("2.3.2 软件各模块介绍")
make_table(
    ["模块", "功能", "关键实现 / 延迟"],
    [
        ["ad9238_capture", "双通道同步捕获、去元稳、偏移二进制转补码", "3 拍；ODDR 转发时钟"],
        ["decim_avg", "÷4 滑动平均，白噪声下换 1 bit ENOB", "2 拍 + 1.5 样本群延迟"],
        ["sc_correct", "六参数校正：偏置、增益、正交、残余位移", "3 拍；闭式矩解，无 LUT"],
        ["cordic_atan2", "向量模式 17 级全流水，16 位角", "19 拍；1 角/拍"],
        ["glitch_guard", "角度域检测-保持，抑制坏样本再注入", "1024 LSB 阈值"],
        ["loop_filter", "Ⅱ 型 PI，kp/ki 可配，45° 滞后告警", "3 拍；Jury 稳定域复核"],
        ["pole_counter", "无符号差分零扩展、增量展开、多圈计数", "跨 32768 不再翻转"],
        ["abz_gen", "2–256× 细分、A/B/Z 输出、Z 脉宽可配", "≤3 拍"],
        ["uvw_gen", "六步换相、正反向对称宽基分支、虚拟 Z", "0/5 扇区对称"],
        ["reg_file", "UART→SPI 桥、统一寄存器地图、BUILD_ID", "2 Mbaud"],
        ["ui_top", "五页 1024×600 触摸界面，直写无帧缓冲", "与生产逻辑二选一"],
        ["eth_top", "ARP/ICMP/UDP，28,672 点/帧抓包与连续流", "1 GbE"],
        ["host/*.py", "标定、抓包、长跑、分箱、签核", "可重跑，输出 CSV/PNG"],
    ],
    [3.0, 7.0, 4.6],
    cap="表 3  主要软件模块",
)
body("六参数校正的数学核心是把理想圆经仿射畸变后的椭圆，用一阶矩定中心、二阶矩定轴长与旋转角，再一次映射回圆；相比极值法，矩法不受单个野值与非整数周期影响，且一次解算即精确。CORDIC 采用象限折叠 + 17 级迭代 + 输出寄存，角度累加器 20 位，保证 16 位输出无截断抖动。PI 环路的稳定域用 Jury 判据复核：按“本拍更新后的积分值”实现时，kp=0…7、ki=1…3 全部稳定；若照抄手册档位而用旧积分值，会出现 Ki>Kp 的发散区，这一点已在 RTL 头注释中写明推导。")
body("多圈计数是 v70 的关键修复点：原实现把 0…65535 的无符号相位按补码做符号扩展再相减，跨 32768 时 +133 被算成 −65,403，累加器每半圈被扣掉 65,536，净计数恒为 0；修复后用 “diff_u = ang_s0 - ang_s1” 取无符号差，再零扩展为 18 位有符号增量，累加器按增量展开。UVW 的修复同理：反向 0/5 扇区在 r_sec==0 时以 0 为基准，角度绕回 65535 侧后恒负，导致反向只剩三个扇区；新增 “bwd_wide” 分支，把 65536−eang 作为宽基偏移，与前向 “eang < 10923” 的特判同构。两处修复合计只增加 39 个 LUT。")

# ---------------- 第三部分 ----------------
part_heading("第三部分  完成情况及性能参数")

h2("整体介绍", "3.1")
body("作品已完成 RTL、仿真、综合实现、上板联调与真机闭环五级验证。电学测试用 AFG-2225 双通道信号源产生 8 Vpp、90° 相移正交信号，覆盖 1 kHz–500 kHz；系统测试用真实转台（2048 周期/转、25.27 kHz 正交输出）带动磁环，板上通过 UART 读取寄存器、通过 1 GbE 抓取原始波形，示波器监测 ABZ/UVW 引脚。v74 生产位流于 2026-11-02 完成上板验收；显示位流同日重建并完成构建签核（WNS +0.422 ns、34,499 端点全过、0 DRC Error），屏侧目视证据仍取自 v62 演示位流。")

h2("工程成果", "3.2")
h3("3.2.1 机械成果")
body("完成磁环—传感头—转台的同轴装配与屏蔽：轴套止口定心、非磁性垫片定气隙、接地屏蔽片抑制共模干扰、线缆应力释放。装配后用正交波形幅值平衡与相位差做快速判据，再以整圈计数是否走满 2048 个电周期确认机械偏心未引入丢拍。实物照片见随作品提交的《作品全貌图》与《开发板重要角度照片》，本文档不重复粘贴以免压缩失真。")

h3("3.2.2 电路成果")
body("完成 ADC 接口、模拟前端、时钟复位、显示/网络/串口五部分的原理与 PCB 实现，并在 v74 位流上完成资源与时序签核（表 4）。生产位流 10,926 LUT、8,697 FF、32/50 BRAM、17 DSP，WNS +0.409 ns、WHS +0.025 ns、0 失败端点、DRC 0 Error；显示位流 17,604 LUT、11,946 FF、48/50 BRAM、22 DSP，WNS +0.422 ns、0 失败端点（34,499）。")
make_table(
    ["项目", "v74 生产位流（已上板）", "v74 显示位流（构建签核）"],
    [
        ["LUT", "10,926（52.53%）", "17,604（84.63%）"],
        ["FF", "8,697（20.91%）", "11,946（28.72%）"],
        ["BRAM", "32 / 50", "48 / 50"],
        ["DSP", "17", "22"],
        ["WNS / WHS", "+0.409 / +0.025 ns", "+0.422 / +0.024 ns"],
        ["失败端点", "0（24,625）", "0（34,499）"],
        ["位流", "1,512,664 B，SHA E4634907…DA2680", "1,700,821 B，SHA 72FF4D13…49C395"],
        ["状态", "真机五判据通过", "构建签核，未目视验收"],
    ],
    [3.2, 6.4, 5.0],
    cap="表 4  v74 资源与时序签核（2026-11-02）",
)

h3("3.2.3 软件成果")
body("触摸屏提供总览、输入波形、逻辑时序、设置、标定五页，零帧缓冲直写，不接上位机即可看数、看波、改参数、查故障。图 3 为总览页实物：MAIN 区显示输入频率与倍率，SPEED 区显示 RPM 与电频率，ABZANGLE 区显示角度与转向，REV 区显示 Z 计数，ABZ/UVW 区显示六路电平。图 4 为设置页：INTER、DIV、PAIRS、RESLIM、Z 宽度/相位、UVW 相位与极性均可在线修改。")
two_pictures(os.path.join("deliverables", "figures", "ui_p1.png"),
             os.path.join("deliverables", "figures", "ui_settings.png"), 6.6,
             "图 3  触摸屏总览页（左）与设置页（右）实物，随 v62 演示位流上板")
body("上位机侧提供 UDP 抓包与连续流：一次抓包 28,672 点原始波形，用于看李萨如、算幅值/相位/THD；连续流模式在 60 s 内收到 598,115 帧、9,968 fps，半径均值漂移小于 0.02%。图 5 为上位机抓包界面。")
picture(os.path.join("deliverables", "figures", "host_capture_ethernet.png"), 13.2,
        "图 5  上位机 UDP 抓包界面：原始 sin/cos、李萨如与统计量")

h2("特性成果", "3.3")
h3("3.3.1 静态校正与角度一致性")
body("在信号源 90° 正交输入下完成六参数标定：gain_s=33,776、gain_c=33,568、shift=0、amp_sq=53,514、lock=0x0301。校正前李萨如呈明显椭圆并带偏置，校正后回到单位圆；全周分箱的角度一致性残差落在 −0.13°…+0.13°，谐波分解为 h1≈0.050°、h2≈0.026°、h3≈0.006°、h4≈0.093°，四次谐波是当前最大残余项，下一步将针对四次谐波做补偿。")
picture(os.path.join("deliverables", "figures", "fig_calibration.png"), 14.6,
        "图 6  六参数标定前后的样本云与半径分布（各约 4.98 万点；圆度 CV 17.79% → 0.10%）")
picture(os.path.join("deliverables", "figures", "fig_residual.png"), 14.6,
        "图 7  电角度残差与谐波分解（16 个 22.5° 分箱；四次谐波 0.093° 为当前最大残余项）")

h3("3.3.2 动态闭环与多协议输出")
body("v74 生产位流在真实转台上通过五条判据（表 5）：转速 719–731 rpm 与输入 25.27 kHz 一致；Z 稳定在 12.00 Hz；多圈计数在一圈内跨 −2047…0、distinct=2048，恰好 2048 个电周期，无丢拍/多拍；UVW 六态均匀、293 次换向/s；60 s 长跑 598,115 帧、9,968 fps、r 漂移 <0.02%。ABZ/UVW 的原始遥测图保存在证据包（deliverables/data/v70）中：A/B 正交、Z 每转一个、UVW 六态按序切换。")
make_table(
    ["判据", "结果", "结论"],
    [
        ["机械转速与输入频率一致", "719.0 / 731.3 rpm（25.27 kHz ⇒ 740 rpm 标称）", "通过，差为转台自身波动"],
        ["Z 每转 1 个", "Z = 12.00 Hz", "通过"],
        ["多圈计数一圈走满", "cnt 跨度 −2047…0，distinct=2048", "通过，无丢拍"],
        ["UVW 六态均匀", "293 次换向/s，六态各约 5,000 点", "通过"],
        ["60 s 连续流", "598,115 帧，9,968 fps，r 漂移 <0.02%", "通过"],
    ],
    [4.4, 6.4, 3.8],
    cap="表 5  v74 真机五判据（2026-11-01 转台）",
)

body("ABZ 的 2–256× 细分与 Z 门控可在线配置；滤波后 ABZ 抖动小于 0.92°，坏样本经角度域检测-保持后再注入被压低约 8 倍。")

h3("3.3.3 与商用细分器的定位对比")
make_table(
    ["项目", "iC-TW28（公开资料）", "iC-TW29（公开资料）", "本作品"],
    [
        ["细分辨率", "10 bit", "10 bit", "16 bit"],
        ["ABZ / UVW", "有 / 有", "有 / 有", "2–256× / 六步 + 虚拟 Z"],
        ["校正", "片内", "片内", "六参数闭式 + 可选全周表"],
        ["诊断", "SPI", "SPI", "触摸 UI + 1 GbE + ILA"],
        ["实现", "专用 ASIC", "专用 ASIC", "单片 FPGA，算法可演进"],
    ],
    [3.0, 3.7, 3.7, 4.2],
    cap="表 6  定位对比（商用器件按公开资料口径，仅作定位参考，非实测对比）",
)
body("与专用 ASIC 相比，本作品的优势不是单颗成本，而是“可演进 + 可审计 + 多协议并行输出”：校正算法、滤波系数、输出协议都能在线改，寄存器地图与校准结果可回读，研发阶段不必为一次算法改动重新流片。")

h3("3.3.4 可复现性与证据链")
body("仓库以 MIT 许可开放 RTL、约束、仿真台、上位机与文档；294 件证据、299 条 SHA-256 覆盖到每个位流、报告与图；54 个仿真台覆盖采集、校正、CORDIC、PI、计数、UVW、UI、以太网；“tools/final_verify.ps1” 一条命令检查源码与签核位流的文本一致性、时序、位流 SHA、文档齐套。报告与本文档中的每个数字都能追到对应文件、日志或位流。")

h3("3.3.5 技能包与通用 PYNQ 子包")
body("skill/ 目录随作品提交一套可复用技能包：7 篇方法长文（定点黄金模型、位宽安全、测试台盲区、源同步约束、确定性测量、报告自动采集、可复现性）加 19 项可直接复制执行的四类资产——校验脚本 6 个（实现报告判决、黄金 vs 仿真逐点比对、SHA-256 清单、空转测试台体检、两套自检、一条命令总门禁）、案例模板 7 个、提示词工作流 5 篇、结构化踩坑清单 1 份（18 条，逐条含触发/现象/排查命令/根因/修法/回归验证/失效条件/来源记录号）。每一项都写明适用场景、使用方法、验证到的效果与失效条件；夹具取自本工程真实数值（v74 报告 +0.409 ns / LUT 52.53%，另有 −0.123 ns / 7 个失败端点的失败回放）。")
body("这套资产自己也被检验：两套自检 24/24 与 18/18（其中 15 条是“必须失败”的负对照），仓库门禁 7 项（链接、命名、记录号可追、文档数字与现场一致、症状索引与清单一致）一条命令给总判决。另附独立于本题的通用 PYNQ 子包（按指南 3.3.2 申报）：只读 .hwh 与文件时间戳，做地址表解析、交付目录位流/地址表配对检查与上板 5 条判据，夹具是 Vivado 2026.1 在 XC7A35T 上真实导出的 handoff。夹具与判据都可复现：同一份真实 handoff 补地址后 PASS、地址重叠 FAIL、缺 `.hwh` FAIL。")

# ---------------- 第四部分 ----------------
part_heading("第四部分  总结")

h2("可扩展之处", "4.1")
body("（1）谐波误差补偿：当前最大残余项是四次谐波（约 0.093°），二次谐波约 0.026°，可在校正后加谐波查表或多项式；（2）100 MHz 时钟 + CORDIC 展开：把 19 拍压到 5–10 拍，总延迟进入 550 ns 以内；（3）原始域 3 点中值：在 ADC 坏样本进入校正前抑制，代价 2 拍延迟与少量比较器；（4）多轴参数化例化：单轴约 30% LUT，多轴共用时钟天然同步，适合多关节一体控制；（5）产品化：RS-422 差分输出、EMC 整改、真实 Z 输入与外部高精度基准比对。")

h2("心得体会", "4.2")
body("这个项目最大的教训是：仿真全绿不等于正确。我们的 33 台主回归在 v69 上全部通过，但真机 10 秒就暴露 cycle_cnt 恒 0——因为所有激励都在小角度内来回，从未跨过 32768 这个半量程边界。符号扩展错误在数学上很“显眼”，在波形上却完全静默：它只在跨边界那一步发生，之后累加器又被拉回 0，看上去像“传感器没转”。这让我们把“边界跨越激励”写进了技能包：整圈、跨 0、跨 2^(N−1)、跨 2^N−1，至少一条反向，断言要盯住跨边界那几步的增量本身，而不是只看最终角度。")
body("第二个教训是定位方法比聪明更重要。两个死锁的现象完全不同——一个是计数恒 0，一个是反向少三个扇区——但我们用同一套四步法解决：先在真机上同时读四个观测量，确认“同死”而不是“某一路坏”；再用 A/B 位流 bisect，把 v68 换回去看是否复现，排除“转台/接线”这类环境变量；然后做探针位流，把内部信号引到寄存器，把“10 秒无声”缩成“一个样点的 step=−65,403”；最后用 ModelSim 定向台复现同一行，改一行、跑 3,000 个 +133 步，看计数从 0 变 6 再变 12。每一步都只回答一个问题，不跳步。")
body("第三个体会是“可观测性”要设计。调试初期我们只能看最终角度，信息量太低；后来把 “step_s”、“wrap_p_raw”、“pair_valid” 引到寄存器，才看清是符号扩展而不是 PPR 配置。工程上，探针位流和 ILA 不是“调试外挂”，而是设计的一部分——它们决定了你能不能在一次上板里拿到足够证据。")
body("第四个体会是取舍。单时钟域、无 MMCM 让延迟确定、CDC 为零，代价是采样率上限 50 MHz；我们选择确定性，因为编码器的价值在“延迟可预算、接口可同步”，而不在峰值采样率。类似地，六参数闭式校正放弃了对极端畸变的拟合能力，换来的是一次解算、可审计、无查找表。每个取舍都写进了报告的风险表，而不是藏起来。")
body("最后是协作方式。大模型在这个项目里最有用的角色不是“写代码”，而是“被迫证伪”：每次我们提出一个假设（PPR 配错、迟滞太小、位域截断），它都被要求先设计一个能推翻该假设的实验，再谈修复。两次误判都是这样被推翻的。协作记录、技能包与证据链一起，构成了这个作品可被复现、可被质疑、也可被后来者直接使用的基础。")

# ---------------- 第五部分 ----------------
part_heading("第五部分  参考文献")
refs = [
    "Analog Devices. AD9238: Dual, 12-Bit, 20/40/65 MSPS, 3 V A/D Converter Datasheet[Z]. 2013.",
    "AMD/Xilinx. 7 Series FPGAs Data Sheet: Overview (DS180)[Z]. 2023.",
    "AMD/Xilinx. Vivado Design Suite User Guide: Synthesis (UG901)[Z]. 2024.",
    "AMD/Xilinx. Vivado Design Suite User Guide: Using Constraints (UG903)[Z]. 2024.",
    "Volder J E. The CORDIC Trigonometric Computing Technique[J]. IRE Transactions on Electronic Computers, 1959, EC-8(3): 330-334.",
    "iC-Haus. iC-TW28: 10-Bit Sin/Cos Interpolator Datasheet[Z]. 2021.",
    "IEEE. IEEE Standard for Ethernet: 802.3-2022[S]. 2022.",
    "Python Software Foundation. Python 3 Language Reference[Z]. 2025.",
]
for i, ref in enumerate(refs, 1):
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.JUSTIFY, indent_chars=0, size=10.5, after=2)
    p.paragraph_format.left_indent = Cm(0.95)
    p.paragraph_format.first_line_indent = Cm(-0.95)
    r = p.add_run("[%d] " % i)
    set_run(r, size=10.5, color=NAVY, bold=True)
    r = p.add_run(ref)
    set_run(r, size=10.5, east=SONG)

out = os.path.join("deliverables", "technical_doc.docx")
doc.save(out)
print("saved", out, os.path.getsize(out))
