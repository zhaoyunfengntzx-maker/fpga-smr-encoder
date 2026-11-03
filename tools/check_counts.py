#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_counts.py —— 文档里写的"数字"必须与仓库里的"事实"一致

【为什么要这个脚本】
  这个项目里最容易坏的不是代码，是**文档里的数字**：
  提交包的 zip 从 653 → 669 → 670 → 683 个条目改了几轮，PDF 从 23 页变 21 页，
  "18 项可执行资产"曾经被手滑写成"24 项"。每改一次，就有五六份 md 里的数字要跟着改，
  人工同步必然漏（`skill/pitfalls.md` P-17 就是这个坑）。
  2026-11-03 真实翻车一次：`deliverables/README.md` 改成了 21 页 / 1.19 MB，
  `submission/submission_checklist.md` 里还留着 "MANIFEST.sha256 575 行"。
  所以：把"文档声称的数字"与"现场重新数一遍的结果"逐条比对。

【提交事实文件（2026-11-03 新增）】
  提交包 zip 被 .gitignore 忽略，全新克隆里没有它——于是这个门禁只能 SKIP，
  而"SKIP"很容易被当成"通过"（P-16 的同一类错误）。
  现在把现场事实固化进 `docs/SUBMISSION_FACTS.json`（随仓库提交）：
    · 有 zip 时：先核"事实文件 vs 现场"（对不上就 FAIL，提示 --write-facts），再核"文档 vs 事实文件"；
    · 没有 zip 时：核"文档 vs 事实文件"，并明说"zip 事实来自提交时的快照"。
  事实文件由 `--write-facts` 从现场生成，不手抄。

【它比什么（只在"带着关键词的那一行"里取数，避免把海报 MB 当成 zip MB）】
  COUNT-ZIP       含 zip 的行里的 "NNN 文件"     == zip 内文件条目数
  COUNT-ZIPSIZE   含 zip 的行里的 "N.NN MB"      == zip 字节数 / 1e6
  COUNT-MANIFEST  "MANIFEST…NNN 行"              == MANIFEST.sha256 行数
  COUNT-PDFPAGE   含 design_report.pdf 的行里的 "NN 页" == PDF 页数
  COUNT-PDFSIZE   同上行里的 "N.NN MB" / "N,NNN,NNN B"  == PDF 字节数
  COUNT-ASSETS    "N 篇长文"、"N 项可执行资产"  == skill/ 实际文件数
  COUNT-SELFTEST  字面量 "24/24"、"18/18"        == --with-tests 时现场跑的结果
  COUNT-FACTS     事实文件                          == 现场（只在有 zip 时判）
  判据是"**每份**文档说的都对"：一份改对、另一份留着旧数字也算 FAIL。

【用法】
  python tools/check_counts.py                 # 比对三份读者会看的 md
  python tools/check_counts.py --write-facts   # 从现场重写 docs/SUBMISSION_FACTS.json（先跑 make_source_package.py）
  python tools/check_counts.py --with-tests    # 顺带真跑两套自检（约 10 秒）
  python tools/check_counts.py --verbose       # 先打印现场事实

【退出码】0 = 全部一致；1 = 有数字与事实不符；2 = 缺文件/读不出来

【失效条件】
  1) 它核"文档说法 vs 事实"，不核"这个数字本身是否合理"；
  2) 句式改了（比如把"670 文件"写成"约七百个文件"）就抓不到，需要同步改正则；
  3) 事实文件是"提交那一刻"的快照：改了内容却忘了重跑 --write-facts，只能靠"有 zip 时"那条判据兜住——
     所以 CI 只在有 zip 的机器上能全绿，其余机器上 zip 三项来自快照；
  4) --with-tests 要求本机有 Python，且两套自检必须能在 10 秒内跑完。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUB = ROOT / "deliverables" / "submission"
ZIP = SUB / "source_code.zip"
PDF = ROOT / "deliverables" / "design_report.pdf"
MANIFEST = ROOT / "_pkg" / "FPGA_encoder_source" / "MANIFEST.sha256"
FACTS = ROOT / "docs" / "SUBMISSION_FACTS.json"
DOCS = [SUB / "README.md", SUB / "submission_checklist.md", ROOT / "deliverables" / "README.md"]


def _utf8_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def pdf_pages(path: Path) -> int | None:
    try:
        from pypdf import PdfReader  # type: ignore
        return len(PdfReader(str(path)).pages)
    except Exception:
        pass
    try:
        return len(re.findall(rb"/Type\s*/Page[^s]", path.read_bytes()))
    except Exception:
        return None


def count_skill_assets() -> dict[str, int]:
    sk = ROOT / "skill"
    tdir = sk / "templates"
    scripts = len(list((sk / "scripts").glob("*.py")))
    templates = len([p for p in tdir.iterdir() if p.is_file()]) if tdir.is_dir() else 0
    prompts = len(list((sk / "prompts").glob("*.md"))) if (sk / "prompts").is_dir() else 0
    # 方法长文 = skill/ 顶层 md 去掉 README 与两份清单（后者是清单，不是长文）
    longform = len([p for p in sk.glob("*.md")
                    if p.name not in ("README.md", "pitfalls.md", "pitfalls_index.md", "CHEATSHEET.md")])
    pitfalls = len(re.findall(r"^### P-\d+", (sk / "pitfalls.md").read_text(encoding="utf-8"), re.M)) \
        if (sk / "pitfalls.md").is_file() else 0
    # "N 项可执行资产" = 脚本 + 模板 + 提示词 + 1 份踩坑清单（清单里有 18 条，但只算 1 项资产）
    return {"scripts": scripts, "templates": templates, "prompts": prompts,
            "longform": longform, "pitfalls": pitfalls,
            "total": scripts + templates + prompts + (1 if pitfalls else 0)}


def measure() -> dict:
    """现场重新数一遍。zip / MANIFEST 不存在时对应字段为 None。"""
    facts: dict = {"zip": None, "manifest_lines": None, "pdf": None, "assets": count_skill_assets()}
    if ZIP.is_file():
        with zipfile.ZipFile(ZIP) as zf:
            entries = len([n for n in zf.namelist() if not n.endswith("/")])
        size = ZIP.stat().st_size
        facts["zip"] = {"entries": entries, "bytes": size, "mb": round(size / 1e6, 2)}
    if MANIFEST.is_file():
        facts["manifest_lines"] = len(MANIFEST.read_text(encoding="utf-8").splitlines())
    if PDF.is_file():
        pages = pdf_pages(PDF)
        size = PDF.stat().st_size
        facts["pdf"] = {"pages": pages, "bytes": size, "mb": round(size / 1e6, 2)}
    return facts


def load_facts() -> dict | None:
    if not FACTS.is_file():
        return None
    try:
        return json.loads(FACTS.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_facts(facts: dict) -> None:
    FACTS.parent.mkdir(parents=True, exist_ok=True)
    FACTS.write_text(json.dumps(facts, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def line_claims(docs: list[Path], must: str, pattern: str) -> dict[str, set[str]]:
    """只在包含 must 的行里用 pattern 取数（pattern 第 1 组是数字）。"""
    out: dict[str, set[str]] = {}
    for d in docs:
        got: set[str] = set()
        for line in d.read_text(encoding="utf-8", errors="replace").splitlines():
            if must not in line:
                continue
            got.update(m.group(1) for m in re.finditer(pattern, line))
        if got:
            out[d.name] = got
    return out


def file_claims(docs: list[Path], fname: str) -> dict[str, dict[str, set[str]]]:
    """按"文件名分段"取数：一行里可能同时出现 design_report.pdf（21 页）与
    technical_doc.pdf（15 页），靠"最近的前一个文件名"把数字归到正确的对象上。
    返回 {文档名: {"页": {...}, "MB": {...}, "文件": {...}, "B": {...}}}"""
    name_re = re.compile(r"[\w./\\-]+\.(?:pdf|zip|docx|rar|bit|xsa)\b")
    unit_res = (("页", r"(\d+)\s*页"), ("MB", r"([\d.]+)\s*MB"), ("文件", r"(\d+)\s*文件"), ("B", r"([\d,]+)\s*B\b"))
    out: dict[str, dict[str, set[str]]] = {}
    for d in docs:
        per: dict[str, set[str]] = {u: set() for u, _ in unit_res}
        for line in d.read_text(encoding="utf-8", errors="replace").splitlines():
            hits = list(name_re.finditer(line))
            for i, m in enumerate(hits):
                if Path(m.group(0).replace("\\", "/")).name != fname:
                    continue
                seg = line[m.end(): hits[i + 1].start() if i + 1 < len(hits) else len(line)]
                for unit, pat in unit_res:
                    per[unit].update(x.group(1) for x in re.finditer(pat, seg))
        if any(per.values()):
            out[d.name] = per
    return out


def merge_units(claims: dict[str, dict[str, set[str]]], unit: str) -> dict[str, set[str]]:
    return {doc: c[unit] for doc, c in claims.items() if c.get(unit)}


def run_selftest() -> tuple[bool, str]:
    lines, ok_all = [], True
    for script, want in ((ROOT / "skill" / "scripts" / "skill_selftest.py", "24/24"),
                         (ROOT / "skill" / "pynq" / "pynq_selftest.py", "18/18")):
        r = subprocess.run([sys.executable, str(script)], capture_output=True)
        text = (r.stdout + r.stderr).decode("utf-8", "replace")
        ok = r.returncode == 0 and want in text
        ok_all = ok_all and ok
        lines.append(f"  {script.name}: rc={r.returncode}，期望输出含 {want} -> {'ok' if ok else 'FAIL'}")
    return ok_all, "\n".join(lines)


def claims_for(docs: list[Path], fname: str, keyword: str, pattern: str) -> dict[str, set[str]]:
    """优先按"文件名分段"取数（一行里有两个 pdf 时才不会串），
    文档里没写全名时退回"含关键字那一行"的粗取法。

    两种取法都要剔除"上限值"：文档里写"（≤200 MB 限制）"时，
    那个 200 是官网限制，不是本包大小——早期版本就把它当成 zip 体积比过一次。
    """
    per = merge_units(file_claims(docs, fname), _unit_of(pattern))
    if not per:
        per = line_claims(docs, keyword, pattern)
    limit = re.compile(r"[≤<]\s*([\d.]+)\s*(?:MB|B|文件|页)")
    for d in docs:
        caps = set(limit.findall(d.read_text(encoding="utf-8", errors="replace")))
        if caps and d.name in per:
            per[d.name] = {v for v in per[d.name] if v not in caps}
        if d.name in per and not per[d.name]:
            del per[d.name]
    return per


def _unit_of(pattern: str) -> str:
    for unit in ("页", "MB", "文件", "B"):
        if unit in pattern:
            return unit
    return "文件"


def skilldoc_check() -> tuple[bool, str]:
    """skill/README.md 是陌生人最先读的一份：它里面的用例数与资产数必须与现场一致。

    2026-11-03 发现它把"18 个用例"写成了 13、把资产数写成 18，而门禁只核三份提交文档，
    这两处就这么躺着漂了两周。所以这里补一条：**旧数字不许出现，新数字必须出现**。
    """
    doc = ROOT / "skill" / "README.md"
    if not doc.is_file():
        return False, "缺 skill/README.md"
    text = doc.read_text(encoding="utf-8", errors="replace")
    assets = count_skill_assets()
    bad: list[str] = []
    stale = {"13/13": "18/18", "14/14": "24/24"}
    for old, new in stale.items():
        if old in text:
            bad.append(f"还写着 {old}（应为 {new}）")
    for need in ("24/24", "18/18"):
        if need not in text:
            bad.append(f"没写 {need}")
    for pattern, want, label in (
        (r"(\d+)\s*项可执行资产", str(assets["total"]), "项可执行资产"),
        (r"(\d+)\s*个用例", None, None),
    ):
        if want is None:
            continue
        for got in set(re.findall(pattern, text)):
            if got != want:
                bad.append(f"{label}写成 {got}（应为 {want}）")
    return (not bad), "；".join(bad) if bad else ""


def _facts_stale(disk: dict, saved: dict) -> list[str]:
    """事实文件与现场（有 zip 的时候）逐字段比，返回不一致的字段描述。"""
    bad: list[str] = []
    if disk["zip"] and saved.get("zip"):
        for key in ("entries", "mb"):
            if saved["zip"].get(key) != disk["zip"].get(key):
                bad.append(f"zip.{key}: 事实 {saved['zip'].get(key)} ≠ 现场 {disk['zip'].get(key)}")
    if disk["manifest_lines"] is not None and saved.get("manifest_lines") is not None:
        if saved["manifest_lines"] != disk["manifest_lines"]:
            bad.append(f"manifest_lines: 事实 {saved['manifest_lines']} ≠ 现场 {disk['manifest_lines']}")
    if disk["pdf"] and saved.get("pdf"):
        for key in ("pages", "bytes"):
            if saved["pdf"].get(key) != disk["pdf"].get(key):
                bad.append(f"pdf.{key}: 事实 {saved['pdf'].get(key)} ≠ 现场 {disk['pdf'].get(key)}")
    if saved.get("assets") and saved["assets"] != disk["assets"]:
        bad.append(f"assets: 事实 {saved['assets']} ≠ 现场 {disk['assets']}")
    return bad


def main(argv: list[str] | None = None) -> int:
    _utf8_console()
    ap = argparse.ArgumentParser(description="核对文档里的数字与仓库事实")
    ap.add_argument("--write-facts", action="store_true",
                    help="把现场事实写进 docs/SUBMISSION_FACTS.json（需先 make_source_package.py）")
    ap.add_argument("--with-tests", action="store_true", help="真跑两套 selftest 核 24/24 与 18/18")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    disk = measure()
    if args.write_facts:
        if not disk["zip"]:
            print(f"[EXIT2] 没有 {ZIP}，先跑 tools/make_source_package.py 再写事实文件", file=sys.stderr)
            return 2
        write_facts(disk)
        print(f"已写 {FACTS.relative_to(ROOT)}：zip {disk['zip']['entries']} 条目 / {disk['zip']['mb']:.2f} MB；"
              f"MANIFEST {disk['manifest_lines']} 行；PDF {disk['pdf']['pages']} 页 / {disk['pdf']['bytes']:,} B；"
              f"资产 {disk['assets']['total']} 项")
        return 0

    saved = load_facts()
    if not disk["zip"] and not saved:
        print(f"[EXIT2] 既没有 {ZIP} 也没有 {FACTS.relative_to(ROOT)}："
              f"先跑 tools/make_source_package.py，或从仓库里恢复事实文件", file=sys.stderr)
        return 2
    if not PDF.is_file():
        print(f"[EXIT2] 没有 {PDF}", file=sys.stderr)
        return 2

    docs = [d for d in DOCS if d.is_file()]
    if not docs:
        print("[EXIT2] 找不到要核对的 md", file=sys.stderr)
        return 2

    # 有效事实：能现场数的用现场的，数不了的（没有 zip）退回提交时的快照
    effective = {
        "zip": disk["zip"] or (saved or {}).get("zip"),
        "manifest_lines": disk["manifest_lines"] if disk["manifest_lines"] is not None
        else (saved or {}).get("manifest_lines"),
        "pdf": disk["pdf"],
        "assets": disk["assets"],
    }
    source = "现场" if disk["zip"] else "提交时快照（zip 不进 git）"
    if args.verbose:
        print(f"  事实来源：zip/MANIFEST = {source}")
        print(f"  现场事实：zip {effective['zip']['entries']} 条目 / {effective['zip']['mb']:.2f} MB；"
              f"PDF {effective['pdf']['bytes']:,} B / {effective['pdf']['mb']:.2f} MB / {effective['pdf']['pages']} 页；"
              f"MANIFEST {effective['manifest_lines']} 行；skill/ {effective['assets']}")

    checks: list[tuple[str, str, str, bool, str]] = []

    if saved and disk["zip"]:
        stale = _facts_stale(disk, saved)
        checks.append(("COUNT-FACTS", "事实文件", "现场",
                       not stale,
                       "；".join(stale) + "（重跑 --write-facts）" if stale else ""))

    def check(code: str, claims: dict[str, set[str]], expected: set[str], note: str = "") -> None:
        if not claims:
            checks.append((code, "（文档没写）", "、".join(sorted(expected)), False, "至少在一份文档里写清楚"))
            return
        shown = "; ".join(f"{k}={sorted(v)}" for k, v in claims.items())
        ok = all(v <= expected for v in claims.values())
        checks.append((code, shown, "、".join(sorted(expected)), ok, "" if ok else note))

    n_files = effective["zip"]["entries"]
    zip_mb = effective["zip"]["mb"]
    check("COUNT-ZIP", claims_for(docs, "source_code.zip", "zip", r"(\d+)\s*文件"), {str(n_files)},
          "zip 条目数 = _pkg 里的文件数 + MANIFEST.sha256 自己；两个口径都要写清")
    # 体积只核到 0.05 MB：zip 里装着这几份 md 自己，改一句文案 zip 就会变几百字节，
    # 而"把文档改到与 zip 完全一致"会陷入自指死循环。条目数/行数/页数仍是精确比对。
    tol = 0.05
    size_claims = claims_for(docs, "source_code.zip", "zip", r"([\d.]+)\s*MB")
    flat = {v for vs in size_claims.values() for v in vs}
    ok_size = bool(flat) and all(abs(float(v) - zip_mb) <= tol for v in flat)
    checks.append(("COUNT-ZIPSIZE", str(sorted(flat)), f"{zip_mb:.2f} ±{tol}",
                   ok_size, "" if ok_size else "误差超过 0.05 MB：重打包后同步"))
    if effective["manifest_lines"] is None:
        checks.append(("COUNT-MANIFEST", "—", "缺 MANIFEST.sha256", False, "先跑 make_source_package.py"))
    else:
        check("COUNT-MANIFEST", line_claims(docs, "MANIFEST", r"(\d+)\s*行"), {str(effective["manifest_lines"])})
    pages = effective["pdf"]["pages"]
    pdf_bytes = effective["pdf"]["bytes"]
    pdf_mb = effective["pdf"]["mb"]
    if pages is None:
        checks.append(("COUNT-PDFPAGE", "—", "读不出页数", False, "装 pypdf 或检查 PDF"))
    else:
        check("COUNT-PDFPAGE", claims_for(docs, "design_report.pdf", "design_report.pdf", r"(\d+)\s*页"), {str(pages)})
    check("COUNT-PDFSIZE", claims_for(docs, "design_report.pdf", "design_report.pdf", r"([\d.]+)\s*MB"),
          {f"{pdf_mb:.2f}"})
    check("COUNT-PDFBYTES", claims_for(docs, "design_report.pdf", "design_report.pdf", r"([\d,]+)\s*B"),
          {f"{pdf_bytes:,}", f"{pdf_bytes}"})
    check("COUNT-ASSETS-LONGFORM", line_claims(docs, "长文", r"(\d+)\s*篇长文"), {str(effective["assets"]["longform"])})
    check("COUNT-ASSETS-TOTAL", line_claims(docs, "项可执行资产", r"(\d+)\s*项可执行资产"), {str(effective["assets"]["total"])})

    if args.with_tests:
        ok, detail = run_selftest()
        print(detail)
        checks.append(("COUNT-SELFTEST", "24/24 与 18/18", "现场跑", ok, "" if ok else "有自检没跑过"))

    # 技能包自己的 README 也要核：它是最常被读的一份，却曾把 18 个用例写成 13 个写了两周
    ok_doc, detail_doc = skilldoc_check()
    checks.append(("COUNT-SKILLDOC", "skill/README.md", "现场", ok_doc, detail_doc))

    width = max(len(c[0]) for c in checks) + 2
    for code, want, actual, ok, note in checks:
        line = f"{code:<{width}} 文档 {want:<46} 事实 {actual:<22} {'ok  ' if ok else 'FAIL'}"
        print(line + (f"  {note}" if note else ""))
    bad = [c for c in checks if not c[3]]
    print(f"\n共 {len(checks)} 条判据，{len(checks) - len(bad)} 条一致"
          + ("" if disk["zip"] else "（zip 三项来自提交时快照）"))
    if bad:
        print("=> FAIL：文档里的数字与事实不符（改了东西就同步 md，别让读者替你数）")
        return 1
    print("=> PASS：文档里的数字与事实一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
