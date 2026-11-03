# -*- coding: utf-8 -*-
"""生成 disp/ring_lut.v —— ㉕ 的「真圆环」进度扇区表。

背景：v26 起 `[−]`/`[+]` 长按的进度反馈是 `disp/disp_engine.v` 里画的**矩形描边**
（按钮内缩 1 px，沿周长 248 px、按 `pnl_prog` 的 4 px/级逐段点亮）。㉕ 把它换成
以按钮中心为圆心的**真圆环**：外径 30 px、内径 26 px（4 px 厚），64 个扇区
（360/64 = 5.625°），从 12 点方向起、顺时针递增，与 `pnl_prog[5:0]` 的 64 级一一对应。

硬件上不打算每像素算 atan2。按钮是 64x64，圆心落在 (31.5, 31.5)，关于两条中线都对称，
所以只存**第一象限的折叠表**：

    地址 addr = {jv[4:0], ju[4:0]}      ju/jv = 折叠坐标（0..31，越大离中心线越远）
    数据 q[4:0] = {valid, k[3:0]}       valid = 该折叠位置落在圆环带内
                                        k = 象限内扇区（0..15，从该象限靠近 12 点的轴起）

折叠 `fold(i) = (i & 31) if (i & 32) else (i ^ 31)`，折叠后到中线的距离
= `j + 0.5` px（用四分之一像素单位表示就是 `4*j + 2`，整数运算即可）。
四个象限按镜像装配成全局扇区号：

    右上（0..15）：s = k           右下（16..31）：s = 31 - k
    左下（32..47）：s = 32 + k     左上（48..63）：s = 63 - k

（装配式在"正好落在扇区边界线上"的像素上会差 1 个扇区：边界只在角度为 5.625° 整数倍时
出现，而 u/v = (2*ju+1)/(2*jv+1) 是有理数，tan 在这些角度上只有 45° 一处理性（=1）
⇒ 只有对角线 ju == jv 的少数像素会差 1；generator 会把这件事数出来并断言其规模。）

生成的 module 是 1 拍寄存输出的 ROM（与 `disp/font_rom.v` 同形）：
`disp/disp_engine.v` 在 S1 用 `px1/py1` 算地址，数据在 S2 与 `px2/py2` 汇合 —— 不给
像素流水线加级。
"""

import math
import os
import sys

# ---------------------------------------------------------------------------
# 几何常数（改这里就够，RTL 只用表）
# ---------------------------------------------------------------------------
N_BTN   = 64          # 按钮 64x64
R_IN    = 26.0        # 圆环内径（px）
R_OUT   = 30.0        # 圆环外径（px）
N_SEC   = 64          # 扇区数（= pnl_prog 的级数）
SEC_DEG = 360.0 / N_SEC
DEPTH   = 32 * 32     # 折叠表 = 32x32


def fold(i):
    """按钮内下标 0..63 -> 折叠坐标 0..31（越大离中线越远）。"""
    return (i & 31) if (i & 32) else (i ^ 31)


def dist4(j):
    """折叠坐标 j 到中线的距离，四分之一像素单位（= 4*j+2）。"""
    return 4 * j + 2


def sector_of(dx, dy):
    """按 atan2 直接算全局扇区号（0 = 12 点，顺时针；dx 右、dy 下为正）。"""
    phi = math.degrees(math.atan2(dx, -dy))
    return int(math.floor((phi % 360.0) / SEC_DEG)) % N_SEC


def assemble(q, k):
    """象限号 + 象限内扇区 -> 全局扇区号（与 RTL 里的表达式一致）。"""
    return (k if q == 0 else (31 - k) if q == 1 else (32 + k) if q == 2 else (63 - k)) % N_SEC


def quadrant(x, y):
    return (0 if (x > 31 and y <= 31) else
            1 if (x > 31 and y > 31) else
            2 if (x <= 31 and y > 31) else 3)


def build():
    """折叠表：{(ju, jv): (valid, k)}。"""
    tab = {}
    lo2 = 16.0 * R_IN * R_IN
    hi2 = 16.0 * R_OUT * R_OUT
    for jv in range(32):
        for ju in range(32):
            u4, v4 = dist4(ju), dist4(jv)
            r2 = float(u4 * u4 + v4 * v4)
            if not (lo2 <= r2 <= hi2):
                tab[(ju, jv)] = (False, 0)
                continue
            k = int(math.floor(math.degrees(math.atan2(ju + 0.5, jv + 0.5)) / SEC_DEG))
            assert 0 <= k <= 15, (ju, jv, k)
            tab[(ju, jv)] = (True, k)
    return tab


def check(tab):
    """把"折叠表 + 象限装配"跑一遍全部 64x64 像素，与直接 atan2 比对。

    返回 (diff, cover, n_ring, off1)。off1 = 只差 1 个扇区且在 45 度对角线上的像素数。
    """
    lo2 = 16.0 * R_IN * R_IN
    hi2 = 16.0 * R_OUT * R_OUT
    diff, cover, off1, n_ring = [], [0] * N_SEC, 0, 0
    for y in range(N_BTN):
        for x in range(N_BTN):
            u4, v4 = dist4(fold(x)), dist4(fold(y))
            r2 = float(u4 * u4 + v4 * v4)
            if not (lo2 <= r2 <= hi2):
                continue
            n_ring += 1
            sx = 1 if x > 31 else -1
            sy = 1 if y > 31 else -1
            s_direct = sector_of(sx * (u4 / 4.0), sy * (v4 / 4.0))
            cover[s_direct] += 1
            valid, k = tab[(fold(x), fold(y))]
            assert valid, ("表说不在带内，直接算在带内", x, y)
            s_hw = assemble(quadrant(x, y), k)
            if s_hw != s_direct:
                dv = min((s_hw - s_direct) % N_SEC, (s_direct - s_hw) % N_SEC)
                diff.append((x, y, s_direct, s_hw, dv))
                if dv == 1 and fold(x) == fold(y):
                    off1 += 1
    return diff, cover, n_ring, off1


# ---------------------------------------------------------------------------
# 生成 Verilog
# ---------------------------------------------------------------------------
HDR = """// =====================================================================
//  disp/ring_lut.v —— 真圆环进度扇区表（**由 tools/gen_ring_lut.py 生成，不要手改**）
//
//  用途：`[−]`/`[+]` 步进按钮长按时的圆形进度反馈（spec §6.5「配环形成进度反馈」）。
//
//  几何：圆心 = 按钮中心 (31.5, 31.5)，外径 %d px、内径 %d px（%d px 厚），
//        %d 个扇区 x %.3f 度，从 12 点方向起、顺时针递增，与 pnl_prog[5:0] 一一对应。
//
//  表：   地址 addr = {jv[4:0], ju[4:0]}，ju/jv 是**折叠坐标**（0..31，越大离中线越远）
//         数据 q[4:0] = {valid, k[3:0]}
//           valid = 该折叠位置落在圆环带内
//           k     = 象限内扇区（0..15，从该象限靠近 12 点的轴起）
//         折叠：fold(i) = i[5] ? i[4:0] : (i[4:0] ^ 5'h1F)
//         象限：rx = x_local[5]（右半）、dy = y_local[5]（下半）
//               q0 右上 rx=1,dy=0 -> s = k          q1 右下 1,1 -> s = 31 - k
//               q2 左下 0,1      -> s = 32 + k       q3 左上 0,0 -> s = 63 - k
//         （45 度对角线上的少数像素会差 1 个扇区：扇区边界正好压在对角线上，
//          肉眼不可见；生成期已核对规模，见 tools/gen_ring_lut.py 的自检。）
//
//  读时序：地址组合产生、打一拍出数据（与 font_rom 同形）。disp_engine 在 S1 给地址，
//          S2 与 px2/py2 汇合 ⇒ 不给像素流水线加级。
//
//  表规模：%d 项 x 5 bit = %d bit（约 %.2f KB，Vivado 推 1 个 RAMB18）
// =====================================================================
"""


def emit(path, tab):
    L = []
    L.append(HDR % (int(R_OUT), int(R_IN), int(R_OUT - R_IN), N_SEC, SEC_DEG,
                    DEPTH, DEPTH * 5, DEPTH * 5 / 8.0 / 1024.0))
    L.append("`default_nettype none")
    L.append("")
    L.append("module ring_lut (")
    L.append("    input  wire        clk,")
    L.append("    input  wire [9:0]  addr,      // {jv[4:0], ju[4:0]}")
    L.append("    output reg  [4:0]  q          // {valid, k[3:0]}")
    L.append(");")
    L.append("")
    L.append("    (* rom_style = \"block\" *) reg [4:0] mem [0:%d];" % (DEPTH - 1))
    L.append("")
    L.append("    initial begin")
    # 每行 4 项，方便和生成器打印的分布对账
    for base in range(0, DEPTH, 4):
        cells = []
        for a in range(base, base + 4):
            jv, ju = (a >> 5) & 31, a & 31
            valid, k = tab[(ju, jv)]
            cells.append("mem[%4d] = 5'h%02X;" % (a, ((1 << 4) if valid else 0) | k))
        L.append("        " + " ".join(cells))
    L.append("    end")
    L.append("")
    L.append("    always @(posedge clk)")
    L.append("        q <= mem[addr];")
    L.append("")
    L.append("endmodule")
    L.append("")
    L.append("`default_nettype wire")
    L.append("")
    txt = "\n".join(L)
    assert not txt.startswith("\ufeff"), "生成物带了 BOM"
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(txt)
    return len(txt)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "disp", "ring_lut.v")

    tab = build()
    n_valid = sum(1 for v, _ in tab.values() if v)
    diff, cover, n_ring, off1 = check(tab)

    print("折叠表      : %d 项，其中圆环带内 %d 项（%.1f%%）" %
          (DEPTH, n_valid, 100.0 * n_valid / DEPTH))
    print("环带像素    : %d（理论 ~%.0f，厚度 %.0f px）" %
          (n_ring, math.pi * (R_IN + R_OUT), R_OUT - R_IN))
    print("扇区覆盖    : 空扇区 %d；每扇区 %d..%d px" %
          (sum(1 for c in cover if c == 0), min(cover), max(cover)))
    print("装配比对    : 差 %d 处（其中 45 度对角线上的 1 扇区偏差 %d 处）" %
          (len(diff), off1))

    # 自检：偏差只能是 1 个扇区，且只能出现在对角线（45 度边界）上
    for x, y, sd, sh, dv in diff:
        assert dv == 1 and fold(x) == fold(y), ("装配式偏差超出预期", x, y, sd, sh, dv)
    assert sum(1 for c in cover if c == 0) == 0, "有扇区一个像素都没有"
    assert n_valid > 0

    n = emit(out, tab)
    print("已写        : %s（%d B = %d 字符）" %
          (os.path.relpath(out, root).replace("\\", "/"), os.path.getsize(out), n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
