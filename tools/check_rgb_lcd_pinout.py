#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_rgb_lcd_pinout.py — 核对「ATK 7 寸 RGB-LCD 模块」接到达芬奇 lite 板 J7(RGB_TFTLCD) 座的引脚账。

用法:
    python tools/check_rgb_lcd_pinout.py

数据来源(全部为仓库内既有材料, 脚本只做交叉核对, 不引入新结论):
    1. Davinci_Lite_1V0.pdf 第 5 页(FPGA Bank34 引脚表) / 第 13 页(RGB LCD 接口原理图)
       —— 用 tools/pdf_text.py --geom 得到标签坐标, 再把 J7 左列 40 个信号贴到 J7 的 1..40 针。
    2. HSTAD9238 / 开发指南(ATK_GUIDE.txt) 表 2.1.1 —— FPGA 引脚 ↔ 信号名。
    3. 本目录 fpga_lcd.inc 的 XDC 约束。

输出: pin_net / ball / J7 针号 对照表, 并标出「一网两名」的触摸信号与 ID 电阻注意事项。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---- 1. FPGA 引脚表(开发指南 表 2.1.1 / 仓库 docs 已核对) -------------------
# 键: 约束/XDC 里的信号名; 值: (FPGA 球号, 中文说明)
FPGA_PINS = {
    "lcd_rgb[0]":  ("V5",  "LCD_B0 蓝0"),
    "lcd_rgb[1]":  ("AB1", "LCD_B1 蓝1"),
    "lcd_rgb[2]":  ("AA4", "LCD_B2 蓝2"),
    "lcd_rgb[3]":  ("AA1", "LCD_B3 蓝3"),
    "lcd_rgb[4]":  ("Y3",  "LCD_B4 蓝4"),
    "lcd_rgb[5]":  ("Y1",  "LCD_B5 蓝5"),
    "lcd_rgb[6]":  ("Y4",  "LCD_B6 蓝6"),
    "lcd_rgb[7]":  ("W1",  "LCD_B7 蓝7 / ID M2"),
    "lcd_rgb[8]":  ("W7",  "LCD_G0 绿0"),
    "lcd_rgb[9]":  ("Y7",  "LCD_G1 绿1"),
    "lcd_rgb[10]": ("V7",  "LCD_G2 绿2"),
    "lcd_rgb[11]": ("AB5", "LCD_G3 绿3"),
    "lcd_rgb[12]": ("Y6",  "LCD_G4 绿4"),
    "lcd_rgb[13]": ("AB3", "LCD_G5 绿5"),
    "lcd_rgb[14]": ("AA3", "LCD_G6 绿6"),
    "lcd_rgb[15]": ("U6",  "LCD_G7 绿7 / ID M1"),
    "lcd_rgb[16]": ("V9",  "LCD_R0 红0"),
    "lcd_rgb[17]": ("AB8", "LCD_R1 红1"),
    "lcd_rgb[18]": ("V8",  "LCD_R2 红2"),
    "lcd_rgb[19]": ("AB7", "LCD_R3 红3"),
    "lcd_rgb[20]": ("AA8", "LCD_R4 红4"),
    "lcd_rgb[21]": ("AB6", "LCD_R5 红5"),
    "lcd_rgb[22]": ("Y8",  "LCD_R6 红6"),
    "lcd_rgb[23]": ("AA6", "LCD_R7 红7 / ID M0"),
    "lcd_pclk":    ("U1",  "LCD_CLK 像素时钟"),
    "lcd_de":      ("W2",  "LCD_DE 数据使能"),
    "lcd_hs":      ("AB2", "LCD_HSYNC 行同步"),
    "lcd_vs":      ("T1",  "LCD_VSYNC 场同步"),
    "lcd_bl":      ("Y2",  "LCD_BL 背光使能"),
    "lcd_rst":     ("R2",  "LCD_RST 面板/触摸复位"),
    "touch_scl":   ("T4",  "触摸 IIC SCL"),
    "touch_sda":   ("U5",  "触摸 IIC SDA"),
    "touch_int":   ("T5",  "触摸中断"),
    "touch_rst_n": ("W4",  "触摸复位"),
}

# ---- 2. J7 (RGB_TFTLCD) 40 针, 由原理图第 13 页几何**重建** ------------------
# 第 13 页 J7: 40 根水平引脚线段 y = 213.56 - 7.2k (k=0..19), 左列(奇数针)在
# x 180.12..187.32, 右列(偶数针)在 x 230.52..237.72; 网络名标签吸附在同一行的
# 竖总线上(左列 x=116.76 / 右列 x=260.76, +5V 在 134.04 / 266.52)。
# 复核脚本: python tools/check_j7_from_geom.py   (逐条重建本表并与指南核对)
J7_NETS = [
    (1,  "+5V",       "+5V 供电"),
    (2,  "+5V",       "+5V 供电"),
    (3,  "LCD_R0",    "红0"),
    (4,  "LCD_R1",    "红1"),
    (5,  "LCD_R2",    "红2"),
    (6,  "LCD_R3",    "红3"),
    (7,  "LCD_R4",    "红4"),
    (8,  "LCD_R5",    "红5"),
    (9,  "LCD_R6",    "红6"),
    (10, "LCD_R7",    "红7 / ID M0"),
    (11, "GND",       "地"),
    (12, "LCD_G0",    "绿0"),
    (13, "LCD_G1",    "绿1"),
    (14, "LCD_G2",    "绿2"),
    (15, "LCD_G3",    "绿3"),
    (16, "LCD_G4",    "绿4"),
    (17, "LCD_G5",    "绿5"),
    (18, "LCD_G6",    "绿6"),
    (19, "LCD_G7",    "绿7 / ID M1"),
    (20, "GND",       "地"),
    (21, "LCD_B0",    "蓝0"),
    (22, "LCD_B1",    "蓝1"),
    (23, "LCD_B2",    "蓝2"),
    (24, "LCD_B3",    "蓝3"),
    (25, "LCD_B4",    "蓝4"),
    (26, "LCD_B5",    "蓝5"),
    (27, "LCD_B6",    "蓝6"),
    (28, "LCD_B7",    "蓝7 / ID M2"),
    (29, "GND",       "地"),
    (30, "LCD_CLK",   "像素时钟"),
    (31, "LCD_HSYNC", "行同步"),
    (32, "LCD_VSYNC", "场同步"),
    (33, "LCD_DE",    "数据使能"),
    (34, "LCD_BL",    "背光使能(高电平点亮)"),
    (35, "T_CS",      "触摸(板级网名)"),
    (36, "T_MOSI",    "触摸(板级网名)"),
    (37, "T_MISO",    "触摸(板级网名)"),
    (38, "T_SCK",     "触摸(板级网名)"),
    (39, "T_PEN",     "触摸(板级网名)"),
    (40, "LCD_RST",   "面板/触摸复位(低有效)"),
]

# ---- 3. 触摸 5 根线 ---------------------------------------------------------
# 开发指南表 2.1.1: T4=touch_scl, U5=touch_sda, T5=touch_int, W4=touch_rst_n;
# 原理图第 5 页 Bank34 区另有第 5 个触摸球 W6(表 2.1.1 未列)。
# 板级只给出电阻屏风格的 T_* 命名, 电容屏实际走 IIC, 故 T_* <-> IIC 角色的
# 对应关系**不作断言**(上板用 IIC 扫描/通断法确认)。
NET_ALIAS = [
    ("T4", "touch_scl",   "触摸 IIC SCL(指南表 2.1.1)"),
    ("U5", "touch_sda",   "触摸 IIC SDA(指南表 2.1.1)"),
    ("T5", "touch_int",   "触摸 INT(指南表 2.1.1)"),
    ("W4", "touch_rst_n", "触摸复位(指南表 2.1.1)"),
    ("W6", "(未在表中)",   "第 5 根触摸线, 角色待确认"),
]

ID_TABLE = [
    ("001", "7084", "800x480"),
    ("010", "7016", "1024x600  ← 本模块"),
    ("100", "4384", "800x480"),
    ("101", "1018", "1280x800"),
]


def check_xdc():
    """读 constr/enc_top.xdc 里已配置的 PACKAGE_PIN, 与本表核对。"""
    path = os.path.join(ROOT, "constr", "enc_top.xdc")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    seen = {}
    for m in re.finditer(r'PACKAGE_PIN\s+(\w+)[^}]*?\[get_ports\s+\{?([^\]\}]+)\}?\]', text):
        seen[m.group(2).strip()] = m.group(1)
    return seen


def main():
    print("== J7 (RGB_TFTLCD) 40 针 <-> FPGA 球号 ==")
    net2ball = {}
    for port, (ball, desc) in FPGA_PINS.items():
        m = re.search(r"LCD_(\w+)", desc)
        if m:
            net2ball["LCD_" + m.group(1)] = ball
    miss = 0
    for pin, net, desc in J7_NETS:
        ball = net2ball.get(net, "—")
        print("  %2d  %-10s %-24s %s" % (pin, net, desc, ball))
        if net.startswith("LCD_") and ball == "—":
            miss += 1

    print("\n== 触摸 5 根线(开发指南表 2.1.1 + 原理图第 5 页) ==")
    for ball, role, note in NET_ALIAS:
        print("  %-5s %-13s %s" % (ball, role, note))

    print("\n== LCD 屏 ID 译码(开发指南 表 13.4.1) ==")
    for bits, lcd_id, res in ID_TABLE:
        print("  M2:M1:M0 = %s (B7:G7:R7) -> %s  %s" % (bits, lcd_id, res))
    print("\n  复核: python tools/check_j7_from_geom.py  (从原理图几何重建 J7 全表)")

    xdc = check_xdc()
    if xdc is None:
        print("\n[!] 未找到 constr/enc_top.xdc, 跳过 XDC 核对")
        return 0
    print("\n== XDC (constr/enc_top.xdc) 核对 ==")
    bad = 0
    for port, (ball, _desc) in sorted(FPGA_PINS.items()):
        got = xdc.get(port)
        if got is None:
            print("  [未约束] %-12s 应补 PACKAGE_PIN %s" % (port, ball))
            bad += 1
        elif got != ball:
            print("  [不符]   %-12s XDC=%s 表=%s" % (port, got, ball))
            bad += 1
    if not bad:
        print("  OK: %d 条引脚全部已按上表约束" % len(FPGA_PINS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
