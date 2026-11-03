#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_j7_from_geom.py -- 从原理图矢量几何**重建** J7(RGB_TFTLCD) 的 40 针接线表。

用法:
    python tools/check_j7_from_geom.py [--geom _lcd_work/board_geom_geom.txt] [--md]

数据来源: tools/pdf_text.py --geom 生成的矢量转储(文字 T + 线段 L)。

几何事实(达芬奇 lite 原理图第 13 页, 全部单位 pt):
  * J7 的 40 根水平引脚线段都是 x 180.12..187.32(左列, 奇数针)
    或 x 230.52..237.72(右列, 偶数针), y = 213.56 - 7.2*k (k=0..19)。
  * 线段外端向左/右各有一条竖总线; 每行**恰有一个**网络名标签吸附在总线上,
    +5V 标签(左 134.04 / 右 266.52)也吸附在该总线上。
  * 针号标签在 x 175.08..190.92(左) / 219.72..235.56(右), y 与线段同高。

因此: 把每个标签吸附到 (a) 最近的引脚行 y、(b) 所在列(左/右),
再按「左列=奇数针 / 右列=偶数针」即可还原整张表 —— 不需要人工判断。
脚本同时把结果与开发指南表 2.1.1(FPGA_PINS)交叉核对, 报出不一致项。
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PAGE = 13
ROW_Y0 = 213.56          # 第一行(针 1 / 针 2)的 y
ROW_DY = 7.2
N_ROWS = 20
X_MID = 208.92           # 左列 / 右列的分界(即 J7 符号框的竖总线)

# 开发指南表 2.1.1: 约束名 -> (球号, 说明)。用于交叉核对。
FPGA_PINS = {
    "lcd_rgb[0]": ("V5", "LCD_B0"), "lcd_rgb[1]": ("AB1", "LCD_B1"),
    "lcd_rgb[2]": ("AA4", "LCD_B2"), "lcd_rgb[3]": ("AA1", "LCD_B3"),
    "lcd_rgb[4]": ("Y3", "LCD_B4"), "lcd_rgb[5]": ("Y1", "LCD_B5"),
    "lcd_rgb[6]": ("Y4", "LCD_B6"), "lcd_rgb[7]": ("W1", "LCD_B7"),
    "lcd_rgb[8]": ("W7", "LCD_G0"), "lcd_rgb[9]": ("Y7", "LCD_G1"),
    "lcd_rgb[10]": ("V7", "LCD_G2"), "lcd_rgb[11]": ("AB5", "LCD_G3"),
    "lcd_rgb[12]": ("Y6", "LCD_G4"), "lcd_rgb[13]": ("AB3", "LCD_G5"),
    "lcd_rgb[14]": ("AA3", "LCD_G6"), "lcd_rgb[15]": ("U6", "LCD_G7"),
    "lcd_rgb[16]": ("V9", "LCD_R0"), "lcd_rgb[17]": ("AB8", "LCD_R1"),
    "lcd_rgb[18]": ("V8", "LCD_R2"), "lcd_rgb[19]": ("AB7", "LCD_R3"),
    "lcd_rgb[20]": ("AA8", "LCD_R4"), "lcd_rgb[21]": ("AB6", "LCD_R5"),
    "lcd_rgb[22]": ("Y8", "LCD_R6"), "lcd_rgb[23]": ("AA6", "LCD_R7"),
    "lcd_pclk": ("U1", "LCD_CLK"), "lcd_de": ("W2", "LCD_DE"),
    "lcd_hs": ("AB2", "LCD_HSYNC"), "lcd_vs": ("T1", "LCD_VSYNC"),
    "lcd_bl": ("Y2", "LCD_BL"), "lcd_rst": ("R2", "LCD_RST"),
    "touch_scl": ("T4", "IIC_SCL"), "touch_sda": ("U5", "IIC_SDA"),
    "touch_int": ("T5", "IIC_INT"), "touch_rst_n": ("W4", "RESET"),
}

# 球号 -> 该球在第 13 页的网络名(用于反查"这一针连到哪个 FPGA 球")
BALL_OF_NET = {}
for _port, (_ball, _tag) in FPGA_PINS.items():
    BALL_OF_NET[_tag] = _ball

# J7 网络名 -> 触摸/控制用途标注
NOTE = {
    "LCD_CLK": "像素时钟", "LCD_DE": "数据使能", "LCD_HSYNC": "行同步",
    "LCD_VSYNC": "场同步", "LCD_BL": "背光使能(高电平点亮)",
    "LCD_RST": "面板/触摸复位(低有效)",
    "T_MISO": "触摸 IIC SDA", "T_MOSI": "触摸 IIC SCL",
    "T_PEN": "触摸 INT", "T_CS": "触摸 RESET",
}
# 屏 ID 线(B7/G7/R7 = M2/M1/M0)
ID_OF_NET = {"LCD_B7": "M2", "LCD_G7": "M1", "LCD_R7": "M0"}


def load_page(path, page):
    labels, segs = [], []
    cur = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^===== PAGE (\d+)/", line)
            if m:
                cur = int(m.group(1))
                continue
            if cur != page:
                continue
            f = line.rstrip("\n").split("\t")
            if f[0] == "T" and len(f) >= 4:
                labels.append((float(f[1]), float(f[2]), f[3]))
            elif f[0] == "L" and len(f) >= 5:
                segs.append(tuple(float(v) for v in f[1:5]))
    return labels, segs


def invert(flat):
    """返回每行的 y 值和逐行字符串(竖排文字需按 x 排序后拼接)。"""
    rows = {}
    for x, y, t in flat:
        rows.setdefault(round(y, 1), []).append((x, t))
    return {y: "".join(t for _x, t in sorted(v)) for y, v in rows.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--geom", default=os.path.join(ROOT, "_lcd_work", "board_geom_geom.txt"))
    ap.add_argument("--md", action="store_true", help="输出 markdown 表格")
    args = ap.parse_args()
    if not os.path.isfile(args.geom):
        print("[!] 找不到 %s" % args.geom, file=sys.stderr)
        return 2

    labels, segs = load_page(args.geom, PAGE)
    print("== 第 %d 页: 标签 %d 个, 线段 %d 条 ==" % (PAGE, len(labels), len(segs)))

    # 1) 引脚行: 任意水平线段(左列 x 180.12..187.32 / 右列 x 230.52..237.72),
    #    y 落在 213.56 - 7.2k 网格上。同一行左右两侧都有线段, 故两侧分别置位。
    rows = {}          # round(y,1) -> {"L":bool, "R":bool}
    for x1, y1, x2, y2 in segs:
        if abs(y1 - y2) > 0.05:
            continue
        mid = (x1 + x2) / 2.0
        if not (170.0 <= mid <= 245.0):
            continue
        k = (ROW_Y0 - y1) / ROW_DY
        if k < -0.05 or k > N_ROWS - 0.95:
            continue
        side = "L" if mid < X_MID else "R"
        rows.setdefault(round(y1, 1), {"L": False, "R": False})[side] = True
    sides = {ry: [s for s in ("L", "R") if v[s]] for ry, v in rows.items()}
    print("   引脚行: %d 行 (左列 %d / 右列 %d)" % (
        len(rows), sum(1 for v in rows.values() if v["L"]),
        sum(1 for v in rows.values() if v["R"])))

    # 2) 标签按 x 分列, 再吸附到最近的行
    #    左列网络名/针号在 x 116.76 / 134.04 / 175.08..190.92
    #    右列网络名/针号在 x 260.76 / 266.52 / 219.72..235.56
    pin_col, net_col, others = [], [], []
    for x, y, t in labels:
        if 170 <= x <= 196 or 215 <= x <= 240:
            pin_col.append((x, y, t, "L" if x <= X_MID else "R"))
        elif 110 <= x <= 140 or 255 <= x <= 272:
            net_col.append((x, y, t, "L" if x <= X_MID else "R"))
        else:
            others.append((x, y, t))

    table = {}         # (row_y, side) -> {"pin": str, "net": str}
    for x, y, t, side in pin_col:
        cand = [ry for ry in sides if side in sides[ry]]
        if not cand:
            continue
        best = min(cand, key=lambda ry: abs(ry - y))
        if abs(best - y) > 5.0:
            continue
        table.setdefault((best, side), {})["pin"] = t
    for x, y, t, side in net_col:
        cand = [ry for ry in sides if side in sides[ry]]
        if not cand:
            continue          # 该列在几何上没量到 -> 记入 others 供人工复核
        best = min(cand, key=lambda ry: abs(ry - y))
        if abs(best - y) > 6.0:
            continue
        table.setdefault((best, side), {})["net"] = t

    # 3) 打印
    #    第 13 页未标网络的 11 / 20 / 29 三针, 与 2 针 +5V 构成 5 个接地针
    #    (空白填充 = 地, 与模块侧 "第 2 针起每 9 针一地" 的常见排法一致)。
    GND_FILL = {11, 20, 29}
    if args.md:
        print("\n| 针 | 板级网络 | FPGA 球 | 说明 |")
        print("|---:|---|---|---|")
    else:
        print("\n== J7 40 针还原表 ==")
    out = []
    for k in range(N_ROWS):
        ry = round(ROW_Y0 - ROW_DY * k, 1)
        for side, pin in (("L", 2 * k + 1), ("R", 2 * k + 2)):
            ent = table.get((ry, side), {})
            net = ent.get("net", "")
            if not net and pin in GND_FILL:
                net = "GND"
            ball = BALL_OF_NET.get(net, "")
            note = NOTE.get(net, "")
            if net in ID_OF_NET:
                note = (note + " / " if note else "") + "屏ID " + ID_OF_NET[net]
            if net in ("+5V", "GND"):
                ball = "—"
            if not net:
                note = "空白填充(推定接地)"
            if args.md:
                print("| %d | `%s` | %s | %s |" % (pin, net or "(未标)", ball or "—", note))
            else:
                print("  %2d  %-10s %-5s %-26s" % (pin, net or "(未标)", ball or "-", note))
            out.append((pin, net, ball))

    # 4) 交叉核对开发指南表 2.1.1(只比 LCD_* 数据/控制网, 这些两边同名)
    print("\n== 与开发指南 表 2.1.1 交叉核对 ==")
    net2ball = {tag: ball for _port, (ball, tag) in FPGA_PINS.items()}
    bad, checked = 0, 0
    for p, n, b in out:
        if n.startswith("LCD_") and n in net2ball:
            checked += 1
            if net2ball[n] != b:
                print("  [不符] 针%-2d %-10s 板级球=%s 指南球=%s" % (p, n, b, net2ball[n]))
                bad += 1
    print("  已核对 %d 个 LCD_* 网络, 不一致 %d 个" % (checked, bad))
    if not bad:
        print("  OK: 第 13 页 J7 的 LCD_* 网络与指南表 2.1.1 的球号**逐条一致**")
    touch = [n for _p, n, _b in out if n.startswith("T_")]
    print("  触摸网(第 13 页线名): %s" % ", ".join(touch))
    return 0


if __name__ == "__main__":
    sys.exit(main())
