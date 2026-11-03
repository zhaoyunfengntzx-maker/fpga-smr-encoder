#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pdf_text.py -- dependency-free PDF text + vector-geometry extractor.

Pure Python standard library only (zlib, re, struct, sys, io, os).

WHY THIS EXISTS
---------------
The project needs pin/net facts out of vendor schematics (PDF) on a machine
where no PDF library can be installed.  This module is deliberately general:
it is a small but real PDF reader (xref tables, xref streams, object streams,
Flate/LZW/ASCII85/ASCIIHex/RunLength filters, PNG+TIFF predictors, CMap /
ToUnicode CID decoding) plus a content-stream text-state machine that also
recovers the vector geometry (so a caller can associate a net label with the
wire it sits on).

USAGE
-----
    python tools/pdf_text.py <file.pdf>
        -> prints a page list with per-page extracted-text length

    python tools/pdf_text.py <file.pdf> -1 out.txt
        -> extracts ALL pages to out.txt (UTF-8)

    python tools/pdf_text.py <file.pdf> 3 out.txt
        -> extracts page index 3 (0-BASED) to out.txt

    python tools/pdf_text.py <file.pdf> -1 out.txt --geom
        -> additionally writes <out>_geom.txt containing, per page,
             T<TAB>x<TAB>y<TAB>text     (each shown text run + its origin)
             L<TAB>x1<TAB>y1<TAB>x2<TAB>y2   (each stroked line segment)

  Options
    --geom        also write the geometry/position file
    --sort        sort text runs into reading order (-y, then x) instead of
                  emitting them in content-stream order
    --fonts       dump a summary of every font encountered, per page
    --quiet       do not print progress to stderr

All output files are written as UTF-8.  Console stdout is re-wrapped as UTF-8
with errors='replace' so a GBK console cannot mangle CJK output.

The extractor is defensive: a malformed object raises internally, is caught,
and processing continues with the next object/page.
"""

import io
import os
import re
import struct
import sys
import zlib

__all__ = ["PdfDocument", "extract_pages", "OCR_FREE", "main"]

# ---------------------------------------------------------------------------
# PDF object model
# ---------------------------------------------------------------------------

WHITESPACE = b"\x00\x09\x0a\x0c\x0d\x20"
DELIMS = b"()<>[]{}/%"
IDENT = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


class PdfError(Exception):
    pass


class PdfName(str):
    """A PDF name object (/Foo).  Subclasses str so it compares like text."""

    __slots__ = ()

    def __repr__(self):
        return "/" + str(self)


class PdfString(bytes):
    """A PDF string object.  Subclasses bytes, so it is NOT a PdfName."""

    __slots__ = ()

    def __repr__(self):
        return "(%r)" % (bytes(self),)


class PdfKeyword(str):
    """A bare keyword / operator token (obj, R, m, Tj, ...)."""

    __slots__ = ()


class PdfRef(object):
    __slots__ = ("num", "gen")

    def __init__(self, num, gen=0):
        self.num = int(num)
        self.gen = int(gen)

    def __repr__(self):
        return "%d %d R" % (self.num, self.gen)

    def __eq__(self, other):
        return isinstance(other, PdfRef) and other.num == self.num

    def __hash__(self):
        return hash(("ref", self.num))


class PdfStream(object):
    __slots__ = ("dict", "raw", "doc", "_data")

    def __init__(self, d, raw, doc=None):
        self.dict = d
        self.raw = raw
        self.doc = doc
        self._data = None

    def get_data(self):
        """Decoded stream bytes (filters + predictor applied)."""
        if self._data is None:
            try:
                self._data = decode_stream(self, self.doc)
            except Exception:
                self._data = b""
        return self._data


# ---------------------------------------------------------------------------
# Lexer / object parser
# ---------------------------------------------------------------------------

_NAME_RE = re.compile(rb"[^\x00\t\n\x0c\r ()<>\[\]{}/%]*")
_NUM_RE = re.compile(rb"[+-]?(?:\d+\.?\d*|\.\d+)")
_INT_RE = re.compile(rb"[+-]?\d+")
_TOKEN_RE = re.compile(rb"[^\x00\t\n\x0c\r ()<>\[\]{}/%]+")


class Lexer(object):
    __slots__ = ("data", "pos", "n")

    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos
        self.n = len(data)

    def skip_ws(self):
        d = self.data
        n = self.n
        p = self.pos
        while p < n:
            c = d[p]
            if c in WHITESPACE:
                p += 1
            elif c == 0x25:  # '%' comment
                while p < n and d[p] not in (0x0A, 0x0D):
                    p += 1
            else:
                break
        self.pos = p

    def at_eof(self):
        self.skip_ws()
        return self.pos >= self.n


def _decode_pdf_name(raw):
    """Decode a PDF name's raw bytes: #xx hex escapes -> byte."""
    out = bytearray()
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c == 0x23 and i + 2 < n:  # '#'
            try:
                out.append(int(raw[i + 1:i + 3], 16))
                i += 3
                continue
            except ValueError:
                pass
        out.append(c)
        i += 1
    try:
        return out.decode("latin-1")
    except Exception:
        return ""


def parse_literal_string(d, p):
    """Parse a (...) literal string starting at d[p]=='('.

    Returns (raw_bytes, next_pos).  Handles escapes and balanced parens.
    """
    n = len(d)
    assert d[p] == 0x28
    p += 1
    depth = 1
    out = bytearray()
    while p < n:
        c = d[p]
        if c == 0x5C:  # backslash
            p += 1
            if p >= n:
                break
            e = d[p]
            if e == 0x6E:
                out.append(0x0A)
                p += 1
            elif e == 0x72:
                out.append(0x0D)
                p += 1
            elif e == 0x74:
                out.append(0x09)
                p += 1
            elif e == 0x62:
                out.append(0x08)
                p += 1
            elif e == 0x66:
                out.append(0x0C)
                p += 1
            elif e in (0x28, 0x29, 0x5C):
                out.append(e)
                p += 1
            elif 0x30 <= e <= 0x37:  # octal, up to 3 digits
                j = p
                val = 0
                k = 0
                while j < n and k < 3 and 0x30 <= d[j] <= 0x37:
                    val = val * 8 + (d[j] - 0x30)
                    j += 1
                    k += 1
                out.append(val & 0xFF)
                p = j
            elif e == 0x0A:
                p += 1
            elif e == 0x0D:
                p += 1
                if p < n and d[p] == 0x0A:
                    p += 1
            else:
                out.append(e)
                p += 1
        elif c == 0x28:
            depth += 1
            out.append(c)
            p += 1
        elif c == 0x29:
            depth -= 1
            if depth == 0:
                p += 1
                break
            out.append(c)
            p += 1
        elif c == 0x0D:
            # CR / CRLF inside a literal string means LF
            out.append(0x0A)
            p += 1
            if p < n and d[p] == 0x0A:
                p += 1
        else:
            out.append(c)
            p += 1
    return bytes(out), p


def parse_hex_string(d, p):
    """Parse a <...> hex string starting at d[p]=='<'.  Returns (bytes,pos)."""
    n = len(d)
    j = d.find(b">", p + 1)
    if j < 0:
        j = n
    body = re.sub(rb"[^0-9A-Fa-f]", b"", d[p + 1:j])
    if len(body) % 2:
        body += b"0"
    try:
        val = bytes.fromhex(body.decode("ascii"))
    except Exception:
        val = b""
    return val, j + 1


def parse_object(lx):
    """Parse one PDF object at the lexer position.  Advances lx.pos."""
    lx.skip_ws()
    d = lx.data
    n = lx.n
    p = lx.pos
    if p >= n:
        raise PdfError("unexpected EOF")

    c = d[p]

    if c == 0x2F:  # '/' name
        m = _NAME_RE.match(d, p + 1)
        end = m.end() if m else p + 1
        lx.pos = end
        return PdfName(_decode_pdf_name(d[p + 1:end]))

    if c == 0x28:  # '(' string
        s, np_ = parse_literal_string(d, p)
        lx.pos = np_
        return PdfString(s)

    if c == 0x3C:  # '<'
        if d[p + 1:p + 2] == b"<":
            lx.pos = p + 2
            return parse_dict(lx)
        s, np_ = parse_hex_string(d, p)
        lx.pos = np_
        return PdfString(s)

    if c == 0x5B:  # '['
        lx.pos = p + 1
        arr = []
        while True:
            lx.skip_ws()
            if lx.pos >= n:
                break
            if d[lx.pos] == 0x5D:
                lx.pos += 1
                break
            before = lx.pos
            try:
                arr.append(parse_object(lx))
            except Exception:
                lx.pos = before + 1
            if lx.pos <= before:
                lx.pos = before + 1
        return arr

    # keywords
    if d[p:p + 4] == b"true":
        lx.pos = p + 4
        return True
    if d[p:p + 5] == b"false":
        lx.pos = p + 5
        return False
    if d[p:p + 4] == b"null":
        lx.pos = p + 4
        return None

    if c in b"+-.0123456789":
        m = _NUM_RE.match(d, p)
        if m:
            tok = m.group()
            after = m.end()
            # possible indirect reference:  "<int> <int> R"
            if b"." not in tok:
                save = lx.pos
                lx.pos = after
                lx.skip_ws()
                m2 = _INT_RE.match(d, lx.pos)
                if m2:
                    after2 = m2.end()
                    p3 = after2
                    while p3 < n and d[p3] in WHITESPACE:
                        p3 += 1
                    if d[p3:p3 + 1] == b"R":
                        p4 = p3 + 1
                        if p4 >= n or d[p4] in WHITESPACE or d[p4] in DELIMS:
                            lx.pos = p4
                            try:
                                return PdfRef(int(tok), int(m2.group()))
                            except Exception:
                                pass
                lx.pos = save
            lx.pos = after
            try:
                if b"." in tok:
                    return float(tok)
                return int(tok)
            except Exception:
                return 0

    # operator / bare keyword
    m = _TOKEN_RE.match(d, p)
    if m and m.end() > p:
        lx.pos = m.end()
        return PdfKeyword(m.group().decode("latin-1"))
    lx.pos = p + 1
    return PdfKeyword(chr(c))


def parse_dict(lx):
    """Parse a << ... >> dictionary (lexer positioned just after '<<')."""
    d = lx.data
    n = lx.n
    out = {}
    while True:
        lx.skip_ws()
        if lx.pos >= n:
            break
        if d[lx.pos:lx.pos + 2] == b">>":
            lx.pos += 2
            break
        before = lx.pos
        try:
            key = parse_object(lx)
        except Exception:
            lx.pos = before + 1
            continue
        try:
            val = parse_object(lx)
        except Exception:
            val = None
        if lx.pos <= before:
            lx.pos = before + 1
            continue
        if isinstance(key, PdfName):
            out[str(key)] = val
        elif isinstance(key, PdfKeyword):
            out[str(key)] = val
        # non-name keys are illegal; ignore
    return out


# ---------------------------------------------------------------------------
# Stream filters
# ---------------------------------------------------------------------------

def _as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return v
    return [v]


def flate_decode(data):
    """zlib / raw-deflate, tolerant of truncation and trailing junk."""
    if not data:
        return b""
    for wbits in (15, -15, 47):
        try:
            return zlib.decompress(data, wbits)
        except Exception:
            pass
    # tolerant partial decode
    out = []
    for wbits in (15, -15):
        try:
            obj = zlib.decompressobj(wbits)
            chunk = obj.decompress(data)
            try:
                chunk += obj.flush()
            except Exception:
                pass
            if chunk:
                out.append(chunk)
        except Exception:
            pass
    if out:
        return max(out, key=len)
    # skip leading junk byte (some producers emit a stray byte)
    if len(data) > 1:
        try:
            return zlib.decompress(data[1:])
        except Exception:
            pass
    return b""


def ascii_hex_decode(data):
    body = re.sub(rb"[^0-9A-Fa-f]", b"", data.split(b">")[0])
    if len(body) % 2:
        body += b"0"
    try:
        return bytes.fromhex(body.decode("ascii"))
    except Exception:
        return b""


def ascii85_decode(data):
    data = data.strip()
    if data.startswith(b"<~"):
        data = data[2:]
    idx = data.find(b"~>")
    if idx >= 0:
        data = data[:idx]
    out = bytearray()
    group = []
    for ch in data:
        if ch in WHITESPACE:
            continue
        if ch == 0x7A and not group:  # 'z'
            out.extend(b"\x00\x00\x00\x00")
            continue
        if ch < 0x21 or ch > 0x75:
            continue
        group.append(ch - 0x21)
        if len(group) == 5:
            val = 0
            for g in group:
                val = val * 85 + g
            out.extend(struct.pack(">I", val & 0xFFFFFFFF))
            group = []
    if group:
        k = len(group)
        group += [84] * (5 - k)
        val = 0
        for g in group:
            val = val * 85 + g
        out.extend(struct.pack(">I", val & 0xFFFFFFFF)[:k - 1])
    return bytes(out)


def runlength_decode(data):
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        l = data[i]
        i += 1
        if l == 128:
            break
        if l < 128:
            out.extend(data[i:i + l + 1])
            i += l + 1
        else:
            if i < n:
                out.extend(bytes([data[i]]) * (257 - l))
                i += 1
    return bytes(out)


def lzw_decode(data, early=1):
    """PDF LZWDecode (variable code width 9..12, EarlyChange)."""
    out = bytearray()
    table = [bytes([i]) for i in range(256)] + [b"", b""]
    bitpos = 0
    codelen = 9
    prev = None
    total_bits = len(data) * 8

    def read_code(pos, length):
        val = 0
        for k in range(length):
            byte_i = (pos + k) >> 3
            if byte_i >= len(data):
                return None
            bit = (data[byte_i] >> (7 - ((pos + k) & 7))) & 1
            val = (val << 1) | bit
        return val

    while bitpos + codelen <= total_bits:
        code = read_code(bitpos, codelen)
        if code is None:
            break
        bitpos += codelen
        if code == 256:
            table = [bytes([i]) for i in range(256)] + [b"", b""]
            codelen = 9
            prev = None
            continue
        if code == 257:
            break
        if prev is None:
            entry = table[code] if code < len(table) else b""
        else:
            if code < len(table):
                entry = table[code]
                table.append(prev + entry[:1])
            else:
                entry = prev + prev[:1]
                table.append(entry)
        out.extend(entry)
        prev = entry

        n_entries = len(table) + (early and 1 or 0)
        if n_entries >= 4096:
            codelen = 12
        elif n_entries >= 2048:
            codelen = 12 if False else (11 if n_entries < 4096 else 12)
            codelen = 11 if len(table) + early < 4096 else 12
        elif n_entries >= 1024:
            codelen = 11 if len(table) + early < 2048 else 12
        elif n_entries >= 512:
            codelen = 10 if len(table) + early < 1024 else 11
        else:
            codelen = 9 if len(table) + early < 512 else 10
    return bytes(out)


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def apply_predictor(data, parms):
    """Undo /Predictor (PNG 10..15 and TIFF 2) on decoded stream bytes."""
    if not isinstance(parms, dict):
        return data
    try:
        pred = int(parms.get("Predictor", 1) or 1)
    except Exception:
        pred = 1
    if pred <= 1:
        return data
    try:
        colors = int(parms.get("Colors", 1) or 1)
        bpc = int(parms.get("BitsPerComponent", 8) or 8)
        columns = int(parms.get("Columns", 1) or 1)
    except Exception:
        colors, bpc, columns = 1, 8, 1
    bpp = max(1, (colors * bpc + 7) // 8)
    rowlen = (columns * colors * bpc + 7) // 8
    if rowlen <= 0:
        return data

    if pred == 2:
        # TIFF horizontal differencing
        out = bytearray(data)
        if bpc == 8:
            for r in range(0, len(out) - rowlen + 1, rowlen):
                for i in range(bpp, rowlen):
                    out[r + i] = (out[r + i] + out[r + i - bpp]) & 0xFF
        elif bpc == 16:
            for r in range(0, len(out) - rowlen + 1, rowlen):
                for i in range(bpp, rowlen, 2):
                    if r + i + 1 < len(out) and r + i - bpp + 1 < len(out):
                        cur = (out[r + i] << 8) | out[r + i + 1]
                        prv = (out[r + i - bpp] << 8) | out[r + i - bpp + 1]
                        v = (cur + prv) & 0xFFFF
                        out[r + i] = (v >> 8) & 0xFF
                        out[r + i + 1] = v & 0xFF
        return bytes(out)

    # PNG predictors: each row is prefixed with a filter-type byte
    out = bytearray()
    prev = bytearray(rowlen)
    i = 0
    n = len(data)
    while i < n:
        ft = data[i]
        i += 1
        row = bytearray(data[i:i + rowlen])
        if len(row) < rowlen:
            row.extend(b"\x00" * (rowlen - len(row)))
        i += rowlen
        if ft == 0:
            pass
        elif ft == 1:  # Sub
            for k in range(bpp, rowlen):
                row[k] = (row[k] + row[k - bpp]) & 0xFF
        elif ft == 2:  # Up
            for k in range(rowlen):
                row[k] = (row[k] + prev[k]) & 0xFF
        elif ft == 3:  # Average
            for k in range(rowlen):
                a = row[k - bpp] if k >= bpp else 0
                row[k] = (row[k] + ((a + prev[k]) >> 1)) & 0xFF
        elif ft == 4:  # Paeth
            for k in range(rowlen):
                a = row[k - bpp] if k >= bpp else 0
                c = prev[k - bpp] if k >= bpp else 0
                row[k] = (row[k] + _paeth(a, prev[k], c)) & 0xFF
        out.extend(row)
        prev = row
    return bytes(out)


def decode_stream(stm, doc=None):
    """Apply /Filter chain and /DecodeParms to a PdfStream."""
    data = stm.raw
    d = stm.dict if isinstance(stm.dict, dict) else {}
    filters = _as_list(d.get("Filter") or d.get("F"))
    parms = _as_list(d.get("DecodeParms") or d.get("DP"))
    if not filters:
        return data
    if doc is not None:
        filters = [doc.resolve(f) for f in filters]
        parms = [doc.resolve(p) for p in parms]

    for i, f in enumerate(filters):
        p = parms[i] if i < len(parms) else None
        try:
            if p is not None and doc is not None:
                p = doc.resolve(p)
        except Exception:
            p = None
        name = str(f) if f is not None else ""
        try:
            if name in ("FlateDecode", "Fl"):
                data = flate_decode(data)
            elif name in ("LZWDecode", "LZW"):
                early = 1
                if isinstance(p, dict):
                    try:
                        early = int(p.get("EarlyChange", 1))
                    except Exception:
                        early = 1
                data = lzw_decode(data, early)
            elif name in ("ASCIIHexDecode", "AHx"):
                data = ascii_hex_decode(data)
            elif name in ("ASCII85Decode", "A85"):
                data = ascii85_decode(data)
            elif name in ("RunLengthDecode", "RL"):
                data = runlength_decode(data)
            elif name in ("Crypt", "DCTDecode", "JPXDecode", "CCITTFaxDecode",
                          "JBIG2Decode"):
                # image codecs: not decoded by this tool
                pass
            else:
                pass
            if p is not None:
                data = apply_predictor(data, p)
        except Exception:
            pass
    return data


# ---------------------------------------------------------------------------
# Document
# ---------------------------------------------------------------------------

_OBJ_RE = re.compile(rb"(?<![0-9])(\d{1,10})\s+(\d{1,5})\s+obj\b")


class PdfDocument(object):
    """A defensively-parsed PDF file."""

    def __init__(self, src):
        if isinstance(src, (bytes, bytearray)):
            self.data = bytes(src)
            self.path = "<bytes>"
        else:
            self.path = str(src)
            with open(src, "rb") as fh:
                self.data = fh.read()
        self.offsets = {}        # objnum -> byte offset (from xref)
        self.objects = {}        # objnum -> parsed value
        self.compressed = {}     # objnum -> parsed value (from object streams)
        self.trailer = {}
        self.warnings = []
        self._objstm_loaded = set()
        self._pages = None
        self._load()

    # -- generic resolution ------------------------------------------------
    def resolve(self, obj, depth=0):
        """Follow indirect references."""
        while isinstance(obj, PdfRef) and depth < 64:
            obj = self.getobj(obj.num)
            depth += 1
        return obj

    def getobj(self, num):
        num = int(num)
        if num in self.objects:
            return self.objects[num]
        if num in self.compressed:
            return self.compressed[num]
        if num in self.offsets:
            try:
                val, _ = self._parse_indirect_at(self.offsets[num])
                self.objects[num] = val
                return val
            except Exception as exc:
                self.warnings.append("obj %d: %r" % (num, exc))
        return None

    def getdict(self, obj):
        obj = self.resolve(obj)
        return obj if isinstance(obj, dict) else {}

    def getstream(self, obj):
        obj = self.resolve(obj)
        return obj if isinstance(obj, PdfStream) else None

    # -- loading -----------------------------------------------------------
    def _load(self):
        data = self.data
        if not data.startswith(b"%PDF"):
            idx = data.find(b"%PDF")
            if idx > 0:
                self.warnings.append("header not at offset 0 (%d)" % idx)
        # 1) follow the xref chain
        try:
            self._load_xref_chain()
        except Exception as exc:
            self.warnings.append("xref chain failed: %r" % (exc,))
        # 2) brute-force scan: fills every gap and rescues broken files
        try:
            self._scan_objects()
        except Exception as exc:
            self.warnings.append("object scan failed: %r" % (exc,))
        # 3) expand object streams found by either route
        try:
            self._load_object_streams()
        except Exception as exc:
            self.warnings.append("ObjStm failed: %r" % (exc,))

    def _find_startxref(self):
        tail = self.data[-2048:] if len(self.data) > 2048 else self.data
        idx = tail.rfind(b"startxref")
        if idx < 0:
            idx = self.data.rfind(b"startxref")
            if idx < 0:
                return None
            base = 0
        else:
            base = len(self.data) - len(tail)
        m = re.compile(rb"startxref\s+(\d+)").search(self.data, base + idx)
        if not m:
            return None
        try:
            return int(m.group(1))
        except Exception:
            return None

    def _load_xref_chain(self):
        off = self._find_startxref()
        if off is None or off <= 0 or off >= len(self.data):
            raise PdfError("no usable startxref")
        seen = set()
        queue = [off]
        guard = 0
        while queue and guard < 512:
            guard += 1
            cur = queue.pop(0)
            if cur in seen or cur <= 0 or cur >= len(self.data):
                continue
            seen.add(cur)
            try:
                prevs = self._parse_xref_section(cur)
            except Exception as exc:
                self.warnings.append("xref@%d: %r" % (cur, exc))
                continue
            for p in prevs:
                if p not in seen:
                    queue.append(p)
        if not self.offsets:
            raise PdfError("xref produced no entries")

    def _parse_xref_section(self, off):
        """Parse a classic xref table or an xref stream at `off`.

        Returns a list of follow-up offsets (/Prev, /XRefStm).
        """
        data = self.data
        data[off:off + 4]
        follows = []
        if data[off:off + 4] == b"xref":
            pos = off + 4
            sub_re = re.compile(rb"\s*(\d+)\s+(\d+)\s*")
            ent_re = re.compile(rb"\s*(\d{1,12})\s+(\d{1,6})\s+([nf])")
            while True:
                m = sub_re.match(data, pos)
                if not m:
                    break
                start = int(m.group(1))
                count = int(m.group(2))
                pos = m.end()
                got = 0
                for i in range(count):
                    m2 = ent_re.match(data, pos)
                    if not m2:
                        break
                    pos = m2.end()
                    got += 1
                    if m2.group(3) == b"n":
                        num = start + i
                        if num not in self.offsets:
                            self.offsets[num] = int(m2.group(1))
                if got == 0:
                    break
            m = re.compile(rb"\s*trailer").match(data, pos)
            if m:
                lx = Lexer(data, m.end())
                try:
                    tr = parse_object(lx)
                    if isinstance(tr, dict):
                        if not self.trailer:
                            self.trailer = tr
                        for key in ("Prev", "XRefStm"):
                            v = self.resolve(tr.get(key))
                            if isinstance(v, int) and v > 0:
                                follows.append(v)
                except Exception:
                    pass
            return follows

        # else: xref stream object at `off`
        try:
            stm, _ = self._parse_indirect_at(off)
        except Exception as exc:
            self.warnings.append("xrefstm@%d: %r" % (off, exc))
            return follows
        if not isinstance(stm, PdfStream):
            # the offset may point at the "N G obj" of a stream we mis-read
            return follows
        d = stm.dict
        if not self.trailer:
            self.trailer = d
        try:
            entry_size = 0
            W = self.resolve(d.get("W")) or []
            W = [int(self.resolve(w) or 0) for w in W]
            entry_size = sum(W)
            size = int(self.resolve(d.get("Size")) or 0)
            index = self.resolve(d.get("Index"))
            if not isinstance(index, list) or not index:
                index = [0, size]
            index = [int(self.resolve(v) or 0) for v in index]
            body = stm.get_data()
            pos = 0
            for k in range(0, len(index) - 1, 2):
                start = index[k]
                count = index[k + 1]
                for i in range(count):
                    if pos + entry_size > len(body):
                        break
                    fields = []
                    for w in W:
                        if w == 0:
                            fields.append(None)
                        else:
                            fields.append(int.from_bytes(body[pos:pos + w], "big"))
                            pos += w
                    ftype = fields[0] if fields[0] is not None else 1
                    f2 = fields[1] if len(fields) > 1 and fields[1] is not None else 0
                    f3 = fields[2] if len(fields) > 2 and fields[2] is not None else 0
                    num = start + i
                    if ftype == 1:
                        if num not in self.offsets:
                            self.offsets[num] = f2
                    elif ftype == 2:
                        self._pending_objstm = getattr(self, "_pending_objstm", [])
                        self._pending_objstm.append((num, f2, f3))
        except Exception as exc:
            self.warnings.append("xrefstm decode: %r" % (exc,))
        for key in ("Prev", "XRefStm"):
            v = self.resolve(d.get(key))
            if isinstance(v, int) and v > 0:
                follows.append(v)
        return follows

    def _parse_indirect_at(self, off):
        """Parse 'N G obj <object> [stream ...] endobj' at a byte offset."""
        lx = Lexer(self.data, off)
        num = parse_object(lx)
        gen = parse_object(lx)
        kw = parse_object(lx)
        if not isinstance(kw, PdfKeyword) or str(kw) != "obj":
            # tolerate a missing 'obj'
            lx.pos = off
            try:
                parse_object(lx)
                parse_object(lx)
            except Exception:
                pass
        value = parse_object(lx)
        lx.skip_ws()
        if isinstance(value, dict) and self.data[lx.pos:lx.pos + 6] == b"stream":
            p = lx.pos + 6
            if self.data[p:p + 2] == b"\r\n":
                p += 2
            elif self.data[p:p + 1] in (b"\n", b"\r"):
                p += 1
            length = self.resolve(value.get("Length"))
            raw = None
            if isinstance(length, int) and 0 <= length and p + length <= len(self.data):
                tail = self.data[p + length:p + length + 24]
                if re.match(rb"\s*endstream", tail):
                    raw = self.data[p:p + length]
            if raw is None:
                j = self.data.find(b"endstream", p)
                if j < 0:
                    j = len(self.data)
                raw = self.data[p:j]
                if raw.endswith(b"\r\n"):
                    raw = raw[:-2]
                elif raw.endswith(b"\n") or raw.endswith(b"\r"):
                    raw = raw[:-1]
            value = PdfStream(value, raw, self)
            lx.pos = p + len(raw)
        return value, lx.pos

    def _scan_objects(self):
        data = self.data
        for m in _OBJ_RE.finditer(data):
            num = int(m.group(1))
            if num in self.objects or num in self.offsets:
                continue
            try:
                val, _ = self._parse_indirect_at(m.start())
            except Exception:
                continue
            if val is None and num != 0:
                pass
            self.objects[num] = val
            self.offsets.setdefault(num, m.start())
        # also trust the scan for objects the xref claimed but we could not read
        for num, off in list(self.offsets.items()):
            if num not in self.objects and num not in self.compressed:
                try:
                    val, _ = self._parse_indirect_at(off)
                    self.objects[num] = val
                except Exception:
                    pass

    def _load_object_streams(self):
        pending = getattr(self, "_pending_objstm", [])
        by_stream = {}
        for num, snum, idx in pending:
            by_stream.setdefault(snum, []).append((num, idx))
        # also discover ObjStm by scanning parsed objects (covers broken xrefs)
        for num, val in list(self.objects.items()):
            if isinstance(val, PdfStream):
                t = val.dict.get("Type")
                if str(t) == "ObjStm":
                    by_stream.setdefault(num, None)
        for snum, wanted in by_stream.items():
            if snum in self._objstm_loaded:
                continue
            self._objstm_loaded.add(snum)
            try:
                self._expand_objstm(snum, wanted)
            except Exception as exc:
                self.warnings.append("ObjStm %d: %r" % (snum, exc))

    def _expand_objstm(self, snum, wanted):
        stm = self.getobj(snum)
        if not isinstance(stm, PdfStream):
            return
        d = stm.dict
        try:
            n = int(self.resolve(d.get("N")) or 0)
            first = int(self.resolve(d.get("First")) or 0)
        except Exception:
            return
        body = stm.get_data()
        if not body:
            return
        header = body[:first]
        nums = [int(x) for x in re.findall(rb"\d+", header)]
        pairs = []
        for i in range(0, min(len(nums) - 1, 2 * n), 2):
            pairs.append((nums[i], nums[i + 1]))
        for onum, ooff in pairs:
            if onum in self.objects or onum in self.compressed:
                continue
            try:
                lx = Lexer(body, first + ooff)
                self.compressed[onum] = parse_object(lx)
            except Exception:
                continue

    # -- page tree ---------------------------------------------------------
    def catalog(self):
        for num, val in list(self.objects.items()) + list(self.compressed.items()):
            d = val.dict if isinstance(val, PdfStream) else val
            if isinstance(d, dict) and str(d.get("Type")) == "Catalog":
                return d
        root = self.resolve(self.trailer.get("Root"))
        if isinstance(root, dict):
            return root
        return {}

    def pages(self):
        if self._pages is not None:
            return self._pages
        out = []
        seen = set()

        def walk(node, depth=0):
            if depth > 64 or len(out) > 20000:
                return
            node = self.resolve(node)
            if not isinstance(node, dict):
                return
            key = id(node)
            if key in seen:
                return
            seen.add(key)
            t = str(node.get("Type") or "")
            kids = self.resolve(node.get("Kids"))
            if t == "Page" or (t != "Pages" and not isinstance(kids, list)):
                out.append(node)
                return
            if isinstance(kids, list):
                for k in kids:
                    walk(k, depth + 1)

        cat = self.catalog()
        if cat.get("Pages") is not None:
            walk(cat["Pages"])
        if not out:
            for num, val in list(self.objects.items()) + list(self.compressed.items()):
                d = val.dict if isinstance(val, PdfStream) else val
                if isinstance(d, dict) and str(d.get("Type")) == "Page":
                    out.append(d)
        self._pages = out
        return out

    def inherited(self, page, key):
        node = page
        for _ in range(64):
            if not isinstance(node, dict):
                break
            if node.get(key) is not None:
                return self.resolve(node.get(key))
            p = node.get("Parent")
            if p is None:
                break
            node = self.resolve(p)
        return None


# ---------------------------------------------------------------------------
# CMap / ToUnicode handling
# ---------------------------------------------------------------------------

def _cmap_tokens(blk):
    """Tokenise a bfchar/bfrange block into ('hex'|'arr'|'int', value)."""
    toks = []
    i = 0
    n = len(blk)
    while i < n:
        c = blk[i:i + 1]
        if c == b"<":
            j = blk.find(b">", i)
            if j < 0:
                break
            toks.append(("hex", blk[i + 1:j]))
            i = j + 1
        elif c == b"[":
            j = blk.find(b"]", i)
            if j < 0:
                break
            inner = blk[i + 1:j]
            toks.append(("arr", re.findall(rb"<([0-9A-Fa-f\s]*)>", inner)))
            i = j + 1
        elif c in b" \t\r\n":
            i += 1
        else:
            m = re.match(rb"[0-9]+", blk[i:])
            if m:
                toks.append(("int", m.group()))
                i += m.end()
            else:
                i += 1
    return toks


def _hexbytes(h):
    h = re.sub(rb"[^0-9A-Fa-f]", b"", h)
    if len(h) % 2:
        h += b"0"
    try:
        return bytes.fromhex(h.decode("ascii"))
    except Exception:
        return b""


def _utf16be(b):
    if len(b) % 2:
        b = b + b"\x00"
    try:
        return b.decode("utf-16-be", "replace")
    except Exception:
        return ""


def parse_tounicode(data):
    """Parse a ToUnicode CMap.  Returns dict: code-bytes -> unicode str."""
    mapping = {}
    if not data:
        return mapping
    text = data
    for blk in re.findall(rb"beginbfchar(.*?)endbfchar", text, re.S):
        toks = _cmap_tokens(blk)
        i = 0
        while i + 1 < len(toks):
            if toks[i][0] == "hex" and toks[i + 1][0] == "hex":
                src = _hexbytes(toks[i][1])
                dst = _utf16be(_hexbytes(toks[i + 1][1]))
                if src:
                    mapping[src] = dst
            i += 2
    for blk in re.findall(rb"beginbfrange(.*?)endbfrange", text, re.S):
        toks = _cmap_tokens(blk)
        i = 0
        while i + 2 < len(toks):
            if toks[i][0] == "hex" and toks[i + 1][0] == "hex":
                lo_b = _hexbytes(toks[i][1])
                hi_b = _hexbytes(toks[i + 1][1])
                third = toks[i + 2]
                if not lo_b:
                    i += 3
                    continue
                width = len(lo_b)
                lo = int.from_bytes(lo_b, "big")
                hi = int.from_bytes(hi_b, "big") if hi_b else lo
                if hi < lo or hi - lo > 65535:
                    hi = lo
                if third[0] == "hex":
                    dstb = _hexbytes(third[1])
                    base_units = [int.from_bytes(dstb[k:k + 2], "big")
                                  for k in range(0, max(2, len(dstb)), 2)] or [0]
                    for k in range(hi - lo + 1):
                        units = list(base_units)
                        units[-1] += k
                        carry = len(units) - 1
                        while carry > 0 and units[carry] > 0xFFFF:
                            units[carry] -= 0x10000
                            units[carry - 1] += 1
                            carry -= 1
                        s = "".join(chr(u & 0xFFFF) for u in units)
                        mapping[(lo + k).to_bytes(width, "big")] = s
                elif third[0] == "arr":
                    for k, hh in enumerate(third[1]):
                        if lo + k > hi:
                            break
                        mapping[(lo + k).to_bytes(width, "big")] = _utf16be(_hexbytes(hh))
                i += 3
            else:
                i += 1
    return mapping


def parse_cid_cmap(data):
    """Parse a CID CMap stream (begincidchar / begincidrange / codespace)."""
    codes = []      # list of (nbytes, lo, hi)
    cid = {}        # code-bytes -> cid
    if not data:
        return codes, cid
    for blk in re.findall(rb"begincodespacerange(.*?)endcodespacerange", data, re.S):
        toks = _cmap_tokens(blk)
        i = 0
        while i + 1 < len(toks):
            if toks[i][0] == "hex" and toks[i + 1][0] == "hex":
                lo_b = _hexbytes(toks[i][1])
                hi_b = _hexbytes(toks[i + 1][1])
                if lo_b:
                    codes.append((len(lo_b),
                                  int.from_bytes(lo_b, "big"),
                                  int.from_bytes(hi_b, "big") if hi_b else int.from_bytes(lo_b, "big")))
            i += 2
    for blk in re.findall(rb"begincidchar(.*?)endcidchar", data, re.S):
        toks = _cmap_tokens(blk)
        i = 0
        while i + 1 < len(toks):
            if toks[i][0] == "hex" and toks[i + 1][0] == "int":
                src = _hexbytes(toks[i][1])
                if src:
                    cid[src] = int(toks[i + 1][1])
            i += 2
    for blk in re.findall(rb"begincidrange(.*?)endcidrange", data, re.S):
        toks = _cmap_tokens(blk)
        i = 0
        while i + 2 < len(toks):
            if toks[i][0] == "hex" and toks[i + 1][0] == "hex" and toks[i + 2][0] == "int":
                lo_b = _hexbytes(toks[i][1])
                hi_b = _hexbytes(toks[i + 1][1])
                base = int(toks[i + 2][1])
                if lo_b:
                    lo = int.from_bytes(lo_b, "big")
                    hi = int.from_bytes(hi_b, "big") if hi_b else lo
                    for k in range(min(hi - lo, 65535) + 1):
                        cid[(lo + k).to_bytes(len(lo_b), "big")] = base + k
            i += 3
    return codes, cid


# ---------------------------------------------------------------------------
# Encodings
# ---------------------------------------------------------------------------

_WINANSI_HIGH = {
    0x80: "\u20ac", 0x82: "\u201a", 0x83: "\u0192", 0x84: "\u201e",
    0x85: "\u2026", 0x86: "\u2020", 0x87: "\u2021", 0x88: "\u02c6",
    0x89: "\u2030", 0x8A: "\u0160", 0x8B: "\u2039", 0x8C: "\u0152",
    0x8E: "\u017d", 0x91: "\u2018", 0x92: "\u2019", 0x93: "\u201c",
    0x94: "\u201d", 0x95: "\u2022", 0x96: "\u2013", 0x97: "\u2014",
    0x98: "\u02dc", 0x99: "\u2122", 0x9A: "\u0161", 0x9B: "\u203a",
    0x9C: "\u0153", 0x9E: "\u017e", 0x9F: "\u0178",
}


def _name_to_unicode(name):
    """Best-effort Adobe glyph name -> unicode."""
    if not name:
        return ""
    if name.startswith("uni") and len(name) >= 7:
        try:
            return "".join(chr(int(name[i:i + 4], 16))
                           for i in range(3, len(name), 4)
                           if re.match(r"[0-9A-Fa-f]{4}", name[i:i + 4] or ""))
        except Exception:
            return ""
    if name.startswith("u") and 5 <= len(name) <= 7:
        try:
            return chr(int(name[1:], 16))
        except Exception:
            pass
    if len(name) == 1:
        return name
    g = _GLYPH_NAMES.get(name)
    if g is not None:
        return g
    m = re.match(r"^(?:g|cid|index|glyph)(\d+)$", name)
    if m:
        return ""
    return ""


_GLYPH_NAMES = {
    "space": " ", "exclam": "!", "quotedbl": '"', "numbersign": "#",
    "dollar": "$", "percent": "%", "ampersand": "&", "quotesingle": "'",
    "quoteright": "\u2019", "quoteleft": "\u2018", "parenleft": "(",
    "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",",
    "hyphen": "-", "minus": "\u2212", "period": ".", "slash": "/",
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    "colon": ":", "semicolon": ";", "less": "<", "equal": "=",
    "greater": ">", "question": "?", "at": "@", "bracketleft": "[",
    "backslash": "\\", "bracketright": "]", "asciicircum": "^",
    "underscore": "_", "grave": "`", "braceleft": "{", "bar": "|",
    "braceright": "}", "asciitilde": "~", "sterling": "\u00a3",
    "yen": "\u00a5", "cent": "\u00a2", "currency": "\u00a4",
    "section": "\u00a7", "copyright": "\u00a9", "registered": "\u00ae",
    "degree": "\u00b0", "plusminus": "\u00b1", "twosuperior": "\u00b2",
    "threesuperior": "\u00b3", "acute": "\u00b4", "mu": "\u00b5",
    "paragraph": "\u00b6", "periodcentered": "\u00b7",
    "cedilla": "\u00b8", "onesuperior": "\u00b9", "ordmasculine": "\u00ba",
    "guillemotright": "\u00bb", "onequarter": "\u00bc",
    "onehalf": "\u00bd", "threequarters": "\u00be",
    "questiondown": "\u00bf", "multiply": "\u00d7", "divide": "\u00f7",
    "germandbls": "\u00df", "ae": "\u00e6", "oe": "\u0153",
    "oslash": "\u00f8", "aring": "\u00e5", "ccedilla": "\u00e7",
    "eth": "\u00f0", "thorn": "\u00fe", "dotlessi": "\u0131",
    "Lslash": "\u0141", "lslash": "\u0142", "Zcaron": "\u017d",
    "zcaron": "\u017e", "Scaron": "\u0160", "scaron": "\u0161",
    "Ydieresis": "\u0178", "endash": "\u2013", "emdash": "\u2014",
    "quoteleft": "\u2018", "quoteright": "\u2019",
    "quotedblleft": "\u201c", "quotedblright": "\u201d",
    "bullet": "\u2022", "dagger": "\u2020", "daggerdbl": "\u2021",
    "ellipsis": "\u2026", "perthousand": "\u2030",
    "guilsinglleft": "\u2039", "guilsinglright": "\u203a",
    "fraction": "\u2044", "florin": "\u0192", "trademark": "\u2122",
    "Omega": "\u03a9", "omega": "\u03c9", "Delta": "\u0394",
    "delta": "\u03b4", "Sigma": "\u03a3", "sigma": "\u03c3",
    "pi": "\u03c0", "alpha": "\u03b1", "beta": "\u03b2",
    "gamma": "\u03b3", "theta": "\u03b8", "lambda": "\u03bb",
    "phi": "\u03c6", "infinity": "\u221e", "notequal": "\u2260",
    "lessequal": "\u2264", "greaterequal": "\u2265",
    "approxequal": "\u2248", "element": "\u2208", "radical": "\u221a",
    "partialdiff": "\u2202", "summation": "\u2211",
    "product": "\u220f", "integral": "\u222b", "ohm": "\u03a9",
    "minus": "\u2212", "nbspace": "\u00a0", "sfthyphen": "-",
    "underscoredbl": "_", "arrowright": "\u2192",
    "arrowleft": "\u2190", "arrowup": "\u2191", "arrowdown": "\u2193",
    "square": "\u25a1", "circlecopyrt": "\u00a9",
    "commaaccent": "\u00b8", "hungarumlaut": "\u02dd",
    "macron": "\u00af", "breve": "\u02d8", "caron": "\u02c7",
    "circumflex": "\u02c6", "tilde": "\u02dc", "dieresis": "\u00a8",
    "ring": "\u02da", "dotaccent": "\u02d9", "ogonek": "\u02db",
    "gravecomb": "\u0300", "acutecomb": "\u0301",
}


def _simple_encoding_table(enc_name, differences):
    """Build code->unicode for a simple (8-bit) font."""
    table = {}
    for code in range(32, 127):
        table[code] = chr(code)
    if enc_name == "WinAnsiEncoding":
        for code in range(128, 256):
            table[code] = _WINANSI_HIGH.get(code, chr(code))
    elif enc_name == "MacRomanEncoding":
        for code in range(128, 256):
            table[code] = chr(code)
    elif enc_name == "Symbol":
        pass
    else:
        # StandardEncoding / PDFDocEncoding / none: use latin-1 for the high half
        for code in range(128, 256):
            table[code] = chr(code)
    for code, gname in (differences or {}).items():
        u = _name_to_unicode(gname)
        if u:
            table[code] = u
    return table


# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------

class PDFFont(object):
    """A usable font: bytes-in -> unicode-out, plus glyph widths."""

    def __init__(self, doc, fd):
        self.doc = doc
        self.fd = fd if isinstance(fd, dict) else {}
        try:
            self.subtype = str(self.fd.get("Subtype") or "")
        except Exception:
            self.subtype = ""
        self.basefont = str(self.fd.get("BaseFont") or "")
        self.two_byte = self.subtype == "Type0"
        self.tounicode = {}
        self.tu_lens = []
        self.cid_map = {}
        self.codespaces = []
        self.enc_table = {}
        self.widths = {}
        self.dw = 1.0
        self.identity = True
        self.ucs2_encoding = False
        self.flags = ""
        self._build()

    # -- construction ------------------------------------------------------
    def _build(self):
        doc = self.doc
        fd = self.fd
        try:
            tu = doc.getstream(fd.get("ToUnicode"))
            if tu is not None:
                self.tounicode = parse_tounicode(tu.get_data())
                self.tu_lens = sorted({len(k) for k in self.tounicode}, reverse=True)
                if self.tounicode:
                    self.flags += "U"
        except Exception:
            pass

        enc = doc.resolve(fd.get("Encoding"))
        enc_name = ""
        differences = {}
        if isinstance(enc, PdfName):
            enc_name = str(enc)
        elif isinstance(enc, dict):
            enc_name = str(doc.resolve(enc.get("BaseEncoding")) or "")
            diffs = doc.resolve(enc.get("Differences"))
            if isinstance(diffs, list):
                cur = 0
                for item in diffs:
                    item = doc.resolve(item)
                    if isinstance(item, (int, float)):
                        cur = int(item)
                    elif isinstance(item, PdfName) or isinstance(item, str):
                        differences[cur] = str(item)
                        cur += 1
        elif isinstance(enc, PdfStream):
            enc_name = str(doc.resolve(enc.dict.get("CMapName")) or "")
            try:
                self.codespaces, self.cid_map = parse_cid_cmap(enc.get_data())
                self.flags += "C"
            except Exception:
                pass
        self.enc_name = enc_name

        if self.two_byte:
            self.identity = enc_name in ("", "Identity-H", "Identity-V")
            self.ucs2_encoding = "UCS2" in enc_name.upper()
            desc = None
            df = doc.resolve(fd.get("DescendantFonts"))
            if isinstance(df, list) and df:
                desc = doc.resolve(df[0])
            self.desc = desc if isinstance(desc, dict) else {}
            try:
                self.dw = float(doc.resolve(self.desc.get("DW")) or 1000) / 1000.0
            except Exception:
                self.dw = 1.0
            self._parse_w()
            if not self.flags:
                self.flags += "N"
        else:
            self.enc_table = _simple_encoding_table(enc_name, differences)
            self._parse_widths()
            if not self.flags:
                self.flags += "S"

    def _parse_widths(self):
        doc = self.doc
        fd = self.fd
        try:
            first = int(doc.resolve(fd.get("FirstChar")) or 0)
        except Exception:
            first = 0
        widths = doc.resolve(fd.get("Widths"))
        if isinstance(widths, list):
            for i, w in enumerate(widths):
                w = doc.resolve(w)
                if isinstance(w, (int, float)):
                    self.widths[first + i] = float(w) / 1000.0

    def _parse_w(self):
        """Parse /W [ c [w...] cfirst clast w ] of a CIDFont."""
        doc = self.doc
        w = doc.resolve(self.desc.get("W"))
        if not isinstance(w, list):
            return
        i = 0
        n = len(w)
        while i < n:
            first = doc.resolve(w[i])
            i += 1
            if i >= n:
                break
            second = doc.resolve(w[i])
            i += 1
            if isinstance(second, list):
                for k, ww in enumerate(second):
                    ww = doc.resolve(ww)
                    if isinstance(ww, (int, float)) and isinstance(first, (int, float)):
                        self.widths[int(first) + k] = float(ww) / 1000.0
            elif isinstance(second, (int, float)):
                if i >= n:
                    break
                third = doc.resolve(w[i])
                i += 1
                if isinstance(third, (int, float)) and isinstance(first, (int, float)):
                    try:
                        for c in range(int(first), int(second) + 1):
                            self.widths[c] = float(third) / 1000.0
                    except Exception:
                        pass

    # -- decoding ----------------------------------------------------------
    def _cid_for(self, code_bytes):
        if not self.two_byte:
            return code_bytes[0] if code_bytes else 0
        if code_bytes in self.cid_map:
            return self.cid_map[code_bytes]
        return int.from_bytes(code_bytes, "big")

    def decode(self, bs):
        """Decode a PDF string (bytes) to unicode text."""
        if not bs:
            return ""
        if not self.two_byte:
            out = []
            for b in bs:
                out.append(self.enc_table.get(b, chr(b) if b >= 32 else ""))
            return "".join(out)

        out = []
        i = 0
        n = len(bs)
        lens = self.tu_lens or [2, 1]
        while i < n:
            hit = False
            for L in lens:
                if i + L > n:
                    continue
                key = bs[i:i + L]
                if key in self.tounicode:
                    out.append(self.tounicode[key])
                    i += L
                    hit = True
                    break
            if hit:
                continue
            # fall back to a 2-byte UCS-2 interpretation
            if i + 2 <= n and (self.identity or self.ucs2_encoding):
                val = (bs[i] << 8) | bs[i + 1]
                if val == 0:
                    i += 2
                    continue
                if 0x20 <= val <= 0xFFFF and not (0xD800 <= val <= 0xDFFF):
                    out.append(chr(val))
                    i += 2
                    continue
            elif i + 1 <= n:
                b = bs[i]
                if 32 <= b < 127:
                    out.append(chr(b))
                    i += 1
                    continue
            i += 1
        return "".join(out)

    def width_of(self, code_bytes, fsize):
        cid = self._cid_for(code_bytes)
        w = self.widths.get(cid)
        if w is None:
            w = self.dw if self.two_byte else 0.5
        return w * fsize

    def string_width(self, bs, fsize, tc=0.0, tw=0.0, tz=1.0):
        """Advance width of a shown string, in text-space units."""
        total = 0.0
        if not self.two_byte:
            for b in bs:
                single = bytes([b])
                wk = self.tounicode.get(single, self.enc_table.get(b, ""))
                total += self.width_of(single, fsize)
                total += tc
                if wk == " ":
                    total += tw
        else:
            lens = self.tu_lens or [2]
            i = 0
            n = len(bs)
            while i < n:
                used = 2 if i + 2 <= n else 1
                for L in lens:
                    if i + L <= n and bs[i:i + L] in self.tounicode:
                        used = L
                        break
                code = bs[i:i + used]
                total += self.width_of(code, fsize)
                total += tc
                i += used
        return total * tz


# ---------------------------------------------------------------------------
# Matrix helpers  (row-vector convention: P' = P x M)
# ---------------------------------------------------------------------------

def mmul(m, n):
    a1, b1, c1, d1, e1, f1 = m
    a2, b2, c2, d2, e2, f2 = n
    return (a1 * a2 + b1 * c2,
            a1 * b2 + b1 * d2,
            c1 * a2 + d1 * c2,
            c1 * b2 + d1 * d2,
            e1 * a2 + f1 * c2 + e2,
            e1 * b2 + f1 * d2 + f2)


def tpoint(m, x, y):
    a, b, c, d, e, f = m
    return (a * x + c * y + e, b * x + d * y + f)


def mtranslate(tx, ty):
    return (1.0, 0.0, 0.0, 1.0, float(tx), float(ty))


def _nums(args, k):
    out = []
    for a in args[:k]:
        try:
            out.append(float(a))
        except Exception:
            out.append(0.0)
    while len(out) < k:
        out.append(0.0)
    return out


# ---------------------------------------------------------------------------
# Content stream processing
# ---------------------------------------------------------------------------

def tokenize_content(data):
    """Yield (operator_string, operands_list) from a content stream."""
    lx = Lexer(data)
    operands = []
    n = lx.n
    guard = 0
    while True:
        guard += 1
        if guard > 20_000_000:
            break
        lx.skip_ws()
        if lx.pos >= n:
            break
        c = data[lx.pos]
        if c in b"+-.0123456789([/":
            before = lx.pos
            try:
                operands.append(parse_object(lx))
            except Exception:
                lx.pos = before + 1
            if lx.pos <= before:
                lx.pos = before + 1
            continue
        if data[lx.pos:lx.pos + 4] == b"true":
            lx.pos += 4
            operands.append(True)
            continue
        if data[lx.pos:lx.pos + 5] == b"false":
            lx.pos += 5
            operands.append(False)
            continue
        if data[lx.pos:lx.pos + 4] == b"null":
            lx.pos += 4
            operands.append(None)
            continue
        if c == 0x3C:  # '<' hex string
            before = lx.pos
            try:
                operands.append(parse_object(lx))
            except Exception:
                lx.pos = before + 1
            if lx.pos <= before:
                lx.pos = before + 1
            continue
        m = _TOKEN_RE.match(data, lx.pos)
        if not m or m.end() == lx.pos:
            lx.pos += 1
            continue
        op = m.group().decode("latin-1")
        lx.pos = m.end()
        if op == "BI":
            # inline image: skip to the matching EI
            j = lx.pos
            idm = re.compile(rb"(?<![A-Za-z0-9])ID(?![A-Za-z0-9])").search(data, j)
            if idm:
                k = idm.end()
                eim = re.compile(rb"(?<![A-Za-z0-9])EI(?![A-Za-z0-9])").search(data, k)
                lx.pos = eim.end() if eim else n
            else:
                lx.pos = n
            operands = []
            continue
        yield op, operands
        operands = []
    if operands:
        yield "", operands


class PageContent(object):
    """Accumulates text runs and line segments for one page."""

    def __init__(self, doc):
        self.doc = doc
        self.runs = []      # (text, x, y) -- raw per-show() fragments (often 1 glyph)
        self.runs_detail = []   # (text, x, y, fontsize, end_x, end_y)
        self.lines = []     # (x1,y1,x2,y2)
        self.fonts_seen = {}
        self.errors = []
        self._depth = 0

    # text extraction
    def process(self, data, resources, ctm=IDENT):
        try:
            self._run(data, resources or {}, ctm)
        except Exception as exc:
            self.errors.append(repr(exc))

    def _run(self, data, res, ctm):
        if self._depth > 24:
            return
        doc = self.doc
        fonts = {}
        xobjs = {}
        if isinstance(res, dict):
            fd = doc.resolve(res.get("Font"))
            if isinstance(fd, dict):
                for k, v in fd.items():
                    try:
                        fonts[k] = PDFFont(doc, doc.getdict(v))
                    except Exception:
                        fonts[k] = None
            xd = doc.resolve(res.get("XObject"))
            if isinstance(xd, dict):
                xobjs = xd

        stack = []
        ctm_cur = ctm
        font = None
        fsize = 0.0
        leading = 0.0
        tc = 0.0
        tw = 0.0
        tz = 1.0
        ts = 0.0
        Tm = IDENT
        Tlm = IDENT
        path = []       # current path subpaths [(x,y),...]
        cur = None
        # initial stroking width from the (default) graphics state
        lw = 1.0

        def show(sbytes, advance=True, force_pos=None):
            nonlocal Tm
            if not isinstance(sbytes, (bytes, bytearray)):
                return
            m = mmul(Tm, ctm_cur)
            x, y = tpoint(m, 0.0, ts)
            txt = font.decode(bytes(sbytes)) if font is not None else bytes(sbytes).decode("latin-1", "replace")
            if txt:
                self.runs.append((txt, x, y))
            if advance:
                if font is not None:
                    w = font.string_width(bytes(sbytes), fsize, tc, tw, tz)
                else:
                    w = len(sbytes) * fsize * 0.5
                ex, ey = tpoint(mmul(mtranslate(w, 0.0), m), 0.0, 0.0)
                if txt:
                    self.runs_detail.append((txt, x, y, fsize, ex, ey))
                Tm = mmul(mtranslate(w, 0.0), Tm)

        for op, args in tokenize_content(data):
            try:
                if op == "q":
                    stack.append((ctm_cur, font, fsize, leading, tc, tw, tz, ts, Tm, Tlm, lw))
                elif op == "Q":
                    if stack:
                        (ctm_cur, font, fsize, leading, tc, tw, tz, ts, Tm, Tlm, lw) = stack.pop()
                elif op == "cm":
                    a, b, c, d, e, f = _nums(args, 6)
                    ctm_cur = mmul((a, b, c, d, e, f), ctm_cur)
                elif op == "w":
                    lw = _nums(args, 1)[0]
                elif op == "gs":
                    gd = doc.resolve(args[0]) if args else None
                    if isinstance(gd, dict):
                        try:
                            lw = float(doc.resolve(gd.get("LW")) or lw)
                        except Exception:
                            pass
                elif op == "BT":
                    Tm = IDENT
                    Tlm = IDENT
                elif op == "ET":
                    pass
                elif op == "Tf":
                    fname = args[0] if args else None
                    font = fonts.get(str(fname)) if fname is not None else None
                    try:
                        fsize = float(args[1]) if len(args) > 1 else 0.0
                    except Exception:
                        fsize = 0.0
                    if font is not None:
                        self.fonts_seen[str(fname)] = font
                elif op == "Td":
                    tx, ty = _nums(args, 2)
                    Tlm = mmul(mtranslate(tx, ty), Tlm)
                    Tm = Tlm
                elif op == "TD":
                    tx, ty = _nums(args, 2)
                    leading = -ty
                    Tlm = mmul(mtranslate(tx, ty), Tlm)
                    Tm = Tlm
                elif op == "TL":
                    leading = _nums(args, 1)[0]
                elif op == "T*":
                    Tlm = mmul(mtranslate(0.0, -leading), Tlm)
                    Tm = Tlm
                elif op == "Tm":
                    a, b, c, d, e, f = _nums(args, 6)
                    Tm = (a, b, c, d, e, f)
                    Tlm = Tm
                elif op == "Tc":
                    tc = _nums(args, 1)[0]
                elif op == "Tw":
                    tw = _nums(args, 1)[0]
                elif op == "Tz":
                    tz = _nums(args, 1)[0] / 100.0
                elif op == "Ts":
                    ts = _nums(args, 1)[0]
                elif op == "Tj":
                    if args:
                        show(args[0])
                elif op == "TJ":
                    arr = args[0] if args else None
                    if isinstance(arr, list):
                        for item in arr:
                            if isinstance(item, (bytes, bytearray)):
                                show(item)
                            else:
                                try:
                                    delta = -float(item) / 1000.0 * fsize * tz
                                except Exception:
                                    delta = 0.0
                                Tm = mmul(mtranslate(delta, 0.0), Tm)
                elif op == "'":
                    Tlm = mmul(mtranslate(0.0, -leading), Tlm)
                    Tm = Tlm
                    if args:
                        show(args[0])
                elif op == '"':
                    if len(args) >= 3:
                        try:
                            tw = float(args[0])
                            tc = float(args[1])
                        except Exception:
                            pass
                        Tlm = mmul(mtranslate(0.0, -leading), Tlm)
                        Tm = Tlm
                        show(args[2])
                elif op in ("m", "l", "c", "v", "y", "re", "h"):
                    if op == "m":
                        x, y = _nums(args, 2)
                        cur = (x, y)
                        path.append([(x, y)])
                    elif op == "l":
                        x, y = _nums(args, 2)
                        if not path:
                            path.append([cur or (x, y)])
                        if cur is None:
                            cur = path[-1][-1]
                        path[-1].append((x, y))
                        cur = (x, y)
                    elif op == "re":
                        x, y, w2, h2 = _nums(args, 4)
                        path.append([(x, y), (x + w2, y), (x + w2, y + h2), (x, y + h2), (x, y)])
                        cur = (x, y)
                    elif op == "h":
                        if path and path[-1]:
                            path[-1].append(path[-1][0])
                            cur = path[-1][0]
                    elif op == "c":
                        x1, y1, x2, y2, x3, y3 = _nums(args, 6)
                        if not path:
                            path.append([cur or (x1, y1)])
                        path[-1].append((x3, y3))
                        cur = (x3, y3)
                    elif op in ("v", "y"):
                        x1, y1, x2, y2 = _nums(args, 4)
                        if not path:
                            path.append([cur or (x1, y1)])
                        path[-1].append((x2, y2))
                        cur = (x2, y2)
                elif op in ("S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"):
                    if op in ("S", "s", "B", "B*", "b", "b*"):
                        self._emit_path(path, ctm_cur)
                    path = []
                    cur = None
                elif op == "Do":
                    name = args[0] if args else None
                    if name is None:
                        continue
                    xo = doc.getstream(xobjs.get(str(name)))
                    if xo is None:
                        continue
                    d = xo.dict
                    if str(d.get("Subtype") or "") != "Form":
                        continue
                    mtx = doc.resolve(d.get("Matrix"))
                    if isinstance(mtx, list) and len(mtx) == 6:
                        try:
                            fm = tuple(float(doc.resolve(v)) for v in mtx)
                        except Exception:
                            fm = IDENT
                    else:
                        fm = IDENT
                    sub_res = doc.resolve(d.get("Resources"))
                    if not isinstance(sub_res, dict):
                        sub_res = res
                    self._depth += 1
                    try:
                        self._run(xo.get_data(), sub_res, mmul(fm, ctm_cur))
                    finally:
                        self._depth -= 1
            except Exception as exc:
                self.errors.append("%s: %r" % (op, exc))
        # flush any path left un-stroked (malformed streams)
        if path:
            self._emit_path(path, ctm_cur)

    def _emit_path(self, path, ctm):
        for sub in path:
            for i in range(len(sub) - 1):
                x1, y1 = tpoint(ctm, sub[i][0], sub[i][1])
                x2, y2 = tpoint(ctm, sub[i + 1][0], sub[i + 1][1])
                if abs(x1 - x2) > 1e-9 or abs(y1 - y2) > 1e-9:
                    self.lines.append((x1, y1, x2, y2))

    # output helpers
    def text_lines(self, sort=False, ytol=1.0):
        runs = list(self.runs)
        if sort:
            runs.sort(key=lambda r: (-round(r[2], 1), r[1]))
            out = []
            cur = None
            for txt, x, y in runs:
                if cur is not None and abs(y - cur[0]) <= ytol:
                    cur[1].append((x, txt))
                else:
                    if cur is not None:
                        out.append(cur)
                    cur = [y, [(x, txt)]]
            if cur is not None:
                out.append(cur)
            res = []
            for y, items in out:
                items.sort()
                res.append("".join(t for _, t in items))
            return res
        # content order: group consecutive runs sharing a baseline
        out = []
        cur_y = None
        buf = []
        for txt, x, y in runs:
            if cur_y is None or abs(y - cur_y) <= ytol:
                buf.append(txt)
                cur_y = y if cur_y is None else cur_y
            else:
                out.append("".join(buf))
                buf = [txt]
                cur_y = y
        if buf:
            out.append("".join(buf))
        return out

    def text_spans(self, gap=0.55, ytol=0.5):
        """Merge the raw per-show() fragments into logical text spans.

        Many CAD exporters (Altium, etc.) emit one `Tj` per glyph, so
        `self.runs` holds single characters.  Spans join fragments that sit
        on the same baseline (or the same stem, for rotated text) and whose
        horizontal/vertical gap is below `gap` x font size.  Returns
        ``[(text, x, y)]`` where ``(x, y)`` is the origin of the first
        fragment, suitable for matching a net label against nearby wires.
        """
        spans = []
        cur = None      # [text, x0, y0, size, ex, ey]
        for txt, x, y, size, ex, ey in self.runs_detail:
            if cur is None:
                cur = [txt, x, y, size, ex, ey]
                continue
            _, x0, y0, s0, pex, pey = cur
            fs = max(size, s0, 1e-6)
            same_row = abs(y - y0) <= ytol * fs
            same_col = abs(x - x0) <= ytol * fs
            if same_row and x >= pex - 0.15 * fs and (x - pex) <= gap * fs:
                cur[0] += txt
                cur[4], cur[5] = ex, ey
                cur[3] = fs
            elif same_col and y <= pey + 0.15 * fs and (pey - y) <= gap * fs:
                cur[0] += txt
                cur[4], cur[5] = ex, ey
                cur[3] = fs
            else:
                spans.append((cur[0], cur[1], cur[2]))
                cur = [txt, x, y, size, ex, ey]
        if cur is not None:
            spans.append((cur[0], cur[1], cur[2]))
        return [s for s in spans if s[0].strip()]


# ---------------------------------------------------------------------------
# Page-level extraction
# ---------------------------------------------------------------------------

def extract_page(doc, page, want_geom=True):
    pc = PageContent(doc)
    res = doc.inherited(page, "Resources")
    contents = doc.resolve(page.get("Contents"))
    streams = []
    if isinstance(contents, PdfStream):
        streams = [contents]
    elif isinstance(contents, list):
        streams = [s for s in (doc.getstream(c) for c in contents) if s is not None]
    blob = b"\n".join(s.get_data() for s in streams)
    pc.process(blob, res, IDENT)
    return pc


def extract_pages(path, page_indices=None, want_geom=True, progress=None):
    """Extract text (and optionally geometry) from a PDF.

    Returns a dict: {'pages': [(index, text, charcount, PageContent)], ...}
    """
    doc = PdfDocument(path)
    pages = doc.pages()
    if page_indices is None:
        page_indices = list(range(len(pages)))
    out = []
    for i in page_indices:
        if i < 0 or i >= len(pages):
            continue
        pc = PageContent(doc)
        try:
            res = doc.inherited(pages[i], "Resources")
            contents = doc.resolve(pages[i].get("Contents"))
            streams = []
            if isinstance(contents, PdfStream):
                streams = [contents]
            elif isinstance(contents, list):
                streams = [s for s in (doc.getstream(c) for c in contents) if s is not None]
            blob = b"\n".join(s.get_data() for s in streams)
            pc.process(blob, res, IDENT)
        except Exception as exc:
            pc.errors.append(repr(exc))
        text = "\n".join(pc.text_lines())
        out.append((i, text, len(text), pc))
        if progress:
            progress(i, len(text))
    return {"doc": doc, "pages": out, "npages": len(pages)}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _wrap_stdout():
    try:
        if hasattr(sys.stdout, "buffer"):
            sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8",
                                          errors="replace", line_buffering=True)
        if hasattr(sys.stderr, "buffer"):
            sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8",
                                          errors="replace", line_buffering=True)
    except Exception:
        pass


def _usage():
    return __doc__


def main(argv=None):
    _wrap_stdout()
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(_usage())
        return 0

    want_geom = "--geom" in argv
    want_sort = "--sort" in argv
    want_fonts = "--fonts" in argv
    quiet = "--quiet" in argv
    argv = [a for a in argv if a not in ("--geom", "--sort", "--fonts", "--quiet")]

    src = argv[0]
    if not os.path.exists(src):
        sys.stderr.write("ERROR: no such file: %s\n" % src)
        return 2

    page_arg = argv[1] if len(argv) > 1 else None
    out_path = argv[2] if len(argv) > 2 else None

    try:
        doc = PdfDocument(src)
    except Exception as exc:
        sys.stderr.write("ERROR: cannot parse %s: %r\n" % (src, exc))
        return 2

    pages = doc.pages()
    npages = len(pages)

    if not quiet:
        sys.stderr.write("file      : %s\n" % src)
        sys.stderr.write("size      : %d bytes\n" % len(doc.data))
        sys.stderr.write("version   : %s\n" % doc.data[:8].decode("latin-1", "replace").strip())
        sys.stderr.write("pages     : %d\n" % npages)
        sys.stderr.write("objects   : %d top-level, %d in object streams\n"
                         % (len(doc.objects), len(doc.compressed)))
        sys.stderr.write("offsets   : %d from xref\n" % len(doc.offsets))
        for w in doc.warnings[:10]:
            sys.stderr.write("warn      : %s\n" % w)

    # no page index -> page list
    if page_arg is None:
        sys.stdout.write("pages=%d\n" % npages)
        sys.stdout.write("%6s %10s  %s\n" % ("index", "chars", "note"))
        total = 0
        for i, page in enumerate(pages):
            try:
                pc = extract_page(doc, page)
                txt = "\n".join(pc.text_lines())
                n = len(txt)
                note = "fonts=%d lines=%d" % (len(pc.fonts_seen), len(pc.lines))
                if pc.errors:
                    note += " errors=%d" % len(pc.errors)
            except Exception as exc:
                n = 0
                note = "ERROR %r" % (exc,)
            total += n
            sys.stdout.write("%6d %10d  %s\n" % (i, n, note))
        sys.stdout.write("total chars = %d\n" % total)
        return 0

    try:
        page_index = int(page_arg)
    except Exception:
        sys.stderr.write("ERROR: page index must be an integer or -1\n")
        return 2

    if page_index == -1:
        indices = list(range(npages))
    else:
        if page_index < 0 or page_index >= npages:
            sys.stderr.write("ERROR: page index %d out of range (0..%d)\n"
                             % (page_index, npages - 1))
            return 2
        indices = [page_index]

    if out_path is None:
        out_path = os.path.splitext(os.path.basename(src))[0] + "_text.txt"
    out_dir = os.path.dirname(os.path.abspath(out_path))
    try:
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
    except Exception:
        pass

    geom_path = None
    if want_geom:
        base, ext = os.path.splitext(out_path)
        geom_path = base + "_geom" + (ext or ".txt")

    geom_fh = open(geom_path, "w", encoding="utf-8", errors="replace") if geom_path else None
    total = 0
    try:
        with open(out_path, "w", encoding="utf-8", errors="replace") as fh:
            for i in indices:
                pc = extract_page(doc, pages[i])
                text = "\n".join(pc.text_lines(sort=want_sort))
                total += len(text)
                fh.write("\n===== PAGE %d/%d  chars=%d =====\n" % (i + 1, npages, len(text)))
                fh.write(text)
                fh.write("\n")
                if want_fonts:
                    fh.write("--- FONTS ON PAGE %d ---\n" % (i + 1))
                    for fname, f in sorted(pc.fonts_seen.items()):
                        fh.write("  %-8s %-14s %-26s enc=%-22s flags=%s\n"
                                 % (fname, f.subtype, f.basefont, getattr(f, "enc_name", ""),
                                    f.flags))
                if geom_fh is not None:
                    geom_fh.write("\n===== PAGE %d/%d =====\n" % (i + 1, npages))
                    for txt, x, y in pc.text_spans():
                        t = txt.replace("\t", " ").replace("\n", " ")
                        geom_fh.write("T\t%.3f\t%.3f\t%s\n" % (x, y, t))
                    for x1, y1, x2, y2 in pc.lines:
                        geom_fh.write("L\t%.3f\t%.3f\t%.3f\t%.3f\n" % (x1, y1, x2, y2))
                if not quiet:
                    sys.stderr.write("page %d/%d: chars=%d textruns=%d lines=%d\n"
                                     % (i + 1, npages, len(text), len(pc.runs), len(pc.lines)))
    finally:
        if geom_fh is not None:
            geom_fh.close()

    sys.stdout.write("wrote %s (%d chars, %d pages)\n" % (out_path, total, len(indices)))
    if geom_path:
        sys.stdout.write("wrote %s\n" % geom_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
