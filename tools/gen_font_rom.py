#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_font_rom.py -- 从 5x7 点阵 ASCII 图生成 Verilog 字库 ROM

为什么用手写 5x7 + 离线放大，而不是直接手写 8x16 十六进制：
  1. ASCII 图**人眼可验**。手写 8x16 十六进制看不出错，竞赛评审也看不出。
  2. 5x7 只存 7 行 x 5 位 = 35 bit/字，43 个字符 = 1505 bit。
  3. 放大在**生成阶段**离线做，不在像素路径上做。
     这一点是刻意的：如果运行时把 (x,y) 除以放大倍数，那个除法就会
     出现在像素路径里，直接违反 disp_engine 的"像素路径 <= 4 级 LUT"纪律。
     离线预放大后，像素路径仍然只是"一次 ROM 读"，与单尺寸字库完全一样。
     代价是每多一个尺寸就多一份点阵存储 —— 而 BRAM 恰恰是本设计最富裕的资源
     （50 个 RAMB36，骨架只用了 1.5 个）。

字符编码 = ASCII。只收录真正会用到的字符：
  空格 . - + / : = ^(度) 0-9 A-Z（另加 % × ÷ ↩ ● ▲ ✖ ○ 七个状态/运算符号），
  小写字母只收 k / z 两个 —— 频率单位按国家规范写作 **kHz**（小写 k、大写 H、
  小写 z：H 以赫兹 Hertz 命名故大写，词头"千" kilo 规定小写）。
  ★ k / z 不进 ASCII_CHARS，只挂在 lab 平面自己的尾巴上（LAB_EXTRA），
    理由与 ○ 相同：插进 ASCII 会把后面 132 个汉字码整体挪位。

输出：disp/font_rom.v
"""

import os
import sys

# 汉字点阵表：由 tools/make_cn_glyphs.py 一次性栅格化并冻结成 16x16 人眼可验的 art。
# 本脚本只负责按同一顺序把它铺进 ROM。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cn_glyphs import ART as CN_ART  # noqa: E402
from cn_glyphs import CHARS as CN_CHARS  # noqa: E402
from font_raster import Raster  # noqa: E402

# ===========================================================================
# 5x7 点阵源。每字 7 行、每行 5 列。'#' = 亮，'.' = 暗。
# ★ 只改这里，然后重新跑本脚本；不要手改 disp/font_rom.v（它会被覆盖）。
# ===========================================================================
G = {}


def _g(ch, art):
    rows = [r for r in art.strip("\n").split("\n")]
    assert len(rows) == 7, "glyph %r has %d rows, expected 7" % (ch, len(rows))
    for i, r in enumerate(rows):
        assert len(r) == 5, "glyph %r row %d has %d cols, expected 5: %r" % (ch, i, len(r), r)
        assert set(r) <= {"#", "."}, "glyph %r row %d has bad chars: %r" % (ch, i, r)
    G[ch] = rows


_g(" ", """
.....
.....
.....
.....
.....
.....
.....
""")

_g(".", """
.....
.....
.....
.....
.....
.##..
.##..
""")

_g("-", """
.....
.....
.....
#####
.....
.....
.....
""")

_g("+", """
.....
..#..
..#..
#####
..#..
..#..
.....
""")

_g("/", """
....#
....#
...##
..#..
.##..
#....
#....
""")

_g(":", """
.....
.##..
.##..
.....
.##..
.##..
.....
""")

_g("=", """
.....
.....
#####
.....
#####
.....
.....
""")

# '^' 当度符号用（屏上显示 45.0^）。小字符比新造一个字省事，也不占额外码位。
_g("^", """
.###.
.#.#.
.###.
.....
.....
.....
.....
""")

# v23 新增三个符号：百分号（规范 §7 的占比/幅值）、乘号（×64 / 回到 ×8）、
# 除号（÷1）。v24 又补了 ↩。四个都是 5x7 手写点阵 ——
# 与上方 44 个 ASCII 字模同一种做法。
# ★ 键名就是屏上要显示的字符本身，必须与 ASCII_CHARS 一一对应。
_g("%", """
##..#
##.#.
...#.
..#..
.#...
#..##
#..##
""")

_g("×", """
.....
#...#
.#.#.
..#..
.#.#.
#...#
.....
""")

_g("÷", """
.....
..#..
.....
#####
.....
..#..
.....
""")

# v24 新增：回车/撤销箭头（规范 §6.5「↩ 回到 ×N」的面板按钮标签）。
# 5x7 手写点阵，画法 = 左向箭头（横杆 + 两根斜刺）加右侧立柱，
# 也就是"回车键"上那个钩子的最简可读形式。
_g("↩", """
....#
.#..#
#####
.#..#
....#
.....
.....
""")


_g("0", """
.###.
#...#
#..##
#.#.#
##..#
#...#
.###.
""")

_g("1", """
..#..
.##..
..#..
..#..
..#..
..#..
.###.
""")

_g("2", """
.###.
#...#
....#
...#.
..#..
.#...
#####
""")

_g("3", """
#####
...#.
..#..
...#.
....#
#...#
.###.
""")

_g("4", """
...#.
..##.
.#.#.
#..#.
#####
...#.
...#.
""")

_g("5", """
#####
#....
####.
....#
....#
#...#
.###.
""")

_g("6", """
..##.
.#...
#....
####.
#...#
#...#
.###.
""")

_g("7", """
#####
....#
...#.
..#..
.#...
.#...
.#...
""")

_g("8", """
.###.
#...#
#...#
.###.
#...#
#...#
.###.
""")

_g("9", """
.###.
#...#
#...#
.####
....#
...#.
.##..
""")

_g("A", """
.###.
#...#
#...#
#####
#...#
#...#
#...#
""")

_g("B", """
####.
#...#
#...#
####.
#...#
#...#
####.
""")

_g("C", """
.###.
#...#
#....
#....
#....
#...#
.###.
""")

_g("D", """
###..
#..#.
#...#
#...#
#...#
#..#.
###..
""")

_g("E", """
#####
#....
#....
####.
#....
#....
#####
""")

_g("F", """
#####
#....
#....
####.
#....
#....
#....
""")

_g("G", """
.###.
#...#
#....
#..##
#...#
#...#
.###.
""")

_g("H", """
#...#
#...#
#...#
#####
#...#
#...#
#...#
""")

_g("I", """
.###.
..#..
..#..
..#..
..#..
..#..
.###.
""")

_g("J", """
....#
....#
....#
....#
#...#
#...#
.###.
""")

_g("K", """
#...#
#..#.
#.#..
##...
#.#..
#..#.
#...#
""")

_g("L", """
#....
#....
#....
#....
#....
#....
#####
""")

_g("M", """
#...#
##.##
#.#.#
#...#
#...#
#...#
#...#
""")

_g("N", """
#...#
##..#
#.#.#
#..##
#...#
#...#
#...#
""")

_g("O", """
.###.
#...#
#...#
#...#
#...#
#...#
.###.
""")

_g("P", """
####.
#...#
#...#
####.
#....
#....
#....
""")

_g("Q", """
.###.
#...#
#...#
#...#
#.#.#
#..#.
.##.#
""")

_g("R", """
####.
#...#
#...#
####.
#.#..
#..#.
#...#
""")

_g("S", """
.####
#....
#....
.###.
....#
....#
####.
""")

_g("T", """
#####
..#..
..#..
..#..
..#..
..#..
..#..
""")

_g("U", """
#...#
#...#
#...#
#...#
#...#
#...#
.###.
""")

_g("V", """
#...#
#...#
#...#
#...#
#...#
.#.#.
..#..
""")

_g("W", """
#...#
#...#
#...#
#.#.#
#.#.#
##.##
#...#
""")

_g("X", """
#...#
#...#
.#.#.
..#..
.#.#.
#...#
#...#
""")

_g("Y", """
#...#
#...#
.#.#.
..#..
..#..
..#..
..#..
""")

_g("Z", """
#####
....#
...#.
..#..
.#...
#....
#####
""")

_g("●", """
.....
.###.
#####
#####
#####
.###.
.....
""")

_g("▲", """
..#..
..#..
.###.
.###.
#####
#####
.....
""")

_g("✖", """
##.##
##.##
.###.
..#..
.###.
##.##
##.##
""")

# ★ v52（㊾）：○（空心圈）—— 卡 6 主值的"低电平"写法（spec §4.5 的
#   `A● B● Z○` / `U V W`）。原来只有实心 ●（索引 48），低电平只能写数字 0，
#   与"这一路是什么电平"读起来不像同一个符号系统。
#   ★ 只进 **val 平面**（`VAL_EXTRA`），不进 `ASCII_CHARS`：`CHARS = ASCII_CHARS +
#     CN_CHARS`，往 ASCII 里插一个字会让后面 132 个汉字码整体 +1，而 RTL 与 tb 里
#     按索引写死的汉字码有一百多处。挂到 val 平面自己的尾巴上 ⇒ val 码 51、汉字码不动。
#   ★ 标签层（lab 平面）也要这个字（卡 6 的次级行 `U● V● W○` 是标签层的 16x16 格），
#     所以再挂一个 `LAB_EXTRA`：接在**汉字之后** ⇒ lab 码 183。两个字面码不同
#     （val 51 / lab 183）不是笔误：两个平面各有自己的字符表与索引位宽，
#     ROM 也是两块（font_rom_val / font_rom_lab），RTL 里从不跨平面传码。
#     代价只是"同一个字有两个编号"，换来的是**汉字码一个都不动**。
_g("○", """
.###.
#...#
#...#
#...#
#...#
.###.
.....
""")

# ★ 2026-11：小写 k / z —— P1 卡 1 的单位从 `KHZ` 改成规范写法 `kHz`
#   （小写 k、大写 H、小写 z；H 是赫兹，按 SI 规定大写；"千"的词头 kilo 小写）。
#   字库原来只有大写 A-Z，`k`/`z` 两个字形都没有。
#   ★ 照样**不进 ASCII_CHARS**（理由见 ○ 那段：会把 132 个汉字码整体 +2），
#     只挂 lab 平面尾巴：接在 ○ 之后 ⇒ lab 码 184 = k、185 = z，汉字码 0..182 不动。
#   ★ 只有 lab 平面（标签层）要这两个字，val 平面（数值/单位大字）用不到，
#     所以 VAL_EXTRA 不变。
#   k 是上伸部（ascender，与 H 同高），z 只有 x 高 —— 下面的 5x7 图就是这个比例，
#   实际点阵由 font_raster 用 Arial Bold 在 11x14 框里原生栅格化，k 顶到框顶、
#   z 矮一截，两者共用 '0' 的基线（见 font_raster 的 ink_top0 对齐）。
_g("k", """
#....
#....
#..#.
#.#..
##...
#.#..
#..#.
""")

_g("z", """
.....
.....
#####
...#.
..#..
.#...
#####
""")

# 字符顺序 = 索引顺序。改这个列表会改变 RTL 里的字符索引，必须同步改 disp_engine.v。
# ★ v23：% / × / ÷ 三个符号**追加在末尾**（索引 44/45/46）——
#   插在中间会把 0-9、A-Z 的索引整体挪位，而 band_view.v / p5_view.v /
#   p2_badge.v / val_format.v 里那些 `CH_ZERO = 6'd8` 是按索引写死的。
#   ASCII_COUNT 47 ⇒ VAL_CODE_W 仍是 6 bit（上限 64），lab 码宽因汉字增多升到 8 bit。
# ★ v24：↩ 同样追加在末尾（索引 47）。
# ★ v31：● / ▲ / ✖ 三个状态字形追加在末尾（索引 48/49/50）—— spec §4.3 的
#   卡片迷你状态条与 §5.2 的"四重冗余"要求状态同时给**字形**，而 ● ▲ ✖ 既不是
#   汉字（不进 cn_glyphs.py，不必重跑字体栅格化）也不是原有 ASCII，所以在 ASCII
#   平面手写 5x7 点阵最省事：字库、两个生成器、RTL 一个字都不用动新机制。
#   这条也是"最后一次追加"的边界提醒 —— ASCII 已到 51 码，val 平面 6 bit 的上限
#   是 64，再加 13 个 ASCII 就得连 val 码宽一起升；而要再加汉字，先看 lab 8 bit
#   的余量（140/256）。
ASCII_CHARS = " .-+/:=^0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ%×÷↩●▲✖"
# ★ v52：只属于 val 平面的符号，接在 ASCII 之后 ⇒ val 码 51（汉字码不动）。
#   必须与 tools/gen_text_ram.py 的 VAL_EXTRA **逐字同序**。
VAL_EXTRA = "○"
# ★ v52：只属于 lab 平面的符号，接在**汉字之后** ⇒ lab 码 183 起（汉字码不动）。
#   ○ = 183（v52，卡 6 的 `Z○` 空心电平点），k = 184 / z = 185（2026-11，P1 单位 kHz）。
#   必须与 tools/gen_text_ram.py 的 LAB_EXTRA **逐字同序** —— 顺序一变 ○ 的码就跟着动，
#   而 disp/uv_state.v:68 的 `CH_LO = 8'd183` 是按码写死的。
LAB_EXTRA = "○kz"
CHARS = ASCII_CHARS + CN_CHARS
VAL_CHARS = ASCII_CHARS + VAL_EXTRA
LAB_CHARS = CHARS + LAB_EXTRA
ASCII_COUNT = len(ASCII_CHARS)
VAL_COUNT = len(VAL_CHARS)
LAB_COUNT = len(LAB_CHARS)
_ALL_GLYPHS = ASCII_CHARS + VAL_EXTRA + LAB_EXTRA
for c in _ALL_GLYPHS:
    assert c in G, "missing glyph for %r" % c
# 反向：G 里不许有字符表之外的字形（多一个字就会让下面的码位/断言对不上）。
assert set(G) == set(_ALL_GLYPHS), \
    "extra glyphs: %r" % (set(G) - set(_ALL_GLYPHS))
assert "".join(CN_ART.keys()) == CN_CHARS, "cn_glyphs.ART key order != CHARS"
for c, rows in CN_ART.items():
    assert len(rows) == 16 and all(len(r) == 16 for r in rows), \
        "cjk glyph %r is not 16x16" % c

# ASCII 字模的两档尺寸。每个尺寸绑定一个**格高**，行的数量就等于格高。
#
# ★ 为什么让行的数量等于"格高"而不是"字形高"：
#   这样 RTL 里的行地址就是**格内 y 坐标本身**（pix_y[3:0] 或 pix_y[5:0]），
#   像素路径上不需要任何加减、比较、钳位。字形之外的扫描行全部为 0。
#   代价是每字多存几行 0 —— 而 BRAM 恰恰是本设计最富裕的资源。
#   反面做法（存精确字形高 + RTL 里算偏移/钳位）会把一个 6 位比较器
#   放进像素路径，换来的只是省下不到 1 个 tile。
#
# y_off = 字形在格内的垂直居留偏移。水平方向一律左对齐（x_off = 0），
# 因为行位图的宽度就等于字形宽度，移位寄存器自然会把多余列输出成 0。
#
# ★ v58（R1）：字形不再由 5x7 点阵整数放大，改由 tools/font_raster.py 用
#   Arial Narrow Bold **按目标尺寸原生栅格化**。5x7 放大 6 倍的做法让每个笔画
#   变成 6x6 的方块（屏上看就是马赛克），原生栅格化后同一块 ROM 里放的是
#   "该尺寸下真实字形的点阵"，清晰度提升而 ROM 尺寸不变。
#   格高仍是 64（2 的幂 ⇒ 地址 = {ch_idx,row} 仍是纯拼接，RTL 一行不改），
#   30x48 的墨迹垂直居中在里面（y_off = 8）。
ASCII_SIZES = [
    # lab：16x16 格里放 11x14 的正文 —— Arial Bold 在这个尺寸上笔画最稳。
    dict(box_w=11, box_h=13, y_off=2, name="lab", row_w=16, fill_w=11,
         font=r"C:\Windows\Fonts\simkai.ttf", thr=70, refs="0123456789/"),
    # val：30x64 格里放 30x48 的大数字 —— Arial **Narrow** Bold 才能在
    #  cap 高 48 的同时把墨迹宽度压在 30 列以内（Arial Bold 会宽到 34 列，
    #  被逐字压扁后就出现"4 只有 41 px 高、1 被拉成 30 px 宽"的乱象）。
    dict(box_w=30, box_h=48, y_off=8, name="val", row_w=30, fill_w=30,
         font=r"C:\Windows\Fonts\simkai.ttf", thr=70),
]

import os as _os
_HERE = _os.path.dirname(_os.path.abspath(__file__))


# ---------------------------------------------------------------------------
# 两个平面
#   lab : 索引 8 bit（51 ASCII + 132 汉字 + 3 专属符号 ○kz = 186 码），行 16 bit
#         行宽从 10 提到 16，是为了让**汉字和 ASCII 共用一块 ROM、共用同一条
#         取字通路**：汉字占满 16 列，ASCII 的 10 列左对齐放在高位。
#         RTL 侧移位寄存器本来就是 16 级（= 格宽），所以行宽 10 -> 16 只改了
#         "从哪一位取第一个像素"，没有多任何逻辑。
#         ★ v23：7 bit（上限 128 码）在 v17 那一轮只剩 1 码，所以这一次先升到
#           8 bit（上限 256 码）再加字。位宽牵连见 disp/disp_engine.v 的 lab_ch_*。
#         ★ v24：48 ASCII + 89 汉字 = 137 码（v23 那轮记的"91 汉字 / 138 码"是笔误：
#           `正常警示故障回到` 里 故/障 本来就在表内，汉字是 83 -> 89 净增 6 个）。
#         ★ v30：51 ASCII + 89 汉字 = 140 码（追加 ●/▲/✖ 三个状态字形）。
#         ★ v52/v76：汉字补到 132 个，再加只属于 lab 的 ○kz ⇒ 51+132+3 = 186 码
#           （8 bit 上限 256，还有 70 码余量；val 侧不受影响）。
#   val : 索引 6 bit（ASCII 51 码 + 只属于这一层的 ○ = 52 码），行 30 bit ——
#         数值/单位/信号名，不需要汉字。这层是像素路径最吃紧的地方，
#         不为用不到的码位付代价（○ 加在 val 自己这一侧，lab 不受影响）。
# ---------------------------------------------------------------------------
PLANES = [
    dict(name="lab", cell_h=16, row_w=16, idx_w=8,
         chars=list(LAB_CHARS)),
    dict(name="val", cell_h=64, row_w=30, idx_w=6,
         chars=list(VAL_CHARS)),
]

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "disp", "font_rom.v")


_RASTER = {}


def _raster(box_w, box_h, font=None, thr=110, refs=None):
    """按 (box, 字体, 阈值, 参考字) 缓存 Raster。字体/阈值必须进 key ——
    两个平面可能用不同字体与阈值，共用一份缓存会让 val 平面偷偷用上 lab 的字号。"""
    key = (box_w, box_h, font, thr, refs)
    if key not in _RASTER:
        kw = {} if refs is None else {"refs": refs}
        _RASTER[key] = Raster(box=(box_w, box_h), path=font, thr=thr, **kw)
    return _RASTER[key]


def ascii_rows(ch, cell_h, y_off, row_w, box_w, box_h, fill_w=None, font=None, thr=110,
               refs=None):
    """ASCII 字的 cell_h 行位图：原生栅格化的点阵，左对齐放进 row_w 位的行里。

    ★ v58：不再 5x7 放大，改由 font_raster 按 box_w x box_h 原生栅格化。
    行位图宽度仍是 row_w，字形墨迹最大 box_w 列，右端补 0 —— RTL 的
    16/30 级移位寄存器照旧工作，宽度契约没变。
    """
    rows = _raster(box_w, box_h, font, thr, refs).rows(ch, row_w, cell_h,
                                                       box_w=box_w, box_h=box_h,
                                                       y_off=y_off, x_off=0, fill_w=fill_w)
    assert len(rows) == cell_h, "glyph %r: %d rows, want %d" % (ch, len(rows), cell_h)
    return rows


def cjk_rows(ch, cell_h):
    """汉字 16x16：行数 = 格高，无纵向偏移，整行就是字形本身。"""
    rows = CN_ART[ch]
    assert len(rows) == cell_h, "cjk glyph %r has %d rows, expected %d" % (ch, len(rows), cell_h)
    return [int(r.replace("#", "1").replace(".", "0"), 2) for r in rows]


def rows_of(ch, plane):
    """按字取行位图：汉字走 16x16 表，ASCII 走 5x7 放大。"""
    if ch in CN_ART:
        return cjk_rows(ch, plane["cell_h"])
    cfg = dict(plane)
    for sz in ASCII_SIZES:
        if sz["name"] == plane["name"]:
            cfg.update(sz)
            break
    else:
        raise SystemExit("no ascii size config for plane %r" % plane["name"])
    return ascii_rows(ch, plane["cell_h"], cfg["y_off"], plane["row_w"],
                      cfg["box_w"], cfg["box_h"], cfg.get("fill_w"),
                      cfg.get("font"), cfg.get("thr", 110), cfg.get("refs"))


def main():
    L = []
    L.append("//=============================================================================")
    L.append("// font_rom.v -- 自动生成，请勿手改")
    L.append("//   生成器: tools/gen_font_rom.py")
    L.append("//   字符集: lab %d 码位（%d ASCII + %d 汉字 + %d lab 专属符号 %s），"
             % (LAB_COUNT, ASCII_COUNT, len(CN_CHARS), len(LAB_EXTRA), LAB_EXTRA))
    L.append("//           val %d 码位（%d ASCII + %d val 专属符号 %s）。"
             % (VAL_COUNT, ASCII_COUNT, len(VAL_EXTRA), VAL_EXTRA))
    L.append("//           lab 平面 8 bit 索引，val 平面 6 bit（ASCII + ○ = %d 码）。" % VAL_COUNT)
    L.append("//   字形源: 英文/数字/符号由 tools/font_raster.py 按目标尺寸原生栅格化（Arial）；")
    L.append("//           %d 个 16x16 汉字点阵，由 tools/make_cn_glyphs.py 栅格化后冻结。" % len(CN_CHARS))
    L.append("//")
    L.append("//   为什么把放大做在生成阶段而不是运行时：")
    L.append("//     运行时要算 glyph_row = y_in_cell / S 的话，一个除法器就会出现在")
    L.append("//     像素路径上，违反 disp_engine 的 \"像素路径 <= 4 级 LUT\" 纪律。")
    L.append("//     离线预放大后，像素路径永远只是 \"一次已寄存的 ROM 读\"。")
    L.append("//")
    L.append("//   为什么每个字的行数 = 格高（而不是字形高）：")
    L.append("//     这样行地址就是格内 y 坐标本身，像素路径上不需要偏移/钳位/比较。")
    L.append("//     字形之外的扫描行全为 0。多存几行 0 换来像素路径更短，划算。")
    L.append("//")
    L.append("//   行位图宽度 = 字形宽度（左对齐）。配合 RTL 里的移位寄存器，")
    L.append("//   多余的列会自然输出 0，不需要任何宽度判断。")
    L.append("//=============================================================================")
    L.append("")
    L.append("`default_nettype none")
    L.append("")

    total_bits = 0
    for pl in PLANES:
        name = pl["name"]
        cell_h = pl["cell_h"]
        row_w = pl["row_w"]
        idx_w = pl["idx_w"]
        chars = pl["chars"]
        depth = len(chars) * cell_h
        total_bits += depth * row_w
        addr_w = max(1, (cell_h - 1).bit_length())
        n_cjk = sum(1 for c in chars if c in CN_ART)
        L.append("//---------------------------------------------------------------------------")
        L.append("// font_rom_%s : 行位图 %d bit，%d 字 x %d 行 = %d 项 x %d bit = %d bit (%.2f KB)"
                 % (name, row_w, len(chars), cell_h, depth, row_w, depth * row_w,
                    depth * row_w / 8.0 / 1024.0))
        L.append("//   字符集: %d 非汉字（ASCII + 本平面专属符号）+ %d 汉字 = %d 码位（索引 %d bit）"
                 % (len(chars) - n_cjk, n_cjk, len(chars), idx_w))
        L.append("//   读延迟 = 1 拍（输出已寄存）。地址 = mem[ch_idx][格内 y]")
        L.append("//   行位图左对齐（bit(%d) = 字形最左列），多余的列自然输出 0"
                 % (row_w - 1))
        L.append("//---------------------------------------------------------------------------")
        L.append("module font_rom_%s (" % name)
        L.append("    input  wire              clk,")
        L.append("    input  wire [%d:0]        ch_idx,       // 0..%d"
                 % (idx_w - 1, len(chars) - 1))
        L.append("    input  wire [%d:0]        row_in_cell, // 0..%d（= 格内 y 坐标，直接来自 pix_y）"
                 % (addr_w - 1, cell_h - 1))
        L.append("    output reg  [%d:0] bits          // 行位图，bit(%d) = 字形最左列"
                 % (row_w - 1, row_w - 1))
        L.append(");")
        L.append("    (* rom_style = \"block\" *) reg [%d:0] mem [0:%d];"
                 % (row_w - 1, depth - 1))
        L.append("    initial begin")
        n = 0
        for ci, c in enumerate(chars):
            rows = rows_of(c, pl)
            assert len(rows) == cell_h, "plane %s char %r: %d rows" % (name, c, len(rows))
            for ri, val in enumerate(rows):
                assert 0 <= val < (1 << row_w), \
                    "plane %s char %r row %d overflows %d bit" % (name, c, ri, row_w)
                L.append("        mem[%d] = %d'h%x;" % (ci * cell_h + ri, row_w, val))
                n += 1
        assert n == depth
        L.append("    end")
        L.append("    // 一维化地址：cell_h 是 2 的幂，{ch_idx,row} 就是 ch_idx*cell_h+row")
        L.append("    wire [%d:0] addr = {ch_idx, row_in_cell};" % (idx_w + addr_w - 1))
        L.append("    always @(posedge clk)")
        L.append("        bits <= mem[addr];")
        L.append("endmodule")
        L.append("")

    L.append("`default_nettype wire")
    L.append("")
    L.append("// 合计 %d bit = %.2f KB = %.2f 个 RAMB36（36 Kb/个）"
             % (total_bits, total_bits / 8.0 / 1024.0, total_bits / 36864.0))

    txt = "\n".join(L) + "\n"
    # 只保证 UTF-8 无 BOM + LF。中文注释在本仓 rtl/*.v 里是常态且已验证可综合；
    # 真正对编码敏感的是 .xdc/.tcl（Vivado 按系统代码页读，见 docs/DEV_STATUS.md §1.7），
    # 而本文件是 .v，不进 Tcl 解释器。
    assert not txt.startswith("\ufeff"), "BOM must not be emitted"
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(txt)
    print("wrote %s" % OUT)
    print("  chars      : lab %d = %d ascii + %d cjk + %d lab-extra (%s); "
          "val %d = %d ascii + %d val-extra (%s)"
          % (LAB_COUNT, ASCII_COUNT, len(CN_CHARS), len(LAB_EXTRA), LAB_EXTRA,
             VAL_COUNT, ASCII_COUNT, len(VAL_EXTRA), VAL_EXTRA))
    print("  total bits : %d  (%.2f KB, %.2f RAMB36)"
          % (total_bits, total_bits / 8.0 / 1024.0, total_bits / 36864.0))



if __name__ == "__main__":
    sys.exit(main())
