# -*- coding: utf-8 -*-
"""Apple 视觉令牌 + 全局样式表（阶段 3）。

设计来源：`docs/16_host_ui_refactor_R16_R20.md` §7（Apple 视觉设计令牌草案）。
色板只在这里定义一次，界面代码一律引用 `C[...]`；改配色只改这个文件。

与 §7 草案的两处偏差（阶段 3 走查记录在案，理由见 docs/16 §11）
--------------------------------------------------------------
1. **页标题 22px 而不是 28px**：28px 是"英雄数值"字号，落在 `#BigValue`（读数）上；
   页标题要让位给数据，22px 已足够分级。
2. **正文 13px、次要 12px 而不是 15/13px**：最小窗口 1600×900 且要求"一屏一事"，
   15px 正文会让「实时」页在最小窗口下出现纵向滚动（阶段 3 走查实测）。

字体
----
Inter（OFL 1.1，随包分发，见 `host/assets/fonts/`）+ 逐字回落
`Segoe UI Variable` / `Segoe UI` / 微软雅黑。**Inter 没有汉字**，中文由回落字体渲染，
这是刻意的（Inter 的拉丁字形 + 雅黑的汉字是这套字号阶梯下最好看的组合）。
"""
import os
import re
import sys

# ----------------------------------------------------------------- 包内资源路径


def _bundle_dir():
    """包内只读资源根目录。

    - 源码模式：`host/`；
    - PyInstaller 冻结（目录版）：`sys._MEIPASS`（= `<dist>/host_app/_internal`）。

    ★ 注意别和 `ui_prefs._home_dir()`（exe **旁边**、可写）搞混：
    字体与图标是只读资源，必须从解包目录读（用户机器 `%TEMP%` 写入受限的历史结论）。
    """
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        return getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(sys.executable)))
    return os.path.dirname(os.path.abspath(__file__))


ASSET_DIR = os.path.join(_bundle_dir(), "assets")
FONT_DIR = os.path.join(ASSET_DIR, "fonts")
IMG_DIR = os.path.join(ASSET_DIR, "img")


def _url(path):
    """样式表里的 url(...) 只认正斜杠。"""
    return path.replace("\\", "/")


IMG = {
    "chk_off": _url(os.path.join(IMG_DIR, "chk_off.png")),
    "chk_on": _url(os.path.join(IMG_DIR, "chk_on.png")),
    "sw_off": _url(os.path.join(IMG_DIR, "sw_off.png")),
    "sw_on": _url(os.path.join(IMG_DIR, "sw_on.png")),
}

# ----------------------------------------------------------------- 色板（Apple）

C = {
    "bg":         "#F5F5F7",   # 页面底色（Apple 的系统灰）
    "card":       "#FFFFFF",   # 卡片底色
    "primary":    "#0071E3",   # 单一强调色：按钮 / 选中 / 曲线 s_n / A·U
    "primary_hi": "#0077ED",   # 主按钮悬停
    "primary_lo": "#006EDB",   # 主按钮按下
    "primary_soft": "#E8F1FD", # 强调色浅底（选中行、次要按钮悬停）
    "secondary":  "#5AC8FA",   # 次级蓝：曲线 2 / 轨迹 / 进度条
    "text":       "#1D1D1F",   # 正文
    "muted":      "#6E6E73",   # 次要文字
    "line":       "#E5E5EA",   # 分隔线 / 卡片描边（1px 细线，不加重边框）
    "line_input": "#D2D2D7",   # 输入控件描边（比分隔线深一档）
    "field":      "#F5F5F7",   # 次级按钮 / 只读底
    "ok":         "#34C759",   # 正常（只表状态）
    "warn":       "#FF9F0A",   # 警告（只表状态；c_n 曲线沿用历史约定）
    "fault":      "#FF3B30",   # 故障（只表状态）
    "chip_off":   "#E5E5EA",   # 指示灯灭
    "ok_soft":    "#EAF7EE",   # 状态浅底
    "warn_soft":  "#FFF4E5",
    "fault_soft": "#FDECEA",
    "info_soft":  "#E8F1FD",
    "disabled":   "#AEAEB2",   # 禁用文字（Apple 的 systemGray）
}

FONT_FAMILIES = ["Inter", "Segoe UI Variable", "Segoe UI",
                 "Microsoft YaHei UI", "Microsoft YaHei"]
FONT_FAMILY = ", ".join('"%s"' % f for f in FONT_FAMILIES) + ", sans-serif"
# 只有「⑪ 通信日志」还用等宽字体：原始应答要按列对齐看（Inter 的 tnum 只保证数字等宽）
MONO_FAMILY = '"Cascadia Mono", "Consolas", monospace'


def app_qss(scale=1.0):
    """全局样式表。`scale` = 字号自适应系数（1.0 = 最小窗口 1600×900 的基准）。

    `scale != 1.0` 时**统一缩放样式表里所有 `Npx`**（字号、内边距、圆角、控件最小宽高、
    滚动条宽度…）：一处基准、一处缩放，避免"改字号忘了改输入框高度"这类漏改。
    """
    qss = _BASE_QSS.format(font=FONT_FAMILY, mono=MONO_FAMILY,
                           **dict(C, **IMG))
    try:
        scale = float(scale)
    except (TypeError, ValueError):
        return qss
    if abs(scale - 1.0) < 1e-6:
        return qss
    return _PX.sub(lambda m: "%dpx" % max(1, int(round(float(m.group(1)) * scale))), qss)


_PX = re.compile(r"(\d+(?:\.\d+)?)px")

_BASE_QSS = """
QWidget {{
    background: {bg};
    color: {text};
    font-family: {font};
    font-size: 13px;
}}
QScrollArea, QScrollArea > QWidget > QWidget {{ background: transparent; }}
QStackedWidget#Pages {{ background: transparent; }}
/* 卡片里的文字标签不画底色，免得出现一条条色带 */
QLabel {{ background: transparent; }}

/* ---------- 卡片（白底 + 12px 圆角 + 1px 细线；不做重边框，也不上阴影特效） ---------- */
QFrame#Card {{
    background: {card};
    border: 1px solid {line};
    border-radius: 12px;
}}
QLabel#CardTitle {{
    color: {text};
    font-size: 17px;
    font-weight: 600;
    padding: 0 0 2px 0;
}}
QLabel#Hint {{ color: {muted}; font-size: 12px; }}
QLabel#FieldName {{ color: {muted}; font-size: 13px; }}
QLabel#BigUnit {{ color: {muted}; font-size: 11px; }}

/* ---------- 阶段 2（R17）：左侧窄侧栏 / 顶栏 / 页标题 ---------- */
QFrame#Sidebar {{
    background: {bg};
    border: none;
    border-right: 1px solid {line};
}}
QLabel#AppTitle {{ font-size: 17px; font-weight: 600; color: {text}; }}
QLabel#AppSub {{ color: {muted}; font-size: 11px; }}
QLabel#NavSep {{ background: {line}; }}
QPushButton#NavItem {{
    background: transparent;
    border: none;
    border-radius: 8px;
    padding: 8px 12px;
    text-align: left;
    color: {text};
    font-size: 13px;
}}
QPushButton#NavItem:hover {{ background: rgba(0, 0, 0, 0.045); }}
QPushButton#NavItem:checked {{
    background: {primary};
    color: #FFFFFF;
    font-weight: 600;
}}
QFrame#TopBar {{
    background: {card};
    border: none;
    border-bottom: 1px solid {line};
}}
QLabel#PageTitle {{ font-size: 22px; font-weight: 600; color: {text}; }}
QLabel#PageSub {{ color: {muted}; font-size: 12px; }}

/* 批次 4：挡位步进按钮（◀ ▶ / − +）—— 小方块，鼠标移上去才显主色 */
QToolButton#StepBtn {{
    background: {card};
    border: 1px solid {line_input};
    border-radius: 8px;
    padding: 0;
    color: {text};
    font-size: 14px;
    font-weight: bold;
    min-width: 26px;
    max-width: 30px;
    min-height: 26px;
}}
QToolButton#StepBtn:hover {{ border-color: {primary}; color: {primary}; }}
QToolButton#StepBtn:pressed {{ background: {primary_soft}; }}
QToolButton#StepBtn:disabled {{ color: {disabled}; border-color: {line}; }}

/* ---------- 大字号数值（"英雄数字"用 28px，正好是 §7 阶梯的顶端） ---------- */
QLabel#BigValue {{
    font-size: 28px;
    font-weight: 600;
    color: {text};
}}
QLabel#BigValueSmall {{
    font-size: 22px;
    font-weight: 600;
    color: {text};
}}

/* ---------- 按钮 ---------- */
QPushButton {{
    background: {field};
    border: 1px solid transparent;
    border-radius: 8px;
    padding: 7px 14px;
    color: {text};
}}
QPushButton:hover {{ background: {primary_soft}; }}
QPushButton:pressed {{ background: {line}; }}
QPushButton:disabled {{ color: {disabled}; background: {field}; }}
QPushButton:focus {{ border-color: {primary}; }}
QPushButton#Primary {{
    background: {primary};
    border: 1px solid {primary};
    color: #FFFFFF;
    font-weight: 600;
    padding: 8px 22px;
}}
QPushButton#Primary:hover {{ background: {primary_hi}; border-color: {primary_hi}; }}
QPushButton#Primary:pressed {{ background: {primary_lo}; border-color: {primary_lo}; }}
QPushButton#Primary:disabled {{ background: {line}; border-color: {line};
                                color: #FFFFFF; }}
QPushButton#Danger {{ background: {card}; border: 1px solid {fault}; color: {fault}; }}
QPushButton#Danger:hover {{ background: {fault_soft}; }}
/* 概览页的「查看 ›」是**链接式**按钮：不画底、只在悬停时给一点浅底 */
QPushButton#Ghost {{
    background: transparent;
    border: none;
    color: {primary};
    font-weight: 600;
    padding: 3px 8px;
}}
QPushButton#Ghost:hover {{ background: {primary_soft}; }}
QPushButton#Ghost:pressed {{ background: {line}; }}

/* ---------- 输入控件 ---------- */
QComboBox, QLineEdit, QSpinBox {{
    background: {card};
    border: 1px solid {line_input};
    border-radius: 8px;
    padding: 6px 10px;
    min-height: 20px;
    selection-background-color: {primary};
    selection-color: #FFFFFF;
}}
QComboBox:hover, QLineEdit:hover, QSpinBox:hover {{ border-color: {muted}; }}
QComboBox:focus, QLineEdit:focus, QSpinBox:focus {{ border-color: {primary}; }}
QComboBox::drop-down {{ border: none; width: 22px; }}
QComboBox QAbstractItemView {{
    background: {card};
    border: 1px solid {line};
    border-radius: 8px;
    selection-background-color: {primary};
    selection-color: #FFFFFF;
    outline: none;
    padding: 4px;
}}
QSpinBox::up-button, QSpinBox::down-button {{
    width: 18px;
    border: none;
    background: transparent;
}}

/* ---------- 勾选：macOS 的圆角方框（默认）与开关（`switch="true"`） ---------- */
QCheckBox {{ spacing: 7px; }}
QCheckBox::indicator {{
    width: 18px;
    height: 18px;
    image: url({chk_off});
}}
QCheckBox::indicator:checked {{ image: url({chk_on}); }}
QCheckBox::indicator:disabled {{ image: url({chk_off}); }}
QCheckBox[switch="true"]::indicator {{
    width: 36px;
    height: 20px;
    image: url({sw_off});
}}
QCheckBox[switch="true"]::indicator:checked {{ image: url({sw_on}); }}

/* ---------- 滚动条（细、悬停变深；不画箭头按钮） ---------- */
QScrollBar:vertical {{
    background: transparent;
    width: 11px;
    margin: 2px;
}}
QScrollBar::handle:vertical {{
    background: {line_input};
    border-radius: 4px;
    min-height: 32px;
}}
QScrollBar::handle:vertical:hover {{ background: {muted}; }}
QScrollBar:horizontal {{
    background: transparent;
    height: 11px;
    margin: 2px;
}}
QScrollBar::handle:horizontal {{
    background: {line_input};
    border-radius: 4px;
    min-width: 32px;
}}
QScrollBar::handle:horizontal:hover {{ background: {muted}; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

/* ---------- 日志 ---------- */
QPlainTextEdit#Log {{
    background: {card};
    border: 1px solid {line};
    border-radius: 10px;
    font-family: {mono};
    font-size: 12px;
    color: {text};
    selection-background-color: {primary};
    selection-color: #FFFFFF;
}}

/* ---------- 状态栏 ---------- */
QStatusBar {{ background: {card}; color: {muted}; font-size: 12px;
              border-top: 1px solid {line}; }}
QStatusBar::item {{ border: none; }}

/* ---------- 表格（后续里程碑用） ---------- */
QTableWidget {{
    background: {card};
    border: 1px solid {line};
    border-radius: 10px;
    gridline-color: {line};
}}
QHeaderView::section {{
    background: {bg};
    color: {muted};
    border: none;
    border-right: 1px solid {line};
    border-bottom: 1px solid {line};
    padding: 5px 8px;
}}

/* ---------- 提示气泡 ---------- */
QToolTip {{
    background: {card};
    color: {text};
    border: 1px solid {line_input};
    border-radius: 8px;
    padding: 6px 9px;
}}
"""



def level_color(level):
    """ok / warn / fault / idle → 颜色。"""
    return {
        "ok": C["ok"],
        "warn": C["warn"],
        "fault": C["fault"],
        "idle": C["muted"],
        "info": C["primary"],
    }.get(level, C["muted"])
