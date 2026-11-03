# -*- coding: utf-8 -*-
"""Check deliverables/submission/source_code.zip before upload.

Verifies what a judge or the submission site will see: archive integrity, no
non-ASCII entries, no build junk, no empty files, a complete MANIFEST.sha256, and
that every relative Markdown link resolves to something inside the archive.

Usage:  python tools/verify_source_package.py [--zip PATH] [--verbose]
Exit code is 0 only when nothing but the documented exclusions is missing.
"""
import argparse
import hashlib
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ZIP = ROOT / "deliverables" / "submission" / "source_code.zip"
MANIFEST = "FPGA_encoder_source/MANIFEST.sha256"
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)")
# historical bitstreams / captures that are deliberately not shipped (see
# deliverables/evidence_index.md, "源码包口径")
EXCLUDED_SUFFIXES = (".bit", ".csv")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default=str(DEFAULT_ZIP))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    zpath = Path(args.zip)
    zf = zipfile.ZipFile(zpath)
    infos = zf.infolist()
    names = [i.filename for i in infos]
    files = {n for n in names if not n.endswith("/")}
    dirs = {n.rstrip("/") for n in names if n.endswith("/")}
    total = sum(i.file_size for i in infos)
    fails = []

    def say(ok: bool, label: str, extra: str = "") -> None:
        print(("PASS " if ok else "FAIL ") + label + (": " + extra if extra else ""))
        if not ok:
            fails.append(label)

    say(zf.testzip() is None, "archive integrity (testzip)")
    say(len(names) == len(set(names)), "no duplicate entries", f"{len(names)} entries")
    nonascii = [n for n in names if not n.isascii()]
    say(not nonascii, "all entry names ASCII", f"{len(nonascii)} offenders")
    junk = [n for n in files
            if "__pycache__" in n or n.endswith(".pyc")
            or "/_impl_" in n or "/_synth_work" in n or n.endswith(".tmp")]
    say(not junk, "no build junk / caches", f"{len(junk)} offenders")
    empty = [n for n in files if zf.getinfo(n).file_size == 0]
    say(not empty, "no empty files", f"{len(empty)} offenders")
    roots = {n.split("/")[0] for n in names}
    say(len(roots) == 1, "single top-level directory", ", ".join(sorted(roots)))

    # manifest ---------------------------------------------------------------
    entries = {}
    for line in zf.read(MANIFEST).decode("utf-8").splitlines():
        line = line.strip()
        if line:
            h, _, p = line.partition("  ")
            entries[p.strip()] = h.lower()
    bad = absent = 0
    for p, h in entries.items():
        arc = "FPGA_encoder_source/" + p.replace("\\", "/")
        if arc not in files:
            absent += 1
            continue
        d = hashlib.sha256()
        with zf.open(arc) as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                d.update(chunk)
        if d.hexdigest() != h:
            bad += 1
    listed = {"FPGA_encoder_source/" + p.replace("\\", "/") for p in entries}
    unlisted = files - listed - {MANIFEST}
    say(not (bad or absent or unlisted), "MANIFEST.sha256 covers every file",
        f"{len(entries)} lines, {bad} bad, {absent} absent, {len(unlisted)} unlisted")

    # links ------------------------------------------------------------------
    missing = []
    checked = 0
    for n in [f for f in files if f.endswith(".md")]:
        base = PurePosixPath(n).parent
        try:
            text = zf.read(n).decode("utf-8", "replace")
        except KeyError:
            continue
        for m in LINK.finditer(text):
            tgt = m.group(1).strip()
            if tgt.startswith(("http://", "https://", "mailto:", "#", "data:")):
                continue
            tgt = tgt.split("#")[0].split("?")[0]
            if not tgt:
                continue
            checked += 1
            parts = list(base.parts)
            for seg in tgt.lstrip("/").split("/"):
                if seg in ("", "."):
                    continue
                if seg == "..":
                    if parts:
                        parts.pop()
                    continue
                parts.append(seg)
            resolved = "/".join(parts)
            if resolved in files or resolved in dirs:
                continue
            missing.append((n, tgt, resolved))
    unexpected = [m for m in missing if not m[2].endswith(EXCLUDED_SUFFIXES)]
    say(not unexpected, "relative Markdown links resolve",
        f"{checked} links, {len(missing)} unresolved "
        f"({len(missing) - len(unexpected)} documented exclusions)")
    if missing and (args.verbose or unexpected):
        for src, tgt, res in missing:
            tag = "MISS" if (src, tgt, res) in unexpected else "skip"
            print(f"  {tag} {src} -> {tgt}")
    print(f"\nfiles={len(files)} dirs={len(dirs)} "
          f"uncompressed={total / 1048576:.2f}MB zip={zpath.stat().st_size / 1048576:.2f}MB")
    if fails:
        print("FAILED: " + ", ".join(fails))
        return 1
    print("PASS: package is upload-ready "
          "(the only unresolved links point at the documented exclusions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
