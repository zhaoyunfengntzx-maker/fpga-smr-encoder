# -*- coding: utf-8 -*-
"""程序化动效生成器（v2）—— 给 3 分钟演示视频用的 CG 素材。

设计原则
--------
1. 每一种"特效"必须解释一个工程事实（延迟、级数、占比），不做无意义的光效。
2. 数据驱动：段宽 = 该级实际拍数，观众一眼能看出 CORDIC 占了近一半延迟。
3. 输出 1920x1080 / 25 fps / H.264 yuv420p，可直接拖进剪映当上层素材。

生成：
  deliverables/video/assets/cg_pipeline_41_5.mp4   8 s  41.5 拍延迟标尺（8 级比例条 + 点阵流动）
  deliverables/video/assets/cg_title.mp4           4 s  片头标题（可当 0:00 开场）
  deliverables/video/assets/cg_deadlock_card.mp4   6 s  死锁四步定位卡片（镜头 22）
  deliverables/video/assets/cg_counters.mp4        6 s  数字滚动（1273x / 176x / 0.009°）

用法：
  E:\\Anaconda\\python.exe tools\\make_cg_assets.py            # 全部生成
  E:\\Anaconda\\python.exe tools\\make_cg_assets.py pipeline   # 只生成某一段
  set RG_OUT=D:\\temp\\out && python tools\\make_cg_assets.py  # 改输出目录（默认 deliverables/video/assets）

依赖：Pillow、imageio-ffmpeg（Anaconda 已自带）。
"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont
import imageio_ffmpeg

W, H, FPS = 1920, 1080, 25
NAVY = (9, 14, 24)
INK = (240, 244, 250)
DIM = (122, 138, 160)
FAINT = (48, 62, 84)
AMBER = (232, 168, 74)
BLUE = (86, 150, 220)
RED = (226, 96, 86)
GREEN = (94, 200, 150)

FONT_DIR = r"C:\Windows\Fonts"


def _f(name, size):
    p = os.path.join(FONT_DIR, name)
    if not os.path.exists(p):
        p = os.path.join(FONT_DIR, "msyh.ttc")
    return ImageFont.truetype(p, size)


F_TITLE = _f("msyhbd.ttc", 76)
F_H1 = _f("msyhbd.ttc", 40)
F_H2 = _f("msyh.ttc", 26)
F_SM = _f("msyh.ttc", 21)
F_XS = _f("msyh.ttc", 18)
F_NUM = _f("consola.ttf", 40)
F_NUM_S = _f("consola.ttf", 22)

OUT = os.environ.get("RG_OUT") or os.path.join("deliverables", "video", "assets")
FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()


# ----------------------------------------------------------------------------- 基础图层
def _background():
    """深色底 + 极淡网格 + 四角压暗，做成 RGBA，一次算好复用。"""
    im = Image.new("RGB", (W, H), NAVY)
    d = ImageDraw.Draw(im)
    for x in range(0, W, 60):
        d.line([(x, 0), (x, H)], fill=(13, 20, 32))
    for y in range(0, H, 60):
        d.line([(0, y), (W, y)], fill=(13, 20, 32))
    # 中央柔光
    glow = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * 0.15, -H * 0.25, W * 0.85, H * 0.95], fill=26)
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    im = Image.composite(Image.new("RGB", (W, H), (26, 38, 60)), im, glow)
    # 暗角
    vig = Image.new("L", (W, H), 0)
    vd = ImageDraw.Draw(vig)
    vd.ellipse([-W * 0.25, -H * 0.45, W * 1.25, H * 1.45], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(200))
    dark = Image.new("RGB", (W, H), (4, 6, 10))
    im = Image.composite(im, dark, vig)
    return im.convert("RGB")


BG = _background()


def new_frame():
    return BG.copy(), Image.new("RGB", (W, H), (0, 0, 0))


def bloom(im, layer, radius=16):
    """把发光层高斯模糊后**加**上去——所有"高级感"都来自这一步（加性叠光，不需要 alpha）。"""
    if radius <= 0:
        return ImageChops.add(im, layer)
    return ImageChops.add(im, layer.filter(ImageFilter.GaussianBlur(radius)))


def ease(x):
    x = max(0.0, min(1.0, x))
    return 1 - (1 - x) ** 3


def lerp(a, b, p):
    return a + (b - a) * p


def rgba4(c, a):
    """兼容旧调用名（当前实现与 rgba 相同，均为三元组）。"""
    return rgba(c, a)


def rgba(c, a):
    """按 alpha 混向背景色：在暗底上得到"淡入"效果，且只需 RGB 三元组。"""
    p = max(0.0, min(1.0, a / 255.0))
    return tuple(int(NAVY[i] + (c[i] - NAVY[i]) * p) for i in range(3))


def text(d, xy, s, f, fill=INK, anchor="la"):
    d.text(xy, s, font=f, fill=fill, anchor=anchor)


# ----------------------------------------------------------------------------- 片段 1：41.5 拍
SEGS = [
    ("ADC", "内部延时（估计）", 7.0, AMBER),
    ("捕获", "同步 + 补码", 3.0, BLUE),
    ("÷4", "抽取平均", 2.0, BLUE),
    ("校正", "六参数", 3.0, BLUE),
    ("CORDIC", "17 级全流水", 19.0, AMBER),
    ("PI", "Ⅱ 型环路", 3.0, BLUE),
    ("ABZ", "边沿生成", 3.0, BLUE),
    ("输出", "", 1.5, BLUE),
]
TOTAL_CYCLES = sum(s[2] for s in SEGS)  # 41.5
X0, X1 = 150, 1770
BAR_Y, BAR_H = 400, 176


def _seg_x(c):
    return X0 + (X1 - X0) * c / TOTAL_CYCLES


def frame_pipeline(i, n):
    t = i / FPS
    dur = n / FPS
    im, glow = new_frame()
    gd = ImageDraw.Draw(glow)
    d = ImageDraw.Draw(im)

    # —— 点阵时间参数
    DT = 0.105          # 每个点进入间隔
    TRAVEL = 3.4        # 从 0 走到 41.5 的时间
    NDOT = int(TOTAL_CYCLES) + 1

    # —— 标题
    a_in = ease((t - 0.05) / 0.5)
    if a_in > 0:
        text(d, (X0, 86), "41.5 拍", F_TITLE, rgba(INK, 255 * a_in))
        text(d, (X0, 204), "≈ 830 ns   @ 50 MHz", F_H1, rgba(AMBER, 255 * a_in))
        text(d, (X0, 266), "单一 50 MHz 时钟域 · 无 MMCM · 无 CDC · 每一拍都可解释", F_SM, rgba(DIM, 235 * a_in))

    # —— 累计拍数（右上角）
    cyc = min(TOTAL_CYCLES, max(0.0, (t - DT) / TRAVEL * TOTAL_CYCLES))
    s_val = "%04.1f" % cyc
    d.text((X1, 116), "cycles", font=F_SM, fill=rgba(DIM, 220), anchor="ra")
    d.text((X1, 140), s_val, font=_f("consola.ttf", 64), fill=rgba(INK, 245), anchor="ra")

    # —— 比例条（段宽 = 该级真实拍数）
    c = 0.0
    for name, sub, w, col in SEGS:
        x_a, x_b = _seg_x(c), _seg_x(c + w)
        c += w
        box = [x_a + 3, BAR_Y, x_b - 3, BAR_Y + BAR_H]
        d.rectangle(box, fill=(19, 28, 43))
        d.rectangle(box, outline=(52, 68, 92), width=2)
        cx = (box[0] + box[2]) / 2
        d.text((cx, BAR_Y + 30), name, font=F_XS, fill=rgba(DIM, 235), anchor="ma")
        big = "%g" % w
        d.text((cx, BAR_Y + 132), big, font=_f("consola.ttf", 42 if w >= 3 else 23),
               fill=rgba(INK, 240), anchor="mm")

    # —— 流动的点
    active = [None] * len(SEGS)
    for k in range(NDOT):
        tk = t - DT - k * 0.105
        if tk < 0 or tk > TRAVEL:
            continue
        p = tk / TRAVEL
        cyc_dot = p * TOTAL_CYCLES
        x = _seg_x(cyc_dot)
        y = BAR_Y + 86
        col = AMBER if cyc_dot < 7.0 else (255, 255, 255)
        # 拖影
        for g in range(1, 4):
            xg = _seg_x(max(0.0, cyc_dot - g * 0.55))
            gd.ellipse([xg - 9, y - 9, xg + 9, y + 9], fill=rgba(col, 46 - g * 10))
        gd.ellipse([x - 16, y - 16, x + 16, y + 16], fill=rgba(col, 130))
        d.ellipse([x - 5, y - 5, x + 5, y + 5], fill=rgba(col, 255))
        # 记录当前点所在段，用于高亮
        cc = 0.0
        for si, (name, sub, w, scol) in enumerate(SEGS):
            if cc <= cyc_dot < cc + w:
                active[si] = (x, y, scol)
                break
            cc += w

    # —— 所在段高亮
    c = 0.0
    for si, (name, sub, w, col) in enumerate(SEGS):
        x_a, x_b = _seg_x(c), _seg_x(c + w)
        c += w
        if active[si] is not None:
            gd.rectangle([x_a + 3, BAR_Y, x_b - 3, BAR_Y + BAR_H], fill=rgba(col, 40))
            d.rectangle([x_a + 2, BAR_Y, x_b - 2, BAR_Y + BAR_H], outline=rgba(col, 235), width=3)

    # —— 底部标尺
    ry = BAR_Y + BAR_H + 44
    d.line([(_seg_x(0), ry), (_seg_x(TOTAL_CYCLES), ry)], fill=rgba(FAINT, 255), width=2)
    cc = 0.0
    for name, sub, w, col in SEGS:
        xx = _seg_x(cc)
        d.line([(xx, ry - 7), (xx, ry + 7)], fill=rgba(FAINT, 255), width=2)
        cc += w
    d.line([(_seg_x(TOTAL_CYCLES), ry - 12), (_seg_x(TOTAL_CYCLES), ry + 12)], fill=rgba(INK, 255), width=3)
    d.text((_seg_x(TOTAL_CYCLES), ry + 16), "41.5", font=F_NUM_S, fill=rgba(DIM, 240), anchor="ma")
    d.text((_seg_x(0), ry + 16), "0", font=F_NUM_S, fill=rgba(DIM, 240), anchor="ma")
    d.text((_seg_x(0), ry + 52), "段宽 = 该级实际拍数（采集 3 · 抽取 2 · 校正 3 · CORDIC 17 级 = 19 拍 · 环路 3 · ABZ 3）",
           font=F_XS, fill=rgba(DIM, 200))

    # —— 结论句
    if t > 4.6:
        aa = ease((t - 4.6) / 0.6)
        text(d, (X0, 790), "延迟是设计常数，不是调出来的", F_H1, rgba(INK, 245 * aa))
        text(d, (X0, 842), "ADC 内部 7 拍为估算（手册未给），其余每级在 RTL 里可数", F_SM, rgba(DIM, 230 * aa))
        text(d, (X1, 798), "TW28 ≈ 1.5 µs", F_H2, rgba(DIM, 220 * aa), anchor="ra")

    im = bloom(im, glow, 18)
    d = ImageDraw.Draw(im)
    # 收尾淡出
    a_out = 1.0 - ease((t - (dur - 0.45)) / 0.45)
    if a_out < 1.0:
        im = Image.blend(Image.new("RGB", (W, H), NAVY), im.convert("RGB"), max(0.0, a_out))
    return im.convert("RGB")


# ----------------------------------------------------------------------------- 片段 2：片头
def frame_title(i, n):
    t = i / FPS
    dur = n / FPS
    im, glow = new_frame()
    gd = ImageDraw.Draw(glow)
    d = ImageDraw.Draw(im)
    a = ease(t / 0.8)
    # 一条缓慢扩张的光带
    yy = 470
    for k in range(3):
        wdt = 240 + 60 * k
        gd.ellipse([W / 2 - wdt * 6, yy - 4, W / 2 + wdt * 6, yy + 4], fill=rgba(AMBER, 70 - 18 * k))
    text(d, (W / 2, 300), "2048 个刻度", F_TITLE, rgba(INK, 255 * a), anchor="mm")
    d.line([(W / 2 - 430, 400), (W / 2 + 430, 400)], fill=rgba(AMBER, 110 * a), width=2)
    text(d, (W / 2, 462), "一块 Artix-7", _f("msyh.ttc", 54), rgba(DIM, 245 * a), anchor="mm")
    text(d, (W / 2, 566), "基于 FPGA 的细分编码器", F_H1, rgba(AMBER, 250 * a), anchor="mm")
    text(d, (W / 2, 720), "2048 周期/转  ·  16 bit 细分角度  ·  单 50 MHz 时钟域", F_SM, rgba(DIM, 210 * a), anchor="mm")
    im = bloom(im, glow, 20)
    d = ImageDraw.Draw(im)
    a_out = 1.0 - ease((t - (dur - 0.4)) / 0.4)
    if a_out < 1.0:
        im = Image.blend(Image.new("RGB", (W, H), NAVY), im.convert("RGB"), max(0.0, a_out))
    return im.convert("RGB")


# ----------------------------------------------------------------------------- 片段 3：死锁四步定位
STEPS = [
    ("①", "真机四观测量同时归零", "转速在转，计数恒 0"),
    ("②", "A/B 位流回退对比", "换回 v68 → 现象复现"),
    ("③", "探针位流抓内部信号", "wrap_p_raw 回绕方向反了"),
    ("④", "ModelSim 定向测试台", "BADSTEP step = -65403"),
]


def frame_deadlock(i, n):
    t = i / FPS
    dur = n / FPS
    im, glow = new_frame()
    gd = ImageDraw.Draw(glow)
    d = ImageDraw.Draw(im)

    text(d, (150, 92), "真机上的一次静默死锁", F_H1, INK)
    text(d, (150, 158), "计数器恒 0 · 反向只剩三个扇区 · 没有任何报错", F_SM, DIM)
    y0 = 250
    for k, (num, title, sub) in enumerate(STEPS):
        ap = ease((t - 0.35 - k * 0.55) / 0.45)
        if ap <= 0:
            continue
        y = y0 + k * 150
        x = 150 + 40 * (1 - ap)
        box = [x, y, x + 760, y + 110]
        col = RED if k == 3 else BLUE
        gd.rectangle(box, fill=rgba(col, int(26 * ap)))
        d.rectangle(box, fill=rgba((18, 27, 42), int(240 * ap)), outline=rgba(col, int(210 * ap)), width=2)
        text(d, (x + 34, y + 55), num, _f("msyhbd.ttc", 40), rgba(col, int(250 * ap)), anchor="lm")
        text(d, (x + 96, y + 34), title, F_H2, rgba(INK, int(250 * ap)))
        text(d, (x + 96, y + 72), sub, F_SM, rgba(DIM, int(235 * ap)))
        # 连接线
        if k < len(STEPS) - 1:
            d.line([(x + 380, y + 112), (x + 380, y + 148)], fill=rgba(FAINT, int(200 * ap)), width=2)

    # 结论
    a = ease((t - 2.9) / 0.6)
    if a > 0:
        text(d, (1000, 300), "四步定位", F_H1, rgba(INK, 250 * a))
        text(d, (1000, 352), "每一步只回答一个问题", F_SM, rgba(DIM, 235 * a))
        text(d, (1000, 470), "-65403", _f("consola.ttf", 72), rgba(RED, 250 * a))
        text(d, (1000, 560), "一个 +133 的增量，", F_H2, rgba(INK, 240 * a))
        text(d, (1000, 600), "被当成 -65403 累加进去", F_H2, rgba(INK, 240 * a))
        text(d, (1000, 690), "根因：有符号扩展", F_SM, rgba(AMBER, 245 * a))
        text(d, (1000, 724), "修复：无符号差分 + 零扩展", F_SM, rgba(GREEN, 245 * a))
        text(d, (150, 900), "修复后连续流 30 min：反向误点火 0 次，计数器不再静默归零", F_SM, rgba(DIM, 220 * a))

    im = bloom(im, glow, 16)
    d = ImageDraw.Draw(im)
    a_out = 1.0 - ease((t - (dur - 0.4)) / 0.4)
    if a_out < 1.0:
        im = Image.blend(Image.new("RGB", (W, H), NAVY), im.convert("RGB"), max(0.0, a_out))
    return im.convert("RGB")


# ----------------------------------------------------------------------------- 片段 4：数字滚动
NUMS = [
    ("20.98°  →  0.0165°", "复合畸变校正", "1273 ×", AMBER),
    ("17.786%  →  0.101%", "板端李萨如圆度", "176 ×", BLUE),
    ("0.009° RMS", "角度跟踪残差", "", GREEN),
]


def frame_counters(i, n):
    t = i / FPS
    dur = n / FPS
    im, glow = new_frame()
    gd = ImageDraw.Draw(glow)
    d = ImageDraw.Draw(im)

    for k, (line, cap, big, col) in enumerate(NUMS):
        t0 = 0.3 + k * 1.5
        ap = ease((t - t0) / 0.5)
        if ap <= 0:
            continue
        y = 250 + k * 240
        gd.rectangle([140, y - 30, 1780, y + 142], fill=rgba(col, int(20 * ap)))
        text(d, (190, y + 10), line, _f("msyhbd.ttc", 62), rgba(INK, int(252 * ap)))
        text(d, (190, y + 88), cap, F_SM, rgba(DIM, int(235 * ap)))
        if big:
            text(d, (1760, y + 40), big, _f("msyhbd.ttc", 64), rgba(col, int(250 * ap)), anchor="ra")

    foot = ease((t - 3.6) / 0.5)
    if foot > 0:
        text(d, (190, 968), "1273× 为定点黄金模型（仿真结果）  ·  176× 与 0.009° 为板上实测", F_SM, rgba(DIM, 215 * foot))

    im = bloom(im, glow, 18)
    d = ImageDraw.Draw(im)
    a_out = 1.0 - ease((t - (dur - 0.4)) / 0.4)
    if a_out < 1.0:
        im = Image.blend(Image.new("RGB", (W, H), NAVY), im.convert("RGB"), max(0.0, a_out))
    return im.convert("RGB")


# ----------------------------------------------------------------------------- 编码
CLIPS = {
    "pipeline": ("cg_pipeline_41_5.mp4", frame_pipeline, 8.0),
    "title": ("cg_title.mp4", frame_title, 4.0),
    "deadlock": ("cg_deadlock_card.mp4", frame_deadlock, 6.0),
    "counters": ("cg_counters.mp4", frame_counters, 6.0),
}


def render(name, stills=True):
    fname, fn, secs = CLIPS[name]
    n = int(round(secs * FPS))
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, fname)
    cmd = [FFMPEG, "-y", "-loglevel", "error",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (W, H), "-r", str(FPS),
           "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "17",
           "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    shot = {int(n * 0.18), int(n * 0.42), int(n * 0.72), n - 2}
    for i in range(n):
        img = fn(i, n)
        p.stdin.write(img.tobytes())
        if stills and i in shot:
            img.save(os.path.join(OUT, "_still_%s_%03d.png" % (name, i)))
    p.stdin.close()
    p.wait()
    print("OK  %-9s %5.1f s  %s" % (name, secs, out))


def check():
    """无文件输出的自检：文字是否重叠 + 画面缩略图，用于在无写权限的环境里验版式。"""
    print("=== 段落布局 ===")
    c = 0.0
    rows = {0: [], 1: []}
    for k, (name, sub, w, col) in enumerate(SEGS):
        x_a, x_b = _seg_x(c), _seg_x(c + w)
        c += w
        tw = F_H2.getbbox(name)[2]
        rows[k % 2].append((x_a + (x_b - x_a) / 2, tw, name, x_b - x_a))
        print("  %-7s 拍数%5.1f  x=%4.0f..%4.0f  宽%4.0f  名宽%3d  余量%5.1f" %
              (name, w, x_a, x_b, x_b - x_a, tw, (x_b - x_a) - tw))
    for par, items in rows.items():
        for i in range(len(items) - 1):
            gap = (items[i + 1][0] - items[i][0]) - (items[i][1] + items[i + 1][1]) / 2
            flag = "OK " if gap > 6 else "!! "
            print("  %s第%d行  %s | %s  间距 %5.1f px" % (flag, par, items[i][2], items[i + 1][2], gap))

    print("\n=== 缩略图 t=4.9s（pipeline）===")
    im = frame_pipeline(int(4.9 * FPS), 8 * FPS).convert("L").resize((96, 30))
    chars = " .:-=+*#%@"
    px = list(im.getdata())
    for y in range(30):
        line = "".join(chars[min(9, px[y * 96 + x] * 10 // 256)] for x in range(96))
        print("  " + line)
    print("\n=== 缩略图 deadlock t=4.0s ===")
    im = frame_deadlock(int(4.0 * FPS), 6 * FPS).convert("L").resize((96, 30))
    px = list(im.getdata())
    for y in range(30):
        line = "".join(chars[min(9, px[y * 96 + x] * 10 // 256)] for x in range(96))
        print("  " + line)


def main():
    which = sys.argv[1:]
    if which and which[0] == "check":
        check()
        return
    which = which or list(CLIPS)
    for name in which:
        if name not in CLIPS:
            print("unknown clip:", name)
            continue
        render(name)
    print("输出目录：", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
