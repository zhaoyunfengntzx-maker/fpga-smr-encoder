r"""波形导出（需求 M6）：把"当前波形"存成一张能直接发给人看的 PNG。

用法（在仓库根目录）：
    python host\export_png.py --selftest      # 离线自检（造数据→出图→查像素）

为什么不清屏截图，而是重新画一张大图：
* 界面里的波形只有 250 px 高，发到微信/贴进报告看不清；重新出图可以给到
  1900×1000 像素、dpi 150，曲线粗细与字体都按打印来。
* 界面上是"每 0.3 秒重画一次"的实时视图，导出时把当时的快照一次性画全，
  顺便把读数（频率、幅值、圆度、判定、板上门限）直接写在图上 —— 图离开界面
  也能自证，收到图的人不用再问"这图什么时候、什么配置下测的"。

**本文件不 import Qt**：只依赖 matplotlib + 同目录的纯逻辑模块（alarm/abz/theme 的
色值副本），因此可以离线自检、也可以在无界面环境（长稳测试）里出图。
"""

import os
import sys
import time

# matplotlib 中文字体：必须在别的 mpl 子模块之前设置（与 panel_wave/panel_abz 一致）
# ★ 这里必须容错：main_window 在模块顶部就 import 本文件，若 matplotlib 缺失而这里抛异常，
#   整个界面都起不来（panel_wave/panel_abz 都做了 HAS_MPL 兜底，导出这条路径也要兜住）
try:
    import matplotlib
    # 只用 Figure + savefig，不碰 pyplot：界面里已经有一堆 Qt 画布，切后端会互相打架
    matplotlib.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False

    from matplotlib.figure import Figure       # noqa: E402
    from matplotlib.gridspec import GridSpec   # noqa: E402
    HAS_MPL = True
except Exception:                                               # pragma: no cover
    matplotlib = None
    Figure = GridSpec = None
    HAS_MPL = False

_NO_MPL_MSG = "没装 matplotlib，导不了图（pip install matplotlib）"

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


def _writable_dir():
    """自检要落盘的临时目录。

    源码运行时落在 `host/` 下（便于查看）；打包成 exe 后 `__file__` 指向
    PyInstaller 的临时解包目录，退出即被删、且不一定可写
    ⇒ 改用 `tempfile` 的系统临时目录。
    """
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        import tempfile                                           # noqa: PLC0415
        return tempfile.gettempdir()
    return _HERE

import abz as az                           # noqa: E402  （host/abz.py，纯逻辑）
import alarm as sg                        # noqa: E402  （host/alarm.py，纯逻辑）

# 配色与界面一致：**从 theme 取**（theme 只依赖 os/sys，不拖 Qt 进导出路径）
# ★ 阶段 3 修：这里原先抄了一份色值，改主题时导出图会留在旧配色上（两处不同步）。
import theme as th                         # noqa: E402

C = th.C

DPI_DEFAULT = 150
WAVE_SIZE = (13.0, 7.2)                     # 英寸 ⇒ 1950×1080 像素
ABZ_SIZE = (13.0, 6.6)


# ----------------------------------------------------------------- 公共小工具
def _stamp(t_wall=None):
    return time.strftime("%Y-%m-%d %H:%M:%S",
                         time.localtime(t_wall if t_wall is not None else time.time()))


def _meta_lines(meta):
    """把 meta 字典整理成图顶部的若干行文字（每行最多约 100 个字符）。"""
    try:
        m = dict(meta or {})
    except (TypeError, ValueError):
        # 传了字符串/列表这种不是字典的东西：原样显示，别把导出打断
        return [str(meta)] if meta else []
    line1 = m.pop("line1", None) or []
    if isinstance(line1, str):
        line1 = [line1]
    out = [str(x) for x in line1 if x]
    # ★ 判空用 `is not None`：`if v` 会把 0 / 0.0 / "" / False 这些有意义的值丢掉
    #   （比如"坏帧 0"就整条不显示了）；键可能是 int/str 混用，排序要按 str
    rest = [str(v) for _k, v in sorted(m.items(), key=lambda kv: str(kv[0]))
            if v is not None]
    if rest:
        out.append("　|　".join(rest))
    return out


def _draw_header(fig, title, meta, y=0.975):
    """左上角标题 + 顶部信息行（信息写进图里，图自己就能说明来路）。"""
    fig.text(0.012, y, title, fontsize=15, color=C["text"], weight="bold",
             ha="left", va="top")
    lines = _meta_lines(meta)
    for i, ln in enumerate(lines):
        fig.text(0.012, y - 0.028 * (i + 1), ln, fontsize=9, color=C["muted"],
                 ha="left", va="top")
    return len(lines)


def _style_ax(ax):
    ax.grid(True, color=C["line"], linewidth=0.6, alpha=0.95)
    ax.tick_params(labelsize=8, colors=C["muted"])
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(C["line"])
    ax.set_facecolor(C["card"])


def _save(fig, path, dpi):
    """保存并回收 figure；返回写入结果（失败不抛异常，交给调用方提示）。"""
    info = {"ok": False, "path": None, "bytes": 0, "px": (0, 0), "error": None}
    existed = True                          # 失败清理用：只在"本次新建"时才删半截文件
    try:
        path = os.path.abspath(path)
        # ★ 目标是个目录时 matplotlib 会悄悄把图写到"同级 <目录名>.png"，而我们还报
        #   ok=True + 目录路径（真踩过）⇒ 直接判错，别让调用方以为导出成功
        if os.path.isdir(path):
            info["path"] = path
            info["error"] = "存图失败：%s 是个文件夹，不是文件名" % path
            fig.clf()
            return info
        if not os.path.splitext(path)[1]:
            # 没有后缀：matplotlib 会写成 path + ".png"，这里补上，保证返回的路径就是
            # 磁盘上真实存在的那一个（否则 getsize 报"找不到文件"、ok 变 False）
            path += ".png"
        info["path"] = path
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            # ★ exist_ok=True（自查发现）：并发/竞态下别把 FileExistsError 报成"存图失败"
            os.makedirs(d, exist_ok=True)
        existed = os.path.exists(path)      # unique_path 保证不存在；真存在就别在失败时删人家
        fig.savefig(path, dpi=dpi, facecolor=C["card"])
        info["bytes"] = os.path.getsize(path)
        info["px"] = (int(fig.get_size_inches()[0] * dpi),
                      int(fig.get_size_inches()[1] * dpi))
        info["ok"] = True
    except Exception as exc:                                    # noqa: BLE001
        info["error"] = "存图失败：%s（磁盘满或文件夹只读？）" % exc
        # ★ 失败时别留下半截 PNG（自查发现）：用户看到文件会以为存成功了。
        #   只删"本次新建且确实存在"的那个 —— 原来就存在的文件绝不动。
        try:
            if not existed and info.get("path") and os.path.isfile(info["path"]):
                os.remove(info["path"])
        except Exception:                                       # noqa: BLE001
            pass
    finally:
        try:
            fig.clf()                      # 不经过 pyplot，直接回收画布
        except Exception:                                       # noqa: BLE001
            pass
    return info


# ------------------------------------------------------------- 输入信号波形图
def _amp_limits(meta):
    """从 meta 里取板上幅值门限 (r 低, r 高)；没有就 (None, None)。

    支持两种给法：直接给平方值 amp_low_sq/amp_high_sq（与界面同源），或给已换算的
    元组 meta["门限"]。这几个键只用于换算，不进图顶部那行说明文字。
    """
    m = meta or {}
    if m.get("amp_low_sq") and m.get("amp_high_sq"):
        return sg.amp_limits(m["amp_low_sq"], m["amp_high_sq"])
    if isinstance(m.get("门限"), (list, tuple)) and len(m["门限"]) == 2:
        return float(m["门限"][0]), float(m["门限"][1])
    return None, None


def _header_meta(meta):
    """顶行说明文字的 meta：把只用于换算的内部键去掉。"""
    ml = dict(meta or {})
    for k in ("门限", "amp_low_sq", "amp_high_sq"):
        ml.pop(k, None)
    return ml


def export_wave_png(path, snap, meta=None, dpi=DPI_DEFAULT, view=None):
    """导出"输入信号波形"：左时域快照、右李萨如圆，读数写在图上。

    snap = host/alarm.py WaveBuffer.snapshot() 的字典
           （键：n/s/c/ang/t/r_mean/r_min/r_max/roundness/clip/r/span_s）
    view = 面板当前视图（host/panel_wave.py WavePanel.scope_view()）：
           {"xlim": [a, b], "ylim": [c, d], "text": "量程：…"}；给 None 时导全貌
    """
    if not HAS_MPL:
        return {"ok": False, "path": path, "bytes": 0, "px": (0, 0), "error": _NO_MPL_MSG}
    n = int((snap or {}).get("n") or 0)
    fs = float(getattr(sg, "FS", 32767.0))
    lim = fs * 1.12
    fig = Figure(figsize=WAVE_SIZE, dpi=dpi, facecolor=C["card"])
    gs = GridSpec(2, 12, figure=fig, height_ratios=[0.34, 1.0],
                  left=0.05, right=0.985, top=0.995, bottom=0.075,
                  hspace=0.02, wspace=0.85)
    inv = fig.add_subplot(gs[0, :])
    inv.axis("off")
    ax_t = fig.add_subplot(gs[1, :7])
    ax_l = fig.add_subplot(gs[1, 7:])
    for ax in (ax_t, ax_l):
        _style_ax(ax)

    head = ["输入信号波形（s_n / c_n）"]
    if view:
        head.append("当前视图")
    ml = _header_meta(meta)
    ml.setdefault("导出时间", _stamp())
    if view and view.get("text"):
        ml.setdefault("量程", str(view["text"]).replace("量程：", ""))
    _draw_header(fig, "　".join(head), ml, y=0.987)

    r_low, r_high = _amp_limits(meta)
    # ★ ylim 必须在 if n 之外算：空数据时下面 set_ylim(ylim[0], ylim[1]) 也要用（自检 [5]）
    ylim = list(view["ylim"]) if (view and view.get("ylim")) else [-lim, lim]

    if n:
        t = snap["t"]
        x = [(v - t[-1]) * 1000.0 for v in t]           # ms，0 = 最新帧
        y_s, y_c = list(snap["s"]), list(snap["c"])
        split = bool(view) and (ylim[1] - ylim[0]) > 2.4 * lim
        if split:
            # 与面板的"分离"排布一致：s_n 上移、c_n 下移各半个通道间距
            off = (ylim[1] - ylim[0]) / 2.0 - lim
            y_s = [v + off for v in y_s]
            y_c = [v - off for v in y_c]
        ax_t.plot(x, y_s, lw=0.9, color=C["primary"], label="s_n")
        ax_t.plot(x, y_c, lw=0.9, color=C["warn"], label="c_n")
        ax_l.plot(snap["c"], snap["s"], lw=0.9, color=C["secondary"], label="c–s 轨迹")
        r = float(snap["r_mean"] or 0.0)
        import math                                          # noqa: PLC0415
        circ = [(r * math.cos(a / 64.0 * 6.2831853),
                 r * math.sin(a / 64.0 * 6.2831853)) for a in range(65)]
        ax_l.plot([p[0] for p in circ], [p[1] for p in circ], lw=0.9, ls="--",
                  color=C["ok"], label="半径参考线 r=%.0f" % r)
        ax_t.legend(loc="upper right", fontsize=8, framealpha=0.85)
        ax_l.legend(loc="upper right", fontsize=8, framealpha=0.85)
        ax_t.set_title("时域快照 %d 帧（%.1f ms；输入超过 5 kHz 已混叠，只看幅度）"
                       % (n, float(snap.get("span_s") or 0.0) * 1000.0), fontsize=10)
        ax_l.set_title("李萨如 c–s（圆度偏差 %.2f%%）" % (snap.get("roundness") or 0.0),
                       fontsize=10)
        # 读数块：写在时域图空白处，图离开界面也能自证
        level, text = sg.amp_verdict(snap.get("r_mean"), r_low, r_high)
        if snap.get("clip"):
            level, text = "fault", text + "（削顶）"
        col = {"ok": C["ok"], "warn": C["warn"], "fault": C["fault"]}.get(level, C["text"])
        notes = [
            "r 均值 %.0f（%.2f 满量程）" % (snap.get("r_mean") or 0.0,
                                          (snap.get("r_mean") or 0.0) / fs),
            "r 范围 %.0f … %.0f" % (snap.get("r_min") or 0.0, snap.get("r_max") or 0.0),
            "圆度偏差 %.2f%%" % (snap.get("roundness") or 0.0),
            "削顶帧 %d" % int(snap.get("clip") or 0),
        ]
        if r_low is not None:
            notes.append("板上门限 r %.0f … %.0f" % (r_low, r_high))
        ax_t.text(0.015, 0.055, "　".join(notes), transform=ax_t.transAxes,
                  fontsize=8.5, color=C["muted"], va="bottom")
        ax_t.text(0.985, 0.055, "幅值判定：" + text, transform=ax_t.transAxes,
                  fontsize=10, color=col, va="bottom", ha="right", weight="bold")
    else:
        ax_t.set_title("时域快照（等数据）", fontsize=10)
        ax_l.set_title("李萨如 c–s（等数据）", fontsize=10)
        ax_t.text(0.5, 0.5, "还没有收到数据", transform=ax_t.transAxes,
                  fontsize=12, color=C["muted"], ha="center", va="center")

    ax_t.set_xlabel("帧时间轴 (ms，0 = 最新帧)", fontsize=9)
    ax_t.set_ylabel("Q1.15 原始码", fontsize=9)
    if view and view.get("xlim"):
        ax_t.set_xlim(float(view["xlim"][0]), float(view["xlim"][1]))
    else:
        ax_t.set_xlim(-1500 / 10.0, 0.0)
    ax_t.set_ylim(ylim[0], ylim[1])
    ax_l.set_xlabel("c_n", fontsize=9)
    ax_l.set_ylabel("s_n", fontsize=9)
    ax_l.set_xlim(-lim, lim)
    ax_l.set_ylim(-lim, lim)
    ax_l.set_aspect("equal", adjustable="box")
    return _save(fig, path, dpi)


# ------------------------------------------------------ ABZ / UVW 等效采样图
def export_abz_png(path, snap, meta=None, dpi=DPI_DEFAULT, theory=None, view=None):
    """导出"ABZ/UVW 等效采样"：左右两张方波图 + 六状态数据表。

    snap   = host/abz.py AbzAnalyzer.snapshot() 的字典
    theory = host/abz.py AbzAnalyzer.theory(f_in) 的字典（可省）
    view   = 面板当前视图（host/panel_abz.py AbzPanel.scope_view()）：
             {"xlim":[a,b], "ylim":[c,d], "offsets":[oa,ob,oz], "text":"量程：…"}；
             给 None 时导全貌（整圈 360°、通道间距 1.1）
    """
    if not HAS_MPL:
        return {"ok": False, "path": path, "bytes": 0, "px": (0, 0), "error": _NO_MPL_MSG}
    snap = snap or {}
    bins = int(snap.get("bins") or 0)
    fig = Figure(figsize=ABZ_SIZE, dpi=dpi, facecolor=C["card"])
    gs = GridSpec(3, 2, figure=fig, height_ratios=[0.30, 1.0, 0.52],
                  left=0.045, right=0.985, top=0.995, bottom=0.075,
                  hspace=0.34, wspace=0.13)
    fig.add_subplot(gs[0, :]).axis("off")
    ax_ab = fig.add_subplot(gs[1, 0])
    ax_uvw = fig.add_subplot(gs[1, 1])
    ax_tab = fig.add_subplot(gs[2, :])
    for ax in (ax_ab, ax_uvw):
        _style_ax(ax)
    ax_tab.axis("off")

    ml = _header_meta(meta)
    ml.setdefault("导出时间", _stamp())
    if view and view.get("text"):
        ml.setdefault("量程", str(view["text"]).replace("量程：", ""))
        ml.setdefault("视图", "当前视图")
    _draw_header(fig, "ABZ / UVW 等效采样" + ("（当前视图）" if view else ""), ml, y=0.987)

    xs = [i * 360.0 / max(1, bins) for i in range(bins)]
    oa, ob, oz = (list(view.get("offsets") or [2.2, 1.1, 0.0]) if view else [2.2, 1.1, 0.0])
    xlim = list(view["xlim"]) if (view and view.get("xlim")) else [0.0, 360.0]
    ylim = list(view["ylim"]) if (view and view.get("ylim")) else [-0.3, 3.4]

    def step(ax, ys, offset, color, label):
        px = [x for x, y in zip(xs, ys or []) if y is not None]
        py = [y + offset for y in (ys or []) if y is not None]
        if px:
            ax.plot(px, py, drawstyle="steps-post", color=color, linewidth=2.0,
                    label=label)

    step(ax_ab, snap.get("a"), oa, C["primary"], "A")
    step(ax_ab, snap.get("b"), ob, C["warn"], "B")
    step(ax_ab, snap.get("z"), oz, C["ok"], "Z")
    step(ax_uvw, snap.get("u"), oa, C["primary"], "U")
    step(ax_uvw, snap.get("v"), ob, C["warn"], "V")
    step(ax_uvw, snap.get("w"), oz, C["ok"], "W")

    for ax, title in ((ax_ab, "ABZ 等效采样（横轴 = 输入电角度，%d 箱；窗口 %.4g°）"
                       % (bins, xlim[1] - xlim[0])),
                      (ax_uvw, "UVW 等效采样（横轴 = UVW 电角度，6 扇区；窗口 %.4g°）"
                       % (xlim[1] - xlim[0]))):
        ax.set_title(title, fontsize=11, color=C["text"])
        ax.set_xlim(xlim[0], xlim[1])
        ax.set_ylim(ylim[0], ylim[1])
        ax.set_yticks([oz + 0.5, ob + 0.5, oa + 0.5])
    ax_ab.set_yticklabels(["Z", "B", "A"])
    ax_uvw.set_yticklabels(["W", "V", "U"])
    for ax in (ax_ab, ax_uvw):
        ax.set_xticks([0, 60, 120, 180, 240, 300, 360])
        ax.legend(loc="upper right", fontsize=8, ncol=3, framealpha=0.85)
        ax.set_xlabel("电角度 (°)", fontsize=9)
    # 60° 扇区分隔线只在整圈视图里画（放大到 10° 时线会跑到画面外）
    if (xlim[1] - xlim[0]) >= 359.0:
        for k in range(1, 6):
            ax_uvw.axvline(k * 60.0, color=C["line"], linewidth=0.9, alpha=0.95)

    # 六状态数据表（两列三行，顺序与界面卡片一致 = 合法状态码从小到大）
    states = list(snap.get("states") or [])
    share8 = list(snap.get("state_share") or [])
    exp = float(snap.get("state_expected_pct") or (100.0 / 6.0))
    cells = []
    for s in az.LEGAL_STATES:
        nm = az.state_text(s)
        cnt = states[s] if s < len(states) else 0
        pct = share8[s] if s < len(share8) else 0.0
        dev = pct - exp
        col = C["ok"] if abs(dev) <= 2.0 else (C["warn"] if abs(dev) <= 6.0 else C["fault"])
        cells.append((nm, cnt, pct, dev, col))
    ax_tab.text(0.0, 1.04, "UVW 六状态数据表（合法状态各占 1/6 ≈ %.1f%%）" % exp,
                transform=ax_tab.transAxes, fontsize=10.5, color=C["text"],
                va="bottom", weight="bold")
    for i, (nm, cnt, pct, dev, col) in enumerate(cells):
        col_i, row_i = (0 if i < 3 else 1), (i % 3)
        x = 0.02 + col_i * 0.50
        y = 0.82 - row_i * 0.30
        ax_tab.text(x, y, nm, transform=ax_tab.transAxes, fontsize=10.5,
                    color=C["text"], va="center", family="monospace")
        ax_tab.text(x + 0.11, y, "%s 帧" % format(cnt, ","), transform=ax_tab.transAxes,
                    fontsize=10, color=C["muted"], va="center")
        ax_tab.text(x + 0.24, y, "%6.2f%%" % pct, transform=ax_tab.transAxes,
                    fontsize=11, color=col, va="center", weight="bold")
        ax_tab.text(x + 0.32, y, "偏 %+.2f%%" % dev, transform=ax_tab.transAxes,
                    fontsize=9.5, color=col, va="center")

    # 关键读数写一行，免得看图的人还要回去问
    bits = []
    if snap.get("duty_a") is not None:
        bits.append("A/B 占空比 %.1f%% / %.1f%%" % (snap["duty_a"] * 100.0,
                                                   (snap.get("duty_b") or 0.0) * 100.0))
    if snap.get("phase_ab_deg") is not None:
        bits.append("A→B 相位差 %.1f°" % snap["phase_ab_deg"])
    bits.append("箱覆盖率 %d/%d、%d/%d" % (snap.get("cover_ab") or 0, bins,
                                        snap.get("cover_uvw") or 0, bins))
    if snap.get("z_hits") is not None:
        bits.append("Z 命中 %d 箱" % snap["z_hits"])
    if theory:
        bits.append("AB 边沿率 %.3f MHz" % (theory.get("ab_edge_rate", 0.0) / 1e6))
        bits.append("Z 理论 %.1f Hz" % theory.get("z_rate", 0.0))
    ax_tab.text(0.0, -0.02, "　|　".join(bits), transform=ax_tab.transAxes,
                fontsize=9.5, color=C["muted"], va="top")
    return _save(fig, path, dpi)


# ------------------------------------------------------------------- 统一入口
def export(kind, path, data, meta=None, theory=None, dpi=DPI_DEFAULT, view=None):
    """kind = "wave" | "abz"（"*_view" = 按当前视图导出）。返回 _save 的结果字典。

    view 只有 *_view 这类 kind 才会用到；给 None 时按全貌导出。
    """
    if str(kind).startswith("abz"):
        return export_abz_png(path, data, meta=meta, dpi=dpi, theory=theory, view=view)
    return export_wave_png(path, data, meta=meta, dpi=dpi, view=view)


def wave_px(dpi=DPI_DEFAULT):
    """波形图导出后的像素尺寸（宽×高）——自检与验收拿它比对实际文件。

    ★ 取整方式必须与 _save 一致：_save 里用 int() 截断，这里原来用 round()，
    非 150/300 的 DPI 下会差 1 像素（selftest_s5 拿它比文件就假失败）。
    """
    return (int(WAVE_SIZE[0] * dpi), int(WAVE_SIZE[1] * dpi))


def abz_px(dpi=DPI_DEFAULT):
    """ABZ/UVW 图导出后的像素尺寸（宽×高）。取整方式同 _save（见 wave_px ★）。"""
    return (int(ABZ_SIZE[0] * dpi), int(ABZ_SIZE[1] * dpi))


def suggest_name(kind="wave", t_wall=None):
    """建议文件名（**纯 ASCII**）：encoder_wave_20261013_151003.png / encoder_abz_uvw_….png

    "*_view" 这类 kind 会在名字里加 `_view` 段，免得和全貌导出撞名。
    ★ 为什么坚持纯 ASCII：竞赛要求"仓库内所有目录名与文件名必须使用纯英文"，
      而这个名字**会被写进 `deliverables/data/` 与演示视频字幕**，
      中文名一旦跨环境（Linux CI、zip 解包、外文评审）就会变成乱码。
      图内的中文标题不受影响（那是文件内容，不是文件名）。
    """
    tag = "abz_uvw" if str(kind).startswith("abz") else "wave"
    if str(kind).endswith("_view"):
        tag += "_view"
    # ★ t_wall=0.0 是"给了时刻"，不是"没给"：用 is not None 判（原来 `or` 会换成当前时间）
    ts = time.time() if t_wall is None else t_wall
    return "encoder_%s_%s.png" % (tag, time.strftime("%Y%m%d_%H%M%S", time.localtime(ts)))


def unique_path(path):
    """同名文件已存在就加 -2、-3 …（连点两次导出不会把前一张悄悄覆盖掉）。"""
    if not path or not os.path.exists(path):
        return path
    root, ext = os.path.splitext(path)
    for i in range(2, 1000):
        cand = "%s-%d%s" % (root, i, ext)
        if not os.path.exists(cand):
            return cand
    return path


# ==============================================================================
# 离线自检
# ==============================================================================
def _synth_wave_snap(n=1500, f_in=3000.0, amp=0.62, noise=0.004, seed=12345):
    """造一段 s/c 快照：与板上同构（Q1.15、10 kHz 采样、可带噪声）。

    默认取 3 kHz（采样率 10 kHz 的 0.3 倍），这样李萨如是一整圈圆 —— 自检要靠
    "圆上有没有点"判断图有没有画出来；若取 20 kHz（=2.0×采样率）会退化成一个点，
    曲线像素数不足以判定（踩过：s≡0、c≡常数，蓝线整行被"隔行取样"漏掉）。
    """
    import math                                              # noqa: PLC0415
    import random                                            # noqa: PLC0415
    rnd = random.Random(seed)
    fs = float(getattr(sg, "FS", 32767.0))
    data = {"n": n, "s": [], "c": [], "ang": [], "t": []}
    for i in range(n):
        ph = 2.0 * math.pi * (f_in / 10000.0) * i
        s = int((amp + rnd.uniform(-noise, noise)) * fs * math.sin(ph))
        c = int((amp + rnd.uniform(-noise, noise)) * fs * math.cos(ph))
        data["s"].append(s)
        data["c"].append(c)
        data["ang"].append(int((ph / (2.0 * math.pi) * 65536.0)) & 0xFFFF)
        data["t"].append(i / 10000.0)
    buf = sg.WaveBuffer(capacity=max(16, n))
    buf.feed([{"s": data["s"][i], "c": data["c"][i], "angle": data["ang"][i]}
              for i in range(n)])
    return buf.snapshot()


def _hex_rgb(s):
    """'#RRGGBB' → (r, g, b)。"""
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def _read_png(path):
    """用 PIL 读回 PNG，返回 (宽, 高, 非白像素数, 各颜色像素计数)。

    用 getcolors() 在 C 层统计整幅图：逐像素在 Python 里扫 200 万点要好秒，
    而且"每隔一行取样"会把只有一条线宽的平线整行漏掉（自检假失败过）。

    ★ 2026-10-17 全面自查修：目标色**从主题令牌现取**（`th.C`），别再写死调色板。
      画图侧一直用 `C = th.C`（`:233-235`、`:332-336`），而这里原先写的是换令牌
      之前的旧色（primary 旧 `#2E7DD1` vs 现 `#0071E3`）⇒ [2]/[4] 两条断言**恒假
      失败**（两个模块自检不在交付门槛里，谁都没发现）。
    """
    from PIL import Image                                    # noqa: PLC0415
    im = Image.open(path).convert("RGB")
    w, h = im.size
    cols = im.getcolors(maxcolors=1 << 24) or []
    targets = {k: _hex_rgb(th.C[k]) for k in ("primary", "warn", "ok", "secondary")}
    nonwhite = sum(c for c, rgb in cols if tuple(rgb) != (255, 255, 255))
    hits = {}
    for k, t in targets.items():
        hits[k] = sum(c for c, rgb in cols
                      if abs(rgb[0] - t[0]) <= 10 and abs(rgb[1] - t[1]) <= 10
                      and abs(rgb[2] - t[2]) <= 10)
    return w, h, nonwhite, hits


def png_px(path, dpi=DPI_DEFAULT):
    """读回 PNG 的实际像素尺寸，返回 (宽, 高)；读不了就回落到理论的 (0, 0)。

    验收/自检用它核对"导出的确实是大图"，比只看文件大小实在。
    """
    try:
        from PIL import Image                                # noqa: PLC0415
        with Image.open(path) as im:
            return im.size
    except Exception:                                        # noqa: BLE001
        return 0, 0


def selftest(out=None):
    """离线自检：造数据 → 出图 → 读回查像素/尺寸/异常。返回 0/1。"""
    import shutil                                            # noqa: PLC0415
    f = out or sys.stdout
    if not HAS_MPL:                     # 没装 matplotlib：导图这条路根本走不了
        print("跳过：%s" % _NO_MPL_MSG, file=f)
        return 1
    tmp = os.path.join(_writable_dir(), "_png_selftest_tmp")
    ok = True
    try:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp)
    except Exception as exc:                                # noqa: BLE001
        print("建不了自检临时目录：%s（%s）" % (tmp, exc), file=f)
        return 1

    meta = {"line1": ["端口 COM3 · 设备 0x0C · 固件 v12", "输入频率 19999.9 Hz　"
                      "倍频 inter=32 div=1 极对数=4"],
            "门限": (19661.0, 39322.0), "amp_low_sq": 19661 ** 2,
            "amp_high_sq": 39322 ** 2}

    # 1) 波形图：落盘 + 尺寸 + 像素内容
    p1 = os.path.join(tmp, "wave.png")
    t0 = time.perf_counter()
    r1 = export_wave_png(p1, _synth_wave_snap(), meta=meta)
    dt1 = time.perf_counter() - t0
    good = bool(r1["ok"]) and r1["bytes"] > 20000 and os.path.isfile(p1)
    w, h, nw, hits = _read_png(p1) if good else (0, 0, 0, {})
    good &= (w >= 1900 and h >= 1000 and nw > 3000)
    ok &= good
    print("[1] 波形图落盘    %d×%d 像素 / %.1f kB / 非白像素 %s / %.2f s  %s"
          % (w, h, r1["bytes"] / 1024.0, format(nw, ","), dt1,
             "PASS" if good else "FAIL"), file=f)

    # 2) 波形图内容：两条曲线（s=主蓝、c=警示橙）与李萨如（次级蓝）都画上了
    good = (hits.get("primary", 0) > 200 and hits.get("warn", 0) > 200
            and hits.get("secondary", 0) > 100 and hits.get("ok", 0) > 20)
    ok &= good
    print("[2] 波形内容      s_n 蓝 %d 点、c_n 橙 %d 点、轨迹 %d 点、参考圆 %d 点  %s"
          % (hits.get("primary", 0), hits.get("warn", 0),
             hits.get("secondary", 0), hits.get("ok", 0),
             "PASS" if good else "FAIL"), file=f)

    # 3) ABZ 图：落盘 + 尺寸
    an = az.AbzAnalyzer(bins=256, pairs=4, inter=32, div=1, z_width=4)
    an.set_regs({"inter": 32, "div": 1, "pairs": 4, "zwidth": 4})
    an.set_output({"abzen": 1, "uwven": 1})
    frames = az.synth_frames(30000, f_hz=19999.9, pairs=4, inter=32, div=1, z_width=4)
    an.feed(frames)
    snap = an.snapshot()
    p2 = os.path.join(tmp, "abz.png")
    r2 = export_abz_png(p2, snap, meta=dict(meta, **{"配置": "inter=32 div=1 极对数=4"}),
                        theory=an.theory(19999.9))
    good = bool(r2["ok"]) and r2["bytes"] > 20000
    w2, h2, nw2, hits2 = _read_png(p2) if good else (0, 0, 0, {})
    good &= (w2 >= 1900 and nw2 > 3000)
    ok &= good
    print("[3] ABZ 图落盘    %d×%d 像素 / %.1f kB / 非白像素 %s  %s"
          % (w2, h2, r2["bytes"] / 1024.0, format(nw2, ","),
             "PASS" if good else "FAIL"), file=f)

    # 4) ABZ 图内容：A/B/Z（蓝/橙/绿）与 U/V/W 都在（两图共用三色）
    good = (hits2.get("primary", 0) > 200 and hits2.get("warn", 0) > 200
            and hits2.get("ok", 0) > 100)
    ok &= good
    print("[4] ABZ 内容      蓝 %d 点、橙 %d 点、绿 %d 点  %s"
          % (hits2.get("primary", 0), hits2.get("warn", 0), hits2.get("ok", 0),
             "PASS" if good else "FAIL"), file=f)

    # 5) 空数据不崩：还没收到帧就点导出，也要出一张"等数据"的图
    #    ★ r5 必须先给初值：原来它在 try 内赋值、try 外引用，一旦导出真抛异常，
    #      except 打印完就 UnboundLocalError，整个自检崩掉（真踩过）
    p5 = os.path.join(tmp, "empty.png")
    r5 = {"ok": False, "bytes": 0.0}
    try:
        r5 = export_wave_png(p5, sg.WaveBuffer(capacity=1500).snapshot(), meta=meta)
        good = bool(r5["ok"]) and r5["bytes"] > 5000
    except Exception as exc:                                # noqa: BLE001
        good = False
        print("    竟然抛异常了：%s" % exc, file=f)
    ok &= good
    print("[5] 空数据不崩    %.1f kB  %s" % (r5.get("bytes", 0) / 1024.0,
                                            "PASS" if good else "FAIL"), file=f)

    # 6) 目录不存在自动建（含中文路径）
    p6 = os.path.join(tmp, "新建 目录", "子目录", "wave.png")
    r6 = export_wave_png(p6, _synth_wave_snap(300), meta=meta)
    good = bool(r6["ok"]) and os.path.isfile(p6)
    ok &= good
    print("[6] 自动建目录    中文路径 %s  %s"
          % (os.path.relpath(p6, tmp), "PASS" if good else "FAIL"), file=f)

    # 7) 重复导出（按钮会被连点）：覆盖不报错、体积稳定
    r7 = export_wave_png(p1, _synth_wave_snap(300), meta=meta)
    good = bool(r7["ok"]) and abs(r7["bytes"] - r1["bytes"]) > 0
    ok &= good
    print("[7] 重复导出      %.1f kB → %.1f kB（覆盖成功）  %s"
          % (r1["bytes"] / 1024.0, r7["bytes"] / 1024.0,
             "PASS" if good else "FAIL"), file=f)

    # 8) 返回结构齐全（界面要拿它提示"已存到…"）
    good = all(k in r1 for k in ("ok", "path", "bytes", "px", "error")) \
        and r1["px"] == (int(WAVE_SIZE[0] * DPI_DEFAULT),
                         int(WAVE_SIZE[1] * DPI_DEFAULT))
    ok &= good
    print("[8] 返回结构      %s  %s"
          % ({k: r1[k] for k in ("ok", "bytes", "px")}, "PASS" if good else "FAIL"),
          file=f)

    # 9) 性能：单张出图 < 3 s（界面按钮点了不能卡住）
    t0 = time.perf_counter()
    export_wave_png(os.path.join(tmp, "speed1.png"), _synth_wave_snap(), meta=meta)
    dt_a = time.perf_counter() - t0
    t0 = time.perf_counter()
    export_abz_png(os.path.join(tmp, "speed2.png"), snap, meta=meta,
                   theory=an.theory(19999.9))
    dt_b = time.perf_counter() - t0
    good = (dt_b < 3.0)
    ok &= good
    print("[9] 出图耗时      波形 %.2f s、ABZ %.2f s（阈值 3 s）  %s"
          % (dt_a, dt_b, "PASS" if good else "FAIL"), file=f)

    # 10) 建议文件名：中文 + 时间戳 + 后缀
    nm = suggest_name("abz", t_wall=1700000000.0)
    good = nm.startswith("encoder_abz_uvw_") and nm.endswith(".png")
    ok &= good
    print("[10] 建议文件名    %s  %s" % (nm, "PASS" if good else "FAIL"), file=f)

    # 11) ★路径与像素契约（自查修过的四处，回归用）
    bad = []
    # ① 没写后缀：matplotlib 会存成 path+".png"，返回的路径必须就是磁盘上那个文件
    p11 = os.path.join(tmp, "noext")
    r11 = export_wave_png(p11, _synth_wave_snap(120), meta=meta)
    if not (r11["ok"] and r11["path"].endswith(".png") and os.path.isfile(r11["path"])):
        bad.append("无后缀 %r" % (r11,))
    # ② 目标是目录：必须报错，不许报 ok=True（matplotlib 会写到同级 <目录名>.png）
    p12 = os.path.join(tmp, "adir")
    os.makedirs(p12, exist_ok=True)
    r12 = export_wave_png(p12, _synth_wave_snap(120), meta=meta)
    if r12["ok"] or not r12["error"]:
        bad.append("目录当文件 %r" % (r12,))
    # ③ 非 150/300 的 DPI：info.px（int 截断）必须与 wave_px/abz_px 完全一致
    r13 = export_wave_png(os.path.join(tmp, "dpi133.png"), _synth_wave_snap(120),
                          meta=meta, dpi=133)
    if r13["px"] != wave_px(133):
        bad.append("波形 px %r≠%r" % (r13["px"], wave_px(133)))
    r14 = export_abz_png(os.path.join(tmp, "dpi133b.png"), snap, meta=meta, dpi=133)
    if r14["px"] != abz_px(133):
        bad.append("ABZ px %r≠%r" % (r14["px"], abz_px(133)))
    # ④ meta 里的 0/False 不能被吞掉，键类型混用不能崩，非字典不能崩
    #    （_meta_lines 只印"值"，调用方给的值本身就带标签，如"输入频率 19999.9 Hz"）
    if _meta_lines({"坏帧": 0, "帧": 3}) != ["0　|　3"] or \
            _meta_lines({1: "x", "b": "y"}) != ["x　|　y"] or _meta_lines("abc") != ["abc"]:
        bad.append("meta %r" % (_meta_lines({"坏帧": 0, "帧": 3}),))
    # ⑤ t_wall=0.0 是"给了时刻"，不能换成当前时间
    if suggest_name("wave", 0.0) != "encoder_wave_19700101_080000.png":
        bad.append("t_wall=0 → %s" % suggest_name("wave", 0.0))
    good = not bad
    ok &= good
    print("[11] 路径/像素契约 %s  %s"
          % ("（5 项全对）" if good else "、".join(bad), "PASS" if good else "FAIL"), file=f)

    # 12) ★按当前视图导出（批次 3）：
    #     - 像素契约与全貌导出一致（S5 判据不能因为多一个按钮就变）
    #     - 视图真的生效：同一份数据，受限量程的图上"墨水"像素与全貌不同
    #     - 文件名带「当前视图」，不和全貌导出撞名
    bad = []
    snap_w = _synth_wave_snap(1500)
    r_full = export_wave_png(os.path.join(tmp, "v_full.png"), snap_w, meta=meta)
    v_wave = {"xlim": [-20.0, 0.0], "ylim": [-36724.6, 36724.6], "text": "量程：横轴 20 ms（手动）"}
    r_vw = export_wave_png(os.path.join(tmp, "v_wave.png"), snap_w, meta=meta, view=v_wave)
    if r_vw["ok"] != r_full["ok"]:
        bad.append("波形视图 ok %r≠%r" % (r_vw["ok"], r_full["ok"]))
    if r_vw["px"] != wave_px():
        bad.append("波形视图 px %r≠%r" % (r_vw["px"], wave_px()))
    ink_full = _read_png(r_full["path"])[2]
    ink_view = _read_png(r_vw["path"])[2]
    if not (r_full["ok"] and r_vw["ok"] and ink_full != ink_view):
        bad.append("波形视图没生效（墨水 %d = %d）" % (ink_full, ink_view))
    v_abz = {"xlim": [90.0, 180.0], "ylim": [-0.3, 3.4], "offsets": [2.2, 1.1, 0.0],
             "text": "量程：横轴 90°（手动）· 叠加 间距 1.1"}
    r_va = export_abz_png(os.path.join(tmp, "v_abz.png"), snap, meta=meta, view=v_abz)
    if not r_va["ok"] or r_va["px"] != abz_px():
        bad.append("ABZ 视图 %r" % (r_va,))
    v_abz2 = {"xlim": [0.0, 360.0], "ylim": [-0.3, 10.0], "offsets": [8.8, 4.4, 0.0],
              "text": "量程：横轴 360°（自动）· 分离 间距 2.0"}
    r_va2 = export_abz_png(os.path.join(tmp, "v_abz2.png"), snap, meta=meta, view=v_abz2)
    ink_abz1 = _read_png(r_va["path"])[2] if r_va["ok"] else -1
    ink_abz2 = _read_png(r_va2["path"])[2] if r_va2["ok"] else -2
    if not r_va2["ok"] or ink_abz2 == ink_abz1:
        bad.append("ABZ 排布/量程没生效（墨水 %d = %d）" % (ink_abz1, ink_abz2))
    # 文件名用 `_view` 段区分；「当前视图」四个字只出现在图内标题与 meta 行（内容，不是文件名）
    if not suggest_name("wave_view", 1700000000.0).startswith("encoder_wave_view_") or \
            not suggest_name("abz_view", 1700000000.0).startswith("encoder_abz_uvw_view_"):
        bad.append("视图文件名 %s / %s" % (suggest_name("wave_view", 1700000000.0),
                                       suggest_name("abz_view", 1700000000.0)))
    # 空数据 + 视图也不能崩（ylim 在 if n 之外算的原因）
    r_va3 = export("wave_view", os.path.join(tmp, "v_empty.png"), {},
                   meta=meta, view=v_wave)
    if not r_va3["ok"]:
        bad.append("空数据视图 %r" % (r_va3,))
    good = not bad
    ok &= good
    print("[12] 按当前视图导出 墨水 全貌 %d → 视图 %d、ABZ %d/%d  %s"
          % (ink_full, ink_view, ink_abz1, ink_abz2,
             "PASS" if good else "FAIL " + "、".join(bad)), file=f)

    print("自检%s" % ("通过 (PASS)" if ok else "失败 (FAIL)"), file=f)
    shutil.rmtree(tmp, ignore_errors=True)
    return 0 if ok else 1


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if "--selftest" in argv:
        return selftest()
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
