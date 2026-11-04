#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
font_raster.py -- 把矢量字体栅格化成 font_rom.v 需要的"行位图"

为什么不再用 5x7 点阵放大：
  5x7 放大 6 倍 = 每个笔画都是 6x6 的方块，1024 宽的屏上肉眼一看就是"马赛克"。
  字形的分辨率必须来自**该尺寸下的原生栅格化**，而不是小点阵的整数放大。

为什么不在运行时缩放：
  disp_engine 的纪律是"像素路径 <= 4 级 LUT"。运行期做 (x,y)/S 会引入除法器。
  所以栅格化放在生成阶段，ROM 里存的仍然是"每个字 cell_h 行、每行 row_w bit、
  左对齐（bit(row_w-1) = 字形最左列）"——与 v1 完全相同的接口，RTL 一行不改。

与 gen_font_rom.py 的契约：
  rows(ch, cell_w, cell_h, box_w, box_h) -> list[int]，长度 = cell_h，
  每个整数 < 2**cell_w，bit(cell_w-1) 是最左像素。

字体选择：
  数值层要"高但不胖"（格宽 30、格高 48），所以用 Arial Narrow Bold；
  汉字仍是 16x16 点阵，不走这里。
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover
    sys.stderr.write("需要 Pillow: pip install pillow\n")
    raise

# 常用字体路径（Windows）。按优先级探测，缺失就往后找。
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\ARIALBD.TTF",   # Arial Bold：数字墨迹 ≈ 0.48 em 宽，30x48 正好填满
    r"C:\Windows\Fonts\ARIALNB.TTF",   # Arial Narrow Bold：退路（窄，字距会显得松）
    r"C:\Windows\Fonts\consolab.ttf",  # Consolas Bold：等宽退路
]

# 这些字符不在字体里好用，或者画出来会糊，改用程序化绘制。
PROCEDURAL = set("●○▲✖↩^")


def pick_font():
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    raise SystemExit("找不到可用字体，试过: %s" % ", ".join(FONT_CANDIDATES))


class Raster(object):
    """按固定字号栅格化一族字符，输出行位图。"""

    def __init__(self, path=None, refs="0123456789ABZREVHWKNM", box=None, thr=110):
        self.path = path or pick_font()
        self.refs = refs
        self.box = box
        self.size = None
        self.font = None
        self.ascent = None
        self.thr = thr            # 二值化阈值：楷体这类细笔画字体要调低，否则掉笔画
        self.ink_top0 = None      # '0' 的墨迹顶相对基线的偏移（负值），用来对基线

    # -- 内部：画一张灰度图，返回 (img, draw) --------------------------------
    def _canvas(self, w, h):
        img = Image.new("L", (w, h), 0)
        return img, ImageDraw.Draw(img)

    def _ink(self, ch, size, pad=8):
        """把 ch 画到一块够大的画布上，返回 (mask, ox, oy)：墨迹的紧凑包围盒与偏移。"""
        font = ImageFont.truetype(self.path, size)
        tmp_w, tmp_h = size * 3 + 32, size * 2 + 32
        img, d = self._canvas(tmp_w, tmp_h)
        ox = tmp_w // 3
        base = tmp_h * 2 // 3
        d.text((ox, base), ch, font=font, fill=255, anchor="ls")
        bb = img.getbbox()
        if bb is None:
            return None, 0, 0
        crop = img.crop(bb)
        return crop, bb[0] - ox, bb[1] - base

    def fit(self, box_w, box_h):
        """选一个能塞进 box 的最大字号（对所有参考字符同时成立）。"""
        best = None
        for size in range(6, 160):
            ok = True
            for ch in self.refs:
                m, _, _ = self._ink(ch, size)
                if m is None:
                    continue
                if m.size[0] > box_w or m.size[1] > box_h:
                    ok = False
                    break
            if ok:
                best = size
            else:
                break
        if best is None:
            raise SystemExit("无法在 %dx%d 内排下任何字号" % (box_w, box_h))
        self.size = best
        self.font = ImageFont.truetype(self.path, best)
        a, dd = self.font.getmetrics()
        self.ascent, self.descent = a, dd
        return best

    def fit_chars(self, chars, box_w, box_h):
        """选一个**对整族字符统一**的最大字号：所有字都必须塞进 box_w x box_h。

        为什么必须统一：v58 第一版是逐字 fit（哪个字宽了就把哪个字压窄），
        结果同一个数字表里 '4' 只有 41 px 高、'1' 被横向拉成 30 px 宽，
        基线也对不齐（`tb_font_rom` 的等高度判据当场抓出来了）。
        字号只能由"整族里最宽的那个字"决定，之后谁也不许单独缩放 ——
        这是等宽数字表（tabular figures）在点阵字库里的前提。
        """
        best = None
        for size in range(6, 160):
            ok = True
            for ch in chars:
                m, _, _ = self._ink(ch, size)
                if m is None:
                    continue
                if m.size[0] > box_w or m.size[1] > box_h:
                    ok = False
                    break
            if ok:
                best = size
            else:
                break
        if best is None:
            raise SystemExit("无法在 %dx%d 内排下任何字号" % (box_w, box_h))
        self.size = best
        self.font = ImageFont.truetype(self.path, best)
        a, dd = self.font.getmetrics()
        self.ascent, self.descent = a, dd
        return best

    # -- 程序化符号 ---------------------------------------------------------
    def _proc(self, ch, box_w, box_h):
        """程序化符号：**只画在墨迹框 (box_w x box_h) 内**。

        ★ v60（T3）：以前这里收的是整格 (30x64)，半径按格高算 ⇒ 圆的直径超过
          30 px 的格宽，左右被裁掉（上板照片里 A/B/Z 后面的圆"缺角"）。
          现在半径一律取 min(box_w, box_h)，并留 2 px 余量。
        """
        img, d = self._canvas(box_w, box_h)
        cx, cy = box_w // 2, box_h // 2
        stroke = max(2, box_h // 12)
        r = max(3, min(box_w, box_h) // 2 - 2)
        if ch == "●":
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
        elif ch == "○":
            w = max(2, stroke // 2 + 1)
            rr = r - w // 2
            d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=255, width=w)
        elif ch == "▲":
            d.polygon([(cx, cy - r), (cx - r, cy + r * 2 // 3),
                       (cx + r, cy + r * 2 // 3)], fill=255)
        elif ch == "✖":
            rr = int(r * 0.85)
            d.line([cx - rr, cy - rr, cx + rr, cy + rr], fill=255, width=stroke)
            d.line([cx - rr, cy + rr, cx + rr, cy - rr], fill=255, width=stroke)
        elif ch == "↩":
            d.line([cx + r, cy - r, cx - r, cy - r], fill=255, width=stroke)
            d.line([cx - r, cy - r, cx - r, cy + r // 2], fill=255, width=stroke)
            d.polygon([(cx - r, cy + r // 2), (cx - r - stroke, cy + r // 2 - stroke * 2),
                       (cx - r + stroke, cy + r // 2 - stroke * 2)], fill=255)
        elif ch == "^":  # 度符号：小空心圈，放在上标位置
            rr = max(2, box_h // 9)
            w = max(1, stroke // 2)
            ex, ey = int(box_w * 0.62), int(box_h * 0.22)
            d.ellipse([ex - rr, ey - rr, ex + rr, ey + rr], outline=255, width=w)
        return img

    # -- 对外：给一个字，返回 cell_h 行位图 ---------------------------------
    def rows(self, ch, cell_w, cell_h, box_w=None, box_h=None,
             y_off=None, x_off=None, fill_w=None):
        """box_w/box_h = 允许的墨迹尺寸；y_off/x_off = 墨迹在格内的左上角。

        fill_w = 横向拉伸目标宽度（只对"本来就比较宽"的字生效，见 THIN 阈值），
        用来把窄字体的字距收紧 —— 否则 ASCII 落在 16px 的汉字格里会显得散。
        """
        if box_w is None:
            box_w = cell_w
        if box_h is None:
            box_h = cell_h
        if y_off is None:
            y_off = (cell_h - box_h) // 2
        if x_off is None:
            x_off = (cell_w - box_w) // 2

        if ch == " ":
            return [0] * cell_h

        # 字号必须先按"**数字族**统一"定下来：数字表要求 0..9 同高同宽，
        # 所以字号只由 0..9 里最宽的那个决定。宽字母（M/W）与 '%' 不参与定字号，
        # 它们超出格子时按等比缩小（见下），否则会把整族数字压到 22 px。
        if self.size is None:
            self.fit_chars("0123456789", box_w, box_h)

        if ch in PROCEDURAL or not self._has(ch):
            img = self._proc(ch, box_w, box_h)
        else:
            mask, lsb, ink_top = self._ink(ch, self.size)
            if mask is None:
                return [0] * cell_h
            iw, ih = mask.size
            if self.ink_top0 is None:
                _, _, self.ink_top0 = self._ink("0", self.size)
            # 数字与符号一律不缩放（这是等宽数字表的前提，`tb_font_rom` 会验）。
            # 只有**本身比格子还宽**的字母（M/W/@ 等）才按等比缩小 —— 缩的是
            # 整个字形，不是只压宽度，所以它的比例不会走形。
            if iw > box_w or ih > box_h:
                k = min(box_w / float(iw), box_h / float(ih))
                iw, ih = max(1, int(round(iw * k))), max(1, int(round(ih * k)))
                mask = mask.resize((iw, ih), Image.LANCZOS)
            # ★ v60（T4）：**不再**把窄数字横向拉到 0.85 格宽。
            #   用户上板反馈"同一行数字有粗有细"就是这一步造成的：'1' 被拉宽
            #   ⇒ 竖笔变粗，而 '0'/'8' 保持原样。等宽数字的前提是同一字号、
            #   同一比例；字距的观感交给格宽（32 px）与居中即可。
            # 水平：墨迹居中（等宽进格）；数字表的字宽由字体决定，不拉不压。
            px_ = x_off + (box_w - iw) // 2
            px_ = max(0, min(cell_w - iw, px_))
            # 垂直按**基线**对齐：'.' '-' 这类小字要坐在基线上，不能顶到格顶。
            py_ = y_off + (ink_top - self.ink_top0)
            py_ = max(0, min(cell_h - ih, py_))
            img = Image.new("L", (cell_w, cell_h), 0)
            img.paste(mask, (px_, py_))

        if ch in PROCEDURAL and (y_off or x_off):
            base = Image.new("L", (cell_w, cell_h), 0)
            base.paste(img, (x_off, y_off))
            img = base

        px = img.load()
        out = []
        thr = self.thr
        for y in range(cell_h):
            v = 0
            for x in range(cell_w):
                v = (v << 1) | (1 if px[x, y] >= thr else 0)
            out.append(v)
        return out

    def _has(self, ch):
        if self.size is None:
            self.fit(self.box[0], self.box[1])
        m, _, _ = self._ink(ch, self.size)
        return m is not None


def contact_sheet(raster, chars, cell_w, cell_h, **kw):
    """把 rows() 的结果画成 1:1 的点阵图，用于人眼验收字模。"""
    pad = 6
    cols = 13
    rows = (len(chars) + cols - 1) // cols
    W = cols * (cell_w + pad) + pad
    H = rows * (cell_h + pad) + pad
    img = Image.new("RGB", (W, H), (18, 18, 22))
    d = ImageDraw.Draw(img)
    for i, ch in enumerate(chars):
        r = raster.rows(ch, cell_w, cell_h, **kw)
        gx = pad + (i % cols) * (cell_w + pad)
        gy = pad + (i // cols) * (cell_h + pad)
        for y, v in enumerate(r):
            for x in range(cell_w):
                if (v >> (cell_w - 1 - x)) & 1:
                    d.point((gx + x, gy + y), fill=(255, 255, 255))
        d.rectangle([gx - 1, gy - 1, gx + cell_w, gy + cell_h], outline=(48, 48, 60))
    return img
