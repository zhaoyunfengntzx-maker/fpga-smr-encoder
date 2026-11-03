# -*- coding: utf-8 -*-
"""给 tools/*.ps1 补回 UTF-8 BOM（缺了就是一类"脚本一行不跑"的隐形故障）。

为什么需要这个脚本：
    Windows PowerShell 5.1 读 `.ps1` 时，**没有 BOM 就按 ANSI/GBK 解码**。
    本目录的脚本正文和注释里全是中文，被 GBK 误解码之后，某个汉字的第二个
    字节可能恰好是 0x22（`"`）或 0x7B（`{`），于是 PowerShell 抛出
    "字符串缺少终止符" / "意外的标记"，而且**报错行号指向一个完全正确的行**。
    排查成本极高，所以这里把它变成一条可自动检查的规则。

    另一半原因：仓库里有一批工具会顺手重写文本文件（格式化、追加章节、
    生成文档），而"重写"经常会把 BOM 丢掉 —— 编辑一次就坏一次。

用法：
    python tools/fix_ps1_bom.py          # 只检查，报告缺失项，不修改
    python tools/fix_ps1_bom.py --fix    # 实际补上 BOM

退出码: 0 = 全部正常（或已修复）；1 = 检查模式下发现有缺失
"""
import glob
import os
import sys

BOM = b"\xef\xbb\xbf"


def main():
    fix = "--fix" in sys.argv[1:]
    here = os.path.dirname(os.path.abspath(__file__))
    files = sorted(glob.glob(os.path.join(here, "*.ps1")))
    missing = []

    for path in files:
        with open(path, "rb") as fh:
            head = fh.read(3)
        name = os.path.basename(path)
        if head == BOM:
            print("  [ok]   %s" % name)
            continue
        missing.append(path)
        if fix:
            with open(path, "rb") as fh:
                body = fh.read()
            with open(path, "wb") as fh:
                fh.write(BOM + body)
            print("  [fix]  %s  (BOM added)" % name)
        else:
            print("  [MISS] %s  (no UTF-8 BOM)" % name)

    print("")
    print("==== %d 个 .ps1 / %d 个缺 BOM ====" % (len(files), len(missing)))

    if missing and not fix:
        print("")
        print("这些脚本在 Windows PowerShell 5.1 下可能因为中文注释被误解码而")
        print("报出与真实原因无关的语法错误。用 `python tools/fix_ps1_bom.py --fix` 修复。")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
