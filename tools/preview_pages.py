"""把每一页的文字平面渲染成 1:1 的预览图，用来人眼核对汉字与版面。

为什么要独立于仿真做这件事
--------------------------
`disp/sim/smoke_p1.v` 出的是**真实光栅**的缩略图，最可信，但它一次只画一页、
而且缩略后 16x16 的汉字会糊成一团，看不清"字有没有写错"。
这个脚本改为直接走 `gen_text_ram.expand()` + 字库同一份数据，按 1:1 铺出来：
  - 与写进 ROM 的内容同源（`expand` 是 build 的同一段代码）
  - 1 px = 1 px，汉字笔画是否粘连、字形是否像那个字，一眼可辨
  - 三页 + 三页的 val 层一起出图，便于横向比

它**不**替代仿真：它证明的是"字库和版面数据对不对"，不证明 RTL 取字/移位正确。
两者都要有。

用法:
    python tools/preview_pages.py            # 出 _disp_work/page_<tag>.png（每页一张）
    python tools/preview_pages.py --scale 2  # 放大 2 倍看笔画

出图：**存活 5 页**各一张（P1 / P2 / P4 / P6 / P7，页号 0 / 1 / 3 / 5 / 6 ——
P3 / P5 / P8 已从产品里删掉，页号留空洞、**不重编号**）。

版面几何从 `tools/ui_geom.py` 取，后者直接解析 `disp/disp_engine.v` 的
`localparam`。★ 以前这里手抄了一份 80/24/140/560/480…，RTL 一改（v58 的
P2 波形区、P4 时序框、导航 6 项改 4 项）预览就与真值漂移，图上看着没问题、
上板却是另一套版面 —— 现在数字只有一个来源，缺一条就抛异常。

另有几张"运行期才有"的演示图：`page_p1_panel.png`（P1 的模态编辑面板开着，
含 `undo_lab` 写的「↩ 回到 ×64」标签带）、`page_p1_panel_ring.png`（按住 `[−]`、
长按进度 32/64 的真圆环；圆环模型与 `disp/ring_lut.v` 逐像素对过表，见
`_disp_work/_ring_xcheck.py`）、`page_p1_chip.png`（六卡迷你状态条的反色块：
卡 5 警示 / 卡 6 故障 —— 静态遥测里六张卡都是"正常"，所以这张图用演示状态，
见 `P1_CHIP_DEMO`）、`page_p1_kp.png`（数字键盘模态）。

标题带主操作按钮：P1「标定」→ P7、P6「闪烁」。其中 P6 那颗按钮里的 16x16
复选框画成**实心**（= 闪烁开，与 `disp/enc_top_disp.v` 的 `reg scr_blink = 1'b1;`
同源）；关掉的空心版由 `disp/tb_disp_engine.v` [12] 段的像素判据覆盖。
★ v58：P4「展开」→ P5 那颗按钮随 P5 一起删了，预览**不再**画它 ——
`TBTN_PAGES` 里只有 p1/p6。
"""

import argparse
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import gen_text_ram as G  # noqa: E402
import ui_geom as UIG  # noqa: E402
from gen_font_rom import ASCII_SIZES, ascii_rows, cjk_rows  # noqa: E402
from cn_glyphs import ART as CN_ART  # noqa: E402

PIL = None
try:
    from PIL import Image, ImageDraw
    PIL = True
except ImportError:                                     # pragma: no cover
    PIL = False

# ---- 版面几何：**全部**来自 disp/disp_engine.v（解析见 tools/ui_geom.py）----
#   ★ 屏幕尺寸 1024x600 仍是字面量：disp_engine.v 里没有对应的 localparam
#     （只有 disp/tb_disp_v58.v 的 H_DISP/V_DISP 是测试台常量，不是版面真值）。
#     lab / val 的字符格尺寸同理，它们属于字库 RTL 的端口契约，不是版面几何。
W, H = 1024, 600
_GEOM = UIG.GEOM
NAV_W = _GEOM["NAV_W"]                  # 左导航栏宽（80）
SBAR_H = _GEOM["SBAR_H"]                # 状态条高（24），导航从它下面起
TITLE_H = _GEOM["TITLE_H"]              # 标题带下沿（64）
LAB_PX = 16          # lab 格 16x16
VAL_PX_X, VAL_PX_Y = 32, 64
# ★ v59：P1 数值格高 48 px（字库格仍是 64 行，字形在 8..55）
VAL_PX_Y_P1 = 48
VAL_Y_OFF_P1 = 8
VAL_ROWS_P1 = 13

# P1 卡片墙：2 列 x 3 行，列原点 CARD_X0/X1、行距 = CARD_Y1 - CARD_Y0（v59）
CARD_XS = (_GEOM["CARD_X0"], _GEOM["CARD_X1"])
CARD_W, CARD_H = _GEOM["CARD_W"], _GEOM["CARD_H"]
CARD_Y0 = _GEOM["CARD_Y0"]
CARD_DY = _GEOM["CARD_Y1"] - _GEOM["CARD_Y0"]

# P2 双通道波形框（含框内中线偏移）与 P4 逻辑时序框（含 6 条通道色块）
WAVE_X0, WAVE_X1 = UIG.WAVE["X0"], UIG.WAVE["X1"]
WAVE_A_Y0, WAVE_A_Y1 = UIG.WAVE["A_Y0"], UIG.WAVE["A_Y1"]
WAVE_B_Y0, WAVE_B_Y1 = UIG.WAVE["B_Y0"], UIG.WAVE["B_Y1"]
WAVE_MID = UIG.WAVE["MID"]              # RTL：p2_mid 的 ry == 12'd99
LG_X0, LG_X1, LG_Y0, LG_Y1 = UIG.LG["X0"], UIG.LG["X1"], UIG.LG["Y0"], UIG.LG["Y1"]
LG_TX0 = UIG.LG["TX0"]                  # 轨迹区左沿 = 标签栏右沿 + 1
LG_TOP, LG_ROW_H, LG_ROWS = UIG.LG["TOP"], UIG.LG["ROW_H"], UIG.LG["ROWS"]
LG_RAIL_HI, LG_RAIL_LO = UIG.LG["RAIL_HI"], UIG.LG["RAIL_LO"]
LG_AXIS = UIG.LG["AXIS"]
LG_SW0, LG_SW1 = UIG.LG["SWATCH_X0"], UIG.LG["SWATCH_X1"]
LG_TICKS = UIG.LG["TICKS"]              # 8 根 45° 刻度的 x（RTL 的 p4_tick 字面量）
LG_TICK_H = UIG.LG["TICK_H"]
LG_CH_COLORS = UIG.LG["CH_COLORS"]      # A/B/Z/U/V/W 六色，顺序 = 道序（lg_ch_col）

# 色板：同样从 RTL 取（disp/disp_engine.v 的 24 位 C_* 常量，0xRRGGBB）。
#   ★ 以前这里各抄一份 0xEAF3FB/0xD6E3F0/…，改色板时两处必须同时改。
C_BG = UIG.colour("C_BG")
C_CARD = UIG.colour("C_CARD")
C_GRID = UIG.colour("C_GRID")
C_ACC = UIG.colour("C_ACC")
C_NAV = UIG.colour("C_NAV")
C_SEC = UIG.colour("C_SEC")
C_TEXT = UIG.colour("C_TEXT")
C_CARD_W = C_CARD
C_PLOT = UIG.colour("C_PLOT")
C_EPRE = UIG.colour("C_EPRE")
C_EPOST = UIG.colour("C_EPOST")

# P7 的两块面板不像其它页是卡片墙，几何在 disp/disp_engine.v 的 P7_* 常量里
_P = UIG.PARAMS
P7_BX0, P7_BX1 = _P["P7_BX0"], _P["P7_BX1"]
P7_BY0, P7_BY1 = _P["P7_BY0"], _P["P7_BY1"]
P7_CVX0, P7_CVX1 = _P["P7_CVX0"], _P["P7_CVX1"]
P7_CVY0, P7_CVY1 = _P["P7_CVY0"], _P["P7_CVY1"]
P7_RX0, P7_RX1 = _P["P7_RX0"], _P["P7_RX1"]
P7_SW0, P7_SW1 = _P["P7_SW0"], _P["P7_SW1"]

# ---- v24：P1 的模态编辑面板（几何全部来自 disp/disp_engine.v 的 PNL_* 等常量）----
#   为什么要画它：`undo_lab` 每帧往"格行 34 的 46..52 列"写「↩ 回到 ×N」，
#   那是**运行期**内容，静态文字层里没有。只抹掉（旧版做法）看不出新功能，
#   只留静态字又看不出它是模态 —— 两种都会骗人。所以额外出一张"面板开着"的图。
PNL_X0, PNL_X1, PNL_Y0, PNL_Y1 = (_GEOM["PNL_X0"], _GEOM["PNL_X1"],
                                  _GEOM["PNL_Y0"], _GEOM["PNL_Y1"])
MNS_X0, MNS_X1, STP_Y0, STP_Y1 = (_P["MNS_X0"], _P["MNS_X1"],
                                  _P["STP_Y0"], _P["STP_Y1"])
PLS_X0, PLS_X1 = _P["PLS_X0"], _P["PLS_X1"]
SLD_X0, SLD_X1, SLD_Y0, SLD_Y1 = _P["SLD_X0"], _P["SLD_X1"], _P["SLD_Y0"], _P["SLD_Y1"]
SLD_TRK_Y0, SLD_TRK_Y1 = _P["SLD_TRK_Y0"], _P["SLD_TRK_Y1"]
CCL_X0, CCL_X1 = _P["CCL_X0"], _P["CCL_X1"]
APL_X0, APL_X1 = _P["APL_X0"], _P["APL_X1"]
BCK_X0, BCK_X1 = _P["BCK_X0"], _P["BCK_X1"]
CMD_Y0, CMD_Y1 = _P["CMD_Y0"], _P["CMD_Y1"]
C_TRACK = UIG.colour("C_TRACK")
#   下面三个是"禁用态按钮"的观感色，RTL 里没有对应常量（disp/ui_panel.v 是
#   按 ui_state 逐像素选色，不是常量表），所以只能在这里定 —— 它们只影响
#   page_p1_panel*.png 的演示观感，不影响任何版面数字。
C_BTN_DIM_EDGE = (0xC8, 0xD2, 0xDE)
C_BTN_DIM = (0xED, 0xF1, 0xF6)
C_APPLY_PEND = (0xFF, 0xF3, 0xCD)

# ---- v30：P5 六状态表的"虚拟格网"（照 disp/disp_engine.v 的 P5_* 常量抄）----
#   spec 4.4 要求 6 行 x 5 列、行高 30、列宽 188，而文字层是全局 16 px 格网，
#   两者不可通约（30/16 = 1.875、188/16 = 11.75）。RTL 里 P5 的表格区走
#   "RAM (行, 列) -> 屏幕 (行带, 格内)" 的重映射；本工具必须用同一套映射，
#   否则预览图上表格会挤在 16 px 的行里 —— 那又是一张骗人的图（U-26 的教训）。
P5_TX0, P5_TY0 = 82, 128
P5_TX1, P5_TY1 = 1022, 338
P5_ROW_H, P5_COL_W = 30, 188
P5_INSET, P5_VINSET = 6, 7
P5_BAR_X0, P5_BAR_X1 = 836, 1020
P5_RAM_R0 = 8                 # 表头行占用的 RAM 行号（数据行 = 9..14）
P5_CH_PER_COL = 11            # 每列 11 个 16 px 字符格（11*16 + 2*6 = 188）
P5_TICK_X = (836, 881, 927, 973, 1019)
P5_DEMO_PX = (36, 91, 137, 183, 0, 60)   # 演示条长（真值来自 p5_view 的 perm*188/1024）
# ---- v31（㉘）：六卡迷你状态条的反色块（spec 5.2 的第三重冗余）----
#   几何与 disp/stat_chip.v 逐格一致：状态条在 RAM 格行 15 / 36，每卡四格，
#   三列起点 6 / 26 / 46。0 = 正常（透明底 + 黑字）、1 = 警示、2 = 故障。
#   静态 lab 版面里六张卡写的都是「● 正常」（那是 gen_text_ram.py 的静态兜底），
#   所以只有演示状态才看得到反色块 —— `page_p1_chip.png` 就是为此出的图。
P1_CHIP_ROW = (15, 36)
P1_CHIP_COL = (6, 26, 46)
P1_CHIP_CELLS = 4
C_OK = (0x3F, 0xA4, 0x5B)
C_WARN = (0xE0, 0x8B, 0x2D)
C_FAULT = (0xD9, 0x45, 0x3D)
P1_CHIP_DEMO = (0, 0, 0, 0, 1, 2)

# v32（㉙）：标题带主操作按钮与「闪烁」复选框。矩形来自 disp/disp_engine.v 的
#   TBTN_X0/X1/Y0/Y1 与 CHK_X0/CHK_Y0；复选框边长 CHK_PX = 16 在 RTL 里是像素
#   字面量（没有 CHK_PX 常量），只能留在这里。
TBTN_X0, TBTN_X1 = _GEOM["TBTN_X0"], _GEOM["TBTN_X1"]
TBTN_Y0, TBTN_Y1 = _GEOM["TBTN_Y0"], _GEOM["TBTN_Y1"]
CHK_X0, CHK_Y0, CHK_PX = _P["CHK_X0"], _P["CHK_Y0"], 16
#   哪几页有这颗按钮：P1「标定」→ P7、P6「闪烁」开关。
#   ★ v58：「展开」→ P5 那颗按钮随 P5 一起删了，`tap_title_btn` 只剩 P1 与 P6
#     两路，所以预览也不该再画 p4 的按钮。
#   ★ 存活两页共用同一个矩形、同一个命中编号（HIT_TITLE_BTN = 15），按页号分派。
TBTN_PAGES = ("p1", "p6")
# ★ v60（T8）：P6 的演示开关（与 disp/disp_engine.v 的 DEMO_BTN_* / DCHK_* 同值）
DEMO_BTN_X0, DEMO_BTN_X1 = 840, 1000
DEMO_BTN_Y0, DEMO_BTN_Y1 = 28, 60
DCHK_X0, DCHK_Y0 = 848, 36

# v34（㊲）/ v42（㊴）：P6 危险区（spec §4.4 的 944x96 + §6.1「危险动作 72..96 px」的按钮）
#   与 v19 模态对话框。几何逐条照 disp/disp_engine.v 抄：
#     区域 x 80..1023 / y 504..599；
#     v42 起是**两颗对称按钮**（各 412 px 宽、缝 16 px，标签落在格行 34 的
#     格列 21..26 与 49..52）：
#       第 1 颗「清除锁存故障」x 180..591 / y 520..583（64 px 高）
#       第 2 颗「恢复默认」    x 608..1019 / y 520..583
#     警示三角中心 x=140、尖顶 y=532、底边 y=572、半宽 20 px；
#     对话框 x 232..791 / y 196..403，两按钮 y 324..379（NO x 272..487 / YES x 536..751）。
#   ★ 本块存在的理由：这一层（危险区 + 按下内嵌框 + 模态遮罩）此前**完全没有**
#     预览件 —— 静态图里那块区域是空白，"按下反馈"就只能靠读代码想象，
#     而 U-40.8 第 3 条恰恰是"看不见的反馈"。
DZ_X0, DZ_X1 = _P["DZ_X0"], _P["DZ_X1"]
DZ_Y0, DZ_Y1 = _P["DZ_Y0"], _P["DZ_Y1"]
DZ_BTN_X0, DZ_BTN_X1 = _P["DZ_BTN_X0"], _P["DZ_BTN_X1"]        # 「清除锁存故障」
DZ_BTN2_X0, DZ_BTN2_X1 = _P["DZ_BTN2_X0"], _P["DZ_BTN2_X1"]    # 「恢复默认」（v42/㊴）
DZ_BTN_Y0, DZ_BTN_Y1 = _P["DZ_BTN_Y0"], _P["DZ_BTN_Y1"]        # RTL 里两颗同高
DZ_BTN2_Y0, DZ_BTN2_Y1 = DZ_BTN_Y0, DZ_BTN_Y1
DZ_BTNS = ((DZ_BTN_X0, DZ_BTN_X1, DZ_BTN_Y0, DZ_BTN_Y1),
           (DZ_BTN2_X0, DZ_BTN2_X1, DZ_BTN2_Y0, DZ_BTN2_Y1))
#   命中区（画框外扩 8 px；disp/enc_top_disp.v 的 DZ_HIT_* / DZ2_HIT_*）。
#   ★ 两颗在 x=600 相接、不重叠：命中区漏改会让第 2 颗左沿落进第 1 颗
#     （按"恢复默认"弹出"清除锁存故障"）—— 端到端台第 11 段专门钉这一条。
DZ_HIT_X0, DZ_HIT_X1 = 172, 600
DZ2_HIT_X0, DZ2_HIT_X1 = 600, 1027
DZ_HIT_Y0, DZ_HIT_Y1 = 512, 592
DZ_TRI_X, DZ_TRI_TOP_Y, DZ_TRI_BOT_Y, DZ_TRI_HW = 140, 532, 572, 20
DZ_INSET, DZ_RING = 10, 2          # 按下内嵌框：里侧 10 px 处、2 px 宽
DLG_X0, DLG_X1 = _P["DLG_X0"], _P["DLG_X1"]
DLG_Y0, DLG_Y1 = _P["DLG_Y0"], _P["DLG_Y1"]
DLG_NO_X0, DLG_NO_X1 = _P["DLG_NO_X0"], _P["DLG_NO_X1"]
DLG_YES_X0, DLG_YES_X1 = _P["DLG_YES_X0"], _P["DLG_YES_X1"]
DLG_BTN_Y0, DLG_BTN_Y1 = _P["DLG_BTN_Y0"], _P["DLG_BTN_Y1"]
#   v42（㊴）：恢复成功后第 2 颗按钮的描边走 C_OK（上面色板里的 0x3FA45B，
#     与 RTL 的 24'h3FA45B 同值）—— 不另立常量，避免两处漂移。
C_DIM = UIG.colour("C_DIM")        # 模态遮罩
C_DLG_PINK = (0xFB, 0xD9, 0xD6)    # 询问态下按钮底色变浅（24'hFBD9D6）
#   对话框文字住在两套专用格行（**v42/㊴ 起按 dlg_kind 分两套**）：
#     kind=0「清除锁存故障」= 标题 13 / 正文 18 / 按钮 22（v41/㊳ 起的位置）
#     kind=1「恢复默认」    = 标题 14 / 正文 19 / 按钮 22（v42/㊴ 新增）
#   ★ 页面层对 13/14/18/19 四行一律排除；行 22 还按格列门控（x >= 256，让出
#     导航栏第 4 个页签「时序」），只有 dlg_on 时由 glyph_dlg 画。
#   ★ 为什么不再用旧行 15/17/21：P6 从 v41（㊳）起是 5 x 88 px 行带，标题墨迹落在
#     带内 v 1..14 ⇒ y 65..78 / 153..166 / 241..254 / 329..342 / 417..430；旧的行 15
#     （240..255）与行 21（336..351）正好压在 241..254 与 329..342 两条标题上。
#   RTL 对应 disp/disp_engine.v 的 dlg_row_page / dlg_cell0 / dlg_cur / DLG_ROW3/4。
DLG_LAB_ROWS = (13, 18, 22)        # kind=0（清除锁存故障）
DLG_LAB_ROWS1 = (14, 19, 22)       # kind=1（恢复默认）
DLG_PAGE_ROWS = (13, 14, 18, 19)   # 页面层一律排除（两套都排除）
DLG_ROW_BTN = 22
DLG_BTN_COL_MIN = 256              # 行 22 的门控起点（RTL 的 px2[9:4] >= 16）
# v41（㊳）：P6 的 88 px 虚拟格网（spec §4.4「项高 88」的字面满足）。
#   5 项铺满 y 64..503，危险区 504..599 不动。与 disp/disp_engine.v 的
#   P6_TY0 / P6_VPH / P6_LAB_R0 / P6_VAL_R0 / P6_X0 逐条对应（两处共同契约）。
#     标题层：RAM 行 = 4 + k，格内 y = 带内 y（0..15）；行带 k 顶 = 64 + 88k。
#       （从 4 起、不从 3 起：行 3 的自然位置 y 48..63 落在 p6_area 之外 ⇒ 会漏残留。）
#     数值层：RAM 行 = 1 + k，格内 y = 带内 y - 13（可见 13..65 ⇒ 墨迹 24..65）。
#     内容列 x >= 96（格列 6 / 数值格列 3）：左侧 80 px 导航竖条仍走全局 16 px 格网。
P6_X0, P6_TY0, P6_TY1, P6_ROW_H, P6_VPH = 96, 64, 504, 88, 13
P6_LAB_R0, P6_VAL_R0 = 4, 1
# v33（㉚）：数字键盘（spec §6.3 的兜底入口）。几何与 disp/ui_panel.v 的
#   KPB_* / KP_* 和 disp/disp_engine.v 的 KPB_* / KP_* / KPV_* 逐条对应 ——
#   改一边必须同时改三处（RTL 两处 + 这里）。
KPB_X0, KPB_X1, KPB_Y0, KPB_Y1 = 856, 920, 392, 456      # 64x64「键盘」入口按钮
KP_X0, KP_Y0, KP_BTN, KP_STEP = 112, 328, 44, 52         # 3 列 x 4 行键位栅格
KPV_X0, KPV_X1, KPV_Y0, KPV_Y1 = 330, 572, 342, 442       # 输入窗（三位 BIG 字段）
KPV_X, KPV_Y, KPV_DX = 340, 352, 72
KP_DEMO = (2, 5, 6)                                       # 演示输入 256（合同上限）
KP_DEMO_DIG = 3


def p5_cell_org(r, c):
    """P5 表格区的 RAM 格 (r, c) 在屏上的左上角；不在表格区则返回 None。"""
    if not (P5_RAM_R0 <= r <= P5_RAM_R0 + 6 and c < 5 * P5_CH_PER_COL):
        return None
    rr, cc = r - P5_RAM_R0, c // P5_CH_PER_COL
    ci = c % P5_CH_PER_COL
    return (P5_TX0 + cc * P5_COL_W + P5_INSET + ci * LAB_PX,
            P5_TY0 + rr * P5_ROW_H + P5_VINSET)


def draw_p5_lab(px, mem, chip=C_TEXT):
    """P5 的文字层：表格区（RAM 行 8..14）走虚拟格网，其余行仍走 16 px 格网。"""
    for r in range(G.LAB_ROWS):
        for c in range(G.LAB_COLS):
            code = mem[r][c]
            if code == 0:
                continue
            org = p5_cell_org(r, c)
            x0, y0 = org if org else (c * LAB_PX, r * LAB_PX)
            ch = G.CHARS[code]
            bits, width = lab_rows(ch)
            for gy in range(16):
                v = bits[gy]
                if v == 0:
                    continue
                for gx in range(16):
                    bit = width - 1 - gx
                    if bit < 0:
                        break
                    if (v >> bit) & 1:
                        x, y = x0 + gx, y0 + gy
                        if 0 <= x < W and 0 <= y < H:
                            px[x, y] = chip


def draw_p5_chart(px):
    """P5 的表格线、条形图槽与刻度线（照 disp/disp_engine.v 的 P5 v30 几何）。"""
    # 外框：x = 81..1023、y = 127..339（左右/上下边界各取 bbox 最外像素）
    for x in range(P5_TX0 - 1, P5_TX1 + 2):
        px[x, P5_TY0 - 1] = C_GRID
        px[x, P5_TY1 + 1] = C_GRID
    for y in range(P5_TY0 - 1, P5_TY1 + 2):
        px[P5_TX0 - 1, y] = C_GRID
        px[P5_TX1 + 1, y] = C_GRID
    # 4 条列分隔线（x = 82 + 188c）+ 6 条行分隔线（y = 128 + 30r）
    for cc in range(1, 5):
        for y in range(P5_TY0, P5_TY1):
            px[P5_TX0 + cc * P5_COL_W, y] = C_GRID
    for rr in range(1, 7):
        for x in range(P5_TX0, P5_TX1):
            px[x, P5_TY0 + rr * P5_ROW_H] = C_GRID
    # 条形图槽（每行带里 18 px）→ 刻度线 → 演示填充
    #   层级与 RTL 一致：fill > tick > track
    for rr in range(6):
        y0 = P5_TY0 + (rr + 1) * P5_ROW_H + 10
        for y in range(y0, y0 + 18):
            for x in range(P5_BAR_X0, P5_BAR_X1):
                px[x, y] = C_TRACK
    for x in P5_TICK_X:
        for y in range(P5_TY0 + P5_ROW_H, P5_TY1):
            px[x, y] = C_SEC
    for rr, thr in enumerate(P5_DEMO_PX):
        y0 = P5_TY0 + (rr + 1) * P5_ROW_H + 10
        for y in range(y0, y0 + 18):
            for x in range(P5_BAR_X0, P5_BAR_X0 + thr):
                px[x, y] = C_ACC


def lab_rows(ch):
    """返回该字符在 lab 平面上的 16 行位图（16 bit）与行位宽。

    ★ v58.2：必须把该平面的 fill_w / font 一起传下去 —— 否则预览会退回
    "默认字体 + 默认字号"，生成器换成 Arial Narrow（val）之后预览还按
    Arial Bold 画，两张图就不是同一套字模了。
    """
    if ch in CN_ART:
        return cjk_rows(ch, 16), 16
    cfg = [s for s in ASCII_SIZES if s["name"] == "lab"][0]
    return (ascii_rows(ch, 16, cfg["y_off"], cfg["row_w"], cfg["box_w"], cfg["box_h"],
                       cfg.get("fill_w"), cfg.get("font")),
            cfg["row_w"])


def val_rows(ch):
    cfg = [s for s in ASCII_SIZES if s["name"] == "val"][0]
    return (ascii_rows(ch, 64, cfg["y_off"], cfg["row_w"], cfg["box_w"], cfg["box_h"],
                       cfg.get("fill_w"), cfg.get("font")),
            cfg["row_w"])


def draw_plane(img, px, mem, cols, rows, cell_w, cell_h, rows_of, chip,
               c0=0, c1=None, r0=0, r1=None, y_off=0):
    """把一块字符码网格铺到 img 上。chip = 字色。

    v41（㊳）：加 c0 / c1 两个格列界 —— P6 的内容列走 88 px 虚拟格网（见
    draw_p6_planes），左侧 80 px 导航竖条仍要按全局 16 px 格网画。
    v42（㊴）：对称地加 r0 / r1 两个格行界 —— P6 危险区按钮标签在格行 34
    （y 544..559，在危险区里、不在 88 px 行带内），只画这一行。
    """
    c1 = cols if c1 is None else c1
    r1 = rows if r1 is None else r1
    # ★ v83：字符表必须**按平面**选，不能一律用 lab 的 G.CHARS。
    #   val 平面自己的尾巴上挂着 val 专属符号（VAL_EXTRA = "○" ⇒ val 码 51），
    #   而 lab 码 51 是**第一个汉字**。以前这里固定取 G.CHARS[code]，于是 val
    #   平面的 ○（码 51）被当成汉字画出来 —— 预览里卡 6 两行的 `Z○` 显示成一个
    #   空心方框，而 disp/font_rom.v 里 val 码 51 是真正的空心圈（ROM 无误，
    #   只是预览的字表拿错了）。判据用 rows_of 身份：val 平面一律传 val_rows。
    charset = G.VAL_CHARS if rows_of is val_rows else G.CHARS
    for r in range(r0, r1):
        for c in range(c0, c1):
            code = mem[r][c]
            if code == 0:
                continue
            ch = charset[code]
            bits, width = rows_of(ch)
            x0 = c * cell_w
            y0 = r * cell_h
            for gy in range(cell_h):
                v = bits[gy + y_off]
                if v == 0:
                    continue
                for gx in range(cell_w):
                    # 行位图左对齐：bit(width-1) 是字形最左列 = 格内第 0 列
                    bit = width - 1 - gx
                    if bit < 0:
                        break
                    if (v >> bit) & 1:
                        x = x0 + gx
                        y = y0 + gy
                        if 0 <= x < W and 0 <= y < H:
                            px[x, y] = chip


def draw_p6_planes(px, lab_mem, val_mem, bad_cells=(), bad_col=C_FAULT):
    """v41（㊳）：P6 的 88 px 虚拟格网（与 disp/disp_engine.v 的 P6_* 同一条契约）。

    标题层：RAM 行 4 + k → 行带 k 的带内 y 0..15（字形墨迹 1..14）；
    数值层：RAM 行 1 + k → 行带 k 的带内 y 13..65（字形 ROM 的墨迹在格内 11..52
            ⇒ 屏上 24..65）。
    ★ 带外一律不画：RTL 那边靠 p6_lvis / p6_vvis 两个可见性门做到同一件事，本工具
      必须照样门控 —— 不门控就会让同一行字形在 88 px 带里重复出现（"忘了门控"
      的典型症状），而预览件存在的意义正是把这种错误在烧板之前照出来。
    ★ 内容列 x >= P6_X0；导航竖条（x < P6_X0）由调用方按全局 16 px 格网画。
    ★ v42（㊴）：`bad_cells`（(RAM 行, 格列) 集合）里的**标题格**画成 `bad_col`
      （红 ✖）—— 对应 RTL 的 `lab_ch_ovr`（覆盖字符码）+ `bad_mark2`（只把这
      一格的墨迹像素涂红，宁静区仍走正常底色/压暗逻辑，见 disp_engine.v:1238）。
    """
    for k in range(5):
        ytop = P6_TY0 + k * P6_ROW_H
        r = P6_LAB_R0 + k
        for c in range(P6_X0 // LAB_PX, G.LAB_COLS):
            code = lab_mem[r][c]
            if code == 0:
                continue
            ch = G.CHARS[code]
            bits, width = lab_rows(ch)
            col = bad_col if (r, c) in bad_cells else C_TEXT
            x0 = c * LAB_PX
            for gy in range(LAB_PX):
                v = bits[gy]
                if v == 0:
                    continue
                y = ytop + gy
                if not (P6_TY0 <= y < P6_TY1):
                    continue
                for gx in range(LAB_PX):
                    bit = width - 1 - gx
                    if bit < 0:
                        break
                    if (v >> bit) & 1:
                        x = x0 + gx
                        if 0 <= x < W:
                            px[x, y] = col
        r = P6_VAL_R0 + k
        for c in range(P6_X0 // VAL_PX_X, G.VAL_COLS):
            code = val_mem[r][c]
            if code == 0:
                continue
            ch = G.CHARS[code]
            bits, width = val_rows(ch)
            x0 = c * VAL_PX_X
            for gy in range(VAL_PX_Y):
                v = bits[gy]
                if v == 0:
                    continue
                y = ytop + P6_VPH + gy
                if not (P6_TY0 <= y < P6_TY1):
                    continue
                for gx in range(VAL_PX_X):
                    bit = width - 1 - gx
                    if bit < 0:
                        break
                    if (v >> bit) & 1:
                        x = x0 + gx
                        if 0 <= x < W:
                            px[x, y] = C_TEXT


def invert_chip_bands(px, states):
    """v31（㉘）：把非"正常"的卡片状态条整块反转成状态色底 + 白字。

    与 RTL 的像素路径同一条 mux（`disp/disp_engine.v` 的 `scbar_inv` 段）：
        `with_txt = scbar_inv ? (glyph_page ? C_CARD : scbar_bg) : ...`
    所以这里只对"已经画成 C_TEXT 的字形像素"改白，其余像素填状态色 ——
    底下的卡片白底/页面底色一律被整块覆盖，与 RTL 的"整块矩形"语义一致。
    必须在 `draw_plane` **之后**调用（要能认出字形像素）。
    """
    for i, st in enumerate(states):
        if st == 0:
            continue
        col = C_FAULT if st == 2 else (C_WARN if st == 1 else C_OK)
        r = P1_CHIP_ROW[i // 3]
        c0 = P1_CHIP_COL[i % 3]
        x0, y0 = c0 * LAB_PX, r * LAB_PX
        for y in range(y0, y0 + LAB_PX):
            for x in range(x0, x0 + P1_CHIP_CELLS * LAB_PX):
                if 0 <= x < W and 0 <= y < H:
                    px[x, y] = C_CARD if px[x, y] == C_TEXT else col


def undo_cells(inter, avail):
    """模拟 `disp/undo_lab.v` 每帧写给 P1 第 34 格行 46..52 列的 7 个字符码。

    与 RTL 同一份口径：`inter == 0` 代表 ×256；只显示倍频（面板从不改分频）；
    数字左紧贴 `×`，前导零不写（所以 8 → 占 1 格、64 → 2 格、256 → 3 格）；
    `avail = 0`（还没有"上一次值"）时只有「回到」。
    """
    def code(ch):
        return G.CHARS.index(ch)

    if not avail:
        return [code("回"), code("到"), 0, 0, 0, 0, 0]
    mag = 256 if inter == 0 else inter
    cells = [code("↩"), code("回"), code("到"), code("×")]
    for i in range(3):
        s = str(mag)
        cells.append((8 + int(s[i])) if i < len(s) else 0)
    return cells


def fold6(i):
    """与 `disp/ring_lut.v` 的地址折叠逐位一致：16x16 折叠表 → 32 象限。"""
    return (i & 31) if (i & 32) else (i ^ 31)


def ring_sec(lx, ly):
    """给像素算扇形号；不在环带里返回 None。

    与 `tools/gen_ring_lut.py` 的 `dist4` / `sector_of` / `assemble` 同一套整数模型：
    距离取"格中心 + 半格"（4x 缩放的 `4*i+2`），因此这里算出来的号与 RTL 表的
    `k` 逐项一致（边界 45° 对角线允许差 1 格，见 `disp/tb_ring_lut.v` 的说明）。
    """
    u4 = 4 * fold6(lx & 63) + 2
    v4 = 4 * fold6(ly & 63) + 2
    r2 = u4 * u4 + v4 * v4
    if not (104 * 104 <= r2 < 120 * 120):        # 环带 26..30 px
        return None
    k = int(math.floor((math.degrees(math.atan2(u4, v4)) % 360.0) / 5.625)) % 64
    if lx > 31:
        return (31 - k) if ly > 31 else k           # 右下 / 右上
    return (32 + k) if ly > 31 else (63 - k)        # 左下 / 左上


# ---- v33（㉚）：七段数码管（disp/seg7.v 的逐像素镜像）----
#   同一套段矩形与掩码；段厚 4（20x32，键内）/ 8（48x80，输入窗）。
#   七段互不重叠 ⇒ 亮像素数 = 点亮的段数 × 段面积（48 / 256），换字号只改 W/H/T。
SEG7_MASK = (0b1111110, 0b0110000, 0b1101101, 0b1111001, 0b0110011,
             0b1011011, 0b1011111, 0b1110000, 0b1111111, 0b1111011)


def draw_seg7(px, x0, y0, d, big, col=C_TEXT):
    W, H = (48, 80) if big else (20, 32)
    T = 8 if big else 4
    MID, HT = H // 2, (8 if big else 4) // 2
    mask = SEG7_MASK[d] if 0 <= d <= 9 else 0
    if not mask:
        return
    for ly in range(H):
        for lx in range(W):
            if ly < T and T <= lx < W - T:
                seg = 1 << 6                       # a
            elif lx < T and T <= ly < MID:
                seg = 1 << 5                       # f
            elif lx >= W - T and T <= ly < MID:
                seg = 1 << 4                       # b
            elif MID - HT <= ly < MID + HT and T <= lx < W - T:
                seg = 1 << 3                       # g
            elif lx < T and MID <= ly < H - T:
                seg = 1 << 2                       # e
            elif lx >= W - T and MID <= ly < H - T:
                seg = 1 << 1                       # c
            elif ly >= H - T and T <= lx < W - T:
                seg = 1 << 0                       # d
            else:
                seg = 0
            if seg and (mask & seg):
                px[x0 + lx, y0 + ly] = col


def kp_key_of(r, c):
    return (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 11)[r * 3 + c]


def draw_kpb(px, down=False):
    """面板右上角的「键盘」入口按钮（64x64）：12 点阵图标（6x6 点、步距 17）。"""
    for y in range(KPB_Y0, KPB_Y1):
        for x in range(KPB_X0, KPB_X1):
            px[x, y] = C_NAV if down else C_CARD
    edge = C_ACC if down else C_GRID
    for x in range(KPB_X0, KPB_X1):
        px[x, KPB_Y0] = px[x, KPB_Y1 - 1] = edge
    for y in range(KPB_Y0, KPB_Y1):
        px[KPB_X0, y] = px[KPB_X1 - 1, y] = edge
    for dy in (8, 22, 36, 50):
        for dx in (12, 29, 46):
            for y in range(KPB_Y0 + dy, KPB_Y0 + dy + 6):
                for x in range(KPB_X0 + dx, KPB_X0 + dx + 6):
                    px[x, y] = C_TEXT


def draw_keypad(px, digits=KP_DEMO, dig=KP_DEMO_DIG, sel=None):
    """键盘模式：12 个 44x44 键（1..9 / ← / 0 / ↵）+ 三位输入窗。"""
    for r in range(4):
        for c in range(3):
            k = kp_key_of(r, c)
            x0, y0 = KP_X0 + c * KP_STEP, KP_Y0 + r * KP_STEP
            down = (sel == k)
            for y in range(y0, y0 + KP_BTN):
                for x in range(x0, x0 + KP_BTN):
                    px[x, y] = C_NAV if down else C_CARD
            edge = C_ACC if down else C_GRID
            for x in range(x0, x0 + KP_BTN):
                px[x, y0] = px[x, y0 + KP_BTN - 1] = edge
            for y in range(y0, y0 + KP_BTN):
                px[x0, y] = px[x0 + KP_BTN - 1, y] = edge
            col = C_ACC if down else C_TEXT
            if k <= 9:
                draw_seg7(px, x0 + 12, y0 + 6, k, False, col)
            elif k == 10:                          # ←（左箭头）
                cy = y0 + 22
                for x in range(x0 + 8, x0 + 20):
                    px[x, cy] = col
                for i in range(6):
                    for j in range(i + 1):
                        px[x0 + 8 + i, cy - j] = col
                        px[x0 + 8 + i, cy + j] = col
            else:                                  # ↵（回车）
                for y in range(y0 + 10, y0 + 29):
                    for x in range(x0 + 16, x0 + 20):
                        px[x, y] = col
                for i in range(8):
                    for j in range(i + 1):
                        px[x0 + 20 + i, y0 + 28 - j] = col
    # 输入窗：白底 + 网格描边 + 三位 BIG 字段（前导零不画，与 RTL 的 .blank 同义）
    for y in range(KPV_Y0, KPV_Y1):
        for x in range(KPV_X0, KPV_X1):
            px[x, y] = C_CARD
    for x in range(KPV_X0, KPV_X1):
        px[x, KPV_Y0] = px[x, KPV_Y1 - 1] = C_GRID
    for y in range(KPV_Y0, KPV_Y1):
        px[KPV_X0, y] = px[KPV_X1 - 1, y] = C_GRID
    for i in range(3):
        if 3 - i > dig:
            continue
        draw_seg7(px, KPV_X + i * KPV_DX, KPV_Y, digits[i], True)


def draw_panel(px, idx=3, pend=False, undo_avail=True, press=None, prog=None,
               kp=False, kp_sel=None):
    """面板的地板与控件（文字层由 draw_plane 之后叠加）。"""
    for y in range(PNL_Y0, PNL_Y1):
        for x in range(PNL_X0, PNL_X1):
            px[x, y] = C_BG
    for x in range(PNL_X0, PNL_X1):
        px[x, PNL_Y0] = px[x, PNL_Y1 - 1] = C_ACC
    for y in range(PNL_Y0, PNL_Y1):
        px[PNL_X0, y] = px[PNL_X1 - 1, y] = C_ACC
    # 两个 64x64 步进按钮：白底 + 网格描边，中间一根 24x6 的符号
    #   v25：按下时底变 C_TRACK、描边变 C_ACC（照 RTL 的按下态），再叠真圆环。
    #   v33：键盘模式下 RTL 把 mns_any/pls_any/sl_any 全门控掉（!pnl_kp_on），
    #     所以这里用"空元组"跳过 —— 键位栅格会盖在同一片区域上。
    for x0, x1, tag in (((MNS_X0, MNS_X1, "mns"), (PLS_X0, PLS_X1, "pls"))
                        if not kp else ()):
        down = (press == tag)
        for y in range(STP_Y0, STP_Y1):
            for x in range(x0, x1):
                px[x, y] = C_TRACK if down else C_CARD
        edge = C_ACC if down else C_GRID
        for x in range(x0, x1):
            px[x, STP_Y0] = px[x, STP_Y1 - 1] = edge
        for y in range(STP_Y0, STP_Y1):
            px[x0, y] = px[x1 - 1, y] = edge
        cx, cy = (x0 + x1) // 2, (STP_Y0 + STP_Y1) // 2
        for x in range(cx - 12, cx + 12):
            for y in range(cy - 3, cy + 3):
                px[x, y] = C_TEXT
        if tag == "pls":                      # [+]
            for y in range(cy - 12, cy + 12):
                for x in range(cx - 3, cx + 3):
                    px[x, y] = C_TEXT
        if down and prog is not None:
            # 长按加速进度：真圆环（环带 26..30 px、64 扇区、12 点起顺时针）。
            for y in range(STP_Y0, STP_Y1):
                for x in range(x0, x1):
                    sec = ring_sec(x - x0, y - STP_Y0)
                    if sec is None:
                        continue
                    px[x, y] = C_ACC if (prog >= 63 or sec < prog) else C_TRACK
    # 离散滑条：轨道 + 8 根刻度 + 选中档铺底 + 当前档游标（键盘模式下不画）
    for y in range(SLD_TRK_Y0, SLD_TRK_Y1) if not kp else ():
        for x in range(SLD_X0, SLD_X1):
            px[x, y] = C_TRACK
    zx = SLD_X0 + idx * 64
    for y in range(SLD_TRK_Y0, SLD_TRK_Y1) if not kp else ():
        for x in range(zx, zx + 64):
            px[x, y] = C_SEC
    for i in range(8) if not kp else ():
        x = SLD_X0 + 32 + i * 64
        for y in range(SLD_TRK_Y0 - 8, SLD_TRK_Y1 + 8):
            px[x, y] = C_GRID
    for y in range(SLD_TRK_Y0 - 12, SLD_TRK_Y1 + 12) if not kp else ():
        for x in range(SLD_X0 + 32 + idx * 64 - 1, SLD_X0 + 32 + idx * 64 + 2):
            px[x, y] = C_ACC
    if kp:
        draw_keypad(px, sel=kp_sel)
    else:
        draw_kpb(px)
    # 三个 160x48 命令按钮
    for x0, x1, dim in ((CCL_X0, CCL_X1, False), (APL_X0, APL_X1, False),
                        (BCK_X0, BCK_X1, not undo_avail)):
        for y in range(CMD_Y0, CMD_Y1):
            for x in range(x0, x1):
                px[x, y] = C_BTN_DIM if dim else (C_APPLY_PEND if (pend and x0 == APL_X0) else C_CARD)
        edge = C_BTN_DIM_EDGE if dim else (C_ACC if (pend and x0 == APL_X0) else C_GRID)
        for x in range(x0, x1):
            px[x, CMD_Y0] = px[x, CMD_Y1 - 1] = edge
        for y in range(CMD_Y0, CMD_Y1):
            px[x0, y] = px[x1 - 1, y] = edge


def _ring(px, x0, x1, y0, y1):
    """在给定矩形里侧 DZ_INSET px 处画一圈 DZ_RING px 宽的红框（按下内嵌框）。"""
    xa, xb = x0 + DZ_INSET, x1 - DZ_INSET
    ya, yb = y0 + DZ_INSET, y1 - DZ_INSET
    for x in range(xa, xb):
        for k in range(DZ_RING):
            px[x, ya + k] = C_FAULT
            px[x, yb - 1 - k] = C_FAULT
    for y in range(ya, yb):
        for k in range(DZ_RING):
            px[xa + k, y] = C_FAULT
            px[xb - 1 - k, y] = C_FAULT


def draw_dz(px, press=False, press2=False, face=C_BG, face2=None,
            edge=C_FAULT, edge2=None):
    """P6 危险区（静态层）：区域底/描边 + 两颗按钮的 64 px 描边 + 警示三角 + 按下内嵌框。

    与 disp/disp_engine.v 的 dz_* 分支逐条对应（那里是逐像素优先级 mux，视觉上等价于
    "区域 → 按钮 → 三角 → 按下内嵌框"这个叠放顺序）。`press`/`press2` 画的是 v34（㊲）
    新增的按下反馈：按钮里侧 10 px 处一道 2 px 的红框 —— **形状**编码，不依赖颜色
    （spec §5.2 第 1 条"颜色绝不作为唯一的状态编码"）；`face`/`face2` 是两颗按钮的底色
    （询问态下两颗都变 24'hFBD9D6），`face2=None` 表示与 `face` 同色。

    ★ v42（㊴）：单颗按钮 → **两颗对称按钮**（各 412 px 宽、缝 16 px）——
      第 1 颗「清除锁存故障」x 180..591、第 2 颗「恢复默认」x 608..1019。
      几何逐条照 disp/disp_engine.v 的 DZ_BTN_* / DZ_BTN2_* 抄（那里还各有一条
      命中区 DZ_HIT_* / DZ2_HIT_*，本工具只画视觉层，不表达命中）。
      `edge2` 是第 2 颗的描边色：恢复**成功**时 RTL 走
      `dz_btn2_edge_col = (ui_rst_state == 2'd1) ? C_OK : C_FAULT` ⇒ 绿（色板 C_OK）；
      失败（state=2）与空闲（state=0）都是红。★ 颜色只是**附加**编码：失败另有
      红 ✖（见 render 的 dz_bad），成功另有 17 项数值全部回默认。"""
    for y in range(DZ_Y0, DZ_Y1):
        for x in range(DZ_X0, DZ_X1):
            px[x, y] = C_CARD
    for x in range(DZ_X0, DZ_X1):
        px[x, DZ_Y0] = C_FAULT
        px[x, DZ_Y1 - 1] = C_FAULT
    for y in range(DZ_Y0, DZ_Y1):
        px[DZ_X0, y] = C_FAULT
        px[DZ_X1 - 1, y] = C_FAULT
    # 两颗按钮：面 + 1 px 描边（64 px 高，落在 spec §6.1「危险动作 72..96」里）
    for i, (bx0, bx1, by0, by1) in enumerate(DZ_BTNS):
        fill = face if (i == 0 or face2 is None) else face2
        col = edge if (i == 0 or edge2 is None) else edge2
        for y in range(by0, by1):
            for x in range(bx0, bx1):
                px[x, y] = fill
        for x in range(bx0, bx1):
            px[x, by0] = col
            px[x, by1 - 1] = col
        for y in range(by0, by1):
            px[bx0, y] = col
            px[bx1 - 1, y] = col
    # 警示三角（中心 x=140、尖顶 y=532、底边 y=572、半宽 20 px）
    for y in range(DZ_TRI_TOP_Y, DZ_TRI_BOT_Y + 1):
        w = min(y - DZ_TRI_TOP_Y, DZ_TRI_HW)
        for x in range(DZ_TRI_X - w, DZ_TRI_X + w + 1):
            px[x, y] = C_FAULT
    if press:
        _ring(px, DZ_BTN_X0, DZ_BTN_X1, DZ_BTN_Y0, DZ_BTN_Y1)
    if press2:
        _ring(px, DZ_BTN2_X0, DZ_BTN2_X1, DZ_BTN2_Y0, DZ_BTN2_Y1)


def draw_dlg(px, dz_keep=True):
    """v19 模态遮罩 + 对话框（几何照 disp/disp_engine.v 的 DLG_* 常量抄）。

    ★ v34（㊲）：新合成分支 `compose = dlg_on ? (in_dlg_box ? … : (dz_keep ? dz_self : C_DIM))`
      下，危险区**按钮矩形**（dz_btn）不再被遮罩压暗。旧版把整屏（对话框之外）
      一律刷成 C_DIM，而按钮在 y 520..583、对话框只到 y 403 ⇒ 按住时那一圈反馈
      在最后一步被遮罩吃掉 —— 这正是 U-40.8 第 3 条"没有按下反馈"的真正原因。
    ★ v42（㊴）：RTL 的 `dz_keep = dlg_on && (dz_btn || dz_btn2)` ⇒ **两颗**按钮
      矩形都不被压暗（旧版只放行第 1 颗，第 2 颗在询问态会整块变暗）。"""
    for y in range(SBAR_H, H):
        for x in range(NAV_W, W):
            if DLG_X0 <= x < DLG_X1 and DLG_Y0 <= y < DLG_Y1:
                continue
            if dz_keep and any(bx0 <= x < bx1 and by0 <= y < by1
                               for bx0, bx1, by0, by1 in DZ_BTNS):
                continue
            px[x, y] = C_DIM
    for y in range(DLG_Y0, DLG_Y1):
        for x in range(DLG_X0, DLG_X1):
            px[x, y] = C_CARD
    for y in range(DLG_Y0, DLG_Y1):
        for x in range(DLG_X0, DLG_X1):
            if x <= DLG_X0 + 1 or x >= DLG_X1 - 2 or y <= DLG_Y0 + 1 or y >= DLG_Y1 - 2:
                px[x, y] = C_FAULT
    for bx0, bx1 in ((DLG_NO_X0, DLG_NO_X1), (DLG_YES_X0, DLG_YES_X1)):
        for y in range(DLG_BTN_Y0, DLG_BTN_Y1):
            for x in range(bx0, bx1):
                px[x, y] = C_BG
        for x in range(bx0, bx1):
            px[x, DLG_BTN_Y0] = C_GRID
            px[x, DLG_BTN_Y1 - 1] = C_GRID
        for y in range(DLG_BTN_Y0, DLG_BTN_Y1):
            px[bx0, y] = C_GRID
            px[bx1 - 1, y] = C_GRID


def draw_p2_frame(px):
    """v58：P2 双通道波形框（静态层）。

    几何全部来自 disp/disp_engine.v（见 tools/ui_geom.py 的 WAVE_*）：
      · 两块轨迹区底铺 C_PLOT：x WAVE_X0..WAVE_X1-1，y 分别在 A / B 区间；
      · 中线 C_GRID：行内偏移 99 px（RTL 的 p2_mid，幅度 0 的位置）；
      · 外框 C_GRID：竖边**只在该通道的 y 区间内**、横边**只在 x >= WAVE_X0
        内** —— RTL 的 p2_vert / p2_horiz 各带这两个门控，少一个就会把
        y = WAVE_A_Y0 整行（连左边导航栏一起）涂成网格色。
    轨迹曲线 trace_a / trace_b 是运行期数据（wa_lo / wa_hi），静态预览不画。
    """
    for y0, y1 in ((WAVE_A_Y0, WAVE_A_Y1), (WAVE_B_Y0, WAVE_B_Y1)):
        for y in range(y0, min(y1, H)):
            for x in range(WAVE_X0, min(WAVE_X1, W)):
                px[x, y] = C_PLOT
        # ★ v60（T5）：细栅格（每 64 px 竖、每 32 px 横）
        for x in range(WAVE_X0, min(WAVE_X1, W)):
            if (x & 63) == 0:
                for y in range(y0, min(y1, H)):
                    px[x, y] = C_GRID
        for y in range(y0, min(y1, H)):
            if (y & 31) == 0:
                for x in range(WAVE_X0, min(WAVE_X1, W)):
                    px[x, y] = C_GRID
        ym = y0 + WAVE_MID
        if ym < min(y1, H):
            for x in range(WAVE_X0, min(WAVE_X1, W)):
                px[x, ym] = C_GRID
        # ★ v60（T5）：左侧 32 px 刻度条（底色 + 3 条 12 px 刻度）
        for x in range(WAVE_X0, min(WAVE_X0 + 32, W)):
            for y in range(y0, min(y1, H)):
                px[x, y] = C_PLOT
        for ry in (9, WAVE_MID, 189):
            for x in range(WAVE_X0, min(WAVE_X0 + 12, W)):
                yy = y0 + ry
                if yy < min(y1, H):
                    px[x, yy] = C_GRID
        for y in range(y0, min(y1, H)):
            px[WAVE_X0, y] = C_GRID
            px[min(WAVE_X1 - 1, W - 1), y] = C_GRID
    for y in (WAVE_A_Y0, WAVE_A_Y1 - 1, WAVE_B_Y0, WAVE_B_Y1 - 1):
        if 0 <= y < H:
            for x in range(WAVE_X0, min(WAVE_X1, W)):
                px[x, y] = C_GRID


def draw_p4_frame(px):
    """v58：P4 逻辑时序框（静态层）。

    几何全部来自 disp/disp_engine.v（见 tools/ui_geom.py 的 LG）：
      · 整框底 C_PLOT（RTL 的 in_lg_box）+ 1 px 外框 C_GRID（p4_border）；
      · 标签栏右沿分隔线 x = LG_TX0 - 1（p4_labsep，笔迹区从 LG_TX0 起）；
      · 时间轴横线 y = LG_AXIS（p4_axisln）+ 8 根 45° 刻度（p4_tick，x 取
        LG_TICKS、y 在 LG_AXIS+1 .. LG_AXIS+TICK_H-1）；
      · 6 条通道色块（lg_swatch）：x LG_SW0..LG_SW1-1、y = LG_TOP + k*LG_ROW_H
        + LG_RAIL_HI .. + LG_RAIL_LO，颜色按道序 A/B/Z/U/V/W 取 C_CH_*。
    ★ 色块以前预览里没有，而它是"哪条轨迹是哪个通道"的唯一视觉线索 ——
      行高从 48 改成 68 之后，色块必须跟着挪，否则和轨迹错位 20 px。
    """
    for y in range(LG_Y0, min(LG_Y1, H)):
        for x in range(LG_X0, min(LG_X1, W)):
            px[x, y] = C_PLOT
    for y in range(LG_Y0, min(LG_Y1, H)):
        px[LG_X0, y] = C_GRID
        px[min(LG_X1 - 1, W - 1), y] = C_GRID
    for x in range(LG_X0, min(LG_X1, W)):
        px[x, LG_Y0] = C_GRID
        px[x, min(LG_Y1 - 1, H - 1)] = C_GRID
    for y in range(LG_Y0, min(LG_Y1, H)):
        px[LG_TX0 - 1, y] = C_GRID
    for x in range(LG_TX0, min(LG_X1, W)):
        px[x, LG_AXIS] = C_GRID
    for tx in LG_TICKS:
        for y in range(LG_AXIS + 1, min(LG_AXIS + LG_TICK_H, H)):
            px[tx, y] = C_GRID
    for k, col in enumerate(LG_CH_COLORS[:LG_ROWS]):
        top = LG_TOP + k * LG_ROW_H
        for y in range(top + LG_RAIL_HI, min(top + LG_RAIL_LO + 1, H)):
            for x in range(LG_SW0, min(LG_SW1, W)):
                px[x, y] = col


def render(page, lab_items, val_items, panel=False, press=None, prog=None,
           chip_demo=None, kp=False, kp_sel=None,
           dz_press=False, dz_press2=False, dz_dlg=False, dz_kind=0, dz_state=0,
           dz_bad=()):
    """`dz_*` 是 v34（㊲）/ v42（㊴）的 P6 危险区演示开关（静态图里它们都是关的）：
        · dz_press / dz_press2：第 1 / 第 2 颗按钮按下（里侧 2 px 红框，形状编码）；
        · dz_dlg + dz_kind：询问态对话框（kind=0「清除锁存故障」行 13/18/22，
          kind=1「恢复默认」行 14/19/22）；
        · dz_state：=1 恢复成功（第 2 颗描边转绿）、=2 恢复失败（描边红 + 按
          `dz_bad` 在标题行右侧画红 ✖）、=0 空闲；
        · dz_bad：失败项列表，元素是 (行带 k, 列 n)，k = 0..4、n = 0..2 —— 与
          RTL `ui_rst_bad` 的位序 k*3+n 一致（✖ 落在格行 4+k、格列 12/32/52）。"""
    img = Image.new("RGB", (W, H), C_BG)
    px = img.load()

    # 卡片底 / 面板底（与 disp/disp_engine.v 的常量逐条对应）
    if page == "p7":
        # P7 不是卡片墙：左框＝误差曲线（底色 C_PLOT），右框＝六参数（C_CARD）
        for x0, x1, fill in ((P7_BX0, P7_BX1, C_PLOT), (P7_RX0, P7_RX1, C_CARD)):
            for y in range(P7_BY0, min(P7_BY1, H)):
                for x in range(x0, min(x1, W)):
                    px[x, y] = fill
        # 描边：两框的边 + 曲线区的上下沿 + 曲线区左右沿（disp_engine.v:1066-1070）
        for x in (P7_BX0, P7_BX1 - 1, P7_RX0, P7_RX1 - 1, P7_CVX0, P7_CVX1 - 1):
            for y in range(P7_BY0, P7_BY1):
                px[x, y] = C_GRID
        for y in (P7_BY0, P7_BY1 - 1, P7_CVY0, P7_CVY1 - 1):
            for x in range(P7_BX0, P7_RX1):
                px[x, y] = C_GRID
        # 图例色块 16x16：紧挨 lab(8,30)"前" 与 lab(8,34)"后" 的左边
        for x0, col in ((P7_SW0, C_EPRE), (P7_SW1, C_EPOST)):
            for y in range(128, 144):
                for x in range(x0, x0 + 16):
                    px[x, y] = col
    elif page == "p1":
        # 卡片墙**只在 P1** —— 与 disp/disp_engine.v:802
        # `in_card = (page == 3'd0) & ((col0|col1|col2) & (row0|row1));` 一致。
        # 几何照 RTL 抄（同文件 :143-148）：列 96/416/736、宽 288、行 64/336、高 256。
        # 旧版这里按 spec §4.3 画 300x264 @ 92/404/716，而且给 P6/P8 也画 3x3 ——
        # RTL 早在"卡片框只在 P1"那一版就把 P2/P6 的框去掉了（P6 用的是
        # spec §4.4 的"3 列 x 4 项网格"，项在格行 3/15/27，与 y=64/336 的卡片框
        # 整段错开），所以预览件那张 P6 卡片墙一直在骗人。
        for cr in range(3):
            for cc in range(2):
                x0, y0 = CARD_XS[cc], CARD_Y0 + cr * CARD_DY
                for y in range(y0, min(y0 + CARD_H, H)):
                    for x in range(x0, min(x0 + CARD_W, W)):
                        px[x, y] = C_GRID if (
                            x in (x0, x0 + CARD_W - 1) or
                            y in (y0, y0 + CARD_H - 1)) else C_CARD
    # 左导航栏：4 档 x 144 px（RTL 的 nav_idx / nav_page / nav_sel）
    #   RTL 底色是 `in_nav ? (nav_sel ? C_SEC : C_NAV)` —— 选中项整档 80x144 铺
    #   C_SEC，其余铺 C_NAV。P7 不在导航里（nav_page 只映射 0/1/3/5），所以
    #   page_p7.png 一档都不高亮；这也正是 RTL 注释说的"一个都不高亮"。
    #   ★ 旧版这里整条铺 C_NAV、从不高亮，图上永远看不出"当前在哪一页"。
    for y in range(SBAR_H, H):
        for x in range(NAV_W):
            px[x, y] = C_NAV
    _cur = UIG.PAGES_BY_TAG[page]
    for _it in UIG.NAV_ITEMS:
        if _it.page != _cur:
            continue
        for y in range(max(_it.y0, SBAR_H), min(_it.y1, H)):
            for x in range(NAV_W):
                px[x, y] = C_SEC
    # 状态栏
    for y in range(SBAR_H):
        for x in range(W):
            px[x, y] = C_ACC
    # 页内标题带
    for y in range(SBAR_H, TITLE_H):
        for x in range(NAV_W, W):
            px[x, y] = C_CARD
    # v58：P2 的双通道波形框 / P4 的逻辑时序框（静态层，曲线本身是运行期数据）
    #   ★ 这两块此前**完全没有**预览件：P2 图上是空白的，P4 图上是空的标题带 ——
    #     v58 把页收缩到 5 页、P2 换区间、P4 换行高之后，预览必须跟上，否则
    #     "预览和 RTL 漂移"的老毛病（正是本次要消灭的东西）会立刻复发。
    if page == "p2":
        draw_p2_frame(px)
    if page == "p4":
        draw_p4_frame(px)
    # v20/v32：标题带主操作按钮（P1「标定」/ P6「闪烁」）
    #   按钮本身只画"白底 + 强调色描边"——文字来自 lab 平面（格行 2），
    #   由下面的 draw_plane 叠上来，与 RTL 的分层一致（bg_sel 先、文字层后）。
    if page in TBTN_PAGES:
        for y in range(TBTN_Y0, TBTN_Y1):
            for x in range(TBTN_X0, TBTN_X1):
                px[x, y] = C_CARD
        for x in range(TBTN_X0, TBTN_X1):
            px[x, TBTN_Y0] = C_ACC
            px[x, TBTN_Y1 - 1] = C_ACC
        for y in range(TBTN_Y0, TBTN_Y1):
            px[TBTN_X0, y] = C_ACC
            px[TBTN_X1 - 1, y] = C_ACC
    #   P6 那颗按钮是「可关闭的 2 Hz 闪烁」的开关，状态用按钮左侧一个 16x16
    #   复选框表示：**实心 = 开、空心 = 关**（几何信息，不看颜色也能读）。
    #   这里画实心版 —— 复位默认开，与 disp/enc_top_disp.v 的
    #   `reg scr_blink = 1'b1;` 一致；关掉的空心版由 [12] 段的像素判据覆盖
    #   （tb_disp_engine.v 的 expect_px(668,36)/expect_px(675,43)）。
    if page == "p6":
        for y in range(CHK_Y0, CHK_Y0 + CHK_PX):
            for x in range(CHK_X0, CHK_X0 + CHK_PX):
                px[x, y] = C_TEXT
        # ★ v60（T8）：演示开关按钮（x 840..999 / y 28..59）。与 disp/disp_engine.v 的
        #   DEMO_BTN_* / DCHK_* 是两处共同契约；复选框默认空（上电演示关）。
        for y in range(DEMO_BTN_Y0, DEMO_BTN_Y1):
            for x in range(DEMO_BTN_X0, DEMO_BTN_X1):
                px[x, y] = C_CARD
        for x in range(DEMO_BTN_X0, DEMO_BTN_X1):
            px[x, DEMO_BTN_Y0] = C_ACC
            px[x, DEMO_BTN_Y1 - 1] = C_ACC
        for y in range(DEMO_BTN_Y0, DEMO_BTN_Y1):
            px[DEMO_BTN_X0, y] = C_ACC
            px[DEMO_BTN_X1 - 1, y] = C_ACC
        for x in range(DCHK_X0, DCHK_X0 + CHK_PX):
            px[x, DCHK_Y0] = C_TEXT
            px[x, DCHK_Y0 + CHK_PX - 1] = C_TEXT
        for y in range(DCHK_Y0, DCHK_Y0 + CHK_PX):
            px[DCHK_X0, y] = C_TEXT
            px[DCHK_X0 + CHK_PX - 1, y] = C_TEXT
    # v30：P5 的表格线 / 条形图槽 / 刻度线（静态层，不依赖运行期）
    if page == "p5":
        draw_p5_chart(px)
    # v34（㊲）：P6 危险区（区域 / 按钮 / 三角 / 按住时的内嵌框）。
    #   ★ 必须在文字层**之前**：按钮上的「清除锁存故障」是 lab 平面的字形，
    #     与 RTL 的分层一致（底色层先、文字层后）。
    #   ★ 询问态下按钮底色换成 C_DLG_PINK（RTL 的 24'hFBD9D6），
    #     遮罩则只放行按钮矩形 —— 这两件事合起来才是"看得见的按下反馈"。
    if page == "p6":
        #   v42（㊴）：第 2 颗按钮的描边色 = `ui_rst_state`（1 绿 / 2 红 / 0 红），
        #     对应 RTL `dz_btn2_edge_col = (ui_rst_state == 2'd1) ? C_OK : C_FAULT`。
        #     静态版面图（dz_state=0）与失败图都是红，只有"恢复成功"演示图是绿。
        draw_dz(px, press=dz_press, press2=dz_press2,
                face=(C_DLG_PINK if dz_dlg else C_BG),
                edge2=(C_OK if dz_state == 1 else C_FAULT))
        if dz_dlg:
            draw_dlg(px)

    lab_mem = G.expand(G.LAB_COLS, G.LAB_ROWS, lab_items, G.LAB_CODE_W)
    val_rows_n = VAL_ROWS_P1 if page == "p1" else G.VAL_ROWS
    # ★ v82：数值平面必须用**它自己的**字库表（VAL_CHARS = ASCII + ○，6 位），
    #   不能沿用标签平面的 CHARS（8 位，○ 在里面是 183）。卡 6 的主值
    #   `A● B● Z○` 用的就是 val 层的 ○（51）—— 早先这行写的是 `A1 B1 Z0`，
    #   没有 ○，所以这个漏传 charset 的 bug 一直没暴露。
    val_mem = G.expand(G.VAL_COLS, val_rows_n, val_items, G.VAL_CODE_W,
                       charset=G.VAL_CHARS)
    # v23：P1 的格行 21（面板标题）与格行 34（三个按钮标签）是**模态行** ——
    #   disp_engine.v 的 glyph_page 在 P1 上永远排除它们，只有 pnl_on=1 时
    #   由 glyph_pnl 画。本工具画的是静态文字层、不模拟模态，所以这里直接抹掉，
    #   否则预览图上会浮着「倍频分频 / PRESET / CANCEL / APPLY / 回到」，
    #   看起来像"常显"（U-26 的真缺陷正是被这种图放过去的）。
    #   ★ v24：`panel=True` 时反过来 —— 面板画出来、模态行保留，再按 undo_lab
    #     的口径把「↩ 回到 ×N」贴到格行 34 的 46..52 列，供人眼核对新标签带。
    if page == "p1" and panel:
        draw_panel(px, press=press, prog=prog, kp=kp, kp_sel=kp_sel)
        # 面板是不透明的：RTL 里 `pnl_any` 的像素一律取面板色，页面层的文字
        #   **不**透出来（`with_pnl` 那条 mux）；只有格行 21/34 是面板自己的
        #   文字（glyph_pnl）。所以这里把落在面板矩形里的页面文字格清掉，
        #   否则预览图上会看到 P1 的数字压在滑条上 —— 那是假的。
        for r in range(G.LAB_ROWS):
            if r in (21, 34):
                continue
            if (r * LAB_PX + LAB_PX - 1) >= PNL_Y0 and (r * LAB_PX) < PNL_Y1:
                for c in range(G.LAB_COLS):
                    if (c * LAB_PX + LAB_PX - 1) >= PNL_X0 and (c * LAB_PX) < PNL_X1:
                        lab_mem[r][c] = 0
        for r in range(len(val_mem)):
            if (r * VAL_PX_Y + VAL_PX_Y - 1) >= PNL_Y0 and (r * VAL_PX_Y) < PNL_Y1:
                for c in range(G.VAL_COLS):
                    if (c * VAL_PX_X + VAL_PX_X - 1) >= PNL_X0 and (c * VAL_PX_X) < PNL_X1:
                        val_mem[r][c] = 0
        cells = undo_cells(64, True)
        for i, code in enumerate(cells):
            lab_mem[34][46 + i] = code
        # v33（㉚）：键盘模式下 RTL 的 `pnl_lab_cell` 把格行 21 整行抑制
        #   （`((lrow2 == 6'd21) && !pnl_kp_on) || (lrow2 == 6'd34)`）—— 那行字
        #   「倍频分频 / PRESET」正压在第 1 行键（y 328..372）上。格行 34 的
        #   三个按钮标签在键盘下方，键盘模式下 CANCEL/APPLY 仍有效，照画。
        if kp:
            for c in range(G.LAB_COLS):
                lab_mem[21][c] = 0
    # v58（R9）：面板模态只在**面板列**里抑制（格列 >= PNL_X0//LAB_PX = 6）。
    #   整行清会把导航第 6 项「设置」（格行 34 列 1）一起抹掉 —— 上板照片里 P1 左侧
    #   只有 5 项就是这个原因。RTL 侧同步：disp_engine.v 的 glyph_page 加了
    #   `cx[9:4] >= 6` 列门控。
    if page == "p1" and not panel:
        for r in (21, 34):
            for c in range(PNL_X0 // LAB_PX, G.LAB_COLS):
                lab_mem[r][c] = 0
        # v58：RTL 的 glyph_page 除了行 21/34，还排除行 23/25 的数值窗+标签窗
        #   （格列 36..45 / 36..46）—— 这两处是「等效倍率 / AB 边沿率」的模态内容，
        #   面板关着时不许留在页面上。预览图以前没抹，卡片 2 右下角会浮着这两行标签。
        for r, c1 in ((23, 46), (25, 47)):
            for c in range(36, c1):
                lab_mem[r][c] = 0
    # v34（㊲）：对话框那几行字在 P6 上同样只是"模态内容" —— RTL 的 glyph_page 对
    #   dlg_cell 一律不画（`~dlg_cell`），只有 dlg_on 时由 glyph_dlg 画。静态版面图里
    #   抹掉，否则预览图上会浮着「清除锁存故障 / REG 0X0405 / CANCEL / OK」，看起来
    #   像"常显"。★ v42（㊴）：两套对话框行（13/18 与 14/19）都抹；行 22（按钮标签）
    #   只在格列 >= 16 的一侧归对话框，格列 1 的导航页签「时序」必须留着。
    if page == "p6" and not dz_dlg:
        # ★ v60（T2）：只抹格列 >= 6 的一侧。整行抹会把导航页签一起抹掉 ——
        #   导航「波形」的格行正好是 14，与「恢复默认」对话框标题行同格行，
        #   上板照片 m03131 里设置页少一项就是这个原因（RTL 同步改了 dlg_cell0）。
        for r in DLG_PAGE_ROWS:
            for c in range(PNL_X0 // LAB_PX, G.LAB_COLS):
                lab_mem[r][c] = 0
        for c in range(DLG_BTN_COL_MIN // LAB_PX, G.LAB_COLS):
            lab_mem[DLG_ROW_BTN][c] = 0
    # v31（㉘）：P5 的文字层走虚拟格网（RAM 行 8..14 → 30 px 行带 / 188 px 列），
    #   其余页仍是 16 px 全局格网。
    #   ★ 演示状态时同时换掉那四格的字符码：不然会出现"警示色块里写着 ● 正常"
    #     这种自相矛盾的图（运行期是 stat_chip 每帧改写这四格）。
    if page == "p1" and chip_demo is not None:
        for i, st in enumerate(chip_demo):
            if st == 0:
                continue
            cells = (49, 0, 136, 137) if st == 1 else (50, 0, 97, 98)
            r = P1_CHIP_ROW[i // 3]
            c0 = P1_CHIP_COL[i % 3]
            for k, code in enumerate(cells):
                lab_mem[r][c0 + k] = code
    if page == "p5":
        draw_p5_lab(px, lab_mem)
    elif page == "p6" and dz_dlg:
        # v41（㊳）/ v42（㊴）：询问态的合成顺序（照 RTL 的 compose）
        #   dlg_on 时对话框之外**整屏** C_DIM（连标题带与导航竖条都压暗）；
        #   框内只有 glyph_dlg（对话框自己的三行字，按 kind 选 13/18 或 14/19）；
        #   唯一被 dz_keep 放行的是危险区**两颗**按钮矩形 —— 它们的脸（C_DLG_PINK）
        #   与标签（lab 行 34）仍在。所以这里只画这三样，页面其它内容一律不画。
        for bx0, bx1, by0, by1 in DZ_BTNS:
            for y in range(by0, by1):
                for x in range(bx0, bx1):
                    px[x, y] = C_DLG_PINK
            for x in range(bx0, bx1):
                px[x, by0] = C_FAULT
                px[x, by1 - 1] = C_FAULT
            for y in range(by0, by1):
                px[bx0, y] = C_FAULT
                px[bx1 - 1, y] = C_FAULT
        box_only = [[0] * G.LAB_COLS for _ in range(G.LAB_ROWS)]
        for r in (DLG_LAB_ROWS if dz_kind == 0 else DLG_LAB_ROWS1):
            for c in range(DLG_X0 // LAB_PX, DLG_X1 // LAB_PX):
                if r == DLG_ROW_BTN and c * LAB_PX < DLG_BTN_COL_MIN:
                    continue            # 行 22 的格列门控（让出导航栏页签）
                box_only[r][c] = lab_mem[r][c]
        for bx0, bx1, _, _ in DZ_BTNS:
            for c in range(bx0 // LAB_PX, bx1 // LAB_PX):
                box_only[34][c] = lab_mem[34][c]       # 按钮标签：格行 34
        draw_plane(img, px, box_only, G.LAB_COLS, G.LAB_ROWS, LAB_PX, LAB_PX, lab_rows, C_TEXT)
    elif page == "p6":
        # v42（㊴）：恢复**失败**时，把没回读上的那一项的标题格换成红 ✖（字符码 50，
        #   与 RTL `lab_ch_ovr = bad_mark_cell ? CH_XMARK : lab_ch_raw` 同一套索引）。
        #   位置照 RTL：第 k 行带 → 格行 4+k；三列的 ✖ 落在格列 12/32/52。
        #   ★ 用行带号 k（不是自然格行）：P6 的行带是虚拟的，标题墨迹横跨 1~2 个
        #     自然格行（见 disp/disp_engine.v:959-963 的同一段教训）。
        #   ★ 颜色：RTL 只把这一格的墨迹涂红（bad_mark2），所以这里把 (行, 列)
        #     交给 draw_p6_planes 用 bad_col 画，而不是整格刷红。
        bad_cells = ()
        if dz_state == 2:
            for k, n in dz_bad:
                lab_mem[P6_LAB_R0 + k][(12, 32, 52)[n]] = 50
            bad_cells = tuple((P6_LAB_R0 + k, (12, 32, 52)[n]) for k, n in dz_bad)
        # v41（㊳）：左侧 80 px 导航竖条按全局 16 px 格网，内容列走 88 px 虚拟格网。
        draw_plane(img, px, lab_mem, G.LAB_COLS, G.LAB_ROWS, LAB_PX, LAB_PX,
                   lab_rows, C_TEXT, c0=0, c1=P6_X0 // LAB_PX)
        # ★ v42（㊴）补：危险区两颗按钮的标签在格行 34（y 544..559），落在危险区里、
        #   不在 88 px 行带内 ⇒ 走全局 16 px 格网（RTL 的 p6_map 只管 y 64..504 的
        #   带区，行 34 由页面层画）。这一行此前**从来没画过**：静态预览图上两颗按钮
        #   是空框，而仿真台的 sc_dz_lbl / sc_dz_lbl2 累加器一直在判它 —— 属于
        #   "预览件看不见的反馈"，正是本工具该照出来的东西。
        draw_plane(img, px, lab_mem, G.LAB_COLS, G.LAB_ROWS, LAB_PX, LAB_PX,
                   lab_rows, C_TEXT, c0=P6_X0 // LAB_PX, r0=34, r1=35)
        # ★ v58 复查补：标题带那颗「闪烁」按钮的标签在格行 2（y 32..47），
        #   既不在 88 px 行带里、也不在危险区的行 34 ⇒ 上面两次都漏画，
        #   静态图上按钮是空框（上板照片里是有字的）。与 RTL 的页面层一致：
        #   p6_map 只管 y 64..504，标题带仍走全局格网。
        draw_plane(img, px, lab_mem, G.LAB_COLS, G.LAB_ROWS, LAB_PX, LAB_PX,
                   lab_rows, C_TEXT, c0=TBTN_X0 // LAB_PX, r0=2, r1=3)
        draw_p6_planes(px, lab_mem, val_mem, bad_cells=bad_cells)
    else:
        draw_plane(img, px, lab_mem, G.LAB_COLS, G.LAB_ROWS, LAB_PX, LAB_PX, lab_rows, C_TEXT)
    if page != "p6":
        if page == "p1":
            # ★ v59：P1 数值格 48 px 节距、字形仍取 64 行字库的 8..55 行
            draw_plane(img, px, val_mem, G.VAL_COLS, val_rows_n, VAL_PX_X, VAL_PX_Y_P1,
                       val_rows, C_TEXT, y_off=VAL_Y_OFF_P1)
        else:
            draw_plane(img, px, val_mem, G.VAL_COLS, G.VAL_ROWS, VAL_PX_X, VAL_PX_Y, val_rows, C_TEXT)
    # v59：P1 状态四格由 stat_chip 写，预览在这里补画（六卡全正常）
    if page == "p1" and not panel:
        draw_p1_chips(img, px)
    # v31（㉘）：状态条反色块必须在文字层之后（要认出字形像素再改白）
    if page == "p1" and chip_demo is not None:
        invert_chip_bands(px, chip_demo)
    return img


def draw_p1_chips(img, px, states=(0, 0, 0, 0, 0, 0)):
    """v59：P1 状态四格（由 disp/stat_chip.v 每帧写入，不在 text_ram 里）。

    格行 7/19/31 = 三排卡片的状态带；格列 30/60 = 左右两列卡片的右端。
    默认六张卡全"正常"，预览图与上电初值一致。
    """
    sym = {0: "●", 1: "▲", 2: "✖"}
    word = {0: ("正", "常"), 1: ("警", "示"), 2: ("故", "障")}
    for ci, st in enumerate(states):
        row = (7, 19, 31)[ci // 2]
        col = (30, 60)[ci % 2]
        for k, ch in enumerate((sym[st], " ", word[st][0], word[st][1])):
            bits, width = lab_rows(ch)
            x0 = (col + k) * LAB_PX
            y0 = row * LAB_PX
            for gy in range(LAB_PX):
                v = bits[gy]
                if v == 0:
                    continue
                for gx in range(LAB_PX):
                    bit = width - 1 - gx
                    if bit < 0:
                        break
                    if (v >> bit) & 1:
                        px[x0 + gx, y0 + gy] = C_TEXT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", type=int, default=1)
    # v58：输出目录可指定。默认仍是 _disp_work/，但沙箱把该目录标成中完整性
    #   （低完整性进程写不进去）时，可以用 `--out _preview` 落到工作区根下自检。
    ap.add_argument("--out", default="", help="输出目录（默认 _disp_work）")
    args = ap.parse_args()
    if not PIL:
        print("FAIL: Pillow is not available")
        return 1

    out = Path(args.out) if args.out else ROOT / "_disp_work"
    out.mkdir(exist_ok=True)
    # v58：页表和 RTL 的存活页表对一遍 —— 文字层（gen_text_ram.py）与预览件是
    #   两个文件，任何一边删页/加页而另一边没跟上，出的图就是假版面。
    #   ★ 这里**故意硬失败**（返回 2），不要回退到"只画能画的几页"。
    tags = tuple(t for t, _lab, _val in G.PAGES)
    if tags != UIG.PAGE_TAGS:
        print("FAIL: 文字层页表 %r 与存活页表 %r 不一致（tools/ui_geom.py）"
              % (tags, UIG.PAGE_TAGS))
        return 2
    for page, lab, val in G.PAGES:
        img = render(page, lab, val)
        if args.scale != 1:
            img = img.resize((W * args.scale, H * args.scale), Image.NEAREST)
        p = out / ("page_%s.png" % page)
        img.save(p)
        print("wrote %s  (%dx%d)" % (p, img.width, img.height))
    # v24：P1 再出一张"面板开着"的图 —— 静态图上模态行是空的，
    #   只有这张能看到「↩ 回到 ×64」（`undo_lab` 的运行期内容）。
    for page, lab, val in G.PAGES:
        if page != "p1":
            continue
        img = render(page, lab, val, panel=True)
        if args.scale != 1:
            img = img.resize((W * args.scale, H * args.scale), Image.NEAREST)
        p = out / "page_p1_panel.png"
        img.save(p)
        print("wrote %s  (%dx%d)" % (p, img.width, img.height))
    # v25：真圆环也只在"按下"时画，静态图与上面那张面板图都没有它 ——
    #   再出一张按住 [−] 长按 32/64 的图（环带 26..30 px、12 点起顺时针半圈）。
    for page, lab, val in G.PAGES:
        if page != "p1":
            continue
        img = render(page, lab, val, panel=True, press="mns", prog=32)
        if args.scale != 1:
            img = img.resize((W * args.scale, H * args.scale), Image.NEAREST)
        p = out / "page_p1_panel_ring.png"
        img.save(p)
        print("wrote %s  (%dx%d)" % (p, img.width, img.height))
    # v31（㉘）：反色块只在"非正常"时才有，而静态遥测六张卡全是正常 ——
    #   再出一张用演示状态的图（卡 5 警示 / 卡 6 故障），人眼核对"色块边界与
    #   状态条四格重合、白字压在色块上"。它**不代表**静态版面的实际状态。
    for page, lab, val in G.PAGES:
        if page != "p1":
            continue
        img = render(page, lab, val, chip_demo=P1_CHIP_DEMO)
        if args.scale != 1:
            img = img.resize((W * args.scale, H * args.scale), Image.NEAREST)
        p = out / "page_p1_chip.png"
        img.save(p)
        print("wrote %s  (%dx%d)" % (p, img.width, img.height))
    # v33（㉚）：数字键盘只在"点开入口按钮"之后才出现（模态），静态版面里没有 ——
    #   再出一张演示图：输入窗里是 256（合同上限）、面板标题行被抑制、[−]/[+]
    #   与滑条不画、入口按钮也不画（它已被键盘取代）。它**不代表**默认画面。
    for page, lab, val in G.PAGES:
        if page != "p1":
            continue
        img = render(page, lab, val, panel=True, kp=True, kp_sel=5)
        if args.scale != 1:
            img = img.resize((W * args.scale, H * args.scale), Image.NEAREST)
        p = out / "page_p1_kp.png"
        img.save(p)
        print("wrote %s  (%dx%d)" % (p, img.width, img.height))
    # v34（㊲）/ v42（㊴）：危险区的按下内嵌框、两套对话框、恢复结果（绿描边 / 红 ✖）
    #   都是"运行期"才有，静态版面图里没有 —— 出演示图供人眼核对（**不代表**默认画面）：
    #     · page_p6_dz_press / _press2：第 1 / 第 2 颗按钮按住 = 里侧一道 2 px 内嵌红框
    #       （形状编码），按钮内部仍是脸（不是整块染色），危险区其它部分不变；
    #     · page_p6_dz_dlg / _dlg2：询问态 = **两颗**按钮矩形都不被遮罩压暗 + 底色变浅
    #       （24'hFBD9D6），危险区其余部分照旧压暗，对话框盖在中间；_dlg2 是 v42 新增的
    #       「恢复默认」标题/正文行（格行 14/19），_dlg 是「清除锁存故障」（13/18）；
    #     · page_p6_rst_ok / _bad：按 OK 跑完 13 条命令后的结果 —— 成功 = 第 2 颗描边
    #       转绿（C_OK）、17 项数值全部回到默认；失败 = 描边保持红 + 没回读上的那一项
    #       标题右侧一个红 ✖（这里演示 (1,1) 限幅 与 (4,2) 相位修正 两项失败）。
    for page, lab, val in G.PAGES:
        if page != "p6":
            continue
        for name, extra in (("page_p6_dz_press.png",  {"dz_press": True}),
                            ("page_p6_dz_press2.png", {"dz_press2": True}),
                            ("page_p6_dz_dlg.png",    {"dz_dlg": True}),
                            ("page_p6_dz_dlg2.png",   {"dz_dlg": True, "dz_kind": 1}),
                            ("page_p6_rst_ok.png",    {"dz_state": 1}),
                            ("page_p6_rst_bad.png",   {"dz_state": 2,
                                                       "dz_bad": ((1, 1), (4, 2))})):
            img = render(page, lab, val, **extra)
            if args.scale != 1:
                img = img.resize((W * args.scale, H * args.scale), Image.NEAREST)
            p = out / name
            img.save(p)
            print("wrote %s  (%dx%d)" % (p, img.width, img.height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
