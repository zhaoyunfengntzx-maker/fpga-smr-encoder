# -*- coding: utf-8 -*-
"""Build the submission archive deliverables/submission/source_code.zip.

The package intentionally excludes build trees (_impl_*, _synth_work_*) and the bulk
capture/bitstream archives (.csv captures, 73 MB of historical .bit files).  It does
include everything the graded deliverables point at: all RTL (rtl/ including eth/ and
ddr3/), the fixed-point golden models (model/), per-testbench simulation logs, every
Vivado synthesis/implementation report (.rpt/.log), and the v90 production + display
bitstreams.  Without those the README's numbers cannot be checked and several
testbenches cannot even compile.

The archive is streamed straight from the git-tracked working tree: no staging copy is
made (a half-copied tree can never end up inside the zip), and scratch files that git
does not know about are never shipped.  Each file is read once, hashed, and written.
Run tools/verify_source_package.py afterwards to check the result.
"""
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
ARCROOT = "FPGA_encoder_source"
OUT = ROOT / "deliverables" / "submission" / "source_code.zip"

INCLUDE_FILES = [
    "README.md", "LICENSE", "NOTICE", ".gitattributes",
    "CHANGELOG.md", "CITATION.cff", "CONTRIBUTING.md", "SECURITY.md",
    "CODE_OF_CONDUCT.md",
    "deliverables/design_report.pdf",
    "deliverables/design_report.docx",
    "deliverables/design_report_full.pdf",
    "deliverables/technical_doc.pdf",
    "deliverables/project_intro.pdf",
]
INCLUDE_GLOBS = [
    "rtl/**/*.v", "rtl/*.md",
    "model/*.py", "model/*.txt",
    "disp/*.v", "sim/*.v", "sim/*.py", "sim/*.do", "sim/*.tcl", "sim/*.md",
    "sim/logs/*.md", "sim/logs/*.txt", "sim/logs/*.csv", "sim/logs/*.log",
    "disp/logs/*.md", "disp/logs/*.log",
    "_boardtest/*.py",
    "constr/*.xdc",
    "tools/*.py", "tools/*.ps1", "tools/*.tcl", "tools/*.bat", "tools/*.md",
    "tools/*.vbs",
    "host/*.py", "host/*.spec", "host/*.bat", "host/*.json", "host/*.md", "host/*.txt",
    "host/preview_s5.png",
    "host/assets/*",
    "deliverables/video/*.md", "deliverables/video/subs/*.srt",
    "deliverables/video/tools/*.py",
    "skill/*.md", "skill/README*",
    "skill/scripts/*.py", "skill/prompts/*.md", "skill/templates/*",
    "skill/examples/*/*", "skill/examples/*/*/*",
    "skill/pynq/*.py", "skill/pynq/*.md", "skill/pynq/prompts/*.md",
    "skill/pynq/templates/*",
    "skill/pynq/examples/*/*",
    "skill/pynq/examples/*.md",
    "docs/*.md",
    "deliverables/*.md",
    "deliverables/figures/*.png",
    "deliverables/figures/*.jpg",
    "deliverables/submission/photos/*.jpg", "deliverables/submission/photos/*.md",
    "deliverables/poster/*.pptx", "deliverables/poster/*.pdf", "deliverables/poster/*.png",
    "deliverables/poster/*.py", "deliverables/poster/*.json",
    "deliverables/data/README.md", "deliverables/data/*/README.md",
    "deliverables/data/SHA256SUMS.txt",
    "deliverables/data/**/*.rpt", "deliverables/data/**/*.log",
    "deliverables/data/**/*.txt", "deliverables/data/v90/*.bit",
    "deliverables/submission/*.md", "deliverables/submission/*.bat",
]
# files that must never ship: personal data, local caches, build trees
EXCLUDE_PARTS = ("__pycache__", ".git", "_impl_", "_synth_work", "_pkg")
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def _tracked() -> set[str]:
    """Paths known to git, so scratch files on disk never leak into the archive."""
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"],
                             capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return set()
    return {p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p}


TRACKED = _tracked()


def collect() -> list[Path]:
    picked: list[Path] = []
    seen: set[Path] = set()

    def take(p: Path) -> None:
        if not p.is_file() or p in seen:
            return
        rel = p.relative_to(ROOT)
        if TRACKED and rel.as_posix() not in TRACKED:
            return
        if rel.name == OUT.name and "submission" in rel.parts:
            return
        if any(part in EXCLUDE_PARTS or part.startswith(("_impl_", "_synth_work"))
               for part in rel.parts):
            return
        seen.add(p)
        picked.append(p)

    for name in INCLUDE_FILES:
        take(ROOT / name)
    for pattern in INCLUDE_GLOBS:
        for p in sorted(ROOT.glob(pattern)):
            take(p)
    return picked


def main() -> int:
    picked = collect()
    rels = {p: p.relative_to(ROOT).as_posix() for p in picked}
    dirs = sorted({(PurePosixPath(ARCROOT) / PurePosixPath(r)).parent.as_posix()
                   for r in rels.values()})
    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    lines: list[str] = []
    total = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        # explicit directory entries: several README/evidence tables link to whole
        # directories (data/v90/, figures/, sim/logs/); those links only resolve if the
        # directory itself is present in the archive
        for d in dirs:
            info = zipfile.ZipInfo(d + "/", date_time=FIXED_TIME)
            info.external_attr = (0o40755 << 16) | 0x10
            info.compress_type = zipfile.ZIP_STORED
            zf.writestr(info, b"")
        for p in picked:
            try:
                data = p.read_bytes()
            except OSError as exc:              # vanished between glob and read
                print(json.dumps({"skipped": rels[p], "why": str(exc)}))
                continue
            total += len(data)
            lines.append(f"{hashlib.sha256(data).hexdigest()}  {rels[p]}")
            info = zipfile.ZipInfo(f"{ARCROOT}/{rels[p]}", date_time=FIXED_TIME)
            info.external_attr = (0o100644 << 16) & 0xFFFFFFFF
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        info = zipfile.ZipInfo(f"{ARCROOT}/MANIFEST.sha256", date_time=FIXED_TIME)
        info.external_attr = (0o100644 << 16) & 0xFFFFFFFF
        info.compress_type = zipfile.ZIP_DEFLATED
        zf.writestr(info, ("\r\n".join(lines) + "\r\n").encode("utf-8"),
                    compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    print(json.dumps({
        "files": len(lines), "dirs": len(dirs),
        "bytes": total, "mb": round(total / 1048576, 2),
        "zip": str(OUT), "zip_mb": round(OUT.stat().st_size / 1048576, 2),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
