"""界面参数记忆（界面优化批次 3）：示波器量程 / 通道间距 / 日志级别 / 窗口尺寸。

存放在与本文件同目录的 `ui_prefs.json`（Windows 下 `pythonw` 单文件 exe 也写在这里旁边）。

★ 唯一铁律：**读/写失败都不许影响界面**。
  文件损坏、键被手改成字符串、值超范围、磁盘只读 —— 一律静默回到默认值，
  绝不把异常抛进 Qt 槽（那会把刷新链打断，用户看到的是整块面板卡死）。

取值一律走 `value()` / `number()` / `choice()` 三个夹取函数，界面代码不许直接信任
`data[...]` 里的东西 —— 这个文件是**用户能手改的**。
"""

from __future__ import annotations

import json
import os
import sys

VERSION = 1

# ★ 2026-10-16：默认宽由 1180 提到 1600 —— R16 已定"最小 1600×900"，而 1180 宽时卡片⑧ 的
#   控制行会被裁掉（该卡片控制栅格 sizeHint ≈665 px，窄于此就露出半个按钮；见 DEV_STATUS §1.85.7）。
DEFAULT_WINDOW_W = 1600
DEFAULT_WINDOW_H = 900
MIN_WINDOW_W = 900
MIN_WINDOW_H = 600
MAX_WINDOW_W = 6000
MAX_WINDOW_H = 4000

DEFAULTS = {
    "version": VERSION,
    "window": {"w": DEFAULT_WINDOW_W, "h": DEFAULT_WINDOW_H},
    "log": {"level": "info"},
    # R2 输入波形：x/y 量程 + 通道排布 + 触发源
    # ★ trig 必须在这里登记（自查发现）：`_merge()` 只遍历默认键，没登记的键
    #   "存得下、读不回" —— 触发源每次启动都被悄悄打回默认。
    "wave": {"x_mode": "auto", "x_span_ms": 300.0,
             "y_mode": "auto", "y_full": 1.0,
             "layout": "overlay", "trig": "s"},
    # ★ 界面字号倍率（同上：以前没登记，用户调过的字号每次启动回落 0）
    "ui": {"scale": 0.0},
    # R3 ABZ/UVW 等效采样：横轴档位 + 通道排布与间距
    "abz": {"x_mode": "auto", "x_span_deg": 360.0,
            "center_deg": 180.0, "layout": "overlay", "spacing": 1.1},
    # R20 读数显示层：raw=False ⇒ 显示稳定值（悬停看原始值）；True ⇒ 全部显示原始值
    "display": {"raw": False},
    # 数据源（m03198）：net = 网口连续流（默认，起不来自动退回串口）/ serial = 串口遥测
    # tau_us：板上角度字的流水线延时（µs），延时补偿用。上板实测 0.32（见 docs/42 §22）。
    # ★ 必须登记，否则"存得下、读不回"。
    "data": {"src": "net", "tau_us": 0.32},
    # 抓包页显示平滑窗口（0=关，3/5/9/15）。★ 必须在这里登记：_merge() 只遍历
    # 默认键，没登记的键"存得下、读不回"（本文件 :35 的老坑，自检 selftest_display 抓到）
    "capture": {"smooth": 0},
}

_cache = None
_path_override = None
_HERE = os.path.dirname(os.path.abspath(__file__))


def _home_dir():
    """参数文件该落在哪个目录。

    ★ 打包成单文件 exe 后 `__file__` 在临时解包目录（`%TEMP%\\_MEIxxxx`，退出即删），
    往里写参数等于没写（下次开窗读不到）⇒ 冻结时必须落在 **exe 自己所在的目录**
    （用户双击的就是 `host/dist/host_app.exe`，参数文件与它并排，看得见也能删）。
    与 `host/link.py:38-39`、`host/export_png.py:52`、`host/recorder.py:471-472` 同一套判断。
    """
    if getattr(sys, "frozen", False) or hasattr(sys, "_MEIPASS"):
        return os.path.dirname(os.path.abspath(sys.executable))
    return _HERE


def path():
    """参数文件路径；自检会用 `_path_override` 指到临时目录。"""
    if _path_override:
        return _path_override
    return os.path.join(_home_dir(), "ui_prefs.json")


def _merge(base, over):
    """把 over 里的**已知键**按类型合进 base（未知键丢掉，类型不对用默认值）。"""
    out = {}
    for key, dflt in base.items():
        got = over.get(key, None) if isinstance(over, dict) else None
        if isinstance(dflt, dict):
            out[key] = _merge(dflt, got if isinstance(got, dict) else {})
        elif isinstance(dflt, bool):
            out[key] = bool(got) if isinstance(got, bool) else dflt
        elif isinstance(dflt, (int, float)):
            out[key] = float(got) if isinstance(got, (int, float)) and not isinstance(got, bool) else float(dflt)
        else:
            out[key] = got if isinstance(got, str) else dflt
    return out


def load():
    """读一次并缓存。文件不存在/损坏/不是 dict 都回默认值（不抛异常）。"""
    global _cache
    data = None
    try:
        with open(path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:                                            # noqa: BLE001
        data = None
    _cache = _merge(DEFAULTS, data)
    return _cache


def data():
    return _cache if _cache is not None else load()


def save(d=None):
    """写盘；失败返回 False（调用方只记一行日志，不做别的）。"""
    try:
        # 原子写：先写 .tmp 再 os.replace，写一半被终止也不会留下半截 JSON
        # （半截 JSON 下次启动会被静默当成默认值，用户以为"设置没记住"）
        tmp = path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(d if d is not None else data(), fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, path())
        return True
    except Exception:                                            # noqa: BLE001
        return False


# ------------------------------------------------------------------ 夹取取值
def section(name):
    d = data().get(name)
    return d if isinstance(d, dict) else {}


def raw(name, key, default=None):
    return section(name).get(key, default)


def number(name, key, lo, hi, default):
    """取数值并夹到 [lo, hi]；不是数字就用 default（再夹一次）。"""
    v = section(name).get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        v = default
    try:
        v = float(v)
    except Exception:                                            # noqa: BLE001
        v = float(default)
    if v != v:                                                   # NaN
        v = float(default)
    return min(float(hi), max(float(lo), v))


def choice(name, key, allowed, default):
    v = section(name).get(key)
    return v if isinstance(v, str) and v in allowed else default


def put(name, key, value):
    """改内存缓存（真正落盘由主窗口在关窗时统一做，避免每次滚轮都写盘）。"""
    d = data()
    sec = d.get(name)
    if not isinstance(sec, dict):
        sec = {}
        d[name] = sec
    sec[key] = value


def window_size():
    w = int(number("window", "w", MIN_WINDOW_W, MAX_WINDOW_W, DEFAULT_WINDOW_W))
    h = int(number("window", "h", MIN_WINDOW_H, MAX_WINDOW_H, DEFAULT_WINDOW_H))
    return w, h


# ------------------------------------------------------------------ 自检
def selftest():
    """自检：损坏文件/越界值/错类型都回落默认，put+save+load 往返一致。"""
    import tempfile
    global _cache
    ok = 0
    fail = 0

    def check(name, cond, info=""):
        nonlocal ok, fail
        if cond:
            ok += 1
            print("  [OK] %s%s" % (name, ("　" + info) if info else ""))
        else:
            fail += 1
            print("  [!!] %s%s" % (name, ("　" + info) if info else ""))

    real_path = path()
    # ★ 临时目录必须放在本文件旁边，而且要用 os.makedirs 建：
    #   ① 本机沙箱只允许写会话工作区，系统 %TEMP% 下建得出来却写不进去；
    #   ② `tempfile.mkdtemp()` 建出来的目录（0700）在沙箱里写文件会被拒
    #      （PermissionError: bad.json）—— makedirs 才行。上一轮失败留下的目录顺延编号。
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_uiprefs_selftest_tmp")
    tmpdir = base
    for i in range(2, 8):
        if not os.path.exists(tmpdir):
            try:
                os.makedirs(tmpdir)
                break
            except OSError:
                pass
        tmpdir = "%s_%d" % (base, i)

    def use(tmp):
        global _path_override
        _path_override = tmp

    try:
        # ① 文件不存在 ⇒ 默认值
        use(os.path.join(tmpdir, "nope.json"))
        _cache = None
        d = load()
        check("文件不存在时用默认值", d["wave"]["x_mode"] == "auto" and d["abz"]["spacing"] > 0,
              "x_mode=%s spacing=%.2f" % (d["wave"]["x_mode"], d["abz"]["spacing"]))

        # ② 损坏的 JSON ⇒ 默认值（不抛异常）
        bad = os.path.join(tmpdir, "bad.json")
        with open(bad, "w", encoding="utf-8") as fh:
            fh.write("{ 这不是 json ,,, ")
        use(bad)
        _cache = None
        d = load()
        check("文件损坏时静默回落默认", d["log"]["level"] == "info" and d["window"]["w"] == DEFAULT_WINDOW_W)

        # ③ 顶层不是 dict / 值是错类型 ⇒ 只丢坏键
        bad2 = os.path.join(tmpdir, "bad2.json")
        with open(bad2, "w", encoding="utf-8") as fh:
            fh.write('[1, 2, 3]')
        use(bad2)
        _cache = None
        check("顶层不是对象时不崩", load()["wave"]["x_mode"] == "auto")

        good = os.path.join(tmpdir, "typed.json")
        with open(good, "w", encoding="utf-8") as fh:
            json.dump({"wave": {"x_mode": 7, "x_span_ms": "很宽", "y_full": 0.25},
                       "log": {"level": 5}, "window": {"w": 12345678}}, fh)
        use(good)
        _cache = None
        d = load()
        check("错类型回落默认、好值保留",
              d["wave"]["x_mode"] == "auto" and d["wave"]["x_span_ms"] == 300.0
              and d["wave"]["y_full"] == 0.25 and d["log"]["level"] == "info",
              "y_full=%.2f" % d["wave"]["y_full"])

        # ④ number()/choice() 夹取
        check("number 夹到区间内", number("wave", "y_full", 0.05, 1.2, 1.0) == 0.25)
        put("wave", "y_full", 99.0)
        check("number 上夹取", number("wave", "y_full", 0.05, 1.2, 1.0) == 1.2)
        put("wave", "y_full", float("nan"))
        check("NaN 回落默认", number("wave", "y_full", 0.05, 1.2, 1.0) == 1.0)
        put("wave", "layout", "胡说")
        check("choice 只认白名单", choice("wave", "layout", ("overlay", "split"), "overlay") == "overlay")

        # ⑤ put + save + load 往返一致
        put("wave", "x_mode", "manual")
        put("wave", "x_span_ms", 120.0)
        put("abz", "spacing", 1.6)
        put("log", "level", "debug")
        put("ui", "scale", 1.25)        # ★ 这两项曾因 DEFAULTS 里没有对应键而"存得下、读不回"
        put("wave", "trig", "off")
        put("window", "w", 1500)
        put("window", "h", 1000)
        rt = os.path.join(tmpdir, "round.json")
        use(rt)
        check("save 成功", save() is True)
        _cache = None
        d = load()
        check("往返一致（模式/量程/间距/级别/窗口）",
              d["wave"]["x_mode"] == "manual" and d["wave"]["x_span_ms"] == 120.0
              and d["abz"]["spacing"] == 1.6 and d["log"]["level"] == "debug",
              "%s %.1f ms spacing %.2f %s" % (d["wave"]["x_mode"], d["wave"]["x_span_ms"],
                                              d["abz"]["spacing"], d["log"]["level"]))
        check("window_size 返回夹取后的整数", window_size() == (1500, 1000), str(window_size()))
        check("★ 落盘往返：ui.scale / wave.trig 也能读回（DEFAULTS 缺键的坑）",
              abs(number("ui", "scale", 0.0, 9.9, 0.0) - 1.25) < 1e-9
              and choice("wave", "trig", ("s", "off"), "s") == "off",
              "scale=%.2f trig=%s" % (number("ui", "scale", 0.0, 9.9, 0.0),
                                      choice("wave", "trig", ("s", "off"), "s")))
        put("window", "w", -5)
        put("window", "h", 10 ** 9)
        check("window_size 越界夹取", window_size() == (MIN_WINDOW_W, MAX_WINDOW_H), str(window_size()))

        # ⑥ 目录不可写 ⇒ save 返回 False 且不抛异常
        use(os.path.join(tmpdir, "sub", "x", "y.json"))
        check("目录不存在时 save 返回 False（不抛）", save() is False)

        # ⑦ ★ 冻结（单文件 exe）时参数文件必须落在 exe 旁边，不能落在临时解包目录
        globals()["_path_override"] = None
        src_dir = os.path.dirname(os.path.abspath(__file__))
        try:
            sys.frozen = True                                       # noqa: B010 临时冒充 PyInstaller 冻结态
            frozen_dir = os.path.dirname(os.path.abspath(sys.executable))
            frozen_path = path()
        finally:
            try:
                del sys.frozen
            except AttributeError:
                pass
        check("冻结时参数文件落在 exe 旁边（不是临时解包目录）",
              os.path.dirname(frozen_path) == frozen_dir and os.path.dirname(frozen_path) != src_dir,
              "冻结→%s；源码→%s" % (frozen_path, os.path.join(src_dir, "ui_prefs.json")))
        # ⑧ ★ 静态交叉核对：界面里 put/读 的每个"段/键"都必须在 DEFAULTS 里登记，
        #    否则就是"存得下、读不回"。这条挡的是将来新增记忆项时的漂移。
        import re as _re
        _src = os.path.dirname(os.path.abspath(__file__))
        _pairs = set()
        for _fn in sorted(os.listdir(_src)):
            if not _fn.endswith(".py"):
                continue
            try:
                with open(os.path.join(_src, _fn), "r", encoding="utf-8") as _fh:
                    _txt = _fh.read()
            except Exception:                                        # noqa: BLE001
                continue
            for _m in _re.finditer(r'\bup\.(?:put|raw|number|choice)\(\s*"([^"]+)"\s*,\s*"([^"]+)"', _txt):
                _pairs.add((_fn, _m.group(1), _m.group(2)))
        _bad = []
        for _fn, _sec, _key in sorted(_pairs):
            if not isinstance(DEFAULTS.get(_sec), dict) or _key not in DEFAULTS[_sec]:
                _bad.append("%s: %s.%s" % (_fn, _sec, _key))
        check("★ 界面读写的记忆项都在 DEFAULTS 里（共 %d 项）" % len(_pairs), not _bad,
              ("缺：" + "、".join(_bad)) if _bad else "")
    finally:
        globals()["_path_override"] = None
        globals()["_cache"] = None
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)
        assert path() == real_path

    print("ui_prefs.py 自检：%d 项通过%s" % (ok, "" if fail == 0 else "，%d 项失败" % fail))
    return 0 if fail == 0 else 1


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="界面参数记忆自检")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    print("参数文件：%s" % path())
    print(json.dumps(data(), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
