"""版面几何的唯一来源：从 `disp/disp_engine.v` 的 `localparam` 解析出来。

为什么要有这个文件
------------------
`disp/disp_engine.v` 是版面几何的唯一真值（每个 `localparam` 上面都写着
"为什么是这个数"）。`tools/preview_pages.py` 早期把 80/24/140/560/480 这些
数字**手抄**了一份，于是 RTL 一改（v58 的 P2 波形区、P4 时序框、导航 6 项
改 4 项），预览图就与真值漂移 —— 图上看着没问题，上板却是另一套版面。

现在预览里的每个几何数字都从这里取：解析失败就抛 :class:`GeometryError`，
**绝不**用默认值兜底（兜底等于把"漂移"重新合法化，正是要消灭的那个毛病）。

解析口径
--------
- 认 `localparam` / `parameter`，带或不带位宽（`[11:0]`）、`integer` 等类型词；
- 数值认 `12'd144`、`8'h5A`、二进制/八进制、纯十进制，以及**引用前面已定义
  常量**的四则表达式（如 `FLD_CX = FLD_X0 + 12'd32`）；
- 只认文件里真实存在的声明：注释里的同名文字不会被当成常量（`^[ \t]*` 锚定
  行首，注释行以 `//` 起头，进不来）；
- 少数几何在 RTL 里是**像素通路中的字面量**，没有做成 `localparam`：
  导航 144 px 档距（`nav_idx` 比较链）、P2 中线偏移（`p2_mid`）、P4 的 8 根
  45° 刻度与色块左右内缩（`p4_tick` / `lg_swatch`）。这些按"赋值表达式体"
  定位后取值，取不到同样抛异常，不猜。

谁在用
------
`tools/preview_pages.py`。RTL 只读，本文件只读 RTL。
"""

from __future__ import annotations

import ast
import re
import sys
from collections import OrderedDict, namedtuple
from pathlib import Path

__all__ = [
    "GeometryError",
    "RTL_PATH",
    "PARAMS",
    "COLORS",
    "GEOM",
    "LG",
    "WAVE",
    "NAV",
    "NAV_ITEMS",
    "NAV_H",
    "NAV_Y0",
    "PAGES",
    "PAGE_TAGS",
    "PAGES_BY_TAG",
    "NavItem",
]

ROOT = Path(__file__).resolve().parent.parent
RTL_PATH = ROOT / "disp" / "disp_engine.v"


class GeometryError(RuntimeError):
    """几何常量解析失败。宁可停下来，也不要拿默认值把漂移盖住。"""


def _die(msg):
    raise GeometryError(msg)


# ---------------------------------------------------------------------------
# 一、localparam 表
# ---------------------------------------------------------------------------
#   行首锚定 + 排除注释；RHS 取到分号为止（允许跨行，例如 FLD_CX 那种就算
#   被格式化成两行也能读）。
#   ★ 2026-11-02 修：v68 起 `disp_engine.v` 把 `parameter integer CPR = 0` 写在**模块参数表**里，
#     没有分号结尾（下一行是 `) (`）。旧正则只认 `;`，于是 RHS 一路吃到几十行之后的第一个分号，
#     报 `常量表达式读不懂`，preview_pages.py 自 v68 起其实一直跑不起来（版面漂移因此没人发现）。
#     现在两种收尾都认：`;` 或 `) (`。
_DECL_RE = re.compile(
    r"^[ \t]*(?:localparam|parameter)\b"
    r"(?:[ \t]+(?:integer|int|signed|unsigned|logic|bit|reg|time))*"
    r"(?:[ \t]*\[[^\]]*\])?"
    r"[ \t]+([A-Za-z_]\w*)[ \t]*=[ \t]*([^;]+?)[ \t]*(?:;|\)[ \t]*\()",
    re.MULTILINE,
)

#   Verilog 定宽字面量：12'd144 / 8'h5A / 24'hFFF3CD / 4'b1010 / 6'o17
_LIT_RE = re.compile(r"(\d*)'[sS]?([dDhHbBoO])([0-9a-fA-F_]+)")


def _literal(match):
    base = match.group(2).lower()
    digits = match.group(3).replace("_", "")
    radix = {"d": 10, "h": 16, "b": 2, "o": 8}[base]
    try:
        return str(int(digits, radix))
    except ValueError:
        _die("看不懂的定宽字面量 %r（只支持 0..9/a..f，不支持 x/z）" % match.group(0))


def _vdiv(a, b):
    """Verilog 的 `/` 是**向零截断**，不是 Python 的向下取整。"""
    if b == 0:
        _die("常量表达式里除以 0")
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


_BIN_OPS = {
    ast.Add: lambda a, b: a + b,
    ast.Sub: lambda a, b: a - b,
    ast.Mult: lambda a, b: a * b,
    ast.Div: _vdiv,
    ast.FloorDiv: _vdiv,
    ast.Mod: lambda a, b: a % b,
    ast.LShift: lambda a, b: a << b,
    ast.RShift: lambda a, b: a >> b,
    ast.BitAnd: lambda a, b: a & b,
    ast.BitOr: lambda a, b: a | b,
    ast.BitXor: lambda a, b: a ^ b,
}
_UN_OPS = {ast.UAdd: lambda a: a, ast.USub: lambda a: -a, ast.Invert: lambda a: ~a}


def _eval_node(node, known, where):
    if isinstance(node, ast.Expression):
        return _eval_node(node.body, known, where)
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.Name):
        if node.id not in known:
            _die("%s：表达式引用了未定义（或声明在后面）的常量 %r —— "
                 "本工具只按文件里的声明顺序求值" % (where, node.id))
        return known[node.id]
    if isinstance(node, ast.BinOp) and type(node.op) in _BIN_OPS:
        left = _eval_node(node.left, known, where)
        right = _eval_node(node.right, known, where)
        return _BIN_OPS[type(node.op)](left, right)
    if isinstance(node, ast.UnaryOp) and type(node.op) in _UN_OPS:
        return _UN_OPS[type(node.op)](_eval_node(node.operand, known, where))
    _die("%s：常量表达式里有不支持的语法（只支持 + - * / %% << >> & | ^ ~ 与常量引用）"
         % where)


def _value(expr, known, where):
    src = _LIT_RE.sub(_literal, expr.strip())
    try:
        tree = ast.parse(src, mode="eval")
    except SyntaxError:
        _die("%s：常量表达式读不懂：%r（原文 %r）" % (where, src, expr.strip()))
    return _eval_node(tree, known, where)


def _load(path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:                                      # pragma: no cover
        _die("读不到 RTL 文件 %s：%s" % (path, exc))
    params = OrderedDict()
    for m in _DECL_RE.finditer(text):
        name, rhs = m.group(1), m.group(2)
        line = text.count("\n", 0, m.start()) + 1
        params[name] = _value(rhs, params, "%s:%d %s" % (path.name, line, name))
    if not params:                                              # pragma: no cover
        _die("%s 里一个 localparam 都没解析到 —— 文件被改过？" % path)
    return text, params


_TEXT, PARAMS = _load(RTL_PATH)


# ---------------------------------------------------------------------------
# 二、色板（24 位的 C_* 常量 -> (r, g, b)）
# ---------------------------------------------------------------------------
COLORS = OrderedDict()
for _name, _val in PARAMS.items():
    if _name.startswith("C_") and 0 <= _val <= 0xFFFFFF:
        COLORS[_name] = ((_val >> 16) & 0xFF, (_val >> 8) & 0xFF, _val & 0xFF)


def colour(name):
    """按名字取 RTL 色板；缺了就抛（预览不吃"颜色不对但没人发现"这一套）。"""
    if name not in COLORS:
        _die("disp/disp_engine.v 里没有色板常量 %r（已解析到 %d 个 C_*）"
             % (name, len(COLORS)))
    return COLORS[name]


# ---------------------------------------------------------------------------
# 三、像素通路里的字面量：按赋值表达式体定位
# ---------------------------------------------------------------------------
def _assign_body(sig, kind="wire"):
    """取 `kind <位宽> sig = ...;` 的表达式体。找不到就抛。"""
    pat = re.compile(
        r"^[ \t]*%s\b[^\n;=]*\b%s\b[ \t]*=[ \t]*(.*?);" % (kind, re.escape(sig)),
        re.MULTILINE | re.DOTALL,
    )
    m = pat.search(_TEXT)
    if not m:
        _die("disp/disp_engine.v 里找不到 `%s %s = ...;` —— 这条几何没有 "
             "localparam，只能从这条赋值表达式里读；预览不会猜它"
             % (kind, sig))
    return m.group(1)


def _literals(body, sig_hint, pattern, count=None):
    """从表达式体里抠出字面量列表；条数不对就抛。"""
    found = [int(v) for v in re.findall(pattern, body)]
    if not found:
        _die("%s 的表达式里没有找到预期的字面量（模式 %r）"
             % (sig_hint, pattern))
    if count is not None and len(found) != count:
        _die("%s 的表达式里读到 %d 个字面量，预期 %d 个（%r）—— RTL 结构变了，"
             "请同步 tools/ui_geom.py" % (sig_hint, len(found), count, found))
    return found


# ---------------------------------------------------------------------------
# 四、这一轮预览真正要用的几何（缺一条就报错，列全了再抛）
# ---------------------------------------------------------------------------
_REQUIRED = (
    # 框架：导航栏 / 状态条 / 标题带
    "NAV_W", "SBAR_H", "TITLE_H",
    # P1 卡片墙
    "CARD_X0", "CARD_X1", "CARD_W", "CARD_H", "CARD_Y0", "CARD_Y1", "CARD_Y2",
    # P2 双通道波形框
    "WAVE_X0", "WAVE_X1", "WAVE_A_Y0", "WAVE_A_Y1", "WAVE_B_Y0", "WAVE_B_Y1",
    # P4 逻辑时序框
    "LG_X0", "LG_X1", "LG_Y0", "LG_Y1", "LG_TX0", "LG_TOP", "LG_ROW_H",
    "LG_RAIL_HI", "LG_RAIL_LO", "LG_AXIS",
    # 标题带主操作按钮
    "TBTN_X0", "TBTN_X1", "TBTN_Y0", "TBTN_Y1",
    # P1 模态编辑面板
    "PNL_X0", "PNL_X1", "PNL_Y0", "PNL_Y1",
)


def _geometry(names):
    missing = [n for n in names if n not in PARAMS]
    if missing:
        _die(
            "disp/disp_engine.v 里缺少这些版面常量：%s\n"
            "  预览不再手抄几何，所以这里必须能从 RTL 解析到。"
            "要么 RTL 改了名/删了声明，要么本文件的 _REQUIRED 写错了 —— "
            "两边同步后再跑。" % "、".join(missing)
        )
    return OrderedDict((n, PARAMS[n]) for n in names)


GEOM = _geometry(_REQUIRED)


# ---- P4：6 条通道的颜色与行数（颜色顺序就是道序，见 lg_ch_col 函数）----
_CH_FN = re.search(r"function\s+\[23:0\]\s+lg_ch_col\s*;(.*?)endfunction",
                   _TEXT, re.DOTALL)
if not _CH_FN:
    _die("disp/disp_engine.v 里找不到 `function [23:0] lg_ch_col;` —— "
         "P4 的 6 条通道色块取不到颜色，也没法确定行数")
_LG_CH_NAMES = re.findall(r"\bC_CH_[A-Z]\b", _CH_FN.group(1))
if not _LG_CH_NAMES:
    _die("lg_ch_col 函数体里没读到 C_CH_* 颜色")
_LG_MISSING = [n for n in _LG_CH_NAMES if n not in COLORS]
if _LG_MISSING:
    _die("lg_ch_col 引用了没有定义的色板：%s" % "、".join(_LG_MISSING))

_SW = _literals(_assign_body("lg_swatch"), "lg_swatch",
                r"LG_X0\s*\+\s*\d+'d(\d+)", count=2)
_TICK = _literals(_assign_body("p4_tick"), "p4_tick",
                  r"p4_tx\s*==\s*\d+'d(\d+)")
_TICK_H = _literals(_assign_body("p4_tick"), "p4_tick",
                    r"LG_AXIS\s*\+\s*\d+'d(\d+)", count=1)[0]

LG = OrderedDict((
    ("X0", GEOM["LG_X0"]),
    ("X1", GEOM["LG_X1"]),
    ("Y0", GEOM["LG_Y0"]),
    ("Y1", GEOM["LG_Y1"]),
    ("TX0", GEOM["LG_TX0"]),
    ("TX1", PARAMS["LG_TX1"]),      # 轨迹区右沿（P4 的刻度和底框要用）
    ("TOP", GEOM["LG_TOP"]),
    ("ROW_H", GEOM["LG_ROW_H"]),
    ("ROWS", len(_LG_CH_NAMES)),
    ("RAIL_HI", GEOM["LG_RAIL_HI"]),
    ("RAIL_LO", GEOM["LG_RAIL_LO"]),
    ("AXIS", GEOM["LG_AXIS"]),
    ("SWATCH_X0", GEOM["LG_X0"] + _SW[0]),
    ("SWATCH_X1", GEOM["LG_X0"] + _SW[1]),
    ("TICKS", tuple(GEOM["LG_TX0"] + t for t in _TICK)),
    ("TICK_H", _TICK_H),
    ("CH_NAMES", tuple(_LG_CH_NAMES)),
    ("CH_COLORS", tuple(COLORS[n] for n in _LG_CH_NAMES)),
))

#   ★ 注意（RTL 里的一处自相矛盾，本工具不修 RTL、只如实报出来）：
#     `LG_ROW_H = 68` 与 `LG_TOP/LG_AXIS` 的注释是 v58 R4 的口径
#     （6 行 x 68 = 408，末行轨线 y=452、低轨 496、轴 572），但像素通路
#     （`lg_row` 比较链、`LG_TOP + 12'd288`、`lg_off = row*48`）仍按 **48 px**
#     行距算。也就是说上板现在是"6 行挤在 288 px 里、轴留在 572"。
#     本文件按 localparam（68）渲染 —— 那才是注释与文字层（P4_LAB 的
#     轨线 y = 112+68k）共同描述的目标版面；RTL 的像素通路需另行修正。


# ---- P2：中线（RTL 里是 `ry_a == 12'd99` 的字面量）----
_P2_MIDS = _literals(_assign_body("p2_mid"), "p2_mid",
                     r"ry_[ab]\s*==\s*\d+'d(\d+)", count=2)
if len(set(_P2_MIDS)) != 1:
    _die("p2_mid 的 A/B 中线偏移不相等（%r），预览不知道照哪个画" % (_P2_MIDS,))

WAVE = OrderedDict((
    ("X0", GEOM["WAVE_X0"]),
    ("X1", GEOM["WAVE_X1"]),
    ("A_Y0", GEOM["WAVE_A_Y0"]),
    ("A_Y1", GEOM["WAVE_A_Y1"]),
    ("B_Y0", GEOM["WAVE_B_Y0"]),
    ("B_Y1", GEOM["WAVE_B_Y1"]),
    ("MID", _P2_MIDS[0]),           # 行内中线偏移（= 幅度 0 的位置）
))


# ---------------------------------------------------------------------------
# 五、导航：4 项 x 144 px（档距在 nav_idx 的比较链里，页号在 nav_page 的映射里）
# ---------------------------------------------------------------------------
def _nav_steps():
    body = _assign_body("nav_idx")
    steps = _literals(body, "nav_idx", r"\+\s*\d*'d(\d+)")
    pitch = steps[0]
    if steps != [pitch * (i + 1) for i in range(len(steps))]:
        _die("nav_idx 的档距不是等差（读到 %r）—— 预览按「每项等高」画导航，"
             "RTL 结构变了就画不准" % (steps,))
    return pitch, len(steps) + 1


def _nav_pages(count):
    pages = [int(v) for v in re.findall(r"\b3'd(\d+)", _assign_body("nav_page"))]
    if len(pages) != count:
        _die("nav_page 映射里读到 %d 个页号（%r），但 nav_idx 有 %d 档 —— "
             "RTL 结构变了，请同步 tools/ui_geom.py" % (len(pages), pages, count))
    return tuple(pages)


def _nav_titles(count):
    """导航标题属于**文字层**（gen_text_ram.NAV），不属于几何。"""
    tools = str(ROOT / "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    try:
        import gen_text_ram
    except ImportError as exc:                                  # pragma: no cover
        _die("导航标题要按 tools/gen_text_ram.py 的 NAV 表取，导入失败：%s" % exc)
    titles = tuple(text for _row, _col, text in gen_text_ram.NAV)
    if len(titles) != count:
        _die("gen_text_ram.NAV 里有 %d 项（%r），RTL 导航却是 %d 项 —— "
             "文字层与 RTL 的导航项数对不上" % (len(titles), titles, count))
    return titles


NAV_H, _NAV_COUNT = _nav_steps()
NAV_Y0 = GEOM["SBAR_H"]             # RTL：`nav_sel = in_nav && (cy >= SBAR_H) && ...`
_NAV_PAGES = _nav_pages(_NAV_COUNT)
_NAV_TITLES = _nav_titles(_NAV_COUNT)

NavItem = namedtuple("NavItem", "title page y0 y1")
NAV_ITEMS = tuple(
    NavItem(_NAV_TITLES[i], _NAV_PAGES[i],
            NAV_Y0 + i * NAV_H, NAV_Y0 + (i + 1) * NAV_H)
    for i in range(_NAV_COUNT)
)
NAV = OrderedDict((
    ("W", GEOM["NAV_W"]),
    ("Y0", NAV_Y0),
    ("H", NAV_H),
    ("COUNT", _NAV_COUNT),
    ("ITEMS", NAV_ITEMS),
))


# ---------------------------------------------------------------------------
# 六、存活页表
# ---------------------------------------------------------------------------
#   ★ 页号**不重编号**：P3(2) / P5(4) / P8(7) 已从产品里删除，号留空洞。
#     这张表是"产品里还有哪几页"的声明（文字层的 gen_text_ram.PAGES 与它
#     必须一一对应），**不是**几何；几何一律来自上面的 RTL 解析。
PAGES = OrderedDict((
    (0, "p1"),      # P1 总览
    (1, "p2"),      # P2 输入波形
    (3, "p4"),      # P4 逻辑时序
    (5, "p6"),      # P6 设置
    (6, "p7"),      # P7 标定（从 P1 标题带的「标定」下钻，不在导航里）
))
PAGE_TAGS = tuple(PAGES.values())
PAGES_BY_TAG = OrderedDict((tag, num) for num, tag in PAGES.items())

# ---- 交叉校验：上面这张表必须与 RTL 的导航映射、P7 页号一致 ----
_P7_M = re.search(r"wire\s+p7_lg\s*=\s*\(page == 3'd(\d+)\)", _TEXT)
if not _P7_M:
    _die("disp/disp_engine.v 里找不到 `wire p7_lg = (page == 3'dN);` —— "
         "P7 的页号无从核对")
_P7_PAGE = int(_P7_M.group(1))
if _P7_PAGE not in PAGES:
    _die("RTL 的 P7 页号是 %d，但存活页表里没有它（表：%r）"
         % (_P7_PAGE, dict(PAGES)))
_NAV_ONLY = tuple(k for k in PAGES if k != _P7_PAGE)
if _NAV_ONLY != _NAV_PAGES:
    _die(
        "存活页表与 RTL 导航映射不一致：\n"
        "  页表里除 P7 之外的页号 = %r\n"
        "  RTL 的 nav_page 映射     = %r\n"
        "  导航项 `page` 就是 RTL 的页号，两边必须逐项相同（页号不重编号）。"
        % (_NAV_ONLY, _NAV_PAGES)
    )
