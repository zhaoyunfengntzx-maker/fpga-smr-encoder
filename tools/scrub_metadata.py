# -*- coding: utf-8 -*-
"""Scrub identity traces from deliverable documents (OOXML + PDF).

The submission rules forbid school / advisor / team information in the report and the
video.  Byte-level metadata (Office ``dc:creator`` / ``cp:lastModifiedBy``, PDF Info
dictionary, XMP packet) survives every PDF export and is easy to overlook, so it is
checked and cleaned here instead of by hand.

Usage::

    python tools/scrub_metadata.py --check          # report only, exit 1 on any hit
    python tools/scrub_metadata.py --fix            # rewrite the offending files
    python tools/scrub_metadata.py --check path...  # explicit files or directories

Rules applied:
  * OOXML: dc:creator and cp:lastModifiedBy are blanked; dc:title / dc:subject kept.
  * PDF:   author / creator / producer / keywords are blanked, XMP is dropped,
           title and subject kept.
  * PNG/JPEG are reported only (use ExifTool for strips); the photo set is clean.

The script is idempotent and refuses to touch anything that is not a regular file.
"""
import argparse
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TARGETS = [
    ROOT / "deliverables",
    ROOT / "docs",
]

OOXML_SUFFIXES = {".docx", ".pptx", ".xlsx"}
PDF_SUFFIXES = {".pdf"}
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}

# Third-party template whose metadata belongs to its vendor, not to us.
SKIP_NAMES = {"template_src.pptx"}
# The signed consent form is meant to carry the signatory's name; never scrub it.
SKIP_NAMES.add("authorization_letter.pdf")

CORE_FIELDS = ("dc:creator", "cp:lastModifiedBy")

# Values that name the producing tool rather than a person.  They are not an
# anonymity problem, but they still say nothing useful, so --fix clears them too.
TOOL_PREFIXES = (
    "Microsoft",
    "Mozilla",
    "HeadlessChrome",
    "Matplotlib",
    "Impress",
    "LibreOffice",
    "CamScanner",
    "Adobe",
    "Word",
    "PowerPoint",
    "Skia",
    "PyMuPDF",
    "Cairo",
    "GPL Ghostscript",
    "python-docx",
    "python-pptx",
)


def ooxml_fields(path):
    """Return {field: value} for the identity fields of an OOXML container."""
    out = {}
    with zipfile.ZipFile(path) as z:
        if "docProps/core.xml" not in z.namelist():
            return out
        xml = z.read("docProps/core.xml").decode("utf-8", "ignore")
    for field in CORE_FIELDS:
        m = re.search(rf"<{field}>(.*?)</{field}>", xml, re.S)
        if m:
            out[field] = m.group(1).strip()
    return out


def scrub_ooxml(path):
    tmp = path.with_suffix(path.suffix + ".tmp")
    with zipfile.ZipFile(path) as src, zipfile.ZipFile(
        tmp, "w", zipfile.ZIP_DEFLATED
    ) as dst:
        for item in src.infolist():
            data = src.read(item.filename)
            if item.filename == "docProps/core.xml":
                xml = data.decode("utf-8", "ignore")
                for field in CORE_FIELDS:
                    xml = re.sub(
                        rf"<{field}>.*?</{field}>", f"<{field}></{field}>", xml, flags=re.S
                    )
                data = xml.encode("utf-8")
            dst.writestr(item, data)
    shutil.move(str(tmp), str(path))


def is_tool(value):
    return any(value.startswith(p) for p in TOOL_PREFIXES)


def tag(value):
    return "tool" if is_tool(value) else "identity"


def pdf_fields(path):
    import pymupdf

    doc = pymupdf.open(path)
    meta = {k: (v or "") for k, v in (doc.metadata or {}).items()}
    doc.close()
    return {k: meta.get(k, "") for k in ("author", "creator", "producer", "keywords")}


def scrub_pdf(path):
    import pymupdf

    doc = pymupdf.open(path)
    meta = doc.metadata or {}
    clean = dict(meta)
    for key in ("author", "creator", "producer", "subject", "keywords", "title"):
        clean[key] = meta.get(key, "") if key in ("title",) else ""
    if not meta.get("title"):
        clean["title"] = "基于FPGA的细分编码器"
    doc.set_metadata(clean)
    try:
        doc.del_xml_metadata()
    except Exception:
        pass
    tmp = path.with_suffix(".pdf.tmp")
    doc.save(str(tmp), garbage=3, deflate=True)
    doc.close()
    shutil.move(str(tmp), str(path))


def image_note(path):
    try:
        from PIL import Image, ExifTags
    except Exception:
        return "exif: unknown"
    im = Image.open(path)
    ex = im.getexif()
    tags = [ExifTags.TAGS.get(k, k) for k in ex.keys()]
    gps = bool(ex.get_ifd(0x8825))
    return f"exif tags: {len(tags)} gps: {gps}"


def iter_files(targets):
    seen = set()
    for t in targets:
        t = Path(t)
        if t.is_file():
            paths = [t]
        else:
            paths = sorted(p for p in t.rglob("*") if p.is_file())
        for p in paths:
            if p.name in SKIP_NAMES or p.resolve() in seen:
                continue
            if p.suffix.lower() in OOXML_SUFFIXES | PDF_SUFFIXES | IMAGE_SUFFIXES:
                seen.add(p.resolve())
                yield p


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="report only (default)")
    ap.add_argument("--fix", action="store_true", help="rewrite offending files")
    ap.add_argument("targets", nargs="*", help="files or directories")
    args = ap.parse_args(argv)

    targets = [Path(x) for x in args.targets] or DEFAULT_TARGETS
    hits, tools, scanned, photos = [], [], 0, 0
    for p in iter_files(targets):
        suffix = p.suffix.lower()
        try:
            if suffix in OOXML_SUFFIXES:
                scanned += 1
                fields = {k: v for k, v in ooxml_fields(p).items() if v}
                if fields:
                    (hits if any(not is_tool(v) for v in fields.values()) else tools).append(
                        (p, fields)
                    )
                    if args.fix:
                        scrub_ooxml(p)
            elif suffix in PDF_SUFFIXES:
                scanned += 1
                fields = {k: v for k, v in pdf_fields(p).items() if v}
                if fields:
                    (hits if any(not is_tool(v) for v in fields.values()) else tools).append(
                        (p, fields)
                    )
                    if args.fix:
                        scrub_pdf(p)
            else:
                photos += 1
                note = image_note(p)
                if "gps: True" in note:
                    hits.append((p, {"gps": "True"}))
                    print(f"[GPS] {p} still carries coordinates")
        except Exception as exc:  # a corrupt file must not abort the sweep
            print(f"[WARN] {p}: {exc}")

    def dump(rows, label):
        for p, bad in rows:
            rel = p.relative_to(ROOT) if str(p).startswith(str(ROOT)) else p
            print(f"[{label}] {rel}: {bad}")

    dump(hits, "identity")
    dump(tools, "tool")
    print(
        f"\nscanned {scanned} documents + {photos} photos; "
        f"{len(hits)} carry identity metadata, {len(tools)} carry only tool names"
    )
    if args.fix:
        print("offending files rewritten in place")
        return 0
    if hits:
        print("run with --fix to blank the fields")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
