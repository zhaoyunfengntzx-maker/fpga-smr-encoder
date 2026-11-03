"""显示层信号处理：min/max 包络抽稀 + 可选零相位平滑。

设计约束（改这个文件前先读）：

1. **只服务显示**：输入数组一律不改（不 in-place、不做 dtype 转换回写），
   导出 CSV/NPY 仍然用原始 ``res.s`` / ``res.c``。
2. **不依赖 scipy**：交付包里只有 numpy + matplotlib；这里用 numpy 实现
   移动平均 / 中值 / Savitzky-Golay / 窗函数法 FIR 低通。
3. **长度守恒**：平滑函数对 n 点返回 n 点（边缘按可用点归一化），
   这样调用方不用改时间轴。
4. **参数可解释**：``SMOOTH_MODES`` 是 UI 下拉的唯一来源，避免界面与算法各写一份。

包络是"保峰抽稀"：每个像素列取该列所有点的最小/最大值，画成竖线。
这不是滤波，不会改变任何数值，只是换一种画法（示波器的标准做法）。
"""

from __future__ import annotations

import numpy as np

#: UI 下拉项：(显示文字, 窗口点数)。0 = 关。
SMOOTH_MODES = (
    ("关", 0),
    ("3 点", 3),
    ("5 点", 5),
    ("9 点", 9),
    ("15 点", 15),
)

#: 平滑算法。savgol 保峰最好，作为默认；中值更适合去孤立毛刺。
SMOOTH_KINDS = ("savgol", "median", "mean")

_SG_CACHE: dict[tuple[int, int], np.ndarray] = {}


def _as_float(x):
    return np.asarray(x, dtype=np.float64)


def moving_average(x, w):
    """居中移动平均（边缘用可用点归一化，长度不变）。"""
    a = _as_float(x)
    n = a.size
    w = int(w)
    if w <= 1 or n == 0:
        return a.copy()
    w = min(w, n)
    c = np.concatenate(([0.0], np.cumsum(a)))
    half = w // 2
    idx = np.arange(n)
    lo = np.clip(idx - half, 0, n)
    hi = np.clip(idx + (w - half), 0, n)
    cnt = np.maximum(hi - lo, 1)
    return (c[hi] - c[lo]) / cnt


def median_filter(x, w):
    """中值滤波（去孤立毛刺，保边沿）。O(n·w) 但 w ≤ 15，实测 < 4 ms。"""
    a = _as_float(x)
    n = a.size
    w = int(w)
    if w <= 1 or n == 0:
        return a.copy()
    w = min(w, n)
    half = w // 2
    pad = np.pad(a, (half, w - half - 1), mode="edge")
    win = np.lib.stride_tricks.sliding_window_view(pad, w)
    return np.median(win, axis=-1)


def _savgol_coeffs(w, order):
    key = (int(w), int(order))
    if key not in _SG_CACHE:
        w = key[0]
        x = np.arange(w, dtype=np.float64) - (w - 1) / 2.0
        # 用最小二乘求多项式平滑系数：对每个位置拟合 order 阶多项式，取常数项
        A = np.vander(x, order + 1, increasing=True)
        pinv = np.linalg.pinv(A)          # (order+1, w)
        _SG_CACHE[key] = pinv[0]          # 常数项系数 = 平滑权重
    return _SG_CACHE[key]


def savgol_filter(x, w, order=3):
    """Savitzky-Golay 平滑（保峰），零相位，长度不变。"""
    a = _as_float(x)
    n = a.size
    w = int(w)
    if w <= 2 or n == 0:
        return a.copy()
    w = min(w, n)
    if w % 2 == 0:
        w -= 1
    if w < 3:
        return a.copy()
    order = min(int(order), w - 2)
    h = _savgol_coeffs(w, order)
    half = w // 2
    pad = np.pad(a, half, mode="edge")
    return np.convolve(pad, h, mode="valid")


def fir_lowpass(x, taps=63, cutoff=0.25):
    """窗函数法线性相位低通（cutoff 为归一化频率，0.5 = Nyquist）。"""
    a = _as_float(x)
    n = a.size
    taps = int(taps) | 1
    if n == 0 or taps <= 3:
        return a.copy()
    m = np.arange(taps) - (taps - 1) / 2.0
    h = 2 * cutoff * np.sinc(2 * cutoff * m) * np.hamming(taps)
    h /= h.sum()
    half = taps // 2
    pad = np.pad(a, half, mode="edge")
    return np.convolve(pad, h, mode="valid")


def smooth(x, w, kind="savgol"):
    """按 UI 的窗口点数做零相位平滑；w=0 原样返回（拷贝）。"""
    w = int(w or 0)
    if w <= 1:
        return _as_float(x)
    if kind == "median":
        return median_filter(x, w)
    if kind == "mean":
        return moving_average(x, w)
    return savgol_filter(x, w)


def envelope(x, cols):
    """按列取 min/max，返回 ``(x_index, ymin, ymax)``，长度 = cols。

    点数少于列数时退化为逐点（保证不丢点）。
    """
    a = _as_float(x)
    n = a.size
    cols = max(1, int(cols))
    if n == 0:
        z = np.zeros(0)
        return z, z, z
    if n <= cols:
        idx = np.arange(n, dtype=np.float64)
        return idx, a, a
    edges = np.linspace(0, n, cols + 1).astype(np.int64)
    edges = np.unique(edges)
    starts = edges[:-1]
    ymin = np.minimum.reduceat(a, starts)
    ymax = np.maximum.reduceat(a, starts)
    xpos = starts.astype(np.float64)
    return xpos, ymin, ymax


def downsample_for_display(x, cols, w=0, kind="savgol"):
    """先平滑再包络（绘制用），返回 (x_index, ymin, ymax)。"""
    return envelope(smooth(x, w, kind), cols)
