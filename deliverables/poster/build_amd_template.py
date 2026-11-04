# -*- coding: utf-8 -*-
"""Build the anonymous AMD-track poster from the official template (journal layout)."""
import os
import re
from pptx import Presentation
from pptx.util import Cm, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN
from pptx.enum.shapes import MSO_SHAPE

SRC = r"deliverables\poster\template_src.pptx"
OUT = r"deliverables\poster\poster_amd_official.pptx"

INK = RGBColor(0x11, 0x11, 0x11)
NAVY = RGBColor(0x0B, 0x25, 0x45)
GREY = RGBColor(0x55, 0x5F, 0x6B)
AMBER = RGBColor(0xB9, 0x7C, 0x12)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

prs = Presentation(SRC)
slide = prs.slides[0]


def drop(shape):
    shape._element.getparent().remove(shape._element)


def text_of(sh):
    return sh.text_frame.text if sh.has_text_frame else ""


DELETE_KEYS = [
    "Title ：Times New Roman", "Team Member Names", "Font: Calibri",
    "校名", "校徽", "作品实物缩略图", "作品测试平台信息",
    "系统框图，关键创新点", "背景，关键信息摘要", "测试结果，性能，展望",
    "SFP+ interface", "On board test by AMD", "[Copyright",
    "Radio telescopes", "Optical Communication Receiver Card",
    "High-speed Acquisition Card",
]


def is_sample_identity(sh):
    """模板右上角的“示例作者/示例单位”占位块。

    这里不写死具体校名或人名，而是按“位置 + 形态”判定：右上角（右上栏）
    且文本形如“某某大学”（含 University / 大学）或“姓 名, 姓 名, 姓 名”
    的逗号分隔英文人名列表。这样脚本里不会残留任何具体学校/个人字样。
    """
    t = (sh.text_frame.text if sh.has_text_frame else "").strip()
    if not t:
        return False
    if sh.left / 360000 < 17.0 or sh.top / 360000 > 3.2:
        return False
    if "University" in t or "大学" in t:
        return True
    parts = [p.strip() for p in t.split(",")]
    if len(parts) >= 2 and all(re.fullmatch(r"[A-Z][a-z]+ [A-Z][a-z]+", p) for p in parts):
        return True
    return False


for sh in list(slide.shapes):
    if any(k in text_of(sh) for k in DELETE_KEYS) or is_sample_identity(sh):
        drop(sh)
    elif sh.shape_type == 9 and sh.width / 360000 > 4 and sh.height / 360000 > 3:
        # 模板遗留的斜向装饰线，会横穿系统框图，去掉
        drop(sh)
    elif text_of(sh).strip() == "Typical application case" and sh.top / 360000 > 8.5:
        drop(sh)
    elif sh.shape_type == 9 and abs(sh.top / 360000 - 5.3) < 0.1:
        drop(sh)

# remove the template's black banner placeholders
for sh in list(slide.shapes):
    try:
        if sh.width / 360000 > 5 and sh.top / 360000 < 4.3 and sh.height / 360000 > 0.6:
            if sh.fill.type is not None and sh.fill.fore_color.rgb == RGBColor(0x00, 0x00, 0x00):
                drop(sh)
    except Exception:
        pass

# drop the template's old section title and banner
for sh in list(slide.shapes):
    txt = sh.text_frame.text.strip() if sh.has_text_frame else ""
    if txt == "System Architecture":
        drop(sh)
    if 2.8 < sh.top / 360000 < 3.2 and sh.width / 360000 > 5:
        drop(sh)

# remove sample pictures, keep the AMD wordmark
for sh in list(slide.shapes):
    if sh.shape_type == 13:
        x = sh.left / 360000
        if abs(x - 28.76) < 0.4 or abs(x - 25.76) < 0.4 or abs(x - 0.71) < 0.5:
            drop(sh)

# replace the sample architecture picture
for sh in list(slide.shapes):
    if sh.shape_type == 13 and 11.0 < sh.left / 360000 < 12.0:
        drop(sh)
slide.shapes.add_picture(r"deliverables\figures\poster_arch.png",
                         Cm(11.2), Cm(4.55), width=Cm(9.9), height=Cm(3.96))

# on-board UI photograph
slide.shapes.add_picture(r"deliverables\figures\ui_p1.png",
                         Cm(28.1), Cm(0.25), width=Cm(5.2))


def rule(x, y, w, color=NAVY, h=0.035):
    sh = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(x), Cm(y), Cm(w), Cm(h))
    sh.fill.solid(); sh.fill.fore_color.rgb = color
    sh.line.fill.background()
    return sh


def bar(x, y, w, h, text):
    sh = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(x), Cm(y), Cm(w), Cm(h))
    sh.fill.solid(); sh.fill.fore_color.rgb = RGBColor(0x1A, 0x1A, 0x1A)
    sh.line.fill.background()
    tf = sh.text_frame; tf.clear()
    p = tf.paragraphs[0]; p.alignment = PP_ALIGN.CENTER
    r = p.add_run(); r.text = text
    r.font.size = Pt(14); r.font.bold = True; r.font.name = "Times New Roman"
    r.font.color.rgb = WHITE
    return sh


def set_box(sh, lines, size=9.0, color=INK, font="Calibri", spacing=1.03,
            align=PP_ALIGN.LEFT, margins=0.05, bold=False):
    tf = sh.text_frame
    tf.clear(); tf.word_wrap = True
    tf.margin_left = tf.margin_right = Cm(margins)
    tf.margin_top = tf.margin_bottom = Cm(0.01)
    for i, item in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align; p.line_spacing = spacing
        p.space_before = Pt(0); p.space_after = Pt(2.2)
        text, b = item if isinstance(item, tuple) else (item, bold)
        if "||" in text:
            lead, rest = text.split("||", 1)
            r = p.add_run(); r.text = lead
            r.font.size = Pt(size); r.font.bold = True
            r.font.color.rgb = color; r.font.name = font
            r = p.add_run(); r.text = " " + rest
            r.font.size = Pt(size); r.font.bold = False
            r.font.color.rgb = color; r.font.name = font
        else:
            r = p.add_run(); r.text = text
            r.font.size = Pt(size); r.font.bold = b
            r.font.color.rgb = color; r.font.name = font


def add_text(x, y, w, h, lines, **kw):
    tb = slide.shapes.add_textbox(Cm(x), Cm(y), Cm(w), Cm(h))
    set_box(tb, lines, **kw)
    return tb


# ---------------- header ----------------
add_text(0.8, 0.42, 14.8, 1.0, [("基于FPGA的细分编码器", True)],
         size=24, font="Microsoft YaHei", color=NAVY, spacing=0.95)
add_text(0.8, 1.42, 14.8, 1.2, [
    "A 2,048-ppr magnetic encoder on a single Artix-7",
    "16-bit interpolation \u00b7 closed-form self-calibration \u00b7 ABZ / UVW / SPI / UDP",
], size=10.2, font="Calibri")
add_text(24.2, 0.42, 3.6, 1.0, [
    "Anonymous copy",
    "Author and affiliation withheld",
], size=7.8, color=GREY)

# ---------------- left column ----------------
bar(0.8, 3.45, 9.9, 0.95, "INTRODUCTION")
add_text(0.8, 4.6, 9.9, 3.9, [
    "Optical encoders degrade under dust, oil and vibration. Magnetic sensing is robust, yet the raw sin/cos bridge is never ideal: offset, gain mismatch, quadrature error and mechanical shift all fold into the angle.",
    "Commercial interpolators fix algorithm and interface together: 10-bit resolution, opaque calibration, and multi-turn counting that needs a second die.",
    ("We implement 2,048 ppr, 16-bit angle and sub-\u00b5s latency, with ABZ, UVW, SPI and 1 GbE diagnostics from one 50 MHz clock.", True),
], size=8.5)

add_text(0.8, 8.1, 9.9, 0.4, [("TYPICAL APPLICATION CASE", True)], size=9.6, color=NAVY)
rule(0.8, 7.98, 9.9)
add_text(0.8, 8.6, 9.9, 1.7, [
    "Servo drives \u2014 UVW, ABZ and SPI from one 32-bit angle word.",
    "Machine-tool rotary tables \u2014 0.0055\u00b0/LSB at 41.5-cycle latency.",
    "Robot joints \u2014 immunity to oil, dust and vibration.",
    "EV traction \u2014 wide temperature range, no optical window.",
], size=8.8)

add_text(0.8, 10.75, 9.9, 0.4, [("KEY ENGINEERING PROBLEMS", True)], size=9.6, color=NAVY)
rule(0.8, 10.63, 9.9)
add_text(0.8, 11.2, 9.9, 1.9, [
    "1  Analog front end \u2014 0.5 Vpp differential to 8 Vpp, 65 MSPS, offset binary.",
    "2  Deterministic latency \u2014 41.5 cycles, fixed by construction.",
    "3  Protocol integration \u2014 ABZ 1\u20131024\u00d7, UVW + virtual Z, SPI, 1 GbE UDP.",
    "4  Verification \u2014 fixed-point model, 57 benches, sign-off, real turntable.",
], size=8.8)

add_text(0.8, 13.35, 9.9, 0.4, [("WHY ONE ARTIX-7", True)], size=9.6, color=NAVY)
rule(0.8, 13.23, 9.9)
add_text(0.8, 13.85, 9.9, 1.3, [
    "Acquisition, calibration, atan2, tracking and five protocols share one clock domain. The encoder core occupies about 30% of the device; the remainder is touch UI and Ethernet diagnostics.",
], size=8.9)

add_text(0.8, 15.3, 9.9, 0.4, [("DESIGN FLOW", True)], size=9.6, color=NAVY)
rule(0.8, 15.18, 9.9)
add_text(0.8, 15.8, 9.9, 1.5, [
    ("Model \u2192 RTL \u2192 57 benches \u2192 sign-off \u2192 board", True),
    "Every number traces to a CSV, log or bitstream hash.",
    "MIT-licensed repository \u00b7 320 evidence files \u00b7 323 SHA-256 lines.",
], size=8.6)

# ---------------- middle column ----------------
bar(11.2, 3.45, 9.9, 0.95, "SYSTEM ARCHITECTURE")
add_text(11.2, 8.55, 9.9, 0.4, [
    "Figure 1 | Six-stage pipeline in one clock domain: 41.5 cycles \u2248 830 ns.",
], size=7.4, color=GREY, spacing=0.95)

add_text(11.2, 9.12, 9.9, 0.4, [("CREATIVE DESIGN", True)], size=9.8, color=NAVY)
rule(11.2, 9.0, 9.9)
add_text(11.2, 9.55, 9.9, 5.15, [
    "Closed-form calibration.||A first/second-order moment solve maps the distorted ellipse to a unit circle in one pass; no LUT, no host iteration.",
    "One clock, 41.5 cycles.||No MMCM, no CDC, no soft core; latency is a design constant, not a measurement.",
    "Wrap-safe counting and UVW.||Unsigned-difference zero-extension removes the +133 \u2192 \u221265,403 deadlock; a wide-base branch makes the 0\u21945 edge identical both ways.",
], size=8.2)

add_text(11.2, 15.0, 9.9, 0.4, [("HOW IT WAS PROVEN", True)], size=9.8, color=NAVY)
rule(11.2, 14.88, 9.9)
add_text(11.2, 15.45, 9.9, 3.0, [
    ("Two silent deadlocks, found only on hardware.", True),
    "Ten seconds of silence on the real turntable while 33/33 benches passed.",
    "Build-ID bisect: probe 0x0013 reduced the failure to one step (\u221265,403 instead of +133); tb_acc2 reproduces 0 \u2192 6 \u2192 12 counts over 3,000 \u00d7 +133 steps.",
    ("Five on-board criteria: ", True),
    "Z = 7.62\u20137.65 Hz, 2,048 distinct counts, 457\u2013459 rpm, six UVW states, 60 s stream.",
], size=8.2)

# ---------------- right column ----------------
add_text(24.95, 9.32, 8.2, 0.4, [("RESULT \u2014 V90 PRODUCTION BITSTREAM", True)], size=9.8, color=NAVY)
rule(24.95, 9.24, 8.2)

metrics = [("2,048", "pulses per rev"), ("16", "bit angle"),
           ("457\u2013459", "rpm"), ("597,886", "frames in 60 s")]
x = 24.7
for num, lab in metrics:
    add_text(x, 9.78, 2.05, 0.75, [(num, True)], size=15.5, color=NAVY, spacing=0.9)
    add_text(x, 10.52, 2.05, 0.4, [lab], size=6.6, color=GREY, spacing=0.9)
    x += 2.12
add_text(24.7, 11.05, 8.6, 0.75, [
    "15.63 kHz electrical \u00b7 Z 7.62\u20137.65 Hz \u00b7 9,964.8 fps \u00b7 radius drift < 0.02%",
], size=8.6)

add_text(24.7, 12.15, 8.5, 0.4, [("IMPLEMENTATION", True)], size=9.2, color=NAVY)
rule(24.7, 12.03, 8.5)
add_text(24.7, 12.6, 8.5, 2.2, [
    "10,978 LUT (52.78%) \u00b7 8,724 FF \u00b7 32/50 BRAM \u00b7 17 DSP",
    "WNS +0.199 ns \u00b7 WHS +0.017 ns \u00b7 0 failing endpoints (24,691)",
    "DRC 0 errors \u00b7 single clock, no MMCM \u00b7 1,504,220 B (build 0x0019)",
], size=8.4)

add_text(24.7, 14.85, 8.5, 0.4, [("VERIFICATION", True)], size=9.2, color=NAVY)
rule(24.7, 14.73, 8.5)
add_text(24.7, 15.3, 8.5, 2.0, [
    "320 evidence files \u00b7 323 SHA-256 lines",
    "57 benches \u00b7 final_verify ALL CHECKS PASSED",
    "Technical report 17 pages \u00b7 full dossier 29 pages",
], size=8.4)

# ---------------- test platform under the photo ----------------
add_text(28.1, 4.2, 5.2, 0.35, ["On-board 1024\u00d7600 touch UI (v62)"], size=7.6, color=GREY)
add_text(28.1, 4.55, 5.2, 2.7, [
    ("TEST PLATFORM", True),
    "XC7A35TFGG484-2 \u00b7 single 50 MHz clock",
    "AD9238 2\u00d712-bit, 65 MSPS front end",
    "2,048-cycle/rev SMR ring, real turntable",
    "1 GbE UDP capture \u00b7 USB-UART 2 Mbaud",
], size=7.8)

# ---------------- master copyright ----------------
for sh in prs.slide_masters[0].shapes:
    if sh.has_text_frame and "Copyright" in sh.text_frame.text:
        tf = sh.text_frame
        tf.clear()
        p = tf.paragraphs[0]
        r = p.add_run()
        r.text = "Copyright \u00a9 2026 \u00b7 FPGA Innovation Track \u00b7 AMD Track"
        r.font.size = Pt(6.5)
        r.font.name = "Calibri"
        r.font.color.rgb = GREY
        r.font.bold = False
        sh.left, sh.top = Cm(0.18), Cm(0.12)
        sh.width, sh.height = Cm(6.4), Cm(0.32)

# 匿名提交：清掉模板作者/最后修改人（AMD 官方模板里带第三方姓名）
cp = prs.core_properties
cp.author = ""
cp.last_modified_by = ""
cp.title = "基于FPGA的细分编码器"
cp.subject = ""
cp.keywords = ""
cp.comments = ""
cp.revision = 1
prs.save(OUT)
print("saved", OUT, os.path.getsize(OUT))
