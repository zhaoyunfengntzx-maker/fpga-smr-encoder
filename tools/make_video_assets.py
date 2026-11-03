# -*- coding: utf-8 -*-
"""Generate CG assets for the 3-minute demo video.

Outputs (1920x1080, 25 fps, H.264):
  deliverables/video/assets/pipeline_41_5.mp4   8 s  cycle ruler 0 -> 41.5
  deliverables/video/assets/sys_grow.mp4        6 s  system diagram reveal
  deliverables/video/assets/end_card.mp4        5 s  title / end card
  deliverables/video/assets/card_title.png            title still
  deliverables/video/assets/card_end.png              end still
"""
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont
import imageio_ffmpeg

W, H, FPS = 1920, 1080, 25
NAVY = (11, 18, 32)
INK = (244, 247, 251)
DIM = (150, 164, 184)
AMBER = (222, 154, 54)
BLUE = (78, 140, 210)
RED = (214, 82, 74)
LINE = (52, 66, 88)

FONT_CN = r"C:\Windows\Fonts\msyh.ttc"
FONT_CN_B = r"C:\Windows\Fonts\msyhbd.ttc"
FONT_EN = r"C:\Windows\Fonts\times.ttf"
FONT_MONO = r"C:\Windows\Fonts\consola.ttf"

OUT = os.path.join("deliverables", "video", "assets")
TMP = os.path.join("_video_tmp")
FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()


def font(path, size):
    return ImageFont.truetype(path, size)


def text(d, xy, s, f, fill=INK, anchor="la"):
    d.text(xy, s, font=f, fill=fill, anchor=anchor)


def bg():
    im = Image.new("RGB", (W, H), NAVY)
    d = ImageDraw.Draw(im)
    # subtle vignette grid
    for x in range(0, W, 80):
        d.line([(x, 0), (x, H)], fill=(15, 24, 40), width=1)
    for y in range(0, H, 80):
        d.line([(0, y), (W, y)], fill=(15, 24, 40), width=1)
    return im, d


def encode(frames_dir, pattern, out_name, seconds):
    out = os.path.join(OUT, out_name)
    cmd = [
        FFMPEG, "-y", "-loglevel", "error",
        "-framerate", str(FPS), "-i", os.path.join(frames_dir, pattern),
        "-c:v", "libx264", "-preset", "medium", "-crf", "17",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", out,
    ]
    subprocess.run(cmd, check=True)
    print("saved", out, os.path.getsize(out), "bytes", seconds, "s")


def render_pipeline():
    """Cycle ruler: 0 -> 41.5 cycles, ADC 7 cycles highlighted, playhead sweep."""
    n = 8 * FPS
    a, b = 180, 1740            # ruler x
    scale = (b - a) / 41.5
    rx = lambda c: a + c * scale
    f_title = font(FONT_EN, 64)
    f_sub = font(FONT_CN, 30)
    f_lab = font(FONT_CN, 26)
    f_num = font(FONT_MONO, 120)
    f_small = font(FONT_CN, 22)

    frames = os.path.join(TMP, "pipeline")
    os.makedirs(frames, exist_ok=True)
    for i in range(n):
        t = i / (n - 1)
        # ease in-out
        e = 0.5 - 0.5 * __import__("math").cos(3.141592653589793 * min(1.0, t / 0.82))
        cur = 41.5 * e
        im, d = bg()
        text(d, (120, 80), "41.5 CYCLES  \u2248  830 ns", f_title, INK)
        text(d, (124, 175), "单时钟域流水线 · 50 MHz · 无 MMCM · 无 CDC", f_sub, DIM)

        y = 690
        # ruler base
        d.line([(a, y), (b, y)], fill=LINE, width=4)
        # ADC band 0..7 (red)
        d.rectangle([rx(0), y - 18, rx(7), y + 18], fill=(120, 44, 40))
        d.rectangle([rx(7), y - 18, b, y + 18], fill=(38, 62, 96))
        for c in range(0, 42):
            x = rx(c)
            hh = 16 if c % 5 == 0 else 9
            d.line([(x, y - hh), (x, y + hh)], fill=(110, 126, 148), width=2)
        # labels
        text(d, (rx(0) + 8, y + 34), "ADC 7 拍（估计）", f_small, (232, 150, 140))
        text(d, (rx(7) + 14, y + 34), "FPGA 流水线 34.5 拍", f_small, (150, 190, 230))

        # stage names above ruler (not to scale, equally spaced)
        stages = ["捕获", "÷4 抽取", "六参数校正", "CORDIC 17 级", "II 型 PI", "增量展开"]
        for k, s in enumerate(stages):
            x = rx(7) + (k + 0.5) * (b - rx(7)) / 6
            active = cur >= 7 + k * (34.5 / 6)
            d.ellipse([x - 7, y - 110, x + 7, y - 96], fill=(AMBER if active else (60, 74, 96)))
            text(d, (x, y - 135), s, f_lab, (INK if active else DIM), anchor="ma")

        # playhead
        px = rx(min(cur, 41.5))
        d.line([(px, y - 80), (px, y + 70)], fill=AMBER, width=5)
        d.ellipse([px - 12, y - 12, px + 12, y + 12], fill=AMBER)

        # counter
        text(d, (1800, 330), f"{cur:04.1f}", f_num, INK, anchor="ra")
        text(d, (1800, 210), "CYCLES", font(FONT_EN, 30), DIM, anchor="ra")
        text(d, (120, 1000), "设计预算：41.5 拍 × 20 ns = 830 ns（含 ADC 内部 7 拍估计）", f_sub, AMBER)
        im.save(os.path.join(frames, f"f{i:04d}.png"))
    encode(frames, "f%04d.png", "pipeline_41_5.mp4", 8)
    shutil.rmtree(frames, ignore_errors=True)


def render_sys_grow():
    """Reveal sys_arch_en.png with a left-to-right wipe + slight push-in."""
    src = Image.open(os.path.join("deliverables", "figures", "sys_arch_en.png")).convert("RGB")
    n = 6 * FPS
    frames = os.path.join(TMP, "sys")
    os.makedirs(frames, exist_ok=True)
    for i in range(n):
        t = i / (n - 1)
        e = 1 - (1 - t) ** 3
        im, d = bg()
        base_scale = min(1800 / src.width, 900 / src.height)
        zoom = 1.0 + 0.03 * t
        iw = int(src.width * base_scale * zoom)
        ih = int(src.height * base_scale * zoom)
        canvas = src.resize((iw, ih), Image.LANCZOS)
        x0 = (W - iw) // 2
        y0 = (H - ih) // 2
        base = Image.new("RGB", (W, H), (16, 24, 38))
        base.paste(canvas, (x0, y0))
        # wipe mask
        crop_w = int(e * W)
        mask = Image.new("L", (W, H), 0)
        ImageDraw.Draw(mask).rectangle([0, 0, crop_w, H], fill=255)
        im = Image.composite(base, im, mask)
        d = ImageDraw.Draw(im)
        if crop_w < W:
            d.line([(crop_w, 0), (crop_w, H)], fill=AMBER, width=6)
        im.save(os.path.join(frames, f"f{i:04d}.png"))
    encode(frames, "f%04d.png", "sys_grow.mp4", 6)
    shutil.rmtree(frames, ignore_errors=True)


def render_cards():
    # title card
    im, d = bg()
    text(d, (120, 300), "2048", font(FONT_EN, 300), INK)
    text(d, (680, 350), "个刻度", font(FONT_CN_B, 120), INK)
    d.line([(124, 660), (900, 660)], fill=AMBER, width=6)
    text(d, (124, 710), "基于FPGA的细分编码器", font(FONT_CN, 54), INK)
    text(d, (124, 790), "3 分钟演示 · 2026", font(FONT_CN, 28), DIM)
    im.save(os.path.join(OUT, "card_title.png"))

    # end card frames
    n = 5 * FPS
    frames = os.path.join(TMP, "end")
    os.makedirs(frames, exist_ok=True)
    for i in range(n):
        t = i / (n - 1)
        im, d = bg()
        alpha = min(1.0, t / 0.25)
        col = tuple(int(NAVY[k] + (INK[k] - NAVY[k]) * alpha) for k in range(3))
        text(d, (W // 2, 430), "基于FPGA的细分编码器", font(FONT_CN_B, 96), col, anchor="ma")
        text(d, (W // 2, 570), "2048 个刻度，一块 Artix-7", font(FONT_CN, 44),
             tuple(int(c * alpha) for c in AMBER), anchor="ma")
        if t > 0.5:
            text(d, (W // 2, 760), "技术文档 · 开源仓库 · 证据索引", font(FONT_CN, 26), DIM, anchor="ma")
        im.save(os.path.join(frames, f"f{i:04d}.png"))
    Image.open(os.path.join(frames, f"f{n-1:04d}.png")).save(os.path.join(OUT, "card_end.png"))
    encode(frames, "f%04d.png", "end_card.mp4", 5)
    shutil.rmtree(frames, ignore_errors=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(TMP, exist_ok=True)
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("all", "pipeline"):
        render_pipeline()
    if which in ("all", "sys"):
        render_sys_grow()
    if which in ("all", "cards"):
        render_cards()
    print("done")


if __name__ == "__main__":
    main()
