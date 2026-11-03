# -*- coding: utf-8 -*-
"""Fill deliverables/design_report.docx into the official competition template.

The document is built *on* deliverables/template/design_report_template.docx: the
template supplies the page size, 1.25 in side margins, 1 in top/bottom margins, the
1.5 line spacing, the empty header/footer and the heading styles.  This script only
replaces the instruction paragraphs with the real content, so the printed result keeps
the template's format.  Body text is Song / Times New Roman 12 pt, part headings
14 pt bold, figures and tables numbered sequentially.  No school / advisor / team
identity anywhere.
"""
import os
from pathlib import Path

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

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "deliverables" / "template" / "design_report_template.docx"

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
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=14, before=16, after=6, keep=True)
    head, _, tail = text.partition("  ")
    if tail:
        r = p.add_run(head + "  ")
        set_run(r, size=14, bold=True, east=SONG)
        r = p.add_run(tail)
        set_run(r, size=12, bold=True, east=SONG)
        return p
    r = p.add_run(text)
    set_run(r, size=14, bold=True, east=SONG)
    # bottom rule
    return p


def h2(text, num=None, size=12):
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=size, before=10, after=4, keep=True)
    r = p.add_run((num + " " if num else "") + text)
    set_run(r, size=size, bold=True, east=SONG)
    return p


def h3(text):
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=12, before=6, after=2, keep=True)
    r = p.add_run(text)
    set_run(r, size=12, bold=True, east=SONG)
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
    set_run(r, size=CAP_PT, east=SONG)
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


def cell_margins(table, top=30, bottom=30, left=80, right=80):
    tblPr = table._tbl.tblPr
    mar = OxmlElement("w:tblCellMar")
    for name, val in (("top", top), ("left", left), ("bottom", bottom), ("right", right)):
        el = OxmlElement("w:" + name)
        el.set(qn("w:w"), str(val))
        el.set(qn("w:type"), "dxa")
        mar.append(el)
    tblPr.append(mar)


def table_borders(table, color="000000"):
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


def make_table(headers, rows, widths, cap=None, align_center=True, header_fill="D9D9D9"):
    if cap:
        p = doc.add_paragraph()
        fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=CAP_PT, before=8, after=2, keep=True)
        r = p.add_run(cap)
        set_run(r, size=CAP_PT)
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
        set_run(r, size=10.5, bold=True, east=SONG)
    for ridx, row in enumerate(rows):
        cells = t.add_row().cells
        for i, val in enumerate(row):
            c = cells[i]
            c.width = Cm(widths[i])
            if ridx % 2 == 1:
                shade(c, "F2F5F9")
            p = c.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if (align_center and i > 0) else WD_ALIGN_PARAGRAPH.LEFT
            p.paragraph_format.space_before = Pt(1)
            p.paragraph_format.space_after = Pt(1)
            p.paragraph_format.line_spacing = 1.1
            r = p.add_run(str(val))
            set_run(r, size=9.5, bold=False, east=SONG)
    for row in t.rows:
        trPr = row._tr.get_or_add_trPr()
        cant = OxmlElement("w:cantSplit")
        trPr.append(cant)
    if len(rows) <= 8:
        for row in t.rows[:-1]:
            for c in row.cells:
                for p in c.paragraphs:
                    p.paragraph_format.keep_with_next = True
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
if not TEMPLATE.is_file():
    raise SystemExit("missing template: %s" % TEMPLATE)

doc = Document(str(TEMPLATE))
_body = doc.element.body
for _child in list(_body):
    if _child.tag != qn("w:sectPr"):
        _body.remove(_child)

# the template already defines page size, margins, 1.5 spacing and an empty
# header/footer; only the body font is pinned explicitly so Chinese text renders
# in Song on every machine
normal = doc.styles["Normal"]
normal.font.name = TNR
normal.font.size = Pt(BODY_PT)
normal.element.rPr.rFonts.set(qn("w:eastAsia"), SONG)
sec = doc.sections[0]

# ---------------- 作品名称 ----------------
p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=18, before=0, after=0, keep=True)
r = p.add_run("作品名称")
set_run(r, size=18, bold=True, east=SONG)

p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=20, before=2, after=4, line=1.5)
r = p.add_run("基于 FPGA 的 SMR 高精度细分磁编码器")
set_run(r, size=20, bold=True, east=SONG)

p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.CENTER, indent_chars=0, size=12, after=12)
r = p.add_run("单芯片 16 位细分 · ABZ/UVW/1 GbE/UART-SPI 多协议输出 · 板载触摸诊断")
set_run(r, size=12, east=SONG)

# ---------------- 摘要 ----------------
h2("摘要", size=14)
body("本作品面向伺服驱动、机床转台与机器人关节对高分辨、抗污染位置反馈的需求，设计了一款基于 SMR 磁阻传感器与 FPGA 的高精度细分磁编码器。系统以 XC7A35TFGG484-2 为唯一计算单元，在 50 MHz 单时钟域内完成双通道 12 bit 同步采样、÷4 抽取、六参数闭式误差校正、17 级全流水 CORDIC 解算、Ⅱ 型 PI 跟踪与增量展开，输出 16 位角度与 ABZ、UVW、1 GbE UDP、UART/SPI 多协议接口，并集成 1024×600 触摸诊断界面，全链路延迟 41.5 拍、约 830 ns（设计预算）。六参数校正由一阶/二阶矩一次解算，无查找表、不依赖上位机迭代；正反向 UVW 采用对称宽基分支，消除 0/5 扇区回绕吞并；多圈计数以无符号差分零扩展累加，消除跨半量程死锁。v90 生产位流已在真实转台闭环（2026-11-04）：Z 7.62/7.65 Hz ⇒ 457–459 rpm，每转恰好 1 个 Z，停位无喘振；UVW 六态计数均衡；60 s 遥测连续上传 597,886 帧（9,964.8 fps）；板级角度一致性 offset 1.76°、RMS 0.71°、max 2.88°。资源 10,978 LUT（52.78%）、8,724 FF、32/50 BRAM、17 DSP，WNS +0.199 ns、0 失败端点。作品以“建模—位精确仿真—构建签核—真机判据”的证据链交付，配套 57 个仿真台、320 件可追溯证据（323 条 SHA-256）与一条命令签核。")
p = doc.add_paragraph()
fmt_par(p, align=WD_ALIGN_PARAGRAPH.LEFT, indent_chars=0, size=12, before=6, after=8)
r = p.add_run("关键词：")
set_run(r, size=12, bold=True, east=SONG)
r = p.add_run("磁编码器；SMR 磁阻传感；CORDIC；FPGA")
set_run(r, size=12)

# ---------------- 第一部分 ----------------
part_heading("第一部分  作品概述")

body("光学编码器在粉尘、油污与振动下会因码盘污染、光源衰减而失效；磁编码器鲁棒，但原始正交桥输出并不理想——偏置、增益失配、正交相位误差与残余位移全部叠进角度。同类专用细分器件把算法与接口一起封死：低阶型号只到 10 bit，高阶方案虽补上位置接口，但多圈仍需第二颗芯片，校准配方不透明、算法无法按现场误差演进。本作品用一片 Artix-7 同时完成采集、六参数校正、16 位角度解算与四类输出，把“专用芯片 + 第二颗多圈芯片 + 黑盒校准”收敛为“单 FPGA + 可回读参数 + 可演进算法”。")


h2("功能与特性")
body("作品在一块 FPGA 上同时完成传感采集、误差校正、角度解算、多协议输出与人机诊断，上电即独立工作，不依赖上位机。（1）双通道 12 bit、65 MSPS 同步采集 SMR 正交信号，片内 ÷4 抽取与数字滤波；（2）偏置、增益、正交相位与残余位移六参数闭式校正，支持上电自标定与一键标定；（3）17 级全流水 CORDIC 解算 16 位绝对角，Ⅱ 型 PI 跟踪抑制抖动，增量展开保证跨 0/2π 连续；（4）ABZ 增量（2–256× 可配）、UVW 六步换相与单 Z 索引、1 GbE UDP 数据流、UART/SPI 寄存器接口；（5）1024×600 触摸屏四页诊断界面，实时显示波形、角度、速度、UVW 扇区与信号质量，标定走 KEY0 长按或串口写 0x0502=0x0001；（6）细分倍数、滤波系数、标定参数与零位在线可改、掉电前可回读核验。")

h2("应用领域")
body("凡需要“高分辨、抗污染、可诊断”角度反馈的场合均适用：伺服电机换相与闭环——UVW、ABZ 两路同片并行输出，省去多芯片拼接；数控机床主轴与精密转台——16 位角、亚微秒延迟，适合高刚性速度环；机器人关节与协作臂——磁阻对油污、粉尘、振动不敏感；汽车电机与转向——宽温、抗 EMI；风电变桨、电梯门机、纺织机械等低速大扭矩场景。与同类专用细分 ASIC（公开资料典型值）相比，本方案把算法、接口与诊断放在同一片 FPGA 内：参数与寄存器地图完全可见、可审计，算法可随现场误差演进，多轴共用时钟因而天然同步。")

h2("主要技术特点")
body("（1）单时钟域：全系统 50 MHz、无 MMCM、无 CDC，延迟确定 41.5 拍；（2）闭式标定：用一阶/二阶矩直接解椭圆→圆映射，一次解算，不用查找表，不做上位机迭代；（3）全流水 CORDIC：17 级、1 角/拍，吞吐与采样率同频；（4）抗回绕：多圈计数用无符号差分零扩展，UVW 正反向各有一条宽基分支，0/5 扇区对称；（5）可诊断：位流内自带触摸 UI、1 GbE 抓包与 ILA，现场不接电脑也能看内部波形；（6）可复现：57 个仿真台、320 件证据、323 条 SHA-256 清单与一条命令签核，任何数字都能追到文件与哈希。")

h2("主要性能指标")
make_table(
    ["指标", "数值", "条件 / 说明"],
    [
        ["角度分辨率", "16 bit/电周期（0.0055° 电角/LSB）", "全周 65,536 码"],
        ["输入信号", "2048 周期/转正交 sin/cos", "SMR 传感头，0.5 Vpp/腿放大到 8 Vpp"],
        ["采样", "2×12 bit @65 MSPS，50 MHz 同步采样", "÷4 平均后 12.5 MSPS 有效样本"],
        ["实测转速", "457–459 rpm", "真实转台，2026-11-04（z_rate.py，每转 1 个 Z）"],
        ["Z 索引", "7.62–7.65 Hz，每转 1 个", "z_index_gen 出 Z 后撤防，离开 ≥1/8 圈重布防"],
        ["角度延迟", "41.5 拍 ≈830 ns", "50 MHz，含 ADC 7 拍估计（设计预算）"],
        ["ABZ 输出", "2–256× 可配；32× 时 65,536 边沿/转", "A/B 正交，Z 门控"],
        ["UVW 输出", "六步换相，约 183 次/s", "458 rpm、4 极对"],
        ["以太网", "28,672 点/帧 @50 MSPS，9,964.8 fps", "1 GbE UDP，60 s 连续 597,886 帧；ping 4/4"],
        ["逻辑资源", "10,978 LUT（52.78%）、8,724 FF（20.97%）、32 BRAM、17 DSP", "v90 生产位流（无 UI、无网）"],
        ["时序", "WNS +0.199 ns / WHS +0.017 ns / 0 失败", "24,691 个端点，DRC 0 Error"],
        ["位流", "1,504,220 B，SHA-256 A89512A5…8F827125", "BUILD 0x0019，2026-11-04 上板验收"],
    ],
    [2.8, 5.6, 6.2],
    cap="表 1  主要性能指标（实测项取自 2026-11-04 转台上板轮次；构建项为 v90 签核值）",
)

h2("主要创新点")
bullet("六参数闭式校正：矩法一次解算，无查找表、无迭代，结果可回读审计。")
bullet("41.5 拍确定性延迟：单时钟域、无 MMCM，速度环无需辨识延迟。")
bullet("无符号差分零扩展 + 正反向对称 UVW：根除两类静默死锁。")
bullet("单 FPGA 并行输出 ABZ、UVW、1 GbE 与触摸 UI。")
bullet("以真机判据（Z 频率与个数、UVW 六态、锁存、角度一致性、长跑）作签核标准。")

h2("设计流程")
body("需求分解 → 算法建模（Python 定点黄金模型）→ RTL 实现 → 位精确仿真（57 台，含跨半量程、反向、坏样本定向台）→ 综合实现签核（资源/时序/DRC）→ 上板联调（信号源、转台、UDP、触摸屏）→ 缺陷定位（A/B 位流 bisect、探针位流）→ 回归归档。每一步的判据都落到文件与 SHA-256，按文档命令可复现同一组数字。")

# ---------------- 第二部分 ----------------
part_heading("第二部分  系统组成及功能说明")

h2("整体介绍", "2.1")
body("系统由 SMR 传感头、模拟前端、AD9238 双通道 ADC、FPGA 与输出接口五部分组成（图 1）。传感头输出两路正交 sin/cos，经差分转单端与增益调整送入 AD9238；FPGA 用 ODDR 把 50 MHz 时钟转发给 ADC，数据在同一时钟域内捕获，因此不存在异步 FIFO 与跨时钟握手。采集样本依次经过 ÷4 抽取、六参数校正、17 级 CORDIC、检测-保持与 Ⅱ 型 PI，得到 32 位 {多圈计数, 16 位角}；该角度同时送往 ABZ、UVW 两路输出与 UDP/UI 遥测。全链路只有一级时钟域、一条数据通路，任一环节的延迟都可由 RTL 头注释与流水表核对。")
picture(os.path.join("deliverables", "figures", "fig1_system_architecture.png"), 16.4,
        "图 1  系统框图。（a）传感前端；（b）单时钟域 FPGA 流水线与 41.5 拍延迟预算；（c）多协议输出。图内数字取自 v90 生产位流与真机记录。")

body("需要特别说明的是时钟方案：整片设计不例化 MMCM/PLL，ADC 时钟由 ODDR 从 50 MHz 系统时钟转发，D1/D2 相位在 v10 相位判别实验中确定为同相，使 ADC 数据在 2–6 ns 内有效、捕获裕量 14–18 ns。这样做的代价是采样率上限受 50 MHz 限制，收益是零 CDC、零 IP 依赖、延迟完全确定——对编码器这类“低带宽、强实时”对象，确定性比峰值频率更重要。")
picture(os.path.join("deliverables", "figures", "fig_pipeline.png"), 16.4,
        "图 2  41.5 拍延迟预算。ADC 内部 7 拍为估计值，其余 34.5 拍为 RTL 流水线；每一段的拍数由寄存器级数决定，总延迟是设计常量而非测量值。")

h2("硬件系统介绍", "2.2")
h3("2.2.1 硬件整体介绍")
body("硬件以正点原子达芬奇-lite 开发板（XC7A35TFGG484-2）为核心，外接 HSEDA AD9238 双通道 12 bit、65 MSPS 模块与 7 英寸 1024×600 RGB 触摸屏；板上千兆 PHY 提供 UDP 通道，USB-UART 提供 2 Mbaud 寄存器通道。主要器件与接口如表 2。")
make_table(
    ["部件", "型号 / 规格", "作用"],
    [
        ["FPGA", "XC7A35TFGG484-2（20,800 LUT）", "采集、校正、解算、协议与 UI 的唯一计算单元"],
        ["ADC 模块", "AD9238BSTZ-65，双 12 bit，65 MSPS", "正交 sin/cos 同步采样，偏移二进制输出"],
        ["系统时钟", "50 MHz 有源晶振 → BUFG", "全芯片唯一时钟，ODDR 转发给 ADC"],
        ["显示", "7 in 1024×600 RGB565 + 电容触摸", "四页诊断界面，无帧缓冲直写"],
        ["网络", "千兆 PHY + RJ45", "UDP 抓包与连续流，28,672 点/帧"],
        ["串口", "USB-UART，2 Mbaud", "寄存器读写、标定、日志"],
        ["调试", "JTAG", "ILA、位流下载与探针实验"],
    ],
    [3.2, 6.6, 4.8],
    cap="表 2  主要硬件组成",
)
body("模拟前端把传感头每腿约 0.5 Vpp 的差分信号转换为单端 8 Vpp，偏置到 AD9238 的中间码（offset binary 的 2048），并做 RC 抗混叠与 ESD 保护。差分转单端级采用低噪声运放、独立模拟地与星形接地点，避免数字回流穿过小信号地。传感头与磁环之间加接地屏蔽片，抑制电机 PWM 共模干扰。")

h3("2.2.2 机械设计介绍")
body("机械部分的核心是“磁环—传感头”的同轴度与气隙稳定性（图 3）。磁环通过轴套与转台主轴刚性连接，端面跳动由轴套止口保证；传感头固定在非磁性支架上，径向气隙由非磁性垫片设定，装配后不再调整；传感头与磁环之间插入接地屏蔽片，线缆用扎带做应力释放，防止转台振动把力传到焊点。装配顺序为：先装轴套与磁环并测端面跳动，再装传感头支架与垫片，最后接屏蔽片与线缆。")
picture(os.path.join("deliverables", "figures", "fig_mech.png"), 13.6,
        "图 3  磁环—传感头机械装配示意（非比例示意；装配实拍见图 5）")
body("由于磁环是 2048 周期/转的细磁极环，安装偏心会直接转化为一次谐波误差，因此同轴度优先于气隙绝对大小：气隙在传感头线性区内即可，偏心必须压到最小。装配完成后用示波器看正交波形的幅值平衡与相位差，作为机械安装是否合格的快速判据。")

h3("2.2.3 电路各模块介绍")
body("（1）ADC 接口：24 位并行总线（两通道各 12 位）+ 转发时钟 + OTR。数据在 FPGA 内先过两级同步器消元稳，再减 2048 转补码；输入约束按数据手册 tPD=2–6 ns 诚实建模（约束取 ≤4 ns），因此综合报告中的输入端口负余量是设计选择，不是虚假违例。")
body("（2）模拟前端：差分转单端、增益、偏置、抗混叠四级。增益把 0.5 Vpp/腿放大到 8 Vpp 差分满量程，偏置网络把零差分映射到中间码；RC 截止频率高于信号带宽 5 倍以上，避免引入额外相移。")
body("（3）时钟与复位：单一 50 MHz 经 BUFG 分发；复位为低有效异步复位、同步释放，保证各模块在同一拍退出复位。")
body("（4）显示、网络与串口：RGB565 直写屏，无帧缓冲；UDP 协议栈用 RTL 实现（ARP/ICMP/UDP），抓包 28,672 点/帧；UART 经寄存器桥访问全部配置与观测量。")
body("（5）电源与接地：模拟 3.3 V 与数字 3.3 V 分开、单点汇合；ADC 时钟走线包地，数据总线串 22 Ω 匹配，减少过冲与串扰。")
make_table(
    ["接口组", "方向（以 FPGA 为基准）", "关键信号线", "电气 / 时序约定"],
    [
        ["正交模拟输入", "输入", "SIN_P/SIN_N、COS_P/COS_N", "差分 0.5 Vpp/腿，90° 相移，DC–700 kHz"],
        ["ADC 数据", "输入", "D1[11:0]、D2[11:0]、OTR、ADC_CLK", "12 bit 偏移二进制，24 位并行，转发时钟 50 MHz"],
        ["显示", "输出", "RGB[15:0]、HS、VS、DE、PCLK", "RGB565，1024×600，像素时钟约 51.2 MHz"],
        ["触摸", "双向", "SDA、SCL、INT", "I²C，100 kHz，裸指与手套两种阈值"],
        ["以太网", "双向", "TXD[3:0]、RXD[3:0]、GTX_CLK、RXC", "RGMII，1 GbE，UDP 28,672 点/帧"],
        ["串口", "双向", "UART_TX、UART_RX", "2 Mbaud，寄存器读写与标定"],
        ["编码器输出", "输出", "A、B、Z、U、V、W", "3.3 V 单端，ABZ 2–256×，UVW 六步 + 单 Z"],
        ["调试", "双向", "TCK、TMS、TDI、TDO", "JTAG，ILA 与探针位流"],
    ],
    [3.0, 3.4, 5.4, 4.9],
    cap="表 4  板级关键接口与信号线（方向以 FPGA 为基准）",
)

h2("软件系统介绍", "2.3")
h3("2.3.1 软件整体介绍")
body("软件分为三层：RTL 层（24 个顶层模块 + 8 个以太网模块）、板级诊断层（触摸 UI 四页）、上位机层（Python 工具集）。RTL 层按“采集—校正—解算—跟踪—输出”五段流水组织，所有模块共享 50 MHz 时钟与 valid 握手；寄存器文件把 UART/SPI 访问映射为统一地址空间，配置与观测量同表，换版本只需核对 BUILD_ID。上位机层提供 link.py（寄存器读写）、check_v70.py（真机判据一键检查，寄存器地图自 v70 未变）、diag_pos3.py（位置/转速长跑）、soak_v68.py（60 s 丢帧统计）、calib_v68.py（标定）、angle_vs_sc.py（角度一致性分箱），全部脚本可重跑。")
body("RTL 与文档之间用 BUILD_ID 绑定：v90 生产位流的 BUILD_ID 为 0x0019；仓库 rtl/ 已是 v90 源，tools/make_v90_rtl.py 只做复制与逐字节校验（不再改写 RTL_BUILD_ID），输出 _synth_work_v90/rtl_v90。任何“源码与位流不是同一版”的情况都会被签核脚本拦下。")
body("三层之间的数据流是单向的：ADC 采样在 rtl/ad9238_capture.v 进入 d1/d2（补码），经 decim_avg 与 sc_correct 变成校正后的 sc_s/sc_c；cordic_atan2 给出 16 位电角度，loop_filter 把角度锁成 32 位 {多圈, 角度} 的 pos；pos 同时驱动 abz_gen、uvw_gen 两路硬件输出与 eth_top 的采样窗。寄存器层（reg_file.v）把这条链上的每个观测量映射到统一地址：上位机读 0x0100 段拿角度与速度、读 0x0200 段拿信号质量与锁存、写 0x0500 段改倍率与滤波。屏 UI（ui_top）读同一份寄存器镜像，因此屏上显示、串口读数与 UDP 抓包三者天然一致，不会出现“屏上一个数、上位机另一个数”。")

h3("2.3.2 软件各模块介绍")
make_table(
    ["模块", "关键输入 → 输出", "实现要点 / 延迟"],
    [
        ["ad9238_capture", "adc_d1[11:0]、adc_d2[11:0]、otr → d1、d2（补码）、valid", "3 拍；ODDR 转发时钟"],
        ["decim_avg", "d1、d2 → s、c（12 bit 有效样本）", "2 拍 + 1.5 样本群延迟"],
        ["sc_correct", "s、c、六参数 → sc_s、sc_c", "3 拍；闭式矩解，无 LUT"],
        ["cordic_atan2", "sc_s、sc_c → angle[15:0]", "19 拍；1 角/拍"],
        ["glitch_guard", "angle → angle_hold、bad_flag", "1024 LSB 阈值，检测-保持"],
        ["loop_filter", "angle、FILT_K → pos[31:0]（多圈 + 16 位角）", "3 拍；Jury 稳定域复核"],
        ["pole_counter", "pos → cycle_cnt、dir", "无符号差分零扩展，跨 32768 不翻转"],
        ["abz_gen", "pos、INTER、div、hyst → A、B、Z", "≤3 拍；限频器可配"],
        ["z_index_gen", "angle、dir → z_arm、z_pulse", "出 Z 撤防，离开 ≥1/8 圈重布防"],
        ["uvw_gen", "eang、UVWPS → U、V、W", "六步换相；0/5 扇区对称"],
        ["reg_file", "uart_rx、addr、wdata → rdata、irq", "UART→SPI 桥，2 Mbaud"],
        ["ui_top", "寄存器镜像、触摸坐标 → RGB[15:0]、HS/VS/DE", "四页直写，无帧缓冲"],
        ["eth_top", "采样窗、控制字 → UDP 帧", "ARP/ICMP/UDP，28,672 点/帧"],
        ["host/*.py", "串口寄存器、UDP 数据报 → CSV / PNG / 判据", "标定、抓包、长跑、分箱、签核"],
    ],
    [3.0, 7.4, 4.2],
    cap="表 3  主要软件模块的关键输入、输出与实现要点",
)
body("六参数校正的数学核心是把理想圆经仿射畸变后的椭圆，用一阶矩定中心、二阶矩定轴长与旋转角，再一次映射回圆；相比极值法，矩法不受单个野值与非整数周期影响，且一次解算即精确。CORDIC 采用象限折叠 + 17 级迭代 + 输出寄存，角度累加器 20 位，保证 16 位输出无截断抖动。PI 环路的稳定域用 Jury 判据复核：按“本拍更新后的积分值”实现时，kp=0…7、ki=1…3 全部稳定；若照抄手册档位而用旧积分值，会出现 Ki>Kp 的发散区，这一点已在 RTL 头注释中写明推导。")
picture(os.path.join("deliverables", "figures", "fig_cordic.png"), 14.6,
        "图 4  CORDIC 收敛。 (a) 输入向量与目标角；(b) 象限折叠后 17 级迭代的残余角，第 14 级已低于 16 位 1 LSB，第 17 级余量约 10×。")

body("多圈计数是 v70 的关键修复点：原实现把 0…65535 的无符号相位按补码做符号扩展再相减，跨 32768 时 +133 被算成 −65,403，累加器每半圈被扣掉 65,536，净计数恒为 0；修复后用 “diff_u = ang_s0 - ang_s1” 取无符号差，再零扩展为 18 位有符号增量，累加器按增量展开。UVW 的修复同理：反向 0/5 扇区在 r_sec==0 时以 0 为基准，角度绕回 65535 侧后恒负，导致反向只剩三个扇区；新增 “bwd_wide” 分支，把 65536−eang 作为宽基偏移，与前向 “eang < 10923” 的特判同构。两处修复未改变流水线结构：净增 10 个 LUT（10,916 → 10,926），WNS 提升约 0.22 ns；v90 再叠加 z_index_gen 后为 10,978 LUT、WNS +0.199 ns。")

# ---------------- 第三部分 ----------------
part_heading("第三部分  完成情况及性能参数")

h2("整体介绍", "3.1")
body("作品已完成 RTL、仿真、综合实现、上板联调与真机闭环五级验证。电学测试用 AFG-2225 双通道信号源产生 8 Vpp、90° 相移正交信号，覆盖 1 kHz–500 kHz；系统测试用真实转台（每转 1 个 Z 索引、2048 周期/转正交输出）带动磁环，板上通过 UART 读取寄存器、通过 1 GbE 抓取原始波形，示波器监测 ABZ/UVW 引脚。v90 生产位流于 2026-11-04 完成上板验收：Z 7.62/7.65 Hz ⇒ 457–459 rpm，UVW 六态计数 {5174, 4761, 4423, 4776, 4763, 4786}，lock=0x0301，r 峰 0.845–0.850 FS，60 s 597,886 帧（9,964.8 fps）。显示位流同日完成构建签核（LUT 17,090 / 82.16%、WNS +0.221 ns、33,365 端点全过、0 DRC Error）并写入 Flash、冷启动通过；屏侧四页已按 v90 显示位流逐页核对（§3.2.3、图 7）。")

picture(os.path.join("deliverables", "figures", "photo_overview.jpg"), 16.4,
        "图 5  系统全貌实拍（2026-11-03）。转台夹具（电机 + 弹性联轴器 + SMR 传感头）、模拟前端与驱动板、AD9238 扩展板叠插的达芬奇-lite 板（XC7A35TFGG484-2）、7 英寸触摸屏与上位机同框（屏上瞬时读数取自演示当天，不作为 v90 转速判据，v90 转速见表 7）。")

h2("工程成果", "3.2")
h3("3.2.1 机械成果")
body("完成磁环—传感头—转台的同轴装配与屏蔽：轴套止口定心、非磁性垫片定气隙、接地屏蔽片抑制共模干扰、线缆应力释放。装配后用正交波形幅值平衡与相位差做快速判据，再以整圈计数是否走满 2048 个电周期确认机械偏心未引入丢拍。机械装配在系统全貌中的位置见图 5，磁环—传感头的相对关系见 2.2.2 节图 3。")

h3("3.2.2 电路成果")
body("完成 ADC 接口、模拟前端、时钟复位、显示/网络/串口五部分的原理与 PCB 实现，并在 v90 位流上完成资源与时序签核（表 5）。生产位流 10,978 LUT、8,724 FF、32/50 BRAM、17 DSP，WNS +0.199 ns、WHS +0.017 ns、0 失败端点、DRC 0 Error；显示位流 17,090 LUT、11,601 FF、45.5/50 BRAM、20 DSP，WNS +0.221 ns、0 失败端点（33,365）。")
make_table(
    ["项目", "v90 生产位流（已上板）", "v90 显示位流（已写 Flash）"],
    [
        ["LUT", "10,978（52.78%）", "17,090（82.16%）"],
        ["FF", "8,724（20.97%）", "11,601（27.89%）"],
        ["BRAM", "32 / 50", "45.5 / 50"],
        ["DSP", "17", "20"],
        ["WNS / WHS", "+0.199 / +0.017 ns", "+0.221 / +0.049 ns"],
        ["失败端点", "0（24,691）", "0（33,365）"],
        ["位流", "1,504,220 B，SHA A89512A5…8F827125", "1,688,245 B，SHA 69FE313C…5F81BAD4"],
        ["状态", "真机判据通过", "构建签核 + 冷启动通过 + 四页逐页核对通过"],
    ],
    [3.2, 6.4, 5.0],
    cap="表 5  v90 资源与时序签核（2026-11-04）",
)
two_pictures(os.path.join("deliverables", "figures", "photo_adc_frontend.jpg"),
             os.path.join("deliverables", "figures", "photo_board_front.jpg"), 7.0,
             "图 6  电路实物。左：AD9238 双通道 12 bit 扩展板（SMA CH1/CH2、差分放大、2.0 V 基准，叠插在 J6 上）；右：FPGA 板正面（RGB_LCD 排线座、J5/J6 排针、JTAG、USB-UART、千兆网口）。")

h3("3.2.3 软件成果")
body("触摸屏提供总览、输入波形、逻辑时序、设置四页，零帧缓冲直写，不接上位机即可看数、看波、改参数、查故障；标定不再占独立页，改为 KEY0 长按或在设置页写 0x0502=0x0001。图 7 为总览页截图：MAIN 区显示输入频率与倍率，SPEED 区显示 RPM 与电频率，ABZANGLE 区显示角度与转向，REV 区显示 Z 计数，ABZ/UVW 区显示六路电平。图 7 右侧为设置页：INTER、DIV、PAIRS、RESLIM、Z 宽度/相位、UVW 相位与极性均可在线修改。2026-11-04 已在 v90 显示位流上逐页人工核对 P1/P2/P4/P6（含裸指触摸、KEY1 翻页与 P6 参数回读），四页全部通过。")
two_pictures(os.path.join("deliverables", "figures", "ui_p1.png"),
             os.path.join("deliverables", "figures", "ui_settings.png"), 6.6,
             "图 7  触摸屏总览页（左）与设置页（右），v90 显示位流上板截图")
body("上位机侧提供 UDP 抓包与连续流：一次抓包 28,672 点原始波形（@50 MSPS），用于看李萨如、算幅值/相位/THD；连续流模式在 60 s 内收到 597,886 帧、9,964.8 fps，半径均值漂移小于 0.02%。图 8 为上位机抓包界面。")
body("上位机是 PySide6 桌面程序（host/，57 个 .py），分三块：实时面板（波形、速度、ABZ/UVW 扇区、信号质量与告警）、抓包与回放（UDP 采样窗保存为 bin/CSV，可离线重算）、标定与参数（六参数一键标定、倍率与滤波在线修改、寄存器读写）。所有面板只读同一套寄存器定义（host/regs.py），与 RTL 的 reg_file.v 由 tools/check_regmap.py 对表校验；程序另带 selftest_*.py 若干，断网、断串口也能验证解析与绘图逻辑。")
picture(os.path.join("deliverables", "figures", "host_capture_ethernet.png"), 13.2,
        "图 8  上位机 UDP 抓包界面：原始 sin/cos、李萨如与统计量")

h2("特性成果", "3.3")

h3("3.3.1 优化过程与前后对比")
body("优化只针对真机暴露的两个缺陷，不做“为改而改”的重构。v66 生产位流在信号源上全绿、回归全过，但接上 2048 周期/转真实转台后四类观测量同时失效：多圈计数恒 0、Z 不出现、UVW 不换相。A/B 换回 v68 同样复现，排除转台与接线；探针位流把 10 s 的“无声”缩到单拍，定位到 rtl/pole_counter.v 把 0…65535 的无符号相位按补码符号扩展再相减，跨 32768 时 +133 被算成 −65,403；第二个缺陷是 rtl/uvw_gen.v 反向 0/5 扇区以 0 为基准，角度绕回 65535 侧后恒负，反向只剩三个扇区。")
body("第三处缺陷只有停位才暴露：转台停在 Z 附近时，角度噪声让 Z 反复布防/撤防，屏上 REV 计数抖动。v90 新增 rtl/abz_gen.v 的 z_index_gen：出 Z 后立即撤防，角度离开 Z 点 ≥1/8 圈（45°）才重新布防（Z_ARM_DIST = 1<<(AW-3)），因此整圈严格 1 个 Z，停位不再喘振。")
body("v90 在真实转台闭环（2026-11-04）：Z 7.62/7.65 Hz ⇒ 457–459 rpm，每转恰好 1 个 Z，UVW 六态计数 {5174, 4761, 4423, 4776, 4763, 4786}。相对 v66 基线，LUT 10,916 → 10,978（+62 LUT，+0.30 个百分点），BRAM 仍 32/50，时序 WNS +0.186 → +0.199 ns；v90 生产与 v90 显示两版同列于表 6。")
make_table(
    ["版本 / 场景", "关键改动", "Z / 多圈计数", "UVW", "LUT", "WNS"],
    [
        ["v66 生产（信号源）", "基线", "仿真通过、真机恒 0", "仿真通过、真机缺 3 扇区", "10,916", "+0.186 ns"],
        ["v68 / v69（真机）", "仅改配置与采样相位", "仍恒 0（同死）", "仍缺扇区", "—", "—"],
        ["v90 生产（当前，真机）", "新增 z_index_gen：出 Z 撤防、离开 45° 重布防", "Z 1 个/转，7.62/7.65 Hz", "六态计数均衡", "10,978（52.78%）", "+0.199 ns"],
        ["v90 显示（当前，已写 Flash）", "四页 UI + 千兆网", "同上", "同上", "17,090（82.16%）", "+0.221 ns"],
    ],
    [2.5, 3.4, 2.5, 2.4, 2.2, 1.6],
    cap="表 6  优化前后对比（同一综合实现脚本；v66 为历史基线、v90 为当前基线）",
)
body("标定链路的优化同样量化：复合畸变下圆度 CV 由 17.79% 降到 0.10%（≈176×），电角度误差 20.9839° → 0.0165°（黄金模型 + RTL 仿真，1273×）；真机全周 16 分箱残差落在 −0.13°…+0.13°，四次谐波 0.093° 是当前最大残余项，已列为下一轮补偿对象。")

h3("3.3.2 静态校正与角度一致性")
body("在信号源 90° 正交输入下完成六参数标定：gain_s=33,776、gain_c=33,568、shift=0、amp_sq=53,514、lock=0x0301。校正前李萨如呈明显椭圆并带偏置，校正后回到单位圆；去常数偏置后的全周 16 分箱系统残差落在 −0.13°…+0.13°，谐波分解为 h1≈0.050°、h2≈0.026°、h3≈0.006°、h4≈0.093°，四次谐波是当前最大残余项，下一步将针对四次谐波做补偿。转台实测（angle_vs_sc.py，2026-11-04）：offset 1.76°、RMS 0.71°、max 2.88°、误差 >5° 占比 0.03%——这是两条角度路径互比的内部一致性口径，不是对绝对角度基准的精度。")
picture(os.path.join("deliverables", "figures", "fig_calib_geometry.png"), 9.4,
        "图 9  六参数闭式校正的几何解释。（a）偏置、增益与正交误差把理想圆变成斜椭圆；（b）一阶/二阶矩一次解算把椭圆映射回单位圆，不需要查找表或迭代。")
picture(os.path.join("deliverables", "figures", "fig_calibration_summary.png"), 16.4,
        "图 10  六参数标定与残余误差。（a）校正前 s–c 轨迹，圆度 CV 17.79%；（b）校正后回到单位圆，CV 0.10%；（c）半径分布；（d）16 个 22.5° 分箱的电角度残差与 1–4 次谐波拟合；（e）谐波幅度，四次谐波 0.093° 为当前最大残余项。")

h3("3.3.3 动态闭环与多协议输出")
body("v90 生产位流在真实转台上通过真机判据（表 7）：Z 7.62/7.65 Hz ⇒ 457–459 rpm（每转 1 个 Z，权威读数取 z_rate.py；check_v70.py 屏显的转速受 1 Z/转 与判据口径影响，是混叠伪值，不采用）；Z 每转恰好 1 个，停位无喘振；UVW 六态计数 {5174, 4761, 4423, 4776, 4763, 4786}，均衡无缺扇区；lock=0x0301、r 峰 0.845–0.850 FS；angle_vs_sc offset 1.76°、RMS 0.71°、max 2.88°；60 s 连续流 597,886 帧、9,964.8 fps，ping 4/4、UDP 28,672 点 @50 MSPS。v70 及更早的版本以“输入 2048 周期/转 ⇒ 单圈计数走满 2048、Z 每转 1 个”为判据；v90 转台每转只有 1 个 Z，判据相应改为 Z 频率与每转个数，旧读数仅作历史对照。遥测文件 deliverables/data/telemetry_abz_uvw.csv 为 v70 轮采集（历史版本），只用于看 A/B 正交与 UVW 六态顺序，不再代表 v90 的 Z 行为。")
make_table(
    ["判据", "结果", "结论"],
    [
        ["Z 频率与转速一致", "7.62 / 7.65 Hz ⇒ 457–459 rpm（每转 1 个 Z，z_rate.py）", "通过，差为转台自身波动"],
        ["Z 每转 1 个", "停位撤防、离开 ≥1/8 圈重布防，整圈 1 个", "通过，无喘振"],
        ["UVW 六态均衡", "{5174, 4761, 4423, 4776, 4763, 4786}", "通过，无缺扇区"],
        ["信号质量与锁存", "lock=0x0301，r 峰 0.845–0.850 FS", "通过"],
        ["角度一致性（内部）", "offset 1.76°，RMS 0.71°，max 2.88°（误差 >5° 0.03%）", "通过，非绝对精度"],
        ["60 s 连续流", "597,886 帧，9,964.8 fps；ping 4/4，UDP 28,672 点 @50 MSPS", "通过"],
    ],
    [4.4, 6.4, 3.8],
    cap="表 7  v90 真机判据（2026-11-04 转台）",
)

picture(os.path.join("deliverables", "figures", "fig_abz_uvw.png"), 16.4,
        "图 11  增量与换相输出时序。（a）UVW 六步：每相 180° 高、120° 互差，720° 内完成两个电周期；（b）A/B/Z 放大：A、B 相差 90°，Z 每转一个，插值倍率 32× 时每电周期 32 个 A 周期。")
body("ABZ 的 2–256× 细分与 Z 门控可在线配置；滤波后 ABZ 抖动小于 0.92°，坏样本经角度域检测-保持后再注入被压低约 8 倍。")

h3("3.3.4 与商用细分器的定位对比")
make_table(
    ["项目", "同类专用细分 ASIC（公开资料典型值）", "同类高阶方案（公开资料典型值）", "本作品"],
    [
        ["细分辨率", "10 bit", "16 bit（后分频）", "16 bit 直出"],
        ["ABZ / UVW", "有 / 有", "有 / 有 + BiSS", "2–256× / 六步 + 单 Z"],
        ["校正", "片内固定", "片内 + 偏心补偿", "六参数闭式 + 可选全周表"],
        ["诊断", "SPI", "SPI / BiSS", "触摸 UI + 1 GbE + ILA"],
        ["实现", "专用 ASIC", "专用 ASIC（封闭）", "单片 FPGA，算法可演进"],
    ],
    [3.0, 3.7, 3.7, 4.2],
    cap="表 8  定位对比（商用器件按公开资料口径，仅作定位参考，非实测对比）",
)
body("与专用 ASIC 相比，本作品的优势不是单颗成本，而是“可演进 + 可审计 + 多协议并行输出”：校正算法、滤波系数、输出协议都能在线改，寄存器地图与校准结果可回读，研发阶段不必为一次算法改动重新流片。")

h3("3.3.5 可复现性与证据链")
body("仓库以 MIT 许可开放 RTL、约束、仿真台、上位机与文档；320 件证据、323 条 SHA-256 覆盖到每个位流、报告与图；57 个仿真台覆盖采集、校正、CORDIC、PI、计数、UVW、UI、以太网；“tools/final_verify.ps1” 一条命令检查源码与签核位流的文本一致性、时序、位流 SHA、文档齐套。报告与本文档中的每个数字都能追到对应文件、日志或位流。")
picture(os.path.join("deliverables", "figures", "fig_verify_chain.png"), 16.4,
        "图 12  五级验证链。固定点模型、RTL、仿真台、构建签核与真机判据逐级绑定，任一级失败都能回溯到上一级的输入。")

# ---------------- 第四部分 ----------------
part_heading("第四部分  总结")

h2("可扩展之处", "4.1")
body("（1）谐波误差补偿：当前最大残余项是四次谐波（约 0.093°），二次谐波约 0.026°，可在校正后加谐波查表或多项式；（2）100 MHz 时钟 + CORDIC 展开：把 19 拍压到 5–10 拍，总延迟进入 550 ns 以内；（3）原始域 3 点中值：在 ADC 坏样本进入校正前抑制，代价 2 拍延迟与少量比较器；（4）多轴参数化例化：单轴约 30% LUT，多轴共用时钟天然同步，适合多关节一体控制；（5）产品化：RS-422 差分输出、EMC 整改、真实 Z 输入与外部高精度基准比对。")

h2("心得体会", "4.2")
body("这个项目最大的教训是：仿真全绿不等于正确。我们的主回归（当时 33 台，现 37 台）在 v69 上全部通过，但真机 10 秒就暴露 cycle_cnt 恒 0——因为所有激励都在小角度内来回，从未跨过 32768 这个半量程边界。符号扩展错误在数学上很“显眼”，在波形上却完全静默：它只在跨边界那一步发生，之后累加器又被拉回 0，看上去像“传感器没转”。这让我们把“边界跨越激励”写进了技能包：整圈、跨 0、跨 2^(N−1)、跨 2^N−1，至少一条反向，断言要盯住跨边界那几步的增量本身，而不是只看最终角度。")
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
    "IEEE. IEEE Standard for Ethernet: 802.3-2022[S]. 2022.",
    "Python Software Foundation. Python 3 Language Reference[Z]. 2025.",
]
for i, ref in enumerate(refs, 1):
    p = doc.add_paragraph()
    fmt_par(p, align=WD_ALIGN_PARAGRAPH.JUSTIFY, indent_chars=0, size=10.5, after=2)
    p.paragraph_format.left_indent = Cm(0.95)
    p.paragraph_format.first_line_indent = Cm(-0.95)
    r = p.add_run("[%d] " % i)
    set_run(r, size=12, bold=True, east=SONG)
    r = p.add_run(ref)
    set_run(r, size=10.5, east=SONG)

# ---------------- 附录 ----------------
part_heading("附录 A  大模型协作记录")
body("全流程把大模型当作“必须先证伪假设的协作者”，而不是代码生成器。协作分三条工作流：需求→架构评审、定点黄金模型与 RTL 逐位对齐、上板缺陷定位。每次提出假设（PPR 配错、迟滞太小、位域截断、采样相位），都先设计一个能推翻该假设的实验，再谈修复；两次误判都是这样被推翻的。")
make_table(
    ["阶段", "提示词要点（摘要）", "模型输出", "人工纠错 / 裁决"],
    [
        ["需求→架构", "给出指标、器件与“无 PS”约束，要求先列风险再给方案", "候选架构、时钟域与接口划分", "否决 MMCM 方案，定单时钟域"],
        ["算法建模", "要求 Python 定点模型与 RTL 逐位一致，给出对拍方法", "黄金模型、对拍脚本、位宽分析", "发现 4 处截断位宽错误"],
        ["RTL 评审", "要求按“跨半量程、反向、坏样本”三类边界审代码", "两处静默死锁的复查清单", "修 pole_counter / uvw_gen"],
        ["上板定位", "只给四类观测量与 A/B 位流结果，要求先列可证伪假设", "PPR 假设、探针位流方案、tb_dbg6", "两次误判被 A/B 与单拍波形推翻"],
        ["文档与图", "要求所有数字可追溯到 CSV/日志/位流哈希", "报告结构、图套件、验收表", "逐条回填证据锚点"],
    ],
    [2.4, 4.4, 4.4, 3.2],
    cap="表 A-1  大模型协作的五个阶段（完整 86 条记录见 docs/ai-collaboration-log.md）",
)
body("两次真实误判：① 把“多圈计数恒 0”归因于 PPR/POLE_BITS 配置，A/B 换回 v68 同样死，假设被证伪；② 只修前向 UVW、漏掉反向，tb_uvw_rev 显示反向 7 次中 82% 停在 110，才补上 bwd_wide。最终用“真机四观测同死 → 探针位流 → tb_dbg6 单拍 BADSTEP → 读 RTL”四步定位。提示词、模型回答与纠错轨迹已随仓库提交（docs/ai-collaboration-log.md），本报告只做摘要。")
body("另外两条可复查的轨迹：其一，多轮仿真“看起来正常”但覆盖率异常，模型先假设 DUT 逻辑有错，实际是测试台激励根本没接到 DUT 端口上——最后靠一个只找“被计算但从未被读”的线的静态检查（tools/scan_dangling.py）才把问题摆到桌面上；其二，输入端口负余量被误判为“约束写反”，复核后发现那是数据手册 tPD=2–6 ns 的诚实建模，约束取 ≤4 ns 之后的负余量是设计选择而非虚假违例。两条都已沉淀进技能包（testbench-blindspot、adc-source-sync-constraints）。")

part_heading("附录 B  技能包提炼过程")
body("skill/ 目录 7 篇方法长文全部按“一句话 / 适用范围 / 使用方法 / 失效条件 / 提炼过程 / 已验证效果”六节撰写；每项都来自本工程的一次真实失败或观察，并给出可回溯的证据锚点，供陌生队伍换题、换板卡直接复用。另有 19 项可直接复制执行的四类资产（6 个校验脚本 / 7 个模板 / 5 篇提示词工作流 / 18 条踩坑清单），同样逐项标注适用场景、用法、已验证效果与失效条件。")
make_table(
    ["技能", "提炼自哪次失败 / 观察", "如何验证有效", "失效边界"],
    [
        ["golden-model-bit-exact", "算法与 RTL 对不上时无法判断谁错", "Python 模型与 37 台回归逐位对拍", "纯组合逻辑或浮点算法不适用"],
        ["fixedpoint-width-safety", "uvw_gen 拼接截断 + v70 跨半量程符号扩展", "tb_acc2：0→6→12 计数；真机整圈计数连续", "小角度激励永远触发不了"],
        ["testbench-blindspot", "回归全绿但真机 10 s 死锁", "整圈/跨 0/跨半量程激励补齐", "无状态或单周期模块收益有限"],
        ["adc-source-sync-constraints", "输入约束方向写反导致假违例", "v9/v10 相位 A/B/A 实测", "非源同步接口需换约束模板"],
        ["deterministic-measurement", "墙上时间 ÷ 帧数误差 2.3×", "电气周期数 + 余数复算", "无参考时钟的场合不适用"],
        ["vivado-report-autocollect", "手抄综合报告易错、版本对不上", "一页数据表与报告逐项比对", "非 Vivado 流程需改解析"],
        ["repo-reproducibility", "中文/空格路径导致脚本失败", "全仓库 ASCII 扫描 + 一键签核", "依赖私有 IP 的工程需补说明"],
    ],
    [3.2, 4.6, 4.4, 2.4],
    cap="表 B-1  技能包与失败来源、验证方法、失效边界",
)
body("陌生队伍的三步用法：只抄经验读 §3/§4；搬脚本改顶部路径常量；复现本工程按根 README 的快速开始执行。评价标准按指南原文执行——“拿到该目录能否直接用在自主题目上”。")
body("可执行资产的可信度不靠自述：6 个脚本仅依赖 Python 标准库，夹具全部取自本工程真实数值（v90 报告 +0.199 ns / LUT 52.78%，另有 −0.123 ns / 7 个失败端点的失败回放）；python skill/scripts/skill_selftest.py 在陌生机器上一条命令即可复验 24/24（其中 10 条是“必须失败”的负对照），python skill/scripts/run_all_checks.py 再把两套自检与四项仓库门禁（链接 / 命名 / 记录号可追 / 文档口径与现场一致）合成一条命令，当前 7/7 全绿；症状索引 skill/pitfalls_index.md 由 tools/gen_pitfall_index.py 从两份清单（18 + 14 条）生成，--check 防止“清单改了索引没改”——只验证“该过的过”正是本工程踩过的坑。")
body("通用 PYNQ 技能包（skill/pynq/，按指南 3.3.2 申报）：本项目本体是纯 RTL、没有 PS，但该加分项要求 Skill 不与本队题目绑定，因此另做了一套只读 .hwh 与文件时间戳的工具——pynq_hwh.py 解析 handoff（IP 清单 / 从口地址表 / 时钟域，判据 ADDR-000…010、CLK-001/002、REG-001，支持 --diff/--json/--md）、pynq_bundle.py 体检交付目录（位流与地址表配对、时间戳、两版 IP 清单对比）、pynq_overlay.py 给出上板 5 条判据与 --mock 离线版，pynq_selftest.py 18 用例（含 5 条负对照、含 --emit-script 生成物编译检查）全部通过。夹具是 Vivado 2026.1 在 XC7A35T 上真实导出的 handoff（57,252 B）：补入地址后 PASS、地址重叠 FAIL、缺 .hwh FAIL。夹具与判据都可复现：同一份真实 handoff 补地址后 PASS、地址重叠 FAIL、缺 .hwh FAIL；每条结论在 skill/pynq/README.md 第 4 节都附了夹具与命令。")

part_heading("附录 C  复现说明")
body("以下命令均以仓库根目录为工作目录；环境为 Vivado 2026.1、Python 3.13、ModelSim（本机 xsim 启动即崩，回归改用 vsim）、正点原子达芬奇-lite XC7A35TFGG484-2 + HSEDA AD9238。")
body("（1）构建源：仓库 rtl/ 已是 v90 源（RTL_BUILD_ID=0x0019，rtl/enc_top.v:239），python tools/make_v90_rtl.py 只做复制与逐字节校验、不再改写 BUILD_ID，输出 _synth_work_v90/rtl_v90。")
body("（2）综合与实现：vivado -mode batch -source tools/impl_check_v90.tcl，产物 _synth_work_v90/enc_top_v90.bit（1,504,220 B，SHA-256 A89512A5…8F827125）与时序/利用率报告；显示位流用 tools/impl_check_disp_v90.tcl，产物 _synth_work_v90/enc_top_disp_v90.bit（1,688,245 B）。")
body("（3）仿真：powershell tools/run_sim.ps1（57 台 = sim 37 + disp 20，含 tb_acc2、tb_uvw_rev 定向台）；日志写入 sim/logs。")
body("（4）上板：烧录 v90 生产位流，python _boardtest/check_v70.py --port COMx 读寄存器判据（寄存器地图自 v70 未变，脚本名保留 v70）；Z 频率与转速用 python _boardtest/z_rate.py；角度一致性用 python _boardtest/angle_vs_sc.py；60 s 长跑用 python _boardtest/soak_v68.py。期望：Z 7.62/7.65 Hz ⇒ 457–459 rpm、UVW 六态计数 {5174, 4761, 4423, 4776, 4763, 4786}、lock=0x0301、r 峰 0.845–0.850 FS、angle_vs_sc offset 1.76°/RMS 0.71°/max 2.88°、60 s 597,886 帧。")
body("（5）签核：powershell tools/final_verify.ps1 检查源码与位流文本一致、WNS/WHS、位流 SHA 与文档齐套；cd deliverables/data && sha256sum -c SHA256SUMS.txt 应逐条通过（清单 323 条）。")
body("（6）交付核对：design_report.pdf（本模板版）、technical_doc.pdf、source_code.zip / source_code.rar 的 MANIFEST.sha256 逐文件校验；任何数字都能在 evidence_index.md 找到对应文件、日志或位流哈希。")
body("（7）一键自检：python skill\\scripts\\run_all_checks.py 一次跑完技能包用例、症状索引一致性、安全与命名检查、记录号可追踪、文档数字与现场一致，7 项全部通过（2026-11-04）；它不重新综合，只核对“仓库里的说法与仓库里的证据是否对得上”。")
body("复现时最常卡住的四个点，按出现频率排序：")
bullet("位流 BUILD_ID 不是 0x0019：说明烧的是旧 bit 文件。重跑 tools/impl_check_v90.tcl，再比对 deliverables/data/SHA256SUMS.txt 里的哈希。")
bullet("屏上不亮：显示功能只在 enc_top_disp_v90.bit 里，生产位流不驱动 RGB 屏；两块位流不要混烧。")
bullet("仿真起不来：run_sim.ps1 需在 sim/ 目录下运行，且 vsim 在 PATH 里；先单独跑一个 tb 看 license。")
bullet("串口/UDP 打不开：串口要独占，先关掉上位机与串口助手；UDP 需 PC 与板同网段，并在防火墙放行对应端口。")

doc.add_page_break()
body("复现环境与目录对照见表 C-1。版本号写进表里而不是散落在正文，换机器时只需核对这一张表。")
make_table(
    ["项", "版本 / 路径", "在复现中的角色"],
    [
        ["工具链", "Vivado 2026.1、ModelSim / vsim", "综合实现、时序与 DRC 报告，57 台回归"],
        ["Python", "3.13.9（标准库 + python-docx、pymupdf）", "黄金模型、上位机、文档与图构建"],
        ["开发板", "正点原子达芬奇-lite，XC7A35TFGG484-2", "唯一计算单元，无 PS、无 PYNQ"],
        ["ADC 模块", "HSEDA AD9238BSTZ-65", "双通道 12 bit、65 MSPS，偏移二进制"],
        ["RTL", "rtl/（24 模块）+ rtl/eth/（8 模块）", "仓库即 v90 源，RTL_BUILD_ID = 0x0019"],
        ["仿真", "sim/（37 台）、disp/（20 台）", "PASS 37/37、20/20，日志写入 sim/logs"],
        ["上位机", "host/（57 个 .py）", "link、check、soak、angle_vs_sc、抓包"],
        ["文档与技能包", "docs/、deliverables/data/、skill/", "39 号判据表、323 条 SHA-256、19 项资产"],
    ],
    [2.6, 6.4, 5.8],
    cap="表 C-1  复现环境与目录对照",
)

out = os.path.join("deliverables", "design_report.docx")
doc.save(out)
print("saved", out, os.path.getsize(out))
