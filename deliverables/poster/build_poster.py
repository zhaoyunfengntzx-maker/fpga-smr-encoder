#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the one-page A4 English poster (deliverables/poster/poster_A4_EN.pptx).

A4 portrait, 21 x 29.7 cm, print margins >= 12 mm. White cards on light paper,
navy header, amber rules, one editable pipeline diagram drawn with shapes.
Numbers follow docs/33_v70_release_report.md (v70 board sign-off).
"""
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Cm, Pt

OUT = Path(__file__).resolve().parent / "poster_A4_EN.pptx"

NAVY = RGBColor(0x0B, 0x25, 0x45)
NAVY_SOFT = RGBColor(0x1D, 0x3A, 0x5F)
TEAL = RGBColor(0x0F, 0x6E, 0x69)
AMBER = RGBColor(0xC9, 0x86, 0x12)
INK = RGBColor(0x1B, 0x22, 0x2B)
MUTED = RGBColor(0x55, 0x60, 0x6E)
LINE = RGBColor(0xD5, 0xDC, 0xE5)
PAPER = RGBColor(0xF4, 0xF6, 0xF9)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
TINT = RGBColor(0xEC, 0xF4, 0xF3)
FONT = "Segoe UI"

prs = Presentation()
prs.slide_width = Cm(21.0)
prs.slide_height = Cm(29.7)
slide = prs.slides.add_slide(prs.slide_layouts[6])
shapes = slide.shapes


def rect(x, y, w, h, fill=WHITE, line=LINE, lw=0.75, shape=MSO_SHAPE.ROUNDED_RECTANGLE,
         radius=0.07):
    s = shapes.add_shape(shape, Cm(x), Cm(y), Cm(w), Cm(h))
    s.fill.solid()
    s.fill.fore_color.rgb = fill
    if line is None:
        s.line.fill.background()
    else:
        s.line.color.rgb = line
        s.line.width = Pt(lw)
    if shape == MSO_SHAPE.ROUNDED_RECTANGLE:
        try:
            s.adjustments[0] = radius
        except Exception:
            pass
    s.shadow.inherit = False
    return s


def text(x, y, w, h, paras, size=9.0, color=INK, bold=False, align=PP_ALIGN.LEFT,
         anchor=MSO_ANCHOR.TOP, space_after=0, line_spacing=0.98):
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
        p.line_spacing = line_spacing
        segs = para if isinstance(para, list) else [(para, {})]
        for txt, opt in segs:
            r = p.add_run()
            r.text = txt
            f = r.font
            f.name = FONT
            rPr = r._r.get_or_add_rPr()
            rPr.append(rPr.makeelement(qn('a:ea'), {'typeface': 'Microsoft YaHei'}))
            f.size = Pt(opt.get("size", size))
            f.bold = opt.get("bold", bold)
            f.italic = opt.get("italic", False)
            f.color.rgb = opt.get("color", color)
    return tb


def bullets(x, y, w, h, items, size=8.8, color=INK, gap=2.0, line_spacing=0.96):
    return text(x, y, w, h, items, size=size, color=color, space_after=gap,
                line_spacing=line_spacing)


def section(x, y, w, label):
    text(x, y, w, 0.5, [[(label.upper(), {"bold": True, "size": 10.2, "color": TEAL})]])
    ln = shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(x), Cm(y + 0.56), Cm(w), Cm(0.045))
    ln.fill.solid()
    ln.fill.fore_color.rgb = AMBER
    ln.line.fill.background()


# ------------------------------------------------------------------ background
bg = shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, prs.slide_height)
bg.fill.solid()
bg.fill.fore_color.rgb = PAPER
bg.line.fill.background()
bg.shadow.inherit = False

# ------------------------------------------------------------------ header 0–3.25
head = shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, Cm(3.25))
head.fill.solid()
head.fill.fore_color.rgb = NAVY
head.line.fill.background()
head.shadow.inherit = False

text(1.0, 0.40, 19.2, 0.4,
     [[("2026 9th National College Student Embedded Chip & System Design Competition",
        {"size": 8.2, "color": RGBColor(0x9F, 0xB6, 0xCE)})]])
text(1.0, 0.78, 19.4, 0.95,
     [[("FPGA Fine-Interpolation Encoder",
        {"size": 22, "bold": True, "color": WHITE})]])
text(1.0, 1.78, 19.2, 0.8,
     [[("A 2,048-ppr magnetic encoder on one Artix-7: 16-bit on-chip interpolation, closed-form self-calibration, ABZ / UVW / SPI / UDP",
        {"size": 9.0, "color": RGBColor(0xD7, 0xE2, 0xEE)})]])
text(1.0, 2.68, 19.2, 0.35,
     [[("FPGA Innovation Track  ·  AMD Track  ·  Independent Topic (Junior Group)  ·  XC7A35T-FGG484-2",
        {"size": 7.8, "color": RGBColor(0x8F, 0xA8, 0xC2)})]])

bar = shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, Cm(0.12))
bar.fill.solid()
bar.fill.fore_color.rgb = AMBER
bar.line.fill.background()

# ------------------------------------------------------------------ problem / approach
section(1.0, 3.50, 8.8, "The problem")
section(11.2, 3.50, 8.8, "Our approach")

rect(1.0, 4.22, 8.8, 4.45)
bullets(1.35, 4.42, 8.1, 4.05, [
    [("Optical encoders ", {}), ("lose accuracy", {"bold": True}),
     (" in dust, oil and vibration; magnetic sensing is rugged, but the raw sin/cos bridge is never ideal.", {})],
    [("Commercial interpolation ASICs ", {}), ("fix both the algorithm and the interface", {"bold": True}),
     (": multi-turn counting needs a second chip, and the calibration recipe stays opaque.", {})],
    [("Goal: ", {}), ("2,048 ppr, 16-bit angle, sub-µs latency", {"bold": True}),
     (", with ABZ, UVW, SPI and Ethernet from one 50 MHz clock domain — no MMCM, no soft-core.", {})],
], size=8.8, gap=5)

rect(11.2, 4.22, 8.8, 4.45)
bullets(11.55, 4.42, 8.1, 4.05, [
    [("Dual 12-bit AD9238 ", {"bold": True}),
     ("samples the SMR bridge at 65 MSPS; synchronous capture and ÷4 decimation give 12.5 MSPS.", {})],
    [("Six-parameter closed-form calibration ", {"bold": True}),
     ("— sin/cos offset, gain ratio, quadrature phase, residual shift — no LUT, no host tuning.", {})],
    [("17-stage CORDIC atan2 ", {"bold": True}),
     ("and a type-II PI loop yield 16-bit angle and speed; incremental unwrapping keeps direction across 0/2π.", {})],
], size=8.8, gap=5)

# ------------------------------------------------------------------ pipeline
section(1.0, 8.95, 19.0, "Signal path — one clock domain, 41.5-cycle latency (≈830 ns, design)")

pipe_y, pipe_h = 9.68, 2.55
stages = [
    (1.0, 4.35, "Front end", "SMR bridge · AD9238\n12-bit ×2 @ 65 MSPS"),
    (5.75, 4.35, "Capture ÷4", "synchronous sampling\n12.5 MSPS clean data"),
    (10.5, 4.6, "Calibrate + atan2", "6-parameter correction\n17-stage CORDIC, 16-bit"),
    (15.5, 4.5, "Track + output", "type-II PI tracking\nspeed, direction, unwrap"),
]
for i, (x, w, title, sub) in enumerate(stages):
    rect(x, pipe_y, w, pipe_h, WHITE if i % 2 == 0 else TINT)
    text(x + 0.28, pipe_y + 0.30, w - 0.5, 0.55,
         [[(title, {"bold": True, "size": 10.0, "color": NAVY})]])
    text(x + 0.28, pipe_y + 1.08, w - 0.5, 1.2, [[(sub, {"size": 8.2, "color": MUTED})]])
    if i < len(stages) - 1:
        ar = shapes.add_shape(MSO_SHAPE.RIGHT_ARROW, Cm(x + w + 0.05), Cm(pipe_y + 1.02),
                              Cm(0.35), Cm(0.5))
        ar.fill.solid()
        ar.fill.fore_color.rgb = AMBER
        ar.line.fill.background()
        ar.shadow.inherit = False

bus = shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Cm(1.0), Cm(12.38), Cm(19.0), Cm(0.62))
bus.fill.solid()
bus.fill.fore_color.rgb = NAVY_SOFT
bus.line.fill.background()
bus.shadow.inherit = False
bus.adjustments[0] = 0.25
text(1.0, 12.49, 19.0, 0.4,
     [[("shared 16-bit angle  +  speed  +  status   →   output stage",
        {"size": 8.8, "bold": True, "color": WHITE})]], align=PP_ALIGN.CENTER)

outs = [
    (1.0, 3.55, "ABZ", "1…1024× interpolation\n65,536 edges/rev at 32×"),
    (4.85, 3.55, "UVW + Z", "six-step commutation\nZ = 7.62–7.65 Hz, one per turn"),
    (8.7, 3.75, "SPI slave", "32-bit angle word\nregister map, 2 Mbaud"),
    (12.75, 3.6, "UDP / 1 GbE", "28,672-point captures\n9,968 fps streaming"),
    (16.65, 3.35, "On-chip TFT UI", "1024×600 touch\n4 diagnostic pages"),
]
for x, w, title, sub in outs:
    rect(x, 13.15, w, 1.45, WHITE)
    text(x + 0.22, 13.26, w - 0.4, 0.4, [[(title, {"bold": True, "size": 9.2, "color": TEAL})]])
    text(x + 0.22, 13.70, w - 0.4, 0.8, [[(sub, {"size": 7.9, "color": MUTED})]])

# ------------------------------------------------------------------ results
section(1.0, 14.85, 19.0, "Board-verified results — v90 production bitstream")

tiles = [
    ("2,048", "pulses / rev", "2,048 distinct counts measured\nacross a full turn"),
    ("15.63", "kHz electrical", "sin/cos at 458 rpm;\n≈800 samples per cycle"),
    ("457–459", "rpm", "7.62–7.65 Hz mechanical,\none Z per turn"),
    ("597,886", "frames / 60 s", "9,964.8 fps Ethernet soak,\nradius drift < 0.02 %"),
]
for i, (num, unit, cap) in enumerate(tiles):
    x = 1.0 + i * 4.8
    rect(x, 15.52, 4.55, 2.25, WHITE)
    text(x + 0.25, 15.62, 4.05, 0.7,
         [[(num, {"bold": True, "size": 19.5, "color": NAVY})]])
    text(x + 0.25, 16.28, 4.05, 0.35,
         [[(unit, {"size": 8.8, "bold": True, "color": TEAL})]])
    text(x + 0.25, 16.70, 4.05, 1.0, [[(cap, {"size": 7.9, "color": MUTED})]])

rect(1.0, 18.02, 10.4, 3.30, WHITE)
rows = [
    ("Timing, 50 MHz", "WNS +0.199 ns  ·  WHS +0.017 ns  ·  0 failing endpoints (24,691)"),
    ("Logic", "10,978 LUT (52.78 %)  ·  8,724 FF (20.97 %)  ·  17 DSP"),
    ("Memory", "32 / 50 BRAM  ·  single clock  ·  DRC 0 errors"),
    ("Bitstream", "1,504,220 B  ·  SHA A89512A5…F827125  ·  build 0x0019"),
    ("Latency", "41.5 cycles ≈ 830 ns, sample to angle (design budget)"),
]
for i, (k, v) in enumerate(rows):
    yy = 18.16 + i * 0.62
    text(1.28, yy, 2.7, 0.45, [[(k, {"bold": True, "size": 8.3, "color": NAVY})]])
    text(3.95, yy, 7.2, 0.45, [[(v, {"size": 8.3, "color": INK})]])
    if i < len(rows) - 1:
        ln = shapes.add_shape(MSO_SHAPE.RECTANGLE, Cm(1.25), Cm(yy + 0.55), Cm(9.9), Cm(0.02))
        ln.fill.solid()
        ln.fill.fore_color.rgb = LINE
        ln.line.fill.background()

rect(11.75, 18.02, 8.25, 3.30, NAVY)
text(12.0, 18.14, 7.75, 0.4,
     [[("How it was proven", {"size": 9.0, "bold": True, "color": AMBER})]])
bullets(12.0, 18.55, 7.75, 2.7, [
    [("Two silent deadlocks ", {"bold": True, "color": WHITE}),
     ("on hardware: sign-extended phase at 32,768, and a swallowed reverse wrap at sector 0/5.",
      {"color": RGBColor(0xD7, 0xE2, 0xEE)})],
    [("Build-ID bisect: ", {"bold": True, "color": WHITE}),
     ("probe 0x0013 traced 10 s of silence to one step of −65,403 instead of +133.",
      {"color": RGBColor(0xD7, 0xE2, 0xEE)})],
    [("tb_acc2 ", {"bold": True, "color": WHITE}),
     ("reproduces 0 → 6 → 12 counts for 3,000 × +133 steps.",
      {"color": RGBColor(0xD7, 0xE2, 0xEE)})],
], size=7.7, gap=3.5)

# ------------------------------------------------------------------ innovations / reproducibility
section(1.0, 21.60, 9.1, "What is new")
rect(1.0, 22.28, 9.1, 4.95)
bullets(1.33, 22.45, 8.5, 4.6, [
    [("Closed-form 6-parameter calibration", {"bold": True}),
     (" — one pass, no lookup table, no host iteration.", {})],
    [("Wrap-safe incremental unwrapping", {"bold": True}),
     (" — direction and multi-turn count survive every 0/2π crossing.", {})],
    [("Symmetric forward/reverse UVW", {"bold": True}),
     (" — a wide-base branch makes the 0→5 sector edge identical both ways.", {})],
    [("Single clock, no MMCM, no soft-core", {"bold": True}),
     (" — 41.5 cycles sample-to-angle, deterministic.", {})],
    [("Self-hosted diagnostics", {"bold": True}),
     (" — 1024×600 touch UI, 1 GbE capture, ILA and register map.", {})],
], size=8.9, gap=4.2)

section(11.2, 21.60, 8.8, "Reproducibility & evidence")
rect(11.2, 22.28, 8.8, 4.95)
bullets(11.53, 22.45, 8.2, 4.6, [
    [("MIT-licensed repository", {"bold": True}),
     (": RTL, constraints, host tools, testbenches and the full 29-page report.", {})],
    [("320 evidence files, 323 SHA-256 lines", {"bold": True}),
     (" — every number here traces to a report, log or bitstream.", {})],
    [("57 simulation benches", {"bold": True}),
     (" plus one-command sign-off: final_verify.ps1 checks sources, timing, bitstream SHAs, documents.", {})],
    [("LLM-collaboration log and skills package", {"bold": True}),
     (" recording how the two deadlocks were found and fixed.", {})],
], size=8.6, gap=5.0)

# ------------------------------------------------------------------ footer
foot = shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, Cm(27.95), prs.slide_width, Cm(1.75))
foot.fill.solid()
foot.fill.fore_color.rgb = NAVY
foot.line.fill.background()
foot.shadow.inherit = False
text(1.0, 28.12, 13.0, 1.3, [
    [("Independent Topic (Junior Group)   ·   XC7A35T-FGG484-2   ·   single 50 MHz clock domain",
      {"size": 8.0, "color": RGBColor(0xB9, 0xCB, 0xDD)})],
    [("Technical report (17 pp) and design report (29 pp) ship with the entry.",
      {"size": 7.2, "color": RGBColor(0x8F, 0xA8, 0xC2)})],
], space_after=2)
text(13.8, 28.12, 6.2, 1.0,
     [[("2026-11-04 submission", {"size": 7.2, "color": RGBColor(0x8F, 0xA8, 0xC2)})]],
     align=PP_ALIGN.RIGHT)

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
print("saved", OUT, OUT.stat().st_size, "B")
