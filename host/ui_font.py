# -*- coding: utf-8 -*-
"""字体装载与"数字不抖"（阶段 3：Apple 视觉落地）。

三件事
------
1. **Inter（OFL 1.1，随包分发）**：`host/assets/fonts/Inter-*.ttf` 按文件注册，
   中文交给系统字体回落（Inter 没有汉字，Qt 会逐字回落到微软雅黑）。
2. **等宽数字**：读数用 Inter 的 `tnum`（tabular figures）特性 —— 数字宽度一致，
   末位跳动时整行不会左右抖；比换一套等宽字体（原先是 Cascadia Mono）更统一，
   也让中英混排不再有两种字形风格。
3. **任何失败都静默回落**：字体是"好看"，起不来界面是"不能用"。用户机器 `%TEMP%`
   写入受限（历史结论），所以只读包内文件、绝不写临时目录。

调用点
------
- `host/app.py`：`QApplication` 建好后立刻 `ui_font.apply(app)`；
- `host/main_window.py`：`MainWindow.__init__` 再调一次（幂等）——
  自检脚本与 `--smoke` 不经过 `app.py`，这样它们看到的也是交付时的字形。
"""
import os

from PySide6.QtGui import QFont, QFontDatabase
from PySide6.QtWidgets import QLabel

import theme as th

FONT_FILES = ("Inter-Regular.ttf", "Inter-Medium.ttf",
              "Inter-SemiBold.ttf", "Inter-Bold.ttf")

BASE_PX = 13                      # 与 theme 的正文一致（QSS 仍会逐条覆盖）

# ---- 字号随窗口自适应（2026-10-16 阶段 5 B 批）----------------------------
# 基准就是最小窗口 1600×900（= 1.0×），窗口更大时按"宽、高各自相对基准的较小比值"
# 放大，上限 1.6×（再大人眼也看不出差别，只会把一屏塞不下）。
BASE_W, BASE_H = 1600, 900
SCALE_MIN, SCALE_MAX = 1.0, 1.6

_registered = 0                   # 幂等标记：重复注册只是浪费几毫秒
_last_px = 0.0                    # 上一次设进 QApplication 的字号（变了才重设）


def available():
    """包内字体文件齐不齐（缺文件不报错，直接回落系统字体）。"""
    return [fn for fn in FONT_FILES
            if os.path.exists(os.path.join(th.FONT_DIR, fn))]


def clamp_scale(scale):
    """把任意缩放系数夹到 [1.0, 1.6]。"""
    try:
        return max(SCALE_MIN, min(SCALE_MAX, float(scale)))
    except Exception:                                             # noqa: BLE001
        return SCALE_MIN


def auto_scale(width, height):
    """窗口逻辑尺寸 → 字号缩放系数（1600×900 = 1.0，上限 1.6）。"""
    try:
        w = max(1.0, float(width) / BASE_W)
        h = max(1.0, float(height) / BASE_H)
    except Exception:                                             # noqa: BLE001
        return SCALE_MIN
    return clamp_scale(min(w, h))


def apply(app=None, px=None):
    """注册 Inter 并设为应用默认字体，返回注册成功的文件数（0 = 回落系统字体）。

    `px` 给应用默认字体的像素尺寸（默认 `BASE_PX`）：字号自适应时它也要跟着变，
    否则"没有在 QSS 里点名"的控件（下拉列表项、消息框、状态栏提示…）还是小字。
    """
    global _registered, _last_px
    try:
        if not _registered:
            n = 0
            for fn in FONT_FILES:
                path = os.path.join(th.FONT_DIR, fn)
                try:
                    if os.path.exists(path) and QFontDatabase.addApplicationFont(path) >= 0:
                        n += 1
                except Exception:                                 # noqa: BLE001
                    pass
            _registered = n
        if _registered:
            from PySide6.QtWidgets import QApplication
            inst = app if app is not None else QApplication.instance()
            target = float(BASE_PX if px is None else px)
            if inst is not None and abs(target - _last_px) > 0.01:
                f = QFont()
                f.setFamilies(th.FONT_FAMILIES)
                f.setPixelSize(int(round(target)))
                inst.setFont(f)
                _last_px = target
        return _registered
    except Exception:                                             # noqa: BLE001
        return 0


def is_loaded():
    """Inter 是否真的进了字体库（自检用）。"""
    try:
        return "Inter" in QFontDatabase.families()
    except Exception:                                             # noqa: BLE001
        return False


def use_tabular(widget):
    """把控件字体换成 Inter + `tnum`（读数用；中文字符照旧走回落）。"""
    try:
        f = QFont(widget.font())
        f.setFamilies(th.FONT_FAMILIES)
        f.setFeature(QFont.Tag("tnum"), 1)
        widget.setFont(f)
        return True
    except Exception:                                             # noqa: BLE001
        return False


def apply_tabular(root):
    """把一棵界面树上所有 `mono="true"` 的标签都打开 `tnum`，返回处理个数。

    ★ 用"扫一遍"而不是在每个 `field()` 里设：页面、面板、动态行（告警 16 行、
    编码器 6 态）都在不同地方建标签，扫一遍最不容易漏；QSS 只管字号/颜色，
    字体族与特性在这里统一收口。
    """
    n = 0
    try:
        for lab in root.findChildren(QLabel):
            if lab.property("mono") in (True, "true"):
                if use_tabular(lab):
                    n += 1
    except Exception:                                             # noqa: BLE001
        pass
    return n


# ---- 当前界面缩放系数（matplotlib 也跟着放大，否则图形里的字会相对变小） -----
_scale = 1.0


def set_scale(scale):
    """记录当前界面缩放系数（由主窗口在应用字号时调用）。"""
    global _scale
    _scale = clamp_scale(scale)
    return _scale


def current_scale():
    return _scale


def pt(base):
    """matplotlib 的字号（pt）× 当前缩放系数。"""
    return float(base) * _scale
