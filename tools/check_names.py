"""用标准库 symtable 找"引用了但没定义/没导入"的全局名（离线静态检查，不需要跑界面）。

为什么要这个：拆分把代码搬到了新模块，最容易漏的就是"原来在 main_window 里随便可见的
模块级别名"（C / uk / SQUARE_POINTS / TAG_TEXT…）。这类漏的在运行时只在特定分支炸，
自检没走到就发现不了 —— 用它一次扫干净。

用法：python -X utf8 tools/_check_names.py [文件...]（不给文件就扫 host/*.py）
"""
import builtins
import io
import os
import symtable
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = os.path.join(os.path.dirname(HERE), "host")

# 这些名字由 Qt 的 Signal/Slot 机制或宿主实例动态提供，静态检查会误报
WHITELIST = {"__file__", "__name__", "__doc__", "__package__", "__builtins__",
             "self", "cls", "super"}


def scan(path):
    src = io.open(path, encoding="utf-8").read()
    st = symtable.symtable(src, path, "exec")
    module_defs = set()
    for sym in st.get_symbols():
        if sym.is_assigned() or sym.is_imported() or sym.is_namespace():
            module_defs.add(sym.get_name())
    bad = []

    def walk(table, outer_defined):
        for sym in table.get_symbols():
            if sym.is_global() and sym.get_name() not in module_defs:
                nm = sym.get_name()
                if nm not in WHITELIST and not hasattr(builtins, nm):
                    bad.append((table.get_name(), nm))
        for child in table.get_children():
            walk(child, outer_defined)

    walk(st, set())
    return bad


def main(argv):
    files = argv[1:] or [os.path.join(HOST, f) for f in sorted(os.listdir(HOST))
                         if f.endswith(".py")]
    total = 0
    for p in files:
        try:
            bad = scan(p)
        except SyntaxError as exc:
            print("[语法] %s: %s" % (p, exc))
            total += 1
            continue
        for owner, nm in bad:
            print("[未定义] %s: %s() 用了 %s" % (os.path.basename(p), owner, nm))
        total += len(bad)
    print("扫描 %d 个文件，可疑引用 %d 处" % (len(files), total))
    return 0 if total == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
