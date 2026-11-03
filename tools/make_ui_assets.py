# -*- coding: utf-8 -*-
"""生成界面用的少量位图资源（阶段 3 Apple 视觉）。

为什么要有位图
--------------
Qt 的样式表画不出「圆角 + 内阴影 + 勾」这种复合图形（`QCheckBox::indicator` 一旦
设了 `background` 就不会再画勾），所以复选框和开关的"脸面"用两张小 PNG：
样式表里只写 `image: url(...)`，逻辑（`isChecked()` / `toggled`）完全不变。

为什么要有这个脚本
------------------
二进制资源不能是"谁也不知道怎么来的"东西：改配色时重跑一次即可。
所有图按 **4× 超采样再缩放** 画出来（PIL 不能抗锯齿地画圆角矩形），
并同时输出 `@2x`（Qt 样式表会自动优先取 `@2x`，非整数缩放的机器也不会糊）。

用法
----
    python tools\\make_ui_assets.py            # 重新生成 host/assets/img/*
"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "host", "assets", "img")

SS = 4                                   # 超采样倍数

# 与 host/theme.py 的令牌保持一致（改这两处要一起改）
BG_CARD = "#FFFFFF"
LINE_IN = "#C7C7CC"                      # 输入控件描边（Apple 的 separator 深一档）
ACCENT = "#0071E3"
SW_OFF = "#E5E5EA"
KNOB = "#FFFFFF"


def _save(img, name, factor):
    # 源图一律按 4× 画，缩到 1× 就是逻辑尺寸；factor=2 的那份源图本身已经是 2 倍像素，
    # 所以这里**只除超采样倍数**、不再乘 factor（乘了会得到 4×，@2x 就白做了）。
    _ = factor
    img = img.resize((max(1, img.width // SS), max(1, img.height // SS)), Image.LANCZOS)
    path = os.path.join(OUT, name)
    img.save(path)
    print("%-18s %dx%d  %d B" % (name, img.width, img.height, os.path.getsize(path)))


def checkbox(on, scale=1):
    """18×18 的 macOS 风格复选框：未勾=白底灰边，勾上=蓝底白勾。"""
    px = 18 * SS * scale
    b = 2 * SS * scale
    im = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([b // 2, b // 2, px - 1 - b // 2, px - 1 - b // 2],
                        radius=5 * SS * scale, fill=BG_CARD if not on else ACCENT,
                        outline=None if on else LINE_IN, width=b if not on else 0)
    if on:
        w = max(2, int(2.2 * SS * scale))
        pts = [(px * 0.26, px * 0.52), (px * 0.44, px * 0.70), (px * 0.75, px * 0.31)]
        d.line(pts, fill=KNOB, width=w, joint="curve")
        r = w // 2
        for x, y in (pts[0], pts[-1]):
            d.ellipse([x - r, y - r, x + r, y + r], fill=KNOB)
    return im


def switch(on, scale=1):
    """36×20 的开关：底槽 + 白圆钮（未勾=灰槽，勾上=蓝槽、钮在右）。"""
    w, h = 36 * SS * scale, 20 * SS * scale
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=h // 2, fill=ACCENT if on else SW_OFF)
    d0 = h - 6 * SS * scale
    x0 = (w - d0 - 3 * SS * scale) if on else 3 * SS * scale
    y0 = (h - d0) // 2
    d.ellipse([x0, y0, x0 + d0, y0 + d0], fill=KNOB)
    return im


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    for scale, suffix in ((1, ""), (2, "@2x")):
        _save(checkbox(False, scale), "chk_off%s.png" % suffix, scale)
        _save(checkbox(True, scale), "chk_on%s.png" % suffix, scale)
        _save(switch(False, scale), "sw_off%s.png" % suffix, scale)
        _save(switch(True, scale), "sw_on%s.png" % suffix, scale)
    print("输出目录：%s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
