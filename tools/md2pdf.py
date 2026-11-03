#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
md2pdf.py —— 把 docs/*.md 导出成同名 .pdf（本仓库文档导出的**唯一**约定做法）

为什么不用 pandoc：本机没有任何 pandoc 的 PDF 引擎（xelatex / pdflatex / typst /
wkhtmltopdf / weasyprint / soffice **全部不存在**；pandoc 本体在
`E:\\Anaconda\\Library\\bin\\pandoc.exe` 但没有引擎，跑 --pdf-engine 一律失败）。
实测可行且零依赖的路径 =  **python-markdown 转 HTML → Edge 无头打印成 PDF**：
  * `E:\\Anaconda\\python.exe` 里已有 `markdown 3.8`；
  * Windows 自带 Edge（`C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe`），
    支持 `--headless=new --print-to-pdf`，中文字体没问题，表格/代码块都正常。

用法：
    & E:\\Anaconda\\python.exe tools\\md2pdf.py docs\\00_roadmap_30d.md [更多 .md ...]
    & E:\\Anaconda\\python.exe tools\\md2pdf.py --all        # 导出 docs/*.md（含 digest 与 08）

产物：输入文件同目录下的同名 `.pdf`（HTML 中间件写到 `_pdf_out/`，用 `--keep-html` 保留，
默认也会保留以便排查版式问题；`--clean-html` 才删）。

★ 版式约定（改这里就全仓库一致）：
    A4、四边 18 mm、正文 10.5 pt 微软雅黑、代码 9 pt Consolas、
    表格全宽 + 细边框 + 表头灰底、标题分级、代码块浅灰底、`page-break-inside: avoid`
    加在表格行与代码块上（避免跨页断裂）。
"""

import argparse
import io
import pathlib
import os
import subprocess
import sys
import tempfile

try:
    import markdown
except ImportError:  # pragma: no cover
    sys.stderr.write("需要 python-markdown（E:\\Anaconda\\python.exe 里已有）：pip install markdown\n")
    raise

EDGE_CANDIDATES = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
]

CSS = """
@page { size: A4; margin: 18mm 16mm; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body {
  font-family: "Microsoft YaHei", "Segoe UI", "PingFang SC", sans-serif;
  font-size: 10.5pt; line-height: 1.55; color: #111; margin: 0;
}
h1 { font-size: 19pt; border-bottom: 2px solid #444; padding-bottom: 4px; margin: 0 0 14px; }
h2 { font-size: 15pt; border-bottom: 1px solid #999; padding-bottom: 3px; margin: 20px 0 10px; }
h3 { font-size: 12.5pt; margin: 16px 0 8px; }
h4 { font-size: 11pt; margin: 13px 0 6px; }
h5, h6 { font-size: 10.5pt; margin: 11px 0 5px; }
p { margin: 6px 0; }
a { color: #0645ad; text-decoration: none; word-break: break-all; }
code {
  font-family: Consolas, "Courier New", monospace; font-size: 9pt;
  background: #f4f4f4; padding: 1px 3px; border-radius: 3px;
}
pre {
  background: #f7f7f7; border: 1px solid #ddd; border-radius: 4px;
  padding: 8px 10px; overflow-x: auto; page-break-inside: avoid;
}
pre code { background: none; padding: 0; font-size: 8.8pt; line-height: 1.4; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 9.5pt; }
th, td { border: 1px solid #bbb; padding: 4px 6px; text-align: left; vertical-align: top; word-break: break-word; }
th { background: #eef1f5; font-weight: 600; }
tr { page-break-inside: avoid; }
blockquote {
  margin: 8px 0; padding: 6px 10px; border-left: 4px solid #b9c2cc;
  background: #fafbfc; color: #222;
}
ul, ol { margin: 6px 0 6px 22px; padding: 0; }
li { margin: 2px 0; }
hr { border: none; border-top: 1px solid #ccc; margin: 14px 0; }
img { max-width: 100%; }
"""

HTML_TMPL = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<base href="{base}">
<title>{title}</title>
<style>{css}</style>
</head>
<body>
{body}
</body>
</html>
"""

MD_EXTENSIONS = [
    "tables",
    "fenced_code",
    "sane_lists",
    "attr_list",
    "toc",
    "md_in_html",
]


def find_edge():
    for p in EDGE_CANDIDATES:
        if os.path.isfile(p):
            return p
    return None


def build_html(md_path, html_path, keep_style=True):
    with io.open(md_path, "r", encoding="utf-8") as f:
        text = f.read()
    body = markdown.markdown(text, extensions=MD_EXTENSIONS)
    title = os.path.basename(md_path)
    base = pathlib.Path(os.path.abspath(md_path)).parent.as_uri() + "/"
    with io.open(html_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(HTML_TMPL.format(title=title, css=CSS if keep_style else "", body=body, base=base))


def html_to_pdf(edge, html_path, pdf_path, user_data_dir):
    html_uri = "file:///" + os.path.abspath(html_path).replace("\\", "/")
    pdf_abs = os.path.abspath(pdf_path)
    if os.path.exists(pdf_abs):
        os.remove(pdf_abs)
    cmd = [
        edge,
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-pdf-header-footer",
        "--user-data-dir=" + user_data_dir,
        "--print-to-pdf=" + pdf_abs,
        html_uri,
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = proc.stdout.decode("utf-8", "replace").strip()
    ok = os.path.isfile(pdf_abs) and os.path.getsize(pdf_abs) > 1024
    return ok, proc.returncode, out, pdf_abs


def main(argv=None):
    ap = argparse.ArgumentParser(description="docs/*.md -> 同名 .pdf（python-markdown + Edge 无头打印）")
    ap.add_argument("files", nargs="*", help="要导出的 .md（相对或绝对路径）")
    ap.add_argument("--all", action="store_true", help="导出 docs/ 下全部 .md（含 digest/08）")
    ap.add_argument("--outdir", default="_pdf_out", help="HTML 中间件目录（默认 _pdf_out）")
    ap.add_argument("--clean-html", action="store_true", help="导出后删除 HTML 中间件")
    ap.add_argument("--edge", default=None, help="浏览器可执行文件路径（默认自动探测 Edge/Chrome）")
    ap.add_argument("--selftest", action="store_true", help="只用一个小 md 自检整条链路")
    args = ap.parse_args(argv)

    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    edge = args.edge or find_edge()
    if not edge:
        sys.stderr.write("找不到 Edge/Chrome；用 --edge 指定可执行文件。\n")
        return 2

    files = list(args.files)
    if args.all:
        docs = os.path.join(root, "docs")
        for n in sorted(os.listdir(docs)):
            if n.lower().endswith(".md"):
                files.append(os.path.join(docs, n))
    if args.selftest:
        tmp_md = os.path.join(root, "_pdf_out", "_selftest.md")
        os.makedirs(os.path.dirname(tmp_md), exist_ok=True)
        with io.open(tmp_md, "w", encoding="utf-8", newline="\n") as f:
            f.write("# 自检标题\n\n| 列 A | 列 B |\n|---|---|\n| 中文 | `code` |\n\n```\nXOR 校验\n```\n")
        files = [tmp_md]
    if not files:
        ap.error("没有输入文件（用 --all 或给出 .md 路径）")

    outdir = args.outdir if os.path.isabs(args.outdir) else os.path.join(root, args.outdir)
    os.makedirs(outdir, exist_ok=True)
    user_data_dir = os.path.join(root, ".tmp", "edge-profile")
    os.makedirs(user_data_dir, exist_ok=True)

    print("EDGE  : %s" % edge)
    print("HTML  : %s" % outdir)
    print("-" * 72)
    fail = 0
    for md_path in files:
        md_path = os.path.abspath(md_path)
        if not os.path.isfile(md_path):
            print("[MISS] %s" % md_path)
            fail += 1
            continue
        base = os.path.splitext(os.path.basename(md_path))[0]
        html_path = os.path.join(outdir, base + ".html")
        pdf_path = os.path.splitext(md_path)[0] + ".pdf"
        build_html(md_path, html_path)
        ok, rc, out, pdf_abs = html_to_pdf(edge, html_path, pdf_path, user_data_dir)
        size = os.path.getsize(pdf_abs) if os.path.isfile(pdf_abs) else 0
        if ok:
            print("[ok  ] %-44s -> %8d B  %s" % (os.path.basename(md_path), size, os.path.basename(pdf_abs)))
        else:
            fail += 1
            print("[FAIL] %-44s rc=%s %s" % (os.path.basename(md_path), rc, out[-400:]))
        if args.clean_html:
            try:
                os.remove(html_path)
            except OSError:
                pass
    print("-" * 72)
    print("导出 %d 个，失败 %d 个" % (len(files), fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
