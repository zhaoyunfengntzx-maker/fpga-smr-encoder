#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the AMD-template one-page poster (A4 landscape, 29.7 x 21 cm).

Follows the layout of the official AMD student-poster template:
title 24 pt Times New Roman, team/affiliation 12 pt Times New Roman,
INTRODUCTION | SYSTEM ARCHITECTURE | CREATIVE DESIGN | RESULT blocks,
board thumbnail, test-platform line and a copyright footer.

The submission copy is anonymous.  To produce the final venue copy, create
`identity.json` next to this script:

    {"names": "Zhang San, Li Si", "school": "University", "province": "Province"}

and rerun; the header will then show names / school / province.
"""
import json
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Cm, Pt

HERE = Path(__file__).resolve().parent
OUT = HERE / "poster_amd_A4.pptx"
FIG = HERE.parent / "figures"

NAVY = RGBColor(0x14, 0x1C, 0x2B)
INK = RGBColor(0x1B, 0x22, 0x2B)
MUTED = RGBColor(0x55, 0x60, 0x6E)
AMBER = RGBColor(0xC9, 0x86, 0x12)
LINE = RGBColor(0xD5, 0xDC, 0xE5)
PAPER = RGBColor(0xF6, 0xF7, 0xF9)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
TEAL = RGBColor(0x0F, 0x5E, 0x59)

SERIF = "Times New Roman"
SANS = "Calibri"

prs = Presentation()
prs.slide_width = Cm(29.7)
prs.slide_height = Cm(21.0)
slide = prs.slides.add_slide(prs.slide_layouts[6])
shapes = slide.shapes


def _ea(run, face):
    rPr = run._r.get_or_add_rPr()
    rPr.append(rPr.makeelement(qn("a:ea"), {"typeface": face}))


def text(x, y, w, h, paras, size=9.0, color=INK, bold=False, font=SANS,
         align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, space_after=1.5, spacing=0.98):
    tb = shapes.add_textbox(Cm(x), Cm(y), Cm(w), Cm(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = Cm(0)
    tf.auto_size = None
    for i, para in enumerate(paras):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.space_after = Pt(space_after)
        p.line_spacing = spacing
        segs = para if isinstance(para, list) else [(para, {})]
        for txt, opt in segs:
            r = p.add_run()
            r.text = txt
            f = r.font
            f.name = opt.get("font", font)
            _ea(r, "Microsoft YaHei")
            f.size = Pt(opt.get("size", size))
            f.bold = opt.get("bold", bold)
            f.color.rgb = opt.get("color", color)
    return tb


def panel(x, y, w, h, fill=WHITE, line=LINE, lw=0.75):
    s = shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(x), Cm(y), Cm(w), Cm(h))
    s.fill.solid()
    s.fill.fore_color.rgb = fill
    if line is None:
        s.line.fill.background()
    else:
        s.line.color.rgb = line
        s.line.width = Pt(lw)
    s.shadow.inherit = False
    return s


def section(x, y, w, title):
    bar = shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(x), Cm(y), Cm(w), Cm(0.78))
    bar.fill.solid()
    bar.fill.fore_color.rgb = NAVY
    bar.line.fill.background()
    bar.shadow.inherit = False
    tf = bar.text_frame
    tf.margin_left = Cm(0.22)
    tf.margin_top = tf.margin_bottom = Cm(0)
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    p = tf.paragraphs[0]
    p.alignment = PP_ALIGN.LEFT
    r = p.add_run()
    r.text = title
    r.font.name = SANS
    r.font.size = Pt(12)
    r.font.bold = True
    r.font.color.rgb = WHITE


def metric(x, y, w, h, big, label):
    panel(x, y, w, h, fill=PAPER)
    text(x + 0.2, y + 0.16, w - 0.3, 0.85, [[(big, {"size": 13.5, "bold": True, "color": NAVY})]])
    text(x + 0.2, y + 1.02, w - 0.3, 0.8,
         [[(ln, {"size": 7.0, "color": MUTED})] for ln in label])


# ---------------------------------------------------------------- header
text(0.8, 0.55, 17.6, 1.9,
     [[("A 2,048-ppr Magnetic Encoder on One Artix-7",
        {"size": 24, "bold": True, "font": SERIF})]], spacing=0.9)
text(0.8, 2.55, 18.0, 0.9,
     [[("基于FPGA的细分编码器", {"size": 12, "bold": True}),
       ("   ·   16-bit on-chip interpolation, closed-form self-calibration, ABZ / UVW / SPI / UDP",
        {"size": 9.2, "color": MUTED})]])

identity_path = HERE / "identity.json"
if identity_path.exists():
    ident = json.loads(identity_path.read_text(encoding="utf-8"))
    text(21.2, 0.62, 6.4, 1.6,
         [[(ident.get("names", ""), {"size": 12, "font": SERIF, "bold": True})],
          [(ident.get("school", "") + ("，" + ident["province"] if ident.get("province") else ""),
            {"size": 12, "font": SERIF})]], align=PP_ALIGN.RIGHT, spacing=0.95)
else:
    text(20.6, 0.72, 7.0, 0.9,
         [[("Anonymous submission — author and affiliation withheld.",
            {"size": 7.6, "color": MUTED})]], align=PP_ALIGN.RIGHT)

# AMD wordmark (text-only, no bitmap dependency)
amd = text(26.05, 1.32, 2.9, 1.3, [[("AMD", {"size": 26, "bold": True, "color": RGBColor(0x1B, 0x1B, 0x1B), "font": SANS})]],
           align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE)
rule = shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(0.8), Cm(3.55), Cm(28.1), Cm(0.06))
rule.fill.solid()
rule.fill.fore_color.rgb = AMBER
rule.line.fill.background()
rule.shadow.inherit = False

# ---------------------------------------------------------------- row 1
section(0.8, 3.85, 8.5, "INTRODUCTION")
intro = [
    "Optical encoders lose accuracy in dust, oil and vibration. Magnetic sensing is rugged, "
    "but the raw sin/cos bridge is never ideal: offset, gain mismatch, quadrature error and "
    "residual shift all fold into the angle.",
    "Imported interpolation ASICs fix both the algorithm and the interface, yet multi-turn "
    "Multi-turn counting needs a second chip and the calibration recipe stays opaque. This work puts the "
    "whole chain — acquisition, calibration, atan2, tracking and five output protocols — into "
    "one Artix-7.",
    [("Goal: ", {"bold": True}),
     ("2,048 ppr, 16-bit angle, sub-µs latency, ABZ / UVW / SPI / UDP / UART from a single "
      "50 MHz clock domain.", {})],
    [("Key technical issues", {"bold": True, "color": TEAL})],
    "•  Analog front end: 0.5 Vpp differential to 8 Vpp, 65 MSPS, offset binary.",
    "•  Real-time: deterministic 41.5-cycle pipeline, no MMCM, no CDC.",
    "•  Protocols: ABZ 1–1024×, UVW + virtual Z, SPI slave, 1 GbE UDP.",
    "•  Validation: fixed-point model, 54 benches, build sign-off, real turntable.",
]
text(1.05, 4.85, 8.0, 7.9, intro, size=8.7, space_after=4.0, spacing=0.97)

section(9.6, 3.85, 19.3, "SYSTEM ARCHITECTURE — ONE CLOCK DOMAIN, 41.5-CYCLE LATENCY")
pic = shapes.add_picture(str(FIG / "sys_arch_en.png"), Cm(9.95), Cm(4.82), width=Cm(13.55))
note_x = 23.85
text(note_x, 4.9, 4.85, 7.7, [
    [("Single 50 MHz clock", {"bold": True, "color": TEAL})],
    "No MMCM/PLL. The ADC clock is forwarded by ODDR, so capture, DSP and outputs share one edge.",
    [("Fixed latency", {"bold": True, "color": TEAL})],
    "41.5 cycles ≈ 830 ns from sample to angle — a speed loop can be tuned without online delay identification.",
    [("Five protocols, one image", {"bold": True, "color": TEAL})],
    "ABZ, UVW+Z, SPI, 1 GbE UDP and UART are generated from the same 32-bit angle, speed and status word.",
], size=8.2, space_after=3.0, spacing=0.96)

# ---------------------------------------------------------------- row 2
section(0.8, 13.95, 8.5, "CREATIVE DESIGN")
text(1.05, 14.9, 8.0, 5.3, [
    [("1  Closed-form six-parameter calibration", {"bold": True, "color": NAVY})],
    "One first/second-order moment solve maps the distorted ellipse to a unit circle. No LUT, "
    "no host iteration; the six coefficients are readable over UART.",
    [("2  Single clock, 41.5 cycles", {"bold": True, "color": NAVY})],
    "Zero CDC and zero IP: latency is a design constant, not a measurement. Peak sample rate is "
    "traded for determinism, which is what an encoder needs.",
    [("3  Wrap-safe counting and UVW", {"bold": True, "color": NAVY})],
    "Unsigned-difference zero-extension removed a +133 → −65,403 sign-extension deadlock; a "
    "wide-base branch makes the 0↔5 sector identical forward and reverse.",
], size=8.3, space_after=4.0, spacing=0.96)

section(9.6, 13.95, 11.2, "RESULT — V74 PRODUCTION BITSTREAM, REAL TURNTABLE")
metric(9.82, 14.85, 2.6, 1.85, "2,048", ["pulses / rev", "2,048 distinct counts"])
metric(12.54, 14.85, 2.6, 1.85, "16 bit", ["angle resolution", "0.0055°/LSB"])
metric(15.26, 14.85, 2.6, 1.85, "719–731", ["rpm, real turntable", "Z = 12.00 Hz"])
metric(17.98, 14.85, 2.6, 1.85, "598,115", ["frames / 60 s", "9,968 fps"])
text(9.85, 16.93, 10.7, 3.0, [
    [("Resources: ", {"bold": True}),
     ("10,926 LUT (52.53%) · 8,697 FF · 32/50 BRAM · 17 DSP", {})],
    [("Timing: ", {"bold": True}),
     ("WNS +0.409 ns · WHS +0.025 ns · 0 failing endpoints (24,625)", {})],
    [("On hardware: ", {"bold": True}),
     ("UVW six states uniform, 293 commutations/s; 60 s stream, radius drift < 0.02%", {})],
], size=8.4, space_after=3.2, spacing=0.96)

section(21.1, 13.95, 7.8, "ON-BOARD UI & TEST PLATFORM")
shapes.add_picture(str(FIG / "ui_p1.png"), Cm(21.4), Cm(14.88), width=Cm(6.2))
text(21.4, 19.6, 6.2, 0.45,
     [[("1024×600 touch UI (v62 demo bitstream)", {"size": 6.6, "color": MUTED})]], align=PP_ALIGN.CENTER)
text(21.4, 20.02, 6.6, 0.35,
     [[("XC7A35T · AD9238 2×12 bit · 50 MHz single clock", {"size": 6.6, "color": MUTED})]])

# ---------------------------------------------------------------- footer
line2 = shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(0.8), Cm(20.42), Cm(28.1), Cm(0.03))
line2.fill.solid()
line2.fill.fore_color.rgb = LINE
line2.line.fill.background()
line2.shadow.inherit = False
text(0.8, 20.5, 28.1, 0.45,
     [[("Copyright 2026 · 2026 9th National College Student Embedded Chip & System Design Competition · "
        "FPGA Innovation Track · AMD Track · Independent Topic (Junior Group) · XC7A35TFGG484-2",
        {"size": 7.0, "color": MUTED})]])

# 匿名提交：清掉模板作者/最后修改人（AMD 官方模板里带第三方姓名）
cp = prs.core_properties
cp.author = ""
cp.last_modified_by = ""
cp.title = "基于FPGA的细分编码器"
cp.subject = ""
cp.keywords = ""
cp.comments = ""
cp.revision = 1
prs.save(str(OUT))
print("saved", OUT)
