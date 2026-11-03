# -*- coding: utf-8 -*-
"""Collect the submission source package (code + docs + evidence index) into _pkg/.

The package intentionally excludes build trees (_impl_*, _synth_work_*), captures,
bitstreams and the 127 MB evidence archive; the evidence archive itself is part of
deliverables/data and is not "code".  Everything kept is small enough to re-run.
"""
import hashlib
import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STAGE = ROOT / "_pkg" / "FPGA_encoder_source"

INCLUDE_FILES = [
    "README.md", "LICENSE", "NOTICE", ".gitattributes",
    "deliverables/design_report.pdf",
    "deliverables/design_report.docx",
    "deliverables/technical_doc.pdf",
]
INCLUDE_GLOBS = [
    "rtl/*.v", "disp/*.v", "sim/*.v", "sim/*.py", "sim/*.do", "sim/*.tcl", "sim/*.md",
    "sim/logs/*.md", "sim/logs/*.txt", "sim/logs/*.csv", "_boardtest/*.py",
    "constr/*.xdc",
    "tools/*.py", "tools/*.ps1", "tools/*.tcl", "tools/*.bat", "tools/*.md",
    "tools/*.vbs",
    "host/*.py", "host/*.spec", "host/*.bat", "host/*.json", "host/*.md", "host/*.txt",
    "host/assets/*",
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
    "deliverables/submission/*.md", "deliverables/submission/*.bat",
]


def add(path: Path) -> None:
    rel = path.relative_to(ROOT)
    dst = STAGE / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dst)


def main() -> None:
    if STAGE.exists():
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)
    for name in INCLUDE_FILES:
        p = ROOT / name
        if p.exists():
            add(p)
    for pattern in INCLUDE_GLOBS:
        for p in sorted(ROOT.glob(pattern)):
            if p.is_file() and "__pycache__" not in p.parts:
                add(p)
    files = sorted(p for p in STAGE.rglob("*") if p.is_file())
    lines = []
    for p in files:
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        lines.append(f"{h}  {p.relative_to(STAGE).as_posix()}")
    (STAGE / "MANIFEST.sha256").write_bytes(
        ("\r\n".join(lines) + "\r\n").encode("utf-8"))
    total = sum(p.stat().st_size for p in files)
    zpath = ROOT / "deliverables" / "submission" / "source_code.zip"
    zpath.parent.mkdir(parents=True, exist_ok=True)
    if zpath.exists():
        zpath.unlink()
    import zipfile
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in files:
            zf.write(p, arcname=(Path("FPGA_encoder_source") / p.relative_to(STAGE)).as_posix())
        zf.write(STAGE / "MANIFEST.sha256", arcname="FPGA_encoder_source/MANIFEST.sha256")
    print(json.dumps({
        "stage": str(STAGE), "files": len(files),
        "bytes": total, "mb": round(total / 1048576, 2),
        "zip": str(zpath), "zip_mb": round(zpath.stat().st_size / 1048576, 2),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
